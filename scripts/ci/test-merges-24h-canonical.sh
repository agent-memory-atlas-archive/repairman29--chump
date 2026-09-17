#!/usr/bin/env bash
# scripts/ci/test-merges-24h-canonical.sh — INFRA-3843 (parent INFRA-3841)
#
# Proves the "reconcile 1/9" claim: scripts/ops/vital-signs.sh (sign
# merge_throughput), scripts/ops/faculty-collector.sh (faculty build), and
# scripts/ops/lib/merges-24h.sh (the shared helper dashboard.rs also shells
# out to) all report the IDENTICAL merges_24h count when pointed at the same
# fixture cache. Self-contained + offline: a synthetic .chump/github_cache.db
# is populated with a known set of merged PRs (some inside the 24h window,
# some outside as a negative control) so no `gh`/network call is needed.

set -uo pipefail   # NOT -e: we assert exit codes / values explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/merges-24h.sh"
VITAL="$REPO_ROOT/scripts/ops/vital-signs.sh"
FACULTY="$REPO_ROOT/scripts/ops/faculty-collector.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

for f in "$LIB" "$VITAL" "$FACULTY"; do
  [[ -f "$f" ]] || { printf 'FATAL: %s not found\n' "$f" >&2; exit 1; }
done

# ── fixture: 5 PRs merged 1h ago (inside 24h window), 2 merged 3d ago (outside) ──
DATA_ROOT="$TMP/data"
mkdir -p "$DATA_ROOT/.chump" "$DATA_ROOT/.chump-locks" "$DATA_ROOT/scripts/ops"
# vital-signs.sh self-heals REPO_ROOT to a real checkout when this manifest
# is missing (honest-instrument fix, 2026-08-22) — plant a stub so it trusts
# our fixture DATA_ROOT instead of silently redirecting to the real repo.
: > "$DATA_ROOT/scripts/ops/organ-manifest.txt"
NOW_EPOCH="$(date -u +%s)"
merged_1h_ago="$(date -u -d "@$((NOW_EPOCH - 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"
merged_3d_ago="$(date -u -d "@$((NOW_EPOCH - 259200))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"

DB="$DATA_ROOT/.chump/github_cache.db"
sqlite3 "$DB" <<SQL
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL DEFAULT '', fetched_at_local TEXT NOT NULL DEFAULT '',
    raw_payload_json TEXT, merge_state_status TEXT
);
INSERT INTO pr_state (number, merged_at, title, updated_at_api, fetched_at_local) VALUES
  (1, '$merged_1h_ago', 'fixture 1', '$merged_1h_ago', '$merged_1h_ago'),
  (2, '$merged_1h_ago', 'fixture 2', '$merged_1h_ago', '$merged_1h_ago'),
  (3, '$merged_1h_ago', 'fixture 3', '$merged_1h_ago', '$merged_1h_ago'),
  (4, '$merged_1h_ago', 'fixture 4', '$merged_1h_ago', '$merged_1h_ago'),
  (5, '$merged_1h_ago', 'fixture 5', '$merged_1h_ago', '$merged_1h_ago'),
  (6, '$merged_3d_ago', 'fixture outside window', '$merged_3d_ago', '$merged_3d_ago'),
  (7, '$merged_3d_ago', 'fixture outside window', '$merged_3d_ago', '$merged_3d_ago');
SQL

EXPECT=5

# ── 1. the shared lib directly ────────────────────────────────────────────────
echo "[test-merges-24h-canonical] lib helper"
source "$LIB"
lib_val="$(merges_24h "$DATA_ROOT" "repairman29/chump")"
[[ "$lib_val" == "$EXPECT" ]] \
  && _ok "merges_24h() == $EXPECT (got $lib_val)" \
  || _fail "merges_24h() expected $EXPECT, got '$lib_val'"

# ── 2. vital-signs.sh --dry-run, sign merge_throughput.value ─────────────────
echo "[test-merges-24h-canonical] vital-signs.sh"
vital_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_VITALS_OUT="$TMP/vitals-out.json" \
  CHUMP_AMBIENT_LOG="$DATA_ROOT/.chump-locks/ambient.jsonl" \
  CHUMP_GH_REPO="repairman29/chump" \
  bash "$VITAL" --dry-run 2>/dev/null)"
vital_val="$(printf '%s' "$vital_json" | jq -r '.signs[] | select(.key=="merge_throughput") | .value')"
[[ "$vital_val" == "$EXPECT" ]] \
  && _ok "vital-signs merge_throughput.value == $EXPECT (got $vital_val)" \
  || _fail "vital-signs merge_throughput.value expected $EXPECT, got '$vital_val'"

# INFRA-7142 (INFRA-3841 slice): the top-level document must ALSO carry the
# canonical `merges_24h` column name, not just the merge_throughput sign.
vital_canonical="$(printf '%s' "$vital_json" | jq -r '.merges_24h')"
[[ "$vital_canonical" == "$EXPECT" ]] \
  && _ok "vital-signs merges_24h (canonical column) == $EXPECT (got $vital_canonical)" \
  || _fail "vital-signs merges_24h (canonical column) expected $EXPECT, got '$vital_canonical'"

# ── 3. faculty-collector.sh --dry-run, build_merges_24h ──────────────────────
echo "[test-merges-24h-canonical] faculty-collector.sh"
faculty_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_FACULTY_OUT="$TMP/faculty-out.json" \
  CHUMP_AMBIENT_LOG="$DATA_ROOT/.chump-locks/ambient.jsonl" \
  CHUMP_GH_REPO="repairman29/chump" \
  CHUMP_ALMANAC_REPO="$TMP/no-almanac" \
  CHUMP_ALMANAC_BIN="$TMP/no-almanac/target/release/almanac" \
  bash "$FACULTY" --dry-run 2>/dev/null)"
faculty_val="$(printf '%s' "$faculty_json" | jq -r '.faculties[] | select(.key=="build") | .value')"
[[ "$faculty_val" == "$EXPECT" ]] \
  && _ok "faculty-collector build merges == $EXPECT (got $faculty_val)" \
  || _fail "faculty-collector build merges expected $EXPECT, got '$faculty_val'"

# INFRA-7142 (INFRA-3841 slice): the top-level document must ALSO carry the
# canonical `merges_24h` column name, not just the build faculty's value.
faculty_canonical="$(printf '%s' "$faculty_json" | jq -r '.merges_24h')"
[[ "$faculty_canonical" == "$EXPECT" ]] \
  && _ok "faculty-collector merges_24h (canonical column) == $EXPECT (got $faculty_canonical)" \
  || _fail "faculty-collector merges_24h (canonical column) expected $EXPECT, got '$faculty_canonical'"

echo
echo "[test-merges-24h-canonical] $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
