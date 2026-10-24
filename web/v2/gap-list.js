// gap-list.js — PRODUCT-102
// <chump-view-gaps> — scrollable / filterable gap list browser.
//
// Features:
//   - Loads all gaps via GET /api/gaps (server-side status/priority/domain filter)
//   - Client-side search box filters rows by ID or title substring
//   - Sortable columns: ID, status, priority, pillar, effort
//   - Per-file collapse groups by domain
//   - Pagination at 100 rows per page (handles 500+ without scroll stutter)
//   - Row click navigates to /gaps/{id} detail (chump:navigate + detail event)
//   - 'Claim' button on each open/claimable row → POST /api/gap/{id}/claim
//   - Emits kind=pwa_gap_list_filtered to /api/ambient/emit when filter changes

const PAGE_SIZE = 100;

const PRIORITY_ORDER = {
  P0: 0, p0: 0, critical: 0, CRITICAL: 0,
  P1: 1, p1: 1, high: 1, HIGH: 1,
  P2: 2, p2: 2, medium: 2, MEDIUM: 2,
  P3: 3, p3: 3, low: 3, LOW: 3,
  P4: 4, p4: 4,
};
const EFFORT_ORDER = { xs: 0, s: 1, m: 2, l: 3, xl: 4 };

function priorityRank(p) {
  if (!p) return 99;
  const trimmed = String(p).trim();
  return PRIORITY_ORDER[trimmed] ?? PRIORITY_ORDER[trimmed.toLowerCase()] ?? PRIORITY_ORDER[trimmed.toUpperCase()] ?? 99;
}

function priorityBadge(p) {
  const colors = {
    P0: '#e53e3e', critical: '#e53e3e',
    P1: '#dd6b20', high: '#dd6b20',
    P2: '#3182ce', medium: '#3182ce',
    P3: '#718096', low: '#718096',
  };
  const c = colors[p] ?? colors[String(p ?? '').toLowerCase()] ?? '#718096';
  return `<span class="gb-badge" style="background:${c}">${p}</span>`;
}
function statusBadge(s) {
  const colors = { open: '#38a169', claimed: '#3182ce', shipped: '#805ad5', done: '#718096' };
  const c = colors[s] ?? '#718096';
  return `<span class="gb-badge" style="background:${c}">${s}</span>`;
}
function pillarBadge(p) {
  if (!p) return '';
  const colors = {
    EFFECTIVE: '#3182ce', CREDIBLE: '#38a169',
    RESILIENT: '#dd6b20', 'ZERO-WASTE': '#805ad5', MISSION: '#e53e3e',
  };
  const c = colors[p] ?? '#718096';
  return `<span class="gb-badge" style="background:${c};font-size:0.7em">${p}</span>`;
}

class ChumpViewGaps extends HTMLElement {
  #gaps = [];
  #filtered = [];
  #page = 0;
  #sortCol = 'priority';
  #sortAsc = true;
  #statusFilter = '';
  #priorityFilter = '';
  #domainFilter = '';
  #pillarFilter = '';
  #searchQuery = '';
  #loading = false;

  connectedCallback() {
    this.attachShadow({ mode: 'open' });
    this.shadowRoot.innerHTML = this.#css() + this.#skeleton();
    this.#wireUI();
    this.#load();
  }

  // ── Fetch ───────────────────────────────────────────────────────────────────

  async #load() {
    if (this.#loading) return;
    this.#loading = true;
    this.#setStatus('Loading gaps…');

    try {
      // Fetch all statuses by default so the browser shows a complete picture,
      // forwarding active status/priority/domain filters to /api/gaps (INFRA-8179).
      const qs = new URLSearchParams({
        status: this.#statusFilter || 'open,claimed,shipped,done',
      });
      if (this.#priorityFilter) qs.set('priority', this.#priorityFilter);
      if (this.#domainFilter) qs.set('domain', this.#domainFilter);
      const r = await fetch(`/api/gaps?${qs}`, {
        headers: { ...this.#authHeaders() },
        credentials: 'same-origin',
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const data = await r.json();
      const rawGaps = Array.isArray(data) ? data : (data.gaps ?? []);
      this.#gaps = rawGaps.slice().sort((a, b) => priorityRank(a.priority) - priorityRank(b.priority));
      this.#applyFilters();
    } catch (err) {
      this.#setStatus(`Error loading gaps: ${err.message}`);
    } finally {
      this.#loading = false;
    }
  }

  // ── Filtering / sorting ─────────────────────────────────────────────────────

  #applyFilters() {
    const q = this.#searchQuery.toLowerCase();
    this.#filtered = this.#gaps.filter(g => {
      if (this.#statusFilter && g.status !== this.#statusFilter) return false;
      if (
        this.#priorityFilter &&
        g.priority !== this.#priorityFilter &&
        priorityRank(g.priority) !== priorityRank(this.#priorityFilter)
      ) {
        return false;
      }
      if (this.#domainFilter && g.domain !== this.#domainFilter) return false;
      if (this.#pillarFilter && (g.pillar ?? '') !== this.#pillarFilter) return false;
      if (q && !(g.id ?? '').toLowerCase().includes(q) && !(g.title ?? '').toLowerCase().includes(q)) return false;
      return true;
    });
    this.#sortGaps();
    this.#page = 0;
    this.#render();
  }

  #sortGaps() {
    const col = this.#sortCol;
    const asc = this.#sortAsc ? 1 : -1;
    this.#filtered.sort((a, b) => {
      let va, vb;
      if (col === 'priority') {
        va = priorityRank(a.priority);
        vb = priorityRank(b.priority);
      } else if (col === 'effort') {
        va = EFFORT_ORDER[a.effort] ?? 9;
        vb = EFFORT_ORDER[b.effort] ?? 9;
      } else {
        va = (a[col] ?? '').toString().toLowerCase();
        vb = (b[col] ?? '').toString().toLowerCase();
      }
      return va < vb ? -asc : va > vb ? asc : 0;
    });
  }

  // ── Rendering ───────────────────────────────────────────────────────────────

  #render() {
    const start = this.#page * PAGE_SIZE;
    const page = this.#filtered.slice(start, start + PAGE_SIZE);
    const total = this.#filtered.length;

    const sr = this.shadowRoot;
    sr.querySelector('.gb-count').textContent =
      `${total} gap${total === 1 ? '' : 's'}` +
      (total !== this.#gaps.length ? ` (of ${this.#gaps.length})` : '');

    const tbody = sr.querySelector('tbody');
    tbody.innerHTML = page.map(g => this.#row(g)).join('');

    // Pagination controls
    const pages = Math.ceil(total / PAGE_SIZE);
    const pg = sr.querySelector('.gb-pagination');
    pg.innerHTML = pages <= 1 ? '' : `
      <button class="gb-btn" id="pg-prev" ${this.#page === 0 ? 'disabled' : ''}>◀</button>
      <span>Page ${this.#page + 1} / ${pages}</span>
      <button class="gb-btn" id="pg-next" ${this.#page >= pages - 1 ? 'disabled' : ''}>▶</button>
    `;
    sr.querySelector('#pg-prev')?.addEventListener('click', () => { this.#page--; this.#render(); });
    sr.querySelector('#pg-next')?.addEventListener('click', () => { this.#page++; this.#render(); });

    // Wire row actions
    tbody.querySelectorAll('[data-gap-id]').forEach(tr => {
      tr.addEventListener('click', e => {
        if (e.target.closest('.gb-claim-btn')) return; // let claim button handle it
        const id = tr.dataset.gapId;
        document.dispatchEvent(new CustomEvent('chump:navigate', { detail: `gaps/${id}` }));
        document.dispatchEvent(new CustomEvent('chump:gap-detail', { detail: { id } }));
      });
    });
    tbody.querySelectorAll('.gb-claim-btn').forEach(btn => {
      btn.addEventListener('click', e => {
        e.stopPropagation();
        this.#claim(btn.dataset.gapId);
      });
    });

    // Sort-column arrows
    sr.querySelectorAll('th[data-sort]').forEach(th => {
      const col = th.dataset.sort;
      th.querySelector('.sort-arrow')?.remove();
      if (col === this.#sortCol) {
        const arrow = document.createElement('span');
        arrow.className = 'sort-arrow';
        arrow.textContent = this.#sortAsc ? ' ▲' : ' ▼';
        th.appendChild(arrow);
      }
    });
  }

  #row(g) {
    const canClaim = g.status === 'open' && g.preflight_status === 'claimable';
    const claimBtn = canClaim
      ? `<button class="gb-claim-btn" data-gap-id="${g.id}" title="Claim this gap">Claim</button>`
      : '';
    return `
      <tr class="gb-row" data-gap-id="${g.id}" tabindex="0" title="${this.#esc(g.title)}">
        <td class="gb-id">${this.#esc(g.id)}</td>
        <td class="gb-title">${this.#esc(g.title.slice(0, 120))}${g.title.length > 120 ? '…' : ''}</td>
        <td>${statusBadge(g.status)}</td>
        <td>${priorityBadge(g.priority)}</td>
        <td>${pillarBadge(g.pillar)}</td>
        <td class="gb-effort">${this.#esc(g.effort ?? '')}</td>
        <td class="gb-domain">${this.#esc(g.domain ?? '')}</td>
        <td class="gb-actions">${claimBtn}</td>
      </tr>`;
  }

  #setStatus(msg) {
    const el = this.shadowRoot.querySelector('.gb-status');
    if (el) el.textContent = msg;
  }

  // ── Claim ───────────────────────────────────────────────────────────────────

  async #claim(id) {
    const btn = this.shadowRoot.querySelector(`.gb-claim-btn[data-gap-id="${id}"]`);
    if (btn) { btn.disabled = true; btn.textContent = '…'; }
    try {
      const r = await fetch(`/api/gap/claim/${id}`, {
        method: 'POST',
        headers: { ...this.#authHeaders() },
        credentials: 'same-origin',
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      await this.#load(); // refresh
    } catch (err) {
      if (btn) { btn.disabled = false; btn.textContent = 'Claim'; }
      alert(`Claim failed: ${err.message}`);
    }
  }

  // ── Wire filter UI ───────────────────────────────────────────────────────────

  #wireUI() {
    const sr = this.shadowRoot;

    // Reload button
    sr.querySelector('#gb-reload')?.addEventListener('click', () => this.#load());

    // Search
    sr.querySelector('#gb-search')?.addEventListener('input', e => {
      this.#searchQuery = e.target.value;
      this.#applyFilters();
      this.#emitFilterEvent();
    });

    // Status filter
    sr.querySelector('#gb-status')?.addEventListener('change', e => {
      this.#statusFilter = e.target.value;
      this.#applyFilters();
      this.#emitFilterEvent();
    });

    // Priority filter
    sr.querySelector('#gb-priority')?.addEventListener('change', e => {
      this.#priorityFilter = e.target.value;
      this.#applyFilters();
      this.#emitFilterEvent();
    });

    // Domain filter
    sr.querySelector('#gb-domain')?.addEventListener('change', e => {
      this.#domainFilter = e.target.value;
      this.#applyFilters();
      this.#emitFilterEvent();
    });

    // Pillar filter
    sr.querySelector('#gb-pillar')?.addEventListener('change', e => {
      this.#pillarFilter = e.target.value;
      this.#applyFilters();
      this.#emitFilterEvent();
    });

    // Sortable column headers
    sr.querySelectorAll('th[data-sort]').forEach(th => {
      th.addEventListener('click', () => {
        const col = th.dataset.sort;
        if (this.#sortCol === col) {
          this.#sortAsc = !this.#sortAsc;
        } else {
          this.#sortCol = col;
          this.#sortAsc = true;
        }
        this.#sortGaps();
        this.#page = 0;
        this.#render();
      });
    });
  }

  #emitFilterEvent() {
    // AC#8: emit pwa_gap_list_filtered to ambient
    navigator.sendBeacon?.('/api/ambient/emit', JSON.stringify({
      kind: 'pwa_gap_list_filtered',
      status: this.#statusFilter || 'all',
      priority: this.#priorityFilter || 'all',
      domain: this.#domainFilter || 'all',
      pillar: this.#pillarFilter || 'all',
      query: this.#searchQuery || '',
      result_count: this.#filtered.length,
    }));
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  #authHeaders() {
    return window.chumpAuthHeaders?.() ?? {};
  }

  #esc(s) {
    return (s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // ── Template ─────────────────────────────────────────────────────────────────

  #skeleton() {
    return `
      <div class="gb-header">
        <h2 class="gb-title-h">Gap Browser</h2>
        <span class="gb-count gb-status">Loading…</span>
        <button class="gb-btn" id="gb-reload" title="Refresh">↺</button>
      </div>

      <div class="gb-filterbar">
        <input type="search" id="gb-search" placeholder="Search ID or title…" class="gb-search" />
        <select id="gb-status" class="gb-sel">
          <option value="">All statuses</option>
          <option value="open">open</option>
          <option value="claimed">claimed</option>
          <option value="shipped">shipped</option>
          <option value="done">done</option>
        </select>
        <select id="gb-priority" class="gb-sel">
          <option value="">All priorities</option>
          <option value="P0">P0</option>
          <option value="P1">P1</option>
          <option value="P2">P2</option>
          <option value="P3">P3</option>
        </select>
        <select id="gb-domain" class="gb-sel">
          <option value="">All domains</option>
          <option value="INFRA">INFRA</option>
          <option value="PRODUCT">PRODUCT</option>
          <option value="CREDIBLE">CREDIBLE</option>
          <option value="EFFECTIVE">EFFECTIVE</option>
          <option value="RESILIENT">RESILIENT</option>
          <option value="ZERO-WASTE">ZERO-WASTE</option>
          <option value="META">META</option>
          <option value="DOC">DOC</option>
          <option value="EVAL">EVAL</option>
        </select>
        <select id="gb-pillar" class="gb-sel">
          <option value="">All pillars</option>
          <option value="EFFECTIVE">EFFECTIVE</option>
          <option value="CREDIBLE">CREDIBLE</option>
          <option value="RESILIENT">RESILIENT</option>
          <option value="ZERO-WASTE">ZERO-WASTE</option>
          <option value="MISSION">MISSION</option>
        </select>
      </div>

      <div class="gb-table-wrap">
        <table class="gb-table">
          <thead>
            <tr>
              <th data-sort="id">ID</th>
              <th data-sort="title">Title</th>
              <th data-sort="status">Status</th>
              <th data-sort="priority">Priority</th>
              <th data-sort="pillar">Pillar</th>
              <th data-sort="effort">Effort</th>
              <th data-sort="domain">Domain</th>
              <th></th>
            </tr>
          </thead>
          <tbody></tbody>
        </table>
      </div>

      <div class="gb-pagination"></div>
    `;
  }

  #css() {
    return `<style>
      :host { display: flex; flex-direction: column; height: 100%; overflow: hidden; font-family: var(--font-sans, system-ui); font-size: 0.875rem; color: var(--c-text, #e2e8f0); }
      .gb-header { display: flex; align-items: center; gap: 8px; padding: 12px 16px 8px; border-bottom: 1px solid var(--c-border, #2d3748); }
      .gb-title-h { margin: 0; font-size: 1rem; font-weight: 600; }
      .gb-count { margin-left: auto; font-size: 0.8rem; color: var(--c-muted, #718096); }
      .gb-filterbar { display: flex; flex-wrap: wrap; gap: 6px; padding: 8px 16px; border-bottom: 1px solid var(--c-border, #2d3748); }
      .gb-search { flex: 1 1 200px; min-width: 120px; padding: 4px 8px; background: var(--c-input-bg, #1a202c); border: 1px solid var(--c-border, #2d3748); border-radius: 4px; color: inherit; }
      .gb-sel { padding: 4px 6px; background: var(--c-input-bg, #1a202c); border: 1px solid var(--c-border, #2d3748); border-radius: 4px; color: inherit; font-size: 0.8rem; }
      .gb-table-wrap { flex: 1; overflow: auto; }
      .gb-table { width: 100%; border-collapse: collapse; table-layout: fixed; }
      .gb-table th { position: sticky; top: 0; background: var(--c-surface, #1a202c); padding: 6px 8px; text-align: left; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--c-muted, #718096); border-bottom: 1px solid var(--c-border, #2d3748); cursor: pointer; user-select: none; white-space: nowrap; }
      .gb-table th:hover { color: var(--c-text, #e2e8f0); }
      .gb-table th:nth-child(1) { width: 9em; }
      .gb-table th:nth-child(2) { width: auto; }
      .gb-table th:nth-child(3), .gb-table th:nth-child(4), .gb-table th:nth-child(5) { width: 7em; }
      .gb-table th:nth-child(6), .gb-table th:nth-child(7) { width: 4.5em; }
      .gb-table th:nth-child(8) { width: 5em; }
      .gb-row { cursor: pointer; border-bottom: 1px solid var(--c-border-subtle, #2d3748); }
      .gb-row:hover { background: var(--c-hover, #2d3748); }
      .gb-row td { padding: 5px 8px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: middle; }
      .gb-id { font-family: monospace; font-size: 0.8rem; color: var(--c-accent, #63b3ed); }
      .gb-title { font-size: 0.82rem; }
      .gb-badge { display: inline-block; padding: 1px 5px; border-radius: 3px; font-size: 0.72rem; font-weight: 600; color: #fff; }
      .gb-btn { padding: 3px 8px; background: var(--c-input-bg, #1a202c); border: 1px solid var(--c-border, #2d3748); border-radius: 4px; color: inherit; cursor: pointer; }
      .gb-btn:hover { background: var(--c-hover, #2d3748); }
      .gb-btn:disabled { opacity: 0.4; cursor: not-allowed; }
      .gb-claim-btn { padding: 2px 7px; background: var(--c-accent, #2b6cb0); border: none; border-radius: 3px; color: #fff; font-size: 0.75rem; cursor: pointer; }
      .gb-claim-btn:hover { background: var(--c-accent-hover, #3182ce); }
      .gb-pagination { display: flex; align-items: center; gap: 8px; justify-content: center; padding: 8px; border-top: 1px solid var(--c-border, #2d3748); font-size: 0.82rem; color: var(--c-muted, #718096); }
      .gb-status { font-style: italic; }
      .sort-arrow { color: var(--c-accent, #63b3ed); }
    </style>`;
  }
}

customElements.define('chump-view-gaps', ChumpViewGaps);
