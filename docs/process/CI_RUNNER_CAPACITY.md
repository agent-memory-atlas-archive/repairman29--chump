# CI Runner Capacity — hosted-runner starvation and what to do about it

> **Status:** operator-decision doc (CREDIBLE-1512). Presents the measured
> starvation, the three capacity options, and a recommendation. The job-count
> cuts in this gap (cargo-test 4→2 on PRs, audit per-lane shards, pwa e2e path-
> gating) are the *demand-side* half; this doc is the *supply-side* decision.

## The problem, measured

GitHub-hosted runner starvation is invisible to every status page: `ubuntu-latest`
jobs sit at `runner=none` for tens of minutes while `githubstatus.com` reads green.
Because branch protection runs with `strict=true` (see
`docs/baselines/branch-protection-main.json`), **every merge to `main` requeues
every armed PR** — so a burst of merges multiplies the queue against a fixed,
small pool.

Measured on 2026-10-17 (CREDIBLE-1512):

| Time (UTC) | Runs queued | Jobs running | ubuntu-latest pickup | GitHub status |
|---|---|---|---|---|
| 04:58Z | 22 | 1 | 20-40 min | clean |
| 12:38Z | 32 | 1-2 | 20-40 min | clean |
| ~13:11Z (`chump kpi report --ci-pickup`) | 62 | — | p95 543s (9m), max 1011s (16m), p50 0 | clean |

The `p50=0` while 62 runs are queued is **survivorship bias**: the jobs that
*completed* were the ones that got a runner fast; the starved jobs are still in
the queue and carry no `started_at` yet. So:

- **`ci_runs_queued` is the leading indicator** (queue depth right now).
- **`ci_pickup_latency_s` p95/max is the lagging confirmation** (how long jobs
  that eventually ran had to wait). The tail — p95 ≈ 9 min, max ≈ 16 min — is the
  real starvation signal; the median hides it.

### How to measure it yourself

```bash
scripts/ci/ci-pickup-collect.sh          # sample last 50 completed runs + live queue depth
chump kpi report --ci-pickup             # p50/p95 per UTC hour + ci_runs_queued
chump kpi report --ci-pickup --emit-if-starved   # also emit kind=ci_runner_starved when p50>10m
```

The collector (`gh api .../jobs`, `created_at` vs `started_at`) writes
`.chump/metrics/ci_pickup.jsonl` + `.chump/metrics/ci_runs_queued`; the Rust KPI
layer (`crates/chump-kpi-report/src/ci_pickup.rs`) reads them, percentiles them,
and emits `kind=ci_runner_starved` when the trailing-30-min p50 pickup exceeds
10 min over ≥ 3 samples. The webhook cache (`.chump/github_cache.db`) stores
`check_runs.started_at/completed_at` but **not** the job `created_at` needed for
queue-wait, so the collector falls back to the jobs API per the AC.

## Demand-side cuts already shipped (CREDIBLE-1512)

These reduce the *number of jobs each PR draws from the pool* without changing any
required check name (branch protection still requires only `verified`; the
`verified` aggregator still consumes the same lane results):

| Lever | Before (PR) | After (PR) | push / merge_group |
|---|---|---|---|
| `ci.yml` cargo-test shards | 4 | **2** | 4 (full partition kept) |
| `ci.yml` e2e (pwa) | fired on every `src/**` + ci.yml change, + 2 spawned-but-disabled no-op suites | gated to `web/**` / `e2e/**` paths; disabled suites dropped | full suite on merge_group |
| `audit.yml` shards | 4 on every non-docs PR | **per-lane subset** (rust→1,2,4; scripts→2,3,4; both→4) | 4 |

The cargo-test, audit, and pwa check-run *names* are unchanged, so the
`verified` cross-workflow poll and the merge queue are untouched.

**Honest limit of the demand-side cut.** A broad PR (one that touches Rust *and*
scripts *and* workflows) still runs the full lane set plus ~10 near-instant
pass-through rollup/`-required` jobs (`test`, `verified`, `cargo-test`,
`clippy-required`, `cargo-test-required`, `fast-checks-required`,
`fast-checks-heavy-required`, `test-e2e`, `audit`, `audit-required`). Those
rollups finish in seconds but each still occupies a concurrency slot. Getting a
broad PR *under 10 total jobs* would require collapsing those rollups into the
`verified` aggregator (none are branch-protection-required; only `verified` is) —
a follow-up, deliberately out of scope here because the `-required` names are
consumed by downstream tooling (PR-rescue, ambient monitoring). The cuts above
target the jobs that actually *sit in the runner queue for minutes*, which is
what causes the starvation.

## Supply-side options

### Option A — re-enable the stopped Mac self-hosted runner for fast-checks

`ci.yml` already carries the per-lane toggle `vars.CHUMP_SELF_HOSTED_FAST_CHECKS`
(and siblings `CHUMP_SELF_HOSTED_CARGO_TEST`, `RUNNER_AUDIT`, …). Flipping
`CHUMP_SELF_HOSTED_FAST_CHECKS=true` routes the fast-checks lane back onto the
self-hosted macOS fleet, off the contended GH pool.

- **Pros:** zero new spend; the plumbing exists; takes load off `ubuntu-latest`
  immediately for the single busiest lane.
- **Cons:** the self-hosted Macs were the documented source of ~50% of the
  historical CI-rot tax (rustup conflicts, tauri corruption, runner-binary
  refresh failures — DOC-063 14-day post-mortem, INFRA-2117). Re-enabling trades
  a capacity problem for a reliability problem unless the runner is kept healthy.
  Never route onto **cuphead** (the build node) or **helsinki** (the broker).

### Option B — a Linux self-hosted runner on a cheap VPS

Stand up a dedicated Linux runner (2-4 vCPU VPS, ~$12-24/mo) labelled into the
`chump-fleet` group and route the hot Linux lanes (fast-checks, cargo-test) to it
via the existing `vars.*` toggles.

- **Pros:** cheap; Linux matches what the lanes already build (no macOS rot
  class); isolated from the fleet's build/broker nodes; scales by adding a second
  VPS. Durable capacity, not a plan upgrade you re-pay monthly per-minute.
- **Cons:** one more host to provision, patch, and monitor (ghost-online is a
  real failure mode — see `infra-watcher`); a single VPS is a single point of
  contention if the queue is deep. **Never cuphead (build node); never helsinki
  (broker).**

### Option C — GitHub Team plan

Upgrade the org to GitHub Team, raising the concurrent-job ceiling and the
hosted-minutes allotment.

- **Pros:** no infra to run; larger-runner SKUs available; uniform hosted
  environment (no self-hosted rot). Immediate relief with one billing change.
- **Cons:** recurring per-seat + per-minute spend that grows with fleet activity;
  does not remove the `strict=true` requeue multiplier — it just buys a bigger
  pool to absorb it; the fleet's long-term direction is *fewer external
  dependencies*, and a paid pool is the opposite.

## Recommendation

**Do the demand-side cut first (shipped here), then Option B (cheap Linux VPS
runner) as the durable supply-side fix, holding Option A as the zero-cost
stop-gap and Option C only if B proves insufficient.**

Rationale: the cuts reduce the queue multiplier for free. Option B gives durable,
cheap, Linux-native capacity that matches the lanes and stays off the paid-plan
treadmill — consistent with the "own iron, fewer external deps" direction — while
avoiding the macOS rot class that made Option A expensive last time. Option A is
the right *immediate* lever (one repo-var flip) if starvation re-fires before a
VPS is stood up. Option C is the fallback if a single VPS can't keep up and the
operator prefers spend over another host — but it leaves the `strict=true`
requeue amplification in place, so pair any capacity option with the standing
`kind=ci_runner_starved` alarm so the decision is re-triggered by data, not by a
stuck queue someone happens to notice.
