#!/usr/bin/env bash
# scripts/ci/test-svc-abstraction.sh — INFRA-7330 (INFRA-7093 / INFRA-3649 slice)
#
# Proves svc_is_alive / svc_revive select the right supervisor mechanism:
#   - systemd mechanism when a chump-<name>.service unit is registered
#     (reset-failed + restart on revive, is-active on liveness check)
#   - process mechanism (pgrep / setsid-nohup) as fallback when no unit
#     is registered for the organ name.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIB="$REPO_ROOT/scripts/ops/svc-abstraction.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-svc-abstraction.sh (INFRA-7330) ==="

[[ -f "$LIB" ]] || fail "svc-abstraction.sh missing: $LIB"
bash -n "$LIB" || fail "svc-abstraction.sh bash -n failed"
pass "script present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate ambient-log + backoff-registry writes to $TMP for the WHOLE file —
# svc_revive (INFRA-3649 AC2/AC4) always emits + always touches the backoff
# registry, so every section below must stay off the real repo's
# .chump-locks/{ambient.jsonl,organ-backoff}/ or repeated test runs pollute
# shared local state with svc-<organ>.json backoff files that never expire.
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/organ-backoff"

# ── 1. Process mechanism: svc_is_alive false, svc_revive launches organ ────
export CHUMP_SVC_ORGANS_DIR="$TMP/organs"
export CHUMP_SVC_LOGS_DIR="$TMP/logs"
mkdir -p "$CHUMP_SVC_ORGANS_DIR"

# No systemctl on PATH for this stub -> forces process mechanism via auto-detect.
export CHUMP_SVC_SYSTEMCTL_BIN="$TMP/no-such-systemctl-binary"

cat > "$CHUMP_SVC_ORGANS_DIR/test-organ.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$CHUMP_SVC_ORGANS_DIR/test-organ.sh"

# shellcheck source=/dev/null
source "$LIB"

if svc_is_alive test-organ; then
    fail "svc_is_alive should be false before revive"
fi
pass "process mechanism: svc_is_alive correctly false pre-revive"

svc_revive test-organ >/dev/null 2>&1 || fail "svc_revive (process) failed"
sleep 0.3
if ! svc_is_alive test-organ; then
    fail "svc_is_alive should be true after process revive"
fi
pass "process mechanism: svc_is_alive true post-revive"

pkill -f "organs/test-organ.sh" >/dev/null 2>&1 || true

# ── 2. svc_revive (process) errors cleanly on missing organ script ─────────
if svc_revive definitely-not-a-real-organ >/dev/null 2>&1; then
    fail "svc_revive should fail for a nonexistent organ script"
fi
pass "process mechanism: svc_revive fails cleanly when organ script absent"

# ── 3. Systemd mechanism: stub systemctl reports a registered unit ─────────
STUB="$TMP/systemctl-stub"
CALL_LOG="$TMP/calls.log"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG"
args=("\$@")
if [[ "\${args[0]}" == "--user" ]]; then
    exit 1
fi
case "\${args[0]}" in
    list-unit-files)
        if [[ "\${args[1]}" == "chump-heal-me.service" ]]; then
            echo "chump-heal-me.service enabled"
            exit 0
        fi
        exit 0
        ;;
    is-active)
        echo "active"
        exit 0
        ;;
    reset-failed)
        exit 0
        ;;
    restart)
        exit 0
        ;;
esac
exit 1
EOF
chmod +x "$STUB"
export CHUMP_SVC_SYSTEMCTL_BIN="$STUB"
: > "$CALL_LOG"

if ! svc_is_alive heal-me; then
    fail "svc_is_alive (systemd) should report alive for stubbed active unit"
fi
grep -q "is-active chump-heal-me.service" "$CALL_LOG" || fail "expected is-active call not logged"
pass "systemd mechanism: svc_is_alive routes through systemctl is-active"

: > "$CALL_LOG"
svc_revive heal-me >/dev/null 2>&1 || fail "svc_revive (systemd) failed"
grep -q "reset-failed chump-heal-me.service" "$CALL_LOG" || fail "expected reset-failed call not logged"
grep -q "restart chump-heal-me.service" "$CALL_LOG" || fail "expected restart call not logged"
pass "systemd mechanism: svc_revive calls reset-failed then restart"

# ── 4. Unregistered unit name falls back to process mechanism ──────────────
if svc_is_alive test-organ; then
    : # organ from step 1 was killed; either state is fine here
fi
export CHUMP_SVC_FORCE_MECHANISM=""
: > "$CALL_LOG"
svc_is_alive no-such-organ-anywhere >/dev/null 2>&1
grep -q "list-unit-files" "$CALL_LOG" || fail "expected mechanism auto-detect to probe list-unit-files"
! grep -q "^is-active" "$CALL_LOG" || fail "should not call is-active for an unregistered unit"
pass "auto-detect: falls back to process mechanism when no unit is registered"

# ── 5. CHUMP_SVC_FORCE_MECHANISM override ───────────────────────────────────
export CHUMP_SVC_FORCE_MECHANISM="systemd"
: > "$CALL_LOG"
svc_is_alive heal-me >/dev/null 2>&1
grep -q "is-active chump-heal-me.service" "$CALL_LOG" || fail "forced systemd mechanism should call is-active"
pass "CHUMP_SVC_FORCE_MECHANISM=systemd forces the systemd path"
export CHUMP_SVC_FORCE_MECHANISM=""

# ── 6. INFRA-3649 AC2: successful revive emits kind=organ_self_healed ──────
AMBIENT_TEST="$TMP/ambient.jsonl"
BACKOFF_TEST="$TMP/organ-backoff"
export CHUMP_AMBIENT_LOG="$AMBIENT_TEST"
export CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_TEST"
export CHUMP_SVC_NODE="test-node-1"
export CHUMP_SVC_FORCE_MECHANISM="systemd"
: > "$AMBIENT_TEST"
svc_revive heal-me >/dev/null 2>&1
grep -q '"kind":"organ_self_healed"' "$AMBIENT_TEST" || fail "svc_revive (systemd) should emit kind=organ_self_healed"
grep -q '"organ":"heal-me"' "$AMBIENT_TEST" || fail "organ_self_healed missing organ field"
grep -q '"node":"test-node-1"' "$AMBIENT_TEST" || fail "organ_self_healed missing node field"
grep -q '"mechanism":"systemd"' "$AMBIENT_TEST" || fail "organ_self_healed should report mechanism=systemd"
pass "svc_revive (systemd) emits kind=organ_self_healed with organ/node/mechanism"

export CHUMP_SVC_FORCE_MECHANISM="process"
: > "$AMBIENT_TEST"
svc_revive test-organ >/dev/null 2>&1
grep -q '"kind":"organ_self_healed"' "$AMBIENT_TEST" || fail "svc_revive (process) should emit kind=organ_self_healed"
grep -q '"mechanism":"process"' "$AMBIENT_TEST" || fail "organ_self_healed should report mechanism=process"
pass "svc_revive (process) emits kind=organ_self_healed with mechanism=process"
pkill -f "organs/test-organ.sh" >/dev/null 2>&1 || true

# ── 7. INFRA-3649 AC4: adversarial repeated-death backoff ──────────────────
rm -rf "$BACKOFF_TEST"
export CHUMP_SVC_RAPID_DEATH_S=3600
export CHUMP_SVC_BACKOFF_COOLDOWN_S=3600
export CHUMP_SVC_FORCE_MECHANISM="process"
: > "$AMBIENT_TEST"
svc_revive test-organ >/dev/null 2>&1   # 1st attempt — establishes last-revive marker
pkill -f "organs/test-organ.sh" >/dev/null 2>&1 || true
: > "$AMBIENT_TEST"
svc_revive test-organ >/dev/null 2>&1   # dies again "immediately" (within RAPID_DEATH_S) — arms backoff
grep -q '"kind":"organ_self_heal_backoff"' "$AMBIENT_TEST" || fail "2nd rapid-repeat revive should emit organ_self_heal_backoff"
grep -q '"kind":"organ_self_healed"' "$AMBIENT_TEST" || fail "2nd rapid-repeat revive should still attempt (and succeed) this once"
pass "rapid repeated death (2nd revive within RAPID_DEATH_S) arms backoff but still attempts once more"

pkill -f "organs/test-organ.sh" >/dev/null 2>&1 || true
: > "$AMBIENT_TEST"
if svc_revive test-organ >/dev/null 2>&1; then
    fail "3rd revive should be SKIPPED while backoff is active (rc should be non-zero)"
fi
grep -q '"kind":"organ_self_heal_backoff_skip"' "$AMBIENT_TEST" || fail "3rd revive should emit organ_self_heal_backoff_skip"
! grep -q '"kind":"organ_self_healed"' "$AMBIENT_TEST" || fail "3rd revive should NOT actually respawn while backed off"
pass "backoff guard: subsequent revive is skipped (not respawn-looped) while cooling down"
pkill -f "organs/test-organ.sh" >/dev/null 2>&1 || true

unset CHUMP_SVC_RAPID_DEATH_S CHUMP_SVC_BACKOFF_COOLDOWN_S CHUMP_SVC_FORCE_MECHANISM CHUMP_SVC_NODE

echo "=== all svc-abstraction tests passed ==="
