#!/usr/bin/env bash
# test-credible-1520-link-pr-at-open.sh — CREDIBLE-1520 (Phase R R2, AC1)
#
# AC1: every code path that opens a PR for a gap writes a gap_prs row via
# link_pr (chump gap link-pr), so a later `chump gap ship` can read the typed
# FK instead of re-parsing the PR title. This test proves — with a stubbed gh —
# that each of the three documented paths writes the row:
#
#   T1  bot-merge.sh  — the REAL _bm_link_pr helper + the PR-number resolution
#                       block extracted from bot-merge.sh, driven by a stubbed
#                       `gh pr view`, writes one gap_prs row per cited gap.
#   T2  manual path   — the documented `chump gap link-pr <ID> <PR> --sha` call
#                       (CLAUDE.md ship-pipeline manual fallback) writes the row,
#                       and CLAUDE.md actually documents that call.
#   T3  dispatch      — `chump dispatch` salvage/ship routes through bot-merge.sh
#                       (so it inherits T1's write) and has NO independent
#                       `gh pr create` that would bypass it.
#
# This does NOT test ship-refuses-without-a-row — that is AC2, a later slice.

set -uo pipefail
PASS=0; FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"
DISPATCH="$REPO_ROOT/src/dispatch.rs"
CLAUDEMD="$REPO_ROOT/CLAUDE.md"

echo "=== CREDIBLE-1520 AC1: gap_prs row written at PR-open on every path ==="

if ! command -v chump >/dev/null 2>&1 && [[ -z "${CHUMP_BIN:-}" ]]; then
    echo "SKIP: chump binary not found (CHUMP_BIN unset, chump not on PATH)"; exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "SKIP: sqlite3 not available"; exit 0
fi
CHUMP="${CHUMP_BIN:-$(command -v chump)}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── a tiny git repo so `git rev-parse HEAD` yields a real head SHA ───────────
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo seed > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" -c commit.gpgsign=false commit -qm seed
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# ── stubbed gh: `gh pr view <...> --json number` returns our fake PR number ──
STUB_PR=4242
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
# Minimal gh stub for CREDIBLE-1520: enough for the bot-merge PR-number
# resolution fallback to resolve a number for the branch.
if [[ "\$1 \$2" == "pr view" ]]; then
    echo "$STUB_PR"
    exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/gh"
# chump first on PATH, then the gh stub, then the rest.
export PATH="$(dirname "$CHUMP"):$TMP/bin:$PATH"

count_rows() {  # count_rows <db> <gap_id> <pr>
    sqlite3 "$1" "SELECT COUNT(*) FROM gap_prs WHERE gap_id='$2' AND pr_number=$3 AND head_sha='$HEAD_SHA';" 2>/dev/null || echo 0
}

# ── T1: bot-merge.sh — extract the REAL _bm_link_pr + resolution block ───────
# The function body is lifted verbatim from bot-merge.sh so the test tracks the
# shipped logic, not a copy that can drift.
FN="$(awk '/^_bm_link_pr\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")"
if [[ -z "$FN" ]]; then
    fail "could not extract _bm_link_pr() from bot-merge.sh"
else
    DB1="$TMP/t1.db"
    (
        cd "$REPO"
        export CHUMP_STATE_DB="$DB1"
        info() { :; }                 # bot-merge helper, stubbed here
        GAP_IDS=("CREDIBLE-1520-T1A" "CREDIBLE-1520-T1B" "none")
        # the verbatim function
        eval "$FN"
        # the resolution block as wired in bot-merge.sh after step=pr_create:
        BRANCH="feature/credible-1520"
        _bm_linked_pr="${_rest_result:-${_new_pr:-${EXISTING_PR:-}}}"
        if [[ -z "$_bm_linked_pr" ]]; then
            _bm_linked_pr="$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")"
        fi
        _bm_link_pr "$_bm_linked_pr"
    )
    a="$(count_rows "$DB1" CREDIBLE-1520-T1A "$STUB_PR")"
    b="$(count_rows "$DB1" CREDIBLE-1520-T1B "$STUB_PR")"
    none="$(sqlite3 "$DB1" "SELECT COUNT(*) FROM gap_prs WHERE gap_id='none';" 2>/dev/null || echo 0)"
    if [[ "$a" == 1 && "$b" == 1 ]]; then
        ok "bot-merge path: wrote a gap_prs row for each cited gap (PR #$STUB_PR)"
    else
        fail "bot-merge path: expected 1 row per gap, got T1A=$a T1B=$b"
    fi
    [[ "$none" == 0 ]] && ok "bot-merge path: the 'none' sentinel is NOT linked" \
        || fail "bot-merge path: 'none' sentinel was linked ($none rows)"
fi

# Static wiring: the call must actually fire after step=pr_create (not dead).
grep -q '_bm_link_pr "\$_bm_linked_pr"' "$SCRIPT" \
    && ok "bot-merge path: _bm_link_pr is invoked after PR create" \
    || fail "bot-merge path: _bm_link_pr call not found in bot-merge.sh"

# ── T2: manual gh pr create path — the documented chump gap link-pr call ─────
DB2="$TMP/t2.db"
( cd "$REPO" && CHUMP_STATE_DB="$DB2" "$CHUMP" gap link-pr CREDIBLE-1520-T2 "$STUB_PR" --sha "$HEAD_SHA" >/dev/null 2>&1 )
if [[ "$(count_rows "$DB2" CREDIBLE-1520-T2 "$STUB_PR")" == 1 ]]; then
    ok "manual path: documented 'chump gap link-pr' writes the gap_prs row"
else
    fail "manual path: 'chump gap link-pr' did not write the row"
fi
grep -q 'chump gap link-pr' "$CLAUDEMD" \
    && ok "manual path: CLAUDE.md documents the link-pr call in the ship pipeline" \
    || fail "manual path: CLAUDE.md does not document 'chump gap link-pr'"

# ── T3: dispatch salvage/ship routes through bot-merge.sh (inherits T1) ──────
grep -q 'bot-merge.sh' "$DISPATCH" \
    && ok "dispatch path: ship() shells out to bot-merge.sh (inherits the link write)" \
    || fail "dispatch path: dispatch.rs no longer references bot-merge.sh"
# No independent PR-create in dispatch that would bypass bot-merge's link.
if grep -En '"pr",[[:space:]]*"create"' "$DISPATCH" | grep -qv '//'; then
    fail "dispatch path: dispatch.rs has its own gh pr create — bypasses the link write"
else
    ok "dispatch path: dispatch.rs has no independent gh pr create (no bypass)"
fi

# ── T4: CREDIBLE-1559 AC2 + AC3 — refuse second gap without --multi; move on re-scope ──
DB4="$TMP/t4.db"
( cd "$REPO" && CHUMP_STATE_DB="$DB4" "$CHUMP" gap link-pr CREDIBLE-1550-T4 "$STUB_PR" --sha "$HEAD_SHA" >/dev/null 2>&1 )
refuse_out="$( cd "$REPO" && CHUMP_STATE_DB="$DB4" "$CHUMP" gap link-pr CREDIBLE-1552-T4 "$STUB_PR" --sha "$HEAD_SHA" 2>&1 )"; refuse_rc=$?
if [[ "$refuse_rc" -ne 0 && "$refuse_out" == *"CREDIBLE-1550-T4"* ]]; then
    ok "CREDIBLE-1559 AC2: 'chump gap link-pr' refuses a second gap without --multi and prints existing link"
else
    fail "CREDIBLE-1559 AC2: expected non-zero + CREDIBLE-1550-T4 in output, got rc=$refuse_rc out=$refuse_out"
fi
if [[ -n "$FN" ]]; then
    (
        cd "$REPO"
        export CHUMP_STATE_DB="$DB4"
        info() { :; }
        # Re-scope PR from umbrella CREDIBLE-1550-T4 to slice CREDIBLE-1552-T4:
        GAP_IDS=("CREDIBLE-1552-T4")
        eval "$FN"
        _bm_link_pr "$STUB_PR"
    )
    old_cnt="$(count_rows "$DB4" CREDIBLE-1550-T4 "$STUB_PR")"
    new_cnt="$(count_rows "$DB4" CREDIBLE-1552-T4 "$STUB_PR")"
    if [[ "$old_cnt" == 0 && "$new_cnt" == 1 ]]; then
        ok "CREDIBLE-1559 AC3: re-scoping via bot-merge _bm_link_pr (--move) moves the link instead of adding a second row"
    else
        fail "CREDIBLE-1559 AC3: expected old_cnt=0 new_cnt=1 after re-scope, got old=$old_cnt new=$new_cnt"
    fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
