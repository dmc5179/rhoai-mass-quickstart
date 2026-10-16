# lib-logging.sh - tee a script's output to a timestamped log file.
#
# Source this, then call start_logging before doing any real work:
#
#     ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#     ORIG_ARGS=("$@")
#     . "${ROOT}/scripts/lib-logging.sh"
#     start_logging "my-prefix" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
#
# Everything after that point goes to the terminal and to
# logs/<prefix>-<timestamp>.log, and the log ends with a machine-readable
# footer giving the exit status.
#
# Implemented by re-running the script as the child of a pipeline rather than
# with `exec > >(tee ...)`. With process substitution the script can exit
# before tee has flushed, which silently truncates both the log and the
# terminal output - exactly when something has gone wrong and the last lines
# matter most. PIPESTATUS carries the real exit status back out.

start_logging() {
    local prefix="$1" script="$2"
    shift 2

    # Already inside the wrapped child: install the footer and return.
    if [ -n "${_LOG_WRAPPED:-}" ]; then
        trap '_log_footer $?' EXIT
        echo "==> Logging to ${LOG_FILE}"
        echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) $(basename "$script") $* ==="
        return 0
    fi

    mkdir -p "${ROOT}/logs"
    LOG_FILE="${ROOT}/logs/${prefix}-$(date +%Y%m%d-%H%M%S).log"
    export LOG_FILE _LOG_WRAPPED=1

    # set -e must be off around the pipeline: with pipefail a failing child
    # would abort this function immediately, skipping the summary below.
    local rc=0
    set +e
    set -o pipefail
    "$script" "$@" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
    set -e

    # Repeat the verdict on the terminal after tee has drained, so it is the
    # last thing on screen even when the script printed a wall of output.
    if [ "$rc" -eq 0 ]; then
        echo "--- OK: ${LOG_FILE}"
    else
        echo "--- FAILED (exit ${rc}): ${LOG_FILE}" >&2
    fi
    exit "$rc"
}

# Written inside the wrapped child, so it lands in the log itself. Keep the
# format stable: scripts/logs.sh greps for it.
_log_footer() {
    local rc="$1"
    if [ "$rc" -eq 0 ]; then
        echo "=== RESULT OK exit=0 $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    else
        echo "=== RESULT FAILED exit=${rc} $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    fi
}
