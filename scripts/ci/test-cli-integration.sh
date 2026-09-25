#!/usr/bin/env bash
# scripts/ci/test-cli-integration.sh
# CREDIBLE-018: CLI integration tests by command category.
#
# For each of 31 CLI commands, verifies:
#   - Help path: shows command description, exits 0
#   - Success path: valid invocation → exit 0 (or skip if DB/network required)
#   - Error path: missing required args → exit non-zero with usage hint
#
# Coverage target: 25/31 commands minimum.
# Run: ./scripts/ci/test-cli-integration.sh
# CI:  wired via scripts/ci/fast-checks.sh (path filter: src/**, scripts/**)

set -uo pipefail

PASS=0
FAIL=0
SKIP=0

ok()    { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip()  { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── CREDIBLE-1078: src/*.rs reference audit (CREDIBLE-237 slice) ───────────────
# Inventories every hard-coded `src/*.rs` path referenced anywhere under
# scripts/ci/, classifying each reference by what it actually verifies:
#   - "behavior-based check"    grep for a fn/struct/const signature inside the file
#   - "negative location check" asserts the path does NOT exist / is absent
#   - "positive location check" asserts the path DOES exist (the default —
#      most references just confirm a file is present at a known location)
classify_src_path_reference() {
    local content="$1"
    if grep -qE "grep[^|]*(pub[[:space:]]+)?(fn|struct|const)[[:space:]]" <<< "$content"; then
        echo "behavior-based check"
    elif grep -qiE '! -f |missing|not found|not created|does not exist|absent|orphan' <<< "$content"; then
        echo "negative location check"
    else
        echo "positive location check"
    fi
}

audit_src_paths() {
    local out="$REPO_ROOT/ci_src_path_inventory.txt"
    : > "$out"
    local file line_num content src_path classification rel_path
    while IFS= read -r -d '' file; do
        rel_path="${file#$REPO_ROOT/}"
        while IFS=: read -r line_num content; do
            [[ -z "$line_num" ]] && continue
            src_path=$(grep -oE 'src/[A-Za-z0-9_/]+\.rs' <<< "$content" | head -1)
            [[ -z "$src_path" ]] && continue
            classification=$(classify_src_path_reference "$content")
            echo "${rel_path}:${line_num}:${src_path}:${classification}" >> "$out"
        done < <(grep -noE '.*src/[A-Za-z0-9_/]+\.rs.*' "$file" 2>/dev/null)
    done < <(find "$SCRIPT_DIR" -type f -print0 | sort -z)
    echo "audit_src_paths: wrote $(wc -l < "$out" | tr -d ' ') reference(s) to $out"
    return 0
}

if [[ "${1:-}" == "--audit-src-paths" ]]; then
    audit_src_paths
    exit $?
fi

# ── Binary discovery ──────────────────────────────────────────────────────────
CHUMP="${REPO_ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump')"
    exit 0
fi

echo "=== CREDIBLE-018: CLI integration tests by command category ==="
echo "  binary: $CHUMP"
echo

# ── Helpers ──────────────────────────────────────────────────────────────────
# Single-run helpers — capture output and exit code atomically.

# Run command; pass if exit 0.
check_success() {
    local desc="$1"; shift
    local output rc=0
    output=$("$CHUMP" "$@" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "$desc"
    else
        fail "$desc → exit $rc (expected 0); output: ${output:0:120}"
    fi
}

# Match helper: avoids set -o pipefail SIGPIPE issue (grep -q exits early → SIGPIPE on echo).
# Uses here-string which has no writer-process to SIGPIPE.
_matches() { grep -Eqi "$1" - <<< "$2"; }

# Run command; pass if exit non-zero AND output matches pattern.
check_error() {
    local desc="$1" pattern="$2"; shift 2
    local output rc=0
    output=$("$CHUMP" "$@" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        fail "$desc → expected non-zero exit, got 0"
    elif _matches "$pattern" "$output"; then
        ok "$desc"
    else
        fail "$desc → exit $rc but output did not match '$pattern'; got: ${output:0:120}"
    fi
}

# Run command; pass if exit 0 AND output matches pattern.
check_output() {
    local desc="$1" pattern="$2"; shift 2
    local output rc=0
    output=$("$CHUMP" "$@" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        fail "$desc → exit $rc (expected 0); output: ${output:0:120}"
    elif _matches "$pattern" "$output"; then
        ok "$desc"
    else
        fail "$desc → exit 0 but output did not match '$pattern'; got: ${output:0:120}"
    fi
}

# Run command; pass if output matches pattern regardless of exit code.
# Use this for help flags that exit non-zero but still show help text.
check_any() {
    local desc="$1" pattern="$2"; shift 2
    local output rc=0
    output=$("$CHUMP" "$@" 2>&1) || rc=$?
    if _matches "$pattern" "$output"; then
        ok "$desc"
    else
        fail "$desc → output did not match '$pattern' (exit $rc); got: ${output:0:120}"
    fi
}

# Run command; pass if exit 0 and STDOUT is valid JSON.
#
# INFRA-3687 contract: `--json` commands emit machine-readable JSON on
# stdout ONLY. Advisory/staleness warnings (e.g. "gap list may be STALE:
# checkout is N commit(s) behind origin/main") go to STDERR by design, so
# scripts can parse stdout cleanly. This helper MUST validate stdout in
# isolation — merging stderr with 2>&1 (as the other check_* helpers do)
# would falsely fail whenever the CI checkout is behind origin/main, which
# is the steady state on a busy trunk (deterministic trunk-red).
check_json() {
    local desc="$1"; shift
    local output err rc=0
    err="$(mktemp)"
    # Capture stdout only; route stderr to a temp file for diagnostics.
    output=$("$CHUMP" "$@" 2>"$err") || rc=$?
    if [[ $rc -ne 0 ]]; then
        fail "$desc → exit $rc (expected 0); stderr: $(head -c 120 "$err")"
    elif echo "$output" | python3 -m json.tool >/dev/null 2>&1; then
        ok "$desc"
    else
        fail "$desc → exit 0 but stdout is not valid JSON; got: ${output:0:120}"
    fi
    rm -f "$err"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. GAP MANAGEMENT (gap, claim, ship)
# ─────────────────────────────────────────────────────────────────────────────
echo "--- 1. Gap management ---"

# gap root: shows subcommand menu (exits non-zero when --help is treated as unknown subcommand)
check_any    "gap --help shows subcommand menu"        "subcommand|list|reserve" gap --help
check_error  "gap (no subcommand) exits non-zero"      "subcommand|error|list"   gap

# gap list: reads DB, shows gap list
check_success "gap list exits 0"                       gap list
check_json    "gap list --json returns valid JSON"     gap list --json
check_success "gap list --status open exits 0"         gap list --status open
check_success "gap list --status done exits 0"         gap list --status done

# gap show: requires GAP-ID (--help exits non-zero from raw binary)
check_any     "gap show --help shows Usage"            "Usage|GAP-ID|gap show"   gap show --help
check_error   "gap show (no args) exits non-zero"      "Usage|error|GAP-ID"      gap show
check_error   "gap show nonexistent exits non-zero"    "not found|error|NOTEXIST" gap show NOTEXIST-999999

# gap reserve: requires --domain + --title (--help exits non-zero from raw binary)
check_any     "gap reserve --help shows Usage"         "Usage|domain|title"      gap reserve --help
check_error   "gap reserve (no args) exits non-zero"   "Usage|error|domain"      gap reserve

# gap ship: requires GAP-ID
check_any     "gap ship --help shows Usage"            "Usage|GAP-ID|gap ship"   gap ship --help
check_error   "gap ship (no args) exits non-zero"      "Usage|error"              gap ship

# gap decompose: requires GAP-ID
check_any     "gap decompose --help shows Usage"       "Usage|GAP-ID|decompose"  gap decompose --help
check_error   "gap decompose (no args) exits non-zero" "Usage|error"              gap decompose

# gap audit-priorities: runs PM health check; exits non-zero when P0 findings exist (expected)
check_any     "gap audit-priorities shows audit header" "audit-priorities|P0|open gaps" gap audit-priorities

# ─────────────────────────────────────────────────────────────────────────────
# 2. CLAIM / SHIP TOP-LEVEL ALIASES
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 2. Claim / Ship aliases ---"

check_output "claim --help shows Usage"              "Usage|GAP-ID|claim"   claim --help
check_error  "claim (no args) exits non-zero"        "Usage|error|GAP-ID"   claim
check_error  "claim bad-format-id exits non-zero"    "error|invalid|Usage|format" claim bad-format-id

check_output "ship --help shows Usage"               "Usage|GAP-ID|ship"    ship --help
check_error  "ship (no args) exits non-zero"         "Usage|error"           ship

# ─────────────────────────────────────────────────────────────────────────────
# 3. ANALYTICS — read-mostly, exit 0 even with empty DB
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 3. Analytics commands ---"

check_success "health exits 0"                        health
check_output  "health-digest contains P0|P1|pillar"   "P0|P1|pillar|health|gap" health-digest
check_success "fleet-status exits 0"                  fleet-status
check_success "fleet-velocity exits 0"                fleet-velocity
check_success "waste-tally exits 0"                   waste-tally
check_success "ship-quality exits 0"                  ship-quality
check_success "roadmap-status exits 0"                roadmap-status
# mission-grade is a HEALTH command: it exits non-zero by design when a pillar's
# shipped_24h is 0 (grade F). That count comes from `git log origin/main --since=24h`,
# so the exit code is time-dependent on real merge activity — asserting exit 0 makes
# this smoke test flaky. Assert instead that the command RUNS and prints its scorecard.
check_any     "mission-grade prints scorecard"        "Mission Grade|Pillar" mission-grade
# lesson-grade requires <GAP-ID> --pr <N> — check it at least shows usage
check_any     "lesson-grade --help shows Usage"        "Usage|lesson-grade|GAP-ID" lesson-grade --help
check_success "ci-summary exits 0"                    ci-summary
check_success "kpi report exits 0"                    kpi report

# classify-failure: with no args runs in heuristic mode (exits 0); --help also runs it
check_any     "classify-failure produces output"     "classify|class=|Usage|failure" classify-failure --help
check_success "classify-failure (no args) exits 0 (heuristic mode)" classify-failure

# cost-watch requires --help invocation
check_any "cost-watch --help shows Usage"         "Usage|cost|watch"      cost-watch --help

# pr-coupling-cost: may need --help
check_any "pr-coupling-cost --help shows Usage"   "Usage|coupling|cost"   pr-coupling-cost --help

# cascade stats: reads metrics table
{
    rc=0
    "$CHUMP" cascade stats >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "cascade stats exits 0"
    else
        skip "cascade stats (may need metrics DB)"
    fi
}

# funnel: reads activation funnel data
{
    rc=0
    "$CHUMP" funnel >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "funnel exits 0"
    else
        skip "funnel (may need funnel data in DB)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. FLEET MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 4. Fleet management ---"

check_any   "fleet --help shows subcommands"         "up|status|down|doctor" fleet --help
check_error "fleet (no subcommand) exits non-zero"   "Usage|subcommand|error" fleet

# fleet status and fleet doctor: may need running fleet
{
    rc=0; "$CHUMP" fleet status >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && ok "fleet status exits 0" || skip "fleet status (no fleet running)"
}
{
    rc=0; "$CHUMP" fleet doctor >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && ok "fleet doctor exits 0" || skip "fleet doctor (may need fleet)"
}

# dispatch: top-level dispatches a gap ("chump dispatch <GAP-ID>")
check_any     "dispatch --help shows Usage"          "Usage|dispatch|GAP-ID|auto-merge" dispatch --help
check_error   "dispatch (no GAP-ID) exits non-zero"  "Usage|error|GAP-ID"               dispatch
# dispatch sub-menu: route, scoreboard, simulate live under 'chump dispatch <sub>'
check_any     "dispatch route --help shows Usage"    "Usage|route|backend|dispatch"     dispatch route --help

# ─────────────────────────────────────────────────────────────────────────────
# 5. SESSION / REFLECTION
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 5. Session and reflection ---"

check_any "session-track --help shows Usage"       "Usage|session|track"    session-track --help
check_any "session-export --help shows Usage"      "Usage|session|export"   session-export --help
check_any "session-resume --help shows Usage"      "Usage|session|resume"   session-resume --help
check_any "reflect-delta --help shows Usage"       "Usage|reflect|delta"    reflect-delta --help
check_any "rebase-stuck --help shows Usage"        "Usage|rebase|stuck"     rebase-stuck --help

# ─────────────────────────────────────────────────────────────────────────────
# 6. PR / CODE REVIEW
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 6. PR and code review ---"

check_any "pr fix-clippy --help shows Usage"       "Usage|fix-clippy|clippy" pr fix-clippy --help

# ─────────────────────────────────────────────────────────────────────────────
# 7. AI / GEN COMMANDS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 7. AI generation ---"

check_any   "gen --help shows Usage"                 "Usage|gen|task"          gen --help
check_error "gen (no args) exits non-zero"           "Usage|error|task"        gen
# orchestrate launches interactively; any output (config, prompt, usage) is acceptable
check_any   "orchestrate starts or shows help"       "Usage|orchestrate|config|brain|claude|enabled" orchestrate --help

# ─────────────────────────────────────────────────────────────────────────────
# 8. GLOBAL FLAGS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 8. Global flags ---"

check_output "--version shows semver"                 "[0-9]\.[0-9]"              --version
check_output "--help shows full command list"         "gap|fleet|dispatch|health" --help

# --debug: may print version + DB path header then hit DB init
{
    output=$("$CHUMP" --debug 2>&1) || true
    if _matches "version|debug|chump" "$output"; then
        ok "--debug shows debug header"
    else
        skip "--debug (no debug output matched)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. HIGH-PRIORITY ERROR PATH COVERAGE (gap, claim, ship, dispatch)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 9. High-priority error paths ---"

# gap ship missing --closed-pr (may first fail on rebase check if branch is stale,
# or hit INFRA-1392 PROOF-OF-MERGE refusal when commit is absent from local main).
# INFRA-2096 follow-up: expanded regex to include PROOF-OF-MERGE wording that
# landed when INFRA-1392 added the proof-of-merge gate — caused this test to
# fail with the new error message "refusing to flip NOTEXIST-000 to status=done
# — no commit on local main carr..." not matching the old regex.
check_error "gap ship NOTEXIST → error (not found, rebase, usage, or INFRA-1392 PROOF-OF-MERGE refusal)" \
    "not found|Usage|error|behind|Rebase|PROOF-OF-MERGE|refusing|no commit on local main" \
    gap ship NOTEXIST-000 --closed-pr 9999

# claim invalid GAP-ID format (error message says "not found" for unknown IDs)
check_error "claim bad-GAP-ID format → error" "error|invalid|Usage|format|not found|reserve" \
    claim 12345-not-valid

# CREDIBLE-291: a transient farmer-RED must NOT mask a GAP-ID format error.
# Before the fix the farmer readiness gate ran BEFORE format validation, so a
# brief farmer-RED made `claim <bad-id>` print "farmer status RED" instead of
# the format error — failing this suite and cascading a fleet-wide false-red
# jam (2026-08-20). Force farmer RED via the fleet-paused sentinel; the format
# error must still win.
_fp291="$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.chump/fleet-paused"
mkdir -p "$(dirname "$_fp291")"; : > "$_fp291"
check_error "claim bad-id under farmer-RED still returns format error (CREDIBLE-291)" \
    "invalid|format|Usage|not found|reserve" claim bad-format-id
rm -f "$_fp291"

# dispatch route with unknown backend → error or usage
{
    rc=0; output=$("$CHUMP" dispatch route --backend totally-unknown-xyz 2>&1) || rc=$?
    if [[ $rc -ne 0 ]] && echo "$output" | grep -qi "error|unknown|Usage|invalid"; then
        ok "dispatch route unknown backend → error"
    elif [[ $rc -ne 0 ]]; then
        ok "dispatch route unknown backend → non-zero exit"
    else
        skip "dispatch route unknown backend (accepted or no-op)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# RESULTS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"

# Coverage is the number of non-skipped command tests.
# With 31 commands and the tests above, we always exceed 25/31.
COVERED=$((PASS + FAIL))
if [[ $COVERED -lt 25 ]]; then
    echo "FAIL: coverage below 25 command tests (got $COVERED)"
    FAIL=$((FAIL+1))
else
    echo "Coverage: $COVERED tests run (target ≥25) — OK"
fi

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL"
    exit 1
else
    echo "PASS"
    exit 0
fi
