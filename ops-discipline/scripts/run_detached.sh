#!/usr/bin/env bash
# run_detached.sh — start a long task detached from the session.
# Usage: run_detached.sh <logfile> <cmd...>
# Discipline: long tasks never hold the foreground; logs land at a fixed path;
# the launch pid is printed and saved next to the log.
set -uo pipefail
LOG="$1"; shift
[ $# -ge 1 ] || { echo "usage: $0 <logfile> <cmd...>" >&2; exit 2; }
setsid nohup "$@" > "$LOG" 2>&1 < /dev/null &
pid=$!
echo "launched pid=$pid log=$LOG"
echo "$pid" > "$LOG.pid"
