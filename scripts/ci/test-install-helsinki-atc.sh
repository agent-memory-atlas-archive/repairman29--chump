#!/usr/bin/env bash
# scripts/ci/test-install-helsinki-atc.sh — INFRA-3593
#
# Smoke-tests the merge-triggered auto-deploy path added to
# install-helsinki-atc.sh: --auto must degrade gracefully (exit 0, emit
# organ_units_deploy_failed) when not root, since CI and most worker
# contexts cannot write /etc/systemd/system.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing or not executable"

bash -n "$SCRIPT" || fail "syntax error"
ok "bash -n passes"

# ── Test: --auto as non-root exits 0 and emits organ_units_deploy_failed ───
# Shim `id` so the assertion holds even when the test runner itself is root
# (some worker sandboxes run as root) — this test must NEVER touch the real
# /etc/systemd/system, so it forces the not-root branch unconditionally.
mkdir -p "$TMP/.chump-locks" "$TMP/bin"
cat > "$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-u" ] && { echo 1000; exit 0; }
exit 1
EOF
chmod +x "$TMP/bin/id"
NODE_AMBIENT="$TMP/.chump-locks/ambient.jsonl" PATH="$TMP/bin:$PATH" bash "$SCRIPT" --auto \
    >"$TMP/out.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "--auto (non-root) must exit 0 (non-fatal), got $rc"
grep -q 'without root' "$TMP/out.log" \
    || fail "expected a not-root warning on stdout/stderr: $(cat "$TMP/out.log")"
grep -q '"kind":"organ_units_deploy_failed"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "expected organ_units_deploy_failed emitted to ambient: $(cat "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null)"
grep -q '"reason":"not_root"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "expected reason=not_root in the emitted event"
ok "--auto (non-root) is non-fatal and emits organ_units_deploy_failed reason=not_root"

# ── Test: the roster references files that actually exist ──────────────────
for unit in chump-pr-lander chump-armed-rebaser chump-board-cycle chump-sla-scorecard chump-organ-watchdog; do
    [ -f "$REPO_ROOT/scripts/dispatch/${unit}.service" ] || fail "missing scripts/dispatch/${unit}.service"
    [ -f "$REPO_ROOT/scripts/dispatch/${unit}.timer" ] || fail "missing scripts/dispatch/${unit}.timer"
done
ok "all 5 system-unit organs (pr-lander, armed-rebaser, board-cycle, sla-scorecard, organ-watchdog) have tracked .service+.timer pairs"

# ── Test: sla-scorecard unit has WorkingDirectory (INFRA-3598) ─────────────
# merge-sla-scorecard.sh resolves its target repo via `gh repo view`, which
# is cwd-based. Without WorkingDirectory, systemd's default cwd (/) makes
# the unit fail every cycle with "no repo nwo; skip" regardless of any
# CHUMP_REPO_ROOT env var (the script never reads that var for gh calls).
grep -q '^WorkingDirectory=' "$REPO_ROOT/scripts/dispatch/chump-sla-scorecard.service" \
    || fail "chump-sla-scorecard.service missing WorkingDirectory= (gh repo view is cwd-based; INFRA-3598)"
ok "chump-sla-scorecard.service sets WorkingDirectory so gh repo view resolves"

# ── Test: --auto from an ephemeral worktree must NOT bake that path into ───
# the persisted node-refresh unit's CHUMP_NODE_REPO (INFRA-3598). Simulate by
# copying the script tree into a fake ".claude/worktrees/<gap>/" path and
# running --check-propagation (a lightweight dry-run stub) — since the real
# script requires root + a live systemd bus for the full --auto path, this
# test instead asserts the source-level guard exists and covers the exact
# path shape node-refresh sessions run from.
grep -q '/.claude/worktrees/' "$SCRIPT" \
    || fail "install-helsinki-atc.sh missing the ephemeral-worktree guard for CHUMP_NODE_REPO"
grep -q 'Not propagating it as CHUMP_NODE_REPO' "$SCRIPT" \
    || fail "install-helsinki-atc.sh guard doesn't skip CHUMP_NODE_REPO propagation for worktree paths"
ok "install-helsinki-atc.sh guards against baking an ephemeral worktree into CHUMP_NODE_REPO"

# ── Test: --auto must NOT abort the roster on a single unit enable failure
#       (RESILIENT-347) ─────────────────────────────────────────────────────
# Before RESILIENT-347, `systemctl enable --now $t` failing for ANY one timer
# under --auto exited the whole script immediately (`exit 0`) — later timers
# in the roster never even got an enable attempt, and the ORGAN_RECONCILE
# call (which backs a structurally-broken organ off cleanly instead of
# re-churning it every cycle) never ran. This is the exact real-world failure
# named in the gap: chump-integrator/sla-scorecard/backlog-sync-writer/farmer
# failing on a node missing that organ's binary/deps must not take the rest
# of the ATC roster down with it.
mkdir -p "$TMP/atc-dest" "$TMP/atc-bins" "$TMP/atc-cargo-bin" "$TMP/atc-locks"
cat > "$TMP/atc-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$ATC_CALL_LOG"
case "$1" in
    enable)
        unit="${@: -1}"
        grep -qxF "$unit" "$ATC_ENABLE_FAIL_FILE" 2>/dev/null && exit 1
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/atc-bins/systemctl"
# chump-integrator's own binary build path is unrelated to this test — stub
# CARGO_BIN_DIR with a pre-existing fake binary so the script's "build it if
# missing" branch (which needs a real cargo/network) never triggers.
cat > "$TMP/atc-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/atc-cargo-bin/chump-integrator"

ATC_CALL_LOG="$TMP/atc-calls.log"
ATC_ENABLE_FAIL_FILE="$TMP/atc-enable-fail.txt"
: > "$ATC_CALL_LOG"
echo "chump-farmer.timer" > "$ATC_ENABLE_FAIL_FILE"

ATC_CALL_LOG="$ATC_CALL_LOG" ATC_ENABLE_FAIL_FILE="$ATC_ENABLE_FAIL_FILE" \
    CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/atc-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/atc-bins/systemctl" \
    CARGO_BIN_DIR="$TMP/atc-cargo-bin" \
    NODE_AMBIENT="$TMP/atc-locks/ambient.jsonl" \
    bash "$SCRIPT" --auto >"$TMP/atc-out.log" 2>&1
atc_rc=$?
[ "$atc_rc" -eq 0 ] || fail "--auto with one failing unit must still exit 0 (non-fatal); got $atc_rc: $(cat "$TMP/atc-out.log")"
grep -q '"kind":"organ_units_deploy_failed".*"unit":"chump-farmer.timer"' "$TMP/atc-locks/ambient.jsonl" \
    || fail "expected organ_units_deploy_failed for chump-farmer.timer: $(cat "$TMP/atc-locks/ambient.jsonl" 2>/dev/null)"
# The two units the gap names as needing more than a path-rewrite
# (chump-integrator.timer, chump-backlog-sync-writer.timer) sit AFTER
# chump-farmer.timer in SYSTEM_TIMERS — proof the loop kept going past the
# failure instead of aborting on it.
grep -q "enable --now chump-integrator.timer" "$TMP/atc-calls.log" \
    || fail "a later timer (chump-integrator.timer) never got an enable attempt — the loop aborted early: $(cat "$TMP/atc-calls.log")"
grep -q "enable --now chump-backlog-sync-writer.timer" "$TMP/atc-calls.log" \
    || fail "a later timer (chump-backlog-sync-writer.timer) never got an enable attempt — the loop aborted early: $(cat "$TMP/atc-calls.log")"
grep -q "== reconciling organ manifest" "$TMP/atc-out.log" \
    || fail "ORGAN_RECONCILE was never reached after the mid-roster enable failure: $(cat "$TMP/atc-out.log")"
ok "--auto with one unit's enable failure continues the roster loop AND still reaches organ-reconcile.sh (RESILIENT-347)"

# ── Test: chump-organ-watchdog.service is host-agnostic (INFRA-3647) ───────
# Before INFRA-3647 the tracked unit hardcoded HOME=/root,
# CHUMP_REPO_ROOT=/root/Projects/chump and source /root/.chump/providers.env
# — the ONLY thing that made it work on an owned node (CJ, non-root) was
# this installer's blanket "/root/" -> $RUN_HOME sed rewrite at copy time.
# The unit now resolves its own paths via the systemd %h specifier, so it's
# correct on ANY node straight from the tracked file, with no rewrite step
# required. Assert both: (a) the tracked source has no absolute /root path,
# and (b) installing it for a non-root run-user still ends up correct (User=
# inserted, no /root path leaked into the installed copy either).
ORGAN_WATCHDOG_SRC="$REPO_ROOT/scripts/dispatch/chump-organ-watchdog.service"
# RESILIENT-200: the tracked unit is helsinki-shaped (/root/... + User=root) ON
# PURPOSE; install-helsinki-atc.sh host-rewrites "/root/" -> $RUN_HOME per node.
# It MUST NOT resolve its home via the systemd %h specifier in an active
# directive: on a SYSTEM-scope unit %h ignores User= and always expands to
# /root, so on an owned node (CJ=jeff) it exec'd /root/... as jeff and failed
# with status 126 "Permission denied" (reverts INFRA-3647/TREK-21).
grep -Eq '^(Environment|ExecStart)=.*%h' "$ORGAN_WATCHDOG_SRC" \
    && fail "chump-organ-watchdog.service must not use %h in an active directive (system-unit %h -> /root regardless of User=; RESILIENT-200): $(grep -nE '^(Environment|ExecStart)=.*%h' "$ORGAN_WATCHDOG_SRC")"
grep -q '/root/Projects/chump/scripts/ops/organ-watchdog.sh' "$ORGAN_WATCHDOG_SRC" \
    || fail "chump-organ-watchdog.service should exec via the installer-rewritten /root/ path convention (RESILIENT-200), not %h"
ok "chump-organ-watchdog.service (tracked source) uses the /root host-rewrite convention, not %h"

mkdir -p "$TMP/cj-dest" "$TMP/cj-bins" "$TMP/cj-cargo-bin" "$TMP/cj-locks"
cat > "$TMP/cj-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/cj-bins/systemctl"
cat > "$TMP/cj-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/cj-cargo-bin/chump-integrator"

CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/cj-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/cj-bins/systemctl" \
    CHUMP_RUN_USER=jeff \
    CARGO_BIN_DIR="$TMP/cj-cargo-bin" \
    NODE_AMBIENT="$TMP/cj-locks/ambient.jsonl" \
    bash "$SCRIPT" --auto >"$TMP/cj-out.log" 2>&1
cj_rc=$?
[ "$cj_rc" -eq 0 ] || fail "--auto for CHUMP_RUN_USER=jeff must exit 0; got $cj_rc: $(cat "$TMP/cj-out.log")"
CJ_INSTALLED="$TMP/cj-dest/chump-organ-watchdog.service"
[ -f "$CJ_INSTALLED" ] || fail "chump-organ-watchdog.service was not installed to the stubbed dest dir"
grep -q '^User=jeff' "$CJ_INSTALLED" \
    || fail "installed chump-organ-watchdog.service missing User=jeff (host-rewrite): $(cat "$CJ_INSTALLED")"
# The exec path + repo root MUST be host-rewritten off /root -> the run-user
# home, and NO %h may survive (a system-unit %h expands to /root at runtime and
# crashes as the non-root user — RESILIENT-200). HOME=/root is the accepted
# sibling convention (all dispatch units set it; overridden per-node) so we
# assert the exec/repo path specifically, not a blanket /root.
grep -Eq '^(Environment|ExecStart)=.*%h' "$CJ_INSTALLED" \
    && fail "installed chump-organ-watchdog.service leaked a %h specifier (expands to /root at runtime): $(cat "$CJ_INSTALLED")"
grep -q '/root/Projects/chump' "$CJ_INSTALLED" \
    && fail "installed chump-organ-watchdog.service leaked an un-rewritten /root/Projects/chump path for a non-root run-user: $(cat "$CJ_INSTALLED")"
# RESILIENT-1102: the repo path is now rewritten to this box's ACTUAL checkout
# ($REPO_ROOT, where the installer runs from) — NOT an assumed
# $RUN_HOME/Projects/chump, which does not exist on an owned node and killed the
# organ with status=200/CHDIR. A stale Projects/chump repo path must NOT survive.
grep -q "${REPO_ROOT}/scripts/ops/organ-watchdog.sh" "$CJ_INSTALLED" \
    || fail "installed chump-organ-watchdog.service ExecStart not rewritten to the real checkout ($REPO_ROOT): $(cat "$CJ_INSTALLED")"
grep -q 'Projects/chump/scripts/ops/organ-watchdog.sh' "$CJ_INSTALLED" \
    && fail "installed chump-organ-watchdog.service still bakes a Projects/chump repo path (RESILIENT-1102): $(cat "$CJ_INSTALLED")"
ok "chump-organ-watchdog.service installs for a non-root run-user (CJ shape): exec path rewritten to the real checkout, no Projects/chump ghost, no %h"

# RESILIENT-200 class guard: NO dispatch *.service may resolve its home via %h
# in an active directive — the installer host-rewrite keys off "/root/" literals
# and cannot adapt %h, which a system-scope unit expands to /root regardless of
# User=. This catches organ-watchdog + process-organ-heal + any future reintro.
_pct_h_offenders="$(grep -lE '^(Environment|ExecStart)=.*%h' "$REPO_ROOT"/scripts/dispatch/*.service 2>/dev/null || true)"
[ -z "$_pct_h_offenders" ] \
    || fail "dispatch *.service units use the %h specifier in an active directive (breaks install-helsinki-atc.sh host-rewrite; RESILIENT-200): $_pct_h_offenders"
ok "no dispatch *.service unit uses %h in an active directive (RESILIENT-200 class guard)"

# ── Guard: the "instruments lie" keystone (INFRA-3647) ─────────────────────
# Every organ installed for a NON-ROOT run-user (CJ=jeff, from the CHUMP_RUN_USER
# =jeff install above into $TMP/cj-dest) must resolve HOME to the run-user's home
# (never /root) AND set cwd at the repo root. The blanket "/root/" prefix rewrite
# silently missed `Environment=HOME=/root` (no trailing slash), so 16 organs kept
# HOME=/root even with User=jeff: gh read /root/.config/gh (perm denied => 0
# merges), almanac read /root/.almanac (0 repos => fake 100% coverage), chump gap
# ran cwd=/ (0 gaps) — every tool failed CLOSED while reporting fake-perfect. This
# guard fails if the generator ever regresses to leaking /root into an owned-node
# unit, or drops the repo-root cwd.
installed_svcs=0
for u in "$TMP/cj-dest"/*.service; do
  [ -f "$u" ] || continue
  installed_svcs=$((installed_svcs+1))
  b="$(basename "$u")"
  grep -Eq '=/root([[:space:]]|$)' "$u" \
    && fail "$b pins a bare =/root value (e.g. HOME=/root) for run-user jeff: $(grep -nE '=/root([[:space:]]|$)' "$u")"
  grep -Eq '^Environment=HOME=.*/root' "$u" \
    && fail "$b HOME still resolves under /root for run-user jeff: $(grep -n '^Environment=HOME=' "$u")"
  grep -q '^WorkingDirectory=' "$u" \
    || fail "$b has no WorkingDirectory= (systemd cwd defaults to /, breaking cwd-based chump gap / gh repo view)"
  # RESILIENT-1102: the WorkingDirectory must be a directory that EXISTS. Before
  # the fix, every organ baked $RUN_HOME/Projects/chump — a path that does not
  # exist on an owned node (repo at $HOME/chump) — so systemd killed it at CHDIR
  # (status=200/CHDIR) before it ran. This class had ZERO coverage; assert that
  # the baked cwd resolves on disk. (Here the installer ran from $REPO_ROOT, the
  # real checkout, so the rewritten WorkingDirectory points there and exists.)
  # The baked WorkingDirectory must resolve to a directory that EXISTS. Before
  # the fix it was an assumed $RUN_HOME/Projects/chump (absent on owned nodes),
  # so systemd killed the organ at CHDIR (status=200/CHDIR) before it ran.
  # (Note: we assert on WorkingDirectory only, NOT a blanket grep for
  # Projects/chump — some units, e.g. chump-gap-closure-reconcile.service,
  # legitimately list $HOME/Projects/chump as ONE runtime self-resolving repo
  # candidate guarded by `-d "$c/.git"`, which is robust, not the bug.)
  _wd="$(sed -n 's/^WorkingDirectory=//p' "$u" | head -1)"
  [ -d "$_wd" ] \
    || fail "$b WorkingDirectory '$_wd' does not exist on disk — systemd would kill it at CHDIR (status=200/CHDIR; RESILIENT-1102)"
done
[ "$installed_svcs" -gt 0 ] || fail "no .service units were installed to the stubbed dest dir — roster/install path broke"
ok "all $installed_svcs generated organs run with HOME off /root + cwd at the real checkout that EXISTS on disk (INFRA-3647 + RESILIENT-1102)"

# ── Test: host-rewrite generalizes past hardcoded /root (RESILIENT-1051) ───
# Several tracked units (chump-nba-dispatch.service, chump-gap-drain.service,
# chump-digest.service) are CJ-native (User=jeff, /home/jeff/... paths), not
# helsinki-shaped. Before this fix the host-rewrite sed only ever matched
# "/root" literals, so installing the SAME roster for a THIRD node (e.g.
# RUN_USER=ubuntu) shipped /home/jeff verbatim into the installed unit's
# active directives (User=, Environment=HOME=, WorkingDirectory=, ExecStart=)
# — a WorkingDirectory/HOME that doesn't exist on that node, causing
# CHDIR/127 failures on every cycle for those organs on every node except
# jeff's own.
mkdir -p "$TMP/ubuntu-dest" "$TMP/ubuntu-bins" "$TMP/ubuntu-cargo-bin" "$TMP/ubuntu-locks"
cat > "$TMP/ubuntu-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/ubuntu-bins/systemctl"
cat > "$TMP/ubuntu-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/ubuntu-cargo-bin/chump-integrator"

CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/ubuntu-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/ubuntu-bins/systemctl" \
    CHUMP_RUN_USER=ubuntu \
    CARGO_BIN_DIR="$TMP/ubuntu-cargo-bin" \
    NODE_AMBIENT="$TMP/ubuntu-locks/ambient.jsonl" \
    bash "$SCRIPT" --auto >"$TMP/ubuntu-out.log" 2>&1
ubuntu_rc=$?
[ "$ubuntu_rc" -eq 0 ] || fail "--auto for CHUMP_RUN_USER=ubuntu must exit 0; got $ubuntu_rc: $(cat "$TMP/ubuntu-out.log")"

for jeff_native in chump-nba-dispatch.service chump-gap-drain.service chump-digest.service; do
    installed="$TMP/ubuntu-dest/$jeff_native"
    [ -f "$installed" ] || fail "$jeff_native was not installed to the stubbed dest dir"
    # Exclude the real checkout path ($REPO_ROOT) from the leak check: repo paths
    # are legitimately rewritten to it (RESILIENT-1102), and on a dev box it may
    # itself live under /home/jeff — that is the real repo, not an un-rewritten
    # source leak. Any OTHER /home/jeff or User=jeff is a genuine leak.
    leaked="$(grep -v '^#' "$installed" | grep -F -v "$REPO_ROOT" | grep -E 'home/jeff|^User=jeff' || true)"
    [ -z "$leaked" ] \
        || fail "$jeff_native leaked an un-rewritten /home/jeff path for run-user ubuntu (RESILIENT-1051): $leaked"
    grep -q '^User=ubuntu' "$installed" \
        || fail "$jeff_native missing User=ubuntu (host-rewrite from a jeff-shaped source): $(grep -n '^User=' "$installed")"
    grep -q '^Environment=HOME=/home/ubuntu$' "$installed" \
        || fail "$jeff_native HOME not rewritten to /home/ubuntu: $(grep -n '^Environment=HOME=' "$installed")"
    # RESILIENT-1102: WorkingDirectory is now the box's REAL checkout ($REPO_ROOT,
    # where the installer ran), not an assumed $HOME/Projects/chump ghost — and
    # it must EXIST on disk (a non-existent cwd is status=200/CHDIR at runtime).
    grep -q "^WorkingDirectory=${REPO_ROOT}\$" "$installed" \
        || fail "$jeff_native WorkingDirectory not rewritten to the real checkout ($REPO_ROOT): $(grep -n '^WorkingDirectory=' "$installed")"
    _wd="$(sed -n 's/^WorkingDirectory=//p' "$installed" | head -1)"
    [ -d "$_wd" ] \
        || fail "$jeff_native WorkingDirectory '$_wd' does not exist — systemd CHDIR kill (status=200/CHDIR; RESILIENT-1102)"
done
ok "jeff-shaped source units (nba-dispatch, gap-drain, digest) host-rewrite cleanly for run-user ubuntu — repo path -> the real (existing) checkout, no /home/jeff leak, no Projects/chump ghost (RESILIENT-1051 + 1102)"

# ── RESILIENT-1446: a root-run deploy honors CHUMP_RUN_USER from node.env ──
# The split-identity hub bug: chump-organ-deploy runs install-helsinki-atc.sh AS
# ROOT from a root-owned checkout, so RUN_USER derived only via `stat %U` was
# root -> root-shaped units, while the worker/store/oauth live under the worker
# user -> farmer heartbeat split -> RESILIENT-069 RED -> fleet dark. The node's
# real identity is persisted in ~/.chump/node.env's CHUMP_RUN_USER; the installer
# must honor it even when CHUMP_RUN_USER is NOT already exported. Assert that a
# node.env-provided CHUMP_RUN_USER (with the env var UNSET) still shapes units.
mkdir -p "$TMP/ne-dest" "$TMP/ne-bins" "$TMP/ne-cargo-bin" "$TMP/ne-locks" "$TMP/ne-state"
cat > "$TMP/ne-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/ne-bins/systemctl"
cat > "$TMP/ne-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/ne-cargo-bin/chump-integrator"
cat > "$TMP/ne-state/node.env" <<'EOF'
export CHUMP_NODE_ROLE=all
export CHUMP_RUN_USER=ubuntu
EOF
# CHUMP_RUN_USER deliberately NOT in the environment — it must come from node.env.
env -u CHUMP_RUN_USER \
    CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/ne-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/ne-bins/systemctl" \
    CHUMP_STATE_DIR="$TMP/ne-state" \
    CARGO_BIN_DIR="$TMP/ne-cargo-bin" \
    NODE_AMBIENT="$TMP/ne-locks/ambient.jsonl" \
    bash "$SCRIPT" --auto >"$TMP/ne-out.log" 2>&1
ne_rc=$?
[ "$ne_rc" -eq 0 ] || fail "--auto with node.env CHUMP_RUN_USER=ubuntu must exit 0; got $ne_rc: $(cat "$TMP/ne-out.log")"
NE_INSTALLED="$TMP/ne-dest/chump-organ-watchdog.service"
[ -f "$NE_INSTALLED" ] || fail "chump-organ-watchdog.service not installed (node.env run-user path): $(cat "$TMP/ne-out.log")"
grep -q '^User=ubuntu' "$NE_INSTALLED" \
    || fail "node.env CHUMP_RUN_USER=ubuntu was not honored — unit not shaped for ubuntu: $(grep -n '^User=' "$NE_INSTALLED")"
ok "install-helsinki-atc.sh honors CHUMP_RUN_USER from node.env when the env var is unset (root-run deploy emits run-user-shaped units — RESILIENT-1446)"

# ── RESILIENT-1446: repo-retarget source guard ────────────────────────────
# When the checkout the (root) installer runs from is owned by a DIFFERENT user
# than the run-user, the baked WorkingDirectory must be re-targeted to the
# run-user's OWN checkout (else the run-user cannot cd into a root-owned tree ->
# 200/CHDIR). A full functional test needs a second-user-owned checkout (not
# creatable without root in CI), so assert the source-level guard exists.
grep -q '_checkout_owner' "$SCRIPT" \
    || fail "install-helsinki-atc.sh missing the RESILIENT-1446 repo-retarget guard for a checkout owned by a non-run-user"
ok "install-helsinki-atc.sh re-targets the baked repo path to the run-user's checkout when the checkout owner differs (RESILIENT-1446 source guard)"

# ── RESILIENT-1452: same-owner node-clone retarget (de-split the hand dropins) ──
# A box that is BOTH a chump-node-install.sh node (self-deploy organ runs from
# $NODE_DIR/repo, default ~/.chumpnode/repo) AND the sole hub (a real checkout
# at $RUN_HOME/chump) has the SAME owner on both trees, so RESILIENT-1446's
# owner-mismatch guard is a no-op and every organ — including the farmer — gets
# placed shaped for the shadow node clone. That's exactly what forced the hand
# drop-ins chump-farmer.service.d/zz-ubuntu-home.conf +
# chump-farmer.timer.d/zz-refire.conf. Reproduce that box shape hermetically:
# copy the installer + its dispatch unit sources into a path that ends in
# ".chumpnode/repo" (so $REPO_ROOT resolves there), point
# CHUMP_INSTALL_ATC_RUN_HOME_OVERRIDE at a fake $HOME containing a real hub
# checkout at $HOME/chump owned by the SAME user, and assert the installed
# chump-farmer.service ends up pointed at the hub, not the node clone.
NC_RUNHOME="$TMP/nc-runhome"
NC_NODE_REPO="$TMP/nc-noderoot/.chumpnode/repo"
mkdir -p "$NC_RUNHOME/chump/.git" "$NC_NODE_REPO/scripts" "$NC_NODE_REPO/scripts/coord" \
    "$TMP/nc-dest" "$TMP/nc-bins" "$TMP/nc-cargo-bin" "$TMP/nc-locks"
# The --auto flow shells out to several sibling scripts by $REPO_ROOT-relative
# path (organ-reconcile.sh, install-node-refresh-systemd.sh, ...) after the
# unit-install loop, so the node-clone checkout needs the full scripts/{dispatch,
# setup,ops} + scripts/coord/lib trees present, not just the installer + units.
cp -r "$REPO_ROOT/scripts/dispatch" "$REPO_ROOT/scripts/setup" "$REPO_ROOT/scripts/ops" "$NC_NODE_REPO/scripts/"
cp -r "$REPO_ROOT/scripts/coord/lib" "$NC_NODE_REPO/scripts/coord/"
cp "$SCRIPT" "$NC_NODE_REPO/scripts/setup/install-helsinki-atc.sh"
cat > "$TMP/nc-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/nc-bins/systemctl"
cat > "$TMP/nc-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/nc-cargo-bin/chump-integrator"

_nc_run_user="$(id -un)"
CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/nc-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/nc-bins/systemctl" \
    CHUMP_INSTALL_ATC_RUN_HOME_OVERRIDE="$NC_RUNHOME" \
    CHUMP_RUN_USER="$_nc_run_user" \
    CARGO_BIN_DIR="$TMP/nc-cargo-bin" \
    NODE_AMBIENT="$TMP/nc-locks/ambient.jsonl" \
    bash "$NC_NODE_REPO/scripts/setup/install-helsinki-atc.sh" --auto >"$TMP/nc-out.log" 2>&1
nc_rc=$?
[ "$nc_rc" -eq 0 ] || fail "--auto from a node-clone-shaped checkout must exit 0; got $nc_rc: $(cat "$TMP/nc-out.log")"
NC_FARMER="$TMP/nc-dest/chump-farmer.service"
[ -f "$NC_FARMER" ] || fail "chump-farmer.service not installed from node-clone-shaped checkout: $(cat "$TMP/nc-out.log")"
grep -q "^WorkingDirectory=${NC_RUNHOME}/chump\$" "$NC_FARMER" \
    || fail "chump-farmer.service WorkingDirectory not re-targeted to the hub checkout ($NC_RUNHOME/chump) — still shaped for the node clone (RESILIENT-1452): $(grep -n '^WorkingDirectory=' "$NC_FARMER")"
grep -q "${NC_NODE_REPO}" "$NC_FARMER" \
    && fail "chump-farmer.service still references the node-clone path $NC_NODE_REPO — RESILIENT-1452 retarget did not fire: $(cat "$NC_FARMER")"
ok "chump-farmer.service host-rewrite retargets a same-owner node-clone checkout (\$HOME/.chumpnode/repo) to the real hub checkout (\$HOME/chump) with no hand-applied drop-in (RESILIENT-1452)"

echo "ALL PASS"
