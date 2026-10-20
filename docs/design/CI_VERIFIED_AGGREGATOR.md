# CI `verified` Aggregator — Architecture Spec (META-134)

> **Status:** LIVE — CREDIBLE-269 (SHIP-INFRA 1/7, foundation landed
> 2026-08-11, cross-workflow lanes landed 2026-08-20, flip to
> `verified`-only confirmed live 2026-08-20). `scripts/ci/aggregator-verified.sh`
> implements the §2.2-2.3
> lane-classification decision logic (unit-tested by
> `scripts/ci/test-aggregator-verified.sh`) and a `verified` job in
> `.github/workflows/ci.yml` runs it on every PR over the ci.yml-local lanes
> (`fast-checks`, `clippy`, `cargo-test`, `pr-hygiene`, `test`) **plus**
> `audit` (audit.yml) and `ACP protocol smoke test` (integrations.yml) —
> those two live in separate workflows, so `verified` polls their Checks-API
> conclusions cross-workflow via `scripts/ci/poll-cross-workflow-checks.sh`,
> feeding the result into the same classification logic as a same-workflow
> lane. **CREDIBLE-1554 (see §2.6):** under a GitHub merge queue `verified` now
> WAITS IN-JOB (via `scripts/ci/verified-wait.sh`) for those cross-workflow
> lanes to conclude on the event SHA, up to 90 min — a lane still running or
> not-yet-posted is `PENDING` (keep polling), `FAILURE` only on a real red lane
> or the timeout — so the first verdict is right on `merge_group` and
> `pull_request` alike. `verified` emits `kind=verified_aggregator_decision` to
> `ambient.jsonl`. **Branch protection and ruleset 15133729 flip to require
> ONLY `verified`, confirmed live via `gh api repos/:owner/:repo/branches/main/protection`
> and ruleset 15133729 — both list exactly one required-status-check entry
> (`verified`). `docs/baselines/branch-protection-main.json` updated to match.
> **Slice of:** META-131 (CI Required-Check Productization).
> **Pair doc:** [`docs/strategy/CI_POLICY_AUDIT.md`](../strategy/CI_POLICY_AUDIT.md) (META-133 — inventory of today's state).
> **Filed:** 2026-05-30, owner: curator-opus-handoff.
> **Target metric:** drop admin-merge ratio from ~70% (current) to **<5%** within 30 days of flip.

---

## 1. Goal

Today, branch protection on `main` lists a **required-trio** of named status checks (`audit`, `test`, `ACP protocol smoke test`) plus a constellation of variants (`audit-required`, `cargo-test-required`, `fast-checks-required`, etc.). Each required name is a *direct pointer* at a single GitHub-Actions job. The arrangement has three failure modes that compound:

1. **Path-filter skips wedge the queue.** A doc-only PR has `if: needs.changes.outputs.code == 'true'` short-circuit to skip on `test`/`audit`. No check-run is emitted under that name. The ruleset waits forever for a contextID that will never exist. PRs sit BLOCKED with `0 fails 0 pending`. This wedge took down 6 PRs on 2026-05-29 (INFRA-2191) and recurred 5+ times in the prior month — operator manually edits the ruleset, flips required-checks empty, merges armed PRs, restores. Admin-merge.
2. **Stub jobs were bolted on per-incident** (`audit-stub`/`audit-required`, `cargo-test-stub`/`cargo-test-required`, ...). Each addition mutates `.github/workflows/ci.yml` AND branch protection AND the ruleset. Drift between the three surfaces (workflow lists job X, branch-protection points at name Y, ruleset enforces Z) is the rank-2 CI-rot class per `docs/strategy/CI_REVIEW_2026-05-29.md`.
3. **Flaky tests cannot quarantine themselves** without manual intervention. A known-flake test that fails 3× in 24h has to be either disabled in source (loses signal) or manually allowlisted in the ruleset (more drift). The fleet has no closed-loop quarantine state machine.

The fix is a **single required check named `verified`** that aggregates path-aware lane verdicts. Branch protection points only at `verified`. Every other lane reports its conclusion *upstream* into the aggregator; `verified` decides whether the PR is shippable.

> **Outcome:** branch-protection has **exactly one** required-status-check entry forever. All gate-evolution happens inside the `verified` job's logic — no more 3-surface drift.

---

## 2. Architecture

### 2.1 Lane fan-in topology

```
                                        ┌─────────────────────────┐
                                        │  branch protection on   │
                                        │  main + merge_group     │
                                        │  required-checks: [     │
                                        │    "verified"           │
                                        │  ]                      │
                                        └────────────┬────────────┘
                                                     │
                                                     ▼
        ┌─────────────────────────────────────────────────────────────┐
        │  verified  (GH-Actions job — name MUST be "verified")       │
        │                                                             │
        │  needs:                                                     │
        │    - cargo-test                                             │
        │    - cargo-test-stub                                        │
        │    - clippy                                                 │
        │    - clippy-stub                                            │
        │    - audit                                                  │
        │    - audit-stub                                             │
        │    - fast-checks                                            │
        │    - fast-checks-stub                                       │
        │    - e2e-pwa                          (no stub yet — TBD)   │
        │    - e2e-battle-sim                                         │
        │    - e2e-golden-path                                        │
        │    - ACP-smoke                                              │
        │    - pr-hygiene                                             │
        │    - gap-status-check                                       │
        │    - gaps-integrity                                         │
        │                                                             │
        │  if: always()    # MUST always run, even on lane failures   │
        │                                                             │
        │  decision logic (see §2.3)                                  │
        └──────────────────────────────┬──────────────────────────────┘
                                       │
              ┌────────────────┬───────┴────────┬────────────────┐
              ▼                ▼                ▼                ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
        │ cargo-   │    │  clippy  │    │  audit   │    │ e2e-pwa  │
        │  test    │    │          │    │          │    │          │
        └─────┬────┘    └─────┬────┘    └─────┬────┘    └─────┬────┘
              │               │               │               │
              ▼               ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
        │  cargo-  │    │  clippy- │    │  audit-  │    │ (no stub)│
        │   test-  │    │   stub   │    │   stub   │    │          │
        │   stub   │    │          │    │          │    │          │
        └──────────┘    └──────────┘    └──────────┘    └──────────┘
              ↑ Exactly one of {real, stub} runs per PR; the other skips.
                Mutual exclusion contract is enforced by `scripts/ci/test-ruleset-doc-only-pr.sh`
                (already validates the audit pair; extended in INFRA-2191 follow-up to cover
                all required pairs).
```

**Why two-tier (real-job + stub-job → aggregator) and not a single job with branching `if`:**
- A single job that decides internally whether to run cargo-test depends on workflow-level outputs from the `changes` step. GH Actions does not allow downstream `needs` to introspect *what* a job did, only whether it `success`/`failure`/`skipped`. The stub pattern gives the aggregator two named inputs whose union is "what was the lane's verdict?".
- Today's per-lane `*-required` rollup jobs (audit-required, cargo-test-required, ...) are the prior-art for this pattern. The aggregator generalizes: instead of N per-lane rollups all listed as required, there is **one** rollup (`verified`) for the whole PR.

### 2.2 Lane conclusion vocabulary

Each lane returns one of:

| Conclusion | Source | Meaning |
|---|---|---|
| `SUCCESS` | GH-Actions `success` | The real job (or its stub) ran and passed. |
| `FAILURE` | GH-Actions `failure` | The real job ran and failed — block. |
| `SKIPPED-PATH-FILTER` | GH-Actions `skipped` from a path-filter `if:` short-circuit, BUT a stub exists for this lane | Real job skipped because path-filter excluded it; the stub MUST have run and emitted `success` for the aggregator to count this as PASS. |
| `FLAKE-QUARANTINED` | A separate quarantine label exists for this test/job (see §3) | The lane failed, but the failure matches an open quarantine ticket with a backing follow-up gap. Aggregator treats as PASS (with an audit trail). |
| `IN-PROGRESS` | GH-Actions `in_progress` at the moment `verified` evaluates | A lane is still running. Aggregator returns `in_progress` itself — branch protection waits. |

### 2.3 Aggregator decision logic

The `verified` job runs a single bash step that walks each `needs.*.result`:

```yaml
verified:
  name: verified  # branch protection points HERE
  needs:
    - cargo-test
    - cargo-test-stub
    - clippy
    - clippy-stub
    - audit
    - audit-stub
    - fast-checks
    - fast-checks-stub
    - e2e-pwa
    - e2e-battle-sim
    - e2e-golden-path
    - ACP-smoke
    - pr-hygiene
    - gap-status-check
    - gaps-integrity
  if: always()
  runs-on: ubuntu-latest
  timeout-minutes: 3
  steps:
    - uses: actions/checkout@v6
    - name: Aggregate lane verdicts (META-134)
      run: |
        bash scripts/ci/aggregator-verified.sh \
          --lane "cargo-test=${{ needs.cargo-test.result }},${{ needs.cargo-test-stub.result }}" \
          --lane "clippy=${{ needs.clippy.result }},${{ needs.clippy-stub.result }}" \
          --lane "audit=${{ needs.audit.result }},${{ needs.audit-stub.result }}" \
          --lane "fast-checks=${{ needs.fast-checks.result }},${{ needs.fast-checks-stub.result }}" \
          --lane "e2e-pwa=${{ needs.e2e-pwa.result }}" \
          --lane "e2e-battle-sim=${{ needs.e2e-battle-sim.result }}" \
          --lane "e2e-golden-path=${{ needs.e2e-golden-path.result }}" \
          --lane "ACP-smoke=${{ needs.ACP-smoke.result }}" \
          --lane "pr-hygiene=${{ needs.pr-hygiene.result }}" \
          --lane "gap-status-check=${{ needs.gap-status-check.result }}" \
          --lane "gaps-integrity=${{ needs.gaps-integrity.result }}" \
          --pr "${{ github.event.pull_request.number }}" \
          --sha "${{ github.event.pull_request.head.sha }}"
```

The aggregator script (`scripts/ci/aggregator-verified.sh`) classifies each lane per §2.2 then computes:

```
verified succeeds  IFF  ∀ lane: classified(lane) ∈ {SUCCESS, SKIPPED-PATH-FILTER+stub-pass, FLAKE-QUARANTINED}

verified fails     IFF  ∃ lane: classified(lane) = FAILURE
                                AND  no quarantine label covers it

verified pending   IFF  ∃ lane: classified(lane) = IN-PROGRESS
                                AND  no FAILURE lane already determined the verdict
```

Plain English:
- **Both real and stub skipped, no stub exists for this lane** → fail (lane is missing a stub; this is a configuration bug to fix before flip).
- **Real skipped + stub succeeded** → pass (path-filter lane).
- **Real failed + flake-quarantine label exists** → pass (with audit emit).
- **Real failed + no quarantine label** → fail.
- **Any IN-PROGRESS + no other FAILURE** → in-progress; branch protection waits.
- **All success or quarantined** → pass.

Aggregator emits `kind=verified_aggregator_decision` to `ambient.jsonl` with per-lane classification for offline audit (see §5).

### 2.4 Stub-job contract (extension of INFRA-2191 pattern)

Every lane listed in §2.1 that is gated by a `if: needs.changes.outputs.X == 'true'` path-filter MUST have a sibling stub job satisfying:

| Field | Real job | Stub job |
|---|---|---|
| `name:` | `audit` | `audit` (intentionally same — both emit one `audit` check-run; mutually exclusive) |
| `if:` | `code == 'true' \|\| event != 'pull_request'` | `(code != 'true' \|\| docs_only == 'true') && event == 'pull_request'` |
| `needs:` | `changes` | `changes` |
| Output | Real lane work | Trivial echo + exit 0 |
| Result the aggregator sees | `success`/`failure`/`in_progress` | `success` (or `skipped` if real job ran) |

**Mutual exclusion smoke test:** `scripts/ci/test-ruleset-doc-only-pr.sh` extends to assert for every required lane: on a synthesized doc-only PR, exactly one of `{lane, lane-stub}` runs; on a code-only PR, the inverse. CI fails if both ran or both skipped.

### 2.5 What replaces the `*-required` rollup jobs

The current per-lane `audit-required` / `cargo-test-required` / `fast-checks-required` rollups become **dead code** under the aggregator. Migration plan §6 removes them in Week 3.

### 2.6 In-job wait — the first verdict must be right under a merge queue (CREDIBLE-1554)

GitHub's native merge queue is the landing provider (umbrella CREDIBLE-1555). A
merge queue removes a `merge_group` from the queue the **instant** a required
check concludes `FAILURE` — there is no second pass to heal into. So the single
`verified` verdict must be correct the first time it concludes, on `merge_group`
**and** `pull_request` alike.

Two of the lanes (`audit` from audit.yml, the `ACP protocol smoke test` from
integrations.yml) live in separate workflows; `needs:` can't see them, so they
are polled cross-workflow via the Checks API. A real `audit` run takes 15–40 min
on starved runners. The old `verified` job polled those lanes for only 120s,
then aggregated once: the first pass returned `PENDING` (aggregator exit 2 → job
`FAILURE`) while the audit was still running, and relied on
`verified-recompute.yml` re-running the job on audit/ACP `workflow_run`
completion. On a PR the failed-then-rerun check heals; in a merge queue the
ejection already happened and the recompute re-run lands too late.

**The rule.** The `verified` job runs exactly **one** step —
`bash scripts/ci/verified-wait.sh` — which **waits in-job** for the
cross-workflow lanes to CONCLUDE on the event SHA, up to the script default of
5400s (90 min, the ruleset `check_response_timeout`), reporting nothing until
they conclude. The step passes the six local lanes as `needs.*.result` strings,
`--pr`, `--event-name`, and the two cross lanes as
`--cross "audit"` / `--cross "ACP protocol smoke test (Zed / JetBrains compatible)"`.
`verified-wait.sh` re-classifies every lane (local strings + a fresh
cross-workflow snapshot) each poll via the unchanged decision core
`scripts/ci/aggregator-verified.sh`:

```
PENDING (aggregator exit 2)  — a lane is still running OR has not posted a check
                               run yet, and nothing is red → KEEP POLLING.
FAILURE (exit 1)             — a REAL red lane concluded failure (short-circuit;
                               no reason to wait) OR the 90-min timeout elapsed
                               while still PENDING (with a reason naming the
                               lanes that never concluded).
SUCCESS (exit 0)            — every lane is green or legitimately skipped.
```

**Lane-seen rule folded in (RESILIENT-1617).** A lane that has not yet posted a
check run — because its backing workflow (audit.yml) is still running, its shard
matrix hasn't finished, or it simply hasn't been dispatched yet — is `PENDING`,
**never FAIL and never PASS**, for the entire wait. The only way a still-pending
lane becomes a `FAILURE` is the timeout. This is implemented by
`poll-cross-workflow-checks.sh --snapshot` (one Checks-API fetch, no fail-close:
any not-yet-terminal lane reads `in_progress`); `verified-wait.sh` owns the
single wait-and-fail-on-timeout decision. The default (non-snapshot) poll mode
keeps its own short-wait + fail-closed-at-timeout behavior for other callers.

**One lane set, per-event budget (CREDIBLE-1554 item 5, Chief-binding).** The
set of lanes `verified` requires — the six local lanes plus the two
cross-workflow lanes (`audit`, ACP) — is **one list**, classified on the event
SHA identically for `pull_request`, `merge_group`, `push` and
`workflow_dispatch`. No event path adds or drops a lane; `verified-wait.sh
--print-lanes` renders that invariant set and `test-verified-wait.sh` asserts it
is identical for all four events. Only the **wait budget** differs: a
`workflow_dispatch` re-run (the INFRA-1395 grace window) is a manual probe, so it
uses a **short bounded window** (`DISPATCH_TIMEOUT_S`, default 300s) rather than
the full 90 min — but it **still classifies the cross lanes on the SHA**
(`required-check-monitor.sh` dispatches `ci.yml` on the PR head, so audit/ACP
already posted there) and concludes `FAILURE` if any cross lane is red, still
running, or never-seen at the end of that window — **never a silent PASS** past
an unseen or red cross lane.

**Invariants preserved.** `aggregator-verified.sh` keeps its `0/1/2/3` exit
codes for all existing callers; the wait lives in `verified-wait.sh`, not in a
new bypass/skip env var. The `verified` job `timeout-minutes` is 95 — greater
than the 90-min wait — so the Actions runner outlives the wait plus
checkout/aggregate overhead rather than killing it mid-poll. The behavior is
pinned by two tests: `scripts/ci/test-ci-verified-shape.sh` (a PyYAML shape
guard asserting the `verified` job runs `verified-wait.sh` with both `--cross`
lanes and `timeout-minutes` ≥ 91, so a comment-only edit can never masquerade as
wired) and `scripts/ci/test-verified-wait.sh` (stubbed Checks API: in_progress→
success, in_progress→failure, never-seen→success, never-seen→timeout, red-local
short-circuit, cross cancelled/timed_out/action_required short-circuit, gh-error
fail-SAFE→timeout, ACP-green+audit-never-seen→PENDING, temp-ambient isolation,
and the workflow_dispatch skip, for both event types).

> **Retirement note:** with the first verdict now correct on `merge_group`,
> `verified-recompute.yml`'s **PR path** is retired separately in RESILIENT-1644;
> its push-event healer stays until CREDIBLE-1521.

---

## 3. Flake quarantine class

### 3.1 Detection

`scripts/ci/flake-detector.sh` (new — extends existing `scripts/ops/ci-flake-rerun.sh`):

- Reads the last 100 failed `cargo-test` / `e2e-*` runs across PRs from `.chump/github_cache.db` (`check_runs` table + `pr_state.head_sha` lookup).
- Computes per-test failure fingerprint (test-name + first 4 lines of error normalized).
- For fingerprints failing **3+ consecutive times** across **3+ different PRs** (so it's not a single bad branch):
  - Open a GitHub issue with title `flake: <test-name>` and label `flake-quarantined`.
  - File a follow-up gap `RESILIENT: fix flake <test-name> (quarantined <date>)` via `chump gap reserve --domain RESILIENT`.
  - Append entry to `.chump/quarantine.db` (sqlite): `fingerprint → {issue_url, gap_id, started_at, expires_at}`.

The detector runs once per hour via launchd (`scripts/setup/install-flake-detector-launchd.sh`).

### 3.2 Aggregator integration

When `verified` evaluates a `FAILURE` lane, the aggregator looks up the failure fingerprint in `.chump/quarantine.db`:

```python
if lane_result == 'failure':
    fingerprint = compute_fingerprint(lane_log_url)
    quarantine = quarantine_db.lookup(fingerprint)
    if quarantine and not quarantine.expired():
        # backing follow-up gap must be open
        if chump_gap_status(quarantine.gap_id) == 'open':
            emit_ambient(kind='verified_lane_flake_quarantined',
                         lane=lane_name, gap_id=quarantine.gap_id)
            return SUCCESS  # treated as pass
    return FAILURE
```

### 3.3 State machine

```
                  3 consecutive same-fingerprint
                  failures across 3+ PRs
                          │
                          ▼
   ┌────────────┐   detector runs    ┌──────────────────┐
   │   ACTIVE   │ ─────────────────▶ │   QUARANTINED    │
   │ (in test   │                    │ (issue labeled,  │
   │  suite)    │                    │  gap filed)      │
   └────────────┘                    └────────┬─────────┘
         ▲                                    │
         │                                    │
         │     follow-up gap ships            │     14 days elapse
         │     (status: shipped)              │     (whichever first)
         │                                    │
         └────────────────────────────────────┘
                 quarantine expires;
                 test re-enters required class

    On re-entry:
      • If next 3 runs pass → stays in required class (true fix).
      • If next run fails with same fingerprint → re-quarantines AUTOMATICALLY,
        with a `kind=flake_re_quarantined` ambient emit + escalation comment
        on the original gap (so it gets re-prioritized).
```

### 3.4 Bounds (anti-abuse)

- **Maximum 5 lanes simultaneously in QUARANTINED state.** If the 6th would land, aggregator refuses the flip and emits `kind=flake_quarantine_budget_exhausted`. Operator must ship one of the open follow-up gaps first.
- **Each quarantine ticket auto-bumps to P1 after 7 days open**, P0 after 14 days, and the test re-enters required-class regardless of fix status (forces conversation).
- **`flake-quarantined` label is auto-only.** Manual application from operator dashboard is permitted but emits `kind=manual_quarantine_applied` with operator identity for audit.

---

## 4. Cascade rebase auto-trigger

### 4.1 Keystone-file landing → fleet-wide rebase

The existing `scripts/coord/queue-driver.sh` has `cascade_rebase_if_hot()` that fires `gh pr update-branch` on every open PR when a commit on main touches a hot file. Today's hot-file list lives in `scripts/coord/cascade-rebase-trigger-paths.txt`:

```
Cargo.toml
rust-toolchain.toml
Cargo.lock
src/main.rs
src/lib.rs
src/agent_loop/**
src/dispatch.rs
.github/workflows/ci.yml
```

**This spec extends the trigger to additional aggregator-keystone files** (cascade is necessary because changing the aggregator changes every PR's evaluation surface):

```
# Additions for META-134 aggregator
.github/workflows/ci.yml                   # already listed; aggregator job lives here
scripts/ci/aggregator-verified.sh          # NEW: aggregator decision logic
scripts/ci/flake-detector.sh               # NEW: flake-quarantine source
docs/design/CI_VERIFIED_AGGREGATOR.md      # this doc — cascade so PRs pick up new contract
scripts/coord/aggregator-watchdog.sh       # NEW: §5 watchdog
.chump/quarantine.db schema migration      # implicit — any sqlite migration emits separately
```

### 4.2 Trigger contract

When a PR lands on main with any keystone-file diff:

1. `queue-driver.sh` detects via `cascade_rebase_if_hot()` (already implemented).
2. For each open non-draft PR: call `gh pr update-branch` (already implemented).
3. Per-commit-SHA debounce lock prevents N workers from firing N times (already in place — INFRA-1310).
4. Emit `kind=cascade_rebase_fired` with `{triggered_by_file, pr_count}` (already emitted).

**This spec doesn't change the cascade mechanism — it widens the trigger set.** All four points are existing INFRA-2207 behavior; META-134 just adds three new entries to `cascade-rebase-trigger-paths.txt`.

### 4.3 Why this matters for the aggregator

Without cascade rebase, an aggregator-logic change shipped in PR-N could let PR-N+1...N+50 keep being evaluated against the OLD aggregator (because GH-Actions re-uses the workflow definition from the PR's base SHA, not main). Cascade rebase pulls every open PR forward to the new base, so all PRs evaluate against the latest aggregator. Otherwise, drift between "what's required on main today" and "what each open PR has to satisfy" silently accumulates.

---

## 5. Drop-restore safety

### 5.1 The failure mode being prevented

On 2026-05-29, operator manually edited ruleset 15133729 to clear `required_status_checks`, merged 5 ARMED PRs, then restored. Between drop and restore, **branch protection was effectively off**. A bad PR could have landed during that window with zero required checks. The window is operator-attention-bounded (~2-5 min). Today, this is acceptable because it's rare and operator-driven; it will become unacceptable when the aggregator handles the routine path, because the only reason to manually edit will be a genuine wedge — and we want those windows visible.

### 5.2 Audit emission contract

Every mutation to branch-protection or ruleset required-checks emits an ambient event:

```yaml
# docs/observability/EVENT_REGISTRY.yaml — new entries
ruleset_changed:
  trigger: "ruleset_required_checks mutated via API (PUT, PATCH, DELETE)"
  fields_required: [ts, actor, ruleset_id, old_required_checks, new_required_checks, reason]
  effect_metric: ruleset_required_checks_size
  consumers: [aggregator-watchdog.sh, dashboards/ruleset-history]

ruleset_required_empty:
  trigger: "ruleset required_status_checks transitions to empty array (DROP)"
  fields_required: [ts, actor, ruleset_id, prior_check_count]
  effect_metric: required_checks_outage_open
  consumers: [aggregator-watchdog.sh]

ruleset_required_restored:
  trigger: "ruleset required_status_checks transitions from empty to non-empty (RESTORE)"
  fields_required: [ts, actor, ruleset_id, restored_check_count, outage_duration_s]
  effect_metric: required_checks_outage_resolved
  consumers: [aggregator-watchdog.sh]

verified_aggregator_decision:
  trigger: "verified job emits final classification per PR"
  fields_required: [ts, pr, sha, verdict, lanes_classified]
  effect_metric: aggregator_pass_rate
  consumers: [dashboards/ci-pass-rate, scripts/ci/aggregator-rollout-shadow.sh]

verified_lane_flake_quarantined:
  trigger: "aggregator passed a lane that failed because a quarantine entry covers it"
  fields_required: [ts, pr, sha, lane, gap_id, fingerprint]
  effect_metric: quarantine_passthrough_count
  consumers: [dashboards/quarantine-health]

flake_quarantine_budget_exhausted:
  trigger: "flake-detector tried to quarantine a 6th lane while 5 are active"
  fields_required: [ts, attempted_lane, active_quarantines]
  effect_metric: quarantine_budget_breach
  consumers: [chump-coord, operator-paging]

flake_re_quarantined:
  trigger: "expired quarantine re-failed within first 3 post-expiry runs"
  fields_required: [ts, lane, prior_gap_id, new_gap_id]
  effect_metric: quarantine_recidivism_count
  consumers: [dashboards/quarantine-health]

cascade_rebase_fired:
  trigger: "queue-driver detected hot-file landing and fired update-branch on open PRs"
  fields_required: [ts, triggered_by_file, pr_count, head_sha]
  effect_metric: cascade_rebase_fan_out
  consumers: [dashboards/cascade-history]  # already emitted; documented here for completeness
```

Scanner-anchor discipline (per `.claude/agents/handoff.md` §5): each of the three NEW kinds above (`ruleset_changed`, `ruleset_required_empty`, `ruleset_required_restored`) ships with an adjacent comment `# scanner-anchor: "kind":"<name>"` in its emitter source AND an entry in `docs/observability/EVENT_REGISTRY.yaml`. No new register-without-emit drift.

### 5.3 Watchdog

`scripts/coord/aggregator-watchdog.sh` (new, launchd-installed) runs every 60s and:

1. Queries ruleset 15133729 via `gh api`.
2. If `required_status_checks` is empty AND was non-empty at the prior tick:
   - Emit `kind=ruleset_required_empty` with `prior_check_count`.
   - Start a `required_checks_outage_open` timer.
3. If outage open for **> 120s**:
   - Page operator (broadcast WARN to `operator-*` via `scripts/coord/broadcast.sh`).
   - Page every active curator (`curator-opus-*`) so they all stop merging until restored.
   - Continue paging every 60s until restored.
4. On restore (empty → non-empty): emit `kind=ruleset_required_restored` with `outage_duration_s`.

**Dependency:** the watchdog requires INFRA-2201 (ruleset-state-history sqlite store) for the "was non-empty at prior tick" comparison. META-134 ships the watchdog stubbed-on-INFRA-2201; flipping `verified` to required in Week 3 is gated on INFRA-2201 shipping.

### 5.4 Operator escape hatch

Manual drop-restore remains available via `gh api`. The watchdog does not prevent it — it makes the window expensive (paging) so the operator chooses it only when justified. Every manual edit emits an audit event keyed on `actor`, building a history operator can review later for "did I really need to do that 7 times this week?"

---

## 6. Migration plan (3 weeks)

### Week 1 — Ship aggregator side-by-side; runs but doesn't gate

| Day | Action |
|---|---|
| 1 | Land `scripts/ci/aggregator-verified.sh` + the `verified` job in `ci.yml`. `verified` runs on every PR but is NOT added to branch protection. |
| 1 | Land `scripts/ci/flake-detector.sh` + launchd plist. Begins populating `.chump/quarantine.db`; aggregator can consult it. |
| 2-3 | Run for ~50 PRs. Inspect `verified_aggregator_decision` events in `ambient.jsonl`. Verify lane classifications match human intuition. |
| 4-7 | Add stubs for any required lane that's missing one (today: e2e-pwa, e2e-battle-sim, e2e-golden-path, ACP-smoke if path-filtered, pr-hygiene if path-filtered). |

**Exit criteria for Week 1:** `verified` has produced a determinate verdict (not `pending`) on 50 consecutive PRs without a single false-positive vs the human reviewer's intuition.

### Week 2 — Shadow mode: measure divergence

| Day | Action |
|---|---|
| 8 | Ship `scripts/ci/aggregator-rollout-shadow.sh` — runs hourly, for each merged PR in the last hour reads both: (a) what `verified` said and (b) what the current required-trio (`audit`+`test`+`ACP-smoke`) decided. |
| 8-13 | Build divergence dashboard: rate of `aggregator_says_pass + trio_says_fail` and inverse. |
| 14 | **Go/no-go decision.** Acceptance bar: divergence rate < 1% AND 100% of divergences are explainable (aggregator passed a flake-quarantined lane while trio blocked → expected; aggregator caught a real failure trio missed → counts as aggregator-better, also acceptable). |

**Exit criteria for Week 2:** divergence < 1% with all instances explainable. No "aggregator passes a real bug" cases.

### Week 3 — Flip aggregator to required; remove individual required-checks

| Day | Action |
|---|---|
| 15 | **Single atomic ruleset edit:** PUT ruleset 15133729 `required_status_checks` to `["verified"]`. Remove `audit`, `test`, `ACP protocol smoke test`, and all `*-required` variants. Emit `kind=ruleset_changed` with full before/after. |
| 15 | Cascade rebase fires automatically (ci.yml in trigger paths). Every open PR re-evaluated against new contract. |
| 15-16 | Watch admin-merge rate. Target: zero admin merges in first 24h post-flip. Alert if any. |
| 17-21 | If first 5 days admin-merge rate < 5%, remove dead per-lane `*-required` rollup jobs (`audit-required`, `cargo-test-required`, `fast-checks-required`, `clippy-required`) from ci.yml. They're already non-required; this cleanup. |

**Exit criteria for Week 3 / project complete:** branch-protection has exactly one required-check entry (`verified`). Admin-merge rate < 5% sustained over 7 days.

### Rollback procedure (if any week fails)

```bash
# Restore prior required-trio + remove verified from required
gh api -X PUT repos/jeffadkins1/Chump/rulesets/15133729 \
  -f required_status_checks='[{"context":"audit"},{"context":"test"},{"context":"ACP protocol smoke test"}]'
# Emit audit
printf '{"ts":"%s","kind":"ruleset_changed","actor":"operator","ruleset_id":15133729,"reason":"META-134 rollback"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
# Open a postmortem gap
chump gap reserve --domain META --title "META-134 rollback retro — <date>"
```

The `verified` job continues to run after rollback (harmless; just no longer required). Shadow mode resumes. Re-attempt after fixing the divergence class that caused rollback.

---

## 7. Measurement

### 7.1 Primary metric

**Admin-merge ratio** = `count(prs merged via "Merge without waiting for requirements") / count(all prs merged)` in a rolling 30-day window.

- Today: ~70% (operator dashboard via `gh api` query on `merged_by` + audit log).
- Target post-Week-3: < 5%.
- Hard rollback trigger: > 10% sustained over 5 days post-flip.

### 7.2 Secondary metrics

| Metric | Source | Target |
|---|---|---|
| `verified` pass rate | `verified_aggregator_decision` events, count `verdict=PASS` / total | > 85% (matches today's underlying lane pass rate) |
| Mean PR queue time | `gh pr list --merged --json mergedAt,createdAt` | No regression vs pre-flip baseline ± 10% |
| Ruleset-required-empty window count | `ruleset_required_empty` events | 0 per week (drops to 0 since operator no longer drops to ship) |
| Flake-quarantine churn | `verified_lane_flake_quarantined` per week | Trends down as gaps ship |
| Cascade rebases per main commit | `cascade_rebase_fired` events | Steady (≈1 per keystone-touching merge) |
| Quarantine recidivism | `flake_re_quarantined` events | 0 (test is genuinely fixed before re-entry) |

### 7.3 Re-audit cadence

`scripts/ci/aggregator-rollout-shadow.sh` continues running indefinitely post-flip (shadow mode is now "verify aggregator is still right"). Operator reviews divergences monthly. If divergence > 1% in any month, file `META: aggregator drift <date>` and re-tune lane classifications.

---

## 8. Diagrams

### 8.1 Lane-fan-in topology (detailed)

```
                          PR opened or pushed
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │   changes job        │
                       │   computes flags:    │
                       │   - code             │
                       │   - docs_only        │
                       │   - scripts_only     │
                       │   - ci_config_only   │
                       └─────────┬────────────┘
                                 │
       ┌─────────────────────────┼─────────────────────────┐
       │                         │                         │
       ▼                         ▼                         ▼
 ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │cargo-test│ │ clippy   │ │ audit    │ │fast-     │ │e2e-pwa   │
 │  (real)  │ │  (real)  │ │  (real)  │ │checks    │ │ (real)   │
 │          │ │          │ │          │ │ (real)   │ │          │
 │if: code  │ │if: code  │ │if: code  │ │always    │ │if: code  │
 └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘
       │            │            │            │            │
       ▼            ▼            ▼            ▼            ▼
 ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │cargo-    │ │ clippy-  │ │ audit-   │ │fast-     │
 │test-     │ │ stub     │ │ stub     │ │checks-   │
 │stub      │ │          │ │          │ │stub      │
 │if: !code │ │if: !code │ │if: !code │ │ (n/a:    │
 │  || docs │ │  || docs │ │  || docs │ │  always- │
 │  _only   │ │  _only   │ │  _only   │ │  runs)   │
 └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘
       │            │            │            │
       │  (Exactly one of {real, stub} runs per PR.)
       │
       └────────────┬────────────┬────────────┬────────────────────┐
                    │            │            │                    │
                    ▼            ▼            ▼                    ▼
              ┌────────────────────────────────────────────────────┐
              │                  verified                          │
              │  reads all needs.*.result via                      │
              │  scripts/ci/aggregator-verified.sh                 │
              │  classifies each lane per §2.2                     │
              │  emits ambient event per §5.2                      │
              │  exits 0 (PASS) or 1 (FAIL)                        │
              └─────────────────────┬──────────────────────────────┘
                                    │
                                    ▼
                       ┌──────────────────────┐
                       │ branch protection    │
                       │ required-checks: [   │
                       │   "verified"         │  ← ONE entry, forever
                       │ ]                    │
                       └──────────────────────┘
```

### 8.2 Flake-quarantine state machine

```
         test in
       ┌─required─┐
       │  class   │ ◀──────────────────────────────┐
       └────┬─────┘                                │
            │                                      │
            │ 3 consecutive same-fingerprint       │
            │ failures across 3+ PRs in 24h        │
            │                                      │
            ▼                                      │
   ┌─────────────────┐                             │
   │  DETECTING      │  flake-detector.sh          │
   │  (in detector   │  runs hourly                │
   │   window)       │                             │
   └────────┬────────┘                             │
            │                                      │
            │ detector confirms pattern            │
            │                                      │
            ▼                                      │
   ┌─────────────────────────────┐                 │
   │  QUARANTINED                │                 │
   │  - GH issue opened          │                 │
   │  - follow-up gap filed      │                 │
   │  - quarantine.db entry      │                 │
   │  - expires_at = now + 14d   │                 │
   │  - aggregator treats as     │                 │
   │    PASS on fingerprint hit  │                 │
   └────────┬────────────────────┘                 │
            │                                      │
            │            ┌─────────────────────────┤
            │            │                         │
   gap ships│      14d elapsed                     │
   AND status:shipped    │                         │
            │            ▼                         │
            │   ┌─────────────────┐                │
            │   │   EXPIRED       │                │
            │   │   re-enters     │                │
            │   │   required class│                │
            │   └────────┬────────┘                │
            │            │                         │
            │            │ next 3 runs             │
            │            │ pass cleanly            │
            │            ▼                         │
            └─────────▶ (back to required class)   │
                                                   │
                       ┌───────────────────────────┘
                       │
                       │ post-expiry failure with same fingerprint
                       │ within first 3 runs
                       │
                       ▼
            ┌─────────────────────────────┐
            │  RE-QUARANTINED             │
            │  - emit flake_re_quarantined│
            │  - escalation comment on    │
            │    prior gap                │
            │  - bump prior gap to P0     │
            │  - new quarantine entry     │
            │    with expires_at = now+7d │
            │    (shorter — second strike)│
            └─────────────┬───────────────┘
                          │
                          └─▶ (loop back to QUARANTINED above)
```

### 8.3 Migration timeline (visual)

```
Week 1               Week 2              Week 3            Post-flip
══════════           ══════════          ══════════        ══════════

 verified            verified            verified           verified
 added,              shadow-             flipped            steady-state
 runs only           compared            to                 measurement
                     vs trio            REQUIRED           
                                                            
                                                            
 stubs for           rollout-            old per-lane       monthly
 all lanes           shadow.sh           required           shadow audit
 verified            dashboards          rollups            for drift
                     50 PRs              removed             
                     observed                                 


       │                  │                  │                  │
       │                  │                  │                  │
  div < 1%?         go/no-go        admin-merge < 5%?    sustained < 5%?
   if yes →           decision        if no → rollback     if drift → re-audit
   continue                                                  
```

---

## Cross-references

- [`docs/strategy/CI_POLICY_AUDIT.md`](../strategy/CI_POLICY_AUDIT.md) — META-133 inventory of current state
- [`docs/strategy/CI_REVIEW_2026-05-29.md`](../strategy/CI_REVIEW_2026-05-29.md) — operator review motivating META-131
- [`docs/gaps/INFRA-2191.yaml`](../gaps/INFRA-2191.yaml) — original stub pattern this spec generalizes
- [`docs/gaps/INFRA-2200.yaml`](../gaps/INFRA-2200.yaml) — workflow-queue wedge that exposed empty-required-checks danger
- INFRA-2201 — ruleset-state-history sqlite store (watchdog dependency)
- INFRA-2207 — cascade-rebase-trigger-paths config (already in place; widened here)
- [`scripts/coord/queue-driver.sh`](../../scripts/coord/queue-driver.sh) — existing cascade implementation
- [`scripts/coord/cascade-rebase-trigger-paths.txt`](../../scripts/coord/cascade-rebase-trigger-paths.txt) — existing trigger-paths list
- [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) — where `verified` and stubs live
- [`docs/observability/EVENT_REGISTRY.yaml`](../observability/EVENT_REGISTRY.yaml) — register the 7 new event kinds before emit (scanner-anchor discipline per `.claude/agents/handoff.md` §5)

---

*End of META-134 spec v1. Pair with META-133 (`docs/strategy/CI_POLICY_AUDIT.md`) for the inventory side; implementation slices follow as separate gaps once this spec passes review.*
