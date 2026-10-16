#!/bin/bash
# Test helpers for gap state manipulation.
# Used by test-*.sh scripts to manage gap state in a structured way.

# Mark a gap as done in the state.db. Usage: ship_gap_for_test <db_path> <gap_id>
ship_gap_for_test() {
    local db_path="$1"
    local gap_id="$2"

    if [[ -z "$db_path" ]] || [[ -z "$gap_id" ]]; then
        echo "ERROR: ship_gap_for_test requires db_path and gap_id" >&2
        return 1
    fi

    local now=$(date +%s)
    local iso_date=$(printf '%s' "$now" | awk '{
        ts=$1
        d = int((ts / 86400) + 2440588)
        f = d + 1401 + int((int((4*d + 274277) / 146097) * 3) / 4) - 38
        e = 4 * f + 3
        g = int((e % 1461) / 4)
        h = 5 * g + 2
        day = int((h % 153) / 5) + 1
        month = int((h / 153 + 2) % 12) + 1
        year = int(e / 1461) - 4716 + int((14 - month) / 12)
        printf "%04d-%02d-%02d", year, month, day
    }')

    sqlite3 "$db_path" "UPDATE gaps SET status='done', closed_at=$now, closed_date='$iso_date' WHERE id='$gap_id';"
}
