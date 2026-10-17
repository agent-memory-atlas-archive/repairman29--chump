#!/usr/bin/env bash
# test-bot-merge-recovery-pr-create.sh — RESILIENT-217 + INFRA-8209
#
# bot-merge.sh's recovery-mode "pr create/update" stage (CHUMP_BOT_MERGE_RECOVERY_MODE=1)
# had two stacked defects:
#   RESILIENT-217: a failed `gh pr create` was swallowed (`|| true`), leaving the
#     PR number empty while the stage still logged done and exited 0.
#   INFRA-8209: it called `gh pr create ... --json number`, a flag gh pr create
#     does not have, so it ALWAYS failed; and the failure was captured with a
#     bare `x="$(gh ...)"; rc=$?`, so the RESILIENT-052 ERR trap fired before
#     the RESILIENT-217 handler ever ran.
#
# This test extracts the REAL production block verbatim from
# scripts/coord/bot-merge.sh (not a reimplementation, so it cannot drift) and
# runs it under `set -e` with an ERR trap installed, against a stub `gh` that
# behaves like the real one (rejects --json, prints the PR URL on success):
#   1. gh pr create fails      -> exit 1, RESILIENT-217 reason printed,
#                                 kind=botmerge_recovery_pr_create_failed emitted,
#                                 ERR trap NOT fired
#   2. gh pr create succeeds   -> exit 0, number parsed from the printed URL,
#                                 called with --base/--head/--title/--body, no --json
#   3. PR already exists       -> gh pr create not invoked, exit 0
#   4. gh prints no URL        -> number resolved via `gh pr list --head`

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== RESILIENT-217 / INFRA-8209 recovery-mode PR-create handling ==="
echo

START_LINE="$(grep -n 'stage_start "recovery: pr create/update"' "$SCRIPT" | head -1 | cut -d: -f1)"
END_MARKER_LINE="$(grep -n 'if \[\[ -n "\$_recover_pr_num" && "\${AUTO_MERGE' "$SCRIPT" | head -1 | cut -d: -f1)"

if [[ -z "$START_LINE" || -z "$END_MARKER_LINE" ]]; then
    fail "could not locate recovery pr-create block markers in $SCRIPT"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
END_LINE=$((END_MARKER_LINE - 1))

BLOCK="$(sed -n "${START_LINE},${END_LINE}p" "$SCRIPT")"

if ! printf '%s\n' "$BLOCK" | grep -q 'botmerge_recovery_pr_create_failed'; then
    fail "extracted block missing botmerge_recovery_pr_create_failed emit"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "extracted real production block contains the RESILIENT-217 failure path"

if printf '%s\n' "$BLOCK" | grep -E '^[^#]*gh pr create' | grep -q -- '--json'; then
    fail "production block still passes --json to gh pr create (INFRA-8209)"
else
    ok "production block does not pass --json to gh pr create (INFRA-8209)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build_harness() {
    local mode="$1"   # fail | succeed | existing | nourl
    local harness="$TMP/harness_${mode}.sh"
    local calls="$TMP/gh_calls_${mode}.log"
    cat > "$harness" <<HARNESS_HEAD
#!/usr/bin/env bash
# Same shell options + class of ERR trap as production bot-merge.sh.
set -euo pipefail
trap 'echo ERR_TRAP_FIRED > "$TMP/err_trap_${mode}.flag"' ERR
stage_start() { :; }
stage_done()  { :; }
red() { printf '%s\n' "\$*" >&2; }
git() {
    if [[ "\$1" == "log" ]]; then echo "fake commit subject"; return 0; fi
    command git "\$@"
}
GH_MODE="$mode"
GH_CALLS="$calls"
CREATED_FLAG="$TMP/created_${mode}.flag"
gh() {
    echo "gh \$*" >> "\$GH_CALLS"
    if [[ "\$1 \$2" == "pr list" ]]; then
        case "\$GH_MODE" in
            existing) echo "4242" ;;
            nourl)    [[ -f "\$CREATED_FLAG" ]] && echo "7777" ;;
        esac
        return 0
    fi
    if [[ "\$1 \$2" == "pr create" ]]; then
        # Real gh: --json is not a flag of 'gh pr create'.
        case " \$* " in *" --json "*) echo "unknown flag: --json" >&2; return 1 ;; esac
        case "\$GH_MODE" in
            fail)    echo "HttpError: rate limit exceeded" >&2; return 1 ;;
            succeed) echo "https://github.com/repairman29/chump/pull/9001"; return 0 ;;
            nourl)   touch "\$CREATED_FLAG"; echo "Creating pull request for x into main"; return 0 ;;
            existing) echo "should not be called in existing-PR mode" >&2; return 1 ;;
        esac
    fi
    return 0
}

BRANCH="chump/infra-8209-test"
BASE_BRANCH="main"
_gap_lbl="INFRA-8209"
_bm_recover_amb="$TMP/ambient_${mode}.jsonl"

$BLOCK

echo "REACHED_END pr=\${_recover_pr_num:-none}"
HARNESS_HEAD
    printf '%s' "$harness"
}

run_mode() {
    local mode="$1" h
    h="$(build_harness "$mode")"
    set +e
    OUT="$(bash "$h" 2>&1)"
    RC=$?
    set -e
}

echo "--- Test 1: gh pr create fails -> RESILIENT-217 handler, not the ERR trap ---"
run_mode fail
[[ "$RC" -eq 1 ]] && ok "T1: exit 1 on gh pr create failure" || fail "T1: expected exit 1, got $RC ($OUT)"
printf '%s\n' "$OUT" | grep -q "REACHED_END" \
    && fail "T1: fell through past the failure branch" || ok "T1: exited before the success path"
printf '%s\n' "$OUT" | grep -q "RESILIENT-217.*rate limit exceeded" \
    && ok "T1: RESILIENT-217 reason (gh's error text) printed" || fail "T1: reason not printed ($OUT)"
grep -q "botmerge_recovery_pr_create_failed" "$TMP/ambient_fail.jsonl" 2>/dev/null \
    && ok "T1: botmerge_recovery_pr_create_failed emitted" || fail "T1: failure event not emitted"
grep -q "rate limit exceeded" "$TMP/ambient_fail.jsonl" 2>/dev/null \
    && ok "T1: gh error text captured in the event reason" || fail "T1: error text missing from event"
[[ ! -f "$TMP/err_trap_fail.flag" ]] \
    && ok "T1: ERR trap did NOT fire (failure reached the RESILIENT-217 handler)" \
    || fail "T1: ERR trap fired before the RESILIENT-217 handler"

echo
echo "--- Test 2: gh pr create succeeds -> number parsed from the printed URL ---"
run_mode succeed
[[ "$RC" -eq 0 ]] && ok "T2: exit 0" || fail "T2: expected exit 0, got $RC ($OUT)"
printf '%s\n' "$OUT" | grep -q "REACHED_END pr=9001" \
    && ok "T2: PR number 9001 resolved from the URL" || fail "T2: PR number not resolved ($OUT)"
CREATE_CALL="$(grep '^gh pr create' "$TMP/gh_calls_succeed.log" || true)"
for f in --base --head --title --body; do
    case "$CREATE_CALL" in *" $f "*) ok "T2: gh pr create passed $f" ;; *) fail "T2: gh pr create missing $f ($CREATE_CALL)" ;; esac
done
case "$CREATE_CALL" in *--json*) fail "T2: --json passed to gh pr create" ;; *) ok "T2: no --json passed" ;; esac
[[ ! -s "$TMP/ambient_succeed.jsonl" ]] && ok "T2: no failure event on success" || fail "T2: failure event on success"
[[ ! -f "$TMP/err_trap_succeed.flag" ]] && ok "T2: ERR trap did not fire" || fail "T2: ERR trap fired"

echo
echo "--- Test 3: PR already exists -> gh pr create not invoked ---"
run_mode existing
[[ "$RC" -eq 0 ]] && ok "T3: exit 0" || fail "T3: expected exit 0, got $RC ($OUT)"
grep -q '^gh pr create' "$TMP/gh_calls_existing.log" \
    && fail "T3: gh pr create invoked despite an existing PR" || ok "T3: gh pr create skipped"
printf '%s\n' "$OUT" | grep -q "REACHED_END pr=4242" && ok "T3: existing PR 4242 used" || fail "T3: existing PR not used"

echo
echo "--- Test 4: gh prints no URL -> number resolved via gh pr list --head ---"
run_mode nourl
[[ "$RC" -eq 0 ]] && ok "T4: exit 0" || fail "T4: expected exit 0, got $RC ($OUT)"
printf '%s\n' "$OUT" | grep -q "REACHED_END pr=7777" \
    && ok "T4: PR number 7777 resolved via gh pr list --head" || fail "T4: fallback lookup failed ($OUT)"
grep -c '^gh pr list' "$TMP/gh_calls_nourl.log" | grep -q '^2$' \
    && ok "T4: gh pr list consulted before and after create" || fail "T4: unexpected gh pr list call count"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
