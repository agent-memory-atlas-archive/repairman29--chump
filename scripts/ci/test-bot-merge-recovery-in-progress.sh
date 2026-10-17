#!/usr/bin/env bash
# test-bot-merge-recovery-in-progress.sh — INFRA-8208
#
# bot-merge.sh recovery mode (CHUMP_BOT_MERGE_RECOVERY_MODE=1) pushes the gap
# branch itself but never exported CHUMP_BOT_MERGE_IN_PROGRESS=1 (only the
# normal push path did), so pre-push Guard 4 (INFRA-719) refused a recovery
# push of a never-pushed chump/<gap>-* branch and the operator had to prefix
# the command by hand.
#
# Functional proof, no mocks of the thing under test: the REAL recovery push
# block is extracted verbatim from scripts/coord/bot-merge.sh and run against a
# throwaway repo + bare "remote" that has the REAL scripts/git-hooks/pre-push
# installed.
#   1. control   - plain `git push` of a new chump/* branch -> BLOCKED (INFRA-719)
#   2. recovery  - the extracted block pushes it, with none of the Guard 4
#                  bypass env vars set (the bot-merge bypass, operator recovery)
#                  in the environment -> passes
#   3. negative  - the same block with the export line deleted -> BLOCKED, so
#                  test 2 genuinely depends on the INFRA-8208 export
#   4. static    - the export precedes the recovery push in the script

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-8208 recovery push passes pre-push Guard 4 ==="
echo

PUSH_LINE="$(grep -n 'stage_start "recovery: push"' "$SCRIPT" | head -1 | cut -d: -f1)"
EXPORT_LINE="$(grep -n '^    export CHUMP_BOT_MERGE_IN_PROGRESS=1' "$SCRIPT" | head -1 | cut -d: -f1)"
RUN_LINE="$(awk -v s="${PUSH_LINE:-0}" 'NR>s && /run git push -u origin "\$BRANCH"/ {print NR; exit}' "$SCRIPT")"
DONE_LINE="$(awk -v s="${RUN_LINE:-0}" 'NR>s && /stage_done/ {print NR; exit}' "$SCRIPT")"

if [[ -z "$PUSH_LINE" || -z "$EXPORT_LINE" || -z "$RUN_LINE" || -z "$DONE_LINE" ]]; then
    fail "could not locate the recovery push block in $SCRIPT (push=$PUSH_LINE export=$EXPORT_LINE run=$RUN_LINE done=$DONE_LINE)"
    echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

if [[ "$EXPORT_LINE" -lt "$PUSH_LINE" && "$PUSH_LINE" -lt "$RUN_LINE" ]]; then
    ok "static: export CHUMP_BOT_MERGE_IN_PROGRESS=1 precedes the recovery push"
else
    fail "static: export (line $EXPORT_LINE) does not precede the recovery push (lines $PUSH_LINE/$RUN_LINE)"
fi
# The export must be inside the recovery block (after the recovery-mode `if`).
RECOVERY_IF="$(grep -n 'CHUMP_BOT_MERGE_RECOVERY_MODE:-0}" == "1" \]\]; then' "$SCRIPT" | head -1 | cut -d: -f1)"
if [[ -n "$RECOVERY_IF" && "$EXPORT_LINE" -gt "$RECOVERY_IF" ]]; then
    ok "static: export sits inside the recovery-mode block"
else
    fail "static: export is not inside the recovery-mode block"
fi

BLOCK="$(sed -n "${EXPORT_LINE},${DONE_LINE}p" "$SCRIPT")"
BLOCK_NO_EXPORT="$(printf '%s\n' "$BLOCK" | sed '1d')"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a work repo whose hook is the real pre-push, plus a fresh gap branch
# per scenario (the first push of a branch is what Guard 4 polices).
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

new_branch() {
    local b="$1"
    (cd "$TMP/work" && git checkout -q main && git checkout -q -b "$b" \
        && echo "$b" > "f_$(echo "$b" | tr '/' '_')" && git add -A && git commit -qm "INFRA-8208: $b")
}

# Run with an EMPTY environment (env -i) so no inherited marker or bypass knob
# can mask Guard 4; keep the heavy guards off.
clean_env() {
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        CHUMP_GAP_CHECK=0 CHUMP_ALLOW_UNREGISTERED_GAP=1 CHUMP_MERGE_PREVIEW=0 \
        CHUMP_TEST_GATE=0 CHUMP_CLIPPY_GATE=0 "$@"
}

run_block() {   # run_block <branch> <block-text>
    local b="$1" text="$2"
    cat > "$TMP/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
stage_start() { :; }
stage_done()  { :; }
run() { "\$@"; }
cd "$TMP/work"
BRANCH="$b"
$text
HARNESS
    clean_env bash "$TMP/harness.sh" 2>&1
}

echo "--- Test 1 (control): plain push of a new chump/* branch is refused ---"
new_branch chump/infra-8208-control
OUT="$(cd "$TMP/work" && clean_env git push -u origin chump/infra-8208-control 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]] && printf '%s' "$OUT" | grep -q "BLOCKED (INFRA-719)"; then
    ok "T1: plain push blocked by Guard 4 (INFRA-719)"
else
    fail "T1: control push was not blocked by Guard 4 (rc=$RC): $OUT"
fi

echo "--- Test 2: recovery push block passes Guard 4 without any bypass env ---"
new_branch chump/infra-8208-recovery
OUT="$(run_block chump/infra-8208-recovery "$BLOCK")"; RC=$?
if [[ "$RC" -eq 0 ]] && ! printf '%s' "$OUT" | grep -q "BLOCKED (INFRA-719)"; then
    ok "T2: recovery push passed Guard 4 (no bypass env var, no CHUMP_OPERATOR_RECOVERY)"
else
    fail "T2: recovery push failed (rc=$RC): $OUT"
fi
if git -C "$TMP/remote.git" rev-parse --verify -q refs/heads/chump/infra-8208-recovery >/dev/null; then
    ok "T2: branch landed on the stub remote"
else
    fail "T2: branch did not land on the stub remote"
fi

echo "--- Test 3 (negative): same block minus the export is refused ---"
new_branch chump/infra-8208-noexport
OUT="$(run_block chump/infra-8208-noexport "$BLOCK_NO_EXPORT")"; RC=$?
if [[ "$RC" -ne 0 ]] && printf '%s' "$OUT" | grep -q "BLOCKED (INFRA-719)"; then
    ok "T3: without the export the recovery push is blocked (test 2 depends on INFRA-8208)"
else
    fail "T3: push without the export was not blocked (rc=$RC): $OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
