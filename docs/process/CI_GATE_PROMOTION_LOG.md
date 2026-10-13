# CI Gate Promotion Log

> INFRA-1869 (META-074 / INFRA-1861 slice d). Append-only log of CI gates
> that have been promoted from `--warn-only` (advisory) to `strict-fail`
> (mandatory). Once a gate is in this log, it MUST stay strict — demoting
> it requires an explicit `CI-Promotion-Reverted: <reason>` commit trailer
> AND a new entry below documenting the demotion + why.
>
> Enforcement: `scripts/ci/test-gate-promotion-no-regression.sh` parses
> this file and fails the build if any listed gate is currently
> `--warn-only` in `.github/workflows/ci.yml` (or sibling workflow files).

## Why this log exists

CI gates exist on a maturity ladder: file → warn-only → strict-fail.
The expensive direction is *backwards*: a strict gate that's flipped
back to warn-only because someone got tired of seeing failures silently
gives back the discipline. Without an explicit log, the regression is
invisible — a PR can demote a gate in a one-line diff that reviewers
miss. This log makes demotion an explicit, audited act.

## Schema

Each entry is a markdown sub-heading with a structured body:

```markdown
## <gate-name>

- **Promoted at:** YYYY-MM-DD HH:MM:SS UTC
- **CI file:** path/to/workflow.yml
- **CI line (anchor):** name-of-step OR line:NN
- **Promoted by:** <gap-id or commit-sha>
- **Reason:** <one-sentence why it should never demote>
- **Demoted at:** (only on demotion, with `CI-Promotion-Reverted:` trailer ref)
- **Demoted by:** (only on demotion, gap-id or commit-sha)
- **Demote reason:** (only on demotion, why we accepted the regression)
```

## Promoted gates (v1)

> The initial list is empty — this PR ships the framework. Gates promoted
> after this lands MUST be appended here. The fleet has several gates
> already running strict today (cargo fmt, cargo clippy -D warnings,
> docs-delta, env-vars-internal, gaps-integrity, etc.); back-filling those
> into this log is a follow-up gap so we don't conflate "promoted from
> warn-only" with "born strict".

## test-preflight-ci-parity

- **Promoted at:** 2026-05-29 00:00:00 UTC
- **CI file:** .github/workflows/ci.yml
- **CI line (anchor):** preflight-vs-CI parity smoke (INFRA-1867)
- **Promoted by:** INFRA-2120
- **Reason:** allowlist drift between `.github/workflows/ci.yml` and
  `chump preflight` is the rank-2 CI-rot class (~15% of recent CI failures
  per docs/strategy/CI_REVIEW_2026-05-29.md Lever 4). Gate must stay strict
  so a CI-config addition without a matching preflight mirror (or
  exceptions entry) fails at the workflow step instead of leaking out as
  silent "local-green-CI-red" surprises. Also fired locally by the
  pre-commit hook (see CLAUDE.md "Local CI discipline"). The slug
  `test-preflight-ci-parity` matches the script basename, which is
  referenced in `bash scripts/ci/test-preflight-ci-parity.sh` on the
  promoted step.

## Demoted gates

> Hopefully this stays empty. Every entry here is a discipline regression
> that an operator accepted as the lesser evil. Track 'em.

## preflight-ci-parity new-gate auto-recognize regression (RESILIENT-550)

- **CI file:** .github/workflows/ci.yml
- **CI line (anchor):** preflight-ci-parity new-gate auto-recognize regression (RESILIENT-550)
- **Demoted at:** 2026-10-13 20:40:00 UTC
- **Demoted by:** INFRA-8125
- **Demote reason:** the auto-recognize FEATURE regressed (a gate defined in the
  same PR diff is flagged UNMIRRORED instead of recognized), turning this
  regression test red on every PR and deadlocking the whole merge pipeline
  (0/17 armed PRs landable). Demoted to advisory (continue-on-error) so the
  pipeline can flow; the step still runs + emits ci_parity_drift. NOTE: this is
  the RESILIENT-550 regression test, not the promoted test-preflight-ci-parity
  drift gate (that stays strict). Re-promote when INFRA-8125 repairs in-diff
  detection. Pairs with Phase R3 (META-195 consensus admin-merge) — root is
  --admin letting unmirrored gates accumulate.


## Adding an entry (workflow)

When promoting a CI gate from `--warn-only` to strict:

1. In the same PR that flips the gate:
2. Append a new entry to "Promoted gates" with all fields filled
3. Commit body MUST cite the gate name explicitly so the audit log
   surfaces it
4. The next `test-gate-promotion-no-regression.sh` run validates that
   the gate is now strict in the workflow file

When (reluctantly) demoting:

1. In the same PR that flips the gate back:
2. Add `CI-Promotion-Reverted: <one-sentence-reason>` to the commit body
   (the pre-push hook checks for this trailer)
3. Update the existing entry under "Promoted gates" to mark `Demoted at`
   + `Demote reason` (don't remove — preserve audit trail)
4. Move the entry to "Demoted gates" section
5. File a follow-up INFRA-NEW gap to fix the underlying cause + re-promote

## Cross-references

- INFRA-1861 — META-074 child A epic (CI/QA 100% initiative)
- INFRA-1872 #2436 — ci_qa_score aggregate telemetry (this log's metric-layer companion)
- INFRA-1837 #2438 — bypass-frequency auditor (per-session shame loop)
- INFRA-1836 #2439 — CHUMP_NO_BYPASS strict-mode helper
