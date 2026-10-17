#!/usr/bin/env bash
# scripts/ci/test-picker-soft-skill-open-pr.sh — INFRA-8176
#
# Two picker throughput wedges, both proven fixed here:
#   1. HARD SKILL FILTER starvation: node1 (WORKER_SKILLS=rust,docs,shell,
#      scripts,md) never saw INFRA-8174 (rust,bash,vercel). skills_required is
#      now a SOFT affinity (matching gaps first in-band, mismatches still
#      offered); WORKER_SKILLS_HARD=1 restores the hard filter.
#   2. DUPLICATE-PR RE-PICK churn: the open-PR anti-spin read a pr_state table
#      that was absent and failed open (RESILIENT-1427 re-picked in cycles
#      24/27/28 while PR #5456 was open). Now: pr_state rows are honoured
#      (closed-unmerged rows ignored), an absent table falls back to a stubbed
#      `gh pr list` through scripts/coord/lib/github_cache.sh with an on-disk
#      cache, and cache_ensure_pr_state_fresh populates pr_state.
#
# Depth: edge (fixture gap JSON + fixture github_cache.db + stubbed gh on
# PATH; no network, no chump binary). Gaps: does not exercise worker.sh's
# full cycle or the Rust (CHUMP_GITHUB_CACHE_RUST=1) refill path.
set -uo pipefail

REPO_ROOT_REAL="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT_REAL/scripts/dispatch/_pick_and_claim_gap.py"
LIB="$REPO_ROOT_REAL/scripts/coord/lib/github_cache.sh"

PASS=0; FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/locks" "$T/root/.chump"
AMB="$T/ambient.jsonl"
GAPS="$T/gaps.json"

# ── stub gh ────────────────────────────────────────────────────────────────
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB_LOG"
[ "${GH_STUB_FAIL:-0}" = "1" ] && exit 1
case "$1 $2" in
  "pr list")   cat "$GH_STUB_PR_LIST" ;;
  "repo view") echo "acme/widgets" ;;
  *)           if [ "$1" = "api" ]; then cat "$GH_STUB_PULLS"; else exit 1; fi ;;
esac
STUB
chmod +x "$T/bin/gh"
export GH_STUB_LOG="$T/gh.log"; : > "$GH_STUB_LOG"
export GH_STUB_PR_LIST="$T/pr-list.json"
export GH_STUB_PULLS="$T/pulls.json"

gap() { # id priority skills_json created_at
  printf '{"id":"%s","status":"open","priority":"%s","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":%s,"created_at":%s}' \
    "$1" "$2" "$3" "$4"
}

pick() { # env... ; dry-run pick, prints picked id
  env -u CHUMP_PICKER_OPEN_PR_FALLBACK -u WORKER_SKILLS_HARD \
    PATH="$T/bin:$PATH" GAP_JSON_FILE="$GAPS" CHUMP_LOCK_DIR="$T/locks" \
    CHUMP_SESSION_ID=test-8176 CHUMP_FLEET_DRY_RUN=1 CHUMP_REBALANCE=0 \
    CHUMP_ACTIVE_MISSION=NONE-0 WORKER_INDEX=1 AMBIENT_JSONL="$AMB" \
    REPO_ROOT="$T/root" CHUMP_OPEN_PR_LOOKUP_DIR="$T/root/.chump/open-pr-by-gap" \
    "$@" python3 -I "$PICKER" 2>"$T/pick.err"
}

has_event() { # kind [field=value]
  python3 -I - "$AMB" "$@" <<'PY'
import json, sys
path, kind = sys.argv[1], sys.argv[2]
want = dict(a.split("=", 1) for a in sys.argv[3:])
for line in open(path):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("kind") != kind:
        continue
    if all(str(e.get(k)) == v or (isinstance(e.get(k), list) and v in e.get(k)) for k, v in want.items()):
        sys.exit(0)
sys.exit(1)
PY
}

echo "== 1. soft skill filter =="
printf '[%s,%s]' \
  "$(gap INFRA-9001 P1 '"[\"vercel\"]"' 1000)" \
  "$(gap INFRA-9002 P1 '"[\"rust\"]"' 2000)" > "$GAPS"
: > "$AMB"
check "matching gap ranks before the vercel gap in the same band" \
  "$(pick WORKER_SKILLS=rust,docs,shell,scripts,md)" "INFRA-9002"

printf '[%s]' "$(gap INFRA-9001 P1 '"[\"vercel\"]"' 1000)" > "$GAPS"
: > "$AMB"
check "vercel gap is OFFERED to a worker without vercel (soft, default)" \
  "$(pick WORKER_SKILLS=rust,docs,shell,scripts,md)" "INFRA-9001"
if has_event picker_soft_skill_demoted picked=INFRA-9001 missing_skills=vercel; then
  ok "kind=picker_soft_skill_demoted emitted with missing_skills"
else
  bad "kind=picker_soft_skill_demoted not emitted"
fi

check "WORKER_SKILLS_HARD=1 restores the hard filter (nothing offered)" \
  "$(pick WORKER_SKILLS=rust,docs,shell,scripts,md WORKER_SKILLS_HARD=1)" ""
if grep -q '"skills_mismatch": 1' "$T/pick.err"; then ok "hard filter counts skills_mismatch"; else bad "skills_mismatch reason missing: $(cat "$T/pick.err")"; fi

printf '[%s,%s]' \
  "$(gap INFRA-9003 P1 '"[\"vercel\",\"nats\"]"' 1000)" \
  "$(gap INFRA-9004 P2 '"[\"rust\"]"' 500)" > "$GAPS"
check "soft demotion never crosses priority (P1 mismatch beats P2 match)" \
  "$(pick WORKER_SKILLS=rust)" "INFRA-9003"

echo "== 2. open-PR anti-spin with pr_state present =="
python3 -I - "$T/root/.chump/github_cache.db" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_ref TEXT, merged_at TEXT, "
            "title TEXT, fetched_at_local TEXT, raw_payload_json TEXT)")
con.executemany("INSERT INTO pr_state VALUES (?,?,?,?,?,?)", [
    (5456, "chump/infra-9101-fleet-1", None, "INFRA-9101: open unmerged",
     "2026-10-16T00:00:00Z", json.dumps({"action": "opened", "pull_request": {"state": "open"}})),
    (5457, "chump/infra-9102-fleet-1", None, "INFRA-9102: closed without merge",
     "2026-10-16T00:00:00Z", json.dumps({"state": "closed"})),
])
con.commit()
PY
printf '[%s,%s]' "$(gap INFRA-9101 P0 '""' 1000)" "$(gap INFRA-9102 P1 '""' 1000)" > "$GAPS"
: > "$AMB"
check "gap with an open PR in pr_state is skipped; closed-unmerged row does not block" \
  "$(pick)" "INFRA-9102"
if has_event picker_skipped_open_pr gaps=INFRA-9101 source=pr_state; then
  ok "kind=picker_skipped_open_pr emitted (source=pr_state)"
else
  bad "kind=picker_skipped_open_pr not emitted for pr_state skip"
fi

echo "== 3. pr_state ABSENT -> gh fallback through github_cache.sh =="
rm -f "$T/root/.chump/github_cache.db"
python3 -I -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute('CREATE TABLE other (x)')" \
  "$T/root/.chump/github_cache.db"   # db exists, table absent (the node1 shape)
printf '[%s,%s]' "$(gap INFRA-9201 P0 '""' 1000)" "$(gap INFRA-9202 P1 '""' 1000)" > "$GAPS"
cat > "$GH_STUB_PR_LIST" <<'J'
[{"number":5456,"title":"INFRA-9201: already shipped, awaiting merge"},
 {"number":5999,"title":"fix(INFRA-9201): a reference PR that does not count"}]
J
: > "$AMB"; : > "$GH_STUB_LOG"
check "without CHUMP_PICKER_OPEN_PR_FALLBACK the picker stays offline (unit-test default)" \
  "$(pick)" "INFRA-9201"
[ ! -s "$GH_STUB_LOG" ] && ok "no gh call when fallback is not enabled" || bad "gh was called without the fallback flag"
check "fallback: gap with an open PR (per gh) is never offered; next gap is" \
  "$(pick CHUMP_PICKER_OPEN_PR_FALLBACK=1)" "INFRA-9202"
grep -q 'pr list --state open --search INFRA-9201 in:title --json number,title' "$GH_STUB_LOG" \
  && ok "gh pr list --state open --search '<GAP-ID> in:title' was the lookup" \
  || bad "unexpected gh call: $(cat "$GH_STUB_LOG")"
if has_event picker_skipped_open_pr gaps=INFRA-9201 source=gh; then
  ok "kind=picker_skipped_open_pr emitted (source=gh)"
else
  bad "kind=picker_skipped_open_pr not emitted for gh skip"
fi
calls_before="$(grep -c 'pr list' "$GH_STUB_LOG")"
pick CHUMP_PICKER_OPEN_PR_FALLBACK=1 >/dev/null
calls_after="$(grep -c 'pr list' "$GH_STUB_LOG")"
check "second cycle inside the 10-minute TTL reads the on-disk cache (no new gh call)" \
  "$calls_after" "$calls_before"
check "cached answer still skips the open-PR gap" \
  "$(pick CHUMP_PICKER_OPEN_PR_FALLBACK=1)" "INFRA-9202"

rm -rf "$T/root/.chump/open-pr-by-gap"
check "gh down -> unknown fails open (offline node never wedges)" \
  "$(pick CHUMP_PICKER_OPEN_PR_FALLBACK=1 GH_STUB_FAIL=1)" "INFRA-9201"

echo "== 4. cache_ensure_pr_state_fresh populates pr_state =="
rm -f "$T/root/.chump/github_cache.db" "$T/root/.chump/pr-state-refresh.stamp"
cat > "$GH_STUB_PULLS" <<'J'
[{"number":6001,"title":"INFRA-9301: open","state":"open","head":{"ref":"chump/infra-9301-fleet-1","sha":"a"},"base":{"ref":"main","sha":"b"},"merged_at":null,"user":{"login":"bot"},"updated_at":"2026-10-16T00:00:00Z"}]
J
: > "$GH_STUB_LOG"
( cd "$T/root" && PATH="$T/bin:$PATH" REPO_ROOT="$T/root" bash -c 'source "$1" && cache_ensure_pr_state_fresh' _ "$LIB" )
check "refresh exits 0 and creates pr_state" \
  "$(python3 -I -c 'import sqlite3,sys; print(",".join(str(r[0]) for r in sqlite3.connect(sys.argv[1]).execute("SELECT number FROM pr_state")))' "$T/root/.chump/github_cache.db" 2>/dev/null)" "6001"
api_calls="$(grep -c '^api ' "$GH_STUB_LOG")"
( cd "$T/root" && PATH="$T/bin:$PATH" REPO_ROOT="$T/root" bash -c 'source "$1" && cache_ensure_pr_state_fresh' _ "$LIB" )
check "a second call inside max-age does not refill" "$(grep -c '^api ' "$GH_STUB_LOG")" "$api_calls"

# reconcile: PR 6001 closed upstream; refresh with an empty open list marks it closed
echo '[]' > "$GH_STUB_PULLS"
( cd "$T/root" && PATH="$T/bin:$PATH" REPO_ROOT="$T/root" bash -c 'source "$1" && cache_ensure_pr_state_fresh 0' _ "$LIB" )
printf '[%s]' "$(gap INFRA-9301 P1 '""' 1000)" > "$GAPS"
check "a PR that left the open list no longer blocks its gap (reconciled closed)" \
  "$(pick)" "INFRA-9301"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] && echo "PASS: INFRA-8176 soft skill filter + open-PR anti-spin" || { echo "FAIL"; exit 1; }
