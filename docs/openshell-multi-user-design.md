# OpenShell for more than one user: design

Status: design only, nothing built. Written 2026-11-09 against OpenShell
`v0.1.6-rhaiv.4` (chart 0.1.6) on the sandbox141 hub. The upstream access
control and workspace documentation is identical in 0.1.6 and 0.1.7, so
everything below holds for 0.1.7 too.

## Where it stands today

The gateway runs with **no OIDC**. It authenticates callers by mutual TLS: the
CLI presents the client certificate cert-manager issued into Secret
`openshell/openshell-client-tls`. With no OIDC roles configured, the gateway
treats every authenticated caller as a **Platform Admin**. The workspace
authorization code returns a Platform Admin grant whenever `admin_role` is
empty, and the upstream docs say "Local gateways without OIDC role configuration
treat authenticated users as Platform Admins."

In practice:

- Only a cluster administrator can read that Secret, so only cluster
  administrators can use OpenShell (`scripts/openshell-cli.sh` runs the CLI with
  it).
- Everyone who can use it is a Platform Admin. There is one identity, no
  per-user audit at the gateway, and all sandboxes live in the `default`
  workspace in the `openshell` namespace.
- Every sandbox's model calls use one MaaS key, minted by the
  `openshell-maas-provider` ServiceAccount. MaaS attributes usage to the user
  who created an API key, so all OpenShell traffic shows up in MaaS as that one
  ServiceAccount, against one subscription's quota.

That is acceptable for a single operator. It does not let people use OpenShell
as themselves.

## What OpenShell supports

### Authentication

| Mode | When it applies | What it gives |
|---|---|---|
| mTLS | A client CA is configured and no OIDC issuer (today) | A verified certificate maps to a user principal. Without OIDC roles, every such user is a Platform Admin |
| OIDC, auth-only | `oidc.issuer` set, `admin_role` and `user_role` empty | Any valid JWT from the issuer is accepted, with no role distinction. Effectively everyone is a Platform Admin again |
| OIDC, RBAC | `oidc.issuer`, `roles_claim`, `admin_role` and `user_role` all set | The gateway checks the role claim on every call |
| Reverse-proxy termination | An access proxy authenticates in front of a gateway that serves plain HTTP | The gateway trusts the proxy. Not suitable here |

The gateway validates `Authorization: Bearer` JWTs against the issuer's JWKS
(RS256 and others, and EdDSA). The issuer must be HTTPS. Documented role claim
paths: Keycloak `realm_access.roles` (or a client's
`resource_access.<client>.roles`), Entra ID `roles`, Okta `groups`. Optional
scope enforcement uses `scopes_claim` with scopes such as `sandbox:write` and
`provider:write`.

The CLI signs in by browser or device code (people), or by client credentials
(automation).

### Roles and workspaces

A **workspace** is the isolation boundary. Sandboxes, sandbox templates,
providers, provider profiles, policies and settings belong to a workspace and
are invisible to other workspaces.

| Role | Granted by | Can |
|---|---|---|
| Platform Admin | The OIDC `admin_role` | Everything, in every workspace; platform profiles and global settings |
| Workspace Admin | An `admin` membership record in one workspace, kept by the gateway | Manage providers, profiles, policy, settings and members in that workspace |
| Workspace User | A `user` membership record in one workspace | Create and use sandboxes and services; read providers and attach them |

Membership records are keyed by the token's `sub`. A user needs both the OIDC
`user_role` and a membership record. The gateway creates the `default`
workspace but adds nobody to it.

On Kubernetes, `workspace_mode` maps workspaces to namespaces:

- `shared` (default, what runs today): one namespace for all workspaces.
- `managed`: a namespace per workspace, created by the gateway. Needs
  cluster-scoped RBAC.
- `operator`: pre-provisioned namespaces on an allowlist.

### Limits that shape the design

- **Sandboxes are not owned by a user.** Upstream: "provider and sandbox records
  are not owned by individual OIDC subjects. In shared clusters, treat provider
  credentials as gateway-wide resources and use separate gateways or external
  tenancy controls when users must not see or attach each other's providers and
  sandboxes." Within a workspace, members see each other's sandboxes. Per-user
  isolation means a workspace per user, or a gateway per team.
- **No group-to-workspace mapping.** Membership is per subject. Upstream issue
  [#4286](https://github.com/NVIDIA/OpenShell/issues/4286) asks for group
  bindings. Until then a sync job has to copy identity-provider groups into
  membership records (the `agent-ops` guide ships one).
- **The mTLS bundle stops signing anyone in once OIDC is on**
  ([#3564](https://github.com/NVIDIA/OpenShell/issues/3564)). Every automated
  caller, including this repo's scripts and the MaaS CronJob, has to move to an
  OIDC client credential.
- **CLI service-account sessions expire after five minutes** and the CLI tries to
  refresh instead of logging in again
  ([#4287](https://github.com/NVIDIA/OpenShell/issues/4287)). Scripts run
  `openshell gateway login` before each command.
- **`server.oidc.caConfigMapName` replaces all of the gateway's trust roots**
  ([#3672](https://github.com/NVIDIA/OpenShell/issues/3672)). With a private
  issuer CA, the ConfigMap must also carry the service CA and anything else the
  gateway calls.

## What Red Hat says

- **RHOAI 3.5 release notes**, Developer Preview: the OpenShell guide "covers
  Helm deployment, mTLS, LLM provider setup, isolated sandboxes, and controlled
  network egress", and points to the `agent-ops` repository. Nothing on OIDC or
  multiple users.
- **`agent-ops`** `install/02-user-auth.md` (midstream, "do not use in
  production"): the validated recipe.
  - Keycloak realm with a per-gateway API client carrying `admin` and `user`
    client roles.
  - Groups that grant the roles.
  - CLI and dashboard login clients, an automation account, and a read-only
    sync account.
  - The dashboard behind oauth2-proxy.
  - A script that turns group membership into workspace membership.
  - It runs Keycloak in dev mode and says to use the RHBK operator with a
    database for anything shared.
- **RHOAI 3.6 plan** (RHAISTRAT-2467, Release Pending; the decision dated
  2026-10-01 is "Option A v2"):
  - **One gateway per namespace, with the customer's own OIDC provider.**
    Keycloak is validated first, Entra ID next (RHOAIENG-98882).
  - **No OpenShift accounts for end users.**
  - Provider and sandbox records are gateway-wide, "so isolation means separate
    Gateways".
  - A standalone OpenShell UI per gateway behind oauth2-proxy, with no change to
    the RHOAI dashboard. An installer delivers it (RHAISTRAT-2715,
    RHOAIENG-97763).
  - Technology Preview, and FIPS clusters are excluded (RHAISTRAT-2717).
- **Later**: console integration and per-user token exchange are 3.7 follow-ups
  (RHAISTRAT-2183, "OpenShell user identity delegation via token exchange for
  user-scoped external services").

## Identity provider options

| Option | How | For | Against |
|---|---|---|---|
| A. OpenShift OAuth directly | Point the gateway's `oidc.issuer` at the cluster | Nothing new to run | **Not possible.** The built-in OAuth server issues opaque tokens and is not an OIDC issuer that a third party can validate with JWKS |
| B. OpenShift with an external OIDC provider | Switch the cluster to direct authentication against Keycloak (OpenShift 4.22, Authentication and authorization, chapter 8), and use the same issuer for OpenShell and MaaS | One identity and one token everywhere | Replaces the built-in OAuth server for the whole cluster: htpasswd users, `cluster-users.sh` and the Open WebUI OpenShift sign-in all change. One provider only. Chapter 9's advanced fields are Technology Preview, and in 4.19 the whole feature was (solution 7135920). Too large a change for OpenShell alone |
| C. RHBK as OpenShell's issuer, brokering OpenShift sign-in | An RHBK realm is the OIDC issuer for the gateway (and optionally MaaS). Its "Openshift v4" identity provider (RHBK Server Administration Guide, §9.4.10) sends people to the cluster's own login | People keep their cluster credentials and `cluster-users.sh` keeps working. Matches the `agent-ops` recipe and the 3.6 Keycloak path. The `rhbk` operator policy already exists in the fork | A Keycloak instance and database to run. Groups must be kept in Keycloak: brokering carries the login, and whether OpenShift group membership comes across needs testing. An `OAuthClient` and its secret on the cluster |
| D. A corporate identity provider directly | Entra ID or Okta as the gateway's issuer | What Red Hat documents for customers (3.6) | None available in an RHDP sandbox. Right for a customer cluster |

## Tenancy options

| Option | Isolation | Cost |
|---|---|---|
| T1. One gateway, one `default` workspace, everyone a member | None between users. Everyone sees every sandbox and provider | Smallest change |
| T2. One gateway, a workspace per team | Between teams; none within a team | A membership sync; a MaaS provider and template per workspace |
| T3. One gateway, a workspace per person | Between people | As T2, multiplied by users; Workspace Admins per person if people should manage their own providers |
| T4. A gateway per team, each in its own namespace | Complete, including providers: Red Hat's 3.6 isolation answer | The openshell policy deploys one gateway today; it would need to become multi-instance (namespace, route, OIDC client per gateway) |

`managed` workspace mode puts each workspace's sandboxes in their own namespace,
which helps quota and network policy per team, at the cost of cluster-scoped
RBAC for the gateway.

## MaaS: one shared key or per-user identity

What MaaS can do (Govern LLM access with Models-as-a-Service, RHOAI 3.5):

- It accepts both API keys and OIDC tokens.
- Usage is attributed to "the user who created the API key" or to "the user's
  OIDC identity".
- With external OIDC configured (§1.19), groups in the token select
  subscriptions, and so quotas.
- API keys keep the groups they had when created, until revoked or expired.

| Option | MaaS sees | Quota | Audit | Needs |
|---|---|---|---|---|
| M1. Shared key (today) | One ServiceAccount | One subscription, shared by all sandboxes | MaaS: none per user. OpenShell's OCSF logs show which sandbox made a request | Nothing |
| M2. A key per workspace | One ServiceAccount per workspace, minted by the CronJob | Still the model's subscription (ServiceAccount groups are per namespace), but usage is reported per workspace | Per workspace, in MaaS | The CronJob loops over workspaces: a ServiceAccount, key, provider and template in each |
| M3. Per-user token | The person, through token exchange: the sandbox's SPIFFE identity plus the user's token, exchanged at Keycloak for a MaaS-audience token | Per user, through groups in the token | Per user, in MaaS | MaaS external OIDC on the same issuer; ZTWIM (**not supported on FIPS clusters**, solution 7144070); the `agent-ops` keycloak-registrar prototype or RHAISTRAT-2183 once delivered |
| M4. People bring their own key | The person who minted it | Per user | Per user | Each person a Workspace Admin of their own workspace (Workspace Users cannot create providers), and their own key rotation |

## What the policies would have to change

For option C with T2 and M2, the smallest step that is really multi-user:

- **`rhbk`**:
  - Add a `Keycloak` CR backed by a database (RDS, as MaaS uses, or
    CloudNativePG).
  - Add a `KeycloakRealmImport`: realm `openshell`, the API client with `admin`
    and `user` client roles, a CLI public client (device code), an automation
    confidential client, a read-only sync client, and groups per workspace.
  - Add the "Openshift v4" identity provider, backed by an `OAuthClient` whose
    secret is generated in the cluster, never in Git.
  - The realm's CA must be one the gateway can verify.
- **`openshell` gateway values**:
  - `gatewayConfig.openshell.gateway.oidc.issuer`, `audience`,
    `roles_claim: resource_access.<api-client>.roles`, and `admin_role` and
    `user_role` (both, or the gateway stays auth-only).
  - `server.oidc.caConfigMapName`, pointing at a bundle that holds the ingress
    signer **and** the service CA (#3672).
  - Decide `server.tls.clientCaSecretName`: keep it, for transport only, or set
    `""`.
  - New config, `config.openshell.oidc`, and a label such as `openshell-auth`,
    validated like the others.
- **A membership sync**: a CronJob that reads the Keycloak groups with the sync
  client and creates or removes workspace membership records, until #4286.
- **`openshell-maas-provider` CronJob**: sign in with the automation client
  credential instead of the mTLS bundle, run `openshell gateway login` before
  each step (#4287), and loop over `config.openshell.workspaces`. Each gets its
  own ServiceAccount and key (M2), a `rhoai-maas` provider and a `rhoai-maas`
  template (both are workspace-scoped; the profile stays platform-scoped).
- **This repo's scripts**: `lib-openshell-cli.sh` signs in with the automation
  credential for administrative use. People use their own CLI with device code,
  or the 3.6 UI.
- **Model `accessGroups`**: unchanged for M2. For M3, the Keycloak groups.
- **Optional**: the 3.6 OpenShell UI chart (oauth2-proxy, loopback BFF, Route,
  NetworkPolicy) once its downstream image ships.

## Recommendation

1. **Identity: option C, RHBK as the issuer, brokering OpenShift sign-in.** It is
   the path Red Hat validated (Keycloak first, in `agent-ops` and the 3.6 plan),
   it keeps `cluster-users.sh` and htpasswd working, and the operator policy
   exists. Do not switch the cluster to external OIDC (B) for OpenShell; that is
   a cluster-wide decision with consequences well beyond it. On a customer
   cluster with a corporate identity provider, use D and skip the brokering.
2. **Tenancy: T2, a workspace per team, on the one gateway**, with the
   membership sync. Move to T4 only when a team must not be able to see another
   team's providers. That is Red Hat's own isolation answer, but it means making
   the openshell policy multi-instance.
3. **MaaS: M2, a key per workspace,** minted by the existing CronJob. It costs
   little, gives per-workspace usage in MaaS, and needs no new components. Plan
   for M3 when RHAISTRAT-2183 delivers token exchange as a product. Do not build
   M3 on the keycloak-registrar prototype, and never on a FIPS cluster, where
   ZTWIM is unsupported.
4. **Sequence**:
   1. RHBK instance and realm.
   2. Gateway OIDC in RBAC mode, together with the CronJob's switch to client
      credentials, in one change, because enabling OIDC breaks the mTLS sign-in
      the CronJob uses today.
   3. The membership sync.
   4. Per-workspace providers.
   5. Re-evaluate against the RHOAI 3.6 installer and UI when they ship, and
      prefer them to anything built here that they replace.
5. **Until then, leave it single-operator.** OpenShell is a Developer Preview,
   and the 3.6 Technology Preview changes the topology and the install. Building
   the full multi-user stack ahead of it risks rework.

## Sources

- OpenShell access control, v0.1.6 and v0.1.7:
  <https://github.com/NVIDIA/OpenShell/blob/v0.1.7/docs/kubernetes/access-control.mdx>
- OpenShell workspaces and roles:
  <https://github.com/NVIDIA/OpenShell/blob/v0.1.7/docs/how-it-works/workspaces.mdx>,
  <https://github.com/NVIDIA/OpenShell/blob/v0.1.7/docs/kubernetes/workspaces.mdx>
- OpenShell gateway authentication:
  <https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/how-it-works/gateways/authentication.mdx>
- Platform-admin default without OIDC roles: `crates/openshell-server/src/auth/workspace_authz.rs`, v0.1.6
- Upstream issues #4286 (group bindings), #3564 (mTLS alongside OIDC), #4287 (CLI session refresh), #3672 (OIDC CA replaces trust roots)
- `agent-ops` user authentication and agent identity guides:
  `install/02-user-auth.md`, `install/03-agent-identity.md`,
  `reference/workarounds.md`, <https://github.com/zanetworker/agent-ops>
- RHOAI 3.5 release notes, Developer Preview features:
  <https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/release_notes/index#developer-preview-features_relnotes>
- Govern LLM access with Models-as-a-Service, RHOAI 3.5 (§1.17.1.2 authentication methods, §1.18.1 usage monitoring, §1.19 external OIDC):
  <https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index>
- OpenShift 4.22 Authentication and authorization, chapters 8 and 9:
  <https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/authentication_and_authorization/index>;
  solution 7135920 (Technology Preview in 4.19)
- RHBK Server Administration Guide, "OpenShift 4" identity provider (§9.4.10 in 26.0):
  <https://access.redhat.com/documentation/en-us/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index>
- ZTWIM on FIPS: <https://access.redhat.com/solutions/7144070>
- Jira: RHAISTRAT-2467 (3.6 UI and the Option A v2 decision), RHAISTRAT-2715
  and RHOAIENG-97763 (installer), RHAISTRAT-2514 (topology), RHOAIENG-98882
  (OIDC provider docs), RHAISTRAT-2183 (token exchange), RHAISTRAT-2717 (FIPS)
