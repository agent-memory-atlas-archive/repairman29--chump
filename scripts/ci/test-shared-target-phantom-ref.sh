#!/usr/bin/env bash
# scripts/ci/test-shared-target-phantom-ref.sh — INFRA-1138 (2026-05-14)
#
# Verifies that using CARGO_TARGET_DIR per-worktree in the test gate prevents
# phantom fingerprint errors caused by sibling worktrees sharing the same
# CARGO_TARGET_DIR (set by install-sccache.sh / INFRA-481).
#
# Tests:
#   1. Structural: pre-push uses per-worktree CARGO_TARGET_DIR for cargo test
#   2. Structural: .cargo-test-target is gitignored
#   3. Structural: INFRA-1138 marker present in pre-push hook
#   4. Logic: CARGO_TARGET_DIR override isolates fingerprints (env var visible)
#   5. Logic: sccache rustc-wrapper config is NOT overridden (still applies)
#   6. Logic: .cargo-test-target path is per-worktree (uses REPO_ROOT_T)
#   7. Documentation: CLAUDE_GOTCHAS.md mentions phantom fingerprint issue
#   8. Documentation: KNOWN_FLAKES.yaml connection (previously documented flakes)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRE_PUSH="$REPO_ROOT/scripts/git-hooks/pre-push"
GITIGNORE="$REPO_ROOT/.gitignore"
GOTCHAS="$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1138 shared-target phantom-ref test ==="
echo

# ── Test 1: pre-push uses per-worktree CARGO_TARGET_DIR ──────────────────────
if grep -q "cargo-test-target" "$PRE_PUSH" && grep -q "CARGO_TARGET_DIR" "$PRE_PUSH"; then
    ok "pre-push sets per-worktree CARGO_TARGET_DIR for cargo test"
else
    fail "pre-push missing per-worktree CARGO_TARGET_DIR for cargo test"
fi

# ── Test 2: .cargo-test-target is gitignored ─────────────────────────────────
if grep -q "\.cargo-test-target" "$GITIGNORE"; then
    ok ".cargo-test-target is in .gitignore"
else
    fail ".cargo-test-target not found in .gitignore"
fi

# ── Test 3: INFRA-1138 marker in pre-push ─────────────────────────────────────
if grep -q "INFRA-1138" "$PRE_PUSH"; then
    ok "INFRA-1138 marker present in pre-push hook"
else
    fail "INFRA-1138 marker missing from pre-push hook"
fi

# ── Test 4: CARGO_TARGET_DIR is set before cargo test invocation ─────────────
# Verify the override appears on the same line as cargo test (env-prefix form)
if grep -qE "CARGO_TARGET_DIR=.*cargo test|CARGO_TARGET_DIR.*\\\s*$" "$PRE_PUSH"; then
    ok "CARGO_TARGET_DIR env-prefix applied before cargo test invocation"
else
    fail "CARGO_TARGET_DIR env-prefix not correctly placed before cargo test"
fi

# ── Test 5: sccache rustc-wrapper not UNCONDITIONALLY disabled ───────────────
# The .cargo/config.toml still has rustc-wrapper=sccache and the normal push
# path keeps it. CREDIBLE-165: INFRA-2184 / EFFECTIVE-097 later added a *guarded*
# self-heal that disables the wrapper ONLY when the sccache binary is missing or
# unresponsive (the test gate still runs, just uncached — a TRUE signal, never a
# false fail). That heal lives in a `_PREPUSH_WRAPPER_OVERRIDE=(env ... RUSTC_WRAPPER=)`
# array and is correct behavior, so we must not flag it. We fail only on an
# UNCONDITIONAL disable — an `unset RUSTC_WRAPPER` or bare `RUSTC_WRAPPER=` that
# is NOT part of the guarded override array (and not the `${RUSTC_WRAPPER:-…}` probe).
uncond_disable="$(grep -nE "unset.*RUSTC_WRAPPER|RUSTC_WRAPPER=|--no-rustc-wrapper" "$PRE_PUSH" \
    | grep -v "_PREPUSH_WRAPPER_OVERRIDE" \
    | grep -v "RUSTC_WRAPPER:-" || true)"
if [ -z "$uncond_disable" ]; then
    ok "pre-push does not unconditionally disable sccache rustc-wrapper (guarded EFFECTIVE-097 heal allowed)"
else
    fail "pre-push unconditionally disables sccache rustc-wrapper: $uncond_disable"
fi

# ── Test 6: per-worktree path uses REPO_ROOT_T (worktree root, not shared) ───
# CREDIBLE-1601: extract the fenced RESILIENT-1669:BEGIN-TEST-TARGET .. END-TEST-TARGET
# block and isolate the exact primary _WT_TEST_TARGET assignment line (plus its
# worktree resolver binding) instead of grepping the whole hook file.
check_primary_wt_test_target() {
    local hook_file="$1"
    local block primary_line source_line
    block="$(awk '
        index($0, "RESILIENT-1669:BEGIN-TEST-TARGET") { in_block = 1; next }
        index($0, "RESILIENT-1669:END-TEST-TARGET")   { in_block = 0; exit }
        in_block { print }
    ' "$hook_file")"
    [[ -n "$block" ]] || return 1
    primary_line="$(printf '%s\n' "$block" | awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*else([[:space:]]|$)/ { exit }
        /_WT_TEST_TARGET=/ { print; exit }
    ')"
    source_line="$(printf '%s\n' "$block" | awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*else([[:space:]]|$)/ { exit }
        /resolve-cargo-target-dir\.sh/ && /source[[:space:]]/ { print; exit }
    ')"
    [[ -n "$primary_line" ]] || return 1
    if printf '%s\n' "$primary_line" | grep -q '_WT_TEST_TARGET.*REPO_ROOT_T\|REPO_ROOT_T.*cargo-test-target'; then
        return 0
    fi
    # Post-INFRA-8620 per-node shared target: primary line must call
    # chump_cargo_target_dir/cargo-test-target AND the primary branch must
    # source resolve-cargo-target-dir.sh via $REPO_ROOT_T (not a whole-file match).
    printf '%s\n' "$primary_line" | grep -qE '_WT_TEST_TARGET="\$\(chump_cargo_target_dir\)/cargo-test-target(\/\$\(basename "\$REPO_ROOT_T"\))?"' \
        && printf '%s\n' "$source_line" | grep -q '"\$REPO_ROOT_T/scripts/ci/lib/resolve-cargo-target-dir\.sh"'
}

if { grep -q '_WT_TEST_TARGET.*REPO_ROOT_T\|REPO_ROOT_T.*cargo-test-target' "$PRE_PUSH" \
    || grep -q 'RESILIENT-1669:BEGIN-TEST-TARGET' "$PRE_PUSH"; } \
    && check_primary_wt_test_target "$PRE_PUSH"; then
    ok "per-worktree test target path uses REPO_ROOT_T (not shared main repo)"
else
    fail "per-worktree test target path missing REPO_ROOT_T binding"
fi

# ── Test 7: CLAUDE_GOTCHAS.md documents the phantom fingerprint issue ─────────
if [[ -r "$GOTCHAS" ]] && grep -q "INFRA-1138\|phantom.*fingerprint\|shared.*CARGO_TARGET_DIR.*phantom\|cargo-test-target" "$GOTCHAS"; then
    ok "CLAUDE_GOTCHAS.md documents the shared-target phantom fingerprint issue"
else
    fail "CLAUDE_GOTCHAS.md missing INFRA-1138 / phantom fingerprint documentation"
fi

# ── Test 8: structure — cargo test block includes target dir setup ────────────
# The per-worktree target dir variable is set before the cargo test invocation.
if grep -q "_WT_TEST_TARGET" "$PRE_PUSH" && grep -q "CARGO_TARGET_DIR.*_WT_TEST_TARGET" "$PRE_PUSH"; then
    ok "cargo test block sets up per-worktree _WT_TEST_TARGET then uses it as CARGO_TARGET_DIR"
else
    fail "cargo test block missing _WT_TEST_TARGET / CARGO_TARGET_DIR=\$_WT_TEST_TARGET setup"
fi

# ── Test 9 (CREDIBLE-1601): M4 mutant — dropping REPO_ROOT_T / primary assignment is killed ──
TMP_M4="$(mktemp -d)"
trap 'rm -rf "$TMP_M4"' EXIT

# Mutant 4a: pre-INFRA-8620 form with $(basename "$REPO_ROOT_T") dropped to a non-resolver literal
# while keeping REPO_ROOT_T and cargo-test-target elsewhere in the file (comments / fallback).
awk '
    index($0, "RESILIENT-1669:BEGIN-TEST-TARGET") { in_block = 1 }
    index($0, "RESILIENT-1669:END-TEST-TARGET")   { in_block = 0 }
    in_block && /_WT_TEST_TARGET="\$\(chump_cargo_target_dir\)\/cargo-test-target/ {
        sub(/\$\(chump_cargo_target_dir\)\/cargo-test-target.*/, "/tmp/unscoped-target\"")
    }
    { print }
' "$PRE_PUSH" > "$TMP_M4/pre-push-m4a"

# Mutant 4b: drop REPO_ROOT_T from the primary resolver source line inside the fenced block
# while REPO_ROOT_T still appears elsewhere in pre-push.
awk '
    index($0, "RESILIENT-1669:BEGIN-TEST-TARGET") { in_block = 1 }
    index($0, "RESILIENT-1669:END-TEST-TARGET")   { in_block = 0 }
    in_block && /source "\$REPO_ROOT_T\/scripts\/ci\/lib\/resolve-cargo-target-dir\.sh"/ {
        sub(/\$REPO_ROOT_T\//, "")
    }
    { print }
' "$PRE_PUSH" > "$TMP_M4/pre-push-m4b"

if ! check_primary_wt_test_target "$TMP_M4/pre-push-m4a" && ! check_primary_wt_test_target "$TMP_M4/pre-push-m4b"; then
    ok "M4 mutant (drop REPO_ROOT_T / primary _WT_TEST_TARGET binding inside fenced block) is killed"
else
    fail "M4 mutant survived primary _WT_TEST_TARGET fenced-block check"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
