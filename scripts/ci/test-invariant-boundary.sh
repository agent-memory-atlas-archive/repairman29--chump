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
# Collect all violations
# ─────────────────────────────────────────────────────────────────────────────
all_violations=()
while IFS= read -r violator; do
    all_violations+=("$violator")
done < <(find_violators)

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
