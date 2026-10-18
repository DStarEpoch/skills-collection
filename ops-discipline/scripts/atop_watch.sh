#!/usr/bin/env bash
# atop_watch.sh — atop/atopsar based system resource monitoring: CPU/memory/disk/network.
#
# Usage:
#   atop_watch.sh [interval] [samples]      live sampling, default 2s x 3
#   atop_watch.sh --history [minutes]       read atop history logs (default last 60min;
#                                           requires the sampling service: atop_check.sh --enable-log)
#
# Design: atopsar reports percentages/rates directly (no manual counter differencing),
# and atop's screen output provides Top processes (per-interval CPU%, not lifetime average).
# atopsar column layouts (verified on 2.10):
#   -c: time cpu %usr %nice %sys %irq %softirq %steal %guest %wait %idle   ("all" row = all cores summed, divide by nproc)
#   -m: time memtotal memfree buffers cached dirty slabmem swptotal swpfree
#   -d: time disk busy read/s KB/read writ/s KB/writ ... (first row of each sample carries the time, continuation rows do not)
#   -i: time interf busy ipack/s opack/s iKbyte/s oKbyte/s ... (same)

set -euo pipefail

command -v atopsar >/dev/null 2>&1 || { echo "[atop_watch] atop not installed; run atop_check.sh --install first" >&2; exit 1; }

nproc=$(nproc)
# atopsar row matchers: timed rows vs continuation rows (device/interface name first), skipping headers
DSK_AWK='
  $1 ~ /^[0-9][0-9]:[0-9][0-9]/ { t=$1; if ($2=="disk" || $3 !~ /%$/) next; dev=$2; busy=$3; r=$4; w=$6 }
  $1 !~ /^[0-9]/ && $2 ~ /%$/   { dev=$1; busy=$2; r=$3; w=$5 }
  dev!="" { printf "  %s %s busy=%s read=%s/s write=%s/s\n", t, dev, busy, r, w; dev="" }
'
NET_AWK='
  $1 ~ /^[0-9][0-9]:[0-9][0-9]/ { t=$1; if ($2=="interf" || $6 !~ /^[0-9]/) next; dev=$2; i=$6; o=$7 }
  $1 !~ /^[0-9]/ && $5 ~ /^[0-9]/ && NF>=7 { dev=$1; i=$5; o=$6 }
  dev!="" { printf "  %s %s in=%sKB/s out=%sKB/s\n", t, dev, i, o; dev="" }
'
CPU_AWK='$1 ~ /^[0-9][0-9]:[0-9][0-9]/ && $2=="all" {printf "  %s busy=%.0f%% (usr %.0f%% sys %.0f%% wait %.0f%%)\n", $1, 100-$11/n, ($3+$4)/n, ($5+$6+$7)/n, $10/n}'
MEM_AWK='$1 ~ /^[0-9][0-9]:[0-9][0-9]/ && NF==9 {print "  " $0}'

if [[ "${1:-}" == "--history" ]]; then
    minutes="${2:-60}"
    start=$(date -d "-${minutes} min" +%H:%M 2>/dev/null || date -v-"${minutes}"M +%H:%M)
    echo "== atop history: last ${minutes} min (from $start) =="
    echo "--- CPU ---";  atopsar -c -b "$start" 2>/dev/null | awk -v n="$nproc" "$CPU_AWK"
    echo "--- DSK ---";  atopsar -d -b "$start" 2>/dev/null | awk "$DSK_AWK"
    echo "--- NET ---";  atopsar -i -b "$start" 2>/dev/null | awk "$NET_AWK"
    exit 0
fi

interval="${1:-2}"
samples="${2:-3}"

echo "== atop_watch: ${samples} samples x ${interval}s ($(date -u +%H:%M:%SZ)) =="
echo "--- CPU (aggregate over ${nproc} cores) ---"
atopsar -c "$interval" "$samples" 2>/dev/null | awk -v n="$nproc" "$CPU_AWK"
echo "--- MEM (total free buffers cached dirty slab swptot swpfree) ---"
atopsar -m "$interval" "$samples" 2>/dev/null | awk "$MEM_AWK"
echo "--- DSK ---"
atopsar -d "$interval" "$samples" 2>/dev/null | awk "$DSK_AWK"
echo "--- NET ---"
atopsar -i "$interval" "$samples" 2>/dev/null | awk "$NET_AWK"
echo "--- top processes by CPU (last sample) ---"
atop "$interval" "$samples" 2>/dev/null | grep -A8 'PID.*SYSCPU' | tail -5
