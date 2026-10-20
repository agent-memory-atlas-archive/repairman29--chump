#!/usr/bin/env bash
# test-cargo-target-reaper-class-d-open-idle.sh — RESILIENT-1635
#
# Validates the RESILIENT-1635 extension of cargo-target-reaper Class D: a
# dispatch worktree whose PR is still OPEN also has its build output reaped when
# it is IDLE, and stale bot-merge-active-dispatch-*.path markers are removed.
#
#   (a) an idle open-PR worktree older than 2h loses target/ + .cargo-test-target/,
#       its source files are byte-unchanged, and the class=D reap event carries
#       that path and its byte count;
#   (b) a worktree with a live lease, a process cwd inside, OR a running dispatch
#       for that gap is never touched (one case each);
#   (c) a stale bot-merge-active-dispatch-*.path marker is removed, a fresh one
#       kept, and a stale one whose bot-merge PID is still alive kept;
#   (d) an open-PR worktree with build activity under 2h old is kept, including
#       activity deep in target/ that leaves the top-level mtime old;
#   plus a dirty-source open-PR worktree is kept (Chief rule 2026-10-19 11:55Z).
#
# Fail-closed fixtures (review of 5c75329dc), each killed by its own mutant:
#   (e) unknown / no-PR state is kept (not treated as open);
#   (f) gh failing is kept, even when it printed an OPEN line before failing;
#   (g) a symlinked .claude/worktrees entry is kept and the checkout it points
#       at keeps its target/ byte-for-byte;
#   (h) a suffixed worktree name (resilient-1828-fleet-1-<ts>) with a running
#       `chump dispatch RESILIENT-1828` is kept;
#   (i) a process with CARGO_TARGET_DIR inside the worktree (cwd elsewhere, the
#       pre-push nextest shape) keeps it;
#   (j) a process holding an open file under target/ (cwd elsewhere) keeps it;
#   (k) with the node build lane lock held by another process, nothing at all is
#       deleted; likewise when `chump admit cargo` refuses;
#   (l) an open-PR worktree whose name and branch yield no gap id is kept;
#   (m) a worktree whose target/ is a symlink is kept, link and pointee intact;
#   (n) a symlinked worktree entry that resolves INSIDE the base (an alias of a
#       nested checkout) is still kept: the -L check stands on its own.
#
# Repair-3 fixtures (review of 492aa340e), each killed by its own mutant:
#   (o) structural: the reaper has no ${CHUMP_ARCH...:-} env default and never
#       names the old lane-lock override variable (the lock path is fixed);
#   (k) the lane lock is the one under the sandbox HOME; with it held, a decoy
#       old-override env var aimed at /dev/null or at a free lock changes
#       nothing: still nothing deleted;
#   (p) Linux only: a same-uid NON-DUMPABLE process (environ/cwd/fd unreadable)
#       whose cmdline names the worktree and which holds a file open under
#       target/ keeps it (skipped with a message on macOS);
#   (q) M13: with CHUMP_REAPER_SAFETY_CHECK=0 (so wt_has_live_bot_merge is off),
#       a process whose cwd is in the worktree SOURCE tree keeps it;
#   (r) N2: a file held open only under .cargo-test-target (cwd elsewhere, no
#       CARGO_TARGET_DIR) keeps the worktree;
#   (s) N6: a worktree whose .cargo-test-target is a symlink is kept whole;
#   (t) the github cache is parsed with json_extract: a row saying
#       "state": "closed" (json.dumps spacing, REST or webhook shape) reads as
#       closed and is reaped; a row with no parseable state is UNKNOWN and kept
#       even though gh would say OPEN;
#   (u) CARGO_TARGET_DIR spelled through a symlink alias of the worktree keeps
#       it (resolved with cd -P on both platforms), including a value that does
#       not exist yet (its longest existing prefix is resolved).
#
# Repair-4 fixtures (review of e1f03a357), each killed by its own mutant:
#   (v) Linux only, each its own reaper pass AFTER the main pass: a same-uid
#       NON-DUMPABLE process whose argv0 is a build tool (sccache, clippy-driver,
#       then cargo) and whose cmdline does NOT name the worktree keeps an idle
#       worktree and logs "same-uid <tool>" (kills B1, the emptied process-type
#       list, and B2, the inverted uid compare); a blind non-tool process whose
#       argument is "<wt>;" keeps it (path match on the next character not
#       being [A-Za-z0-9._-]); then with every such process killed, and a blind
#       process naming only "<wt>-old" alive, the same worktree IS reaped
#       (skipped with a message on macOS);
#   (w) CARGO_TARGET_DIR spelled <tmp>/not-yet/../repo/.../<wt>/target (".."
#       after a component that does not exist, so cd -P cannot resolve it) keeps
#       the worktree: the value is normalized lexically.
#
# Isolation: the reaper runs with HOME set to a sandbox dir (test-sandbox.sh),
# so its fixed $HOME/.chump/architect-lane.lock resolves inside the sandbox;
# no env var redirects the lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-cargo-target-reaper-class-d-open-idle.sh ==="

command -v flock >/dev/null 2>&1 || fail "flock is required (Class D takes the node build lane lock)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required (the github cache fixtures)"

# ── (o) structural: no CHUMP_ARCH* env default, no lane-lock override ───────
echo "--- (o) the lane lock path takes no env override ---"
ARCH_DEFAULTS="$(grep -nE '[$][{]CHUMP_ARCH[A-Z_]*:-' "$REAPER" || true)"
[[ -z "$ARCH_DEFAULTS" ]] \
    || fail "(o) the reaper has a CHUMP_ARCH* env default (a safety-input bypass): ${ARCH_DEFAULTS}"
LANE_OVERRIDE_REFS="$(grep -n 'CHUMP_ARCH_LANE_LOCK' "$REAPER" || true)"
[[ -z "$LANE_OVERRIDE_REFS" ]] \
    || fail "(o) the reaper still reads the lane-lock override variable: ${LANE_OVERRIDE_REFS}"
pass "(o) no CHUMP_ARCH* env default and no lane-lock override in the reaper"

TMP="$(mktemp -d)"
declare -a BG_PIDS=()
cleanup() {
    local p
    for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT

FAKE_REPO="$TMP/repo"
WT_BASE="$FAKE_REPO/.claude/worktrees"
LOCKS="$FAKE_REPO/.chump-locks"
mkdir -p "$WT_BASE" "$LOCKS"
AMBIENT="$LOCKS/ambient.jsonl"
: > "$AMBIENT"

# stub gh: `gh pr list --head <branch> ...` → OPEN for any branch with "open";
# a branch with "ghfail" prints an OPEN line and then FAILS (exit 1).
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
    *ghfail*)          echo '[{"number":333,"state":"OPEN"}]'; echo "gh: HTTP 502" >&2; exit 1 ;;
    *merged*|*closed*) echo '[{"number":111,"state":"MERGED"}]' ;;
    *open*)            echo '[{"number":222,"state":"OPEN"}]' ;;
    *)                 echo '[]' ;;
esac
GH
chmod +x "$BIN/gh"
# stub chump: `chump admit cargo` admits unless the refuse flag file exists.
ADMIT_REFUSE="$TMP/admit-refuse"
cat > "$BIN/chump" <<CHUMP
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "admit cargo" ]]; then
    [[ -e "$ADMIT_REFUSE" ]] && exit 75
    exit 0
fi
exit 0
CHUMP
chmod +x "$BIN/chump"
export PATH="$BIN:$PATH"
# (t) a github cache holding rows only for the cache fixtures' branches; every
# other branch misses it and takes the gh fallback.
CACHE_DB="$TMP/github_cache.db"
export CHUMP_CACHE_DB="$CACHE_DB"
# The reaper runs under a sandbox HOME, so the node build lane lock it takes
# ($HOME/.chump/architect-lane.lock, a fixed path) is the sandbox's, never the
# real ~/.chump one.
SANDBOX_HOME="$TMP/home"
# shellcheck source=scripts/coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
chump_test_sandbox_setup "$SANDBOX_HOME"
LANE_LOCK="$SANDBOX_HOME/.chump/architect-lane.lock"

# backdate <seconds-ago> <path>... — portable (GNU + BSD) mtime backdate.
backdate() {
    local secs="$1" e ts
    shift
    e=$(( $(date +%s) - secs ))
    ts="$(date -d "@$e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$e" +%Y%m%d%H%M.%S)"
    touch -t "$ts" "$@"
}
THREE_H=$(( 3 * 3600 ))

# mk_repo <dir> <branch> — a real git repo on <branch> with committed source and
# fully backdated build dirs (every file and dir 3h old).
mk_repo() {
    local wt="$1" branch="$2"
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
    local p
    while IFS= read -r p; do backdate "$THREE_H" "$p"; done < <(
        find "$wt/target" "$wt/.cargo-test-target" -depth)
}
# mk_wt <name> <branch> — mk_repo under the scanned worktree base; echoes path.
mk_wt() {
    mk_repo "$WT_BASE/$1" "$2"
    printf '%s' "$WT_BASE/$1"
}

# Distinct gap-id-shaped names (digit suffix) so the dispatch/activity matchers
# can't false-match each other or the parent dispatch's prompt.
WT_REAP="$(mk_wt resilient-1801 chump/resilient-1801-open)"
WT_LEASE="$(mk_wt resilient-1802 chump/resilient-1802-open)"
WT_CWD="$(mk_wt resilient-1803 chump/resilient-1803-open)"
WT_DISPATCH="$(mk_wt resilient-1804 chump/resilient-1804-open)"
WT_DIRTY="$(mk_wt resilient-1805 chump/resilient-1805-open)"
WT_ACTIVE="$(mk_wt resilient-1806 chump/resilient-1806-open)"
WT_NOPR="$(mk_wt resilient-1807 chump/resilient-1807-nopr)"
WT_GHFAIL="$(mk_wt resilient-1808 chump/resilient-1808-ghfail)"
WT_SUFFIX="$(mk_wt resilient-1828-fleet-1-20261019t000000 chump/resilient-1828-fleet-1-20261019t000000-open)"
WT_CTD="$(mk_wt resilient-1810 chump/resilient-1810-open)"
WT_OPENFILE="$(mk_wt resilient-1811 chump/resilient-1811-open)"
WT_DEEP="$(mk_wt resilient-1812 chump/resilient-1812-open)"
WT_NOGAP="$(mk_wt scratch-wt chump/scratch-open)"
WT_LINKTGT="$(mk_wt resilient-1813 chump/resilient-1813-open)"
WT_BLIND="$(mk_wt resilient-1815 chump/resilient-1815-open)"
WT_M13="$(mk_wt resilient-1816 chump/resilient-1816-open)"
WT_N2="$(mk_wt resilient-1817 chump/resilient-1817-open)"
WT_N6="$(mk_wt resilient-1818 chump/resilient-1818-open)"
WT_CACHE_UNK="$(mk_wt resilient-1819 chump/resilient-1819-open)"
WT_CACHE_SHUT="$(mk_wt cachewt-shut chump/cachewt-shut)"
WT_CACHE_HOOK="$(mk_wt cachewt-hook chump/cachewt-hook)"
WT_ALIAS1="$(mk_wt resilient-1820 chump/resilient-1820-open)"
WT_ALIAS2="$(mk_wt resilient-1821 chump/resilient-1821-open)"
WT_DOTDOT="$(mk_wt resilient-1823 chump/resilient-1823-open)"

# (t) cache rows. merged_at is NULL everywhere, so only raw_payload_json says
# what state the PR is in. json.dumps spacing ("state": "closed") on purpose.
sqlite3 "$CACHE_DB" <<'SQL'
CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_ref TEXT, merged_at TEXT, raw_payload_json TEXT);
INSERT INTO pr_state VALUES (901, 'chump/cachewt-shut', NULL, '{"number": 901, "state": "closed"}');
INSERT INTO pr_state VALUES (902, 'chump/cachewt-hook', NULL, '{"action": "closed", "number": 902, "pull_request": {"number": 902, "state": "closed"}}');
INSERT INTO pr_state VALUES (903, 'chump/resilient-1819-open', NULL, '{"number": 903}');
SQL

# (s) N6: WT_N6/.cargo-test-target is a symlink to a build dir elsewhere; its
# target/ is a real, idle dir. The whole worktree must be kept.
ELSEWHERE_CTT="$TMP/elsewhere-ctt"
mkdir -p "$ELSEWHERE_CTT/debug"
echo shared-test-artifact > "$ELSEWHERE_CTT/debug/chump"
backdate "$THREE_H" "$ELSEWHERE_CTT/debug/chump" "$ELSEWHERE_CTT/debug" "$ELSEWHERE_CTT"
rm -rf "$WT_N6/.cargo-test-target"
ln -s "$ELSEWHERE_CTT" "$WT_N6/.cargo-test-target"
_e=$(( $(date +%s) - THREE_H ))
touch -h -t "$(date -d "@$_e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$_e" +%Y%m%d%H%M.%S)" "$WT_N6/.cargo-test-target"

# (m) WT_LINKTGT/target is a symlink to a build dir that is not this worktree's.
ELSEWHERE="$TMP/elsewhere-target"
mkdir -p "$ELSEWHERE/debug"
echo shared-artifact > "$ELSEWHERE/debug/chump"
backdate "$THREE_H" "$ELSEWHERE/debug/chump" "$ELSEWHERE/debug" "$ELSEWHERE"
rm -rf "$WT_LINKTGT/target"
ln -s "$ELSEWHERE" "$WT_LINKTGT/target"
# The link's own mtime is old too, so only the symlink guard can keep it.
_e=$(( $(date +%s) - THREE_H ))
touch -h -t "$(date -d "@$_e" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$_e" +%Y%m%d%H%M.%S)" "$WT_LINKTGT/target"

# (n) .claude/worktrees/resilient-1814 is a symlink to a checkout nested under
# the base (nest/ itself has no build dirs, so the scan never reaps it directly).
NESTED="$WT_BASE/nest/resilient-1814"
mk_repo "$NESTED" chump/resilient-1814-open
ln -s "$NESTED" "$WT_BASE/resilient-1814"

# (g) a symlinked worktree entry pointing at ANOTHER checkout (outside the base).
OTHER="$TMP/other-checkout/resilient-1809"
mk_repo "$OTHER" chump/resilient-1809-open
ln -s "$OTHER" "$WT_BASE/resilient-1809"

# (b) live lease naming WT_LEASE.
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$LOCKS/lease-1802.json" <<EOF
{"worktree":"$WT_LEASE","gap_id":"RESILIENT-1802","heartbeat_at":"$NOW_ISO","taken_at":"$NOW_ISO"}
EOF

# (b) a live process whose cwd is inside WT_CWD.
( cd "$WT_CWD" && exec sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (b) a running `chump dispatch` for WT_DISPATCH's gap (argv names RESILIENT-1804).
( exec -a "chump dispatch RESILIENT-1804 --backend headless" sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (h) a running dispatch for the suffixed worktree's gap, RESILIENT-1828.
( exec -a "chump dispatch RESILIENT-1828 --backend headless" sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (i) the pre-push nextest shape: CARGO_TARGET_DIR inside WT_CTD, cwd elsewhere.
# python3 (not /bin/sleep): macOS hides a platform binary's environment.
# The value is built in a variable first: this is a fixture aiming a build at a
# worktree on purpose, not a script defaulting its own target dir there.
CTD_FIXTURE_VALUE="$WT_CTD/.cargo-test-target"
( cd "$TMP" && CARGO_TARGET_DIR="$CTD_FIXTURE_VALUE" \
    exec python3 -c 'import time; time.sleep(300)' ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (u) CARGO_TARGET_DIR spelled through a symlink alias of the worktree (outside
# the scanned base), cwd elsewhere: an existing path under the alias, and one
# that does not exist yet. python3 so macOS shows the environment.
ln -s "$WT_ALIAS1" "$TMP/alias-1820"
ln -s "$WT_ALIAS2" "$TMP/alias-1821"
CTD_ALIAS1_VALUE="$TMP/alias-1820/target"
CTD_ALIAS2_VALUE="$TMP/alias-1821/not-built-yet/.cargo-test-target"
( cd "$TMP" && CARGO_TARGET_DIR="$CTD_ALIAS1_VALUE" \
    exec python3 -c 'import time; time.sleep(300)' ) >/dev/null 2>&1 &
BG_PIDS+=("$!")
( cd "$TMP" && CARGO_TARGET_DIR="$CTD_ALIAS2_VALUE" \
    exec python3 -c 'import time; time.sleep(300)' ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (w) CARGO_TARGET_DIR with ".." after a component that does not exist: cargo's
# create_dir_all lands it in WT_DOTDOT/target, but cd -P cannot resolve past
# the missing component. cwd elsewhere; python3 so macOS shows the environment.
CTD_DOTDOT_VALUE="$TMP/not-yet-1823/../repo/.claude/worktrees/resilient-1823/target"
( cd "$TMP" && CARGO_TARGET_DIR="$CTD_DOTDOT_VALUE" \
    exec python3 -c 'import time; time.sleep(300)' ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (q) M13: a process whose cwd is in WT_M13's SOURCE tree (not under target/
# or .cargo-test-target/, so an open-file scan of the build dirs never sees it).
mkdir -p "$WT_M13/src"
( cd "$WT_M13/src" && exec sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (r) N2: a file held open ONLY under WT_N2/.cargo-test-target; cwd elsewhere,
# no CARGO_TARGET_DIR in its environment.
# shellcheck disable=SC2016  # $1 expands in the child sh, on purpose
( cd "$TMP" && exec env -u CARGO_TARGET_DIR sh -c \
    'exec 3<"$1" && exec sleep 300' n2 "$WT_N2/.cargo-test-target/debug/chump" ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (p) Linux only: a same-uid NON-DUMPABLE process. prctl(PR_SET_DUMPABLE, 0)
# makes its /proc environ, cwd and fd unreadable to this uid; only cmdline
# stays world-readable. Its cmdline names WT_BLIND and it holds a file open
# under WT_BLIND/target, with CARGO_TARGET_DIR inside WT_BLIND and cwd elsewhere.
BLIND_PID=""
BLIND_IS_BLIND=0
if [[ -d /proc/self ]]; then
    CTD_BLIND_VALUE="$WT_BLIND/target"
    ( cd "$TMP" && CARGO_TARGET_DIR="$CTD_BLIND_VALUE" exec python3 -c '
import ctypes, sys, time
f = open(sys.argv[1], "rb")
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(4, 0, 0, 0, 0) != 0:   # PR_SET_DUMPABLE = 4
    sys.exit(3)
time.sleep(300)
' "$WT_BLIND/target/debug/chump" "$WT_BLIND" ) >/dev/null 2>&1 &
    BLIND_PID="$!"
    BG_PIDS+=("$BLIND_PID")
fi

# (j) a process holding a file open under WT_OPENFILE/target, cwd elsewhere.
( cd "$TMP" && exec 3<"$WT_OPENFILE/target/debug/chump" && exec sleep 300 ) >/dev/null 2>&1 &
BG_PIDS+=("$!")

# (c) markers: one stale (> grace), one fresh (within grace), one stale whose
# bot-merge PID (named in its log path) is still running.
MARK_STALE="$LOCKS/bot-merge-active-dispatch-stale.path"
MARK_FRESH="$LOCKS/bot-merge-active-dispatch-fresh.path"
MARK_LIVE="$LOCKS/bot-merge-active-dispatch-live.path"
( exec -a "bash scripts/coord/bot-merge.sh --gap RESILIENT-1899 --auto-merge" sleep 300 ) >/dev/null 2>&1 &
BM_PID="$!"
BG_PIDS+=("$BM_PID")
echo "/tmp/log-stale" > "$MARK_STALE"
echo "/tmp/log-fresh" > "$MARK_FRESH"
echo "$LOCKS/bot-merge-${BM_PID}.log" > "$MARK_LIVE"
backdate 3600 "$MARK_STALE" "$MARK_LIVE"   # > 15m grace

# (d) WT_ACTIVE: build activity within 2h → keep. Un-backdate its build dirs.
touch "$WT_ACTIVE/target" "$WT_ACTIVE/.cargo-test-target"
# (d) WT_DEEP: only a file deep in target/ is fresh; top-level dirs stay 3h old.
touch "$WT_DEEP/target/debug/chump"

# (dirty) WT_DIRTY: a tracked change in the source tree → keep.
echo "fn main() { /* edited */ }" > "$WT_DIRTY/main.rs"

# Record source checksums to prove the reaper never touches source bytes.
src_sum() { git -C "$1" hash-object main.rs; }
REAP_SRC_BEFORE="$(src_sum "$WT_REAP")"
OTHER_TARGET_BEFORE="$(cat "$OTHER/target/debug/chump")"
REAP_REAL="$(cd -P "$WT_REAP" && pwd -P)"
REAP_TARGET_BYTES="$(du -sk "$REAP_REAL/target" | awk '{print $1 * 1024}')"
REAP_CTT_BYTES="$(du -sk "$REAP_REAL/.cargo-test-target" | awk '{print $1 * 1024}')"

# Regression pin (as in the RESILIENT-1620 test): env lock store points at a
# foreign dir so Class D must find the lease in the SCANNED repo's own store.
FOREIGN_LOCKS="$TMP/foreign-locks"
mkdir -p "$FOREIGN_LOCKS"
sleep 0.5   # let the fixture processes exec

if [[ -n "$BLIND_PID" ]]; then
    kill -0 "$BLIND_PID" 2>/dev/null || fail "(p) the non-dumpable fixture process did not start"
    if ! readlink "/proc/${BLIND_PID}/cwd" >/dev/null 2>&1 \
        && ! { : < "/proc/${BLIND_PID}/environ"; } 2>/dev/null; then
        BLIND_IS_BLIND=1
    fi
fi

# run_reaper [VAR=value...] — run the real reaper, Class D only, under the
# sandbox HOME. Extra VAR=value words are added to its environment (a decoy
# env var, or CHUMP_REAPER_SAFETY_CHECK=0 for (q)).
run_reaper() {
    env HOME="$SANDBOX_HOME" \
    CHUMP_LOCK_DIR="$FOREIGN_LOCKS" \
    CHUMP_STATE_DB="$TMP/foreign-state.db" \
    REAPER_REPO_ROOT="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_REAPER_SAFETY_CHECK=1 \
    CHUMP_REAPER_BOT_MERGE_GRACE_MIN=15 \
    "$@" \
        bash "$REAPER" --class-d-only --execute 2>&1
}

# nothing_deleted <label> — every fixture's build dirs and every marker intact.
nothing_deleted() {
    local w
    for w in "$WT_REAP" "$WT_LEASE" "$WT_CWD" "$WT_DISPATCH" "$WT_DIRTY" "$WT_ACTIVE" \
             "$WT_NOPR" "$WT_GHFAIL" "$WT_SUFFIX" "$WT_CTD" "$WT_OPENFILE" "$WT_DEEP" "$OTHER" \
             "$WT_NOGAP" "$WT_LINKTGT" "$NESTED" "$WT_BLIND" "$WT_M13" "$WT_N2" "$WT_N6" \
             "$WT_CACHE_UNK" "$WT_CACHE_SHUT" "$WT_CACHE_HOOK" "$WT_ALIAS1" "$WT_ALIAS2" \
             "$WT_DOTDOT"; do
        [[ -d "$w/target" && -d "$w/.cargo-test-target" ]] || fail "$1: $w build output was deleted"
    done
    [[ -f "$MARK_STALE" && -f "$MARK_FRESH" && -f "$MARK_LIVE" ]] || fail "$1: a marker was deleted"
    if grep -q '"class":"D"' "$AMBIENT"; then
        fail "$1: a class=D reap event was emitted"
    fi
}

# ── (k) node build lane lock held by another process → nothing deleted ──────
echo "--- (k) lane lock held: whole Class D tick skipped ---"
# The holder execs sleep with the lock fd, so killing that PID drops the lock.
( exec 7>>"$LANE_LOCK" && flock 7 && exec sleep 300 ) >/dev/null 2>&1 &
LOCK_HOLDER="$!"
BG_PIDS+=("$LOCK_HOLDER")
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if flock -n "$LANE_LOCK" true 2>/dev/null; then sleep 0.2; else break; fi
done
flock -n "$LANE_LOCK" true 2>/dev/null && fail "(k) the fixture could not take the sandbox HOME lane lock"
OUT="$(run_reaper)" || fail "reaper exited non-zero (lock held)"
echo "$OUT" | sed 's/^/    /'
nothing_deleted "(k) lock held"
[[ "$OUT" == *"lane lock held"* ]] || fail "(k) skip reason for the held lane lock not logged"
[[ "$OUT" == *"$LANE_LOCK"* ]] || fail "(k) the reaper did not report the sandbox HOME lane lock path"
pass "(k) lane lock held by another process: nothing deleted, reason logged"
# The old test-only override, aimed at /dev/null or at a free lock, must not
# move the lock: HOME's lock is held, so the tick still skips.
FREE_LOCK="$TMP/free-decoy.lock"
for decoy in /dev/null "$FREE_LOCK"; do
    OUT="$(run_reaper CHUMP_ARCH_LANE_LOCK="$decoy")" || fail "reaper exited non-zero (decoy ${decoy})"
    echo "$OUT" | sed 's/^/    /'
    nothing_deleted "(k) lock held, decoy override ${decoy}"
    [[ "$OUT" == *"lane lock held"* ]] || fail "(k) decoy override ${decoy} moved the lane lock"
done
pass "(k) a decoy lane-lock override env var (/dev/null, a free lock) changes nothing"
kill "$LOCK_HOLDER" 2>/dev/null || true
wait "$LOCK_HOLDER" 2>/dev/null || true

# ── (k) chump admit cargo refuses → nothing deleted ─────────────────────────
echo "--- (k) chump admit cargo refused: whole Class D tick skipped ---"
: > "$ADMIT_REFUSE"
OUT="$(run_reaper)" || fail "reaper exited non-zero (admit refused)"
echo "$OUT" | sed 's/^/    /'
nothing_deleted "(k) admit refused"
[[ "$OUT" == *"chump admit cargo refused"* ]] || fail "(k) skip reason for the admit refusal not logged"
pass "(k) chump admit cargo refused: nothing deleted, reason logged"
rm -f "$ADMIT_REFUSE"

echo "--- Class D open-PR idle reap ---"
OUT="$(run_reaper)" || fail "reaper exited non-zero"
echo "$OUT" | sed 's/^/    /'

# (a) idle open-PR worktree reaped; source byte-identical.
[[ ! -d "$WT_REAP/target" ]]             || fail "(a) idle open-PR target/ not reaped"
[[ ! -d "$WT_REAP/.cargo-test-target" ]] || fail "(a) idle open-PR .cargo-test-target/ not reaped"
[[ -f "$WT_REAP/main.rs" ]]              || fail "(a) idle open-PR source removed!"
[[ -d "$WT_REAP/.git" ]]                 || fail "(a) idle open-PR .git removed!"
[[ "$(src_sum "$WT_REAP")" == "$REAP_SRC_BEFORE" ]] || fail "(a) source bytes changed!"
pass "(a) idle open-PR worktree: build output reaped, source byte-unchanged"

# (a) the class=D REAP event itself (not the marker event) names the reaped
# build dir and its byte count.
python3 - "$AMBIENT" "$REAP_REAL/target" "$REAP_TARGET_BYTES" \
          "$REAP_REAL/.cargo-test-target" "$REAP_CTT_BYTES" <<'PY' || fail "(a) class=D reap event path/bytes mismatch"
import json, sys
amb, want = sys.argv[1], dict(zip(sys.argv[2::2], (int(b) for b in sys.argv[3::2])))
seen = {}
for line in open(amb):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("kind") == "cargo_target_reaped" and e.get("class") == "D" and "branch" in e:
        seen[e["path"]] = e
for path, nbytes in want.items():
    e = seen.get(path)
    if e is None:
        sys.exit(f"no class=D reap event for {path}; saw {sorted(seen)}")
    if e["bytes_freed"] != nbytes or nbytes <= 0:
        sys.exit(f"{path}: bytes_freed={e['bytes_freed']} want {nbytes}")
    if e.get("dry_run") is not False:
        sys.exit(f"{path}: dry_run={e.get('dry_run')}")
PY
pass "(a) class=D reap event carries the reaped path and its bytes_freed"

# no_reap_event <wt> — no class=D reap event names this worktree's build dirs.
no_reap_event() {
    local real
    real="$(cd -P "$1" && pwd -P)"
    if grep -Fq "\"path\":\"${real}/target\"" "$AMBIENT" \
        || grep -Fq "\"path\":\"${real}/.cargo-test-target\"" "$AMBIENT"; then
        fail "$2: a class=D reap event names $real"
    fi
}

# (b) live lease → kept.
[[ -d "$WT_LEASE/target" ]]              || fail "(b) live-lease open-PR target/ was reaped"
[[ -d "$WT_LEASE/.cargo-test-target" ]]  || fail "(b) live-lease open-PR .cargo-test-target/ was reaped"
no_reap_event "$WT_LEASE" "(b) live lease"
pass "(b) live-lease worktree kept"

# (b) process cwd inside → kept.
[[ -d "$WT_CWD/target" ]]                || fail "(b) cwd-held open-PR target/ was reaped"
[[ -d "$WT_CWD/.cargo-test-target" ]]    || fail "(b) cwd-held open-PR .cargo-test-target/ was reaped"
no_reap_event "$WT_CWD" "(b) cwd inside"
pass "(b) process-cwd-inside worktree kept"

# (b) running dispatch for the gap → kept.
[[ -d "$WT_DISPATCH/target" ]]           || fail "(b) running-dispatch open-PR target/ was reaped"
[[ -d "$WT_DISPATCH/.cargo-test-target" ]] || fail "(b) running-dispatch open-PR .cargo-test-target/ was reaped"
no_reap_event "$WT_DISPATCH" "(b) running dispatch"
pass "(b) running-dispatch worktree kept"

# (dirty) tracked source change → kept.
[[ -d "$WT_DIRTY/target" ]]              || fail "(dirty) dirty-source open-PR target/ was reaped"
[[ -d "$WT_DIRTY/.cargo-test-target" ]]  || fail "(dirty) dirty-source open-PR .cargo-test-target/ was reaped"
no_reap_event "$WT_DIRTY" "(dirty) dirty source"
pass "(dirty) dirty-source worktree kept"

# (d) build activity under 2h → kept.
[[ -d "$WT_ACTIVE/target" ]]             || fail "(d) activity<2h open-PR target/ was reaped"
[[ -d "$WT_ACTIVE/.cargo-test-target" ]] || fail "(d) activity<2h open-PR .cargo-test-target/ was reaped"
no_reap_event "$WT_ACTIVE" "(d) activity<2h"
pass "(d) activity-within-2h worktree kept"
[[ -d "$WT_DEEP/target" && -d "$WT_DEEP/.cargo-test-target" ]] \
    || fail "(d) deep-file activity<2h (top-level mtime 3h old) open-PR build output was reaped"
no_reap_event "$WT_DEEP" "(d) deep activity"
pass "(d) activity deep in target/ (top-level mtime old) kept"

# (e) no PR / unknown state → kept.
[[ -d "$WT_NOPR/target" && -d "$WT_NOPR/.cargo-test-target" ]] \
    || fail "(e) unknown/no-PR worktree build output was reaped"
no_reap_event "$WT_NOPR" "(e) no-PR"
pass "(e) unknown/no-PR state kept (not treated as open)"

# (f) gh failing → kept, even though it printed an OPEN line first.
[[ -d "$WT_GHFAIL/target" && -d "$WT_GHFAIL/.cargo-test-target" ]] \
    || fail "(f) gh-failing worktree build output was reaped"
no_reap_event "$WT_GHFAIL" "(f) gh failing"
pass "(f) gh failing kept"

# (g) symlinked worktree entry → kept; the other checkout's target untouched.
[[ -L "$WT_BASE/resilient-1809" ]]       || fail "(g) symlinked entry removed"
[[ -d "$OTHER/target" && -d "$OTHER/.cargo-test-target" ]] \
    || fail "(g) the symlinked-to checkout's build output was deleted"
[[ "$(cat "$OTHER/target/debug/chump")" == "$OTHER_TARGET_BEFORE" ]] \
    || fail "(g) the symlinked-to checkout's target bytes changed"
no_reap_event "$OTHER" "(g) symlink"
pass "(g) symlinked worktree entry kept; the other checkout's target byte-unchanged"

# (h) suffixed name with a running dispatch for its gap → kept.
[[ -d "$WT_SUFFIX/target" && -d "$WT_SUFFIX/.cargo-test-target" ]] \
    || fail "(h) suffixed worktree under a live chump dispatch RESILIENT-1828 was reaped"
no_reap_event "$WT_SUFFIX" "(h) suffixed dispatch"
pass "(h) suffixed resilient-1828-fleet-1-<ts> with a running dispatch kept"

# (i) CARGO_TARGET_DIR inside the worktree, cwd elsewhere → kept.
[[ -d "$WT_CTD/target" && -d "$WT_CTD/.cargo-test-target" ]] \
    || fail "(i) CARGO_TARGET_DIR-busy worktree build output was reaped"
no_reap_event "$WT_CTD" "(i) CARGO_TARGET_DIR"
pass "(i) CARGO_TARGET_DIR-busy worktree (cwd elsewhere) kept"

# (j) open file under target/, cwd elsewhere → kept.
[[ -d "$WT_OPENFILE/target" && -d "$WT_OPENFILE/.cargo-test-target" ]] \
    || fail "(j) open-file-busy worktree build output was reaped"
no_reap_event "$WT_OPENFILE" "(j) open file"
pass "(j) open-file-busy worktree (cwd elsewhere) kept"

# (l) no derivable gap id → kept (cannot rule out a running dispatch).
[[ -d "$WT_NOGAP/target" && -d "$WT_NOGAP/.cargo-test-target" ]] \
    || fail "(l) open-PR worktree with no derivable gap id was reaped"
no_reap_event "$WT_NOGAP" "(l) no gap id"
pass "(l) open-PR worktree with no derivable gap id kept"

# (m) symlinked build dir → worktree kept; the link and what it points at intact.
[[ -L "$WT_LINKTGT/target" ]]            || fail "(m) symlinked target/ link was removed"
[[ "$(cat "$ELSEWHERE/debug/chump")" == "shared-artifact" ]] \
    || fail "(m) the symlinked target's pointee changed"
[[ -d "$WT_LINKTGT/.cargo-test-target" ]] || fail "(m) worktree with a symlinked target/ had .cargo-test-target reaped"
no_reap_event "$WT_LINKTGT" "(m) symlinked build dir"
pass "(m) symlinked build dir: worktree kept, link + pointee intact"

# (n) symlinked entry resolving inside the base → kept; nested checkout intact.
[[ -L "$WT_BASE/resilient-1814" ]]       || fail "(n) symlinked alias entry removed"
[[ -d "$NESTED/target" && -d "$NESTED/.cargo-test-target" ]] \
    || fail "(n) build output reaped through a symlinked alias entry inside the base"
no_reap_event "$NESTED" "(n) in-base symlink alias"
pass "(n) symlinked alias entry resolving inside the base kept"

# (c) stale marker removed, fresh marker kept, live-PID marker kept.
[[ ! -f "$MARK_STALE" ]]                 || fail "(c) stale marker not removed"
[[ -f "$MARK_FRESH" ]]                   || fail "(c) fresh marker was removed"
[[ -f "$MARK_LIVE" ]]                    || fail "(c) stale-mtime marker with a live bot-merge PID was removed"
grep -Fq "bot-merge-active-dispatch-stale.path" "$AMBIENT" \
    || fail "(c) stale-marker removal not logged to ambient"
pass "(c) stale active-dispatch marker removed + logged, fresh and live-PID markers kept"

# (r) N2: open file only under .cargo-test-target → kept.
[[ -d "$WT_N2/target" && -d "$WT_N2/.cargo-test-target" ]] \
    || fail "(r) N2: worktree with a file open only under .cargo-test-target was reaped"
no_reap_event "$WT_N2" "(r) N2 open file under .cargo-test-target"
pass "(r) N2: a file open only under .cargo-test-target (cwd elsewhere, no env) keeps the worktree"

# (s) N6: symlinked .cargo-test-target → the whole worktree kept.
[[ -L "$WT_N6/.cargo-test-target" ]]     || fail "(s) N6: the symlinked .cargo-test-target link was removed"
[[ "$(cat "$ELSEWHERE_CTT/debug/chump")" == "shared-test-artifact" ]] \
    || fail "(s) N6: the symlinked .cargo-test-target's pointee changed"
[[ -d "$WT_N6/target" ]]                 || fail "(s) N6: worktree with a symlinked .cargo-test-target had target/ reaped"
no_reap_event "$WT_N6" "(s) N6 symlinked .cargo-test-target"
pass "(s) N6: symlinked .cargo-test-target: worktree kept, link + pointee intact"

# (t) cache: "state": "closed" (REST and webhook shapes) → closed → reaped;
# a row with no parseable state → unknown → kept (gh would have said OPEN).
for w in "$WT_CACHE_SHUT" "$WT_CACHE_HOOK"; do
    [[ ! -d "$w/target" && ! -d "$w/.cargo-test-target" ]] \
        || fail "(t) cache row \"state\": \"closed\" not read as closed for $w (kept)"
    [[ -f "$w/main.rs" ]]                || fail "(t) cache-closed worktree source removed!"
done
[[ "$OUT" == *"chump/cachewt-shut merged/closed"* && "$OUT" == *"chump/cachewt-hook merged/closed"* ]] \
    || fail "(t) cache-closed worktrees not reaped on the merged/closed path"
[[ -d "$WT_CACHE_UNK/target" && -d "$WT_CACHE_UNK/.cargo-test-target" ]] \
    || fail "(t) cache row with no parseable state was read as open and reaped"
no_reap_event "$WT_CACHE_UNK" "(t) cache unknown state"
pass "(t) cache: json_extract reads \"state\": \"closed\" as closed; an unparseable row is unknown and kept"

# (u) CARGO_TARGET_DIR through a symlink alias (existing, and not yet built) → kept.
[[ -d "$WT_ALIAS1/target" && -d "$WT_ALIAS1/.cargo-test-target" ]] \
    || fail "(u) worktree with CARGO_TARGET_DIR spelled through a symlink alias was reaped"
no_reap_event "$WT_ALIAS1" "(u) CARGO_TARGET_DIR via alias"
[[ -d "$WT_ALIAS2/target" && -d "$WT_ALIAS2/.cargo-test-target" ]] \
    || fail "(u) worktree with a not-yet-existing CARGO_TARGET_DIR under a symlink alias was reaped"
no_reap_event "$WT_ALIAS2" "(u) not-yet-existing CARGO_TARGET_DIR via alias"
pass "(u) CARGO_TARGET_DIR via a symlink alias (existing and not yet built) keeps the worktree"

# (w) CARGO_TARGET_DIR with ".." past a missing component → normalized → kept.
[[ -d "$WT_DOTDOT/target" && -d "$WT_DOTDOT/.cargo-test-target" ]] \
    || fail "(w) worktree with CARGO_TARGET_DIR spelled <tmp>/not-yet/../<wt>/target was reaped (\"..\" not normalized)"
no_reap_event "$WT_DOTDOT" "(w) CARGO_TARGET_DIR with .."
pass "(w) CARGO_TARGET_DIR with \"..\" past a missing component keeps the worktree (normalized)"

# (p) Linux only: same-uid non-dumpable process naming the worktree → kept.
if [[ -n "$BLIND_PID" ]]; then
    [[ -d "$WT_BLIND/target" && -d "$WT_BLIND/.cargo-test-target" ]] \
        || fail "(p) worktree named by a non-dumpable (unreadable /proc) process's cmdline was reaped"
    no_reap_event "$WT_BLIND" "(p) non-dumpable process"
    if [[ $BLIND_IS_BLIND -eq 1 ]]; then
        [[ "$OUT" == *"unreadable pid judged busy by cmdline"* ]] \
            || fail "(p) the non-dumpable fixture was not judged by its cmdline"
        [[ "$OUT" == *"judged by cmdline: "*"$BLIND_PID"* ]] \
            || fail "(p) the per-tick blind-pid summary line does not list pid $BLIND_PID"
        pass "(p) non-dumpable same-uid process (environ/cwd/fd unreadable) naming the worktree: kept, blind pids logged"
    else
        pass "(p) worktree kept; NOTE the fixture process was readable here (running as root?), so the blind path was not exercised"
    fi
else
    echo "  - (p) SKIPPED: no /proc on this host (macOS); the non-dumpable-process fixture runs on Linux only"
fi

# class=D emitted for the open-PR reap.
grep -q '"class":"D"' "$AMBIENT" || fail "no class=D event emitted"
pass "cargo_target_reaped class=D emitted"

# ── (q) M13: CHUMP_REAPER_SAFETY_CHECK=0 + cwd in the source tree → kept ─────
# With the safety check off, wt_has_live_bot_merge (which also checks cwds)
# returns early; only the Class D cwd check can keep WT_M13.
echo "--- (q) M13: safety check off, process cwd in the source tree ---"
[[ -d "$WT_M13/target" && -d "$WT_M13/.cargo-test-target" ]] \
    || fail "(q) M13: cwd-in-source worktree reaped on the first (safety check on) run"
OUT="$(run_reaper CHUMP_REAPER_SAFETY_CHECK=0)" || fail "reaper exited non-zero (safety check off)"
echo "$OUT" | sed 's/^/    /'
[[ -d "$WT_M13/target" && -d "$WT_M13/.cargo-test-target" ]] \
    || fail "(q) M13: with CHUMP_REAPER_SAFETY_CHECK=0 a worktree with a process cwd in its source tree was reaped"
no_reap_event "$WT_M13" "(q) M13 cwd in source tree"
[[ "$OUT" == *"skip (process cwd inside): $(cd -P "$WT_M13" && pwd -P)"* ]] \
    || fail "(q) M13: the cwd check did not report keeping the worktree"
pass "(q) M13: safety check off, a process cwd in the source tree keeps the worktree"

# ── (v) Linux only: same-uid blind build tool, cmdline NOT naming the worktree ──
# Each case is its own reaper pass, after the main pass, on a fresh idle
# open-PR worktree created here (so the main pass never saw it). The fixture
# process is python3 exec'd with argv0 set to the tool name and made
# non-dumpable (prctl PR_SET_DUMPABLE 0): its /proc environ, cwd and fd are
# unreadable, so only _classd_blind_pid_busy can judge it. Its cmdline is
# "<tool> -c <script> [args]"; neither the script nor the args name the
# worktree unless a case says so.
echo "--- (v) same-uid non-dumpable build tool not naming the worktree (own passes) ---"
if [[ ! -d /proc/self ]]; then
    echo "  - (v) SKIPPED: no /proc on this host (macOS); the same-uid blind build-tool fixture runs on Linux only"
elif [[ $BLIND_IS_BLIND -ne 1 ]]; then
    echo "  - (v) SKIPPED: a non-dumpable process is readable here (running as root?), so no pid is blind and the same-uid rule cannot be exercised"
else
    PY3="$(command -v python3)"
    BLIND_TOOL_PY='
import ctypes, sys, time
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(4, 0, 0, 0, 0) != 0:   # PR_SET_DUMPABLE = 4
    sys.exit(3)
time.sleep(300)
'
    WT_SAMEUID="$(mk_wt resilient-1822 chump/resilient-1822-open)"
    SAMEUID_REAL="$(cd -P "$WT_SAMEUID" && pwd -P)"
    SAMEUID_SRC_BEFORE="$(src_sum "$WT_SAMEUID")"
    stop_blind_tool() {
        kill "$V_PID" 2>/dev/null || true
        wait "$V_PID" 2>/dev/null || true
    }
    # cmdline_of <pid> — the pid's argv, NUL-separated args joined by spaces.
    cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline"; }

    # start_blind_tool <argv0> [arg...] — start the non-dumpable fixture with
    # cwd elsewhere and no CARGO_TARGET_DIR (unset in the subshell: `env -u`
    # would re-exec python with the path as argv0); sets V_PID once it is blind.
    start_blind_tool() {
        local argv0="$1" _
        shift
        ( cd "$TMP" && unset CARGO_TARGET_DIR && exec -a "$argv0" "$PY3" -c "$BLIND_TOOL_PY" "$@" ) >/dev/null 2>&1 &
        V_PID="$!"
        BG_PIDS+=("$V_PID")
        for _ in $(seq 1 50); do
            kill -0 "$V_PID" 2>/dev/null || fail "(v) the ${argv0} fixture process exited (prctl failed?)"
            if ! readlink "/proc/${V_PID}/cwd" >/dev/null 2>&1; then
                return 0
            fi
            sleep 0.1
        done
        fail "(v) the ${argv0} fixture process never became non-dumpable"
    }

    for tool in sccache clippy-driver cargo; do
        start_blind_tool "$tool"
        V_CMDLINE="$(cmdline_of "$V_PID")"
        [[ "$V_CMDLINE" == "${tool} -c "* ]] \
            || fail "(v) the fixture's argv0 is not ${tool}: cmdline is '${V_CMDLINE}'"
        [[ "$V_CMDLINE" != *resilient-1822* ]] \
            || fail "(v) the ${tool} fixture's cmdline names the worktree; it must not"
        OUT="$(run_reaper)" || fail "reaper exited non-zero ((v) ${tool})"
        echo "$OUT" | sed 's/^/    /'
        [[ -d "$WT_SAMEUID/target" && -d "$WT_SAMEUID/.cargo-test-target" ]] \
            || fail "(v) an idle worktree was reaped while a same-uid non-dumpable ${tool} (cmdline not naming it) was running"
        no_reap_event "$WT_SAMEUID" "(v) same-uid ${tool}"
        [[ "$OUT" == *"skip (unreadable pid judged busy by cmdline: pid=${V_PID} same-uid ${tool}): ${SAMEUID_REAL}"* ]] \
            || fail "(v) the keep was not logged as \"pid=${V_PID} same-uid ${tool}\" for ${SAMEUID_REAL}"
        stop_blind_tool
        pass "(v) same-uid non-dumpable ${tool} (cmdline does not name the worktree): kept, logged \"same-uid ${tool}\""
    done

    # Path match: a blind NON-tool process (argv0 python3) whose argument is
    # "<wt>;" names the worktree (";" is not a path-name character).
    start_blind_tool python3 "--cfg=${SAMEUID_REAL};"
    OUT="$(run_reaper)" || fail "reaper exited non-zero ((v) path match)"
    echo "$OUT" | sed 's/^/    /'
    [[ -d "$WT_SAMEUID/target" && -d "$WT_SAMEUID/.cargo-test-target" ]] \
        || fail "(v) a blind process whose argument is \"<wt>;\" did not keep the worktree"
    [[ "$OUT" == *"skip (unreadable pid judged busy by cmdline: pid=${V_PID} cmdline names ${SAMEUID_REAL}): ${SAMEUID_REAL}"* ]] \
        || fail "(v) the \"<wt>;\" keep was not logged as \"pid=${V_PID} cmdline names ${SAMEUID_REAL}\""
    stop_blind_tool
    pass "(v) a blind process whose argument is \"<wt>;\" names the worktree: kept"

    # Every fixture process killed; only a blind python3 naming "<wt>-old"
    # ("-" IS a path-name character, so a different path) is alive. The same
    # worktree is now idle and IS reaped, so the keeps above were the
    # processes', not some other guard's.
    start_blind_tool python3 "${SAMEUID_REAL}-old"
    OUT="$(run_reaper)" || fail "reaper exited non-zero ((v) after kill)"
    echo "$OUT" | sed 's/^/    /'
    [[ ! -d "$WT_SAMEUID/target" && ! -d "$WT_SAMEUID/.cargo-test-target" ]] \
        || fail "(v) with the build-tool fixtures killed (only a \"<wt>-old\" blind pid alive) the idle worktree was NOT reaped"
    [[ -f "$WT_SAMEUID/main.rs" && "$(src_sum "$WT_SAMEUID")" == "$SAMEUID_SRC_BEFORE" ]] \
        || fail "(v) reaping the build output changed or removed the source"
    [[ "$OUT" == *"judged by cmdline: "*"$V_PID"* ]] \
        || fail "(v) the \"<wt>-old\" blind pid ${V_PID} was not listed in the blind-pid summary line"
    stop_blind_tool
    pass "(v) build-tool fixtures killed: the same idle worktree is reaped; a \"<wt>-old\" blind pid does not name it"
fi

echo "=== all Class-D open-idle tests passed ==="
