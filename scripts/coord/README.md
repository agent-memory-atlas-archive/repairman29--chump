# scripts/coord/ — Coordination Entry Points

All gap lifecycle, fleet coordination, and PR management scripts live here.
See [`scripts/README.md`](../README.md) for the broader taxonomy.

---

## Quick decision guide

| Goal | Use this |
|---|---|
| Claim a gap | `chump claim <ID>` (preferred) or `gap-claim.sh <ID>` |
| Check a gap is pickable | `gap-preflight.sh <ID>` |
| Commit work | `chump-commit.sh <files> -m "msg"` |
| Ship a gap | `bot-merge.sh --gap <ID> --auto-merge` |
| Watch a PR recover from DIRTY | `pr-watch.sh <PR#>` (or pr-watch-shepherd.sh automatically) |
| Repair gap store drift | `gap-doctor.py` (detect + patch) |
| Refill the gap queue automatically | `gap-gardener.py` (hourly cron) |
| Propose new gaps from docs | `gap-architect.py` (LLM sprint planner) |
| Glance at ambient stream | `chump-ambient-glance.sh` |
| Inject ambient context (CI/hook) | `ambient-context-inject.sh` |
| End a session + release lease | `ambient-session-end.sh` |

---

## gap-doctor vs gap-gardener vs gap-architect

These three are often confused because all three touch the gap store:

| Tool | Who runs it | When | What it does |
|---|---|---|---|
| **`gap-doctor.py`** | Agent or operator | On demand, after merge conflicts or import bugs | Detects and repairs drift between `state.db` and `docs/gaps/*.yaml`. Fixes mismatched status, double-encoded `depends_on`, ghost entries. Run when `chump gap list` shows stale data. |
| **`gap-doctor-all.sh`** | Operator or CI | After large batch imports | Wrapper that runs `gap-doctor.py` across all gaps and summarizes the repair log. |
| **`gap-gardener.py`** | Launchd cron (hourly) | When queue depth is low | Seeds new gaps from strategic docs when `open count < MIN_QUEUE_DEPTH`. Not for interactive use — it's an autonomous refill loop. |
| **`gap-architect.py`** | Agent or operator | When sprint planning | LLM-driven: reads roadmap/docs, calls Claude, generates 20+ concrete gaps. Use to bootstrap a new domain or after a synthesis. |

**Rule of thumb**: drift problems → `gap-doctor.py`, empty queue → `gap-gardener.py`, new batch → `gap-architect.py`.

---

## Full script reference

### Gap lifecycle

| Script | Purpose |
|---|---|
| `gap-claim.sh` | Write a lease file for a gap; called by `chump claim` |
| `gap-preflight.sh` | Check gap is open, unclaimed, no stale PR; exits 1 if blocked |
| `gap-reserve.sh` | Reserve a new gap ID (wrapper around `chump gap reserve`) |
| `gap-doctor.py` | Detect and repair state.db ↔ YAML drift |
| `gap-doctor-all.sh` | Run gap-doctor.py across all gaps |
| `gap-doctor-backfill-closed-pr.sh` | Backfill `closed_pr` field for gaps closed without `chump gap ship` |
| `gap-normalize-domains.sh` | Normalize domain prefix casing in gap IDs |
| `gap-store-prototype.sh` | Prototype new gap store features; not for production |
| `gap-gardener.py` | Hourly auto-filler when queue is sparse |
| `gap-architect.py` | LLM sprint planner; generates batches of new gaps from docs |
| `gap-doctor-reconcile.py` | Reconcile state.db with state.sql after merge conflicts |
| `check-gaps-integrity.py` | Read-only integrity audit (no mutations); good for CI spot checks |
| `resolve-gaps-conflict.py` | 3-way merge driver for `.chump/state.sql` conflicts |
| `close-superseded-prs.sh` | INFRA-994: auto-close open PRs for a gap that shipped via another path; invoked by `chump gap ship` |
| `backfill-ghost-gaps.sh` | Find gaps whose PR merged but status is still `open`; batch-close |
| `ghost-gap-reaper.sh` | Delete lease files for sessions that no longer exist |

### Shipping and PRs

| Script | Purpose |
|---|---|
| `bot-merge.sh` | **Canonical ship pipeline**: fmt + clippy + push + PR + auto-merge + gap-ship-fatal |
| `chump-commit.sh` | Commit with cadence tracking; use instead of bare `git commit` |
| `check-spec-on-spec.sh` | Guard against arming auto-merge when a competing speculative PR is already armed (INFRA-684) |
| `pr-watch.sh` | Watch a PR, rebase + re-arm when it goes DIRTY after auto-merge armed |
| `pr-watch-shepherd.sh` | → moved to `scripts/coord/` from `scripts/ops/`; launchd-managed shepherd for all DIRTY-after-arm PRs |
| `archive-superseded-branch.sh` | Delete branches for closed/superseded PRs |
| `worktree-prune.sh` | Remove stale linked worktrees |
| `check-gap-status-flip.sh` | Detect when a gap flips from open→done without going through `chump gap ship` |
| `bounced-pr-detector.sh` | Find PRs that merged but left the gap in status:open |
| `_bounced_pr_classifier.py` | Helper: classify why a PR bounced (conflict/stale/other) |
| `pr-title-drift-detector.sh` | Alert when PR title diverges from gap title |
| `bot-shipped-audit.sh` | Audit which shipped PRs went through bot-merge.sh vs manual path |
| `bot-merge-run-timed.py` | Helper: run bot-merge with a timeout; used by orchestrate.rs |

### Ambient stream and observability

| Script | Purpose |
|---|---|
| `ambient-context-inject.sh` | SessionStart/PreToolUse hook: inject ambient digest as system context (FLEET-022) |
| `ambient-session-end.sh` | Stop hook: emit `session_end` + release lease |
| `chump-ambient-glance.sh` | Quick human-readable tail of the last N ambient events |
| `ci-failure-digest.sh` | Summarize recent CI failures for triage |
| `harvest-synthesis-lessons.sh` | Extract lessons from synthesis docs → `chump_improvement_targets` |
| `recurring-gap-pattern-detector.sh` | Detect gap domains or error classes that keep recurring |
| `log-chump-cli.sh` | Structured logging wrapper for `chump` CLI calls |

### Utility

| Script | Purpose |
|---|---|
| `broadcast.sh` | Send a message to all active sessions via ambient stream |
| `claude-retry.sh` | Retry `claude -p` with backoff on transient failures |
| `code-reviewer-agent.sh` | Run the code-reviewer subagent against a PR |
| `chump-decomposition-propose.sh` | Propose a decomposition of a large gap into sub-gaps |
| `demo-pr-worktree.sh` | Demo script for showing the worktree + PR flow |
| `ensure-chump-repo.sh` | Assert we are inside the Chump repo; abort otherwise |
| `musher.sh` / `musher.py` | Batch-apply a set of gap updates; rarely used |
| `queue-driver.sh` | Drive the gap pick loop (used by worker.sh in dispatch/) |
| `check-worktree-config.sh` | Verify worktree config.worktree is healthy (INFRA-810) |

## Cache lib (`lib/github_cache.sh`) — INFRA-1081 / INFRA-1107

Local SQLite cache at `.chump/github_cache.db` populated by the webhook
receiver. **Every script that reads PR state should source this lib and
use cache_lookup_* helpers first; fall back to direct `gh api` only on
miss.** Cache miss is one REST call (cheap, REST core bucket stays
healthy when GraphQL exhausts).

| Function | Returns | Replaces |
|---|---|---|
| `cache_lookup_pr <number>` | JSON of `gh api repos/X/pulls/N` shape | `gh pr view --json …` / `gh api …/pulls/N` |
| `cache_query_behind_prs` | newline-separated PR numbers (mergeable_state=BEHIND, AM armed) | `gh pr list --json mergeStateStatus -q …` |
| `cache_lookup_checks <head_sha>` | tab-separated `name\tstatus\tconclusion` per check | `gh api repos/X/commits/<sha>/check-runs` |

```bash
source "$(dirname "$0")/lib/github_cache.sh"
PR_META="$(cache_lookup_pr 1234)"          # 0 API calls if cache warm
BEHIND="$(cache_query_behind_prs)"         # 0 API calls always (sqlite)
CHECKS="$(cache_lookup_checks "$sha")"     # 0 API calls if INFRA-1107 cache has the SHA
```

**Already-migrated consumers:**
- `queue-driver.sh` BEHIND scan (INFRA-1081)
- `chump-ambient-glance.sh --check-prs` overlap scan (INFRA-1108)
- `pr-rescue.sh` per-PR meta loop (INFRA-1109)

**Pending consumers** (open gaps): `bot-merge.sh` per-PR check-runs
(INFRA-1130), `ghost-gap-reaper.sh` and other N+1 callers (INFRA-1082).

**Operator setup** (one-time, see `scripts/setup/install-webhook-receiver-launchd.sh`):
GitHub webhook → smee.io → local Python receiver → SQLite cache. The
`com.chump.github-cache-reconcile.plist` LaunchAgent reconciles every
5 min to catch missed deliveries (INFRA-1105).

## Auth-tier map (INFRA-1078)

See [`AUTH_AUDIT.md`](AUTH_AUDIT.md) (regenerate via
`scripts/ci/auth-tier-audit.sh`). As of last audit: 7 APP_TOKEN /
218 PAT / 27 GITHUB_TOKEN callsites — 218 PAT callsites represent a
2.5× quota migration opportunity. Each is a follow-up gap candidate.

## Ephemeral vs permanent branches in bot-merge.sh

bot-merge.sh has **no separate staging branches** — there is exactly one
branch per gap (`chump/<gap>-claim`) and it is the PR head. The
INFRA-472 auto-stage step (around lines 1002-1029) commits any uncommitted
scoped edits onto that same branch with the subject prefix
`auto: bot-merge pre-rebase staging`. These commits are PR commits, not
staging branches — there is no separate ref to clean up.

**INFRA-997 guard:** if every commit on the gap-claim branch since
`origin/main` has that exact auto-staging subject (i.e., the operator
ran bot-merge with no real gap work), `gh pr create` is refused with
exit code 16 and `kind=staging_only_pr_blocked` is emitted to
ambient.jsonl. The original waste case (PR #1655, 2026-05-13) shipped
exactly this pattern as an empty PR; this guard prevents recurrence.
Bypass when intentional: `CHUMP_ALLOW_STAGING_ONLY_PR=1`.

## Required-check stub pattern (INFRA-1143)

GitHub Actions does not distinguish "skipped" from "failed" in branch
protection. If a required status check skips (because the path filter says
no code changed), the merge is blocked forever.

The **synthetic-green stub pattern** avoids this:

```
# For each required check <job>:
<job>:                # real job, gated by path filter
  if: needs.changes.outputs.code == 'true' || push || merge_group
  ...

<job>-stub:           # fast stub, runs when real job is skipped
  if: needs.changes.outputs.code != 'true' && pull_request
  steps:
    - run: echo "<job> skipped — no code changes. Stub satisfies branch protection."

<job>-required:       # rollup — branch protection points at THIS name
  needs: [<job>, <job>-stub]
  if: always()
  steps:
    - run: |
        real="${{ needs.<job>.result }}"
        stub="${{ needs.<job>-stub.result }}"
        if [[ "$real" == "success" || "$stub" == "success" ]]; then
          echo "PASS"
        elif [[ "$real" == "skipped" && "$stub" == "skipped" ]]; then
          echo "both skipped (push/merge_group — OK)"
        else
          exit 1
        fi
```

**Jobs with this pattern (as of INFRA-1143):**
- `clippy` / `clippy-stub` / `clippy-required`
- `cargo-test` / `cargo-test-stub` / `cargo-test-required`
- `fast-checks` / `fast-checks-stub` / `fast-checks-required`
- `audit` / `audit-stub` / `audit-required`

**Branch protection migration (operator action):**
1. Merge INFRA-1143 PR (stubs + rollups land in main).
2. Admin: add `clippy-required`, `cargo-test-required`, `fast-checks-required`,
   `audit-required` to branch protection required status checks.
3. Admin: remove old `test` and `audit` required checks (keep overlap if
   open PRs need both).
4. INFRA-1142 (follow-up): narrow the `code` filter to Rust-only paths.

**Adding a new required check:** use the `<job>-stub` + `<job>-required` template
above. Never add a conditional job directly to branch protection without a stub.

## Branch hygiene (INFRA-1058)

### Automatic cleanup (recommended)
Enable "Automatically delete head branches" in:
  GitHub repo → Settings → General → Pull Requests

When enabled, GitHub auto-deletes the head branch after every squash-merge.
This covers all new merges; it does NOT backfill historical refs.

### Manual sweep via branch-reaper.sh
For branches whose PRs merged before the setting was enabled:

```bash
# Dry-run (safe, default): shows what would be pruned
scripts/coord/branch-reaper.sh

# Actually prune (requires --act flag):
scripts/coord/branch-reaper.sh --act

# Only prune branches closed > 14 days ago:
scripts/coord/branch-reaper.sh --act --min-age-days 14

# Skip specific branches:
scripts/coord/branch-reaper.sh --act --keep-list my-feature,wip/research
```

Protected branches (never pruned): `main`, `master`, `develop`, `staging`,
`production`, `release/*`, `gh-readonly-queue/*`, `release-plz-*`.

Emits `kind=branch_reaper_pruned` to `ambient.jsonl` per deletion.

## `chump-coord assign` — delta publish, not a full-backlog firehose (ZERO-WASTE-003)

`chump-coord assign` (FLEET-034, `crates/chump-coord/src/assign.rs`) polls
`state.db` every `poll_interval` and publishes `WorkEnvelope`s to
`chump.work.<priority>.<class>.<machine>` for open+unclaimed gaps.

**It is a delta publisher, not a full-backlog re-broadcast.** Each cycle
computes a routing fingerprint (priority + class + machine + replicas) per
open+unclaimed gap and diffs it against the previous cycle's `DeltaState`
(in-memory, process-lifetime). Only gaps that are **new** (never seen),
**changed** (fingerprint differs — e.g. priority bump), or **newly
unclaimed** get published; an unchanged backlog publishes ~0 envelopes per
cycle. A gap that gets claimed between cycles simply drops out of the next
`DeltaState` snapshot — no tombstone envelope is published for it.

- **First cycle after daemon start always republishes the full open set
  once.** `DeltaState` starts empty on every process start (it is not
  persisted to disk), so every open+unclaimed gap looks "new" on cycle 1 —
  this is the intentional fail-open behavior, not a bug or a missing-state
  error path.
- **Broker-down path is unchanged (FLEET-034):** if NATS is unreachable at
  startup, `assign` logs the condition and exits `0` so a supervisor can
  restart it; workers fall back to the existing pull loop.
- Consumers that previously relied on every open gap being re-announced
  every `poll_interval` (e.g. for a crude periodic refresh) must switch to
  treating `chump.work.>` as an edge-triggered change feed, not a
  level-triggered snapshot — cross-check `state.db` directly for full state.
