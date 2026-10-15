# RHOAI MaaS on AWS

Push-button deployment of OpenShift 4.22 on AWS with Red Hat OpenShift AI
Models-as-a-Service.

The VPC is built separately from the cluster, so `openshift-install destroy
cluster` tears down the cluster and leaves the network in place for the next
build.

## Layout

```
cluster.env                 Non-secret settings: region, cluster name, sizes
cloudformation/01_vpc.yaml  Standalone single-AZ VPC
templates/                  install-config template (CHANGEME placeholders)
scripts/                    Numbered phases, run in order
bin/                        oc, kubectl, openshift-install-fips  (gitignored)
secrets/                    aws.env, pull-secret.json            (gitignored)
clusters/<name>/            Installer state: kubeconfig, metadata (gitignored)
rhoai-maas-guide/           Upstream MaaS guide (manifests + setup script)
```

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
$EDITOR cluster.env                          # region, cluster name, sizing

scripts/00-init.sh                           # fetch oc + openshift-install
scripts/10-deploy-cluster.sh --dry-run       # check wiring
scripts/10-deploy-cluster.sh                 # VPC + cluster, 30-45 min
```

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
