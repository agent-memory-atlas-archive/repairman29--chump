#!/usr/bin/env bash
# Post-launch monitor for Olive (PRODUCT-382): daily signup/store/cart/feedback report.
#
# PRODUCT-382: For 14 days after the 2026-10-10 Facebook launch, report new
# sign-ups, stores set, cart pushes and feedback rows daily to the board channel.
#
# Baseline taken on first run and stored; daily runs compute and post deltas.
# Calls out non-Jeff cart pushes explicitly (the ASK-005 trigger).
#
# Token pattern: Uses holler_drain_inbox-style RPC token (CHUMP_OLIVE_RPC_TOKEN),
# never copies service-role key off the node.
#
# Env vars (all optional):
#   CHUMP_OLIVE_RPC_URL          Supabase PostgREST endpoint (default $SUPABASE_URL/rest/v1)
#   CHUMP_OLIVE_RPC_TOKEN        Anon or service-role token for RPC calls (default $SUPABASE_ANON_KEY)
#   CHUMP_OLIVE_BASELINE_DIR     Where to store baseline counts (default $HOME/.chump/olive-launch-baseline)
#   CHUMP_OLIVE_LAUNCH_DATE      FB launch date YYYY-MM-DD (default 2026-10-10)
#   CHUMP_DISCORD_ENABLED        Set to 0 to disable Discord notify (default 1)
#   CHUMP_AMBIENT_LOG            ambient.jsonl path for observability (default .chump-locks/ambient.jsonl)
#   CHUMP_OLIVE_DRY_RUN          Set to 1 to log without posting (default 0)

set -euo pipefail

_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd
}

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now() { date -u +%s; }

_emit() {  # kind, extra_json_fragment
    local log; log="${CHUMP_AMBIENT_LOG:-$(_repo_root)/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    if [[ -n "${2:-}" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' "$(_ts)" "$1" "$2" >> "$log" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"%s"}\n' "$(_ts)" "$1" >> "$log" 2>/dev/null || true
    fi
}

_notify() {
    local msg="$1"
    [[ "${CHUMP_DISCORD_ENABLED:-1}" == "0" ]] && return 0
    local bin; bin="$(_repo_root)/target/release/chump"
    [[ -x "$bin" ]] || bin="$(_repo_root)/target/debug/chump"
    [[ -x "$bin" ]] || { echo "[olive-monitor] chump binary not found" >&2; return 1; }
    echo "$msg" | "$bin" --notify 2>/dev/null || {
        # scanner-anchor: "kind":"olive_monitor_notify_failed"
        _emit "olive_monitor_notify_failed" "\"error\":\"chump --notify failed\""
        return 0
    }
}

_get_rpc_url() {
    if [[ -n "${CHUMP_OLIVE_RPC_URL:-}" ]]; then
        echo "$CHUMP_OLIVE_RPC_URL"
        return 0
    fi
    if [[ -n "${SUPABASE_URL:-}" ]]; then
        echo "${SUPABASE_URL}/rest/v1"
        return 0
    fi
    echo ""
}

_get_rpc_token() {
    if [[ -n "${CHUMP_OLIVE_RPC_TOKEN:-}" ]]; then
        echo "$CHUMP_OLIVE_RPC_TOKEN"
        return 0
    fi
    if [[ -n "${SUPABASE_ANON_KEY:-}" ]]; then
        echo "$SUPABASE_ANON_KEY"
        return 0
    fi
    echo ""
}

# Query table for row count. Returns integer or empty on error.
_query_count() {  # table_name
    local table="$1" url token
    url="$(_get_rpc_url)"
    token="$(_get_rpc_token)"
    [[ -z "$url" || -z "$token" ]] && { echo ""; return 1; }

    curl -s -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "${url}/${table}?select=count()" \
        2>/dev/null | grep -o '"count":"[0-9]*' | cut -d'"' -f4 || echo ""
}

# Build baseline file path for a given table
_baseline_path() {  # table_name
    local base_dir
    base_dir="${CHUMP_OLIVE_BASELINE_DIR:-${HOME}/.chump/olive-launch-baseline}"
    echo "${base_dir}/$1.json"
}

# Load baseline count for a table (returns 0 if none, stored count otherwise)
_load_baseline() {  # table_name
    local path; path="$(_baseline_path "$1")"
    [[ -f "$path" ]] && { jq -r '.count // 0' "$path" 2>/dev/null || echo "0"; } || echo "0"
}

# Save baseline count for a table
_save_baseline() {  # table_name count
    local path; path="$(_baseline_path "$1")"
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    printf '{"table":"%s","count":%s,"ts":"%s"}\n' "$1" "$2" "$(_ts)" > "$path" 2>/dev/null || true
}

# Extract non-Jeff pushers from olive_cart_events
# Returns comma-separated list of user identifiers who pushed (not Jeff)
_get_non_jeff_pushers() {
    local url token
    url="$(_get_rpc_url)"
    token="$(_get_rpc_token)"
    [[ -z "$url" || -z "$token" ]] && { echo ""; return 0; }

    # Query recent cart events, exclude "jeff" user, get distinct user identifiers
    # This assumes olive_cart_events has an `user_id` or `user_email` column
    curl -s -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        "${url}/olive_cart_events?select=user_id&order=id.desc&limit=1000" \
        2>/dev/null | jq -r '.[] | select(.user_id != "jeff") | .user_id' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || echo ""
}

# Days remaining in the 14-day watch window
_days_remaining() {
    local launch launch_epoch now_epoch days_passed days_left
    launch="${CHUMP_OLIVE_LAUNCH_DATE:-2026-10-10}"
    launch_epoch=$(date -d "$launch" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$launch" +%s 2>/dev/null || echo 0)
    now_epoch=$(_now)
    if (( launch_epoch == 0 )); then
        echo "unknown"
        return 1
    fi
    days_passed=$(( (now_epoch - launch_epoch) / 86400 ))
    days_left=$(( 14 - days_passed ))
    [[ $days_left -lt 0 ]] && days_left=0
    echo "$days_left"
}

# Main run: query current counts, compute deltas, report, update baseline if needed
main() {
    local days_left
    days_left="$(_days_remaining)"
    if [[ "$days_left" == "unknown" ]] || [[ "$days_left" -gt 14 ]]; then
        # scanner-anchor: "kind":"olive_monitor_launch_not_started"
        _emit "olive_monitor_launch_not_started" "\"msg\":\"Launch date not yet or parsing failed\""
        echo "[olive-monitor] Launch window not active or could not parse launch date. Exiting." >&2
        return 0
    fi
    if (( days_left == 0 )); then
        # scanner-anchor: "kind":"olive_monitor_window_closed"
        _emit "olive_monitor_window_closed" "\"day\":14"
        echo "[olive-monitor] 14-day watch window closed. Exiting." >&2
        return 0
    fi

    # Query current counts
    local users_now stores_now pushes_now feedback_now
    users_now="$(_query_count "auth.users")" || users_now=""
    stores_now="$(_query_count "olive_user_stores")" || stores_now=""
    pushes_now="$(_query_count "olive_cart_events")" || pushes_now=""
    feedback_now="$(_query_count "feedback_events")" || feedback_now=""

    # Load or initialize baselines
    local users_base stores_base pushes_base feedback_base
    users_base="$(_load_baseline "auth.users")"
    stores_base="$(_load_baseline "olive_user_stores")"
    pushes_base="$(_load_baseline "olive_cart_events")"
    feedback_base="$(_load_baseline "feedback_events")"

    # If any baseline is "0" and current is non-empty, this is the first run — save baselines
    if [[ "$users_base" == "0" ]] && [[ -n "$users_now" ]]; then
        _save_baseline "auth.users" "$users_now"
        _save_baseline "olive_user_stores" "$stores_now"
        _save_baseline "olive_cart_events" "$pushes_now"
        _save_baseline "feedback_events" "$feedback_now"
        users_base="$users_now"
        stores_base="$stores_now"
        pushes_base="$pushes_now"
        feedback_base="$feedback_now"
        # scanner-anchor: "kind":"olive_monitor_baseline_initialized"
        _emit "olive_monitor_baseline_initialized" \
            "\"users\":${users_now},\"stores\":${stores_now},\"pushes\":${pushes_now},\"feedback\":${feedback_now}"
    fi

    # Compute deltas (handle empty counts as 0)
    local users_delta stores_delta pushes_delta feedback_delta
    users_delta=$(( ${users_now:-0} - ${users_base:-0} ))
    stores_delta=$(( ${stores_now:-0} - ${stores_base:-0} ))
    pushes_delta=$(( ${pushes_now:-0} - ${pushes_base:-0} ))
    feedback_delta=$(( ${feedback_now:-0} - ${feedback_base:-0} ))

    # Build report message
    local report non_jeff_pushers extra_note
    report="Olive since FB post: +${users_delta} users, +${stores_delta} stores, +${pushes_delta} cart pushes, +${feedback_delta} feedback"
    non_jeff_pushers="$(_get_non_jeff_pushers)" || non_jeff_pushers=""

    if [[ -n "$non_jeff_pushers" && "$non_jeff_pushers" != "" ]]; then
        extra_note=" 🎯 **First non-Jeff cart push detected:** ${non_jeff_pushers} — ASK-005 trigger!"
        report="${report}${extra_note}"
    fi

    # Report (dry-run or actual)
    if [[ "${CHUMP_OLIVE_DRY_RUN:-0}" == "1" ]]; then
        echo "[olive-monitor DRY_RUN] Would send to board: ${report}"
        # scanner-anchor: "kind":"olive_monitor_report_dryrun"
        _emit "olive_monitor_report_dryrun" "\"msg\":\"${report}\",\"days_left\":${days_left}"
    else
        _notify "$report" || true
        # scanner-anchor: "kind":"olive_monitor_report_posted"
        _emit "olive_monitor_report_posted" \
            "\"users_delta\":${users_delta},\"stores_delta\":${stores_delta},\"pushes_delta\":${pushes_delta},\"feedback_delta\":${feedback_delta},\"non_jeff_pushers\":\"${non_jeff_pushers}\",\"days_left\":${days_left}"
    fi

    echo "[olive-monitor] ${report}"
}

main "$@"
