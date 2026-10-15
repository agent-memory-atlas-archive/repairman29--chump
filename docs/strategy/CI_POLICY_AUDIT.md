---
doc_tag: log
owner_gap: DOC-089
last_audited: 2026-05-29
---

# CI Policy Audit (META-133 — META-131 slice 1/N)

> **Goal.** Inventory every CI check + every recent failure class so META-131 ("collapse 12 gates -> 1 verified aggregator") can be designed against reality, not memory.
>
> **Scope.** Required-status-checks, jobs in `.github/workflows/`, stub jobs, pre-commit / pre-push hooks. Each gets a row + the bug class it was added for + current cost.
>
> **Verdict driving META-131 (COMPLETED, CREDIBLE-1490).** ~70% of merges that week required `gh pr merge --admin` bypass. The cause was not the gates being wrong — most did catch real bugs. The cause was the **gate-shape**: the required-checks contract on `main` could not tell "skipped because path-filter said so" from "skipped because the workflow file is broken" from "skipped because of a runner crash." Every one of those reads as "this PR is not verified" -> operator bypasses to ship -> next PR sees no signal from the last bypass and repeats. The fix: one `verified` aggregator that explicitly classifies skips (path-filter / workflow-broken / runner-crash) and polls the full-fleet intent (audit + ACP smoke) routes every current gate without losing coverage. Shipped CREDIBLE-269 + CREDIBLE-1490.
>
> **Cross-references (do not duplicate — extend).**
> - [`docs/process/CI_GATES_INVENTORY.md`](../process/CI_GATES_INVENTORY.md) — Tier A/B/C/D taxonomy of mirrored-locally state (INFRA-1762).
> - [`docs/process/CI_PREFLIGHT_PARITY.md`](../process/CI_PREFLIGHT_PARITY.md) — full CI gate <-> preflight cross-reference (META-071).
> - [`docs/process/CI_REQUIRED_CHECKS_DESIGN.md`](../process/CI_REQUIRED_CHECKS_DESIGN.md) — design constraints for required checks (post-2026-05-25 wedge).
> - [`docs/process/CI_GATE_PROMOTION_LOG.md`](../process/CI_GATE_PROMOTION_LOG.md) — append-only promotion ledger (INFRA-1869).
> - [`docs/strategy/CI_REVIEW_2026-05-29.md`](./CI_REVIEW_2026-05-29.md) — 14-day failure catalog + 5 levers (37% of ships were CI-rot fixes).

---

## §1. Required-status-checks (the wall every PR hits)

Source: `gh api repos/repairman29/chump/branches/main/protection` + `gh api repos/repairman29/chump/rulesets/15133729` (both as of 2026-05-30).

Both surfaces — the legacy branch-protection rule and ruleset 15133729 ("Protect main") — now require **one** aggregated context:

| Context (literal name) | Workflow file | Emitting job | Effective cost (PR-blocking when failing) | Bug class caught |
|---|---|---|---|---|
| `verified` | `.github/workflows/ci.yml` | `verified` (aggregator polling ci.yml lanes + audit + ACP smoke) | Variable: <2 min aggregator overhead + max(ci.yml-local lanes, audit grace 120s, ACP smoke). Ci.yml lanes: ~5-8 min cargo-test, 3-5 min clippy, ~5 min fast-checks. Audit + ACP polled via cross-workflow Checks API (CREDIBLE-269, META-134). | Test/lint/fmt/PR-shape regressions across **944 test-*.sh** scripts + cargo workspace + Smoke + observability + cache + 60+ ambient-touching scripts + ACP wire-format regressions (Zed / JetBrains real-client compatibility) |

**Ruleset bypass actor:** RepositoryRole id=5 (admins), `bypass_mode: always`. This is the mechanism behind `gh pr merge --admin`.

**Critical context for META-131.** Required-status-check enforcement is **all-or-nothing** at the GitHub API level: if the listed context emits "skipped" because no check-run posted under that name, the PR sits BLOCKED forever (skipped != passing). INFRA-2191 (2026-05-29 #2741) added the `audit-stub` job whose **`name:` field is literally `audit`** (NOT `audit-stub`) precisely to satisfy this contract on doc-only PRs. The stub pattern is the design workaround; META-131 should subsume it.

---

## §2. ci.yml jobs (the main workflow)

`.github/workflows/ci.yml` is 2,182 lines, 20+ jobs. Counted from a fresh read of the file on `chump/meta-133-claim`:

| Job | Required? | Path-filter (when does it run?) | Runs-on default | Wall-clock target | Bug class | Stub-coupled? |
|---|---|---|---|---|---|---|
| `changes` | no | always | ubuntu-latest (or self-hosted, var) | <30s | paths-filter to gate downstream jobs | no |
| `pr-hygiene` | no (folds into `test`) | every PR + push + merge_group | ubuntu-latest | ~10 min | CREDIBLE-026/027 PR-shape (scope-vs-title, mass-deletion, AC coverage, install-manifest, PWA parse, research-privacy, voice-lint, broad-canary, merge-queue trigger coverage, workflow Linux-only guard) | no |
| `fast-checks` | no (folds into `test`) | rust/scripts change | ubuntu-latest (containerized — INFRA-2117) | target <5 min, cap 15m | cargo fmt + 100+ test-*.sh guards (gap-reserve, merge-driver, ambient schema, lease TTL, picker priority, fleet-bootstrap, all the daily-burn classes) | **yes — fast-checks-stub** |
| `clippy` | no (folds into `test`) | rust change | ubuntu-latest (INFRA-2117) | target 3-5 min, cap 20m | `cargo clippy --workspace --all-targets -- -D warnings` | **yes — clippy-stub** |
| `cargo-test` | no (folds into `test`) | rust change | ubuntu-latest (INFRA-2117) | target 5-8 min, cap 30m | `cargo nextest run --workspace` via INFRA-764 flake-rerun wrapper + sccache (INFRA-2093) | **yes — cargo-test-stub** |
| `test` (rollup) | **YES** | always | ubuntu-latest | <5 min rollup overhead | aggregator + INFRA-1002 cascade-cancel classification | no |
| `audit` | **YES** (real or stub) | not docs-only | ubuntu-latest (INFRA-2117) | <15 min | 80+ test-*.sh smokes (PWA observability, fleet-state mutex, GraphQL preflight, gap consolidate, AC enforcement, EVENT_REGISTRY strict, no-inline-ambient-printf, CI regression guard) | **yes — audit-stub** |
| `audit-stub` | (emits `audit` name) | docs-only PR OR no code | ubuntu-latest | <2 min | placeholder so the `audit` required check is satisfied without running 15-min smoke battery on doc-only PRs (INFRA-2191) | required-check sibling |
| `clippy-stub` | (covers `clippy-required`) | no code OR PR event | ubuntu-latest | <2 min | satisfies branch protection on docs-only PRs (INFRA-1143 stub pattern) | required-check sibling |
| `cargo-test-stub` | (covers `cargo-test-required`) | no code OR PR event | ubuntu-latest | <2 min | INFRA-1143 stub pattern | required-check sibling |
| `fast-checks-stub` | (covers `fast-checks-required`) | no code OR PR event | ubuntu-latest | <2 min | INFRA-1143 stub pattern | required-check sibling |
| `clippy-required` | optional rollup (INFRA-1143) | always | ubuntu-latest | <2 min | rollup: clippy OR clippy-stub passed | no |
| `cargo-test-required` | optional rollup | always | ubuntu-latest | <2 min | rollup: cargo-test OR stub passed | no |
| `fast-checks-required` | optional rollup | always | ubuntu-latest | <2 min | rollup: fast-checks OR stub passed | no |
| `audit-required` | optional rollup | always | ubuntu-latest | <15 min (has extra steps) | rollup + INFRA-779 gitdir repair test + 8 more append-only steps | no |
| `coverage` | no (continue-on-error) | rust change | ubuntu-latest | cap 45 min | CREDIBLE-006 llvm-cov line coverage; advisory drift detector vs `docs/credibility/COVERAGE_BASELINE.md` | no |
| `e2e-pwa` | no (continue-on-error) | e2e change OR merge_group | ubuntu-latest | cap 60 min, target ~30 min | Ollama (qwen2.5:7b) + cargo build + chump --web + Playwright | no |
| `e2e-battle-sim` | no (DISABLED — RESILIENT-016) | `if: false` (moved to nightly) | ubuntu-latest | n/a | battle simulator suite | no |
| `e2e-golden-path` | no (DISABLED — RESILIENT-016) | `if: false` (moved to nightly) | ubuntu-latest | n/a | external-golden-path + timing log | no |
| `test-e2e` (rollup) | no (continue-on-error) | always | ubuntu-latest | <5 min | aggregator for e2e shards | no |
| `tauri-cowork-e2e` | no (DISABLED — RESILIENT-016) | `if: false` | ubuntu-latest | n/a | Tauri WebDriver Selenium suite | no |
| `integration-test` | no (continue-on-error) | always after fast-checks | ubuntu-latest | cap 10 min | INFRA-849 claim->commit->ship pipeline with stubs | no |
| `required-check-grace-guard` | no (workflow_dispatch only) | grace=1 dispatch | ubuntu-latest | <30s | INFRA-1395 grace window — newly added required checks skip on pre-grace PRs | no |

**Stub count: 4 (clippy-stub, cargo-test-stub, fast-checks-stub, audit-stub).** Stubs exist because GitHub Actions treats skipped required-checks as failures. Every stub is a workaround for the same root problem and would consolidate into a single decision in a `verified` aggregator.

---

## §3. Other workflow files (24 .yml total in `.github/workflows/`)

| Workflow | Required? | Trigger | What it does | Bug class |
|---|---|---|---|---|
| `editor-integration.yml` | YES (ACP smoke step) | push + PR + merge_group | ACP JSON-RPC fixtures for initialize / session/new / session/list | ACP wire-format |
| `acp-real-clients.yml` | no | path-scoped PR + merge_group | matrix replay of recorded Zed/JetBrains messages + force-fire fixture | CREDIBLE-057 ACP real-client compat |
| `audit-weekly.yml` | no | Mon 08:17 UTC cron | `scripts/audit/run-all.sh` weekly; commits findings | INFRA-044 long-tail audits |
| `auto-flip-on-merge.yml` | no | merged PR | parses gap ID from PR title, runs `chump gap ship --update-yaml` | INFRA-2121 gap-registry drift (31 silent-shipped gaps as of 2026-05-29) |
| `branch-protection-drift.yml` | no | daily 07:23 UTC + on touch | diffs live branch protection vs `docs/baselines/branch-protection-main.json` | INFRA-121 silent auto-merge disarm |
| `cargo-audit-nightly.yml` | no | daily 03:00 UTC + push to main | `cargo audit` against RustSec DB | INFRA-503 (split out of per-PR for 12min/PR savings) |
| `ci-advisory.yml` | no | push to main | post-merge advisory jobs (demoted from ci.yml per INFRA-1381) | INFRA-1385/1386/1387 deferred-decision e2e |
| `ci-flake-rerun.yml` | no | workflow_run + 10min cron + dispatch | classify CI failures, rerun flake/infra-broken | INFRA-557 known-flake handling |
| `ci-nightly.yml` | no | 02:00 UTC daily | full e2e (tauri-cowork-e2e + battle-sim + golden-path) on main | RESILIENT-016 — e2e moved off PR path |
| `dependabot-auto-merge.yml` | no | dependabot PR open | arms `gh pr merge --auto --squash` once at open time | INFRA-NEW (PR #673 24h+ stuck) |
| `e2e-dogfood-nightly.yml` | no | 04:00 UTC daily + dispatch | full dogfood matrix (release build + LLM smoke) on main | INFRA-549 (moved from per-PR) |
| `e2e-pwa-advisory.yml` | no | PR + nightly cron | observability for `test.skip(!INCLUDE_PWA_FLAKES)` quarantined describes | INFRA-1332 PWA flake visibility |
| `ftue-clean-machine-2026.yml` | no | workflow_dispatch only | full 5-min FTUE demo on fresh runner (brew install -> orchestrate) | INFRA-600/799 onboarding regression |
| `ci.yml` (`gap-status-check` job, folded from `gap-status-guard.yml` INFRA-2299) | no | PR open/edit/sync/label | rejects PR if title gap-ID's YAML doesn't show `status: done` | INFRA-066/075/188 stale-status loop |
| `no-anthropic-smoke.yml` | no | PR | gap list / reserve / show / ship run with zero API key set | CREDIBLE-046 chump-first contract |
| `pr-rescue.yml` | no | 2h cron + dispatch | scan auto-merge-armed PRs, rebase + re-arm if stale (>4h) | RESILIENT-006 stale-PR (queue stranding) |
| `pr-triage-bot.yml` | no | workflow_run + check_run | auto-fix lint-class fails, file gap on test-class fails | INFRA-624 manual triage replacement |
| `queue-driver.yml` | no | push to main + 5min cron + check_suite + dispatch | push-update-branch the oldest BEHIND PR | INFRA-048 queue-stranded BEHIND PRs |
| `release-plz.yml` | no | push to main (publishable crates) | open release PR; publish to crates.io | release automation |
| `release.yml` | no | git tag push | cargo-dist artifacts + GitHub release | release automation |
| `repo-health.yml` | no | PR | fast (<60s) gap-ref / broken-doc-link / dead-env-var checks | INFRA-087 |
| `test-bot-autonomous.yml` | no | path-scoped PR | creates fixture PR with known clippy lint; asserts pr-triage-bot auto-fixes within 15 min | CREDIBLE-002 pr-triage-bot autonomy |
| `voice-lint.yml` | no | PR + merge_group | banned-words lint on docs/ changes | INFRA-1728 VOICE_GUARDRAIL |
| `ci.yml` | (covered §2) | — | — | — |

**24 workflow files, 4 stubs, 3 required contexts.** Of the 24 only `ci.yml` and `editor-integration.yml` contribute to required-status-checks. The other 22 are advisory or operational (cron daemons, advisory metrics, post-merge automation, the `pr-rescue` + `queue-driver` pair that keep the queue moving).

---

## §4. Pre-commit / pre-push hook gates (local first line of defense)

Source: `scripts/git-hooks/`. Pre-commit invokes the orchestrator at `pre-commit` (2021 lines), which calls each `pre-commit-*.sh` sibling. Pre-push (1291 lines) is similar.

| Hook | Lines | Bug class | Bypass mechanism |
|---|---|---|---|
| `pre-commit` (orchestrator) | 2021 | dispatches to siblings; also handles RESILIENT-025/026 off-rails contract (claim path + gap-ID in subject) | `CHUMP_OFF_RAILS_CHECK=0` or `Off-Rails-Bypass:` trailer |
| `pre-commit-ac-completeness.sh` | 149 | CREDIBLE-054 — staged gaps must have non-TODO acceptance_criteria | (none — gate is correctness) |
| `pre-commit-default-flip.sh` | 193 | INFRA-762 — silent default flips warned | `Default-Flip-Bypass:` trailer |
| `pre-commit-effect-metric.sh` | 100 | every gap must declare `effect_metric` | (none) |
| `pre-commit-event-registry.sh` | 110 | new `ambient emit` kinds must register or sit in `event-registry-reserved.txt` | strict mode (INFRA-1287) |
| `pre-commit-gap-divergence.sh` | 159 | INFRA-783 — YAML vs state.db divergence | (none) |
| `pre-commit-git-identity.sh` | 121 | INFRA-787 — commits must be `jeffadkins1@gmail.com` | (none) |
| `pre-commit-hardcoded-dates.sh` | 254 | INFRA-971 — no literal `2025-` in new source | `Hardcoded-Date-Bypass:` trailer |
| `pre-commit-main-worktree-config.sh` | 70 | META-011 — never edit src/ in main worktree | (CI catches the stomp class) |
| `pre-commit-obs-budget.sh` | 129 | INFRA-755 — new emit sites must register observability | `CHUMP_OBS_BUDGET_BYPASS=1` |
| `pre-commit-preflight-ci-parity.sh` | 62 | INFRA-2120 — new `ci.yml run:` step must mirror in preflight, be Tier-D, or sit in exceptions list | `CHUMP_PREFLIGHT_PARITY_CHECK=0` |
| `pre-commit-pwa-index-uniq.sh` | 54 | PWA `index.html` uniqueness | (none) |
| `pre-commit-redundancy.sh` | 132 | META-063 — no new duplicates of existing fleet primitives | `Redundancy-Bypass:` trailer |
| `pre-commit-rust-first.sh` | 318 | META-064 — shell that hits Rust-first criteria needs explicit bypass | `Rust-First-Bypass:` trailer |
| `commit-msg` | 68 | docs-delta trailer (INFRA-1969) | (corrective) |
| `pre-push` | 1291 | force-with-lease race guard, MERGED guard, KNOWN_FLAKES auto-bypass, cargo-test full-suite, off-rails branch check, CI regression guard pass-through, preflight | `--no-verify` (audited per INFRA-1834) |
| `pre-push-ci-regression-guard.sh` | (sibling) | INFRA-1421 — fix commits touching `ci.yml` must include CI-Regression-Guard test | (none — discipline gate) |

**Why this matters for META-131.** Pre-commit + pre-push together implement the local-first-line; their CI counterparts (the bulk of `fast-checks` + `audit` + `pr-hygiene` test-*.sh steps) are the network-cost replay. The `verified` aggregator design should treat **"local hooks passed AND CI confirmed"** as the joint signal — neither side alone is enough (locals can be `--no-verify`'d, CI can be wedged).

---

## §5. Failure-class breakdown — why admin-merge fired ~70% this week

This is the operational reality META-131 must fix. Each row is a concrete bug class observed since 2026-05-25 with evidence. Total observed admin-merges this week: ~16 events tagged `bot_merge_bypassed` in ambient (CI_REVIEW_2026-05-29 §"14-day failure catalog"), but the operator self-reports the rate is higher because many bypass via `gh pr merge --admin` directly (no ambient emit on the GH API path).

| # | Failure class | Concrete incident | Root cause | Why admin-merge was the recovery |
|---|---|---|---|---|
| 1 | **pr-hygiene chronic queue-wide** | PR #2752 (2026-05-29) had to ship as `fix(installer-manifest): map fleet-recorder + fleet-server as optional — unwedges pr-hygiene queue-wide`. Every open PR was failing `Install manifest gate` because two new install scripts (INFRA-2174 #2724, INFRA-2189 #2745) shipped without being added to `REQUIRED_DAEMONS` / `optional-installers-allowlist.txt` / `deprecated-installers-allowlist.txt`. | A required gate (install manifest INFRA-1810) blocks queue-wide on ANY new installer until the allowlist is updated — a coordination gap with the PR that adds the installer. | Bypass via admin merge so PR #2752 could land first. Queue could not self-recover. |
| 2 | **PWA Playwright flake** | INFRA-2128 — the `e2e-pwa` job is `continue-on-error: true` but its random failures still light up the rollup state visible in `gh pr checks`, which confuses bot-merge.sh + auto-merge arm decisions. | Playwright + Ollama warm-up timing is genuinely flaky; quarantined describes (`INCLUDE_PWA_FLAKES=1`) get visibility via `e2e-pwa-advisory.yml` but the per-PR ci.yml lane still spits noise. | Operator visually confirms "only PWA flake red, rest green" then admin-merges. |
| 3 | **ACP smoke runner backup** | `ACP protocol smoke test (Zed / JetBrains compatible)` from `editor-integration.yml` is the third required context. Self-hosted Mac runner queue saturated; ACP smoke sits pending 20+ min while real bug-finding gates have already passed. | Self-hosted runner pool sizing + serial draining of required check; ACP smoke does NOT path-filter so every PR queues for it. | Admin merge once the operator sees the other two required checks are green and ACP has been pending too long. |
| 4 | **ci.yml workflow file silent break** | INFRA-2200 (#2749 post-mortem 2026-05-30). `runner.temp` was used in a `job.env:` context where the expression is not allowed; `actions/runner-listener` accepted the file (no schema validation at API level) but every single CI run from 2026-05-27 14:30Z to 2026-05-29 22:35Z (~265 commits, ~50 runs) failed to QUEUE — "This run likely failed because of a workflow file issue", 0 jobs reported. | A workflow file syntax error that fails parse-time but does NOT fail submit. Required-status-checks were satisfied by **prior** check-run records on the head SHA from when the file was healthy, OR by ruleset relaxation during cascade-break windows. | Admin merge was the **only** recovery — no PR could earn a required-check green because no jobs ran. ~2 days of unverified merges. |
| 5 | **Silent open required-checks** | INFRA-2201 (shipped #2780). Doc-only PRs ran into ruleset 15133729 requiring the bare context `audit` while the `audit` job's `if:` short-circuited to skip on docs-only — no check-run ever posted under that name, PR sat BLOCKED with 0 fails 0 pending forever. | Stub pattern (INFRA-1143) covered `audit-required` but the ruleset (separate from legacy branch protection) had `audit` as the required context. Mutual-exclusion contract was not enforced until INFRA-2191 made `audit-stub` emit under name `audit`. | Operator either admin-merged or temporarily edited the ruleset to drop `audit` (cascade-break window). |
| 6 | **Bot-merge GraphQL exhaustion / poll stall** | bot-merge.sh hangs in `pollForState` 15min+ waiting for `mergeStateStatus=CLEAN` while GraphQL budget is exhausted (132 events in 14d per CI_REVIEW); cache fallback exists (INFRA-1081) but the merge-decision call itself goes GraphQL. INFRA-1939 added exit-144-fast guard. | Burst contention from autopilot + bot-merge + dashboard polling overwhelming the GraphQL bucket. | `CHUMP_BYPASS_BOT_MERGE=1` + manual `gh pr merge --admin` — admin needed because the missed-poll window left the PR in BLOCKED state from a stale check the cache hadn't refreshed. |
| 7 | **fast-checks queue-wide trunk-RED (cargo fmt drift)** | INFRA-2216 (#2782 2026-05-30) — `cargo fmt --all` drift in 4 files of `chump-integrator` after a merge that didn't run preflight. Every other open PR hit `cargo fmt --all -- --check` failure on rebase. | Lack of preflight discipline on the source PR; `chump preflight` would have caught it locally per the INFRA-1673 mandate but `--no-verify` was used. | Admin-merge the fix PR #2782 first to unwedge the queue, then re-trigger CI on the others. |
| 8 | **audit queue-wide trunk-RED (backfill-shipped-gaps.sh allowlist)** | INFRA-2218 (#2784 2026-05-30) — a new script in `scripts/coord/` triggered the raw-gh lint gate (INFRA-1274) or a sibling that walks `scripts/coord/**`. | A new tool needed allowlist entry; the gate fires on first PR that adds the file + every subsequent rebase. | Admin-merge to land allowlist, then queue self-recovers. |

**Pattern across all 8 classes.** The CI surface has **no** signal that distinguishes "this PR's diff caused a real failure" from "infrastructure failure caused a missing or stale check-run." The operator's only recourse is to (a) read the failure manually, decide it's infrastructure not PR-content, and (b) admin-merge. **META-131 must make this distinction first-class** — that's the entire point of the consolidation.

---

## §6. Consolidation thesis — every current check routed to one `verified` aggregator

Hypothesis: A single required-status-check named `verified` whose **decision rule explicitly classifies each input** would route every current gate without losing coverage, and would make ~80% of this week's admin-merges unnecessary by adding the "infrastructure-failed != PR-bad" signal at the contract surface.

### Routing table

| Current gate (or class) | Aggregator-input role | Why this routing |
|---|---|---|
| `test` (rollup: fast-checks + clippy + cargo-test + pr-hygiene) | **required input** | These are the actual correctness gates; failure should always block. |
| `audit` (real, not stub) | **required input** when run; **path-skipped-via-stub** else | Stub becomes a first-class "skipped because docs-only" signal that aggregator counts as PASS, not WAIT-FOREVER. |
| `ACP protocol smoke test (Zed / JetBrains compatible)` | **required input** | ACP wire-format regressions are real bugs; keep as required. |
| `audit-stub` / `clippy-stub` / `cargo-test-stub` / `fast-checks-stub` | **input "path-skipped" signal**, not its own required check | Aggregator reads "stub fired because path-filter excluded code" as PASS. Eliminates the 4-stub pattern as a separate concern. |
| `audit-required` / `clippy-required` / `cargo-test-required` / `fast-checks-required` | **already-rollup; collapse into `verified`** | They are exactly the kind of rollup `verified` would subsume; no information loss. |
| `coverage` (continue-on-error) | **advisory** — surfaced as a `verified` annotation, not a blocking input | Already non-blocking; just stop polluting the rollup view. |
| `e2e-pwa` (continue-on-error, flaky per INFRA-1332) | **flake-quarantined** — its result is "flake_observed" not pass/fail | Aggregator routes known-flake gates to a quarantine bucket whose failure does not block. Observable via the existing `e2e-pwa-advisory.yml` workflow. |
| `e2e-battle-sim`, `e2e-golden-path`, `tauri-cowork-e2e` | **disabled-on-PR** (already `if: false` per RESILIENT-016) | Aggregator does not poll for them; nightly workflow owns them. |
| `integration-test` (INFRA-849, continue-on-error) | **advisory** | Useful signal, not blocking. |
| `pr-hygiene` sub-steps (AC-coverage, PWA-parse, research-privacy with `\|\| true`) | **advisory** today; promote per INFRA-1869 ladder when calibrated | These are explicit `--warn-only` per their own design; aggregator surfaces them but does not block. |
| Stub-emit-under-real-name pattern (INFRA-2191) | **eliminated** | When the aggregator's decision rule treats "skipped because path-filter excluded code" as a first-class PASS reason, there is no need to spoof check-run names. |
| Workflow file failed-to-queue (INFRA-2200 class) | **NEW signal type the aggregator must define** | If `gh api repos/X/commits/SHA/check-runs` returns **no** check-runs for an expected workflow, aggregator emits "infrastructure_no_signal" instead of waiting forever or letting prior-SHA check-runs count. Operator sees this distinct from "PR failed CI" — and can fix the workflow file as a separate concern instead of admin-merging through unknown state. |
| Ruleset silent-open-required-check (INFRA-2201 class) | **NEW gate `fleet doctor` runs at PR open** | Aggregator design enforces: every context listed in the ruleset has an active workflow whose `name:` matches. INFRA-2201 already ships `chump fleet doctor` + a CI gate for this; META-131 adopts it as part of the contract. |
| Pre-commit hooks (16 of them) + pre-push (1) | **local first line; aggregator records they ran in `Pre-Push-Preflight-OK: <sha>` commit trailer** | When the trailer is present + CI confirms, aggregator can short-circuit some sub-checks (mirrors preflight-vs-CI parity discipline). Keeps local + CI signals jointly meaningful. |
| Auto-flip-on-merge (INFRA-2121) | **post-merge, unaffected** | Already handles the gap-registry-flip drift class; aggregator decision is upstream of it. |
| `dependabot-auto-merge.yml`, `pr-rescue.yml`, `queue-driver.yml`, cron jobs | **unaffected — operational daemons** | These keep the queue moving; aggregator design is orthogonal. |
| All 24 advisory workflows (cron, branch-protection-drift, audit-weekly, etc.) | **unaffected — surfaced where they live today** | Aggregator is about *the required-checks contract on `main`*, not the broader CI surface. |

### Decision rule for `verified` (first-pass sketch)

The aggregator job runs on `pull_request` + `merge_group`. Its decision rule (in roughly the same shape as the existing `test` rollup's classification, INFRA-1002):

1. **PASS** if every **required input** is `success` OR `skipped via path-filter (stub fired and is_path_filter_skip=true)`.
2. **PASS** if a required input is `cancelled` AND another required input is `failure` (cascade-cancel — root cause is the failure).
3. **FAIL with reason=PR_diff** if a required input is `failure` and the failure trace matches the PR diff (existing CI-summary classifier from INFRA-557 `src/ci_summary.rs`).
4. **FAIL with reason=infrastructure_no_signal** if a required input never emitted a check-run AND `gh api commits/SHA/check-runs` returns the workflow as missing — operator sees this distinct surface and fixes the workflow file (INFRA-2200 class).
5. **FAIL with reason=flake_observed** if the only failures are in flake-quarantined inputs (INFRA-1332 / INFRA-557 known-flake-list). Auto-rerun fires via existing `ci-flake-rerun.yml`.
6. **WAIT** if required inputs are still `in_progress`.

The aggregator's failure reasons get emitted to ambient (`kind=verified_fail`, `field=reason`) so the fleet's bot-merge / pr-rescue / paramedic logic can route per-class instead of treating all "red CI" identically.

### Branch protection migration

The minimum-disruption migration:

1. Ship `verified` aggregator as advisory (continue-on-error: true) on every PR. Soak 1-2 weeks. Validate it would have caught the bug classes in §5.
2. Add `verified` as a **second** required context alongside `test` + `audit` + `ACP smoke`. Both contracts hold; safety belt remains.
3. After 1 week of 100% agreement between `verified` and the 3 legacy contexts: remove the legacy 3, leaving `verified` as the sole required check.
4. Stub jobs (4 of them) become dead code at this point and can be deleted in a follow-up cleanup PR. INFRA-1143's stub pattern was a workaround for the old contract; `verified` makes it unnecessary.

### What META-131 does NOT need to change

- The 944 `test-*.sh` scripts. They keep firing in their existing jobs.
- The 24 workflow files (except adding `verified` and eventually removing 4 stubs).
- The pre-commit / pre-push hooks. They remain the local first line.
- `chump preflight` and its parity discipline (INFRA-2120 / INFRA-1867). The aggregator complements preflight, doesn't replace it.
- Ruleset 15133729 itself — just edit the `required_status_checks` list.

---

## §7. Sibling slices of META-131 this audit suggests

META-133 (this doc) is slice 1/N. The audit surfaces these natural follow-up slices:

| Sibling slice | Scope | Why |
|---|---|---|
| Design `verified` aggregator job (Rust + ci.yml step) | s | The actual code that implements the decision rule in §6. |
| Define ambient `kind=verified_fail` + reason enum | xs | The fleet's per-class routing needs the enum locked. |
| Migration runbook (advisory -> dual -> sole) | xs | Operator-facing 3-step procedure with rollback. |
| Stub-job deletion cleanup PR | xs | Follow-up after sole-required-check stabilizes. |
| `chump fleet doctor` ruleset-vs-workflow-name validation | xs | INFRA-2201 already ships this; verify META-131 adopts it. |
| `verified` aggregator preflight parity (INFRA-2120) | xs | Mirror the decision rule in `src/preflight.rs` so the same classification fires locally. |
| Bot-merge integration with `verified_fail` reasons | s | Make bot-merge route by reason instead of just polling state. |

Each is independently shippable. None require a "big-bang" rewrite.

---

## §8. Open questions for operator

These came up while writing this audit and would benefit from explicit operator decision before the `verified` aggregator slice ships:

1. **Stub-name-spoof retention?** INFRA-2191's choice to name `audit-stub` literally `audit` is a workaround for the `audit` ruleset context. Under the `verified` design we delete it — confirm the cleanup PR is in-scope.
2. **`ACP smoke` keep separate or fold into `verified`?** It's the most genuinely-orthogonal of the 3 required checks (wire-format vs. logic). Keeping it separate is operationally clearer; folding is conceptually cleaner. Pick one explicitly.
3. **Flake-quarantine list scope** — `e2e-pwa` is the obvious member, but `coverage` and `integration-test` also routinely fail in non-PR-causal ways. Decide which gates qualify before the rule fires.
4. **Migration timeline** — 1 week of dual-required is the safe default; 2 weeks if it lands during a holiday window. Operator picks.
5. **`Pre-Push-Preflight-OK:` commit-trailer recognition** — should `verified` actually short-circuit any sub-checks based on the trailer, or just record it for audit? Short-circuiting is faster but introduces a `--no-verify`-trailer-injection trust-boundary. Default: record-only, decide later.

---

## §9. Sources read for this audit

Files (paths relative to repo root, citation links open in the docs/strategy worktree):

- `.github/workflows/ci.yml` (2,182 lines) — full inventory of jobs §2 above
- `.github/workflows/` other 23 yml files — §3 inventory
- `scripts/git-hooks/pre-commit` (2,021 lines) + `pre-commit-*.sh` siblings + `pre-push` (1,291 lines) — §4 hook inventory
- `gh api repos/repairman29/chump/branches/main/protection` — §1 legacy required checks
- `gh api repos/repairman29/chump/rulesets/15133729` — §1 ruleset contexts + bypass actors
- [`docs/process/CI_GATES_INVENTORY.md`](../process/CI_GATES_INVENTORY.md) (113 lines, INFRA-1762) — Tier A/B/C/D taxonomy of mirrored-locally state
- [`docs/process/CI_PREFLIGHT_PARITY.md`](../process/CI_PREFLIGHT_PARITY.md) (100 lines, META-071) — CI gate <-> preflight cross-reference
- [`docs/process/CI_REQUIRED_CHECKS_DESIGN.md`](../process/CI_REQUIRED_CHECKS_DESIGN.md) (204 lines) — design constraints for required checks post-2026-05-25 wedge
- [`docs/process/CI_GATE_PROMOTION_LOG.md`](../process/CI_GATE_PROMOTION_LOG.md) — append-only promotion ledger (INFRA-1869)
- [`docs/strategy/CI_REVIEW_2026-05-29.md`](./CI_REVIEW_2026-05-29.md) (201 lines) — 14-day failure catalog + 5 levers (37% of ships = CI-rot fixes)
- [`docs/gaps/INFRA-2200.yaml`](../gaps/INFRA-2200.yaml) — workflow-file silent break post-mortem
- [`docs/gaps/INFRA-2201.yaml`](../gaps/INFRA-2201.yaml) (resolved #2780) — silent open required-checks
- [`docs/gaps/INFRA-2191.yaml`](../gaps/INFRA-2191.yaml) (resolved #2741) — audit-stub emits as `audit`
- 14-day commit log scan (`git log --oneline --since='2026-05-24'`) — concrete wedge/unwedge/bypass evidence in §5

Counts at audit time:
- 24 workflow files in `.github/workflows/`
- 3 required-status-check contexts
- 4 stub jobs in ci.yml
- 944 `scripts/ci/test-*.sh` scripts
- 16 pre-commit hook siblings (1 orchestrator + 15 siblings)
- 1 pre-push hook (1291 lines)
- ~70% admin-merge bypass rate this week (operator-reported, evidence triangulated from `bot_merge_bypassed` ambient + `--admin` in commit subjects)
