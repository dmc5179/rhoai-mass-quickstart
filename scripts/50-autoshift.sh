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

# Prefer the helm 00-init.sh fetched, for the same reason we address oc by
# explicit path: no collision with whatever is on PATH.
HELM="${HELM:-$(command -v helm || true)}"
[ -x "$HELM" ] || { echo "Error: helm not found. Run scripts/00-init.sh." >&2; exit 1; }

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

# Where the ACM and GitOps helm RELEASE RECORDS live. This is bookkeeping only -
# both charts create their own operator namespaces - but it has to be pinned.
# Left unpinned, helm falls back to whatever namespace the kubeconfig context
# happens to point at, so the same command finds the release one day and
# decides to do a fresh install the next, which then fails on the namespaces
# the existing release already owns:
#
#   Namespace "openshift-gitops-operator" ... cannot be imported into the
#   current release: ... must equal "openshift-machine-api": current value is
#   "default"
#
# 'default' is where an unpinned run from a fresh kubeconfig would have put
# them, so it is the compatible choice rather than a tasteful one. Override
# only if your releases are already somewhere else.
OPERATOR_RELEASE_NS="${AUTOSHIFT_OPERATOR_RELEASE_NS:-default}"

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    # Every probe here is allowed to fail: before ACM and GitOps are installed
    # their CRDs do not exist, and with set -e + pipefail a missing CRD would
    # abort the report halfway through rather than saying "none".
    set +e
    echo "==> Operators"
    "$OC" get csv -A --no-headers 2>/dev/null |
        grep -Ei 'advanced-cluster-management|openshift-gitops' | awk '{print "    "$2" "$NF}' || echo "    none"
    echo "==> AutoShift release"
    "$HELM" list -n "$GITOPS_NS" 2>/dev/null | grep -i autoshift || echo "    not installed"
    echo "==> ApplicationSet"
    "$OC" get applicationset -n "$GITOPS_NS" --no-headers 2>/dev/null | awk '{print "    "$1}' || true
    echo "==> Applications"
    "$OC" get applications.argoproj.io -n "$GITOPS_NS" --no-headers 2>/dev/null | awk '{print "    "$1" "$NF}' || true
    echo "==> ManagedClusters"
    "$OC" get managedcluster -o custom-columns='NAME:.metadata.name,SET:.metadata.labels.cluster\.open-cluster-management\.io/clusterset' --no-headers 2>/dev/null | sed 's/^/    /' || true
    echo "==> Policies not Compliant"
    "$OC" get policy -A --no-headers 2>/dev/null | awk '$NF!="Compliant" && NF {print "    "$1"/"$2" "$NF}' || true
    set -e
    exit 0
fi

# --- uninstall --------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
    echo "==> Removing the AutoShift release (policies stop being reconciled)"
    "$HELM" uninstall autoshift -n "$GITOPS_NS" 2>/dev/null || echo "    not installed"
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

# Installing ACM through this chart has two sharp edges, both stemming from
# the MultiClusterHub being created by a post-install hook:
#
#  1. helm does not re-run post-install hooks on an upgrade. Once ANY release
#     record exists - including a failed one - `upgrade --install` reports
#     success and silently never creates the MultiClusterHub.
#
#  2. On a fresh cluster the hook fires before the operator's validating
#     webhook has endpoints, so it is rejected:
#       no endpoints available for service "multiclusterhub-operator-webhook"
#     The chart waits for the multiclusterhubs CRD, but the CRD is registered
#     by the CSV well before the webhook pod is serving.
#
# The invariant worth enforcing is simple: if there is no MultiClusterHub,
# the hook has not run, whatever the release record says. So any pre-existing
# release without an MCH is removed and installed cleanly.
ACM_NS="open-cluster-management"

acm_mch_exists() { "$OC" get multiclusterhub multiclusterhub -n "$ACM_NS" >/dev/null 2>&1; }

acm_wait_ns_gone() {
    local deadline=$(( $(date +%s) + 300 ))
    while "$OC" get namespace "$ACM_NS" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "Error: the ${ACM_NS} namespace is stuck Terminating." >&2
            return 1
        }
        sleep 5
    done
}

# Install with --no-hooks, then create the MultiClusterHub ourselves once the
# webhook is actually serving. This sidesteps both edges instead of retrying
# around them:
#
#   - no failed release record, so nothing later degrades into an upgrade that
#     silently skips the hook
#   - the MCH is created strictly after the webhook has endpoints
#
# The MCH is rendered from the chart's own template rather than written out
# here, so the chart stays the source of truth for its content. Note
# ignoreHelmHooks does NOT help: it gates only the CRD-reader and CRD-wait
# hooks, not acm-mch.yaml.
acm_render_mch() {
    "$HELM" template advanced-cluster-management advanced-cluster-management \
        -n "$OPERATOR_RELEASE_NS" --show-only templates/acm-mch.yaml 2>/dev/null
}

acm_wait_webhook() {
    local deadline=$(( $(date +%s) + 600 ))
    until [ -n "$("$OC" get endpoints multiclusterhub-operator-webhook -n "$ACM_NS" \
                  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "Error: the ACM webhook never got endpoints." >&2
            echo "       Check: \"\$OC\" get pods -n ${ACM_NS}" >&2
            return 1
        }
        sleep 10
    done
}

install_acm() {
    if acm_mch_exists; then
        echo "==> MultiClusterHub already exists; leaving it alone"
        return 0
    fi

    echo "    Installing the operator (hooks deferred)"
    "$HELM" upgrade --install advanced-cluster-management advanced-cluster-management \
        -n "$OPERATOR_RELEASE_NS" --no-hooks || return 1

    echo "    Waiting for the operator CSV to succeed"
    "$OC" wait --for=create "namespace/${ACM_NS}" --timeout=5m >/dev/null 2>&1 || true
    local deadline=$(( $(date +%s) + 900 ))
    until "$OC" get csv -n "$ACM_NS" --no-headers 2>/dev/null | grep -q 'advanced-cluster-management.*Succeeded'; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "Error: the ACM operator CSV never reached Succeeded." >&2
            "$OC" get csv -n "$ACM_NS" >&2 2>/dev/null || true
            return 1
        }
        sleep 10
    done

    echo "    Waiting for the validating webhook to serve"
    acm_wait_webhook || return 1

    echo "    Creating the MultiClusterHub"
    acm_render_mch | "$OC" apply -f - || return 1
}

echo "==> Installing Red Hat Advanced Cluster Management"
install_acm || exit 1

# Wait by name in its own namespace. An --all/-A form would hit the trap that
# --for=jsonpath fails instantly with "no matching resources found" when
# nothing matches yet, rather than waiting for it to appear.
echo "    Waiting for the MultiClusterHub to be created (up to 10m)"
if ! "$OC" wait --for=create "multiclusterhub/multiclusterhub" -n "$ACM_NS" --timeout=10m >/dev/null 2>&1; then
    echo "Error: the MultiClusterHub was never created." >&2
    echo "       The chart creates it from a post-install hook; if the release" >&2
    echo "       shows as an upgrade, that hook did not run." >&2
    echo "       Check: \"\$HELM\" list -a -A  and  \"\$OC\" get multiclusterhub -A" >&2
    exit 1
fi
echo "    Waiting for it to reach Running (up to 20m)"
if ! "$OC" wait --for=jsonpath='{.status.phase}'=Running \
        "multiclusterhub/multiclusterhub" -n "$ACM_NS" --timeout=20m; then
    echo "Error: the MultiClusterHub did not reach Running." >&2
    "$OC" get multiclusterhub -n "$ACM_NS" >&2 2>/dev/null || true
    "$OC" get pods -n "$ACM_NS" --no-headers 2>/dev/null | grep -v Running | head >&2 || true
    exit 1
fi

echo "==> Installing OpenShift GitOps"
"$HELM" upgrade --install openshift-gitops openshift-gitops \
    -n "$OPERATOR_RELEASE_NS" -f policies/stable/openshift-gitops/values.yaml

# Do not assume the instance name. AutoShift's ArgoCD is called infra-gitops,
# so the server deployment is infra-gitops-server, not openshift-gitops-server.
# Select on the labels the operator stamps instead, which hold whatever the
# instance is called.
echo "    Waiting for the ArgoCD server (up to 10m)"
"$OC" wait --for=create deployment \
    -l 'app.kubernetes.io/part-of=argocd,app.kubernetes.io/component=server' \
    -n "$GITOPS_NS" --timeout=10m >/dev/null 2>&1 || true
if ! "$OC" wait --for=condition=Available deployment \
        -l 'app.kubernetes.io/part-of=argocd,app.kubernetes.io/component=server' \
        -n "$GITOPS_NS" --timeout=10m >/dev/null 2>&1; then
    echo "Error: the ArgoCD server did not become Available." >&2
    "$OC" get argocd,deploy -n "$GITOPS_NS" >&2 2>/dev/null || true
    exit 1
fi
echo "    ArgoCD instance: $("$OC" get argocd -n "$GITOPS_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"

echo "==> Installing AutoShift"
HELM_ARGS=(upgrade --install autoshift ./autoshift -n "$GITOPS_NS")
[ -n "$GIT_REPO" ]   && HELM_ARGS+=(--set "autoshiftGitRepo=${GIT_REPO}")
[ -n "$GIT_BRANCH" ] && HELM_ARGS+=(--set "autoshiftGitBranchTag=${GIT_BRANCH}")
# Order matters: cluster overrides clusterset overrides global. The per-cluster
# file is keyed on the ACM ManagedCluster name, which for a hub managing itself
# is 'local-cluster' rather than $CLUSTER_NAME. Generate it with
# scripts/45-autoshift-values.sh; it is skipped silently when absent.
CLUSTER_VALUES="${AUTOSHIFT_CLUSTER_VALUES:-local-cluster}"
for f in autoshift/values/global.yaml \
         "autoshift/values/clustersets/${CLUSTERSET}.yaml" \
         "autoshift/values/clusters/${CLUSTER_VALUES}.yaml"; do
    [ -f "$f" ] && HELM_ARGS+=(-f "$f")
done

# Helm reads values at install time, so a per-cluster file written after this
# point does nothing until the next bootstrap. Say so now rather than letting
# someone discover it when their GPU node never appears.
if [ ! -f "autoshift/values/clusters/${CLUSTER_VALUES}.yaml" ]; then
    cat >&2 <<EOF
    WARNING: no per-cluster values at autoshift/values/clusters/${CLUSTER_VALUES}.yaml
    Anything driven by per-cluster labels - GPU nodes in particular - will not
    be configured. Generate it and re-run this command:

        scripts/45-autoshift-values.sh --replicas 1 --force
        scripts/50-autoshift.sh bootstrap
EOF
fi
[ -n "${AUTOSHIFT_EXTRA_VALUES:-}" ] && HELM_ARGS+=(-f "$AUTOSHIFT_EXTRA_VALUES")
"$HELM" "${HELM_ARGS[@]}"

cat <<EOF

AutoShift is installed. It is not acting on anything yet - the hub has to be
added to a clusterset before any policy applies.

Do these IN ORDER. Helm reads values at install time, so anything written
after this bootstrap needs another bootstrap to take effect:

    1. scripts/45-autoshift-values.sh --replicas 1 --force
         Per-cluster values: GPU node count, instance type, zone. Skip this
         and you get no GPU node, with nothing reporting an error.

    2. Set the policy labels you want in
         ${AUTOSHIFT_DIR}/autoshift/values/clustersets/${CLUSTERSET}.yaml
         Set them in the values files, never on the ManagedCluster directly.
         RHOAI MaaS is four labels that have to move together: openshift-ai,
         connectivity-link, openshift-ai-maas, openshift-ai-models.

    3. scripts/50-autoshift.sh bootstrap
         Again, to apply 1 and 2.

    4. scripts/50-autoshift.sh adopt
         The irreversible step. This activates EVERY enabled policy at once,
         and turning a label back off does not uninstall what it created.
         Check what is enabled before running it.

    5. scripts/50-autoshift.sh status
EOF
