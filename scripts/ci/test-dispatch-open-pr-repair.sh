#!/usr/bin/env bash
# scripts/ci/test-dispatch-open-pr-repair.sh — INFRA-8199
#
# `chump dispatch <GAP> --backend headless` with no --prompt, on a gap whose
# PR was already open, auto-built a prompt that decomposed instead of
# repairing (cuphead CREDIBLE-1491.redispatch.log, 2026-10-16 00:35Z: PR
# #5473 on claude/credible-1491 untouched, eight sub-gaps filed). This test
# drives the real binary with a stubbed `gh` on PATH and proves:
#   1. an open PR refuses the dispatch BEFORE any work backend spawns, and
#      the refusal names the PR number and head branch;
#   2. CHUMP_CLAIM_ALLOW_DUPLICATE_PR=0 is not an override (still refuses);
#   3. CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1 turns it into a REPAIR: mode=Repair on
#      the PR head branch, a brief with the PR number, branch and failing
#      check names, no decomposition text, and kind=dispatch_repair_brief_built
#      in ambient with the PR number;
#   4. with no open PR the dispatch proceeds as ordinary work.
# Uses --print-prompt, so nothing is spawned, claimed or pushed.
# No network: gh is a stub. Needs a built chump binary (CHUMP_BIN, or
# ${CARGO_TARGET_DIR:-target}/debug/chump); builds one if cargo is present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0; FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

echo "=== INFRA-8199 dispatch open-PR refuse/repair test ==="

BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if [[ ! -x "$BIN" ]]; then
    if command -v cargo >/dev/null 2>&1; then
        (cd "$REPO_ROOT" && cargo build --bin chump 2>&1 | tail -3)
    fi
fi
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: no chump binary at $BIN and could not build one" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture repo the binary runs from (no remote, nothing real to touch).
FIX="$TMP/repo"
mkdir -p "$FIX"
(
    cd "$FIX" && git init -q -b main && git config user.email t@example.com \
        && git config user.name t && echo x > f.txt && git add f.txt \
        && git commit -q -m init
) || { echo "FAIL: fixture git repo" >&2; exit 1; }

STUB="$TMP/bin"
mkdir -p "$STUB"
GH_LOG="$TMP/gh.log"
: > "$GH_LOG"
cat > "$STUB/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
    cat "\${STUB_PR_JSON:?}"
    exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "checks" ]]; then
    cat <<'JSON'
[{"name":"fmt","bucket":"fail"},{"name":"clippy","bucket":"fail"},{"name":"test","bucket":"fail"},{"name":"docs","bucket":"pass"}]
JSON
    exit 1
fi
exit 1
STUBEOF
chmod +x "$STUB/gh"

PR_OPEN="$TMP/pr-open.json"
cat > "$PR_OPEN" <<'JSON'
[{"number":5473,"title":"CREDIBLE-1491: branch-protection baseline","headRefName":"claude/credible-1491"}]
JSON
PR_NONE="$TMP/pr-none.json"
echo '[]' > "$PR_NONE"

AMB="$TMP/ambient.jsonl"

run_dispatch() {
    # $1 = PR json fixture; rest = env assignments
    local fixture="$1"; shift
    (
        cd "$FIX" || exit 99
        env -u CHUMP_CLAIM_ALLOW_DUPLICATE_PR \
            PATH="$STUB:$PATH" STUB_PR_JSON="$fixture" \
            CHUMP_AMBIENT_LOG="$AMB" CHUMP_AMBIENT_NATS=0 CHUMP_REPO="$FIX" \
            "$@" \
            "$BIN" dispatch CREDIBLE-1491 --backend headless --model sonnet --print-prompt
    )
}

# ── 1. open PR, no override → refuse before spawning ─────────────────────────
OUT="$(run_dispatch "$PR_OPEN" 2>&1)"; RC=$?
if [[ $RC -ne 0 ]]; then ok "refuses with non-zero exit (rc=$RC)"; else fail "expected refusal, got rc=0"; fi
grep -q '#5473' <<<"$OUT" && ok "refusal names PR #5473" || fail "refusal missing PR number: $OUT"
grep -q 'claude/credible-1491' <<<"$OUT" && ok "refusal names head branch" || fail "refusal missing head branch: $OUT"
grep -q 'CHUMP_CLAIM_ALLOW_DUPLICATE_PR' <<<"$OUT" && ok "refusal names the override" || fail "refusal missing override hint"
if grep -q 'auto-building the work prompt' <<<"$OUT"; then
    fail "a work prompt was built before the refusal (gate must run first)"
else
    ok "no work prompt built (gate ran before the backend)"
fi

# ── 2. override=0 is not an override ─────────────────────────────────────────
OUT="$(run_dispatch "$PR_OPEN" CHUMP_CLAIM_ALLOW_DUPLICATE_PR=0 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && grep -q '#5473' <<<"$OUT" \
    && ok "CHUMP_CLAIM_ALLOW_DUPLICATE_PR=0 still refuses" \
    || fail "override=0 should refuse (rc=$RC): $OUT"

# ── 3. override=1 → repair brief on the PR head ──────────────────────────────
: > "$AMB"
OUT="$(run_dispatch "$PR_OPEN" CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && ok "override proceeds (rc=0)" || fail "override run failed rc=$RC: $OUT"
grep -q 'mode=Repair { head_branch: "claude/credible-1491" }' <<<"$OUT" \
    && ok "mode is Repair on the PR head branch" || fail "mode not Repair on PR head: $OUT"
grep -q 'REPAIRING an existing pull request' <<<"$OUT" && ok "prompt is a repair brief" || fail "not a repair brief"
grep -q 'PR #5473' <<<"$OUT" && ok "brief names PR #5473" || fail "brief missing PR number"
grep -q 'git push origin HEAD:claude/credible-1491' <<<"$OUT" && ok "brief says fix and push to the head branch" || fail "brief missing push instruction"
for c in fmt clippy test; do
    grep -q -- "  - $c\$" <<<"$OUT" && ok "brief lists failing check: $c" || fail "brief missing failing check $c"
done
grep -q -- '  - docs$' <<<"$OUT" && fail "brief lists a passing check (docs)" || ok "passing checks not listed"
if grep -qi 'decompos' <<<"$OUT"; then
    fail "repair brief contains decomposition text"
else
    ok "repair brief contains no decomposition text"
fi
if grep -q '"kind":"dispatch_repair_brief_built"' "$AMB" && grep -q '"pr_number":5473' "$AMB"; then
    ok "kind=dispatch_repair_brief_built emitted with pr_number=5473"
else
    fail "dispatch_repair_brief_built not in ambient: $(cat "$AMB")"
fi

# ── 4. no open PR → ordinary work ────────────────────────────────────────────
OUT="$(run_dispatch "$PR_NONE" 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && ok "no-PR dispatch proceeds (rc=0)" || fail "no-PR run failed rc=$RC: $OUT"
grep -q 'mode=Work' <<<"$OUT" && ok "no-PR mode is Work" || fail "no-PR mode not Work: $OUT"
grep -q 'INFRA-8199 guard' <<<"$OUT" && ok "work prompt carries the no-self-filing guard" || fail "work prompt missing guard"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
