#!/usr/bin/env bash
# stale-pr-reaper.sh — Auto-close PRs whose gap work is already on main.
#
# Run hourly (via launchd or cron) or manually to keep the PR queue clean.
# The root problem it solves: an agent works on a branch for hours, meanwhile
# another agent pushes the same gap directly to main. The branch PR becomes
# stale dead-weight; CI keeps running; future agents see open gaps that are
# actually done.
#
# What it does:
#   1. Lists all open PRs via gh CLI.
#   2. For each PR: extracts gap IDs from the title and its commits vs main.
#   3. Reads docs/gaps.yaml from origin/main.
#   4. Closes the PR if ALL cited gaps are `done` on main AND the branch is
#      more than STALE_BEHIND_THRESHOLD commits behind main.
#   5. Warns (but does not close) on PRs that are very stale with open gaps —
#      those need a manual rebase decision.
#
# Usage:
#   ./scripts/ops/stale-pr-reaper.sh              # live run
#   ./scripts/ops/stale-pr-reaper.sh --dry-run    # print what would happen, no changes
#
# Environment:
#   REMOTE                 git remote (default: origin)
#   BASE                   base branch (default: main)
#   STALE_BEHIND_THRESHOLD max commits a PR can be behind before it's considered
#                          stale (default: 15). All-done PRs above this are closed.
#   WARN_BEHIND_THRESHOLD  commits behind at which a warning is issued even if
#                          gaps are not fully done (default: 25).

set -euo pipefail

# INFRA-120: shared instrumentation (heartbeat + ambient reaper_run event +
# log rotation). Sourced from scripts/lib/ so all reapers share the same
# emit/rotate path; the watchdog reads /tmp/chump-reaper-<NAME>.heartbeat.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
# Absolute dir of THIS script — used to locate sibling helpers (e.g.
# lib/classify-blocked-pr.py) independently of cwd or REAPER_REPO_ROOT.
REAPER_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
reaper_setup pr
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free
reaper_rotate_log /tmp/chump-stale-pr-reaper.out.log
reaper_rotate_log /tmp/chump-stale-pr-reaper.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
STALE_BEHIND_THRESHOLD="${STALE_BEHIND_THRESHOLD:-15}"
WARN_BEHIND_THRESHOLD="${WARN_BEHIND_THRESHOLD:-25}"

# INFRA-1081: source github cache lib
# shellcheck source=scripts/coord/lib/github_cache.sh
if [[ -f "$(dirname "$0")/../coord/lib/github_cache.sh" ]]; then
    source "$(dirname "$0")/../coord/lib/github_cache.sh"
fi

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== stale-pr-reaper (base: $REMOTE/$BASE) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no PRs will be closed."

# Fetch main and all PR branches
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE/$BASE — aborting."; exit 1
}

# INFRA-219 (2026-05-02): the source of truth on origin/main is per-file
# `docs/gaps/<ID>.yaml` (post-INFRA-188 deletion of the monolith). The
# previous implementation read `docs/gaps.yaml` and would silently abort
# on every modern run; worse, when wired against a local state.db it
# would false-close filing PRs (the gap exists in local DB precisely
# because the PR being inspected reserved it). The fix here:
#
#   1. gap_status() queries `git show origin/main:docs/gaps/<ID>.yaml`
#      directly, NEVER local state. Returns "" if the gap isn't on main.
#   2. Filing PRs (titled "chore(gaps): file ..." / "chore(gaps): reserve
#      ...") are skipped entirely. They cannot be duplicates of themselves.
#
# Optional monolith fallback — only used if `docs/gaps.yaml` still exists
# on $REMOTE/$BASE (i.e. some downstream fork hasn't yet absorbed
# INFRA-188). The post-INFRA-188 path is the canonical one.
GAPS_YAML_LEGACY=$(git show "$REMOTE/$BASE:docs/gaps.yaml" 2>/dev/null || true)

# gap_status GAP_ID — returns the status field value, querying ONLY
# origin/main (never local state.db). Empty string if the gap is not on
# main. Looks up per-file YAML first (canonical post-INFRA-188), falls
# back to the monolith only if it still exists.
gap_status() {
    local gid="$1"
    local per_file
    per_file=$(git show "$REMOTE/$BASE:docs/gaps/${gid}.yaml" 2>/dev/null || true)
    if [[ -n "$per_file" ]]; then
        # Per-file format: top-level list with one entry. Indented
        # under "- id:" so status: is at column 2 (vs column 4 in the
        # legacy monolith). Match either indentation defensively.
        echo "$per_file" | awk '
            /^- id:/{f=1; next}
            f && /^[[:space:]]+status:[[:space:]]/{
                sub(/^[[:space:]]+status:[[:space:]]*/,""); print; exit
            }'
        return
    fi
    if [[ -n "$GAPS_YAML_LEGACY" ]]; then
        echo "$GAPS_YAML_LEGACY" | awk \
            "/^  - id: ${gid}\$/{f=1} f && /^    status:/{sub(/^    status: */,\"\"); print; exit}"
    fi
}

# is_filing_pr_title TITLE — returns 0 if the PR title looks like a gap
# filing PR (whose only intent is to add a `docs/gaps/<ID>.yaml` row).
# Filing PRs are NEVER duplicates of themselves — even if local state.db
# has the gap (because `chump gap reserve` put it there), origin/main
# does not yet, and that's exactly what the PR is about to fix.
is_filing_pr_title() {
    local title="$1"
    case "$title" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

# List open PRs (number branch title) - INFRA-1081: cache-first
PRS=""
if command -v cache_query_open_prs >/dev/null 2>&1; then
    PRS=$(cache_query_open_prs | awk -F$'\t' '{print $1"\t"$3"\t"$2}' || true)
fi

if [[ -z "$PRS" ]]; then
    PRS=$(gh pr list --json number,title,headRefName \
        --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null || true)
fi

CLOSED=0
WARNED=0

if [[ -z "$PRS" ]]; then
    info "No open PRs found — skipping stale-PR checks."
fi

while IFS=$'\t' read -r PR_NUM PR_BRANCH PR_TITLE; do
    [[ -z "$PR_NUM" ]] && continue
    info "PR #$PR_NUM  branch=$PR_BRANCH"
    info "  title: $PR_TITLE"

    # INFRA-219: filing PRs are never duplicates of themselves. Their
    # entire purpose is to land a new `docs/gaps/<ID>.yaml` on origin/main.
    # Local state.db already has the row (because `chump gap reserve`
    # put it there before pushing). Closing the PR strands the gap
    # local-only forever — the exact incident from PR #718 (2026-05-02).
    if is_filing_pr_title "$PR_TITLE"; then
        info "  → Filing PR (chore(gaps): file/reserve …) — skipping reaper checks."
        continue
    fi

    # Fetch the PR branch; skip if unreachable (deleted remote etc.)
    if ! git fetch "$REMOTE" "$PR_BRANCH" --quiet 2>/dev/null; then
        warn "Could not fetch $REMOTE/$PR_BRANCH — skipping."
        continue
    fi

    BEHIND=$(git rev-list --count \
        "$REMOTE/$PR_BRANCH..$REMOTE/$BASE" 2>/dev/null || echo 0)
    AHEAD=$(git rev-list --count \
        "$REMOTE/$BASE..$REMOTE/$PR_BRANCH" 2>/dev/null || echo 0)
    info "  commits: +${AHEAD} ahead / -${BEHIND} behind $BASE"

    # Extract gap IDs from: PR title + commits on the branch vs main.
    COMMIT_MSGS=$(git log "$REMOTE/$BASE..$REMOTE/$PR_BRANCH" \
        --oneline 2>/dev/null | head -30 || true)
    GAP_IDS=$(printf '%s\n%s\n' "$PR_TITLE" "$COMMIT_MSGS" \
        | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u || true)

    if [[ -z "$GAP_IDS" ]]; then
        if [[ "$BEHIND" -gt "$WARN_BEHIND_THRESHOLD" ]]; then
            warn "PR #$PR_NUM is $BEHIND commits behind main with no gap IDs — review manually."
            WARNED=$((WARNED + 1))
        else
            info "  No gap IDs found; nothing to check."
        fi
        continue
    fi

    info "  Gap IDs: $(echo $GAP_IDS | tr '\n' ' ')"

    ALL_DONE=1
    DONE_LIST=""
    OPEN_LIST=""

    for GID in $GAP_IDS; do
        STATUS=$(gap_status "$GID")
        if [[ -z "$STATUS" ]]; then
            info "  $GID — not in gaps.yaml (new gap or ID not matching)"
            ALL_DONE=0
            OPEN_LIST="$OPEN_LIST $GID(?)"
        elif [[ "$STATUS" == "done" ]]; then
            DONE_LIST="$DONE_LIST $GID"
        else
            ALL_DONE=0
            OPEN_LIST="$OPEN_LIST $GID($STATUS)"
        fi
    done

    DONE_LIST="${DONE_LIST# }"
    OPEN_LIST="${OPEN_LIST# }"

    if [[ $ALL_DONE -eq 1 && "$BEHIND" -gt "$STALE_BEHIND_THRESHOLD" ]]; then
        # INFRA-258 (2026-05-02): "all gaps done" is necessary but NOT
        # sufficient. Live incident: PR #833 shipped TWO deliverables
        # (AGENTS.md doc + a test). The runtime fix landed via PR #854
        # but the AGENTS.md doc did NOT — closing #833 silently lost the
        # doc, requiring recovery PR #863. Check that every file in this
        # PR's diff is byte-identical to origin/main before closing. If
        # any file diverges, defer with a "partial-delivery" warning so
        # an operator can review the unique content.
        PARTIAL_FILES=""
        if [[ "${CHUMP_REAPER_PARITY_CHECK:-1}" != "0" ]]; then
            # INFRA-1275: cache-first file lookup
            PR_FILES=""
            if command -v cache_lookup_pr_files >/dev/null 2>&1; then
                PR_FILES=$(cache_lookup_pr_files "$PR_NUM" | tr ',' '\n' || true)
            fi
            if [[ -z "$PR_FILES" ]]; then
                PR_FILES=$(gh pr diff "$PR_NUM" --name-only 2>/dev/null || true)
            fi

            if [[ -n "$PR_FILES" ]]; then
                while IFS= read -r f; do
                    [[ -z "$f" ]] && continue
                    branch_blob=$(git rev-parse "$REMOTE/$PR_BRANCH:$f" 2>/dev/null || echo "missing-on-branch")
                    main_blob=$(git rev-parse "$REMOTE/$BASE:$f" 2>/dev/null || echo "missing-on-main")
                    if [[ "$branch_blob" != "$main_blob" ]]; then
                        PARTIAL_FILES+="$f"$'\n'
                    fi
                done <<< "$PR_FILES"
            fi
        fi

        if [[ -n "$PARTIAL_FILES" ]]; then
            DIVERGENT_COUNT=$(echo "$PARTIAL_FILES" | grep -c .)
            warn "  → PARTIAL DELIVERY (INFRA-258): gap done on main but $DIVERGENT_COUNT file(s) diverge:"
            echo "$PARTIAL_FILES" | sed 's/^/      - /'
            warn "  Skipping close. Operator action: rebase + ship divergent files,"
            warn "  or close manually after confirming the diverging content is intentionally dropped."
            warn "  (Bypass: CHUMP_REAPER_PARITY_CHECK=0 — historical pre-INFRA-258 behavior.)"
            WARNED=$((WARNED + 1))
            continue
        fi

        # INFRA-1195: freshness gate — skip the close if the PR was updated
        # recently. During an active rebase + force-push cycle the branch can
        # briefly satisfy ALL_DONE + parity-OK while the owner is mid-push.
        # Closing at that moment is a false-positive that strands real work.
        # Default window: CHUMP_CURATOR_FRESHNESS_MIN=10 minutes.
        _freshness_min="${CHUMP_CURATOR_FRESHNESS_MIN:-10}"
        _pr_updated_at=$(gh pr view "$PR_NUM" --json updatedAt -q .updatedAt 2>/dev/null || echo "")
        if [[ -n "$_pr_updated_at" ]]; then
            _pr_epoch=$(python3 -c "
from datetime import datetime, timezone
dt = datetime.fromisoformat('${_pr_updated_at}'.replace('Z','+00:00'))
print(int(dt.timestamp()))" 2>/dev/null || echo 0)
            _now_epoch=$(date +%s)
            _age_min=$(( (_now_epoch - _pr_epoch) / 60 ))
            if [[ "$_age_min" -lt "$_freshness_min" ]]; then
                warn "  → SKIP CLOSE (INFRA-1195): PR #$PR_NUM updated ${_age_min}m ago (< ${_freshness_min}m freshness window) — possible active rebase, deferring."
                _amb="${REAPER_LOCK_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks}/ambient.jsonl"
                _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                printf '{"ts":"%s","kind":"curator_skip_active_rebase","pr":%s,"gap":"%s","age_minutes":%d,"reason":"updated_within_freshness_window"}\n' \
                    "$_ts" "$PR_NUM" "$DONE_LIST" "$_age_min" >> "$_amb" 2>/dev/null || true
                WARNED=$((WARNED + 1))
                continue
            fi
        fi

        red "  → STALE: all gaps done on main [$DONE_LIST], $BEHIND commits behind, file parity OK."
        CLOSE_MSG="Auto-closing: every gap this PR was working on (${DONE_LIST}) is already \`done\` on \`main\` — the work landed via another agent's commits. The branch is **${BEHIND} commits behind** \`${BASE}\`. Verified all PR files are byte-identical to main, so nothing is lost.

Run \`scripts/coord/gap-preflight.sh ${DONE_LIST// / }\` to confirm, then pick a new open gap from \`docs/gaps.yaml\`."
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "gh pr close $PR_NUM --comment \"...\""
        else
            gh pr close "$PR_NUM" --comment "$CLOSE_MSG"
            green "  Closed PR #$PR_NUM."
        fi
        CLOSED=$((CLOSED + 1))

    elif [[ $ALL_DONE -eq 1 && "$BEHIND" -gt 0 ]]; then
        info "  All gaps done [$DONE_LIST] but only $BEHIND commits behind — needs rebase, not closure."
        info "  Hint: git rebase origin/$BASE && git push --force-with-lease"

    elif [[ "$BEHIND" -gt "$WARN_BEHIND_THRESHOLD" ]]; then
        warn "PR #$PR_NUM is $BEHIND commits behind main. Open gaps: $OPEN_LIST"
        warn "Rebase needed: git fetch && git rebase origin/$BASE"
        WARNED=$((WARNED + 1))

    else
        info "  → Active: open gaps [$OPEN_LIST], $BEHIND behind — OK."
    fi

done <<< "$PRS"

# INFRA-674: ghost-status reaper — for each MERGED PR in the last 24h, resolve
# the gap(s) it closes from the typed gap_prs FK (CREDIBLE-1550 AC1, written at
# PR-open); if state.db shows the gap still open, run `chump gap ship` to close
# it. This catches the "shipped but never closed" phantom that blocks the picker
# for hours (e.g. INFRA-664 via #1264).
#
# CREDIBLE-1551 (Phase R R2, AC2): the gap to close is resolved from
# `chump gap gaps-for-pr` — NEVER parsed from the merged PR's title or body. A
# title match was never proof the PR implemented the gap (it falsely closed the
# R3 umbrella CREDIBLE-1492 from a docs-only receipt PR). `chump gap ship`
# enforces the same gap_prs link, so a merged PR with no row closes nothing.
GHOST_CLOSED=0
GHOST_CLOSED_PAIRS=""
if command -v chump >/dev/null 2>&1; then
    green "=== ghost-status scan (INFRA-674): checking merged PRs (last 24h) ==="

    # gh's --search merged:> filter uses ISO-8601 date; use last 24h window
    SINCE=$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u '+%Y-%m-%dT%H:%M:%SZ')
    SINCE_DATE="${SINCE%%T*}"

    MERGED_PRS=$(gh pr list --state merged \
        --search "merged:>=${SINCE_DATE}" \
        --json number \
        --jq '.[] | "\(.number)"' 2>/dev/null || true)

    if [[ -z "$MERGED_PRS" ]]; then
        info "No merged PRs in last 24h — nothing to scan."
    else
        while IFS=$'\t' read -r M_NUM; do
            [[ -z "$M_NUM" ]] && continue

            # Resolve the gap(s) to close from the typed gap_prs FK, not a title.
            M_GAP_IDS=$(chump gap gaps-for-pr "$M_NUM" 2>/dev/null | sort -u || true)
            [[ -z "$M_GAP_IDS" ]] && continue

            for GID in $M_GAP_IDS; do
                # Query local state.db via chump gap show; extract status line
                GID_STATUS=$(chump gap show "$GID" 2>/dev/null \
                    | awk '/^[[:space:]]*status:/{sub(/^[[:space:]]*status:[[:space:]]*/,""); print; exit}' \
                    || true)
                [[ "$GID_STATUS" == "open" ]] || continue

                info "  Ghost detected: $GID status=open but PR #$M_NUM is merged."
                if [[ $DRY_RUN -eq 1 ]]; then
                    dry "chump gap ship $GID --closed-pr $M_NUM --update-yaml"
                else
                    if chump gap ship "$GID" --closed-pr "$M_NUM" --update-yaml 2>/dev/null; then
                        green "  Closed ghost gap $GID (PR #$M_NUM)."
                        GHOST_CLOSED=$((GHOST_CLOSED + 1))
                        GHOST_CLOSED_PAIRS="${GHOST_CLOSED_PAIRS}{\"gap_id\":\"$GID\",\"pr\":$M_NUM},"
                    else
                        warn "chump gap ship $GID --closed-pr $M_NUM failed — skipping."
                    fi
                fi
            done
        done <<< "$MERGED_PRS"
    fi

    if [[ $GHOST_CLOSED -gt 0 ]]; then
        # Emit ALERT kind=ghost_status_closed to ambient
        LOCK_DIR="${REAPER_LOCK_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks}"
        AMBIENT="$LOCK_DIR/ambient.jsonl"
        PAIRS_JSON="[${GHOST_CLOSED_PAIRS%,}]"
        TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        printf '{"ts":"%s","event":"ALERT","kind":"ghost_status_closed","count":%d,"gaps":%s}\n' \
            "$TS" "$GHOST_CLOSED" "$PAIRS_JSON" >> "$AMBIENT" 2>/dev/null || true
        green "  Emitted ALERT kind=ghost_status_closed for $GHOST_CLOSED gap(s)."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# INFRA-1410: PR-stuck SLO + auto-respawn
#
# When a PR has been mergeStateStatus=BLOCKED for > CHUMP_PR_STUCK_SLO_HRS
# (default 2h) and there's been no commit/comment activity in that window,
# attempt one chump-rebase-and-push.sh (INFRA-1404). If still BLOCKED 30min
# after the rebase attempt, close the PR with a comment + emit
# kind=pr_auto_closed_for_respawn so stuck-pr-filer.sh re-files the gap.
#
# Operator escape hatch: `gh pr edit --add-label do-not-respawn` exempts the PR.
#
# State is persisted in .chump-locks/stuck-pr-state.json:
#   { "<pr_num>": { "rebase_attempted_at": "ISO", "branch": "..." } }
#
# Bypass: CHUMP_PR_AUTO_RESPAWN=0 skips this pass entirely.
# ─────────────────────────────────────────────────────────────────────────────
RESPAWN_REBASED=0
RESPAWN_CLOSED=0
RESPAWN_EXEMPT=0
RESPAWN_SPARED=0

if [[ "${CHUMP_PR_AUTO_RESPAWN:-1}" != "0" ]]; then
    green "=== PR-stuck SLO + auto-respawn (INFRA-1410) ==="

    LOCK_DIR="${REAPER_LOCK_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks}"
    AMBIENT="$LOCK_DIR/ambient.jsonl"
    STATE_FILE="$LOCK_DIR/stuck-pr-state.json"
    SLO_HRS="${CHUMP_PR_STUCK_SLO_HRS:-2}"
    RECLOSE_MINS="${CHUMP_PR_STUCK_RECLOSE_MINS:-30}"
    REBASE_SCRIPT="${REBASE_SCRIPT_OVERRIDE:-${REAPER_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/scripts/coord/chump-rebase-and-push.sh}"

    # Fetch open PR list early — needed both for trunk-RED count and the
    # respawn loop below. Fetched once here to avoid a second gh API call.
    # Walk open PRs again — this time looking for BLOCKED-too-long candidates.
    RESPAWN_PRS_JSON=$(gh pr list --json number,headRefName,title,mergeStateStatus,updatedAt,labels 2>/dev/null || echo "[]")

    # ── RESILIENT-050: trunk-RED hold ────────────────────────────────────────
    # Before bouncing any PR, check whether trunk is currently RED. When trunk
    # is RED, ALL BLOCKED PRs are downstream of the upstream failure — bouncing
    # them destroys legitimate in-flight work (INCIDENT 2026-05-30T15:46Z, 28
    # PRs auto-closed in 60 seconds). Hold until trunk recovers.
    #
    # State file: .chump-locks/trunk-red-detector-state.json
    #   { "last_failed_sha": "abc123" | null, "last_emit_ts": "ISO8601", ... }
    # If file is absent, fall back to gh run list for a live check.
    # On network failure: fail-open (assume GREEN) to avoid false holds.
    #
    # Bypass: CHUMP_REAPER_HOLD_TRUNK_RED=0
    # ────────────────────────────────────────────────────────────────────────

    _trunk_red=0
    if [[ "${CHUMP_REAPER_HOLD_TRUNK_RED:-1}" != "0" ]]; then
        _trunk_state_file="$LOCK_DIR/trunk-red-detector-state.json"
        _trunk_red_window_s="${CHUMP_REAPER_TRUNK_RED_WINDOW_S:-3600}"  # 60 min

        if [[ -s "$_trunk_state_file" ]]; then
            # Read last_failed_sha and last_emit_ts from the detector state file.
            _last_failed_sha=$(python3 -c "
import json, sys
try:
    d = json.load(open('$_trunk_state_file'))
    print(d.get('last_failed_sha') or '')
except Exception:
    print('')
" 2>/dev/null || true)
            _last_emit_ts=$(python3 -c "
import json, sys
try:
    d = json.load(open('$_trunk_state_file'))
    print(d.get('last_emit_ts') or '')
except Exception:
    print('')
" 2>/dev/null || true)

            if [[ -n "$_last_failed_sha" && "$_last_failed_sha" != "null" && -n "$_last_emit_ts" ]]; then
                _emit_age_s=$(python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$_last_emit_ts'.replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc) - t).total_seconds()))
except Exception:
    print(9999)
" 2>/dev/null || echo 9999)
                if [[ "$_emit_age_s" -le "$_trunk_red_window_s" ]]; then
                    _trunk_red=1
                    info "Trunk-RED detected via state file (sha=${_last_failed_sha:0:8}, age=${_emit_age_s}s)"
                else
                    info "Trunk-RED state file present but stale (${_emit_age_s}s > ${_trunk_red_window_s}s window) — treating as GREEN"
                fi
            else
                info "Trunk-RED state file present: last_failed_sha=null → trunk GREEN"
            fi
        else
            # No state file — fall back to a live gh run check.
            info "No trunk-red-detector-state.json — checking latest main CI run via gh"
            _latest_conclusion=$(gh run list \
                --branch main \
                --workflow ci.yml \
                --limit 1 \
                --json conclusion \
                --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo "unknown")
            if [[ "$_latest_conclusion" == "failure" ]]; then
                _trunk_red=1
                info "Trunk-RED detected via live gh run check (conclusion=$_latest_conclusion)"
            else
                info "Trunk GREEN via live gh run check (conclusion=$_latest_conclusion)"
            fi
        fi

        if [[ "$_trunk_red" -eq 1 ]]; then
            # Count how many BLOCKED PRs would have been bounced this cycle.
            _would_bounce_count=$(python3 -c "
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
count = sum(1 for r in rows if r.get('mergeStateStatus') == 'BLOCKED')
print(count)
" "${RESPAWN_PRS_JSON:-[]}" 2>/dev/null || echo "0")

            _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            printf '{"ts":"%s","kind":"reaper_holding_for_trunk_red","would_bounce_count":%s,"reason":"trunk_red_state_within_window","window_s":%d}\n' \
                "$_ts" "${_would_bounce_count:-0}" "$_trunk_red_window_s" \
                >> "$AMBIENT" 2>/dev/null || true
            warn "TRUNK RED: holding all PR bounces this cycle (${_would_bounce_count:-0} PR(s) spared). Will retry when trunk recovers."
            warn "Re-enable: fix trunk + wait for trunk-red-detector to clear last_failed_sha."
            # Skip the entire auto-respawn loop — set variables used in summary.
            RESPAWN_REBASED=0; RESPAWN_CLOSED=0; RESPAWN_EXEMPT=0; RESPAWN_SPARED=0
            green "  respawn summary (HELD): rebased=0  closed=0  exempt=0  spared=0  [trunk-RED hold active]"
        fi
    fi
    # ── end RESILIENT-050 trunk-RED hold ────────────────────────────────────

    # Ensure state file exists and is valid JSON.
    if [[ ! -s "$STATE_FILE" ]]; then
        echo '{}' > "$STATE_FILE" 2>/dev/null || true
    fi
    python3 -c "import json; json.load(open('$STATE_FILE'))" 2>/dev/null \
        || echo '{}' > "$STATE_FILE" 2>/dev/null || true

    # respawn_emit KIND PR_NUM EXTRA_JSON_FRAGMENT — append to ambient.
    respawn_emit() {
        local _kind="$1" _pr="$2" _extra="${3:-}"
        local _ts
        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ -n "$_extra" ]]; then
            printf '{"ts":"%s","kind":"%s","pr":%s,%s}\n' \
                "$_ts" "$_kind" "$_pr" "$_extra" >> "$AMBIENT" 2>/dev/null || true
        else
            printf '{"ts":"%s","kind":"%s","pr":%s}\n' \
                "$_ts" "$_kind" "$_pr" >> "$AMBIENT" 2>/dev/null || true
        fi
    }

    # respawn_state_get PR_NUM FIELD — print state field or empty.
    respawn_state_get() {
        local _pr="$1" _field="$2"
        python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
except Exception:
    sys.exit(0)
v = (d.get('$_pr') or {}).get('$_field') or ''
print(v)
" 2>/dev/null || true
    }

    # respawn_state_set PR_NUM JSON_OBJECT_FRAGMENT — merge into state for PR.
    respawn_state_set() {
        local _pr="$1" _obj="$2"
        python3 - "$STATE_FILE" "$_pr" "$_obj" <<'PYEOF' || true
import json, sys
path, pr, obj_json = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(path))
except Exception:
    d = {}
try:
    obj = json.loads(obj_json)
except Exception:
    obj = {}
cur = d.get(pr) or {}
cur.update(obj)
d[pr] = cur
json.dump(d, open(path, 'w'))
PYEOF
    }

    # respawn_state_clear PR_NUM — drop the PR entry.
    respawn_state_clear() {
        local _pr="$1"
        python3 - "$STATE_FILE" "$_pr" <<'PYEOF' || true
import json, sys
path, pr = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    d = {}
d.pop(pr, None)
json.dump(d, open(path, 'w'))
PYEOF
    }

    # mins_since ISO_TS — minutes since an ISO timestamp (0 if blank/invalid).
    mins_since() {
        local _ts="$1"
        [[ -z "$_ts" ]] && { echo 0; return; }
        python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$_ts'.replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc) - t).total_seconds() / 60))
except Exception:
    print(0)
" 2>/dev/null || echo 0
    }

    # ── REAPER-SPARE helpers: never bounce a RECOVERABLE BLOCKED PR ──────────
    # mergeStateStatus=BLOCKED is a catch-all. Before the SLO loop rebases or
    # (worse) closes a BLOCKED PR, classify WHY it is blocked so recoverable
    # work is spared. See scripts/ops/lib/classify-blocked-pr.py for the pure
    # decision function (fixture-tested). Incident: PR #4589 — a green PR reaped
    # after 3 known-flake reruns tripped the INFRA-304 budget.
    #
    # Bypass: CHUMP_REAPER_SPARE_RECOVERABLE=0 restores the historical
    # close-any-BLOCKED-PR behavior (pre-fix; not recommended).
    # The classifier is a sibling of THIS script (resolved relative to the
    # reaper's own dir, not REAPER_REPO_ROOT — the latter is the repo being
    # operated on, which may be a worktree that does not carry scripts/).
    CLASSIFY_HELPER="$REAPER_SCRIPT_DIR/lib/classify-blocked-pr.py"
    # Single, fixture-tested run-id discovery helper (sibling of the classifier).
    # Reused instead of re-embedding the targetUrl/detailsUrl regex a third time.
    RUNIDS_HELPER="$REAPER_SCRIPT_DIR/lib/pr-failing-run-ids.py"
    # Cooldown markers live in the OPERATED repo's .chump-locks (same location
    # ci-flake-rerun.sh writes them: REAPER_REPO_ROOT/.chump-locks/ci-flake-cooldown).
    FLAKE_COOLDOWN_DIR="${REAPER_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.chump-locks/ci-flake-cooldown"

    # classify_blocked_pr PR_NUM — echo one of:
    #   pending | flake_exhausted | blocked_no_failure | hard_fail | conflict
    # Recoverable (spare): pending, flake_exhausted, blocked_no_failure.
    # Dead (fall through to bounce): hard_fail, conflict.
    classify_blocked_pr() {
        local _pr="$1"
        # Fail-safe: if the classifier helper is missing (partial checkout),
        # spare the PR rather than reaping it — destroying correct work is worse
        # than leaving a dead PR open for the next cycle / operator.
        if [[ ! -f "$CLASSIFY_HELPER" ]]; then
            echo "blocked_no_failure"; return
        fi
        # Test override: feed a fixture rollup + mergeable instead of calling gh.
        if [[ -n "${CHUMP_REAPER_ROLLUP_OVERRIDE:-}" ]]; then
            python3 "$CLASSIFY_HELPER" \
                --rollup-file "$CHUMP_REAPER_ROLLUP_OVERRIDE" \
                --mergeable "${CHUMP_REAPER_MERGEABLE_OVERRIDE:-MERGEABLE}" \
                --pr "$_pr" \
                --cooldown-dir "$FLAKE_COOLDOWN_DIR" \
                --flake-budget "${CHUMP_FLAKE_BUDGET:-3}" 2>/dev/null \
                || echo "blocked_no_failure"
            return
        fi
        local _view _rollup_file _mergeable
        _view=$(gh pr view "$_pr" --json statusCheckRollup,mergeable 2>/dev/null || echo '{}')
        # Trailing-X template only — BSD/macOS mktemp rejects a suffix after the
        # X's (returns empty), which would strand every classification.
        _rollup_file=$(mktemp "${TMPDIR:-/tmp}/reaper-rollup-XXXXXX" 2>/dev/null || echo "")
        [[ -z "$_rollup_file" ]] && { echo "blocked_no_failure"; return; }
        printf '%s' "$_view" \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); json.dump(d.get("statusCheckRollup") or [], open(sys.argv[1],"w"))' "$_rollup_file" 2>/dev/null \
            || printf '[]' > "$_rollup_file"
        _mergeable=$(printf '%s' "$_view" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("mergeable") or ""))' 2>/dev/null || echo "")
        python3 "$CLASSIFY_HELPER" \
            --rollup-file "$_rollup_file" \
            --mergeable "$_mergeable" \
            --pr "$_pr" \
            --cooldown-dir "$FLAKE_COOLDOWN_DIR" \
            --flake-budget "${CHUMP_FLAKE_BUDGET:-3}" 2>/dev/null \
            || echo "blocked_no_failure"
        rm -f "$_rollup_file" 2>/dev/null || true
    }

    # rearm_flake_budget PR_NUM — reset the INFRA-304 per-PR flake budget so
    # ci-flake-rerun.sh is permitted to retry the known flake on the next
    # failing run-id. Deletes the count + one-time-comment markers only.
    rearm_flake_budget() {
        local _pr="$1"
        rm -f "$FLAKE_COOLDOWN_DIR/pr-${_pr}.count" \
              "$FLAKE_COOLDOWN_DIR/pr-${_pr}.commented" 2>/dev/null || true
    }

    # prompt_flake_retry PR_NUM — completes PR #4606. Re-arming the flake budget
    # (above) only PERMITS a rerun on the next DISTINCT run-id, because
    # ci-flake-rerun.sh keys its per-run cooldown on the run-id
    # ($FLAKE_COOLDOWN_DIR/run-<RUN_ID>.ts). So the PR's CURRENT still-failing run
    # would not be retried until a re-push / fresh CI trigger minted a new run-id
    # — delaying recovery of a green-but-flake-blocked PR (the #4589 class). This
    # makes the retry PROMPT: it reruns the PR's current failing run(s) NOW.
    #
    # Approach (b) of the two acceptable options: a direct `gh run rerun` (the
    # sanctioned fleet pattern — see keep-mergeable-organ.sh RESILIENT-342 —
    # since gh auth is available in the reaper's runtime and the run-id is
    # discoverable from the statusCheckRollup the classifier already reads). It
    # writes the same per-run cooldown marker ci-flake-rerun.sh writes, so the
    # two organs never double-rerun the same run-id.
    #
    # BOUNDED: this is only ever called from inside the
    # CHUMP_REAPER_FLAKE_REARM_MAX-guarded re-arm block below, so a PR's current
    # run is rerun-prompted at most CHUMP_REAPER_FLAKE_REARM_MAX times total —
    # after that the flake_exhausted branch ESCALATES instead of re-arming. No
    # unbounded rerun loop. Bypass: CHUMP_REAPER_FLAKE_PROMPT_RETRY=0.
    prompt_flake_retry() {
        local _pr="$1"
        [[ "${CHUMP_REAPER_FLAKE_PROMPT_RETRY:-1}" == "0" ]] && return 0
        # Fail-safe: if the discovery helper is missing (partial checkout), do
        # nothing — ci-flake-rerun.sh remains the (slower) safety net.
        [[ -f "$RUNIDS_HELPER" ]] || {
            info "  PR #$_pr: run-id helper missing — skipping prompt-retry (ci-flake-rerun will retry on its next pass)."
            return 0
        }

        local _rollup_file _cleanup_rollup=0
        if [[ -n "${CHUMP_REAPER_ROLLUP_OVERRIDE:-}" ]]; then
            # Test seam: reuse the same fixture the classifier override reads.
            _rollup_file="$CHUMP_REAPER_ROLLUP_OVERRIDE"
        else
            local _view
            _view=$(gh pr view "$_pr" --json statusCheckRollup 2>/dev/null || echo '{}')
            _rollup_file=$(mktemp "${TMPDIR:-/tmp}/reaper-rerun-XXXXXX" 2>/dev/null || echo "")
            [[ -z "$_rollup_file" ]] && return 0
            printf '%s' "$_view" > "$_rollup_file"
            _cleanup_rollup=1
        fi

        local _rows
        _rows=$(python3 "$RUNIDS_HELPER" --rollup-file "$_rollup_file" 2>/dev/null || true)
        [[ "$_cleanup_rollup" -eq 1 ]] && rm -f "$_rollup_file" 2>/dev/null || true

        if [[ -z "$_rows" ]]; then
            info "  PR #$_pr: no failing run-id discoverable from rollup — ci-flake-rerun will retry on its next pass."
            return 0
        fi

        local _rid _cancelled _did=0 _ids=""
        while IFS=$'\t' read -r _rid _cancelled; do
            [[ -z "$_rid" ]] && continue
            _ids="${_ids:+$_ids,}$_rid"
            if [[ $DRY_RUN -eq 1 ]]; then
                dry "would rerun current failing run $_rid for PR #$_pr (cancelled=${_cancelled:-0})"
                _did=1
                continue
            fi
            local _rc=1
            if [[ "$_cancelled" == "1" ]]; then
                # CANCELLED/TIMED_OUT jobs are skipped by --failed (RESILIENT-308)
                # — rerun the whole run.
                _reaper_gh_run_rerun "$_rid" "" && _rc=0
            else
                _reaper_gh_run_rerun "$_rid" "--failed" && _rc=0
            fi
            if [[ $_rc -eq 0 ]]; then
                # Mirror ci-flake-rerun.sh's per-run cooldown so it does not
                # double-rerun this same run-id on its next pass.
                mkdir -p "$FLAKE_COOLDOWN_DIR" 2>/dev/null || true
                date +%s > "$FLAKE_COOLDOWN_DIR/run-${_rid}.ts" 2>/dev/null || true
                _did=1
            else
                warn "  PR #$_pr: gh run rerun $_rid failed — ci-flake-rerun will retry on its next pass."
            fi
        done <<< "$_rows"

        if [[ $_did -eq 1 ]]; then
            info "  PR #$_pr: prompted immediate retry of current failing run(s) [$_ids] — no wait for a new run-id."
            respawn_emit pr_stuck_flake_rerun_prompted "$_pr" "\"run_ids\":\"$_ids\""
        fi
    }

    # _reaper_gh_run_rerun RUN_ID EXTRA_ARGS — thin wrapper so tests can inject a
    # fake rerun command via CHUMP_REAPER_RERUN_CMD (recording invocations)
    # instead of hitting the real GitHub API. EXTRA_ARGS is passed UNQUOTED so an
    # empty value adds no argument and "--failed" passes as a single flag.
    _reaper_gh_run_rerun() {
        local _rid="$1" _extra="${2:-}"
        if [[ -n "${CHUMP_REAPER_RERUN_CMD:-}" ]]; then
            # shellcheck disable=SC2086
            $CHUMP_REAPER_RERUN_CMD "$_rid" $_extra >/dev/null 2>&1
        else
            # shellcheck disable=SC2086
            gh run rerun "$_rid" $_extra >/dev/null 2>&1
        fi
    }

    # RESPAWN_PRS_JSON was fetched earlier (before the trunk-RED check) to
    # allow the hold count to be accurate. Reuse it here.
    RESPAWN_TSV=$(python3 -c "
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for r in rows:
    labels = ','.join((l.get('name') or '') for l in (r.get('labels') or []))
    print('\t'.join([
        str(r.get('number','')),
        r.get('headRefName','') or '',
        (r.get('title','') or '').replace('\t',' '),
        r.get('mergeStateStatus','') or '',
        r.get('updatedAt','') or '',
        labels,
    ]))
" "$RESPAWN_PRS_JSON" 2>/dev/null || true)

    if [[ -z "$RESPAWN_TSV" ]]; then
        info "(no open PRs to evaluate for auto-respawn)"
    fi

    # RESILIENT-050: skip the entire bounce loop when trunk is RED.
    if [[ "$_trunk_red" -eq 1 ]]; then
        info "(trunk-RED hold active — skipping all PR bounce/rebase actions this cycle)"
    fi

    while [[ "$_trunk_red" -eq 0 ]] && IFS=$'\t' read -r PR_NUM PR_BRANCH PR_TITLE MSS UPDATED_AT LABELS; do
        [[ -z "$PR_NUM" ]] && continue

        # Operator exemption — clear any pending state and emit once per scan.
        if [[ ",$LABELS," == *",do-not-respawn,"* ]]; then
            if [[ -n "$(respawn_state_get "$PR_NUM" "rebase_attempted_at")" ]]; then
                respawn_state_clear "$PR_NUM"
            fi
            info "  PR #$PR_NUM has label do-not-respawn — exempt from auto-respawn."
            respawn_emit pr_stuck_exempt "$PR_NUM" "\"reason\":\"label_do_not_respawn\""
            RESPAWN_EXEMPT=$((RESPAWN_EXEMPT + 1))
            continue
        fi

        # Only act on BLOCKED PRs.
        if [[ "$MSS" != "BLOCKED" ]]; then
            # If we had pending state for a now-unblocked PR, clear it.
            if [[ -n "$(respawn_state_get "$PR_NUM" "rebase_attempted_at")" ]]; then
                info "  PR #$PR_NUM no longer BLOCKED ($MSS) — clearing respawn state."
                respawn_state_clear "$PR_NUM"
            fi
            continue
        fi

        # Skip filing PRs (they shouldn't be auto-closed for respawn).
        if is_filing_pr_title "$PR_TITLE"; then
            continue
        fi

        # ── REAPER-SPARE: classify WHY this PR is BLOCKED before touching it ──
        # Recoverable blocks (CI still running, or a known-flake budget block on
        # an otherwise-green PR) must NEVER be rebased-then-closed — that is the
        # PR #4589 class where correct work was destroyed. Only genuinely dead
        # PRs (a hard non-flake CI failure, or a merge conflict) fall through to
        # the rebase→close respawn path below.
        if [[ "${CHUMP_REAPER_SPARE_RECOVERABLE:-1}" != "0" ]]; then
            _spare_verdict=$(classify_blocked_pr "$PR_NUM")
            case "$_spare_verdict" in
                pending|blocked_no_failure)
                    info "  PR #$PR_NUM BLOCKED but RECOVERABLE ($_spare_verdict) — sparing (no hard failure to justify a close)."
                    # Clear any stale rebase-attempt state so the 30-min close
                    # timer never fires for a PR that is simply waiting on CI.
                    if [[ -n "$(respawn_state_get "$PR_NUM" "rebase_attempted_at")" ]]; then
                        respawn_state_clear "$PR_NUM"
                    fi
                    respawn_emit pr_stuck_spared "$PR_NUM" "\"reason\":\"$_spare_verdict\""
                    RESPAWN_SPARED=$((RESPAWN_SPARED + 1))
                    continue
                    ;;
                flake_exhausted)
                    _rearm_n=$(respawn_state_get "$PR_NUM" "flake_rearmed_count"); _rearm_n="${_rearm_n:-0}"
                    _rearm_max="${CHUMP_REAPER_FLAKE_REARM_MAX:-1}"
                    if [[ "$_rearm_n" -lt "$_rearm_max" ]]; then
                        info "  PR #$PR_NUM BLOCKED only by a flake-budget-exhausted known flake — re-arming budget (attempt $((_rearm_n + 1))/$_rearm_max), sparing. NEVER closing a green PR."
                        rearm_flake_budget "$PR_NUM"
                        # PR #4606 completion: re-arming alone only permits a
                        # rerun on the NEXT run-id; also PROMPT a retry of the
                        # CURRENT failing run so recovery is immediate, not
                        # deferred to a re-push. Bounded by this same
                        # CHUMP_REAPER_FLAKE_REARM_MAX guard.
                        prompt_flake_retry "$PR_NUM"
                        # Drop any pending close timer; keep the re-arm counter.
                        respawn_state_clear "$PR_NUM"
                        respawn_state_set "$PR_NUM" "{\"flake_rearmed_count\":$((_rearm_n + 1))}"
                        respawn_emit pr_stuck_flake_rearmed "$PR_NUM" "\"attempt\":$((_rearm_n + 1)),\"max\":$_rearm_max"
                    else
                        warn "  PR #$PR_NUM flake budget re-exhausted after $_rearm_n re-arm(s) — ESCALATING to operator, NOT closing (anti-memento: keep correct work)."
                        respawn_emit pr_stuck_flake_escalated "$PR_NUM" "\"rearmed\":$_rearm_n,\"reason\":\"flake_persists_after_rearm\""
                    fi
                    RESPAWN_SPARED=$((RESPAWN_SPARED + 1))
                    continue
                    ;;
                *)
                    : # hard_fail / conflict → genuinely dead; fall through.
                    ;;
            esac
        fi

        ATTEMPTED_AT=$(respawn_state_get "$PR_NUM" "rebase_attempted_at")

        if [[ -z "$ATTEMPTED_AT" ]]; then
            # First detection — check it's been BLOCKED long enough.
            # PR updatedAt is a fair lower-bound on how long the PR has been
            # in its current state (the queue updates the timestamp on each
            # commit/comment/check-run/label change).
            if [[ -z "$UPDATED_AT" ]]; then
                AGE_HRS=0
            else
                AGE_HRS=$(python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('$UPDATED_AT'.replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc) - t).total_seconds() / 3600))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
            fi

            if [[ "$AGE_HRS" -lt "$SLO_HRS" ]]; then
                info "  PR #$PR_NUM BLOCKED for ${AGE_HRS}h (< ${SLO_HRS}h SLO) — not yet stuck."
                continue
            fi

            info "  PR #$PR_NUM BLOCKED for ${AGE_HRS}h ≥ ${SLO_HRS}h SLO — attempting rebase."
            NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            respawn_state_set "$PR_NUM" \
                "{\"rebase_attempted_at\":\"$NOW_TS\",\"branch\":\"$PR_BRANCH\",\"age_hrs_at_attempt\":$AGE_HRS}"
            respawn_emit pr_stuck_cycle_1_rebase_attempted "$PR_NUM" \
                "\"branch\":\"$PR_BRANCH\",\"age_hrs\":$AGE_HRS"

            if [[ $DRY_RUN -eq 1 ]]; then
                dry "would invoke $REBASE_SCRIPT on PR #$PR_NUM branch $PR_BRANCH"
            elif [[ -x "$REBASE_SCRIPT" ]]; then
                # Fetch the branch and check it out into a throw-away worktree
                # name; failure here is non-fatal because the reaper's job is
                # to RECORD that we attempted (so the 30-min reclose timer
                # starts). The actual rebase efficacy is measured by the next
                # cycle's MSS re-check.
                (
                    cd "$REAPER_REPO_ROOT" 2>/dev/null || exit 0
                    git fetch "$REMOTE" "$PR_BRANCH" --quiet 2>/dev/null || true
                    git rev-parse --verify "$REMOTE/$PR_BRANCH" >/dev/null 2>&1 \
                        && git checkout -q -B "respawn-${PR_NUM}-$$" "$REMOTE/$PR_BRANCH" 2>/dev/null \
                        || true
                    "$REBASE_SCRIPT" "$BASE" --remote "$REMOTE" 2>&1 | head -20 || true
                ) || warn "  rebase-and-push attempt failed (will re-check after ${RECLOSE_MINS}m)"
            else
                warn "  $REBASE_SCRIPT not executable — recording attempt without invoke."
            fi
            RESPAWN_REBASED=$((RESPAWN_REBASED + 1))
            continue
        fi

        # Second pass — we already attempted a rebase. If it's been
        # RECLOSE_MINS since and the PR is still BLOCKED, close it.
        SINCE_MINS=$(mins_since "$ATTEMPTED_AT")
        if [[ "$SINCE_MINS" -lt "$RECLOSE_MINS" ]]; then
            info "  PR #$PR_NUM still BLOCKED but only ${SINCE_MINS}m since rebase attempt (need ${RECLOSE_MINS}m) — waiting."
            continue
        fi

        # Close + emit.
        CLOSE_COMMENT="auto-closed by stale-pr-reaper after ${SLO_HRS}h+${RECLOSE_MINS}m BLOCKED; gap re-claimable

Triggered by INFRA-1410 PR-stuck SLO + auto-respawn. The original gap
referenced in the PR title will be re-opened by stuck-pr-filer for the
next picker. To exempt a PR from this loop permanently, run:

  gh pr edit ${PR_NUM} --add-label do-not-respawn"

        if [[ $DRY_RUN -eq 1 ]]; then
            dry "would close PR #$PR_NUM with comment: ${CLOSE_COMMENT:0:80}…"
        else
            gh pr close "$PR_NUM" --comment "$CLOSE_COMMENT" 2>/dev/null \
                || warn "  gh pr close $PR_NUM failed."
            green "  Closed PR #$PR_NUM for respawn."
        fi

        # Extract gap IDs from the PR title for the emit payload.
        RESPAWN_GAPS=$(printf '%s\n' "$PR_TITLE" | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u | paste -sd, -)
        respawn_emit pr_auto_closed_for_respawn "$PR_NUM" \
            "\"branch\":\"$PR_BRANCH\",\"gap_ids\":\"${RESPAWN_GAPS:-}\",\"title\":\"$(printf '%s' "$PR_TITLE" | sed 's/"/\\"/g')\""
        respawn_state_clear "$PR_NUM"
        RESPAWN_CLOSED=$((RESPAWN_CLOSED + 1))
    done <<< "$RESPAWN_TSV"

    if [[ "$_trunk_red" -eq 0 ]]; then
        green "  respawn summary: rebased=$RESPAWN_REBASED  closed=$RESPAWN_CLOSED  exempt=$RESPAWN_EXEMPT  spared=$RESPAWN_SPARED"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# INFRA-3803 (INFRA-3604 slice): retire stale + conflicting PRs
#
# Any open PR whose branch has a real merge conflict (mergeable=CONFLICTING)
# and has sat that way for CHUMP_RETIRE_STALE_DAYS+ days is dead weight —
# nothing auto-rebases a genuine content conflict, so it will never resolve
# itself. This applies whether or not the underlying gap's priority was
# demoted: a demotion just makes the PR even less likely to get manual
# attention, but the close condition is the same stale+conflicting check
# either way — so AC #1 (demoted gap) and AC #3 (regardless of demotion)
# collapse into a single unconditional check here, and since the reaper runs
# hourly (StartInterval=3600 in dev.chump.stale-pr-reaper.plist), any PR that
# crosses the threshold is caught within 1 hour.
#
# Retired PRs are labeled `retired` (deliberately distinct from rot-reaper's
# `rot-reaped` label — that belongs to the separate author-scoped
# resolve-first pipeline, RESILIENT-324/RESILIENT-339) so revivers leave the
# close alone; the gap itself is left untouched (still open) for a clean
# re-pick.
#
# Bypass: CHUMP_RETIRE_STALE_CONFLICTING=0
# ─────────────────────────────────────────────────────────────────────────────
RETIRED=0
if [[ "${CHUMP_RETIRE_STALE_CONFLICTING:-1}" != "0" ]]; then
    green "=== stale+conflicting PR retirement (INFRA-3803) ==="

    LOCK_DIR="${REAPER_LOCK_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks}"
    AMBIENT="$LOCK_DIR/ambient.jsonl"
    RETIRE_STALE_DAYS="${CHUMP_RETIRE_STALE_DAYS:-7}"
    RETIRE_LABEL="${CHUMP_RETIRE_LABEL:-retired}"

    RETIRE_PRS_JSON=$(gh pr list --state open --limit 200 \
        --json number,headRefName,title,mergeable,createdAt,labels 2>/dev/null || echo "[]")

    RETIRE_TSV=$(python3 -c "
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for r in rows:
    labels = ','.join((l.get('name') or '') for l in (r.get('labels') or []))
    print('\t'.join([
        str(r.get('number','')),
        r.get('headRefName','') or '',
        (r.get('title','') or '').replace('\t',' '),
        r.get('mergeable','') or '',
        r.get('createdAt','') or '',
        labels,
    ]))
" "$RETIRE_PRS_JSON" 2>/dev/null || true)

    if [[ -z "$RETIRE_TSV" ]]; then
        info "(no open PRs to evaluate for stale-conflicting retirement)"
    fi

    RETIRE_LABEL_ENSURED=0
    ensure_retire_label() {
        [[ "$RETIRE_LABEL_ENSURED" == 1 ]] && return 0
        RETIRE_LABEL_ENSURED=1
        if gh label list --limit 300 2>/dev/null | grep -qE "^${RETIRE_LABEL}([[:space:]]|$)"; then return 0; fi
        gh label create "$RETIRE_LABEL" --color 5319E7 \
            --description "Auto-retired: stale + merge-conflicting, gap left open for re-pick (INFRA-3803)" \
            >/dev/null 2>&1 || true
    }

    while IFS=$'\t' read -r RPR_NUM RPR_BRANCH RPR_TITLE RPR_MERGEABLE RPR_CREATED RPR_LABELS; do
        [[ -z "$RPR_NUM" ]] && continue

        # Already retired — nothing to do.
        if [[ ",$RPR_LABELS," == *",$RETIRE_LABEL,"* ]]; then
            continue
        fi

        # Operator exemption — reuse do-not-respawn as a general "leave me alone" signal.
        if [[ ",$RPR_LABELS," == *",do-not-respawn,"* ]]; then
            continue
        fi

        # Filing PRs are never subject to retirement.
        if is_filing_pr_title "$RPR_TITLE"; then
            continue
        fi

        if [[ "$RPR_MERGEABLE" != "CONFLICTING" ]]; then
            continue
        fi

        [[ -z "$RPR_CREATED" ]] && continue

        AGE_DAYS=$(python3 -c "
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat('${RPR_CREATED}'.replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc) - t).total_seconds() / 86400))
except Exception:
    print(0)
" 2>/dev/null || echo 0)

        if [[ "$AGE_DAYS" -lt "$RETIRE_STALE_DAYS" ]]; then
            info "  PR #$RPR_NUM CONFLICTING but only ${AGE_DAYS}d old (< ${RETIRE_STALE_DAYS}d) — leaving for owner/rebaser."
            continue
        fi

        RETIRE_GAPS=$(printf '%s\n' "$RPR_TITLE" | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u | paste -sd, -)

        red "  PR #$RPR_NUM — CONFLICTING, ${AGE_DAYS}d old → RETIRE (gap re-pickable)."
        RETIRE_MSG="Auto-retiring (stale-pr-reaper / INFRA-3803): this PR has had unresolved merge conflicts with \`${BASE}\` for **${AGE_DAYS} days** (≥ ${RETIRE_STALE_DAYS}d threshold). Nothing auto-resolves a genuine content conflict, so this branch would sit CONFLICTING indefinitely and jam the merge queue. The cited gap(s) (${RETIRE_GAPS:-none}) are left **open** for a clean re-pick on fresh \`${BASE}\`. Labeled \`${RETIRE_LABEL}\` so revivers won't fight this deliberate close."

        if [[ $DRY_RUN -eq 1 ]]; then
            dry "would close PR #$RPR_NUM (${AGE_DAYS}d CONFLICTING) and label $RETIRE_LABEL"
        else
            ensure_retire_label
            gh pr close "$RPR_NUM" --comment "$RETIRE_MSG" 2>/dev/null \
                || warn "  gh pr close $RPR_NUM failed."
            if gh pr edit "$RPR_NUM" --add-label "$RETIRE_LABEL" >/dev/null 2>&1; then
                green "  Retired PR #$RPR_NUM (labeled $RETIRE_LABEL)."
            else
                warn "  could not add label '$RETIRE_LABEL' to PR #$RPR_NUM."
            fi
        fi

        TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"ts":"%s","kind":"pr_retired_stale_conflicting","pr":%s,"branch":"%s","gap_ids":"%s","age_days":%s,"label":"%s"}\n' \
            "$TS" "$RPR_NUM" "$RPR_BRANCH" "${RETIRE_GAPS:-}" "$AGE_DAYS" "$RETIRE_LABEL" >> "$AMBIENT" 2>/dev/null || true
        RETIRED=$((RETIRED + 1))
    done <<< "$RETIRE_TSV"

    green "  retirement summary: retired=$RETIRED (threshold=${RETIRE_STALE_DAYS}d, label=${RETIRE_LABEL})"
fi

echo ""
green "=== reaper done: $CLOSED closed, $WARNED warnings, $GHOST_CLOSED ghost gaps closed, $RESPAWN_REBASED respawn-rebased, $RESPAWN_CLOSED respawn-closed, $RESPAWN_SPARED respawn-spared, $RETIRED stale-conflicting retired ==="

# INFRA-120: stamp heartbeat + emit reaper_run event. Disarm trap first so we
# don't double-emit on the EXIT trap.
trap - EXIT
reaper_finish ok "{\"closed\":$CLOSED,\"warned\":$WARNED,\"ghost_closed\":$GHOST_CLOSED,\"respawn_rebased\":$RESPAWN_REBASED,\"respawn_closed\":$RESPAWN_CLOSED,\"respawn_spared\":$RESPAWN_SPARED,\"retired\":$RETIRED}"
