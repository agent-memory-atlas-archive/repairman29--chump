#!/usr/bin/env bash
# scripts/ci/test-credible-1258-extract-gap-ids.sh — CREDIBLE-1258
#
# Validates the current gap-ID extraction mechanism used by
# scripts/ops/github-webhook-receiver.py:_extract_gap_ids (sibling-lease-
# release path, NOT the narrower closure path already covered by
# scripts/ci/test-webhook-gap-flip.sh).
#
# CREDIBLE-1072 restricted _extract_gap_ids to the PR TITLE only — the body
# (including any `Closes:` trailer written there) is no longer scanned.
# This suite's expectations were updated accordingly; see
# scripts/ci/test-webhook-gap-flip.sh section (e) for the dedicated
# CREDIBLE-1072 regression coverage.
#
# AC1: unit test confirms _extract_gap_ids extracts IDs from the PR title
#      only, using \b([A-Z][A-Z-]+-\d+)\b, and ignores the body entirely.
# AC2: integration test runs the receiver on a sample merged PR and
#      verifies the extracted IDs match the expected list.
# AC3: this suite must pass in CI without failures.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RECEIVER="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

[[ -f "$RECEIVER" ]] || { echo "FAIL: receiver not found at $RECEIVER"; exit 1; }

echo "=== CREDIBLE-1258 gap-ID extraction validation ==="
echo

# ── AC1: unit test — _extract_gap_ids, title + body(Closes:) ───────────────
out="$(python3 - "$RECEIVER" <<'PY'
import sys, importlib.util

recv_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("ghwr_credible_1258", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

cases = [
    (
        {"title": "fix(INFRA-1444): test", "body": ""},
        ["INFRA-1444"],
    ),
    (
        {"title": "no gap id here", "body": "Closes: CREDIBLE-268"},
        [],
    ),
    (
        {"title": "feat(MISSION-9001): x",
         "body": "Some unrelated prose about MISSION-9003.\n\nCloses: MISSION-9004, MISSION-9005"},
        ["MISSION-9001"],
    ),
    (
        {"title": "mixed CREDIBLE-001 and PRODUCT-049 and INFRA-1500", "body": None},
        ["CREDIBLE-001", "PRODUCT-049", "INFRA-1500"],
    ),
    (
        {"title": "dup INFRA-1444 twice INFRA-1444", "body": "Closes: INFRA-1444"},
        ["INFRA-1444"],
    ),
]

fails = 0
for pr, expected in cases:
    got = mod._extract_gap_ids(pr)
    if got != expected:
        print(f"  FAIL: pr={pr!r} expected={expected} got={got}")
        fails += 1
print(f"CASES_RUN={len(cases)} FAILS={fails}")
sys.exit(1 if fails else 0)
PY
)"
echo "$out"
if [[ "$out" == *"FAILS=0"* ]]; then
    ok "_extract_gap_ids extracts from title only via \\b([A-Z][A-Z-]+-\\d+)\\b (body ignored)"
else
    fail "_extract_gap_ids unit cases failed"
fi

# ── AC2: integration test — run receiver's extraction on a sample merged PR ─
out2="$(python3 - "$RECEIVER" <<'PY'
import sys, importlib.util

recv_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("ghwr_credible_1258_integ", recv_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# A representative merged PR payload shape, as delivered by the GitHub
# pull_request webhook (trimmed to the fields _extract_gap_ids reads).
sample_merged_pr = {
    "number": 4700,
    "merged": True,
    "title": "feat(CREDIBLE-1258): validate gap ID extraction mechanism",
    "body": (
        "Adds unit + integration coverage for _extract_gap_ids.\n\n"
        "See also CREDIBLE-268 for the narrower closure-path extractor "
        "(cited in prose, not a Closes: trailer, so it must NOT be extracted).\n\n"
        "Closes: CREDIBLE-1258"
    ),
    "head": {"ref": "chump/credible-1258-claim"},
}

# CREDIBLE-268 is only cited in body prose, and the body's `Closes:
# CREDIBLE-1258` trailer is title-only-discipline-ignored too (CREDIBLE-1072)
# — CREDIBLE-1258 is only extracted because it also appears in the title.
expected = ["CREDIBLE-1258"]
got = mod._extract_gap_ids(sample_merged_pr)
if got != expected:
    print(f"FAIL: expected={expected} got={got}")
    sys.exit(1)
print(f"OK: extracted={got}")
sys.exit(0)
PY
)"
echo "$out2"
if [[ "$out2" == OK:* ]]; then
    ok "receiver run on sample merged PR extracts expected gap ID list"
else
    fail "sample merged PR extraction mismatch"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
