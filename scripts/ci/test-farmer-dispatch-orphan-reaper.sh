#!/usr/bin/env bash
# test-farmer-dispatch-orphan-reaper.sh — INFRA-8198
#
# Exercises reap_dispatch_orphans() (scripts/coord/lib/dispatch-orphan-reaper.sh)
# against a fake `claude -p` process whose cwd sits under a fake
# `.claude/worktrees/` dispatch dir and whose parent is the test's own
# shell (not a live `chump dispatch`) — i.e. exactly the orphan shape the
# reaper exists to catch. With CHUMP_DISPATCH_ORPHAN_MIN_AGE_S=0 the
# reaper should kill it immediately and append a dispatch_orphan_reaped
# ambient line.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

fail() {
    echo "[FAIL] $1" >&2
    exit 1
}

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${FAKE_PID:-}" ]] && kill -KILL "$FAKE_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

WT_DIR="$WORK/.claude/worktrees/infra-9996"
mkdir -p "$WT_DIR"

# setsid detaches so `ps -o ppid=` doesn't read back a shell-builtin pid
# that's gone the moment this subshell returns; `exec -a` renames argv[0]
# so `pgrep -f '^claude -p'` matches it like it would a real `claude -p`.
setsid bash -c 'cd "'"$WT_DIR"'" && exec -a "claude -p fake" sleep 300' &
FAKE_PID=$!
# setsid re-parents to its own session leader (a grandchild of this
# script), so poll briefly for the actual `claude -p`-named pid under that
# cwd rather than assuming $! is it.
sleep 0.3
REAL_PID="$(pgrep -f '^claude -p fake' | head -1)"
[[ -n "$REAL_PID" ]] || fail "could not find the fake claude -p process via pgrep"

export AMBIENT="$WORK/ambient.jsonl"
export LOCK_DIR="$WORK"
: > "$AMBIENT"

# shellcheck source=scripts/coord/lib/dispatch-orphan-reaper.sh
source "$REPO_ROOT/scripts/coord/lib/dispatch-orphan-reaper.sh"

CHUMP_DISPATCH_ORPHAN_MIN_AGE_S=0 CHUMP_DISPATCH_ORPHAN_GRACE_S=1 reap_dispatch_orphans

sleep 1
if kill -0 "$REAL_PID" 2>/dev/null; then
    fail "fake claude -p pid=$REAL_PID is still alive after reap_dispatch_orphans"
fi

if ! grep -q '"kind":"dispatch_orphan_reaped"' "$AMBIENT"; then
    fail "no dispatch_orphan_reaped line in $AMBIENT: $(cat "$AMBIENT")"
fi
if ! grep -q "\"pid\":$REAL_PID" "$AMBIENT"; then
    fail "dispatch_orphan_reaped line missing pid=$REAL_PID: $(cat "$AMBIENT")"
fi

echo "[PASS] reap_dispatch_orphans killed the fake claude -p orphan and emitted dispatch_orphan_reaped"
