#!/usr/bin/env bash
# scripts/ci/test-pre-push-preflight-hook.sh — INFRA-1671 regression test.
#
# Asserts the Guard 0a (chump preflight) block in scripts/git-hooks/pre-push:
#   1. invokes `chump preflight` when the binary is available and push has Rust/scripts diff
#   2. skips silently when `chump` binary is unavailable
#   3. skips when push has no Rust/scripts content
#   4. INFRA-2422: CHUMP_PREFLIGHT_SKIP is deleted — no bypass env accepted
#
# Structural checks against the hook file itself — does NOT actually
# install the hook in a sandbox repo (that's brittle and slow for CI).
# The structural assertion is enough: if Guard 0a is wired correctly in
# the hook source, it will fire correctly when installed.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-1671 pre-push preflight guard ==="

[[ -f "$HOOK" ]] || { echo "[FAIL] $HOOK not found"; exit 1; }

# 1. Guard 0a block exists
if grep -q "^# Guard 0a: chump preflight (INFRA-1671)" "$HOOK"; then
    ok "Guard 0a block header present"
else
    fail "Guard 0a block header missing — was the guard inserted?"
fi

# 2. Invokes the binary
if grep -qE 'chump preflight' "$HOOK"; then
    ok "hook calls 'chump preflight'"
else
    fail "hook does not call 'chump preflight'"
fi

# 3. INFRA-2422: CHUMP_PREFLIGHT_SKIP must NOT appear as a bypass in the hook
if grep -q 'CHUMP_PREFLIGHT_SKIP:-0' "$HOOK"; then
    fail "CHUMP_PREFLIGHT_SKIP bypass still present — should be deleted (INFRA-2422)"
else
    ok "CHUMP_PREFLIGHT_SKIP bypass absent (deleted per INFRA-2422)"
fi

# 4. Has the 'command -v chump' fallback (binary not installed)
if grep -q 'command -v chump' "$HOOK"; then
    ok "binary-availability fallback present"
else
    fail "binary-availability fallback missing — would break early bootstrap"
fi

# 4b. Has the 'chump preflight --help' capability check
# (old binaries without the preflight subcommand must not block pushes)
if grep -q 'chump preflight --help' "$HOOK"; then
    ok "preflight-capability check present (old binaries skip gracefully)"
else
    fail "preflight-capability check missing — old binaries would block all pushes"
fi

# 5. Has the push-delta gating (only run on Rust/scripts pushes)
if grep -qE 'preflight_has_targets' "$HOOK"; then
    ok "push-delta gating present (skips doc-only pushes)"
else
    fail "push-delta gating missing — would run preflight on doc-only pushes"
fi

# 6. Exits non-zero on failure (BLOCKED keyword + exit 1)
guard_block=$(awk '/^# Guard 0a:/,/^# Guard 0:/' "$HOOK")
if echo "$guard_block" | grep -q 'BLOCKED: chump preflight failed'; then
    ok "blocks push with diagnostic on preflight failure"
else
    fail "missing 'BLOCKED' diagnostic on preflight failure"
fi
if echo "$guard_block" | grep -q 'exit 1'; then
    ok "exits 1 on preflight failure"
else
    fail "missing exit 1 on preflight failure"
fi

# 7. INFRA-2422: failure message references auto-skip (not deleted bypass)
if echo "$guard_block" | grep -q "INFRA-2422"; then
    ok "failure message references INFRA-2422 auto-skip (no bypass env)"
else
    fail "failure message should reference INFRA-2422 auto-skip"
fi

# 8. Order: Guard 0a appears BEFORE Guard 0 (cargo fmt) in the file
line_0a=$(grep -n '^# Guard 0a:' "$HOOK" | head -1 | cut -d: -f1)
line_0=$(grep -n '^# Guard 0: cargo fmt' "$HOOK" | head -1 | cut -d: -f1)
if [[ -n "$line_0a" && -n "$line_0" ]] && (( line_0a < line_0 )); then
    ok "Guard 0a runs BEFORE Guard 0 (cargo fmt) — line $line_0a < $line_0"
else
    fail "Guard 0a should run before Guard 0 (cargo fmt); 0a=$line_0a, 0=$line_0"
fi

# 9. INFRA-3521: the FULL preflight re-run is skipped for bot-merge-initiated
#    pushes (bot-merge already gated + delegates the cargo suite to CI;
#    re-running the full preflight here blew the 300s push budget → SIGTERM →
#    orphaned worktree → META-156).
if grep -q 'CHUMP_BOT_MERGE_IN_PROGRESS' "$HOOK" && grep -q 'INFRA-3521' "$HOOK"; then
    ok "INFRA-3521: bot-merge pushes skip the redundant FULL preflight re-run"
else
    fail "INFRA-3521 bot-merge preflight-narrowing missing — double-preflight timeout wedge unfixed"
fi

# 9b. RESILIENT-1622: INFRA-3521 is NARROWED, not a full skip — under
#     CHUMP_BOT_MERGE_IN_PROGRESS the hook runs the STRUCTURAL subset
#     (`chump preflight --structural`, no cargo build) instead of skipping
#     preflight entirely, so census / ci-parity / env-var / event-registry /
#     path-filter / no-new-bypass / raw-gh are caught before push (#5582, #5585).
guard_0a_block=$(awk '/^# Guard 0a:/,/^# Guard 0: cargo fmt/' "$HOOK")
if grep -q 'RESILIENT-1622' <<<"$guard_0a_block" \
    && grep -q 'chump preflight \$_pf_structural_arg' <<<"$guard_0a_block" \
    && grep -q 'prepush_preflight_skipped_botmerge' <<<"$guard_0a_block"; then
    ok "RESILIENT-1622: bot-merge push runs the structural subset (narrowed) + emits an audit event"
else
    fail "RESILIENT-1622: bot-merge branch should run 'chump preflight --structural' (INFRA-3521 narrowed), not skip entirely"
fi

# 9c. RESILIENT-1622 rollout safety: the structural subset is a NEW flag, and
#     `chump preflight` ignores unknown flags, so a STALE binary handed
#     --structural would silently run the FULL (cargo-build) preflight here and
#     blow bot-merge's 300s push budget (the META-156 regression INFRA-3521
#     fixed). The narrowing must therefore be CAPABILITY-GATED: run --structural
#     only when `chump preflight --help` advertises it; otherwise fall back to
#     the old skip. Assert the capability check wraps the structural branch,
#     and that it captures --help then tests the string: a `--help | grep -q`
#     pipeline under pipefail can SIGPIPE the upstream and read as false,
#     silently skipping the gate (fleet CI class 31).
botmerge_narrow_block=$(awk '/CHUMP_BOT_MERGE_IN_PROGRESS.*== "1"/,/^    fi/' <<<"$guard_0a_block")
if grep -q '_pf_help="$(chump preflight --help' <<<"$botmerge_narrow_block" \
    && grep -qF '[[ "$_pf_help" == *--structural* ]]' <<<"$botmerge_narrow_block"; then
    ok "RESILIENT-1622: structural narrowing is capability-gated (stale binary falls back to the old skip)"
else
    fail "RESILIENT-1622: structural narrowing must be guarded by a captured 'chump preflight --help' + [[ == *--structural* ]] capability check"
fi
if grep -qE 'preflight --help[^|]*\| *grep -q' <<<"$botmerge_narrow_block"; then
    fail "RESILIENT-1622: capability check still pipes 'chump preflight --help' into grep -q (pipefail class 31)"
else
    ok "RESILIENT-1622: capability check has no 'preflight --help | grep -q' pipeline"
fi

# 10. INFRA-3524: clippy re-run is skipped for bot-merge-initiated pushes
#     (bot-merge already ran `cargo clippy --workspace --fix`; re-running the
#     clippy gate here rebuilds ring's C-assembly cold and blew the 300s push
#     budget → SIGTERM → orphaned worktree → META-156; timed out CREDIBLE-178
#     twice). Extends INFRA-3521's preflight-skip to the clippy gate.
if grep -q 'CHUMP_BOT_MERGE_IN_PROGRESS' "$HOOK" && grep -q 'INFRA-3524' "$HOOK"; then
    ok "INFRA-3524: bot-merge pushes skip the redundant clippy re-run"
else
    fail "INFRA-3524 bot-merge clippy-skip missing — redundant clippy blows bot-merge push budget"
fi

# 10b. The clippy skip leaves an audit trail
if grep -q 'prepush_clippy_skipped_botmerge' "$HOOK"; then
    ok "INFRA-3524: clippy skip emits a prepush_clippy_skipped_botmerge audit event"
else
    fail "INFRA-3524: clippy skip should emit prepush_clippy_skipped_botmerge to ambient"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
