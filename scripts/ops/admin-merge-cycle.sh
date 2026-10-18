#!/usr/bin/env bash
# scripts/ops/admin-merge-cycle.sh — INFRA-2041 + RESILIENT-031
#
# Wraps the admin-merge cycle: drop required-status-checks rule → merge PR
# with --admin → restore ruleset. Reads checked-in snapshot JSON so the
# /tmp/ruleset-*.json GC-silent-fail class is eliminated.
#
# RESILIENT-031 ADDS: mandatory noise-class discipline.
# You must declare WHICH noise pattern justifies this bypass with --noise-class,
# and the actual failing checks on the PR must match that class. If they don't,
# the cycle REFUSES. Use --force-admin --reason for true emergencies (emits audit event).
#
# Usage:
#   scripts/ops/admin-merge-cycle.sh --pr <N> --noise-class <id> [options]
#   scripts/ops/admin-merge-cycle.sh --pr <N> --force-admin --reason "<text>" [options]
#   scripts/ops/admin-merge-cycle.sh --list-classes
#
# Options:
#   --pr <N>                PR number to admin-merge (required for merge)
#   --noise-class <id>      Declare which known noise pattern justifies the bypass.
#                           Looks up <id> in NOISE_CLASSES_FILE, fetches actual
#                           failing check names via gh pr checks, refuses if mismatch.
#   --force-admin           Emergency bypass: skip noise-class check. REQUIRES --reason.
#                           Emits kind=admin_merge_forced to ambient.jsonl for audit.
#   --reason "<text>"       Required with --force-admin. Explain the emergency.
#   --list-classes          Print active noise classes and exit.
#   --ruleset-id <ID>       Ruleset ID to cycle (default: 15133729)
#   --propagation-wait      Seconds to wait after drop for propagation (default: 8)
#   --dry-run               Print plan without executing
#   --repo <owner/repo>     Override repo (default: auto from gh repo view)
#
# Environment:
#   CHUMP_ADMIN_MERGE_DRY_RUN=1     same as --dry-run
#   CHUMP_ADMIN_MERGE_REPO          same as --repo
#   CHUMP_AMBIENT_LOG               override ambient.jsonl path
#   CHUMP_NOISE_CLASSES_FILE        override path to known-noise-classes.yaml
#   CHUMP_ADMIN_MERGE_TEST_GH       mock gh binary for testing
#   CHUMP_ADMIN_MERGE_TEST_GAP_STATUS <id>:<status>  mock gap status for testing
#   CHUMP_ADMIN_MERGE_BURST_THRESHOLD N   burst trip count (default 3)
#   CHUMP_ADMIN_MERGE_BURST_WINDOW_S  N   burst window in seconds (default 3600)
#   CHUMP_ADMIN_MERGE_FORCE=1         bypass burst circuit-breaker (emits burst_overridden)
#   OPERATOR_SESSION_ID               optional: tag cycle_run events with session id
#
# Exit codes:
#   0  PR merged and ruleset restored (or --list-classes printed)
#   1  usage error, noise-class mismatch, or non-critical failure
#   2  CRITICAL: PR merged but ruleset restore failed (requires operator action)
#   3  circuit-breaker tripped: burst threshold exceeded; use --force-admin or CHUMP_ADMIN_MERGE_FORCE=1 to override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/ruleset-snapshots"
DROP_JSON="$SNAPSHOT_DIR/drop.json"
RESTORE_JSON="$SNAPSHOT_DIR/restore.json"
NOISE_CLASSES_FILE="${CHUMP_NOISE_CLASSES_FILE:-$SCRIPT_DIR/known-noise-classes.yaml}"
GH_BIN="${CHUMP_ADMIN_MERGE_TEST_GH:-gh}"
# CREDIBLE-1524: admin-merge consensus gate (refuses --admin without a PASSED
# AdminMergeProposal consensus_result for the PR).
# shellcheck source=scripts/coord/lib/admin-merge-consensus-gate.sh
source "$SCRIPT_DIR/../coord/lib/admin-merge-consensus-gate.sh"

# Defaults
PR_NUM=""
RULESET_ID="15133729"
PROPAGATION_WAIT=8
DRY_RUN="${CHUMP_ADMIN_MERGE_DRY_RUN:-0}"
REPO="${CHUMP_ADMIN_MERGE_REPO:-}"
NOISE_CLASS=""
FORCE_ADMIN=0
FORCE_REASON=""
LIST_CLASSES=0

# Burst circuit-breaker (INFRA-2071)
BURST_THRESHOLD="${CHUMP_ADMIN_MERGE_BURST_THRESHOLD:-3}"
BURST_WINDOW_S="${CHUMP_ADMIN_MERGE_BURST_WINDOW_S:-3600}"
ADMIN_MERGE_FORCE="${CHUMP_ADMIN_MERGE_FORCE:-0}"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            PR_NUM="$2"; shift 2 ;;
        --noise-class)
            NOISE_CLASS="$2"; shift 2 ;;
        --force-admin)
            FORCE_ADMIN=1; shift ;;
        --reason)
            FORCE_REASON="$2"; shift 2 ;;
        --list-classes)
            LIST_CLASSES=1; shift ;;
        --ruleset-id)
            RULESET_ID="$2"; shift 2 ;;
        --propagation-wait)
            PROPAGATION_WAIT="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --repo)
            REPO="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -50 | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "[admin-merge-cycle] unknown argument: $1" >&2
            exit 1 ;;
    esac
done

# Ambient log
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    # scanner-anchor: "kind":"admin_merge_forced"
    printf '{"ts":"%s","kind":"%s","source":"admin_merge_cycle"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

_run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] $*" >&2
    else
        "$@"
    fi
}

# ── Burst circuit-breaker helpers (INFRA-2071) ────────────────────────────────

# Count admin_merge_cycle_run events in the ambient log within BURST_WINDOW_S
_count_recent_runs() {
    local log="$1"
    local window_s="$2"
    if [[ ! -f "$log" ]]; then
        echo "0"
        return
    fi
    local now_epoch
    now_epoch="$(date -u +%s)"
    local cutoff_epoch=$(( now_epoch - window_s ))
    python3 - "$log" "$cutoff_epoch" <<'PYEOF'
import sys, json
log_path = sys.argv[1]
cutoff   = int(sys.argv[2])
count = 0
with open(log_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("kind") != "admin_merge_cycle_run":
            continue
        ts = ev.get("ts", "")
        # Parse ISO-8601 ts to epoch
        try:
            from datetime import datetime, timezone
            dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            ev_epoch = int(dt.timestamp())
        except Exception:
            continue
        if ev_epoch >= cutoff:
            count += 1
print(count)
PYEOF
}

# Emit kind=admin_merge_cycle_run (the counter event)
_emit_cycle_run() {
    local pr="$1"
    local reason="$2"
    local session_id="${OPERATOR_SESSION_ID:-${USER:-unknown}}"
    # scanner-anchor: "kind":"admin_merge_cycle_run"
    _emit "admin_merge_cycle_run" \
        "\"pr\":\"$pr\"" \
        "\"reason\":\"$(printf '%s' "$reason" | sed 's/"/\\"/g')\"" \
        "\"operator_session_id\":\"$session_id\""
}

# Check burst threshold; if tripped, emit admin_merge_burst and return 1
# Returns 0 if safe to proceed, 1 if tripped (caller should exit unless override)
_check_burst() {
    local count
    count="$(_count_recent_runs "$AMBIENT_LOG" "$BURST_WINDOW_S")"
    if [[ "$count" -ge "$BURST_THRESHOLD" ]]; then
        local window_h=$(( BURST_WINDOW_S / 3600 ))
        echo "[admin-merge-cycle] BURST DETECTED: $count admin_merge_cycle_run events in past ${BURST_WINDOW_S}s (threshold=$BURST_THRESHOLD)" >&2
        echo "[admin-merge-cycle] admin-merge burst detected: $count cycles in past ${window_h}h exceeds threshold $BURST_THRESHOLD; pause to triage root cause OR re-run with --force-admin to override" >&2
        if [[ "$DRY_RUN" != "1" ]]; then
            # scanner-anchor: "kind":"admin_merge_burst"
            _emit "admin_merge_burst" \
                "\"count\":$count" \
                "\"window_s\":$BURST_WINDOW_S" \
                "\"threshold\":$BURST_THRESHOLD" \
                "\"operator_action_needed\":true"
        else
            echo "[dry-run] would emit kind=admin_merge_burst (count=$count window_s=$BURST_WINDOW_S threshold=$BURST_THRESHOLD)" >&2
        fi
        return 1
    fi
    return 0
}

# ── --list-classes ─────────────────────────────────────────────────────────────

_list_classes() {
    if [[ ! -f "$NOISE_CLASSES_FILE" ]]; then
        echo "[admin-merge-cycle] no noise classes file at: $NOISE_CLASSES_FILE" >&2
        echo "(no classes registered)" >&2
        return
    fi
    python3 - "$NOISE_CLASSES_FILE" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
classes = data.get('classes', [])
if not classes:
    print("(no classes registered)")
    sys.exit(0)
print(f"Registered noise classes ({len(classes)} total):")
for cls in classes:
    cid     = cls.get('id', '?')
    desc    = cls.get('description', '')
    matches = cls.get('matches', [])
    pattern = cls.get('pattern', '')
    fix_gap = cls.get('upstream_fix_gap') or ''
    expires = cls.get('expires_after_ship', False)
    print(f"\n  id:          {cid}")
    print(f"  description: {desc}")
    print(f"  matches:     {matches}")
    print(f"  pattern:     {pattern}")
    if fix_gap:
        print(f"  upstream_fix_gap:    {fix_gap}")
    if expires:
        print(f"  expires_after_ship:  true")
PYEOF
}

if [[ "$LIST_CLASSES" == "1" ]]; then
    _list_classes
    exit 0
fi

# ── Validate required args ────────────────────────────────────────────────────

if [[ -z "$PR_NUM" ]]; then
    echo "[admin-merge-cycle] ERROR: --pr <N> is required" >&2
    echo "Usage: $0 --pr <N> {--noise-class <id> | --force-admin --reason '<text>'} [options]" >&2
    exit 1
fi

# Must declare either --noise-class OR --force-admin (not both, not neither)
if [[ -n "$NOISE_CLASS" && "$FORCE_ADMIN" == "1" ]]; then
    echo "[admin-merge-cycle] ERROR: --noise-class and --force-admin are mutually exclusive" >&2
    exit 1
fi
if [[ -z "$NOISE_CLASS" && "$FORCE_ADMIN" != "1" ]]; then
    echo "[admin-merge-cycle] REFUSE: you must declare a noise class or use --force-admin." >&2
    echo "" >&2
    echo "  --noise-class <id>             declare which known noise pattern justifies this bypass" >&2
    echo "  --force-admin --reason '<why>' emergency bypass (emits kind=admin_merge_forced audit event)" >&2
    echo "" >&2
    echo "Active classes:" >&2
    _list_classes >&2
    exit 1
fi
if [[ "$FORCE_ADMIN" == "1" && -z "$FORCE_REASON" ]]; then
    echo "[admin-merge-cycle] ERROR: --force-admin requires --reason '<emergency reason>'" >&2
    exit 1
fi

# ── Noise-class validation ────────────────────────────────────────────────────

_validate_noise_class() {
    local class_id="$1"
    local pr="$2"

    if [[ ! -f "$NOISE_CLASSES_FILE" ]]; then
        echo "[admin-merge-cycle] REFUSE: noise classes file not found: $NOISE_CLASSES_FILE" >&2
        echo "  Create it first. See docs/process/CLAUDE_GOTCHAS.md §When to admin-merge." >&2
        return 1
    fi

    # Look up the class
    local class_json
    class_json="$(python3 - "$NOISE_CLASSES_FILE" "$class_id" <<'PYEOF'
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for cls in data.get('classes', []):
    if cls.get('id') == sys.argv[2]:
        print(json.dumps(cls))
        sys.exit(0)
print("NOT_FOUND")
PYEOF
)"

    if [[ "$class_json" == "NOT_FOUND" ]]; then
        echo "[admin-merge-cycle] REFUSE: noise class '$class_id' not registered in $NOISE_CLASSES_FILE" >&2
        echo "  Run --list-classes to see valid options." >&2
        return 1
    fi

    # Auto-expire: if expires_after_ship=true and upstream gap is done, refuse.
    local upstream_fix_gap expires_after_ship
    upstream_fix_gap="$(printf '%s' "$class_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('upstream_fix_gap') or '')")"
    expires_after_ship="$(printf '%s' "$class_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('expires_after_ship', False)).lower())")"

    if [[ "$expires_after_ship" == "true" && -n "$upstream_fix_gap" ]]; then
        local gap_status
        # Support test injection: CHUMP_ADMIN_MERGE_TEST_GAP_STATUS=INFRA-2044:done
        local test_override="${CHUMP_ADMIN_MERGE_TEST_GAP_STATUS:-}"
        if [[ -n "$test_override" ]]; then
            local test_id="${test_override%%:*}"
            local test_st="${test_override##*:}"
            [[ "$test_id" == "$upstream_fix_gap" ]] && gap_status="$test_st" || gap_status="open"
        else
            gap_status="$(chump gap show "$upstream_fix_gap" 2>/dev/null | grep '^\s*status:' | awk '{print $2}' || echo "unknown")"
        fi

        if [[ "$gap_status" == "done" ]]; then
            echo "[admin-merge-cycle] REFUSE: noise class '$class_id' is EXPIRED." >&2
            echo "  Upstream fix gap $upstream_fix_gap is marked done." >&2
            echo "  This noise should no longer occur. If it does, file a regression gap." >&2
            return 1
        fi
    fi

    # Fetch actual failing checks for the PR
    echo "[admin-merge-cycle] fetching failing checks for PR $pr..." >&2
    local failing_checks
    failing_checks="$("$GH_BIN" pr checks "$pr" --repo "${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo repairman29/chump)}" 2>/dev/null \
        | grep -iE 'fail(ure)?|error' \
        | awk '{print $1}' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$' \
        || true)"

    if [[ -z "$failing_checks" ]]; then
        echo "[admin-merge-cycle] REFUSE: no failing checks found for PR $pr." >&2
        echo "  Admin-merge is only appropriate when checks are actually failing." >&2
        echo "  If checks are pending, wait for them to complete first." >&2
        return 1
    fi

    echo "[admin-merge-cycle] failing checks:" >&2
    printf '%s\n' "$failing_checks" | while IFS= read -r check; do
        echo "  - $check" >&2
    done

    # Check each failing check against class.matches[] (substring) and class.pattern (regex)
    local matches_json pattern matched_check
    matches_json="$(printf '%s' "$class_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('matches',[])))")"
    pattern="$(printf '%s' "$class_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pattern',''))")"

    local found_match="false"
    while IFS= read -r check; do
        [[ -z "$check" ]] && continue
        local hit
        hit="$(python3 - "$matches_json" "$check" "$pattern" <<'PYEOF'
import sys, json, re
matches_list = json.loads(sys.argv[1])
check_name   = sys.argv[2]
pattern_str  = sys.argv[3]
for m in matches_list:
    if m.lower() in check_name.lower():
        print("yes")
        sys.exit(0)
if pattern_str:
    try:
        if re.search(pattern_str, check_name):
            print("yes")
            sys.exit(0)
    except re.error:
        pass
print("no")
PYEOF
)"
        if [[ "$hit" == "yes" ]]; then
            found_match="true"
            matched_check="$check"
            break
        fi
    done <<< "$failing_checks"

    if [[ "$found_match" == "false" ]]; then
        local description
        description="$(printf '%s' "$class_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('description',''))")"
        echo "[admin-merge-cycle] REFUSE: failing checks do NOT match noise class '$class_id'." >&2
        echo "  Class:   $description" >&2
        echo "  matches: $matches_json" >&2
        echo "  pattern: $pattern" >&2
        echo "" >&2
        echo "  Options:" >&2
        echo "    1. Use the correct noise class for your actual failure." >&2
        echo "    2. Add a new class to $NOISE_CLASSES_FILE." >&2
        echo "    3. --force-admin --reason '<why>' for true emergencies (audit-logged)." >&2
        return 1
    fi

    echo "[admin-merge-cycle] MATCH: check '$matched_check' matches class '$class_id'. Proceeding." >&2
    return 0
}

# ── Burst circuit-breaker check (INFRA-2071) ─────────────────────────────────
# Must run before merge dispatch. --force-admin AND CHUMP_ADMIN_MERGE_FORCE=1
# both bypass the breaker, but still emit admin_merge_burst_overridden for audit.

if ! _check_burst; then
    # Burst tripped
    if [[ "$FORCE_ADMIN" == "1" || "$ADMIN_MERGE_FORCE" == "1" ]]; then
        echo "[admin-merge-cycle] burst override active (--force-admin or CHUMP_ADMIN_MERGE_FORCE=1); proceeding despite burst." >&2
        if [[ "$DRY_RUN" != "1" ]]; then
            # scanner-anchor: "kind":"admin_merge_burst_overridden"
            _emit "admin_merge_burst_overridden" \
                "\"pr\":\"$PR_NUM\"" \
                "\"count\":$(_count_recent_runs "$AMBIENT_LOG" "$BURST_WINDOW_S")" \
                "\"window_s\":$BURST_WINDOW_S" \
                "\"threshold\":$BURST_THRESHOLD" \
                "\"override_method\":\"$([ "$FORCE_ADMIN" == "1" ] && echo "--force-admin" || echo "CHUMP_ADMIN_MERGE_FORCE")\""
        else
            echo "[dry-run] would emit kind=admin_merge_burst_overridden for PR $PR_NUM" >&2
        fi
    else
        exit 3
    fi
fi

# ── Dispatch noise-class or force-admin ───────────────────────────────────────

if [[ "$FORCE_ADMIN" == "1" ]]; then
    echo "[admin-merge-cycle] FORCE-ADMIN bypass. Reason: $FORCE_REASON" >&2
    if [[ "$DRY_RUN" != "1" ]]; then
        _emit "admin_merge_forced" \
            "\"pr\":\"$PR_NUM\"" \
            "\"reason\":\"$(printf '%s' "$FORCE_REASON" | sed 's/"/\\"/g')\"" \
            "\"operator\":\"${USER:-unknown}\""
        echo "[admin-merge-cycle] Emitted kind=admin_merge_forced to ambient.jsonl (audit trail)." >&2
    else
        echo "[dry-run] would emit kind=admin_merge_forced for PR $PR_NUM" >&2
    fi
else
    # noise-class path — validate before proceeding
    if ! _validate_noise_class "$NOISE_CLASS" "$PR_NUM"; then
        exit 1
    fi
fi

# ── Validate snapshot files exist ────────────────────────────────────────────

if [[ ! -f "$DROP_JSON" ]]; then
    echo "[admin-merge-cycle] ERROR: drop snapshot not found: $DROP_JSON" >&2
    exit 1
fi
if [[ ! -f "$RESTORE_JSON" ]]; then
    echo "[admin-merge-cycle] ERROR: restore snapshot not found: $RESTORE_JSON" >&2
    exit 1
fi

# Resolve repo if not set
if [[ -z "$REPO" ]]; then
    REPO="$("$GH_BIN" repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
    if [[ -z "$REPO" ]]; then
        echo "[admin-merge-cycle] ERROR: could not determine repo; pass --repo <owner/repo>" >&2
        exit 1
    fi
fi

echo "[admin-merge-cycle] repo=$REPO ruleset=$RULESET_ID pr=$PR_NUM propagation_wait=${PROPAGATION_WAIT}s" >&2
[[ "$DRY_RUN" == "1" ]] && echo "[admin-merge-cycle] DRY-RUN mode — no changes will be made" >&2

# Step 1: Drop required_status_checks by loading the drop snapshot
echo "[admin-merge-cycle] step 1/4: dropping required_status_checks rule via $DROP_JSON" >&2
_run "$GH_BIN" api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$DROP_JSON" > /dev/null

# Step 2: Wait for propagation
echo "[admin-merge-cycle] step 2/4: waiting ${PROPAGATION_WAIT}s for ruleset propagation..." >&2
if [[ "$DRY_RUN" != "1" ]]; then
    sleep "$PROPAGATION_WAIT"
fi

# Step 3: Admin-merge the PR
# CREDIBLE-1524: refuse the --admin bypass unless a PASSED AdminMergeProposal
# consensus_result names this PR (enforce mode; shadow logs + proceeds).
if [[ "$DRY_RUN" != "1" ]] && ! admin_merge_consensus_gate "$PR_NUM"; then
    echo "[admin-merge-cycle] step 3/4: admin-merge REFUSED by consensus gate (CREDIBLE-1524) — PR #$PR_NUM" >&2
    echo "[admin-merge-cycle] restoring ruleset before exit..." >&2
    _run "$GH_BIN" api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$RESTORE_JSON" > /dev/null || true
    exit 1
fi
echo "[admin-merge-cycle] step 3/4: merging PR #$PR_NUM with --admin --squash" >&2
MERGE_EXIT=0
_run "$GH_BIN" pr merge "$PR_NUM" --squash --admin || MERGE_EXIT=$?

# Step 4: Restore ruleset regardless of merge outcome
echo "[admin-merge-cycle] step 4/4: restoring ruleset via $RESTORE_JSON" >&2
RESTORE_EXIT=0
_run "$GH_BIN" api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input "$RESTORE_JSON" > /dev/null || RESTORE_EXIT=$?

if [[ "$RESTORE_EXIT" -ne 0 ]]; then
    echo "[admin-merge-cycle] CRITICAL: ruleset restore FAILED (exit $RESTORE_EXIT) — operator action required" >&2
    echo "[admin-merge-cycle] CRITICAL: manually PUT restore snapshot: $RESTORE_JSON" >&2
    echo "[admin-merge-cycle] CRITICAL: command: gh api -X PUT repos/$REPO/rulesets/$RULESET_ID --input $RESTORE_JSON" >&2
    _emit "admin_merge_cycle_restore_failed" \
        "\"pr\":\"$PR_NUM\"" \
        "\"ruleset_id\":\"$RULESET_ID\"" \
        "\"restore_json\":\"$RESTORE_JSON\"" \
        "\"severity\":\"CRITICAL\""
    exit 2
fi

if [[ "$MERGE_EXIT" -ne 0 ]]; then
    echo "[admin-merge-cycle] WARNING: merge of PR #$PR_NUM failed (exit $MERGE_EXIT) — ruleset was restored" >&2
    _emit "admin_merge_cycle_merge_failed" \
        "\"pr\":\"$PR_NUM\"" \
        "\"ruleset_id\":\"$RULESET_ID\"" \
        "\"merge_exit\":\"$MERGE_EXIT\""
    exit 1
fi

echo "[admin-merge-cycle] OK: PR #$PR_NUM merged and ruleset restored" >&2

# Emit cycle_run counter event BEFORE cycle_ok (INFRA-2071: this is what the burst counter counts)
if [[ "$DRY_RUN" != "1" ]]; then
    _REASON_TAG=""
    if [[ "$FORCE_ADMIN" == "1" ]]; then
        _REASON_TAG="force-admin: $(printf '%s' "$FORCE_REASON" | sed 's/"/\\"/g')"
    else
        _REASON_TAG="noise-class: $NOISE_CLASS"
    fi
    _emit_cycle_run "$PR_NUM" "$_REASON_TAG"
else
    echo "[dry-run] would emit kind=admin_merge_cycle_run for PR $PR_NUM" >&2
fi

_emit "admin_merge_cycle_ok" \
    "\"pr\":\"$PR_NUM\"" \
    "\"ruleset_id\":\"$RULESET_ID\""
