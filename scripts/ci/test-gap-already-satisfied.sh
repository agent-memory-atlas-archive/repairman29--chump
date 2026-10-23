#!/usr/bin/env bash
# scripts/ci/test-gap-already-satisfied.sh — INFRA-3826
#
# Verifies the --check-already-satisfied backstop of gap-doctor-reconcile.py:
# the durable periodic catch for open gaps with NO closed_pr whose work is
# already on main (the class the live-only INFRA-3808 worker close misses and
# --check-closure-drift is blind to).
#
#   CREDIBLE-1551 (Phase R R2, AC2): the auto-close is RETIRED. The covering PR
#   belongs to a DIFFERENT gap and is not gap_prs-linked here, so the ship
#   FK-gate refuses it; this pass now only FLAGS. Asserted here:
#   1. HIGH confidence (cycle log shows already-shipped + covering PR MERGED) →
#      gap left OPEN, kind=gap_already_satisfied_flagged emitted with
#      reason=fk_close_not_applicable. NO gap_already_satisfied_closed event.
#   2. LOW confidence (covering PR NOT merged) → gap left OPEN, only
#      kind=gap_already_satisfied_flagged (reason=pr_not_merged) emitted.
#   3. Gaps with no cycle log, or a log with no signal, are left untouched.
#   4. Reads the gap store DIRECTLY from CHUMP_STATE_DB (NOT `chump gap list`).
#   5. dry-run writes nothing (no db mutation, no ambient line).
#   6. Exits 0 (self-healing oneshot stays green); closes nothing, ever.
#
# Uses a fake `gh` on PATH so the test needs no network/auth.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor-reconcile.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Fake `gh`: pulls/9999 merged, pulls/9998 closed-not-merged ──────────────
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then echo "test/repo"; exit 0; fi
if [[ "$1" == "api" ]]; then
    case "$2" in
        */pulls/9999) echo "closed 2026-08-25T12:00:00Z"; exit 0 ;;
        */pulls/9998) echo "open -"; exit 0 ;;
        *) echo "fake-gh: unhandled $2" >&2; exit 1 ;;
    esac
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"

# ── A git repo so REPO_ROOT (git rev-parse) resolves; docs/gaps + locks ─────
# The backstop imports scripts/dispatch/detect_already_satisfied.py relative to
# REPO_ROOT, so mirror it into the fake repo at the same path it lives in prod.
GIT_REPO="$TMP/repo"
mkdir -p "$GIT_REPO/docs/gaps" "$GIT_REPO/.chump-locks" "$GIT_REPO/.chump" \
         "$GIT_REPO/scripts/dispatch"
cp "$REPO_ROOT/scripts/dispatch/detect_already_satisfied.py" \
   "$GIT_REPO/scripts/dispatch/detect_already_satisfied.py"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email t@t
git -C "$GIT_REPO" config user.name t
AMB="$GIT_REPO/.chump-locks/ambient.jsonl"
STATE_DB="$GIT_REPO/.chump/state.db"

# ── Seed state.db (direct sqlite — the ground-truth store) ──────────────────
seed_db() {
    rm -f "$STATE_DB"
    sqlite3 "$STATE_DB" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY, title TEXT DEFAULT '', status TEXT DEFAULT 'open',
    closed_pr INTEGER, closed_date TEXT DEFAULT '', evidence TEXT DEFAULT ''
);
-- COVERED: no closed_pr, cycle log will show merged PR #9999 → should CLOSE.
INSERT INTO gaps (id,status) VALUES ('COVERED-1','open');
-- UNMERGED: cycle log names PR #9998 which is NOT merged → should FLAG only.
INSERT INTO gaps (id,status) VALUES ('UNMERGED-1','open');
-- NOLOG: no cycle log at all → untouched.
INSERT INTO gaps (id,status) VALUES ('NOLOG-1','open');
-- NOSIGNAL: has a cycle log but no already-satisfied signal → untouched.
INSERT INTO gaps (id,status) VALUES ('NOSIGNAL-1','open');
-- HASPR: already has closed_pr → out of scope for this mode (untouched here).
INSERT INTO gaps (id,status,closed_pr) VALUES ('HASPR-1','open',1234);
SQL
}

# ── Fake worker cycle logs (streaming claude JSONL, last assistant text) ────
LOGDIR="$TMP/chump-fleet-testsid"
mkdir -p "$LOGDIR"
mk_log() {  # <gap_id> <final assistant text>
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' \
        "$2" > "$LOGDIR/agent-7-cycle3-$1.log"
}
mk_log COVERED-1  "This gap was already implemented in PR #9999. Worktree is clean, nothing to ship."
mk_log UNMERGED-1 "Already shipped in PR #9998; no diff remaining, nothing to commit."
mk_log NOSIGNAL-1 "Made progress on the parser but ran out of time; will continue next cycle."

run() {  # extra flags
    (cd "$GIT_REPO" && PATH="$TMP/fakebin:$PATH" CHUMP_STATE_DB="$STATE_DB" \
        FLEET_LOG_DIR="$LOGDIR" python3 "$SCRIPT" --check-already-satisfied $1)
    return $?
}
status_of() { sqlite3 "$STATE_DB" "SELECT status FROM gaps WHERE id='$1';"; }
closedpr_of() { sqlite3 "$STATE_DB" "SELECT COALESCE(closed_pr,'') FROM gaps WHERE id='$1';"; }

# ── Test 1: dry-run mutates nothing ─────────────────────────────────────────
seed_db; rm -f "$AMB"
set +e; out="$(run --dry-run 2>&1)"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "dry-run rc=$rc (want 0): $out"
[[ "$(status_of COVERED-1)" == "open" ]] || fail "dry-run changed COVERED-1 status"
[[ ! -s "$AMB" ]] || fail "dry-run wrote ambient: $(cat "$AMB")"
grep -q "COVERED-1" <<<"$out" || fail "dry-run didn't mention COVERED-1: $out"
ok "dry-run reports but writes nothing"

# ── Test 2: apply — RETIRED auto-close; the covered gap is FLAGGED, not closed ─
seed_db; rm -f "$AMB"
set +e; out="$(run "" 2>&1)"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "apply rc=$rc (want 0 — self-healing stays green): $out"
# CREDIBLE-1551: COVERED-1's covering PR #9999 is not gap_prs-linked to it, so
# the FK-gate would refuse the close — the pass FLAGS it and LEAVES IT OPEN.
[[ "$(status_of COVERED-1)" == "open" ]] \
    || fail "COVERED-1 must stay OPEN (auto-close retired), got '$(status_of COVERED-1)': $out"
[[ -z "$(closedpr_of COVERED-1)" ]] \
    || fail "COVERED-1 must NOT get a closed_pr (got '$(closedpr_of COVERED-1)')"
[[ "$(status_of UNMERGED-1)" == "open" ]] \
    || fail "UNMERGED-1 should stay open (PR not merged), got '$(status_of UNMERGED-1)'"
[[ "$(status_of NOLOG-1)" == "open" ]] || fail "NOLOG-1 should be untouched"
[[ "$(status_of NOSIGNAL-1)" == "open" ]] || fail "NOSIGNAL-1 should be untouched"
[[ "$(status_of HASPR-1)" == "open" ]] || fail "HASPR-1 (has closed_pr) out of scope, untouched"
ok "apply closes NOTHING (auto-close retired); covered + unmerged gaps left open"

# ── Test 3: both gaps FLAGGED (no close event at all) ────────────────────────
# The HIGH-confidence covered gap is flagged with the RETIREMENT reason; the
# unmerged gap keeps its pr_not_merged reason. A gap_already_satisfied_closed
# event must NEVER appear now — that pins the retirement (kills a relapse that
# re-enables the --closed-pr auto-close).
grep -q '"kind":"gap_already_satisfied_closed"' "$AMB" \
    && fail "gap_already_satisfied_closed emitted — auto-close relapse: $(cat "$AMB")"
grep -q '"kind":"gap_already_satisfied_flagged"' "$AMB" || fail "no flagged event: $(cat "$AMB")"
# COVERED-1's event line carries BOTH its gap_id and the retirement reason.
# (Read the line into a var first — a `grep | grep -q` tail would SIGPIPE the
# producer under `set -o pipefail` and false-fail.)
cov_line="$(grep '"gap_id":"COVERED-1"' "$AMB" || true)"
grep -q '"reason":"fk_close_not_applicable"' <<<"$cov_line" \
    || fail "COVERED-1 not flagged with reason=fk_close_not_applicable: $(cat "$AMB")"
grep -q '"gap_id":"UNMERGED-1"' "$AMB" || fail "flagged event missing UNMERGED-1 gap_id"
grep -q '"reason":"pr_not_merged"' "$AMB" || fail "UNMERGED-1 flag missing reason=pr_not_merged"
ok "both gaps flagged (COVERED-1 fk_close_not_applicable, UNMERGED-1 pr_not_merged); no close event"

# ── Test 4: idempotent — a second apply closes nothing, still exit 0 ─────────
rm -f "$AMB"
set +e; out="$(run "" 2>&1)"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "second apply rc=$rc (want 0)"
grep -q "closed 0 already_satisfied" <<<"$out" || fail "second apply should close 0: $out"
ok "idempotent: re-run closes nothing (auto-close retired — always 0 closed)"

# ── Test 5: both new kinds registered in EVENT_REGISTRY.yaml ─────────────────
for k in gap_already_satisfied_closed gap_already_satisfied_flagged; do
    grep -q "kind: $k" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
        || fail "$k not registered in EVENT_REGISTRY.yaml"
done
ok "EVENT_REGISTRY.yaml registers both already-satisfied event kinds"

echo
echo "All INFRA-3826 already-satisfied backstop tests passed."
