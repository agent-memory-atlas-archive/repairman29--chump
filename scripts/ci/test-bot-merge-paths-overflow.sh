#!/usr/bin/env bash
# scripts/ci/test-bot-merge-paths-overflow.sh — RESILIENT-1610
#
# Replays the INFRA-8192 class the old INFRA-8202 commit fence lost work on:
# a dispatch lease on crates/chump-gap-store whose diff ALSO touches
# src/main.rs. The fence refused the whole commit (exit 4) and three Rust
# dispatches lost finished work. The new crate-/src-aware classification must:
#   (1) ALLOW an out-of-lease path that is in the same crate, the same src/
#       tree as a leased path, or unclaimed by any other live lease — those
#       are committed with the in-scope work, not flagged;
#   (2) treat a path another LIVE lease owns (or a docs/gaps/*.yaml deletion)
#       as a REAL collision — preserve it on refs/stash/<gap-id>, drop it from
#       the commit, and emit kind=dispatch_paths_overflow with the list.
#
# Bash only. No network. Sources the extracted libs directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/coord/lib/bot-merge-autocommit.sh"
LEASE_LIB="${REPO_ROOT}/scripts/lib/lease.sh"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-1610 bot-merge dispatch --paths overflow test ==="
echo

[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 2; }

# shellcheck source=../coord/lib/bot-merge-autocommit.sh
source "$LIB"
# shellcheck source=../lib/lease.sh
[[ -f "$LEASE_LIB" ]] && source "$LEASE_LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

seed_repo() {
    local dir="$1"
    mkdir -p "$dir/crates/chump-gap-store/src" "$dir/src" "$dir/.chump-locks"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t.com
    git -C "$dir" config user.name t
    echo "fn main() {}" > "$dir/src/main.rs"
    echo "pub fn q() {}" > "$dir/crates/chump-gap-store/src/lib.rs"
    git -C "$dir" add . >/dev/null
    git -C "$dir" commit -q -m seed
}

# ── (1) INFRA-8192 replay: crate lease + src/main.rs → both committed ──────
echo "[1. INFRA-8192 replay — lease on crate, diff also in src/main.rs]"

FAKE="${TMP}/repo1"
seed_repo "$FAKE"

LEASE="${FAKE}/.chump-locks/claim-RESILIENT.json"
cat > "$LEASE" <<JSON
{"session_id":"s1","gap_id":"INFRA-8192","paths":["crates/chump-gap-store"],
 "expires_at":"2999-01-01T00:00:00Z"}
JSON

echo "// edit" >> "$FAKE/crates/chump-gap-store/src/lib.rs"
echo "// edit main" >> "$FAKE/src/main.rs"
git -C "$FAKE" add -A >/dev/null

STAGED="$(cd "$FAKE" && git diff --cached --name-only)"
COLL="$(cd "$FAKE" && LOCK_DIR="$FAKE/.chump-locks" REPO_ROOT="$FAKE" \
    _bm_collision_staged_paths "$LEASE" INFRA-8192 "$STAGED")"

if [[ -z "$COLL" ]]; then
    ok "no collision flagged — src/main.rs allowed alongside the crate lease"
else
    fail "src/main.rs wrongly flagged as a collision: $COLL"
fi

# ── (2) src/-tree sibling allowance ────────────────────────────────────────
echo
echo "[2. src/ sibling allowance — lease src/dispatch.rs, diff src/main.rs]"

FAKE2="${TMP}/repo2"
seed_repo "$FAKE2"
echo "fn d() {}" > "$FAKE2/src/dispatch.rs"
git -C "$FAKE2" add -A >/dev/null && git -C "$FAKE2" commit -q -m "add dispatch"

LEASE2="${FAKE2}/.chump-locks/claim-R2.json"
cat > "$LEASE2" <<JSON
{"session_id":"s2","gap_id":"G2","paths":["src/dispatch.rs"],"expires_at":"2999-01-01T00:00:00Z"}
JSON

echo "// edit" >> "$FAKE2/src/main.rs"
git -C "$FAKE2" add -A >/dev/null
STAGED2="$(cd "$FAKE2" && git diff --cached --name-only)"
COLL2="$(cd "$FAKE2" && LOCK_DIR="$FAKE2/.chump-locks" REPO_ROOT="$FAKE2" \
    _bm_collision_staged_paths "$LEASE2" G2 "$STAGED2")"
if [[ -z "$COLL2" ]]; then
    ok "src/main.rs allowed as a src/-tree sibling of src/dispatch.rs"
else
    fail "src/main.rs wrongly flagged: $COLL2"
fi

# ── (3) REAL collision — another live lease owns the stray path ────────────
echo
echo "[3. real collision — src/main.rs owned by another LIVE lease]"

FAKE3="${TMP}/repo3"
seed_repo "$FAKE3"

LEASE3="${FAKE3}/.chump-locks/claim-ME.json"
cat > "$LEASE3" <<JSON
{"session_id":"me","gap_id":"RESILIENT-1610","paths":["crates/chump-gap-store"],
 "expires_at":"2999-01-01T00:00:00Z"}
JSON
# A sibling live lease that owns src/main.rs.
cat > "${FAKE3}/.chump-locks/claim-OTHER.json" <<JSON
{"session_id":"other","gap_id":"INFRA-9999","paths":["src/main.rs"],
 "expires_at":"2999-01-01T00:00:00Z"}
JSON
# An EXPIRED lease owning something must NOT cause a collision.
cat > "${FAKE3}/.chump-locks/claim-DEAD.json" <<JSON
{"session_id":"dead","gap_id":"OLD-1","paths":["crates/chump-gap-store"],
 "expires_at":"2000-01-01T00:00:00Z"}
JSON

echo "// edit crate" >> "$FAKE3/crates/chump-gap-store/src/lib.rs"
echo "// edit main" >> "$FAKE3/src/main.rs"
git -C "$FAKE3" add -A >/dev/null

STAGED3="$(cd "$FAKE3" && git diff --cached --name-only)"
COLL3="$(cd "$FAKE3" && LOCK_DIR="$FAKE3/.chump-locks" REPO_ROOT="$FAKE3" \
    _bm_collision_staged_paths "$LEASE3" RESILIENT-1610 "$STAGED3")"

if printf '%s\n' "$COLL3" | grep -qx 'src/main.rs'; then
    ok "src/main.rs flagged as a collision (owned by a live sibling lease)"
else
    fail "src/main.rs NOT flagged despite a live sibling lease: '$COLL3'"
fi
if printf '%s\n' "$COLL3" | grep -q 'lib.rs'; then
    fail "the in-lease crate path was wrongly flagged: $COLL3"
else
    ok "the in-lease crate path was not flagged"
fi

# Now exercise the preserve-and-drop + commit path end-to-end.
HEAD_BEFORE="$(git -C "$FAKE3" rev-parse HEAD)"
(
    cd "$FAKE3"
    export CHUMP_AMBIENT_LOG="$FAKE3/.chump-locks/ambient.jsonl"
    _bm_preserve_and_drop_collisions RESILIENT-1610 "$COLL3"
    git commit -q -m "RESILIENT-1610: in-scope only"
)

if git -C "$FAKE3" show "refs/stash/RESILIENT-1610" >/dev/null 2>&1; then
    ok "collision preserved on refs/stash/RESILIENT-1610"
else
    fail "refs/stash/RESILIENT-1610 was not created"
fi

# src/main.rs must be back at HEAD content (dropped from the commit + worktree).
if git -C "$FAKE3" show HEAD:src/main.rs | grep -q 'edit main'; then
    fail "src/main.rs collision leaked into the in-scope commit"
else
    ok "src/main.rs kept out of the in-scope commit"
fi
# The in-scope crate edit must be in the commit.
if git -C "$FAKE3" show HEAD:crates/chump-gap-store/src/lib.rs | grep -q 'edit crate'; then
    ok "the in-scope crate edit landed in the commit"
else
    fail "the in-scope crate edit was lost"
fi
# Worktree must be clean of the dropped path so a later rebase won't trip.
if [[ -z "$(git -C "$FAKE3" status --porcelain -- src/main.rs)" ]]; then
    ok "worktree clean of the dropped collision path"
else
    fail "worktree still dirty on src/main.rs after drop"
fi
# The ambient event must name the path with the literal kind.
if grep -q '"kind":"dispatch_paths_overflow"' "$FAKE3/.chump-locks/ambient.jsonl" 2>/dev/null \
    && grep -q 'src/main.rs' "$FAKE3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "emitted kind=dispatch_paths_overflow with the preserved path"
else
    fail "kind=dispatch_paths_overflow event missing or incomplete"
fi
[[ "$(git -C "$FAKE3" rev-parse HEAD)" != "$HEAD_BEFORE" ]] \
    && ok "HEAD advanced (in-scope commit landed)" \
    || fail "HEAD did not move"

# ── (4) docs/gaps/*.yaml deletion is always a collision (MISSION-111) ──────
echo
echo "[4. docs/gaps/*.yaml deletion stays a collision]"

FAKE4="${TMP}/repo4"
seed_repo "$FAKE4"
mkdir -p "$FAKE4/docs/gaps"
echo "gap: X" > "$FAKE4/docs/gaps/X.yaml"
git -C "$FAKE4" add -A >/dev/null && git -C "$FAKE4" commit -q -m "add gap"

LEASE4="${FAKE4}/.chump-locks/claim-R4.json"
cat > "$LEASE4" <<JSON
{"session_id":"s4","gap_id":"G4","paths":["crates/chump-gap-store"],"expires_at":"2999-01-01T00:00:00Z"}
JSON
echo "// edit crate" >> "$FAKE4/crates/chump-gap-store/src/lib.rs"
git -C "$FAKE4" rm -q "docs/gaps/X.yaml"
git -C "$FAKE4" add -A >/dev/null
STAGED4="$(cd "$FAKE4" && git diff --cached --name-only)"
COLL4="$(cd "$FAKE4" && LOCK_DIR="$FAKE4/.chump-locks" REPO_ROOT="$FAKE4" \
    _bm_collision_staged_paths "$LEASE4" G4 "$STAGED4")"
if printf '%s\n' "$COLL4" | grep -q 'docs/gaps/X.yaml'; then
    ok "docs/gaps/X.yaml deletion flagged as a collision"
else
    fail "docs/gaps/X.yaml deletion NOT flagged: '$COLL4'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
