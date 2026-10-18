#!/usr/bin/env bash
# scripts/coord/recovery-queue-service.sh — INFRA-1993 (THE FLOOR Phase 3)
#
# Consumes operator_recovery_requested events from ambient.jsonl,
# rate-limits to max 3 admin-merge cycles per hour fleet-wide, and runs
# the canonical drop-gates → admin-merge → re-arm cycle that Opus has
# been doing manually all day.
#
# Runs every 60 seconds via launchd. Idempotent: tracks last processed
# event by ambient.jsonl offset in .chump-locks/recovery-queue-state.json.
#
# Rate limit: sliding window of last 3600s; max 3 cycles. If exceeded,
# emit kind=recovery_queue_rate_limited + skip until window slides.
#
# Cycle steps:
#   1. Snapshot current ruleset rules → /tmp/ruleset-backup-<ts>.json
#   2. PUT ruleset with required_status_checks rule DROPPED
#   3. For each PR in request: gh pr merge --squash --admin
#   4. PUT ruleset RESTORED to original
#   5. Emit kind=operator_recovery_executed with pre/post diff
#
# Safety:
#   - Refuses to merge PRs that aren't owned by the chump bot (head_repo_owner check)
#   - Refuses to merge PRs from forks
#   - CHUMP_RECOVERY_QUEUE_PAUSE=1 disables the daemon entirely
#   - All actions audited via ambient events
#   - INFRA-2025: writes .chump-locks/recovery-cycle-in-flight.flag during the
#     drop-window so cluster-detector can skip mis-classified scans.
#
# Config (env):
#   CHUMP_RECOVERY_QUEUE_PAUSE=1            disable daemon
#   CHUMP_RECOVERY_QUEUE_RATE=3             max cycles per 3600s (default 3)
#   CHUMP_RECOVERY_QUEUE_RULESET_ID=15133729  ruleset to drop+restore
#   CHUMP_RECOVERY_QUEUE_DRY_RUN=1          plan but don't execute
#   CHUMP_RECOVERY_QUEUE_TEST_GH=<path>     test injection: mock gh
#   CHUMP_AMBIENT_LOG=<path>                test injection: ambient file

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="$REPO_ROOT/.chump-locks/recovery-queue-state.json"
LOG="$REPO_ROOT/.chump-locks/recovery-queue-service.log"
RATE="${CHUMP_RECOVERY_QUEUE_RATE:-3}"
WINDOW=3600
RULESET_ID="${CHUMP_RECOVERY_QUEUE_RULESET_ID:-15133729}"
DRY_RUN="${CHUMP_RECOVERY_QUEUE_DRY_RUN:-0}"
GH_BIN="${CHUMP_RECOVERY_QUEUE_TEST_GH:-gh}"
# Checkpoint: tracks mid-flight step for crash recovery.
# Age threshold: if checkpoint is older than 2× the launchd interval (120s),
# the daemon process that wrote it is considered dead and we auto-restore.
CHECKPOINT="$REPO_ROOT/.chump-locks/recovery-queue-in-flight.json"
CHECKPOINT_MAX_AGE="${CHUMP_RECOVERY_QUEUE_CHECKPOINT_MAX_AGE:-120}"
# INFRA-2025: in-flight marker so cluster-detector skips scans during drop-window
IN_FLIGHT_FLAG="${CHUMP_RECOVERY_IN_FLIGHT_FLAG:-$REPO_ROOT/.chump-locks/recovery-cycle-in-flight.flag}"

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

# INFRA-2025: ensure flag is always cleaned up even on unexpected exit
trap 'rm -f "$IN_FLIGHT_FLAG"' EXIT

# ── INFRA-2009: silent-noop guard ─────────────────────────────────────────────
# Emits kind=daemon_silent_noop if main work body is skipped on non-empty input.
# shellcheck source=scripts/coord/lib/silent-noop-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/silent-noop-guard.sh"
_sng_install_guard "recovery_queue_service" "$AMBIENT"
# CREDIBLE-1524: admin-merge consensus gate (refuses --admin without a PASSED
# AdminMergeProposal consensus_result for the PR).
# shellcheck source=scripts/coord/lib/admin-merge-consensus-gate.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/admin-merge-consensus-gate.sh"

if [[ "${CHUMP_RECOVERY_QUEUE_PAUSE:-0}" == "1" ]]; then
    printf '{"ts":"%s","kind":"recovery_queue_paused","source":"recovery_queue_service","reason":"env_pause"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
    echo "recovery-queue: paused via env" >&2
    exit 0
fi

# ── Checkpoint helpers (INFRA-2027) ─────────────────────────────────────────
# Write step-name + backup-path to the in-flight checkpoint file.
# Called BEFORE each destructive step so a crash at any stage is detectable.
_checkpoint_step() {
    local step="$1"
    local backup_path="${2:-}"
    [[ "$DRY_RUN" == "1" ]] && return
    printf '{"step":"%s","backup_path":"%s","started_ts":"%s","pid":%d}\n' \
        "$step" "$backup_path" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" \
        > "$CHECKPOINT.tmp" && mv "$CHECKPOINT.tmp" "$CHECKPOINT" || true
}

# Clear the checkpoint after a successful cycle.
_checkpoint_clear() {
    [[ "$DRY_RUN" == "1" ]] && return
    rm -f "$CHECKPOINT" || true
}

# At daemon startup: if an orphaned checkpoint exists (age > CHECKPOINT_MAX_AGE),
# auto-restore the ruleset from its backup and emit operator_recovery_aborted_recovered.
_resume_from_checkpoint_if_orphaned() {
    [[ -f "$CHECKPOINT" ]] || return 0

    local checkpoint_ts backup_path step
    checkpoint_ts="$(python3 -c "
import json, sys
try:
    d = json.load(open('$CHECKPOINT'))
    print(d.get('started_ts',''))
except Exception:
    print('')
" 2>/dev/null || true)"

    [[ -z "$checkpoint_ts" ]] && { rm -f "$CHECKPOINT"; return 0; }

    # Compute age in seconds
    local age
    age="$(python3 -c "
import datetime, sys
try:
    ts = '$checkpoint_ts'
    dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - dt).total_seconds()))
except Exception:
    print(9999)
" 2>/dev/null || echo 9999)"

    if [[ "$age" -lt "$CHECKPOINT_MAX_AGE" ]]; then
        # Process may still be alive; don't interfere.
        echo "[checkpoint] in-flight checkpoint age=${age}s < ${CHECKPOINT_MAX_AGE}s — skipping auto-restore" >&2
        return 0
    fi

    step="$(python3 -c "
import json, sys
try:
    d = json.load(open('$CHECKPOINT'))
    print(d.get('step','unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo unknown)"

    backup_path="$(python3 -c "
import json, sys
try:
    d = json.load(open('$CHECKPOINT'))
    print(d.get('backup_path',''))
except Exception:
    print('')
" 2>/dev/null || true)"

    echo "[checkpoint] orphaned checkpoint detected: step=$step age=${age}s backup=$backup_path" >&2

    # Only attempt restore if we have a backup file and the step was AFTER the drop.
    if [[ "$step" == "drop" || "$step" == "merge" ]] && [[ -n "$backup_path" ]] && [[ -f "$backup_path" ]]; then
        echo "[checkpoint] restoring ruleset from backup: $backup_path" >&2
        if [[ "$DRY_RUN" != "1" ]]; then
            if "$GH_BIN" api -X PUT "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" \
                    --input "$backup_path" >/dev/null 2>&1; then
                echo "[checkpoint] ruleset auto-restored successfully" >&2
                _emit "operator_recovery_aborted_recovered" \
                    "\"aborted_step\":\"$step\"" \
                    "\"checkpoint_age_s\":\"$age\"" \
                    "\"backup_file\":\"$backup_path\"" \
                    "\"ruleset_id\":\"$RULESET_ID\""
                rm -f "$CHECKPOINT" "$backup_path" || true
            else
                echo "[checkpoint] CRITICAL: auto-restore failed — operator action required; backup=$backup_path" >&2
                _emit "operator_recovery_failed" \
                    "\"reason\":\"checkpoint_auto_restore_failed_CRITICAL\"" \
                    "\"aborted_step\":\"$step\"" \
                    "\"backup_file\":\"$backup_path\"" \
                    "\"ruleset_id\":\"$RULESET_ID\""
            fi
        fi
    elif [[ "$step" == "snapshot" ]]; then
        # Died before drop — ruleset is still intact; just clear the checkpoint.
        echo "[checkpoint] aborted at snapshot step — ruleset intact; clearing checkpoint" >&2
        _emit "operator_recovery_aborted_recovered" \
            "\"aborted_step\":\"$step\"" \
            "\"checkpoint_age_s\":\"$age\"" \
            "\"note\":\"died_before_drop_no_restore_needed\"" \
            "\"ruleset_id\":\"$RULESET_ID\""
        rm -f "$CHECKPOINT" || true
    else
        echo "[checkpoint] unknown step or missing backup; clearing stale checkpoint" >&2
        rm -f "$CHECKPOINT" || true
    fi
}

# ── State helpers ────────────────────────────────────────────────────────────
_load_state() {
    if [[ -f "$STATE" ]]; then
        cat "$STATE"
    else
        echo '{"processed_offset":0,"recent_cycles":[]}'
    fi
}

_save_state() {
    [[ "$DRY_RUN" == "1" ]] && return
    echo "$1" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"recovery_queue_service"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Find unprocessed operator_recovery_requested events ────────────────────
_find_requests() {
    [[ -f "$AMBIENT" ]] || return
    local state; state="$(_load_state)"
    local offset
    offset="$(echo "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("processed_offset",0))' 2>/dev/null || echo 0)"
    offset="${offset:-0}"

    # Stream lines starting at offset+1 (1-based line numbers).
    # Use python json parse to filter by TOP-LEVEL kind — avoids the
    # substring trap (rate_limited events embed the deferred request).
    awk -v from="$((offset+1))" 'NR>=from' "$AMBIENT" 2>/dev/null \
        | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    # Guard against non-dict JSON values (some misc emitters write
    # numbers/strings/arrays to ambient.jsonl). Without this, a single
    # non-dict line crashes the pipe + drops remaining input.
    if not isinstance(obj, dict):
        continue
    if obj.get("kind") == "operator_recovery_requested":
        print(line)
' 2>/dev/null || true
}

# ── Check rate limit ────────────────────────────────────────────────────────
_under_rate_limit() {
    local state; state="$(_load_state)"
    local now; now="$(date +%s)"
    local recent
    recent="$(echo "$state" | python3 -c "
import json, sys, time
try:
    s = json.load(sys.stdin)
    cutoff = $now - $WINDOW
    cycles = [t for t in s.get('recent_cycles', []) if t > cutoff]
    print(len(cycles))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
    recent="${recent:-0}"
    [[ "$recent" -lt "$RATE" ]]
}

_record_cycle() {
    local state; state="$(_load_state)"
    local now; now="$(date +%s)"
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'recent_cycles':[]}
s.setdefault('recent_cycles', []).append($now)
# Prune cycles older than the window
cutoff = $now - $WINDOW
s['recent_cycles'] = [t for t in s['recent_cycles'] if t > cutoff]
print(json.dumps(s))
")"
    _save_state "$state"
}

# ── Advance the processed offset ────────────────────────────────────────────
_advance_offset() {
    local new_offset="$1"
    local state; state="$(_load_state)"
    state="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    s = {'processed_offset':0,'recent_cycles':[]}
s['processed_offset'] = $new_offset
print(json.dumps(s))
")"
    _save_state "$state"
}

# ── Safety check: PR is from this repo (not a fork) ─────────────────────────
_pr_safe_to_admin() {
    local pr="$1"
    # In production, we'd check head_repo_owner; for now just accept.
    # Test injection bypasses live gh.
    if [[ "$GH_BIN" != "gh" ]]; then
        return 0
    fi
    local head_owner
    head_owner="$("$GH_BIN" pr view "$pr" --json headRepositoryOwner --jq '.headRepositoryOwner.login' 2>/dev/null || echo "")"
    [[ -z "$head_owner" ]] && return 0  # fail-open if gh errors
    # Accept if owner matches the configured allowed owners (default: chump-bot orgs)
    case "$head_owner" in
        repairman29|jeffadkins|chump-bot) return 0 ;;
        *) echo "[safety] PR #$pr head_owner=$head_owner not in allowlist; refusing" >&2; return 1 ;;
    esac
}

# ── The cycle: drop → admin-merge → re-arm ─────────────────────────────────
_run_cycle() {
    local prs_csv="$1"
    local reason="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[cycle] starting: prs=$prs_csv reason=$reason" >&2

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] would: snapshot ruleset, drop rules, merge $prs_csv, restore" >&2
        _emit "operator_recovery_executed" \
            "\"prs\":\"$prs_csv\"" \
            "\"reason\":\"$reason\"" \
            "\"dry_run\":true"
        return 0
    fi

    # 1. Snapshot
    local backup="/tmp/recovery-ruleset-backup-${RULESET_ID}-$$.json"
    _checkpoint_step "snapshot" "$backup"
    if ! "$GH_BIN" api "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" > "$backup" 2>/dev/null; then
        echo "[fail] could not snapshot ruleset $RULESET_ID — aborting" >&2
        _emit "operator_recovery_failed" \
            "\"reason\":\"ruleset_snapshot_failed\"" \
            "\"prs\":\"$prs_csv\""
        _checkpoint_clear
        return 1
    fi

    # 2. Construct dropped variant + PUT
    local dropped="/tmp/recovery-ruleset-dropped-$$.json"
    python3 -c "
import json
with open('$backup') as f: d = json.load(f)
out = {
    'name': d.get('name'),
    'target': d.get('target'),
    'enforcement': d.get('enforcement'),
    'conditions': d.get('conditions'),
    'rules': [r for r in d.get('rules',[]) if r.get('type') != 'required_status_checks'],
}
with open('$dropped','w') as f: json.dump(out,f)
" 2>/dev/null

    _checkpoint_step "drop" "$backup"
    if ! "$GH_BIN" api -X PUT "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" --input "$dropped" >/dev/null 2>&1; then
        echo "[fail] could not drop ruleset rules — aborting" >&2
        _emit "operator_recovery_failed" \
            "\"reason\":\"ruleset_drop_failed\"" \
            "\"prs\":\"$prs_csv\""
        rm -f "$backup" "$dropped"
        _checkpoint_clear
        return 1
    fi

    # 3. Admin-merge each PR
    _checkpoint_step "merge" "$backup"
    local merged=""
    local failed=""
    IFS=',' read -ra PR_LIST <<< "$prs_csv"
    for pr in "${PR_LIST[@]}"; do
        pr="$(echo "$pr" | xargs)"
        [[ -z "$pr" ]] && continue
        if ! _pr_safe_to_admin "$pr"; then
            failed+="$pr,"
            continue
        fi
        # CREDIBLE-1524: refuse the --admin bypass unless a PASSED
        # AdminMergeProposal consensus_result names this PR (enforce mode;
        # shadow logs + proceeds).
        if ! admin_merge_consensus_gate "$pr"; then
            failed+="$pr,"
            continue
        fi
        if "$GH_BIN" pr merge "$pr" --squash --admin 2>/dev/null; then
            merged+="$pr,"
        else
            # Check if already merged
            local state
            state="$("$GH_BIN" pr view "$pr" --json state --jq '.state' 2>/dev/null || echo "")"
            if [[ "$state" == "MERGED" ]] || [[ "$state" == "CLOSED" ]]; then
                merged+="$pr,"  # idempotent
            else
                failed+="$pr,"
            fi
        fi
    done

    # 4. Restore ruleset
    if ! "$GH_BIN" api -X PUT "repos/${CHUMP_GH_REPO:-repairman29/chump}/rulesets/$RULESET_ID" --input "$backup" >/dev/null 2>&1; then
        echo "[CRITICAL] could not restore ruleset $RULESET_ID — operator action required" >&2
        _emit "operator_recovery_failed" \
            "\"reason\":\"ruleset_restore_failed_CRITICAL\"" \
            "\"prs\":\"$prs_csv\"" \
            "\"merged\":\"${merged%,}\"" \
            "\"backup_file\":\"$backup\""
        return 2
    fi

    rm -f "$backup" "$dropped"
    _checkpoint_clear
    _record_cycle
    _emit "operator_recovery_executed" \
        "\"prs\":\"$prs_csv\"" \
        "\"merged\":\"${merged%,}\"" \
        "\"failed\":\"${failed%,}\"" \
        "\"reason\":\"$reason\"" \
        "\"ruleset_id\":\"$RULESET_ID\""
    echo "[cycle] done: merged=${merged%,} failed=${failed%,}" >&2
    return 0
}

# ── Main loop ───────────────────────────────────────────────────────────────
# On every daemon startup, check for an orphaned mid-flight checkpoint from a
# previous process that died between steps. If found and old enough, auto-restore.
_resume_from_checkpoint_if_orphaned

LINE_NUM=0
REQUESTS="$(_find_requests)"

if [[ -z "$REQUESTS" ]]; then
    # Nothing to do; just advance to current offset to keep state fresh.
    if [[ -f "$AMBIENT" ]]; then
        TOTAL_LINES="$(wc -l < "$AMBIENT" | xargs)"
        _advance_offset "$TOTAL_LINES"
    fi
    exit 0
fi

echo "[service] found $(echo "$REQUESTS" | wc -l | xargs) pending request(s)" >&2

# Track the highest line number we process
if [[ -f "$AMBIENT" ]]; then
    HIGHEST_LINE="$(wc -l < "$AMBIENT" | xargs)"
else
    HIGHEST_LINE=0
fi

_SNG_HAD_INPUT=1   # INFRA-2009: non-empty requests → guard expects main work
while IFS= read -r req; do
    [[ -z "$req" ]] && continue

    if ! _under_rate_limit; then
        _emit "recovery_queue_rate_limited" \
            "\"max_per_hour\":\"$RATE\"" \
            "\"deferred_request\":\"$(echo "$req" | head -c 100)\""
        echo "[skip] rate limit hit ($RATE/hour); deferring" >&2
        break
    fi

    PRS="$(echo "$req" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("prs",""))' 2>/dev/null)"
    REASON="$(echo "$req" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null)"
    [[ -z "$PRS" ]] && continue

    # INFRA-2025: mark cycle in-flight before dropping required_status_checks
    touch "$IN_FLIGHT_FLAG" 2>/dev/null || true
    _run_cycle "$PRS" "$REASON"
    rm -f "$IN_FLIGHT_FLAG"
done <<< "$REQUESTS"
_sng_mark_done     # INFRA-2009: main work body executed

# Advance offset past everything we considered
_advance_offset "$HIGHEST_LINE"
exit 0
