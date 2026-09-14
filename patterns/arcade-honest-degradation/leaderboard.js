// Honest-degradation reference implementation for the arcade's leaderboard
// widget (EFFECTIVE-1643, sub-slice of EFFECTIVE-370). Vendor this into
// games:shared/leaderboard.js — see docs/VENDOR_LEDGER.md Surface 1.
//
// Contract: this module NEVER throws and NEVER surfaces a raw backend error
// to the DOM. When Supabase is unreachable, times out, or returns a 5xx /
// quota-exhausted response, callers get a degraded-but-truthful result
// instead of a dead endpoint. The primary game loop never depends on this
// module resolving successfully.

const DEFAULT_TIMEOUT_MS = 4000;
const NAPPING_MESSAGE = 'scores are napping';

async function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function isDegradedStatus(status) {
  // 5xx (server/backend failure) or 429 (quota exhausted) both count as
  // "the backend is not currently trustworthy" — never as "no scores exist".
  return status >= 500 || status === 429;
}

// Fetches leaderboard scores. Always resolves — never rejects.
//
// Returns either:
//   { ok: true, scores: [...] }
//   { ok: false, message: 'scores are napping', reason: '<diagnostic>' }
async function fetchLeaderboard({
  supabaseUrl,
  supabaseKey,
  gameId,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  fetchImpl = fetchWithTimeout,
} = {}) {
  if (!supabaseUrl || !supabaseKey) {
    return { ok: false, message: NAPPING_MESSAGE, reason: 'missing_config' };
  }

  try {
    const res = await fetchImpl(
      `${supabaseUrl}/rest/v1/leaderboard?game_id=eq.${encodeURIComponent(gameId)}&order=score.desc&limit=10`,
      { headers: { apikey: supabaseKey, Authorization: `Bearer ${supabaseKey}` } },
      timeoutMs
    );

    if (isDegradedStatus(res.status)) {
      return { ok: false, message: NAPPING_MESSAGE, reason: `http_${res.status}` };
    }
    if (!res.ok) {
      // Non-5xx, non-2xx (e.g. 404 misconfigured table) is still a truthful
      // "not available right now", never a thrown error.
      return { ok: false, message: NAPPING_MESSAGE, reason: `http_${res.status}` };
    }

    const scores = await res.json();
    return { ok: true, scores };
  } catch (err) {
    // Network failure, DNS failure, timeout/abort — all collapse to the same
    // honest banner. The specific reason is kept for logs/telemetry only,
    // never rendered to the player.
    const reason = err && err.name === 'AbortError' ? 'timeout' : 'network_error';
    return { ok: false, message: NAPPING_MESSAGE, reason };
  }
}

// Renders the leaderboard panel into `mountEl`. Degraded results render a
// quiet banner in place of the score list — the panel never disappears and
// never shows a raw error string. Caller supplies `renderScores` /
// `renderBanner` so this module has no framework/DOM dependency.
async function renderLeaderboard(mountEl, opts, { renderScores, renderBanner } = {}) {
  const result = await fetchLeaderboard(opts);
  if (result.ok) {
    renderScores(mountEl, result.scores);
  } else {
    renderBanner(mountEl, result.message);
  }
  return result;
}

module.exports = { fetchLeaderboard, renderLeaderboard, NAPPING_MESSAGE, isDegradedStatus };
