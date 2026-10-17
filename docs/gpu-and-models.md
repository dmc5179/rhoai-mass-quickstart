# GPUs and models

## The one thing to know

**The guide only *detects* GPUs. It never creates them.**

`setup-maas.sh` reads the `nvidia.com/gpu.memory` node label. If no node has
it, it falls back to the CPU simulator — and reports success. You get a
working MaaS install that answers prompts with stub text, and nothing says
anything went wrong.

Two defences, use both:

1. Bring up a GPU node **before** phase 20 — see below.
2. Set `MAAS_MODEL` in `cluster.env` instead of leaving it `auto`, so a
   missing GPU becomes a visible failure.

## Choosing a model

| `MAAS_MODEL` | Hardware | Storage | Notes |
|---|---|---|---|
| `simulator` | CPU | `hf://sshleifer/tiny-gpt2` | stub responses; for plumbing tests |
| `qwen3-06b` | CPU, ~16 GiB RAM | `hf://Qwen/Qwen3-0.6B` | real inference, no GPU |
| `granite-tiny-gpu` | GPU, ~8 GiB VRAM | **OCI modelcar** | best fit for `g6.xlarge` |
| `gemma` | GPU, ~12 GiB VRAM | **OCI modelcar** | |
| `gpt-oss-20b` | GPU, ~16 GiB VRAM | **OCI modelcar** | quantized; tight on 24 GB |
| `auto` | — | — | guide decides; silently downgrades |

`qwen3-06b` is the useful middle ground: genuine inference with no GPU cost,
good for proving the whole path before committing to hardware.

## OCI modelcars

The three GPU models ship as Red Hat-published OCI images rather than
downloading weights at runtime:

```yaml
model:
  name: granite-4-tiny
  uri: oci://registry.redhat.io/rhai/modelcar-granite-4-0-h-tiny-fp8-dynamic:3.0
```

The weights travel as a container image, which means registry auth and
mirroring instead of HuggingFace reachability, faster and repeatable pulls,
and a straightforward disconnected story. Your pull secret must include
`registry.redhat.io`:

```bash
jq -r '.auths | keys[]' secrets/pull-secret.json
```

To package *your own* model as a modelcar, RHOAI's model registry can
transform one from object storage or a URL into a ModelCar image as a
background Job — see [Register and store a model as an OCI
image](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_model_registries/index).

## Adding a GPU node

```bash
# GPU nodes come from the gpu-nodes AutoShift policy, not a script.
scripts/55-autoshift-values.sh --replicas 1 --force          # on-demand
scripts/55-autoshift-values.sh --replicas 1 --spot --force   # spot, cheaper, reclaimable
scripts/50-autoshift.sh bootstrap                            # apply
scripts/50-autoshift.sh status

# Back to zero: regenerate with --replicas 0 and re-apply. The MachineSet
# stays, costing nothing, so scaling back up is immediate.
scripts/55-autoshift-values.sh --replicas 0 --force
scripts/50-autoshift.sh bootstrap
```

`up` takes about 25 minutes and does four things, because all four are needed
before the guide can see a GPU:

1. scales the GPU machine set from 0
2. installs Node Feature Discovery and the NVIDIA GPU operator, from the
   pinned guide submodule
3. creates the `NodeFeatureDiscovery` and `ClusterPolicy` instances, once
   their CRDs exist
4. waits for a node to advertise `nvidia.com/gpu` capacity

It then prints the detected VRAM — the exact label the guide reads to pick a
model.

`down` scales to 0 but leaves the operators installed; they cost nothing idle
and reinstalling them is slow.

### The machine sets

Phase 10 creates two, both at 0 replicas, cloned from the cluster's own worker
machine set so they inherit the right AMI, subnet, security groups, and IAM
profile:

| Name | Spot |
|---|---|
| `<infra>-gpu-<az>` | no |
| `<infra>-gpu-spot-<az>` | yes, bidding up to the on-demand price |

Nodes are labelled `node-role.kubernetes.io/gpu` and tainted
`nvidia.com/gpu:NoSchedule`, which keeps ordinary workloads off an expensive
instance. The guide's GPU models already carry the matching toleration, so
this needs no configuration on your side.

### Instance types

`GPU_INSTANCE_TYPE` in `cluster.env`, default `g6.xlarge`.

| Type | GPU | VRAM |
|---|---|---|
| `g6.xlarge` | L4 | 24 GB |
| `g5.xlarge` | A10G | 24 GB |
| `g4dn.xlarge` | T4 | 16 GB |

Check the type is offered in your AZ before relying on it — availability
varies, and the VPC pins you to one zone:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=g6.xlarge Name=location,Values=us-east-2a
```

### Quota

New AWS accounts have a quota of **0** for *Running On-Demand G and VT
instances*. The machine set will sit unfulfilled with no obvious error.
Request an increase early — it can take days.

Spot has a separate quota, *All G and VT Spot Instance Requests*.

## Confirming you got what you asked for

```bash
scripts/35-smoke-test.sh
```

It sends a real prompt and prints the completion. If the answer looks like
stub text it says so explicitly, which is the fastest way to catch a silent
simulator fallback.

---

Next: [verifying.md](verifying.md) · [operations.md](operations.md)
