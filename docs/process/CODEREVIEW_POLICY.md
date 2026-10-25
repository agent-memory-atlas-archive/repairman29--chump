---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Code Review Policy (INFRA-AGENT-CODEREVIEW MVP)

The `scripts/coord/code-reviewer-agent.sh` agent reviews `src/*` PRs before auto-merge
fires. This document defines the auto-approve / concern / escalate matrix.

## Verdicts

The agent emits exactly one of three verdicts on the first line of its response:

| Verdict       | Exit code | Action                                                                 |
|---------------|-----------|------------------------------------------------------------------------|
| `APPROVE`     | 0         | `gh pr review --approve` — auto-merge proceeds                        |
| `CONCERN`     | 1         | `gh pr review --request-changes` — merge blocks                       |
| `ESCALATE`    | 2         | `gh pr comment` — human review required                                |
| `SKIP`        | 3         | Docs-only PR — no review run (strictly reserved for `DOCS_ONLY=1`)     |
| `ERROR`       | 4         | Could not fetch diff / missing CLI args — merge blocks                 |
| `UNAVAILABLE` | 5         | LLM gateway unavailable on `src/*` PR — emit `code_review_unavailable`, hold auto-merge (CREDIBLE-1529) |

## Auto-approve criteria (ALL must hold)

1. Tests pass on the PR branch (`cargo test --workspace` green in CI).
2. Diff is **under 200 LOC** (added + removed lines).
3. **No new `unwrap()` / `expect()`** in production code paths. Test-only code
   (`#[cfg(test)]`, `tests/`, `*_tests.rs`) is exempt.
4. **No new top-level dependencies** added to any `Cargo.toml`.
5. Diff matches the cited gap's acceptance criteria (when a gap is referenced).
6. No obvious bugs, security issues, or panic-inducing changes.

If all six hold the agent emits `APPROVE`.

## Raise `CONCERN` when

- Any auto-approve criterion fails.
- New `unwrap()` / `expect()` in production code that should be `?` or `match`.
- New panics, `todo!()`, `unimplemented!()`, `unreachable!()` in production paths.
- Obvious logic bugs (off-by-one, swapped args, wrong condition).
- Missing error handling on a fallible call.
- Missing tests for new public API surface.
- Diff drifts from gap acceptance criteria (e.g. PR claims to fix bug X but
  also refactors module Y — the refactor should be a separate PR per the
  "≤ 5 commits, ≤ 5 files" rule in CLAUDE.md).

## Escalate to human (`ESCALATE`) when

The agent **always** escalates, never auto-approves, when the diff touches:

- `scripts/git-hooks/*` — pre-commit/pre-push guards (silent stomp risk).
- `scripts/coord/bot-merge.sh` — the ship pipeline itself.
- `scripts/coord/code-reviewer-agent.sh` — this agent (no self-approval).
- `.claude/*` — agent settings, hooks, slash commands.
- Anything matching `*CHUMP_TOOLS_ASK*` (e.g. the hardcoded ask-list in
  `src/tool_ask.rs` — security boundary).

The agent also escalates when:

- It cannot confidently judge the change (unfamiliar subsystem, ambiguous
  business logic, requires runtime context).
- The diff exceeds the prompt size limit (~80KB raw diff).
- The Anthropic API returns malformed output.

## Docs-only PRs (`SKIP`)

If `gh pr diff <PR> --name-only` returns only `docs/`, `*.md`, or `README*`
files, the agent skips the review entirely (exit 3). These PRs auto-merge
without code review by design — they cannot break the build.

## Integration with `bot-merge.sh`

When `bot-merge.sh --auto-merge` detects a PR that touches `src/*` or
`crates/*/src/*`, it invokes the agent **before** enabling auto-merge:

```bash
scripts/coord/code-reviewer-agent.sh <PR> --gap <GAP-ID> --post
case $? in
    0) gh pr merge --auto --squash ;;            # APPROVE
    1) echo "Code-reviewer raised concerns — merge blocked." ;;
    2) echo "Escalated to human — merge blocked." ;;
    3) gh pr merge --auto --squash ;;            # SKIP (docs-only ONLY)
    5)                                           # UNAVAILABLE (CREDIBLE-1529)
       # Emit kind=code_review_unavailable to .chump-locks/ambient.jsonl
       # (counted over trailing 7d by `chump kpi report` as unreviewed_src_merges_7d)
       # and hold auto-merge so an unreviewed src/* PR is never silently treated as approved.
       echo "Code-reviewer gateway unavailable — emitted kind=code_review_unavailable; merge held." ;;
    *) echo "code-reviewer-agent errored — merge blocked." ;;
esac
```

### Gateway-unavailable policy (`CREDIBLE-1529`)

Exit code `3` (`SKIP`) is reserved **strictly** for docs-only PRs (`DOCS_ONLY=1`).
When a PR touches `src/*` or `crates/*/src/*` and `code-reviewer-agent.sh` cannot
obtain a Tier-2 review from `chump llm-complete` (either because no LLM auth path
is configured or because the gateway returns empty/non-zero), the script prints
`UNAVAILABLE: reviewer gateway unavailable (no provider configured for chump llm-complete)`
and exits `5` (`UNAVAILABLE`), never `3`.

`scripts/coord/bot-merge.sh` handles exit `5` in a dedicated branch:
1. Emits `kind=code_review_unavailable` (registered in `docs/observability/events.d/code_review_unavailable.yaml`) to `.chump-locks/ambient.jsonl` with `pr`, `gap_id`, `exit_code: 5`, `policy: "hold"`, and `reason: "reviewer_gateway_unavailable"`.
2. Holds auto-merge (`exit 1`) so an unreviewed `src/*` PR is never conflated with an approved or docs-only PR.
3. `chump kpi report` aggregates `kind=code_review_unavailable` events over a trailing 7-day window as `unreviewed_src_merges_7d`.

## MVP scope vs deferred work

**In MVP (this PR):**
- `code-reviewer-agent.sh` script with APPROVE/CONCERN/ESCALATE/SKIP verdicts.
- `bot-merge.sh` integration: invoked for any PR touching `src/*` or
  `crates/*/src/*`, blocks auto-merge on CONCERN/ESCALATE.
- Sensitive-path escalation list (above).
- Docs-only short-circuit.
- Calls Claude API directly via `curl` + `ANTHROPIC_API_KEY` from `.env`.

**Deferred to follow-up gaps:**
- GitHub branch-protection rule requiring a `code-reviewer-bot` review (needs
  a dedicated GitHub App or PAT for the bot identity).
- INFRA-AGENT-ESCALATION integration for the ESCALATE verdict (Slack ping,
  human notification routing).
- Per-domain reviewer specialisation (security-sensitive paths reviewed by a
  dedicated security prompt; ML/eval paths by a dedicated eval prompt).
- Caching identical-diff verdicts to avoid double-spend on retries.
- Structured `gh pr review` line comments tied to specific diff hunks (MVP
  posts a single overall review comment).
- Reviewer telemetry: track agreement rate vs human override over time so we
  can tune the auto-approve criteria.

## Tuning

Concrete-criteria tuning is preferred over prompt tuning. Edit the criteria
list above and the matching string in `scripts/coord/code-reviewer-agent.sh` together
when adjusting thresholds. Keep them in sync.

### Gate-file `--auto-merge` refusal (`CREDIBLE-1526` / `CREDIBLE-1576` / `CREDIBLE-1577`)

Any PR whose `--paths` or branch diff touches a ship-gate file
(`.github/workflows/*`, `scripts/ci/*`, `scripts/git-hooks/*`,
`scripts/coord/bot-merge.sh`, `scripts/coord/code-reviewer-agent.sh`,
`crates/chump-preflight/*`, `crates/chump-ship/*`, `*verified-wait*`) is
refused with exit `2` when `--auto-merge` is passed to either:
- `chump dispatch <GAP> --auto-merge` (`src/dispatch.rs::check_workspace_auto_merge_gate`,
  emitting `kind=dispatch_auto_merge_refused` before spawning the agent), or
- `scripts/coord/bot-merge.sh --auto-merge` (`bot_merge_gate_arm_refused`).

Gate-file PRs land exclusively via the independent review organ
(`chump-review-organ.service`), which labels unapproved PRs `review-held`
and `review-needs-mutants` and merges head-pinned only after a written
`VERDICT: APPROVE` with mutant-kill receipts.

### Rust auto-merge policy (`CREDIBLE-1583`)

Every Rust caller that invokes `gh pr merge ... --auto` (`crates/chump-ship/src/lib.rs`,
`crates/chump-ship/src/manual_ship.rs`, and `crates/chump-integrator/src/daemon.rs`)
gates the arm through `chump_ship::arm_policy::require_allowed_at` with
`GateAction::Arm`:
- `HOLD_LABELS` includes `review-held` and `review-needs-mutants` alongside
  `no-auto-merge`, `hold`, `do-not-merge`, and `CHUMP_HOLD` (case-insensitive).
- When `action == GateAction::Arm` and `gh pr view` or JSON parsing fails,
  `require_allowed_at` **fails closed** (`HoldReason::ReadError`), emitting
  `kind=pr_arm_skipped_hold` with `reason="read_error:<msg>"` and refusing to
  arm auto-merge. (`GateAction::Touch` retains fail-open semantics on transient
  read errors.)
- `scripts/ci/test-arm-policy.sh` enforces that no executable `gh pr merge ... --auto`
  call appears in `crates/` outside those three gated call sites.
