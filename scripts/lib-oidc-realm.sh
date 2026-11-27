#!/usr/bin/env bash
# shellcheck shell=bash
# lib-oidc-realm.sh - build a NEW cluster's Keycloak realm: print the
#                     KeycloakRealmImport for a cluster that is not the lab,
#                     from cluster.env, the secrets/ files and the fork's hub
#                     values.
#
# scripts/keycloak-oidc.sh builds its realm from
# secrets/keycloak-oidc-backup/groups.json, which only the lab has. These
# functions build the same shape of realm from things every cluster has
# (AUTH_MODE task T2; nothing calls them yet - the planned
# scripts/48-external-oidc.sh will):
#
#   clients   console (confidential), oc-cli (public, direct access grants for
#             scripted logins), gateway (confidential), devspaces
#             (confidential) and argocd (confidential; standard flow, direct
#             access grants off, no PKCE requirement - Argo CD's server-side
#             flow sends no code_challenge_method). Every client gets an
#             audience mapper for all five clients, so the API server accepts
#             any client's token wherever its audiences list includes them.
#             The groups claim reaches console, oc-cli, gateway and devspaces
#             through a per-client group membership mapper; Argo CD gets it
#             through a realm client scope named groups (openid-connect,
#             include.in.token.scope true, group membership mapper with the
#             groups claim, full path off, in the ID token, access token and
#             userinfo), assigned as a default client scope of argocd - Argo CD
#             requests the scope by name, so it must exist even though the
#             other clients never ask for it. A second realm client scope
#             named ogx-api (openid-connect, include.in.token.scope true,
#             display.on.consent.screen false) carries an audience mapper for
#             ogx-api, the audience the OGX server checks (agent-identity-manual
#             10-ogx.yaml, AUTH_AUDIENCE); it is an optional client scope of
#             oc-cli, so a token requested with scope "openid ogx-api" carries
#             aud ogx-api and a plain sign-in token is unchanged.
#   users     the usernames in secrets/cluster-users.env plus maas-user from
#             secrets/maas-user.env. Passwords go in through KeycloakRealmImport
#             placeholders (${KEY}) backed by the realm-secrets Secret - never
#             into the custom resource and never on a command line.
#   groups    config.htpasswdUsers.groups in the fork's clusterset values
#             (${AUTOSHIFT_DIR}/autoshift/values/clustersets/<set>.yaml): the
#             group names and their members, verbatim.
#
# The hosts come from the caller, which knows them and this library never calls
# oc: pass them as arguments, or set CONSOLE_HOST, GATEWAY_HOST and
# DEVSPACES_HOST. The console needs https://<console host>/auth/callback, the
# gateway https://<gateway host>/oauth2/callback, Dev Spaces
# https://<devspaces host>/oauth/callback with that host as web origin, and
# Argo CD https://<argocd host>/auth/callback (plus localhost:8085 for the CLI)
# with the route origin as web origin. The Argo CD host is the fourth argument,
# else ARGOCD_HOST, else infra-gitops-server-openshift-gitops.<APPS_DOMAIN>
# (the GitOps operator's server Route host on an OpenShift-gitops instance);
# without any of the three the render fails.
#
#   oidc_realm_import [console host] [gateway host] [devspaces host] [argocd host]
#       Prints the KeycloakRealmImport (JSON; oc apply -f - takes it).
#       Missing secrets/cluster-users.env or secrets/maas-user.env are
#       generated first (umask 077, python secrets.token_urlsafe), in the same
#       format scripts/cluster-users.sh and scripts/maas-user.sh write.
#   oidc_realm_secret_env
#       Prints one KEY=VALUE line per realm-secrets key, ready for
#       `oc create secret generic realm-secrets -n "$KEYCLOAK_NAMESPACE"
#       --from-env-file=/dev/stdin`. Client secrets come from
#       secrets/keycloak-oidc.env (the Keycloak install creates them), user
#       passwords from the two env files. A missing key is an error.
#
# User details (email, names) stay the @example.test placeholders the lab's
# import uses; correct them per cluster once it exists.

# The clusterset's htpasswdUsers groups, as JSON: [{name, users, ...}, ...].
_oidc_realm_hub_groups() {
    local hub="${AUTOSHIFT_DIR}/autoshift/values/clustersets/${AUTOSHIFT_CLUSTERSET:-hub}.yaml"
    [ -f "$hub" ] || { echo "Error: no clusterset values at ${hub}; is AUTOSHIFT_DIR set?" >&2; return 1; }
    CLUSTERSET="${AUTOSHIFT_CLUSTERSET:-hub}" yq -o=json \
        '.hubClusterSets[strenv(CLUSTERSET)].config.htpasswdUsers.groups' "$hub"
}

# The username roster for secrets/cluster-users.env: every hub group member
# except the MaaS service user, first-seen order.
_oidc_realm_roster() {
    _oidc_realm_hub_groups | python3 -I -c '
import json, sys
users = []
for g in json.load(sys.stdin):
    for u in g.get("users", []):
        if u != "maas-user" and u not in users:
            users.append(u)
print(" ".join(users))'
}

# secrets/cluster-users.env: sorted <user>=<password> lines, nothing else.
_oidc_realm_users_env() {
    local f="${ROOT}/secrets/cluster-users.env" tmp pw u
    [ -s "$f" ] && return 0
    echo "==> Generating ${f} (random passwords, mode 0600)" >&2
    tmp="$(mktemp)"
    umask 077
    for u in $(_oidc_realm_roster); do
        pw="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(24))')"
        printf '%s=%s\n' "$u" "$pw" >> "$tmp"
    done
    sort -o "$f" "$tmp" && rm -f "$tmp" && chmod 600 "$f"
}

# secrets/maas-user.env: the three MAAS_USER_* variables, as maas-user.sh writes.
_oidc_realm_maas_env() {
    local f="${ROOT}/secrets/maas-user.env" pw
    [ -s "$f" ] && return 0
    echo "==> Generating ${f} (random password, mode 0600)" >&2
    pw="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(24))')"
    umask 077
    cat > "$f" <<EOF
# Generated by scripts/lib-oidc-realm.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# NOT in git. secrets/ is ignored except for the .example templates.
MAAS_USER="maas-user"
MAAS_USER_PASSWORD="${pw}"
MAAS_USER_HTPASSWD_SECRET="htpasswd-users"
EOF
    chmod 600 "$f"
}

# _oidc_realm_env_get <file> <key> - the value after the first KEY=, empty if
# absent. maas-user.env and keycloak-oidc.env quote their values; strip them.
_oidc_realm_env_get() {
    sed -n "s/^${2}=//p" "$1" | head -1 | sed 's/^"//; s/"$//'
}

oidc_realm_secret_env() { # KEY=VALUE lines for the realm-secrets Secret
    local uenv="${ROOT}/secrets/cluster-users.env" menv="${ROOT}/secrets/maas-user.env" \
          oenv="${ROOT}/secrets/keycloak-oidc.env" u v usan k
    _oidc_realm_users_env; _oidc_realm_maas_env
    for k in CONSOLE_CLIENT_SECRET GATEWAY_CLIENT_SECRET DEVSPACES_CLIENT_SECRET ARGOCD_CLIENT_SECRET; do
        v="$(_oidc_realm_env_get "$oenv" "$k")"
        [ -n "$v" ] || { echo "Error: ${oenv} has no ${k}; the client secrets are created during the Keycloak install" >&2; return 1; }
        printf '%s=%s\n' "$k" "$v"
    done
    while read -r u; do
        [ -n "$u" ] || continue
        v="$(_oidc_realm_env_get "$uenv" "$u")"
        [ -n "$v" ] || { echo "Error: ${uenv} has no password for ${u}" >&2; return 1; }
        usan="$(sed 's/[^A-Za-z0-9]/_/g' <<<"$u")"
        printf 'KC_PW_%s=%s\n' "$usan" "$v"
    done < <(sed -n '/^#/d; s/=.*//p' "$uenv" | LC_ALL=C sort)
    v="$(_oidc_realm_env_get "$menv" MAAS_USER_PASSWORD)"
    [ -n "$v" ] || { echo "Error: ${menv} has no MAAS_USER_PASSWORD" >&2; return 1; }
    # The key must match the realm's placeholder, which is derived from the user name the
    # same way as above (maas-user -> KC_PW_maas_user).
    u="$(_oidc_realm_env_get "$menv" MAAS_USER)"; u="${u:-maas-user}"
    printf 'KC_PW_%s=%s\n' "$(sed 's/[^A-Za-z0-9]/_/g' <<<"$u")" "$v"
}

oidc_realm_import() { # [console host] [gateway host] [devspaces host] [argocd host] -> prints the CR
    local chost="${1:-${CONSOLE_HOST:-}}" ghost="${2:-${GATEWAY_HOST:-}}" dhost="${3:-${DEVSPACES_HOST:-}}"
    [ -n "$chost" ] && [ -n "$ghost" ] && [ -n "$dhost" ] || {
        echo "Error: pass the console, gateway and Dev Spaces hosts as arguments, or set" >&2
        echo "       CONSOLE_HOST, GATEWAY_HOST and DEVSPACES_HOST." >&2
        return 1
    }
    # Argo CD: fourth argument, else ARGOCD_HOST, else the GitOps operator's
    # server Route host under APPS_DOMAIN.
    local ahost="${4:-${ARGOCD_HOST:-}}"
    if [ -z "$ahost" ] && [ -n "${APPS_DOMAIN:-}" ]; then
        ahost="infra-gitops-server-openshift-gitops.${APPS_DOMAIN}"
    fi
    [ -n "$ahost" ] || {
        echo "Error: no Argo CD server route host; pass it as the fourth argument to" >&2
        echo "       oidc_realm_import, or set ARGOCD_HOST or APPS_DOMAIN." >&2
        return 1
    }
    local uenv="${ROOT}/secrets/cluster-users.env" menv="${ROOT}/secrets/maas-user.env" k groups_json maas_user
    _oidc_realm_users_env; _oidc_realm_maas_env
    for k in CONSOLE_CLIENT_SECRET GATEWAY_CLIENT_SECRET DEVSPACES_CLIENT_SECRET ARGOCD_CLIENT_SECRET; do
        [ -n "$(_oidc_realm_env_get "${ROOT}/secrets/keycloak-oidc.env" "$k")" ] \
            || { echo "Error: secrets/keycloak-oidc.env has no ${k}; the client secrets are created during the Keycloak install" >&2; return 1; }
    done
    groups_json="$(_oidc_realm_hub_groups)" || return 1
    maas_user="$(_oidc_realm_env_get "$menv" MAAS_USER)"
    [ -n "$maas_user" ] || maas_user="maas-user"
    KC_NAME="$KEYCLOAK_NAME" REALM="$KEYCLOAK_REALM" KC_NS="$KEYCLOAK_NAMESPACE" \
    LIFESPAN="$OIDC_TOKEN_LIFESPAN" \
    C_CONSOLE="$OIDC_CLIENT_CONSOLE" C_CLI="$OIDC_CLIENT_CLI" C_GW="$OIDC_CLIENT_GATEWAY" \
    C_DEVSPACES="$OIDC_CLIENT_DEVSPACES" C_ARGOCD="${OIDC_CLIENT_ARGOCD:-argocd}" \
    CONSOLE_HOST="$chost" GATEWAY_HOST="$ghost" DEVSPACES_HOST="$dhost" ARGOCD_HOST="$ahost" \
    CLI_PORTS="$OIDC_CLI_CALLBACK_PORTS" ROSTER="$(sed -n '/^#/d; s/=.*//p' "$uenv" | LC_ALL=C sort | tr '\n' ' ')" \
    MAAS_USER="$maas_user" HUB_GROUPS_JSON="$groups_json" \
    python3 -I - <<'PY'
import json, os, re, sys
e = os.environ
key = lambda u: "KC_PW_" + re.sub(r"[^A-Za-z0-9]", "_", u)
hub = json.loads(e["HUB_GROUPS_JSON"])
groups = [{"name": g["name"]} for g in hub]
members = {g["name"]: g.get("users", []) for g in hub}
users = sorted(set(u for u in e["ROSTER"].split() if u) | {e["MAAS_USER"]})
def audiences(client_ids):
    return [{"name": f"aud-{c}", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
             "config": {"included.client.audience": c, "id.token.claim": "false", "access.token.claim": "true"}}
            for c in client_ids]
def mappers(client_ids):
    m = [{"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
          "config": {"claim.name": "groups", "full.path": "false", "id.token.claim": "true",
                     "access.token.claim": "true", "userinfo.token.claim": "true"}}]
    return m + audiences(client_ids)
all_clients = [e["C_CONSOLE"], e["C_CLI"], e["C_GW"], e["C_DEVSPACES"], e["C_ARGOCD"]]
uris = []
for p in e["CLI_PORTS"].split():
    uris += [f"http://localhost:{p}", f"http://localhost:{p}/*"]
clients = [
    {"clientId": e["C_CONSOLE"], "publicClient": False, "secret": "${CONSOLE_CLIENT_SECRET}",
     "standardFlowEnabled": True, "redirectUris": [f"https://{e['CONSOLE_HOST']}/auth/callback"],
     "protocolMappers": mappers(all_clients)},
    {"clientId": e["C_CLI"], "publicClient": True, "standardFlowEnabled": True,
     "directAccessGrantsEnabled": True,   # scripted test logins only; never in production
     "redirectUris": uris, "protocolMappers": mappers(all_clients),
     # ogx-api is OPTIONAL here: the audience joins aud only when the caller asks
     # for scope "openid ogx-api" (scripts/lib-oc-token.sh consumers, demo-trace.sh's
     # OGX hop), so everyday CLI tokens stay exactly as they were.
     "optionalClientScopes": ["ogx-api"]},
    {"clientId": e["C_GW"], "publicClient": False, "secret": "${GATEWAY_CLIENT_SECRET}",
     "standardFlowEnabled": True, "redirectUris": [f"https://{e['GATEWAY_HOST']}/oauth2/callback"],
     "protocolMappers": mappers(all_clients)},
    {"clientId": e["C_DEVSPACES"], "publicClient": False, "secret": "${DEVSPACES_CLIENT_SECRET}",
     "standardFlowEnabled": True,
     "redirectUris": [f"https://{e['DEVSPACES_HOST']}/oauth/callback"],
     "webOrigins": [f"https://{e['DEVSPACES_HOST']}"],
     "protocolMappers": mappers(all_clients)},
    {"clientId": e["C_ARGOCD"], "publicClient": False, "secret": "${ARGOCD_CLIENT_SECRET}",
     "standardFlowEnabled": True,
     "directAccessGrantsEnabled": False,   # the lab: standard flow only, no password grant
     # Argo CD's server-side flow sends no code_challenge_method, so no PKCE requirement
     # is set (setting one makes every sign-in fail). localhost:8085 is the CLI callback.
     "redirectUris": [f"https://{e['ARGOCD_HOST']}/auth/callback", "http://localhost:8085/auth/callback"],
     "webOrigins": [f"https://{e['ARGOCD_HOST']}"],
     # The groups claim comes from the groups client scope, not a per-client mapper
     # (Argo CD requests the scope by name). The four built-in scope names are the
     # realm defaults a UI-created client gets on RHBK 26; listing them keeps them.
     "defaultClientScopes": ["profile", "email", "roles", "web-origins", "groups"],
     "protocolMappers": audiences(all_clients)},
]
# Argo CD requests the scope named groups; the realm has none by default. The scope
# carries the group membership mapper, so the claim rides the ID token, the access
# token and userinfo whenever the client was granted the scope.
groups_scope = [{"name": "groups", "protocol": "openid-connect",
                 "attributes": {"include.in.token.scope": "true"},
                 "protocolMappers": [{"name": "groups", "protocol": "openid-connect",
                                      "protocolMapper": "oidc-group-membership-mapper",
                                      "config": {"claim.name": "groups", "full.path": "false",
                                                 "id.token.claim": "true", "access.token.claim": "true",
                                                 "userinfo.token.claim": "true"}}]}]
# The OGX server (agent-identity-manual 10-ogx.yaml) validates tokens against AUTH_AUDIENCE
# ogx-api. The audience mapper below puts ogx-api in aud when, and only when, the client
# was granted this scope, so a caller opts in by requesting scope "openid ogx-api" and
# nobody else's token changes. Consent display is off: the lab shows no consent screens.
ogx_scope = [{"name": "ogx-api", "protocol": "openid-connect",
              "attributes": {"include.in.token.scope": "true",
                             "display.on.consent.screen": "false"},
              "protocolMappers": [{"name": "ogx-api-audience", "protocol": "openid-connect",
                                   "protocolMapper": "oidc-audience-mapper",
                                   "config": {"included.custom.audience": "ogx-api",
                                              "access.token.claim": "true",
                                              "id.token.claim": "false"}}]}]
user_entries = []
for u in users:
    gs = [f"/{n}" for n, mem in members.items() if u in mem]
    if not gs:
        print(f"warning: {u} is in no hub group; imported with no membership", file=sys.stderr)
    user_entries.append({"username": u, "enabled": True, "email": f"{u}@example.test", "emailVerified": True,
                         "firstName": u, "lastName": "test", "groups": gs,
                         "credentials": [{"type": "password", "value": "${%s}" % key(u), "temporary": False}]})
realm = {"realm": e["REALM"], "enabled": True, "accessTokenLifespan": int(e["LIFESPAN"]),
         "groups": groups, "clients": clients, "clientScopes": groups_scope + ogx_scope, "users": user_entries}
placeholders = {k: {"secret": {"name": "realm-secrets", "key": k}}
                for k in ["CONSOLE_CLIENT_SECRET", "GATEWAY_CLIENT_SECRET", "DEVSPACES_CLIENT_SECRET",
                          "ARGOCD_CLIENT_SECRET"]
                + [key(u) for u in users]}
cr = {"apiVersion": "k8s.keycloak.org/v2alpha1", "kind": "KeycloakRealmImport",
      "metadata": {"name": e["REALM"], "namespace": e["KC_NS"]},
      "spec": {"keycloakCRName": e["KC_NAME"], "realm": realm, "placeholders": placeholders}}
print(json.dumps(cr, indent=2))
PY
}
