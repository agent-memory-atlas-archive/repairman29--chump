# CI Gates Inventory (INFRA-1762)

> **Goal.** Every deterministic CI gate either has a `chump preflight` mirror
> or a documented reason it cannot have one. The autonomy loop bleeds on every
> deterministic gate that fails post-push: ~5-10 min CI round-trip + force-push
> to fix. Mirrored locally, the same failure costs ~30 s.
>
> **Status as of 2026-05-23.** ~25 PR-required gates total. 5 mirrored
> (`cargo fmt`, `cargo clippy`, `cargo check`, scoped `test-*.sh`,
> event-registry-audit per INFRA-1731). 18 deterministic gates remain missing
> mirrors. 6-8 of those filed as per-gate follow-ups (see § Follow-up gaps).
> The rest are either low-frequency, low-cost-to-fail, or genuinely require
> GitHub state.
>
> **Generated inventory (INFRA-5119, INFRA-1861 slice, 2026-09-06).** The
> tables below are hand-maintained and drift as gates ship, get renamed, or
> get removed (e.g. the Tier C `test-env-vars-internal-coverage.sh` row below
> no longer corresponds to any `run:` step in `.github/workflows/*.yml` — the
> gate was removed from CI since it was filed). The authoritative,
> machine-generated per-gate mapping — every CI gate step scanned across
> `ci.yml` + sibling workflows, matched against its `chump preflight` mirror,
> Tier-D reason, or allowlist entry — lives at
> [`docs/process/CI_GATES_GENERATED_INVENTORY.md`](./CI_GATES_GENERATED_INVENTORY.md).
> Regenerate it with:
> ```bash
> CHUMP_GENERATE_INVENTORY=docs/process/CI_GATES_GENERATED_INVENTORY.md \
>   bash scripts/ci/test-preflight-ci-parity.sh
> ```
> As of the last regeneration: **339 gate steps scanned, 0 MISSING** (all
> have a mirror, a Tier-D reason, or an allowlist entry) — see that file's
> "MISSING preflight equivalents" section for the live AC-2 list. When that
> section is non-empty, file a gap per entry and add it to Tier C below.

## Reading guide

- **Tier A** — gate has a `chump preflight` mirror. Caught locally in < 30 s.
- **Tier B** — gate has a pre-push or pre-commit hook mirror but is NOT in
  `chump preflight`. (Hooks run on push/commit; preflight runs on demand.
  The autonomy boost from also having it in preflight is small.)
- **Tier C** — deterministic, mirrorable, but **no local equivalent**. These
  are the ones the autonomy loop bleeds on. **Highest leverage for new gaps.**
- **Tier D** — cannot be mirrored locally (requires GitHub API state, a
  running service, or a Linux-only environment). Documented but not filed.

---

## Tier A — locally mirrored ✅

| Gate | Where | Local mirror | Notes |
|---|---|---|---|
| `cargo fmt --check` | `fast-checks` job + `cargo-test` job | `chump preflight` step 1 (INFRA-1670) | Sub-second on warm cache |
| `cargo clippy -D warnings` | `clippy` job | `chump preflight` step 2 | ~10-60 s warm |
| `cargo check --workspace` | `cargo-test` job (prereq) | `chump preflight` step 3 | ~5-30 s warm |
| `scripts/ci/test-*.sh` (changed-only) | `fast-checks` + `audit` jobs | `chump preflight --with-tests` (scoped to diff) | Opt-in flag |
| **event-registry-audit** | `audit` job | `chump preflight` (auto-gated on diff) | **INFRA-1731 shipped #2377** |
| `test-fleet-pause-autolift.sh` | `test` job shard | pure shell sandbox, no GitHub API | **RESILIENT-066** |

## Tier B — hook-mirrored, not in preflight

| Gate | CI location | Hook mirror | Reason no preflight mirror |
|---|---|---|---|
| `cargo test --bin chump --tests` | `cargo-test` job | `pre-push` Guard 0g (INFRA-761) capped at 600 s (INFRA-1744) | Test runtime too long for preflight's <60 s target; pre-push catches it before push |
| `git-identity` (jeffadkins1@ for commits) | not on CI (commit-time) | `pre-commit-git-identity.sh` | Pre-commit only — would be redundant in preflight |
| `hardcoded-date` (no `2025-` literals in new code) | `fast-checks` job (`test-hardcoded-date-guard.sh`) | `pre-commit-hardcoded-dates.sh` | Pre-commit catches at edit time |
| `ac-completeness` (filed gaps have AC) | `pr-hygiene` job | `pre-commit-ac-completeness.sh` (commit-time) | Pre-commit fires; CI is the backstop |

## Tier C — missing local mirror, MIRRORABLE 🎯

These are the high-leverage follow-up targets. Each PR failure I've watched
this week was one of these.

| # | Gate (CI script) | What it checks | Local mirror? | Frequency observed | Filed gap |
|---|---|---|---|---|---|
| 1 | `test-env-vars-internal-coverage.sh` | Every `CHUMP_*` env var referenced in code is documented in `scripts/ci/env-vars-internal.txt` (DOC-026) | NO | **5+ this week** (#2363, #2367, #2381, etc. all batch-allowlists) | **INFRA-1787** |
| 2 | `test-infra-124-docs-delta-trailer.sh` | PRs touching `docs/` carry a `Net-new-docs: +N` trailer (INFRA-124) | NO | 2+ this week | **INFRA-1788** |
| 3 | `test-chump-subcommand-help.sh` | Every `chump <subcmd> --help` exits 0 (INFRA-1246) | NO | Rare but high-blast-radius regression (shipped 2× this quarter) | **INFRA-1789** |
| 4 | `test-markdown-intra-doc-links.sh` (changed-only) | No broken `.md` links in files modified by this PR (DOC-039) | NO | 1-2 per week | **INFRA-1790** |
| 5 | `test-gap-preflight-ac-gate.sh` | Open gaps with vague/empty AC are unpickable (INFRA-1259) | NO | Indirectly via `chump gap audit-ac --open` | **INFRA-1791** |
| 6 | `check-pr-scope.sh` | PR doesn't touch too many disjoint paths | NO | Operator-disciplined; rare CI fail | **INFRA-1792** |
| 7 | `test-no-claude-leak.sh` (warn-only on CI today) | No new Claude-specific refs in product-layer code (INFRA-1051) | NO | Warn-only on CI; promotion to strict planned | **INFRA-1793** |
| 8 | `test-broad-canary-coverage.sh` | `docs/process/CLAUDE_GOTCHAS.md` is updated when known-failure-mode files are touched | NO | Operator-discipline; low-frequency | **INFRA-1794** |

## Tier D — cannot mirror locally ⛔

Documented for completeness; do **not** file follow-ups.

| Gate | Why no local mirror |
|---|---|
| `branch-protection-drift.yml` | Reads live branch-protection rules from GitHub repo settings |
| `pr-rescue.yml` | Polls open PRs across the repo; needs GitHub API |
| `dependabot-auto-merge.yml` | Dependabot-only; runs against bot-authored PRs |
| `release-plz.yml` | Publishes to crates.io; needs registry credentials |
| `e2e-pwa-advisory.yml` | Spins up the PWA dev server + headless browser; too heavyweight for preflight |
| `acp-real-clients.yml` | Needs Zed/JetBrains ACP runtime |
| `cargo-audit-nightly.yml` | Cron-scheduled vulnerability scan; nightly cadence by design |
| `editor-integration.yml` | Needs editor process + IPC |
| `audit-weekly.yml` | Weekly summary of audit metrics; reads merged-PR history |
| `pr-triage-bot.yml` | Triages OTHER PRs; not gating this one |
| `queue-driver.yml` | Manipulates merge queue state |
| `ftue-clean-machine-2026.yml` | Requires a fresh VM |
| `no-anthropic-smoke.yml` | Validates chump-first contract under no-network |
| `sccache health probe` | Probes R2 remote-cache connectivity in CI runner environment; local dev has different network + credentials — meaningless to run locally (INFRA-2288) |
| `sccache --show-config (BuildBuddy + R2 URLs)` | Diagnostic print of CI-only env vars (`SCCACHE_BUILDBUDDY_URL`, `SCCACHE_ENDPOINT`) and the running sccache server's stats; local dev has neither the secrets nor a CI-started server (INFRA-4653) |
| `actionlint — workflow syntax gate` (META-199) | Uses `rhysd/actionlint` GitHub Action; requires the actionlint binary not in standard preflight env |
| `coverage-nightly.yml` (META-200) | Nightly cron only; llvm-cov instrument pass is too slow for per-PR preflight |
| commit-msg docs-delta trailer check | INFRA-1969/INFRA-3379 — `test-docs-delta-commit-msg.sh` validates the commit-msg git hook itself; runs as a `commit-msg` hook, not a preflight gate — mirroring would duplicate hook logic rather than test something preflight doesn't already cover |
| gap-reserve concurrency | INFRA-021/301/INFRA-3379 — `test-gap-reserve-concurrency.sh` requires a freshly `cargo build`-ed `chump` binary on `PATH`; the parallel-claim race it tests only reproduces against the compiled binary, too slow for the preflight fast loop |
| gap-reserve ID zero-padding | INFRA-080/INFRA-3379 — `test-gap-reserve-padding.sh`, same as above, requires compiled `chump` binary on `PATH` |
| gap-reserve --acceptance-criteria gate | CREDIBLE-1300/INFRA-3379 — `test-chump-gap-reserve-acceptance-criteria.sh` requires a compiled `chump` binary on `PATH` to exercise the reserve CLI gate; same shape as the sibling gap-reserve functional tests above |
| gap-ID cross-session collision | CREDIBLE-052/INFRA-3379 — `test-gap-id-cross-session.sh` requires `CHUMP_BIN` pointing at a compiled `chump` binary; cross-session collision fixture needs the real CLI, not source |
| gap-ID lease uniqueness gate | INFRA-1970/INFRA-3379 — `test-gap-id-lease-uniqueness.sh` requires `CHUMP_BIN`; duplicate-PR race-window guard needs the compiled binary under concurrent invocation |
| UUID gap-ID compatibility | INFRA-3379 — `test-uuid-gap-id-compat.sh` requires `CHUMP_BIN`; UUID gap-ID compatibility fixture drives the real CLI |
| release --lease | INFRA-3379 — `test-release-lease-flag.sh` requires `CHUMP_BIN`; `--lease` release flag fixture drives the real CLI |
| CLI help system consistency | INFRA-3383 — `test-cli-help.sh`; falls back to `cargo build --bin chump` when no binary is on `PATH`; too slow for the preflight fast loop (step name matched, not script path — the CI step wraps it in a multi-line `run: \|` with a `CHUMP_BIN=` prefix line) |
| CLI integration tests | INFRA-3383 — `test-cli-integration.sh`; requires a compiled `chump` binary on `PATH` to exercise; not preflight-fast-loop shaped (step name matched — see note above) |
| `test-infra-254-pwa-root-redirect.sh` | INFRA-3383 — runs `cargo build --bin chump` and spins up the PWA server on a port; too heavyweight for preflight |
| `test-subagent-budget-kill.sh` | INFRA-3383 — INFRA-1972 parent-enforced kill is a runtime supervisor test that spawns + kills child processes; not preflight-shaped |
| `test-md-links-loop.sh` | INFRA-3383 — INFRA-1925 md-links curator loop smoke; tests a curator daemon loop, not a per-commit gate |
| `test-review-handoff-smoke.sh` | INFRA-3383 — INFRA-774 end-to-end smoke (synthesizes a CI failure + simulates `review --serve` + telemetry assertions); needs the full CI fixture env |
| `test-rollup-semantic.sh` | INFRA-3383 — unconditionally runs `cargo test --bin chump rollup_cmd` when `cargo` is available; too slow for the preflight fast loop |
| `test-research-026-preflight.sh` | INFRA-3383 — eval harness preflight; requires `scripts/eval/` setup not present in a bare preflight run |

## Required-vs-advisory disposition decisions

Gates that were demoted out of `ci.yml` (INFRA-1381) and now run only in
`ci-nightly.yml` / `ci-advisory.yml` need an explicit disposition: PROMOTE
back to required, or KEEP-ADVISORY with a documented reason + review-by
date. `docs/process/CI_GATES.md` referenced by earlier gap filings does not
exist in this repo — this section (`CI_GATES_INVENTORY.md`) is the
canonical home for these decisions.

| Gate | Disposition | Rationale | Flake/fail rate cited | Review by |
|---|---|---|---|---|
| `tauri-cowork-e2e` | **KEEP-ADVISORY** (nightly + post-merge only, INFRA-1385) | Full Tauri + WebDriver smoke is failing almost every run, not flaking occasionally — this is a broken/too-fragile-to-gate environment, not a borderline-flaky test. Promoting to required would block ~every PR. | `gh run view` job-level conclusion for the `tauri-cowork-e2e` job: **30/30 failures** on `ci-nightly.yml` (last 30 runs) and **29/30 failures** on `ci-advisory.yml` (post-merge, last 30 runs) as of 2026-08-21. `scripts/ci/check-gate-fire-rate.sh` referenced by earlier gap filings does not exist in this repo; `scripts/dispatch/gate-fire-rate.sh` covers chump-internal `gate_check_*` ambient events, not GitHub Actions job outcomes, so job-level `gh run view` history was used instead. | 2026-11-21 (re-check after Tauri/WebDriver environment work, or after 90 days, whichever first) |
| `e2e-battle-sim` | **KEEP-ADVISORY** (nightly + post-merge only, INFRA-1386) | Not borderline-flaky and not broken — it is currently a **no-op**. `scripts/ci/run-battle-sim-suite.sh` has a `BATTLE_SIM_SKIP_IF_NO_LLM=1` guard (both `ci-nightly.yml` and `ci-advisory.yml` set this env var) that `exit 0`s immediately when neither `OPENAI_API_BASE` nor `OPENROUTER_API_KEY` is set — and neither workflow provisions an LLM credential for this job. Every recorded run completes in ~7s (checkout + skip-echo only); the mock-project fix-and-verify loop the suite exists to exercise never runs. Promoting to required would gate every PR on a check that provides **zero signal** while still costing a required-check slot + runner minute. KEEP-ADVISORY until CI wiring for an LLM credential (Ollama service container or `OPENROUTER_API_KEY` secret) makes the suite actually execute — only then is a flake-rate re-measurement meaningful. | `gh run view` job-level conclusion for the `e2e-battle-sim` job: **30/30 "success"** on `ci-nightly.yml` and **30/30 "success"** on `ci-advisory.yml` (last 30 runs each) as of 2026-08-21 — but every run's `startedAt`→`completedAt` span is ~7s, confirming the skip-guard fires every time rather than the suite actually running. `scripts/ci/check-gate-fire-rate.sh` referenced by the gap filing does not exist in this repo (same gap as INFRA-1385/tauri-cowork-e2e); job-level `gh run view` history was used instead. | 2026-11-21 (re-check once an LLM credential is wired into `ci-nightly.yml`/`ci-advisory.yml` for this job, or after 90 days, whichever first) |
| `e2e-golden-path` | **KEEP-ADVISORY** (nightly + post-merge only, INFRA-1387) | Unlike `tauri-cowork-e2e` and `e2e-battle-sim`, this gate is **neither broken nor a no-op** — `scripts/ci/verify-external-golden-path.sh` + `scripts/ci/golden-path-timing.sh` do a real `cargo build` (debug) and file-presence smoke, and the job is consistently green. That real signal is exactly why it's still worth measuring, but RESILIENT-016 (2026-05-17) moved it off the per-PR path for a *cost* reason, not a *correctness* reason: the job needs `apt-get install webkit2gtk-4.1`/`libayatana-appindicator3-dev`/etc. plus a full cargo build (~4-5 min wall-clock per run), and running that on every PR was part of the 5+-simultaneous-PR pileup RESILIENT-016 fixed (see `INFRA-1529`). Re-enabling it as required in `ci.yml` would reintroduce that per-PR runner-minute + apt-install cost, and — separately — the job today runs with `continue-on-error: true` inside a matrix (`e2e` job) feeding a rollup (`test-e2e`) that is *itself* `continue-on-error: true`; promoting for real would mean restructuring that matrix/rollup, not just flipping a flag, which is out of scope for this s-effort disposition gap. KEEP-ADVISORY for now; the near-100% pass rate below makes this the strongest PROMOTE candidate of the three RESILIENT-016 gates if/when the e2e matrix is restructured to make per-suite required-vs-advisory splits cheap. | `gh api .../actions/runs/<id>/jobs` job-level conclusion for the `e2e-golden-path` job, last 30 runs each as of 2026-08-21: **30/30 "success"** on `ci-advisory.yml` (post-merge, ~4-5 min per run) and **29/30 "success" + 1 "cancelled"** on `ci-nightly.yml`. `scripts/ci/check-gate-fire-rate.sh` referenced by the gap filing does not exist in this repo (same gap as INFRA-1385/INFRA-1386); job-level `gh api`/`gh run list` history was used instead. | 2026-11-21 (re-check after any e2e matrix/rollup restructuring makes per-suite required promotion cheap, or after 90 days, whichever first) |

## Promotion criteria for Tier C → Tier A

Each follow-up gap (INFRA-1787..1794) ships when:

1. The gate runs under `chump preflight` with **the same exit semantics as
   CI** (same fail messages, same fail codes).
2. The gate is **scope-gated**: skipped when the staged diff doesn't include
   any of its trigger paths. Keeps preflight fast on docs-only PRs.
3. A **per-gate bypass env var** is documented (e.g.
   `CHUMP_PREFLIGHT_SKIP_ENVVARS=1`) and emits a `preflight_<gate>_bypassed`
   audit event when used.
4. A smoke test at `scripts/ci/test-preflight-<gate>-gate.sh` asserts
   the gate fires on synthetic failure + bypass-env produces a clean 0 exit
   with the audit emit.

This is the **INFRA-1731 pattern**: that's how the event-registry mirror
shipped, and how every Tier C gap should land.

## Tracking

Each per-gate gap emits `kind=ci_gate_mirrored` when it ships, queryable via
`chump-coord ci-gate-coverage` (per INFRA-1762 AC-4). When all of
INFRA-1787..1794 land, Tier A grows from 5 → 13 gates; the autonomy-tax
falls roughly proportionally.

## Update history

- **2026-05-23** — Initial inventory. INFRA-1731 just shipped as the
  first mirror beyond cargo gates. INFRA-1787..1794 filed as per-gate
  follow-ups.
