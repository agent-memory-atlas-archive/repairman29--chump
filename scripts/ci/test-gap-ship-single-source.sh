#!/usr/bin/env bash
# test-gap-ship-single-source.sh — CREDIBLE-1499
#
# Enforces the invariant: only the ship() function in src/dispatch.rs
# should execute UPDATE statements that set status='done' on gaps.
#
# Returns exit 0 if the invariant holds, exit 1 if stray writers found.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0
FAIL=0

ok() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

echo "=== CREDIBLE-1499: gap status='done' single-source enforcement ==="
echo

STRAY_FILE=$(mktemp)
trap "rm -f $STRAY_FILE" EXIT

# Collect grep results
rust_matches=$(find "$REPO_ROOT/src" -name "*.rs" ! -name "dispatch.rs" -exec grep -n "UPDATE.*status.*=.*'done'" {} + 2>/dev/null || echo "")
shell_matches=$(find "$REPO_ROOT/scripts" -name "*.sh" -exec grep -n "UPDATE.*status.*=.*'done'" {} + 2>/dev/null || echo "")

# Process Rust files
echo "Scanning Rust files for stray UPDATE status='done' writers..."
if [[ -n "$rust_matches" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse: /path/to/file.rs:linenum:... (first two colons split file and linenum)
        file=$(echo "$line" | cut -d: -f1)
        linenum=$(echo "$line" | cut -d: -f2)

        # Check if this line is within a #[cfg(test)] block
        in_test=0
        if grep -q "#\[cfg(test)\]" "$file" 2>/dev/null; then
            head_result=$(head -n "$linenum" "$file" | grep -c "#\[cfg(test)\]" || echo 0)
            if [[ $head_result -gt 0 ]]; then
                in_test=1
            fi
        fi

        if [[ $in_test -eq 0 ]]; then
            echo "$line" >> "$STRAY_FILE"
        else
            echo "  [test code] $line"
        fi
    done <<< "$rust_matches"
fi

# Process shell scripts
echo
echo "Scanning shell scripts for stray UPDATE status='done' writers..."
if [[ -n "$shell_matches" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse: /path/to/file.sh:linenum:...
        file=$(echo "$line" | cut -d: -f1)

        # Check if this is a test fixture file (test-*.sh) or lib file
        is_fixture=0
        if [[ "$file" =~ test-.+\.sh$ ]] || [[ "$file" =~ .*-lib\.sh$ ]]; then
            is_fixture=1
        fi

        if [[ $is_fixture -eq 1 ]]; then
            echo "  [test fixture] $line"
        else
            echo "$line" >> "$STRAY_FILE"
        fi
    done <<< "$shell_matches"
fi

echo

# Report findings
if [[ -s "$STRAY_FILE" ]]; then
    echo "Found stray UPDATE status='done' writers:"
    cat "$STRAY_FILE" | while read -r line; do
        echo "  $line"
    done
    fail "Found stray UPDATE status='done' writers outside of dispatch.rs ship() function"
else
    ok "No stray UPDATE status='done' writers found (excluding dispatch.rs and test code)"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
