#!/usr/bin/env bash
#
# 45-autoshift-values.sh - render the per-cluster AutoShift values file from
#                          cluster.env and the live cluster.
#
# Usage: scripts/45-autoshift-values.sh [options]
#
# Options:
#   --name <name>          ManagedCluster name to key the file on. Default: the
#                          hub's own, which ACM calls 'local-cluster'.
#   --clusterset <name>    Clusterset to assign. Default: $AUTOSHIFT_CLUSTERSET.
#   --replicas <n>         GPU replicas. Default: 0 (MachineSet exists, costs nothing).
#   --instance-type <t>    Override $GPU_INSTANCE_TYPE.
#   --spot                 Request spot instances. See the warning below.
#   --stdout               Print instead of writing.
#   --force                Overwrite an existing file.
#
# Writes $AUTOSHIFT_DIR/autoshift/values/clusters/<name>.yaml, which phase 50
# then passes to helm.
#
# Two things worth knowing:
#
#   1. The YAML key must be the ACM ManagedCluster name, NOT $CLUSTER_NAME. For
#      a hub managing itself those differ: the cluster is 'rhoai' to the
#      installer and 'local-cluster' to ACM. Keying it wrong is silent - helm
#      accepts the file and no label is ever applied.
#
#   2. No VPC or subnet IDs appear here. The gpu-nodes policy clones the
#      cluster's own worker MachineSet at reconcile time, so it discovers the
#      subnet, AMI, security groups and IAM profile itself. Nothing about the
#      network has to cross from CloudFormation into AutoShift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MC_NAME=""
CLUSTERSET=""
REPLICAS="0"
INSTANCE_TYPE=""
SPOT="false"
TO_STDOUT=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --name)          MC_NAME="$2"; shift 2 ;;
        --clusterset)    CLUSTERSET="$2"; shift 2 ;;
        --replicas)      REPLICAS="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --spot)          SPOT="true"; shift ;;
        --stdout)        TO_STDOUT=1; shift ;;
        --force)         FORCE=1; shift ;;
        -h|--help)       sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "45-autoshift-values.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

: "${AUTOSHIFT_DIR:?AUTOSHIFT_DIR must be set in cluster.env}"
VALUES_DIR="${AUTOSHIFT_DIR}/autoshift/values/clusters"
[ -d "$VALUES_DIR" ] || {
    echo "Error: ${VALUES_DIR} does not exist." >&2
    echo "       Is AUTOSHIFT_DIR really an AutoShift checkout?" >&2
    exit 1
}

CLUSTERSET="${CLUSTERSET:-${AUTOSHIFT_CLUSTERSET:-hub}}"
INSTANCE_TYPE="${INSTANCE_TYPE:-${GPU_INSTANCE_TYPE:-}}"
[ -n "$INSTANCE_TYPE" ] || { echo "Error: no GPU instance type (set GPU_INSTANCE_TYPE)." >&2; exit 1; }

case "$REPLICAS" in
    ''|*[!0-9]*) echo "Error: --replicas must be a non-negative integer, got '${REPLICAS}'." >&2; exit 2 ;;
esac

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
HAVE_CLUSTER=0
if [ -f "$KUBECONFIG" ] && export KUBECONFIG && "$OC" get --raw /readyz >/dev/null 2>&1; then
    HAVE_CLUSTER=1
fi

# Addressing MachineSets by their fully qualified resource name is not
# pedantry. Installing ACM brings in the Cluster API CRDs, which serve a
# SECOND resource also called 'machinesets' (cluster.x-k8s.io). From then on
# the bare name is ambiguous and oc silently resolves it to the empty CAPI one,
# so `oc get machineset` reports "No resources found" on a cluster that plainly
# has them. Always qualify the group here.
MS="machinesets.machine.openshift.io"
MAPI="openshift-machine-api"

worker_field() {
    [ "$HAVE_CLUSTER" -eq 1 ] || return 1
    "$OC" get "$MS" -n "$MAPI" -o json 2>/dev/null | python3 -I -c "
import json,sys
try: items=json.load(sys.stdin).get('items',[])
except Exception: sys.exit(1)
for m in items:
    lbls=m.get('spec',{}).get('template',{}).get('metadata',{}).get('labels',{})
    if lbls.get('machine.openshift.io/cluster-api-machine-role')!='worker': continue
    if '-gpu-' in m['metadata']['name']: continue
    p=m['spec']['template']['spec']['providerSpec']['value'].get('placement',{})
    v=p.get('$1','')
    if v: print(v); break
" 2>/dev/null
}

# Zone and region, most authoritative source first: the running cluster knows
# where its workers actually are; the CloudFormation stack only knows where it
# put the subnets; cluster.env only knows what was asked for.
ZONE="$(worker_field availabilityZone || true)"
REGION="$(worker_field region || true)"

if [ -z "$ZONE" ]; then
    ZONE="${VPC_AZ:-}"
fi
if [ -z "$ZONE" ] && command -v aws >/dev/null 2>&1; then
    ZONE="$(aws cloudformation describe-stacks --stack-name "${VPC_STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`AvailabilityZone`].OutputValue' \
        --output text 2>/dev/null || true)"
    [ "$ZONE" = "None" ] && ZONE=""
fi
[ -n "$ZONE" ] || {
    echo "Error: could not determine the availability zone." >&2
    echo "       Start the cluster, set VPC_AZ in cluster.env, or make sure the" >&2
    echo "       ${VPC_STACK_NAME} CloudFormation stack is reachable." >&2
    exit 1
}
# Every AWS zone is its region plus one trailing letter.
[ -n "$REGION" ] || REGION="${ZONE%?}"

if [ -z "$MC_NAME" ]; then
    MC_NAME="local-cluster"
    if [ "$HAVE_CLUSTER" -eq 1 ] && "$OC" get managedcluster >/dev/null 2>&1; then
        detected="$("$OC" get managedcluster -o jsonpath='{.items[?(@.spec.leaseDurationSeconds)].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -x 'local-cluster' || true)"
        [ -n "$detected" ] && MC_NAME="$detected"
    fi
fi

OUT="${VALUES_DIR}/${MC_NAME}.yaml"

render() {
    cat <<EOF
# Generated by scripts/45-autoshift-values.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# from ${ROOT}/cluster.env and the live cluster. Re-run that script rather than
# editing by hand; it is regenerated, not merged.
#
# The key below is the ACM ManagedCluster name, which for a hub managing itself
# is 'local-cluster' - not the installer's cluster name (${CLUSTER_NAME}).
clusters:
  ${MC_NAME}:
    config:
      clusterSet: '${CLUSTERSET}'
    labels:
      # GPU nodes. The policy clones this cluster's worker MachineSet, so the
      # subnet, AMI, security groups and IAM profile are discovered at
      # reconcile time and deliberately absent here.
      gpu-nodes: '${REPLICAS}'
      gpu-nodes-provider: aws
      gpu-nodes-instance-type: '${INSTANCE_TYPE}'
      gpu-nodes-zone-1: '${ZONE}'
      gpu-nodes-region: '${REGION}'
      gpu-nodes-spot: '${SPOT}'
EOF
}

if [ "$TO_STDOUT" -eq 1 ]; then
    render
    exit 0
fi

if [ -e "$OUT" ] && [ "$FORCE" -eq 0 ]; then
    echo "Error: ${OUT} already exists. Re-run with --force to overwrite." >&2
    exit 1
fi

render > "$OUT"

echo "==> Wrote ${OUT}"
echo "    ManagedCluster: ${MC_NAME}   clusterset: ${CLUSTERSET}"
echo "    GPU: ${REPLICAS} x ${INSTANCE_TYPE} in ${ZONE} (spot=${SPOT})"
if [ "$SPOT" = "true" ]; then
    echo
    echo "    Spot has no fallback. If capacity is unavailable - or denied by a" >&2
    echo "    service control policy, which looks identical from inside the" >&2
    echo "    cluster - the machines never appear and policy-gpu-nodes-test goes" >&2
    echo "    NonCompliant. That is deliberate; a silent switch to on-demand" >&2
    echo "    would be a surprise on the bill." >&2
fi
cat <<EOF

This file lives in the AutoShift checkout but is NOT committed there - it
describes this cluster, not the policies. Apply it with:

    scripts/50-autoshift.sh bootstrap

Policies still have to be switched on for the clusterset. Set the labels you
want in ${AUTOSHIFT_DIR}/autoshift/values/clustersets/${CLUSTERSET}.yaml, then
re-run the bootstrap and watch:

    scripts/50-autoshift.sh status
EOF
