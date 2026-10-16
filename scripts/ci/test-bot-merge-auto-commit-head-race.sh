#!/usr/bin/env bash
# scripts/ci/test-bot-merge-auto-commit-head-race.sh — INFRA-8202
#
# Verifies the three bot-merge.sh INFRA-472 auto-commit fixes:
#   AC1 — a "cannot lock ref HEAD" race (another organ rebasing the branch
#         mid-commit-hook-run) is retried once with the same staged-path
#         list instead of stranding the work.
#   AC2 — the init phase emits named sub-steps (so the heartbeat's bare
#         "alive — step=init" becomes diagnosable) and the heartbeat has a
#         120s stall-warning contract.
#   AC3 — a staged path outside the dispatch lease (e.g. a stray deleted
#         docs/gaps/*.yaml) makes the auto-commit refuse instead of landing
#         collateral damage in the gap's own commit.
#
# Bash only. No network. Sources the extracted lib directly rather than
# invoking the full bot-merge.sh (which needs gh/network).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/coord/lib/bot-merge-autocommit.sh"
BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-8202 bot-merge auto-commit HEAD-race / stray-path / sub-step test ==="
echo

[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 2; }
[[ -f "$BOT_MERGE" ]] || { echo "FATAL: $BOT_MERGE missing"; exit 2; }

# shellcheck source=../coord/lib/bot-merge-autocommit.sh
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── (1) AC1: HEAD-lock race is retried once and succeeds ───────────────────
echo "[1. AC1 — HEAD-lock race retry]"

FAKE="${TMP}/repo1"
mkdir -p "$FAKE"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
echo "one" > "$FAKE/a.txt"
git -C "$FAKE" add a.txt >/dev/null
git -C "$FAKE" commit -q -m seed

# Fixture: a pre-commit hook that holds a competing HEAD.lock on its FIRST
# invocation (simulating a sibling organ — pr-auto-rebase / the merge-
# serializer — moving HEAD mid-hook-run), so git's own ref-update fails
# with "cannot lock ref HEAD" exactly like the real race. On the SECOND
# invocation (the retry) it releases the lock, simulating the sibling
# organ having finished by then.
mkdir -p "$FAKE/.git/hooks"
MARKER="${TMP}/hook-fired-once"
cat > "$FAKE/.git/hooks/pre-commit" <<HOOK
#!/usr/bin/env bash
set -e
if [[ ! -f "$MARKER" ]]; then
    touch "$MARKER"
    # Simulate the sibling organ: create a competing HEAD.lock so THIS
    # commit's own ref-update fails with "cannot lock ref HEAD".
    : > "\$(git rev-parse --git-dir)/HEAD.lock"
else
    # Second invocation (the retry): the sibling organ has finished and
    # released its lock by now — remove it before git's own ref-update runs.
    rm -f "\$(git rev-parse --git-dir)/HEAD.lock"
fi
exit 0
HOOK
chmod +x "$FAKE/.git/hooks/pre-commit"

echo "two" >> "$FAKE/a.txt"
(cd "$FAKE" && git add a.txt)

HEAD_BEFORE="$(git -C "$FAKE" rev-parse HEAD)"
(
    cd "$FAKE"
    _bm_auto_commit_with_retry "test commit (INFRA-8202)" "a.txt"
)
RC=$?

# Clean up a lock file that might still be sitting there if something went
# wrong, so later checks don't false-positive on a wedged repo.
rm -f "$FAKE/.git/HEAD.lock" 2>/dev/null || true

if [[ "$RC" -eq 0 ]]; then
    ok "_bm_auto_commit_with_retry returned success after the HEAD-lock race"
else
    fail "_bm_auto_commit_with_retry returned rc=$RC (expected 0)"
fi

HEAD_AFTER="$(git -C "$FAKE" rev-parse HEAD)"
if [[ "$HEAD_AFTER" != "$HEAD_BEFORE" ]]; then
    ok "HEAD advanced past the pre-race commit (retry committed)"
else
    fail "HEAD did not move — commit never landed"
fi

if git -C "$FAKE" show HEAD:a.txt 2>/dev/null | grep -q '^two$'; then
    ok "resulting HEAD contains the staged change"
else
    fail "resulting HEAD is missing the staged change"
fi

if [[ -f "$MARKER" ]]; then
    ok "the hook fired at least once (first attempt hit the race)"
else
    fail "hook marker missing — fixture didn't exercise the race path"
fi

# ── (2) AC3: stray staged path outside the lease is refused ────────────────
echo
echo "[2. AC3 — stray-path refusal]"

FAKE2="${TMP}/repo2"
mkdir -p "$FAKE2/docs/gaps"
git -C "$FAKE2" init -q -b main
git -C "$FAKE2" config user.email t@t.com
git -C "$FAKE2" config user.name t
echo "fn main() {}" > "$FAKE2/src_a.rs"
echo "gap: X" > "$FAKE2/docs/gaps/X.yaml"
mkdir -p "$FAKE2/src"
mv "$FAKE2/src_a.rs" "$FAKE2/src/a.rs"
git -C "$FAKE2" add . >/dev/null
git -C "$FAKE2" commit -q -m seed

LEASE_FILE="${TMP}/lease.json"
cat > "$LEASE_FILE" <<'JSON'
{"session_id":"test-session","gap_id":"INFRA-8202","paths":["src/a.rs"]}
JSON

echo "// edit" >> "$FAKE2/src/a.rs"
git -C "$FAKE2" rm -q "docs/gaps/X.yaml"
(cd "$FAKE2" && git add src/a.rs)

STAGED="$(cd "$FAKE2" && git diff --cached --name-only)"
STRAY="$(cd "$FAKE2" && _bm_stray_staged_paths "$LEASE_FILE" "$STAGED")"

if printf '%s\n' "$STRAY" | grep -q 'docs/gaps/X.yaml'; then
    ok "stray-path check names the deleted docs/gaps/X.yaml"
else
    fail "stray-path check did not flag docs/gaps/X.yaml (got: $STRAY)"
fi

# Now stage ONLY the in-lease path and confirm no refusal.
FAKE3="${TMP}/repo3"
mkdir -p "$FAKE3/src"
git -C "$FAKE3" init -q -b main
git -C "$FAKE3" config user.email t@t.com
git -C "$FAKE3" config user.name t
echo "fn main() {}" > "$FAKE3/src/a.rs"
git -C "$FAKE3" add . >/dev/null
git -C "$FAKE3" commit -q -m seed
echo "// edit" >> "$FAKE3/src/a.rs"
(cd "$FAKE3" && git add src/a.rs)
STAGED3="$(cd "$FAKE3" && git diff --cached --name-only)"
STRAY3="$(cd "$FAKE3" && _bm_stray_staged_paths "$LEASE_FILE" "$STAGED3")"
if [[ -z "$STRAY3" ]]; then
    ok "in-lease-only staged path produces no stray-path refusal"
else
    fail "unexpected stray-path flag for in-lease-only staging: $STRAY3"
fi

# ── (3) AC2: sub-step contract ──────────────────────────────────────────────
echo
echo "[3. AC2 — sub-step contract]"

for substep in shadow-plan untracked-auto-add auto-commit; do
    if grep -q "_bm_substep \"${substep}\"" "$BOT_MERGE"; then
        ok "bot-merge.sh labels the '${substep}' sub-step"
    else
        fail "bot-merge.sh is missing a _bm_substep call for '${substep}'"
    fi
done

if grep -q "no sub-step progress for" "$BOT_MERGE"; then
    ok "heartbeat printer references the 120s stall-warning message"
else
    fail "heartbeat printer is missing the 120s stall-warning message"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
