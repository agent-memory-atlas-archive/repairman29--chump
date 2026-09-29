#!/usr/bin/env bash
# Adversarial check for the memory guards (RESILIENT-314): a runaway process OUTSIDE supabase.slice
# (standing in for a fleet cargo build) allocates until the box is nearly out of memory. Pass = earlyoom
# kills the hog and supabase_postgres keeps the same PID (never restarted). Takes ~1 minute.
set -uo pipefail
before=$(docker inspect -f '{{.State.Pid}} {{.State.StartedAt}}' supabase_postgres)
sudo systemd-run --unit=r314-memhog --property=OOMScoreAdjust=500 --collect python3 -c "
import time
b=[]
for i in range(60):
    b.append(bytearray(512*1024*1024))
    for j in range(0,len(b[-1]),4096): b[-1][j]=1
    time.sleep(0.4)
print('hog survived', len(b)*0.5, 'GB')"
for _ in $(seq 1 45); do sleep 2; systemctl is-active --quiet r314-memhog || break; done
journalctl -u earlyoom --since -3min --no-pager -o cat | grep -i "sending" | tail -1
after=$(docker inspect -f '{{.State.Pid}} {{.State.StartedAt}}' supabase_postgres)
echo "postgres before: $before"; echo "postgres after:  $after"
[[ "$before" == "$after" ]] && echo "PASS: postgres survived (same PID)" || { echo "FAIL: postgres restarted"; exit 1; }
