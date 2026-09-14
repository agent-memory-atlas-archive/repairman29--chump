# Why `<chump-chat>` never appears — cadence default-view drift (INFRA-1433 slice)

> **Gap:** INFRA-6338 (INFRA-1433 slice)
> **Scope:** determine why the `tauri-cowork-e2e` Selenium wait for the
> `chump-chat` CSS selector (`e2e-tauri/run.mjs`) never resolves.
> **Evidence:** live `ci-nightly.yml` run `34817040814` (2026-09-14T07:15Z),
> job `tauri-cowork-e2e` — full log reviewed via `gh run view --log`.

## Summary

The selector is **not stale** — `<chump-chat>` is still the live custom
element name (`web/v2/chat.js:417`, `customElements.define('chump-chat', ...)`)
and `e2e-tauri/run.mjs` targets it correctly. The app **does mount successfully**
in CI's headless Xvfb environment — `#app-title` is located within seconds, no
D-Bus/X11/WebKit init failure occurs (the AT-SPI accessibility-bus warning and
DRI3/EGL warnings in the log are cosmetic noise, not fatal — WebKitGTK renders
fine without them). The prior slice, INFRA-6093, already fixed three stacked
CI-config bugs (wrong script name, missing `tauri-driver` install, missing
WebKitWebDriver apt package) that used to abort the job *before* the app ever
got a chance to render — that fix is confirmed live in `ci-nightly.yml` today
and the job now reaches the actual Selenium wait.

**The real, still-live cause:** `<chump-chat>` only exists in the DOM while
the **Chat sub-tab of the "Now" cadence** is the active view
(`web/v2/app.js` — `ChumpViewChat.connectedCallback()` sets
`this.innerHTML = '<chump-chat ...>'`, and `ChumpViewChat` is only
instantiated when the router activates the `chat` sub-view). On fresh page
load, the "Now" cadence's `default_view` is `'cockpit'`, **not** `'chat'` —
changed by commit `f9a21b6d` (PRODUCT-132 / PR #2066, 2026-05-15,
`"default_view of 'now' cadence is now 'cockpit' (was 'chat')"`). The e2e
test (`e2e-tauri/run.mjs`) loads the app fresh and waits for `<chump-chat>`
without ever clicking the Chat sub-tab, so the wait times out every run —
this has been silently broken since 2026-05-15, four months before this
investigation.

## Reproduction (live CI evidence)

`ci-nightly.yml` run `34817040814`, job `tauri-cowork-e2e`:

```
tauri e2e: #app-title found at t=1789370576064; waiting for <chump-chat>…
...
TimeoutError: Waiting for element to be located By(css selector, chump-chat)
Wait timed out after 120947ms
```

`#app-title` (light-DOM, always rendered) locates in under 3 seconds. The
120s wait for `chump-chat` times out with no other error — the page is up,
JS executed, the shell rendered; the element the test wants simply isn't in
the tree because the cockpit view is showing instead of chat.

## Per-AC findings

1. **Was the selector renamed?** No. `chump-chat` is current
   (`web/v2/chat.js:417`, referenced identically in `web/v2/app.js:4196`,
   `web/v2/index.html:2150-2155`, and three Playwright specs under `e2e/tests/`).
   No `chat-room` or other rename exists anywhere in the tree.
2. **Does the app fail to mount in CI's xvfb headless env?** No. `#app-title`
   renders immediately; the shell boots, the web server serves the PWA, and
   the WebView loads it successfully under `xvfb-run`.
3. **Missing D-Bus / X11 dependencies?** No fatal ones. The log shows two
   benign warnings — `AT-SPI: Error retrieving accessibility bus address`
   (dbus a11y bus absent, only affects screen-reader integration) and
   `libEGL warning: DRI3 error: Could not get DRI3 device` (software
   rendering fallback, not a crash) — both pre-existing in headless CI and
   neither blocks page load or JS execution. INFRA-6093 already confirmed
   `xvfb`, `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `librsvg2-dev`,
   `libayatana-appindicator3-dev` are all correctly installed.
4. **Root cause:** router/view-default drift, not an environment or selector
   problem — see Summary above.

## Fix scope (left for the follow-up slice, per two-phase decomposition)

Two independent, non-conflicting fixes; either resolves the immediate CI
timeout, both address the underlying UX-vs-test mismatch:

- **Test-side (minimal, recommended):** `e2e-tauri/run.mjs` should click the
  Chat sub-tab (`[data-view="chat"]` — see `e2e/tests/api-and-pwa.spec.ts`
  for the equivalent Playwright pattern: `page.locator('[data-view="chat"]').click()`)
  before waiting on `chump-chat`, mirroring how a real user reaches the chat
  surface post-PRODUCT-132.
- **App-side (only if Chat is meant to be the landing view for this
  archetype):** reconsider whether `'now'` cadence's `default_view` should be
  `'chat'` again — out of scope here since PRODUCT-132 made that change
  deliberately (dedup/attention surfacing on Cockpit), and reverting it is a
  product decision, not a test-infra fix.

Filed as a follow-up: the test-side fix (`e2e-tauri/run.mjs` navigation click)
is the correct next slice of INFRA-1433 and does not require app changes.

## Related

- `docs/audits/INFRA-6093-tauri-e2e-app-init-investigation.md` — prior slice,
  fixed the CI-config drift (script name / tauri-driver install / WebKitWebDriver
  package) that used to abort the job before it reached this failure mode.
- `docs/gaps/INFRA-1433.yaml` — parent gap, full original AC.
