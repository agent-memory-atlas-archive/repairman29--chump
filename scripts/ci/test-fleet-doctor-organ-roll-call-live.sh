#!/usr/bin/env bash
# test-fleet-doctor-organ-roll-call-live.sh — INFRA-3646 (TREK-20)
#
# Verifies fleet-doctor-strict.sh's check_organ_roll_call_live:
#   1. `enabled` unit with unmet requires= → skip (not-applicable), never
#      asserted against systemctl.
#   2. `enabled` + applicable + systemctl is-active → pass.
#   3. `enabled` + applicable + inactive + NO backoff record → fail, detail
#      says "dead and unowned".
#   4. `enabled` + applicable + inactive + fresh backoff record (still inside
#      cooldown) → fail, detail says "IN BACKOFF COOLDOWN" (distinguishing it
#      from the unowned case).
#   5. `enabled` + applicable + inactive + EXPIRED backoff record (cooldown
#      elapsed) → fail, detail says "dead and unowned" (same as case 3 — an
#      expired backoff is no different from never having one).
#
# Proves the INFRA-3646 behavior: Roll-Call must go from "declared in the
# manifest" (static, RESILIENT-366) to "actually is-active right now" (live),
# while never flagging organs that are legitimately not-applicable to this
# node, and while telling an operator which dead organs the healer already
# gave up on vs. which ones nobody is watching at all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMP="$(mktemp -d -t test-fleet-doctor-organ-roll-call-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── stub systemctl: `is-active <unit>` succeeds iff unit is listed in
#    $ACTIVE_FILE ────────────────────────────────────────────────────────────
ACTIVE_FILE="$TMP/active.txt"
: > "$ACTIVE_FILE"
STUB="$TMP/systemctl"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$STUB"

BACKOFF_DIR="$TMP/organ-backoff"
mkdir -p "$BACKOFF_DIR"

FILE_ASSET="$TMP/cj-worker-run.sh"
echo "#!/usr/bin/env bash" > "$FILE_ASSET"

MANIFEST="$TMP/manifest.txt"
cat > "$MANIFEST" <<EOF
enabled     chump-not-applicable.timer  role=muscle requires=bin:this-binary-does-not-exist-anywhere
enabled     chump-happy.timer  role=brain
enabled     chump-unowned-dead.timer  role=muscle
enabled     chump-backoff-cooling.timer  role=data
enabled     chump-backoff-expired.timer  role=data
enabled     chump-cj-worker.service  role=muscle requires=bin:bash,file:$FILE_ASSET
enabled     chump-cj-file-missing.service  role=muscle requires=file:$TMP/no-such-asset
EOF

# Source the doctor script for direct function access (matches the
# FLEET_DOCTOR_SOURCED pattern used by the other fleet-doctor-strict.sh
# check tests, e.g. test-fleet-doctor-auth-probe.sh).
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_n_status() { printf '%s' "${STATUSES[-${1}]:-}"; }
last_n_detail() { printf '%s' "${DETAILS[-${1}]:-}"; }

run_check() {
    CHECKS=(); STATUSES=(); DETAILS=(); REMEDIES=(); PASS_COUNT=0; FAIL_COUNT=0
    ACTIVE_FILE="$ACTIVE_FILE" \
    CHUMP_ORGAN_MANIFEST="$MANIFEST" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S=3600 \
        check_organ_roll_call_live
}

echo "chump-happy.timer" >> "$ACTIVE_FILE"
echo "chump-cj-worker.service" >> "$ACTIVE_FILE"
rm -f "$BACKOFF_DIR"/*.json 2>/dev/null || true
printf '{"unit":"chump-backoff-cooling.timer","since":%d,"reason":"enable_failed"}\n' \
    "$(date +%s)" > "$BACKOFF_DIR/chump-backoff-cooling.timer.json"
printf '{"unit":"chump-backoff-expired.timer","since":%d,"reason":"verify_failed"}\n' \
    "$(( $(date +%s) - 7200 ))" > "$BACKOFF_DIR/chump-backoff-expired.timer.json"

run_check

# Manifest order: not-applicable, happy, unowned-dead, backoff-cooling,
# backoff-expired, cj-worker (file: present), cj-file-missing (file: absent)
[[ "${#CHECKS[@]}" -eq 7 ]] || fail "expected 7 organ checks registered, got ${#CHECKS[@]} (${CHECKS[*]})"

# ── 1. not-applicable (unmet requires=) → skip ──────────────────────────────
if [[ "${STATUSES[0]}" == "skip" && "${DETAILS[0]}" == *"not applicable"* ]]; then
    pass "unmet requires= → skip, not RED"
else
    fail "expected skip/'not applicable' for chump-not-applicable.timer, got status=${STATUSES[0]} detail=${DETAILS[0]}"
fi

# ── 2. active → pass ─────────────────────────────────────────────────────────
if [[ "${STATUSES[1]}" == "pass" ]]; then
    pass "active organ → pass"
else
    fail "expected pass for chump-happy.timer, got status=${STATUSES[1]} detail=${DETAILS[1]}"
fi

# ── 3. dead, no backoff record → fail, 'dead and unowned' ───────────────────
if [[ "${STATUSES[2]}" == "fail" && "${DETAILS[2]}" == *"dead and unowned"* ]]; then
    pass "inactive + no backoff record → fail, 'dead and unowned'"
else
    fail "expected fail/'dead and unowned' for chump-unowned-dead.timer, got status=${STATUSES[2]} detail=${DETAILS[2]}"
fi

# ── 4. dead, fresh backoff record → fail, 'IN BACKOFF COOLDOWN' ─────────────
if [[ "${STATUSES[3]}" == "fail" && "${DETAILS[3]}" == *"IN BACKOFF COOLDOWN"* ]]; then
    pass "inactive + fresh backoff → fail, distinguished as 'IN BACKOFF COOLDOWN'"
else
    fail "expected fail/'IN BACKOFF COOLDOWN' for chump-backoff-cooling.timer, got status=${STATUSES[3]} detail=${DETAILS[3]}"
fi

# ── 5. dead, expired backoff record → fail, 'dead and unowned' (same as #3) ─
if [[ "${STATUSES[4]}" == "fail" && "${DETAILS[4]}" == *"dead and unowned"* ]]; then
    pass "inactive + expired backoff → fail, 'dead and unowned' (cooldown elapsed, no longer distinguished)"
else
    fail "expected fail/'dead and unowned' for chump-backoff-expired.timer, got status=${STATUSES[4]} detail=${DETAILS[4]}"
fi

# ── 6. file: requires= met (asset exists) + active → pass (RESILIENT-1436) ──
if [[ "${STATUSES[5]}" == "pass" ]]; then
    pass "requires=file:<existing-asset> → applicable and checked, active → pass"
else
    fail "expected pass for chump-cj-worker.service (file: asset exists), got status=${STATUSES[5]} detail=${DETAILS[5]}"
fi

# ── 7. file: requires= unmet (asset absent) → skip, not unknown-spec fail ──
if [[ "${STATUSES[6]}" == "skip" && "${DETAILS[6]}" == *"missing_file"* ]]; then
    pass "requires=file:<absent-asset> → skip/'missing_file', not RED and not 'unknown_requires_spec'"
else
    fail "expected skip/'missing_file' for chump-cj-file-missing.service, got status=${STATUSES[6]} detail=${DETAILS[6]}"
fi

echo "ALL PASS"
