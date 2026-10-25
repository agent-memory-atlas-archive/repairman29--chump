#!/usr/bin/env bash
# fleet-status.sh — INFRA-204
#
# Operator-facing fleet control pane: a tmux window with live views of
#   (1) ambient.jsonl tail (peripheral vision across all sessions)
#   (2) PR queue depth + open PRs (merge-queue health)
#   (3) per-agent state (lease files + worktrees + branch heads)
#
# Defaults to a 3-pane tmux layout. Falls back to a single-shot snapshot
# (no tmux required) when run with --once or when tmux is unavailable —
# this lets unattended fleet loops, CI, and headless monitors share the
# same code path.
#
# Usage:
#   scripts/dispatch/fleet-status.sh           # tmux dashboard (interactive)
#   scripts/dispatch/fleet-status.sh --once    # single snapshot to stdout
#   scripts/dispatch/fleet-status.sh --json    # single JSON object to stdout
#   scripts/dispatch/fleet-status.sh --pane ambient|queue|agents
#                                              # render just one pane (used by tmux)
#
# Env:
#   CHUMP_LOCK_DIR    override .chump-locks location
#   CHUMP_AMBIENT_LOG override ambient.jsonl path
#   FLEET_REFRESH     refresh interval seconds for queue/agents panes (default 5)
#   FLEET_TMUX_SESSION  tmux session name (default "chump-fleet")

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
# INFRA-1081: source github cache + worktree libs
# shellcheck source=../coord/lib/github_cache.sh
if [[ -f "$REPO_ROOT/scripts/coord/lib/github_cache.sh" ]]; then
  source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
fi
# shellcheck source=../lib/worktree-iter.sh
if [[ -f "$REPO_ROOT/scripts/lib/worktree-iter.sh" ]]; then
  source "$REPO_ROOT/scripts/lib/worktree-iter.sh"
fi
# INFRA-1055: API rate-limit circuit breaker (non-fatal if missing).
# shellcheck source=../coord/api-rate-limit-gate.sh
_rl_gate_path="$REPO_ROOT/scripts/coord/api-rate-limit-gate.sh"
[[ -f "$_rl_gate_path" ]] && source "$_rl_gate_path"
unset _rl_gate_path

# Resolve the canonical lock dir + ambient stream.
#
# Linked worktrees have their own .chump-locks/ for *their* lease, but the
# durable ambient.jsonl lives in the main checkout's .chump-locks/. So:
#   - LOCK_DIR is for lease enumeration (defaults to worktree-local).
#   - AMBIENT prefers the main-checkout ambient if no env override, falling
#     back to the worktree-local one.
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
  AMBIENT="$CHUMP_AMBIENT_LOG"
else
  AMBIENT="$LOCK_DIR/ambient.jsonl"
  if [[ ! -f "$AMBIENT" ]]; then
    COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [[ -n "$COMMON_DIR" ]]; then
      MAIN_ROOT="$(cd "$COMMON_DIR/.." && pwd 2>/dev/null || echo "")"
      if [[ -n "$MAIN_ROOT" && -f "$MAIN_ROOT/.chump-locks/ambient.jsonl" ]]; then
        AMBIENT="$MAIN_ROOT/.chump-locks/ambient.jsonl"
      fi
    fi
  fi
fi
REFRESH="${FLEET_REFRESH:-5}"
SESSION="${FLEET_TMUX_SESSION:-chump-fleet}"

# ---------- pane renderers ----------

render_ambient() {
  echo "========== ambient.jsonl tail ($(date -u +%H:%M:%SZ)) =========="
  if [[ -f "$AMBIENT" ]]; then
    local total edits commits alerts
    total=$(wc -l <"$AMBIENT" | tr -d ' ')
    edits=$(grep -c '"event":"file_edit"' "$AMBIENT" 2>/dev/null || true)
    commits=$(grep -c '"event":"commit"' "$AMBIENT" 2>/dev/null || true)
    alerts=$(grep -c 'ALERT' "$AMBIENT" 2>/dev/null || true)
    echo "stream: ${total} events  edits=${edits} commits=${commits} alerts=${alerts}"
    echo "----"
    tail -n 30 "$AMBIENT"
  else
    echo "(no ambient stream at $AMBIENT)"
  fi
}

render_queue() {
  echo "========== PR queue depth ($(date -u +%H:%M:%SZ)) =========="
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "(gh not installed or not authenticated)"
    return
  fi

  local open_count auto_count queued_count
  # INFRA-1081: cache-first lookups
  local pr_data=""
  if command -v cache_query_pr_queue >/dev/null 2>&1; then
    pr_data=$(cache_query_pr_queue || echo "")
  fi

  if [[ -n "$pr_data" ]]; then
    open_count=$(printf '%s\n' "$pr_data" | wc -l | tr -d ' ')
    auto_count=$(printf '%s\n' "$pr_data" | awk -F$'\t' '$5 == 1' | wc -l | tr -d ' ')
  else
    open_count=$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo "?")
    auto_count=$(gh pr list --state open --json number,autoMergeRequest \
                   --jq '[.[] | select(.autoMergeRequest != null)] | length' 2>/dev/null || echo "?")
  fi

  echo "open PRs: ${open_count}"
  echo "auto-merge armed: ${auto_count}"

  # github merge-queue (best-effort; the REST endpoint isn't part of the public
  # API on every plan, so swallow stderr+errors and report n/a instead).
  queued_count=$(gh api "repos/{owner}/{repo}/queues/main/entries" --jq 'length' 2>/dev/null || echo "")
  if [[ -z "$queued_count" || "$queued_count" == *"Not Found"* || "$queued_count" == *"message"* || ! "$queued_count" =~ ^[0-9]+$ ]]; then
    queued_count="n/a"
  fi
  echo "merge-queue depth: ${queued_count}"
  echo "----"

  # Per-PR brief: number, mergeStateStatus, lifecycle
  if [[ -n "$pr_data" ]]; then
    # format: <number>\t<title>\t<head_ref>\t<mergeable_state>\t<auto_merge>\t<draft>
    # INFRA-1081: Use python for robust tab-parsing if awk fails or mangles.
    printf '%s\n' "$pr_data" | head -n 25 | python3 -c "
import sys
for line in sys.stdin:
    parts = line.strip('\n').split('\t')
    if len(parts) < 6: continue
    num, title, head, state, auto, draft = parts
    auto_label = ' auto' if auto == '1' else ''
    draft_label = ' draft' if draft == '1' else ''
    print(f'  #{num} [{state}{auto_label}{draft_label}] {head} — {title}')
"
  else
    gh pr list --state open \
      --json number,title,headRefName,mergeStateStatus,autoMergeRequest,isDraft \
      --jq '.[] | "  #\(.number) [\(.mergeStateStatus // "?")\(if .autoMergeRequest then " auto" else "" end)\(if .isDraft then " draft" else "" end)] \(.headRefName) — \(.title)"' \
      2>/dev/null | head -n 25 || echo "(failed to enumerate open PRs)"
  fi
}

render_agents() {
  echo "========== per-agent state ($(date -u +%H:%M:%SZ)) =========="
  mkdir -p "$LOCK_DIR" 2>/dev/null || true

  shopt -s nullglob
  local leases=("$LOCK_DIR"/*.json)
  shopt -u nullglob

  # EFFECTIVE-087: distinguish ACTIVE leases (real claim with session_id +
  # expires within 6h) from stale/marker files. Only count/classify — never delete.
  local PY="${PYTHON:-python3}"
  if [[ ${#leases[@]} -gt 0 ]] && command -v "$PY" >/dev/null 2>&1; then
    "$PY" -c '
import json, os, sys, time, datetime
now = time.time()
ACTIVE_TTL_SECS = 6 * 3600  # 6h — leases beyond this are stale

active_rows = []
stale_rows  = []

for path in sys.argv[1:]:
    fname = os.path.basename(path)
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception:
        stale_rows.append((fname, "unparseable", "", "", ""))
        continue

    sess = d.get("session_id") or d.get("session") or ""
    gap  = d.get("gap_id") or (d.get("pending_new_gap") or {}).get("id") or ""
    wt   = d.get("worktree") or d.get("cwd") or ""
    if isinstance(wt, str) and len(wt) > 50:
        wt = "..." + wt[-47:]

    expires_str = d.get("expires_at") or d.get("expires") or ""
    try:
        st = os.stat(path)
        age_secs = now - st.st_mtime
    except OSError:
        age_secs = 9999999

    # Classify: ACTIVE = has a real session_id AND file is fresh (< 6h old)
    # OR has an expires_at that is in the future.
    is_active = False
    if sess:
        # Check expires_at first
        if expires_str:
            try:
                exp_ts = datetime.datetime.fromisoformat(
                    expires_str.replace("Z", "+00:00")).timestamp()
                if exp_ts > now:
                    is_active = True
            except Exception:
                pass
        # Fallback: file modified within the active TTL window
        if not is_active and age_secs < ACTIVE_TTL_SECS:
            is_active = True

    age_label = "%dm" % int(age_secs / 60)

    if is_active:
        active_rows.append((fname[:28], sess[:18], gap[:14], age_label, wt))
    else:
        stale_rows.append((fname[:28], sess[:18] if sess else "(no session)", gap[:14], age_label, ""))

print("active leases: %d" % len(active_rows))
if active_rows:
    print("  %-28s %-19s %-14s %-5s %s" % ("lease", "session", "gap", "age", "worktree"))
    for r in active_rows:
        print("  %-28s %-19s %-14s %-5s %s" % r)
print("stale lease files: %d%s" % (
    len(stale_rows),
    "  (run: ls .chump-locks/*.json | grep curator-filed-)" if stale_rows else ""
))
' "${leases[@]}" 2>/dev/null || echo "live leases: ${#leases[@]}"
  else
    echo "active leases: 0"
    echo "stale lease files: ${#leases[@]}"
  fi

  # INFRA-8603: aggregate skipped external gaps across workers
  local ext_gate="closed"
  if [[ "${CHUMP_EXTERNAL_REPO_PICK_OK:-0}" == "1" || "${CHUMP_EXTERNAL_REPO_PICK_OK:-0}" == "true" ]]; then
    ext_gate="open"
  fi
  local ext_skipped=0
  if [[ -d "$LOCK_DIR/external-repo-skipped" ]] && command -v "$PY" >/dev/null 2>&1; then
    ext_skipped=$("$PY" - "$LOCK_DIR/external-repo-skipped" <<'PY' 2>/dev/null || echo 0
import json, os, sys
d = sys.argv[1]
total = 0
for fn in os.listdir(d):
    if fn.endswith(".json"):
        try:
            with open(os.path.join(d, fn)) as fh:
                total += int(json.load(fh).get("skipped_external_gaps", 0))
        except Exception:
            pass
print(total)
PY
)
  fi
  if [[ "$ext_gate" == "open" ]]; then
    echo "external_repo gate: open (skipped across workers: ${ext_skipped})"
  else
    echo "external_repo gate: closed (${ext_skipped} gaps blocked)"
    if [[ "$ext_skipped" -gt 0 ]]; then
      echo "${ext_skipped} external gaps skipped: gate closed"
    fi
  fi

  echo "----"
  echo "linked worktrees:"
  # INFRA-1211: use shared scanner
  if command -v scan_worktrees >/dev/null 2>&1; then
    for wt in $(scan_worktrees --include-tmp --include-dot-claude); do
      # Emulate the output of `git worktree list` for the dashboard
      # git worktree list format: <path> <hash> [<branch>]
      # scan_worktrees just gives paths. We can enrich it slightly.
      if [[ -d "$wt" ]]; then
        branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(no branch)")
        printf "  %-60s [%s]\n" "$wt" "$branch"
      fi
    done | head -n 20
  else
    git worktree list 2>/dev/null | sed 's/^/  /' | head -n 20 || echo "  (git worktree list failed)"
  fi
}

# EFFECTIVE-087: last-hour / last-24h PR merges + agent:human coordination ratio.
# Cache-first (per CLAUDE.md): reads .chump/github_cache.db if present and fresh,
# falls back to git log on origin/main (cheap, no API calls).
render_recent_merges() {
  echo "========== recent merges + agent:human ratio ($(date -u +%H:%M:%SZ)) =========="

  local PY="${PYTHON:-python3}"
  if ! command -v "$PY" >/dev/null 2>&1; then
    echo "(python3 unavailable — skipping recent-merges section)"
    return 0
  fi

  # Git-log path — no API call, always available.
  # Counts commits on origin/main within the time windows.
  # CREDIBLE-093: when origin/main ref doesn't exist (fake test repos, brand-new
  # clones), `git log origin/main` fails non-zero — under set -e + pipefail
  # that killed the whole fleet-status script and downstream renders never ran.
  # Sub-shell + `|| echo ""` swallows the failure so this section degrades to
  # "0 merges" instead of crashing the dashboard.
  local merges_1h merges_24h
  merges_1h=$( { git log origin/main --since="1 hour ago" --format="%H" 2>/dev/null || echo ""; } | wc -l | tr -d ' ')
  merges_24h=$( { git log origin/main --since="24 hours ago" --format="%H" 2>/dev/null || echo ""; } | wc -l | tr -d ' ')

  printf "merges last 1h:  %s\n" "$merges_1h"
  printf "merges last 24h: %s\n" "$merges_24h"
  echo "----"

  # Agent:human ratio — last N commits by author email.
  # Fleet authors: jeffadkins1@gmail.com, chump-dispatch, t@t.t, bigpickle
  # Human/operator: any other email (including jeffadkins@... personal commits)
  "$PY" -c '
import subprocess, sys

N = 20
# Agent author patterns (substrings of email)
AGENT_PATTERNS = [
    "jeffadkins1@gmail.com",
    "chump-dispatch",
    "t@t.t",
    "bigpickle",
    "noreply@anthropic.com",
]

try:
    result = subprocess.run(
        ["git", "log", "origin/main", "--format=%ae", f"-{N}"],
        capture_output=True, text=True, timeout=15
    )
    emails = [e.strip() for e in result.stdout.splitlines() if e.strip()]
except Exception as exc:
    print(f"(git log failed: {exc})")
    sys.exit(0)

if not emails:
    print("(no recent commits found)")
    sys.exit(0)

agent_count = 0
human_count = 0
for email in emails:
    el = email.lower()
    if any(p.lower() in el for p in AGENT_PATTERNS):
        agent_count += 1
    else:
        human_count += 1

total = agent_count + human_count
pct = int(agent_count * 100 / total) if total else 0
print(f"agent:human ratio (last {len(emails)} commits):  {agent_count}:{human_count}  ({pct}% autonomous)")
if human_count > 0:
    print("  (human commits detected — review for manual intervention pattern)")
' 2>/dev/null || echo "(ratio computation failed)"
}

render_starvation() {
  # INFRA-315: aggregate kind=fleet_starved events from ambient.jsonl so
  # the operator can see at a glance whether workers are quiet because
  # the fleet really has no work, or because filters are too tight, or
  # because gap-doctor is blocked. Per-agent count + per-filter signature
  # so a tight FLEET_DOMAIN_FILTER showing all the events is itself the
  # diagnosis.
  echo "========== fleet starvation ($(date -u +%H:%M:%SZ)) =========="
  if [[ ! -f "$AMBIENT" ]]; then
    echo "(no ambient stream at $AMBIENT)"
    return 0
  fi
  # Aggregate the last 24h of fleet_starved events. python3 is already
  # a fleet-status.sh dep below; keep parity.
  python3 - "$AMBIENT" <<'PY'
import json, sys, time, collections
path = sys.argv[1]
cutoff = time.time() - 24 * 3600
total = 0
per_agent = collections.Counter()
per_filter = collections.Counter()
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("event") != "fleet_starved":
                continue
            ts = rec.get("ts", "")
            try:
                t = time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                if time.mktime(t) < cutoff:
                    continue
            except (TypeError, ValueError):
                continue
            total += 1
            per_agent[rec.get("agent_id", "?")] += 1
            per_filter[rec.get("filters", "?")] += 1
except FileNotFoundError:
    print("(ambient stream missing)")
    raise SystemExit(0)
print(f"total kind=fleet_starved events (last 24h): {total}")
if total == 0:
    raise SystemExit(0)
print()
print("per agent:")
for a, n in per_agent.most_common(10):
    print(f"  agent {a}: {n}")
print()
print("per filter combination (most-starved first):")
for f, n in per_filter.most_common(5):
    print(f"  {n:>3}× {f}")
PY
}

render_version_skew() {
  # INFRA-609: check if running fleet's worker.sh is behind origin/main.
  local skew_script="$REPO_ROOT/scripts/dev/fleet-version-skew-detect.sh"
  if [[ -x "$skew_script" ]]; then
    if ! "$skew_script" 2>&1; then
      : # non-zero exit already printed the warning
    fi
  fi
}

render_race_loss() {
  # FLEET-035: aggregate kind=speculative_race_loss events from ambient.jsonl.
  # Shows last-24h count + gap_id breakdown + cost estimate (per-gap-count as
  # proxy for parallel cargo-build waste minutes).
  echo "========== speculative race losses ($(date -u +%H:%M:%SZ)) =========="
  if [[ ! -f "$AMBIENT" ]]; then
    echo "(no ambient stream at $AMBIENT)"
    return 0
  fi
  python3 - "$AMBIENT" <<'PY'
import json, sys, time, collections
path = sys.argv[1]
cutoff = time.time() - 24 * 3600
total = 0
per_gap = collections.Counter()
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("kind") != "speculative_race_loss":
                continue
            ts = rec.get("ts", "")
            try:
                import datetime
                dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if dt.timestamp() < cutoff:
                    continue
            except Exception:
                continue
            total += 1
            per_gap[rec.get("gap_id", "?")] += 1
except FileNotFoundError:
    print("(ambient stream missing)")
    raise SystemExit(0)
print(f"total race losses (last 24h): {total}")
if total == 0:
    print("(no speculative race losses — fleet coordination working well)")
    raise SystemExit(0)
# Cost estimate: each race loss ≈ 10 min cargo build + 5 min CI = ~15 min
est_min = total * 15
print(f"estimated compute wasted: ~{est_min} minutes")
print()
print("by gap (most-raced first):")
for g, n in per_gap.most_common(10):
    print(f"  {g}: {n} race loss(es)")
PY
}

# EFFECTIVE-025 + INFRA-1055: show GitHub REST + GraphQL rate-limit remaining.
# Uses `gh api rate_limit` (REST call, does NOT consume GraphQL quota).
# Emits rate_limit_approaching / rate_limit_exhausted ambient events when
# thresholds are crossed (via api-rate-limit-gate.sh if available).
render_rate_limit() {
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "GitHub API: (gh not available — rate limit unknown)"
    return
  fi

  # INFRA-1055: use gate snapshot if available (avoids duplicate /rate_limit call).
  # CREDIBLE-093: when the snapshot path EXISTS but returns 0/empty values (its
  # default uninitialised state when rate_limit_snapshot was sourced but the gh
  # call inside it failed silently), fall through to the direct gh-api path
  # below so the test's mock gh actually gets called.  Symptom this fixes:
  # EFFECTIVE-025 test failing in CI audit-shard 2 because the snapshot
  # returned 0/0 and the formatted line didn't match the regex.
  local rest_rem rest_lim gql_rem gql_lim
  local _used_snapshot=0
  if declare -F rate_limit_snapshot >/dev/null 2>&1; then
    rate_limit_snapshot --source "fleet-status.sh" 2>/dev/null || true
    rest_rem="${RL_REST_REMAINING:-}"; rest_lim="${RL_REST_LIMIT:-}"
    gql_rem="${RL_GQL_REMAINING:-}";  gql_lim="${RL_GQL_LIMIT:-}"
    # Did the snapshot produce real data?  REST limit > 0 is the smoking-gun.
    # Use case/regex instead of -gt so a non-numeric value (or empty) never
    # trips `set -e` and silently kills render_rate_limit.
    case "$rest_lim" in
      ''|0|*[!0-9]*) : ;;
      *) _used_snapshot=1
         rate_limit_gate "fleet-status" --source "fleet-status.sh" >/dev/null 2>&1 || true ;;
    esac
  fi
  if [[ "$_used_snapshot" -eq 0 ]]; then
    local raw
    raw="$(gh api rate_limit 2>/dev/null || echo "")"
    if [[ -z "$raw" ]]; then
      echo "GitHub API: (rate_limit call failed — offline or auth issue)"
      return
    fi
    rest_rem="$(echo "$raw" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo "?")"
    rest_lim="$(echo "$raw" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['limit'])" 2>/dev/null || echo "5000")"
    gql_rem="$(echo "$raw" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d['resources']['graphql']['remaining'])" 2>/dev/null || echo "?")"
    gql_lim="$(echo "$raw" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d['resources']['graphql']['limit'])" 2>/dev/null || echo "5000")"
  fi

  local reset_ts
  if [[ "$_used_snapshot" -eq 1 ]]; then
    # CREDIBLE-093: gate snapshot was used — RL_ vars don't expose the reset
    # epoch directly so show ?? for the timestamp (real data, not a fallback).
    reset_ts="??"
  else
    # Direct gh-api path (else branch above populated $raw); parse the reset.
    reset_ts="$(echo "$raw" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)
c = d['resources']['core']['reset']
g = d['resources']['graphql']['reset']
ts = max(c, g)
print(datetime.datetime.utcfromtimestamp(ts).strftime('%H:%M'))
" 2>/dev/null || echo "??")"
  fi

  local line="GitHub API: REST=${rest_rem}/${rest_lim} GraphQL=${gql_rem}/${gql_lim} (resets ${reset_ts} UTC)"
  local warn=0
  { [[ "$rest_rem" != "?" ]] && [[ "$rest_rem" -lt 1000 ]]; } 2>/dev/null && warn=1 || true
  { [[ "$gql_rem"  != "?" ]] && [[ "$gql_rem"  -lt 2500 ]]; } 2>/dev/null && warn=1 || true

  if [[ "$warn" -eq 1 ]]; then
    if [[ -t 1 ]]; then
      printf '\033[31mWARN: %s\033[0m\n' "$line"
    else
      printf 'WARN: %s\n' "$line"
    fi
  else
    echo "$line"
  fi
}

render_ship_rate() {
  # CREDIBLE-047: autonomous ship rate — % of fleet PRs with zero operator touch.
  # Read last row from metrics file if available (avoids API call in hot render path).
  local metrics_file="${CHUMP_METRICS_DIR:-$HOME/.chump/metrics}/autonomous-ship-rate.jsonl"
  if [[ -f "$metrics_file" ]]; then
    local last_row; last_row="$(tail -1 "$metrics_file")"
    local rate fleet auto date
    rate="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{float(d[\"autonomous_rate\"])*100:.0f}%')" 2>/dev/null || echo "?")"
    fleet="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['fleet_filed'])" 2>/dev/null || echo "?")"
    auto="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['autonomous'])" 2>/dev/null || echo "?")"
    date="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['date'])" 2>/dev/null || echo "?")"
    echo "autonomous-ship-rate: ${rate} (${auto}/${fleet} fleet PRs, as of ${date})"
  else
    echo "autonomous-ship-rate: (no data — run: bash scripts/dispatch/autonomous-ship-rate.sh)"
  fi
}

render_merge_mix() {
  # CREDIBLE-296: Race Control merge-mix board — user-value% vs self-maint%
  # vs reconcile-waste%. Read last row from metrics file if available (avoids
  # API call in hot render path). race-control.sh (scripts/coord/) is the
  # single canonical emitter (INFRA-3844 — merge-mix-board.sh retired).
  local metrics_file="${CHUMP_METRICS_DIR:-$HOME/.chump/metrics}/race-control.jsonl"
  if [[ -f "$metrics_file" ]]; then
    local last_row; last_row="$(tail -1 "$metrics_file")"
    local uv sm rw date
    uv="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"user_value_pct\"]:.0f}%')" 2>/dev/null || echo "?")"
    sm="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"self_maintenance_pct\"]:.0f}%')" 2>/dev/null || echo "?")"
    rw="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"reconcile_waste_pct\"]:.0f}%')" 2>/dev/null || echo "?")"
    date="$(echo "$last_row" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['date'])" 2>/dev/null || echo "?")"
    echo "merge-mix: user-value=${uv} self-maint=${sm} reconcile-waste=${rw} (as of ${date})"
  else
    echo "merge-mix: (no data — run: bash scripts/coord/race-control.sh)"
  fi
}

render_all() {
  render_version_skew
  render_agents
  echo
  render_recent_merges
  echo
  render_queue
  echo
  render_starvation
  echo
  render_race_loss
  echo
  render_rate_limit
  echo
  render_ship_rate
  echo
  render_merge_mix
  echo
  render_ambient
  echo
  render_ship_rate
}

render_json() {
  local PY="${PYTHON:-python3}"
  "$PY" - "$LOCK_DIR" "$AMBIENT" <<'PY'
import json, os, sys, time, collections

lock_dir = sys.argv[1]
ambient_path = sys.argv[2]
now = time.time()

# active_leases + fleet_workers_alive: count .json lease files
leases = [f for f in os.listdir(lock_dir) if f.endswith(".json")] if os.path.isdir(lock_dir) else []
active_leases = len(leases)
fleet_workers_alive = active_leases

# parse ambient for ships_24h and waste_30m
ships_24h = 0
waste_30m = 0
cutoff_24h = now - 24 * 3600
cutoff_30m = now - 30 * 60

if os.path.isfile(ambient_path):
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = rec.get("ts", "")
            try:
                t = time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                t_epoch = time.mktime(t)
            except (TypeError, ValueError):
                continue
            event = rec.get("event", "")
            if event in ("gap_shipped", "ship") and t_epoch >= cutoff_24h:
                ships_24h += 1
            if event in ("waste", "fleet_waste", "idle_waste", "abandoned_lease") and t_epoch >= cutoff_30m:
                waste_30m += 1

# pickable_count: query chump gap list for open unclaimed gaps
import subprocess
pickable_count = 0
try:
    result = subprocess.run(
        ["chump", "gap", "list", "--status", "open", "--json"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0 and result.stdout.strip():
        gaps = json.loads(result.stdout)
        if isinstance(gaps, list):
            pickable_count = sum(1 for g in gaps if not g.get("claimed_by"))
except Exception:
    # fallback: count lease files vs open gaps heuristic
    pickable_count = -1  # unknown

# INFRA-8603: aggregate skipped external gaps across workers
ext_skipped_dir = os.path.join(lock_dir, "external-repo-skipped")
skipped_external_gaps = 0
if os.path.isdir(ext_skipped_dir):
    for fn in os.listdir(ext_skipped_dir):
        if fn.endswith(".json"):
            try:
                with open(os.path.join(ext_skipped_dir, fn)) as fh:
                    skipped_external_gaps += int(json.load(fh).get("skipped_external_gaps", 0))
            except Exception:
                pass
ext_gate_env = os.environ.get("CHUMP_EXTERNAL_REPO_PICK_OK", "").strip().lower()
external_repo_gate = "open" if ext_gate_env in ("1", "true") else "closed"

out = {
    "active_leases": active_leases,
    "ships_24h": ships_24h,
    "pickable_count": pickable_count,
    "waste_30m": waste_30m,
    "fleet_workers_alive": fleet_workers_alive,
    "external_repo_gate": external_repo_gate,
    "skipped_external_gaps": skipped_external_gaps,
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
}

# INFRA-599: include latest mission_grade event from ambient.jsonl
latest_mg = None
if os.path.isfile(ambient_path):
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("kind") == "mission_grade":
                latest_mg = rec
if latest_mg is not None:
    out["mission_grade"] = latest_mg

print(json.dumps(out))
PY
}

# ---------- entrypoint ----------

mode="tmux"
pane=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)        mode="once"; shift ;;
    --json)        mode="json"; shift ;;
    --pane)        pane="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '1,30p' "$0"; exit 0 ;;
    *)             echo "[fleet-status] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$mode" == "json" ]]; then
  render_json
  exit 0
fi

if [[ -n "$pane" ]]; then
  case "$pane" in
    ambient)    render_ambient ;;
    queue)      render_queue ;;
    agents)     render_agents ;;
    starvation) render_starvation ;;
    race-loss)  render_race_loss ;;
    *)          echo "[fleet-status] unknown --pane: $pane (want ambient|queue|agents|starvation|race-loss)" >&2; exit 2 ;;
  esac
  exit 0
fi

if [[ "$mode" == "once" ]]; then
  render_all
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "[fleet-status] tmux not installed — falling back to --once snapshot" >&2
  render_all
  exit 0
fi

# Build tmux dashboard. Re-attach if the session already exists.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[fleet-status] attaching to existing tmux session '$SESSION'"
  exec tmux attach -t "$SESSION"
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Pane 0 (left, large): ambient tail via tail -F so the stream is live without
# repolling. Pane 1 (top right): PR queue. Pane 2 (bottom right): per-agent.
if [[ -f "$AMBIENT" ]]; then
  ambient_cmd="tail -F '$AMBIENT'"
else
  ambient_cmd="while true; do '$SELF' --pane ambient; sleep $REFRESH; clear; done"
fi

queue_cmd="while true; do clear; '$SELF' --pane queue; sleep $REFRESH; done"
agents_cmd="while true; do clear; '$SELF' --pane agents; sleep $REFRESH; done"

tmux new-session -d -s "$SESSION" -n fleet -x 220 -y 60 "$ambient_cmd"
tmux split-window -h -t "$SESSION:fleet" -p 50 "$queue_cmd"
tmux split-window -v -t "$SESSION:fleet.1" -p 50 "$agents_cmd"
tmux select-pane -t "$SESSION:fleet.0"
tmux set-option -t "$SESSION" status-right "chump fleet | refresh ${REFRESH}s"

echo "[fleet-status] tmux session '$SESSION' created (ambient | queue | agents)"
echo "[fleet-status] attaching... (detach with C-b d)"
exec tmux attach -t "$SESSION"
