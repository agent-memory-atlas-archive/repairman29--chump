#!/usr/bin/env bash
# CI test for INFRA-8097.
#
# board-tick.sh ran the collector as a RELOCATED COPY:
#   git show origin/main:scripts/ops/vital-signs.sh > ~/.chump/_vs.sh && bash ~/.chump/_vs.sh
# so SCRIPT_DIR resolved to ~/.chump and the `source "$SCRIPT_DIR/lib/..."` calls
# in vital-signs.sh died with 'No such file'. stderr was discarded
# (`>/dev/null 2>&1`) and the exit was swallowed (`|| true`), so the board kept
# reporting merge_throughput=null with the basis "gh pr list returned no parseable
# count" — which was FALSE, because gh never ran at all.
#
# The collector copied OUTSIDE the repo must either
#   (a) read a real numeric merge_throughput, or
#   (b) name the missing lib in its basis
# and NEVER emit the 'gh pr list' basis when the lib is absent.
#
# This test fails on main pre-fix (basis == "uninstrumented: gh pr list returned
# no parseable count") and passes once the lib resolution + honest basis land.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VITAL_SIGNS_SH="${REPO_ROOT}/scripts/ops/vital-signs.sh"
LIB_DIR="${REPO_ROOT}/scripts/ops/lib"

FAIL=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }

echo "[test-vital-signs-relocated-collector] INFRA-8097 — relocated collector names its missing lib, never blames gh"

[[ -f "$VITAL_SIGNS_SH" ]] || { echo "  [FAIL] scripts/ops/vital-signs.sh not found" >&2; exit 1; }
[[ -d "$LIB_DIR" ]] || { echo "  [FAIL] scripts/ops/lib not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] jq not found" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "  [FAIL] sqlite3 not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# HOME is stubbed so the script's REAL_HOME self-heal cannot wander back into a
# real checkout — that is what makes this deterministic on a case-insensitive
# macOS filesystem as well as on Linux.
run_relocated() {
  local dest="$1" root="$2" script="$3"
  HOME="$TMP/$dest/home" CHUMP_REPO_ROOT="$root" \
  CHUMP_AMBIENT_LOG="$TMP/$dest/amb.jsonl" \
  bash "$script" --dry-run 2>"$TMP/$dest/err.log"
}

echo "[1. collector copied outside the repo, NO lib anywhere -> names the missing lib]"
mkdir -p "$TMP/case1/home"
cp "$VITAL_SIGNS_SH" "$TMP/case1/_vs.sh"
out1="$(run_relocated case1 "$TMP/case1/nowhere" "$TMP/case1/_vs.sh")"

mt1="$(printf '%s' "$out1" | jq -r '.signs[]|select(.key=="merge_throughput")|.value' 2>/dev/null)"
basis1="$(printf '%s' "$out1" | jq -r '.signs[]|select(.key=="merge_throughput")|.basis' 2>/dev/null)"
[[ "$mt1" == "null" ]] && ok "merge_throughput is null when the lib is missing (no fabricated 0)" \
  || fail "expected merge_throughput=null with a missing lib, got '$mt1'"
[[ "$basis1" == *"collector lib missing"* ]] && ok "basis names the missing lib" \
  || fail "expected basis to name the missing lib, got '$basis1'"
[[ "$basis1" != *"uninstrumented: gh pr list"* ]] && ok "basis never blames gh (gh never ran)" \
  || fail "basis still blames gh: '$basis1'"

hi1="$(printf '%s' "$out1" | jq -r '.signs[]|select(.key=="human_intervention")|.basis' 2>/dev/null)"
[[ "$hi1" == *"collector lib missing"* ]] && ok "human_intervention basis also names the missing lib" \
  || fail "human_intervention basis did not name the missing lib, got '$hi1'"

echo "[2. collector is LOUD about the break and free of the two failure signatures]"
[[ -s "$TMP/case1/err.log" ]] && ok "collector reports the missing lib to stderr (fails loud)" \
  || fail "expected collector to speak up on stderr, got silence"
grep -qiE "command not found|No such file or directory" "$TMP/case1/err.log" \
  && fail "collector leaked 'command not found' / 'No such file' to stderr" \
  || ok "no 'command not found' / 'No such file' from the collector"

echo "[3. relocated copy WITH the lib resolvable via REPO_ROOT -> numeric merge_throughput]"
mkdir -p "$TMP/case2/home" "$TMP/case2/collector" \
         "$TMP/case2/repo/scripts/ops" "$TMP/case2/repo/.chump"
touch "$TMP/case2/repo/scripts/ops/organ-manifest.txt"
cp -R "$LIB_DIR" "$TMP/case2/repo/scripts/ops/lib"
sqlite3 "$TMP/case2/repo/.chump/github_cache.db" \
  "CREATE TABLE pr_state (merged_at TEXT);"
for _i in 1 2 3 4 5 6 7; do
  sqlite3 "$TMP/case2/repo/.chump/github_cache.db" \
    "INSERT INTO pr_state(merged_at) VALUES ('$(date -u +%Y-%m-%dT%H:%M:%SZ)');"
done
cp "$VITAL_SIGNS_SH" "$TMP/case2/collector/_vs.sh"
{
  printf '{"ts":"%s","kind":"operator_page"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","kind":"operator_paged"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","kind":"pager_notified"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP/case2/amb.jsonl"
out2="$(run_relocated case2 "$TMP/case2/repo" "$TMP/case2/collector/_vs.sh")"

mt2="$(printf '%s' "$out2" | jq -r '.signs[]|select(.key=="merge_throughput")|.value' 2>/dev/null)"
basis2="$(printf '%s' "$out2" | jq -r '.signs[]|select(.key=="merge_throughput")|.basis' 2>/dev/null)"
[[ "$mt2" == "7" ]] && ok "merge_throughput reads 7 from the cache-backed lib" \
  || fail "expected merge_throughput=7 from the relocated collector, got '$mt2'"
[[ "$basis2" != *"uninstrumented: gh pr list"* ]] && ok "numeric path does not carry the gh blame basis" \
  || fail "numeric path still carries the gh blame basis: '$basis2'"

hi2="$(printf '%s' "$out2" | jq -r '.signs[]|select(.key=="human_intervention")|.value' 2>/dev/null)"
[[ "$hi2" == "3" ]] && ok "human_intervention is numeric when the lib resolves ($hi2)" \
  || fail "expected human_intervention=3 from 3 seeded pages, got '$hi2'"

if [[ "$FAIL" == 0 ]]; then
  echo "[test-vital-signs-relocated-collector] PASS"
else
  echo "[test-vital-signs-relocated-collector] FAIL" >&2
fi
exit "$FAIL"
