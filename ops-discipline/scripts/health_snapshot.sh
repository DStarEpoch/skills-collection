#!/usr/bin/env bash
# health_snapshot.sh — one-shot health snapshot.
# Usage: health_snapshot.sh <pidfile-dir> <ports (space separated)>
# Discipline: liveness is pidfile + kill -0 only, never pgrep -f.
set -uo pipefail
PIDDIR="${1:?usage: $0 <pidfile-dir> <ports...>}"; shift
echo "== $(date -u +%FT%TZ) =="
echo "--- pidfile liveness:"
for f in "$PIDDIR"/*.pid; do
  [ -e "$f" ] || continue
  pid=$(cat "$f")
  if kill -0 "$pid" 2>/dev/null; then echo "ALIVE  $(basename "$f") pid=$pid"; else echo "DEAD   $(basename "$f") pid=$pid"; fi
done
echo "--- ports:"
for p in "$@"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "http://localhost:$p/" 2>/dev/null || echo ERR)
  echo "port $p: $code"
done
echo "--- load/mem/disk:"
uptime
free -g | awk 'NR<=2'
df -h / /data 2>/dev/null | awk 'NR==1 || /^\/dev/'
