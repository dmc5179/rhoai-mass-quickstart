#!/usr/bin/env bash
#
# generate-config.sh - render install-config.yaml from the local template using
#                      the outputs of the VPC CloudFormation stack.
#
# Usage: scripts/generate-config.sh [-o <output file>]
#
# Reads settings from cluster.env and credentials from the environment (see
# secrets/aws.env). The VPC stack must already exist; 10-deploy-cluster.sh
# creates it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/templates/install-config.yaml.existingvpc"
OUTPUT_FILE="${ROOT}/install-config.yaml"

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)   sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "generate-config.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"

for cmd in aws yq jq; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is not installed." >&2; exit 1; }
done

# This script is written against python-yq (kislyuk), which takes jq expressions
# and needs -y to emit YAML. Go yq (mikefarah) uses an incompatible syntax.
if ! yq --help 2>&1 | grep -q -- '-y'; then
    echo "Error: this script needs python-yq (pip install yq), not Go yq." >&2
    exit 1
fi

[ -f "$TEMPLATE" ] || { echo "Error: template not found: $TEMPLATE" >&2; exit 1; }

stack_output() {
    aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

echo "==> Reading outputs from stack ${VPC_STACK_NAME}"
REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set (see aws.env)}"
AZ="$(stack_output AvailabilityZone)"
SUBNETS_YAML="$(stack_output InstallConfigSubnets)"
[ -n "$AZ" ] && [ -n "$SUBNETS_YAML" ] || {
    echo "Error: stack ${VPC_STACK_NAME} did not return the expected outputs." >&2
    exit 1
}
echo "    region=${REGION} az=${AZ}"

# Base domain: use the configured value, else auto-detect the account's single
# public hosted zone. More than one is ambiguous, so fail rather than guess.
if [ -z "${BASE_DOMAIN}" ]; then
    echo "==> Detecting public Route 53 hosted zone"
    mapfile -t ZONES < <(aws route53 list-hosted-zones \
        --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text | tr '\t' '\n')
    case "${#ZONES[@]}" in
        0) echo "Error: no public Route 53 hosted zone found. Register a domain and" >&2
           echo "       create a public hosted zone, or set BASE_DOMAIN in cluster.env." >&2
           exit 1 ;;
        1) BASE_DOMAIN="${ZONES[0]%.}" ;;
        *) echo "Error: ${#ZONES[@]} public hosted zones found: ${ZONES[*]}" >&2
           echo "       Set BASE_DOMAIN in cluster.env to pick one." >&2
           exit 1 ;;
    esac
fi
echo "    baseDomain=${BASE_DOMAIN}"

[ -f "$PULL_SECRET_FILE" ] || { echo "Error: pull secret not found: $PULL_SECRET_FILE" >&2; exit 1; }
[ -f "$SSH_KEY_FILE" ]     || { echo "Error: ssh public key not found: $SSH_KEY_FILE" >&2; exit 1; }
jq -e . "$PULL_SECRET_FILE" >/dev/null || { echo "Error: pull secret is not valid JSON." >&2; exit 1; }

echo "==> Rendering ${OUTPUT_FILE}"
cp "$TEMPLATE" "$OUTPUT_FILE"

# The stack emits a full platform: block; take just the subnets list from it so
# the role assignments stay in one place (the CloudFormation template).
SUBNETS_JSON="$(printf '%s\n' "$SUBNETS_YAML" | yq -c '.platform.aws.vpc.subnets')"

yq -y -i \
    --arg domain "$BASE_DOMAIN" \
    --arg name   "$CLUSTER_NAME" \
    --arg region "$REGION" \
    --arg az     "$AZ" \
    --arg ps     "$(tr -d '\n' < "$PULL_SECRET_FILE")" \
    --arg key    "$(cat "$SSH_KEY_FILE")" \
    --argjson subnets "$SUBNETS_JSON" \
    '.baseDomain = $domain
     | .metadata.name = $name
     | .platform.aws.region = $region
     | .platform.aws.vpc.subnets = $subnets
     | .controlPlane.platform.aws.zones = [$az]
     | .compute[0].platform.aws.zones = [$az]
     | .pullSecret = $ps
     | .sshKey = $key' \
    "$OUTPUT_FILE"

echo "==> Wrote ${OUTPUT_FILE}"
