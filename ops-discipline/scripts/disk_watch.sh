#!/usr/bin/env bash
# disk_watch.sh — disk usage + growth rate (one-shot, meant for scheduled tasks;
# the rate comes from a state file written by the previous run).
# Usage: disk_watch.sh <mountpoint> [free-GiB-alert-threshold] [statefile]
set -uo pipefail
MP="${1:?usage: $0 <mountpoint> [free-gib-alert] [statefile]}"
ALERT="${2:-100}"
STATE="${3:-/tmp/disk_watch.$(echo "$MP" | tr '/' '_').state}"
read -r used_gib avail_gib < <(df -BG --output=used,avail "$MP" | tail -1 | tr -d 'G')
now=$(date +%s)
rate=""
if [ -f "$STATE" ]; then
  read -r prev_used prev_ts < "$STATE"
  dt=$((now - prev_ts)); du_=$((used_gib - prev_used))
  [ "$dt" -gt 0 ] && rate=$(awk "BEGIN{printf \"%.2f\", $du_/($dt/3600)}")
fi
echo "$used_gib $now" > "$STATE"
echo "$MP: used=${used_gib}GiB avail=${avail_gib}GiB${rate:+ growth=${rate}GiB/h}"
[ "$avail_gib" -lt "$ALERT" ] && { echo "ALERT: ${MP} below ${ALERT}GiB free"; exit 3; }
exit 0
