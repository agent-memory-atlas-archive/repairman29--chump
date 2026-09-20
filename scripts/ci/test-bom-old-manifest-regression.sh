#!/usr/bin/env bash
# scripts/ci/test-bom-old-manifest-regression.sh — INFRA-7769
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (INFRA-7756, one-command-
# install BOM unification, slice A). INFRA-7768 proved the FOUR unified-BOM
# consumers agree with each other on a synthetic manifest that already has
# platforms=/housekeeping= tokens. This test proves the other half: that a
# REAL, pre-unification organ-manifest.txt — the actual three-separate-
# rosters world this slice replaced (organ-manifest.txt with no platforms=,
# bootstrap-manifest.yaml as an independent installer list, and
# install-node-housekeeping.sh's own hardcoded 10-organ heredoc) — is
# handled the way the design requires, not silently mishandled:
#
#   1. The old-shape manifest still PARSES (organ_manifest_parse is
#      backward-compatible — no crash on a file with zero platforms= lines).
#   2. Every unit's platform defaults to "systemd", exactly as
#      organ-manifest-lib.sh's header documents — proven against a REAL
#      historical file, not just a hand-rolled synthetic one.
#   3. render-organ-roster.sh --platform launchd on the OLD manifest alone
#      renders NOTHING — the concrete, measurable gap unification closed:
#      before INFRA-7765 folded bootstrap-manifest.yaml in, organ-manifest.txt
#      alone could not describe a single macOS-applicable organ.
#   4. housekeeping_organs_from_manifest() on the OLD manifest emits the
#      EXACT documented WARN (INFRA-7766) and falls back to the exact
#      built-in 10-organ roster — the "specific error" this gap's
#      acceptance criteria call for, and the load-bearing proof that the
#      fallback is reachable by a genuinely old file, not just a synthetic
#      one-liner.
#   5. The SAME function, run against the CURRENT real organ-manifest.txt,
#      does NOT emit that WARN and returns the real derived roster instead —
#      so this test only passes because the unified BOM's housekeeping=
#      tokens are present TODAY. Revert INFRA-7766 (or strip organ-
#      manifest.txt back to the old shape) and this assertion is the one
#      that catches it — "the unified BOM is missing" is exactly the
#      condition this test is conditioned on (INFRA-7769 AC #2).
#
# Old-manifest content lives in scripts/ci/fixtures/organ-manifest-pre-
# unification.txt — lines copied verbatim from commit
# e16215781d8c388701140f971235951c010141a1 (the last commit before
# INFRA-7764), frozen as a static fixture rather than fetched via `git show`
# because CI checkouts are shallow (actions/checkout@v7 default depth=1) and
# cannot reach that commit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MANIFEST_LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
HK_LIB="$REPO_ROOT/scripts/ops/lib/node-housekeeping-roster-lib.sh"
RENDERER="$REPO_ROOT/scripts/ops/render-organ-roster.sh"
REAL_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
OLD_MANIFEST="$SCRIPT_DIR/fixtures/organ-manifest-pre-unification.txt"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-bom-old-manifest-regression.sh (INFRA-7769) ==="

for f in "$MANIFEST_LIB" "$HK_LIB" "$RENDERER" "$REAL_MANIFEST" "$OLD_MANIFEST"; do
  [[ -e "$f" ]] || fail "missing $f"
done

# shellcheck disable=SC1090
source "$MANIFEST_LIB"
# shellcheck disable=SC1090
source "$HK_LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Sanity on the fixture itself: it really is old-shape (this test is
# meaningless if someone "helpfully" adds the new tokens to it).
grep -v '^#' "$OLD_MANIFEST" | grep -q "platforms=" && fail "fixture must NOT contain platforms= — it would no longer be old-shape"
grep -v '^#' "$OLD_MANIFEST" | grep -q "housekeeping=" && fail "fixture must NOT contain housekeeping= — it would no longer be old-shape"
pass "fixture genuinely has zero platforms=/housekeeping= tokens (still old-shape)"

# ── 1+2. Old manifest still parses; every unit defaults to platforms=systemd ──
OLD_OFF=(); OLD_EN=(); declare -A OLD_ROLE; declare -A OLD_REQ; declare -A OLD_PLAT
organ_manifest_parse "$OLD_MANIFEST" OLD_OFF OLD_EN OLD_ROLE OLD_REQ OLD_PLAT \
  || fail "organ_manifest_parse must still parse a real pre-unification manifest (backward compat)"
[[ "${#OLD_EN[@]}" -gt 0 ]] || fail "expected at least one enabled unit from the old-shape fixture"
for unit in "${OLD_EN[@]}"; do
  [[ "${OLD_PLAT[$unit]:-systemd}" == "systemd" ]] \
    || fail "unit $unit from an old-shape manifest must default to platforms=systemd, got: ${OLD_PLAT[$unit]:-}"
done
pass "organ_manifest_parse parses the real old-shape manifest and defaults every unit to platforms=systemd"

# ── 3. Old manifest alone cannot render a single launchd-applicable organ ──
out_launchd="$("$RENDERER" --platform launchd --manifest "$OLD_MANIFEST")"
[[ -z "$out_launchd" ]] \
  || fail "old-shape organ-manifest.txt alone must render ZERO launchd-applicable organs (that's what bootstrap-manifest.yaml's fold-in fixed); got: $out_launchd"
pass "render-organ-roster.sh --platform launchd on the old manifest alone renders nothing — the exact pre-fold-in gap"

# ── 4. Old manifest: housekeeping lib fires the specific WARN + exact fallback roster ──
old_hk_out="$(housekeeping_organs_from_manifest "$OLD_MANIFEST" 2>"$TMP/hk-old.err")"
grep -q "WARN (INFRA-7766): no housekeeping= lines found in $OLD_MANIFEST" "$TMP/hk-old.err" \
  || fail "old-shape manifest must trigger the exact documented INFRA-7766 WARN"

expected_fallback="node-orchestrator
rot-reaper
worktree-reaper
disk-monitor
main-health-watchdog
pr-lander
cargo-sweep-gc
reviver
pr-stuck-live-scan
pr-stuck-cluster-detector"
old_hk_names="$(echo "$old_hk_out" | awk -F'|' '{print $1}')"
[[ "$old_hk_names" == "$expected_fallback" ]] \
  || fail "old-shape manifest must fall back to the EXACT pre-INFRA-7766 10-organ roster in order; got:
$old_hk_names"
pass "housekeeping_organs_from_manifest fires the specific INFRA-7766 WARN and returns the exact frozen 10-organ fallback roster on a real old-shape manifest"

# ── 5. The CURRENT real manifest must NOT trigger that fallback — this is the ──
#      assertion that only passes because the unified BOM exists today.
current_hk_out="$(housekeeping_organs_from_manifest "$REAL_MANIFEST" 2>"$TMP/hk-current.err")"
grep -q "WARN (INFRA-7766)" "$TMP/hk-current.err" \
  && fail "the CURRENT organ-manifest.txt triggered the old-shape fallback WARN — the unified BOM (housekeeping= tokens) is missing today; INFRA-7766 has regressed"
current_hk_names="$(echo "$current_hk_out" | awk -F'|' '{print $1}')"
[[ "$current_hk_names" != "$expected_fallback" ]] \
  || fail "the CURRENT manifest produced the exact fallback roster by coincidence-or-regression — expected a REAL derived roster, not the old-shape fallback"
pass "the CURRENT organ-manifest.txt does NOT trigger the old-shape fallback — proves this test's pass/fail is conditioned on the unified BOM actually being present (INFRA-7769 AC #2)"

echo "ALL PASS"
