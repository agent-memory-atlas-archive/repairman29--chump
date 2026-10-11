# MISSION-123 — duplicate close

Shed-on-breach for the node capacity planner is already on main (#5225, fixed up in #5288).

- AC1: `shed_target()` returns `shed` when load > `HARD_LIMIT_PCT`; plan JSON records `shed.action`.
- AC2: sheds the highest-numbered (lowest-priority) worker unit, never the last one.
- AC3: logs `auto-size shed triggered`.
- AC4: normal-load budget math unchanged.

Verified: `bash scripts/ci/test-node-capacity-plan.sh` passes all cases.
