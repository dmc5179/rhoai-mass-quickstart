#!/usr/bin/env bash
#
# add-gpu-machinesets.sh - create on-demand and spot GPU machine sets, both at
#                          replica 0.
#
# Usage: scripts/add-gpu-machinesets.sh
#
# Run against a cluster that is already up. Called at the end of
# 10-deploy-cluster.sh, and safe to run on its own afterwards.
#
# Both sets start at 0 replicas so the cluster carries no GPU cost until you
# ask for one:
#
#   "$OC" scale machineset/<name> -n openshift-machine-api --replicas=1
#
# Existing machine sets are left completely alone, so re-running this will not
# reset a set you have already scaled up.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

command -v jq >/dev/null || { echo "Error: 'jq' is not installed." >&2; exit 1; }

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG

MAPI="openshift-machine-api"

# Clone an existing worker machine set rather than writing one from scratch:
# that inherits the RHCOS AMI, subnet, security groups, IAM instance profile,
# and cluster tags, all of which are cluster-specific and easy to get wrong.
# The machine-role label lives in .spec.template.metadata.labels - the labels
# stamped onto the Machines - not in the MachineSet's own .metadata.labels,
# which only carries cluster-api-cluster. `oc get -l` filters on the latter, so
# selecting with -l here silently matches nothing. Read the template labels
# instead, and skip any GPU set we created earlier so a re-run does not clone
# a GPU machine set as its own base.
BASE="$("$OC" get machineset -n "$MAPI" -o json | jq -r '
    .items[]
    | select(.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] == "worker")
    | select(.metadata.name | test("-gpu(-spot)?-") | not)
    | .metadata.name' | head -1)"
[ -n "$BASE" ] || { echo "Error: no worker machine set found to use as a base." >&2; exit 1; }

INFRA="$("$OC" get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"
AZ="$("$OC" get machineset "$BASE" -n "$MAPI" \
    -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')"

echo "==> Base machine set: ${BASE}"
echo "==> Cluster: ${INFRA}   zone: ${AZ}   GPU type: ${GPU_INSTANCE_TYPE}"

# $1 = machine set name, $2 = "true" for spot
render() {
    "$OC" get machineset "$BASE" -n "$MAPI" -o json | jq \
        --arg name "$1" \
        --arg itype "$GPU_INSTANCE_TYPE" \
        --argjson spot "$2" '
        .metadata.name = $name
        # Strip the server-populated fields so this is a clean create.
        | del(.metadata.uid, .metadata.resourceVersion, .metadata.generation,
              .metadata.creationTimestamp, .metadata.annotations,
              .metadata.ownerReferences, .status)
        | .spec.replicas = 0
        | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
        | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
        | .spec.template.spec.providerSpec.value.instanceType = $itype
        # Label the node so workloads can target it, and taint it so that only
        # pods that explicitly tolerate GPUs land on an expensive instance. The
        # GPU models in the guide already carry the matching toleration.
        | .spec.template.spec.metadata.labels =
            ((.spec.template.spec.metadata.labels // {}) + {"node-role.kubernetes.io/gpu": ""})
        | .spec.template.spec.taints = [{"key": "nvidia.com/gpu", "effect": "NoSchedule"}]
        # An empty spotMarketOptions means "bid up to the on-demand price",
        # which is the documented recommendation.
        | if $spot then .spec.template.spec.providerSpec.value.spotMarketOptions = {} else . end
        '
}

for spec in "${INFRA}-gpu-${AZ}:false" "${INFRA}-gpu-spot-${AZ}:true"; do
    name="${spec%:*}"
    spot="${spec##*:}"

    if "$OC" get machineset "$name" -n "$MAPI" >/dev/null 2>&1; then
        echo "==> ${name} already exists; leaving it untouched"
        continue
    fi

    echo "==> Creating ${name} (spot=${spot}, replicas=0)"
    render "$name" "$spot" | "$OC" create -f -
done

echo
"$OC" get machineset -n "$MAPI" -o custom-columns=\
'NAME:.metadata.name,REPLICAS:.spec.replicas,TYPE:.spec.template.spec.providerSpec.value.instanceType,SPOT:.spec.template.spec.providerSpec.value.spotMarketOptions'
