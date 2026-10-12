#!/usr/bin/env bash
# Regression test for INFRA-8111 — the RESILIENT-1562 merge wedge.
#
# duplicate-pr-detector.sh must dedupe a swarm whose PRs were CREATED long ago,
# even when a rescue/shepherd organ keeps their updated_at fresh (mass-reopen).
# The original bug keyed freshness on updated_at AND let a single fresh PR
# exempt the whole group, so a perpetually-touched 21-PR swarm was skipped for
# 33h ("no eligible groups"). This test locks the fix: freshness keys on
# created_at, and only individual genuinely-new PRs are spared.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

now=$(date -u +%s)
iso() { python3 -c "import datetime;print(datetime.datetime.fromtimestamp($1, datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
old=$(iso $((now-7200)))   # created 2h ago
fresh=$(iso $((now-30)))   # updated 30s ago (bot touch)
new=$(iso $((now-60)))     # created 1m ago (genuinely new)

# 3 stale swarm members (old created, bot-fresh updated) + 1 genuinely-new PR.
cat > "$TMP/pulls.json" <<JSON
[{"number":901,"title":"RESILIENT-9999: fix verified race","created_at":"$old","updated_at":"$fresh"},
 {"number":902,"title":"RESILIENT-9999: fix verified race again","created_at":"$old","updated_at":"$fresh"},
 {"number":903,"title":"RESILIENT-9999: fix verified race once more","created_at":"$old","updated_at":"$fresh"},
 {"number":904,"title":"RESILIENT-9999: brand new attempt","created_at":"$new","updated_at":"$fresh"},
 {"number":905,"title":"fix(dedup): detector bug (RESILIENT-9999 wedge)","created_at":"$old","updated_at":"$fresh"}]
JSON

# stub gh so the detector runs offline against the fixture
cat > "$TMP/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"repo view"*) echo "test/repo" ;;
  *"api"*pulls*)  cat "$TMP/pulls.json" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/gh"

out="$(PATH="$TMP:$PATH" bash "$ROOT/scripts/coord/duplicate-pr-detector.sh" 2>&1 || true)"
echo "$out"

fail() { echo "FAIL: $1"; exit 1; }
echo "$out" | grep -q "RESILIENT-9999" || fail "swarm not detected (old-created/bot-fresh group was skipped — the original bug)"
echo "$out" | grep -qi "WINNER" || fail "no winner chosen for the duplicate group"
# the genuinely-new PR (#904, created 1m ago) must NOT be closed as a loser
echo "$out" | grep -qi "LOSER #904" && fail "closed a genuinely-new PR (#904) that is still inside the fresh window"
# #905 only MENTIONS the gap mid-title ("(RESILIENT-9999 wedge)") — it must NOT be grouped/closed
echo "$out" | grep -qi "LOSER #905" && fail "grouped a PR that merely mentions the gap mid-title (the false-positive that nearly closed the fix's own PR)"
echo "PASS: stale swarm deduped despite bot-fresh updated_at; new PR + gap-mention PR both spared"
