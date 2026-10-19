#!/usr/bin/env bash
# health_snapshot.sh — one-shot health snapshot.
# Usage: health_snapshot.sh <pidfile-dir> <port-spec...>
# Port spec: <port>[@<addr>]            TCP connect probe (no HTTP assumption)
#            <port>/http[=<path>][@<addr>]   HTTP GET with status code
# port must be a decimal 1-65535; addr defaults to 127.0.0.1 (set it explicitly for
# services bound to a specific interface). Specs are validated, never shell-interpolated.
#
# Liveness discipline: strict positive-integer pid; kill -0 only after that.
# EPERM (process exists but not ours) is reported NOPERM, not DEAD; zombie = DEAD;
# pidfile older than the process start time = STALE-PIDFILE (PID reuse suspicion).
# Mounts come from MOUNTS (or SYSTEM_MOUNT + DATA_MOUNTS) in the env pin; each is
# verified as an actual mountpoint via mountinfo, not merely an existing path.
#
# Exit codes: 0 = all green; 2 = insufficient evidence (including a missing probe tool)
# (no pidfiles / NOPERM / STALE-PIDFILE / missing or unmounted mount / bad spec /
# MOUNTS unconfigured); 3 = hard failure (DEAD / TCP-CLOSED / HTTP bad status).
set -uo pipefail
PIDDIR="${1:?usage: $0 <pidfile-dir> <port[/http[=path]][@addr]...>}"; shift
rc=0
need2() { [ "$rc" -lt 2 ] && rc=2; }
hard() { rc=3; }

echo "== $(date -u +%FT%TZ) =="
echo "--- pidfile liveness:"
btime=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null || echo 0)
hz=$(getconf CLK_TCK 2>/dev/null || echo "")
[ -n "$hz" ] || echo "note: getconf CLK_TCK unavailable; STALE-PIDFILE check skipped (no reliable tick rate)"
found_pidfile=0
for f in "$PIDDIR"/*.pid; do
  [ -e "$f" ] || continue
  found_pidfile=1
  pid=$(cat "$f" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) echo "INVALID-PIDFILE $f (content: ${pid:-empty})"; need2; continue ;;
  esac
  # normalize leading zeros ("000123" is the same pid as "123"); 0 stays 0 and is rejected
  pid=$((10#$pid))
  if [ "$pid" -eq 0 ]; then
    echo "INVALID-PIDFILE $f (zero pid — kill would mean the process group)"; need2; continue
  fi
  if kill -0 "$pid" 2>/dev/null; then
    # comm (field 2) may contain BOTH spaces and ')' — strip up to the LAST ') '
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null || echo "")
    rest="${stat_line##*) }"
    state=$(printf '%s' "$rest" | awk '{print $1}')
    if [ -z "$stat_line" ] || [ "$rest" = "$stat_line" ]; then
      echo "UNKNOWN $(basename "$f") pid=$pid (stat unreadable/malformed)"; need2; continue
    fi
    if [ "$state" = "Z" ]; then
      echo "DEAD   $(basename "$f") pid=$pid (zombie)"; hard; continue
    fi
    # stale pidfile: pidfile older than process start -> likely PID reuse
    start_ticks=$(printf '%s' "$rest" | awk '{print $20}')
    if [ -n "$hz" ] && [ "$hz" -gt 0 ] && [ "$btime" -gt 0 ] && [ "$start_ticks" -gt 0 ]; then
      start_epoch=$(( btime + start_ticks / hz ))
      pf_mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
      if [ "$pf_mtime" -gt 0 ] && [ "$pf_mtime" -lt "$((start_epoch - 2))" ]; then
        echo "STALE-PIDFILE $(basename "$f") pid=$pid (pidfile predates process start; PID reuse?)"; need2; continue
      fi
    fi
    echo "ALIVE  $(basename "$f") pid=$pid"
  else
    if [ -d "/proc/$pid" ]; then
      echo "NOPERM $(basename "$f") pid=$pid (exists but not signal-able by us)"; need2
    else
      echo "DEAD   $(basename "$f") pid=$pid"; hard
    fi
  fi
done
[ "$found_pidfile" = 0 ] && { echo "no pidfiles in $PIDDIR"; need2; }

echo "--- ports:"
for spec in "$@"; do
  addr="127.0.0.1"
  case "$spec" in *@*) addr="${spec##*@}"; spec="${spec%@*}" ;; esac
  case "$addr" in *[!A-Za-z0-9.:_%-]*) echo "port spec '$spec': invalid addr"; need2; continue ;; esac
  port="${spec%%/*}"; proto="${spec#*/}"; [ "$proto" = "$spec" ] && proto="tcp"
  case "$port" in ''|*[!0-9]*) echo "port spec '$spec': invalid port"; need2; continue ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo "port spec '$spec': port out of range"; need2; continue; }
  case "$proto" in
    tcp)
      # address and port go through positional parameters — never shell-interpolated
      if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$addr" "$port" 2>/dev/null; then
        echo "port $port@$addr: TCP-OPEN"
      else
        echo "port $port@$addr: TCP-CLOSED"; hard
      fi
      ;;
    http|http=*)
      if ! command -v curl >/dev/null 2>&1; then
        echo "port $port: curl unavailable (tool missing; severity not yet known)"; need2; continue
      fi
      path="/"; [ "${proto#http=}" != "$proto" ] && path="${proto#http=}"
      code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 -- "http://$addr:$port$path" 2>/dev/null || echo ERR)
      echo "port $port@$addr: HTTP $path -> $code"
      case "$code" in 2[0-9][0-9]|3[0-9][0-9]) ;; *) hard ;; esac
      ;;
    *) echo "port spec '$spec': unknown proto (use tcp or http)"; need2 ;;
  esac
done

echo "--- load/mem/disk:"
uptime
free -g | awk 'NR<=2'
mounts="${MOUNTS:-${SYSTEM_MOUNT:+${SYSTEM_MOUNT} }${DATA_MOUNTS:-}}"
if [ -z "${mounts// /}" ]; then
  echo "MOUNTS not configured — confirm the disk layout with the user into the env pin first (SKILL.md §0.5)"
  need2
else
  for mp in $mounts; do
    if ! awk -v m="$mp" '$5==m{found=1} END{exit !found}' /proc/self/mountinfo 2>/dev/null; then
      echo "NOT-MOUNTED: $mp (path may exist but nothing is mounted there)"; need2; continue
    fi
    line=$(df -h "$mp" 2>/dev/null | awk 'NR==2')
    if [ -n "$line" ]; then echo "$line"; else echo "MISSING mount: $mp"; need2; fi
  done
fi
exit "$rc"
