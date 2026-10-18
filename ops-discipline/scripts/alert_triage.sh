#!/usr/bin/env bash
# alert_triage.sh — alert triage: list firing alerts and compare against the known-noise list.
# Usage: KNOWN_FILE=<known-list-file> alert_triage.sh <command producing alert JSON...>
# Known-list format: one alert name per line (# starts a comment).
# Exit codes: 0 = all known; 3 = unknown alert present (escalate).
set -uo pipefail
KNOWN_FILE="${KNOWN_FILE:-/dev/null}"
out=$("$@")
echo "$out"
unknown=0
for name in $(echo "$out" | grep -oE '"alertname"[: ]+"[^"]+"' | sed 's/.*"alertname"[: ]*"//;s/"//' | sort -u); do
  if ! grep -qxF "$name" "$KNOWN_FILE" 2>/dev/null; then
    echo "UNKNOWN-ALERT: $name"
    unknown=1
  fi
done
[ "$unknown" = 1 ] && exit 3 || exit 0
