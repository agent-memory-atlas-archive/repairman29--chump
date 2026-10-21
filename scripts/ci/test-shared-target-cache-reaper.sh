#!/usr/bin/env bash
# scripts/ci/test-shared-target-cache-reaper.sh — RESILIENT-1045 / RESILIENT-1680
#
# Proves the scoped shared-target-cache-reaper (RESILIENT-1680 rewrite):
#   1. Over budget, idle, EXECUTE → every `incremental/` dir reaped, the target
#      root and all non-incremental build output PRESERVED (never the whole
#      target), reaped event emitted.
#   2. Over budget, idle, DRY-RUN → nothing deleted, dryrun event emitted.
#   3. Under budget AND disk fine → "nothing to do", guards not even reached.
#   4. skip-when-building: a (stubbed) cargo/rustc/nextest/rustdoc process alive
#      → the whole tick skips, incremental dirs intact, reason logged.
#   5. skip-when-admit-refused: `chump admit cargo` refuses → skip, intact.
#   6+7. skip-when-locked: either architect lane lock held by another process
#      → skip, incremental dirs intact, reason logged.
#   8. Safety inputs take NO env override: CHUMP_SHARED_TARGET_CAP_GB and
#      CHUMP_SHARED_TARGET in the environment change nothing (the reads were
#      removed in RESILIENT-1680) — budget/target come from CLI args only.
#   9. disk-pressure-reaper.sh still wires the reaper in before its ≥50GB
#      early-exit (proactive, not tier-gated).
#  10. DEFAULT gate fires: with NO --target/--floor-gb/--budget-gb (the exact
#      invocation the organ-manifest + disk-pressure-reaper pass, `--execute`
#      only), the reaper reaps the fixture at the sandbox default target
#      ($HOME/.cargo/chump-shared-target) once du/df (shadowed on PATH) cross
#      the FLOOR_GB_DEFAULT/BUDGET_GB_DEFAULT constants. This pins the ONLY gate
#      production actually uses — flipping the defaults to never-fire is caught.
#  11. DEFAULT under-threshold: same defaults-only invocation, du/df report the
#      target small + disk plentiful → nothing-to-do, nothing deleted.
#  12. unknown CLI arg fails CLOSED: a bogus flag exits 2 and deletes nothing
#      (a mistyped threshold flag must not be swallowed into a silent-default run).
#  13. FLOOR-only DEFAULT gate: du→under budget but df→under the default floor,
#      defaults-only invocation → the reap fires driven SOLELY by under_floor
#      (reason is the floor, not the budget). Isolates the floor trigger so
#      dropping the under_floor arm or flipping FLOOR_GB_DEFAULT→0 is caught.
#  14. BUDGET-only DEFAULT gate: du→over budget but df→above the default floor,
#      defaults-only → the reap fires driven SOLELY by over_budget (reason is the
#      budget, not the floor). Isolates the budget trigger so flipping
#      BUDGET_GB_DEFAULT→huge is caught. 13+14 together pin each OR'd trigger.
#
# No real multi-GB dir and no real build: the reaper runs under a SANDBOX HOME
# (scripts/coord/lib/test-sandbox.sh) so its fixed ~/.chump/architect-lane*.lock
# paths resolve inside the sandbox, the trigger is forced via the --budget-gb /
# --floor-gb CLI args the systemd unit passes, and `pgrep` / `chump` are shadowed
# on PATH to stub the process list and the cargo-admission check.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REAPER="$REPO_ROOT/scripts/coord/shared-target-cache-reaper.sh"
PRESSURE="$REPO_ROOT/scripts/coord/disk-pressure-reaper.sh"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

[[ -x "$REAPER" ]] || { echo "reaper not executable: $REAPER" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock required for this test" >&2; exit 1; }

WORK="$(mktemp -d)"
BG_PIDS=()
cleanup() {
  local p
  for p in "${BG_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

AMB="$WORK/ambient.jsonl"
BIN="$WORK/bin"; mkdir -p "$BIN"
BUILD_FLAG="$WORK/build-alive"      # present → stub pgrep reports a live build
ADMIT_REFUSE="$WORK/admit-refuse"   # present → stub chump admit cargo refuses
DU_DF_MODE="$WORK/du-df-mode"       # contents "trigger"|"safe" → stub du/df lie;
                                    # absent → stubs exec the real du/df (inert).

# stub pgrep: reports a build process alive ONLY while $BUILD_FLAG exists.
cat > "$BIN/pgrep" <<PGREP
#!/usr/bin/env bash
name=""
prev=""
for a in "\$@"; do [[ "\$prev" == "-x" ]] && name="\$a"; prev="\$a"; done
if [[ -e "$BUILD_FLAG" ]]; then
  case "\$name" in cargo|rustc|cargo-nextest|rustdoc) exit 0 ;; esac
fi
exit 1
PGREP
chmod +x "$BIN/pgrep"

# stub chump: `chump admit cargo` admits unless $ADMIT_REFUSE exists.
cat > "$BIN/chump" <<CHUMP
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "admit cargo" ]]; then
  [[ -e "$ADMIT_REFUSE" ]] && exit 75
  exit 0
fi
exit 0
CHUMP
chmod +x "$BIN/chump"

# stub du/df: when $DU_DF_MODE holds "trigger" they report the target huge /
# disk scarce so BOTH of the reaper's DEFAULT budget/floor constants fire; "safe"
# reports the target tiny / disk plentiful so NEITHER default trigger fires.
# "budget" reports the target huge but disk plentiful → ONLY over_budget fires
# (floor miss); "floor" reports the target tiny but disk scarce → ONLY
# under_floor fires (budget miss). The budget/floor modes isolate each of the
# two OR'd default triggers so a mutant that drops/disables one is caught.
# Absent → exec the real du/df, so every CLI-driven case above is unaffected.
REAL_DU="$(command -v du)"
REAL_DF="$(command -v df)"
cat > "$BIN/du" <<DU
#!/usr/bin/env bash
mode=""; [[ -e "$DU_DF_MODE" ]] && mode="\$(cat "$DU_DF_MODE" 2>/dev/null)"
p=""; for a in "\$@"; do p="\$a"; done
case "\$mode" in
  trigger) printf '99G\t%s\n' "\$p"; exit 0 ;;
  safe)    printf '1G\t%s\n' "\$p"; exit 0 ;;
  budget)  printf '99G\t%s\n' "\$p"; exit 0 ;;
  floor)   printf '1G\t%s\n' "\$p"; exit 0 ;;
esac
exec "$REAL_DU" "\$@"
DU
chmod +x "$BIN/du"
cat > "$BIN/df" <<DF
#!/usr/bin/env bash
mode=""; [[ -e "$DU_DF_MODE" ]] && mode="\$(cat "$DU_DF_MODE" 2>/dev/null)"
case "\$mode" in
  trigger) echo "Filesystem 1G-blocks Used Avail Use% Mounted"
           echo "/dev/stub 100G 95G 10G 91% /"; exit 0 ;;
  safe)    echo "Filesystem 1G-blocks Used Avail Use% Mounted"
           echo "/dev/stub 1000G 1G 999G 1% /"; exit 0 ;;
  budget)  echo "Filesystem 1G-blocks Used Avail Use% Mounted"
           echo "/dev/stub 1000G 1G 999G 1% /"; exit 0 ;;
  floor)   echo "Filesystem 1G-blocks Used Avail Use% Mounted"
           echo "/dev/stub 100G 95G 10G 91% /"; exit 0 ;;
esac
exec "$REAL_DF" "\$@"
DF
chmod +x "$BIN/df"

# Sandbox HOME so the reaper's fixed lane-lock paths resolve inside the sandbox.
SANDBOX_HOME="$WORK/home"
# shellcheck source=scripts/coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
chump_test_sandbox_setup "$SANDBOX_HOME"
LANE_LOCK_1="$SANDBOX_HOME/.chump/architect-lane.lock"
LANE_LOCK_2="$SANDBOX_HOME/.chump/architect-lane2.lock"
mkdir -p "$SANDBOX_HOME/.chump"

# Build a fresh fixture target each case: three incremental caches (debug,
# release and a per-toolchain triple) plus non-incremental build output + a
# marker that must survive.
INCR_DIRS=(
  "debug/incremental"
  "release/incremental"
  "x86_64-unknown-linux-gnu/debug/incremental"
)
KEEP_FILES=(
  "debug/deps/keepme.rlib"
  "release/marker"
  "x86_64-unknown-linux-gnu/debug/deps/triplekeep.rlib"
)
make_target() {
  local t="$1" d f
  rm -rf "$t"; mkdir -p "$t"
  for d in "${INCR_DIRS[@]}"; do mkdir -p "$t/$d"; echo garbage > "$t/$d/cache.bin"; done
  for f in "${KEEP_FILES[@]}"; do mkdir -p "$(dirname "$t/$f")"; echo keep > "$t/$f"; done
}
incrementals_gone() {  # <target>
  local t="$1" d
  for d in "${INCR_DIRS[@]}"; do [[ -d "$t/$d" ]] && return 1; done
  return 0
}
keeps_intact() {  # <target>
  local t="$1" f
  [[ -d "$t" ]] || return 1
  for f in "${KEEP_FILES[@]}"; do [[ -f "$t/$f" ]] || return 1; done
  return 0
}
incrementals_intact() {  # <target>
  local t="$1" d
  for d in "${INCR_DIRS[@]}"; do [[ -d "$t/$d" ]] || return 1; done
  return 0
}

# run_reaper <target> [extra args...] — real reaper under the sandbox HOME.
run_reaper() {
  local t="$1"; shift
  env HOME="$SANDBOX_HOME" \
      PATH="$BIN:$PATH" \
      CHUMP_AMBIENT_LOG="$AMB" \
      CHUMP_REPO_ROOT="$WORK" \
      bash "$REAPER" --target "$t" "$@" 2>&1
}

# run_reaper_defaults [extra args...] — real reaper with NO --target/threshold
# args, i.e. the exact defaults-only invocation production passes.
run_reaper_defaults() {
  env HOME="$SANDBOX_HOME" \
      PATH="$BIN:$PATH" \
      CHUMP_AMBIENT_LOG="$AMB" \
      CHUMP_REPO_ROOT="$WORK" \
      bash "$REAPER" "$@" 2>&1
}

# The sandbox default target the reaper resolves when no --target is passed.
DEFAULT_TARGET="$SANDBOX_HOME/.cargo/chump-shared-target"

# ── 1. over budget, idle, EXECUTE → incrementals reaped, target preserved ────
echo "== 1. EXECUTE: reap incremental dirs, preserve the target =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
T="$WORK/t1"; make_target "$T"
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
(( rc == 0 )) && pass "execute exits 0" || fail "execute should exit 0, got $rc"
incrementals_gone "$T" && pass "all incremental/ dirs reaped (debug, release, per-toolchain)" || fail "an incremental dir survived: $OUT"
keeps_intact "$T" && pass "target root + non-incremental output preserved (never the whole target)" || fail "the reap removed non-incremental output / the target root"
grep -q '"kind":"shared_target_incremental_reaped"' "$AMB" && pass "emitted reaped event" || fail "missing reaped event"

# ── 2. over budget, idle, DRY-RUN → nothing deleted ──────────────────────────
echo "== 2. DRY-RUN: nothing deleted =="
: > "$AMB"
T="$WORK/t2"; make_target "$T"
OUT="$(run_reaper "$T" --budget-gb 0 --floor-gb 0)"; rc=$?
(( rc == 0 )) && pass "dry-run exits 0" || fail "dry-run should exit 0, got $rc"
incrementals_intact "$T" && pass "DRY-RUN deleted nothing" || fail "DRY-RUN deleted an incremental dir"
grep -q '"kind":"shared_target_incremental_reap_dryrun"' "$AMB" && pass "emitted dryrun event" || fail "missing dryrun event"

# ── 3. under budget AND disk fine → nothing to do, guards not reached ────────
echo "== 3. under budget + disk fine → nothing to do =="
: > "$AMB"; : > "$BUILD_FLAG"   # a build is "alive", but the trigger isn't met
T="$WORK/t3"; make_target "$T"
OUT="$(run_reaper "$T" --execute --budget-gb 999999 --floor-gb 0)"; rc=$?
rm -f "$BUILD_FLAG"
(( rc == 0 )) && pass "nothing-to-do exits 0" || fail "should exit 0, got $rc"
[[ "$OUT" == *"nothing to do"* ]] && pass "reported nothing to do" || fail "did not report nothing to do: $OUT"
incrementals_intact "$T" && pass "nothing deleted when neither trigger fires" || fail "deleted something with no trigger"

# ── 4. skip-when-building ────────────────────────────────────────────────────
echo "== 4. skip when a build is in progress =="
: > "$AMB"; : > "$BUILD_FLAG"
T="$WORK/t4"; make_target "$T"
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
rm -f "$BUILD_FLAG"
(( rc == 0 )) && pass "skip-building exits 0" || fail "should exit 0, got $rc"
incrementals_intact "$T" && pass "build-in-progress guard prevented the reap" || fail "reaped while a build was alive — guard broken"
grep -q '"reason":"build_in_progress"' "$AMB" && pass "logged build_in_progress skip reason" || fail "missing build_in_progress skip reason: $OUT"

# ── 5. skip-when-admit-refused ───────────────────────────────────────────────
echo "== 5. skip when chump admit cargo refuses =="
: > "$AMB"; : > "$ADMIT_REFUSE"
T="$WORK/t5"; make_target "$T"
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
rm -f "$ADMIT_REFUSE"
(( rc == 0 )) && pass "skip-admit exits 0" || fail "should exit 0, got $rc"
incrementals_intact "$T" && pass "admit-refused guard prevented the reap" || fail "reaped while admit refused — guard broken"
grep -q '"reason":"admit_refused"' "$AMB" && pass "logged admit_refused skip reason" || fail "missing admit_refused skip reason: $OUT"

# hold_lock <lockfile> → echoes the holder PID (drop it by killing the PID).
hold_lock() {
  local lf="$1"
  ( exec 7>>"$lf" && flock 7 && exec sleep 300 ) >/dev/null 2>&1 &
  local pid="$!"
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if flock -n "$lf" true 2>/dev/null; then sleep 0.2; else break; fi
  done
  echo "$pid"
}

# ── 6. skip-when-locked: architect lane-1 held ───────────────────────────────
echo "== 6. skip when architect lane-1 lock is held =="
: > "$AMB"
T="$WORK/t6"; make_target "$T"
HOLDER="$(hold_lock "$LANE_LOCK_1")"; BG_PIDS+=("$HOLDER")
flock -n "$LANE_LOCK_1" true 2>/dev/null && fail "(6) fixture could not take lane-1 lock"
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
(( rc == 0 )) && pass "skip-lane1 exits 0" || fail "should exit 0, got $rc"
incrementals_intact "$T" && pass "lane-1 lock guard prevented the reap" || fail "reaped while lane-1 held — guard broken"
grep -q '"reason":"lane1_held"' "$AMB" && pass "logged lane1_held skip reason" || fail "missing lane1_held skip reason: $OUT"
[[ "$OUT" == *"$LANE_LOCK_1"* ]] && pass "reported the lane-1 lock path" || fail "did not report the lane-1 lock path: $OUT"

# ── 7. skip-when-locked: architect lane-2 held (lane-1 free) ─────────────────
echo "== 7. skip when architect lane-2 lock is held =="
: > "$AMB"
T="$WORK/t7"; make_target "$T"
HOLDER="$(hold_lock "$LANE_LOCK_2")"; BG_PIDS+=("$HOLDER")
flock -n "$LANE_LOCK_2" true 2>/dev/null && fail "(7) fixture could not take lane-2 lock"
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
(( rc == 0 )) && pass "skip-lane2 exits 0" || fail "should exit 0, got $rc"
incrementals_intact "$T" && pass "lane-2 lock guard prevented the reap" || fail "reaped while lane-2 held — guard broken"
grep -q '"reason":"lane2_held"' "$AMB" && pass "logged lane2_held skip reason" || fail "missing lane2_held skip reason: $OUT"

# ── 8. safety inputs take no env override ────────────────────────────────────
echo "== 8. env cannot change the budget or the target (reads removed) =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
# (a) a huge CHUMP_SHARED_TARGET_CAP_GB env must NOT raise the budget: with the
#     CLI --budget-gb 0 the reap must still fire.
T="$WORK/t8a"; make_target "$T"
export CHUMP_SHARED_TARGET_CAP_GB=999999
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
unset CHUMP_SHARED_TARGET_CAP_GB
incrementals_gone "$T" && pass "CHUMP_SHARED_TARGET_CAP_GB env ignored (CLI budget wins)" || fail "env cap suppressed the reap — env read not removed"
# (b) a CHUMP_SHARED_TARGET env pointing at a decoy must NOT redirect the reap:
#     only the --target CLI arg decides, and the decoy must be untouched.
DECOY="$WORK/decoy-target"; make_target "$DECOY"
T="$WORK/t8b"; make_target "$T"
export CHUMP_SHARED_TARGET="$DECOY"
OUT="$(run_reaper "$T" --execute --budget-gb 0 --floor-gb 0)"; rc=$?
unset CHUMP_SHARED_TARGET
incrementals_gone "$T" && pass "CLI --target reaped (not the env target)" || fail "CLI target not reaped"
incrementals_intact "$DECOY" && pass "CHUMP_SHARED_TARGET env target untouched (read removed)" || fail "env target got reaped — env read not removed"
# And the production script must READ none of the removed env vars (a $-prefixed
# expansion; the header comment naming them for history is fine, a read is not).
grep -qE '\$\{?CHUMP_SHARED_TARGET' "$REAPER" \
  && fail "the reaper still reads a removed CHUMP_SHARED_TARGET* env var" \
  || pass "no CHUMP_SHARED_TARGET* safety-input env reads remain in the reaper"

# ── 9. disk-pressure-reaper wiring ───────────────────────────────────────────
echo "== 9. disk-pressure-reaper wires the reaper before its ≥50GB early-exit =="
grep -q 'shared-target-cache-reaper.sh' "$PRESSURE" && pass "disk-pressure-reaper references the reaper" || fail "disk-pressure-reaper does not invoke the reaper"
reaper_call_line=$(grep -n 'SHARED_TARGET_REAPER"' "$PRESSURE" | tail -1 | cut -d: -f1)
early_exit_line=$(grep -n 'idle (≥ 50GB threshold)' "$PRESSURE" | head -1 | cut -d: -f1)
if [[ -n "$reaper_call_line" && -n "$early_exit_line" ]] && (( reaper_call_line < early_exit_line )); then
  pass "reaper runs before the ≥50GB early-exit (proactive, not tier-gated)"
else
  fail "reaper must run before the ≥50GB early-exit (call=$reaper_call_line exit=$early_exit_line)"
fi

# ── 10. DEFAULT gate fires (the only gate production uses) ───────────────────
echo "== 10. defaults-only invocation reaps when du/df cross the default budget/floor =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
make_target "$DEFAULT_TARGET"
echo trigger > "$DU_DF_MODE"                       # du→99G (>15 budget), df→10G (<25 floor)
OUT="$(run_reaper_defaults --execute)"; rc=$?
rm -f "$DU_DF_MODE"
(( rc == 0 )) && pass "defaults-only execute exits 0" || fail "should exit 0, got $rc: $OUT"
incrementals_gone "$DEFAULT_TARGET" && pass "DEFAULT budget/floor triggered the reap (no CLI thresholds)" || fail "default gate did not fire — defaults never-fire would survive: $OUT"
keeps_intact "$DEFAULT_TARGET" && pass "default-target root + non-incremental output preserved" || fail "default reap removed non-incremental output / the target root"
grep -q '"kind":"shared_target_incremental_reaped"' "$AMB" && pass "emitted reaped event on default gate" || fail "missing reaped event on default gate"

# ── 11. DEFAULT under-threshold → nothing to do ──────────────────────────────
echo "== 11. defaults-only invocation does nothing when target small + disk fine =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
make_target "$DEFAULT_TARGET"
echo safe > "$DU_DF_MODE"                           # du→1G (<15 budget), df→999G (>25 floor)
OUT="$(run_reaper_defaults --execute)"; rc=$?
rm -f "$DU_DF_MODE"
(( rc == 0 )) && pass "defaults-only under-threshold exits 0" || fail "should exit 0, got $rc: $OUT"
[[ "$OUT" == *"nothing to do"* ]] && pass "reported nothing to do under the defaults" || fail "did not report nothing to do: $OUT"
incrementals_intact "$DEFAULT_TARGET" && pass "nothing deleted when neither default trigger fires" || fail "deleted something under the defaults with no trigger"

# ── 12. unknown CLI arg fails closed (exit 2, nothing deleted) ───────────────
echo "== 12. a bogus flag exits 2 and deletes nothing =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
T="$WORK/t12"; make_target "$T"
echo trigger > "$DU_DF_MODE"   # if exit 2 were dropped the --execute reaper WOULD reap
OUT="$(run_reaper "$T" --execute --bogus)"; rc=$?
rm -f "$DU_DF_MODE"
(( rc == 2 )) && pass "unknown arg exits 2 (fail-closed)" || fail "unknown arg should exit 2, got $rc: $OUT"
incrementals_intact "$T" && pass "nothing deleted on a bad arg" || fail "a bad arg deleted an incremental dir — fail-open"

# ── 13. FLOOR-only default gate: under_floor alone drives the reap ────────────
# du→1G (< BUDGET_GB_DEFAULT 15, budget MISS) but df→10G avail (< FLOOR_GB_DEFAULT
# 25, floor FIRE). Defaults-only invocation (no CLI thresholds) so this isolates
# the DEFAULT floor trigger: dropping the under_floor arm (M1) or flipping
# FLOOR_GB_DEFAULT→0 (M2) makes this reap NOT fire → caught. This is the exact
# RESILIENT-1635 "disk tight but target under the size budget" scenario.
echo "== 13. FLOOR-only: under_floor alone (budget miss) triggers the reap =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
make_target "$DEFAULT_TARGET"
echo floor > "$DU_DF_MODE"                          # du→1G (<15 budget), df→10G (<25 floor)
OUT="$(run_reaper_defaults --execute)"; rc=$?
rm -f "$DU_DF_MODE"
(( rc == 0 )) && pass "floor-only defaults execute exits 0" || fail "should exit 0, got $rc: $OUT"
[[ "$OUT" == *"free disk under floor"* ]] && pass "reap reason is the floor (not the budget)" || fail "reap was not driven by the floor trigger: $OUT"
[[ "$OUT" == *"over budget"* ]] && fail "budget was reported over when the target is under budget: $OUT" || pass "budget correctly NOT over (floor is the sole trigger)"
incrementals_gone "$DEFAULT_TARGET" && pass "under_floor alone drove the reap (M1/M2 would not fire here)" || fail "floor trigger did not fire — under_floor arm unpinned: $OUT"
keeps_intact "$DEFAULT_TARGET" && pass "target root + non-incremental output preserved under floor-only reap" || fail "floor-only reap removed non-incremental output / the target root"
grep -q '"kind":"shared_target_incremental_reaped"' "$AMB" && pass "emitted reaped event on the floor-only gate" || fail "missing reaped event on the floor-only gate"

# ── 14. BUDGET-only default gate: over_budget alone drives the reap ───────────
# du→99G (> BUDGET_GB_DEFAULT 15, budget FIRE) but df→999G avail (> FLOOR_GB_DEFAULT
# 25, floor MISS). Defaults-only so this isolates the DEFAULT budget trigger:
# flipping BUDGET_GB_DEFAULT→huge (M3) makes this reap NOT fire → caught.
echo "== 14. BUDGET-only: over_budget alone (floor miss) triggers the reap =="
: > "$AMB"; rm -f "$BUILD_FLAG" "$ADMIT_REFUSE"
make_target "$DEFAULT_TARGET"
echo budget > "$DU_DF_MODE"                         # du→99G (>15 budget), df→999G (>25 floor)
OUT="$(run_reaper_defaults --execute)"; rc=$?
rm -f "$DU_DF_MODE"
(( rc == 0 )) && pass "budget-only defaults execute exits 0" || fail "should exit 0, got $rc: $OUT"
[[ "$OUT" == *"over budget"* ]] && pass "reap reason is the budget (not the floor)" || fail "reap was not driven by the budget trigger: $OUT"
[[ "$OUT" == *"free disk under floor"* ]] && fail "floor was reported under when disk is plentiful: $OUT" || pass "floor correctly NOT under (budget is the sole trigger)"
incrementals_gone "$DEFAULT_TARGET" && pass "over_budget alone drove the reap (M3 would not fire here)" || fail "budget trigger did not fire — over_budget unpinned: $OUT"
keeps_intact "$DEFAULT_TARGET" && pass "target root + non-incremental output preserved under budget-only reap" || fail "budget-only reap removed non-incremental output / the target root"
grep -q '"kind":"shared_target_incremental_reaped"' "$AMB" && pass "emitted reaped event on the budget-only gate" || fail "missing reaped event on the budget-only gate"

echo ""
if (( fails == 0 )); then echo "PASS test-shared-target-cache-reaper"; exit 0
else echo "FAIL ($fails) test-shared-target-cache-reaper"; exit 1; fi
