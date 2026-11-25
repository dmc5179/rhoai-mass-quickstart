#!/usr/bin/env bash
#
# cluster-users.sh - create, update or remove the users who log in to this
#                    cluster, and report their passwords to hand out. htpasswd
#                    users normally; Keycloak realm users on external OIDC.
#
# Usage: scripts/cluster-users.sh apply  <user>... [--admin] [--group <g>]... [--rotate] [--no-values]
#        scripts/cluster-users.sh remove <user>... [--no-values]
#        scripts/cluster-users.sh status
#
#   apply     Add each user, or keep them as they are. A new user gets a new
#             password; an existing user keeps theirs unless --rotate. A user
#             whose password is in secrets/cluster-users.env but who is missing
#             from the cluster (a rebuild) gets that same password back. Every
#             user goes into the maas-users Group, so they can mint MaaS API
#             keys. With --admin they also go into cluster-admins
#             (ClusterRole cluster-admin).
#   remove    Delete the users' htpasswd lines and Group memberships.
#   status    List the users in the htpasswd Secret, their Groups, and whether
#             each can log in.
#
#   --admin      Also grant cluster-admin through the cluster-admins Group.
#   --group <g>  Also add the users to Group <g> (repeatable).
#   --rotate     Generate new passwords for users who already have one.
#   --no-values  Leave the AutoShift hub values alone (passwords only).
#
# On a cluster with external OIDC (authentications.config type OIDC) there is no
# OAuth server, no htpasswd and no OpenShift Groups: the users and groups live
# in the Keycloak realm (scripts/lib-keycloak.sh), and the token's groups claim
# carries the membership. Then:
#   apply     creates or updates the realm user (enabled, email verified) and
#             adds it to maas-users, with --admin also cluster-admins and
#             rhods-admins, and to each --group; missing groups are created.
#             Memberships are only ever added. An existing user's password is
#             left alone unless --rotate; if the one in the file gets no token,
#             that is reported, not reset.
#   remove    deletes the realm users.
#   status    lists the realm users and their groups, and gets each a token.
#   The htpasswd Secret, the identity provider and the hub values are skipped.
#
# Why named users rather than kubeadmin. kubeadmin is a break-glass account:
# every action shows up as the same person, it is in no Group, so it can't mint
# MaaS keys (MaaS checks Group membership), and it is meant to be removed once
# a real identity provider exists. A login per person gives an audit trail, lets
# you revoke one person without touching the others, and lets each person own
# their own MaaS keys.
#
# Who owns what:
#   - Passwords: this script. The htpasswd Secret openshift-config/htpasswd-users
#     holds bcrypt hashes; the plain passwords go to secrets/cluster-users.env
#     (mode 0600, gitignored) so they can be sent to people. Neither is in git.
#   - Groups and role bindings: the AutoShift htpasswd-users policy, from
#     config.htpasswdUsers in the hub values. This script edits that file
#     ($AUTOSHIFT_DIR/autoshift/values/clustersets/hub.yaml) unless
#     --no-values. Values are read at bootstrap, so a Group change takes effect
#     after `scripts/50-autoshift.sh bootstrap`. Commit the file in the fork too.
#
# Users already in the Secret (maas-user, anyone added by hand) are kept.
# Removing someone does NOT revoke MaaS keys they minted; revoke those by hand.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

usage() { sed -n '2,59p' "${BASH_SOURCE[0]}"; }
case "${1:-}" in -h|--help|"") usage; exit 0 ;; esac
ACTION="$1"; shift

ADMIN=0; ROTATE=0; VALUES=1; USERS=(); EXTRA_GROUPS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --admin)     ADMIN=1; shift ;;
        --group)     EXTRA_GROUPS+=("${2:?--group needs a name}"); shift 2 ;;
        --rotate)    ROTATE=1; shift ;;
        --no-values) VALUES=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*) echo "cluster-users.sh: unknown option '$1'" >&2; exit 2 ;;
        *)  USERS+=("$1"); shift ;;
    esac
done

case "$ACTION" in
    apply|remove) [ ${#USERS[@]} -gt 0 ] || { echo "Error: name at least one user." >&2; exit 2; } ;;
    status) ;;
    *) echo "Usage: scripts/cluster-users.sh {apply|remove|status} [user...] [options]" >&2; exit 2 ;;
esac

for u in ${USERS[@]+"${USERS[@]}"}; do
    # OpenShift user names are free-form, but keep them to what htpasswd and a
    # Group member list both handle without quoting surprises.
    [[ "$u" =~ ^[a-z0-9]([a-z0-9._-]{0,61}[a-z0-9])?$ ]] || {
        echo "Error: '$u' is not a valid user name (lower-case letters, digits, . _ -)." >&2; exit 2; }
    [ "$u" = "kubeadmin" ] && { echo "Error: kubeadmin is not an htpasswd user." >&2; exit 2; }
done
for g in ${EXTRA_GROUPS[@]+"${EXTRA_GROUPS[@]}"}; do
    [[ "$g" =~ ^[a-z0-9]([a-z0-9._:-]{0,61}[a-z0-9])?$ ]] || {
        echo "Error: '$g' is not a valid group name." >&2; exit 2; }
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
. "${ROOT}/scripts/lib-oc-token.sh"
. "${ROOT}/scripts/lib-keycloak.sh"
start_logging "cluster-users" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

# Must match config.htpasswdUsers in the hub values.
SECRET_NAME="htpasswd-users"
PROVIDER_NAME="htpasswd"
MAAS_GROUP="maas-users"
ADMIN_GROUP="cluster-admins"
RHODS_ADMIN_GROUP="rhods-admins"   # OIDC mode only; in htpasswd mode the hub values own it
PW_FILE="${ROOT}/secrets/cluster-users.env"
VALUES_FILE="${AUTOSHIFT_DIR:?AUTOSHIFT_DIR must be set in cluster.env}/autoshift/values/clustersets/hub.yaml"

export KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
"$OC" get --raw /readyz >/dev/null 2>&1 || {
    echo "Error: cluster API not reachable via ${KUBECONFIG}." >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
HTFILE="${WORK}/htpasswd"

OIDC=0
if cluster_is_oidc; then
    OIDC=1
    echo "==> Cluster uses external OIDC: users and groups are in Keycloak realm ${KC_REALM} (${KC_NS}/${KC_POD})"
fi

fetch_htpasswd() {
    : > "$HTFILE"
    if "$OC" get secret "$SECRET_NAME" -n openshift-config >/dev/null 2>&1; then
        "$OC" extract "secret/${SECRET_NAME}" -n openshift-config --keys=htpasswd --to="$WORK" --confirm >/dev/null
    fi
}

push_htpasswd() {
    "$OC" create secret generic "$SECRET_NAME" -n openshift-config \
        --from-file=htpasswd="$HTFILE" --dry-run=client -o yaml | "$OC" apply -f - >/dev/null
    echo "==> Secret openshift-config/${SECRET_NAME} applied"
}

# Passwords file: one `user=password` line per user, nothing else.
pw_get() { [ -f "$PW_FILE" ] && sed -n "s/^${1}=//p" "$PW_FILE" | head -1 || true; }
pw_set() {
    umask 077
    touch "$PW_FILE"
    grep -v "^${1}=" "$PW_FILE" > "${WORK}/pw" || true
    printf '%s=%s\n' "$1" "$2" >> "${WORK}/pw"
    sort -o "$PW_FILE" "${WORK}/pw"
    chmod 600 "$PW_FILE"
}
pw_del() {
    [ -f "$PW_FILE" ] || return 0
    grep -v "^${1}=" "$PW_FILE" > "${WORK}/pw" || true
    cat "${WORK}/pw" > "$PW_FILE"
}
# pw_get, falling back to maas-user.sh's own file for maas-user.
pw_any() {
    local pw; pw="$(pw_get "$1")"
    if [ -z "$pw" ] && [ -f "${ROOT}/secrets/maas-user.env" ]; then
        pw="$(. "${ROOT}/secrets/maas-user.env"; [ "${MAAS_USER:-}" = "$1" ] && printf '%s' "${MAAS_USER_PASSWORD:-}")" || true
    fi
    printf '%s' "$pw"
}
gen_password() {
    python3 -I -c "
import secrets, string
print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))"
}

# Group membership in the hub values, through Go yq (see CLAUDE.md).
values_check() {
    yq --version 2>/dev/null | grep -q 'mikefarah/yq.* v4\.' || {
        echo "Error: needs Go yq v4 (mikefarah), not the Python yq." >&2; exit 1; }
    [ -f "$VALUES_FILE" ] || { echo "Error: ${VALUES_FILE} not found." >&2; exit 1; }
    EDIT_FILE="${WORK}/hub.yaml"
    cp "$VALUES_FILE" "$EDIT_FILE"
}
# yq reflows whitespace across the whole file (blank lines, comment alignment),
# which would make every user change a noisy diff. Edit a copy with yq, then
# splice only the htpasswdUsers block back, leaving the rest byte for byte.
values_commit() {
    python3 -I - "$VALUES_FILE" "$EDIT_FILE" <<'PY'
import sys
orig_path, edit_path = sys.argv[1], sys.argv[2]
def block(lines):
    for i, l in enumerate(lines):
        if l.rstrip() == "      htpasswdUsers:":
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].startswith("       ")):
                j += 1
            while j > i + 1 and not lines[j - 1].strip():   # keep trailing blank lines outside
                j -= 1
            return i, j
    sys.exit("htpasswdUsers block not found at config indentation")
orig = open(orig_path).read().splitlines(keepends=True)
edit = open(edit_path).read().splitlines(keepends=True)
oi, oj = block(orig); ei, ej = block(edit)
open(orig_path, "w").write("".join(orig[:oi] + edit[ei:ej] + orig[oj:]))
PY
}
values_add() {   # $1 group, $2 user, $3 clusterRole ('' for none)
    local have
    have="$(G="$1" yq '[.hubClusterSets.hub.config.htpasswdUsers.groups[]? | select(.name == strenv(G))] | length' "$EDIT_FILE")"
    if [ "$have" = "0" ]; then
        G="$1" yq -i '.hubClusterSets.hub.config.htpasswdUsers.groups += [{"name": strenv(G), "users": []}]' "$EDIT_FILE"
    fi
    G="$1" U="$2" yq -i '(.hubClusterSets.hub.config.htpasswdUsers.groups[] | select(.name == strenv(G))).users |= ((. // []) + [strenv(U)] | unique)' "$EDIT_FILE"
    if [ -n "$3" ]; then
        G="$1" R="$3" yq -i '(.hubClusterSets.hub.config.htpasswdUsers.groups[] | select(.name == strenv(G))).clusterRoles |= ((. // []) + [strenv(R)] | unique)' "$EDIT_FILE"
    fi
}
values_remove() {   # $1 user
    U="$1" yq -i '
      .hubClusterSets.hub.config.htpasswdUsers.groups[].users |= map(select(. != strenv(U)))
    ' "$EDIT_FILE"
}

# --- external OIDC: status and remove -----------------------------------------
if [ "$OIDC" -eq 1 ] && [ "$ACTION" = "status" ]; then
    echo "==> Skipped: htpasswd Secret and OAuth identity provider (no OAuth server under external OIDC)"
    echo "==> Users in realm ${KC_REALM} (token = password grant with the password on file):"
    kc_users_groups > "${WORK}/realm-users"
    [ -s "${WORK}/realm-users" ] || echo "    none"
    while IFS=$'\t' read -r u enabled groups; do
        pw="$(pw_any "$u")"
        if [ -z "$pw" ]; then
            token="(password not in ${PW_FILE##*/})"
        elif [ -n "$(oidc_token "$u" "$pw" 2>/dev/null)" ]; then
            token="OK"
        else
            token="FAIL"
        fi
        printf '    %-16s enabled=%-5s groups=%-50s token=%s\n' "$u" "$enabled" "$groups" "$token"
    done < "${WORK}/realm-users"
    exit 0
fi
if [ "$OIDC" -eq 1 ] && [ "$ACTION" = "remove" ]; then
    echo "==> Skipped: htpasswd Secret and hub values (no OpenShift users or Groups under external OIDC)"
    for u in "${USERS[@]}"; do
        if [ "$(kc_user_delete "$u")" = "deleted" ]; then
            echo "==> Deleted ${u} from realm ${KC_REALM} (and its group memberships)"
        else
            echo "==> ${u} was not in realm ${KC_REALM}"
        fi
        pw_del "$u"
    done
    cat <<EOF

Removed: ${USERS[*]}

They can no longer get a token. A token already issued stays valid until it
expires (the realm's access-token lifespan, 5 minutes on the lab realm).
MaaS API keys they minted are NOT revoked by this. Revoke them by hand.
EOF
    exit 0
fi

# --- status -----------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    fetch_htpasswd
    echo "==> Users in openshift-config/${SECRET_NAME}:"
    if [ -s "$HTFILE" ]; then
        for u in $(cut -d: -f1 "$HTFILE"); do
            groups="$("$OC" get groups.user.openshift.io -o json 2>/dev/null \
                | U="$u" python3 -I -c 'import json,os,sys; print(",".join(g["metadata"]["name"] for g in json.load(sys.stdin)["items"] if os.environ["U"] in (g.get("users") or [])) or "-")')"
            pw="$(pw_any "$u")"
            login="-"
            if [ -n "$pw" ]; then
                tmp_kc="${WORK}/kc-${u}"
                KUBECONFIG="$tmp_kc" "$OC" login -u "$u" -p "$pw" \
                    --server="$("$OC" whoami --show-server)" --insecure-skip-tls-verify=true >/dev/null 2>&1 \
                    && login="OK" || login="FAILED"
            else
                login="(password not in ${PW_FILE##*/})"
            fi
            printf '    %-16s groups=%-28s login=%s\n' "$u" "$groups" "$login"
        done
    else
        echo "    none"
    fi
    printf '==> Identity provider %s: ' "$PROVIDER_NAME"
    "$OC" get oauth.config.openshift.io cluster \
        -o jsonpath="{.spec.identityProviders[?(@.name==\"${PROVIDER_NAME}\")].type}" 2>/dev/null | grep -q HTPasswd \
        && echo "present" || echo "absent (is the htpasswd-users policy enabled?)"
    exit 0
fi

if [ "$OIDC" -eq 0 ]; then
    command -v htpasswd >/dev/null || {
        echo "Error: 'htpasswd' not found. Install httpd-tools (dnf install httpd-tools)." >&2; exit 1; }
    [ "$VALUES" -eq 1 ] && values_check
    fetch_htpasswd
fi

# --- remove -----------------------------------------------------------------
if [ "$ACTION" = "remove" ]; then
    for u in "${USERS[@]}"; do
        if grep -q "^${u}:" "$HTFILE" 2>/dev/null; then
            htpasswd -D "$HTFILE" "$u" >/dev/null 2>&1
            echo "==> Removed ${u} from the htpasswd Secret"
        else
            echo "==> ${u} was not in the htpasswd Secret"
        fi
        pw_del "$u"
        [ "$VALUES" -eq 1 ] && values_remove "$u"
    done
    [ "$VALUES" -eq 1 ] && values_commit
    push_htpasswd
    cat <<EOF

Removed: ${USERS[*]}

They can no longer log in. Their OpenShift User and Identity objects remain;
delete them to finish (each identity is named htpasswd:<user>):

$(for u in "${USERS[@]}"; do echo "    oc delete user ${u}; oc delete identity ${PROVIDER_NAME}:${u}"; done)

MaaS API keys they minted are NOT revoked by this. Revoke them by hand.
EOF
    if [ "$VALUES" -eq 1 ]; then
        echo
        echo "Group membership was removed from ${VALUES_FILE}."
        echo "Apply it with: scripts/50-autoshift.sh bootstrap   (and commit the file in the fork)"
    fi
    exit 0
fi

# --- apply ------------------------------------------------------------------
declare -A NEWPW
if [ "$OIDC" -eq 1 ]; then
    echo "==> Skipped: htpasswd Secret and hub values (no OpenShift users or Groups under external OIDC)"
    WANT_GROUPS="$MAAS_GROUP"
    [ "$ADMIN" -eq 1 ] && WANT_GROUPS="${WANT_GROUPS} ${ADMIN_GROUP} ${RHODS_ADMIN_GROUP}"
    for g in ${EXTRA_GROUPS[@]+"${EXTRA_GROUPS[@]}"}; do WANT_GROUPS="${WANT_GROUPS} ${g}"; done
    for u in "${USERS[@]}"; do
        pw="$(pw_get "$u")"
        exists=0; [ -n "$(kc_user_id "$u")" ] && exists=1
        setpw=""
        if [ "$exists" -eq 0 ] && [ -n "$pw" ] && [ "$ROTATE" -eq 0 ]; then
            state="restored"; setpw="$pw"     # rebuilt realm: same password back
        elif [ "$exists" -eq 0 ]; then
            state="new"; pw="$(gen_password)"; setpw="$pw"
        elif [ "$ROTATE" -eq 1 ]; then
            state="rotated"; pw="$(gen_password)"; setpw="$pw"
        else
            state="kept"
        fi
        # Recorded first, so a password the realm has is never missing from the file.
        if [ -n "$setpw" ]; then pw_set "$u" "$pw"; fi
        # shellcheck disable=SC2086  # WANT_GROUPS is a word list of validated names
        kc_user_ensure "$u" "$setpw" $WANT_GROUPS >/dev/null
        if [ "$state" = "kept" ]; then
            if [ -z "$pw" ]; then
                state="kept (password not in ${PW_FILE##*/}; realm password unchanged)"
            elif [ -z "$(oidc_token "$u" "$pw" 2>/dev/null)" ]; then
                state="PASSWORD MISMATCH: the one in ${PW_FILE##*/} gets no token; realm password left as it is (--rotate to set a new one)"
            fi
        fi
        echo "==> ${u}: realm user ${state}; groups include ${WANT_GROUPS// /, }"
        NEWPW["$u"]="$state"
    done
else
for u in "${USERS[@]}"; do
    pw="$(pw_get "$u")"
    if [ -n "$pw" ] && [ "$ROTATE" -eq 0 ] && grep -q "^${u}:" "$HTFILE" 2>/dev/null; then
        state="kept"
    elif [ -n "$pw" ] && [ "$ROTATE" -eq 0 ]; then
        # In secrets/cluster-users.env but not in the cluster's htpasswd: a
        # rebuilt cluster, or a Secret recreated by hand. Put the same password
        # back rather than inventing a new one people would have to be sent.
        state="restored"
    else
        pw="$(gen_password)"
        grep -q "^${u}:" "$HTFILE" 2>/dev/null && state="rotated" || state="new"
    fi
    # -B bcrypt; -i reads the password from stdin so it never shows in ps.
    if [ -s "$HTFILE" ]; then printf '%s' "$pw" | htpasswd -B -i "$HTFILE" "$u" >/dev/null 2>&1
    else printf '%s' "$pw" | htpasswd -c -B -i "$HTFILE" "$u" >/dev/null 2>&1; fi
    pw_set "$u" "$pw"
    NEWPW["$u"]="$state"
    if [ "$VALUES" -eq 1 ]; then
        values_add "$MAAS_GROUP" "$u" ""
        [ "$ADMIN" -eq 1 ] && values_add "$ADMIN_GROUP" "$u" "cluster-admin"
        for g in ${EXTRA_GROUPS[@]+"${EXTRA_GROUPS[@]}"}; do values_add "$g" "$u" ""; done
    fi
done
[ "$VALUES" -eq 1 ] && values_commit
push_htpasswd
fi

CONSOLE="$("$OC" whoami --show-console 2>/dev/null || echo "<console URL>")"
# RHOAI 3.x serves the dashboard through its gateway at the GatewayConfig's domain
# (rh-ai.<apps domain>); the old rhods-dashboard Route only redirects there.
DASHBOARD="$("$OC" get gatewayconfig default-gateway -o jsonpath='https://{.status.domain}' 2>/dev/null || true)"
[ "$DASHBOARD" = "https://" ] && DASHBOARD=""
[ -n "$DASHBOARD" ] || DASHBOARD="$("$OC" get route rhods-dashboard -n redhat-ods-applications -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"

# Passwords go to the terminal only. Everything on stdout is tee'd into logs/
# by lib-logging, so printing them there would leave every password in a log
# file. /dev/tty bypasses the tee; with no terminal (a pipeline, CI), they are
# not printed at all and the file is the only copy.
tty_ok=0
{ : > /dev/tty; } 2>/dev/null && tty_ok=1
echo
echo "Logins to send (kept in ${PW_FILE}, mode 0600, not in git):"
echo
printf '  %-16s %s\n' USER STATE
for u in "${USERS[@]}"; do
    printf '  %-16s %s\n' "$u" "${NEWPW[$u]}"
done
if [ "$tty_ok" -eq 1 ]; then
    {
        echo
        echo "  Passwords (shown on this terminal only, not logged):"
        for u in "${USERS[@]}"; do
            if [ -n "$(pw_get "$u")" ]; then printf '    %-16s %s\n' "$u" "$(pw_get "$u")"; fi
        done
    } > /dev/tty
else
    echo
    echo "  No terminal, so passwords are not printed. Read them from ${PW_FILE}."
fi
if [ "$OIDC" -eq 1 ]; then
    ISSUER="$("$OC" get authentications.config.openshift.io cluster -o jsonpath='{.spec.oidcProviders[0].issuer.issuerURL}')"
    CLI_ID="$("$OC" get authentications.config.openshift.io cluster -o jsonpath='{.spec.oidcProviders[0].oidcClients[?(@.componentName=="cli")].clientID}')"
    cat <<EOF

  Console:        ${CONSOLE}   (signs in through Keycloak)
EOF
    [ -n "$DASHBOARD" ] && echo "  RHOAI dashboard: ${DASHBOARD}"
    cat <<EOF
  CLI:            oc login $("$OC" whoami --show-server) --exec-plugin oc-oidc \\
                      --issuer-url ${ISSUER} --client-id ${CLI_ID} --callback-port 8080 \\
                      --certificate-authority <api-ca> --oidc-certificate-authority <ingress-ca>

A new realm user can sign in at once. Group changes reach a session at its next
token (5 minutes on the lab realm).
EOF
    exit 0
fi
cat <<EOF

  Console:        ${CONSOLE}   (choose the "${PROVIDER_NAME}" login)
EOF
[ -n "$DASHBOARD" ] && echo "  RHOAI dashboard: ${DASHBOARD}"
cat <<EOF
  CLI:            oc login -u <user> $("$OC" whoami --show-server)

A new login works once the oauth-openshift pods pick up the Secret, usually
within a minute or two.
EOF
if [ ${#EXTRA_GROUPS[@]} -gt 0 ] && [ "$VALUES" -eq 0 ]; then
    echo; echo "Note: --group has no effect with --no-values (the hub values own the Groups)."
fi
if [ "$VALUES" -eq 1 ]; then
    cat <<EOF

Group membership (${MAAS_GROUP}$([ "$ADMIN" -eq 1 ] && echo ", ${ADMIN_GROUP}")) was written to:
    ${VALUES_FILE}
It takes effect, so they can mint MaaS keys, after:
    scripts/50-autoshift.sh bootstrap
Commit that file in the fork as well, or the next bootstrap from a clean
checkout drops them.
EOF
fi
