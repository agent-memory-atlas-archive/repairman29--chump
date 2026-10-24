#!/usr/bin/env bash
# scripts/ci/test-agent-dispatch-guardrail.sh — RESILIENT-060
#
# 5-case test suite for scripts/coord/agent-dispatch-guardrail.sh
#
# Tests:
#   1. write-paths all in lease → rc=0, agent_dispatch_guardrail_passed emitted
#   2. write-paths include 1 outside lease → rc=1, agent_dispatch_guardrail_blocked
#      emitted, stderr contains the offending path
#   3. no lease file exists → rc=1, stderr says "no active lease for gap-id X"
#   4. branch name mismatch (lease gap=INFRA-1, branch=chump/infra-2-claim) → rc=1
#   5. *.rs path included + worktree has fmt-dirty files → rc=1, stderr mentions
#      "cargo fmt --check failed"
#
# NOTE: chump is binary-only — never use `cargo test --lib`; use --bin chump.

set -eo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


PASS=0
FAIL=0
FAILS=()

ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-090/093: scrub GIT_DIR/GIT_WORK_TREE inherited from pre-push.
# shellcheck source=../lib/scrub-git-env.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

GUARDRAIL="$REPO_ROOT/scripts/coord/agent-dispatch-guardrail.sh"

printf '=== RESILIENT-060 agent-dispatch-guardrail tests ===\n'

# ── Source-contract checks ────────────────────────────────────────────────────
if [[ -x "$GUARDRAIL" ]]; then
    ok "guardrail script exists and is executable"
else
    fail "guardrail script missing or not executable: $GUARDRAIL"
    printf 'FATAL: cannot continue without the script.\n' >&2
    exit 1
fi

bash -n "$GUARDRAIL" 2>/dev/null && ok "guardrail passes bash -n syntax check" \
    || fail "guardrail has bash syntax errors"

for kind in agent_dispatch_guardrail_passed agent_dispatch_guardrail_blocked; do
    if grep -q "\"$kind\"" "$GUARDRAIL" 2>/dev/null; then
        ok "script emits $kind"
    else
        fail "script missing emit for $kind"
    fi
    if grep -q "kind: $kind" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
        ok "EVENT_REGISTRY.yaml registers $kind"
    else
        fail "EVENT_REGISTRY.yaml missing entry for $kind"
    fi
done

if grep -q "RESILIENT-060" "$REPO_ROOT/docs/process/SUBAGENT_DISPATCH.md" \
   && grep -q "agent-dispatch-guardrail.sh" "$REPO_ROOT/docs/process/SUBAGENT_DISPATCH.md"; then
    ok "SUBAGENT_DISPATCH.md references RESILIENT-060 and agent-dispatch-guardrail.sh"
else
    fail "SUBAGENT_DISPATCH.md missing RESILIENT-060 section or guardrail reference"
fi

# ── Synthetic test harness setup ───────────────────────────────────────────────
# Each test gets its own temp dir with a fake .chump-locks/ tree,
# a fake git repo on the right branch, and an optional Cargo.toml + src.
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

# Helper: create a minimal fake git repo at $1 on branch $2
make_repo() {
    local dir="$1" branch="$2"
    mkdir -p "$dir"
    cd "$dir"
    git init --quiet
    git checkout -b "$branch" --quiet 2>/dev/null || git checkout "$branch" --quiet 2>/dev/null || true
    git commit --allow-empty -m "init" --quiet
    # Point git-common-dir back to itself (single repo, not a worktree)
    cd - > /dev/null
}

# Helper: create a lease JSON at $1/.chump-locks/claim-<gap>-test.json
make_lease() {
    local repo_dir="$1" gap_id="$2"; shift 2
    local paths_json="$1"  # JSON array string e.g. '["foo","bar"]'
    mkdir -p "$repo_dir/.chump-locks"
    printf '{"session_id":"test","paths":%s,"gap_id":"%s"}\n' \
        "$paths_json" "$gap_id" \
        > "$repo_dir/.chump-locks/claim-$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')-test.json"
}

# Run the guardrail with test-specific overrides.
# Returns exit code; captures stderr to a temp file for assertion.
LAST_STDERR=""
run_guardrail() {
    local repo_dir="$1" gap_id="$2" paths_csv="$3"
    LAST_STDERR="$(mktemp)"
    CHUMP_LOCK_DIR="$repo_dir/.chump-locks" \
    CHUMP_AMBIENT_LOG="$repo_dir/.chump-locks/ambient.jsonl" \
        bash "$GUARDRAIL" "$gap_id" "$paths_csv" 2>"$LAST_STDERR" || true
    # Return the actual exit code from the subshell
    CHUMP_LOCK_DIR="$repo_dir/.chump-locks" \
    CHUMP_AMBIENT_LOG="$repo_dir/.chump-locks/ambient.jsonl" \
        bash "$GUARDRAIL" "$gap_id" "$paths_csv" 2>/dev/null
}

# ── TEST 1: All write-paths in lease → rc=0, passed event emitted ─────────────
printf '\n-- Test 1: valid paths, correct branch --\n'
T1="$TMP_BASE/t1"
make_repo "$T1" "chump/infra-9001-claim"
make_lease "$T1" "INFRA-9001" '["scripts/coord/foo.sh","scripts/ci/test-foo.sh"]'
AMBIENT1="$T1/.chump-locks/ambient.jsonl"

T1_STDERR="$(mktemp)"
set +e
(
  cd "$T1"
  CHUMP_REPO_ROOT="$T1" \
  CHUMP_LOCK_DIR="$T1/.chump-locks" \
  CHUMP_AMBIENT_LOG="$AMBIENT1" \
      bash "$GUARDRAIL" "INFRA-9001" "scripts/coord/foo.sh,scripts/ci/test-foo.sh" 2>"$T1_STDERR"
)
T1_RC=$?
set -e

if [[ $T1_RC -eq 0 ]]; then
    ok "Test 1: rc=0 (passed)"
else
    fail "Test 1: expected rc=0, got $T1_RC ($(cat "$T1_STDERR"))"
fi

if [[ -f "$AMBIENT1" ]] && grep -q "agent_dispatch_guardrail_passed" "$AMBIENT1"; then
    ok "Test 1: agent_dispatch_guardrail_passed emitted to ambient"
else
    fail "Test 1: agent_dispatch_guardrail_passed not found in ambient log"
fi

# ── TEST 2: One path outside lease → rc=1, offending path in stderr ───────────
printf '\n-- Test 2: one path outside lease --\n'
T2="$TMP_BASE/t2"
make_repo "$T2" "chump/infra-9002-claim"
make_lease "$T2" "INFRA-9002" '["scripts/coord/foo.sh"]'
AMBIENT2="$T2/.chump-locks/ambient.jsonl"

T2_STDERR="$(mktemp)"
set +e
(
  cd "$T2"
  CHUMP_REPO_ROOT="$T2" \
  CHUMP_LOCK_DIR="$T2/.chump-locks" \
  CHUMP_AMBIENT_LOG="$AMBIENT2" \
      bash "$GUARDRAIL" "INFRA-9002" "scripts/coord/foo.sh,src/atomic_claim.rs" 2>"$T2_STDERR"
)
T2_RC=$?
set -e

if [[ $T2_RC -eq 1 ]]; then
    ok "Test 2: rc=1 (blocked)"
else
    fail "Test 2: expected rc=1, got $T2_RC"
fi

if grep -q "src/atomic_claim.rs" "$T2_STDERR"; then
    ok "Test 2: offending path appears in stderr"
else
    fail "Test 2: offending path missing from stderr (got: $(cat "$T2_STDERR" | head -3))"
fi

if [[ -f "$AMBIENT2" ]] && grep -q "agent_dispatch_guardrail_blocked" "$AMBIENT2"; then
    ok "Test 2: agent_dispatch_guardrail_blocked emitted to ambient"
else
    fail "Test 2: agent_dispatch_guardrail_blocked not found in ambient log"
fi

# ── TEST 3: No lease file exists → rc=1, stderr says "no active lease" ────────
printf '\n-- Test 3: no lease file --\n'
T3="$TMP_BASE/t3"
make_repo "$T3" "chump/infra-9003-claim"
mkdir -p "$T3/.chump-locks"   # lock dir exists but no claim-*.json inside
AMBIENT3="$T3/.chump-locks/ambient.jsonl"

T3_STDERR="$(mktemp)"
set +e
(
  cd "$T3"
  CHUMP_REPO_ROOT="$T3" \
  CHUMP_LOCK_DIR="$T3/.chump-locks" \
  CHUMP_AMBIENT_LOG="$AMBIENT3" \
      bash "$GUARDRAIL" "INFRA-9003" "scripts/coord/foo.sh" 2>"$T3_STDERR"
)
T3_RC=$?
set -e

if [[ $T3_RC -eq 1 ]]; then
    ok "Test 3: rc=1 (blocked)"
else
    fail "Test 3: expected rc=1, got $T3_RC"
fi

if grep -qi "no active lease" "$T3_STDERR"; then
    ok "Test 3: stderr mentions 'no active lease'"
else
    fail "Test 3: expected 'no active lease' in stderr (got: $(cat "$T3_STDERR" | head -3))"
fi

# ── TEST 4: Branch name mismatch ───────────────────────────────────────────────
printf '\n-- Test 4: branch mismatch --\n'
T4="$TMP_BASE/t4"
# Branch says infra-2, lease says INFRA-1
make_repo "$T4" "chump/infra-2-claim"
make_lease "$T4" "INFRA-1" '["scripts/coord/foo.sh"]'
AMBIENT4="$T4/.chump-locks/ambient.jsonl"

T4_STDERR="$(mktemp)"
set +e
(
  cd "$T4"
  CHUMP_REPO_ROOT="$T4" \
  CHUMP_LOCK_DIR="$T4/.chump-locks" \
  CHUMP_AMBIENT_LOG="$AMBIENT4" \
      bash "$GUARDRAIL" "INFRA-1" "scripts/coord/foo.sh" 2>"$T4_STDERR"
)
T4_RC=$?
set -e

if [[ $T4_RC -eq 1 ]]; then
    ok "Test 4: rc=1 (blocked on branch mismatch)"
else
    fail "Test 4: expected rc=1 (branch mismatch), got $T4_RC ($(cat "$T4_STDERR"))"
fi

if grep -qi "branch mismatch\|does not match" "$T4_STDERR"; then
    ok "Test 4: stderr mentions branch mismatch"
else
    fail "Test 4: expected 'branch mismatch' in stderr (got: $(cat "$T4_STDERR" | head -3))"
fi

# ── TEST 5: *.rs path + fmt-dirty worktree → rc=1, stderr mentions fmt ────────
printf '\n-- Test 5: *.rs path with fmt-dirty worktree --\n'
T5="$TMP_BASE/t5"
make_repo "$T5" "chump/infra-9005-claim"
make_lease "$T5" "INFRA-9005" '["src/lib.rs"]'
AMBIENT5="$T5/.chump-locks/ambient.jsonl"

# Create a minimal Cargo.toml + fmt-dirty Rust file.
printf '[package]\nname = "guardrail-test"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\nname = "guardrail_test"\npath = "src/lib.rs"\n' \
    > "$T5/Cargo.toml"
mkdir -p "$T5/src"
# Deliberately mis-formatted: missing spaces around `+`
printf 'pub fn add(a:i32,b:i32)->i32{a+b}\n' > "$T5/src/lib.rs"

T5_STDERR="$(mktemp)"
CARGO_BIN="$(command -v cargo 2>/dev/null || printf '')"
if [[ -z "$CARGO_BIN" ]]; then
    for try_c in "$HOME/.cargo/bin/cargo" "/usr/local/bin/cargo"; do
        [[ -x "$try_c" ]] && CARGO_BIN="$try_c" && break
    done
fi

if [[ -z "$CARGO_BIN" ]]; then
    printf '  SKIP: Test 5: cargo not available in this environment\n'
else
    set +e
    (
      cd "$T5"
      CHUMP_REPO_ROOT="$T5" \
      CHUMP_LOCK_DIR="$T5/.chump-locks" \
      CHUMP_AMBIENT_LOG="$AMBIENT5" \
      CHUMP_WORKTREE_ROOT="$T5" \
          bash "$GUARDRAIL" "INFRA-9005" "src/lib.rs" 2>"$T5_STDERR"
    )
    T5_RC=$?
    set -e

    if [[ $T5_RC -eq 1 ]]; then
        ok "Test 5: rc=1 (blocked on fmt-dirty worktree)"
    else
        fail "Test 5: expected rc=1 (fmt dirty), got $T5_RC ($(cat "$T5_STDERR"))"
    fi

    if grep -qi "cargo fmt" "$T5_STDERR"; then
        ok "Test 5: stderr mentions 'cargo fmt'"
    else
        fail "Test 5: expected 'cargo fmt' in stderr (got: $(cat "$T5_STDERR" | head -3))"
    fi
fi

# ── TEST 6 (RESILIENT-213): auto-detect REPO_ROOT from cwd, no override ───────
# The regression this gap exists for: invoke the guardrail via its ABSOLUTE
# path (the normal dispatch pattern) while cwd is a *different* repo (T6,
# standing in for a worktree) and CHUMP_REPO_ROOT is deliberately left
# UNSET. Before the fix, REPO_ROOT always fell back to the script's own
# location ($SCRIPT_DIR/../..) -- i.e. THIS repo, not T6 -- so the branch
# check would validate against this repo's branch instead of T6's
# "chump/infra-9006-claim", producing a false BLOCKED. After the fix,
# `git rev-parse --show-toplevel` run from T6's cwd correctly resolves
# REPO_ROOT to T6 itself.
printf '\n-- Test 6: REPO_ROOT auto-detected from cwd, no CHUMP_REPO_ROOT override --\n'
T6="$TMP_BASE/t6"
make_repo "$T6" "chump/infra-9006-claim"
make_lease "$T6" "INFRA-9006" '["scripts/coord/foo.sh"]'
AMBIENT6="$T6/.chump-locks/ambient.jsonl"

T6_STDERR="$(mktemp)"
set +e
(
  cd "$T6"
  # Deliberately NOT setting CHUMP_REPO_ROOT -- this is the exact scenario
  # RESILIENT-213 found broken. CHUMP_LOCK_DIR/CHUMP_AMBIENT_LOG still set
  # so the test doesn't pollute this repo's own real ambient log.
  CHUMP_LOCK_DIR="$T6/.chump-locks" \
  CHUMP_AMBIENT_LOG="$AMBIENT6" \
      bash "$GUARDRAIL" "INFRA-9006" "scripts/coord/foo.sh" 2>"$T6_STDERR"
)
T6_RC=$?
set -e

if [[ $T6_RC -eq 0 ]]; then
    ok "Test 6: rc=0 -- correctly detected T6's own branch via auto-detected REPO_ROOT"
else
    fail "Test 6: expected rc=0 (auto-detect should resolve REPO_ROOT to T6), got $T6_RC ($(cat "$T6_STDERR"))"
fi

if [[ -f "$AMBIENT6" ]] && grep -q "agent_dispatch_guardrail_passed" "$AMBIENT6"; then
    ok "Test 6: agent_dispatch_guardrail_passed emitted to ambient"
else
    fail "Test 6: agent_dispatch_guardrail_passed not found in ambient log"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    printf 'Failed tests:\n'
    for f in "${FAILS[@]}"; do
        printf '  - %s\n' "$f"
    done
    exit 1
fi

exit 0
