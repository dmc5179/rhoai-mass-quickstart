# Deploy RHOAI 3.5.2 with MaaS into a new RHDP account

A linear runbook. It starts when a new Red Hat Demo Platform (RHDP) **AWS
Blank Open Environment** arrives and ends with MaaS serving a model,
`scripts/checkup.sh` reporting no problems, the Hermes agent answering
through Open WebUI, and an OpenShell sandbox calling the model. Run every block
from the root of this repository, in order.

The stack it builds:

| Component | Version | Set by |
|---|---|---|
| OpenShift | 4.22 | `scripts/00-init.sh` (channel `stable-4.22`) |
| RHACM | `release-2.17` | AutoShift hub values |
| OpenShift GitOps | `gitops-1.22` | AutoShift hub values |
| RHOAI | `rhods-operator.3.5.2`, channel `stable-3.x` | `openshift-ai-version` in `hub.yaml` |
| Connectivity Link | 1.5 (`stable-1.5`) | `connectivity-link-channel` in `hub.yaml` |
| OpenShell | `v0.1.6-rhaiv.4`, chart 0.1.6 (Developer Preview) | `openshell-version` in `hub.yaml`; chart pin in the fork |
| Red Hat build of Agent Sandbox | 0.9.0 (`preview-0.9`, Technology Preview) | `agent-sandbox-channel` in `hub.yaml` |

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
The key lasts 90 days, the longest MaaS allows on RHOAI 3.5.2 (it refuses a
longer `--key-ttl` with "expiration exceeds maximum allowed"). Re-run `key`
before it expires; Lightspeed stops answering when it does.

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

## 12. Hermes and Open WebUI

The Hermes agent and Open WebUI, its chat front end, arrive as the
`hermes-agent` and `open-webui` policies. There is nothing to run: `adopt`
turned them on, and `policy-hermes-agent` waits on
`policy-openshift-ai-models-ready`, so they come up on their own once step 10
answers. This section is how to check them and what to expect.

### What turns them on

All in the `rhoai-maas` hub values (`autoshift/values/clustersets/hub.yaml`):

| Setting | This build | Why |
|---|---|---|
| labels `hermes-agent`, `open-webui` | `'true'` | Enablement |
| `config.hermesAgent.model` | `granite-4-tiny-gpu` | A model **name** from `openshiftAiModels.models`. The request id, subscription, gateway and CA are derived from it |
| `config.openWebui.auth` | `openshift` | Sign in with OpenShift credentials, through an oauth-proxy sidecar |
| `config.openWebui.adminEmail` | `<user>@cluster.local` | The administrator. See [the first administrator](#the-first-administrator) |
| `config.openWebui.allowedGroups` | unset, so `[maas-users]` | Who may sign in |
| model `accessGroups` | includes `system:serviceaccounts:hermes` | Hermes mints its own key with its ServiceAccount; without this group maas-api refuses it with a 403 |
| model `tokenRateLimit` | `300000` per `1m` | See below |

Every Hermes turn sends about 14,000 prompt tokens, because its tool
definitions, skills and memory travel with each request, and a turn that calls
a tool costs about twice that. The `openshift-ai-models` default of 50000 a
minute is three turns; 300000 leaves room for several users. Size it from
that, not from chat traffic.

### Check it

```bash
"$OC" get policies.policy.open-cluster-management.io -n policies-autoshift | grep -E 'hermes|open-webui'
```

All six Compliant: `policy-hermes-agent`, `-access`, `-ready`, `-key`,
`policy-open-webui` and `-ready`. `-key` waits for `-ready`, so it shows
Pending for a few minutes after the pod first starts, which is not a fault.

Hermes mints its key at startup and logs it:

```bash
"$OC" logs deployments.apps/hermes-agent -n hermes -c hermes | grep bootstrap
```

```
[bootstrap] created Secret hermes-api-key with a new random API_SERVER_KEY
[bootstrap] API_SERVER_KEY read from Secret hermes-api-key
[bootstrap] minting a MaaS key: no stored key
[bootstrap] minted MaaS key (subscription granite-4-tiny-gpu-default, ttl 720h), valid until <date>
[bootstrap] Hermes will restart for key renewal at <date a week earlier>
```

Then a real agent turn with a tool call, end to end:

```bash
scripts/hermes-smoke-test.sh
```

It reports the tool Hermes called and its answer. Open WebUI is at:

```bash
"$OC" get routes.route.openshift.io open-webui -n open-webui -o jsonpath='https://{.spec.host}{"\n"}'
```

Opening it redirects to the OpenShift login. Sign in as a user from
`scripts/cluster-users.sh apply`; it adds people to `maas-users`, which is
what `allowedGroups` admits.

### The first administrator

The proxy names each OpenShift user to Open WebUI as `<username>@cluster.local`
when the user has no email address, which is every htpasswd user. Open WebUI
creates the account named by `adminEmail` as administrator on its first start,
so `adminEmail` must be that form: `danclark@cluster.local` for `danclark`. Any
other address creates an administrator nobody can sign in as.

Everyone else starts as `user`, because `allowedGroups` already decided who
gets in. The proxy cannot pass OpenShift groups on, so further administrators
are promoted in **Admin Panel > Users**.

`adminEmail` and the default role are read on Open WebUI's **first start
only**, then kept in its database. On an install that first started with local
sign-in, set **Admin Panel > Settings > General > Default User Role** to `user`
once, or new users wait in `pending`.

### Key renewal

The MaaS key renews itself. Hermes runs under `timeout` and stops at the start
of the renewal window, `renewBefore` (168h) ahead of expiry. The container
exits 124, the kubelet restarts it, and the bootstrap mints a replacement.
That is one restart about every 22 days. A restart count that climbs by one at
that interval is renewal working, not a crash. `policy-hermes-agent-key`
reports a key that expired or a renewal more than two hours overdue.

### When it goes wrong

| Symptom | Cause |
|---|---|
| `[bootstrap] ... mint rejected, HTTP 403` | The model's `accessGroups` lack `system:serviceaccounts:hermes`. `policy-hermes-agent-access` says so too |
| `[bootstrap] ... no HTTP response` | maas-api or the gateway is not up yet. The bootstrap retries for several minutes, then exits and the kubelet restarts it to try again |
| `403 Permission Denied` from the proxy after login | The user is not in `allowedGroups`. Add them with `scripts/cluster-users.sh apply <user>` |
| `server_error` with `resource name may not be empty` at `/oauth/authorize` | The OpenShift OAuth server is rolling out, for example after an htpasswd change. Wait two minutes |
| New users stuck in `pending` | The default role was set at first start; see above |
| An empty model list, or `Model not found` | Open WebUI's stored connection to Hermes is stale. Hermes never rotates its key, so this follows only a deleted `hermes` namespace. Re-enter the key in **Admin Panel > Settings > Connections** |
| `429` in a chat | The model's `tokenRateLimit`. A tool turn costs about 28,000 tokens |
| `policy-hermes-agent-key` NonCompliant | The key expired or its renewal failed. The pod's `bootstrap` log names the reason |
| Long conversations fail on a FIPS cluster | Hermes hashes with MD5 for non-security purposes, which FIPS mode refuses. A known limit of the current image; see [What to verify on first deploy](#what-to-verify-on-first-deploy) |

Deleting the `hermes` or `open-webui` namespace deletes Hermes' memory and
skills, or Open WebUI's users and chats. Turning a label off does not;
`pruneObjectBehavior: None` leaves everything in place.

## 13. OpenShell

OpenShell runs AI agents in isolated sandboxes: kernel-enforced filesystem,
process and network policy around each one, and credentials the agent never
sees. It arrives as policies from the fork: `agent-sandbox` installs the Red
Hat build of Agent Sandbox, and `community/openshell` deploys the OpenShell
gateway and, with `openshell-maas`, gives sandboxes governed access to the MaaS
model. As with step 12 there is nothing to run: the policies order themselves
(prereqs, then namespace, gateway and gateway-ready, then the MaaS provider
once `policy-openshell-maas-provider` sees the model Ready). This section is how
to check it and what to expect.

OpenShell is a **Developer Preview** in Red Hat OpenShift AI 3.5 ("not
supported for production environments"), on Red Hat-built images from
`quay.io/opendatahub`. Agent Sandbox is a **Technology Preview**. Neither is
FIPS-compliant: see [FIPS](#fips).

### What turns it on

All in the `rhoai-maas` hub values (`autoshift/values/clustersets/hub.yaml`):

| Setting | This build | Why |
|---|---|---|
| labels `agent-sandbox`, `agent-sandbox-channel` | `'true'`, `preview-0.9` | The Sandbox API the gateway creates sandboxes through. Needs OpenShift 4.22.2 or later on 4.22 |
| label `cert-manager` | `'true'` | Issues the gateway's TLS and the CLI's mTLS client certificate |
| labels `openshell`, `openshell-version` | `'true'`, `v0.1.6-rhaiv.4` | The gateway, and the image tag for gateway, supervisor, sandbox runtime and CLI. The tag must come from the same upstream release as the chart the policy pins (0.1.6) |
| label `openshell-maas` | `'true'` | The `rhoai-maas` provider profile, provider and sandbox template, kept current by a CronJob |
| `config.openshell.maas.model` | `granite-4-tiny-gpu` | A model **name** from `openshiftAiModels.models`. The gateway URL and the `<model>-default` subscription are derived from it |
| `config.openshell.maas.keyTtl`, `renewBefore` | defaults `720h`, `168h` | The key's lifetime and renewal window. RHOAI 3.5.2 refuses keys longer than `2160h` (90 days) |
| model `accessGroups` | includes `system:serviceaccounts:openshell` | The CronJob mints the key with its ServiceAccount; without this group maas-api refuses it with a 403. Sandboxes get no ServiceAccount token, so this does not let a sandbox mint keys |

Sandboxes draw on the same `tokenRateLimit` as Hermes and everyone else using
the model. The autoshift chart refuses to render if `openshell` is on without
`agent-sandbox` and `cert-manager`, or `openshell-maas` without
`openshift-ai-maas`, `openshift-ai-models` and the model.

### Turning it on for the first time

In this build both labels are on, so `adopt` brings up everything, and the
dependencies order it. On a cluster getting OpenShell for the first time, or
after an `openshell-version` change, enable it in two steps instead, so a
gateway problem is found before anything depends on it:

1. `openshell` and `agent-sandbox` (with `openshell-maas: 'false'`). Wait for
   `policy-openshell-gateway-ready` to be Compliant, then prove a sandbox
   starts:

   ```bash
   scripts/openshell-smoke-test.sh --dry-run
   scripts/openshell-cli.sh -- sandbox create --name hello --no-tty --detach -- sleep 300
   scripts/openshell-cli.sh -- sandbox exec hello --no-tty -- sh -c 'id; head -2 /etc/os-release'
   scripts/openshell-cli.sh -- sandbox delete hello
   ```

   The first sandbox is what pulls the supervisor and sandbox runtime images,
   so a wrong tag or a missing mirror shows up here and nowhere earlier.

2. `openshell-maas`. Then the full smoke test below.

### Check it

```bash
"$OC" get policies.policy.open-cluster-management.io -n policies-autoshift | grep -E 'openshell|agent-sandbox'
```

All seven Compliant: `policy-agent-sandbox-operator-install`,
`policy-openshell-prereqs`, `-namespace`, `-gateway`, `-gateway-ready`,
`-maas-provider` and `-maas-provider-ready`. `-maas-provider-ready` waits for
the CronJob's first successful run, up to 15 minutes; to run it now:

```bash
"$OC" -n openshell create job openshell-maas-provider-manual --from=cronjob/openshell-maas-provider
"$OC" -n openshell logs -f job/openshell-maas-provider-manual
```

```
[maas-provider] imported provider profile rhoai-maas
[maas-provider] created sandbox template rhoai-maas
[maas-provider] minting a new key: provider rhoai-maas does not exist
[maas-provider] provider rhoai-maas has a new key, valid until <date>
```

Later runs print `nothing to do: key valid until <date>` and mint nothing.
Delete the manual job afterwards.

Then the whole path, end to end:

```bash
scripts/openshell-smoke-test.sh
```

It creates a throwaway sandbox, checks it holds `OPENAI_BASE_URL` and only a key
placeholder, lists the models, gets one chat completion, confirms the
placeholder is refused at another host and that the sandbox trusts the cluster
ingress signer, then deletes the sandbox. `scripts/checkup.sh` reports the
policies, the gateway pod, the key's expiry and the CronJob's last success,
read-only.

For anything else, the CLI runs in a throwaway pod, so nothing has to be
installed locally:

```bash
scripts/openshell-cli.sh -- status
scripts/openshell-cli.sh shell          # interactive; the CLI is `openshell`
scripts/openshell-cli.sh delete         # remove a pod left by shell or --keep
```

It signs in with the gateway's mTLS client bundle, which is a platform
administrator while the gateway has no OIDC, and only a cluster administrator
can read it. Multi-user access is not set up; see
[openshell-multi-user-design.md](openshell-multi-user-design.md).

### Using the model from a sandbox

Create sandboxes with both the template and the provider:

```bash
scripts/openshell-cli.sh -- sandbox create --name agent \
  --template rhoai-maas --provider rhoai-maas --no-tty --detach -- sleep 3600
```

The provider puts a placeholder in `OPENAI_API_KEY`, and the sandbox proxy
swaps in the real key only on requests to the MaaS gateway, under `/v1`, from an
allowed program (`config.openshell.maas.binaries`; curl, Python and Node by
default). The template sets `OPENAI_BASE_URL`. Both are needed because OpenShell
0.1.6 does not put a provider's configuration values into the sandbox
environment, only its credentials. The OpenAI SDK then works unchanged; the
request model ID is `publishers/llm/models/granite-4-tiny-gpu`.

A new sandbox can reach nothing else: the default policy allows no egress.

### Upgrades

The gateway StatefulSet is enforced `mustonlyhave`, the rest of the chart
`musthave`. Changing `openshell-version` therefore rolls the gateway like any
other change, with no manual step. The chart version is pinned in the fork's
`policies/community/openshell/manifests/chart/kustomization.yaml` and moves
with the tag: `v0.1.6-rhaiv.N` belongs with chart `0.1.6`. Sandboxes keep
running across a gateway restart; a changed ingress signer reaches them only
after each is stopped and started.

### FIPS

Not compliant, and not supported on FIPS-mandated clusters. Red Hat's own
`check-payload` scan fails all four OpenShell images: they carry their own
cryptography (AWS-LC and ring) rather than the RHEL FIPS module. The RHOAI 3.6
Technology Preview excludes FIPS-mandated clusters, and FIPS is targeted for
RHOAI 3.7 (RHAISTRAT-2717). The Agent Sandbox CSV declares itself not
FIPS-compliant. On a FIPS-mode test cluster OpenShell is expected to work, but
that is a functional test, not compliance.

### When it goes wrong

| Symptom | Cause |
|---|---|
| StatefulSet `openshell` at 0/1, `FailedCreate ... unable to validate against any security context constraint` with `fsGroup` or `runAsUser` 1000 | The chart's fixed UID reached the cluster. The policy removes it with a patch; a live StatefulSet created before that fix keeps it under `musthave`. Delete the StatefulSet once and the policy recreates it |
| `policy-openshell-prereqs` NonCompliant | Its message names what is missing: the Sandbox API (is `agent-sandbox` on and its CSV `Succeeded`?), the cert-manager CRDs, or a default StorageClass |
| Provider job: `mint rejected or unreachable, HTTP 403` | The model's `accessGroups` lack `system:serviceaccounts:openshell` |
| `OPENAI_BASE_URL` empty in a sandbox | Created without `--template rhoai-maas`, or the template does not exist yet. The CronJob creates it; check with `scripts/openshell-cli.sh -- sandbox template get rhoai-maas` |
| `curl: (7) Couldn't connect` or a proxy 403 to any host but MaaS | By design: sandboxes have no egress beyond what an attached provider or a sandbox policy allows |
| `credential_endpoint_mismatch` | The placeholder was sent somewhere other than the MaaS gateway under `/v1`. Also by design |
| TLS errors calling MaaS from a sandbox | The sandbox does not trust the ingress signer. Check ConfigMap `openshell/openshell-additional-ca`; after the signer changes, restart `openshell-0` and stop and start the sandbox |
| `401` from MaaS in a sandbox | The provider's key expired: `scripts/checkup.sh` shows its expiry and the CronJob's last success |
| `scripts/openshell-cli.sh` hangs on `Ready` | The pod cannot start; the script prints its events. A missing `openshell-client-tls` Secret means cert-manager has not issued it |

Deleting the `openshell` namespace deletes every sandbox and the gateway's
database. Turning a label off does not; `pruneObjectBehavior: None` leaves
everything in place.

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

7. **Hermes under FIPS.** The current Hermes image calls `hashlib.md5()`
   without `usedforsecurity=False`, which RHEL's OpenSSL refuses in FIPS mode.
   It was reproduced with `OPENSSL_FORCE_FIPS_MODE=1`, not seen on a FIPS
   cluster. Expect the pod to start and short turns to work. Bundled skills are
   not synced at startup, which is logged and tolerated, and conversations long
   enough to be compressed fail. A long conversation is the test. The fix is an
   image built with that flag; Open WebUI runs on a Debian base whose OpenSSL
   ignores FIPS mode, so it works but is not FIPS validated.

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
