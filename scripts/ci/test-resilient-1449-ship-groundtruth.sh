#!/usr/bin/env bash
# test-resilient-1449-ship-groundtruth.sh — RESILIENT-1449
#
# The worker cycle-outcome classifier used to emit FALSE failed/unverified_ship
# for cycles that actually shipped: the session pushed the branch, created the
# PR and armed auto-merge, then sat QUIET polling `gh pr view` for its own
# merge. That produced no stdout for 120s, so the INFRA-705 stall-detector
# killed it (rc=143) and the cycle was classified "failed" — even though the PR
# existed and may already have merged (RESILIENT-1123 logged rc=1 yet PR #4812
# MERGED; EFFECTIVE-1015 was stall-killed mid-poll but PR #4813 was created).
#
# Two coupled fixes are verified here, testing the REAL functions extracted
# from scripts/dispatch/worker.sh (not replicas — durable-fix doctrine, same
# pattern as test-stall-detector-build-aware.sh):
#   (1) _detect_ship_evidence — ground truth: a cycle whose branch has a PR is
#       SHIPPED. Consulted before any failed/unverified verdict.
#   (2) _cycle_log_shows_ship — a post-ship merge-poll is recognized so the
#       stall-detector extends its no-output threshold instead of killing.
# Plus structural assertions that worker.sh wires both into the classifier and
# the stall-detector, and that the new ambient kind is registered.
#
# Run: ./scripts/ci/test-resilient-1449-ship-groundtruth.sh
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
[[ -f "$WORKER" ]] || { echo "FAIL: worker.sh not found"; exit 1; }

echo "=== RESILIENT-1449 ship-ground-truth tests ==="

# ── Extract + load the REAL functions from worker.sh ─────────────────────────
_fn_dse="$(sed -n '/^_detect_ship_evidence() {/,/^}/p' "$WORKER")"
_fn_cls="$(sed -n '/^_cycle_log_shows_ship() {/,/^}/p' "$WORKER")"
if [[ -n "$_fn_dse" ]]; then eval "$_fn_dse"; fi
if [[ -n "$_fn_cls" ]]; then eval "$_fn_cls"; fi
if type _detect_ship_evidence >/dev/null 2>&1; then
    ok "extracted + loaded the real _detect_ship_evidence from worker.sh"
else
    fail "could not extract _detect_ship_evidence from worker.sh"
fi
if type _cycle_log_shows_ship >/dev/null 2>&1; then
    ok "extracted + loaded the real _cycle_log_shows_ship from worker.sh"
else
    fail "could not extract _cycle_log_shows_ship from worker.sh"
fi

# ── Behavioral: _detect_ship_evidence consults ground truth ──────────────────
# Hermetic: point REPO_ROOT at a dir with NO cache db, and shim gh/chump on PATH.
_shimdir="$(mktemp -d)"
_repo_noship="$(mktemp -d)"   # no .chump/github_cache.db → cache branch skipped
export PATH="$_shimdir:$PATH"

# chump shim: always reports gap status "open" (no ship-status shortcut).
cat > "$_shimdir/chump" <<'SH'
#!/usr/bin/env bash
echo "  status: open"
SH
chmod +x "$_shimdir/chump"

# Scenario A: a PR exists for the branch → gh returns its number → SHIPPED.
cat > "$_shimdir/gh" <<'SH'
#!/usr/bin/env bash
# `gh pr list ... --jq '.[0].number // empty'` → print the PR number.
echo "4813"
SH
chmod +x "$_shimdir/gh"
_out="$(REPO_ROOT="$_repo_noship" _detect_ship_evidence RESILIENT-1449 chump/resilient-1449-claim)"; _rc=$?
if [[ $_rc -eq 0 && "$_out" == "4813" ]]; then
    ok "branch WITH a PR → _detect_ship_evidence returns evidence (rc=0, '$_out') → cycle SHIPPED, not failed"
else
    fail "branch WITH a PR should return evidence; got rc=$_rc out='$_out'"
fi

# Scenario B: no PR anywhere → gh returns empty → NO evidence.
cat > "$_shimdir/gh" <<'SH'
#!/usr/bin/env bash
echo ""
SH
chmod +x "$_shimdir/gh"
_out="$(REPO_ROOT="$_repo_noship" _detect_ship_evidence RESILIENT-1449 chump/resilient-1449-claim)"; _rc=$?
if [[ $_rc -ne 0 && -z "$_out" ]]; then
    ok "branch with NO PR → _detect_ship_evidence returns nothing (rc=$_rc) → not a false shipped"
else
    fail "branch with NO PR should return no evidence; got rc=$_rc out='$_out'"
fi
rm -rf "$_shimdir" "$_repo_noship"

# ── Behavioral: _cycle_log_shows_ship recognizes the post-ship phase ─────────
_log="$(mktemp)"
printf 'thinking...\nrunning bot-merge\nhttps://github.com/repairman29/chump/pull/4813\n' > "$_log"
if _cycle_log_shows_ship "$_log"; then
    ok "log with a PR URL → post-ship recognized → stall-detector extends timeout (poll not killed)"
else
    fail "PR-URL log should be recognized as post-ship"
fi
printf 'PR #4813 armed for auto-merge\n' > "$_log"
if _cycle_log_shows_ship "$_log"; then
    ok "log with 'armed for auto-merge' → post-ship recognized"
else
    fail "'armed for auto-merge' log should be recognized as post-ship"
fi
printf 'thinking...\nediting src/main.rs\nrunning cargo build\n' > "$_log"
if _cycle_log_shows_ship "$_log"; then
    fail "a NON-shipped log must NOT be treated as post-ship (would weaken the 120s stall guard)"
else
    ok "non-shipped log → NOT post-ship → normal 120s stall threshold still enforced"
fi
rm -f "$_log"

# ── Structural: classifier consults ground truth before "failed" ────────────
if grep -q 'CHUMP_SHIP_GROUNDTRUTH_RECHECK' "$WORKER" && \
   grep -q 'cycle_reclassified_shipped' "$WORKER"; then
    ok "worker.sh reclassifies failed→shipped when ground truth shows a PR (RESILIENT-1449)"
else
    fail "worker.sh missing the failed→shipped ground-truth reclassification"
fi
# The reclassification must ONLY fire when the verdict is still "failed"
# (never override an established shipped/wedge/timeout verdict).
if grep -q '\[ "\$_cycle_kind" = "failed" \] && \[ "\${CHUMP_SHIP_GROUNDTRUTH_RECHECK:-1}"' "$WORKER"; then
    ok "reclassification is guarded on _cycle_kind==failed (never overrides other verdicts)"
else
    fail "reclassification guard on _cycle_kind==failed not found"
fi

# ── Structural: stall-detector extends its timeout during the post-ship poll ─
if grep -q 'CHUMP_POSTSHIP_STALL_THRESHOLD_S' "$WORKER" && \
   grep -q '_cycle_log_shows_ship "\$cycle_log"' "$WORKER" && \
   grep -q '_eff_threshold=\$_postship_threshold' "$WORKER"; then
    ok "stall-detector uses an extended post-ship threshold gated on _cycle_log_shows_ship"
else
    fail "stall-detector post-ship carve-out (extended threshold) not wired in"
fi
# The strict 120s bound must remain the default for non-shipped cycles.
if grep -q '_eff_threshold=\$_stall_threshold' "$WORKER"; then
    ok "non-shipped cycles keep the strict CHUMP_STALL_THRESHOLD_S bound (protection unchanged)"
else
    fail "default _eff_threshold=_stall_threshold missing — genuine-hang protection may be weakened"
fi

# ── Registry: the new ambient kind is registered (event-registry gate) ───────
if grep -q 'kind: cycle_reclassified_shipped' "$REGISTRY" 2>/dev/null; then
    ok "cycle_reclassified_shipped registered in EVENT_REGISTRY.yaml"
else
    fail "cycle_reclassified_shipped missing from EVENT_REGISTRY.yaml (event-registry gate would fail)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
