#!/usr/bin/env bash
#
# ogx-database.sh - OGX's metadata database: a database and a login role on the
#                   MaaS RDS instance, wired to the cluster.
#
# Usage: scripts/ogx-database.sh create  [--dry-run] [--yes]
#        scripts/ogx-database.sh status
#        scripts/ogx-database.sh secret            # Secret ogx-postgres from stdin
#        scripts/ogx-database.sh drop    [--dry-run] --yes
#
# Why it reuses the MaaS RDS instance. OGX (OpenShift AI 3.5.2) needs PostgreSQL
# for its metadata store, and the cluster already carries one: the instance that
# scripts/maas-database.sh created for MaaS. It is already PostgreSQL, it is
# already reachable from the cluster (its security group admits 5432 from the
# VPC CIDR and it has no public address), and scripts/cluster-power.sh already
# stops it and starts it with the cluster. A second instance would double the
# database bill and add a second thing to park. No AWS API call is made here:
# the endpoint and the master credentials come from secrets/maas-db.env.
#
# Isolation. OGX gets its own database (ogx) owned by its own login role (ogx),
# and runs its own schema migrations in it. Nothing is shared with the MaaS
# schema, and OGX never holds MaaS credentials: the master user authenticates
# the bootstrap pod, the ogx role is what OGX itself connects as.
#
# Coupling to MaaS. scripts/maas-database.sh destroy deletes the instance and
# therefore OGX's database with it. After a re-provision, re-run this script's
# create (and secret) to rebuild the role and the empty database; OGX re-runs
# its migrations on first start.
#
# The password never enters Git (secrets/ogx-db.env, mode 0600) and never sits
# on a command line: the bootstrap pod receives the master password through a
# temporary Secret as PGPASSWORD, and the ogx password travels in the SQL text
# on stdin.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

case "${1:-}" in
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
ACTION="${1:-}"; shift || true

case "$ACTION" in
    create|status|secret|drop) ;;
    *) echo "Usage: scripts/ogx-database.sh {create|status|secret|drop} [--dry-run] [--yes]" >&2; exit 2 ;;
esac

DRY_RUN=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes)     ASSUME_YES=1; shift ;;
        *) echo "ogx-database.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "ogx-database" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

MASTER_CREDS="${ROOT}/secrets/maas-db.env"
OGX_CREDS="${ROOT}/secrets/ogx-db.env"
OGX_DB_NAME="ogx"
OGX_DB_USER="ogx"
# The same pinned image family scripts/keycloak-oidc.sh uses for its test
# database (KEYCLOAK_DB_IMAGE); it carries the psql client.
OGX_DB_IMAGE="${OGX_DB_IMAGE:-registry.redhat.io/rhel9/postgresql-16:1-1795335911}"
# Where the OGXServer is deployed, per agent-identity-manual/vars.env.example
# (OGX_NAMESPACE=agents) and its 10-ogx.yaml.
OGX_NAMESPACE="${OGX_NAMESPACE:-agents}"
BOOTSTRAP_POD="ogx-db-bootstrap"
BOOTSTRAP_SECRET="ogx-db-bootstrap"

[ -f "$MASTER_CREDS" ] || {
    echo "Error: ${MASTER_CREDS} not found. The MaaS RDS instance does not exist yet." >&2
    echo "       Run: scripts/maas-database.sh create" >&2
    exit 1
}
# Host, port, master user, master password. Values are never echoed.
# shellcheck disable=SC1090
. "$MASTER_CREDS"
: "${MAAS_DB_HOST:?maas-db.env has no MAAS_DB_HOST}" "${MAAS_DB_PORT:?maas-db.env has no MAAS_DB_PORT}"
: "${MAAS_DB_USER:?maas-db.env has no MAAS_DB_USER}" "${MAAS_DB_PASSWORD:?maas-db.env has no MAAS_DB_PASSWORD}"

# The bootstrap pod runs psql against the instance, so the cluster must be up.
# Everything else in this script is local or talks to the database directly.
cluster_ready() {
    KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
    export KUBECONFIG
    "$OC" get --raw /readyz >/dev/null 2>&1
}

gen_password() {
    # Same alphabet maas-database.sh uses: RDS-side quoting is not the issue
    # here, but the password is inlined in single-quoted SQL, so no quotes and
    # no backslashes.
    python3 -I -c "
import secrets,string
alphabet = string.ascii_letters + string.digits + '-_.!*+'
print(''.join(secrets.choice(alphabet) for _ in range(32)))"
}

# run_psql_pod <sql-text> — runs the SQL in a short-lived pod that connects to
# the instance as the master user with sslmode=require. The SQL and the master
# credentials travel in the temporary Secret (never on a command line, and not on
# stdin: oc run -i can drop input sent before it attaches, after which psql runs
# nothing and still exits 0). The pod is removed with --rm; the Secret by the
# caller's trap. Returns psql's exit status.
run_psql_pod() {
    local sql="$1"
    "$OC" delete pod "$BOOTSTRAP_POD" -n default --ignore-not-found --wait=true >/dev/null
    # The password and the SQL (which carries the ogx password) come in on file
    # descriptors 4 and 3; host, port and user are not secret.
    "$OC" create secret generic "$BOOTSTRAP_SECRET" -n default \
        --from-file=PGPASSWORD=/dev/fd/4 --from-file=OGX_SQL=/dev/fd/3 \
        --from-literal=MAAS_DB_HOST="$MAAS_DB_HOST" --from-literal=MAAS_DB_PORT="$MAAS_DB_PORT" \
        --from-literal=MAAS_DB_USER="$MAAS_DB_USER" --dry-run=client -o yaml \
        3<<<"$sql" 4< <(printf '%s' "$MAAS_DB_PASSWORD") \
        | "$OC" apply -f - >/dev/null
    local overrides
    # The command goes in the overrides: an overrides container replaces the whole
    # container, so oc run's own --command arguments would be dropped and the image's
    # entrypoint (the PostgreSQL server) would run instead.
    local cmd='printf "%s\n" "$OGX_SQL" | psql "sslmode=require host=${MAAS_DB_HOST} port=${MAAS_DB_PORT} user=${MAAS_DB_USER} dbname=postgres" -v ON_ERROR_STOP=1 -X -f -'
    overrides="$(jq -n --arg img "$OGX_DB_IMAGE" --arg s "$BOOTSTRAP_SECRET" --arg c "$cmd" \
        '{spec:{restartPolicy:"Never",containers:[{name:"psql",image:$img,
          command:["/bin/bash","-c",$c], envFrom:[{secretRef:{name:$s}}]}]}}')"
    "$OC" run "$BOOTSTRAP_POD" -n default --rm --attach --quiet --restart=Never \
        --image="$OGX_DB_IMAGE" --overrides="$overrides" </dev/null
}

cleanup_bootstrap() {
    "$OC" delete secret "$BOOTSTRAP_SECRET" -n default --ignore-not-found >/dev/null 2>&1 || true
    "$OC" delete pod "$BOOTSTRAP_POD" -n default --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# create_sql <password> — the idempotent bootstrap SQL. The password is inlined
# in single quotes; the alphabet above rules out quotes and backslashes.
create_sql() {
    cat <<SQL
DO \$do\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${OGX_DB_USER}') THEN
        CREATE ROLE ${OGX_DB_USER} LOGIN;
    END IF;
END \$do\$;
ALTER ROLE ${OGX_DB_USER} LOGIN PASSWORD '$1';
-- PostgreSQL 16: CREATE DATABASE ... OWNER needs the creator to be able to SET ROLE
-- to the owner, and the RDS master user is not a true superuser. Membership gives it.
GRANT ${OGX_DB_USER} TO CURRENT_USER;
SELECT 'CREATE DATABASE ${OGX_DB_NAME} OWNER ${OGX_DB_USER}' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = '${OGX_DB_NAME}')\gexec
-- Revoking CONNECT on the maas database from PUBLIC is safe for MaaS:
-- maas-api authenticates as the master user, which keeps its access regardless
-- of PUBLIC grants, and the only other login role on the instance is ogx, which
-- owns its own database and has no business opening the MaaS one. Gated on the
-- database existing, so a renamed MaaS database does not fail the run.
SELECT 'REVOKE CONNECT ON DATABASE maas FROM PUBLIC' WHERE EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = 'maas')\gexec
SQL
}

drop_sql() {
    cat <<SQL
SELECT 'DROP DATABASE ${OGX_DB_NAME} WITH (FORCE)' WHERE EXISTS (SELECT FROM pg_catalog.pg_database WHERE datname = '${OGX_DB_NAME}')\gexec
SELECT 'DROP ROLE ${OGX_DB_USER}' WHERE EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${OGX_DB_USER}')\gexec
SQL
}

status_sql() {
    cat <<SQL
SELECT 'role ' || rolname FROM pg_catalog.pg_roles WHERE rolname = '${OGX_DB_USER}';
SELECT 'database ' || datname FROM pg_catalog.pg_database WHERE datname = '${OGX_DB_NAME}';
SQL
}

mask_sql() { sed "s/PASSWORD '[^']*'/PASSWORD '********'/g"; }

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    cluster_ready || { echo "Error: cluster API not reachable; status needs a pod to query the instance." >&2; exit 1; }
    trap cleanup_bootstrap EXIT
    out="$(run_psql_pod "$(status_sql)")" || true
    trap - EXIT
    cleanup_bootstrap
    grep -q "^ *role ${OGX_DB_USER} *$" <<<"$out" && r="present" || r="absent"
    grep -q "^ *database ${OGX_DB_NAME} *$" <<<"$out" && d="present" || d="absent"
    echo "role ${OGX_DB_USER}: ${r}"
    echo "database ${OGX_DB_NAME}: ${d}"
    [ "$r" = "present" ] && [ "$d" = "present" ] || {
        echo "Run: scripts/ogx-database.sh create"
    }
    exit 0
fi

# --- secret -----------------------------------------------------------------
if [ "$ACTION" = "secret" ]; then
    cluster_ready || { echo "Error: cluster API not reachable; cannot create the Secret." >&2; exit 1; }
    [ -t 0 ] && {
        echo "Error: pipe the OGX password in on stdin:" >&2
        echo "       scripts/ogx-database.sh secret < ${OGX_CREDS}" >&2
        exit 1
    }
    input="$(cat)"
    ogx_pw="$(sed -n 's/^OGX_DB_PASSWORD=//p' <<<"$input" | head -1 | sed 's/^"//; s/"$//')"
    [ -n "$ogx_pw" ] || ogx_pw="$(head -1 <<<"$input")"
    [ -n "$ogx_pw" ] || { echo "Error: no password on stdin." >&2; exit 1; }
    "$OC" get namespace "$OGX_NAMESPACE" >/dev/null 2>&1 || {
        echo "Error: namespace ${OGX_NAMESPACE} does not exist yet." >&2
        echo "       Create it (agent-identity-manual 10-ogx.yaml) and re-run." >&2
        exit 1
    }
    tmpf="$(mktemp "${TMPDIR:-/tmp}/ogx-db-pw.XXXXXX")"
    umask 077
    printf '%s' "$ogx_pw" > "$tmpf"
    "$OC" create secret generic ogx-postgres -n "$OGX_NAMESPACE" \
        --from-file=password="$tmpf" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    rm -f "$tmpf"
    echo "==> Secret ${OGX_NAMESPACE}/ogx-postgres applied (key password)"
    exit 0
fi

# --- create -----------------------------------------------------------------
if [ "$ACTION" = "create" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "==> [dry-run] plan for scripts/ogx-database.sh create"
        echo "    instance endpoint (from secrets/maas-db.env): ${MAAS_DB_HOST}:${MAAS_DB_PORT}"
        echo "    would generate a password and write ${OGX_CREDS} (mode 0600):"
        echo "        OGX_DB_HOST=${MAAS_DB_HOST}"
        echo "        OGX_DB_PORT=${MAAS_DB_PORT}"
        echo "        OGX_DB_NAME=${OGX_DB_NAME}"
        echo "        OGX_DB_USER=${OGX_DB_USER}"
        echo "        OGX_DB_PASSWORD=<generated>"
        echo "    would run pod default/${BOOTSTRAP_POD} (image ${OGX_DB_IMAGE}),"
        echo "      env from temporary Secret ${BOOTSTRAP_SECRET} (PGPASSWORD, MAAS_DB_HOST/PORT/USER),"
        echo "      psql with sslmode=require, and execute:"
        create_sql "<generated>" | mask_sql | sed 's/^/        /'
        echo "    would delete the pod and the temporary Secret afterwards"
        echo "    would print the next step: scripts/ogx-database.sh secret"
        echo
        echo "    Not exercised by a dry run: whether the RDS instance is up (it is stopped"
        echo "    with the cluster), the TLS handshake to it, the image pull, the cluster"
        echo "    API, and the current role/database state. No AWS API call is made at all."
        exit 0
    fi
    [ -f "$OGX_CREDS" ] && {
        echo "==> ${OGX_CREDS} exists; generating a fresh password and updating the role"
        echo "    Re-run 'scripts/ogx-database.sh secret' afterwards to refresh the cluster Secret."
    }
    cluster_ready || { echo "Error: cluster API not reachable; create runs a bootstrap pod in the cluster." >&2; exit 1; }
    ogx_pw="$(gen_password)"
    sql="$(create_sql "$ogx_pw")"
    trap cleanup_bootstrap EXIT
    if ! psql_out="$(run_psql_pod "$sql" 2>&1)"; then
        echo "Error: the bootstrap SQL failed:" >&2
        sed "s/PASSWORD '[^']*'/PASSWORD '********'/g; s/^/    /" <<<"$psql_out" >&2
        exit 1
    fi
    trap - EXIT
    cleanup_bootstrap
    umask 077
    cat > "$OGX_CREDS" <<EOF
# Generated by scripts/ogx-database.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# NOT in git. secrets/ is ignored except for the .example templates.
OGX_DB_HOST="${MAAS_DB_HOST}"
OGX_DB_PORT="${MAAS_DB_PORT}"
OGX_DB_NAME="${OGX_DB_NAME}"
OGX_DB_USER="${OGX_DB_USER}"
OGX_DB_PASSWORD="${ogx_pw}"
EOF
    echo "==> Role ${OGX_DB_USER} and database ${OGX_DB_NAME} ready on ${MAAS_DB_HOST}:${MAAS_DB_PORT}"
    echo "==> Wrote ${OGX_CREDS} (mode 0600)"
    echo "    Next: scripts/ogx-database.sh secret < ${OGX_CREDS}"
    exit 0
fi

# --- drop -------------------------------------------------------------------
# Without --yes nothing is dropped.
if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    echo "About to DROP database ${OGX_DB_NAME} and role ${OGX_DB_USER} on ${MAAS_DB_HOST}:${MAAS_DB_PORT}."
    echo "Re-run with --yes to confirm."
    exit 1
fi
if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> [dry-run] would run pod default/${BOOTSTRAP_POD} and execute:"
    drop_sql | sed 's/^/        /'
    echo "    would delete the pod and the temporary Secret afterwards"
    exit 0
fi
cluster_ready || { echo "Error: cluster API not reachable; drop runs a bootstrap pod in the cluster." >&2; exit 1; }
sql="$(drop_sql)"
trap cleanup_bootstrap EXIT
run_psql_pod "$sql" >/dev/null
trap - EXIT
cleanup_bootstrap
echo "==> Database ${OGX_DB_NAME} and role ${OGX_DB_USER} dropped (files left alone: ${OGX_CREDS})"
