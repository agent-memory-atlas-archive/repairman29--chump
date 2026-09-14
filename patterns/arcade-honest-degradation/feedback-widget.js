// Honest-degradation reference implementation for the arcade's feedback
// widget (EFFECTIVE-1643, sub-slice of EFFECTIVE-370). Vendor this into
// games:shared/feedback-widget.js — see docs/VENDOR_LEDGER.md Surface 1.
//
// Contract: submitting feedback never throws and never surfaces a dead
// endpoint / raw HTTP error to the player. A backend failure degrades to a
// non-blocking notice; the game loop is never gated on this succeeding.

const DEFAULT_TIMEOUT_MS = 4000;
const UNAVAILABLE_MESSAGE = "feedback's taking a nap — try again later";

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
  return status >= 500 || status === 429;
}

// Submits a feedback payload. Always resolves — never rejects.
//
// Returns either:
//   { ok: true }
//   { ok: false, message: "feedback's taking a nap — try again later", reason: '<diagnostic>' }
async function submitFeedback({
  supabaseUrl,
  supabaseKey,
  gameId,
  payload,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  fetchImpl = fetchWithTimeout,
} = {}) {
  if (!supabaseUrl || !supabaseKey) {
    return { ok: false, message: UNAVAILABLE_MESSAGE, reason: 'missing_config' };
  }

  try {
    const res = await fetchImpl(
      `${supabaseUrl}/rest/v1/feedback`,
      {
        method: 'POST',
        headers: {
          apikey: supabaseKey,
          Authorization: `Bearer ${supabaseKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ game_id: gameId, ...payload }),
      },
      timeoutMs
    );

    if (isDegradedStatus(res.status) || !res.ok) {
      return { ok: false, message: UNAVAILABLE_MESSAGE, reason: `http_${res.status}` };
    }
    return { ok: true };
  } catch (err) {
    const reason = err && err.name === 'AbortError' ? 'timeout' : 'network_error';
    return { ok: false, message: UNAVAILABLE_MESSAGE, reason };
  }
}

// Handles a feedback-widget submit event end to end. On failure, shows a
// non-blocking notice via `renderNotice` instead of a dead-endpoint error —
// the widget stays interactive and the game loop is untouched either way.
async function handleFeedbackSubmit(opts, { renderNotice, renderSuccess } = {}) {
  const result = await submitFeedback(opts);
  if (result.ok) {
    renderSuccess();
  } else {
    renderNotice(result.message);
  }
  return result;
}

module.exports = { submitFeedback, handleFeedbackSubmit, UNAVAILABLE_MESSAGE, isDegradedStatus };
