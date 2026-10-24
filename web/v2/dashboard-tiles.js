// web/v2/dashboard-tiles.js — INFRA-2215
//
// <chump-dashboard-tiles> — 3-tile PWA cockpit dashboard consuming
// GET /api/dashboard-summary (INFRA-1883, PR #2777).
//
// Tiles: ships-today / ci-qa-score / active-leases. Read-only — no tile
// mutates state; clicking a gap_id in the active-leases tile navigates via
// the existing chump:navigate event (same contract as gap-list.js), it does
// not edit anything.
//
// Marcus-arc demo #3 — must be visible from `/` with no auth gate and look
// polished enough to screenshot on first render (skeleton → data or an
// inline error pill with retry, never an empty tile).

const CSS = `
  :host { display: block; }
  .tiles {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
  }
  @media (max-width: 900px) {
    .tiles { grid-template-columns: 1fr; }
  }
  .tile {
    background: var(--bg-secondary, #1a1a1c);
    border: 1px solid var(--border, #2a2a2e);
    border-radius: 10px;
    padding: 14px 16px;
    min-height: 110px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .tile-label {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary, #8a8a8e);
  }
  .tile-value {
    font-size: 30px;
    font-weight: 700;
    color: var(--text, #e5e5ea);
    font-variant-numeric: tabular-nums;
    line-height: 1.1;
  }
  .tile-value.tone-green { color: var(--success, #30d158); }
  .tile-value.tone-amber { color: var(--warn, #ff9f0a); }
  .tile-value.tone-red   { color: var(--error, #ff453a); }
  .tile-value.tone-gray  { color: var(--text-secondary, #8a8a8e); }
  .tile-meta {
    font-size: 11px;
    color: var(--text-secondary, #8a8a8e);
  }

  /* Skeleton loading state */
  .skeleton-bar {
    height: 30px; width: 70%;
    border-radius: 4px;
    background: linear-gradient(90deg,
      var(--bg-tertiary, #25252a) 25%,
      var(--border, #2a2a2e) 50%,
      var(--bg-tertiary, #25252a) 75%);
    background-size: 200% 100%;
    animation: dash-tile-shimmer 1.2s ease-in-out infinite;
  }
  @keyframes dash-tile-shimmer {
    0% { background-position: 200% 0; }
    100% { background-position: -200% 0; }
  }

  /* Error pill + retry */
  .tile-error {
    display: flex; flex-direction: column; gap: 8px;
    align-items: flex-start;
  }
  .tile-error-pill {
    display: inline-flex; align-items: center; gap: 6px;
    font-size: 11px; color: var(--error, #ff453a);
    background: rgba(255,69,58,0.14);
    border: 1px solid rgba(255,69,58,0.35);
    border-radius: 12px;
    padding: 3px 10px;
  }
  .tile-retry {
    background: var(--bg-tertiary, #25252a);
    border: 1px solid var(--border, #2a2a2e);
    color: var(--text, #e5e5ea);
    border-radius: 5px;
    padding: 4px 10px;
    font-size: 11px;
    cursor: pointer;
  }
  .tile-retry:hover { background: var(--accent, #0a84ff); color: #fff; border-color: transparent; }

  /* Active-leases list */
  .lease-list {
    list-style: none; margin: 0; padding: 0;
    display: flex; flex-direction: column; gap: 4px;
    overflow: auto;
    max-height: 180px;
  }
  .lease-row {
    display: flex; justify-content: space-between; align-items: baseline;
    gap: 8px; font-size: 12px;
  }
  .lease-gap {
    background: none; border: none; padding: 0;
    color: var(--accent, #0a84ff); cursor: pointer;
    font-family: ui-monospace, monospace; font-size: 12px;
    text-decoration: none;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .lease-gap:hover { text-decoration: underline; }
  .lease-countdown {
    flex: 0 0 auto;
    font-variant-numeric: tabular-nums;
    color: var(--text-secondary, #8a8a8e);
    white-space: nowrap;
  }
  .lease-countdown.expired { color: var(--error, #ff453a); }
  .lease-empty {
    font-size: 12px; color: var(--text-secondary, #8a8a8e);
    font-style: italic;
  }
`;

class ChumpDashboardTiles extends HTMLElement {
  #shadow;
  #timer;

  constructor() {
    super();
    this.#shadow = this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.#renderSkeleton();
    this.#load();
    this.#timer = setInterval(() => this.#load(), 60_000);
  }

  disconnectedCallback() {
    clearInterval(this.#timer);
  }

  async #load() {
    try {
      const r = await fetch('/api/dashboard-summary');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      this.#renderData(data);
    } catch (e) {
      this.#renderError();
    }
  }

  #renderSkeleton() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="tiles" aria-label="Dashboard summary" aria-busy="true">
        ${['Ships today', 'CI/QA score', 'Active leases'].map((label) => `
          <div class="tile">
            <div class="tile-label">${label}</div>
            <div class="skeleton-bar"></div>
          </div>
        `).join('')}
      </div>
    `;
  }

  #renderError() {
    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="tiles" aria-label="Dashboard summary">
        <div class="tile">
          <div class="tile-label">Dashboard</div>
          <div class="tile-error">
            <span class="tile-error-pill">⚠ couldn't load dashboard summary</span>
            <button type="button" class="tile-retry" id="retry-btn">Retry</button>
          </div>
        </div>
      </div>
    `;
    this.#shadow.getElementById('retry-btn')?.addEventListener('click', () => {
      this.#renderSkeleton();
      this.#load();
    });
  }

  #renderData(data) {
    const shipsToday = Number.isFinite(data.today_ships) ? data.today_ships : 0;
    const ci = data.ci_qa_score || null;
    const leases = Array.isArray(data.active_leases) ? data.active_leases.slice() : [];

    // AC 4: sorted expiry-soonest-first regardless of backend ordering.
    leases.sort((a, b) => {
      const ta = Date.parse(a.expires_at || '');
      const tb = Date.parse(b.expires_at || '');
      if (Number.isNaN(ta) && Number.isNaN(tb)) return 0;
      if (Number.isNaN(ta)) return 1;
      if (Number.isNaN(tb)) return -1;
      return ta - tb;
    });
    const top10 = leases.slice(0, 10);

    const wedgedPrs = Number.isFinite(data.landing_wedged_prs)
      ? data.landing_wedged_prs
      : (Number.isFinite(data.stuck_prs) ? data.stuck_prs : (ci?.stuck_prs ?? 0));
    const ciTone = ChumpDashboardTiles.#ciTone(ci, wedgedPrs);
    const ciLabel = ci
      ? `${ci.pct.toFixed(0)}%`
      : '—';
    const wedgedSuffix = wedgedPrs > 0 ? ` · ${wedgedPrs} wedged` : '';
    const ciMeta = ci
      ? `${ci.sample_size} run${ci.sample_size === 1 ? '' : 's'} · ${ci.status}${wedgedSuffix}`
      : 'no recent CI/QA score';

    const leaseRows = top10.length
      ? top10.map((l) => `
          <li class="lease-row">
            <button type="button" class="lease-gap" data-gap="${ChumpDashboardTiles.#esc(l.gap)}">${ChumpDashboardTiles.#esc(l.gap)}</button>
            <span class="lease-countdown" data-expires="${ChumpDashboardTiles.#esc(l.expires_at)}"></span>
          </li>
        `).join('')
      : `<li class="lease-empty">no active leases</li>`;

    this.#shadow.innerHTML = `
      <style>${CSS}</style>
      <div class="tiles" aria-label="Dashboard summary">
        <div class="tile" aria-label="Ships today">
          <div class="tile-label">Ships today</div>
          <div class="tile-value">${shipsToday}</div>
          <div class="tile-meta">last ${data.window_hours ?? 24}h</div>
        </div>

        <div class="tile" aria-label="CI/QA score">
          <div class="tile-label">CI/QA score</div>
          <div class="tile-value tone-${ciTone}">${ciLabel}</div>
          <div class="tile-meta">${ciMeta}</div>
        </div>

        <div class="tile" aria-label="Active leases">
          <div class="tile-label">Active leases</div>
          <ul class="lease-list">${leaseRows}</ul>
        </div>
      </div>
    `;

    this.#shadow.querySelectorAll('.lease-gap').forEach((btn) => {
      btn.addEventListener('click', () => {
        const gap = btn.dataset.gap;
        if (!gap) return;
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: `gaps/${gap}` }));
        document.dispatchEvent(new CustomEvent('chump:gap-detail', { detail: { id: gap } }));
      });
    });

    this.#shadow.querySelectorAll('.lease-countdown').forEach((el) => {
      ChumpDashboardTiles.#renderCountdown(el);
    });
  }

  static #ciTone(ci, wedgedPrs = 0) {
    if (!ci || typeof ci.pct !== 'number') return 'gray';
    const st = String(ci.status ?? '').toLowerCase();
    if (st === 'red' || wedgedPrs >= 5 || ci.pct < 50) return 'red';
    if (st === 'amber' || wedgedPrs > 0 || ci.pct < 80) return 'amber';
    if (st === 'unknown') return 'gray';
    return 'green';
  }

  static #renderCountdown(el) {
    const expiresAt = el.dataset.expires;
    const t = Date.parse(expiresAt || '');
    if (Number.isNaN(t)) {
      el.textContent = '—';
      return;
    }
    const deltaMs = t - Date.now();
    if (deltaMs <= 0) {
      el.textContent = 'expired';
      el.classList.add('expired');
      return;
    }
    const mins = Math.round(deltaMs / 60_000);
    el.textContent = mins < 60
      ? `${mins}m`
      : `${Math.round(mins / 60)}h ${mins % 60}m`;
  }

  static #esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
}
customElements.define('chump-dashboard-tiles', ChumpDashboardTiles);
