# Ship Audit Rubric — grading what landed, not what's queued

> **What this is.** The standard for grading a **shipped PR** against the
> mission, the vision, and the needs of the OS, and for rolling those grades
> into an honest **release-note audit**.
>
> **What this is not.** Not a code review (correctness is CI's job), not a
> pipeline check (`scripts/dev/ship-audit.sh` owns that), not a backlog
> inventory (`chump mission-grade` owns that).

## Why this exists

Chump already grades three things, and none of them is the ship:

| Surface | Grades | Question answered |
|---|---|---|
| `chump mission-grade` (`src/mission_grade.rs`) | backlog **stock** per pillar | "is there work queued?" |
| `scripts/dev/ship-audit.sh` (INFRA-341) | **pipeline** gates 1-5 | "did the code reach main?" |
| `scripts/dev/mission-scoreboard.sh` (MISSION-014) | **THE BINARY** | "did BEAST get a zero-touch PR?" |
| **this rubric** | **the ship itself** | **"was it worth shipping?"** |

Note the shape of the gap. `mission_grade.rs` scores a pillar `A` when **two or
more gaps are waiting** in it. That is a measure of *supply*, and a pillar can
hold an `A` forever while shipping nothing that moves the ribbon. The fleet can
therefore report healthy pillars, a green pipeline, and a rising ship count
while the Scoreboard sits still. `docs/MISSION.md` already names this failure:
**motion is not progress.** This rubric is the instrument that catches it.

## The two axes (never collapse them)

A single composite number hides which half failed. A useless change shipped
immaculately is still waste; a ribbon-critical change shipped sloppily is still
debt. **Always report `M<n>/Q<n>`.**

### Axis M — Mission Vector (0-3)

The one question from `docs/MISSION.md`: *"Does this move the factory toward a
hands-off ribbon from a clean install?"*

| Score | Band | Test |
|---|---|---|
| **M3** | Ribbon-critical | Removes a **human touch** from the clean-install-to-outcome path, or advances THE BINARY (a zero-touch merge in a repo we don't own). |
| **M2** | Goal-serving | Unblocks a named Goal (1-5) without itself removing a touch. Prerequisite work with a stated successor. |
| **M1** | Lights-on | Substrate or self-maintenance that was genuinely load-bearing: a real outage fixed or prevented. Justified **only** as unblocking a Goal. |
| **M0** | Motion | Queue hygiene, bookkeeping, re-verification, meta-work about the fleet's own process. Did not move the Scoreboard. |

**M is judgment, not arithmetic.** An outcome link raises the *prior*, it does
not set the score. `chump gap reserve --priority P0|P1` already requires
`--outcome`, so linkage is cheap; a gap can be linked to `MISSION-010` and still
be pure bookkeeping. The auditor must read the diff, not the tag.

### Axis Q — Execution Quality (0-15)

Five dimensions, 0-3 each. These are largely mechanical and are what the
auditor script computes.

| Dim | Name | 3 | 0 |
|---|---|---|---|
| **T** | Traceability | Outcome linked, AC concrete and falsifiable, receipts (gap ID, PR #, metric) in the body | No outcome, vague AC, claims without receipts |
| **V** | Verification depth | Names its depth tier (smoke / happy-path / edge / adversarial) **and** its gaps | Claims "covered" or "tested" with no tier named |
| **D** | Durability | Fixes the **class**; adds the gate that prevents recurrence | Band-aid on the instance; reverted or re-fixed later |
| **L** | Legibility | A stranger reads it and knows what changed, why, and what it cost | Auto-generated placeholder title; intent unstated |
| **W** | Waste | Net-new capability; prior art checked (harvester) | Duplicate, rework, churn, or re-implemented prior art |

## Hard gates (auto-fail a dimension, never averaged away)

Averages hide catastrophic single failures. These are absolute. Each is drawn
from a rule the shop already holds, and each has a measured base rate in this
repo (30-day window, sampled 2026-09-22).

| Gate | Condition | Forces | Rule it enforces | Observed |
|---|---|---|---|---|
| **G1** | **No stated intent.** Title is a placeholder (e.g. `agent changes (auto-committed, model skipped git_commit)`) | `L=0`, verdict **UNAUDITABLE** | A ship nobody can read cannot be graded, and did not happen for audit purposes | **23 ships / 30d** |
| **G2** | **Reverted, regressed, or re-fixed within 7d** | `D=0` | Durable-fix doctrine (CREDIBLE-105) | **18 ships / 30d** |
| **G3** | **Duplicate of already-shipped work** | `W=0` | META-063 no-new-duplicates; mine-before-build | **7 title clusters / 30d** |
| **G4** | **Coverage claimed with no depth tier** | `V=0` | Shop rule 8: green is not covered | see `e2e/DEPTH.md` pattern |
| **G5** | **Public-facing claim with no receipt** | `T=0` | Shop rule 1: facts over vibes | |

G1 is the load-bearing one. Twenty-three un-auditable ships in a month is not a
documentation problem; it is a hole in the audit trail large enough that the
mission-ship ratio cannot be computed honestly without naming it.

## Verdict bands

| Verdict | Condition | Where it goes in the release note |
|---|---|---|
| **SHIP OF RECORD** | `M>=2`, `Q>=11`, no gate tripped | Headline |
| **SOLID** | `M>=2`, `Q` 8-10 | Mentioned |
| **LIGHTS-ON** | `M=1`, `Q>=8` | Counted, not celebrated |
| **MOTION** | `M=0` | Waste column |
| **DEBT** | any gate tripped | Debt column, named, with cost |

## The release-note audit

The weekly artifact. Six sections, in this order, and **the debt column is
never omitted** (a release note without one is marketing, not an audit).

1. **Mission-ship ratio** (Goal 3, target `>=2/3`): ships with `M>=2` over total real ships.
2. **Signal-to-noise**: real ships over total commits. Automated no-op commits are not ships.
3. **Ships of record**: what actually moved, each with a receipt.
4. **Lights-on**: what kept it running.
5. **Debt column**: gates tripped, named, with cost.
6. **THE BINARY**: did it move? (section (1) of `mission-scoreboard.sh`.)

### Honesty rules

- **Noise is not shipped work.** In the sampled week, 518 commits landed on
  `main` and 414 of them (80%) were `chore(backlog): coherence sync - 0 gaps
  closed`. Any throughput figure that counts those is false. The SessionStart
  banner's "45 ships, ~1.9/hr" is drawn from the unfiltered count.
- **Un-auditable ships are reported as a count, not skipped.** They are the
  error bar on every other number in the audit.
- **`M` is stated by a named grader,** machine or person, and the auditor's
  identity is recorded. Machine-proposed `M` is a prior, and is labelled as one.

## Usage

```bash
scripts/dev/release-audit.py                  # default 7d window
scripts/dev/release-audit.py --since 30d      # custom window
scripts/dev/release-audit.py --worksheet      # per-PR grading sheet, M left blank
scripts/dev/release-audit.py --json           # machine-readable
```

The script computes `Q` and the gates mechanically and emits `M` only as a
**prior**. Filling in `M` is the grader's job. It refuses to print a
mission-ship ratio from priors alone, because a ratio computed from unread tags
is exactly the kind of number this rubric exists to stop.

## Related

- `docs/MISSION.md` — the ribbon, the Goals, the Scoreboard
- `AGENTS.md` — the 4 pillars, ship discipline, durable-fix doctrine
- `docs/process/RESEARCH_INTEGRITY.md` — evidence standards
- `scripts/ci/test-release-note-voice-lint.sh` — voice rules on release-note prose
