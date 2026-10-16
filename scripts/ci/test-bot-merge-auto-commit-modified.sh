#!/usr/bin/env bash
# test-bot-merge-auto-commit-modified.sh — INFRA-472
#
# Verifies bot-merge.sh's INFRA-472 block auto-stages + auto-commits
# modified files before rebase, eliminating the "cannot rebase: You
# have unstaged changes" friction class.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"

[[ -f "$SCRIPT" ]] || { echo "FATAL: bot-merge.sh missing"; exit 2; }

echo "=== INFRA-472 bot-merge auto-commit modified files test ==="
echo

# --- Test 1: code presence ---
if grep -q '0b. Modified-files handler (INFRA-472)' "$SCRIPT"; then
    ok "INFRA-472 modified-files handler block present"
else
    fail "INFRA-472 handler block missing"
fi

if grep -qE 'CHUMP_BOT_MERGE_AUTO_COMMIT_M' "$SCRIPT"; then
    ok "CHUMP_BOT_MERGE_AUTO_COMMIT_M bypass env documented"
else
    fail "bypass env CHUMP_BOT_MERGE_AUTO_COMMIT_M not present"
fi

# --- Test 2: simulation — extract the 0a + 0b blocks and run them in a
# fake repo with modified files; verify the staging+commit happens. ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE="$TMPDIR_BASE/repo"
mkdir -p "$FAKE/src" "$FAKE/scripts"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
echo "fn main() {}" > "$FAKE/src/main.rs"
echo "#!/usr/bin/env bash" > "$FAKE/scripts/foo.sh"
git -C "$FAKE" add . >/dev/null
git -C "$FAKE" commit -q -m "seed"

# Modify a tracked file (this is the M case)
echo "// modified content" >> "$FAKE/src/main.rs"
# Add an untracked file (the INFRA-404 case)
echo "echo new" > "$FAKE/scripts/new.sh"

# Extract the 0a + 0b blocks. They start at "# ── 0a." and end before "# ── 0."
BLOCKS="$TMPDIR_BASE/blocks.sh"
awk '/^# ── 0a\. /,/^# ── 0\. /' "$SCRIPT" \
    | sed '$d' > "$BLOCKS"   # drop the trailing "# ── 0." marker line

# Wrap with the color helpers + minimal env so it can run standalone.
HARNESS="$TMPDIR_BASE/harness.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo 'green()  { printf "[green] %s\n" "$*"; }'
    echo 'red()    { printf "[red] %s\n" "$*"; }'
    echo 'yellow() { printf "[yellow] %s\n" "$*"; }'
    echo 'info()   { printf "[info] %s\n" "$*"; }'
    # INFRA-8202: the 0b block now calls _bm_substep / _bm_resolve_lease_file /
    # _bm_stray_staged_paths / _bm_auto_commit_with_retry — source the real
    # implementations so this harness exercises the actual retry/refusal logic.
    printf 'source %q\n' "$REPO_ROOT/scripts/coord/lib/bot-merge-autocommit.sh"
    cat "$BLOCKS"
} > "$HARNESS"

# Run in the fake repo
(
    cd "$FAKE"
    bash "$HARNESS" >"$TMPDIR_BASE/harness.out" 2>&1
)

# Verify the modified file got staged + committed
_log_count=$(git -C "$FAKE" log --oneline 2>/dev/null | grep -c 'auto: bot-merge pre-rebase' || true)
if [[ "$_log_count" -ge 1 ]]; then
    ok "auto-commit landed for modified + untracked files"
else
    fail "auto-commit did NOT land. Harness output:"
    sed 's/^/    /' "$TMPDIR_BASE/harness.out"
    git -C "$FAKE" log --oneline | sed 's/^/    LOG: /'
fi

# Verify the working tree is now clean (rebase would proceed)
if [[ -z "$(git -C "$FAKE" status --porcelain)" ]]; then
    ok "working tree clean after auto-commit (rebase-safe)"
else
    fail "working tree NOT clean: $(git -C "$FAKE" status --porcelain)"
fi

# --- Test 3: bypass env honored ---
# Reset the fake repo
git -C "$FAKE" reset --hard HEAD~1 >/dev/null 2>&1 || true
echo "// modification 2" >> "$FAKE/src/main.rs"

(
    cd "$FAKE"
    CHUMP_BOT_MERGE_AUTO_COMMIT_M=0 bash "$HARNESS" >"$TMPDIR_BASE/harness2.out" 2>&1 || true
)

# With bypass, the modified file should NOT be committed
if git -C "$FAKE" status --porcelain | grep -qE '^\sM '; then
    ok "CHUMP_BOT_MERGE_AUTO_COMMIT_M=0 bypass leaves modified files alone"
else
    fail "bypass did not work: $(git -C "$FAKE" status --porcelain)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
