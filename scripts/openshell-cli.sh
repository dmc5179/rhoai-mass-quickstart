#!/usr/bin/env bash
#
# openshell-cli.sh - run the OpenShell CLI against the cluster's gateway from a
#                    pod inside the cluster, with no openshell binary installed.
#
# Usage: scripts/openshell-cli.sh [--keep] [--stdin] -- <openshell arguments>
#        scripts/openshell-cli.sh shell
#        scripts/openshell-cli.sh delete
#        scripts/openshell-cli.sh --dry-run
#
#   -- <args>   start the pod if needed, wait until it is Ready, run
#               `openshell <args>` in it, and delete the pod afterwards if this
#               run created it. The exit status is the CLI's.
#   --keep      leave the pod running, so the next call starts instantly.
#   --stdin     pass this script's stdin to the CLI, for arguments such as
#               `--policy /dev/stdin`. Off by default, so an automated caller
#               whose stdin never closes cannot hang a command.
#   shell       an interactive shell in the pod (the CLI is `openshell`); the
#               pod is kept. Not logged: logging would take the terminal away.
#   delete      remove the pod.
#   --dry-run   print the pod spec this cluster would get, and change nothing.
#
# Examples:
#   scripts/openshell-cli.sh -- status
#   scripts/openshell-cli.sh --keep -- sandbox list
#   scripts/openshell-cli.sh -- sandbox create --name demo --template rhoai-maas \
#       --provider rhoai-maas --no-tty --detach -- sleep 900
#
# The pod signs in with the gateway's mTLS client bundle, a platform-admin
# identity while OIDC is off, so this needs a cluster admin's kubeconfig. It
# deletes itself after an hour whatever happens. Details:
# scripts/lib-openshell-cli.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORIG_ARGS=("$@")
KEEP=0
STDIN=0
MODE=""
CLI_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)     KEEP=1; shift ;;
        --stdin)    STDIN=1; shift ;;
        --dry-run)  MODE=dry-run; shift ;;
        shell)      MODE=shell; shift ;;
        delete)     MODE=delete; shift ;;
        --)         shift; MODE=run; CLI_ARGS=("$@"); break ;;
        -h|--help)  sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "openshell-cli.sh: unknown option '$1' (CLI arguments go after --)" >&2; exit 2 ;;
    esac
done
[ -n "$MODE" ] || { sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 2; }
if [ "$MODE" = run ] && [ "${#CLI_ARGS[@]}" -eq 0 ]; then
    echo "openshell-cli.sh: nothing to run after --" >&2; exit 2
fi

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"

# The shell is interactive; lib-logging re-runs the script under tee, which
# would leave it without a terminal. Everything else is logged.
if [ "$MODE" != shell ]; then
    . "${ROOT}/scripts/lib-logging.sh"
    start_logging "openshell-cli" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG
"$OC" get --raw /readyz >/dev/null 2>&1 || { echo "Error: cluster API not reachable." >&2; exit 1; }

. "${ROOT}/scripts/lib-openshell-cli.sh"

case "$MODE" in
    dry-run)
        image="$(oscli_image)" || {
            echo "Error: no OpenShell gateway (StatefulSet ${OSCLI_NS}/openshell) on this cluster." >&2
            exit 1; }
        oscli_pod_spec "$image"
        echo "(dry run: nothing created)"
        ;;
    delete)
        oscli_delete
        echo "==> Deleted pod ${OSCLI_NS}/${OSCLI_POD} (if it existed)"
        ;;
    shell)
        oscli_ensure_pod
        echo "==> Interactive shell in ${OSCLI_NS}/${OSCLI_POD}. The pod is kept; remove it with:"
        echo "    scripts/openshell-cli.sh delete"
        "$OC" exec -it -n "$OSCLI_NS" "$OSCLI_POD" -- /bin/bash
        ;;
    run)
        # One EXIT trap for both jobs: start_logging installed the log footer
        # as the EXIT trap, and a second trap statement would replace it.
        on_exit() { local rc=$?; oscli_cleanup; _log_footer "$rc"; }
        [ "$KEEP" = 1 ] || trap on_exit EXIT
        oscli_ensure_pod
        OSCLI_STDIN="$STDIN"
        rc=0
        oscli_run "${CLI_ARGS[@]}" || rc=$?
        [ "$KEEP" = 1 ] && echo "==> Pod ${OSCLI_NS}/${OSCLI_POD} kept (--keep)"
        exit "$rc"
        ;;
esac
