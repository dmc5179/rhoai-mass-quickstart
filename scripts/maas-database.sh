#!/usr/bin/env bash
#
# maas-database.sh - provision the PostgreSQL database that RHOAI MaaS requires,
#                    as an AWS RDS instance, and wire the cluster to it.
#
# Usage: scripts/maas-database.sh create  [options]
#        scripts/maas-database.sh status
#        scripts/maas-database.sh secret            # re-create the k8s Secret only
#        scripts/maas-database.sh destroy [--yes]
#
# Options for create:
#   --ha                    Multi-AZ. A synchronous standby in a second zone with
#                           automatic failover. Roughly doubles the cost.
#   --instance-class <c>    Default: db.t4g.small
#   --storage <gb>          Default: 20
#   --engine-version <v>    Default: whatever AWS considers current for postgres
#   --name <id>             Default: <CLUSTER_NAME>-maas
#   --db-name <n>           Default: maas
#   --username <u>          Default: maas
#   --no-secret             Provision only; do not touch the cluster
#   --yes                   Skip the confirmation prompt
#
# Why RDS rather than an in-cluster database. maas-api will not start without
# PostgreSQL:
#
#   error: failed to load database URL: failed to read secret
#   redhat-ai-gateway-infra/maas-db-config: secrets "maas-db-config" not found
#
# The pod CrashLoopBackOffs, and the gateway answers *authenticated* requests
# with "no healthy upstream" — so it presents as a gateway fault rather than a
# missing dependency. This is a hard requirement, not an optional add-on.
#
# Running the database inside the cluster it serves means its backups, failover
# and upgrades become the cluster's problem. For a disconnected or on-premise
# install that is unavoidable, and the crunchy-postgres-operator is the answer
# there. On AWS a managed instance is better, and nothing has to be mirrored.
#
# The credential never enters Git. It is written to secrets/ (ignored) and put
# straight into a Kubernetes Secret, which is the same out-of-band pattern the
# Lightspeed API key uses.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

case "${1:-}" in
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
ACTION="${1:-}"; shift || true

HA=0
INSTANCE_CLASS="db.t4g.small"
STORAGE_GB=20
ENGINE_VERSION=""
DB_ID=""
DB_NAME="maas"
DB_USER="maas"
MAKE_SECRET=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ha)             HA=1; shift ;;
        --instance-class) INSTANCE_CLASS="$2"; shift 2 ;;
        --storage)        STORAGE_GB="$2"; shift 2 ;;
        --engine-version) ENGINE_VERSION="$2"; shift 2 ;;
        --name)           DB_ID="$2"; shift 2 ;;
        --db-name)        DB_NAME="$2"; shift 2 ;;
        --username)       DB_USER="$2"; shift 2 ;;
        --no-secret)      MAKE_SECRET=0; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)        sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "maas-database.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    create|status|destroy|secret) ;;
    *) echo "Usage: scripts/maas-database.sh {create|status|secret|destroy} [options]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "maas-database" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

command -v aws >/dev/null || { echo "Error: the 'aws' CLI is not installed." >&2; exit 1; }
[ "$PLATFORM" = "aws" ] || {
    echo "Error: this script provisions AWS RDS, but PLATFORM is '${PLATFORM}'." >&2
    echo "       On another platform use a managed database from that provider, or" >&2
    echo "       the crunchy-postgres-operator in-cluster." >&2
    exit 1
}

DB_ID="${DB_ID:-${CLUSTER_NAME}-maas}"
REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set (see secrets/aws.env)}"
SG_NAME="${DB_ID}-sg"
SUBNET_GROUP="${DB_ID}-subnets"
CREDS_FILE="${ROOT}/secrets/maas-db.env"
MAAS_NS="redhat-ai-gateway-infra"
SECRET_NAME="maas-db-config"

stack_output() {
    aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

db_field() {
    aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
        --query "DBInstances[0].$1" --output text 2>/dev/null
}

db_exists() { aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; }

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    if ! db_exists; then
        echo "No RDS instance named '${DB_ID}' in ${REGION}."
        exit 0
    fi
    printf '  %-14s %s\n' \
        identifier "$DB_ID" \
        status     "$(db_field DBInstanceStatus)" \
        engine     "$(db_field EngineVersion)" \
        class      "$(db_field DBInstanceClass)" \
        multi-az   "$(db_field MultiAZ)" \
        storage    "$(db_field AllocatedStorage)GiB" \
        endpoint   "$(db_field Endpoint.Address):$(db_field Endpoint.Port)"
    echo
    echo "  Cluster Secret:"
    if KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig" "$OC" get secret "$SECRET_NAME" -n "$MAAS_NS" >/dev/null 2>&1; then
        echo "    ${MAAS_NS}/${SECRET_NAME} exists"
    else
        echo "    ${MAAS_NS}/${SECRET_NAME} MISSING — run: scripts/maas-database.sh secret"
    fi
    exit 0
fi

# --- destroy ----------------------------------------------------------------
if [ "$ACTION" = "destroy" ]; then
    db_exists || { echo "No RDS instance named '${DB_ID}'."; exit 0; }
    if [ "$ASSUME_YES" -eq 0 ]; then
        echo "About to DELETE RDS instance '${DB_ID}' and every backup of it."
        printf "Type the instance name to confirm: "
        read -r reply
        [ "$reply" = "$DB_ID" ] || { echo "Not confirmed; nothing deleted."; exit 1; }
    fi
    echo "==> Deleting ${DB_ID} (no final snapshot)"
    aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
        --skip-final-snapshot --delete-automated-backups >/dev/null
    echo "    Waiting for deletion"
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" || true
    aws rds delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" 2>/dev/null || true
    sg="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
          --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
    [ -n "$sg" ] && [ "$sg" != "None" ] && aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
    echo "    Done. secrets/maas-db.env and the cluster Secret are left alone."
    exit 0
fi

# --- secret -----------------------------------------------------------------
write_secret() {
    local url="$1"
    KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
    export KUBECONFIG
    "$OC" get --raw /readyz >/dev/null 2>&1 || {
        echo "Error: cluster API not reachable; cannot create the Secret." >&2
        echo "       The database is provisioned. Re-run: scripts/maas-database.sh secret" >&2
        return 1
    }
    # The namespace is created by RHOAI. On 3.5 maas-api lives in
    # redhat-ai-gateway-infra; on 3.4 it was redhat-ods-applications.
    "$OC" get namespace "$MAAS_NS" >/dev/null 2>&1 || {
        echo "Error: namespace ${MAAS_NS} does not exist yet." >&2
        echo "       Enable RHOAI MaaS first, then re-run: scripts/maas-database.sh secret" >&2
        return 1
    }
    "$OC" create secret generic "$SECRET_NAME" -n "$MAAS_NS" \
        --from-literal=DB_CONNECTION_URL="$url" \
        --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    echo "==> Secret ${MAAS_NS}/${SECRET_NAME} applied"
}

if [ "$ACTION" = "secret" ]; then
    [ -f "$CREDS_FILE" ] || { echo "Error: ${CREDS_FILE} not found. Run 'create' first." >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$CREDS_FILE"
    write_secret "$MAAS_DB_URL"
    echo "    maas-api picks this up on its next restart:"
    echo "      \"\$OC\" rollout restart deployment/maas-api -n ${MAAS_NS}"
    exit 0
fi

# --- create -----------------------------------------------------------------
if db_exists; then
    echo "RDS instance '${DB_ID}' already exists (status: $(db_field DBInstanceStatus))."
    echo "Use 'status' to inspect it, or 'destroy' to remove it first."
    exit 1
fi

VPC_ID="$(stack_output VpcId)"
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || {
    echo "Error: could not read VpcId from CloudFormation stack '${VPC_STACK_NAME}'." >&2
    exit 1
}
PRIVATE_SUBNET="$(stack_output PrivateSubnetId)"
PRIMARY_AZ="$(stack_output AvailabilityZone)"

# RDS requires a DB subnet group spanning at least two availability zones, even
# for a single-AZ instance. The VPC this project builds is deliberately
# single-AZ, so a second private subnet is created here. 01_vpc.yaml carves its
# CIDRs as if there were three zones and uses only indices 0 and 3, specifically
# so indices 1/2 and 4/5 are free for this.
echo "==> VPC ${VPC_ID} (primary AZ ${PRIMARY_AZ})"
SECOND_AZ="$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[?ZoneName!='${PRIMARY_AZ}'].ZoneName | [0]" --output text)"
[ -n "$SECOND_AZ" ] && [ "$SECOND_AZ" != "None" ] || {
    echo "Error: could not find a second availability zone in ${REGION}." >&2; exit 1; }

DB_SUBNET_2="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${DB_ID}-db-${SECOND_AZ}" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null)"

if [ -z "$DB_SUBNET_2" ] || [ "$DB_SUBNET_2" = "None" ]; then
    VPC_CIDR_ACTUAL="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].CidrBlock' --output text)"
    TAKEN_CIDRS="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'Subnets[].CidrBlock' --output text | tr '\t' ' ')"
    # Derived from the subnets that actually exist, not by replaying the
    # CloudFormation arithmetic. 01_vpc.yaml sizes its subnets from a SubnetBits
    # parameter, so recomputing !Cidr [VpcCidr, 6, SubnetBits] here means
    # guessing that parameter — and guessing wrong yields a plausible CIDR that
    # silently overlaps an existing subnet. Matching the existing prefix length
    # and skipping anything that overlaps is correct for any value of it.
    DB_CIDR="$(VPC_CIDR="$VPC_CIDR_ACTUAL" TAKEN="$TAKEN_CIDRS" python3 -I -c "
import ipaddress, os, sys
vpc = ipaddress.ip_network(os.environ['VPC_CIDR'])
taken = [ipaddress.ip_network(c) for c in os.environ['TAKEN'].split() if c]
if not taken:
    sys.exit('no existing subnets to size against')
prefix = max(n.prefixlen for n in taken)
for cand in vpc.subnets(new_prefix=prefix):
    if not any(cand.overlaps(t) for t in taken):
        print(cand); break
else:
    sys.exit('no free /%d block left in %s' % (prefix, vpc))")"
    [ -n "$DB_CIDR" ] || { echo "Error: no free subnet block in the VPC." >&2; exit 1; }
    echo "==> Creating a second private subnet ${DB_CIDR} in ${SECOND_AZ}"
    echo "    RDS needs a subnet group across two zones; this VPC is single-AZ by design."
    DB_SUBNET_2="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$DB_CIDR" \
        --availability-zone "$SECOND_AZ" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${DB_ID}-db-${SECOND_AZ}}]" \
        --query 'Subnet.SubnetId' --output text)"
else
    echo "==> Reusing database subnet ${DB_SUBNET_2} in ${SECOND_AZ}"
fi

if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP" >/dev/null 2>&1; then
    echo "==> Creating DB subnet group ${SUBNET_GROUP}"
    aws rds create-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" \
        --db-subnet-group-description "RHOAI MaaS database for ${CLUSTER_NAME}" \
        --subnet-ids "$PRIVATE_SUBNET" "$DB_SUBNET_2" >/dev/null
fi

SG_ID="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    echo "==> Creating security group ${SG_NAME}"
    SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
        --description "PostgreSQL from inside the VPC, for RHOAI MaaS" \
        --query 'GroupId' --output text)"
    # Scoped to the VPC CIDR, not 0.0.0.0/0. The database has no public address
    # and nothing outside the cluster network needs to reach it.
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 5432 \
        --cidr "$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)" \
        >/dev/null
fi

DB_PASS="$(python3 -I -c "
import secrets,string
# RDS rejects / @ \" and space in a master password.
alphabet = string.ascii_letters + string.digits + '-_.!*+'
print(''.join(secrets.choice(alphabet) for _ in range(32)))")"

cat <<EOF

About to create an RDS instance. This costs money until destroyed.

    identifier   ${DB_ID}
    class        ${INSTANCE_CLASS}
    storage      ${STORAGE_GB} GiB (gp3, encrypted)
    multi-AZ     $([ "$HA" -eq 1 ] && echo 'yes - standby in a second zone, automatic failover' || echo 'no - single instance')
    region       ${REGION}
    network      private subnets only, no public address
EOF
if [ "$ASSUME_YES" -eq 0 ]; then
    printf "Proceed? [y/N] "
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "Nothing created."; exit 1 ;; esac
fi

echo "==> Creating RDS instance ${DB_ID}"
create_args=(
    --db-instance-identifier "$DB_ID"
    --db-instance-class "$INSTANCE_CLASS"
    --engine postgres
    --allocated-storage "$STORAGE_GB"
    --storage-type gp3
    --storage-encrypted
    --master-username "$DB_USER"
    --master-user-password "$DB_PASS"
    --db-name "$DB_NAME"
    --db-subnet-group-name "$SUBNET_GROUP"
    --vpc-security-group-ids "$SG_ID"
    --no-publicly-accessible
    --backup-retention-period 7
    --copy-tags-to-snapshot
    --tags "Key=Name,Value=${DB_ID}" "Key=cluster,Value=${CLUSTER_NAME}" "Key=purpose,Value=rhoai-maas"
)
[ -n "$ENGINE_VERSION" ] && create_args+=(--engine-version "$ENGINE_VERSION")
[ "$HA" -eq 1 ] && create_args+=(--multi-az) || create_args+=(--no-multi-az)

aws rds create-db-instance "${create_args[@]}" >/dev/null

echo "    Waiting for the instance to become available (typically 5-10 minutes)"
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"

ENDPOINT="$(db_field Endpoint.Address)"
PORT="$(db_field Endpoint.Port)"
DB_URL="postgresql://${DB_USER}:${DB_PASS}@${ENDPOINT}:${PORT}/${DB_NAME}"

# secrets/ is gitignored wholesale. The password exists in exactly two places:
# this file and the cluster Secret.
umask 077
cat > "$CREDS_FILE" <<EOF
# Generated by scripts/maas-database.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# NOT in git. secrets/ is ignored except for the .example templates.
MAAS_DB_IDENTIFIER="${DB_ID}"
MAAS_DB_HOST="${ENDPOINT}"
MAAS_DB_PORT="${PORT}"
MAAS_DB_NAME="${DB_NAME}"
MAAS_DB_USER="${DB_USER}"
MAAS_DB_PASSWORD="${DB_PASS}"
MAAS_DB_URL="${DB_URL}"
EOF
echo "==> Wrote ${CREDS_FILE} (mode 0600)"

if [ "$MAKE_SECRET" -eq 1 ]; then
    write_secret "$DB_URL" || true
fi

cat <<EOF

Database ready at ${ENDPOINT}:${PORT}

maas-api reads the Secret once at startup, so restart it to pick this up:

    "\$OC" rollout restart deployment/maas-api -n ${MAAS_NS}

Then check the authenticated path end to end:

    scripts/35-smoke-test.sh

To tear it down and stop the charge:

    scripts/maas-database.sh destroy
EOF
