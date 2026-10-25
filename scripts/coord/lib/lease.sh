#!/bin/sh
# scripts/coord/lib/lease.sh
#
# Shared logic for locating and parsing chump lease/claim files
# (.chump-locks/claim-*.json). Consolidates redundant jq/grep parsers
# identified in META-063.

# get_active_claim_file [root]
#   Returns the path to the first claim-*.json found in .chump-locks.
get_active_claim_file() {
    local root="${1:-${REPO_ROOT:-.}}"
    local dir="$root/.chump-locks"
    [ -d "$dir" ] || return 0
    # Ship-fragility fix: prefer the claim matching the CURRENT branch's gap. A
    # blind `head -1` used to pick a STALE claim left by a prior ship
    # (claim-resilient-355-*.json), so the RESILIENT-025 pre-commit gate blocked a
    # commit for a DIFFERENT gap ("must mention claimed gap RESILIENT-355" while
    # committing RESILIENT-361) — a recurring barnacle that turned every ship into a
    # fight. Branch names are chump/<domain>-<num>-...; match that gap's claim first.
    local branch gap_slug match f fbranch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    # CREDIBLE-1566: check if any lease in $dir explicitly binds .branch == $branch
    # (used by `chump dispatch --repair <PR>` so repair branches match their lease).
    if [ -n "$branch" ]; then
        for f in "$dir"/*.json; do
            [ -f "$f" ] || continue
            fbranch="$(jq -r '.branch // empty' "$f" 2>/dev/null || true)"
            if [ -n "$fbranch" ] && [ "$fbranch" = "$branch" ]; then
                printf '%s\n' "$f"
                return 0
            fi
        done
    fi
    gap_slug="$(printf '%s' "$branch" | sed -nE 's#^chump/([a-z]+-[0-9]+).*#\1#p')"
    if [ -n "$gap_slug" ]; then
        match="$(find "$dir" -maxdepth 1 -name "claim-${gap_slug}-*.json" 2>/dev/null | head -1)"
        # Matching claim for THIS branch's gap → enforce it. No matching claim →
        # any claims present are for OTHER gaps (stale to this branch); do not
        # enforce them here, so a leftover claim can never block an unrelated ship.
        printf '%s\n' "$match"
        return 0
    fi
    # Branch carries no gap id (e.g. main) → legacy behaviour.
    find "$dir" -maxdepth 1 -name 'claim-*.json' 2>/dev/null | head -1
}

# parse_lease_field <file> <field>
#   Extracts a top-level field from a lease JSON file.
parse_lease_field() {
    local file="${1:?parse_lease_field <file> <field>}"
    local field="${2:?parse_lease_field <file> <field>}"
    if [ ! -f "$file" ]; then return 1; fi
    jq -r ".$field // empty" "$file" 2>/dev/null
}

# get_claimed_gap [file]
#   Returns the gap_id from the given file (or auto-locates the active claim).
get_claimed_gap() {
    local file="$1"
    if [ -z "$file" ]; then
        file=$(get_active_claim_file)
    fi
    [ -n "$file" ] && parse_lease_field "$file" "gap_id"
}

# get_claim_paths [file]
#   Returns the paths[] array from the given file, one per line.
get_claim_paths() {
    local file="$1"
    if [ -z "$file" ]; then
        file=$(get_active_claim_file)
    fi
    if [ -n "$file" ] && [ -f "$file" ]; then
        jq -r '.paths[]? // empty' "$file" 2>/dev/null | grep -v '^$' || true
    fi
}
