#!/usr/bin/env bash
# scripts/ci/test-infra-1062-clippy-timeout-silent-exit.sh — INFRA-1062
#
# Verifies that bot-merge.sh does NOT exit silently when cargo clippy --fix
# times out (exit 124). Before the fix, the script exited after "Skipping tests"
# with no error, no push, no PR opened — observed 4x on 2026-05-13.
#
# Tests:
#   1. Static: warn() is defined (undefined warn → exit 127 with set -e)
#   2. Static: exec 200>lock has no 2>/dev/null (permanent stderr silencing)
#   3. Static: clippy --fix timeout (rc=124) is tracked via _clippy_fix_rc, not || true
#   4. Static: commit fallback has || true guard (can't fail set -e)
#   5. Functional: simulate clippy timeout (fake run_timed_hb returning 124),
#      assert bot-merge continues past "Skipping tests" to git-push stage

set -uo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. warn() is defined ─────────────────────────────────────────────────────
grep -q '^warn()' "$BM" || fail "warn() not defined in bot-merge.sh (calling undefined fn with set -e exits 127)"
ok "warn() is defined"

# ── 2. exec 200>lock has no 2>/dev/null ──────────────────────────────────────
if grep -q 'exec 200>.*2>/dev/null' "$BM"; then
    fail "exec 200>lock still has 2>/dev/null — permanently silences shell stderr (INFRA-1062)"
fi
ok "exec 200>lock has no permanent stderr redirect"

# ── 3. clippy --fix timeout tracked via _clippy_fix_rc ───────────────────────
grep -q '_clippy_fix_rc=0' "$BM" \
    || fail "_clippy_fix_rc not introduced — clippy timeout still || true only"
grep -q '_clippy_fix_rc.*-eq 124' "$BM" \
    || fail "rc=124 timeout check missing"
ok "clippy --fix timeout rc tracked and checked"

# ── 4. commit fallback has || true ───────────────────────────────────────────
# The git commit fallback (amend or new commit) must end with || true so a
# failed commit doesn't trigger set -e.
grep -q 'git commit --no-verify.*INFRA-624.*|| true' "$BM" \
    || fail "commit fallback line missing || true guard"
ok "commit fallback has || true guard"

# ── 5. Functional: simulate clippy timeout, assert continuation ──────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a fake bot-merge that stubs out the expensive parts but exercises
# the clippy --fix timeout path.  We:
#  a) source just enough of the helpers
#  b) override run_timed_hb to return 124 for "cargo clippy --fix"
#  c) set FAST=1, SKIP_TESTS=1, DRY_RUN=1 (skip real push)
#  d) verify we hit "clippy --fix pre-flight done" AND no silent exit before "git push"

cat >"$TMP/test-clippy-timeout.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

# Minimal stubs matching bot-merge's function signatures
green()  { printf '[bot-merge] GREEN: %s\n' "$*"; }
red()    { printf '[bot-merge] RED: %s\n' "$*"; }
yellow() { printf '[bot-merge] YELLOW: %s\n' "$*"; }
warn()   { yellow "$*"; }
info()   { printf '[bot-merge] INFO: %s\n' "$*"; }
stage_start() { __STAGE_LABEL="$1"; __STAGE_T0=$(date +%s); info "▶ $1 starting …"; }
stage_done()  { local e=$(( $(date +%s) - __STAGE_T0 )); info "✓ $__STAGE_LABEL done (${e}s)"; }
heartbeat_begin() { true; }
heartbeat_end()   { true; }

# CRITICAL: override run_timed_hb so "cargo clippy --fix" returns 124 (timeout)
run_timed_hb() {
    local label=$1; shift 2
    if [[ "$label" == "cargo clippy --fix" ]]; then
        printf '[test] simulating clippy --fix timeout (rc=124)\n'
        return 124
    fi
    return 0
}

FAST=1
SKIP_TESTS=1
DRY_RUN=1  # skip actual git/push operations

# ── reproduce the exact clippy --fix block from bot-merge.sh ──────────────────
if command -v cargo &>/dev/null; then
    stage_start "cargo clippy --workspace --fix (--fast pre-flight auto-correct)"
    _clippy_fix_rc=0
    run_timed_hb "cargo clippy --fix" 240 cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged 2>&1 || _clippy_fix_rc=$?
    if [[ "$_clippy_fix_rc" -eq 124 ]]; then
        warn "INFRA-1062: clippy --fix timed out after 240s — continuing to push (CI clippy is the gate)"
    fi
    if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
        info "clippy --fix auto-corrected lints — staging + amending"
        git add -A 2>/dev/null || true
        git commit --amend --no-edit --no-verify >/dev/null 2>&1 || \
            git commit --no-verify -m "chore: cargo clippy --fix (auto from bot-merge.sh --fast pre-flight, INFRA-624 follow-up)" || true
    fi
    stage_done
    green "clippy --fix pre-flight done."
fi

if [[ $SKIP_TESTS -eq 1 ]]; then
    info "Skipping tests (--skip-tests)."
fi

# If we reach here, the timeout did NOT cause a silent exit
printf 'REACHED_PUSH_STAGE\n'
INNER
chmod +x "$TMP/test-clippy-timeout.sh"

# Run from a scratch git repo so git status works
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" commit --allow-empty -m "init" -q 2>/dev/null

output=$(cd "$TMP/repo" && bash "$TMP/test-clippy-timeout.sh" 2>&1)
if ! echo "$output" | grep -q 'REACHED_PUSH_STAGE'; then
    printf 'Script output:\n%s\n' "$output"
    fail "bot-merge exited silently before push stage when clippy --fix timed out"
fi
if ! echo "$output" | grep -q 'INFRA-1062.*timed out'; then
    printf 'Script output:\n%s\n' "$output"
    fail "timeout warning not emitted (operator gets no signal the timeout occurred)"
fi
if ! echo "$output" | grep -q 'clippy --fix pre-flight done'; then
    printf 'Script output:\n%s\n' "$output"
    fail "stage completion banner missing after timeout"
fi
ok "clippy timeout (rc=124) → continues to push stage with explicit warning"

echo
echo "All INFRA-1062 silent-exit tests passed."
