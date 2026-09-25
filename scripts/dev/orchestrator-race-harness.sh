#!/usr/bin/env bash
# scripts/dev/orchestrator-race-harness.sh — INFRA-4283 (INFRA-1966 slice)
#
# Reproducible test harness for orchestrator race conditions. bot-merge.sh,
# queue-driver.sh, and pr-rescue.sh (scripts/coord/) all read/write the same
# shared substrate — .chump-locks/*.json leases, .chump-locks/ambient.jsonl,
# and the git index — with no cross-process mutex between them (INFRA-1966
# critique C3). This harness launches all three concurrently inside an
# isolated sandbox clone (never the caller's real worktree), records exit
# code / timestamps / PID / subshell identifier for every launch, and
# compares an unsynchronized run against a flock-serialized run so the race
# is directly observable rather than asserted.
#
# Controlled environment (AC1):
#   - `git clone --local` of this repo into a throwaway tmpdir sandbox.
#     Every launched process's REPO_ROOT resolves inside the sandbox
#     (each script computes REPO_ROOT from its own script path), so nothing
#     here touches the caller's live .chump-locks/, git state, or gaps.
#   - All three targets run in their safe/no-mutate mode: bot-merge.sh and
#     queue-driver.sh get --dry-run; pr-rescue.sh gets PR_RESCUE_DRY_RUN=1.
#     GH_TOKEN is intentionally left unset unless the caller exports one —
#     all three scripts are documented to no-op/exit early without it, which
#     keeps the harness network-free and CI-safe by default.
#
# Recording (AC2): every launch appends one JSONL line to --out with
#   {target, iteration, mode, pid, subshell (BASHPID), start_ts, end_ts,
#    duration_s, exit_code}
#
# Reproduction (AC3): default mode ("race") launches all three targets with
# a bare `&` — no synchronization. --serialize mode wraps each launch in a
# flock on a shared lockfile in the sandbox so only one target runs at a
# time. Run both modes back to back (the default) and the summary reports
# the exit-code variance seen in each — the race mode is expected to show
# non-uniform exit codes / contention errors (e.g. index.lock, lease CAS
# failures surfaced in stderr) across iterations that the serialized mode
# does not.
#
# Usage:
#   scripts/dev/orchestrator-race-harness.sh [options]
#
# Options:
#   --iterations N     Repetitions per mode (default: 3)
#   --timeout SECS     Per-process wall-clock cap via `timeout` (default: 30)
#   --mode race|serialize|both   Which mode(s) to run (default: both)
#   --out FILE          JSONL output path (default: sandbox/harness-log.jsonl,
#                        copied to /tmp/orchestrator-race-harness-<ts>.jsonl)
#   --keep-sandbox       Don't delete the sandbox clone on exit (for inspection)
#
# Exit code: always 0 on successful completion of the harness itself (the
# harness's job is to reproduce and record races, not to fail CI on them).
# Non-zero only on harness setup failure (clone failed, etc).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ITERATIONS=3
TIMEOUT_S=30
MODE="both"
OUT_FILE=""
KEEP_SANDBOX=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --timeout)    TIMEOUT_S="$2"; shift 2 ;;
        --mode)       MODE="$2"; shift 2 ;;
        --out)        OUT_FILE="$2"; shift 2 ;;
        --keep-sandbox) KEEP_SANDBOX=1; shift ;;
        -h|--help)
            sed -n '2,45p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "[race-harness] unknown arg: $1" >&2; exit 2 ;;
    esac
done

case "$MODE" in
    race|serialize|both) ;;
    *) echo "[race-harness] --mode must be race|serialize|both, got: $MODE" >&2; exit 2 ;;
esac

TS="$(date -u +%Y%m%dT%H%M%SZ)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/orchestrator-race-harness-XXXXXX")"
[[ -z "$OUT_FILE" ]] && OUT_FILE="${TMPDIR:-/tmp}/orchestrator-race-harness-${TS}.jsonl"
LOCKFILE="$SANDBOX/serialize.lock"
: > "$OUT_FILE"

cleanup() {
    if [[ "$KEEP_SANDBOX" -eq 1 ]]; then
        echo "[race-harness] sandbox kept at: $SANDBOX" >&2
    else
        rm -rf "$SANDBOX"
    fi
}
trap cleanup EXIT

echo "[race-harness] cloning $REPO_ROOT -> $SANDBOX/repo (local, isolated)" >&2
if ! git clone --local --quiet "$REPO_ROOT" "$SANDBOX/repo" 2>"$SANDBOX/clone.err"; then
    echo "[race-harness] FATAL: sandbox clone failed:" >&2
    cat "$SANDBOX/clone.err" >&2
    exit 1
fi
SANDBOX_REPO="$SANDBOX/repo"

# target -> invocation (relative to $SANDBOX_REPO)
declare -A TARGET_CMD=(
    [bot-merge]="scripts/coord/bot-merge.sh --dry-run"
    [queue-driver]="scripts/coord/queue-driver.sh --dry-run"
    [pr-rescue]="scripts/coord/pr-rescue.sh"
)
declare -A TARGET_ENV=(
    [bot-merge]=""
    [queue-driver]=""
    [pr-rescue]="PR_RESCUE_DRY_RUN=1"
)

now_ns() { date -u +%s.%N; }

# launch_one <target> <iteration> <run_mode>
# Appends one JSONL record to OUT_FILE. Runs in the background; caller waits
# on $! and matches PIDs back up via the pid field already recorded.
launch_one() {
    local target="$1" iteration="$2" run_mode="$3"
    local cmd="${TARGET_CMD[$target]}"
    local envs="${TARGET_ENV[$target]}"
    local start end dur pid subshell rc

    (
        # shellcheck disable=SC2086
        cd "$SANDBOX_REPO" || exit 127
        start="$(now_ns)"
        pid=$$
        subshell="$BASHPID"
        if [[ "$run_mode" == "serialize" ]]; then
            exec {lockfd}>"$LOCKFILE"
            flock "$lockfd"
        fi
        # shellcheck disable=SC2086
        env $envs timeout "$TIMEOUT_S" $cmd >"$SANDBOX/${target}-${run_mode}-${iteration}.out" 2>&1
        rc=$?
        end="$(now_ns)"
        dur="$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}')"
        printf '{"target":"%s","iteration":%d,"mode":"%s","pid":%d,"subshell":%d,"start_ts":"%s","end_ts":"%s","duration_s":%s,"exit_code":%d}\n' \
            "$target" "$iteration" "$run_mode" "$pid" "$subshell" "$start" "$end" "$dur" "$rc" >> "$OUT_FILE"
        exit "$rc"
    ) &
}

run_round() {
    local run_mode="$1" iteration="$2"
    local pids=()
    for target in "${!TARGET_CMD[@]}"; do
        launch_one "$target" "$iteration" "$run_mode"
        pids+=("$!")
    done
    # AC1: launched in parallel — no `wait` between launches above, only after.
    local p
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null || true
    done
}

run_mode_all() {
    local run_mode="$1"
    local i
    for (( i = 1; i <= ITERATIONS; i++ )); do
        echo "[race-harness] mode=$run_mode iteration=$i/$ITERATIONS" >&2
        run_round "$run_mode" "$i"
    done
}

if [[ "$MODE" == "race" || "$MODE" == "both" ]]; then
    run_mode_all "race"
fi
if [[ "$MODE" == "serialize" || "$MODE" == "both" ]]; then
    run_mode_all "serialize"
fi

# ── summary (AC3): report exit-code variance per target per mode ───────────
echo "" >&2
echo "[race-harness] summary (log: $OUT_FILE)" >&2
for run_mode in race serialize; do
    [[ "$MODE" != "both" && "$MODE" != "$run_mode" ]] && continue
    for target in "${!TARGET_CMD[@]}"; do
        codes="$(grep "\"target\":\"${target}\"" "$OUT_FILE" 2>/dev/null | grep "\"mode\":\"${run_mode}\"" \
            | sed -n 's/.*"exit_code":\([0-9-]*\).*/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')"
        n_distinct="$(printf '%s' "$codes" | tr ',' '\n' | grep -c . || true)"
        variance=""
        [[ "$n_distinct" -gt 1 ]] && variance=" <-- non-uniform exit codes across iterations (race symptom)"
        printf '  %-8s %-12s exit_codes=[%s]%s\n' "$run_mode" "$target" "$codes" "$variance" >&2
    done
done

echo "[race-harness] done. $(wc -l < "$OUT_FILE" | tr -d ' ') records written to $OUT_FILE" >&2
exit 0
