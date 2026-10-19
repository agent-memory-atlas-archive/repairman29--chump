#!/usr/bin/env bash
# CREDIBLE-1550/1552 (Phase R R2) — gap-doctor-reconcile.py --check-merged-pr-links
# closes a gap ONLY via the typed gap_prs FK + GitHub's merged state, never a PR
# title and never a PARTIAL-body regex (CREDIBLE-1552 deleted that heuristic).
#
# Fixtures (throwaway state.db; fake gh + chump on PATH, no network):
#   CREDIBLE-9000  umbrella, OPEN, NO gap_prs row (merged PR #100 titles it)
#   CREDIBLE-9001  slice,    OPEN, gap_prs → merged PR #100 (title names the UMBRELLA)
#   CREDIBLE-9002  docs gap, OPEN, NO gap_prs row (merged docs PR #300 titles it)
#   CREDIBLE-9003  slice,    OPEN, gap_prs → merged PR #200 whose body is "AC1 only"
#   CREDIBLE-9004  slice,    OPEN, gap_prs → PR #400 whose merged-flag fetch ERRORS
#   CREDIBLE-9005  slice,    OPEN, gap_prs → newest PR #500 OPEN + older PR #501 MERGED
#
# Asserts the CREDIBLE-1552 behaviour:
#   - no title close happens: the umbrella CREDIBLE-9000 (title-named by #100 but
#     unlinked) and the docs gap CREDIBLE-9002 (no row) both stay open.
#   - a linked merged PR closes its gap: CREDIBLE-9001 closes via its FK to #100.
#   - an unlinked merged PR emits pr_without_gap_link and closes nothing: the
#     report-only pass flags #100→9000 and #300→9002.
#   - a failed merged-flag fetch closes nothing: CREDIBLE-9004 stays open and
#     emits gap_close_skipped_merge_fetch_error (fail closed).
#   - the PARTIAL body heuristic is GONE: CREDIBLE-9003 (body "AC1 only") now
#     CLOSES, no gh `pr view --json body` call is ever made, and the source
#     carries no body regex. No gap_close_skipped_partial_pr event is emitted.
#   - a link whose PR is open while an older link is merged: CREDIBLE-9005 closes
#     via the older merged #501 (skips the open newest #500).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor-reconcile.py"
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# git-init the fixture so the reconciler's REPO_ROOT (git toplevel, resolved at
# import) is $TMP — keeps its ambient.jsonl + cache lookups inside the fixture.
git init --quiet "$TMP" 2>/dev/null || { echo "SKIP: git init failed"; exit 0; }

STATE_DB="$TMP/state.db"
sqlite3 "$STATE_DB" <<'SQL'
CREATE TABLE gaps (id TEXT PRIMARY KEY, status TEXT, title TEXT);
INSERT INTO gaps VALUES ('CREDIBLE-9000','open','umbrella');
INSERT INTO gaps VALUES ('CREDIBLE-9001','open','slice one');
INSERT INTO gaps VALUES ('CREDIBLE-9002','open','docs gap');
INSERT INTO gaps VALUES ('CREDIBLE-9003','open','slice three');
INSERT INTO gaps VALUES ('CREDIBLE-9004','open','slice four');
INSERT INTO gaps VALUES ('CREDIBLE-9005','open','slice five');
CREATE TABLE gap_prs (gap_id TEXT, pr_number INTEGER, head_sha TEXT,
                      opened_at INTEGER, state TEXT,
                      PRIMARY KEY (gap_id, pr_number));
INSERT INTO gap_prs VALUES ('CREDIBLE-9001',100,'deadbeef',100,'open');
INSERT INTO gap_prs VALUES ('CREDIBLE-9003',200,'cafef00d',200,'open');
INSERT INTO gap_prs VALUES ('CREDIBLE-9004',400,'badf00d0',400,'open');
-- 9005: newest link #500 is OPEN, older #501 is MERGED (opened_at DESC => 500 first)
INSERT INTO gap_prs VALUES ('CREDIBLE-9005',500,'0pen5000',501,'open');
INSERT INTO gap_prs VALUES ('CREDIBLE-9005',501,'merged501',500,'open');
SQL

# ── fake gh ───────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
# repo view → test/repo
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then echo "test/repo"; exit 0; fi
# api repos/.../pulls/<N> → "<state> <merged_at>"
if [[ "\$1" == "api" ]]; then
  case "\$*" in
    *"/pulls/100"*) echo "closed 2026-10-18T00:00:00Z"; exit 0 ;;
    *"/pulls/200"*) echo "closed 2026-10-18T00:30:00Z"; exit 0 ;;
    *"/pulls/400"*) echo "boom" >&2; exit 1 ;;   # fetch ERROR → fail closed
    *"/pulls/500"*) echo "open -"; exit 0 ;;      # newest link not merged
    *"/pulls/501"*) echo "closed 2026-10-18T01:00:00Z"; exit 0 ;;
    *) echo "closed -"; exit 0 ;;
  esac
fi
# pr list --state merged → recently merged PRs for the report-only pass
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  cat <<'JSON'
[
  {"number":100,"title":"CREDIBLE-9000 umbrella shipped"},
  {"number":300,"title":"CREDIBLE-9002 docs addendum"}
]
JSON
  exit 0
fi
# pr view --json body → MUST NEVER be called (partial-body heuristic deleted)
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  echo "\$*" >> "$TMP/body-calls.txt"
  echo ""
  exit 0
fi
echo ""; exit 0
EOF
chmod +x "$TMP/bin/gh"

# ── fake chump: record `gap ship` calls (gap id + closed-pr) ───────────────────
cat >"$TMP/bin/chump" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "gap" && "\$2" == "ship" ]]; then
  echo "\$3 \$5" >> "$TMP/shipped.txt"
fi
exit 0
EOF
chmod +x "$TMP/bin/chump"

export PATH="$TMP/bin:$PATH"
export CHUMP_STATE_DB="$STATE_DB"
export CHUMP_REPO_ROOT="$TMP"
mkdir -p "$TMP/.chump-locks"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"

( cd "$TMP" && python3 "$SCRIPT" --check-merged-pr-links ) >/dev/null 2>&1 || true

SHIPPED="$(cat "$TMP/shipped.txt" 2>/dev/null || true)"
shipped_gap() { grep -qE "^$1( |\$)" <<<"$SHIPPED"; }

# a linked merged PR closes its gap.
if shipped_gap 'CREDIBLE-9001'; then
  pass "FK-linked slice CREDIBLE-9001 closed (merged PR #100)"
else
  fail "FK-linked slice CREDIBLE-9001 was NOT closed (shipped='$SHIPPED')"
fi

# no title close: umbrella named by #100's title but unlinked stays open.
if shipped_gap 'CREDIBLE-9000'; then
  fail "umbrella CREDIBLE-9000 closed by title — must require a gap_prs row"
else
  pass "no title close: umbrella CREDIBLE-9000 stays open (no gap_prs row)"
fi

# no title close: docs gap with no row stays open.
if shipped_gap 'CREDIBLE-9002'; then
  fail "docs gap CREDIBLE-9002 closed without a gap_prs row"
else
  pass "no title close: docs gap CREDIBLE-9002 stays open (no gap_prs row)"
fi

# PARTIAL body heuristic gone: the "AC1 only" body PR now CLOSES its gap.
if shipped_gap 'CREDIBLE-9003'; then
  pass "PARTIAL heuristic gone: CREDIBLE-9003 (AC1-only body) now closes via its FK"
else
  fail "CREDIBLE-9003 did not close — the deleted PARTIAL-body regex must not block it"
fi
# …and the body was never fetched.
if [[ -s "$TMP/body-calls.txt" ]]; then
  fail "gh pr view --json body was called ($(cat "$TMP/body-calls.txt")) — no body may be consulted"
else
  pass "no PR body consulted (gh pr view --json body never called)"
fi
# …and no partial-skip event was emitted.
if grep -q '"kind":"gap_close_skipped_partial_pr"' "$AMBIENT" 2>/dev/null; then
  fail "gap_close_skipped_partial_pr emitted — the partial path must be gone"
else
  pass "no gap_close_skipped_partial_pr event emitted"
fi

# failed merged-flag fetch closes nothing + emits the fail-closed event.
if shipped_gap 'CREDIBLE-9004'; then
  fail "CREDIBLE-9004 closed despite a merged-flag fetch error — must fail closed"
else
  pass "fail closed: CREDIBLE-9004 stays open when the merge fetch errors"
fi
if grep -q '"kind":"gap_close_skipped_merge_fetch_error"' "$AMBIENT" 2>/dev/null \
   && grep -q 'CREDIBLE-9004' "$AMBIENT" 2>/dev/null; then
  pass "gap_close_skipped_merge_fetch_error emitted for CREDIBLE-9004"
else
  fail "no gap_close_skipped_merge_fetch_error event for CREDIBLE-9004"
fi

# open-newest + merged-older link: closes via the older merged #501.
if grep -qE '^CREDIBLE-9005 501$' <<<"$SHIPPED"; then
  pass "CREDIBLE-9005 closes via the older MERGED link #501 (newest #500 is open)"
else
  fail "CREDIBLE-9005 did not close via #501 (shipped='$SHIPPED')"
fi

# report-only pass: both unlinked merged PRs emit pr_without_gap_link, close nothing.
if grep -q '"kind":"pr_without_gap_link"' "$AMBIENT" 2>/dev/null \
   && grep -q '"gap_id":"CREDIBLE-9000"' "$AMBIENT" 2>/dev/null \
   && grep -q '"gap_id":"CREDIBLE-9002"' "$AMBIENT" 2>/dev/null; then
  pass "report-only: pr_without_gap_link emitted for CREDIBLE-9000 and CREDIBLE-9002"
else
  fail "report-only: pr_without_gap_link not emitted for both unlinked merged PRs"
fi

# Source-level guarantee: no body regex / body fetch remains in the reconciler.
if grep -qE '_PARTIAL_BODY_RE|def pr_body\(|--json.?body' "$SCRIPT"; then
  fail "gap-doctor-reconcile.py still references a PARTIAL body regex / pr_body / --json body"
else
  pass "source carries no PARTIAL body regex, no pr_body(), no --json body"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "[credible-1552-gap-prs-closer] ALL PASS"
