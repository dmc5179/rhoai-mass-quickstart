# shellcheck shell=bash
# lib-openshell-cli.sh - run the OpenShell CLI from a throwaway pod in the
#                        cluster, so no openshell binary is needed here.
#
# Source after cluster.env, bin/ocp-env.sh and KUBECONFIG are set up:
#
#     . "${ROOT}/scripts/lib-openshell-cli.sh"
#     oscli_ensure_pod           # create it if absent, wait until Ready
#     oscli_run status           # openshell status, inside the pod
#     oscli_cleanup              # delete it, if this process created it
#
# The pod runs quay.io/opendatahub/odh-openshell-cli at the SAME tag as the
# live gateway, read from StatefulSet openshell, so the CLI always matches the
# gateway it talks to. It reaches the gateway on its in-cluster Service and
# signs in with the gateway's mTLS client bundle (Secret openshell-client-tls),
# which it copies out of a read-only mount because the CLI wants its key at
# 0600 under $HOME. With OIDC off that identity is a platform admin, and only a
# cluster admin can read the Secret, so the pod is as privileged as its
# creator. It deletes itself after OSCLI_TTL seconds whatever happens here.
#
# Used by scripts/openshell-cli.sh and scripts/openshell-smoke-test.sh.

OSCLI_NS="${OSCLI_NS:-openshell}"
OSCLI_POD="${OSCLI_POD:-openshell-cli}"
OSCLI_TTL="${OSCLI_TTL:-3600}"
OSCLI_CREATED=0

# The CLI image for the running gateway: odh-openshell-gateway:<tag> becomes
# odh-openshell-cli:<tag>. Fails when there is no gateway, rather than guessing.
oscli_image() {
    local gw
    gw="$("$OC" get statefulsets.apps openshell -n "$OSCLI_NS" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    case "$gw" in
        */odh-openshell-gateway:*) printf '%s\n' "${gw%/odh-openshell-gateway:*}/odh-openshell-cli:${gw##*:}" ;;
        *) return 1 ;;
    esac
}

oscli_pod_spec() {   # $1 image
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${OSCLI_POD}
  namespace: ${OSCLI_NS}
  labels:
    app.kubernetes.io/name: openshell-cli
    app.kubernetes.io/managed-by: rhoai-mass-aws-openshell-cli
spec:
  restartPolicy: Never
  activeDeadlineSeconds: ${OSCLI_TTL}
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: cli
      image: ${1}
      command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          d="\${HOME}/.config/openshell/gateways/openshell/mtls"
          mkdir -p "\$d"
          cp /var/run/openshell-mtls/ca.crt /var/run/openshell-mtls/tls.crt /var/run/openshell-mtls/tls.key "\$d/"
          chmod 600 "\$d/tls.key"
          openshell gateway add https://openshell.${OSCLI_NS}.svc:8080 --local --name openshell >/dev/null
          touch /tmp/ready
          exec sleep ${OSCLI_TTL}
      readinessProbe:
        exec:
          command: [test, -f, /tmp/ready]
        periodSeconds: 2
      env:
        - name: HOME
          value: /tmp
        - name: OPENSHELL_GATEWAY
          value: openshell
        - name: OPENSHELL_COLOR
          value: never
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 256Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: mtls
          mountPath: /var/run/openshell-mtls
          readOnly: true
  volumes:
    - name: tmp
      emptyDir: {}
    - name: mtls
      secret:
        secretName: openshell-client-tls
        defaultMode: 256
EOF
}

# Create the pod unless a running one exists; wait until it is Ready. A pod
# past its deadline, or otherwise finished, is replaced.
oscli_ensure_pod() {
    local phase image
    phase="$("$OC" get pods "$OSCLI_POD" -n "$OSCLI_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
        Running|Pending) ;;
        "") ;;
        *) "$OC" delete pods "$OSCLI_POD" -n "$OSCLI_NS" --ignore-not-found --wait=true >/dev/null
           phase="" ;;
    esac
    if [ -z "$phase" ]; then
        image="$(oscli_image)" || {
            echo "Error: no OpenShell gateway (StatefulSet ${OSCLI_NS}/openshell) on this cluster." >&2
            echo "       It is deployed by the openshell policy: set the openshell and agent-sandbox" >&2
            echo "       labels in the hub values, then check \"\$OC\" get policy -A | grep openshell" >&2
            return 1; }
        "$OC" get secrets openshell-client-tls -n "$OSCLI_NS" -o name >/dev/null 2>&1 || {
            echo "Error: no Secret ${OSCLI_NS}/openshell-client-tls (the gateway's mTLS client bundle)." >&2
            echo "       cert-manager issues it; check policy-openshell-gateway-ready." >&2
            return 1; }
        oscli_pod_spec "$image" | "$OC" apply -f - >/dev/null
        OSCLI_CREATED=1
        echo "==> Started pod ${OSCLI_NS}/${OSCLI_POD} (${image##*/})"
    fi
    "$OC" wait pods "$OSCLI_POD" -n "$OSCLI_NS" --for=condition=Ready --timeout=180s >/dev/null || {
        echo "Error: pod ${OSCLI_NS}/${OSCLI_POD} did not become Ready." >&2
        "$OC" describe pods "$OSCLI_POD" -n "$OSCLI_NS" 2>/dev/null | sed -n '/^Events:/,$p' >&2
        "$OC" logs "$OSCLI_POD" -n "$OSCLI_NS" 2>/dev/null | tail -5 >&2
        return 1; }
}

# Run the openshell CLI in the pod. Arguments pass through unchanged; the exit
# status is the CLI's. stdin is attached only when OSCLI_STDIN=1.
oscli_run() {
    if [ "${OSCLI_STDIN:-0}" = 1 ]; then
        "$OC" exec -i -n "$OSCLI_NS" "$OSCLI_POD" -- openshell "$@"
    else
        "$OC" exec -n "$OSCLI_NS" "$OSCLI_POD" -- openshell "$@"
    fi
}

oscli_delete() {
    "$OC" delete pods "$OSCLI_POD" -n "$OSCLI_NS" --ignore-not-found --wait=true >/dev/null
}

# Delete the pod only if this process created it, so a pod someone kept with
# --keep (or a run in another terminal) is not pulled out from under them.
oscli_cleanup() {
    [ "$OSCLI_CREATED" = 1 ] && oscli_delete
    return 0
}
