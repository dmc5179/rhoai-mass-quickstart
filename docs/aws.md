# Deploying on AWS

The proven path. Start to finish is roughly 90 minutes, most of it waiting.

Before you begin, work through [prerequisites.md](prerequisites.md) — in
particular the inotify setting and the Route 53 hosted zone.

## 0. Get an account

If you do not already have an AWS account to build in, order an **AWS Blank
Open Environment** from [demo.redhat.com](https://demo.redhat.com). It comes
with admin credentials and a Route 53 public hosted zone, which is what the
next step needs. Everything below works the same on any admin-level AWS
account.

## 1. Configure

```bash
cp secrets/aws.env.example secrets/aws.env
$EDITOR secrets/aws.env        # access key, secret key, AWS_DEFAULT_REGION
$EDITOR cluster.env            # PLATFORM="aws", CLUSTER_NAME, sizing
```

The settings that matter most:

| Setting | Default | Notes |
|---|---|---|
| `PLATFORM` | `aws` | — |
| `CLUSTER_NAME` | `rhoai` | becomes `<name>.<base domain>` |
| `BASE_DOMAIN` | *(empty)* | empty = auto-detect the single public Route 53 zone |
| `VPC_CIDR` | `10.0.0.0/16` | never overlap `100.64.0.0/16` |
| `VPC_AZ` | *(empty)* | empty = first AZ in the region |
| `GPU_INSTANCE_TYPE` | `g6.xlarge` | L4, 24 GB |
| `MAAS_MODEL` | `auto` | see [gpu-and-models.md](gpu-and-models.md) |

## 2. Fetch the tooling

```bash
scripts/00-init.sh
```

Downloads the RHEL 9 builds of `oc` and `openshift-install` for the current
4.22 release into `bin/`, verifies them against the mirror's published
checksums, and writes `bin/ocp-env.sh`.

`PATH` is deliberately untouched. Source the env file to get `$OC` and
`$OPENSHIFT_INSTALL` as explicit paths, so these never collide with any `oc`
already installed:

```bash
source bin/ocp-env.sh
"$OC" version --client
```

The installer binary is named `openshift-install-fips` because that is what
the RHEL 9 archive ships. It is the ordinary installer unless the host is in
FIPS mode.

## 3. Build the cluster

```bash
scripts/10-deploy-cluster.sh --dry-run   # check wiring, create nothing
scripts/10-deploy-cluster.sh
```

Three steps, ~40 minutes:

1. **VPC** — creates the `rhoai-vpc` CloudFormation stack from
   [`../cloudformation/01_vpc.yaml`](../cloudformation/01_vpc.yaml), or reuses
   it if present. Single AZ: one public and one private subnet, an internet
   gateway, one NAT gateway, and an S3 endpoint.
2. **install-config** — rendered from
   `templates/install-config.yaml.aws` plus the stack's outputs.
3. **install** — `openshift-install create cluster`.

No GPU machine sets. Phase 10 used to create an on-demand and a spot set at
0 replicas; the `gpu-nodes` AutoShift policy owns them now, driven by the
labels `scripts/45-autoshift-values.sh` renders. See step 5 below.

Everything is tee'd to `logs/deploy-aws-<timestamp>.log` at debug level. The
path prints first, so you can follow or share it even if the run hangs.

### What the VPC does differently

It carries no `kubernetes.io/cluster/*: owned` tags. The installer adds its
own `: shared` tags to the subnets and removes them on destroy, so the VPC
survives `destroy cluster` and the next build reuses it.

It *does* carry `kubernetes.io/role/elb` on the public subnet and
`kubernetes.io/role/internal-elb` on the private one. Those are not ownership
tags — they are how the AWS cloud controller finds subnets for a
`LoadBalancer` Service. Without them the MaaS gateway fails with
`could not find any suitable subnets for creating the ELB`.

The install-config assigns subnet roles explicitly
(`IngressControllerLB`, `ControlPlaneExternalLB`, `BootstrapNode`,
`ClusterNode`, `ControlPlaneInternalLB`) rather than relying on
auto-discovery, which would require the VPC to contain no non-cluster
subnets — defeating the point of a reusable network.

## 4. Use the cluster

```bash
source bin/ocp-env.sh
export KUBECONFIG=clusters/rhoai/auth/kubeconfig
"$OC" get nodes
"$OC" get clusterversion
```

The `kubeadmin` password is in `clusters/rhoai/auth/kubeadmin-password`.

> Keep `clusters/<name>/` — `metadata.json` is the only record of which cloud
> resources belong to this cluster. Without it, teardown becomes a manual hunt
> through tags.

## 5. Optional: add a GPU node

Only if you want a real LLM rather than the CPU simulator.

```bash
scripts/45-autoshift-values.sh --replicas 1 --force   # GPU node, ~25 min
scripts/50-autoshift.sh bootstrap
```

Full detail in [gpu-and-models.md](gpu-and-models.md). Do it **before** phase
20 — the guide only detects GPUs that already exist, and silently falls back
to the simulator otherwise.

## 6. Install RHOAI and MaaS

```bash
scripts/20-deploy-maas.sh
```

Wraps the guide submodule's `setup-maas.sh`, passing `MAAS_MODEL` from
`cluster.env`. Takes 20–40 minutes and installs the operators (RHOAI,
Connectivity Link, cert-manager, Leader Worker Set), configures the gateway
and PostgreSQL, creates the DataScienceCluster, and deploys your model.

Any `setup-maas.sh` flag passes straight through:

```bash
scripts/20-deploy-maas.sh --with-observability
scripts/20-deploy-maas.sh --from-phase 4     # resume after a failure
```

### Or get MaaS from AutoShift instead

If the cluster is already under AutoShift, the same stack arrives as policy
and you skip phase 20 entirely:

```bash
scripts/autoshift-feature.sh enable maas
scripts/maas-database.sh create     # phase 20 would have done this
scripts/checkup.sh
```

The database step is not optional and is easy to miss, because it is the one
piece `setup-maas.sh` does that no policy does. Details and the failure it
produces are in
[running-under-autoshift.md](running-under-autoshift.md).

## 7. Prove it works

```bash
scripts/30-verify-maas.sh   # platform: six-phase end-to-end
scripts/35-smoke-test.sh    # your model: a real prompt, a real answer
```

See [verifying.md](verifying.md) for what each covers and why you want both.

## 8. When you are done

```bash
scripts/cluster-power.sh stop --wait     # park it, keep it
scripts/90-destroy-cluster.sh            # destroy, keep the VPC
scripts/90-destroy-cluster.sh --with-vpc # destroy everything
```

[operations.md](operations.md) covers what each still costs.

---

## If something fails

Check [troubleshooting.md](troubleshooting.md) first — the failures seen here
in practice are listed with their fixes.

Two logs:

- `logs/deploy-aws-<timestamp>.log` — the whole run
- `clusters/<name>/.openshift_install.log` — the installer's own, which
  survives a failure

A partial install is cleaned up with `scripts/90-destroy-cluster.sh`; it works
from `metadata.json`, which the installer writes before creating anything.
