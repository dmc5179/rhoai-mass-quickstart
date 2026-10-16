# RHOAI MaaS on AWS

Push-button deployment of OpenShift 4.22 on AWS with Red Hat OpenShift AI
Models-as-a-Service.

The VPC is built separately from the cluster, so `openshift-install destroy
cluster` tears down the cluster and leaves the network in place for the next
build.

## Layout

```
cluster.env                 Non-secret settings: platform, region, sizes
cloudformation/01_vpc.yaml  Standalone single-AZ VPC (AWS only)
templates/                  One install-config template per platform
scripts/                    Numbered phases, run in order
bin/                        oc, kubectl, openshift-install-fips  (gitignored)
secrets/                    aws.env, pull-secret.json            (gitignored)
clusters/<name>/            Installer state: kubeconfig, metadata (gitignored)
rhoai-maas-guide/           MaaS guide, as a submodule pinned to a known-good
                            commit of our fork
```

Clone with the submodule:

```bash
git clone --recurse-submodules git@github.com:dmc5179/rhoai-mass-quickstart.git
# already cloned without it:
git submodule update --init
```

The submodule tracks a fork of
[rh-aiservices-bu/rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide).
To pull in upstream changes:

```bash
cd rhoai-maas-guide
git fetch upstream && git merge upstream/main && git push origin main
cd .. && git add rhoai-maas-guide && git commit -m "Bump guide"
```

Committing the submodule pointer is what records *which* version of the guide a
given cluster build was validated against.

## Platforms

Set `PLATFORM` in `cluster.env`. Each platform has its own template under
`templates/`, and `generate-install-config.sh` dispatches on it.

| `PLATFORM` | State | Notes |
|---|---|---|
| `aws` | Working | VPC built separately by CloudFormation and outlives the cluster. GPU machine sets created automatically. |
| `ibmcloud` | Config generation ready, not yet run | `baseDomain` must be a CIS domain zone in the same account. Set `IBM_VPC_NAME` plus both subnet lists to reuse a VPC, or leave blank to let the installer create one. |
| `baremetal` | Needs a host list | `platform.baremetal` requires per-host BMC address, credentials, and MAC. Fill in `templates/install-config.yaml.baremetal`. |

Platform differences worth knowing:

- **The separate-network design is AWS-only.** On IBM Cloud, leaving
  `IBM_VPC_NAME` blank means the installer owns the VPC and destroys it with
  the cluster. Point it at an existing VPC to get the AWS-like separation.
- **GPU machine sets are AWS-only.** `add-gpu-machinesets.sh` patches
  AWS-specific `providerSpec` fields (`instanceType`, `spotMarketOptions`);
  IBM Cloud uses different field names and has no direct spot equivalent.
- **Bare metal is three different approaches**, not one — installer-provisioned
  via BMC, agent-based ISO, or UPI. The template covers the first; see its
  header comment for how to choose.
- **MaaS itself already handles all of them.** The guide auto-detects the
  cluster platform and installs MetalLB plus a passthrough Route on non-cloud
  clusters, so phase 20 needs no changes for bare metal.

## Prerequisites

- An AWS account with admin credentials.
- **A registered domain with a public Route 53 hosted zone in that account.**
  The installer creates cluster DNS inside it. Without one, phase 10 stops
  before touching anything.
- A pull secret from <https://console.redhat.com/openshift/install/pull-secret>,
  saved to `secrets/pull-secret.json`.
- An SSH public key (`~/.ssh/id_rsa.pub` by default).
- `aws`, `python-yq`, `jq`, and `curl` on PATH.

## Usage

```bash
cp secrets/aws.env.example secrets/aws.env   # then fill in your keys
$EDITOR cluster.env                          # PLATFORM, region, cluster name

scripts/00-init.sh                           # fetch oc + openshift-install
scripts/10-deploy-cluster.sh --dry-run       # check wiring
scripts/10-deploy-cluster.sh                 # VPC + cluster, 30-45 min
scripts/20-deploy-maas.sh                    # RHOAI + MaaS, 20-40 min
```

`20-deploy-maas.sh` passes its arguments straight through to the guide's
`setup-maas.sh`, so anything that script accepts works here:

```bash
scripts/20-deploy-maas.sh --model simulator      # CPU-only, no GPU needed
scripts/20-deploy-maas.sh --with-observability
scripts/20-deploy-maas.sh --from-phase 4         # resume after a failure
```

With no arguments the guide auto-detects GPU capacity and picks a model.

## GPU nodes

Phase 10 creates two GPU machine sets, both at **0 replicas**, so they cost
nothing until you ask for one:

| Machine set | Purpose |
|---|---|
| `<infra>-gpu-<az>` | On-demand. Predictable, no interruptions. |
| `<infra>-gpu-spot-<az>` | Spot. Much cheaper, but AWS can reclaim the node with a two-minute warning. |

```bash
source bin/ocp-env.sh
export KUBECONFIG=clusters/rhoai/auth/kubeconfig

"$OC" get machineset -n openshift-machine-api
"$OC" scale machineset/<name> -n openshift-machine-api --replicas=1
```

Both are cloned from the cluster's own worker machine set, so they inherit the
correct RHCOS AMI, subnet, security groups, and IAM profile. Nodes are labelled
`node-role.kubernetes.io/gpu` and tainted `nvidia.com/gpu:NoSchedule`, which
keeps ordinary workloads off them; the guide's GPU models already carry the
matching toleration.

Set the instance type with `GPU_INSTANCE_TYPE` in `cluster.env`. Scale back to
0 when you are done — a running GPU node is the most expensive thing in this
stack.

Then use the cluster:

```bash
source bin/ocp-env.sh
export KUBECONFIG=clusters/rhoai/auth/kubeconfig
"$OC" get clusterversion
```

PATH is deliberately not modified. `bin/ocp-env.sh` exports `$OC`, `$KUBECTL`,
and `$OPENSHIFT_INSTALL` as explicit paths, so these binaries never collide with
anything else installed on the host.

## Teardown

```bash
source bin/ocp-env.sh
"$OPENSHIFT_INSTALL" destroy cluster --dir clusters/rhoai
```

The VPC stack survives. To remove it as well:

```bash
aws cloudformation delete-stack --stack-name rhoai-vpc
```

## Notes

- **GPU quota.** New AWS accounts have a quota of 0 for "Running On-Demand G and
  VT instances". Request an increase before adding a GPU machine set; approval
  can take days. The MaaS guide ships CPU-only models (`simulator`,
  `qwen3-06b`), so the platform can be validated while that is pending.
- **Single AZ.** `cloudformation/01_vpc.yaml` builds one AZ to keep NAT gateway
  costs down, which means no AZ redundancy for the control plane. Set `VPC_AZ`
  in `cluster.env` to pin the zone when GPU capacity matters.
- **Installer binary.** The RHEL 9 installer archive ships as
  `openshift-install-fips`; it is kept under that name. It is the ordinary
  installer when the host is not in FIPS mode.
