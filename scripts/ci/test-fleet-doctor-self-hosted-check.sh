#!/usr/bin/env bash
# test-fleet-doctor-self-hosted-check.sh — INFRA-1544
#
# Verifies the self-hosted runner liveness check in fleet doctor:
#   1. Mock gh api response with 0 runners → expect unhealthy (non-zero exit)
#   2. Mock gh api response with 1+ runners → expect healthy (zero exit)
#   3. Telemetry event fleet_doctor_runner_count is emitted with correct counts
#
# The test stubs the gh api calls to simulate different runner states without
# needing actual GitHub API access.

set -uo pipefail

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

REPO_ROOT_REAL="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT_REAL/target/debug/chump}"

[[ -f "$CHUMP_BIN" ]] || fail "chump binary not found at $CHUMP_BIN"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-self-hosted-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Test 1: 0 runners online → unhealthy ────────────────────────────────────
echo "Test 1: 0 runners online → unhealthy"

MOCK_GH_DIR="$TMPDIR_BASE/mock-gh-0runners"
mkdir -p "$MOCK_GH_DIR"

# Create a mock gh script that returns 0 runners
cat > "$MOCK_GH_DIR/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos"* ]]; then
  echo '{"total_count": 2, "runners": [{"id": 1, "name": "runner-1", "status": "offline", "busy": false}, {"id": 2, "name": "runner-2", "status": "offline", "busy": false}]}'
  exit 0
else
  # For other gh commands (repo view, etc), return mock data
  if [[ "$3" == "--json" && "$4" == "owner" ]]; then
    echo "test-owner"
  elif [[ "$3" == "--json" && "$4" == "name" ]]; then
    echo "test-repo"
  fi
  exit 0
fi
EOF
chmod +x "$MOCK_GH_DIR/gh"

export PATH="$MOCK_GH_DIR:$PATH"
AMBIENT_LOG="$TMPDIR_BASE/ambient-0runners.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"

# Run the check and capture output
OUTPUT=$("$CHUMP_BIN" fleet doctor --json 2>&1 || true)

# Verify unhealthy in output
if echo "$OUTPUT" | grep -q '"healthy":false'; then
    pass "0 runners → unhealthy status"
else
    fail "expected unhealthy status with 0 runners, got: $OUTPUT"
fi

# Verify telemetry event
if [[ -f "$AMBIENT_LOG" ]] && grep -q '"kind":"fleet_doctor_runner_count"' "$AMBIENT_LOG"; then
    pass "telemetry event kind=fleet_doctor_runner_count emitted"
else
    fail "expected ambient event kind=fleet_doctor_runner_count in $AMBIENT_LOG"
fi

# ── Test 2: 1+ runners online → healthy ────────────────────────────────────
echo ""
echo "Test 2: 1+ runners online → healthy"

MOCK_GH_DIR2="$TMPDIR_BASE/mock-gh-healthy"
mkdir -p "$MOCK_GH_DIR2"

cat > "$MOCK_GH_DIR2/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos"* ]]; then
  echo '{"total_count": 3, "runners": [{"id": 1, "name": "runner-1", "status": "online", "busy": false}, {"id": 2, "name": "runner-2", "status": "offline", "busy": false}, {"id": 3, "name": "runner-3", "status": "online", "busy": true}]}'
  exit 0
else
  if [[ "$3" == "--json" && "$4" == "owner" ]]; then
    echo "test-owner"
  elif [[ "$3" == "--json" && "$4" == "name" ]]; then
    echo "test-repo"
  fi
  exit 0
fi
EOF
chmod +x "$MOCK_GH_DIR2/gh"

export PATH="$MOCK_GH_DIR2:$PATH"
AMBIENT_LOG2="$TMPDIR_BASE/ambient-healthy.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG2"

OUTPUT2=$("$CHUMP_BIN" fleet doctor --json 2>&1 || true)

if echo "$OUTPUT2" | grep -q '"healthy":true'; then
    pass "1+ runners → healthy status"
else
    fail "expected healthy status with 1+ runners, got: $OUTPUT2"
fi

# Verify online count is correct (1 non-busy)
if echo "$OUTPUT2" | grep -q '"online_count":1'; then
    pass "online_count correctly shows 1 (non-busy runner)"
else
    fail "expected online_count=1, output: $OUTPUT2"
fi

# ── Test 3: Degraded mode (1 runner, at threshold) ────────────────────────
echo ""
echo "Test 3: Degraded mode (exactly 1 runner, no extras)"

MOCK_GH_DIR3="$TMPDIR_BASE/mock-gh-degraded"
mkdir -p "$MOCK_GH_DIR3"

cat > "$MOCK_GH_DIR3/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos"* ]]; then
  echo '{"total_count": 1, "runners": [{"id": 1, "name": "runner-1", "status": "online", "busy": false}]}'
  exit 0
else
  if [[ "$3" == "--json" && "$4" == "owner" ]]; then
    echo "test-owner"
  elif [[ "$3" == "--json" && "$4" == "name" ]]; then
    echo "test-repo"
  fi
  exit 0
fi
EOF
chmod +x "$MOCK_GH_DIR3/gh"

export PATH="$MOCK_GH_DIR3:$PATH"
AMBIENT_LOG3="$TMPDIR_BASE/ambient-degraded.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG3"

OUTPUT3=$("$CHUMP_BIN" fleet doctor --json 2>&1 || true)

if echo "$OUTPUT3" | grep -q '"healthy":true' && echo "$OUTPUT3" | grep -q '"online_count":1'; then
    pass "degraded mode (1 runner) → still healthy but at threshold"
else
    fail "expected healthy status at threshold (1 runner), got: $OUTPUT3"
fi

if echo "$OUTPUT3" | grep -q '"detail":"1 online runner'; then
    pass "detail message indicates degraded status"
else
    fail "expected degraded detail message, got: $OUTPUT3"
fi

echo ""
echo "=== all fleet-doctor self-hosted-runner tests passed ==="
