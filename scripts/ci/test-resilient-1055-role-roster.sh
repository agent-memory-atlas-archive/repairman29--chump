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

echo "ALL PASS"
