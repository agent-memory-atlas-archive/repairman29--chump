# `chump-chat` selector — existence and naming (INFRA-1433 slice)

> **Gap:** INFRA-7154 (INFRA-1433 slice)
> **Scope:** locate the Web Component definition for the `chump-chat`
> custom element and confirm whether it has been renamed.

## Findings

1. **Selector name — not renamed.** The custom element is still named
   `chump-chat`. It is defined and registered in
   `web/v2/chat.js:417`:

   ```js
   customElements.define('chump-chat', ChumpChat);
   ```

   The `ChumpChat` class body starts at `web/v2/chat.js:47` (comment header
   `// ── <chump-chat> ──…`). No alternate name (e.g. `chat-room`) exists
   anywhere under `web/v2/`.

2. **Source file:** `web/v2/chat.js` (class `ChumpChat`, registered at
   line 417).

3. **Consumers referencing the same name** (confirms no drift between
   definition and call sites):
   - `web/v2/app.js:4196` — `ChumpViewChat.connectedCallback()` sets
     `this.innerHTML = '<chump-chat style="flex:1;min-height:0"></chump-chat>'`.
   - `web/v2/index.html:2150-2155` — `viewChat.querySelector('chump-chat')`
     (light-DOM lookup, since `<chump-chat>` itself attaches a shadow root).

## Related prior work

A deeper investigation of this same selector already exists —
[`docs/audits/INFRA-6338-chump-chat-selector-investigation.md`](./INFRA-6338-chump-chat-selector-investigation.md)
(INFRA-6338, also an INFRA-1433 slice) confirmed the same naming facts and
additionally root-caused why the `tauri-cowork-e2e` Selenium wait for this
selector times out in CI: `chump-chat` only mounts when the "Now" cadence's
Chat sub-tab is active, and the cadence's `default_view` was changed to
`'cockpit'` by PRODUCT-132 (PR #2066, 2026-05-15) — the e2e test never
clicks into the Chat sub-tab before waiting. See that doc for the
reproduction, root cause, and fix scope; this gap's AC (name + source file)
is answered above without needing to repeat that analysis.
