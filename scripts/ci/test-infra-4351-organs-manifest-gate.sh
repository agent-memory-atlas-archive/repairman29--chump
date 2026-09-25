#!/usr/bin/env bash
# scripts/ci/test-infra-4351-organs-manifest-gate.sh — INFRA-4351
# (INFRA-3641 slice: "Refactor install_organs() to parse organ-manifest.txt
# and invoke svc_install/svc_up")
#
# Proves install_organs() in chump-node-install.sh:
#   1. reads scripts/ops/organ-manifest.txt (via CHUMP_ORGAN_MANIFEST) and
#      only treats `enabled` lines as candidates — `paging_off` lines are
#      never installed.
#   2. for each candidate organ it still applicable, calls svc_install
#      followed by svc_up (unchanged happy path).
#   3. an organ that is declared but NOT applicable to this install (wrong
#      role= scope, or an unmet requires= precondition) is SKIPPED without
#      the script failing — no svc_install/svc_up call, exit code 0.
#   4. an organ with NO line in the manifest at all keeps pre-INFRA-4351
#      behavior: it still installs whenever role-selected (the manifest is
#      additive coverage, not a second required declaration).
#
# Network-free + deterministic: install_organs() is sourced and driven
# directly against a scratch NODE_DIR, same harness shape as
# test-resilient-1016-muscle-self-clean.sh / test-resilient-746-organ-role-reconcile.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"

[[ -f "$INSTALLER" ]] || { echo "FAIL: installer missing: $INSTALLER"; exit 1; }
bash -n "$INSTALLER" || { echo "FAIL: chump-node-install.sh syntax"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-infra-4351-organs-manifest-gate.sh (INFRA-4351) ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-4351-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── scenario A: paging_off + role-mismatch + unmet-requires all skip cleanly ─
GATE_MANIFEST="$TMP/manifest-gate.txt"
cat > "$GATE_MANIFEST" <<'EOF'
paging_off  chump-fleet-health-sentinel.service
enabled     chump-worker.service             role=brain
enabled     chump-process-organ-heal.service  role=muscle requires=bin:chump-4351-totally-fake-binary
EOF

ATMP="$TMP/install-a"
mkdir -p "$ATMP/node/bin" "$ATMP/node/organs" "$ATMP/node/logs"
(
  set --
  # shellcheck disable=SC1090
  . "$INSTALLER"
  ROLE=muscle
  CHUMP_NODE_DIR="$ATMP/node"
  CHUMP_STATE_DIR="$ATMP/state"
  NODE_DIR="$ATMP/node"; STATE_DIR="$ATMP/state"
  LOG_DIR="$NODE_DIR/logs"; ORGAN_DIR="$NODE_DIR/organs"; BIN="$NODE_DIR/bin/chump"
  export CHUMP_ORGAN_MANIFEST="$GATE_MANIFEST"
  detect_host
  install_organs
) >"$ATMP/install.log" 2>&1
a_rc=$?

[ "$a_rc" -eq 0 ] || fail "install_organs must exit 0 even when every candidate organ is skipped (rc=$a_rc); log: $(cat "$ATMP/install.log")"
[ "$a_rc" -eq 0 ] && pass "install_organs does not fail the script when organs are skipped as non-applicable"

grep -q "worker skipped:.*paging_off\|worker skipped:.*role=brain" "$ATMP/install.log" \
  && pass "role-mismatched worker organ (manifest role=brain, install role=muscle) is skipped" \
  || fail "expected a role-mismatch skip message for worker; log: $(cat "$ATMP/install.log")"

grep -q "process-organ-heal skipped:.*requires unmet" "$ATMP/install.log" \
  && pass "process-organ-heal organ with an unmet requires= precondition is skipped" \
  || fail "expected a requires-unmet skip message for process-organ-heal; log: $(cat "$ATMP/install.log")"

grep -q "fleet-health-sentinel skipped:.*paging_off" "$ATMP/install.log" \
  && pass "paging_off fleet-health-sentinel organ is skipped" \
  || fail "expected a paging_off skip message for fleet-health-sentinel; log: $(cat "$ATMP/install.log")"

grep -q "organ installed+up: worker" "$ATMP/install.log" \
  && fail "worker must NOT be installed+up (role-mismatched in manifest)" \
  || pass "worker was never svc_install/svc_up'd"
grep -q "organ installed+up: process-organ-heal" "$ATMP/install.log" \
  && fail "process-organ-heal must NOT be installed+up (unmet requires=)" \
  || pass "process-organ-heal was never svc_install/svc_up'd"
grep -q "organ installed+up: fleet-health-sentinel" "$ATMP/install.log" \
  && fail "fleet-health-sentinel must NOT be installed+up (paging_off)" \
  || pass "fleet-health-sentinel was never svc_install/svc_up'd"

# ── scenario B: an organ with no manifest line at all keeps installing
#       (back-compat — the manifest is additive, not a required gate) ───────
EMPTY_MANIFEST="$TMP/manifest-empty.txt"
cat > "$EMPTY_MANIFEST" <<'EOF'
# no organs declared here at all
EOF

BTMP="$TMP/install-b"
mkdir -p "$BTMP/node/bin" "$BTMP/node/organs" "$BTMP/node/logs"
(
  set --
  # shellcheck disable=SC1090
  . "$INSTALLER"
  ROLE=brain
  CHUMP_NODE_DIR="$BTMP/node"
  CHUMP_STATE_DIR="$BTMP/state"
  NODE_DIR="$BTMP/node"; STATE_DIR="$BTMP/state"
  LOG_DIR="$NODE_DIR/logs"; ORGAN_DIR="$NODE_DIR/organs"; BIN="$NODE_DIR/bin/chump"
  export CHUMP_ORGAN_MANIFEST="$EMPTY_MANIFEST"
  detect_host
  install_organs
) >"$BTMP/install.log" 2>&1
b_rc=$?

[ "$b_rc" -eq 0 ] || fail "install_organs must exit 0 for a brain install against an empty manifest (rc=$b_rc)"

grep -q "organ installed+up: node-heartbeat" "$BTMP/install.log" \
  && pass "an organ absent from the manifest entirely still installs (back-compat)" \
  || fail "node-heartbeat should still install+up when it has no organ-manifest.txt line; log: $(cat "$BTMP/install.log")"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: INFRA-4351 organs-manifest-gate holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
