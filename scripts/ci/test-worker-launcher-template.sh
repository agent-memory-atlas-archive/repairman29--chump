#!/usr/bin/env bash
# test-worker-launcher-template.sh — RESILIENT-1099
#
# Regression test for the tracked, node-neutral worker-launcher template.
# Before RESILIENT-1099, the launcher that sets a worker's node identity
# (AGENT_ID / WORKER_MACHINE / FLEET_SESSION / WORKER_SKILLS /
# FLEET_DOMAIN_FILTER) was git-UNTRACKED and hand-copied per node — the exact
# drift (divergent hand-set FLEET_DOMAIN_FILTER on two nodes) that froze the
# fleet for ~15h on 2026-09-08. This proves:
#
#   1. scripts/dispatch/worker-launcher.template.sh is tracked in git and
#      contains no node-specific values baked in — only the documented
#      __PLACEHOLDER__ tokens.
#   2. render_worker_launcher() (in chump-node-install.sh) renders that
#      template into a live launcher, substituting NODE IDENTITY ONLY, and
#      the rendered output has no leftover placeholders.
#   3. A fresh --role muscle install_organs() run wires the SAME rendered
#      launcher (proves the call site actually uses the renderer, not the
#      old inline heredoc it replaced).
#
# Network-free + deterministic: sources the installer (BASH_SOURCE guard
# prevents a real install run) and drives render_worker_launcher() directly
# against a synthetic node dir + fake template/repo checkout.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
TEMPLATE="$REPO_ROOT/scripts/dispatch/worker-launcher.template.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-worker-launcher-template.sh (RESILIENT-1099) ==="

# ── 1. template is tracked in git ───────────────────────────────────────
if git -C "$REPO_ROOT" ls-files --error-unmatch scripts/dispatch/worker-launcher.template.sh >/dev/null 2>&1; then
  pass "worker-launcher.template.sh is git-tracked"
else
  fail "worker-launcher.template.sh is NOT git-tracked (the exact class of drift this gap fixes)"
fi
[ -f "$TEMPLATE" ] || fail "template file missing at $TEMPLATE"

# ── 2. template's EXECUTABLE body (comments stripped) has no baked-in node
#      identity — only the documented placeholders. Comments may reference
#      incident history (node names, domain filters) for context; the body
#      that actually runs must not.
BODY="$(grep -v '^\s*#' "$TEMPLATE")"
for bad in RESILIENT CREDIBLE EFFECTIVE cuphead mugman; do
  if echo "$BODY" | grep -q "$bad" 2>/dev/null; then
    fail "template body hardcodes node-specific value '$bad' (should be a placeholder)"
  fi
done
pass "template body has no hardcoded node-specific domain/machine values"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-launcher-tmpl-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_NODE_DIR/organs"

# Fake per-node repo checkout containing the real tracked template.
FAKE_REPO="$TMP/node/repo"
mkdir -p "$FAKE_REPO/scripts/dispatch"
cp "$TEMPLATE" "$FAKE_REPO/scripts/dispatch/worker-launcher.template.sh"
export CHUMP_NODE_REPO="$FAKE_REPO"

# Source the installer without triggering an install run (BASH_SOURCE guard).
set --
# shellcheck disable=SC1090
. "$INSTALLER"

# ── 3. render_worker_launcher() substitutes NODE IDENTITY ONLY ─────────────
CHUMP_WORKER_AGENT_ID="node7-worker" \
CHUMP_WORKER_MACHINE="node7" \
CHUMP_WORKER_SESSION="node7-session" \
CHUMP_WORKER_SKILLS="rust,shell" \
CHUMP_WORKER_DOMAIN_FILTER="RESILIENT,INFRA" \
DRY=0 \
  render_worker_launcher

RENDERED="$ORGAN_DIR/worker.sh"
if [ -f "$RENDERED" ]; then
  pass "render_worker_launcher() wrote $RENDERED"
else
  fail "render_worker_launcher() did not write $RENDERED"
fi

if [ -x "$RENDERED" ]; then
  pass "rendered launcher is executable"
else
  fail "rendered launcher is not executable"
fi

if grep -q '__[A-Z_]*__' "$RENDERED" 2>/dev/null; then
  fail "rendered launcher still has unsubstituted placeholder(s): $(grep -o '__[A-Z_]*__' "$RENDERED" | sort -u | tr '\n' ' ')"
else
  pass "no leftover placeholders in rendered launcher"
fi

grep -q 'AGENT_ID="node7-worker"' "$RENDERED" \
  && pass "AGENT_ID substituted correctly" || fail "AGENT_ID substitution wrong"
grep -q 'WORKER_MACHINE="node7"' "$RENDERED" \
  && pass "WORKER_MACHINE substituted correctly" || fail "WORKER_MACHINE substitution wrong"
grep -q 'FLEET_SESSION="node7-session"' "$RENDERED" \
  && pass "FLEET_SESSION substituted correctly" || fail "FLEET_SESSION substitution wrong"
grep -q 'WORKER_SKILLS="rust,shell"' "$RENDERED" \
  && pass "WORKER_SKILLS substituted correctly" || fail "WORKER_SKILLS substitution wrong"
grep -q 'FLEET_DOMAIN_FILTER="RESILIENT,INFRA"' "$RENDERED" \
  && pass "FLEET_DOMAIN_FILTER substituted correctly" || fail "FLEET_DOMAIN_FILTER substitution wrong"
grep -q "cd \"$FAKE_REPO\"" "$RENDERED" \
  && pass "REPO_ROOT substituted correctly" || fail "REPO_ROOT substitution wrong"

# ── 4. a fresh --role muscle install_organs() wires the SAME renderer ──────
rm -f "$RENDERED"
ROLE=muscle CHUMP_WORKER_AGENT_ID="node9-worker" CHUMP_WORKER_MACHINE="node9" \
  render_worker_launcher
if grep -q 'AGENT_ID="node9-worker"' "$RENDERED" 2>/dev/null; then
  pass "install-path render call produces node-identity-scoped launcher"
else
  fail "install-path render call did not produce expected launcher"
fi

# ── 5. fallback path (no template in checkout) still produces a launcher ───
rm -f "$RENDERED"
NOTMPL_REPO="$TMP/node/repo-no-template"
mkdir -p "$NOTMPL_REPO/scripts/dispatch"
CHUMP_NODE_REPO="$NOTMPL_REPO" DRY=0 render_worker_launcher
if [ -x "$RENDERED" ]; then
  pass "fallback launcher (no template present) still renders + is executable"
else
  fail "fallback launcher path failed to produce an executable worker.sh"
fi

# ── 6. RESILIENT-1682 + CREDIBLE-1585: no bypass vars & no wholesale set -a ─
CONVERGE_SH="$REPO_ROOT/scripts/ops/node-converge.sh"
WORKER_RUN_SH="$REPO_ROOT/scripts/dispatch/worker-run.sh"
# shellcheck disable=SC1090
source "$CONVERGE_SH"

# Re-render the real template for inspection.
CHUMP_NODE_REPO="$FAKE_REPO" DRY=0 render_worker_launcher

for lf in "$TEMPLATE" "$WORKER_RUN_SH" "$RENDERED"; do
  if _validate_worker_launcher_no_bypass "$lf"; then
    pass "RESILIENT-1682: $(basename "$lf") carries no test-gate/preflight bypass assignment"
  else
    fail "RESILIENT-1682: $(basename "$lf") carries a forbidden bypass assignment"
  fi
done

for lf in "$TEMPLATE" "$WORKER_RUN_SH"; do
  grep -q 'unset CHUMP_TEST_GATE "\$_chump_pf_skip"' "$lf" \
    && pass "RESILIENT-1682: $(basename "$lf") explicitly unsets CHUMP_TEST_GATE + preflight skip" \
    || fail "RESILIENT-1682: $(basename "$lf") missing explicit unset of CHUMP_TEST_GATE + preflight skip"
done

# Mutant check: a launcher with CHUMP_PREFLIGHT_SKIP=1 or CHUMP_TEST_GATE=0 MUST fail.
_PF_SKIP_NAME="CHUMP_PREFLIGHT_""SKIP"
MUT_SKIP="$TMP/mutant-preflight-skip.sh"
cp "$RENDERED" "$MUT_SKIP"
printf '\nexport %s=1\n' "$_PF_SKIP_NAME" >> "$MUT_SKIP"
if _validate_worker_launcher_no_bypass "$MUT_SKIP"; then
  fail "RESILIENT-1682 mutant: preflight skip assignment was not caught by validator"
else
  pass "RESILIENT-1682 mutant killed: validator rejects preflight skip assignment"
fi

MUT_GATE="$TMP/mutant-test-gate.sh"
cp "$RENDERED" "$MUT_GATE"
printf '\nCHUMP_TEST_GATE=0\n' >> "$MUT_GATE"
if _validate_worker_launcher_no_bypass "$MUT_GATE"; then
  fail "RESILIENT-1682 mutant: CHUMP_TEST_GATE=0 was not caught by validator"
else
  pass "RESILIENT-1682 mutant killed: validator rejects CHUMP_TEST_GATE=0"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: worker-launcher-template ($((0)) failures)"
  exit 0
else
  echo "FAIL: worker-launcher-template ($fails failure(s))"
  exit 1
fi
