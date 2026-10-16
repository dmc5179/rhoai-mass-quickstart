#!/usr/bin/env bash
#
# 40-lightspeed.sh - install OpenShift Lightspeed and point it at the model
#                    you are serving through MaaS.
#
# Usage: scripts/40-lightspeed.sh install [--model <id>] [--key-ttl <dur>]
#        scripts/40-lightspeed.sh status
#        scripts/40-lightspeed.sh uninstall
#
# Optional. Lightspeed is the AI assistant in the OpenShift web console; this
# wires it to your own MaaS-hosted model instead of a SaaS provider, so no
# cluster data leaves the environment.
#
# MaaS is an OpenAI-compatible endpoint with bearer auth, which is exactly
# what Lightspeed's rhoai_vllm provider expects. The only wrinkle is the API
# key: MaaS keys carry an expiry, and Lightspeed holds its key in a Secret
# with no rotation of its own, so --key-ttl defaults to a year. Re-run
# `install` to mint a fresh key and update the Secret.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

ACTION="${1:-}"; shift || true
MODEL=""
KEY_TTL="8760h"     # one year

while [ $# -gt 0 ]; do
    case "$1" in
        --model)   MODEL="$2"; shift 2 ;;
        --key-ttl) KEY_TTL="$2"; shift 2 ;;
        *) echo "40-lightspeed.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    install|status|uninstall) ;;
    *) echo "Usage: scripts/40-lightspeed.sh {install|status|uninstall} [--model <id>] [--key-ttl <dur>]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "lightspeed" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

for c in jq curl; do command -v "$c" >/dev/null || { echo "Error: '$c' is not installed." >&2; exit 1; }; done

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG
"$OC" get --raw /readyz >/dev/null 2>&1 || { echo "Error: cluster API not reachable." >&2; exit 1; }

NS="openshift-lightspeed"
SECRET="maas-api-key"

# --- status / uninstall -----------------------------------------------------
if [ "$ACTION" = "status" ]; then
    echo "==> Operator"
    "$OC" get csv -n "$NS" --no-headers 2>/dev/null | grep -i lightspeed || echo "    not installed"
    echo "==> OLSConfig"
    "$OC" get olsconfig cluster -o jsonpath='{.spec.ols.defaultProvider} / {.spec.ols.defaultModel}{"\n"}' 2>/dev/null || echo "    none"
    echo "==> Pods"
    "$OC" get pods -n "$NS" --no-headers 2>/dev/null || echo "    none"
    exit 0
fi

if [ "$ACTION" = "uninstall" ]; then
    echo "==> Removing OLSConfig, Secret, Subscription and CSV"
    "$OC" delete olsconfig cluster --ignore-not-found
    "$OC" delete secret "$SECRET" -n "$NS" --ignore-not-found
    "$OC" delete subscription lightspeed-operator -n "$NS" --ignore-not-found
    for csv in $("$OC" get csv -n "$NS" -o name 2>/dev/null | grep -i lightspeed || true); do
        "$OC" delete "$csv" -n "$NS" --ignore-not-found
    done
    echo "    The ${NS} namespace is left in place."
    exit 0
fi

# --- install ----------------------------------------------------------------
"$OC" get crd maasmodelrefs.maas.opendatahub.io >/dev/null 2>&1 || {
    echo "Error: MaaS is not installed. Run scripts/20-deploy-maas.sh first." >&2; exit 1; }

. "${ROOT}/scripts/lib-oc-token.sh"
ensure_oc_token || exit 1
trap cleanup_oc_token EXIT

CLUSTER_DOMAIN="$("$OC" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
HOST="https://${MAAS_HOSTNAME}"

SUBSCRIPTION="$("$OC" get maassubscription -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$SUBSCRIPTION" ] || { echo "Error: no MaaSSubscription found." >&2; exit 1; }

echo "==> Gateway:      ${HOST}"
echo "==> Subscription: ${SUBSCRIPTION}"

# --- operator ---------------------------------------------------------------
echo "==> Installing the OpenShift Lightspeed operator"
"$OC" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-lightspeed-og
  namespace: ${NS}
spec:
  targetNamespaces:
  - ${NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lightspeed-operator
  namespace: ${NS}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: lightspeed-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "==> Waiting for the operator to install (up to 10m)"
"$OC" wait --for=jsonpath='{.status.installedCSV}' subscription/lightspeed-operator \
    -n "$NS" --timeout=5m >/dev/null || {
    echo "Error: the subscription never reported an installed CSV." >&2
    echo "       Check: \"\$OC\" get subscription,csv -n ${NS}" >&2
    exit 1
}
CSV="$("$OC" get subscription lightspeed-operator -n "$NS" -o jsonpath='{.status.installedCSV}')"
"$OC" wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${CSV}" -n "$NS" --timeout=10m >/dev/null || {
    echo "Error: ${CSV} did not reach Succeeded." >&2; exit 1; }
echo "    ${CSV}"

# --for=create first: --for=condition on a resource that does not exist yet
# fails instantly with "no matching resources found" rather than waiting.
"$OC" wait --for=create crd/olsconfigs.ols.openshift.io --timeout=5m >/dev/null
"$OC" wait --for=condition=established crd/olsconfigs.ols.openshift.io --timeout=2m >/dev/null

# --- model ------------------------------------------------------------------
# Mint a key first: the model listing is served by the gateway, which needs
# one, and it is also what Lightspeed will authenticate with.
echo "==> Minting a MaaS API key (ttl ${KEY_TTL})"
KEY_RESPONSE="$(curl -sSk --max-time 30 \
    -H "Authorization: Bearer $("$OC" whoami -t)" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"name\":\"openshift-lightspeed\",\"description\":\"scripts/40-lightspeed.sh\",\"expiresIn\":\"${KEY_TTL}\",\"subscription\":\"${SUBSCRIPTION}\"}" \
    "${HOST}/maas-api/v1/api-keys" 2>/dev/null || echo '{}')"
API_KEY="$(jq -r '.key // empty' <<<"$KEY_RESPONSE")"
[ -n "$API_KEY" ] || {
    echo "Error: could not mint an API key." >&2
    echo "       Response: ${KEY_RESPONSE:0:300}" >&2
    exit 1
}

if [ -z "$MODEL" ]; then
    MODEL="$(curl -sSk --max-time 30 -H "Authorization: Bearer ${API_KEY}" \
        "${HOST}/maas-api/v1/models" 2>/dev/null | jq -r '.data[0].id // empty')"
    [ -n "$MODEL" ] || { echo "Error: the gateway lists no models." >&2; exit 1; }
fi
echo "==> Model: ${MODEL}"

# --- credentials + config ---------------------------------------------------
# The key name is always "apitoken" regardless of provider.
echo "==> Storing the key in ${NS}/${SECRET}"
"$OC" create secret generic "$SECRET" -n "$NS" \
    --from-literal=apitoken="$API_KEY" \
    --dry-run=client -o yaml | "$OC" apply -f - >/dev/null

# The provider URL must end in /v1.
echo "==> Applying the OLSConfig"
"$OC" apply -f - <<EOF
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
spec:
  llm:
    providers:
    - name: maas
      type: rhoai_vllm
      url: ${HOST}/v1
      credentialsSecretRef:
        name: ${SECRET}
      models:
      - name: ${MODEL}
  ols:
    defaultProvider: maas
    defaultModel: ${MODEL}
EOF

echo "==> Waiting for the Lightspeed service to come up (up to 10m)"
if ! "$OC" wait --for=condition=Available deployment -l app.kubernetes.io/part-of=openshift-lightspeed \
        -n "$NS" --timeout=10m 2>/dev/null; then
    echo "    Deployments did not all report Available. Current state:" >&2
    "$OC" get pods -n "$NS" >&2 || true
    echo "    Check: \"\$OC\" logs -n ${NS} -l app.kubernetes.io/part-of=openshift-lightspeed" >&2
    exit 1
fi

cat <<EOF

OpenShift Lightspeed is wired to your MaaS endpoint.

    provider: maas (rhoai_vllm)
    url:      ${HOST}/v1
    model:    ${MODEL}

Open the OpenShift web console and use the Lightspeed panel. Questions are
answered by the model running on your own GPU node - nothing leaves the
cluster.

The API key expires in ${KEY_TTL}. Re-run this to mint a fresh one:

    scripts/40-lightspeed.sh install
EOF
