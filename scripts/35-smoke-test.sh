#!/usr/bin/env bash
#
# 35-smoke-test.sh - send a real prompt to the model you actually deployed,
#                    through the MaaS gateway, using a real API key.
#
# Usage: scripts/35-smoke-test.sh [--prompt "..."] [--model <id>] [--keep-key]
#
# This is the gap phase 30 leaves open. The guide's verify.sh deploys its own
# throwaway simulator and tests that, so it proves the MaaS platform works -
# not that your model serves traffic. This exercises the real path end to end:
#
#   mint an API key -> list models -> POST /v1/chat/completions -> read the text
#
# It is also the quickest way to catch the silent-simulator problem: if you
# meant to deploy a GPU model and no GPU node was present, the response here
# comes back as obvious stub text.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT="In one sentence, what is Kubernetes?"
MODEL=""
KEEP_KEY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)   PROMPT="$2"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        --keep-key) KEEP_KEY=1; shift ;;
        -h|--help)  sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "35-smoke-test.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

for c in jq curl; do command -v "$c" >/dev/null || { echo "Error: '$c' is not installed." >&2; exit 1; }; done

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG

"$OC" get --raw /readyz >/dev/null 2>&1 || {
    echo "Error: cluster API not reachable." >&2; exit 1; }

"$OC" get crd maasmodelrefs.maas.opendatahub.io >/dev/null 2>&1 || {
    echo "Error: MaaS is not installed. Run scripts/20-deploy-maas.sh first." >&2; exit 1; }

# --- endpoint ---------------------------------------------------------------
CLUSTER_DOMAIN="$("$OC" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
HOST="https://${MAAS_HOSTNAME}"
echo "==> Gateway: ${HOST}"

# --- subscription -----------------------------------------------------------
# An API key is minted against a subscription, and the names are per-model
# (e.g. granite-tiny-gpu-free), so discover rather than hardcode.
SUBSCRIPTION="$("$OC" get maassubscription -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$SUBSCRIPTION" ] || {
    echo "Error: no MaaSSubscription found. Did phase 20 finish deploying a model?" >&2
    echo "       Check: \"\$OC\" get maassubscription -A" >&2
    exit 1
}
echo "==> Subscription: ${SUBSCRIPTION}"

echo "==> Deployed models:"
"$OC" get maasmodelref -A --no-headers 2>/dev/null |
    awk '{printf "    %s/%s\n", $1, $2}' || echo "    (none)"

# --- api key ----------------------------------------------------------------
# Minted with the caller's own OpenShift token; the returned key is what a
# consumer would actually use.
echo "==> Minting an API key"
KEY_RESPONSE="$(curl -sSk --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $("$OC" whoami -t)" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"name\":\"smoke-test\",\"description\":\"scripts/35-smoke-test.sh\",\"expiresIn\":\"1h\",\"subscription\":\"${SUBSCRIPTION}\"}" \
    "${HOST}/maas-api/v1/api-keys" 2>/dev/null || echo '{}')"

API_KEY="$(jq -r '.key // empty' <<<"$KEY_RESPONSE")"
API_KEY_ID="$(jq -r '.id // empty' <<<"$KEY_RESPONSE")"
[ -n "$API_KEY" ] || {
    echo "Error: could not mint an API key." >&2
    echo "       Response: ${KEY_RESPONSE:0:300}" >&2
    exit 1
}
echo "    key id ${API_KEY_ID}"

cleanup() {
    if [ "$KEEP_KEY" -eq 0 ] && [ -n "${API_KEY_ID:-}" ]; then
        curl -sSk --max-time 15 -X DELETE \
            -H "Authorization: Bearer $("$OC" whoami -t)" \
            "${HOST}/maas-api/v1/api-keys/${API_KEY_ID}" >/dev/null 2>&1 || true
        echo "==> Revoked API key ${API_KEY_ID}"
    fi
}
trap cleanup EXIT

# --- model ------------------------------------------------------------------
if [ -z "$MODEL" ]; then
    MODELS="$(curl -sSk --max-time 30 \
        -H "Authorization: Bearer ${API_KEY}" \
        "${HOST}/maas-api/v1/models" 2>/dev/null || echo '{}')"
    MODEL="$(jq -r '.data[0].id // empty' <<<"$MODELS")"
    COUNT="$(jq -r '.data | length // 0' <<<"$MODELS")"
    [ -n "$MODEL" ] || {
        echo "Error: the gateway lists no models." >&2
        echo "       Response: ${MODELS:0:300}" >&2
        exit 1
    }
    echo "==> Gateway lists ${COUNT} model(s); using ${MODEL}"
fi

# --- inference --------------------------------------------------------------
echo "==> Prompt: ${PROMPT}"
RESPONSE="$(curl -sSk --max-time 120 -w '\n%{http_code}' \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg m "$MODEL" --arg p "$PROMPT" \
          '{model:$m, messages:[{role:"user", content:$p}], max_tokens:200}')" \
    "${HOST}/v1/chat/completions" 2>/dev/null || printf '\n000')"

CODE="$(tail -1 <<<"$RESPONSE")"
BODY="$(sed '$d' <<<"$RESPONSE")"

if [ "$CODE" != "200" ]; then
    echo >&2
    echo "FAIL: inference returned HTTP ${CODE}" >&2
    echo "${BODY:0:500}" >&2
    exit 1
fi

CONTENT="$(jq -r '.choices[0].message.content // empty' <<<"$BODY")"
USAGE="$(jq -r '.usage | "prompt=\(.prompt_tokens) completion=\(.completion_tokens)"' <<<"$BODY" 2>/dev/null || true)"

cat <<EOF

--- response ---------------------------------------------------------------
${CONTENT:-(empty)}
----------------------------------------------------------------------------
model:  ${MODEL}
tokens: ${USAGE:-n/a}

EOF

# A real model answers the question; the simulator emits stub text. Worth
# calling out, because deploying the simulator by accident is the single
# easiest mistake to make here.
if [ -z "$CONTENT" ]; then
    echo "WARNING: HTTP 200 but an empty completion - check the model pod logs." >&2
elif grep -qiE 'simulat|lorem ipsum|tiny-gpt2' <<<"${CONTENT}${MODEL}"; then
    echo "NOTE: this looks like the CPU simulator rather than a real model."
    echo "      If you wanted a GPU model: scripts/15-gpu-node.sh up, set"
    echo "      MAAS_MODEL in cluster.env, then re-run phase 20."
fi

echo "Smoke test passed."
