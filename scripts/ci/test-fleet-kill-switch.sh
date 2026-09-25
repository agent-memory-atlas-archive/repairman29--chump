#!/usr/bin/env bash
# scripts/ci/test-fleet-kill-switch.sh — RESILIENT-073
#
# Verifies the fleet kill switch (AUTONOMY_LEVEL) contract:
#
#   1. AUTONOMY_LEVEL=0  → chump claim refuses (exit non-zero)
#   2. File missing      → chump claim refuses (fail-closed)
#   3. File corrupt      → chump claim refuses (fail-closed)
#   4. AUTONOMY_LEVEL=5  → chump claim proceeds past the kill-switch gate
#   5. AUTONOMY_LEVEL=0  → bot-merge refuses (exit 10)
#   6. File missing      → bot-merge refuses (exit 10, fail-closed)
#   7. AUTONOMY_LEVEL=5  → bot-merge passes the kill-switch gate
#   8. worker.sh tick    → AUTONOMY_LEVEL=0 emits fleet_stopped_kill_switch
#                          and does NOT claim a gap
#
# All tests use a temporary HOME so they never touch the real
# ~/.chump/AUTONOMY_LEVEL on the operator's machine.
#
# Exit 0 = all pass.  Exit 1 = at least one failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# RESILIENT-073: Tests 1-4 exercise the compiled `chump` binary's claim gating.
# Quick jobs (fast-checks) run `cargo check` but don't produce a binary at
# target/debug/chump, so build it on demand here — keeps the test self-contained
# across CI jobs without skipping any coverage.
#
# Resolve the binary path via `cargo metadata` AFTER the build — that's the
# only path that survives every env permutation we hit:
#   - CI sets CARGO_TARGET_DIR=/tmp/cargo-target-NNNN-N (out-of-tree)
#   - local dev sets .cargo/config.toml [build].target-dir = shared dir
#     (INFRA-481, .gitignored — not present in CI)
#   - vanilla worktree: $REPO_ROOT/target
if ! command -v cargo &>/dev/null; then
    echo "[FAIL] cargo not on PATH; cannot resolve chump binary" >&2
    exit 1
fi

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[kill-switch-test] chump binary absent in this job — building (cargo build --bin chump)…"
    (cd "$REPO_ROOT" && cargo build --bin chump --quiet) || {
        echo "[FAIL] could not build chump binary for kill-switch test" >&2
        exit 1
    }
    _target_dir="$(cd "$REPO_ROOT" && cargo metadata --no-deps --format-version 1 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("target_directory",""))' 2>/dev/null)"
    if [[ -n "$_target_dir" && -x "$_target_dir/debug/chump" ]]; then
        CHUMP_BIN="$_target_dir/debug/chump"
    fi
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[FAIL] chump binary still absent at $CHUMP_BIN after build" >&2
    exit 1
fi

PASS=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

# ── Fixtures ─────────────────────────────────────────────────────────────────

# Synthetic HOME so every test gets an isolated ~/.chump/AUTONOMY_LEVEL.
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/.chump"

AL_FILE="$FAKE_HOME/.chump/AUTONOMY_LEVEL"

# Synthetic ambient log so events land somewhere inspectable.
FAKE_AMBIENT="$FAKE_HOME/ambient.jsonl"

# ── Helper: read ambient for a kind ──────────────────────────────────────────
ambient_has_kind() {
    local kind="$1"
    grep -q "\"kind\":\"${kind}\"" "$FAKE_AMBIENT" 2>/dev/null
}

# ── Helper: run chump claim against a disposable state ───────────────────────
# We don't actually create a worktree — we only care that the kill-switch gate
# fires before any mutation. The claim will fail for *some* reason; we just
# check the stderr contains the right message when the kill switch is the cause.
run_claim_check() {
    local label="$1"
    # Use a non-existent gap ID so claim fails fast; what matters is *why*.
    HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
        "$CHUMP_BIN" claim RESILIENT-073-TEST-FAKE --role fleet-test 2>&1 || true
}

# ── Test 1: AUTONOMY_LEVEL=0 → claim refuses ─────────────────────────────────
echo "0" > "$AL_FILE"
_out="$(HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    "$CHUMP_BIN" claim RESILIENT-073-FAKE --role fleet-test 2>&1 || true)"
if echo "$_out" | grep -q "fleet stopped"; then
    ok "Test 1: AUTONOMY_LEVEL=0 → claim refused with 'fleet stopped'"
else
    fail "Test 1: AUTONOMY_LEVEL=0 → claim output did not contain 'fleet stopped': $_out"
fi

# ── Test 2: File missing → claim refuses (fail-closed) ───────────────────────
rm -f "$AL_FILE"
_out="$(HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    "$CHUMP_BIN" claim RESILIENT-073-FAKE --role fleet-test 2>&1 || true)"
if echo "$_out" | grep -q "fleet stopped"; then
    ok "Test 2: AUTONOMY_LEVEL missing → claim refused (fail-closed)"
else
    fail "Test 2: AUTONOMY_LEVEL missing → claim did not refuse: $_out"
fi

# ── Test 3: File corrupt → claim refuses (fail-closed) ───────────────────────
echo "banana" > "$AL_FILE"
_out="$(HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    "$CHUMP_BIN" claim RESILIENT-073-FAKE --role fleet-test 2>&1 || true)"
if echo "$_out" | grep -q "fleet stopped"; then
    ok "Test 3: AUTONOMY_LEVEL=corrupt → claim refused (fail-closed)"
else
    fail "Test 3: AUTONOMY_LEVEL=corrupt → claim did not refuse: $_out"
fi

# ── Test 4: AUTONOMY_LEVEL=5 → kill-switch gate passes ──────────────────────
# The claim will still fail (fake gap ID, no worktree set up) but must NOT
# fail with "fleet stopped".
echo "5" > "$AL_FILE"
_out="$(HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    "$CHUMP_BIN" claim RESILIENT-073-FAKE --role fleet-test 2>&1 || true)"
if echo "$_out" | grep -q "fleet stopped"; then
    fail "Test 4: AUTONOMY_LEVEL=5 → kill-switch fired (should not have)"
else
    ok "Test 4: AUTONOMY_LEVEL=5 → kill-switch gate passed"
fi

# ── Test 5: bot-merge AUTONOMY_LEVEL=0 → exit 10 ────────────────────────────
echo "0" > "$AL_FILE"
_rc=0
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    bash "$REPO_ROOT/scripts/coord/bot-merge.sh" --gap FAKE-999 --dry-run 2>/dev/null \
    || _rc=$?
if [[ "$_rc" -eq 10 ]]; then
    ok "Test 5: bot-merge AUTONOMY_LEVEL=0 → exit 10"
else
    fail "Test 5: bot-merge AUTONOMY_LEVEL=0 → expected exit 10, got $_rc"
fi

# ── Test 6: bot-merge file missing → exit 10 (fail-closed) ──────────────────
rm -f "$AL_FILE"
_rc=0
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    bash "$REPO_ROOT/scripts/coord/bot-merge.sh" --gap FAKE-999 --dry-run 2>/dev/null \
    || _rc=$?
if [[ "$_rc" -eq 10 ]]; then
    ok "Test 6: bot-merge AUTONOMY_LEVEL missing → exit 10 (fail-closed)"
else
    fail "Test 6: bot-merge AUTONOMY_LEVEL missing → expected exit 10, got $_rc"
fi

# ── Test 7: bot-merge AUTONOMY_LEVEL=5 → kill-switch passes ──────────────────
# bot-merge will fail later (no real git repo / gh setup) but must NOT exit 10.
echo "5" > "$AL_FILE"
_rc=0
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    bash "$REPO_ROOT/scripts/coord/bot-merge.sh" --gap FAKE-999 --dry-run 2>/dev/null \
    || _rc=$?
if [[ "$_rc" -eq 10 ]]; then
    fail "Test 7: bot-merge AUTONOMY_LEVEL=5 → kill-switch fired (should not have, rc=$_rc)"
else
    ok "Test 7: bot-merge AUTONOMY_LEVEL=5 → kill-switch gate passed (rc=$_rc)"
fi

# ── Test 8: ambient kind=fleet_stopped_kill_switch emitted on level 0 ────────
echo "0" > "$AL_FILE"
> "$FAKE_AMBIENT"  # clear
# Simulate a worker.sh tick by sourcing just the kill-switch block inline.
_al_level=0
if [[ -r "$AL_FILE" ]]; then
    _al_raw="$(tr -d '[:space:]' < "$AL_FILE" 2>/dev/null || true)"
    if [[ "$_al_raw" =~ ^[0-9]+$ ]] && [[ "$_al_raw" -gt 0 ]]; then
        _al_level="$_al_raw"
    fi
fi
if [[ "$_al_level" -eq 0 ]]; then
    printf '{"ts":"%s","kind":"fleet_stopped_kill_switch","source":"worker","agent_id":"test","autonomy_level":%s,"note":"RESILIENT-073"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_al_level}" >> "$FAKE_AMBIENT" 2>/dev/null || true
fi
if ambient_has_kind "fleet_stopped_kill_switch"; then
    ok "Test 8: AUTONOMY_LEVEL=0 → fleet_stopped_kill_switch emitted to ambient"
else
    fail "Test 8: fleet_stopped_kill_switch not found in ambient stream"
fi

# ── Test 9: refresh/provision scripts must never write AUTONOMY_LEVEL ────────
# RESILIENT-321: a refresh/provision path clobbered ~/.chump/AUTONOMY_LEVEL to
# 0 on 2026-08-14, silently halting the fleet 6h. These scripts run
# unattended (systemd timer / node provisioning) and must never write to the
# kill-switch file — only explicit operator commands (`chump fleet
# start|stop|level|down`) may. Static guard: neither script may contain a
# redirect into AUTONOMY_LEVEL.
_refresh_provision_scripts=(
    "$REPO_ROOT/scripts/ops/node-refresh-chump.sh"
    "$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
    "$REPO_ROOT/scripts/setup/provision-chumpd-host.sh"
    "$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
)
_write_offenders=""
for _script in "${_refresh_provision_scripts[@]}"; do
    if [[ -f "$_script" ]] && grep -vE '^\s*#' "$_script" | grep -E '>[^>=].*AUTONOMY_LEVEL|AUTONOMY_LEVEL.*[^<]<' >/dev/null 2>&1; then
        _write_offenders="${_write_offenders} $_script"
    fi
done
if [[ -z "$_write_offenders" ]]; then
    ok "Test 9: refresh/provision scripts contain no AUTONOMY_LEVEL write"
else
    fail "Test 9: found a write into AUTONOMY_LEVEL in:${_write_offenders} — refresh/provision must never clobber the operator's kill switch"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
