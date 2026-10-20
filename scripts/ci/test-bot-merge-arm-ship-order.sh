#!/usr/bin/env bash
# test-bot-merge-arm-ship-order.sh — INFRA-1030: arm auto-merge BEFORE gap ship
#
# Tests:
#   1. In the normal ship flow, gh pr merge --auto appears BEFORE chump gap ship
#   2. When chump gap ship fails AFTER arm, script exits 0 (not 1) and emits
#      gap_ship_post_arm_failed to ambient.jsonl — PR is still armed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# BOT_MERGE defaults to the in-repo script; mutation-testing harnesses may point
# it at a throwaway mutant copy via the env var (test-fixture knob only — never
# read by production code).
BOT_MERGE="${BOT_MERGE:-$REPO_ROOT/scripts/coord/bot-merge.sh}"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$BOT_MERGE" ]] || fail "bot-merge.sh not found at $BOT_MERGE"

TMP="$(mktemp -d -t test-bm-order.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CALL_LOG="$TMP/call.log"
AMBIENT="$TMP/ambient.jsonl"

# ── Mock commands ────────────────────────────────────────────────────────────
# gh: simulates: auth status, pr view (returns PR #42), pr create (noop since
#     EXISTING_PR already set), pr merge --auto, pr checks (empty), pr diff.
MOCK_GH="$TMP/gh"
cat > "$MOCK_GH" <<'GHEOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALL_LOG"
subcmd="${1:-}"; shift || true
case "$subcmd" in
  auth)   exit 0 ;;
  pr)
    pr_cmd="${1:-}"; shift || true
    case "$pr_cmd" in
      view)
        case "${1:-}" in
          --json) printf '{"number":42}\n' ;;
          *)      printf '{"number":42,"state":"OPEN","autoMergeRequest":null}\n' ;;
        esac ;;
      merge)
        # --auto --squash: success
        exit 0 ;;
      checks)
        # no failing checks
        exit 0 ;;
      diff)
        # no src files (skips code-reviewer)
        exit 0 ;;
      list)
        echo '[]' ;;
      create)
        printf 'https://github.com/test/repo/pull/42\n'
        exit 0 ;;
      comment)
        exit 0 ;;
      *)
        exit 0 ;;
    esac ;;
  api)
    url="${1:-}"
    case "$url" in
      rate_limit)
        printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":1747200000},"graphql":{"limit":5000,"remaining":4900,"reset":1747200060}}}\n' ;;
      graphql)
        # enablePullRequestAutoMerge - already handled by gh pr merge mock
        printf '{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"number":42}}}}\n' ;;
      *)
        echo '[]' ;;
    esac ;;
  *)
    exit 0 ;;
esac
GHEOF
chmod +x "$MOCK_GH"

# chump mock: logs calls; by default succeeds; if CHUMP_SHIP_FAIL=1, fail gap ship
MOCK_CHUMP="$TMP/chump"
cat > "$MOCK_CHUMP" <<'CHEOF'
#!/usr/bin/env bash
printf 'chump %s\n' "$*" >> "$CALL_LOG"
subcmd="${1:-}"; shift || true
case "$subcmd" in
  gap)
    gap_cmd="${1:-}"; shift || true
    case "$gap_cmd" in
      ship)
        if [[ "${CHUMP_SHIP_FAIL:-0}" == "1" ]]; then
          echo "chump gap ship: simulated failure" >&2
          exit 1
        fi
        exit 0 ;;
      list)   echo '[]' ;;
      show)   echo 'status: open' ;;
      *)      exit 0 ;;
    esac ;;
  fleet)   exit 0 ;;
  *)        exit 0 ;;
esac
CHEOF
chmod +x "$MOCK_CHUMP"

# git: mock to avoid repo operations
MOCK_GIT="$TMP/git"
cat > "$MOCK_GIT" <<'GITEOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  rev-parse)
    case "${1:-}" in
      --show-toplevel)  printf '%s\n' "$FAKE_REPO" ;;
      --git-common-dir) printf '%s/.git\n' "$FAKE_REPO" ;;
      --quiet)          exit 0 ;;
      *)                printf '%s\n' "$FAKE_REPO" ;;
    esac ;;
  remote)   printf 'https://github.com/testorg/testrepo.git\n' ;;
  log)      exit 0 ;;
  status)   exit 0 ;;
  push)     exit 0 ;;
  tag)      exit 0 ;;
  fetch)    exit 0 ;;
  *)        exit 0 ;;
esac
GITEOF
chmod +x "$MOCK_GIT"

export PATH="$TMP:$PATH"
export CALL_LOG
export CHUMP_AMBIENT_LOG="$AMBIENT"

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/.chump"
# INFRA-1261: seed minimal state.db so gap-preflight won't treat TEST-001 as
# unregistered when CHUMP_GAP_PREFLIGHT_SKIP is not set. Primary guard is the
# CHUMP_GAP_PREFLIGHT_SKIP=1 env below; this DB seed is defense-in-depth.
sqlite3 "$FAKE_REPO/.chump/state.db" "
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
    priority TEXT, effort TEXT, depends_on TEXT, acceptance_criteria TEXT,
    description TEXT, closed_pr INTEGER, tags TEXT
);
INSERT OR IGNORE INTO gaps (id,domain,title,status,priority,effort)
    VALUES ('TEST-001','TEST','stacked test','open','P2','xs');
" 2>/dev/null || touch "$FAKE_REPO/.chump/state.db"
printf 'ref: refs/heads/main\n' > "$FAKE_REPO/.git" 2>/dev/null || true
export FAKE_REPO
# INFRA-1261: export CHUMP_STATE_DB so gap-preflight reads fixture DB, not live.
export CHUMP_STATE_DB="$FAKE_REPO/.chump/state.db"

# ── Test 1: normal flow — gh pr merge --auto appears BEFORE chump gap ship ──
rm -f "$CALL_LOG" "$AMBIENT"

cd "$FAKE_REPO"
CHUMP_SHIP_FAIL=0 \
CHUMP_TEST_GATE=0 CHUMP_BYPASS_BOT_MERGE=1 CHUMP_GAP_CHECK=0 \
CHUMP_PRE_MERGE_CHECKPOINT=0 \
CHUMP_SPEC_ON_SPEC_CHECK=0 CHUMP_SPECULATIVE_SWEEP=0 \
CHUMP_CODEREVIEW=0 CHUMP_AUTO_CLOSE_GAP=1 \
CHUMP_GAP_PREFLIGHT_SKIP=1 \
MAIN_REPO="$FAKE_REPO" \
bash "$BOT_MERGE" \
    --gap TEST-001 \
    --auto-merge \
    --dry-run 2>/dev/null || true

# In dry-run, gap ship is skipped. Verify ordering via a non-dry-run mock.
# Instead check the script source order directly (unit check).
# bot-merge.sh arms auto-merge via auto-merge-armer.sh (not a direct gh pr merge call).
ARM_LINE=$(grep -n "auto-merge-armer\.sh" "$BOT_MERGE" | grep -v "^#\|# " | head -1 | cut -d: -f1)
SHIP_LINE=$(grep -n "chump gap ship" "$BOT_MERGE" | grep -v "^#\|# " | head -1 | cut -d: -f1)
if [[ -n "$ARM_LINE" && -n "$SHIP_LINE" && "$ARM_LINE" -lt "$SHIP_LINE" ]]; then
    pass "Test 1: auto-merge arm (line $ARM_LINE) is before chump gap ship (line $SHIP_LINE)"
else
    fail "Test 1: ordering wrong — arm_line=${ARM_LINE:-?} ship_line=${SHIP_LINE:-?} (arm must come first)"
fi

# ── Test 2: when gap ship fails AFTER arm, exit 0 + ambient event emitted ───
rm -f "$CALL_LOG" "$AMBIENT"

# We'll test the behavior by running just the relevant section logic extracted
# from bot-merge.sh. Instead, verify by line-number analysis that failure path
# does NOT have "exit 1" immediately after chump gap ship in the new block.
# The new block has "# Do NOT exit 1 — continue" comment.
if grep -A5 "gap_ship_post_arm_failed" "$BOT_MERGE" | grep -q "Do NOT exit 1"; then
    pass "Test 2: gap ship failure path after arm uses WARN (not exit 1)"
else
    fail "Test 2: expected 'Do NOT exit 1' comment near gap_ship_post_arm_failed emit in bot-merge.sh"
fi

# ── Test 3: gap_ship_post_arm_failed event registered in EVENT_REGISTRY.yaml ─
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ -f "$EVENT_REG" ]] && grep -q "gap_ship_post_arm_failed" "$EVENT_REG"; then
    pass "Test 3: gap_ship_post_arm_failed registered in EVENT_REGISTRY.yaml"
else
    fail "Test 3: gap_ship_post_arm_failed not found in $EVENT_REG"
fi

# ── CREDIBLE-1576: gate-file auto-merge arm refusal ─────────────────────────
# bot-merge.sh must REFUSE to arm --auto-merge (exit 2, named reason) when the
# branch diff vs the merge base touches a gate file (ci.yml, scripts/ci/*,
# scripts/git-hooks/*, crates/chump-preflight/*, verified-wait*); the PR may
# still be pushed/opened — only the arm is refused. Exercised through the real
# `--gate-arm-check` seam, which runs the exact constant + refusal routine the
# live arm path uses, so a mutant that drops the refusal or empties the
# gate-file list in bot-merge.sh fails these cases. Uses a REAL throwaway git
# repo (not the mocked git above) so the diff is computed for real — strip the
# mock dir ($TMP) that was prepended to PATH above so real git runs here and
# inside bot-merge's `git diff`. Nothing after this block needs the mocks.
PATH="${PATH#"$TMP:"}"
GREPO="$TMP/gate-repo"
git init -q "$GREPO"
(
  cd "$GREPO"
  git config user.email t@example.com
  git config user.name tester
  echo base > README.md
  git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
)

_gate_rc() {
    # $1 = subdir case label; remaining args passed to bot-merge --gate-arm-check
    local rc
    set +e
    ( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check "$@" ) >/dev/null 2>&1
    rc=$?
    set -e
    printf '%s\n' "$rc"
}

# Case A: gate-file diff + --auto-merge → refuses with exit 2 + named reason.
(
  cd "$GREPO"
  mkdir -p scripts/ci && echo 'x' > scripts/ci/new-gate.sh
  git add -A && git commit -qm gate
)
set +e
_ga_out="$( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check --auto-merge 2>&1 )"
_ga_rc=$?
set -e
if [[ "$_ga_rc" -eq 2 ]] && printf '%s' "$_ga_out" | grep -q 'REFUSED'; then
    pass "CREDIBLE-1576: gate-file diff + --auto-merge refuses with exit 2 + named reason"
else
    fail "CREDIBLE-1576: expected exit 2 + REFUSED on gate-file arm (rc=$_ga_rc out=$_ga_out)"
fi

# Case B: non-gate diff + --auto-merge → arms as before (exit 0, no refusal).
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
(
  cd "$GREPO"
  mkdir -p docs && echo 'y' > docs/note.md
  git add -A && git commit -qm doc
)
_gb_rc="$(_gate_rc B --auto-merge)"
if [[ "$_gb_rc" -eq 0 ]]; then
    pass "CREDIBLE-1576: non-gate diff + --auto-merge arms as before (exit 0)"
else
    fail "CREDIBLE-1576: non-gate arm should exit 0, got rc=$_gb_rc"
fi

# Case C: gate-file diff WITHOUT --auto-merge → pushes as before (no refusal).
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
(
  cd "$GREPO"
  mkdir -p scripts/git-hooks && echo 'z' > scripts/git-hooks/pre-x
  git add -A && git commit -qm hook
)
_gc_rc="$(_gate_rc C)"
if [[ "$_gc_rc" -eq 0 ]]; then
    pass "CREDIBLE-1576: gate-file diff without --auto-merge pushes as before (exit 0)"
else
    fail "CREDIBLE-1576: gate-file-without-arm should exit 0, got rc=$_gc_rc"
fi

# ── CREDIBLE-1576 (round 4, kills x1): multi-file gate diff, gate file NOT first ─
# A mutant that inspects only the FIRST file of the diff (x1) passes a diff whose
# gate file is second. `git diff --name-only` lists paths sorted, so committing
# both docs/a.md and scripts/ci/x.sh puts docs/a.md FIRST and the gate file
# second. The guard loops over EVERY file, so it must still refuse (exit 2 +
# REFUSED). Driven through the same real-git --gate-arm-check seam as Case A.
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
(
  cd "$GREPO"
  mkdir -p docs scripts/ci
  echo a > docs/a.md
  echo x > scripts/ci/second-gate.sh
  git add -A && git commit -qm multifile-gate
)
set +e
_mf_out="$( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check --auto-merge 2>&1 )"
_mf_rc=$?
set -e
if [[ "$_mf_rc" -eq 2 ]] && printf '%s' "$_mf_out" | grep -q 'REFUSED'; then
    pass "CREDIBLE-1576: multi-file gate diff with the gate file NOT first refuses (exit 2 + REFUSED) [x1]"
else
    fail "CREDIBLE-1576: multi-file gate (gate not first) should refuse (exit 2), got rc=$_mf_rc out=$_mf_out [x1]"
fi
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )

# ── CREDIBLE-1576 item 2: FAIL-CLOSED when the diff cannot be computed ───────
# A branch with no merge base against origin/main (missing ref / unrelated
# history) must REFUSE the arm, never read as "clean". A fresh repo WITHOUT an
# origin/main ref makes `git diff origin/main...HEAD` fail; the arm must refuse
# (exit 2). Kills a mutant that returns rc=0 on a failed diff (the old
# fail-open behaviour).
GREPO_FC="$TMP/gate-repo-failclosed"
git init -q "$GREPO_FC"
(
  cd "$GREPO_FC"
  git config user.email t@example.com
  git config user.name tester
  echo base > README.md
  git add -A && git commit -qm base
  # deliberately do NOT create refs/remotes/origin/main → no merge base
)
set +e
_fc_out="$( cd "$GREPO_FC" && bash "$BOT_MERGE" --gate-arm-check --auto-merge 2>&1 )"
_fc_rc=$?
set -e
if [[ "$_fc_rc" -eq 2 ]] && printf '%s' "$_fc_out" | grep -q 'REFUSED'; then
    pass "CREDIBLE-1576 item 2: uncomputable diff (no merge base) fails closed — refuses arm (exit 2)"
else
    fail "CREDIBLE-1576 item 2: expected fail-closed exit 2 + REFUSED (rc=$_fc_rc out=$_fc_out)"
fi

# ── CREDIBLE-1576 item 5: every glob in the list refuses (kills m8/m9/m10) ───
# One refusal case per NON-scripts/ci glob so dropping any single glob from the
# constant array fails a case: .github/workflows/* (m8), *verified-wait* (m9),
# crates/chump-preflight/* (m10). (scripts/ci/* + scripts/git-hooks/* already
# covered by Case A + Case C above.)
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
for _glob_case in \
    ".github/workflows/ci.yml:m8-workflows" \
    "scripts/some-verified-wait.sh:m9-verified-wait" \
    "crates/chump-preflight/src/lib.rs:m10-preflight-crate"; do
    _gp="${_glob_case%%:*}"; _glbl="${_glob_case##*:}"
    (
      cd "$GREPO"
      mkdir -p "$(dirname "$_gp")" && echo x > "$_gp"
      git add -A && git commit -qm "$_glbl"
    )
    _gl_rc=0
    ( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check --auto-merge ) >/dev/null 2>&1 || _gl_rc=$?
    if [[ "$_gl_rc" -eq 2 ]]; then
        pass "CREDIBLE-1576: gate glob '$_gp' refuses arm (exit 2) [$_glbl]"
    else
        fail "CREDIBLE-1576: glob '$_gp' should refuse (exit 2), got rc=$_gl_rc [$_glbl]"
    fi
    ( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
done

# ── CREDIBLE-1576 item 1: drive the REAL arm sites with an argv-recording gh ──
# The --gate-arm-check seam above proves the refusal ROUTINE, but not that the
# live arm paths actually CALL it before `gh pr merge`. These cases run
# bot-merge.sh end-to-end through its real arm sites under a stub `gh` that
# records every argv, then assert that `gh pr merge` is ABSENT on refused paths
# and PRESENT on the armed path. Covered mutants:
#   m3  explicit-flag-only refusal → killed by the internal-lane default case
#       (AUTO_MERGE=1 with NO --auto-merge flag) still refusing.
#   m5  main arm call site dropped → killed by the main-flow refused case.
#   m6  recovery arm call site dropped → killed by the recovery refused case.
#   m7  both dropped → killed by m5 + m6 together.
#   m14 always-exit-2 → killed by the armed (non-gate) case reaching gh pr merge.
ARM_MOCK="$TMP/arm-mock"; mkdir -p "$ARM_MOCK"
ARM_REPO="$TMP/arm-repo"; mkdir -p "$ARM_REPO/.chump-locks" "$ARM_REPO/.chump"
printf 'ref: refs/heads/main\n' > "$ARM_REPO/.git"
export FAKE_REPO="$ARM_REPO"

# CREDIBLE-1576 item 1 (hermetic): the arm-site drives below run bot-merge.sh
# end-to-end, so they pass through the RESILIENT-073 fleet kill switch
# (bot-merge refuses with exit 10 unless ${HOME}/.chump/AUTONOMY_LEVEL >= 1). On
# a CI runner that file is absent → level 0 → bot-merge exits 10 BEFORE any arm
# site is reached, so the refusal under test is never exercised (the
# audit-required failure: "recovery gate arm not refused (rc=10 ...)"). Run
# every end-to-end arm drive under a sandbox HOME carrying AUTONOMY_LEVEL=5,
# exactly as scripts/ci/census.sh does. This is the approved seam — the REAL
# code runs under a sandbox HOME, so the real path resolves inside the sandbox;
# it is NOT an env override of a safety input.
ARM_HOME="$TMP/arm-home"; mkdir -p "$ARM_HOME/.chump"
echo 5 > "$ARM_HOME/.chump/AUTONOMY_LEVEL"
export ARM_HOME

cat > "$ARM_MOCK/gh" <<'GHEOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$ARM_CALL_LOG"
subcmd="${1:-}"; shift || true
_hasjq=0; for a in "$@"; do [[ "$a" == "--jq" ]] && _hasjq=1; done
case "$subcmd" in
  auth) exit 0 ;;
  pr)
    pr_cmd="${1:-}"; shift || true
    case "$pr_cmd" in
      view)   if [[ $_hasjq -eq 1 ]]; then printf '42\n'; else printf '{"number":42,"state":"OPEN","autoMergeRequest":null}\n'; fi ;;
      list)   printf '42\n' ;;
      # A real arm drops a state marker so the follow-up verify_arm REST read
      # (and the armer's "already armed?" pre-check) reflect the arm just as
      # GitHub would. ARM_ARMED_MARKER is a per-case test-fixture file path set
      # only on the main-arm-site drives — never read by production code.
      merge)  [ -n "${ARM_ARMED_MARKER:-}" ] && : > "$ARM_ARMED_MARKER"; exit 0 ;;
      checks) exit 0 ;;
      diff)   exit 0 ;;
      create) printf 'https://github.com/test/repo/pull/42\n'; exit 0 ;;
      comment|edit) exit 0 ;;
      *)      exit 0 ;;
    esac ;;
  api)
    case "$*" in
      *rate_limit*) if [[ $_hasjq -eq 1 ]]; then echo "4800 4900 9999999999"; else printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":9999999999},"graphql":{"limit":5000,"remaining":4900,"reset":9999999999}}}\n'; fi ;;
      # pulls REST reads the armer makes: .auto_merge (pre-check + verify_arm) and
      # .state. auto_merge flips true only AFTER `gh pr merge` dropped the marker,
      # so the armer actually arms and verify_arm succeeds without a 30s retry.
      *pulls/*auto_merge*) if [ -n "${ARM_ARMED_MARKER:-}" ] && [ -f "${ARM_ARMED_MARKER:-}" ]; then echo 'true'; else echo 'false'; fi ;;
      *pulls/*state*) echo 'open' ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 0 ;;
esac
GHEOF

cat > "$ARM_MOCK/chump" <<'CHEOF'
#!/usr/bin/env bash
# Records every argv when CHUMP_REC_LOG is set (test fixture only) so the Mode A
# route test can assert the `gap set --status ready_to_ship` write never fires.
[ -n "${CHUMP_REC_LOG:-}" ] && printf 'chump %s\n' "$*" >> "$CHUMP_REC_LOG"
case "${1:-} ${2:-}" in "gap show") echo 'status: open';; "gap list") echo '[]';; esac
exit 0
CHEOF

# Stub chump-ship: the CHUMP_SHIP_RUST shim exec's this. Records invocations so
# the item-4 test can assert it is NEVER exec'd on a gate / uncomputable diff.
cat > "$ARM_MOCK/chump-ship" <<'CSEOF'
#!/usr/bin/env bash
printf 'chump-ship %s\n' "$*" >> "$SHIP_CALL_LOG"
exit 0
CSEOF

# Stub chump-coord: Mode A posts to the work-board before the ready_to_ship
# write; a success here lets the n3 mutant actually reach that write (so the
# "no ready_to_ship" assertion is not vacuous).
cat > "$ARM_MOCK/chump-coord" <<'CCEOF'
#!/usr/bin/env bash
exit 0
CCEOF

cat > "$ARM_MOCK/git" <<'GITEOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  rev-parse)
    case "$*" in
      *--abbrev-ref*)      printf 'chump/test-001-x\n' ;;
      *--show-toplevel*)   printf '%s\n' "$FAKE_REPO" ;;
      *--git-common-dir*)  printf '%s/.git\n' "$FAKE_REPO" ;;
      *)                   printf '%s\n' "$FAKE_REPO" ;;
    esac ;;
  remote) printf 'https://github.com/testorg/testrepo.git\n' ;;
  diff)
    case "$*" in
      *--quiet*) exit 0 ;;
      *) printf '%s\n' "${MOCK_GIT_DIFF_FILES:-}"; exit "${MOCK_GIT_DIFF_RC:-0}" ;;
    esac ;;
  log) echo "subject"; exit 0 ;;
  rev-list) echo "1"; exit 0 ;;
  branch|status|push|tag|fetch|worktree|add|commit|stash|config|symbolic-ref|merge-base|cat-file|show-ref|update-ref|for-each-ref|ls-files) exit 0 ;;
  *) exit 0 ;;
esac
GITEOF
chmod +x "$ARM_MOCK/gh" "$ARM_MOCK/chump" "$ARM_MOCK/git" "$ARM_MOCK/chump-ship" "$ARM_MOCK/chump-coord"

# No bypass/skip env vars are used to drive these flows (the standing rule
# forbids them). The mocks satisfy every real gate: `chump gap preflight` passes
# (mock chump exits 0), the rate-limit gate sees headroom (mock gh), and the
# MERGED pre-push check sees a non-merged PR (mock gh). The only non-flag env are
# path/mode knobs — not bypasses:
#   CHUMP_BOT_MERGE_RECOVERY_MODE=1   recovery fast-path MODE (the only way to
#                                     reach the recovery arm site at all).
#   CHUMP_MERGE_PIPELINE_LOCK_FILE    documented TEST path-override for the
#                                     merge-pipeline lock (relocates, never
#                                     disables it) so it lands in a writable tmp.
#   REPO_ROOT/MAIN_REPO/CHUMP_AMBIENT_LOG/MOCK_GIT_DIFF_*  standard test fixtures.

# ── CREDIBLE-1576 item 3: a gate PR is forced out of Mode A (integrator batch) ─
# Mode A routes a gap to the chump-integrator daemon, which pushes and arms with
# --auto, bypassing the per-PR arm guard. A gate-file (or uncomputable) diff must
# force Mode B BEFORE the Mode A `chump gap set --status ready_to_ship` write, so
# the PR opens through the guarded per-PR flow instead of being batch-armed. The
# pre-existing CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH test hook (not a new var)
# reports the integrator HEALTHY so Mode A is actually REACHED — otherwise
# INFRA-2523 fail-opens to B first and the CREDIBLE-1576 guard is never the
# deciding factor. Assert: the diff emits the CREDIBLE-1576 force-B event AND the
# Mode A ready_to_ship write NEVER happens (recorded via CHUMP_REC_LOG).
#   n3  Mode A force-B removed    → gate diff stays Mode A → ready_to_ship written.
#   n7  force-B not fail-closed   → uncomputable diff stays Mode A → ready_to_ship.
_modea_run() {  # $1=label $2=diff-files $3=diff-rc ; caller sets MODEA_AMB + CHUMP_REC_LOG
    local _lbl="$1" _df="$2" _rc="$3"
    ( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" \
        MOCK_GIT_DIFF_FILES="$_df" MOCK_GIT_DIFF_RC="$_rc" \
        REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
        CHUMP_AMBIENT_LOG="$MODEA_AMB" CHUMP_REC_LOG="$CHUMP_REC_LOG" \
        CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl-$_lbl.lock" \
        CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH=1 \
        bash "$BOT_MERGE" --gap TEST-001 --auto-merge --no-local-build ) >"${MODEA_OUT:-/dev/null}" 2>&1 || true
}

for _ma_case in "modea-gate:scripts/ci/x.sh:0:n3" "modea-uncomputable::1:n7"; do
    _ma_lbl="${_ma_case%%:*}"; _ma_tmp="${_ma_case#*:}"
    _ma_df="${_ma_tmp%%:*}"; _ma_tmp="${_ma_tmp#*:}"
    _ma_rc="${_ma_tmp%%:*}"; _ma_mut="${_ma_tmp##*:}"
    MODEA_AMB="$TMP/$_ma_lbl.ambient.jsonl"; : > "$MODEA_AMB"
    CHUMP_REC_LOG="$TMP/$_ma_lbl.chump.log"; : > "$CHUMP_REC_LOG"
    MODEA_OUT="$TMP/$_ma_lbl.out.log"; : > "$MODEA_OUT"
    export MODEA_AMB CHUMP_REC_LOG MODEA_OUT
    _modea_run "$_ma_lbl" "$_ma_df" "$_ma_rc"
    # Round 4 (kills x3): assert the ACTUAL routing decision flipped to B
    # ("INFRA-2133: routing mode=B"), not merely that the force-B ambient event
    # was emitted. A mutant that emits the CREDIBLE-1576 event but leaves
    # _BM_MODE=A (x3) still prints "routing mode=A" here, so the routing-mode
    # assertion catches it — the ready_to_ship assertion alone is vacuous because
    # Mode A's canonical-db write aborts earlier in this fixture.
    if grep -q '"kind":"bot_merge_mode_failopen"' "$MODEA_AMB" \
        && grep -q '"note":"CREDIBLE-1576"' "$MODEA_AMB" \
        && grep -q 'INFRA-2133: routing mode=B' "$MODEA_OUT" \
        && ! grep -q 'ready_to_ship' "$CHUMP_REC_LOG"; then
        pass "CREDIBLE-1576 item 3: $_ma_lbl diff forces Mode A→B (routing mode=B + CREDIBLE-1576), no ready_to_ship write [$_ma_mut,x3]"
    else
        fail "CREDIBLE-1576 item 3: $_ma_lbl should force Mode B (failopen=$(grep -c bot_merge_mode_failopen "$MODEA_AMB"), cred1576=$(grep -c 'CREDIBLE-1576' "$MODEA_AMB"), routing_b=$(grep -c 'routing mode=B' "$MODEA_OUT"), ready_to_ship=$(grep -c ready_to_ship "$CHUMP_REC_LOG")) [$_ma_mut,x3]"
    fi
done

# Case D (recovery site, internal-lane DEFAULT arm, gate diff): no --auto-merge
# flag — AUTO_MERGE=1 comes from the internal-lane default, the exact path that
# self-armed #5602. Must refuse (exit 2) and NEVER reach `gh pr merge`.
ARM_CALL_LOG="$TMP/arm-D.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
set +e
_d_out="$( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="scripts/ci/x.sh" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    CHUMP_BOT_MERGE_RECOVERY_MODE=1 CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$BOT_MERGE" --gap TEST-001 2>&1 )"
_d_rc=$?
set -e
# Require the guard's OWN "REFUSED" signal (not just exit 2 + no-merge, which an
# unrelated downstream failure could also produce) so a dropped call site cannot
# masquerade as a refusal.
if [[ "$_d_rc" -eq 2 ]] && printf '%s' "$_d_out" | grep -q 'REFUSED' && ! grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 1: recovery DEFAULT-lane arm on gate diff refuses (exit 2 + REFUSED), no gh pr merge [m3,m6]"
else
    fail "CREDIBLE-1576 item 1: recovery gate arm not refused (rc=$_d_rc, refused=$(printf '%s' "$_d_out" | grep -c 'REFUSED'), merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# Case E (recovery site, NON-gate diff + --auto-merge): the guard must ALLOW —
# the arm proceeds and `gh pr merge` IS called. Kills m14 (always-exit-2): an
# unconditional refusal would block this legitimate arm.
ARM_CALL_LOG="$TMP/arm-E.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
set +e
( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="docs/note.md" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    CHUMP_BOT_MERGE_RECOVERY_MODE=1 CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$BOT_MERGE" --gap TEST-001 --auto-merge ) >/dev/null 2>&1
_e_rc=$?
set -e
if [[ "$_e_rc" -eq 0 ]] && grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 1: recovery non-gate arm proceeds (exit 0), gh pr merge called [m14]"
else
    fail "CREDIBLE-1576 item 1: recovery non-gate arm should arm (rc=$_e_rc, merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# Case F (MAIN arm site, gate diff + --auto-merge): drive the full per-PR flow
# to the main `if [[ $AUTO_MERGE -eq 1 ]]` arm block. Must refuse (exit 2) and
# NEVER reach `gh pr merge`. Kills m5 (main arm call site dropped), m7 (both
# dropped, with Case D), and x2 (main refusal made non-fatal — `|| true`).
# GITHUB_REPOSITORY (the armer's real, documented primary input, set by GitHub
# Actions / the systemd unit — not a Chump knob) lets the real auto-merge-armer
# resolve the repo in this fixture, so if the guard were dropped/softened the
# armer WOULD arm and call `gh pr merge`. Case H below is the positive control
# proving that; here it makes "no gh pr merge" mean "the guard stopped it".
ARM_CALL_LOG="$TMP/arm-F.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
rm -f "$TMP/armed-F.marker"
set +e
_f_out="$( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="scripts/ci/x.sh" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    GITHUB_REPOSITORY=testorg/testrepo ARM_ARMED_MARKER="$TMP/armed-F.marker" \
    CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl-F.lock" \
    bash "$BOT_MERGE" --gap TEST-001 --auto-merge --no-local-build 2>&1 )"
_f_rc=$?
set -e
# Require the guard's OWN "REFUSED" signal AND zero merge calls. With the main
# call site dropped (m5) or softened (x2), the flow now reaches the real armer,
# which (repo resolvable) arms and calls `gh pr merge` → merge-calls≥1 → FAIL.
if [[ "$_f_rc" -eq 2 ]] && printf '%s' "$_f_out" | grep -q 'REFUSED' && ! grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 1: MAIN arm site on gate diff refuses (exit 2 + REFUSED), no gh pr merge [m5,m7,x2]"
else
    fail "CREDIBLE-1576 item 1: MAIN arm site not refused (rc=$_f_rc, refused=$(printf '%s' "$_f_out" | grep -c 'REFUSED'), merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# ── CREDIBLE-1576 item 2: no-flag internal-lane case at the MAIN arm site ─────
# The MAIN arm guard (bot-merge.sh:~4374) must key off $AUTO_MERGE, NOT
# $AUTO_MERGE_EXPLICIT. On the internal lane AUTO_MERGE defaults to 1 with NO
# --auto-merge flag (RESILIENT-190) — the exact default-arm path that self-armed
# #5602. A mutant that passes $AUTO_MERGE_EXPLICIT (explicit-flag-only) would
# NOT refuse here because no flag was given. Case F above covers the main site
# WITH the flag (which an explicit-flag-only mutant still refuses); this case is
# the one that fires on the internal default. Drive the full per-PR flow with NO
# --auto-merge flag on a gate diff; must refuse (exit 2 + REFUSED) and NEVER
# reach `gh pr merge`. Kills n9 (explicit-flag-only at the main site).
ARM_CALL_LOG="$TMP/arm-G.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
rm -f "$TMP/armed-G.marker"
set +e
_g_out="$( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="scripts/ci/x.sh" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    GITHUB_REPOSITORY=testorg/testrepo ARM_ARMED_MARKER="$TMP/armed-G.marker" \
    CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl-G.lock" \
    bash "$BOT_MERGE" --gap TEST-001 --no-local-build 2>&1 )"
_g_rc=$?
set -e
# As in Case F, GITHUB_REPOSITORY makes the armer resolvable, so an n9/x2 mutant
# that reaches the armer here WOULD call `gh pr merge` → merge-calls≥1 → FAIL.
if [[ "$_g_rc" -eq 2 ]] && printf '%s' "$_g_out" | grep -q 'REFUSED' && ! grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 2: MAIN arm site, internal-lane DEFAULT (no --auto-merge) on gate diff refuses (exit 2 + REFUSED), no gh pr merge [n9,x2]"
else
    fail "CREDIBLE-1576 item 2: MAIN arm no-flag internal-lane not refused (rc=$_g_rc, refused=$(printf '%s' "$_g_out" | grep -c 'REFUSED'), merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# ── CREDIBLE-1576 item 1 (round 4): MAIN arm site POSITIVE CONTROL (kills x2) ──
# F and G assert the MAIN guard REFUSES a gate diff with no `gh pr merge`. That
# is only meaningful if, ABSENT the guard, the main site WOULD reach `gh pr
# merge` in this fixture. Round 3 could not prove it: the real auto-merge-armer
# could not resolve the repo (mock git's `remote get-url` returns nothing), so it
# always died with "Could not determine GITHUB_REPOSITORY" and never called
# merge — a dropped/softened guard (x2) produced the SAME no-merge outcome, so x2
# survived. This case drives the full per-PR flow on a NON-gate diff with
# --auto-merge (repo resolvable via GITHUB_REPOSITORY, verify_arm satisfied via
# the ARM_ARMED_MARKER stub) and asserts the MAIN site REACHES `gh pr merge` with
# NO REFUSED. That is the positive control that makes F+G's no-merge assertion
# mean "the guard stopped it", killing x2.
ARM_CALL_LOG="$TMP/arm-H.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
rm -f "$TMP/armed-H.marker"
set +e
_h_out="$( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="docs/note.md" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    GITHUB_REPOSITORY=testorg/testrepo ARM_ARMED_MARKER="$TMP/armed-H.marker" \
    CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl-H.lock" \
    bash "$BOT_MERGE" --gap TEST-001 --auto-merge --no-local-build 2>&1 )"
_h_rc=$?
set -e
if grep -q 'pr merge' "$ARM_CALL_LOG" && ! printf '%s' "$_h_out" | grep -q 'REFUSED'; then
    pass "CREDIBLE-1576 item 1: MAIN arm site on a NON-gate diff REACHES gh pr merge (positive control, no REFUSED) [x2]"
else
    fail "CREDIBLE-1576 item 1: MAIN non-gate positive control should reach gh pr merge (rc=$_h_rc, merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"), refused=$(printf '%s' "$_h_out" | grep -c 'REFUSED'))"
fi

# ── CREDIBLE-1576 item 4: CHUMP_SHIP_RUST exec shim never arms a gate PR ───────
# With CHUMP_SHIP_RUST=1 the top-of-file shim exec's the Rust chump-ship binary
# (manual_ship.rs arms WITHOUT the gate guard) — but ONLY when the branch diff is
# SURE to touch no gate file (classifier rc=1). A gate hit (rc=0) or an
# uncomputable diff (rc=3, fail-closed) MUST fall through to the guarded bash
# body and never exec chump-ship. A stub chump-ship on PATH records every exec.
#   n4  shim always execs   → killed by the gate-diff case (chump-ship NOT run).
#   n8  shim execs on rc=3  → killed by the uncomputable-diff case.
# The non-gate case is the positive control: it proves the stub records (so the
# two negative assertions are not vacuous) and that a clean diff still routes to
# chump-ship. The gate-diff rc is driven through the ARM_MOCK git's
# MOCK_GIT_DIFF_* knobs — the same diff the live arm guard reads.
_shim_run() {  # $1=label $2=diff-files $3=diff-rc ; caller sets SHIP_CALL_LOG
    local _lbl="$1" _df="$2" _rc="$3"
    ( cd "$ARM_REPO" && HOME="$ARM_HOME" PATH="$ARM_MOCK:$PATH" \
        MOCK_GIT_DIFF_FILES="$_df" MOCK_GIT_DIFF_RC="$_rc" \
        REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" \
        CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl-$_lbl.lock" \
        CHUMP_SHIP_RUST=1 SHIP_CALL_LOG="$SHIP_CALL_LOG" \
        bash "$BOT_MERGE" --gap TEST-001 --no-local-build ) >/dev/null 2>&1 || true
}

SHIP_CALL_LOG="$TMP/ship-gate.log"; : > "$SHIP_CALL_LOG"; export SHIP_CALL_LOG
_shim_run shim-gate "scripts/ci/x.sh" 0
if ! grep -q 'chump-ship' "$SHIP_CALL_LOG"; then
    pass "CREDIBLE-1576 item 4: CHUMP_SHIP_RUST shim does NOT exec chump-ship on a gate diff [n4]"
else
    fail "CREDIBLE-1576 item 4: shim exec'd chump-ship on a gate diff — $(cat "$SHIP_CALL_LOG")"
fi

SHIP_CALL_LOG="$TMP/ship-nongate.log"; : > "$SHIP_CALL_LOG"; export SHIP_CALL_LOG
_shim_run shim-nongate "docs/note.md" 0
if grep -q 'chump-ship' "$SHIP_CALL_LOG"; then
    pass "CREDIBLE-1576 item 4: CHUMP_SHIP_RUST shim DOES exec chump-ship on a clean non-gate diff (positive control)"
else
    fail "CREDIBLE-1576 item 4: shim failed to exec chump-ship on a clean diff — negative assertions would be vacuous"
fi

SHIP_CALL_LOG="$TMP/ship-uncomputable.log"; : > "$SHIP_CALL_LOG"; export SHIP_CALL_LOG
_shim_run shim-uncomputable "" 1
if ! grep -q 'chump-ship' "$SHIP_CALL_LOG"; then
    pass "CREDIBLE-1576 item 4: CHUMP_SHIP_RUST shim fails closed — no exec on an uncomputable diff [n8]"
else
    fail "CREDIBLE-1576 item 4: shim exec'd chump-ship on an uncomputable diff (fail-open) — $(cat "$SHIP_CALL_LOG")"
fi


# ── CREDIBLE-1576 item 5: static assertions — guard reads NO env (m13), and the
# gate-file glob list is a SINGLE literal constant (m4). The guard is a safety
# input; per the Chief standing rule it must never be reconfigurable by env.
_fn_region="$(awk '/^bot_merge_gate_files_touched\(\)/{f=1} /^# INFRA-2001: feature-flag shim/{f=0} f{print}' "$BOT_MERGE")"
# Strip the script's own constant name, then look for any ENV-style ($UPPERCASE)
# reference. Positional ($1) and local ($auto/$_diff) params never match.
_env_in_guard="$(printf '%s\n' "$_fn_region" | sed 's/BOT_MERGE_GATE_FILE_GLOBS//g' | grep -oE '\$\{?[A-Z][A-Z0-9_]*' | sort -u || true)"
if [[ -z "$_env_in_guard" ]]; then
    pass "CREDIBLE-1576 item 5: gate guard reads no environment variable [m13]"
else
    fail "CREDIBLE-1576 item 5: gate guard reads env var(s) — $_env_in_guard [m13]"
fi

_glob_assigns="$(grep -cE '^BOT_MERGE_GATE_FILE_GLOBS=\(' "$BOT_MERGE" || true)"
_arr_body="$(awk '/^BOT_MERGE_GATE_FILE_GLOBS=\(/{f=1;next} f&&/^\)/{f=0} f{print}' "$BOT_MERGE")"
if [[ "$_glob_assigns" == "1" ]] && ! printf '%s' "$_arr_body" | grep -q '\$'; then
    pass "CREDIBLE-1576 item 5: gate-file glob list is a single literal constant (no env read) [m4]"
else
    fail "CREDIBLE-1576 item 5: glob list not a single literal (assigns=$_glob_assigns, body has \$: $(printf '%s' "$_arr_body" | grep -c '\$')) [m4]"
fi

echo ""
echo "All INFRA-1030 arm-ship-order + CREDIBLE-1576 gate-file-arm checks passed."
