#!/usr/bin/env bash
#
# 48-external-oidc.sh - switch a freshly built cluster to OpenShift direct authentication
#                       against an in-cluster Red Hat build of Keycloak (AUTH_MODE=oidc).
#
# Usage: AUTH_MODE=oidc scripts/48-external-oidc.sh <step> [--dry-run]
#
# Steps, in order (each one can be re-run):
#   preflight   AUTH_MODE is oidc, the installer kubeconfig (client certificate) is in use,
#               the API answers, and the RHOAI GatewayConfig and Dev Spaces namespace exist.
#   keycloak    Keycloak operator, PostgreSQL, Keycloak and the realm (keycloak-oidc.sh
#               keycloak-install). Skipped when the realm already answers.
#   switch      authentications.config.openshift.io/cluster -> type OIDC, with every client
#               as an audience (console, oc-cli, the RHOAI gateway and Dev Spaces) so there
#               is one kube-apiserver rollout, not two. Waits for the rollout (~20 min).
#               Skipped when the cluster is already OIDC.
#   gateway     RHOAI GatewayConfig default-gateway -> spec.oidc, regenerate the
#               kube-auth-proxy credentials, cookie refresh 4m (below the token lifespan).
#   devspaces   Secret oauth-secret and ConfigMap keycloak-certs (ca-bundle) in
#               openshift-devspaces, for the CheCluster networking.auth that phase 45 writes.
#   smoke       keycloak-oidc.sh verify and scripts/checkup.sh --section auth.
#   all         Every step above, in order.
#
# Phase order: 10 -> 45 (AUTH_MODE=oidc) -> 50 bootstrap/adopt -> 48 all -> maas-user.sh -> 35.
# Between 50 and 48 nobody can sign in except with the installer kubeconfig, and Dev Spaces
# points at an issuer that does not exist yet. That is expected.
#
# Break-glass: the installer kubeconfig keeps working throughout. Copy it somewhere safe
# before 'switch' (see CLAUDE.md, "Break-glass").
#
# The steps call scripts/keycloak-oidc.sh, the tested harness that switched the lab on
# 2026-11-24, with the names from cluster.env (KEYCLOAK_*, OIDC_*).
#
# FIRST PASS (AUTH_MODE task T3): the keycloak step still builds its realm the way
# keycloak-oidc.sh does, from secrets/keycloak-oidc-backup/groups.json. A new cluster has no
# such backup; the realm builder (scripts/lib-oidc-realm.sh, task T2) replaces that input.
# Until then 'keycloak' refuses on a cluster without the backup. Not yet run end to end (T6).
set -euo pipefail

ORIG_ARGS=("$@")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}"; }

STEP="${1:-}"; shift || true
DRY=""
for a in "$@"; do
    case "$a" in
        --dry-run) DRY="--dry-run" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "48-external-oidc.sh: unknown option '$a'" >&2; exit 2 ;;
    esac
done
case "$STEP" in
    preflight|keycloak|switch|gateway|devspaces|smoke|all) ;;
    -h|--help|"") usage; exit 0 ;;
    *) echo "48-external-oidc.sh: unknown step '$STEP'" >&2; usage >&2; exit 2 ;;
esac

start_logging "48-external-oidc" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
export KUBECONFIG
KC="${ROOT}/scripts/keycloak-oidc.sh"
DEVSPACES_NS="openshift-devspaces"

step() { echo; echo "==> $*"; }
die()  { echo "Error: $*" >&2; exit 1; }
dry()  { [ -n "$DRY" ]; }
auth_type() { "$OC" get authentications.config.openshift.io cluster -o jsonpath='{.spec.type}' 2>/dev/null || true; }
issuer() {
    echo "https://keycloak-${KEYCLOAK_NAMESPACE}.$("$OC" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')/realms/${KEYCLOAK_REALM}"
}

do_preflight() {
    step "Preflight"
    [ "${AUTH_MODE:-oauth}" = "oidc" ] || die "AUTH_MODE is '${AUTH_MODE:-oauth}'; run as AUTH_MODE=oidc $0 ${STEP}"
    if dry; then echo "    [dry-run] would check the API, the kubeconfig, GatewayConfig and ${DEVSPACES_NS}"; return 0; fi
    [ -f "$KUBECONFIG" ] || die "no installer kubeconfig at ${KUBECONFIG}"
    "$OC" get --raw /readyz >/dev/null 2>&1 || die "the cluster API is not reachable"
    # The installer kubeconfig authenticates with a client certificate; it is the way back in
    # once the OAuth server is gone, so refuse to run with anything else.
    "$OC" config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | grep -q . \
        || die "KUBECONFIG does not authenticate with a client certificate; use the installer kubeconfig"
    echo "    API ready; installer kubeconfig (client certificate); Authentication type: $(auth_type)"
    "$OC" get gatewayconfigs.services.platform.opendatahub.io default-gateway >/dev/null 2>&1 \
        && echo "    RHOAI GatewayConfig default-gateway present" \
        || echo "    Warning: no RHOAI GatewayConfig yet; the gateway step will wait for it" >&2
    "$OC" get namespace "$DEVSPACES_NS" >/dev/null 2>&1 \
        && echo "    ${DEVSPACES_NS} present" \
        || echo "    Warning: ${DEVSPACES_NS} not present; the devspaces step is skipped until it exists" >&2
}

do_keycloak() {
    step "Keycloak and the realm (${KEYCLOAK_NAMESPACE}/${KEYCLOAK_NAME}, realm ${KEYCLOAK_REALM})"
    if ! dry && curl -skf --max-time 10 "$(issuer)/.well-known/openid-configuration" >/dev/null 2>&1; then
        echo "    realm already answers at $(issuer); skipped"
        return 0
    fi
    # TODO(T2): build the realm with scripts/lib-oidc-realm.sh instead of the lab's backup.
    "$KC" keycloak-install $DRY
}

do_switch() {
    step "OpenShift Authentication -> OIDC (one rollout, all audiences)"
    if ! dry && [ "$(auth_type)" = "OIDC" ]; then
        echo "    already OIDC; skipped"
        return 0
    fi
    # Dev Spaces signs in with its own client, so its token must carry an audience the API
    # server accepts; adding it now avoids the second rollout the lab needed on 2026-11-25.
    EXTRA_AUDIENCES="${OIDC_CLIENT_DEVSPACES}" "$KC" switch-ocp $DRY
}

do_gateway() {
    step "RHOAI gateway -> Keycloak"
    if ! dry; then
        for _ in $(seq 1 60); do
            "$OC" get gatewayconfigs.services.platform.opendatahub.io default-gateway >/dev/null 2>&1 && break
            sleep 10
        done
        "$OC" get gatewayconfigs.services.platform.opendatahub.io default-gateway >/dev/null 2>&1 \
            || die "no GatewayConfig default-gateway after 10 minutes; is RHOAI installed (phase 50)?"
    fi
    "$KC" switch-gateway --regen-creds $DRY
    # Below the access-token lifespan, or dashboard sessions end when the token expires.
    "$KC" cookie-refresh 4m $DRY
}

do_devspaces() {
    step "Dev Spaces sign-in through Keycloak"
    if dry; then
        echo "    [dry-run] would create Secret oauth-secret (oAuthSecret from secrets/keycloak-oidc.env DEVSPACES_CLIENT_SECRET)"
        echo "    [dry-run] and ConfigMap keycloak-certs (component=ca-bundle) in ${DEVSPACES_NS}"
        return 0
    fi
    "$OC" get namespace "$DEVSPACES_NS" >/dev/null 2>&1 || { echo "    ${DEVSPACES_NS} not present; skipped"; return 0; }
    local env="${ROOT}/secrets/keycloak-oidc.env" sec
    # shellcheck disable=SC1090
    sec="$( ( set +u; . "$env"; printf '%s' "${DEVSPACES_CLIENT_SECRET:-}" ) )"
    [ -n "$sec" ] || die "DEVSPACES_CLIENT_SECRET is not in ${env}; the realm must define the ${OIDC_CLIENT_DEVSPACES} client first"
    # The secret goes to oc on stdin, never on a command line.
    printf '%s' "$sec" | "$OC" create secret generic oauth-secret -n "$DEVSPACES_NS" \
        --from-file=oAuthSecret=/dev/stdin --dry-run=client -o yaml \
        | "$OC" label --local -f - app.kubernetes.io/part-of=che.eclipse.org -o yaml \
        | "$OC" apply -f - >/dev/null
    unset sec
    # Keycloak's route uses the default ingress certificate, so trust that CA.
    "$OC" get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' \
        | "$OC" create configmap keycloak-certs -n "$DEVSPACES_NS" --from-file=keycloak-ca.crt=/dev/stdin \
            --dry-run=client -o yaml \
        | "$OC" label --local -f - app.kubernetes.io/component=ca-bundle app.kubernetes.io/part-of=che.eclipse.org -o yaml \
        | "$OC" apply -f - >/dev/null
    echo "    oauth-secret and keycloak-certs applied in ${DEVSPACES_NS}"
}

do_smoke() {
    step "Smoke test"
    if dry; then echo "    [dry-run] would run keycloak-oidc.sh verify and checkup.sh --section auth"; return 0; fi
    "$KC" verify || echo "Warning: keycloak-oidc.sh verify reported problems" >&2
    "${ROOT}/scripts/checkup.sh" --section auth
}

case "$STEP" in
    preflight) do_preflight ;;
    keycloak)  do_preflight; do_keycloak ;;
    switch)    do_preflight; do_switch ;;
    gateway)   do_preflight; do_gateway ;;
    devspaces) do_preflight; do_devspaces ;;
    smoke)     do_smoke ;;
    all)       do_preflight; do_keycloak; do_switch; do_gateway; do_devspaces; do_smoke ;;
esac
