#!/usr/bin/env bash
# scripts/ci/test-cargo-mutex-isolation.sh
#
# INFRA-1374 originally asserted that chump-commit.sh, bot-merge.sh, the
# pre-commit hook and the infra smoke each pinned a PER-WORKTREE
# .cargo-build-target. ZERO-WASTE-134 reversed that: four worktrees carried
# private 2.4-3 GB build dirs (10 GiB, measured 2026-10-17). The contract is now:
#   - the four entry points adopt the ONE resolver
#     (scripts/ci/lib/resolve-cargo-target-dir.sh -> chump_export_cargo_target_dir)
#   - none of them defaults CARGO_TARGET_DIR to a path inside the worktree
#   - the resolver order is CARGO_TARGET_DIR > CHUMP_CARGO_TARGET >
#     CHUMP_SHARED_CARGO_TARGET > $HOME/.cargo/chump-shared-target
# Lock contention is still observed by bot-merge's cargo_lock_wait wrapper.
#
# Hermetic; no cargo. Related: test-cargo-target-no-worktree-default.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

RESOLVER="$REPO_ROOT/scripts/ci/lib/resolve-cargo-target-dir.sh"
for f in scripts/coord/chump-commit.sh scripts/coord/bot-merge.sh \
         scripts/git-hooks/pre-commit scripts/ci/test-infra-changes-smoke.sh; do
  if grep -q 'chump_export_cargo_target_dir' "$REPO_ROOT/$f"; then
    ok "$f adopts the shared resolver"
  else
    fail "$f does not call chump_export_cargo_target_dir"
  fi
  if grep -v '^[[:space:]]*#' "$REPO_ROOT/$f" | grep -qE '\.cargo-build-target'; then
    fail "$f still references .cargo-build-target outside comments"
  else
    ok "$f has no .cargo-build-target default"
  fi
done

# Resolver precedence, run in a clean env.
run() { env -i HOME="/u" PATH="$PATH" "$@" bash -c \
  "source '$RESOLVER'; chump_cargo_target_dir"; }
chk() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1 -> $3"; else fail "$1: expected $2 got $3"; fi
}
chk "default" "/u/.cargo/chump-shared-target" "$(run)"
chk "CHUMP_SHARED_CARGO_TARGET alias" "/a" "$(run CHUMP_SHARED_CARGO_TARGET=/a)"
chk "CHUMP_CARGO_TARGET beats alias" "/b" "$(run CHUMP_SHARED_CARGO_TARGET=/a CHUMP_CARGO_TARGET=/b)"
chk "CARGO_TARGET_DIR beats all" "/c" "$(run CHUMP_CARGO_TARGET=/b CARGO_TARGET_DIR=/c)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "All checks passed."
