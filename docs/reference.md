# Reference

## Scripts

Numbered scripts are phases, run in order. Unnumbered ones are helpers.

| Script | What it does |
|---|---|
| `00-init.sh` | Fetch `oc`, `kubectl`, `openshift-install-fips` into `bin/`, checksum-verified. Writes `bin/ocp-env.sh`. |
| `10-deploy-cluster.sh` | Network, install-config, cluster install, GPU machine sets at 0. |
| `15-gpu-node.sh` | Scale a GPU node up or down, install NFD + NVIDIA operator, wait for `nvidia.com/gpu`. |
| `20-deploy-maas.sh` | RHOAI + MaaS + a model, via the guide's `setup-maas.sh`. |
| `30-verify-maas.sh` | Six-phase platform verification, via the guide's `verify.sh`. |
| `35-smoke-test.sh` | Real prompt to your model through the gateway. |
| `90-destroy-cluster.sh` | Tear down; works on partial installs. |
| `generate-install-config.sh` | Render `install-config.yaml`. Called by phase 10. |
| `add-gpu-machinesets.sh` | Create the GPU machine sets. Called by phase 10. |
| `cluster-power.sh` | Stop / start / status, with a cost breakdown. |

### Options

```
00-init.sh          [--dir <path>] [--channel <name>] [--force]
10-deploy-cluster.sh [--dry-run] [--log-level <level>]
15-gpu-node.sh      {up|down|status} [--spot] [--fallback] [--replicas N]
20-deploy-maas.sh   <any setup-maas.sh flag>
30-verify-maas.sh   [--no-cleanup] [--cleanup-only]
35-smoke-test.sh    [--prompt "..."] [--model <id>] [--keep-key]
90-destroy-cluster.sh [--with-vpc] [--purge] [--log-level <level>]
cluster-power.sh    {stop|start|status} [--wait]
```

Useful `setup-maas.sh` flags, passed through by phase 20: `--model`,
`--from-phase N`, `--skip-models`, `--skip-verify`, `--with-observability`,
`--with-external-models`, `--with-redis`, `--disconnected`, `--dry-run`.

## cluster.env

### Common

| Setting | Default | Notes |
|---|---|---|
| `PLATFORM` | `aws` | `aws`, `ibmcloud`, `baremetal` |
| `CLUSTER_NAME` | `rhoai` | |
| `BASE_DOMAIN` | *(empty)* | AWS: auto-detected. IBM/bare metal: required. |
| `MAAS_MODEL` | `auto` | pin it; `auto` downgrades silently |
| `CLUSTER_DIR` | `${ROOT}/clusters/${CLUSTER_NAME}` | installer state |
| `PULL_SECRET_FILE` | `${ROOT}/secrets/pull-secret.json` | |
| `SSH_KEY_FILE` | `~/.ssh/id_rsa.pub` | |

### AWS

| Setting | Default |
|---|---|
| `VPC_STACK_NAME` | `rhoai-vpc` |
| `VPC_INFRA_NAME` | `rhoai` |
| `VPC_CIDR` | `10.0.0.0/16` |
| `VPC_AZ` | *(empty — first AZ in region)* |
| `GPU_INSTANCE_TYPE` | `g6.xlarge` |

### IBM Cloud

| Setting | Default |
|---|---|
| `IBM_REGION` | `us-south` |
| `IBM_RESOURCE_GROUP` | *(empty — account default)* |
| `IBM_VPC_NAME` | *(empty — installer creates one)* |
| `IBM_CONTROL_PLANE_SUBNETS` | *(empty)* comma-separated |
| `IBM_COMPUTE_SUBNETS` | *(empty)* comma-separated |
| `IBM_CONTROL_PLANE_PROFILE` | `bx2-4x16` |
| `IBM_COMPUTE_PROFILE` | `bx2-8x32` |

### Bare metal

| Setting | Default |
|---|---|
| `BM_API_VIP` | *(empty — required)* |
| `BM_INGRESS_VIP` | *(empty — required)* |
| `BM_MACHINE_CIDR` | `10.0.0.0/16` |
| `BM_RENDEZVOUS_IP` | *(empty — required)* |
| `BM_CONTROL_PLANE_REPLICAS` | `3` |
| `BM_COMPUTE_REPLICAS` | `2` |

## Credentials

| File | Contents |
|---|---|
| `secrets/aws.env` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` |
| `secrets/ibm.env` | `IC_API_KEY`, `IBMCLOUD_API_KEY` |
| `secrets/pull-secret.json` | Red Hat pull secret |

All gitignored. Only the `.example` files are committed, listed individually
in `.gitignore` — do not generalise that to `*.example`, or a real credential
saved under that name would be committed.

## Environment from bin/ocp-env.sh

| Variable | Points at |
|---|---|
| `OCP_BIN_DIR` | `bin/` |
| `OCP_VERSION` | e.g. `4.22.18` |
| `OC` | `bin/oc` |
| `KUBECTL` | `bin/kubectl` |
| `OPENSHIFT_INSTALL` | `bin/openshift-install-fips` |

`PATH` is never modified, so these cannot collide with other installs. Phases
20 and 30 do prepend `bin/` for their subprocess only, because the guide's
scripts call bare `oc`.

## Official documentation

- [Govern LLM access with Models-as-a-Service (RHOAI 3.5)](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index)
- [Installing on AWS (OCP 4.22)](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/installing_on_aws/index)
- [Installing on IBM Cloud (OCP 4.22)](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/installing_on_ibm_cloud/index)
- [RHOAI 3.x supported configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x)
- [Upstream guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide)
