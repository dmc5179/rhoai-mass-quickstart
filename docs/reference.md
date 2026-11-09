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
| `generate-install-config.sh` | Render `install-config.yaml` from the template and the VPC stack's outputs. Called by phase 10. Needs Go yq v4. See [aws-vpc-and-cloudformation.md](aws-vpc-and-cloudformation.md). |
| `autoshift-feature.sh` | Enable or disable AutoShift capability as whole features, with the label groups and their config requirements enforced. |
| `check-operator-install-modes.sh` | Find operator policies whose OperatorGroup scope the cluster's catalog will reject. Read-only. |
| `checkup.sh` | Walk the whole RHOAI MaaS chain in dependency order and name the first broken link. Read-only. |
| `hermes-smoke-test.sh` | Prove the Hermes path: pod Ready, MaaS key unexpired, Open WebUI holding the Hermes API key, then one agent turn that must call a tool. Reports the tool, its result and the answer. `--dry-run` skips the turn. |
| `openshell-smoke-test.sh` | Prove the OpenShell path: gateway Ready and CLI connected, then a throwaway sandbox from the `rhoai-maas` template and provider that must hold `OPENAI_BASE_URL` and only a key placeholder, list the models, get one chat completion, have the placeholder refused at another host, and trust the cluster ingress signer. Deletes the sandbox on every exit. `--dry-run` checks only the gateway. |
| `openshell-cli.sh` | Run the OpenShell CLI against the cluster's gateway from a pod in the cluster, so no `openshell` binary is needed locally. `-- <args>` runs one command (`--keep` leaves the pod for the next call; `--stdin` passes stdin through), `shell` opens an interactive shell, `delete` removes the pod, `--dry-run` prints the pod spec. The pod runs the CLI image at the gateway's own tag and signs in with the gateway's mTLS client bundle, so it needs a cluster admin's kubeconfig. |
| `maas-database.sh` | Provision the AWS RDS PostgreSQL that MaaS requires, and write the `maas-db-config` Secret. |
| `maas-user.sh` | Create the htpasswd user that mints MaaS keys, and the Secret the `htpasswd-users` policy waits for. Password in `secrets/maas-user.env`. |
| `cluster-users.sh` | Create, update or remove named htpasswd logins for the people using the cluster (`apply john paul [--admin]`, `remove`, `status`). Prints the passwords to send; keeps them in `secrets/cluster-users.env`; adds the users to `maas-users` (and `cluster-admins` with `--admin`) in the hub values. |
| `cluster-power.sh` | Stop / start / status, with a cost breakdown. |
| `spot-check.sh` | Read-only: spot vs on-demand prices, spot placement scores per zone, the account's spot vCPU quotas, and the hourly cost of the default layout with and without spot workers and GPU. Run it before phase 10 to choose `VPC_AZ` and instance types (`--workers`, `--gpus`, `--dry-run`). |
| `logs.sh` | List recent runs and whether they passed. |
| `lib-logging.sh` | Shared logging, sourced by the phase scripts. |
| `lib-openshell-cli.sh` | The OpenShell CLI pod, sourced by `openshell-cli.sh` and `openshell-smoke-test.sh`. |

### Options

```
00-init.sh          [--dir <path>] [--channel <name>] [--force]
10-deploy-cluster.sh [--dry-run] [--log-level <level>] [--fips | --no-fips]
20-deploy-maas.sh   <any setup-maas.sh flag>
45-autoshift-values.sh [--name <mc>] [--clusterset <s>] [--replicas N]
                    [--instance-type <t>] [--spot] [--stdout] [--force]
30-verify-maas.sh   [--no-cleanup] [--cleanup-only]
35-smoke-test.sh    [--prompt "..."] [--model <id>] [--keep-key]
hermes-smoke-test.sh [--dry-run] [--prompt "..."]
openshell-smoke-test.sh [--dry-run] [--model <id>] [--keep-cli]
openshell-cli.sh    [--keep] [--stdin] -- <openshell args> | shell | delete | --dry-run
40-lightspeed.sh    {install|status|uninstall} [--model <id>] [--key-ttl <dur>]
50-autoshift.sh     {bootstrap|adopt|status|uninstall}
90-destroy-cluster.sh [--with-vpc] [--purge] [--log-level <level>]
cluster-power.sh    {stop|start|status} [--wait]
spot-check.sh       [--workers <type,...>] [--gpus <type,...>] [--dry-run]
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
| `hermes-smoke-test` | `hermes-smoke-test.sh` |
| `openshell-smoke-test` | `openshell-smoke-test.sh` |
| `openshell-cli` | `openshell-cli.sh` (not `shell`, which is interactive) |
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
| `FIPS` | `true` | Nodes in FIPS mode. Install time only. `--fips` / `--no-fips` on phase 10 override it for one run. |
| `FIPS_SKIP_HOST_CHECK` | `true` | Lets phase 10 run from a host that is not in FIPS mode by setting `OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION`. A test cluster, not a compliant one; `false` makes phase 10 stop instead. |
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

## Hermes and Open WebUI settings

Hub values (`config:` in `autoshift/values/clustersets/hub.yaml` of the
AutoShift fork), read by the `hermes-agent` and `open-webui` policies. The
full lists, with every default, are in each policy's README:
[hermes-agent](https://github.com/dmc5179/autoshiftv2/blob/rhoai-maas/policies/stable/hermes-agent/README.md),
[open-webui](https://github.com/dmc5179/autoshiftv2/blob/rhoai-maas/policies/stable/open-webui/README.md).

| Setting | Default | Notes |
|---|---|---|
| `hermesAgent.model` | *(required)* | A model **name** from `openshiftAiModels.models`, not a request id. The request id, subscription, gateway and CA are derived from it |
| `hermesAgent.keyTtl` | `720h` | MaaS key lifetime, whole hours, at most `2160h` (the RHOAI 3.5 limit). Longer values fail the policy render |
| `hermesAgent.renewBefore` | `168h` | How long before expiry the pod restarts to renew the key. Must be shorter than `keyTtl` |
| `hermesAgent.image` | the verified pin | Hermes image, pinned by digest |
| `openWebui.auth` | `local` | `openshift` signs in with OpenShift credentials through an oauth-proxy sidecar; `local` uses Open WebUI accounts |
| `openWebui.adminEmail` | *(none)* | The administrator, created on first start. With `auth: openshift`, `<user>@cluster.local` for an htpasswd user |
| `openWebui.allowedGroups` | `[maas-users]` | `auth: openshift` only. OpenShift groups whose members can sign in |

The model's `accessGroups` must include `system:serviceaccounts:hermes`, the
group Hermes mints its key as. Enable both with the `hermes-agent` and
`open-webui` labels.

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
