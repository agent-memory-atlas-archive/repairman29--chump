#!/usr/bin/env bash
# scripts/ci/test-pr-rescue-cache-migration.sh — INFRA-1109
#
# Verifies pr-rescue.sh prefers cache_lookup_pr over direct gh api per-PR.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PR_RESCUE="$REPO_ROOT/scripts/coord/pr-rescue.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$PR_RESCUE" ]] || fail "pr-rescue.sh missing"
grep -q 'INFRA-1109' "$PR_RESCUE" || fail "INFRA-1109 banner missing"
grep -q 'cache_lookup_pr' "$PR_RESCUE" || fail "doesn't call cache_lookup_pr"
grep -q 'lib/github_cache.sh' "$PR_RESCUE" || fail "doesn't source github_cache.sh"
# Verify the fallback path (chump_gh api) is still present
grep -q 'chump_gh api "repos/${REPO}/pulls/${PR_NUM}"' "$PR_RESCUE" \
    || fail "lost the chump_gh api fallback"
ok "static: cache_lookup_pr call + lib source + gh api fallback all present"

# Verify the cache call comes BEFORE the fallback (line ordering)
CACHE_LINE=$(grep -n 'cache_lookup_pr "\${PR_NUM}"' "$PR_RESCUE" | head -1 | cut -d: -f1)
FALLBACK_LINE=$(grep -n 'chump_gh api "repos/${REPO}/pulls/${PR_NUM}"' "$PR_RESCUE" | head -1 | cut -d: -f1)
[[ "$CACHE_LINE" -lt "$FALLBACK_LINE" ]] \
    || fail "cache_lookup_pr (line $CACHE_LINE) must come before fallback (line $FALLBACK_LINE)"
ok "cache_lookup_pr precedes chump_gh api fallback in PR loop"

# Verify the script syntactically parses (bash -n)
bash -n "$PR_RESCUE" || fail "pr-rescue.sh has syntax error after migration"
ok "pr-rescue.sh syntactically valid"

# CREDIBLE-1539: Verify cache_lookup_pr is guarded with || true under set -e so
# exit code 2 (missing .chump/github_cache.db on CI runners) does not abort
# pr-rescue.sh before reaching the chump_gh api REST fallback.
grep -qE 'PR_META="\$\(cache_lookup_pr "\$\{PR_NUM\}" 2>/dev/null \|\| true\)"' "$PR_RESCUE" \
    || fail "CREDIBLE-1539: cache_lookup_pr call in pr-rescue.sh is not guarded with || true"
ok "CREDIBLE-1539: cache_lookup_pr guarded with || true against exit code 2 on missing cache DB"

# Behavioral check: under set -euo pipefail with missing github_cache.db,
# evaluating the cache_lookup_pr block must not exit 2 and must leave PR_META empty
# so the fallback branch triggers.
TMP_1539="$(mktemp -d)"
trap 'rm -rf "$TMP_1539"' EXIT
CHUMP_GITHUB_CACHE_DB="$TMP_1539/no-such-cache.db" REPO_ROOT="$REPO_ROOT" bash -c '
    set -euo pipefail
    source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"
    PR_NUM=42
    PR_META=""
    if declare -F cache_lookup_pr >/dev/null 2>&1; then
        PR_META="$(cache_lookup_pr "${PR_NUM}" 2>/dev/null || true)"
    fi
    [[ -z "$PR_META" ]]
' || fail "CREDIBLE-1539: cold-cache cache_lookup_pr block aborted under set -euo pipefail"
ok "CREDIBLE-1539: cold-cache cache_lookup_pr block survives set -euo pipefail and triggers fallback"

echo
echo "All INFRA-1109 / CREDIBLE-1539 pr-rescue-cache-migration tests passed."
