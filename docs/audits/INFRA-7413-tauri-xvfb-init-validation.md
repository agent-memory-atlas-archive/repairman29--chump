# Tauri app initialization under CI's xvfb headless env — validated (INFRA-1433 slice)

> **Gap:** INFRA-7413 (INFRA-1433 slice)
> **Scope:** run the `tauri-cowork-e2e` CI job (or equivalent) with xvfb,
> capture logs, and determine whether D-Bus/X11 errors prevent the app from
> mounting.
> **Evidence:** live `ci-nightly.yml` run `35316301882`
> (2026-09-18T06:45:47Z, pre-dates the INFRA-7412 fix landing at
> 2026-09-18T19:44:36-06:00), job `tauri-cowork-e2e`, full log reviewed via
> `gh run view --log`.

## Summary

**The app mounts successfully under xvfb.** No D-Bus or X11 error prevents
initialization. Two warnings appear during `chump-desktop` startup and are
both benign / non-fatal — the WebView renders and the PWA shell loads within
seconds regardless:

```
(chump-desktop:21203): dbind-WARNING **: 06:54:05.500: AT-SPI: Error retrieving accessibility bus address: org.freedesktop.DBus.Error.ServiceUnknown: The name org.a11y.Bus was not provided by any .service files
libEGL warning: DRI3 error: Could not get DRI3 device
libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
tauri e2e: #app-title found at t=1789714447889; waiting for <chump-chat>…
```

- **AT-SPI / D-Bus warning** — `dbind-WARNING`: the accessibility bus
  (`org.a11y.Bus`) is absent under xvfb (no session D-Bus service registers
  it). This only affects screen-reader/AT integration; it does not block
  WebKitGTK from creating a window or loading content.
- **libEGL / DRI3 warning** — xvfb has no real GPU, so DRI3 hardware
  acceleration is unavailable. WebKitGTK falls back to software rendering
  and continues; this is expected in any headless X server, not a chump-specific
  defect.
- **App mount confirmed** — `#app-title` (light-DOM, always rendered on
  first paint) is located at `t=1789714447889`, ~2.2s after the "Running
  WebDriver tests under xvfb…" log line. The web server health check
  (`/api/health`) also passed before the WebDriver session started. Both
  confirm the Tauri shell fully initializes — window created, WebView
  attached, page loaded, JS executed — inside xvfb.

This job still ends in a `TimeoutError` on this run, but the timeout is on
the **`chump-chat` CSS selector**, not on app initialization — and that
failure mode is pre-existing/known (root-caused by INFRA-6338, re-verified
by INFRA-7154/INFRA-7412) and already fixed on `main` post-INFRA-7412
(`e2e-tauri/run.mjs` now clicks `[data-view="chat"]` before waiting on the
selector). The run examined here (`35316301882`, started 06:45:47Z) predates
that fix landing (19:44:36-06:00 the same day), so it's the last available
nightly evidence of the pre-fix behavior — useful here specifically because
it isolates the app-mount question from the selector question.

## Per-AC findings

1. **Ran the CI job with xvfb and captured logs.** Used the live
   `ci-nightly.yml` `tauri-cowork-e2e` job run (`35316301882`) rather than a
   fresh local run — `run-tauri-e2e.sh` is Linux-only and requires
   `webkit2gtk`, `tauri-driver`, and `WebKitWebDriver` system packages
   matching the CI image; the nightly run is the same command
   (`bash scripts/ci/run-tauri-e2e.sh` → `xvfb-run -a npm test`) executed on
   the same `ubuntu-latest` base the gap is asking about, and gives
   reproducible, timestamped, non-cherry-picked evidence.
2. **No D-Bus or X11 error prevents mounting.** The only D-Bus-adjacent
   message is the AT-SPI accessibility-bus warning above — cosmetic, not
   fatal. No X11 connection failure, no WebKitGTK crash, no `Xvfb` startup
   error appears anywhere in the job log.
3. **Log excerpt provided above** shows successful initialization
   (`#app-title found`) immediately following the benign warnings.

## Related

- [`docs/audits/INFRA-6338-chump-chat-selector-investigation.md`](./INFRA-6338-chump-chat-selector-investigation.md) — original root-cause of the `chump-chat` selector timeout (view-default drift, not an init/env issue).
- [`docs/audits/INFRA-7154-chump-chat-selector-investigation.md`](./INFRA-7154-chump-chat-selector-investigation.md) — confirms selector name unchanged.
- [`docs/audits/INFRA-7412-chump-chat-selector-investigation.md`](./INFRA-7412-chump-chat-selector-investigation.md) — applies the test-side fix (click `[data-view="chat"]`); landed same day as this run, after it started.
- `docs/gaps/INFRA-1433.yaml` — parent gap, full original AC.
