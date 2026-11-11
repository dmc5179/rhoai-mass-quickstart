#!/usr/bin/env bash
#
# keycloak-oidc.sh - switch this cluster from the OpenShift OAuth server to a
#                    Keycloak realm (direct OIDC), test the RHOAI gateway against
#                    it, and switch back. A test harness, not a production setup.
#
# Usage: scripts/keycloak-oidc.sh <command> [options] [--dry-run]
#
# Commands, in session order (docs/keycloak-oidc-test-runbook.md):
#   preflight                 Installer kubeconfig in use and certificate-based,
#                             cluster healthy, backups present.
#   backup                    Save the auth configuration and the group and user
#                             names RBAC and MaaS refer to (secrets/keycloak-oidc-backup/).
#   keycloak-install          Red Hat build of Keycloak operator, a PostgreSQL, a
#                             Keycloak, and realm "rhoai" (300 s access tokens).
#   switch-ocp                authentications.config.openshift.io/cluster -> type OIDC.
#                             Removes the OAuth server, users, groups, htpasswd logins.
#   switch-gateway --keep-creds | --regen-creds
#                             GatewayConfig default-gateway -> spec.oidc.
#                             --keep-creds leaves kube-auth-proxy-creds in place, to
#                             reproduce the reuse bug; --regen-creds deletes it and
#                             restarts kube-auth-proxy (the workaround).
#   cookie-refresh <duration|default>
#                             Set (e.g. 4m) or remove GatewayConfig spec.cookie.refresh,
#                             and show kube-auth-proxy's --cookie-refresh.
#   verify [--watch-session]  Non-browser checks with Keycloak tokens: oc, MaaS key
#                             minting, a model call, gateway status. --watch-session
#                             is EXPERIMENTAL: a scripted browser login through
#                             kube-auth-proxy, then dashboard API calls at T+2/6/12 min.
#   rollback                  OCP back to the OAuth server (OCP 4.22 section 8.3),
#                             GatewayConfig back to integrated OAuth, AutoShift
#                             bootstrap + refresh, checkup.
#   keycloak-uninstall        Remove Keycloak and the CA/client Secrets. Refuses while
#                             the cluster still points at it.
#   status                    What is switched right now.
#
# Options:
#   --dry-run    Print what would be applied. Makes no cluster or AWS calls;
#                values discovered from the cluster are shown as <placeholders>.
#   --user <u>   For verify: the realm user to test as (default: first user).
#
# Secrets (umask 077, gitignored):
#   secrets/keycloak-users.env       realm user passwords, generated
#   secrets/keycloak-oidc.env        client secrets and the PostgreSQL password
#   secrets/keycloak-oidc-backup/    the pre-switch configuration, including the
#                                    kube-auth-proxy-creds Secret
#
# Always run with the installer kubeconfig (clusters/<CLUSTER_NAME>/auth/kubeconfig,
# certificate-based). It is the way back in once the OAuth server is gone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

usage() { sed -n '2,49p' "${BASH_SOURCE[0]}"; }

case "${1:-}" in
    ""|-h|--help) usage; exit 0 ;;
esac
ACTION="$1"; shift

DRY_RUN=0
CREDS_MODE=""
COOKIE_VALUE=""
TEST_USER=""
WATCH_SESSION=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)       DRY_RUN=1; shift ;;
        --keep-creds)    CREDS_MODE="keep"; shift ;;
        --regen-creds)   CREDS_MODE="regen"; shift ;;
        --user)          TEST_USER="${2:?--user needs a value}"; shift 2 ;;
        --watch-session) WATCH_SESSION=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*) echo "keycloak-oidc.sh: unknown option '$1'" >&2; exit 2 ;;
        *)  if [ "$ACTION" = "cookie-refresh" ] && [ -z "$COOKIE_VALUE" ]; then
                COOKIE_VALUE="$1"; shift
            else
                echo "keycloak-oidc.sh: unexpected argument '$1'" >&2; exit 2
            fi ;;
    esac
done

case "$ACTION" in
    preflight|backup|keycloak-install|switch-ocp|verify|rollback|keycloak-uninstall|status) ;;
    switch-gateway)
        [ -n "$CREDS_MODE" ] || { echo "switch-gateway needs --keep-creds or --regen-creds" >&2; exit 2; } ;;
    cookie-refresh)
        [ -n "$COOKIE_VALUE" ] || { echo "cookie-refresh needs a duration (e.g. 4m) or 'default'" >&2; exit 2; }
        if [ "$COOKIE_VALUE" != "default" ] && ! [[ "$COOKIE_VALUE" =~ ^[0-9]+(s|m|h)$ ]]; then
            echo "cookie-refresh: '$COOKIE_VALUE' is not a duration like 30s, 4m or 1h" >&2; exit 2
        fi ;;
    *) echo "keycloak-oidc.sh: unknown command '$ACTION' (see --help)" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "keycloak-oidc" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

for c in jq curl python3; do
    command -v "$c" >/dev/null || { echo "Error: '$c' is not installed." >&2; exit 1; }
done

umask 077
KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
export KUBECONFIG

# --- fixed names -------------------------------------------------------------
KC_NS="keycloak-oidc-test"
KC_NAME="rhbk"
REALM="rhoai"
TOKEN_LIFESPAN=300                          # Keycloak's default, stated explicitly
CLIENT_CONSOLE="openshift-console"          # confidential, OCP web console
CLIENT_CLI="oc-cli"                         # public, oc login (and scripted tests)
CLIENT_GATEWAY="rhoai-gateway"              # confidential, RHOAI kube-auth-proxy
OIDC_PROVIDER_NAME="keycloak-test"
CA_CONFIGMAP="keycloak-oidc-ca"             # openshift-config, key ca-bundle.crt
CONSOLE_SECRET="keycloak-console-client"    # openshift-config, key clientSecret
GATEWAY_SECRET="keycloak-gateway-client"    # openshift-ingress, key clientSecret
GATEWAY_CA_SECRET="keycloak-oidc-ca"        # openshift-ingress, key ca.crt
GW_CONFIG="gatewayconfigs.services.platform.opendatahub.io/default-gateway"
AUTH_CFG="authentications.config.openshift.io/cluster"
BACKUP_DIR="${ROOT}/secrets/keycloak-oidc-backup"
USERS_ENV="${ROOT}/secrets/keycloak-users.env"
OIDC_ENV="${ROOT}/secrets/keycloak-oidc.env"
CA_FILE="${BACKUP_DIR}/ingress-ca.crt"

# --- helpers -----------------------------------------------------------------
dry() { [ "$DRY_RUN" -eq 1 ]; }
step() { echo; echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

# discover <placeholder> <command...>: run a read-only query, or return the
# placeholder in --dry-run so no cluster call is made.
discover() {
    local ph="$1"; shift
    if dry; then echo "<${ph}>"; else "$@"; fi
}

# apply_yaml <description>: manifest on stdin -> oc apply, or printed in --dry-run.
apply_yaml() {
    local what="$1" body
    body="$(cat)"
    if dry; then
        echo "--- [dry-run] would apply: ${what}"; echo "$body"
    else
        "$OC" apply -f - <<<"$body" >/dev/null && echo "    applied: ${what}"
    fi
}

# run <command...>: execute, or print in --dry-run.
run() {
    if dry; then echo "--- [dry-run] would run: $*"; else "$@"; fi
}

# A random secret value, never echoed.
gen_secret() { python3 -I -c 'import secrets; print(secrets.token_urlsafe(24))'; }

# env_get <file> <VAR>: read one value from an env file in a subshell.
# shellcheck disable=SC1090  # the file is one of the secrets/*.env files above
env_get() { ( set +u; . "$1"; eval "printf '%s' \"\${$2:-}\"" ); }

require_api() {
    dry && return 0
    "$OC" get --raw /readyz >/dev/null 2>&1 || die "cluster API not reachable via ${KUBECONFIG}."
}

cluster_domain() { discover apps-domain "$OC" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'; }
kc_host() { echo "keycloak-${KC_NS}.$(cluster_domain)"; }
issuer_url() { echo "https://$(kc_host)/realms/${REALM}"; }
console_host() { discover console-host "$OC" get routes.route.openshift.io console -n openshift-console -o jsonpath='{.spec.host}'; }
gateway_host() {
    discover rhoai-gateway-host sh -c "\"$OC\" get gateways.gateway.networking.k8s.io data-science-gateway -n openshift-ingress -o jsonpath='{range .spec.listeners[*]}{.hostname}{\"\\n\"}{end}' | grep -v '^\$' | head -1"
}
auth_type() { discover auth-type "$OC" get "$AUTH_CFG" -o jsonpath='{.spec.type}'; }

# Wait until kube-apiserver has rolled a newer revision to every node.
wait_kas_rollout() {
    local before="$1" deadline=$(( $(date +%s) + 2400 )) latest pending
    dry && { echo "--- [dry-run] would wait up to 40 min for kube-apiserver revision > ${before} on all nodes"; return 0; }
    echo "    waiting for kube-apiserver to roll past revision ${before} (up to 40 min)"
    while :; do
        latest="$("$OC" get kubeapiservers.operator.openshift.io cluster -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null || echo 0)"
        pending="$("$OC" get kubeapiservers.operator.openshift.io cluster -o json 2>/dev/null \
            | jq --argjson l "${latest:-0}" '[.status.nodeStatuses[] | select(.currentRevision != $l)] | length' 2>/dev/null || echo 99)"
        if [ "${latest:-0}" -gt "$before" ] && [ "$pending" = "0" ] \
           && [ "$("$OC" get clusteroperators.config.openshift.io kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" = "False" ]; then
            echo "    kube-apiserver at revision ${latest} on all nodes"; return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || die "kube-apiserver rollout did not finish in 40 min (latest ${latest}, ${pending} nodes behind). Check: oc get co kube-apiserver authentication"
        sleep 30
    done
}

kas_revision() { discover 0 "$OC" get kubeapiservers.operator.openshift.io cluster -o jsonpath='{.status.latestAvailableRevision}'; }

# kc_token <user> <id|access>: a token for a realm user from the public oc-cli
# client (direct access grant, enabled for this test realm only).
kc_token() {
    local user="$1" kind="$2" pw
    pw="$(env_get "$USERS_ENV" "KC_PW_$(echo "$user" | tr -c 'A-Za-z0-9\n' '_')")"
    [ -n "$pw" ] || die "no password for ${user} in ${USERS_ENV}"
    curl -sS --cacert "$CA_FILE" --max-time 20 \
        --data-urlencode "grant_type=password" --data-urlencode "client_id=${CLIENT_CLI}" \
        --data-urlencode "username=${user}" --data-urlencode "password=${pw}" \
        --data-urlencode "scope=openid" \
        "$(issuer_url)/protocol/openid-connect/token" | jq -r ".${kind}_token // empty"
}

first_user() { sed -n 's/^KC_USER_[0-9]*="\(.*\)"$/\1/p' "$USERS_ENV" | head -1; }

# --- commands ----------------------------------------------------------------
cmd_status() {
    require_api
    step "Authentication type: $(auth_type)  (empty = OpenShift OAuth server, OIDC = direct)"
    dry && return 0
    "$OC" get "$AUTH_CFG" -o jsonpath='{range .spec.oidcProviders[*]}    provider {.name}: {.issuer.issuerURL}{"\n"}{end}'
    step "GatewayConfig default-gateway"
    "$OC" get "$GW_CONFIG" -o json | jq '{oidc: .spec.oidc, cookie: .spec.cookie, providerCASecretName: .spec.providerCASecretName, conditions: [.status.conditions[]? | {type, status, reason}]}'
    step "kube-auth-proxy"
    "$OC" get deployments.apps kube-auth-proxy -n openshift-ingress -o json \
        | jq -r '.spec.template.spec.containers[0].args[] | select(test("cookie-refresh|cookie-expire|oidc-issuer|provider="))' | sed 's/^/    /'
    printf '    kube-auth-proxy-creds client ID: '
    "$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_ID}' 2>/dev/null | base64 -d || echo "(absent)"
    echo
    step "Keycloak: $("$OC" get keycloaks.k8s.keycloak.org "$KC_NAME" -n "$KC_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo absent)"
}

cmd_preflight() {
    require_api
    step "Installer kubeconfig"
    [ -f "$KUBECONFIG" ] || die "${KUBECONFIG} not found"
    grep -q "client-certificate-data" "$KUBECONFIG" || die "${KUBECONFIG} is not certificate-based; it would stop working after the switch"
    local who="system:admin"
    dry || who="$("$OC" whoami)"
    [ "$who" = "system:admin" ] || die "oc whoami is '${who}', expected system:admin from the installer kubeconfig"
    echo "    ${KUBECONFIG} (certificate), oc whoami = ${who}"
    step "Cluster health"
    if dry; then echo "--- [dry-run] would check clusteroperators, nodes and policy compliance"; else
        local bad
        bad="$("$OC" get clusteroperators.config.openshift.io --no-headers | awk '$3!="True" || $4!="False" || $5!="False"' | wc -l)"
        [ "$bad" -eq 0 ] || die "${bad} cluster operators are not Available/settled: oc get co"
        [ "$("$OC" get nodes --no-headers | awk '$2!="Ready"' | wc -l)" -eq 0 ] || die "not every node is Ready"
        echo "    cluster operators and nodes healthy"
        echo "    policies not Compliant: $("$OC" get policies.policy.open-cluster-management.io -n local-cluster -o jsonpath='{range .items[*]}{.status.compliant}{"\n"}{end}' | grep -vc '^Compliant$' || true)"
    fi
    step "Current state"
    echo "    authentication type: '$(auth_type)'"
    step "Backups"
    if [ -s "${BACKUP_DIR}/authentication.yaml" ] && [ -s "${BACKUP_DIR}/groups.json" ]; then
        echo "    present in ${BACKUP_DIR} (taken $(stat -c %y "${BACKUP_DIR}/authentication.yaml" | cut -d. -f1))"
    else
        echo "    MISSING - run: scripts/keycloak-oidc.sh backup"
    fi
}

cmd_backup() {
    require_api
    [ "$(auth_type)" != "OIDC" ] || die "the cluster is already on direct OIDC; a backup now would not capture the OAuth configuration"
    if dry; then echo "--- [dry-run] would write the backup to ${BACKUP_DIR}"; return 0; fi
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    step "Saving configuration to ${BACKUP_DIR}"
    "$OC" get "$AUTH_CFG" -o yaml > "${BACKUP_DIR}/authentication.yaml"
    "$OC" get oauths.config.openshift.io cluster -o yaml > "${BACKUP_DIR}/oauth.yaml"
    "$OC" get "$GW_CONFIG" -o yaml > "${BACKUP_DIR}/gatewayconfig.yaml"
    "$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o yaml > "${BACKUP_DIR}/kube-auth-proxy-creds.yaml" 2>/dev/null || echo "    (kube-auth-proxy-creds absent)"
    "$OC" get odhdashboardconfigs.opendatahub.io -A -o yaml > "${BACKUP_DIR}/odhdashboardconfig.yaml" 2>/dev/null || true
    "$OC" get maassubscriptions.maas.opendatahub.io -A -o json > "${BACKUP_DIR}/maassubscriptions.json" 2>/dev/null || echo '{"items":[]}' > "${BACKUP_DIR}/maassubscriptions.json"
    "$OC" get maasauthpolicies.maas.opendatahub.io -A -o json > "${BACKUP_DIR}/maasauthpolicies.json" 2>/dev/null || echo '{"items":[]}' > "${BACKUP_DIR}/maasauthpolicies.json"
    "$OC" get groups.user.openshift.io -o json > "${BACKUP_DIR}/openshift-groups.json"
    "$OC" get clusterrolebindings.rbac.authorization.k8s.io,rolebindings.rbac.authorization.k8s.io -A -o json > "${BACKUP_DIR}/bindings.json"
    "$OC" get configmaps default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_FILE"
    [ -s "$CA_FILE" ] || die "could not read the default ingress CA"

    step "Group and user names that RBAC and MaaS refer to"
    # Every non-system group named by a binding, a MaaS subscription or a MaaS
    # authorization policy, with its members from the OpenShift Group objects.
    # These become realm groups, so the groups claim matches what is already
    # bound (no claimMappings prefix). Users named directly are kept too.
    python3 -I - "$BACKUP_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
load = lambda f: json.load(open(os.path.join(d, f)))
members = {g["metadata"]["name"]: g.get("users") or [] for g in load("openshift-groups.json")["items"]}
groups, users = {}, set()
def add(name, src):
    if name and not name.startswith("system:"):
        groups.setdefault(name, set()).add(src)
for b in load("bindings.json")["items"]:
    for s in b.get("subjects") or []:
        if s.get("kind") == "Group": add(s["name"], "rbac")
        if s.get("kind") == "User" and ":" not in s["name"] and s["name"] != "kube:admin": users.add(s["name"])
for s in load("maassubscriptions.json")["items"]:
    o = s.get("spec", {}).get("owner", {})
    for g in o.get("groups") or []: add(g.get("name"), "maas-subscription")
    users.update(o.get("users") or [])
for p in load("maasauthpolicies.json")["items"]:
    sj = p.get("spec", {}).get("subjects", {})
    for g in sj.get("groups") or []: add(g.get("name"), "maas-authpolicy")
    users.update(sj.get("users") or [])
out = {"groups": {}, "users": sorted(users)}
for g in sorted(groups):
    out["groups"][g] = {"sources": sorted(groups[g]), "members": members.get(g, [])}
    users.update(members.get(g, []))
out["users"] = sorted(u for u in users if u and not u.startswith("system:"))
json.dump(out, open(os.path.join(d, "groups.json"), "w"), indent=2)
for g, v in out["groups"].items():
    print(f"    {g:30} {','.join(v['sources']):40} members: {', '.join(v['members']) or '-'}")
print(f"    users: {', '.join(out['users'])}")
PY
    chmod 600 "${BACKUP_DIR}"/*
    echo "    backup complete"
}

cmd_keycloak_install() {
    require_api
    [ -s "${BACKUP_DIR}/groups.json" ] || dry || die "run 'backup' first; the realm is built from its group list"

    step "Generating secrets (kept if they already exist)"
    if dry; then echo "--- [dry-run] would create ${OIDC_ENV} and ${USERS_ENV}"; else
        if [ ! -s "$OIDC_ENV" ]; then
            printf 'CONSOLE_CLIENT_SECRET="%s"\nGATEWAY_CLIENT_SECRET="%s"\nDB_PASSWORD="%s"\n' \
                "$(gen_secret)" "$(gen_secret)" "$(gen_secret)" > "$OIDC_ENV"
        fi
        if [ ! -s "$USERS_ENV" ]; then
            local i=0 u
            for u in $(jq -r '.users[]' "${BACKUP_DIR}/groups.json"); do
                printf 'KC_USER_%d="%s"\nKC_PW_%s="%s"\n' "$i" "$u" "$(echo "$u" | tr -c 'A-Za-z0-9\n' '_')" "$(gen_secret)"
                i=$((i + 1))
            done > "$USERS_ENV"
        fi
        chmod 600 "$OIDC_ENV" "$USERS_ENV"
        echo "    ${OIDC_ENV}, ${USERS_ENV}"
    fi

    step "Namespace and the Red Hat build of Keycloak operator"
    local channel
    channel="$(discover rhbk-default-channel "$OC" get packagemanifests.packages.operators.coreos.com rhbk-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')"
    [ -n "$channel" ] || die "package rhbk-operator not found in the catalogs"
    apply_yaml "namespace, OperatorGroup, Subscription (channel ${channel})" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${KC_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${KC_NS}
  namespace: ${KC_NS}
spec:
  targetNamespaces: [${KC_NS}]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${KC_NS}
spec:
  name: rhbk-operator
  channel: ${channel}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    if ! dry; then
        local deadline=$(( $(date +%s) + 600 ))
        until "$OC" get csv -n "$KC_NS" --no-headers 2>/dev/null | grep -q 'rhbk-operator.*Succeeded'; do
            [ "$(date +%s)" -lt "$deadline" ] || die "the rhbk-operator CSV did not reach Succeeded in 10 min: oc get csv -n ${KC_NS}"
            sleep 10
        done
        echo "    rhbk-operator Succeeded"
    fi

    step "PostgreSQL for Keycloak (registry.redhat.io/rhel9/postgresql-16, test only)"
    local dbpw="<generated>"
    dry || dbpw="$(env_get "$OIDC_ENV" DB_PASSWORD)"
    if dry; then echo "--- [dry-run] would create Secret ${KC_NS}/keycloak-db (username keycloak, password from ${OIDC_ENV})"; else
        "$OC" create secret generic keycloak-db -n "$KC_NS" \
            --from-literal=username=keycloak --from-file=password=<(printf '%s' "$dbpw") \
            --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    fi
    apply_yaml "PostgreSQL PVC, Deployment, Service" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: keycloak-db, namespace: ${KC_NS}}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak-db, namespace: ${KC_NS}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: keycloak-db}}
  template:
    metadata: {labels: {app: keycloak-db}}
    spec:
      containers:
        - name: postgresql
          image: registry.redhat.io/rhel9/postgresql-16:latest
          env:
            - {name: POSTGRESQL_DATABASE, value: keycloak}
            - name: POSTGRESQL_USER
              valueFrom: {secretKeyRef: {name: keycloak-db, key: username}}
            - name: POSTGRESQL_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-db, key: password}}
          ports: [{containerPort: 5432}]
          readinessProbe: {exec: {command: [pg_isready, -h, localhost]}, periodSeconds: 10}
          volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: keycloak-db}}]
---
apiVersion: v1
kind: Service
metadata: {name: keycloak-db, namespace: ${KC_NS}}
spec:
  selector: {app: keycloak-db}
  ports: [{port: 5432, targetPort: 5432}]
EOF

    step "Keycloak, served over HTTP behind an edge Route on the default ingress certificate"
    local host; host="$(kc_host)"
    apply_yaml "Keycloak ${KC_NAME} and Route" <<EOF
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata: {name: ${KC_NAME}, namespace: ${KC_NS}}
spec:
  instances: 1
  db:
    vendor: postgres
    host: keycloak-db
    database: keycloak
    usernameSecret: {name: keycloak-db, key: username}
    passwordSecret: {name: keycloak-db, key: password}
  http:
    httpEnabled: true
  hostname:
    hostname: https://${host}
  proxy:
    headers: xforwarded
  ingress:
    enabled: false
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: keycloak, namespace: ${KC_NS}}
spec:
  host: ${host}
  to: {kind: Service, name: ${KC_NAME}-service}
  port: {targetPort: http}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Redirect}
EOF
    if ! dry; then
        "$OC" wait keycloaks.k8s.keycloak.org/"$KC_NAME" -n "$KC_NS" --for=condition=Ready --timeout=10m >/dev/null \
            || die "Keycloak did not become Ready: oc get keycloaks.k8s.keycloak.org -n ${KC_NS} -o yaml"
        echo "    Keycloak Ready at https://${host}"
    fi

    step "Realm ${REALM}: ${TOKEN_LIFESPAN}s access tokens, groups claim, three clients, test users"
    # Secret values go in through KeycloakRealmImport placeholders, never into the CR.
    local chost ghost
    chost="$(console_host)"; ghost="$(gateway_host)"
    if dry; then echo "--- [dry-run] would create Secret ${KC_NS}/realm-secrets from ${OIDC_ENV} and ${USERS_ENV}"; else
        # One file per key in a private directory; values never reach a command line.
        local sdir k; sdir="$(mktemp -d)"
        env_get "$OIDC_ENV" CONSOLE_CLIENT_SECRET > "${sdir}/CONSOLE_CLIENT_SECRET"
        env_get "$OIDC_ENV" GATEWAY_CLIENT_SECRET > "${sdir}/GATEWAY_CLIENT_SECRET"
        while read -r k; do
            env_get "$USERS_ENV" "$k" > "${sdir}/${k}"
        done < <(sed -n 's/^\(KC_PW_[A-Za-z0-9_]*\)=.*/\1/p' "$USERS_ENV")
        "$OC" create secret generic realm-secrets -n "$KC_NS" --from-file="$sdir" --dry-run=client -o yaml \
            | "$OC" apply -f - >/dev/null
        rm -rf "$sdir"
    fi
    local groups_json='{"groups":{"maas-users":{"members":["<user>"]}},"users":["<user>"]}'
    dry || groups_json="$(cat "${BACKUP_DIR}/groups.json")"
    GROUPS_JSON="$groups_json" KC_NAME="$KC_NAME" REALM="$REALM" LIFESPAN="$TOKEN_LIFESPAN" \
    C_CONSOLE="$CLIENT_CONSOLE" C_CLI="$CLIENT_CLI" C_GW="$CLIENT_GATEWAY" \
    CONSOLE_HOST="$chost" GATEWAY_HOST="$ghost" KC_NS="$KC_NS" \
    python3 -I - <<'PY' | apply_yaml "KeycloakRealmImport ${REALM}"
import json, os, re
e = os.environ
g = json.loads(e["GROUPS_JSON"])
key = lambda u: "KC_PW_" + re.sub(r"[^A-Za-z0-9]", "_", u)
def mappers(client_ids):
    m = [{"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
          "config": {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                     "access.token.claim": "true", "userinfo.token.claim": "true"}}]
    for c in client_ids:   # every token is accepted by the API server, whichever client asked
        m.append({"name": f"aud-{c}", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
                  "config": {"included.client.audience": c, "id.token.claim": "false", "access.token.claim": "true"}})
    return m
all_clients = [e["C_CONSOLE"], e["C_CLI"], e["C_GW"]]
clients = [
    {"clientId": e["C_CONSOLE"], "publicClient": False, "secret": "${CONSOLE_CLIENT_SECRET}",
     "standardFlowEnabled": True, "redirectUris": [f"https://{e['CONSOLE_HOST']}/auth/callback"],
     "protocolMappers": mappers(all_clients)},
    {"clientId": e["C_CLI"], "publicClient": True, "standardFlowEnabled": True,
     "directAccessGrantsEnabled": True,   # scripted test logins only; never in production
     "redirectUris": ["http://localhost:8080", "http://localhost:8080/*"],
     "protocolMappers": mappers(all_clients)},
    {"clientId": e["C_GW"], "publicClient": False, "secret": "${GATEWAY_CLIENT_SECRET}",
     "standardFlowEnabled": True, "redirectUris": [f"https://{e['GATEWAY_HOST']}/oauth2/callback"],
     "protocolMappers": mappers(all_clients)},
]
users = []
for u in g["users"]:
    users.append({"username": u, "enabled": True, "email": f"{u}@example.test", "emailVerified": True,
                  "firstName": u, "lastName": "test",
                  "groups": [f"/{n}" for n, v in g["groups"].items() if u in v.get("members", [])],
                  "credentials": [{"type": "password", "value": "${%s}" % key(u), "temporary": False}]})
realm = {"realm": e["REALM"], "enabled": True, "accessTokenLifespan": int(e["LIFESPAN"]),
         "groups": [{"name": n} for n in g["groups"]], "clients": clients, "users": users}
placeholders = {k: {"secret": {"name": "realm-secrets", "key": k}}
                for k in ["CONSOLE_CLIENT_SECRET", "GATEWAY_CLIENT_SECRET"] + [key(u) for u in g["users"]]}
cr = {"apiVersion": "k8s.keycloak.org/v2alpha1", "kind": "KeycloakRealmImport",
      "metadata": {"name": e["REALM"], "namespace": e["KC_NS"]},
      "spec": {"keycloakCRName": e["KC_NAME"], "realm": realm, "placeholders": placeholders}}
print(json.dumps(cr, indent=2))
PY
    if ! dry; then
        "$OC" wait keycloakrealmimports.k8s.keycloak.org/"$REALM" -n "$KC_NS" --for=condition=Done --timeout=10m >/dev/null \
            || die "realm import did not finish: oc get keycloakrealmimports.k8s.keycloak.org -n ${KC_NS} -o yaml"
        curl -sS --cacert "$CA_FILE" --max-time 15 -o /dev/null -w '    discovery: HTTP %{http_code}\n' \
            "$(issuer_url)/.well-known/openid-configuration"
        local u tok; u="$(first_user)"; tok="$(kc_token "$u" access)"
        [ -n "$tok" ] || die "could not get a token for ${u} from the realm"
        python3 -I -c 'import sys,json,base64;p=sys.argv[1].split(".")[1];p+="="*(-len(p)%4);c=json.loads(base64.urlsafe_b64decode(p));print("    token for",c.get("preferred_username"),"groups",c.get("groups"),"aud",c.get("aud"),"lifetime",c["exp"]-c["iat"],"s")' "$tok"
    fi
}

cmd_switch_ocp() {
    require_api
    [ -s "${BACKUP_DIR}/authentication.yaml" ] || dry || die "no backup; run 'backup' first"
    [ -s "$OIDC_ENV" ] || dry || die "no ${OIDC_ENV}; run 'keycloak-install' first"
    step "CA and console client Secret in openshift-config"
    if dry; then echo "--- [dry-run] would create ConfigMap openshift-config/${CA_CONFIGMAP} (ca-bundle.crt = default ingress CA) and Secret openshift-config/${CONSOLE_SECRET}"; else
        "$OC" create configmap "$CA_CONFIGMAP" -n openshift-config --from-file=ca-bundle.crt="$CA_FILE" \
            --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
        "$OC" create secret generic "$CONSOLE_SECRET" -n openshift-config \
            --from-file=clientSecret=<(env_get "$OIDC_ENV" CONSOLE_CLIENT_SECRET) \
            --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    fi
    local before; before="$(kas_revision)"
    step "authentications.config.openshift.io/cluster -> type OIDC (OCP 4.22 section 8.2)"
    # Usernames and groups unprefixed, so existing User/Group RBAC subjects and
    # MaaS group names keep matching (danclark stays danclark).
    local patch
    patch="$(cat <<EOF
{"spec": {"type": "OIDC", "webhookTokenAuthenticator": null, "oidcProviders": [{
  "name": "${OIDC_PROVIDER_NAME}",
  "issuer": {"issuerURL": "$(issuer_url)",
             "audiences": ["${CLIENT_CONSOLE}", "${CLIENT_CLI}", "${CLIENT_GATEWAY}"],
             "issuerCertificateAuthority": {"name": "${CA_CONFIGMAP}"}},
  "claimMappings": {"username": {"claim": "preferred_username", "prefixPolicy": "NoPrefix"},
                    "groups": {"claim": "groups"}},
  "oidcClients": [
    {"componentName": "cli", "componentNamespace": "openshift-console", "clientID": "${CLIENT_CLI}"},
    {"componentName": "console", "componentNamespace": "openshift-console", "clientID": "${CLIENT_CONSOLE}",
     "clientSecret": {"name": "${CONSOLE_SECRET}"}}]}]}}
EOF
)"
    run "$OC" patch "$AUTH_CFG" --type=merge -p "$patch"
    dry && echo "$patch" | jq .
    wait_kas_rollout "$before"
    if ! dry; then
        step "A Keycloak-issued token against the API server"
        local u tok; u="$(first_user)"; tok="$(kc_token "$u" id)"
        echo "    oc whoami (id token for ${u}): $("$OC" --kubeconfig=/dev/null --server="$("$OC" whoami --show-server)" \
            --certificate-authority=<("$OC" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d) \
            --token="$tok" whoami 2>&1)"
        echo "    oc login for people: oc login --exec-plugin=oc-oidc --issuer-url=$(issuer_url) --client-id=${CLIENT_CLI} --callback-port=8080 --oidc-certificate-authority ${CA_FILE}"
        echo "    console: https://$(console_host)  (expect a Keycloak login page)"
    fi
}

cmd_switch_gateway() {
    require_api
    [ "$(auth_type)" = "OIDC" ] || dry || die "the cluster is not on direct OIDC yet; the gateway follows the cluster mode (run switch-ocp)"
    step "Gateway client and CA Secrets in openshift-ingress"
    if dry; then echo "--- [dry-run] would create Secrets openshift-ingress/${GATEWAY_SECRET} (clientSecret) and openshift-ingress/${GATEWAY_CA_SECRET} (ca.crt)"; else
        "$OC" create secret generic "$GATEWAY_SECRET" -n openshift-ingress \
            --from-file=clientSecret=<(env_get "$OIDC_ENV" GATEWAY_CLIENT_SECRET) --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
        "$OC" create secret generic "$GATEWAY_CA_SECRET" -n openshift-ingress \
            --from-file=ca.crt="$CA_FILE" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
        echo "    kube-auth-proxy-creds before: client ID '$("$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_ID}' 2>/dev/null | base64 -d)'," \
             "secret sha256 $("$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_SECRET}' 2>/dev/null | sha256sum | cut -c1-12)"
    fi
    step "GatewayConfig default-gateway -> spec.oidc (RHOAI 3.5 Administer platform access 10.2)"
    run "$OC" patch "$GW_CONFIG" --type=merge -p "{\"spec\":{\"providerCASecretName\":\"${GATEWAY_CA_SECRET}\",\"oidc\":{\"issuerURL\":\"$(issuer_url)\",\"clientID\":\"${CLIENT_GATEWAY}\",\"clientSecretRef\":{\"name\":\"${GATEWAY_SECRET}\",\"key\":\"clientSecret\"}}}}"
    if [ "$CREDS_MODE" = "regen" ]; then
        step "Workaround: delete kube-auth-proxy-creds, let the operator regenerate it, restart kube-auth-proxy"
        run "$OC" delete secrets kube-auth-proxy-creds -n openshift-ingress --ignore-not-found
        if ! dry; then
            local deadline=$(( $(date +%s) + 300 ))
            until "$OC" get secrets kube-auth-proxy-creds -n openshift-ingress >/dev/null 2>&1; do
                [ "$(date +%s)" -lt "$deadline" ] || die "kube-auth-proxy-creds was not regenerated in 5 min"
                sleep 5
            done
        fi
        run "$OC" rollout restart deployments.apps/kube-auth-proxy -n openshift-ingress
        run "$OC" rollout status deployments.apps/kube-auth-proxy -n openshift-ingress --timeout=5m
    else
        echo "    --keep-creds: kube-auth-proxy-creds left as it is (reproduces the reuse behaviour)"
        dry || sleep 60
    fi
    if ! dry; then
        step "Evidence"
        local want_secret_sha
        want_secret_sha="$(env_get "$OIDC_ENV" GATEWAY_CLIENT_SECRET | base64 -w0 | sha256sum | cut -c1-12)"
        echo "    kube-auth-proxy-creds client ID: '$("$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_ID}' | base64 -d)' (want ${CLIENT_GATEWAY})"
        echo "    client secret sha256 $("$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_SECRET}' | sha256sum | cut -c1-12), Keycloak's is ${want_secret_sha}"
        echo "    kube-auth-proxy pods:"; "$OC" get pods -n openshift-ingress -l app=kube-auth-proxy -o custom-columns=NAME:.metadata.name,STARTED:.status.startTime --no-headers | sed 's/^/      /'
        echo "    kube-auth-proxy log (last 15 lines):"; "$OC" logs deployments.apps/kube-auth-proxy -n openshift-ingress --tail=15 2>&1 | sed 's/^/      /'
        echo "    GatewayConfig: $("$OC" get "$GW_CONFIG" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}')"
        echo "    Now sign in to https://$(gateway_host)/ in a private window and record what happens (runbook step 5)."
    fi
}

cmd_cookie_refresh() {
    require_api
    if [ "$COOKIE_VALUE" = "default" ]; then
        step "Removing spec.cookie.refresh (operator default: 1h)"
        run "$OC" patch "$GW_CONFIG" --type=json -p '[{"op":"remove","path":"/spec/cookie/refresh"}]'
    else
        step "spec.cookie.refresh = ${COOKIE_VALUE} (must be below the ${TOKEN_LIFESPAN}s access-token lifespan)"
        run "$OC" patch "$GW_CONFIG" --type=merge -p "{\"spec\":{\"cookie\":{\"refresh\":\"${COOKIE_VALUE}\"}}}"
    fi
    if ! dry; then
        local want="${COOKIE_VALUE}" deadline=$(( $(date +%s) + 300 )) got
        [ "$want" = "default" ] && want="1h"
        until got="$("$OC" get deployments.apps kube-auth-proxy -n openshift-ingress -o json | jq -r '.spec.template.spec.containers[0].args[] | select(startswith("--cookie-refresh=")) | sub("--cookie-refresh=";"")')" \
              && [ "$(python3 -I -c 'import re,sys;f=lambda s:sum(int(n)*{"h":3600,"m":60,"s":1}[u] for n,u in re.findall(r"(\d+)([hms])",s));print(f(sys.argv[1])==f(sys.argv[2]))' "$got" "$want")" = "True" ]; do
            [ "$(date +%s)" -lt "$deadline" ] || die "kube-auth-proxy still has --cookie-refresh=${got}, expected ${want}"
            sleep 5
        done
        "$OC" rollout status deployments.apps/kube-auth-proxy -n openshift-ingress --timeout=5m >/dev/null
        echo "    kube-auth-proxy now runs with --cookie-refresh=${got}"
    fi
}

cmd_verify() {
    require_api
    [ "$(auth_type)" = "OIDC" ] || dry || die "the cluster is not on direct OIDC"
    local u="${TEST_USER:-}"
    if [ -z "$u" ]; then if dry; then u="<user>"; else u="$(first_user)"; fi; fi
    if dry; then echo "--- [dry-run] would test as ${u}: oc whoami with id and access tokens, MaaS key mint with each, a model call, gateway status"; return 0; fi
    local idt act server cafile dom host
    idt="$(kc_token "$u" id)"; act="$(kc_token "$u" access)"
    [ -n "$idt" ] && [ -n "$act" ] || die "could not get tokens for ${u}"
    server="$("$OC" whoami --show-server)"
    cafile="$(mktemp)"; trap 'rm -f "$cafile"' RETURN
    "$OC" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$cafile"
    step "API server with Keycloak tokens (user ${u})"
    for kind in id access; do
        local t; [ "$kind" = id ] && t="$idt" || t="$act"
        echo "    ${kind} token: $("$OC" --kubeconfig=/dev/null --server="$server" --certificate-authority="$cafile" --token="$t" whoami 2>&1 | head -1)"
    done
    echo "    groups seen by the API server: $("$OC" --kubeconfig=/dev/null --server="$server" --certificate-authority="$cafile" --token="$idt" auth whoami -o jsonpath='{.status.userInfo.groups}' 2>&1)"

    step "MaaS: mint a key with each token (maas-api checks it with TokenReview), then call a model"
    dom="$(cluster_domain)"; host="https://maas.${dom}"
    local sub; sub="$("$OC" get maassubscriptions.maas.opendatahub.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    local key="" keyid="" kind
    for kind in id access; do
        local t resp code; [ "$kind" = id ] && t="$idt" || t="$act"
        resp="$(curl -sSk --max-time 30 -w '\n%{http_code}' -H "Authorization: Bearer ${t}" -H 'Content-Type: application/json' \
            -X POST -d "{\"name\":\"keycloak-oidc-test\",\"expiresIn\":\"1h\",\"subscription\":\"${sub}\"}" \
            "${host}/maas-api/v1/api-keys" 2>/dev/null || printf '\n000')"
        code="$(tail -1 <<<"$resp")"
        echo "    mint with ${kind} token: HTTP ${code} $(sed '$d' <<<"$resp" | jq -c '{error: (.error // .message // empty)}' 2>/dev/null)"
        if [ "$code" = "201" ] || [ "$code" = "200" ]; then
            [ -n "$key" ] || { key="$(sed '$d' <<<"$resp" | jq -r '.key')"; keyid="$(sed '$d' <<<"$resp" | jq -r '.id')"; }
        fi
    done
    if [ -n "$key" ]; then
        local model code
        model="$(curl -sSk --max-time 30 -H "Authorization: Bearer ${key}" "${host}/maas-api/v1/models" | jq -r '.data[0].id // empty')"
        code="$(curl -sSk --max-time 120 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
            -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK.\"}],\"max_tokens\":5}" "${host}/v1/chat/completions")"
        echo "    model ${model:-?} with the minted key: HTTP ${code}"
        curl -sSk --max-time 15 -X DELETE -H "Authorization: Bearer ${idt}" "${host}/maas-api/v1/api-keys/${keyid}" -o /dev/null -w '    key revoked: HTTP %{http_code}\n' || true
    fi

    step "Gateway and dashboard"
    echo "    GatewayConfig: $("$OC" get "$GW_CONFIG" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}')"
    echo "    kube-auth-proxy: $("$OC" get deployments.apps kube-auth-proxy -n openshift-ingress -o jsonpath='{.status.availableReplicas}/{.spec.replicas} available')," \
         "$("$OC" get deployments.apps kube-auth-proxy -n openshift-ingress -o json | jq -r '[.spec.template.spec.containers[0].args[] | select(test("cookie-refresh|cookie-expire"))] | join(" ")')"
    local gh; gh="$(gateway_host)"
    echo "    dashboard API with the id token as a bearer (skip-jwt-bearer-tokens path): HTTP $(curl -sSk --max-time 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${idt}" "https://${gh}/api/config")"

    [ "$WATCH_SESSION" -eq 1 ] && watch_session "$u" "$gh"
    return 0
}

# EXPERIMENTAL. Log in through kube-auth-proxy like a browser (Keycloak login
# form, cookie jar), then call the dashboard API with only the session cookie at
# T+2, T+6 and T+12 min, as an XHR would (no redirects followed). With
# --cookie-refresh above the token lifespan, expect calls after ~5 min to fail
# or redirect; with it below, expect 200 throughout. The parsing of Keycloak's
# login page is the fragile part.
watch_session() {
    local u="$1" gh="$2" jar pw form start t code
    jar="$(mktemp)"; pw="$(env_get "$USERS_ENV" "KC_PW_$(echo "$u" | tr -c 'A-Za-z0-9\n' '_')")"
    step "EXPERIMENTAL session watch as ${u} on https://${gh}/"
    form="$(curl -sSk -L -c "$jar" -b "$jar" --max-time 30 "https://${gh}/" \
        | python3 -I -c 'import sys,re,html;m=re.search(r"<form[^>]*id=\"kc-form-login\"[^>]*action=\"([^\"]+)\"",sys.stdin.read());print(html.unescape(m.group(1)) if m else "")')"
    [ -n "$form" ] || { echo "    could not find the Keycloak login form; do the manual test instead"; rm -f "$jar"; return 0; }
    curl -sSk -L -c "$jar" -b "$jar" --max-time 30 -o /dev/null \
        --data-urlencode "username=${u}" --data-urlencode "password=${pw}" "$form"
    grep -q _oauth2_proxy "$jar" || { echo "    no _oauth2_proxy cookie after login; do the manual test instead"; rm -f "$jar"; return 0; }
    start="$(date +%s)"
    echo "    signed in at $(date +%T); --cookie-refresh=$("$OC" get deployments.apps kube-auth-proxy -n openshift-ingress -o json | jq -r '.spec.template.spec.containers[0].args[] | select(startswith("--cookie-refresh=")) | sub("--cookie-refresh=";"")')"
    for t in 0 2 6 12; do
        while [ $(( $(date +%s) - start )) -lt $(( t * 60 )) ]; do sleep 10; done
        code="$(curl -sSk -b "$jar" -c "$jar" --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' \
            -H 'X-Requested-With: XMLHttpRequest' "https://${gh}/api/config")"
        echo "    T+${t}m $(date +%T): ${code}"
    done
    rm -f "$jar"
}

cmd_rollback() {
    require_api
    step "OpenShift back to the built-in OAuth server (OCP 4.22 section 8.3)"
    if dry || [ "$(auth_type)" = "OIDC" ]; then
        local before; before="$(kas_revision)"
        run "$OC" patch "$AUTH_CFG" --type=merge -p '{"spec":{"type":"","oidcProviders":null}}'
        if ! dry && [ -s "${BACKUP_DIR}/authentication.yaml" ]; then
            # Put back a webhookTokenAuthenticator if the pre-switch spec had one
            # (section 8.3 resets only type and oidcProviders).
            local wta; wta="$("$OC" create --dry-run=client -o json -f "${BACKUP_DIR}/authentication.yaml" | jq -c '.spec.webhookTokenAuthenticator // empty')"
            [ -z "$wta" ] || "$OC" patch "$AUTH_CFG" --type=merge -p "{\"spec\":{\"webhookTokenAuthenticator\":${wta}}}"
        fi
        wait_kas_rollout "$before"
    else
        echo "    already on the OAuth server"
    fi
    step "GatewayConfig back to integrated OAuth"
    if dry || [ -n "$("$OC" get "$GW_CONFIG" -o jsonpath='{.spec.oidc}')" ]; then
        run "$OC" patch "$GW_CONFIG" --type=json -p '[{"op":"remove","path":"/spec/oidc"}]'
    fi
    if dry || [ -n "$("$OC" get "$GW_CONFIG" -o jsonpath='{.spec.providerCASecretName}')" ]; then
        run "$OC" patch "$GW_CONFIG" --type=json -p '[{"op":"remove","path":"/spec/providerCASecretName"}]'
    fi
    if dry || [ -n "$("$OC" get "$GW_CONFIG" -o jsonpath='{.spec.cookie.refresh}')" ]; then
        run "$OC" patch "$GW_CONFIG" --type=json -p '[{"op":"remove","path":"/spec/cookie/refresh"}]'
    fi
    run "$OC" delete secrets kube-auth-proxy-creds -n openshift-ingress --ignore-not-found
    if ! dry; then
        local deadline=$(( $(date +%s) + 300 ))
        until "$OC" get secrets kube-auth-proxy-creds -n openshift-ingress >/dev/null 2>&1; do
            [ "$(date +%s)" -lt "$deadline" ] || die "kube-auth-proxy-creds was not regenerated in 5 min"
            sleep 5
        done
    fi
    run "$OC" rollout restart deployments.apps/kube-auth-proxy -n openshift-ingress
    run "$OC" rollout status deployments.apps/kube-auth-proxy -n openshift-ingress --timeout=5m
    if ! dry; then
        echo "    kube-auth-proxy-creds client ID: $("$OC" get secrets kube-auth-proxy-creds -n openshift-ingress -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_ID}' | base64 -d) (want data-science)"
    fi
    step "AutoShift: re-apply the hub values and pull policies (restores htpasswd users and Groups)"
    run "${ROOT}/scripts/50-autoshift.sh" bootstrap
    run "${ROOT}/scripts/50-autoshift.sh" refresh
    run "${ROOT}/scripts/cluster-users.sh" status
    run "${ROOT}/scripts/checkup.sh"
    echo "    Keycloak is left running; remove it with: scripts/keycloak-oidc.sh keycloak-uninstall"
}

cmd_keycloak_uninstall() {
    require_api
    [ "$(auth_type)" != "OIDC" ] || dry || die "the cluster still uses direct OIDC; run rollback first"
    if ! dry && [ -n "$("$OC" get "$GW_CONFIG" -o jsonpath='{.spec.oidc}' 2>/dev/null)" ]; then
        die "GatewayConfig still has spec.oidc; run rollback first"
    fi
    step "Removing Keycloak and its Secrets"
    run "$OC" delete keycloakrealmimports.k8s.keycloak.org --all -n "$KC_NS" --ignore-not-found
    run "$OC" delete keycloaks.k8s.keycloak.org --all -n "$KC_NS" --ignore-not-found
    run "$OC" delete subscriptions.operators.coreos.com rhbk-operator -n "$KC_NS" --ignore-not-found
    run "$OC" delete clusterserviceversions.operators.coreos.com -n "$KC_NS" --all --ignore-not-found
    run "$OC" delete namespace "$KC_NS" --ignore-not-found --wait=false
    run "$OC" delete configmaps "$CA_CONFIGMAP" -n openshift-config --ignore-not-found
    run "$OC" delete secrets "$CONSOLE_SECRET" -n openshift-config --ignore-not-found
    run "$OC" delete secrets "$GATEWAY_SECRET" "$GATEWAY_CA_SECRET" -n openshift-ingress --ignore-not-found
    echo "    secrets/keycloak-*.env and ${BACKUP_DIR} are kept; delete them by hand when done"
}

case "$ACTION" in
    preflight)          cmd_preflight ;;
    backup)             cmd_backup ;;
    keycloak-install)   cmd_keycloak_install ;;
    switch-ocp)         cmd_switch_ocp ;;
    switch-gateway)     cmd_switch_gateway ;;
    cookie-refresh)     cmd_cookie_refresh ;;
    verify)             cmd_verify ;;
    rollback)           cmd_rollback ;;
    keycloak-uninstall) cmd_keycloak_uninstall ;;
    status)             cmd_status ;;
esac
