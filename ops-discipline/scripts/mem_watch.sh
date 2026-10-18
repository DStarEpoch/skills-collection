#!/usr/bin/env bash
# mem_watch.sh — process memory monitoring (one-shot, meant for scheduled tasks).
# Usage: mem_watch.sh [RSS alert threshold MiB] (default 4096)
# Lists actual RSS of managed processes (from pidfiles); exit 3 when over threshold.
set -uo pipefail
LIMIT="${1:-4096}"
echo "== $(date -u +%FT%TZ) mem watch (limit ${LIMIT} MiB) =="
over=0
# Managed process set: prefer PIDDIR (env var pointing at the pidfile dir); else WATCH_PIDS
PIDS="${WATCH_PIDS:-}"
if [ -z "$PIDS" ] && [ -n "${PIDDIR:-}" ] && [ -d "${PIDDIR:-/nonexistent}" ]; then
  PIDS=$(for f in "$PIDDIR"/*.pid; do [ -f "$f" ] && cat "$f" && echo; done)
fi
for pid in $PIDS; do
  [ -r "/proc/$pid/status" ] || continue
  rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status")
  name=$(awk '/^Name:/{print $2}' "/proc/$pid/status")
  rss_mib=$((rss_kb / 1024))
  flag=""; [ "$rss_mib" -gt "$LIMIT" ] && { flag=" OVER"; over=1; }
  echo "$name pid=$pid rss=${rss_mib}MiB$flag"
done
# Host-wide pressure
free -m | awk 'NR==2{printf "host: mem used %sMiB / %sMiB, avail %sMiB\n", $3, $2, $7}'
[ -f /proc/pressure/memory ] && cat /proc/pressure/memory | head -2
[ "$over" = 1 ] && exit 3 || exit 0
