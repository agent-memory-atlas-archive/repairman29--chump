#!/usr/bin/env bash
# CREDIBLE-092 / CREDIBLE-268 regression guard.
#
# The webhook receiver (runs LOCALLY, has .chump/state.db access) must flip a
# merged PR's referenced gaps to status=done. This fixes the root cause that
# .github/workflows/auto-flip-on-merge.yml could not: CI has no canonical
# state.db, so merged gaps stayed 'open' and got re-claimed (ghost-gap waste).
#
# CREDIBLE-268 hardened this: the original title+body scan flipped every gap
# a PR merely CITED (30 flips / 8 PRs / ~22 collateral on 2026-08-09).
# Asserts: (a) the flip fn exists + is wired + routes through `gap ship` (not
# `gap set`, so PROOF-OF-MERGE + closed_date apply); (b) extraction is
# title-or-Closes-trailer only — a gap merely cited in body prose must NOT
# flip; (c) auto-flip stays suppressed by default (CHUMP_WEBHOOK_AUTOFLIP
# unset); (d) a closed-UNMERGED PR does NOT flip (no regression).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/
RECV="$ROOT/ops/github-webhook-receiver.py"
[[ -f "$RECV" ]] || { echo "FAIL: receiver not found at $RECV"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# (a) static wiring
grep -q 'def _auto_flip_gaps_done' "$RECV" && ok "flip fn defined" || fail "no _auto_flip_gaps_done"
grep -q 'def _extract_gap_ids_for_closure' "$RECV" \
  && ok "closure extraction fn defined" || fail "no _extract_gap_ids_for_closure"
grep -q '"ship", gid' "$RECV" && grep -q '"--closed-pr",' "$RECV" \
  && ok "flip calls chump gap ship --closed-pr (not gap set)" \
  || fail "flip does not route through chump gap ship"
grep -q '"set", gid' "$RECV" \
  && fail "flip still calls chump gap set (bypasses PROOF-OF-MERGE + closed_date)" \
  || ok "flip does not call chump gap set"
grep -q '_auto_flip_gaps_done(pr, payload)' "$RECV" && ok "wired into merged-PR handler" || fail "not wired into handler"

# (b)-(d) behavioral: stub chump, importlib-load receiver, exercise both paths
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/chump" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CHUMP_STUB_CALLS"
exit 0
STUB
chmod +x "$tmp/chump"
export CHUMP_STUB_CALLS="$tmp/calls"
: > "$CHUMP_STUB_CALLS"

# (c) default (CHUMP_WEBHOOK_AUTOFLIP unset) — must stay suppressed, no chump call
python3 - "$RECV" "$tmp/chump" <<'PY'
import sys, os, importlib.util
recv_path, chump_bin = sys.argv[1], sys.argv[2]
os.environ["CHUMP_BIN"] = chump_bin
os.environ.pop("CHUMP_WEBHOOK_AUTOFLIP", None)
spec = importlib.util.spec_from_file_location("ghwr_test_suppressed", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
pr = {"number": 9999, "merged": True,
      "title": "fix(MISSION-9001): something",
      "body": "Gap: MISSION-9001",
      "head": {"ref": "chump/mission-9001-claim"}}
print("suppressed_flip_count=%d" % mod._auto_flip_gaps_done(pr, {"action": "closed", "pull_request": pr}))
PY
[[ -s "$CHUMP_STUB_CALLS" ]] \
  && fail "auto-flip fired with CHUMP_WEBHOOK_AUTOFLIP unset (should stay suppressed by default)" \
  || ok "auto-flip suppressed by default (CHUMP_WEBHOOK_AUTOFLIP unset)"

# (b)/(d) with CHUMP_WEBHOOK_AUTOFLIP=1: title-id flips, body-citation-only does NOT, unmerged does NOT
: > "$CHUMP_STUB_CALLS"
python3 - "$RECV" "$tmp/chump" <<'PY'
import sys, os, importlib.util
recv_path, chump_bin = sys.argv[1], sys.argv[2]
os.environ["CHUMP_BIN"] = chump_bin
os.environ["CHUMP_WEBHOOK_AUTOFLIP"] = "1"
spec = importlib.util.spec_from_file_location("ghwr_test_enabled", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# merged PR naming the gap in its TITLE -> flips
pr = {"number": 9999, "merged": True,
      "title": "fix(MISSION-9001): something",
      "body": "Gap: MISSION-9001",
      "head": {"ref": "chump/mission-9001-claim"}}
print("title_flip_count=%d" % mod._auto_flip_gaps_done(pr, {"action": "closed", "pull_request": pr}))

# merged PR that only CITES a gap in body prose (no Closes: trailer) -> must NOT flip
pr_cite = {"number": 9997, "merged": True,
           "title": "docs: analysis of factory yield",
           "body": "This explains why MISSION-9003 keeps destroying PRs.",
           "head": {"ref": "chump/factory-yield-claim"}}
print("cite_only_flip_count=%d" % mod._auto_flip_gaps_done(pr_cite, {"action": "closed", "pull_request": pr_cite}))

# merged PR with an explicit Closes: trailer -> flips
pr_closes = {"number": 9996, "merged": True,
             "title": "fix: unrelated title",
             "body": "Some prose mentioning MISSION-9005 in passing.\n\nCloses: MISSION-9004",
             "head": {"ref": "chump/some-slug-claim"}}
print("closes_trailer_flip_count=%d" % mod._auto_flip_gaps_done(pr_closes, {"action": "closed", "pull_request": pr_closes}))

# closed-UNMERGED PR — must NOT flip
pr2 = {"number": 9998, "merged": False,
       "title": "fix(MISSION-9002): x", "body": "Gap: MISSION-9002",
       "head": {"ref": "chump/mission-9002-claim"}}
print("unmerged_flip_count=%d" % mod._auto_flip_gaps_done(pr2, {"action": "closed", "pull_request": pr2}))
PY

grep -q 'gap ship MISSION-9001 --closed-pr 9999' "$CHUMP_STUB_CALLS" \
  && ok "merged PR naming gap in TITLE flipped MISSION-9001 -> done via gap ship (closed-pr 9999)" \
  || fail "title-named flip call wrong/missing. calls: [$(tr '\n' '|' <"$CHUMP_STUB_CALLS")]"
grep -q 'MISSION-9003' "$CHUMP_STUB_CALLS" \
  && fail "PR that only CITED MISSION-9003 in body prose wrongly flipped it" \
  || ok "body-citation-only mention did NOT flip (over-match fixed)"
grep -q 'gap ship MISSION-9004 --closed-pr 9996' "$CHUMP_STUB_CALLS" \
  && ok "explicit Closes: trailer flipped MISSION-9004 -> done via gap ship" \
  || fail "Closes: trailer flip call wrong/missing. calls: [$(tr '\n' '|' <"$CHUMP_STUB_CALLS")]"
grep -q 'MISSION-9005' "$CHUMP_STUB_CALLS" \
  && fail "prose mention alongside a Closes: trailer wrongly flipped MISSION-9005" \
  || ok "prose mention beside a Closes: trailer did NOT flip"
grep -q 'MISSION-9002' "$CHUMP_STUB_CALLS" \
  && fail "closed-UNMERGED PR wrongly flipped MISSION-9002" \
  || ok "closed-unmerged PR did NOT flip (no regression)"

# (e) CREDIBLE-1072: _extract_gap_ids (used by lease-release) is title-only —
# a gap ID that appears ONLY in the body (even behind a Closes: trailer) must
# NOT be extracted; a gap ID in the title still is.
extract_out="$(python3 - "$RECV" <<'PY'
import sys, importlib.util
recv_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("ghwr_test_extract", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

pr_body_only = {"title": "docs: unrelated title", "body": "See CREDIBLE-9999 for context."}
print("body_only=%r" % mod._extract_gap_ids(pr_body_only))

pr_body_closes = {"title": "docs: unrelated title", "body": "Closes: CREDIBLE-9999"}
print("body_closes=%r" % mod._extract_gap_ids(pr_body_closes))

pr_title = {"title": "fix(CREDIBLE-1234): something", "body": "no gap ids here"}
print("title=%r" % mod._extract_gap_ids(pr_title))
PY
)"
echo "$extract_out" | grep -q "body_only=\[\]" \
  && ok "_extract_gap_ids: body-only mention extracts nothing" \
  || fail "_extract_gap_ids: body-only mention wrongly extracted an id ($extract_out)"
echo "$extract_out" | grep -q "body_closes=\[\]" \
  && ok "_extract_gap_ids: body-only Closes: trailer extracts nothing (title-only discipline)" \
  || fail "_extract_gap_ids: body Closes: trailer wrongly extracted an id ($extract_out)"
echo "$extract_out" | grep -q "title=\['CREDIBLE-1234'\]" \
  && ok "_extract_gap_ids: title-named gap id still extracted" \
  || fail "_extract_gap_ids: title-named gap id extraction broken ($extract_out)"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-webhook-gap-flip.sh (title/Closes: only extraction; routes through gap ship; suppressed by default)"
  exit 0
else
  echo "FAIL: test-webhook-gap-flip.sh ($fails assertion(s) failed)"
  exit 1
fi
