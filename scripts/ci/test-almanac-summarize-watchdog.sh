#!/usr/bin/env bash
# scripts/ci/test-almanac-summarize-watchdog.sh — RESILIENT-354
#
# Proves the almanac-summarize-watchdog:
#   1. source contract: script + plist + installer present, syntax clean
#   2. DEAD driver path: stubbed pgrep reports nothing alive -> watchdog
#      calls the restart command and emits almanac_summarize_restarted
#      ("kill it -> back within one cycle")
#   3. ALIVE driver path: stubbed pgrep reports it alive -> no restart call
#   4. COVERAGE-DROP path: stubbed coverage reporter returns a served repo
#      below the floor -> watchdog pages via operator-recall.sh
#      --condition ALMANAC_SUMMARIZE_COVERAGE_DROP and emits
#      almanac_summarize_coverage_drop ("coverage-drop pages like any organ
#      failure")
#   5. COVERAGE-OK path: all served repos >= floor -> no page
#   6. --dry-run does not call the restart command or the recall script
#   7. heartbeat tick always emitted

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WATCHDOG="$REPO_ROOT/scripts/ops/almanac-summarize-watchdog.sh"
PLIST="$REPO_ROOT/launchd/com.chump.almanac-summarize-watchdog.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-almanac-summarize-watchdog.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-almanac-summarize-watchdog.sh (RESILIENT-354) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
echo "--- 1: source contract ---"
[[ -f "$WATCHDOG" ]] || fail "watchdog script missing: $WATCHDOG"
[[ -x "$WATCHDOG" ]] || fail "watchdog script not executable: $WATCHDOG"
bash -n "$WATCHDOG" || fail "watchdog bash -n failed"
[[ -f "$INSTALL" ]] || fail "installer missing: $INSTALL"
[[ -x "$INSTALL" ]] || fail "installer not executable: $INSTALL"
bash -n "$INSTALL" || fail "installer bash -n failed"
[[ -f "$PLIST" ]] || fail "plist missing: $PLIST"
grep -q "almanac-summarize-watchdog.sh" "$PLIST" \
    || fail "plist does not reference almanac-summarize-watchdog.sh"
grep -q "com.chump.almanac-summarize-watchdog" "$PLIST" \
    || fail "plist missing expected Label"
pass "script + plist + installer present, syntax clean"

# ── 1b. Bootstrap wiring — REQUIRED_DAEMONS (RESILIENT-354) ────────────────
# A watchdog that exists on disk but isn't in REQUIRED_DAEMONS is exactly the
# failure this gap is about: shipped-but-never-installed, so the launcher
# stays unsupervised on any host that didn't run the installer by hand.
echo "--- 1b: bootstrap wiring ---"
BOOTSTRAP="$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh"
[[ -f "$BOOTSTRAP" ]] || fail "bootstrap script missing: $BOOTSTRAP"
grep -qF "com.chump.almanac-summarize-watchdog|scripts/setup/install-almanac-summarize-watchdog.sh" "$BOOTSTRAP" \
    || fail "almanac-summarize-watchdog not registered in REQUIRED_DAEMONS — will never auto-install"
pass "almanac-summarize-watchdog registered in REQUIRED_DAEMONS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Recall stub — records every invocation so we can assert paging happened
# (or didn't) without touching the real operator-recall.sh.
RECALL_CALL_LOG="$TMP/recall-calls.log"
RECALL_STUB="$TMP/recall-stub.sh"
cat > "$RECALL_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RECALL_CALL_LOG"
exit 0
EOF
chmod +x "$RECALL_STUB"

# ── 2. DEAD driver: stubbed pgrep finds nothing -> restart invoked ─────────
echo "--- 2: dead driver path ---"
PGREP_DEAD="$TMP/pgrep-dead"
cat > "$PGREP_DEAD" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$PGREP_DEAD"

RESTART_CALL_LOG="$TMP/restart-calls.log"
RESTART_CMD="echo restarted >> $RESTART_CALL_LOG"

AMB="$TMP/ambient.jsonl"
: > "$AMB"
out="$(CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_DEAD" \
    CHUMP_ALMANAC_WATCHDOG_RESTART_CMD="$RESTART_CMD" \
    CHUMP_ALMANAC_BIN="/nonexistent/almanac" \
    CHUMP_AMBIENT_LOG="$AMB" "$WATCHDOG" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "watchdog exited $rc on dead-driver path; output: $out"
[[ -s "$RESTART_CALL_LOG" ]] || fail "expected restart command to run; output: $out"
grep -q '"kind":"almanac_summarize_restarted"' "$AMB" \
    || fail "expected almanac_summarize_restarted emitted; ambient: $(cat "$AMB")"
pass "dead driver -> restart command invoked + almanac_summarize_restarted emitted"

# ── 3. ALIVE driver: stubbed pgrep succeeds -> no restart call ─────────────
echo "--- 3: alive driver path ---"
PGREP_ALIVE="$TMP/pgrep-alive"
cat > "$PGREP_ALIVE" <<'EOF'
#!/usr/bin/env bash
echo 12345
exit 0
EOF
chmod +x "$PGREP_ALIVE"

RESTART_CALL_LOG2="$TMP/restart-calls2.log"
RESTART_CMD2="echo restarted >> $RESTART_CALL_LOG2"
AMB2="$TMP/ambient2.jsonl"
: > "$AMB2"
CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_ALIVE" \
    CHUMP_ALMANAC_WATCHDOG_RESTART_CMD="$RESTART_CMD2" \
    CHUMP_ALMANAC_BIN="/nonexistent/almanac" \
    CHUMP_AMBIENT_LOG="$AMB2" "$WATCHDOG" >/dev/null 2>&1
[[ -s "$RESTART_CALL_LOG2" ]] && fail "alive driver must not trigger a restart; calls: $(cat "$RESTART_CALL_LOG2")"
grep -q '"kind":"almanac_summarize_watchdog_tick"' "$AMB2" \
    || fail "expected heartbeat tick even on the healthy path; ambient: $(cat "$AMB2")"
pass "alive driver: no restart call, heartbeat still emitted"

# ── 4. COVERAGE-DROP: a served repo below floor -> pages via recall ────────
echo "--- 4: coverage-drop path ---"
COVERAGE_LOW="$TMP/coverage-low.sh"
cat > "$COVERAGE_LOW" <<'EOF'
#!/usr/bin/env bash
echo '{"repos":[{"repo":"holler","pct":68.6},{"repo":"dice","pct":99.1}]}'
EOF
chmod +x "$COVERAGE_LOW"

AMB3="$TMP/ambient3.jsonl"
: > "$AMB3"
: > "$RECALL_CALL_LOG"
CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_ALIVE" \
    CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN="$COVERAGE_LOW" \
    CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_ALMANAC_SUMMARIZE_MIN_PCT=95 \
    CHUMP_AMBIENT_LOG="$AMB3" "$WATCHDOG" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] || fail "expected exit 2 (CREDIBLE-1174 guard) on coverage-drop path; got $rc"
grep -q -- "--condition ALMANAC_SUMMARIZE_COVERAGE_DROP" "$RECALL_CALL_LOG" \
    || fail "expected operator-recall.sh --condition ALMANAC_SUMMARIZE_COVERAGE_DROP; calls: $(cat "$RECALL_CALL_LOG")"
grep -q '"kind":"almanac_summarize_coverage_drop"' "$AMB3" \
    || fail "expected almanac_summarize_coverage_drop emitted; ambient: $(cat "$AMB3")"
grep -q '"worst_repo":"holler"' "$AMB3" \
    || fail "expected worst_repo=holler in coverage_drop event; ambient: $(cat "$AMB3")"
pass "coverage below floor -> operator-recall paged + almanac_summarize_coverage_drop emitted + exit 2"

# ── 5. COVERAGE-OK: all served repos >= floor -> no page ───────────────────
echo "--- 5: coverage-ok path ---"
COVERAGE_OK="$TMP/coverage-ok.sh"
cat > "$COVERAGE_OK" <<'EOF'
#!/usr/bin/env bash
echo '{"repos":[{"repo":"holler","pct":97.2},{"repo":"dice","pct":99.1}]}'
EOF
chmod +x "$COVERAGE_OK"

AMB4="$TMP/ambient4.jsonl"
: > "$AMB4"
: > "$RECALL_CALL_LOG"
CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_ALIVE" \
    CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN="$COVERAGE_OK" \
    CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_ALMANAC_SUMMARIZE_MIN_PCT=95 \
    CHUMP_AMBIENT_LOG="$AMB4" "$WATCHDOG" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "coverage OK must exit 0; got $rc"
[[ -s "$RECALL_CALL_LOG" ]] && fail "coverage OK must not page; calls: $(cat "$RECALL_CALL_LOG")"
grep -q '"kind":"almanac_summarize_coverage_drop"' "$AMB4" \
    && fail "coverage OK must not emit almanac_summarize_coverage_drop; ambient: $(cat "$AMB4")"
pass "coverage at/above floor -> no page, no coverage_drop event"

# ── 6. --dry-run does not restart or page ───────────────────────────────────
echo "--- 6: dry-run path ---"
RESTART_CALL_LOG3="$TMP/restart-calls3.log"
RESTART_CMD3="echo restarted >> $RESTART_CALL_LOG3"
AMB5="$TMP/ambient5.jsonl"
: > "$AMB5"
: > "$RECALL_CALL_LOG"
CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_DEAD" \
    CHUMP_ALMANAC_WATCHDOG_RESTART_CMD="$RESTART_CMD3" \
    CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN="$COVERAGE_LOW" \
    CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_ALMANAC_SUMMARIZE_MIN_PCT=95 \
    CHUMP_AMBIENT_LOG="$AMB5" "$WATCHDOG" --dry-run >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "--dry-run must exit 0 even with a coverage drop present; got $rc"
[[ -s "$RESTART_CALL_LOG3" ]] && fail "--dry-run must not call the restart command; calls: $(cat "$RESTART_CALL_LOG3")"
[[ -s "$RECALL_CALL_LOG" ]] && fail "--dry-run must not page operator-recall; calls: $(cat "$RECALL_CALL_LOG")"
pass "--dry-run reports without restarting or paging, exits 0"

# ── 7. MISSING/INVALID pct: entries lacking pct data fail-closed ───────────
# CREDIBLE-1045: a repo entry with neither "pct" nor "summarized_pct" used to
# silently default to 100 (treated as compliant). It must instead be treated
# as a coverage violation so a malformed report can't hide a real gap.
echo "--- 7: missing/invalid pct fails closed ---"
COVERAGE_MISSING="$TMP/coverage-missing.sh"
cat > "$COVERAGE_MISSING" <<'EOF'
#!/usr/bin/env bash
echo '{"repos":[{"repo":"noreport"},{"repo":"dice","pct":99.1}]}'
EOF
chmod +x "$COVERAGE_MISSING"

AMB6="$TMP/ambient6.jsonl"
: > "$AMB6"
: > "$RECALL_CALL_LOG"
CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_ALIVE" \
    CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN="$COVERAGE_MISSING" \
    CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_ALMANAC_SUMMARIZE_MIN_PCT=95 \
    CHUMP_AMBIENT_LOG="$AMB6" "$WATCHDOG" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] || fail "expected exit 2 (CREDIBLE-1174 guard) when a repo is missing pct data; got $rc"
grep -q -- "--condition ALMANAC_SUMMARIZE_COVERAGE_DROP" "$RECALL_CALL_LOG" \
    || fail "expected missing-pct entry to page operator-recall; calls: $(cat "$RECALL_CALL_LOG")"
grep -q '"worst_repo":"noreport(missing_pct_field)"' "$AMB6" \
    || fail "expected worst_repo to flag the missing-pct entry; ambient: $(cat "$AMB6")"
pass "repo entry missing pct field -> treated as coverage violation, not silently 100%, exit 2"

# ── 8. FLOOR CLAMP: a below-95 MIN_PCT override cannot weaken the guard ────
# CREDIBLE-1210: CHUMP_ALMANAC_SUMMARIZE_MIN_PCT must never lower the guard
# below the 95% mission floor. A repo at 80% would pass an (unclamped) 50%
# override but must still trip the guard once clamped back to 95%.
echo "--- 8: MIN_PCT below 95 is clamped to 95 ---"
COVERAGE_80="$TMP/coverage-80.sh"
cat > "$COVERAGE_80" <<'EOF'
#!/usr/bin/env bash
echo '{"repos":[{"repo":"holler","pct":80.0}]}'
EOF
chmod +x "$COVERAGE_80"

AMB7="$TMP/ambient7.jsonl"
: > "$AMB7"
: > "$RECALL_CALL_LOG"
out="$(CHUMP_ALMANAC_WATCHDOG_PGREP_BIN="$PGREP_ALIVE" \
    CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN="$COVERAGE_80" \
    CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_ALMANAC_SUMMARIZE_MIN_PCT=50 \
    CHUMP_AMBIENT_LOG="$AMB7" "$WATCHDOG" 2>&1)"
rc=$?
[[ "$rc" -eq 2 ]] || fail "expected exit 2 — a 50% override must be clamped to the 95% floor; got $rc; output: $out"
grep -q -- "--condition ALMANAC_SUMMARIZE_COVERAGE_DROP" "$RECALL_CALL_LOG" \
    || fail "expected clamped floor to still page operator-recall; calls: $(cat "$RECALL_CALL_LOG")"
grep -q '"floor":95' "$AMB7" \
    || fail "expected coverage_drop event to record the clamped floor of 95; ambient: $(cat "$AMB7")"
pass "MIN_PCT override below 95 is clamped to 95 -> guard still trips, floor recorded as 95"

echo "=== all almanac-summarize-watchdog tests passed ==="
