#!/usr/bin/env bash
# mem_watch.sh — process memory monitoring (one-shot, meant for scheduled tasks).
# Usage: mem_watch.sh [RSS alert threshold MiB] (default 4096; confirm per host)
# Process set: PIDDIR (pidfile directory) preferred, else WATCH_PIDS (space separated).
# A configured-but-unreadable pid is exit 2 (unobservable ≠ fine).
# Cgroup: CGROUP=<path> (v2 memory.current/memory.max or v1 usage/limit) reports usage
# AND judges it: used >= 90% of the effective limit (tightest ancestor limit for v2)
# is OVER. Unreadable counters or zero/invalid limits are exit 2, never "unlimited".
# Exit codes: 0 = ok; 1 = bad args; 2 = observation failed; 3 = threshold crossed.
set -uo pipefail
LIMIT="${1:-4096}"
case "$LIMIT" in ''|*[!0-9]*) echo "usage: $0 [positive-integer MiB limit]" >&2; exit 1 ;; esac
echo "== $(date -u +%FT%TZ) mem watch (limit ${LIMIT} MiB) =="
rc=0
worse() { [ "$1" -gt "$rc" ] && rc=$1 || true; }
PIDS=""
if [ -n "${PIDDIR:-}" ] && [ -d "${PIDDIR:-/nonexistent}" ]; then
  PIDS=$(for f in "$PIDDIR"/*.pid; do [ -f "$f" ] && cat "$f" && echo; done)
  [ -z "$PIDS" ] && { echo "PIDDIR=$PIDDIR has no pidfiles"; worse 2; }
elif [ -n "${WATCH_PIDS:-}" ]; then
  PIDS="$WATCH_PIDS"
else
  echo "no process set configured (PIDDIR or WATCH_PIDS required)"; worse 2
fi
for pid in $PIDS; do
  case "$pid" in ''|*[!0-9]*) echo "invalid pid '$pid'"; worse 2; continue ;;
    0*) echo "invalid pid '$pid' (zero pid)"; worse 2; continue ;; esac
  if [ ! -r "/proc/$pid/status" ]; then
    if [ -d "/proc/$pid" ]; then echo "pid=$pid NOPERM (exists, unreadable)"; else echo "pid=$pid GONE"; fi
    worse 2; continue
  fi
  rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status")
  name=$(awk '/^Name:/{print $2}' "/proc/$pid/status")
  case "${rss_kb:-}" in
    ''|*[!0-9]*) echo "pid=$pid VmRSS unavailable (unobservable, not zero)"; worse 2; continue ;;
  esac
  rss_mib=$(( rss_kb / 1024 ))
  flag=""; [ "$rss_mib" -gt "$LIMIT" ] && { flag=" OVER"; worse 3; }
  echo "$name pid=$pid rss=${rss_mib}MiB$flag"
done
if [ -n "${CGROUP:-}" ]; then
  if [ -r "$CGROUP/memory.current" ]; then            # cgroup v2, walk ancestors for tightest limit
    cur=$(cat "$CGROUP/memory.current")
    best_pct=-1; best_where=""
    d="$CGROUP"
    unreadable=0
    while [ "$d" != "/" ] && [ "$d" != "." ]; do
      pct=""
      if [ -e "$d/memory.max" ] && [ ! -r "$d/memory.max" ]; then
        echo "WARN: $d memory.max exists but is unreadable (limit unobservable)" >&2
        unreadable=1; worse 2
      elif [ ! -e "$d/memory.max" ] && [ -e "$d/memory.current" ]; then
        echo "WARN: $d exposes memory.current but no memory.max (unobservable limit)" >&2
        unreadable=1; worse 2
      fi
      if [ -r "$d/memory.max" ]; then
        m=$(cat "$d/memory.max")
        if [ "$m" != "max" ]; then
          case "$m" in ''|*[!0-9]*) echo "WARN: unreadable memory.max at $d" >&2; worse 2; unreadable=1; break ;; esac
          [ "$m" -eq 0 ] && { echo "WARN: zero memory.max at $d" >&2; worse 2; break; }
          # the ancestor's own usage is required: a child's usage cannot prove ancestor pressure
          if [ ! -r "$d/memory.current" ]; then
            echo "WARN: $d has memory.max but unreadable memory.current (ancestor pressure unobservable)" >&2
            worse 2; unreadable=1
          else
            u=$(cat "$d/memory.current")
            pct=$(( u * 100 / m ))
          fi
          if [ -n "$pct" ] && [ "$pct" -gt "$best_pct" ]; then best_pct=$pct; best_where="$d (limit $((m/1048576))MiB)"; fi
        fi
      fi
      d=$(dirname "$d")
    done
    if [ "$best_pct" -ge 0 ]; then
      flag=""; [ "$best_pct" -ge 90 ] && { flag=" OVER"; worse 3; }
      echo "cgroup(v2) $CGROUP: used=$((cur/1048576))MiB tightest=${best_where} (${best_pct}%)$flag"
    elif [ "$unreadable" = 0 ]; then
      echo "cgroup(v2) $CGROUP: used=$((cur/1048576))MiB max=unlimited (no ancestor limit readable and none missing)"
    else
      echo "cgroup(v2) $CGROUP: used=$((cur/1048576))MiB limit UNKNOWN (see warnings)"
      worse 2
    fi
  elif [ -r "$CGROUP/memory.usage_in_bytes" ]; then   # cgroup v1
    cur=$(cat "$CGROUP/memory.usage_in_bytes"); max=$(cat "$CGROUP/memory.limit_in_bytes" 2>/dev/null || echo "")
    case "$max" in ''|*[!0-9]*) echo "WARN: unreadable memory.limit_in_bytes"; worse 2 ;; 
      *)
        if [ "$max" -ge 1152921504606846976 ]; then
          echo "cgroup(v1) $CGROUP: used=$((cur/1048576))MiB max=unlimited"
        elif [ "$max" -eq 0 ]; then
          echo "WARN: zero memory.limit_in_bytes" >&2; worse 2
        else
          pct=$((cur * 100 / max))
          flag=""; [ "$pct" -ge 90 ] && { flag=" OVER(${pct}% of limit)"; worse 3; }
          echo "cgroup(v1) $CGROUP: used=$((cur/1048576))MiB max=$((max/1048576))MiB (${pct}%)$flag"
        fi ;;
    esac
  else
    echo "WARN: CGROUP=$CGROUP has no readable memory counters" >&2; worse 2
  fi
fi
free -m | awk 'NR==2{printf "host: mem used %sMiB / %sMiB, avail %sMiB\n", $3, $2, $7}'
[ -f /proc/pressure/memory ] && head -2 /proc/pressure/memory
exit "$rc"
