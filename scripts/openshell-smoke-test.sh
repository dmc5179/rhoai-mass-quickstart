#!/usr/bin/env bash
#
# openshell-smoke-test.sh - prove the OpenShell path end to end: the gateway,
#                           one throwaway sandbox, and a real model call from
#                           inside it through Models-as-a-Service.
#
# Usage: scripts/openshell-smoke-test.sh [--dry-run] [--model <id>] [--keep-cli]
#
# Checks, in order:
#
#   gateway pod Ready -> CLI connected -> sandbox template rhoai-maas exists ->
#   sandbox created from it with the rhoai-maas provider -> OPENAI_BASE_URL set
#   and OPENAI_API_KEY a placeholder, never the real key -> GET /models ->
#   one chat completion -> the placeholder is refused anywhere but MaaS ->
#   the cluster ingress signer is in the sandbox's CA bundle
#
# --dry-run checks only the gateway: pod Ready and CLI connected. It still
# starts and removes the CLI pod, but creates no sandbox and calls no model.
# A full run costs one short chat completion from the model's tokenRateLimit.
# --model overrides the request model ID, which is otherwise the first one
# /models returns. --keep-cli leaves the CLI pod for scripts/openshell-cli.sh.
#
# The sandbox is deleted on every exit, including failure and Ctrl-C. Only the
# first characters of the key placeholder are printed, never more.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORIG_ARGS=("$@")
DRY_RUN=0
MODEL=""
KEEP_CLI=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --model)    MODEL="$2"; shift 2 ;;
        --keep-cli) KEEP_CLI=1; shift ;;
        -h|--help)  sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "openshell-smoke-test.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

. "${ROOT}/scripts/lib-logging.sh"
start_logging "openshell-smoke-test" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

command -v jq >/dev/null || { echo "Error: 'jq' is not installed." >&2; exit 1; }

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG
"$OC" get --raw /readyz >/dev/null 2>&1 || { echo "Error: cluster API not reachable." >&2; exit 1; }

. "${ROOT}/scripts/lib-openshell-cli.sh"

SANDBOX=""
fail() {   # $1 message, remaining args: hint lines
    echo >&2
    echo "FAIL: $1" >&2
    shift
    local l
    for l in "$@"; do echo "      $l" >&2; done
    exit 1
}

# One EXIT trap: start_logging installed the log footer as the EXIT trap, and a
# second trap statement would replace it. The sandbox goes first, while the CLI
# pod that deletes it still exists.
on_exit() {
    local rc=$?
    if [ -n "$SANDBOX" ]; then
        if oscli_run sandbox delete "$SANDBOX" >/dev/null 2>&1; then
            echo "==> Deleted sandbox ${SANDBOX}"
        else
            echo "WARNING: could not delete sandbox ${SANDBOX}; remove it with:" >&2
            echo "         scripts/openshell-cli.sh -- sandbox delete ${SANDBOX}" >&2
        fi
    fi
    [ "$KEEP_CLI" = 1 ] || oscli_cleanup
    _log_footer "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# Run a shell snippet in the sandbox. Extra environment for the snippet goes in
# as --env, which carries non-secret values only.
sbx_sh() {   # $1 snippet, remaining args: --env KEY=VALUE pairs
    local snippet="$1"; shift
    oscli_run sandbox exec "$SANDBOX" --no-tty --no-login-shell --timeout 120 "$@" -- sh -c "$snippet"
}

# --- gateway ----------------------------------------------------------------
READY="$("$OC" get statefulsets.apps openshell -n "$OSCLI_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
[ "${READY:-0}" -ge 1 ] || fail "the OpenShell gateway is not Ready (StatefulSet ${OSCLI_NS}/openshell)." \
    "No StatefulSet: the openshell policy is not placed; check the openshell and agent-sandbox labels." \
    "No pod: usually admission. \"\$OC\" -n ${OSCLI_NS} describe statefulsets.apps openshell | sed -n '/Events:/,\$p'" \
    "Then: scripts/checkup.sh"
echo "==> Gateway pod Ready"

oscli_ensure_pod || fail "the CLI pod did not start." "See the events printed above."
STATUS="$(oscli_run status 2>&1 || true)"
grep -q 'Connected' <<<"$STATUS" || fail "the CLI cannot reach the gateway." \
    "openshell status said: $(tr '\n' ' ' <<<"$STATUS" | cut -c1-200)" \
    "A TLS error means the gateway certificate is not issued yet; check policy-openshell-gateway-ready."
echo "==> CLI connected: $(grep -o -E 'Version: *[^ ]+' <<<"$STATUS" | head -1)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "Checks passed (dry run: no sandbox, no model call)."
    exit 0
fi

# --- template and sandbox ---------------------------------------------------
# The provider supplies the key placeholder; the template supplies
# OPENAI_BASE_URL, because OpenShell 0.1.6 does not put a provider's config
# values into the sandbox environment. Both come from the openshell-maas
# CronJob.
oscli_run sandbox template get rhoai-maas >/dev/null 2>&1 || fail "no sandbox template rhoai-maas." \
    "The openshell-maas-provider CronJob creates it. Is the openshell-maas label on, and has a run succeeded?" \
    "Trigger one: \"\$OC\" -n ${OSCLI_NS} create job openshell-maas-provider-manual --from=cronjob/openshell-maas-provider"

SANDBOX="smoke-$(date +%s)"
echo "==> Creating sandbox ${SANDBOX} (template rhoai-maas, provider rhoai-maas)"
START="$(date +%s)"
oscli_run sandbox create --name "$SANDBOX" --template rhoai-maas --provider rhoai-maas \
    --no-tty --detach -- sleep 900 >/dev/null || fail "sandbox creation failed." \
    "The supervisor and sandbox images are first pulled here: \"\$OC\" -n ${OSCLI_NS} get pods" \
    "and \"\$OC\" -n ${OSCLI_NS} describe pod <sandbox pod> for ImagePullBackOff or admission errors."
echo "==> Sandbox ready in $(( $(date +%s) - START ))s"

# --- environment ------------------------------------------------------------
ENVOUT="$(sbx_sh 'printf "%s\n" "${OPENAI_BASE_URL:-}"; printf "%s\n" "${OPENAI_API_KEY:-}" | cut -c1-12')"
BASE_URL="$(sed -n 1p <<<"$ENVOUT")"
KEY_PREFIX="$(sed -n 2p <<<"$ENVOUT")"
case "$BASE_URL" in
    https://*) echo "==> OPENAI_BASE_URL=${BASE_URL}" ;;
    *) fail "OPENAI_BASE_URL is not set in the sandbox." \
           "It comes from the rhoai-maas template: scripts/openshell-cli.sh -- sandbox template get rhoai-maas" ;;
esac
case "$KEY_PREFIX" in
    "")      fail "OPENAI_API_KEY is not set in the sandbox." \
                 "It comes from the rhoai-maas provider: scripts/openshell-cli.sh -- provider get rhoai-maas" ;;
    sk-oai-*) fail "the sandbox holds a REAL Models-as-a-Service key, not a placeholder." \
                 "Revoke it, and check the rhoai-maas provider profile was imported." ;;
    *)       echo "==> OPENAI_API_KEY is a placeholder (${KEY_PREFIX}...)" ;;
esac

# --- model calls ------------------------------------------------------------
# The key travels as the placeholder; the sandbox proxy swaps in the real key
# on the way to MaaS.
MODELS="$(sbx_sh 'curl -sS --max-time 30 "$OPENAI_BASE_URL/models" -H "Authorization: Bearer $OPENAI_API_KEY"' 2>&1 || true)"
FIRST="$(jq -r '.data[0].id // empty' <<<"$MODELS" 2>/dev/null || true)"
[ -n "$FIRST" ] || fail "GET ${BASE_URL}/models returned no models." \
    "Response: $(tr '\n' ' ' <<<"$MODELS" | cut -c1-200)" \
    "401: the provider's key expired or was revoked; check ConfigMap ${OSCLI_NS}/openshell-maas-provider-state." \
    "TLS errors: the sandbox does not trust the ingress signer; check ConfigMap ${OSCLI_NS}/openshell-additional-ca." \
    "403 credential_endpoint_mismatch: the rhoai-maas profile names another host than the MaaS gateway."
MODEL="${MODEL:-$FIRST}"
echo "==> GET /models: $(jq -r '[.data[].id] | join(", ")' <<<"$MODELS")"

CHAT="$(sbx_sh 'curl -sS --max-time 120 "$OPENAI_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$SMOKE_MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}]}"' \
    --env "SMOKE_MODEL=${MODEL}" 2>&1 || true)"
ANSWER="$(jq -r '.choices[0].message.content // empty' <<<"$CHAT" 2>/dev/null || true)"
[ -n "$ANSWER" ] || fail "the chat completion returned no answer (model ${MODEL})." \
    "Response: $(tr '\n' ' ' <<<"$CHAT" | cut -c1-200)" \
    "429: the model's tokenRateLimit is spent; retry later or raise it in config.openshiftAiModels."
echo "==> Chat completion from ${MODEL}: $(tr '\n' ' ' <<<"$ANSWER" | cut -c1-80)"

# --- containment ------------------------------------------------------------
# The same placeholder sent to another host must not work: policy blocks the
# connection, or the proxy answers 403 credential_endpoint_mismatch.
NEG="$(sbx_sh 'code=$(curl -sS --max-time 15 -o /dev/null -w "%{http_code}" https://example.com/ \
    -H "Authorization: Bearer $OPENAI_API_KEY" 2>/dev/null); echo "rc=$? code=$code"' 2>&1 || true)"
case "$NEG" in
    *code=2*|*code=3*) fail "the placeholder reached https://example.com (${NEG})." \
                           "Egress is not being enforced; check the sandbox network policy and the CNI." ;;
    *) echo "==> Placeholder refused outside MaaS (${NEG})" ;;
esac

# --- trust ------------------------------------------------------------------
# The cluster ingress signer must be in the sandbox's CA bundle, or nothing
# served on *.apps would verify. Compared on a slice of the certificate's
# base64 body: the gateway re-encodes the bundle at 64 columns, so the body
# survives with only its line breaks changed.
INGRESS_CA="$("$OC" get configmaps default-ingress-cert -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)"
NEEDLE="$(awk '/BEGIN CERT/{f=1;next} /END CERT/{exit} f' <<<"$INGRESS_CA" | tr -d '\n' | cut -c101-260)"
[ -n "$NEEDLE" ] || fail "could not read ConfigMap openshift-config-managed/default-ingress-cert."
TRUST="$(sbx_sh 'b="${SSL_CERT_FILE:-}"; [ -r "$b" ] || { echo "no-bundle $b"; exit 0; }
    if tr -d "\n" < "$b" | grep -qF "$SMOKE_NEEDLE"; then echo "found $b"; else echo "missing $b"; fi' \
    --env "SMOKE_NEEDLE=${NEEDLE}" 2>&1 || true)"
case "$TRUST" in
    found*)   echo "==> Ingress signer present in the sandbox CA bundle (${TRUST#found })" ;;
    missing*) fail "the cluster ingress signer is not in the sandbox CA bundle (${TRUST#missing })." \
                  "The gateway stages ConfigMap ${OSCLI_NS}/openshell-additional-ca at startup; restart it" \
                  "after the signer changes: \"\$OC\" -n ${OSCLI_NS} delete pod openshell-0" ;;
    *)        fail "the sandbox has no readable CA bundle (${TRUST})." ;;
esac

echo
echo "OpenShell smoke test passed."
