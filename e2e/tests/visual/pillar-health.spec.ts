import { test, expect } from '@playwright/test';
import http from 'http';
import fs from 'fs';
import path from 'path';
import type { AddressInfo } from 'net';

// INFRA-7422: visual snapshot harness slice of INFRA-1587 (cost-meter precedent: INFRA-7164).
//
// Renders <chump-pillar-health> (web/v2/pillar-health.js) standalone via a
// throwaway static file server rooted at the repo — no chump server process, no
// baseURL dependency. Module scripts are blocked by CORS under file://, so a real
// HTTP origin is required even for a static fixture.
const REPO_ROOT = path.join(__dirname, '..', '..', '..');
const MIME: Record<string, string> = { '.html': 'text/html', '.js': 'text/javascript' };

let server: http.Server;
let baseURL: string;

test.beforeAll(async () => {
  server = http.createServer((req, res) => {
    const filePath = path.join(REPO_ROOT, decodeURIComponent((req.url || '/').split('?')[0]));
    if (!filePath.startsWith(REPO_ROOT) || !fs.existsSync(filePath)) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
    fs.createReadStream(filePath).pipe(res);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  baseURL = `http://127.0.0.1:${port}`;
});

test.afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

// connectedCallback() renders the loading state synchronously before the
// /api/health/pillars fetch settles. Blocking that fetch freezes the
// component in its deterministic loading render for the snapshot.
test.describe('visual snapshot: chump-pillar-health', () => {
  test('renders loading state', async ({ page }) => {
    await page.route('**/api/health/pillars', () => {
      // Never fulfill — keeps the component in its synchronous loading render.
    });

    await page.goto(`${baseURL}/e2e/tests/visual/fixtures/pillar-health.html`);

    const health = page.locator('chump-pillar-health');
    await expect(health).toBeVisible();

    await expect(health).toHaveScreenshot('pillar-health-loading.png', {
      maxDiffPixelRatio: 0.05,
    });
  });
});
