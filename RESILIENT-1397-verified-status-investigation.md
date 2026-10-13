# RESILIENT-1397: Verified Status Posting Logic Investigation

## Gap Summary

This document investigates and documents the current verifier logic for posting the `verified` commit status as part of RESILIENT-1365.

## Overview

The `verified` status is not a traditional commit status posted via GitHub REST API. Instead, it is a **GitHub Actions check-run** that is automatically created and managed by GitHub Actions as a job result. The `verified` job acts as the **single aggregator** of all CI lane verdicts, implementing the architecture specified in META-134 (CREDIBLE-269).

---

## Source Files and Functions

### Primary Source Files

1. **`.github/workflows/ci.yml` — The `verified` job definition**
   - **Location:** `.github/workflows/ci.yml`, lines 583–625
   - **Role:** Defines the GitHub Actions job that becomes the `verified` check-run
   - **Job name:** `verified` (this is the check-run name that appears in branch protection)
   - **Key properties:**
     - `if: always()` — runs even if earlier jobs fail; never skipped
     - `timeout-minutes: 15` — gives adequate time for cross-workflow polling
     - `needs:` — depends on same-workflow lanes: `fast-checks`, `fast-checks-heavy`, `clippy`, `cargo-test`, `pr-hygiene`, `test`

2. **`scripts/ci/aggregator-verified.sh` — The decision-logic engine**
   - **Location:** `scripts/ci/aggregator-verified.sh`, lines 1–169
   - **Role:** Implements the core decision logic that classifies each lane and determines the overall verdict
   - **Functions:**
     - `classify_lane()` (lines 78–113) — classifies a single lane's result into PASS / FAIL / PENDING
     - Main logic (lines 115–129) — loops over lanes, computes overall verdict

3. **`scripts/ci/poll-cross-workflow-checks.sh` — Cross-workflow lane fetcher**
   - **Location:** Referenced in ci.yml, lines 596–603
   - **Role:** Polls GitHub's Checks API to fetch results from `audit.yml` and `integrations.yml` workflows (separate GH Action workflows)
   - **Input:** Check names (`audit`, `ACP protocol smoke test`) and SHA
   - **Output:** Lane results in the format `<lane_name>=<result>`
   - **Timeout:** 120 seconds (configurable) — waits for pending checks, then fails open to prevent indefinite blocking

---

## Decision Flow

### 1. Trigger Event

The `verified` job is triggered automatically by GitHub Actions when a PR is opened or updated:

```
PR opened/updated 
    → .github/workflows/ci.yml runs
    → All lanes execute in parallel (fast-checks, clippy, cargo-test, etc.)
    → verified job enters "waiting" state (depends on all lanes)
    → When all required lanes reach terminal state, verified job starts
```

### 2. Prerequisites Collection Phase

When the `verified` job starts, it must collect results from **two sources**:

#### A. Same-Workflow Lanes (Local)
These are available directly via GitHub Actions `needs.<job>.result`:
- `fast-checks`
- `fast-checks-heavy`
- `clippy`
- `cargo-test`
- `pr-hygiene`
- `test`

**Code location:** `.github/workflows/ci.yml`, lines 610–618 (the `Aggregate lane verdicts` step)

#### B. Cross-Workflow Lanes (Remote)
These live in separate workflows and must be polled via GitHub's Checks API:
- `audit` (from `audit.yml`)
- `ACP protocol smoke test` (from `integrations.yml`)

**Code location:** `.github/workflows/ci.yml`, lines 591–605 (the `Poll cross-workflow lanes` step)

**Polling logic flow:**
```
poll-cross-workflow-checks.sh receives:
    --sha <commit-sha>
    --check "audit"
    --check "ACP protocol smoke test (Zed / JetBrains compatible)"
    --timeout-s 120
    --interval-s 15

Polling loop (max 8 iterations, 15s between each):
    1. Query GitHub Checks API: GET /repos/{owner}/{repo}/commits/{sha}/check-runs
    2. For each check in the list, filter by name (case-insensitive substring match)
    3. Extract the `status` and `conclusion` fields
    4. If conclusion is terminal (success/failure/cancelled/skipped/neutral):
       → Output: "audit=success" or "audit=failure", etc.
    5. If status is still "in_progress" and we haven't hit the timeout:
       → Continue polling after 15s
    6. If timeout (120s) is reached with checks still pending:
       → Fail-open with "PENDING" to avoid deadlock

Output format: "lane_name=result" per line, where result ∈ {success, failure, cancelled, skipped, in_progress, pending, ""(missing)}
```

**Code location:** `scripts/ci/poll-cross-workflow-checks.sh` (exact location not shown, but referenced at ci.yml:600)

### 3. Lane Classification Phase

Once both local and cross-workflow results are collected, `aggregator-verified.sh` classifies each lane:

**Classification rules (per `aggregator-verified.sh` lines 78–113):**

```bash
classify_lane() {
    # Input: "lane_name=result[,stub_result]" 
    # (stub_result only present for path-filtered lanes with stub jobs)
    
    case "$real_job_result" in
        "success")
            echo "PASS"
            
        "failure" | "cancelled")
            echo "FAIL"
            
        "skipped")
            if [ no stub for this lane ]; then
                echo "PASS"  # real job doesn't apply, lane OK
            else
                case "$stub_result" in
                    "success") echo "PASS"   # stub ran, path-filter OK
                    "failure"|"cancelled") echo "FAIL"  # stub also failed
                    "skipped") echo "FAIL"   # both skipped = config bug
                    *)  echo "PENDING"       # stub still running
                esac
            fi
            
        "in_progress" | "queued" | "")
            echo "PENDING"
            
        *)
            echo "FAIL"  # unknown state = fail closed
    esac
}
```

**Mapping:**
- `success` → **PASS**
- `skipped` (no stub) → **PASS** (lane doesn't apply)
- `skipped` (with stub=success) → **PASS** (path-filter + stub covers it)
- `failure` or `cancelled` → **FAIL**
- `in_progress`/`queued`/missing → **PENDING**

### 4. Overall Verdict Computation Phase

After classifying all lanes (lines 115–129), the aggregator computes a single overall verdict:

```bash
OVERALL="PASS"

for each lane in [fast-checks, clippy, cargo-test, pr-hygiene, test, audit, ACP-smoke]:
    verdict = classify_lane(lane)
    
    if verdict == "FAIL":
        OVERALL = "FAIL"   # fast-fail: any FAIL makes verdict FAIL
    elif verdict == "PENDING" AND OVERALL != "FAIL":
        OVERALL = "PENDING"  # no FAIL yet, but something still running

exit_code:
    PASS    → exit 0
    FAIL    → exit 1
    PENDING → exit 2
```

**Decision table:**

| Condition | Verdict | Exit Code |
|-----------|---------|-----------|
| Any lane classifies FAIL | FAIL | 1 |
| No FAIL, at least one PENDING | PENDING | 2 |
| All lanes classify PASS | PASS | 0 |

### 5. Status Posting (Implicit via GitHub Actions)

**GitHub Actions automatically creates the check-run** with the name specified in the job's `name:` field (`verified`):

```yaml
verified:
    name: verified   # ← This becomes the check-run name
```

When the aggregator script exits with code 0, GitHub Actions marks the `verified` check-run as **SUCCESS**.
When it exits with code 1 or 2, GitHub Actions marks it as **FAILURE** (or **NEUTRAL** if the logic warrants it).

**The check-run is NOT posted via a REST API call.** It exists automatically because the job exists and runs. The aggregator's exit code determines the check-run's conclusion.

### 6. Ambient Event Emission (Observability)

After computing the verdict, `aggregator-verified.sh` (lines 132–161) emits an ambient event for offline audit:

```bash
kind=verified_aggregator_decision
{
    "ts": "2026-10-13T...",
    "kind": "verified_aggregator_decision",
    "pr": "<number>",
    "sha": "<commit-sha>",
    "verdict": "PASS" | "FAIL" | "PENDING",
    "lanes_classified": {
        "fast-checks": "PASS",
        "clippy": "FAIL",
        "cargo-test": "PASS",
        ...
    }
}
```

**Emission:** Written to `.chump-locks/ambient.jsonl` (line 158)

---

## Decision Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ GitHub Actions: PR opened/updated                              │
└──────────────────┬──────────────────────────────────────────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │  All lanes execute   │
        │  in parallel:        │
        │  • fast-checks       │
        │  • clippy            │
        │  • cargo-test        │
        │  • pr-hygiene        │
        │  • test              │
        │  • (audit)           │
        │  • (ACP-smoke)       │
        └────────┬─────────────┘
                 │
                 ▼
   ┌──────────────────────────────────┐
   │ verified job starts              │
   │ (if: always())                   │
   └────────┬─────────────────────────┘
            │
            ├─→ Poll cross-workflow lanes (step 1)
            │   ├─ Call Checks API for "audit"
            │   └─ Call Checks API for "ACP protocol smoke test"
            │   └─ Wait up to 120s for results
            │   └─ Output: audit=success, acp_result=failure, etc.
            │
            ├─→ Classify each lane (aggregator-verified.sh, step 2)
            │   ├─ fast-checks result → classify → PASS/FAIL/PENDING
            │   ├─ clippy result → classify → PASS/FAIL/PENDING
            │   ├─ cargo-test result → classify → PASS/FAIL/PENDING
            │   ├─ pr-hygiene result → classify → PASS/FAIL/PENDING
            │   ├─ test result → classify → PASS/FAIL/PENDING
            │   ├─ audit result → classify → PASS/FAIL/PENDING
            │   └─ acp-smoke result → classify → PASS/FAIL/PENDING
            │
            ├─→ Compute overall verdict (step 3)
            │   ├─ IF any lane = FAIL → OVERALL = FAIL
            │   ├─ ELSE IF any lane = PENDING → OVERALL = PENDING
            │   └─ ELSE → OVERALL = PASS
            │
            ├─→ Emit ambient event (step 4)
            │   └─ kind=verified_aggregator_decision
            │
            └─→ Exit with code
                ├─ 0 (PASS) → GitHub marks check-run SUCCESS
                ├─ 1 (FAIL) → GitHub marks check-run FAILURE
                └─ 2 (PENDING) → GitHub marks check-run FAILURE or NEUTRAL
                                 (RESILIENT-1562: verified-recompute.yml 
                                  re-runs when dependent workflows complete)

                         ▼
            ┌──────────────────────────┐
            │ GitHub automatically     │
            │ creates/updates the      │
            │ "verified" check-run     │
            │ based on exit code       │
            └──────────────────────────┘
                         │
                         ▼
            ┌──────────────────────────────────┐
            │ Branch protection evaluates      │
            │ Required checks: ["verified"]    │
            │ PR is mergeable IFF verified=OK  │
            └──────────────────────────────────┘
```

---

## Key Design Patterns

### 1. Fail-Closed on Poll Timeout (RESILIENT-1562)

If the cross-workflow poll reaches the 120-second timeout before all checks reach a terminal state:
- The aggregator **does not wait forever**
- Instead, it **emits PENDING** for the unresolved lanes
- The `verified` job **exits with code 2** (PENDING)
- GitHub Actions marks the check-run as PENDING (not SUCCESS)
- A separate daemon (`verified-recompute.yml`) watches for `audit.yml` and `integrations.yml` completion and **re-runs** the `verified` job automatically

**Rationale:** Prevents infinite blocking while ensuring eventual correctness.

### 2. Path-Filtered Lanes with Stub Jobs

Some lanes (like `cargo-test`, `audit`, `clippy`) are gated by `if: needs.changes.outputs.code == 'true'` — they skip on doc-only PRs. For these lanes:
- A **stub job** runs when the real job skips
- The stub job is trivial (just `echo success`)
- The aggregator sees both results (e.g., `"cargo-test=skipped,success"`)
- **Classification:** skipped + stub-success = PASS

**Rationale:** Proves that the lane "not running" is intentional (doc-only) and not a configuration bug.

### 3. Early Exit on FAIL

The aggregator uses **fast-fail logic** (line 122-123):

```bash
if [[ "$verdict" == "FAIL" ]]; then
    OVERALL="FAIL"
```

Once any lane fails, `OVERALL` is set to FAIL and never changes back. This ensures the verdict is **definitive** as soon as a failure is detected.

---

## Summary of Source Files

| File | Lines | Role |
|------|-------|------|
| `.github/workflows/ci.yml` | 583–625 | Defines the `verified` GH Actions job |
| `scripts/ci/aggregator-verified.sh` | 78–129 | Classifies lanes and computes overall verdict |
| `scripts/ci/poll-cross-workflow-checks.sh` | (referenced) | Fetches cross-workflow lane results via Checks API |
| `docs/design/CI_VERIFIED_AGGREGATOR.md` | (full spec) | Architecture and decision table for the aggregator |

---

## Required and Non-Required Checks Evaluation

### Required Checks (ALL must PASS for mergeable)
The aggregator classifies **all** lanes as required by default. Each lane is evaluated per the classification rules in §2.2:

1. **Same-workflow lanes** (always evaluated):
   - `fast-checks` → must be PASS (or PENDING waits)
   - `fast-checks-heavy` → must be PASS (or PENDING waits)
   - `clippy` → must be PASS (or PENDING waits)
   - `cargo-test` → must be PASS (or PENDING waits)
   - `pr-hygiene` → must be PASS (or PENDING waits)
   - `test` → must be PASS (or PENDING waits)

2. **Cross-workflow lanes** (polled from other workflows):
   - `audit` → must be PASS (or PENDING waits)
   - `ACP protocol smoke test` → must be PASS (or PENDING waits)

### Non-Required Checks (Advisory)
Currently, **there are no advisory checks** in the aggregator. All lanes contribute equally to the verdict.

**Future extension (not yet implemented):** 
- Certain lanes could be marked advisory via environment variable (e.g., `CHUMP_VERIFY_CI_ADVISORY_NAMES`)
- Advisory lanes would be polled/logged but never gate the verdict

---

## Entry Points and How They Work

### Entry Point 1: GitHub Actions Automatic Trigger
```
Event: pull_request opened/synchronize
 → .github/workflows/ci.yml @ on.pull_request
 → All jobs execute per their `if:` conditions
 → verified job starts when its dependencies (needs:) complete
```

**Code location:** `.github/workflows/ci.yml`, top-level workflow definition

### Entry Point 2: Manual Recompute (RESILIENT-1562)
```
Event: audit.yml or integrations.yml workflow_run completes
 → verified-recompute.yml triggers (separate workflow)
 → Re-runs the verified job on the original PR
 → Ensures cross-workflow lanes are re-evaluated
```

**Code location:** `.github/workflows/verified-recompute.yml` (not shown but referenced)

---

## Conclusion

The `verified` status is implemented as:

1. **A GitHub Actions job** (named `verified`) that runs when CI lanes complete
2. **A decision engine** (`aggregator-verified.sh`) that classifies each lane and computes an overall verdict
3. **A cross-workflow poller** (`poll-cross-workflow-checks.sh`) that fetches results from separate workflows
4. **An implicit status post** — GitHub Actions automatically creates the check-run and sets its conclusion based on the script's exit code

The decision flow evaluates all lanes as required checks with no current advisory lanes. Future extensions (e.g., quarantined flakes, advisory lanes) are designed into the architecture but not yet active.
