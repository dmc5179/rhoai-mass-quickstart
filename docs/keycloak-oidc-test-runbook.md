# Runbook: switching sandbox141 to Keycloak OIDC and back

Status: prepared 2026-11-11, **not yet run**. Purpose, scope and expected results are written before
the session so the session records results against them.

## What this session proves

| # | Question | Source of the claim today |
|---|---|---|
| a | With Keycloak issuing 5-minute access tokens, does the RHOAI gateway break after about 5 minutes when `GatewayConfig spec.cookie.refresh` is at its default `1h`, and does `4m` fix it? | Code: `getCookieSettings` defaults (rhods-operator `rhoai-3.5`), API field comment |
| b | On the switch, does the operator keep the old OpenShift OAuth client secret in `kube-auth-proxy-creds` and ignore `spec.oidc.clientSecretRef`, and does delete + `rollout restart` fix it? | Code: `getAuthProxySecretValues` (a known, partly fixed upgrade bug in the same function) |
| c | Does the end-to-end switch checklist work: console, `oc login`, dashboard, MaaS key minting and a model call, Gen AI playground, Lightspeed? | Docs, partly inferred |
| d | The points that document marks unverified: why the playground keeps working, whether MaaS accepts Keycloak tokens through TokenReview, what removing `spec.oidc` does on rollback | Inference |

The gateway mode cannot be switched on its own: the operator reads
`authentications.config.openshift.io/cluster` (`GetClusterAuthenticationMode`), so the whole cluster
moves to Keycloak for the session.

## Impact while switched

- The OpenShift OAuth server, `*.oauth.openshift.io` and `*.user.openshift.io` are gone (OCP 4.22
  section 8.1.1). **htpasswd logins stop**: `danclark`, `maas-user`, `kubeadmin`. People sign in
  through Keycloak instead, as the same user names.
- Scripts that log in as kubeadmin stop working: `35-smoke-test.sh`, `lib-oc-token.sh` callers,
  `maas-user.sh`. `keycloak-oidc.sh verify` replaces the smoke test for the session.
- **Open WebUI** signs people in through an oauth-proxy sidecar that is an OpenShift OAuth client
  (`serviceaccounts.openshift.io/oauth-redirectreference`). Expect its login to fail until rollback.
  Hermes behind it is unaffected for existing API traffic.
- **The installer kubeconfig keeps working** (client certificate). It is the only way back in; check
  it in preflight and do not lose the terminal that has it.

Cost: no AWS resources are created. Time: about 4.5 hours with the cluster on.

## AutoShift and ACM while switched

| Component | Expected | Recommendation |
|---|---|---|
| `htpasswd-users` policy (enforce, `pruneObjectBehavior: None`) | Its OAuth CR identity-provider entry is still applied (the CR remains; the server is gone). Its `Group` objects fail: `user.openshift.io` is not served, so the policy goes NonCompliant | **Accept NonCompliant; do not pause.** Pausing means a `hub.yaml` label change and a bootstrap now and another at rollback, and with `pruneObjectBehavior: None` turning the label off removes nothing anyway. Leaving it on means the rollback heals itself: once the Group API returns, the policy recreates the Groups and RoleBindings. Pausing would also add a second label-to-config change during the session, the ordering hazard from 2026-11-11 (memory: label-to-config migration lag) |
| `htpasswd`, `manual-remediations` (OAuth customization) | Disabled on this hub (`'false'`) | Nothing to do |
| `open-webui` policy | Compliant (it manages the Deployment, not the login) while logins fail | Accept; note in results |
| No policy manages `authentications.config.openshift.io` | The switch is not reverted by AutoShift | Confirmed by grep of the fork's `policies/` |
| ACM `local-cluster` (self-managed hub) | Klusterlet and add-ons use client certificates and service account tokens, not OAuth | **Unverified.** Watch `oc get managedclusters.cluster.open-cluster-management.io local-cluster` stays `Available` through steps 3-7; if it drops, roll back |
| ACM, GitOps and AutoShift consoles | Use the console session | Should follow the console's Keycloak login; record |

Expect the policy count to show 1-2 NonCompliant (`htpasswd-users`, possibly its test policy) for
the length of the window, and `scripts/cluster-users.sh status` to fail on the Groups part.

## Group and user names

`backup` reads every non-system group named by a ClusterRoleBinding or RoleBinding, a MaaS
subscription (`spec.owner.groups`) or a MaaS authorization policy (`spec.subjects.groups`), with the
members of the matching OpenShift Group objects. On sandbox141 that is expected to be `maas-users`
(maas-user, danclark) and `cluster-admins` (danclark). Those become realm groups and users with the
same names, and `switch-ocp` maps claims **without prefixes** (`preferred_username` with
`NoPrefix`, `groups` with no prefix). So every existing RoleBinding subject and MaaS group name keeps
matching. A customer who adds a `claimMappings.groups.prefix` must rename their MaaS subscription and
authorization-policy groups, and RBAC subjects, to the prefixed form; the session can show that by
re-running step 3 with a prefix (optional, step 8).

## Session plan

All commands from `~/workspace/rhoai-mass-aws`, with the installer kubeconfig. Each step logs to
`logs/keycloak-oidc-*.log`. Every command accepts `--dry-run`.

| Step | Command | Time | Go/no-go before the next step |
|---|---|---|---|
| 0 | `scripts/cluster-power.sh start --wait`; `scripts/checkup.sh` | 20 min | Checkup clean; all policies Compliant |
| 1 | `scripts/keycloak-oidc.sh preflight` then `backup`, then `preflight` again | 10 min | `system:admin` via certificate; backups present; `groups.json` lists the groups above |
| 2 | `scripts/keycloak-oidc.sh keycloak-install` | 25 min | Keycloak Ready; discovery HTTP 200; the printed test token shows `lifetime 300 s`, the right groups, and `aud` including all three clients |
| 3 | `scripts/keycloak-oidc.sh switch-ocp` | 30-45 min | kube-apiserver at the new revision on all nodes; `oc whoami` with a Keycloak token prints the user name; console shows the Keycloak login; `oc login --exec-plugin=oc-oidc ...` (printed) works; `local-cluster` Available |
| 4 | `scripts/keycloak-oidc.sh switch-gateway --keep-creds` | 10 min | See step 4 below; this is the reproduction of question b |
| 5 | `scripts/keycloak-oidc.sh switch-gateway --regen-creds` | 10 min | Dashboard login works in a private window |
| 6 | Cookie-refresh test, default then `4m` | 45 min | See step 6 below; question a |
| 7 | `scripts/keycloak-oidc.sh verify`; manual checks | 30 min | See step 7; questions c and d |
| 8 | Optional: groups prefix | 30 min | Only if time allows; adds a rollout |
| 9 | `scripts/keycloak-oidc.sh rollback` | 45 min | See Rollback; checkup clean |
| 10 | `scripts/keycloak-oidc.sh keycloak-uninstall` (optional); park | 10 min | |

### Step 4: reproduce the client-secret reuse (question b)

`switch-gateway --keep-creds` creates the gateway client Secret and CA Secret, patches
`GatewayConfig default-gateway` exactly as RHOAI 3.5 *Administer platform access* section 10.2
describes, and leaves `kube-auth-proxy-creds` alone. It prints the before and after client ID and a
hash of the client secret.

Expected if the code reading is right:

- `kube-auth-proxy-creds` client ID becomes `rhoai-gateway` (after the earlier upgrade-bug fix), but the client
  secret hash is **unchanged** and differs from Keycloak's.
- Signing in to the dashboard in a private window: Keycloak login succeeds, then the callback fails;
  kube-auth-proxy logs a token-exchange error with `unauthorized_client` or `invalid_client`.
- `GatewayConfig` still reports Ready.

Capture the log lines and the browser error. If the client secret did change and login works, the
reuse does not happen on 3.5.2: record that and correct the draft
`docs/jira-drafts/rhoai-gateway-oidc-clientsecretref-ignored.md`.

### Step 5: the workaround

`switch-gateway --regen-creds` deletes `kube-auth-proxy-creds`, waits for the operator to regenerate
it, then runs `oc rollout restart deployments.apps/kube-auth-proxy -n openshift-ingress`. Expected:
the client secret hash now matches Keycloak's and the dashboard login works. Also note whether
the pods restarted **before** the manual restart (the automatic restart sometimes does not
fire).

### Step 6: cookie refresh against the 5-minute token (question a)

Manual browser procedure, twice: first with the default, then with `4m`.

1. `scripts/keycloak-oidc.sh cookie-refresh default`; confirm it prints `--cookie-refresh=1h`.
2. Open a private window with developer tools (Network tab, "Preserve log" on). Go to the dashboard
   URL (`https://<data-science-gateway host>/`), sign in as `maas-user`. **Note the time (T).**
3. At T+2, T+6 and T+12 minutes, reload a dashboard page that calls the API (for example Models or
   Settings) and click into one project. For each, record:
   - the status of the `/api/...` XHR requests (200, 401, 403, or a redirect to Keycloak);
   - any dashboard error banner;
   - `oc logs deployments.apps/kube-auth-proxy -n openshift-ingress --since=3m | grep -iE 'refresh|expired|invalid|401|403'`.
4. `scripts/keycloak-oidc.sh cookie-refresh 4m`; confirm `--cookie-refresh=4m0s` (or `4m`). Sign out,
   close the window, and repeat 2-3 in a new private window.

Expected: with `1h`, API calls start failing or redirecting shortly after T+5, because the
session's access token has expired and kube-auth-proxy does not refresh it for an hour; with `4m`,
every call succeeds through T+12. A full-page reload may hide the problem by bouncing through
Keycloak's still-valid SSO session, which is why the XHR status matters more than whether the page
renders. Record exactly what is seen; a result different from the expectation changes the draft
`docs/jira-drafts/rhoai-docs-gateway-cookie-refresh.md`.

Optional, **experimental**: `scripts/keycloak-oidc.sh verify --watch-session` logs in through
kube-auth-proxy with curl (Keycloak login form, cookie jar) and calls `/api/config` with only the
session cookie at T+0, 2, 6 and 12 minutes, without following redirects. Run it once per setting.
It depends on parsing Keycloak's login page; if it cannot find the form it says so and the manual
procedure stands.

### Step 7: the switch checklist and the open questions (questions c, d)

`scripts/keycloak-oidc.sh verify` (optionally `--user maas-user`):

- `oc whoami` with the Keycloak **ID** token and with the **access** token; the groups the API
  server sees (`oc auth whoami`).
- MaaS: mint a key with each token at `/maas-api/v1/api-keys`. This answers whether maas-api's
  TokenReview accepts Keycloak tokens, and with which audience. A 401 for one token type and 201 for
  the other is a real finding to record. Then a chat completion with the minted key,
  and the key revoked.
- kube-auth-proxy args and GatewayConfig conditions; the dashboard API with the ID token as a bearer.

By hand, in a browser signed in through Keycloak:

| Check | Expected | Record |
|---|---|---|
| OpenShift console as `danclark` | Keycloak login; cluster-admin views available (Group `cluster-admins` from the claim) | |
| Dashboard as `maas-user` | Projects visible per RBAC | |
| Dashboard: Gen AI studio > Playground, project `llm` | Chat works | Whether it uses an existing MaaS key, mints a new one, or the user's token (dashboard network tab) - this settles the "kept working" explanation |
| Dashboard: API keys page | Lists keys; creating one works | |
| Lightspeed in the console | Answers | Whether its backend accepts the Keycloak token |
| Open WebUI | Login fails (OpenShift OAuth client) | Error text |
| ACM console, `local-cluster` | Available | |

### Step 8 (optional): a groups prefix

Re-run step 3 with `claimMappings.groups.prefix: 'oidc:'` by editing the patch, wait for the
rollout, and show that `maas-user` loses MaaS access (`verify` mint returns 403) until the
subscription group is renamed to `oidc:maas-users`. Revert before rollback. Adds 40 minutes.

## Rollback

`scripts/keycloak-oidc.sh rollback`:

1. `oc patch authentications.config.openshift.io/cluster --type=merge -p '{"spec":{"type":"","oidcProviders":null}}'`
   (OCP 4.22 section 8.3), puts back a `webhookTokenAuthenticator` if the backup had one, and waits
   for the kube-apiserver rollout (up to 40 min).
2. Removes `spec.oidc`, `spec.providerCASecretName` and `spec.cookie.refresh` from
   `GatewayConfig default-gateway`, deletes `kube-auth-proxy-creds`, waits for it to be regenerated,
   restarts kube-auth-proxy, and checks the client ID is back to `data-science`.
3. `scripts/50-autoshift.sh bootstrap` and `refresh`, then `scripts/cluster-users.sh status` and
   `scripts/checkup.sh`.

Go/no-go after rollback: `oc login` as `danclark` with the htpasswd password works; the dashboard
logs in through OpenShift; Open WebUI logs in; all policies Compliant (Groups recreated by
`htpasswd-users`); MaaS smoke test (`scripts/35-smoke-test.sh`) passes.

Record for question d: whether removing `spec.oidc` alone returned the gateway to integrated mode
(the cluster mode is what decides it, so it should follow step 1), and whether the regenerated
secret needed the manual restart.

**If the API is unreachable with Keycloak tokens and the console is down**, the installer
kubeconfig still works: run step 1 by hand with it. If that kubeconfig is also lost, recovery means
a new kubeconfig from the node's localhost-recovery credentials; avoid this by keeping the file and
checking it in preflight.

`keycloak-uninstall` then removes the realm, Keycloak, its operator and namespace, and the CA and
client Secrets in `openshift-config` and `openshift-ingress`. It refuses while the cluster or the
GatewayConfig still points at Keycloak. `secrets/keycloak-*.env` and
`secrets/keycloak-oidc-backup/` stay until deleted by hand.

## What the script sets up

| Item | Value |
|---|---|
| Namespace | `keycloak-oidc-test` |
| Operator | `rhbk-operator` from `redhat-operators`, default channel read from the package manifest at run time, OwnNamespace |
| Database | `registry.redhat.io/rhel9/postgresql-16`, 1 Gi PVC (test only) |
| Keycloak | CR `rhbk`, HTTP behind an edge Route `keycloak-keycloak-oidc-test.<apps domain>` on the default ingress certificate |
| Trust | The default ingress CA (`openshift-config-managed/default-ingress-cert`) as ConfigMap `openshift-config/keycloak-oidc-ca` (`issuerCertificateAuthority`) and Secret `openshift-ingress/keycloak-oidc-ca` (`GatewayConfig spec.providerCASecretName`) |
| Realm | `rhoai`, `accessTokenLifespan: 300`, groups claim (`oidc-group-membership-mapper`, no full path), audience mappers so every token carries all three client IDs |
| Clients | `openshift-console` (confidential, `https://<console>/auth/callback`), `oc-cli` (public, `http://localhost:8080`, direct access grants on for scripted test logins only), `rhoai-gateway` (confidential, `https://<gateway host>/oauth2/callback`) |
| Secrets | Client secrets and user passwords generated into `secrets/`, passed to the realm through `KeycloakRealmImport` placeholders, never in a CR |

## Unverified before the session

- `issuerCertificateAuthority` takes a ConfigMap in `openshift-config` with key `ca-bundle.crt`
  (as the internal OAuth CA does); the script uses that.
- `rhbk-operator` is the package name in the 4.22 `redhat-operators` catalog; `keycloak-install`
  stops with a clear message if it is not.
- The Keycloak service name `rhbk-service` and port name `http` used by the Route.
- Whether kube-auth-proxy passes the ID token or the access token upstream; the audience mappers
  make both acceptable to the API server either way.
- The ACM self-managed hub's independence from OAuth.
