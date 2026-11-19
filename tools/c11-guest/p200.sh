#!/bin/zsh
# p200.sh [N]: add N panels to workspace:1 area:1, then measure (spike row 20; G.4, T2.12). Runs INSIDE the guest.
# The guest-side C11_* variables g.sh exports are inherited, so `guest.sh cli` reaches the right app.
N=${1:-199}; G="$HOME/c11-guest/guest.sh"
t0=$(python3 -c 'import time;print(time.time())')
for i in $(seq 1 $N); do $G cli new-panel --workspace workspace:1 --area area:1 >/dev/null 2>&1 || $G cli new-panel --workspace workspace:1 >/dev/null; done
t1=$(python3 -c 'import time;print(time.time())'); echo "created $N in $(python3 -c "print(round($t1-$t0,1))")s"
sleep 60
echo "panels: $($G cli tree --no-layout | grep -c 'panel:')"
for i in 1 2 3; do /usr/bin/time -p $G cli tree --no-layout 2>&1 >/dev/null | grep real; done
sleep 5
$G procs
top -l 2 -s 5 -stats pid,command,cpu,mem | grep -E "c11|herdr" | tail -4
