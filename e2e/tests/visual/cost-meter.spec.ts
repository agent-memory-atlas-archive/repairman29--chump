import { test, expect } from '@playwright/test';
import http from 'http';
import fs from 'fs';
import path from 'path';
import type { AddressInfo } from 'net';

// INFRA-7164: visual snapshot harness slice of INFRA-1587.
//
// Renders a single chump-* web component (<chump-cost-meter>, web/v2/cost-meter.js)
// standalone via a throwaway static file server rooted at the repo — no chump
// server process, no LLM, no baseURL dependency, so this suite runs identically
// in any harness. (Module scripts are blocked by CORS under file://, so a real
// HTTP origin is required even for a static fixture.)
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

// The component's connectedCallback synchronously renders a "loading…" state
// before firing its telemetry fetch. We block that fetch so it never settles,
// freezing the component in its deterministic loading render for the snapshot.
test.describe('visual snapshot: chump-cost-meter', () => {
  test('renders loading state', async ({ page }) => {
    await page.route('**/api/telemetry/cost', () => {
      // Never fulfill — keeps the component in its synchronous "loading…" render.
    });

    await page.goto(`${baseURL}/e2e/tests/visual/fixtures/cost-meter.html`);

    const meter = page.locator('chump-cost-meter');
    await expect(meter).toBeVisible();

    await expect(meter).toHaveScreenshot('cost-meter-loading.png', {
      maxDiffPixelRatio: 0.05,
    });
  });
});
