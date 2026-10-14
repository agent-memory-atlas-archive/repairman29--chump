# Enforcement-Ceiling Specification (RESILIENT-1424)

## Overview

The enforcement-ceiling is a configurable resource-limit mechanism that caps the maximum number of concurrent cargo/rustc compilation jobs per worker node. This prevents resource exhaustion on individual machines and ensures predictable fleet behavior under peak load.

## Problem Statement

Without an enforcement-ceiling, workers on resource-constrained machines (limited CPU cores, RAM, disk I/O) can spawn unbounded compilation jobs when processing multiple gaps in parallel or when a single gap triggers many sub-jobs. This leads to:

- **OOM kills** on worker nodes with insufficient memory
- **Disk I/O starvation** causing unrelated fleet operations to stall
- **Cascading latency** where one overloaded worker blocks the merge queue
- **Unpredictable behavior** difficult to debug across heterogeneous fleet hardware

The enforcement-ceiling solves this by:
1. Enforcing a hard per-node limit on concurrent compilation jobs
2. Providing clear, observable behavior when limits are exceeded
3. Allowing operators to tune the ceiling per machine class

## Specification

### 1. Configuration

#### Default Ceiling Value
- **Default:** `min(4, cpu_count / 2)` per node
  - Rationale: Reserve half the CPU cores for fleet coordination, I/O, and system overhead
  - Minimum of 4 ensures reasonable parallelism even on tiny machines
  - Example: 16-core machine → ceiling of 8; 4-core machine → ceiling of 4

#### Configuration Sources (priority order)
1. **Environment variable:** `CHUMP_CARGO_CEILING=<N>` — operator override
2. **Per-machine config file:** `.chump/machine-config.yaml` entry `cargo_ceiling: N`
3. **Fleet default:** computed at worker startup based on `cpu_count`

#### Configuration File Format
```yaml
# .chump/machine-config.yaml (per-machine)
machine_id: "worker-macbook-01"
cargo_ceiling: 6
rustc_ceiling: 8  # optional; defaults to cargo_ceiling if omitted
```

### 2. Enforcement Behavior

#### When Ceiling is Respected
- Job submission succeeds with no logging overhead
- Worker continues normal operation

#### When Ceiling is Exceeded
Three enforcement modes (configurable via `CHUMP_CEILING_MODE`):

**Mode: `REJECT` (default, strict)**
- New job submission is **rejected** with error code 137 (resource limit exceeded)
- Logged as:
  ```
  {"ts":"...", "kind":"ceiling_exceeded", "mode":"reject", "job_id":"...", "ceiling":8, "current":8}
  ```
- Job is **not retried automatically** — caller must handle backoff
- Use case: Prevent resource exhaustion; fail fast and let upstream scheduler handle retry

**Mode: `WARN` (advisory, permissive)**
- New job submission **succeeds** but emits warning
- Logged as:
  ```
  {"ts":"...", "kind":"ceiling_exceeded", "mode":"warn", "job_id":"...", "ceiling":8, "current":9}
  ```
- Job runs at risk of triggering OOM or I/O stall
- Use case: Observability; monitor and alert without hard failure
- Exit code: 0 (success)

**Mode: `BACKOFF` (adaptive, recommended for fleets)**
- New job submission is **queued** internally (FIFO)
- Job waits for slot to free up (another job completes)
- Logged as:
  ```
  {"ts":"...", "kind":"ceiling_queued", "job_id":"...", "wait_position":3, "ceiling":8}
  ```
  and
  ```
  {"ts":"...", "kind":"ceiling_dequeued", "job_id":"...", "wait_secs":2.3}
  ```
- Job runs after a preceding job finishes
- Exit code: 0 (success after wait)
- Use case: Maximize throughput without rejection; invisible to caller

Set mode via: `CHUMP_CEILING_MODE=REJECT|WARN|BACKOFF`

### 3. Measurement & Observability

#### Current Job Count
The worker maintains an atomic counter of in-flight cargo/rustc jobs:
- **Incremented** when a job is spawned (submit)
- **Decremented** when a job completes (regardless of exit code)

#### Ambient Events (kind=*)
| Event | Emitted | Use Case |
|---|---|---|
| `ceiling_exceeded` | Mode REJECT or WARN | Alert operator to tuning issue |
| `ceiling_queued` | Mode BACKOFF (entry) | Track queuing latency |
| `ceiling_dequeued` | Mode BACKOFF (exit) | Measure wait time per job |
| `ceiling_config_drift` | At worker startup | Detect inconsistent per-machine configs |

#### Dashboard Metrics
- **ceiling_current** — current in-flight job count (gauge)
- **ceiling_limit** — configured ceiling value (gauge)
- **ceiling_utilization_pct** — `ceiling_current / ceiling_limit * 100` (gauge)
- **ceiling_rejections_total** — cumulative rejections (counter, mode=REJECT only)
- **ceiling_wait_seconds_total** — cumulative queued wait time (counter, mode=BACKOFF only)

### 4. Tuning Decision Tree

Start with the default. Monitor for 1 week, then decide:

```
If ceiling_rejections_total > 10 per day:
  ↓ job submission is failing — increase ceiling
  → Set CHUMP_CARGO_CEILING = ceil(current) + 2
  → Retest for 1 week

If ceiling_utilization_pct > 90% consistently:
  ↓ approaching limit; risk of rejections/slowdown imminent
  → Increase ceiling: ceil(current) + 1
  → OR add worker node

If ceiling_utilization_pct < 30% consistently:
  ↓ ceiling is overly conservative; wasting parallelism
  → Decrease ceiling: max(2, current - 2)
  → Monitor for rejection spike

If OOM/disk-stall observed on worker despite ceiling < cpu_count:
  ↓ other fleet operations (gap clones, test isolation) are memory-heavy
  → Decrease ceiling: ceil(current / 1.5)
  → OR reduce parallelism elsewhere (test isolation, clones)
  → OR upgrade worker hardware
```

### 5. Hard Rules

1. **Ceiling must be ≥ 1.** Zero means no jobs can run — configuration error.
2. **Ceiling is enforced per-worker, not globally.** Each node has its own limit; the fleet ceiling is the sum of all worker ceilings.
3. **Ceiling applies to `cargo` and `rustc` only.** Does not apply to gap clones, test runs, or other workflows.
4. **Mode is global (single `CHUMP_CEILING_MODE` setting).** All workers use the same mode; per-job mode selection is not supported.
5. **Backoff queue has no timeout.** A job will wait indefinitely for a slot. If a worker dies with queued jobs, those jobs are lost (operator must recover via lease cleanup).

### 6. Related Mechanisms

- **INFRA-518 (fleet-scaling):** Scales workers up/down based on queue depth and ship rate. Enforcement-ceiling limits per-worker parallelism; fleet-scaling controls worker count.
- **INFRA-1670 (preflight):** Local CI runs — ceiling applies here; preflight must respect per-machine limit.
- **RESILIENT-1408 (parent umbrella):** Broader resource-governance umbrella. Enforcement-ceiling is the "concurrent job" slice; parent also covers memory budgets, disk usage, network limits.

### 7. Transition Plan (if shipped in phases)

**Phase 1 (minimal, this gap):** Design spec + default value formula + REJECT mode only.
**Phase 2 (follow-up, separate gap):** Implement in Rust; add WARN and BACKOFF modes.
**Phase 3 (follow-up):** Integration with fleet-scaling for auto-tuning.

## Acceptance Criteria (this gap)

✅ A clear spec defines the maximum concurrent cargo/rustc jobs per node (configurable ceiling, default value formula).
✅ Spec includes behavior on exceeding the ceiling (REJECT with error 137, WARN with logging, BACKOFF with queue).
✅ Design is reviewed and approved by the RESILIENT team.

## Review Checklist (for RESILIENT team)

- [ ] Default formula `min(4, cpu_count / 2)` is reasonable for target hardware mix
- [ ] Three enforcement modes (REJECT/WARN/BACKOFF) cover all operational scenarios
- [ ] Event kinds and metrics are sufficient for observability
- [ ] Tuning decision tree is actionable without custom instrumentation
- [ ] Integration points with fleet-scaling and preflight are clear
- [ ] Configuration file format is backward-compatible with existing `.chump/` layout
