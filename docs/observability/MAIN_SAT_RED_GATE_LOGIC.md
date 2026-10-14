# Main-SAT Red Status: Gate Logic Documentation

> **RESILIENT-417 slice**: Documenting the existing gate logic for main-sat red reporting
> (RESILIENT-474, RESILIENT-1123)

## Overview

The **main-SAT (main-sustained, over time) red gate** is a diagnosticemission-critical signal that detects when the main branch's CI has been failing continuously for a sustained period, defaulting to **48 hours** (2,880 minutes). This document identifies the codebases and data structures that implement this logic.

## 1. Emission Location: `scripts/coord/lib/board-vitals.sh`

### Primary Emitter

The main-sat red detection is implemented in **`scripts/coord/lib/board-vitals.sh`** (lines 584-602), as part of the board-vitals health check loop.

**File:** `/scripts/coord/lib/board-vitals.sh`  
**Function:** `board_vitals_check()` (lines 416-665)  
**Relevant Section:** Lines 584-602 (Section 4c: main-sat gate sustained red)

### Entry Point and Flow

The board-vitals library is invoked by the **board-cycle beat** (`scripts/coord/board-cycle.sh`) every 30 minutes. The cycle calls `board_vitals_check()`, which performs a series of health checks, including the main-sat sustained-red detection.

**Invocation Context (RESILIENT-371, RESILIENT-410):**
- Lives on: board-cycle beat (30-minute cadence)
- Type: Non-merge watch (complements the merge SLA check)
- Environment: Currently invoked live on every board-cycle tick when `CHUMP_BOARD_VITALS_MAIN_RED_LIVE=1` (default 1)

### Main-SAT Red Emission Logic (Section 4c)

```bash
# ── 4c · main-sat gate SUSTAINED red (RESILIENT-1123, RESILIENT-416 slice) ─
# Same underlying span as 4/4b (_bv_main_red_span_min, section 3b) — no new
# log-scanning, this is purely an independently-configurable threshold +
# its own ambient kind so a consumer that only cares about the "main-sat"
# gate (as opposed to the 30m look-now page or the 48h structural-outage
# signal) can watch one kind without re-deriving the span itself. Default
# threshold matches the 48h precedent from RESILIENT-1128; distinct env
# var so the two thresholds can be tuned independently. Read-only: this
# section only ever emits a diagnostic event, never mutates state (AC2),
# and — because main_red_span resets to 0 the instant a benign status line
# lands — a transient red that clears before the window never trips it
# (AC3, mirrors the false-positive guarantee proven for RESILIENT-1128).
local main_sat_red_min
main_sat_red_min="${CHUMP_BOARD_VITALS_MAIN_SAT_RED_MIN:-2880}"
if (( main_red_span >= main_sat_red_min )); then
    # scanner-anchor: "kind":"main_sat_sustained_red"
    _bv_emit "main_sat_sustained_red" \
        "\"main_red_span_min\":${main_red_span},\"threshold_min\":${main_sat_red_min}"
fi
```

## 2. Data Structures for Red Status Tracking

### 2a. The Main-Red Span Calculation

The **main red span** is the foundational data structure that tracks how long main CI has been continuously failing in real-time.

**Function:** `_bv_main_red_span_min()` (lines 219-260)  
**Input:** `.chump-locks/ambient.jsonl` (the ambient event stream)  
**Output:** Integer minutes of continuous real-red span (0 if not currently red)

**Algorithm:**
1. Reads all `main_red_detected` events from the ambient log
2. Extracts the timestamp and status from each event
3. Defines "benign" statuses: `{no_runs, green, clean, passing, none, ok, ""}`
4. Walks backwards from the newest event
5. Counts consecutive non-benign (real-red) statuses
6. Returns the span in minutes: `(newest_epoch - oldest_consecutive_red_epoch) / 60`
7. **Key property:** Resets to 0 the instant a benign status line lands, preventing false positives on transient red that recovers within the window

**Data structure (Python logic):**
```python
BENIGN = {"no_runs","green","clean","passing","none","ok",""}
rows = []  # list of (epoch_timestamp, status_string) tuples

# Walk backwards while still real-red; span = newest - oldest-consecutive-red
if newest_status in BENIGN:
    span = 0
else:
    # find oldest consecutive red, calculate span
    span = (newest_epoch - start_epoch) // 60
```

### 2b. The Ambient Event Emission: `main_red_detected`

The red-status data originates from the **`main_red_detected`** ambient event, emitted by `scripts/ops/main-health-watchdog.sh` (INFRA-1656).

**Event Kind:** `main_red_detected` (lines 157-164, 209-216, 246-253, 266-273)

**Emitted Fields:**
- `ts` — ISO 8601 timestamp
- `kind` — `"main_red_detected"`
- `emitter` — `"main-health-watchdog"`
- `gate` — The failing CI gate/job name (or "none" if green/no-runs)
- `sha` — Short (12-char) commit SHA of the HEAD
- `run_url` — URL to the GitHub Actions run
- `head_sha` — Full commit SHA
- `gap_id` — ID of the filed P0 main-red gap (if any)
- `dry_run` — "0" (for test/dry-run distinction)
- `status` — One of: `success`, `failure`, `no_runs`, `deduped`, `filed`, `reserve_failed`

**Emission Contexts:**
- **Green main (success):** Status = success + gate=none, emitted as heartbeat to prove watchdog is alive
- **Red main (failure):** Status = filed or deduped, with gate set to the first failing job name
- **No CI runs yet:** Status = no_runs, gate=none
- **Already filed for this SHA:** Status = deduped, gap_id set to existing gap

### 2c. Downstream: The `main_sat_sustained_red` Ambient Event

**Event Kind:** `main_sat_sustained_red` (RESILIENT-1123)  
**Emitter:** `scripts/coord/lib/board-vitals.sh` (section 4c)

**Emission Condition:**
- Emitted only when `_bv_main_red_span_min() >= CHUMP_BOARD_VITALS_MAIN_SAT_RED_MIN`
- Default threshold: 2,880 minutes (48 hours)
- Tunable via: `CHUMP_BOARD_VITALS_MAIN_SAT_RED_MIN` environment variable

**Emitted Fields:**
- `ts` — ISO 8601 timestamp of the emission
- `kind` — `"main_sat_sustained_red"`
- `main_red_span_min` — The calculated continuous red span in minutes (integer)
- `threshold_min` — The configured threshold that triggered emission (integer)

**Example JSON Line:**
```json
{"ts":"2026-10-14T11:30:45Z","kind":"main_sat_sustained_red","main_red_span_min":2920,"threshold_min":2880}
```

## 3. Timestamp and Timing Behavior

### Red Span Reset Semantics

The red span **resets to 0 immediately** when:
1. A `main_red_detected` event with a benign status (green, clean, passing, no_runs, none, ok) is emitted
2. This resets even if the main branch recovered for only a few minutes and then turned red again

**Implication:** The span measures the **current continuous red streak**, not cumulative red time. A main branch that was red for 30 hours, green for 5 minutes, then red again for 20 hours will emit a span of ~20 hours (1,200 minutes), not 50 hours.

### Timing Diagram

```
Time:       T0          T1          T2          T3
Event:      RED        RED         GREEN       RED
Span Min:    0         60           0          30  ← resets on benign
```

At T3, if span = 30 min and threshold = 2,880 min, **no emission** (30 < 2,880).
If the red persists for 48 hours more (T3 → T4, +2,880 min), then span = 2,910 min and **emission fires**.

## 4. Configuration Parameters

**Environment Variables (in `scripts/coord/lib/board-vitals.sh`):**

| Env Var | Default | Purpose |
|---------|---------|---------|
| `CHUMP_BOARD_VITALS_MAIN_SAT_RED_MIN` | 2880 (48h) | Threshold in minutes for main-sat red emission |
| `CHUMP_BOARD_VITALS_MAIN_RED_MIN` | 30 | Threshold for the urgent 30-min main-red page (section 4) |
| `CHUMP_BOARD_VITALS_SUSTAINED_MAIN_RED_MIN` | 2880 (48h) | Threshold for the `sustained_main_red` event (sibling signal) |
| `CHUMP_BOARD_VITALS_MAIN_RED_LIVE` | 1 | Enable live watchdog invocation per board-cycle beat (vs. macOS-launchd-only) |
| `CHUMP_BOARD_VITALS_MAIN_HEALTH_BIN` | `scripts/ops/main-health-watchdog.sh` | Path to the watchdog binary (test hook) |
| `CHUMP_AMBIENT_LOG` | `.chump-locks/ambient.jsonl` | Path to the ambient event log |

## 5. The Watchdog: `scripts/ops/main-health-watchdog.sh`

**Location:** `scripts/ops/main-health-watchdog.sh` (INFRA-1656)  
**Cadence:** Invoked live by board-vitals.sh on every board-cycle tick (30-min beat) when enabled

**Algorithm (lines 80-275):**
1. Query the latest CI run on main via `gh run list --branch main --workflow CI --limit 1`
2. Parse the JSON response to extract: conclusion, headSha, URL, gate name, failed step
3. If conclusion = success → emit `main_red_detected` with status=success and exit
4. If conclusion = failure:
   - Walk jobs[*] to find the first failing job
   - Walk steps[*] within that job to find the first failing step
   - Extract gate name (job name) and failed_step
5. **Dedup check:** Scan open P0 `INFRA-NEW-MAIN-RED-*` gaps. If any gap's notes contain the current headSha, skip filing (dedup)
6. If not deduped → file a new P0 INFRA gap titled `INFRA-NEW-MAIN-RED-<YYYY-MM-DD>: <gate>` with:
   - Description: run URL, headSha, gate, failed step
   - Acceptance criteria: root-cause identified → fix PR → main CI green
   - Notes: dedup token (`sha=<headSha>`)
7. Emit `main_red_detected` with status=filed/deduped/no_runs/reserve_failed

**Exit Codes:**
- `0` — Normal (gap filed, deduped, no runs, or disabled)
- `2` — Internal failure (gh unavailable, malformed JSON, reserve failed)

## 6. Test Coverage and Validation

**Test File:** `scripts/ci/test-board-vitals.sh`

**Main-SAT Red Test Cases (RESILIENT-1123):**

```bash
echo "[test-board-vitals] RESILIENT-1123: main_sat_sustained_red fires past the 48h threshold"
_emitted "58h consecutive real-red span → main_sat_sustained_red emitted" \
    "$MS" '"kind":"main_sat_sustained_red".*"main_red_span_min":3480'
_notemitted "40m red span (well under 48h) → main_sat_sustained_red NOT emitted" \
    "$MS2" '"kind":"main_sat_sustained_red"'
_notemitted "long-past red span since recovered to green → main_sat_sustained_red NOT emitted" \
    "$MS3" '"kind":"main_sat_sustained_red"'
```

**Test Invariants:**
- AC1: Emits only when span ≥ threshold
- AC2: Read-only (no state mutation)
- AC3: No false positives on transient red that clears before window (verified by span-reset semantics)

## 7. Event Registry Entry

**Location:** `docs/observability/EVENT_REGISTRY.yaml` (lines 2314-2324)

```yaml
- kind: main_sat_sustained_red
  effect_metric: self
  emitter: scripts/coord/lib/board-vitals.sh (RESILIENT-1123, RESILIENT-416 slice)
  trigger: the live main_red_span (section 3b, RESILIENT-414) has held at a
    real-red streak for at least CHUMP_BOARD_VITALS_MAIN_SAT_RED_MIN minutes
    (default 2880 = 48h) — the main-sat gate's own independently-configurable
    sustained-red signal, sibling of sustained_main_red (RESILIENT-1128).
    Never fires on a transient red that clears before the window, since
    main_red_span resets to 0 the moment a benign status line lands.
  consumers: [ambient]
  fields_required: [ts, kind, main_red_span_min, threshold_min]
```

## Summary

| Aspect | Location | Details |
|--------|----------|---------|
| **Emission Logic** | `scripts/coord/lib/board-vitals.sh:584-602` | Threshold gate; emits only when span ≥ 2,880 min |
| **Span Calculation** | `scripts/coord/lib/board-vitals.sh:219-260` | Walks ambient `main_red_detected` events; resets to 0 on benign status |
| **Source Data** | `scripts/ops/main-health-watchdog.sh` | Emits `main_red_detected` events; files P0 gaps on failure |
| **Data Storage** | `.chump-locks/ambient.jsonl` | Append-only event log; parsed live each board-vitals cycle |
| **Configuration** | Environment variables | `CHUMP_BOARD_VITALS_MAIN_SAT_RED_MIN` (default 2,880 min) |
| **Event Kind** | `main_sat_sustained_red` | Emitted when span ≥ threshold; includes span and threshold fields |
| **Test Coverage** | `scripts/ci/test-board-vitals.sh` | Validates emission only on 48h+ span, transient red recovery |

---

**Gap:** RESILIENT-474 (RESILIENT-417 slice)  
**Acceptance Criteria:**  
✅ Documented location(s) in the RESILIENT codebase where main-sat red status is emitted  
✅ Identified data structures used to store the red status and its timestamps
