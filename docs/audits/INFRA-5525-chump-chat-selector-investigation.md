# `chump-chat` selector — re-verification, no drift (INFRA-1433 slice)

> **Gap:** INFRA-5525 (INFRA-1433 slice)
> **AC:** (1) determine whether the selector is stale/renamed, missing due to
> app-init failure, or blocked by missing X11/D-Bus deps in CI; (2) document
> root cause in a short report.

## Verdict: not stale, not an env/dependency problem — already root-caused and fixed

This is the sixth INFRA-1433 slice (after INFRA-4301, INFRA-5211, INFRA-6338,
INFRA-6916, INFRA-7154, INFRA-7412). Re-checked all three AC branches against
current `main` (2026-09-25):

1. **Stale/renamed selector?** No. `customElements.define('chump-chat',
   ChumpChat)` (`web/v2/chat.js:417`) still matches `By.css('chump-chat')`
   (`e2e-tauri/run.mjs:128`) verbatim. Grep for `chat-room` or any other
   rename candidate under `web/v2/` finds nothing.
2. **App-init failure in CI?** No. `#app-title` locates in seconds on
   `ci-nightly.yml` runs (confirmed previously via live run `34817040814`,
   INFRA-6338); only cosmetic AT-SPI/DRI3 warnings, no fatal error.
3. **Missing X11/D-Bus dependency?** No — ruled out by (2); the app mounts
   fine in the xvfb session.

**Actual root cause (INFRA-6338, applied by INFRA-7412):** `<chump-chat>`
only mounts while the Chat sub-tab of the "Now" cadence is active. PRODUCT-132
(2026-05-15) changed the cadence's `default_view` from `'chat'` to
`'cockpit'`, so `e2e-tauri/run.mjs` timed out waiting for an element that was
never rendered — a boot-sequence/test-navigation gap, not a selector rename
or a missing dependency. INFRA-7412 shipped the fix: `run.mjs` now clicks
`[data-view="chat"]` before waiting on `chump-chat` (`e2e-tauri/run.mjs:114-115`).

## Confirmation the fix holds

Live nightly run `36104297256` (2026-09-25T06:45Z) — job `tauri-cowork-e2e`
job-level `conclusion: success`. `tauri-cowork-e2e` remains PR-non-blocking
(`if: false`, RESILIENT-016, `.github/workflows/ci.yml:312`) but is green on
its actual (nightly) execution path.

## Disposition

No code change needed. This slice reconfirms INFRA-7412's fix still holds
with zero drift 11 days later. See `docs/process/CLAUDE_GOTCHAS.md` →
"`chump-chat` selector confirmed NOT stale" for the full history and prior
slices' findings.
