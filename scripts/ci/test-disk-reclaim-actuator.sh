#!/usr/bin/env bash
# RESILIENT-1565: disk-reclaim-actuator gating + bounds
set -u
D="$(cd "$(dirname "$0")/../coord" && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CHUMP_AMBIENT_LOG="$T/a.jsonl" CHUMP_DISK_RECLAIM_FREE_GB_FILE="$T/free"
echo 60 > "$T/free"
"$D/disk-reclaim-actuator.sh" | grep -q "nothing to do" || { echo FAIL above-highwater; exit 1; }
echo 10 > "$T/free"
CHUMP_DISK_RECLAIM_BUILD_LIVE=1 "$D/disk-reclaim-actuator.sh" | grep -q "build is live" || { echo FAIL live-build; exit 1; }
CHUMP_DISK_RECLAIM_BUILD_LIVE=0 "$D/disk-reclaim-actuator.sh" | grep -q "DRY-RUN step=stale-worktrees" || { echo FAIL dry; exit 1; }
echo 55 > "$T/free"; echo 30 > "$T/hi"
CHUMP_DISK_RECLAIM_BUILD_LIVE=0 CHUMP_DISK_RECLAIM_HIGH_GB=60 "$D/disk-reclaim-actuator.sh" | grep -q "DRY-RUN" && { echo FAIL lowwater; exit 1; }
echo PASS
