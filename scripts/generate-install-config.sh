#!/usr/bin/env bash
#
# generate-install-config.sh - render install-config.yaml for the platform
#                              selected in cluster.env.
#
# Usage: scripts/generate-install-config.sh [-o <output file>]
#
# Reads settings from cluster.env and credentials from the environment (see
# secrets/). Each platform starts from its own template under templates/ and
# gets a common patch plus a platform-specific one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${ROOT}/install-config.yaml"

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)   sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "generate-install-config.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# shellcheck source=../cluster.env
. "${ROOT}/cluster.env"

TEMPLATE="${ROOT}/templates/install-config.yaml.${PLATFORM}"
[ -f "$TEMPLATE" ] || {
    echo "Error: no template for PLATFORM='${PLATFORM}'." >&2
    echo "       Expected ${TEMPLATE}" >&2
    echo "       Supported: aws, ibmcloud, baremetal" >&2
    exit 1
}

for cmd in yq jq; do
    command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is not installed." >&2; exit 1; }
done

# This script is written against python-yq (kislyuk), which takes jq expressions
# and needs -y to emit YAML. Go yq (mikefarah) uses an incompatible syntax.
if ! yq --help 2>&1 | grep -q -- '-y'; then
    echo "Error: this script needs python-yq (pip install yq), not Go yq." >&2
    exit 1
fi

[ -f "$PULL_SECRET_FILE" ] || { echo "Error: pull secret not found: $PULL_SECRET_FILE" >&2; exit 1; }
[ -f "$SSH_KEY_FILE" ]     || { echo "Error: ssh public key not found: $SSH_KEY_FILE" >&2; exit 1; }
jq -e . "$PULL_SECRET_FILE" >/dev/null || { echo "Error: pull secret is not valid JSON." >&2; exit 1; }

# Convert "a,b, c" into a JSON array, or [] when empty. The trailing newline
# matters: with no input at all, `jq -R` reads zero lines and emits nothing,
# which then breaks --argjson.
csv_to_json() {
    printf '%s\n' "${1:-}" |
        jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# --- platform: aws ----------------------------------------------------------
# Subnets, zone, and region come from the CloudFormation stack that owns the
# VPC, so the role assignments live in one place (the CloudFormation template).
patch_aws() {
    command -v aws >/dev/null || { echo "Error: 'aws' CLI is not installed." >&2; exit 1; }

    local region az subnets_yaml subnets_json
    region="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set (see secrets/aws.env)}"

    stack_output() {
        aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
            --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
    }

    echo "==> Reading outputs from stack ${VPC_STACK_NAME}"
    az="$(stack_output AvailabilityZone)"
    subnets_yaml="$(stack_output InstallConfigSubnets)"
    [ -n "$az" ] && [ -n "$subnets_yaml" ] || {
        echo "Error: stack ${VPC_STACK_NAME} did not return the expected outputs." >&2
        exit 1
    }
    echo "    region=${region} az=${az}"

    # Base domain: use the configured value, else auto-detect the account's
    # single public hosted zone. More than one is ambiguous, so fail rather
    # than guess.
    if [ -z "${BASE_DOMAIN}" ]; then
        echo "==> Detecting public Route 53 hosted zone"
        local zones
        mapfile -t zones < <(aws route53 list-hosted-zones \
            --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text | tr '\t' '\n')
        case "${#zones[@]}" in
            0) echo "Error: no public Route 53 hosted zone found. Create one, or" >&2
               echo "       set BASE_DOMAIN in cluster.env." >&2
               exit 1 ;;
            1) BASE_DOMAIN="${zones[0]%.}" ;;
            *) echo "Error: ${#zones[@]} public hosted zones found: ${zones[*]}" >&2
               echo "       Set BASE_DOMAIN in cluster.env to pick one." >&2
               exit 1 ;;
        esac
    fi

    subnets_json="$(printf '%s\n' "$subnets_yaml" | yq -c '.platform.aws.vpc.subnets')"

    yq -y -i \
        --arg region "$region" \
        --arg az "$az" \
        --argjson subnets "$subnets_json" \
        '.platform.aws.region = $region
         | .platform.aws.vpc.subnets = $subnets
         | .controlPlane.platform.aws.zones = [$az]
         | .compute[0].platform.aws.zones = [$az]' \
        "$OUTPUT_FILE"
}

# --- platform: ibmcloud -----------------------------------------------------
patch_ibmcloud() {
    : "${BASE_DOMAIN:?BASE_DOMAIN must be set in cluster.env for ibmcloud (a CIS domain zone)}"
    : "${IBM_REGION:?IBM_REGION must be set in cluster.env}"

    yq -y -i \
        --arg region "$IBM_REGION" \
        --arg cp "$IBM_CONTROL_PLANE_PROFILE" \
        --arg wk "$IBM_COMPUTE_PROFILE" \
        '.platform.ibmcloud.region = $region
         | .controlPlane.platform.ibmcloud.type = $cp
         | .compute[0].platform.ibmcloud.type = $wk' \
        "$OUTPUT_FILE"

    [ -n "${IBM_RESOURCE_GROUP}" ] && yq -y -i --arg v "$IBM_RESOURCE_GROUP" \
        '.platform.ibmcloud.resourceGroupName = $v' "$OUTPUT_FILE"

    # An existing VPC needs the VPC name and both subnet lists together;
    # supplying only some of them fails validation in confusing ways.
    if [ -n "${IBM_VPC_NAME}" ]; then
        local cp_subnets wk_subnets
        cp_subnets="$(csv_to_json "$IBM_CONTROL_PLANE_SUBNETS")"
        wk_subnets="$(csv_to_json "$IBM_COMPUTE_SUBNETS")"
        if [ "$cp_subnets" = "[]" ] || [ "$wk_subnets" = "[]" ]; then
            echo "Error: IBM_VPC_NAME is set, so IBM_CONTROL_PLANE_SUBNETS and" >&2
            echo "       IBM_COMPUTE_SUBNETS must be set too." >&2
            exit 1
        fi
        yq -y -i \
            --arg vpc "$IBM_VPC_NAME" \
            --argjson cps "$cp_subnets" \
            --argjson wks "$wk_subnets" \
            '.platform.ibmcloud.vpcName = $vpc
             | .platform.ibmcloud.controlPlaneSubnets = $cps
             | .platform.ibmcloud.computeSubnets = $wks' \
            "$OUTPUT_FILE"
        echo "    using existing VPC ${IBM_VPC_NAME}"
    else
        echo "    installer will create the VPC (it is destroyed with the cluster)"
    fi
}

# --- platform: baremetal (agent-based installer) ----------------------------
# Also renders agent-config.yaml alongside install-config.yaml; the agent
# installer consumes both when building the ISO.
patch_baremetal() {
    : "${BASE_DOMAIN:?BASE_DOMAIN must be set in cluster.env for baremetal}"
    : "${BM_MACHINE_CIDR:?BM_MACHINE_CIDR must be set in cluster.env}"
    : "${BM_RENDEZVOUS_IP:?BM_RENDEZVOUS_IP must be set in cluster.env}"

    local agent_template="${ROOT}/templates/agent-config.yaml.baremetal"
    local agent_out="${OUTPUT_FILE%/*}/agent-config.yaml"
    [ -f "$agent_template" ] || { echo "Error: missing ${agent_template}" >&2; exit 1; }

    yq -y -i \
        --arg cidr "$BM_MACHINE_CIDR" \
        --argjson cp "$BM_CONTROL_PLANE_REPLICAS" \
        --argjson wk "$BM_COMPUTE_REPLICAS" \
        '.networking.machineNetwork = [{"cidr": $cidr}]
         | .controlPlane.replicas = $cp
         | .compute[0].replicas = $wk' \
        "$OUTPUT_FILE"

    # Single-node OpenShift cannot use platform.baremetal at all. The installer
    # rejects it with "Only platform none and external supports 1 ControlPlane
    # and 0 Compute nodes", so swap the whole platform stanza for `none`. VIPs
    # go with it: one node has nothing to balance across.
    if [ "$BM_CONTROL_PLANE_REPLICAS" = "1" ] && [ "$BM_COMPUTE_REPLICAS" = "0" ]; then
        echo "    single-node cluster: using 'platform: none' and no VIPs"
        yq -y -i '.platform = {"none": {}}' "$OUTPUT_FILE"
    else
        : "${BM_API_VIP:?BM_API_VIP must be set in cluster.env (except for single-node)}"
        : "${BM_INGRESS_VIP:?BM_INGRESS_VIP must be set in cluster.env (except for single-node)}"
        yq -y -i \
            --arg api "$BM_API_VIP" \
            --arg ing "$BM_INGRESS_VIP" \
            '.platform.baremetal.apiVIPs = [$api]
             | .platform.baremetal.ingressVIPs = [$ing]' \
            "$OUTPUT_FILE"
    fi

    cp "$agent_template" "$agent_out"
    yq -y -i \
        --arg name "$CLUSTER_NAME" \
        --arg ip "$BM_RENDEZVOUS_IP" \
        '.metadata.name = $name | .rendezvousIP = $ip' \
        "$agent_out"

    if grep -q CHANGEME "$agent_out"; then
        echo "Error: unresolved CHANGEME placeholders in ${agent_out}:" >&2
        grep -n CHANGEME "$agent_out" >&2
        exit 1
    fi
    echo "    wrote ${agent_out}"
}

echo "==> Platform: ${PLATFORM}"
echo "==> Rendering ${OUTPUT_FILE}"
cp "$TEMPLATE" "$OUTPUT_FILE"

"patch_${PLATFORM}"

# Common fields, applied last so BASE_DOMAIN picks up anything a platform
# handler resolved (AWS auto-detects it from Route 53).
yq -y -i \
    --arg domain "$BASE_DOMAIN" \
    --arg name   "$CLUSTER_NAME" \
    --arg ps     "$(tr -d '\n' < "$PULL_SECRET_FILE")" \
    --arg key    "$(cat "$SSH_KEY_FILE")" \
    '.baseDomain = $domain
     | .metadata.name = $name
     | .pullSecret = $ps
     | .sshKey = $key' \
    "$OUTPUT_FILE"

echo "    baseDomain=${BASE_DOMAIN} cluster=${CLUSTER_NAME}"

# Nothing should reach the installer with a placeholder still in it.
if grep -q CHANGEME "$OUTPUT_FILE"; then
    echo >&2
    echo "Error: unresolved CHANGEME placeholders remain in ${OUTPUT_FILE}:" >&2
    grep -n CHANGEME "$OUTPUT_FILE" >&2
    exit 1
fi

echo "==> Wrote ${OUTPUT_FILE}"
