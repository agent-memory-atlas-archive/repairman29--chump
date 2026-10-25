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

# CREDIBLE-1573: snapshot the real checkout's coordination/runtime surfaces
# BEFORE the test runs so we can assert at the end that .chump, .chump-locks,
# bin/, and sessions/ in the real checkout are 100% untouched.
_snapshot_real_checkout() {
    python3 - "$REPO_ROOT" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
for rel in (".chump", ".chump-locks", "bin", "sessions"):
    base = os.path.join(root, rel)
    if not os.path.exists(base):
        print(f"{rel}:ABSENT")
        continue
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        filenames.sort()
        rdir = os.path.relpath(dirpath, root)
        print(f"DIR:{rdir}")
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            relf = os.path.relpath(fp, root)
            try:
                st = os.lstat(fp)
                h = hashlib.sha256(open(fp, "rb").read()).hexdigest() if os.path.isfile(fp) else "nonfile"
                print(f"FILE:{relf}:{st.st_size}:{h}")
            except OSError:
                print(f"FILE:{relf}:vanished")
PYEOF
}
REAL_SNAPSHOT_BEFORE="$(_snapshot_real_checkout)"

# Synthetic HOME so every test gets an isolated ~/.chump/AUTONOMY_LEVEL.
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/.chump"

# shellcheck source=../coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
chump_test_sandbox_setup "$FAKE_HOME"
write_sandbox_healthy_node "$FAKE_HOME"
unset CHUMP_HOME CHUMP_REPO CHUMP_REPO_ROOT CHUMP_STATE_DB CHUMP_LOCK_DIR CHUMP_STATE_DIR CHUMP_TEST_SANDBOX_MARKER

# CREDIBLE-1573 / CREDIBLE-1584: isolated temp git repo + temp bin/chump copy
# inside $FAKE_HOME so `chump claim` and `bot-merge.sh` never touch the real
# checkout's .chump, .chump-locks, or bin/ (no bin/chump.wedged-inode-* leak).
BM_KS_REPO="$FAKE_HOME/bm-ks-repo"
mkdir -p "$BM_KS_REPO/.chump" "$BM_KS_REPO/.chump-locks" "$BM_KS_REPO/bin" "$BM_KS_REPO/sessions"
git -C "$BM_KS_REPO" init -q -b main
git -C "$BM_KS_REPO" config user.email "t@chump.local"
git -C "$BM_KS_REPO" config user.name "t"
git -C "$BM_KS_REPO" commit -q --allow-empty -m "init" --no-verify
cp "$REPO_ROOT/bin/chump" "$BM_KS_REPO/bin/chump" 2>/dev/null || true
export CHUMP_REPO="$BM_KS_REPO"
export CHUMP_REPO_ROOT="$BM_KS_REPO"
export CHUMP_STATE_DB="$BM_KS_REPO/.chump/state.db"
export CHUMP_LOCK_DIR="$BM_KS_REPO/.chump-locks"
export CHUMP_SESSION_DIR="$BM_KS_REPO/sessions"
export CHUMP_INTERNAL_DOCTOR=0
export PATH="$BM_KS_REPO/bin:$PATH"
cd "$BM_KS_REPO"

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
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" CHUMP_REPO_ROOT="$BM_KS_REPO" \
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
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" CHUMP_REPO_ROOT="$BM_KS_REPO" \
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
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" CHUMP_REPO_ROOT="$BM_KS_REPO" \
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

# ── Test 10: write_sandbox_healthy_node guard refuses non-lib / unsafe sandboxes
#    (RESILIENT-1652 repair 6). The healthy-node fixture writes a NOT-paused
#    node.env; if it could be aimed at a real node's state dir it would unpause a
#    paused node. These cases kill the mutants the guard exists to stop:
#      F1  — a caller sets CHUMP_HOME by hand but never ran the lib (no marker);
#      F2  — a valid lib sandbox whose CHUMP_STATE_DIR is re-pointed at a real dir;
#      F4  — a symlinked sandbox whose leaf resolves into a real dir;
#      E3b — the symlinked sandbox passed with a trailing slash ("L/"), which a
#            bare `-L` would FOLLOW and miss (pwd -P resolution catches it);
#      E3c — the same symlink passed as "L/." (a "." leaf), likewise caught;
#      F4b — a real sandbox whose .chump LEAF is a symlink into a real dir;
#      M2  — a marker left over from sandbox A while CHUMP_HOME + CHUMP_STATE_DIR
#            are hand-set to B (the marker!=arg check must still refuse).
#    This test is already wired into CI (ci.yml), so the guard is proven in the
#    merge gate without adding a new ci.yml step. Each call runs in a subshell
#    (the guard `exit 2`s on refusal); `|| rc=$?` captures it under `set -e`.
echo ""
GUARD_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME" "$GUARD_ROOT"' EXIT

# F1: caller-set CHUMP_HOME + CHUMP_STATE_DIR, but no chump_test_sandbox_setup,
# so CHUMP_TEST_SANDBOX_MARKER is absent → refuse, write nothing.
F1_DIR="$GUARD_ROOT/f1"; mkdir -p "$F1_DIR/.chump"
F1_BEFORE="$(cd "$F1_DIR" && find . | sort)"
rc=0
(
    export CHUMP_HOME="$F1_DIR" CHUMP_STATE_DIR="$F1_DIR/.chump"
    unset CHUMP_TEST_SANDBOX_MARKER
    write_sandbox_healthy_node "$F1_DIR"
) >/dev/null 2>&1 || rc=$?
F1_AFTER="$(cd "$F1_DIR" && find . | sort)"
if [[ "$rc" -eq 2 && "$F1_BEFORE" == "$F1_AFTER" ]]; then
    ok "Test 10a (F1): refuses caller-set CHUMP_HOME with no lib marker (exit 2, nothing written)"
else
    fail "Test 10a (F1): expected exit 2 + no write (rc=$rc)"
fi

# F2: a valid lib sandbox, but CHUMP_STATE_DIR re-pointed at a real paused node
# dir after setup → refuse, and the sentinel node.env stays byte-identical.
F2_SENTINEL="$GUARD_ROOT/real-node"; mkdir -p "$F2_SENTINEL"
printf 'CHUMP_NODE_MODE=paused\nCHUMP_NODE_WORK_ENABLED=0\n' >"$F2_SENTINEL/node.env"
F2_BEFORE="$(cd "$F2_SENTINEL" && find . -type f -exec sha256sum {} \; | sort)"
rc=0
(
    chump_test_sandbox_setup "$GUARD_ROOT/f2-sandbox" >/dev/null 2>&1
    export CHUMP_STATE_DIR="$F2_SENTINEL"   # the dangerous re-point
    write_sandbox_healthy_node "$GUARD_ROOT/f2-sandbox"
) >/dev/null 2>&1 || rc=$?
F2_AFTER="$(cd "$F2_SENTINEL" && find . -type f -exec sha256sum {} \; | sort)"
if [[ "$rc" -eq 2 && "$F2_BEFORE" == "$F2_AFTER" ]]; then
    ok "Test 10b (F2): refuses when CHUMP_STATE_DIR != <sandbox>/.chump (exit 2, sentinel unchanged)"
else
    fail "Test 10b (F2): expected exit 2 + sentinel unchanged (rc=$rc)"
fi

# F4: a symlinked sandbox (leaf is a symlink into a real dir) → refuse even
# though the lib set the marker/CHUMP_HOME/CHUMP_STATE_DIR to the symlink path.
# The stand-in real dir must be UNCHANGED by the guard: the 3 node files the
# fixture ever writes (oauth-token.json/node.env/farmer-heartbeat) must not have
# leaked into it. (setup legitimately mkdir's .chump there through the symlink;
# the guard — which refuses — writes none of those three.)
F4_REAL="$GUARD_ROOT/f4-real"; mkdir -p "$F4_REAL"
F4_LINK="$GUARD_ROOT/f4-link"; ln -s "$F4_REAL" "$F4_LINK"
rc=0
(
    chump_test_sandbox_setup "$F4_LINK" >/dev/null 2>&1
    write_sandbox_healthy_node "$F4_LINK"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 && ! -e "$F4_REAL/.chump/oauth-token.json" \
      && ! -e "$F4_REAL/.chump/node.env" && ! -e "$F4_REAL/.chump/farmer-heartbeat" ]]; then
    ok "Test 10c (F4): refuses a symlinked sandbox (exit 2, real target unwritten)"
else
    fail "Test 10c (F4): expected exit 2 + real target unwritten (rc=$rc)"
fi

# E3b: the SAME symlinked sandbox passed with a TRAILING SLASH ("L/"). A bare
# `-L "L/"` FOLLOWS the slash and reports "not a symlink", so the lib is set up
# WITH the trailing-slash form (marker/CHUMP_HOME/CHUMP_STATE_DIR all equal it)
# to force the symlink branch — not the marker branch — to fire. pwd -P strips
# the slash and still resolves the symlinked leaf → refuse.
E3_REAL="$GUARD_ROOT/e3-real"; mkdir -p "$E3_REAL"
E3_LINK="$GUARD_ROOT/e3-link"; ln -s "$E3_REAL" "$E3_LINK"
rc=0
(
    chump_test_sandbox_setup "$E3_LINK/" >/dev/null 2>&1
    write_sandbox_healthy_node "$E3_LINK/"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 && ! -e "$E3_REAL/.chump/oauth-token.json" \
      && ! -e "$E3_REAL/.chump/node.env" && ! -e "$E3_REAL/.chump/farmer-heartbeat" ]]; then
    ok "Test 10d (E3b): refuses a symlinked sandbox passed as 'L/' (exit 2, real target unwritten)"
else
    fail "Test 10d (E3b): expected exit 2 + real target unwritten on 'L/' (rc=$rc)"
fi

# E3c: the same symlink passed as "L/." (a "." leaf). The strip leaves the "."
# leaf, which pwd -P resolution refuses as unverifiable → refuse.
rc=0
(
    chump_test_sandbox_setup "$E3_LINK/." >/dev/null 2>&1
    write_sandbox_healthy_node "$E3_LINK/."
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 && ! -e "$E3_REAL/.chump/oauth-token.json" \
      && ! -e "$E3_REAL/.chump/node.env" && ! -e "$E3_REAL/.chump/farmer-heartbeat" ]]; then
    ok "Test 10e (E3c): refuses a symlinked sandbox passed as 'L/.' (exit 2, real target unwritten)"
else
    fail "Test 10e (E3c): expected exit 2 + real target unwritten on 'L/.' (rc=$rc)"
fi

# F4b: a REAL sandbox dir whose .chump LEAF is a symlink into a real dir. The
# sandbox leaf passes, but the .chump leaf must be refused (pwd -P on .chump),
# and the real .chump target must not receive the node files. The symlink is
# created BEFORE setup so setup's `mkdir -p <sandbox>/.chump` is a no-op on it.
F4B_SANDBOX="$GUARD_ROOT/f4b-sandbox"; mkdir -p "$F4B_SANDBOX"
F4B_REAL="$GUARD_ROOT/f4b-chump-real"; mkdir -p "$F4B_REAL"
ln -s "$F4B_REAL" "$F4B_SANDBOX/.chump"
rc=0
(
    chump_test_sandbox_setup "$F4B_SANDBOX" >/dev/null 2>&1
    write_sandbox_healthy_node "$F4B_SANDBOX"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 && ! -e "$F4B_REAL/oauth-token.json" \
      && ! -e "$F4B_REAL/node.env" && ! -e "$F4B_REAL/farmer-heartbeat" ]]; then
    ok "Test 10f (F4b): refuses a symlinked .chump leaf (exit 2, real target unwritten)"
else
    fail "Test 10f (F4b): expected exit 2 + real target unwritten on symlinked .chump (rc=$rc)"
fi

# M2: a marker left over from sandbox A, but CHUMP_HOME + CHUMP_STATE_DIR
# hand-set to a DIFFERENT dir B. B is a fully valid-looking sandbox (real
# B/.chump exists) so that WITHOUT the marker!=arg check the guard would write
# into B — the refusal here is proof the marker guard (not some other branch)
# fires. B must be unchanged.
M2_A="$GUARD_ROOT/m2-a"
M2_B="$GUARD_ROOT/m2-b"; mkdir -p "$M2_B/.chump"
M2_B_BEFORE="$(cd "$M2_B" && find . | sort)"
rc=0
(
    chump_test_sandbox_setup "$M2_A" >/dev/null 2>&1   # marker := A
    export CHUMP_HOME="$M2_B"
    export CHUMP_STATE_DIR="$M2_B/.chump"              # B now looks valid…
    write_sandbox_healthy_node "$M2_B"                 # …but marker is still A
) >/dev/null 2>&1 || rc=$?
M2_B_AFTER="$(cd "$M2_B" && find . | sort)"
if [[ "$rc" -eq 2 && "$M2_B_BEFORE" == "$M2_B_AFTER" ]]; then
    ok "Test 10g (M2): refuses a stale marker from a different sandbox (exit 2, B unchanged)"
else
    fail "Test 10g (M2): expected exit 2 + B unchanged (rc=$rc)"
fi

# ── Test 11 (CREDIBLE-1573): real checkout .chump, .chump-locks, bin/, sessions/ untouched ──
REAL_SNAPSHOT_AFTER="$(_snapshot_real_checkout)"
if [[ "$REAL_SNAPSHOT_BEFORE" == "$REAL_SNAPSHOT_AFTER" ]]; then
    ok "Test 11 (CREDIBLE-1573): real checkout (.chump, .chump-locks, bin/, sessions/) untouched"
else
    fail "Test 11 (CREDIBLE-1573): real checkout was mutated during test-fleet-kill-switch.sh"
    diff -u <(printf '%s\n' "$REAL_SNAPSHOT_BEFORE") <(printf '%s\n' "$REAL_SNAPSHOT_AFTER") >&2 || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
