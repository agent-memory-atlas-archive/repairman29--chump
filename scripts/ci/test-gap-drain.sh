#!/usr/bin/env bash
# EFFECTIVE-464: test scripts/dispatch/gap-drain.sh — the DRAIN LOOP.
#
# Regression coverage for the two levers (enrich thin / decompose broad) and
# the shared attempt-cooldown ledger, none of which had a test since #4197
# shipped. Uses fake `chump` / `chump-gap-enricher` binaries on PATH so the
# real fleet DB and LLM calls are never touched.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

FAIL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BIN="$TMPDIR/bin"
mkdir -p "$BIN"

# ── fake `chump` — serves `gap list --status open --json` and
#    `gap decompose <ID> --apply` ────────────────────────────────────────────
cat >"$BIN/chump" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "gap" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"id":"EFFECTIVE-9001","priority":"P1","effort":"m","title":"broad gap needs decompose","description":"touches many files across the crate with no single anchor","acceptance_criteria":"multi-part AC across several files"},
  {"id":"EFFECTIVE-9002","priority":"P2","effort":"s","title":"thin gap needs enrichment badly","description":"","acceptance_criteria":""}
]
JSON
  exit 0
fi
if [ "$1" = "gap" ] && [ "$2" = "decompose" ]; then
  echo "filed EFFECTIVE-9010, EFFECTIVE-9011"
  exit 0
fi
echo "fake chump: unhandled args: $*" >&2
exit 1
FAKE
chmod +x "$BIN/chump"

# ── fake `chump-gap-enricher` — always applies successfully ────────────────
cat >"$BIN/chump-gap-enricher" <<'FAKE'
#!/usr/bin/env bash
gid="$1"
cat <<JSON
{"enriched":[{"id":"$gid","applied":true}]}
JSON
exit 0
FAKE
chmod +x "$BIN/chump-gap-enricher"

REPO_ROOT="$(git rev-parse --show-toplevel)"
LEDGER="$TMPDIR/ledger"
ATTEMPTED="$TMPDIR/attempted.tsv"

run_drain() {
  # CHUMP_DECOMPOSE_API_BASE is the manual-override escape hatch in
  # lib/decompose-provider.sh — pinning it skips the OpenRouter/Google/Groq
  # network health-probes entirely, keeping this test hermetic.
  PATH="$BIN:$PATH" \
  CHUMP_REPO_ROOT="$REPO_ROOT" \
  CHUMP_DRAIN_LEDGER="$LEDGER" \
  CHUMP_DRAIN_ATTEMPTED="$ATTEMPTED" \
  CHUMP_DRAIN_ENRICH_LIMIT=6 \
  CHUMP_DRAIN_DECOMPOSE_LIMIT=1 \
  CHUMP_DRAIN_ATTEMPT_COOLDOWN_S="${1:-86400}" \
  CHUMP_DECOMPOSE_API_BASE="http://127.0.0.1:1/unused" \
  CHUMP_DECOMPOSE_API_KEY="unused" \
  CHUMP_DECOMPOSE_MODEL="unused" \
  bash "$REPO_ROOT/scripts/dispatch/gap-drain.sh" 2>&1
}

echo "=== EFFECTIVE-464: gap-drain.sh test ==="

echo "--- test 1: first tick decomposes the broad gap and enriches the thin gap"
out1="$(run_drain 86400)"
if ! echo "$out1" | grep -q "decompose EFFECTIVE-9001 OK"; then
  echo "FAIL: expected broad gap EFFECTIVE-9001 to be decomposed"
  echo "$out1"
  FAIL=1
fi
if ! echo "$out1" | grep -q "enrich EFFECTIVE-9002 APPLIED"; then
  echo "FAIL: expected thin gap EFFECTIVE-9002 to be enriched"
  echo "$out1"
  FAIL=1
fi
if ! echo "$out1" | grep -q "DONE decomposed=1 enriched=1"; then
  echo "FAIL: expected tick summary decomposed=1 enriched=1"
  echo "$out1"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && echo "PASS: first tick worked both levers"

echo "--- test 2: attempted ledger records both gaps"
if ! grep -q "^EFFECTIVE-9001" "$ATTEMPTED"; then
  echo "FAIL: EFFECTIVE-9001 missing from attempted ledger"
  FAIL=1
fi
if ! grep -q "^EFFECTIVE-9002" "$ATTEMPTED"; then
  echo "FAIL: EFFECTIVE-9002 missing from attempted ledger"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && echo "PASS: attempted ledger recorded both gaps"

echo "--- test 3: cooldown skips already-attempted gaps on the very next tick"
out2="$(run_drain 86400)"
if ! echo "$out2" | grep -q "DONE decomposed=0 enriched=0"; then
  echo "FAIL: expected second tick (within cooldown) to skip both gaps, got:"
  echo "$out2"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && echo "PASS: cooldown suppressed re-attempt within the window"

echo "--- test 4: zero cooldown lets the tick re-attempt immediately"
out3="$(run_drain 0)"
if ! echo "$out3" | grep -q "DONE decomposed=1 enriched=1"; then
  echo "FAIL: expected zero-cooldown tick to re-attempt both gaps, got:"
  echo "$out3"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && echo "PASS: zero cooldown re-attempts immediately"

echo "--- test 5: run ledger accumulates a summary line per tick"
lines="$(wc -l <"$LEDGER" | tr -d ' ')"
if [ "$lines" -lt 3 ]; then
  echo "FAIL: expected >=3 run-ledger lines (one per tick), got $lines"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && echo "PASS: run ledger has one line per tick"

echo "--- test 6: effort L/M/xl (case-insensitive) selected, P0/P1 first; LLM-down refunds cooldown"
BIN2="$TMPDIR/bin2"; mkdir -p "$BIN2"
cp "$BIN/chump-gap-enricher" "$BIN2/"
cat >"$BIN2/chump" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "gap" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"id":"EFFECTIVE-9103","priority":"P2","effort":"m","title":"p2 m"},
  {"id":"EFFECTIVE-9101","priority":"P0","effort":"L","title":"p0 L"},
  {"id":"EFFECTIVE-9102","priority":"P1","effort":"xl","title":"p1 xl"},
  {"id":"EFFECTIVE-9104","priority":"P1","effort":"M","title":"p1 M"},
  {"id":"EFFECTIVE-9105","priority":"P0","effort":"XS","title":"p0 XS skipped"}
]
JSON
  exit 0
fi
if [ "$1" = "gap" ] && [ "$2" = "decompose" ]; then
  echo "Error: LLM call failed: no provider" >&2
  exit 1
fi
exit 1
FAKE
chmod +x "$BIN2/chump"
ATTEMPTED="$TMPDIR/attempted2.tsv"; rm -f "$ATTEMPTED"
out6="$(BIN="$BIN2" PATH="$BIN2:$PATH" CHUMP_REPO_ROOT="$REPO_ROOT" CHUMP_DRAIN_LEDGER="$TMPDIR/ledger2" \
  CHUMP_DRAIN_ATTEMPTED="$ATTEMPTED" CHUMP_DRAIN_ENRICH_LIMIT=0 CHUMP_DRAIN_DECOMPOSE_LIMIT=4 \
  CHUMP_DRAIN_ATTEMPT_COOLDOWN_S=86400 CHUMP_DECOMPOSE_API_BASE="http://127.0.0.1:1/unused" \
  CHUMP_DECOMPOSE_API_KEY=unused CHUMP_DECOMPOSE_MODEL=unused \
  bash "$REPO_ROOT/scripts/dispatch/gap-drain.sh" 2>&1)"
for g in 9101 9102 9103 9104; do
  echo "$out6" | grep -q "decompose EFFECTIVE-$g \.\.\." || { echo "FAIL: EFFECTIVE-$g not selected"; FAIL=1; }
done
echo "$out6" | grep -q "decompose EFFECTIVE-9105" && { echo "FAIL: XS gap selected"; FAIL=1; }
order="$(echo "$out6" | grep -oE "decompose EFFECTIVE-91[0-9]+ \.\.\." | grep -oE "91[0-9]+" | tr '\n' ' ')"
[ "$order" = "9101 9102 9104 9103 " ] || { echo "FAIL: priority order wrong: $order"; FAIL=1; }
if [ -s "$ATTEMPTED" ]; then echo "FAIL: cooldown burned on LLM-down failure"; cat "$ATTEMPTED"; FAIL=1; fi
[ "$FAIL" -eq 0 ] && echo "PASS: case-variant effort, priority order, cooldown refund"

if [ "$FAIL" -eq 0 ]; then
  echo "=== ALL PASS ==="
  exit 0
else
  echo "=== FAIL ==="
  exit 1
fi
