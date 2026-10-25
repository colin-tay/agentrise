#!/bin/sh
# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
# Usage: scripts/perf-check.sh <seconds>  → avg CPU and max RSS of Agentrise
PID=$(pgrep -x Agentrise) || { echo "Agentrise not running"; exit 1; }
N=$(( ${1:-60} / 2 ))
top -l "$N" -s 2 -pid "$PID" -stats cpu,mem | awk '/^[0-9.]+ +[0-9]/ {n++; if (n>1) {c+=$1; m=$2; gsub(/[^0-9.]/,"",m); if ($2 ~ /G/) m*=1024; if (m>mx) mx=m}} END {printf "avg_cpu=%.2f%% max_mem=%.0fMB samples=%d\n", c/(n-1), mx, n-1}'
