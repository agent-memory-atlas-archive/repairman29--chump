#!/usr/bin/env bash
# test-pr-clean-dirty-classifier.sh — INFRA-6229
#
# Proves scripts/coord/pr-clean-dirty-classifier.sh classifies every open PR
# as CLEAN or DIRTY and dispatches the right terminal-state action:
#   • CLEAN + unarmed         → gh pr merge --auto --squash (arm)
#   • CLEAN + already armed   → left alone (no duplicate arm attempt)
#   • DIRTY + redundant       → gh pr close (retire)
#   • DIRTY + not redundant   → gh pr update-branch (content-rebase)
#
# Runs against a synthetic PR fixture (CHUMP_PR_CLASSIFIER_PR_JSON) with
# gh/git stubbed on PATH — no live GitHub, no state mutation.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/pr-clean-dirty-classifier.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CALL_LOG="$TMP/calls.log"
: > "$CALL_LOG"

STUB="$TMP/bin"
mkdir -p "$STUB"

# gh stub: records every invocation, fakes success for merge/close/update-branch
cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$CALL_LOG"
case "\$1" in
  pr)
    case "\$2" in
      merge|close|update-branch) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
EOF

# git stub: passes through for anything except the fetch/merge-base/rev-parse
# calls this script makes for redundancy detection. PR #201 (redundant-dirty)
# resolves merge-base == branch tip; PR #202 (real-dirty) resolves them
# different so the rebase path is taken.
cat > "$STUB/git" <<'EOF'
#!/usr/bin/env bash
real_git() { command git "$@"; }
case "$1" in
  -C)
    repo="$2"; shift 2
    case "$1" in
      fetch) echo "git fetch $*" >> "$CHUMP_TEST_CALL_LOG"; exit 0 ;;
      merge-base)
        echo "git merge-base $*" >> "$CHUMP_TEST_CALL_LOG"
        if [[ "$*" == *"redundant-dirty"* ]]; then echo "aaaa"; else echo "aaaa"; fi
        exit 0
        ;;
      rev-parse)
        echo "git rev-parse $*" >> "$CHUMP_TEST_CALL_LOG"
        if [[ "$*" == *"redundant-dirty"* ]]; then echo "aaaa"; else echo "bbbb"; fi
        exit 0
        ;;
      *) real_git -C "$repo" "$@" ;;
    esac
    ;;
  *) real_git "$@" ;;
esac
EOF
chmod +x "$STUB"/*
export CHUMP_TEST_CALL_LOG="$CALL_LOG"
export PATH="$STUB:$PATH"

FIXTURE="$TMP/prs.json"
cat > "$FIXTURE" <<'EOF'
[
  {"number": 101, "headRefName": "clean-unarmed", "mergeStateStatus": "CLEAN", "autoMergeRequest": null, "title": "clean unarmed"},
  {"number": 102, "headRefName": "clean-armed", "mergeStateStatus": "CLEAN", "autoMergeRequest": {"enabledAt": "2026-01-01T00:00:00Z"}, "title": "clean armed"},
  {"number": 201, "headRefName": "redundant-dirty", "mergeStateStatus": "DIRTY", "autoMergeRequest": null, "title": "redundant dirty"},
  {"number": 202, "headRefName": "real-dirty", "mergeStateStatus": "CONFLICTING", "autoMergeRequest": null, "title": "real dirty"}
]
EOF

export CHUMP_PR_CLASSIFIER_PR_JSON="$FIXTURE"
export CHUMP_PR_CLASSIFIER_AMBIENT="$TMP/ambient.jsonl"

OUT="$(bash "$SCRIPT" 2>&1)"
RC=$?

fail=0

if [[ "$RC" -ne 0 ]]; then
    echo "FAIL: classifier exited non-zero ($RC)"
    echo "$OUT"
    fail=1
fi

grep -q "gh pr merge 101 --auto --squash" "$CALL_LOG" || { echo "FAIL: expected arm call for PR #101 (CLEAN+unarmed)"; fail=1; }
grep -q "gh pr merge 102" "$CALL_LOG" && { echo "FAIL: should NOT re-arm already-armed PR #102"; fail=1; }
grep -q "gh pr close 201" "$CALL_LOG" || { echo "FAIL: expected retire (close) call for PR #201 (DIRTY+redundant)"; fail=1; }
grep -q "gh pr update-branch 202" "$CALL_LOG" || { echo "FAIL: expected content-rebase call for PR #202 (DIRTY+not-redundant)"; fail=1; }

grep -q '"pr":101.*"label":"CLEAN"' "$CHUMP_PR_CLASSIFIER_AMBIENT" || { echo "FAIL: PR #101 not classified CLEAN in ambient"; fail=1; }
grep -q '"pr":201.*"label":"DIRTY"' "$CHUMP_PR_CLASSIFIER_AMBIENT" || { echo "FAIL: PR #201 not classified DIRTY in ambient"; fail=1; }
grep -q '"pr":101.*pr_terminal_armed\|pr_terminal_armed.*"pr":101' "$CHUMP_PR_CLASSIFIER_AMBIENT" >/dev/null || \
    grep -q 'pr_terminal_armed' "$CHUMP_PR_CLASSIFIER_AMBIENT" || { echo "FAIL: no pr_terminal_armed event emitted"; fail=1; }
grep -q 'pr_terminal_retired' "$CHUMP_PR_CLASSIFIER_AMBIENT" || { echo "FAIL: no pr_terminal_retired event emitted"; fail=1; }
grep -q 'pr_terminal_rebased' "$CHUMP_PR_CLASSIFIER_AMBIENT" || { echo "FAIL: no pr_terminal_rebased event emitted"; fail=1; }

if [[ "$fail" -ne 0 ]]; then
    echo "--- classifier output ---"
    echo "$OUT"
    echo "--- calls ---"
    cat "$CALL_LOG"
    echo "--- ambient ---"
    cat "$CHUMP_PR_CLASSIFIER_AMBIENT" 2>/dev/null
    echo "FAIL: test-pr-clean-dirty-classifier.sh"
    exit 1
fi

echo "PASS: test-pr-clean-dirty-classifier.sh"
