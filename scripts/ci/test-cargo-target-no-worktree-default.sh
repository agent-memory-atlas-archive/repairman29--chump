#!/usr/bin/env bash
# scripts/ci/test-cargo-target-no-worktree-default.sh — ZERO-WASTE-134
#
# Guard: no script defaults CARGO_TARGET_DIR (or builds a .cargo-build-target /
# .cargo-test-target) inside a worktree or repo root. Every default goes through
# scripts/ci/lib/resolve-cargo-target-dir.sh (CARGO_TARGET_DIR > CHUMP_CARGO_TARGET
# > ~/.cargo/chump-shared-target).
#
# Receipt: 2026-10-17, four worktrees carried private 2.4-3 GB build dirs
# (10 GiB) because chump-commit.sh and the hooks defaulted to
# <worktree>/.cargo-build-target when unset in THEIR environment.
#
# Depth: structural scan (assignment sites only) + fixture run of the real
# resolution blocks extracted from chump-commit.sh and pre-commit in a temp git
# worktree. NOT covered: read-only binary LOOKUPS such as
# ${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump (they create no dir; ~100
# test scripts use them); dynamically built paths; non-shell callers.
#
# Allowlist: scripts/ci/cargo-target-worktree-allowlist.txt (SHRINK-ONLY).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
ALLOW="scripts/ci/cargo-target-worktree-allowlist.txt"
RESOLVER="scripts/ci/lib/resolve-cargo-target-dir.sh"
FAILS=0
ok()  { echo "ok:   $*"; }
bad() { echo "FAIL: $*" >&2; FAILS=$((FAILS+1)); }

# ── Part 1: structural scan ───────────────────────────────────────────────────
# Rule A (all scripts + workflows): an assignment of CARGO_TARGET_DIR whose value
#   points at the repo/worktree root, $PWD or a .cargo-*-target dir.
# Rule B (non-test scripts): any use of a .cargo-build-target / .cargo-test-target path.
# Comments, echo/printf lines, this test, the legacy-contract test and the reaper
# (which REMOVES such dirs) are skipped.
hits="$(
  { grep -rnE '(^|[;&(|[:space:]])(export[[:space:]]+)?CARGO_TARGET_DIR:?=[^[:space:]]*(REPO_ROOT|WT_PATH|\$ROOT|\$\{ROOT|PWD|\$\(pwd|\.cargo-build-target|\.cargo-test-target)' scripts .github/workflows 2>/dev/null
    grep -rnE '\.cargo-(build|test)-target' scripts .github/workflows 2>/dev/null | grep -v '^scripts/ci/test-'
  } \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(echo|printf|log|info|warn)[[:space:]]' \
  | grep -vE '^scripts/ci/(test-cargo-target-no-worktree-default|test-cargo-mutex-isolation|cargo-target-worktree-allowlist)' \
  | grep -vE '^scripts/ops/cargo-target-reaper\.sh:' \
  | cut -d: -f1 | sort -u
)"

allowed="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" | sed -E 's/[[:space:]]+#.*//' | sort -u)"

for f in $hits; do
  if grep -qxF "$f" <<<"$allowed"; then
    ok "$f allowlisted (known debt)"
  else
    bad "$f defaults a cargo target dir inside a worktree/repo root. Source $RESOLVER and call chump_export_cargo_target_dir (do not extend the allowlist)."
  fi
done
# Shrink-only: a stale entry must be deleted.
for a in $allowed; do
  if ! grep -qxF "$a" <<<"$hits"; then
    bad "allowlist entry $a is stale (no worktree-local default found) - delete it from $ALLOW"
  fi
done
[[ -z "$hits" ]] && ok "no worktree-local cargo target defaults found"

# ── Part 2: fixture - real resolution blocks create nothing in the worktree ───
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WT="$TMP/wt"; FAKE_HOME="$TMP/home"
mkdir -p "$WT/scripts/ci/lib" "$WT/scripts/coord" "$FAKE_HOME"
git -C "$WT" init -q 2>/dev/null
cp "$RESOLVER" "$WT/scripts/ci/lib/"
cp scripts/coord/chump-commit.sh "$WT/scripts/coord/"

# Extract the resolver blocks verbatim from the two real files.
extract() { # file start-marker
  awk -v m="$2" 'index($0,m){f=1} f{print} f&&/^fi$/{exit}' "$1"
}
extract scripts/coord/chump-commit.sh '# ZERO-WASTE-134: ONE cargo target resolver (scripts/ci/lib' >"$TMP/commit-block.sh"
extract scripts/git-hooks/pre-commit '# ZERO-WASTE-134: ONE cargo target resolver, never' >"$TMP/hook-block.sh"
[[ -s "$TMP/commit-block.sh" ]] && ok "extracted chump-commit.sh resolution block" || bad "cannot extract chump-commit.sh block"
[[ -s "$TMP/hook-block.sh" ]]   && ok "extracted pre-commit resolution block"      || bad "cannot extract pre-commit block"

# 1) chump-commit.sh block: env scrubbed (the hook-path case), cwd = the worktree.
# $0 points at the copied script so the block finds its sibling resolver.
run_block() { # block-file, extra-env...
  (cd "$WT" && env -i HOME="$FAKE_HOME" PATH="$PATH" "${@:2}" bash -c '
    REPO_ROOT="$1"; blk="$2"
    set -- ; eval "$(cat "$blk")"
    printf "%s\n" "$CARGO_TARGET_DIR"' "$WT/scripts/coord/chump-commit.sh" "$WT" "$1" 2>/dev/null)
}
got="$(run_block "$TMP/commit-block.sh")"
exp="$FAKE_HOME/.cargo/chump-shared-target"
[[ "$got" == "$exp" ]] && ok "chump-commit.sh block resolves to shared dir ($got)" || bad "chump-commit.sh block resolved '$got', expected '$exp'"
[[ ! -e "$WT/.cargo-build-target" ]] && ok "no <worktree>/.cargo-build-target created by chump-commit.sh block" || bad "<worktree>/.cargo-build-target was created"
[[ -d "$exp" ]] && ok "shared dir created under HOME" || bad "shared dir not created"

# 2) pre-commit block (uses $REPO_ROOT directly).
got2="$(cd "$WT" && env -i HOME="$FAKE_HOME" PATH="$PATH" bash -c '
  REPO_ROOT="$1"; eval "$(cat "$2")"; printf "%s\n" "$CARGO_TARGET_DIR"' x "$WT" "$TMP/hook-block.sh" 2>/dev/null)"
[[ "$got2" == "$exp" ]] && ok "pre-commit block resolves to shared dir" || bad "pre-commit block resolved '$got2', expected '$exp'"
[[ ! -e "$WT/.cargo-build-target" ]] && ok "no <worktree>/.cargo-build-target created by pre-commit block" || bad "pre-commit block created <worktree>/.cargo-build-target"

# 3) env override honored, announce once.
got3="$(cd "$WT" && env -i HOME="$FAKE_HOME" PATH="$PATH" CARGO_TARGET_DIR="$TMP/agent-dir" bash -c '
  REPO_ROOT="$1"; eval "$(cat "$2")"; printf "%s\n" "$CARGO_TARGET_DIR"' x "$WT" "$TMP/hook-block.sh" 2>/dev/null)"
[[ "$got3" == "$TMP/agent-dir" ]] && ok "caller CARGO_TARGET_DIR respected" || bad "caller CARGO_TARGET_DIR overridden: '$got3'"
ann="$(cd "$WT" && env -i HOME="$FAKE_HOME" PATH="$PATH" bash -c '
  REPO_ROOT="$1"; eval "$(cat "$2")"; eval "$(cat "$2")"' x "$WT" "$TMP/hook-block.sh" 2>&1 >/dev/null | grep -c '^\[cargo-target\]')"
[[ "$ann" == "1" ]] && ok "announces the chosen dir exactly once" || bad "expected 1 announce line, got $ann"

if [[ "$FAILS" -gt 0 ]]; then echo "test-cargo-target-no-worktree-default: $FAILS failure(s)" >&2; exit 1; fi
echo "test-cargo-target-no-worktree-default: PASS"
