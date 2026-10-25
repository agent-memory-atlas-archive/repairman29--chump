#!/usr/bin/env bash
# mission-scoreboard.sh (MISSION-014) — READ-ONLY scoreboard for the operative
# mission (MISSION-010). The one honest measure of whether Chump is moving
# toward zero-human-touch software delivery. Pairs with docs/MISSION.md.
#
# No state mutation. Safe to run anytime. Exit 0 = HANDS-OFF/ON-TRACK,
# exit 1 = DRIFTING/STALLED (so a conductor loop can gate on $?).
#
# Modes:
#   (default)     single-repo view focused on BEAST (the proof)
#   --per-repo    per-repo block for every row in `chump repos list` + aggregate
#   --aggregate   aggregate-only rollup (no per-repo blocks)
#
# Follow-up: port to `chump kpi mission` (Rust) once metrics stabilize.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" 2>/dev/null || true

MODE="default"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --per-repo)  MODE="per-repo"; shift ;;
        --aggregate) MODE="aggregate"; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0 ;;
        *) echo "[mission-scoreboard] unknown flag: $1" >&2; exit 2 ;;
    esac
done

BEAST="repairman29/BEAST-MODE"
ACTIVE_MISSION="$(cat "$HOME/.chump/ACTIVE_MISSION" 2>/dev/null || echo MISSION-010)"
now=$(date -u +%s)

# Portable date helpers (BSD/macOS first, GNU fallback)
days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null; }
iso_to_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0; }

wk="$(days_ago 7)"; day="$(days_ago 1)"

# MISSION-037: per-repo block. Prints ①/②/③ for one repo.
# Args: $1 = owner/repo
score_one_repo() {
    local repo="$1"
    local beast_ships ratio_str="n/a" linked_count=0 last_ship_age="?"

    # ① binary: zero-touch ship this week (we don't differentiate touched vs zero-touch
    # at the per-repo grain — just "did Chump merge anything there?")
    beast_ships=$(gh pr list -R "$repo" --state merged --search "merged:>=$wk" --json number --jq 'length' 2>/dev/null)
    beast_ships="${beast_ships:-0}"

    # ② mission-link rate for THIS repo (count gaps tagged for this repo)
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
        linked_count=$(sqlite3 .chump/state.db \
            "SELECT COUNT(*) FROM gaps WHERE skills_required LIKE '%external_repo:${repo}%' AND status='open';" \
            2>/dev/null || echo 0)
    fi

    # ④ last-merge age in this repo (in days, to keep output tight)
    local last_merge_iso
    last_merge_iso=$(gh pr list -R "$repo" --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt' 2>/dev/null)
    if [[ -n "$last_merge_iso" ]]; then
        local last_ep age_days
        last_ep=$(iso_to_epoch "$last_merge_iso")
        age_days=$(( (now - last_ep) / 86400 ))
        last_ship_age="${age_days}d"
    fi

    printf "  %-35s  ships(7d)=%-3s  open_gaps_tagged=%-3s  last_ship=%s\n" \
        "$repo" "$beast_ships" "$linked_count" "$last_ship_age"

    # Return aggregate state via stdout-only-channel? Use external accumulators.
    AGG_SHIPS_WK=$((AGG_SHIPS_WK + beast_ships))
    AGG_TAGGED=$((AGG_TAGGED + linked_count))
    if [[ "$beast_ships" -gt 0 ]]; then
        AGG_REPOS_SHIPPED_WK=$((AGG_REPOS_SHIPPED_WK + 1))
    fi
}

# Enumerate tracked repos. Returns owner/repo per line, or empty if unavailable.
list_tracked_repos() {
    if command -v chump >/dev/null 2>&1; then
        # chump repos list --json gives well-shaped output; fall back to raw column scan
        chump repos list --json 2>/dev/null \
            | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
    if isinstance(rows, list):
        for r in rows:
            rid = r.get('id') if isinstance(r, dict) else None
            if rid: print(rid)
except Exception:
    pass
" 2>/dev/null
    fi
    # Fallback: direct SQL (works even if CLI subcommand not wired in old binary)
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
        sqlite3 .chump/state.db "SELECT id FROM repos WHERE status='active';" 2>/dev/null
    fi
}

echo "═══ CHUMP MISSION SCOREBOARD ═══  $(date -u +%Y-%m-%dT%H:%MZ)"
echo "Mission: $ACTIVE_MISSION — zero-human-touch software delivery; proof: $BEAST 0→1"
echo "(read-only; see docs/MISSION.md)"
echo

# ── MISSION-037: per-repo + aggregate rollup ─────────────────────────────────
# When --per-repo or --aggregate, scoreboard rolls up across every active repo
# (from `chump repos list`, the MISSION-033 derived index) instead of focusing
# solely on BEAST. Exits 0 when at least one repo has shipped this week AND
# tagged-gap coverage is non-zero across the fleet; exits 1 otherwise.
if [[ "$MODE" == "per-repo" || "$MODE" == "aggregate" ]]; then
    AGG_SHIPS_WK=0
    AGG_TAGGED=0
    AGG_REPOS_SHIPPED_WK=0
    AGG_REPO_COUNT=0

    # Pre-flight: enumerate. Always include BEAST as the canonical repo even
    # if the repos table is empty (today's reality before MISSION-041 backfill
    # flows through gap import).
    repo_list_tmp="$(list_tracked_repos 2>/dev/null || true)"
    if [[ -z "$repo_list_tmp" ]]; then
        repo_list_tmp="$BEAST"
        echo "(no repos in registry — falling back to BEAST canonical: $BEAST)"
        echo
    fi

    if [[ "$MODE" == "per-repo" ]]; then
        echo "═══ PER-REPO ═══"
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            AGG_REPO_COUNT=$((AGG_REPO_COUNT + 1))
            score_one_repo "$r"
        done <<< "$repo_list_tmp"
        echo
    else
        # aggregate-only: still iterate but suppress per-repo output by redirecting
        # the printf inside score_one_repo. Cheaper: just count + sum directly.
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            AGG_REPO_COUNT=$((AGG_REPO_COUNT + 1))
            ships_q=$(gh pr list -R "$r" --state merged --search "merged:>=$wk" --json number --jq 'length' 2>/dev/null)
            ships_q="${ships_q:-0}"
            AGG_SHIPS_WK=$((AGG_SHIPS_WK + ships_q))
            if [[ "$ships_q" -gt 0 ]]; then
                AGG_REPOS_SHIPPED_WK=$((AGG_REPOS_SHIPPED_WK + 1))
            fi
            if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
                tagged_q=$(sqlite3 .chump/state.db \
                    "SELECT COUNT(*) FROM gaps WHERE skills_required LIKE '%external_repo:${r}%' AND status='open';" \
                    2>/dev/null || echo 0)
                AGG_TAGGED=$((AGG_TAGGED + tagged_q))
            fi
        done <<< "$repo_list_tmp"
    fi

    echo "═══ AGGREGATE (across $AGG_REPO_COUNT tracked repos) ═══"
    if [[ "$AGG_REPO_COUNT" -gt 0 ]]; then
        pct=$(( AGG_REPOS_SHIPPED_WK * 100 / AGG_REPO_COUNT ))
    else
        pct=0
    fi
    echo "  ① mission ratio (repo-coverage): $AGG_REPOS_SHIPPED_WK of $AGG_REPO_COUNT shipped this week (${pct}%)"
    echo "  ② total ships across fleet (7d):  $AGG_SHIPS_WK"
    echo "  ③ open gaps with external_repo: tag: $AGG_TAGGED"
    echo

    echo "═══ VERDICT ═══"
    if [[ "$AGG_REPOS_SHIPPED_WK" -gt 0 && "$AGG_TAGGED" -gt 0 ]]; then
        echo "  🟢 MISSION ACTIVE — $AGG_REPOS_SHIPPED_WK repo(s) shipping, $AGG_TAGGED open routable gaps. Watch BEAST for zero-touch."
        exit 0
    elif [[ "$AGG_REPOS_SHIPPED_WK" -gt 0 ]]; then
        echo "  🟡 SHIPPING-BUT-UNROUTED — repos active, but $AGG_TAGGED gaps tagged for routing. Backfill external_repo: tags (MISSION-041)."
        exit 1
    else
        echo "  🔴 NO REPO ACTIVITY — no tracked repo merged a PR this week. The mission isn't moving."
        exit 1
    fi
fi

# ── ① THE BINARY: zero-touch BEAST ship this week ───────────────────────────
# COTG-3.3/INFRA-3496: "merged" is NOT "zero-touch". The mission is achieved only by an
# AGENT-authored merge, provable by the `Chump-Agent:` commit trailer (the fleet's
# autonomous signature — the producer is on every fleet commit, INFRA-3479). Count
# merges, then classify each by the trailer; a merge whose commits lack it is
# human-in-loop and does NOT count toward the binary. No longer "instrumented later" —
# this IS the instrumentation.
beast_prs=$(gh pr list -R "$BEAST" --state merged --search "merged:>=$wk" --json number --jq '.[].number' 2>/dev/null)
beast=0; beast_zt=0
for _pr in $beast_prs; do
  [ -z "$_pr" ] && continue
  beast=$((beast+1))
  if gh pr view "$_pr" -R "$BEAST" --json commits --jq '.commits[].messageBody' 2>/dev/null \
       | grep -qE '^Chump-Agent:'; then
    beast_zt=$((beast_zt+1))
  fi
done
echo "① THE BINARY — zero-human-touch PR merged in $BEAST this week?"
if [ "$beast_zt" -gt 0 ]; then
  echo "     ✅ YES — $beast_zt zero-touch (Chump-Agent) of $beast BEAST merge(s) last 7d"
elif [ "$beast" -gt 0 ]; then
  echo "     ❌ NO  ($beast BEAST merge(s) last 7d, but 0 carry the Chump-Agent trailer — human-in-loop, not zero-touch)"
else
  echo "     ❌ NO  (BEAST merges last 7d: 0)  ← the mission is NOT yet achieved"
fi

# MISSION-066: persist ① so repeatability (not just a single lucky run) can be
# verified across runs via `chump kpi report --mission-binary`, mirroring the
# mission_grade ambient pattern used for pillar history.
mkdir -p .chump-locks 2>/dev/null || true
printf '{"ts":"%s","kind":"mission_binary_check","repo":"%s","beast_merges_7d":%d,"beast_zero_touch_7d":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BEAST" "$beast" "$beast_zt" \
  >> .chump-locks/ambient.jsonl 2>/dev/null || true
echo

# ── ② Mission-ship ratio (24h) ──────────────────────────────────────────────
# CREDIBLE-238: R&D is intentionally excluded from the Gate-2 mission-ship
# ratio numerator (while remaining in pillar inventory and pillar_coverage so
# balance_restock can still detect R&D starvation). WHY: R&D's valid output is
# frequently a NO-GO (killing an experiment counts as a successful R&D run).
# Counting R&D merges in the mission-ship numerator would make the 2/3 scaling
# gate gameable — the fleet could clear Gate 2 by running and killing
# experiments instead of shipping mission-linked outcomes. Do not "clean up"
# this exclusion in a future refactor.
total=0; mission=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  total=$((total+1))
  if grep -qiE '(^|[^A-Za-z])(R&D|RND):' <<<"$t"; then
    continue
  fi
  gid=$(printf '%s' "$t" | grep -oE '[A-Z]+-[0-9]+' | head -1)
  [ -z "$gid" ] && continue
  case "$gid" in RND-*|RD-*) continue;; esac
  _gap_json="$(chump gap show "$gid" --json 2>/dev/null || true)"
  if grep -qiE '"(domain|pillar)":[[:space:]]*"(RND|R&D)"|"title":[[:space:]]*"(R&D|RND):' <<<"$_gap_json"; then
    continue
  fi
  case "$gid" in MISSION-*) mission=$((mission+1)); continue;; esac
  if grep -qiE "\"domain\":[[:space:]]*\"MISSION\"|$ACTIVE_MISSION|\"outcome_id\":[[:space:]]*\"[^\"]" <<<"$_gap_json"; then
    mission=$((mission+1))
  fi
done < <(gh pr list --state merged --search "merged:>=$day" --json title --jq '.[].title' 2>/dev/null)
ratio="n/a"; [ "$total" -gt 0 ] && ratio="$mission/$total"
echo "② Mission-ship ratio (24h): $ratio   (target ≥ 2/3 — mission-linked merges ÷ total; R&D excluded)"
echo

# ── ③ Deploy-lag (Goal 1 / MISSION-012 proxy) ───────────────────────────────
bin="$(command -v chump 2>/dev/null || echo /opt/homebrew/bin/chump)"
# ~/.local/bin/chump is a symlink; un-resolved stat reads its creation date, not the build.
bin="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
# GNU stat's `-f` means "report on the filesystem" (prints unrelated fields,
# exit 0) rather than erroring, so it must NOT be tried first or the `-c %Y`
# (GNU mtime) fallback never fires on Linux — try GNU form first, then BSD.
binep=$(stat -L -c %Y "$bin" 2>/dev/null || stat -L -f %m "$bin" 2>/dev/null || echo 0)
binbuilt=$(date -u -r "$binep" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$binep" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo '?')
# CREDIBLE-293: FRESHNESS SLA, not an instant snapshot. Comparing the running
# binary against origin/main's tip at the exact instant this script runs
# false-positives on ordinary auto-deploy lag: main moves every ~10-20 min,
# the auto-deploy cycle runs every ~20 min, so main is "ahead" of the last
# deploy most of the time by design — that isn't a regression. Only flag a
# real regression when the binary has been behind for LONGER than one
# deploy-cadence-plus-build-time window (default 30 min; override via
# MISSION_SCOREBOARD_DEPLOY_SLA_SECONDS).
DEPLOY_SLA_SECONDS="${MISSION_SCOREBOARD_DEPLOY_SLA_SECONDS:-1800}"
main_ref="origin/main"
git rev-parse --verify "$main_ref" >/dev/null 2>&1 || main_ref="main"
git rev-parse --verify "$main_ref" >/dev/null 2>&1 || main_ref="HEAD"
main_moved_epoch=$(git log -1 --format=%ct "$main_ref" 2>/dev/null || echo 0)
lag_since_main_move=$(( now - main_moved_epoch ))
autodeploy=0
if [ "$binep" -ge "$main_moved_epoch" ]; then
  autodeploy=1   # binary already built at/after the latest main-move: current.
elif [ "$lag_since_main_move" -le "$DEPLOY_SLA_SECONDS" ]; then
  autodeploy=1   # main moved recently; within the normal auto-deploy cadence window.
fi
echo "③ Deploy — do merged fixes reach the running binary automatically?  (binary built $binbuilt)"
if [ "$autodeploy" -eq 1 ]; then
  echo "     ✅ within freshness SLA (deploy-lag ${lag_since_main_move}s ≤ ${DEPLOY_SLA_SECONDS}s cadence window)"
  stale=0
else
  echo "     ❌ STALE — deploy-lag ${lag_since_main_move}s exceeds ${DEPLOY_SLA_SECONDS}s SLA — merges are inert until redeploy. THE MULTIPLIER."
  stale=1
fi
echo

# ── ④ Fleet liveness ────────────────────────────────────────────────────────
lm=$(gh pr list --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt' 2>/dev/null)
lmep=$(iso_to_epoch "$lm"); agem=$(( (now - lmep) / 60 ))
ships=$(gh pr list --state merged --search "merged:>=$day" --json number --jq 'length' 2>/dev/null)
echo "④ Fleet liveness: last merge ${agem}m ago | merges last 24h: ${ships:-?}"
echo

# ── ⑤ BEAST-MODE prerequisite readiness (MISSION-066) ───────────────────────
# MISSION-019 through MISSION-024 (the MISSION-015 slice) are individual
# "verify fleet can <pipeline step>" gaps that prove Chump can actually pick,
# clone, commit, push, PR, and monitor against $BEAST. Each is tagged
# external_repo:$BEAST, which the picker (crates/chump-coord/src/worker/
# capability.rs, INFRA-2113) skips unless CHUMP_EXTERNAL_REPO_PICK_OK=1 is
# set in the claiming session's env. If that gate never opens, these gaps
# rot open with 0 implementation commits and ① above can never turn YES on
# its own — this section makes that stall visible instead of eyeballed.
prereq_open=0
prereq_no_commits=0
prereq_stuck_ids=""
if command -v sqlite3 >/dev/null 2>&1 && [[ -f .chump/state.db ]]; then
    while IFS= read -r gid; do
        [[ -z "$gid" ]] && continue
        prereq_open=$((prereq_open+1))
        commit_count=$(git log --oneline --grep "^${gid}:" -E 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${commit_count:-0}" -eq 0 ]]; then
            prereq_no_commits=$((prereq_no_commits+1))
            prereq_stuck_ids="${prereq_stuck_ids}${prereq_stuck_ids:+, }${gid}"
        fi
    done < <(sqlite3 .chump/state.db \
        "SELECT id FROM gaps WHERE skills_required LIKE '%external_repo:${BEAST}%' AND status='open' ORDER BY id;" 2>/dev/null)
fi
pick_gate="closed"
[[ "${CHUMP_EXTERNAL_REPO_PICK_OK:-0}" == "1" ]] && pick_gate="open"

# Consecutive-cycle stall streak: walk beast_prereq_check history in
# ambient.jsonl backwards from the most recent entry and count how many
# runs in a row reported zero_commit>0. This turns "MISSION ① = NO for the
# Nth consecutive cycle" (previously an eyeballed claim in gap titles) into
# a derived, testable number. Bash-3.2-safe: no mapfile/associative arrays.
AMBIENT_FILE=".chump-locks/ambient.jsonl"
prereq_streak=0
if [[ -f "$AMBIENT_FILE" ]] && command -v tac >/dev/null 2>&1; then
    while IFS= read -r zc; do
        [[ -z "$zc" ]] && continue
        [[ "$zc" -gt 0 ]] || break
        prereq_streak=$((prereq_streak+1))
    done < <(tac "$AMBIENT_FILE" 2>/dev/null | grep -F '"kind":"beast_prereq_check"' \
        | sed -n 's/.*"zero_commit":\([0-9]*\).*/\1/p')
elif [[ -f "$AMBIENT_FILE" ]]; then
    # macOS/BSD has no tac by default; fall back to tail -r.
    while IFS= read -r zc; do
        [[ -z "$zc" ]] && continue
        [[ "$zc" -gt 0 ]] || break
        prereq_streak=$((prereq_streak+1))
    done < <(tail -r "$AMBIENT_FILE" 2>/dev/null | grep -F '"kind":"beast_prereq_check"' \
        | sed -n 's/.*"zero_commit":\([0-9]*\).*/\1/p')
fi
# This run's own result extends (or breaks) the streak read from history.
if [[ "$prereq_no_commits" -gt 0 ]]; then
    prereq_streak=$((prereq_streak+1))
else
    prereq_streak=0
fi

echo "⑤ BEAST-MODE prerequisite readiness (MISSION-019..024 slice):"
echo "     open=$prereq_open  zero-commit=$prereq_no_commits  pick-gate=$pick_gate (CHUMP_EXTERNAL_REPO_PICK_OK)"
if [[ "$prereq_no_commits" -gt 0 ]]; then
    echo "     ⚠️  stuck (0 implementation commits): $prereq_stuck_ids"
    echo "     streak: $prereq_streak consecutive cycle(s) with zero-commit stall"
    if [[ "$pick_gate" == "closed" ]]; then
        echo "     → root cause: CHUMP_EXTERNAL_REPO_PICK_OK is unset here; standard fleet workers skip external_repo: tagged gaps (INFRA-2113)."
    fi
    if [[ "$prereq_streak" -ge 10 ]]; then
        echo "     🚨 ESCALATION: stall has persisted $prereq_streak consecutive cycles with no root-cause fix — refiling MISSION-066 without opening the pick-gate or reassigning the prerequisite work will not move MISSION ①."
    fi
else
    echo "     streak: 0 (no zero-commit prerequisites this cycle)"
fi
mkdir -p .chump-locks 2>/dev/null || true
printf '{"ts":"%s","kind":"beast_prereq_check","open":%d,"zero_commit":%d,"pick_gate":"%s","streak":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$prereq_open" "$prereq_no_commits" "$pick_gate" "$prereq_streak" \
    >> .chump-locks/ambient.jsonl 2>/dev/null || true
echo

# ── Verdict ─────────────────────────────────────────────────────────────────
echo "═══ VERDICT ═══"
rc=0
need=$(( (total + 2) / 3 ))   # ceil(total*2/3) lower bound for "mission-weighted"
if [ "$beast_zt" -gt 0 ]; then
  echo "  🟢 HANDS-OFF territory — BEAST shipping ZERO-TOUCH ($beast_zt/$beast agent-authored). Verify repeatability, then dial autonomy up."
elif [ "$beast" -gt 0 ]; then
  echo "  🟠 DRIFTING — BEAST has $beast merge(s) but 0 zero-touch (all human-in-loop, no Chump-Agent trailer). The binary is NOT achieved; close the autonomous-ship gap."; rc=1
elif [ "$agem" -gt 180 ] && [ "$lmep" -gt 0 ]; then
  echo "  🔴 STALLED — no merge in ${agem}m. Unblock the queue before anything else."; rc=1
elif [ "$stale" -eq 1 ]; then
  echo "  🟠 DRIFTING — fleet ships but fixes don't DEPLOY (MISSION-012). The mission is inert until self-deploy lands."; rc=1
elif [ "$total" -gt 0 ] && [ "$mission" -lt "$need" ]; then
  echo "  🟠 DRIFTING — work-mix is mostly self-maintenance ($ratio mission). Refill the backlog with mission gaps."; rc=1
else
  echo "  🟡 ON-TRACK — mission-weighted + deploying, but BEAST not yet shipping. Push the onboard→BEAST path."
fi
# Next lever derives from the same signals as the verdict — never name a goal a line
# above this already reported done.
if [ "$stale" -eq 1 ]; then
  nextlever="MISSION-012 (self-deploy) — until merges go live, the scoreboard can't move."
elif [ "$beast_zt" -eq 0 ]; then
  nextlever="MISSION-066 (zero-touch BEAST proof) — make ① YES."
elif [ "$total" -gt 0 ] && [ "$mission" -lt "$need" ]; then
  nextlever="mission-ship ratio ② ($ratio, target ≥ ⅔) — the scaling gate."
else
  nextlever="MISSION-066 repeatability — keep ① YES with autonomy dialed up."
fi
echo "  Next lever: $nextlever"
exit "$rc"
