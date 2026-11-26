# shellcheck shell=bash
# lib-keycloak.sh - manage users and groups in the lab's Keycloak realm.
#
# On a cluster that uses external OIDC (scripts/lib-oc-token.sh: cluster_is_oidc),
# users and groups live in the Keycloak realm, not in OpenShift. These helpers run
# kcadm inside the Keycloak pod as the bootstrap admin, so they need nothing but the
# installer kubeconfig:
#
#   - The admin credentials come from the Secret the operator generated
#     (rhbk-initial-admin in the Keycloak namespace).
#   - The kcadm script and every secret value go to `oc exec -i ... bash -s` on
#     stdin, never on a command line and never to stdout (which lib-logging tees
#     into logs/). kcadm reads the admin password from KC_CLI_PASSWORD, and a
#     user's password goes to the reset-password endpoint through `-f -`.
#
# Requires: OC and KUBECONFIG set. Override the names below by setting them first.
#
#   kc_user_id <user>                     realm user ID, empty if absent
#   kc_user_ensure <user> <pw> <group>... create or update the user (enabled, email
#                                         verified, no required actions), set the
#                                         password if <pw> is non-empty, add it to
#                                         each group (created if missing). Prints
#                                         "created" or "updated". Additive: never
#                                         removes a group membership.
#   kc_users_groups                       one line per realm user: name, enabled,
#                                         comma-separated groups (tab-separated)
#   kc_user_delete <user>                 delete the user (and so its memberships)
#   kc_group_delete <group>               delete the group if it exists

KC_NS="${KC_NS:-${KEYCLOAK_NAMESPACE:-keycloak-oidc-test}}"
KC_POD="${KC_POD:-${KEYCLOAK_NAME:-rhbk}-0}"
KC_REALM="${KC_REALM:-${KEYCLOAK_REALM:-rhoai}}"
KC_ADMIN_SECRET="${KC_ADMIN_SECRET:-${KEYCLOAK_ADMIN_SECRET:-rhbk-initial-admin}}"

# kc_run [VAR=value ...] < script
# Runs the bash script on stdin inside the Keycloak pod, logged in to kcadm. The
# VAR=value pairs become shell variables there, sent on stdin. In the script:
#   kc <kcadm args>     kcadm with stdin from /dev/null
#   kc_in <kcadm args>  kcadm reading stdin (for -f -)
#   $R                  the realm
# There is no awk, python or jq in the Keycloak image; use bash, sed, grep, cut, tr.
kc_run() {
    local body admin_user admin_pw kv
    body="$(cat)"
    admin_user="$("$OC" get secret "$KC_ADMIN_SECRET" -n "$KC_NS" -o jsonpath='{.data.username}' | base64 -d)"
    admin_pw="$("$OC" get secret "$KC_ADMIN_SECRET" -n "$KC_NS" -o jsonpath='{.data.password}' | base64 -d)"
    [ -n "$admin_user" ] && [ -n "$admin_pw" ] || {
        echo "Error: could not read the Keycloak admin from Secret ${KC_NS}/${KC_ADMIN_SECRET}" >&2; return 1; }
    {
        printf 'export KC_CLI_PASSWORD=%q\n' "$admin_pw"
        printf 'KC_ADMIN_USER=%q\nR=%q\n' "$admin_user" "$KC_REALM"
        for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
        cat <<'PRE'
set -euo pipefail
CFG="/tmp/kcadm-$$.config"; trap 'rm -f "$CFG"' EXIT
kc()    { /opt/keycloak/bin/kcadm.sh "$@" --config "$CFG" </dev/null; }
kc_in() { /opt/keycloak/bin/kcadm.sh "$@" --config "$CFG"; }
kc config credentials --server http://localhost:8080 --realm master --user "$KC_ADMIN_USER" >/dev/null 2>&1 \
    || { echo "Error: kcadm could not log in to Keycloak as $KC_ADMIN_USER" >&2; exit 1; }
unset KC_CLI_PASSWORD
uid_of() { kc get users -r "$R" -q username="$1" -q exact=true --fields id --format csv --noquotes | head -1; }
gid_of() {
    local i n
    while IFS=, read -r i n; do [ "$n" = "$1" ] && { echo "$i"; return 0; }; done \
        < <(kc get groups -r "$R" -q search="$1" -q exact=true --fields id,name --format csv --noquotes)
    return 0
}
PRE
        printf '%s\n' "$body"
    } | "$OC" exec -i -n "$KC_NS" "$KC_POD" -- bash -s
}

kc_user_id() {
    kc_run U="$1" <<'EOF'
uid_of "$U"
EOF
}

kc_user_ensure() {
    local user="$1" pw="$2" pw_json=""
    shift 2
    if [ -n "$pw" ]; then
        pw_json="$(PW="$pw" python3 -I -c 'import json,os; print(json.dumps({"type":"password","value":os.environ["PW"],"temporary":False}))')"
    fi
    kc_run U="$user" PW_JSON="$pw_json" GROUPS_LIST="$*" <<'EOF'
id="$(uid_of "$U")"
if [ -z "$id" ]; then
    # firstName/lastName as the realm import set them: Keycloak's user profile
    # requires them, and a user missing one has a required action, which makes
    # the password grant fail with "Account is not fully set up".
    kc create users -r "$R" -s username="$U" -s enabled=true -s emailVerified=true \
        -s email="$U@example.test" -s firstName="$U" -s lastName=user -i >/dev/null
    id="$(uid_of "$U")"
    state=created
else
    kc update "users/$id" -r "$R" -s enabled=true -s emailVerified=true -s 'requiredActions=[]'
    state=updated
fi
[ -n "$id" ] || { echo "Error: user $U not found after create" >&2; exit 1; }
if [ -n "$PW_JSON" ]; then
    printf '%s' "$PW_JSON" | kc_in update "users/$id/reset-password" -r "$R" -n -f -
fi
for g in $GROUPS_LIST; do
    gid="$(gid_of "$g")"
    if [ -z "$gid" ]; then
        kc create groups -r "$R" -s name="$g" -i >/dev/null
        gid="$(gid_of "$g")"
        echo "    created realm group $g" >&2
    fi
    kc update "users/$id/groups/$gid" -r "$R" -n
done
echo "$state"
EOF
}

kc_users_groups() {
    kc_run <<'EOF'
while IFS=, read -r id name enabled; do
    gs="$(kc get "users/$id/groups" -r "$R" --fields name --format csv --noquotes | tr '\n' ',' | sed 's/,$//')"
    printf '%s\t%s\t%s\n' "$name" "$enabled" "${gs:--}"
done < <(kc get users -r "$R" --fields id,username,enabled --format csv --noquotes -l 1000)
EOF
}

kc_user_delete() {
    kc_run U="$1" <<'EOF'
id="$(uid_of "$U")"
if [ -n "$id" ]; then kc delete "users/$id" -r "$R"; echo deleted; else echo absent; fi
EOF
}

kc_group_delete() {
    kc_run G="$1" <<'EOF'
gid="$(gid_of "$G")"
if [ -n "$gid" ]; then kc delete "groups/$gid" -r "$R"; echo deleted; else echo absent; fi
EOF
}
