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

echo "ALL PASS"
