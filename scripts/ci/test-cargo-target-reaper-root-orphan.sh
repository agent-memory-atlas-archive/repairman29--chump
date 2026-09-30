#!/usr/bin/env bash
# test-cargo-target-reaper-root-orphan.sh — INFRA-7890
# Smoke-tests Class (i): orphaned root-level .cargo-test-target /
# .cargo-build-target dirs directly under REPO_ROOT (not under /tmp/chump-*,
# which is already covered by Class B). These are leftovers from a direct
# (non-worktree) build/test run, now superseded by the shared sccache cache.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }
skip() { echo "  SKIP $*"; }

echo "=== test-cargo-target-reaper-root-orphan.sh (INFRA-7890) ==="

if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    skip "active cargo/rustc process — cannot run reaper tests"
    exit 0
fi

TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT
mkdir -p "${TMPBASE}/.chump-locks"

# Patch REPO_ROOT to point at TMPBASE, mirroring test-cargo-target-reaper-scope.sh
PATCHED="${TMPBASE}/reaper-root-orphan-test.sh"
sed "s|REPO_ROOT=\"\$(cd.*\"|REPO_ROOT=\"${TMPBASE}\"|" "$REAPER" > "$PATCHED"
chmod +x "$PATCHED"

# ── Test 1: fresh root .cargo-test-target (within FLEET_AGE_D) is NOT reaped ──
echo "--- Test 1: fresh .cargo-test-target is preserved ---"
mkdir -p "${TMPBASE}/.cargo-test-target/debug"
touch "${TMPBASE}/.cargo-test-target/debug/fresh"

CHUMP_CARGO_REAPER_TMP_GLOB="/nonexistent-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    bash "$PATCHED" --fleet-age-d 7 --execute >/dev/null 2>&1 || true

[[ -d "${TMPBASE}/.cargo-test-target" ]] \
    || fail "fresh root .cargo-test-target was reaped despite being <7d old"
pass "fresh root .cargo-test-target preserved"

# ── Test 2: stale root .cargo-test-target IS reaped ──────────────────────────
echo "--- Test 2: stale root .cargo-test-target is removed ---"
# Backdate mtime beyond FLEET_AGE_D
touch -d '30 days ago' "${TMPBASE}/.cargo-test-target" 2>/dev/null \
    || touch -t 202501010000 "${TMPBASE}/.cargo-test-target"

dry_out=$(CHUMP_CARGO_REAPER_TMP_GLOB="/nonexistent-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    bash "$PATCHED" --fleet-age-d 7 2>&1 || true)
echo "$dry_out" | grep -q "root orphaned cargo target" \
    || fail "dry-run did not identify stale root .cargo-test-target"
pass "stale root .cargo-test-target identified in dry-run"

CHUMP_CARGO_REAPER_TMP_GLOB="/nonexistent-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    bash "$PATCHED" --fleet-age-d 7 --execute >/dev/null 2>&1 || true

[[ ! -d "${TMPBASE}/.cargo-test-target" ]] \
    || fail "stale root .cargo-test-target not removed by --execute"
pass "stale root .cargo-test-target removed by --execute"

# ── Test 3: summary event includes root_orphan_target_count ─────────────────
echo "--- Test 3: summary event has root_orphan_target_count ---"
grep -q 'root_orphan_target_count' "$REAPER" \
    || fail "root_orphan_target_count not in summary emit"
pass "summary event includes root_orphan_target_count"

echo ""
echo "All INFRA-7890 root-orphan reaper tests passed."
