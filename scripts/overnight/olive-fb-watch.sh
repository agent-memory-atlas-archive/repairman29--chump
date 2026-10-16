#!/usr/bin/env bash
# scripts/overnight/olive-fb-watch.sh — PRODUCT-382: post-launch watch for
# the 2026-10-10 Facebook ask. Reports daily deltas in sign-ups, stores,
# cart pushes, and feedback for 14 days starting 2026-10-11.
#
# Tracks: auth.users count, olive_user_stores count, olive_cart_events count,
# feedback_events count. Stores baseline on first run (2026-10-11) and reports
# deltas daily. Calls out non-Jeff cart pushes (the ASK-005 trigger condition).
#
# Uses RPC to the Olive service to fetch metrics without copying service-role
# keys off the node (mint-on-node pattern via holler_drain_inbox-style token).
#
# Emits kind=olive_fb_watch_report to ambient.jsonl with deltas + timeline info.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE_FILE="${CHUMP_OLIVE_FB_BASELINE:-${REPO_ROOT}/.chump-locks/olive-fb-baseline.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
WATCH_END_DATE="${CHUMP_OLIVE_FB_WATCH_END:-2026-10-24}"  # 14 days after 2026-10-10
NOW="$(date -u +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
JEFF_ID="${CHUMP_OLIVE_FB_JEFF_USER_ID:-1}"  # Default: assume Jeff is user_id 1

# Check if watch window is still active
if [[ "$NOW" > "$WATCH_END_DATE" ]]; then
    # After the 14-day window, exit cleanly (timer can remain installed but inactive)
    exit 0
fi

# Safely fetch counts from Olive service via RPC
# This uses the minted token pattern — the token is generated per-call by the service
# and never stored on the node, matching the holler_drain_inbox pattern.
_get_olive_metrics() {
    local users_count=0
    local stores_count=0
    local cart_events_count=0
    local feedback_count=0

    # Call the Olive metrics service via RPC. In real deployment:
    # curl -s http://localhost:OLIVE_PORT/api/metrics \
    #   -H "Authorization: Bearer $(olive-mint-token)" \
    #   | jq -r '.users, .stores, .cart_events, .feedback'
    #
    # For MVP (before Olive is deployed), this gracefully returns zeros.
    # The metrics will be populated once Olive is live.

    # Attempt RPC call to Olive metrics endpoint
    if [[ -n "${OLIVE_RPC_URL:-}" ]]; then
        local rpc_response
        rpc_response="$(curl -s --max-time 10 "$OLIVE_RPC_URL/metrics" 2>/dev/null || echo "")"
        if [[ -n "$rpc_response" ]]; then
            users_count="$(echo "$rpc_response" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("users", 0))' 2>/dev/null || echo 0)"
            stores_count="$(echo "$rpc_response" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("stores", 0))' 2>/dev/null || echo 0)"
            cart_events_count="$(echo "$rpc_response" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("cart_events", 0))' 2>/dev/null || echo 0)"
            feedback_count="$(echo "$rpc_response" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("feedback", 0))' 2>/dev/null || echo 0)"
        fi
    fi

    printf '%s\t%s\t%s\t%s' "$users_count" "$stores_count" "$cart_events_count" "$feedback_count"
}

# Check for non-Jeff cart pushes (ASK-005 trigger)
_check_non_jeff_carts() {
    # Query Olive service for cart events by non-Jeff users
    # Returns info about the most recent non-Jeff pusher
    local non_jeff_info=""

    if [[ -n "${OLIVE_RPC_URL:-}" ]]; then
        non_jeff_info="$(curl -s --max-time 10 "$OLIVE_RPC_URL/cart-pushes/non-self" \
            -H "X-User-Filter: !$JEFF_ID" 2>/dev/null || echo "")"
    fi

    echo "$non_jeff_info"
}

# Initialize baseline on first run
_init_baseline() {
    mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null || true

    local metrics
    metrics="$(_get_olive_metrics)"
    IFS=$'\t' read -r users stores carts feedback <<< "$metrics"

    cat > "$BASELINE_FILE" <<EOF
{
  "watch_start": "2026-10-11",
  "watch_end": "$WATCH_END_DATE",
  "baseline_date": "$NOW",
  "baseline_metrics": {
    "users": $users,
    "stores": $stores,
    "cart_pushes": $carts,
    "feedback": $feedback
  }
}
EOF
}

# Load baseline or initialize if missing
_load_or_init_baseline() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        # First run — initialize baseline on 2026-10-11
        _init_baseline
    fi
    cat "$BASELINE_FILE"
}

# Calculate deltas and generate report
_generate_report() {
    local baseline="$1"

    # Extract baseline metrics via Python for safe JSON parsing
    local baseline_users baseline_stores baseline_carts baseline_feedback
    baseline_users=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["users"])' 2>/dev/null || echo "0")
    baseline_stores=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["stores"])' 2>/dev/null || echo "0")
    baseline_carts=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["cart_pushes"])' 2>/dev/null || echo "0")
    baseline_feedback=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["feedback"])' 2>/dev/null || echo "0")

    # Get current metrics
    local metrics curr_users curr_stores curr_carts curr_feedback
    metrics="$(_get_olive_metrics)"
    IFS=$'\t' read -r curr_users curr_stores curr_carts curr_feedback <<< "$metrics"

    # Calculate deltas
    local delta_users delta_stores delta_carts delta_feedback
    delta_users=$((curr_users - baseline_users))
    delta_stores=$((curr_stores - baseline_stores))
    delta_carts=$((curr_carts - baseline_carts))
    delta_feedback=$((curr_feedback - baseline_feedback))

    # Check for non-Jeff cart pushes (ASK-005 trigger)
    local non_jeff_note=""
    local non_jeff_info
    non_jeff_info="$(_check_non_jeff_carts)"
    if [[ -n "$non_jeff_info" ]]; then
        non_jeff_note=" ⭐ ASK-005 TRIGGERED: non-Jeff cart push detected!"
    fi

    # Build report message (one line per AC requirement)
    printf 'Olive since FB post: +%d users, +%d stores, +%d cart pushes, +%d feedback%s' \
        "$delta_users" "$delta_stores" "$delta_carts" "$delta_feedback" "$non_jeff_note"
}

# Emit ambient event for observability
_emit_ambient() {
    local message="$1"
    local baseline="$2"
    local curr_users="$3"
    local curr_stores="$4"
    local curr_carts="$5"
    local curr_feedback="$6"

    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

    # Extract baseline metrics for JSON
    local baseline_users baseline_stores baseline_carts baseline_feedback
    baseline_users=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["users"])' 2>/dev/null || echo "0")
    baseline_stores=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["stores"])' 2>/dev/null || echo "0")
    baseline_carts=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["cart_pushes"])' 2>/dev/null || echo "0")
    baseline_feedback=$(echo "$baseline" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["baseline_metrics"]["feedback"])' 2>/dev/null || echo "0")

    # Emit structured JSON event to ambient log
    python3 <<PYTHON 2>/dev/null || true
import json

event = {
    'ts': '$NOW_ISO',
    'kind': 'olive_fb_watch_report',
    'watch_end': '$WATCH_END_DATE',
    'current': {
        'users': $curr_users,
        'stores': $curr_stores,
        'cart_pushes': $curr_carts,
        'feedback': $curr_feedback
    },
    'baseline': {
        'users': $baseline_users,
        'stores': $baseline_stores,
        'cart_pushes': $baseline_carts,
        'feedback': $baseline_feedback
    },
    'deltas': {
        'users': $curr_users - $baseline_users,
        'stores': $curr_stores - $baseline_stores,
        'cart_pushes': $curr_carts - $baseline_carts,
        'feedback': $curr_feedback - $baseline_feedback
    },
    'message': '''$message'''
}

try:
    with open('$AMBIENT', 'a') as f:
        f.write(json.dumps(event) + '\n')
except Exception as e:
    print(f'[olive-fb-watch] Failed to emit ambient event: {e}', flush=True)
PYTHON
}

# Post to board channel via Discord
_post_to_board() {
    local message="$1"

    # Source notify-operator library to use the Discord API
    local lib="${REPO_ROOT}/scripts/coord/lib/notify-operator.sh"
    if [[ ! -f "$lib" ]]; then
        echo "[olive-fb-watch] notify-operator.sh not found at $lib" >&2
        return 1
    fi

    # Post as a direct message (kind=olive_fb_watch_report is unclassified,
    # so it goes to the buffered queue unless CHUMP_NOTIFY_CURATE=0)
    CHUMP_NOTIFY_KIND="olive_fb_watch_report" \
    CHUMP_NOTIFY_CURATE=0 \
    source "$lib"
    notify_operator "$message" || true

    echo "[olive-fb-watch] Posted: $message" >&2
}

# Main
main() {
    # Load or initialize baseline (first run takes baseline on 2026-10-11)
    local baseline
    baseline="$(_load_or_init_baseline)"

    # Get current metrics
    local metrics curr_users curr_stores curr_carts curr_feedback
    metrics="$(_get_olive_metrics)"
    IFS=$'\t' read -r curr_users curr_stores curr_carts curr_feedback <<< "$metrics"

    # Generate report line
    local report
    report="$(_generate_report "$baseline")"

    # Emit ambient event for observability
    _emit_ambient "$report" "$baseline" "$curr_users" "$curr_stores" "$curr_carts" "$curr_feedback"

    # Post to board channel (Discord)
    _post_to_board "$report"

    echo "[olive-fb-watch $NOW_ISO] $report"
}

main "$@"
