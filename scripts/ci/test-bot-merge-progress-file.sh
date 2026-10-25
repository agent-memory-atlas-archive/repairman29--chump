#!/usr/bin/env bash
# scripts/ci/test-bot-merge-progress-file.sh
#
# INFRA-2673: ensure scripts/coord/bot-merge.sh --progress-file PATH appends
# line-oriented phase markers so background callers (run_in_background=true)
# can tail -f the file to see incremental progress.
#
# Without this, today's bot-merge invocations stayed at 0 bytes of stdout
# output for 10+ minutes while internal work proceeded silently — operator
# could not distinguish "hung" from "slow but working".
#
# This test only validates the static shape (flag parsed, helper writes
# appendable lines, format `phase=<name> ts=<iso8601>`). A live ship is the
# integration test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [[ ! -f "$BM" ]]; then
    fail "bot-merge.sh not found at $BM"
    exit 1
fi

# ── Assert 1: --progress-file flag is in arg parser ──────────────────────────
if grep -qE -- '--progress-file' "$BM"; then
    ok "--progress-file flag is recognised in arg parser"
else
    fail "--progress-file flag missing from bot-merge.sh arg parser"
fi

# ── Assert 2: PROGRESS_FILE_OVERRIDE variable exists ─────────────────────────
if grep -qE 'PROGRESS_FILE_OVERRIDE' "$BM"; then
    ok "PROGRESS_FILE_OVERRIDE variable defined"
else
    fail "PROGRESS_FILE_OVERRIDE variable not defined"
fi

# ── Assert 3: line-oriented phase marker is appended (>>) not overwritten ────
# The helper should append to the override path (so tail -f works).
if grep -qE '"\$PROGRESS_FILE_OVERRIDE"' "$BM" && \
   grep -qE 'phase=.*ts=.*gap=' "$BM"; then
    ok "phase markers written as 'phase=<name> ts=<iso> gap=...' format"
else
    fail "phase marker format missing or not in 'phase= ts= gap=' form"
fi

if grep -qE '>>\s*"\$PROGRESS_FILE_OVERRIDE"' "$BM"; then
    ok "progress-file uses append (>>) — tail -f friendly"
else
    fail "progress-file is NOT appended (>>) — overwriting breaks tail -f"
fi

# ── Assert 4: backwards-compat (no --progress-file → existing behaviour) ─────
# The override path must be guarded by `[[ -n "${PROGRESS_FILE_OVERRIDE:-}" ]]`
# so callers who don't pass --progress-file get the existing JSON-ledger-only
# behaviour.
if grep -qE '\[\[ -n "\$\{PROGRESS_FILE_OVERRIDE:-\}" \]\]' "$BM"; then
    ok "override path is conditional on PROGRESS_FILE_OVERRIDE being set"
else
    fail "override path NOT guarded — non-progress-file callers may regress"
fi

# ── Assert 5: dry-run smoke: --progress-file accepted without erroring ───────
TMP_LOG="$(mktemp -t bot-merge-progress-test.XXXXXX)"
# Invoke with --dry-run to short-circuit before any push/lease work, and
# --gap none to avoid needing a real gap registry.
# CREDIBLE-1584: run bot-merge.sh inside an isolated temp git repo (1 commit ahead of origin/main).
TMP_BM_REPO="$(mktemp -d)"
mkdir -p "$TMP_BM_REPO/.chump-locks"
git -C "$TMP_BM_REPO" init -q -b main
git -C "$TMP_BM_REPO" config user.email "t@chump.local"
git -C "$TMP_BM_REPO" config user.name "t"
git -C "$TMP_BM_REPO" commit -q --allow-empty -m "base" --no-verify
git -C "$TMP_BM_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$TMP_BM_REPO" checkout -q -b claude/progress-probe
git -C "$TMP_BM_REPO" commit -q --allow-empty -m "INFRA-2673: progress probe" --no-verify
if (cd "$TMP_BM_REPO" && CHUMP_REPO_ROOT="$TMP_BM_REPO" bash "$BM" --gap none --dry-run --progress-file "$TMP_LOG" >/dev/null 2>&1); then
    ok "bot-merge.sh --gap none --dry-run --progress-file accepted"
else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
        # exit 2 is the "no GAP_IDS" guard from INFRA-237; it fires even with
        # --gap none after the filter empties the list. That's fine — the
        # flag was at least parsed without "unknown flag" exit.
        ok "bot-merge.sh --progress-file flag accepted (dry-run exit=2 from no-gap guard is expected)"
    else
        fail "bot-merge.sh --progress-file dry-run failed with exit $rc"
    fi
fi
rm -rf "$TMP_LOG" "$TMP_BM_REPO" 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "── INFRA-2673 bot-merge progress-file summary ──"
echo "  PASS: $PASS  FAIL: $FAIL"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
