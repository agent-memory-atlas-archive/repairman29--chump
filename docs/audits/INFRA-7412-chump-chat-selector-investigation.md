# `chump-chat` selector — investigation + fix landed (INFRA-1433 slice)

> **Gap:** INFRA-7412 (INFRA-1433 slice)
> **Scope:** reproduce the `tauri-cowork-e2e` Selenium timeout on the
> `chump-chat` CSS selector, confirm whether the selector was renamed, and
> document findings.

## Findings (reproduction + selector identity)

1. **Selector name — not renamed.** `chump-chat` is still the live custom
   element name, defined and registered in `web/v2/chat.js:417`:

   ```js
   customElements.define('chump-chat', ChumpChat);
   ```

   No alternate name (`chat-room` or otherwise) exists anywhere under
   `web/v2/`. Consumers (`web/v2/app.js:4196`, `web/v2/index.html:2150-2155`,
   and three Playwright specs under `e2e/tests/`) all reference the same
   name — no drift between definition and call sites.

2. **Reproduction — CI:** confirmed via live `ci-nightly.yml` run
   `34817040814` (2026-09-14T07:15Z), job `tauri-cowork-e2e`. `#app-title`
   (light-DOM, always rendered) locates in under 3 seconds; the 120s wait
   for `chump-chat` then times out with no other error:

   ```
   tauri e2e: #app-title found at t=1789370576064; waiting for <chump-chat>…
   TimeoutError: Waiting for element to be located By(css selector, chump-chat)
   Wait timed out after 120947ms
   ```

3. **Root cause (already root-caused by INFRA-6338, re-verified here):**
   `<chump-chat>` only mounts while the **Chat sub-tab of the "Now"
   cadence** is the active view (`ChumpViewChat.connectedCallback()` in
   `web/v2/app.js` sets `this.innerHTML = '<chump-chat ...>'`). PRODUCT-132
   (PR #2066, 2026-05-15) changed the "now" cadence's `default_view` from
   `'chat'` to `'cockpit'`. `e2e-tauri/run.mjs` loaded the app fresh and
   waited for `<chump-chat>` without ever clicking into the Chat sub-tab, so
   the element was simply never in the DOM to find — not an app-mount
   failure, not a D-Bus/X11 dependency issue, not a selector rename.

## This slice's contribution: the fix

INFRA-6338 and INFRA-7154 (prior INFRA-1433 slices) already answered the
"is the selector stale?" question twice and scoped the fix but left it
unapplied. This slice applies the recommended test-side fix: `e2e-tauri/run.mjs`
now clicks `[data-view="chat"]` (the same nav element the Playwright specs in
`e2e/tests/api-and-pwa.spec.ts` use) before waiting on `chump-chat`, mirroring
how a real user reaches the chat surface post-PRODUCT-132.

## Related prior work

- [`docs/audits/INFRA-6338-chump-chat-selector-investigation.md`](./INFRA-6338-chump-chat-selector-investigation.md) — original root-cause + fix scope.
- [`docs/audits/INFRA-7154-chump-chat-selector-investigation.md`](./INFRA-7154-chump-chat-selector-investigation.md) — second slice, confirmed same facts.
- `docs/gaps/INFRA-1433.yaml` — parent gap, full original AC.
