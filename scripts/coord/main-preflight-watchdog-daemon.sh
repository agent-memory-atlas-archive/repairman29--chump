#!/usr/bin/env bash
# scripts/coord/main-preflight-watchdog-daemon.sh — INFRA-2397
#
# Main-Preflight Watchdog daemon: runs `chump preflight` against a fresh
# worktree of origin/main on a periodic interval and files a P0 gap when any
# gate fails. Closes the observation gap identified in the PR #2942 post-mortem
# (INFRA-2396): the existing trunk-sentinel only watches ci.yml conclusion on
# main — it misses 5+ audit-class gates that fail on PR validation but not on
# main's own post-merge CI.
#
# Pillars: RESILIENT + ZERO-WASTE. A preflight-red trunk that nobody notices
# until the next innocent PR pays a 60+ minute tax is a fleet-halt-class wedge.
# This daemon closes that observation gap autonomously via local gate execution
# (no gh calls required).
#
# State machine:
#   GREEN   last tick: all preflight gates passed → emit heartbeat, no gap
#   RED     last tick: one or more gates failed → file P0 gap (idempotent),
#           emit kind=main_preflight_red
#   RECOVERY  transition RED→GREEN → emit kind=main_preflight_recovered,
#           close auto-filed gaps
#
# Idempotency: sha256 fingerprint of sorted failing-gate names. Same fingerprint
# on the next tick → no re-spam. New failing gate appears → new gap.
#
# Recovery: when all gates pass after a red window, emits
# kind=main_preflight_recovered and closes any gaps auto-filed during the
# RED window (tracked in .chump/main-preflight-state.json).
#
# scanner-anchor: "kind":"main_preflight_red"
# scanner-anchor: "kind":"main_preflight_recovered"
# scanner-anchor: "kind":"main_preflight_disabled"
#
# Usage:
#   bash scripts/coord/main-preflight-watchdog-daemon.sh tick        # one tick
#   bash scripts/coord/main-preflight-watchdog-daemon.sh --help
#   bash scripts/coord/main-preflight-watchdog-daemon.sh             # one tick (launchd default)
#
# Env knobs (all optional):
#   CHUMP_MAIN_PREFLIGHT_DISABLED   non-empty → exit 0 immediately (audit-logged)
#   CHUMP_MAIN_PREFLIGHT_INTERVAL_S seconds between ticks in daemon loop (default 600)
#   CHUMP_MAIN_PREFLIGHT_DRY_RUN    non-empty → no chump writes (default unset)
#   CHUMP_MAIN_PREFLIGHT_STATE_FILE path to state JSON (default $REPO/.chump/main-preflight-state.json)
#   CHUMP_MAIN_PREFLIGHT_MOCK_FAIL  CSV of fake failing gate names (test-mode only)
#   CHUMP_MAIN_PREFLIGHT_MOCK_PASS  non-empty → treat preflight as passed (test-mode only)
#   CHUMP_AMBIENT_PATH              override ambient.jsonl path (META-248)
#   CHUMP_AMBIENT_LOG               legacy alias for CHUMP_AMBIENT_PATH
#   CHUMP_MAIN_PREFLIGHT_TARGET_DIR persistent CARGO_TARGET_DIR for ticks
#                                   (default ~/.chump/main-preflight-target, ZERO-WASTE-142)
#   CHUMP_MAIN_PREFLIGHT_MIN_INTERVAL_S floor between real ticks, seconds
#                                   (default 1800, ZERO-WASTE-142)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# META-248: honor CHUMP_AMBIENT_PATH first, CHUMP_AMBIENT_LOG legacy alias second.
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

# ── Configuration ─────────────────────────────────────────────────────────────
DISABLED="${CHUMP_MAIN_PREFLIGHT_DISABLED:-}"
DRY_RUN="${CHUMP_MAIN_PREFLIGHT_DRY_RUN:-}"
STATE_FILE="${CHUMP_MAIN_PREFLIGHT_STATE_FILE:-$REPO_ROOT/.chump/main-preflight-state.json}"
MOCK_FAIL="${CHUMP_MAIN_PREFLIGHT_MOCK_FAIL:-}"
MOCK_PASS="${CHUMP_MAIN_PREFLIGHT_MOCK_PASS:-}"

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

CHUMP_BIN="${CHUMP_MAIN_PREFLIGHT_CHUMP_CMD:-chump}"

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ -n "$DISABLED" ]]; then
    _ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    printf '[main-preflight-watchdog] CHUMP_MAIN_PREFLIGHT_DISABLED set — exiting\n' >&2
    printf '{"ts":"%s","kind":"main_preflight_disabled","dry_run":false}\n' \
        "$(_ts)" >> "$AMBIENT"
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts()        { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date +%s; }
log()        { printf '[main-preflight-watchdog] %s\n' "$*" >&2; }

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local dry; if [[ -n "$DRY_RUN" ]]; then dry="true"; else dry="false"; fi
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry,$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

_load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" 2>/dev/null || printf '{}'
    else
        printf '{}'
    fi
}

_save_state() {
    local body="$1"
    printf '%s\n' "$body" > "$STATE_FILE"
}

# Fingerprint = sha256(sorted failing-gate names, pipe-joined), first 12 chars.
# INFRA-2404 BUG-3 fix: prior `tr '\n' '\n'` was a no-op identity transform.
# That left the shasum input with a trailing newline AND ambiguous boundary if
# a gate name ever contained whitespace, risking false-dedup collisions.
# Pipe-delimit instead — gate names cannot legitimately contain `|`.
_gate_fingerprint() {
    local gates_csv="$1"
    if [[ -z "$gates_csv" ]]; then
        printf 'nofail'
        return
    fi
    printf '%s' "$gates_csv" \
        | tr ',' '\n' \
        | sort \
        | tr '\n' '|' \
        | shasum -a 256 \
        | cut -c1-12
}

# Generate a unique tick ID for correlating log lines and events.
_tick_id() {
    printf 'tick-%s-%s' "$(_now_epoch)" "$$"
}

# ── (1) Run preflight against a fresh origin/main worktree ───────────────────
# Returns CSV of failing gate names on stdout.
# An empty return means all gates passed.
#
# Strategy: clone origin/main into a fresh /tmp worktree, run `chump preflight`
# there, parse FAIL: lines. Clean up the worktree when done.
#
# Test hooks (used by test-main-preflight-watchdog.sh):
#   CHUMP_MAIN_PREFLIGHT_MOCK_FAIL  — CSV of gate names to treat as failing
#   CHUMP_MAIN_PREFLIGHT_MOCK_PASS  — if set, treat all gates as passing
_run_preflight() {
    # Test-mode: mock pass
    if [[ -n "$MOCK_PASS" ]]; then
        log "MOCK_PASS set — treating all gates as passed"
        printf ''
        return 0
    fi

    # Test-mode: mock fail
    if [[ -n "$MOCK_FAIL" ]]; then
        log "MOCK_FAIL set — injecting failing gates: $MOCK_FAIL"
        printf '%s' "$MOCK_FAIL"
        return 0
    fi

    # Real mode: create a fresh worktree of origin/main in /tmp
    local ts_str; ts_str="$(date +%Y%m%d%H%M%S)"
    local wt_path="/tmp/chump-main-preflight-${ts_str}-$$"
    local head_sha=""
    local failing_gates=""

    # ZERO-WASTE-142: a persistent, shared CARGO_TARGET_DIR outside the
    # per-tick mirror. Before this, every tick built into wt_path/target —
    # a cold build every time (1h+ CPU, 11G on disk) because the mirror
    # (and its target/) was deleted at tick end. Pointing CARGO_TARGET_DIR
    # at a dir that outlives the mirror makes each tick an incremental
    # build; only the source checkout (small) lives in /tmp.
    local target_dir="${CHUMP_MAIN_PREFLIGHT_TARGET_DIR:-$HOME/.chump/main-preflight-target}"
    mkdir -p "$target_dir" 2>/dev/null || true

    # Cleanup trap — runs on function exit regardless
    local cleanup_done=0
    _cleanup_wt() {
        if [[ "$cleanup_done" -eq 0 ]]; then
            cleanup_done=1
            if [[ -d "$wt_path" ]]; then
                git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
                rm -rf "$wt_path" 2>/dev/null || true
                log "cleaned up worktree: $wt_path"
            fi
        fi
    }
    # Note: trap is local to subshell context if called inside $(...).
    # We handle cleanup inline after the block below.

    # Fetch latest origin/main
    git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || {
        log "WARN: git fetch origin main failed — skipping this tick"
        printf ''
        return 0
    }

    head_sha="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"

    # Add a temporary worktree at origin/main
    if ! git -C "$REPO_ROOT" worktree add --quiet "$wt_path" origin/main 2>/dev/null; then
        log "WARN: git worktree add failed for $wt_path — skipping tick"
        rm -rf "$wt_path" 2>/dev/null || true
        printf ''
        return 0
    fi

    log "running chump preflight in worktree: $wt_path (sha=${head_sha:0:12})"

    # Run preflight; capture stdout for FAIL: line parsing.
    # INFRA-2404 BUG-2 fix: cd into the worktree AND set REPO_ROOT to it. The
    # prior code set REPO_ROOT to the parent repo, so preflight actually ran
    # against the developer's current branch — defeating the whole "watch
    # origin/main" premise. Both `cd` and REPO_ROOT are needed: `cd` makes
    # preflight's CWD-relative file lookups work; REPO_ROOT pins config lookup.
    local preflight_out=""
    local preflight_rc=0
    preflight_out="$(cd "$wt_path" && REPO_ROOT="$wt_path" CARGO_TARGET_DIR="$target_dir" \
        "$CHUMP_BIN" preflight 2>&1)" || preflight_rc=$?

    # INFRA-2458: Parse `chump preflight`'s structured per-gate failure marker:
    #
    #     [preflight] <gate-name> ... ✗ (<N>ms)
    #
    # The previous regex `FAIL[: \t]+[^ \t]+` matched the SUMMARY line
    # `[preflight] FAIL — at least one gate did not pass (total {ms}ms)` and
    # captured the literal em-dash as a "gate name", producing
    # failing_gates=["—"] false positives that wedged the claim health gate
    # for every fleet member until a human flipped state.json.
    #
    # New rules:
    #   1. Extract only lines that match preflight's structured per-gate
    #      failure marker: `^\[preflight\] <gate> ... ✗`. This is the ONE
    #      authoritative signal for per-gate failure.
    #   2. Gate names are restricted to `[A-Za-z][A-Za-z0-9_.-]*` — letters,
    #      digits, dot, dash, underscore. Anything else (em-dash, punctuation,
    #      whitespace) is rejected at the regex layer.
    #   3. If the regex extracts nothing AND preflight_rc != 0, log a warning
    #      and use the generic "preflight-exit-nonzero" label so we still
    #      fingerprint+file, but the gate-name list is honest (one entry,
    #      ASCII, no garbage).
    if [[ "$preflight_rc" -ne 0 ]]; then
        # The ✗ character is U+2717 (HEAVY BALLOT X). Embed it literally in
        # the regex; bash regex handles UTF-8 byte sequences as opaque.
        failing_gates="$(printf '%s' "$preflight_out" \
            | grep -E '^\[preflight\] [A-Za-z][A-Za-z0-9_.-]* \.\.\. ✗' \
            | sed -E 's/^\[preflight\] ([A-Za-z][A-Za-z0-9_.-]*) \.\.\. ✗.*$/\1/' \
            | sort -u \
            | tr '\n' ',' \
            | sed 's/,$//')"

        # Defense-in-depth: drop any extracted "gate" that is empty or
        # contains only non-alphanumeric characters (punctuation, dashes,
        # whitespace). This catches edge cases the regex above might miss
        # (e.g. future preflight output format drift).
        local sanitized=""
        local IFS=','
        for g in $failing_gates; do
            # Trim whitespace; reject if empty or no alphanumerics.
            g="${g#"${g%%[![:space:]]*}"}"
            g="${g%"${g##*[![:space:]]}"}"
            if [[ -n "$g" && "$g" =~ [A-Za-z0-9] ]]; then
                if [[ -z "$sanitized" ]]; then
                    sanitized="$g"
                else
                    sanitized="$sanitized,$g"
                fi
            fi
        done
        failing_gates="$sanitized"

        # If no structured FAIL lines found but preflight exited non-zero,
        # use a generic label so we still file and fingerprint.
        if [[ -z "$failing_gates" ]]; then
            failing_gates="preflight-exit-nonzero"
        fi
        log "preflight returned exit=$preflight_rc failing_gates=[$failing_gates]"
    else
        log "preflight PASSED (exit=0)"
    fi

    # Cleanup worktree
    git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
    rm -rf "$wt_path" 2>/dev/null || true

    printf '%s' "$failing_gates"
}

# ── (2) File a P0 preflight-red gap (idempotent via fingerprint) ──────────────
_file_preflight_gap() {
    local fingerprint="$1" failing_csv="$2" head_sha="$3" tick_id="$4"

    if [[ -n "$DRY_RUN" ]]; then
        log "DRY_RUN: would file preflight-red gap (fp=$fingerprint gates=$failing_csv)"
        printf 'INFRA-DRYRUN-%s' "$fingerprint"
        return 0
    fi

    # Use the first gate as the primary label in the title
    local primary_gate
    primary_gate="$(printf '%s' "$failing_csv" | tr ',' '\n' | head -1)"
    primary_gate="${primary_gate:-unknown}"

    local title
    title="RESILIENT: INFRA-NEW-MAIN-RED-${primary_gate}: preflight gate failure on origin/main (fp=${fingerprint})"

    local description
    description="main-preflight-watchdog (INFRA-2397) detected one or more preflight gates failing on origin/main.

  - Failing gates: ${failing_csv:-unknown}
  - Fingerprint: ${fingerprint}
  - Head SHA: ${head_sha:-unknown}
  - Tick ID: ${tick_id}

This gap was auto-filed by scripts/coord/main-preflight-watchdog-daemon.sh. The fingerprint is sha256(sorted failing-gate names) so a second tick with the same failure set will NOT re-file. A new failing gate will file a new gap.

CONTEXT: The trunk-sentinel daemon watches ci.yml conclusion on main — it does NOT catch preflight/audit-class gates that fail on PR validation but not on main's own post-merge CI. This daemon fills that gap by running chump preflight against origin/main locally.

Recommended workflow:
  1. Run locally: chump preflight  (should reproduce the failure)
  2. Identify the failing gate from: ${failing_csv:-unknown}
  3. Fix the gate or the underlying code issue
  4. When origin/main passes preflight, this daemon will emit main_preflight_recovered and close this gap automatically.

This is a fleet-halt-class wedge: the next PR opened against main will inherit this failure. Fix before picking new work."

    local out exit_code gap_id
    exit_code=0
    out="$(CHUMP_GAP_RESERVE_NO_SIMILARITY=1 FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --priority P0 \
        --effort s \
        --title "$title" \
        --force-duplicate 2>&1)" || exit_code=$?

    gap_id="$(printf '%s' "$out" | grep -oE 'INFRA-[0-9]+' | head -1)"
    if [[ -n "$gap_id" ]]; then
        log "filed preflight-red gap: $gap_id (fp=$fingerprint)"

        # Backfill description + acceptance criteria
        local ac
        ac="All preflight gates pass on origin/main|chump preflight exits 0 on a fresh worktree|main-preflight-watchdog emits main_preflight_recovered and closes this gap"
        if ! "$CHUMP_BIN" gap set "$gap_id" \
            --description "$description" \
            --acceptance-criteria "$ac" >/dev/null 2>&1; then
            log "WARN: failed to backfill description on $gap_id"
        fi
        printf '%s' "$gap_id"
    else
        log "WARN: gap reserve failed (exit=$exit_code): $out"
        printf 'UNFILED'
    fi
}

# ── (3) Recovery: close gaps auto-filed during the red window ─────────────────
_recover_close_gaps() {
    local prev_state_str="$1"
    local filed_csv
    filed_csv="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(','.join(s.get('filed_gaps', [])))
except Exception:
    pass
" 2>/dev/null || true)"

    if [[ -z "$filed_csv" ]]; then
        return 0
    fi

    local closed=0 g
    local IFS=','
    for g in $filed_csv; do
        [[ -z "$g" || "$g" == "UNFILED" || "$g" == INFRA-DRYRUN-* ]] && continue
        if [[ -n "$DRY_RUN" ]]; then
            log "DRY_RUN: would close $g (preflight recovered)"
            closed=$((closed + 1))
            continue
        fi
        if "$CHUMP_BIN" gap set "$g" --status "done" \
            --note "main-preflight-watchdog: preflight recovered on origin/main" \
            >/dev/null 2>&1; then
            log "closed $g (preflight recovered)"
            closed=$((closed + 1))
        else
            log "WARN: failed to close $g"
        fi
    done

    printf '%d %s' "$closed" "$filed_csv"
}

# ── (4) Tick — one reconcile iteration ───────────────────────────────────────
#
# ZERO-WASTE-142: before running the expensive worktree+preflight path, check
# two cheap short-circuits against the PREVIOUS verdict's state:
#   - cadence floor: don't run a real tick within CHUMP_MAIN_PREFLIGHT_MIN_INTERVAL_S
#     of the previous real tick (no back-to-back hour-long ticks).
#   - sha-unchanged: if origin/main hasn't moved since the last verdict, the
#     answer can't have changed — skip the rebuild entirely.
# Both reads are a `git fetch` + `rev-parse`, not a worktree checkout.
cmd_tick() {
    local tick_id; tick_id="$(_tick_id)"
    log "tick start: $tick_id"

    local floor_s="${CHUMP_MAIN_PREFLIGHT_MIN_INTERVAL_S:-1800}"
    local prev_state_peek; prev_state_peek="$(_load_state)"
    local prev_head_sha_peek prev_tick_at_peek
    prev_head_sha_peek="$(printf '%s' "$prev_state_peek" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(s.get('last_head_sha', ''))
except Exception:
    pass
" 2>/dev/null || true)"
    prev_tick_at_peek="$(printf '%s' "$prev_state_peek" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(int(s.get('last_tick_at', 0) or 0))
except Exception:
    print(0)
" 2>/dev/null || printf '0')"

    if [[ -z "$MOCK_PASS" && -z "$MOCK_FAIL" ]]; then
        local now_secs; now_secs="$(date -u +%s)"
        if [[ -n "$prev_tick_at_peek" && "$prev_tick_at_peek" != "0" ]] \
            && (( now_secs - prev_tick_at_peek < floor_s )); then
            log "tick skip: cadence floor not elapsed ($(( now_secs - prev_tick_at_peek ))s < ${floor_s}s)"
            return 0
        fi

        git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
        local cur_head_sha_peek
        cur_head_sha_peek="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"
        if [[ -n "$cur_head_sha_peek" && -n "$prev_head_sha_peek" \
            && "$cur_head_sha_peek" == "$prev_head_sha_peek" ]]; then
            log "tick skip: origin/main sha unchanged since last verdict (${cur_head_sha_peek:0:12})"
            return 0
        fi
    fi

    # Run preflight; get CSV of failing gate names (empty = all passed)
    local failing_csv
    failing_csv="$(_run_preflight)"

    # Derive current state
    local cur_state
    if [[ -z "$failing_csv" ]]; then
        cur_state="GREEN"
    else
        cur_state="RED"
    fi

    # Get head SHA (best-effort; may be empty in mock mode)
    local head_sha=""
    head_sha="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"

    # Compute fingerprint
    local fingerprint
    fingerprint="$(_gate_fingerprint "$failing_csv")"

    # Load previous state
    local prev_state_str; prev_state_str="$(_load_state)"
    local prev_state
    prev_state="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(s.get('state', 'GREEN'))
except Exception:
    print('GREEN')
" 2>/dev/null || printf 'GREEN')"

    # ── GREEN path ─────────────────────────────────────────────────────────────
    if [[ "$cur_state" == "GREEN" ]]; then
        if [[ "$prev_state" == "RED" ]]; then
            # Recovery: close auto-filed gaps
            local recovery_out
            recovery_out="$(_recover_close_gaps "$prev_state_str")"
            local closed_count closed_gaps
            closed_count="$(printf '%s' "$recovery_out" | awk '{print $1}')"
            closed_gaps="$(printf '%s' "$recovery_out" | cut -d' ' -f2-)"
            closed_count="${closed_count:-0}"

            local prev_fp
            prev_fp="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(s.get('fingerprint', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

            # Build gaps_closed JSON array
            local gaps_arr="[]"
            if [[ -n "$closed_gaps" ]]; then
                gaps_arr="$(printf '%s' "$closed_gaps" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
ids = [x for x in raw.split(',') if x and x != 'UNFILED' and not x.startswith('INFRA-DRYRUN-')]
print(json.dumps(ids))
" 2>/dev/null || printf '[]')"
            fi

            emit "main_preflight_recovered" \
                "\"previous_fingerprint\":\"${prev_fp}\",\"head_sha\":\"${head_sha}\",\"gaps_closed\":${gaps_arr},\"closed_count\":${closed_count:-0},\"tick_id\":\"${tick_id}\""
            log "RECOVERY: preflight GREEN after RED (fp=$prev_fp closed=$closed_count)"
        fi

        local _green_ts; _green_ts="$(_ts)"
        # INFRA-2404 BUG-1 fix: also emit reader-expected keys (last_status,
        # last_tick_at, failing_gates). atomic_claim.rs parse_main_health_state
        # reads exactly those three; without them the claim gate was silently
        # inert. Keep the existing state/updated_at/last_tick_id fields for
        # backward compat and richer debugging.
        _save_state "$(STATE=GREEN HEAD_SHA="$head_sha" TS="$_green_ts" \
            TS_SECS="$(date -u +%s)" TICK_ID="$tick_id" \
            python3 <<'PYEOF'
import json, os
print(json.dumps({
    'state': os.environ.get('STATE', 'GREEN'),
    'last_status': os.environ.get('STATE', 'GREEN').lower(),
    'last_tick_at': int(os.environ.get('TS_SECS', '0') or '0'),
    'failing_gates': [],
    'fingerprint': '',
    'filed_fingerprints': [],
    'filed_gaps': [],
    'last_head_sha': os.environ.get('HEAD_SHA', ''),
    'updated_at': os.environ.get('TS', ''),
    'last_tick_id': os.environ.get('TICK_ID', ''),
}))
PYEOF
)"
        log "tick end: GREEN"
        return 0
    fi

    # ── RED path ───────────────────────────────────────────────────────────────
    log "preflight RED (fp=$fingerprint failing=[$failing_csv])"

    # Load filed fingerprints + gaps from prior state
    local prev_filed_fps prev_filed_gaps
    prev_filed_fps="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(','.join(s.get('filed_fingerprints', [])))
except Exception:
    print('')
" 2>/dev/null || true)"

    prev_filed_gaps="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(','.join(s.get('filed_gaps', [])))
except Exception:
    print('')
" 2>/dev/null || true)"

    local new_filed_fps="$prev_filed_fps"
    local new_filed_gaps="$prev_filed_gaps"
    local gap_id=""

    # File gap if this fingerprint hasn't been filed yet (dedup)
    # INFRA-2347 pattern: use case-glob instead of pipefail-racy printf|grep -q
    if [[ ",$prev_filed_fps," != *",$fingerprint,"* ]]; then
        gap_id="$(_file_preflight_gap "$fingerprint" "$failing_csv" "$head_sha" "$tick_id")"
        if [[ -n "$new_filed_fps" ]]; then
            new_filed_fps="${new_filed_fps},${fingerprint}"
        else
            new_filed_fps="$fingerprint"
        fi
        if [[ -n "$new_filed_gaps" ]]; then
            new_filed_gaps="${new_filed_gaps},${gap_id}"
        else
            new_filed_gaps="$gap_id"
        fi
    else
        log "fingerprint $fingerprint already filed — skipping gap reserve (dedup)"
        # Find the gap ID from state for the event emission
        gap_id="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
fp = '$fingerprint'
try:
    s = json.loads(sys.stdin.read() or '{}')
    fps = s.get('filed_fingerprints', [])
    gids = s.get('filed_gaps', [])
    for i, f in enumerate(fps):
        if f == fp and i < len(gids):
            print(gids[i])
            break
    else:
        print('UNFILED')
except Exception:
    print('UNFILED')
" 2>/dev/null || printf 'UNFILED')"
    fi

    # Build failing_gates JSON array for the event
    local gates_arr
    gates_arr="$(printf '%s' "$failing_csv" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
gates = [g for g in raw.split(',') if g]
print(json.dumps(gates))
" 2>/dev/null || printf '[]')"

    emit "main_preflight_red" \
        "\"tick_id\":\"${tick_id}\",\"failing_gates\":${gates_arr},\"fingerprint\":\"${fingerprint}\",\"gap_id\":\"${gap_id:-UNFILED}\",\"head_sha\":\"${head_sha}\""

    # Persist new state
    _save_state "$(NEW_STATE=RED \
        FINGERPRINT="$fingerprint" \
        FILED_FPS="$new_filed_fps" \
        FILED_GAPS="$new_filed_gaps" \
        HEAD_SHA="$head_sha" \
        TICK_ID="$tick_id" \
        UPDATED_AT="$(_ts)" \
        UPDATED_AT_SECS="$(date -u +%s)" \
        FAILING_GATES_CSV="$failing_csv" \
        python3 <<'PYEOF'
import json, os
state = os.environ.get('NEW_STATE', 'RED')
print(json.dumps({
    'state': state,
    'last_status': state.lower(),
    'last_tick_at': int(os.environ.get('UPDATED_AT_SECS', '0') or '0'),
    'failing_gates': [s for s in os.environ.get('FAILING_GATES_CSV', '').split(',') if s],
    'fingerprint': os.environ.get('FINGERPRINT', ''),
    'filed_fingerprints': [s for s in os.environ.get('FILED_FPS', '').split(',') if s],
    'filed_gaps': [s for s in os.environ.get('FILED_GAPS', '').split(',') if s],
    'last_head_sha': os.environ.get('HEAD_SHA', ''),
    'updated_at': os.environ.get('UPDATED_AT', ''),
    'last_tick_id': os.environ.get('TICK_ID', ''),
}))
PYEOF
)"

    log "tick end: RED (gap=$gap_id)"
}

# ── (5) CLI ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    tick) cmd_tick ;;
    --help|-h)
        sed -n '1,65p' "$0"
        exit 0
        ;;
    "")
        # No-arg invocation (launchd default) = one tick.
        cmd_tick
        ;;
    *)
        printf 'Usage: %s tick | --help\n' "$0" >&2
        exit 2
        ;;
esac
