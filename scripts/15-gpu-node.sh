#!/usr/bin/env bash
#
# 15-gpu-node.sh - bring a GPU node online (or take it away again) so that
#                  phase 20 deploys a real GPU model instead of the simulator.
#
# Usage: scripts/15-gpu-node.sh up [--spot] [--fallback] [--replicas N]
#        scripts/15-gpu-node.sh down
#        scripts/15-gpu-node.sh status
#
# Why this exists: the guide's setup-maas.sh only *detects* GPUs. It reads the
# nvidia.com/gpu.memory node label and, finding nothing, silently falls back to
# the CPU simulator - the run looks successful either way. It never installs
# the operators that create that label, and phase 1 of the guide only applies
# manifests/01-prerequisites/operators/, not .../gpu/.
#
# So "up" does the four things that have to happen first:
#   1. scale the GPU machine set from 0 to N
#   2. install Node Feature Discovery and the NVIDIA GPU operator
#   3. create the NodeFeatureDiscovery and ClusterPolicy instances
#   4. wait until a node actually advertises nvidia.com/gpu
#
# Run this before scripts/20-deploy-maas.sh. Run "down" afterwards to stop
# paying for the GPU.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUIDE="${ROOT}/rhoai-maas-guide"
ACTION="${1:-}"; shift || true
USE_SPOT=0
REPLICAS=1

FALLBACK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --spot)     USE_SPOT=1; shift ;;
        --fallback) FALLBACK=1; shift ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        *) echo "15-gpu-node.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

[ "$FALLBACK" -eq 0 ] || [ "$USE_SPOT" -eq 1 ] || {
    echo "15-gpu-node.sh: --fallback only makes sense with --spot" >&2; exit 2; }

case "$ACTION" in
    up|down|status) ;;
    *) echo "Usage: scripts/15-gpu-node.sh {up|down|status} [--spot] [--fallback] [--replicas N]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

command -v jq >/dev/null || { echo "Error: 'jq' is not installed." >&2; exit 1; }

[ "$PLATFORM" = "aws" ] || { echo "Error: GPU node automation is AWS-only (PLATFORM=${PLATFORM})." >&2; exit 1; }

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}. Run phase 10 first." >&2; exit 1; }
export KUBECONFIG

# The installer writes auth/kubeconfig early, well before the API is actually
# serving, so the file existing is not enough. Without this check the script
# dies in a later assignment with a wall of oc DNS errors.
if ! "$OC" get --raw /readyz >/dev/null 2>&1; then
    echo "Error: the cluster API is not reachable yet." >&2
    echo "       $("$OC" whoami --show-server 2>/dev/null || echo "(server unknown)")" >&2
    echo "       Wait for scripts/10-deploy-cluster.sh to finish, then retry." >&2
    exit 1
fi

MAPI="openshift-machine-api"
INFRA="$("$OC" get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"

# The machine-role label is in .spec.template.metadata.labels, not in the
# MachineSet's own .metadata.labels, so `oc get -l` cannot select on it. Read
# the template labels, and ignore the GPU sets themselves when looking for the
# ordinary worker set that tells us the zone.
AZ="$("$OC" get machineset -n "$MAPI" -o json | jq -r '
    .items[]
    | select(.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] == "worker")
    | select(.metadata.name | test("-gpu(-spot)?-") | not)
    | .spec.template.spec.providerSpec.value.placement.availabilityZone' | head -1)"

# Worker machine sets do not exist until the cluster is past bootstrap.
[ -n "$AZ" ] || {
    echo "Error: no worker machine set found - the cluster is probably still" >&2
    echo "       bootstrapping. Wait for scripts/10-deploy-cluster.sh to finish." >&2
    exit 1
}

if [ "$USE_SPOT" -eq 1 ]; then
    MS="${INFRA}-gpu-spot-${AZ}"
else
    MS="${INFRA}-gpu-${AZ}"
fi

"$OC" get machineset "$MS" -n "$MAPI" >/dev/null 2>&1 || {
    echo "Error: machine set ${MS} not found." >&2
    echo "       Phase 10 creates it; run scripts/add-gpu-machinesets.sh if the" >&2
    echo "       cluster predates that step." >&2
    exit 1
}

show_status() {
    echo "==> GPU machine sets"
    "$OC" get machineset -n "$MAPI" -o custom-columns=\
'NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas' |
        grep -E 'NAME|gpu' || true
    echo
    echo "==> Nodes advertising a GPU"
    local n
    n="$("$OC" get nodes -l nvidia.com/gpu.present=true \
        -o custom-columns='NODE:.metadata.name,GPU:.metadata.labels.nvidia\.com/gpu\.product,MEM_MiB:.metadata.labels.nvidia\.com/gpu\.memory,CAPACITY:.status.capacity.nvidia\.com/gpu' \
        --no-headers 2>/dev/null || true)"
    if [ -n "$n" ]; then
        echo "$n"
    else
        echo "    (none - phase 20 would pick the CPU simulator)"
    fi
}

case "$ACTION" in
status)
    show_status
    exit 0
    ;;

down)
    echo "==> Scaling ${MS} to 0"
    "$OC" scale machineset "$MS" -n "$MAPI" --replicas=0
    echo "    The NFD and GPU operators are left installed; they cost nothing"
    echo "    without a GPU node, and leaving them avoids a slow reinstall."
    exit 0
    ;;

up)
    echo "==> Cluster ${INFRA}, zone ${AZ}"

    # Spot is roughly half price but can simply be unavailable. Show what it
    # costs now, so an unfulfilled request later is interpretable rather than
    # mysterious.
    if [ "$USE_SPOT" -eq 1 ] && command -v aws >/dev/null; then
        SPOT_PRICE="$(aws ec2 describe-spot-price-history \
            --instance-types "$GPU_INSTANCE_TYPE" \
            --product-descriptions "Linux/UNIX" \
            --availability-zone "$AZ" --max-items 1 \
            --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null || true)"
        [ -n "$SPOT_PRICE" ] && [ "$SPOT_PRICE" != "None" ] &&
            echo "==> Spot price for ${GPU_INSTANCE_TYPE} in ${AZ}: \$${SPOT_PRICE}/hr"
        echo "    Spot nodes can be reclaimed with two minutes' notice. The"
        echo "    machine set replaces them, but a model pod mid-request dies."
    fi

    echo "==> Scaling ${MS} to ${REPLICAS} (${GPU_INSTANCE_TYPE})"
    "$OC" scale machineset "$MS" -n "$MAPI" --replicas="$REPLICAS"

    # A spot request that cannot be filled leaves the Machine sitting in
    # Provisioning indefinitely, so waiting the full 25 minutes for a node
    # label tells you nothing useful. Watch the Machine itself for a few
    # minutes and surface the reason.
    if [ "$USE_SPOT" -eq 1 ]; then
        echo "==> Checking the spot request is being fulfilled (up to 5m)"
        spot_ok=0
        deadline=$(( $(date +%s) + 300 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            phases="$("$OC" get machines -n "$MAPI" \
                -o jsonpath="{range .items[?(@.spec.providerID)]}{.metadata.name}{'\t'}{.status.phase}{'\n'}{end}" \
                2>/dev/null | grep -F "${MS}" || true)"
            if grep -qE 'Provisioned|Running' <<<"$phases"; then
                spot_ok=1; break
            fi
            failure="$("$OC" get machines -n "$MAPI" -o json 2>/dev/null |
                jq -r --arg ms "$MS" '.items[]
                    | select(.metadata.name | startswith($ms))
                    | .status.errorMessage // .status.failureMessage // empty' | head -1)"
            if [ -n "$failure" ]; then
                echo "    Spot request failed: ${failure}" >&2
                break
            fi
            sleep 15
        done

        if [ "$spot_ok" -eq 0 ]; then
            if [ "$FALLBACK" -eq 1 ]; then
                echo "==> Spot did not fulfil; falling back to on-demand"
                "$OC" scale machineset "$MS" -n "$MAPI" --replicas=0
                MS="${INFRA}-gpu-${AZ}"
                USE_SPOT=0
                echo "==> Scaling ${MS} to ${REPLICAS}"
                "$OC" scale machineset "$MS" -n "$MAPI" --replicas="$REPLICAS"
            else
                echo "    Still unfulfilled. Continuing to wait - re-run with"
                echo "    --fallback to switch to on-demand automatically."
            fi
        fi
    fi

    # --- operators ---------------------------------------------------------
    # Applied from the guide submodule so the versions stay pinned with it.
    echo "==> Installing Node Feature Discovery and the NVIDIA GPU operator"
    "$OC" apply -k "${GUIDE}/manifests/01-prerequisites/gpu/"

    echo "    Waiting for the operator CSVs to succeed (up to 10m)"
    for ns in openshift-nfd nvidia-gpu-operator; do
        deadline=$(( $(date +%s) + 600 ))
        while :; do
            if "$OC" get csv -n "$ns" --no-headers 2>/dev/null | grep -q Succeeded; then
                echo "    ${ns}: Succeeded"
                break
            fi
            [ "$(date +%s)" -lt "$deadline" ] || {
                echo "Error: no CSV reached Succeeded in ${ns} within 10m." >&2
                echo "       Check: \"\$OC\" get csv -n ${ns}" >&2
                exit 1
            }
            sleep 10
        done
    done

    # --- instances ---------------------------------------------------------
    # Separate from the subscriptions because these CRs do not exist until the
    # operators have installed their CRDs.
    echo "==> Creating NodeFeatureDiscovery and ClusterPolicy"
    "$OC" apply -k "${GUIDE}/manifests/01-prerequisites/gpu/instances/"

    # --- wait for the node -------------------------------------------------
    # The slow part: EC2 has to start the instance, it has to join the cluster,
    # NFD has to label it, then the GPU operator has to build and load the
    # driver on it. Twenty-five minutes is not unusual on a first run.
    echo "==> Waiting for a node to advertise nvidia.com/gpu (up to 25m)"
    deadline=$(( $(date +%s) + 1500 ))
    while :; do
        ready="$("$OC" get nodes -l nvidia.com/gpu.present=true \
            -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null || true)"
        if [ -n "$ready" ] && [ "$ready" != "0" ]; then
            echo "    GPU capacity reported: ${ready}"
            break
        fi
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "Error: no GPU node became ready within 25m." >&2
            echo "       Machines:  \"\$OC\" get machines -n ${MAPI}" >&2
            echo "       GPU pods:  \"\$OC\" get pods -n nvidia-gpu-operator" >&2
            echo "       A spot machine set can sit unfulfilled if there is no" >&2
            echo "       capacity at the current price." >&2
            exit 1
        }
        sleep 20
    done

    echo
    show_status

    # The guide picks its model from this label, so surfacing it here makes the
    # downstream choice predictable rather than a surprise.
    MEM="$("$OC" get nodes -l nvidia.com/gpu.present=true \
        -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null || true)"
    cat <<EOF

GPU node is ready${MEM:+ with ${MEM} MiB of VRAM}.

scripts/20-deploy-maas.sh will now detect it and choose a GPU model instead of
the CPU simulator. To pin the choice explicitly:

    scripts/20-deploy-maas.sh --model granite-tiny-gpu

granite-tiny-gpu is the OCI modelcar at
registry.redhat.io/rhai/modelcar-granite-4-0-h-tiny-fp8-dynamic:3.0 and needs
about 8 GiB of VRAM.

When you are done, stop paying for the GPU:

    scripts/15-gpu-node.sh down
EOF
    ;;
esac
