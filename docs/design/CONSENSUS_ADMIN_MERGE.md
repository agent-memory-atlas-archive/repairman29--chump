---
doc_tag: design
owner_gap: META-545
slice_of: META-195
status: proposed
last_updated: 2026-09-15
---

# Design: Consensus-Based Admin-Merge (META-195 Phase 1)

## Problem

Admin-merge (`gh pr merge --admin --squash`) bypasses required checks. Today
that bypass is authorized either by the operator directly, or by an agent
acting as operator — both are a human-in-the-loop (HITL) decision made from
partial context. Each bypass hides a real CI-failure signal; if the fleet
keeps bypassing on the operator's say-so, the signal never gets acted on.

The fix is to make the bypass decision **consensus-based**: multiple curator
roles vote, using the signals they already observe, and the tally — not a
single operator call — decides whether to admin-merge.

The substrate for this already exists and does not need to be rewritten:

- `crates/chump-coord/src/consensus.rs` — `ConsensusCoordinator`,
  `DecisionType`, `Vote`, `ConsensusDecision`, SHA256 vote-proof audit trail
- `chump vote` / `chump consensus-tally` CLI (META-159)
- `curator-opus-deliberator` role (META-162) — tallies votes, emits
  `kind=consensus_result`
- INFRA-2274 — a consensus merge gate already wired into
  `scripts/coord/bot-merge.sh` (~line 3754), running in **shadow mode**
  (`CHUMP_CONSENSUS_MERGE_GATE=1`): it computes a verdict via
  `chump consensus-tally` but only logs `kind=consensus_gate_would_block`
  and proceeds regardless.

This document specs what's missing to flip that gate from shadow to
enforce: the decision type, who votes and how, the tally threshold, and the
mode-switch procedure. It is Phase 1 (DESIGN) of the four-phase plan in the
META-195 gap description; Phase 2 (CODE) implements this spec.

## Decision type

Add `AdminMergeProposal` to the `DecisionType` enum in
`crates/chump-coord/src/consensus.rs`:

```rust
pub enum DecisionType {
    EscalationRequired,
    ResourceCritical,
    NetworkPartitionRecovery,
    FleetScaleChange,
    /// Should this PR be admin-merged (required checks bypassed)?
    /// Raised by bot-merge.sh when a PR is BLOCKED/red but the caller
    /// (operator-as-claude or an autonomous curator) believes the failure
    /// is not attributable to the PR's own change.
    AdminMergeProposal,
}
```

A vote is initiated per-PR, keyed by correlation ID `pr-<number>` (matches
the existing `chump vote pr-<N> ...` convention already used by the shadow
gate's log message). `VoteRequest.context` carries the structured signal
bundle described below so voters don't have to re-derive it.

## Who votes, and on what signal (auto-vote rules)

Four curator roles auto-vote — each already runs a loop
(`scripts/coord/*-loop.sh`) with visibility into a different slice of fleet
state, so no new polling infrastructure is needed. A fifth "vote" is the
operator's explicit override, which is not a curator vote but a
short-circuit (see below).

| Voter | Signal it inspects | Vote rule |
|---|---|---|
| `curator-opus-ci-audit` | Failure signature across open PRs (`ambient.jsonl` CI events, last 2h) | Same failure class on **N≥3** open PRs → `Approve` (shared-class = trunk contagion, not this PR's bug). Failure unique to this PR → `Abort`. |
| `curator-opus-shepherd` | `.chump-locks/trunk-red-detector-state.json` | Trunk-RED active → `Approve`, tagged `integration_trunk_red_emergency` in the vote's `context` field (this is a *conditional* approve — see Safety-rail tag below, not a blanket pass). Trunk-RED inactive → defer to the signal each role already owns (no independent opinion). |
| `curator-opus-handoff` | Whether the PR's own diff touches the failing check's surface (e.g. a `ci:` step it edited) | Diff touches the failing surface → `Abort` (real bug in scope). Diff is unrelated (e.g. docs-only PR failing on an infra flake) → `Approve`. |
| `curator-opus-deliberator` | Tallies; does not cast a first-order vote itself except as tie-breaker of last resort (see Quorum-not-reached) | N/A — deliberator's job is arithmetic, not opinion, to avoid it grading its own tally. |

**Operator explicit override.** If the operator (or operator-as-claude) sets
an explicit override flag (`CHUMP_ADMIN_MERGE_OPERATOR_OVERRIDE=<reason>` on
the `bot-merge.sh` invocation), the vote is recorded as `Approve` from
`session=operator` and the tally short-circuits to `PASSED` immediately —
this preserves today's HITL path as a strict superset, not a removed
capability. Every override emits `kind=agent_admin_merge` with
`override_used: true` for audit (Historian curator picks this up as a
lesson candidate if overrides cluster).

Each of the three opinionated roles votes independently based only on
signals visible to its own loop — no cross-role consultation before voting,
so the vote reflects genuinely independent evidence (this mirrors the
adversarial-verify pattern used elsewhere in the fleet: independent
observers, not a chain of approvals).

## Tally + threshold logic

Implemented in `scripts/coord/bot-merge.sh`, replacing the current
log-only shadow branch (~line 3826 onward) with a real tally call:

1. **Open vote window**: 60s default, configurable via
   `CHUMP_ADMIN_MERGE_VOTE_WAIT_S`. `bot-merge.sh` calls
   `chump vote pr-<N> --request --decision-type admin-merge-proposal` and
   then polls `chump consensus-tally pr-<N>` until the window elapses or
   quorum is met early.
2. **Quorum**: 3 of the 4 roles above must cast a real vote (`Approve` /
   `Abort`; `Timeout` does not count toward quorum, matching
   `Vote::is_committed()` in `consensus.rs`).
3. **Threshold**: 3-of-4 `Approve` passes outright. With only 3 votes cast
   (quorum floor), require **all 3** to `Approve` — a single `Abort` at
   quorum floor is treated as real signal, not noise, and fails the
   proposal. This is stricter than a bare majority deliberately: admin-merge
   bypasses a *required* check, so the default should lean toward `Abort`
   on any dissent unless there's enough of a crowd to outvote it.
4. **Safety-rail tag**: any `Approve` cast under the trunk-RED rule carries
   `context.tag=integration_trunk_red_emergency`. If a PASSED tally
   includes ≥1 safety-rail-tagged approval, the resulting admin-merge is
   itself tagged in the `kind=agent_admin_merge` audit event so a later
   Historian sweep can distinguish "genuine independent consensus" from
   "trunk-RED swept several PRs through at once."
5. **Quorum-not-reached** (fewer than 3 votes cast within the window,
   e.g. a curator loop is down): fall back to the existing operator-as-
   tie-breaker HITL path unchanged — this is not a new failure mode, it's
   today's behavior preserved as the fallback.

This reuses `ConsensusDecision::{Proceed, Abort, Inconclusive}` directly:
`Proceed` → admin-merge proceeds, `Abort` → blocked (files a follow-up gap
instead, does not silently drop the PR), `Inconclusive` (includes
quorum-not-reached) → operator tie-break.

## Relationship to the existing AUTO_ADMIN_MERGE_POLICY.md (META-209/210)

`docs/process/AUTO_ADMIN_MERGE_POLICY.md` already codifies a *different*,
narrower consensus path: it gates on `deliberator-opus`-tallied votes from
an unspecified voter pool, a fix-class title-prefix allowlist, a DIRTY
check, a T1-T4 quiet-window check, and an `admin-merge-hold` label. That
policy is orthogonal to this one — it governs *whether an agent may invoke
admin-merge at all* as a blanket policy gate; this document specs *how the
vote that feeds `chump consensus-tally` is actually produced* (who votes,
on what evidence, with what threshold) for the specific `AdminMergeProposal`
decision type. Phase 2 implementation should wire this into
`AUTO_ADMIN_MERGE_POLICY.md`'s "Consensus resolved" condition as the
concrete answer to "who votes and how," rather than leaving that condition
abstract. No change to the other four gate conditions (fix-class allowlist,
DIRTY check, T1-T4 quiet window, HOLD label) is proposed here.

## Mode switch procedure (SHADOW → ENFORCE)

Reuses the existing `CHUMP_CONSENSUS_MERGE_GATE` env var and its three
states already implemented in `bot-merge.sh` (~line 3762):

```
CHUMP_CONSENSUS_MERGE_GATE unset (or 0)  → gate skipped entirely
CHUMP_CONSENSUS_MERGE_GATE=1             → shadow (log only, never blocks)
CHUMP_CONSENSUS_MERGE_GATE=enforce       → blocking (this design's tally decides)
```

Phase 2 ships the `AdminMergeProposal` type, the four auto-vote hooks, and
the tally/threshold logic — but leaves `CHUMP_CONSENSUS_MERGE_GATE=1`
(shadow) unchanged in all launcher surfaces
(`launchd/com.chump.fleet-daemon.plist`,
`launchd/com.chump.opus-curator.plist`, `scripts/dispatch/run-fleet.sh`).
In shadow mode the new tally logic runs and emits
`kind=consensus_gate_would_block` / would-proceed exactly as today, so its
verdicts accumulate for review without any behavior change.

**Flip gate (Phase 4, not this doc):**

1. Observe shadow-mode tallies for ≥10 votes
   (`grep '"kind":"consensus_gate_would_block"' .chump-locks/ambient.jsonl | wc -l`
   plus the would-proceed equivalent).
2. Operator reviews the distribution: does the auto-vote tally agree with
   what the operator would have decided by hand, on the same PRs? Disagreement
   is the signal to fix a voter's rule, not to abandon the gate.
3. Operator sets `CHUMP_CONSENSUS_MERGE_GATE=enforce` in the shell rc (or
   plist env) across the three launcher surfaces.
4. Every subsequent enforcement decision emits `kind=agent_admin_merge` or
   `kind=agent_admin_merge_blocked` per `AUTO_ADMIN_MERGE_POLICY.md`'s
   existing audit format, plus the tally detail (`consensus_vote_count`,
   per-voter breakdown) from this design.
5. Rollback: setting the var back to `1` (shadow) or unsetting it is
   immediate and requires no code change — this is the same rollback path
   INFRA-2274 already offers today.

## Non-goals

- This document does not change the DIRTY-check, T1-T4-quiet-window, or
  `admin-merge-hold`-label conditions in `AUTO_ADMIN_MERGE_POLICY.md`.
- It does not implement a new voting UI or a new curator role — voting is
  a small addition to each of the four existing `*-loop.sh` scripts.
- It does not flip the gate to enforce mode — that is Phase 4, explicitly
  gated on operator review of shadow-mode data (see above).

## Acceptance for Phase 2 (forward pointer, not this gap's AC)

- `AdminMergeProposal` variant lands in `consensus.rs` with tests.
- Each of the three opinionated curator loops casts a real vote via
  `chump vote pr-<N> <±1|0> --reason '<signal>'` when a PR enters the
  admin-merge-candidate state.
- `bot-merge.sh`'s shadow branch calls the real tally instead of a stub,
  under the existing `CHUMP_CONSENSUS_MERGE_GATE=1` shadow behavior
  (log-only, non-blocking).
- A synthetic BLOCKED+green PR exercises the full tally end-to-end in a
  test harness, per the META-195 acceptance criteria.

## Operator approval

Pending — this document is submitted for operator review per META-545 AC3.
