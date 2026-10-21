#!/usr/bin/env bash
# scripts/ci/test-resilient-1055-role-roster.sh — RESILIENT-1055
#
# The --role fresh-node bring-up now PLACES the role's manifest unit files (not
# just enables never-copied ones). This locks the load-bearing pieces of that:
#   1. organ_is_applicable's `file:` spec (the CJ-legacy-unit skip that keeps a
#      generic box from backing off a file-less unit forever).
#   2. organ-role-roster.sh's role filtering + kind classification (the is-active
#      receipt the FTUE and any real-box proof read).
#   3. the node-local exemption list (the units a role-scoped reconcile must
#      NEVER reap — worker/heartbeat/sentinel + the reconcile's own beat).
#   4. the shared host-rewrite lib's core transforms (root->run-user, bare
#      Environment=HOME rewrite, keep-root) — the byte-for-byte contract both
#      placers depend on.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB_MANIFEST="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
LIB_UNIT="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
ROSTER="$REPO_ROOT/scripts/ops/organ-role-roster.sh"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass(){ printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

for f in "$LIB_MANIFEST" "$LIB_UNIT" "$ROSTER" "$RECONCILE"; do
  [ -f "$f" ] || fail "missing $f"
  bash -n "$f" || fail "bash -n failed: $f"
done
pass "syntax integrity of the lib + roster + reconcile"

# ── 1. organ_is_applicable file: spec ────────────────────────────────────────
source "$LIB_MANIFEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
touch "$TMP/present-asset"
reason=""
organ_is_applicable "u.service" "file:$TMP/present-asset" reason \
  || fail "file: guard should be APPLICABLE when the file exists (got reason=$reason)"
pass "file: applicable when the asset exists"
reason=""
if organ_is_applicable "u.service" "file:$TMP/absent-asset" reason; then
  fail "file: guard should be NOT-applicable when the file is absent"
fi
[ "$reason" = "missing_file:$TMP/absent-asset" ] || fail "file: reason wrong: $reason"
pass "file: not-applicable (skipped) when the asset is absent — the CJ-legacy-unit skip"
# ~/ expansion
reason=""; HOME="$TMP" organ_is_applicable "u" "file:~/present-asset" reason \
  || fail "file:~/ should expand against HOME and be applicable (reason=$reason)"
pass "file:~/ expands against \$HOME"

# ── 2. organ-role-roster.sh filtering + kind ─────────────────────────────────
MAN="$TMP/manifest.txt"
cat > "$MAN" <<EOF
enabled  chump-brainy.timer     role=brain
enabled  chump-datum.service    role=data
enabled  chump-muscley.service  role=muscle
enabled  chump-gated.timer      role=brain requires=file:$TMP/absent-asset
EOF
# stub systemctl: cat -> ok (unit "present"), is-active -> active
STUB="$TMP/systemctl"; cat > "$STUB" <<'SH'
#!/usr/bin/env bash
case "$1" in
  cat) exit 0;;
  is-active) echo active; exit 0;;
  *) exit 0;;
esac
SH
chmod +x "$STUB"
out="$(CHUMP_ORGAN_MANIFEST="$MAN" CHUMP_ORGAN_RECONCILE_ROLE="brain,data,janitor,trust" \
       CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" bash "$ROSTER")"
echo "$out" | grep -qE '^active	chump-brainy\.timer	timer' || fail "roster: brainy timer should be active/timer; got: $out"
echo "$out" | grep -qE '^active	chump-datum\.service	service' || fail "roster: datum service should be active/service; got: $out"
echo "$out" | grep -q 'chump-muscley.service' && fail "roster: muscle-tagged unit must NOT appear under a brain filter; got: $out"
echo "$out" | grep -qE '^SKIP	chump-gated\.timer' || fail "roster: file:-gated timer should be SKIP; got: $out"
pass "organ-role-roster.sh: brain filter includes brain/data, excludes muscle, SKIPs a file-gated unit, classifies timer vs service"
# muscle filter shows only the muscle-tagged unit
outm="$(CHUMP_ORGAN_MANIFEST="$MAN" CHUMP_ORGAN_RECONCILE_ROLE="muscle" \
        CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" bash "$ROSTER")"
echo "$outm" | grep -qE '^active	chump-muscley\.service' || fail "muscle filter should show the muscle unit; got: $outm"
echo "$outm" | grep -q 'chump-brainy' && fail "muscle filter must NOT show brain units; got: $outm"
pass "organ-role-roster.sh: muscle filter scopes to muscle-tagged units only"

# ── 3. node-local exemption ──────────────────────────────────────────────────
# organ_is_node_local lives in organ-reconcile.sh; source just that function's
# definition by grepping it out is brittle — instead assert the list is present
# and covers the FTUE-verified reap victims.
for u in chump-organ-reconcile chump-worker chump-fleet-health-sentinel chump-process-organ-heal chump-node-heartbeat; do
  grep -qE "^\s*$u\$" "$RECONCILE" || fail "node-local exemption list must include $u (the role-scoped reconcile must never reap it)"
done
pass "node-local exemption list covers worker/heartbeat/sentinel/process-heal + the reconcile's own beat"

# ── 3b. RESILIENT-1687: migrate-root-organs renders the ubuntu drop-ins + the ─
# chown list for EXACTLY chump-fleet-health-sentinel + chump-node-heartbeat.
# #5625 (RESILIENT-1683) landed only the render *test*; this locks the tracked
# RENDERER that actually writes the two units off the /root/.chumpnode install
# onto User=ubuntu running the repo copies. Portable (grep/sed -E only, no
# `sed -i`), so it runs here BEFORE the GNU-sed gate below. Each assertion is
# killed by a mutant inline before it is trusted on real renderer output.
MIGRATE="$REPO_ROOT/scripts/ops/migrate-root-organs-to-ubuntu.sh"
HEARTBEAT_ORGAN="$REPO_ROOT/scripts/ops/node-heartbeat.sh"
[ -f "$MIGRATE" ] || fail "RESILIENT-1687: renderer missing: $MIGRATE"
[ -f "$HEARTBEAT_ORGAN" ] || fail "RESILIENT-1687: node-heartbeat repo copy missing: $HEARTBEAT_ORGAN (installer wrapper was never a repo file)"
bash -n "$MIGRATE" || fail "RESILIENT-1687: $MIGRATE fails bash -n"
bash -n "$HEARTBEAT_ORGAN" || fail "RESILIENT-1687: $HEARTBEAT_ORGAN fails bash -n"

# The repo heartbeat organ resolves its state dir from $HOME ONLY (the standing
# -rule seam) — never a CHUMP_STATE_DIR env default, which would be a safety
# -input bypass.
grep -qE '="\$HOME/\.chump"' "$HEARTBEAT_ORGAN" \
  || fail "RESILIENT-1687: node-heartbeat.sh must resolve STATE from \$HOME (the standing-rule seam)"
grep -qE '\$\{?CHUMP_STATE_DIR' "$HEARTBEAT_ORGAN" \
  && fail "RESILIENT-1687: node-heartbeat.sh must NOT read a \$CHUMP_STATE_DIR env default (safety-input bypass)"

# _r1687_user_ok <dropin-text-file> -> 0 iff a non-empty, non-root User= is set.
_r1687_user_ok() { local u; u="$(sed -n 's/^User=//p' "$1" | head -1)"; [ -n "$u" ] && [ "$u" != root ]; }
# _r1687_list_has <list-file> <path> -> 0 iff the chown list contains <path> exactly.
_r1687_list_has() { grep -qxF "$2" "$1"; }

R1687_T="$TMP/r1687"; mkdir -p "$R1687_T"
# Mutant 1: a drop-in with NO User= line (the root-write trap) must FAIL the check.
printf '[Service]\nExecStart=/home/ubuntu/chump/scripts/ops/node-heartbeat.sh\n' > "$R1687_T/mut-nouser.conf"
_r1687_user_ok "$R1687_T/mut-nouser.conf" && fail "RESILIENT-1687 mutant: a drop-in with no User= must fail the user check"
printf '[Service]\nUser=root\n' > "$R1687_T/mut-rootuser.conf"
_r1687_user_ok "$R1687_T/mut-rootuser.conf" && fail "RESILIENT-1687 mutant: a drop-in with User=root must fail the user check"
# Mutant 2: a chown list missing the heartbeat path must FAIL the contains-check.
printf '/home/ubuntu/.chump/fleet-health-sentinel.heartbeat\n' > "$R1687_T/mut-droppath.list"
_r1687_list_has "$R1687_T/mut-droppath.list" "/home/ubuntu/.chump/node-heartbeat" \
  && fail "RESILIENT-1687 mutant: a chown list missing /home/ubuntu/.chump/node-heartbeat must fail the contains-check"
pass "RESILIENT-1687 assertions are mutant-killed: no-User / User=root fail the user check; a dropped chown path fails the contains-check"

# Real renderer, production target (User=ubuntu, /home/ubuntu paths) — AC1 shape.
for u in chump-fleet-health-sentinel chump-node-heartbeat; do
  d="$R1687_T/$u.conf"
  bash "$MIGRATE" --home /home/ubuntu --user ubuntu --repo /home/ubuntu/chump --render-dropin "$u" > "$d" \
    || fail "RESILIENT-1687: renderer failed for $u"
  grep -qx 'User=ubuntu' "$d" || fail "RESILIENT-1687: $u drop-in missing User=ubuntu (root-write trap): $(cat "$d")"
  _r1687_user_ok "$d" || fail "RESILIENT-1687: $u drop-in User= is empty or root"
  grep -qxF 'EnvironmentFile=-/home/ubuntu/.chump/providers.env' "$d" \
    || fail "RESILIENT-1687: $u drop-in must load providers.env from the ubuntu home: $(grep EnvironmentFile "$d")"
  # ExecStart must be cleared (reset line) then re-pointed at the repo copy.
  grep -qx 'ExecStart=' "$d" || fail "RESILIENT-1687: $u drop-in must clear the inherited ExecStart with an empty ExecStart= line"
  grep -qE "^ExecStart=/usr/bin/env bash /home/ubuntu/chump/scripts/ops/" "$d" \
    || fail "RESILIENT-1687: $u ExecStart must run the repo copy under /home/ubuntu/chump: $(grep '^ExecStart=' "$d")"
done
grep -qE '^ExecStart=/usr/bin/env bash /home/ubuntu/chump/scripts/ops/fleet-health-sentinel\.sh --local --loop$' "$R1687_T/chump-fleet-health-sentinel.conf" \
  || fail "RESILIENT-1687: the sentinel must run --local --loop from the repo copy"
grep -qE '^ExecStart=/usr/bin/env bash /home/ubuntu/chump/scripts/ops/node-heartbeat\.sh$' "$R1687_T/chump-node-heartbeat.conf" \
  || fail "RESILIENT-1687: node-heartbeat must run the repo copy"
pass "RESILIENT-1687: renderer writes both drop-ins User=ubuntu, providers.env under /home/ubuntu, ExecStart cleared + re-pointed at the repo copies"

# The home/user/repo are an explicit-CLI seam (never a CHUMP_* env) — prove a
# non-default target flows all the way through the rendered unit.
bash "$MIGRATE" --home /srv/sbx --user sbxuser --repo /srv/sbx/chump --render-dropin chump-node-heartbeat > "$R1687_T/seam.conf" \
  || fail "RESILIENT-1687: renderer failed for the seam check"
grep -qx 'User=sbxuser' "$R1687_T/seam.conf" || fail "RESILIENT-1687: --user must flow into User= (explicit-CLI seam)"
grep -qxF 'EnvironmentFile=-/srv/sbx/.chump/providers.env' "$R1687_T/seam.conf" || fail "RESILIENT-1687: --home must flow into EnvironmentFile="
grep -qE '^ExecStart=/usr/bin/env bash /srv/sbx/chump/scripts/ops/node-heartbeat\.sh$' "$R1687_T/seam.conf" || fail "RESILIENT-1687: --repo must flow into ExecStart="
pass "RESILIENT-1687: home/user/repo are an explicit-CLI seam — a non-default target renders through without any env default"

# Chown list is parsed FROM THE REAL organ scripts in this checkout; resolve
# against /home/ubuntu. Every state file both organs write must appear.
bash "$MIGRATE" --home /home/ubuntu --repo "$REPO_ROOT" --chown-list > "$R1687_T/chown.list" \
  || fail "RESILIENT-1687: --chown-list failed"
for p in \
  /home/ubuntu/.chump/node-heartbeat \
  /home/ubuntu/.chump/fleet-health-sentinel.heartbeat \
  /tmp/chump-reaper-fleet-health-sentinel.heartbeat; do
  _r1687_list_has "$R1687_T/chown.list" "$p" \
    || fail "RESILIENT-1687: chown list (from the scripts) must include $p; got: $(cat "$R1687_T/chown.list")"
done
# Nothing under /root must ever appear — the whole point is to leave the root install.
grep -q '/root/' "$R1687_T/chown.list" && fail "RESILIENT-1687: chown list leaked a /root path: $(cat "$R1687_T/chown.list")"
pass "RESILIENT-1687: chown list parsed from the organ scripts covers both heartbeat files + the reaper beat, resolved under /home/ubuntu, no /root leak"

# ── 3c. RESILIENT-1687 (AC6/AC7): the node installer EMITS the tracked heartbeat
# organ VERBATIM — one source, no inline heredoc. #5639 pre-push review: the
# installer (scripts/setup/chump-node-install.sh) used to generate its OWN inline
# node-heartbeat.sh wrapper that had already drifted from the repo copy
# (${CHUMP_STATE_DIR:-$HOME/.chump} vs $HOME-only). This locks that the installer
# now installs scripts/ops/node-heartbeat.sh byte-for-byte and that no second
# (inline) source survives. Killed by a mutant on EITHER side.
NODE_INSTALL="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$NODE_INSTALL" ] || fail "RESILIENT-1687: node installer missing: $NODE_INSTALL"

# _r1687_one_source <installer-file> -> 0 iff it installs the TRACKED
# scripts/ops/node-heartbeat.sh into $ORGAN_DIR AND carries NO inline heredoc
# that regenerates the organ (the drift-prone second source).
_r1687_one_source() {
  local f="$1"
  grep -qE 'tracked_heartbeat=.*scripts/ops/node-heartbeat\.sh' "$f" || return 1
  grep -qE "install -m755 .*tracked_heartbeat.*ORGAN_DIR/node-heartbeat\.sh" "$f" || return 1
  if grep -qF "cat > '\$ORGAN_DIR/node-heartbeat.sh'" "$f"; then return 1; fi
  return 0
}

# Installer-side mutant: a copy that re-grows the inline heredoc must FAIL the
# one-source check (proving the check is real) before we trust it on the installer.
R1687_INST_MUT="$TMP/chump-node-install.inline.sh"
cp "$NODE_INSTALL" "$R1687_INST_MUT"
cat >> "$R1687_INST_MUT" <<'MUT'
__mut_second_source(){ cat > '$ORGAN_DIR/node-heartbeat.sh' <<'HB'
#!/usr/bin/env bash
STATE="${CHUMP_STATE_DIR:-$HOME/.chump}"
HB
}
MUT
_r1687_one_source "$R1687_INST_MUT" \
  && fail "RESILIENT-1687 mutant: an installer that regenerates node-heartbeat.sh inline must fail the one-source check"
# The real installer passes.
_r1687_one_source "$NODE_INSTALL" \
  || fail "RESILIENT-1687 (AC6): chump-node-install.sh must install the tracked scripts/ops/node-heartbeat.sh with no inline heredoc (one source)"

# Byte-identity: the installer emits via `install -m755 <tracked>`; simulate that
# exact emission and assert it is byte-for-byte the tracked organ (AC7).
R1687_EMIT="$TMP/r1687-emit"; mkdir -p "$R1687_EMIT"
install -m755 "$HEARTBEAT_ORGAN" "$R1687_EMIT/node-heartbeat.sh" \
  || fail "RESILIENT-1687: could not simulate the installer's node-heartbeat emission"
cmp -s "$R1687_EMIT/node-heartbeat.sh" "$HEARTBEAT_ORGAN" \
  || fail "RESILIENT-1687 (AC7): installer-emitted node-heartbeat.sh is not byte-identical to the tracked repo copy"
# Tracked-side mutant: if the tracked organ drifts by even one byte, the emitted
# copy no longer matches the canonical — proving the cmp check is a real detector.
R1687_HB_MUT="$TMP/node-heartbeat.mutant.sh"
cp "$HEARTBEAT_ORGAN" "$R1687_HB_MUT"
printf '# RESILIENT-1687 tracked-side mutant\n' >> "$R1687_HB_MUT"
install -m755 "$R1687_HB_MUT" "$R1687_EMIT/node-heartbeat.sh"
cmp -s "$R1687_EMIT/node-heartbeat.sh" "$HEARTBEAT_ORGAN" \
  && fail "RESILIENT-1687 mutant: a byte-edited tracked node-heartbeat.sh must break the installer byte-identity check (AC7 detector proven)"
pass "RESILIENT-1687 (AC6/AC7): installer installs the tracked node-heartbeat.sh byte-for-byte; no inline second source; mutants on either side killed"

# ── 3d. RESILIENT-1687 (AC4): the /root installs are ARCHIVED (move aside +
# marker), NEVER deleted, and a path a loaded unit still references is HELD (the
# "once nothing execs them" precondition). archive-plan is read-only; exercise
# its three verdicts on a sandbox. The path-boundary scan is mutant-killed inline.
R1687_AR="$TMP/r1687-archive"; mkdir -p "$R1687_AR/root/.chumpnode" "$R1687_AR/root/.chump" "$R1687_AR/units"
# a unit that still execs /root/.chumpnode -> that path must be HELD.
printf '[Service]\nExecStart=/bin/bash %s/root/.chumpnode/organs/x.sh\n' "$R1687_AR" > "$R1687_AR/units/chump-x.service"

_r1687_plan() {
  bash "$MIGRATE" --archive-plan --scan-dir "$R1687_AR/units" \
    --archive-path "$R1687_AR/root/.chumpnode" \
    --archive-path "$R1687_AR/root/.chump" \
    --archive-path "$R1687_AR/root/.absent"
}
R1687_PLAN="$R1687_AR/plan.out"
_r1687_plan > "$R1687_PLAN" || fail "RESILIENT-1687 (AC4): --archive-plan failed"
# referenced path -> HELD (never archived while a unit execs it).
grep -qE "^HELD $R1687_AR/root/\.chumpnode " "$R1687_PLAN" \
  || fail "RESILIENT-1687 (AC4): a /root install a loaded unit still execs must be HELD; got: $(cat "$R1687_PLAN")"
# the sibling .chump (unreferenced; NOT falsely held by the .chumpnode substring)
# -> ARCHIVE to a move-aside path, never deleted.
grep -qE "^ARCHIVE $R1687_AR/root/\.chump -> $R1687_AR/root/\.chump\.archived-resilient-1687\$" "$R1687_PLAN" \
  || fail "RESILIENT-1687 (AC4): a clear /root install must be ARCHIVEd (move aside), never deleted; got: $(cat "$R1687_PLAN")"
grep -qE "^SKIP $R1687_AR/root/\.absent\$" "$R1687_PLAN" \
  || fail "RESILIENT-1687 (AC4): an absent path must be SKIPped; got: $(cat "$R1687_PLAN")"
# the plan NEVER proposes a destructive op — archived, not removed.
if grep -qiE '\b(rm|delete|remove|rmdir)\b' "$R1687_PLAN"; then
  fail "RESILIENT-1687 (AC4): archive-plan must never propose deleting a /root install; got: $(cat "$R1687_PLAN")"
fi
pass "RESILIENT-1687 (AC4): archive-plan HELDs a still-referenced install, ARCHIVEs a clear sibling (no substring false-hold), SKIPs absent — never deletes"

# ── 4. host-rewrite core transforms ──────────────────────────────────────────
# organ_unit_host_rewrite uses GNU `sed -i` (in-place append/insert), which is
# how the units are placed on their Linux deploy targets. On a non-GNU sed
# (macOS/BSD dev box) skip this part — the units never deploy there, and CI runs
# on ubuntu where it executes for real.
if ! sed --version 2>/dev/null | grep -qi gnu; then
  echo "SKIP host-rewrite transforms (non-GNU sed — Linux-deploy-only; runs for real on CI ubuntu)"
  echo "ALL PASS"; exit 0
fi
source "$LIB_UNIT"
# INFRA-8571: the source is a placeholder TEMPLATE (__HOME__ / __REPO_ROOT__,
# no User= line). The rewriter resolves the placeholders and injects the
# host-agnostic runtime context; a baked /root/ or User= literal would now be
# refused loudly (section 4b).
# Use a $TMP run-home (no pre-existing Projects/chump symlink) so the 5-arg
# fallback is deterministic on any machine — a dev box whose real
# $HOME/Projects/chump is a bootstrap symlink would otherwise realpath-collapse
# the fallback and make this assertion machine-dependent.
RH="$TMP/rh"; mkdir -p "$RH"
SRCU="$TMP/tpl-unit.service"
cat > "$SRCU" <<'EOF'
[Unit]
Description=x
[Service]
Environment=HOME=__HOME__
ExecStart=__REPO_ROOT__/scripts/x.sh
EOF
DESTU="$TMP/out.service"
organ_unit_host_rewrite "$SRCU" "$DESTU" "ubuntu" "$RH" 0 || fail "host_rewrite returned non-zero"
grep -q '^User=ubuntu$' "$DESTU" || fail "host_rewrite: system scope must inject User=ubuntu"
grep -q "^Environment=HOME=${RH}\$" "$DESTU" || fail "host_rewrite: __HOME__ should resolve to the run-home (the instruments-lie keystone)"
# 5-arg call (no repo_root): __REPO_ROOT__ falls back to $HOME/Projects/chump.
grep -q "^ExecStart=${RH}/Projects/chump/scripts/x.sh\$" "$DESTU" || fail "host_rewrite: __REPO_ROOT__ should resolve to the run-home repo (legacy default)"
# keep-root
organ_unit_host_rewrite "$SRCU" "$DESTU" "ubuntu" "$RH" 1 || fail "host_rewrite keep-root returned non-zero"
grep -q '^User=root$' "$DESTU" || fail "host_rewrite keep-root: User must stay root"
pass "organ_unit_host_rewrite: placeholder resolution, User inject, __HOME__ resolve, keep-root all hold"

# ── 4b. INFRA-8571: a baked host literal is REFUSED, not patched ─────────────
# The legacy source-home sed rules are gone; a unit that still carries a baked
# /root/ path or User= line fails install LOUDLY so the gate is the only path.
SRCBAD="$TMP/baked-literal.service"
cat > "$SRCBAD" <<'EOF'
[Unit]
Description=x
[Service]
User=root
ExecStart=/root/Projects/chump/scripts/x.sh
EOF
organ_unit_host_rewrite "$SRCBAD" "$TMP/out-bad.service" "ubuntu" "/home/ubuntu" 0 2>/dev/null \
  && fail "a source with a baked /root/ + User= literal must be refused (INFRA-8571)"
pass "organ_unit_host_rewrite refuses a baked host literal instead of patching it"

# ── 5. RESILIENT-1102: __REPO_ROOT__ resolves to the REAL checkout, so units ──
# never point at a non-existent $HOME/Projects/chump (the owned-node 200/CHDIR
# root — this whole class had ZERO test coverage before).
SRCR="$TMP/repo-unit.service"
cat > "$SRCR" <<'EOF'
[Unit]
Description=x
[Service]
Environment=HOME=__HOME__
Environment=CHUMP_REPO_ROOT=__REPO_ROOT__
WorkingDirectory=__REPO_ROOT__
ExecStart=/bin/bash -lc 'source __HOME__/.chump/providers.env; cd __REPO_ROOT__; exec __REPO_ROOT__/scripts/ops/x.sh'
EOF
# The box's real repo lives at $HOME/chump (NO Projects segment) — and it EXISTS.
# Compare against its PHYSICAL path: the rewriter now realpath-resolves the repo
# root (so a bootstrap symlink can never be baked in), and on macOS $TMP itself
# sits under /var -> /private/var, so the resolved output differs from the raw
# $TMP path. Resolving here also hardens the test against any symlinked TMPDIR.
REAL_REPO="$TMP/home-ubuntu/chump"; mkdir -p "$REAL_REPO"
REAL_REPO="$(cd "$REAL_REPO" && pwd -P)"
DESTR="$TMP/out-repo.service"
organ_unit_host_rewrite "$SRCR" "$DESTR" "ubuntu" "$TMP/home-ubuntu" 0 "$REAL_REPO" || fail "host_rewrite(repo_root) returned non-zero"
# Every repo reference resolves to the real checkout; home-only paths (.chump)
# still track the run-home.
grep -q "^WorkingDirectory=${REAL_REPO}\$" "$DESTR" || fail "repo_root: WorkingDirectory not rewritten to the real checkout: $(grep -n '^WorkingDirectory=' "$DESTR")"
grep -q "^Environment=CHUMP_REPO_ROOT=${REAL_REPO}\$" "$DESTR" || fail "repo_root: CHUMP_REPO_ROOT not rewritten: $(grep -n CHUMP_REPO_ROOT "$DESTR")"
grep -q "cd ${REAL_REPO};" "$DESTR" || fail "repo_root: inline 'cd <repo>' not rewritten: $(grep -n ExecStart "$DESTR")"
grep -q "exec ${REAL_REPO}/scripts/ops/x.sh" "$DESTR" || fail "repo_root: ExecStart repo path not rewritten: $(grep -n ExecStart "$DESTR")"
grep -q "source ${TMP}/home-ubuntu/.chump/providers.env" "$DESTR" || fail "repo_root: home-only .chump path should track run-home, not the repo: $(grep -n ExecStart "$DESTR")"
grep -q 'Projects/chump' "$DESTR" && fail "repo_root: a stale Projects/chump path leaked into the unit: $(grep -n 'Projects/chump' "$DESTR")"
# THE class that hid: the baked WorkingDirectory must be a directory that
# actually exists on disk (a non-existent cwd is status=200/CHDIR at runtime).
_wd="$(sed -n 's/^WorkingDirectory=//p' "$DESTR")"
[ -d "$_wd" ] || fail "repo_root: baked WorkingDirectory '$_wd' does not exist on disk (this is the 200/CHDIR bug)"
pass "organ_unit_host_rewrite: repo_root redirects every repo path to the real (existing) checkout — no Projects/chump ghost, WorkingDirectory exists"

# ── 6. RESILIENT-1102 residue: a SYMLINKED repo_root is collapsed to the REAL ─
# on-disk checkout, so a hand-bootstrapped symlink (e.g. $HOME/Projects/chump ->
# $HOME/chump) never gets baked into the units — otherwise that bootstrap symlink
# stays permanently load-bearing and can never be retired.
REAL2="$TMP/box/chump"; mkdir -p "$REAL2"
REAL2="$(cd "$REAL2" && pwd -P)"               # physical (see section 5 note)
mkdir -p "$TMP/box/Projects"
ln -s "$REAL2" "$TMP/box/Projects/chump"       # the bootstrap symlink
LINK2="$TMP/box/Projects/chump"
DESTS="$TMP/out-symlink.service"
organ_unit_host_rewrite "$SRCR" "$DESTS" "ubuntu" "$TMP/box" 0 "$LINK2" || fail "host_rewrite(symlink repo_root) returned non-zero"
grep -q "^WorkingDirectory=${REAL2}\$" "$DESTS" || fail "symlink repo_root: WorkingDirectory must bake the REAL checkout, not the symlink: $(grep -n '^WorkingDirectory=' "$DESTS")"
grep -q "Projects/chump" "$DESTS" && fail "symlink repo_root: the bootstrap symlink path leaked into the unit (still load-bearing): $(grep -n 'Projects/chump' "$DESTS")"
pass "organ_unit_host_rewrite: a symlinked repo_root collapses to the real checkout — the bootstrap symlink is not baked in and can be retired"

# ── 7. RESILIENT-1508: organ_unit_execstart_resolves ────────────────────────
# Proves the installer can tell, PER UNIT, whether its own ExecStart binary
# actually resolves on the PATH/User baked into that unit — the gate that
# would have refused to enable cuphead's self-doctor/paramedic/conductor
# (pinned to a /root/.chumpnode checkout whose bin/ was never built) instead
# of silently enabling an exit-127 timer.
mkdir -p "$TMP/fakebin"
touch "$TMP/fakebin/chump"; chmod +x "$TMP/fakebin/chump"

RESOLVES="$TMP/resolves.service"
cat > "$RESOLVES" <<EOF
[Unit]
Description=x
[Service]
User=ubuntu
Environment=PATH=$TMP/fakebin:/usr/bin:/bin
ExecStart=/bin/bash -c 'set -a; source /home/ubuntu/.chump/providers.env 2>/dev/null; set +a; exec chump self-rescue-loop'
EOF
reason=""
organ_unit_execstart_resolves "$RESOLVES" reason \
  || fail "execstart_resolves: should resolve when chump is on the unit's own PATH (reason=$reason)"
pass "organ_unit_execstart_resolves: resolves a bare command present on the unit's Environment=PATH="

UNRESOLVED="$TMP/unresolved.service"
cat > "$UNRESOLVED" <<EOF
[Unit]
Description=x
[Service]
User=root
Environment=PATH=/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash -c 'set -a; source /root/.chump/providers.env 2>/dev/null; set +a; exec chump self-rescue-loop'
EOF
reason=""
if organ_unit_execstart_resolves "$UNRESOLVED" reason; then
  fail "execstart_resolves: should NOT resolve when chump is absent from the unit's own PATH"
fi
[[ "$reason" == missing_bin_on_unit_path:chump ]] || fail "execstart_resolves: wrong reason: $reason"
pass "organ_unit_execstart_resolves: refuses (missing_bin_on_unit_path) the exact cuphead exit-127 shape — User=root/PATH=/root/.cargo/bin with no chump symlinked there"

ABSPATH="$TMP/abspath.service"
cat > "$ABSPATH" <<EOF
[Unit]
Description=x
[Service]
ExecStart=$TMP/fakebin/chump self-rescue-loop
EOF
reason=""
organ_unit_execstart_resolves "$ABSPATH" reason \
  || fail "execstart_resolves: an absolute ExecStart path should resolve via -x directly (reason=$reason)"
pass "organ_unit_execstart_resolves: resolves a direct absolute-path ExecStart"

ABSMISSING="$TMP/absmissing.service"
cat > "$ABSMISSING" <<EOF
[Unit]
Description=x
[Service]
ExecStart=$TMP/fakebin/does-not-exist self-rescue-loop
EOF
reason=""
if organ_unit_execstart_resolves "$ABSMISSING" reason; then
  fail "execstart_resolves: a non-existent absolute ExecStart path must not resolve"
fi
[[ "$reason" == binary_not_executable:* ]] || fail "execstart_resolves: wrong reason: $reason"
pass "organ_unit_execstart_resolves: refuses a non-existent absolute ExecStart path"

# ── 8. RESILIENT-1508: install-helsinki-atc.sh rosters the self-rescue organs
# and gates their enable on organ_unit_execstart_resolves.
ATC_INSTALLER="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
for u in chump-self-doctor chump-paramedic chump-conductor; do
  grep -q "^  ${u}.service\$" "$ATC_INSTALLER" || fail "install-helsinki-atc.sh SYSTEM_UNITS missing ${u}.service"
  grep -q "^  ${u}.timer\$" "$ATC_INSTALLER" || fail "install-helsinki-atc.sh SYSTEM_UNITS missing ${u}.timer"
  grep "^SYSTEM_TIMERS=(" "$ATC_INSTALLER" | grep -q "${u}.timer" || fail "install-helsinki-atc.sh SYSTEM_TIMERS missing ${u}.timer"
done
grep -q "organ_unit_execstart_resolves" "$ATC_INSTALLER" || fail "install-helsinki-atc.sh does not call organ_unit_execstart_resolves before enabling"
pass "install-helsinki-atc.sh rosters self-doctor/paramedic/conductor and gates enable on organ_unit_execstart_resolves"

# ── 9. RESILIENT-1683: node-refresh renders every system-scope chump unit with ─
# User=ubuntu and never execs a script outside the two allowed repo roots. The
# tracked renderer (organ_unit_host_rewrite — the shell mirror node-refresh and
# install-helsinki-atc.sh share) resolves every placeholder template to an ubuntu
# node; this section renders every unit in the system-scope SYSTEM_UNITS roster
# and asserts two safety invariants the un-pause receipt (item 8) gates on:
#   (a) a non-empty, non-root User= (a hand-installed unit with an empty User ran
#       as root — the fleet-health-sentinel / node-heartbeat root-write trap);
#   (b) no EXECUTED script path (ExecStart argv[0], and the `exec <script>` target
#       of a `/bin/bash -c '…'` wrapper) lies outside /home/ubuntu/chump or
#       /home/ubuntu/.chumpnode/repo — the "chump-coo-gateway execs
#       /home/ubuntu/coo/run.sh" class. Sourced config (~/.chump/providers.env)
#       and built binaries (~/.cargo/bin/chump-integrator) are NOT executed
#       scripts and are not in scope — only a shell-script path is.
# Each assertion is killed by a mutant below (render one unit without a User;
# point one `exec` at /home/ubuntu/coo/run.sh).
R1683_ROOT_A="/home/ubuntu/chump"
R1683_ROOT_B="/home/ubuntu/.chumpnode/repo"

# _r1683_user_value <rendered-unit> -> first User= value (empty string if none)
_r1683_user_value() { sed -n 's/^User=//p' "$1" | head -1; }

# _r1683_user_ok <rendered-unit> -> 0 if User= is present and neither empty nor
# root; 1 otherwise. A [Service] unit with no User= line (the root-write trap)
# yields the empty string and fails.
_r1683_user_ok() {
  local u; u="$(_r1683_user_value "$1")"
  [ -n "$u" ] && [ "$u" != root ]
}

# _r1683_exec_scripts <rendered-unit> -> the EXECUTED shell-script paths of every
# ExecStart*/ExecStart line: the line's argv[0], plus the `exec <token>` target of
# a `/bin/bash -c '…; exec <script>'` wrapper. Only tokens that are a shell script
# (end in .sh, or name a repo `/scripts/` path) are emitted — a bare `chump`, a
# /usr/bin/python3 interpreter, a ~/.cargo/bin binary and a `source`d env file are
# not executed scripts and are deliberately excluded.
_r1683_exec_scripts() {
  local line val argv0 execs p
  while IFS= read -r line; do
    val="${line#*=}"
    argv0="$(printf '%s' "$val" | awk '{print $1}')"
    execs="$(printf '%s\n' "$val" | grep -oE 'exec "?[^ "'"'"';]+' | sed -E 's/^exec "?//')"
    for p in "$argv0" $execs; do
      p="${p%\'}"; p="${p%\"}"
      case "$p" in
        *.sh|*/scripts/*) printf '%s\n' "$p" ;;
      esac
    done
  done < <(grep -E '^ExecStart' "$1")
}

# _r1683_path_allowed <path> -> 0 if under an allowed repo root (or a system
# interpreter path), 1 otherwise.
_r1683_path_allowed() {
  case "$1" in
    # RESILIENT-1685: a reaped dispatch worktree lives UNDER the repo root
    # (/home/ubuntu/chump/.claude/worktrees/…), and /tmp is ephemeral — an
    # ExecStart under either is the cuphead exit-127-every-tick trap (a unit
    # installed from a worktree that was later reaped). Refuse both BEFORE the
    # allowed-root match, which would otherwise accept the worktree path as
    # "under /home/ubuntu/chump".
    */.claude/worktrees/*|/tmp|/tmp/*) return 1 ;;
    "$R1683_ROOT_A"|"$R1683_ROOT_A"/*|"$R1683_ROOT_B"|"$R1683_ROOT_B"/*) return 0 ;;
    /bin/*|/usr/*|/sbin/*|/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _r1683_render <template> <dest> -> render a tracked template to an ubuntu node,
# system scope (User injected), repo at the first allowed root. keep_root=0, so a
# keep-root organ's deliberate root-ness (applied by the installer, not the
# template) is never asserted here — every template must render to User=ubuntu.
_r1683_render() { organ_unit_host_rewrite "$1" "$2" "ubuntu" "/home/ubuntu" 0 "$R1683_ROOT_A"; }

# Self-test the two assertions against their mutants BEFORE trusting them on the
# real roster — an assertion that cannot fail proves nothing.
R1683_T="$TMP/r1683"; mkdir -p "$R1683_T"
cat > "$R1683_T/mut-nouser.service" <<'EOF'
[Unit]
Description=x
[Service]
Environment=HOME=/home/ubuntu
ExecStart=/bin/bash -c 'exec /home/ubuntu/chump/scripts/x.sh'
EOF
_r1683_user_ok "$R1683_T/mut-nouser.service" \
  && fail "mutant: a rendered unit with NO User= line must fail the user assertion"
cat > "$R1683_T/mut-rootuser.service" <<'EOF'
[Service]
User=root
ExecStart=/home/ubuntu/chump/scripts/x.sh
EOF
_r1683_user_ok "$R1683_T/mut-rootuser.service" \
  && fail "mutant: a rendered unit with User=root must fail the user assertion"
cat > "$R1683_T/mut-coo.service" <<'EOF'
[Service]
User=ubuntu
ExecStart=/bin/bash -c 'set -a; source /home/ubuntu/.chump/providers.env; set +a; exec /home/ubuntu/coo/run.sh'
EOF
_coo_flagged=0
while IFS= read -r _p; do _r1683_path_allowed "$_p" || _coo_flagged=1; done < <(_r1683_exec_scripts "$R1683_T/mut-coo.service")
[ "$_coo_flagged" = 1 ] || fail "mutant: an ExecStart that execs /home/ubuntu/coo/run.sh must fail the exec-path assertion"
# and the clean shape (User=ubuntu, repo exec, sourced env) must PASS both.
_r1683_user_ok "$R1683_T/mut-coo.service" || fail "self-test: User=ubuntu must pass the user assertion"
cat > "$R1683_T/ok.service" <<'EOF'
[Service]
User=ubuntu
ExecStart=/bin/bash -c 'set -a; source /home/ubuntu/.chump/providers.env; set +a; exec /home/ubuntu/chump/scripts/ops/x.sh'
EOF
_ok_flagged=0
while IFS= read -r _p; do _r1683_path_allowed "$_p" || _ok_flagged=1; done < <(_r1683_exec_scripts "$R1683_T/ok.service")
[ "$_ok_flagged" = 0 ] || fail "self-test: a repo-rooted exec must pass the exec-path assertion"
pass "RESILIENT-1683 assertions are mutant-killed: no-User and User=root fail the user check; an /home/ubuntu/coo exec fails the path check; repo-rooted + sourced-env passes"

# RESILIENT-1685 (AC2): the exec-path assertion must ALSO refuse a unit RENDERED
# from a reaped-prone dispatch worktree. A worktree checkout
# (/home/ubuntu/chump/.claude/worktrees/…) sits UNDER the allowed repo root, so
# before this slice _r1683_path_allowed accepted it — exactly the cuphead
# exit-127 trap, where chump-node-refresh.service execed a script in a worktree
# that was later reaped. Mutant: render one unit with the repo_root pointed at a
# dispatch worktree; the rendered exec MUST be flagged. (The renderer bakes
# __REPO_ROOT__ verbatim, so the worktree path need not exist on disk here.)
cat > "$R1683_T/mut-worktree.service" <<'EOF'
[Unit]
Description=x
[Service]
ExecStart=/bin/bash -lc 'set -a; source __HOME__/.chump/providers.env >/dev/null; set +a; exec __REPO_ROOT__/scripts/ops/x.sh'
EOF
R1683_WT_ROOT="$R1683_ROOT_A/.claude/worktrees/infra-8571"
organ_unit_host_rewrite "$R1683_T/mut-worktree.service" "$R1683_T/mut-worktree.out" "ubuntu" "/home/ubuntu" 0 "$R1683_WT_ROOT" \
  || fail "self-test: renderer should render a placeholder template even with a worktree repo_root"
_wt_flagged=0
while IFS= read -r _p; do _r1683_path_allowed "$_p" || _wt_flagged=1; done < <(_r1683_exec_scripts "$R1683_T/mut-worktree.out")
[ "$_wt_flagged" = 1 ] || fail "mutant: an ExecStart rendered from a .claude/worktrees/ repo root must fail the exec-path assertion (RESILIENT-1685)"
# A bare /tmp exec must also be refused (the other ephemeral ExecStart class).
_r1683_path_allowed "/tmp/infra-8571/scripts/ops/x.sh" \
  && fail "mutant: an ExecStart under /tmp must fail the exec-path assertion (RESILIENT-1685)"
pass "RESILIENT-1685 (AC2): an ExecStart rendered from a .claude/worktrees/ repo root (and any /tmp path) fails the exec-path assertion"

# Render EVERY system-scope chump unit (the SYSTEM_UNITS roster install-helsinki-
# atc.sh deploys) and assert both invariants on each.
R1683_ROSTER="$(sed -n '/^SYSTEM_UNITS=(/,/^)/p' "$ATC_INSTALLER" | grep -oE 'chump-[a-z0-9-]+\.service')"
[ -n "$R1683_ROSTER" ] || fail "RESILIENT-1683: SYSTEM_UNITS roster came back empty — cannot render every unit"
r1683_checked=0
for u in $R1683_ROSTER; do
  f="$REPO_ROOT/scripts/dispatch/$u"; [ -f "$f" ] || f="$REPO_ROOT/scripts/setup/$u"
  [ -f "$f" ] || fail "RESILIENT-1683: roster unit $u has no tracked template under scripts/dispatch or scripts/setup"
  out="$R1683_T/$u"
  _r1683_render "$f" "$out" || fail "RESILIENT-1683: renderer refused roster unit $u (host literal?) — a system-scope unit must render cleanly"
  grep -q '^\[Service\]' "$out" || continue   # a bare [Unit]-only file has no User to assert
  _r1683_user_ok "$out" || fail "RESILIENT-1683: roster unit $u rendered with an empty or root User= (got '$(_r1683_user_value "$out")') — the root-write trap"
  while IFS= read -r p; do
    _r1683_path_allowed "$p" || fail "RESILIENT-1683: roster unit $u execs a script outside the allowed repo roots: $p"
  done < <(_r1683_exec_scripts "$out")
  r1683_checked=$((r1683_checked + 1))
done
[ "$r1683_checked" -ge 20 ] || fail "RESILIENT-1683: only rendered $r1683_checked roster services — the roster scan is broken"
pass "RESILIENT-1683: all $r1683_checked system-scope roster services render User=ubuntu and exec only repo-rooted scripts"

# ── 9b. RESILIENT-1683 (AC2): the three named units render ONLY from a repo path
# or not at all. chump-coo-gateway and chump-node1-worker carry no tracked
# template (not at all); chump-discord-gateway's tracked template execs a repo
# script. Any tracked *.service for these names that renders is held to the
# exec-path invariant.
for name in chump-coo-gateway chump-node1-worker chump-discord-gateway; do
  found=0
  for f in "$REPO_ROOT"/scripts/dispatch/"$name".service "$REPO_ROOT"/scripts/setup/"$name".service; do
    [ -f "$f" ] || continue
    found=1
    out="$R1683_T/named-$name.service"
    if _r1683_render "$f" "$out" 2>/dev/null; then
      while IFS= read -r p; do
        _r1683_path_allowed "$p" || fail "RESILIENT-1683 (AC2): $name ($f) execs a script outside the allowed repo roots: $p"
      done < <(_r1683_exec_scripts "$out")
    fi
  done
  [ "$name" = chump-discord-gateway ] && [ "$found" = 0 ] \
    && fail "RESILIENT-1683 (AC2): chump-discord-gateway has no tracked template to render from the repo path"
done
pass "RESILIENT-1683 (AC2): coo-gateway/node1-worker render not-at-all; discord-gateway renders a repo-rooted exec"

# ── 10. RESILIENT-1685 (AC1/AC3): install-node-refresh-systemd.sh must never
# bake an ExecStart that execs node-refresh-chump.sh from a reaped-prone
# dispatch worktree (.claude/worktrees/…) or /tmp. LIVE ROOT CAUSE (cuphead
# 2026-10-21): the installer was invoked from a dispatch worktree, its
# `$(dirname "$0")/../ops/…` fallback resolved SCRIPT_SRC inside that worktree,
# the worktree was later reaped, and chump-node-refresh.service exited 127 every
# tick on a missing script — the node binary never refreshed and the review
# organ ran stale code for days. The installer must instead refuse LOUDLY
# (non-zero, no worktree ExecStart written) when the only copy on disk lives
# under a worktree/tmp and no stable checkout is available. Mutant: drop the
# _resolve_stable_script worktree-skip and the installer silently bakes the
# worktree path (exit 0) → this section fails.
R1685_INSTALLER="$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
[ -f "$R1685_INSTALLER" ] || fail "RESILIENT-1685: install-node-refresh-systemd.sh missing"
R1685_T="$TMP/r1685"
# A fake dispatch-worktree checkout holding the installer + the scripts it bakes.
R1685_WT="$R1685_T/host/chump/.claude/worktrees/infra-8571"
mkdir -p "$R1685_WT/scripts/setup" "$R1685_WT/scripts/ops" "$R1685_WT/scripts/coord"
cp "$R1685_INSTALLER" "$R1685_WT/scripts/setup/install-node-refresh-systemd.sh"
for s in scripts/ops/node-refresh-chump.sh scripts/coord/node-deploy-lag-watchdog.sh scripts/ops/node-script-host-refresh.sh; do
  [ -f "$REPO_ROOT/$s" ] && cp "$REPO_ROOT/$s" "$R1685_WT/$s"
done
# A fake HOME with NO stable checkout (~/.chumpnode/repo, ~/chump, …) so the only
# resolvable copy is the worktree one — the exact cuphead condition.
R1685_HOME="$R1685_T/fakehome"; mkdir -p "$R1685_HOME"
# Stub systemctl/loginctl so a guard-less (mutant) installer completes to exit 0
# rather than dying on a missing systemd user bus for the wrong reason.
R1685_BIN="$R1685_T/bin"; mkdir -p "$R1685_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R1685_BIN/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R1685_BIN/loginctl"
chmod +x "$R1685_BIN/systemctl" "$R1685_BIN/loginctl"

r1685_rc=0
env -u CHUMP_NODE_REPO -u CHUMP_NODE_BIN -u GH_TOKEN \
  HOME="$R1685_HOME" \
  PATH="$R1685_BIN:/usr/bin:/bin" \
  bash "$R1685_WT/scripts/setup/install-node-refresh-systemd.sh" > "$R1685_T/out.log" 2>&1 || r1685_rc=$?

R1685_UNIT="$R1685_HOME/.config/systemd/user/chump-node-refresh.service"
# (a) No unit may be written that execs from a worktree or /tmp.
if [ -f "$R1685_UNIT" ]; then
  r1685_exec="$(grep '^ExecStart=' "$R1685_UNIT" | head -1 || true)"
  case "$r1685_exec" in
    *.claude/worktrees/*|*/tmp/*)
      fail "RESILIENT-1685: installer baked a worktree/tmp ExecStart (the exit-127 trap): $r1685_exec" ;;
  esac
fi
# (b) With only a worktree copy and no stable checkout, the installer must refuse
# loudly (non-zero) — a loud install failure beats a silent exit-127 timer.
[ "$r1685_rc" -ne 0 ] \
  || fail "RESILIENT-1685: installer did NOT refuse to install from a reaped-prone dispatch worktree with no stable checkout (exit $r1685_rc) — the exit-127 trap would recur. out: $(cat "$R1685_T/out.log")"
pass "RESILIENT-1685 (AC1/AC3): install-node-refresh-systemd.sh refuses a worktree/tmp ExecStart and fails loudly when no stable checkout exists"

echo "ALL PASS"
