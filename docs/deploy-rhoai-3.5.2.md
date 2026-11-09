# Deploy RHOAI 3.5.2 with MaaS into a new RHDP account

A linear runbook. It starts when a new Red Hat Demo Platform (RHDP) **AWS
Blank Open Environment** arrives and ends with MaaS serving a model and
`scripts/checkup.sh` reporting no problems. Run every block from the root of
this repository, in order.

The stack it builds:

| Component | Version | Set by |
|---|---|---|
| OpenShift | 4.22 | `scripts/00-init.sh` (channel `stable-4.22`) |
| RHACM | `release-2.17` | AutoShift hub values |
| OpenShift GitOps | `gitops-1.22` | AutoShift hub values |
| RHOAI | `rhods-operator.3.5.2`, channel `stable-3.x` | `openshift-ai-version` in `hub.yaml` |
| Connectivity Link | 1.5 (`stable-1.5`) | `connectivity-link-channel` in `hub.yaml` |

Everything on the cluster arrives as RHACM policies from the AutoShift fork
(`$AUTOSHIFT_DIR`, branch `rhoai-maas`). Read
[running-under-autoshift.md](running-under-autoshift.md) once before you start.

Expect about two and a half hours, most of it waiting: 40 minutes for the
cluster, then the operators, the GPU node, RDS and the model.

> The RHOAI 3.5 MaaS documentation (section 1.2) says Connectivity Link
> 1.4.x is required. This stack runs 1.5 deliberately.

## 1. Clear out the previous account

A new open environment is a different AWS account. Nothing from the old one
carries over, and three local leftovers get in the way.

**The old cluster state directory.** Phase 10 refuses to run while
`clusters/rhoai/` is non-empty. The cluster died with its account, so there is
nothing to destroy; move the directory aside instead:

```bash
[ -d clusters/rhoai ] && mv clusters/rhoai "clusters/rhoai-gone-$(date +%Y%m%d)"
```

**The old database credentials.** `secrets/maas-db.env` names an RDS
instance in the old account. `maas-database.sh create` overwrites it, but
`maas-database.sh secret` would happily push the stale URL into the new
cluster. Move it aside so it cannot be used:

```bash
[ -f secrets/maas-db.env ] && mv secrets/maas-db.env "secrets/maas-db.env.old-$(date +%Y%m%d)"
```

`secrets/maas-user.env` can stay. `maas-user.sh create` reuses the password
in it and writes it into the new cluster.

**New AWS keys.** Put the environment's access key, secret key and region in
`secrets/aws.env` (copy `secrets/aws.env.example` if the file does not exist):

```bash
$EDITOR secrets/aws.env        # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
```

Then confirm the keys belong to the new account and that it has exactly one
public hosted zone. With `BASE_DOMAIN=""` in `cluster.env`, phase 10 detects
the domain from public zones only, and there must be exactly one:

```bash
( . secrets/aws.env
  aws sts get-caller-identity --query Account --output text
  aws route53 list-hosted-zones \
    --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text )
```

The pull secret (`secrets/pull-secret.json`) and SSH key are per person, not
per account, so they carry over. [prerequisites.md](prerequisites.md) covers
creating them if they do not exist.

## 2. GPU quota and zone

The model in the hub values (`granite-4-tiny-gpu`) needs one GPU, which
means one `g6.xlarge` (4 vCPU). A new account's quota for *Running On-Demand
G and VT instances* is **0**, and the request can take days, so ask now:

```bash
( . secrets/aws.env
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
    --query 'Quota.Value' )
```

The VPC is single-AZ, so the GPU node must be available in that one zone.
`VPC_AZ=""` takes the first zone in the region. Check where the instance type
is offered and, if the first zone is not listed, set `VPC_AZ` in
`cluster.env` **before** phase 10:

```bash
( . secrets/aws.env
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters Name=instance-type,Values=g6.xlarge --query 'InstanceTypeOfferings[].Location' --output text )
```

## 3. Workstation pre-flight

Since OpenShift's move to Cluster API, `openshift-install` runs a local control plane that
needs inotify instances. At the default limit of 128 the install dies about 40
seconds in with `too many open files`. Phase 10 checks this and refuses with
fewer than 256 free, but set it now:

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
echo 'fs.inotify.max_user_instances=8192' | sudo tee /etc/sysctl.d/99-openshift-installer.conf
```

Make sure the AutoShift fork is on `rhoai-maas` and fully pushed. Policies are
read from Git, never from the working copy; values are read from the working
copy by helm at install time:

```bash
ROOT=$PWD; . ./cluster.env                         # for $AUTOSHIFT_DIR
git -C "$AUTOSHIFT_DIR" status --short --branch      # expect: ## rhoai-maas...origin/rhoai-maas, nothing ahead
git -C "$AUTOSHIFT_DIR" log --oneline origin/rhoai-maas..rhoai-maas   # expect: empty
```

Confirm the pins in the hub values:

```bash
grep -n -e "openshift-ai-version" -e "openshift-ai-channel" -e "connectivity-link-channel" \
  "$AUTOSHIFT_DIR/autoshift/values/clustersets/hub.yaml"
# openshift-ai-version: 'rhods-operator.3.5.2'
# openshift-ai-channel: stable-3.x
# connectivity-link-channel: stable-1.5
```

## 4. Fetch the tooling

```bash
scripts/00-init.sh
```

Downloads `oc`, `kubectl`, `openshift-install-fips` and `helm` for the current
4.22 release into `bin/` and writes `bin/ocp-env.sh`. Re-running against
binaries that already match is cheap. `PATH` is never modified; every later
command uses `"$OC"` from `bin/ocp-env.sh`.

## 5. Build the VPC and the cluster

```bash
scripts/10-deploy-cluster.sh --dry-run
scripts/10-deploy-cluster.sh            # ~40 min
```

The dry run checks the wiring and creates nothing. It cannot test
install-config rendering, which needs the outputs of a stack it does not
create. The real run creates the `rhoai-vpc` CloudFormation stack from
`cloudformation/01_vpc.yaml` (new account, so it is always a create), renders
`install-config.yaml` from the stack outputs, and installs into it. The log
path prints first, under `logs/deploy-aws-<timestamp>.log`.

Then set up the shell every later block assumes:

```bash
source bin/ocp-env.sh
export KUBECONFIG=clusters/rhoai/auth/kubeconfig
"$OC" get nodes
"$OC" get clusterversion
```

## 6. Per-cluster values, then AutoShift

Phase 45 has to come first. Helm reads values at install time, so a values
file written after the bootstrap does nothing until another bootstrap. It
needs a reachable cluster, not RHACM:

```bash
scripts/45-autoshift-values.sh --replicas 1 --force   # one GPU node
scripts/50-autoshift.sh bootstrap                     # RHACM, GitOps, AutoShift
```

`--force` overwrites the values file left from the previous account. It is
keyed on `local-cluster`, the RHACM name for a hub that manages itself.

When the bootstrap finishes, the hub is still in the `default` clusterset and
no policy acts on it. Check what `adopt` is about to turn on:

```bash
scripts/autoshift-feature.sh status
```

`gpu`, `rhoai`, `maas` and `users` must read `on`; they already are in the
`rhoai-maas` hub values. `maas` is five labels that only work together
(`openshift-ai`, `connectivity-link`, `openshift-ai-maas`,
`openshift-ai-models`, `leader-worker-set`); `scripts/autoshift-feature.sh
list` shows every group. `lightspeed` may show `PARTIAL`; it is not part of
this runbook.

## 7. Adopt

This is the step that cannot be undone by editing values. It activates every
enabled policy at once, and turning a label back off later stops
reconciliation without uninstalling anything.

```bash
scripts/50-autoshift.sh adopt
scripts/50-autoshift.sh status
```

Re-run `status` until the policies settle. Policies are Pending while they
wait on dependencies, which is not a failure. RHOAI is roughly 75 GB of images
and the GPU node takes about 25 minutes, so give it time before debugging.

**Expect a rolling reboot of every node, about 5 minutes after `adopt`.**
AutoShift's node policies create the `master-node-config` and
`worker-node-config` KubeletConfigs (reserved CPU and memory, `maxPods: 250`).
The Machine Config Operator then cordons, drains and reboots each node in turn,
GPU node included. That takes 30 to 45 minutes. While it runs, operator pods move:
the RHOAI CSV briefly shows `Installing`, Kuadrant components drop to not ready,
the DataScienceCluster dips to Not Ready, and the model restarts when the GPU
node reboots. None of that is a fault. Watch it finish with:

```bash
oc get mcp                 # both pools UPDATED=True, UPDATING=False when done
```

The database and `maas-user` steps can run during the reboot. Hold the smoke
test until both pools have finished.

### Check the operator pins

Once the CSVs exist:

```bash
scripts/checkup.sh --section operators
```

This is the first place the 3.5.2-specific checks come in:

- RHOAI CSV is exactly `rhods-operator.3.5.2` and Succeeded. A newer CSV
  offered by the Subscription is a warning, which is the pin holding. Do not
  approve its InstallPlan by hand; move `openshift-ai-version` in `hub.yaml`.
- `rhcl-operator` is 1.5.x. On 1.5 there is one CSV; no separate Authorino,
  Limitador or DNS CSVs.
- `kuadrant-operator-controller-manager` has the CONNLINK-1878 memory limit
  of 2Gi, which the `connectivity-link` policy sets through the Subscription.
  A hand patch to the Deployment is reset by OLM. To see it directly:

  ```bash
  "$OC" get deployments.apps kuadrant-operator-controller-manager -n openshift-operators \
    -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
  ```

If a CSV is stuck, `scripts/check-operator-install-modes.sh` compares each
OperatorGroup's scope against what its CSV supports.

## 8. The MaaS database

`maas-api` will not start without PostgreSQL, and no label provides it. The
script writes the Secret into `redhat-ai-gateway-infra`, which RHOAI creates,
so wait for the namespace:

```bash
"$OC" get namespace redhat-ai-gateway-infra
scripts/maas-database.sh create          # RDS PostgreSQL, ~10 min; asks to confirm
scripts/maas-database.sh status
```

To overlap the RDS wait with the RHOAI rollout, split it: run
`scripts/maas-database.sh create --no-secret` any time after phase 10, then
`scripts/maas-database.sh secret` once the namespace exists.

`maas-api` reads the Secret only at startup. If it was already crash-looping
when the Secret landed:

```bash
"$OC" rollout restart deployments.apps/maas-api -n redhat-ai-gateway-infra
```

The database adds a subnet, security group and DB subnet group to the VPC
outside the CloudFormation stack. `scripts/maas-database.sh destroy` removes
the instance, the security group and the subnet group, but not the subnet, so
`scripts/90-destroy-cluster.sh --with-vpc` fails on a dependency violation
until that subnet is deleted too (see the last section).

## 9. The MaaS user

Only a member of a subscription's groups can mint a key, and `kubeadmin` is in
none. Create the htpasswd user in `maas-users`:

```bash
scripts/maas-user.sh create
scripts/maas-user.sh status
```

The password is in `secrets/maas-user.env`. The `htpasswd-users` policy adds
the identity provider once the Secret exists, so this can run any time after
phase 10.

## 10. Smoke test

```bash
scripts/35-smoke-test.sh
```

It mints a key as `maas-user`, lists models, and sends a real prompt through
the gateway. Stub text in the answer means the model fell back to a simulator.

Then give Lightspeed its key. The `openshift-lightspeed` policy installs the
operator and writes the OLSConfig, but the MaaS key it reads is a credential,
so it is minted here rather than kept in Git:

```bash
scripts/40-lightspeed.sh key        # mint a key as maas-user, write openshift-lightspeed/maas-api-key
```

Don't run `scripts/40-lightspeed.sh install` on this build: the policy owns
the operator and the OLSConfig, and `install` would give them a second owner.
The key lasts a year by default (`--key-ttl`); re-run `key` before it expires.

## 11. Checkup

```bash
scripts/checkup.sh
```

The whole chain in dependency order. It names the first break, so fix that one
first. The MaaS section carries the rest of the 3.5.2 checks:

- `policy-openshift-ai-maas-dsc` Compliant and `default-dsc`
  `aigateway.modelsAsAService` set to `Managed`.
- `KuadrantControlPlane` `default`: every component ready, every CRD
  established, and the Authorino, Limitador, DNS and MCP Gateway components'
  Deployments Available. Status only; never edit or delete this resource,
  which cascade-deletes all four.
- Red Hat solution 7148630: whether the `payload-processing` EnvoyFilter has
  the endpoint picker fix. If not, checkup names the workaround (below).
- Each model's running vLLM image against the one the RHOAI bundle declares,
  `registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:fd9540f3…bfbc1` for 3.5.2.
- An informational line on the Service Mesh Subscription (below).

Done when the summary says `No problems found.` and the smoke test answers.

## What to verify on first deploy

These were render-tested or reasoned about, never seen on a cluster. Record
what you find in this file.

1. **`policy-openshift-ai-maas-dsc`** goes Compliant after
   `policy-openshift-ai-dsc`, without changes, and the field reads `Managed`:

   ```bash
   "$OC" get policies.policy.open-cluster-management.io policy-openshift-ai-maas-dsc -n policies-autoshift
   "$OC" get datascienceclusters.datasciencecluster.opendatahub.io default-dsc \
     -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}{"\n"}'
   ```

2. **The CONNLINK-1878 override** reaches the Deployment (step 7). It was
   verified only on the generated OperatorPolicy.

3. **Solution 7148630 on 3.5.2.** The fix is backported to the RHOAI 3.5
   branch, but nobody has confirmed that 3.5.2 includes it:

   ```bash
   "$OC" get envoyfilters.networking.istio.io payload-processing -n openshift-ingress -o yaml \
     | grep 'operation: REMOVE'
   ```

   A match means the fix is in. No match means the EPP is bypassed: requests
   succeed but skip prefix-cache and load-aware scheduling. The workaround is
   the `maas-epp-after-ipp-workaround` EnvoyFilter (namespace
   `openshift-ingress`, priority 20, after `payload-processing`'s 10) from
   <https://access.redhat.com/solutions/7148630>. Run the solution's
   Diagnostic Steps before applying it, and delete it after upgrading to a
   fixed build.

4. **The new checkup checks themselves.** They were tested only against
   mocked `oc` output. In particular, checkup finds each `KuadrantControlPlane`
   component's Deployment by the images in the component's status, then by
   name. A `component ...: no Deployment found` warning on a healthy cluster
   means the matching needs fixing, not the cluster. Compare against:

   ```bash
   "$OC" get crd -o name | grep kuadrantcontrolplanes
   "$OC" get deployments.apps -A | grep -i -e authorino -e limitador -e dns -e mcp
   ```

5. **The vLLM image.** The hub values pin the bundle's digest by hand; it
   drifted once already. Checkup compares the running image with the CSV's
   `RELATED_IMAGE_RHAII_VLLM_CUDA_IMAGE`.

6. **The Service Mesh question.** Red Hat solution 7143483 says the ingress
   operator stops managing the `servicemeshoperator3` Subscription from 4.21.22,
   which conflicts with what we saw on 4.22.18. Checkup prints the
   Subscription and the ingress operator's `GATEWAY_API_OPERATOR_VERSION`; the
   full set of commands is in
   [rhoai-disconnected-additional-images.md](rhoai-disconnected-additional-images.md#service-mesh-is-openshifts-dependency-not-rhoais).

## When you are done

```bash
scripts/cluster-power.sh stop --wait          # park it, keep it
```

To remove everything instead: the database's extra subnet is tagged
`<CLUSTER_NAME>-maas-db-<zone>` and has to go before the VPC stack can:

```bash
scripts/maas-database.sh destroy
( . secrets/aws.env
  for id in $(aws ec2 describe-subnets --filters 'Name=tag:Name,Values=rhoai-maas-db-*' \
                --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$id"
  done )
scripts/90-destroy-cluster.sh --with-vpc
```

An expiring open environment takes everything with it, so destroying is only
worth it to stop the bill early. Either way, start the next account at step 1.
