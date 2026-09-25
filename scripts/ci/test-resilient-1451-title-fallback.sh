#!/usr/bin/env bash
# test-resilient-1451-title-fallback.sh — RESILIENT-1451
#
# RESILIENT-1449 gave _detect_ship_evidence a ground-truth check keyed on the
# cycle's HEAD BRANCH (cache `head_ref=`, then `gh pr list --head`). That
# keying goes blind once the PR merges: a fast auto-merge DELETES the head
# branch, so both the cache row and gh's `--head` filter come up empty even
# though the PR MERGED (live: RESILIENT-1447 -> PR #4816 MERGED and
# RESILIENT-1450 -> PR #4817 MERGED, both logged kind=unverified_ship).
#
# Fix verified here: when the branch-keyed lookup is empty, fall back to a
# GAP-ID-keyed title match (PR titles are always "<GAP_ID>: <summary>") —
# in BOTH the cache path and the live-gh fallback path. Tests the REAL
# _detect_ship_evidence extracted from scripts/dispatch/worker.sh, not a
# replica (durable-fix doctrine, same pattern as test-resilient-1449).
#
# Run: ./scripts/ci/test-resilient-1451-title-fallback.sh
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
[[ -f "$WORKER" ]] || { echo "FAIL: worker.sh not found"; exit 1; }

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not available"; exit 0; }

echo "=== RESILIENT-1451 branch-deleted-after-merge title-fallback tests ==="

_fn_dse="$(sed -n '/^_detect_ship_evidence() {/,/^}/p' "$WORKER")"
if [[ -n "$_fn_dse" ]]; then eval "$_fn_dse"; fi
if type _detect_ship_evidence >/dev/null 2>&1; then
    ok "extracted + loaded the real _detect_ship_evidence from worker.sh"
else
    fail "could not extract _detect_ship_evidence from worker.sh"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

_shimdir="$(mktemp -d)"
_repo="$(mktemp -d)"
export PATH="$_shimdir:$PATH"

# chump shim: gap not ready_to_ship/done/shipped per canonical status — so
# the status-shortcut must NOT be what saves this scenario.
cat > "$_shimdir/chump" <<'SH'
#!/usr/bin/env bash
echo "  status: open"
SH
chmod +x "$_shimdir/chump"

# ── Scenario 1: cache has the PR, but keyed by an OLD/deleted head_ref ──────
# (merge deleted the branch; the cached row's head_ref no longer matches the
# branch this worker constructs). Title carries the GAP_ID, though.
mkdir -p "$_repo/.chump"
sqlite3 "$_repo/.chump/github_cache.db" <<'SQL'
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT, auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0, merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL, raw_payload_json TEXT
);
INSERT INTO pr_state (number, head_ref, title, merged_at, updated_at_api, fetched_at_local)
VALUES (4816, 'some-stale-branch-name', 'RESILIENT-1447: fix the thing', '2026-09-25T00:00:00Z', '2026-09-25T00:00:00Z', '2026-09-25T00:00:00Z');
SQL

# gh must NOT be consulted for this scenario — cache title fallback alone
# should resolve it. Make gh fail loudly if called, so a pass can't hide a
# silent gh dependency.
cat > "$_shimdir/gh" <<'SH'
#!/usr/bin/env bash
echo "FAIL: gh should not have been called (cache title fallback should resolve first)" >&2
exit 1
SH
chmod +x "$_shimdir/gh"

_out="$(REPO_ROOT="$_repo" _detect_ship_evidence RESILIENT-1447 chump/resilient-1447-claim)"; _rc=$?
if [[ $_rc -eq 0 && "$_out" == "4816" ]]; then
    ok "cache row with STALE head_ref but matching GAP-ID title -> resolved via title fallback (rc=0, '$_out')"
else
    fail "cache title-fallback should resolve merged-branch-deleted PR; got rc=$_rc out='$_out'"
fi
rm -f "$_repo/.chump/github_cache.db"

# ── Scenario 2: no cache db at all; gh --head comes up empty (branch gone
# after merge) but gh --search by GAP_ID in:title finds it ─────────────────
cat > "$_shimdir/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "$a" == "--search" ]]; then
        echo "4817"
        exit 0
    fi
done
# --head path (branch deleted post-merge): no match.
echo ""
SH
chmod +x "$_shimdir/gh"

_out="$(REPO_ROOT="$_repo" _detect_ship_evidence RESILIENT-1450 chump/resilient-1450-claim)"; _rc=$?
if [[ $_rc -eq 0 && "$_out" == "4817" ]]; then
    ok "no cache db + gh --head empty (branch deleted) -> gh --search by GAP-ID title resolves it (rc=0, '$_out')"
else
    fail "gh title-search fallback should resolve merged-branch-deleted PR; got rc=$_rc out='$_out'"
fi

# ── Scenario 3: truly no evidence anywhere -> still correctly unverified ───
cat > "$_shimdir/gh" <<'SH'
#!/usr/bin/env bash
echo ""
SH
chmod +x "$_shimdir/gh"
_out="$(REPO_ROOT="$_repo" _detect_ship_evidence RESILIENT-9999 chump/resilient-9999-claim)"; _rc=$?
if [[ $_rc -ne 0 && -z "$_out" ]]; then
    ok "no evidence anywhere -> still correctly reports NO evidence (rc=$_rc) — fallback doesn't manufacture false positives"
else
    fail "no-evidence case should return nothing; got rc=$_rc out='$_out'"
fi

rm -rf "$_shimdir" "$_repo"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
