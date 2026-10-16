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
