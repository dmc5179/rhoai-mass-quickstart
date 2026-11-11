#!/usr/bin/env bash
#
# dns-zone-clash-test.sh - reproduce the Connectivity Link DNSPolicy failure with
#                          same-name public and private Route 53 hosted zones,
#                          and prove the subdomain workaround. Then clean up.
#
# Usage: scripts/dns-zone-clash-test.sh run      [options]
#        scripts/dns-zone-clash-test.sh status   [options]
#        scripts/dns-zone-clash-test.sh teardown [options]
#
# Options:
#   --label <l>            Test subdomain label (default: $DNS_TEST_LABEL or "dnstest")
#   --gateway-class <c>    GatewayClass for the test Gateway (default: discovered from
#                          the cluster's Kuadrant gateways, e.g. maas-default-gateway)
#   --timeout <seconds>    How long run waits for the Gateway and DNSRecords (default 900)
#   --dry-run              Print what would be done. Makes no AWS or cluster calls.
#
# What run builds, under the sandbox's public base zone <base>:
#
#   <label>.<base>       PUBLIC   NS-delegated from <base>
#   <label>.<base>       PRIVATE  associated with the cluster VPC     <- the clash
#   api.<label>.<base>   PUBLIC   NS-delegated from public <label>.<base>  <- the workaround
#
# plus an IAM user scoped to those zones (key in secrets/dns-zone-clash-test.env),
# and in namespace dns-zone-test a kuadrant.io/aws Secret, a Gateway with two
# listeners (*.<label>.<base> and *.api.<label>.<base>) and a DNSPolicy.
#
# Expected result, from the dns-operator code (findDNSZoneForHost walks from the
# host up; two zones with the exact same name at one level is ErrMultipleZonesFound):
#   - the *.<label>.<base> DNSRecord: Ready=False, "Unable to find suitable zone in
#     provider: multiple zones found for host"
#   - the *.api.<label>.<base> DNSRecord: Ready=True, assigned to api.<label>.<base>,
#     because the more specific zone exists only once and the duplicate parents are
#     never consulted
# run exits 0 only when both hold, and saves the DNSRecord YAML under logs/.
#
# Side effects to know about:
#   - The private zone, the public test zones and the IAM user live OUTSIDE the VPC
#     CloudFormation stack, like the maas-database.sh resources. Run teardown before
#     90-destroy-cluster.sh --with-vpc, or the stack delete can be blocked.
#   - While the test zones exist there is more than one public hosted zone, so the
#     BASE_DOMAIN auto-detection in generate-install-config.sh stops working. Set
#     BASE_DOMAIN in cluster.env, or tear the test down, before a new install.
#   - The test Gateway gets its own AWS load balancer while it exists.
#
# teardown is safe to repeat and after a partial run. It only touches hosted zones
# tagged Purpose=dns-zone-clash-test with the exact test names, the exact NS
# delegation records in the base and test zones, and the tagged IAM user.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

case "${1:-}" in
    -h|--help) sed -n '2,52p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
ACTION="${1:-}"; shift || true

LABEL="${DNS_TEST_LABEL:-dnstest}"
GATEWAY_CLASS="${GATEWAY_CLASS:-}"
TIMEOUT=900
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --label)         LABEL="$2"; shift 2 ;;
        --gateway-class) GATEWAY_CLASS="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       sed -n '2,52p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "dns-zone-clash-test.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    run|status|teardown) ;;
    *) echo "Usage: scripts/dns-zone-clash-test.sh {run|status|teardown} [--label l] [--gateway-class c] [--timeout s] [--dry-run]" >&2; exit 2 ;;
esac
[[ "$LABEL" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
    echo "Error: --label must be a single lowercase DNS label, got '${LABEL}'." >&2; exit 2; }

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "dns-zone-clash-test" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

TAG_KEY="Purpose"
TAG_VALUE="dns-zone-clash-test"
NS_TEST="dns-zone-test"
GW_NAME="dns-zone-clash"
POLICY_NAME="dns-zone-clash"
SECRET_NAME="aws-credentials"
IAM_USER="${CLUSTER_NAME}-dns-zone-clash-test"
IAM_POLICY="route53-dns-zone-clash-test"
CREDS_FILE="${ROOT}/secrets/dns-zone-clash-test.env"
EVIDENCE="${ROOT}/logs/dns-zone-clash-test-$(date +%Y%m%d-%H%M%S)-dnsrecords.yaml"

[ "$PLATFORM" = "aws" ] || { echo "Error: PLATFORM is '${PLATFORM}'; this test needs AWS Route 53." >&2; exit 1; }

# --- dry-run: describe, never call AWS or the cluster -------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    base="${BASE_DOMAIN:-<the single public hosted zone>}"
    zone="${LABEL}.${base}"
    echo "==> DRY RUN (${ACTION}): no AWS or cluster calls are made"
    echo "    base zone           ${base}  (from BASE_DOMAIN, else auto-detected, excluding test zones)"
    echo "    VPC                 output VpcId of CloudFormation stack ${VPC_STACK_NAME}"
    case "$ACTION" in
        run)
            cat <<EOF
    1. Route 53 (tag ${TAG_KEY}=${TAG_VALUE}, reused if present):
         create public  zone ${zone}
         create private zone ${zone} associated with the VPC
         create public  zone api.${zone}
         UPSERT NS ${zone}      in ${base}
         UPSERT NS api.${zone}  in public ${zone}
    2. IAM user ${IAM_USER}: inline policy ${IAM_POLICY}
         (change/list records on the three test zones only), one access key
         written to ${CREDS_FILE} (0600)
    3. Cluster, namespace ${NS_TEST}:
         Secret ${SECRET_NAME} (type kuadrant.io/aws) from that key
         Gateway ${GW_NAME} (class ${GATEWAY_CLASS:-<discovered from maas-default-gateway>})
           listener clash       *.${zone}
           listener workaround  *.api.${zone}
         DNSPolicy ${POLICY_NAME} -> Gateway ${GW_NAME}, providerRefs ${SECRET_NAME}
    4. Wait up to ${TIMEOUT}s, then expect:
         *.${zone}      Ready=False  "multiple zones found for host"
         *.api.${zone}  Ready=True   zone api.${zone}, record present in Route 53
       DNSRecord YAML saved to logs/
EOF
            ;;
        status)
            echo "    Would list the test zones (private flag, VPCs), the IAM user and the"
            echo "    Gateway / DNSPolicy / DNSRecord conditions in ${NS_TEST}." ;;
        teardown)
            cat <<EOF
    1. Delete DNSPolicy ${POLICY_NAME}, Gateway ${GW_NAME}, namespace ${NS_TEST}; wait for
       dns-operator to remove its records
    2. In each tagged test zone, delete every record except the apex NS and SOA
    3. Delete NS ${zone} from ${base} and NS api.${zone} from public ${zone}
    4. Delete private ${zone}, public api.${zone}, public ${zone} (tag and name checked)
    5. Delete IAM user ${IAM_USER} (tag checked): access keys, inline policy, user
    6. Remove ${CREDS_FILE}
EOF
            ;;
    esac
    exit 0
fi

# --- AWS and cluster access ---------------------------------------------------
command -v aws >/dev/null || { echo "Error: the 'aws' CLI is not installed." >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 is required (JSON handling)." >&2; exit 1; }
if [ -f "${ROOT}/secrets/aws.env" ]; then
    # shellcheck disable=SC1091
    . "${ROOT}/secrets/aws.env"
fi
aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "Error: AWS credentials are not valid. Check secrets/aws.env:" >&2
    aws sts get-caller-identity 2>&1 | sed 's/^/       /' >&2
    exit 1
}
REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set (see secrets/aws.env)}"

export KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
cluster_up() { timeout 30 "$OC" whoami >/dev/null 2>&1; }

stack_output() {
    aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

# The base zone, as generate-install-config.sh finds it, but ignoring the test
# zones this script creates (they would otherwise make "exactly one" fail).
detect_base_domain() {
    if [ -n "${BASE_DOMAIN:-}" ]; then echo "${BASE_DOMAIN%.}"; return; fi
    local zones=()
    # shellcheck disable=SC2016  # JMESPath backticks, not shell expansion
    mapfile -t zones < <(aws route53 list-hosted-zones \
        --query 'HostedZones[?Config.PrivateZone==`false`].Name' --output text | tr '\t' '\n' \
        | grep -v -E "^(api\.)?${LABEL}\." | sed 's/\.$//' | grep -v '^$')
    case "${#zones[@]}" in
        1) echo "${zones[0]}" ;;
        0) echo "Error: no public Route 53 hosted zone found; set BASE_DOMAIN in cluster.env." >&2; return 1 ;;
        *) echo "Error: ${#zones[@]} public hosted zones (${zones[*]}); set BASE_DOMAIN in cluster.env." >&2; return 1 ;;
    esac
}

# zone_id <name> <true|false>: ID (without /hostedzone/) of the zone with exactly
# this name and privacy, or empty.
zone_id() {
    aws route53 list-hosted-zones-by-name --dns-name "$1" --max-items 20 --output json \
    | python3 -I -c '
import json, sys
name, private = sys.argv[1].rstrip(".") + ".", sys.argv[2] == "true"
for z in json.load(sys.stdin).get("HostedZones", []):
    if z["Name"] == name and z["Config"].get("PrivateZone", False) == private:
        print(z["Id"].split("/")[-1]); break
' "$1" "$2"
}

zone_is_tagged() {
    [ "$(aws route53 list-tags-for-resource --resource-type hostedzone --resource-id "$1" \
        --query "ResourceTagSet.Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text 2>/dev/null)" = "$TAG_VALUE" ]
}

zone_ns() {
    aws route53 get-hosted-zone --id "$1" --query 'DelegationSet.NameServers' --output text | tr '\t' ' '
}

# change_ns <parent-zone-id> <UPSERT|DELETE> <record-name> <ns...>
change_ns() {
    local parent="$1" action="$2" name="$3"; shift 3
    local batch
    batch="$(python3 -I -c '
import json, sys
action, name, ns = sys.argv[1], sys.argv[2].rstrip(".") + ".", sys.argv[3:]
print(json.dumps({"Changes": [{"Action": action, "ResourceRecordSet": {
    "Name": name, "Type": "NS", "TTL": 300,
    "ResourceRecords": [{"Value": n} for n in ns]}}]}))
' "$action" "$name" "$@")"
    aws route53 change-resource-record-sets --hosted-zone-id "$parent" --change-batch "$batch" >/dev/null
}

# existing_ns <zone-id> <record-name>: the NS values of an exact non-apex NS record.
existing_ns() {
    aws route53 list-resource-record-sets --hosted-zone-id "$1" --start-record-name "$2" \
        --start-record-type NS --max-items 1 --output json \
    | python3 -I -c '
import json, sys
name = sys.argv[1].rstrip(".") + "."
for r in json.load(sys.stdin).get("ResourceRecordSets", []):
    if r["Name"] == name and r["Type"] == "NS":
        print(" ".join(v["Value"] for v in r.get("ResourceRecords", [])))
' "$2"
}

# ensure_zone <name> <true|false> [vpc-id]: create (tagged) unless it exists; echo the ID.
ensure_zone() {
    local name="$1" private="$2" vpc="${3:-}" id
    id="$(zone_id "$name" "$private")"
    if [ -n "$id" ]; then
        zone_is_tagged "$id" || {
            echo "Error: zone ${name} (private=${private}, ${id}) exists but is not tagged ${TAG_KEY}=${TAG_VALUE}." >&2
            echo "       It was not created by this test; refusing to use it. Pick another --label." >&2
            return 1; }
        echo "    reuse   ${name} private=${private} ${id}" >&2
    else
        # The caller reference must be unique per request in the account, including
        # after a zone is deleted, so it carries a timestamp. Reruns find the zone by
        # name, privacy and tag instead.
        local ref
        ref="dnsclash-${CLUSTER_NAME}-${name}-${private}-$(date +%s)"
        local args=(--name "$name" --caller-reference "$ref"
                    --hosted-zone-config "Comment=dns-zone-clash-test ${CLUSTER_NAME},PrivateZone=${private}")
        [ "$private" = "true" ] && args+=(--vpc "VPCRegion=${REGION},VPCId=${vpc}")
        id="$(aws route53 create-hosted-zone "${args[@]}" --query 'HostedZone.Id' --output text | sed 's|.*/||')"
        aws route53 change-tags-for-resource --resource-type hostedzone --resource-id "$id" \
            --add-tags "Key=${TAG_KEY},Value=${TAG_VALUE}" "Key=Cluster,Value=${CLUSTER_NAME}"
        echo "    created ${name} private=${private} ${id}" >&2
    fi
    echo "$id"
}

# --- status -------------------------------------------------------------------
do_status() {
    local base zone
    base="$(detect_base_domain)"; zone="${LABEL}.${base}"
    echo "==> Route 53 test zones under ${base}"
    local name private id
    for spec in "${zone} false" "${zone} true" "api.${zone} false"; do
        read -r name private <<<"$spec"
        id="$(zone_id "$name" "$private")"
        if [ -z "$id" ]; then printf '    %-40s private=%-5s absent\n' "$name" "$private"; continue; fi
        local vpcs; vpcs="$(aws route53 get-hosted-zone --id "$id" --query 'VPCs[].VPCId' --output text 2>/dev/null)"
        printf '    %-40s private=%-5s %s tagged=%s vpcs=%s\n' "$name" "$private" "$id" \
            "$(zone_is_tagged "$id" && echo yes || echo NO)" "${vpcs:-none}"
    done
    echo "==> IAM user"
    if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
        echo "    ${IAM_USER}: present, keys: $(aws iam list-access-keys --user-name "$IAM_USER" \
            --query 'AccessKeyMetadata[].AccessKeyId' --output text)"
    else
        echo "    ${IAM_USER}: absent"
    fi
    echo "==> Cluster (namespace ${NS_TEST})"
    if ! cluster_up; then echo "    cluster API not reachable via ${KUBECONFIG}"; return 0; fi
    "$OC" get gateways.gateway.networking.k8s.io "$GW_NAME" -n "$NS_TEST" \
        -o jsonpath='    Gateway {.metadata.name}: Programmed={.status.conditions[?(@.type=="Programmed")].status} address={.status.addresses[0].value}{"\n"}' 2>/dev/null \
        || echo "    Gateway ${GW_NAME}: absent"
    "$OC" get dnspolicies.kuadrant.io "$POLICY_NAME" -n "$NS_TEST" \
        -o jsonpath='    DNSPolicy {.metadata.name}: Accepted={.status.conditions[?(@.type=="Accepted")].status} Enforced={.status.conditions[?(@.type=="Enforced")].status} {.status.conditions[?(@.type=="Enforced")].message}{"\n"}' 2>/dev/null \
        || echo "    DNSPolicy ${POLICY_NAME}: absent"
    "$OC" get dnsrecords.kuadrant.io -n "$NS_TEST" \
        -o jsonpath='{range .items[*]}    DNSRecord {.metadata.name} rootHost={.spec.rootHost} zone={.status.zoneDomainName} Ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}: {.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>/dev/null \
        || true
}

# --- run ----------------------------------------------------------------------
do_run() {
    local base zone vpc
    base="$(detect_base_domain)"; zone="${LABEL}.${base}"
    vpc="$(stack_output VpcId)"
    [ -n "$vpc" ] && [ "$vpc" != "None" ] || {
        echo "Error: no VpcId output on CloudFormation stack ${VPC_STACK_NAME} in ${REGION}." >&2; return 1; }
    cluster_up || { echo "Error: cluster API not reachable via ${KUBECONFIG}." >&2; return 1; }

    local base_id
    base_id="$(zone_id "$base" false)"
    [ -n "$base_id" ] || { echo "Error: public zone ${base} not found." >&2; return 1; }
    echo "==> Base zone ${base} (${base_id}), VPC ${vpc}"
    echo "    Note: while the test zones exist, BASE_DOMAIN auto-detection for new installs"
    echo "    sees extra public zones. Run teardown when done."

    echo "==> Route 53 zones"
    local pub_id priv_id api_id
    pub_id="$(ensure_zone "$zone" false)"
    priv_id="$(ensure_zone "$zone" true "$vpc")"
    api_id="$(ensure_zone "api.${zone}" false)"
    # shellcheck disable=SC2046
    change_ns "$base_id" UPSERT "$zone" $(zone_ns "$pub_id")
    # shellcheck disable=SC2046
    change_ns "$pub_id" UPSERT "api.${zone}" $(zone_ns "$api_id")
    echo "    delegations: ${zone} in ${base}; api.${zone} in public ${zone}"

    echo "==> IAM user ${IAM_USER}"
    if ! aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
        aws iam create-user --user-name "$IAM_USER" \
            --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" "Key=Cluster,Value=${CLUSTER_NAME}" >/dev/null
        echo "    created"
    else
        [ "$(aws iam list-user-tags --user-name "$IAM_USER" \
            --query "Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text)" = "$TAG_VALUE" ] || {
            echo "Error: IAM user ${IAM_USER} exists without tag ${TAG_KEY}=${TAG_VALUE}; refusing to use it." >&2
            return 1; }
        echo "    reuse"
    fi
    # Changes only on the three test zones. Listing zones cannot be resource-scoped,
    # and that is the point: dns-operator sees every zone, including the private one.
    local policy
    policy="$(python3 -I -c '
import json, sys
zones = ["arn:aws:route53:::hostedzone/" + z for z in sys.argv[1:]]
print(json.dumps({"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": ["route53:ChangeResourceRecordSets",
     "route53:ListResourceRecordSets", "route53:GetHostedZone"], "Resource": zones},
  {"Effect": "Allow", "Action": ["route53:GetChange"], "Resource": "arn:aws:route53:::change/*"},
  {"Effect": "Allow", "Action": ["route53:ListHostedZones", "route53:ListHostedZonesByName",
     "route53:GetHostedZoneCount", "route53:ListTagsForResource"], "Resource": "*"}]}))
' "$pub_id" "$priv_id" "$api_id")"
    aws iam put-user-policy --user-name "$IAM_USER" --policy-name "$IAM_POLICY" --policy-document "$policy"

    local key_id="" key_secret=""
    if [ -f "$CREDS_FILE" ]; then
        # shellcheck disable=SC1090
        key_id="$( . "$CREDS_FILE"; echo "${AWS_ACCESS_KEY_ID:-}")"
        aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' \
            --output text | tr '\t' '\n' | grep -qx "$key_id" || key_id=""
    fi
    if [ -z "$key_id" ]; then
        local out
        out="$(aws iam create-access-key --user-name "$IAM_USER" \
            --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
        read -r key_id key_secret <<<"$out"
        ( umask 077
          printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_REGION=%s\n' \
              "$key_id" "$key_secret" "$REGION" > "$CREDS_FILE" )
        echo "    new access key ${key_id}, stored in secrets/$(basename "$CREDS_FILE")"
        echo "    (IAM keys take a few seconds to become usable)"
        sleep 10
    else
        echo "    reuse access key ${key_id}"
    fi

    echo "==> Cluster objects in ${NS_TEST}"
    if [ -z "$GATEWAY_CLASS" ]; then
        GATEWAY_CLASS="$("$OC" get gateways.gateway.networking.k8s.io maas-default-gateway -n openshift-ingress \
            -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null || true)"
        [ -n "$GATEWAY_CLASS" ] || GATEWAY_CLASS="$("$OC" get gateways.gateway.networking.k8s.io -A \
            -l kuadrant.io/gateway=true -o jsonpath='{.items[0].spec.gatewayClassName}' 2>/dev/null || true)"
        [ -n "$GATEWAY_CLASS" ] || { echo "Error: could not discover a GatewayClass; pass --gateway-class." >&2; return 1; }
    fi
    echo "    GatewayClass ${GATEWAY_CLASS}"
    "$OC" create namespace "$NS_TEST" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    # From the file, so the key never appears on a command line.
    "$OC" create secret generic "$SECRET_NAME" -n "$NS_TEST" --type=kuadrant.io/aws \
        --from-env-file="$CREDS_FILE" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    "$OC" apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${NS_TEST}
  labels:
    kuadrant.io/gateway: "true"
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
    - name: clash
      hostname: "*.${zone}"
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
    - name: workaround
      hostname: "*.api.${zone}"
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata:
  name: ${POLICY_NAME}
  namespace: ${NS_TEST}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GW_NAME}
  providerRefs:
    - name: ${SECRET_NAME}
EOF
    echo "    applied Secret, Gateway, DNSPolicy"

    echo "==> Waiting up to ${TIMEOUT}s for the Gateway address and both DNSRecords"
    local deadline=$(( $(date +%s) + TIMEOUT )) clash_ready="" work_ready="" n
    until [ "$(date +%s)" -ge "$deadline" ]; do
        n="$("$OC" get dnsrecords.kuadrant.io -n "$NS_TEST" --no-headers 2>/dev/null | wc -l)"
        clash_ready="$(record_field "*.${zone}" '{.status.conditions[?(@.type=="Ready")].status}')"
        work_ready="$(record_field "*.api.${zone}" '{.status.conditions[?(@.type=="Ready")].status}')"
        if [ -n "$clash_ready" ] && [ "$work_ready" = "True" ]; then break; fi
        echo "    $(date +%T) records=${n} clash Ready=${clash_ready:--} workaround Ready=${work_ready:--}"
        sleep 20
    done

    "$OC" get dnsrecords.kuadrant.io -n "$NS_TEST" -o yaml > "$EVIDENCE" 2>/dev/null || true
    echo "==> Result (DNSRecord YAML: logs/$(basename "$EVIDENCE"))"
    local clash_msg work_zone ok=1
    clash_msg="$(record_field "*.${zone}" '{.status.conditions[?(@.type=="Ready")].reason}: {.status.conditions[?(@.type=="Ready")].message}')"
    work_zone="$(record_field "*.api.${zone}" '{.status.zoneDomainName}')"
    echo "    *.${zone}: Ready=${clash_ready:-none} ${clash_msg}"
    echo "    *.api.${zone}: Ready=${work_ready:-none} zone=${work_zone:-none}"

    if [ "$clash_ready" = "False" ] && grep -qi "multiple zones found" <<<"$clash_msg"; then
        echo "    PASS clash: the same-name public and private zones make zone selection fail"
    else
        echo "    FAIL clash: expected Ready=False with 'multiple zones found for host'" >&2; ok=0
    fi
    if [ "$work_ready" = "True" ] && [ "${work_zone%.}" = "api.${zone}" ]; then
        echo "    PASS workaround: the unique api.${zone} zone was chosen"
    else
        echo "    FAIL workaround: expected Ready=True in zone api.${zone}" >&2; ok=0
    fi

    echo "==> Records dns-operator wrote in api.${zone}"
    aws route53 list-resource-record-sets --hosted-zone-id "$api_id" \
        --query "ResourceRecordSets[?Type!='NS' && Type!='SOA'].[Name,Type,TTL]" --output text | sed 's/^/    /'
    if command -v dig >/dev/null; then
        local ns1; ns1="$(zone_ns "$api_id" | awk '{print $1}')"
        echo "    dig @${ns1} probe.api.${zone}: $(dig +short "@${ns1}" "probe.api.${zone}" | tr '\n' ' ')"
    fi

    [ "$ok" -eq 1 ] || return 1
    echo "==> Both expectations hold. Run 'scripts/dns-zone-clash-test.sh teardown' when done."
}

# record_field <rootHost> <jsonpath-body>: a field of the DNSRecord for that root host.
record_field() {
    local name
    name="$("$OC" get dnsrecords.kuadrant.io -n "$NS_TEST" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.rootHost}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' -v h="$1" '$2 == h {print $1; exit}')"
    [ -n "$name" ] || return 0
    "$OC" get dnsrecords.kuadrant.io "$name" -n "$NS_TEST" -o jsonpath="$2" 2>/dev/null || true
}

# --- teardown -----------------------------------------------------------------
# delete_records_except_apex <zone-id> <zone-name>: delete every record set except
# the apex NS and SOA, so the zone can be deleted.
delete_records_except_apex() {
    local batch
    batch="$(aws route53 list-resource-record-sets --hosted-zone-id "$1" --output json \
    | python3 -I -c '
import json, sys
apex = sys.argv[1].rstrip(".") + "."
changes = [{"Action": "DELETE", "ResourceRecordSet": r}
           for r in json.load(sys.stdin)["ResourceRecordSets"]
           if not (r["Name"] == apex and r["Type"] in ("NS", "SOA"))]
print(json.dumps({"Changes": changes}) if changes else "")
' "$2")"
    [ -z "$batch" ] && return 0
    aws route53 change-resource-record-sets --hosted-zone-id "$1" --change-batch "$batch" >/dev/null
    echo "    cleared records in $2 ($1)"
}

do_teardown() {
    local base zone
    base="$(detect_base_domain)"; zone="${LABEL}.${base}"

    echo "==> Cluster objects"
    if cluster_up; then
        "$OC" delete dnspolicies.kuadrant.io "$POLICY_NAME" -n "$NS_TEST" --ignore-not-found --wait=false >/dev/null
        "$OC" delete gateways.gateway.networking.k8s.io "$GW_NAME" -n "$NS_TEST" --ignore-not-found --wait=false >/dev/null
        local deadline=$(( $(date +%s) + 300 ))
        while [ "$("$OC" get dnsrecords.kuadrant.io -n "$NS_TEST" --no-headers 2>/dev/null | wc -l)" -gt 0 ] \
              && [ "$(date +%s)" -lt "$deadline" ]; do
            echo "    waiting for dns-operator to remove its DNSRecords"; sleep 10
        done
        "$OC" delete namespace "$NS_TEST" --ignore-not-found --timeout=180s >/dev/null || \
            echo "    Warning: namespace ${NS_TEST} did not finish deleting; check finalizers." >&2
        echo "    removed DNSPolicy, Gateway and namespace ${NS_TEST}"
    else
        echo "    cluster API not reachable; skipping (records are removed from the zones below)"
    fi

    echo "==> Route 53"
    local base_id pub_id priv_id api_id
    base_id="$(zone_id "$base" false)"
    pub_id="$(zone_id "$zone" false)"; priv_id="$(zone_id "$zone" true)"; api_id="$(zone_id "api.${zone}" false)"
    for id in "$pub_id" "$priv_id" "$api_id"; do
        [ -z "$id" ] && continue
        zone_is_tagged "$id" || { echo "Error: zone ${id} is not tagged ${TAG_KEY}=${TAG_VALUE}; refusing to touch it." >&2; return 1; }
    done

    local ns
    if [ -n "$base_id" ]; then
        ns="$(existing_ns "$base_id" "$zone")"
        # shellcheck disable=SC2086
        [ -n "$ns" ] && change_ns "$base_id" DELETE "$zone" $ns && echo "    removed NS ${zone} from ${base}"
    fi
    if [ -n "$pub_id" ]; then
        ns="$(existing_ns "$pub_id" "api.${zone}")"
        # shellcheck disable=SC2086
        [ -n "$ns" ] && change_ns "$pub_id" DELETE "api.${zone}" $ns && echo "    removed NS api.${zone} from ${zone}"
    fi

    local spec name id
    for spec in "${priv_id}:${zone} (private)" "${api_id}:api.${zone}" "${pub_id}:${zone}"; do
        id="${spec%%:*}"; name="${spec#*:}"
        [ -z "$id" ] && { echo "    ${name}: absent"; continue; }
        delete_records_except_apex "$id" "${name% (private)}"
        aws route53 delete-hosted-zone --id "$id" >/dev/null
        echo "    deleted zone ${name} ${id}"
    done

    echo "==> IAM user ${IAM_USER}"
    if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
        [ "$(aws iam list-user-tags --user-name "$IAM_USER" \
            --query "Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text)" = "$TAG_VALUE" ] || {
            echo "Error: IAM user ${IAM_USER} is not tagged ${TAG_KEY}=${TAG_VALUE}; refusing to delete it." >&2
            return 1; }
        local k
        for k in $(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
            aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"
        done
        aws iam delete-user-policy --user-name "$IAM_USER" --policy-name "$IAM_POLICY" 2>/dev/null || true
        aws iam delete-user --user-name "$IAM_USER"
        echo "    deleted"
    else
        echo "    absent"
    fi
    rm -f "$CREDS_FILE"
    echo "==> Teardown complete"
}

case "$ACTION" in
    run)      do_run ;;
    status)   do_status ;;
    teardown) do_teardown ;;
esac
