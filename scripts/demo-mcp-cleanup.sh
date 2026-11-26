#!/usr/bin/env bash
#
# demo-mcp-cleanup.sh - remove what the 2026-11-25 agent-identity MCP demo created.
#
# Usage: scripts/demo-mcp-cleanup.sh [--apply]
#
# A dry run by default: it prints the commands and changes nothing, without
# calling the cluster, so it works while the cluster is parked. --apply runs
# them for real. Every delete uses --ignore-not-found, so re-running, or
# cleaning an already partly cleaned cluster, is fine.
#
# What each step removes:
#
#   1. Nothing on the AutoShift side. The mcp-gateway policy must be turned off
#      FIRST: label mcp-gateway: 'false' for the clusterset in the fork's
#      autoshift/values/clustersets/hub.yaml, then scripts/50-autoshift.sh
#      bootstrap. Otherwise ACM recreates everything the steps below delete.
#      With --apply the script refuses to run while the local-cluster
#      ManagedCluster still carries the label autoshift.io/mcp-gateway=true.
#   2. The server registrations rhokp-docs (namespace rhokp) and openshift-mcp
#      (namespace openshift-mcp-server), and their routes rhokp-docs-mcp and
#      openshift-mcp-mcp.
#   3. In openshift-ingress: the mcp-gateway Gateway (deleting it also removes
#      its AWS load balancer), the mcp-gateway Route, the mcp-mcp-gateway
#      ReferenceGrant, the mcp-gateway-mcp AuthPolicy and the
#      mcp-gateway-authn-ssl EnvoyFilter.
#   4. The mcp-gateway MCPGatewayExtension, then the mcp-gateway namespace.
#   5. The OpenShift MCP server: helm uninstall openshift-mcp-server, then the
#      openshift-mcp-server namespace. The release's ClusterRoleBindings are
#      cluster-scoped, so any whose name contains openshift-mcp-server are
#      deleted separately.
#   6. The demo-agent-b-view RoleBinding in agent-id-test.
#
# NOT removed: the GatewayClass openshift-default. It is the cluster's shared
# gateway class; the MaaS gateway uses it too.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

usage() { sed -n '2,35p' "${BASH_SOURCE[0]}"; }
APPLY=0
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "")        ;;
    --apply)   APPLY=1 ;;
    *) echo "Usage: scripts/demo-mcp-cleanup.sh [--apply]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "demo-mcp-cleanup" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

# The installer kubeconfig: certificate-based, so it works whatever the cluster's
# sign-in is, and it is the way back in when Keycloak or the router is down.
KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
export KUBECONFIG

del() { # del <resource> <name> [namespace] - print the delete, run it with --apply
    local -a ns=()
    [ $# -ge 3 ] && ns=(-n "$3")
    echo "  oc delete $1 $2${ns[*]+" ${ns[*]}"} --ignore-not-found"
    if [ "$APPLY" -eq 1 ]; then
        "$OC" delete "$1" "$2" ${ns[@]+"${ns[@]}"} --ignore-not-found >/dev/null
    fi
}

echo "==> 1. AutoShift side: the mcp-gateway policy must go first"
echo "    Set mcp-gateway: 'false' for the clusterset in"
echo "    ${AUTOSHIFT_DIR}/autoshift/values/clustersets/hub.yaml, then run:"
echo "      scripts/50-autoshift.sh bootstrap"
echo "    Otherwise ACM recreates everything the steps below delete."
if [ "$APPLY" -eq 1 ]; then
    lbl="$("$OC" get managedclusters.cluster.open-cluster-management.io local-cluster \
        -o jsonpath='{.metadata.labels.autoshift\.io/mcp-gateway}' 2>/dev/null || true)"
    if [ "$lbl" = "true" ]; then
        echo "Error: local-cluster still carries the label autoshift.io/mcp-gateway=true." >&2
        echo "       Turn the mcp-gateway policy off and re-run scripts/50-autoshift.sh" >&2
        echo "       bootstrap before cleaning up." >&2
        exit 1
    fi
    echo "    The label is off; continuing."
fi

echo "==> 2. Server registrations and their routes"
del mcpserverregistrations.mcp.kuadrant.io rhokp-docs rhokp
del mcpserverregistrations.mcp.kuadrant.io openshift-mcp openshift-mcp-server
del httproutes.gateway.networking.k8s.io rhokp-docs-mcp rhokp
del httproutes.gateway.networking.k8s.io openshift-mcp-mcp openshift-mcp-server

echo "==> 3. openshift-ingress: the gateway and its attachments"
echo "    Deleting the Gateway also removes its AWS load balancer."
del gateways.gateway.networking.k8s.io mcp-gateway openshift-ingress
del routes.route.openshift.io mcp-gateway openshift-ingress
del referencegrants.gateway.networking.k8s.io mcp-mcp-gateway openshift-ingress
del authpolicies.kuadrant.io mcp-gateway-mcp openshift-ingress
del envoyfilters.networking.istio.io mcp-gateway-authn-ssl openshift-ingress

echo "==> 4. MCPGatewayExtension, then its namespace"
del mcpgatewayextensions.mcp.kuadrant.io mcp-gateway mcp-gateway
del namespace mcp-gateway

echo "==> 5. The OpenShift MCP server (Helm release), then its namespace"
if [ "$APPLY" -eq 1 ]; then
    "$HELM" uninstall openshift-mcp-server -n openshift-mcp-server
else
    echo "  helm uninstall openshift-mcp-server -n openshift-mcp-server"
fi
del namespace openshift-mcp-server
echo "    The release's ClusterRoleBindings are cluster-scoped; deleting any whose"
echo "    name contains openshift-mcp-server:"
if [ "$APPLY" -eq 1 ]; then
    crbs="$("$OC" get clusterrolebindings.rbac.authorization.k8s.io -o name 2>/dev/null | grep 'openshift-mcp-server' || true)"
    while IFS= read -r crb; do
        [ -n "$crb" ] || continue
        echo "  oc delete $crb --ignore-not-found"
        "$OC" delete "$crb" --ignore-not-found >/dev/null
    done <<<"$crbs"
else
    echo "  oc get clusterrolebindings.rbac.authorization.k8s.io -o name | grep openshift-mcp-server | xargs -r oc delete --ignore-not-found"
fi

echo "==> 6. Demo leftovers"
del rolebindings.rbac.authorization.k8s.io demo-agent-b-view agent-id-test

echo
if [ "$APPLY" -eq 1 ]; then
    echo "Cleanup applied. Left standing: the GatewayClass openshift-default (the MaaS gateway uses it too)."
else
    echo "Dry run - nothing was changed. Re-run with --apply to delete."
fi
