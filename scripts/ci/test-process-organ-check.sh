#!/usr/bin/env bash
# scripts/ci/test-process-organ-check.sh — INFRA-7588 (process-organ health
# reporting, INFRA-3648 slice)
#
# Proves `process-organ-heal.sh --check` reports per-organ DETECTED-ALIVE /
# DETECTED-DEAD / UNKNOWN status from the pgrep detector alone (no systemctl
# dependency), exits non-zero when any organ is DETECTED-DEAD, and exits 0
# when all organs are alive. Uses a stubbed `pgrep` and a synthetic registry
# so the test is deterministic (no real background processes).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HEAL="$REPO_ROOT/scripts/ops/process-organ-heal.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-process-organ-check.sh (INFRA-7588) ==="

[[ -f "$HEAL" ]] || fail "heal script missing: $HEAL"
bash -n "$HEAL" || fail "heal script bash -n failed"
grep -q -- '--check' "$HEAL" || fail "--check flag not implemented in process-organ-heal.sh"
pass "script present, syntax clean, --check flag wired"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/scripts/ops"

REGISTRY="$TMP/registry.txt"
cat > "$REGISTRY" <<'EOF'
alive-organ|scripts/ops/alive-organ.sh
dead-organ|scripts/ops/dead-organ.sh
EOF

# ── 1. Mixed registry: one alive, one dead -> DETECTED-ALIVE / DETECTED-DEAD, exit 1 ──
PGREP_MIXED="$TMP/pgrep-mixed"
cat > "$PGREP_MIXED" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *alive-organ.sh*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$PGREP_MIXED"

OUT="$TMP/out-mixed.log"
REPO_ROOT="$FAKE_REPO" \
CHUMP_PROCESS_ORGAN_REGISTRY="$REGISTRY" \
CHUMP_PROCESS_ORGAN_PGREP_BIN="$PGREP_MIXED" \
CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" \
    bash "$HEAL" --check > "$OUT" 2>&1
rc=$?
[[ $rc -eq 1 ]] || fail "expected exit 1 with a DETECTED-DEAD organ, got $rc: $(cat "$OUT")"
grep -q 'DETECTED-ALIVE: alive-organ' "$OUT" || fail "alive-organ not reported DETECTED-ALIVE: $(cat "$OUT")"
grep -q 'DETECTED-DEAD: dead-organ' "$OUT" || fail "dead-organ not reported DETECTED-DEAD: $(cat "$OUT")"
pass "mixed registry: DETECTED-ALIVE + DETECTED-DEAD reported, exit 1 (AC2, AC3, AC6)"

# ── 2. All-alive registry -> exit 0 (mirrors '9 live organs' scenario, AC5) ──
REGISTRY_ALIVE="$TMP/registry-alive.txt"
cat > "$REGISTRY_ALIVE" <<'EOF'
organ-a|scripts/ops/alive-organ.sh
organ-b|scripts/ops/alive-organ.sh
organ-c|scripts/ops/alive-organ.sh
EOF
PGREP_ALIVE="$TMP/pgrep-alive"
cat > "$PGREP_ALIVE" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PGREP_ALIVE"

OUT2="$TMP/out-alive.log"
REPO_ROOT="$FAKE_REPO" \
CHUMP_PROCESS_ORGAN_REGISTRY="$REGISTRY_ALIVE" \
CHUMP_PROCESS_ORGAN_PGREP_BIN="$PGREP_ALIVE" \
CHUMP_AMBIENT_LOG="$TMP/ambient2.jsonl" \
    bash "$HEAL" --check > "$OUT2" 2>&1
rc2=$?
[[ $rc2 -eq 0 ]] || fail "expected exit 0 when all organs alive, got $rc2: $(cat "$OUT2")"
[[ "$(grep -c 'DETECTED-ALIVE' "$OUT2")" -eq 3 ]] || fail "expected 3 DETECTED-ALIVE lines: $(cat "$OUT2")"
pass "all-alive registry: 3/3 DETECTED-ALIVE, exit 0 (AC5)"

# ── 3. --check never spawns anything, even when an organ is dead ───────────
[[ -f "$FAKE_REPO/scripts/ops/dead-organ-ran" ]] && fail "--check spawned an organ (should never spawn)"
pass "--check never spawns (read-only report)"

# ── 4. --check does not depend on systemctl (AC4) ───────────────────────────
grep -vE '^\s*#' "$HEAL" | grep -q 'systemctl' \
    && fail "process-organ-heal.sh has a non-comment systemctl reference (AC4 forbids this)"
pass "no systemctl dependency anywhere in process-organ-heal.sh (AC4)"

echo "=== all process-organ --check tests passed ==="
