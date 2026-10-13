#!/usr/bin/env bash
# RESILIENT-1573 smoke test for no-ship-loop-detector.sh
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$R/scripts/coord/no-ship-loop-detector.sh"
bash -n "$D"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
A=$T/a.jsonl
for _ in 1 2 3 4 5; do echo '{"event":"cycle_end","gap_id":"X-1","kind":"failed"}' >> "$A"; done
echo '{"event":"cycle_end","gap_id":"Y-1","kind":"shipped"}' >> "$A"
printf '#!/bin/bash\necho "$*" >> %s/calls\necho RESILIENT-9999\n' "$T" > "$T/chump"; chmod +x "$T/chump"
export CHUMP_AMBIENT_PATH=$A CHUMP_NOSHIP_LOOP_STATE_FILE=$T/s.json CHUMP_NOSHIP_LOOP_CHUMP_CMD=$T/chump
bash "$D" 2>/dev/null
grep -q 'gap set X-1 --status blocked' "$T/calls" || { echo FAIL block; exit 1; }
! grep -q 'Y-1' "$T/calls" || { echo FAIL shipped gap blocked; exit 1; }
bash "$D" 2>/dev/null
[[ "$(grep -c 'gap set X-1' "$T/calls")" == 1 ]] || { echo FAIL dedup; exit 1; }
echo '{"event":"cycle_end","gap_id":"X-1","kind":"timeout"}' >> "$A"
bash "$D" 2>/dev/null
[[ "$(grep -c 'gap set X-1' "$T/calls")" == 2 ]] || { echo FAIL reblock; exit 1; }
[[ "$(grep -c 'gap reserve' "$T/calls")" == 1 ]] || { echo FAIL one-gap; exit 1; }
grep -q 'kind: no_ship_loop_detected' "$R/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'kind: service_crash_loop' "$R/docs/observability/EVENT_REGISTRY.yaml"
echo PASS
