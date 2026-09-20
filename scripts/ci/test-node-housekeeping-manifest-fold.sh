#!/usr/bin/env bash
# scripts/ci/test-node-housekeeping-manifest-fold.sh — INFRA-7766
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (one-command-install BOM
# unification, INFRA-7756): install-node-housekeeping.sh's hardcoded
# 10-organ ORGANS= heredoc is folded into organ-manifest.txt (housekeeping=
# tokens on 8 of the 10 lines, plus a documented 2-organ naming-collision
# carve-out — see node-housekeeping-roster-lib.sh) so the script becomes a
# thin caller instead of hardcoding its own roster.
#
# Proves:
#   1. install-node-housekeeping.sh no longer defines its own ORGANS
#      heredoc — it sources node-housekeeping-roster-lib.sh and calls
#      housekeeping_organs_from_manifest().
#   2. The 8 non-colliding organs each have a real, role-tagged
#      organ-manifest.txt line carrying a housekeeping= token, AND a
#      requires=file:~/.chump/organs/<name>.sh guard (so organ-reconcile
#      SKIPS them on any node that hasn't run install-node-housekeeping.sh
#      — never force-installs into a backoff loop).
#   3. Feeding the real organ-manifest.txt into
#      housekeeping_organs_from_manifest() reproduces the exact 10-organ,
#      byte-identical-to-pre-INFRA-7766 roster (8 manifest-sourced + 2
#      carve-out).
#
# Without INFRA-7766, step 1 fails (the old heredoc is still there) and
# step 3 fails (the function/lib doesn't exist yet).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOUSEKEEPING="$REPO_ROOT/scripts/setup/install-node-housekeeping.sh"
ROSTER_LIB="$REPO_ROOT/scripts/ops/lib/node-housekeeping-roster-lib.sh"
ORGAN_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-node-housekeeping-manifest-fold.sh (INFRA-7766) ==="

[[ -f "$HOUSEKEEPING" ]] || fail "missing $HOUSEKEEPING"
[[ -f "$ROSTER_LIB" ]] || fail "missing $ROSTER_LIB"
bash -n "$HOUSEKEEPING" || fail "install-node-housekeeping.sh bash -n failed"
bash -n "$ROSTER_LIB" || fail "node-housekeeping-roster-lib.sh bash -n failed"
pass "scripts present, syntax clean"

grep -q 'housekeeping_organs_from_manifest' "$HOUSEKEEPING" \
  || fail "install-node-housekeeping.sh does not call housekeeping_organs_from_manifest() — still hardcoding its own roster?"
grep -qE '^ORGANS="node-orchestrator\|scripts/ops/node-orchestrator\.sh\|0$' "$HOUSEKEEPING" \
  && fail "install-node-housekeeping.sh still carries the old hardcoded ORGANS= heredoc verbatim — regression to pre-INFRA-7766 shape"
pass "install-node-housekeeping.sh no longer hardcodes its own ORGANS heredoc"

# 8 non-colliding organs: real manifest lines with role=, housekeeping=, and
# a file: requires= guard.
NON_COLLIDING=(node-orchestrator worktree-reaper disk-monitor main-health-watchdog cargo-sweep-gc reviver pr-stuck-live-scan pr-stuck-cluster-detector)
for name in "${NON_COLLIDING[@]}"; do
  line="$(grep -E "^enabled +chump-${name//./\\.}\.service" "$ORGAN_MANIFEST")"
  [[ -n "$line" ]] || fail "organ-manifest.txt missing 'enabled chump-$name.service' line"
  echo "$line" | grep -q 'role=' || fail "chump-$name.service line has no role="
  echo "$line" | grep -q "housekeeping=" || fail "chump-$name.service line has no housekeeping= token"
  echo "$line" | grep -q "requires=.*file:~/.chump/organs/$name.sh" \
    || fail "chump-$name.service line's requires= must guard on file:~/.chump/organs/$name.sh so a node without housekeeping installed SKIPS it; got: $line"
done
pass "all 8 non-colliding housekeeping organs have role=/housekeeping=/file:-guarded organ-manifest.txt lines"

# The 2 documented collisions must NOT get a fresh organ-manifest.txt line
# with housekeeping= (they'd collide with the pre-existing chump-pr-lander /
# chump-rot-reaper units already declared for a different capability).
for name in pr-lander rot-reaper; do
  grep -E "^enabled +chump-${name}\.service.*housekeeping=" "$ORGAN_MANIFEST" \
    && fail "chump-$name.service must NOT carry a housekeeping= token in organ-manifest.txt (documented naming collision, INFRA-7772) — got a match"
done
pass "the 2 documented pr-lander/rot-reaper naming collisions carry no housekeeping= organ-manifest.txt line"

# ── Round-trip: real manifest -> derived roster == pre-INFRA-7766 roster ───
# shellcheck source=../ops/lib/node-housekeeping-roster-lib.sh
source "$ROSTER_LIB"
derived="$(housekeeping_organs_from_manifest "$ORGAN_MANIFEST" 2>/dev/null)"
expected="node-orchestrator|scripts/ops/node-orchestrator.sh|0
rot-reaper|scripts/ops/rot-reaper.sh|1800
worktree-reaper|scripts/ops/stale-worktree-reaper.sh --execute|900
disk-monitor|scripts/ops/disk-health-monitor.sh|300
main-health-watchdog|scripts/ops/main-health-watchdog.sh|600
pr-lander|scripts/dispatch/pr-lander-beat.sh|600
cargo-sweep-gc|scripts/ops/cargo-sweep-gc.sh|3600
reviver|scripts/coord/post-push-integrity-watch.sh|60
pr-stuck-live-scan|scripts/ops/stuck-pr-filer.sh|3600
pr-stuck-cluster-detector|scripts/coord/pr-stuck-cluster-detector.sh --apply|1800"

derived_sorted="$(printf '%s\n' "$derived" | sort)"
expected_sorted="$(printf '%s\n' "$expected" | sort)"
[[ "$derived_sorted" == "$expected_sorted" ]] \
  || fail "derived roster does not match the pre-INFRA-7766 roster (order-independent set compare).
--- derived ---
$derived_sorted
--- expected ---
$expected_sorted"
pass "real organ-manifest.txt derives the byte-identical pre-INFRA-7766 10-organ roster (set-equal)"

echo "ALL PASS"
