# Posse Autonomy Audit Report

**Date:** 2026-10-14  
**Executed by:** MISSION-108  
**Checklist reference:** docs/POSSE_AUTONOMY_CHECKLIST.md  
**Status:** Initial audit — identified missing schedule triggers and manual steps

---

## Executive Summary

Posse (`repairman29/posse`) is a critical external fleet component responsible for autonomous portfolio discovery and finding filing into the holler knowledge base. This audit applied the POSSE_AUTONOMY_CHECKLIST to identify gaps between the *required* autonomous behaviors and the *current* implementation.

**Finding:** Posse is **partially autonomous**. Core logic is in place (portfolio scanning, holler integration), but **schedule triggers are not yet active** — portfolio scans and organ sweeps currently require manual invocation.

**Critical gaps identified:**
1. LaunchD / systemd schedule not configured or deployed
2. Autonomous task selection for finding filing not yet wired to holler
3. Verification step for scanned findings not formalized
4. Ambient event emission for Posse autonomy not yet integrated

---

## Audit Results by Behavior

### ✅ Requirement 1: Scheduled Execution

**Status:** **MISSING**  
**Finding:** No active schedule discovered.

- [x] Schedule pattern exists: `COM.CHUMP.AUTONOMY-CRON.PLIST.EXAMPLE` in chump repo serves as template
- [ ] Posse-specific schedule file not found in `repairman29/posse/scripts/plists/`
- [ ] LaunchAgent not loaded (`launchctl list | grep posse` returns empty)
- [ ] Cron/systemd configuration not present in expected locations
- [ ] Start interval not configurable via `POSSE_SCHEDULE_INTERVAL`

**Manual step:** Posse schedules must be installed via `chump bootstrap posse` or equivalent (not yet automated)

**Dependency:** Blocks all autonomous execution; required before any other behaviors can activate

---

### ✅ Requirement 2: Deterministic Task Selection

**Status:** **PARTIAL**  
**Finding:** Portfolio discovery is deterministic; finding-filing task selection is not yet wired.

- [x] Portfolio scanning logic is deterministic (scan-portfolio.mjs produces consistent output)
- [x] Dependency awareness could be built into task selection (not required yet for portfolio scan)
- [x] Priority ordering framework exists in chump autonomy_loop.rs
- [ ] Posse-side task selection not yet integrated with chump's task_db
- [ ] Finding filing currently requires manual invocation or external orchestration

**Manual step:** Operator must decide: (a) file findings immediately after scan, or (b) queue findings into task_db for Posse's own picker to select

**Dependency:** Upstream — wait for schedule (Req 1) before wiring task selection

---

### ⚠️ Requirement 3: Execution Verification

**Status:** **NOT FORMALIZED**  
**Finding:** Scans produce output, but verification acceptance criteria not yet defined.

- [ ] Acceptance criteria for "portfolio scan succeeded" not formalized
- [ ] Failure detection (e.g., scan hangs, partial results) not defined
- [ ] Success signal to feed back to Posse ("findings filed successfully") not wired
- [ ] Verification framework (FSM state) could be reused from chump autonomy_fsm.rs but not yet integrated

**Manual step:** Operator currently visually inspects findings before filing; no automated verification of scan completeness or finding quality

**Dependency:** Requires definition of acceptance criteria before filing findings at scale

---

### ✅ Requirement 4: State Mutation via Canonical APIs

**Status:** **PARTIAL**  
**Finding:** Holler integration is via documented API; state mutations follow holler schema.

- [x] Findings filed into holler using `fileFinding` API (repairman29/holler documented contract)
- [x] De-duplication logic checks holler before filing (dedupe_hash pattern)
- [x] No direct database writes observed; API-first pattern respected
- [x] Lease/claim logic not yet needed (findings are append-only, no mutual exclusion between multiple Posse instances)
- [ ] Ambient event emission for finding mutations not yet wired

**Manual step:** Findings must be manually validated before filing; operator spot-checks holler after scan

**Dependency:** Upstream — blocked by schedule (Req 1)

---

### ⚠️ Requirement 5: Error Handling & Halt Signals

**Status:** **MINIMAL**  
**Finding:** Basic error handling present; halt signals not yet formalized.

- [x] Unrecoverable errors logged (scan-portfolio.mjs catches try/catch blocks)
- [ ] Halt condition detection not defined ("when should Posse stop and escalate?")
- [ ] Ambient event `kind=halt_autonomy` never emitted from Posse
- [ ] Operator escalation path not wired (RESILIENT-274 quiet gate not yet used by Posse)
- [x] Timeouts implemented in scan-portfolio.mjs (respects SCAN_TIMEOUT env var)

**Manual step:** Operator must monitor scan logs manually for hangs or unexpected errors; no automatic escalation

**Dependency:** Blocks high-confidence autonomous operation without human oversight

---

### ⚠️ Requirement 6: Observability & Health Signals

**Status:** **MINIMAL**  
**Finding:** Scan produces console output; structured ambient events not yet integrated.

- [ ] `kind=autonomy_tick` never emitted by Posse
- [ ] `kind=task_executed` not wired
- [ ] `kind=verification_passed` / `kind=verification_failed` not emitted
- [ ] Heartbeat check (farmer / infra-watcher) not configured for Posse
- [ ] Task success metrics not exposed for dashboard

**Manual step:** Operator must read scan-portfolio logs manually; no machine-readable signal for fleet monitoring

**Dependency:** Critical for fleet trust (CREDIBLE pillar); without observability, Posse cannot be verified as running correctly

---

### ⚠️ Requirement 7: Credential & Permission Management

**Status:** **MANUAL**  
**Finding:** Credentials required; configuration is ad-hoc.

- [x] API credentials (HOLLER_SUPABASE_URL, HOLLER_ANON_KEY) loaded from environment
- [ ] Credentials never validated before scan (INFRA-622 credential-rotation not wired)
- [ ] Credential refresh loop not active (INFRA-2124 oauth-refresh pattern not used by Posse)
- [x] Tool approval gates respected (no --dangerously-* mode in current implementation)
- [x] MCP bridge not needed (Posse is JS/mjs, external to chump binary)

**Manual step:** Operator must set HOLLER_SUPABASE_URL and HOLLER_ANON_KEY in environment before scan; no automatic refresh

**Dependency:** Credentials must be valid for any autonomous operation; credential staleness will cause silent failures

---

### ⚠️ Requirement 8: Memory & Context Injection

**Status:** **NOT IMPLEMENTED**  
**Finding:** Portfolio scan has no awareness of prior findings or playbooks.

- [ ] Memory database not queried by Posse
- [ ] Prior-episode context not injected into scan
- [ ] Playbooks / gotchas for scanned repos not retrieved
- [ ] Coverage gaps not documented

**Manual step:** Operator must manually review prior findings and curate scan scope (e.g., exclude stale repos)

**Dependency:** Quality improvement (EFFECTIVE pillar); not blocking autonomy but will improve finding relevance

---

### ✅ Requirement 9: Lease & Concurrency Control

**Status:** **NOT NEEDED (APPEND-ONLY MODEL)**  
**Finding:** Portfolio filings are append-only (no mutual exclusion required).

- [x] De-duplication via holler dedupe_hash (idempotent, safe to replay)
- [x] Multiple Posse instances can run concurrently without collision
- [x] Lost-scan recovery defined (re-run scan safely; holler de-dupe prevents duplication)
- [ ] But: no lease tracking in .chump-locks for audit trail

**Manual step:** None required for concurrency; idempotent design handles multiple instances

**Dependency:** None blocking

---

### ⚠️ Requirement 10: Logging & Audit Trail

**Status:** **MINIMAL**  
**Finding:** Basic logging present; structured audit trail not yet formalized.

- [x] All scans logged (console output, sometimes captured to file)
- [ ] Log rotation not configured (logs will grow unbounded)
- [ ] Sensitive data not stripped (HOLLER_ANON_KEY potentially logged)
- [ ] Machine-parseable format not standardized (plain-text output, not JSON)
- [ ] Operator replay not possible (no structured logs with task_id, input params)

**Manual step:** Operator manually tails logs during scan; cannot replay from logs

**Dependency:** Audit trail required for incident diagnosis; currently blocks post-incident RCA

---

### ⚠️ Requirement 11: Portfolio Scanning

**Status:** **PARTIAL**  
**Finding:** Core scanning logic is solid; integration is ad-hoc.

- [x] scan-portfolio.mjs logic is deterministic and produces consistent findings
- [x] Holler integration (fileFinding API) implemented
- [x] De-duplication (dedupe_hash) prevents duplicates across runs
- [ ] Schedule not active (blocking autonomous execution)
- [x] Dry-run mode available for validation (`--dry-run` flag supported)

**Manual step:** Scans must be run manually (`npm run scan` from posse repo)

**Dependency:** Schedule must be active (Req 1) for this to run autonomously

---

### ⚠️ Requirement 12: Organ Sweep (Code-Posse Integration)

**Status:** **NOT ACTIVE**  
**Finding:** Organ sweep infrastructure exists in almanac; not yet scheduled or wired to Posse.

- [x] `almanac/scripts/organ-sweep.mjs` exists and can be run manually
- [ ] Sweep schedule not active
- [ ] Integration with Posse not yet formalized (separate process, not called by Posse)
- [ ] Findings from organ sweep not yet merged into Posse's filing pipeline

**Manual step:** Operator must run `node scripts/organ-sweep.mjs` from almanac repo manually

**Dependency:** Upstream — blocks autonomous drift detection (EFFECTIVE-389)

---

## Critical Path Dependencies

### Phase 1: Enable Portfolio Scanning Schedule (Req 1)
1. Create `repairman29/posse/scripts/plists/com.posse.portfolio-scan.plist` (copy from chump template)
2. Wire cron schedule in plist: `<integer>300</integer>` (every 5 min for testing; 3600 for production)
3. Install via `launchctl load` in Posse CI/bootstrap flow
4. Verify via `launchctl list | grep com.posse.portfolio-scan`

**Effort:** xs (2 files, config-only)  
**Owner:** Posse maintainer (external)

### Phase 2: Emit Ambient Events (Req 6)
1. Integrate chump's ambient.jsonl publisher (or JSON-over-curl equivalent)
2. Emit `kind=portfolio_scan_start` / `kind=portfolio_scan_complete`
3. Include finding count, holler dedupe hits, new-finding count
4. Log to chump's ambient.jsonl (or Posse's own ambient.jsonl if separate)

**Effort:** s (5-10 lines JS, JSON formatting)  
**Owner:** Posse maintainer or chump fleet

### Phase 3: Formalize Verification (Req 3)
1. Define acceptance criteria: "scan is complete iff all N repos queried and finding count > 0"
2. Add timeout/retry logic: if scan hangs >10 min, mark failed and escalate
3. Emit `kind=portfolio_scan_verification_failed` if acceptance criteria not met

**Effort:** m (decision on criteria + implementation)  
**Owner:** MISSION-010 owner (mission PM)

### Phase 4: Wire Organ Sweep Schedule (Req 12)
1. Create `almanac/scripts/plists/com.almanac.organ-sweep.plist`
2. Schedule every 6 hours (EFFECTIVE-389 analysis scope)
3. Ensure findings are filed into holler with `reporter=almanac-<organ>`

**Effort:** s (plist only)  
**Owner:** Almanac maintainer (external)

---

## Identified Manual Steps

| # | Step | Frequency | Rationale | Blocker? |
|---|---|---|---|---|
| 1 | Install Posse schedule (launchctl load) | Once per machine | No automated bootstrap flow yet | **CRITICAL** |
| 2 | Set HOLLER_SUPABASE_URL / HOLLER_ANON_KEY | Once per machine | Credentials not in secure store | Medium |
| 3 | Inspect portfolio scan output | Each scan (5m) | No automated verification | Low (can be removed once Req 3 done) |
| 4 | Validate findings before holler filing | Each scan (5m) | No QA gate yet | Low (async audit acceptable) |
| 5 | Monitor ambient events | Continuous | No alerting yet | Low (observability gap) |
| 6 | Rotate scan logs | Weekly | No automated cleanup | Low (can run 6 mo before filling disk) |

---

## Recommendations

### Immediate (unblock autonomous operation)
1. **[CRITICAL]** Implement Phase 1 (schedule activation). Without it, Posse remains manual.
2. **[CRITICAL]** Implement Phase 2 (ambient events). Without observability, fleet cannot verify Posse is working.
3. Set HOLLER credentials in environment (operationalization, not a code change).

### Short-term (confidence building)
4. Implement Phase 3 (verification acceptance criteria). Enables high-confidence autonomous operation.
5. Add log rotation + structured JSON logging (Req 10). Enables post-incident RCA.

### Medium-term (full fleet integration)
6. Implement Phase 4 (organ sweep schedule). Closes drift-detection gap (EFFECTIVE-389).
7. Wire memory context injection (Req 8). Improves finding relevance and deduplication.

### Long-term (optimization)
8. Move credential management to secure store (INFRA-622 equivalent for Posse).
9. Build Posse finding-filing into chump task_db (unified task selection across Chump + Posse).

---

## Conclusion

Posse has solid **core logic** (scanning, deduplication, API integration) but **lacks automation scaffolding** (schedule, observability, verification). The critical blocker is **schedule activation** (Req 1); without it, Posse cannot run unattended.

Once Phase 1 and Phase 2 are complete, Posse can begin autonomous operation under human observation (no verification gate yet). Phase 3 would enable full hands-off operation.

**Estimated effort to critical threshold (Phases 1–2):** **xs** (plist + ~10 lines JS)  
**Estimated effort to confidence threshold (Phases 1–3):** **s** (plist + verification logic + acceptance criteria decision)

**Next action:** File MISSION-109 (Posse schedule activation) as a blocker for full autonomy; mark MISSION-108 complete with this audit report.

