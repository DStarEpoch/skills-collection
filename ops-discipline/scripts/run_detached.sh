#!/usr/bin/env bash
# run_detached.sh — start a long task detached from the session.
# Usage: run_detached.sh <logfile> <cmd...>
# Discipline: long tasks never hold the foreground; logs land at a fixed path.
# Probe outcomes, honestly distinguished:
#   launched  — still alive after 1s (long-running task)
#   completed — exited within 1s with code 0 (a fast successful task, NOT a failure)
#   FAILED    — start failure / fast non-zero exit / unwritable log, exit 1
#   UNTRACKED — task started but its identity could not be persisted, exit 2
#
# Guards:
#   - the whole wrapper's stdio is redirected (an agent runner's captured pipe is never held)
#   - a strict flock on <log>.lock wraps check+launch, so two concurrent starts cannot both
#     pass the pre-check (the pid only exists after the 1s probe; locking closes that gap)
#   - a live task already registered on the same log -> ALREADY-RUNNING, exit 2
#   - .pid/.exit writes are checked; failing to persist identity is exit 2, never silent 0
# Note: the recorded pid is the launcher shim; use it for liveness, not for signalling
# the payload — real service management belongs to a supervisor.
set -uo pipefail
LOG="$1"; shift
[ $# -ge 1 ] || { echo "usage: $0 <logfile> <cmd...>" >&2; exit 2; }
command -v "$1" >/dev/null 2>&1 || { echo "FAILED: command not found: $1" >&2; exit 1; }
touch "$LOG" 2>/dev/null || { echo "FAILED: log not writable: $LOG" >&2; exit 1; }

# --- critical section: check-then-launch under an exclusive lock -----------------
{ exec 7>>"$LOG.lock"; } 2>/dev/null || { echo "FAILED: lock file not writable: $LOG.lock" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAILED: flock unavailable (cannot serialize launch)" >&2; exit 2; }
flock -w 5 7 || { echo "FAILED: could not acquire $LOG.lock" >&2; exit 2; }
if [ -f "$LOG.pid" ]; then
  old=$(cat "$LOG.pid" 2>/dev/null || echo "")
  case "$old" in ''|*[!0-9]*) : ;;
    *)
      if kill -0 "$old" 2>/dev/null; then
        echo "ALREADY-RUNNING: pid=$old registered on $LOG" >&2
        exit 2
      fi ;;
  esac
fi
# reserve the identity BEFORE launch so a concurrent starter sees a live pid immediately
printf '%s\n' "$$" > "$LOG.pid" 2>/dev/null || { echo "FAILED: cannot reserve $LOG.pid" >&2; exit 2; }
# per-run exit record: a shared "$LOG.exit" would let one run overwrite another's result
EXITF="$LOG.exit.$$"
rm -f "$EXITF"
# 7>&- keeps the child from inheriting the lock fd (an inherited fd would hold the lock
# for the payload's whole lifetime and stall the next start)
LOGF="$LOG" EXITF="$EXITF" setsid nohup bash -c '"$@" >>"$LOGF" 2>&1; echo "$?" > "$EXITF"' bash "$@" </dev/null >>"$LOG" 2>&1 7>&- &
pid=$!
if ! printf '%s\n' "$pid" > "$LOG.pid" 2>/dev/null; then
  echo "UNTRACKED: pid=$pid launched but $LOG.pid could not be persisted" >&2
  exit 2
fi
exec 7>&-  # release the lock; the probe below runs outside it
# --- probe ----------------------------------------------------------------------
sleep 1
if [ -f "$EXITF" ]; then
  rc=$(cat "$EXITF")
  # cleanup must be lock-held AND ownership-checked: another run may have registered
  # its pid in the meantime (the probe runs outside the launch lock)
  if ! { exec 7>>"$LOG.lock" && flock -w 5 7; } 2>/dev/null; then
    echo "UNTRACKED: cleanup lock unavailable; preserving $LOG.pid and $EXITF" >&2
    exit 2
  fi
  if [ "$(cat "$LOG.pid" 2>/dev/null)" = "$pid" ]; then rm -f "$LOG.pid"; fi
  rm -f "$EXITF"
  exec 7>&-
  if [ "$rc" = 0 ]; then
    echo "completed pid=$pid exit=0 log=$LOG"
    exit 0
  fi
  echo "FAILED: $* exited rc=$rc; see $LOG" >&2
  exit 1
fi
if kill -0 "$pid" 2>/dev/null; then
  echo "launched pid=$pid log=$LOG"
  exit 0
fi
echo "FAILED: $* vanished without exit record; see $LOG" >&2
exit 1
