#!/usr/bin/env bash
#
# cluster-power.sh - stop or start the cluster's EC2 instances to park it
#                    without destroying it.
#
# Usage: scripts/cluster-power.sh {stop|start|status|settle} [--wait] [--keep-db] [--settle]
#
# settle (or start --settle) brings a just-started cluster to a working state: waits for
# the API, approves the node CSRs that pile up while it was off, waits for the nodes and
# the Kuadrant operator, then restarts any gateway that failed to load its Kuadrant Wasm
# plugin. A gateway that starts before the operator fails closed and returns 503 for
# every MaaS request, with nothing else reporting a fault (seen 2026-11-25).
#
# stop and start also stop and start the MaaS RDS database (scripts/maas-database.sh),
# unless --keep-db. start brings the database up first and waits for it, because
# maas-api will not start without it. AWS starts a stopped RDS instance again on its
# own after 7 days, so a cluster parked longer than that pays for the database again.
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

ORIG_ARGS=("$@")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "cluster-power" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

ACTION="${1:-}"
WAIT=0
KEEP_DB=0
SETTLE=0
shift || true
for a in "$@"; do
    case "$a" in
        --wait)    WAIT=1 ;;
        --keep-db) KEEP_DB=1 ;;
        --settle)  SETTLE=1; WAIT=1 ;;
        *) echo "Usage: scripts/cluster-power.sh {stop|start|status|settle} [--wait] [--keep-db] [--settle]" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    stop|start|status|settle) ;;
    *) echo "Usage: scripts/cluster-power.sh {stop|start|status|settle} [--wait] [--keep-db] [--settle]" >&2; exit 2 ;;
esac

# --- settle: from "instances running" to "cluster working" ---------------------
# Uses the installer kubeconfig (client certificate), which works whatever the
# cluster's sign-in is.
settle() {
    export KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
    local o=("$OC" --request-timeout=20s) n=1
    echo "==> Settling: waiting for the API (up to 20 min)"
    for _ in $(seq 1 80); do "${o[@]}" get --raw /readyz >/dev/null 2>&1 && break; sleep 15; done
    "${o[@]}" get --raw /readyz >/dev/null 2>&1 || { echo "Error: the API did not come up; rerun: scripts/cluster-power.sh settle" >&2; return 1; }
    echo "    API is up."

    # Kubelet serving certificates lapse while the cluster is off. CSRs come in two
    # rounds (client, then serving) as the kubelets reconnect, so keep approving
    # until every node is Ready.
    echo "==> Approving pending node CSRs until every node is Ready (up to 20 min)"
    for _ in $(seq 1 40); do
        local pend
        pend="$("${o[@]}" get csr --no-headers 2>/dev/null | awk '$NF=="Pending"{print $1}' || true)"
        if [ -n "$pend" ]; then
            # shellcheck disable=SC2086
            "${o[@]}" adm certificate approve $pend >/dev/null 2>&1 && echo "    approved $(wc -w <<<"$pend") CSR(s)"
        fi
        n="$("${o[@]}" get nodes --no-headers 2>/dev/null | grep -cv ' Ready ' || true)"
        [ "${n:-1}" -eq 0 ] && [ -z "$pend" ] && break
        sleep 30
    done
    "${o[@]}" get nodes --no-headers 2>/dev/null | awk '{print "    "$1" "$2}'
    [ "${n:-1}" -eq 0 ] || echo "Warning: ${n} node(s) still not Ready. See KCS 7136634." >&2

    # The Kuadrant operator serves the gateways' Wasm plugin over HTTP.
    local kdep="kuadrant-operator-controller-manager" kns="openshift-operators"
    if "${o[@]}" get deployments.apps "$kdep" -n "$kns" >/dev/null 2>&1; then
        echo "==> Waiting for ${kdep} (serves the gateways' Wasm plugin)"
        "${o[@]}" rollout status deployments.apps/"$kdep" -n "$kns" --timeout=600s >/dev/null 2>&1 \
            && echo "    Available." || echo "Warning: ${kdep} not Available after 10 min." >&2

        # A gateway pod without the plugin fails closed and returns 503: every fetch failed
        # (failures > 0, successes 0), or it answered with wasm_fail_stream in the last 15
        # minutes. The startup log line "Plugin configured to fail closed failed to load" and
        # a cache negative hit are not enough on their own: worker threads that fetch at the
        # same moment log them and then load the plugin, and such pods serve normally.
        # Restart the Deployment of a broken pod; healthy ones are left alone.
        echo "==> Checking each gateway pod loaded the Kuadrant Wasm plugin"
        local gp st fs f s why dep restarted=""
        for gp in $("${o[@]}" get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null); do
            st="$("${o[@]}" exec -n openshift-ingress "${gp#pod/}" -- pilot-agent request GET stats 2>/dev/null | grep -E '^wasm\.remote_load_fetch_(failures|successes):' || true)"
            [ -n "$st" ] || continue
            f="$(awk -F': ' '/fetch_failures/{print $2}' <<<"$st")"; s="$(awk -F': ' '/fetch_successes/{print $2}' <<<"$st")"
            fs="$("${o[@]}" logs -n openshift-ingress "${gp#pod/}" --since=15m 2>/dev/null | grep -c 'wasm_fail_stream' || true)"
            why=""
            [ "${f:-0}" -gt 0 ] && [ "${s:-0}" -eq 0 ] && why="fetch failures ${f}, successes 0"
            [ "${fs:-0}" -gt 0 ] && why="${why:+$why; }${fs} wasm_fail_stream responses in 15 min"
            if [ -n "$why" ]; then
                # pod -> ReplicaSet -> Deployment
                dep="$("${o[@]}" get "$gp" -n openshift-ingress -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
                dep="$("${o[@]}" get replicasets.apps "$dep" -n openshift-ingress -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
                [ -n "$dep" ] || continue
                case " $restarted " in *" $dep "*) continue ;; esac
                echo "    ${gp#pod/}: plugin failed to load (${why}); restarting ${dep}"
                "${o[@]}" rollout restart deployments.apps/"$dep" -n openshift-ingress >/dev/null \
                    && "${o[@]}" rollout status deployments.apps/"$dep" -n openshift-ingress --timeout=300s >/dev/null 2>&1
                restarted="$restarted $dep"
            fi
        done
        [ -n "$restarted" ] || echo "    All gateway pods loaded it."
    fi
    echo
    echo "Settled. Full check: scripts/checkup.sh"
}

if [ "$ACTION" = "settle" ]; then
    settle
    exit $?
fi

[ "$PLATFORM" = "aws" ] || { echo "Error: this script is AWS-only (PLATFORM=${PLATFORM})." >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: 'jq' is not installed." >&2; exit 1; }

# Credentials come from secrets/aws.env, as in phase 10, not from whatever the
# calling shell happens to have exported.
if [ -f "${ROOT}/secrets/aws.env" ]; then
    # shellcheck disable=SC1091
    . "${ROOT}/secrets/aws.env"
fi
aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "Error: AWS credentials are not valid. Check secrets/aws.env:" >&2
    aws sts get-caller-identity 2>&1 | sed 's/^/       /' >&2
    exit 1
}

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
        # The MaaS database (scripts/maas-database.sh) lives in this VPC, outside the
        # cluster's tags, and keeps billing while the nodes are stopped.
        rds="$(aws rds describe-db-instances \
            --query "DBInstances[?DBSubnetGroup.VpcId=='${vpc_id}'].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]" \
            --output text 2>/dev/null | awk '{printf "%s%s (%s, %s)", sep, $1, $2, $3; sep=", "}')"
    else
        nats=0; lbs=0; rds=""
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
  RDS databases     ${rds:-none in the VPC}
                    billed while available; stop/start here stop and start it too (unless --keep-db)
---------------------------------------------------------------------------
Parking saves the compute charge only. To stop paying for the NAT gateway,
EBS, and load balancers you have to destroy the cluster. The MaaS database is
stopped and started with the nodes (use --keep-db to leave it running); AWS starts
a stopped RDS instance again after 7 days. scripts/maas-database.sh destroy removes
it. To destroy the cluster:
    scripts/90-destroy-cluster.sh            # keeps the VPC and its NAT
    scripts/90-destroy-cluster.sh --with-vpc # removes the NAT too
EOF
}

# The MaaS database, through scripts/maas-database.sh (a no-op when there is none).
db_power() {
    [ "$KEEP_DB" -eq 1 ] && { echo "==> Leaving the MaaS database as it is (--keep-db)"; return 0; }
    local w=""; [ "$WAIT" -eq 1 ] && w="--wait"
    # shellcheck disable=SC2086
    "${ROOT}/scripts/maas-database.sh" "$1" $w || echo "Warning: maas-database.sh $1 failed; check scripts/maas-database.sh status" >&2
}

case "$ACTION" in
    status)
        cost_summary
        exit 0
        ;;

    stop)
        # shellcheck disable=SC2046
        set -- $(workers running) $(masters running)
        if [ $# -eq 0 ]; then
            echo "Nothing running to stop."
            db_power stop
            exit 0
        fi
        echo "==> Stopping $# instance(s): workers first, then control plane"
        aws ec2 stop-instances --instance-ids "$@" \
            --query 'StoppingInstances[].{id:InstanceId,state:CurrentState.Name}' --output table
        if [ "$WAIT" -eq 1 ]; then
            echo "==> Waiting for all instances to reach 'stopped'"
            aws ec2 wait instance-stopped --instance-ids "$@"
            echo "    Done."
        fi
        db_power stop
        STATES="$(aws ec2 describe-instances --instance-ids "$@" \
            --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,name:Tags[?Key==`Name`]|[0].Value,type:InstanceType}' \
            --output json 2>/dev/null || echo "$STATES")"
        cost_summary
        cat <<EOF

Bring it back with:
    scripts/cluster-power.sh start --settle
EOF
        ;;

    start)
        # shellcheck disable=SC2046
        # The database first: maas-api crash-loops without it. --wait here waits for it
        # to be available before the nodes start.
        db_power start
        # shellcheck disable=SC2046
        set -- $(masters stopped) $(workers stopped)
        [ $# -gt 0 ] || { echo "Nothing stopped to start."; exit 0; }
        echo "==> Starting $# instance(s): control plane first, then workers"
        # One call per instance. A single StartInstances call for all of them fails as a
        # whole when EC2 has no capacity for one instance type in the zone, which GPU
        # types often hit (us-east-2a refused the g6.xlarge on 2026-11-19). Started one
        # by one, the rest of the cluster comes up and the refused ones are named.
        started=() refused=()
        for id in "$@"; do
            if out="$(aws ec2 start-instances --instance-ids "$id" \
                    --query 'StartingInstances[0].CurrentState.Name' --output text 2>&1)"; then
                printf '    %s %s\n' "$id" "$out"; started+=("$id")
            else
                printf '    %s NOT STARTED: %s\n' "$id" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
                refused+=("$id")
            fi
        done
        if [ "$WAIT" -eq 1 ] && [ "${#started[@]}" -gt 0 ]; then
            echo "==> Waiting for the started instances to reach 'running'"
            aws ec2 wait instance-running --instance-ids "${started[@]}"
            echo "    Done."
        fi
        if [ "${#refused[@]}" -gt 0 ]; then
            cat <<EOF

${#refused[@]} instance(s) did not start. InsufficientInstanceCapacity means EC2 has none of
that type in the zone right now; it usually frees up within hours. Retry with:

    scripts/cluster-power.sh start --wait

The cluster runs without them. Workloads that need them (a GPU model, for one) stay
Pending, and while they do the cluster autoscaler may add a replacement machine.
EOF
        fi
        if [ "$SETTLE" -eq 1 ]; then
            settle
            exit $?
        fi
        cat <<EOF

Instances are up. The cluster itself takes several more minutes to settle, and
node IPs change on restart. To do the steps below automatically, plus the Kuadrant
gateway check, run: scripts/cluster-power.sh settle

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
