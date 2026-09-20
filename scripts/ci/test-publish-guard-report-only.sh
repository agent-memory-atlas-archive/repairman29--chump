#!/usr/bin/env bash
# INFRA-7880: the publish guard is installed REPORT-ONLY. This test pins the two properties that
# matter in that phase: it SEES the finding, and it NEVER changes whether a commit succeeds.
#
# Depth (shop rule: green is not covered). See scripts/publish-guard/DEPTH.md for the full chart.
#   engine table test ........ edge + a named adversarial set (48 cases, 3 are KNOWN-MISS pins)
#   wrapper + hook wiring .... happy-path + edge (this file, sandbox repo, synthetic terms only)
#   bot-merge call site ...... smoke (static: the call exists, is piped PR text, is `|| true`)
#   CI workflow .............. smoke (static shape checks here; the live run is the PR's own check)
# NOT covered here: a real bot-merge run end to end, a linked-worktree commit writing to the
# main checkout's ambient stream, concurrent writers, python3 missing from PATH.
#
# Every term in this file is synthetic. Do not put a real hostname, path or name in a test.
#
# Run from repo root: bash scripts/ci/test-publish-guard-report-only.sh

set -u
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT" || exit 2

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── 1. engine table test ─────────────────────────────────────────────────────
if python3 scripts/publish-guard/test_publish_guard.py >/dev/null 2>&1; then
    pass "engine table test (48 cases) behaves as listed"
else
    fail "engine table test has a failing case: python3 scripts/publish-guard/test_publish_guard.py"
fi

# ── sandbox: a repo with the real hooks, the real wrapper, and a fake HOME ───
SANDBOX=$(mktemp -d)
FAKEHOME=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$FAKEHOME"' EXIT
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/scripts/git-hooks" "$SANDBOX/scripts/publish-guard" "$SANDBOX/src" \
         "$SANDBOX/.publish-guard" "$SANDBOX/.chump-locks" "$SANDBOX/docs/gaps"
cp scripts/git-hooks/pre-commit scripts/git-hooks/commit-msg "$SANDBOX/scripts/git-hooks/"
chmod +x "$SANDBOX/scripts/git-hooks/"*
cp scripts/publish-guard/publish-guard.py scripts/publish-guard/report_only.py "$SANDBOX/scripts/publish-guard/"
cp .publish-guard/MIN_PATTERNS_VERSION .publish-guard/overrides.txt "$SANDBOX/.publish-guard/"
printf '.chump-locks/\n' > "$SANDBOX/.gitignore"
# No Cargo.toml and no .rs on purpose: the sandbox HOME is fake (so no real pattern file can
# leak into the test), and a fake HOME hides rustup's toolchain on CI runners. Plain text files
# keep cargo out of it, and prove the call is reached on a docs-only commit too.
echo 'notes' > "$SANDBOX/src/notes.md"
G() { git -C "$SANDBOX" -c user.email=t@t -c user.name=t "$@"; }
G add -A >/dev/null
G commit -q --no-verify -m seed
G config core.hooksPath scripts/git-hooks

# Existing guards are switched off with their EXISTING switches so the sandbox needs no fleet
# state. None of these touches the publish guard: it has no switch.
SANDBOX_ENV="HOME=$FAKEHOME CHUMP_LEASE_CHECK=0 CHUMP_STOMP_WARN=0 CHUMP_GAPS_LOCK=0 CHUMP_PREREG_CHECK=0
             CHUMP_CROSS_JUDGE_CHECK=0 CHUMP_SUBMODULE_CHECK=0 CHUMP_CHECK_BUILD=0 CHUMP_FMT_CHECK=0
             CHUMP_DOCS_DELTA_CHECK=0 CHUMP_PREREG_CONTENT_CHECK=0 CHUMP_RAW_YAML_LOCK=0
             CHUMP_BOOK_SYNC_CHECK=0 CHUMP_PROVENANCE_STAMP=0 CHUMP_GAP_CHECK=0"
AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"
commit() { # commit <message>  -> exit code of git commit, output in $SANDBOX/.out
    # shellcheck disable=SC2086
    env $SANDBOX_ENV git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "$1" >"$SANDBOX/.out" 2>&1
}

# ── 2. no pattern file: generic rules only, says so, commit succeeds ─────────
echo 'see /Users/realperson/notes for context' >> "$SANDBOX/src/notes.md"
G add src/notes.md
if commit "INFRA-1: add a note"; then pass "commit with a finding still SUCCEEDS (report-only)"; else fail "report-only guard changed the commit outcome"; cat "$SANDBOX/.out"; fi
grep -q 'generic rules only' "$SANDBOX/.out" && pass "missing pattern file falls back to builtin-only and says so" || fail "no builtin-only notice"
grep -q 'src/notes.md:[0-9]*: home-path' "$SANDBOX/.out" && pass "finding reported as file:line: class" || fail "home-path finding not reported"
grep -q 'realperson' "$SANDBOX/.out" && fail "output echoed the matched value" || pass "matched value is not echoed"
if grep -q '"kind":"publish_guard_report"' "$AMBIENT" 2>/dev/null && grep -q '"site":"staged"' "$AMBIENT" \
   && grep -q '"patterns":"builtin-only"' "$AMBIENT" && grep -q 'home-path=1' "$AMBIENT"; then
    pass "ambient event written with site, pattern mode and class counts"
else
    fail "ambient event missing or incomplete"
fi
grep -q 'realperson\|src/notes.md' "$AMBIENT" && fail "ambient event carries a path or a value" || pass "ambient event carries no path and no value"

# ── 3. operator pattern file present: term caught in diff and in message ─────
mkdir -p "$FAKEHOME/.config/chump"
cat > "$FAKEHOME/.config/chump/publish-guard.patterns" <<'EOF'
#! publish-guard-patterns v1
#! version 1
#! nonce 0000-test-only
hostname   term   zorkmidbox
EOF
: > "$AMBIENT"
echo 'deployed from zorkmidbox' >> "$SANDBOX/src/notes.md"
G add src/notes.md
if commit "INFRA-2: rebuilt on zorkmidbox overnight"; then pass "commit with operator-term findings still succeeds"; else fail "operator-term finding blocked the commit"; cat "$SANDBOX/.out"; fi
grep -q 'src/notes.md:[0-9]*: hostname' "$SANDBOX/.out" && pass "operator term found in the staged diff" || fail "operator term in diff not reported"
grep -q 'commit-message:1: hostname' "$SANDBOX/.out" && pass "operator term found in the commit MESSAGE (commit-msg stage)" || fail "operator term in message not reported"
grep -q 'zorkmidbox' "$SANDBOX/.out" && fail "output echoed the operator term" || pass "operator term is not echoed"
grep -q '"site":"message"' "$AMBIENT" && grep -q '"patterns":"full"' "$AMBIENT" && pass "message-site event written, pattern mode full" || fail "message-site event missing"

# ── 4. registry paths are skipped in report-only mode ────────────────────────
: > "$AMBIENT"
printf 'title: moved the box zorkmidbox\n' > "$SANDBOX/docs/gaps/INFRA-3.yaml"
echo 'a clean line rides along so the staged scan has something to read' >> "$SANDBOX/src/notes.md"
G add docs/gaps/INFRA-3.yaml src/notes.md
commit "INFRA-3: registry row" || true
if grep '"site":"staged"' "$AMBIENT" | grep -q '"status":"clean"'; then
    pass "docs/gaps/ is skipped: no hostname finding from the registry path"
else
    fail "registry path was scanned (or no event was written)"
fi

# ── 5. stale pattern file: engine cannot run, commit still succeeds ──────────
echo 9 > "$SANDBOX/.publish-guard/MIN_PATTERNS_VERSION"
echo 'one more line' >> "$SANDBOX/src/notes.md"
G add src/notes.md .publish-guard/MIN_PATTERNS_VERSION
if commit "INFRA-4: tidy"; then pass "engine exit 2 (stale patterns) does not block the commit"; else fail "engine exit 2 blocked the commit"; cat "$SANDBOX/.out"; fi
grep -q 'could-not-run' "$SANDBOX/.out" && pass "could-not-run is reported, not swallowed" || fail "could-not-run not reported"

# ── 6. text mode (the bot-merge call shape) ──────────────────────────────────
echo 1 > "$SANDBOX/.publish-guard/MIN_PATTERNS_VERSION"
out=$(cd "$SANDBOX" && printf 'INFRA-5: title\n\nTested against zorkmidbox\n' | env HOME="$FAKEHOME" python3 scripts/publish-guard/report_only.py text pr-title-and-body 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'pr-title-and-body:3: hostname' && pass "text mode reports a PR-body finding and exits 0" || fail "text mode: rc=$rc out=$out"
out=$(cd "$SANDBOX" && printf 'x zorkmidbox\n' | env HOME="$FAKEHOME" python3 scripts/publish-guard/report_only.py --summary-only text pr 2>&1)
echo "$out" | grep -q 'pr:1:' && fail "--summary-only printed a finding line" || pass "--summary-only prints counts, no path:line pointers"
env HOME="$FAKEHOME" python3 "$SANDBOX/scripts/publish-guard/report_only.py" nonsense >/dev/null 2>&1 && pass "bad arguments still exit 0" || fail "bad arguments exited non-zero"

# ── 7. static: call sites and workflow shape ─────────────────────────────────
grep -q 'report_only.py" text pr-title-and-body || true' scripts/coord/bot-merge.sh && pass "bot-merge calls the wrapper with PR text and ignores its exit" || fail "bot-merge call missing or not exit-ignored"
lean=$(grep -n 'CHUMP_PRECOMMIT_STRICT:-0' scripts/git-hooks/pre-commit | head -1 | cut -d: -f1)
call=$(grep -n 'report_only.py" staged || true' scripts/git-hooks/pre-commit | head -1 | cut -d: -f1)
[ -n "$call" ] && [ -n "$lean" ] && [ "$call" -lt "$lean" ] && pass "pre-commit call sits ABOVE the lean exit" || fail "pre-commit call missing or below the lean exit"
WF=.github/workflows/publish-guard.yml
if grep -v '^ *#' "$WF" | grep -q 'pull_request_target'; then fail "workflow uses pull_request_target"; else pass "workflow does not use pull_request_target"; fi
grep -q 'continue-on-error: true' "$WF" && grep -q "steps.p.outputs.have == 'true'" "$WF" && pass "workflow never fails and skips when the secret is empty" || fail "workflow lacks continue-on-error or the empty-secret skip"
if grep -rn 'PUBLISH_GUARD[A-Z_]*\(=\|:-\)' scripts/publish-guard/*.py scripts/git-hooks/pre-commit scripts/git-hooks/commit-msg >/dev/null 2>&1 \
   || grep -n 'os\.environ\|getenv' scripts/publish-guard/publish-guard.py scripts/publish-guard/report_only.py >/dev/null 2>&1; then
    fail "the guard reads an environment variable (no bypass variable, ever)"
else
    pass "neither the engine nor the wrapper reads any environment variable"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
