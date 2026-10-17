#!/bin/bash
# Idle CPU / memory of a running Glance.
# Usage: Scripts/measure_idle_cpu.sh [pid] [seconds]
#   pid      default: the oldest process named Glance
#   seconds  default: 30 (sampled every 2 s with `top`, first sample discarded)
# Method: `top -l N -s 2 -pid PID -stats pid,cpu` reports CPU over each 2 s interval.
# The first sample of top is "since boot of the tool" and is skipped. Prints mean and max of the rest, plus RSS.
# Do the measurement with the island closed, nothing playing, and no other load on the machine.
set -euo pipefail
PID="${1:-$(pgrep -x Glance | head -1 || true)}"
SECS="${2:-30}"
[ -n "$PID" ] || { echo "No Glance process found (pass a pid)"; exit 1; }
N=$(( SECS / 2 + 1 ))
echo "Measuring pid $PID for ~${SECS}s (island should be idle and closed)..."
top -l "$N" -s 2 -pid "$PID" -stats pid,cpu | awk -v pid="$PID" '
  $1 == pid { i++; if (i > 1) { sum += $2; if ($2 > max) max = $2; c++ } }
  END { if (c) printf "samples=%d mean=%.2f%% max=%.2f%%\n", c, sum / c, max; else print "no samples" }'
echo "RSS: $(ps -o rss= -p "$PID" | awk '{printf "%.1f MB", $1/1024}')"
