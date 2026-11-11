# Rebuilding with FIPS: plan and checklist

The next cluster is built with `fips: true` (the `cluster.env` default since 12549c3), to recheck
the whole stack under FIPS. FIPS can only be chosen at install time, so this is a destroy and
rebuild of sandbox141, not a change to it. Everything below is in the order to do it.

The detailed per-phase steps are in [deploy-rhoai-3.5.2.md](deploy-rhoai-3.5.2.md); this page
covers what is different about a rebuild, and what to check that is specific to FIPS.

## 0. Decide first

These change what the FIPS cluster runs. None blocks the rebuild, but each is cheaper to decide
before it than after.

| Decision | Options | If undecided |
|---|---|---|
| Hermes image | Our own build with the md5 `usedforsecurity=False` fix; keep the current image; RHOAI Playground and OGX instead | Current image: Hermes starts and answers short turns, but long conversations fail at compression under FIPS |
| Open WebUI | Accept that its Debian OpenSSL is not FIPS validated; rebuild on UBI | Runs, with a documented compliance gap |
| ZTWIM | Leave the label on to see what breaks; turn it off for a clean baseline | On. KB 7144070 says unsupported on FIPS, and 1.2 has not shipped |
| MaaS database | Fresh (destroy and create); reuse the existing RDS instance | Fresh, for a clean recheck. Reuse works: the instance's security group admits the whole VPC CIDR and the VPC stays |

## 1. Before tearing down

```bash
scripts/checkup.sh > logs/pre-rebuild-checkup.txt 2>&1     # a baseline to compare against
git -C "$AUTOSHIFT_DIR" status --short                      # fork clean and pushed: policies come from Git
git -C "$AUTOSHIFT_DIR" log --oneline -1 origin/rhoai-maas
. secrets/aws.env && aws sts get-caller-identity            # RHDP credentials still valid
```

What a rebuild loses, by design:

- Open WebUI's users and chats, and Hermes' memory and skills (both on cluster PVCs).
- Every MaaS API key, if the database is recreated. Nothing outside the cluster holds one except
  Lightspeed's, which phase 40 re-mints.
- The htpasswd Secret. `secrets/cluster-users.env` keeps the passwords, and
  `cluster-users.sh apply` now puts the same password back for a user it finds missing from the
  cluster, so nobody needs a new one.

What survives: the VPC stack `rhoai-vpc` and the extra database subnet (`90-destroy-cluster.sh`
leaves both), everything under `secrets/`, the fork, and the untracked per-cluster values file
`$AUTOSHIFT_DIR/autoshift/values/clusters/local-cluster.yaml`. So do the agent-lab S3 bucket and
IAM user, unless they are removed first (step 2).

## 2. Tear down

First, the agent-lab pipeline storage from
[agent-lab-phase0/README.md](agent-lab-phase0/README.md). Its S3 bucket and IAM user live in the
AWS account, outside the cluster and the VPC stack, so nothing below removes them and they keep
billing (and holding a valid access key) after the cluster is gone:

```bash
. secrets/aws.env
B=rhoai-130382331273-agent-lab; U=rhoai-dspa-agent-lab
aws s3 rm "s3://$B" --recursive && aws s3api delete-bucket --bucket "$B"
for k in $(aws iam list-access-keys --user-name "$U" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name "$U" --access-key-id "$k"; done
aws iam delete-user-policy --user-name "$U" --policy-name s3-agent-lab-bucket
aws iam delete-user --user-name "$U"
rm -f secrets/pipelines-s3-agent-lab.env
```

The project itself (`agent-lab`) goes with the cluster. Then the database and the cluster:

```bash
scripts/maas-database.sh destroy       # skip if reusing the database. Deletes the instance, its
                                       # subnet group and security group; leaves the extra subnet
scripts/90-destroy-cluster.sh          # NOT --with-vpc. Archives clusters/rhoai, keeps the VPC
```

Then check nothing of the old cluster is left:

```bash
. secrets/aws.env
aws ec2 describe-instances --filters "Name=tag-key,Values=kubernetes.io/cluster/rhoai-sxnhz" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'length(Reservations)'
ls clusters/rhoai 2>/dev/null | wc -l   # 0: phase 10 refuses to run while it is non-empty
```

The trap in CLAUDE.md applies only if the VPC is ever deleted: `maas-database.sh` adds a subnet
outside the stack, so `--with-vpc` fails on a dependency until that subnet is removed by hand.

## 3. Build

```bash
scripts/10-deploy-cluster.sh --dry-run
```

Expect, before anything is created:

```
==> FIPS: cluster in FIPS mode; this host is NOT (fips_enabled=0)
    FIPS_SKIP_HOST_CHECK=true: setting OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=1.
```

That is the expected path from this Fedora workstation: the nodes run FIPS, but the install is not
compliant because its initial keys and certificates are made on a non-FIPS host. For a compliant
build, run phase 10 from a RHEL 9 host in FIPS mode instead. Then:

```bash
scripts/10-deploy-cluster.sh           # about 45 minutes
```

## 4. Confirm FIPS before anything else

```bash
scripts/checkup.sh --section cluster
#   ✓ FIPS mode: on (install-config; rendered MachineConfigs: master=true worker=true)
"$OC" debug node/<any node> -- cat /proc/sys/crypto/fips_enabled     # 1
```

If either says off, stop: nothing after this point is a FIPS test.

## 5. AutoShift, then the out-of-band pieces

Runbook sections 6 to 11, unchanged:

```bash
scripts/45-autoshift-values.sh --force   # regenerate local-cluster.yaml for the new cluster
scripts/50-autoshift.sh bootstrap
scripts/50-autoshift.sh adopt            # KubeletConfig policies reboot every node once
scripts/maas-database.sh create          # or: scripts/maas-database.sh secret, if reused
scripts/maas-user.sh create
scripts/cluster-users.sh apply danclark --admin    # state "restored": same password as before
scripts/40-lightspeed.sh key
```

Different from the first build, and now automatic:

- The cluster autoscaler comes up with adopt (workers 3 to 6, GPU 1 to 2).
- `gpu-nodes` labels the GPU MachineSet `cluster-api/accelerator: nvidia-l4`, so the new GPU node
  has the label from birth. On sandbox141 it had to be added by hand.
- Open WebUI starts in OpenShift sign-in mode with `danclark@cluster.local` as administrator, and
  takes its default user role from its environment on first start, so the one-time Admin Panel
  fix is not needed.

### 5a. Before the first bootstrap: two upstream checks

The fresh cluster is the one chance to test things that only happen on a first install.

- **The AutoShift fork is in sync.** Bootstrap from `rhoai-maas` only after the sync with upstream
  and the PR versions of the leader-worker-set, connectivity-link, gpu-nodes and
  nvidia-gpu-operator policies has been reviewed and merged into it, so the cluster runs the code
  under upstream review.
- **Upstream PR #326 (the MultiClusterHub hook race), on a cluster with no ACM yet.**
  `50-autoshift.sh` avoids the race by installing ACM with `--no-hooks` and creating the
  MultiClusterHub itself, so it cannot test the fix. Install ACM once from the PR branch with its
  hooks instead, before `bootstrap`:

  ```bash
  cd ~/workspace/autoshiftv2-wt-281        # branch pr/mch-hook-webhook-wait
  ~/workspace/rhoai-mass-aws/bin/helm upgrade --install advanced-cluster-management advanced-cluster-management \
      -n default --timeout 20m             # hooks on: crd-check now waits for the webhook
  ~/workspace/rhoai-mass-aws/bin/oc get pods -n open-cluster-management | grep crd-check   # its log names each wait
  ~/workspace/rhoai-mass-aws/bin/oc get multiclusterhubs.operator.open-cluster-management.io -A
  ```

  Pass: the MultiClusterHub exists after this first install, with no rerun. Then run
  `scripts/50-autoshift.sh bootstrap` as usual; it finds the MultiClusterHub and leaves it alone.
  Comment the result on #326, including the `crd-check` log.

## 6. The FIPS checks

Functional first, then the known risks:

```bash
scripts/35-smoke-test.sh               # MaaS end to end
scripts/hermes-smoke-test.sh           # a Hermes agent turn with a tool call
scripts/openshell-smoke-test.sh        # a sandbox reaching MaaS
scripts/checkup.sh                     # everything
```

| Check | What would fail | Expected |
|---|---|---|
| A long Hermes conversation, past its compression threshold | md5 in `context_compressor.py` | Fails with the current image |
| Hermes' log at startup | md5 in `skills_sync.py`; logged and tolerated | Bundled skills not synced |
| Open WebUI sign-in and a chat | Debian OpenSSL ignores FIPS | Works; not FIPS validated |
| OpenShell sandbox and MaaS | Vendored Rust crypto ignores the kernel flag | Works; not compliant until RHOAI 3.7 |
| Lightspeed answer | Red Hat build | Works |
| `maas-api` to RDS | TLS from a Red Hat image | Works |
| ZTWIM, if left on | KB 7144070 | Unknown; record what happens |

Record the results against the `fips-rebuild` checklist in the session work state.

## 7. Afterwards

- Park the cluster when idle: `scripts/cluster-power.sh stop`.
- Revisit the decisions in step 0 with the results in hand.
