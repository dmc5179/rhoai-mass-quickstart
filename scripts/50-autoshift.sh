#!/usr/bin/env bash
#
# 50-autoshift.sh - put the cluster under AutoShift (RHACM + GitOps) so that
#                   RHOAI, MaaS and the rest arrive as policies rather than
#                   as the imperative phases 15-40.
#
# Usage: scripts/50-autoshift.sh bootstrap   # ACM, GitOps, then AutoShift
#        scripts/50-autoshift.sh adopt       # hub manages itself
#        scripts/50-autoshift.sh status
#        scripts/50-autoshift.sh uninstall
#
# Reads AUTOSHIFT_* from cluster.env. This drives an AutoShift checkout that
# lives outside this repo; nothing here vendors it.
#
# The thing that catches people: the ApplicationSet pulls policy *charts* from
# Git, not from your working copy. Only *values* are read locally. So edits to
# a policy under policies/ do nothing until they are pushed to the branch that
# AUTOSHIFT_GIT_BRANCH names.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

ACTION="${1:-}"; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "50-autoshift.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done
case "$ACTION" in
    bootstrap|adopt|status|uninstall) ;;
    *) echo "Usage: scripts/50-autoshift.sh {bootstrap|adopt|status|uninstall}" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "autoshift" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

command -v helm >/dev/null || { echo "Error: 'helm' is not installed." >&2; exit 1; }

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG
"$OC" get --raw /readyz >/dev/null 2>&1 || { echo "Error: cluster API not reachable." >&2; exit 1; }

: "${AUTOSHIFT_DIR:?AUTOSHIFT_DIR must be set in cluster.env}"
[ -d "${AUTOSHIFT_DIR}/autoshift" ] || {
    echo "Error: ${AUTOSHIFT_DIR} does not look like an AutoShift checkout" >&2
    echo "       (no autoshift/ chart directory inside it)." >&2
    exit 1
}

GITOPS_NS="openshift-gitops"
CLUSTERSET="${AUTOSHIFT_CLUSTERSET:-hub}"

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    echo "==> Operators"
    "$OC" get csv -A --no-headers 2>/dev/null |
        grep -Ei 'advanced-cluster-management|openshift-gitops' | awk '{print "    "$2" "$NF}' || echo "    none"
    echo "==> AutoShift release"
    helm list -n "$GITOPS_NS" 2>/dev/null | grep -i autoshift || echo "    not installed"
    echo "==> ApplicationSet / Applications"
    "$OC" get applicationset -n "$GITOPS_NS" --no-headers 2>/dev/null | awk '{print "    "$1}' || echo "    none"
    "$OC" get applications.argoproj.io -n "$GITOPS_NS" --no-headers 2>/dev/null | wc -l | xargs echo "    applications:"
    echo "==> ManagedClusters and their clusterset"
    "$OC" get managedcluster -o custom-columns='NAME:.metadata.name,SET:.metadata.labels.cluster\.open-cluster-management\.io/clusterset' --no-headers 2>/dev/null || echo "    none"
    echo "==> Policies not Compliant"
    "$OC" get policy -A --no-headers 2>/dev/null | awk '$NF!="Compliant" && NF {print "    "$1"/"$2" "$NF}' || true
    exit 0
fi

# --- uninstall --------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
    echo "==> Removing the AutoShift release (policies stop being reconciled)"
    helm uninstall autoshift -n "$GITOPS_NS" 2>/dev/null || echo "    not installed"
    cat <<EOF

AutoShift is gone. What it deployed is NOT: removing the ApplicationSet stops
reconciliation but leaves the operators and CRs it created in place. Remove
those deliberately, or rebuild the cluster.

ACM and GitOps are also still installed. Remove them with:
    helm uninstall openshift-gitops advanced-cluster-management -n ${GITOPS_NS}
EOF
    exit 0
fi

# --- adopt ------------------------------------------------------------------
# Separate from bootstrap because this is the step that makes policies start
# acting on the hub, and it is worth being able to do it deliberately.
if [ "$ACTION" = "adopt" ]; then
    "$OC" get managedcluster local-cluster >/dev/null 2>&1 || {
        echo "Error: no 'local-cluster' ManagedCluster yet." >&2
        echo "       ACM creates it after install; run bootstrap first and wait." >&2
        exit 1
    }
    echo "==> Adding local-cluster to clusterset '${CLUSTERSET}'"
    "$OC" label managedcluster local-cluster \
        "cluster.open-cluster-management.io/clusterset=${CLUSTERSET}" --overwrite
    echo
    echo "The hub now manages itself. Policies whose placement matches this"
    echo "clusterset will begin reconciling; watch with:"
    echo "    scripts/50-autoshift.sh status"
    exit 0
fi

# --- bootstrap --------------------------------------------------------------
cd "$AUTOSHIFT_DIR"

GIT_REPO="${AUTOSHIFT_GIT_REPO:-}"
GIT_BRANCH="${AUTOSHIFT_GIT_BRANCH:-}"

# Warn loudly rather than silently deploying upstream's policies when the
# intent was to test a branch.
if [ -n "$GIT_BRANCH" ]; then
    echo "==> Policy source: ${GIT_REPO:-<chart default>} @ ${GIT_BRANCH}"
    if git -C "$AUTOSHIFT_DIR" rev-parse --verify "origin/${GIT_BRANCH}" >/dev/null 2>&1; then
        LOCAL="$(git -C "$AUTOSHIFT_DIR" rev-parse HEAD 2>/dev/null || true)"
        REMOTE="$(git -C "$AUTOSHIFT_DIR" rev-parse "origin/${GIT_BRANCH}" 2>/dev/null || true)"
        [ "$LOCAL" = "$REMOTE" ] || cat >&2 <<EOF
    WARNING: your checkout is not identical to origin/${GIT_BRANCH}.
    The ApplicationSet reads policies from Git, never from this directory, so
    unpushed policy edits will NOT be deployed.
EOF
    else
        echo "    WARNING: origin/${GIT_BRANCH} does not exist. Push the branch first," >&2
        echo "    or the ApplicationSet will find no policies." >&2
    fi
else
    echo "==> Policy source: chart default (upstream main)"
fi

echo "==> Installing Red Hat Advanced Cluster Management"
helm upgrade --install advanced-cluster-management advanced-cluster-management

echo "    Waiting for the MultiClusterHub to be Running (up to 20m)"
"$OC" wait --for=create multiclusterhub -A --timeout=10m >/dev/null 2>&1 || true
if ! "$OC" wait --for=jsonpath='{.status.phase}'=Running multiclusterhub --all -A --timeout=20m 2>/dev/null; then
    echo "Error: the MultiClusterHub did not reach Running." >&2
    "$OC" get multiclusterhub -A >&2 2>/dev/null || true
    exit 1
fi

echo "==> Installing OpenShift GitOps"
helm upgrade --install openshift-gitops openshift-gitops -f policies/stable/openshift-gitops/values.yaml

echo "    Waiting for the ArgoCD server (up to 10m)"
"$OC" wait --for=create deployment/openshift-gitops-server -n "$GITOPS_NS" --timeout=10m >/dev/null 2>&1 || true
"$OC" wait --for=condition=Available deployment/openshift-gitops-server -n "$GITOPS_NS" --timeout=10m >/dev/null || {
    echo "Error: the ArgoCD server did not become Available." >&2
    "$OC" get pods -n "$GITOPS_NS" >&2 2>/dev/null || true
    exit 1
}

echo "==> Installing AutoShift"
HELM_ARGS=(upgrade --install autoshift ./autoshift -n "$GITOPS_NS")
[ -n "$GIT_REPO" ]   && HELM_ARGS+=(--set "autoshiftGitRepo=${GIT_REPO}")
[ -n "$GIT_BRANCH" ] && HELM_ARGS+=(--set "autoshiftGitBranchTag=${GIT_BRANCH}")
for f in autoshift/values/global.yaml "autoshift/values/clustersets/${CLUSTERSET}.yaml"; do
    [ -f "$f" ] && HELM_ARGS+=(-f "$f")
done
[ -n "${AUTOSHIFT_EXTRA_VALUES:-}" ] && HELM_ARGS+=(-f "$AUTOSHIFT_EXTRA_VALUES")
helm "${HELM_ARGS[@]}"

cat <<EOF

AutoShift is installed. It is not acting on anything yet - the hub has to be
added to a clusterset first:

    scripts/50-autoshift.sh adopt

Then enable policies by setting their labels to 'true' in the values files
(never on the ManagedCluster directly), re-run the install, and watch:

    scripts/50-autoshift.sh status
EOF
