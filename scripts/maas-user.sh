#!/usr/bin/env bash
#
# maas-user.sh - create the htpasswd user that people log in as to mint MaaS
#                API keys, and the Secret the htpasswd-users policy waits for.
#
# Usage: scripts/maas-user.sh create  [--user <name>] [--rotate]
#        scripts/maas-user.sh status
#
# Options:
#   --user <name>   Default: maas-user. Must match a member of a Group in
#                   config.htpasswdUsers in the AutoShift hub values.
#   --rotate        Generate a new password even if one already exists.
#
# Why this exists. A MaaS subscription is owned by Groups, and only a member
# can mint an API key. kubeadmin is in no Group, and the hub values narrow the
# subscription to two: the hermes ServiceAccounts, and maas-users. This script
# creates the person who belongs to maas-users.
#
# What it does and does not do. The AutoShift htpasswd-users policy owns the
# OAuth identity provider, the Group and its role bindings - all declarative,
# all from git. The one thing it cannot own is the password, because a hash
# does not belong in a repository either. This script creates that piece:
#
#   - generates a password, or reuses the one in secrets/maas-user.env
#   - writes the htpasswd Secret in openshift-config
#   - records the password in secrets/maas-user.env (mode 0600, gitignored)
#
# The policy adds the identity provider only once that Secret exists, so this
# can run before or after AutoShift is bootstrapped.
#
# Other users already in the Secret are preserved: their lines are kept, and
# only this user's line is added or replaced.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

case "${1:-}" in
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
ACTION="${1:-}"; shift || true

MAAS_USER="maas-user"
ROTATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user)   MAAS_USER="$2"; shift 2 ;;
        --rotate) ROTATE=1; shift ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "maas-user.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    create|status) ;;
    *) echo "Usage: scripts/maas-user.sh {create|status} [options]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "maas-user" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

# Must match config.htpasswdUsers.secretName / providerName / the Group name in
# the AutoShift hub values.
SECRET_NAME="htpasswd-users"
PROVIDER_NAME="htpasswd"
GROUP_NAME="maas-users"
ENV_FILE="${ROOT}/secrets/maas-user.env"

export KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
"$OC" get --raw /readyz >/dev/null 2>&1 || {
    echo "Error: cluster API not reachable via ${KUBECONFIG}." >&2; exit 1; }

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    printf '  %-28s ' "htpasswd Secret"
    "$OC" get secret "$SECRET_NAME" -n openshift-config >/dev/null 2>&1 \
        && echo "present (openshift-config/${SECRET_NAME})" \
        || echo "MISSING - run: scripts/maas-user.sh create"
    printf '  %-28s ' "OAuth identity provider"
    "$OC" get oauth.config.openshift.io cluster \
        -o jsonpath="{.spec.identityProviders[?(@.name==\"${PROVIDER_NAME}\")].type}" 2>/dev/null \
        | grep -q HTPasswd \
        && echo "present (${PROVIDER_NAME})" \
        || echo "absent - is the htpasswd-users policy enabled, and the Secret present?"
    printf '  %-28s ' "Group ${GROUP_NAME}"
    "$OC" get groups.user.openshift.io "$GROUP_NAME" -o jsonpath='{.users}' 2>/dev/null \
        || echo "absent"
    echo
    printf '  %-28s ' "authentication operator"
    "$OC" get clusteroperator authentication \
        -o jsonpath='{range .status.conditions[?(@.type=="Degraded")]}Degraded={.status} {.message}{end}' 2>/dev/null
    echo
    printf '  %-28s ' "credentials file"
    [ -f "$ENV_FILE" ] && echo "$ENV_FILE" || echo "absent"
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        printf '  %-28s ' "login as ${MAAS_USER}"
        tmp_kc="$(mktemp)"; trap 'rm -f "$tmp_kc"' EXIT
        KUBECONFIG="$tmp_kc" "$OC" login -u "$MAAS_USER" -p "$MAAS_USER_PASSWORD" \
            --server="$("$OC" whoami --show-server)" --insecure-skip-tls-verify=true >/dev/null 2>&1 \
            && echo "OK" \
            || echo "FAILED - the provider takes a minute or two to roll out after the Secret appears"
    fi
    exit 0
fi

# --- create -----------------------------------------------------------------
command -v htpasswd >/dev/null || {
    echo "Error: 'htpasswd' not found. Install httpd-tools (dnf install httpd-tools)." >&2; exit 1; }

PASSWORD=""
# Sourcing the env file sets MAAS_USER, which would clobber --user. Read it in a
# subshell and compare, so the requested user always wins.
WANT_USER="$MAAS_USER"
if [ -f "$ENV_FILE" ] && [ "$ROTATE" -eq 0 ]; then
    FILE_USER="$(. "$ENV_FILE"; printf '%s' "${MAAS_USER:-}")"
    FILE_PASS="$(. "$ENV_FILE"; printf '%s' "${MAAS_USER_PASSWORD:-}")"
    if [ "$FILE_USER" = "$WANT_USER" ] && [ -n "$FILE_PASS" ]; then
        PASSWORD="$FILE_PASS"
        echo "==> Reusing the password in ${ENV_FILE} (--rotate for a new one)"
    fi
fi
MAAS_USER="$WANT_USER"
if [ -z "$PASSWORD" ]; then
    PASSWORD="$(python3 -I -c "
import secrets, string
print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))")"
    echo "==> Generated a new password for ${MAAS_USER}"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HTFILE="${WORK}/htpasswd"

# Start from the existing Secret so other users survive, then add or replace
# this user's line. htpasswd -B is bcrypt; -i reads the password from stdin so
# it never appears in the process list.
if "$OC" get secret "$SECRET_NAME" -n openshift-config >/dev/null 2>&1; then
    "$OC" extract "secret/${SECRET_NAME}" -n openshift-config --keys=htpasswd --to="$WORK" --confirm >/dev/null
    printf '%s' "$PASSWORD" | htpasswd -B -i "$HTFILE" "$MAAS_USER" >/dev/null 2>&1
    echo "==> Updated ${MAAS_USER} in the existing Secret (other users kept)"
else
    printf '%s' "$PASSWORD" | htpasswd -c -B -i "$HTFILE" "$MAAS_USER" >/dev/null 2>&1
fi

"$OC" create secret generic "$SECRET_NAME" -n openshift-config \
    --from-file=htpasswd="$HTFILE" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
echo "==> Secret openshift-config/${SECRET_NAME} applied"

umask 077
cat > "$ENV_FILE" <<EOF
# Generated by scripts/maas-user.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# NOT in git. secrets/ is ignored except for the .example templates.
MAAS_USER="${MAAS_USER}"
MAAS_USER_PASSWORD="${PASSWORD}"
MAAS_USER_HTPASSWD_SECRET="${SECRET_NAME}"
EOF
echo "==> Wrote ${ENV_FILE} (mode 0600)"

cat <<EOF

${MAAS_USER} will be able to log in once the htpasswd-users policy adds the
identity provider - its next evaluation after it sees the Secret - and the
oauth-openshift pods roll out, typically a minute or two. Check with:

    scripts/maas-user.sh status

Then this user can mint MaaS keys from the RHOAI dashboard (API keys page) or
the API, and scripts/35-smoke-test.sh mints as this user automatically.

Removing ${MAAS_USER} from the maas-users Group does NOT revoke keys it already
minted. Revoke those by hand.
EOF
