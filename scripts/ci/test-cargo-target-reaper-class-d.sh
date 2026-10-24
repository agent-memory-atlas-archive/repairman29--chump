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

# ── INFRA-8578: cache_lookup_pr_state_by_branch (open, merged, closed, miss) ──
echo "--- INFRA-8578: cache_lookup_pr_state_by_branch + Class D delegation ---"
# AC2: cargo-target-reaper.sh Class D delegates to cache_lookup_pr_state_by_branch
# instead of carrying a private sqlite3 SELECT ... FROM pr_state query.
if grep -q "cache_lookup_pr_state_by_branch" "$REAPER" && ! awk '/^_classd_pr_merged_or_closed\(\)/,/^\}/' "$REAPER" | grep -q "sqlite3"; then
    pass "INFRA-8578 AC2: _classd_pr_merged_or_closed uses cache_lookup_pr_state_by_branch (no private sqlite query)"
else
    fail "INFRA-8578 AC2: _classd_pr_merged_or_closed still contains a private sqlite query or lacks cache_lookup_pr_state_by_branch"
fi

grep -q "cache_lookup_pr_state_by_branch" "$REPO_ROOT/CLAUDE.md" \
    || fail "INFRA-8578: CLAUDE.md does not document cache_lookup_pr_state_by_branch"
pass "INFRA-8578: CLAUDE.md documents cache_lookup_pr_state_by_branch"

CACHE_FIXTURE_DB="$TMP/infra-8578-cache.db"
sqlite3 "$CACHE_FIXTURE_DB" <<'SQL'
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT,
    merged_at TEXT,
    raw_payload_json TEXT
);
INSERT INTO pr_state VALUES (801, 'claude/branch-open', NULL, '{"number": 801, "state": "open"}');
INSERT INTO pr_state VALUES (802, 'claude/branch-merged', '2026-10-24T08:00:00Z', '{"number": 802, "state": "closed", "merged_at": "2026-10-24T08:00:00Z"}');
INSERT INTO pr_state VALUES (803, 'claude/branch-closed', NULL, '{"number": 803, "state": "closed"}');
SQL

# Source github_cache.sh in a subshell with a stubbed gh for the cache-miss fallback.
STUB_GH_8578="$TMP/bin-8578"
mkdir -p "$STUB_GH_8578"
cat > "$STUB_GH_8578/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    case "$*" in
        *claude/branch-miss-merged*)
            echo '[{"number": 804, "state": "MERGED"}]'
            exit 0
            ;;
        *claude/branch-miss-none*)
            echo '[]'
            exit 0
            ;;
    esac
fi
exit 1
EOF
chmod +x "$STUB_GH_8578/gh"

# shellcheck source=../coord/lib/github_cache.sh
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"

out_open="$(CHUMP_CACHE_DB="$CACHE_FIXTURE_DB" PATH="$STUB_GH_8578:$PATH" cache_lookup_pr_state_by_branch "claude/branch-open")"
[[ "$out_open" == $'801\topen' ]] || fail "INFRA-8578 AC1/AC3: expected '801\topen' for cached open PR, got '$out_open'"
pass "INFRA-8578 AC1/AC3: cached open PR returns 801<TAB>open"

out_merged="$(CHUMP_CACHE_DB="$CACHE_FIXTURE_DB" PATH="$STUB_GH_8578:$PATH" cache_lookup_pr_state_by_branch "claude/branch-merged")"
[[ "$out_merged" == $'802\tmerged' ]] || fail "INFRA-8578 AC1/AC3: expected '802\tmerged' for cached merged PR, got '$out_merged'"
pass "INFRA-8578 AC1/AC3: cached merged PR returns 802<TAB>merged"

out_closed="$(CHUMP_CACHE_DB="$CACHE_FIXTURE_DB" PATH="$STUB_GH_8578:$PATH" cache_lookup_pr_state_by_branch "claude/branch-closed")"
[[ "$out_closed" == $'803\tclosed' ]] || fail "INFRA-8578 AC1/AC3: expected '803\tclosed' for cached closed PR, got '$out_closed'"
pass "INFRA-8578 AC1/AC3: cached closed PR returns 803<TAB>closed"

out_miss_hit="$(CHUMP_CACHE_DB="$CACHE_FIXTURE_DB" PATH="$STUB_GH_8578:$PATH" cache_lookup_pr_state_by_branch "claude/branch-miss-merged")"
[[ "$out_miss_hit" == $'804\tmerged' ]] || fail "INFRA-8578 AC1/AC3: expected '804\tmerged' on cache miss REST fallback, got '$out_miss_hit'"
pass "INFRA-8578 AC1/AC3: cache miss falls back to REST and returns 804<TAB>merged"

if CHUMP_CACHE_DB="$CACHE_FIXTURE_DB" PATH="$STUB_GH_8578:$PATH" cache_lookup_pr_state_by_branch "claude/branch-miss-none" >/dev/null 2>&1; then
    fail "INFRA-8578 AC1/AC3: expected non-zero rc when branch has no PR in cache or REST"
else
    pass "INFRA-8578 AC1/AC3: cache miss with no PR returns non-zero"
fi

# ── RESILIENT-1641: idle open-PR target/ + .cargo-build-target/, live-cwd & active-cargo skip ──
echo "--- RESILIENT-1641: idle open-PR target/ + .cargo-build-target/ reap, live-cwd & active-cargo skip ---"
backdate_3h() {
    local secs=10800 e ts
    e=$(( $(date +%s) - secs ))
    ts="$(date -d "@$e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$e" +%Y%m%d%H%M.%S)"
    touch -t "$ts" "$@"
}

mk_open_idle_wt() {
    local name="$1" branch="$2"
    local wt
    wt="$(mk_wt "$name" "$branch")"
    mkdir -p "$wt/.cargo-build-target/debug"
    echo build-artifact > "$wt/.cargo-build-target/debug/chump"
    local p
    while IFS= read -r p; do backdate_3h "$p"; done < <(
        find "$wt/target" "$wt/.cargo-test-target" "$wt/.cargo-build-target" -depth)
    printf '%s' "$wt"
}

WT_R1641_IDLE="$(mk_open_idle_wt test-1641 chump/test-1641-open)"
WT_R1641_CWD="$(mk_open_idle_wt test-1642 chump/test-1642-open)"
WT_R1641_CARGO="$(mk_open_idle_wt test-1643 chump/test-1643-open)"

# Live cwd inside WT_R1641_CWD
( cd "$WT_R1641_CWD" && exec sleep 300 ) >/dev/null 2>&1 &
R1641_CWD_PID=$!

# Active cargo running against WT_R1641_CARGO (cwd outside, argv names worktree)
( cd "$TMP" && exec -a "cargo check --manifest-path $WT_R1641_CARGO/Cargo.toml" sleep 300 ) >/dev/null 2>&1 &
R1641_CARGO_PID=$!
sleep 0.4

# 1. Default dry-run: does NOT delete WT_R1641_IDLE's target/ or .cargo-build-target/
HOME="$SANDBOX_HOME" \
CHUMP_LOCK_DIR="$FOREIGN_LOCKS" \
CHUMP_STATE_DB="$TMP/foreign-state.db" \
REAPER_REPO_ROOT="$FAKE_REPO" \
CHUMP_WORKTREE_BASE="$WT_BASE" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_REAPER_SAFETY_CHECK=1 \
CHUMP_REAPER_AUTO_EXECUTE_PCT=101 \
    bash "$REAPER" --class-d-only >/dev/null 2>&1 || fail "RESILIENT-1641: dry-run exited non-zero"

[[ -d "$WT_R1641_IDLE/target" && -d "$WT_R1641_IDLE/.cargo-build-target" ]] \
    || fail "RESILIENT-1641: default dry-run deleted target/ or .cargo-build-target/"
pass "RESILIENT-1641: dry-run by default preserves target/ and .cargo-build-target/"

# 2. Auto-execute under CHUMP_REAPER_AUTO_EXECUTE_PCT=0 (or --execute) reaps idle open-PR target/ + .cargo-build-target/
: > "$AMBIENT"
OUT_R1641="$(
    HOME="$SANDBOX_HOME" \
    CHUMP_LOCK_DIR="$FOREIGN_LOCKS" \
    CHUMP_STATE_DB="$TMP/foreign-state.db" \
    REAPER_REPO_ROOT="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_REAPER_SAFETY_CHECK=1 \
    CHUMP_REAPER_AUTO_EXECUTE_PCT=0 \
        bash "$REAPER" --class-d-only 2>&1
)" || fail "RESILIENT-1641: auto-execute exited non-zero"
echo "$OUT_R1641" | sed 's/^/    /'

kill "$R1641_CWD_PID" "$R1641_CARGO_PID" 2>/dev/null || true

# Idle open-PR worktree: target/ and .cargo-build-target/ removed, sources and .git intact
[[ ! -d "$WT_R1641_IDLE/target" ]]               || fail "RESILIENT-1641: idle open-PR target/ not removed"
[[ ! -d "$WT_R1641_IDLE/.cargo-build-target" ]]  || fail "RESILIENT-1641: idle open-PR .cargo-build-target/ not removed"
[[ -f "$WT_R1641_IDLE/main.rs" ]]                || fail "RESILIENT-1641: idle open-PR sources removed!"
[[ -d "$WT_R1641_IDLE/.git" ]]                   || fail "RESILIENT-1641: idle open-PR .git removed!"
pass "RESILIENT-1641: idle open-PR worktree target/ + .cargo-build-target/ removed; sources and .git intact"

# Live-cwd worktree skipped
[[ -d "$WT_R1641_CWD/target" && -d "$WT_R1641_CWD/.cargo-build-target" ]] \
    || fail "RESILIENT-1641: live-cwd worktree build dirs were removed"
pass "RESILIENT-1641: live-cwd worktree skipped"

# Active-cargo worktree skipped
[[ -d "$WT_R1641_CARGO/target" && -d "$WT_R1641_CARGO/.cargo-build-target" ]] \
    || fail "RESILIENT-1641: active-cargo worktree build dirs were removed"
pass "RESILIENT-1641: active-cargo worktree skipped"

# One kind=cargo_target_reaped event per dir with bytes_freed > 0
IDLE_REAL="$(cd -P "$WT_R1641_IDLE" && pwd -P)"
python3 - "$AMBIENT" "$IDLE_REAL/target" "$IDLE_REAL/.cargo-build-target" <<'PY' || fail "RESILIENT-1641: missing cargo_target_reaped events with bytes_freed"
import json, sys
amb, want_paths = sys.argv[1], sys.argv[2:]
by_path = {}
for line in open(amb):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("kind") == "cargo_target_reaped":
        by_path[e.get("path")] = e
for p in want_paths:
    if p not in by_path:
        sys.exit(f"missing cargo_target_reaped event for {p}")
    if int(by_path[p].get("bytes_freed", 0)) <= 0:
        sys.exit(f"expected bytes_freed > 0 for {p}, got {by_path[p]}")
PY
pass "RESILIENT-1641: emits one kind=cargo_target_reaped event per dir with bytes_freed > 0"

echo "=== all Class-D tests passed ==="
