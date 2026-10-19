#!/usr/bin/env bash
# disk_watch.sh — disk usage + growth rate (one-shot, meant for scheduled tasks).
# Usage: disk_watch.sh <mountpoint> [free-GiB-alert] [rate-alert-GiB/h] [statefile]
# Measurements and comparisons are in BYTES (GiB rounding never hides a threshold);
# GiB only in display. The mountpoint is verified against mountinfo first — an existing
# path with nothing mounted is NOT evidence of a healthy data disk.
# Rate model: boot-aware like progress_watch — same boot uses /proc/uptime deltas;
# a boot change re-baselines (no cross-reboot rate). Stale state (>24h) also re-baselines.
# State is atomic-write + best-effort flock.
# Exit codes: 0 = ok; 2 = insufficient evidence (unmounted/unreadable/unwritable/arg);
# 3 = floor breached or growth rate above the alert.
set -uo pipefail
MP="${1:?usage: $0 <mountpoint> [free-gib-alert] [rate-alert-gib-per-h] [statefile]}"
ALERT="${2:-${DISK_FLOOR_GIB:-100}}"
RATE_ALERT="${3:-}"
STATE="${4:-}"
case "$ALERT" in ''|*[!0-9]*) echo "free-gib-alert must be a non-negative integer" >&2; exit 2 ;; esac
case "$RATE_ALERT" in ''|*[!0-9]*) [ -z "$RATE_ALERT" ] || { echo "rate-alert must be a non-negative integer" >&2; exit 2; } ;; esac

awk -v m="$MP" '$5==m{found=1} END{exit !found}' /proc/self/mountinfo 2>/dev/null \
  || { echo "NOT-MOUNTED: $MP (existing path is not a mount; refusing to measure the wrong fs)"; exit 2; }

# bytes, GNU and POSIX paths
if df -B1 --output=used,avail "$MP" >/dev/null 2>&1; then
  read -r used_b avail_b < <(df -B1 --output=used,avail "$MP" | awk 'NR==2{gsub(/B/,""); print $1, $2}')
else
  read -r used_b avail_b < <(df -kP "$MP" 2>/dev/null | awk 'NR==2{print $3*1024, $4*1024}')
fi
case "${used_b:-}/${avail_b:-}" in
  ''/*|*/''|*[!0-9/]*) echo "MEASURE-FAILED: cannot read usage for $MP" >&2; exit 2 ;;
esac

if [ -z "$STATE" ]; then
  STATE_DIR="${OPS_STATE_DIR:-${HOME:-/var/tmp}/.local/state/ops-skill}"
  mkdir -p "$STATE_DIR" || { echo "STATE-UNWRITABLE: $STATE_DIR" >&2; exit 2; }
  STATE="$STATE_DIR/disk_watch.$(printf '%s' "$MP" | cksum | cut -d' ' -f1).state"
fi
if command -v flock >/dev/null 2>&1; then
  if ! { exec 8>>"$STATE.lock" && flock -w 5 8; } 2>/dev/null; then
    echo "STATE-LOCK-FAILED: $STATE.lock (concurrent writer or unwritable)" >&2
    exit 2
  fi
fi

now=$(date +%s)
up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)

rate_note=""
if [ -f "$STATE" ]; then
  read -r prev_used prev_wall prev_up prev_boot < "$STATE" 2>/dev/null || prev_used=""
  case "${prev_used:-}" in ''|*[!0-9]*) prev_used="" ;; esac
  if [ -n "$prev_used" ]; then
    if [ "$prev_boot" != "$boot" ]; then
      rate_note="boot changed; re-baselining (no rate this run)"
    else
      dt=$(( up - prev_up )); [ "$dt" -le 0 ] && dt=$(( now - prev_wall ))
      [ "$dt" -lt 0 ] && dt=0
      if [ "$dt" -gt 86400 ]; then
        rate_note="state older than 24h; re-baselining"
      elif [ "$dt" -gt 0 ]; then
        # compare in full precision first; only the display is rounded
        gib_h=$(awk "BEGIN{printf \"%.2f\", ($used_b-$prev_used)/1073741824/($dt/3600)}")
        rate_note="growth=${gib_h}GiB/h"
        if [ -n "$RATE_ALERT" ] && awk "BEGIN{exit !((($used_b-$prev_used)/1073741824/($dt/3600)) > $RATE_ALERT)}"; then
          echo "$MP: growth ${gib_h}GiB/h above alert ${RATE_ALERT}GiB/h"
          echo "$used_b $now $up $boot" > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"
          exit 3
        fi
      fi
    fi
  fi
fi
echo "$used_b $now $up $boot" > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE" \
  || { echo "STATE-UNWRITABLE: $STATE" >&2; rm -f "$STATE.tmp.$$"; exit 2; }

used_gib=$(awk "BEGIN{printf \"%.1f\", $used_b/1073741824}")
avail_gib=$(awk "BEGIN{printf \"%.1f\", $avail_b/1073741824}")
avail_floor_b=$(( ALERT * 1073741824 ))
echo "$MP: used=${used_gib}GiB avail=${avail_gib}GiB${rate_note:+ $rate_note}"
[ "$avail_b" -lt "$avail_floor_b" ] && { echo "ALERT: ${MP} below ${ALERT}GiB free"; exit 3; }
exit 0
