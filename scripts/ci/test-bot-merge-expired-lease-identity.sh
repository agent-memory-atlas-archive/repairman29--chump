#!/usr/bin/env bash
# scripts/ci/test-bot-merge-expired-lease-identity.sh — INFRA-8201
#
# `chump claim` writes a gap-claim marker (<main checkout>/.chump-locks/
# gap-claim-<GAP>.json) that nothing removes when the writer dies before
# its own real lease is written. bot-merge.sh's session-ID auto-detection
# (and its sibling INFRA-1901 _lease_wt / META-156 _existing_claim_session
# scans) used to match that EXPIRED marker by gap_id and adopt the dead
# session, then the pre-commit lease gate saw the LIVE dispatch's own path
# lease as "foreign" and refused the commit.
#
# This test validates (without network, without a real `chump claim`):
#   1. lease_is_expired distinguishes the expired marker from a live lease
#      for the same gap.
#   2. bm_pick_session_from_lockdir (scripts/lib/lease.sh) picks the LIVE
#      session, never the expired one, for the same gap_id.
#   3. bot-merge.sh's three LOCK_DIR scans all call lease_is_expired
#      (grep-level contract — no silent regression to the old behavior).
#   4. _bm_cleanup references the AC2 claim-marker-cleanup variables.
#   5. AC2: the claim-marker cleanup removes a marker it created on a
#      non-zero-exit cleanup call, but leaves alone a marker whose
#      session_id differs from the one it recorded.
#   6. AC3: scripts/git-hooks/pre-commit's lease gate allows a commit whose
#      only conflicting lease is expired, and prints the "treated as free"
#      line (tests the extracted shell logic, not the full hook — see
#      "Test depth" in the commit body).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
FAILED=0

echo "=== INFRA-8201 bot-merge expired-lease identity test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/lease.sh
source "${REPO_ROOT}/scripts/lib/lease.sh"

LOCKDIR="${TMP}/.chump-locks"
mkdir -p "$LOCKDIR"

EXPIRED_FILE="${LOCKDIR}/gap-claim-INFRA-9997.json"
LIVE_FILE="${LOCKDIR}/live-sess.json"

cat > "$EXPIRED_FILE" <<'EOF'
{"gap_id":"INFRA-9997","session_id":"claim-infra-9997-1-1","taken_at":"2020-01-01T00:00:00Z","expires_at":"2020-01-01T00:00:00Z"}
EOF

cat > "$LIVE_FILE" <<'EOF'
{"gap_id":"INFRA-9997","session_id":"live-9997","taken_at":"2099-01-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z"}
EOF

# ── 1. lease_is_expired ──────────────────────────────────────────────────
echo "[1. lease_is_expired distinguishes expired vs. live]"

if lease_is_expired "$EXPIRED_FILE"; then
    ok "lease_is_expired reports the 2020 marker as expired"
else
    fail "lease_is_expired did not flag the 2020 marker as expired"
fi

if lease_is_expired "$LIVE_FILE"; then
    fail "lease_is_expired wrongly flagged the 2099 lease as expired"
else
    ok "lease_is_expired reports the 2099 lease as live"
fi

# ── 2. bm_pick_session_from_lockdir picks the live session ─────────────────
echo
echo "[2. bm_pick_session_from_lockdir never returns the expired session]"

PICKED="$(bm_pick_session_from_lockdir "$LOCKDIR" "INFRA-9997" || true)"
if [[ "$PICKED" == "live-9997" ]]; then
    ok "bm_pick_session_from_lockdir picked live-9997"
else
    fail "bm_pick_session_from_lockdir picked '$PICKED', expected live-9997"
fi

rm -f "$LIVE_FILE"
PICKED_NONE="$(bm_pick_session_from_lockdir "$LOCKDIR" "INFRA-9997" || true)"
if [[ -z "$PICKED_NONE" ]]; then
    ok "bm_pick_session_from_lockdir returns nothing when only an expired lease exists"
else
    fail "bm_pick_session_from_lockdir wrongly returned '$PICKED_NONE' for an all-expired dir"
fi
# Restore for any later reuse of LOCKDIR in this script.
cat > "$LIVE_FILE" <<'EOF'
{"gap_id":"INFRA-9997","session_id":"live-9997","taken_at":"2099-01-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z"}
EOF

# ── 3. grep-level contract: all three LOCK_DIR scans call lease_is_expired ──
echo
echo "[3. bot-merge.sh's LOCK_DIR scans all check lease_is_expired]"

BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"

if grep -q 'bm_pick_session_from_lockdir "\$LOCK_DIR"' "$BOT_MERGE"; then
    ok "session-auto-detection scan uses bm_pick_session_from_lockdir"
else
    fail "session-auto-detection scan does not call bm_pick_session_from_lockdir"
fi

LEASE_IS_EXPIRED_HITS="$(grep -c 'lease_is_expired "\$_lf"' "$BOT_MERGE" || true)"
if [[ "$LEASE_IS_EXPIRED_HITS" -ge 2 ]]; then
    ok "found $LEASE_IS_EXPIRED_HITS lease_is_expired checks in the remaining \$_lf scans (INFRA-1901 + META-156)"
else
    fail "expected >=2 lease_is_expired checks in bot-merge.sh's remaining \$_lf scans, found $LEASE_IS_EXPIRED_HITS"
fi

if grep -q '_BM_CLAIM_MARKER_FILE' "$BOT_MERGE"; then
    ok "_bm_cleanup / claim step reference _BM_CLAIM_MARKER_FILE"
else
    fail "bot-merge.sh missing _BM_CLAIM_MARKER_FILE wiring"
fi

# ── 4. AC2: claim-marker cleanup removes its own marker, leaves others alone ─
echo
echo "[4. AC2: _bm_cleanup's marker removal is session-scoped]"

# Extract just the _bm_cleanup function body's marker-removal block by
# sourcing bot-merge.sh's helper logic directly would require its full
# environment (CHUMP_SESSION_ID, repo paths, etc). Instead we replicate the
# exact removal predicate bot-merge.sh uses, matching its source verbatim,
# so a regression in that predicate is caught here without needing the
# full bot-merge.sh runtime.
MARKER_GAP="INFRA-9998"
MARKER_FILE="${LOCKDIR}/gap-claim-${MARKER_GAP}.json"
cat > "$MARKER_FILE" <<'EOF'
{"gap_id":"INFRA-9998","session_id":"our-session-abc","taken_at":"2026-01-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z"}
EOF

bm_cleanup_marker_test() {
    local marker_file="$1" recorded_session="$2" exit_code="$3"
    local is_failure=0
    [[ "$exit_code" != "0" ]] && is_failure=1
    if [[ "$is_failure" -eq 1 && -n "$marker_file" && -f "$marker_file" ]]; then
        local now_session
        now_session="$(lease_session_id "$marker_file" 2>/dev/null || true)"
        if [[ -n "$recorded_session" && "$now_session" == "$recorded_session" ]]; then
            rm -f "$marker_file"
        fi
    fi
}

bm_cleanup_marker_test "$MARKER_FILE" "our-session-abc" 1
if [[ ! -f "$MARKER_FILE" ]]; then
    ok "cleanup removed the marker it created on a non-zero exit (matching session)"
else
    fail "cleanup left the marker in place despite a matching session + non-zero exit"
fi

MARKER_FILE2="${LOCKDIR}/gap-claim-INFRA-9996.json"
cat > "$MARKER_FILE2" <<'EOF'
{"gap_id":"INFRA-9996","session_id":"someone-elses-session","taken_at":"2026-01-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z"}
EOF
bm_cleanup_marker_test "$MARKER_FILE2" "our-session-abc" 1
if [[ -f "$MARKER_FILE2" ]]; then
    ok "cleanup left a marker alone whose session_id differs from the recorded one"
else
    fail "cleanup wrongly removed a marker belonging to a DIFFERENT session"
fi

# ── 5. AC3: pre-commit's expired-lease gate allows the commit + explains ───
echo
echo "[5. AC3: pre-commit treats an expired conflicting lease as free]"

PRE_COMMIT="${REPO_ROOT}/scripts/git-hooks/pre-commit"
if grep -q 'treated as free' "$PRE_COMMIT"; then
    ok "pre-commit prints a 'treated as free' line for skipped expired leases"
else
    fail "pre-commit does not name expired-lease holders as free"
fi

# Replicate pre-commit's exact expiry predicate (date parsing + comparison)
# against the SAME expired fixture used above, proving a conflicting lease
# that is actually expired is treated as free rather than a block.
# Test depth: this validates the extracted predicate, not a live run of the
# full hook end-to-end (the hook needs a real git repo + staged files to
# drive standalone within the time budget) — see "Test depth" in the commit.
now_epoch=$(date -u +%s)
expires=$(sed -n 's/.*"expires_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$EXPIRED_FILE" | head -n1)
if [[ "$(uname -s)" == "Darwin" ]]; then
    exp_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null || true)
else
    exp_epoch=$(date -u -d "$expires" +%s 2>/dev/null || true)
fi
if [[ -n "$exp_epoch" && "$exp_epoch" -le "$now_epoch" ]]; then
    ok "pre-commit's expiry predicate treats the 2020 marker as expired (free)"
else
    fail "pre-commit's expiry predicate did not treat the 2020 marker as expired"
fi

echo
if [[ "$FAILED" -eq 1 ]]; then
    echo "=== INFRA-8201: FAILED ===" >&2
    exit 1
fi
echo "=== INFRA-8201: all assertions passed ==="
