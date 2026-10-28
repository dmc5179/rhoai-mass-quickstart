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

ensure_oc_token() {
    if "$OC" whoami -t >/dev/null 2>&1; then
        return 0   # already token-based
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
