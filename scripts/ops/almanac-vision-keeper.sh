#!/usr/bin/env bash
# almanac-vision-keeper.sh — the "eyes" as a standing process (INFRA-3650,
# INFRA-3637, PEER-HEAL-03, MISSION-010).
#
# almanac-liveness-refresh.sh (INFRA-3643/TREK-17) is a single-pass
# check-and-fix; on a systemd node it gets a cadence from
# chump-almanac-liveness.timer (install-almanac-organ.sh, INFRA-3657). This
# script is the OTHER way that cadence gets applied: a plain infinite loop,
# for hosts/paths where the "eyes" run as a raw background bash process
# instead of a supervised systemd unit. That's exactly the shape
# process-organ-heal.sh (INFRA-3650) exists to watch — pgrep -f on this
# script's own path is a reliable, host-independent liveness signal, and if
# this loop dies (unsupervised bash procs don't self-restart) the heal loop
# respawns it from scripts/ops/process-organ-registry.txt.
#
# INFRA-3637 — keep the eyes 20/20 and never drift. Beyond delegating to the
# liveness/refresh probe, each pass now actively KEEPS the chump index sharp:
#
#   1. UN-DRIFT — git fetch origin main && git reset --hard origin/main on the
#      indexed chump checkout *before* indexing, but ONLY if that checkout is
#      clean of tracked changes. A commit-hook refresh on a worker's stray
#      branch had drifted the index off main; grounding the checkout on main
#      first means the index re-indexes main, not whatever branch was left
#      checked out. Untracked files are left untouched (reset --hard does not
#      remove them); a checkout with tracked/staged edits is skipped, never
#      clobbered.
#   2. DRIVE SUMMARIES TO COMPLETION — refresh + embed pick up moved HEADs and
#      new symbols, then `almanac summarize` is driven in a BOUNDED loop until
#      the summarized-file count stops rising. Summaries had been sitting at
#      ~25% of summarizable files because nothing drove summarize to the end,
#      silently degrading doc-level fusion search to keyword.
#   3. ACUITY SIGNAL — every pass emits a vision_acuity ambient event carrying
#      BOTH the symbol (embedding) % and the summary %, plus a regression flag
#      (WARN on stderr) when either number dropped since the last pass. That's
#      the observable that turns "the eyes silently went blurry" into a
#      signal a watcher can act on.
#
# This does NOT convert the keeper to a systemd unit (that is a separate gap);
# it stays a plain loop / one-shot so process-organ-heal.sh can supervise it.
#
# Usage:
#   scripts/ops/almanac-vision-keeper.sh              # loop forever
#   scripts/ops/almanac-vision-keeper.sh --once       # single pass, for tests
#   scripts/ops/almanac-vision-keeper.sh --once --dry-run  # single pass, no mutating index ops
#
# Env:
#   CHUMP_VISION_KEEPER_INTERVAL_S — seconds between passes (default 900 = 15min,
#                                    matches chump-almanac-liveness.timer's cadence)
#   REPO_ROOT / CHUMP_REPO_ROOT    — repo checkout to find the liveness script in
#   CHUMP_ALMANAC_BIN              — path to the almanac binary
#                                    (default $HOME/Projects/almanac/target/release/almanac)
#   CHUMP_ALMANAC_INDEX_REPO       — the indexed chump checkout to un-drift
#                                    (default $HOME/Projects/chump)
#   CHUMP_VISION_KEEPER_DRY_RUN=1  — skip all mutating index ops (reset/refresh/
#                                    embed/summarize); still read coverage + emit
#   CHUMP_VISION_KEEPER_MAX_SUMMARIZE_ROUNDS   — bound on the summarize loop
#                                    (default 40; 0 skips the loop)
#   CHUMP_VISION_KEEPER_SUMMARIZE_ROUND_TIMEOUT_S — per-round timeout (default 1800)
#   CHUMP_VISION_ACUITY_STATE      — file holding last "symbol_pct summary_pct"
#                                    for regression detection
#                                    (default $HOME/.almanac/vision-acuity.state)
#   CHUMP_VISION_KEEPER_MIN_SUMMARY_PCT — summary_pct floor (CREDIBLE-300/
#                                    CREDIBLE-1339); a pass below this floor
#                                    emits vision_acuity_below_floor and
#                                    vision_pass returns non-zero instead of
#                                    silently reporting success. Never allowed
#                                    below 95 (clamped, mirrors CREDIBLE-1210).
#   CHUMP_AMBIENT_LOG              — override ambient.jsonl path
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
LIVENESS_SCRIPT="$REPO_ROOT/scripts/ops/almanac-liveness-refresh.sh"
INTERVAL="${CHUMP_VISION_KEEPER_INTERVAL_S:-900}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

ALMANAC_BIN="${CHUMP_ALMANAC_BIN:-$HOME/Projects/almanac/target/release/almanac}"
INDEX_REPO="${CHUMP_ALMANAC_INDEX_REPO:-$HOME/Projects/chump}"
MAX_SUMMARIZE_ROUNDS="${CHUMP_VISION_KEEPER_MAX_SUMMARIZE_ROUNDS:-40}"
SUMMARIZE_ROUND_TIMEOUT_S="${CHUMP_VISION_KEEPER_SUMMARIZE_ROUND_TIMEOUT_S:-1800}"
STATE_FILE="${CHUMP_VISION_ACUITY_STATE:-$HOME/.almanac/vision-acuity.state}"
MIN_SUMMARY_PCT="${CHUMP_VISION_KEEPER_MIN_SUMMARY_PCT:-95}"
# CREDIBLE-1210-style clamp: the floor must never drop below the 95% mission
# floor (CREDIBLE-300) even via a careless/misconfigured env override.
if awk -v v="$MIN_SUMMARY_PCT" 'BEGIN{exit !(v+0 < 95)}' 2>/dev/null; then
    echo "[almanac-vision-keeper] CHUMP_VISION_KEEPER_MIN_SUMMARY_PCT=$MIN_SUMMARY_PCT is below the 95% mission floor — clamping to 95"
    MIN_SUMMARY_PCT=95
fi

ONCE=0
DRY_RUN="${CHUMP_VISION_KEEPER_DRY_RUN:-0}"
for arg in "$@"; do
    case "$arg" in
        --once)    ONCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
    esac
done

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── coverage parse ──────────────────────────────────────────────────────────
# Sets globals from `almanac coverage`'s headline lines:
#   summaries:  <count>/<total> summarizable files = <pct>%   → SUMMARY_*
#   embeddings: <count>/<total> symbols = <pct>%              → SYMBOL_*
# Returns 0 iff BOTH lines parsed.
SYMBOL_COUNT="" SYMBOL_TOTAL="" SYMBOL_PCT=""
SUMMARY_COUNT="" SUMMARY_TOTAL="" SUMMARY_PCT=""
parse_coverage() {
    SYMBOL_COUNT="" SYMBOL_TOTAL="" SYMBOL_PCT=""
    SUMMARY_COUNT="" SUMMARY_TOTAL="" SUMMARY_PCT=""
    [[ -x "$ALMANAC_BIN" ]] || return 1
    local cov
    cov="$("$ALMANAC_BIN" coverage 2>/dev/null || true)"
    [[ -n "$cov" ]] || return 1
    local sline eline
    sline="$(printf '%s\n' "$cov" | grep -E '^summaries:'  | head -1)"
    eline="$(printf '%s\n' "$cov" | grep -E '^embeddings:' | head -1)"
    if [[ "$sline" =~ summaries:[[:space:]]*([0-9]+)/([0-9]+).*=[[:space:]]*([0-9]+)% ]]; then
        SUMMARY_COUNT="${BASH_REMATCH[1]}"; SUMMARY_TOTAL="${BASH_REMATCH[2]}"; SUMMARY_PCT="${BASH_REMATCH[3]}"
    fi
    if [[ "$eline" =~ embeddings:[[:space:]]*([0-9]+)/([0-9]+).*=[[:space:]]*([0-9]+)% ]]; then
        SYMBOL_COUNT="${BASH_REMATCH[1]}"; SYMBOL_TOTAL="${BASH_REMATCH[2]}"; SYMBOL_PCT="${BASH_REMATCH[3]}"
    fi
    [[ -n "$SUMMARY_PCT" && -n "$SYMBOL_PCT" ]]
}

# ── un-drift: reset the indexed checkout to origin/main (only if clean) ──────
RESET_STATUS="none"
undrift_index_repo() {
    if [[ ! -d "$INDEX_REPO/.git" ]]; then
        echo "[almanac-vision-keeper] index repo is not a git checkout: $INDEX_REPO (skip un-drift)"
        RESET_STATUS="not_git"; return 0
    fi
    # "clean" = no tracked/staged modifications. Untracked files are fine —
    # `git reset --hard` never removes them — and a worker leaving stray logs
    # in the canonical checkout must not block grounding the index on main.
    local dirty
    dirty="$(git -C "$INDEX_REPO" status --porcelain --untracked-files=no 2>/dev/null)"
    if [[ -n "$dirty" ]]; then
        echo "[almanac-vision-keeper] WARN: $INDEX_REPO has tracked changes — skipping git reset to avoid clobbering in-progress work" >&2
        RESET_STATUS="skipped_dirty"; return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[almanac-vision-keeper] (dry-run) would: git -C $INDEX_REPO fetch origin main && git reset --hard origin/main"
        RESET_STATUS="dry_run"; return 0
    fi
    if ! git -C "$INDEX_REPO" fetch origin main --quiet 2>/dev/null; then
        echo "[almanac-vision-keeper] WARN: git fetch origin main failed for $INDEX_REPO (skip un-drift this cycle)" >&2
        RESET_STATUS="fetch_failed"; return 0
    fi
    local cur; cur="$(git -C "$INDEX_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [[ "$cur" != "main" ]]; then
        echo "[almanac-vision-keeper] index repo on '$cur' (drifted) — restoring HEAD to main"
        git -C "$INDEX_REPO" checkout main --quiet 2>/dev/null \
            || git -C "$INDEX_REPO" switch -C main --quiet origin/main 2>/dev/null || true
        RESET_STATUS="drift_restored"
    else
        RESET_STATUS="reset"
    fi
    if git -C "$INDEX_REPO" reset --hard origin/main --quiet 2>/dev/null; then
        echo "[almanac-vision-keeper] index repo grounded on origin/main ($(git -C "$INDEX_REPO" rev-parse --short HEAD 2>/dev/null))"
    else
        echo "[almanac-vision-keeper] WARN: git reset --hard origin/main failed for $INDEX_REPO" >&2
        RESET_STATUS="reset_failed"
    fi
    return 0
}

# ── drive summaries to completion (bounded) ─────────────────────────────────
SUMMARIZE_ROUNDS=0
drive_summaries() {
    SUMMARIZE_ROUNDS=0
    [[ -x "$ALMANAC_BIN" ]] || return 0
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[almanac-vision-keeper] (dry-run) would drive 'almanac summarize chump' until coverage plateaus"
        return 0
    fi
    if (( MAX_SUMMARIZE_ROUNDS <= 0 )); then
        echo "[almanac-vision-keeper] summarize loop disabled (MAX_SUMMARIZE_ROUNDS=$MAX_SUMMARIZE_ROUNDS)"
        return 0
    fi
    local prev=-1 cur
    while (( SUMMARIZE_ROUNDS < MAX_SUMMARIZE_ROUNDS )); do
        # Measure the summarized-file count before running another pass.
        if parse_coverage; then cur="$SUMMARY_COUNT"; else cur=""; fi
        if [[ -z "$cur" ]]; then
            echo "[almanac-vision-keeper] summarize loop: coverage unreadable — stopping" >&2
            break
        fi
        if (( cur <= prev )); then
            # A full summarize pass added nothing new → coverage has plateaued.
            echo "[almanac-vision-keeper] summaries plateaued at $cur files after $SUMMARIZE_ROUNDS round(s)"
            break
        fi
        prev="$cur"
        SUMMARIZE_ROUNDS=$((SUMMARIZE_ROUNDS + 1))
        timeout "$SUMMARIZE_ROUND_TIMEOUT_S" "$ALMANAC_BIN" summarize chump >/dev/null 2>&1 || true
    done
    if (( SUMMARIZE_ROUNDS >= MAX_SUMMARIZE_ROUNDS )); then
        echo "[almanac-vision-keeper] summarize loop hit round cap ($MAX_SUMMARIZE_ROUNDS) — will continue next cycle" >&2
    fi
}

# ── one vision pass ─────────────────────────────────────────────────────────
vision_pass() {
    if [[ ! -x "$ALMANAC_BIN" ]]; then
        echo "[almanac-vision-keeper] almanac CLI absent at $ALMANAC_BIN — skipping vision pass (no local index on this node)"
        # scanner-anchor: "kind":"vision_acuity_skip"  (INFRA-3637; emitted when a
        # pass cannot produce an acuity reading — the almanac binary is absent on
        # this node, or `almanac coverage` was unparseable — so a dark node is
        # itself observable instead of silently emitting nothing. Registered in
        # docs/observability/EVENT_REGISTRY.yaml.)
        emit vision_acuity_skip "\"reason\":\"almanac_bin_absent\",\"bin\":\"$ALMANAC_BIN\",\"dry_run\":$DRY_RUN"
        return 0
    fi

    # 1. un-drift the indexed checkout, then re-index it onto main.
    undrift_index_repo
    if [[ "$DRY_RUN" != "1" ]]; then
        "$ALMANAC_BIN" refresh chump >/dev/null 2>&1 || true
        "$ALMANAC_BIN" embed >/dev/null 2>&1 || true
    else
        echo "[almanac-vision-keeper] (dry-run) would: almanac refresh chump && almanac embed"
    fi

    # 2. drive summaries to completion (bounded).
    drive_summaries

    # 3. acuity signal.
    if ! parse_coverage; then
        echo "[almanac-vision-keeper] WARN: coverage report unparseable — emitting skip" >&2
        emit vision_acuity_skip "\"reason\":\"coverage_unparseable\",\"dry_run\":$DRY_RUN"
        return 0
    fi

    # Regression detection against last recorded acuity.
    local prev_sym="" prev_sum="" regressed="none"
    if [[ -f "$STATE_FILE" ]]; then read -r prev_sym prev_sum _ < "$STATE_FILE" 2>/dev/null || true; fi
    if [[ -n "$prev_sym" && "$SYMBOL_PCT" =~ ^[0-9]+$ && "$prev_sym" =~ ^[0-9]+$ ]] && (( SYMBOL_PCT < prev_sym )); then
        regressed="symbol"
    fi
    if [[ -n "$prev_sum" && "$SUMMARY_PCT" =~ ^[0-9]+$ && "$prev_sum" =~ ^[0-9]+$ ]] && (( SUMMARY_PCT < prev_sum )); then
        if [[ "$regressed" == "symbol" ]]; then regressed="both"; else regressed="summary"; fi
    fi
    if [[ "$regressed" != "none" ]]; then
        echo "[almanac-vision-keeper] WARN: vision acuity REGRESSED ($regressed) — symbol ${prev_sym:-?}%->${SYMBOL_PCT}%, summary ${prev_sum:-?}%->${SUMMARY_PCT}%" >&2
    fi

    # Persist current acuity for the next pass (skip in dry-run so smoke runs
    # never move the real regression baseline).
    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
        printf '%s %s\n' "$SYMBOL_PCT" "$SUMMARY_PCT" > "$STATE_FILE" 2>/dev/null || true
    fi

    echo "[almanac-vision-keeper] acuity: symbol ${SYMBOL_PCT}% (${SYMBOL_COUNT}/${SYMBOL_TOTAL})  summary ${SUMMARY_PCT}% (${SUMMARY_COUNT}/${SUMMARY_TOTAL})  reset=$RESET_STATUS  summarize_rounds=$SUMMARIZE_ROUNDS  regressed=$regressed  dry_run=$DRY_RUN"
    # scanner-anchor: "kind":"vision_acuity"  (INFRA-3637; emitted every pass —
    # carries BOTH the symbol/embedding % and the summary % of the chump index,
    # plus regressed=symbol|summary|both|none so a drop in either leg pages the
    # same way any organ-degradation signal does. Registered in
    # docs/observability/EVENT_REGISTRY.yaml.)
    emit vision_acuity "\"symbol_pct\":$SYMBOL_PCT,\"summary_pct\":$SUMMARY_PCT,\"symbol_count\":$SYMBOL_COUNT,\"symbol_total\":$SYMBOL_TOTAL,\"summary_count\":$SUMMARY_COUNT,\"summary_total\":$SUMMARY_TOTAL,\"summarize_rounds\":$SUMMARIZE_ROUNDS,\"reset\":\"$RESET_STATUS\",\"regressed\":\"$regressed\",\"dry_run\":$DRY_RUN"

    # CREDIBLE-1339 (CREDIBLE-300 slice): the >95% summarized_pct floor must be
    # enforceable by this code path itself, not just visible to a downstream
    # watcher (board-vitals.sh / almanac-summarize-watchdog.sh already guard
    # their own read of the acuity state; this guards the writer). A pass that
    # lands below the floor emits vision_acuity_below_floor and returns
    # non-zero so `vision_pass || ...` in the main loop surfaces the failure
    # instead of it looking identical to a healthy pass.
    if [[ "$SUMMARY_PCT" =~ ^[0-9]+$ ]] && (( SUMMARY_PCT < MIN_SUMMARY_PCT )); then
        echo "[almanac-vision-keeper] WARN: summary coverage ${SUMMARY_PCT}% is below the ${MIN_SUMMARY_PCT}% mission floor (CREDIBLE-300)" >&2
        # scanner-anchor: "kind":"vision_acuity_below_floor"  (CREDIBLE-1339;
        # fires whenever a pass's summary_pct lands below the mission floor —
        # the guard's "notify" half; the non-zero return is the "error" half.)
        emit vision_acuity_below_floor "\"summary_pct\":$SUMMARY_PCT,\"floor\":$MIN_SUMMARY_PCT,\"dry_run\":$DRY_RUN"
        return 1
    fi
}

# ── main loop ───────────────────────────────────────────────────────────────
while true; do
    if [[ -x "$LIVENESS_SCRIPT" ]]; then
        "$LIVENESS_SCRIPT" || echo "[almanac-vision-keeper] liveness-refresh exited non-zero (non-fatal, retrying next cycle)" >&2
    else
        echo "[almanac-vision-keeper] WARN: liveness script missing/not executable: $LIVENESS_SCRIPT" >&2
    fi

    vision_pass || echo "[almanac-vision-keeper] vision pass exited non-zero (non-fatal, retrying next cycle)" >&2

    [[ "$ONCE" == "1" ]] && break
    sleep "$INTERVAL"
done
