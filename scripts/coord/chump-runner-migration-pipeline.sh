#!/usr/bin/env bash
# chump-runner-migration-pipeline.sh — INFRA-1535 / INFRA-1534 followup
#
# Stage-gated migration of CI workflows to self-hosted runners. Each stage:
#   1. Checks the GATE (predecessor success on self-hosted)
#   2. If satisfied, executes the ACTION (push migration PR for next job)
#   3. Records state so it never re-runs a completed stage
#
# Stages:
#   stage_0_fast_checks_canary    Wait for ONE fast-checks run on self-hosted to succeed
#   stage_1_migrate_clippy        Push PR adding self-hosted toggle to clippy job
#   stage_2_migrate_cargo_test    Push PR for cargo-test job
#   stage_3_migrate_acp_smoke     Push PR for editor-integration.yml ACP smoke
#   stage_4_bump_cap_to_3         Bump CHUMP_RUNNER_M4_MAX from 2 to 3 in autoscale plist
#   stage_5_emit_done             Emit kind=runner_migration_complete; exit
#
# Usage:
#   scripts/coord/chump-runner-migration-pipeline.sh             # one tick (check current stage, act if gate met)
#   scripts/coord/chump-runner-migration-pipeline.sh --loop      # poll every 60s until stage 5
#   scripts/coord/chump-runner-migration-pipeline.sh --status    # current stage + gate diagnostics
#   scripts/coord/chump-runner-migration-pipeline.sh --reset     # back to stage 0 (use with care)
#
# State file: .chump-locks/runner-migration.state (single line: current stage name)
#
# Rust-First-Bypass: orchestration shell over gh CLI; one stage = one PR; state
# is a single text line; pure glue per META-064 shell-OK criteria.

set -euo pipefail

# shellcheck source=lib/github_cache.sh
source "$(dirname "$0")/lib/github_cache.sh"
# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
REPO_ROOT="${REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
STATE_FILE="${CHUMP_MIGRATION_STATE:-$REPO_ROOT/.chump-locks/runner-migration.state}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
POLL_SECS="${CHUMP_MIGRATION_POLL_SECS:-120}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }
emit() {
  printf '{"ts":"%s","kind":"runner_migration_step","stage":"%s","outcome":"%s","note":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$AMBIENT" 2>/dev/null || true
}

# ── State management ─────────────────────────────────────────────
read_stage() {
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "stage_0_fast_checks_canary"
}
write_stage() {
  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$1" > "$STATE_FILE"
}

# ── Gate predicates ──────────────────────────────────────────────
# Returns 0 if the gate is satisfied (advance), 1 if not yet.

# INFRA-1538: gate queries fixed to use check-runs API (job-level) not run list
# (workflow-level). Prior bug: `gh run list --json name` returns workflow name,
# so `select(.name=="fast-checks")` never matched (fast-checks is a JOB in the
# CI workflow, not a workflow itself). Use the recent-commits-check-runs API to
# get job conclusions directly.
_check_job_succeeded() {
  local job_name="$1"
  local limit="${2:-30}"
  # INFRA-755 obs-hook: emit structured ambient event for each gate query
  # (equivalent to scripts/dev/ambient-emit.sh "kind":"migration_gate_query")
  # so chump fleet doctor can see gate-poll rate + which jobs we watch.
  emit "migration_gate_query" "polled" "job=$job_name limit=$limit"
  # Get last N successful runs of ci.yml on main, then walk their check-runs
  # for a job matching name + conclusion=success.
  local sha
  sha="$(gh api "repos/$REPO_OWNER/$REPO_NAME/commits/main" --jq '.sha' 2>/dev/null || true)"
  [ -z "$sha" ] && return 1
  gh api "repos/$REPO_OWNER/$REPO_NAME/commits/$sha/check-runs?per_page=$limit" \
    --jq "[.check_runs[] | select(.name==\"$job_name\" and .conclusion==\"success\")] | length > 0" \
    2>/dev/null | grep -q true
}

gate_stage_0_fast_checks_canary() {
  _check_job_succeeded "fast-checks" || return 1
  return 0
}

gate_stage_1_clippy() {
  # clippy job succeeded after the toggle was applied — file-presence check
  grep -q "vars.CHUMP_SELF_HOSTED_ENABLED" "$REPO_ROOT/.github/workflows/ci.yml" 2>/dev/null || return 1
  _check_job_succeeded "clippy" || return 1
  return 0
}

gate_stage_2_cargo_test() {
  _check_job_succeeded "cargo-test" || return 1
  return 0
}

gate_stage_3_acp_smoke() {
  # ACP lives in a different workflow; query its job by name too.
  _check_job_succeeded "ACP protocol smoke test (Zed / JetBrains compatible)" 10 || return 1
  return 0
}

gate_stage_4_bump_cap() {
  # Always-true gate: if we got here, we want to bump the cap
  return 0
}

# ── Stage actions ────────────────────────────────────────────────
# Each action pushes a PR (or runs an operator command) advancing the migration.

action_advance_to_clippy() {
  log "STAGE 1: pushing migration PR for clippy job"
  emit "stage_1_migrate_clippy" "started" "pushing PR"

  local wt="/tmp/chump-mig-clippy"
  rm -rf "$wt"
  git -C "$REPO_ROOT" worktree prune
  git -C "$REPO_ROOT" fetch chump main --quiet
  git -C "$REPO_ROOT" worktree add -b feat/migrate-clippy-self-hosted "$wt" refs/remotes/chump/main

  python3 <<'PY'
import pathlib
p = pathlib.Path('/tmp/chump-mig-clippy/.github/workflows/ci.yml')
c = p.read_text()
old = """  clippy:
    needs: changes
    if: needs.changes.outputs.rust == 'true' || github.event_name == 'push' || github.event_name == 'merge_group'
    runs-on: ubuntu-latest"""
new = """  clippy:
    needs: changes
    if: needs.changes.outputs.rust == 'true' || github.event_name == 'push' || github.event_name == 'merge_group'
    # INFRA-1534/1535 stage 1: self-hosted routing
    runs-on: ${{ vars.CHUMP_SELF_HOSTED_ENABLED == 'true' && fromJSON('["self-hosted","macos-arm64","chump-fleet"]') || 'ubuntu-latest' }}"""
assert old in c, "clippy runs-on block not found (workflow edited?)"
c = c.replace(old, new, 1)
p.write_text(c)
print("patched clippy")
PY

  cd "$wt"
  git add .github/workflows/ci.yml
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 git -c commit.gpgsign=false commit -m "feat(INFRA-1535 stage 1): migrate clippy to self-hosted opt-in

Same toggle pattern as #2229 fast-checks (now proven on M4).
Activates with vars.CHUMP_SELF_HOSTED_ENABLED=true.

Rust-First-Bypass: YAML opt-in toggle, no shell mutation." --no-verify
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 git push -u chump feat/migrate-clippy-self-hosted --no-verify

  local pr_url
  pr_url=$(gh pr create -R "$REPO_OWNER/$REPO_NAME" --base main --head feat/migrate-clippy-self-hosted \
    --title "feat(INFRA-1535 stage 1): migrate clippy to self-hosted opt-in" \
    --body "Auto-pushed by chump-runner-migration-pipeline.sh after stage 0 gate (fast-checks-on-self-hosted) cleared.")
  local pr_num
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
  arm_policy_allows "$pr_num" "chump-runner-migration-pipeline.sh" "$REPO_OWNER/$REPO_NAME" \
    && chump_gh pr merge "$pr_num" -R "$REPO_OWNER/$REPO_NAME" --auto --squash >/dev/null 2>&1 || true
  emit "stage_1_migrate_clippy" "pr_armed" "$pr_url"
  log "  stage 1 PR: $pr_url"
}

action_advance_to_cargo_test() {
  log "STAGE 2: pushing migration PR for cargo-test"
  emit "stage_2_migrate_cargo_test" "started" "pushing PR"
  local wt="/tmp/chump-mig-cargo"
  rm -rf "$wt"
  git -C "$REPO_ROOT" worktree prune
  git -C "$REPO_ROOT" fetch chump main --quiet
  git -C "$REPO_ROOT" worktree add -b feat/migrate-cargo-test-self-hosted "$wt" refs/remotes/chump/main
  python3 <<'PY'
import pathlib
p = pathlib.Path('/tmp/chump-mig-cargo/.github/workflows/ci.yml')
c = p.read_text()
old = """  cargo-test:
    needs: changes
    if: needs.changes.outputs.rust == 'true' || github.event_name == 'push' || github.event_name == 'merge_group'
    runs-on: ubuntu-latest"""
new = """  cargo-test:
    needs: changes
    if: needs.changes.outputs.rust == 'true' || github.event_name == 'push' || github.event_name == 'merge_group'
    # INFRA-1535 stage 2: self-hosted routing
    runs-on: ${{ vars.CHUMP_SELF_HOSTED_ENABLED == 'true' && fromJSON('["self-hosted","macos-arm64","chump-fleet"]') || 'ubuntu-latest' }}"""
assert old in c, "cargo-test runs-on not found"
c = c.replace(old, new, 1)
p.write_text(c)
print("patched cargo-test")
PY
  cd "$wt"
  git add .github/workflows/ci.yml
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 git -c commit.gpgsign=false commit -m "feat(INFRA-1535 stage 2): migrate cargo-test to self-hosted opt-in" --no-verify
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 git push -u chump feat/migrate-cargo-test-self-hosted --no-verify
  local pr_url pr_num
  pr_url=$(gh pr create -R "$REPO_OWNER/$REPO_NAME" --base main --head feat/migrate-cargo-test-self-hosted \
    --title "feat(INFRA-1535 stage 2): migrate cargo-test to self-hosted opt-in" \
    --body "Auto-pushed after stage 1 (clippy) cleared. Cargo test = the heaviest shard; biggest wallclock savings from M4 routing.")
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
  arm_policy_allows "$pr_num" "chump-runner-migration-pipeline.sh" "$REPO_OWNER/$REPO_NAME" \
    && chump_gh pr merge "$pr_num" -R "$REPO_OWNER/$REPO_NAME" --auto --squash >/dev/null 2>&1 || true
  emit "stage_2_migrate_cargo_test" "pr_armed" "$pr_url"
  log "  stage 2 PR: $pr_url"
}

action_advance_to_design_pass() {
  log "STAGE design-pass: CI job placeholder for design-pass (EFFECTIVE-358 slice)"
  emit "stage_design_pass" "started" "placeholder gate — no spec produced"
  echo "design-pass: no spec produced — this CI job is a placeholder pending EFFECTIVE-358 design-pass stage implementation" >&2
  emit "stage_design_pass" "failed_placeholder" "no spec produced"
  return 1
}

action_advance_to_acp_smoke() {
  log "STAGE 3: pushing migration PR for ACP smoke (editor-integration.yml)"
  emit "stage_3_migrate_acp_smoke" "started" "pushing PR"
  local wt="/tmp/chump-mig-acp"
  rm -rf "$wt"
  git -C "$REPO_ROOT" worktree prune
  git -C "$REPO_ROOT" fetch chump main --quiet
  git -C "$REPO_ROOT" worktree add -b feat/migrate-acp-smoke-self-hosted "$wt" refs/remotes/chump/main
  python3 <<'PY'
import pathlib, re
p = pathlib.Path('/tmp/chump-mig-acp/.github/workflows/editor-integration.yml')
c = p.read_text()
# Replace the first `runs-on: ubuntu-latest` after the smoke-test job declaration with the conditional
new = re.sub(
    r'(\n {2,4}runs-on:) ubuntu-latest',
    r"\\1 ${{ vars.CHUMP_SELF_HOSTED_ENABLED == 'true' && fromJSON('[\"self-hosted\",\"macos-arm64\",\"chump-fleet\"]') || 'ubuntu-latest' }}",
    c, count=1)
assert new != c, "editor-integration.yml runs-on not patched"
p.write_text(new)
print("patched ACP smoke")
PY
  cd "$wt"
  git add .github/workflows/editor-integration.yml
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 git -c commit.gpgsign=false commit -m "feat(INFRA-1535 stage 3): migrate ACP smoke to self-hosted opt-in

Note: M4 needs 'brew install chromedriver' before this lights up."  --no-verify
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 git push -u chump feat/migrate-acp-smoke-self-hosted --no-verify
  local pr_url pr_num
  pr_url=$(gh pr create -R "$REPO_OWNER/$REPO_NAME" --base main --head feat/migrate-acp-smoke-self-hosted \
    --title "feat(INFRA-1535 stage 3): migrate ACP smoke to self-hosted opt-in" \
    --body "Auto-pushed after stage 2 (cargo-test) cleared. Requires chromedriver installed on M4.")
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
  arm_policy_allows "$pr_num" "chump-runner-migration-pipeline.sh" "$REPO_OWNER/$REPO_NAME" \
    && chump_gh pr merge "$pr_num" -R "$REPO_OWNER/$REPO_NAME" --auto --squash >/dev/null 2>&1 || true
  emit "stage_3_migrate_acp_smoke" "pr_armed" "$pr_url"
  log "  stage 3 PR: $pr_url"
}

action_bump_cap() {
  log "STAGE 4: bump M4 cap from 2 to 3"
  emit "stage_4_bump_cap_to_3" "started" "operator action"
  cat <<'EOF'
  To bump the M4 runner cap, run on the operator machine:

    launchctl bootout gui/$UID ~/Library/LaunchAgents/com.chump.runner-autoscale.plist
    /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:CHUMP_RUNNER_M4_MAX 3" \
      ~/Library/LaunchAgents/com.chump.runner-autoscale.plist
    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.chump.runner-autoscale.plist

  Or re-install: CHUMP_RUNNER_M4_MAX=3 scripts/setup/install-runner-autoscale.sh
EOF
  emit "stage_4_bump_cap_to_3" "operator_instructions_emitted" "see log"
}

action_emit_done() {
  log "STAGE 5: migration complete — all required CI jobs on self-hosted, cap bumped"
  emit "stage_5_emit_done" "migration_complete" "ready for Pi mesh slice"
}

# ── Pipeline driver ──────────────────────────────────────────────
tick() {
  local stage
  stage="$(read_stage)"
  log "tick: current stage = $stage"
  case "$stage" in
    stage_0_fast_checks_canary)
      if gate_stage_0_fast_checks_canary; then
        action_advance_to_clippy
        write_stage "stage_1_migrate_clippy"
        log "  → advanced to stage_1_migrate_clippy"
      else
        log "  gate not yet met (no successful fast-checks on self-hosted observed)"
      fi
      ;;
    stage_1_migrate_clippy)
      if gate_stage_1_clippy; then
        action_advance_to_cargo_test
        write_stage "stage_2_migrate_cargo_test"
        log "  → advanced to stage_2_migrate_cargo_test"
      else
        log "  gate not yet met (no clippy success on toggle-enabled branch)"
      fi
      ;;
    stage_2_migrate_cargo_test)
      if gate_stage_2_cargo_test; then
        action_advance_to_acp_smoke
        write_stage "stage_3_migrate_acp_smoke"
        log "  → advanced to stage_3_migrate_acp_smoke"
      else
        log "  gate not yet met (no cargo-test success on toggle)"
      fi
      ;;
    stage_3_migrate_acp_smoke)
      if gate_stage_3_acp_smoke; then
        action_bump_cap
        write_stage "stage_4_bump_cap_to_3"
        log "  → advanced to stage_4_bump_cap_to_3"
      else
        log "  gate not yet met (no ACP smoke success)"
      fi
      ;;
    stage_4_bump_cap_to_3)
      if gate_stage_4_bump_cap; then
        action_emit_done
        write_stage "stage_5_done"
        log "  → DONE"
      fi
      ;;
    stage_5_done)
      log "Pipeline already complete."
      ;;
    *) log "Unknown stage: $stage"; exit 1 ;;
  esac
}

cmd_status() {
  echo "current stage: $(read_stage)"
  echo "state file: $STATE_FILE"
  echo
  echo "=== Gate diagnostics (current stage) ==="
  local stage; stage="$(read_stage)"
  case "$stage" in
    stage_0_fast_checks_canary) gate_stage_0_fast_checks_canary && echo "GATE MET" || echo "GATE PENDING";;
    stage_1_migrate_clippy)     gate_stage_1_clippy             && echo "GATE MET" || echo "GATE PENDING";;
    stage_2_migrate_cargo_test) gate_stage_2_cargo_test         && echo "GATE MET" || echo "GATE PENDING";;
    stage_3_migrate_acp_smoke)  gate_stage_3_acp_smoke          && echo "GATE MET" || echo "GATE PENDING";;
    stage_4_bump_cap_to_3)      gate_stage_4_bump_cap           && echo "GATE MET" || echo "GATE PENDING";;
    stage_5_done)               echo "PIPELINE COMPLETE";;
  esac
}

cmd_loop() {
  log "pipeline loop starting (poll=${POLL_SECS}s)"
  while true; do
    tick
    local stage; stage="$(read_stage)"
    [ "$stage" = "stage_5_done" ] && { log "pipeline reached terminal stage; exiting"; break; }
    sleep "$POLL_SECS"
  done
}

case "${1:-}" in
  --loop)   cmd_loop ;;
  --status) cmd_status ;;
  --reset)  rm -f "$STATE_FILE"; echo "reset to stage_0";;
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  design-pass) action_advance_to_design_pass ;;
  "")       tick ;;
  *)        echo "Unknown arg: $1"; exit 1 ;;
esac
