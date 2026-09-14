// Node assertions backing scripts/ci/test-arcade-honest-degradation.sh
// (EFFECTIVE-1643). Spins up a tiny local HTTP server that simulates a
// down/quota-exhausted Supabase backend, then drives the reference
// leaderboard + feedback-widget modules against it.
'use strict';

const http = require('http');
const assert = require('assert');
const path = require('path');

const { fetchLeaderboard, renderLeaderboard, NAPPING_MESSAGE } = require(
  path.join(__dirname, '..', '..', '..', 'patterns', 'arcade-honest-degradation', 'leaderboard.js')
);
const { submitFeedback, handleFeedbackSubmit, UNAVAILABLE_MESSAGE } = require(
  path.join(__dirname, '..', '..', '..', 'patterns', 'arcade-honest-degradation', 'feedback-widget.js')
);

function startServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function serverUrl(server) {
  const { port } = server.address();
  return `http://127.0.0.1:${port}`;
}

async function main() {
  // 1. Supabase returns 500 (down) — leaderboard must degrade, never throw.
  {
    const server = await startServer((req, res) => {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'internal' }));
    });
    try {
      const result = await fetchLeaderboard({
        supabaseUrl: serverUrl(server),
        supabaseKey: 'test-key',
        gameId: 'game-1',
      });
      assert.strictEqual(result.ok, false, 'leaderboard should degrade on 500');
      assert.strictEqual(result.message, NAPPING_MESSAGE, 'leaderboard should show the napping banner on 500');
    } finally {
      server.close();
    }
  }

  // 2. Supabase returns 429 (quota exhausted) — same honest degradation, no 5xx surfaced.
  {
    const server = await startServer((req, res) => {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'quota exceeded' }));
    });
    try {
      const result = await fetchLeaderboard({
        supabaseUrl: serverUrl(server),
        supabaseKey: 'test-key',
        gameId: 'game-1',
      });
      assert.strictEqual(result.ok, false, 'leaderboard should degrade on 429');
      assert.strictEqual(result.message, NAPPING_MESSAGE);
    } finally {
      server.close();
    }
  }

  // 3. Connection refused (host down entirely) — must not throw, must degrade.
  {
    let threw = false;
    let result;
    try {
      result = await fetchLeaderboard({
        supabaseUrl: 'http://127.0.0.1:1', // reserved port, connection refused
        supabaseKey: 'test-key',
        gameId: 'game-1',
        timeoutMs: 1000,
      });
    } catch (err) {
      threw = true;
    }
    assert.strictEqual(threw, false, 'fetchLeaderboard must never throw on connection failure');
    assert.strictEqual(result.ok, false);
    assert.strictEqual(result.message, NAPPING_MESSAGE);
  }

  // 4. Primary game loop continues to run unchanged — renderLeaderboard resolves
  //    and calls the degraded-banner renderer, never propagates an error up
  //    to the caller (i.e. the game loop driving it).
  {
    const server = await startServer((req, res) => {
      res.writeHead(503);
      res.end('service unavailable');
    });
    try {
      let bannerShown = null;
      let scoresShown = null;
      const mountEl = {};
      await renderLeaderboard(
        mountEl,
        { supabaseUrl: serverUrl(server), supabaseKey: 'test-key', gameId: 'game-1' },
        {
          renderScores: (_el, scores) => { scoresShown = scores; },
          renderBanner: (_el, message) => { bannerShown = message; },
        }
      );
      assert.strictEqual(bannerShown, NAPPING_MESSAGE, 'game loop should see the napping banner, not an exception');
      assert.strictEqual(scoresShown, null, 'scores renderer should not fire on a degraded backend');
    } finally {
      server.close();
    }
  }

  // 5. Feedback widget: 500 backend -> non-blocking notice, never a raw error.
  {
    const server = await startServer((req, res) => {
      res.writeHead(500);
      res.end('internal error');
    });
    try {
      const result = await submitFeedback({
        supabaseUrl: serverUrl(server),
        supabaseKey: 'test-key',
        gameId: 'game-1',
        payload: { text: 'great game' },
      });
      assert.strictEqual(result.ok, false);
      assert.strictEqual(result.message, UNAVAILABLE_MESSAGE);

      let noticeShown = null;
      let successCalled = false;
      await handleFeedbackSubmit(
        { supabaseUrl: serverUrl(server), supabaseKey: 'test-key', gameId: 'game-1', payload: {} },
        {
          renderNotice: (message) => { noticeShown = message; },
          renderSuccess: () => { successCalled = true; },
        }
      );
      assert.strictEqual(noticeShown, UNAVAILABLE_MESSAGE);
      assert.strictEqual(successCalled, false);
    } finally {
      server.close();
    }
  }

  // 6. Feedback widget: healthy backend -> success path still works (no
  //    over-degradation when Supabase is actually fine).
  {
    const server = await startServer((req, res) => {
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({}));
    });
    try {
      const result = await submitFeedback({
        supabaseUrl: serverUrl(server),
        supabaseKey: 'test-key',
        gameId: 'game-1',
        payload: { text: 'great game' },
      });
      assert.strictEqual(result.ok, true, 'a healthy backend should not be reported as degraded');
    } finally {
      server.close();
    }
  }

  console.log('All arcade honest-degradation assertions passed.');
}

main().catch((err) => {
  console.error('FAIL:', err);
  process.exit(1);
});
