#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-fleet-brief.sh — INFRA-721
#
# Verifies `chump fleet brief` Rust subcommand:
#   1. Outputs the header line
#   2. Counts real commits on origin/main as ships (CREDIBLE-168, not ambient events)
#   3. Counts alert events by kind (pr_stuck, silent_agent)
#   4. --json flag emits valid JSON with required fields
#   5. Exits 0 and doesn't fall through to rest of main()
#   6. Reads ambient.jsonl from CHUMP_REPO (not CWD)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN"
    echo "  Run: cargo build --bin chump"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Build a synthetic CHUMP_REPO with ambient.jsonl and state.db ──────────────
mkdir -p "$TMP/repo/.chump-locks"
mkdir -p "$TMP/repo/.chump"

NOW_TS="$(date -u +%s)"
RECENT_ISO="$(date -u -r "$((NOW_TS - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$((NOW_TS - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
OLD_ISO="2026-01-01T00:00:00Z"
ALERT_RECENT_ISO="$(date -u -r "$((NOW_TS - 600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$((NOW_TS - 600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# Write ambient.jsonl with alert events only — ships are now counted from git
# (origin/main), seeded below, NOT from ambient "commit" events:
#   - 2 pr_stuck alerts (recent)
#   - 1 silent_agent alert (recent, within 30m)
#   - 1 silent_agent alert (old, outside 30m but within 24h)
cat >"$TMP/repo/.chump-locks/ambient.jsonl" <<EOF
{"ts":"$RECENT_ISO","event":"alert","kind":"pr_stuck","pr":1001,"reason":"CI red","session":"s1"}
{"ts":"$RECENT_ISO","event":"alert","kind":"pr_stuck","pr":1002,"reason":"DIRTY","session":"s2"}
{"ts":"$ALERT_RECENT_ISO","event":"ALERT","kind":"silent_agent","note":"session=s3 gap=INFRA-X last_event_age=99m","session":"monitor"}
{"ts":"$OLD_ISO","event":"ALERT","kind":"silent_agent","note":"old silent agent outside 30m","session":"monitor"}
EOF

# ── Seed origin/main with dated commits — the real "ships" (CREDIBLE-168) ─────
# fleet-brief now counts commits on origin/main via `git log --since` (real
# merges), NOT ambient "commit" events — every worker WIP/auto commit emitted a
# "commit" event, over-counting ships ~55x. main_checkout_root() resolves to
# CHUMP_REPO here, so seed 3 commits dated 1h ago (inside the 24h window) + 1
# old commit (outside it), then point refs/remotes/origin/main at the tip; the
# subcommand's `git log --since=<cutoff> origin/main` then sees exactly 3.
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email ci@chump.test
git -C "$TMP/repo" config user.name CI
GIT_AUTHOR_DATE="$OLD_ISO" GIT_COMMITTER_DATE="$OLD_ISO" \
    git -C "$TMP/repo" -c commit.gpgsign=false commit -q --allow-empty -m "old ship (outside 24h window)"
for _i in 1 2 3; do
    GIT_AUTHOR_DATE="$RECENT_ISO" GIT_COMMITTER_DATE="$RECENT_ISO" \
        git -C "$TMP/repo" -c commit.gpgsign=false commit -q --allow-empty -m "ship $_i (1h ago)"
done
git -C "$TMP/repo" update-ref refs/remotes/origin/main HEAD

# ── Test 1: header line present ───────────────────────────────────────────────
echo "Test 1: output contains fleet brief header"
OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$OUT" | grep -q "Fleet brief"; then
    echo "  PASS"
else
    echo "  FAIL: missing Fleet brief header"
    echo "$OUT" | sed 's/^/  /'
    exit 1
fi

# ── Test 2: real origin/main commits counted as ships ────────────────────────
echo "Test 2: origin/main commits in 24h counted as ships (3, not 0 or 4)"
if echo "$OUT" | grep -qE "^Ships: 3"; then
    echo "  PASS (Ships: 3)"
else
    echo "  FAIL: expected 'Ships: 3'"
    echo "$OUT" | grep -i "ship" | sed 's/^/  /'
    exit 1
fi

# ── Test 3: alert(30m) counts only recent ALERT events ───────────────────────
echo "Test 3: Alerts(30m) shows only alerts in last 30 min (1)"
if echo "$OUT" | grep -qE "Alerts\(30m\): 1"; then
    echo "  PASS (Alerts(30m): 1)"
else
    echo "  FAIL: expected 'Alerts(30m): 1'"
    echo "$OUT" | grep -i alert | sed 's/^/  /'
    exit 1
fi

# ── Test 4: --json emits valid JSON with required fields ──────────────────────
echo "Test 4: --json flag emits valid JSON"
JSON_OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief --json 2>/dev/null)"
REQUIRED_FIELDS="ships_24h auto_fixed manual_rescues stalls_gt_4h fleet_wedges silent_agents pr_stuck alerts pillar_mix suggestions"
all_ok=1
for field in $REQUIRED_FIELDS; do
    if ! echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
        echo "  FAIL: missing field '$field' in JSON output"
        all_ok=0
    fi
done
if [[ "$all_ok" -eq 1 ]]; then
    SHIPS="$(echo "$JSON_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['ships_24h'])")"
    if [[ "$SHIPS" == "3" ]]; then
        echo "  PASS (valid JSON, ships_24h=3)"
    else
        echo "  FAIL: ships_24h=$SHIPS expected 3"
        exit 1
    fi
else
    exit 1
fi

# ── Test 5: exits 0 ───────────────────────────────────────────────────────────
echo "Test 5: exits 0 (no fall-through to rest of main)"
CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 0 ]]; then
    echo "  PASS (exit 0)"
else
    echo "  FAIL: exit code $RC (expected 0)"
    exit 1
fi

# ── Test 6: --window filters to shorter window ────────────────────────────────
echo "Test 6: --window 1800 (30 min) excludes 1h-old commits"
SHORT_OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief --window 1800 2>/dev/null)"
if echo "$SHORT_OUT" | grep -qE "^Ships: 0"; then
    echo "  PASS (Ships: 0 when window=30m)"
else
    echo "  FAIL: expected Ships: 0 with 30m window (all commits are 1h old)"
    echo "$SHORT_OUT" | grep -i "ship" | sed 's/^/  /'
    exit 1
fi

# ── Test 7 (CREDIBLE-120): SLO breach suppresses 'healthy' and prints breach warning ──
echo "Test 7 (CREDIBLE-120): SLO breach suppresses healthy verdict"
SLO_OUT="$(CHUMP_REPO="$TMP/repo" CHUMP_SLO_BREACH_COUNT_OVERRIDE=2 "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$SLO_OUT" | grep -q "⚠ SLO BREACH: 2 breached — chump health --slo-check for detail" \
   && ! echo "$SLO_OUT" | grep -q "fleet looks healthy"; then
    echo "  PASS (SLO breach banner shown and 'fleet looks healthy' suppressed)"
else
    echo "  FAIL: expected SLO BREACH warning without 'fleet looks healthy'"
    echo "$SLO_OUT" | sed 's/^/  /'
    exit 1
fi

# ── Test 8 (CREDIBLE-121): Alerts(30m) counts only live ambient events within last 30m ──
echo "Test 8 (CREDIBLE-121): Alerts(30m) counts only live 30m alert events"
NOW_RECENT="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
OLD_ALERT="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
cat > "$TMP/repo/.chump-locks/ambient.jsonl" <<EOF
{"ts":"$NOW_RECENT","event":"ALERT","kind":"pr_stuck","pr":101}
{"ts":"$OLD_ALERT","event":"ALERT","kind":"pr_stuck","pr":102}
EOF
ALERT_OUT="$(CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
SHELL_ALERT_OUT="$(CHUMP_REPO_ROOT="$TMP/repo" CHUMP_AMBIENT_LOG="$TMP/repo/.chump-locks/ambient.jsonl" bash "$REPO_ROOT/scripts/dispatch/fleet-brief.sh" 2>/dev/null)"
if echo "$ALERT_OUT" | grep -qE "Alerts\(30m\): 1" \
   && echo "$SHELL_ALERT_OUT" | grep -qE "Alerts\(30m\): 1"; then
    echo "  PASS (Alerts(30m): 1 — counted 10m-old alert, excluded 3h-old alert in both Rust and shell)"
else
    echo "  FAIL: expected 'Alerts(30m): 1' in output"
    echo "$ALERT_OUT" | grep -i "alert" | sed 's/^/  /'
    echo "$SHELL_ALERT_OUT" | grep -i "alert" | sed 's/^/  /'
    exit 1
fi

echo ""
echo "All fleet-brief tests passed (8/8)."
