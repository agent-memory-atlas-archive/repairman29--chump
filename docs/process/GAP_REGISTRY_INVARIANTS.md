# GAP_REGISTRY_INVARIANTS.md — CREDIBLE-039

Canonical list of invariants enforced by `test-gap-closure-consistency.sh`
(and, in future, the `chump gap audit-priorities` subcommand). Each invariant
is checked autonomously via the `dev.chump.premature-closure-watch` launchd
plist (15-min cadence).

## I-1: No orphan closed_pr

Every gap with `status=done` and `closed_pr=N` must have that PR actually
merged on GitHub. If the PR is open, closed-but-unmerged, or missing, the
gap is "prematurely closed" — the ship pipeline (`bot-merge.sh`) failed to
atomically flip status, or `state.db` was manually corrupted.

**Enforcement:** `test-gap-closure-consistency.sh` forward mode.
**ALERT kind:** `gap_drift_premature_close`.

## I-2: No stale post-merge gap

Every gap with `status=open` and `closed_pr=N` must have that PR *not yet*
merged on GitHub. If the PR is already merged, the gap should have been
flipped to `done` — something in the ship pipeline skipped the atomic close.

**Enforcement:** `test-gap-closure-consistency.sh` reverse mode.
**ALERT kind:** `stale_post_merge_gap`.

## I-3: Premature closure auto-fix

When I-1 detects a premature closure AND the referenced PR's mergeable
status is `BLOCKED` or `DIRTY` (i.e., the PR is not mergeable and the gap
was incorrectly marked `done`), the `--auto-fix` flag flips the gap back
to `status=in_progress` using `CHUMP_ALLOW_RECYCLE=1` internally.
The fix is logged via `kind=premature_closure_auto_fixed`.

**Enforcement:** `test-gap-closure-consistency.sh --auto-fix`.
**ALERT kind:** `premature_closure_auto_fixed`.

## I-3b: Reverse-mode auto-fix (future)

When I-2 detects a stale post-merge gap, a future `--auto-fix` extension
should run `chump gap ship <GAP-ID> --closed-pr <N>` to flip the gap to
`done` automatically. Not yet implemented because incorrect auto-ship
could close gaps whose ACs are genuinely unmet.

## Operator-block marker and the reopen guard (RESILIENT-1587)

To block a gap so that no sweeper reopens it, run `chump gap set X --status blocked --add-note "operator-block: <reason>"`. Every automated writer that flips a gap to `open` (`rot-reaper.sh`, `pr-failure-auto-rescue.sh`, `ghost-gap-reaper.sh`, `cooldown-transient-sweep.sh`, `outcome-verify-heal-consumer.sh`, `triage_bookkeeping_gaps.sh`, `stuck-pr-filer.sh`) goes through `scripts/lib/safe-reopen-gap.sh` (`safe_reopen_gap` / `gap_reopen_allowed`), which refuses when the gap is `status=blocked` and carries the `operator-block:` marker, or is blocked without an `INFRA-3832 auto-block` stamp. Only INFRA-3832 auto-blocked gaps (no `operator-block:` marker) may be reopened automatically. Any new writer of `--status open` must call the helper; `scripts/ci/test-gap-reopen-guard.sh` covers it.
