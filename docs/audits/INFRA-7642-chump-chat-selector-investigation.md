# `chump-chat` selector — re-verification, no drift, no reproduction (INFRA-1433 slice)

> **Gap:** INFRA-7642 (INFRA-1433 slice)
> **AC:** (1) run `tauri-cowork-e2e` locally; (2) observe the 60s timeout on
> the `chump-chat` selector; (3) capture console/Selenium logs showing the
> failure.

## Verdict: the timeout does not reproduce — fixed since INFRA-7412, reconfirmed since INFRA-5525

This is the eighth INFRA-1433 slice (after INFRA-4301, INFRA-5211,
INFRA-6338, INFRA-6916, INFRA-7154, INFRA-7412, INFRA-5525). A local run is
not possible in this environment (no built Tauri binary, no `tauri-driver`,
no X11 display) — CI's `ci-nightly.yml` `tauri-cowork-e2e` job is the only
environment that actually exercises the Selenium/webdriver path, so it's the
substitute reproduction surface used by every prior slice, including this
one.

Checked the last 3 nightly runs (2026-09-23 through 2026-09-25) — all green:

```
run 36104297256 (2026-09-25T06:45Z): tauri-cowork-e2e conclusion=success
run 35966456786 (2026-09-24T06:50Z): tauri-cowork-e2e conclusion=success
run 35828653395 (2026-09-23T06:50Z): tauri-cowork-e2e conclusion=success
```

Job log from the most recent run (`36104297256`, job `107973287714`) shows
`chump-chat` locating in ~10ms after the Chat nav click — no timeout:

```
tauri e2e: #app-title found at t=1790319255217; clicking Chat nav…
tauri e2e: Chat nav clicked at t=1790319255266; waiting for <chump-chat>…
tauri e2e: <chump-chat> located at t=1790319255274; waiting for shadow root…
tauri webdriver e2e: ok (page-load + chump-chat upgrade verified; INFRA-263 will restore /task round-trip)
```

## Why the 60s timeout in the AC doesn't reproduce

The AC describes the original bug (pre-fix): `e2e-tauri/run.mjs` waited on
`By.css('chump-chat')` without ever navigating to the Chat sub-tab, because
PRODUCT-132 (2026-05-15) changed the "Now" cadence's `default_view` from
`'chat'` to `'cockpit'`, so `<chump-chat>` was never mounted. Root-caused by
INFRA-6338, fixed by INFRA-7412 (`e2e-tauri/run.mjs:114-115` now clicks
`[data-view="chat"]` before waiting on `chump-chat`), and reconfirmed with
zero drift by INFRA-5525 and again here.

## Disposition

No code change. Confirms the fix still holds. See
`docs/process/CLAUDE_GOTCHAS.md` → "`chump-chat` selector confirmed NOT
stale" and the prior slice docs for full history:

- [`INFRA-6338`](./INFRA-6338-chump-chat-selector-investigation.md) — original root cause.
- [`INFRA-7154`](./INFRA-7154-chump-chat-selector-investigation.md) — second confirmation.
- [`INFRA-7412`](./INFRA-7412-chump-chat-selector-investigation.md) — fix applied.
- [`INFRA-5525`](./INFRA-5525-chump-chat-selector-investigation.md) — fix reconfirmed, 11 days later.
