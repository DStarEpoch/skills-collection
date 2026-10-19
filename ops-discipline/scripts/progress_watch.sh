#!/usr/bin/env bash
# progress_watch.sh — one-shot progress check (meant for scheduled tasks;
# it never loops or sleeps itself).
# Usage: progress_watch.sh <logfile> <progress-regex> [stall-seconds] [extract-regex]
#
# Stall detection tracks whether the PROGRESS VALUE of the latest matching line advances,
# not the file mtime (heartbeat writes do not reset the clock).
# The progress value defaults to the whole line; if log lines carry per-line-varying
# fields (timestamps, counters), pass the 4th argument EXTRACT regex (grep -oE, first
# match, e.g. 'pct=[0-9]+') — otherwise timestamps defeat the hash and STALL never fires
# (the script warns on stderr).
#
# Clock model: within one boot, elapsed time uses /proc/uptime (NTP-step immune);
# across a boot change, it falls back to wall clock and says so. State is keyed by
# log+regex+extract, written atomically, flock-guarded when flock exists.
#
# Exit codes: 0 = advancing / baseline established / within stall threshold;
# 2 = insufficient evidence (missing log / no match / unwritable state / no hash tool);
# 3 = STALL.
set -uo pipefail
LOG="${1:?usage: $0 <log> <progress-regex> [stall-sec] [extract-regex]}"; RE="${2:?}"
STALL="${3:-600}"; EXTRACT="${4:-}"
case "$STALL" in ''|*[!0-9]*) echo "usage: stall-sec must be a positive integer" >&2; exit 2 ;; esac

HASH=cksum; command -v cksum >/dev/null 2>&1 || { HASH=sha256sum; command -v sha256sum >/dev/null 2>&1 || { HASH=md5sum; command -v md5sum >/dev/null 2>&1 || { echo "no hash tool (cksum/sha256sum/md5sum)" >&2; exit 2; }; }; }

STATE_DIR="${OPS_STATE_DIR:-${HOME:-/var/tmp}/.local/state/ops-skill}"
STATE="$STATE_DIR/progress_watch.$(printf '%s' "$LOG|$RE|$EXTRACT" | $HASH | cut -d' ' -f1).state"

[ -f "$LOG" ] || { echo "MISSING log: $LOG"; exit 2; }
grep -E "$RE" "$LOG" | tail -5
latest=$(grep -E "$RE" "$LOG" | tail -1)
[ -n "$latest" ] || { echo "NO-PROGRESS-MARKER: regex matched nothing in $LOG"; exit 2; }
if [ -n "$EXTRACT" ]; then
  value=$(printf '%s' "$latest" | grep -oE "$EXTRACT" | head -1)
  [ -n "$value" ] || { echo "EXTRACT-MISS: extract regex matched nothing in latest marker line"; exit 2; }
else
  value="$latest"
  echo "note: no extract regex given; timestamped lines defeat stall detection (see script header)" >&2
fi
hash=$(printf '%s' "$value" | $HASH | cut -d' ' -f1)
now=$(date +%s)
up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)

run_check() {
  prev_hash=""; prev_wall=0; prev_up=0; prev_boot=""
  [ -f "$STATE" ] && read -r prev_hash prev_wall prev_up prev_boot < "$STATE"
  if [ -n "$prev_hash" ] && [ "$prev_hash" = "$hash" ]; then
    if [ "$prev_boot" = "$boot" ] && [ "$up" -gt 0 ] && [ "$prev_up" -gt 0 ]; then
      age=$(( up - prev_up ))
    else
      age=$(( now - prev_wall ))
      echo "note: boot changed; age uses wall clock (includes downtime)"
    fi
    [ "$age" -lt 0 ] && age=0   # wall-clock step-back protection
    echo "progress value unchanged for ${age}s (stall threshold ${STALL}s)"
    [ "$age" -gt "$STALL" ] && { echo "STALL: progress value unchanged for ${age}s"; exit 3; }
    exit 0
  fi
  tmp="$STATE.tmp.$$"
  if ! printf '%s %s %s %s\n' "$hash" "$now" "$up" "$boot" > "$tmp" 2>/dev/null || ! mv "$tmp" "$STATE" 2>/dev/null; then
    echo "STATE-UNWRITABLE: cannot persist baseline to $STATE" >&2
    rm -f "$tmp" 2>/dev/null
    exit 2
  fi
  if [ -n "$prev_hash" ]; then echo "progress advancing (value changed)"; else echo "baseline established (first observation)"; fi
  exit 0
}
mkdir -p "$STATE_DIR" 2>/dev/null
# Supported hosts provide flock; acquisition failure returns 2 without updating state.
if command -v flock >/dev/null 2>&1; then
  if ! { exec 9>>"$STATE.lock" && flock -w 5 9; } 2>/dev/null; then
    echo "STATE-LOCK-FAILED: $STATE.lock (concurrent writer or unwritable)" >&2
    exit 2
  fi
fi
run_check
