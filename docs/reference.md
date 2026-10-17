# Reference

## Scripts

Numbered scripts are phases, run in order. Unnumbered ones are helpers.

| Script | What it does |
|---|---|
| `00-init.sh` | Fetch `oc`, `kubectl`, `openshift-install-fips` into `bin/`, checksum-verified. Writes `bin/ocp-env.sh`. |
| `10-deploy-cluster.sh` | Network, install-config, cluster install. |
| `20-deploy-maas.sh` | RHOAI + MaaS + a model, via the guide's `setup-maas.sh`. |
| `30-verify-maas.sh` | Six-phase platform verification, via the guide's `verify.sh`. |
| `35-smoke-test.sh` | Real prompt to your model through the gateway. |
| `40-lightspeed.sh` | Optional. Install OpenShift Lightspeed pointed at your MaaS model. |
| `45-autoshift-values.sh` | Render the per-cluster AutoShift values file, including GPU node sizing. |
| `50-autoshift.sh` | Optional. Put the cluster under AutoShift (RHACM + GitOps). `refresh` pulls policy changes from Git immediately. |
| `90-destroy-cluster.sh` | Tear down; works on partial installs. |
| `generate-install-config.sh` | Render `install-config.yaml`. Called by phase 10. |
| `autoshift-feature.sh` | Enable or disable AutoShift capability as whole features, with the label groups and their config requirements enforced. |
| `check-operator-install-modes.sh` | Find operator policies whose OperatorGroup scope the cluster's catalog will reject. Read-only. |
| `checkup.sh` | Walk the whole RHOAI MaaS chain in dependency order and name the first broken link. Read-only. |
| `cluster-power.sh` | Stop / start / status, with a cost breakdown. |
| `logs.sh` | List recent runs and whether they passed. |
| `lib-logging.sh` | Shared logging, sourced by the phase scripts. |

### Options

```
00-init.sh          [--dir <path>] [--channel <name>] [--force]
10-deploy-cluster.sh [--dry-run] [--log-level <level>]
20-deploy-maas.sh   <any setup-maas.sh flag>
45-autoshift-values.sh [--name <mc>] [--clusterset <s>] [--replicas N]
                    [--instance-type <t>] [--spot] [--stdout] [--force]
30-verify-maas.sh   [--no-cleanup] [--cleanup-only]
35-smoke-test.sh    [--prompt "..."] [--model <id>] [--keep-key]
40-lightspeed.sh    {install|status|uninstall} [--model <id>] [--key-ttl <dur>]
50-autoshift.sh     {bootstrap|adopt|status|uninstall}
90-destroy-cluster.sh [--with-vpc] [--purge] [--log-level <level>]
cluster-power.sh    {stop|start|status} [--wait]
logs.sh             [N] | --failed | --last
```

Useful `setup-maas.sh` flags, passed through by phase 20: `--model`,
`--from-phase N`, `--skip-models`, `--skip-verify`, `--with-observability`,
`--with-external-models`, `--with-redis`, `--disconnected`, `--dry-run`.

## Logs

Every phase script tees its output to `logs/<prefix>-<timestamp>.log` and ends
it with a machine-readable footer:

```
=== RESULT OK exit=0 2026-10-16T17:48:04Z ===
=== RESULT FAILED exit=1 2026-10-16T17:48:03Z ===
```

So you can run a long phase, then just check:

```bash
scripts/logs.sh            # recent runs and their status
scripts/logs.sh --failed   # only failures
scripts/logs.sh --last     # path of the newest log
```

| Prefix | Script |
|---|---|
| `deploy-<platform>` | `10-deploy-cluster.sh` |
| `maas-install` | `20-deploy-maas.sh` |
| `maas-verify` | `30-verify-maas.sh` |
| `smoke-test` | `35-smoke-test.sh` |
| `lightspeed` | `40-lightspeed.sh` |
| `autoshift` | `50-autoshift.sh` |
| `destroy-<platform>` | `90-destroy-cluster.sh` |

A log with no `RESULT` footer means the run is still going, or was killed.

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
