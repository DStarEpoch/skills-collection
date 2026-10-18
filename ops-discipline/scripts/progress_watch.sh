#!/usr/bin/env bash
# progress_watch.sh — one-shot progress check (meant for scheduled tasks;
# it never loops or sleeps itself).
# Usage: progress_watch.sh <logfile> <progress-regex> [stall-seconds]
# Output: latest matching lines + log age in seconds; exit 3 when stalled beyond threshold.
set -uo pipefail
LOG="${1:?usage: $0 <log> <progress-regex> [stall-sec]}"; RE="${2:?}"; STALL="${3:-600}"
[ -f "$LOG" ] || { echo "MISSING log: $LOG"; exit 2; }
grep -E "$RE" "$LOG" | tail -5
now=$(date +%s); mtime=$(stat -c %Y "$LOG"); age=$((now - mtime))
echo "log age: ${age}s (stall threshold ${STALL}s)"
[ "$age" -gt "$STALL" ] && { echo "STALL: no log progress for ${age}s"; exit 3; }
exit 0
