#!/usr/bin/env bash
# test-reaper-bot-merge-live.sh — RESILIENT-1609
#
# On 2026-10-16 18:46Z the worktree reaper removed ~/chump/.claude/worktrees/
# infra-8180 while `CHUMP_BOT_MERGE_RECOVERY_MODE=1 bot-merge --gap INFRA-8180`
# was mid-push from it (kind=bot_merge_crashed). The reaper's guards (active
# lease, fresh git index, uncommitted/unpushed work) all said "reapable": a
# recovery-mode ship takes no lease and leaves the git index idle during clippy.
#
# Fixture proof that the reapers now treat a LIVE bot-merge ship as active:
#   A. wt_has_live_bot_merge / worktree_is_active (shared guards)
#        - a fresh bot-merge-*.steps naming the worktree        -> protected
#        - ... naming only the gap the worktree basename implies -> protected
#        - the same file aged past the grace                     -> reapable
#        - a fresh steps file naming a DIFFERENT worktree        -> reapable
#        - a live process whose cwd is the worktree              -> protected
#        - ... after that process exits                          -> reapable
#        - ambient worktree_reaper_skipped_active carries reason=bot_merge_live
#   B. worktree-prune.sh --execute on a fake repo: the live worktree survives
#      (reason=bot_merge_live), its otherwise-identical sibling is pruned.
#   C. target-dir-reaper.sh --critical spares the live worktree's target/.
#   D. bot-merge.sh itself: the session line names the worktree; the steps file
#      is touched at every named step and every heartbeat tick, and
#      _bm_steps_touch really refreshes the mtime.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAFETY="$REPO_ROOT/scripts/coord/lib/worktree-reaper-safety.sh"
PRUNE="$REPO_ROOT/scripts/coord/worktree-prune.sh"
TDR="$REPO_ROOT/scripts/coord/target-dir-reaper.sh"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== RESILIENT-1609 reaper leaves live bot-merge ships alone ==="

TMP="$(mktemp -d /tmp/chump-1609-test.XXXXXX)"
SLEEPER=""
trap '[[ -n "$SLEEPER" ]] && kill "$SLEEPER" 2>/dev/null; rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
export CHUMP_WT_CWD_CACHE_S=0          # no lsof cache between assertions

age_file() { touch -t 202001010000 "$1" 2>/dev/null; }
amb_has()  { grep -q "$2" "$1" 2>/dev/null; }

# ── fake main repo with a bare "remote", so clean worktrees are pushed ────────
FAKE="$TMP/fake-repo"
mkdir -p "$FAKE/.claude/worktrees" "$FAKE/.chump-locks"
(
    cd "$FAKE" && git init -q -b main && git config user.email t@t.t && git config user.name t \
        && echo init > README.md && printf 'target/\n' > .gitignore && git add -A && git commit -qm init \
        && git clone --bare -q . "$TMP/remote.git" && git remote add origin "$TMP/remote.git" \
        && git fetch -q origin
) || { echo "FAIL: could not build fixture repo"; exit 2; }
AMB="$FAKE/.chump-locks/ambient.jsonl"; : > "$AMB"
export CHUMP_AMBIENT_LOG="$AMB"

mk_wt() {   # mk_wt <name> : a clean, pushed, old-index worktree with no lease
    local wt="$FAKE/.claude/worktrees/$1"
    git -C "$FAKE" worktree add -q -b "chump/$1" "$wt" origin/main >/dev/null 2>&1
    git -C "$wt" push -q origin "HEAD:refs/heads/chump/$1" 2>/dev/null
    git -C "$wt" branch -q --set-upstream-to="origin/chump/$1" 2>/dev/null || true
    local idx; idx="$(git -C "$wt" rev-parse --git-path index)"
    case "$idx" in /*) : ;; *) idx="$wt/$idx" ;; esac
    age_file "$idx"
    printf '%s' "$wt"
}

# `git status` (guard 3) can rewrite the index and so make it look fresh to guard 2;
# re-age it before every assertion so only the guard under test can protect.
reage() {
    local idx; idx="$(git -C "$1" rev-parse --git-path index)"
    case "$idx" in /*) : ;; *) idx="$1/$idx" ;; esac
    age_file "$idx"
}
active() { reage "$1"; worktree_is_active "$@"; }

# steps file as bot-merge writes it (session line first), keyed by PID.
mk_steps() {   # mk_steps <pid> <worktree-or-empty> <gap_ids>
    local f="$FAKE/.chump-locks/bot-merge-$1.steps"
    printf '{"ts":"2026-10-16T18:40:00Z","step":"session","transition":"start","elapsed_s":0,"pid":%s,"worktree":"%s","branch":"chump/x","gap_ids":"%s"}\n' \
        "$1" "$2" "$3" > "$f"
    printf '%s' "$f"
}

# shellcheck source=/dev/null
source "$SAFETY"

# ── A. shared guard ───────────────────────────────────────────────────────────
echo "--- A: wt_has_live_bot_merge / worktree_is_active ---"
WT="$(mk_wt infra-8180)"
if active "$WT" "$FAKE"; then fail "A0: control worktree already protected before any steps file"; else ok "A0: control worktree is reapable (clean, pushed, old index, no lease)"; fi

SF="$(mk_steps 4242 "$WT" "INFRA-8180")"
: > "$AMB"
if active "$WT" "$FAKE"; then ok "A1: fresh steps file naming the worktree -> protected"; else fail "A1: fresh steps file did not protect the worktree"; fi
amb_has "$AMB" '"kind":"worktree_reaper_skipped_active"' && amb_has "$AMB" '"reason":"bot_merge_live"' \
    && ok "A1: ambient worktree_reaper_skipped_active carries reason=bot_merge_live" \
    || fail "A1: ambient event/reason missing: $(cat "$AMB")"

age_file "$SF"
if active "$WT" "$FAKE"; then fail "A2: steps file older than the grace still protects"; else ok "A2: steps file older than the grace -> reapable again"; fi

SF="$(mk_steps 4243 "/somewhere/else/entirely" "INFRA-9999")"
if active "$WT" "$FAKE"; then fail "A3: a steps file for another worktree protected this one"; else ok "A3: fresh steps file for a different worktree/gap -> reapable"; fi
rm -f "$SF"

SF="$(mk_steps 4244 "" "INFRA-8180 INFRA-1")"
if active "$WT" "$FAKE"; then ok "A4: steps file naming only the gap (basename -> INFRA-8180) -> protected"; else fail "A4: gap-id match did not protect"; fi
rm -f "$SF"

SF="$(mk_steps 4245 "$WT" "INFRA-8180")"
touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)" "$SF"
if CHUMP_REAPER_BOT_MERGE_GRACE_MIN=5 active "$WT" "$FAKE"; then fail "A5: 10-min-old steps file protected under a 5-min grace"; else ok "A5: grace is configurable (10m-old file, 5m grace -> reapable)"; fi
if CHUMP_REAPER_BOT_MERGE_GRACE_MIN=30 active "$WT" "$FAKE"; then ok "A5: same file protected under a 30-min grace"; else fail "A5: 30-min grace did not protect a 10m-old file"; fi
rm -f "$SF"

# live process cwd
( cd "$WT" && exec sleep 120 ) &
SLEEPER=$!
sleep 1
: > "$AMB"
if active "$WT" "$FAKE"; then ok "A6: live process with cwd in the worktree -> protected"; else fail "A6: cwd process did not protect the worktree"; fi
amb_has "$AMB" '"reason":"bot_merge_live"' && ok "A6: reason=bot_merge_live emitted for the cwd guard" || fail "A6: reason missing: $(cat "$AMB")"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
sleep 1
if active "$WT" "$FAKE"; then fail "A7: still protected after the process exited"; else ok "A7: process exited -> reapable again"; fi

if CHUMP_REAPER_SAFETY_CHECK=0 active "$WT" "$FAKE"; then fail "A8: CHUMP_REAPER_SAFETY_CHECK=0 not honored"; else ok "A8: CHUMP_REAPER_SAFETY_CHECK=0 bypass honored"; fi

# ── B. worktree-prune.sh --execute ────────────────────────────────────────────
echo "--- B: worktree-prune.sh --execute spares the live ship ---"
LIVE="$(mk_wt infra-8180-live)"
DEAD="$(mk_wt infra-8180-dead)"
SF="$(mk_steps 5151 "$LIVE" "INFRA-8180")"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in *"pr list"*) echo '[]' ;; *) echo '{}' ;; esac
GH
chmod +x "$TMP/bin/gh"
: > "$AMB"
( cd "$FAKE" && PATH="$TMP/bin:$PATH" CHUMP_REAPER_SAFETY_CHECK=1 CHUMP_REAPER_INDEX_MMIN=0 \
    CHUMP_WORKTREE_BASE=".claude/worktrees" bash "$PRUNE" --execute >"$TMP/prune.out" 2>"$TMP/prune.err" )
if [[ -d "$LIVE" ]]; then ok "B1: live-ship worktree survived worktree-prune --execute"; else fail "B1: live-ship worktree was PRUNED (the 2026-10-16 bug)"; cat "$TMP/prune.out" "$TMP/prune.err" | head -20; fi
amb_has "$AMB" 'bot_merge_live' && ok "B2: worktree-prune emitted reason=bot_merge_live" || fail "B2: no bot_merge_live skip event from worktree-prune"
if [[ ! -d "$DEAD" ]]; then ok "B3: identical worktree with no live ship WAS pruned (the guard is not a blanket skip)"; else fail "B3: control worktree was not pruned - test is not discriminating"; fi

# ── C. target-dir-reaper --critical ───────────────────────────────────────────
echo "--- C: target-dir-reaper --critical spares the live ship's target/ ---"
SCAN="$TMP/scan"; mkdir -p "$SCAN"
git clone -q "$TMP/remote.git" "$SCAN/chump-live" 2>/dev/null; git clone -q "$TMP/remote.git" "$SCAN/chump-gone" 2>/dev/null
for d in chump-live chump-gone; do
    mkdir -p "$SCAN/$d/target"; echo bin > "$SCAN/$d/target/artifact"
    idx="$(git -C "$SCAN/$d" rev-parse --git-path index)"; case "$idx" in /*) : ;; *) idx="$SCAN/$d/$idx" ;; esac; age_file "$idx"
done
rm -f "$FAKE"/.chump-locks/bot-merge-*.steps
mk_steps 6161 "$SCAN/chump-live" "" >/dev/null
CHUMP_REPO="$FAKE" CHUMP_TARGET_REAPER_SCAN_GLOB="$SCAN/chump-*" bash "$TDR" --execute --force --critical >/dev/null 2>&1
if [[ -d "$SCAN/chump-live/target" ]]; then ok "C1: live-ship target/ survived the --critical reaper"; else fail "C1: live-ship target/ was reaped"; fi
if [[ ! -d "$SCAN/chump-gone/target" ]]; then ok "C2: control target/ was reaped (reaper still works)"; else fail "C2: control target/ not reaped - test not discriminating"; fi

# ── D. bot-merge.sh keeps its steps file fresh ────────────────────────────────
echo "--- D: bot-merge.sh touches / names its steps file ---"
grep -q '"step":"session","transition":"start".*"worktree":"%s"' "$BM" \
    && ok "D1: session line records the worktree (reaper correlation key)" || fail "D1: session line lacks the worktree field"
for fn in _bm_step_start _bm_step_done; do
    if sed -n "/^${fn}() {/,/^}/p" "$BM" | grep -q '_bm_steps_touch'; then ok "D2: $fn touches the steps file"; else fail "D2: $fn does not touch the steps file"; fi
done
if grep -q '_hb_elapsed=\$(( _hb_elapsed + _hb_interval ))' "$BM" \
   && sed -n '/_hb_elapsed=\$(( _hb_elapsed + _hb_interval ))/,+2p' "$BM" | grep -q '_bm_steps_touch'; then
    ok "D3: heartbeat tick touches the steps file (a long clippy stays 'live')"
else
    fail "D3: heartbeat tick does not touch the steps file"
fi
sed -n '/^_bm_steps_touch() {/,/^}/p' "$BM" > "$TMP/touch_fn.sh"
if [[ -s "$TMP/touch_fn.sh" ]]; then
    ( source "$TMP/touch_fn.sh"
      _BM_STEPS_FILE="$TMP/t.steps"; echo '{}' > "$_BM_STEPS_FILE"; age_file "$_BM_STEPS_FILE"
      before="$(find "$_BM_STEPS_FILE" -mmin -1 | wc -l | tr -d ' ')"
      _bm_steps_touch
      after="$(find "$_BM_STEPS_FILE" -mmin -1 | wc -l | tr -d ' ')"
      [[ "$before" == "0" && "$after" == "1" ]] ) \
        && ok "D4: _bm_steps_touch refreshes an aged steps file" || fail "D4: _bm_steps_touch did not refresh the mtime"
else
    fail "D4: _bm_steps_touch not found in bot-merge.sh"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
