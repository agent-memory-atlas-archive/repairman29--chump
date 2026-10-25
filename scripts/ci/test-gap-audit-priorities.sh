#!/usr/bin/env bash
# test-gap-audit-priorities.sh — INFRA-586
#
# Validates the `chump gap audit-priorities` subcommand:
#  - subcommand wired in main.rs
#  - all 7 metric fields present in --json output
#  - exit-0 on a clean fixture DB (no P0s, no vague, no race pollution)
#  - exit-1 on vague (no AC) open gap
#  - CLAUDE.md MISSION-PM section documents the command

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-586 gap audit-priorities test ==="
echo

# 1. Subcommand wired in main.rs.
if grep -q '"audit-priorities"' "$REPO_ROOT/src/main.rs"; then
    ok "audit-priorities arm in main.rs"
else
    fail "audit-priorities arm missing from main.rs"
fi

# 2. Help text lists audit-priorities.
if grep -q 'audit-priorities' "$REPO_ROOT/src/main.rs"; then
    ok "audit-priorities mentioned in help/match"
else
    fail "audit-priorities not mentioned in main.rs"
fi

# 3. CLAUDE.md MISSION-PM section documents chump gap audit-priorities.
if grep -q 'audit-priorities' "$REPO_ROOT/CLAUDE.md"; then
    ok "CLAUDE.md references audit-priorities"
else
    fail "CLAUDE.md missing audit-priorities reference"
fi

if grep -q 'MISSION-PM\|META-046' "$REPO_ROOT/CLAUDE.md"; then
    ok "CLAUDE.md has MISSION-PM / META-046 section"
else
    fail "CLAUDE.md missing MISSION-PM / META-046 section"
fi

# 4. Functional test: build binary and run against an isolated fixture DB.
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

# 4a. Empty DB → exit 0 and expected JSON keys present.
JSON=$("$BIN" gap audit-priorities --json 2>/dev/null)
for key in p0_count vague_pickable double_encoded_depends_on missing_dep_refs \
           open_with_closed_pr race_test_pollution p0_stuck_7d; do
    if echo "$JSON" | grep -q "\"$key\""; then
        ok "JSON key $key present"
    else
        fail "JSON key $key missing"
    fi
done

if "$BIN" gap audit-priorities --json >/dev/null 2>&1; then
    ok "exit 0 on empty registry"
else
    fail "expected exit 0 on empty registry"
fi

# 4b. Open gap with no AC → vague_pickable > 0 → exit 1.
# INFRA-2984: since EFFECTIVE-294, `gap reserve` auto-fills concrete default
# AC unless --skip-obs-acs is passed — without it this fixture no longer
# produces a vague gap and the test below silently stopped testing anything.
"$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "audit-prio-fixture-vague" --skip-obs-acs --no-ac-required --force --quiet 2>/dev/null
if ! "$BIN" gap audit-priorities >/dev/null 2>&1; then
    ok "exit 1 on vague pickable gap"
else
    fail "expected exit 1 on vague pickable gap"
fi

# INFRA-2984: audit-priorities now exits 1 whenever vague_pickable > 0 (that
# IS the fixture we just set up), and under `set -o pipefail` a non-zero exit
# from $BIN made the pipeline itself fail, so `|| echo 0` fired *in addition
# to* python3's real count — two lines glued into one non-numeric string that
# broke the `[[ -ge ]]` comparison below. `|| true` on the $BIN call keeps
# its stdout while not tripping pipefail.
VAGUE_COUNT=$({ "$BIN" gap audit-priorities --json 2>/dev/null || true; } \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('vague_pickable',0))" 2>/dev/null || echo 0)
if [[ "$VAGUE_COUNT" -ge 1 ]]; then
    ok "vague_pickable count >= 1 (got $VAGUE_COUNT)"
else
    fail "vague_pickable count should be >=1 (got $VAGUE_COUNT)"
fi

# 4c. race-* title pollution check.
"$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "race-fixture-test" --force --quiet 2>/dev/null
RACE_COUNT=$({ "$BIN" gap audit-priorities --json 2>/dev/null || true; } \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('race_test_pollution',0))" 2>/dev/null || echo 0)
if [[ "$RACE_COUNT" -ge 1 ]]; then
    ok "race_test_pollution count >= 1 (got $RACE_COUNT)"
else
    fail "race_test_pollution count should be >=1 (got $RACE_COUNT)"
fi

# 4d. placeholder-title pollution check (CREDIBLE-225).
"$BIN" gap reserve --domain CREDIBLE --priority P2 --effort xs \
    --title "tmp" --force --quiet 2>/dev/null
PLACEHOLDER_COUNT=$({ "$BIN" gap audit-priorities --json 2>/dev/null || true; } \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('placeholder_title_pollution',0))" 2>/dev/null || echo 0)
if [[ "$PLACEHOLDER_COUNT" -ge 1 ]]; then
    ok "placeholder_title_pollution count >= 1 (got $PLACEHOLDER_COUNT)"
else
    fail "placeholder_title_pollution count should be >=1 (got $PLACEHOLDER_COUNT)"
fi

# 4e. phantom_ref_allowlist in docs/process/RESEARCH_INTEGRITY.md (CREDIBLE-095):
#     - allowlisted prefixes (EVAL-*, RESEARCH-*) are skipped (0 phantoms)
#     - non-allowlisted nonexistent gap ID (INFRA-999999) is flagged as phantom
mkdir -p "$TMP/docs/process" "$TMP/docs/gaps"
cat > "$TMP/docs/process/RESEARCH_INTEGRITY.md" <<'EOF'
---
doc_tag: canonical
phantom_ref_allowlist: [EVAL-*, RESEARCH-*]
---
Historical references EVAL-001 and RESEARCH-004 are allowlisted.
EOF
PHANTOM_HIT=$({ "$BIN" gap audit-priorities --json 2>/dev/null || true; } \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('phantom_doc_refs',99))" 2>/dev/null || echo 99)
if [[ "$PHANTOM_HIT" -eq 0 ]]; then
    ok "CREDIBLE-095: phantom_ref_allowlist skips allowlisted EVAL-* and RESEARCH-* IDs (phantom_doc_refs=0)"
else
    fail "CREDIBLE-095: expected phantom_doc_refs=0 for allowlisted IDs, got $PHANTOM_HIT"
fi

cat >> "$TMP/docs/process/RESEARCH_INTEGRITY.md" <<'EOF'
Unregistered reference INFRA-999999 must still be caught.
EOF
PHANTOM_MISS=$({ "$BIN" gap audit-priorities --json 2>/dev/null || true; } \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('phantom_doc_refs',0))" 2>/dev/null || echo 0)
if [[ "$PHANTOM_MISS" -eq 1 ]]; then
    ok "CREDIBLE-095: non-allowlisted phantom ref INFRA-999999 is caught (phantom_doc_refs=1)"
else
    fail "CREDIBLE-095: expected phantom_doc_refs=1 for non-allowlisted INFRA-999999, got $PHANTOM_MISS"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
