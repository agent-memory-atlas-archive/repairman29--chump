#!/usr/bin/env bash
# test-sse-filter-and-regret.sh — INFRA-1559 smoke test.
#
# Verifies:
#   (a) source audit — ChumpAmbientViewer exposes tag-based filter pills
#       (kind/gap/severity), a saved-preset dropdown backed by localStorage,
#       and a "new since last viewed" overlay counter; emits
#       kind=sse_filter_applied telemetry on filter change.
#   (b) source audit — ChumpBanditRegretPanel subscribes to
#       kind=routing_decision / kind=routing_outcome and renders a
#       cumulative-regret-per-arm chart with an "optimal always" overlay.
#   (c) live behavioural check (node, no browser needed) — loads both
#       component classes straight out of web/v2/app.js, injects synthetic
#       routing_decision + routing_outcome events, and asserts: filter pills
#       render for an active filter, and the regret line's cumulative value
#       per arm is monotonically non-decreasing across the injected events.
#
# Run: bash scripts/ci/test-sse-filter-and-regret.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_JS="$REPO_ROOT/web/v2/app.js"

echo "=== INFRA-1559 SSE filter UI + bandit regret smoke test ==="
echo

[[ -f "$APP_JS" ]] || { fail "Test 1: web/v2/app.js missing"; echo; echo "FAIL"; exit 1; }
ok "Test 1: web/v2/app.js present"

# ── (a) Source audit: filter pills + presets + telemetry ────────────────────
echo "--- Tests 2-8: ChumpAmbientViewer filter pills / presets / telemetry ---"

if grep -q 'amb-gap-filter' "$APP_JS" && grep -q 'amb-severity-filter' "$APP_JS"; then
    ok "Test 2: gap + severity filter inputs present"
else
    fail "Test 2: gap/severity filter inputs missing"
fi

if grep -q 'amb-active-pills' "$APP_JS" && grep -q 'amb-pill-chip' "$APP_JS"; then
    ok "Test 3: active filter pills (removable chips) rendered"
else
    fail "Test 3: filter pill chip rendering missing"
fi

if grep -q "amb-preset-select" "$APP_JS" && grep -q "chump-ambient-filter-presets" "$APP_JS"; then
    ok "Test 4: saved-preset dropdown backed by localStorage present"
else
    fail "Test 4: saved-preset dropdown / localStorage key missing"
fi

if grep -q "window.localStorage?.getItem" "$APP_JS" && grep -q "window.localStorage?.setItem" "$APP_JS"; then
    ok "Test 5: presets persisted via workspace-local localStorage"
else
    fail "Test 5: localStorage get/set for presets missing"
fi

if grep -q "new since last viewed" "$APP_JS"; then
    ok "Test 6: 'new since last viewed' overlay counter present"
else
    fail "Test 6: 'new since last viewed' overlay counter missing"
fi

if grep -q "'sse_filter_applied'" "$APP_JS" && grep -q "filter_spec" "$APP_JS" && grep -q "results_count" "$APP_JS"; then
    ok "Test 7: kind=sse_filter_applied telemetry with filter_spec + results_count"
else
    fail "Test 7: sse_filter_applied telemetry missing required fields"
fi

if grep -q "sse_filter_applied" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "Test 8: sse_filter_applied registered in EVENT_REGISTRY.yaml"
else
    fail "Test 8: sse_filter_applied missing from EVENT_REGISTRY.yaml"
fi

# ── (b) Source audit: bandit regret panel ────────────────────────────────────
echo "--- Tests 9-13: ChumpBanditRegretPanel ---"

if grep -q "class ChumpBanditRegretPanel" "$APP_JS"; then
    ok "Test 9: ChumpBanditRegretPanel class defined"
else
    fail "Test 9: ChumpBanditRegretPanel class missing"
fi

if grep -q "kinds=routing_decision,routing_outcome" "$APP_JS"; then
    ok "Test 10: subscribes to kind=routing_decision + kind=routing_outcome"
else
    fail "Test 10: routing_decision/routing_outcome subscription missing"
fi

if grep -q "regret-optimal-line" "$APP_JS"; then
    ok "Test 11: 'optimal arm always' overlay line rendered"
else
    fail "Test 11: optimal-always overlay line missing"
fi

if grep -q "Math.max(0, optimal - reward)" "$APP_JS"; then
    ok "Test 12: regret increment clamped non-negative (monotonic-by-construction)"
else
    fail "Test 12: regret increment clamp missing — cumulative regret could decrease"
fi

if grep -q "customElements.define('chump-bandit-regret-panel'" "$APP_JS"; then
    ok "Test 13: chump-bandit-regret-panel custom element registered"
else
    fail "Test 13: chump-bandit-regret-panel not registered"
fi

# ── (c) Live behavioural check: synthetic events, no browser (node) ─────────
echo "--- Test 14: synthetic routing_decision/routing_outcome injection (node) ---"

if command -v node >/dev/null 2>&1; then
    NODE_HARNESS="$(mktemp -t infra1559-XXXXXX.js)"
    trap 'rm -f "$NODE_HARNESS"' EXIT

    cat > "$NODE_HARNESS" <<'NODEEOF'
const assert = require('node:assert');
const fs = require('node:fs');

const appJsPath = process.argv[2];
const appJs = fs.readFileSync(appJsPath, 'utf8');

function extractClass(src, startMarker, endMarker, className) {
  const s = src.indexOf(startMarker);
  const e = src.indexOf(endMarker);
  if (s < 0 || e < 0) {
    console.error(`could not locate markers for ${className}`);
    process.exit(2);
  }
  const classSrc = src.slice(s, e + endMarker.length);
  return (new Function(`${classSrc}\nreturn ${className};`))();
}

// ── Minimal DOM stubs (mirrors web/v2/tests/ambient-viewer.test.js) ────────
class FakeElement {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.firstChild = null;
    this.attributes = {};
    this.dataset = {};
    this.style = { display: '' };
    this._innerHTML = '';
    this._listeners = {};
    this.scrollTop = 0; this.clientHeight = 0; this.scrollHeight = 0;
    this.hidden = false; this.textContent = ''; this.parent = null;
    this.className = ''; this.title = ''; this.value = '';
  }
  set innerHTML(v) {
    this._innerHTML = v;
    this.children = parseChildren(v, this);
    this.firstChild = this.children[0] || null;
  }
  get innerHTML() { return this._innerHTML; }
  setAttribute(k, v) { this.attributes[k] = v; }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); }
  appendChild(c) { c.parent = this; this.children.push(c); this.firstChild = this.children[0]; return c; }
  removeChild(c) { this.children = this.children.filter(x => x !== c); this.firstChild = this.children[0] || null; }
  querySelector(sel) { return findFirst(this, sel); }
  querySelectorAll(sel) { const out = []; walk(this, (n) => { if (matchesSelector(n, sel)) out.push(n); }); return out; }
  dispatch(name, evt) { (this._listeners[name] || []).forEach(fn => fn(evt)); }
}
function matchesSelector(node, sel) {
  if (!node || !sel) return false;
  if (sel.startsWith('.')) { const cls = sel.slice(1); return node.className && node.className.split(/\s+/).includes(cls); }
  return node.tagName === sel.toUpperCase();
}
function findFirst(root, sel) { let hit = null; walk(root, (n) => { if (!hit && matchesSelector(n, sel)) hit = n; }); return hit; }
function walk(node, fn) { fn(node); (node.children || []).forEach(c => walk(c, fn)); }
function parseChildren(html, parent) {
  const out = [];
  const tagRe = /<(\w+)([^>]*)>/g;
  let m;
  while ((m = tagRe.exec(html))) {
    const tag = m[1]; const attrs = m[2];
    const el = new FakeElement(tag); el.parent = parent;
    const clsM = /class="([^"]+)"/.exec(attrs);
    if (clsM) el.className = clsM[1];
    out.push(el);
  }
  return out;
}

globalThis.HTMLElement = FakeElement;
globalThis.customElements = { define() {} };
globalThis.document = { createElement(tag) { return new FakeElement(tag); }, dispatchEvent() {} };
globalThis.window = {};

const esRegistry = [];
class FakeEventSource {
  constructor(url) { this.url = url; this._handlers = {}; this.closed = false; esRegistry.push(this); }
  addEventListener(ev, fn) { this._handlers[ev] = fn; }
  close() { this.closed = true; }
  fire(ev, payload) { const fn = this._handlers[ev]; if (fn) fn({ data: typeof payload === 'string' ? payload : JSON.stringify(payload) }); }
}
globalThis.EventSource = FakeEventSource;

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); console.log(`[synthetic] PASS: ${name}`); passed++; }
  catch (e) { console.error(`[synthetic] FAIL: ${name}\n  ${e.stack || e.message}`); failed++; }
}

// ── Filter pills render for an active filter ────────────────────────────────
const ChumpAmbientViewer = extractClass(
  appJs,
  '// ── <chump-ambient-viewer> (INFRA-1198, filter pills + presets INFRA-1559)',
  "customElements.define('chump-ambient-viewer', ChumpAmbientViewer);",
  'ChumpAmbientViewer'
);

test('filter pills appear once a gap filter is applied', () => {
  esRegistry.length = 0;
  const c = new ChumpAmbientViewer();
  c.connectedCallback();
  const gapInput = c.querySelector('.amb-gap-filter');
  assert.ok(gapInput, 'gap filter input exists');
  gapInput.dispatch('change', { target: { value: 'INFRA-1559' } });
  const pillBar = c.querySelector('.amb-active-pills');
  assert.ok(pillBar, 'active-pills bar exists');
  assert.ok(pillBar.innerHTML.includes('gap=INFRA-1559'), `pill renders gap filter (got: ${pillBar.innerHTML})`);
});

// ── Cumulative regret is monotonically non-decreasing per arm ──────────────
const ChumpBanditRegretPanel = extractClass(
  appJs,
  '// ── <chump-bandit-regret-panel> (INFRA-1559)',
  "customElements.define('chump-bandit-regret-panel', ChumpBanditRegretPanel);",
  'ChumpBanditRegretPanel'
);

function parseCumRegret(legendHtml, arm) {
  const re = new RegExp(`${arm} \\(cum\\. regret ([0-9.]+)\\)`);
  const m = re.exec(legendHtml);
  return m ? parseFloat(m[1]) : null;
}

test('cumulative regret per arm is monotonic non-decreasing across synthetic events', () => {
  esRegistry.length = 0;
  const panel = new ChumpBanditRegretPanel();
  panel.connectedCallback();
  const es = esRegistry[esRegistry.length - 1];
  assert.ok(es.url.includes('kinds=routing_decision,routing_outcome'), 'subscribes to both kinds');

  // Synthetic decision+outcome pairs across 2 arms, INCLUDING a case where
  // reward > optimal_reward (should clamp regret_inc to 0, never negative).
  const synthetic = [
    { kind: 'routing_decision', arm: 'sonnet', decision_id: 'd1' },
    { kind: 'routing_outcome',  arm: 'sonnet', decision_id: 'd1', reward: 0.8, optimal_reward: 1.0 },
    { kind: 'routing_decision', arm: 'haiku',  decision_id: 'd2' },
    { kind: 'routing_outcome',  arm: 'haiku',  decision_id: 'd2', reward: 0.5, optimal_reward: 0.9 },
    { kind: 'routing_decision', arm: 'sonnet', decision_id: 'd3' },
    { kind: 'routing_outcome',  arm: 'sonnet', decision_id: 'd3', reward: 1.0, optimal_reward: 0.7 }, // reward > optimal — regret_inc clamps to 0
    { kind: 'routing_decision', arm: 'haiku',  decision_id: 'd4' },
    { kind: 'routing_outcome',  arm: 'haiku',  decision_id: 'd4', reward: 0.2, optimal_reward: 0.9 },
  ];

  const seenSonnet = [];
  const seenHaiku = [];
  for (const evt of synthetic) {
    es.fire('ambient', evt);
    const legend = panel.querySelector('.regret-legend');
    if (legend) {
      const s = parseCumRegret(legend.innerHTML, 'sonnet');
      const h = parseCumRegret(legend.innerHTML, 'haiku');
      if (s !== null) seenSonnet.push(s);
      if (h !== null) seenHaiku.push(h);
    }
  }

  assert.ok(seenSonnet.length >= 2, 'captured >=2 sonnet regret samples');
  assert.ok(seenHaiku.length >= 2, 'captured >=2 haiku regret samples');
  for (const series of [seenSonnet, seenHaiku]) {
    for (let i = 1; i < series.length; i++) {
      assert.ok(series[i] >= series[i - 1] - 1e-9,
        `cumulative regret is monotonic non-decreasing (${series[i - 1]} -> ${series[i]})`);
    }
  }
  // sonnet's 3rd outcome (reward=1.0 > optimal=0.7) must NOT have decreased cumulative regret.
  assert.ok(seenSonnet[seenSonnet.length - 1] >= seenSonnet[seenSonnet.length - 2] - 1e-9,
    'reward > optimal_reward does not decrease cumulative regret (clamped to 0 increment)');
});

console.log('');
console.log(`[synthetic] ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
NODEEOF

    if node "$NODE_HARNESS" "$APP_JS"; then
        ok "Test 14: synthetic injection — filter pills render + regret is monotonic non-decreasing"
    else
        fail "Test 14: synthetic injection harness reported a failure (see output above)"
    fi
    rm -f "$NODE_HARNESS"
    trap - EXIT
else
    echo "--- Test 14: SKIPPED (node not on PATH) ---"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    printf 'FAILS:\n'
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
