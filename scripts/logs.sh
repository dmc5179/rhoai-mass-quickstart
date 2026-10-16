#!/usr/bin/env bash
#
# logs.sh - show recent script runs and whether they passed.
#
# Usage: scripts/logs.sh [N]        list the last N runs (default 15)
#        scripts/logs.sh --failed   only failures
#        scripts/logs.sh --last     print the path of the newest log
#
# Every logged script ends its log with a "=== RESULT ... ===" line; this
# reads that.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N=15
ONLY_FAILED=0

case "${1:-}" in
    --failed) ONLY_FAILED=1 ;;
    --last)   ls -t "${ROOT}"/logs/*.log 2>/dev/null | head -1; exit 0 ;;
    --help|-h) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    '') ;;
    *) N="$1" ;;
esac

shopt -s nullglob
logs=("${ROOT}"/logs/*.log)
[ "${#logs[@]}" -gt 0 ] || { echo "No logs yet."; exit 0; }

printf '%-10s %-34s %s\n' STATUS LOG SUMMARY
# shellcheck disable=SC2012
ls -t "${ROOT}"/logs/*.log | head -"$N" | while read -r f; do
    result="$(grep -oE '=== RESULT (OK|FAILED) exit=[0-9]+' "$f" | tail -1 || true)"
    case "$result" in
        *OK*)     status="OK" ;;
        *FAILED*) status="FAILED" ;;
        *)        status="RUNNING?" ;;   # no footer: still going, or killed
    esac
    [ "$ONLY_FAILED" -eq 1 ] && [ "$status" != "FAILED" ] && continue
    # Last non-debug line gives a hint at what happened.
    summary="$(grep -vE "level=debug|^=== (RESULT|START)|^==> Logging" "$f" | grep -vE "^\s*$" | tail -1 | cut -c1-58)"
    printf '%-10s %-34s %s\n' "$status" "$(basename "$f")" "$summary"
done
