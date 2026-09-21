#!/usr/bin/env bash
# operator-recall.sh — INFRA-626: detect halt-class conditions and page the operator.
#
# Checks four conditions by scanning ambient.jsonl, then:
#   1. Emits kind=operator_recall to ambient.jsonl (idempotent — cooldown-gated)
#   2. POSTs a JSON body to CHUMP_OPERATOR_RECALL_URL if set
#
# Conditions:
#   (a) AUTH_DEAD           — ≥ CHUMP_AUTH_STORM_RECALL_THRESHOLD fleet_auth_storm
#                             events with action=worker_exit in the last
#                             CHUMP_AUTH_STORM_WINDOW_SECS (default 5, 3600),
#                             OR ≥ CHUMP_OAUTH_FAILURE_RECALL_THRESHOLD (default 3)
#                             oauth_token_refresh_failed events, OR
#                             ≥ CHUMP_AUTH_STALE_RECALL_THRESHOLD (default 2)
#                             auth_token_stale events (RESILIENT-056: emitted by
#                             infra-watcher-loop.sh check-oauth-freshness), all
#                             within the same CHUMP_AUTH_STORM_WINDOW_SECS window —
#                             widened past the single fleet_auth_storm+worker_exit
#                             signal so a wedged refresher pages too, OR
#                             ≥ CHUMP_SUB_AUTH_DEAD_RECALL_THRESHOLD (default 1)
#                             worker_sub_auth_dead events (RESILIENT-1443:
#                             worker.sh's CHUMP_AUTH_MODE=oauth precheck found
#                             the claude CLI OAuth session logged out)
#   (b) COST_CAP            — cost_cap_exceeded event in ambient.jsonl within 2 h,
#                             OR `chump cost-watch --hard-cap` exits non-zero
#   (c) CI_BROKEN           — ≥ CHUMP_CI_BROKEN_THRESHOLD pr_stuck events with
#                             reason containing "ci" in CHUMP_CI_BROKEN_WINDOW_SECS
#                             (default 3, 7200)
#   (d) QUEUE_STARVE        — fleet_queue_depth event with pickable_count=0 AND no
#                             gap_reserved event in CHUMP_QUEUE_STARVE_SECS (default 86400)
#   (e) QUEUE_SATURATED     — >= CHUMP_RUNNER_QUEUE_MIN_COUNT (default 3) queued
#                             workflow_runs older than CHUMP_RUNNER_QUEUE_THRESHOLD_S
#                             (default 300) exist. Jobs on a sample of those runs are
#                             fetched (gh api .../actions/runs/<id>/jobs) and classified
#                             by runs-on label into two subclasses (META-101):
#                               RUNNERS_GHOSTED           — jobs target self-hosted
#                                 labels AND >=1 self-hosted runner is online+idle
#                                 (matching label, not picking up work)
#                               QUEUE_SATURATED_GH_HOSTED — jobs target GitHub-hosted
#                                 labels (ubuntu-*/macos*/windows*) — GH-hosted runner
#                                 concurrency quota is exhausted; restarting anything
#                                 does not help
#                             Guard: CHUMP_RUNNER_GHOST_ONLINE_DETECT (default 1, set to 0 to disable)
#   (f) DISK_CRITICAL       — ≥1 disk_critical event in last
#                             CHUMP_DISK_CRITICAL_WINDOW_SECS (default 600) AND
#                             current free% < CHUMP_DISK_CRITICAL_PCT (default 5).
#                             Fires when the INFRA-2304 reactor's escalated reap
#                             could not recover sufficient headroom — operator
#                             must intervene (manual reap, fleet pause, etc.)
#   (g) PTY_EXHAUSTION      — invoked directly (via --condition PTY_EXHAUSTION)
#                             by scripts/coord/infra-watcher-loop.sh check-ptys
#                             (RESILIENT-092) when pty allocation crosses
#                             CHUMP_INFRA_WATCHER_PTY_THRESHOLD (default 80%) of
#                             kern.tty.ptmx_max (macOS) or /proc/sys/kernel/pty/max
#                             (Linux) — pages BEFORE forkpty fails machine-wide,
#                             not auto-detected by this script's scan loop.
#   (h) AUTONOMY_HALT       — RESILIENT-321: the kill switch (~/.chump/AUTONOMY_LEVEL)
#                             is currently 0 AND the oldest fleet_stopped_kill_switch
#                             event in the last CHUMP_AUTONOMY_HALT_WINDOW_SECS
#                             (default 86400) is older than
#                             CHUMP_AUTONOMY_HALT_MIN_SECS (default 1800) — i.e. the
#                             fleet has been silently halted for 30+ minutes. Every
#                             other halt condition above self-reports via a loud
#                             ambient event the moment it fires; AUTONOMY_LEVEL=0 did
#                             not — worker.sh/bot-merge.sh log+skip quietly every
#                             cycle, so a refresh/provision (or any other automated
#                             path) clobbering the kill switch to 0 went unnoticed
#                             for 6h on 2026-08-14. This closes that silent-halt gap.
#   (i) WORKER_HALT         — RESILIENT-324: invoked directly (via --condition
#                             WORKER_HALT) by scripts/ops/organ-watchdog.sh when
#                             every configured chump-worker@<id>.service (the
#                             gap-starter fleet workers) has sat inactive for >=
#                             CHUMP_WORKER_HALT_MIN_SECS (default 1800), tracked
#                             independent of AUTONOMY_LEVEL — a provision/refresh
#                             path can SIGTERM-stop + disable the worker UNITS
#                             directly without ever touching the kill switch, which
#                             is exactly how the fleet sat with zero active workers
#                             for 2.5h with no alarm on 2026-08-14 (AUTONOMY_HALT
#                             above never fired because AUTONOMY_LEVEL stayed
#                             non-zero the whole time).
#   (j) ZERO_SHIP_ACTIVE    — RESILIENT-575: >= CHUMP_ZERO_SHIP_MIN_CYCLES
#                             (default 3) worker_exit events (workers are
#                             actively cycling — NOT idle/halted, which (h)/(i)
#                             already cover) but 0 gap_shipped events, both
#                             within CHUMP_ZERO_SHIP_WINDOW_SECS (default 3600).
#                             This is the "board" signal from the 2026-09-01
#                             incident: workers showed 'active' the whole time
#                             while a sub-cap outage silently cooled-down+
#                             blocked every gap it touched — zero real PRs for
#                             9h, unpaged, because every existing condition
#                             checks for idle/dead workers, not busy-but-fruitless
#                             ones.
#
# Usage:
#   operator-recall.sh                  # auto-detect all conditions; exit 0
#   operator-recall.sh --check-only     # exit 1 if any halt condition is active
#   operator-recall.sh --condition NAME --reason "..." # emit + notify directly
#
# Env:
#   CHUMP_OPERATOR_RECALL_URL              webhook endpoint (curl POST JSON)
#   CHUMP_OPERATOR_RECALL_COOLDOWN_SECS    suppress duplicate recalls (default 3600)
#   CHUMP_AUTH_STORM_RECALL_THRESHOLD      default 5
#   CHUMP_AUTH_STORM_WINDOW_SECS           default 3600
#   CHUMP_OAUTH_FAILURE_RECALL_THRESHOLD   default 3 (oauth_token_refresh_failed count)
#   CHUMP_AUTH_STALE_RECALL_THRESHOLD      default 2 (auth_token_stale count)
#   CHUMP_SUB_AUTH_DEAD_RECALL_THRESHOLD   default 1 (worker_sub_auth_dead count, RESILIENT-1443)
#   CHUMP_CI_BROKEN_THRESHOLD              default 3
#   CHUMP_CI_BROKEN_WINDOW_SECS            default 7200
#   CHUMP_QUEUE_STARVE_SECS                default 86400
#   CHUMP_RUNNER_QUEUE_THRESHOLD_S         seconds a run stays queued before QUEUE_SATURATED fires (default 300)
#   CHUMP_RUNNER_QUEUE_MIN_COUNT           min queued+stale runs required before classifying (default 3)
#   CHUMP_RUNNER_GHOST_ONLINE_DETECT       set to 0 to disable QUEUE_SATURATED detection (default 1)
#   CHUMP_DISK_CRITICAL_WINDOW_SECS        recency window for disk_critical events (default 600)
#   CHUMP_DISK_CRITICAL_PCT                free% threshold below which to page (default 5)
#   CHUMP_ZERO_SHIP_WINDOW_SECS            default 3600 (RESILIENT-575)
#   CHUMP_ZERO_SHIP_MIN_CYCLES             default 3 (RESILIENT-575)
#   CHUMP_AMBIENT_LOG                      path to ambient.jsonl

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_lock_dir="$(dirname "$_amb")"

_recall_url="${CHUMP_OPERATOR_RECALL_URL:-}"
_cooldown="${CHUMP_OPERATOR_RECALL_COOLDOWN_SECS:-3600}"
_auth_threshold="${CHUMP_AUTH_STORM_RECALL_THRESHOLD:-5}"
_auth_window="${CHUMP_AUTH_STORM_WINDOW_SECS:-3600}"
_oauth_fail_threshold="${CHUMP_OAUTH_FAILURE_RECALL_THRESHOLD:-3}"
_auth_stale_threshold="${CHUMP_AUTH_STALE_RECALL_THRESHOLD:-2}"
_sub_auth_dead_threshold="${CHUMP_SUB_AUTH_DEAD_RECALL_THRESHOLD:-1}"
_ci_threshold="${CHUMP_CI_BROKEN_THRESHOLD:-3}"
_ci_window="${CHUMP_CI_BROKEN_WINDOW_SECS:-7200}"
_queue_starve="${CHUMP_QUEUE_STARVE_SECS:-86400}"
_runner_queue_threshold="${CHUMP_RUNNER_QUEUE_THRESHOLD_S:-300}"
_runner_queue_min_count="${CHUMP_RUNNER_QUEUE_MIN_COUNT:-3}"
_runner_ghost_detect="${CHUMP_RUNNER_GHOST_ONLINE_DETECT:-1}"
_disk_critical_window="${CHUMP_DISK_CRITICAL_WINDOW_SECS:-600}"
_disk_critical_pct="${CHUMP_DISK_CRITICAL_PCT:-5}"
_zero_ship_window="${CHUMP_ZERO_SHIP_WINDOW_SECS:-3600}"
_zero_ship_min_cycles="${CHUMP_ZERO_SHIP_MIN_CYCLES:-3}"
_autonomy_halt_min_secs="${CHUMP_AUTONOMY_HALT_MIN_SECS:-1800}"
_autonomy_halt_window="${CHUMP_AUTONOMY_HALT_WINDOW_SECS:-86400}"

_check_only=0
_forced_condition=""
_forced_reason=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) _check_only=1; shift ;;
        --condition)  _forced_condition="$2"; shift 2 ;;
        --reason)     _forced_reason="$2"; shift 2 ;;
        *) echo "Usage: $0 [--check-only] [--condition NAME --reason TEXT]" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

_now_epoch() { date +%s; }

_emit_recall() {
    # $1=condition $2=reason $3=optional extra JSON fields, e.g.
    #   ,"class":"X","workflow_run_ids":[1,2],"remediation":"..."
    local condition="$1" reason="$2" extra_fields="${3:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    mkdir -p "$_lock_dir" 2>/dev/null || true

    # Cooldown: skip if we already emitted this condition recently.
    local cooldown_file="$_lock_dir/operator-recall-${condition}.ts"
    if [[ -f "$cooldown_file" ]]; then
        local last_ts; last_ts="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
        local age=$(( $(_now_epoch) - last_ts ))
        if (( age < _cooldown )); then
            return 0
        fi
    fi

    # Emit to ambient.jsonl.
    local body
    body="$(printf '{"ts":"%s","kind":"operator_recall","condition":"%s","reason":"%s"%s}' \
        "$ts" "$condition" "$reason" "$extra_fields")"
    printf '%s\n' "$body" >> "$_amb" 2>/dev/null || true

    # Update cooldown timestamp.
    _now_epoch > "$cooldown_file" 2>/dev/null || true

    echo "[operator-recall] RECALL condition=${condition} reason=${reason}"

    # Webhook notification.
    if [[ -n "$_recall_url" ]]; then
        local payload
        payload="$(printf '{"ts":"%s","condition":"%s","reason":"%s","fleet":"%s"}' \
            "$ts" "$condition" "$reason" "${FLEET_SESSION:-chump-fleet}")"
        curl -sf -X POST -H "Content-Type: application/json" \
            -d "$payload" "$_recall_url" >/dev/null 2>&1 || \
            echo "[operator-recall] WARNING: webhook POST failed (url=${_recall_url})" >&2
    fi
}

# ── (e) QUEUE_SATURATED detection (META-101) ──────────────────────────────────
#
# Two subclasses, distinguished by classifying the runs-on labels of jobs on a
# sample of stale-queued runs (via gh api .../actions/runs/<id>/jobs):
#   RUNNERS_GHOSTED           — jobs target self-hosted labels AND a self-hosted
#                               runner matching those labels is online+idle
#                               (remediation: restart the runner)
#   QUEUE_SATURATED_GH_HOSTED — jobs target GitHub-hosted labels (ubuntu-*,
#                               macos*, windows*); GH-hosted concurrency quota
#                               is exhausted (remediation: NOT a restart — reduce
#                               concurrent triggers / raise quota / migrate to
#                               self-hosted)

_detect_queue_saturated() {
    local cache_db="$REPO_ROOT/.chump/github_cache.db"
    local now_epoch; now_epoch="$(_now_epoch)"
    local stale_threshold="$_runner_queue_threshold"
    local min_count="$_runner_queue_min_count"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local _gh_repo="${GITHUB_REPOSITORY:-repairman29/chump}"

    # --- Step 1: find queued workflow_runs older than threshold (id + age) ---
    local queued_count=0
    local oldest_age_s=0
    local run_ids=""

    if [[ -f "$cache_db" ]]; then
        # Read from cache: workflow_run_cache table (INFRA-1872 shape)
        local cache_result
        cache_result=$(python3 - "$cache_db" "$now_epoch" "$stale_threshold" <<'PYEOF' 2>/dev/null
import sys, sqlite3
from datetime import datetime, timezone

db_path, now_epoch, threshold = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    tables = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
    count = 0
    oldest_age = 0
    ids = []
    if "workflow_run_cache" in tables:
        cols = [r[1] for r in cur.execute("PRAGMA table_info(workflow_run_cache)").fetchall()]
        id_col = "run_id" if "run_id" in cols else "id"
        rows = cur.execute(
            f"SELECT {id_col}, created_at FROM workflow_run_cache WHERE status='queued'"
        ).fetchall()
        for (run_id, created_at) in rows:
            try:
                created_epoch = int(datetime.fromisoformat(
                    created_at.rstrip("Z")).replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                continue
            age = now_epoch - created_epoch
            if age >= threshold:
                count += 1
                ids.append(str(run_id))
                if age > oldest_age:
                    oldest_age = age
    print(f"{count} {oldest_age} {','.join(ids)}")
    conn.close()
except Exception:
    print("0 0 ")
PYEOF
        )
        queued_count=$(echo "$cache_result" | awk '{print $1}')
        oldest_age_s=$(echo "$cache_result" | awk '{print $2}')
        run_ids=$(echo "$cache_result" | awk '{print $3}')
    fi

    queued_count="${queued_count//[[:space:]]/}"
    # Not enough stale queued runs to classify — nothing to do (AC2: M=3 default).
    if [[ -z "$queued_count" ]] || (( queued_count < min_count )); then
        return 0
    fi

    # --- Step 2: check for online-but-idle self-hosted runners via GitHub API ---
    local idle_runners=0
    local runners_json
    runners_json=$(gh api "repos/${_gh_repo}/actions/runners" --paginate 2>/dev/null || echo "")

    if [[ -n "$runners_json" ]]; then
        idle_runners=$(python3 - "$runners_json" <<'PYEOF' 2>/dev/null
import sys, json
try:
    data = json.loads(sys.argv[1])
    runners = data if isinstance(data, list) else data.get("runners", [])
    count = sum(
        1 for r in runners
        if r.get("status") == "online" and not r.get("busy", True)
        and any(l.get("name") == "self-hosted" for l in r.get("labels", []))
    )
    print(count)
except Exception:
    print(0)
PYEOF
        )
    fi
    idle_runners="${idle_runners//[[:space:]]/}"
    [[ -z "$idle_runners" ]] && idle_runners=0

    # --- Step 3: sample jobs for up to 5 stale-queued runs, classify by runs-on label ---
    local sample_ids; sample_ids=$(echo "$run_ids" | tr ',' '\n' | grep -v '^$' | head -5)
    local jobs_json_all="["
    local first=1
    for rid in $sample_ids; do
        local jobs_json
        jobs_json=$(gh api "repos/${_gh_repo}/actions/runs/${rid}/jobs" 2>/dev/null || echo "")
        [[ -z "$jobs_json" ]] && continue
        if (( first )); then first=0; else jobs_json_all+=","; fi
        jobs_json_all+="{\"run_id\":${rid},\"jobs\":${jobs_json}}"
    done
    jobs_json_all+="]"

    # classify: prints "<self_hosted|gh_hosted|none> <comma-labels> <comma-run-ids>"
    local classification
    classification=$(python3 - "$jobs_json_all" <<'PYEOF' 2>/dev/null
import sys, json
GH_HOSTED_PREFIXES = ("ubuntu-", "macos", "windows-")
try:
    entries = json.loads(sys.argv[1])
except Exception:
    entries = []

self_hosted_runs, self_hosted_labels = [], set()
gh_hosted_runs, gh_hosted_labels = [], set()

for entry in entries:
    run_id = entry.get("run_id")
    jobs = entry.get("jobs", {})
    job_list = jobs.get("jobs", []) if isinstance(jobs, dict) else []
    for job in job_list:
        if job.get("status") != "queued":
            continue
        labels = job.get("labels", []) or []
        is_self_hosted = "self-hosted" in labels
        is_gh_hosted = any(
            any(str(l).lower().startswith(p) for p in GH_HOSTED_PREFIXES) or str(l).lower() in ("ubuntu-latest", "macos-latest", "windows-latest")
            for l in labels
        )
        if is_self_hosted:
            self_hosted_runs.append(str(run_id))
            self_hosted_labels.update(str(l) for l in labels)
        elif is_gh_hosted:
            gh_hosted_runs.append(str(run_id))
            gh_hosted_labels.update(str(l) for l in labels)

if self_hosted_runs:
    print(f"self_hosted {','.join(sorted(self_hosted_labels))} {','.join(sorted(set(self_hosted_runs)))}")
elif gh_hosted_runs:
    print(f"gh_hosted {','.join(sorted(gh_hosted_labels))} {','.join(sorted(set(gh_hosted_runs)))}")
else:
    print("none  ")
PYEOF
    )

    local _class _labels _ids
    _class=$(echo "$classification" | awk '{print $1}')
    _labels=$(echo "$classification" | awk '{print $2}')
    _ids=$(echo "$classification" | awk '{print $3}')

    if [[ "$_class" == "self_hosted" ]] && (( idle_runners >= 1 )); then
        # RUNNERS_GHOSTED: self-hosted-labeled jobs queued while a matching
        # self-hosted runner sits online+idle — restart is the fix.
        local detect_body
        detect_body="$(printf '{"ts":"%s","kind":"runner_ghost_online_detected","queued_count":%d,"oldest_age_s":%d,"idle_runners":%d,"threshold_s":%d}' \
            "$ts" "$queued_count" "$oldest_age_s" "$idle_runners" "$stale_threshold")"
        printf '%s\n' "$detect_body" >> "$_amb" 2>/dev/null || true

        local _reason="${queued_count} workflow run(s) queued for >${stale_threshold}s (oldest=${oldest_age_s}s) with ${idle_runners} self-hosted runner(s) online-but-idle and queued jobs targeting self-hosted labels [${_labels}]; runners are ghost-online"
        local _extra
        _extra="$(printf ',"class":"RUNNERS_GHOSTED","workflow_run_ids":[%s],"runs_on_labels":[%s],"remediation":"launchctl restart the self-hosted runner service"' \
            "$_ids" \
            "$(echo "$_labels" | sed -E 's/([^,]+)/"\1"/g')")"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=RUNNERS_GHOSTED: $_reason"
            _any_halt=1
        else
            _emit_recall "RUNNERS_GHOSTED" "$_reason" "$_extra"
        fi
    elif [[ "$_class" == "gh_hosted" ]]; then
        # QUEUE_SATURATED_GH_HOSTED: queued jobs target GH-hosted labels —
        # this is a quota-exhaustion condition, NOT a runner-health condition.
        # Restarting anything does not help.
        local _reason="${queued_count} workflow run(s) queued for >${stale_threshold}s (oldest=${oldest_age_s}s); sampled queued jobs target GitHub-hosted runs-on labels [${_labels}] (run_ids=[${_ids}]); GH-hosted runner concurrency quota is likely exhausted"
        local _extra
        _extra="$(printf ',"class":"QUEUE_SATURATED_GH_HOSTED","workflow_run_ids":[%s],"runs_on_labels":[%s],"remediation":"no-restart-fix; reduce concurrent workflow triggers OR increase GH-hosted concurrency quota OR migrate affected jobs to self-hosted"' \
            "$_ids" \
            "$(echo "$_labels" | sed -E 's/([^,]+)/"\1"/g')")"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=QUEUE_SATURATED_GH_HOSTED: $_reason"
            _any_halt=1
        else
            _emit_recall "QUEUE_SATURATED_GH_HOSTED" "$_reason" "$_extra"
        fi
    elif (( idle_runners >= 1 )); then
        # Fallback: couldn't classify jobs (API miss) but idle self-hosted
        # runners + stale queue is still evidence of the ghosted pattern.
        local _reason="${queued_count} workflow run(s) queued for >${stale_threshold}s (oldest=${oldest_age_s}s) with ${idle_runners} self-hosted runner(s) online-but-idle (job classification unavailable); runners may be ghost-online"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=RUNNERS_GHOSTED: $_reason"
            _any_halt=1
        else
            _emit_recall "RUNNERS_GHOSTED" "$_reason" ',"class":"RUNNERS_GHOSTED","remediation":"launchctl restart the self-hosted runner service"'
        fi
    fi
}

# ── Forced mode (called by scripts or tests) ──────────────────────────────────

if [[ -n "$_forced_condition" ]]; then
    _emit_recall "$_forced_condition" "${_forced_reason:-manual trigger}"
    exit 0
fi

# ── Condition detection ───────────────────────────────────────────────────────

_any_halt=0

_scan_ambient() {
    # Returns lines from ambient.jsonl within the last N seconds matching a pattern.
    local window_secs="$1"
    local pattern="$2"
    local since=$(( $(_now_epoch) - window_secs ))

    if [[ ! -f "$_amb" ]]; then return; fi

    python3 - "$_amb" "$since" "$pattern" <<'PYEOF'
import sys, json, re
path, since, pattern = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rx = re.compile(pattern)
from datetime import datetime, timezone

def epoch_from_ts(ts):
    try:
        ts = ts.rstrip("Z")
        return int(datetime.fromisoformat(ts).replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return 0

with open(path, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ts = obj.get("ts", "")
        if epoch_from_ts(ts) < since:
            continue
        if rx.search(line):
            print(line)
PYEOF
}

# (a) AUTH_DEAD — fleet_auth_storm with action=worker_exit, OR repeated
# oauth_token_refresh_failed / auth_token_stale (RESILIENT-056: widened past
# the original narrow signal so a wedged OAuth refresher pages the operator
# too, not only a worker-exit storm).
_auth_exits=$(_scan_ambient "$_auth_window" '"kind":"fleet_auth_storm"' \
    | grep -c '"action":"worker_exit"' 2>/dev/null || true)
_auth_exits="${_auth_exits//[[:space:]]/}"

_oauth_fail_hits=$(_scan_ambient "$_auth_window" '"kind":"oauth_token_refresh_failed"' | wc -l 2>/dev/null || echo 0)
_oauth_fail_hits="${_oauth_fail_hits//[[:space:]]/}"

_auth_stale_hits=$(_scan_ambient "$_auth_window" '"kind":"auth_token_stale"' | wc -l 2>/dev/null || echo 0)
_auth_stale_hits="${_auth_stale_hits//[[:space:]]/}"

# RESILIENT-1443: worker_sub_auth_dead — worker.sh's precheck (CHUMP_AUTH_MODE=
# oauth) found the claude CLI OAuth session logged out (e.g. lapsed across a
# reboot). This is an unambiguous "the sub is dead" signal, not a probabilistic
# storm, so it pages at a low count by default (threshold=1) — the whole point
# is that a logged-out sub pages within one worker cycle instead of the fleet
# silently demoting to a dead free-tier floor for hours (2026-09-21 CJ
# incident: farmer heartbeat stayed green while 0 gaps shipped post-reboot).
_sub_auth_dead_hits=$(_scan_ambient "$_auth_window" '"kind":"worker_sub_auth_dead"' | wc -l 2>/dev/null || echo 0)
_sub_auth_dead_hits="${_sub_auth_dead_hits//[[:space:]]/}"

# CREDIBLE-130: fleet_credit_exhausted (billing exhausted, credentials fine)
# is deliberately EXCLUDED from every AUTH_DEAD signal above — it must never
# be added to the fleet_auth_storm/oauth_token_refresh_failed/auth_token_stale
# scan set, since that would resurrect the 2026-06-08 misdiagnosis (a valid
# key on a zero-balance account paged as "auth credentials appear fully
# dead"). Surface it as its own informational line instead so an operator
# checking recall status sees the real cause and the real fix (top up
# credits / switch CHUMP_AUTH_MODE), not an auth-rotation runbook.
_credit_exhausted_hits=$(_scan_ambient "$_auth_window" '"kind":"fleet_credit_exhausted"' | wc -l 2>/dev/null || echo 0)
_credit_exhausted_hits="${_credit_exhausted_hits//[[:space:]]/}"
if (( _credit_exhausted_hits > 0 )); then
    echo "[operator-recall] INFO: fleet_credit_exhausted seen ${_credit_exhausted_hits}x in last ${_auth_window}s — billing exhausted, NOT an auth failure; not counted toward AUTH_DEAD. Top up credits or switch CHUMP_AUTH_MODE." >&2
fi

_reason=""
if (( _auth_exits >= _auth_threshold )); then
    _reason="fleet_auth_storm with action=worker_exit seen ${_auth_exits}x in last ${_auth_window}s (threshold=${_auth_threshold}); auth credentials appear fully dead"
elif (( _oauth_fail_hits >= _oauth_fail_threshold )); then
    _reason="oauth_token_refresh_failed seen ${_oauth_fail_hits}x in last ${_auth_window}s (threshold=${_oauth_fail_threshold}); OAuth refresher repeatedly failing"
elif (( _auth_stale_hits >= _auth_stale_threshold )); then
    _reason="auth_token_stale seen ${_auth_stale_hits}x in last ${_auth_window}s (threshold=${_auth_stale_threshold}); token stale/expired and not recovering"
elif (( _sub_auth_dead_hits >= _sub_auth_dead_threshold )); then
    _reason="worker_sub_auth_dead seen ${_sub_auth_dead_hits}x in last ${_auth_window}s (threshold=${_sub_auth_dead_threshold}); claude CLI OAuth session is logged out on a worker configured for CHUMP_AUTH_MODE=oauth (RESILIENT-1443) — run: claude then /login, verify with: claude -p OK"
fi

if [[ -n "$_reason" ]]; then
    if (( _check_only )); then
        echo "[operator-recall] HALT condition=AUTH_DEAD: $_reason"
        _any_halt=1
    else
        _emit_recall "AUTH_DEAD" "$_reason"
    fi
fi

# (b) COST_CAP — cost_cap_exceeded event in ambient within 2 h, or cost-watch hard-cap
_cost_hits=$(_scan_ambient "7200" '"kind":"cost_cap_exceeded"' | wc -l 2>/dev/null || echo 0)
_cost_hits="${_cost_hits//[[:space:]]/}"
_cost_over=0
if (( _cost_hits > 0 )); then
    _cost_over=1
else
    # Secondary: ask chump binary (best-effort, may not be available)
    if command -v chump >/dev/null 2>&1; then
        if ! chump cost-watch --hard-cap >/dev/null 2>&1; then
            _cost_over=1
        fi
    fi
fi
if (( _cost_over )); then
    _reason="daily cost cap exceeded (${_cost_hits} cost_cap_exceeded event(s) in ambient.jsonl or chump cost-watch --hard-cap triggered)"
    if (( _check_only )); then
        echo "[operator-recall] HALT condition=COST_CAP: $_reason"
        _any_halt=1
    else
        _emit_recall "COST_CAP" "$_reason"
    fi
fi

# (c) CI_BROKEN — pr_stuck with ci-related reason
_ci_raw=$(_scan_ambient "$_ci_window" '"kind":"pr_stuck"')
# RESILIENT-281: grep -c already prints "0" (and exits 1) on zero matches;
# `|| echo 0` appended a duplicate line ($'0\n0'), breaking the `(( ))`
# comparisons below with a silent "syntax error in expression". Use `|| true`.
_ci_hits=$(echo "$_ci_raw" | grep -ic '"reason".*ci\|ci.*fail\|check.*fail\|all.*check' 2>/dev/null || true)
_ci_hits="${_ci_hits//[[:space:]]/}"
# Fall back: count any pr_stuck if no reason field — conservative
if (( _ci_hits == 0 )); then
    _total_stuck=$(echo "$_ci_raw" | grep -c '"kind":"pr_stuck"' 2>/dev/null || true)
    _total_stuck="${_total_stuck//[[:space:]]/}"
    if (( _total_stuck >= _ci_threshold * 2 )); then
        _ci_hits=$_ci_threshold
    fi
fi
if (( _ci_hits >= _ci_threshold )); then
    _reason="${_ci_hits} pr_stuck-with-CI-failure event(s) in last ${_ci_window}s (threshold=${_ci_threshold}); CI may be fully broken"
    if (( _check_only )); then
        echo "[operator-recall] HALT condition=CI_BROKEN: $_reason"
        _any_halt=1
    else
        _emit_recall "CI_BROKEN" "$_reason"
    fi
fi

# (d) QUEUE_STARVE — pickable_count=0 AND no gap_reserved in last N seconds
_recent_queue=$(_scan_ambient "300" '"kind":"fleet_queue_depth"' | tail -1)
_pickable=1  # default: assume queue has work
if [[ -n "$_recent_queue" ]]; then
    _pickable=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(int(d.get('pickable_count', 1)))
except Exception:
    print(1)
" "$_recent_queue" 2>/dev/null || echo 1)
fi
_pickable="${_pickable//[[:space:]]/}"

if (( _pickable == 0 )); then
    _recent_reserve=$(_scan_ambient "$_queue_starve" '"kind":"gap_reserved"' | wc -l 2>/dev/null || echo 0)
    _recent_reserve="${_recent_reserve//[[:space:]]/}"
    if (( _recent_reserve == 0 )); then
        _starve_hours=$(( _queue_starve / 3600 ))
        _reason="queue has 0 pickable gaps AND no gap_reserved event in last ${_starve_hours}h; fleet is starved with no new work arriving"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=QUEUE_STARVE: $_reason"
            _any_halt=1
        else
            _emit_recall "QUEUE_STARVE" "$_reason"
        fi
    fi
fi

# (e) QUEUE_SATURATED — stale queued runs classified into RUNNERS_GHOSTED or
#     QUEUE_SATURATED_GH_HOSTED by sampling job runs-on labels (META-101)
if (( _runner_ghost_detect != 0 )); then
    _detect_queue_saturated
fi

# (f) DISK_CRITICAL — disk_critical event recently AND current free% still below threshold
_disk_hits=$(_scan_ambient "$_disk_critical_window" '"kind":"disk_critical"' | wc -l 2>/dev/null || echo 0)
_disk_hits="${_disk_hits//[[:space:]]/}"
if (( _disk_hits > 0 )); then
    _cur_free_pct=$(df -P /System/Volumes/Data 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print 100-$5}' || echo 100)
    _cur_free_pct="${_cur_free_pct//[[:space:]]/}"
    if [[ -n "$_cur_free_pct" ]] && (( _cur_free_pct < _disk_critical_pct )); then
        _reason="${_disk_hits} disk_critical event(s) in last ${_disk_critical_window}s AND current free=${_cur_free_pct}% (<${_disk_critical_pct}%); reactor escalation insufficient — operator must intervene"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=DISK_CRITICAL: $_reason"
            _any_halt=1
        else
            _emit_recall "DISK_CRITICAL" "$_reason"
        fi
    fi
fi

# (h) AUTONOMY_HALT — RESILIENT-321: sustained silent kill-switch halt.
# Live-read the current AUTONOMY_LEVEL (same fail-closed contract as every
# other consumer); only proceed if it is 0 RIGHT NOW — a since-recovered halt
# (operator ran `chump fleet start`) must not page.
_al_file_live="${HOME:-/tmp}/.chump/AUTONOMY_LEVEL"
_al_now=0
if [[ -r "$_al_file_live" ]]; then
    _al_raw_live="$(tr -d '[:space:]' < "$_al_file_live" 2>/dev/null || true)"
    [[ "$_al_raw_live" =~ ^[0-9]+$ ]] && _al_now="$_al_raw_live"
fi
if [[ "$_al_now" -eq 0 ]]; then
    _halt_events=$(_scan_ambient "$_autonomy_halt_window" '"kind":"fleet_stopped_kill_switch"')
    if [[ -n "$_halt_events" ]]; then
        _first_halt_ts=$(echo "$_halt_events" | python3 -c "
import json, sys
from datetime import datetime, timezone
best = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        ts = d.get('ts', '').rstrip('Z')
        epoch = int(datetime.fromisoformat(ts).replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        continue
    if best is None or epoch < best:
        best = epoch
print(best if best is not None else 0)
" 2>/dev/null || echo 0)
        _first_halt_ts="${_first_halt_ts:-0}"
        if [[ "$_first_halt_ts" =~ ^[0-9]+$ ]] && (( _first_halt_ts > 0 )); then
            _halt_age=$(( $(_now_epoch) - _first_halt_ts ))
            if (( _halt_age >= _autonomy_halt_min_secs )); then
                _halt_mins=$(( _halt_age / 60 ))
                _reason="AUTONOMY_LEVEL has been 0 (kill switch) for ~${_halt_mins}m (>= ${_autonomy_halt_min_secs}s threshold); fleet is silently halted with no work happening"
                if (( _check_only )); then
                    echo "[operator-recall] HALT condition=AUTONOMY_HALT: $_reason"
                    _any_halt=1
                else
                    _emit_recall "AUTONOMY_HALT" "$_reason" ',"class":"AUTONOMY_HALT","halt_age_s":'"$_halt_age"',"remediation":"chump fleet start (or chump fleet level N) to resume; if this was NOT operator-initiated, find + fix the process that wrote AUTONOMY_LEVEL=0 before resuming"'
                fi
            fi
        fi
    fi
fi

# (j) ZERO_SHIP_ACTIVE — RESILIENT-575: workers are actively cycling
# (worker_exit events present, so this is NOT idle/dead — (h)/(i) own that)
# but nothing has shipped in the same window. Catches the "board said active,
# nothing shipped" class the 2026-09-01 sub-cap-outage incident fell through.
_worker_cycles=$(_scan_ambient "$_zero_ship_window" '"kind":"worker_exit"' | wc -l 2>/dev/null || echo 0)
_worker_cycles="${_worker_cycles//[[:space:]]/}"
if [[ -n "$_worker_cycles" ]] && (( _worker_cycles >= _zero_ship_min_cycles )); then
    _ship_count=$(_scan_ambient "$_zero_ship_window" '"kind":"gap_shipped"' | wc -l 2>/dev/null || echo 0)
    _ship_count="${_ship_count//[[:space:]]/}"
    if [[ -n "$_ship_count" ]] && (( _ship_count == 0 )); then
        _zs_hours=$(( _zero_ship_window / 3600 ))
        _reason="${_worker_cycles} worker_exit cycle(s) in the last ${_zs_hours}h (workers actively cycling) but 0 gap_shipped events — fleet is busy but shipping nothing"
        if (( _check_only )); then
            echo "[operator-recall] HALT condition=ZERO_SHIP_ACTIVE: $_reason"
            _any_halt=1
        else
            _emit_recall "ZERO_SHIP_ACTIVE" "$_reason" ',"class":"ZERO_SHIP_ACTIVE","worker_cycles":'"$_worker_cycles"',"remediation":"check for fleet_backend_auto_fallback / worker_cooldown_cluster_wide / auth-storm events in ambient.jsonl; a busy-but-fruitless fleet usually means every cycle is silently failing on one backend"'
        fi
    fi
fi

if (( _check_only && _any_halt )); then
    exit 1
fi
exit 0
