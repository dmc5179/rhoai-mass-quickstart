# Deploying on IBM Cloud

> **Status: config generation is ready and schema-checked, but no cluster has
> been built with it yet.** Treat the first run as a shakedown. The AWS path
> is the proven one.

See [prerequisites.md](prerequisites.md) first, including the inotify setting
— IBM Cloud uses the same local Cluster API control plane as AWS.

## What differs from AWS

| | AWS | IBM Cloud |
|---|---|---|
| Network | separate CloudFormation stack, outlives the cluster | installer-created, **destroyed with the cluster**, unless you point at an existing VPC |
| DNS | Route 53 zone, auto-detected | CIS domain zone, **must be set explicitly** |
| GPU automation | `15-gpu-node.sh`, machine sets, spot | **not implemented** |
| Park / resume | `cluster-power.sh` | **not implemented** |
| Teardown | `90-destroy-cluster.sh` | same script; `openshift-install destroy` handles it |

## 1. Credentials

```bash
cp secrets/ibm.env.example secrets/ibm.env
$EDITOR secrets/ibm.env
```

Set both `IC_API_KEY` (read by the installer) and `IBMCLOUD_API_KEY` (read by
the `ibmcloud` CLI) to the same value.

The key needs access policies for IAM Identity, Resource Group, Cloud Object
Storage, Internet Services, DNS Services, and VPC Infrastructure Services.

## 2. DNS

**`BASE_DOMAIN` must be a domain zone in IBM Cloud Internet Services (CIS) in
the same account.** It is not auto-detected, and CIS does not support IPv6, so
dual-stack is out. A private cluster uses IBM Cloud DNS Services instead.

## 3. Configure

```bash
$EDITOR cluster.env
```

```bash
PLATFORM="ibmcloud"
BASE_DOMAIN="your-cis-zone.example.com"   # required
IBM_REGION="us-south"
IBM_RESOURCE_GROUP=""                      # blank = account default
```

### Existing VPC, or let the installer build one?

Leaving `IBM_VPC_NAME` blank means the installer creates and owns the VPC —
and destroys it with the cluster. That is the opposite of the AWS behaviour,
where the network deliberately survives.

To get the AWS-like separation, create a VPC yourself and point at it. All
three settings are required together; setting only some fails validation in
confusing ways, so the script checks and refuses:

```bash
IBM_VPC_NAME="my-vpc"
IBM_CONTROL_PLANE_SUBNETS="cp-subnet-1, cp-subnet-2"
IBM_COMPUTE_SUBNETS="wk-subnet-1"
```

### Machine profiles

```bash
IBM_CONTROL_PLANE_PROFILE="bx2-4x16"   # 4 vCPU / 16 GB, documented minimum
IBM_COMPUTE_PROFILE="bx2-8x32"         # 8 vCPU / 32 GB, ~ m6i.2xlarge
```

## 4. Deploy

```bash
scripts/00-init.sh
scripts/10-deploy-cluster.sh --dry-run
scripts/10-deploy-cluster.sh
```

Phase 10 skips the CloudFormation step, sources `secrets/ibm.env` instead of
`aws.env`, and skips the GPU machine sets.

## 5. RHOAI and MaaS

```bash
scripts/20-deploy-maas.sh
scripts/30-verify-maas.sh
scripts/35-smoke-test.sh
```

These are platform-agnostic — the guide detects the cluster platform itself.
Without GPU automation, set `MAAS_MODEL` to a CPU model (`qwen3-06b` for real
inference, `simulator` for plumbing only) unless you have attached GPU nodes
by hand.

## Accelerators

IBM Cloud VPC x86 GPU profiles are the `gx2`/`gx3` families — for example
`gx2-8x64x1v100` (V100) and `gx3-16x80x1l4` (L4). These are NVIDIA, and what
an x86 VPC cluster would use.

**IBM Spyre** is a different track: it targets IBM Z (s390x) and IBM Power
(ppc64le), and integrates through the IBM Spyre Operator listed in the
[RHOAI 3.x supported
configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x).
It is not an option for an x86 IBM Cloud VPC cluster. Check what your account
actually offers before planning around either:

```bash
set -a; . secrets/ibm.env; set +a
ibmcloud is instance-profiles | grep -E '^gx'
```

Being listed in the region is not the same as being entitled to launch one.

## Teardown

```bash
scripts/90-destroy-cluster.sh
```

If the installer created the VPC, it goes too. If you supplied an existing
one, it stays.
