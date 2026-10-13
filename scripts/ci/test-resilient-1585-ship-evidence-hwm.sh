#!/usr/bin/env bash
# test-resilient-1585-ship-evidence-hwm.sh — RESILIENT-1585
# Title fallback in _detect_ship_evidence must ignore PRs numbered at/below the
# claim-time PR high-water mark (pr_state has no created_at column), so an old
# merged PR doesn't mask unverified_ship and the EFFECTIVE-441 park can fire.
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
HELPER="$REPO_ROOT/scripts/dispatch/_unverified_ship_escalation.py"
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: no sqlite3"; exit 0; }
eval "$(sed -n '/^_detect_ship_evidence() {/,/^}/p' "$WORKER")"
type _detect_ship_evidence >/dev/null 2>&1 || { echo "FAIL: cannot extract fn"; exit 1; }

_shim="$(mktemp -d)"; _repo="$(mktemp -d)"; export PATH="$_shim:$PATH"
printf '#!/usr/bin/env bash\necho "  status: open"\n' > "$_shim/chump"
# gh: --search returns old PR 100 (and 205 if GH_NEW=1)
cat > "$_shim/gh" <<'SH'
#!/usr/bin/env bash
jq_expr=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jq_expr="$a"; prev="$a"; done
for a in "$@"; do
  if [ "$a" = "--search" ]; then
    if [ "${GH_NEW:-0}" = 1 ]; then j='[{"number":205},{"number":100}]'; else j='[{"number":100}]'; fi
    echo "$j" | jq -r "$jq_expr"; exit 0
  fi
done
echo ""
SH
chmod +x "$_shim"/*
mkdir -p "$_repo/.chump"
sqlite3 "$_repo/.chump/github_cache.db" <<'SQL'
CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_ref TEXT, title TEXT,
 updated_at_api TEXT NOT NULL DEFAULT '', fetched_at_local TEXT NOT NULL DEFAULT '');
INSERT INTO pr_state (number, head_ref, title) VALUES (100,'old-branch','GAP-X: old slice');
SQL

echo "--- old merged PR (100), HWM=150, no new PR -> no evidence"
out="$(REPO_ROOT="$_repo" _detect_ship_evidence GAP-X chump/gap-x-new 150)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "old PR ignored (cache + gh)" || fail "got rc=$rc out='$out'"

echo "--- RESILIENT-1451: PR 205 opened this cycle, branch deleted -> detected"
sqlite3 "$_repo/.chump/github_cache.db" "INSERT INTO pr_state (number, head_ref, title) VALUES (205,'deleted-branch','GAP-X: new');"
out="$(REPO_ROOT="$_repo" _detect_ship_evidence GAP-X chump/gap-x-new 150)"; rc=$?
[[ $rc -eq 0 && "$out" == "205" ]] && ok "cache: new PR detected" || fail "cache got rc=$rc out='$out'"
rm -f "$_repo/.chump/github_cache.db"
out="$(GH_NEW=1 REPO_ROOT="$_repo" _detect_ship_evidence GAP-X chump/gap-x-new 150)"; rc=$?
[[ $rc -eq 0 && "$out" == "205" ]] && ok "gh: new PR detected" || fail "gh got rc=$rc out='$out'"

echo "--- counter increments and parks at M when evidence is absent each cycle"
_d="$(mktemp -d)"; last=""
for i in 1 2 3 4; do
  REPO_ROOT="$_repo" _detect_ship_evidence GAP-X chump/gap-x-new 150 >/dev/null \
    || last="$(python3 "$HELPER" record "$_d" GAP-X --escalate-n 2 --park-m 4)"
done
[[ "$last" == 4* && "$last" == *park* ]] && ok "parked at M ($last)" || fail "last='$last'"
rm -rf "$_shim" "$_repo" "$_d"
echo "=== $PASS passed, $FAIL failed ==="; [[ $FAIL -eq 0 ]]
