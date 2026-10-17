#!/usr/bin/env bash
# scripts/ci/test-inbox-first-picker.sh — INFRA-1254

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$PICKER" ] || fail "missing $PICKER"

mkdir -p "$TMP/locks/inbox"
SESSION="test-session-$$"

# Registry: two open gaps + one in the inbox HANDOFF.
cat > "$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-100","status":"open","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","created_at":"2026-01-01T00:00:00Z"},
  {"id":"INFRA-200","status":"open","acceptance_criteria":"Implement the change and verify the behavior","priority":"P2","effort":"m","created_at":"2026-01-01T00:00:00Z"},
  {"id":"INFRA-300","status":"done","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","created_at":"2026-01-01T00:00:00Z"}
]
EOF

# ── Test 1: no inbox → fall through to score-based pick (P1 wins) ─────────
out=$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_SESSION_ID="$SESSION" \
      CHUMP_LOCK_DIR="$TMP/locks" python3 "$PICKER")
[ "$out" = "INFRA-100" ] \
    || fail "no inbox → expected score-pick INFRA-100 (P1), got '$out'"
ok "no inbox → score-based P1 wins"

# ── Test 2: inbox HANDOFF for open gap → that gap wins (over higher prio) ──
cat > "$TMP/locks/inbox/$SESSION.jsonl" <<'EOF'
{"event":"HANDOFF","session":"someone-else","ts":"2026-05-14T00:00:00Z","gap":"INFRA-200","to":"test-session"}
EOF
out=$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_SESSION_ID="$SESSION" \
      CHUMP_LOCK_DIR="$TMP/locks" python3 "$PICKER")
[ "$out" = "INFRA-200" ] \
    || fail "HANDOFF for INFRA-200 should win even though INFRA-100 is higher-priority, got '$out'"
ok "HANDOFF in inbox wins over score-based default"

# ── Test 3: HANDOFF for a DONE gap → ignored, fall back to score ──────────
cat > "$TMP/locks/inbox/$SESSION.jsonl" <<'EOF'
{"event":"HANDOFF","session":"someone-else","ts":"2026-05-14T00:00:00Z","gap":"INFRA-300","to":"test-session"}
EOF
out=$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_SESSION_ID="$SESSION" \
      CHUMP_LOCK_DIR="$TMP/locks" python3 "$PICKER")
[ "$out" = "INFRA-100" ] \
    || fail "HANDOFF for DONE gap must be ignored; expected fallback INFRA-100, got '$out'"
ok "HANDOFF for done gap → ignored, fallback to score"

# ── Test 4: CHUMP_IGNORE_INBOX=1 → bypass ─────────────────────────────────
cat > "$TMP/locks/inbox/$SESSION.jsonl" <<'EOF'
{"event":"HANDOFF","session":"x","ts":"2026-05-14T00:00:00Z","gap":"INFRA-200","to":"test-session"}
EOF
out=$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_SESSION_ID="$SESSION" \
      CHUMP_LOCK_DIR="$TMP/locks" CHUMP_IGNORE_INBOX=1 python3 "$PICKER")
[ "$out" = "INFRA-100" ] \
    || fail "CHUMP_IGNORE_INBOX=1 should bypass; expected score-pick INFRA-100, got '$out'"
ok "CHUMP_IGNORE_INBOX=1 bypass works"

# ── Test 5: HANDOFF using corr_id (no gap field) ──────────────────────────
cat > "$TMP/locks/inbox/$SESSION.jsonl" <<'EOF'
{"event":"HANDOFF","session":"x","ts":"2026-05-14T00:00:00Z","corr_id":"INFRA-200","to":"test-session"}
EOF
out=$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_SESSION_ID="$SESSION" \
      CHUMP_LOCK_DIR="$TMP/locks" python3 "$PICKER")
[ "$out" = "INFRA-200" ] \
    || fail "corr_id should be used when gap absent, got '$out'"
ok "corr_id is honored when gap field absent"

# ── Test 6: oldest HANDOFF wins when multiple present ─────────────────────
cat > "$TMP/locks/inbox/$SESSION.jsonl" <<'EOF'
{"event":"HANDOFF","session":"x","ts":"2026-05-13T00:00:00Z","gap":"INFRA-200","to":"test-session"}
{"event":"HANDOFF","session":"y","ts":"2026-05-14T00:00:00Z","gap":"INFRA-100","to":"test-session"}
EOF
out=$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_SESSION_ID="$SESSION" \
      CHUMP_LOCK_DIR="$TMP/locks" python3 "$PICKER")
[ "$out" = "INFRA-200" ] \
    || fail "first HANDOFF in inbox should win (oldest), got '$out'"
ok "multiple HANDOFFs → oldest wins"

echo
echo "All INFRA-1254 inbox-first-picker tests passed."
