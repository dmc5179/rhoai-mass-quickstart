#!/usr/bin/env bash
#
# rhokp-key.sh - create the RHOKP access key Secret the rhokp-mcp policies wait
#                for, from secrets/rhokp.env, and report on the chain behind it.
#
# Usage: scripts/rhokp-key.sh apply  [--namespace <ns>] [--secret <name>] [--key <key>] [--restart]
#        scripts/rhokp-key.sh status [--namespace <ns>] [--secret <name>] [--key <key>]
#
# Options:
#   --namespace <ns>  Default: rhokp. Must match config.rhokpMcp.namespace.
#   --secret <name>   Default: rhokp-access-key. config.rhokpMcp.accessKeySecret.
#   --key <key>       Default: ACCESS_KEY. config.rhokpMcp.accessKeySecretKey.
#   --restart         After apply, restart RHOKP so it reads the new key. A
#                     restart re-indexes, which takes several minutes.
#
# Why this exists. The Red Hat Offline Knowledge Portal (RHOKP) needs an access
# key, which comes with a Satellite Infrastructure subscription (SKU MCT3718).
# Without it RHOKP serves its web UI but search returns nothing. The key is a
# licensed credential, so it never goes in git or AutoShift values: the
# AutoShift rhokp-mcp policies expect this one Secret to be created out of band,
# and policy-rhokp-mcp-prereqs reports it missing until it is.
#
# Where the key comes from: secrets/rhokp.env (gitignored), with one line
#
#   RHOKP_KEY="<the access key>"
#
# The key never appears in a command line, on the terminal or in logs/: it is
# read in a subshell, written to a mode 0600 file in a private temporary
# directory, passed to oc with --from-file, and the directory is removed on
# exit. oc apply's output is discarded.
#
# The namespace is created if it does not exist yet, so this can run before or
# after AutoShift is bootstrapped; the rhokp-mcp-ns policy adopts it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}"; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
ACTION="${1:-}"; shift || true

NAMESPACE="rhokp"
SECRET_NAME="rhokp-access-key"
SECRET_KEY="ACCESS_KEY"
RESTART=0
while [ $# -gt 0 ]; do
    case "$1" in
        --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
        --secret)    SECRET_NAME="${2:?--secret needs a value}"; shift 2 ;;
        --key)       SECRET_KEY="${2:?--key needs a value}"; shift 2 ;;
        --restart)   RESTART=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "rhokp-key.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    apply|status) ;;
    *) echo "Usage: scripts/rhokp-key.sh {apply|status} [options]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "rhokp-key" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

ENV_FILE="${ROOT}/secrets/rhokp.env"

export KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
"$OC" get --raw /readyz >/dev/null 2>&1 || {
    echo "Error: cluster API not reachable via ${KUBECONFIG}." >&2; exit 1; }

# Length of a Secret's data value, without printing it. 0 when absent.
secret_key_length() {
    "$OC" get secret "$SECRET_NAME" -n "$NAMESPACE" \
        -o jsonpath="{.data.${SECRET_KEY}}" 2>/dev/null | tr -d '\n' | wc -c
}

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    printf '  %-30s ' "key file"
    if [ -f "$ENV_FILE" ]; then
        if grep -Eq '^[[:space:]]*(export[[:space:]]+)?RHOKP_KEY=' "$ENV_FILE"; then
            echo "$ENV_FILE (RHOKP_KEY set)"
        else
            echo "$ENV_FILE has no RHOKP_KEY line"
        fi
    else
        echo "absent: create ${ENV_FILE} with RHOKP_KEY=\"...\""
    fi
    printf '  %-30s ' "namespace ${NAMESPACE}"
    "$OC" get namespace "$NAMESPACE" >/dev/null 2>&1 && echo "present" || echo "absent"
    printf '  %-30s ' "Secret ${SECRET_NAME}"
    if "$OC" get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        if [ "$(secret_key_length)" -gt 0 ]; then
            echo "present, ${SECRET_KEY} non-empty"
        else
            echo "present, but no non-empty ${SECRET_KEY} - run: scripts/rhokp-key.sh apply"
        fi
    else
        echo "MISSING - run: scripts/rhokp-key.sh apply"
    fi
    for d in rhokp-server rhokp-mcp; do
        printf '  %-30s ' "deployment ${d}"
        "$OC" get deployment "$d" -n "$NAMESPACE" \
            -o jsonpath='{.status.availableReplicas}/{.spec.replicas} available{"\n"}' 2>/dev/null \
            || echo "absent"
    done
    # The same query as RHOKP's readiness probe, run in its own pod (its
    # NetworkPolicy admits nothing else). Reads a count, never the key.
    printf '  %-30s ' "portal search index"
    if "$OC" get deployment rhokp-server -n "$NAMESPACE" >/dev/null 2>&1; then
        n="$("$OC" exec -n "$NAMESPACE" deploy/rhokp-server -c rhokp -- \
            curl -sf --max-time 8 'http://127.0.0.1:8983/solr/portal/select?q=*:*&rows=0&wt=json&indent=false' 2>/dev/null \
            | grep -Eo '"numFound": ?[0-9]+' | grep -Eo '[0-9]+$' || true)"
        if [ -z "$n" ]; then
            echo "no answer (still starting or indexing?)"
        elif [ "$n" -eq 0 ]; then
            echo "0 documents - the key is missing, invalid, or indexing has not finished"
        else
            echo "${n} documents"
        fi
    else
        echo "RHOKP not deployed"
    fi
    printf '  %-30s ' "gateway registration"
    "$OC" get mcpserverregistrations.mcp.kuadrant.io -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}: Ready={.status.conditions[?(@.type=="Ready")].status} {end}{"\n"}' 2>/dev/null \
        | grep . || echo "none"
    echo
    # An unplaced policy has no compliance at all, which is not the same as
    # Compliant: say so rather than print a blank.
    echo "  Policies:"
    "$OC" get policies.policy.open-cluster-management.io -A --no-headers \
        -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATE:.status.compliant' 2>/dev/null \
        | awk '$2 ~ /rhokp|mcp-gateway/ && $1 != "local-cluster" {
                 st = ($3 == "<none>") ? "no status (not placed, or not evaluated yet)" : $3
                 printf "    %-40s %s\n", $2, st }' \
        | sort -u || true
    exit 0
fi

# --- apply ------------------------------------------------------------------
[ -f "$ENV_FILE" ] || {
    echo "Error: ${ENV_FILE} not found. Create it (it is gitignored) with:" >&2
    echo "    RHOKP_KEY=\"<the RHOKP access key>\"" >&2
    exit 1; }

umask 077
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
KEYFILE="${WORK}/key"

# A subshell, so RHOKP_KEY never enters this script's environment, and with
# tracing off whatever the caller set. printf '%s' adds no newline, which RHOKP
# would otherwise read as part of the key.
(
    set +x
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    printf '%s' "${RHOKP_KEY:-}"
) > "$KEYFILE"

if [ ! -s "$KEYFILE" ]; then
    echo "Error: RHOKP_KEY is empty or unset in ${ENV_FILE}." >&2
    exit 1
fi

if ! "$OC" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    "$OC" create namespace "$NAMESPACE" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    echo "==> Created namespace ${NAMESPACE} (the rhokp-mcp-ns policy adopts it)"
fi

existed=0
"$OC" get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1 && existed=1

"$OC" create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
    --from-file="${SECRET_KEY}=${KEYFILE}" --dry-run=client -o yaml \
    | "$OC" apply -f - >/dev/null
echo "==> Secret ${NAMESPACE}/${SECRET_NAME} applied (key ${SECRET_KEY})"

if "$OC" get deployment rhokp-server -n "$NAMESPACE" >/dev/null 2>&1; then
    if [ "$RESTART" -eq 1 ]; then
        "$OC" rollout restart deployment/rhokp-server -n "$NAMESPACE" >/dev/null
        echo "==> Restarted rhokp-server; it re-indexes for several minutes"
    elif [ "$existed" -eq 1 ]; then
        echo "==> RHOKP reads the key at startup. To use a changed key:"
        echo "    scripts/rhokp-key.sh apply --restart   (re-indexes, several minutes)"
    fi
fi

cat <<EOF

policy-rhokp-mcp-prereqs turns Compliant at its next evaluation, then RHOKP is
deployed and indexes (the first start pulls 7 to 10 GB). Follow it with:

    scripts/rhokp-key.sh status
EOF
