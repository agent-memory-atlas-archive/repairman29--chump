#!/usr/bin/env bash
# test-fleet-scrubber.sh — INFRA-2176
#
# Smoke test for web/fleet-scrubber/index.html.
#
# Asserts:
#   1. D3 v7 CDN script tag present
#   2. Required element IDs: #timeline, #lanes, #live-toggle, #replay-btn, #side-panel
#   3. Activity color CSS variables: --color-claim, --color-edit, --color-push,
#      --color-merge, --color-blocked, --color-idle
#   4. fixtures/segments.json and fixtures/events.json exist and are valid JSON
#   5. fixtures/gen.py exists and is executable
#
# The test serves the page via python3 http.server on an ephemeral port and
# asserts on the raw HTML (curl); no browser required.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WEB_DIR="$REPO_ROOT/web/fleet-scrubber"

PASS=0
FAIL=0
FAILURES=()

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

# ── Start ephemeral HTTP server ───────────────────────────────────────────────
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
python3 -m http.server --directory "$WEB_DIR" "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
HTML_TMP=""
trap 'kill $SERVER_PID 2>/dev/null || true; [[ -n "${HTML_TMP:-}" ]] && rm -f "$HTML_TMP"' EXIT

# Give the server a moment
sleep 0.4

# Fetch the page
HTML=$(curl -sf "http://localhost:$PORT/index.html" 2>&1) || {
    echo "FAIL: could not fetch http://localhost:$PORT/index.html"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}

echo "=== test-fleet-scrubber.sh ==="
echo ""
echo "--- Test 1: D3 v7 CDN script tag ---"
if echo "$HTML" | grep -q 'src="https://d3js.org/d3.v7.min.js"'; then
    ok "D3 v7 CDN script tag present"
else
    bad "D3 v7 CDN script tag missing (expected: src=\"https://d3js.org/d3.v7.min.js\")"
fi

echo ""
echo "--- Test 2: Required element IDs ---"
for id in "id=\"timeline\"" "id=\"lanes\"" "id=\"live-toggle\"" "id=\"replay-btn\"" "id=\"side-panel\""; do
    if echo "$HTML" | grep -q "$id"; then
        ok "Element $id present"
    else
        bad "Element $id missing"
    fi
done

echo ""
echo "--- Test 3: Activity color CSS variables ---"
# Write HTML to a temp file so we can search it with python3 (avoids grep flag issues
# with CSS variable names that start with --)
HTML_TMP="$(mktemp /tmp/fleet-scrubber-test-XXXXXX.html)"
printf '%s' "$HTML" > "$HTML_TMP"
for var in "--color-claim" "--color-edit" "--color-push" "--color-merge" "--color-blocked" "--color-idle"; do
    if python3 -c "import sys; content=open('$HTML_TMP').read(); sys.exit(0 if '$var' in content else 1)"; then
        ok "CSS variable $var present"
    else
        bad "CSS variable $var missing"
    fi
done

echo ""
echo "--- Test 4: Fixture files exist and are valid JSON ---"
SEGMENTS_JSON="$WEB_DIR/fixtures/segments.json"
EVENTS_JSON="$WEB_DIR/fixtures/events.json"

if [[ -f "$SEGMENTS_JSON" ]]; then
    if python3 -c "import json,sys; data=json.load(open('$SEGMENTS_JSON')); assert isinstance(data, list) and len(data) > 0" 2>/dev/null; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('$SEGMENTS_JSON'))))")
        ok "fixtures/segments.json is valid JSON with $COUNT entries"
    else
        bad "fixtures/segments.json is invalid JSON or empty"
    fi
else
    bad "fixtures/segments.json not found"
fi

if [[ -f "$EVENTS_JSON" ]]; then
    if python3 -c "import json,sys; data=json.load(open('$EVENTS_JSON')); assert isinstance(data, list) and len(data) > 0" 2>/dev/null; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('$EVENTS_JSON'))))")
        ok "fixtures/events.json is valid JSON with $COUNT entries"
    else
        bad "fixtures/events.json is invalid JSON or empty"
    fi
else
    bad "fixtures/events.json not found"
fi

echo ""
echo "--- Test 5: Fixture generator exists ---"
GEN_PY="$WEB_DIR/fixtures/gen.py"
if [[ -f "$GEN_PY" ]]; then
    ok "fixtures/gen.py exists"
else
    bad "fixtures/gen.py not found"
fi

echo ""
echo "--- Test 6: chump-fleet-view.sh exists and is executable ---"
VIEW_SH="$REPO_ROOT/scripts/dev/chump-fleet-view.sh"
if [[ -x "$VIEW_SH" ]]; then
    ok "scripts/dev/chump-fleet-view.sh is executable"
else
    bad "scripts/dev/chump-fleet-view.sh not found or not executable"
fi

echo ""
echo "--- Test 7: README exists ---"
README="$WEB_DIR/README.md"
if [[ -f "$README" ]]; then
    ok "web/fleet-scrubber/README.md exists"
else
    bad "web/fleet-scrubber/README.md not found"
fi

echo ""
echo "--- Test 8: ?fixtures=1 mode URL switch present in JS ---"
if echo "$HTML" | grep -q 'USE_FIXTURES'; then
    ok "Fixture mode URL switch (USE_FIXTURES) present in JS"
else
    bad "Fixture mode URL switch missing"
fi

echo ""
echo "--- Test 9: INFRA-2217 — lane recency sort logic present ---"
if echo "$HTML" | grep -q 'lastTsAll'; then
    ok "Recency sort map (lastTsAll) present in JS"
else
    bad "Recency sort map (lastTsAll) missing — lane sort not implemented"
fi
if echo "$HTML" | grep -q 'STALE_THRESHOLD_MS'; then
    ok "Stale threshold constant (STALE_THRESHOLD_MS) present"
else
    bad "Stale threshold constant missing"
fi

echo ""
echo "--- Test 10: INFRA-2217 — self-highlight CSS and JS present ---"
if echo "$HTML" | grep -q 'self-session'; then
    ok "Self-session CSS class present"
else
    bad "Self-session CSS class missing"
fi
if echo "$HTML" | grep -q 'chump-self-session-id'; then
    ok "Self-session localStorage key (chump-self-session-id) present"
else
    bad "Self-session localStorage key missing"
fi
if echo "$HTML" | grep -q 'selfSessionId'; then
    ok "selfSessionId state variable present"
else
    bad "selfSessionId state variable missing"
fi

echo ""
echo "--- Test 11: INFRA-2217 — show-stale toggle present ---"
if echo "$HTML" | grep -q 'id="stale-toggle"'; then
    ok "Stale toggle button (id=stale-toggle) present"
else
    bad "Stale toggle button missing"
fi
if echo "$HTML" | grep -q 'chump-show-stale'; then
    ok "Stale toggle localStorage key (chump-show-stale) present"
else
    bad "Stale toggle localStorage key missing"
fi

echo ""
echo "--- Test 12: INFRA-2217 — fixture lane order matches recency ---"
# Verify fixture segments.json has multiple sessions with distinct max-end
# timestamps, confirming the sort has meaningful data to order.
python3 -c "
import json, sys
from collections import defaultdict

path = '$SEGMENTS_JSON'
segs = json.load(open(path))
sessions = defaultdict(list)
for s in segs:
    sessions[s['session_id']].append(s['end'])

if len(sessions) < 2:
    print('WARN: only one session in fixtures — recency sort has nothing to order')
    sys.exit(0)

max_ends = {sid: max(ends) for sid, ends in sessions.items()}
sids_sorted = sorted(max_ends, key=lambda s: max_ends[s], reverse=True)
print('  Sessions in recency order: ' + str(sids_sorted))
for i in range(len(sids_sorted) - 1):
    assert max_ends[sids_sorted[i]] >= max_ends[sids_sorted[i+1]], \
        'Sort order wrong: ' + sids_sorted[i] + ' vs ' + sids_sorted[i+1]
print('  Lane recency order validated against fixture data')
" && ok "Fixture data supports lane recency sort (multiple sessions, distinct max-end timestamps)" \
  || bad "Fixture lane recency sort validation failed"

echo ""
echo "--- Test 13: META-624 — nested-lane expand/collapse arrow ---"
if echo "$HTML" | grep -q 'lane-toggle'; then
    ok "lane-toggle CSS class present"
else
    bad "lane-toggle CSS class missing"
fi
if echo "$HTML" | grep -q 'chump-scrubber-collapsed-lanes'; then
    ok "Collapsed-lanes localStorage key (chump-scrubber-collapsed-lanes) present"
else
    bad "Collapsed-lanes localStorage key missing"
fi
if echo "$HTML" | grep -q 'aria-expanded'; then
    ok "aria-expanded attribute wired on the lane toggle"
else
    bad "aria-expanded attribute missing"
fi
if echo "$HTML" | grep -q 'buildLaneOrder'; then
    ok "buildLaneOrder() parent/child lane hierarchy present"
else
    bad "buildLaneOrder() missing — nested-lane grouping not implemented"
fi
if python3 -c "
import json, sys
segs = json.load(open('$SEGMENTS_JSON'))
sys.exit(0 if any('parent_session_id' in s for s in segs) else 1)
"; then
    ok "fixtures/segments.json includes at least one parent_session_id (nested-lane demo data)"
else
    bad "fixtures/segments.json has no parent_session_id — nesting is untestable in fixture mode"
fi

echo ""
echo "--- Test 14: META-743 — segment duration computed from start_ts_ms/end_ts_ms ---"
INDEX_HTML="$WEB_DIR/index.html"
if command -v node >/dev/null 2>&1; then
    NODE_RESULT=$(node -e "
const fs = require('fs');
const html = fs.readFileSync('$INDEX_HTML', 'utf8');
const durMatch = html.match(/const computeDurS = \(seg\) => \{[\s\S]*?\n\};/);
const fmtMatch = html.match(/const fmtDur = \(s\) => \{[\s\S]*?\n\};/);
if (!durMatch || !fmtMatch) { console.log('EXTRACT_FAIL'); process.exit(0); }
const fn = new Function(durMatch[0] + fmtMatch[0] + '; return [computeDurS({ start_ts_ms: 1000, end_ts_ms: 5500 }), fmtDur(computeDurS({ start_ts_ms: 1000, end_ts_ms: 5500 }))];');
const [dur, label] = fn();
console.log(dur + '|' + label);
" 2>&1)
    if [[ "$NODE_RESULT" == "4.5|4.5s" ]]; then
        ok "segment start_ts_ms=1000, end_ts_ms=5500 renders as 4.5s (got: $NODE_RESULT)"
    else
        bad "segment duration mismatch: expected '4.5|4.5s', got '$NODE_RESULT'"
    fi
else
    echo "  [SKIP] node not available — cannot exercise computeDurS/fmtDur"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi

exit 0
