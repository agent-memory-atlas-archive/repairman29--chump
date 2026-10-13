# MISSION-123 (re-filed) — closed as duplicate, fifth occurrence

This gap ID was re-filed as open a fifth time after being closed as a
duplicate of PR #5225 (commit `3528c5ade`, "node capacity planner sheds on
hard-limit breach") four times already — see `docs/MISSION-123-NOTES.md`,
`docs/MISSION-123-DUP-NOTES-2.md`, `docs/MISSION-123-DUP-NOTES-3.md`,
`docs/MISSION-123-DUP-NOTES-4.md`.

Re-verified on this branch that all 4 acceptance criteria still hold on
`origin/main`:

1. **AC1** — `shed_target()` in `scripts/ops/node-capacity-plan.sh` returns
   `"shed"` once load strictly exceeds the hard limit.
2. **AC2** — on shed, the lowest-priority (highest-numbered) worker is
   stopped and `plan.json` records `shed.action`/`shed.target`.
3. **AC3** — log line `auto-size shed triggered: ...` is emitted verbatim.
4. **AC4** — normal loads and the last-worker guard are untouched/correct.

`bash scripts/ci/test-node-capacity-plan.sh` passes clean, including the
`MISSION-123: planner shed-on-breach integration` section. No new code
needed — closing as a duplicate again rather than re-implementing existing
coverage. Precedent: `docs/MISSION-123-NOTES.md`,
`docs/MISSION-123-DUP-NOTES-2.md`, `docs/MISSION-123-DUP-NOTES-3.md`,
`docs/MISSION-123-DUP-NOTES-4.md`.

**Process note:** this gap keeps getting re-filed as open despite being
closed four prior times (PRs #5225-closure, #5232, #5236, #5239, #5240).
The underlying re-filing mechanism should be investigated so the fleet
stops burning claim/ship cycles on an already-shipped slice — flagged here
rather than hand-fixed, per the no-hand-work discipline.

## Sixth occurrence

Re-verified at HEAD `0b5704586`: `bash scripts/ci/test-node-capacity-plan.sh`
passes clean (AC1-AC4). Already delivered by #5225 / #5288; no new code.

## Seventh occurrence

Re-verified at HEAD `94a6cc381`: `bash scripts/ci/test-node-capacity-plan.sh`
passes clean (AC1-AC4). Already delivered by #5225 / #5288; no new code.

## Eighth occurrence

Re-verified at HEAD `59673ec4b`: `bash scripts/ci/test-node-capacity-plan.sh`
passes clean (AC1-AC4). Already delivered by #5225 / #5288; no new code.

## Ninth occurrence

Re-verified at HEAD `3ed1f2580`: `bash scripts/ci/test-node-capacity-plan.sh`
passes clean (AC1-AC4). Already delivered by #5225 / #5288; no new code.

## Tenth occurrence

Re-verified at HEAD `2859134e9`: `bash scripts/ci/test-node-capacity-plan.sh`
passes clean (AC1-AC4). Already delivered by #5225 / #5288; no new code.

## Eleventh occurrence

Re-verified at HEAD `4d123f1bc`: `bash scripts/ci/test-node-capacity-plan.sh`
passes clean (AC1-AC4). Already delivered by #5225 / #5288; no new code.
