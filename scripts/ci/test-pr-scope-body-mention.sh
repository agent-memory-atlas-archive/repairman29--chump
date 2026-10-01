#!/usr/bin/env bash
# test-pr-scope-body-mention.sh — CREDIBLE-1483: Rule B body-mention bypass
# must work against an explicit PR number (the CI detached-HEAD-checkout
# shape), not just a bare `gh pr view` that only works locally.
#
# A fake `gh` on PATH simulates the real CI failure mode: the bare call
# (no PR number) fails exactly like it does in the Actions pull_request
# checkout, while the explicit-number call succeeds. Before CREDIBLE-1483,
# check-pr-scope.sh only ever issued the bare call, so this test fails
# without the fix (the deleted file gets flagged as a silent revert even
# though the PR body names it).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-pr-scope.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-pr-scope-body.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fake gh: bare call fails (detached-HEAD CI shape); explicit numbered
#    call against the right repo succeeds and returns a body mentioning
#    the deleted file. ──────────────────────────────────────────────────
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
# Mimic: gh pr view [<number>] [--repo X] --json body -q .body
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    shift 2
    num=""
    if [[ "$1" != --* ]]; then
        num="$1"
        shift
    fi
    if [[ -n "$num" ]]; then
        # Explicit PR number — succeeds (the fixed CI path).
        echo "Deletes file.txt — see the 72h-old add commit, this was intentional."
        exit 0
    fi
    # Bare call with no PR number — fails, exactly like gh in a detached-HEAD
    # Actions checkout where it cannot infer the PR.
    exit 1
fi
exit 1
GHEOF
chmod +x "$FAKE_BIN/gh"

# jq must still be the real one for GITHUB_EVENT_PATH/event-number lookups.
REAL_JQ="$(command -v jq || true)"
if [[ -n "$REAL_JQ" ]]; then
    ln -s "$REAL_JQ" "$FAKE_BIN/jq"
fi

# ── Repo fixture: origin remote + a file deleted on a feature branch,
#    where the file was last touched on origin/main well within the
#    72h silent-revert cutoff. ───────────────────────────────────────
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"

REPO="$TMP/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" config user.email "test@test.invalid"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config commit.gpgsign false

printf 'content\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "feat: add file.txt"
git -C "$REPO" push -q origin HEAD:main

git -C "$REPO" checkout -q -b feature
rm "$REPO/file.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: remove file.txt per body note"

run_guard() {
    (
        cd "$REPO" \
        && PATH="$FAKE_BIN:$PATH" \
           GITHUB_BASE_REF=main \
           PR_NUMBER=42 \
           GITHUB_REPOSITORY="test/repo" \
           bash "$GUARD" --warn-only 2>&1
    ) || true
}

out="$(run_guard)"

if echo "$out" | grep -q "Rule B (silent revert)"; then
    fail "Rule B flagged file.txt as a silent revert even though PR_NUMBER=42's body mentions it: $out"
fi
echo "$out" | grep -q "Rule B: no silent reverts" \
    || fail "Expected Rule B to pass via the explicit-PR-number body-mention path: $out"
pass "Rule B: explicit-PR-number body-mention bypass works"

echo ""
echo "All CREDIBLE-1483 Rule B body-mention checks passed."
