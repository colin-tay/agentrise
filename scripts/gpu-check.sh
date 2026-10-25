#!/bin/zsh
# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
# GPU / CPU cost of the tower while it is running.
# Usage: scripts/gpu-check.sh [warmup_seconds=6]
# Prints exactly one line: gpu=<x>% ws_gpu=<y>% ws_cpu=<z>% tower_cpu=<w>%
#   gpu       mean IOAccelerator "Device Utilization %" over 12 samples (zero samples dropped)
#   ws_gpu    WindowServer share of GPU time over 5 s (accumulatedGPUTime delta)
#   ws_cpu    WindowServer CPU %, mean of the last two `top` samples
#   tower_cpu Agentrise CPU % (0 when it is not running)

warmup=${1:-6}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gpu-check.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

ws_pid=$(pgrep -x WindowServer | head -1)
tower_pid=$(pgrep -x Agentrise | head -1)

read -r -d '' PY <<'PYEOF'
import subprocess, re, time
def snap():
    out = subprocess.run(['ioreg', '-r', '-c', 'AGXDeviceUserClient', '-l', '-w0'],
                         capture_output=True, text=True).stdout
    d = {}
    for blk in out.split('+-o ')[1:]:
        m = re.search(r'"IOUserClientCreator" = "pid (\d+), ([^"]+)"', blk)
        if not m:
            continue
        t = sum(int(x) for x in re.findall(r'"accumulatedGPUTime"=(\d+)', blk))
        k = (m.group(1), m.group(2))
        d[k] = d.get(k, 0) + t
    return d
a = snap(); time.sleep(5); b = snap()
print("%.1f" % sum((b[k] - a.get(k, 0)) / 5e9 * 100 for k in b if k[1] == 'WindowServer'))
PYEOF

cpu_of() {  # $1 = pid; mean of the last two of three 2-second samples
    [[ -z "$1" ]] && { echo 0; return; }
    top -l 3 -s 2 -stats pid,cpu -pid "$1" 2>/dev/null \
        | awk -v p="$1" '$1 == p { v[++n] = $2 } END { if (n >= 2) printf "%.0f", (v[n] + v[n-1]) / 2; else printf "0" }'
}

sleep "$warmup"

# All four measurements overlap in time.
python3 -I -c "$PY" > "$tmp/ws_gpu" &
cpu_of "$ws_pid" > "$tmp/ws_cpu" &
cpu_of "$tower_pid" > "$tmp/tower_cpu" &

s=0; n=0
for i in $(seq 1 12); do
    v=$(ioreg -r -d 1 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)
    [[ -n "$v" && "$v" -gt 0 ]] && { s=$((s + v)); n=$((n + 1)); }
    sleep 0.5
done
wait

gpu=0; (( n > 0 )) && gpu=$((s / n))
echo "gpu=${gpu}% ws_gpu=$(<"$tmp/ws_gpu")% ws_cpu=$(<"$tmp/ws_cpu")% tower_cpu=$(<"$tmp/tower_cpu")%"
