#!/usr/bin/env bash
# board-vitals.sh — RESILIENT-371: the resident board's NON-merge watch.
#
# WHY THIS EXISTS. The board-cycle beat (INFRA-3590) + its escalate organ
# (RESILIENT-373) residentized ONE dimension of the human board's per-loop
# watch — the 30-minute merge SLA — and page the operator on a breach, deduped.
# But the human board checks more than merges every tick: box health (disk),
# an UNRECOVERABLE stall, sustained main-red, and credential/credit needs. On
# CJ those sensors are DARK: the disk-health/disk-pressure/fleet-worker
# watchdogs AND operator-recall (the halt-class credential/cost pager, INFRA-626)
# are Mac-launchd / inactive units that were never made resident (Helsinki
# port-list debt), so NOTHING pages Jeff when / fills, the line dies, or the
# floor loses auth/credit. This lib closes that gap as a deterministic,
# threshold-gated, DEDUPED consolidated watch that the ALREADY-RESIDENT
# board-cycle beat invokes each cycle (rides an is-active+is-enabled timer, no
# new root-owned unit).
#
# THE PAGE BAR (RESILIENT-411 recalibration). Jeff's standing order: DMs are his
# advisor conversation + ONLY pages he must ACT on — zero transient-operational-
# lull pages. A page fires ONLY when it is genuinely HIS problem and nothing
# self-heals it:
#   * disk_full   — the disk path is ≥90% (80-90% self-cleans; no page).
#   * merge_stall — the line is DEAD: 0 merges for the full drought window
#                   (default 3h) AND 0 PRs in flight (BLOCKED/green/pending =
#                   CI-lag the board-cycle beat nurses, NOT a stall) AND the
#                   worker is not producing. This is the ONLY worker-silence-
#                   related page; bare silence NEVER pages — worker lulls
#                   self-heal (INFRA-3832) and an "unrecoverable wedge" is
#                   exactly this 3h-dead-line case. The LLM diagnosis fires here.
#   * main_red    — main CI red sustained ≥30m (not a transient per-PR red).
#   * oauth_expired — ≥3 oauth_token_refresh_failed in-window with NO recovery
#                   since (routine oauth_token_refreshed successes never page).
#   * cost_cap    — a cost_cap_exceeded in-window (sub cap / OpenRouter credit).
#   * almanac_coverage_low — the almanac index's summarized_pct (written by
#                   almanac-vision-keeper.sh's acuity state file, CREDIBLE-300)
#                   is at or below the 95% mission floor. An unreadable/missing
#                   state file means "unknown", not "0%" — it never pages (the
#                   keeper not having run yet is not a coverage regression).
# oauth_expired + cost_cap residentize operator-recall.sh's proven signals+bar.
# The `[board-vitals] tick` proof-of-life line (RESILIENT-410) still prints
# EVERY beat regardless — that is journal observability, NOT a DM.
#
# COMPLEMENTS, does not duplicate:
#   * MERGE SLA (armed green PR past 30m) → board-cycle-escalate.sh owns it.
#   * self-healed conditions (worker cooldown/wedge → INFRA-3832; disk auto-clean
#     when the reactor runs; farmer kicking a silent worker) → their own organs
#     own the heal; this lib pages only the RESIDUE those heals leave unresolved
#     (e.g. a stall still dead 3h later).
#
# CONTRACT:
#   board_vitals_check              → always returns 0 (an escalation organ must
#                                     never break the beat it reports on — same
#                                     invariant as notify-operator.sh /
#                                     board-cycle-escalate.sh).
#
# ENV (all optional):
#   CHUMP_BOARD_VITALS_ENABLED         0 disables (default 1)
#   CHUMP_BOARD_VITALS_DRY_RUN         1 = compute + log the EXACT message it
#                                      WOULD send (kind=board_vitals_page_dryrun)
#                                      and honor dedup, but never DM / never call
#                                      the LLM. Default 0.
#   CHUMP_AMBIENT_LOG                  ambient log to read + emit into
#   CHUMP_BOARD_VITALS_STATE_DIR       dedup state dir (default .chump-locks/board-vitals)
#   CHUMP_BOARD_VITALS_WINDOW_S        dedup window seconds (default 7200 = 2h)
#   CHUMP_BOARD_VITALS_DISK_PATH       filesystem to check (default /)
#   CHUMP_BOARD_VITALS_DISK_PCT        disk page threshold %% (default 90)
#   CHUMP_BOARD_VITALS_DROUGHT_MIN     merge-stall threshold minutes (default 180 = 3h)
#   CHUMP_BOARD_VITALS_WORKER_SILENT_MIN worker not-producing threshold min (default 40)
#   CHUMP_BOARD_VITALS_MAIN_RED_MIN    sustained main-red threshold minutes (default 30)
#   CHUMP_BOARD_VITALS_MAIN_RED_LIVE   0 disables the live per-beat invocation of
#                                      main-health-watchdog.sh (RESILIENT-414);
#                                      default 1. Without this, main_red_detected
#                                      only ever lands via that script's macOS-
#                                      launchd-only daily cron, which is dark on
#                                      non-mac hosts — a real outage never emits.
#   CHUMP_BOARD_VITALS_MAIN_HEALTH_BIN override path to the main-health-watchdog
#                                      script invoked live (default
#                                      scripts/ops/main-health-watchdog.sh;
#                                      test hook).
#   CHUMP_BOARD_VITALS_FLOOR_WINDOW_S  window for oauth/cost signal counts (default 7200 = 2h)
#   CHUMP_BOARD_VITALS_OAUTH_FAIL_THR  oauth_token_refresh_failed count to page (default 3)
#   CHUMP_BOARD_VITALS_ALMANAC_STATE   almanac-vision-keeper.sh acuity state file to read
#                                      summarized_pct from (default
#                                      $CHUMP_VISION_ACUITY_STATE, else
#                                      $HOME/.almanac/vision-acuity.state; test hook)
#   CHUMP_BOARD_VITALS_ALMANAC_FLOOR   summarized_pct floor, page at-or-below (default 95)
#   CHUMP_BOARD_VITALS_ESCALATE_MODEL  model for the merge-stall diagnosis (default sonnet)
#   CHUMP_BOARD_VITALS_ESCALATE        1 enables the LLM diagnosis on merge_stall (default 1)
#
# shellcheck shell=bash

# ── HOST-ASSUMPTION HARDENING (mirrors vital-signs.sh / faculty-collector.sh) ──
# The fleet's service convention hardcodes Environment=HOME=/root even when
# User=jeff, and under systemd PATH is minimal. Resolve the RUN-USER's real
# home + prepend its bins so gh/chump/claude resolve and per-user config reads
# don't silently fail (which would make the board LIE).
_bv_harden_env() {
    local real_home
    real_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
    [[ -z "$real_home" || ! -d "$real_home" ]] && real_home="${HOME:-/root}"
    export HOME="$real_home"
    export PATH="$real_home/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
}

_bv_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd
}

_bv_ambient_log() {
    local root; root="$(_bv_repo_root)"
    printf '%s\n' "${CHUMP_AMBIENT_LOG:-${root}/.chump-locks/ambient.jsonl}"
}

_bv_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_bv_now() { date -u +%s; }

_bv_emit() {  # kind, extra-json (no leading/trailing comma) — never fails
    local log; log="$(_bv_ambient_log)"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    local ts; ts="$(_bv_ts)"
    if [[ -n "${2:-}" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$1" "$2" >> "$log" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"%s"}\n' "$ts" "$1" >> "$log" 2>/dev/null || true
    fi
}

# Epoch of the NEWEST ambient line whose "kind" is one of the pipe-joined
# alternatives in $1. Prints an integer epoch, or 0 if none/parse-fail.
_bv_newest_kind_epoch() {  # kind_regex
    local log; log="$(_bv_ambient_log)"
    [[ -f "$log" ]] || { echo 0; return; }
    KINDS="$1" python3 - "$log" <<'PY' 2>/dev/null || echo 0
import sys, json, os, re
from datetime import datetime, timezone
kinds = set(os.environ.get("KINDS", "").split("|"))
best = 0
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if not any(('"kind":"%s"' % k) in line for k in kinds):
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("kind") not in kinds:
                continue
            try:
                ep = int(datetime.strptime(o.get("ts",""), "%Y-%m-%dT%H:%M:%SZ")
                         .replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                ep = 0
            if ep > best:
                best = ep
except Exception:
    pass
print(best)
PY
}

# Newest board_cycle_report_posted line's (sla_breaches + stalls_classified),
# the count of PRs "in flight" the board cycle already accounted for. Prints an
# integer (0 if no report). Used to distinguish a true merge-drought (nothing in
# flight) from CI-lag (PRs exist, just not merging yet — the beat's job).
_bv_prs_in_flight() {
    local log; log="$(_bv_ambient_log)"
    [[ -f "$log" ]] || { echo 0; return; }
    python3 - "$log" <<'PY' 2>/dev/null || echo 0
import sys, json
best = None
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if '"board_cycle_report_posted"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("kind") == "board_cycle_report_posted":
                best = o  # last wins = newest (append-ordered)
except Exception:
    pass
if best is None:
    print(-1)  # no report at all → caller treats as "unknown", not "zero"
else:
    def _i(k):
        v = best.get(k, 0)
        try: return int(v)
        except Exception: return 0
    print(_i("sla_breaches") + _i("stalls_classified"))
PY
}

# Span in minutes of the CURRENT consecutive run of real-red main_red_detected
# lines at the tail of the stream (0 if the newest such line is not real-red).
# "real red" = status NOT in the benign set {no_runs, green, clean, passing,
# none, ok}.
_bv_main_red_span_min() {
    local log; log="$(_bv_ambient_log)"
    [[ -f "$log" ]] || { echo 0; return; }
    python3 - "$log" <<'PY' 2>/dev/null || echo 0
import sys, json
from datetime import datetime, timezone
BENIGN = {"no_runs","green","clean","passing","none","ok",""}
rows = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if '"main_red_detected"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("kind") != "main_red_detected":
                continue
            try:
                ep = int(datetime.strptime(o.get("ts",""), "%Y-%m-%dT%H:%M:%SZ")
                         .replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                continue
            rows.append((ep, str(o.get("status","")).lower()))
except Exception:
    pass
if not rows:
    print(0); sys.exit(0)
rows.sort()
newest_ep, newest_status = rows[-1]
if newest_status in BENIGN:
    print(0); sys.exit(0)
# walk backwards while still real-red; span = newest - oldest-consecutive-red
start_ep = newest_ep
for ep, st in reversed(rows[:-1]):
    if st in BENIGN:
        break
    start_ep = ep
print(int((newest_ep - start_ep) // 60))
PY
}

# Was a farmer_silent_worker emitted within the last $1 seconds? (the farmer
# confirming a LEASED session went silent — the residue its kick may not fix)
_bv_farmer_silent_recent() {  # within_seconds
    local within="$1" ep now
    ep="$(_bv_newest_kind_epoch "farmer_silent_worker")"
    now="$(_bv_now)"
    [[ "$ep" =~ ^[0-9]+$ ]] || ep=0
    (( ep > 0 && now - ep <= within ))
}

# Count ambient lines of a given kind whose ts is within the last N seconds.
# Used for the floor/credential page conditions (oauth-refresh-failed,
# cost_cap_exceeded), mirroring operator-recall.sh's windowed-count bar.
_bv_count_kind_since() {  # kind, window_seconds  -> integer count
    local log; log="$(_bv_ambient_log)"
    [[ -f "$log" ]] || { echo 0; return; }
    KIND="$1" WINDOW="$2" python3 - "$log" <<'PY' 2>/dev/null || echo 0
import sys, json, os
from datetime import datetime, timezone
kind = os.environ.get("KIND", ""); window = int(os.environ.get("WINDOW", "0"))
now = datetime.now(timezone.utc).timestamp()
n = 0
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if ('"kind":"%s"' % kind) not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("kind") != kind:
                continue
            try:
                ep = datetime.strptime(o.get("ts",""), "%Y-%m-%dT%H:%M:%SZ") \
                     .replace(tzinfo=timezone.utc).timestamp()
            except Exception:
                continue
            if now - ep <= window:
                n += 1
except Exception:
    pass
print(n)
PY
}

# Read the almanac index's summarized_pct off almanac-vision-keeper.sh's
# acuity state file ("<symbol_pct> <summary_pct>", CREDIBLE-300). Prints the
# integer summary_pct on stdout, or nothing if the file is missing/unreadable/
# malformed — callers must treat empty output as "unknown", never as 0, so a
# keeper that simply hasn't run yet cannot masquerade as a coverage collapse.
_bv_almanac_coverage_pct() {
    local state_file
    state_file="${CHUMP_BOARD_VITALS_ALMANAC_STATE:-${CHUMP_VISION_ACUITY_STATE:-$HOME/.almanac/vision-acuity.state}}"
    [[ -f "$state_file" ]] || return 0
    local sym sum
    read -r sym sum _ < "$state_file" 2>/dev/null || return 0
    [[ "$sum" =~ ^[0-9]+$ ]] && printf '%s\n' "$sum"
}

# Resolve notify_operator (source notify-operator.sh; stub if absent so the lib
# stays testable). Sets a module flag so we source once.
_bv_ensure_notify() {
    if declare -F notify_operator >/dev/null 2>&1; then return 0; fi
    local sib; sib="$(dirname "${BASH_SOURCE[0]}")/notify-operator.sh"
    if [[ -f "$sib" ]]; then
        # shellcheck source=notify-operator.sh
        source "$sib"
    else
        notify_operator() { echo "[board-vitals] notify-operator.sh MISSING" >&2; return 0; }
    fi
}

# _bv_maybe_page <signature> <message>  — page via notify_operator
# (kind=board_vitals_alert → registry PAGE) unless the same signature paged
# inside the dedup window. Honors DRY_RUN (logs the exact WOULD-send message,
# still records the signature so dedup is demonstrable). Emits an ambient trail
# either way. Never fails.
_bv_maybe_page() {
    local sig="$1" msg="$2"
    local state_dir window dry
    state_dir="${CHUMP_BOARD_VITALS_STATE_DIR:-$(_bv_repo_root)/.chump-locks/board-vitals}"
    window="${CHUMP_BOARD_VITALS_WINDOW_S:-7200}"
    dry="${CHUMP_BOARD_VITALS_DRY_RUN:-0}"
    mkdir -p "$state_dir" 2>/dev/null || true
    local sigfile; sigfile="$state_dir/$(printf '%s' "$sig" | tr '/ :.' '____').json"

    if [[ -f "$sigfile" ]]; then
        local last now
        last="$(python3 -c "import json;print(json.load(open('$sigfile')).get('last_epoch',0))" 2>/dev/null || echo 0)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        now="$(_bv_now)"
        if (( now - last < window )); then
            _bv_emit "board_vitals_page_deduped" "\"signature\":\"${sig}\""
            return 0
        fi
    fi

    if [[ "$dry" == "1" ]]; then
        _bv_emit "board_vitals_page_dryrun" "\"signature\":\"${sig}\""
        printf '[board-vitals DRY_RUN] WOULD PAGE (sig=%s):\n%s\n' "$sig" "$msg" >&2
    else
        _bv_ensure_notify
        CHUMP_NOTIFY_KIND="board_vitals_alert" notify_operator "$msg" >/dev/null 2>&1
        _bv_emit "board_vitals_page_sent" "\"signature\":\"${sig}\""
    fi

    python3 -c "import json;json.dump({'signature':'$sig','last_epoch':$(_bv_now)}, open('$sigfile','w'))" 2>/dev/null || true
    return 0
}

# Bounded LLM diagnosis of a novel/unclassifiable anomaly. Returns the model's
# one-paragraph diagnosis on stdout (empty on any failure). Never hangs the beat
# (hard timeout). Skipped in DRY_RUN and when disabled.
_bv_llm_diagnose() {  # snapshot_text
    local snapshot="$1" model timeout_s
    model="${CHUMP_BOARD_VITALS_ESCALATE_MODEL:-sonnet}"
    timeout_s="${CHUMP_BOARD_VITALS_ESCALATE_TIMEOUT_S:-120}"
    command -v claude >/dev/null 2>&1 || { echo ""; return 0; }
    local prompt="You are the ChumpOS duty-officer triaging a fleet anomaly the \
deterministic board watch could not classify. Given this vital-signs snapshot, \
in 2-3 sentences: name the single most likely root cause and ONE concrete next \
action a human operator should take. Be terse and specific. Do NOT send any \
message, do NOT call tools, just answer.

SNAPSHOT:
${snapshot}"
    local out
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout "${timeout_s}s" claude -p "$prompt" --model "$model" 2>/dev/null)"
    else
        out="$(claude -p "$prompt" --model "$model" 2>/dev/null)"
    fi
    printf '%s' "$out" | head -c 1200
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
board_vitals_check() {
    [[ "${CHUMP_BOARD_VITALS_ENABLED:-1}" == "0" ]] && return 0
    _bv_harden_env

    local now; now="$(_bv_now)"
    local disk_path disk_pct_thr drought_min silent_min main_red_min
    disk_path="${CHUMP_BOARD_VITALS_DISK_PATH:-/}"
    disk_pct_thr="${CHUMP_BOARD_VITALS_DISK_PCT:-90}"
    drought_min="${CHUMP_BOARD_VITALS_DROUGHT_MIN:-180}"
    silent_min="${CHUMP_BOARD_VITALS_WORKER_SILENT_MIN:-40}"
    main_red_min="${CHUMP_BOARD_VITALS_MAIN_RED_MIN:-30}"

    local incidents=0

    # ── 0 · ALMANAC: summarized_pct guard (CREDIBLE-300/CREDIBLE-1303) ────────
    # summarized_pct is read from almanac-vision-keeper.sh's acuity state, not
    # assumed — an unreadable/missing file is "unknown" and never pages (the
    # keeper not having run yet is not itself a coverage regression).
    local almanac_floor coverage
    almanac_floor="${CHUMP_BOARD_VITALS_ALMANAC_FLOOR:-95}"
    coverage="$(_bv_almanac_coverage_pct)"
    if [[ "$coverage" =~ ^[0-9]+$ ]] && (( coverage <= almanac_floor )); then
        incidents=$((incidents+1))
        _bv_maybe_page "almanac_coverage_low" \
"🔴 **Almanac coverage — summarized_pct guard.** The chump index is ${coverage}% summarized, at or below the ${almanac_floor}% mission floor (CREDIBLE-300). almanac-vision-keeper.sh should be driving summarize to completion each pass — check it's alive and not stuck. (board-vitals.sh, pages once per $(( ${CHUMP_BOARD_VITALS_WINDOW_S:-7200} / 60 ))m)"
    fi

    # ── 1 · BOX: disk ────────────────────────────────────────────────────────
    local disk_pct
    disk_pct="$(df -P "$disk_path" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    [[ "$disk_pct" =~ ^[0-9]+$ ]] || disk_pct=""
    if [[ -n "$disk_pct" ]] && (( disk_pct >= disk_pct_thr )); then
        incidents=$((incidents+1))
        _bv_maybe_page "disk_full" \
"🔴 **Box health — disk critical.** ${disk_path} is ${disk_pct}% full (page threshold ${disk_pct_thr}%). The disk auto-clean reactor is not resident on this node — a human should free space or install the reactor. (board-vitals.sh, pages once per $(( ${CHUMP_BOARD_VITALS_WINDOW_S:-7200} / 60 ))m)"
    fi

    # ── 2 · WORKER liveness (age of the freshest worker-produced signal) ─────
    local worker_ep worker_age_min="" worker_silent=0
    worker_ep="$(_bv_newest_kind_epoch "token_usage_partial|gap_shipped|gap_claimed")"
    [[ "$worker_ep" =~ ^[0-9]+$ ]] || worker_ep=0
    if (( worker_ep > 0 )); then
        worker_age_min=$(( (now - worker_ep) / 60 ))
        (( worker_age_min >= silent_min )) && worker_silent=1
    fi

    # ── 3a · LIVE main-red emit (RESILIENT-414) ───────────────────────────────
    # main-health-watchdog.sh (INFRA-1656) is a macOS-launchd-only daily cron.
    # On a systemd host (e.g. CJ) it never runs at all, so ambient's
    # main_red_detected stream is permanently empty and _bv_main_red_span_min
    # below always reads 0 — a real, sustained red-main outage is invisible to
    # this watch no matter how long it lasts (observed: 44h outage read as
    # incidents=0, never paged). This beat is ALREADY resident every cycle, so
    # fire the watchdog's own detection logic live, right here, instead of
    # depending on a cron that may not exist on this host. Same script, same
    # dedup/gap-filing behavior — just invoked from a live beat, not a dead
    # timer. Bounded + best-effort: never blocks or breaks the beat.
    local main_health_bin
    main_health_bin="${CHUMP_BOARD_VITALS_MAIN_HEALTH_BIN:-$(_bv_repo_root)/scripts/ops/main-health-watchdog.sh}"
    if [[ "${CHUMP_BOARD_VITALS_MAIN_RED_LIVE:-1}" == "1" ]] && [[ -f "$main_health_bin" ]]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 20s bash "$main_health_bin" >/dev/null 2>&1 || true
        else
            bash "$main_health_bin" >/dev/null 2>&1 || true
        fi
    fi

    # ── 3b · MAIN sustained red span (consumed by both section 3c and 4) ──────
    local main_red_span
    main_red_span="$(_bv_main_red_span_min)"
    [[ "$main_red_span" =~ ^[0-9]+$ ]] || main_red_span=0

    # ── 3c · MERGES: an UNRECOVERABLE stall (the human board's real page bar) ─
    # RESILIENT-411 recalibration. This is the ONLY worker-silence-related page.
    # Worker lulls SELF-HEAL (INFRA-3832 cools-down / auto-blocks wedged or
    # timed-out gaps), so a transient silence must NEVER page — an earlier
    # 40-min-silence page fired on a lull that recovered in ~1 min (operational
    # noise, not Jeff's problem). A page fires ONLY when the LINE IS DEAD: no
    # merge to main for the full drought window (default 3h) AND (nothing in
    # flight OR main is currently red) AND the worker is not producing.
    #
    # RESILIENT-414: "nothing in flight" used to be the ONLY escape hatch, but
    # _bv_prs_in_flight folds board-cycle's `stalls_classified` count in — and
    # when main is red, GitHub marks EVERY open PR BLOCKED, which the beat's
    # LLM classifies as a "stall" (a PR it is nursing), so prs_in_flight is
    # never 0 during a red-main outage. That let a fully-jammed queue read as
    # "PRs in flight, not a stall" for the ENTIRE outage — the 44h case. A
    # queue full of PRs that are BLOCKED because main itself is broken is not
    # being nursed toward landing; nothing can land until a human fixes main.
    # So: bypass the in-flight gate whenever main is currently red — the drought
    # + worker-silence conditions still both have to hold, so this only fires
    # once the line has genuinely gone dead for the full window.
    local last_merge_ep merge_age_min="" prs_in_flight
    last_merge_ep="$(git -C "$(_bv_repo_root)" log origin/main -1 --format=%ct 2>/dev/null)"
    [[ "$last_merge_ep" =~ ^[0-9]+$ ]] || last_merge_ep=0
    prs_in_flight="$(_bv_prs_in_flight)"
    [[ "$prs_in_flight" =~ ^-?[0-9]+$ ]] || prs_in_flight=-1
    if (( last_merge_ep > 0 )); then
        merge_age_min=$(( (now - last_merge_ep) / 60 ))
        if (( merge_age_min >= drought_min )) \
           && ( (( prs_in_flight == 0 )) || (( main_red_span >= 1 )) ) \
           && (( worker_silent == 1 )); then
            incidents=$((incidents+1))
            # This IS the hard, possibly-novel case — enrich the page with a
            # bounded LLM diagnosis (the escalation path; skipped in DRY_RUN /
            # when disabled). The LLM now fires ONLY on a real dead line, never
            # on bare silence.
            local diag=""
            if [[ "${CHUMP_BOARD_VITALS_ESCALATE:-1}" == "1" ]] && [[ "${CHUMP_BOARD_VITALS_DRY_RUN:-0}" != "1" ]]; then
                _bv_emit "board_vitals_novel_escalation" \
                    "\"merge_age_min\":\"${merge_age_min}\",\"worker_silent_min\":\"${worker_age_min}\""
                diag="$(_bv_llm_diagnose "merge_age_min=${merge_age_min}; prs_in_flight=0; worker_silent_min=${worker_age_min}; disk_pct=${disk_pct}")"
            fi
            local in_flight_desc="0 PRs in flight"
            if (( prs_in_flight != 0 )) && (( main_red_span >= 1 )); then
                in_flight_desc="${prs_in_flight} PR(s) BLOCKED behind red main (not real progress)"
            fi
            _bv_maybe_page "merge_stall" \
"🔴 **Merge stall — the line is dead.** No merge to main in ${merge_age_min}m (threshold ${drought_min}m), ${in_flight_desc}, and the worker has produced nothing for ${worker_age_min}m. Past the self-heal window — a human needs to look.$( [[ -n "$diag" ]] && printf '\nLLM triage: %s' "$diag" ) (board-vitals.sh)"
        fi
    fi

    # ── 4 · MAIN sustained red ───────────────────────────────────────────────
    # Sustained (default >30m), not a transient per-PR red a hotfix clears.
    # (main_red_span computed live in section 3a/3b above, RESILIENT-414.)
    if (( main_red_span >= main_red_min )); then
        incidents=$((incidents+1))
        _bv_maybe_page "main_red" \
"🔴 **main CI red ${main_red_span}m.** main has been failing for ${main_red_span}m (threshold ${main_red_min}m) — the whole fleet builds on red. A human should look. (board-vitals.sh)"
    fi

    # ── 5 · FLOOR: credential / credit needs — genuinely Jeff's to fix ───────
    # Residentizes operator-recall.sh's (INFRA-626) halt-class credential/cost
    # pages: that organ's timer is NOT active on this node. Same registered
    # signals + thresholds, so this is a residency move, not a new invention.
    local floor_window oauth_fail_thr oauth_fails cost_hits
    floor_window="${CHUMP_BOARD_VITALS_FLOOR_WINDOW_S:-7200}"
    #   (a) OAuth GENUINELY expired: >= N oauth_token_refresh_failed in-window
    #       AND the most recent oauth event is a FAILURE (a later
    #       oauth_token_refreshed success means it recovered → no page). Routine
    #       oauth_token_refreshed successes never page.
    oauth_fail_thr="${CHUMP_BOARD_VITALS_OAUTH_FAIL_THR:-3}"
    oauth_fails="$(_bv_count_kind_since "oauth_token_refresh_failed" "$floor_window")"
    [[ "$oauth_fails" =~ ^[0-9]+$ ]] || oauth_fails=0
    if (( oauth_fails >= oauth_fail_thr )); then
        local fail_ep ok_ep
        fail_ep="$(_bv_newest_kind_epoch "oauth_token_refresh_failed")"
        ok_ep="$(_bv_newest_kind_epoch "oauth_token_refreshed")"
        [[ "$fail_ep" =~ ^[0-9]+$ ]] || fail_ep=0
        [[ "$ok_ep" =~ ^[0-9]+$ ]] || ok_ep=0
        if (( fail_ep > ok_ep )); then
            incidents=$((incidents+1))
            _bv_maybe_page "oauth_expired" \
"🔑 **OAuth expired — the floor can't authenticate.** ${oauth_fails} token-refresh failures in the last $((floor_window/60))m (threshold ${oauth_fail_thr}), no recovery since. Re-auth is Jeff's to do. (board-vitals.sh)"
        fi
    fi
    #   (b) Spend/credit cap hit: any cost_cap_exceeded in-window — sub cap
    #       exhausted / OpenRouter credit needed, the floor can't ship.
    cost_hits="$(_bv_count_kind_since "cost_cap_exceeded" "$floor_window")"
    [[ "$cost_hits" =~ ^[0-9]+$ ]] || cost_hits=0
    if (( cost_hits >= 1 )); then
        incidents=$((incidents+1))
        _bv_maybe_page "cost_cap" \
"💳 **Spend cap hit — the floor can't ship.** ${cost_hits} cost_cap_exceeded event(s) in the last $((floor_window/60))m: sub cap exhausted / credit needed. Topping up is Jeff's to do. (board-vitals.sh)"
    fi

    _bv_emit "board_vitals_tick" \
"\"incidents\":${incidents},\"disk_pct\":\"${disk_pct}\",\"merge_age_min\":\"${merge_age_min}\",\"worker_silent\":${worker_silent},\"main_red_span_min\":${main_red_span}"

    # RESILIENT-410: unconditional proof-of-life to STDOUT — so the resident
    # watch is visible in the board-cycle beat's systemd JOURNAL (where the
    # human board looks with journalctl), not only in .chump-locks/ambient.jsonl.
    # Without this line a healthy watch (incidents=0, emits only to ambient) is
    # indistinguishable from a dead one in the journal. Prints EVERY run.
    printf '[board-vitals] tick — incidents=%s disk=%s%% merge_age=%sm worker_silent=%s main_red_span=%sm%s\n' \
        "${incidents}" "${disk_pct:-?}" "${merge_age_min:-?}" "${worker_silent}" "${main_red_span}" \
        "$( (( incidents > 0 )) && printf ' — PAGED (see board_vitals_page_sent)' || true )"
    return 0
}

# Direct-execution entry point (mirrors notify-operator.sh / board-cycle-escalate.sh).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    board_vitals_check
fi
