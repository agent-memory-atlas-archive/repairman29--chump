#!/usr/bin/env bash
# test-credible-061-seed-consistency.sh — CREDIBLE-061
#
# Validates that the fixture seed in test-gap-list-since-json-schema.sh
# produces the expected number of gaps. This test runs the seed in isolation
# and asserts the count matches the threshold (≥5).
#
# Motivation: if the seed drifts (only 3 gaps created instead of 5), the
# schema test fails downstream with a confusing "expected ≥5; got 3" message.
# This test catches the seed drift directly so the root cause is visible.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

echo "=== CREDIBLE-061: seed consistency check ==="
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
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1
export CHUMP_PILLAR_BALANCE_DISABLE=1

# ── 3. Seed 5 synthetic gaps ──────────────────────────────────────────────────
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

# ── 4. Verify seed count matches threshold ───────────────────────────────────
FIXTURE_COUNT=$("$BIN" gap list --json 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
EXPECTED_MIN=5

if [[ "$FIXTURE_COUNT" -ge "$EXPECTED_MIN" ]]; then
    ok "seed produced ≥$EXPECTED_MIN fixture gaps (actual=$FIXTURE_COUNT)"
else
    fail "seed produced only $FIXTURE_COUNT gaps; expected ≥$EXPECTED_MIN"
    printf '  seeding diagnostics:%s\n' "${SEED_DIAG:-
    (no reserve errors captured — gaps created then vanished?)}" >&2
fi

# ── 5. Per-domain validation ──────────────────────────────────────────────────
# Ensure each domain has at least one gap (robustness check)
for domain in "${DOMAINS[@]}"; do
    count=$("$BIN" gap list --domain "$domain" --json 2>/dev/null \
        | python3 -c "import json,sys; gaps = json.load(sys.stdin); print(len([g for g in gaps if g.get('domain') == '$domain']))" 2>/dev/null || echo 0)
    if [[ "$count" -ge 1 ]]; then
        ok "domain $domain has ≥1 gap (count=$count)"
    else
        fail "domain $domain has no gaps"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
