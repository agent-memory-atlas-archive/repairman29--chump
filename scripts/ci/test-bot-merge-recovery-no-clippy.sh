#!/usr/bin/env bash
# test-bot-merge-recovery-no-clippy.sh — RESILIENT-1608
#
# Receipt (2026-10-16, INFRA-8180 salvage on cuphead): bot-merge recovery mode
# pushed, the pre-push hook re-ran clippy, hit its 600s phase cap and reported
# "cargo clippy -D warnings failed" although no lint failed.
#
#   T1 control  - a plain push with a .rs change runs the pre-push clippy gate
#                 (stub cargo counts >= 1), so T2's zero is not vacuous
#   T2 AC1      - the REAL recovery push block, extracted from bot-merge.sh,
#                 pushes the same kind of branch with ZERO clippy invocations
#   T3 AC2      - a clippy that hits the phase timeout is BLOCKED as a timeout
#                 (message + kind=prepush_clippy_blocked outcome=timeout)
#   T4 AC2      - a clippy that fails is still BLOCKED as a lint failure,
#                 message unchanged, outcome=lint_failure
#   T5 AC3      - chump_clippy_budget derives the budget from green clippy
#                 durations (x1.5, floor 300, ceiling 3600, default 900)
#   T6 AC3      - bot-merge logs the derivation, and stage_done checks a
#                 stage against its OWN budget (the 541s-vs-300s wedge)

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
LIB="$REPO_ROOT/scripts/coord/lib/clippy-budget.sh"

echo "=== RESILIENT-1608 recovery push never re-runs clippy; timeout != lint failure; derived budget ==="

if ! command -v timeout >/dev/null 2>&1; then
    echo "SKIP: no 'timeout' binary (the pre-push hook needs it)"
    exit 0
fi

EXPORT_LINE="$(grep -n '^    export CHUMP_BOT_MERGE_IN_PROGRESS=1' "$SCRIPT" | head -1 | cut -d: -f1)"
PUSH_LINE="$(grep -n 'stage_start "recovery: push"' "$SCRIPT" | head -1 | cut -d: -f1)"
RUN_LINE="$(awk -v s="${PUSH_LINE:-0}" 'NR>s && /run git push -u origin "\$BRANCH"/ {print NR; exit}' "$SCRIPT")"
DONE_LINE="$(awk -v s="${RUN_LINE:-0}" 'NR>s && /stage_done/ {print NR; exit}' "$SCRIPT")"
if [[ -z "$EXPORT_LINE" || -z "$PUSH_LINE" || -z "$RUN_LINE" || -z "$DONE_LINE" || "$EXPORT_LINE" -gt "$PUSH_LINE" ]]; then
    fail "could not locate the recovery push block (export=$EXPORT_LINE push=$PUSH_LINE run=$RUN_LINE done=$DONE_LINE)"
    echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi
BLOCK="$(sed -n "${EXPORT_LINE},${DONE_LINE}p" "$SCRIPT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub cargo: counts clippy invocations; behaviour per $STUB_MODE.
mkdir -p "$TMP/bin"
COUNT="$TMP/clippy.count"
cat > "$TMP/bin/cargo" <<STUB
#!/usr/bin/env bash
case " \$* " in
    *" clippy "*)
        echo clippy >> "$COUNT"
        case "\${STUB_MODE:-pass}" in
            hang) sleep 30 ;;
            lint) echo "error: unused variable" >&2; exit 101 ;;
        esac
        ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/cargo"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/work"
(
    cd "$TMP/work" || exit 1
    git config user.email t@example.invalid; git config user.name test
    echo a > a; git add a; git commit -qm init
    git remote add origin "$TMP/remote.git"
    git push -q origin main >/dev/null 2>&1
    printf '.chump-locks/\n' >> .git/info/exclude
    mkdir -p .git/hooks
    cp "$HOOK" .git/hooks/pre-push; chmod +x .git/hooks/pre-push
) || { fail "could not build the throwaway repo"; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1; }

new_rs_branch() {
    local b="$1"
    (cd "$TMP/work" && git checkout -q main && git checkout -q -b "$b" \
        && echo "fn f() {}" > "f_$(echo "$b" | tr '/-' '__').rs" && git add -A \
        && git commit -qm "RESILIENT-1608: $b")
}

AMB="$TMP/ambient.jsonl"
clean_env() {
    env -i PATH="$TMP/bin:$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        CHUMP_GAP_CHECK=0 CHUMP_ALLOW_UNREGISTERED_GAP=1 CHUMP_MERGE_PREVIEW=0 \
        CHUMP_TEST_GATE=0 CHUMP_CLIPPY_MIN_DISK_KB=0 CHUMP_AMBIENT_LOG="$AMB" "$@"
}
clippy_count() { [[ -f "$COUNT" ]] && wc -l < "$COUNT" | tr -d ' ' || echo 0; }

echo "--- T1 (control): plain push with a .rs change runs the clippy gate ---"
rm -f "$COUNT"; new_rs_branch claude/resilient-1608-control
OUT="$(cd "$TMP/work" && clean_env git push -u origin claude/resilient-1608-control 2>&1)"; RC=$?
N="$(clippy_count)"
if [[ "$RC" -eq 0 && "$N" -ge 1 ]]; then
    ok "T1: plain push ran clippy ($N invocation(s)) and passed"
else
    fail "T1: control push rc=$RC clippy=$N: $OUT"
fi

echo "--- T2 (AC1): recovery push block pushes with zero clippy invocations ---"
rm -f "$COUNT"; new_rs_branch claude/resilient-1608-recovery
cat > "$TMP/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
stage_start() { :; }
stage_done()  { :; }
run() { "\$@"; }
cd "$TMP/work"
BRANCH="claude/resilient-1608-recovery"
$BLOCK
HARNESS
OUT="$(clean_env CHUMP_BOT_MERGE_RECOVERY_MODE=1 bash "$TMP/harness.sh" 2>&1)"; RC=$?
N="$(clippy_count)"
if [[ "$RC" -eq 0 && "$N" -eq 0 ]]; then
    ok "T2: recovery push passed with 0 clippy invocations"
else
    fail "T2: recovery push rc=$RC clippy=$N: $OUT"
fi
if git -C "$TMP/remote.git" rev-parse --verify -q refs/heads/claude/resilient-1608-recovery >/dev/null; then
    ok "T2: recovery branch landed on the stub remote"
else
    fail "T2: recovery branch did not land on the stub remote"
fi

echo "--- T3 (AC2): clippy timeout is reported as a timeout ---"
rm -f "$COUNT" "$AMB"; new_rs_branch claude/resilient-1608-timeout
OUT="$(cd "$TMP/work" && clean_env STUB_MODE=hang CHUMP_PREPUSH_CLIPPY_TIMEOUT_S=2 git push -u origin claude/resilient-1608-timeout 2>&1)"; RC=$?
case "$OUT" in
    *"cargo clippy TIMED OUT after 2s (RESILIENT-1608)"*) T3MSG=1 ;;
    *) T3MSG=0 ;;
esac
case "$OUT" in
    *"cargo clippy -D warnings failed"*) T3LINT=1 ;;
    *) T3LINT=0 ;;
esac
if [[ "$RC" -ne 0 && "$T3MSG" -eq 1 && "$T3LINT" -eq 0 ]]; then
    ok "T3: timed-out clippy BLOCKED as a timeout, not as a lint failure"
else
    fail "T3: rc=$RC timeout_msg=$T3MSG lint_msg=$T3LINT: $OUT"
fi
AMB_BODY="$(cat "$AMB" 2>/dev/null || true)"
case "$AMB_BODY" in
    *'"kind":"prepush_clippy_blocked","outcome":"timeout"'*) ok "T3: kind=prepush_clippy_blocked outcome=timeout emitted" ;;
    *) fail "T3: no prepush_clippy_blocked outcome=timeout event: $AMB_BODY" ;;
esac

echo "--- T4 (AC2): clippy lint failure keeps its message ---"
rm -f "$COUNT" "$AMB"; new_rs_branch claude/resilient-1608-lint
OUT="$(cd "$TMP/work" && clean_env STUB_MODE=lint git push -u origin claude/resilient-1608-lint 2>&1)"; RC=$?
case "$OUT" in
    *"[pre-push] BLOCKED: cargo clippy -D warnings failed (INFRA-1390)."*) T4MSG=1 ;;
    *) T4MSG=0 ;;
esac
if [[ "$RC" -ne 0 && "$T4MSG" -eq 1 ]]; then
    ok "T4: failing clippy BLOCKED with the unchanged INFRA-1390 message"
else
    fail "T4: rc=$RC lint_msg=$T4MSG: $OUT"
fi
AMB_BODY="$(cat "$AMB" 2>/dev/null || true)"
case "$AMB_BODY" in
    *'"kind":"prepush_clippy_blocked","outcome":"lint_failure"'*) ok "T4: kind=prepush_clippy_blocked outcome=lint_failure emitted" ;;
    *) fail "T4: no prepush_clippy_blocked outcome=lint_failure event: $AMB_BODY" ;;
esac

echo "--- T5 (AC3): derived clippy budget ---"
# shellcheck source=scripts/coord/lib/clippy-budget.sh
. "$LIB"
dur() { printf '{"ts":"t","kind":"bot_merge_phase_duration","phase":"%s","elapsed_s":%d,"gap":"G","branch":"b"}\n' "$1" "$2"; }
expect_budget() {   # expect_budget <label> <ambient-file> <want>
    local got; got="$(chump_clippy_budget "$2")"
    if [[ "$got" == "$3" ]]; then ok "T5: $1 -> $got"; else fail "T5: $1: got '$got' want '$3'"; fi
}
expect_budget "no ambient file" "$TMP/none.jsonl" "900 default 0 0"
: > "$TMP/a1.jsonl"; dur "cargo test" 2000 >> "$TMP/a1.jsonl"
expect_budget "no clippy samples" "$TMP/a1.jsonl" "900 default 0 0"
dur "cargo clippy --workspace --all-targets" 541 >> "$TMP/a1.jsonl"
expect_budget "one 541s green clippy" "$TMP/a1.jsonl" "812 last_green 541 1"
: > "$TMP/a2.jsonl"; dur "cargo clippy --workspace --all-targets" 100 >> "$TMP/a2.jsonl"
expect_budget "fast clippy floors at 300" "$TMP/a2.jsonl" "300 last_green 100 1"
: > "$TMP/a3.jsonl"; dur "cargo clippy --workspace --all-targets" 3000 >> "$TMP/a3.jsonl"
expect_budget "slow clippy caps at 3600" "$TMP/a3.jsonl" "3600 last_green 3000 1"
: > "$TMP/a4.jsonl"
for s in 1000 200 210 220 230 240; do dur "cargo clippy --workspace --all-targets" "$s" >> "$TMP/a4.jsonl"; done
dur "cargo clippy --bin chump --fix (--fast pre-flight auto-correct)" 5000 >> "$TMP/a4.jsonl"
expect_budget "slowest of the LAST 5 greens; --fix pre-flight ignored" "$TMP/a4.jsonl" "360 last_green 240 5"

echo "--- T6 (AC3): bot-merge uses + logs the derivation; stage_done uses the stage's own budget ---"
if grep -q 'chump_clippy_budget "\$_clippy_amb"' "$SCRIPT" \
    && grep -q '"kind":"bot_merge_clippy_budget_derived"' "$SCRIPT" \
    && grep -q '_run_cargo_with_lock_detect "cargo clippy" "\$_clippy_budget"' "$SCRIPT"; then
    ok "T6: clippy stage timeout comes from chump_clippy_budget and the derivation is emitted"
else
    fail "T6: bot-merge clippy stage is not wired to the derived budget"
fi
SD_START="$(grep -n '^stage_done() {' "$SCRIPT" | head -1 | cut -d: -f1)"
SD_BODY="$(sed -n "${SD_START:-1},$(( ${SD_START:-1} + 20 ))p" "$SCRIPT")"
case "$SD_BODY" in
    *'local budget="${__STAGE_BUDGET:-'*) ok "T6: stage_done checks elapsed against the stage's own budget" ;;
    *) fail "T6: stage_done still checks against the global budget" ;;
esac

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
