#!/usr/bin/env bash
# scripts/ci/test-admin-merges-7d.sh — CREDIBLE-1525 (PHASE-R R3 slice of CREDIBLE-1492)
#
# Validates the admin_merges_7d counter end-to-end against a fixture GitHub
# cache (.chump/github_cache.db). An admin merge is a merged PR whose merge was
# NOT via auto-merge AND whose required `verified` check was not success at
# merge time.
#
#   AC1: chump kpi report --json .admin_merges.admin_merges_7d == the
#        gh-shaped count computed independently over the same fixture.
#   AC2: kind=admin_merge_executed registered + emitted on detection (deduped).
#   AC3: chump health --temp --json .admin_merges_7d shows the same number.
#
# The Rust unit tests in crates/chump-kpi-report/src/admin_merges.rs cover the
# pure classifier (cache + gh-json paths, case-insensitivity, dedup); this
# fixture proves the CLI integration + the cross-surface agreement.

set -uo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== CREDIBLE-1525: admin_merges_7d counter ==="
echo

# ── (0) registry + source contract ─────────────────────────────────────────
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "kind: admin_merge_executed" "$REG"; then
    ok "admin_merge_executed registered in EVENT_REGISTRY.yaml"
else
    fail "admin_merge_executed NOT registered in EVENT_REGISTRY.yaml"
fi
source "$SCRIPT_DIR/lib/source-grep.sh" 2>/dev/null || true
MOD="$REPO_ROOT/crates/chump-kpi-report/src/admin_merges.rs"
if [[ -f "$MOD" ]] && grep -q '"kind":"admin_merge_executed"' "$MOD"; then
    ok "emit site carries literal kind=admin_merge_executed"
else
    fail "emit literal missing in admin_merges.rs"
fi

# ── resolve chump binary ────────────────────────────────────────────────────
BIN="${CHUMP_BIN:-}"
if [[ -z "$BIN" ]]; then
    for cand in \
        "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" \
        "$REPO_ROOT/target/debug/chump" \
        "$HOME/.cargo/chump-shared-target/debug/chump"; do
        [[ -x "$cand" ]] && BIN="$cand" && break
    done
fi
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    echo "  SKIP: no chump binary found (set CHUMP_BIN); source contract checks still ran."
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
fi
for tool in sqlite3 python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "  SKIP: $tool unavailable"; exit 0; }
done

# ── fixture: a GitHub cache with a mix of merge shapes ──────────────────────
FIX="$(mktemp -d)"
# W-013 immunization: drop workflow-injected env so our fixture root wins.
unset CHUMP_LOCK_DIR CHUMP_AMBIENT_LOG
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.chump"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -v-10d +%Y-%m-%dT%H:%M:%SZ)"

sqlite3 "$FIX/.chump/github_cache.db" <<SQL
CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_sha TEXT,
  auto_merge_enabled INTEGER NOT NULL DEFAULT 0, merged_at TEXT);
CREATE TABLE check_runs (head_sha TEXT, name TEXT, conclusion TEXT,
  PRIMARY KEY (head_sha, name));
-- #101 admin: manual merge, verified FAILED, recent.
INSERT INTO pr_state VALUES (101,'shaA',0,'$NOW');
INSERT INTO check_runs VALUES ('shaA','verified','failure');
-- #102 clean auto-merge, verified green → NOT admin.
INSERT INTO pr_state VALUES (102,'shaB',1,'$NOW');
INSERT INTO check_runs VALUES ('shaB','verified','success');
-- #103 manual merge but verified green → NOT admin.
INSERT INTO pr_state VALUES (103,'shaC',0,'$NOW');
INSERT INTO check_runs VALUES ('shaC','verified','success');
-- #104 admin: manual merge, NO verified check at all, recent.
INSERT INTO pr_state VALUES (104,'shaD',0,'$NOW');
-- #105 manual + verified FAILED but 10 days old → out of 7d window.
INSERT INTO pr_state VALUES (105,'shaE',0,'$OLD');
INSERT INTO check_runs VALUES ('shaE','verified','failure');
-- #106 admin: verified SUCCESS uppercase is still green (case-insensitive).
INSERT INTO pr_state VALUES (106,'shaF',0,'$NOW');
INSERT INTO check_runs VALUES ('shaF','verified','SUCCESS');
SQL

# gh-shaped reference count: the same definition, computed independently via
# SQL over the fixture (merged, not auto-merge, no verified-success check-run,
# within 7d). This is what `gh pr list --json ...` would report.
CUTOFF="$(python3 -c 'import time;print(int(time.time())-7*86400)')"
EXPECTED="$(sqlite3 "$FIX/.chump/github_cache.db" "
  SELECT COUNT(*) FROM pr_state p
  WHERE p.merged_at IS NOT NULL
    AND p.auto_merge_enabled = 0
    AND CAST(strftime('%s', p.merged_at) AS INTEGER) >= $CUTOFF
    AND NOT EXISTS (
      SELECT 1 FROM check_runs c
      WHERE c.head_sha = p.head_sha
        AND LOWER(c.name) = 'verified'
        AND LOWER(c.conclusion) = 'success');")"
echo "  (gh-shaped reference count over fixture: $EXPECTED; hand-expected: 2)"

# ── AC1: kpi report admin_merges_7d matches the reference ───────────────────
KPI_JSON="$(CHUMP_REPO="$FIX" "$BIN" kpi report --json 2>/dev/null)"
GOT="$(printf '%s' "$KPI_JSON" | python3 -c \
  "import sys,json;print(json.load(sys.stdin)['admin_merges']['admin_merges_7d'])" 2>/dev/null || echo "?")"
SRC="$(printf '%s' "$KPI_JSON" | python3 -c \
  "import sys,json;print(json.load(sys.stdin)['admin_merges']['source'])" 2>/dev/null || echo "?")"
if [[ "$GOT" == "$EXPECTED" && "$GOT" == "2" ]]; then
    ok "AC1: kpi admin_merges_7d=$GOT matches gh-shaped count (source=$SRC)"
else
    fail "AC1: kpi admin_merges_7d=$GOT, expected $EXPECTED (hand=2), source=$SRC"
fi

# ── AC2: kind=admin_merge_executed emitted on detection, deduped on re-run ──
EMITTED="$(grep -c '"kind":"admin_merge_executed"' "$FIX/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)"
if [[ "$EMITTED" == "2" ]]; then
    ok "AC2: emitted $EMITTED admin_merge_executed events on detection"
else
    fail "AC2: expected 2 admin_merge_executed events, got $EMITTED"
fi
CHUMP_REPO="$FIX" "$BIN" kpi report --json >/dev/null 2>&1
EMITTED2="$(grep -c '"kind":"admin_merge_executed"' "$FIX/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)"
if [[ "$EMITTED2" == "2" ]]; then
    ok "AC2: re-run is idempotent (still $EMITTED2, deduped by PR number)"
else
    fail "AC2: re-run duplicated events (now $EMITTED2, expected 2)"
fi
if grep -q '"pr":101' "$FIX/.chump-locks/ambient.jsonl" \
   && grep -q '"pr":104' "$FIX/.chump-locks/ambient.jsonl"; then
    ok "AC2: emitted events carry the detected PR numbers (101, 104)"
else
    fail "AC2: emitted events missing expected PR numbers"
fi

# ── AC3: floor_temp shows the same number ───────────────────────────────────
TEMP_JSON="$(CHUMP_REPO="$FIX" "$BIN" health --temp --json 2>/dev/null)"
TEMP_N="$(printf '%s' "$TEMP_JSON" | python3 -c \
  "import sys,json;print(json.load(sys.stdin).get('admin_merges_7d'))" 2>/dev/null || echo "?")"
if [[ "$TEMP_N" == "$GOT" ]]; then
    ok "AC3: floor_temp admin_merges_7d=$TEMP_N matches kpi report"
else
    fail "AC3: floor_temp admin_merges_7d=$TEMP_N != kpi $GOT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
