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

# RESILIENT-1678 AC1: resolve real git by absolute path captured BEFORE PATH
# is modified, never via `command git` or PATH lookup inside the stub.
REAL_GIT="$(command -v git)"
[[ -n "$REAL_GIT" && -x "$REAL_GIT" ]] || { echo "FAIL: cannot resolve real git binary"; exit 1; }
export REAL_GIT

# git stub: passes through for anything except the fetch/merge-base/rev-parse
# calls this script makes for redundancy detection. PR #201 (redundant-dirty)
# resolves merge-base == branch tip; PR #202 (real-dirty) resolves them
# different so the rebase path is taken.
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
EOF
cat >> "$STUB/git" <<'EOF'
STUB_DEPTH="${CHUMP_GIT_STUB_DEPTH:-0}"
STUB_DEPTH=$((STUB_DEPTH + 1))
export CHUMP_GIT_STUB_DEPTH="$STUB_DEPTH"
if [[ "$STUB_DEPTH" -gt 2 ]]; then
  echo "FAIL: git stub recursion detected (depth=$STUB_DEPTH)" >&2
  exit 99
fi
if [[ -n "${CHUMP_GIT_STUB_DEPTH_LOG:-}" ]]; then
  echo "$STUB_DEPTH" >> "$CHUMP_GIT_STUB_DEPTH_LOG"
fi
real_git() { "$REAL_GIT" "$@"; }
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

# ── RESILIENT-1678 AC3: unhandled git subcommand + classifier run with bounded process count ──
DEPTH_LOG="$TMP/stub_depth.log"
: > "$DEPTH_LOG"
export CHUMP_GIT_STUB_DEPTH_LOG="$DEPTH_LOG"

start_ts="$(date +%s)"
# Exercise both top-level unhandled subcommand (`git --version`) and `-C <repo>` unhandled
# subcommand (`git -C "$REPO_ROOT" rev-list --max-count=1 HEAD`) plus a full classifier run
# while $STUB is first on PATH.
if ! timeout 10 bash -c '
  set -euo pipefail
  git --version >/dev/null
  git -C "$1" rev-list --max-count=1 HEAD >/dev/null
  bash "$2" >/dev/null 2>&1
' _ "$REPO_ROOT" "$SCRIPT"; then
    echo "FAIL: RESILIENT-1678 AC3: unhandled git subcommand / classifier timed out or failed"
    fail=1
fi
elapsed=$(( $(date +%s) - start_ts ))
if [[ "$elapsed" -ge 10 ]]; then
    echo "FAIL: RESILIENT-1678 AC3: unhandled git subcommand took ${elapsed}s (>= 10s)"
    fail=1
fi
max_depth="$(sort -n "$DEPTH_LOG" | tail -1)"
if [[ -z "$max_depth" || "$max_depth" -gt 1 ]]; then
    echo "FAIL: RESILIENT-1678 AC3: expected max stub call depth 1 (no recursion), got '${max_depth:-empty}'"
    fail=1
fi

# ── RESILIENT-1678 AC2: grep gate across scripts/ci/*.sh stubs ───────────────
check_ci_stubs_no_self_path_lookup() {
  local target_dir="$1"
  python3 - "$target_dir" <<'PYGATE'
import glob, os, re, sys

ci_dir = sys.argv[1]
violations = []

stub_heredoc_re = re.compile(
    r'cat\s*>+\s*["\']?\$[A-Za-z0-9_{}/.-]+/([a-z0-9_-]+)["\']?\s*<<([\'"]?)(\w+)\2\n(.*?)\n\3\b',
    re.DOTALL,
)
path_prepend_re = re.compile(r'PATH=.*\$[A-Za-z0-9_]+.*:\$PATH')

for path in sorted(glob.glob(os.path.join(ci_dir, "*.sh"))):
    with open(path, errors="replace") as f:
        text = f.read()
    if not path_prepend_re.search(text):
        continue
    for m in stub_heredoc_re.finditer(text):
        bin_name = m.group(1)
        body = m.group(4)
        for line in body.splitlines():
            ls = line.strip()
            if not ls or ls.startswith("#") or ls.startswith("echo ") or ls.startswith("printf ") or ls.startswith("cat "):
                continue
            code = re.sub(r"#.*$", "", ls)
            code_unq = re.sub(r'"[^"]*"|\'[^\']*\'', "", code)
            if re.search(
                rf'(?:^|[;|&({{\s])(?:command\s+(?!-[pv]\b)|(?:exec\s+)?/usr/bin/env\s+|exec\s+)?{re.escape(bin_name)}(?:\s|$)',
                code_unq,
            ):
                violations.append(f"{path}: stub '{bin_name}' invokes '{bin_name}' via PATH: {ls}")

if violations:
    for v in violations:
        print(v, file=sys.stderr)
    sys.exit(1)
PYGATE
}

if ! check_ci_stubs_no_self_path_lookup "$REPO_ROOT/scripts/ci"; then
    echo "FAIL: RESILIENT-1678 AC2: scripts/ci contains a PATH-prepending stub that calls itself via PATH"
    fail=1
fi

# Prove the grep gate catches a mutant stub that calls `command git "$@"` or bare `git "$@"`
MUTANT_CI="$TMP/mutant-ci"
mkdir -p "$MUTANT_CI"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat > "$STUB/git" <<'\''EOF'\''' \
  '#!/usr/bin/env bash' \
  'real_git() { '"command"' git "$@"; }' \
  'real_git "$@"' \
  'EOF' \
  'export PATH="$STUB:$PATH"' > "$MUTANT_CI/test-bad-stub.sh"
if check_ci_stubs_no_self_path_lookup "$MUTANT_CI" 2>/dev/null; then
    echo "FAIL: RESILIENT-1678 AC2: grep gate failed to catch mutant command git stub"
    fail=1
fi

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
