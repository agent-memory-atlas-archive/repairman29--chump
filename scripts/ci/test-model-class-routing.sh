#!/usr/bin/env bash
# INFRA-471: test model-class-aware fleet routing.
#
# Verifies that:
#   1. flash (deepseek) workers take xs/s only; haiku/sonnet gates retired (RESILIENT-1138)
#   2. sonnet workers pick effort=xs gaps by default (INFRA-2998: all-sonnet
#      fleet); refusal is opt-in via CHUMP_MIXED_FLEET_XS_GATE=1
#   3. _resolve_model.py returns the correct model class per routing.yaml
#
# Exit 0 = all checks pass; exit 1 = any failure.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PICK_SCRIPT="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
RESOLVE_SCRIPT="$REPO_ROOT/scripts/dispatch/_resolve_model.py"
PASS=0
FAIL=0

ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

# ── Test fixture: fake gap JSON with various effort levels ─────────────────
GAP_JSON='[
  {"id":"TEST-001","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1,"acceptance_criteria":"has real criteria"},
  {"id":"TEST-002","domain":"INFRA","priority":"P1","effort":"s", "status":"open","created_at":2},
  {"id":"TEST-003","domain":"INFRA","priority":"P1","effort":"m", "status":"open","created_at":3},
  {"id":"TEST-004","domain":"INFRA","priority":"P1","effort":"l", "status":"open","created_at":4},
  {"id":"TEST-005","domain":"INFRA","priority":"P1","effort":"xl","status":"open","created_at":5}
]'

run_picker() {
    # Run _pick_gap.py with given FLEET_MODEL; prints picked gap ID or empty.
    local model="$1"
    local tmpfile
    tmpfile="$(mktemp -t routing-test.XXXXXX)"
    printf '%s' "$GAP_JSON" > "$tmpfile"
    result="$(GAP_JSON_FILE="$tmpfile" \
        FLEET_MODEL="$model" \
        FLEET_PRIORITY_FILTER="P0,P1" \
        FLEET_DOMAIN_FILTER="" \
        FLEET_EFFORT_FILTER="xs,s,m,l,xl" \
        EXCLUDE_RE="^$" \
        ACTIVE_GAPS="" \
        WORKER_INDEX="1" \
        COOLDOWN_DIR="" \
        python3 "$PICK_SCRIPT" 2>/dev/null || true)"
    rm -f "$tmpfile"
    printf '%s' "$result"
}

# ── 1. flash (deepseek) takes xs/s only; haiku gate retired (RESILIENT-1138) ──
picked="$(run_picker flash)"
if [[ "$picked" == "TEST-001" ]] || [[ "$picked" == "TEST-002" ]]; then
    ok "flash picks xs/s (picked=$picked)"
else
    fail "flash should pick xs/s but got: '$picked'"
fi

tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '[{"id":"TEST-M","domain":"INFRA","priority":"P1","effort":"m","status":"open","created_at":1,"acceptance_criteria":"has real criteria"}]' > "$tmpf"
flash_m="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=flash FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ -z "$flash_m" ]]; then ok "flash refuses effort=m"; else fail "flash should refuse effort=m, got: '$flash_m'"; fi

# haiku/sonnet gates are retired: both pick any effort
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '[{"id":"TEST-XS","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1,"acceptance_criteria":"has real criteria"}]' > "$tmpf"
for mdl in sonnet haiku; do
    got="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=$mdl FLEET_PRIORITY_FILTER="" \
        FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
        ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
        CHUMP_MIXED_FLEET_XS_GATE=1 python3 "$PICK_SCRIPT" 2>/dev/null || true)"
    if [[ "$got" == "TEST-XS" ]]; then ok "$mdl picks effort=xs (gate retired)"; else fail "$mdl should pick xs, got: '$got'"; fi
done
rm -f "$tmpf"

# sonnet accepts m
GAP_JSON_SM='[{"id":"TEST-SM","domain":"INFRA","priority":"P1","effort":"m","status":"open","created_at":1,"acceptance_criteria":"has real criteria"}]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$GAP_JSON_SM" > "$tmpf"
sonnet_m="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=sonnet FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ "$sonnet_m" == "TEST-SM" ]]; then
    ok "sonnet picks effort=m"
else
    fail "sonnet should pick effort=m but got: '$sonnet_m'"
fi

# ── 3. _resolve_model.py: effort → model class ──────────────────────────────
resolve() {
    local gap_id="$1" effort="$2" domain="$3"
    local json="[{\"id\":\"${gap_id}\",\"domain\":\"${domain}\",\"effort\":\"${effort}\",\"status\":\"open\"}]"
    printf '%s' "$json" | \
        GAP_ID="$gap_id" REPO_ROOT="$REPO_ROOT" FLEET_MODEL="sonnet" \
        python3 "$RESOLVE_SCRIPT" 2>/dev/null || true
}

# RESILIENT-154 (#3146) flipped routing.yaml xs/s from haiku → sonnet ("remove
# haiku from the fleet — sonnet is the floor"): haiku stalled ~60% of cycles and
# saves $0 on a flat subscription. _resolve_model.py now returns sonnet for xs/s.
m_for_xs="$(resolve TEST-XS xs INFRA)"
if [[ "$m_for_xs" == "flash" ]]; then
    ok "resolve: effort=xs → flash (deepseek, RESILIENT-1138)"
else
    fail "resolve: effort=xs should → flash, got: '$m_for_xs'"
fi

m_for_s="$(resolve TEST-S s INFRA)"
if [[ "$m_for_s" == "flash" ]]; then
    ok "resolve: effort=s → flash (deepseek, RESILIENT-1138)"
else
    fail "resolve: effort=s should → flash, got: '$m_for_s'"
fi

m_for_m="$(resolve TEST-M m INFRA)"
if [[ "$m_for_m" == "sonnet" ]]; then
    ok "resolve: effort=m → sonnet"
else
    fail "resolve: effort=m should → sonnet, got: '$m_for_m'"
fi

m_for_l="$(resolve TEST-L l INFRA)"
if [[ "$m_for_l" == "sonnet" ]]; then
    ok "resolve: effort=l → sonnet"
else
    fail "resolve: effort=l should → sonnet, got: '$m_for_l'"
fi

# ── 4. task_class routing: COG-* → cognition → sonnet ──────────────────────
m_for_cog="$(resolve COG-042 m COG)"
if [[ "$m_for_cog" == "sonnet" ]]; then
    ok "resolve: COG-* task_class=cognition → sonnet"
else
    fail "resolve: COG-* should → sonnet (cognition route), got: '$m_for_cog'"
fi

# ── 5. mixed fleet simulation: pick from shared pool ───────────────────────
# Pool has xs, s, m, l. Haiku should pick xs or s; sonnet (all-sonnet fleet
# default, INFRA-2998) is no longer gated off xs, so it may pick any of them —
# effort_rank sorts xs first, so it picks xs here.
POOL='[
  {"id":"POOL-XS","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1,"acceptance_criteria":"has real criteria"},
  {"id":"POOL-S", "domain":"INFRA","priority":"P1","effort":"s", "status":"open","created_at":2,"acceptance_criteria":"has real criteria"},
  {"id":"POOL-M", "domain":"INFRA","priority":"P1","effort":"m", "status":"open","created_at":3,"acceptance_criteria":"has real criteria"},
  {"id":"POOL-L", "domain":"INFRA","priority":"P1","effort":"l", "status":"open","created_at":4,"acceptance_criteria":"has real criteria"}
]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$POOL" > "$tmpf"
flash_pool="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=flash FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ "$flash_pool" == "POOL-XS" ]] || [[ "$flash_pool" == "POOL-S" ]]; then
    ok "mixed pool: flash picks xs/s (got $flash_pool)"
else
    fail "mixed pool: flash should pick xs/s, got: '$flash_pool'"
fi

tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$POOL" > "$tmpf"
sonnet_pool="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=sonnet FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ "$sonnet_pool" == "POOL-XS" ]] || [[ "$sonnet_pool" == "POOL-S" ]] || [[ "$sonnet_pool" == "POOL-M" ]] || [[ "$sonnet_pool" == "POOL-L" ]]; then
    ok "mixed pool: sonnet picks xs/s/m/l (got $sonnet_pool)"
else
    fail "mixed pool: sonnet should pick xs/s/m/l, got: '$sonnet_pool'"
fi

# ── 6. INFRA-8177: P0 and keystone/unwedge floor (>= sonnet, never haiku/flash) ─
m_p0_xs="$(printf '[{"id":"TEST-P0-XS","domain":"INFRA","priority":"P0","effort":"xs","status":"open"}]' | \
    GAP_ID="TEST-P0-XS" REPO_ROOT="$REPO_ROOT" FLEET_MODEL="haiku" python3 "$RESOLVE_SCRIPT" 2>/dev/null || true)"
if [[ "$m_p0_xs" == "sonnet" ]]; then
    ok "INFRA-8177: P0 + effort=xs routes to sonnet floor"
else
    fail "INFRA-8177: P0 + effort=xs should route to sonnet, got: '$m_p0_xs'"
fi

m_keystone_xs="$(printf '[{"id":"TEST-KS-XS","domain":"INFRA","priority":"P2","effort":"xs","skills_required":"rust,keystone","status":"open"}]' | \
    GAP_ID="TEST-KS-XS" REPO_ROOT="$REPO_ROOT" FLEET_MODEL="haiku" python3 "$RESOLVE_SCRIPT" 2>/dev/null || true)"
if [[ "$m_keystone_xs" == "sonnet" ]]; then
    ok "INFRA-8177: P2 + keystone + effort=xs routes to sonnet floor"
else
    fail "INFRA-8177: P2 + keystone + effort=xs should route to sonnet, got: '$m_keystone_xs'"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
