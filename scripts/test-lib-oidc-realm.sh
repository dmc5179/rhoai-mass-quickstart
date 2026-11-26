#!/usr/bin/env bash
# shellcheck shell=bash
# test-lib-oidc-realm.sh - offline self-test for scripts/lib-oidc-realm.sh.
#
# Builds a throwaway ROOT and AUTOSHIFT_DIR under mktemp -d, seeds them with a
# copy of cluster.env, fake secrets/ files in the formats the library reads and
# a fake hub values file with two groups, then sources the library against
# them and asserts on what it renders. The repository's real secrets/
# directory is never read or written: ROOT points into the temp tree before
# cluster.env is sourced, so every secrets/ path the library sees is inside
# the temp tree, and the temp tree is removed on exit.
#
# Usage: scripts/test-lib-oidc-realm.sh
# Prints one PASS/FAIL line per check and exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${SCRIPT_DIR}/lib-oidc-realm.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { # check <name> <command...>; the command's exit status decides
    local name="$1"
    shift
    if "$@"; then ok "$name"; else bad "$name"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/secrets" "${tmp}/autoshift/values/clustersets"
cp "${REPO_ROOT}/cluster.env" "${tmp}/cluster.env"

# --- fake inputs, none of them real secrets ---------------------------------
# Two hub groups; maas-user is a member so the roster-then-union path shows.
cat > "${tmp}/autoshift/values/clustersets/hub.yaml" <<'YAML'
hubClusterSets:
  hub:
    config:
      htpasswdUsers:
        groups:
          - name: platform-admins
            users: [alice, bob]
          - name: platform-viewers
            users: [carol, maas-user]
YAML
# Format _oidc_realm_users_env writes: comment lines, then sorted user=password.
cat > "${tmp}/secrets/cluster-users.env" <<'ENV'
# fake users, not real passwords
alice=fake-alice-password
bob=fake-bob-password
carol=fake-carol-password
ENV
# Format _oidc_realm_maas_env writes: quoted MAAS_USER_* variables.
cat > "${tmp}/secrets/maas-user.env" <<'ENV'
# fake, quoted as maas-user.sh writes it
MAAS_USER="maas-user"
MAAS_USER_PASSWORD="fake-maas-password"
MAAS_USER_HTPASSWD_SECRET="htpasswd-users"
ENV
# The Keycloak install leaves the client secrets here, quoted.
cat > "${tmp}/secrets/keycloak-oidc.env" <<'ENV'
# fake client secrets
CONSOLE_CLIENT_SECRET="fake-console-secret"
GATEWAY_CLIENT_SECRET="fake-gateway-secret"
DEVSPACES_CLIENT_SECRET="fake-devspaces-secret"
ENV

# The library reads ROOT and AUTOSHIFT_DIR inside its functions, so both are
# exported for the sourced code.
export ROOT="${tmp}"
# Both sourced from the temp tree: cluster.env is the copy made above, and
# every secrets/ path it or the library builds lands under ${ROOT}.
# shellcheck source=../cluster.env
source "${tmp}/cluster.env"
# shellcheck source=lib-oidc-realm.sh
source "${LIB}"
export AUTOSHIFT_DIR="${tmp}"

# --- render the realm with example hosts ------------------------------------
cr_json=""
if ! cr_json="$(oidc_realm_import console.example.test gateway.example.test devspaces.example.test)"; then
    bad "oidc_realm_import rendered the KeycloakRealmImport"
    echo "the library failed to render; aborting" >&2
    exit 1
fi
ok "oidc_realm_import rendered the KeycloakRealmImport"

# --- assert on the rendered CR ----------------------------------------------
# Every check prints its own PASS/FAIL line and the block exits non-zero if
# any failed. Details name variables, never fake secret values.
set +e
py_out="$(CR_JSON="$cr_json" \
    CLI_PORTS_EXPECT="$OIDC_CLI_CALLBACK_PORTS" \
    C_CONSOLE="$OIDC_CLIENT_CONSOLE" C_CLI="$OIDC_CLIENT_CLI" \
    C_GW="$OIDC_CLIENT_GATEWAY" C_DS="$OIDC_CLIENT_DEVSPACES" \
    F_CONSOLE="fake-console-secret" F_GW="fake-gateway-secret" F_DS="fake-devspaces-secret" \
    F_PW_ALICE="fake-alice-password" F_PW_BOB="fake-bob-password" \
    F_PW_CAROL="fake-carol-password" F_PW_MAAS="fake-maas-password" \
    python3 -I - <<'PY'
import json, os, sys

cr = json.loads(os.environ["CR_JSON"])
e = os.environ
realm = cr["spec"]["realm"]
results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))

clients = realm["clients"]
cli = next(c for c in clients if c["clientId"] == e["C_CLI"])
expect_uris = set()
for p in e["CLI_PORTS_EXPECT"].split():
    expect_uris |= {f"http://localhost:{p}", f"http://localhost:{p}/*"}
check("kind is KeycloakRealmImport", cr["kind"] == "KeycloakRealmImport")
check("4 clients", len(clients) == 4, f"got {len(clients)}")
check(f"{e['C_CLI']} is public with the callback ports and their /* paths",
      cli.get("publicClient") is True and set(cli["redirectUris"]) == expect_uris,
      f"redirectUris {sorted(cli['redirectUris'])}")

all_ids = sorted([e["C_CONSOLE"], e["C_CLI"], e["C_GW"], e["C_DS"]])
for c in clients:
    auds = sorted(m["config"]["included.client.audience"] for m in c["protocolMappers"]
                  if m["protocolMapper"] == "oidc-audience-mapper")
    grp = [m for m in c["protocolMappers"] if m["protocolMapper"] == "oidc-group-membership-mapper"]
    check(f"client {c['clientId']} has 4 audience mappers covering all clients", auds == all_ids,
          f"audiences {auds}")
    check(f"client {c['clientId']} has the groups mapper", len(grp) == 1)

users = {u["username"] for u in realm["users"]}
check("users are the fake users plus maas-user",
      users == {"alice", "bob", "carol", "maas-user"}, f"users {sorted(users)}")
groups = {g["name"] for g in realm["groups"]}
check("groups match the fake hub values",
      groups == {"platform-admins", "platform-viewers"}, f"groups {sorted(groups)}")
membership = {"alice": ["/platform-admins"], "bob": ["/platform-admins"],
              "carol": ["/platform-viewers"], "maas-user": ["/platform-viewers"]}
for u in realm["users"]:
    check(f"user {u['username']} is a member of exactly its hub groups",
          u["groups"] == membership[u["username"]], f"groups {u['groups']}")

leaked = [k for k in ("F_CONSOLE", "F_GW", "F_DS", "F_PW_ALICE", "F_PW_BOB", "F_PW_CAROL", "F_PW_MAAS")
          if e[k] in json.dumps(cr)]
check("no fake secret value appears in the rendered CR", not leaked,
      "leaked: " + ", ".join(leaked))

# Placeholder keys are derived from user names (maas-user -> KC_PW_maas_user); the
# Secret that oidc_realm_secret_env builds must use exactly the same keys.
expect_ph = {"CONSOLE_CLIENT_SECRET", "GATEWAY_CLIENT_SECRET", "DEVSPACES_CLIENT_SECRET",
             "KC_PW_alice", "KC_PW_bob", "KC_PW_carol", "KC_PW_maas_user"}
check("placeholders cover the client secrets and every user password",
      set(cr["spec"]["placeholders"]) == expect_ph,
      f"placeholders {sorted(cr['spec']['placeholders'])}")

for name, good, detail in results:
    line = ("PASS" if good else "FAIL") + ": " + name
    if detail and not good:
        line += " - " + detail
    print(line)
sys.exit(0 if all(r[1] for r in results) else 1)
PY
)"
py_rc=$?
set -e
saw_fail=0
while read -r line; do
    case "$line" in
        PASS:*) ok "${line#PASS: }" ;;
        FAIL:*) saw_fail=1; bad "${line#FAIL: }" ;;
    esac
done <<< "$py_out"
if [ "$py_rc" -ne 0 ] && [ "$saw_fail" -eq 0 ]; then
    bad "the JSON assertion block failed without printing a check (exit $py_rc)"
fi

# --- oidc_realm_secret_env prints the expected key names ---------------------
# Values are captured and never printed; only the key names are compared. They must
# be the CR's placeholder keys, or Keycloak imports users without their passwords.
sec_out="$(oidc_realm_secret_env 2>/dev/null)" || true
got_keys="$(sed 's/=.*//' <<<"$sec_out" | LC_ALL=C sort)"
want_keys="$(printf '%s\n' CONSOLE_CLIENT_SECRET DEVSPACES_CLIENT_SECRET GATEWAY_CLIENT_SECRET \
    KC_PW_alice KC_PW_bob KC_PW_carol KC_PW_maas_user | LC_ALL=C sort)"
check "oidc_realm_secret_env prints the expected key names" [ "$got_keys" = "$want_keys" ]

# --- missing user env files are generated, mode 600, inside the temp ROOT ----
root2="${tmp}/root2"
mkdir -p "${root2}/secrets"
cp "${tmp}/secrets/keycloak-oidc.env" "${root2}/secrets/"
export ROOT="${root2}"
gen_out="$(oidc_realm_secret_env 2>/dev/null)" || true
check "generated cluster-users.env inside the temp ROOT" [ -f "${root2}/secrets/cluster-users.env" ]
check "generated maas-user.env inside the temp ROOT" [ -f "${root2}/secrets/maas-user.env" ]
check "generated cluster-users.env has mode 600" [ "$(stat -c %a "${root2}/secrets/cluster-users.env")" = 600 ]
check "generated maas-user.env has mode 600" [ "$(stat -c %a "${root2}/secrets/maas-user.env")" = 600 ]
gen_users="$(sed -n '/^#/d; s/=.*//p' "${root2}/secrets/cluster-users.env" | LC_ALL=C sort | tr '\n' ' ')"
check "the generated roster is the hub members without maas-user" [ "$gen_users" = "alice bob carol " ]
check "the generated maas env holds MAAS_USER_PASSWORD" \
    grep -q '^MAAS_USER_PASSWORD=' "${root2}/secrets/maas-user.env"
check "the generated files still satisfy oidc_realm_secret_env" \
    [ "$(sed 's/=.*//' <<<"$gen_out" | LC_ALL=C sort)" = "$want_keys" ]

# --- summary -----------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
