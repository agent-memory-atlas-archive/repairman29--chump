#!/usr/bin/env bash
# test-fleet-starve-auto-action.sh — INFRA-391 regression test.
#
# Verifies the three modes wired into worker.sh's starvation path:
#   default   — emits suggestion to ambient + log, continues looping
#   auto-relax (CHUMP_STARVE_AUTO_RELAX=1) — applies suggested filter in-place
#   auto-shutdown (CHUMP_STARVE_AUTO_SHUTDOWN=1) — exits cleanly with rc=0
#
# Strategy: invoke worker.sh with `chump` and `gh` stubbed on PATH so it
# always returns "no pickable gap", short IDLE_SLEEP_S so cycles run
# quickly, low CHUMP_STARVE_THRESHOLD=1 so starvation triggers on first
# empty pick. Capture log output and the ambient.jsonl event, assert
# expected behavior per mode.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -x "$WORKER" ]] || { echo "[FAIL] worker.sh not executable"; exit 1; }

# macOS ships with `gtimeout` (brew coreutils); ubuntu-latest has `timeout`.
# Pick whichever exists; skip cleanly if neither is available.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v gtimeout)"
else
    echo "[SKIP] neither timeout nor gtimeout found — install brew coreutils on macOS"
    exit 0
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Stub `chump` to return an empty gap list (forces starvation).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "gap list --status open --json") echo "[]" ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/chump"

# Stub git so worker.sh's pre-loop git fetch doesn't actually hit a remote.
# (We let the real git through for everything else via `command -p git`
# fallback, since the worker uses git for many things; simpler to just
# skip the git fetch step by stubbing `git fetch` only.)
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "fetch" ]]; then exit 0; fi
exec /usr/bin/git "$@"
STUB
chmod +x "$TMP/bin/git"

# Skip chump-doctor by stubbing it (it's at scripts/dev/chump-binary-unwedge.sh
# which the worker invokes by absolute path; stub via PATH wouldn't work,
# so write a sentinel that gets mounted into a fake REPO_ROOT below).

# Use a fake REPO_ROOT that has a stub chump-binary-unwedge.sh.
FAKE_ROOT="$TMP/fake-repo"
mkdir -p "$FAKE_ROOT/scripts/dev" "$FAKE_ROOT/scripts/dispatch" "$FAKE_ROOT/.chump-locks"
cat > "$FAKE_ROOT/scripts/dev/chump-binary-unwedge.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_ROOT/scripts/dev/chump-binary-unwedge.sh"
# _pick_gap.py needs to be present + always print empty (no candidates).
cat > "$FAKE_ROOT/scripts/dispatch/_pick_gap.py" <<'STUB'
#!/usr/bin/env python3
# Test stub: always returns empty (no pickable gap → triggers starvation).
import sys
sys.exit(0)
STUB
chmod +x "$FAKE_ROOT/scripts/dispatch/_pick_gap.py"

# Pre-init git so the worker.sh's `git fetch origin main` doesn't blow up
# (with our stub this is a no-op, but the worker also reads symbolic-ref).
( cd "$FAKE_ROOT" && /usr/bin/git init -q && /usr/bin/git config user.email t@t \
  && /usr/bin/git config user.name t && touch x && /usr/bin/git add x \
  && /usr/bin/git commit -qm "v0" )

run_worker() {
    # `$@` may be empty; guard with ${array[@]+"${array[@]}"} so set -u
    # doesn't fire on bash 3.2/4.x edge cases when there are no extra
    # env vars. Each "$@" entry should be a literal "KEY=VAL" string
    # consumed by `env`.
    local out_file="$TMP/worker-out.log"
    local amb_file="$FAKE_ROOT/.chump-locks/ambient.jsonl"
    : > "$amb_file"
    : > "$out_file"

    # RESILIENT-073: worker.sh now checks ~/.chump/AUTONOMY_LEVEL as the
    # FIRST step of each cycle and bails (fail-closed) if missing/zero.
    # This starve test must set up a fake HOME with AUTONOMY_LEVEL=5 so
    # the kill switch doesn't fire before the starve detection runs.
    local fake_home="$TMP/fake-home"
    mkdir -p "$fake_home/.chump"
    echo "5" > "$fake_home/.chump/AUTONOMY_LEVEL"

    set +e
    # RESILIENT-1591 contract: worker.sh now REFUSES to default to the free-tier
    # floor (exit 78) with no sub auth AND no explicit backend ("we don't ship
    # with free"). This fake HOME has no auth, so opt into an explicit non-ship
    # sweep backend (chump-local, honored by the guard) to exercise the STARVE
    # path this test is actually about, not the auth-refusal guard.
    env PATH="$TMP/bin:/usr/bin:/bin" \
        HOME="$fake_home" \
        AGENT_ID="9" \
        REPO_ROOT="$FAKE_ROOT" \
        FLEET_BACKEND="chump-local" \
        FLEET_LOG_DIR="$TMP/fleet-logs" \
        IDLE_SLEEP_S="1" \
        CHUMP_POLL_JITTER="0" \
        CHUMP_STARVE_THRESHOLD="1" \
        CHUMP_AMBIENT_LOG="$amb_file" \
        "$@" \
        "$TIMEOUT_BIN" 5 bash "$WORKER" >"$out_file" 2>&1
    local rc=$?
    set -e
    echo "$rc|$out_file|$amb_file"
}

# ── Test 1: default mode — emits suggestion, continues looping ───────────
echo "Test 1: default — emits suggestion, continues (timeout)"
result=$(run_worker)
IFS='|' read -r rc out amb <<< "$result"
# Worker should NOT have exited cleanly on its own; timeout (rc=124) means it kept looping.
if [[ $rc -ne 124 ]]; then
    echo "[FAIL] expected timeout (rc=124, worker kept looping), got rc=$rc"
    cat "$out"
    exit 1
fi
if ! grep -q "ALERT kind=fleet_starved" "$out"; then
    echo "[FAIL] no fleet_starved log line"
    cat "$out"
    exit 1
fi
if ! grep -q '"event":"fleet_starved"' "$amb" || ! grep -q '"suggest":' "$amb"; then
    echo "[FAIL] ambient event missing or no suggest field"
    cat "$amb"
    exit 1
fi
if ! grep -q "INFRA-391: auto-" "$out" && grep -q "auto-relax" "$out"; then
    echo "[FAIL] default mode shouldn't have auto-relaxed"
    exit 1
fi
echo "[PASS]"

# ── Test 2: auto-relax — applies suggested filter ────────────────────────
echo ""
echo "Test 2: CHUMP_STARVE_AUTO_RELAX=1 — applies suggested filter in-place"
result=$(run_worker CHUMP_STARVE_AUTO_RELAX=1 FLEET_DOMAIN_FILTER="INFRA")
IFS='|' read -r rc out amb <<< "$result"
[[ $rc -eq 124 ]] || { echo "[FAIL] expected timeout (still looping), got rc=$rc"; cat "$out"; exit 1; }
if ! grep -q "INFRA-391: auto-relaxed" "$out"; then
    echo "[FAIL] no auto-relax log line"
    cat "$out"
    exit 1
fi
if ! grep -q "drop FLEET_DOMAIN_FILTER" "$out"; then
    echo "[FAIL] suggested action wasn't 'drop FLEET_DOMAIN_FILTER' as expected"
    cat "$out"
    exit 1
fi
echo "[PASS]"

# ── Test 3: auto-shutdown — exits cleanly with rc=0 ──────────────────────
echo ""
echo "Test 3: CHUMP_STARVE_AUTO_SHUTDOWN=1 — exits clean rc=0"
result=$(run_worker CHUMP_STARVE_AUTO_SHUTDOWN=1)
IFS='|' read -r rc out amb <<< "$result"
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected rc=0 (auto-shutdown), got rc=$rc"
    cat "$out"
    exit 1
fi
if ! grep -q "INFRA-391: auto-shutdown" "$out"; then
    echo "[FAIL] no auto-shutdown log line"
    cat "$out"
    exit 1
fi
echo "[PASS]"

echo ""
echo "[OK] all 3 INFRA-391 starve-action modes work"
