#!/usr/bin/env bash
# scripts/coord/mesh-worker-loop.sh — INFRA-2545 (FLEET-034 Phase 2 / INFRA-2476)
#
# The persistent CONSUMER half of the NATS work-routing mesh. The publisher half
# (chump-coord assign daemon, com.chump.coord-assign) posts WorkEnvelopes to
# chump.work.>; this consumer picks ONE capability-matched gap per tick and
# either ROUTES it (default) or EXECUTES it.
#
# This is what turns the fleet's *coincidental* convergence (every agent pulls
# independently, re-discovering the same work) into *coordinated* convergence
# (work is routed to the worker whose capabilities match — no duplication).
#
# SAFETY:
#   - FAIL-OPEN: if the broker is unreachable, exit 0 immediately — the pull
#     fleet (scripts/dispatch/worker.sh) handles everything. The mesh is an
#     optimization layer, never a dependency (A2A_ROADMAP principle 7).
#   - BOUNDED: one gap per invocation; cadence is the launchd StartInterval.
#   - ROUTE-ONLY by default: claim a capability-matched gap, emit a coordination
#     event, release. Proves the routing is LIVE with ZERO autonomous-execution
#     risk. Flip CHUMP_MESH_WORKER_EXECUTE=1 to hand the gap to the standard
#     autonomous executor (chump --execute-gap), which takes the authoritative
#     file-lease (so it coexists safely with the pull fleet — the file-lease
#     arbitrates; no double-execution).
#
# Env:
#   CHUMP_NATS_URL                broker (default nats://127.0.0.1:4222)
#   WORKER_SKILLS / WORKER_MACHINE / WORKER_BACKEND   capability filter
#   CHUMP_MESH_WORKER_EXECUTE=1   enable execution (default: route-only)
#   CHUMP_COORD_BIN               chump-coord path (default ~/.local/bin/chump-coord)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
[ -n "$ROOT" ] && cd "$ROOT" || exit 0
export CHUMP_NATS_URL="${CHUMP_NATS_URL:-nats://127.0.0.1:4222}"
BIN="${CHUMP_COORD_BIN:-$HOME/.local/bin/chump-coord}"
# Ambient stream lives in the MAIN repo's .chump-locks. When the daemon runs
# from the main checkout (its deployed home) $ROOT is correct; CHUMP_AMBIENT_PATH
# lets a worktree-run / test point at the canonical stream explicitly.
AMB="${CHUMP_AMBIENT_PATH:-$ROOT/.chump-locks/ambient.jsonl}"
SESS="${CHUMP_SESSION_ID:-mesh-worker-$(hostname -s 2>/dev/null || echo host)-$$}"
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# schedule_ephemeral — EFFECTIVE-1015 (EFFECTIVE-178 slice)
#
# Runs `cmd` on a fixed `interval` in a detached background subshell.
# Stops after `max_iter` executions if max_iter > 0 (0/empty = unbounded),
# and stops as soon as `ctx_pid` (if non-empty) is no longer alive — the
# cancellable context. Prints "[EPHEMERAL]" before each execution so the
# loop is observable in logs. Echoes the background subshell's PID so a
# caller can track/wait on it.
schedule_ephemeral() {
    local cmd="$1" interval="$2" max_iter="${3:-0}" ctx_pid="${4:-}"
    (
        local n=0
        while :; do
            if [ -n "$ctx_pid" ] && ! kill -0 "$ctx_pid" 2>/dev/null; then
                break
            fi
            n=$((n + 1))
            echo "[EPHEMERAL] $(_ts) iter=${n} cmd: ${cmd}"
            eval "$cmd"
            if [ "$max_iter" -gt 0 ] && [ "$n" -ge "$max_iter" ]; then
                break
            fi
            if [ -n "$ctx_pid" ] && ! kill -0 "$ctx_pid" 2>/dev/null; then
                break
            fi
            sleep "$interval"
        done
    ) &
    echo $!
}

# --- unit tests (run via: scripts/coord/mesh-worker-loop.sh --self-test) ---

test_schedule_ephemeral_max_iter() {
    local tmpfile sched_pid count
    tmpfile="$(mktemp)"
    sched_pid=$(schedule_ephemeral "echo tick >> '${tmpfile}'" 0.2 3 "")
    wait "$sched_pid" 2>/dev/null
    count=$(wc -l < "$tmpfile" | tr -d ' ')
    rm -f "$tmpfile"
    if [ "$count" -eq 3 ]; then
        echo "PASS test_schedule_ephemeral_max_iter"
        return 0
    fi
    echo "FAIL test_schedule_ephemeral_max_iter (expected 3 executions, got ${count})"
    return 1
}

test_schedule_ephemeral_cancel() {
    local tmpfile ctx_pid sched_pid count_at_cancel count_after
    tmpfile="$(mktemp)"
    sleep 100 &
    ctx_pid=$!
    sched_pid=$(schedule_ephemeral "echo tick >> '${tmpfile}'" 0.2 1000 "$ctx_pid")
    sleep 0.7
    kill "$ctx_pid" 2>/dev/null
    wait "$ctx_pid" 2>/dev/null
    sleep 0.3
    count_at_cancel=$(wc -l < "$tmpfile" | tr -d ' ')
    sleep 1
    count_after=$(wc -l < "$tmpfile" | tr -d ' ')
    kill "$sched_pid" 2>/dev/null
    rm -f "$tmpfile"
    if [ "$count_after" -eq "$count_at_cancel" ]; then
        echo "PASS test_schedule_ephemeral_cancel"
        return 0
    fi
    echo "FAIL test_schedule_ephemeral_cancel (count grew from ${count_at_cancel} to ${count_after} after cancel)"
    return 1
}

if [ "${1:-}" = "--self-test" ]; then
    _fail=0
    test_schedule_ephemeral_max_iter || _fail=1
    test_schedule_ephemeral_cancel || _fail=1
    exit "$_fail"
fi

[ -x "$BIN" ] || { echo "[mesh-worker] chump-coord not found at $BIN — exit." >&2; exit 0; }

# MISSION-018: log external-repo pick state at every tick so "is the flag
# flipped?" is observable from the worker logs. Implemented at
# crates/chump-coord/src/worker/capability.rs:130 — gaps tagged with
# skills_required containing `external_repo:<owner>/<repo>` are skipped unless
# this env var is "1". The plist sets it to 1 by default (BEAST-MODE work).
echo "[mesh-worker] $(_ts) external_repo_pick_ok=${CHUMP_EXTERNAL_REPO_PICK_OK:-0}" >&2

# FAIL-OPEN: no broker → let the pull fleet handle all work.
if ! "$BIN" ping >/dev/null 2>&1; then
    echo "[mesh-worker] NATS unreachable — fail-open; pull fleet handles work." >&2
    exit 0
fi

# Pick ONE capability-matched, mesh-routed gap — claiming AT MOST ONE.
#
# Bus shape: the work bus is EPHEMERAL core NATS pub/sub (assign.rs publishes via
# core `.publish()`, no JetStream retention) and the publisher emits a burst of
# *every open gap* every ~30s. A late subscriber gets no backlog — it only sees
# envelopes published while it is connected.
#
# Why `--once` and NOT a persistent `worker`: `chump-coord worker` (no --once)
# is the pull-fleet's NATS front-end — it CLAIMS EVERY capability-match it sees.
# Pointed at a 1300-envelope burst with broad WORKER_SKILLS, it claims the whole
# board in one drain. `--once` instead `break`s after the FIRST successful CAS
# claim, so it claims EXACTLY ONE gap (or zero). That exactly-one guarantee is
# the anti-flood invariant — route-only must never claim a batch it won't run.
#
# The cost of `--once` is a tiny subscribe window (~500ms drain) that usually
# falls *between* the publisher's 30s bursts. We cover that by RETRYING --once
# back-to-back until it catches one or the deadline passes. Each attempt
# reconnects (~hundreds of ms), so this is NATS-latency-paced, not a CPU spin —
# no sleep needed (and sleep is unavailable in some harnesses). Net: at most one
# claim per tick, reliably caught within ~one publisher cycle.
WAIT_S="${CHUMP_MESH_WORKER_WAIT_S:-40}"
GAP=""
_deadline=$(( $(date +%s) + WAIT_S ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
    GAP="$(CHUMP_SESSION_ID="$SESS" "$BIN" worker --once --subjects 'chump.work.>' 2>/dev/null \
        | grep -oE '^[A-Z]+-[0-9]+' | head -1)"
    [ -n "$GAP" ] && break
done
if [ -z "$GAP" ]; then
    echo "[mesh-worker] no mesh-routed gap matched capabilities within ${WAIT_S}s." >&2
    exit 0
fi

if [ "${CHUMP_MESH_WORKER_EXECUTE:-0}" != "1" ]; then
    # ROUTE-ONLY (default): the mesh routed real work to this worker's
    # capabilities — record it, release the claim, do not execute.
    # scanner-anchor: "kind":"mesh_worker_routed"
    printf '{"ts":"%s","kind":"mesh_worker_routed","gap_id":"%s","session":"%s","mode":"route-only","note":"INFRA-2545 FLEET-034 work-routing live; set CHUMP_MESH_WORKER_EXECUTE=1 to execute"}\n' \
        "$(_ts)" "$GAP" "$SESS" >> "$AMB" 2>/dev/null || true
    "$BIN" release "$GAP" >/dev/null 2>&1 || true
    echo "[mesh-worker] ROUTE-ONLY: mesh routed $GAP to my capabilities (released). Set CHUMP_MESH_WORKER_EXECUTE=1 to execute." >&2
    exit 0
fi

# EXECUTE: release the NATS-KV routing-claim, then hand to the standard
# autonomous executor, which takes the authoritative file-lease (coexists
# safely with the pull fleet — the file-lease arbitrates).
# scanner-anchor: "kind":"mesh_worker_executing"
printf '{"ts":"%s","kind":"mesh_worker_executing","gap_id":"%s","session":"%s","note":"INFRA-2545: mesh-routed -> chump --execute-gap"}\n' \
    "$(_ts)" "$GAP" "$SESS" >> "$AMB" 2>/dev/null || true
"$BIN" release "$GAP" >/dev/null 2>&1 || true
echo "[mesh-worker] EXECUTE: mesh routed $GAP -> chump --execute-gap" >&2
exec chump --execute-gap "$GAP"
