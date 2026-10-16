# Deploying on bare metal

> **Status: config generation is ready and validated against the installer,
> but no cluster has been built with it yet.**

Uses the **agent-based installer**: you generate a bootable ISO and start the
machines yourself. No BMC access, no provisioning network, no cloud API.

Of the three bare-metal approaches — BMC-driven IPI, agent-based, and UPI —
this is usually the right one for lab hardware.

## 1. Plan the network

You need:

- a subnet for the nodes (`BM_MACHINE_CIDR`)
- **two free IPs** on it, outside any DHCP pool, for the API and ingress VIPs
- DNS resolving `api.<cluster>.<base domain>` → API VIP and
  `*.apps.<cluster>.<base domain>` → ingress VIP
- one control plane node with a **stable address** to act as the rendezvous
  host — the other nodes find it by IP during bootstrap, so use a static
  address or a DHCP reservation

## 2. Configure

```bash
$EDITOR cluster.env
```

```bash
PLATFORM="baremetal"
BASE_DOMAIN="lab.example.com"
BM_MACHINE_CIDR="10.0.0.0/16"
BM_API_VIP="10.0.0.5"
BM_INGRESS_VIP="10.0.0.6"
BM_RENDEZVOUS_IP="10.0.0.21"
BM_CONTROL_PLANE_REPLICAS="3"
BM_COMPUTE_REPLICAS="2"
```

### Topologies

| Control plane | Workers | Result |
|---|---|---|
| 3 | 2+ | standard |
| 3 | 0 | compact — control plane nodes also run workloads |
| 1 | 0 | single-node OpenShift |

Single-node is special: the installer rejects `platform: baremetal` with
*"Only platform none and external supports 1 ControlPlane and 0 Compute
nodes"*. Setting `1`/`0` switches the whole platform stanza to `none` and
drops the VIPs automatically — one node has nothing to balance across.

## 3. Static IPs or specific disks

Optional. With DHCP, the generated `agent-config.yaml` needs nothing more than
the rendezvous IP.

For static addressing or disk selection, add a `hosts:` list to
`templates/agent-config.yaml.baremetal`. Each entry needs at least one
interface matched by MAC address; `networkConfig` is NMState. The template
header has a worked example.

Note this is `agent-config.yaml`, **not** `install-config.yaml`. The
`platform.baremetal.hosts` field that BMC-driven IPI requires is not used
here.

## 4. Build the ISO

```bash
scripts/00-init.sh
scripts/10-deploy-cluster.sh
```

Phase 10 renders both config files, runs `openshift-install agent create
image`, prints the ISO path, then waits.

```
clusters/<name>/agent.x86_64.iso
```

## 5. Boot the machines

Boot every node from the ISO — USB, virtual media, or PXE. Include the
rendezvous node.

The script blocks on `agent wait-for` while you do this. Interrupting is safe;
resume with:

```bash
source bin/ocp-env.sh
"$OPENSHIFT_INSTALL" agent wait-for install-complete --dir clusters/<name>
```

## 6. RHOAI and MaaS

```bash
scripts/20-deploy-maas.sh
scripts/30-verify-maas.sh
scripts/35-smoke-test.sh
```

**MaaS handles bare metal natively.** The guide detects a non-cloud platform
and installs MetalLB plus a passthrough Route, because there is no cloud load
balancer to give the gateway an external IP. No configuration needed.

## GPUs

`scripts/15-gpu-node.sh` is AWS-only — it scales machine sets, which do not
exist here. With physical GPUs in your nodes, apply the guide's operator
manifests directly:

```bash
source bin/ocp-env.sh
export KUBECONFIG=clusters/<name>/auth/kubeconfig
"$OC" apply -k rhoai-maas-guide/manifests/01-prerequisites/gpu/
# wait for the CSVs, then:
"$OC" apply -k rhoai-maas-guide/manifests/01-prerequisites/gpu/instances/
```

Then confirm a node advertises `nvidia.com/gpu` before running phase 20.

## Teardown

There is no cloud API to delete machines through, so
`90-destroy-cluster.sh` refuses by design. Wipe or re-provision the hardware,
then remove `clusters/<name>/`.
