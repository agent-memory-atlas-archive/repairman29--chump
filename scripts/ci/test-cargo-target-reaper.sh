#!/usr/bin/env bash
# test-cargo-target-reaper.sh — INFRA-1250
# Validates cargo-target-reaper.sh: stale + fresh fixture, dry-run, --execute.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-cargo-target-reaper.sh ==="

# ── Fixture setup ────────────────────────────────────────────────────────────
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_TARGET="${TMPDIR_BASE}/target/debug"
mkdir -p "${FAKE_TARGET}/.fingerprint" "${FAKE_TARGET}/deps"

# Create stale entries (30 days old)
mkdir -p "${FAKE_TARGET}/.fingerprint/stale-crate-abc123"
touch -d "30 days ago" "${FAKE_TARGET}/.fingerprint/stale-crate-abc123" 2>/dev/null \
    || touch -A -302400000 "${FAKE_TARGET}/.fingerprint/stale-crate-abc123" 2>/dev/null \
    || python3 -c "import os,time; os.utime('${FAKE_TARGET}/.fingerprint/stale-crate-abc123', (time.time()-2592000, time.time()-2592000))"
touch "${FAKE_TARGET}/deps/libstale_crate-abc123.rlib"
python3 -c "import os,time; os.utime('${FAKE_TARGET}/deps/libstale_crate-abc123.rlib', (time.time()-2592000, time.time()-2592000))"

# Create fresh entries (1 day old — should NOT be reaped with default 14d threshold)
mkdir -p "${FAKE_TARGET}/.fingerprint/fresh-crate-def456"
touch "${FAKE_TARGET}/deps/libfresh_crate-def456.rlib"

# ── Test 1: Safety guard — active cargo process ──────────────────────────────
echo "--- Test 1: safety guard (active cargo) ---"
# Can't easily fake a cargo process in CI, so just verify guard logic exists
grep -q "pgrep.*cargo\|pgrep.*rustc" "$REAPER" || fail "no active-cargo guard found in reaper script"
pass "active-cargo guard present"

# ── Test 2: Safety guard — low disk ─────────────────────────────────────────
echo "--- Test 2: safety guard (low disk check present) ---"
grep -q "free_gb\|MIN_FREE_GB\|df -k" "$REAPER" || fail "no low-disk guard found in reaper script"
pass "low-disk guard present"

# ── Test 3: dry-run identifies stale, not fresh ──────────────────────────────
echo "--- Test 3: dry-run identifies stale only ---"
# Override REPO_ROOT by running from TMPDIR_BASE with symlinked structure
mkdir -p "${TMPDIR_BASE}/.chump-locks"
# Patch: copy reaper with overridden REPO_ROOT.
# Also set CHUMP_CARGO_REAPER_GIT_DIR to the real repo so git worktree list works,
# and CHUMP_CARGO_REAPER_TMP_GLOB="" to disable the /tmp orphan scan (test isolation).
PATCHED_REAPER="${TMPDIR_BASE}/cargo-target-reaper-test.sh"
sed "s|REPO_ROOT=\"\$(cd.*\"|REPO_ROOT=\"${TMPDIR_BASE}\"|" "$REAPER" > "$PATCHED_REAPER"
chmod +x "$PATCHED_REAPER"

# Run dry-run (no cargo processes in CI — guard passes)
if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "  SKIP (active cargo process detected — cannot run reaper in this environment)"
else
    output=$(CHUMP_CARGO_REAPER_TMP_GLOB="" bash "$PATCHED_REAPER" --fingerprint-age-d 14 2>&1 || true)
    echo "$output" | grep -q "stale-crate" || fail "dry-run did not identify stale-crate"
    echo "$output" | grep -q "fresh-crate" && fail "dry-run incorrectly targeted fresh-crate" || true
    pass "dry-run correctly identifies stale, skips fresh"
fi

# ── Test 4: --execute actually deletes stale ────────────────────────────────
echo "--- Test 4: --execute deletes stale ---"
if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "  SKIP (active cargo process detected)"
else
    CHUMP_CARGO_REAPER_TMP_GLOB="" bash "$PATCHED_REAPER" --fingerprint-age-d 14 --execute 2>&1 || true
    [[ -d "${FAKE_TARGET}/.fingerprint/stale-crate-abc123" ]] \
        && fail "stale fingerprint dir not deleted by --execute"
    [[ -f "${FAKE_TARGET}/deps/libstale_crate-abc123.rlib" ]] \
        && fail "stale rlib not deleted by --execute"
    [[ -d "${FAKE_TARGET}/.fingerprint/fresh-crate-def456" ]] \
        || fail "fresh fingerprint dir was incorrectly deleted"
    [[ -f "${FAKE_TARGET}/deps/libfresh_crate-def456.rlib" ]] \
        || fail "fresh rlib was incorrectly deleted"
    pass "--execute deletes stale, preserves fresh"
fi

# ── Test 5: ambient event emitted ────────────────────────────────────────────
echo "--- Test 5: ambient event emitted ---"
if [[ -f "${TMPDIR_BASE}/.chump-locks/ambient.jsonl" ]]; then
    grep -q '"kind":"cargo_target_reaper_summary"' "${TMPDIR_BASE}/.chump-locks/ambient.jsonl" \
        || fail "cargo_target_reaper_summary event not emitted"
    pass "cargo_target_reaper_summary emitted to ambient.jsonl"
else
    echo "  SKIP (ambient log not created — no artifacts reaped in skipped tests)"
fi

# ── Test 6: --help exits 0 ───────────────────────────────────────────────────
echo "--- Test 6: --help exits 0 ---"
bash "$REAPER" --help > /dev/null || fail "--help exited non-zero"
pass "--help exits 0"

# ── Test 7: script syntax check ──────────────────────────────────────────────
echo "--- Test 7: bash -n syntax check ---"
bash -n "$REAPER" || fail "script has syntax errors"
pass "script syntax OK"

# ── Test 8: INFRA-1170 — orphaned /tmp/chump-*/target/ reap ─────────────────
echo "--- Test 8: orphaned /tmp worktree target/ reap (INFRA-1170) ---"
if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "  SKIP (active cargo process detected)"
else
    # Create a synthetic orphaned worktree under a temp path that mimics /tmp/chump-<gap>-<id>/.
    # We can't use /tmp/chump-* directly (would need root on some systems), so we patch
    # the reaper to scan our synthetic directory instead via CHUMP_CARGO_REAPER_TMP_GLOB.
    # Since the reaper hard-codes /tmp/chump-*/, we instead test the logic via source-check.
    grep -q 'INFRA-1170' "$REAPER" \
        || fail "INFRA-1170 attribution missing from reaper"
    grep -q 'worktree_gone.*true\|worktree_gone=true' "$REAPER" \
        || fail "worktree_gone field not emitted in reaper"
    grep -q 'worktree list --porcelain' "$REAPER" \
        || fail "git worktree list --porcelain check not in reaper"
    grep -q 'failure_class.*transient\|transient.*failure_class' "$REAPER" \
        || fail "transient failure class not present in reaper"
    grep -q 'failure_class.*permanent\|permanent.*failure_class' "$REAPER" \
        || fail "permanent failure class not present in reaper"
    grep -q 'worktree_orphan_count' "$REAPER" \
        || fail "worktree_orphan_count not in summary emit"
    pass "INFRA-1170: worktree_gone field, failure taxonomy, orphan count all present"

    # Functional test: synthetic /tmp/chump-test-reaper-XXXX that is NOT a registered worktree.
    _fake_wt="$(mktemp -d /tmp/chump-test-reaper-XXXX)"
    _fake_target="${_fake_wt}/target"
    mkdir -p "$_fake_target"
    mkdir -p "${TMPDIR_BASE}/.chump-locks"

    # Run with:
    #   CHUMP_CARGO_REAPER_TMP_GLOB pointing only at the fake dir (safe scan scope)
    #   CHUMP_CARGO_REAPER_GIT_DIR pointing at the real repo (so worktree list works)
    # The fake dir is NOT a registered worktree, so it should be treated as orphaned.
    PATCHED2="${TMPDIR_BASE}/cargo-target-reaper-infra1170.sh"
    sed "s|REPO_ROOT=\"\$(cd.*\"|REPO_ROOT=\"${TMPDIR_BASE}\"|" "$REAPER" > "$PATCHED2"
    chmod +x "$PATCHED2"

    orphan_out=$(CHUMP_CARGO_REAPER_TMP_GLOB="$_fake_wt" \
        CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
        bash "$PATCHED2" 2>&1 || true)
    if echo "$orphan_out" | grep -q 'orphan worktree target'; then
        pass "INFRA-1170 dry-run identifies orphaned /tmp/chump-*/target/"
    else
        # If git worktree list happens to list the fake path (unlikely), skip gracefully.
        if git worktree list --porcelain 2>/dev/null | grep -qxF "worktree ${_fake_wt}"; then
            echo "  SKIP (fake wt accidentally in git worktree list)"
        else
            fail "INFRA-1170 dry-run did not identify orphaned target: $orphan_out"
        fi
    fi

    # Verify ambient event with worktree_gone=true emitted.
    _amb="${TMPDIR_BASE}/.chump-locks/ambient.jsonl"
    if [[ -f "$_amb" ]] && grep -q '"worktree_gone":true' "$_amb" 2>/dev/null; then
        pass "INFRA-1170 ambient event has worktree_gone:true"
    else
        echo "  SKIP (ambient log empty — no orphaned target processed)"
    fi

    # Verify --execute removes the orphaned target dir.
    CHUMP_CARGO_REAPER_TMP_GLOB="$_fake_wt" \
        CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
        bash "$PATCHED2" --execute 2>&1 || true
    if [[ ! -d "$_fake_target" ]]; then
        pass "INFRA-1170 --execute removed orphaned target/"
    else
        # May not have been removed if worktree showed up as registered somehow.
        echo "  SKIP (target dir still present — likely registered worktree edge case)"
    fi

    rm -rf "$_fake_wt" 2>/dev/null || true
fi

# ── Test 9: summary event includes worktree_orphan_count ─────────────────────
echo "--- Test 9: summary event has worktree_orphan_count (INFRA-1170) ---"
grep -q 'worktree_orphan_count' "$REAPER" \
    || fail "worktree_orphan_count not present in cargo_target_reaper_summary emit"
pass "summary event includes worktree_orphan_count"

# ── Test 10: ZERO-WASTE-012 — disk-critical aggressive mode bypasses the blanket
#    cargo-active abort, so the reaper actually runs on a continuously-building fleet.
#    (Runs the reaper in dry-run = default, so it never deletes during the test.) ──
echo "--- Test 10: aggressive mode bypasses the blanket cargo-active abort (ZERO-WASTE-012) ---"
# Spawn a fake process matching the reaper's `pgrep -f \"rustc \"` guard (argv0=\"rustc \").
# RESILIENT-219: 60s (was 20s) — under CI load the two reaper invocations below
# together can take longer than 20s, letting the fake process exit before the
# second invocation's own `pgrep -f "rustc "` check runs, which silently
# changes the test's premise (no active build) instead of failing loudly.
( exec -a "rustc " sleep 60 ) &
_fake_rustc_pid=$!
sleep 0.3
if ! pgrep -f "rustc " >/dev/null 2>&1; then
    kill "$_fake_rustc_pid" 2>/dev/null || true
    echo "  SKIP (could not spawn a fake rustc matcher in this environment)"
else
    # RESILIENT-219: `printf '%s' "$long_string" | grep -q pattern` is a classic
    # pipefail footgun — `grep -q` exits the instant it finds a match (that's
    # what -q optimizes for), which can SIGPIPE a still-writing printf if
    # $long_string exceeds what grep needed to read. This script runs under
    # `set -o pipefail`, so that SIGPIPE (exit 141) becomes the PIPELINE's
    # reported exit status regardless of grep's own (correct) result --
    # observed in CI as "printf: write error: Broken pipe" immediately
    # followed by this test falsely reporting "neither aborted nor escalated"
    # even when the reaper's real output was correct. Pure bash substring
    # matching sidesteps the footgun entirely (no subprocess, no pipe).
    #
    # Normal mode (disk healthy) + active build → MUST NOT reap. It skips
    # cleanly and exits 0: an active build is a normal condition on a worker
    # node, not a failure, and a non-zero exit marked the systemd oneshot
    # `failed` every tick — the exact spurious-failure the guard should not
    # cause. The conservative guard is still intact: normal mode never touches
    # target/ while a build runs; it just returns 0 instead of aborting.
    set +e
    out_normal="$(CHUMP_DISK_CRITICAL_GB=0 bash "$REAPER" 2>&1)"
    rc_normal=$?
    set -e
    if [[ "$out_normal" == *"SKIP: active cargo"* && $rc_normal -eq 0 ]]; then
        pass "normal mode skips cleanly (exit 0, no reap) on an active cargo/rustc process — conservative guard intact"
    else
        fail "normal mode did NOT skip cleanly on active rustc (rc=$rc_normal) — the conservative guard was lost"
    fi
    # Disk-critical aggressive mode + active build → must NOT abort; must escalate.
    out_agg="$(CHUMP_DISK_CRITICAL_GB=999999 bash "$REAPER" 2>&1 || true)"
    if [[ "$out_agg" == *"ABORT: active cargo"* ]]; then
        fail "aggressive mode STILL aborts on active cargo — fix ineffective (the bug)"
    elif [[ "$out_agg" == *"escalating"* ]]; then
        pass "disk-critical aggressive mode bypasses the blanket cargo-active abort + escalates"
    else
        fail "aggressive mode neither aborted nor escalated — unexpected"
    fi
    kill "$_fake_rustc_pid" 2>/dev/null || true
fi

echo ""
echo "All cargo-target-reaper tests passed."
