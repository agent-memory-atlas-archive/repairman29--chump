#!/usr/bin/env bash
# scripts/ops/almanac-summarize-watchdog.sh — RESILIENT-354
#
# WHY THIS EXISTS. The almanac summarize fleet launcher
# (`com.jeffadkins.almanac.summarize`, the driver that turns embedded rows
# into fusion-searchable summaries) was hand-launched, not durably supervised
# — FLEET_LOAD_MAP.md flagged this as "not hand-launched (tonight's
# mistake)". It died to SIGTERM on 2026-08-10 and nothing restarted it: chump
# sat stuck at 68.6% summarized for 10 days, silently degrading the fusion
# search leg (keyword-only) on a third of the served repos. No alarm fired
# because nothing watched the launcher's liveness OR the coverage number it
# is supposed to move.
#
# This watchdog closes both halves, mirroring organ-watchdog.sh's pattern
# (RESILIENT-356: the healer itself is peer-supervised so it can never stay
# dead) applied to the almanac summarize organ specifically:
#
#   1. LIVENESS — is the summarize driver process alive? If not, restart it
#      (no human step). Proof of "kill it -> back within one cycle".
#   2. COVERAGE — is the fleet's summarized-percentage at/above the floor
#      (default 95%) for every served repo? If any served repo is below the
#      floor, page the operator via operator-recall.sh --condition
#      ALMANAC_SUMMARIZE_COVERAGE_DROP — the same halt-class paging path
#      every other organ failure uses (WORKER_HALT, CI_BROKEN, ...).
#
# Usage:
#   scripts/ops/almanac-summarize-watchdog.sh              # scan + heal, real commands
#   scripts/ops/almanac-summarize-watchdog.sh --dry-run     # report only, no restart/page
#
# Test hooks (used by scripts/ci/test-almanac-summarize-watchdog.sh):
#   CHUMP_ALMANAC_WATCHDOG_PGREP_BIN     — path to a stubbed `pgrep`
#   CHUMP_ALMANAC_WATCHDOG_RESTART_CMD   — command to run to (re)start the
#                                          driver (default: launchctl
#                                          kickstart -k gui/$(id -u)/
#                                          com.jeffadkins.almanac.summarize)
#   CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN  — path to a stubbed coverage-reporter
#                                          (default: `almanac coverage --json`
#                                          via CHUMP_ALMANAC_BIN)
#   CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT — override for operator-recall.sh
#   CHUMP_ALMANAC_SUMMARIZE_MIN_PCT      — coverage floor (default 95)
#   CHUMP_ALMANAC_SUMMARIZE_PROC_PATTERN — pgrep -f pattern for the driver
#                                          (default 'summarize-worker|summarize-supervisor|almanac.*summarize')
#   CHUMP_AMBIENT_LOG                    — override ambient.jsonl path
#
# Exit codes:
#   0  normal (coverage at/above floor, or check skipped)
#   1  internal failure (coverage report unreadable and not a plain skip)
#   2  CREDIBLE-1174: coverage guard tripped — at least one served repo is
#      below the summarized-coverage floor (default 95%). The operator page
#      already fires unconditionally (see below); this non-zero exit lets a
#      calling supervisor (launchd condition, CI gate, chained script) react
#      to the guard without having to grep ambient.jsonl.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

PGREP_BIN="${CHUMP_ALMANAC_WATCHDOG_PGREP_BIN:-pgrep}"
PROC_PATTERN="${CHUMP_ALMANAC_SUMMARIZE_PROC_PATTERN:-summarize-worker|summarize-supervisor|almanac.*summarize}"
RESTART_CMD="${CHUMP_ALMANAC_WATCHDOG_RESTART_CMD:-launchctl kickstart -k gui/$(id -u)/com.jeffadkins.almanac.summarize}"
COVERAGE_BIN="${CHUMP_ALMANAC_WATCHDOG_COVERAGE_BIN:-}"
ALMANAC_BIN="${CHUMP_ALMANAC_BIN:-$HOME/Projects/almanac/target/release/almanac}"
RECALL_SCRIPT="${CHUMP_ALMANAC_WATCHDOG_RECALL_SCRIPT:-$REPO_ROOT/scripts/dispatch/operator-recall.sh}"
MIN_PCT="${CHUMP_ALMANAC_SUMMARIZE_MIN_PCT:-95}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── 1. Liveness: is the summarize driver alive? ─────────────────────────────
restarted=0
if "$PGREP_BIN" -f "$PROC_PATTERN" >/dev/null 2>&1; then
    echo "[almanac-summarize-watchdog] driver alive (pattern: $PROC_PATTERN)"
else
    echo "[almanac-summarize-watchdog] DEAD: no process matching '$PROC_PATTERN'"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[almanac-summarize-watchdog]   (dry-run) would run: $RESTART_CMD"
    else
        if eval "$RESTART_CMD" >/dev/null 2>&1; then
            echo "[almanac-summarize-watchdog]   restarted driver"
            # scanner-anchor: "kind":"almanac_summarize_restarted"  (RESILIENT-354;
            # fires when the watchdog finds the summarize driver dead and
            # relaunches it with no human step — proof "kill it -> back
            # within one cycle")
            emit almanac_summarize_restarted "\"pattern\":\"$PROC_PATTERN\""
            restarted=1
        else
            echo "[almanac-summarize-watchdog]   ERROR: restart command failed" >&2
            # scanner-anchor: "kind":"almanac_summarize_restart_failed"
            emit almanac_summarize_restart_failed "\"pattern\":\"$PROC_PATTERN\""
        fi
    fi
fi

# ── 2. Coverage: is every served repo at/above the floor? ──────────────────
coverage_json=""
coverage_status="ok"
if [[ -n "$COVERAGE_BIN" ]]; then
    coverage_json="$("$COVERAGE_BIN" 2>/dev/null || true)"
elif [[ -x "$ALMANAC_BIN" ]]; then
    coverage_json="$("$ALMANAC_BIN" coverage --json 2>/dev/null || true)"
else
    coverage_status="skip"
    echo "[almanac-summarize-watchdog] almanac CLI absent at $ALMANAC_BIN — skipping coverage check (no local index on this node)"
fi

worst_repo="" worst_pct="" below_count=0
if [[ "$coverage_status" == "ok" ]]; then
    if [[ -z "$coverage_json" ]]; then
        echo "[almanac-summarize-watchdog] coverage report empty/unreadable" >&2
        emit almanac_summarize_watchdog_tick "\"restarted\":$restarted,\"coverage_status\":\"error\",\"dry_run\":$DRY_RUN"
        exit 1
    fi
    read -r below_count worst_repo worst_pct <<<"$(printf '%s' "$coverage_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("0", "", "")
    sys.exit(0)
repos = data.get("repos", data if isinstance(data, list) else [])
floor = float(sys.argv[1])
below = []
for r in repos:
    name = r.get("repo", r.get("name", "unknown"))
    # CREDIBLE-1045: a repo entry missing both "pct" and "summarized_pct"
    # used to default to 100 (silently treated as fully compliant). That let
    # a malformed/partial coverage report hide a real coverage gap instead
    # of tripping the floor check. Missing/unparseable data must fail the
    # check, not pass it by default.
    if "pct" not in r and "summarized_pct" not in r:
        below.append((f"{name}(missing_pct_field)", 0.0))
        continue
    pct = r.get("pct", r.get("summarized_pct"))
    try:
        pct = float(pct)
    except Exception:
        below.append((f"{name}(invalid_pct_value)", 0.0))
        continue
    if pct < floor:
        below.append((name, pct))
below.sort(key=lambda x: x[1])
if below:
    print(len(below), below[0][0], below[0][1])
else:
    print(0, "", "")
' "$MIN_PCT" 2>/dev/null)"
    below_count="${below_count:-0}"

    if [[ "$below_count" -gt 0 ]]; then
        echo "[almanac-summarize-watchdog] COVERAGE-DROP: $below_count served repo(s) below ${MIN_PCT}% floor (worst: $worst_repo at ${worst_pct}%)"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[almanac-summarize-watchdog]   (dry-run) would page operator: ALMANAC_SUMMARIZE_COVERAGE_DROP"
        elif [[ -x "$RECALL_SCRIPT" ]]; then
            CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$RECALL_SCRIPT" --condition ALMANAC_SUMMARIZE_COVERAGE_DROP \
                --reason "$below_count served repo(s) below ${MIN_PCT}% summarized (worst: $worst_repo at ${worst_pct}%) — fusion NL search degrades to keyword-only on the affected repos" \
                >/dev/null 2>&1 || echo "[almanac-summarize-watchdog]   WARN: operator-recall.sh call failed" >&2
        fi
        # scanner-anchor: "kind":"almanac_summarize_coverage_drop"  (RESILIENT-354;
        # fires whenever a served repo is below the summarized-coverage floor —
        # the board's verifiable proof coverage-drop pages like any organ
        # failure)
        emit almanac_summarize_coverage_drop "\"below_count\":$below_count,\"worst_repo\":\"$worst_repo\",\"worst_pct\":$worst_pct,\"floor\":$MIN_PCT,\"dry_run\":$DRY_RUN"
    else
        echo "[almanac-summarize-watchdog] coverage OK: all served repos >= ${MIN_PCT}%"
    fi
fi

# Heartbeat — always emit so a dead watchdog is itself observable.
# scanner-anchor: "kind":"almanac_summarize_watchdog_tick"  (RESILIENT-354;
# emitted every cycle, success or no-op — proof the watchdog itself is alive)
emit almanac_summarize_watchdog_tick "\"restarted\":$restarted,\"coverage_status\":\"$coverage_status\",\"below_count\":${below_count:-0},\"dry_run\":$DRY_RUN"

echo "[almanac-summarize-watchdog] cycle complete: restarted=$restarted coverage_status=$coverage_status below_count=${below_count:-0} dry_run=$DRY_RUN"

# CREDIBLE-1174: the 95%-floor guard must be enforceable by a caller, not
# just visible in ambient.jsonl. A non-zero exit here is the "returning an
# error ... when below this threshold" half of the guard; the operator page
# above is the "notify" half. Dry-run never enforces (report-only by design).
if [[ "${below_count:-0}" -gt 0 && "$DRY_RUN" != "1" ]]; then
    exit 2
fi
exit 0
