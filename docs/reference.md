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
| `45-autoshift-values.sh` | Render the per-cluster AutoShift values file, including GPU node sizing. Reads `AUTH_MODE` (default `oauth`): `AUTH_MODE=oidc scripts/45-autoshift-values.sh` turns the `htpasswd-users` policy off for the cluster and writes the Dev Spaces Keycloak sign-in config (`config.dev-spaces`), deriving the realm's issuer (override with `OIDC_ISSUER`). Refuses `oauth` mode against a cluster already signed in through OIDC, and warns when the cluster is unreachable so the check could not run. |
| `50-autoshift.sh` | Optional. Put the cluster under AutoShift (RHACM + GitOps). `refresh` pulls policy changes from Git immediately. |
| `48-external-oidc.sh` | Switch a fresh cluster to OpenShift direct authentication against an in-cluster Keycloak (`AUTH_MODE=oidc`): `preflight`, `keycloak`, `switch`, `gateway`, `devspaces`, `smoke`, or `all`; `--dry-run` prints the commands. Runs between phase 50 and 35 (AUTH_MODE=oidc only). First pass: not yet run end to end, and the `keycloak` step still builds its realm from `secrets/keycloak-oidc-backup/`, the lab's backup, refusing on a cluster without one; `lib-oidc-realm.sh` is to replace that input. |
| `90-destroy-cluster.sh` | Tear down; works on partial installs. |
| `generate-install-config.sh` | Render `install-config.yaml` from the template and the VPC stack's outputs. Called by phase 10. Needs Go yq v4. See [aws-vpc-and-cloudformation.md](aws-vpc-and-cloudformation.md). |
| `autoshift-feature.sh` | Enable or disable AutoShift capability as whole features, with the label groups and their config requirements enforced. |
| `check-operator-install-modes.sh` | Find operator policies whose OperatorGroup scope the cluster's catalog will reject. Read-only. |
| `checkup.sh` | Walk the whole RHOAI MaaS chain in dependency order and name the first broken link. Read-only. Covers sign-in too: on external OIDC, a Keycloak token accepted by the API server, the kube-apiserver rollout, and front ends still behind OpenShift OAuth. A parked GPU (MachineSets and models at 0) reads as parked, not broken. |
| `hermes-smoke-test.sh` | Prove the Hermes path: pod Ready, MaaS key unexpired, Open WebUI holding the Hermes API key, then one agent turn that must call a tool. Reports the tool, its result and the answer. With `openWebui.maas`, also Open WebUI's MaaS key, the model in its list and one short answer. `--dry-run` skips the turns. |
| `openshell-smoke-test.sh` | Prove the OpenShell path: gateway Ready and CLI connected, then a throwaway sandbox from the `rhoai-maas` template and provider that must hold `OPENAI_BASE_URL` and only a key placeholder, list the models, get one chat completion, have the placeholder refused at another host, and trust the cluster ingress signer. Deletes the sandbox on every exit. `--dry-run` checks only the gateway. |
| `openshell-cli.sh` | Run the OpenShell CLI against the cluster's gateway from a pod in the cluster, so no `openshell` binary is needed locally. `-- <args>` runs one command (`--keep` leaves the pod for the next call; `--stdin` passes stdin through), `shell` opens an interactive shell, `delete` removes the pod, `--dry-run` prints the pod spec. The pod runs the CLI image at the gateway's own tag and signs in with the gateway's mTLS client bundle, so it needs a cluster admin's kubeconfig. |
| `maas-database.sh` | Provision the AWS RDS PostgreSQL that MaaS requires, and write the `maas-db-config` Secret. |
| `maas-user.sh` | Create the user that mints MaaS keys (`create`, `status`). Password in `secrets/maas-user.env`. Normally an htpasswd user plus the Secret the `htpasswd-users` policy waits for. On external OIDC, a Keycloak realm user in `maas-users` (`scripts/lib-keycloak.sh`); `status` gets it a token. An existing realm user's password changes only with `--rotate`. |
| `rhokp-key.sh` | `apply` creates or updates the RHOKP access key Secret (`rhokp/rhokp-access-key`, key `ACCESS_KEY`) that the `rhokp-mcp` policies wait for, from `RHOKP_KEY` in `secrets/rhokp.env`, without the key appearing in a command line or log; `--restart` makes RHOKP read a changed key (it re-indexes). `status` reports the Secret, both Deployments, the number of documents in the search index, the MCP gateway registration and the policies. |
| `demo-mcp-cleanup.sh` | Remove what the 2026-11-25 agent-identity MCP demo created: server registrations and routes, the `mcp-gateway` Gateway (and its AWS load balancer) with its attachments, the MCPGatewayExtension and its namespace, the OpenShift MCP server Helm release, and the demo RoleBinding. Dry run by default — it prints the commands and calls no API; `--apply` runs them. With `--apply` it refuses while the `mcp-gateway` policy is still enabled, since ACM would recreate everything; the shared `openshift-default` GatewayClass is left alone. |
| `cluster-users.sh` | Create, update or remove named logins for the people using the cluster (`apply john paul [--admin] [--group <g>]`, `remove`, `status`). Prints the passwords to send; keeps them in `secrets/cluster-users.env`. Normally htpasswd users, added to `maas-users` (and `cluster-admins` with `--admin`) in the hub values. On external OIDC, Keycloak realm users and groups instead (`--admin` adds `cluster-admins` and `rhods-admins`; memberships only added); `status` gets each user a token, and an existing password changes only with `--rotate`. |
| `dns-zone-clash-test.sh` | Live test of the Connectivity Link DNSPolicy failure when a public and a private Route 53 zone share a name (`run`, `status`, `teardown`, `--dry-run`). Builds public and private `dnstest.<base>` plus a public `api.dnstest.<base>`, a scoped IAM user (key in `secrets/dns-zone-clash-test.env`), and a test Gateway with a DNSPolicy; passes when the clash listener fails with "multiple zones found for host" and the `api` listener resolves. The zones and user are outside the VPC stack: run `teardown` before `90-destroy-cluster.sh --with-vpc`, and while they exist BASE_DOMAIN auto-detection sees extra public zones. |
| `keycloak-oidc.sh` | Test harness that switches the cluster from the OpenShift OAuth server to a Keycloak realm (direct OIDC) and back, to reproduce RHOAI gateway behaviour with external OIDC; follow `docs/keycloak-oidc-test-runbook.md`. Subcommands: `preflight`, `backup`, `keycloak-install`, `switch-ocp`, `switch-gateway --keep-creds\|--regen-creds`, `cookie-refresh <duration\|default>`, `verify [--user u] [--watch-session]`, `rollback`, `keycloak-uninstall`, `status`, all with `--dry-run`. **Disruptive:** htpasswd and kubeadmin logins stop while switched; run it with the installer kubeconfig, which is the way back in. Writes `secrets/keycloak-users.env`, `secrets/keycloak-oidc.env` and `secrets/keycloak-oidc-backup/`. The lab has been switched permanently since 2026-11-24 (see CLAUDE.md); `rollback` is no longer part of the plan. |
| `lib-oidc-realm.sh` | Build a NEW cluster's Keycloak realm as a KeycloakRealmImport, from cluster.env, the `secrets/` files and the hub values rather than `secrets/keycloak-oidc-backup/`: console, `oc-cli`, gateway and Dev Spaces clients with the groups claim and cross-audience mappers, the users from `secrets/cluster-users.env` plus `maas-user`, and the groups and memberships from the hub values. Passwords and client secrets go in as realm-import placeholders backed by a `realm-secrets` Secret, never into the custom resource; missing `secrets/` files are generated in the format `cluster-users.sh` and `maas-user.sh` write. A library, not a phase: nothing calls it yet, `48-external-oidc.sh` will. |
| `cluster-power.sh` | Stop / start / status, with a cost breakdown. `stop` and `start` also stop and start the MaaS RDS database (`--keep-db` leaves it alone); `start` brings the database up first. Instances start one by one, so an instance EC2 refuses for capacity (often the GPU type) is named while the rest come up. `settle` (or `start --settle`) then waits for the API, approves node CSRs until every node is Ready, and restarts any gateway that never loaded its Kuadrant Wasm plugin (a gateway that starts before kuadrant-operator returns 503 for all MaaS traffic). |
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
48-external-oidc.sh {preflight|keycloak|switch|gateway|devspaces|smoke|all} [--dry-run]
90-destroy-cluster.sh [--with-vpc] [--purge] [--log-level <level>]
cluster-power.sh    {stop|start|status|settle} [--wait] [--keep-db] [--settle]
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

### External identity (AUTH_MODE)

Set at cluster build time: `oauth` signs people in through the built-in OAuth
server with htpasswd users, `oidc` through OpenShift direct authentication
against an in-cluster Keycloak realm (which removes the OAuth server,
`kubeadmin` and the `user.openshift.io` API; group membership comes from the
token's `groups` claim).

| Setting | Default | Notes |
|---|---|---|
| `AUTH_MODE` | `oauth` | `oauth` or `oidc`. Read by phase 45, which refuses `oauth` against a cluster already on OIDC. |
| `KEYCLOAK_NAMESPACE` | `keycloak-oidc-test` | namespace of the Keycloak operator, its database and the Keycloak CR |
| `KEYCLOAK_NAME` | `rhbk` | the Keycloak CR; its pod is `<name>-0` |
| `KEYCLOAK_REALM` | `rhoai` | the realm holding the clients, users and groups |
| `KEYCLOAK_ADMIN_SECRET` | `rhbk-initial-admin` | Secret holding the realm admin's credentials |
| `OIDC_TOKEN_LIFESPAN` | `300` | seconds. Web Terminal and Dev Spaces kubeconfig tokens are not refreshed, so they stop working after this. |
| `OIDC_CLIENT_CONSOLE` | `openshift-console` | |
| `OIDC_CLIENT_CLI` | `oc-cli` | public client `oc login` uses, with direct access grants for scripted logins |
| `OIDC_CLIENT_GATEWAY` | `rhoai-gateway` | the RHOAI gateway's client |
| `OIDC_CLIENT_DEVSPACES` | `devspaces` | |
| `OIDC_CLI_CALLBACK_PORTS` | `8080 8090` | localhost ports registered as `oc-cli` redirect URIs; `oc login --callback-port` must be one of them |
| `OIDC_SCRIPT_USER` | `danclark` | the realm user scripts get bearer tokens as (`lib-oc-token.sh`) |

The issuer URL is derived, not set here:
`https://keycloak-<KEYCLOAK_NAMESPACE>.<apps domain>/realms/<KEYCLOAK_REALM>`.
Phase 45 works it out from the live cluster's apps domain, falling back to
`BASE_DOMAIN`; setting `OIDC_ISSUER` in the environment overrides it.

### AWS

| Setting | Default |
|---|---|
| `VPC_STACK_NAME` | `rhoai-vpc` |
| `VPC_INFRA_NAME` | `rhoai` |
| `VPC_CIDR` | `10.0.0.0/16` |
| `VPC_AZ` | *(empty — first AZ in region)* |
| `GPU_INSTANCE_TYPE` | `g6.2xlarge` |

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

**Bearer tokens.** Scripts that call the MaaS API or need a token (`35-smoke-test.sh`, `30-verify-maas.sh`,
`40-lightspeed.sh`) get one through `scripts/lib-oc-token.sh`. On an OAuth cluster it logs in as kubeadmin
(and mints MaaS keys as the htpasswd `maas-user`). On a cluster with external OIDC
(`authentications.config.openshift.io` type `OIDC`) it gets Keycloak access tokens with the password grant
from the cluster's own issuer and `cli` client: cluster reads as `OIDC_SCRIPT_USER` (default `danclark`,
password from `secrets/cluster-users.env`), minting as `maas-user` (`secrets/maas-user.env`). Tokens last
5 minutes on the lab realm. The installer kubeconfig (client certificate) works in both modes.


| File | Contents |
|---|---|
| `secrets/aws.env` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` |
| `secrets/ibm.env` | `IC_API_KEY`, `IBMCLOUD_API_KEY` |
| `secrets/pull-secret.json` | Red Hat pull secret |
| `secrets/break-glass/rhoai-admin.kubeconfig` | The installer's client-certificate context, flattened, mode 600. The way in when Keycloak, its database or the router is down; it depends on no identity provider. |

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
| `openWebui.maas.model` | *(none)* | A model name from `openshiftAiModels.models`, offered directly next to Hermes. All Open WebUI users share its one key, so one `tokenRateLimit`. Sets `ENABLE_PERSISTENT_CONFIG=False`: Admin Panel settings then last until restart |
| `openWebui.maas.keyTtl` / `.renewBefore` | `720h` / `168h` | As for Hermes |

The model's `accessGroups` must include `system:serviceaccounts:hermes`, the
group Hermes mints its key as, and with `openWebui.maas`,
`system:serviceaccounts:open-webui`. Enable both with the `hermes-agent` and
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
