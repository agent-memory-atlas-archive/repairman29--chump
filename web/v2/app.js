// Chump v2 — vanilla Web Components app shell.
// No build step, no CDN dependencies. Air-gap safe by construction.

// ── chumpPrefs: localStorage namespace + try/catch wrapper (INFRA-1280) ─────
// Every PWA preference lives under the `chump.*` localStorage namespace.
// Schema doc: docs/api/PWA_STATE_SCHEMA.md. Each consumer reads/writes via
// this helper, so:
//   - corruption never breaks the UI (try/catch + default fallback)
//   - every write emits kind=pwa_pref_changed for telemetry / adoption signal
//   - one place to grep for every persisted preference
//
// Privacy: no PII (no API tokens, no user content). session_ids + gap_ids OK.
window.chumpPrefs = window.chumpPrefs || (() => {
  const NS = 'chump.';
  function k(key) { return key.startsWith(NS) ? key : NS + key; }
  function emit(key, valueClass) {
    // Best-effort ambient signal via a sendBeacon-style fetch; never block.
    try {
      const ts = new Date().toISOString();
      // The /api/ambient/emit endpoint may not exist on every binary; fail silent.
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'pwa_pref_changed', key, value_class: valueClass, ts,
      }));
    } catch {}
  }
  return {
    /** Read a JSON-serialised pref. Returns `fallback` on miss or parse error. */
    get(key, fallback = null) {
      try {
        const raw = localStorage.getItem(k(key));
        if (raw == null) return fallback;
        return JSON.parse(raw);
      } catch {
        return fallback;
      }
    },
    /** Write a pref. Stringifies to JSON. Emits telemetry. */
    set(key, value) {
      try {
        localStorage.setItem(k(key), JSON.stringify(value));
        const cls = value == null ? 'null'
                  : typeof value === 'boolean' ? 'bool'
                  : typeof value === 'number'  ? 'number'
                  : Array.isArray(value)       ? 'array'
                  : typeof value === 'object'  ? 'object'
                                               : 'string';
        emit(k(key), cls);
        return true;
      } catch {
        return false;
      }
    },
    /** Remove a single pref. */
    del(key) {
      try { localStorage.removeItem(k(key)); return true; } catch { return false; }
    },
    /** Wipe ALL chump.* prefs. Used by Settings → Reset all preferences. */
    resetAll() {
      try {
        const keys = [];
        for (let i = 0; i < localStorage.length; i++) {
          const key = localStorage.key(i);
          if (key && key.startsWith(NS)) keys.push(key);
        }
        keys.forEach(key => localStorage.removeItem(key));
        emit('*', 'reset_all');
        return keys.length;
      } catch { return 0; }
    },
  };
})();

// ── Theme: apply persisted theme BEFORE first paint (avoid flash) ───────────
(() => {
  const t = window.chumpPrefs.get('theme', 'system');
  function effectiveTheme(pref) {
    if (pref === 'light' || pref === 'dark' || pref === 'high-contrast') return pref;
    // 'system' → follow OS
    return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  document.documentElement.setAttribute('data-theme', effectiveTheme(t));
  // React to OS theme changes when in system mode.
  window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (window.chumpPrefs.get('theme', 'system') === 'system') {
      document.documentElement.setAttribute('data-theme', effectiveTheme('system'));
    }
  });
})();

// ── Cost-ceiling 402 interceptor (PRODUCT-113) ──────────────────────────────
// Frontend half of the kill-switch contract: when the backend returns 402
// Payment Required on any /api/chat or /api/gap/work request, the body
// carries {error:'session_cost_exceeded', kill_threshold, current} and the
// PWA renders a modal that explains what happened and how to raise the
// ceiling. Backend enforcement (Rust handler change) is a follow-up gap.
//
// This module ONLY handles the UI side: it wraps window.fetch so every
// callsite that hits an /api/* endpoint inherits the modal automatically.
// No view code needs to know about cost-kill semantics.
(() => {
  const origFetch = window.fetch.bind(window);
  let modalOpen = false;
  window.fetch = async function(input, init) {
    const res = await origFetch(input, init);
    if (res.status === 402) {
      try {
        const cloned = res.clone();
        const body = await cloned.json().catch(() => ({}));
        if (body && (body.error === 'session_cost_exceeded' || body.error === 'fleet_cost_exceeded')) {
          if (!modalOpen) renderKillModal(body);
        }
      } catch {}
    }
    return res;
  };

  function renderKillModal(body) {
    modalOpen = true;
    const kind = body.error === 'fleet_cost_exceeded' ? 'fleet' : 'session';
    const title = kind === 'fleet'
      ? 'Fleet daily cost ceiling exceeded'
      : 'Session cost ceiling exceeded';
    const ceiling = body.kill_threshold ?? '?';
    const current = body.current ?? '?';
    const modal = document.createElement('div');
    modal.className = 'cost-kill-modal';
    modal.setAttribute('role', 'alertdialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-label', title);
    modal.innerHTML = `
      <div class="cost-kill-modal-shell">
        <h2 class="cost-kill-title">⛔ ${title}</h2>
        <p class="cost-kill-msg">
          This ${kind} hit its <strong>$${ceiling}</strong> kill threshold
          (current: <strong>$${current}</strong>). New turn requests will be
          refused until the ceiling is raised or the cap resets.
        </p>
        <p class="cost-kill-actions">
          <button type="button" class="cost-kill-config">Raise ceiling in CONFIG</button>
          <button type="button" class="cost-kill-dismiss">Dismiss</button>
        </p>
        <p class="cost-kill-hint">
          Telemetry: <code>kind=cost_threshold_crossed</code> fired in ambient.jsonl.
        </p>
      </div>
    `;
    document.body.appendChild(modal);
    modal.querySelector('.cost-kill-config')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
      closeModal();
    });
    modal.querySelector('.cost-kill-dismiss')?.addEventListener('click', closeModal);
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'cost_threshold_crossed',
        which: kind, kill_threshold: ceiling, current,
        ts: new Date().toISOString(),
      }));
    } catch {}

    function closeModal() {
      modalOpen = false;
      modal.remove();
    }
  }
})();

// ── ChumpAcpDeeplink helper (PRODUCT-110) ───────────────────────────────────
// Build chump://acp/open?... URLs the operator's registered ACP client (Zed,
// JetBrains, etc) can intercept and open. Competitive-differentiation surface
// vs Claude Code per docs/design/OPERATOR_CONSOLE_V2.md (archetype 3) —
// CC structurally can't ship this. The browser silently ignores the click
// when no ACP client is registered; the companion "Copy link" button keeps
// the value useful for sharing in either case.
//
// Schema documented in docs/api/PWA_ACP_DEEPLINKS.md.
window.ChumpAcpDeeplink = window.ChumpAcpDeeplink || (() => {
  function build(params) {
    const url = new URL('chump://acp/open');
    for (const [k, v] of Object.entries(params || {})) {
      if (v == null || v === '') continue;
      url.searchParams.set(k, String(v));
    }
    return url.toString();
  }
  return {
    open(params)     { return build(params); },          // generic
    gap(id, opts={}) { return build({ gap: id, ...opts }); },
    pr(num, opts={}) { return build({ pr: num,  ...opts }); },
    branch(b, opts={}) { return build({ branch: b, ...opts }); },
  };
})();

// PRODUCT-110: delegated click handler for Copy-link buttons across the app.
// Lives at the document level so any future view that renders a .gap-acp-copy
// button gets the same behavior without extra wiring.
document.addEventListener('click', (e) => {
  const btn = e.target.closest('.gap-acp-copy');
  if (!btn) return;
  const href = btn.dataset.acpHref;
  if (!href) return;
  try {
    navigator.clipboard?.writeText(href).then(() => {
      const prev = btn.textContent;
      btn.textContent = 'Copied ✓';
      btn.classList.add('gap-acp-copy-success');
      setTimeout(() => {
        btn.textContent = prev;
        btn.classList.remove('gap-acp-copy-success');
      }, 1200);
    });
  } catch {}
  try {
    navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
      kind: 'acp_deeplink_emitted',
      target_kind: 'copy',
      client_detected: !!navigator.clipboard,
      ts: new Date().toISOString(),
    }));
  } catch {}
});

// PRODUCT-110: telemetry on the actual ACP link click (the editor handoff path).
document.addEventListener('click', (e) => {
  const a = e.target.closest('a.gap-acp-link');
  if (!a) return;
  try {
    navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
      kind: 'acp_deeplink_emitted',
      target_kind: a.dataset.acpTarget || 'unknown',
      target_id: a.dataset.acpId || a.dataset.acpPr || a.dataset.acpBranch || '',
      // We can't observe whether the browser actually had a handler — emit
      // best-effort so the leaderboard sees "deeplink attempted" volume.
      client_detected: 'unknown',
      ts: new Date().toISOString(),
    }));
  } catch {}
});

// ── DashboardStream singleton (PRODUCT-099) ──────────────────────────────────
// Frontend was polling /api/dashboard, /api/jobs, /api/fleet-status, /api/gap-queue
// on 3 different setInterval timers (5/10/15s). Meanwhile the backend has been
// shipping SSE at /api/dashboard/stream that nobody consumed. Wire it up.
//
// This is a tiny event bus: ONE EventSource for the whole app; views subscribe
// via window.chumpStream.subscribe(callback). Reconnect with backoff on error.
// Pauses when the document is hidden (battery win on phone).
//
// Visible status: dispatches CustomEvent('chump:stream-status', { detail: 'live'|'reconnecting'|'paused'|'offline' })
// so any component can render a live indicator.
class DashboardStream {
  #es = null;
  #subs = new Set();
  #status = 'init';
  #reconnectDelayMs = 1000;       // grows on failure, resets on success
  #reconnectTimer = null;
  #visibilityHooked = false;
  #onlineHooked = false;
  #lastEventAt = 0;
  #lastPayload = null;            // replayed to late subscribers

  start() {
    if (this.#visibilityHooked === false) {
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') {
          this.#close('paused');
        } else if (this.#status === 'paused' || this.#status === 'offline') {
          this.#open();
        }
      });
      this.#visibilityHooked = true;
    }
    if (this.#onlineHooked === false) {
      window.addEventListener('offline', () => this.#close('offline'));
      window.addEventListener('online', () => {
        if (document.visibilityState !== 'hidden') this.#open();
      });
      this.#onlineHooked = true;
    }
    if (document.visibilityState !== 'hidden') this.#open();
  }

  subscribe(fn) {
    this.#subs.add(fn);
    // Replay the most recent payload so late subscribers don't wait 30s
    // for the next dashboard tick.
    if (this.#lastPayload) {
      try { fn(this.#lastPayload); } catch {}
    }
    return () => this.#subs.delete(fn);
  }

  status() { return this.#status; }
  lastEventAt() { return this.#lastEventAt; }

  #setStatus(next) {
    if (next === this.#status) return;
    this.#status = next;
    document.dispatchEvent(new CustomEvent('chump:stream-status', { detail: next }));
  }

  #open() {
    this.#clearReconnect();
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
    try {
      this.#es = new EventSource('/api/dashboard/stream');
    } catch (e) {
      this.#scheduleReconnect();
      return;
    }
    this.#setStatus('connecting');
    this.#es.addEventListener('dashboard', (ev) => {
      this.#lastEventAt = Date.now();
      this.#setStatus('live');
      this.#reconnectDelayMs = 1000;
      let data = null;
      try { data = JSON.parse(ev.data); } catch { return; }
      const msg = { type: 'dashboard', data };
      this.#lastPayload = msg;
      this.#subs.forEach((fn) => { try { fn(msg); } catch {} });
    });
    this.#es.onerror = () => this.#scheduleReconnect();
  }

  #close(reason) {
    this.#clearReconnect();
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
    this.#setStatus(reason);
  }

  #scheduleReconnect() {
    this.#clearReconnect();
    if (this.#es) { try { this.#es.close(); } catch {} this.#es = null; }
    this.#setStatus('reconnecting');
    // Full jitter on the base delay so concurrent clients don't reconnect-stampede.
    const jitter = Math.random() * 0.5 + 0.75; // 0.75x – 1.25x
    const delay = Math.round(this.#reconnectDelayMs * jitter);
    this.#reconnectDelayMs = Math.min(this.#reconnectDelayMs * 2, 30_000);
    this.#reconnectTimer = setTimeout(() => {
      if (document.visibilityState !== 'hidden' && navigator.onLine !== false) {
        this.#open();
      }
    }, delay);
  }

  #clearReconnect() {
    if (this.#reconnectTimer) { clearTimeout(this.#reconnectTimer); this.#reconnectTimer = null; }
  }
}

window.chumpStream = window.chumpStream || new DashboardStream();
window.addEventListener('DOMContentLoaded', () => window.chumpStream.start());

// ── <chump-nav> ───────────────────────────────────────────────────────────────
// PRODUCT-106: four-cadence operator console nav per docs/design/OPERATOR_CONSOLE_V2.md.
//
// Replaces the prior 11-button feature-grouped nav with four workflow-grouped
// cadence buttons (NOW / AMBIENT / LIBRARY / CONFIG). Each cadence renders a
// sub-tab strip below the main nav containing the sub-views from the design
// doc's canvas table.
//
// Back-compat: every legacy data-view name continues to resolve via the
// CADENCE_VIEW_MAP below. Clicking a sub-tab dispatches the same
// chump:navigate CustomEvent the router has always consumed — no view code
// changes needed. URL deep links (?view=<id>) still work because the legacy
// data-view IDs are the values in the map.
//
// Keyboard shortcuts: N / A / L / C switch cadences. Persists last cadence
// via INFRA-1280 chumpPrefs (chump.last_cadence).
//
// Telemetry: kind=cadence_view_active {cadence, dwell_s} on every switch.
const CHUMP_CADENCES = [
  {
    id: 'now',
    label: 'Now',
    icon: '⚡',
    shortcut: 'n',
    default_view: 'cockpit',
    subtabs: [
      { id: 'cockpit',       label: 'Cockpit',        icon: '🎯' }, // PRODUCT-122
      { id: 'impact',        label: 'Impact',         icon: '📊' }, // PRODUCT-081
      { id: 'brief',         label: 'Brief',          icon: '📋' }, // PRODUCT-078
      { id: 'chat',          label: 'Chat',           icon: '💬' },
      { id: 'agent',         label: 'My queue',       icon: '🔄' },
      { id: 'notifications', label: 'Alerts',         icon: '🔔', badge: true },
      { id: 'tasks',         label: 'Tasks',          icon: '✅' },
    ],
  },
  {
    id: 'ambient',
    label: 'Ambient',
    icon: '📡',
    shortcut: 'a',
    default_view: 'ambient',
    subtabs: [
      { id: 'ambient', label: 'Events',  icon: '📡' },
      { id: 'agents',  label: 'Fleet',   icon: '🤝' },
      { id: 'results', label: 'Ships',   icon: '📊' },
      { id: 'health',  label: 'Health',  icon: '🩺' }, // INFRA-1203
      { id: 'prs',     label: 'PRs',     icon: '🔀' }, // PRODUCT-084

      // INFRA-1204: a2a coordination view (inbox / INTENT / nudge).
      { id: 'coord',        label: 'Coord',        icon: '✉️' },
      // INFRA-1365: orchestrator session history panel.
      { id: 'orchestrator', label: 'Orchestrator', icon: '🎛' },
    ],
  },
  {
    id: 'library',
    label: 'Library',
    icon: '📚',
    shortcut: 'l',
    default_view: 'audit',
    subtabs: [
      // PRODUCT-111: dedicated Audit view consolidating tool-approval-audit +
      // cos-decisions for the enterprise-auditor archetype. Judgment kept as
      // a separate sub-tab for the operator-pending-decisions surface.
      { id: 'audit',     label: 'Audit',     icon: '📋' },
      { id: 'judgment',  label: 'Judgment',  icon: '⚖️' },
      { id: 'decisions', label: 'Decisions', icon: '🎯' },
      { id: 'memory',    label: 'Memory',    icon: '🧠' },

      { id: 'judgment',  label: 'Audit',     icon: '⚖️' },
      { id: 'roadmap',   label: 'Roadmap',   icon: '🗺' }, // INFRA-1207
    ],
  },
  {
    id: 'config',
    label: 'Config',
    icon: '⚙',
    shortcut: 'c',
    default_view: 'settings',
    subtabs: [
      { id: 'settings', label: 'Settings', icon: '⚙' },
      { id: 'models',   label: 'Models',   icon: '🤖' },
      // PRODUCT-112: archetype-1 (offline solo dev) trust signal —
      // air-gap badge in the footer click-drills here.
      { id: 'network',  label: 'Network',  icon: '🌐' },
    ],
  },
];

// Legacy view-id → cadence-id lookup so sub-tab clicks know which cadence to highlight.
const CHUMP_VIEW_TO_CADENCE = (() => {
  const out = {};
  for (const cad of CHUMP_CADENCES) {
    for (const tab of cad.subtabs) out[tab.id] = cad.id;
  }
  return out;
})();

class ChumpNav extends HTMLElement {
  #lastCadenceAt = 0;
  #activeCadence = null;

  connectedCallback() {
    // Resolve initial cadence: URL ?cadence > URL ?view→cadence map > chumpPrefs > 'now'.
    const url = new URLSearchParams(location.search);
    const cadenceFromUrl = url.get('cadence');
    const viewFromUrl = url.get('view');
    const storedCadence = window.chumpPrefs?.get('last_cadence', null);
    const initial = (cadenceFromUrl && CHUMP_CADENCES.find(c => c.id === cadenceFromUrl)?.id)
      || (viewFromUrl && CHUMP_VIEW_TO_CADENCE[viewFromUrl])
      || storedCadence
      || 'now';

    this.#renderShell();
    this.#activateCadence(initial, viewFromUrl);
    this.#wireClicks();
    this.#wireShortcuts();
  }

  #renderShell() {
    this.innerHTML = `
      <div class="nav-cadences" role="tablist" aria-label="Cadence">
        ${CHUMP_CADENCES.map((c) => `
          <button class="nav-cadence" role="tab"
                  data-cadence="${c.id}"
                  aria-label="${c.label} (${c.shortcut.toUpperCase()})"
                  title="${c.label} — press ${c.shortcut.toUpperCase()}">
            <span class="nav-icon">${c.icon}</span>
            <span class="nav-label">${c.label}</span>
          </button>
        `).join('')}
      </div>
      <div class="nav-subtabs" role="tablist" aria-label="Sub-view" id="chump-nav-subtabs"></div>
    `;
  }

  #renderSubtabs(cadenceId) {
    const cad = CHUMP_CADENCES.find(c => c.id === cadenceId);
    const bar = this.querySelector('#chump-nav-subtabs');
    if (!cad || !bar) return;
    bar.innerHTML = cad.subtabs.map(t => `
      <button class="nav-item" role="tab"
              data-view="${t.id}"
              aria-label="${t.label}"
              title="${t.label}">
        <span class="nav-icon">${t.icon}${t.badge ? '<span class="notif-badge" id="notif-nav-badge" hidden>0</span>' : ''}</span>
        <span class="nav-label">${t.label}</span>
      </button>
    `).join('');
  }

  #wireClicks() {
    // Cadence buttons.
    this.querySelectorAll('[data-cadence]').forEach((btn) => {
      btn.addEventListener('click', () => this.#activateCadence(btn.dataset.cadence));
    });
    // Sub-tab clicks (delegated since subtabs re-render on cadence change).
    this.querySelector('#chump-nav-subtabs')?.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-view]');
      if (!btn) return;
      this.#activateView(btn.dataset.view);
    });
  }

  #wireShortcuts() {
    document.addEventListener('keydown', (e) => {
      // Ignore when typing in inputs.
      if (e.target.matches('input, textarea, [contenteditable]')) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const cad = CHUMP_CADENCES.find(c => c.shortcut === e.key.toLowerCase());
      if (cad) {
        e.preventDefault();
        this.#activateCadence(cad.id);
      }
    });
  }

  #activateCadence(cadenceId, viewOverride = null) {
    const cad = CHUMP_CADENCES.find(c => c.id === cadenceId);
    if (!cad) return;

    // Telemetry: emit dwell-time for the previous cadence.
    if (this.#activeCadence && this.#activeCadence !== cadenceId && this.#lastCadenceAt) {
      const dwell_s = Math.round((Date.now() - this.#lastCadenceAt) / 1000);
      ChumpNav.#emitCadenceEvent(this.#activeCadence, dwell_s);
    }

    this.#activeCadence = cadenceId;
    this.#lastCadenceAt = Date.now();

    // Visual state.
    this.querySelectorAll('[data-cadence]').forEach((b) => b.removeAttribute('aria-current'));
    this.querySelector(`[data-cadence="${cadenceId}"]`)?.setAttribute('aria-current', 'page');

    this.#renderSubtabs(cadenceId);

    // Activate target view: viewOverride (URL) > cadence's default.
    const target = viewOverride && CHUMP_VIEW_TO_CADENCE[viewOverride] === cadenceId
      ? viewOverride
      : cad.default_view;
    this.#activateView(target, /* skipUrlPush */ false);

    // Persist + URL update.
    window.chumpPrefs?.set('last_cadence', cadenceId);
    try {
      const url = new URL(location.href);
      url.searchParams.set('cadence', cadenceId);
      history.replaceState(null, '', url.toString());
    } catch {}
  }

  #activateView(viewId, skipUrlPush = false) {
    // Update sub-tab visual state.
    this.querySelectorAll('#chump-nav-subtabs [data-view]').forEach((b) => b.removeAttribute('aria-current'));
    this.querySelector(`#chump-nav-subtabs [data-view="${viewId}"]`)?.setAttribute('aria-current', 'page');

    // Dispatch the legacy chump:navigate event the router has always consumed.
    document.dispatchEvent(new CustomEvent('chump:navigate', { detail: viewId }));

    if (!skipUrlPush) {
      try {
        const url = new URL(location.href);
        url.searchParams.set('view', viewId);
        history.replaceState(null, '', url.toString());
      } catch {}
    }
  }

  static #emitCadenceEvent(cadenceId, dwell_s) {
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'cadence_view_active',
        cadence: cadenceId,
        dwell_s,
        ts: new Date().toISOString(),
      }));
    } catch {}
  }
}
customElements.define('chump-nav', ChumpNav);

// ── <chump-tool-approval-tray> (PRODUCT-109) ────────────────────────────────
// Persistent tray that catches every tool_approval_request SSE event in one
// place — pulls tool approvals OUT of the chat scroll so they survive when
// the operator scrolls away or switches views.
//
// Listener contract:
//   - Receives document-level `chump:tool_approval` CustomEvent {detail: payload}
//     dispatched by chat.js (and any other future SSE source).
//   - Payload shape (matches src/stream_events.rs AgentEvent::ToolApprovalRequest):
//     { request_id, tool_name, tool_input, risk_level, reason, expires_at_secs }
//   - On APPROVE/DENY click → POST /api/approve {request_id, allowed} (handler
//     already exists at src/web_server.rs handle_approve).
//
// Multi-tab safety: uses BroadcastChannel('chump-tool-approval') to dedup
// across tabs. Approving in one tab dismisses the row in all tabs.
//
// Expired-deny-by-default: when expires_at_secs has passed without decision,
// the tray auto-POSTs allowed=false and shows the row dimmed with
// "(expired)" for 30s before removing.
//
// A11y: list is role='log' aria-live='polite'; each row is role='listitem'
// with aria-keyshortcuts on APPROVE/DENY (a/d). The tray itself is hidden
// (display:none) when list is empty so it doesn't take vertical space.
class ChumpToolApprovalTray extends HTMLElement {
  #pending = new Map(); // request_id → {payload, received_at, status}
  #channel = null;
  #tickTimer = null;
  #focusedRow = null;

  connectedCallback() {
    this.innerHTML = `
      <div class="tat-shell" role="log" aria-live="polite" aria-label="Pending tool approvals" hidden>
        <div class="tat-header">
          <span class="tat-count" id="tat-count">0</span>
          <span class="tat-title">pending tool approvals</span>
          <div class="tat-batch">
            <button type="button" class="tat-batch-btn tat-approve-all" aria-label="Approve all pending tool requests">Approve all</button>
            <button type="button" class="tat-batch-btn tat-deny-all" aria-label="Deny all pending tool requests">Deny all</button>
          </div>
        </div>
        <ul class="tat-list" id="tat-list"></ul>
      </div>
    `;
    document.addEventListener('chump:tool_approval', (e) => this.#onIncoming(e.detail));
    this.querySelector('.tat-approve-all')?.addEventListener('click', () => this.#decideAll(true));
    this.querySelector('.tat-deny-all')?.addEventListener('click', () => this.#decideAll(false));
    this.querySelector('#tat-list')?.addEventListener('click', (e) => this.#onListClick(e));

    // Multi-tab dedup channel — peer tab approves/denies, we drop the row.
    if (typeof BroadcastChannel !== 'undefined') {
      try {
        this.#channel = new BroadcastChannel('chump-tool-approval');
        this.#channel.addEventListener('message', (e) => {
          const m = e.data;
          if (m?.kind === 'decided' && m.request_id && this.#pending.has(m.request_id)) {
            this.#pending.delete(m.request_id);
            this.#render();
          }
        });
      } catch {}
    }

    // 1s tick to refresh countdowns + auto-deny expired.
    this.#tickTimer = setInterval(() => this.#tick(), 1000);
  }

  disconnectedCallback() {
    if (this.#tickTimer) clearInterval(this.#tickTimer);
    try { this.#channel?.close(); } catch {}
  }

  #onIncoming(payload) {
    if (!payload?.request_id) return;
    if (this.#pending.has(payload.request_id)) return; // dedup same tab
    this.#pending.set(payload.request_id, {
      payload,
      received_at: Date.now(),
      status: 'open',
    });
    this.#render();
  }

  #render() {
    const shell = this.querySelector('.tat-shell');
    const list = this.querySelector('#tat-list');
    const count = this.querySelector('#tat-count');
    if (!shell || !list || !count) return;
    const rows = Array.from(this.#pending.values()).sort((a, b) => a.received_at - b.received_at);
    count.textContent = String(rows.length);
    shell.hidden = rows.length === 0;
    list.innerHTML = rows.map((r) => this.#renderRow(r)).join('');
  }

  #renderRow(row) {
    const p = row.payload;
    const reqId = String(p.request_id || '').replace(/[<>&"]/g, '');
    const tool = String(p.tool_name || 'unknown');
    const risk = String(p.risk_level || '').toLowerCase();
    const reason = String(p.reason || '');
    const argsPreview = ChumpToolApprovalTray.#truncate(JSON.stringify(p.tool_input ?? {}), 180);
    const expiresIn = ChumpToolApprovalTray.#expiresInSecs(p.expires_at_secs);
    const expiredClass = row.status === 'expired' ? 'tat-row-expired' : '';
    const riskClass = `tat-risk-${risk || 'unknown'}`;
    return `
      <li class="tat-row ${riskClass} ${expiredClass}" role="listitem"
          data-request-id="${reqId}" tabindex="0">
        <div class="tat-row-main">
          <span class="tat-tool">${tool}</span>
          <span class="tat-risk">${risk || 'unknown'}</span>
          <span class="tat-countdown" data-countdown="${reqId}">${ChumpToolApprovalTray.#fmtCountdown(expiresIn)}</span>
        </div>
        ${reason ? `<div class="tat-reason">${ChumpToolApprovalTray.#esc(reason)}</div>` : ''}
        <div class="tat-args"><code>${ChumpToolApprovalTray.#esc(argsPreview)}</code></div>
        <div class="tat-actions">
          <button type="button" class="tat-btn tat-approve" data-action="approve" data-req="${reqId}"
                  aria-keyshortcuts="a" title="Approve (a)">Approve</button>
          <button type="button" class="tat-btn tat-deny" data-action="deny" data-req="${reqId}"
                  aria-keyshortcuts="d" title="Deny (d)">Deny</button>
        </div>
      </li>
    `;
  }

  #onListClick(e) {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const reqId = btn.dataset.req;
    const allowed = btn.dataset.action === 'approve';
    this.#decide(reqId, allowed);
  }

  #decideAll(allowed) {
    const ids = Array.from(this.#pending.keys());
    if (!ids.length) return;
    if (!confirm(`${allowed ? 'Approve' : 'Deny'} ${ids.length} pending tool request${ids.length === 1 ? '' : 's'}?`)) return;
    ids.forEach((id) => this.#decide(id, allowed, /* skipConfirm */ true));
  }

  #decide(requestId, allowed) {
    const row = this.#pending.get(requestId);
    if (!row) return;
    // Optimistic UI: dim immediately so the operator sees feedback.
    const li = this.querySelector(`.tat-row[data-request-id="${requestId}"]`);
    if (li) li.classList.add('tat-row-pending');

    fetch('/api/approve', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ request_id: requestId, allowed }),
    }).then((r) => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      this.#pending.delete(requestId);
      this.#broadcast({ kind: 'decided', request_id: requestId, allowed });
      this.#emitTelemetry({ action: allowed ? 'approved' : 'denied', tool: row.payload?.tool_name, mode: 'single' });
      this.#render();
    }).catch((err) => {
      if (li) {
        li.classList.remove('tat-row-pending');
        li.classList.add('tat-row-error');
        const banner = document.createElement('div');
        banner.className = 'tat-error-banner';
        banner.textContent = `Failed: ${err.message}. Retry below.`;
        li.appendChild(banner);
      }
    });
  }

  #tick() {
    if (this.#pending.size === 0) return;
    const now = Math.floor(Date.now() / 1000);
    let dirty = false;
    for (const [reqId, row] of this.#pending) {
      const expiresAt = Number(row.payload.expires_at_secs ?? 0);
      const remaining = expiresAt - now;
      // Update the countdown text in-place (no full re-render — keeps focus).
      const span = this.querySelector(`[data-countdown="${reqId}"]`);
      if (span) span.textContent = ChumpToolApprovalTray.#fmtCountdown(remaining);
      if (remaining <= 0 && row.status === 'open') {
        // Auto-deny expired requests.
        row.status = 'expired';
        const li = this.querySelector(`.tat-row[data-request-id="${reqId}"]`);
        if (li) li.classList.add('tat-row-expired');
        fetch('/api/approve', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ request_id: reqId, allowed: false }),
        }).then(() => {
          this.#broadcast({ kind: 'decided', request_id: reqId, allowed: false, reason: 'expired' });
          this.#emitTelemetry({ action: 'auto-denied', tool: row.payload?.tool_name, mode: 'expired' });
          // Hold the dimmed row for 30s so the operator sees the auto-deny.
          setTimeout(() => {
            this.#pending.delete(reqId);
            this.#render();
          }, 30000);
        }).catch(() => { /* will retry next tick if still pending */ });
        dirty = true;
      }
    }
    if (dirty) this.#render();
  }

  #broadcast(msg) {
    try { this.#channel?.postMessage(msg); } catch {}
  }

  #emitTelemetry(fields) {
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'tool_approval_tray_action',
        ts: new Date().toISOString(),
        ...fields,
      }));
    } catch {}
  }

  // ── helpers ──
  static #expiresInSecs(expiresAt) {
    const n = Number(expiresAt ?? 0);
    if (!n) return null;
    return n - Math.floor(Date.now() / 1000);
  }

  static #fmtCountdown(secs) {
    if (secs == null) return '—';
    if (secs <= 0) return 'expired';
    if (secs < 60) return `${secs}s`;
    const m = Math.floor(secs / 60);
    return `${m}m ${secs % 60}s`;
  }

  static #truncate(s, max) {
    if (!s) return '';
    return s.length > max ? s.slice(0, max - 1) + '…' : s;
  }

  static #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-tool-approval-tray', ChumpToolApprovalTray);

// ── <chump-first-run-wizard> (PRODUCT-108) ──────────────────────────────────
// Inline golden-path runner that replaces the empty Dashboard for new
// operators. Per docs/design/OPERATOR_CONSOLE_V2.md §first-run (archetype 1
// — offline solo dev): until brain/heartbeat/repo/model are configured,
// the NOW view shows this checklist instead of an empty dashboard.
//
// Each step polls its detection endpoint every 5s; the moment a step's
// pre-conditions go green, it auto-checks. Operator can [Skip] any step.
// When all 5 are done OR skipped, the wizard self-hides. State persists
// via INFRA-1280 chumpPrefs (chump.firstrun.completed_steps,
// chump.firstrun.dismissed). Re-accessible via Config → Setup at any
// time (a follow-up sub-gap wires the Settings entry).
//
// Telemetry: kind=firstrun_step_complete {step, action: detected|clicked|skipped}
// on every transition — lets us measure where new operators get stuck.
const FIRSTRUN_STEPS = [
  {
    id: 'model',
    title: 'LLM ready',
    detail: 'Detect an LLM at /api/stack-status (ollama / mistral.rs / OpenAI-compat)',
    detect: async () => {
      try {
        const r = await fetch('/api/stack-status'); if (!r.ok) return null;
        const d = await r.json();
        const inf = d.inference || {};
        if (inf.configured && inf.models_reachable !== false) {
          return { ok: true, label: d.llm_last_completion?.label || d.primary_backend || 'ready' };
        }
        return { ok: false, hint: 'No model reachable — install ollama + pull a model, or set OPENAI_API_BASE' };
      } catch { return null; }
    },
    cta: { href: 'https://github.com/repairman29/chump#install', label: 'Install guide' },
  },
  {
    id: 'repo',
    title: 'Repo set',
    detect: async () => {
      try {
        const r = await fetch('/api/repo/context'); if (!r.ok) return null;
        const d = await r.json();
        const repo = d.current_repo || d.repo || d.path;
        return repo ? { ok: true, label: repo } : { ok: false, hint: 'Set CHUMP_REPO or cd into a git repo before running chump --web' };
      } catch { return null; }
    },
    cta: { action: 'open-config', label: 'Choose repo' },
  },
  {
    // INFRA-1015: detect missing state.db and offer to initialize the repo via
    // POST /api/repo/init. The wizard step shows a confirmation dialog before
    // calling init so the operator is never surprised.
    id: 'repo_init',
    title: 'Repo initialized',
    detail: 'Detect .chump/state.db — run chump init if missing',
    detect: async () => {
      try {
        const r = await fetch('/api/repo/context'); if (!r.ok) return null;
        const d = await r.json();
        const repoPath = d.effective_root || d.current_repo || d.repo || d.path;
        if (!repoPath) return { ok: false, hint: 'Set a repo first (step above).' };
        // Check for state.db via a lightweight probe: if /api/gap-queue returns ok, state.db exists.
        const gq = await fetch('/api/gap-queue?limit=1');
        if (gq.ok) return { ok: true, label: '.chump/state.db found' };
        return { ok: false, hint: 'state.db not found — click "Initialize" to run chump init in this repo.', repoPath };
      } catch { return null; }
    },
    cta: { action: 'init-repo', label: 'Initialize' },
  },
  {
    id: 'brain',
    title: 'Brain initialized',
    detect: async () => {
      try {
        const r = await fetch('/api/brain/graph/stats'); if (!r.ok) return null;
        const d = await r.json();
        const nodes = Number(d.nodes ?? d.node_count ?? 0);
        return nodes > 0
          ? { ok: true, label: `${nodes} nodes` }
          : { ok: false, hint: 'Run `chump init` to populate the brain graph' };
      } catch { return null; }
    },
    cta: { href: 'https://github.com/repairman29/chump#init', label: 'Init brain' },
  },
  {
    id: 'autopilot',
    title: 'Autopilot running',
    detect: async () => {
      try {
        const r = await fetch('/api/autopilot/status'); if (!r.ok) return null;
        const d = await r.json();
        const running = d.running === true || d.status === 'running' || d.heartbeat_running === true;
        return running
          ? { ok: true, label: 'running' }
          : { ok: false, hint: 'Optional — required for "ship products" loop, not for one-off claims' };
      } catch { return null; }
    },
    cta: { action: 'start-autopilot', label: 'Start' },
    optional: true,
  },
  {
    id: 'first_gap',
    title: 'First gap claimed',
    detect: async () => {
      try {
        const r = await fetch('/api/gap-queue?status=claimed');
        if (!r.ok) return null;
        const d = await r.json();
        return (d.count ?? 0) > 0
          ? { ok: true, label: `${d.count} claimed` }
          : { ok: false, hint: 'Browse the Queue to claim your first gap' };
      } catch { return null; }
    },
    cta: { action: 'open-queue', label: 'Browse queue' },
    optional: true,
  },
  // INFRA-1585: Tauri-specific steps folded from <chump-ootb-wizard>.
  // These rows only render when window.__TAURI__ is present.
  {
    id: 'tauri_ollama',
    title: 'Ollama ready (Tauri)',
    detail: 'Detect Ollama for Tauri-native Chump desktop',
    tauriOnly: true,
    detect: async () => {
      if (!window.__TAURI__) return { ok: true, label: 'n/a (browser)' };
      try {
        const w = window.__TAURI__;
        const invoke = w.core?.invoke?.bind(w.core) ?? w.invoke?.bind(w) ?? null;
        if (!invoke) return { ok: false, hint: 'Tauri IPC unavailable' };
        const j = await invoke('ootb_detect_ollama');
        if (j && j.installed) {
          return { ok: true, label: (j.version || 'installed').replace(/\s+/g, ' ').trim() };
        }
        return { ok: false, hint: 'Ollama not found — install it or use LM Studio / MLX / a custom API base' };
      } catch { return null; }
    },
    cta: { action: 'tauri-open-ollama-download', label: 'Download Ollama' },
    optional: true,
  },
  {
    id: 'tauri_notif_perms',
    title: 'Native notifications (Tauri)',
    detail: 'System-tray alerts require notification permission on macOS',
    tauriOnly: true,
    detect: async () => {
      if (!window.__TAURI__) return { ok: true, label: 'n/a (browser)' };
      try {
        const w = window.__TAURI__;
        const invoke = w.core?.invoke?.bind(w.core) ?? w.invoke?.bind(w) ?? null;
        if (!invoke) return { ok: false, hint: 'Tauri IPC unavailable' };
        const result = await invoke('check_notification_permission');
        if (result && result.granted) return { ok: true, label: 'granted' };
        return { ok: false, hint: 'Click "Allow" to enable tray alerts' };
      } catch {
        // If the command is not registered (older builds), treat as optional pass.
        return { ok: true, label: 'skipped (command unavailable)' };
      }
    },
    cta: { action: 'tauri-request-notif-perms', label: 'Allow' },
    optional: true,
  },
];

class ChumpFirstRunWizard extends HTMLElement {
  #pollTimer = null;
  #state = {};

  connectedCallback() {
    // INFRA-1585: migrate legacy chump_first_visit keys from the old <chump-welcome>
    // component so users who completed that flow are not shown the new wizard.
    this.#migrateLegacyWelcomeKeys();

    // ?welcome=force overrides the dismissed flag for QA / demos.
    const forceShow = new URLSearchParams(location.search).get('welcome') === 'force';

    // Hide-permanently flag — if dismissed, never render until chumpPrefs is reset.
    if (!forceShow && window.chumpPrefs?.get('firstrun.dismissed', false) === true) {
      this.hidden = true;
      return;
    }

    // INFRA-1585: filter out Tauri-only steps when not running in Tauri.
    const isTauri = !!window.__TAURI__;
    const activeSteps = FIRSTRUN_STEPS.filter((s) => !s.tauriOnly || isTauri);

    this.#state = {
      steps: activeSteps.map((s) => ({
        id: s.id,
        status: window.chumpPrefs?.get(`firstrun.step.${s.id}`, null) || 'pending', // 'pending' | 'detected' | 'skipped' | 'completed'
        result: null,
      })),
      activeSteps,
    };
    this.#render();
    this.#detectAll();
    this.#pollTimer = setInterval(() => this.#detectAll(), 5000);
  }

  // INFRA-1585: one-way migration — if the old chump-welcome localStorage keys exist,
  // treat the user as having already completed first-run and suppress the new wizard.
  #migrateLegacyWelcomeKeys() {
    const seen = localStorage.getItem('chump_first_visit');
    const done = localStorage.getItem('chump_first_visit_completed');
    if (seen || done) {
      // Write via chumpPrefs if available, else directly with the same key format.
      if (window.chumpPrefs) {
        if (!window.chumpPrefs.get('firstrun.dismissed', false)) {
          window.chumpPrefs.set('firstrun.dismissed', true);
        }
      } else {
        if (!localStorage.getItem('chump.firstrun.dismissed')) {
          localStorage.setItem('chump.firstrun.dismissed', 'true');
        }
      }
    }
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  #render() {
    if (this.#isAllDone()) {
      this.hidden = true;
      return;
    }
    this.hidden = false;
    const total = this.#state.steps.length;
    const done = this.#state.steps.filter((s) => s.status === 'detected' || s.status === 'skipped' || s.status === 'completed').length;
    this.innerHTML = `
      <section class="frw-shell" data-onboarding="first-run-wizard" role="region" aria-label="First-run setup">
        <header class="frw-header">
          <h2 class="frw-title">Welcome — let's get Chump ready.</h2>
          <p class="frw-subtitle">${done} of ${total} steps complete. Each row auto-checks every 5 seconds.</p>
          <button type="button" class="frw-dismiss" aria-label="Dismiss the setup wizard (re-open from Config → Setup)">Dismiss</button>
        </header>
        <ol class="frw-steps">
          ${this.#state.steps.map((s, i) => this.#renderStep(s, this.#state.activeSteps[i])).join('')}
        </ol>
      </section>
    `;
    this.querySelector('.frw-dismiss')?.addEventListener('click', () => this.#dismiss());
    this.querySelectorAll('[data-step-skip]').forEach((b) => {
      b.addEventListener('click', () => this.#skipStep(b.dataset.stepSkip));
    });
    this.querySelectorAll('[data-step-action]').forEach((b) => {
      b.addEventListener('click', () => this.#stepAction(b.dataset.stepAction, b.dataset.actionKind));
    });
  }

  #renderStep(state, def) {
    const idx = this.#state.activeSteps.findIndex((s) => s.id === state.id);
    const isCurrent = state.status === 'pending' && this.#state.steps.slice(0, idx).every((s) => s.status !== 'pending');
    const checkIcon = state.status === 'detected' ? '✓'
                    : state.status === 'completed' ? '✓'
                    : state.status === 'skipped' ? '·'
                    : isCurrent ? '▸' : '○';
    const checkClass = state.status === 'detected' || state.status === 'completed' ? 'frw-step-done'
                    : state.status === 'skipped' ? 'frw-step-skipped'
                    : isCurrent ? 'frw-step-current' : 'frw-step-pending';
    const hint = state.result?.hint || def.detail || '';
    const label = state.result?.label || '';
    const showCta = state.status === 'pending';
    const ctaHtml = showCta && def.cta ? this.#renderCta(def.cta, state.id) : '';
    const skipHtml = showCta && def.optional ? `<button type="button" class="frw-skip" data-step-skip="${state.id}">Skip</button>` : '';
    return `
      <li class="frw-step ${checkClass}" role="listitem" aria-current="${isCurrent ? 'step' : 'false'}">
        <span class="frw-step-icon" aria-hidden="true">${checkIcon}</span>
        <div class="frw-step-body">
          <p class="frw-step-title">${def.title}${label ? ` — <span class="frw-step-label">${label}</span>` : ''}</p>
          ${state.status === 'pending' && hint ? `<p class="frw-step-hint">${hint}</p>` : ''}
        </div>
        <div class="frw-step-actions">${ctaHtml}${skipHtml}</div>
      </li>
    `;
  }

  #renderCta(cta, stepId) {
    if (cta.href) {
      return `<a class="frw-cta" href="${cta.href}" target="_blank" rel="noopener" data-step-action="${stepId}" data-action-kind="link">${cta.label}</a>`;
    }
    if (cta.action) {
      return `<button type="button" class="frw-cta" data-step-action="${stepId}" data-action-kind="${cta.action}">${cta.label}</button>`;
    }
    return '';
  }

  async #detectAll() {
    let dirty = false;
    for (let i = 0; i < this.#state.activeSteps.length; i++) {
      const def = this.#state.activeSteps[i];
      const state = this.#state.steps[i];
      if (state.status === 'detected' || state.status === 'completed' || state.status === 'skipped') continue;
      const result = await def.detect();
      state.result = result || null;
      if (result?.ok === true && state.status !== 'detected') {
        state.status = 'detected';
        window.chumpPrefs?.set(`firstrun.step.${state.id}`, 'detected');
        this.#emitTelemetry(state.id, 'detected');
        dirty = true;
      } else {
        dirty = true; // hint may have changed even on no-op
      }
    }
    if (dirty) this.#render();
  }

  #skipStep(stepId) {
    const state = this.#state.steps.find((s) => s.id === stepId);
    if (!state) return;
    state.status = 'skipped';
    window.chumpPrefs?.set(`firstrun.step.${stepId}`, 'skipped');
    this.#emitTelemetry(stepId, 'skipped');
    this.#render();
  }

  #stepAction(stepId, kind) {
    this.#emitTelemetry(stepId, `clicked:${kind || 'link'}`);
    if (kind === 'start-autopilot') {
      fetch('/api/autopilot/start', { method: 'POST' }).then(() => this.#detectAll()).catch(() => {});
    } else if (kind === 'open-queue') {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'agent' }));
    } else if (kind === 'open-config') {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
    } else if (kind === 'init-repo') {
      void this.#doRepoInit(stepId);
    } else if (kind === 'tauri-open-ollama-download') {
      // INFRA-1585: Tauri-folded step — open Ollama download via Tauri IPC.
      const w = window.__TAURI__;
      if (w) {
        const invoke = w.core?.invoke?.bind(w.core) ?? w.invoke?.bind(w) ?? null;
        if (invoke) invoke('ootb_open_ollama_download').catch(() => {});
      }
      setTimeout(() => this.#detectAll(), 3000);
    } else if (kind === 'tauri-request-notif-perms') {
      // INFRA-1585: Tauri-folded step — request notification permission via IPC.
      const w = window.__TAURI__;
      if (w) {
        const invoke = w.core?.invoke?.bind(w.core) ?? w.invoke?.bind(w) ?? null;
        if (invoke) invoke('request_notification_permission').catch(() => {}).then(() => this.#detectAll());
      }
    }
    // 'link' kind — the <a> handles navigation natively.
  }

  // INFRA-1015: confirmation dialog + POST /api/repo/init flow.
  async #doRepoInit(stepId) {
    // Get the current repo path from context.
    let repoPath = '';
    try {
      const r = await fetch('/api/repo/context');
      if (r.ok) {
        const d = await r.json();
        repoPath = d.effective_root || d.current_repo || d.repo || d.path || '';
      }
    } catch {}

    if (!repoPath) {
      alert('Cannot initialize: no active repo path detected. Set a repo first.');
      return;
    }

    // Confirmation dialog with optional seed-gaps checkbox.
    const seedDefault = false;
    const confirmed = window.confirm(
      `Initialize Chump repo at:\n  ${repoPath}\n\nThis will run "chump init" and install git hooks.\nContinue?`
    );
    if (!confirmed) return;

    // Ask about starter gaps — use confirm as a simple yes/no for the checkbox.
    const seedGaps = window.confirm(
      `Seed 3 starter gaps into the new registry?\n\n(STARTER-001 Feature, STARTER-002 Test, STARTER-003 Health check)\n\nClick OK to seed, Cancel to skip.`
    );

    // Show busy state in the step while we call the API.
    const state = this.#state.steps.find((s) => s.id === stepId);
    if (state) {
      state.result = { hint: 'Initializing repo…' };
      this.#render();
    }

    try {
      const resp = await fetch('/api/repo/init', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: repoPath, seed_starter_gaps: seedGaps }),
      });
      const d = await resp.json();
      if (d.ok) {
        const msg = d.already_initialized
          ? `Already initialized — state.db exists.`
          : `Initialized: state.db created${d.hooks_installed ? ', hooks installed' : ''}${d.gaps_seeded?.length ? `, ${d.gaps_seeded.length} starter gaps seeded` : ''}.`;
        if (state) {
          state.status = 'detected';
          state.result = { ok: true, label: msg };
          window.chumpPrefs?.set(`firstrun.step.${stepId}`, 'detected');
          this.#emitTelemetry(stepId, 'detected');
        }
      } else {
        if (state) state.result = { hint: `Init failed: ${d.error || 'unknown error'}` };
        alert(`Repo init failed:\n${d.error || 'Unknown error'}`);
      }
    } catch (e) {
      if (state) state.result = { hint: `Network error: ${e.message}` };
      alert(`Repo init error: ${e.message}`);
    }
    this.#render();
  }

  #dismiss() {
    window.chumpPrefs?.set('firstrun.dismissed', true);
    this.#emitTelemetry('*', 'dismissed');
    this.hidden = true;
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  #isAllDone() {
    return this.#state.steps.every((s) => s.status !== 'pending');
  }

  #emitTelemetry(stepId, action) {
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'firstrun_step_complete',
        step: stepId, action,
        ts: new Date().toISOString(),
      }));
    } catch {}
  }
}
customElements.define('chump-first-run-wizard', ChumpFirstRunWizard);

// ── <chump-status-footer> (PRODUCT-107) ─────────────────────────────────────
// Persistent operator HUD — always visible across every cadence. Six slots:
//   model | cost | air-gap | pillars (E/C/R/Z) | fleet | GH budget
//
// Each slot polls independently (its own interval) so a slow one doesn't
// stall the others. Click any slot → drill to the canonical detail view
// via the same chump:navigate event the rest of the app uses.
//
// Data sources per docs/design/OPERATOR_CONSOLE_V2.md §footer:
//   - model   : /api/stack-status .llm_last_completion (+ cascade slot suffix)
//   - cost    : /api/telemetry/cost (INFRA-1012)
//   - air-gap : /api/stack-status .air_gap_mode
//   - pillars : placeholder "—" until INFRA-1203 ships an endpoint
//   - fleet   : /api/fleet-status
//   - GH budget : /api/stack-status .github_rate_limit (or .gh_rate_limit)
//
// Telemetry: kind=footer_slot_drilled {slot, cadence_target} on every click.
//
// PRODUCT-107: 6 slots: model / cost / air-gap / pillars / fleet / GH budget.
// Desktop: one row. Mobile: wraps to 2 rows.
const FOOTER_CSS = `
  :host { display: block; }
  .sf-shell {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 14px;
    padding-bottom: calc(6px + var(--safe-bottom));
    background: var(--bg-surface);
    border-top: 1px solid var(--border);
    font-size: 11px;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    position: relative;
    z-index: 8;
    flex-shrink: 0;
  }
  .sf-slot {
    display: inline-flex;
    align-items: baseline;
    gap: 4px;
    padding: 4px 8px;
    border: none;
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
    border-radius: var(--radius-sm);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    min-height: 28px;
    transition: background 0.12s, color 0.12s;
  }
  .sf-slot:hover {
    background: var(--bg-elevated);
    color: var(--text-primary, var(--text));
  }
  .sf-slot:focus {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }
  .sf-dot {
    font-size: 14px; line-height: 1;
  }
  .sf-label {
    font-size: 9px;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    color: var(--text-secondary);
  }
  .sf-value {
    color: var(--text-primary, var(--text));
    font-weight: 500;
  }
  .sf-value.sf-stale {
    opacity: 0.5;
  }
  .sf-value.sf-warn {
    color: var(--warn, #ff9f0a);
  }
  .sf-value.sf-red {
    color: var(--error, #ff453a);
    font-weight: 600;
  }
  .sf-pillars { padding: 4px 10px; }
  .sf-pillar-grades {
    font-family: "SF Mono", ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.02em;
    color: var(--text-primary, var(--text));
  }
  /* Mobile (≤640px): wrap to 2 rows, tap targets ≥36px */
  @media (max-width: 640px) {
    .sf-shell {
      flex-wrap: wrap;
      justify-content: space-around;
      gap: 4px;
      padding: 6px 8px;
    }
    .sf-slot {
      flex: 1 1 auto;
      min-width: 90px;
      min-height: 36px;
      justify-content: center;
    }
    .sf-pillars { flex-basis: 100%; }
  }
`;

class ChumpStatusFooter extends HTMLElement {
  #shadow;
  #pollers = [];
  #lastValues = {};

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#shadow.innerHTML = `
      <style>${FOOTER_CSS}</style>
      <div class="sf-shell" role="contentinfo" aria-label="Operator status">
        <button type="button" class="sf-slot sf-model" data-slot="model" data-target="config:models"
                title="Model — click to view providers" aria-label="Active model (click to view providers)">
          <span class="sf-dot" id="sf-model-dot">○</span>
          <span class="sf-value" id="sf-model-value">loading…</span>
        </button>
        <button type="button" class="sf-slot sf-cost" data-slot="cost" data-target="library:judgment"
                title="Today's cost — click for breakdown" aria-label="Cumulative cost (click for breakdown)">
          <span class="sf-label">$</span>
          <span class="sf-value" id="sf-cost-value">…</span>
        </button>
        <button type="button" class="sf-slot sf-airgap" data-slot="airgap" data-target="config:network"
                title="Air-gap mode" aria-label="Air-gap mode status (click for network audit)">
          <span class="sf-dot" id="sf-airgap-dot">○</span>
          <span class="sf-value" id="sf-airgap-value">network</span>
        </button>
        <button type="button" class="sf-slot sf-pillars" data-slot="pillars" data-target="library:judgment"
                title="Pillar grades (E/C/R/Z) — click for Fleet Health" aria-label="Pillar grades (click for Fleet Health)">
          <span class="sf-pillar-grades" id="sf-pillar-grades">E:— C:— R:— Z:—</span>
        </button>
        <button type="button" class="sf-slot sf-fleet" data-slot="fleet" data-target="ambient:agents"
                title="Fleet roster — click to view agents" aria-label="Fleet health (click to view agents)">
          <span class="sf-dot" id="sf-fleet-dot">○</span>
          <span class="sf-value" id="sf-fleet-value">…</span>
        </button>
        <button type="button" class="sf-slot sf-gh" data-slot="gh" data-target="library:judgment"
                title="GitHub rate-limit budget" aria-label="GitHub GraphQL budget remaining">
          <span class="sf-label">GH</span>
          <span class="sf-value" id="sf-gh-value">…</span>
        </button>
      </div>
    `;
    this.#shadow.addEventListener('click', (e) => this.#onSlotClick(e));

    this.#startPoller(60_000, () => this.#pollStackStatus());
    this.#startPoller(30_000, () => this.#pollCost());
    this.#startPoller(15_000, () => this.#pollFleet());

    // First paint immediately.
    this.#pollStackStatus();
    this.#pollCost();
    this.#pollFleet();
  }

  disconnectedCallback() {
    this.#pollers.forEach((id) => clearInterval(id));
    this.#pollers = [];
  }

  #startPoller(intervalMs, fn) {
    this.#pollers.push(setInterval(() => fn(), intervalMs));
  }

  #pollStackStatus() {
    fetch('/api/stack-status').then((r) => r.ok ? r.json() : null).then((d) => {
      if (!d) return this.#markStale('model');
      const last = d.llm_last_completion || null;
      const modelLabel = last?.label || d.primary_backend || 'cold';
      const modelDot = this.#shadow.querySelector('#sf-model-dot');
      const modelVal = this.#shadow.querySelector('#sf-model-value');
      if (modelDot) { modelDot.textContent = last ? '●' : '○'; modelDot.style.color = last ? 'var(--accent)' : 'var(--text-secondary)'; }
      if (modelVal) { modelVal.textContent = ChumpStatusFooter.#truncate(modelLabel, 18); modelVal.classList.remove('sf-stale'); }
      this.#lastValues.model = modelLabel;

      const airgap = d.air_gap_mode === true;
      const agDot = this.#shadow.querySelector('#sf-airgap-dot');
      const agVal = this.#shadow.querySelector('#sf-airgap-value');
      if (agDot) { agDot.textContent = airgap ? '●' : '○'; agDot.style.color = airgap ? 'var(--success)' : 'var(--text-secondary)'; }
      if (agVal) { agVal.textContent = airgap ? 'air-gap' : 'network'; agVal.classList.remove('sf-stale'); }
      this.#lastValues.airgap = airgap;

      const rl = d.github_rate_limit || d.gh_rate_limit;
      if (rl && typeof rl.graphql_remaining === 'number' && typeof rl.graphql_limit === 'number') {
        const pct = Math.round((rl.graphql_remaining / Math.max(1, rl.graphql_limit)) * 100);
        const ghVal = this.#shadow.querySelector('#sf-gh-value');
        if (ghVal) {
          ghVal.textContent = `${pct}%`;
          ghVal.classList.toggle('sf-warn', pct < 50);
          ghVal.classList.toggle('sf-red',  pct < 20);
          ghVal.classList.remove('sf-stale');
        }
        this.#lastValues.gh = pct;
      }
    }).catch(() => this.#markStale('model'));
  }

  #pollCost() {
    fetch('/api/telemetry/cost').then((r) => r.ok ? r.json() : null).then((d) => {
      if (!d) return this.#markStale('cost');
      const dollars = Number(d.session_cost_usd ?? d.total_cost_usd ?? d.cost_today ?? 0);
      const v = this.#shadow.querySelector('#sf-cost-value');
      if (v) {
        v.textContent = dollars.toFixed(2);
        v.classList.remove('sf-stale');
        const thresh = (window.chumpPrefs?.get('cost.thresholds', null)) || { warn: 0.50, red: 2.00 };
        v.classList.toggle('sf-warn', dollars >= (thresh.warn || 0.5));
        v.classList.toggle('sf-red',  dollars >= (thresh.red  || 2.0));
      }
      this.#lastValues.cost = dollars;
    }).catch(() => this.#markStale('cost'));
  }

  #pollFleet() {
    fetch('/api/fleet-status').then((r) => r.ok ? r.json() : null).then((d) => {
      if (!d) return this.#markStale('fleet');
      const agents = Array.isArray(d.agents) ? d.agents
                   : Array.isArray(d.sessions) ? d.sessions
                   : Array.isArray(d) ? d
                   : [];
      const total = agents.length;
      const healthy = agents.filter((a) => {
        const s = String(a.status || a.state || '').toLowerCase();
        return s === 'active' || s === 'working' || s === 'healthy' || s === '';
      }).length;
      const dot = this.#shadow.querySelector('#sf-fleet-dot');
      const val = this.#shadow.querySelector('#sf-fleet-value');
      if (val) { val.textContent = total === 0 ? '—' : `${healthy}/${total}`; val.classList.remove('sf-stale'); }
      if (dot) {
        if (total === 0)            { dot.textContent = '○'; dot.style.color = 'var(--text-secondary)'; }
        else if (healthy === total) { dot.textContent = '●'; dot.style.color = 'var(--success)'; }
        else if (healthy >= total/2){ dot.textContent = '●'; dot.style.color = 'var(--warn)'; }
        else                        { dot.textContent = '●'; dot.style.color = 'var(--error)'; }
      }
      this.#lastValues.fleet = { healthy, total };
    }).catch(() => this.#markStale('fleet'));
  }

  #markStale(slot) {
    const v = this.#shadow.querySelector(`#sf-${slot}-value`);
    if (v && this.#lastValues[slot] !== undefined) v.classList.add('sf-stale');
  }

  #onSlotClick(e) {
    const btn = e.target.closest('[data-slot]');
    if (!btn) return;
    const slot = btn.dataset.slot;
    const [cadence, view] = (btn.dataset.target || '').split(':');
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'footer_slot_drilled', slot, cadence_target: cadence,
        ts: new Date().toISOString(),
      }));
    } catch {}
    if (view) {
      document.dispatchEvent(new CustomEvent('chump:navigate', { detail: view }));
    }
  }

  static #truncate(s, max) {
    if (!s) return '—';
    return s.length > max ? s.slice(0, max - 1) + '…' : s;
  }
}
customElements.define('chump-status-footer', ChumpStatusFooter);

// ── <chump-model-indicator> ───────────────────────────────────────────────────
class ChumpModelIndicator extends HTMLElement {
  connectedCallback() {
    this.render('detecting…');
    this.#poll();
  }

  render(label) {
    this.innerHTML = `<span class="model-chip" title="Current model">${label}</span>`;
  }

  #poll() {
    fetch('/api/health')
      .then((r) => r.json())
      .then((d) => {
        const model = d.model_id || d.active_model || 'local';
        this.render(model);
      })
      .catch(() => this.render('offline'));
  }
}
customElements.define('chump-model-indicator', ChumpModelIndicator);

// ── <chump-heartbeat> ─────────────────────────────────────────────────────────
class ChumpHeartbeat extends HTMLElement {
  #timer = null;

  connectedCallback() {
    this.#tick();
    this.#timer = setInterval(() => this.#tick(), 15_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  #tick() {
    fetch('/api/health')
      .then((r) => r.json())
      .then((d) => {
        const ts = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        const sessions = d.active_sessions ?? '—';
        this.innerHTML = `<span class="hb-dot online" title="Agent online"></span><span class="hb-text">online · ${sessions} sessions · ${ts}</span>`;
      })
      .catch(() => {
        this.innerHTML = `<span class="hb-dot offline" title="Agent offline"></span><span class="hb-text">offline</span>`;
      });
  }
}
customElements.define('chump-heartbeat', ChumpHeartbeat);

// ── <chump-doctor-banner> (INFRA-990) ───────────────────────────────────────
//
// Persistent banner that surfaces config-health failures from
// GET /api/health/doctor. Renders nothing while ok=true. While ok=false,
// renders a sticky strip listing each failure with a "Configure" button
// linking to the settings view. Re-polls every 30s; on transition to ok=true
// shows a one-shot "✓ Configuration green" toast and self-hides.
//
// Accessibility: focusable Configure button, ARIA region label. ESC does NOT
// dismiss (AC #4) — banner is persistent until doctor goes green.
class ChumpDoctorBanner extends HTMLElement {
  #timer = null;
  #lastOk = null; // null | true | false — used to detect ok=false → ok=true transition

  connectedCallback() {
    this.setAttribute('role', 'region');
    this.setAttribute('aria-label', 'Configuration health');
    this.style.display = 'none'; // hidden until first poll resolves to ok=false
    this.#poll();
    this.#timer = setInterval(() => this.#poll(), 30_000);
  }

  disconnectedCallback() {
    if (this.#timer) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
  }

  async #poll() {
    let data;
    try {
      const r = await fetch('/api/health/doctor', { headers: { 'Accept': 'application/json' } });
      data = await r.json();
    } catch (err) {
      // Network down or endpoint missing — don't render anything; the
      // existing offline-banner already covers the "PWA can't reach itself"
      // case. Keep this widget silent.
      return;
    }

    if (data.ok === true) {
      if (this.#lastOk === false) {
        // We just transitioned from failing → green. One-shot toast.
        this.#renderToast();
        setTimeout(() => { this.style.display = 'none'; this.innerHTML = ''; }, 3000);
      } else {
        this.style.display = 'none';
        this.innerHTML = '';
      }
      this.#lastOk = true;
      return;
    }

    this.#lastOk = false;
    this.style.display = 'block';
    const failures = Array.isArray(data.failures) ? data.failures : [];
    const items = failures.map((f) => {
      const fix = f.fix_hint ? ` — <span class="fix-hint">${this.#esc(f.fix_hint)}</span>` : '';
      return `<li><strong>${this.#esc(f.check)}</strong>: ${this.#esc(f.message)}${fix}</li>`;
    }).join('');
    this.innerHTML = `
      <div class="doctor-banner-inner">
        <div class="doctor-banner-head">
          <strong>Configuration needed before fleet can run</strong>
        </div>
        <ul class="doctor-banner-list">${items}</ul>
        <div class="doctor-banner-actions">
          <button type="button" class="doctor-configure" aria-label="Open settings to configure">Configure</button>
        </div>
      </div>
    `;
    const btn = this.querySelector('.doctor-configure');
    if (btn) {
      btn.addEventListener('click', () => {
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
      });
    }
  }

  #renderToast() {
    this.style.display = 'block';
    this.innerHTML = `<div class="doctor-banner-inner doctor-banner-toast">✓ Configuration green — fleet ready</div>`;
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-doctor-banner', ChumpDoctorBanner);

// ── <chump-auth-toast> (INFRA-991) ──────────────────────────────────────────
//
// Surfaces kind=fleet_auth_fallback ambient events (emitted by src/auth.rs
// when an Anthropic 401 forces a mode swap) as actionable toasts so the
// operator can re-enter the broken credential without leaving the PWA.
//
// Subscribes to /api/ambient/stream?kind=fleet_auth_fallback (SSE — already
// exists for PRODUCT-091). Server-side kind filter means we don't process
// unrelated events. De-dup is client-side: at most one visible toast,
// counter increments on subsequent events in a 60s window.
//
// AC mapping:
//   1. EventSource subscribes to the existing endpoint
//   2. Toast renders with failed_mode + fallback_mode + "Re-enter key" button
//   3. De-dup ≤1 visible toast per 60s; counter shows "× N events in last 60s"
//   4. Auto-dismiss 5 min after last related event; manually dismissable
//   5. Test: synthetic line → toast visible within 2s (covered by SSE poll)
class ChumpAuthToast extends HTMLElement {
  #es = null;
  #count = 0;
  #lastEventTs = 0;
  #autoDismissTimer = null;
  #latestEvent = null; // most recent {failed_mode, fallback_mode}

  // De-dup window: subsequent events within this window increment the
  // counter on the visible toast instead of replacing it.
  static DEDUP_WINDOW_MS = 60_000;
  // Auto-dismiss timer: cleared and restarted on each new event.
  static AUTO_DISMISS_MS = 5 * 60_000;

  connectedCallback() {
    this.setAttribute('role', 'alert');
    this.setAttribute('aria-live', 'polite');
    this.style.display = 'none';
    this.#subscribe();
  }

  disconnectedCallback() {
    if (this.#es) {
      this.#es.close();
      this.#es = null;
    }
    if (this.#autoDismissTimer) {
      clearTimeout(this.#autoDismissTimer);
      this.#autoDismissTimer = null;
    }
  }

  #subscribe() {
    try {
      this.#es = new EventSource('/api/ambient/stream?kind=fleet_auth_fallback');
    } catch (err) {
      // EventSource unsupported — render nothing. Operator falls back to
      // tailing ambient.jsonl in a terminal (the pre-INFRA-991 status quo).
      return;
    }
    this.#es.addEventListener('ambient', (e) => {
      let payload;
      try { payload = JSON.parse(e.data); } catch { return; }
      if (payload.kind !== 'fleet_auth_fallback') return;
      this.#onEvent(payload);
    });
    this.#es.addEventListener('error', () => {
      // EventSource auto-reconnects; we just need to not crash. If the
      // server is down the doctor-banner will catch it.
    });
  }

  #onEvent(payload) {
    const now = Date.now();
    const withinWindow = (now - this.#lastEventTs) < ChumpAuthToast.DEDUP_WINDOW_MS;
    this.#lastEventTs = now;
    this.#latestEvent = payload;
    if (this.#count > 0 && withinWindow && this.style.display !== 'none') {
      this.#count += 1;
    } else {
      this.#count = 1;
    }
    this.#render();
    this.#restartAutoDismiss();
  }

  #restartAutoDismiss() {
    if (this.#autoDismissTimer) clearTimeout(this.#autoDismissTimer);
    this.#autoDismissTimer = setTimeout(() => this.#dismiss(), ChumpAuthToast.AUTO_DISMISS_MS);
  }

  #dismiss() {
    this.style.display = 'none';
    this.innerHTML = '';
    this.#count = 0;
    this.#latestEvent = null;
    if (this.#autoDismissTimer) {
      clearTimeout(this.#autoDismissTimer);
      this.#autoDismissTimer = null;
    }
  }

  #render() {
    if (!this.#latestEvent) return;
    const failed = this.#esc(this.#latestEvent.failed_mode || 'unknown');
    const fallback = this.#esc(this.#latestEvent.fallback_mode || 'unknown');
    const counter = this.#count > 1
      ? `<span class="auth-toast-counter">× ${this.#count} events in last 60s</span>`
      : '';
    this.style.display = 'block';
    this.innerHTML = `
      <div class="auth-toast-inner">
        <div class="auth-toast-head"><strong>Anthropic auth failed</strong> ${counter}</div>
        <div class="auth-toast-body">Worker fell back to <strong>${fallback}</strong> after <strong>${failed}</strong> mode failed.</div>
        <div class="auth-toast-actions">
          <button type="button" class="auth-toast-reenter">Re-enter key</button>
          <button type="button" class="auth-toast-dismiss" aria-label="Dismiss">Dismiss</button>
        </div>
      </div>
    `;
    const reenter = this.querySelector('.auth-toast-reenter');
    if (reenter) {
      reenter.addEventListener('click', () => {
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'settings' }));
      });
    }
    const dismiss = this.querySelector('.auth-toast-dismiss');
    if (dismiss) {
      dismiss.addEventListener('click', () => this.#dismiss());
    }
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-auth-toast', ChumpAuthToast);

// ── <chump-repo-switcher> (INFRA-992) ────────────────────────────────────────
//
// Surfaces multi-repo mode in the PWA header. Lets the operator switch the
// PWA's working repo without `kill + cd + restart`.
//
// Backend wired in INFRA-988's vicinity:
//   GET  /api/repo/context  → {multi_repo_enabled, effective_root, ...}
//   POST /api/repo/working  → canonicalizes path, requires .git/, behind
//                              CHUMP_MULTI_REPO_ENABLED=1 toggle (already in
//                              the SETTINGS_KEYS whitelist).
//
// When multi_repo_enabled=false this component renders nothing — the operator
// must first flip the toggle in /settings (and restart the PWA, since the
// backend reads env at process-start).
class ChumpRepoSwitcher extends HTMLElement {
  #enabled = false;
  #current = '';
  #dialogOpen = false;

  async connectedCallback() {
    this.innerHTML = '';
    await this.#refresh();
  }

  async #refresh() {
    let ctx;
    try {
      const r = await fetch('/api/repo/context');
      ctx = await r.json();
    } catch (err) {
      this.style.display = 'none';
      return;
    }
    this.#enabled = !!ctx.multi_repo_enabled;
    this.#current = String(ctx.effective_root || '');
    this.#renderChip();
  }

  #renderChip() {
    if (!this.#enabled) {
      this.style.display = 'none';
      this.innerHTML = '';
      return;
    }
    this.style.display = 'inline-flex';
    const last = this.#current.split('/').filter(Boolean).pop() || this.#current || '(none)';
    this.innerHTML = `
      <span class="repo-chip" title="${this.#esc(this.#current)}">
        <span class="repo-chip-icon" aria-hidden="true">📁</span>
        <span class="repo-chip-name">${this.#esc(last)}</span>
      </span>
      <button type="button" class="repo-switch-btn" aria-label="Switch working repo">Switch</button>
    `;
    const btn = this.querySelector('.repo-switch-btn');
    if (btn) {
      btn.addEventListener('click', () => this.#openDialog());
    }
  }

  #openDialog() {
    if (this.#dialogOpen) return;
    this.#dialogOpen = true;
    const dlg = document.createElement('div');
    dlg.className = 'repo-dialog';
    dlg.setAttribute('role', 'dialog');
    dlg.setAttribute('aria-modal', 'true');
    dlg.setAttribute('aria-label', 'Switch working repo');
    dlg.innerHTML = `
      <div class="repo-dialog-inner">
        <div class="repo-dialog-head"><strong>Switch working repo</strong></div>
        <label class="repo-dialog-label">
          Repo root path
          <input type="text" class="repo-dialog-path" placeholder="${this.#esc(this.#current)}" autocomplete="off">
        </label>
        <div class="repo-dialog-warn">
          ⚠ In-flight workflows continue against the previous repo.
          Only newly started tasks use the new binding.
        </div>
        <div class="repo-dialog-error" style="display:none"></div>
        <div class="repo-dialog-actions">
          <button type="button" class="repo-dialog-save">Save</button>
          <button type="button" class="repo-dialog-cancel">Cancel</button>
        </div>
      </div>
    `;
    this.appendChild(dlg);
    const input = dlg.querySelector('.repo-dialog-path');
    const errDiv = dlg.querySelector('.repo-dialog-error');
    const save = dlg.querySelector('.repo-dialog-save');
    const cancel = dlg.querySelector('.repo-dialog-cancel');

    const close = () => {
      dlg.remove();
      this.#dialogOpen = false;
    };
    cancel.addEventListener('click', close);
    dlg.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
    input.focus();

    save.addEventListener('click', async () => {
      const raw = (input.value || '').trim();
      if (!raw) {
        errDiv.textContent = 'Path required';
        errDiv.style.display = 'block';
        return;
      }
      save.disabled = true;
      errDiv.style.display = 'none';
      let resp, body;
      try {
        resp = await fetch('/api/repo/working', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path: raw }),
        });
        body = await resp.json();
      } catch (e) {
        save.disabled = false;
        errDiv.textContent = `Network error: ${e.message || e}`;
        errDiv.style.display = 'block';
        return;
      }
      if (resp.status === 200 && body.ok === true) {
        // Success — reload so all views re-fetch against the new repo.
        location.reload();
        return;
      }
      save.disabled = false;
      const msg = body && body.error
        ? body.error
        : `Could not switch repo (HTTP ${resp.status})`;
      errDiv.textContent = msg;
      errDiv.style.display = 'block';
    });
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-repo-switcher', ChumpRepoSwitcher);

// ── <chump-view-tasks> ────────────────────────────────────────────────────────
class ChumpViewTasks extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Tasks</h2>
        <p class="view-subtitle">Active and recent agent tasks</p>
      </section>
      <section class="task-list" id="task-list">
        <p class="placeholder">Loading tasks…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#task-list');
    fetch('/api/tasks')
      .then((r) => r.json())
      .then((tasks) => {
        if (!Array.isArray(tasks) || tasks.length === 0) {
          list.innerHTML = '<p class="placeholder">No tasks yet. Start a session to create one.</p>';
          return;
        }
        list.innerHTML = tasks.slice(0, 20).map((t) => `
          <article class="task-card">
            <header class="task-card-header">
              <span class="task-status ${t.status ?? 'unknown'}">${t.status ?? 'unknown'}</span>
              <span class="task-id">${t.id ?? ''}</span>
            </header>
            <p class="task-desc">${t.description ?? t.title ?? '(no description)'}</p>
          </article>
        `).join('');
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Could not load tasks (offline or server not running).</p>';
      });
  }
}
customElements.define('chump-view-tasks', ChumpViewTasks);

// ── <chump-view-memory> ───────────────────────────────────────────────────────
class ChumpViewMemory extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Memory</h2>
        <p class="view-subtitle">Lessons learned and persistent context</p>
      </section>
      <section class="memory-list" id="memory-list">
        <p class="placeholder">Loading memory…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#memory-list');
    fetch('/api/briefing')
      .then((r) => r.json())
      .then((d) => {
        const items = d.lessons ?? d.memories ?? [];
        if (items.length === 0) {
          list.innerHTML = '<p class="placeholder">No lessons recorded yet.</p>';
          return;
        }
        list.innerHTML = items.slice(0, 30).map((item) => `
          <article class="memory-card">
            <p class="memory-text">${typeof item === 'string' ? item : (item.content ?? item.lesson ?? JSON.stringify(item))}</p>
          </article>
        `).join('');
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Memory unavailable (offline or server not running).</p>';
      });
  }
}
customElements.define('chump-view-memory', ChumpViewMemory);

// ── <chump-parallelism-governor> ─────────────────────────────────────────────
class ChumpParallelismGovernor extends HTMLElement {
  connectedCallback() {
    // PRODUCT-098: use namespaced prefs wrapper; falls back to legacy bare key via migration.
    const saved = String(window.chumpPrefs?.get('parallelism-limit', null)
      ?? localStorage.getItem('parallelism-limit')
      ?? '4');
    this.innerHTML = `
      <label class="setting-row">
        <span class="setting-label">Parallelism Governor</span>
        <input
          type="range"
          min="1"
          max="16"
          value="${saved}"
          id="parallelism-slider"
          class="setting-slider"
          aria-label="Max concurrent operations"
        />
        <span class="setting-value" id="parallelism-value">${saved}</span>
      </label>
    `;
    this.querySelector('#parallelism-slider')?.addEventListener('change', (e) => {
      window.chumpPrefs?.set('parallelism-limit', e.target.value);
      this.querySelector('#parallelism-value').textContent = e.target.value;
      document.dispatchEvent(new CustomEvent('chump:parallelism-changed', { detail: parseInt(e.target.value) }));
    });
  }
}
customElements.define('chump-parallelism-governor', ChumpParallelismGovernor);

// ── <chump-view-decisions> ────────────────────────────────────────────────────
class ChumpViewDecisions extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Decisions</h2>
        <p class="view-subtitle">Decision channel inbox — pending actions</p>
      </section>
      <section class="decisions-list" id="decisions-list">
        <p class="placeholder">Loading decisions…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#decisions-list');
    fetch('/api/decisions')
      .then((r) => r.json())
      .then((decisions) => {
        if (!Array.isArray(decisions) || decisions.length === 0) {
          list.innerHTML = '<p class="placeholder">No pending decisions. All caught up!</p>';
          return;
        }
        list.innerHTML = decisions.slice(0, 30).map((d) => {
          const priority = d.priority || 'normal';
          const action = d.action || 'decision';
          return `
            <article class="task-card">
              <header class="task-card-header">
                <span class="task-status ${priority}">${priority}</span>
                <span class="task-id">${d.id ?? ''}</span>
              </header>
              <p class="task-desc"><strong>${action}</strong></p>
              ${d.context ? `<p class="task-desc" style="color: var(--text-secondary); font-size: 12px; margin-top: 4px;">${d.context}</p>` : ''}
            </article>
          `;
        }).join('');
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Could not load decisions (offline or server not running).</p>';
      });
  }
}
customElements.define('chump-view-decisions', ChumpViewDecisions);

// ── <chump-view-judgment> (PRODUCT-079) ───────────────────────────────────────
class ChumpViewJudgment extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Needs Your Judgment</h2>
        <p class="view-subtitle">Gaps and events waiting on operator input</p>
      </section>
      <section class="task-list" id="judgment-list">
        <p class="placeholder">Loading…</p>
      </section>
    `;
    this.#load();
  }

  #load() {
    const list = this.querySelector('#judgment-list');
    fetch('/api/needs-judgment')
      .then((r) => r.json())
      .then((data) => {
        const items = data.items ?? [];
        if (items.length === 0) {
          const ago = data.last_decision_ts
            ? `Last operator decision: ${data.last_decision_ts}`
            : 'No prior decisions recorded';
          list.innerHTML = `<p class="placeholder">Fleet is moving without you. ${ago}</p>`;
          return;
        }
        list.innerHTML = items.map((item) => `
          <article class="task-card" data-id="${item.id}" data-type="${item.item_type}">
            <header class="task-card-header">
              <span class="task-status ${item.item_type}">${item.item_type}</span>
              <span class="task-id">${item.id}</span>
              ${item.priority ? `<span style="margin-left:auto;font-size:11px;opacity:.7">${item.priority}</span>` : ''}
            </header>
            <p class="task-desc">${item.summary ?? '(no summary)'}</p>
            ${item.recommended_action ? `<p class="task-desc" style="color:var(--text-secondary);font-size:12px">${item.recommended_action}</p>` : ''}
            <button class="judgment-ack-btn" style="margin-top:8px;padding:4px 10px;cursor:pointer;border-radius:4px;border:1px solid var(--border-color);background:transparent;color:var(--text-primary);font-size:12px"
              data-id="${item.id}" data-type="${item.item_type}">Mark handled</button>
          </article>
        `).join('');

        list.querySelectorAll('.judgment-ack-btn').forEach((btn) => {
          btn.addEventListener('click', () => this.#ack(btn.dataset.id, btn.dataset.type, btn));
        });
      })
      .catch(() => {
        list.innerHTML = '<p class="placeholder">Could not load (offline or server not running).</p>';
      });
  }

  #ack(itemId, itemType, btn) {
    btn.disabled = true;
    btn.textContent = 'Marking…';
    fetch('/api/needs-judgment/ack', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ item_type: itemType, item_id: itemId }),
    })
      .then(() => {
        const card = btn.closest('article');
        if (card) card.style.opacity = '0.4';
        btn.textContent = 'Handled';
      })
      .catch(() => {
        btn.disabled = false;
        btn.textContent = 'Mark handled';
      });
  }
}
customElements.define('chump-view-judgment', ChumpViewJudgment);

// ── <chump-view-audit> (PRODUCT-111) ────────────────────────────────────────
// Decision-chain audit panel. Consolidates /api/tool-approval-audit +
// /api/cos/decisions into one chronological feed for archetype 4 (enterprise
// auditor) per docs/design/OPERATOR_CONSOLE_V2.md.
//
// "We let an AI commit code" goes from trust-me-bro to a defensible audit
// trail when this view ships: every tool approval, every COS decision, every
// outcome, exportable as JSONL.
//
// Filter dimensions:
//   - Time window: 1h | 24h (default) | 7d | all
//   - Decision kind: tool_approval | cos | (more as endpoints land)
//   - Session ID (click any session_id in a row to filter to it)
//   - Gap ID (click any gap_id to filter)
//
// Export: visible rows → JSONL download. Useful for the CTO screenshot
// use case.
class ChumpViewAudit extends HTMLElement {
  #rows = [];       // merged chronological list
  #filtered = [];   // post-filter
  #filters = { window: '24h', kind: '', session: '', gap: '' };
  #expanded = new Set(); // request_id / decision_id of rows expanded inline

  connectedCallback() {
    // Restore filter state from chumpPrefs (INFRA-1280).
    const stored = window.chumpPrefs?.get('audit.filters', null);
    if (stored && typeof stored === 'object') {
      Object.assign(this.#filters, stored);
    }
    this.innerHTML = `
      <section class="view-header">
        <h2>Audit</h2>
        <p class="view-subtitle">Tool approvals + COS decisions chronological — defensible record of every agent action</p>
      </section>
      <section class="audit-toolbar" role="toolbar" aria-label="Audit filters">
        <div class="audit-chips" role="radiogroup" aria-label="Time window">
          ${['1h', '24h', '7d', 'all'].map((w) => `
            <button type="button" class="audit-chip" data-window="${w}"
                    aria-pressed="${this.#filters.window === w ? 'true' : 'false'}">${w}</button>
          `).join('')}
        </div>
        <div class="audit-chips" role="radiogroup" aria-label="Decision kind">
          ${[['', 'all kinds'], ['tool_approval', 'tool'], ['cos', 'COS']].map(([k, lbl]) => `
            <button type="button" class="audit-chip" data-kind="${k}"
                    aria-pressed="${this.#filters.kind === k ? 'true' : 'false'}">${lbl}</button>
          `).join('')}
        </div>
        <input type="search" class="audit-search" placeholder="Filter by session / gap"
               aria-label="Filter by session ID or gap ID"
               value="${this.#escAttr(this.#filters.session || this.#filters.gap || '')}">
        <button type="button" class="audit-export" aria-label="Export visible rows as JSONL">Export JSONL</button>
        <button type="button" class="audit-clear" aria-label="Clear filters">Clear</button>
      </section>
      <section class="audit-stats" id="audit-stats" aria-live="polite"></section>
      <section class="audit-list" id="audit-list" aria-live="polite" aria-busy="true">
        <p class="placeholder">Loading audit feed…</p>
      </section>
    `;
    this.#wireToolbar();
    this.#load();
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }
  #pollTimer = null;

  #wireToolbar() {
    this.querySelectorAll('[data-window]').forEach((b) => {
      b.addEventListener('click', () => { this.#filters.window = b.dataset.window; this.#persist(); this.#load(); });
    });
    this.querySelectorAll('[data-kind]').forEach((b) => {
      b.addEventListener('click', () => { this.#filters.kind = b.dataset.kind; this.#persist(); this.#render(); });
    });
    this.querySelector('.audit-search')?.addEventListener('input', (e) => {
      // Heuristic: if input looks like a gap ID (X-NNN), filter by gap; else session.
      const v = e.target.value.trim();
      if (/^[A-Z]+-\d+$/i.test(v)) { this.#filters.gap = v; this.#filters.session = ''; }
      else { this.#filters.session = v; this.#filters.gap = ''; }
      this.#persist();
      this.#render();
    });
    this.querySelector('.audit-export')?.addEventListener('click', () => this.#export());
    this.querySelector('.audit-clear')?.addEventListener('click', () => this.#clearFilters());
    this.querySelector('#audit-list')?.addEventListener('click', (e) => this.#onRowClick(e));
  }

  #persist() {
    window.chumpPrefs?.set('audit.filters', this.#filters);
  }

  #clearFilters() {
    this.#filters = { window: '24h', kind: '', session: '', gap: '' };
    this.#persist();
    // Reset visual state.
    this.querySelectorAll('[data-window]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.window === '24h' ? 'true' : 'false'));
    this.querySelectorAll('[data-kind]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.kind === '' ? 'true' : 'false'));
    const s = this.querySelector('.audit-search'); if (s) s.value = '';
    this.#load();
  }

  async #load() {
    const list = this.querySelector('#audit-list');
    if (list) list.setAttribute('aria-busy', 'true');
    const w = this.#filters.window;
    const sinceParam = w === 'all' ? '' : `?since=${w}`;
    try {
      const [toolR, cosR] = await Promise.all([
        fetch(`/api/tool-approval-audit${sinceParam}`).then((r) => r.ok ? r.json() : null).catch(() => null),
        fetch(`/api/cos/decisions${sinceParam}`).then((r) => r.ok ? r.json() : null).catch(() => null),
      ]);
      const toolRows = (toolR?.rows || toolR || []).map((r) => ({
        ts: r.ts || r.timestamp || r.decided_at || r.ts_iso || '',
        kind: 'tool_approval',
        session_id: r.session_id || r.session || '',
        gap_id: r.gap_id || r.gap || '',
        summary: r.tool_name ? `${r.tool_name} → ${r.allowed === true ? 'approved' : r.allowed === false ? 'denied' : '?'}` : (r.summary || '(no summary)'),
        outcome: r.allowed === true ? 'approved' : r.allowed === false ? 'denied' : (r.outcome || 'unknown'),
        payload: r,
      }));
      const cosRows = (cosR?.rows || cosR || []).map((r) => ({
        ts: r.ts || r.timestamp || r.decided_at || r.ts_iso || '',
        kind: 'cos',
        session_id: r.session_id || r.session || '',
        gap_id: r.gap_id || r.gap || '',
        summary: r.decision || r.reason || r.summary || '(no summary)',
        outcome: r.outcome || r.action || 'logged',
        payload: r,
      }));
      this.#rows = [...toolRows, ...cosRows].sort((a, b) => (b.ts || '').localeCompare(a.ts || ''));
      this.#render();
    } catch (err) {
      if (list) list.innerHTML = `<p class="placeholder">Could not load audit feed: ${this.#esc(String(err))}</p>`;
    }
    if (list) list.setAttribute('aria-busy', 'false');
  }

  #render() {
    const stats = this.querySelector('#audit-stats');
    const list = this.querySelector('#audit-list');
    if (!stats || !list) return;
    const f = this.#filters;
    this.#filtered = this.#rows.filter((r) => {
      if (f.kind && r.kind !== f.kind) return false;
      if (f.session && !r.session_id.includes(f.session)) return false;
      if (f.gap && !r.gap_id.toUpperCase().includes(f.gap.toUpperCase())) return false;
      return true;
    });
    stats.innerHTML = `
      <span class="audit-stat">${this.#filtered.length}</span> rows
      <span class="audit-stat-sep">·</span>
      <span class="audit-stat">${this.#rows.length}</span> total in window
      <span class="audit-stat-sep">·</span>
      <span class="audit-stat">${this.#rows.filter((r) => r.kind === 'tool_approval').length}</span> tool
      <span class="audit-stat-sep">·</span>
      <span class="audit-stat">${this.#rows.filter((r) => r.kind === 'cos').length}</span> cos
    `;
    if (this.#filtered.length === 0) {
      list.innerHTML = `<p class="placeholder">No decisions in the selected window/filter — fleet has been quiet (or your filters are too narrow).</p>`;
      return;
    }
    list.innerHTML = `
      <table class="audit-table" role="grid">
        <thead>
          <tr>
            <th scope="col">when</th>
            <th scope="col">kind</th>
            <th scope="col">session</th>
            <th scope="col">gap</th>
            <th scope="col">summary</th>
            <th scope="col">outcome</th>
          </tr>
        </thead>
        <tbody>
          ${this.#filtered.map((r, i) => this.#renderRow(r, i)).join('')}
        </tbody>
      </table>
    `;
  }

  #renderRow(r, i) {
    const rowId = `audit-row-${i}`;
    const isExpanded = this.#expanded.has(rowId);
    const outcomeClass = r.outcome === 'approved' ? 'audit-outcome-ok'
                       : r.outcome === 'denied'   ? 'audit-outcome-bad'
                       : 'audit-outcome-info';
    return `
      <tr class="audit-row" data-row-id="${rowId}" tabindex="0">
        <td class="audit-cell-ts">${this.#fmtTs(r.ts)}</td>
        <td class="audit-cell-kind"><span class="audit-kind audit-kind-${r.kind}">${r.kind}</span></td>
        <td class="audit-cell-session"><button type="button" class="audit-pill" data-filter-session="${this.#escAttr(r.session_id)}">${this.#shortSession(r.session_id)}</button></td>
        <td class="audit-cell-gap">${r.gap_id ? `<button type="button" class="audit-pill" data-filter-gap="${this.#escAttr(r.gap_id)}">${this.#esc(r.gap_id)}</button>` : '—'}</td>
        <td class="audit-cell-summary">${this.#esc(r.summary).slice(0, 200)}</td>
        <td class="audit-cell-outcome"><span class="audit-outcome ${outcomeClass}">${r.outcome}</span></td>
      </tr>
      ${isExpanded ? `<tr class="audit-row-expansion"><td colspan="6"><pre><code>${this.#esc(JSON.stringify(r.payload, null, 2))}</code></pre></td></tr>` : ''}
    `;
  }

  #onRowClick(e) {
    // Click on a session/gap pill → set filter.
    const sessBtn = e.target.closest('[data-filter-session]');
    if (sessBtn) {
      this.#filters.session = sessBtn.dataset.filterSession;
      this.#filters.gap = '';
      this.#persist();
      const s = this.querySelector('.audit-search'); if (s) s.value = this.#filters.session;
      this.#render();
      e.stopPropagation();
      return;
    }
    const gapBtn = e.target.closest('[data-filter-gap]');
    if (gapBtn) {
      this.#filters.gap = gapBtn.dataset.filterGap;
      this.#filters.session = '';
      this.#persist();
      const s = this.querySelector('.audit-search'); if (s) s.value = this.#filters.gap;
      this.#render();
      e.stopPropagation();
      return;
    }
    // Click on the row body → toggle expansion.
    const tr = e.target.closest('.audit-row');
    if (!tr) return;
    const id = tr.dataset.rowId;
    if (this.#expanded.has(id)) this.#expanded.delete(id);
    else this.#expanded.add(id);
    this.#render();
  }

  #export() {
    const jsonl = this.#filtered.map((r) => JSON.stringify(r.payload)).join('\n');
    const blob = new Blob([jsonl], { type: 'application/x-ndjson' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    a.href = url;
    a.download = `chump-audit-${stamp}.jsonl`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'audit_view_session', action: 'exported',
        rows_exported: this.#filtered.length,
        ts: new Date().toISOString(),
      }));
    } catch {}
  }

  // helpers
  #esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  #escAttr(s) { return this.#esc(s); }
  #shortSession(sid) {
    const m = String(sid).match(/^(?:claim-)?([a-z]+-\d+)/i);
    return m ? m[1] : (String(sid).slice(0, 16) + (sid.length > 16 ? '…' : ''));
  }
  #fmtTs(ts) {
    if (!ts) return '—';
    try {
      const d = new Date(ts);
      if (isNaN(d.getTime())) return ts;
      // Relative for recent, absolute else
      const ageS = (Date.now() - d.getTime()) / 1000;
      if (ageS < 60) return `${Math.round(ageS)}s ago`;
      if (ageS < 3600) return `${Math.round(ageS / 60)}m ago`;
      if (ageS < 86400) return `${Math.round(ageS / 3600)}h ago`;
      return d.toISOString().slice(0, 16).replace('T', ' ');
    } catch { return ts; }
  }
}
customElements.define('chump-view-audit', ChumpViewAudit);

// ── <chump-view-network-audit> (PRODUCT-112) ────────────────────────────────
// Archetype 1 (offline solo dev) trust signal. The status footer air-gap
// slot drills here. Renders a chronological list of outbound HTTP requests
// Chump has made — sourced from /api/ambient/recent filtered to the
// outbound-network event kinds (github_api_call, outbound_http_call,
// bash_call with curl/wget).
//
// Behavior per docs/design/OPERATOR_CONSOLE_V2.md (archetype 1):
//   - When air-gap mode is on AND any non-github row appears: red banner
//     "WARN — air-gap claim violated by N outbound calls"
//   - When air-gap mode is on AND ZERO non-github rows: empty state
//     celebrates the win ("No outbound traffic. Air-gap claim holds.")
//   - github.com is the documented exception (PR ship pipeline) — shown
//     in a footnote, never triggers a violation banner
//
// Time window: last 10m / 1h / 24h / since-process-start. Defaults to 1h.
class ChumpViewNetworkAudit extends HTMLElement {
  #rows = [];
  #airgap = null; // true | false | null
  #window = '1h';
  #pollTimer = null;

  connectedCallback() {
    this.#window = window.chumpPrefs?.get('network.window', '1h') || '1h';
    this.innerHTML = `
      <section class="view-header">
        <h2>Network audit</h2>
        <p class="view-subtitle">Outbound HTTP calls since process start — archetype-1 air-gap trust signal</p>
      </section>
      <section class="netaudit-banner" id="netaudit-banner" hidden></section>
      <section class="netaudit-toolbar" role="toolbar" aria-label="Network audit window">
        <div class="netaudit-chips" role="radiogroup" aria-label="Time window">
          ${['10m', '1h', '24h', 'all'].map((w) => `
            <button type="button" class="netaudit-chip" data-window="${w}"
                    aria-pressed="${this.#window === w ? 'true' : 'false'}">${w}</button>
          `).join('')}
        </div>
        <button type="button" class="netaudit-export" aria-label="Export visible rows as JSONL">Export JSONL</button>
      </section>
      <section class="netaudit-stats" id="netaudit-stats" aria-live="polite"></section>
      <section class="netaudit-list" id="netaudit-list" aria-live="polite" aria-busy="true">
        <p class="placeholder">Loading network audit…</p>
      </section>
      <footer class="netaudit-footnote">
        Note: <code>github.com</code> / <code>api.github.com</code> are documented
        exceptions for the PR ship pipeline. They do not violate the air-gap claim.
      </footer>
    `;
    this.querySelectorAll('[data-window]').forEach((b) => {
      b.addEventListener('click', () => { this.#window = b.dataset.window; window.chumpPrefs?.set('network.window', this.#window); this.#load(); });
    });
    this.querySelector('.netaudit-export')?.addEventListener('click', () => this.#export());
    this.#load();
    // Auto-refresh every 30s so a fresh outbound call appears quickly.
    this.#pollTimer = setInterval(() => this.#load(), 30_000);
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'network_audit_viewed',
        window: this.#window,
        ts: new Date().toISOString(),
      }));
    } catch {}
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  async #load() {
    const list = this.querySelector('#netaudit-list');
    if (list) list.setAttribute('aria-busy', 'true');
    try {
      // Pull air-gap mode in parallel with the ambient tail.
      const [stack, ambient] = await Promise.all([
        fetch('/api/stack-status').then((r) => r.ok ? r.json() : null).catch(() => null),
        fetch(`/api/ambient/recent?n=500&kind=github_api_call,outbound_http_call`).then((r) => r.ok ? r.json() : null).catch(() => null),
      ]);
      this.#airgap = stack?.air_gap_mode === true;
      const events = ambient?.events || ambient?.rows || ambient || [];
      const sinceMs = this.#windowSinceMs();
      this.#rows = events
        .map((e) => this.#normalise(e))
        .filter((r) => r.host)
        .filter((r) => sinceMs == null || r.ts_ms >= sinceMs)
        .sort((a, b) => b.ts_ms - a.ts_ms);
      this.#render();
    } catch (err) {
      if (list) list.innerHTML = `<p class="placeholder">Could not load network audit: ${this.#esc(String(err))}</p>`;
    }
    if (list) list.setAttribute('aria-busy', 'false');
  }

  #windowSinceMs() {
    const now = Date.now();
    switch (this.#window) {
      case '10m': return now - 10 * 60 * 1000;
      case '1h':  return now - 60 * 60 * 1000;
      case '24h': return now - 24 * 60 * 60 * 1000;
      case 'all': return null;
      default:    return now - 60 * 60 * 1000;
    }
  }

  #normalise(e) {
    // Map heterogeneous ambient kinds to a uniform row shape.
    const ts = e.ts || e.timestamp || '';
    const ts_ms = (() => {
      try { return new Date(ts).getTime() || 0; } catch { return 0; }
    })();
    const kind = e.kind || e.event || '';
    let host = '', path = '', initiated_by = '';
    if (kind === 'github_api_call') {
      host = 'api.github.com';
      path = e.api || e.endpoint || '';
      initiated_by = e.script || e.session || 'gh';
    } else if (kind === 'outbound_http_call') {
      host = e.host || e.url?.split('/')[2] || '';
      path = e.path || (e.url || '').slice(host ? e.url.indexOf(host) + host.length : 0);
      initiated_by = e.source || e.module || 'unknown';
    } else {
      host = e.host || '';
      path = e.path || '';
      initiated_by = e.source || '';
    }
    return { ts, ts_ms, kind, host, path, initiated_by, bytes: e.bytes ?? null, payload: e };
  }

  #render() {
    const banner = this.querySelector('#netaudit-banner');
    const stats = this.querySelector('#netaudit-stats');
    const list = this.querySelector('#netaudit-list');
    if (!banner || !stats || !list) return;

    const total = this.#rows.length;
    const githubOnly = this.#rows.filter((r) => /github\.com$/i.test(r.host));
    const nonGithub = this.#rows.filter((r) => !/github\.com$/i.test(r.host));
    stats.innerHTML = `
      <span class="netaudit-stat">${total}</span> total
      <span class="netaudit-stat-sep">·</span>
      <span class="netaudit-stat">${githubOnly.length}</span> github (exception)
      <span class="netaudit-stat-sep">·</span>
      <span class="netaudit-stat ${nonGithub.length > 0 && this.#airgap ? 'netaudit-stat-violation' : ''}">${nonGithub.length}</span> non-github
    `;

    if (this.#airgap === true) {
      if (nonGithub.length > 0) {
        banner.hidden = false;
        banner.className = 'netaudit-banner netaudit-banner-violation';
        banner.innerHTML = `⛔ <strong>WARN</strong> — air-gap claim violated by ${nonGithub.length} outbound call${nonGithub.length === 1 ? '' : 's'} in the selected window. Investigate immediately.`;
      } else {
        banner.hidden = false;
        banner.className = 'netaudit-banner netaudit-banner-ok';
        banner.innerHTML = `● <strong>Air-gap holds</strong> — no outbound non-github traffic in the selected window. ${githubOnly.length} github call${githubOnly.length === 1 ? '' : 's'} (documented exception).`;
      }
    } else if (this.#airgap === false) {
      banner.hidden = false;
      banner.className = 'netaudit-banner netaudit-banner-info';
      banner.innerHTML = `Air-gap mode is OFF. To enable: set <code>CHUMP_AIR_GAP_MODE=1</code> and restart <code>chump --web</code>.`;
    } else {
      banner.hidden = true;
    }

    if (total === 0) {
      const msg = this.#airgap === true
        ? `No outbound traffic in the last ${this.#window}. Air-gap claim holds — celebrate the offline win.`
        : `No outbound traffic in the last ${this.#window}.`;
      list.innerHTML = `<p class="placeholder">${msg}</p>`;
      return;
    }
    list.innerHTML = `
      <table class="netaudit-table" role="grid">
        <thead><tr>
          <th scope="col">when</th>
          <th scope="col">host</th>
          <th scope="col">path</th>
          <th scope="col">via</th>
        </tr></thead>
        <tbody>
          ${this.#rows.map((r) => this.#renderRow(r)).join('')}
        </tbody>
      </table>
    `;
  }

  #renderRow(r) {
    const isGithub = /github\.com$/i.test(r.host);
    const exceptionTag = isGithub ? '<span class="netaudit-pill netaudit-pill-ok">exception</span>' : '';
    return `
      <tr class="netaudit-row ${isGithub ? '' : 'netaudit-row-nongithub'}">
        <td class="netaudit-cell-ts">${this.#fmtTs(r.ts)}</td>
        <td class="netaudit-cell-host">${this.#esc(r.host)} ${exceptionTag}</td>
        <td class="netaudit-cell-path">${this.#esc((r.path || '').slice(0, 240))}</td>
        <td class="netaudit-cell-via">${this.#esc(r.initiated_by)}</td>
      </tr>
    `;
  }

  #export() {
    const jsonl = this.#rows.map((r) => JSON.stringify(r.payload)).join('\n');
    const blob = new Blob([jsonl], { type: 'application/x-ndjson' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    a.href = url;
    a.download = `chump-network-audit-${stamp}.jsonl`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'network_audit_exported',
        rows: this.#rows.length,
        window: this.#window,
        ts: new Date().toISOString(),
      }));
    } catch {}
  }

  #fmtTs(ts) {
    if (!ts) return '—';
    try {
      const d = new Date(ts);
      if (isNaN(d.getTime())) return ts;
      // Relative for recent, absolute else
      const ageS = (Date.now() - d.getTime()) / 1000;
      if (ageS < 60) return `${Math.round(ageS)}s ago`;
      if (ageS < 3600) return `${Math.round(ageS / 60)}m ago`;
      if (ageS < 86400) return `${Math.round(ageS / 3600)}h ago`;
      return d.toISOString().slice(0, 16).replace('T', ' ');
    } catch { return ts; }
  }

  #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
}
customElements.define('chump-view-network-audit', ChumpViewNetworkAudit);

// ── <chump-view-fleet-health> (INFRA-1203) ──────────────────────────────────
// Fleet operator's morning "how is everything?" view. Per
// docs/design/OPERATOR_CONSOLE_V2.md §footer: this view is the drill-in for
// the 4 pillar grades + KPI strip + SLO breach list + GraphQL budget.
//
// Lives in AMBIENT cadence as 'health' sub-tab. The status footer
// (PRODUCT-107) pillar slot click-drills here.
//
// Backend endpoint /api/fleet/health doesn't exist yet (file backend follow-up
// gap). For the MVP this view composes existing endpoints:
//   - /api/stack-status (rate_limit + cognitive_control fields)
//   - /api/dashboard (fleet_status + last_heartbeat_iso + fleet_status_reason)
//   - /api/telemetry/cost (cost burn)
//   - chumpPrefs cost.thresholds (operator-tunable warn/red bands)
//
// Pillar grades use placeholder dashes today; when a real grading endpoint
// ships (file as INFRA-NEW), the panel will wire to it. The structural shell
// is here so the wiring is a 30-line addition rather than a new view.
class ChumpViewFleetHealth extends HTMLElement {
  #pollTimer = null;
  #last = { stack: null, dashboard: null, cost: null };

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Fleet health</h2>
        <p class="view-subtitle">Pillars · KPIs · SLOs · API budget — the operator HUD drill-in</p>
      </section>
      <section class="fh-grid">
        <article class="fh-panel fh-pillars">
          <header class="fh-panel-header"><h3>🏛 Pillar grades</h3></header>
          <div class="fh-pillar-quadrant" id="fh-pillar-quadrant">
            ${['effective','credible','resilient','zero-waste'].map((p) => `
              <div class="fh-pillar-cell fh-pillar-${p}" data-pillar="${p}">
                <span class="fh-pillar-label">${p.toUpperCase()}</span>
                <span class="fh-pillar-grade" id="fh-grade-${p}">—</span>
                <span class="fh-pillar-trend" id="fh-trend-${p}"></span>
              </div>
            `).join('')}
          </div>
          <p class="fh-panel-footnote">
            Live grading endpoint pending — placeholder shows the slot.
            Run <code>chump mission-grade</code> in a terminal for current grades.
          </p>
        </article>
        <article class="fh-panel fh-kpis">
          <header class="fh-panel-header"><h3>📈 KPI strip</h3></header>
          <div class="fh-kpis-grid">
            <div class="fh-kpi">
              <span class="fh-kpi-value" id="fh-kpi-fleet">—</span>
              <span class="fh-kpi-label">fleet</span>
            </div>
            <div class="fh-kpi">
              <span class="fh-kpi-value" id="fh-kpi-cost">$—</span>
              <span class="fh-kpi-label">cost / session</span>
            </div>
            <div class="fh-kpi">
              <span class="fh-kpi-value" id="fh-kpi-heartbeat">—</span>
              <span class="fh-kpi-label">last heartbeat</span>
            </div>
            <div class="fh-kpi">
              <span class="fh-kpi-value" id="fh-kpi-ships">—</span>
              <span class="fh-kpi-label">ships (24h, rough)</span>
            </div>
          </div>
        </article>
        <article class="fh-panel fh-slos">
          <header class="fh-panel-header"><h3>🎯 SLO status</h3></header>
          <ul class="fh-slo-list" id="fh-slo-list">
            <li class="placeholder">Loading SLO check…</li>
          </ul>
          <p class="fh-panel-footnote">
            Sourced from <code>fleet_status_reason</code> on <code>/api/dashboard</code> (INFRA-1206). Click <a href="/v2/?view=settings">CONFIG → Settings</a> to tune thresholds.
          </p>
        </article>
        <article class="fh-panel fh-budget">
          <header class="fh-panel-header"><h3>🔋 GraphQL budget</h3></header>
          <div class="fh-budget-gauge">
            <div class="fh-budget-bar"><div class="fh-budget-fill" id="fh-budget-fill" style="width:0%"></div></div>
            <span class="fh-budget-pct" id="fh-budget-pct">—</span>
          </div>
          <p class="fh-panel-footnote" id="fh-budget-footnote">
            Loading rate-limit state…
          </p>
        </article>
      </section>
    `;
    this.#load();
    this.#pollTimer = setInterval(() => this.#load(), 30_000);
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'fleet_health_view_session', ts: new Date().toISOString(),
      }));
    } catch {}
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  async #load() {
    const [stack, dash, cost, fleet] = await Promise.all([
      fetch('/api/stack-status').then((r) => r.ok ? r.json() : null).catch(() => null),
      fetch('/api/dashboard').then((r) => r.ok ? r.json() : null).catch(() => null),
      fetch('/api/telemetry/cost').then((r) => r.ok ? r.json() : null).catch(() => null),
      fetch('/api/fleet-status').then((r) => r.ok ? r.json() : null).catch(() => null),
    ]);
    this.#last = { stack, dashboard: dash, cost, fleet };

    // ── KPI strip ─────────────────────────────────────────────────────────
    const fleetEl = this.querySelector('#fh-kpi-fleet');
    if (fleetEl) {
      const agents = Array.isArray(fleet?.agents) ? fleet.agents
                  : Array.isArray(fleet?.sessions) ? fleet.sessions
                  : Array.isArray(fleet) ? fleet : [];
      fleetEl.textContent = agents.length === 0 ? '—' : `${agents.length}`;
    }
    const costEl = this.querySelector('#fh-kpi-cost');
    if (costEl) {
      const d = Number(cost?.session_cost_usd ?? cost?.total_cost_usd ?? 0);
      costEl.textContent = '$' + d.toFixed(2);
      const t = (window.chumpPrefs?.get('cost.thresholds', null)) || { warn: 0.5, red: 2.0 };
      costEl.classList.toggle('fh-kpi-warn', d >= t.warn);
      costEl.classList.toggle('fh-kpi-red',  d >= t.red);
    }
    const hbEl = this.querySelector('#fh-kpi-heartbeat');
    if (hbEl) {
      const hb = dash?.last_heartbeat_iso || '';
      if (hb) {
        try {
          const dt = new Date(hb);
          const ageS = (Date.now() - dt.getTime()) / 1000;
          hbEl.textContent = ageS < 60 ? `${Math.round(ageS)}s` : ageS < 3600 ? `${Math.round(ageS/60)}m` : ageS < 86400 ? `${Math.round(ageS/3600)}h` : '>1d';
        } catch { hbEl.textContent = '?'; }
      } else hbEl.textContent = '—';
    }
    const shipsEl = this.querySelector('#fh-kpi-ships');
    if (shipsEl) {
      // Best-effort: count "Round … ok" lines in ship_log_tail (rough proxy).
      const tail = dash?.ship_log_tail || [];
      const rounds = Array.isArray(tail) ? tail.filter((l) => /Round.*\) ok/.test(String(l))).length : 0;
      shipsEl.textContent = String(rounds);
    }

    // ── SLO list (from fleet_status + reason — INFRA-1206 surface) ────────
    const sloList = this.querySelector('#fh-slo-list');
    if (sloList) {
      const status = dash?.fleet_status || 'unknown';
      const reason = dash?.fleet_status_reason || null;
      const items = [];
      const colorCls = status === 'green' ? 'fh-slo-ok' : status === 'amber' || status === 'yellow' ? 'fh-slo-warn' : 'fh-slo-bad';
      items.push(`<li class="fh-slo-row ${colorCls}">
        <span class="fh-slo-name">overall</span>
        <span class="fh-slo-status">${this.#esc(status)}</span>
        ${reason ? `<span class="fh-slo-reason">${this.#esc(reason)}</span>` : ''}
      </li>`);
      // GraphQL budget as a synthetic SLO ("≥20% remaining")
      const rl = stack?.github_rate_limit || stack?.gh_rate_limit;
      if (rl && typeof rl.graphql_remaining === 'number' && typeof rl.graphql_limit === 'number') {
        const pct = Math.round((rl.graphql_remaining / Math.max(1, rl.graphql_limit)) * 100);
        const cls = pct < 20 ? 'fh-slo-bad' : pct < 50 ? 'fh-slo-warn' : 'fh-slo-ok';
        items.push(`<li class="fh-slo-row ${cls}">
          <span class="fh-slo-name">github graphql ≥ 20%</span>
          <span class="fh-slo-status">${pct}%</span>
        </li>`);
      }
      sloList.innerHTML = items.join('');
    }

    // ── GraphQL budget gauge ──────────────────────────────────────────────
    const fill = this.querySelector('#fh-budget-fill');
    const pctEl = this.querySelector('#fh-budget-pct');
    const fn = this.querySelector('#fh-budget-footnote');
    const rl = stack?.github_rate_limit || stack?.gh_rate_limit;
    if (fill && pctEl) {
      if (rl && typeof rl.graphql_remaining === 'number' && typeof rl.graphql_limit === 'number') {
        const pct = Math.round((rl.graphql_remaining / Math.max(1, rl.graphql_limit)) * 100);
        fill.style.width = pct + '%';
        fill.classList.toggle('fh-bar-warn', pct < 50);
        fill.classList.toggle('fh-bar-red',  pct < 20);
        pctEl.textContent = pct + '%';
        if (fn) fn.textContent = `Remaining: ${rl.graphql_remaining} / ${rl.graphql_limit}${rl.reset ? `, resets ${new Date(rl.reset * 1000).toLocaleTimeString()}` : ''}`;
      } else {
        pctEl.textContent = 'n/a';
        if (fn) fn.textContent = 'Rate-limit state unavailable from /api/stack-status (gh_rate_limit field absent).';
      }
    }
  }

  #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
}
customElements.define('chump-view-fleet-health', ChumpViewFleetHealth);

// ── <chump-view-coord> (INFRA-1204) ─────────────────────────────────────────
// A2A coordination panel — inbox + INTENT board + PR-nudge log in one pane.
// Surfaces the consumer side of INFRA-1115 (mailboxes), INFRA-1116 (INTENT
// gate), INFRA-1117 (chump-pr-nudge) so operators can MONITOR multi-agent
// coordination in real time + intervene (force-override an INTENT, mark
// nudge as acked, peek at any session's inbox).
//
// Sits in AMBIENT cadence per docs/design/OPERATOR_CONSOLE_V2.md §canvas.
//
// Three panels stacked:
//   1. INBOX     — /api/inbox/{session} for the operator's chosen session
//                  + dropdown to pick from recently-active sessions
//   2. INTENT    — /api/ambient/recent?kind=intent_announced (last 5min,
//                  filtered to entries with no matching CLAIM within 60s)
//   3. NUDGES    — /api/ambient/recent?kind=pr_nudge_emitted (last 24h)
class ChumpViewCoord extends HTMLElement {
  #pollTimer = null;
  #selectedSession = null;
  #sessions = [];      // [{id, last_event_ts}]
  #inbox = [];
  #intents = [];
  #nudges = [];

  connectedCallback() {
    this.#selectedSession = window.chumpPrefs?.get('coord.session', null) || null;
    this.innerHTML = `
      <section class="view-header">
        <h2>Coordination</h2>
        <p class="view-subtitle">Inbox + INTENT board + PR-nudge log — the a2a consumption side</p>
      </section>
      <section class="coord-panels">
        <article class="coord-panel coord-inbox">
          <header class="coord-panel-header">
            <h3>📬 Inbox</h3>
            <label class="coord-session-picker">
              session
              <select id="coord-session-select" aria-label="Select inbox session"></select>
            </label>
            <span class="coord-stat" id="coord-inbox-count">…</span>
          </header>
          <ul class="coord-list" id="coord-inbox-list" aria-live="polite">
            <li class="placeholder">Loading inbox…</li>
          </ul>
        </article>
        <article class="coord-panel coord-intents">
          <header class="coord-panel-header">
            <h3>🎯 INTENT board</h3>
            <span class="coord-stat" id="coord-intents-count">…</span>
          </header>
          <ul class="coord-list" id="coord-intents-list" aria-live="polite">
            <li class="placeholder">Loading INTENT events…</li>
          </ul>
          <p class="coord-panel-footnote">
            Recent INTENT announcements (last 5 min). Operators can override a stale INTENT via <code>scripts/coord/broadcast.sh</code>.
          </p>
        </article>
        <article class="coord-panel coord-nudges">
          <header class="coord-panel-header">
            <h3>🔔 PR-nudge log</h3>
            <span class="coord-stat" id="coord-nudges-count">…</span>
          </header>
          <ul class="coord-list" id="coord-nudges-list" aria-live="polite">
            <li class="placeholder">Loading nudge log…</li>
          </ul>
          <p class="coord-panel-footnote">
            chump-pr-nudge.sh history — 5 classes: dirty / blocked-ci / orphan-disarmed / base-modified / clean-not-merged.
          </p>
        </article>
      </section>
    `;
    this.querySelector('#coord-session-select')?.addEventListener('change', (e) => {
      this.#selectedSession = e.target.value || null;
      window.chumpPrefs?.set('coord.session', this.#selectedSession);
      this.#loadInbox();
    });
    this.#loadAll();
    this.#pollTimer = setInterval(() => this.#loadAll(), 20_000);
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'coord_view_session', ts: new Date().toISOString(),
      }));
    } catch {}
  }

  disconnectedCallback() {
    if (this.#pollTimer) clearInterval(this.#pollTimer);
  }

  async #loadAll() {
    await Promise.all([
      this.#refreshSessions(),
      this.#loadIntents(),
      this.#loadNudges(),
    ]);
    await this.#loadInbox();
  }

  async #refreshSessions() {
    // Scan recent ambient events for distinct session ids.
    try {
      const r = await fetch('/api/ambient/recent?n=500');
      if (!r.ok) return;
      const d = await r.json();
      const events = d?.events || d?.rows || d || [];
      const map = new Map(); // sid → last_ts
      for (const e of events) {
        const sid = e.session || e.session_id;
        if (!sid) continue;
        const t = e.ts || '';
        const prev = map.get(sid);
        if (!prev || t > prev) map.set(sid, t);
      }
      this.#sessions = [...map.entries()]
        .map(([id, t]) => ({ id, last_event_ts: t }))
        .sort((a, b) => (b.last_event_ts || '').localeCompare(a.last_event_ts || ''))
        .slice(0, 30);
      const sel = this.querySelector('#coord-session-select');
      if (sel) {
        const prev = sel.value || this.#selectedSession || '';
        sel.innerHTML = '<option value="">— pick a session —</option>' + this.#sessions.map((s) => `
          <option value="${this.#esc(s.id)}"${s.id === prev ? ' selected' : ''}>
            ${this.#shortSession(s.id)} (${this.#fmtTs(s.last_event_ts)})
          </option>
        `).join('');
        if (prev && [...sel.options].some((o) => o.value === prev)) sel.value = prev;
        else if (this.#sessions.length && !prev) {
          this.#selectedSession = this.#sessions[0].id;
          sel.value = this.#selectedSession;
        }
      }
    } catch {}
  }

  async #loadInbox() {
    const list = this.querySelector('#coord-inbox-list');
    const count = this.querySelector('#coord-inbox-count');
    if (!list || !count) return;
    if (!this.#selectedSession) {
      list.innerHTML = `<li class="placeholder">Pick a session above to read its inbox.</li>`;
      count.textContent = '—';
      return;
    }
    try {
      const sid = encodeURIComponent(this.#selectedSession);
      const r = await fetch(`/api/inbox/${sid}?limit=50`);
      if (!r.ok) {
        list.innerHTML = `<li class="placeholder">No inbox for this session yet (or backend missing).</li>`;
        count.textContent = '0';
        return;
      }
      const d = await r.json();
      const msgs = d?.messages || d?.items || (Array.isArray(d) ? d : []);
      this.#inbox = msgs;
      count.textContent = String(msgs.length);
      if (msgs.length === 0) {
        list.innerHTML = `<li class="placeholder">No messages in this inbox.</li>`;
        return;
      }
      list.innerHTML = msgs.map((m) => `
        <li class="coord-row coord-row-inbox">
          <span class="coord-row-ts">${this.#fmtTs(m.ts || m.timestamp)}</span>
          <span class="coord-row-from">${this.#shortSession(m.from || m.sender || '?')}</span>
          <span class="coord-row-kind">${this.#esc(m.kind || m.type || 'msg')}</span>
          <span class="coord-row-body">${this.#esc((m.body || m.summary || '').slice(0, 200))}</span>
        </li>
      `).join('');
    } catch {
      list.innerHTML = `<li class="placeholder">Could not load inbox.</li>`;
    }
  }

  async #loadIntents() {
    const list = this.querySelector('#coord-intents-list');
    const count = this.querySelector('#coord-intents-count');
    if (!list || !count) return;
    try {
      const r = await fetch('/api/ambient/recent?n=200&kind=intent_announced');
      const d = r.ok ? await r.json() : null;
      const events = d?.events || d?.rows || d || [];
      const cutoff = Date.now() - 5 * 60 * 1000;
      this.#intents = events.filter((e) => {
        try { return new Date(e.ts).getTime() >= cutoff; } catch { return false; }
      }).slice(0, 50);
      count.textContent = String(this.#intents.length);
      if (this.#intents.length === 0) {
        list.innerHTML = `<li class="placeholder">No pending INTENT announcements (last 5 min).</li>`;
        return;
      }
      list.innerHTML = this.#intents.map((e) => `
        <li class="coord-row coord-row-intent">
          <span class="coord-row-ts">${this.#fmtTs(e.ts)}</span>
          <span class="coord-row-from">${this.#shortSession(e.session || e.session_id || '?')}</span>
          <span class="coord-row-gap">${this.#esc(e.gap_id || e.gap || '—')}</span>
          <span class="coord-row-body">${this.#esc((e.paths || e.summary || '').toString().slice(0, 160))}</span>
        </li>
      `).join('');
    } catch {
      list.innerHTML = `<li class="placeholder">Could not load INTENT board.</li>`;
    }
  }

  async #loadNudges() {
    const list = this.querySelector('#coord-nudges-list');
    const count = this.querySelector('#coord-nudges-count');
    if (!list || !count) return;
    try {
      const r = await fetch('/api/ambient/recent?n=200&kind=pr_nudge_emitted');
      const d = r.ok ? await r.json() : null;
      const events = d?.events || d?.rows || d || [];
      this.#nudges = events.slice(0, 50);
      count.textContent = String(this.#nudges.length);
      if (this.#nudges.length === 0) {
        list.innerHTML = `<li class="placeholder">No PR nudges in window.</li>`;
        return;
      }
      list.innerHTML = this.#nudges.map((e) => `
        <li class="coord-row coord-row-nudge">
          <span class="coord-row-ts">${this.#fmtTs(e.ts)}</span>
          <span class="coord-row-class coord-row-class-${this.#esc(e.class || 'unknown')}">${this.#esc(e.class || '?')}</span>
          <span class="coord-row-pr">${e.pr ? `<a href="https://github.com/repairman29/chump/pull/${this.#esc(String(e.pr))}" target="_blank" rel="noopener">#${this.#esc(String(e.pr))}</a>` : '—'}</span>
          <span class="coord-row-body">${this.#esc((e.template || e.note || '').slice(0, 140))}</span>
        </li>
      `).join('');
    } catch {
      list.innerHTML = `<li class="placeholder">Could not load nudge log.</li>`;
    }
  }

  #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  #shortSession(sid) {
    const m = String(sid).match(/^(?:claim-)?([a-z]+-\d+)/i);
    return m ? m[1] : (String(sid).slice(0, 18) + (String(sid).length > 18 ? '…' : ''));
  }
  #fmtTs(ts) {
    if (!ts) return '—';
    try {
      const d = new Date(ts);
      if (isNaN(d.getTime())) return ts;
      const ageS = (Date.now() - d.getTime()) / 1000;
      if (ageS < 60) return `${Math.round(ageS)}s ago`;
      if (ageS < 3600) return `${Math.round(ageS / 60)}m ago`;
      if (ageS < 86400) return `${Math.round(ageS / 3600)}h ago`;
      return d.toISOString().slice(0, 16).replace('T', ' ');
    } catch { return ts; }
  }
}
customElements.define('chump-view-coord', ChumpViewCoord);

// ── <chump-view-roadmap> (INFRA-1207) ───────────────────────────────────────
// Apex situational-awareness view per docs/design/OPERATOR_CONSOLE_V2.md
// (archetype 2 fleet operator). Answers "where does today's gap fit in the
// long arc?" — by rendering docs/ROADMAP.md milestones with completion %
// and gap chips per milestone.
//
// Routes via 'roadmap' in LIBRARY cadence.
//
// Data: /api/roadmap (endpoint not yet shipped — file backend follow-up).
// MVP renders three states:
//   1. Endpoint live + parsed → vertical timeline with milestone cards
//   2. Endpoint 404 → manual fallback "open docs/ROADMAP.md" + raw file
//      fetch from /docs/ROADMAP.md (served by chump --web static path)
//   3. Both fail → friendly error
class ChumpViewRoadmap extends HTMLElement {
  #data = null;

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Roadmap</h2>
        <p class="view-subtitle">Where today's gap fits in the long arc — milestone completion + blockers</p>
      </section>
      <section class="roadmap-toolbar" role="toolbar" aria-label="Roadmap filters">
        <label class="roadmap-filter">
          <input type="checkbox" id="roadmap-current-only" checked>
          <span>Show only current milestone</span>
        </label>
      </section>
      <section class="roadmap-list" id="roadmap-list" aria-live="polite" aria-busy="true">
        <p class="placeholder">Loading roadmap…</p>
      </section>
    `;
    this.querySelector('#roadmap-current-only')?.addEventListener('change', () => this.#render());
    this.#load();
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'roadmap_view_session', ts: new Date().toISOString(),
      }));
    } catch {}
  }

  async #load() {
    const list = this.querySelector('#roadmap-list');
    if (!list) return;
    list.setAttribute('aria-busy', 'true');
    try {
      // First try the structured endpoint.
      const r = await fetch('/api/roadmap');
      if (r.ok) {
        this.#data = await r.json();
        this.#render();
        return;
      }
      // Fall back to raw markdown if the static dir serves it.
      const raw = await fetch('/docs/ROADMAP.md').catch(() => null);
      if (raw && raw.ok) {
        const text = await raw.text();
        this.#data = this.#parseMarkdown(text);
        this.#render();
        return;
      }
      list.innerHTML = `<p class="placeholder">
        Roadmap endpoint pending (<code>/api/roadmap</code> not implemented yet).<br>
        Read the source: <a href="https://github.com/repairman29/chump/blob/main/docs/ROADMAP.md" target="_blank" rel="noopener">docs/ROADMAP.md on GitHub</a>
        or run <code>chump roadmap-status</code> in a terminal.
      </p>`;
    } catch (err) {
      list.innerHTML = `<p class="placeholder">Could not load roadmap: ${this.#esc(String(err))}</p>`;
    }
    list.setAttribute('aria-busy', 'false');
  }

  #parseMarkdown(text) {
    // Minimal parser for ROADMAP.md milestones. Heuristic: each "## Milestone"
    // heading starts a milestone block; "status:", "Gaps:", "Blockers:" are
    // optional fields. This is good-enough for the MVP shell; the real
    // /api/roadmap endpoint will do this server-side properly.
    const milestones = [];
    const lines = text.split('\n');
    let current = null;
    for (const line of lines) {
      if (/^##\s+/.test(line)) {
        if (current) milestones.push(current);
        const m = line.match(/^##\s+(.+)$/);
        current = { id: '', title: m ? m[1] : 'untitled', status: 'unknown', progress_pct: null, gaps: [], blockers: [], target_date: null };
      } else if (current) {
        if (/^status:\s*/i.test(line)) {
          current.status = line.replace(/^status:\s*/i, '').trim().toLowerCase();
        } else if (/^target[_ -]?date:\s*/i.test(line)) {
          current.target_date = line.replace(/^target[_ -]?date:\s*/i, '').trim();
        } else if (/^- ([A-Z]+-\d+)/.test(line)) {
          const gm = line.match(/^- ([A-Z]+-\d+)\s*[—-]?\s*(.+)?$/);
          if (gm) current.gaps.push({ id: gm[1], title: gm[2] || '' });
        }
      }
    }
    if (current) milestones.push(current);
    return { milestones };
  }

  #render() {
    const list = this.querySelector('#roadmap-list');
    if (!list || !this.#data) return;
    const onlyCurrent = !!this.querySelector('#roadmap-current-only')?.checked;
    const milestones = this.#data.milestones || [];
    if (milestones.length === 0) {
      list.innerHTML = `<p class="placeholder">No milestones found in roadmap.</p>`;
      return;
    }
    const filtered = onlyCurrent
      ? milestones.filter((m) => m.status === 'active' || m.status === 'next')
      : milestones;
    if (filtered.length === 0) {
      list.innerHTML = `<p class="placeholder">No active milestones (toggle "current only" off to see done/next).</p>`;
      return;
    }
    list.innerHTML = filtered.map((m) => this.#renderMilestone(m)).join('');
  }

  #renderMilestone(m) {
    const statusIcon = m.status === 'active'  ? '▶'
                    : m.status === 'next'    ? '◇'
                    : m.status === 'done'    ? '✓'
                    : m.status === 'blocked' ? '✗'
                    : '○';
    const statusClass = m.status === 'active'  ? 'roadmap-milestone-active'
                     : m.status === 'next'    ? 'roadmap-milestone-next'
                     : m.status === 'done'    ? 'roadmap-milestone-done'
                     : m.status === 'blocked' ? 'roadmap-milestone-blocked'
                     :                          'roadmap-milestone-unknown';
    const pct = typeof m.progress_pct === 'number'
      ? `<span class="roadmap-pct">${m.progress_pct}%</span>`
      : '';
    const gapsHtml = (m.gaps || []).slice(0, 8).map((g) => `
      <a href="/v2/?view=agent#${this.#esc(g.id || '')}" class="roadmap-gap-chip"
         title="${this.#esc(g.title || '')}">
        ${this.#esc(g.id || '?')}
      </a>
    `).join('');
    const blockersHtml = (m.blockers || []).length > 0
      ? `<div class="roadmap-blockers">⚠ Blockers: ${m.blockers.map((b) => this.#esc(typeof b === 'string' ? b : b.description || '')).join(', ')}</div>`
      : '';
    return `
      <article class="roadmap-milestone ${statusClass}">
        <header class="roadmap-milestone-header">
          <span class="roadmap-milestone-icon" aria-hidden="true">${statusIcon}</span>
          <h3 class="roadmap-milestone-title">${this.#esc(m.title || m.id || 'untitled')}</h3>
          ${m.target_date ? `<span class="roadmap-target">${this.#esc(m.target_date)}</span>` : ''}
          ${pct}
        </header>
        ${gapsHtml ? `<div class="roadmap-gaps">${gapsHtml}</div>` : ''}
        ${blockersHtml}
      </article>
    `;
  }

  #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
}
customElements.define('chump-view-roadmap', ChumpViewRoadmap);

// ── <chump-view-settings> ─────────────────────────────────────────────────────
class ChumpViewSettings extends HTMLElement {
  #metricsTimer = null;

  disconnectedCallback() {
    if (this.#metricsTimer) {
      clearInterval(this.#metricsTimer);
      this.#metricsTimer = null;
    }
  }

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Settings</h2>
        <p class="view-subtitle">v2 shell · Chump PWA rebuild (PRODUCT-012, PRODUCT-044)</p>
      </section>
      <section class="settings-grid">
        <label class="setting-row">
          <span class="setting-label">Version</span>
          <span class="setting-value">v2-alpha (PRODUCT-012 shell + phase 3)</span>
        </label>
        <label class="setting-row">
          <span class="setting-label">Framework</span>
          <span class="setting-value">Vanilla JS + Web Components (no build)</span>
        </label>
        <label class="setting-row">
          <span class="setting-label">Offline</span>
          <span class="setting-value">Service Worker active — shell cached</span>
        </label>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Appearance (INFRA-1280 Sub-gap 4)</p>
          <div id="theme-toggle" role="radiogroup" aria-label="Theme">
            <label style="display:inline-flex;align-items:center;gap:6px;margin-right:14px;">
              <input type="radio" name="chump-theme" value="system"> System
            </label>
            <label style="display:inline-flex;align-items:center;gap:6px;margin-right:14px;">
              <input type="radio" name="chump-theme" value="light"> Light
            </label>
            <label style="display:inline-flex;align-items:center;gap:6px;margin-right:14px;">
              <input type="radio" name="chump-theme" value="dark"> Dark
            </label>
            <label style="display:inline-flex;align-items:center;gap:6px;">
              <input type="radio" name="chump-theme" value="high-contrast"> High contrast
            </label>
          </div>
          <p style="color: var(--text-muted); font-size: 0.8em; margin-top: 6px;">
            Default: System (follows OS prefers-color-scheme).
          </p>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Inference Settings</p>
          <div id="cascade-slots" style="margin-bottom: 16px; font-size: 0.9em; color: var(--text-muted);">
            <p>Loading cascade slot info…</p>
          </div>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 4px;">Inference Performance (PRODUCT-055)</p>
          <p style="color: var(--text-muted); font-size: 0.8em; margin-bottom: 10px;">
            Per-slot latency and throughput — live, updated every 5 s. Sparkline = last 10 requests.
          </p>
          <div id="slot-metrics" style="display: flex; flex-direction: column; gap: 8px;">
            <p style="color: var(--text-muted); font-size: 0.9em;">Loading metrics…</p>
          </div>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Fleet Control</p>
          <chump-parallelism-governor></chump-parallelism-governor>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">API Secrets (INFRA-989)</p>
          <div id="api-secrets" style="font-size: 0.9em;">
            <p style="color: var(--text-muted);">Loading secrets…</p>
          </div>
          <p style="color: var(--text-muted); font-size: 0.8em; margin-top: 8px;">
            Stored in <code>~/.chump/config.toml</code> [api] (chmod 600). Probed against
            the provider before persist — bad credentials never reach disk.
            Values are never returned by GET — only presence + last 4 chars.
          </p>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Operator Configuration (INFRA-988)</p>
          <div id="operator-config" style="font-size: 0.9em;">
            <p style="color: var(--text-muted);">Loading operator config…</p>
          </div>
          <p style="color: var(--text-muted); font-size: 0.8em; margin-top: 8px;">
            Stored in <code>~/.chump/config.toml</code> [settings]. Env vars override.
            Secrets are managed separately (above).
          </p>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">Cost ceiling (PRODUCT-113)</p>
          <p style="color: var(--text-muted); font-size: 0.85em; margin-bottom: 8px;">
            Operator-tunable budget thresholds. Status footer cost meter colors per
            band; if a session exceeds the kill threshold, new turn requests are
            refused. Defends archetype 4 (enterprise) "what if the AI runs $1000
            overnight" concern.
          </p>
          <div id="cost-thresholds" style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;max-width:480px;">
            <label class="cost-threshold">
              <span class="cost-threshold-label">warn at $</span>
              <input type="number" id="cost-warn" min="0" step="0.05" value="0.50"
                     aria-label="Cost warning threshold in dollars">
            </label>
            <label class="cost-threshold">
              <span class="cost-threshold-label">red at $</span>
              <input type="number" id="cost-red" min="0" step="0.10" value="2.00"
                     aria-label="Cost red threshold in dollars">
            </label>
            <label class="cost-threshold">
              <span class="cost-threshold-label">KILL at $</span>
              <input type="number" id="cost-kill" min="0" step="1.00" value="5.00"
                     aria-label="Cost kill-switch threshold in dollars (session refused above this)">
            </label>
          </div>
          <p id="cost-threshold-error" style="color: var(--accent-error,#cc3344); font-size: 0.8em; margin-top: 6px; display:none;"></p>
          <div style="display:flex;gap:12px;align-items:center;margin-top:10px;">
            <label style="display:inline-flex;align-items:center;gap:6px;">
              <input type="checkbox" id="cost-fleet-kill">
              <span>Pause all workers when fleet daily cost exceeds $</span>
              <input type="number" id="cost-fleet-kill-threshold" min="0" step="1" value="20"
                     aria-label="Fleet-wide daily cost ceiling" style="width:80px;">
            </label>
          </div>
          <button type="button" id="cost-threshold-reset" style="padding:4px 10px;border:1px solid var(--border);background:transparent;color:var(--text-secondary);border-radius:4px;cursor:pointer;font-size:11px;margin-top:8px;">
            Reset to defaults
          </button>
        </div>
        <div style="border-top: 1px solid var(--border-color); padding-top: 12px; margin-top: 12px;">
          <p class="setting-label" style="margin-bottom: 12px;">PWA Preferences (INFRA-1280)</p>
          <p style="color: var(--text-muted); font-size: 0.85em; margin-bottom: 8px;">
            Theme + queue filters + cost thresholds + (future) sidecar / stream pause are persisted
            under the <code>chump.*</code> localStorage namespace. Schema:
            <code>docs/api/PWA_STATE_SCHEMA.md</code>.
          </p>
          <button type="button" id="chump-prefs-reset" class="chump-prefs-reset" aria-label="Reset all PWA preferences" style="padding:6px 12px;border:1px solid var(--accent-error,#cc3344);background:transparent;color:var(--accent-error,#cc3344);border-radius:6px;cursor:pointer;font-size:0.9em;">
            Reset all preferences
          </button>
          <p style="color: var(--text-muted); font-size: 0.75em; margin-top: 6px;">
            Wipes every <code>chump.*</code> key from localStorage and reloads.
          </p>
        </div>
      </section>
    `;
    this.#loadCascadeInfo();
    this.#loadOperatorConfig();
    this.#loadApiSecrets();
    this.#wireThemeToggle();
    this.#wireCostThresholds();
    this.#wireResetButton();
    this.#loadSlotMetrics();
    // PRODUCT-055: poll slot metrics every 5 seconds for live latency/throughput display.
    this.#metricsTimer = setInterval(() => this.#loadSlotMetrics(), 5000);
  }

  // PRODUCT-113: cost-ceiling inputs (warn / red / kill) + fleet-wide kill toggle.
  // Reads from chumpPrefs.cost.thresholds, validates positive + warn<red<kill,
  // persists on every change. Cost meter + status-footer cost slot
  // (PRODUCT-107) read the same chumpPrefs key to color their value bands.
  // Kill switch is a frontend contract today — backend enforcement (POST
  // /api/chat returns 402 when session cost > kill) is a follow-up gap.
  #wireCostThresholds() {
    const warn = this.querySelector('#cost-warn');
    const red  = this.querySelector('#cost-red');
    const kill = this.querySelector('#cost-kill');
    const fleetKill   = this.querySelector('#cost-fleet-kill');
    const fleetKillT  = this.querySelector('#cost-fleet-kill-threshold');
    const err  = this.querySelector('#cost-threshold-error');
    const resetBtn = this.querySelector('#cost-threshold-reset');
    if (!warn || !red || !kill) return;

    const stored = (window.chumpPrefs?.get('cost.thresholds', null)) || {};
    const fleet = (window.chumpPrefs?.get('cost.fleet_kill', null)) || {};
    if (stored.warn != null) warn.value = stored.warn;
    if (stored.red  != null) red.value  = stored.red;
    if (stored.kill != null) kill.value = stored.kill;
    if (fleetKill)  fleetKill.checked   = fleet.enabled === true;
    if (fleetKillT && fleet.threshold != null) fleetKillT.value = fleet.threshold;

    const validate = () => {
      const w = Number(warn.value), r = Number(red.value), k = Number(kill.value);
      if (!Number.isFinite(w) || w < 0) return 'warn must be ≥ 0';
      if (!Number.isFinite(r) || r < 0) return 'red must be ≥ 0';
      if (!Number.isFinite(k) || k < 0) return 'kill must be ≥ 0';
      if (!(w < r))      return 'warn must be less than red';
      if (!(r < k))      return 'red must be less than kill';
      return null;
    };

    const persist = () => {
      const msg = validate();
      if (err) { err.style.display = msg ? '' : 'none'; err.textContent = msg || ''; }
      if (msg) return; // don't persist invalid state
      const next = { warn: Number(warn.value), red: Number(red.value), kill: Number(kill.value) };
      const prev = window.chumpPrefs?.get('cost.thresholds', null);
      window.chumpPrefs?.set('cost.thresholds', next);
      // Telemetry: emit when any threshold actually changed.
      if (!prev || prev.warn !== next.warn || prev.red !== next.red || prev.kill !== next.kill) {
        try {
          navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
            kind: 'cost_threshold_changed',
            warn: next.warn, red: next.red, kill: next.kill,
            ts: new Date().toISOString(),
          }));
        } catch {}
      }
    };

    [warn, red, kill].forEach((el) => el.addEventListener('change', persist));

    const persistFleet = () => {
      const enabled = !!fleetKill?.checked;
      const t = Number(fleetKillT?.value || 0);
      window.chumpPrefs?.set('cost.fleet_kill', { enabled, threshold: t });
    };
    fleetKill?.addEventListener('change', persistFleet);
    fleetKillT?.addEventListener('change', persistFleet);

    resetBtn?.addEventListener('click', () => {
      warn.value = '0.50'; red.value = '2.00'; kill.value = '5.00';
      if (fleetKill) fleetKill.checked = false;
      if (fleetKillT) fleetKillT.value = '20';
      window.chumpPrefs?.del('cost.thresholds');
      window.chumpPrefs?.del('cost.fleet_kill');
      if (err) { err.style.display = 'none'; err.textContent = ''; }
      try {
        navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
          kind: 'cost_threshold_changed', action: 'reset',
          ts: new Date().toISOString(),
        }));
      } catch {}
    });
  }

  // INFRA-1280 Sub-gap 4: theme toggle (System/Light/Dark/High-contrast).
  // Reads stored pref, checks the right radio, persists changes, repaints.
  #wireThemeToggle() {
    const current = window.chumpPrefs.get('theme', 'system');
    const radios = this.querySelectorAll('input[name="chump-theme"]');
    radios.forEach(r => {
      if (r.value === current) r.checked = true;
      r.addEventListener('change', (e) => {
        const v = e.target.value;
        window.chumpPrefs.set('theme', v);
        const effective = (v === 'system')
          ? (window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
          : v;
        document.documentElement.setAttribute('data-theme', effective);
      });
    });
  }

  // INFRA-989: render API secret slots from /api/settings/secret/{name}.
  // GET returns {set, last4} — never the value. Replace flow opens a
  // type=password input that POSTs to the same endpoint with probe-before-store.
  #loadApiSecrets() {
    const container = this.querySelector('#api-secrets');
    if (!container) return;
    const secrets = [
      { key: 'ANTHROPIC_API_KEY', label: 'Anthropic API key' },
      { key: 'CLAUDE_CODE_OAUTH_TOKEN', label: 'Claude Code OAuth token' },
      { key: 'GH_TOKEN', label: 'GitHub token' },
    ];
    Promise.all(secrets.map(s =>
      fetch(`/api/settings/secret/${encodeURIComponent(s.key)}`)
        .then(r => r.ok ? r.json() : { set: false, last4: '' })
        .then(data => ({ ...s, ...data }))
        .catch(() => ({ ...s, set: false, last4: '', error: true }))
    ))
    .then(rows => {
      container.innerHTML = rows.map(r => {
        const masked = r.set ? `••••••••${r.last4}` : '<span style="color:var(--text-muted)">(not set)</span>';
        const cls = r.set ? 'op-secret-row-set' : 'op-secret-row-unset';
        return `
          <div class="op-secret-row ${cls}" data-key="${r.key}" style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
            <label style="flex:1;">${r.label}</label>
            <code class="op-secret-mask" style="font-family:monospace;">${masked}</code>
            <button data-action="replace" data-key="${r.key}" class="op-secret-replace">${r.set ? 'Replace' : 'Set'}</button>
          </div>`;
      }).join('');
      container.querySelectorAll('[data-action="replace"]').forEach(btn => {
        btn.addEventListener('click', e => this.#startSecretReplace(e));
      });
    });
  }

  // INFRA-1280 Sub-gap 9: Reset-all wipes every chump.* localStorage key.
  // Confirms before nuking so accidental clicks don't surprise the operator.
  #wireResetButton() {
    const btn = this.querySelector('#chump-prefs-reset');
    btn?.addEventListener('click', () => {
      if (!confirm('Reset ALL PWA preferences (theme, queue filters, etc.)?\n\nThis will reload the page.')) return;
      const wiped = window.chumpPrefs.resetAll();
      btn.textContent = `Wiped ${wiped} keys — reloading…`;
      btn.disabled = true;
      setTimeout(() => location.reload(), 400);
    });
  }

  // INFRA-989: open the inline replace form for a secret slot.
  #startSecretReplace(e) {
    const btn = e.target;
    const key = btn.dataset.key;
    const row = btn.closest('.op-secret-row');
    if (!row || row.querySelector('input[type="password"]')) return;
    // Build the replace form inline. type=password + autocomplete=off so
    // the browser doesn't cache the value or expose it via DevTools history.
    const form = document.createElement('div');
    form.style.cssText = 'display:flex;align-items:center;gap:6px;flex:1;';
    form.innerHTML = `
      <input type="password" autocomplete="off" data-key="${key}" placeholder="Paste new value…" style="flex:1;font-family:monospace;">
      <button data-action="save-secret" data-key="${key}">Save</button>
      <button data-action="cancel-secret" data-key="${key}">Cancel</button>
      <span data-role="status" style="font-size:0.85em;color:var(--text-muted);"></span>
    `;
    row.appendChild(form);
    form.querySelector('[data-action="save-secret"]').addEventListener('click', ev => this.#saveSecret(ev));
    form.querySelector('[data-action="cancel-secret"]').addEventListener('click', ev => {
      ev.target.closest('.op-secret-row').querySelector('div').remove();
    });
  }

  // INFRA-989: POST the secret value (probe-before-store, 422 on probe fail).
  #saveSecret(e) {
    const btn = e.target;
    const key = btn.dataset.key;
    const row = btn.closest('.op-secret-row');
    const input = row.querySelector('input[type="password"]');
    const status = row.querySelector('[data-role="status"]');
    const value = input.value;
    if (!value) { status.textContent = '(empty)'; return; }
    btn.disabled = true;
    status.textContent = 'probing…';
    fetch(`/api/settings/secret/${encodeURIComponent(key)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
      body: JSON.stringify({ value }),
    })
    .then(r => {
      if (r.status === 422) {
        status.textContent = 'probe failed — not saved';
        btn.disabled = false;
        return null;
      }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json();
    })
    .then(j => {
      if (!j) return;
      // Immediately clear the cleartext from the input/memory.
      input.value = '';
      status.textContent = `saved (••••${j.last4})`;
      // Re-render the entire secrets section so the new state is reflected.
      setTimeout(() => this.#loadApiSecrets(), 400);
    })
    .catch(err => {
      status.textContent = `error: ${err.message}`;
      btn.disabled = false;
    });
  }

  // INFRA-988: render non-secret config fields from /api/settings.
  // Each field shows value + source badge (env / config / default).
  #loadOperatorConfig() {
    const container = this.querySelector('#operator-config');
    fetch('/api/settings')
      .then(r => r.json())
      .then(data => {
        const fields = [
          { key: 'CHUMP_AUTH_MODE', label: 'Auth mode', options: ['auto', 'api-key', 'oauth'] },
          { key: 'CHUMP_MULTI_REPO_ENABLED', label: 'Multi-repo', options: ['0', '1'] },
          { key: 'FLEET_SIZE', label: 'Fleet size', type: 'number', min: 0, max: 64 },
          { key: 'FLEET_MODEL', label: 'Fleet model', options: ['haiku', 'sonnet', 'opus'] },
          { key: 'CHUMP_ROUND_PRIVACY', label: 'Round privacy', options: ['safe', 'dogfood'] },
          { key: 'CHUMP_REPO', label: 'Working repo path', type: 'text' },
        ];
        container.innerHTML = fields.map(f => {
          const entry = data[f.key] || { value: '', source: 'default' };
          const badge = `<span class="op-config-badge op-config-badge-${entry.source}">${entry.source}</span>`;
          const envLocked = entry.source === 'env';
          const lockedAttr = envLocked ? 'disabled title="Set via env var — unset env to edit via PWA"' : '';
          let input;
          if (f.options) {
            input = `<select data-key="${f.key}" ${lockedAttr}>${f.options.map(o => `<option value="${o}" ${o === entry.value ? 'selected' : ''}>${o}</option>`).join('')}</select>`;
          } else {
            const min = f.min != null ? `min="${f.min}"` : '';
            const max = f.max != null ? `max="${f.max}"` : '';
            input = `<input type="${f.type}" data-key="${f.key}" value="${entry.value}" ${min} ${max} ${lockedAttr}>`;
          }
          return `
            <div class="op-config-row" style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
              <label style="flex:1;">${f.label}</label>
              ${input}
              ${badge}
            </div>`;
        }).join('');
        container.querySelectorAll('[data-key]').forEach(el => {
          el.addEventListener('change', e => this.#onConfigChange(e));
        });
      })
      .catch(err => {
        container.innerHTML = `<p style="color:var(--error-color)">Error loading config: ${err.message}</p>`;
      });
  }

  #onConfigChange(e) {
    const el = e.target;
    const key = el.dataset.key;
    const value = el.value;
    el.disabled = true;
    fetch(`/api/settings/${encodeURIComponent(key)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'pwa' },
      body: JSON.stringify({ value }),
    })
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(() => this.#loadOperatorConfig())
      .catch(err => {
        console.error(`settings POST ${key} failed:`, err);
        el.disabled = false;
      });
  }

  // PRODUCT-055: load per-slot inference metrics from /api/slots and render cards with sparklines.
  #loadSlotMetrics() {
    const container = this.querySelector('#slot-metrics');
    if (!container) return;
    fetch('/api/slots')
      .then(r => r.json())
      .then(data => {
        const slots = data.slots || [];
        if (slots.length === 0) {
          container.innerHTML = '<p class="cascade-empty">No cascade slots configured — metrics unavailable.</p>';
          return;
        }
        container.innerHTML = slots.map(slot => {
          const p50 = slot.latency_ms_p50 != null ? `${Math.round(slot.latency_ms_p50)} ms` : '—';
          const p95 = slot.latency_ms_p95 != null ? `${Math.round(slot.latency_ms_p95)} ms` : '—';
          const tps = slot.avg_tokens_per_sec != null ? `${slot.avg_tokens_per_sec.toFixed(1)} tok/s` : '—';
          const total = (slot.success_count || 0) + (slot.sanity_fail_count || 0);
          const successRate = total > 0
            ? `${Math.round(100 * (slot.success_count || 0) / total)}%`
            : '—';
          const lastUsed = slot.last_used_at
            ? new Date(slot.last_used_at + 'Z').toLocaleTimeString()
            : 'never';
          const sparkSvg = this.#renderSparkline(slot.request_history || []);
          return `
            <div class="slot-metric-card">
              <div class="slot-metric-header">
                <span class="slot-metric-name">${slot.name}</span>
                <span class="slot-metric-last">last: ${lastUsed}</span>
              </div>
              <div class="slot-metric-stats">
                <div class="slot-metric-stat">
                  <span class="slot-metric-val">${p50}</span>
                  <span class="slot-metric-label">p50 latency</span>
                </div>
                <div class="slot-metric-stat">
                  <span class="slot-metric-val">${p95}</span>
                  <span class="slot-metric-label">p95 latency</span>
                </div>
                <div class="slot-metric-stat">
                  <span class="slot-metric-val accent">${tps}</span>
                  <span class="slot-metric-label">avg tok/s</span>
                </div>
                <div class="slot-metric-stat">
                  <span class="slot-metric-val success">${successRate}</span>
                  <span class="slot-metric-label">success rate</span>
                </div>
                <div class="slot-sparkline-wrap">
                  ${sparkSvg}
                  <div class="slot-sparkline-caption">last 10 requests</div>
                </div>
              </div>
            </div>`;
        }).join('');
      })
      .catch(() => {
        // Silently fail — server may not have cascade slots configured.
        if (container) container.innerHTML = '<p class="cascade-empty" style="color:var(--text-secondary)">Metrics unavailable (server offline or no cascade slots).</p>';
      });
  }

  // PRODUCT-055: render a vanilla SVG sparkline for the last 10 latency values.
  // Values are shown oldest→newest left→right. Bar height proportional to latency.
  #renderSparkline(history) {
    if (!history || history.length === 0) {
      return '<div style="height:32px;display:flex;align-items:center;justify-content:center;color:var(--text-secondary);font-size:10px;">no data</div>';
    }
    // history is newest-first; reverse to show oldest→newest.
    const entries = [...history].reverse();
    const vals = entries.map(e => e.latency_ms || 0);
    const maxVal = Math.max(...vals, 1);
    const W = 80;
    const H = 32;
    const barW = Math.floor(W / 10);
    const gap = 1;
    const bars = vals.map((v, i) => {
      const barH = Math.max(2, Math.round((v / maxVal) * (H - 4)));
      const x = i * (barW + gap);
      const y = H - barH;
      // Color: green if below p50-ish (< half max), amber if mid, red if high.
      const ratio = v / maxVal;
      const fill = ratio < 0.4 ? 'var(--success, #30d158)'
                 : ratio < 0.75 ? 'var(--warn, #ff9f0a)'
                 : 'var(--error, #ff453a)';
      return `<rect x="${x}" y="${y}" width="${barW}" height="${barH}" fill="${fill}" rx="1"/>`;
    }).join('');
    return `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" style="display:block;width:100%;height:${H}px;" aria-hidden="true">${bars}</svg>`;
  }

  // PRODUCT-054: load real cascade slot data and render toggle switches.
  #loadCascadeInfo() {
    const container = this.querySelector('#cascade-slots');
    fetch('/api/cascade-status')
      .then(r => r.json())
      .then(data => {
        if (!data || !data.slots) {
          container.innerHTML = '<p class="cascade-empty">No cascade slots configured.</p>';
          return;
        }
        if (data.slots.length === 0) {
          container.innerHTML = '<p class="cascade-empty">Cascade disabled — no slots found.</p>';
          return;
        }
        container.innerHTML = data.slots.map(slot => {
          const disabled = !!slot.disabled_by_config;
          const circuit = slot.circuit_state || 'ok';
          const circuitBadge = circuit === 'open'
            ? '<span class="cascade-badge cascade-badge-err">circuit open</span>'
            : circuit === 'half_open'
              ? '<span class="cascade-badge cascade-badge-warn">half-open</span>'
              : '';
          const rpm = slot.rpm_limit > 0 ? `${slot.calls_this_minute}/${slot.rpm_limit} rpm` : '';
          const rpd = slot.rpd_limit > 0 ? `${slot.calls_today}/${slot.rpd_limit} rpd` : '';
          const stats = [rpm, rpd].filter(Boolean).join(' · ');
          return `
            <div class="cascade-slot-row ${disabled ? 'cascade-slot-disabled' : ''}">
              <div class="cascade-slot-info">
                <span class="cascade-slot-name">${slot.name}</span>
                ${circuitBadge}
                ${stats ? `<span class="cascade-slot-stats">${stats}</span>` : ''}
              </div>
              <label class="cascade-toggle" title="${disabled ? 'Enable slot' : 'Disable slot'}">
                <input type="checkbox" class="cascade-toggle-input"
                  data-slot="${slot.name}"
                  ${disabled ? '' : 'checked'}
                  ${circuit === 'open' ? 'disabled' : ''}>
                <span class="cascade-toggle-track"></span>
              </label>
            </div>`;
        }).join('');
        // Wire toggle events
        container.querySelectorAll('.cascade-toggle-input').forEach(cb => {
          cb.addEventListener('change', e => this.#onSlotToggle(e));
        });
      })
      .catch(err => {
        container.innerHTML = `<p style="color:var(--error-color)">Error: ${err.message}</p>`;
      });
  }

  #onSlotToggle(e) {
    const cb = e.target;
    const slot = cb.dataset.slot;
    const enabled = cb.checked;
    cb.disabled = true;
    fetch('/api/cascade-slot-toggle', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ slot, enabled }),
    })
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(() => {
        // Refresh to reflect saved state
        this.#loadCascadeInfo();
      })
      .catch(err => {
        cb.checked = !enabled; // revert optimistic toggle
        cb.disabled = false;
        console.error('cascade-slot-toggle failed:', err);
      });
  }

  // INFRA-1711: shared error/info toast utility used by other v2 views
  // (e.g. content-bots.js) that don't want to duplicate toast plumbing.
  static showToast(kind, message) {
    let host = document.getElementById('chump-view-settings-toast-host');
    if (!host) {
      host = document.createElement('div');
      host.id = 'chump-view-settings-toast-host';
      host.style.cssText = 'position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:9999;display:flex;flex-direction:column;gap:8px;';
      document.body.appendChild(host);
    }
    const toast = document.createElement('div');
    const color = kind === 'error' ? '#ff453a' : '#3182ce';
    toast.style.cssText = `background:${color};color:#fff;padding:8px 16px;border-radius:6px;font:13px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;box-shadow:0 2px 8px rgba(0,0,0,0.3);`;
    toast.textContent = message;
    host.appendChild(toast);
    setTimeout(() => toast.remove(), 5_000);
  }
}
customElements.define('chump-view-settings', ChumpViewSettings);
window.ChumpViewSettings = ChumpViewSettings;

// ── <chump-view-agents> (PRODUCT-059) ────────────────────────────────────────
// Read-only live results board: one card per active .chump-locks/*.json session.
// Polls /api/fleet-status every 10 seconds. Works without GitHub access (PR fields
// are shown only when the gh CLI is available on the server).
class ChumpViewAgents extends HTMLElement {
  #timer = null;

  connectedCallback() {
    // INFRA-1010: <chump-fleet-sidebar> renders the same data as the legacy
    // polling list but with real-time SSE updates (<2s on lease_acquired,
    // phase_*, ship_*). The legacy agent-card list below remains as a
    // detail view (PR/CI columns the sidebar omits).
    this.innerHTML = `
      <section class="view-header">
        <h2>Agents</h2>
        <p class="view-subtitle">Active fleet sessions — leases, PRs, and CI status</p>
      </section>
      <chump-fleet-sidebar></chump-fleet-sidebar>
      <p class="agents-refresh-note" id="agents-refresh-note">Refreshes every 10 s</p>
      <section class="agents-list" id="agents-list">
        <p class="placeholder">Loading active sessions…</p>
      </section>
    `;
    this.#load();
    this.#timer = setInterval(() => this.#load(), 10_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  #load() {
    const list = this.querySelector('#agents-list');
    const note = this.querySelector('#agents-refresh-note');
    // PRODUCT-100: use apiFetch wrapper for visible error state + staleness tracking.
    (window.apiFetch ? window.apiFetch('/api/fleet-status') : fetch('/api/fleet-status'))
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((d) => {
        const sessions = d.sessions ?? [];
        const ts = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        if (note) note.textContent = `${sessions.length} active session${sessions.length !== 1 ? 's' : ''} · last updated ${ts}`;

        if (sessions.length === 0) {
          list.innerHTML = '<p class="placeholder">No active agent sessions. The fleet is idle.</p>';
          return;
        }

        list.innerHTML = sessions.map((s) => {
          const gapId = s.gap_id || '—';
          const title = s.gap_title || '(no title)';
          const priority = s.gap_priority ? `${s.gap_priority}/${s.gap_effort || '?'}` : '';
          const branch = s.branch || '';
          const worktree = s.worktree_path || '';

          // PR link
          const prNum = s.pr_number;
          const prState = (s.pr_state || '').toLowerCase();
          const prHtml = prNum
            ? `<a class="agent-pr-link" href="https://github.com/${this.#repoSlug()}/pull/${prNum}" target="_blank" rel="noopener">#${prNum} ${prState}</a>`
            : '';

          // CI badge
          const ci = s.ci_status;
          const ciClass = ci === 'success' ? 'ci-success'
                        : ci === 'failure' ? 'ci-failure'
                        : ci === 'pending' ? 'ci-pending' : '';
          const ciBadge = ci ? `<span class="agent-ci-badge ${ciClass}">CI: ${ci}</span>` : '';

          // Heartbeat age
          const heartbeatAge = s.heartbeat_at ? this.#age(s.heartbeat_at) : '';

          return `
            <article class="agent-card">
              <header class="agent-card-header">
                <span class="agent-gap-id">${gapId}</span>
                ${ciBadge}
                ${priority ? `<span class="gap-priority">${priority}</span>` : ''}
                ${prHtml}
              </header>
              <p class="agent-gap-title">${title}</p>
              <div class="agent-meta">
                ${branch ? `<span title="Branch">🌿 ${branch}</span>` : ''}
                ${s.taken_at ? `<span title="Started">🕐 ${this.#age(s.taken_at)} ago</span>` : ''}
                ${heartbeatAge ? `<span title="Last heartbeat">💓 ${heartbeatAge} ago</span>` : ''}
              </div>
              ${worktree ? `<p class="agent-worktree" title="Worktree path">📂 ${worktree}</p>` : ''}
            </article>
          `;
        }).join('');
      })
      .catch((err) => {
        if (list) list.innerHTML = `<p class="placeholder">Could not load fleet status: ${err.message}</p>`;
      });
  }

  #repoSlug() {
    // Best-effort: extract owner/repo from the page origin (works when hosted
    // behind a reverse proxy that sets X-Repo-Slug). Falls back to the GitHub
    // origin for the known Chump repo.
    return 'jeffadkins/Chump';
  }

  #age(isoString) {
    try {
      const ms = Date.now() - new Date(isoString).getTime();
      const secs = Math.floor(ms / 1000);
      if (secs < 60) return `${secs}s`;
      const mins = Math.floor(secs / 60);
      if (mins < 60) return `${mins}m`;
      const hrs = Math.floor(mins / 60);
      return `${hrs}h ${mins % 60}m`;
    } catch {
      return '?';
    }
  }
}
customElements.define('chump-view-agents', ChumpViewAgents);

// ── <chump-view-results> ──────────────────────────────────────────────────────
class ChumpViewResults extends HTMLElement {
  #unsubscribe = null;

  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Results</h2>
        <p class="view-subtitle">Live status and job results <span id="stream-pill" class="stream-pill" style="font-size:11px;margin-left:8px;padding:2px 8px;border-radius:10px;background:var(--bg-muted, #2a2a2a);color:var(--text-secondary, #aaa);">— stream: init</span></p>
      </section>
      <section class="results-list" id="results-container">
        <p class="placeholder">Loading results…</p>
      </section>
    `;
    // Initial fetch in parallel with SSE so the page isn't empty for 30s.
    this.#load();
    // PRODUCT-099: subscribe to the SSE bus instead of polling.
    if (window.chumpStream) {
      this.#unsubscribe = window.chumpStream.subscribe((msg) => {
        if (msg.type === 'dashboard') this.#renderFromStream(msg.data);
      });
      // Reflect connection status as a small live pill.
      document.addEventListener('chump:stream-status', this.#onStatus);
      // Late mount: paint pill from current bus status (don't wait for the
      // next status-change event, which may never come if we're already live).
      this.#onStatus({ detail: window.chumpStream.status() });
    }
  }

  disconnectedCallback() {
    if (this.#unsubscribe) { this.#unsubscribe(); this.#unsubscribe = null; }
    document.removeEventListener('chump:stream-status', this.#onStatus);
  }

  #onStatus = (e) => {
    const pill = this.querySelector('#stream-pill');
    if (!pill) return;
    const colors = {
      live: ['#1f4d2a', '#9be3a9', '● live'],
      connecting: ['#3a3a1a', '#e3d29b', '◌ connecting'],
      reconnecting: ['#4d3a1a', '#e3c19b', '↻ reconnecting'],
      paused: ['#1a2a3a', '#9bb8e3', '⏸ paused'],
      offline: ['#4d1f1f', '#e39b9b', '⚠ offline'],
      init: ['#2a2a2a', '#aaa', '— stream: init'],
    };
    const [bg, fg, label] = colors[e.detail] || colors.init;
    pill.style.background = bg;
    pill.style.color = fg;
    pill.textContent = label;
  };

  #renderFromStream(dashboard) {
    // Same render path as #load but called per SSE event; do NOT clobber the
    // jobs list (the stream doesn't carry jobs yet — that's a separate gap).
    if (!dashboard || !Object.keys(dashboard).length) return;
    const card = this.querySelector('#stream-dashboard-card');
    const html = `
      <article id="stream-dashboard-card" class="task-card">
        <header class="task-card-header">
          <span class="task-status ${dashboard.ship_running ? 'running' : 'done'}">
            ${dashboard.ship_running ? 'Active' : 'Idle'}
          </span>
        </header>
        <p class="task-desc"><strong>Fleet status:</strong> ${dashboard.fleet_status ?? '?'}</p>
        ${dashboard.last_heartbeat_iso ? `<p class="task-desc"><strong>Last heartbeat:</strong> ${dashboard.last_heartbeat_iso}</p>` : ''}
        ${Array.isArray(dashboard.active_tasks) && dashboard.active_tasks.length > 0
            ? `<p class="task-desc"><strong>Active tasks:</strong> ${dashboard.active_tasks.length}</p>` : ''}
      </article>
    `;
    const container = this.querySelector('#results-container');
    if (!container) return;
    if (card) {
      card.outerHTML = html;
    } else {
      container.insertAdjacentHTML('afterbegin', html);
    }
  }

  #load() {
    const container = this.querySelector('#results-container');
    // PRODUCT-100: use apiFetch for visible error state.
    const _fetch = window.apiFetch ?? fetch;
    Promise.all([
      _fetch('/api/dashboard').then(r => r.json()).catch(() => ({})),
      _fetch('/api/jobs').then(r => r.json()).catch(() => [])
    ]).then(([dashboard, jobs]) => {
      if (!dashboard && !jobs) {
        container.innerHTML = '<p class="placeholder">No results available (offline or server not running).</p>';
        return;
      }

      let html = '';

      if (dashboard && Object.keys(dashboard).length > 0) {
        html += `
          <article class="task-card">
            <header class="task-card-header">
              <span class="task-status ${dashboard.ship_running ? 'running' : 'done'}">
                ${dashboard.ship_running ? 'Active' : 'Idle'}
              </span>
            </header>
            <p class="task-desc"><strong>Agent Status:</strong> ${dashboard.ship_running ? 'Running' : 'Stopped'}</p>
            ${dashboard.ship_summary ? `<p class="task-desc"><strong>Current Round:</strong> ${JSON.stringify(dashboard.ship_summary).substring(0, 100)}…</p>` : ''}
          </article>
        `;
      }

      if (Array.isArray(jobs) && jobs.length > 0) {
        jobs.slice(0, 15).forEach(job => {
          html += `
            <article class="task-card">
              <header class="task-card-header">
                <span class="task-status ${job.status ?? 'unknown'}">${job.status ?? 'pending'}</span>
                <span class="task-id">${job.id ?? job.job_id ?? ''}</span>
              </header>
              <p class="task-desc">${job.description ?? job.title ?? '(no title)'}</p>
              ${job.result ? `<p class="task-desc" style="color: var(--text-secondary); font-size: 12px; margin-top: 4px;"><strong>Result:</strong> ${job.result}</p>` : ''}
            </article>
          `;
        });
      }

      if (!html) {
        container.innerHTML = '<p class="placeholder">No active jobs or results yet.</p>';
      } else {
        container.innerHTML = html;
      }
    }).catch(() => {
      container.innerHTML = '<p class="placeholder">Failed to load results.</p>';
    });
  }
}
customElements.define('chump-view-results', ChumpViewResults);

// ── <chump-view-chat> ─────────────────────────────────────────────────────────
class ChumpViewChat extends HTMLElement {
  connectedCallback() {
    this.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden;height:100%';
    this.innerHTML = '<chump-chat style="flex:1;min-height:0"></chump-chat>';
  }
}
customElements.define('chump-view-chat', ChumpViewChat);

// ── <chump-view-agent> ────────────────────────────────────────────────────────
class ChumpViewAgent extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Gap Queue</h2>
        <p class="view-subtitle">Fleet orchestrator — claim and work gaps autonomously</p>
      </section>
      <chump-hint-composer></chump-hint-composer>
      <section class="gap-search-bar" id="gap-search-bar">
        <input type="search" id="gap-search-input" placeholder="Search gaps…" autocomplete="off" />
        <select id="gap-filter-status"><option value="">All statuses</option><option value="open">open</option><option value="done">done</option><option value="in_flight">in_flight</option></select>
        <select id="gap-filter-priority"><option value="">All priorities</option><option value="P0">P0</option><option value="P1">P1</option><option value="P2">P2</option></select>
        <select id="gap-filter-effort"><option value="">All efforts</option><option value="xs">xs</option><option value="s">s</option><option value="m">m</option><option value="l">l</option><option value="xl">xl</option></select>
        <label class="gap-filter-ac"><input type="checkbox" id="gap-filter-has-ac" /> Missing AC</label>
        <button id="gap-filter-clear" type="button" class="gap-filter-clear" aria-label="Clear all filters" title="Clear all filters">Clear</button>
      </section>
      <section class="gap-queue-stats" id="gap-stats">
        <div class="stat-item">
          <span class="stat-value">—</span>
          <span class="stat-label">Open</span>
        </div>
        <div class="stat-item">
          <span class="stat-value">—</span>
          <span class="stat-label">Claimable</span>
        </div>
      </section>
      <section class="gap-list" id="gap-list">
        <p class="placeholder">Loading gap queue…</p>
      </section>
    `;
    this.#wireSearch();
    this.#restoreFilters();
    this.#load();
    this.#poll = setInterval(() => this.#load(), 5000);
  }

  // INFRA-1280 Sub-gap 2: persist + restore queue filter state across reload.
  // Order of precedence on mount: URL query params > localStorage > defaults.
  // Any change writes back to localStorage. URL is updated via replaceState
  // (no history pollution per filter keystroke).
  #restoreFilters() {
    const url = new URLSearchParams(location.search);
    const stored = window.chumpPrefs.get('queue.filters', {});
    const get = (key) => url.get(key) ?? stored[key] ?? '';
    const qInput = this.querySelector('#gap-search-input');
    const statusSel = this.querySelector('#gap-filter-status');
    const prioritySel = this.querySelector('#gap-filter-priority');
    const effortSel = this.querySelector('#gap-filter-effort');
    const hasAcCb = this.querySelector('#gap-filter-has-ac');
    if (qInput) qInput.value = get('q');
    if (statusSel) statusSel.value = get('status');
    if (prioritySel) prioritySel.value = get('priority');
    if (effortSel) effortSel.value = get('effort');
    if (hasAcCb) {
      const stored_ac = stored.has_ac;
      const url_ac = url.get('has_ac');
      hasAcCb.checked = (url_ac === 'false') || stored_ac === true;
    }
    if (this.#searchActive()) {
      // Re-run with restored filters.
      this.#persistFilters();
      this.#search();
    }
  }

  #persistFilters() {
    const q = this.querySelector('#gap-search-input')?.value || '';
    const status = this.querySelector('#gap-filter-status')?.value || '';
    const priority = this.querySelector('#gap-filter-priority')?.value || '';
    const effort = this.querySelector('#gap-filter-effort')?.value || '';
    const has_ac = !!this.querySelector('#gap-filter-has-ac')?.checked;
    const filters = { q, status, priority, effort, has_ac };
    window.chumpPrefs.set('queue.filters', filters);
    // Reflect in URL (replaceState — don't bloat history).
    try {
      const url = new URL(location.href);
      for (const [k, v] of Object.entries({ q, status, priority, effort })) {
        if (v) url.searchParams.set(k, v); else url.searchParams.delete(k);
      }
      if (has_ac) url.searchParams.set('has_ac', 'false'); else url.searchParams.delete('has_ac');
      history.replaceState(null, '', url.toString());
    } catch {}
  }

  /** Clear all filters + storage + URL — wired to the "Clear" button. */
  #clearFilters() {
    const qInput = this.querySelector('#gap-search-input');
    if (qInput) qInput.value = '';
    ['#gap-filter-status', '#gap-filter-priority', '#gap-filter-effort']
      .forEach(sel => { const el = this.querySelector(sel); if (el) el.value = ''; });
    const hasAcCb = this.querySelector('#gap-filter-has-ac');
    if (hasAcCb) hasAcCb.checked = false;
    window.chumpPrefs.del('queue.filters');
    try {
      const url = new URL(location.href);
      ['q', 'status', 'priority', 'effort', 'has_ac'].forEach(k => url.searchParams.delete(k));
      history.replaceState(null, '', url.toString());
    } catch {}
    this.#load();
  }

  disconnectedCallback() {
    clearInterval(this.#poll);
    // INFRA-1196: stop observing for lazy-mount on view-switch + clear
    // the gap-list so embedded components run their own disconnectedCallback
    // (closes the EventSource in <chump-workflow-timeline>, stops the
    // /api/pr/{n} poll in <chump-pr-card>). No leaked SSE streams.
    if (this.#embedObserver) {
      try { this.#embedObserver.disconnect(); } catch {}
      this.#embedObserver = null;
    }
    const list = this.querySelector('#gap-list');
    if (list) list.innerHTML = '';
  }

  #wireSearch() {
    let debounce = null;
    const trigger = () => {
      // INFRA-1280: persist on every change. Search itself stays debounced.
      this.#persistFilters();
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        if (this.#searchActive()) this.#search();
        else this.#load();   // empty filters → fall back to /api/gap-queue
      }, 300);
    };
    this.querySelector('#gap-search-input')?.addEventListener('input', trigger);
    this.querySelector('#gap-filter-status')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-priority')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-effort')?.addEventListener('change', trigger);
    this.querySelector('#gap-filter-has-ac')?.addEventListener('change', trigger);
    // INFRA-1280 Sub-gap 2: explicit Clear button for one-click reset.
    this.querySelector('#gap-filter-clear')?.addEventListener('click', () => this.#clearFilters());
  }

  #searchActive() {
    const q = this.querySelector('#gap-search-input')?.value || '';
    const status = this.querySelector('#gap-filter-status')?.value || '';
    const priority = this.querySelector('#gap-filter-priority')?.value || '';
    const effort = this.querySelector('#gap-filter-effort')?.value || '';
    const hasAc = this.querySelector('#gap-filter-has-ac')?.checked;
    return q || status || priority || effort || hasAc;
  }

  #search() {
    const list = this.querySelector('#gap-list');
    const q = this.querySelector('#gap-search-input')?.value || '';
    const status = this.querySelector('#gap-filter-status')?.value || '';
    const priority = this.querySelector('#gap-filter-priority')?.value || '';
    const effort = this.querySelector('#gap-filter-effort')?.value || '';
    const hasAc = this.querySelector('#gap-filter-has-ac')?.checked;
    const params = new URLSearchParams();
    if (q) params.set('q', q);
    if (status) params.set('status', status);
    if (priority) params.set('priority', priority);
    if (effort) params.set('effort', effort);
    if (hasAc) params.set('has_ac', 'false');
    fetch(`/api/gaps/search?${params}`)
      .then((r) => r.json())
      .then((d) => {
        const results = d.results ?? [];
        if (results.length === 0) {
          list.innerHTML = '<p class="placeholder">No gaps match your search.</p>';
          return;
        }
        list.innerHTML = results.map((g) => `
          <article class="gap-card">
            <header class="gap-card-header">
              <span class="gap-id">${g.id}</span>
              <span class="gap-badge">${g.status || '?'}</span>
              <span class="gap-priority">${g.priority || 'P?'}/${g.effort || '?'}</span>
            </header>
            <p class="gap-title">${g.title || '(no title)'}</p>
          </article>
        `).join('');
      })
      .catch((err) => {
        list.innerHTML = `<p class="placeholder">Search failed: ${err.message}</p>`;
      });
  }

  #load() {
    if (this.#searchActive()) return; // don't stomp search results with poll
    const list = this.querySelector('#gap-list');
    const stats = this.querySelector('#gap-stats');
    // INFRA-1197: response now carries 15 fields per gap (domain, status,
    // closed_pr, assigned_session, pillar, depends_on, …). This consumer
    // still uses only the legacy 6 — see INFRA-1196 to wire <chump-pr-card>
    // (per closed_pr) and <chump-workflow-timeline> (per active workflow)
    // into each row, plus pillar/domain badges + lease-holder indicator.
    fetch('/api/gap-queue')
      .then((r) => r.json())
      .then((d) => {
        const gaps = d.gaps ?? [];
        const claimable = d.claimable_count ?? 0;

        if (gaps.length === 0) {
          list.innerHTML = '<p class="placeholder">No gaps in queue.</p>';
          stats.innerHTML = `
            <div class="stat-item"><span class="stat-value">0</span><span class="stat-label">Open</span></div>
            <div class="stat-item"><span class="stat-value">0</span><span class="stat-label">Claimable</span></div>
          `;
          return;
        }

        stats.innerHTML = `
          <div class="stat-item"><span class="stat-value">${gaps.length}</span><span class="stat-label">Open</span></div>
          <div class="stat-item"><span class="stat-value">${claimable}</span><span class="stat-label">Claimable</span></div>
        `;

        list.innerHTML = gaps.map((g) => this.#renderRow(g)).join('');

        // Attach claim handlers
        list.querySelectorAll('.gap-claim-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#claim(e.target.closest('article'), e.target.dataset.gapId));
        });

        // Attach work/dispatch handlers
        list.querySelectorAll('.gap-work-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#work(e.target.closest('article'), e.target.dataset.gapId));
        });

        // Attach retry handlers (PRODUCT-114)
        list.querySelectorAll('.gap-retry-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#retry(e.target.closest('article'), e.target.dataset.gapId, e.target.dataset.fromPhase));
        });

        // Attach status handlers
        list.querySelectorAll('.gap-status-btn').forEach((btn) => {
          btn.addEventListener('click', (e) => this.#status(e.target.dataset.gapId));
        });

        // INFRA-1196: lazy-mount per-row embeds (pr-card / workflow-timeline)
        // via IntersectionObserver so off-screen rows don't pay the SSE +
        // poll cost. Only rows that scroll into view get their components
        // instantiated. Cleanup happens automatically when innerHTML is
        // replaced on the next #load() — both components disconnect
        // their EventSource / poll timer in disconnectedCallback().
        this.#mountVisibleEmbeds(list);
      })
      .catch((err) => {
        list.innerHTML = `<p class="placeholder">Could not load gap queue: ${err.message}</p>`;
      });
  }

  // PRODUCT-114: disable all action buttons in a row while a call is in-flight (AC-4).
  #setRowPending(article, pending) {
    if (!article) return;
    article.querySelectorAll('.gap-claim-btn,.gap-work-btn,.gap-retry-btn,.gap-status-btn')
      .forEach((btn) => { btn.disabled = pending; });
    if (pending) {
      article.classList.add('gap-row-pending');
    } else {
      article.classList.remove('gap-row-pending');
    }
  }

  // PRODUCT-114: common headers for state-mutating gap POST calls (AC-5).
  // Includes CSRF token required by gap_security_headers_middleware (CREDIBLE-023).
  #gapPostHeaders() {
    return { 'X-CSRF-Token': 'pwa', 'Content-Type': 'application/json' };
  }

  // PRODUCT-114: inline update of the row status badge after a successful claim (AC-1).
  #updateRowStatus(article, statusText) {
    if (!article) return;
    const badge = article.querySelector('.gap-badge');
    if (badge) { badge.textContent = statusText; badge.className = 'gap-badge badge-warn'; }
  }

  // AC-1: Claim button POSTs to /api/gap/claim/{id};
  // row updates with claimed-by + worktree on success.
  #claim(article, gapId) {
    this.#setRowPending(article, true);
    fetch(`/api/gap/claim/${gapId}`, {
      method: 'POST',
      headers: this.#gapPostHeaders(),
    })
      .then((r) => r.json())
      .then((d) => {
        this.#setRowPending(article, false);
        if (d.error) {
          const errEl = article?.querySelector('.gap-error');
          if (errEl) errEl.textContent = `Claim failed: ${d.error}`;
          else alert(`Claim failed: ${d.error}`);
        } else {
          this.#updateRowStatus(article, 'claimed');
          const msg = d.worktree_path ? `Claimed. Worktree: ${d.worktree_path}` : 'Claimed.';
          const actionsEl = article?.querySelector('.gap-actions');
          if (actionsEl) actionsEl.textContent = msg;
          this.#load();
        }
      })
      .catch((err) => {
        this.#setRowPending(article, false);
        alert(`Claim error: ${err.message}`);
      });
  }

  // AC-2: Dispatch button POSTs to /api/gap/work/{id};
  // row shows worker SSE stream inline (via IntersectionObserver embed after #load).
  #work(article, gapId) {
    if (!confirm(`Dispatch a fleet worker for ${gapId}?\n\nThis spawns an autonomous agent workflow.`)) return;
    this.#setRowPending(article, true);
    fetch(`/api/gap/work/${gapId}`, {
      method: 'POST',
      headers: this.#gapPostHeaders(),
    })
      .then((r) => r.json())
      .then((d) => {
        this.#setRowPending(article, false);
        if (d.error) {
          alert(`Dispatch failed: ${d.error}`);
        } else {
          // Reload to mount the SSE workflow-timeline embed for this row.
          this.#load();
        }
      })
      .catch((err) => {
        this.#setRowPending(article, false);
        alert(`Dispatch error: ${err.message}`);
      });
  }

  // AC-3: Retry button POSTs /api/gap/work/{id}/retry;
  // visible when a previous attempt is in-flight or failed (preflight_status=blocked).
  #retry(article, gapId, fromPhase = 'preflight') {
    this.#setRowPending(article, true);
    fetch(`/api/gap/work/${gapId}/retry?from_phase=${encodeURIComponent(fromPhase)}`, {
      method: 'POST',
      headers: this.#gapPostHeaders(),
    })
      .then((r) => r.json())
      .then((d) => {
        this.#setRowPending(article, false);
        if (d.status === 'max_retries_exceeded') {
          alert(`Max retries exceeded for ${gapId} (phase: ${fromPhase}).`);
        } else if (d.error) {
          alert(`Retry failed: ${d.error}`);
        } else {
          this.#load();
        }
      })
      .catch((err) => {
        this.#setRowPending(article, false);
        alert(`Retry error: ${err.message}`);
      });
  }

  #status(gapId) {
    fetch(`/api/gap/status/${gapId}`)
      .then((r) => r.json())
      .then((d) => {
        if (d.error) {
          alert(`Status error: ${d.error}`);
        } else {
          const msg = `Gap: ${gapId}\nStatus: ${d.status}\nTitle: ${d.title}\nPriority: ${d.priority}/${d.effort}`;
          alert(msg);
        }
      })
      .catch((err) => {
        alert(`Status error: ${err.message}`);
      });
  }

  // INFRA-1196: render one queue row with the full INFRA-1197 fat shape:
  // pillar badge, domain chip, AC count, depends-on indicator, lease
  // holder, plus *placeholders* for the embedded components. The
  // components mount lazily via IntersectionObserver in #mountVisibleEmbeds.
  #renderRow(g) {
    const badgeClass = g.preflight_status === 'claimable' ? 'badge-success' :
                      g.preflight_status === 'blocked'   ? 'badge-warn'    :
                                                           'badge-error';
    // PRODUCT-114: three action buttons per gap row.
    // Claim: shown when gap is claimable.
    // Dispatch + Retry: shown when gap is active (blocked by an in-flight session).
    // Retry is always offered alongside Dispatch so the operator can force-retry
    // from a specific phase without having to navigate elsewhere.
    const actions = g.preflight_status === 'claimable'
      ? `<button class="gap-claim-btn" data-gap-id="${g.id}">Claim</button>`
      : g.preflight_status === 'blocked'
      ? `<button class="gap-work-btn" data-gap-id="${g.id}">Dispatch</button>` +
        `<button class="gap-retry-btn" data-gap-id="${g.id}" data-from-phase="preflight">Retry</button>` +
        `<button class="gap-status-btn" data-gap-id="${g.id}">Status</button>`
      : '';

    // Pillar pill — colored. Falls back to nothing when no tag.
    const pillarHtml = g.pillar
      ? `<span class="gap-pillar gap-pillar-${g.pillar}">${g.pillar}</span>`
      : '';
    const domainHtml = g.domain ? `<span class="gap-domain">${g.domain}</span>` : '';
    const acHtml = (g.acceptance_criteria_count != null && g.acceptance_criteria_count > 0)
      ? `<span class="gap-ac" title="${g.acceptance_criteria_count} acceptance criteria">AC ${g.acceptance_criteria_count}</span>`
      : '';
    const depsHtml = (Array.isArray(g.depends_on) && g.depends_on.length > 0)
      ? `<span class="gap-deps" title="depends on: ${g.depends_on.join(', ')}">↳ ${g.depends_on.length} deps</span>`
      : '';

    // Lease holder line — when the gap is claim-blocked by an active session.
    const leaseHtml = g.assigned_session
      ? `<p class="gap-lease" title="${g.assigned_session}">⚙ claimed by ${this.#shortSession(g.assigned_session)}</p>`
      : '';

    // PRODUCT-110: ACP deeplinks — competitive-differentiation surface vs CC.
    // Render "Open in editor ↗" and "Copy" buttons on every gap row. The
    // chump://acp/open?gap=X scheme requires a registered ACP client
    // (Zed / JetBrains / etc) on the operator's machine — if absent, the
    // browser silently ignores the click. The Copy button always works for
    // sharing the link with a teammate or sibling tab.
    const acpHref = ChumpAcpDeeplink.open({ gap: g.id });
    const acpHtml = `
      <a class="gap-acp-link" href="${acpHref}" data-acp-target="gap" data-acp-id="${g.id}"
         title="Open ${g.id} in your registered ACP editor (Zed / JetBrains)"
         aria-label="Open ${g.id} in editor">
        Open in editor ↗
      </a>
      <button type="button" class="gap-acp-copy" data-acp-href="${acpHref}"
              title="Copy ACP deeplink to clipboard"
              aria-label="Copy ACP link for ${g.id}">
        Copy link
      </button>
    `;

    // Embedded slots — placeholders the IntersectionObserver fills.
    // pr-card slot: only when closed_pr is set (a shipped gap surfaced via
    // ?status=shipped or via search).
    const prCardSlot = g.closed_pr
      ? `<div class="gap-embed gap-embed-pr" data-pr-number="${g.closed_pr}" data-mounted="0"></div>`
      : '';
    // workflow-timeline slot: gap status indicates active work. We treat
    // "preflight blocked because someone claimed it" as the canonical
    // active-workflow signal — the alternative ambient-jsonl scan would
    // require a separate API call per gap. assigned_session being set
    // (which we surface above) is what makes blocked → active.
    const isActiveWorkflow = g.preflight_status === 'blocked' && !!g.assigned_session;
    const timelineSlot = isActiveWorkflow
      ? `<div class="gap-embed gap-embed-timeline" data-gap-id="${g.id}" data-mounted="0"></div>`
      : '';

    return `
      <article class="gap-card" data-gap-id="${g.id}">
        <header class="gap-card-header">
          <span class="gap-id">${g.id}</span>
          ${pillarHtml}
          ${domainHtml}
          <span class="gap-badge ${badgeClass}">${g.preflight_status || 'unknown'}</span>
          <span class="gap-priority">${g.priority || 'P?'}/${g.effort || '?'}</span>
          ${acHtml}
          ${depsHtml}
        </header>
        <p class="gap-title">${g.title || '(no title)'}</p>
        ${leaseHtml}
        ${g.preflight_error ? `<p class="gap-error">${g.preflight_error}</p>` : ''}
        ${actions ? `<div class="gap-actions">${actions}</div>` : ''}
        <div class="gap-acp-row">${acpHtml}</div>
        ${timelineSlot}
        ${prCardSlot}
      </article>
    `;
  }

  #shortSession(sid) {
    // claim-infra-1196-16242-1778775648 → infra-1196 (operator-readable).
    const m = String(sid).match(/^claim-([a-z]+-\d+)/i);
    return m ? m[1] : (String(sid).slice(0, 24) + '…');
  }

  // INFRA-1196: lazy-mount embedded <chump-pr-card> + <chump-workflow-timeline>
  // for slots that scroll into view. Reduces SSE/poll cost when the queue
  // is long. Uses one IntersectionObserver per #load() call — replaced on
  // each refresh.
  #mountVisibleEmbeds(list) {
    if (this.#embedObserver) {
      try { this.#embedObserver.disconnect(); } catch {}
    }
    if (typeof IntersectionObserver === 'undefined') {
      // Fallback: mount everything (small queues, old browsers).
      list.querySelectorAll('.gap-embed[data-mounted="0"]').forEach((el) => this.#mountEmbed(el));
      return;
    }
    this.#embedObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting && entry.target.dataset.mounted === '0') {
          this.#mountEmbed(entry.target);
        }
      });
    }, { rootMargin: '200px 0px' /* pre-mount slightly before visible */ });
    list.querySelectorAll('.gap-embed[data-mounted="0"]').forEach((el) => {
      this.#embedObserver.observe(el);
    });
  }

  #mountEmbed(slot) {
    if (slot.dataset.mounted === '1') return;
    slot.dataset.mounted = '1';
    if (slot.classList.contains('gap-embed-pr')) {
      const pr = slot.dataset.prNumber;
      if (!pr) return;
      const card = document.createElement('chump-pr-card');
      card.setAttribute('pr-number', pr);
      slot.appendChild(card);
    } else if (slot.classList.contains('gap-embed-timeline')) {
      const gid = slot.dataset.gapId;
      if (!gid) return;
      const tl = document.createElement('chump-workflow-timeline');
      tl.setAttribute('gap-id', gid);
      slot.appendChild(tl);
    }
  }

  #poll;
  #embedObserver;
}
customElements.define('chump-view-agent', ChumpViewAgent);

// ── <chump-hint-composer> (PRODUCT-116) ──────────────────────────────────────
//
// Strategic-redirect composer: a chat-style input wired to POST /api/inject-hint.
// Operator types a directive ('focus on Effective today', 'pause Resilient work',
// etc.) and selects a TTL preset (15min / 1hr / 4hr / 24hr). On submit the hint
// is posted to the blackboard with high urgency + goal_relevance so it surfaces
// in the next agent turn's context (FLEET-022 already injects operator_hint events
// at SessionStart). History below shows the last 10 hints from ambient.jsonl.
class ChumpHintComposer extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `
      <section class="hint-composer" aria-label="Strategic redirect composer">
        <h3 class="hint-composer-heading">Strategic redirect</h3>
        <p class="hint-composer-desc">Inject a priority directive — agents will pick it up at next session start.</p>
        <div class="hint-input-row">
          <input type="text" id="hint-text" class="hint-text-input" maxlength="500"
            placeholder="e.g. focus on Effective today, pause Resilient work…"
            autocomplete="off" aria-label="Hint text" />
          <button type="button" id="hint-submit" class="hint-submit-btn">Inject</button>
        </div>
        <div class="hint-ttl-row" role="group" aria-label="TTL preset">
          <span class="hint-ttl-label">Expires in:</span>
          <button type="button" class="hint-ttl-btn" data-minutes="15">15 min</button>
          <button type="button" class="hint-ttl-btn hint-ttl-selected" data-minutes="60">1 hr</button>
          <button type="button" class="hint-ttl-btn" data-minutes="240">4 hr</button>
          <button type="button" class="hint-ttl-btn" data-minutes="1440">24 hr</button>
        </div>
        <p class="hint-status" id="hint-status" aria-live="polite"></p>
        <section class="hint-history" aria-label="Recent hints">
          <h4 class="hint-history-heading">Recent hints</h4>
          <ul class="hint-history-list" id="hint-history-list">
            <li class="hint-history-empty">Loading…</li>
          </ul>
        </section>
      </section>
    `;
    this.#selectedTtl = 60;
    this.#wireEvents();
    this.#loadHistory();
  }

  disconnectedCallback() {
    if (this.#historyTimer) clearInterval(this.#historyTimer);
  }

  #selectedTtl = 60;
  #historyTimer = null;

  #wireEvents() {
    // TTL preset selection
    this.querySelectorAll('.hint-ttl-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        this.querySelectorAll('.hint-ttl-btn').forEach((b) => b.classList.remove('hint-ttl-selected'));
        btn.classList.add('hint-ttl-selected');
        this.#selectedTtl = parseInt(btn.dataset.minutes, 10);
      });
    });

    // Submit on button click
    const submitBtn = this.querySelector('#hint-submit');
    const textInput = this.querySelector('#hint-text');
    submitBtn?.addEventListener('click', () => this.#submit());

    // Submit on Enter
    textInput?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this.#submit(); }
    });

    // Refresh history every 30s
    this.#historyTimer = setInterval(() => this.#loadHistory(), 30_000);
  }

  #submit() {
    const textInput = this.querySelector('#hint-text');
    const statusEl = this.querySelector('#hint-status');
    const submitBtn = this.querySelector('#hint-submit');
    const hint = textInput?.value?.trim();
    if (!hint) { if (statusEl) statusEl.textContent = 'Hint cannot be empty.'; return; }

    if (submitBtn) submitBtn.disabled = true;
    if (statusEl) statusEl.textContent = 'Injecting…';

    fetch('/api/inject-hint', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hint, ttl_minutes: this.#selectedTtl }),
    })
      .then((r) => r.json())
      .then((d) => {
        if (submitBtn) submitBtn.disabled = false;
        if (d.ok) {
          if (textInput) textInput.value = '';
          if (statusEl) statusEl.textContent = `✓ Injected (TTL ${this.#selectedTtl} min). Agents will pick up at next session start.`;
          this.#loadHistory();
        } else {
          if (statusEl) statusEl.textContent = `Inject failed: ${d.error ?? 'unknown error'}`;
        }
      })
      .catch((err) => {
        if (submitBtn) submitBtn.disabled = false;
        if (statusEl) statusEl.textContent = `Error: ${err.message}`;
      });
  }

  // AC: fetch recent hints from /api/ambient/recent?kind=operator_hint, show list
  // with TTL countdown (expires_at derived from ts + ttl_minutes).
  #loadHistory() {
    fetch('/api/ambient/recent?kind=operator_hint&n=10')
      .then((r) => r.json())
      .then((d) => {
        const events = (d.events ?? []).slice().reverse(); // newest first
        const list = this.querySelector('#hint-history-list');
        if (!list) return;
        if (events.length === 0) {
          list.innerHTML = '<li class="hint-history-empty">No hints yet.</li>';
          return;
        }
        list.innerHTML = events.map((ev) => {
          const hint = ev.hint ?? ev.text ?? '(no text)';
          const ttl = ev.ttl_minutes ?? 60;
          const ts = ev.ts ?? '';
          const expiresAt = ts ? new Date(new Date(ts).getTime() + ttl * 60 * 1000) : null;
          const remaining = expiresAt ? this.#ttlLabel(expiresAt) : `${ttl} min`;
          return `<li class="hint-history-item">
            <span class="hint-history-text">${this.#esc(hint)}</span>
            <span class="hint-history-ttl">${remaining}</span>
          </li>`;
        }).join('');
      })
      .catch(() => {
        const list = this.querySelector('#hint-history-list');
        if (list) list.innerHTML = '<li class="hint-history-empty">Could not load history.</li>';
      });
  }

  #ttlLabel(expiresAt) {
    const diffMs = expiresAt - Date.now();
    if (diffMs <= 0) return 'expired';
    const mins = Math.floor(diffMs / 60_000);
    if (mins < 60) return `${mins} min left`;
    const hrs = Math.floor(mins / 60);
    return `${hrs} hr left`;
  }

  #esc(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
}
customElements.define('chump-hint-composer', ChumpHintComposer);

// ── <chump-ambient-viewer> (INFRA-1198, filter pills + presets INFRA-1559) ──
//
// Live-tails .chump-locks/ambient.jsonl in the PWA's Events view via the
// existing SSE endpoint (PRODUCT-091, /api/ambient/stream?kind=<X>?).
// Renders a filtered, drillable list:
//   - kind dropdown (top-N curated + "All") — server-side filter via ?kind=
//   - gap + severity filter pills (INFRA-1559) — applied client-side; today's
//     fleet is < 100 active gaps so client-side filtering is fine (server-side
//     is out of scope until ~1000+, per INFRA-1559 AC7)
//   - saved-preset dropdown (workspace-local localStorage, INFRA-1559)
//   - connection indicator (● live / ○ reconnecting / ✕ error)
//   - scrollable list, auto-pinned to bottom unless the user scrolls up
//   - "↓ N new since last viewed" pill appears while scrolled up; click jumps
//     to bottom
//   - click a row → expand to pretty-printed JSON drill-in
//
// Buffer is capped at #maxBuffer to keep DOM bounded under storm conditions.
// EventSource errors are silenced (browser auto-reconnects); the indicator
// flips to ○ during transient disconnects.
class ChumpAmbientViewer extends HTMLElement {
  #es = null;
  #kindFilter = '';
  #gapFilter = '';
  #severityFilter = '';
  #pinnedToBottom = true;
  #buffer = [];
  #pendingNew = 0;
  #connState = 'connecting'; // 'live' | 'reconnecting' | 'error' | 'connecting'

  static #MAX_BUFFER = 500;
  static #PRESET_KEY = 'chump-ambient-filter-presets';

  // Curated kinds for the dropdown — the most operator-meaningful ones.
  // "All" sentinel uses empty string. The list is enrichment, not authoritative;
  // events with other kinds still flow through when filter is "All".
  static #FILTER_OPTIONS = [
    { value: '', label: 'All kinds' },
    { value: 'fleet_auth_fallback',   label: 'fleet_auth_fallback' },
    { value: 'pwa_secret_changed',    label: 'pwa_secret_changed' },
    { value: 'pwa_doctor_check',      label: 'pwa_doctor_check' },
    { value: 'pwa_setting_changed',   label: 'pwa_setting_changed' },
    { value: 'auto_merge_armed',      label: 'auto_merge_armed' },
    { value: 'bot_merge_rest_direct', label: 'bot_merge_rest_direct' },
    { value: 'gh_secondary_limit_hit',label: 'gh_secondary_limit_hit' },
    { value: 'pr_stuck_announced',    label: 'pr_stuck_announced' },
    { value: 'silent_agent',          label: 'silent_agent' },
    { value: 'lease_overlap',         label: 'lease_overlap' },
    { value: 'edit_burst',            label: 'edit_burst' },
  ];

  connectedCallback() {
    // CREDIBLE-135: restore the operator's last kind filter (PRODUCT-098 chumpPrefs)
    // so the ambient-viewer selection survives reloads.
    this.#kindFilter = window.chumpPrefs?.get('ambient-kind-filter', '') || '';
    this.#renderShell();
    this.#subscribe();
  }

  disconnectedCallback() {
    if (this.#es) { this.#es.close(); this.#es = null; }
  }

  #renderShell() {
    const options = ChumpAmbientViewer.#FILTER_OPTIONS.map(o =>
      `<option value="${this.#esc(o.value)}">${this.#esc(o.label)}</option>`
    ).join('');
    const presetOptions = this.#presetOptionsHtml();
    this.innerHTML = `
      <div class="amb-toolbar">
        <label class="amb-filter-label">
          Filter by kind:
          <select class="amb-filter">${options}</select>
        </label>
        <label class="amb-filter-label">
          gap:
          <input type="text" class="amb-gap-filter" placeholder="gap id" />
        </label>
        <label class="amb-filter-label">
          severity:
          <select class="amb-severity-filter">
            <option value="">All</option>
            <option value="info">info</option>
            <option value="warn">warn</option>
            <option value="error">error</option>
          </select>
        </label>
        <span class="amb-state amb-state-connecting" title="connecting…">●</span>
      </div>
      <div class="amb-pillbar">
        <div class="amb-active-pills"></div>
        <div class="amb-preset-bar">
          <select class="amb-preset-select">${presetOptions}</select>
          <input type="text" class="amb-preset-name" placeholder="preset name" />
          <button type="button" class="amb-preset-save">Save preset</button>
        </div>
      </div>
      <div class="amb-pill" style="display:none">↓ <span class="amb-pill-n">0</span> new since last viewed</div>
      <ol class="amb-list" tabindex="0" aria-label="Ambient event stream"></ol>
    `;
    const sel = this.querySelector('.amb-filter');
    if (this.#kindFilter) sel.value = this.#kindFilter;
    sel.addEventListener('change', (e) => this.#applyFilterChange({ kind: e.target.value }));

    const gapInput = this.querySelector('.amb-gap-filter');
    gapInput.value = this.#gapFilter;
    gapInput.addEventListener('change', (e) => this.#applyFilterChange({ gap: e.target.value }));

    const sevSel = this.querySelector('.amb-severity-filter');
    sevSel.value = this.#severityFilter;
    sevSel.addEventListener('change', (e) => this.#applyFilterChange({ severity: e.target.value }));

    const presetSel = this.querySelector('.amb-preset-select');
    presetSel.addEventListener('change', (e) => this.#applyPreset(e.target.value));

    const saveBtn = this.querySelector('.amb-preset-save');
    saveBtn.addEventListener('click', () => this.#saveCurrentPreset());

    const list = this.querySelector('.amb-list');
    list.addEventListener('scroll', () => this.#onScroll());
    const pill = this.querySelector('.amb-pill');
    pill.addEventListener('click', () => this.#jumpToBottom());

    this.#renderActivePills();
  }

  #subscribe() {
    if (this.#es) { this.#es.close(); this.#es = null; }
    this.#setConn('connecting');
    const url = this.#kindFilter
      ? `/api/ambient/stream?kind=${encodeURIComponent(this.#kindFilter)}`
      : '/api/ambient/stream';
    try {
      this.#es = new EventSource(url);
    } catch (err) {
      this.#setConn('error');
      return;
    }
    this.#es.addEventListener('open', () => this.#setConn('live'));
    this.#es.addEventListener('ambient', (e) => {
      let payload;
      try { payload = JSON.parse(e.data); } catch { return; }
      this.#onEvent(payload);
    });
    this.#es.addEventListener('error', () => {
      this.#setConn('reconnecting');
    });
  }

  #onEvent(payload) {
    // Re-validate against the active filter — server should already filter
    // by kind, but gap/severity are client-side only (INFRA-1559 AC7) and
    // this is also defence-in-depth for a race during filter swap.
    if (!this.#matchesFilter(payload)) return;

    this.#buffer.push(payload);
    if (this.#buffer.length > ChumpAmbientViewer.#MAX_BUFFER) {
      const drop = this.#buffer.length - ChumpAmbientViewer.#MAX_BUFFER;
      this.#buffer.splice(0, drop);
    }
    this.#appendRow(payload);
    if (this.#pinnedToBottom) {
      this.#jumpToBottom();
    } else {
      this.#pendingNew += 1;
      this.#refreshPill();
    }
  }

  #appendRow(payload) {
    const list = this.querySelector('.amb-list');
    if (!list) return;
    const li = document.createElement('li');
    li.className = 'amb-row';
    const ts = String(payload.ts || '').slice(11, 19) || '--:--:--';
    const kind = String(payload.kind || payload.event || 'unknown');
    const summary = this.#summarize(payload);
    li.innerHTML = `
      <span class="amb-ts">${this.#esc(ts)}</span>
      <span class="amb-kind">${this.#esc(kind)}</span>
      <span class="amb-summary">${this.#esc(summary)}</span>
      <pre class="amb-detail" hidden></pre>
    `;
    li.addEventListener('click', () => this.#toggleDetail(li, payload));
    list.appendChild(li);
    // Evict DOM rows beyond the buffer cap.
    while (list.children.length > ChumpAmbientViewer.#MAX_BUFFER) {
      list.removeChild(list.firstChild);
    }
  }

  #summarize(p) {
    // Pull the 2-3 most informative fields beyond ts/kind/event.
    const skip = new Set(['ts', 'kind', 'event']);
    const parts = [];
    for (const [k, v] of Object.entries(p)) {
      if (skip.has(k)) continue;
      if (parts.length >= 3) break;
      const valStr = typeof v === 'string' ? v : JSON.stringify(v);
      parts.push(`${k}=${valStr}`);
    }
    return parts.join(' · ');
  }

  #toggleDetail(li, payload) {
    const pre = li.querySelector('.amb-detail');
    if (!pre) return;
    if (pre.hidden) {
      pre.textContent = JSON.stringify(payload, null, 2);
      pre.hidden = false;
    } else {
      pre.hidden = true;
    }
  }

  // INFRA-1559: true when `payload` passes ALL active filter pills
  // (kind — server-filtered too; gap/severity — client-side only per AC7).
  #matchesFilter(payload) {
    if (this.#kindFilter && payload.kind !== this.#kindFilter) return false;
    if (this.#gapFilter) {
      const gapVal = String(payload.gap_id ?? payload.gap ?? '');
      if (!gapVal.toLowerCase().includes(this.#gapFilter.toLowerCase())) return false;
    }
    if (this.#severityFilter && payload.severity !== this.#severityFilter) return false;
    return true;
  }

  // Merges `partial` (any of {kind, gap, severity}) into filter state,
  // emits kind=sse_filter_applied telemetry (AC6), resets the buffer, and
  // re-subscribes (kind is server-side; gap/severity re-filter client-side).
  #applyFilterChange(partial) {
    const prevBuffer = this.#buffer;
    if (typeof partial.kind === 'string') this.#kindFilter = partial.kind;
    if (typeof partial.gap === 'string') this.#gapFilter = partial.gap.trim();
    if (typeof partial.severity === 'string') this.#severityFilter = partial.severity;

    // CREDIBLE-135: persist kind filter so the choice survives reloads (PRODUCT-098 chumpPrefs).
    window.chumpPrefs?.set('ambient-kind-filter', this.#kindFilter);

    const resultsCount = prevBuffer.filter((p) => this.#matchesFilter(p)).length;
    this.#emitFilterTelemetry(resultsCount);

    this.#buffer = [];
    this.#pendingNew = 0;
    const list = this.querySelector('.amb-list');
    if (list) list.innerHTML = '';
    this.#refreshPill();
    this.#renderActivePills();
    this.#subscribe();
  }

  #emitFilterTelemetry(resultsCount) {
    const filterSpec = { kind: this.#kindFilter, gap: this.#gapFilter, severity: this.#severityFilter };
    if (typeof navigator !== 'undefined') {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'sse_filter_applied',
        filter_spec: filterSpec,
        results_count: resultsCount,
      }));
    }
  }

  // ── Filter pills row (INFRA-1559) ─────────────────────────────────────────
  #renderActivePills() {
    const bar = this.querySelector('.amb-active-pills');
    if (!bar) return;
    const active = [];
    if (this.#kindFilter) active.push({ key: 'kind', label: `kind=${this.#kindFilter}` });
    if (this.#gapFilter) active.push({ key: 'gap', label: `gap=${this.#gapFilter}` });
    if (this.#severityFilter) active.push({ key: 'severity', label: `severity=${this.#severityFilter}` });
    if (active.length === 0) {
      bar.innerHTML = '<span class="amb-pill-chip-empty">No active filters</span>';
      return;
    }
    bar.innerHTML = active.map(a =>
      `<span class="amb-pill-chip" data-key="${this.#esc(a.key)}">${this.#esc(a.label)} <button type="button" class="amb-pill-chip-x" data-key="${this.#esc(a.key)}" aria-label="Remove ${this.#esc(a.label)} filter">×</button></span>`
    ).join('');
    bar.querySelectorAll('.amb-pill-chip-x').forEach((btn) => {
      btn.addEventListener('click', (e) => this.#removePill(e.target.getAttribute('data-key')));
    });
  }

  #removePill(key) {
    if (key === 'kind') {
      const sel = this.querySelector('.amb-filter');
      if (sel) sel.value = '';
      this.#applyFilterChange({ kind: '' });
    } else if (key === 'gap') {
      const input = this.querySelector('.amb-gap-filter');
      if (input) input.value = '';
      this.#applyFilterChange({ gap: '' });
    } else if (key === 'severity') {
      const sel = this.querySelector('.amb-severity-filter');
      if (sel) sel.value = '';
      this.#applyFilterChange({ severity: '' });
    }
  }

  // ── Saved presets (INFRA-1559, workspace-local localStorage) ──────────────
  #loadPresets() {
    try {
      const raw = window.localStorage?.getItem(ChumpAmbientViewer.#PRESET_KEY);
      return raw ? JSON.parse(raw) : {};
    } catch {
      return {};
    }
  }

  #savePresets(presets) {
    try {
      window.localStorage?.setItem(ChumpAmbientViewer.#PRESET_KEY, JSON.stringify(presets));
    } catch {
      // best-effort — quota exceeded or localStorage unavailable
    }
  }

  #presetOptionsHtml() {
    const presets = this.#loadPresets();
    const names = Object.keys(presets);
    const opts = ['<option value="">Presets…</option>']
      .concat(names.map(n => `<option value="${this.#esc(n)}">${this.#esc(n)}</option>`));
    return opts.join('');
  }

  #saveCurrentPreset() {
    const nameInput = this.querySelector('.amb-preset-name');
    const name = (nameInput?.value || '').trim();
    if (!name) return;
    const presets = this.#loadPresets();
    presets[name] = { kind: this.#kindFilter, gap: this.#gapFilter, severity: this.#severityFilter };
    this.#savePresets(presets);
    const sel = this.querySelector('.amb-preset-select');
    if (sel) sel.innerHTML = this.#presetOptionsHtml();
    if (nameInput) nameInput.value = '';
  }

  #applyPreset(name) {
    if (!name) return;
    const presets = this.#loadPresets();
    const preset = presets[name];
    if (!preset) return;
    const kindSel = this.querySelector('.amb-filter');
    if (kindSel) kindSel.value = preset.kind || '';
    const gapInput = this.querySelector('.amb-gap-filter');
    if (gapInput) gapInput.value = preset.gap || '';
    const sevSel = this.querySelector('.amb-severity-filter');
    if (sevSel) sevSel.value = preset.severity || '';
    this.#applyFilterChange({
      kind: preset.kind || '',
      gap: preset.gap || '',
      severity: preset.severity || '',
    });
  }

  #onScroll() {
    const list = this.querySelector('.amb-list');
    if (!list) return;
    const atBottom = (list.scrollTop + list.clientHeight) >= (list.scrollHeight - 4);
    this.#pinnedToBottom = atBottom;
    if (atBottom && this.#pendingNew > 0) {
      this.#pendingNew = 0;
      this.#refreshPill();
    }
  }

  #jumpToBottom() {
    const list = this.querySelector('.amb-list');
    if (!list) return;
    list.scrollTop = list.scrollHeight;
    this.#pinnedToBottom = true;
    this.#pendingNew = 0;
    this.#refreshPill();
  }

  #refreshPill() {
    const pill = this.querySelector('.amb-pill');
    const n = this.querySelector('.amb-pill-n');
    if (!pill || !n) return;
    if (this.#pendingNew > 0) {
      pill.style.display = 'block';
      n.textContent = String(this.#pendingNew);
    } else {
      pill.style.display = 'none';
    }
  }

  #setConn(state) {
    this.#connState = state;
    const el = this.querySelector('.amb-state');
    if (!el) return;
    el.className = `amb-state amb-state-${state}`;
    const map = {
      live:         { glyph: '●', title: 'live' },
      reconnecting: { glyph: '○', title: 'reconnecting…' },
      error:        { glyph: '✕', title: 'error' },
      connecting:   { glyph: '●', title: 'connecting…' },
    };
    const m = map[state] || map.connecting;
    el.textContent = m.glyph;
    el.title = m.title;
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-ambient-viewer', ChumpAmbientViewer);

// ── <chump-bandit-regret-panel> (INFRA-1559) ─────────────────────────────────
//
// Pairs with the routing brain (TBD gap, placeholder INFRA-1545): once that
// gap ships bandit-arm choices, it will emit `kind=routing_decision` (a
// decision was made) and `kind=routing_outcome` (arm, reward, optimal_reward)
// on the same ambient stream this component subscribes to. Renders a
// cumulative-regret-per-arm time series so an operator can see at a glance
// whether the routing brain is working (regret flat/slowly-growing = good)
// or degrading (regret growing steeply = investigate).
//
// Until the routing brain ships, this renders an empty-state placeholder —
// filed-and-parked per AC4. No server changes needed: reuses the existing
// INFRA-1010 `?kinds=a,b` multi-kind SSE filter.
class ChumpBanditRegretPanel extends HTMLElement {
  #es = null;
  #arms = {}; // arm -> { cumRegret: number, points: number[] (cumulative regret per outcome) }
  #connState = 'connecting'; // 'live' | 'reconnecting' | 'error' | 'connecting'

  // Cycle through canonical design tokens (CSS_TOKEN_DISCIPLINE, INFRA-1590) —
  // no raw hex literals in JS.
  static #COLORS = ['var(--accent)', 'var(--warn)', 'var(--success)', 'var(--error)', 'var(--text-secondary)'];

  connectedCallback() {
    this.#renderShell();
    this.#subscribe();
  }

  disconnectedCallback() {
    if (this.#es) { this.#es.close(); this.#es = null; }
  }

  #renderShell() {
    this.innerHTML = `
      <div class="regret-toolbar">
        <span class="regret-title">Bandit regret (routing brain)</span>
        <span class="regret-state regret-state-connecting" title="connecting…">●</span>
      </div>
      <div class="regret-empty">Waiting for routing_decision / routing_outcome events (routing brain not yet shipped — TBD-INFRA-1545)…</div>
      <svg class="regret-chart" viewBox="0 0 600 200" preserveAspectRatio="none" hidden></svg>
      <div class="regret-legend"></div>
    `;
  }

  #subscribe() {
    if (this.#es) { this.#es.close(); this.#es = null; }
    this.#setConn('connecting');
    const url = '/api/ambient/stream?kinds=routing_decision,routing_outcome';
    try {
      this.#es = new EventSource(url);
    } catch (err) {
      this.#setConn('error');
      return;
    }
    this.#es.addEventListener('open', () => this.#setConn('live'));
    this.#es.addEventListener('ambient', (e) => {
      let payload;
      try { payload = JSON.parse(e.data); } catch { return; }
      this.#onEvent(payload);
    });
    this.#es.addEventListener('error', () => this.#setConn('reconnecting'));
  }

  #onEvent(payload) {
    const kind = payload.kind || payload.event;
    if (kind !== 'routing_outcome') return; // routing_decision is context only, not chart data
    this.#recordOutcome(payload);
  }

  // Cumulative regret per arm: regret_inc = max(0, optimal_reward - reward),
  // clamped non-negative so the running cumulative sum is monotonic
  // non-decreasing by construction (INFRA-1559 AC5 smoke-test invariant).
  // `optimal_reward` falls back to `reward` (0 regret) until the routing
  // brain starts emitting it.
  #recordOutcome(payload) {
    const arm = String(payload.arm || payload.model_tier || payload.agent_backend || payload.machine || 'unknown');
    const reward = Number(payload.reward ?? 0);
    const optimal = Number(payload.optimal_reward ?? payload.best_reward ?? reward);
    const regretInc = Math.max(0, optimal - reward);

    if (!this.#arms[arm]) this.#arms[arm] = { cumRegret: 0, points: [] };
    const state = this.#arms[arm];
    state.cumRegret += regretInc;
    state.points.push(state.cumRegret);

    this.#render();
  }

  #render() {
    const armNames = Object.keys(this.#arms);
    const empty = this.querySelector('.regret-empty');
    const svg = this.querySelector('.regret-chart');
    const legend = this.querySelector('.regret-legend');
    if (!svg || !legend) return;

    if (armNames.length === 0) {
      if (empty) empty.hidden = false;
      svg.hidden = true;
      return;
    }
    if (empty) empty.hidden = true;
    svg.hidden = false;

    const maxLen = Math.max(...armNames.map(a => this.#arms[a].points.length));
    const maxRegret = Math.max(1, ...armNames.map(a => this.#arms[a].cumRegret));
    const w = 600, h = 200, pad = 6;

    const lines = armNames.map((arm, i) => {
      const color = ChumpBanditRegretPanel.#COLORS[i % ChumpBanditRegretPanel.#COLORS.length];
      const pts = this.#arms[arm].points;
      const coords = pts.map((v, idx) => {
        const x = maxLen > 1 ? (idx / (maxLen - 1)) * (w - 2 * pad) + pad : pad;
        const y = h - pad - (v / maxRegret) * (h - 2 * pad);
        return `${x.toFixed(1)},${y.toFixed(1)}`;
      }).join(' ');
      return `<polyline class="regret-line" data-arm="${this.#esc(arm)}" points="${coords}" fill="none" stroke="${color}" stroke-width="2" />`;
    }).join('');

    // Overlay: "if we had picked the optimal arm always" (computed
    // retrospectively, AC3) — by definition regret against the retrospective
    // optimum is 0, so this is the flat zero baseline every arm's
    // cumulative-regret line is measured against.
    const optimalLine = `<line class="regret-optimal-line" x1="${pad}" y1="${h - pad}" x2="${w - pad}" y2="${h - pad}" stroke="var(--text-secondary)" stroke-width="1" stroke-dasharray="4,3" />`;

    svg.innerHTML = optimalLine + lines;

    legend.innerHTML = armNames.map((arm, i) => {
      const color = ChumpBanditRegretPanel.#COLORS[i % ChumpBanditRegretPanel.#COLORS.length];
      const cum = this.#arms[arm].cumRegret.toFixed(2);
      return `<span class="regret-legend-item"><span class="regret-swatch" style="background:${color}"></span>${this.#esc(arm)} (cum. regret ${cum})</span>`;
    }).join('') + `<span class="regret-legend-item regret-legend-optimal"><span class="regret-swatch regret-swatch-optimal"></span>optimal-always (retrospective)</span>`;
  }

  #setConn(state) {
    this.#connState = state;
    const el = this.querySelector('.regret-state');
    if (!el) return;
    el.className = `regret-state regret-state-${state}`;
    const map = {
      live:         { glyph: '●', title: 'live' },
      reconnecting: { glyph: '○', title: 'reconnecting…' },
      error:        { glyph: '✕', title: 'error' },
      connecting:   { glyph: '●', title: 'connecting…' },
    };
    const m = map[state] || map.connecting;
    el.textContent = m.glyph;
    el.title = m.title;
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
customElements.define('chump-bandit-regret-panel', ChumpBanditRegretPanel);

// ── <chump-view-orchestrator-sessions> (INFRA-1365) ───────────────────────────
// CREDIBLE — surfaces orchestrate_session_summary ambient events so operators
// can see Phase 3/4 demo metrics (cost, wall time, intent-routing rate) without
// grepping ambient.jsonl.
//
// Layout: 3 SVG sparklines at the top (cost, wall_time_s, intent ratio) + a
// scrollable per-session row table below. Empty-state copy when no data.
//
// Data sources:
//   - Initial load: GET /api/ambient/recent?kind=orchestrate_session_summary&n=50
//   - Live tail:    EventSource /api/ambient/stream?kind=orchestrate_session_summary
//
// Telemetry: emits kind=ui_view_render on connectedCallback.
class ChumpViewOrchestratorSessions extends HTMLElement {
  #sessions = []; // chronological array of orchestrate_session_summary events
  #es = null;
  #MAX = 50;

  connectedCallback() {
    this.#render();
    this.#emitTelemetry();
    this.#loadHistory();
    this.#subscribe();
  }

  disconnectedCallback() {
    if (this.#es) { this.#es.close(); this.#es = null; }
  }

  // ── Render shell ────────────────────────────────────────────────────────────
  #render() {
    this.innerHTML = `
      <section class="view-header">
        <h2>Orchestrator sessions</h2>
        <p class="view-subtitle">Last 50 orchestrate sessions · 24h rolling window · kind=orchestrate_session_summary</p>
      </section>
      <section class="orch-sparklines" id="orch-sparklines" aria-label="Orchestrator session sparklines">
        <figure class="orch-sparkline-fig" id="orch-fig-cost">
          <figcaption class="orch-spark-label">Cost (USD)</figcaption>
          <svg class="orch-spark-svg" id="orch-spark-cost" viewBox="0 0 200 40"
               aria-label="Cost per session sparkline" role="img"></svg>
        </figure>
        <figure class="orch-sparkline-fig" id="orch-fig-wall">
          <figcaption class="orch-spark-label">Wall time (s)</figcaption>
          <svg class="orch-spark-svg" id="orch-spark-wall" viewBox="0 0 200 40"
               aria-label="Wall time per session sparkline" role="img"></svg>
        </figure>
        <figure class="orch-sparkline-fig" id="orch-fig-intent">
          <figcaption class="orch-spark-label">Intent ratio</figcaption>
          <svg class="orch-spark-svg" id="orch-spark-intent" viewBox="0 0 200 40"
               aria-label="Intent-routing ratio per session sparkline" role="img"></svg>
        </figure>
      </section>
      <section class="orch-table-wrap" id="orch-table-wrap" aria-live="polite" aria-busy="true">
        <p class="orch-placeholder" id="orch-placeholder">Loading orchestrator sessions…</p>
        <table class="orch-table" id="orch-table" hidden>
          <thead>
            <tr>
              <th scope="col">Time</th>
              <th scope="col">Session</th>
              <th scope="col">Intents</th>
              <th scope="col">Tools</th>
              <th scope="col">Cost</th>
              <th scope="col">Exit</th>
            </tr>
          </thead>
          <tbody id="orch-tbody"></tbody>
        </table>
      </section>
    `;
  }

  // ── Telemetry ───────────────────────────────────────────────────────────────
  #emitTelemetry() {
    try {
      navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
        kind: 'ui_view_render',
        subject: 'orchestrator-sessions',
        ts: new Date().toISOString(),
      }));
    } catch {}
  }

  // ── Historical load ─────────────────────────────────────────────────────────
  async #loadHistory() {
    try {
      const r = await fetch('/api/ambient/recent?kind=orchestrate_session_summary&n=50');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const events = await r.json();
      if (Array.isArray(events) && events.length > 0) {
        // Sort ascending so sparklines flow left→right.
        events.sort((a, b) => String(a.ts || '').localeCompare(String(b.ts || '')));
        for (const ev of events) this.#ingest(ev, /* repaint */ false);
        this.#repaint();
      } else {
        this.#showEmpty();
      }
    } catch {
      this.#showEmpty();
    }
    // Mark table section no longer busy.
    this.querySelector('#orch-table-wrap')?.removeAttribute('aria-busy');
  }

  // ── Live SSE ────────────────────────────────────────────────────────────────
  #subscribe() {
    if (this.#es) { this.#es.close(); this.#es = null; }
    try {
      this.#es = new EventSource('/api/ambient/stream?kind=orchestrate_session_summary');
    } catch { return; }
    this.#es.addEventListener('ambient', (e) => {
      let payload;
      try { payload = JSON.parse(e.data); } catch { return; }
      if (payload.kind !== 'orchestrate_session_summary') return;
      this.#ingest(payload, /* repaint */ true);
    });
  }

  // ── Data ingestion ───────────────────────────────────────────────────────────
  #ingest(ev, repaint) {
    this.#sessions.push(ev);
    if (this.#sessions.length > this.#MAX) {
      this.#sessions.shift(); // drop oldest
    }
    if (repaint) this.#repaint();
  }

  // ── Full repaint ─────────────────────────────────────────────────────────────
  #repaint() {
    if (this.#sessions.length === 0) { this.#showEmpty(); return; }
    this.#paintSparklines();
    this.#paintTable();
    // Reveal table, hide placeholder.
    const ph = this.querySelector('#orch-placeholder');
    const tbl = this.querySelector('#orch-table');
    if (ph) ph.hidden = true;
    if (tbl) tbl.hidden = false;
  }

  // ── Sparklines ───────────────────────────────────────────────────────────────
  #paintSparklines() {
    const cost   = this.#sessions.map(s => Number(s.cost_usd   ?? s.cost   ?? 0));
    const wall   = this.#sessions.map(s => Number(s.wall_time_s ?? 0));
    const intent = this.#sessions.map(s => {
      const total  = Number(s.intents_total  ?? (Number(s.intents_routed ?? 0) + Number(s.intents_failed ?? 0)));
      const routed = Number(s.intents_routed ?? 0);
      return total > 0 ? routed / total : 0;
    });
    this.#drawSparkline('#orch-spark-cost',   cost,   '#30d158');
    this.#drawSparkline('#orch-spark-wall',   wall,   '#0a84ff');
    this.#drawSparkline('#orch-spark-intent', intent, '#ff9f0a');
  }

  #drawSparkline(selector, values, stroke) {
    const svg = this.querySelector(selector);
    if (!svg || values.length === 0) return;
    const W = 200, H = 40, PAD = 4;
    const min = Math.min(...values);
    const max = Math.max(...values);
    const range = max - min || 1;
    const n = values.length;
    const pts = values.map((v, i) => {
      const x = PAD + (i / Math.max(n - 1, 1)) * (W - 2 * PAD);
      const y = H - PAD - ((v - min) / range) * (H - 2 * PAD);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(' ');
    svg.innerHTML = `
      <polyline points="${this.#escAttr(pts)}"
                fill="none" stroke="${this.#escAttr(stroke)}" stroke-width="1.5"
                stroke-linejoin="round" stroke-linecap="round"/>
      <circle cx="${this.#escAttr(String((PAD + (W - 2 * PAD)).toFixed(1)))}"
              cy="${this.#escAttr(String((H - PAD - ((values[values.length - 1] - min) / range) * (H - 2 * PAD)).toFixed(1)))}"
              r="2.5" fill="${this.#escAttr(stroke)}"/>
    `;
  }

  // ── Table ─────────────────────────────────────────────────────────────────────
  #paintTable() {
    const tbody = this.querySelector('#orch-tbody');
    if (!tbody) return;
    tbody.innerHTML = '';
    // Render newest-first.
    for (const s of [...this.#sessions].reverse()) {
      const tr = document.createElement('tr');
      tr.className = 'orch-row';
      const ts    = this.#fmtTs(s.ts);
      const sid   = String(s.session_id || s.session || '—').slice(0, 32);
      const routed = Number(s.intents_routed ?? 0);
      const failed = Number(s.intents_failed ?? 0);
      const tools  = Number(s.tool_calls ?? 0);
      const cost   = Number(s.cost_usd ?? s.cost ?? 0);
      const exit   = String(s.exit_reason ?? 'unknown');
      const exitCls = exit === 'clean' ? 'orch-exit-clean'
                    : (exit === 'crash' || exit === 'timeout') ? 'orch-exit-bad'
                    : 'orch-exit-gray';
      tr.innerHTML = `
        <td class="orch-cell-ts">${this.#esc(ts)}</td>
        <td class="orch-cell-sid">
          <button class="orch-sid-btn" type="button"
                  data-sid="${this.#escAttr(sid)}"
                  title="Filter ambient stream to session ${this.#escAttr(sid)}">${this.#esc(sid)}</button>
        </td>
        <td class="orch-cell-num">${this.#esc(String(routed))}/${this.#esc(String(failed))}</td>
        <td class="orch-cell-num">${this.#esc(String(tools))}</td>
        <td class="orch-cell-num">$${this.#esc(cost.toFixed(4))}</td>
        <td><span class="orch-exit ${this.#escAttr(exitCls)}">${this.#esc(exit)}</span></td>
      `;
      // Click session_id → navigate to ambient filtered to that session.
      tr.querySelector('.orch-sid-btn')?.addEventListener('click', (e) => {
        const id = e.currentTarget.dataset.sid;
        // Dispatch navigation to ambient view with session filter hint.
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: 'ambient' }));
        // After a tick, try to set the ambient viewer's session filter if present.
        setTimeout(() => {
          const viewer = document.querySelector('chump-ambient-viewer');
          if (viewer && typeof viewer.setFilter === 'function') viewer.setFilter(id);
        }, 50);
      });
      tbody.appendChild(tr);
    }
  }

  // ── Empty state ───────────────────────────────────────────────────────────────
  #showEmpty() {
    const ph = this.querySelector('#orch-placeholder');
    if (!ph) return;
    ph.hidden = false;
    ph.innerHTML = `
      <span class="orch-empty-icon">🎛</span>
      <span>No orchestrator sessions in the last 24h —
        run <code>chump orchestrate</code> to populate.</span>
      <a class="orch-empty-link"
         href="docs/process/CHUMP_ORCHESTRATE.md"
         target="_blank" rel="noopener">View docs</a>
    `;
    const tbl = this.querySelector('#orch-table');
    if (tbl) tbl.hidden = true;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────
  #fmtTs(ts) {
    try {
      const d = new Date(ts);
      if (isNaN(d.getTime())) return String(ts ?? '—').slice(0, 19);
      const ageS = (Date.now() - d.getTime()) / 1000;
      if (ageS < 60)    return `${Math.round(ageS)}s ago`;
      if (ageS < 3600)  return `${Math.round(ageS / 60)}m ago`;
      if (ageS < 86400) return `${Math.round(ageS / 3600)}h ago`;
      return d.toISOString().slice(0, 16).replace('T', ' ');
    } catch { return String(ts ?? '—').slice(0, 19); }
  }

  #esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  #escAttr(s) { return this.#esc(s); }
}
customElements.define('chump-view-orchestrator-sessions', ChumpViewOrchestratorSessions);

// ── Router ────────────────────────────────────────────────────────────────────
// PRODUCT-091: ambient event viewer view factory.
function makeAmbientView() {
  const el = document.createElement('div');
  el.className = 'view-panel';
  el.innerHTML = `
    <h2 class="view-title">Ambient Events</h2>
    <p class="view-subtitle">Real-time tail of .chump-locks/ambient.jsonl — fleet activity stream</p>
    <chump-ambient-viewer></chump-ambient-viewer>
    <h3 class="view-title regret-panel-title">Bandit Regret</h3>
    <chump-bandit-regret-panel></chump-bandit-regret-panel>`;
  return el;
}

const VIEWS = {
  chat:          () => document.createElement('chump-view-chat'),
  agents:        () => document.createElement('chump-view-agents'),
  results:       () => document.createElement('chump-view-results'),
  agent:         () => document.createElement('chump-view-agent'),
  tasks:         () => document.createElement('chump-view-tasks'),
  decisions:     () => document.createElement('chump-view-decisions'),
  judgment:      () => document.createElement('chump-view-judgment'),
  audit:         () => document.createElement('chump-view-audit'), // PRODUCT-111

  network:       () => document.createElement('chump-view-network-audit'), // PRODUCT-112

  roadmap:       () => document.createElement('chump-view-roadmap'), // INFRA-1207

  health:        () => document.createElement('chump-view-fleet-health'), // INFRA-1203

  coord:         () => document.createElement('chump-view-coord'), // INFRA-1204
  orchestrator:  () => document.createElement('chump-view-orchestrator-sessions'), // INFRA-1365
  ambient:       makeAmbientView,
  notifications: () => document.createElement('chump-view-notifications'), // PRODUCT-094
  attention:     () => document.createElement('chump-operator-attention'), // PRODUCT-117
  stuck:         () => document.createElement('chump-stuck-items'),        // PRODUCT-080
  config:        () => document.createElement('chump-config-dials'), // PRODUCT-118
  prs:           () => document.createElement('chump-view-prs'),           // PRODUCT-084

  cockpit:       () => document.createElement('chump-view-cockpit'),        // PRODUCT-122
  memory:        () => document.createElement('chump-view-memory'),
  models:        () => document.createElement('chump-view-models'),
  settings:      () => document.createElement('chump-view-settings'),
  impact:        () => document.createElement('chump-view-impact'),          // PRODUCT-081
  brief:         () => document.createElement('chump-view-brief'),           // PRODUCT-078
};

document.addEventListener('chump:navigate', (e) => {
  const main = document.getElementById('main-content');
  if (!main) return;
  const factory = VIEWS[e.detail] ?? VIEWS.tasks;
  main.innerHTML = '';
  main.appendChild(factory());
  // PRODUCT-098: persist current view so refresh restores it.
  window.chumpPrefs?.set('last-view', e.detail);
});

// ── Boot ──────────────────────────────────────────────────────────────────────
if ('serviceWorker' in navigator) {
  // INFRA-250: relative URL + relative scope so the SW registers correctly
  // in both axum-sidecar context (resolves to /v2/sw.js with /v2/ scope)
  // and Tauri context (where frontendDist = web/v2, so root-relative paths
  // would 404).
  navigator.serviceWorker.register('sw.js', { scope: './' }).catch(() => {});
}

// Initial view.
window.addEventListener('DOMContentLoaded', () => {
  const main = document.getElementById('main-content');
  // PRODUCT-098: restore last view from prefs; default to 'chat'.
  const lastView = window.chumpPrefs?.get('last-view', 'chat') ?? 'chat';
  const factory = VIEWS[lastView] ?? VIEWS.chat;
  if (main) {
    main.appendChild(factory());
    // Sync nav highlight: clear default chat highlight, then set the restored view.
    // Guard: only remove chat highlight if we're restoring a different view.
    if (lastView !== 'chat') {
      document.querySelector('[data-view="chat"]')?.removeAttribute('aria-current');
      document.querySelector(`[data-view="${lastView}"]`)?.setAttribute('aria-current', 'page');
    }
    // If lastView === 'chat', the HTML's default aria-current on chat is already correct.
  }
});
