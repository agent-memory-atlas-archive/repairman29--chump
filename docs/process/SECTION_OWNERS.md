# CHUMP_PLAYBOOK.md — section ownership (META-172 slice, META-535)

`docs/process/CHUMP_PLAYBOOK.md` does not exist yet (tracked by the rest of
META-172). This table is filed ahead of that doc so the ownership mapping is
fixed and reviewable now; once CHUMP_PLAYBOOK.md lands, its sections must
match this table exactly.

| Section | Owner (curator lane) |
|---|---|
| §1 | orchestrator |
| §2 | orchestrator |
| §3 | handoff |
| §4 | handoff |
| §5 | observability |
| §6 | external-collab |
| §7 | infra-watcher + shepherd |
| §8 | all (cross-cutting) |

When the CI gate in META-172 (`scripts/ci/test-chump-playbook-freshness.sh`)
fails on a given section, the owning curator lane above is responsible for
the fix.
