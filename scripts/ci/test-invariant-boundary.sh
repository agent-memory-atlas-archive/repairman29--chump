#!/usr/bin/env bash
# test-invariant-boundary.sh — INFRA-8218 (Phase R R6.1)
#
# Enforces the invariant-boundary gate: scripts under scripts/ (except test-*)
# must NOT write state directly to:
#   (a) state.db (sqlite3 with UPDATE/INSERT/DELETE/REPLACE on gap/lease/outcome tables)
#   (b) .chump-locks/*.json (claim/lease files)
#   (c) gap status assignments (status = done|shipped|open|blocked|in_progress)
#
# Modes:
#   CHUMP_BOUNDARY_GATE=shadow (default) — print violators, exit 0
#   CHUMP_BOUNDARY_GATE=enforce — fail on any violator not in allowlist, exit 1
#
# The allowlist (scripts/ci/invariant-boundary-allowlist.txt) is the source
# of truth for permitted direct writers. It may only SHRINK over time; CI
# fails if the allowlist grows.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE_MODE="${CHUMP_BOUNDARY_GATE:-shadow}"
ALLOWLIST_FILE="$REPO_ROOT/scripts/ci/invariant-boundary-allowlist.txt"

# Parse allowlist into a set for O(1) lookup.
declare -A ALLOWLISTED
if [[ -f "$ALLOWLIST_FILE" ]]; then
    while IFS= read -r line; do
        # Skip comments and empty lines.
        [[ "$line" =~ ^# || -z "$line" ]] && continue
        # Extract script name (first column before whitespace).
        script_name="${line%% *}"
        ALLOWLISTED["$script_name"]=1
    done < "$ALLOWLIST_FILE"
fi

echo "=== INFRA-8218 Invariant-boundary gate (mode: $GATE_MODE) ==="

# ─────────────────────────────────────────────────────────────────────────────
# Detect all violations: scripts that reference state.db or .chump-locks writes
# ─────────────────────────────────────────────────────────────────────────────
find_violators() {
    # Find all scripts except test-* that reference state.db mutations or lease writes.
    #
    # Patterns:
    # (a) sqlite3 followed by UPDATE/INSERT/DELETE/REPLACE (state.db mutations)
    # (b) writes to .chump-locks/*.json files
    # (c) direct status assignments

    find "$REPO_ROOT/scripts" \( -name "*.sh" -o -name "*.py" \) -type f | while read -r file; do
        # Skip test files.
        [[ "$(basename "$file")" =~ ^test- ]] && continue

        # Pattern (a): sqlite3 + UPDATE|INSERT|DELETE|REPLACE
        # Match: lines with sqlite3 followed (on same line or next) by mutation keywords
        if grep -E 'sqlite3.*(UPDATE|INSERT|DELETE|REPLACE)' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null; then
            echo "$(basename "$file")"
            continue
        fi

        # Pattern (b): writes to .chump-locks/*.json
        # Shell redirects: > .chump-locks/...json or >> .chump-locks/...json
        if grep -E '>\s*.*\.chump-locks/.*\.json|>>\s*.*\.chump-locks/.*\.json' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null; then
            echo "$(basename "$file")"
            continue
        fi

        # Pattern (c): status assignments (status="value")
        # Skip if it's just a comment or comparison
        if grep -E 'status\s*=\s*"(done|shipped|open|blocked|in_progress)"' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null; then
            echo "$(basename "$file")"
            continue
        fi
    done | sort -u
}

# ─────────────────────────────────────────────────────────────────────────────
# INFRA-8574 (PHASE-R R6, INFRA-8195 AC1): narrow lease-writer detector.
#
# The slice names TWO lease artifacts whose only writer must be
# crates/chump-atomic-claim (i.e. `chump claim`):
#   (L1) .chump-locks/claim-*.json lease files, and
#   (L2) the state.db `leases` table.
#
# This is stricter than the broad pattern-(b) scan above (any .chump-locks/*.json)
# and closes two real holes in that scan:
#   - pattern (a)'s single-line `sqlite3 ... DELETE` regex misses the reapers'
#     multi-line `DELETE FROM leases` heredocs, so the leases-table invariant
#     was never actually caught (stale-gap-lock-reaper.sh / stale-worktree-
#     reaper.sh / bot-merge.sh vacuum stale rows — allowlisted cleanup writers,
#     tracked for a Rust-owned release path as a follow-up, see MISSION-028);
#   - the fleet picker (_pick_and_claim_gap.py) writes a `<session>.json` lease
#     via a Python rename (not a shell redirect), so neither (a) nor (b) sees
#     it. Migrating that direct write to `chump claim` + adding Python-lease
#     detection here is INFRA-8195 AC2, reserved as a follow-up slice.
#
# Unlike the state.db/status scan above (mode-gated by CHUMP_BOUNDARY_GATE),
# lease writers are enforced UNCONDITIONALLY: a non-allowlisted lease writer
# fails the gate in both shadow and enforce runs.
find_lease_writers() {
    find "$REPO_ROOT/scripts" \( -name "*.sh" -o -name "*.py" \) -type f | while read -r file; do
        # Skip test files.
        [[ "$(basename "$file")" =~ ^test- ]] && continue

        # (L1) a shell redirect that WRITES a claim-*.json lease file. Readers
        # (`for lock in ...claim-*.json`, globs) are not redirects, so excluded.
        if grep -E '(^|[^<])>>?[[:space:]]*"?[^|;&#]*\.chump-locks/claim-[^"'"'"'|;&# ]*\.json' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null; then
            echo "$(basename "$file")"
            continue
        fi

        # (L2) a state.db `leases` table mutation. SELECT ... FROM leases
        # (reads) are intentionally NOT matched; "releases" has no word
        # boundary before "leases" so it is excluded by \bleases\b.
        if grep -E '(INSERT[[:space:]]+INTO|REPLACE[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+leases\b' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null; then
            echo "$(basename "$file")"
            continue
        fi

        # (L3) INFRA-8580 (INFRA-8195 AC2): a Python script that constructs a
        # session-lease dict (taken_at + heartbeat_at) and writes it directly
        # via json.dump/dumps instead of delegating to `chump claim --lease-only`.
        if [[ "$file" == *.py ]] \
           && grep -E '"taken_at"' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null \
           && grep -E '"heartbeat_at"' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null \
           && grep -E 'json\.dumps?\(' "$file" 2>/dev/null | grep -v "^[[:space:]]*#" > /dev/null; then
            echo "$(basename "$file")"
            continue
        fi
    done | sort -u
}

# ─────────────────────────────────────────────────────────────────────────────
# Collect all violations
# ─────────────────────────────────────────────────────────────────────────────
all_violations=()
while IFS= read -r violator; do
    all_violations+=("$violator")
done < <(find_violators)

# ─────────────────────────────────────────────────────────────────────────────
# INFRA-8574: lease-writer invariant — always enforced (independent of mode).
# A lease writer outside crates/chump-atomic-claim that is not on the allowlist
# fails the gate immediately. This runs before the mode dispatch so the
# invariant holds in both shadow and enforce invocations.
# ─────────────────────────────────────────────────────────────────────────────
lease_violations=()
while IFS= read -r lw; do
    lease_violations+=("$lw")
done < <(find_lease_writers)

lease_unapproved=()
for lw in "${lease_violations[@]}"; do
    if [[ -z "${ALLOWLISTED[$lw]:-}" ]]; then
        lease_unapproved+=("$lw")
    fi
done

echo ""
echo "── INFRA-8574 lease-writer invariant (claim-*.json + state.db leases table) ──"
if [[ ${#lease_unapproved[@]} -eq 0 ]]; then
    echo "✓ Only crates/chump-atomic-claim writes leases (allowlisted cleanup writers aside)"
    printf '{"ts":"%s","kind":"invariant_boundary_violation","check":"lease_writers","count":%d,"unapproved":0,"status":"ok"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#lease_violations[@]}" | tee -a "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
else
    echo "✗ Unapproved lease writer(s) outside crates/chump-atomic-claim:"
    for u in "${lease_unapproved[@]}"; do
        echo "  ✗ $u — writes .chump-locks/claim-*.json or the state.db leases table directly"
    done
    echo ""
    echo "Route lease writes through \`chump claim\` (crates/chump-atomic-claim)."
    printf '{"ts":"%s","kind":"invariant_boundary_violation","check":"lease_writers","count":%d,"unapproved":%d,"status":"violation"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#lease_violations[@]}" "${#lease_unapproved[@]}" | tee -a "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Report results based on mode
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$GATE_MODE" == "shadow" ]]; then
    echo ""
    echo "Shadow mode: listing detected violators (not enforced)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ ${#all_violations[@]} -eq 0 ]]; then
        echo "✓ No violations detected"
        exit 0
    fi

    for violator in "${all_violations[@]}"; do
        echo "  • $violator"
    done

    echo ""
    echo "Total violators: ${#all_violations[@]}"

    # Emit ambient event
    printf '{"ts":"%s","kind":"invariant_boundary_violation","count":%d,"mode":"shadow"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#all_violations[@]}" | tee -a "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true

    exit 0

elif [[ "$GATE_MODE" == "enforce" ]]; then
    echo ""
    echo "Enforce mode: checking against allowlist"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    unapproved=()
    for violator in "${all_violations[@]}"; do
        if [[ -z "${ALLOWLISTED[$violator]:-}" ]]; then
            unapproved+=("$violator")
        fi
    done

    if [[ ${#unapproved[@]} -eq 0 ]]; then
        echo "✓ All violators are allowlisted"
        echo ""
        # Emit ambient event
        printf '{"ts":"%s","kind":"invariant_boundary_violation","count":%d,"mode":"enforce","status":"ok"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#all_violations[@]}" | tee -a "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
        exit 0
    fi

    echo "✗ Unapproved violators found:"
    for u in "${unapproved[@]}"; do
        echo "  ✗ $u (not in allowlist)"
    done

    echo ""
    echo "Allowed writers (from $ALLOWLIST_FILE):"
    for allowed in "${!ALLOWLISTED[@]}"; do
        echo "  ✓ $allowed"
    done

    echo ""
    # Emit ambient event
    printf '{"ts":"%s","kind":"invariant_boundary_violation","count":%d,"unapproved":%d,"mode":"enforce","status":"violation"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#all_violations[@]}" "${#unapproved[@]}" | tee -a "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true

    exit 1
else
    echo "ERROR: CHUMP_BOUNDARY_GATE must be 'shadow' or 'enforce', got: $GATE_MODE"
    exit 2
fi
