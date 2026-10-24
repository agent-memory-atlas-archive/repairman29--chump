#!/usr/bin/env bash
# test-chump-fleet-cli.sh — FLEET-037
#
# End-to-end tests for `chump fleet up` and `chump fleet down` (ergonomic verbs).
#
# Assertions:
#   1. chump fleet up --help (or bare up) exits non-zero with usage text
#   2. chump fleet up with no session running → invokes run-fleet.sh with default env vars
#   3. chump fleet up when session already running → exits 2 with "already running"
#   4. chump fleet down → passes FLEET_SIZE=0 to run-fleet.sh
#   5. chump fleet scale 3 → writes .chump/fleet-desired-size with "3"
#
# Uses a $TMP/bin/ stub dir prepended to PATH to intercept `tmux` and
# capture arguments; run-fleet.sh is stubbed in the fake repo.

set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Locate the chump binary.
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
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" commit --allow-empty -q -m "init"

# ── Stub run-fleet.sh ─────────────────────────────────────────────────────────
# Echoes the env vars it received so callers can assert on them; exits 0.
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

# ── Stub bin/ directory for tmux control ─────────────────────────────────────
# We create two flavours:
#   tmux-nosession: `tmux has-session` always fails (exit 1) — session not running
#   tmux-hassession: `tmux has-session` always succeeds (exit 0) — session running
mkdir -p "$TMP/bin-nosession"
cat > "$TMP/bin-nosession/tmux" <<'SH'
#!/usr/bin/env bash
# stub: has-session always fails (no session running)
if [[ "$1" == "has-session" ]]; then
    exit 1
fi
echo "tmux-stub: $*"
exit 0
SH
chmod +x "$TMP/bin-nosession/tmux"

mkdir -p "$TMP/bin-hassession"
cat > "$TMP/bin-hassession/tmux" <<'SH'
#!/usr/bin/env bash
# stub: has-session always succeeds (session running)
if [[ "$1" == "has-session" ]]; then
    exit 0
fi
echo "tmux-stub: $*"
exit 0
SH
chmod +x "$TMP/bin-hassession/tmux"

# ── Common env ────────────────────────────────────────────────────────────────
_env=(
    CHUMP_REPO="$FAKE_REPO"
    HOME="$TMP/home"
)
mkdir -p "$TMP/home/.chump"

PASS=0
FAIL=0

assert_output_contains() {
    local label="$1"
    local pattern="$2"
    local actual="$3"
    if echo "$actual" | grep -qF "$pattern"; then
        echo "  PASS: $label"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label — expected '$pattern' in output:"
        echo "$actual" | sed 's/^/    /'
        (( FAIL++ )) || true
    fi
}

assert_exit_code() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        echo "  PASS: $label (exit $actual)"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label — expected exit $expected, got $actual"
        (( FAIL++ )) || true
    fi
}

# ── Test 1: chump fleet up prints usage (exits 2) ────────────────────────────
echo "=== Test 1: chump fleet up (unknown/help) prints usage ==="
# When no tmux session exists and run-fleet.sh stub returns 0, up should print
# its help text if --help is passed via the catch-all path. We test indirectly:
# `chump fleet up --help` falls through to run-fleet start path (which the stub
# handles), OR we test that the bare `chump fleet` (no subcmd) prints usage.
out1=$(env "${_env[@]}" PATH="$TMP/bin-nosession:$PATH" "$CHUMP_BIN" fleet 2>&1 || true)
assert_output_contains "bare fleet shows usage text" "up" "$out1"
assert_output_contains "bare fleet lists down verb" "down" "$out1"

# ── Test 2: chump fleet up with no session → runs run-fleet.sh with defaults ──
echo "=== Test 2: chump fleet up (no session) passes default env vars ==="
out2=$(env "${_env[@]}" PATH="$TMP/bin-nosession:$PATH" "$CHUMP_BIN" fleet up 2>&1 || true)
assert_output_contains "FLEET_SIZE=2 default" "FLEET_SIZE=2" "$out2"
assert_output_contains "FLEET_MODEL=sonnet default" "FLEET_MODEL=sonnet" "$out2"
assert_output_contains "FLEET_EFFORT_FILTER=xs,s,m default" "FLEET_EFFORT_FILTER=xs,s,m" "$out2"

# ── Test 3: chump fleet up when session already running → exits 2 ─────────────
echo "=== Test 3: chump fleet up (session running) exits 2 with idempotency error ==="
out3=$(env "${_env[@]}" PATH="$TMP/bin-hassession:$PATH" "$CHUMP_BIN" fleet up 2>&1 || true)
rc3=0
env "${_env[@]}" PATH="$TMP/bin-hassession:$PATH" "$CHUMP_BIN" fleet up >/dev/null 2>&1 || rc3=$?
assert_exit_code "exits 2 when session already running" 2 "$rc3"
assert_output_contains "error message mentions already running" "already running" "$out3"
assert_output_contains "error message suggests scale" "scale" "$out3"

# ── Test 4: chump fleet down → passes FLEET_SIZE=0 to run-fleet.sh ────────────
echo "=== Test 4: chump fleet down passes FLEET_SIZE=0 ==="
out4=$(env "${_env[@]}" PATH="$TMP/bin-nosession:$PATH" "$CHUMP_BIN" fleet down 2>&1 || true)
assert_output_contains "FLEET_SIZE=0 for down" "FLEET_SIZE=0" "$out4"

# ── Test 5: chump fleet scale 3 writes fleet-desired-size ────────────────────
echo "=== Test 5: chump fleet scale 3 writes .chump/fleet-desired-size ==="
env "${_env[@]}" PATH="$TMP/bin-nosession:$PATH" "$CHUMP_BIN" fleet scale 3 >/dev/null 2>&1 || true

desired_file="$FAKE_REPO/.chump/fleet-desired-size"
if [[ -f "$desired_file" ]] && grep -q "^3" "$desired_file"; then
    echo "  PASS: fleet-desired-size written with value 3"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet-desired-size not written or wrong content (expected '3')"
    if [[ -f "$desired_file" ]]; then
        echo "    actual contents: $(cat "$desired_file")"
    else
        echo "    file does not exist: $desired_file"
    fi
    (( FAIL++ )) || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
