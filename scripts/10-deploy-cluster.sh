#!/usr/bin/env bash
#
# 10-deploy-cluster.sh - stand up the base OpenShift cluster on the platform
#                        selected by PLATFORM in cluster.env.
#
#   1. ensure the network exists (AWS: the VPC CloudFormation stack)
#   2. render install-config.yaml for the platform in cluster.env
#   3. run the installer (bare metal: build an agent ISO and wait for it)
#   4. add on-demand and spot GPU machine sets at replica 0 (AWS only)
#
# Usage: scripts/10-deploy-cluster.sh [--dry-run]
#
# On AWS the VPC stack is deliberately not deleted by `openshift-install destroy
# cluster`, so the cluster can be rebuilt without re-creating the network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# cluster.env first: PLATFORM decides which credential file is needed.
. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

case "$PLATFORM" in
    aws)       CREDS="${ROOT}/secrets/aws.env" ;;
    ibmcloud)  CREDS="${ROOT}/secrets/ibm.env" ;;
    baremetal) CREDS="" ;;   # no cloud credentials needed
    *) echo "Error: unsupported PLATFORM='${PLATFORM}' (aws, ibmcloud, baremetal)" >&2; exit 1 ;;
esac

if [ -n "$CREDS" ]; then
    [ -f "$CREDS" ] || { echo "Error: credentials not found: ${CREDS}" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$CREDS"
fi

echo "==> Platform: ${PLATFORM}"

# --- 1. network -------------------------------------------------------------
# Only AWS builds its network separately. On IBM Cloud the installer either
# creates the VPC or reuses one named in cluster.env; on bare metal the network
# already exists.
if [ "$PLATFORM" = "aws" ]; then
    echo "==> Checking AWS credentials"
    aws sts get-caller-identity --output text --query 'Arn'

    if aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" >/dev/null 2>&1; then
        echo "==> VPC stack ${VPC_STACK_NAME} already exists; reusing it"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "==> [dry-run] would create VPC stack ${VPC_STACK_NAME} from cloudformation/01_vpc.yaml"
    else
        echo "==> Creating VPC stack ${VPC_STACK_NAME}"
        aws cloudformation create-stack \
            --stack-name "$VPC_STACK_NAME" \
            --template-body "file://${ROOT}/cloudformation/01_vpc.yaml" \
            --parameters \
                "ParameterKey=InfrastructureName,ParameterValue=${VPC_INFRA_NAME}" \
                "ParameterKey=VpcCidr,ParameterValue=${VPC_CIDR}" \
                "ParameterKey=AvailabilityZone,ParameterValue=${VPC_AZ}" \
            --output text --query 'StackId'

        echo "    Waiting for stack to finish (a few minutes)"
        aws cloudformation wait stack-create-complete --stack-name "$VPC_STACK_NAME"
    fi
fi

# --- 2. install-config ------------------------------------------------------
if [ -d "$CLUSTER_DIR" ] && [ -n "$(ls -A "$CLUSTER_DIR" 2>/dev/null)" ]; then
    echo "Error: ${CLUSTER_DIR} is not empty." >&2
    if [ "$PLATFORM" = "baremetal" ]; then
        echo "       Agent-based installs cannot be destroyed from here; wipe the" >&2
        echo "       machines, then remove the directory to start over." >&2
    else
        echo "       Destroy the previous cluster first:" >&2
        echo "       \"\$OPENSHIFT_INSTALL\" destroy cluster --dir ${CLUSTER_DIR}" >&2
    fi
    exit 1
fi

# --- 3. install -------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> [dry-run] would render install-config.yaml via scripts/generate-install-config.sh"
    if [ "$PLATFORM" = "baremetal" ]; then
        echo "==> [dry-run] would also render agent-config.yaml"
        echo "==> [dry-run] would run: \$OPENSHIFT_INSTALL agent create image --dir ${CLUSTER_DIR}"
    else
        echo "==> [dry-run] would run: \$OPENSHIFT_INSTALL create cluster --dir ${CLUSTER_DIR}"
    fi
    [ "$PLATFORM" = "aws" ] && \
        echo "==> [dry-run] would add GPU machine sets (${GPU_INSTANCE_TYPE}, on-demand + spot, replicas=0)"
    exit 0
fi

echo "==> Generating install-config.yaml"
"${ROOT}/scripts/generate-install-config.sh"

# The installer consumes (and rewrites) these in its state directory, so hand
# it copies and keep the rendered originals for reference.
mkdir -p "$CLUSTER_DIR"
cp "${ROOT}/install-config.yaml" "${CLUSTER_DIR}/install-config.yaml"

if [ "$PLATFORM" = "baremetal" ]; then
    # Agent-based: build a bootable ISO, then wait for the machines that you
    # start from it. There is no cloud API to create machines through, so the
    # installer cannot do this part.
    cp "${ROOT}/agent-config.yaml" "${CLUSTER_DIR}/agent-config.yaml"

    echo "==> Building agent ISO"
    "$OPENSHIFT_INSTALL" agent create image --dir "$CLUSTER_DIR" --log-level=info

    cat <<EOF

ISO ready: ${CLUSTER_DIR}/agent.x86_64.iso

Boot all ${BM_CONTROL_PLANE_REPLICAS} control plane and ${BM_COMPUTE_REPLICAS} worker machines from it now.
The node at ${BM_RENDEZVOUS_IP} bootstraps the cluster and must be among them.

Waiting for the install to complete. Interrupting here is safe - resume with:
    "\$OPENSHIFT_INSTALL" agent wait-for install-complete --dir ${CLUSTER_DIR}

EOF
    "$OPENSHIFT_INSTALL" agent wait-for bootstrap-complete --dir "$CLUSTER_DIR" --log-level=info
    "$OPENSHIFT_INSTALL" agent wait-for install-complete --dir "$CLUSTER_DIR" --log-level=info
else
    echo "==> Creating cluster (expect 30-45 minutes)"
    "$OPENSHIFT_INSTALL" create cluster --dir "$CLUSTER_DIR" --log-level=info
fi

# --- 4. GPU machine sets ----------------------------------------------------
# Created at replica 0, so they cost nothing until scaled up. AWS only: the
# script patches AWS-specific providerSpec fields (instanceType,
# spotMarketOptions), which have no direct equivalent on the other platforms.
if [ "$PLATFORM" = "aws" ]; then
    "${ROOT}/scripts/add-gpu-machinesets.sh"
else
    echo "==> Skipping GPU machine sets (not implemented for ${PLATFORM})"
fi

cat <<EOF

Cluster is up. To use it:

    export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig
    "\$OC" get clusterversion

The kubeadmin password is in ${CLUSTER_DIR}/auth/kubeadmin-password.
EOF
