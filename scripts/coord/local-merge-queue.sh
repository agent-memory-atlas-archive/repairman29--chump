#!/usr/bin/env bash
# local-merge-queue.sh — INFRA-2252 (the previously-mythical INFRA-1321)
#
# Phase 3 of the offline-first roadmap (docs/design/OFFLINE_FIRST.md §2).
# When CHUMP_GITHUB_MODE=offline, bot-merge.sh routes gap-ship requests here
# instead of `gh pr merge --auto`. No GitHub calls are made by this script.
#
# Merge requests are persisted as a PersistentMission-shaped JSON envelope
# (matching crates/chump-coord/src/mission/persistence.rs field names) under
# the INFRA-2247 file-backed mission store location (~/.chump/missions/), so
# a pending merge survives a node restart even mid-queue.
#
# Serialization across worker machines on the local mesh (Pi mesh scenario)
# uses NATS KV atomic create-if-absent as a CAS lock; when NATS is
# unreachable (airplane scenario) it falls back to a flock(1) file lock
# under .chump-locks/local-merge-queue.lock.
#
# Usage:
#   local-merge-queue.sh enqueue <GAP-ID> <BRANCH> [--worker NAME]
#   local-merge-queue.sh process [--dry-run]
#   local-merge-queue.sh status
#
# Exit codes:
#   0  success (enqueue: request persisted; process: all pending drained or
#      none pending; status: always 0)
#   1  unexpected error
#   2  bad usage
set -euo pipefail

# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"
# shellcheck source=lib/ambient-write.sh
source "$(dirname "$0")/lib/ambient-write.sh"

AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"
MISSIONS_DIR="${CHUMP_MISSIONS_DIR:-$HOME/.chump/missions}"
LMQ_LOCK_FILE="$LOCK_DIR/local-merge-queue.lock"
LMQ_NATS_BUCKET="${CHUMP_LMQ_NATS_BUCKET:-chump-merge-queue}"
LMQ_NATS_KEY="lock"
LMQ_LOCK_TIMEOUT_S="${CHUMP_LMQ_LOCK_TIMEOUT_S:-60}"

mkdir -p "$MISSIONS_DIR" "$LOCK_DIR"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# scanner-anchor: "kind":"local_merge_queued"
# scanner-anchor: "kind":"local_merge_landed"
# scanner-anchor: "kind":"local_merge_blocked"
_emit() {
    # _emit <kind> <extra-json-fields-without-braces>
    local kind="$1" extra="${2:-}"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$(_ts)\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$(_ts)\",\"kind\":\"$kind\"}"
    fi
    _ambient_write "$AMBIENT_LOG" "$line"
}

_json_get() {
    # _json_get <file> <python-expr-on-loaded-dict-d>
    python3 - "$1" "$2" <<'PYEOF'
import sys, json
path, expr = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
print(eval(expr))
PYEOF
}

_nats_available() {
    [[ -n "${CHUMP_NATS_URL:-}" ]] && command -v nats >/dev/null 2>&1 \
        && nats --server "$CHUMP_NATS_URL" kv ls >/dev/null 2>&1
}

# Acquire the merge-queue lock. Prints "nats" or "flock" (the mode used) to
# stdout on success. Caller must call _release_merge_lock with the same mode
# when done. Returns 1 if the lock could not be acquired within the budget.
_acquire_merge_lock() {
    local deadline=$((SECONDS + LMQ_LOCK_TIMEOUT_S))
    if _nats_available; then
        while (( SECONDS < deadline )); do
            if nats --server "$CHUMP_NATS_URL" kv create "$LMQ_NATS_BUCKET" "$LMQ_NATS_KEY" \
                --value "$$@$(hostname)" >/dev/null 2>&1; then
                echo "nats"
                return 0
            fi
            sleep 1
        done
        return 1
    fi
    # Fallback: flock. Use a fixed fd (9) opened against LMQ_LOCK_FILE; the
    # fd is inherited by the caller's shell so it stays held until released.
    exec 9>"$LMQ_LOCK_FILE"
    if flock -w "$LMQ_LOCK_TIMEOUT_S" 9; then
        echo "flock"
        return 0
    fi
    exec 9>&-
    return 1
}

_release_merge_lock() {
    local mode="$1"
    if [[ "$mode" == "nats" ]]; then
        nats --server "$CHUMP_NATS_URL" kv del "$LMQ_NATS_BUCKET" "$LMQ_NATS_KEY" --force >/dev/null 2>&1 || true
    else
        exec 9>&- 2>/dev/null || true
    fi
}

# ── Mission-store envelope (PersistentMission<MergeRequest>-shaped) ─────────
#
# Field names mirror crates/chump-coord/src/mission/persistence.rs so a
# future Rust reader can load these files directly via FileBackedMissionStore.
# The MergeRequest itself lives in objectives[0].target (branch name) plus
# objectives[0].id (gap id) and objectives[0].description.

_mission_file_for() {
    # Deterministic path so `process` can re-derive it from a listing.
    printf '%s/local-merge-%s.json' "$MISSIONS_DIR" "$1"
}

_enqueue() {
    local gap_id="$1" branch="$2" worker="${3:-unknown}"
    local seq
    seq="$(date -u +%s%N)"
    local mission_id="local-merge-${seq}-${gap_id}"
    local file="$MISSIONS_DIR/${mission_id}.json"
    local ts; ts="$(_ts)"

    cat > "$file" <<JSONEOF
{
  "mission": {
    "id": "$mission_id",
    "name": "local-merge:$gap_id",
    "objectives": [
      {
        "id": "$gap_id",
        "description": "merge $branch into local main",
        "resource_cost": 0,
        "duration_secs": 0,
        "target": "$branch",
        "sequence": 0
      }
    ],
    "fallback_behavior": "safe_shutdown",
    "timestamp_issued": "$ts",
    "ttl_seconds": 0,
    "version": 1
  },
  "checkpoints": [
    {
      "mission_id": "$mission_id",
      "objective_id": "$gap_id",
      "state": "pending",
      "ts": "$ts"
    }
  ],
  "worker": "$worker"
}
JSONEOF

    _emit "local_merge_queued" "\"gap\":\"$gap_id\",\"branch\":\"$branch\",\"mission_id\":\"$mission_id\""
    echo "$mission_id"
}

_checkpoint() {
    # _checkpoint <file> <gap_id> <state>
    local file="$1" gap_id="$2" state="$3" ts; ts="$(_ts)"
    python3 - "$file" "$gap_id" "$state" "$ts" <<'PYEOF'
import sys, json
path, gap_id, state, ts = sys.argv[1:5]
with open(path) as f:
    d = json.load(f)
d["checkpoints"].append({
    "mission_id": d["mission"]["id"],
    "objective_id": gap_id,
    "state": state,
    "ts": ts,
})
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
}

_pending_missions() {
    # FIFO order — filenames are epoch-nanosecond-prefixed, so lexical sort
    # is chronological.
    find "$MISSIONS_DIR" -maxdepth 1 -name 'local-merge-*.json' 2>/dev/null | sort
}

_is_pending() {
    local file="$1"
    local last_state
    last_state="$(_json_get "$file" "d['checkpoints'][-1]['state']" 2>/dev/null || echo "")"
    [[ "$last_state" == "pending" || "$last_state" == "in_progress" ]]
}

_process_one() {
    local file="$1" dry_run="$2"
    local gap_id branch
    gap_id="$(_json_get "$file" "d['mission']['objectives'][0]['id']")"
    branch="$(_json_get "$file" "d['mission']['objectives'][0]['target']")"

    local lock_mode
    if ! lock_mode="$(_acquire_merge_lock)"; then
        _emit "local_merge_blocked" "\"gap\":\"$gap_id\",\"reason\":\"lock_timeout\""
        return 1
    fi

    _checkpoint "$file" "$gap_id" "in_progress"

    local failed=0 reason=""
    if [[ "$dry_run" == "1" ]]; then
        echo "[local-merge-queue] (dry-run) would merge $branch for $gap_id"
    else
        if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
            failed=1; reason="branch_missing"
        fi
        if [[ $failed -eq 0 ]]; then
            # Only fetch if we are not in offline mode (i.e., we are allowed to make network calls)
            if [[ "${CHUMP_GITHUB_MODE:-}" != "offline" ]]; then
                git fetch origin main >/dev/null 2>&1 || true
            fi
            git checkout main >/dev/null 2>&1 || { failed=1; reason="checkout_main_failed"; }
        fi
        if [[ $failed -eq 0 ]] && ! git merge --squash "$branch" >/dev/null 2>&1; then
            git merge --abort >/dev/null 2>&1 || true
            failed=1; reason="squash_conflict"
        fi
        if [[ $failed -eq 0 ]]; then
            local subject
            subject="$(git log "$branch" -1 --format='%s' 2>/dev/null || echo "$gap_id")"
            if ! git commit -m "${subject} [local-merge]" >/dev/null 2>&1; then
                failed=1; reason="commit_failed"
            fi
        fi
    fi

    if [[ $failed -eq 1 ]]; then
        _checkpoint "$file" "$gap_id" "failed"
        _emit "local_merge_blocked" "\"gap\":\"$gap_id\",\"reason\":\"$reason\""
        _release_merge_lock "$lock_mode"
        return 1
    fi

    local sha="dry-run"
    if [[ "$dry_run" != "1" ]]; then
        sha="$(git rev-parse HEAD)"
        command -v chump >/dev/null 2>&1 && chump gap set "$gap_id" --status done \
            --add-note "local-merge sha=$sha branch=$branch (INFRA-2252 offline queue)" >/dev/null 2>&1 || true
    fi

    _checkpoint "$file" "$gap_id" "completed"
    _emit "local_merge_landed" "\"gap\":\"$gap_id\",\"sha\":\"$sha\""
    _release_merge_lock "$lock_mode"

    # Archive so re-runs of `process` don't re-merge an already-landed request.
    mkdir -p "$MISSIONS_DIR/archive"
    mv "$file" "$MISSIONS_DIR/archive/$(basename "$file")" 2>/dev/null || true
    return 0
}

_process_all() {
    local dry_run="0"
    [[ "${1:-}" == "--dry-run" ]] && dry_run="1"

    local any=0 rc=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        _is_pending "$f" || continue
        any=1
        _process_one "$f" "$dry_run" || rc=1
    done < <(_pending_missions)

    if [[ "$any" == "0" ]]; then
        echo "[local-merge-queue] no pending merge requests."
    fi
    return $rc
}

_status() {
    local n; n="$(_pending_missions | wc -l | tr -d ' ')"
    echo "[local-merge-queue] pending missions: $n"
    _pending_missions
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        enqueue)
            [[ $# -ge 3 ]] || { echo "usage: $0 enqueue <GAP-ID> <BRANCH> [--worker NAME]" >&2; exit 2; }
            local worker="unknown"
            [[ "${4:-}" == "--worker" ]] && worker="${5:-unknown}"
            _enqueue "$2" "$3" "$worker"
            ;;
        process)
            shift || true
            _process_all "${1:-}"
            ;;
        status)
            _status
            ;;
        *)
            echo "usage: $0 {enqueue|process|status} ..." >&2
            exit 2
            ;;
    esac
}

main "$@"
