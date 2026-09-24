#!/usr/bin/env bash
# scripts/ci/test-resilient-1450-worker-reexec-on-head-change.sh — RESILIENT-1450
#
# Proves worker.sh re-execs itself at a cycle boundary when the tracked
# worker.sh HEAD moves under it, instead of running the merged-not-running
# gap: node-converge (RESILIENT-1189) hard-resets $REPO_ROOT to origin/main
# every ~10min but NEVER restarts the already-running worker process, so a
# merged worker.sh fix sat on disk while the worker kept executing stale code
# (observed: #4815/RESILIENT-1449 fix was inert for a day until a manual
# restart).
#
# Extracts the real _check_worker_head_reexec function (RESILIENT-1450 marker
# comment through its closing brace) straight out of scripts/dispatch/worker.sh
# and exercises it against a throwaway git repo, so this test FAILS if the
# function is reverted/renamed/removed — it does not hand-roll a duplicate
# implementation.

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -f "$WORKER_SH" ]] || { echo "FAIL: worker.sh missing: $WORKER_SH"; exit 1; }
bash -n "$WORKER_SH" || { echo "FAIL: worker.sh bash -n"; exit 1; }

FUNC_SNIPPET="$(sed -n '/^_check_worker_head_reexec() {/,/^}$/p' "$WORKER_SH")"
if [[ -z "$FUNC_SNIPPET" ]] || ! grep -q '_check_worker_head_reexec()' <<<"$FUNC_SNIPPET"; then
    echo "FAIL: could not extract _check_worker_head_reexec from worker.sh — RESILIENT-1450 fix missing/renamed"
    exit 1
fi
ok "extracted _check_worker_head_reexec verbatim from worker.sh"

# Also require the wiring call inside the main loop, right at the cycle
# boundary (before any gap-claim work happens for the cycle).
if ! grep -A3 '^while :; do' "$WORKER_SH" | grep -q '_check_worker_head_reexec'; then
    fail "worker.sh main loop does not call _check_worker_head_reexec at the cycle boundary"
else
    ok "worker.sh main loop calls _check_worker_head_reexec right after cycle increment"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1450.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts/dispatch"
git -C "$TMP" init -q
git -C "$TMP" config user.email test@test.com
git -C "$TMP" config user.name test

# Fake worker.sh: what the re-exec should land on. If it runs, it proves the
# self-restart actually happened (not just logged).
cat > "$TMP/scripts/dispatch/worker.sh" <<'EOF'
#!/usr/bin/env bash
touch "$TMP_MARKER"
EOF
chmod +x "$TMP/scripts/dispatch/worker.sh"
git -C "$TMP" add -A
git -C "$TMP" commit -q -m "initial"

# Test harness: mirrors exactly how worker.sh drives this — _WORKER_START_SHA
# is captured ONCE (at process start, before any node-converge reset could
# happen), then _check_worker_head_reexec is called on a later cycle and
# re-reads the live HEAD itself.
run_check() {  # -> writes ambient.jsonl + optionally touches TMP_MARKER
    local start_sha="$1" reexec_env="$2"
    cat > "$TMP/harness.sh" <<HARNESS
set -uo pipefail
REPO_ROOT="$TMP"
AGENT_ID="test-agent"
CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
CHUMP_WORKER_HEAD_REEXEC="$reexec_env"
_WORKER_START_SHA="$start_sha"
log() { :; }
$FUNC_SNIPPET
_check_worker_head_reexec
HARNESS
    TMP_MARKER="$TMP/reexec-happened" bash "$TMP/harness.sh"
}

START_SHA="$(git -C "$TMP" rev-parse HEAD)"

# ── 1. HEAD unchanged: no re-exec, no ambient event ─────────────────────────
rm -f "$TMP/reexec-happened" "$TMP/ambient.jsonl"
run_check "$START_SHA" 1
if [[ -e "$TMP/reexec-happened" ]]; then
    fail "re-exec fired with unchanged HEAD (should be a no-op)"
else
    ok "unchanged HEAD: no re-exec"
fi
if [[ -s "$TMP/ambient.jsonl" ]]; then
    fail "ambient event emitted with unchanged HEAD"
else
    ok "unchanged HEAD: no ambient event"
fi

# ── 2. HEAD moves (simulating node-converge's hard reset): re-exec fires ────
# The worker process itself never made this commit — node-converge did, out
# from under it — so START_SHA (captured at process start) stays fixed while
# HEAD advances underneath.
echo "changed" > "$TMP/scripts/dispatch/worker.sh.marker"
git -C "$TMP" add -A
git -C "$TMP" commit -q -m "simulated node-converge pull of a new worker.sh"

rm -f "$TMP/reexec-happened" "$TMP/ambient.jsonl"
run_check "$START_SHA" 1
if [[ -e "$TMP/reexec-happened" ]]; then
    ok "HEAD moved: worker.sh re-exec'd itself (marker file created)"
else
    fail "HEAD moved: worker.sh did NOT re-exec (merged-not-running bug reproduced)"
fi
if grep -q '"kind":"worker_reexec_on_head_change"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "HEAD moved: emitted kind=worker_reexec_on_head_change to ambient"
else
    fail "HEAD moved: no worker_reexec_on_head_change ambient event"
fi

# ── 3. CHUMP_WORKER_HEAD_REEXEC=0 disables the behavior ─────────────────────
rm -f "$TMP/reexec-happened" "$TMP/ambient.jsonl"
run_check "$START_SHA" 0
if [[ -e "$TMP/reexec-happened" ]]; then
    fail "re-exec fired despite CHUMP_WORKER_HEAD_REEXEC=0"
else
    ok "CHUMP_WORKER_HEAD_REEXEC=0 disables the re-exec"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: RESILIENT-1450 worker re-exec-on-HEAD-change holds ($PASS checks)"
    exit 0
else
    echo "FAIL: $FAIL check(s) failed ($0)"
    exit 1
fi
