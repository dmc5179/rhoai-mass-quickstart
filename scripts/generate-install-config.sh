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

# Written against Go yq v4 (mikefarah/yq) - the `yq` Fedora ships. The Python
# yq (kislyuk, `pip install yq`) shares the name but takes jq syntax and fails
# here in confusing ways, so check up front.
#
# Two idioms used throughout, because Go yq has no --arg/--argjson:
#   V="$x" yq -i '.a = strenv(V)'   a string, inserted verbatim
#   V="$j" yq -i '.a = env(V)'      parsed as YAML/JSON, so arrays and integers
#                                   keep their type
# Go yq also preserves comments, which the Python yq dropped - see the
# CHANGEME check at the end.
if ! yq --version 2>&1 | grep -q 'mikefarah/yq.* v4\.'; then
    echo "Error: this script needs Go yq v4 (https://github.com/mikefarah/yq)." >&2
    echo "       Found: $(yq --version 2>&1 | head -1)" >&2
    echo "       On Fedora: dnf install yq" >&2
    exit 1
fi

[ -f "$PULL_SECRET_FILE" ] || { echo "Error: pull secret not found: $PULL_SECRET_FILE" >&2; exit 1; }
[ -f "$SSH_KEY_FILE" ]     || { echo "Error: ssh public key not found: $SSH_KEY_FILE" >&2; exit 1; }
jq -e . "$PULL_SECRET_FILE" >/dev/null || { echo "Error: pull secret is not valid JSON." >&2; exit 1; }

# Convert "a,b, c" into a JSON array, or [] when empty. The trailing newline
# matters: with no input at all, `jq -R` reads zero lines and emits nothing,
# which then breaks the env() parse that consumes it.
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

    # The subnet IDs come from the VPC stack, so it has to exist first.
    # 10-deploy-cluster.sh creates it; this script never does, to keep network
    # creation in one place.
    if ! aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" >/dev/null 2>&1; then
        echo "Error: CloudFormation stack '${VPC_STACK_NAME}' does not exist in ${region}." >&2
        echo "       This script reads the cluster's subnet IDs from that stack, so the" >&2
        echo "       network has to be created first. Either run the full deploy:" >&2
        echo >&2
        echo "           scripts/10-deploy-cluster.sh" >&2
        echo >&2
        echo "       which creates the stack and then renders this file, or create just" >&2
        echo "       the stack and re-run this script:" >&2
        echo >&2
        echo "           aws cloudformation create-stack --stack-name ${VPC_STACK_NAME} \\" >&2
        echo "               --template-body file://${ROOT}/cloudformation/01_vpc.yaml \\" >&2
        echo "               --parameters ParameterKey=InfrastructureName,ParameterValue=${VPC_INFRA_NAME} \\" >&2
        echo "                            ParameterKey=VpcCidr,ParameterValue=${VPC_CIDR} \\" >&2
        echo "                            ParameterKey=AvailabilityZone,ParameterValue=${VPC_AZ}" >&2
        echo "           aws cloudformation wait stack-create-complete --stack-name ${VPC_STACK_NAME}" >&2
        exit 1
    fi

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

    subnets_json="$(printf '%s\n' "$subnets_yaml" | yq -o=json -I=0 '.platform.aws.vpc.subnets')"

    # Machine sizing comes from cluster.env so it is reviewable in one place
    # alongside everything else about the cluster, rather than being buried in
    # the template. The template's own values are the same defaults, so it
    # still renders sensibly on its own.
    local cp_type cp_reps wk_type wk_reps
    cp_type="${AWS_CONTROL_PLANE_TYPE:-m6i.2xlarge}"
    cp_reps="${AWS_CONTROL_PLANE_REPLICAS:-3}"
    wk_type="${AWS_WORKER_TYPE:-m6i.4xlarge}"
    wk_reps="${AWS_WORKER_REPLICAS:-3}"

    for v in "$cp_reps" "$wk_reps"; do
        case "$v" in ''|*[!0-9]*)
            echo "Error: replica counts must be integers (got '${v}')." >&2; exit 1 ;;
        esac
    done
    echo "    control plane=${cp_reps} x ${cp_type}   workers=${wk_reps} x ${wk_type}"

    V_REGION="$region" V_AZ="$az" V_SUBNETS="$subnets_json" \
    V_CPTYPE="$cp_type" V_WKTYPE="$wk_type" V_CPREPS="$cp_reps" V_WKREPS="$wk_reps" \
    yq -i '
          .platform.aws.region = strenv(V_REGION)
        | .platform.aws.vpc.subnets = env(V_SUBNETS)
        | .platform.aws.vpc.subnets style=""
        | .controlPlane.platform.aws.zones = [strenv(V_AZ)]
        | .controlPlane.platform.aws.type = strenv(V_CPTYPE)
        | .controlPlane.replicas = env(V_CPREPS)
        | .compute[0].platform.aws.zones = [strenv(V_AZ)]
        | .compute[0].platform.aws.type = strenv(V_WKTYPE)
        | .compute[0].replicas = env(V_WKREPS)' \
        "$OUTPUT_FILE"
}

# --- platform: ibmcloud -----------------------------------------------------
patch_ibmcloud() {
    : "${BASE_DOMAIN:?BASE_DOMAIN must be set in cluster.env for ibmcloud (a CIS domain zone)}"
    : "${IBM_REGION:?IBM_REGION must be set in cluster.env}"

    V_REGION="$IBM_REGION" V_CP="$IBM_CONTROL_PLANE_PROFILE" V_WK="$IBM_COMPUTE_PROFILE" \
    yq -i '
          .platform.ibmcloud.region = strenv(V_REGION)
        | .controlPlane.platform.ibmcloud.type = strenv(V_CP)
        | .compute[0].platform.ibmcloud.type = strenv(V_WK)' \
        "$OUTPUT_FILE"

    [ -n "${IBM_RESOURCE_GROUP}" ] && V="$IBM_RESOURCE_GROUP" yq -i \
        '.platform.ibmcloud.resourceGroupName = strenv(V)' "$OUTPUT_FILE"

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
        V_VPC="$IBM_VPC_NAME" V_CPS="$cp_subnets" V_WKS="$wk_subnets" \
        yq -i '
              .platform.ibmcloud.vpcName = strenv(V_VPC)
            | .platform.ibmcloud.controlPlaneSubnets = env(V_CPS)
            | .platform.ibmcloud.computeSubnets = env(V_WKS)
            | .platform.ibmcloud.controlPlaneSubnets style=""
            | .platform.ibmcloud.computeSubnets style=""' \
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

    V_CIDR="$BM_MACHINE_CIDR" V_CP="$BM_CONTROL_PLANE_REPLICAS" V_WK="$BM_COMPUTE_REPLICAS" \
    yq -i '
          .networking.machineNetwork = [{"cidr": strenv(V_CIDR)}]
        | .controlPlane.replicas = env(V_CP)
        | .compute[0].replicas = env(V_WK)' \
        "$OUTPUT_FILE"

    # Single-node OpenShift cannot use platform.baremetal at all. The installer
    # rejects it with "Only platform none and external supports 1 ControlPlane
    # and 0 Compute nodes", so swap the whole platform stanza for `none`. VIPs
    # go with it: one node has nothing to balance across.
    if [ "$BM_CONTROL_PLANE_REPLICAS" = "1" ] && [ "$BM_COMPUTE_REPLICAS" = "0" ]; then
        echo "    single-node cluster: using 'platform: none' and no VIPs"
        yq -i '.platform = {"none": {}}' "$OUTPUT_FILE"
    else
        : "${BM_API_VIP:?BM_API_VIP must be set in cluster.env (except for single-node)}"
        : "${BM_INGRESS_VIP:?BM_INGRESS_VIP must be set in cluster.env (except for single-node)}"
        V_API="$BM_API_VIP" V_ING="$BM_INGRESS_VIP" yq -i '
              .platform.baremetal.apiVIPs = [strenv(V_API)]
            | .platform.baremetal.ingressVIPs = [strenv(V_ING)]' \
            "$OUTPUT_FILE"
    fi

    cp "$agent_template" "$agent_out"
    V_NAME="$CLUSTER_NAME" V_IP="$BM_RENDEZVOUS_IP" yq -i \
        '.metadata.name = strenv(V_NAME) | .rendezvousIP = strenv(V_IP)' \
        "$agent_out"

    if grep -qE '^[^#]*CHANGEME' "$agent_out"; then
        echo "Error: unresolved CHANGEME placeholders in ${agent_out}:" >&2
        grep -nE '^[^#]*CHANGEME' "$agent_out" >&2
        exit 1
    fi
    echo "    wrote ${agent_out}"
}

echo "==> Platform: ${PLATFORM}"
echo "==> Rendering ${OUTPUT_FILE}"
cp "$TEMPLATE" "$OUTPUT_FILE"

# Never leave a half-rendered config behind: one with CHANGEME placeholders
# still in it looks plausible enough to be used by mistake.
cleanup_partial() {
    local rc=$?
    [ "$rc" -ne 0 ] && rm -f "$OUTPUT_FILE" "${OUTPUT_FILE%/*}/agent-config.yaml"
    return $rc
}
trap cleanup_partial EXIT

"patch_${PLATFORM}"

# Common fields, applied last so BASE_DOMAIN picks up anything a platform
# handler resolved (AWS auto-detects it from Route 53).
# strenv keeps the pull secret a STRING. env() would parse its JSON into a YAML
# map, which the installer rejects - pullSecret must be the JSON text itself.
case "${FIPS:-}" in
    true|false) ;;
    *) echo "Error: FIPS must be true or false (got '${FIPS:-}'); see cluster.env." >&2; exit 1 ;;
esac
V_FIPS="$FIPS" V_DOMAIN="$BASE_DOMAIN" V_NAME="$CLUSTER_NAME" \
V_PS="$(tr -d '\n' < "$PULL_SECRET_FILE")" V_KEY="$(cat "$SSH_KEY_FILE")" \
yq -i '
      .fips = env(V_FIPS)
    | .baseDomain = strenv(V_DOMAIN)
    | .metadata.name = strenv(V_NAME)
    | .pullSecret = strenv(V_PS)
    | .sshKey = strenv(V_KEY)' \
    "$OUTPUT_FILE"

echo "    baseDomain=${BASE_DOMAIN} cluster=${CLUSTER_NAME} fips=${FIPS}"

# Nothing should reach the installer with a placeholder still in it. Comments
# are excluded: Go yq preserves the template's comments, and those mention
# CHANGEME by name. A real placeholder is a value, so it never follows a #.
if grep -qE '^[^#]*CHANGEME' "$OUTPUT_FILE"; then
    echo >&2
    echo "Error: unresolved CHANGEME placeholders remain in ${OUTPUT_FILE}:" >&2
    grep -nE '^[^#]*CHANGEME' "$OUTPUT_FILE" >&2
    exit 1
fi

echo "==> Wrote ${OUTPUT_FILE}"
