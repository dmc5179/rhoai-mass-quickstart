#!/usr/bin/env bash
#
# 90-destroy-cluster.sh - tear down the cluster, including after a failed or
#                         partial install.
#
# Usage: scripts/90-destroy-cluster.sh [--with-vpc] [--purge] [--log-level <level>]
#
#   --with-vpc   also delete the VPC CloudFormation stack (AWS). Off by
#                default: the VPC is meant to outlive the cluster.
#   --purge      delete the cluster state directory instead of archiving it.
#   --log-level  installer log level (default: debug)
#
# `openshift-install destroy cluster` works from metadata.json, which the
# installer writes early - so this cleans up a run that died partway, not just
# a cluster that finished building. It deletes everything tagged
# kubernetes.io/cluster/<infraID>=owned.
#
# The state directory is archived rather than deleted, because metadata.json is
# the only record of which cloud resources belong to this cluster. Losing it
# before everything is gone means hunting resources down by hand.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_VPC=0
PURGE=0
LOG_LEVEL="${LOG_LEVEL:-debug}"
ORIG_ARGS=("$@")

while [ $# -gt 0 ]; do
    case "$1" in
        --with-vpc)  WITH_VPC=1; shift ;;
        --purge)     PURGE=1; shift ;;
        --log-level) LOG_LEVEL="$2"; shift 2 ;;
        -h|--help)   sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "90-destroy-cluster.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

case "$PLATFORM" in
    aws)       CREDS="${ROOT}/secrets/aws.env" ;;
    ibmcloud)  CREDS="${ROOT}/secrets/ibm.env" ;;
    baremetal) CREDS="" ;;
    *) echo "Error: unsupported PLATFORM='${PLATFORM}'" >&2; exit 1 ;;
esac
if [ -n "$CREDS" ]; then
    [ -f "$CREDS" ] || { echo "Error: credentials not found: ${CREDS}" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$CREDS"
fi

# Same re-exec logging as phase 10: a pipeline rather than process
# substitution, so nothing is lost if this exits early.
if [ -z "${_LOG_WRAPPED:-}" ]; then
    mkdir -p "${ROOT}/logs"
    LOG_FILE="${ROOT}/logs/destroy-${PLATFORM}-$(date +%Y%m%d-%H%M%S).log"
    export LOG_FILE _LOG_WRAPPED=1
    set -o pipefail
    "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} 2>&1 | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
fi

echo "==> Logging to ${LOG_FILE}"

if [ "$PLATFORM" = "baremetal" ]; then
    cat >&2 <<EOF
Error: agent-based bare metal installs cannot be destroyed from here. There is
       no cloud API to delete machines through. Wipe or re-provision the
       hardware, then remove ${CLUSTER_DIR} to start over.
EOF
    exit 1
fi

if [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    echo "Nothing to destroy: no ${CLUSTER_DIR}/metadata.json."
    if [ -d "$CLUSTER_DIR" ] && [ -n "$(ls -A "$CLUSTER_DIR" 2>/dev/null)" ]; then
        echo
        echo "The directory exists but has no metadata.json, so the installer" >&2
        echo "cannot identify the cloud resources. If a cluster really was" >&2
        echo "created, find its resources by the kubernetes.io/cluster/<infraID>" >&2
        echo "tag and remove them by hand." >&2
        exit 1
    fi
    exit 0
fi

INFRA_ID="$(jq -r '.infraID' "${CLUSTER_DIR}/metadata.json")"
echo "==> Destroying cluster ${INFRA_ID}"
echo "    Everything tagged kubernetes.io/cluster/${INFRA_ID}=owned will be deleted."

# The installer is idempotent here and exits 0 when there is nothing left, so
# it is safe to re-run after a partial failure.
"$OPENSHIFT_INSTALL" destroy cluster --dir "$CLUSTER_DIR" --log-level="$LOG_LEVEL"

echo "==> Cluster resources deleted"

# --- VPC --------------------------------------------------------------------
# Untouched by the installer: the VPC carries no kubernetes.io/cluster/*=owned
# tags, which is what lets it outlive the cluster. Only the "shared" tags the
# installer added to the subnets are removed, by the installer itself.
if [ "$PLATFORM" = "aws" ]; then
    if [ "$WITH_VPC" -eq 1 ]; then
        if aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" >/dev/null 2>&1; then
            echo "==> Deleting VPC stack ${VPC_STACK_NAME}"
            aws cloudformation delete-stack --stack-name "$VPC_STACK_NAME"
            echo "    Waiting for the stack to go away"
            aws cloudformation wait stack-delete-complete --stack-name "$VPC_STACK_NAME"
            echo "    Done."
        else
            echo "==> VPC stack ${VPC_STACK_NAME} does not exist; nothing to delete"
        fi
    else
        echo "==> Keeping VPC stack ${VPC_STACK_NAME} (pass --with-vpc to remove it)"
        echo "    Note it still costs money: the NAT gateway and its Elastic IP"
        echo "    are billed whether or not a cluster is using them."
    fi
fi

# --- state directory --------------------------------------------------------
# Phase 10 refuses to start when this is non-empty, so it has to be cleared
# one way or the other before rebuilding.
if [ "$PURGE" -eq 1 ]; then
    echo "==> Removing ${CLUSTER_DIR}"
    rm -rf "$CLUSTER_DIR"
else
    ARCHIVE="${CLUSTER_DIR}-destroyed-$(date +%Y%m%d-%H%M%S)"
    echo "==> Archiving state to ${ARCHIVE}"
    mv "$CLUSTER_DIR" "$ARCHIVE"
    echo "    Delete it once you are satisfied nothing was left behind."
fi

cat <<EOF

Done. To rebuild:
    scripts/10-deploy-cluster.sh

Full log of this run: ${LOG_FILE}
EOF
