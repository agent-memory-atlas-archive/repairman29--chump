#!/usr/bin/env bash
# scripts/coord/cascade-unblock-detector.sh — INFRA-2070 (META-118 sub-gap 4)
#
# Cascade-unblock detector: when a wedge_auto_fix PR merges, identify all open PRs
# whose CI failed on the same failure signature, and trigger gh pr update-branch on each.
#
# Flow:
#   1. Scan ambient.jsonl for recently-merged wedge_auto_fix PRs
#      (identified by: label "wedge_auto_fix" OR commit trailer "wedge_auto_fix: signature_hash=X")
#   2. For each merged fix PR, find open PRs whose pr_failed ambient events share the same
#      failure signature (or BEHIND state + same failure class pattern)
#   3. Apply safety guards before rebasing each matched PR
#   4. Call gh pr update-branch on each matched safe PR
#   5. Emit kind=cascade_unblocked (success) or kind=cascade_unblock_skipped (per-skip)
#
# RESILIENT-1521 generic stale sweep (runs every tick, no label / sibling needed):
#   every open PR whose mergeStateStatus is BLOCKED or DIRTY and whose base has
#   advanced past its merge-base (compare behind_by > 0) gets gh pr update-branch
#   so CI re-runs on the fresh base. Real conflicts are escalated, never resolved
#   (cascade_unblock_skipped reason=rebase_conflict). A PR we already refreshed
#   that is up to date with base yet still BLOCKED is a REAL failure: it is routed
#   once to the ci-audit curator (kind=pr_stuck reason=failing_after_fresh_base)
#   and never re-looped. State: CHUMP_UNBLOCK_STATE (pr<TAB>action<TAB>base_sha).
#
# Safety guards (NEVER skip):
#   a. Operator commented in last 30min → skip with reason=operator_recent_comment
#   b. PR has CHUMP_HOLD label → skip with reason=chump_hold_label
#   c. gh pr update-branch fails (conflict or API error) → skip with reason=rebase_conflict
#
# Env overrides:
#   CHUMP_AMBIENT_LOG                  override ambient.jsonl path
#   CHUMP_REPO / CHUMP_REPO_ROOT       override repo root
#   CHUMP_UNBLOCK_TEST_GH              path to mock gh binary (tests)
#   CHUMP_UNBLOCK_TEST_CHUMP           path to mock chump binary (tests)
#   CHUMP_UNBLOCK_LOOKBACK_S           how far back to scan for merged fix PRs (default 600)
#   CHUMP_UNBLOCK_PR_LOOKBACK_S        how far back to scan pr_failed events (default 7200)
#   CHUMP_UNBLOCK_OPERATOR_WINDOW_S    operator recency window in seconds (default 1800)
#   CHUMP_UNBLOCK_RATE_LIMIT           max rebase attempts per run (default 10)
#   CHUMP_UNBLOCK_STATE                stale-sweep state file (default <ambient dir>/cascade-unblock-state.tsv)
#   CHUMP_UNBLOCK_SKIP=1               skip env (test/emergency kill-switch)
#   CHUMP_UNBLOCK_DRY_RUN=1            dry-run mode: log but don't call gh pr update-branch
#
# Audit events emitted:
#   cascade_unblocked         — one or more PRs were queued for rebase after a fix PR merged
#   cascade_unblock_skipped   — a candidate PR was skipped (with reason field)
#
# scanner-anchor: "kind":"cascade_unblocked"
# scanner-anchor: "kind":"cascade_unblock_skipped"

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH="${CHUMP_UNBLOCK_TEST_GH:-gh}"
# shellcheck source=lib/pr_rebase.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr_rebase.sh"
# RESILIENT-1616: the shared pr-cut predicate — a deliberately cut PR is
# terminal; never rebase it in either the stale sweep or the cascade.
# shellcheck source=lib/pr-cut-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-cut-guard.sh"
_shared_rebase() { CHUMP_PR_REBASE_GH="$GH" pr_rebase_if_strict "$1" "${CHUMP_REPO:-repairman29/chump}" main; }
LIB_CACHE="$REPO_ROOT/scripts/coord/lib/github_cache.sh"

LOOKBACK_S="${CHUMP_UNBLOCK_LOOKBACK_S:-600}"
PR_LOOKBACK_S="${CHUMP_UNBLOCK_PR_LOOKBACK_S:-7200}"
OPERATOR_WINDOW_S="${CHUMP_UNBLOCK_OPERATOR_WINDOW_S:-1800}"
RATE_LIMIT="${CHUMP_UNBLOCK_RATE_LIMIT:-10}"
DRY_RUN="${CHUMP_UNBLOCK_DRY_RUN:-0}"
STATE_FILE="${CHUMP_UNBLOCK_STATE:-$(dirname "$AMBIENT")/cascade-unblock-state.tsv}"

# ── Utilities ─────────────────────────────────────────────────────────────────

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[cascade-unblock %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

emit_ambient() {
    local kind="$1" extra="${2:-}"
    local line
    local timestamp; timestamp="$(ts)"
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$timestamp\",\"kind\":\"$kind\",\"source\":\"cascade_unblock_detector\",$extra}"
    else
        line="{\"ts\":\"$timestamp\",\"kind\":\"$kind\",\"source\":\"cascade_unblock_detector\"}"
    fi
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

# ── Guard: SKIP env ───────────────────────────────────────────────────────────

if [[ "${CHUMP_UNBLOCK_SKIP:-0}" == "1" ]]; then
    log "cascade-unblock: CHUMP_UNBLOCK_SKIP=1 — skipped"
    exit 0
fi

# ── Load cache lib (optional, degrades gracefully) ────────────────────────────

_CACHE_AVAILABLE=0
if [[ -f "$LIB_CACHE" ]]; then
    # shellcheck source=scripts/coord/lib/github_cache.sh
    # shellcheck disable=SC1091  # path is dynamic (env-overridable); source-directive above is the hint
    source "$LIB_CACHE" 2>/dev/null && _CACHE_AVAILABLE=1 || true
fi

# ── Daemon tick emit (INFRA-2280 META-118 scheduling activation) ─────────────
emit_ambient "meta_118_daemon_tick" "\"daemon\":\"cascade-unblock-detector\""

# ── Step 1: Find recently-merged wedge_auto_fix PRs ──────────────────────────
#
# Two discovery paths:
#   A. ambient.jsonl: scan for gap_shipped or pull_request_merged events where
#      the PR has label wedge_auto_fix or a commit trailer wedge_auto_fix: signature_hash=X
#   B. gh api: query PRs closed in last LOOKBACK_S with label wedge_auto_fix
#
# We read PR commit messages / trailer via gh pr view --json commits.
# signature_hash is extracted from the trailer "wedge_auto_fix: signature_hash=X"
# If no trailer, we use the PR label "wedge_auto_fix" + derive hash from PR number.

log "cascade-unblock: scanning for recently-merged wedge_auto_fix PRs..."

cutoff_epoch() {
    local delta="$1"
    date -u -v-"${delta}"S +%s 2>/dev/null \
        || date -u -d "-${delta} seconds" +%s 2>/dev/null \
        || echo "0"
}

FIX_CUTOFF="$(cutoff_epoch "$LOOKBACK_S")"
PR_FAIL_CUTOFF="$(cutoff_epoch "$PR_LOOKBACK_S")"
NOW_EPOCH="$(date -u +%s 2>/dev/null || echo "0")"

# Query recently-closed PRs with wedge_auto_fix label via gh
# Returns: "pr_number\tsignature_hash" per line
find_fix_prs() {
    local pr_list=""

    # Try cache first
    if [[ "$_CACHE_AVAILABLE" == "1" ]]; then
        # shellcheck disable=SC2034  # pr_list populated for cache warm-up; gh path below is primary
        pr_list="$(cache_query_open_prs_by_title "wedge_auto_fix" 2>/dev/null || true)"
    fi

    # Query closed PRs with wedge_auto_fix label via gh api (background criticality)
    local gh_output=""
    gh_output="$(CHUMP_GH_CALL_CRITICALITY=background \
        "$GH" pr list --state merged --label "wedge_auto_fix" \
        --json number,mergedAt,title \
        --limit 20 \
        2>/dev/null || true)"

    if [[ -z "$gh_output" ]]; then
        log "find_fix_prs: no merged PRs with wedge_auto_fix label found via gh"
        return 0
    fi

    # Filter to those merged within LOOKBACK_S; extract signature from title/body
    python3 - "$gh_output" "$FIX_CUTOFF" <<'PY' 2>/dev/null || true
import json, sys, datetime, re

try:
    prs = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

try:
    cutoff = int(sys.argv[2])
except Exception:
    cutoff = 0

for pr in prs:
    merged_at = pr.get("mergedAt") or ""
    if not merged_at:
        continue
    try:
        t = datetime.datetime.strptime(merged_at, "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        epoch = 0
    if epoch < cutoff:
        continue
    number = pr.get("number", 0)
    title  = pr.get("title", "")
    # Try to extract signature_hash from title: "wedge_auto_fix: signature_hash=XXXX"
    m = re.search(r'signature_hash[=:]([0-9a-f]+)', title, re.IGNORECASE)
    sig = m.group(1) if m else f"pr{number}"
    print(f"{number}\t{sig}")
PY
}

# ── Step 2: Find open PRs with matching failure signature ─────────────────────
#
# For each fix PR / signature, scan ambient.jsonl for pr_failed events within
# PR_LOOKBACK_S that carry the same signature_hash (or failure_class / wedge_class).
# Also accept BEHIND PRs that haven't been updated since the fix PR merged.

find_blocked_prs_for_signature() {
    local sig="$1"
    local source_pr_number="$2"

    if [[ ! -f "$AMBIENT" ]]; then
        return 0
    fi

    # Scan pr_failed events for matching signature
    python3 - "$AMBIENT" "$sig" "$source_pr_number" "$PR_FAIL_CUTOFF" <<'PY' 2>/dev/null || true
import json, sys, datetime, re

ambient_path   = sys.argv[1]
target_sig     = sys.argv[2].lower()
source_pr      = int(sys.argv[3])
try:
    cutoff = int(sys.argv[4])
except Exception:
    cutoff = 0

matched_prs = set()

try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            kind = d.get("kind", "")
            if kind not in ("pr_failed", "wedge_detected", "wedge_class_detected"):
                continue
            ts_str = d.get("ts", "")
            try:
                t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
                epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
            except Exception:
                epoch = 0
            if epoch < cutoff:
                continue
            pr_num = d.get("pr_number") or d.get("pr_num") or 0
            try:
                pr_num = int(pr_num)
            except Exception:
                pr_num = 0
            if pr_num == 0 or pr_num == source_pr:
                continue
            # Match signature by: failure_signature, wedge_class, signature_hash
            fields = [
                str(d.get("failure_signature", "") or ""),
                str(d.get("wedge_class", "") or ""),
                str(d.get("signature_hash", "") or ""),
                str(d.get("failing_class", "") or ""),
            ]
            for f_val in fields:
                if f_val.lower() == target_sig or (
                    len(target_sig) > 4 and target_sig in f_val.lower()
                ):
                    matched_prs.add(pr_num)
                    break
except Exception:
    pass

for pr in sorted(matched_prs):
    print(pr)
PY
}

# ── Step 3: Safety checks ─────────────────────────────────────────────────────

# Check if operator commented on a PR in the last OPERATOR_WINDOW_S seconds
# Returns 0 if safe (no recent operator comment), 1 if blocked
operator_commented_recently() {
    local pr_num="$1"
    local since_epoch
    since_epoch="$(( NOW_EPOCH - OPERATOR_WINDOW_S ))"

    local pr_json=""
    pr_json="$(CHUMP_GH_CALL_CRITICALITY=background \
        "$GH" pr view "$pr_num" \
        --json comments \
        2>/dev/null || true)"

    if [[ -z "$pr_json" ]]; then
        # Cannot fetch PR — treat as safe (don't block on API error)
        return 0
    fi

    local recent_commenters=""
    recent_commenters="$(python3 - "$pr_json" "$since_epoch" <<'PY' 2>/dev/null || true
import json, sys, datetime
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
try:
    since = int(sys.argv[2])
except Exception:
    since = 0
comments = d.get("comments", []) or []
for c in comments:
    created = c.get("createdAt", "") or ""
    try:
        t = datetime.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
        epoch = int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        epoch = 0
    if epoch >= since:
        login = (c.get("author") or {}).get("login", "unknown")
        print(login)
PY
)"

    if [[ -n "$recent_commenters" ]]; then
        log "safety: PR #$pr_num has operator comment in last ${OPERATOR_WINDOW_S}s from: $(printf '%s' "$recent_commenters" | tr '\n' ',')"
        return 1
    fi
    return 0
}

# Check if PR has CHUMP_HOLD label
pr_has_hold_label() {
    local pr_num="$1"
    local labels_json=""

    # Try cache first
    if [[ "$_CACHE_AVAILABLE" == "1" ]]; then
        labels_json="$(cache_lookup_pr "$pr_num" --max-age-s 300 2>/dev/null || true)"
    fi

    if [[ -z "$labels_json" ]]; then
        labels_json="$(CHUMP_GH_CALL_CRITICALITY=background \
            "$GH" pr view "$pr_num" \
            --json labels \
            2>/dev/null || true)"
    fi

    if [[ -z "$labels_json" ]]; then
        return 1  # cannot fetch — assume no hold
    fi

    local has_hold=""
    has_hold="$(python3 - "$labels_json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
labels = d.get("labels", []) or []
for l in labels:
    name = l.get("name", "") if isinstance(l, dict) else str(l)
    if "CHUMP_HOLD" in name.upper():
        print("yes")
        break
PY
)"

    if [[ "$has_hold" == "yes" ]]; then
        log "safety: PR #$pr_num has CHUMP_HOLD label"
        return 0  # has hold
    fi
    return 1  # no hold
}

# ── Step 3b: Generic stale sweep (RESILIENT-1521) ─────────────────────────────
#
# Independent of wedge_auto_fix labels / same-signature siblings: any open PR that
# is BLOCKED or DIRTY and stale against an advanced base is update-branch'd.

# Prints "<pr>\t<state>\t<behind_by>\t<base_sha>" per open BLOCKED/DIRTY PR.
find_stale_prs() {
    local list
    list="$(CHUMP_GH_CALL_CRITICALITY=background "$GH" pr list --state open \
        --json number,mergeStateStatus,baseRefName,headRefOid --limit 100 2>/dev/null || true)"
    [[ -z "$list" ]] && return 0
    local rows
    rows="$(python3 - "$list" <<'PY' 2>/dev/null || true
import json, sys
try:
    prs = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for p in prs:
    st = (p.get("mergeStateStatus") or "").upper()
    if st in ("BLOCKED", "DIRTY"):
        print("%s\t%s\t%s\t%s" % (p.get("number"), st, p.get("baseRefName") or "main", p.get("headRefOid") or ""))
PY
)"
    local num st base head cmp behind
    while IFS=$'\t' read -r num st base head; do
        [[ -z "$num" ]] && continue
        cmp="$(CHUMP_GH_CALL_CRITICALITY=background "$GH" api \
            "repos/{owner}/{repo}/compare/${base}...${head}" 2>/dev/null || true)"
        behind="$(python3 - "$cmp" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.loads(sys.argv[1])
    print("%s\t%s" % (int(d.get("behind_by", 0)), (d.get("merge_base_commit") or {}).get("sha", "")))
except Exception:
    print("0\t")
PY
)"
        printf '%s\t%s\t%s\t%s\n' "$num" "$st" "${behind%%$'\t'*}" "${behind#*$'\t'}"
    done <<< "$rows"
}

state_get() { [[ -f "$STATE_FILE" ]] && awk -F'\t' -v p="$1" '$1==p{v=$2"\t"$3} END{print v}' "$STATE_FILE"; }
state_set() {
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    { [[ -f "$STATE_FILE" ]] && awk -F'\t' -v p="$1" '$1!=p' "$STATE_FILE"; printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } \
        > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
}

stale_sweep() {
    local rows attempted=0 ok=0 conflict=0 routed=0 skipped=0
    rows="$(find_stale_prs)"
    if [[ -z "$rows" ]]; then
        log "stale-sweep: no BLOCKED/DIRTY open PRs"
        return 0
    fi
    local num st behind mb prev prev_action prev_mb
    while IFS=$'\t' read -r num st behind mb; do
        [[ -z "$num" ]] && continue
        prev="$(state_get "$num")"
        prev_action="${prev%%$'\t'*}"; prev_mb="${prev#*$'\t'}"

        if [[ "${behind:-0}" -le 0 ]]; then
            # Up to date with base. If we already refreshed it and it is still
            # BLOCKED, the failure is real: hand to ci-audit once, no re-loop.
            if [[ "$prev_action" == "refreshed" ]]; then
                emit_ambient "pr_stuck" \
                    "\"pr_number\":$num,\"reason\":\"failing_after_fresh_base\",\"merge_state\":\"$st\",\"route\":\"ci-audit\""
                emit_ambient "cascade_unblock_skipped" \
                    "\"source_pr\":0,\"signature_hash\":\"stale_sweep\",\"pr_number\":$num,\"reason\":\"failing_after_fresh_base\""
                state_set "$num" "routed" "$mb"
                routed=$(( routed + 1 ))
            fi
            continue
        fi

        # Stale vs advanced base. A conflict is only retried once the base moves again.
        if [[ "$prev_action" == "conflict" && "$prev_mb" == "$mb" ]]; then
            continue
        fi
        if [[ "$TOTAL_ATTEMPTED" -ge "$RATE_LIMIT" ]]; then
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":0,\"signature_hash\":\"stale_sweep\",\"pr_number\":$num,\"reason\":\"rate_limit_reached\",\"rate_limit\":$RATE_LIMIT"
            skipped=$(( skipped + 1 )); continue
        fi
        if ! operator_commented_recently "$num"; then
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":0,\"signature_hash\":\"stale_sweep\",\"pr_number\":$num,\"reason\":\"operator_recent_comment\",\"window_s\":$OPERATOR_WINDOW_S"
            skipped=$(( skipped + 1 )); continue
        fi
        if pr_has_hold_label "$num"; then
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":0,\"signature_hash\":\"stale_sweep\",\"pr_number\":$num,\"reason\":\"chump_hold_label\""
            skipped=$(( skipped + 1 )); continue
        fi

        # RESILIENT-1616: never rebase a deliberately cut PR.
        if pr_cut_honored "$num" "cascade-unblock-detector.sh" "rebase"; then
            log "stale-sweep: PR #$num is pr-cut (terminal; RESILIENT-1616) — skipping"
            continue
        fi
        TOTAL_ATTEMPTED=$(( TOTAL_ATTEMPTED + 1 )); attempted=$(( attempted + 1 ))
        if [[ "$DRY_RUN" == "1" ]]; then
            log "stale-sweep: DRY_RUN — would call: gh pr update-branch $num ($st, behind=$behind)"
            ok=$(( ok + 1 )); continue
        fi
        log "stale-sweep: gh pr update-branch $num ($st, behind=$behind)"
        if _shared_rebase "$num" 2>/dev/null; then
            state_set "$num" "refreshed" "$mb"
            ok=$(( ok + 1 ))
        else
            state_set "$num" "conflict" "$mb"
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":0,\"signature_hash\":\"stale_sweep\",\"pr_number\":$num,\"reason\":\"rebase_conflict\",\"merge_state\":\"$st\""
            conflict=$(( conflict + 1 ))
        fi
    done <<< "$rows"

    (( attempted + routed + skipped + conflict > 0 )) && emit_ambient "cascade_unblocked" \
        "\"source_pr\":0,\"signature_hash\":\"stale_sweep\",\"matched_pr_numbers\":\"\",\"rebase_attempt_count\":$attempted,\"success_count\":$ok,\"conflict_count\":$conflict,\"skipped_count\":$skipped,\"routed_ci_audit\":$routed"
    log "stale-sweep: attempted=$attempted ok=$ok conflict=$conflict routed_ci_audit=$routed skipped=$skipped"
}

TOTAL_ATTEMPTED=0
stale_sweep

# ── Step 4 + 5: Main cascade-unblock loop ─────────────────────────────────────

FIX_PRS="$(find_fix_prs)"

if [[ -z "$FIX_PRS" ]]; then
    log "cascade-unblock: no recently-merged wedge_auto_fix PRs found — nothing to do"
    exit 0
fi

log "cascade-unblock: found fix PRs:"$'\n'"$FIX_PRS"

TOTAL_SUCCESS=0
TOTAL_CONFLICT=0
TOTAL_SKIPPED=0

while IFS=$'\t' read -r source_pr sig_hash; do
    [[ -z "$source_pr" ]] && continue
    log "cascade-unblock: processing fix PR #$source_pr (signature=$sig_hash)"

    # Find PRs blocked by the same signature
    BLOCKED_PRS="$(find_blocked_prs_for_signature "$sig_hash" "$source_pr")"

    if [[ -z "$BLOCKED_PRS" ]]; then
        log "cascade-unblock: no matching blocked PRs for signature=$sig_hash"
        continue
    fi

    log "cascade-unblock: matched PRs for signature=$sig_hash: $(printf '%s' "$BLOCKED_PRS" | tr '\n' ',')"

    ALL_MATCHED_PRS=()
    SUCCESS_PRS=()
    CONFLICT_PRS=()

    while IFS= read -r pr_num; do
        [[ -z "$pr_num" ]] && continue

        ALL_MATCHED_PRS+=("$pr_num")

        # Rate limit check
        if [[ "$TOTAL_ATTEMPTED" -ge "$RATE_LIMIT" ]]; then
            log "cascade-unblock: rate limit $RATE_LIMIT reached — stopping"
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":$source_pr,\"signature_hash\":\"$sig_hash\",\"pr_number\":$pr_num,\"reason\":\"rate_limit_reached\",\"rate_limit\":$RATE_LIMIT"
            TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
            continue
        fi

        # Safety guard (a): operator commented recently
        if ! operator_commented_recently "$pr_num"; then
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":$source_pr,\"signature_hash\":\"$sig_hash\",\"pr_number\":$pr_num,\"reason\":\"operator_recent_comment\",\"window_s\":$OPERATOR_WINDOW_S"
            TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
            continue
        fi

        # Safety guard (b): PR has CHUMP_HOLD label
        if pr_has_hold_label "$pr_num"; then
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":$source_pr,\"signature_hash\":\"$sig_hash\",\"pr_number\":$pr_num,\"reason\":\"chump_hold_label\""
            TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
            continue
        fi

        # RESILIENT-1616: never rebase a deliberately cut PR.
        if pr_cut_honored "$pr_num" "cascade-unblock-detector.sh" "rebase"; then
            log "cascade-unblock: PR #$pr_num is pr-cut (terminal; RESILIENT-1616) — skipping"
            continue
        fi
        TOTAL_ATTEMPTED=$(( TOTAL_ATTEMPTED + 1 ))

        if [[ "$DRY_RUN" == "1" ]]; then
            log "cascade-unblock: DRY_RUN — would call: gh pr update-branch $pr_num"
            SUCCESS_PRS+=("$pr_num")
            TOTAL_SUCCESS=$(( TOTAL_SUCCESS + 1 ))
            continue
        fi

        # Safety guard (c): attempt rebase; failure = conflict or API error
        log "cascade-unblock: calling gh pr update-branch $pr_num"
        if _shared_rebase "$pr_num" 2>/dev/null; then
            log "cascade-unblock: PR #$pr_num rebase succeeded"
            SUCCESS_PRS+=("$pr_num")
            TOTAL_SUCCESS=$(( TOTAL_SUCCESS + 1 ))
        else
            log "cascade-unblock: PR #$pr_num rebase FAILED (conflict or API error)"
            CONFLICT_PRS+=("$pr_num")
            TOTAL_CONFLICT=$(( TOTAL_CONFLICT + 1 ))
            emit_ambient "cascade_unblock_skipped" \
                "\"source_pr\":$source_pr,\"signature_hash\":\"$sig_hash\",\"pr_number\":$pr_num,\"reason\":\"rebase_conflict\""
        fi

    done < <(printf '%s\n' "$BLOCKED_PRS")

    # Build matched_pr_numbers CSV
    matched_csv="$(printf '%s\n' "${ALL_MATCHED_PRS[@]+"${ALL_MATCHED_PRS[@]}"}" | tr '\n' ',' | sed 's/,$//')"
    success_count=${#SUCCESS_PRS[@]}
    conflict_count=${#CONFLICT_PRS[@]}
    rebase_attempt_count=$(( success_count + conflict_count ))

    # Emit cascade_unblocked even if some failed — records what happened
    emit_ambient "cascade_unblocked" \
        "\"source_pr\":$source_pr,\"signature_hash\":\"$sig_hash\",\"matched_pr_numbers\":\"$matched_csv\",\"rebase_attempt_count\":$rebase_attempt_count,\"success_count\":$success_count,\"conflict_count\":$conflict_count,\"skipped_count\":$TOTAL_SKIPPED"

    log "cascade-unblock: fix PR #$source_pr done — matched=${#ALL_MATCHED_PRS[@]} success=$success_count conflict=$conflict_count skipped=$TOTAL_SKIPPED"

done < <(printf '%s\n' "$FIX_PRS")

log "cascade-unblock: run complete — total_attempted=$TOTAL_ATTEMPTED success=$TOTAL_SUCCESS conflict=$TOTAL_CONFLICT skipped=$TOTAL_SKIPPED"

exit 0
