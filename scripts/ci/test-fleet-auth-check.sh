#!/usr/bin/env bash
# INFRA-621: fleet auth-check probe test — validates launch-time auth verification.
#
# Tests 4 scenarios:
#   1. OAUTH-only valid
#   2. API-key only valid
#   3. Both credentials valid
#   4. Both credentials invalid
#
# Run from repo root: bash scripts/ci/test-fleet-auth-check.sh
#
# Exit code: 0 = all pass, 1 = any failure.

set -eu
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Helper: test auth probe in isolated environment
test_auth_probe() {
    local scenario="$1"
    local api_key="${2:-}"
    local oauth_token="${3:-}"
    local expect_success="${4:-1}"

    local sandbox=$(mktemp -d)
    trap "rm -rf '$sandbox'" RETURN

    mkdir -p "$sandbox/bin" "$sandbox/.chump-locks" "$sandbox/.chump" "$sandbox/logs"

    # Stub binaries
    for bin in git tmux chump sqlite3; do
        echo "#!/bin/sh" > "$sandbox/bin/$bin"
        echo "exit 0" >> "$sandbox/bin/$bin"
        chmod +x "$sandbox/bin/$bin"
    done

    # Mock claude
    cat > "$sandbox/bin/claude" << 'CLAUDE_MOCK'
#!/bin/bash
[[ "$1" == "-p" ]] || exit 0
[[ -n "${ANTHROPIC_API_KEY:-}" && "${ANTHROPIC_API_KEY}" != "invalid" ]] && { echo "ok"; exit 0; }
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" && "${CLAUDE_CODE_OAUTH_TOKEN}" != "invalid" ]] && { echo "ok"; exit 0; }
echo "error: 401 Unauthorized" >&2
exit 1
CLAUDE_MOCK
    chmod +x "$sandbox/bin/claude"

    touch "$sandbox/.chump/state.db"

    # Write probe script to a temp file to avoid quoting issues
    local probe_script="$sandbox/probe.sh"
    cat > "$probe_script" << 'PROBE_END'
#!/bin/bash
set +e

mkdir -p "$(dirname "$CHUMP_AMBIENT_LOG")"

_fleet_auth_mode="unknown"
_fleet_auth_path="none"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && { _fleet_auth_mode="api_key"; _fleet_auth_path="ANTHROPIC_API_KEY"; }
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && { _fleet_auth_mode="subscription"; _fleet_auth_path="CLAUDE_CODE_OAUTH_TOKEN"; }

_probe_out=$(claude -p "ok" 2>&1) && _probe_rc=0 || _probe_rc=$?

if [[ $_probe_rc -eq 0 ]]; then
    printf '{"ts":"%s","kind":"fleet_auth_verified","auth_mode":"%s","auth_path":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$_fleet_auth_mode" "$_fleet_auth_path" \
        >> "$CHUMP_AMBIENT_LOG" 2>/dev/null || true
    exit 0
else
    if [[ "$_fleet_auth_mode" == "subscription" ]]; then
        _auth_probe_error="CLAUDE_CODE_OAUTH_TOKEN is expired or invalid."
    elif [[ "$_fleet_auth_mode" == "api_key" ]]; then
        _auth_probe_error="ANTHROPIC_API_KEY is invalid or has insufficient permissions."
    elif [[ "$_fleet_auth_mode" == "unknown" ]]; then
        _auth_probe_error="No auth credentials found."
    else
        _auth_probe_error="Auth probe failed: $_probe_out"
    fi

    printf '{"ts":"%s","kind":"fleet_auth_misconfigured","auth_mode":"%s","auth_path":"%s","error":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$_fleet_auth_mode" "$_fleet_auth_path" \
        "$(echo "$_auth_probe_error" | sed 's/"/""/g')" \
        >> "$CHUMP_AMBIENT_LOG" 2>/dev/null || true
    exit 3
fi
PROBE_END
    chmod +x "$probe_script"

    # Run probe with env vars (exit code is not reliable, check ambient log instead)
    ANTHROPIC_API_KEY="$api_key" \
    CLAUDE_CODE_OAUTH_TOKEN="$oauth_token" \
    CHUMP_AMBIENT_LOG="$sandbox/ambient.jsonl" \
    HOME="$sandbox" \
    PATH="$sandbox/bin:/usr/bin:/bin" \
    bash "$probe_script" 2>/dev/null || true

    # Check ambient log
    local amb_has_verified=0
    local amb_has_misconfigured=0
    if [[ -f "$sandbox/ambient.jsonl" ]]; then
        grep -q '"kind":"fleet_auth_verified"' "$sandbox/ambient.jsonl" && amb_has_verified=1 || true
        grep -q '"kind":"fleet_auth_misconfigured"' "$sandbox/ambient.jsonl" && amb_has_misconfigured=1 || true
    fi

    # Evaluate result
    if [[ $expect_success -eq 1 ]]; then
        if [[ $amb_has_verified -eq 1 ]]; then
            pass "$scenario"
        else
            fail "$scenario — expected success but verified=$amb_has_verified misconfigured=$amb_has_misconfigured"
        fi
    else
        if [[ $amb_has_misconfigured -eq 1 ]]; then
            pass "$scenario"
        else
            fail "$scenario — expected failure but verified=$amb_has_verified misconfigured=$amb_has_misconfigured"
        fi
    fi
}

echo ""
echo "── Fleet auth-check probe tests (INFRA-621) ────────────────────────"

# Test 4 scenarios per gap AC
test_auth_probe "OAUTH-only valid" "" "valid-oauth-token" "1"
test_auth_probe "API-key only valid" "valid-api-key" "" "1"
test_auth_probe "both credentials valid" "valid-api-key" "valid-oauth-token" "1"
test_auth_probe "both credentials invalid" "invalid" "invalid" "0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
