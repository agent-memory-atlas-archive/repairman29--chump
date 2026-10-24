#!/usr/bin/env bash
# ghost-gap-reaper.sh — two independent reconciliation passes over ghost gaps.
#
# Phase 1 (INFRA-556): roll back gaps that are status=done but whose
# closed_pr was closed without merging (CI failed forever / operator closed
# the PR). Prevents ghost gaps from clogging the registry.
#
#   INFRA-1284: Rewired to batch REST approach — one REST page scan replaces
#   one per-gap REST call (1576+ done gaps → was O(N) calls, now O(1) call).
#
#   Strategy:
#     1. GET /pulls?state=closed&per_page=100 via REST (one call, no GraphQL).
#     2. Filter to merged_at==null within lookback window → bounced PR numbers.
#     3. Build closed_pr→gap_id map from done gaps in state.db (no API calls).
#     4. Intersect: any done gap whose closed_pr appears in bounced set → ghost.
#     5. Roll those gaps back to open + emit ambient event.
#
# Phase 2 (INFRA-1909): the reverse drift class — a gap is still status=open
# in state.db but a PR referencing its gap_id already merged to origin/main.
# This happens when `chump gap ship` is skipped/forgotten after a manual
# merge, forcing an operator round-trip (claim → discover stale → release +
# chump gap ship). 4 instances in the 2026-05-24 session cost ~20 operator-min
# that a daily cron absorbs silently.
#
#   Strategy:
#     1. List all status:open gaps from state.db.
#     2. For each gap_id, `gh pr list --search '<gap_id>' --state merged
#        --json number,mergedAt --limit 1` — if a merged PR is found, the
#        gap is a ghost.
#     3. Reconcile via `chump gap ship <ID> --closed-pr <N> --update-yaml`
#        (stale/proof-of-merge checks bypassed — this call is the audit of
#        record, not a fresh claim) and emit kind=ghost_gap_reaped.
#
# Run periodically from control.sh (every 5 min), daily cron, or the hourly
# planner. Best-effort — always exits 0, even when 0 ghosts are found.
#
# Env:
#   CHUMP_GHOST_REAPER_LOOKBACK_DAYS   Phase 1: days of closed PRs to scan (default 7)
#   CHUMP_GHOST_REAPER=0               Phase 1: disable entirely
#   CHUMP_GHOST_GAP_REAPER=0           Phase 2: disable entirely (INFRA-1909)

set -uo pipefail

# INFRA-956: default harness to a schema-valid value.
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# INFRA-1081: source github cache lib
# shellcheck source=scripts/coord/lib/github_cache.sh
if [[ -f "$REPO_ROOT/scripts/coord/lib/github_cache.sh" ]]; then
    source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
fi

_chump="${HOME}/.cargo/bin/chump"
command -v "$_chump" >/dev/null 2>&1 || _chump="chump"
# shellcheck source=scripts/lib/safe-reopen-gap.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/safe-reopen-gap.sh"

_emit_ambient() {
    if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" "$@" 2>/dev/null || true
    fi
}

# ── Phase 1 (INFRA-556): done-but-bounced-PR rollback ─────────────────────────
run_phase1() {
    [[ "${CHUMP_GHOST_REAPER:-1}" == "0" ]] && return 0
    command -v "$_chump" >/dev/null 2>&1 || { echo "[ghost-gap-reaper] chump not found, skipping phase 1"; return 0; }
    command -v gh       >/dev/null 2>&1 || { echo "[ghost-gap-reaper] gh not found, skipping phase 1"; return 0; }
    command -v python3  >/dev/null 2>&1 || { echo "[ghost-gap-reaper] python3 not found, skipping phase 1"; return 0; }

    local _lookback_days="${CHUMP_GHOST_REAPER_LOOKBACK_DAYS:-7}"
    local _repo="${GITHUB_REPOSITORY:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')}"

    # ── Step 1: recently-closed PRs (cache-first via INFRA-1081) ──────
    local _closed_prs
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$(_cache_db_path)" ]]; then
        # Fetch from local cache — recently updated closed PRs
        _closed_prs="$(sqlite3 "$(_cache_db_path)" "SELECT json_group_array(json(raw_payload_json)) FROM (SELECT raw_payload_json FROM pr_state WHERE merged_at IS NULL AND fetched_at_local > datetime('now', '-$_lookback_days days') ORDER BY updated_at_api DESC LIMIT 100)")"
    else
        _closed_prs=$(gh api "repos/$_repo/pulls?state=closed&per_page=100&sort=updated&direction=desc" \
            2>/dev/null || echo "[]")
    fi

    [[ -z "$_closed_prs" || "$_closed_prs" == "[]" ]] && return 0

    # ── Step 2: filter to closed-without-merge within lookback window ────────
    # INFRA-1313: Use closed_at (not updated_at) so PRs bumped by comments
    # don't trigger false positives. Falls back to updated_at if missing.
    local _tmp_prs
    _tmp_prs=$(mktemp /tmp/ghost-reaper-prs.XXXXXX)
    printf '%s' "$_closed_prs" > "$_tmp_prs"
    local _bounced_pr_nums
    _bounced_pr_nums=$(python3 -c "
import json, sys, datetime
lookback_days = $_lookback_days
cutoff = datetime.datetime.utcnow() - datetime.timedelta(days=lookback_days)
with open('$_tmp_prs') as f:
    prs = json.load(f)
for pr in prs:
    if pr.get('merged_at') is not None:
        continue
    if pr.get('state') != 'closed':
        continue
    ts_str = pr.get('closed_at') or pr.get('updated_at') or ''
    if ts_str:
        try:
            ts = datetime.datetime.fromisoformat(ts_str.replace('Z','+00:00')).replace(tzinfo=None)
            if ts < cutoff:
                continue
        except Exception:
            pass
    print(pr['number'])
" 2>/dev/null || true)
    rm -f "$_tmp_prs"

    [[ -z "$_bounced_pr_nums" ]] && return 0

    # ── Step 3: build closed_pr→gap_id map from state.db (no API calls) ──────
    # INFRA-1313: Exclude gaps with titles containing meta-tracking patterns
    # ([CI-RED], [ORPHAN], [DIRTY], [BEHIND], or "stuck") — these track stuck
    # PRs, not shipping PRs.
    local _done_json
    _done_json=$(CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
        "$_chump" gap list --status done --json 2>/dev/null || echo "[]")

    [[ "$_done_json" == "[]" || -z "$_done_json" ]] && return 0

    local _pr_to_gap
    _pr_to_gap=$(printf '%s' "$_done_json" | python3 -c "
import json, sys, re
m = {}
for g in json.load(sys.stdin):
    pr = g.get('closed_pr')
    if not pr:
        continue
    title = g.get('title') or ''
    if re.search(r'\[(CI-RED|ORPHAN|DIRTY|BEHIND)\]|stuck', title, re.IGNORECASE):
        continue
    m[str(pr)] = g['id']
print(json.dumps(m))
" 2>/dev/null || echo "{}")

    # ── Step 4: intersect in one Python call — no per-PR spawning ────────────
    local _tmp_map _tmp_prnums
    _tmp_map=$(mktemp /tmp/ghost-reaper-map.XXXXXX)
    _tmp_prnums=$(mktemp /tmp/ghost-reaper-nums.XXXXXX)
    printf '%s' "$_pr_to_gap"   > "$_tmp_map"
    printf '%s' "$_bounced_pr_nums" > "$_tmp_prnums"

    local _ghosts
    _ghosts=$(python3 -c "
import json
with open('$_tmp_map') as f:
    pr_to_gap = json.load(f)
with open('$_tmp_prnums') as f:
    bounced = [ln.strip() for ln in f if ln.strip()]
for pr_num in bounced:
    gap_id = pr_to_gap.get(str(pr_num), '')
    if gap_id:
        print(gap_id, pr_num)
" 2>/dev/null || true)

    rm -f "$_tmp_map" "$_tmp_prnums"

    local _rolled_back=0
    local _gid _pr_num
    while IFS=' ' read -r _gid _pr_num; do
        [[ -z "$_gid" ]] && continue

        echo "[ghost-gap-reaper] INFRA-556: rolling back $_gid — PR #$_pr_num closed without merge"
        CHUMP_BIN="$_chump" gap_reopen_allowed "$_gid" || continue
        CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 CHUMP_ALLOW_RECYCLE=1 \
            "$_chump" gap set "$_gid" --status open 2>/dev/null || {
            echo "[ghost-gap-reaper] WARNING: failed to roll back $_gid"
            continue
        }
        _emit_ambient gap_rolled_back "gap=$_gid" "pr=$_pr_num" "reason=pr_closed_without_merge"
        (( _rolled_back++ )) || true
    done <<< "$_ghosts"

    (( _rolled_back > 0 )) && echo "[ghost-gap-reaper] rolled back $_rolled_back ghost gap(s) to status=open"
    return 0
}

# ── Phase 2 (INFRA-1909, RESILIENT-070): open-but-already-merged reconciliation
#
#   RESILIENT-070: a manual run produced zero output while 21 ghost gaps sat
#   open. Root cause — those 21 gaps already had `closed_pr` populated in
#   state.db (a prior `chump gap ship` set the field but the status write
#   didn't stick), so the correct fix needed no GitHub lookup at all. The old
#   loop only ever tried the gh-search path, which is silent-failure-prone
#   (offline, rate-limited, or title/branch no longer contains the gap ID) and
#   never consulted the `closed_pr` field it already had in hand. Now: trust
#   a numeric `closed_pr` already on the gap first; only fall back to the
#   cache/gh-search lookup when that field is empty.
run_phase2() {
    if [[ "${CHUMP_GHOST_GAP_REAPER:-1}" == "0" ]]; then
        echo "[ghost-gap-reaper] INFRA-1909: phase 2 disabled via CHUMP_GHOST_GAP_REAPER=0"
        _emit_ambient ghost_gap_reaper_disabled "reason=env_bypass"
        return 0
    fi
    command -v "$_chump" >/dev/null 2>&1 || { echo "[ghost-gap-reaper] chump not found, skipping phase 2"; return 0; }
    command -v gh       >/dev/null 2>&1 || { echo "[ghost-gap-reaper] gh not found, skipping phase 2"; return 0; }
    command -v python3  >/dev/null 2>&1 || { echo "[ghost-gap-reaper] python3 not found, skipping phase 2"; return 0; }

    local _open_json
    _open_json=$(CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
        "$_chump" gap list --status open --json 2>/dev/null || echo "[]")

    [[ "$_open_json" == "[]" || -z "$_open_json" ]] && return 0

    # RESILIENT-070: emit "<id>\t<known_pr_or_empty>" — known_pr is the gap's
    # own closed_pr field when it's already a plain integer, else empty (fall
    # back to gh search).
    local _open_pairs
    _open_pairs=$(printf '%s' "$_open_json" | python3 -c "
import json, sys, re
for g in json.load(sys.stdin):
    gid = g.get('id')
    if not gid:
        continue
    pr = g.get('closed_pr')
    pr_str = str(pr).strip() if pr not in (None, '') else ''
    if pr_str and not re.fullmatch(r'\d+', pr_str):
        pr_str = ''
    print(f'{gid}\t{pr_str}')
" 2>/dev/null || true)

    [[ -z "$_open_pairs" ]] && return 0

    local _reaped=0
    local _gid _known_pr _pr_json _pr_num
    while IFS=$'\t' read -r _gid _known_pr; do
        [[ -z "$_gid" ]] && continue

        # CREDIBLE-1553 (Phase R R2 / R1): keep ONLY the known-closed_pr path.
        # Drop the title LIKE and gh pr list --search fallback, and never ship
        # with the deleted proof-of-merge bypass env var.
        [[ -n "$_known_pr" ]] || continue
        _pr_num="$_known_pr"
        echo "[ghost-gap-reaper] RESILIENT-070: reconciling $_gid — closed_pr=#$_pr_num already recorded, no PR lookup needed"

        CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
            CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
            "$_chump" gap ship "$_gid" --closed-pr "$_pr_num" --update-yaml 2>/dev/null || {
            echo "[ghost-gap-reaper] WARNING: failed to ship $_gid"
            continue
        }
        _emit_ambient ghost_gap_reaped "gap=$_gid" "pr=$_pr_num" "reaped_via=ghost-gap-reaper"
        (( _reaped++ )) || true
    done <<< "$_open_pairs"

    (( _reaped > 0 )) && echo "[ghost-gap-reaper] INFRA-1909: reaped $_reaped ghost-open gap(s) to status=done"
    return 0
}

run_phase1
run_phase2
exit 0
