#!/usr/bin/env bash
# test-chumpd-worker-loop.sh — PHASE-R R6 / INFRA-8575
#
# The per-worker loop control (cadence, heartbeat, fleet-paused sentinel,
# per-tick budget) moved from scripts/dispatch/worker.sh into the
# `chumpd worker` subcommand. This asserts, against a STUB tick body (no real
# fleet), that over two ticks:
#   1. the tick body runs each tick and the heartbeat file is written
#   2. when the fleet-paused sentinel is present the tick body does NOT run,
#      a chumpd_worker_paused event is emitted, and the heartbeat keeps writing
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chumpd"
if [[ ! -x "$BIN" ]]; then
    echo "  [build] cargo build -p chumpd..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build -p chumpd -q) \
        || { echo "FAIL: build"; exit 1; }
fi
[[ -x "$BIN" ]] || BIN="$REPO_ROOT/target/debug/chumpd"

echo "=== INFRA-8575 chumpd worker loop test ==="

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/repo/.chump-locks"
AMBIENT="$FIX/repo/.chump-locks/ambient.jsonl"
HB="$FIX/hb"
PAUSE="$FIX/paused"
TICKLOG="$FIX/ticks.log"

# Stub tick body: records one line per invocation. Byte-trivial so the test is
# about loop CONTROL, not any real worker work.
STUB="$FIX/tick.sh"
printf '#!/usr/bin/env bash\necho tick >> %q\n' "$TICKLOG" > "$STUB"
chmod +x "$STUB"

# ── Part 1: two ticks run the body + write the heartbeat ──────────────────
: > "$TICKLOG"
REPO_ROOT="$FIX/repo" AGENT_ID=7 "$BIN" worker \
    --tick-cmd "bash $STUB" --cadence-secs 0 --max-ticks 2 \
    --pause-file "$PAUSE" --heartbeat-file "$HB" --ambient "$AMBIENT" \
    > "$FIX/run1.log" 2>&1

ran=$(wc -l < "$TICKLOG" 2>/dev/null | tr -d ' ')
if [[ "$ran" == "2" ]]; then ok "tick body ran twice (got $ran)"; else fail "expected 2 ticks, got $ran"; fi

if [[ -f "$HB" ]]; then
    hb_epoch="$(cut -d' ' -f1 "$HB")"
    if [[ "$hb_epoch" =~ ^[0-9]+$ ]] && [[ "$hb_epoch" -gt 0 ]]; then
        ok "heartbeat written with epoch ($hb_epoch)"
    else
        fail "heartbeat epoch malformed: '$hb_epoch'"
    fi
else
    fail "heartbeat file missing"
fi

if grep -q '"kind":"chumpd_worker_loop_started"' "$AMBIENT" \
   && grep -q '"kind":"chumpd_worker_loop_stopped"' "$AMBIENT"; then
    ok "loop start/stop events emitted"
else
    fail "missing loop start/stop events"
fi

# ── Part 2: fleet-paused sentinel blocks the tick body ────────────────────
: > "$TICKLOG"; : > "$AMBIENT"; rm -f "$HB"
: > "$PAUSE"   # raise the sentinel

# cadence 1s so a couple of pause cycles elapse; kill after ~3s.
REPO_ROOT="$FIX/repo" AGENT_ID=7 "$BIN" worker \
    --tick-cmd "bash $STUB" --cadence-secs 1 --max-ticks 0 \
    --pause-file "$PAUSE" --heartbeat-file "$HB" --ambient "$AMBIENT" \
    > "$FIX/run2.log" 2>&1 &
WP=$!
sleep 3
kill "$WP" 2>/dev/null
wait "$WP" 2>/dev/null

paused_ran=$(wc -l < "$TICKLOG" 2>/dev/null | tr -d ' ')
if [[ "${paused_ran:-0}" == "0" ]]; then ok "tick body did NOT run while paused"; else fail "tick body ran $paused_ran times while paused"; fi

pcount=$(grep -c '"kind":"chumpd_worker_paused"' "$AMBIENT" 2>/dev/null | tr -d ' ')
if [[ "${pcount:-0}" -ge 1 ]]; then ok "chumpd_worker_paused emitted ($pcount)"; else fail "no chumpd_worker_paused event"; fi

if [[ -f "$HB" ]] && grep -q 'paused' "$HB"; then
    ok "heartbeat kept writing while paused (worker stays visibly alive)"
else
    fail "heartbeat not written while paused"
fi

# ── Part 3 (INFRA-8582 AC2): worker.sh shim resolves chumpd on a node with no target/ ──
mkdir -p "$FIX/repo/scripts/ci/lib" "$FIX/node/bin" "$FIX/empty-target" "$FIX/home"
cp "$REPO_ROOT/scripts/ci/lib/resolve-cargo-target-dir.sh" "$FIX/repo/scripts/ci/lib/resolve-cargo-target-dir.sh"
rm -rf "$FIX/repo/target"
cat > "$FIX/node/bin/chumpd" <<'EOF'
#!/usr/bin/env bash
echo "stub-chumpd-ran:$*"
exit 0
EOF
chmod +x "$FIX/node/bin/chumpd"
: > "$AMBIENT"
SHIM_OUT="$(REPO_ROOT="$FIX/repo" AGENT_ID=9 CHUMP_NODE_DIR="$FIX/node"     CARGO_TARGET_DIR="$FIX/empty-target" HOME="$FIX/home"     CHUMP_AMBIENT_FILE="$AMBIENT" PATH="/usr/bin:/bin"     bash "$REPO_ROOT/scripts/dispatch/worker.sh" 2>&1)"
if printf '%s\n' "$SHIM_OUT" | grep -q "stub-chumpd-ran:worker"; then
    ok "worker.sh shim resolved chumpd from node bin dir with no target/ directory"
else
    fail "worker.sh shim did not exec node bin chumpd (out: $SHIM_OUT)"
fi
if grep -q '"kind":"worker_loop_backend"' "$AMBIENT" && grep -q '"backend":"rust"' "$AMBIENT"; then
    ok "worker.sh shim emitted kind=worker_loop_backend backend=rust"
else
    fail "worker.sh shim did not emit worker_loop_backend backend=rust"
fi

# ── Part 4 (INFRA-8582 AC3): legacy fallback only when chumpd is truly absent ──
: > "$AMBIENT"
FALLBACK_OUT="$(REPO_ROOT="$FIX/repo" AGENT_ID=9 CHUMPD_BIN="$FIX/no-such-chumpd"     CHUMP_AMBIENT_FILE="$AMBIENT"     timeout 2 bash "$REPO_ROOT/scripts/dispatch/worker.sh" --dry-run 2>&1 || true)"
if printf '%s\n' "$FALLBACK_OUT" | grep -q "chumpd binary truly absent"; then
    ok "worker.sh shim reports when chumpd is truly absent"
else
    fail "worker.sh shim did not report chumpd truly absent (out: $FALLBACK_OUT)"
fi
if grep -q '"kind":"worker_loop_backend"' "$AMBIENT" && grep -q '"backend":"legacy"' "$AMBIENT"; then
    ok "worker.sh shim emitted kind=worker_loop_backend backend=legacy on fallback"
else
    fail "worker.sh shim did not emit worker_loop_backend backend=legacy"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
