#!/usr/bin/env bash
# evidence_snapshot.sh — one-command anomaly scene preservation.
# Preserve first, diagnose second, act last.
# Usage: evidence_snapshot.sh <evidence-root> <topic> [logfiles...]
set -uo pipefail
ROOT="${1:?usage: $0 <evidence-root> <topic> [logfiles...]}"; TOPIC="${2:?}"; shift 2
TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$ROOT/$TOPIC/$TS"
mkdir -p "$DEST"
{
  date -u +%FT%TZ
  echo "--- uptime"; uptime
  echo "--- df"; df -h
  echo "--- free"; free -m
} > "$DEST/host.txt"
ps aux > "$DEST/ps-aux.txt"
docker ps -a > "$DEST/docker-ps.txt" 2>/dev/null || true
for f in "$@"; do
  [ -f "$f" ] && cp -a "$f" "$DEST/$(basename "$f")"
done
echo "evidence: $DEST"
