#!/usr/bin/env bash
# test-ambient-emit-session-persist.sh — INFRA-3002 AC #1 regression test.
#
# Bug: an interactive session with no CHUMP_SESSION_ID/CLAUDE_SESSION_ID set
# and no pre-existing .wt-session-id cache used to get a FRESH timestamp-based
# session id on every scripts/dev/ambient-emit.sh call. chump-ambient-glance.sh
# resolves SELF_SID by reading the SAME .wt-session-id cache file, so those
# two never matched — the invoking session's own prior events (e.g. its own
# commit retries) were misread as sibling collisions under --check-overlap.
#
# Fix: ambient-emit.sh mints a session id ONCE and persists it to
# .wt-session-id immediately, so every subsequent call (and
# chump-ambient-glance.sh) resolves the same id.
#
# Verifies:
#   (1) Two back-to-back ambient-emit.sh calls with no session env vars set
#       write events tagged with the SAME session id.
#   (2) chump-ambient-glance.sh --check-overlap does NOT fire on those two
#       own-session events (own-session retries stay invisible).
#   (3) A genuine different-session INTENT collision still fires (gate not
#       weakened).

set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
GLANCE="$REPO_ROOT/scripts/dev/chump-ambient-glance.sh"
[[ -x "$EMIT" ]] || { echo "FATAL: $EMIT not executable"; exit 2; }
[[ -x "$GLANCE" ]] || { echo "FATAL: $GLANCE not executable"; exit 2; }

TMP="$(mktemp -d)"
unset CHUMP_REPO CHUMP_LOCK_DIR CHUMP_SESSION_ID CLAUDE_SESSION_ID
trap 'rm -rf "$TMP"' EXIT

# Fake worktree: real git repo (ambient-emit.sh shells out to
# `git rev-parse --show-toplevel` / `--git-common-dir`) so this must be a
# real repo, not just a directory with a .chump-locks/ under it.
git init -q "$TMP/wt"
( cd "$TMP/wt" && git commit -q --allow-empty -m init )

echo "=== ambient-emit.sh session-id persistence tests (INFRA-3002) ==="

# ── 1. Same session id across two calls with no env vars set ────────────────
echo "--- Test 1: session id stable across calls ---"
( cd "$TMP/wt" && "$EMIT" file_edit path=src/foo.rs >/dev/null 2>&1 )
( cd "$TMP/wt" && "$EMIT" file_edit path=src/bar.rs >/dev/null 2>&1 )

AMBIENT="$TMP/wt/.chump-locks/ambient.jsonl"
if [[ ! -f "$AMBIENT" ]]; then
    fail "ambient.jsonl was not written"
else
    SIDS="$(python3 -c "
import json
sids = set()
with open('$AMBIENT') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        sids.add(json.loads(line).get('session'))
print(len(sids))
")"
    if [[ "$SIDS" == "1" ]]; then
        ok "both events share one session id"
    else
        fail "expected 1 distinct session id across 2 calls, got $SIDS"
    fi
fi

if [[ -f "$TMP/wt/.chump-locks/.wt-session-id" ]]; then
    ok ".wt-session-id cache was written"
else
    fail ".wt-session-id cache was not written"
fi

# ── 2. Own-session events do NOT trip --check-overlap ───────────────────────
echo "--- Test 2: own-session events invisible to --check-overlap ---"
if ( cd "$TMP/wt" && "$GLANCE" --paths src/foo.rs --check-overlap >/dev/null 2>&1 ); then
    ok "own-session file_edit does not trigger overlap"
else
    fail "own-session file_edit incorrectly triggered --check-overlap"
fi

# ── 3. A genuine different-session collision still fires ────────────────────
echo "--- Test 3: real sibling collision still caught ---"
NOW_ISO() { date -u +%Y-%m-%dT%H:%M:%SZ; }
printf '{"event":"file_edit","session":"a-different-sibling","ts":"%s","path":"src/foo.rs"}\n' \
    "$(NOW_ISO)" >> "$AMBIENT"
if ( cd "$TMP/wt" && "$GLANCE" --paths src/foo.rs --check-overlap >/dev/null 2>&1 ); then
    fail "sibling file_edit collision should have triggered exit 2"
else
    rc=$?
    if [[ $rc -eq 2 ]]; then ok "exit 2 on real sibling collision"
    else fail "expected exit 2, got $rc"; fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failed:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
