#!/usr/bin/env bash
# scripts/ci/test-doc-155-changelog-roadmap-freshness.sh — DOC-155
#
# Proves CHANGELOG.md + docs/ROADMAP.md "current cycle" + the two crate
# changelogs were synced to reality (or explicitly dormant-tagged) instead
# of frozen in May/Aug against 289 undocumented PRs.
#
# AC: fails on the pre-DOC-155 state (CHANGELOG stops May, ROADMAP "current
# cycle" stops Aug, crate changelogs silently stale), passes once the
# September theme is named / dormant tags are present.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()   { printf '[PASS] %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== DOC-155: CHANGELOG + ROADMAP freshness ==="

# 1. CHANGELOG.md [Unreleased] section names the September fleet-self-hosting
#    theme (organ-manifest / almanac), not just the April/May ACP work.
if grep -q '### Added — Fleet self-hosting' CHANGELOG.md \
   && grep -q 'organ-manifest' CHANGELOG.md \
   && grep -q 'almanac' CHANGELOG.md; then
    ok "CHANGELOG.md [Unreleased] names the fleet-self-hosting (organ-manifest/almanac) theme"
else
    fail "CHANGELOG.md [Unreleased] does not name the fleet-self-hosting theme"
fi

# 2. docs/ROADMAP.md "current cycle" header points at September, not the
#    stale Jul 19 -> Aug 16 window, and explicitly demotes the old plan to
#    historical rather than silently leaving it labeled "current".
if grep -q '^## Current cycle — Fleet self-hosting (2026-09-06' docs/ROADMAP.md; then
    ok "docs/ROADMAP.md 'Current cycle' header is the September fleet-self-hosting cycle"
else
    fail "docs/ROADMAP.md 'Current cycle' header still points at the stale Jul/Aug cycle"
fi

if grep -q '^## Historical: Revival & Truth' docs/ROADMAP.md; then
    ok "Old Jul/Aug 'Revival & Truth' plan relabeled Historical (no longer claims to be current)"
else
    fail "Old Jul/Aug 'Revival & Truth' plan is not relabeled Historical"
fi

# 3. Crate changelogs are either updated or explicitly dormant-tagged with a
#    pointer to the live source of truth (root CHANGELOG.md).
for crate_changelog in crates/chump-agent-lease/CHANGELOG.md crates/chump-mcp-lifecycle/CHANGELOG.md; do
    if grep -qi 'Dormant' "$crate_changelog" && grep -q '\.\./\.\./CHANGELOG.md' "$crate_changelog"; then
        ok "$crate_changelog explicitly dormant-tagged with pointer to root CHANGELOG.md"
    else
        fail "$crate_changelog is neither updated nor dormant-tagged"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
