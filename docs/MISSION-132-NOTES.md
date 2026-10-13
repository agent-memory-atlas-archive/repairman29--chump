# MISSION-132 — closed as duplicate of already-shipped work

All acceptance criteria are satisfied on `main` by PR #5247 (`d7cb5d18e`):
`effective_max()` in `node-orchestrator.sh` already sizes workers from
`compute_worker_budget` via `plan.json`, and
`scripts/ci/test-mission-132-worker-budget-integration.sh` proves a
resource-limited node gets a reduced budget (4 passed, 0 failed).
