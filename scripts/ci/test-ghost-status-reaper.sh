#!/usr/bin/env bash
# test-ghost-status-reaper.sh — INFRA-674 ghost-status reaper extension
#
# Verifies that stale-pr-reaper.sh, when run against a merged PR whose
# cited gap is still status=open in state.db, calls `chump gap ship`
# and emits kind=ghost_status_closed to ambient.jsonl.
#
# Fixtures:
#   PR #9901 (merged, title "INFRA-664: fix foo") — gap INFRA-664 is open → must be closed
#   PR #9902 (merged, title "INFRA-665: fix bar") — gap INFRA-665 is done  → must be skipped
#
# Stubs out `gh`, `chump`, and git; never touches real state.db or GitHub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not found or not executable: $REAPER"; exit 1; }

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/shipped" "$TMPDIR_TEST/.chump-locks" "$TMPDIR_TEST/.chump"
AMBIENT="$TMPDIR_TEST/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

# ---------- stub: gh ----------------------------------------------------------
cat > "$TMPDIR_TEST/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh shim for test-ghost-status-reaper.sh
case "$*" in
  *"pr list"*"--state merged"*)
    # Return two merged PRs from last 24h
    printf '%s\t%s\t%s\n' "9901" "INFRA-664: fix foo" ""
    printf '%s\t%s\t%s\n' "9902" "INFRA-665: fix bar" ""
    ;;
  *"pr list"*"--state open"*|*"pr list"*)
    # No open PRs (avoid stale-PR logic running)
    echo ""
    ;;
  *"pr diff"*)
    echo ""
    ;;
  *)
    echo "" ;;
esac
exit 0
STUB
chmod +x "$TMPDIR_TEST/bin/gh"

# ---------- stub: chump -------------------------------------------------------
cat > "$TMPDIR_TEST/bin/chump" <<STUB
#!/usr/bin/env bash
# chump shim: gaps-for-pr resolves the gap from the typed gap_prs FK
# (CREDIBLE-1551 — the reaper no longer parses the gap from the PR title);
# gap show returns status for known gaps; gap ship records the call.
TMPDIR_TEST="$TMPDIR_TEST"
case "\$*" in
  *"gap gaps-for-pr 9901"*)
    echo "INFRA-664"
    ;;
  *"gap gaps-for-pr 9902"*)
    echo "INFRA-665"
    ;;
  *"gap show INFRA-664"*)
    echo "- id: INFRA-664"
    echo "  status: open"
    ;;
  *"gap show INFRA-665"*)
    echo "- id: INFRA-665"
    echo "  status: done"
    ;;
  *"gap ship INFRA-664"*"--closed-pr"*"9901"*)
    touch "\$TMPDIR_TEST/shipped/INFRA-664"
    ;;
  *"gap ship INFRA-665"*)
    touch "\$TMPDIR_TEST/shipped/INFRA-665"
    ;;
  *)
    ;;
esac
exit 0
STUB
chmod +x "$TMPDIR_TEST/bin/chump"

# ---------- stub: git ---------------------------------------------------------
cat > "$TMPDIR_TEST/bin/git" <<STUB
#!/usr/bin/env bash
# git shim — reaper needs fetch + rev-parse + rev-list
case "\$*" in
  *"rev-parse --show-toplevel"*)
    echo "$TMPDIR_TEST"
    ;;
  *"fetch"*)
    exit 0
    ;;
  *"pr list"*)
    echo ""
    ;;
  *"rev-list --count"*)
    echo "0"
    ;;
  *"show "*":docs/gaps/"*)
    exit 1
    ;;
  *"show "*":docs/gaps.yaml"*)
    exit 1
    ;;
  *"log"*)
    echo ""
    ;;
  *)
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$TMPDIR_TEST/bin/git"

# ---------- stub: reaper-instrumentation.sh -----------------------------------
mkdir -p "$TMPDIR_TEST/scripts/lib"
cat > "$TMPDIR_TEST/scripts/lib/reaper-instrumentation.sh" <<STUB
#!/usr/bin/env bash
REAPER_LOCK_DIR="$TMPDIR_TEST/.chump-locks"
REAPER_NAME="pr"
REAPER_REPO_ROOT="$TMPDIR_TEST"
export REAPER_LOCK_DIR REAPER_NAME REAPER_REPO_ROOT
reaper_setup()          { :; }
reaper_check_disk_headroom() { :; }
reaper_rotate_log()     { :; }
reaper_finish()         { :; }
STUB

# ---------- run reaper with stubs in PATH ------------------------------------
# Patch the reaper's source line to use our stub instrumentation, then run it.
STUB_LIB="$TMPDIR_TEST/scripts/lib/reaper-instrumentation.sh"
PATCHED="$TMPDIR_TEST/reaper-patched.sh"

# Replace the `source ... reaper-instrumentation.sh` line with stub path.
perl -pe "s|^source\b.*reaper-instrumentation\.sh.*|source '$STUB_LIB'|" \
    "$REAPER" > "$PATCHED"
chmod +x "$PATCHED"

# CREDIBLE-1553: default invocation (without --close-merged-gaps) must NOT close merged gaps
OUT_DEFAULT=$(PATH="$TMPDIR_TEST/bin:$PATH" \
    REAPER_LOCK_DIR="$TMPDIR_TEST/.chump-locks" \
    REAPER_REPO_ROOT="$TMPDIR_TEST" \
    bash "$PATCHED" 2>&1 || true)
if [[ -f "$TMPDIR_TEST/shipped/INFRA-664" ]]; then
    echo "FAIL: INFRA-664 was shipped without --close-merged-gaps (CREDIBLE-1553 requires opt-in)"
    exit 1
else
    echo "PASS: default invocation did NOT close merged gaps without --close-merged-gaps"
fi

OUT=$(PATH="$TMPDIR_TEST/bin:$PATH" \
    REAPER_LOCK_DIR="$TMPDIR_TEST/.chump-locks" \
    REAPER_REPO_ROOT="$TMPDIR_TEST" \
    bash "$PATCHED" --close-merged-gaps 2>&1 || true)

echo "$OUT"

# ---------- assertions -------------------------------------------------------
FAIL=0

if [[ -f "$TMPDIR_TEST/shipped/INFRA-664" ]]; then
    echo "PASS: INFRA-664 (open gap, PR #9901 merged) was closed via chump gap ship"
else
    echo "FAIL: INFRA-664 should have been shipped but was not"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/shipped/INFRA-665" ]]; then
    echo "PASS: INFRA-665 (already done) was NOT re-shipped"
else
    echo "FAIL: INFRA-665 should NOT have been shipped (already done)"
    FAIL=1
fi

# Verify ambient ALERT was emitted
if grep -q '"kind":"ghost_status_closed"' "$AMBIENT"; then
    echo "PASS: ambient.jsonl contains kind=ghost_status_closed event"
else
    echo "FAIL: ambient.jsonl missing kind=ghost_status_closed event"
    FAIL=1
fi

if grep -q '"gap_id":"INFRA-664"' "$AMBIENT"; then
    echo "PASS: ghost_status_closed event references INFRA-664"
else
    echo "FAIL: ghost_status_closed event missing INFRA-664"
    FAIL=1
fi

# Summary line must mention ghost gaps
if echo "$OUT" | grep -qE "ghost gap|ghost_closed|Ghost"; then
    echo "PASS: output mentions ghost gap closure"
else
    echo "FAIL: output does not mention ghost gap closure"
    FAIL=1
fi

exit $FAIL
