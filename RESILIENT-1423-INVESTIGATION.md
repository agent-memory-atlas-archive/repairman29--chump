# RESILIENT-1423: Leg-2 Auto-Size Implementation Investigation

## Executive Summary

The "leg-2" auto-size enforcement for cargo/rustc jobs is implemented across **three layers**:
1. **chumpd** (supervisor daemon) — derives initial CARGO_BUILD_JOBS from RAM + CPU
2. **worker-run.sh** — node-aware runtime clamp per active worker count
3. **run-fleet.sh** — aggregate concurrency limiter (FLEET_SIZE × CARGO_BUILD_JOBS ≤ nproc)

All three enforce the same principle: **prevent rustc oversubscription** (the 2026-08-22 CJ incident where 14 workers × 4 jobs/worker = 56 rustc threads on a 4-core box).

---

## Implementation Details

### Layer 1: chumpd (Initial Derivation)

**File:** `crates/chumpd/src/main.rs:81-113`

**Function:** `derive_cargo_build_jobs(total_ram_gb: Option<f64>, cpus: usize) -> usize`

**Logic:**
```rust
// Line 83-88
fn derive_cargo_build_jobs(total_ram_gb: Option<f64>, cpus: usize) -> usize {
    let cpus = cpus.max(1);
    match total_ram_gb {
        Some(gb) if gb > 0.0 => (((gb * 0.5) / 1.2) as usize).clamp(1, cpus),
        _ => 4.min(cpus),
    }
}
```

**Derivation Formula:**
- **With known RAM:** `floor((RAM_GB × 0.5) / 1.2)` clamped to `1..=cpus`
  - Rationale: 1.2 GB per rustc job; budget half of total RAM for builds
  - Example: 24 GB RAM → `(24 × 0.5) / 1.2 = 10 jobs` (assuming ≥10 cpus)
- **Without RAM:** Fallback to `4.min(cpus)` — safe conservative default

**Enforcement Hook (chumpd spawn):**

Line 273-274, 293:
```bash
build_jobs=$(cargo_build_jobs)
eprintln!("chumpd: worker {agent_id} CARGO_BUILD_JOBS={build_jobs} (derived from RAM/cpus)");

command
    .env("CARGO_BUILD_JOBS", build_jobs.to_string())
```

Each worker spawned by chumpd inherits this pre-computed value as an environment variable.

**Tests:** `crates/chumpd/src/main.rs:715-724`
```rust
#[test]
fn build_jobs_scale_with_ram_and_clamp() {
    assert_eq!(derive_cargo_build_jobs(Some(24.0), 16), 10);
    assert_eq!(derive_cargo_build_jobs(Some(24.0), 4), 4);
    assert_eq!(derive_cargo_build_jobs(Some(1.0), 8), 1);
    assert_eq!(derive_cargo_build_jobs(None, 8), 4);
}
```

---

### Layer 2: worker-run.sh (Node-Aware Runtime Clamp)

**File:** `scripts/dispatch/worker-run.sh:46-54`

**Logic:**
```bash
if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
    _cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    _cores="${_cores:-$(sysctl -n hw.ncpu 2>/dev/null || true)}"
    _cores="${_cores:-1}"
    _workers_up="$(pgrep -fc '[w]orker.sh' 2>/dev/null || true)"
    [[ "${_workers_up:-0}" -lt 1 ]] && _workers_up=1
    _auto_jobs=$(( _cores / _workers_up ))
    [[ "$_auto_jobs" -lt 1 ]] && _auto_jobs=1
    export CARGO_BUILD_JOBS="$_auto_jobs"
fi
```

**Enforcement Principle:**
- Detects **how many workers are currently running** on the node (`pgrep`)
- Divides available cores by active worker count
- Formula: `CARGO_BUILD_JOBS = nproc / active_worker_count` (≥1)

**Example:**
- 8 cores, 2 workers up → `8 / 2 = 4 jobs/worker`
- 4 cores, 4 workers up → `4 / 4 = 1 job/worker`
- 4 cores, 14 workers up → `4 / 14 = 0` → clamped to 1

**Important:** Explicit `CARGO_BUILD_JOBS` env var **bypasses this clamp** (line 46 check).

**Test Coverage:** `scripts/ci/test-worker-run-node-aware.sh`
```bash
ok "4 cores / 4 active workers -> CARGO_BUILD_JOBS=1"
ok "8 cores / 2 active workers -> CARGO_BUILD_JOBS=4"
ok "explicit CARGO_BUILD_JOBS env still wins over auto-compute"
```

---

### Layer 3: run-fleet.sh (Aggregate Concurrency Limiter)

**File:** `scripts/dispatch/run-fleet.sh:309-347`

**Enforcement Hook (Lines 311-347):**

```bash
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"

# INFRA-3659: cap AGGREGATE cargo concurrency (FLEET_SIZE * CARGO_BUILD_JOBS)
# to this host's core count
if [[ "$FLEET_SIZE" != "0" ]]; then
    _fleet_nproc="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    if [[ "$_fleet_nproc" =~ ^[0-9]+$ ]] && (( _fleet_nproc > 0 )) && \
       (( FLEET_SIZE * CARGO_BUILD_JOBS > _fleet_nproc )); then
        _fleet_size_before=$FLEET_SIZE
        _cargo_jobs_before=$CARGO_BUILD_JOBS
        
        # Prefer trimming FLEET_SIZE first (cheaper than reducing per-job concurrency)
        if (( FLEET_SIZE > _fleet_nproc )); then
            FLEET_SIZE=$_fleet_nproc
        fi
        # Then reduce FLEET_SIZE further if still oversubscribed
        while (( FLEET_SIZE * CARGO_BUILD_JOBS > _fleet_nproc && FLEET_SIZE > 1 )); do
            FLEET_SIZE=$(( FLEET_SIZE - 1 ))
        done
        # Finally, clamp CARGO_BUILD_JOBS if needed
        if (( FLEET_SIZE * CARGO_BUILD_JOBS > _fleet_nproc )); then
            CARGO_BUILD_JOBS=$(( _fleet_nproc / FLEET_SIZE ))
            (( CARGO_BUILD_JOBS < 1 )) && CARGO_BUILD_JOBS=1
            export CARGO_BUILD_JOBS
        fi
        
        echo "[run-fleet] INFRA-3659: capped concurrency to nproc=$_fleet_nproc -> ..."
        printf '{"ts":"%s","kind":"fleet_concurrency_capped",...}\n' ... >> ambient.jsonl
    fi
fi
```

**Enforcement Principle:**
- **Invariant:** `FLEET_SIZE × CARGO_BUILD_JOBS ≤ nproc` (total rustc threads ≤ core count)
- **Clamping priority:** Worker count first, then per-worker jobs (preserves per-job speedup for single worker)
- **Observable signal:** Emits `kind=fleet_concurrency_capped` event to `ambient.jsonl`

**Example (the 2026-08-22 CJ incident):**
- Input: FLEET_SIZE=14, CARGO_BUILD_JOBS=4, nproc=4
- Step 1: FLEET_SIZE > nproc → FLEET_SIZE=4
- Step 2: Still 4×4=16 > 4 → Loop reduces FLEET_SIZE to 1
- Step 3: Still 1×4=4 > 4 (boundary case, equal is OK)
- Output: FLEET_SIZE=1, CARGO_BUILD_JOBS=4 (one worker can use all cores)

**Test Coverage:** `scripts/ci/test-run-fleet-core-cap.sh`
```bash
check "CJ replay: FLEET_SIZE clamped to nproc" "FLEET_SIZE=4 CARGO_BUILD_JOBS=1" "$out"
check "within-budget values untouched" "FLEET_SIZE=2 CARGO_BUILD_JOBS=2" "$out"
check "aggregate jobs clamped when FLEET_SIZE already <= nproc" "FLEET_SIZE=4 CARGO_BUILD_JOBS=1" "$out"
```

---

## Current Admission Path for Cargo/Rustc Jobs

### Cargo Job Admission Flow

1. **chumpd supervisor** spawns worker.sh child processes
   - Computes CARGO_BUILD_JOBS from system RAM/CPU
   - Exports as env var to each worker (fixed at spawn time)
   - Source: `crates/chumpd/src/main.rs:273, 293`

2. **worker-run.sh** is invoked by worker.sh
   - Runtime recompute: if CARGO_BUILD_JOBS not already set, divide nproc by active worker count
   - Clamps to ensure fair CPU distribution across concurrent workers
   - Source: `scripts/dispatch/worker-run.sh:46-54`

3. **run-fleet.sh** (fleet launcher) pre-flight validation
   - Aggregate check: FLEET_SIZE × CARGO_BUILD_JOBS must fit in nproc
   - Emits warning + ambient event if clamping occurs
   - Source: `scripts/dispatch/run-fleet.sh:309-347`

4. **Cargo invocation** (inside worker.sh)
   - Inherits CARGO_BUILD_JOBS from environment
   - Used by rustc via cargo's `-j` parallelism flag
   - No further clamps after admission

### Design Philosophy

**Three-layer redundancy:**
- **Layer 1 (chumpd)** — static RAM-based derivation at spawn
- **Layer 2 (worker-run.sh)** — dynamic load-balancing per node
- **Layer 3 (run-fleet.sh)** — aggregate safety net before fleet launch

**No bypass knob:** INFRA-2429 "zero-bypass thesis" — the cap is structural, not advisory. Systems with spare headroom should **raise the limits explicitly** rather than opt out.

---

## Summary Table

| Enforcement Point | File | Lines | Trigger | Observable Signal |
|---|---|---|---|---|
| **chumpd derivation** | `crates/chumpd/src/main.rs` | 83–113, 273–274 | Worker spawn time | `chumpd_worker_spawned` event, CARGO_BUILD_JOBS env in stderr |
| **worker-run runtime clamp** | `scripts/dispatch/worker-run.sh` | 46–54 | Each worker starts | Environment variable export (silent unless overridden) |
| **run-fleet aggregate cap** | `scripts/dispatch/run-fleet.sh` | 311–347 | Fleet launch | `fleet_concurrency_capped` event in ambient.jsonl + stderr log |

---

## Acceptance Criteria Met

✅ **AC1:** Source files containing the leg-2 auto-size logic are identified
   - `crates/chumpd/src/main.rs` (derivation from RAM/CPU)
   - `scripts/dispatch/worker-run.sh` (node-aware runtime clamp)
   - `scripts/dispatch/run-fleet.sh` (aggregate concurrency limiter)
   - Test files: `scripts/ci/test-mission-122-build-storm-autosize.sh`, `test-worker-run-node-aware.sh`, `test-run-fleet-core-cap.sh`

✅ **AC2:** Current admission path for cargo/rustc jobs is documented with line numbers
   - chumpd: lines 83–88 (derivation), 273–274 (spawn hook)
   - worker-run.sh: lines 46–54 (node-aware clamp)
   - run-fleet.sh: lines 309–347 (aggregate check + clamping)

✅ **AC3:** Short report added to ticket linking identified code locations (this document)
