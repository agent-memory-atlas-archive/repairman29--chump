#!/usr/bin/env bash
# test-fleet-clone-index.sh — RESILIENT-1351
#
# Proves scripts/ops/fleet-clone-index.sh — the org-wide clone→index→untether
# sweep that gives almanac the WHOLE repairman29 org — behaves correctly,
# WITHOUT touching the network or the real almanac/chump binaries. It runs the
# sweep against a fake `gh` (org enumeration + clone) and a fake `almanac`
# (repos/index/untether/refresh) placed first on PATH, in a throwaway HOME.
#
# This is deliberately a shell test, not a Rust cargo test: the unit under test
# IS a bash orchestrator around external CLIs (gh, git, almanac) with a
# disk-floor guard — the thing worth proving is the multi-process glue and the
# escalation branch, which a cargo test cannot reach. It never invokes the
# chump binary.
#
# Covers (depth: happy-path + the disk-floor adversarial branch):
#   1. the sweep script exists + is executable (fails without the change)
#   2. --dry-run enumerates the org and emits almanac_fleet_clone_started,
#      makes zero clones
#   3. a full run skips already-registered repos, clones+indexes+untethers the
#      rest, drops worktrees (standing disk = indexes only), emits
#      almanac_fleet_clone_completed with newly_indexed > 0
#   4. DISK-FLOOR ESCALATION: when free space is below the floor, the sweep
#      STOPS before cloning, keeps a partial index, exits 0, and emits
#      almanac_fleet_clone_disk_floor with the exact numbers
# Gaps: does not exercise a real gh/almanac, real disk exhaustion, or the
#   systemd timer wiring (that's install-fleet-clone-index-timer.sh --check).

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWEEP="$REPO_ROOT/scripts/ops/fleet-clone-index.sh"

echo "=== RESILIENT-1351 fleet-clone-index sweep tests ==="

# ── Test 1: script present + executable (this is the fail-without-change gate) ─
if [[ -x "$SWEEP" ]]; then ok "sweep script present + executable"
else bad "sweep script missing/non-executable at $SWEEP"; echo "FAIL"; exit 1; fi

# ── Build the hermetic fixture ────────────────────────────────────────────────
WORK="$(mktemp -d -t fleet-clone-index.XXXXXX)"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
CACHE="$WORK/repos-cache"
CHUMP_ROOT="$WORK/chump-root"; mkdir -p "$CHUMP_ROOT/.chump-locks"
AMBIENT="$CHUMP_ROOT/.chump-locks/ambient.jsonl"

# Fake `gh`: enumerate a 3-repo org, auth OK, clone materializes a source file.
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo list")
    # org repos: one already-registered ("almanac"), two new.
    printf '%s\n' almanac widget-alpha widget-beta ;;
  "repo clone")
    # gh repo clone ORG/NAME DIR -- <gitargs...>
    dir="$4"
    mkdir -p "$dir/.git" "$dir/src"
    echo "fn main() {}" > "$dir/src/main.rs"
    exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$FAKEBIN/gh"

# Fake `almanac`: repos/index/untether/refresh. untether simulates drop-worktree.
cat > "$FAKEBIN/almanac" <<'ALM'
#!/usr/bin/env bash
case "$1" in
  repos)
    # header line first (sweep reads count from it), then registered rows.
    echo "1 repo(s):"
    echo "almanac              deadbeef  worktree  [/somewhere/almanac]" ;;
  index)   exit 0 ;;
  untether)
    # $2 = slug; simulate --drop-worktree by removing the cache clone.
    [ -n "${ALMANAC_REPO_CACHE:-}" ] && rm -rf "${ALMANAC_REPO_CACHE:?}/$2"
    exit 0 ;;
  refresh) exit 0 ;;
  *) exit 0 ;;
esac
ALM
chmod +x "$FAKEBIN/almanac"

run_sweep() {  # extra args...
  PATH="$FAKEBIN:$PATH" \
  ALMANAC_BIN="$FAKEBIN/almanac" \
  CHUMP_FLEET_ORG="repairman29" \
  ALMANAC_REPO_CACHE="$CACHE" \
  ALMANAC_HOME="$WORK/almanac-home" \
  CHUMP_REPO_ROOT="$CHUMP_ROOT" \
  ALMANAC_CLONE_MARKER="$WORK/marker.last" \
  ALMANAC_CLONE_LOG="$WORK/sweep.log" \
  bash "$SWEEP" "$@"
}

# ── Test 2: --dry-run enumerates, emits started, clones nothing ───────────────
: > "$AMBIENT"; rm -rf "$CACHE"
if run_sweep --dry-run >/dev/null 2>&1; then ok "dry-run exits 0"
else bad "dry-run exited non-zero"; fi
if grep -q '"kind":"almanac_fleet_clone_started"' "$AMBIENT"; then ok "dry-run emitted almanac_fleet_clone_started"
else bad "dry-run did not emit almanac_fleet_clone_started"; fi
if [[ ! -d "$CACHE" ]] || [[ -z "$(ls -A "$CACHE" 2>/dev/null)" ]]; then ok "dry-run made zero clones"
else bad "dry-run left clones in cache"; fi

# ── Test 3: full run — skip registered, clone+index+untether the rest ─────────
: > "$AMBIENT"; rm -rf "$CACHE"
if run_sweep --no-refresh >/dev/null 2>&1; then ok "full run exits 0"
else bad "full run exited non-zero"; fi
comp="$(grep '"kind":"almanac_fleet_clone_completed"' "$AMBIENT" | tail -1)"
if [[ -n "$comp" ]]; then ok "full run emitted almanac_fleet_clone_completed"
else bad "no almanac_fleet_clone_completed event"; fi
# 2 new repos (widget-alpha, widget-beta); almanac was already registered → skipped.
if grep -q '"newly_indexed":2' <<<"$comp"; then ok "indexed the 2 new repos, skipped already-registered"
else bad "expected newly_indexed:2, got: $comp"; fi
if grep -q '"already_registered":1' <<<"$comp"; then ok "skipped the 1 already-registered repo"
else bad "expected already_registered:1, got: $comp"; fi
# untether --drop-worktree removed the worktrees → cache holds no clones.
if [[ -z "$(ls -A "$CACHE" 2>/dev/null)" ]]; then ok "worktrees dropped after index (standing disk = indexes only)"
else bad "cache still holds clones after untether: $(ls -A "$CACHE" 2>/dev/null)"; fi

# ── Test 4: DISK-FLOOR ESCALATION ─────────────────────────────────────────────
: > "$AMBIENT"; rm -rf "$CACHE"
# Floor absurdly high → the pre-clone check trips before any clone.
if ALMANAC_DISK_FLOOR_GB=99999999 run_sweep --no-refresh >/dev/null 2>&1; then ok "disk-floor run still exits 0 (partial, coordinator stays healthy)"
else bad "disk-floor run exited non-zero (should degrade gracefully)"; fi
esc="$(grep '"kind":"almanac_fleet_clone_disk_floor"' "$AMBIENT" | tail -1)"
if [[ -n "$esc" ]]; then ok "disk-floor emitted the escalation event almanac_fleet_clone_disk_floor"
else bad "no almanac_fleet_clone_disk_floor escalation event"; fi
if grep -q '"newly_indexed":0' <<<"$esc" && grep -q '"stopped_before":' <<<"$esc"; then
  ok "escalation carries the numbers (newly_indexed + stopped_before repo)"
else bad "escalation event missing numbers: $esc"; fi
if [[ -z "$(ls -A "$CACHE" 2>/dev/null)" ]]; then ok "disk-floor made zero clones (stopped before cloning)"
else bad "disk-floor left clones despite being under the floor"; fi

echo ""
echo "=== fleet-clone-index: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
