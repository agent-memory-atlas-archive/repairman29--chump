#!/usr/bin/env bash
# scripts/ci/test-pillar-cap-auto-demote.sh — CREDIBLE-072
#
# Smoke test for the reserve-time pillar merge-share cap:
#  1. Seed an isolated state.db with synthetic merges (gaps closed as done in
#     the last 7d) putting RESILIENT at 50% of the week's merges.
#  2. `chump gap reserve` a new RESILIENT P1 gap → auto-demoted to P2, and
#     ambient.jsonl has kind=pillar_cap_demote naming the new gap.
#  3. Same reserve with --cap-override → keeps P1, decision=override logged.
#  4. CHUMP_PILLAR_CAP=0 → rule off, keeps P1.
#  5. `chump gap pillar-share` prints RESILIENT 50% [OVER CAP].
#  6. pillar_cap_demote is registered in EVENT_REGISTRY.yaml.
#
# Needs a built chump binary (CHUMP_BIN, or target/debug/chump) and python3.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -n "${CHUMP_BIN:-}" ]]; then
    CHUMP="$CHUMP_BIN"
elif [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
else
    CHUMP="$(command -v chump 2>/dev/null || echo chump)"
fi
[[ "$CHUMP" = /* ]] || CHUMP="$REPO_ROOT/$CHUMP"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
git -C "$FAKE" init -q
git -C "$FAKE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
AMBIENT="$FAKE/.chump-locks/ambient.jsonl"

export CHUMP_REPO="$FAKE" CHUMP_WORKTREE_ROOT="$FAKE"
# CREDIBLE-1519: isolate the RESILIENT-069 farmer gate's oauth path off the
# host ~/.chump (a stale host token would RED-block these seeds). --force would
# bypass the pillar-balance gate under test, so isolate via CHUMP_HOME instead.
export CHUMP_HOME="$FAKE"
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1 CHUMP_DISABLE_OFFLINE_CHECK=1
cd "$FAKE" || exit 1

reserve() {  # reserve <title> <priority> [extra args...] → prints new id
    local title="$1" prio="$2"; shift 2
    "$CHUMP" gap reserve --domain INFRA --title "$title" --priority "$prio" \
        --effort xs --force --no-outcome-required --no-evidence-required --quiet "$@" 2>>"$TMP/err.log" \
        | grep -oE 'INFRA-[0-9]+' | head -1
}
prio_of() {  # prio_of <id>
    python3 - "$FAKE/.chump/state.db" "$1" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute("SELECT priority FROM gaps WHERE id=?", (sys.argv[2],)).fetchone()
print(row[0] if row else "")
PY
}

echo "=== CREDIBLE-072 pillar-cap auto-demote smoke test ==="

# ── Seed: init the db, then 10 synthetic merges in the last day ──────────────
SEED_ID="$(CHUMP_PILLAR_CAP=0 reserve "seed row for pillar cap test" P3)"
if [[ -z "$SEED_ID" ]]; then
    fail "could not initialise state.db via gap reserve"; tail -5 "$TMP/err.log"
    echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
python3 - "$FAKE/.chump/state.db" "$SEED_ID" <<'PY'
import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1])
cols = [r[1] for r in db.execute("PRAGMA table_info(gaps)")]
seed = dict(zip(cols, db.execute("SELECT * FROM gaps WHERE id=?", (sys.argv[2],)).fetchone()))
now = int(time.time())
titles = ["RESILIENT: synthetic merge %d" % i for i in range(5)] + \
         ["EFFECTIVE: synthetic merge 0", "CREDIBLE: synthetic merge 0"] + \
         ["ZERO-WASTE: synthetic merge %d" % i for i in range(3)]
for i, t in enumerate(titles):
    row = dict(seed, id="SEED-%03d" % i, title=t, status="done", closed_at=now - 86400, priority="P2")
    db.execute("INSERT INTO gaps (%s) VALUES (%s)" % (",".join(row), ",".join("?" * len(row))), list(row.values()))
db.commit()
PY

# ── 1. RESILIENT at 50% → new RESILIENT P1 demoted to P2 + ambient event ─────
NEW_ID="$(reserve "RESILIENT: pillar cap smoke new gap" P1)"
if [[ -n "$NEW_ID" && "$(prio_of "$NEW_ID")" == "P2" ]]; then
    ok "new RESILIENT P1 gap auto-demoted to P2 ($NEW_ID)"
else
    fail "expected $NEW_ID at P2, got '$(prio_of "$NEW_ID")'"; tail -5 "$TMP/err.log"
fi
if grep -q "\"kind\":\"pillar_cap_demote\",\"gap_id\":\"$NEW_ID\",\"pillar\":\"RESILIENT\",\"current_share\":50.0,\"decision\":\"demote\"" "$AMBIENT" 2>/dev/null; then
    ok "ambient has pillar_cap_demote for $NEW_ID (RESILIENT 50.0%, demote)"
else
    fail "pillar_cap_demote event missing for $NEW_ID"; cat "$AMBIENT" 2>/dev/null | tail -3
fi

# ── 2. --cap-override keeps P1 and is logged ─────────────────────────────────
OVR_ID="$(reserve "RESILIENT: pillar cap override gap" P1 --cap-override "smoke test override")"
if [[ -n "$OVR_ID" && "$(prio_of "$OVR_ID")" == "P1" ]] \
   && grep -q "\"gap_id\":\"$OVR_ID\".*\"decision\":\"override\".*\"override_reason\":\"smoke test override\"" "$AMBIENT"; then
    ok "--cap-override keeps P1 and logs decision=override ($OVR_ID)"
else
    fail "--cap-override: expected P1 + override event, got '$(prio_of "$OVR_ID")'"
fi

# ── 3. CHUMP_PILLAR_CAP=0 disables the rule ──────────────────────────────────
OFF_ID="$(CHUMP_PILLAR_CAP=0 reserve "RESILIENT: pillar cap disabled gap" P1)"
if [[ -n "$OFF_ID" && "$(prio_of "$OFF_ID")" == "P1" ]] && ! grep -q "\"gap_id\":\"$OFF_ID\"" "$AMBIENT"; then
    ok "CHUMP_PILLAR_CAP=0 keeps P1 with no event ($OFF_ID)"
else
    fail "CHUMP_PILLAR_CAP=0: expected P1 and no event, got '$(prio_of "$OFF_ID")'"
fi

# ── 4. pillar-share status line ──────────────────────────────────────────────
LINE="$("$CHUMP" gap pillar-share 2>/dev/null)"
if [[ "$LINE" == "Pillars: RESILIENT 50% [OVER CAP]"* ]]; then
    ok "gap pillar-share: $LINE"
else
    fail "gap pillar-share line unexpected: '$LINE'"
fi

# ── 5. event registered ──────────────────────────────────────────────────────
if grep -q '^  - kind: pillar_cap_demote$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "pillar_cap_demote registered in EVENT_REGISTRY.yaml"
else
    fail "pillar_cap_demote missing from EVENT_REGISTRY.yaml"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
