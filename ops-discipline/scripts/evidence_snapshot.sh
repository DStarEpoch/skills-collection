#!/usr/bin/env bash
# evidence_snapshot.sh — one-command anomaly scene preservation.
# Preserve first, diagnose second, act last.
# Usage: evidence_snapshot.sh <evidence-root> <topic> [logfiles...]
# Optional env:
#   STATE_PATHS="<pidfile/lock/state dirs, space separated>" — recursively preserved
#   EVIDENCE_MAX_MIB (default 512) — HARD payload budget across host/ps/docker/locks
#     output, logfiles, and state files. Reads are size-bounded; manifest and temporary
#     enumeration metadata are excluded. Anything skipped or truncated is recorded.
#
# Contract (one channel for enumeration, copy, budget, manifest):
#   - copies are read-bounded (head -c <measured size>): a file growing during the
#     snapshot cannot exceed its charge
#   - state copies are anchored to the confirmed state root ($d/$rel) — never resolved
#     against the caller's CWD
#   - directory arguments to the logfile list are rejected (never recursively copied)
#   - Docker is collected with an explicit argv-free --format only; if that fails we
#     record "unavailable" and DO NOT fall back to the COMMAND column
#   - find enumeration status is checked: a partial listing is exit 2, even when some
#     files were copied
#   - ps uses safe columns only (argv is where secrets live)
#
# Exit codes: 0 = complete; 2 = incomplete/failed (see MANIFEST.txt).
set -uo pipefail
ROOT="${1:?usage: $0 <evidence-root> <topic> [logfiles...]}"; TOPIC="${2:?}"; shift 2
case "$TOPIC" in *..*|*/*|-*|"") echo "invalid topic: $TOPIC" >&2; exit 2 ;; esac
max_mib="${EVIDENCE_MAX_MIB:-512}"
case "$max_mib" in ''|*[!0-9]*) echo "EVIDENCE_MAX_MIB must be an integer from 0 to 1048576" >&2; exit 2 ;; esac
[ "${#max_mib}" -le 7 ] && [ "$max_mib" -le 1048576 ] || { echo "EVIDENCE_MAX_MIB out of range" >&2; exit 2; }
umask 077
TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$ROOT/$TOPIC/$TS.$$"
if ! mkdir -p "$ROOT/$TOPIC" 2>/dev/null || ! mkdir "$DEST" 2>/dev/null; then
  echo "FAILED: cannot create unique evidence dir $DEST" >&2; exit 2
fi
rc=0
budget_kib=$(( 10#$max_mib * 1024 ))
spent_kib=0
left_kib() { echo $(( budget_kib - spent_kib )); }
charge() { spent_kib=$(( spent_kib + $1 )); }

# Bound command output too; a large process/container table cannot overrun the budget.
capture_cmd() { # name command...
  local name="$1"; shift
  local left cap b
  left=$(left_kib)
  if [ "$left" -le 0 ]; then echo "SKIPPED $name (budget exhausted)"; rc=2; return 1; fi
  cap=$(( left * 1024 ))
  "$@" 2>/dev/null | head -c "$cap" > "$DEST/$name" 2>/dev/null
  local -a codes=("${PIPESTATUS[@]}")
  b=$(stat -c %s "$DEST/$name" 2>/dev/null || echo 0)
  charge $(( (b + 1023) / 1024 ))
  if [ "${codes[1]}" -ne 0 ]; then
    echo "INCOMPLETE $name (capture write failed)"; rc=2; return 1
  fi
  if [ "$b" -ge "$cap" ]; then
    echo "INCOMPLETE $name (payload budget reached; kept $b bytes)"; rc=2; return 1
  fi
  if [ "${codes[0]}" -ne 0 ]; then
    echo "UNAVAILABLE $name (command rc=${codes[0]}; kept $b bytes)"
    [ "$b" -eq 0 ] || rc=2
    return 1
  fi
  return 0
}

echo "# evidence manifest $TS pid=$$" > "$DEST/MANIFEST.txt" || { echo "FAILED: manifest not writable" >&2; exit 2; }
{
  echo "## host capture"
  capture_cmd host.txt bash -ec 'date -u +%FT%TZ; echo "--- uptime"; uptime; echo "--- df"; df -h; echo "--- free"; free -m' || rc=2
  # argv-free process tables (secrets live in argv; see SKILL.md secret hygiene)
  capture_cmd ps-safe.txt ps -eo pid,ppid,user,stat,%cpu,%mem,etimes,comm || rc=2
  # Docker: explicit safe columns only. No fallback to COMMAND (argv leak).
  if capture_cmd docker-ps.txt docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}'; then
    :
  else
    echo "docker unavailable (safe format failed; argv deliberately not collected)"
  fi
  capture_cmd proc-locks.txt cat /proc/locks || echo "proc-locks unavailable"

  echo "## logfiles"
  for f in "$@"; do
    if [ -d "$f" ]; then
      printf 'REJECTED %s (directory, not recursively copied)\n' "$f"; rc=2; continue
    fi
    [ -e "$f" ] || { printf 'MISSING %s\n' "$f"; rc=2; continue; }
    size=$(stat -Lc %s "$f" 2>/dev/null || echo "")
    case "$size" in ''|*[!0-9]*) printf 'MISSING %s (size unreadable)\n' "$f"; rc=2; continue ;; esac
    kib=$(( (size + 1023) / 1024 ))
    left=$(left_kib)
    if [ "$left" -le 0 ]; then printf 'SKIPPED %s (budget exhausted)\n' "$f"; rc=2; continue; fi
    enc="$(printf '%s' "$f" | sed 's|^/||; s|/|__|g').$(printf '%s' "$f" | cksum | cut -d' ' -f1)"
    if [ "$kib" -gt "$left" ]; then
      # Read-bounded head copy of exactly what the remaining payload budget allows.
      keep=$(( left * 1024 ))
      if head -c "$keep" "$f" > "$DEST/$enc.head${left}KiB" 2>/dev/null; then
        charge "$left"
        printf 'truncated-head %s -> %s (budget: kept %sKiB of %sKiB)\n' "$f" "$enc" "$left" "$kib"
      else
        printf 'MISSING %s (budget truncation failed)\n' "$f"; rc=2
      fi
    else
      # read bounded by the measured size: a growing file cannot overrun its charge
      if head -c "$size" "$f" > "$DEST/$enc" 2>/dev/null; then
        charge $(( ($(stat -c %s "$DEST/$enc" 2>/dev/null || echo 0) + 1023) / 1024 ))
        printf 'copied %s -> %s (%s bytes)\n' "$f" "$enc" "$size"
      else
        printf 'MISSING %s (copy failed)\n' "$f"; rc=2
      fi
    fi
  done

  echo "## state paths"
  for d in ${STATE_PATHS:-}; do
    if [ ! -d "$d" ]; then printf 'MISSING state dir %s\n' "$d"; rc=2; continue; fi
    sub="$DEST/state.$(printf '%s' "$d" | sha256sum | cut -d' ' -f1)"
    mkdir -p "$sub" || { printf 'MISSING state dir %s (mkdir failed)\n' "$d"; rc=2; continue; }
    list=$(mktemp) || { printf 'MISSING state dir %s (mktemp failed)\n' "$d"; rc=2; continue; }
    ( cd "$d" && find . -type f -print0 2>/dev/null ) > "$list"
    enum_rc=$?
    if [ "$enum_rc" -ne 0 ]; then
      printf 'ENUMERATION-FAILED %s (find rc=%s; listing may be partial)\n' "$d" "$enum_rc"; rc=2
    fi
    copied=0; skipped=0; failed=0
    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      [ -n "$rel" ] || continue
      fsize=$(stat -Lc %s "$d/$rel" 2>/dev/null || echo "")
      case "$fsize" in
        ''|*[!0-9]*) printf 'MISSING state file %s/%s (size unreadable)\n' "$d" "$rel"; failed=$((failed+1)); rc=2; continue ;;
      esac
      if [ "$fsize" -ge 1048576 ]; then
        printf 'large-not-copied %s/%s %s bytes\n' "$d" "$rel" "$fsize"
        skipped=$((skipped+1)); continue
      fi
      fkib=$(( (fsize + 1023) / 1024 ))
      if [ "$(left_kib)" -lt "$fkib" ]; then
        printf 'SKIPPED state file %s/%s (budget: %sKiB needed, %sKiB left)\n' "$d" "$rel" "$fkib" "$(left_kib)"
        skipped=$((skipped+1)); rc=2; continue
      fi
      flat=$(printf '%s' "$rel" | sha256sum | cut -d' ' -f1)
      # Unambiguous path key; a/b and a__b cannot overwrite each other.
      # Copies stay anchored to the state root and bounded to the measured size.
      if head -c "$fsize" "$d/$rel" > "$sub/$flat" 2>/dev/null; then
        charge $(( ($(stat -c %s "$sub/$flat" 2>/dev/null || echo 0) + 1023) / 1024 ))
        printf 'copied state %q -> %s (%s bytes)\n' "$d/$rel" "$sub/$flat" "$fsize"
        copied=$((copied+1))
      else
        printf 'MISSING state file %s/%s (copy failed)\n' "$d" "$rel"; failed=$((failed+1)); rc=2
      fi
    done < "$list"
    rm -f "$list"
    printf 'snapshotted %s -> %s (%d copied, %d skipped, %d failed)\n' "$d" "$sub" "$copied" "$skipped" "$failed"
    [ $((copied + skipped)) -eq 0 ] && [ "$failed" -eq 0 ] && { printf 'EMPTY state dir %s\n' "$d"; rc=2; }
  done
  echo "## budget: spent ${spent_kib}KiB of ${budget_kib}KiB"
  [ "$(left_kib)" -le 0 ] && echo "BUDGET-EXHAUSTED: further copies were skipped"
  true   # the block's status must not depend on the last test
} >> "$DEST/MANIFEST.txt" 2>&1 || { echo "FAILED: manifest write failed" >&2; exit 2; }
cat "$DEST/MANIFEST.txt"
echo "evidence: $DEST"
exit "$rc"
