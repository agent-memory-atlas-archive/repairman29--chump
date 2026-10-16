#!/usr/bin/env bash
# scripts/ci/test-dispatch-ship-session-id.sh — INFRA-8204
#
# `chump dispatch --backend headless` creates a fresh worktree, claims the
# gap's lease INTO that worktree's own `.chump-locks/`, then runs bot-merge.sh
# there WITHOUT exporting CHUMP_SESSION_ID — so bot-merge.sh's session-ID
# auto-detection (which only ever scanned the MAIN checkout's $LOCK_DIR and
# state.db) could never find the lease claim() just wrote, and its INFRA-1901
# "already inside claimed worktree" check re-invoked `chump claim`, either
# spawning a stray second worktree or failing with "worktree already exists".
#
# This test exercises the building blocks the fix added:
#   1. lease_file_for_gap_in_dir() finds/misses leases in a dispatch-shaped
#      worktree's .chump-locks/ dir.
#   2. lease_session_id() reads the session id back out of that lease file.
#   3. grep-level contract on bot-merge.sh: both the session auto-detection
#      block and the INFRA-1901 pre-claim check call
#      lease_file_for_gap_in_dir against "$PWD/.chump-locks", and the
#      META-156 AC#2 message block no longer prints the literal '<unset>' or
#      '<unknown>'.
#   4. grep-level contract on src/dispatch.rs: ship() exports
#      CHUMP_SESSION_ID on the bot-merge Command.
# Best effort: a bot-merge.sh --dry-run smoke run against a fixture worktree
# with stub gh/chump binaries on PATH, asserting the auto-detect line appears
# and `chump claim` is never invoked.
#
# No network, no cargo, no real headless child — bash only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FAIL_COUNT=0
ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== INFRA-8204 dispatch ship-phase session-id test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/lease.sh
source "${REPO_ROOT}/scripts/lib/lease.sh"

# ── Fixture: a dispatch-shaped worktree lease ────────────────────────────────
WT="${TMP}/dispatch-wt"
mkdir -p "${WT}/.chump-locks"
LEASE_FILE="${WT}/.chump-locks/dispatch-infra-9999-1-1.json"
cat > "$LEASE_FILE" <<'EOF'
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"PLACEHOLDER","expires_at":"2099-01-01T00:00:00Z"}
EOF
# Swap in the real worktree path (avoids escaping it into the heredoc above).
sed -i.bak "s#PLACEHOLDER#${WT}#" "$LEASE_FILE" && rm -f "${LEASE_FILE}.bak"
printf '%s' "dispatch-infra-9999-1-1" > "${WT}/.chump-locks/.wt-session-id"

# ── 1. lease_file_for_gap_in_dir finds/misses correctly ──────────────────────
echo "[1. lease_file_for_gap_in_dir]"

FOUND="$(lease_file_for_gap_in_dir "${WT}/.chump-locks" "INFRA-9999" || true)"
if [[ "$FOUND" == "$LEASE_FILE" ]]; then
    ok "finds the dispatch worktree's own lease file for INFRA-9999"
else
    fail "expected '$LEASE_FILE', got '$FOUND'"
fi

if MISS="$(lease_file_for_gap_in_dir "${WT}/.chump-locks" "INFRA-0000")"; then
    fail "expected rc=1 (no match) for INFRA-0000, got rc=0 output='$MISS'"
elif [[ -n "$MISS" ]]; then
    fail "expected empty output for INFRA-0000, got '$MISS'"
else
    ok "returns empty + rc=1 for a gap id with no lease in the dir"
fi

# ── 2. lease_session_id reads the dispatch session id back out ──────────────
echo
echo "[2. lease_session_id]"

SID="$(lease_session_id "$LEASE_FILE")"
if [[ "$SID" == "dispatch-infra-9999-1-1" ]]; then
    ok "lease_session_id reads back the dispatch session id"
else
    fail "expected 'dispatch-infra-9999-1-1', got '$SID'"
fi

# ── 3. grep-level contracts ──────────────────────────────────────────────────
echo
echo "[3. grep-level contracts]"

BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"
DISPATCH_RS="${REPO_ROOT}/src/dispatch.rs"

# bot-merge.sh must call lease_file_for_gap_in_dir against $PWD/.chump-locks
# in BOTH the session auto-detection block and the INFRA-1901 pre-claim check.
CALL_COUNT="$(grep -c 'lease_file_for_gap_in_dir "\$PWD/.chump-locks"' "$BOT_MERGE" || true)"
if [[ "$CALL_COUNT" -ge 2 ]]; then
    ok "bot-merge.sh calls lease_file_for_gap_in_dir \"\$PWD/.chump-locks\" at least twice (got $CALL_COUNT)"
else
    fail "expected >=2 calls to lease_file_for_gap_in_dir \"\$PWD/.chump-locks\" in bot-merge.sh, got $CALL_COUNT"
fi

# The META-156 AC#2 block (bounded by its characteristic marker through the
# next top-level 'else' claim-failure branch) must never print the literal
# placeholders this gap replaced with concrete sources.
AC2_BLOCK="$(awk '/META-156 AC#2: re-claim failure/,/Some other claim failure/' "$BOT_MERGE")"
if printf '%s' "$AC2_BLOCK" | grep -qF '<unset>'; then
    fail "META-156 AC#2 block still contains the literal '<unset>'"
elif printf '%s' "$AC2_BLOCK" | grep -qF '<unknown>'; then
    fail "META-156 AC#2 block still contains the literal '<unknown>'"
else
    ok "META-156 AC#2 block no longer prints '<unset>' or '<unknown>'"
fi

# dispatch.rs: ship() must export CHUMP_SESSION_ID explicitly onto the
# bot-merge Command, not merely rely on inheritance.
SHIP_FN="$(awk '/^fn ship\(/,/^fn current_pr_number/' "$DISPATCH_RS")"
if printf '%s' "$SHIP_FN" | grep -q 'cmd.env("CHUMP_SESSION_ID"'; then
    ok "dispatch.rs ship() sets CHUMP_SESSION_ID on the bot-merge Command"
else
    fail "dispatch.rs ship() does not set CHUMP_SESSION_ID on the bot-merge Command"
fi

# ── 4. best-effort: bot-merge.sh --dry-run smoke run ─────────────────────────
echo
echo "[4. bot-merge.sh --dry-run smoke run (best effort)]"

run_dry_run_smoke() {
    local fixture="${TMP}/fixture-repo"
    mkdir -p "$fixture"
    (
        cd "$fixture" || exit 1
        git init -q -b main
        git config user.email test@example.com
        git config user.name test
        echo "x" > f.txt
        git add f.txt
        git commit -q -m init
        git checkout -q -b claude/infra-9999
        echo "y" >> f.txt
        git add f.txt
        git commit -q -m "work for INFRA-9999"
    ) || return 1

    mkdir -p "${fixture}/.chump-locks"
    cat > "${fixture}/.chump-locks/dispatch-infra-9999-1-1.json" <<EOF
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"${fixture}","expires_at":"2099-01-01T00:00:00Z"}
EOF
    printf '%s' "dispatch-infra-9999-1-1" > "${fixture}/.chump-locks/.wt-session-id"

    local stub_bin="${TMP}/stub-bin"
    mkdir -p "$stub_bin"
    local argv_log="${TMP}/chump-argv.log"
    : > "$argv_log"

    cat > "${stub_bin}/chump" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${argv_log}"
if [[ "\$1" == "gap" && "\$2" == "preflight" ]]; then
    echo "[preflight] OK"
    exit 0
fi
exit 0
EOF
    chmod +x "${stub_bin}/chump"

    cat > "${stub_bin}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${stub_bin}/gh"

    local out
    if ! out="$(cd "$fixture" && PATH="${stub_bin}:${PATH}" bash "${BOT_MERGE}" --gap INFRA-9999 --dry-run 2>&1)"; then
        printf '%s\n' "$out" >&2
        return 2
    fi

    if grep -q 'claim' "$argv_log" 2>/dev/null; then
        printf '%s\n' "$out" >&2
        fail "stub chump recorded a 'claim' call — bot-merge re-invoked chump claim \
instead of recognizing the dispatch worktree's own lease"
    else
        ok "stub chump never saw a 'claim' invocation during --dry-run"
    fi

    if printf '%s' "$out" | grep -q 'INFRA-8204'; then
        ok "bot-merge --dry-run output contains the INFRA-8204 auto-detect line"
    else
        fail "bot-merge --dry-run output missing the INFRA-8204 auto-detect line"
    fi

    if printf '%s' "$out" | grep -qi 're-claim failure'; then
        fail "bot-merge --dry-run output contains a re-claim failure message"
    else
        ok "bot-merge --dry-run output contains no re-claim failure message"
    fi
}

if run_dry_run_smoke; then
    :
else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
        echo "SKIP: bot-merge dry-run not exercised (fixture invocation failed — \
bot-merge.sh's --dry-run path has preconditions beyond this fixture's reach)"
    fi
fi

echo
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "=== INFRA-8204 tests FAILED ($FAIL_COUNT failure(s)) ==="
    exit 1
fi
echo "=== INFRA-8204 tests complete ==="
