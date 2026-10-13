#!/usr/bin/env bash
# test-gap-list-since-json-schema.sh — CREDIBLE-061
#
# Verifies that `chump gap list --json` emits valid JSON where every gap
# object contains the required fields consumed by ambient stream processors:
#   id, title, status, priority, effort, domain
#
# Uses a synthetic state.db fixture with 5 gaps; no network or real DB.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

echo "=== CREDIBLE-061: chump gap list --json schema test ==="
echo

# ── 1. Binary presence ────────────────────────────────────────────────────────
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — cannot run functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "chump binary present"

# ── 2. Isolated fixture environment ──────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
# CREDIBLE-107: the new --evidence gate blocks P1 RESILIENT/MISSION/CREDIBLE
# reserves without --evidence. Test fixtures aren't real gaps and don't
# need real evidence; bypass the gate for the seeding loop only.
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1
# EFFECTIVE-294: default AC are now concrete (no TODO placeholders), which
# makes fixture gaps *pickable* — activating the INFRA-1152 pillar-balance
# gate inside this synthetic 5-gap DB (first pillar reserve = 100% of pool →
# blocked, seeding dies at 1/5). The fixture isn't real pillar inventory;
# disable the gate for seeding, same rationale as the evidence bypass above.
export CHUMP_PILLAR_BALANCE_DISABLE=1

# ── 3. Seed 5 synthetic gaps ──────────────────────────────────────────────────
# CREDIBLE-144: this loop used to run `gap reserve ... --quiet 2>/dev/null || true`,
# silently swallowing any reserve failure. Under CI resource pressure a transient
# reserve failure then surfaced only as a confusing "expected ≥5; got N" with no
# cause — false-failing unrelated PRs (e.g. #3167, #3155) that never touched the
# reserve path. Now: capture stderr, retry each reserve, and on a short fixture
# print the captured diagnostics so the *real* cause is visible in the CI log.
DOMAINS=(INFRA CREDIBLE RESILIENT EFFECTIVE ZERO-WASTE)
SEED_DIAG=""
for domain in "${DOMAINS[@]}"; do
    title="credible-061-fixture-$(echo "$domain" | tr '[:upper:]' '[:lower:]')"
    seeded=0
    for attempt in 1 2 3; do
        # RESILIENT, CREDIBLE domains require --evidence for P1 gaps (CREDIBLE-107 gate)
        evidence_arg=""
        if [[ "$domain" == "RESILIENT" ]] || [[ "$domain" == "CREDIBLE" ]]; then
            evidence_arg="--evidence test fixture"
        fi
        if err="$("$BIN" gap reserve \
                    --domain "$domain" \
                    --priority P1 \
                    --effort xs \
                    --title "$title" \
                    --force-duplicate \
                    $evidence_arg \
                    --quiet 2>&1)"; then
            seeded=1
            break
        fi
        SEED_DIAG="${SEED_DIAG}
    [$domain attempt $attempt] reserve exited non-zero: ${err:-<no output>}"
        sleep 0.5
    done
    if [[ "$seeded" -ne 1 ]]; then
        SEED_DIAG="${SEED_DIAG}
    [$domain] FAILED to seed after 3 attempts"
    fi
done

FIXTURE_COUNT=$("$BIN" gap list --json 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
if [[ "$FIXTURE_COUNT" -ge 5 ]]; then
    ok "5 fixture gaps seeded (total=$FIXTURE_COUNT)"
else
    fail "expected ≥5 fixture gaps; got $FIXTURE_COUNT"
    printf '  seeding diagnostics (CREDIBLE-144):%s\n' "${SEED_DIAG:-
    (no reserve errors captured — gaps created then vanished?)}" >&2
fi

# ── 4. JSON output: required fields present in every gap ─────────────────────
REQUIRED_FIELDS=(id title status priority effort domain)
JSON=$("$BIN" gap list --json 2>/dev/null)

VALID=$(python3 -c "
import json, sys
raw = sys.stdin.read()
fields = ['id','title','status','priority','effort','domain']
try:
    gaps = json.loads(raw)
except Exception as e:
    print('invalid JSON: ' + str(e))
    sys.exit(0)
if not isinstance(gaps, list):
    print('top-level value is not a JSON array')
    sys.exit(0)
missing = {}
for gap in gaps:
    for f in fields:
        if f not in gap:
            missing[f] = missing.get(f, 0) + 1
if missing:
    for f, cnt in missing.items():
        print('field ' + f + ' missing in ' + str(cnt) + ' gap(s)')
    sys.exit(0)
print('ok')
" <<< "$JSON" 2>/dev/null || echo "python-error")

if [[ "$VALID" == "ok" ]]; then
    ok "all required fields present (id, title, status, priority, effort, domain)"
else
    fail "JSON schema violation: $VALID"
fi

# ── 5. --since filter: valid JSON, object wrapper with gaps key + schema ─────
# When --since is given, chump gap list --json returns:
#   {"gaps": [...], "since_cutoff": "YYYY-MM-DD"}
SINCE_JSON=$("$BIN" gap list --since 9999d --json 2>/dev/null || true)
SINCE_RESULT=$(python3 -c "
import json, sys
raw = sys.stdin.read()
fields = ['id','title','status','priority','effort','domain']
try:
    obj = json.loads(raw)
except Exception as e:
    print('invalid JSON: ' + str(e))
    sys.exit(0)
# Accept both wrapped object {gaps:[...], since_cutoff:...} and bare array.
if isinstance(obj, list):
    gaps = obj
elif isinstance(obj, dict) and 'gaps' in obj and 'since_cutoff' in obj:
    gaps = obj['gaps']
else:
    print('unexpected shape: ' + str(type(obj)))
    sys.exit(0)
missing = {}
for gap in gaps:
    for f in fields:
        if f not in gap:
            missing[f] = missing.get(f, 0) + 1
if missing:
    for f, cnt in missing.items():
        print('field ' + f + ' missing in ' + str(cnt) + ' gap(s)')
    sys.exit(0)
print('ok:' + str(len(gaps)))
" <<< "$SINCE_JSON" 2>/dev/null || echo "python-error")
if [[ "$SINCE_RESULT" == ok:* ]]; then
    COUNT="${SINCE_RESULT#ok:}"
    ok "--since 9999d returns valid JSON envelope with correct schema ($COUNT gap(s) matched)"
else
    fail "--since 9999d JSON problem: $SINCE_RESULT"
fi

# ── 6. Idempotency: second run returns same count ─────────────────────────────
SECOND_COUNT=$("$BIN" gap list --json 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
if [[ "$SECOND_COUNT" -eq "$FIXTURE_COUNT" ]]; then
    ok "idempotent: second gap list returns same count ($SECOND_COUNT)"
else
    fail "non-idempotent: first=$FIXTURE_COUNT, second=$SECOND_COUNT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
