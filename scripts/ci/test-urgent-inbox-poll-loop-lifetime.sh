#!/usr/bin/env bash
# test-urgent-inbox-poll-loop-lifetime.sh — RESILIENT-1624
#
# The urgent-inbox poll loop must NOT be immortal. Before this fix the
# SessionStart hook daemonized it (nohup + disown) out of the headless
# `claude -p` process group, with its cwd inside the dispatch worktree, so
# INFRA-8198's process-group kill never reached it and every finished dispatch
# left a poller pinning the worktree against the Class-D reaper (8 orphans /
# ~22 GB unreapable on cuphead 2026-10-18).
#
#   AC1: the loop exits within two ticks of its parent session dying.
#   AC1b: the loop exits within two ticks of its worktree being removed.
#   AC2: the SessionStart hook launches the loop with a cwd outside the
#        worktree (so it never pins the worktree cwd against the reaper).
#
# Pure shell / process fixtures — no built binary needed, so this never SKIPs.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOOP="$REPO_ROOT/scripts/setup/urgent-inbox-poll-loop.sh"
HOOK="$REPO_ROOT/scripts/setup/session-start-urgent-inbox-poll.sh"

WORK="$(mktemp -d)"
cleanup() {
    # Reap any fixtures still alive so a failing assertion doesn't leak procs.
    [[ -n "${FAKE_PARENT:-}" ]] && kill "$FAKE_PARENT" 2>/dev/null
    [[ -n "${LOOP_PID:-}" ]] && kill "$LOOP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fast ticks so "two ticks" is ~2s of wall-clock, not ~10s.
export CHUMP_URGENT_INBOX_POLL_INTERVAL_S=1
export CHUMP_AMBIENT_LOG="$WORK/ambient.jsonl"

alive() { kill -0 "$1" 2>/dev/null; }

# Wait up to $1 seconds for pid $2 to exit; return 0 if it exited in time.
wait_exit() {
    local deadline=$(( SECONDS + $1 ))
    while (( SECONDS < deadline )); do
        alive "$2" || return 0
        sleep 0.2
    done
    ! alive "$2"
}

# ---- AC1: parent death ----------------------------------------------------
WT1="$WORK/wt1"
mkdir -p "$WT1/.chump-locks"
# Fake owning session: a process we fully control the lifetime of.
sleep 300 & FAKE_PARENT=$!
CHUMP_REPO="$WT1" bash "$LOOP" "$FAKE_PARENT" & LOOP_PID=$!

sleep 1
alive "$LOOP_PID" || fail "AC1: loop exited while its parent was still alive"

kill "$FAKE_PARENT" 2>/dev/null
wait "$FAKE_PARENT" 2>/dev/null
FAKE_PARENT=""
# Two ticks = 2s; allow a little slack for scheduling.
wait_exit 4 "$LOOP_PID" || fail "AC1: loop did not exit within two ticks of parent death"
LOOP_PID=""
echo "ok AC1: loop exits after parent session dies"

# ---- AC1b: worktree removal -----------------------------------------------
WT2="$WORK/wt2"
mkdir -p "$WT2/.chump-locks"
sleep 300 & FAKE_PARENT=$!
CHUMP_REPO="$WT2" bash "$LOOP" "$FAKE_PARENT" & LOOP_PID=$!

sleep 1
alive "$LOOP_PID" || fail "AC1b: loop exited while its worktree still existed"

rm -rf "$WT2"
wait_exit 4 "$LOOP_PID" || fail "AC1b: loop did not exit within two ticks of worktree removal"
LOOP_PID=""
kill "$FAKE_PARENT" 2>/dev/null; wait "$FAKE_PARENT" 2>/dev/null; FAKE_PARENT=""
echo "ok AC1b: loop exits after its worktree is removed"

# ---- AC2: hook launches the loop with cwd outside the worktree ------------
# Only assertable where /proc/<pid>/cwd is readable (Linux). Elsewhere the
# cwd=/ launch is still exercised; we just can't introspect it, so we skip the
# assertion rather than fail.
if [[ -r "/proc/$$/cwd" ]]; then
    WT3="$WORK/wt3"
    mkdir -p "$WT3/.chump-locks" "$WT3/scripts/setup"
    # The hook resolves LOOP_SCRIPT relative to CHUMP_REPO, so the worktree
    # needs its own copy (a real worktree is a full checkout; this temp one
    # isn't). Copy only what the hook needs to launch.
    cp "$LOOP" "$WT3/scripts/setup/urgent-inbox-poll-loop.sh"
    chmod +x "$WT3/scripts/setup/urgent-inbox-poll-loop.sh"
    PIDFILE="$WT3/.chump-locks/urgent-inbox-poll-loop.pid"
    # Run the hook from inside the worktree (as a real session would) so a
    # regression that inherits the hook's cwd would land the loop in $WT3.
    ( cd "$WT3" && CHUMP_REPO="$WT3" CHUMP_AMBIENT_LOG="$WORK/ambient.jsonl" \
        bash "$HOOK" >/dev/null 2>&1 )
    [[ -f "$PIDFILE" ]] || fail "AC2: hook did not write the loop pidfile"
    HOOK_LOOP_PID="$(head -1 "$PIDFILE" | tr -d '[:space:]')"
    [[ -n "$HOOK_LOOP_PID" ]] || fail "AC2: empty loop pid in pidfile"
    LOOP_PID="$HOOK_LOOP_PID"
    alive "$LOOP_PID" || fail "AC2: hook-launched loop is not running"
    LOOP_CWD="$(readlink "/proc/$LOOP_PID/cwd" 2>/dev/null || true)"
    case "$LOOP_CWD" in
        "$WT3"|"$WT3"/*)
            fail "AC2: loop cwd ($LOOP_CWD) is inside the worktree — it will pin it against the reaper" ;;
    esac
    echo "ok AC2: hook-launched loop cwd ($LOOP_CWD) is outside the worktree"
    kill "$LOOP_PID" 2>/dev/null; LOOP_PID=""
else
    echo "skip AC2 cwd introspection: /proc not readable on this host"
fi

echo "PASS: test-urgent-inbox-poll-loop-lifetime.sh"
exit 0
