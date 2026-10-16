#!/usr/bin/env bash
# INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374).
#
# The sweeper itself depends on `gh` + a real GitHub session, which CI
# doesn't have without a token. So this test:
#
#   1. Asserts the script exists + is executable.
#   2. Asserts --dry-run is in its --help / usage hint (catches an accidental
#      removal of the safety knob).
#   3. Asserts the WIP/skip/hold regex catches the patterns it documents.
#   4. Drives the sweeper end-to-end against a fake `gh` + fake armer,
#      including the INFRA-8178 human-vs-gate disarm classification: a
#      disarm attributed to the automation login (or landing right after a
#      failed required check) must be re-armed once green; a genuine human
#      disarm must still be respected.
#
# Run from repo root: bash scripts/ci/test-auto-arm-sweeper.sh

set -e
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWEEPER="$REPO_ROOT/scripts/ops/auto-arm-sweeper.sh"

# 1. exists + executable
[[ -f "$SWEEPER" ]] && pass "scripts/ops/auto-arm-sweeper.sh exists" \
                   || fail "scripts/ops/auto-arm-sweeper.sh missing"
[[ -x "$SWEEPER" ]] && pass "auto-arm-sweeper.sh is executable" \
                   || fail "auto-arm-sweeper.sh not executable"

# 2. --dry-run is documented + handled
grep -q -- '--dry-run' "$SWEEPER" && pass "--dry-run flag present in script" \
                                  || fail "--dry-run flag absent (safety regression)"

# 3. WIP/hold/skip pattern present (the docs claim these stop arming)
for pat in 'WIP' 'skip' 'hold'; do
    if grep -q -i "$pat" "$SWEEPER"; then
        pass "skip pattern present: $pat"
    else
        fail "skip pattern missing: $pat"
    fi
done

# 4. CHUMP_AUTOARM_SKIP bypass present
grep -q "CHUMP_AUTOARM_SKIP" "$SWEEPER" \
    && pass "CHUMP_AUTOARM_SKIP bypass env var present" \
    || fail "CHUMP_AUTOARM_SKIP bypass env var missing"

# 5. CHUMP_AUTOARM_SKIP=1 actually short-circuits + exits 0
if CHUMP_AUTOARM_SKIP=1 bash "$SWEEPER" --dry-run > /tmp/auto-arm-skip.log 2>&1; then
    grep -q "CHUMP_AUTOARM_SKIP" /tmp/auto-arm-skip.log \
        && pass "CHUMP_AUTOARM_SKIP=1 emits a clear bypass message + exits 0" \
        || fail "CHUMP_AUTOARM_SKIP=1 didn't emit expected message (got: $(head -1 /tmp/auto-arm-skip.log))"
else
    fail "CHUMP_AUTOARM_SKIP=1 should exit 0 (got non-zero)"
fi

# 6. INFRA-8047/INFRA-8178: behavioural test with a fake `gh` + fake armer.
#
# Fake gh's `timeline` and `check-runs` responses are read from two files
# (TIMELINE_FIXTURE / CHECKRUNS_FIXTURE) so each scenario below can set its
# own synthetic auto_merge_disabled actor/timestamp + failed-check
# timestamps without actually running jq.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") echo tester ;;
  "pr list") cat "$FAKE_PRS" ;;
  "api repos/{owner}/{repo}/issues/"*"/timeline") cat "${TIMELINE_FIXTURE:-/dev/null}" ;;
  "api repos/{owner}/{repo}/commits/"*"/check-runs") cat "${CHECKRUNS_FIXTURE:-/dev/null}" ;;
esac
GH
cat > "$T/armer" <<'AR'
#!/usr/bin/env bash
echo "$2" >> "$ARM_LOG"
AR
chmod +x "$T/bin/gh" "$T/armer"
export PATH="$T/bin:$PATH" FAKE_PRS="$T/prs.json" ARM_LOG="$T/arm.log" \
       CHUMP_AUTOARM_ARMER="$T/armer" CHUMP_AUTOARM_STATE="$T/state.tsv"
: > "$ARM_LOG"
pr_json() { # <labels-json> <autoMerge-json> <sha>
  echo "[{\"number\":7,\"title\":\"x\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"autoMergeRequest\":$2,\"labels\":$1,\"headRefOid\":\"$3\"}]" > "$FAKE_PRS"
}
# arm_json: non-empty autoMergeRequest object so the python shim's
# truthiness check (an empty `{}` is falsy in Python) reports has_auto=true.
arm_json() { pr_json "$1" '{"enabledBy":{"login":"tester"}}' "$2"; }

# held PR: two ticks, never armed
pr_json '[{"name":"hold"}]' null aaa
bash "$SWEEPER" >/dev/null 2>&1; bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "hold label: PR stays unarmed across two ticks" \
                      || fail "hold label: PR was armed"

# unheld PR gets armed
pr_json '[]' null aaa
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "unheld green PR is armed" || fail "unheld PR not armed"

# human disarm (armed state remembered, now unarmed, same sha): not re-armed.
# Timeline actor is NOT the automation login ("tester") and there is no
# failed-check correlation -> classified HUMAN -> respected.
printf 'human-op' > "$T/timeline-human-legacy.txt"
: > "$T/checkruns-empty-legacy.txt"
export TIMELINE_FIXTURE="$T/timeline-human-legacy.txt" CHECKRUNS_FIXTURE="$T/checkruns-empty-legacy.txt"
: > "$ARM_LOG"
bash "$SWEEPER" >/dev/null 2>&1; bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "human disarm respected across two ticks" || fail "disarmed PR was re-armed"
grep -q "disarmed.human-op" "$T/state.tsv" && pass "disarmer recorded" || fail "disarmer not recorded"

# new push (new sha), no hold label: re-armed
pr_json '[]' null bbb
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "new head SHA re-arms" || fail "new head SHA did not re-arm"

# new push but hold label: still not armed
: > "$ARM_LOG"; pr_json '[{"name":"do-not-merge"}]' null ccc
bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "do-not-merge label blocks re-arm" || fail "do-not-merge ignored"

# --- INFRA-8178: human-vs-gate disarm classification -----------------------

# Scenario A: auto_merge_disabled attributed to the automation login itself
# (the dominant real-world case — PR #5488/#5476 receipts) -> gate
# behaviour, not a human hold -> re-arm once green.
: > "$ARM_LOG"
printf 'tester\t2026-01-01T00:10:00Z' > "$T/timeline-bot-self.txt"
: > "$T/checkruns-empty-a.txt"
export TIMELINE_FIXTURE="$T/timeline-bot-self.txt" CHECKRUNS_FIXTURE="$T/checkruns-empty-a.txt"
arm_json '[]' ddd
bash "$SWEEPER" >/dev/null 2>&1
pr_json '[]' null ddd
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "automation-login disarm is re-armed (not a human hold)" \
                                 || fail "automation-login disarm was NOT re-armed"

# Scenario B: disarm attributed to a non-automation actor but landing right
# after a failed required check on the same head -> still gate behaviour.
: > "$ARM_LOG"
printf 'github-actions[bot]\t2026-01-01T00:10:00Z' > "$T/timeline-bot-check.txt"
printf '2026-01-01T00:05:00Z\n' > "$T/checkruns-failed.txt"
export TIMELINE_FIXTURE="$T/timeline-bot-check.txt" CHECKRUNS_FIXTURE="$T/checkruns-failed.txt"
arm_json '[]' eee
bash "$SWEEPER" >/dev/null 2>&1
pr_json '[]' null eee
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "disarm within window of a failed check is re-armed" \
                                 || fail "disarm within window of a failed check was NOT re-armed"

# Scenario C: a REAL human disarm — different actor, AND no failed-check
# anywhere near the disarm timestamp — is still respected.
: > "$ARM_LOG"
printf 'jeffadkins\t2026-01-01T00:10:00Z' > "$T/timeline-human.txt"
: > "$T/checkruns-empty-c.txt"
export TIMELINE_FIXTURE="$T/timeline-human.txt" CHECKRUNS_FIXTURE="$T/checkruns-empty-c.txt"
arm_json '[]' fff
bash "$SWEEPER" >/dev/null 2>&1
pr_json '[]' null fff
bash "$SWEEPER" >/dev/null 2>&1; bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "genuine human disarm (unrelated actor, no failed check) is respected" \
                       || fail "genuine human disarm was incorrectly re-armed"
grep -q "disarmed.jeffadkins" "$T/state.tsv" && pass "human disarmer recorded (jeffadkins)" \
                                              || fail "human disarmer not recorded"

# Scenario D: a bot/app actor (dependabot[bot]) disarms with NO failed-check
# anywhere near the disarm timestamp -> still NOT a human hold (bot logins
# are never human, independent of timing correlation) -> re-armed.
: > "$ARM_LOG"
printf 'dependabot[bot]\t2026-01-01T00:10:00Z' > "$T/timeline-bot-no-check.txt"
: > "$T/checkruns-empty-d.txt"
export TIMELINE_FIXTURE="$T/timeline-bot-no-check.txt" CHECKRUNS_FIXTURE="$T/checkruns-empty-d.txt"
arm_json '[]' ggg
bash "$SWEEPER" >/dev/null 2>&1
pr_json '[]' null ggg
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "bot-suffixed actor disarm is re-armed even without a correlated failed check" \
                                 || fail "bot-suffixed actor disarm was NOT re-armed"

unset TIMELINE_FIXTURE CHECKRUNS_FIXTURE

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
