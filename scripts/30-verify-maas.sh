#!/usr/bin/env bash
#
# 30-verify-maas.sh - run the guide's end-to-end MaaS verification against the
#                     cluster built by phase 10 and configured by phase 20.
#
# Usage: scripts/30-verify-maas.sh [verify.sh options...]
#
#   --no-cleanup     leave the test model and MaaS resources deployed
#   --cleanup-only   only remove test resources from a previous run
#
# Thin wrapper around manifests/06-verification/verify.sh in the guide
# submodule, which runs six phases: infrastructure health, deploying a
# simulator model, API and inference checks, auth enforcement, rate limiting,
# and cleanup.
#
# Note this deploys its own throwaway simulator model to test against; it does
# not exercise whatever model phase 20 installed. It verifies the MaaS
# platform, not your chosen model.
#
# For the deeper checks - the blind-spot regression suite and validation that
# the guide's own documented commands still produce the documented output -
# use the verify-guide skill, symlinked into .claude/skills/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUIDE="${ROOT}/rhoai-maas-guide"

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

ORIG_ARGS=("$@")
. "${ROOT}/scripts/lib-logging.sh"
start_logging "maas-verify" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}


VERIFY="${GUIDE}/manifests/06-verification/verify.sh"
[ -f "$VERIFY" ] || {
    echo "Error: guide submodule is not checked out. Run:" >&2
    echo "       git submodule update --init" >&2
    exit 1
}

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || {
    echo "Error: no kubeconfig at ${KUBECONFIG}." >&2
    echo "       Run scripts/10-deploy-cluster.sh first." >&2
    exit 1
}
export KUBECONFIG

if ! "$OC" get --raw /readyz >/dev/null 2>&1; then
    echo "Error: the cluster API is not reachable." >&2
    echo "       $("$OC" whoami --show-server 2>/dev/null || echo "(server unknown)")" >&2
    exit 1
fi

# Fail early with something readable rather than letting verify.sh discover
# halfway through that MaaS was never installed.
if ! "$OC" get crd maasmodelrefs.maas.opendatahub.io >/dev/null 2>&1; then
    echo "Error: MaaS does not appear to be installed - the MaaSModelRef CRD is" >&2
    echo "       missing. Run scripts/20-deploy-maas.sh first." >&2
    exit 1
fi

# verify.sh mints API keys with `oc whoami -t`, which a cert-based kubeconfig
# cannot satisfy.
. "${ROOT}/scripts/lib-oc-token.sh"
ensure_oc_token || exit 1
trap cleanup_oc_token EXIT

# Same constraint as phase 20: verify.sh calls bare `oc` and checks `oc whoami`,
# so it needs oc on PATH. Scoped to this process, which also guarantees it runs
# against the pinned 4.22 client rather than whatever is installed on the host.
export PATH="${OCP_BIN_DIR}:${PATH}"

echo "==> Using oc:      $(command -v oc)"
echo "==> Using cluster: $("$OC" whoami --show-server)"
echo "==> Guide pinned at: $(git -C "$GUIDE" rev-parse --short HEAD)"

cd "$GUIDE"
# Not exec: see 20-deploy-maas.sh - the EXIT trap writes the log footer.
"$VERIFY" "$@"
