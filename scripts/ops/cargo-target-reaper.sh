#!/usr/bin/env bash
# cargo-target-reaper.sh — INFRA-1250 + INFRA-1170 + INFRA-2125 + INFRA-2181
# Reclaim stale cargo build artifacts (60GB+ unbounded growth).
#
# Usage:
#   bash scripts/ops/cargo-target-reaper.sh [--execute] [--fingerprint-age-d N] [--fleet-age-d N]
#   bash scripts/ops/cargo-target-reaper.sh --event-listen [--execute]
#
# By default: dry-run only. Pass --execute to actually delete.
#
# --event-listen (INFRA-2181): tail-poll ambient.jsonl for kind=integration_cycle_shipped
#   at 30s cadence; fire a full reap (--execute if passed) within 60s of each event.
#   Keeps running indefinitely as a daemon. Exits 0 on SIGTERM/SIGINT.
#   Falls through to a one-shot run if the ambient log is unavailable (fail-open).
#
# Reaps:
#   (a) target/debug/.fingerprint/*        mtime > FINGERPRINT_AGE_D days
#   (b) target/debug/deps/lib*.rlib        mtime > FINGERPRINT_AGE_D days
#   (c) ~/.cache/chump-fleet-target/<dir>/ mtime > FLEET_AGE_D days AND
#       no live process has CARGO_TARGET_DIR pointing at <dir>
#   (d) INFRA-1170: /tmp/chump-*/target/   where originating git worktree no
#       longer exists in `git worktree list --porcelain` (orphaned target dirs)
#   (e) INFRA-2125/A: /tmp/chump-coord-linux-build* + /tmp/chump-cross-build-*
#       (Linux cross-build artifacts from scripts/dev/cross-build-linux.sh)
#   (f) INFRA-2125/B: /tmp/chump-*/.cargo-test-target/
#       (hidden cargo target dirs from Sonnet workers using custom CARGO_TARGET_DIR)
#   (g) INFRA-2125/C: /tmp/chump-*/target/ in worktrees with ACTIVE lease but
#       whose PR is open + auto-merge armed + local HEAD matches remote tip
#       (work is safely on origin; rebuild cost is bounded)
#   (h) INFRA-2188: ~/.cache/chump-runner/cargo-target/{debug,release}/
#       .fingerprint/* AND deps/lib*.rlib by FLEET_AGE_D mtime. Filed because
#       the self-hosted runner accumulates 40-60GB here unbounded — it never
#       runs as a worktree so (c)/(d) miss it. Safety guard: skip the
#       sub-target dir if any chump-* binary mtime <24h ago (worker is hot).
#
# Disk-pressure escalation (INFRA-2188):
#   CHUMP_DISK_CRITICAL_GB (default 20) — when df reports free < N GB on
#   $HOME, FINGERPRINT_AGE_D is forced to 1 and FLEET_AGE_D to 2 for this
#   run. Emits kind=cargo_reaper_aggressive_mode_engaged on entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EXECUTE=0
EVENT_LISTEN=0
FINGERPRINT_AGE_D="${CHUMP_CARGO_REAPER_FINGERPRINT_AGE_D:-14}"
FLEET_AGE_D="${CHUMP_CARGO_REAPER_FLEET_AGE_D:-7}"
MIN_FREE_GB=1
# INFRA-2188: when free disk drops below DISK_CRITICAL_GB on $HOME, the reaper
# escalates: FINGERPRINT_AGE_D→1 and FLEET_AGE_D→2 for this run.
DISK_CRITICAL_GB="${CHUMP_DISK_CRITICAL_GB:-20}"
# INFRA-2188: ~/.cache/chump-runner/cargo-target/{debug,release}. Override for
# tests via CHUMP_CARGO_REAPER_RUNNER_CACHE.
RUNNER_CACHE_BASE="${CHUMP_CARGO_REAPER_RUNNER_CACHE:-${HOME}/.cache/chump-runner/cargo-target}"
RUNNER_HOT_BIN_AGE_H="${CHUMP_CARGO_REAPER_RUNNER_HOT_AGE_H:-24}"

# INFRA-1211: shared worktree scanning + github cache libs
# shellcheck source=scripts/lib/worktree-iter.sh
if [[ -f "$(dirname "$0")/../lib/worktree-iter.sh" ]]; then
    source "$(dirname "$0")/../lib/worktree-iter.sh"
fi
# shellcheck source=scripts/coord/lib/github_cache.sh
if [[ -f "$(dirname "$0")/../coord/lib/github_cache.sh" ]]; then
    source "$(dirname "$0")/../coord/lib/github_cache.sh"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)            EXECUTE=1 ;;
        --event-listen)       EVENT_LISTEN=1 ;;
        --fingerprint-age-d)  FINGERPRINT_AGE_D="$2"; shift ;;
        --fleet-age-d)        FLEET_AGE_D="$2"; shift ;;
        --help|-h)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Event-listener mode (INFRA-2181) ────────────────────────────────────────
# When --event-listen is passed, tail-poll ambient.jsonl for
# kind=integration_cycle_shipped and trigger a full reap within 60s.
# Runs indefinitely as a daemon; exits cleanly on SIGTERM/SIGINT.
if [[ $EVENT_LISTEN -eq 1 ]]; then
    _ambient_log="${CHUMP_CARGO_REAPER_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
    _poll_interval="${CHUMP_CARGO_REAPER_EVENT_POLL_S:-30}"
    _reaper_self="${BASH_SOURCE[0]}"
    _execute_flag=""
    [[ $EXECUTE -eq 1 ]] && _execute_flag="--execute"

    echo "[cargo-target-reaper] event-listen mode: polling ${_ambient_log} every ${_poll_interval}s for kind=integration_cycle_shipped"
    printf '{"ts":"%s","kind":"cargo_target_reaper_event_listener_started","poll_interval_s":%d,"execute":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_poll_interval" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
        >> "${_ambient_log}" 2>/dev/null || true

    _last_seen_ts=""
    _stop=0
    trap '_stop=1' SIGTERM SIGINT

    # Fall back to one-shot if ambient log is not readable
    if [[ ! -f "$_ambient_log" ]]; then
        echo "[cargo-target-reaper] WARN: ambient log not found at ${_ambient_log} — running one-shot reap (fail-open)" >&2
        exec bash "$_reaper_self" ${_execute_flag}
    fi

    while [[ $_stop -eq 0 ]]; do
        # Find any integration_cycle_shipped events newer than _last_seen_ts
        _new_event=""
        while IFS= read -r _line; do
            _kind=$(printf '%s' "$_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('kind',''))" 2>/dev/null || true)
            if [[ "$_kind" == "integration_cycle_shipped" ]]; then
                _event_ts=$(printf '%s' "$_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ts',''))" 2>/dev/null || true)
                if [[ -z "$_last_seen_ts" || "$_event_ts" > "$_last_seen_ts" ]]; then
                    _new_event="$_line"
                    _last_seen_ts="$_event_ts"
                fi
            fi
        done < <(tail -200 "$_ambient_log" 2>/dev/null || true)

        if [[ -n "$_new_event" ]]; then
            _gap_id=$(printf '%s' "$_new_event" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gap_id','unknown'))" 2>/dev/null || echo unknown)
            echo "[cargo-target-reaper] integration_cycle_shipped detected (gap=${_gap_id}, ts=${_last_seen_ts}) — triggering reap…"
            printf '{"ts":"%s","kind":"cargo_target_reaper_event_triggered","trigger_event_ts":"%s","gap_id":"%s","execute":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_last_seen_ts" "$_gap_id" \
                "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
                >> "${_ambient_log}" 2>/dev/null || true
            # Run reap inline (not subprocess) so EXECUTE flag propagates cleanly
            # Re-exec as a child to get a fresh process with safety guards reset
            bash "$_reaper_self" ${_execute_flag} &
            _reap_pid=$!
            wait "$_reap_pid" || true
        fi

        # Sleep in small chunks so SIGTERM is caught promptly
        _slept=0
        while [[ $_stop -eq 0 && $_slept -lt $_poll_interval ]]; do
            sleep 5
            _slept=$(( _slept + 5 ))
        done
    done

    echo "[cargo-target-reaper] event-listen mode: received stop signal, exiting cleanly."
    printf '{"ts":"%s","kind":"cargo_target_reaper_event_listener_stopped"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "${_ambient_log}" 2>/dev/null || true
    exit 0
fi

# ── Safety guards ────────────────────────────────────────────────────────────

# INFRA-2188 + ZERO-WASTE-012: compute the disk-critical AGGRESSIVE_MODE FIRST, so
# the guards below can relax when disk is critical. Previously this ran AFTER the
# guards — so on a continuously-building fleet at low disk, the blanket cargo-active
# guard ALWAYS aborted and the aggressive mode never engaged → the reaper never ran
# while the shared target grew unbounded → recurring disk_critical.
AGGRESSIVE_MODE=0
if [[ "$DISK_CRITICAL_GB" -gt 0 ]]; then
    _home_free_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    _home_free_gb=$(( _home_free_kb / 1024 / 1024 ))
    if [[ $_home_free_gb -lt $DISK_CRITICAL_GB ]]; then
        AGGRESSIVE_MODE=1
        FINGERPRINT_AGE_D=1
        FLEET_AGE_D=2
        echo "[cargo-target-reaper] disk-critical: ${_home_free_gb}GB free on \$HOME (< ${DISK_CRITICAL_GB}GB threshold) — escalating: FINGERPRINT_AGE_D=${FINGERPRINT_AGE_D} FLEET_AGE_D=${FLEET_AGE_D}"
        # INFRA-2188: emit ambient event so fleet observers can react.
        _agg_log="${REPO_ROOT}/.chump-locks/ambient.jsonl"
        printf '{"ts":"%s","kind":"cargo_reaper_aggressive_mode_engaged","free_gb":%d,"disk_critical_gb":%d,"fingerprint_age_d":%d,"fleet_age_d":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_home_free_gb" "$DISK_CRITICAL_GB" \
            "$FINGERPRINT_AGE_D" "$FLEET_AGE_D" \
            >> "$_agg_log" 2>/dev/null || true
    fi
fi

# 1. Refuse if any cargo process is active — NORMAL MODE ONLY (ZERO-WASTE-012).
# In disk-critical aggressive mode the fleet is always building, so a blanket abort
# means the reaper NEVER runs while disk fills. The per-target cargo-lock check
# (later, per candidate) + age-based reaping (only stale artifacts an active build
# does not reference) keep aggressive-mode reaping build-safe.
if [[ $AGGRESSIVE_MODE -eq 0 ]] \
   && { pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; }; then
    # Skip cleanly this cycle: an active build is a NORMAL condition on a worker
    # node (it is nearly always building), not a failure. Exiting non-zero here
    # marked the systemd oneshot unit `failed` every tick on a build host — the
    # exact spurious-failure this reaper's own guard should not cause. The timer
    # re-runs it once the build settles; nothing to reap now.
    echo "[cargo-target-reaper] SKIP: active cargo/rustc processes detected — nothing to reap this cycle; will retry next tick." >&2
    exit 0
fi

# 2. Refuse if free disk < MIN_FREE_GB — NORMAL MODE ONLY (ZERO-WASTE-012).
# When disk IS critical (aggressive mode), reaping is exactly what is needed;
# aborting here is backwards for a disk reaper.
if [[ $AGGRESSIVE_MODE -eq 0 ]]; then
    _free_kb=$(df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    _free_gb=$(( _free_kb / 1024 / 1024 ))
    if [[ $_free_gb -lt $MIN_FREE_GB ]]; then
        # Skip cleanly (exit 0, not a failure): in normal mode below the safety
        # floor there is nothing this reaper will safely touch; disk-critical
        # reaping is handled by AGGRESSIVE_MODE above. A non-zero exit here only
        # marked the systemd oneshot unit `failed` without doing any work.
        echo "[cargo-target-reaper] SKIP: only ${_free_gb}GB free — below the ${MIN_FREE_GB}GB normal-mode floor; nothing to reap this cycle." >&2
        exit 0
    fi
fi

AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"
_dry_label="[DRY-RUN]"
[[ $EXECUTE -eq 1 ]] && _dry_label=""

_total_bytes=0
_reaped_count=0

# ── Helper: maybe_delete ─────────────────────────────────────────────────────
# Usage: maybe_delete <path>
maybe_delete() {
    local path="$1"
    local size_bytes=0
    if [[ -d "$path" ]]; then
        size_bytes=$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    elif [[ -f "$path" ]]; then
        size_bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
    fi
    local age_days=0
    age_days=$(( ( $(date +%s) - $(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  reap: ${path} (${age_days}d old, ~$(( size_bytes / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$path"
    fi
    _total_bytes=$(( _total_bytes + size_bytes ))
    _reaped_count=$(( _reaped_count + 1 ))
    # Emit per-artifact ambient event
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$size_bytes" "$age_days" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── (a+b) main repo target/debug ─────────────────────────────────────────────
TARGET_DEBUG="${REPO_ROOT}/target/debug"
if [[ -d "$TARGET_DEBUG" ]]; then
    echo "[cargo-target-reaper] Scanning ${TARGET_DEBUG}/.fingerprint/* (>${FINGERPRINT_AGE_D}d)…"
    while IFS= read -r -d '' entry; do
        maybe_delete "$entry"
    done < <(find "${TARGET_DEBUG}/.fingerprint" -mindepth 1 -maxdepth 1 -mtime "+${FINGERPRINT_AGE_D}" -print0 2>/dev/null)

    echo "[cargo-target-reaper] Scanning ${TARGET_DEBUG}/deps/lib*.rlib (>${FINGERPRINT_AGE_D}d)…"
    while IFS= read -r -d '' entry; do
        maybe_delete "$entry"
    done < <(find "${TARGET_DEBUG}/deps" -maxdepth 1 -name 'lib*.rlib' -mtime "+${FINGERPRINT_AGE_D}" -print0 2>/dev/null)
fi

# ── (c) fleet shared target dirs ─────────────────────────────────────────────
FLEET_CACHE="${HOME}/.cache/chump-fleet-target"
if [[ -d "$FLEET_CACHE" ]]; then
    echo "[cargo-target-reaper] Scanning ${FLEET_CACHE}/ (>${FLEET_AGE_D}d, no live owner)…"
    # Collect all CARGO_TARGET_DIR values from live processes
    _live_targets=""
    while IFS= read -r pid; do
        _env=$(ps eww -p "$pid" 2>/dev/null | grep -o 'CARGO_TARGET_DIR=[^ ]*' | head -1 || true)
        if [[ -n "$_env" ]]; then
            _live_targets="${_live_targets}${_env##*=}"$'\n'
        fi
    done < <(pgrep -f "cargo|rustc" 2>/dev/null || true)

    while IFS= read -r -d '' dir; do
        _basename=$(basename "$dir")
        # Skip if any live process references this dir
        if echo "$_live_targets" | grep -qF "$_basename" 2>/dev/null; then
            echo "  skip (live owner): ${dir}"
            continue
        fi
        maybe_delete "$dir"
    done < <(find "$FLEET_CACHE" -mindepth 1 -maxdepth 1 -type d -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
fi

# ── (d) INFRA-1170: /tmp/chump-*/target/ orphaned by gone worktrees ──────────
# Reap target/ dirs in /tmp/chump-* paths where the originating git worktree
# is no longer registered in `git worktree list --porcelain`. Safe because:
#   - If the worktree was removed (git worktree remove), the target dir is dead weight.
#   - If the worktree is still active, git worktree list will still show it.
#
# Failure taxonomy (emitted as ambient events):
#   transient: cargo lock file present (.cargo-lock) — build may be in flight.
#   permanent: rm -rf failed (path gone mid-reap, permission error, etc.).
_tmp_orphan_count=0

# Build set of registered worktree paths (INFRA-1211: use shared scanner).
_registered_wts=$'\n'
if command -v scan_worktrees >/dev/null 2>&1; then
    for _wt in $(scan_worktrees --include-tmp --include-dot-claude); do
        _registered_wts="${_registered_wts}${_wt}"$'\n'
    done
else
    # Fallback to legacy scan if lib missing
    _wt_list_raw="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)"
    while IFS= read -r _wt_line; do
        if [[ "$_wt_line" == worktree\ * ]]; then
            _registered_wts="${_registered_wts}${_wt_line#worktree }"$'\n'
        fi
    done <<< "$_wt_list_raw"
fi

# Support override for testing: CHUMP_CARGO_REAPER_TMP_GLOB controls the scan path.
_TMP_GLOB="${CHUMP_CARGO_REAPER_TMP_GLOB:-/tmp/chump-*}"
echo "[cargo-target-reaper] Scanning ${_TMP_GLOB}/target/ (orphaned worktrees)…"

# META-117/B: materialize _registered_wts to a tempfile once before loop
_META117_REG_WTS_BUF="$(mktemp)"
trap 'rm -f "$_META117_REG_WTS_BUF"' EXIT
printf '%s' "$_registered_wts" > "$_META117_REG_WTS_BUF"

for _wt_candidate in ${_TMP_GLOB}/; do
    [[ -d "$_wt_candidate" ]] || continue
    _wt_candidate="${_wt_candidate%/}"
    _target_candidate="${_wt_candidate}/target"
    [[ -d "$_target_candidate" ]] || continue

    # Skip if this worktree is still registered with git.
    if grep -qxF "$_wt_candidate" "$_META117_REG_WTS_BUF" 2>/dev/null; then
        echo "  skip (registered worktree): ${_wt_candidate}"
        continue
    fi

    # RESILIENT-116: honor the .chump-no-reap escape hatch (same sentinel
    # active-target-reaper.sh and stale-worktree-reaper.sh respect — see
    # RESILIENT-107 precedent). Checked before any deletion decision.
    if [[ -e "${_wt_candidate}/.chump-no-reap" ]]; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"no_reap_marker"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (.chump-no-reap present): ${_target_candidate}"
        continue
    fi

    # Transient failure: cargo lock present means a build may be in flight.
    if [[ -f "${_target_candidate}/.cargo-lock" ]]; then
        printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","error":"cargo_lock_active","failure_class":"transient","worktree_gone":true,"dry_run":true}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (cargo lock active — transient): ${_target_candidate}"
        continue
    fi

    # RESILIENT-116: lsof guard — a live process with files open under
    # target/ means a build is actively writing to it even when no
    # .cargo-lock is present (e.g. between compiler invocations).
    if command -v lsof >/dev/null 2>&1 && lsof -F n +D "$_target_candidate" 2>/dev/null | grep -q .; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (process has files open — active build): ${_target_candidate}"
        continue
    fi

    _t_size_bytes=$(du -sk "$_target_candidate" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _t_age_days=$(( ( $(date +%s) - $(stat -f%m "$_target_candidate" 2>/dev/null \
        || stat -c%Y "$_target_candidate" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  orphan worktree target: ${_target_candidate} (${_t_age_days}d old, ~$(( _t_size_bytes / 1024 / 1024 ))MB)"

    _reap_ok=1
    if [[ $EXECUTE -eq 1 ]]; then
        if ! rm -rf "$_target_candidate" 2>/dev/null; then
            # Permanent failure: path vanished mid-reap or permission denied.
            printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","error":"rm_failed","failure_class":"permanent","worktree_gone":true}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
                >> "$AMBIENT_LOG" 2>/dev/null || true
            _reap_ok=0
        fi
    fi

    if [[ $_reap_ok -eq 1 ]]; then
        _total_bytes=$(( _total_bytes + _t_size_bytes ))
        _reaped_count=$(( _reaped_count + 1 ))
        _tmp_orphan_count=$(( _tmp_orphan_count + 1 ))
        printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"worktree_gone":true}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            "$_t_size_bytes" "$_t_age_days" \
            "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
    fi
done

# ── (e) INFRA-2125/A: Linux cross-build artifacts ───────────────────────────
# /tmp/chump-coord-linux-build* and /tmp/chump-cross-build-* from cross-build-linux.sh
_cross_build_count=0
echo "[cargo-target-reaper] Scanning /tmp/chump-coord-linux-build* and /tmp/chump-cross-build-* (Class A cross-build artifacts)…"
for _cross_dir in /tmp/chump-coord-linux-build* /tmp/chump-cross-build-*; do
    [[ -d "$_cross_dir" ]] || continue
    _cb_size=$(du -sk "$_cross_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _cb_age=$(( ( $(date +%s) - $(stat -f%m "$_cross_dir" 2>/dev/null || stat -c%Y "$_cross_dir" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  cross-build artifact: ${_cross_dir} (${_cb_age}d old, ~$(( _cb_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_cross_dir" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _cb_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _cross_build_count=$(( _cross_build_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"cross_build"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_cross_dir" "$_cb_size" "$_cb_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (f) INFRA-2125/B: hidden .cargo-test-target/ dirs ───────────────────────
# /tmp/chump-*/.cargo-test-target/ — Sonnet workers setting custom CARGO_TARGET_DIR
_cargo_test_target_count=0
echo "[cargo-target-reaper] Scanning /tmp/chump-*/.cargo-test-target/ (Class B worker cargo-test-target dirs)…"
for _wt_dir in ${_TMP_GLOB:-/tmp/chump-*}/; do
    [[ -d "$_wt_dir" ]] || continue
    _ctt="${_wt_dir%/}/.cargo-test-target"
    [[ -d "$_ctt" ]] || continue
    _ctt_size=$(du -sk "$_ctt" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _ctt_age=$(( ( $(date +%s) - $(stat -f%m "$_ctt" 2>/dev/null || stat -c%Y "$_ctt" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  cargo-test-target: ${_ctt} (${_ctt_age}d old, ~$(( _ctt_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_ctt" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _ctt_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _cargo_test_target_count=$(( _cargo_test_target_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"cargo_test_target"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ctt" "$_ctt_size" "$_ctt_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (g) INFRA-2125/C: lease-active worktrees with pushed+auto-merge PR ──────
# Reap target/ in a worktree that has an active lease IF:
#   1. A PR exists for the branch
#   2. That PR has autoMergeRequest != null (auto-merge armed)
#   3. Local HEAD matches origin/<branch> (work is safely on origin)
# Reasoning: work is on origin; rebuild cost is bounded if CI bounces.
_lease_armed_count=0
echo "[cargo-target-reaper] Scanning lease-active worktrees for pushed+auto-merge PRs (Class C)…"
for _lease_file in "${REPO_ROOT}/.chump-locks"/*.json; do
    [[ -f "$_lease_file" ]] || continue
    _lease_wt=$(python3 -c "import json,sys; d=json.load(open('$_lease_file')); print(d.get('worktree',''))" 2>/dev/null || true)
    [[ -n "$_lease_wt" ]] || continue
    _lease_target="${_lease_wt}/target"
    [[ -d "$_lease_target" ]] || continue

    # RESILIENT-116: honor the .chump-no-reap escape hatch — a pushed +
    # auto-merge-armed PR can still have a build actively running (e.g. a
    # local re-test after push) racing this class-C reap.
    if [[ -e "${_lease_wt}/.chump-no-reap" ]]; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"no_reap_marker"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (.chump-no-reap present): ${_lease_target}"
        continue
    fi

    # RESILIENT-116: active cargo lock or fresh mtime means a build may be
    # mid-flight in this worktree; do not race it even if the PR is pushed.
    if [[ -f "${_lease_target}/.cargo-lock" ]]; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (cargo lock active — transient): ${_lease_target}"
        continue
    fi
    if command -v lsof >/dev/null 2>&1 && lsof -F n +D "$_lease_target" 2>/dev/null | grep -q .; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (process has files open — active build): ${_lease_target}"
        continue
    fi

    # Get branch name from worktree
    _branch=$(git -C "$_lease_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ -n "$_branch" ]] || continue

    # Check: does a PR exist for this branch? (INFRA-1081: cache-first)
    _pr_json=""
    if command -v cache_lookup_pr_by_branch >/dev/null 2>&1; then
        _pr_json=$(cache_lookup_pr_by_branch "$_branch" 2>/dev/null || true)
        if [[ -n "$_pr_json" ]]; then
            _pr_json="[$_pr_json]" # wrap in array to match gh pr list --json output shape
        fi
    fi

    if [[ -z "$_pr_json" ]]; then
        _pr_json=$(gh pr list --head "$_branch" --json number,autoMergeRequest,headRefOid --limit 1 2>/dev/null || true)
    fi
    [[ -n "$_pr_json" ]] || continue
    _pr_count=$(echo "$_pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)
    [[ "$_pr_count" -gt 0 ]] || continue

    # Check: auto-merge armed?
    _auto_merge=$(echo "$_pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d[0].get('autoMergeRequest') else 'no')" 2>/dev/null || echo no)
    [[ "$_auto_merge" == "yes" ]] || continue

    # Check: local HEAD matches remote tip?
    _local_head=$(git -C "$_lease_wt" rev-parse HEAD 2>/dev/null || true)
    _remote_head=$(git -C "$_lease_wt" rev-parse "origin/${_branch}" 2>/dev/null || true)
    [[ -n "$_local_head" && -n "$_remote_head" ]] || continue
    [[ "$_local_head" == "$_remote_head" ]] || continue

    _lt_size=$(du -sk "$_lease_target" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _lt_age=$(( ( $(date +%s) - $(stat -f%m "$_lease_target" 2>/dev/null || stat -c%Y "$_lease_target" 2>/dev/null || echo 0) ) / 86400 ))
    _pr_num=$(echo "$_pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['number'])" 2>/dev/null || echo unknown)
    echo "${_dry_label}  lease+auto-merge target: ${_lease_target} (PR #${_pr_num} auto-merge armed, HEAD pushed, ${_lt_age}d old, ~$(( _lt_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_lease_target" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _lt_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _lease_armed_count=$(( _lease_armed_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"lease_auto_merge","pr_number":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" "$_lt_size" "$_lt_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$_pr_num" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (h) INFRA-2188: chump-runner cargo-target cache ─────────────────────────
# The self-hosted runner sets CARGO_TARGET_DIR=~/.cache/chump-runner/cargo-target
# and accumulates 40-60GB there unbounded. It's never a worktree path so (c)/(d)
# miss it. We mirror the (a+b) pattern but key the safety guard on per-profile
# hot-binary mtime: if any chump-* binary in the profile dir was touched within
# the last RUNNER_HOT_BIN_AGE_H hours, skip that profile (runner job in flight).
_runner_scope_count=0
if [[ -d "$RUNNER_CACHE_BASE" ]]; then
    echo "[cargo-target-reaper] Scanning ${RUNNER_CACHE_BASE}/{debug,release} (runner-scope; hot-touch guard ${RUNNER_HOT_BIN_AGE_H}h)…"
    for _profile in debug release; do
        _prof_dir="${RUNNER_CACHE_BASE}/${_profile}"
        [[ -d "$_prof_dir" ]] || continue

        # Hot-touch guard: scan top-level chump-* binaries (no extension) for
        # any mtime newer than RUNNER_HOT_BIN_AGE_H hours. If hot, skip.
        _hot=0
        _hot_age_s=$(( RUNNER_HOT_BIN_AGE_H * 3600 ))
        _now_epoch=$(date +%s)
        while IFS= read -r -d '' _bin; do
            [[ -f "$_bin" ]] || continue
            # Skip .d / .rlib / .rmeta / dirs
            case "$_bin" in *.d|*.rlib|*.rmeta) continue ;; esac
            _bmtime=$(stat -f%m "$_bin" 2>/dev/null || stat -c%Y "$_bin" 2>/dev/null || echo 0)
            if [[ $(( _now_epoch - _bmtime )) -lt $_hot_age_s ]]; then
                _hot=1
                echo "  skip (${_profile}: hot binary $(basename "$_bin") <${RUNNER_HOT_BIN_AGE_H}h)"
                break
            fi
        done < <(find "$_prof_dir" -mindepth 1 -maxdepth 1 -name 'chump*' -type f -print0 2>/dev/null)
        [[ $_hot -eq 1 ]] && continue

        # Reap .fingerprint/* > FLEET_AGE_D
        if [[ -d "${_prof_dir}/.fingerprint" ]]; then
            while IFS= read -r -d '' _entry; do
                _rs_size=$(du -sk "$_entry" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
                _rs_age=$(( ( _now_epoch - $(stat -f%m "$_entry" 2>/dev/null || stat -c%Y "$_entry" 2>/dev/null || echo 0) ) / 86400 ))
                echo "${_dry_label}  runner-scope reap: ${_entry} (${_rs_age}d old, ~$(( _rs_size / 1024 / 1024 ))MB)"
                if [[ $EXECUTE -eq 1 ]]; then
                    rm -rf "$_entry" 2>/dev/null || true
                fi
                _total_bytes=$(( _total_bytes + _rs_size ))
                _reaped_count=$(( _reaped_count + 1 ))
                _runner_scope_count=$(( _runner_scope_count + 1 ))
                printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"runner_cache","profile":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_entry" "$_rs_size" "$_rs_age" \
                    "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$_profile" \
                    >> "$AMBIENT_LOG" 2>/dev/null || true
            done < <(find "${_prof_dir}/.fingerprint" -mindepth 1 -maxdepth 1 -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
        fi

        # Reap deps/lib*.rlib > FLEET_AGE_D
        if [[ -d "${_prof_dir}/deps" ]]; then
            while IFS= read -r -d '' _entry; do
                _rs_size=$(stat -f%z "$_entry" 2>/dev/null || stat -c%s "$_entry" 2>/dev/null || echo 0)
                _rs_age=$(( ( _now_epoch - $(stat -f%m "$_entry" 2>/dev/null || stat -c%Y "$_entry" 2>/dev/null || echo 0) ) / 86400 ))
                echo "${_dry_label}  runner-scope reap: ${_entry} (${_rs_age}d old, ~$(( _rs_size / 1024 / 1024 ))MB)"
                if [[ $EXECUTE -eq 1 ]]; then
                    rm -f "$_entry" 2>/dev/null || true
                fi
                _total_bytes=$(( _total_bytes + _rs_size ))
                _reaped_count=$(( _reaped_count + 1 ))
                _runner_scope_count=$(( _runner_scope_count + 1 ))
                printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"runner_cache","profile":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_entry" "$_rs_size" "$_rs_age" \
                    "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$_profile" \
                    >> "$AMBIENT_LOG" 2>/dev/null || true
            done < <(find "${_prof_dir}/deps" -maxdepth 1 -name 'lib*.rlib' -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
        fi
    done
fi

# ── Summary ──────────────────────────────────────────────────────────────────
_total_mb=$(( _total_bytes / 1024 / 1024 ))
echo ""
echo "[cargo-target-reaper] ${_dry_label} Done: ${_reaped_count} artifacts, ~${_total_mb}MB (orphaned /tmp worktrees: ${_tmp_orphan_count}, runner-scope: ${_runner_scope_count})"
if [[ $EXECUTE -eq 0 && $_reaped_count -gt 0 ]]; then
    echo "[cargo-target-reaper] Re-run with --execute to actually delete."
fi

# Summary ambient event — includes worktree_orphan_count (INFRA-1170) + INFRA-2125 class counts + INFRA-2188 runner_scope_count + aggressive_mode flag.
printf '{"ts":"%s","kind":"cargo_target_reaper_summary","reaped_count":%d,"bytes_freed":%d,"execute":%s,"worktree_orphan_count":%d,"cross_build_count":%d,"cargo_test_target_count":%d,"lease_auto_merge_count":%d,"runner_scope_count":%d,"aggressive_mode":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_reaped_count" "$_total_bytes" \
    "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
    "$_tmp_orphan_count" "$_cross_build_count" "$_cargo_test_target_count" "$_lease_armed_count" \
    "$_runner_scope_count" "$([[ $AGGRESSIVE_MODE -eq 1 ]] && echo 'true' || echo 'false')" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
