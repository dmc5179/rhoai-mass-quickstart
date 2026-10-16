#!/usr/bin/env bash
#
# 10-deploy-cluster.sh - stand up the base OpenShift cluster in AWS.
#
#   1. ensure the VPC CloudFormation stack exists
#   2. render install-config.yaml from the stack outputs
#   3. run the installer
#   4. add on-demand and spot GPU machine sets, both at replica 0
#
# Usage: scripts/10-deploy-cluster.sh [--dry-run]
#
# The VPC stack is deliberately not deleted by `openshift-install destroy
# cluster`, so the cluster can be rebuilt without re-creating the network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

. "${ROOT}/secrets/aws.env"
. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

echo "==> Checking AWS credentials"
aws sts get-caller-identity --output text --query 'Arn'

# --- 1. VPC -----------------------------------------------------------------
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

# --- 2. install-config ------------------------------------------------------
if [ -d "$CLUSTER_DIR" ] && [ -n "$(ls -A "$CLUSTER_DIR" 2>/dev/null)" ]; then
    echo "Error: ${CLUSTER_DIR} is not empty. Destroy the previous cluster first:" >&2
    echo "       \"\$OPENSHIFT_INSTALL\" destroy cluster --dir ${CLUSTER_DIR}" >&2
    exit 1
fi

# --- 3. install -------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> [dry-run] would render install-config.yaml via scripts/generate-install-config.sh"
    echo "==> [dry-run] would run: \$OPENSHIFT_INSTALL create cluster --dir ${CLUSTER_DIR}"
    echo "==> [dry-run] would add GPU machine sets (${GPU_INSTANCE_TYPE}, on-demand + spot, replicas=0)"
    exit 0
fi

echo "==> Generating install-config.yaml"
"${ROOT}/scripts/generate-install-config.sh"

# The installer consumes (and rewrites) install-config.yaml in its state
# directory, so hand it a copy and keep the rendered original for reference.
mkdir -p "$CLUSTER_DIR"
cp "${ROOT}/install-config.yaml" "${CLUSTER_DIR}/install-config.yaml"

echo "==> Creating cluster (expect 30-45 minutes)"
"$OPENSHIFT_INSTALL" create cluster --dir "$CLUSTER_DIR" --log-level=info

# --- 4. GPU machine sets ----------------------------------------------------
# Created at replica 0, so they cost nothing until scaled up.
"${ROOT}/scripts/add-gpu-machinesets.sh"

cat <<EOF

Cluster is up. To use it:

    export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig
    "\$OC" get clusterversion

The kubeadmin password is in ${CLUSTER_DIR}/auth/kubeadmin-password.
EOF
