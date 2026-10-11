#!/usr/bin/env bash
# stuck-pr-filer.sh — INFRA-307: convert stuck-PR detection into a queued gap
# instead of pinging the human to relay messages between agents.
#
# Why this exists. The original framing was "agent A needs to message agent B
# that B's PR is stuck." That's the wrong abstraction: by the time anyone
# notices, agent B has often exited (one-shot dispatch). The cleanup work
# belongs to whichever fleet agent picks it up next, not to the agent that
# happened to open the PR. So instead of building inboxes, we make stuck PRs
# show up as ordinary INFRA gaps that `run-fleet.sh` claims under the existing
# auto-pickup filters (P1, effort xs/s, INFRA domain).
#
# What it does. Walks open PRs, scores each against four stuck conditions:
#   - DIRTY    : mergeStateStatus=DIRTY for > DIRTY_THRESHOLD_HOURS
#   - CI_RED   : any required check failing for > CI_FAIL_THRESHOLD_MINS
#   - BEHIND   : > BEHIND_COMMITS_THRESHOLD commits behind base
#   - ORPHAN   : auto-merge disarmed AND no live lease for the PR's gap
# When a PR matches any condition, files an INFRA gap titled
# "PR #<N> stuck — <reason>" with the PR URL, the original gap IDs, and a
# suggested action. Filers de-dup by checking open INFRA gap titles for
# "PR #<N> stuck" first, so re-running the script is idempotent.
#
# Skips. Filing PRs (`chore(gaps): file/reserve …`), drafts, dependabot
# (those go through stale-pr-reaper.sh's natural close path), and PRs that
# already have a stuck-pr filing gap open.
#
# Usage:
#   scripts/ops/stuck-pr-filer.sh                # live run
#   scripts/ops/stuck-pr-filer.sh --dry-run      # print what would be filed
#
# Environment:
#   REMOTE                       git remote (default: origin)
#   BASE                         base branch (default: main)
#   DIRTY_THRESHOLD_HOURS        DIRTY age before filing (default: 4)
#   CI_FAIL_THRESHOLD_MINS       CI red age in minutes before filing (default: 20)
#   CI_FAIL_THRESHOLD_HOURS      (legacy, converted to mins if set)
#   BEHIND_COMMITS_THRESHOLD     commits-behind that triggers a gap (default: 20)
#   CHUMP_STUCK_PR_FILER=0       bypass — exit 0 immediately
#
# Designed to be idempotent and watchdog-graded — sources reaper-instrumentation
# so /tmp/chump-reaper-stuck-pr.heartbeat lands on every run and an ambient
# `kind=reaper_run` event is emitted.

set -euo pipefail

if [[ "${CHUMP_STUCK_PR_FILER:-1}" == "0" ]]; then
    echo "[stuck-pr-filer] CHUMP_STUCK_PR_FILER=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
source "$(dirname "$0")/../lib/safe-reopen-gap.sh"
reaper_setup stuck-pr
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free
reaper_rotate_log /tmp/chump-stuck-pr-filer.out.log
reaper_rotate_log /tmp/chump-stuck-pr-filer.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
# ZERO-WASTE-014: stuck/CI-red findings are ambient signals by default; they no
# longer file gaps (make-work inflow). Set CHUMP_NOISE_GAP_FILING=1 to restore
# the legacy gap-filing behaviour.
NOISE_GAP_FILING="${CHUMP_NOISE_GAP_FILING:-0}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
DIRTY_THRESHOLD_HOURS="${DIRTY_THRESHOLD_HOURS:-4}"
# INFRA-727: lowered from 2h to 20min. Fleet cycles are 2-15min; a PR that's
# been CI-red for 20min is definitely not going to self-heal. The stuck-pr-filer
# runs hourly, so effective detection latency is 20-80min (threshold + poll).
CI_FAIL_THRESHOLD_MINS="${CI_FAIL_THRESHOLD_MINS:-20}"
# Back-compat: convert legacy hours setting if someone still uses it
if [[ -n "${CI_FAIL_THRESHOLD_HOURS:-}" ]]; then
    CI_FAIL_THRESHOLD_MINS=$(( CI_FAIL_THRESHOLD_HOURS * 60 ))
fi
BEHIND_COMMITS_THRESHOLD="${BEHIND_COMMITS_THRESHOLD:-20}"
SHARED_BLOCKER_THRESHOLD="${SHARED_BLOCKER_THRESHOLD:-3}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== stuck-pr-filer (base: $REMOTE/$BASE) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no gaps will be filed."

# Temp file for deferred CI-RED data (shared-blocker aggregation).
# Format per line: pr_num\tcheck_name\tci_red_mins\tpr_branch\tgap_ids
SHARED_BLOCKER_TMP=$(mktemp /tmp/chump-shared-blocker-XXXXXX)

# INFRA-1410: reopen_respawned_gaps definition + invocation. Runs BEFORE the
# `git fetch` below so a network-offline environment still drains queued
# pr_auto_closed_for_respawn events into reopened gaps.
#
# Bypass: CHUMP_RESPAWN_REFILE=0 disables.
reopen_respawned_gaps() {
    [[ "${CHUMP_RESPAWN_REFILE:-1}" == "0" ]] && return 0
    command -v chump >/dev/null 2>&1 || return 0

    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    [[ -s "$ambient" ]] || return 0

    local window_hrs="${RESPAWN_WINDOW_HRS:-24}"

    # Collect (pr_num, gap_ids) tuples for pr_auto_closed_for_respawn events
    # in the window.
    local events
    events=$(python3 - "$ambient" "$window_hrs" <<'PYEOF' || true
import json, sys
from datetime import datetime, timezone, timedelta
path, window = sys.argv[1], int(sys.argv[2])
cutoff = datetime.now(timezone.utc) - timedelta(hours=window)
seen = {}
try:
    fp = open(path)
except Exception:
    fp = None
if fp is not None:
    for line in fp:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get('kind') != 'pr_auto_closed_for_respawn':
            continue
        ts = d.get('ts','')
        try:
            t = datetime.fromisoformat(ts.replace('Z','+00:00'))
            if t < cutoff:
                continue
        except Exception:
            continue
        pr = str(d.get('pr',''))
        if not pr:
            continue
        gap_ids = (d.get('gap_ids') or '').strip()
        seen[pr] = gap_ids   # last event wins
    fp.close()
for pr, gap_ids in seen.items():
    print(f"{pr}\t{gap_ids}")
PYEOF
    )

    [[ -z "$events" ]] && return 0

    local reopened=0
    while IFS=$'\t' read -r pr_num gap_ids_csv; do
        [[ -z "$pr_num" || -z "$gap_ids_csv" ]] && continue
        # Iterate cited gap IDs (comma-separated).
        IFS=',' read -ra _gids <<<"$gap_ids_csv"
        for gid in "${_gids[@]}"; do
            [[ -z "$gid" ]] && continue
            local current
            current=$(chump gap show "$gid" 2>/dev/null || true)
            [[ -z "$current" ]] && continue
            if grep -qF "respawn-handled:${pr_num}" <<<"$current"; then
                continue
            fi
            local status
            status=$(awk '/^[[:space:]]*status:/{sub(/^[[:space:]]*status:[[:space:]]*/,""); print; exit}' <<<"$current")
            local cycle
            # grep returns rc=1 on no match — wrap to keep `set -e` happy.
            cycle=$( { grep -oE 'stuck cycle [0-9]+' <<<"$current" || true; } \
                     | { grep -oE '[0-9]+' || true; } \
                     | sort -n | tail -1)
            cycle="${cycle:-0}"
            cycle=$((cycle + 1))
            local note_date
            note_date=$(date -u +%Y-%m-%d)
            local note="stuck cycle ${cycle} → re-attempt ${note_date} (PR #${pr_num} auto-closed) respawn-handled:${pr_num}"

            if [[ $DRY_RUN -eq 1 ]]; then
                printf '  [dry-run] would reopen %s (status=%s) with note: %s\n' "$gid" "$status" "$note"
                continue
            fi

            if [[ "$status" == "blocked" ]]; then
                printf '\033[0;33m  skip %s: status=blocked, not reopening (PR #%s)\033[0m\n' "$gid" "$pr_num"
                printf '{"ts":"%s","kind":"respawn_reopen_skipped_blocked","gap":"%s","pr":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gid" "$pr_num" \
                    >> "$lock_dir/ambient.jsonl" 2>/dev/null || true
                continue
            fi
            if [[ "$status" != "open" ]]; then
                safe_reopen_gap "$gid" \
                    || printf '\033[0;33m  WARN: chump gap set %s --status open failed\033[0m\n' "$gid"
            fi
            chump gap set "$gid" --add-note "$note" >/dev/null 2>&1 \
                || printf '\033[0;33m  WARN: chump gap set %s --add-note failed\033[0m\n' "$gid"
            printf '  reopened %s for picker (cycle %d, ex-PR #%s)\n' "$gid" "$cycle" "$pr_num"
            reopened=$((reopened + 1))
        done
    done <<<"$events"

    [[ $reopened -gt 0 ]] && printf '\033[0;32m  reopened %d gap(s) from pr_auto_closed_for_respawn events\033[0m\n' "$reopened"
    return 0
}

# Run early so we drain respawn events even when the network fetch fails.
reopen_respawned_gaps

git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE/$BASE — aborting."; exit 1
}

# Existing stuck-pr filings keyed by PR number. Title convention:
# "PR #<N> stuck — <reason>". We match on " #<N> " to avoid false hits on,
# say, INFRA-#N-shaped substrings.
EXISTING_FILINGS=""
if command -v chump >/dev/null 2>&1; then
    EXISTING_FILINGS=$(chump gap list --status open --json 2>/dev/null \
        | python3 -c "
import json, sys, re
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    title = r.get('title') or ''
    m = re.search(r'PR #(\d+) stuck', title)
    if m:
        print(m.group(1))
" 2>/dev/null || true)
fi

# INFRA-386: auto-close filed gaps whose underlying PR has resolved.
# Runs once per filer cycle, before the dedup-driven filing loop. Walks
# every open INFRA gap titled "PR #N stuck — ..." and checks PR N's
# state — if MERGED or CLOSED, flips the gap to closed via
# `chump gap set --status closed`.
#
# RESILIENT-098 (2026-06-05): switched from `chump gap ship` to
# `chump gap set --status closed`. The `ship` path enforces the
# INFRA-2423 auto-fetch gate (refuses when local main is behind origin
# AND working tree is dirty), which is the right discipline for HUMAN
# ship operations but wrong for an autonomous daemon that just wants to
# flip status. Pre-fix, 23 zombies accumulated over 5 days because every
# auto-close attempt hit the gate, logged a WARN, and left the gap open.
#
# Pre-fix history: INFRA-356/357/358 stayed open hours after their
# referenced PRs were closed via batch-unstick, with the hourly filer
# hitting EXISTING_FILINGS dedup but never resolving.
# Bypass: INFRA_386_AUTOCLOSE=0 for testing.
auto_close_resolved_filings() {
    [[ "${INFRA_386_AUTOCLOSE:-1}" == "0" ]] && return 0
    command -v chump >/dev/null 2>&1 || return 0

    local mapping
    mapping=$(chump gap list --status open --json 2>/dev/null \
        | python3 -c "
import json, sys, re
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    title = r.get('title') or ''
    m = re.search(r'PR #(\d+) stuck', title)
    if m:
        gid = r.get('id') or ''
        if gid: print(f\"{gid}|{m.group(1)}\")
" 2>/dev/null || true)

    [[ -z "$mapping" ]] && return 0

    local closed=0
    while IFS='|' read -r gap_id pr_num; do
        [[ -z "$gap_id" || -z "$pr_num" ]] && continue
        local state
        state=$(gh pr view "$pr_num" --json state -q .state 2>/dev/null || echo "")
        case "$state" in
            MERGED|CLOSED)
                if [[ $DRY_RUN -eq 1 ]]; then
                    dry "would auto-close $gap_id (PR #$pr_num is $state)"
                else
                    # RESILIENT-098: use `gap set --status closed` (state.db direct)
                    # instead of `gap ship` to bypass the INFRA-2423 auto-fetch gate.
                    if chump gap set "$gap_id" --status closed --closed-pr "$pr_num" \
                          --add-note "auto-closed by stuck-pr-filer: PR #$pr_num resolved ($state)" \
                          >/dev/null 2>&1; then
                        info "auto-closed $gap_id — referenced PR #$pr_num resolved ($state)"
                        closed=$((closed + 1))
                    else
                        warn "chump gap set $gap_id --status closed failed (PR #$pr_num $state)"
                    fi
                fi
                ;;
        esac
    done <<< "$mapping"

    [[ $closed -gt 0 ]] && green "  auto-closed $closed resolved filing(s)"
    return 0
}

# Run before the filing loop so EXISTING_FILINGS reflects the freshly-closed gaps.
auto_close_resolved_filings
# Refresh EXISTING_FILINGS after auto-close so dedup is current.
if command -v chump >/dev/null 2>&1; then
    EXISTING_FILINGS=$(chump gap list --status open --json 2>/dev/null \
        | python3 -c "
import json, sys, re
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    title = r.get('title') or ''
    m = re.search(r'PR #(\d+) stuck', title)
    if m:
        print(m.group(1))
" 2>/dev/null || true)
fi

already_filed() {
    local pr="$1"
    [[ -n "$EXISTING_FILINGS" ]] || return 1
    grep -qx "$pr" <<<"$EXISTING_FILINGS"
}

# is_filing_pr_title TITLE — PRs whose only intent is to land a new gap YAML.
# Mirrors stale-pr-reaper.sh's exemption (INFRA-219).
is_filing_pr_title() {
    local title="$1"
    case "$title" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

# pr_age_hours ISO_TIMESTAMP — fractional hours between now and timestamp.
pr_age_hours() {
    local ts="$1"
    [[ -z "$ts" ]] && { echo 0; return; }
    python3 -c "
import sys
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
    delta = datetime.now(timezone.utc) - t
    print(int(delta.total_seconds() / 3600))
except Exception:
    print(0)
" "$ts" 2>/dev/null || echo 0
}

# extract_gap_ids TITLE_BODY — pulls DOMAIN-NUM tokens for cross-reference.
extract_gap_ids() {
    grep -oE '\b[A-Z]+-[0-9]+\b' <<<"$1" | sort -u | head -10
}

# has_live_lease GAP_ID — true if any session lease still owns this gap.
has_live_lease() {
    local gid="$1"
    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
    grep -lE "\"gap_id\"[[:space:]]*:[[:space:]]*\"${gid}\"" \
        "$lock_dir"/*.json 2>/dev/null | head -1 >/dev/null
}

# file_stuck_gap PR_NUM REASON SUMMARY DETAILS [STUCK_CLASS]
# INFRA-376: STUCK_CLASS is one of REBASE, CI-RED, BEHIND, ORPHAN.
# Tag goes into the gap title in [brackets] (so the fleet picker can
# route by class) and the description carries a routing hint.
file_stuck_gap() {
    local pr_num="$1"
    local reason="$2"
    local summary="$3"
    local details="$4"
    local stuck_class="${5:-UNKNOWN}"

    local title="PR #${pr_num} stuck [${stuck_class}] — ${reason}"
    local pr_url="https://github.com/repairman29/chump/pull/${pr_num}"

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would file: $title"
        dry "  $summary"
        return
    fi

    if [[ "$NOISE_GAP_FILING" != "1" ]]; then
        local _zw_amb="${CHUMP_AMBIENT_LOG:-${REAPER_LOCK_DIR:-.chump-locks}/ambient.jsonl}"
        local _zw_ts
        _zw_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","event":"alert","kind":"stuck_pr","pr":%s,"stuck_class":"%s","reason":"%s"}\n' \
            "$_zw_ts" "$pr_num" "$stuck_class" "$reason" >> "$_zw_amb" 2>/dev/null || true
        # Keep the legacy pr_stuck event so the cluster detector still sees it.
        printf '{"event":"alert","kind":"pr_stuck","ts":"%s","pr":%s,"reason":"%s","gap":"","filed_gap":""}\n' \
            "$_zw_ts" "$pr_num" "$reason" >> "$_zw_amb" 2>/dev/null || true
        info "  PR #${pr_num} stuck [${stuck_class}] — emitted ambient stuck_pr (no gap filed)"
        FILED=$((FILED + 1))
        return
    fi

    if ! command -v chump >/dev/null 2>&1; then
        warn "chump binary not on PATH — cannot reserve gap; skipping PR #${pr_num}"
        return
    fi

    local reserved
    reserved=$(chump gap reserve --domain INFRA --title "$title" \
        --priority P1 --effort xs 2>&1 | tail -1)
    if [[ ! "$reserved" =~ ^INFRA-[0-9]+$ ]]; then
        warn "chump gap reserve failed for PR #${pr_num}: $reserved"
        return
    fi
    info "  filed $reserved: $title"

    # Description: PR URL + reason + suggested action. Kept short — the next
    # agent reads the PR for details.
    local desc
    desc="${pr_url}

Detected by stuck-pr-filer ($(date -u +%Y-%m-%dT%H:%M:%SZ)).

Trigger: ${reason}
${summary}

Suggested action:
  1. Check the PR — confirm whether the underlying gap landed elsewhere.
  2. If yes: gh pr close ${pr_num} --comment 'superseded'.
  3. If no:  rebase the branch and re-arm via scripts/coord/bot-merge.sh.

${details}"

    chump gap set "$reserved" --description "$desc" 2>/dev/null || \
        warn "  could not set description on $reserved (gap reserved but bare)"

    # INFRA-1247: verify the PR is still open before emitting pr_stuck.
    # Cross-check via cache_lookup_pr (INFRA-1081) to avoid emitting for PRs
    # that closed between our initial scan and the emit. If the cache lookup
    # fails (miss or binary unavailable), default to emitting (safe-side).
    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    local _pr_state="open"
    if declare -f cache_lookup_pr &>/dev/null; then
        _pr_state=$(cache_lookup_pr "$pr_num" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state','open'))" \
            2>/dev/null || echo "open")
    fi
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$_pr_state" != "open" ]]; then
        # Suppressed — emit classifier event so suppression rate is measurable
        printf '{"ts":"%s","kind":"alert_classifier_suppressed","original_kind":"pr_stuck","reason":"pr_closed","target_id":"%s"}\n' \
            "$ts" "$pr_num" >> "$ambient" 2>/dev/null || true
        info "  PR #$pr_num is $_pr_state — suppressed pr_stuck emit (INFRA-1247)"
        return
    fi
    # RESILIENT-349: emit both "gap" (consumed by pr-stuck-cluster-detector.sh's
    # ev.get('gap','')) and "filed_gap" (the historical field name other
    # consumers/docs reference) so the cluster/chronic escalation chain can
    # resolve the originating gap id.
    printf '{"event":"alert","kind":"pr_stuck","ts":"%s","pr":%s,"reason":"%s","gap":"%s","filed_gap":"%s"}\n' \
        "$ts" "$pr_num" "$reason" "$reserved" "$reserved" >> "$ambient" 2>/dev/null || true

    FILED=$((FILED + 1))
}

# detect_shared_ci_blockers — INFRA-454
# Reads SHARED_BLOCKER_TMP (lines: pr_num\tcheck_name\tci_red_mins\tpr_branch\tgap_ids).
# Groups by check_name. Groups with N>=SHARED_BLOCKER_THRESHOLD get ONE cleanup gap;
# smaller groups fall back to individual CI-RED per-PR gaps.
detect_shared_ci_blockers() {
    [[ ! -s "${SHARED_BLOCKER_TMP:-/dev/null}" ]] && return 0

    green "=== shared-CI-blocker pass ==="

    # Collect existing "CI blocker:" gap titles for dedup.
    local existing_blocker_titles=""
    if command -v chump >/dev/null 2>&1; then
        existing_blocker_titles=$(chump gap list --status open --json 2>/dev/null \
            | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    t = (r.get('title') or '')
    if 'CI blocker:' in t:
        print(t)
" 2>/dev/null || true)
    fi

    # Group by check_name; emit GROUP or INDIVIDUAL directives.
    local group_data
    group_data=$(python3 - "$SHARED_BLOCKER_TMP" "$SHARED_BLOCKER_THRESHOLD" <<'PYEOF'
import sys, collections

data_file = sys.argv[1]
threshold = int(sys.argv[2])

groups = collections.defaultdict(list)
with open(data_file) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 5:
            continue
        pr_num, check_name, ci_red_mins, pr_branch, gap_ids = \
            parts[0], parts[1], parts[2], parts[3], parts[4]
        existing_prs = [x[0] for x in groups[check_name]]
        if pr_num not in existing_prs:
            groups[check_name].append((pr_num, ci_red_mins, pr_branch, gap_ids))

for check_name, entries in sorted(groups.items()):
    count = len(entries)
    pr_nums = ','.join(x[0] for x in entries)
    max_hrs = max((int(x[1]) for x in entries if x[1].isdigit()), default=0)
    if count >= threshold:
        print(f"GROUP\t{check_name}\t{count}\t{pr_nums}\t{max_hrs}")
    else:
        for pr_num, ci_red_mins, pr_branch, gap_ids in entries:
            print(f"INDIVIDUAL\t{pr_num}\t{check_name}\t{ci_red_mins}\t{pr_branch}\t{gap_ids}")
PYEOF
    ) || true

    [[ -z "$group_data" ]] && { info "no CI-RED deferred entries to process"; return 0; }

    local _handled_prs=""  # track PRs filed this run to prevent one-gap-per-check-name duplication

    while IFS=$'\t' read -r _action _rest; do
        case "$_action" in

            GROUP)
                local _check_name _count _pr_nums _max_hrs
                IFS=$'\t' read -r _check_name _count _pr_nums _max_hrs <<<"$_rest"
                local _title="CI blocker: ${_check_name} failing on ${_count}+ open PRs"

                if grep -qF "CI blocker: ${_check_name}" <<<"${existing_blocker_titles}" 2>/dev/null; then
                    info "  shared-blocker for '${_check_name}' already filed — skipping"
                    continue
                fi

                # Locate associated test script by matching a .sh filename in the check name.
                local _script_path=""
                local _candidate
                _candidate=$(printf '%s' "$_check_name" | grep -oE '[a-zA-Z0-9_.-]+\.sh' | head -1 || true)
                if [[ -n "$_candidate" && -f "scripts/ci/$_candidate" ]]; then
                    _script_path="scripts/ci/$_candidate"
                fi

                # Recent commits to the script on origin/main (broken-test-not-yet-rebased signal).
                local _script_context=""
                if [[ -n "$_script_path" ]]; then
                    local _last_commit
                    _last_commit=$(git log --format='%H' -1 origin/main -- "$_script_path" 2>/dev/null || true)
                    if [[ -n "$_last_commit" ]]; then
                        _script_context=$(git log --oneline -5 origin/main -- "$_script_path" 2>/dev/null || true)
                        _script_context="${_script_context}
$(git diff "${_last_commit}^" "$_last_commit" -- "$_script_path" 2>/dev/null | head -30 || true)"
                    else
                        _script_context="(no commits for $_script_path on origin/main)"
                    fi
                else
                    _script_context="(script path not identified from check name: $_check_name)"
                fi

                if [[ $DRY_RUN -eq 1 ]]; then
                    dry "would file shared-blocker gap: $_title"
                    dry "  affected PRs ($_count): $_pr_nums"
                    FILED=$((FILED + 1))
                    continue
                fi

                if [[ "$NOISE_GAP_FILING" != "1" ]]; then
                    local _zw_lock="${REAPER_LOCK_DIR:-.chump-locks}"
                    printf '{"event":"alert","kind":"shared_ci_blocker","ts":"%s","check_name":"%s","affected_prs":%s,"filed_gap":""}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_check_name" "$_count" \
                        >> "$_zw_lock/ambient.jsonl" 2>/dev/null || true
                    info "  shared-blocker '${_check_name}' emitted ambient (no gap filed)"
                    FILED=$((FILED + 1))
                    continue
                fi

                command -v chump >/dev/null 2>&1 || {
                    warn "chump not on PATH — skipping shared-blocker gap for '$_check_name'"; continue
                }

                local _reserved
                _reserved=$(chump gap reserve --domain INFRA --title "$_title" \
                    --priority P1 --effort s 2>&1 | tail -1)
                if [[ ! "$_reserved" =~ ^INFRA-[0-9]+$ ]]; then
                    warn "chump gap reserve failed for shared-blocker '$_check_name': $_reserved"
                    continue
                fi
                info "  filed $_reserved: $_title"

                local _ts
                _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                local _desc
                _desc="Shared CI-blocker detected by stuck-pr-filer (${_ts}).

Failing CI step:  ${_check_name}
Script path:      ${_script_path:-unknown}
Affected PRs:     ${_count} (#${_pr_nums//,/ #})
Oldest failure:   ${_max_hrs}h

Recent changes to script on origin/main:
${_script_context}

Suggested action:
  1. Check whether origin/main already fixed this test (git log above).
  2. If yes: bulk-rebase affected PRs so they pick up the fix.
  3. If no: fix the script and ship a patch PR first.
  4. Once root cause resolved, re-arm affected PRs via bot-merge.sh."

                chump gap set "$_reserved" --description "$_desc" 2>/dev/null || \
                    warn "  could not set description on $_reserved"

                local _lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
                printf '{"event":"alert","kind":"shared_ci_blocker","ts":"%s","check_name":"%s","affected_prs":%s,"filed_gap":"%s"}\n' \
                    "$_ts" "$_check_name" "$_count" "$_reserved" \
                    >> "$_lock_dir/ambient.jsonl" 2>/dev/null || true

                FILED=$((FILED + 1))
                ;;

            INDIVIDUAL)
                local _pr_num _check_name _ci_red_mins _pr_branch _gap_ids
                IFS=$'\t' read -r _pr_num _check_name _ci_red_mins _pr_branch _gap_ids <<<"$_rest"
                # One gap per PR, not one per failing check name.
                if echo " $_handled_prs " | grep -qw "$_pr_num"; then
                    info "  PR #$_pr_num already handled this run (check '$_check_name') — skipping duplicate"
                    local _855_amb="${CHUMP_AMBIENT_LOG:-${REAPER_LOCK_DIR:-.chump-locks}/ambient.jsonl}"
                    printf '{"ts":"%s","kind":"stuck_pr_filing_dedup_hit","pr_number":%s,"check_name":"%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_pr_num" "$_check_name" \
                        >> "$_855_amb" 2>/dev/null || true
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                if already_filed "$_pr_num"; then
                    info "  PR #$_pr_num already has a stuck-pr filing — skipping"
                    # INFRA-855: emit dedup hit so watchdogs / fleet-brief can observe
                    local _855_amb="${CHUMP_AMBIENT_LOG:-${REAPER_LOCK_DIR:-.chump-locks}/ambient.jsonl}"
                    printf '{"ts":"%s","kind":"stuck_pr_filing_dedup_hit","pr_number":%s,"check_name":"%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_pr_num" "$_check_name" \
                        >> "$_855_amb" 2>/dev/null || true
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                _handled_prs="$_handled_prs $_pr_num"
                local _reason="CI red for ${_ci_red_mins}m"
                local _summary="At least one required check has been failing for ${_ci_red_mins}m (threshold ${CI_FAIL_THRESHOLD_MINS}m). Failing check: ${_check_name}."
                local _details="Original gap(s) cited in PR title/commits: ${_gap_ids}
Branch: ${_pr_branch}
Failing check: ${_check_name}
Stuck class: CI-RED — ci-flake-rerun or human investigation required"
                file_stuck_gap "$_pr_num" "$_reason" "$_summary" "$_details" "CI-RED"
                # INFRA-855: update EXISTING_FILINGS so later already_filed() calls
                # in this same run also see the just-filed PR (cross-check dedup).
                EXISTING_FILINGS="$(printf '%s\n%s' "$EXISTING_FILINGS" "$_pr_num")"
                ;;
        esac
    done <<<"$group_data"
}

# Walk open PRs.
PRS_JSON=$(gh pr list --json number,title,headRefName,isDraft,author,mergeStateStatus,autoMergeRequest,updatedAt 2>/dev/null || echo "[]")
if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
    info "No open PRs found."
    green "=== stuck-pr-filer done (nothing to do) ==="
    trap - EXIT
    reaper_finish ok '{"filed":0,"skipped":0}'
    exit 0
fi

FILED=0
SKIPPED=0

# Stream PR records as TSV via python so we can keep the bash loop simple.
PR_TSV=$(python3 -c "
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    print('\t'.join([
        str(r.get('number','')),
        r.get('headRefName','') or '',
        (r.get('title','') or '').replace('\t',' '),
        '1' if r.get('isDraft') else '0',
        ((r.get('author') or {}).get('login','') or ''),
        r.get('mergeStateStatus','') or '',
        '1' if r.get('autoMergeRequest') else '0',
        r.get('updatedAt','') or '',
    ]))
" <<<"$PRS_JSON")

while IFS=$'\t' read -r PR_NUM PR_BRANCH PR_TITLE IS_DRAFT AUTHOR MSS HAS_AUTOMERGE UPDATED_AT; do
    [[ -z "$PR_NUM" ]] && continue

    info "PR #$PR_NUM  $PR_TITLE"

    if [[ "$IS_DRAFT" == "1" ]]; then
        info "  → draft, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if [[ "$AUTHOR" == "dependabot" || "$AUTHOR" == "app/dependabot" ]]; then
        info "  → dependabot, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if is_filing_pr_title "$PR_TITLE"; then
        info "  → gap-filing PR, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if already_filed "$PR_NUM"; then
        info "  → already has a stuck-pr filing gap, skipping"; SKIPPED=$((SKIPPED+1)); continue
    fi

    # Cross-reference original gap IDs (for the description).
    GAP_IDS=$(extract_gap_ids "$PR_TITLE")

    # Condition: BEHIND.
    BEHIND=0
    if git fetch "$REMOTE" "$PR_BRANCH" --quiet 2>/dev/null; then
        BEHIND=$(git rev-list --count "$REMOTE/$PR_BRANCH..$REMOTE/$BASE" 2>/dev/null || echo 0)
    fi

    # Condition: DIRTY age (proxy: PR updatedAt — the queue refreshes it on
    # state transitions, so updatedAt of a DIRTY PR is a fair lower-bound on
    # how long it's been DIRTY).
    AGE_HOURS=$(pr_age_hours "$UPDATED_AT")

    # Condition: CI red. Pull check status; treat any FAILURE/CANCELLED as red.
    CI_RED=0
    CI_RED_MINS=0
    CI_FAILING_NAMES=""
    if CHECKS_JSON=$(gh pr checks "$PR_NUM" --json name,state,completedAt 2>/dev/null); then
        CI_RED_MINS=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    rows = json.loads(sys.argv[1])
except Exception:
    print(0); sys.exit()
worst = 0
for r in rows:
    state = (r.get('state') or '').upper()
    if state in ('FAILURE','CANCELLED','TIMED_OUT','ACTION_REQUIRED','ERROR'):
        ts = r.get('completedAt')
        if not ts:
            continue
        try:
            t = datetime.fromisoformat(ts.replace('Z','+00:00'))
            mins = int((datetime.now(timezone.utc) - t).total_seconds() / 60)
            if mins > worst:
                worst = mins
        except Exception:
            pass
print(worst)
" "$CHECKS_JSON" 2>/dev/null || echo 0)
        [[ "$CI_RED_MINS" -gt 0 ]] && CI_RED=1
        # Collect failing check names for shared-blocker aggregation.
        if [[ "$CI_RED" == "1" ]]; then
            CI_FAILING_NAMES=$(python3 -c "
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    sys.exit()
seen = set()
for r in rows:
    state = (r.get('state') or '').upper()
    if state in ('FAILURE','CANCELLED','TIMED_OUT','ACTION_REQUIRED','ERROR'):
        name = (r.get('name') or '').strip()
        if name and name not in seen:
            seen.add(name)
            print(name)
" "$CHECKS_JSON" 2>/dev/null || true)
        fi
    fi

    # Condition: ORPHAN. auto-merge disarmed + no live lease for the cited gap.
    ORPHAN=0
    if [[ "$HAS_AUTOMERGE" == "0" && -n "$GAP_IDS" ]]; then
        ORPHAN=1
        for gid in $GAP_IDS; do
            if has_live_lease "$gid"; then
                ORPHAN=0; break
            fi
        done
    fi

    info "  state: mss=$MSS  behind=$BEHIND  ci_red_mins=$CI_RED_MINS  age_hrs=$AGE_HOURS  orphan=$ORPHAN  gaps=${GAP_IDS:-none}"

    REASON=""
    SUMMARY=""
    STUCK_CLASS=""   # INFRA-376: tag the cleanup gap with stuck mode
    if [[ "$MSS" == "DIRTY" && "$AGE_HOURS" -ge "$DIRTY_THRESHOLD_HOURS" ]]; then
        REASON="DIRTY for ${AGE_HOURS}h"
        SUMMARY="Branch needs rebase. mergeStateStatus=DIRTY for ${AGE_HOURS}h (threshold ${DIRTY_THRESHOLD_HOURS}h)."
        STUCK_CLASS="REBASE"
    elif [[ "$CI_RED" == "1" && "$CI_RED_MINS" -ge "$CI_FAIL_THRESHOLD_MINS" ]]; then
        STUCK_CLASS="CI-RED"
        # Defer CI-RED filing: detect_shared_ci_blockers() decides whether to file
        # one shared-blocker gap (N>=$SHARED_BLOCKER_THRESHOLD) or individual gaps.
        _names_to_record="${CI_FAILING_NAMES:-}"
        if [[ -n "$_names_to_record" ]]; then
            while IFS= read -r _cname; do
                [[ -z "$_cname" ]] && continue
                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$PR_NUM" "$_cname" "$CI_RED_MINS" "$PR_BRANCH" "${GAP_IDS:-none}" \
                    >> "$SHARED_BLOCKER_TMP"
            done <<<"$_names_to_record"
        else
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$PR_NUM" "unknown" "$CI_RED_MINS" "$PR_BRANCH" "${GAP_IDS:-none}" \
                >> "$SHARED_BLOCKER_TMP"
        fi
        info "  → CI-RED deferred (${CI_RED_MINS}m); will check for shared-blocker pattern"
        SKIPPED=$((SKIPPED+1))
        continue
    elif [[ "$BEHIND" -ge "$BEHIND_COMMITS_THRESHOLD" ]]; then
        REASON="${BEHIND} commits behind ${BASE}"
        SUMMARY="Branch is ${BEHIND} commits behind ${BASE} (threshold ${BEHIND_COMMITS_THRESHOLD}). The CLAUDE.md hard rule says rebase at 15."
        STUCK_CLASS="BEHIND"
    elif [[ "$ORPHAN" == "1" ]]; then
        REASON="auto-merge disarmed, no live owner"
        SUMMARY="Auto-merge is disarmed and the original gap(s) [${GAP_IDS}] have no live lease — the opening agent likely exited without re-arming."
        STUCK_CLASS="ORPHAN"
    else
        info "  → not stuck"; SKIPPED=$((SKIPPED+1)); continue
    fi

    DETAILS="Original gap(s) cited in PR title/commits: ${GAP_IDS:-none}
Branch: ${PR_BRANCH}
Stuck class: ${STUCK_CLASS} — REBASE→pr-watch-shepherd, CI-RED→ci-flake-rerun or human, BEHIND→pr-watch-shepherd, ORPHAN→auto-arm-sweeper"

    file_stuck_gap "$PR_NUM" "$REASON" "$SUMMARY" "$DETAILS" "$STUCK_CLASS"
done <<<"$PR_TSV"

detect_shared_ci_blockers
rm -f "${SHARED_BLOCKER_TMP:-}"

echo ""
green "=== stuck-pr-filer done: $FILED filed, $SKIPPED skipped ==="

trap - EXIT
reaper_finish ok "{\"filed\":$FILED,\"skipped\":$SKIPPED}"
