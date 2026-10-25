#!/usr/bin/env bash
# test-mission-scoreboard-zerotouch.sh — COTG-3.3 / INFRA-3496.
#
# Proves axis ① of mission-scoreboard.sh classifies a BEAST merge by the
# `Chump-Agent:` commit trailer (the fleet's autonomous signature), not by a raw
# merge count. Depth: correctness — a stub `gh` injects one merged BEAST PR whose
# commit body either carries the trailer (→ zero-touch YES) or doesn't (→ NO,
# human-in-loop). Hermetic: no network; stub `gh` on PATH.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$REPO_ROOT/scripts/dev/mission-scoreboard.sh"
[ -f "$SB" ] || { echo "[test] FAIL: $SB missing"; exit 1; }

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub gh: one merged BEAST PR (#999); its commit body comes from $STUB_BODY.
# Every other gh call returns empty (the rest of the scoreboard degrades cleanly).
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"pr list"*"--json number"*) echo "999" ;;
  *"pr view"*commits*)          printf '%s\n' "${STUB_BODY:-}" ;;
  *)                            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run() { PATH="$STUB_DIR:$PATH" STUB_BODY="$1" timeout 90 bash "$SB" 2>/dev/null; }

fail=0

# (a) commit WITH the Chump-Agent trailer → zero-touch YES
out="$(run 'implement the thing

Chump-Agent: Widget@test-machine')"
if echo "$out" | grep -qE '① THE BINARY.*'; then :; fi
if echo "$out" | grep -q 'zero-touch (Chump-Agent) of'; then
  echo "[test] (a) trailered merge → ① reports zero-touch: OK"
else
  echo "[test] (a) FAIL: trailered merge not reported as zero-touch"; echo "$out" | grep -A1 '① THE BINARY'; fail=1
fi

# (b) commit WITHOUT the trailer → NOT zero-touch (human-in-loop)
out="$(run 'a human fixed this

Co-Authored-By: Somebody <x@y.z>')"
if echo "$out" | grep -qE 'human-in-loop, not zero-touch'; then
  echo "[test] (b) untrailered merge → ① reports human-in-loop NO: OK"
else
  echo "[test] (b) FAIL: untrailered merge not reported as human-in-loop"; echo "$out" | grep -A1 '① THE BINARY'; fail=1
fi

# ── (c) CREDIBLE-238: R&D merge excluded from Gate-2 mission-ship ratio numerator ──
cat > "$STUB_DIR/gh" <<'STUB_GH2'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"pr list"*"--json title"*)
    printf '%s\n' "${STUB_MERGED_TITLES:-}"
    ;;
  *)
    :
    ;;
esac
exit 0
STUB_GH2
chmod +x "$STUB_DIR/gh"

cat > "$STUB_DIR/chump" <<'STUB_CHUMP'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "show" ]]; then
  gid="${3:-}"
  case "$gid" in
    INFRA-777)
      echo '{"id":"INFRA-777","domain":"RND","title":"R&D: benchmark experiment","outcome_id":"MISSION-010"}'
      ;;
    *)
      echo '{"id":"'"$gid"'","domain":"MISSION","outcome_id":"MISSION-010"}'
      ;;
  esac
fi
exit 0
STUB_CHUMP
chmod +x "$STUB_DIR/chump"

out_no_rnd="$(PATH="$STUB_DIR:$PATH" STUB_MERGED_TITLES=$'MISSION-001: ship one\nMISSION-002: ship two' timeout 90 bash "$SB" 2>/dev/null)"
out_with_rnd="$(PATH="$STUB_DIR:$PATH" STUB_MERGED_TITLES=$'MISSION-001: ship one\nMISSION-002: ship two\nRND-009: experiment no-go\nINFRA-777: R&D experiment with outcome_id' timeout 90 bash "$SB" 2>/dev/null)"

if grep -q '② Mission-ship ratio (24h): 2/2' <<<"$out_no_rnd" \
   && grep -q '② Mission-ship ratio (24h): 2/4' <<<"$out_with_rnd" \
   && grep -q 'R&D excluded' <<<"$out_with_rnd"; then
  echo "[test] (c) CREDIBLE-238: R&D merges do not increment mission-ship numerator (2/2 without R&D, 2/4 with 2 R&D merges) and Gate-2 line states 'R&D excluded': OK"
else
  echo "[test] (c) FAIL: CREDIBLE-238 ratio or label check failed"
  echo "  without R&D: $(grep '② Mission-ship ratio' <<<"$out_no_rnd")"
  echo "  with R&D:    $(grep '② Mission-ship ratio' <<<"$out_with_rnd")"
  fail=1
fi

if grep -q 'NO-GO' "$SB" && grep -q 'gameable' "$SB" \
   && grep -q 'pub rnd: usize' "$REPO_ROOT/src/roadmap_status.rs" \
   && grep -q '"R&D"' "$REPO_ROOT/scripts/coord/opus-curator.sh"; then
  echo "[test] (d) CREDIBLE-238: exclusion comment cites NO-GO/gameable reasoning and R&D remains in pillar_coverage + balance_restock: OK"
else
  echo "[test] (d) FAIL: CREDIBLE-238 comment or pillar_coverage/balance_restock check failed"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "[test-mission-scoreboard-zerotouch] PASS" || { echo "[test-mission-scoreboard-zerotouch] FAIL"; exit 1; }
