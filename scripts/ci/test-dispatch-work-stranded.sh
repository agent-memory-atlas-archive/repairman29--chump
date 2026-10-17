#!/usr/bin/env bash
# test-dispatch-work-stranded.sh — INFRA-8203
#
# Runtime fixture: a fake `claude` stands in for the headless work child of
# `chump dispatch`. It records its argv and stdin, edits a tracked file and
# adds a new one in its worktree, and exits 0 WITHOUT committing — the
# INFRA-8183 round-3 shape (agent ends its turn with everything uncommitted).
#   AC1: argv carries --disallowedTools with ScheduleWakeup and Monitor, and
#        the prompt on stdin carries the headless epilogue
#   AC2: dispatch emits kind=dispatch_work_stranded with the diff stat, writes
#        <GAP>.stranded.patch under the dispatch-logs dir, and does not ship
#   AC3: the epilogue demands a commit before any wait over 60s and a
#        wall-clock cap on every local build
#
# SKIPs (exit 0) when no built `chump` binary is available, like the sibling
# test-dispatch-child-lifetime.sh.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BIN="${CHUMP_BIN:-}"
if [[ -z "$BIN" ]]; then
    if [[ -x "$REPO_ROOT/target/release/chump" ]]; then
        BIN="$REPO_ROOT/target/release/chump"
    elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
        BIN="$REPO_ROOT/target/debug/chump"
    fi
fi
if [[ -z "$BIN" ]]; then
    echo "SKIP: no built chump binary (set CHUMP_BIN or build target/{release,debug}/chump)"
    exit 0
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
    echo "[FAIL] $1" >&2
    echo "--- stderr ---" >&2
    tail -40 "$WORK/stderr.log" >&2 2>/dev/null || true
    exit 1
}

git init --quiet --bare "$WORK/origin.git"
git init --quiet -b main "$WORK/repo"
git -C "$WORK/repo" config user.email infra-8203@test.invalid
git -C "$WORK/repo" config user.name infra-8203-test
echo "infra-8203 fixture" > "$WORK/repo/README.md"
git -C "$WORK/repo" add README.md
git -C "$WORK/repo" commit -q -m init
git -C "$WORK/repo" remote add origin "$WORK/origin.git"
git -C "$WORK/repo" push -q origin main
git -C "$WORK/repo" fetch -q origin

export CHUMP_REPO="$WORK/repo"
export CHUMP_HOME="$WORK/repo"
export CHUMP_WORKTREE_ROOT="$WORK/repo"
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_AMBIENT_LOG="$WORK/ambient.jsonl"
export CHUMP_DISPATCH_LOGS_DIR="$WORK/dispatch-logs"

GAP_OUT="$("$BIN" gap reserve --domain INFRA --title "INFRA-8203 dispatch work stranded fixture" --priority P2 --effort xs --force 2>&1)"
GAP_ID="$(printf '%s\n' "$GAP_OUT" | grep -o 'INFRA-[0-9]\+' | head -1)"
if [[ -z "$GAP_ID" ]]; then
    echo "SKIP: could not reserve a fixture gap (output: $GAP_OUT)"
    exit 0
fi

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$WORK/claude.argv"
cat > "$WORK/claude.stdin"
echo "edited by the agent" >> README.md
echo "fn stranded() {}" > stranded_work.rs
exit 0
EOF
chmod +x "$FAKEBIN/claude"

PATH="$FAKEBIN:$PATH" \
    CHUMP_SUBAGENT_BUDGET_S=120 \
    "$BIN" dispatch "$GAP_ID" --backend headless --prompt "do the gap" \
    >"$WORK/stdout.log" 2>"$WORK/stderr.log"
STATUS=$?

[[ -f "$WORK/claude.argv" ]] || fail "fake claude never ran"

# AC1: flag
ARGV="$(cat "$WORK/claude.argv")"
case "$ARGV" in
    *"--disallowedTools"*) ;;
    *) fail "claude argv has no --disallowedTools: $ARGV" ;;
esac
case "$ARGV" in
    *ScheduleWakeup*Monitor*|*Monitor*ScheduleWakeup*) ;;
    *) fail "--disallowedTools does not name ScheduleWakeup and Monitor: $ARGV" ;;
esac

# AC1 + AC3: epilogue on stdin
PROMPT="$(cat "$WORK/claude.stdin")"
for needle in "do the gap" "ScheduleWakeup and Monitor are disabled" \
    "COMMIT before any wait longer than 60 seconds" "wall-clock cap"; do
    case "$PROMPT" in
        *"$needle"*) ;;
        *) fail "headless prompt missing: $needle" ;;
    esac
done

# AC2: stranded detection, patch, event, no ship
[[ "$STATUS" -ne 0 ]] || fail "dispatch exited 0 although the work was stranded"
PATCH="$WORK/dispatch-logs/$GAP_ID.stranded.patch"
[[ -s "$PATCH" ]] || fail "no $GAP_ID.stranded.patch under the dispatch-logs dir"
PATCH_BODY="$(cat "$PATCH")"
case "$PATCH_BODY" in
    *"edited by the agent"*) ;;
    *) fail "patch lacks the tracked-file edit" ;;
esac
case "$PATCH_BODY" in
    *"stranded_work.rs"*) ;;
    *) fail "patch lacks the untracked new file" ;;
esac
AMB="$(cat "$WORK/ambient.jsonl" 2>/dev/null || true)"
case "$AMB" in
    *'"kind":"dispatch_work_stranded"'*) ;;
    *) fail "no kind=dispatch_work_stranded in ambient" ;;
esac
case "$AMB" in
    *'"diffstat":"'*README.md*) ;;
    *) fail "dispatch_work_stranded carries no diff stat" ;;
esac
ERR="$(cat "$WORK/stderr.log")"
case "$ERR" in
    *"work stranded"*) ;;
    *) fail "stderr does not report the stranded work" ;;
esac

echo "[PASS] headless dispatch: wakeup tools disallowed, epilogue present, stranded work saved + reported, no ship"
