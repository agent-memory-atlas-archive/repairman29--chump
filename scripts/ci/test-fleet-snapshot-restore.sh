#!/usr/bin/env bash
# test-fleet-snapshot-restore.sh — INFRA-612
#
# End-to-end tests for `chump fleet snapshot` and `chump fleet restore`.
# Verifies:
#   (a) snapshot writes .chump/restart-snapshots/<ts>.json with leases/ambient/queue
#   (b) snapshot emits fleet_snapshot event to ambient.jsonl
#   (c) restore replays lease files to .chump-locks/
#   (d) restore emits fleet_restore event to ambient.jsonl
#   (e) restore without snapshot-id exits non-zero

set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

# Seed a lease file.
cat > "$FAKE_REPO/.chump-locks/claude-test-session.json" <<'JSON'
{
  "session_id": "claude-test-session",
  "paths": ["src/main.rs"],
  "taken_at": "2026-05-06T10:00:00Z",
  "expires_at": "2026-05-06T10:30:00Z",
  "heartbeat_at": "2026-05-06T10:00:00Z",
  "purpose": "test lease for snapshot",
  "worktree": ".claude/worktrees/test",
  "gap_id": "INFRA-612"
}
JSON

# Seed fleet-desired-size.
echo "3" > "$FAKE_REPO/.chump/fleet-desired-size"

# Seed ambient.jsonl.
printf '{"ts":"2026-05-06T09:55:00Z","kind":"fleet_scale_request","to":3}\n' \
    >> "$FAKE_REPO/.chump-locks/ambient.jsonl"
printf '{"ts":"2026-05-06T09:56:00Z","kind":"gap_shipped","gap_id":"INFRA-611"}\n' \
    >> "$FAKE_REPO/.chump-locks/ambient.jsonl"

_env=(CHUMP_REPO="$FAKE_REPO" HOME="$TMP/home")
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
        echo "  PASS: $label (non-zero as expected)"
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

# ── Test 1: fleet snapshot creates file ───────────────────────────────────────
echo "=== Test 1: chump fleet snapshot writes snapshot file ==="
out1=$(env "${_env[@]}" "$CHUMP_BIN" fleet snapshot 2>&1)
assert_output_contains "snapshot path printed" "restart-snapshots" "$out1"
assert_output_contains "leases count printed" "leases=1" "$out1"

snap_file=$(ls "$FAKE_REPO/.chump/restart-snapshots/"*.json 2>/dev/null | head -1 || true)
if [[ -n "$snap_file" && -f "$snap_file" ]]; then
    echo "  PASS: snapshot file created at $snap_file"
    (( PASS++ )) || true
else
    echo "  FAIL: no snapshot file found in .chump/restart-snapshots/"
    (( FAIL++ )) || true
fi

# ── Test 2: snapshot JSON structure ───────────────────────────────────────────
echo "=== Test 2: snapshot JSON contains expected fields ==="
if [[ -n "$snap_file" ]]; then
    snap_json=$(cat "$snap_file")
    for field in snapshot_id ts fleet_desired_size leases ambient_tail; do
        if echo "$snap_json" | grep -q "\"$field\""; then
            echo "  PASS: field '$field' present"
            (( PASS++ )) || true
        else
            echo "  FAIL: field '$field' missing from snapshot JSON"
            (( FAIL++ )) || true
        fi
    done
    # Verify lease content captured.
    if echo "$snap_json" | grep -q "INFRA-612"; then
        echo "  PASS: lease gap_id captured"
        (( PASS++ )) || true
    else
        echo "  FAIL: lease gap_id not found in snapshot"
        (( FAIL++ )) || true
    fi
    # Verify fleet_desired_size captured (allow pretty-print spacing).
    if echo "$snap_json" | grep -qE '"fleet_desired_size"[[:space:]]*:[[:space:]]*3'; then
        echo "  PASS: fleet_desired_size=3 captured"
        (( PASS++ )) || true
    else
        echo "  FAIL: fleet_desired_size not captured correctly"
        (( FAIL++ )) || true
    fi
fi

# ── Test 3: snapshot emits ambient event ──────────────────────────────────────
echo "=== Test 3: fleet snapshot emits fleet_snapshot ambient event ==="
if grep -q '"kind":"fleet_snapshot"' "$FAKE_REPO/.chump-locks/ambient.jsonl" 2>/dev/null; then
    echo "  PASS: fleet_snapshot event in ambient.jsonl"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet_snapshot event missing from ambient.jsonl"
    (( FAIL++ )) || true
fi

# ── Test 4: fleet restore replays leases ──────────────────────────────────────
echo "=== Test 4: chump fleet restore replays leases ==="
# Remove the original lease to prove restore recreates it.
rm "$FAKE_REPO/.chump-locks/claude-test-session.json"

if [[ -n "$snap_file" ]]; then
    snap_id=$(basename "$snap_file" .json)
    out4=$(env "${_env[@]}" "$CHUMP_BIN" fleet restore "$snap_id" 2>&1)
    assert_output_contains "restore prints replayed count" "leases_replayed=1" "$out4"
    assert_output_contains "restore prints snapshot_id" "$snap_id" "$out4"

    if [[ -f "$FAKE_REPO/.chump-locks/claude-test-session.json" ]]; then
        echo "  PASS: lease file restored"
        (( PASS++ )) || true
    else
        echo "  FAIL: lease file not restored"
        (( FAIL++ )) || true
    fi

    # Verify restored lease is valid JSON with expected content.
    if python3 -c "import json,sys; d=json.load(open('$FAKE_REPO/.chump-locks/claude-test-session.json')); assert d['gap_id']=='INFRA-612'" 2>/dev/null; then
        echo "  PASS: restored lease has correct gap_id"
        (( PASS++ )) || true
    else
        echo "  FAIL: restored lease missing or wrong gap_id"
        (( FAIL++ )) || true
    fi
fi

# ── Test 5: restore emits fleet_restore ambient event ─────────────────────────
echo "=== Test 5: fleet restore emits fleet_restore ambient event ==="
if grep -q '"kind":"fleet_restore"' "$FAKE_REPO/.chump-locks/ambient.jsonl" 2>/dev/null; then
    echo "  PASS: fleet_restore event in ambient.jsonl"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet_restore event missing from ambient.jsonl"
    (( FAIL++ )) || true
fi

# ── Test 6: restore replays fleet-desired-size ────────────────────────────────
echo "=== Test 6: restore replays fleet-desired-size ==="
if grep -q "^3" "$FAKE_REPO/.chump/fleet-desired-size" 2>/dev/null; then
    echo "  PASS: fleet-desired-size restored to 3"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet-desired-size not restored"
    (( FAIL++ )) || true
fi

# ── Test 7: restore via full path ─────────────────────────────────────────────
echo "=== Test 7: chump fleet restore accepts full path ==="
if [[ -n "$snap_file" ]]; then
    out7=$(env "${_env[@]}" "$CHUMP_BIN" fleet restore "$snap_file" 2>&1)
    assert_output_contains "restore via full path succeeds" "leases_replayed" "$out7"
fi

# ── Test 8: restore missing snapshot-id exits non-zero ────────────────────────
echo "=== Test 8: chump fleet restore (no snapshot-id) exits non-zero ==="
assert_fail "missing snapshot-id exits non-zero" \
    env "${_env[@]}" "$CHUMP_BIN" fleet restore

# ── Test 9: restore non-existent snapshot exits non-zero ──────────────────────
echo "=== Test 9: chump fleet restore <bogus-id> exits non-zero ==="
assert_fail "nonexistent snapshot exits non-zero" \
    env "${_env[@]}" "$CHUMP_BIN" fleet restore "99991231-999999"

# ── Test 10: unknown fleet subcommand still exits non-zero ────────────────────
echo "=== Test 10: chump fleet bogus exits non-zero ==="
assert_fail "unknown subcommand exits non-zero" \
    env "${_env[@]}" "$CHUMP_BIN" fleet bogus

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
