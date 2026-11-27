# shellcheck shell=bash
# lib-oc-token.sh - make sure $KUBECONFIG has a bearer token.
#
# The MaaS API authenticates callers with an OpenShift bearer token, so
# anything that mints an API key needs `oc whoami -t` to work. The installer's
# kubeconfig authenticates with client certificates instead, and against that
# `oc whoami -t` fails with:
#
#     error: no token is currently in use for this session
#
# ensure_oc_token logs in as kubeadmin into a throwaway kubeconfig and points
# KUBECONFIG at it. The original file is never modified.
#
# Requires: OC, CLUSTER_DIR, and KUBECONFIG already set.

# --- External OIDC (OpenShift direct authentication) ----------------------------
# With authentications.config.openshift.io type OIDC there is no OAuth server, no
# kubeadmin and no `oc login -u/-p`. oidc_token gets an access token straight from the
# cluster's own OIDC provider (issuer and the "cli" client read from the cluster), using
# the password grant, which the provider must allow for that client (our lab realm does).
cluster_is_oidc() {
    [ "$("$OC" get authentications.config.openshift.io cluster -o jsonpath='{.spec.type}' 2>/dev/null)" = "OIDC" ]
}

# oidc_token <user> <password> [scope]  ->  prints an access token (empty on failure)
# The scope is optional and defaults to openid. Passing a wider scope makes an
# optional client scope's audience mapper fire: "openid ogx-api" returns a token whose
# aud carries the OGX audience, which the OGX gateway requires (the agent-identity-manual
# repository's ogx-token.sh mints exactly that token).
oidc_token() {
    local iss cid tep
    local scope="${3:-openid}"
    iss="$("$OC" get authentications.config.openshift.io cluster -o jsonpath='{.spec.oidcProviders[0].issuer.issuerURL}')"
    cid="$("$OC" get authentications.config.openshift.io cluster -o jsonpath='{.spec.oidcProviders[0].oidcClients[?(@.componentName=="cli")].clientID}')"
    tep="$(curl -sk "${iss}/.well-known/openid-configuration" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token_endpoint",""))')"
    [ -n "$tep" ] && [ -n "$cid" ] || { echo "Error: could not read the OIDC issuer or cli client from the cluster" >&2; return 1; }
    # The password goes to curl on stdin (password@-), never on a command line where any user
    # on the host could read it from the process list.
    printf '%s' "$2" | curl -sk -X POST "$tep" --data-urlencode grant_type=password --data-urlencode client_id="$cid" \
        --data-urlencode username="$1" --data-urlencode password@- --data-urlencode scope="$scope" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}

# _oidc_kubeconfig <user> <password>: a throwaway kubeconfig with that user's token
_oidc_kubeconfig() {
    local server kc tok
    server="$("$OC" whoami --show-server)"; kc="$(mktemp)"
    tok="$(oidc_token "$1" "$2")" || { rm -f "$kc"; return 1; }
    [ -n "$tok" ] || { rm -f "$kc"; echo "Error: the OIDC provider gave no token for $1" >&2; return 1; }
    # Written from the environment rather than `oc login --token=...`, which would put the token
    # on a command line. The file is created 0600 by mktemp.
    TOK="$tok" SERVER="$server" python3 -I -c 'import json,os
print(json.dumps({"apiVersion": "v1", "kind": "Config", "current-context": "oidc",
  "clusters": [{"name": "c", "cluster": {"server": os.environ["SERVER"], "insecure-skip-tls-verify": True}}],
  "users": [{"name": "u", "user": {"token": os.environ["TOK"]}}],
  "contexts": [{"name": "oidc", "context": {"cluster": "c", "user": "u"}}]}))' > "$kc"
    KUBECONFIG="$kc" "$OC" whoami >/dev/null 2>&1 \
        || { rm -f "$kc"; echo "Error: the API server rejected the OIDC token for $1" >&2; return 1; }
    echo "$kc"
}

ensure_oc_token() {
    if "$OC" whoami -t >/dev/null 2>&1; then
        return 0   # already token-based
    fi

    if cluster_is_oidc; then
        # No kubeadmin under external OIDC: use an admin from secrets/cluster-users.env
        # (OIDC_SCRIPT_USER, default danclark). Tokens are short-lived (5 min on our realm).
        local u="${OIDC_SCRIPT_USER:-danclark}" p kc
        p="$( ( set +u; . "${ROOT}/secrets/cluster-users.env"; eval "printf '%s' \"\${$u:-}\"" ) )"
        kc="$(_oidc_kubeconfig "$u" "$p")" || return 1
        _OC_TOKEN_KUBECONFIG="$kc"; export KUBECONFIG="$kc"
        echo "==> Obtained an OIDC token as $("$OC" whoami) (cluster uses external OIDC)"
        return 0
    fi

    local pwfile="${CLUSTER_DIR}/auth/kubeadmin-password"
    [ -f "$pwfile" ] || {
        echo "Error: ${KUBECONFIG} authenticates with a client certificate, so" >&2
        echo "       there is no bearer token for the MaaS API, and" >&2
        echo "       ${pwfile} is missing to log in with." >&2
        echo "       Run 'oc login' yourself and re-run with that KUBECONFIG." >&2
        return 1
    }

    local server token_kc
    server="$("$OC" whoami --show-server)"
    token_kc="$(mktemp)"
    # Cleaned up by the caller's EXIT trap via _OC_TOKEN_KUBECONFIG.
    _OC_TOKEN_KUBECONFIG="$token_kc"

    if ! KUBECONFIG="$token_kc" "$OC" login \
            -u kubeadmin -p "$(cat "$pwfile")" \
            --server="$server" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
        rm -f "$token_kc"
        echo "Error: could not log in as kubeadmin to obtain a token." >&2
        return 1
    fi

    export KUBECONFIG="$token_kc"
    echo "==> Obtained a bearer token as $("$OC" whoami) (cert-based kubeconfig cannot provide one)"
}

cleanup_oc_token() {
    [ -n "${_OC_TOKEN_KUBECONFIG:-}" ] && rm -f "$_OC_TOKEN_KUBECONFIG"
    return 0
}

# maas_mint_token sets MAAS_MINT_TOKEN to the bearer token to mint MaaS API keys
# with, and MAAS_MINT_IDENTITY to who that token belongs to.
#
# Minting is deliberately separate from cluster reads. MaaS decides who may mint
# by Group membership alone - the subscription's owner.groups - and kubeadmin is
# in none of the Groups a narrowed subscription names. So a script can read the
# cluster as kubeadmin and still be refused a key. When secrets/maas-user.env
# exists (written by scripts/maas-user.sh), mint as that htpasswd user instead,
# which is in the maas-users Group. Otherwise fall back to the current token.
#
# The user needs no Kubernetes RBAC for this: the token is used only against the
# MaaS API, never against the cluster API.
#
# Requires: OC and KUBECONFIG set, ROOT pointing at the repository.
maas_mint_token() {
    local env="${ROOT}/secrets/maas-user.env"
    if [ ! -f "$env" ]; then
        MAAS_MINT_TOKEN="$("$OC" whoami -t 2>/dev/null)"
        MAAS_MINT_IDENTITY="$("$OC" whoami 2>/dev/null)"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$env"
    if cluster_is_oidc; then
        MAAS_MINT_TOKEN="$(oidc_token "$MAAS_USER" "$MAAS_USER_PASSWORD")"
        MAAS_MINT_IDENTITY="$MAAS_USER"
        [ -n "$MAAS_MINT_TOKEN" ] && return 0
        echo "Error: the OIDC provider gave no token for ${MAAS_USER}" >&2; return 1
    fi
    local server user_kc
    server="$("$OC" whoami --show-server)"
    user_kc="$(mktemp)"
    _MAAS_USER_KUBECONFIG="$user_kc"
    # The identity provider rolls out by restarting the oauth-openshift pods,
    # which takes a minute or two after the Secret first appears. Retry rather
    # than report a fresh cluster as broken.
    local i
    for i in 1 2 3 4 5 6; do
        if KUBECONFIG="$user_kc" "$OC" login -u "$MAAS_USER" -p "$MAAS_USER_PASSWORD" \
                --server="$server" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
            MAAS_MINT_TOKEN="$(KUBECONFIG="$user_kc" "$OC" whoami -t)"
            MAAS_MINT_IDENTITY="$MAAS_USER"
            return 0
        fi
        [ "$i" -lt 6 ] && sleep 20
    done
    echo "Error: could not log in as ${MAAS_USER} (from ${env})." >&2
    echo "       Check the identity provider is live: scripts/maas-user.sh status" >&2
    return 1
}

cleanup_maas_mint_token() {
    [ -n "${_MAAS_USER_KUBECONFIG:-}" ] && rm -f "$_MAAS_USER_KUBECONFIG"
    return 0
}
