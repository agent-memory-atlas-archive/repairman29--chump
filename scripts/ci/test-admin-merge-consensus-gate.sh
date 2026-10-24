#!/usr/bin/env bash
# test-admin-merge-consensus-gate.sh — CREDIBLE-1524 (PHASE-R R3 slice of
# CREDIBLE-1492), AC1 + AC4.
#
#   AC1  — every `gh pr merge --admin` call site under scripts/ refuses without
#          a PASSED AdminMergeProposal consensus_result for the PR. Proven two
#          ways: (Part B) a stubbed-gh fixture per call-site invocation shape,
#          driving the EXACT guard idiom each site uses, and (Part C) the shared
#          gate function's decision table.
#   AC4  — a grep gate that FAILS on a new `gh pr merge --admin` call site under
#          scripts/**/*.sh that is not guarded by admin_merge_consensus_gate
#          (Part A).
#
# Pairs with:
#   scripts/coord/lib/admin-merge-consensus-gate.sh  (the gate)
#   scripts/coord/pr-shepherd-daemon.sh:*            call sites
#   scripts/coord/recovery-queue-service.sh:*
#   scripts/ops/admin-merge-cycle.sh:*
#   scripts/ops/break-trunk-cascade.sh:*

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GATE_LIB="$REPO_ROOT/scripts/coord/lib/admin-merge-consensus-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

# The real --admin call-site files (NOT comments / echo strings / CI fixtures).
CALL_SITES=(
  "scripts/coord/pr-shepherd-daemon.sh"
  "scripts/coord/recovery-queue-service.sh"
  "scripts/ops/admin-merge-cycle.sh"
  "scripts/ops/break-trunk-cascade.sh"
)

# ── Part A: AC4 grep gate ─────────────────────────────────────────────────────
# Enumerate every real admin-merge command line under scripts/**/*.sh (excluding
# CI fixtures, comments, and echo/printf string literals), then require an
# admin_merge_consensus_gate guard within the preceding window in the same file.
# A NEW unguarded `gh pr merge --admin` call site makes this fail.
echo "── Part A: grep gate (AC4) ──"

GUARD_WINDOW=80   # lines of lookback for the guard call

# Lines that are genuine command invocations of an admin merge.
mapfile -t MERGE_LINES < <(
  grep -rn "pr merge" "$REPO_ROOT/scripts" --include="*.sh" 2>/dev/null \
    | grep -- "--admin" \
    | grep -v "/scripts/ci/" \
    | grep -vE ':[[:space:]]*#' \
    | grep -viE '(echo|printf)[[:space:]]' \
    || true
)

if [[ ${#MERGE_LINES[@]} -eq 0 ]]; then
  bad "Part A: found ZERO admin-merge call sites — the enumeration filter is broken"
else
  echo "   found ${#MERGE_LINES[@]} admin-merge call-site line(s)"
fi

for entry in "${MERGE_LINES[@]}"; do
  # entry shape: <abs-path>:<lineno>:<code>
  file="${entry%%:*}"
  rest="${entry#*:}"
  lineno="${rest%%:*}"
  relfile="${file#"$REPO_ROOT"/}"

  # Is this file one of the known, guarded call sites?
  known=0
  for cs in "${CALL_SITES[@]}"; do
    [[ "$relfile" == "$cs" ]] && known=1 && break
  done
  if [[ $known -eq 0 ]]; then
    bad "AC4: NEW unguarded admin-merge call site $relfile:$lineno — add admin_merge_consensus_gate before it (and register the site in this test's CALL_SITES)"
    continue
  fi

  # Require the gate within GUARD_WINDOW lines above the merge line.
  start=$(( lineno - GUARD_WINDOW )); (( start < 1 )) && start=1
  window="$(sed -n "${start},${lineno}p" "$file")"
  if printf '%s\n' "$window" | grep -q "admin_merge_consensus_gate"; then
    ok "AC4: $relfile:$lineno guarded by admin_merge_consensus_gate"
  else
    bad "AC4: $relfile:$lineno has NO admin_merge_consensus_gate guard within $GUARD_WINDOW lines above"
  fi
done

# Every call site must source the shared gate lib.
for cs in "${CALL_SITES[@]}"; do
  if grep -q "admin-merge-consensus-gate.sh" "$REPO_ROOT/$cs"; then
    ok "AC4: $cs sources the gate lib"
  else
    bad "AC4: $cs does NOT source scripts/coord/lib/admin-merge-consensus-gate.sh"
  fi
done

# ── Part C: AC1 shared-gate decision table ────────────────────────────────────
echo "── Part C: gate decision table (AC1) ──"
if [[ ! -f "$GATE_LIB" ]]; then
  bad "gate lib missing at $GATE_LIB"
else
  # Each sub-shell isolates env + ambient.
  run_gate() { # <mode> <pr> <ambient> → prints RC
    (
      set +e
      export CHUMP_CONSENSUS_MERGE_GATE="$1"
      export CHUMP_AMBIENT_LOG="$3"
      export REPO_ROOT="$TMP"
      # shellcheck source=/dev/null
      source "$GATE_LIB"
      admin_merge_consensus_gate "$2" >/dev/null 2>&1
      echo $?
    )
  }

  AMB="$TMP/decision.jsonl"; : > "$AMB"

  # disabled → proceed (rc 0), no event
  [[ "$(run_gate 0 900 "$AMB")" == "0" ]] && ok "disabled → proceed" || bad "disabled should proceed"

  # enforce + no PASSED → refuse (rc 1)
  [[ "$(run_gate enforce 901 "$AMB")" == "1" ]] && ok "enforce + no consensus → REFUSE" || bad "enforce + no consensus should refuse"

  # shadow + no PASSED → proceed (rc 0)
  [[ "$(run_gate shadow 902 "$AMB")" == "0" ]] && ok "shadow + no consensus → proceed" || bad "shadow + no consensus should proceed"

  # enforce + PASSED present → proceed (rc 0)
  echo '{"ts":"t","kind":"consensus_result","corr_id":"admin-merge-pr-903","verdict":"PASSED"}' >> "$AMB"
  [[ "$(run_gate enforce 903 "$AMB")" == "0" ]] && ok "enforce + PASSED AdminMergeProposal → proceed" || bad "enforce + PASSED should proceed"

  # enforce + a FAILED (not PASSED) verdict → refuse
  echo '{"ts":"t","kind":"consensus_result","corr_id":"admin-merge-pr-904","verdict":"FAILED"}' >> "$AMB"
  [[ "$(run_gate enforce 904 "$AMB")" == "1" ]] && ok "enforce + FAILED verdict → REFUSE" || bad "enforce + FAILED should refuse"

  # Emitted kinds present.
  for k in admin_merge_consensus_refused admin_merge_consensus_shadow admin_merge_consensus_approved; do
    if grep -q "\"kind\":\"$k\"" "$AMB"; then ok "emitted $k"; else bad "missing emit $k"; fi
  done
fi

# ── Part B: AC1 stubbed-gh fixture, per call-site invocation shape ─────────────
# Each call site invokes a different merge command (chump_gh / "$GH_BIN" / gh).
# For each, stand up a RECORDER stub for that command, source the real gate lib,
# run the EXACT guard idiom the site uses, and assert: in enforce mode with no
# consensus the merge command is NEVER invoked (recorder empty = refused); with a
# PASSED AdminMergeProposal it IS invoked.
echo "── Part B: stubbed-gh refusal per call-site shape (AC1) ──"

# site_shape <label> <pr> <merge-invocation-template>
# The template uses $MERGE as the recorder command and $PR as the PR number.
run_site_fixture() {
  local label="$1" pr="$2" invoke="$3"
  local amb="$TMP/site_${label}.jsonl"; : > "$amb"
  local rec="$TMP/site_${label}.rec"; : > "$rec"

  # Recorder stub for the merge command.
  local merge_stub="$TMP/merge_${label}.sh"
  cat > "$merge_stub" <<REC
#!/usr/bin/env bash
printf '%s\n' "MERGE_INVOKED $*" >> "$rec"
exit 0
REC
  chmod +x "$merge_stub"

  # enforce + no consensus → must REFUSE (recorder stays empty).
  (
    set +e
    export CHUMP_CONSENSUS_MERGE_GATE=enforce
    export CHUMP_AMBIENT_LOG="$amb"
    export REPO_ROOT="$TMP"
    MERGE="$merge_stub"; PR="$pr"
    # shellcheck source=/dev/null
    source "$GATE_LIB"
    # EXACT guard idiom: gate first, then the site's merge invocation.
    if admin_merge_consensus_gate "$PR" >/dev/null 2>&1; then
      eval "$invoke"
    fi
  )
  if [[ -s "$rec" ]]; then
    bad "Part B [$label]: enforce+no-consensus INVOKED the merge (should refuse) — $(cat "$rec")"
  else
    ok "Part B [$label]: enforce+no-consensus refused (merge not invoked)"
  fi

  # enforce + PASSED → must INVOKE the merge.
  echo "{\"ts\":\"t\",\"kind\":\"consensus_result\",\"corr_id\":\"admin-merge-pr-${pr}\",\"verdict\":\"PASSED\"}" >> "$amb"
  : > "$rec"
  (
    set +e
    export CHUMP_CONSENSUS_MERGE_GATE=enforce
    export CHUMP_AMBIENT_LOG="$amb"
    export REPO_ROOT="$TMP"
    MERGE="$merge_stub"; PR="$pr"
    # shellcheck source=/dev/null
    source "$GATE_LIB"
    if admin_merge_consensus_gate "$PR" >/dev/null 2>&1; then
      eval "$invoke"
    fi
  )
  if grep -q "MERGE_INVOKED" "$rec"; then
    ok "Part B [$label]: enforce+PASSED invoked the merge"
  else
    bad "Part B [$label]: enforce+PASSED did NOT invoke the merge (should proceed)"
  fi
}

# Mirror each real site's invocation shape (the command token differs per site).
run_site_fixture "pr-shepherd"   1001 '"$MERGE" pr merge "$PR" --squash --admin --delete-branch'
run_site_fixture "recovery"      1002 '"$MERGE" pr merge "$PR" --squash --admin'
run_site_fixture "admin-cycle"   1003 '"$MERGE" pr merge "$PR" --squash --admin'
run_site_fixture "break-trunk"   1004 '"$MERGE" pr merge "$PR" --admin --squash'

# ── Part D: CREDIBLE-1547 installer enforce flip + shadow→enforce upgrade ─────
echo "── Part D: CREDIBLE-1547 installer enforce default + shadow upgrade ──"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

if grep -q "CHUMP_CONSENSUS_MERGE_GATE=enforce" "$INSTALLER" && ! grep -q "printf 'CHUMP_CONSENSUS_MERGE_GATE=shadow" "$INSTALLER"; then
  ok "Part D: chump-node-install.sh writes CHUMP_CONSENSUS_MERGE_GATE=enforce by default"
else
  bad "Part D: chump-node-install.sh does not write CHUMP_CONSENSUS_MERGE_GATE=enforce by default"
fi

# Extract and run the installer consensus-gate carry/upgrade logic against
# (1) fresh node.env, (2) existing shadow node.env, (3) existing export 1 node.env, (4) explicit 0 node.env.
run_installer_gate_slice() {
  local pre_line="$1"
  local env_file="$TMP/node_env_test"
  rm -f "$env_file"
  if [[ -n "$pre_line" ]]; then
    printf '%s\n' "$pre_line" > "$env_file"
  fi
  (
    node_env="$env_file"
    eval "$(awk '/_consensus_gate_line=""/{flag=1} /# INFRA-8588: node\.env is written ONLY/{flag=0} flag{print}' "$INSTALLER" | sed 's/^[[:space:]]*local / /')"
    if [ -n "${_consensus_gate_line:-}" ]; then
      printf '%s\n' "$_consensus_gate_line"
    else
      eval "$(grep "printf 'CHUMP_CONSENSUS_MERGE_GATE=" "$INSTALLER" | head -1)"
    fi
  )
}

[[ "$(run_installer_gate_slice "")" == "CHUMP_CONSENSUS_MERGE_GATE=enforce" ]] \
  && ok "Part D: fresh node.env → CHUMP_CONSENSUS_MERGE_GATE=enforce" \
  || bad "Part D: fresh node.env did not produce CHUMP_CONSENSUS_MERGE_GATE=enforce"

[[ "$(run_installer_gate_slice "CHUMP_CONSENSUS_MERGE_GATE=shadow")" == "CHUMP_CONSENSUS_MERGE_GATE=enforce" ]] \
  && ok "Part D: existing shadow node.env → upgraded to CHUMP_CONSENSUS_MERGE_GATE=enforce" \
  || bad "Part D: existing shadow node.env was NOT upgraded to enforce"

[[ "$(run_installer_gate_slice "export CHUMP_CONSENSUS_MERGE_GATE=1")" == "CHUMP_CONSENSUS_MERGE_GATE=enforce" ]] \
  && ok "Part D: existing export=1 node.env → upgraded to CHUMP_CONSENSUS_MERGE_GATE=enforce" \
  || bad "Part D: existing export=1 node.env was NOT upgraded to enforce"

[[ "$(run_installer_gate_slice "CHUMP_CONSENSUS_MERGE_GATE=0")" == "CHUMP_CONSENSUS_MERGE_GATE=0" ]] \
  && ok "Part D: explicit CHUMP_CONSENSUS_MERGE_GATE=0 preserved" \
  || bad "Part D: explicit CHUMP_CONSENSUS_MERGE_GATE=0 was not preserved"

if grep -q 'CHUMP_CONSENSUS_MERGE_GATE=${CHUMP_CONSENSUS_MERGE_GATE:-enforce}' "$RUN_FLEET"; then
  ok "Part D: run-fleet.sh defaults CHUMP_CONSENSUS_MERGE_GATE to enforce"
else
  bad "Part D: run-fleet.sh does not default CHUMP_CONSENSUS_MERGE_GATE to enforce"
fi

_bm_log_line="$(CHUMP_CONSENSUS_MERGE_GATE=enforce bash -c 'info() { echo "$*"; }; eval "$(grep "info .*bot-merge: consensus merge gate" "'"$BOT_MERGE"'")"')"
if [[ "$_bm_log_line" == *"mode=enforce"* && "$_bm_log_line" == *"gate=enforce"* ]]; then
  ok "Part D: bot-merge.sh logs mode=enforce gate=enforce"
else
  bad "Part D: bot-merge.sh log line missing gate=enforce (got: $_bm_log_line)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────"
echo "test-admin-merge-consensus-gate: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "[test-admin-merge-consensus-gate] ALL GREEN"
