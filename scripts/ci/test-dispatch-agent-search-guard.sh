#!/usr/bin/env bash
# test-dispatch-agent-search-guard.sh — ZERO-WASTE-133
#
# Runtime fixture: a fake `claude` stands in for the headless work child of
# `chump dispatch` and records what it was handed:
#   (a) its cwd (the dispatch worktree) carries a .ignore that excludes
#       .cargo-build-target/ and target/ from rg / fd / ag (and ugrep with
#       --ignore-files=.ignore), and the file does not show in git status;
#   (b) its env carries the per-tool-call timeout knobs Claude Code honours:
#       CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 (a timed-out call is killed,
#       not auto-backgrounded), BASH_DEFAULT_TIMEOUT_MS, BASH_MAX_TIMEOUT_MS.
# The stalled-call watchdog itself is covered by the cargo unit test
# zero_waste_133_stalled_tool_call_is_killed_and_agent_continues.
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
git -C "$WORK/repo" config user.email zero-waste-133@test.invalid
git -C "$WORK/repo" config user.name zero-waste-133-test
echo "zero-waste-133 fixture" > "$WORK/repo/README.md"
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
unset CHUMP_DISPATCH_TOOL_CALL_TIMEOUT_SECS

GAP_OUT="$("$BIN" gap reserve --domain INFRA --title "ZERO-WASTE-133 dispatch agent search guard fixture" --priority P2 --effort xs --force 2>&1)"
GAP_ID="$(printf '%s\n' "$GAP_OUT" | grep -o 'INFRA-[0-9]\+' | head -1)"
if [[ -z "$GAP_ID" ]]; then
    echo "SKIP: could not reserve a fixture gap (output: $GAP_OUT)"
    exit 0
fi

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<EOF
#!/bin/sh
env > "$WORK/claude.env"
pwd > "$WORK/claude.cwd"
[ -f .ignore ] && cp .ignore "$WORK/claude.ignore"
git status --porcelain --untracked-files=all > "$WORK/claude.status" 2>&1
sleep 120
EOF
chmod +x "$FAKEBIN/claude"

PATH="$FAKEBIN:$PATH" \
    CHUMP_SUBAGENT_BUDGET_S=3 \
    CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S=3 \
    "$BIN" dispatch "$GAP_ID" --backend headless --prompt x \
    >"$WORK/stdout.log" 2>"$WORK/stderr.log"

[[ -f "$WORK/claude.env" ]] || fail "fake claude never ran (no env capture)"

# (a) ignore file in the worktree
[[ -f "$WORK/claude.ignore" ]] || fail "dispatch worktree $(cat "$WORK/claude.cwd" 2>/dev/null) has no .ignore"
IGN="$(cat "$WORK/claude.ignore")"
for d in "/.cargo-build-target/" "/target/"; do
    case "$IGN" in
        *"$d"*) ;;
        *) fail ".ignore does not exclude $d: $IGN" ;;
    esac
done
STATUS_OUT="$(cat "$WORK/claude.status")"
case "$STATUS_OUT" in
    *".ignore"*) fail ".ignore shows in git status (would be committed): $STATUS_OUT" ;;
esac

# (b) per-tool-call timeout env
ENV_OUT="$(cat "$WORK/claude.env")"
for kv in "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1" "BASH_DEFAULT_TIMEOUT_MS=300000" "BASH_MAX_TIMEOUT_MS=1200000"; do
    case "$ENV_OUT" in
        *"$kv"*) ;;
        *) fail "spawn env missing $kv" ;;
    esac
done

echo "[PASS] dispatch worktree carries .ignore (untracked-invisible) and claude -p gets the per-tool-call timeout env"
