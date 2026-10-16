#!/usr/bin/env bash
#
# 20-deploy-maas.sh - install RHOAI Models-as-a-Service on the cluster built by
#                     10-deploy-cluster.sh.
#
# Usage: scripts/20-deploy-maas.sh [setup-maas.sh options...]
#
# Thin wrapper around the guide's own orchestrator in the rhoai-maas-guide
# submodule. Any options given here are passed straight through, e.g.
#
#   scripts/20-deploy-maas.sh --model simulator
#   scripts/20-deploy-maas.sh --with-observability
#   scripts/20-deploy-maas.sh --from-phase 4
#
# With no options the guide auto-detects GPU capacity and picks a model.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUIDE="${ROOT}/rhoai-maas-guide"

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

[ -f "${GUIDE}/scripts/setup-maas.sh" ] || {
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

# setup-maas.sh calls bare `oc` ~175 times and offers no override variable, so
# it needs oc on PATH - unlike the rest of this repo, which addresses the
# binaries explicitly. Scope the change to this process only; the caller's PATH
# is untouched because this script is executed, not sourced.
export PATH="${OCP_BIN_DIR}:${PATH}"

echo "==> Using oc:      $(command -v oc)"
echo "==> Using cluster: $("$OC" whoami --show-server)"
echo "==> Guide pinned at: $(git -C "$GUIDE" rev-parse --short HEAD)"

# The guide's paths are relative to its own repo root.
cd "$GUIDE"
exec ./scripts/setup-maas.sh "$@"
