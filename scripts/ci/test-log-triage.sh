#!/usr/bin/env bash
# test-log-triage.sh — INFRA-1891
#
# Validates `chump fleet log-triage`:
#  - subcommand wired in main.rs + help text
#  - seeds a fixture ambient.jsonl with known signatures + a fixture
#    state.db (one DONE gap referenced by gap_failed events)
#  - runs `log-triage --window-h 1 --json` and asserts the JSON contains
#    the expected finding + correct dedup status
#  - asserts the Markdown report was written to .chump/triage/YYYY-MM-DD.md
#    with a today.md symlink alongside it

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Source the gap test helpers
REPO_ROOT_TMP="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT_TMP/scripts/ci/test-gap-lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Re-source REPO_ROOT for use in rest of script
unset REPO_ROOT_TMP

echo "=== INFRA-1891 chump fleet log-triage test ==="
echo

# 1. Subcommand wired in main.rs.
if grep -q '"log-triage" =>' "$REPO_ROOT/src/main.rs"; then
    ok "log-triage arm in main.rs"
else
    fail "log-triage arm missing from main.rs"
fi

if grep -q 'log-triage' "$REPO_ROOT/src/main.rs"; then
    ok "log-triage mentioned in help text"
else
    fail "log-triage not mentioned in main.rs help text"
fi

# 2. Registered in the event registry (guard requires this before emit).
if grep -q 'kind: log_triage_completed' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "log_triage_completed registered in EVENT_REGISTRY.yaml"
else
    fail "log_triage_completed missing from EVENT_REGISTRY.yaml"
fi
if grep -q 'kind: log_triage_finding_high_signal' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "log_triage_finding_high_signal registered in EVENT_REGISTRY.yaml"
else
    fail "log_triage_finding_high_signal missing from EVENT_REGISTRY.yaml"
fi

# 3. launchd plist present for the daily 09:00 schedule.
PLIST="$REPO_ROOT/scripts/launchd/com.chump.log-triage.plist"
if [[ -f "$PLIST" ]] && grep -q '<key>Hour</key>' "$PLIST" && grep -q '<integer>9</integer>' "$PLIST"; then
    ok "launchd plist present with 09:00 StartCalendarInterval"
else
    fail "launchd plist missing or not scheduled at 09:00"
fi

# 4. Functional test: build binary and run against an isolated fixture repo.
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

mkdir -p "$TMP/.chump-locks"

# Seed a fixture DONE gap so the gap_failed cross-ref has a real gap_id to
# join against.
GAP_OUT=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "log-triage fixture done gap" --quiet 2>/dev/null || true)
GAP_ID=$("$BIN" gap list --status open --json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print([g['id'] for g in d if g['title']=='log-triage fixture done gap'][0])" 2>/dev/null || echo "")

if [[ -z "$GAP_ID" ]]; then
    fail "could not resolve fixture gap id — skipping cross-ref assertions"
else
    ok "fixture gap $GAP_ID reserved"
    ship_gap_for_test "$TMP/.chump/state.db" "$GAP_ID"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$TMP/.chump-locks/ambient.jsonl" <<EOF
{"ts":"$NOW","kind":"gap_failed","gap_id":"$GAP_ID"}
{"ts":"$NOW","kind":"gap_failed","gap_id":"$GAP_ID"}
{"ts":"$NOW","kind":"dirty_pr_unresolvable","pr":"501","conflict_files":"src/hotfile.rs"}
{"ts":"$NOW","kind":"dirty_pr_unresolvable","pr":"502","conflict_files":"src/hotfile.rs"}
not valid json at all
{"ts":"$NOW","kind":"noise_event"}
EOF

JSON=$("$BIN" fleet log-triage --window-h 1 --json 2>/dev/null)

for key in window_h events_processed parse_errors histogram_top10 findings candidate_gap_count; do
    if echo "$JSON" | grep -q "\"$key\""; then
        ok "JSON key $key present"
    else
        fail "JSON key $key missing"
    fi
done

PARSE_ERRORS=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['parse_errors'])")
if [[ "$PARSE_ERRORS" -ge 1 ]]; then
    ok "parse_errors counted the malformed line (got $PARSE_ERRORS)"
else
    fail "expected parse_errors >= 1, got $PARSE_ERRORS"
fi

GAP_FAILED_SIG=$(echo "$JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sigs = [f['signature'] for f in d['findings']]
print('gap_failed_on_done_gaps' in sigs)
")
if [[ -n "$GAP_ID" ]]; then
    if [[ "$GAP_FAILED_SIG" == "True" ]]; then
        ok "gap_failed_on_done_gaps finding present"
    else
        fail "expected gap_failed_on_done_gaps finding, got: $JSON"
    fi
fi

HOTFILE_SIG=$(echo "$JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sigs = [f['signature'] for f in d['findings']]
print(any('src/hotfile.rs' in s for s in sigs))
")
if [[ "$HOTFILE_SIG" == "True" ]]; then
    ok "hot conflict-file finding present"
else
    fail "expected hot conflict-file finding, got: $JSON"
fi

DEDUP_STATUS=$(echo "$JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = [f['dedup_status'] for f in d['findings'] if f['signature']=='gap_failed_on_done_gaps']
print(m[0] if m else 'MISSING')
")
if [[ "$DEDUP_STATUS" == "none" ]]; then
    ok "dedup status is 'none' for a fresh finding (no matching open gap)"
else
    fail "expected dedup status 'none', got '$DEDUP_STATUS'"
fi

TODAY="$(date -u +%Y-%m-%d)"
REPORT="$TMP/.chump/triage/$TODAY.md"
if [[ -f "$REPORT" ]]; then
    ok "Markdown report written to .chump/triage/$TODAY.md"
else
    fail "Markdown report missing at $REPORT"
fi
if [[ -L "$TMP/.chump/triage/today.md" || -f "$TMP/.chump/triage/today.md" ]]; then
    ok "today.md symlink/copy present"
else
    fail "today.md symlink missing"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
