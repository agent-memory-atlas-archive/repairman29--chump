#!/usr/bin/env bash
# RESILIENT-1590: missing cargo-sweep goes RED; wedged-inode binaries reaped to newest-1;
# multi-dir sweep; reaper auto-executes under pressure.
set -uo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; GC="$R/scripts/ops/cargo-sweep-gc.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; fails=0
ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1" >&2; fails=$((fails+1)); }
mkdir -p "$W/bin" "$W/repo/target/release" "$W/t1" "$W/t2"; : > "$W/repo/Cargo.toml"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/cargo"; chmod +x "$W/bin/cargo"
AMB="$W/amb.jsonl"; : > "$AMB"
PATH="$W/bin:/usr/bin:/bin" HOME="$W" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO="$W/repo" bash "$GC" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "missing cargo-sweep exits non-zero" || bad "missing cargo-sweep must be RED"
grep -q '"kind":"cargo_sweep_gc_errored"' "$AMB" && ok "errored event emitted" || bad "no errored event"
printf '#!/bin/sh\necho "Cleaned: 1 MB"\nexit 0\n' > "$W/bin/cargo-sweep"; chmod +x "$W/bin/cargo-sweep"
for i in 1 2 3; do touch "$W/repo/target/release/chump.wedged-inode-$i"; touch -d "$((4-i)) days ago" "$W/repo/target/release/chump.wedged-inode-$i"; done
: > "$AMB"
PATH="$W/bin:/usr/bin:/bin" HOME="$W" CHUMP_AMBIENT_LOG="$AMB" CHUMP_REPO="$W/repo" \
  CHUMP_CARGO_SWEEP_TARGET_DIRS="$W/t1=100:$W/t2=200" bash "$GC" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "healthy run exits 0" || bad "healthy run should exit 0"
[[ $(ls "$W/repo/target/release" | grep -c wedged-inode) -eq 1 ]] && ok "wedged copies reaped to newest-1" || bad "wedged reap"
grep -q 'chump.wedged-inode-3' <(ls "$W/repo/target/release") && ok "newest kept" || bad "newest not kept"
[[ $(grep -c '"kind":"cargo_sweep_gc_ran"' "$AMB") -eq 2 ]] && ok "both dirs swept" || bad "multi-dir sweep"
grep -q '"cap_mb":200' "$AMB" && ok "per-dir cap honored" || bad "per-dir cap"
grep -q 'CHUMP_REAPER_AUTO_EXECUTE_PCT' "$R/scripts/ops/cargo-target-reaper.sh" && ok "reaper auto-execute present" || bad "reaper"
(( fails )) && { echo "FAIL"; exit 1; }; echo "PASS test-resilient-1590-disk-selfheal"
