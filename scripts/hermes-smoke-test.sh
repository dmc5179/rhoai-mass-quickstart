#!/usr/bin/env bash
#
# hermes-smoke-test.sh - prove the Hermes agent path end to end: Hermes and
#                        its MaaS key, Open WebUI wiring, then one real agent
#                        turn that must call a tool.
#
# Usage: scripts/hermes-smoke-test.sh [--dry-run] [--prompt "..."]
#
# The Hermes counterpart of 35-smoke-test.sh. It checks, in order:
#
#   Hermes pod Ready -> MaaS key stored and unexpired -> Open WebUI holds the
#   same Hermes API key, and its Route answers -> POST /v1/chat/completions
#   to the Hermes API server -> the tool call recorded in Hermes' state.db
#
# --dry-run stops before the agent turn. The turn costs about 28k tokens of
# the model's tokenRateLimit and leaves one session in Hermes' history.
# Secrets are never printed: the key is piped to curl inside the pod.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Captured before the parse loop consumes "$@"; the logging re-exec
# needs to hand the child the same arguments this run got.
ORIG_ARGS=("$@")
PROMPT="Use your terminal tool to run the command: uname -s. Then reply with only the exact output of that command."
DEFAULT_PROMPT=1
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)   PROMPT="$2"; DEFAULT_PROMPT=0; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "hermes-smoke-test.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

. "${ROOT}/scripts/lib-logging.sh"
start_logging "hermes-smoke-test" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}


for c in jq curl sha256sum; do command -v "$c" >/dev/null || { echo "Error: '$c' is not installed." >&2; exit 1; }; done

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG

"$OC" get --raw /readyz >/dev/null 2>&1 || {
    echo "Error: cluster API not reachable." >&2; exit 1; }

fail() {   # $1 message, remaining args: hint lines
    echo >&2
    echo "FAIL: $1" >&2
    shift
    local l
    for l in "$@"; do echo "      $l" >&2; done
    exit 1
}

# --- Hermes -----------------------------------------------------------------
# Found by label, not by a fixed namespace: hermesAgent.namespace is a setting.
HNS="$("$OC" get deployments.apps -A -l app.kubernetes.io/name=hermes-agent \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
[ -n "$HNS" ] || fail "no Hermes deployment on this cluster." \
    "Hermes is deployed by the hermes-agent policy: set the hermes-agent label and" \
    "config.hermesAgent.model in the cluster's values, then re-bootstrap." \
    "Check: \"\$OC\" get policy -A | grep hermes"
echo "==> Hermes namespace: ${HNS}"

READY="$("$OC" get deployments.apps hermes-agent -n "$HNS" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
[ "${READY:-0}" -ge 1 ] || fail "the Hermes pod is not Ready." \
    "Its startup log says why: \"\$OC\" logs deploy/hermes-agent -n ${HNS} | grep bootstrap" \
    "A 403 there means its ServiceAccount group is missing from the model's accessGroups."
echo "==> Hermes pod Ready"

# --- MaaS key ---------------------------------------------------------------
# The pod mints its own key and records the expiry on the Secret. Only the
# annotation is read; the key itself never leaves the cluster.
EXP="$("$OC" get secret hermes-maas-key -n "$HNS" \
    -o jsonpath='{.metadata.annotations.hermes\.autoshift\.io/expires-at}' 2>/dev/null || true)"
[ -n "$EXP" ] || fail "no stored MaaS key (Secret ${HNS}/hermes-maas-key)." \
    "The pod mints it at startup: \"\$OC\" logs deploy/hermes-agent -n ${HNS} | grep bootstrap"
NOW="$(date +%s)"
[ "$EXP" -gt "$NOW" ] || fail "the stored MaaS key expired $(date -u -d "@${EXP}" +%Y-%m-%dT%H:%MZ)." \
    "Renewal restarts the pod before expiry; its log says why it did not:" \
    "\"\$OC\" logs deploy/hermes-agent -n ${HNS} | grep bootstrap"
echo "==> MaaS key valid until $(date -u -d "@${EXP}" +%Y-%m-%dT%H:%MZ) (about $(( (EXP - NOW) / 86400 )) days)"

# Fingerprint for comparison only.
API_FP="$("$OC" get secret hermes-api-key -n "$HNS" -o jsonpath='{.data.API_SERVER_KEY}' 2>/dev/null |
    base64 -d | sha256sum | cut -c1-12 || true)"
[ -n "$API_FP" ] && [ "$API_FP" != "$(printf '' | sha256sum | cut -c1-12)" ] ||
    fail "no Hermes API key (Secret ${HNS}/hermes-api-key)." \
        "The hermes-agent policy generates it; check: \"\$OC\" get policy -A | grep hermes"

# --- Open WebUI -------------------------------------------------------------
# Optional: Hermes works without it. When present, it must hold the same
# Hermes API key, or every chat fails with 401 while the pod looks healthy.
ONS="$("$OC" get deployments.apps -A -l app.kubernetes.io/name=open-webui \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
if [ -z "$ONS" ]; then
    echo "==> Open WebUI: not deployed (skipped)"
else
    OREADY="$("$OC" get deployments.apps -n "$ONS" -l app.kubernetes.io/name=open-webui \
        -o jsonpath='{.items[0].status.availableReplicas}' 2>/dev/null || true)"
    [ "${OREADY:-0}" -ge 1 ] || fail "the Open WebUI pod is not Ready." \
        "\"\$OC\" get pods -n ${ONS}; \"\$OC\" get policy -A | grep open-webui"
    OWUI_FP="$("$OC" get secret open-webui-hermes -n "$ONS" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null |
        base64 -d | sha256sum | cut -c1-12 || true)"
    [ "$OWUI_FP" = "$API_FP" ] || fail "Open WebUI holds a different Hermes API key than Hermes." \
        "The open-webui policy copies ${HNS}/hermes-api-key into ${ONS}/open-webui-hermes;" \
        "check it is Compliant: \"\$OC\" get policy -A | grep open-webui"
    echo "==> Open WebUI Ready, holding the current Hermes API key"

    ROUTE="$("$OC" get routes.route.openshift.io -n "$ONS" -l app.kubernetes.io/name=open-webui \
        -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
    if [ -n "$ROUTE" ]; then
        RCODE="$(curl -sk --connect-timeout 10 --max-time 30 -o /dev/null \
            -w '%{http_code} %{redirect_url}' "https://${ROUTE}/" 2>/dev/null || echo 000)"
        case "$RCODE" in
            302*oauth/authorize*) echo "==> Route https://${ROUTE} redirects to OpenShift sign-in" ;;
            200*)                 echo "==> Route https://${ROUTE} answers (built-in sign-in)" ;;
            *) fail "the Open WebUI Route answered '${RCODE%% *}'." \
                   "\"\$OC\" get pods -n ${ONS}; with auth openshift, also the oauth-proxy container log." ;;
        esac
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "Checks passed (dry run: no agent turn)."
    exit 0
fi

# --- agent turn -------------------------------------------------------------
# Run from inside the pod against the API server on localhost, so the test
# does not depend on a Route and the key never appears on a command line:
# the key and the request body arrive on stdin.
#
# A fresh session id per run. Without one Hermes derives the session from the
# first message, so a repeated prompt resumes the previous run's session:
# history grows each time and old tool calls would be counted as new.
BODY="$(jq -nc --arg p "$PROMPT" '{model:"hermes-agent", messages:[{role:"user", content:$p}]}')"
echo "==> Prompt: ${PROMPT}"
echo "    (an agent turn with a tool call takes a minute or two)"
T0="$(date +%s)"
SESSION_REQ="smoke-test-${T0}-$$"
# shellcheck disable=SC2016  # $K and $1 expand in the pod's shell
RAW="$({ "$OC" get secret hermes-api-key -n "$HNS" -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d; echo
        printf '%s' "$BODY"; } |
    "$OC" exec -i deploy/hermes-agent -n "$HNS" -c hermes -- sh -c '
        read -r K
        curl -sS -i --max-time 300 -w "\n%{http_code}" \
            -H "Authorization: Bearer $K" -H "Content-Type: application/json" \
            -H "X-Hermes-Session-Id: $1" \
            --data-binary @- http://127.0.0.1:${API_SERVER_PORT:-8642}/v1/chat/completions' \
        sh "$SESSION_REQ" 2>/dev/null || printf '\n000')"

CODE="$(tail -1 <<<"$RAW")"
SESSION="$(tr -d '\r' <<<"$RAW" | sed -n 's/^[Xx]-[Hh]ermes-[Ss]ession-[Ii]d: *//p' | head -1)"
SESSION="${SESSION:-$SESSION_REQ}"
# The body is the line after the header block's blank line, minus the code.
RESP="$(sed '$d' <<<"$RAW" | tr -d '\r' | awk 'b{print} /^$/{b=1}')"

hint_from_logs() {
    # Upstream errors from the gateway show up in the pod log, not the response.
    local lines
    lines="$("$OC" logs deploy/hermes-agent -n "$HNS" -c hermes --since=10m 2>/dev/null |
        grep -E ' 40[13] | 429|Too Many Requests|Unauthorized|Forbidden|timed out|Connection refused' |
        tail -5 | cut -c1-200 || true)"
    [ -z "$lines" ] && return 0
    echo "      Recent errors in the Hermes log:" >&2
    # shellcheck disable=SC2001
    sed 's/^/        /' <<<"$lines" >&2
    echo "      401/403 from MaaS: key or accessGroups; 429: the model's tokenRateLimit." >&2
}

if [ "$CODE" != "200" ]; then
    echo "${RESP:0:500}" >&2
    case "$CODE" in
        401) fail "the Hermes API server refused the key (HTTP 401)." \
                 "Secret ${HNS}/hermes-api-key no longer matches the running pod; restart it:" \
                 "\"\$OC\" rollout restart deploy/hermes-agent -n ${HNS}" ;;
        000) hint_from_logs
             fail "no response from the Hermes API server within 300s." \
                 "Hermes waits on the model through the MaaS gateway; check the model pod and the log above." ;;
        *)   hint_from_logs
             fail "the Hermes API server returned HTTP ${CODE}." ;;
    esac
fi

CONTENT="$(jq -r '.choices[0].message.content // empty' <<<"$RESP" 2>/dev/null || true)"
USAGE="$(jq -r '.usage | "prompt=\(.prompt_tokens) completion=\(.completion_tokens)"' <<<"$RESP" 2>/dev/null || true)"

# --- tool call, from Hermes' own record -------------------------------------
# The API response carries only the final answer. The tool calls are in the
# session store; read it read-only with the image's own Python, taking only
# messages written during this run.
TOOLS="$("$OC" exec deploy/hermes-agent -n "$HNS" -c hermes -- \
    /opt/hermes/.venv/bin/python -c '
import json, os, sqlite3, sys
sid, t0 = sys.argv[1], float(sys.argv[2])
db = sqlite3.connect("file:%s/state.db?mode=ro" % os.environ.get("HERMES_HOME", "/opt/data"), uri=True)
print("session\t" + sid)
for role, calls, name, content in db.execute(
        "select role, tool_calls, tool_name, content from messages"
        " where session_id = ? and timestamp >= ? order by id", (sid, t0 - 5)):
    if role == "assistant" and calls:
        for c in json.loads(calls):
            f = c.get("function", {})
            print("call\t%s\t%s" % (f.get("name", "?"), (f.get("arguments") or "")[:150].replace("\n", " ")))
    elif role == "tool":
        print("result\t%s\t%s" % (name or "", (content or "")[:150].replace("\n", " ")))
' "$SESSION" "$T0" 2>/dev/null || true)"

SESSION="$(awk -F'\t' '$1=="session"{print $2}' <<<"$TOOLS")"
CALLS="$(awk -F'\t' '$1=="call"{printf "    %s %s\n", $2, $3}' <<<"$TOOLS")"
RESULTS="$(awk -F'\t' '$1=="result"{printf "    %s\n", $3}' <<<"$TOOLS")"

cat <<EOF

--- response ---------------------------------------------------------------
${CONTENT:-(empty)}
--- tool calls -------------------------------------------------------------
${CALLS:-    (none)}
--- tool results -----------------------------------------------------------
${RESULTS:-    (none)}
----------------------------------------------------------------------------
session: ${SESSION:-unknown}
tokens:  ${USAGE:-n/a}
time:    $(( $(date +%s) - T0 ))s

EOF

[ -n "$CONTENT" ] || { hint_from_logs; fail "HTTP 200 but an empty answer." \
    "Hermes reports model errors in its log: \"\$OC\" logs deploy/hermes-agent -n ${HNS} --since=10m"; }

[ -n "$CALLS" ] || fail "the agent answered without calling a tool." \
    "The model must emit structured tool calls: check that its LLMInferenceService" \
    "enables tool calling with the right parser for the model (--tool-call-parser)."

if [ "$DEFAULT_PROMPT" -eq 1 ] && ! grep -q 'Linux' <<<"$CONTENT"; then
    echo "WARNING: the tool ran, but the answer does not contain 'Linux'; read the results above." >&2
fi

echo "Hermes smoke test passed."
