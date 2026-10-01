#!/usr/bin/env bash
# test-almanac-liveness-reindex.sh — INFRA-3639 (TREK-14)
#
# Proves scripts/ops/almanac-liveness-refresh.sh's fleet-reindex-trigger
# logic (section "2b"): the exact live bug found while shipping INFRA-3639 —
# a present, healthy almanac binary with a completely EMPTY fleet index
# (indexed_files=0) reported "healthy" forever because section 2 of the
# liveness organ only ever watched almanac's OWN self-index marker, never
# scripts/ops/index-almanac.sh's fleet-wide sweep marker. This test asserts:
#
#   1. empty index (no fleet marker, indexed_files=0) triggers a fleet
#      reindex — index-almanac.sh runs, indexed_files goes from 0 to >0 in
#      the SAME cycle, and almanac_liveness_reindex_triggered is emitted
#   2. a populated index with a fresh fleet marker is a true no-op — no
#      second reindex call
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d -t almanac-liveness-reindex-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO_ROOT="$TMP/chump-repo"
mkdir -p "$REPO_ROOT/.chump-locks"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

export HOME="$TMP/home"
mkdir -p "$HOME"

# --- fake sibling almanac repo (local origin, offline-safe) ---------------
ALMANAC_ORIGIN="$TMP/almanac-origin.git"
ALMANAC_REPO="$TMP/almanac"
git init --quiet --bare "$ALMANAC_ORIGIN"
git init --quiet "$ALMANAC_REPO"
git -C "$ALMANAC_REPO" config user.email "test@example.com"
git -C "$ALMANAC_REPO" config user.name "Test"
echo "v1" > "$ALMANAC_REPO/src.rs"
git -C "$ALMANAC_REPO" add src.rs
git -C "$ALMANAC_REPO" commit --quiet -m "v1"
git -C "$ALMANAC_REPO" branch -M main
git -C "$ALMANAC_REPO" remote add origin "$ALMANAC_ORIGIN"
git -C "$ALMANAC_REPO" push --quiet origin main
MAIN_SHA="$(git -C "$ALMANAC_REPO" rev-parse --short HEAD)"

ALMANAC_BIN="$TMP/bin/almanac"
mkdir -p "$(dirname "$ALMANAC_BIN")"

# --- one fake fleet repo for index-almanac.sh to discover -----------------
FLEET_ROOTS="$TMP/fleetroots"
mkdir -p "$FLEET_ROOTS/demo-repo"
git init --quiet "$FLEET_ROOTS/demo-repo"

STATS_COUNT_FILE="$TMP/stats-count"
INDEX_CALLS_LOG="$TMP/index-calls.log"
echo 0 > "$STATS_COUNT_FILE"

cat > "$ALMANAC_BIN" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "almanac 0.1.0 ($MAIN_SHA built test)" ;;
  stats) echo "files: \$(cat "$STATS_COUNT_FILE" 2>/dev/null || echo 0)" ;;
  index)
    echo "\$2" >> "$INDEX_CALLS_LOG"
    echo "3" > "$STATS_COUNT_FILE"
    echo '{"status":"ok"}'
    ;;
  *) echo "unknown subcommand: \$1" >&2; exit 1 ;;
esac
EOF
chmod +x "$ALMANAC_BIN"
cp "$ALMANAC_BIN" "$(dirname "$ALMANAC_BIN")/almanac-mcp"

# BIN_STAMP matches origin/main's commit so the binary-freshness section
# (section 1) is a no-op — this test is scoped to section 2b, not the
# already-covered build/rebuild path (test-refresh-almanac-binary.sh).
echo "$MAIN_SHA" > "${ALMANAC_BIN}.commit"

FLEET_INDEX_MARKER="$TMP/almanac-state/fleet-index.last"

run_liveness() {
    CHUMP_REPO_ROOT="$REPO_ROOT" \
    CHUMP_ALMANAC_BIN="$ALMANAC_BIN" \
    CHUMP_ALMANAC_REPO="$ALMANAC_REPO" \
    CHUMP_ALMANAC_MARKER="$TMP/no-self-index-marker" \
    CHUMP_ALMANAC_HEALTH_REPO="demo" \
    CHUMP_ALMANAC_FLEET_INDEX_MARKER="$FLEET_INDEX_MARKER" \
    ALMANAC_FLEET_ROOTS="$FLEET_ROOTS" \
        bash scripts/ops/almanac-liveness-refresh.sh
}

last_health_field() {  # last_health_field <field>
    tail -20 "$AMBIENT" | grep "\"kind\":\"almanac_health\"" | tail -1 \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

# --- Case 1: empty index, no fleet marker -> self-heals in one cycle ------
run_liveness
INDEXED1="$(last_health_field indexed_files)"
[ "$INDEXED1" -gt 0 ] || { echo "FAIL: case1 expected indexed_files>0 after self-heal, got $INDEXED1"; exit 1; }
grep -q "\"kind\":\"almanac_liveness_reindex_triggered\"" "$AMBIENT" || { echo "FAIL: case1 missing almanac_liveness_reindex_triggered emission"; exit 1; }
[ -f "$FLEET_INDEX_MARKER" ] || { echo "FAIL: case1 fleet index marker not written"; exit 1; }
CALLS1=$(wc -l < "$INDEX_CALLS_LOG")
[ "$CALLS1" -eq 1 ] || { echo "FAIL: case1 expected exactly 1 repo indexed, got $CALLS1"; exit 1; }
echo "OK case1: empty fleet index self-heals — index-almanac.sh runs, indexed_files 0 -> $INDEXED1, recovery line emitted"

# --- Case 2: populated index + fresh fleet marker -> true no-op -----------
run_liveness
INDEXED2="$(last_health_field indexed_files)"
[ "$INDEXED2" -gt 0 ] || { echo "FAIL: case2 expected indexed_files still >0, got $INDEXED2"; exit 1; }
CALLS2=$(wc -l < "$INDEX_CALLS_LOG")
[ "$CALLS2" -eq 1 ] || { echo "FAIL: case2 expected no additional reindex call (still 1 total), got $CALLS2"; exit 1; }
echo "OK case2: populated index + fresh fleet marker is a true no-op — no redundant reindex"

echo "OK: almanac-liveness-refresh.sh self-heals an empty fleet index (the tonight-blindness bug) and is idempotent once healthy"
