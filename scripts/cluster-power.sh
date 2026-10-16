#!/usr/bin/env bash
#
# cluster-power.sh - stop or start the cluster's EC2 instances to park it
#                    without destroying it.
#
# Usage: scripts/cluster-power.sh {stop|start|status} [--wait]
#
# Finds nodes through the AWS Resource Groups Tagging API, using the cluster's
# own infrastructure ID. Every resource the installer creates is tagged
# kubernetes.io/cluster/<infraID>=owned, so this picks up control plane and
# worker nodes - including any added later, such as a scaled-up GPU machine
# set - without needing a hardcoded list.
#
# The infrastructure ID comes from the installer's metadata.json rather than
# from `oc`, because the whole point of this script is to work when the
# cluster's API is down.
#
# This parks a lab cluster; it is not the full documented graceful shutdown,
# which starts with an etcd backup. See "Shutting down the cluster gracefully"
# in the OpenShift backup and restore docs if the cluster matters.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/cluster.env"

ACTION="${1:-}"
WAIT=0
[ "${2:-}" = "--wait" ] && WAIT=1

case "$ACTION" in
    stop|start|status) ;;
    *) echo "Usage: scripts/cluster-power.sh {stop|start|status} [--wait]" >&2; exit 2 ;;
esac

[ "$PLATFORM" = "aws" ] || { echo "Error: this script is AWS-only (PLATFORM=${PLATFORM})." >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: 'jq' is not installed." >&2; exit 1; }

META="${CLUSTER_DIR}/metadata.json"
[ -f "$META" ] || {
    echo "Error: ${META} not found - no cluster to act on." >&2
    exit 1
}

INFRA_ID="$(jq -r '.infraID' "$META")"
REGION="$(jq -r '.aws.region // empty' "$META")"
REGION="${REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$INFRA_ID" ] && [ -n "$REGION" ] || {
    echo "Error: could not read infraID and region from ${META}." >&2
    exit 1
}
export AWS_DEFAULT_REGION="$REGION"

TAG_KEY="kubernetes.io/cluster/${INFRA_ID}"
echo "==> Cluster ${INFRA_ID} in ${REGION}"
echo "==> Finding instances tagged ${TAG_KEY}=owned"

# The tagging API returns ARNs plus tags. Pull out the instance ID and the
# Name tag, which is what distinguishes a master from a worker.
INSTANCES="$(aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=${TAG_KEY},Values=owned" \
    --resource-type-filters ec2:instance \
    --query 'ResourceTagMappingList[].{arn:ResourceARN,name:Tags[?Key==`Name`]|[0].Value}' \
    --output json)"

if [ "$(jq 'length' <<<"$INSTANCES")" -eq 0 ]; then
    echo "    No instances found. Either the cluster was never created, or it"
    echo "    has already been destroyed."
    exit 0
fi

# An instance ARN ends in instance/i-0123..., so the ID is the last path
# segment. Terminated instances keep their tags for a while, so filter by
# live state rather than trusting the tag search alone.
ALL_IDS="$(jq -r '.[].arn | split("/")[-1]' <<<"$INSTANCES" | sort)"
STATES="$(aws ec2 describe-instances --instance-ids $ALL_IDS \
    --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,name:Tags[?Key==`Name`]|[0].Value,type:InstanceType}' \
    --output json)"

printf '\n%-22s %-14s %-14s %s\n' NAME ID TYPE STATE
jq -r '.[] | [.name // "-", .id, .type, .state] | @tsv' <<<"$STATES" |
    sort | while IFS=$'\t' read -r name id type state; do
        printf '%-22s %-14s %-14s %s\n' "$name" "$id" "$type" "$state"
    done
echo

# Control plane nodes are named <infraID>-master-N. Ordering matters: stop the
# workers first so workloads drain off before the API goes away, and start the
# control plane first so the workers have something to register with.
masters() { jq -r --arg s "$1" '.[] | select(.state==$s) | select(.name|test("-master")) | .id' <<<"$STATES"; }
workers() { jq -r --arg s "$1" '.[] | select(.state==$s) | select(.name|test("-master")|not) | .id' <<<"$STATES"; }

# Stopping instances stops the EC2 compute charge and nothing else. Everything
# below keeps billing while the cluster is parked, which is the single most
# common surprise - so report it rather than leave it to be discovered later.
cost_summary() {
    local vols vol_gib eips nats lbs running stopped

    vols="$(aws ec2 describe-volumes \
        --filters "Name=tag:${TAG_KEY},Values=owned" \
        --query 'Volumes[].Size' --output json 2>/dev/null || echo '[]')"
    vol_gib="$(jq 'add // 0' <<<"$vols")"
    vols="$(jq 'length' <<<"$vols")"

    # Elastic IPs and NAT gateways mostly belong to the VPC stack rather than
    # the cluster, so query the VPC rather than filtering on the cluster tag.
    local vpc_id
    vpc_id="$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
        --output text 2>/dev/null || true)"

    if [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ]; then
        nats="$(aws ec2 describe-nat-gateways \
            --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available" \
            --query 'length(NatGateways)' --output text 2>/dev/null || echo 0)"
        lbs="$(aws elbv2 describe-load-balancers \
            --query "length(LoadBalancers[?VpcId=='${vpc_id}'])" --output text 2>/dev/null || echo 0)"
    else
        nats=0; lbs=0
    fi
    eips="$(aws ec2 describe-addresses --query 'length(Addresses)' --output text 2>/dev/null || echo 0)"

    running="$(jq -r '[.[] | select(.state=="running")] | length' <<<"$STATES")"
    stopped="$(jq -r '[.[] | select(.state=="stopped")] | length' <<<"$STATES")"

    cat <<EOF

--- what is costing money -------------------------------------------------
  EC2 instances     ${running} running, ${stopped} stopped
                    stopped instances cost nothing for compute
  EBS volumes       ${vols} totalling ${vol_gib} GiB
                    billed in full whether or not the instance is running
  NAT gateways      ${nats} in the VPC
                    hourly charge continues even with every node stopped
  Elastic IPs       ${eips} allocated
  Load balancers    ${lbs} in the VPC
---------------------------------------------------------------------------
Parking saves the compute charge only. To stop paying for the NAT gateway,
EBS, and load balancers you have to destroy the cluster:
    scripts/90-destroy-cluster.sh            # keeps the VPC and its NAT
    scripts/90-destroy-cluster.sh --with-vpc # removes the NAT too
EOF
}

case "$ACTION" in
    status)
        cost_summary
        exit 0
        ;;

    stop)
        # shellcheck disable=SC2046
        set -- $(workers running) $(masters running)
        [ $# -gt 0 ] || { echo "Nothing running to stop."; exit 0; }
        echo "==> Stopping $# instance(s): workers first, then control plane"
        aws ec2 stop-instances --instance-ids "$@" \
            --query 'StoppingInstances[].{id:InstanceId,state:CurrentState.Name}' --output table
        if [ "$WAIT" -eq 1 ]; then
            echo "==> Waiting for all instances to reach 'stopped'"
            aws ec2 wait instance-stopped --instance-ids "$@"
            echo "    Done."
        fi
        STATES="$(aws ec2 describe-instances --instance-ids "$@" \
            --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,name:Tags[?Key==`Name`]|[0].Value,type:InstanceType}' \
            --output json 2>/dev/null || echo "$STATES")"
        cost_summary
        cat <<EOF

Bring it back with:
    scripts/cluster-power.sh start --wait
EOF
        ;;

    start)
        # shellcheck disable=SC2046
        set -- $(masters stopped) $(workers stopped)
        [ $# -gt 0 ] || { echo "Nothing stopped to start."; exit 0; }
        echo "==> Starting $# instance(s): control plane first, then workers"
        aws ec2 start-instances --instance-ids "$@" \
            --query 'StartingInstances[].{id:InstanceId,state:CurrentState.Name}' --output table
        if [ "$WAIT" -eq 1 ]; then
            echo "==> Waiting for all instances to reach 'running'"
            aws ec2 wait instance-running --instance-ids "$@"
            echo "    Done."
        fi
        cat <<EOF

Instances are up. The cluster itself takes several more minutes to settle, and
node IPs change on restart.

Nodes often come back NotReady with their CSRs pending, because the kubelet
serving certificates were not renewed while the cluster was off. Approve them:

    export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig
    "\$OC" get csr -o name | xargs -r "\$OC" adm certificate approve
    "\$OC" get nodes

Expect to run that twice - a second round of CSRs appears once the kubelets
reconnect. If nodes stay NotReady after both rounds, see KCS 7136634.
EOF
        ;;
esac
