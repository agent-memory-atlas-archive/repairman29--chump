# CI app-init failure investigation — headless Xvfb/D-Bus (INFRA-1433 slice)

> **Gap:** INFRA-6093 (INFRA-1433 slice)
> **Scope:** why the `tauri-cowork-e2e` job's Selenium wait for `chump-chat` never
> succeeds in CI's headless environment.
> **Environment reproduced against:** Ubuntu 26.04 LTS "resolute" (local sandbox),
> apt package index matching the same archive `ubuntu-latest` runners draw from.

## Summary

The Selenium timeout described in INFRA-1433 is **not** caused by a stale CSS
selector (`web/index.html` already renders `#app-title` and `<chump-chat>` —
see `e2e-tauri/run.mjs`), and it is **not** caused by a missing X11 dependency
either. The real cause is that `.github/workflows/ci-nightly.yml`'s
`tauri-cowork-e2e` job — the only place this suite actually runs, since
`ci.yml`'s copy has been `if: false` since RESILIENT-016 — fails at **three
separate, stacked setup bugs**, every one of which aborts the job *before* the
app ever gets a chance to mount under Xvfb/D-Bus/WebKit. `continue-on-error:
true` on the job has hidden all three, every night, silently.

## Reproduction

Installed the job's declared dependencies on a headless Ubuntu box (no X
session, no desktop) matching the CI runner's apt archive:

```bash
sudo apt-get install -y xvfb webkitgtk-webdriver dbus-x11
which WebKitWebDriver xvfb-run dbus-launch   # all resolve — packages install fine
```

Then walked the job's actual steps in order:

1. **`bash scripts/ci/run-tauri-cowork-e2e.sh`** (the exact command
   `ci-nightly.yml` line 59 ran) — **fails immediately**:
   ```
   bash: scripts/ci/run-tauri-cowork-e2e.sh: No such file or directory
   ```
   The script was renamed/never existed under that name; the real script is
   `scripts/ci/run-tauri-e2e.sh` (confirmed via `git log` / repo search — every
   other reference in the repo, `book/src/operations.md`,
   `docs/operations/OPERATIONS.md`, `docs/architecture/PWA.md`,
   `e2e-tauri/README.md`, all point at `run-tauri-e2e.sh`). This is an exit-127
   shell error, not an app-mount failure — it never reaches Xvfb, D-Bus, or
   WebKit at all.

2. Even pointed at the correct script, `run-tauri-e2e.sh` guards on
   `command -v tauri-driver` and exits 1 with "Install tauri-driver: cargo
   install tauri-driver --locked" — because **`ci-nightly.yml` never installs
   the `tauri-driver` binary**. The step is literally named "Install Linux
   packages (tauri-driver)" but only runs `apt-get install` for system libs;
   there is no `cargo install tauri-driver` anywhere in the job.

3. Even with `tauri-driver` installed, the script also guards on
   `command -v WebKitWebDriver` and exits 1 if absent. `ci-nightly.yml`'s apt
   package list (`webkit2gtk-4.1 libwebkit2gtk-4.1-dev
   libayatana-appindicator3-dev build-essential pkg-config libssl-dev
   libgtk-3-dev librsvg2-dev xvfb`) never installs a WebDriver package at all
   — `webkit2gtk-driver` (the package `ci.yml`'s disabled copy of the job
   uses) is simply absent from the nightly job's list.

None of these three are D-Bus or X11 dependency gaps — Xvfb and dbus-daemon
both installed and ran fine locally. They're CI-config drift: the working
script/binary/package names that exist in `ci.yml`'s (disabled) job and in
`scripts/ci/run-tauri-e2e.sh` were never carried over correctly into
`ci-nightly.yml` when the suite was moved there by RESILIENT-016
(2026-05-17), and `continue-on-error: true` meant nobody saw the red X.

## Secondary finding: package-name drift risk

While reproducing, `apt-get install -y webkit2gtk-driver` (the package name
`ci.yml`'s disabled job still uses) **failed outright** on Ubuntu 26.04:

```
Package 'webkit2gtk-driver' has no installation candidate
E: Unable to locate package webkit2gtk-driver
```

`apt-cache showpkg webkit2gtk-driver` shows it as a transitional/reverse-dep
only; the real package is now `webkitgtk-webdriver`:

```
$ apt-cache policy webkitgtk-webdriver
webkitgtk-webdriver:
  Installed: (none)
  Candidate: 2.52.6-0ubuntu0.26.04.1
```

`ubuntu-latest` on GitHub Actions is 24.04 as of this writing (where
`webkit2gtk-driver` still resolves — confirmed by the 2026-05-30
`CI_DEPENDENCY_AUDIT_2026-05-30.md` verifying the whole apt list), but the
label rolls forward to newer LTS releases over time. Once it does, `ci.yml`'s
`tauri-cowork-e2e` job (currently `if: false`, but not deleted, so it *will*
run again the moment someone re-enables it) will fail the same way. This is
now guarded against — see Fix below.

## Root cause (per AC)

1. **`ci-nightly.yml` referenced a script that doesn't exist**
   (`run-tauri-cowork-e2e.sh` vs. the real `run-tauri-e2e.sh`) — exit 127
   before any app-mount attempt.
2. **`ci-nightly.yml` never installs the `tauri-driver` binary** — the
   WebDriver intermediary between Selenium and WebKitGTK never starts.
3. **`ci-nightly.yml` never installs a WebKitWebDriver system package**
   (`webkit2gtk-driver` / `webkitgtk-webdriver` depending on Ubuntu release) —
   the actual browser-automation endpoint is absent.
4. (Latent, not yet triggered) **`webkit2gtk-driver` is renamed to
   `webkitgtk-webdriver` on Ubuntu 26.04+** — `ci.yml`'s disabled job would
   break the same way once `ubuntu-latest` advances that far.

No D-Bus or X11 library was actually missing in either workflow's apt list;
`xvfb`, `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `librsvg2-dev`,
`libayatana-appindicator3-dev` were all correctly declared. The "app never
mounts" symptom in INFRA-1433 traces to the job dying at setup, not to a
runtime X11/D-Bus fault during app init.

## Required packages (confirmed via local install)

| Package | Role | Notes |
|---|---|---|
| `xvfb` | virtual framebuffer so WebKitGTK can open a display headlessly | present in both workflows already |
| `libwebkit2gtk-4.1-dev` | WebKitGTK dev headers, needed to build `chump-desktop` | present already |
| `libgtk-3-dev`, `librsvg2-dev`, `libayatana-appindicator3-dev` | Tauri/GTK build deps | present already |
| `webkit2gtk-driver` (Ubuntu ≤24.04) **or** `webkitgtk-webdriver` (Ubuntu ≥26.04) | provides the `WebKitWebDriver` binary the app is automated through | **was entirely missing from `ci-nightly.yml`**; name varies by Ubuntu release |
| `tauri-driver` (cargo binary, not apt) | WebDriver-protocol bridge between Selenium and `WebKitWebDriver` | **was entirely missing from `ci-nightly.yml`** |

## Fix applied (INFRA-6093)

- `.github/workflows/ci-nightly.yml`: corrected the script invocation to
  `scripts/ci/run-tauri-e2e.sh`; added a `cargo install tauri-driver --locked`
  step; added the WebKitWebDriver apt package with a `webkit2gtk-driver ||
  webkitgtk-webdriver` fallback.
- `.github/workflows/ci.yml` (currently `if: false`, kept in sync so it's
  correct whenever re-enabled): same `webkit2gtk-driver || webkitgtk-webdriver`
  fallback for the WebKitWebDriver apt package.

## Out of scope (tracked on the parent gap)

INFRA-1433's broader AC (stale-selector regression check, smoke test
`scripts/ci/test-chump-chat-selector.sh`, decide nightly-only vs. per-PR) is
unchanged by this slice — the selector itself was already current
(`#app-title`, `<chump-chat>`) in `e2e-tauri/run.mjs` at investigation time.
Whether the now-fixed nightly job passes end-to-end (i.e. the Selenium wait
actually resolves once setup succeeds) should be confirmed on the next
`ci-nightly` scheduled run and folded back into INFRA-1433.
