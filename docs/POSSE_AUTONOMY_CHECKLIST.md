# Posse Autonomy Checklist

**Purpose:** Specify the required autonomous behaviors for Posse (`repairman29/posse`) to operate as a self-scheduling, self-directed component of the Chump fleet.

**Status:** Initial definition (MISSION-108)

---

## Core Autonomous Behaviors

### 1. **Scheduled Execution**

**Requirement:** Posse must run on a deterministic schedule without manual intervention.

- [ ] Scheduled via launchd (macOS) or systemd equivalent (Linux)
- [ ] Schedule defined in `scripts/plists/` or equivalent configuration
- [ ] Start interval configurable via environment variable (e.g., `POSSE_SCHEDULE_INTERVAL`)
- [ ] Automatic restart on crash or unexpected termination
- [ ] Supervisor (`launchctl list` or equivalent) confirms active state

**Related:** RESILIENT-069 (farmer heartbeat), COM.CHUMP.AUTONOMY-CRON.PLIST.EXAMPLE pattern

---

### 2. **Deterministic Task Selection**

**Requirement:** Posse must pick and execute tasks (findings/filings) without human selection.

- [ ] Task selection logic documented and deterministic (not random)
- [ ] Dependency awareness: respects task `depends_on` constraints before execution
- [ ] Priority-aware: orders tasks by urgency (priority × age)
- [ ] Fallback behavior defined when no tasks are available (e.g., sleep/noop)
- [ ] Task selection query meets performance SLA (< 1s)

**Related:** autonomy_loop.rs `pick_next_task()`, task_db::task_list_unblocked_for_assignee()

---

### 3. **Execution Verification**

**Requirement:** Posse must validate that its work completed as intended.

- [ ] Post-execution verification step defined (not skipped)
- [ ] Acceptance criteria defined for each task (task contract)
- [ ] Verification can detect failure (timeouts, rejection, incomplete output)
- [ ] Failed tasks are marked as such (not silently marked done)
- [ ] Verification output is logged for operator audit

**Related:** autonomy_fsm.rs (Verifying state), VerificationOutcome

---

### 4. **State Mutation via Canonical APIs**

**Requirement:** Posse must update task/gap state using only documented APIs, never direct mutations.

- [ ] State changes routed through task_db API (task_update, task_mark_done, etc.)
- [ ] No direct SQL writes to task tables
- [ ] Mutations emit to ambient.jsonl for observability
- [ ] Lease/claim logic respects existing atomic-claim guarantees
- [ ] Rollback paths defined (task can be reset to `open` after failed execution)

**Related:** task_db module, atomic-claim semantics (INFRA-498)

---

### 5. **Error Handling & Halt Signals**

**Requirement:** Posse must respect safety guardrails and emit halt signals when appropriate.

- [ ] Detects and logs unrecoverable errors (malformed task, missing dependency)
- [ ] Exits with non-zero code on halt conditions (no silent swallowing)
- [ ] Emits `kind=halt_autonomy` to ambient.jsonl when execution cannot proceed
- [ ] Operator escalation path defined (RESILIENT-274 quiet gate)
- [ ] Graceful degradation: does not hang or loop infinitely on error

**Related:** RESILIENT-274 (operator-escalation-registry.txt), autonomy_fsm.rs Failed state

---

### 6. **Observability & Health Signals**

**Requirement:** Posse must emit structured events so the fleet can monitor its health.

- [ ] Emits `kind=autonomy_tick` at start and completion
- [ ] Emits `kind=task_executed` per executed task (with task_id, status, duration)
- [ ] Emits `kind=verification_passed` / `kind=verification_failed` per task
- [ ] Heartbeat logged (age monitored by farmer / infra-watcher)
- [ ] Task count + success rate tracked for dashboard / KPI reports

**Related:** ambient.jsonl schema, fleet-doctor liveness checks

---

### 7. **Credential & Permission Management**

**Requirement:** Posse must safely handle credentials and respect permission boundaries.

- [ ] API credentials (GitHub, holler, etc.) loaded from environment or secure store
- [ ] Credentials never logged or committed to state.db
- [ ] Task execution respects tool-approval gates (does not bypass `--dangerously-*` mode)
- [ ] MCP bridge initialized before task execution (if task requires external tools)
- [ ] Credential refresh checks before each task (INFRA-622 / INFRA-2124)

**Related:** INFRA-622 (auth modes), mcp_bridge module, agent_factory initialization

---

### 8. **Memory & Context Injection**

**Requirement:** Posse must inject relevant memory to improve task execution.

- [ ] Memory database query on task selection (keyword search by title + repo)
- [ ] Memory context (playbooks, gotchas, procedures) injected into task brief
- [ ] Memory-search failures do not block task execution (graceful fallback)
- [ ] Memory coverage documented (which task classes have prior episodes)

**Related:** autonomy_loop.rs `fetch_task_memory_context()`, AUTO-009

---

### 9. **Lease & Concurrency Control**

**Requirement:** Posse must coordinate with other fleet agents and not double-execute tasks.

- [ ] Atomic claim before task execution (CAS / try_claim_gap pattern)
- [ ] Lease TTL enforced (stale leases reaped, not held forever)
- [ ] Lease owned by assignee (`CHUMP_AUTONOMY_ASSIGNEE`) for audit trail
- [ ] Concurrency tests verify no dual execution across multiple Posse instances
- [ ] Lost-lease recovery defined (task requeued if Posse crashes mid-execution)

**Related:** atomic-claim (INFRA-498), crate::chump_atomic_claim

---

### 10. **Logging & Audit Trail**

**Requirement:** Posse must maintain logs suitable for incident diagnosis.

- [ ] All executed tasks logged with task_id, command, output, result
- [ ] Log rotation / cleanup defined (logs/autonomy-cron.log aged after N days)
- [ ] Sensitive data (credentials, PIIs) stripped from logs
- [ ] Log format machine-parseable (JSON preferred, CSV acceptable)
- [ ] Operator can reconstruct task history from logs (deterministic replay)

**Related:** autonomy-cron.sh logging pattern, logs/autonomy-cron.log

---

## Posse-Specific Integrations

### 11. **Portfolio Scanning**

**Requirement:** Posse's core mission is autonomous portfolio discovery and health scanning.

- [ ] `scan-portfolio.mjs` runs on schedule (not manual)
- [ ] Produces structured findings (HOLLER fileFinding format)
- [ ] De-duplication: checks holler before filing (no duplicate reports)
- [ ] Integrates with holler backend (HOLLER_SUPABASE_URL, HOLLER_ANON_KEY)
- [ ] Dry-run mode available for validation (not required for cron, but testable)

**Related:** repairman29/posse `scan-portfolio.mjs`, EFFECTIVE-374

---

### 12. **Organ Sweep (Code-Posse Integration)**

**Requirement:** Posse works alongside `almanac` to audit code configuration and wiring drift.

- [ ] `almanac/scripts/organ-sweep.mjs` runs on schedule
- [ ] WIRING / CONFIG / LIVEMAP organs queried per repo
- [ ] New findings filed into holler using `reporter=almanac-<organ>`
- [ ] Previous findings deduplicated (holler dedupe_hash lookup)
- [ ] Coverage gaps documented (which repos have shallow inspection only)

**Related:** EFFECTIVE-389, EFFECTIVE-398, almanac organ-sweep.mjs, INFRA-3472

---

## Exit Criteria

For a Posse autonomy implementation to be considered complete:

1. **All 12 behaviors above are implemented and tested**
2. **Schedule triggers are verified active** (launchd loaded, systemd enabled, or equivalent)
3. **At least one full autonomous cycle** has run end-to-end and successfully filed a finding or completed a task
4. **Ambient events are flowing** to the observability layer (proof: kind=task_executed in ambient.jsonl)
5. **Manual steps have been identified and documented** (in the POSSE_AUTONOMY_AUDIT.md report)

---

## References

- **Autonomy infrastructure:** autonomy_loop.rs, autonomy_fsm.rs, task_db.rs
- **External dependencies:** repairman29/posse (scan-portfolio.mjs, holler integration)
- **Fleet observability:** ambient.jsonl schema, fleet-doctor checks
- **Safety rails:** RESILIENT-274 (quiet gate), INFRA-622 (auth modes)
- **Related gaps:** MISSION-103 (parent umbrella), MISSION-010 (mission of record)

