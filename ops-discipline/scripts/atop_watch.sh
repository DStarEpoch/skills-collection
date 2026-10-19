#!/usr/bin/env bash
# atop_watch.sh — atop/atopsar based system resource monitoring: CPU/memory/disk/network.
#
# Usage:
#   atop_watch.sh [interval] [samples]      live sampling, default 2s x 3
#   atop_watch.sh --history <minutes>       history summary (min/avg/max; needs the
#                                           sampling service: atop_check.sh --enable-log)
#
# Design:
#   - All four metric classes come from ONE combined `atopsar -c -m -d -i` run, so every
#     section shares the same time window.
#   - Sections are split by atopsar's trailing markers (_cpu_/_mem_/_dsk_/_if_); timed
#     rows are matched by a strict HH:MM:SS regex so continuation rows (device/interface
#     names, which may start with a digit after truncation) are never mistaken for rows.
#   - Timestamps are HOST-LOCAL throughout (atop log files are local-date/local-time);
#     headers say so explicitly so UTC and local are never mixed silently.
#   - History selects DAY FILES (-r YYYYMMDD) and, when the window crosses midnight,
#     concatenates one run per day. Actual first/last sample times are printed; if the
#     window is not covered (retention), the output says so instead of pretending.
#   - Exit codes: 0 = data produced; 1 = atop missing / any section empty / history
#     unavailable (absence of evidence is not a healthy system); 2 = bad arguments, or the
#     requested window is not fully covered by day files (incomplete evidence).
#
# Column layouts verified on atop 2.10 (re-verify if the version changes):
#   -c: time cpu %usr %nice %sys %irq %softirq %steal %guest %wait %idle   ("all" = all cores, / nproc)
#   -m: time memtotal memfree buffers cached dirty slabmem swptotal swpfree
#   -d: time disk busy read/s KB/read writ/s KB/writ ...
#   -i: time interf busy ipack/s opack/s iKbyte/s oKbyte/s ...

set -euo pipefail

command -v atopsar >/dev/null 2>&1 || { echo "[atop_watch] atop not installed; run atop_check.sh --install first" >&2; exit 1; }
atop -V >/dev/null 2>&1 || { echo "[atop_watch] atop binary present but broken (atop -V failed)" >&2; exit 1; }

nproc=$(nproc)
SECTION='
  /_cpu_[[:space:]]*$|_if_[[:space:]]*$|_mem_[[:space:]]*$|_dsk_[[:space:]]*$/ {
    if ($0 ~ /_cpu_$/) sec="cpu"; else if ($0 ~ /_mem_$/) sec="mem";
    else if ($0 ~ /_dsk_$/) sec="dsk"; else sec="net"; next
  }
'
T='^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$'   # strict HH:MM:SS

CPU_AWK="$SECTION"'
  sec=="cpu" && $1 ~ t && $2=="all" {
    printf "  %s busy=%.0f%% (usr %.0f%% sys %.0f%% wait %.0f%%)\n", $1, 100-$11/n, ($3+$4)/n, ($5+$6+$7)/n, $10/n; c++
  } END { if (c==0) exit 1 }'
MEM_AWK="$SECTION"'
  sec=="mem" && $1 ~ t && NF==9 { print "  " $0; c++ }
  END { if (c==0) exit 1 }'
DSK_AWK="$SECTION"'
  sec=="dsk" && $1 ~ t && $3 ~ /%$/ { t0=$1; dev=$2; busy=$3; r=$4; w=$6 }
  sec=="dsk" && $1 !~ t && $2 ~ /%$/ { dev=$1; busy=$2; r=$3; w=$5 }
  sec=="dsk" && dev!="" { printf "  %s %s busy=%s read=%s/s write=%s/s\n", t0, dev, busy, r, w; dev=""; c++ }
  END { if (c==0) exit 1 }'
NET_AWK="$SECTION"'
  sec=="net" && $1 ~ t && $6 ~ /^[0-9]/ { t0=$1; dev=$2; i=$6; o=$7 }
  sec=="net" && $1 !~ t && NF>=7 { dev=$1; i=$5; o=$6 }
  sec=="net" && dev!="" { printf "  %s %s in=%sKB/s out=%sKB/s\n", t0, dev, i, o; dev=""; c++ }
  END { if (c==0) exit 1 }'

if [[ "${1:-}" == "--history" ]]; then
    minutes="${2:-60}"
    [[ "$minutes" =~ ^[0-9]+$ ]] || { echo "usage: atop_watch.sh --history <positive-minutes>" >&2; exit 2; }
    if [ "$minutes" -gt 1440 ]; then
        echo "[atop_watch] note: ${minutes} min spans ~$(( minutes / 1440 + 1 )) day files; each day costs seconds to parse and the whole window is buffered in memory" >&2
    fi
    start_date=$(date -d "-${minutes} min" +%Y%m%d 2>/dev/null) \
        || { echo "[atop_watch] date -d unavailable (GNU coreutils required)" >&2; exit 1; }
    start_time=$(date -d "-${minutes} min" +%H:%M 2>/dev/null) \
        || { echo "[atop_watch] date -d unavailable (GNU coreutils required)" >&2; exit 1; }
    today=$(date +%Y%m%d)
    raw=""; coverage=""; first_day=""; failed_days=""; missing_days=""; partial=0
    d="$start_date"
    while [ "$d" -le "$today" ]; do
        b="00:00"; [ "$d" = "$start_date" ] && b="$start_time"
        if [ -r "/var/log/atop/atop_$d" ]; then
            chunk=$(atopsar -c -m -d -i -r "$d" -b "$b" 2>/dev/null) || chunk=""
            if [ -z "$chunk" ]; then failed_days="${failed_days} ${d}"; partial=1; else
                raw="${raw}${chunk}
"
                # first = first emitted row (honours -b on the start day); last = MAX
                # timestamp (a day file repeats the next day's opening rows at its end)
                cfirst=$(printf '%s\n' "$chunk" | grep -oE '^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | sed -n '1p')
                clast=$(printf '%s\n' "$chunk" | grep -oE '^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | sort | sed -n '$p')
                [ -n "$cfirst" ] && [ -n "$clast" ] && [ "$clast" \< "$cfirst" ] && clast="$cfirst"
                [ -z "$first_day" ] && [ -n "$cfirst" ] && first_day="$d"
                coverage="${coverage}   ${d}: ${cfirst} .. ${clast} (host-local)
"
            fi
        else
            missing_days="${missing_days} ${d}"; partial=1
        fi
        d=$(date -d "$d + 1 day" +%Y%m%d 2>/dev/null) \
            || { echo "[atop_watch] date -d failed for '$d + 1 day'" >&2; exit 1; }
    done
    [ -n "$raw" ] || { echo "[atop_watch] history unavailable for ${start_date} ${start_time}..now (retention/atop logging?)" >&2; exit 1; }

    echo "== atop history summary: requested last ${minutes} min (from ${start_date} ${start_time} host-local) =="
    echo "   per-day actual coverage:"
    printf '%s' "$coverage"
    first_all=$(printf '%s\n' "$raw" | grep -oE '^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | sed -n '1p')
    # date-aware start-gap check (a date-less HH:MM comparison hides a whole missing day)
    if [ -n "$first_day" ] && [ -n "$first_all" ]; then
        t0=$(date -d "$start_date $start_time" +%s 2>/dev/null || echo 0)
        t1=$(date -d "$first_day $first_all" +%s 2>/dev/null || echo 0)
        if [ "$t0" -gt 0 ] && [ "$t1" -gt 0 ]; then
            gap_min=$(( (t1 - t0) / 60 ))
            if [ "$gap_min" -gt 10 ]; then
                echo "   NOTE: coverage starts ${gap_min} min after the requested start (retention or missing day files)"
                partial=1
            fi
        fi
    fi
    [ -n "$failed_days" ] && echo "   NOTE: atopsar returned no data for day(s):${failed_days} (file present but empty/unreadable)"
    [ -n "$missing_days" ] && echo "   NOTE: no atop log file for day(s):${missing_days} (outside retention? window NOT fully covered)"

    rows_cpu=$(printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"' sec=="cpu" && $1 ~ t && $2=="all" {n++} END{print n+0}')
    rows_mem=$(printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"' sec=="mem" && $1 ~ t && NF==9 {n++} END{print n+0}')
    rows_dsk=$(printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"' sec=="dsk" && (($1 ~ t && $3 ~ /%$/) || ($1 !~ t && $2 ~ /%$/)) {n++} END{print n+0}')
    rows_net=$(printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"' sec=="net" && NF>=7 {n++} END{print n+0}')
    echo "   section rows: cpu=$rows_cpu mem=$rows_mem dsk=$rows_dsk net=$rows_net"
    missing=""
    [ "$rows_cpu" -eq 0 ] && missing="$missing CPU"
    [ "$rows_mem" -eq 0 ] && missing="$missing MEM"
    [ "$rows_dsk" -eq 0 ] && missing="$missing DSK"
    [ "$rows_net" -eq 0 ] && missing="$missing NET"
    if [ -n "$missing" ]; then
        echo "[atop_watch] history sections missing data:$missing (contract: every section must be present)" >&2
        exit 1
    fi
    if [ "$partial" = 1 ]; then
        echo "[atop_watch] history coverage is PARTIAL (see NOTE lines); not reporting a complete window" >&2
        exit 2
    fi

    echo "--- CPU busy% (min/avg/max over samples) ---"
    printf '%s\n' "$raw" | awk -v n="$nproc" -v t="$T" "$SECTION"'
        sec=="cpu" && $1 ~ t && $2=="all" { b=100-$11/n; w=$10/n;
            if (!c++ || b<mn) mn=b; if (b>mx) mx=b; s+=b; sw+=w; if (w>wm) wm=w }
        END { if (!c) exit 1; printf "  busy min=%.0f%% avg=%.0f%% max=%.0f%% | wait avg=%.1f%% max=%.1f%% (%d samples)\n", mn, s/c, mx, sw/c, wm, c }' \
        || { echo "[atop_watch] no CPU rows in history window" >&2; exit 1; }
    echo "--- MEM (first/last, MiB) ---"
    printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"'
        sec=="mem" && $1 ~ t && NF==9 {
            gsub(/M/,"",$3); gsub(/M/,"",$5);
            if (!c++) { f_free=$3; f_cache=$5 } l_free=$3; l_cache=$5 }
        END { if (c) printf "  free %d -> %d MiB | cached %d -> %d MiB (%d samples)\n", f_free, l_free, f_cache, l_cache, c;
              else print "  (no mem rows in window)" }'
    echo "--- DSK per device: busy% max(avg), write/s max ---"
    printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"'
        sec=="dsk" && $1 ~ t && $3 ~ /%$/ { dev=$2; b=$3+0; w=$6+0 }
        sec=="dsk" && $1 !~ t && $2 ~ /%$/ { dev=$1; b=$2+0; w=$5+0 }
        sec=="dsk" && dev!="" { c[dev]++; s[dev]+=b; if (b>bm[dev]) bm[dev]=b; if (w>wm[dev]) wm[dev]=w; dev="" }
        END { for (d in c) printf "  %s busy max=%.0f%% avg=%.0f%% | write max=%.0f/s\n", d, bm[d], s[d]/c[d], wm[d] }'
    echo "--- NET per interface: max in/out KB/s (IDLE = zero traffic all window; a flow breaking to zero IS the signal) ---"
    printf '%s\n' "$raw" | awk -v t="$T" "$SECTION"'
        sec=="net" && $1 ~ t && $6 ~ /^[0-9]/ { dev=$2; i=$6+0; o=$7+0 }
        sec=="net" && $1 !~ t && NF>=7 { dev=$1; i=$5+0; o=$6+0 }
        sec=="net" && dev!="" { if (i>im[dev]) im[dev]=i; if (o>om[dev]) om[dev]=o; dev="" }
        END { for (d in im) printf "  %s in max=%.0fKB/s out max=%.0fKB/s%s\n", d, im[d], om[d], (im[d]+om[d]>0 ? "" : " IDLE") }'
    exit 0
fi

interval="${1:-2}"
samples="${2:-3}"
echo "== atop_watch: ${samples} samples x ${interval}s ($(date +%H:%M:%S%z), host local time; atop logs/samples are local) =="
raw=$(atopsar -c -m -d -i "$interval" "$samples" 2>/dev/null) \
    || { echo "[atop_watch] atopsar sampling failed" >&2; exit 1; }
rc=0
echo "--- CPU (aggregate over ${nproc} cores) ---"
printf '%s\n' "$raw" | awk -v n="$nproc" -v t="$T" "$CPU_AWK" || rc=1
echo "--- MEM (total free buffers cached dirty slab swptot swpfree) ---"
printf '%s\n' "$raw" | awk -v t="$T" "$MEM_AWK" || rc=1
echo "--- DSK ---"
printf '%s\n' "$raw" | awk -v t="$T" "$DSK_AWK" || rc=1
echo "--- NET ---"
printf '%s\n' "$raw" | awk -v t="$T" "$NET_AWK" || rc=1
echo "--- top processes by CPU (last sample, separate small window) ---"
topout=$(atop "$interval" "$samples" 2>/dev/null | awk '
  /PID.*SYSCPU/ { buf=$0 "\n"; n=0; next }
  buf!="" && n<9 { buf=buf $0 "\n"; n++ }
  END { printf "%s", buf }') \
  || { echo "[atop_watch] top-process collection failed" >&2; topout=""; rc=1; }
if printf '%s\n' "$topout" | grep -qE '^ *[0-9]+ '; then
  printf '%s\n' "$topout" | head -6
else
  echo "[atop_watch] top-process section produced no data" >&2
  rc=1
fi
[ "$rc" = 0 ] || { echo "[atop_watch] one or more metric sections produced no data" >&2; exit 1; }
