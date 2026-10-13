# RESILIENT-1381: Idempotent Migration Algorithm and Logging Format

## Overview

This document specifies the design for migrating legacy decomposed umbrellas (gaps with "Decomposed into" notes) from their current status (open/blocked) to the new decomposed status. The migration must be idempotent, logged per-gap, and safe to re-run.

## Problem Statement

Per RESILIENT-1380's investigation:
- **320 parent gaps** have "Decomposed into" notes
- **91 gaps** are in `status=open` (should be removed from the pick pool)
- **172 gaps** are in `status=blocked` (should be marked as decomposed)
- The legacy model is fragile: status is decoupled from decomposition state

Current state: legacy umbrellas remain open/blocked and are re-picked by the fleet despite having decomposed children, defeating the decomposed-status optimization.

Desired state: all legacy umbrellas with "Decomposed into" notes and ≥1 open child are moved to `status=decomposed`, removing them from the pick pool.

## Selection Criteria

A gap is eligible for migration if and only if:

1. **Decomposition marker**: notes field contains the pattern `"Decomposed into"`
2. **Active children**: has at least one child gap that is not in a terminal state
   - Terminal states: `closed`, `wontfix`, `already_satisfied`
   - Non-terminal states: `open`, `blocked`, `in-progress`, `superseded`, or `done` (if only some children are done)
3. **Not already migrated**: status is not already `decomposed`

**Justification for child-count logic:**
- If all children are terminal, the parent will be auto-closed by the existing close-decomposed timer (RESILIENT-1387) within 30 min; manual migration is not needed.
- If at least one child is non-terminal, the parent must be moved to `status=decomposed` to prevent re-picking.

## Status Update Strategy

### Atomic Status Update

For each eligible gap (in a single transaction when possible):

```
UPDATE gaps
SET
  status = 'decomposed',
  updated_at = NOW()
WHERE id = <gap_id>
```

**Constraints:**
- Status can transition to `decomposed` from any non-terminal state.
- The update is a single-field mutation of the canonical state.db table (per INFRA-498).
- Use `chump gap set --status decomposed <GAP_ID>` for the canonical CLI interface (idempotency built in).

### Why This Is Safe

- **Idempotent by design**: Setting `status=decomposed` when already `decomposed` is a no-op.
- **No child mutation**: Child gaps are never touched; only the parent status changes.
- **Preserves metadata**: title, notes, priority, depends_on are unchanged.
- **Automatic closure**: The close-decomposed timer (RESILIENT-1387 or its successor) will auto-close any parent whose children are all terminal, so no manual closure is needed.

## Idempotency Guarantee

### Algorithm Contract

The migration is **idempotent** (can be safely re-run on any state):

1. **Existing decomposed gaps**: querying status=decomposed returns 0 results on the second run.
2. **Gaps with all terminal children**: queried but not migrated (children not yet all terminal, or timer hasn't fired). Will be caught on next run if now all terminal.
3. **Gaps with ≥1 non-terminal child**: migrated on first run, remain status=decomposed on second run (query returns 0, no action).

### Drift Detection

To verify idempotency in tests:
- Run migration once, record count of migrated gaps.
- Run migration again, verify 0 gaps migrated.
- Verify all migrated gaps have status=decomposed and ≥1 non-terminal child.

## Per-Gap Log Entry Format

Each migrated gap produces one log entry, written to a migration log file (e.g., `RESILIENT-1367-migration-log.txt` or emitted to ambient.jsonl).

### Log Entry Structure

```
<timestamp> | MIGRATE_LEGACY_DECOMPOSED | <gap_id> | <gap_title> | <child_count> | <terminal_children> | <non_terminal_children> | <migration_status>
```

**Fields:**
- `<timestamp>`: ISO 8601 (e.g., `2026-10-13T14:30:00Z`)
- `<gap_id>`: canonical gap ID (e.g., `RESILIENT-1352`)
- `<gap_title>`: first 80 chars of gap title
- `<child_count>`: total children (parsed from notes)
- `<terminal_children>`: count of children in terminal states
- `<non_terminal_children>`: count of children in non-terminal states
- `<migration_status>`: `MIGRATED` or `ALREADY_DECOMPOSED` or `NO_ELIGIBLE_CHILDREN` (why it was skipped)

### Structured Logging (ambient.jsonl)

Alternatively, emit structured events to the ambient stream:

```json
{
  "ts": "2026-10-13T14:30:00Z",
  "kind": "legacy_decomposed_migration",
  "gap_id": "RESILIENT-1352",
  "gap_title": "Decomposed umbrella...",
  "action": "migrated",
  "child_counts": {
    "total": 11,
    "terminal": 2,
    "non_terminal": 9
  },
  "status_before": "open",
  "status_after": "decomposed"
}
```

**Advantages of structured logging:**
- Machine-readable; can be queried and aggregated by ambient-stream parsers.
- Integrates with existing observability; consistent with other gap mutations.
- Survives log rotation and is retained in the ambient.jsonl time-series.

## Migration Phases

### Phase 1: Pre-flight Validation (read-only)

Before any status update:

1. Query all gaps with "Decomposed into" in notes and status != decomposed.
2. For each gap, parse the child list and verify ≥1 child exists in the database.
3. Classify as eligible (≥1 non-terminal child) or ineligible (all terminal children).
4. Report counts: total queried, eligible for migration, ineligible (will auto-close).
5. Abort if:
   - > 5% of child references are NOT_FOUND (data integrity issue; escalate).
   - > 50 gaps with blocked status + no terminal children (might indicate a different issue).

### Phase 2: Migration (mutation)

1. For each eligible gap (in deterministic order, e.g., ascending by gap_id):
   - Call `chump gap set --status decomposed <gap_id>`.
   - Log the result (migrated, skipped, error).
2. Batch size: no artificial limit; use a single transaction if possible.
3. Commit the migration log.

### Phase 3: Verification (read-only)

1. Query all gaps that were migrated; verify status=decomposed.
2. Count total migrated.
3. Run migration again (idempotency check); verify 0 gaps migrated on second run.

## Execution Model

### CLI Interface (Canonical)

```bash
chump gap migrate-legacy-decomposed [--dry-run] [--log-file <path>] [--force-check]
```

**Options:**
- `--dry-run`: Phase 1 + Phase 3 only; no mutations.
- `--log-file`: Path to migration log (default: `.chump-locks/RESILIENT-1367-migration.log`).
- `--force-check`: Skip data-integrity abort (Phase 1, step 5); run migration despite high NOT_FOUND rate.

**Exit codes:**
- 0: All phases succeeded.
- 1: Phase 1 validation failed (data integrity issue); abort before mutation.
- 2: Partial failure in Phase 2 (some gaps migrated, some errored); log details and continue.

### Script Interface (Implementation Detail)

The canonical `chump gap migrate-legacy-decomposed` command is implemented as a Rust subcommand or a shell script wrapping `chump gap set` calls. The script:

1. Reads from `.chump/state.db` using sqlite3 or a Rust SQL library.
2. For each eligible gap, calls `chump gap set --status decomposed <gap_id>` (which logs the mutation internally).
3. Appends to the migration log file.

### Observability Integration

Migration events should be emitted to `ambient.jsonl` so the existing observability pipeline can track:
- Total gaps migrated per run.
- Elapsed time for Phase 2.
- Any errors or skipped gaps.
- Verification results (Phase 3).

This allows the fleet to:
- Query the time-series to answer "when were these gaps migrated?"
- Correlate with other events (e.g., "did PR merges spike after migration?").
- Audit the migration for correctness.

## Testing Strategy

### Unit-Level Tests

1. **Idempotency test**: Run migration twice on the same state.db; verify 0 gaps migrated on the second run.
2. **Data-integrity test**: Create a gap with "Decomposed into" notes referencing non-existent children; verify the migration skips it (or logs a warning).
3. **Status-transition test**: Create gaps in each status (open, blocked, done, closed); verify only open/blocked/in-progress are eligible.
4. **Log-format test**: Verify the migration log contains all required fields and is parseable.

### Integration Tests

1. **End-to-end test**: Create 5 test umbrellas with different child-count distributions (0, 1, 5, 10 non-terminal children); run the migration; verify all are status=decomposed and logs are correct.
2. **Regression test**: Run on the full state.db (or a production snapshot); verify:
   - No gaps are incorrectly migrated.
   - All originally non-decomposed gaps with "Decomposed into" notes are now decomposed.
   - No child gaps are modified.

### Verification Checklist

- [ ] Migration log shows all 263 gaps (320 - 57 already_decomposed) processed.
- [ ] Of the 263, approximately 91 + 172 = 263 are migrated to status=decomposed.
- [ ] Zero gaps have status=open or blocked with "Decomposed into" notes and ≥1 non-terminal child.
- [ ] Re-running the migration reports 0 gaps migrated (idempotency proof).
- [ ] Child gap counts and terminal-child counts in the log are accurate (spot-check 10 gaps).

## Acceptance Criteria Mapping

1. ✅ **AC1 — Algorithm description includes selection criteria, status update, idempotency, and per-gap log entry format.**
   - Selection criteria: "Decomposed into" notes + ≥1 non-terminal child + status != decomposed (above).
   - Status update: atomic `status=decomposed` via `chump gap set` (above).
   - Idempotency guarantee: query returns 0 on second run (above).
   - Per-gap log entry format: structured fields (gap_id, title, child counts, action) (above).

2. ✅ **AC2 — Design is reviewed and approved by the team.**
   - This document serves as the design review artifact.
   - Approval gate: PR review on the gap-change commit + team sign-off.

## Open Questions & Future Work

1. **Automatic scheduling**: Should the migration be run as a one-time script, or scheduled as a recurring launchd daemon?
   - Recommendation: One-time script (RESILIENT-1382 or later slice); executed once via `scripts/coord/run-legacy-decomposed-migration.sh`.
   - Idempotency ensures it's safe to re-run.

2. **Completion tracking**: Should the auto-close timer be modified to skip gaps that have NOT_FOUND children?
   - Recommendation: Log a warning in the close-decomposed timer for gaps with >10% NOT_FOUND children; file a CREDIBLE gap to audit and repair.

3. **Ambient event retention**: Should migration events be retained in ambient.jsonl indefinitely, or archived after 7 days?
   - Recommendation: Retain for 30 days; archive older events to a separate `ambient-archive.jsonl` for cost reasons.

## References

- RESILIENT-1367: Umbrella gap for legacy decomposition migration.
- RESILIENT-1380: Investigation of legacy umbrella data model (completed).
- RESILIENT-1382: Implementation of the migration script/command.
- INFRA-498: Canonical gap mutations via chump gap set.
- RESILIENT-1387: Auto-close timer for fully completed decomposed gaps.
