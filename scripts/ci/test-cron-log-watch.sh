#!/usr/bin/env bash
# test-cron-log-watch.sh — PRODUCT-250
#
# Proves scripts/alerts/cron-log-watch.py:
#   1. a healthy log (recent succeeded run, no stuck sessions) alerts on
#      nothing and exits 0
#   2. a deliberately stale fixture (mirrors the 2026-08-17 first-mate-brief
#      incident — a run stuck "running" for 33 days, no succeeded run ever)
#      trips BOTH the cron_task_stale and cron_session_stuck alerts and
#      exits non-zero
#   3. a task with a recent succeeded run but an unrelated old stuck session
#      still alerts on the stuck session alone
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d -t cron-log-watch-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- Case 1: healthy log -> no alerts, exit 0 -------------------------------
HEALTHY_LOG="$TMP/healthy.jsonl"
cat > "$HEALTHY_LOG" <<'EOF'
{"ts": "2026-09-12T09:00:00Z", "task": "first-mate-brief", "session_id": "h1", "status": "running"}
{"ts": "2026-09-12T09:05:00Z", "task": "first-mate-brief", "session_id": "h1", "status": "succeeded"}
EOF

set +e
OUT1=$(python3 scripts/alerts/cron-log-watch.py --log "$HEALTHY_LOG" --now "2026-09-19T00:00:00Z")
RC1=$?
set -e
[ "$RC1" -eq 0 ] || { echo "FAIL: healthy log expected exit 0, got $RC1 (out: $OUT1)"; exit 1; }
[ -z "$OUT1" ] || { echo "FAIL: healthy log expected no alerts, got: $OUT1"; exit 1; }

# --- Case 2: stale fixture mirroring the incident -> both alerts, exit 1 --
STALE_LOG="$TMP/stale.jsonl"
cat > "$STALE_LOG" <<'EOF'
{"ts": "2026-08-17T09:00:00Z", "task": "first-mate-brief", "session_id": "stuck1", "status": "running"}
EOF

set +e
OUT2=$(python3 scripts/alerts/cron-log-watch.py --log "$STALE_LOG" --now "2026-09-19T00:00:00Z")
RC2=$?
set -e
[ "$RC2" -ne 0 ] || { echo "FAIL: stale fixture expected non-zero exit"; exit 1; }

echo "$OUT2" | grep -q '"kind": "cron_task_stale"' || { echo "FAIL: stale fixture did not trip cron_task_stale. Got: $OUT2"; exit 1; }
echo "$OUT2" | grep -q '"kind": "cron_session_stuck"' || { echo "FAIL: stale fixture did not trip cron_session_stuck. Got: $OUT2"; exit 1; }
echo "$OUT2" | grep -q '"task": "first-mate-brief"' || { echo "FAIL: alert missing task name. Got: $OUT2"; exit 1; }

# --- Case 3: recent success on the task, but an unrelated old stuck session
MIXED_LOG="$TMP/mixed.jsonl"
cat > "$MIXED_LOG" <<'EOF'
{"ts": "2026-09-12T09:00:00Z", "task": "first-mate-brief", "session_id": "ok1", "status": "running"}
{"ts": "2026-09-12T09:05:00Z", "task": "first-mate-brief", "session_id": "ok1", "status": "succeeded"}
{"ts": "2026-09-15T09:00:00Z", "task": "first-mate-brief", "session_id": "hung1", "status": "running"}
EOF

set +e
OUT3=$(python3 scripts/alerts/cron-log-watch.py --log "$MIXED_LOG" --now "2026-09-19T00:00:00Z")
RC3=$?
set -e
[ "$RC3" -ne 0 ] || { echo "FAIL: mixed fixture expected non-zero exit (stuck session)"; exit 1; }
echo "$OUT3" | grep -q '"kind": "cron_session_stuck"' || { echo "FAIL: mixed fixture did not trip cron_session_stuck. Got: $OUT3"; exit 1; }
echo "$OUT3" | grep -q '"kind": "cron_task_stale"' && { echo "FAIL: mixed fixture should NOT trip cron_task_stale (recent succeeded run exists). Got: $OUT3"; exit 1; }

echo "OK: cron-log-watch.py alerts on stale tasks (no succeeded run in N days) and stuck sessions (running > running-hours), and stays quiet on a healthy log"
