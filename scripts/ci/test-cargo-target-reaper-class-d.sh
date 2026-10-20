#!/usr/bin/env bash
# test-cargo-target-reaper-class-d.sh — RESILIENT-1620
#
# Validates Class D of cargo-target-reaper.sh + the disk-health-monitor
# low-disk trigger:
#   AC1: a lease-less dispatch worktree whose PR merged loses target/ and
#        .cargo-test-target/ within one reaper cycle; source untouched.
#   AC2: a worktree whose PR is open, OR has a live lease, OR has a process
#        cwd inside, is NEVER reaped.
#   AC3: kind=cargo_target_reaped with class=D is emitted.
#   AC4: disk-health-monitor triggers a reaper run when free < 10%.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"
DISK_MON="${REPO_ROOT}/scripts/ops/disk-health-monitor.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-cargo-target-reaper-class-d.sh ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${CWD_PID:-}" ]] && kill "$CWD_PID" 2>/dev/null || true' EXIT

FAKE_REPO="$TMP/repo"
WT_BASE="$FAKE_REPO/.claude/worktrees"
mkdir -p "$WT_BASE" "$FAKE_REPO/.chump-locks"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

# stub gh: `gh pr list --head <branch> --state all --json ...` → JSON by branch.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
branch=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--head" ]] && branch="$a"
    prev="$a"
done
case "$branch" in
    *merged*|*closed*) echo '[{"number":111,"state":"MERGED"}]' ;;
    *open*)            echo '[{"number":222,"state":"OPEN"}]' ;;
    *)                 echo '[]' ;;
esac
GH
chmod +x "$BIN/gh"
# RESILIENT-1635: Class D takes the node build lane lock and passes
# `chump admit cargo` before deleting anything. Stub chump to admit. The lock
# path is fixed at $HOME/.chump/architect-lane.lock (no env override), so the
# reaper runs under a sandbox HOME and takes the sandbox's lock, never the real
# ~/.chump one.
cat > "$BIN/chump" <<'CHUMP'
#!/usr/bin/env bash
exit 0
CHUMP
chmod +x "$BIN/chump"
SANDBOX_HOME="$TMP/home"
# shellcheck source=scripts/coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
chump_test_sandbox_setup "$SANDBOX_HOME"
export PATH="$BIN:$PATH"
# Force cache-miss so the gh fallback path is exercised deterministically.
export CHUMP_CACHE_DB="$TMP/nonexistent-cache.db"

# Helper: make a fake dispatch worktree that is a real git repo on <branch>,
# with target/, .cargo-test-target/, and a source file.
mk_wt() {
    local name="$1" branch="$2"
    local wt="$WT_BASE/$name"
    mkdir -p "$wt"
    git -C "$wt" init -q
    git -C "$wt" config user.email t@t.t
    git -C "$wt" config user.name t
    git -C "$wt" checkout -q -b "$branch"
    echo "fn main() {}" > "$wt/main.rs"
    git -C "$wt" add -A
    git -C "$wt" -c commit.gpgsign=false commit -q -m init
    mkdir -p "$wt/target/debug" "$wt/.cargo-test-target/debug"
    echo artifact > "$wt/target/debug/chump"
    echo artifact > "$wt/.cargo-test-target/debug/chump"
    printf '%s' "$wt"
}

WT_MERGED="$(mk_wt merged chump/resilient-merged)"
WT_OPEN="$(mk_wt open chump/resilient-open)"
WT_LEASED="$(mk_wt leased chump/resilient-merged-leased)"
WT_CWD="$(mk_wt cwdheld chump/resilient-merged-cwd)"

# AC2 setup: a fresh lease naming WT_LEASED (merged branch, but protected).
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FAKE_REPO/.chump-locks/lease-leased.json" <<EOF
{"worktree":"$WT_LEASED","gap_id":"RESILIENT-TEST","heartbeat_at":"$NOW_ISO","taken_at":"$NOW_ISO"}
EOF

# AC2 setup: a live process whose cwd is inside WT_CWD.
( cd "$WT_CWD" && exec sleep 300 ) &
CWD_PID=$!
sleep 0.5

# Regression pin: CI fast-checks exports CHUMP_LOCK_DIR=<workspace>/.chump-locks,
# a store that does NOT hold this fixture's lease. Class D must still find the
# lease in the scanned repo's own .chump-locks. Point the env store at an empty
# foreign dir on every runner so the mismatch is always exercised.
FOREIGN_LOCKS="$TMP/foreign-locks"
mkdir -p "$FOREIGN_LOCKS"

run_reaper() {
    HOME="$SANDBOX_HOME" \
    CHUMP_LOCK_DIR="$FOREIGN_LOCKS" \
    CHUMP_STATE_DB="$TMP/foreign-state.db" \
    REAPER_REPO_ROOT="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_REAPER_SAFETY_CHECK=1 \
        bash "$REAPER" --class-d-only --execute 2>&1
}

echo "--- Class D reap (merged → reap; open/leased/cwd → keep) ---"
OUT="$(run_reaper)" || fail "reaper exited non-zero"
echo "$OUT" | sed 's/^/    /'

# AC1: merged worktree build dirs gone, source intact.
[[ ! -d "$WT_MERGED/target" ]]            || fail "AC1: merged target/ not reaped"
[[ ! -d "$WT_MERGED/.cargo-test-target" ]] || fail "AC1: merged .cargo-test-target/ not reaped"
[[ -f "$WT_MERGED/main.rs" ]]             || fail "AC1: merged source removed!"
[[ -d "$WT_MERGED/.git" ]]                || fail "AC1: merged .git removed!"
pass "AC1: merged worktree target/ + .cargo-test-target/ reaped, source kept"

# AC2: open PR worktree untouched.
[[ -d "$WT_OPEN/target" ]]                 || fail "AC2: open-PR target/ was reaped"
[[ -d "$WT_OPEN/.cargo-test-target" ]]     || fail "AC2: open-PR .cargo-test-target/ was reaped"
pass "AC2: open-PR worktree kept"

# AC2: leased worktree untouched (even though its branch is 'merged').
[[ -d "$WT_LEASED/target" ]]               || fail "AC2: leased worktree target/ was reaped"
pass "AC2: live-lease worktree kept"

# AC2: cwd-held worktree untouched.
[[ -d "$WT_CWD/target" ]]                  || fail "AC2: cwd-held worktree target/ was reaped"
pass "AC2: process-cwd-inside worktree kept"

# AC3: ambient event with class=D emitted.
grep -q '"kind":"cargo_target_reaped"' "$AMBIENT" || fail "AC3: no cargo_target_reaped event"
grep -q '"class":"D"' "$AMBIENT"                  || fail "AC3: no class=D event"
pass "AC3: cargo_target_reaped class=D emitted"

# ── AC4: disk-health-monitor triggers the reaper under 10% free ──────────────
echo "--- AC4: disk-health-monitor low-disk trigger ---"
MARKER="$TMP/reaper-fired"
STUB_REAPER="$TMP/stub-reaper.sh"
cat > "$STUB_REAPER" <<STUB
#!/usr/bin/env bash
echo "stub-reaper invoked: \$*" >> "$MARKER"
exit 0
STUB
chmod +x "$STUB_REAPER"

FAKEDF="$TMP/fakedf.sh"
cat > "$FAKEDF" <<'DF'
#!/usr/bin/env bash
echo "Filesystem Size Used Avail Capacity Mounted"
echo "/dev/fake 100G 91G 9G 91% /"
DF
chmod +x "$FAKEDF"

DISK_AMBIENT="$TMP/disk-ambient.jsonl"
: > "$DISK_AMBIENT"
CHUMP_AMBIENT_OVERRIDE="$DISK_AMBIENT" \
CHUMP_DISK_MONITOR_DF_CMD="bash $FAKEDF" \
CHUMP_DISK_CARGO_REAPER_SCRIPT="$STUB_REAPER" \
CHUMP_DISK_AUTO_REMEDIATE=1 \
    bash "$DISK_MON" >/dev/null 2>&1 || true

[[ -f "$MARKER" ]] || fail "AC4: disk-health-monitor did not invoke the cargo-target-reaper at 9% free"
grep -q -- '--class-d-only' "$MARKER" || fail "AC4: reaper not invoked with --class-d-only"
grep -q '"kind":"disk_low_cargo_reaper_triggered"' "$DISK_AMBIENT" \
    || fail "AC4: disk_low_cargo_reaper_triggered not emitted"
pass "AC4: disk-health-monitor fired cargo-target-reaper --class-d-only under 10% free"

echo "=== all Class-D tests passed ==="
