#!/usr/bin/env bash
# test-orphan-allowlist-daemon.sh — INFRA-5426
#
# Smoke-tests for scripts/coord/orphan-allowlist-daemon.sh:
#
#   1. A new orphan (not tracked, not reserved) triggers kind=audit_orphan_landed
#      with orphan_kind + sha fields, and lands in the state file as "landed"
#   2. The rescue phase opens a PR (via stubbed git/gh) titled
#      `auto-allowlist: add orphan <SHA>` and appends the orphan to reserved.txt
#   3. kind=orphan_allowlist_pr_opened is emitted with orphan_kind/sha/pr fields
#   4. Re-run is idempotent — no duplicate PR / ambient event on a second pass
#   5. An orphan already present in reserved.txt is never flagged as landed
#   6. An open PR already existing for the branch is adopted, not duplicated
#   7. --dry-run never mutates reserved.txt, state file, or ambient.jsonl
#   8. CHUMP_ORPHAN_ALLOWLIST_DAEMON=0 bypasses entirely (exit 0, no writes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/orphan-allowlist-daemon.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$DAEMON" ]] || fail "orphan-allowlist-daemon.sh not found at $DAEMON"
[[ -x "$DAEMON" ]] || fail "orphan-allowlist-daemon.sh is not executable"

TMP="$(mktemp -d -t test-orphan-allowlist-daemon.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_LOCK="$TMP/locks"; mkdir -p "$FAKE_LOCK"
FAKE_AMBIENT="$FAKE_LOCK/ambient.jsonl"
FAKE_STATE="$FAKE_LOCK/state.json"
FAKE_RESERVED="$TMP/event-registry-reserved.txt"
cat > "$FAKE_RESERVED" <<'EOF'
# comment — ignored
already_reserved_kind  # reason: test fixture — already reserved, never a live orphan
EOF

# Fake orphan-lister — stands in for the real coverage script's report-mode
# scan so the daemon's tests never touch the real 1200+-kind registry.
FAKE_COVERAGE="$TMP/fake-coverage.sh"
FAKE_COVERAGE_ORPHANS="$TMP/orphans.txt"
cat > "$FAKE_COVERAGE_ORPHANS" <<'EOF'
already_reserved_kind
new_orphan_kind
EOF
cat > "$FAKE_COVERAGE" <<EOF
#!/usr/bin/env bash
while IFS= read -r k; do
    [[ -z "\$k" ]] && continue
    echo "  ORPHAN: \$k"
done < "$FAKE_COVERAGE_ORPHANS"
EOF
chmod +x "$FAKE_COVERAGE"

GIT_LOG="$TMP/git-calls.log"
GH_LOG="$TMP/gh-calls.log"
FAKE_GIT="$TMP/fake-git.sh"
cat > "$FAKE_GIT" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GIT_LOG"
if [[ "\$*" == *"rev-parse --short HEAD"* ]]; then
    echo "abc1234"
fi
exit 0
EOF
chmod +x "$FAKE_GIT"

GH_PR_LIST_OUT="$TMP/gh-pr-list-out.txt"
: > "$GH_PR_LIST_OUT"
FAKE_GH="$TMP/fake-gh.sh"
cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [[ "\$1 \$2" == "pr list" ]]; then
    cat "$GH_PR_LIST_OUT"
elif [[ "\$1 \$2" == "pr create" ]]; then
    echo '{"number": 42}'
fi
exit 0
EOF
chmod +x "$FAKE_GH"

_env() {
    env \
        CHUMP_LOCK_DIR="$FAKE_LOCK" \
        CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
        CHUMP_ORPHAN_DAEMON_STATE="$FAKE_STATE" \
        CHUMP_ORPHAN_DAEMON_RESERVED="$FAKE_RESERVED" \
        CHUMP_ORPHAN_DAEMON_COVERAGE_SCRIPT="$FAKE_COVERAGE" \
        CHUMP_ORPHAN_DAEMON_GIT_BIN="$FAKE_GIT" \
        CHUMP_ORPHAN_DAEMON_GH_BIN="$FAKE_GH" \
        CHUMP_ORPHAN_DAEMON_REPO_ROOT="$TMP" \
        CHUMP_ORPHAN_DAEMON_HEAD_SHA="abc1234" \
        "$@"
}

run_daemon() { _env bash "$DAEMON" --once "$@" 2>&1 || true; }

# ── Test 1+2+3: first pass detects, rescues, and emits ────────────────────────
out1="$(run_daemon)"
echo "$out1" | grep -q "new orphan landed: new_orphan_kind" \
    || fail "Test 1: expected detection log line for new_orphan_kind; got: $out1"

grep -q '"kind":"audit_orphan_landed"' "$FAKE_AMBIENT" \
    || fail "Test 1: audit_orphan_landed not emitted; ambient: $(cat "$FAKE_AMBIENT" 2>/dev/null)"
grep '"kind":"audit_orphan_landed"' "$FAKE_AMBIENT" | grep -q '"orphan_kind":"new_orphan_kind"' \
    || fail "Test 1: audit_orphan_landed missing orphan_kind=new_orphan_kind"
grep '"kind":"audit_orphan_landed"' "$FAKE_AMBIENT" | grep -q '"sha":"abc1234"' \
    || fail "Test 1: audit_orphan_landed missing sha=abc1234"
pass "Test 1: kind=audit_orphan_landed emitted with orphan_kind + sha"

grep -q "new_orphan_kind" "$FAKE_RESERVED" \
    || fail "Test 2: new_orphan_kind not appended to reserved.txt after rescue pass"
pass "Test 2: rescue phase appended orphan to event-registry-reserved.txt"

grep -q '"kind":"orphan_allowlist_pr_opened"' "$FAKE_AMBIENT" \
    || fail "Test 3: orphan_allowlist_pr_opened not emitted"
grep '"kind":"orphan_allowlist_pr_opened"' "$FAKE_AMBIENT" | grep -q '"pr":42' \
    || fail "Test 3: orphan_allowlist_pr_opened missing pr=42"
pass "Test 3: kind=orphan_allowlist_pr_opened emitted with pr number"

grep -q -- "--title auto-allowlist: add orphan abc1234" "$GH_LOG" \
    || fail "PR title check: expected 'auto-allowlist: add orphan abc1234' pattern in gh call log: $(cat "$GH_LOG")"
pass "PR title follows pattern 'auto-allowlist: add orphan <SHA>'"

# ── Test 4: idempotent re-run ─────────────────────────────────────────────────
CALLS_BEFORE="$(wc -l < "$GH_LOG")"
run_daemon >/dev/null
CALLS_AFTER="$(wc -l < "$GH_LOG")"
[[ "$CALLS_BEFORE" == "$CALLS_AFTER" ]] \
    || fail "Test 4: re-run should not issue new gh calls once orphan is pr_opened (before=$CALLS_BEFORE after=$CALLS_AFTER)"
OPENED_COUNT="$(grep -c '"kind":"orphan_allowlist_pr_opened"' "$FAKE_AMBIENT")"
[[ "$OPENED_COUNT" -eq 1 ]] \
    || fail "Test 4: expected exactly 1 orphan_allowlist_pr_opened event after 2 passes, got $OPENED_COUNT"
pass "Test 4: re-run is idempotent — no duplicate PR / event"

# ── Test 5: already-reserved orphan never flagged as landed ──────────────────
grep -q '"orphan_kind":"already_reserved_kind"' "$FAKE_AMBIENT" \
    && fail "Test 5: already_reserved_kind must never be treated as a live orphan"
pass "Test 5: already-reserved kind never flagged as landed"

# ── Test 6: adopt an existing open PR instead of duplicating ─────────────────
rm -f "$FAKE_STATE" "$FAKE_AMBIENT" "$GH_LOG" "$GIT_LOG"
cat > "$FAKE_RESERVED" <<'EOF'
already_reserved_kind  # reason: test fixture
EOF
echo "99" > "$GH_PR_LIST_OUT"
out6="$(run_daemon)"
CREATE_CALLS="$(grep -c 'pr create' "$GH_LOG" 2>/dev/null || true)"
CREATE_CALLS="${CREATE_CALLS:-0}"
[[ "$CREATE_CALLS" -eq 0 ]] \
    || fail "Test 6: existing open PR (99) should be adopted, not re-created; gh log: $(cat "$GH_LOG")"
jq -r '.new_orphan_kind.pr' "$FAKE_STATE" | grep -q '^99$' \
    || fail "Test 6: state should record pr=99 for the adopted PR; state: $(cat "$FAKE_STATE")"
pass "Test 6: existing open PR for the branch is adopted, not duplicated"

# ── Test 7: --dry-run never mutates anything ──────────────────────────────────
rm -f "$FAKE_STATE" "$FAKE_AMBIENT" "$GH_LOG" "$GIT_LOG"
: > "$GH_PR_LIST_OUT"
cat > "$FAKE_RESERVED" <<'EOF'
already_reserved_kind  # reason: test fixture
EOF
RESERVED_BEFORE="$(cat "$FAKE_RESERVED")"
_env bash "$DAEMON" --once --dry-run >/dev/null 2>&1 || true
RESERVED_AFTER="$(cat "$FAKE_RESERVED")"
[[ "$RESERVED_BEFORE" == "$RESERVED_AFTER" ]] \
    || fail "Test 7: --dry-run must not mutate event-registry-reserved.txt"
[[ ! -s "$FAKE_AMBIENT" ]] \
    || fail "Test 7: --dry-run must not emit to ambient.jsonl"
[[ "$(jq -r 'keys | length' "$FAKE_STATE" 2>/dev/null || echo 0)" == "0" ]] \
    || fail "Test 7: --dry-run must not write to the state file"
pass "Test 7: --dry-run makes no mutations (reserved.txt, ambient.jsonl, state file)"

# ── Test 8: bypass via CHUMP_ORPHAN_ALLOWLIST_DAEMON=0 ────────────────────────
rm -f "$FAKE_STATE" "$FAKE_AMBIENT"
rc8=0
_env env CHUMP_ORPHAN_ALLOWLIST_DAEMON=0 bash "$DAEMON" --once >/dev/null 2>&1 || rc8=$?
[[ "$rc8" -eq 0 ]] || fail "Test 8: bypass should exit 0, got $rc8"
[[ ! -f "$FAKE_AMBIENT" || ! -s "$FAKE_AMBIENT" ]] \
    || fail "Test 8: bypass must not emit anything"
pass "Test 8: CHUMP_ORPHAN_ALLOWLIST_DAEMON=0 bypasses cleanly"

echo ""
echo "All INFRA-5426 orphan-allowlist-daemon checks passed (8/8)."
