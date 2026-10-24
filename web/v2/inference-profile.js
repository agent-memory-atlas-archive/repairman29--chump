// Chump v2 — Model selection guide + inference profile tuning UI.
// PRODUCT-028: offline solo devs pick and configure local LLMs without reading source code.
// No build step, no CDN. Air-gap safe by construction.

// ── Hardware tiers ────────────────────────────────────────────────────────────
const TIERS = [
  { id: '8gb',  label: '≤ 8 GB',  desc: 'Laptop / edge device'    },
  { id: '16gb', label: '16 GB',   desc: 'Mid-range Mac / PC'       },
  { id: '24gb', label: '24 GB+',  desc: 'M4 Air / M-series Pro'    },
];

// ── Profile catalog ───────────────────────────────────────────────────────────
// Each profile: id, name, backend, icon, tiers[], whenToUse, models[], envFn
const PROFILES = [
  {
    id: 'ollama-7b',
    name: 'Ollama — 7B',
    icon: '🦙',
    tiers: ['8gb', '16gb', '24gb'],
    whenToUse: 'Simplest setup, fastest start. Good for chat and light tool use.',
    model: 'qwen2.5:7b',
    envFn: () => `OPENAI_API_BASE=http://127.0.0.1:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:7b`,
    startCmd: 'ollama serve && ollama pull qwen2.5:7b',
    notes: 'Run `ollama serve` before starting Chump.',
  },
  {
    id: 'ollama-14b',
    name: 'Ollama — 14B',
    icon: '🦙',
    tiers: ['16gb', '24gb'],
    whenToUse: 'More capable than 7B for complex reasoning. Needs ~9 GB VRAM.',
    model: 'qwen2.5:14b',
    envFn: () => `OPENAI_API_BASE=http://127.0.0.1:11434/v1
OPENAI_API_KEY=ollama
OPENAI_MODEL=qwen2.5:14b`,
    startCmd: 'ollama serve && ollama pull qwen2.5:14b',
    notes: 'Requires ~9 GB free unified RAM. Use 7B if the machine feels sluggish.',
  },
  {
    id: 'vllm-14b',
    name: 'vLLM-MLX — 14B (recommended)',
    icon: '⚡',
    tiers: ['24gb'],
    whenToUse: 'Best quality + throughput on Apple Silicon. Steady production default.',
    model: 'mlx-community/Qwen2.5-14B-Instruct-4bit',
    envFn: () => `OPENAI_API_BASE=http://127.0.0.1:8000/v1
OPENAI_API_KEY=not-needed
OPENAI_MODEL=mlx-community/Qwen2.5-14B-Instruct-4bit
CHUMP_MAX_CONCURRENT_TURNS=1
HEARTBEAT_LOCK=1
VLLM_MAX_NUM_SEQS=1
VLLM_MAX_TOKENS=4096
VLLM_CACHE_PERCENT=0.12`,
    startCmd: './scripts/setup/restart-vllm-if-down.sh',
    notes: 'Apple Silicon only. Install: uv tool install vllm-mlx. First pull ~8 GB.',
  },
  {
    id: 'vllm-7b',
    name: 'vLLM-MLX — 7B (lite)',
    icon: '⚡',
    tiers: ['16gb', '24gb'],
    whenToUse: 'Same Metal path as 14B but lighter. Good when 14B pushes RAM limits.',
    model: 'mlx-community/Qwen2.5-7B-Instruct-4bit',
    envFn: () => `OPENAI_API_BASE=http://127.0.0.1:8001/v1
OPENAI_API_KEY=not-needed
OPENAI_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit`,
    startCmd: './scripts/setup/restart-vllm-8001-if-down.sh',
    notes: 'Served on port 8001. Apple Silicon only.',
  },
  {
    id: 'mistralrs-4b',
    name: 'In-process mistral.rs — 4B',
    icon: '🦀',
    tiers: ['8gb', '16gb', '24gb'],
    whenToUse: 'Single Rust process, no Python server. Good for minimal-dependency setups.',
    model: 'Qwen/Qwen3-4B',
    envFn: (bits) => `CHUMP_INFERENCE_BACKEND=mistralrs
CHUMP_MISTRALRS_MODEL=Qwen/Qwen3-4B
CHUMP_MISTRALRS_ISQ_BITS=${bits || 4}
OPENAI_MODEL=Qwen/Qwen3-4B`,
    startCmd: 'cargo build --release --features mistralrs-infer',
    notes: 'Weights load on first request (~minutes for 4B). Needs HF_TOKEN for gated repos.',
    hasBitsPicker: true,
  },
  {
    id: 'mistralrs-metal',
    name: 'In-process mistral.rs — Metal',
    icon: '🦀',
    tiers: ['24gb'],
    whenToUse: 'Apple Silicon GPU + single Rust process. Fast after first load.',
    model: 'Qwen/Qwen3-4B',
    envFn: (bits) => `CHUMP_INFERENCE_BACKEND=mistralrs
CHUMP_MISTRALRS_MODEL=Qwen/Qwen3-4B
CHUMP_MISTRALRS_ISQ_BITS=${bits || 4}
OPENAI_MODEL=Qwen/Qwen3-4B`,
    startCmd: 'cargo build --release --features mistralrs-metal',
    notes: 'Requires full Xcode (xcrun metal --version must succeed).',
    hasBitsPicker: true,
  },
  {
    id: 'cloud-byok-gemini',
    name: 'Google AI (Gemini 3.8 Flash) — Frontier BYOK',
    icon: '✨',
    tiers: ['8gb', '16gb', '24gb'],
    whenToUse: 'Zero local VRAM. Uses Google AI frontier coding models (1M context) via GEMINI_API_KEY.',
    model: 'gemini-3.8-flash',
    envFn: () => `OPENAI_API_BASE=https://generativelanguage.googleapis.com/v1beta/openai
OPENAI_MODEL=gemini-3.8-flash
CHUMP_BYOK_PRIMARY=1
CHUMP_BYOK_PAID=1
CHUMP_AUTO_BYOK_SLOTS=1`,
    startCmd: 'chump llm-complete --model opus <<< "Reply with OK"',
    notes: 'Set GEMINI_API_KEY in Settings → API Secrets or .env.',
  },
];

// ── <chump-view-models> ───────────────────────────────────────────────────────
class ChumpViewModels extends HTMLElement {
  #tier = '24gb';
  #status = null;
  #selectedBits = {};

  connectedCallback() {
    this.innerHTML = `
      <style>
        .models-wrap { padding: 16px; display: flex; flex-direction: column; gap: 16px; max-width: 720px; }
        .section-title { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.6px; color: var(--text-secondary); margin-bottom: 8px; }

        /* ── Live status card ── */
        .status-card {
          background: var(--bg-surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 12px 14px;
          display: flex;
          flex-direction: column;
          gap: 6px;
        }
        .status-row { display: flex; justify-content: space-between; align-items: center; font-size: 12px; }
        .status-label { color: var(--text-secondary); }
        .status-val { font-family: "SF Mono", monospace; font-size: 11px; color: var(--text); }
        .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-right: 5px; }
        .dot.ok  { background: var(--success); }
        .dot.err { background: var(--error); }
        .dot.unk { background: var(--text-secondary); }

        /* ── Tier picker ── */
        .tier-row { display: flex; gap: 6px; }
        .tier-btn {
          flex: 1; padding: 8px 6px; border: 1px solid var(--border);
          background: var(--bg-surface); color: var(--text-secondary);
          border-radius: var(--radius-sm); font-size: 12px; font-weight: 500;
          cursor: pointer; text-align: center; transition: all 0.15s;
        }
        .tier-btn.active {
          border-color: var(--accent); background: var(--accent-dim); color: var(--accent);
        }
        .tier-desc { font-size: 10px; color: inherit; margin-top: 2px; }

        /* ── Profile cards ── */
        .profile-card {
          background: var(--bg-surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 14px;
          display: flex;
          flex-direction: column;
          gap: 10px;
        }
        .profile-header { display: flex; align-items: center; gap: 8px; }
        .profile-icon { font-size: 20px; line-height: 1; }
        .profile-name { font-size: 14px; font-weight: 600; }
        .profile-when { font-size: 12px; color: var(--text-secondary); line-height: 1.45; }

        /* ── ISQ bits picker ── */
        .bits-row { display: flex; align-items: center; gap: 8px; font-size: 12px; }
        .bits-label { color: var(--text-secondary); white-space: nowrap; }
        .bits-select {
          background: var(--bg-elevated); border: 1px solid var(--border);
          color: var(--text); border-radius: var(--radius-sm);
          padding: 3px 8px; font-size: 12px; cursor: pointer;
        }

        /* ── Env snippet ── */
        .env-block { position: relative; }
        .env-pre {
          background: var(--bg-elevated); border: 1px solid var(--border);
          border-radius: var(--radius-sm); padding: 10px 12px;
          font-family: "SF Mono", monospace; font-size: 11px;
          white-space: pre; overflow-x: auto; color: var(--text);
          margin: 0; line-height: 1.6;
        }
        .copy-btn {
          position: absolute; top: 6px; right: 6px;
          padding: 3px 8px; font-size: 10px; font-weight: 600;
          background: var(--bg-surface); border: 1px solid var(--border);
          border-radius: var(--radius-sm); color: var(--text-secondary);
          cursor: pointer; transition: all 0.15s;
        }
        .copy-btn:hover { color: var(--accent); border-color: var(--accent); }
        .copy-btn.copied { color: var(--success); border-color: var(--success); }

        /* ── Start command ── */
        .start-row { display: flex; align-items: center; gap: 8px; font-size: 12px; }
        .start-label { color: var(--text-secondary); white-space: nowrap; }
        .start-cmd { font-family: "SF Mono", monospace; font-size: 11px; color: var(--text); }

        /* ── Notes ── */
        .profile-notes { font-size: 11px; color: var(--text-secondary); line-height: 1.5; border-left: 2px solid var(--border); padding-left: 8px; }

        /* ── Empty state ── */
        .no-profiles { color: var(--text-secondary); font-size: 13px; padding: 24px 0; text-align: center; }
      </style>
      <section class="view-header">
        <h2>Model Selection</h2>
        <p class="view-subtitle">Pick and configure a local LLM — no source code required</p>
      </section>
      <div class="models-wrap">
        <div>
          <p class="section-title">Live inference status</p>
          <div id="status-card" class="status-card">
            <p style="font-size:12px;color:var(--text-secondary)">Loading…</p>
          </div>
        </div>
        <div>
          <p class="section-title">Your hardware tier</p>
          <div class="tier-row" id="tier-row"></div>
        </div>
        <div>
          <p class="section-title">Recommended profiles</p>
          <div id="profile-list" style="display:flex;flex-direction:column;gap:12px;"></div>
        </div>
        <div style="font-size:11px;color:var(--text-secondary);border-top:1px solid var(--border);padding-top:12px;">
          After editing <code style="font-family:SF Mono,monospace">.env</code>, restart Chump for changes to take effect.
          Full guide: <code style="font-family:SF Mono,monospace">docs/operations/INFERENCE_PROFILES.md</code>
        </div>
      </div>
    `;
    this.#buildTierPicker();
    this.#renderProfiles();
    this.#loadStatus();
  }

  #buildTierPicker() {
    const row = this.querySelector('#tier-row');
    row.innerHTML = TIERS.map((t) => `
      <button class="tier-btn${t.id === this.#tier ? ' active' : ''}" data-tier="${t.id}">
        ${t.label}
        <div class="tier-desc">${t.desc}</div>
      </button>
    `).join('');
    row.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-tier]');
      if (!btn) return;
      this.#tier = btn.dataset.tier;
      row.querySelectorAll('.tier-btn').forEach((b) => b.classList.toggle('active', b.dataset.tier === this.#tier));
      this.#renderProfiles();
    });
  }

  #renderProfiles() {
    const list = this.querySelector('#profile-list');
    const visible = PROFILES.filter((p) => p.tiers.includes(this.#tier));
    if (visible.length === 0) {
      list.innerHTML = '<p class="no-profiles">No profiles match this tier.</p>';
      return;
    }
    list.innerHTML = '';
    visible.forEach((p) => list.appendChild(this.#makeProfileCard(p)));
  }

  #makeProfileCard(profile) {
    const card = document.createElement('div');
    card.className = 'profile-card';
    card.dataset.profileId = profile.id;

    const bits = this.#selectedBits[profile.id] ?? 4;
    const envText = profile.envFn(bits);

    card.innerHTML = `
      <div class="profile-header">
        <span class="profile-icon">${profile.icon}</span>
        <span class="profile-name">${profile.name}</span>
      </div>
      <p class="profile-when">${profile.whenToUse}</p>
      ${profile.hasBitsPicker ? `
        <div class="bits-row">
          <span class="bits-label">ISQ bits (quantization):</span>
          <select class="bits-select" data-profile="${profile.id}">
            ${[8, 6, 5, 4, 3, 2].map((b) => `<option value="${b}"${b === bits ? ' selected' : ''}>${b}-bit${b === 4 ? ' (default)' : b === 8 ? ' (quality)' : b <= 3 ? ' (small)' : ''}</option>`).join('')}
          </select>
        </div>
      ` : ''}
      <div class="env-block">
        <pre class="env-pre" id="env-${profile.id}">${envText}</pre>
        <button class="copy-btn" data-copy="${profile.id}">Copy</button>
      </div>
      <div class="start-row">
        <span class="start-label">Start:</span>
        <code class="start-cmd">${profile.startCmd}</code>
      </div>
      <p class="profile-notes">${profile.notes}</p>
    `;

    card.querySelector('.copy-btn')?.addEventListener('click', (e) => {
      const pre = card.querySelector(`#env-${profile.id}`);
      navigator.clipboard?.writeText(pre.textContent).then(() => {
        e.target.textContent = 'Copied!';
        e.target.classList.add('copied');
        setTimeout(() => { e.target.textContent = 'Copy'; e.target.classList.remove('copied'); }, 2000);
      }).catch(() => {});
    });

    if (profile.hasBitsPicker) {
      card.querySelector('.bits-select')?.addEventListener('change', (e) => {
        const newBits = parseInt(e.target.value, 10);
        this.#selectedBits[profile.id] = newBits;
        const pre = card.querySelector(`#env-${profile.id}`);
        if (pre) pre.textContent = profile.envFn(newBits);
      });
    }

    return card;
  }

  #loadStatus() {
    const card = this.querySelector('#status-card');
    fetch('/api/stack-status')
      .then((r) => r.json())
      .then((d) => {
        this.#status = d;
        const reachable = d.inference?.models_reachable;
        const dotClass = reachable === true ? 'ok' : reachable === false ? 'err' : 'unk';
        const backend = d.inference?.primary_backend ?? (d.openai_api_base ? 'http' : 'unknown');
        card.innerHTML = `
          <div class="status-row">
            <span class="status-label">Model</span>
            <span class="status-val">${d.openai_model || d.inference?.mistralrs_model || '(not set)'}</span>
          </div>
          <div class="status-row">
            <span class="status-label">API base</span>
            <span class="status-val">${d.openai_api_base || '(not set)'}</span>
          </div>
          <div class="status-row">
            <span class="status-label">Backend</span>
            <span class="status-val">${backend}</span>
          </div>
          <div class="status-row">
            <span class="status-label">Provider</span>
            <span class="status-val"><span class="dot ${dotClass}"></span>${reachable === true ? 'reachable' : reachable === false ? 'unreachable' : 'unknown'}</span>
          </div>
          ${d.air_gap_mode ? '<div class="status-row"><span class="status-label">Air-gap</span><span class="status-val" style="color:var(--warn)">enabled</span></div>' : ''}
        `;
      })
      .catch(() => {
        card.innerHTML = `<p style="font-size:12px;color:var(--text-secondary)"><span class="dot err"></span>Server offline — showing static profiles</p>`;
      });
  }
}
customElements.define('chump-view-models', ChumpViewModels);
