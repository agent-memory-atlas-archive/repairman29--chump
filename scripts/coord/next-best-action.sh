#!/usr/bin/env bash
# next-best-action.sh — the ADVISORY next-best-action router (v0).
#
# The shape of the thing that will one day replace the human ATC/dispatcher:
# given the shared fleet state, it COMPUTES and EMITS a ranked list of
# next-best-actions by EV = (value if it works) x P(success). It RECOMMENDS and
# LOGS only — it does NOT dispatch a worker, merge a PR, or restart an organ.
# Autonomy is earned only AFTER its recommendations prove calibrated (same rule
# as the pr-book casino: price first, settle, and only then act).
#
# It does NOT rebuild the scheduler. It CONSUMES the sighted organs that already
# price and pick work:
#   - pr-book-model.jq        P(merge) per open PR + the cheapest EV-raising action
#   - ~/.chump/faculty-status.json   the 11-faculty OS self-portrait (frontier)
#   - ~/.chump/journey-odds.json     per-journey P(success) board (sibling agent; optional)
#   - chump gap list --json          open gaps by priority
#   - systemctl ... --state=failed   dead organs (a dark capability)
#
# OUTPUT:
#   - ~/.chump/next-best-action.json   full ranked list (machine-readable)
#   - stdout                            the top 3, operator-readable
#   - ambient event kind=next_best_action  (the top pick, for the nervous system)
#
# EV SCORING IS TRANSPARENT, NOT A BLACK BOX. Every action-type's `value`,
# `p_default`, `who`, and `need_to_know` live in the ACTION_TABLE jq object
# below. EV = value x p_success. value is a 0..100 "points if it works" score;
# p_success is the real per-candidate probability (PR price, organ-restart odds,
# journey odds) or the table default when no live signal exists.
#
# Usage:
#   scripts/coord/next-best-action.sh            # compute, write, print top 3, emit
#   scripts/coord/next-best-action.sh --no-emit  # everything except the ambient event
#   scripts/coord/next-best-action.sh --top N     # print top N (default 3)
#
# Env:
#   CHUMP_NBA_OUT       output json (default ~/.chump/next-best-action.json)
#   CHUMP_JOURNEY_ODDS  journey-odds json (default ~/.chump/journey-odds.json)
#   CHUMP_FACULTY_OUT   faculty-status json (default ~/.chump/faculty-status.json)
#   CHUMP_AMBIENT_LOG   ambient jsonl (default REPO/.chump-locks/ambient.jsonl)
#   CHUMP_FLEET_TARGET_SIZE  expected worker-pane count (default 2; mirrors
#                            fleet-autopilot.sh's ensure_worker_pool target)
set -uo pipefail

# RESILIENT-422: pane coverage pct — the fraction of the EXPECTED chump-fleet
# worker panes that are actually alive right now (0..100). This is the one
# operational signal pr-book/journey-odds don't carry: a worker-pool that's
# down doesn't fail a PR-merge bet, it silently starves dispatch_worker_p0/p1
# bets of the capacity to ever execute. Without it, "dispatch the top P0 gap"
# scores the SAME EV whether 0 or 2 workers are alive to pick it up — vibes,
# not a calibratable prediction. Wired in as a multiplicative discount on the
# dispatch_worker_* p_success below (step 4) so a starved pool measurably
# drags those bets' EV down, and the raw pct is also written into the output
# board so it can be joined against outcomes later (same "price now, settle
# later" discipline as pr-book.sh / calibration.sh).
pane_coverage_pct() {
  local target="${CHUMP_FLEET_TARGET_SIZE:-2}"
  local live=0
  if tmux has-session -t chump-fleet 2>/dev/null; then
    live="$(tmux list-panes -t chump-fleet -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || true)"
  fi
  [[ "$live" =~ ^[0-9]+$ ]] || live=0
  # list-panes includes the control pane (fleet.0) — subtract it so we count
  # WORKER panes only, same accounting ensure_worker_pool uses (live >= target+1).
  local workers=$(( live > 0 ? live - 1 : 0 ))
  local pct=0
  if [[ "$target" =~ ^[0-9]+$ ]] && (( target > 0 )); then
    pct=$(( (workers * 100) / target ))
  else
    pct=100
  fi
  (( pct > 100 )) && pct=100
  (( pct < 0 )) && pct=0
  echo "$pct"
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Anchor to the git toplevel of the WORKING DIR, not the script's own tree (the
# pr-pulse idiom). This organ reads GLOBAL fleet state — the canonical gap store,
# ambient log, and faculty portrait all live under the main checkout / $HOME.
# Running it from inside a throwaway worktree would read that worktree's tiny
# split-brain state.db instead (64 gaps vs the canonical 4200+). Deploy it with
# WorkingDirectory=<main checkout>. MODEL_JQ stays $DIR-relative so it is found
# alongside this script in either tree.
REPO="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$DIR/../.." && pwd))"
# HOST-ASSUMPTION fix (mirrors faculty-collector): resolve the run-user's REAL
# home so gh/chump/almanac read the right per-user config under systemd.
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[[ -n "${REAL_HOME:-}" && -d "$REAL_HOME" ]] && export HOME="$REAL_HOME"

OUT="${CHUMP_NBA_OUT:-$HOME/.chump/next-best-action.json}"
JOURNEY="${CHUMP_JOURNEY_ODDS:-$HOME/.chump/journey-odds.json}"
FACULTY="${CHUMP_FACULTY_OUT:-$HOME/.chump/faculty-status.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
MODEL_JQ="$DIR/pr-book-model.jq"
mkdir -p "$HOME/.chump"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TOPN=3; NO_EMIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-emit) NO_EMIT=1 ;;
    --top) TOPN="${2:-3}"; shift ;;
    *) ;;
  esac; shift
done

# ── The transparent scoring table ──────────────────────────────────────────
# action_type -> { value (points 0..100), p_default, who, need }
# EV = value * p_success. p_success is the live signal when present, else p_default.
read -r -d '' ACTION_TABLE <<'JQ'
{
  "merge_pr":        {"value":60,"p_default":0.90,"who":"organ","need":"integrator/lander: this PR is green — arm auto-merge and land it"},
  "resolve_conflict":{"value":42,"p_default":0.45,"who":"organ","need":"conflict-resolution-consumer: rebase onto main + resolve, then re-arm"},
  "rebase_pr":       {"value":35,"p_default":0.55,"who":"organ","need":"armed-pr-rebaser: PR is behind main — rebase to unblock the merge"},
  "rerun_stale":     {"value":32,"p_default":0.55,"who":"organ","need":"transient-retrigger: red is a shared-gate flake — rerun the failed checks"},
  "close_deep_red":  {"value":18,"p_default":0.85,"who":"organ","need":"reaper: PR is deep-red/abandoned — cut it to unclog the queue"},
  "undraft_pr":      {"value":22,"p_default":0.50,"who":"human","need":"author: PR is a draft — mark ready if the work is done"},
  "wait_ci":         {"value":15,"p_default":0.80,"who":"organ","need":"no action — CI is running; let it settle before touching"},
  "fix_own_red":     {"value":28,"p_default":0.35,"who":"worker","need":"author/worker: PR has its own real red — fix the failing test"},
  "heal_organ":      {"value":70,"p_default":0.85,"who":"organ","need":"reviver/duty-officer: a manifest organ is dead — restart it (dark capability)"},
  "dispatch_worker_p0": {"value":55,"p_default":0.55,"who":"worker","need":"musher: open P0 gaps are waiting — pick the top one and assign a worker"},
  "dispatch_worker_p1": {"value":45,"p_default":0.55,"who":"worker","need":"musher: open P1 gaps are waiting — pick the top one and assign a worker"},
  "raise_faculty":   {"value":40,"p_default":0.25,"who":"human","need":"Jeff/board+swarm: a faculty is still ours/hand-run — build the organ that crosses it"}
}
JQ

# ── 1. PRs → priced candidates via pr-book-model.jq (INFRA-8592) ────────────
# Evaluate checks for the PR's current headRefOid ONLY (cache row keyed by head
# SHA, gh fallback; stale cache rows older than the head are ignored).
CACHE_DB="${CHUMP_CACHE_DB:-$REPO/.chump/github_cache.db}"
if [[ -n "${CHUMP_NBA_PR_FIXTURE:-}" && -f "${CHUMP_NBA_PR_FIXTURE}" ]]; then
  PR_RAW="$(cat "$CHUMP_NBA_PR_FIXTURE")"
else
  PR_RAW="$(gh pr list --state open --limit 40 \
    --json number,title,mergeStateStatus,createdAt,updatedAt,isDraft,statusCheckRollup,headRefOid 2>/dev/null || echo '[]')"
fi
PR_RAW="$(CHUMP_NBA_CACHE_DB="$CACHE_DB" python3 -c '
import json, os, sqlite3, sys

try:
    prs = json.loads(sys.stdin.read() or "[]")
    if not isinstance(prs, list):
        prs = []
except Exception:
    prs = []

db_path = os.environ.get("CHUMP_NBA_CACHE_DB", "")
conn = None
if db_path and os.path.isfile(db_path):
    try:
        conn = sqlite3.connect(db_path)
    except Exception:
        conn = None

def check_head(c):
    if not isinstance(c, dict):
        return ""
    h = c.get("headSha") or c.get("head_sha") or ""
    if not h and isinstance(c.get("commit"), dict):
        h = c["commit"].get("oid") or ""
    return str(h).strip().lower()

def check_ts(c):
    if not isinstance(c, dict):
        return ""
    return str(c.get("startedAt") or c.get("completedAt") or c.get("createdAt") or c.get("fetched_at_local") or "").strip()

out = []
for pr in prs:
    if not isinstance(pr, dict):
        continue
    num = pr.get("number")
    head = str(pr.get("headRefOid") or "").strip()
    head_l = head.lower()
    head_ts = str(pr.get("headCommittedAt") or pr.get("pushedAt") or pr.get("updatedAt") or "").strip()

    # Filter gh fallback rollup to current headRefOid only (and drop rows older than headCommittedAt/pushedAt if set).
    explicit_head_ts = str(pr.get("headCommittedAt") or pr.get("pushedAt") or "").strip()
    gh_checks = []
    for c in (pr.get("statusCheckRollup") or []):
        if not isinstance(c, dict):
            continue
        ch = check_head(c)
        if ch and head_l and ch != head_l:
            continue
        cts = check_ts(c)
        if explicit_head_ts and cts and cts < explicit_head_ts:
            continue
        c_copy = dict(c)
        if head and not check_head(c_copy):
            c_copy["headSha"] = head
        gh_checks.append(c_copy)

    # Check sqlite cache keyed by current headRefOid; ignore any stale row older than the head.
    cache_checks = []
    if conn is not None and head_l:
        try:
            cur = conn.cursor()
            # 1) check_runs keyed by head_sha == current headRefOid
            cur.execute(
                "SELECT name, status, conclusion, started_at, completed_at, fetched_at_local, head_sha "
                "FROM check_runs WHERE LOWER(head_sha) = ?",
                (head_l,),
            )
            for name, status, concl, started_at, completed_at, fetched_at, r_sha in cur.fetchall():
                row_ts = (fetched_at or completed_at or started_at or "").strip()
                if head_ts and row_ts and row_ts < head_ts:
                    continue  # stale cache row older than head
                cache_checks.append({
                    "name": name,
                    "status": status or None,
                    "conclusion": concl or None,
                    "startedAt": started_at or None,
                    "completedAt": completed_at or None,
                    "headSha": r_sha or head,
                })
        except Exception:
            pass
        if not cache_checks and num is not None:
            try:
                cur = conn.cursor()
                cur.execute(
                    "SELECT head_sha, fetched_at_local, updated_at_api, raw_payload_json "
                    "FROM pr_state WHERE number = ?",
                    (num,),
                )
                row = cur.fetchone()
                if row:
                    p_sha = (row[0] or "")
                    p_fetched = (row[1] or "")
                    p_updated = (row[2] or "")
                    p_raw = (row[3] or "")
                    p_ts = p_fetched or p_updated or ""
                    # Ignore stale pr_state rows whose head_sha != current head or whose timestamp < head_ts
                    if p_sha.strip().lower() == head_l and not (head_ts and p_ts and p_ts < head_ts) and p_raw:
                        payload = json.loads(p_raw)
                        for c in (payload.get("statusCheckRollup") or []):
                            if not isinstance(c, dict):
                                continue
                            ch = check_head(c)
                            if ch and ch != head_l:
                                continue
                            c_copy = dict(c)
                            c_copy["headSha"] = head
                            cache_checks.append(c_copy)
            except Exception:
                pass

    # Cache row keyed by current head SHA wins when present; otherwise gh fallback for current head.
    if cache_checks and not gh_checks:
        pr["statusCheckRollup"] = cache_checks
    elif cache_checks and gh_checks:
        by_name = {}
        for c in gh_checks:
            by_name[str(c.get("name") or c.get("context") or len(by_name))] = c
        for c in cache_checks:
            k = str(c.get("name") or c.get("context") or len(by_name))
            prev = by_name.get(k)
            if prev is None:
                by_name[k] = c
            else:
                pts = check_ts(prev)
                cts = check_ts(c)
                if cts and pts and cts >= pts:
                    by_name[k] = c
        pr["statusCheckRollup"] = list(by_name.values())
    else:
        pr["statusCheckRollup"] = gh_checks
    out.append(pr)

if conn is not None:
    conn.close()
print(json.dumps(out))
' <<<"$PR_RAW" 2>/dev/null || printf '%s' "$PR_RAW")"

PR_CAND="$(printf '%s' "$PR_RAW" | jq -c "$(cat "$MODEL_JQ")"'
  [ .[] | {
      source:"pr",
      action:( action as $a |
        if   $a=="MERGE-NOW" then "merge_pr"
        elif ($a|test("resolve-conflict")) then "resolve_conflict"
        elif ($a|test("rerun")) then "rerun_stale"
        elif ($a|test("rebase|REBASE")) then "rebase_pr"
        elif ($a|test("CUT|deep-red")) then "close_deep_red"
        elif ($a=="un-draft") then "undraft_pr"
        elif ($a=="wait-CI") then "wait_ci"
        elif ($a=="merge-candidate") then "merge_pr"
        else "fix_own_red" end),
      target:("#\(.number)"),
      head_sha:(.headRefOid // null),
      label:(if (.headRefOid // "") != "" then "\(.title[0:48]) [head:\(.headRefOid)]" else (.title[0:60]) end),
      p_success:(price),
      raw_action:action,
      merge_state:.mergeStateStatus
  } ]' 2>/dev/null || echo '[]')"
[[ -z "$PR_CAND" ]] && PR_CAND='[]'

# ── 2. Failed organs → heal candidates ──────────────────────────────────────
if [[ -n "${CHUMP_NBA_FAILED_UNITS_FIXTURE:-}" && -f "${CHUMP_NBA_FAILED_UNITS_FIXTURE}" ]]; then
  FAILED_UNITS="$(cat "$CHUMP_NBA_FAILED_UNITS_FIXTURE")"
else
  FAILED_UNITS="$( { systemctl list-units 'chump-*' --state=failed --no-legend 2>/dev/null;
                     systemctl --user list-units 'chump-*' --state=failed --no-legend 2>/dev/null; } \
                   | awk '{print $1}' | sed 's/^●//' | grep -v '^$' | sort -u )"
fi
ORGAN_CAND="$(printf '%s\n' "$FAILED_UNITS" | jq -R -s -c '
  [ split("\n")[] | select(length>0) | {
      source:"organ", action:"heal_organ", target:.,
      label:("dead organ: "+.), p_success:null } ]' 2>/dev/null || echo '[]')"
[[ -z "$ORGAN_CAND" ]] && ORGAN_CAND='[]'

# ── 3. Faculties still ours/hand (frontier) → raise-faculty candidates ───────
if [[ -f "$FACULTY" ]]; then
  FAC_CAND="$(jq -c '
    [ .faculties[] | select(.state=="ours" or .state=="hand")
      | { source:"faculty", action:"raise_faculty", target:.key,
          label:("faculty: "+.name+" ("+.state+")"),
          position:.position, p_success:null } ]' "$FACULTY" 2>/dev/null || echo '[]')"
else FAC_CAND='[]'; fi
[[ -z "$FAC_CAND" ]] && FAC_CAND='[]'

# ── 4. Open P0/P1 gaps → dispatch-worker candidates ─────────────────────────
# Robust read: the first `chump` call in a cold shell can print a warning line
# before the JSON array, so strip everything before the first top-level `[`.
if [[ -n "${CHUMP_NBA_GAPS_FIXTURE:-}" && -f "${CHUMP_NBA_GAPS_FIXTURE}" ]]; then
  GAP_JSON="$(cat "$CHUMP_NBA_GAPS_FIXTURE")"
else
  GAP_JSON="$(chump gap list --json 2>/dev/null | sed -n '/^\[/,$p')"
fi
printf '%s' "$GAP_JSON" | jq -e 'type=="array"' >/dev/null 2>&1 || GAP_JSON='[]'
P0_OPEN="$(printf '%s' "$GAP_JSON" | jq '[ .[] | select(.status=="open" and .priority=="P0") ] | length' 2>/dev/null || echo 0)"
P1_OPEN="$(printf '%s' "$GAP_JSON" | jq '[ .[] | select(.status=="open" and .priority=="P1") ] | length' 2>/dev/null || echo 0)"
[[ "$P0_OPEN" =~ ^[0-9]+$ ]] || P0_OPEN=0
[[ "$P1_OPEN" =~ ^[0-9]+$ ]] || P1_OPEN=0
# journey-odds (sibling agent, optional): a top-level median/avg P(success) if present.
JODDS="null"
if [[ -f "$JOURNEY" ]]; then
  JODDS="$(jq -c '(.median_p // .avg_p // (.journeys? // [] | map(.p_success // .p // empty) | (add / (length|if .==0 then 1 else . end)))) // null' "$JOURNEY" 2>/dev/null || echo null)"
  [[ -z "$JODDS" ]] && JODDS="null"
fi
# RESILIENT-422: pane coverage discounts dispatch_worker_* p_success ALWAYS
# (not just when journey-odds is present) — a starved pool is a real drag on
# "will this gap actually get picked up", independent of merge-side odds.
PANE_COVERAGE_PCT="$(pane_coverage_pct)"
PANE_FRAC="$(awk -v p="$PANE_COVERAGE_PCT" 'BEGIN{printf "%.4f", p/100}')"
GAP_CAND="$(jq -n -c \
  --argjson p0 "$P0_OPEN" --argjson p1 "$P1_OPEN" --argjson jo "$JODDS" \
  --argjson tbl "$ACTION_TABLE" --argjson pane_frac "$PANE_FRAC" '
  ( if $p0>0 then [ { source:"gap", action:"dispatch_worker_p0",
       target:("top of \($p0) open P0 gaps"),
       label:("\($p0) open P0 gaps waiting for a worker"),
       p_success:(( (if $jo != null then $jo else $tbl.dispatch_worker_p0.p_default end) * $pane_frac )) } ] else [] end )
  + ( if $p1>0 then [ { source:"gap", action:"dispatch_worker_p1",
       target:("top of \($p1) open P1 gaps"),
       label:("\($p1) open P1 gaps waiting for a worker"),
       p_success:(( (if $jo != null then $jo else $tbl.dispatch_worker_p1.p_default end) * $pane_frac )) } ] else [] end )' \
  2>/dev/null || echo '[]')"
[[ -z "$GAP_CAND" ]] && GAP_CAND='[]'

# ── 5. Combine + score (EV = value * p_success) ─────────────────────────────
RANKED="$(jq -n -c \
  --argjson tbl "$ACTION_TABLE" \
  --argjson pr "$PR_CAND" --argjson organ "$ORGAN_CAND" \
  --argjson fac "$FAC_CAND" --argjson gap "$GAP_CAND" '
  ($pr + $organ + $fac + $gap)
  | map(
      . as $c
      | ($tbl[$c.action]) as $t
      # p_success: live signal if present, else table default.
      | ( if ($c.p_success != null) then $c.p_success else $t.p_default end ) as $p0
      # raise_faculty value scales by headroom to peer (1 - position): the
      # further a faculty is from being a peer, the more a crossing is worth.
      | ( if $c.action=="raise_faculty"
          then ($t.value * (1 - (($c.position // 0.5))))
          else $t.value end ) as $val
      | ({
          action:$c.action,
          target:$c.target,
          value:(($val*10|round)/10),
          p_success:(($p0*100|round)/100),
          expected_value:(($val*$p0*10|round)/10),
          why:$c.label,
          who_should_do_it:$t.who,
          need_to_know:(if ($c.head_sha // "") != "" then "\($t.need) (head \($c.head_sha))" else $t.need end)
        } + (if ($c.head_sha // "") != "" then {head_sha:$c.head_sha, headRefOid:$c.head_sha} else {} end))
    )
  | sort_by(-.expected_value)' 2>/dev/null || echo '[]')"
[[ -z "$RANKED" ]] && RANKED='[]'

N="$(printf '%s' "$RANKED" | jq 'length')"

# ── 6. Write the machine-readable board ─────────────────────────────────────
printf '%s' "$RANKED" | jq -c --arg ts "$TS" --argjson n "$N" --argjson pane_pct "$PANE_COVERAGE_PCT" '
  { generated_at:$ts, advisory:true, count:$n, pane_coverage_pct:$pane_pct,
    note:"ADVISORY ONLY — recommends + logs, does not dispatch/merge/heal. EV = value x P(success).",
    recommendations:. }' > "$OUT"

# ── 7. Operator-readable top N ──────────────────────────────────────────────
echo "== NEXT-BEST-ACTION (advisory)  $TS =="
echo "   $N candidate action(s) scored by EV = value x P(success). Recommend-only."
printf '   %-4s %-16s %-26s %-6s %-5s %-8s %s\n' "#" "ACTION" "TARGET" "EV" "P" "WHO" "WHY"
printf '%s' "$RANKED" | jq -r --argjson k "$TOPN" '
  to_entries | .[0:$k][] | .key as $i | .value |
  "   \($i+1)\t\(.action)\t\(.target[0:26])\t\(.expected_value)\t\(.p_success)\t\(.who_should_do_it)\t\(.why[0:44])"' \
  | while IFS=$'\t' read -r i a tg ev p who why; do
      printf '   %-4s %-16s %-26s %-6s %-5s %-8s %s\n' "$i" "$a" "$tg" "$ev" "$p" "$who" "$why"
    done
echo "   -> $OUT"

# ── 8. Emit the top pick to the nervous system (ambient) ────────────────────
if [[ "$NO_EMIT" != "1" && "$N" -gt 0 ]]; then
  EMIT="$DIR/../dev/ambient-emit.sh"
  TOP="$(printf '%s' "$RANKED" | jq -c '.[0]')"
  if [[ -x "$EMIT" ]]; then
    # INFRA-3850: nba_ev/nba_p (not bare "ev"/"p") — namespaces the nba table's
    # EV/P columns so a cross-kind ambient.jsonl scan can't conflate them with
    # pr_book.ev or rating.p_win.
    CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-fleet-dispatcher}" \
    "$EMIT" next_best_action \
      "action=$(printf '%s' "$TOP" | jq -r .action)" \
      "target=$(printf '%s' "$TOP" | jq -r .target)" \
      "nba_ev=$(printf '%s' "$TOP" | jq -r .expected_value)" \
      "nba_p=$(printf '%s' "$TOP" | jq -r .p_success)" \
      "who=$(printf '%s' "$TOP" | jq -r .who_should_do_it)" \
      "candidates=$N" "advisory=true" "pane_coverage_pct=$PANE_COVERAGE_PCT" 2>/dev/null || true
  fi
fi
exit 0
