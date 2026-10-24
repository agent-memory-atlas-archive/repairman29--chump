#!/usr/bin/env bash
# test-ghost-gap-reaper.sh — integration test for the ghost-gap reaper's two
# phases: INFRA-556 (done-but-bounced-PR rollback) and INFRA-1909
# (open-but-already-merged reconciliation).
# INFRA-1313: Also tests that closed_at (not updated_at) is used for lookback,
# and that meta-tracking gaps with [CI-RED], [ORPHAN], etc. titles are excluded.
#
# Phase 1 fixtures:
#   gap_A: status=done, closed_pr=101 (PR 101 closed without merge) → must roll back to open
#   gap_B: status=done, closed_pr=102 (PR 102 merged)               → must stay done
#   gap_C: status=done, closed_pr=103 (PR 103 still open)           → must stay done (not yet decided)
#   gap_D: status=done, closed_pr="" (no PR recorded)               → must stay done (nothing to check)
#   gap_E: status=done, closed_pr=104, title="PR #104 stuck [CI-RED]" → must stay done (meta-tracking)
#   gap_F: status=done, closed_pr=105, title="ORPHAN-fix" → must stay done (meta-tracking)
#   gap_old: status=done, closed_pr=106, updated_at recent (commented on), closed_at old → must stay done (uses closed_at)
#
# Phase 2 fixtures (INFRA-1909):
#   gap_G: status=open, no merged PR found            → must stay open
#   gap_H: status=open, merged PR #201 found via search → must be shipped (status=done)
#   gap_I: status=open, closed_pr=202 already recorded (RESILIENT-070)
#          → must be shipped WITHOUT any gh lookup (gh stub has no entry for gap_I;
#            if the reaper fell through to gh search it would find nothing and fail)
#
# Stubs out chump + gh with minimal shims; never touches real state.db or GitHub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/coord/ghost-gap-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not found or not executable: $REAPER"; exit 1; }

# INFRA-1909: dates must be computed relative to "now" (not hardcoded) so the
# 7-day lookback window in phase 1 doesn't drift stale as calendar time passes.
RECENT_DATE=$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(days=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
OLD_DATE=$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
NOW_DATE=$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ---------- stub: chump -------------------------------------------------------
# Accepts: gap list --status done --json   → returns fixture JSON
# Accepts: gap set <ID> --status open      → writes "$TMPDIR_TEST/rolled_back/<ID>"
STUB_CHUMP="$TMPDIR_TEST/bin/chump"
mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/rolled_back"

cat > "$STUB_CHUMP" <<'STUB'
#!/usr/bin/env bash
# Minimal chump shim for test-ghost-gap-reaper.sh
TMPDIR_TEST="$CHUMP_TEST_TMPDIR"
case "$*" in
  *"list --status done --json"*)
    cat <<'JSON'
[
  {"id":"gap_A","status":"done","closed_pr":"101","title":"gap A"},
  {"id":"gap_B","status":"done","closed_pr":"102","title":"gap B"},
  {"id":"gap_C","status":"done","closed_pr":"103","title":"gap C"},
  {"id":"gap_D","status":"done","closed_pr":"","title":"gap D"},
  {"id":"gap_E","status":"done","closed_pr":"104","title":"PR #104 stuck [CI-RED] — CI timeout"},
  {"id":"gap_F","status":"done","closed_pr":"105","title":"[ORPHAN]: gap for stuck PR"},
  {"id":"gap_old","status":"done","closed_pr":"106","title":"old gap"}
]
JSON
    ;;
  *"set gap_A --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_A"
    ;;
  *"set gap_B --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_B"
    ;;
  *"set gap_C --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_C"
    ;;
  *"set gap_E --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_E"
    ;;
  *"set gap_F --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_F"
    ;;
  *"set gap_old --status open"*)
    touch "$TMPDIR_TEST/rolled_back/gap_old"
    ;;
  *"list --status open --json"*)
    cat <<'JSON'
[
  {"id":"gap_G","status":"open","closed_pr":"","title":"gap G"},
  {"id":"gap_H","status":"open","closed_pr":"","title":"gap H"},
  {"id":"gap_I","status":"open","closed_pr":"202","title":"gap I"}
]
JSON
    ;;
  *"ship gap_H --closed-pr 201 --update-yaml"*)
    touch "$TMPDIR_TEST/shipped/gap_H"
    ;;
  *"ship gap_I --closed-pr 202 --update-yaml"*)
    touch "$TMPDIR_TEST/shipped/gap_I"
    ;;
  *)
    ;;
esac
exit 0
STUB
chmod +x "$STUB_CHUMP"
mkdir -p "$TMPDIR_TEST/shipped"

# ---------- stub: gh ----------------------------------------------------------
# Accepts: pr view <N> --json state,mergedAt
STUB_GH="$TMPDIR_TEST/bin/gh"
cat > "$STUB_GH" <<STUB
#!/usr/bin/env bash
# gh shim: pr view <N> --json state,mergedAt
# Also handles the REST pull API response format used by ghost-gap-reaper
case "\$*" in
  *"repos"*"pulls?state=closed"*)
    # REST API response for closed PRs (103 is still open, so not in this list)
    cat <<JSON
[
  {"number":101,"state":"closed","merged_at":null,"closed_at":"$RECENT_DATE","updated_at":"$RECENT_DATE"},
  {"number":102,"state":"closed","merged_at":"$RECENT_DATE","closed_at":"$RECENT_DATE","updated_at":"$RECENT_DATE"},
  {"number":104,"state":"closed","merged_at":null,"closed_at":"$RECENT_DATE","updated_at":"$RECENT_DATE"},
  {"number":105,"state":"closed","merged_at":null,"closed_at":"$RECENT_DATE","updated_at":"$RECENT_DATE"},
  {"number":106,"state":"closed","merged_at":null,"closed_at":"$OLD_DATE","updated_at":"$NOW_DATE"}
]
JSON
    ;;
  *"pr list --search gap_H --state merged"*)
    cat <<JSON
[{"number":201,"mergedAt":"$RECENT_DATE"}]
JSON
    ;;
  *"pr list --search gap_G --state merged"*)
    echo '[]'
    ;;
  *)
    echo '{"state":"MERGED","mergedAt":"$RECENT_DATE"}'
    ;;
esac
exit 0
STUB
chmod +x "$STUB_GH"

# ---------- stub: ambient-emit.sh ---------------------------------------------
mkdir -p "$TMPDIR_TEST/scripts/dev"
cat > "$TMPDIR_TEST/scripts/dev/ambient-emit.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMPDIR_TEST/scripts/dev/ambient-emit.sh"

# ---------- run reaper with stubs in PATH ------------------------------------
OUT=$(PATH="$TMPDIR_TEST/bin:$PATH" \
    CHUMP_REPO="$TMPDIR_TEST" \
    CHUMP_BINARY_STALENESS_CHECK=0 \
    HOME="$TMPDIR_TEST" \
    CHUMP_TEST_TMPDIR="$TMPDIR_TEST" \
    "$REAPER" 2>&1 || true)

echo "$OUT"

# ---------- assertions -------------------------------------------------------
FAIL=0

if [[ -f "$TMPDIR_TEST/rolled_back/gap_A" ]]; then
    echo "PASS: gap_A (PR closed without merge) was rolled back to open"
else
    echo "FAIL: gap_A should have been rolled back but was not"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_B" ]]; then
    echo "PASS: gap_B (PR merged) was NOT rolled back"
else
    echo "FAIL: gap_B should NOT have been rolled back (PR merged)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_C" ]]; then
    echo "PASS: gap_C (PR still open) was NOT rolled back"
else
    echo "FAIL: gap_C should NOT have been rolled back (PR still open)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_D" ]]; then
    echo "PASS: gap_D (no closed_pr) was NOT rolled back"
else
    echo "FAIL: gap_D should NOT have been rolled back (no PR)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_E" ]]; then
    echo "PASS: gap_E (meta-tracking [CI-RED]) was NOT rolled back"
else
    echo "FAIL: gap_E should NOT have been rolled back (meta-tracking gap with [CI-RED])"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_F" ]]; then
    echo "PASS: gap_F (meta-tracking ORPHAN) was NOT rolled back"
else
    echo "FAIL: gap_F should NOT have been rolled back (meta-tracking gap with ORPHAN)"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/rolled_back/gap_old" ]]; then
    echo "PASS: gap_old (closed_at outside window) was NOT rolled back"
else
    echo "FAIL: gap_old should NOT have been rolled back (closed_at outside 7-day window)"
    FAIL=1
fi

# Output must mention the rollback
echo "$OUT" | grep -q "gap_A" \
    || { echo "FAIL: output missing gap_A rollback message"; FAIL=1; }

echo "$OUT" | grep -q "rolled back 1 ghost gap(s)" \
    || { echo "FAIL: summary line 'rolled back 1 ghost gap(s)' not found in output"; FAIL=1; }

# Phase 2 (INFRA-1909 + CREDIBLE-1553) assertions:
# gap_H has no closed_pr recorded; even though gh search would return PR #201,
# ghost-gap-reaper must NOT fall back to title/search lookup (CREDIBLE-1553).
if [[ ! -f "$TMPDIR_TEST/shipped/gap_H" ]]; then
    echo "PASS: gap_H (unlinked search match only, no closed_pr) was NOT shipped (CREDIBLE-1553)"
else
    echo "FAIL: gap_H should NOT have been shipped via title/search fallback"
    FAIL=1
fi

if [[ ! -f "$TMPDIR_TEST/shipped/gap_G" ]]; then
    echo "PASS: gap_G (no merged PR found) was NOT shipped"
else
    echo "FAIL: gap_G should NOT have been shipped (no merged PR)"
    FAIL=1
fi

_pom_var="CHUMP_""BYPASS_PROOF_OF_MERGE"
if grep -q "$_pom_var" "$REAPER"; then
    echo "FAIL: ghost-gap-reaper.sh still references $_pom_var"
    FAIL=1
else
    echo "PASS: ghost-gap-reaper.sh does not use $_pom_var"
fi

echo "$OUT" | grep -q "reaped 1 ghost-open gap(s)" \
    || { echo "FAIL: summary line 'reaped 1 ghost-open gap(s)' not found in output"; FAIL=1; }

# RESILIENT-070: gap_I already had closed_pr recorded — must be shipped
# directly, with no gh lookup (gh stub has no case for "gap_I" search).
if [[ -f "$TMPDIR_TEST/shipped/gap_I" ]]; then
    echo "PASS: gap_I (closed_pr already recorded) was shipped without a PR lookup"
else
    echo "FAIL: gap_I should have been shipped via its already-recorded closed_pr"
    FAIL=1
fi

echo "$OUT" | grep -q "closed_pr=#202 already recorded, no PR lookup needed" \
    || { echo "FAIL: output missing RESILIENT-070 no-lookup-needed message for gap_I"; FAIL=1; }

exit $FAIL
