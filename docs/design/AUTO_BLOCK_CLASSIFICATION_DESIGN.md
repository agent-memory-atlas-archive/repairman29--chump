# Auto-Block Classification Design (RESILIENT-1342)

## Overview

This document outlines the current auto-block implementation in the fleet and identifies insertion points where a classification hook can distinguish between different categories of auto-blocked gaps.

## Current Implementation (INFRA-3832)

### Core Files

1. **scripts/dispatch/worker.sh** (lines 2731–2787)
   - **File**: Worker dispatch loop
   - **Role**: Detects non-ship cycles and calls `offense_bump()` to increment the consecutive-failure counter
   - **Key decision point**: Line 2787 calls `offense_maybe_block()` when offense count ≥ threshold

2. **scripts/dispatch/lib/offense-ledger.sh** (lines 22–39)
   - **File**: Offense tracking and auto-block execution
   - **Role**: Contains `offense_maybe_block()` function that performs the actual status=blocked transition
   - **Key decision point**: Line 29 performs the `chump gap set --status blocked` call

3. **scripts/dispatch/worker.sh** (lines 2988–2991)
   - **File**: Secondary auto-block path for unverified_ship cycles (RESILIENT-1584)
   - **Role**: Tracks unverified ships separately; calls `offense_maybe_block()` with `kind="unverified_ship"`
   - **Key decision point**: Line 2991 auto-blocks unverified ships after 3+ consecutive failures

### Current Behavior

**Trigger conditions:**
- Default threshold: `CHUMP_AUTO_BLOCK_THRESHOLD=3` (configurable)
- Failures are classified by `kind` (e.g., `nonship_cooldown`, `timeout`, `wedge`, `unverified_ship`)
- Guard: `CHUMP_AUTO_BLOCK_OFFENDERS=1` (default; set to 0 to disable auto-block)

**Offense Counter:**
- File-based storage: `$REPO_ROOT/.chump-locks/offense/${GAP_ID}.count`
- Incremented per non-ship cycle via `offense_bump()`
- Cleared on successful ship via `offense_clear()`

**Auto-block Action:**
- Sets `status=blocked` with a note in the gap's `notes` field
- Emits `kind=gap_auto_blocked` to `ambient.jsonl`
- Clears the offense counter after blocking

## Classification Insertion Points

The following sections identify where a classification layer can be injected to categorize why a gap was auto-blocked.

### 1. **Offense-Ledger Classification** (Primary)

**Location**: `scripts/dispatch/lib/offense-ledger.sh`, function `offense_maybe_block()`

**Current state:**
```bash
offense_maybe_block "$GAP_ID" "$_offense_n" "$_cooldown_kind" "$rc" "${_cycle_log_size:-0}"
```

**Insertion point**: The `$_cooldown_kind` variable (3rd argument) already carries classification intent:
- `nonship_cooldown` (default)
- `timeout`
- `wedge`
- `unverified_ship`

**Hook location (lines 22–39):**
- **Before `chump gap set` call (line 29)**: Add classification logic to enrich the note or emit an event
- **After `chump gap set` call (line 34)**: Perform post-block actions (e.g., file follow-up gap, escalate)

### 2. **Worker Dispatch Classification** (Secondary)

**Location**: `scripts/dispatch/worker.sh`, lines 2730–2787 (primary path) and lines 2988–2991 (unverified_ship path)

**Insertion point 1: Before `offense_maybe_block()` call (line 2787)**
- Opportunity to inspect the gap's history and compute a richer classification
- Access to: `rc` (exit code), `_cycle_log_size`, `GAP_ID`, full worker context
- Could call a new `classify_offense()` function that returns a structured classification object

**Insertion point 2: Unverified Ship escalation (line 3006)**
- Already uses `_unverified_ship_escalation.py` to track separate escalation state
- Could integrate classification into the Python escalation logic

### 3. **Ambient Event Enrichment**

**Location**: `scripts/dispatch/lib/offense-ledger.sh`, lines 31–33

**Current event:**
```json
{
  "kind": "gap_auto_blocked",
  "ts": "...",
  "session": "...",
  "agent": "...",
  "gap_id": "...",
  "offenses": 3,
  "last_kind": "nonship_cooldown",
  "rc": 1
}
```

**Insertion point**: Extend the JSON payload with:
- `classification` (e.g., "spec_error", "timeout", "wedge", "unverified_ship_escalation")
- `inferred_root_cause` (e.g., "acceptance_criteria_missing", "api_timeout", "mcp_wedge")
- `recommended_action` (e.g., "decompose", "escalate_model", "manual_review")

### 4. **Gap Note Enrichment**

**Location**: `scripts/dispatch/lib/offense-ledger.sh`, line 27

**Current note:**
```
INFRA-3832 auto-block: 3 consecutive non-ship cycles (last kind=nonship_cooldown, rc=1, cycle_log=2048B). 
Worker kept re-picking + looping; blocked to leave the pick pool. Un-block after fixing the spec / decomposing.
```

**Insertion point**: Append classification-specific guidance:
- For spec errors: "Suggest decomposing or clarifying acceptance_criteria before re-opening."
- For timeout: "Consider reducing scope or increasing model capability."
- For wedge: "Check MCP / API health before re-opening."
- For unverified_ship: "Gap shipped but tests/observers unverified; manual review required."

## Recommended Architecture

### Option A: Shell-Based Classification

**Pros:**
- Minimal code changes
- Uses existing `lib/` infrastructure
- Classification lives near the decision site

**Cons:**
- Shell string-matching is fragile
- Hard to maintain complex rules

**Implementation:**
```bash
# New function in offense-ledger.sh
classify_offense_kind() {
    local kind="$1" rc="$2" logbytes="$3"
    case "$kind" in
        timeout) echo "timeout" ;;
        wedge) echo "wedge" ;;
        unverified_ship) echo "unverified_ship" ;;
        *) echo "spec_error" ;;  # default
    esac
}
```

### Option B: Python-Based Classification (Recommended)

**Pros:**
- Centralized logic
- Reusable across unverified_ship and primary paths
- Easy to extend with rule-based or ML inference

**Cons:**
- Adds a new Python CLI tool
- Requires integration with `chump gap set`

**Implementation:**
```bash
# New tool: scripts/dispatch/_gap_classification.py
python3 "$REPO_ROOT/scripts/dispatch/_gap_classification.py" \
    classify "$GAP_ID" --kind "$_cooldown_kind" --rc "$rc" --log-bytes "$_cycle_log_size"
# Returns: {"classification": "spec_error", "reason": "..."}
```

## Success Criteria (AC from RESILIENT-1342)

1. ✅ **Code owners confirm the identified files contain the auto-block decision logic:**
   - `scripts/dispatch/worker.sh` (lines 2731–2787, 2988–2991)
   - `scripts/dispatch/lib/offense-ledger.sh` (lines 22–39)

2. ✅ **Design note outlines where the classification hook will be added:**
   - Section 3 above identifies four insertion points:
     1. Offense-ledger function `offense_maybe_block()`
     2. Worker dispatch before/after offense calls
     3. Ambient event enrichment
     4. Gap note enrichment

## Next Steps (RESILIENT-1328)

The parent gap (RESILIENT-1328) encompasses:
- Implementing the classification hook (likely Python-based per Option B)
- Enriching the ambient event with classification fields
- Updating the gap note with classification-specific guidance
- Testing the classification output on real auto-block events

This design note serves as the foundation for those implementation slices.
