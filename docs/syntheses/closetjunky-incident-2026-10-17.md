# Closetjunky node wedge incident — 2026-10-17

**Date:** 2026-10-17T02:10Z  
**Gap:** RESILIENT-1611  
**Incident class:** 21 — node admission ceiling insufficient; memory thrash + sshd unresponsive  
**Root cause:** INFRA-8219 admission check did not count cargo fix/clippy/test; no on-node dead-man watchdog  

## What happened

Closetjunky (4-core, 8GB fleet coordinator node) became SSH-unresponsive at 02:10Z when:
1. A Sonnet dispatch ran `cargo fix --workspace --all-targets` (cost: 62% CPU, 900s)
2. A second `claude -p` process was spawned for a different gap
3. Load spiked to 14.1 on 4 cores (3.5x threshold); system entered memory thrash
4. SSH authenticated but the kernel could not allocate memory for shell processes
5. System remained wedged until operator power-cycled it from the cabinet at 03:04Z

**Evidence:**
- 2026-10-17T02:04:00Z — load 14.1 on 4 cores, `cargo fix` at 62% CPU
- 2026-10-17T02:10:00Z — SSH publickey auth succeeds; shell timeout "Timeout, server not responding"
- 2026-10-17T03:04:50Z — node offline on tailnet (no Tailscale SSH fallback available)

## Root causes

### 1. INFRA-8219 admission ceiling incomplete

`src/admission_check.rs` only counted `cargo_job` in the database query, not `cargo_fix`, `cargo_clippy`, `cargo_test`, or `cargo_build`. When a Sonnet built a Rust gap, it inserted a `cargo_fix` record, but the second spawn saw only 0 active `cargo_job` records and admitted a second workspace build.

### 2. Node-level dead-man absent

The fleet had off-node monitoring (`scripts/ops/offnode-deadman-watch.sh`, RESILIENT-1247) but no on-node protection. When load spiked, no local process-killer ran to shed load before sshd wedged.

### 3. Tailscale SSH not enabled

Closetjunky had no Tailscale SSH fallback (`tailscale set --ssh`), so when sshd became unresponsive, the operator had to physically power-cycle from the cabinet.

## Fixes shipped (RESILIENT-1611)

### AC 1: Admission ceiling counts cargo fix/clippy/test/build

**File:** `src/admission_check.rs`

- Modified `count_active_cargo_jobs()` to query job types `["cargo_job", "cargo_fix", "cargo_clippy", "cargo_test", "cargo_build"]` instead of just `cargo_job`
- Added `get_cargo_job_type(cmd)` helper to classify commands into the correct job type
- Updated `insert_cargo_job()` to read the command string and record the specific type

**Behavior:** Now a `cargo fix` on one worker prevents a second workspace build from being admitted until the first completes.

### AC 2: Dispatch briefs forbid workspace-wide cargo on non-Rust gaps

**Mechanism:** The layer-aware dispatch model (`INFRA-8220`) already routes non-Rust gaps to Sonnet. Added explicit advisory to `docs/process/SUBAGENT_DISPATCH.md`:

> **Non-Rust gaps (shell/docs)**: Do NOT run workspace-wide `cargo fix`, `cargo clippy`, `cargo build`, or `cargo test --workspace`. These exhaust the admission ceiling and starve other workers. Run only targeted, file-specific cargo invocations if any.

**Enforcement:** Manual per dispatch brief (no hard gate yet); long-term: consider a hard gate in the dispatch layer.

### AC 3: Node-level dead-man installed on every owned node

**Files created:**
- `scripts/ops/load-aware-deadman.sh` — monitors load, memory, SSH responsiveness
- `scripts/ops/systemd/chump-load-aware-deadman.service` — systemd service unit
- `scripts/ops/systemd/chump-load-aware-deadman.timer` — 60-second check interval
- `scripts/setup/install-load-aware-deadman.sh` — idempotent installer
- `scripts/ci/test-load-aware-deadman.sh` — CI gate for unit file validity and function presence

**Thresholds:**
- **Load spike:** 1m load > 3x nproc for 10 minutes → kill newest `claude -p` process
- **Memory pressure:** MemAvailable < 5% of MemTotal for 5 minutes → kill newest `cargo` process
- **SSH unresponsive:** 15 minutes without shell response → systemd watchdog triggers reboot

**Instrumentation:** All actions emit `kind=deadman_*` events to `ambient.jsonl` for observability.

**Testing:** Dry-run mode (`CHUMP_DEADMAN_DRY_RUN=1`) logs actions without killing.

### AC 4: Tailscale SSH enabled on every owned node

Added to `scripts/setup/chump-node-install.sh`:
```bash
tailscale set --ssh 2>/dev/null || echo "tailscale-ssh enabled or unavailable"
```

This allows out-of-band SSH access even when the node's sshd is wedged, enabling faster recovery.

### AC 5: Incident recorded

This document records the incident as class 21 with full root-cause analysis, fixes shipped, and recovery steps.

## Recovery

**Immediate (2026-10-17T03:04:50Z):** Operator power-cycled closetjunky from the cabinet.

**Short-term (this PR):** Deploy admission ceiling fix, node dead-man, and Tailscale SSH to all owned nodes.

**Long-term:** 
- Monitor `kind=deadman_*` ambient events for patterns
- Tune load/memory thresholds if false positives occur
- Consider a hard gate in dispatch to refuse workspace cargo on non-Rust gaps

## Testing checklist

```bash
# Syntax validation
bash scripts/ci/test-load-aware-deadman.sh

# Install locally (idempotent)
bash scripts/setup/install-load-aware-deadman.sh

# Verify systemd unit files
systemctl --user status chump-load-aware-deadman.timer
systemctl --user status chump-load-aware-deadman.service

# Dry-run test (identify without killing)
CHUMP_DEADMAN_DRY_RUN=1 bash scripts/ops/load-aware-deadman.sh

# Monitor ambient events
tail -f .chump-locks/ambient.jsonl | grep deadman
```

## Lessons

1. **Admission ceiling gaps cascade:** INFRA-8219 was meant to prevent this exact scenario, but the implementation missed new job types. Always keep the admission control layer in sync with new process classes.

2. **On-node resilience beats off-node detection:** The off-node dead-man (`offnode-deadman-watch.sh`) could not help because:
   - It runs on a different node and cannot force a remote reboot
   - Tailscale SSH was not enabled, so the operator had no fallback SSH path
   - Local watchdog + Tailscale SSH is faster and more reliable

3. **Workspace builds are footguns on small nodes:** A single `cargo fix --workspace` on a 4-core machine is enough to wedge the node. Document this explicitly in dispatch briefs and consider a cost model.

4. **Systemd watchdog integration is powerful:** Combining a local load/memory checker with systemd watchdog allows automatic recovery without external intervention.

## References

- RESILIENT-1611 (this gap)
- INFRA-8219 (admission ceiling)
- INFRA-8220 (layer-aware dispatch defaults)
- RESILIENT-1247 (off-node dead-man witness)
- ZERO-WASTE-133 (the Sonnet dispatch that triggered the incident)
