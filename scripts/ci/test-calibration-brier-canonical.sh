#!/usr/bin/env bash
# scripts/ci/test-calibration-brier-canonical.sh — INFRA-3845 (parent INFRA-3841)
#
# Proves the "reconcile 3/9" claim: scripts/coord/pr-book.sh (--settle) is the
# SINGLE writer of calibration_brier — it computes Brier once over the ledger
# and appends a trailing {kind:pr_book_calibration,brier:...} summary row to
# pr-book-calibration.log. scripts/ops/vital-signs.sh (sign calibration_brier)
# and scripts/ops/faculty-collector.sh (faculty know_score) both READ that
# value BY REFERENCE (tail -n1) instead of recomputing it — so all three must
# report the IDENTICAL number when pointed at the same calibration log.
#
# Self-contained + offline: pr-book.sh --settle runs against a fixture ledger
# + fixture outcomes (no gh call), producing a real calibration log; the two
# readers are then pointed at that same log via CHUMP_PR_BOOK_CALIB.
#
# Regression coverage: before INFRA-3845, vital-signs.sh recomputed Brier from
# the log's raw {predicted,outcome} rows independently of pr-book's own
# computation — two computations of one number is exactly the drift this test
# would have caught (it fails if either reader stops reading pr-book's summary
# row verbatim).

set -uo pipefail   # NOT -e: we assert exit codes / values explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PRBOOK="$REPO_ROOT/scripts/coord/pr-book.sh"
VITAL="$REPO_ROOT/scripts/ops/vital-signs.sh"
FACULTY="$REPO_ROOT/scripts/ops/faculty-collector.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

for f in "$PRBOOK" "$VITAL" "$FACULTY"; do
  [[ -f "$f" ]] || { printf 'FATAL: %s not found\n' "$f" >&2; exit 1; }
done

DATA_ROOT="$TMP/data"
mkdir -p "$DATA_ROOT/.chump" "$DATA_ROOT/.chump-locks" "$DATA_ROOT/scripts/ops"
# vital-signs.sh self-heals REPO_ROOT to a real checkout when this manifest is
# missing — plant a stub so it trusts our fixture DATA_ROOT.
: > "$DATA_ROOT/scripts/ops/organ-manifest.txt"

# ── 1. pr-book.sh --settle is the single writer: known ledger + outcomes ─────
# pr1 price .9 (MERGED->1) err .01 ; pr2 price .2 (CLOSED->0) err .04
# Brier = (.01+.04)/2 = 0.025
LEDGER="$TMP/led.jsonl"
CALIB="$DATA_ROOT/.chump/pr-book-calibration.log"
cat > "$LEDGER" <<'J'
{"ts":"t","pr":1,"sha":"x","price":0.9,"state":"CLEAN"}
{"ts":"t","pr":2,"sha":"y","price":0.2,"state":"DIRTY"}
J
cat > "$TMP/outcomes.json" <<'J'
[{"number":1,"state":"MERGED"},{"number":2,"state":"CLOSED"}]
J
echo "[test-calibration-brier-canonical] pr-book.sh --settle (writer)"
settle_out="$(PR_BOOK_LEDGER="$LEDGER" PR_BOOK_CALIB="$CALIB" \
  PR_BOOK_OUTCOMES_FIXTURE="$TMP/outcomes.json" bash "$PRBOOK" --settle 2>&1)"
echo "$settle_out" | grep -qE 'running Brier: 0\.025($| )' \
  && _ok "pr-book.sh --settle computed Brier=0.025" \
  || { echo "$settle_out"; _fail "pr-book.sh --settle did not compute Brier=0.025"; }
EXPECT="0.025"

# ── 2. vital-signs.sh reads it BY REFERENCE, not recomputed ──────────────────
echo "[test-calibration-brier-canonical] vital-signs.sh (reader)"
vital_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_VITALS_OUT="$TMP/vitals-out.json" \
  CHUMP_AMBIENT_LOG="$DATA_ROOT/.chump-locks/ambient.jsonl" \
  CHUMP_PR_BOOK_CALIB="$CALIB" \
  timeout 90 bash "$VITAL" --dry-run 2>/dev/null)"
vital_val="$(printf '%s' "$vital_json" | jq -r '.signs[] | select(.key=="calibration_brier") | .value')"
# compare numerically (readers may format the same value with different
# trailing-zero precision — 0.025 vs 0.0250 — that is NOT a disagreement)
vital_eq="$(awk -v a="$vital_val" -v b="$EXPECT" 'BEGIN{print (a+0==b+0)?1:0}')"
[[ "$vital_eq" == "1" ]] \
  && _ok "vital-signs calibration_brier.value == $EXPECT (got $vital_val)" \
  || _fail "vital-signs calibration_brier.value expected $EXPECT, got '$vital_val'"

# ── 3. faculty-collector.sh reads the SAME log (already by-reference) ────────
echo "[test-calibration-brier-canonical] faculty-collector.sh (reader)"
faculty_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_FACULTY_OUT="$TMP/faculty-out.json" \
  CHUMP_AMBIENT_LOG="$DATA_ROOT/.chump-locks/ambient.jsonl" \
  CHUMP_PR_BOOK_CALIB="$CALIB" \
  CHUMP_ALMANAC_REPO="$TMP/no-almanac" \
  CHUMP_ALMANAC_BIN="$TMP/no-almanac/target/release/almanac" \
  timeout 90 bash "$FACULTY" --dry-run 2>/dev/null)"
faculty_val="$(printf '%s' "$faculty_json" | jq -r '.faculties[] | select(.key=="know_score") | .value')"
faculty_eq="$(awk -v a="$faculty_val" -v b="$EXPECT" 'BEGIN{print (a+0==b+0)?1:0}')"
[[ "$faculty_eq" == "1" ]] \
  && _ok "faculty-collector know_score.value == $EXPECT (got $faculty_val)" \
  || _fail "faculty-collector know_score.value expected $EXPECT, got '$faculty_val'"

# ── 3b. pr-book.sh board mode (cockpit's pr_book_odds reader) cites the SAME
#       canonical column too — this is the third surface (web/cockpit-live's
#       "manage-PRs casino ... Brier" panel reads p.brier off pr_book_odds).
echo "[test-calibration-brier-canonical] pr-book.sh board mode (cockpit reader)"
BOARD_FIXTURE="$TMP/board.json"
cat > "$BOARD_FIXTURE" <<'J'
[]
J
BOARD_AMBIENT="$TMP/board-ambient.jsonl"
PR_BOOK_RAW_FIXTURE="$BOARD_FIXTURE" PR_BOOK_LEDGER="$TMP/board-ledger.jsonl" \
  PR_BOOK_CALIB="$CALIB" CHUMP_AMBIENT_LOG="$BOARD_AMBIENT" \
  bash "$PRBOOK" >/dev/null 2>&1
odds_brier="$(tail -n1 "$BOARD_AMBIENT" 2>/dev/null | jq -r 'select(.kind=="pr_book_odds") | .brier // empty')"
odds_eq="$(awk -v a="$odds_brier" -v b="$EXPECT" 'BEGIN{print (a+0==b+0)?1:0}')"
[[ "$odds_eq" == "1" ]] \
  && _ok "pr_book_odds.brier == $EXPECT (got $odds_brier)" \
  || _fail "pr_book_odds.brier expected $EXPECT, got '$odds_brier'"

# ── 4. all three agree with each other, not just with EXPECT ────────────────
agree="$(awk -v a="$vital_val" -v b="$faculty_val" -v c="$odds_brier" 'BEGIN{print (a+0==b+0 && b+0==c+0)?1:0}')"
[[ "$agree" == "1" ]] \
  && _ok "vital-signs, faculty-collector, and pr_book_odds all agree ($vital_val == $faculty_val == $odds_brier)" \
  || _fail "vital-signs ($vital_val), faculty-collector ($faculty_val), pr_book_odds ($odds_brier) DISAGREE"

# ── 5. divergence probe: authoritative summary != naive per-row recompute ────
# A hand-built log where the naive mean-squared-error over the per-row
# {predicted,outcome} pairs is 0.025, but the trailing pr_book_calibration
# summary row (the value pr-book.sh actually settled on and the ONLY value a
# by-reference reader may report) says 0.5 — standing in for pr-book's settle
# logic diverging from a naive recompute (e.g. a future weighting/filter
# change). A reader that recomputes from the rows will report 0.025 here and
# FAIL this check; a reader that cites the summary row verbatim reports 0.5.
DIVERGE_CALIB="$TMP/diverge-cal.log"
cat > "$DIVERGE_CALIB" <<'J'
{"ts":"t","kind":"pr_book_prediction","pr":1,"predicted":0.9,"outcome":1}
{"ts":"t","kind":"pr_book_prediction","pr":2,"predicted":0.2,"outcome":0}
{"ts":"t","kind":"pr_book_calibration","brier":0.5,"n":2,"merged":1,"closed":1}
J
echo "[test-calibration-brier-canonical] divergence probe (authoritative summary wins)"
diverge_vital_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_VITALS_OUT="$TMP/vitals-diverge.json" \
  CHUMP_AMBIENT_LOG="$DATA_ROOT/.chump-locks/ambient.jsonl" \
  CHUMP_PR_BOOK_CALIB="$DIVERGE_CALIB" \
  timeout 90 bash "$VITAL" --dry-run 2>/dev/null)"
diverge_vital_val="$(printf '%s' "$diverge_vital_json" | jq -r '.signs[] | select(.key=="calibration_brier") | .value')"
diverge_eq="$(awk -v a="$diverge_vital_val" 'BEGIN{print (a+0==0.5)?1:0}')"
[[ "$diverge_eq" == "1" ]] \
  && _ok "vital-signs cites the authoritative summary row (0.5), not a naive recompute (got $diverge_vital_val)" \
  || _fail "vital-signs did NOT cite the authoritative summary row — recompute drift detected (expected 0.5, got '$diverge_vital_val')"

echo
echo "[test-calibration-brier-canonical] $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
