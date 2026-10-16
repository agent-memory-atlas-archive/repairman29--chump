#!/bin/bash
# INFRA-1570: test /api/settings/repo GET and PUT handlers.
# Writes settings via PUT and reads them back via GET, asserting roundtrip equality.

set -e

REPO_ROOT="${CHUMP_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO_ROOT"

# Start the web server in background if not already running
if ! pgrep -f "chump --web" > /dev/null 2>&1; then
    PORT=9999 cargo run --bin chump --release -- --web > /tmp/chump_web_test.log 2>&1 &
    WEB_PID=$!
    sleep 2
    trap "kill $WEB_PID 2>/dev/null || true" EXIT
fi

WEB_URL="http://localhost:9999"
AUTH_HEADER="Authorization: Bearer test-token"

echo "Testing /api/settings/repo GET (default repo settings)"
GET_RESPONSE=$(curl -s -H "$AUTH_HEADER" "$WEB_URL/api/settings/repo")
echo "GET Response: $GET_RESPONSE"

# Parse the response
REPO_PATH=$(echo "$GET_RESPONSE" | jq -r '.repo_path // empty')
PRIORITY=$(echo "$GET_RESPONSE" | jq -r '.default_priority_filter // empty')
EFFORT=$(echo "$GET_RESPONSE" | jq -r '.default_effort_filter // empty')
BRANCHES=$(echo "$GET_RESPONSE" | jq -r '.watched_branches | @json' | sed 's/^"//;s/"$//')

if [ -z "$REPO_PATH" ] || [ -z "$PRIORITY" ] || [ -z "$EFFORT" ]; then
    echo "ERROR: Failed to parse GET response"
    exit 1
fi

echo "✓ GET returned valid repo settings"
echo "  repo_path: $REPO_PATH"
echo "  default_priority_filter: $PRIORITY"
echo "  default_effort_filter: $EFFORT"
echo "  watched_branches: $BRANCHES"

# Test PUT with new settings
echo ""
echo "Testing /api/settings/repo PUT (update settings)"
PUT_PAYLOAD=$(cat <<'EOF'
{
  "watched_branches": ["main", "develop", "staging"],
  "default_priority_filter": "P1",
  "default_effort_filter": "m"
}
EOF
)

PUT_RESPONSE=$(curl -s -X PUT -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "$PUT_PAYLOAD" "$WEB_URL/api/settings/repo")
echo "PUT Response: $PUT_RESPONSE"

PUT_OK=$(echo "$PUT_RESPONSE" | jq -r '.ok // empty')
if [ "$PUT_OK" != "true" ]; then
    echo "ERROR: PUT did not return ok:true"
    exit 1
fi

echo "✓ PUT succeeded"

# Read back the settings to verify roundtrip
echo ""
echo "Testing roundtrip: GET after PUT"
ROUNDTRIP=$(curl -s -H "$AUTH_HEADER" "$WEB_URL/api/settings/repo")
echo "Roundtrip Response: $ROUNDTRIP"

NEW_PRIORITY=$(echo "$ROUNDTRIP" | jq -r '.default_priority_filter // empty')
NEW_EFFORT=$(echo "$ROUNDTRIP" | jq -r '.default_effort_filter // empty')
NEW_BRANCHES=$(echo "$ROUNDTRIP" | jq -r '.watched_branches | length')

if [ "$NEW_PRIORITY" != "P1" ]; then
    echo "ERROR: priority filter roundtrip failed (expected P1, got $NEW_PRIORITY)"
    exit 1
fi

if [ "$NEW_EFFORT" != "m" ]; then
    echo "ERROR: effort filter roundtrip failed (expected m, got $NEW_EFFORT)"
    exit 1
fi

if [ "$NEW_BRANCHES" != "3" ]; then
    echo "ERROR: watched_branches roundtrip failed (expected 3, got $NEW_BRANCHES)"
    exit 1
fi

echo "✓ Roundtrip equality check passed"
echo "  default_priority_filter: $NEW_PRIORITY (expected P1)"
echo "  default_effort_filter: $NEW_EFFORT (expected m)"
echo "  watched_branches count: $NEW_BRANCHES (expected 3)"

echo ""
echo "All tests passed ✓"
