#!/usr/bin/env bash
# test-dispatch-child-lifetime.sh — INFRA-8198
#
# Runtime smoke: a fake `claude` executable stands in for the real
# headless work child. Under a 3s subagent budget, `chump dispatch`
# must exit non-zero quickly AND the fake child must not survive it —
# this is the bug INFRA-8198 closes (a dispatch that printed preflight
# lines, exited 0, and left its claude -p child running with PPID 1 for
# 25+ minutes past the 1800s budget).
#
# SKIPs (exit 0) when no built `chump` binary is available, so this stays
# cheap in fast-checks; the real coverage is tests/dispatch_child_lifetime.rs
# (run by `cargo test`) plus this runner under full CI once a binary exists.

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
    echo "--- stdout ---" >&2
    cat "$WORK/stdout.log" >&2 2>/dev/null || true
    echo "--- stderr ---" >&2
    cat "$WORK/stderr.log" >&2 2>/dev/null || true
    exit 1
}

git init --quiet --bare "$WORK/origin.git"
git init --quiet -b main "$WORK/repo"
git -C "$WORK/repo" config user.email infra-8198@test.invalid
git -C "$WORK/repo" config user.name infra-8198-test
echo "infra-8198 fixture" > "$WORK/repo/README.md"
git -C "$WORK/repo" add README.md
git -C "$WORK/repo" commit -q -m init
git -C "$WORK/repo" remote add origin "$WORK/origin.git"
git -C "$WORK/repo" push -q origin main
git -C "$WORK/repo" fetch -q origin

export CHUMP_REPO="$WORK/repo"
export CHUMP_HOME="$WORK/repo"
export CHUMP_WORKTREE_ROOT="$WORK/repo"
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

GAP_OUT="$("$BIN" gap reserve --domain INFRA --title "INFRA-8198 dispatch-child-lifetime smoke gap" --priority P2 --effort xs --force 2>&1)"
GAP_ID="$(printf '%s\n' "$GAP_OUT" | grep -o 'INFRA-[0-9]\+' | head -1)"
if [[ -z "$GAP_ID" ]]; then
    echo "SKIP: could not reserve a fixture gap (output: $GAP_OUT)"
    exit 0
fi

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
PIDFILE="$WORK/claude.pid"
cat > "$FAKEBIN/claude" <<EOF
#!/bin/sh
echo \$\$ > "$PIDFILE"
sleep 120
EOF
chmod +x "$FAKEBIN/claude"

START="$(date +%s)"
PATH="$FAKEBIN:$PATH" \
    CHUMP_SUBAGENT_BUDGET_S=3 \
    CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S=3 \
    "$BIN" dispatch "$GAP_ID" --backend headless --prompt x \
    >"$WORK/stdout.log" 2>"$WORK/stderr.log"
STATUS=$?
END="$(date +%s)"
ELAPSED=$((END - START))

[[ "$STATUS" -ne 0 ]] || fail "dispatch exited 0 under a 3s budget (expected non-zero)"
[[ "$ELAPSED" -lt 60 ]] || fail "dispatch took ${ELAPSED}s (expected under 60s)"

if [[ ! -f "$PIDFILE" ]]; then
    fail "fake claude never wrote its pidfile — dispatch never spawned it"
fi
CPID="$(cat "$PIDFILE")"
sleep 5
if kill -0 "$CPID" 2>/dev/null; then
    fail "fake claude pid $CPID still alive 5s after dispatch exited"
fi

grep -q '\[dispatch\] ' "$WORK/stderr.log" || fail "stderr missing '[dispatch] ' line"
grep -q 'exit=' "$WORK/stderr.log" || fail "stderr missing 'exit=' token"
grep -q 'child_alive_at_exit=false' "$WORK/stderr.log" || fail "stderr missing 'child_alive_at_exit=false'"

echo "[PASS] dispatch child lifetime: budget-killed fake claude did not survive, exit line present"
