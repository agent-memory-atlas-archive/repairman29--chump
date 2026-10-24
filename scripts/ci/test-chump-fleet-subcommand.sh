#!/usr/bin/env bash
# test-chump-fleet-subcommand.sh — INFRA-596
#
# End-to-end test for `chump fleet <start|stop|status|scale>`.
# Stubs run-fleet.sh and fleet-status.sh so no real tmux or API calls happen.
# Verifies that:
#   (a) `chump fleet start` passes FLEET_SIZE/FLEET_MODEL/FLEET_EFFORT_FILTER to run-fleet.sh
#   (b) `chump fleet stop` sets FLEET_SIZE=0 and invokes run-fleet.sh
#   (c) `chump fleet status` calls fleet-status.sh --once (plain) or --json
#   (d) `chump fleet scale N` writes .chump/fleet-desired-size and emits ambient event
#   (e) bad/missing args exit non-zero with usage line

set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Locate the chump binary — prefer a freshly-built debug binary.
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    for candidate in \
        "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" \
        "$REPO_ROOT/target/release/chump" \
        "$(command -v chump 2>/dev/null || true)"
    do
        if [[ -x "$candidate" ]]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found (run 'cargo build' first or set CHUMP_BIN=...)" >&2
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fake repo layout ──────────────────────────────────────────────────────────
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/scripts/dispatch"
mkdir -p "$FAKE_REPO/.chump-locks"
mkdir -p "$FAKE_REPO/.chump"
# Minimal git repo so repo_path::repo_root() won't fall through to cwd.
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" commit --allow-empty -q -m "init"

# ── Stub run-fleet.sh ─────────────────────────────────────────────────────────
# Writes received env vars to $TMP/run-fleet-calls for assertion and exits 0.
cat > "$FAKE_REPO/scripts/dispatch/run-fleet.sh" <<'SH'
#!/usr/bin/env bash
echo "run-fleet FLEET_SIZE=${FLEET_SIZE:-} FLEET_MODEL=${FLEET_MODEL:-} FLEET_EFFORT_FILTER=${FLEET_EFFORT_FILTER:-} FLEET_DOMAIN_FILTER=${FLEET_DOMAIN_FILTER:-} FLEET_SESSION=${FLEET_SESSION:-}"
SH
chmod +x "$FAKE_REPO/scripts/dispatch/run-fleet.sh"

# ── Stub fleet-status.sh ──────────────────────────────────────────────────────
cat > "$FAKE_REPO/scripts/dispatch/fleet-status.sh" <<'SH'
#!/usr/bin/env bash
echo "fleet-status args=$*"
SH
chmod +x "$FAKE_REPO/scripts/dispatch/fleet-status.sh"

# Common env: point chump at the fake repo, suppress dotenv loading.
_env=(
    CHUMP_REPO="$FAKE_REPO"
    HOME="$TMP/home"
)
mkdir -p "$TMP/home/.chump"

PASS=0
FAIL=0

assert_pass() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $label"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label (expected exit 0)"
        (( FAIL++ )) || true
    fi
}

assert_fail() {
    local label="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        echo "  PASS: $label (non-zero exit as expected)"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label (expected non-zero exit)"
        (( FAIL++ )) || true
    fi
}

assert_output_contains() {
    local label="$1"
    local pattern="$2"
    local actual="$3"
    if echo "$actual" | grep -qF "$pattern"; then
        echo "  PASS: $label"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label — expected '$pattern' in:"
        echo "$actual" | sed 's/^/    /'
        (( FAIL++ )) || true
    fi
}

# ── Test 1: fleet start — default size=2, passes env vars ────────────────────
echo "=== Test 1: chump fleet start (default --size 2) ==="
out=$(env "${_env[@]}" "$CHUMP_BIN" fleet start 2>&1 || true)
assert_output_contains "FLEET_SIZE=2 passed to run-fleet.sh" "FLEET_SIZE=2" "$out"
assert_output_contains "FLEET_MODEL=sonnet passed" "FLEET_MODEL=sonnet" "$out"
assert_output_contains "FLEET_EFFORT_FILTER=xs,s,m passed" "FLEET_EFFORT_FILTER=xs,s,m" "$out"

# ── Test 2: fleet start --size 3 --model haiku --domain INFRA ────────────────
echo "=== Test 2: chump fleet start --size 3 --model haiku --domain INFRA ==="
out2=$(env "${_env[@]}" "$CHUMP_BIN" fleet start --size 3 --model haiku --domain INFRA 2>&1 || true)
assert_output_contains "FLEET_SIZE=3 passed" "FLEET_SIZE=3" "$out2"
assert_output_contains "FLEET_MODEL=haiku passed" "FLEET_MODEL=haiku" "$out2"
assert_output_contains "FLEET_DOMAIN_FILTER=INFRA passed" "FLEET_DOMAIN_FILTER=INFRA" "$out2"

# ── Test 3: fleet stop — sets FLEET_SIZE=0 ───────────────────────────────────
echo "=== Test 3: chump fleet stop ==="
out3=$(env "${_env[@]}" "$CHUMP_BIN" fleet stop 2>&1 || true)
assert_output_contains "FLEET_SIZE=0 for stop" "FLEET_SIZE=0" "$out3"

# ── Test 4: fleet status (plain) — calls fleet-status.sh --once ──────────────
echo "=== Test 4: chump fleet status (plain) ==="
out4=$(env "${_env[@]}" "$CHUMP_BIN" fleet status 2>&1 || true)
assert_output_contains "fleet-status.sh called with --once" "--once" "$out4"

# ── Test 5: fleet status --json — calls fleet-status.sh --json ───────────────
echo "=== Test 5: chump fleet status --json ==="
out5=$(env "${_env[@]}" "$CHUMP_BIN" fleet status --json 2>&1 || true)
assert_output_contains "fleet-status.sh called with --json" "--json" "$out5"

# ── Test 6: fleet scale N — writes desired-size file + ambient event ─────────
echo "=== Test 6: chump fleet scale 2 ==="
out6=$(env "${_env[@]}" "$CHUMP_BIN" fleet scale 2 2>&1 || true)
assert_output_contains "scale prints desired size" "desired=2" "$out6"

desired_file="$FAKE_REPO/.chump/fleet-desired-size"
if [[ -f "$desired_file" ]] && grep -q "^2" "$desired_file"; then
    echo "  PASS: fleet-desired-size written"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet-desired-size not written or wrong content"
    (( FAIL++ )) || true
fi

ambient="$FAKE_REPO/.chump-locks/ambient.jsonl"
if [[ -f "$ambient" ]] && grep -q '"kind":"fleet_scale_request"' "$ambient"; then
    echo "  PASS: fleet_scale_request event emitted to ambient.jsonl"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet_scale_request event missing from ambient.jsonl"
    (( FAIL++ )) || true
fi

# ── Test 7: fleet scale — missing N exits non-zero ───────────────────────────
echo "=== Test 7: chump fleet scale (no N) exits non-zero ==="
if ! env "${_env[@]}" "$CHUMP_BIN" fleet scale >/dev/null 2>&1; then
    echo "  PASS: missing N exits non-zero"
    (( PASS++ )) || true
else
    echo "  FAIL: expected non-zero for missing N"
    (( FAIL++ )) || true
fi

# ── Test 8: unknown subcommand exits non-zero ─────────────────────────────────
echo "=== Test 8: chump fleet bogus exits non-zero ==="
if ! env "${_env[@]}" "$CHUMP_BIN" fleet bogus >/dev/null 2>&1; then
    echo "  PASS: unknown subcommand exits non-zero"
    (( PASS++ )) || true
else
    echo "  FAIL: expected non-zero for unknown subcommand"
    (( FAIL++ )) || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
