#!/usr/bin/env bash
# test-jeff-bus-ingest.sh — proves the conversation-bus inbound ingester
# (scripts/ops/jeff-bus-ingest.py, Phase A of "Mirror in the OS"):
#   1. parses Claude Code transcript lines and writes real rows into
#      chump_web_messages (user text, assistant text, assistant thinking);
#   2. skips tool-only / empty turns and non-conversational line types;
#   3. is IDEMPOTENT — a second run over the same transcripts inserts zero
#      new rows (the per-line uuid cursor dedups).
# Fails loudly if the ingester is missing or its behavior regresses.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INGESTER="$REPO_ROOT/scripts/ops/jeff-bus-ingest.py"
PASS=0
FAIL=0

ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$INGESTER" ]; then
    echo "FAIL: ingester not found at $INGESTER"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/sessions/chump_memory.db"
TDIR="$WORK/projects/-some-project"
mkdir -p "$TDIR"

FIX="$TDIR/session-a.jsonl"
{
    echo '{"type":"queue-operation","operation":"enqueue","uuid":"q1","sessionId":"S1","content":"noise"}'
    echo '{"type":"user","uuid":"u1","sessionId":"S1","timestamp":"2026-09-25T10:00:00.000Z","message":{"role":"user","content":"Ship gap FOO-1 please."}}'
    echo '{"type":"assistant","uuid":"a1","sessionId":"S1","timestamp":"2026-09-25T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"weighing options"},{"type":"text","text":"On it — claiming FOO-1 now."}]}}'
    echo '{"type":"assistant","uuid":"a2","sessionId":"S1","timestamp":"2026-09-25T10:00:06.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
    echo '{"type":"user","uuid":"u2","sessionId":"S1","timestamp":"2026-09-25T10:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"exit 0"}]}}'
} >"$FIX"

run_ingest() {
    CHUMP_MEMORY_DB_PATH="$DB" CHUMP_TRANSCRIPTS_DIR="$WORK/projects" \
        python3 "$INGESTER"
}

# ── First pass ────────────────────────────────────────────────────────────
OUT1="$(run_ingest)" || { echo "FAIL: ingester exited non-zero"; echo "$OUT1"; exit 1; }
echo "run1: $OUT1"

count_msgs() { sqlite3 "$DB" "SELECT COUNT(*) FROM chump_web_messages;"; }
count_sess() { sqlite3 "$DB" "SELECT COUNT(*) FROM chump_web_sessions;"; }

M1="$(count_msgs)"
S1COUNT="$(count_sess)"
# u1 (user text) + a1 (assistant text) = 2 conversational turns.
# q1 (queue-operation), a2 (pure tool_use), u2 (pure tool_result) are skipped.
[ "$M1" = "2" ] && ok "first pass inserted 2 conversational messages" || bad "expected 2 messages, got $M1"
[ "$S1COUNT" = "1" ] && ok "first pass upserted 1 session" || bad "expected 1 session, got $S1COUNT"

USER_TXT="$(sqlite3 "$DB" "SELECT content FROM chump_web_messages WHERE role='user';")"
[ "$USER_TXT" = "Ship gap FOO-1 please." ] && ok "user turn text preserved" || bad "user text wrong: [$USER_TXT]"

THINK="$(sqlite3 "$DB" "SELECT thinking_monologue FROM chump_web_messages WHERE role='assistant';")"
[ "$THINK" = "weighing options" ] && ok "assistant thinking captured" || bad "thinking wrong: [$THINK]"

TS="$(sqlite3 "$DB" "SELECT created_at FROM chump_web_messages WHERE role='user';")"
[ "$TS" = "2026-09-25T10:00:00.000Z" ] && ok "original transcript timestamp preserved" || bad "timestamp wrong: [$TS]"

# ── Second pass: idempotency ──────────────────────────────────────────────
OUT2="$(run_ingest)"
echo "run2: $OUT2"
M2="$(count_msgs)"
[ "$M2" = "2" ] && ok "second pass inserted 0 new rows (idempotent)" || bad "idempotency broken: $M1 -> $M2"

# ── Append a new turn, confirm only the delta lands ───────────────────────
echo '{"type":"user","uuid":"u3","sessionId":"S1","timestamp":"2026-09-25T10:01:00.000Z","message":{"role":"user","content":"thanks"}}' >>"$FIX"
OUT3="$(run_ingest)"
echo "run3: $OUT3"
M3="$(count_msgs)"
[ "$M3" = "3" ] && ok "incremental pass ingested only the new turn" || bad "expected 3 after append, got $M3"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
