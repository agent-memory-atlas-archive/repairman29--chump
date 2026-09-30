# scripts/ — Taxonomy, Entry Points, and Canonical Tools

This directory holds every operational script in Chump. Scripts are grouped
by role; the table below is your navigation map.

---

## Directory taxonomy

| Directory | Role | When to use |
|---|---|---|
| [`coord/`](#coord) | Gap lifecycle, fleet coordination | Claiming, committing, shipping, merging gaps |
| [`ci/`](#ci) | CI guard tests | Fast-checks and fixture smoke tests run in CI |
| [`ops/`](#ops) | Long-running daemons and reapers | Auto-recovery, watchdogs, background sweepers |
| [`dispatch/`](#dispatch) | Fleet worker management | Launching, monitoring, and restarting the worker fleet |
| [`dev/`](#dev) | Developer tools | Ambient stream, local observability, debug helpers |
| [`setup/`](#setup) | One-time or idempotent installers | Hooks, launchd plists, environment bootstrap |
| [`git-hooks/`](#git-hooks) | Git lifecycle guards | Pre-commit, pre-push guards installed via `install-hooks.sh` |
| [`lib/`](#lib) | Shared shell libraries | Sourced by other scripts; not invoked directly |
| [`overnight/`](#overnight) | Scheduled research/eval tasks | Nightly cron jobs; run by launchd agents |
| [`eval/`](#eval) | Model and fleet evaluation harnesses | Research lane tests, A/B runners, eval fixtures |

Less-used directories (small scope):

| Directory | Role |
|---|---|
| `ab-harness/` | A/B test scaffold for model comparisons |
| `audit/` | Spot-audit scripts for PR diff, gap, and lesson quality |
| `demo/` | Demo scripts for showing Chump to new users |
| `discord/` | Discord bot helper scripts |
| `git/` | Low-level git utilities |
| `plists/` | Raw launchd plist fragments (consumed by `setup/`) |
| `qa/` | Manual QA checklists and scripts |
| `release/` | `cargo publish` orchestration ([owner + manual-run note](./release/README.md)) |
| `archived/` | Retired scripts kept for history/reference, no active callers ([`spike/`](./archived/spike/), [`demo/`](./archived/demo/), [`eval/`](./archived/eval/)) |

---

## Canonical tool per task

| Task | Use this | Notes |
|---|---|---|
| **Claim a gap** | `chump claim <GAP-ID>` | Canonical: atomic fetch + verify + worktree + lease |
| | `scripts/coord/gap-claim.sh <GAP-ID>` | Fallback when `chump` binary is unavailable |
| **File a new gap** | `chump gap reserve --domain X --title "..."` | Canonical; prevents ID collisions |
| **Commit work** | `scripts/coord/chump-commit.sh <files> -m "msg"` | Respects commit cadence; do not use bare `git commit` |
| **Ship a gap** | `scripts/coord/bot-merge.sh --gap <ID> --auto-merge` | Canonical; wires gap-ship-fatal + auto-close |
| **Check gap status** | `chump gap show <ID>` | Reads state.db |
| **List open gaps** | `chump gap list --status open` | Canonical source of truth |
| **Run preflight** | `scripts/coord/gap-preflight.sh <GAP-ID>` | Run before every claim; exits 1 if not pickable |
| **Monitor fleet** | `scripts/dispatch/fleet-status.sh` | Ship rate, agent health |
| **Fleet brief** | `scripts/dispatch/fleet-brief.sh` | 24h summary; shown at session start |
| **Start fleet** | `scripts/dispatch/run-fleet.sh` | Launches N workers |
| **Restart fleet** | `scripts/dispatch/fleet-restart.sh` | Safe restart with cooldown |
| **Watch ambient** | `scripts/dev/ambient-watch.sh` | Tail ambient.jsonl with formatting |
| **Rebuild capabilities registry** | `scripts/dev/build-capabilities-registry.sh` | Canonical source for `docs/CAPABILITIES_REGISTRY.json` (Quartermaster artifact, INFRA-1729) |
| **Generate registry for foreign repo** | `scripts/ops/generate-capabilities-registry.sh <repo-path>` | Column A `chump ingest` wrapper; writes `<repo-path>/docs/CAPABILITIES_REGISTRY.json` |
| **Check capabilities freshness** | `scripts/ci/check-capabilities-freshness.sh` | Is the catalog stale? Loud `[STALE]` banner past 30d; `--strict` to block (CREDIBLE-240) |
| **Which provider fronts a tool** | `scripts/ops/capability-provider-join.sh` | Joins the capabilities registry to `privateer/charter.json` (CREDIBLE-240) |
| **Sweep for false-done gaps** | `scripts/ops/false-done-sweep.py --multi-close-only --json` | Flags `status:done` gaps whose closing PR shipped no implementation file (CREDIBLE-279); see module docstring for tiers |
| **Install hooks** | `scripts/setup/install-hooks.sh` | Idempotent; run after worktree add |
| **Install ambient** | `scripts/setup/install-ambient-hooks.sh` | SessionStart/PreToolUse hooks for matrix wiring |
| **Fix bare worktree** | `scripts/setup/fix-worktree-show-toplevel.sh` | Heals `core.bare=true` poison (INFRA-810) |

**Public-facing docs surface:** [`docs/PITCH.md`](../docs/PITCH.md) — the canonical external-reviewer doc (why Chump, who it is for, what is shipped). Start there for grant readers, collaborators, or Marcus design-review.

---

## `coord/` — Gap lifecycle and fleet coordination {#coord}

The most-used scripts in day-to-day operation.

| Script | Purpose |
|---|---|
| `bot-merge.sh` | **Canonical ship pipeline**: fmt + clippy + push + PR create + auto-merge arm + gap-ship-fatal + INFRA-154 auto-close |
| `gap-claim.sh` | Write a lease file; called by `chump claim` |
| `gap-preflight.sh` | Check a gap is pickable (open, unclaimed, no stale PR) |
| `chump-commit.sh` | Commit with cadence tracking and ambient event emit |
| `check-spec-on-spec.sh` | INFRA-684: guard against arming auto-merge when a competing spec already has it armed |
| `pr-watch.sh` | INFRA-190: watch a PR, rebase + re-arm when it goes DIRTY after auto-merge |
| `pr-watch-shepherd.sh` | INFRA-354: launchd-managed shepherd that runs pr-watch for all DIRTY-after-arm PRs |
| `ambient-context-inject.sh` | SessionStart/PreToolUse hook: inject ambient stream digest as system context |
| `ambient-session-end.sh` | Stop hook: emit session_end + release lease |
| `bounced-pr-detector.sh` | Detect PRs that merged but left gap status:open |
| `backfill-ghost-gaps.sh` | Repair gaps whose YAML is open but PR merged |
| `ci-failure-digest.sh` | Summarize CI failures for operator triage |

---

## `ci/` — CI guard tests {#ci}

Every `test-*.sh` file is a smoke test run in `fast-checks`. Add new tests here; call them from `.github/workflows/ci.yml`.

Selected tests:

| Script | What it guards |
|---|---|
| `test-gap-preflight-unregistered.sh` | INFRA-020: gap-preflight rejects unregistered IDs |
| `test-gap-claim-race.sh` | INFRA-403: claim exclusivity under race |
| `test-no-manual-ship-bypass.sh` | INFRA-719: pre-push blocks direct gap branch push |
| `test-bounced-pr-detector.sh` | INFRA-781: bounced-PR fixture |
| `test-precommit-strict-replay.sh` | INFRA-767: mirrors local pre-commit guards to CI |
| `test-worktree-show-toplevel.sh` | INFRA-810: core.bare fix for linked worktrees |
| `test-lint-handoff-comment.sh` | INFRA-769: handoff comment format linter |
| `test-speculative-on-speculative-guard.sh` | INFRA-684: spec-on-spec arm block |
| `test-path-filter-allowlist.sh` | INFRA-682: CI path-filter coverage guard |
| `precommit-strict-replay.sh` | Replays pre-commit checks in CI (not a test script) |

---

## `ops/` — Daemons and reapers {#ops}

Long-running or cron-scheduled background processes. Most are managed via launchd plists installed by `setup/`.

| Script | Purpose |
|---|---|
| `pr-watch-shepherd.sh` | → moved to `coord/` (INFRA-354) |
| `auto-arm-sweeper.sh` | Re-arm PRs whose auto-merge was unintentionally disarmed |
| `ci-flake-rerun.sh` | Auto-rerun known-flaky CI checks |
| `active-target-reaper.sh` | Kill stale active-target leases |
| `disk-pressure-watchdog.sh` | Alert when disk is near capacity |
| `reaper-heartbeat-watchdog.sh` | Monitor heartbeat files; alert on silence |
| `stale-branch-reaper.sh` | Delete merged branches older than N days |
| `stale-gap-lock-reaper.sh` | Expire gap lease files past TTL |
| `stale-pr-reaper.sh` | Close PRs that have been superseded |
| `stuck-pr-filer.sh` | File a gap when a PR is stuck >4h with no activity |

### Fleet garbage collection (INFRA-974 / INFRA-1038 disposition)

There is no `chump fleet gc` subcommand. Fleet "garbage" is collected by
three specialists that each run on their own launchd schedule:

| Garbage | Collector | Schedule |
|---|---|---|
| Stale linked worktrees | `chump fleet prune-worktrees --apply` via `com.chump.prune-worktrees.plist` | daily 03:00 |
| Expired `.chump-locks/` lease files + state.db rows | `scripts/ops/stale-gap-lock-reaper.sh --execute` via `com.chump.stale-gap-lock-reaper.plist` (INFRA-676/INFRA-1017) | every 5 min |
| `.chump-locks/ambient.jsonl` size | INFRA-941 in-process auto-rotate at 50 MB threshold | continuous |

If you want a single operator-friendly entry-point, alias your shell:
`alias chump-gc='chump fleet prune-worktrees --apply && bash scripts/ops/stale-gap-lock-reaper.sh --execute'`.

INFRA-974 closed as obsolete — the original ask ("scheduled `chump fleet gc`
every 30 min") is already covered by the three specialists above. A unified
subcommand would be operator-convenience-only and is left for a follow-up
gap if the three-call pattern becomes friction.

---

## `dispatch/` — Fleet worker management {#dispatch}

| Script | Purpose |
|---|---|
| `run-fleet.sh` | Launch N fleet workers (reads `FLEET_SIZE`, `FLEET_MODEL`) |
| `worker.sh` | Single worker: pick gap → claim → execute → ship loop |
| `fleet-status.sh` | Ship rate, in-flight agents, recent events |
| `fleet-brief.sh` | 60-second operator briefing (24h ships, pillar mix, stalls) |
| `fleet-restart.sh` | Graceful restart with cooldown |
| `fleet-autorestart-daemon.sh` | INFRA-611: daemon that restarts fleet on starve |
| `control.sh` | Send control signals to running fleet |

---

## `dev/` — Developer and observability tools {#dev}

| Script | Purpose |
|---|---|
| `ambient-watch.sh` | Live tail of ambient.jsonl with human formatting |
| `ambient-emit.sh` | Append a JSON event to ambient.jsonl |
| `ambient-query.sh` | Filter ambient.jsonl by kind/time |
| `ambient-rotate.sh` | Rotate ambient.jsonl (cap file size) |
| `bring-up-stack.sh` | Start inference stack (Ollama / vllm / mlx) for local LLM |

---

## `setup/` — Installers {#setup}

All scripts here are idempotent — safe to re-run.

| Script | Installs |
|---|---|
| `install-hooks.sh` | Git hooks (pre-commit, pre-push, post-commit) in every worktree |
| `install-ambient-hooks.sh` | Claude Code `settings.json` hooks for FLEET-019 matrix wiring |
| `install-merge-drivers.sh` | Custom merge drivers for state.sql / ci.yml |
| `fix-worktree-show-toplevel.sh` | Heals `core.bare=true` poison; run once on affected machines |
| `install-pr-watch-shepherd-launchd.sh` | PR-watch shepherd as launchd agent (every 10 min) |
| `install-mission-grade-launchd.sh` | Mission-grade auto-scorer as launchd agent (every 30 min) |
| `install-stale-gap-lock-reaper-launchd.sh` | Stale lease reaper as launchd agent |

---

## `git-hooks/` — Git lifecycle guards {#git-hooks}

Installed as symlinks into every worktree's `.git/hooks/` by `install-hooks.sh`.

| Hook | Guards |
|---|---|
| `pre-commit` | cargo fmt, shellcheck, event-registry, obs-budget, gap-divergence |
| `pre-push` | Gap-preflight, auto-merge-armed check, force-lease race, bot-merge required for new gap branches (INFRA-719) |
| `post-commit` | Ambient event emit (file_edit/commit) |
| `post-checkout` | Ambient event emit on branch switch |

---

## `lib/` — Shared shell libraries {#lib}

Source these in scripts that need canonical path resolution or retry logic. Do not invoke directly.

| File | Provides |
|---|---|
| `repo-paths.sh` | `REPO_ROOT`, `MAIN_REPO`, `LOCK_DIR` — handles main vs linked worktree |
| `resolve-main-worktree.sh` | `resolve_main_worktree()` — finds the main repo from any context |
| `chump-preflight.sh` | Auto-heal wedged `chump` binary before CLI calls |
| `heartbeat.sh` | `touch_heartbeat()` for reapers |

---

## `overnight/` — Scheduled research tasks {#overnight}

Run by launchd agents nightly. Not for interactive use.

| Script | Purpose |
|---|---|
| `nightly-research.sh` | Kick off research lane A/B runs while operator sleeps |
| `overnight-analysis.sh` | Aggregate eval results from the day |

---

## `eval/` — Evaluation harnesses {#eval}

Research and measurement infrastructure.

| Script | Purpose |
|---|---|
| `research-lane-a-smoke.sh` | RESEARCH-018: smoke test for lane A harness (no API); run in CI (`ci.yml` "Research Lane A smoke") |
| `eval-reflection-ab.sh` | EVAL-008: A/B accuracy comparison, heuristic vs. LLM reflection; reads `fixtures/reflection-episodes.json` by default |
| `fixtures/` | Data fixtures consumed by `eval/` scripts (e.g. `reflection-episodes.json`) |

Retired `run-study[1-5].sh` and `wedge-h1-smoke.sh` (no CI/script callers, single
historical commits) moved to [`scripts/archived/eval/`](./archived/eval/).
