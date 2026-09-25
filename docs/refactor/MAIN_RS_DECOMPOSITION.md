# src/main.rs decomposition — migration plan (INFRA-1687 slice)

**Status:** planning artifact. Names every subcommand currently dispatched
from `src/main.rs` and proposes a follow-up-migration owner per group, so
`chump gap decompose` has real per-owner slices to generate when INFRA-1687
is claimed. Per the two-phase decomposition doctrine
([`CLAUDE.md` → Two-phase decomposition](../../CLAUDE.md)), this document is
the *rough shape*, not pre-filed sub-gaps — sub-gaps get generated against
the current codebase at claim time.

## Why this exists

`src/main.rs` is **22,052 lines** as of this writing (2026-09-25), dispatching
subcommands through a long chain of
`if args.get(1).map(String::as_str) == Some("<name>") { ... }` blocks (plus a
handful of `match args[1].as_str()` alias expansions at the top). Every PR
that touches an unrelated subcommand still risks a lease collision on this
one file — the original motivating pain for INFRA-1687
(`docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md`). The target end-state
(INFRA-1748 pilot, still open) is inventory/linkme-style subcommand
self-registration: each subcommand owns `src/cmd/<name>.rs` and main.rs
shrinks to a thin router.

This doc is the map that makes that migration tractable: one row per
subcommand, its current anchor line in `src/main.rs`, the proposed target
module, and a proposed migration-owner lane. Backward compatibility during
the migration is verified by
[`scripts/ci/test-cli-surface-baseline.sh`](../../scripts/ci/test-cli-surface-baseline.sh)
(created alongside this doc, INFRA-5587) — it snapshots `--help` output and a
handful of baseline command invocations so any subcommand migration that
silently changes CLI surface is caught immediately.

## How to read the table

- **Anchor line** — the line in `src/main.rs` (as of the commit that shipped
  this doc) where the subcommand's dispatch block starts. Anchors drift as
  the file changes; treat them as a starting point for `grep -n
  '"<name>"' src/main.rs`, not a permanent citation.
- **Target module** — proposed destination under `src/cmd/` once
  self-registration lands (INFRA-1748 pattern).
- **Migration owner (lane)** — the curator lane (see `.claude/agents/`) whose
  domain knowledge best fits verifying the ported behavior. This is a
  *proposal* for `chump gap decompose` to assign per-slice ownership, not an
  active claim — no curator should treat this table as a standing lease.
- **Documented?** — whether the subcommand appears in `print_help()`
  (`src/main.rs:1022`). Commands marked "no" are reachable but undocumented
  in top-level `--help`; several are early/internal (git-guard,
  wip-snapshot) and were never meant for the printed surface, but a few
  (e.g. `inventory`, `contract-scan`, `roadmap-from-vision`) look like
  documentation drift worth a follow-up.

## Gap management — core CLI lifecycle (owner: INFRA core, no curator lane)

These subcommands are the foundational gap/claim/ship lifecycle. They are
load-bearing for every other lane, so migration should be owned by whoever
claims INFRA-1687 directly rather than delegated to a domain curator.

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `gap` | 9785 | `src/cmd/gap.rs` | yes |
| `claim` | 2194 | `src/cmd/claim.rs` | yes |
| `ship` (alias `s`, expands to `gap ship`) | 2114 | `src/cmd/gap.rs` | yes |
| `init` | 2154 | `src/cmd/init.rs` | yes |
| `preflight` | 2265 | `src/cmd/preflight.rs` | yes |
| `pe-suite` | 2307 | `src/cmd/pe_suite.rs` | yes |
| `plan` | 4946 | `src/cmd/plan.rs` | no (referenced via `chump plan --help`) |

## Fleet + orchestration (owner lane: `orchestrator`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `fleet` (alias `f`) | 6261 | `src/cmd/fleet.rs` | yes |
| `dispatch` (alias `d`) | 6137 | `src/cmd/dispatch.rs` | yes |
| `brain` | 17691 | `src/cmd/brain.rs` | yes |
| `orchestrate` | 19457 | `src/cmd/orchestrate.rs` | yes |
| `resume` | 2597 | `src/cmd/resume.rs` | no |
| `farmer` | 1608 | `src/cmd/farmer.rs` | no |
| `start` | 19365 | `src/cmd/start.rs` | no |

## Analytics + observability (owner lane: `observability`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `health` (alias `h`) | 3286 | `src/cmd/health.rs` | yes |
| `health-digest` | 5668 | `src/cmd/health.rs` | yes |
| `session-summary` | 2299 | `src/cmd/session.rs` | yes |
| `fleet-status` | 4925 | `src/cmd/fleet_status.rs` | yes |
| `fleet-velocity` | 4953 | `src/cmd/fleet_status.rs` | yes |
| `waste-tally` | 5264 | `src/cmd/waste_tally.rs` | yes |
| `ship-quality` | 5725 | `src/cmd/ship_quality.rs` | yes |
| `roadmap-status` | 4778 | `src/cmd/roadmap.rs` | yes |
| `roadmap-pillar-score` | 4873 | `src/cmd/roadmap.rs` | yes |
| `mission-grade` | 3232 | `src/cmd/mission_grade.rs` | yes |
| `lesson-grade` | 2804 | `src/cmd/lesson_grade.rs` | yes |
| `ci-summary` | 5780 | `src/cmd/ci_summary.rs` | yes |
| `verify` | 2281 | `src/cmd/verify.rs` | yes |
| `classify-failure` | 5844 | `src/cmd/classify_failure.rs` | yes |
| `kpi` | 17390 | `src/cmd/kpi.rs` | yes |
| `claim-lint` | 2504 | `src/cmd/claim_lint.rs` | yes |
| `cost-watch` (alias `cs`) | 17273 | `src/cmd/cost.rs` | yes |
| `cost` | 17200 | `src/cmd/cost.rs` | yes |
| `cost-check` | 17332 | `src/cmd/cost.rs` | no |
| `pr-coupling-cost` | 5368 | `src/cmd/pr_coupling_cost.rs` | yes |
| `cascade` | 6039 | `src/cmd/cascade.rs` | yes |
| `funnel` | 2173 | `src/cmd/funnel.rs` | yes |
| `dashboard` | 6017 | `src/cmd/dashboard.rs` | yes |
| `ambient-rotate` | 4901 | `src/cmd/ambient.rs` | no |

## Session / reflection / PR rescue (owner lane: `shepherd`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `session-track` | 5854 | `src/cmd/session.rs` | yes |
| `session-export` | 5916 | `src/cmd/session.rs` | yes |
| `session-resume` | 5970 | `src/cmd/session.rs` | yes |
| `reflect-delta` | 5993 | `src/cmd/reflect_delta.rs` | yes |
| `rebase-stuck` | 5769 | `src/cmd/rebase_stuck.rs` | yes |
| `pr` (fix-clippy, triage) | 5411 | `src/cmd/pr.rs` | yes |
| `pr-rescue` | 2706 | `src/cmd/pr_rescue.rs` | no |
| `self-rescue-loop` | 2290 | `src/cmd/self_rescue_loop.rs` | no |
| `paramedic` | 5550 | `src/cmd/paramedic.rs` | no |
| `scrap` | 2626 | `src/cmd/scrap.rs` | no |
| `sibling-status` | 2494 | `src/cmd/sibling_status.rs` | no |

## CI / gate discipline (owner lane: `ci-audit`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `git-guard` | 1489 | `src/cmd/git_guard.rs` | no |
| `wip-snapshot` | 1495 | `src/cmd/wip_snapshot.rs` | no |
| `verify-claim-branch` | 1506 | `src/cmd/verify_claim_branch.rs` | no |
| `self-check-staleness` | 1536 | `src/cmd/self_check_staleness.rs` | yes |
| `ci-lesson` | 1676 | `src/cmd/ci_lesson.rs` | no |

## A2A / coordination (owner lane: `handoff`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `ambient` | 1955 | `src/cmd/ambient.rs` | no |
| `curator` | 2004 | `src/cmd/curator.rs` | no |
| `vote` | 2401 | `src/cmd/consensus.rs` | no |
| `consensus` | 2412 | `src/cmd/consensus.rs` | no |
| `consensus-tally` | 2473 | `src/cmd/consensus.rs` | no |
| `voice` | 2423 | `src/cmd/voice.rs` | no |
| `intervention-watchdog` | 2438 | `src/cmd/intervention_watchdog.rs` | no |
| `contract-scan` | 2526 | `src/cmd/contract_scan.rs` | no |

## External repo / arsenal (owner lane: `harvester` / `target`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `ingest` | 2340 | `src/cmd/ingest.rs` | no |
| `ingest-preflight` | 2347 | `src/cmd/ingest.rs` | no |
| `scan` | 2356 | `src/cmd/scan.rs` | no |
| `cartograph` | 2365 | `src/cmd/cartograph.rs` | no |
| `evangelize` | 2374 | `src/cmd/evangelize.rs` | no |
| `harvest` | 2383 | `src/cmd/harvest.rs` | no |
| `systematize` | 2392 | `src/cmd/systematize.rs` | no |
| `roadmap-from-vision` | 2559 | `src/cmd/roadmap.rs` | no |
| `inspect` | 2575 | `src/cmd/inspect.rs` | no |
| `bootstrap` | 2537 | `src/cmd/bootstrap.rs` | yes |
| `outcome` | 3798 | `src/cmd/outcome.rs` | no |
| `repos` | 4517 | `src/cmd/repos.rs` | no |
| `skill` | 3383 | `src/cmd/skill.rs` | no |
| `intake` | 3766 | `src/cmd/intake.rs` | no |
| `inventory` | 2515 | `src/cmd/inventory.rs` | no |

## Demo / eval (owner lane: `target`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `demo` | 2455 | `src/cmd/demo.rs` | no |
| `bench` | 2445 | `src/cmd/bench.rs` | no |
| `swe` | 2550 | `src/cmd/swe.rs` | no |
| `trek` | 19410 | `src/cmd/trek.rs` | no |
| `review` | 19623 | `src/cmd/review.rs` | no |
| `gen` | 19578 | `src/cmd/gen.rs` | yes |

## Operator-facing / external collab (owner lane: `external-collab`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `content-bots` | 3652 | `src/cmd/content_bots.rs` | no |
| `audit` | 2854 | `src/cmd/audit.rs` | no |

## Substrate / ops (owner lane: `infra-watcher`)

| Subcommand | Anchor line | Target module | Documented? |
|---|---|---|---|
| `cron` | 2273 | `src/cmd/cron.rs` | yes (referenced elsewhere) |
| `disk` | 2654 | `src/cmd/disk.rs` | no |
| `upgrade` | 3264 | `src/cmd/upgrade.rs` | no |
| `completion` | 2768 | `src/cmd/completion.rs` | no |
| `config` | 2465 | `src/cmd/config.rs` | no |
| `provider` | 1622 | `src/cmd/provider.rs` | no |
| `provider-chain` | 1778 | `src/cmd/provider.rs` | no |
| `llm-complete` | 1728 | `src/cmd/llm_complete.rs` | no |
| `agent-run` | 1842 | `src/cmd/agent_run.rs` | no |

## Server modes (out of scope for this migration)

`--web`, `--acp`, `--discord`, `--telegram`, `--slack`, `--rpc` are
long-running server flags parsed earlier in `main()`, not
`args.get(1)`-dispatched subcommands. They stay out of the `src/cmd/<name>.rs`
self-registration pattern (INFRA-1748) — they're server entrypoints, not CLI
verbs — and are excluded from this table on purpose.

## Documentation drift found while compiling this table

The following are advertised in `print_help()` but have no `args.get(1) ==
Some("<name>")` dispatch found in `src/main.rs` at time of writing:
`onboard`, `improve`, `external verify-merge`. These likely route through
the generic front-door/LLM-prompt fallback (`src/front_door.rs`) rather than
a dedicated dispatch block, or have drifted out of sync with the help text.
Worth a follow-up gap to either wire them up properly or fix the help text —
filed separately, not in scope for INFRA-5587.

## Migration sequencing (informational, not prescriptive)

Per INFRA-1748 (open, P1), the pilot already targets `chump fanout` (anchor
5007) and `chump rollup` (anchor 4982) as the first port. This table extends
that pilot's proof point to the rest of the surface so `chump gap decompose
INFRA-1687` has a full per-lane slice list once the pilot pattern is proven.
Suggested order once the pilot lands:

1. **Gap management core** (`gap`, `claim`, `ship`) — highest edit frequency,
   highest payoff, but also highest risk; do this only after the pilot
   pattern has shipped and been stable for a full week.
2. **Analytics / observability** — largest single group (24 subcommands),
   mostly read-only reporting commands with low interdependency; good
   parallelization target for multiple lane owners at once.
3. **Everything else** — lower edit frequency; migrate opportunistically as
   each subcommand's owner lane touches it anyway.

## Backward-compat verification

Every step in this migration must pass
`scripts/ci/test-cli-surface-baseline.sh` unchanged — see that script for
the exact baseline commands and expected invariants (exit code 0,
`Usage:`/`USAGE` present in `--help` output, top-level `print_help()`
coverage). A subcommand port is only "done" when its behavior is
byte-identical for the baseline invocations before and after the move.
