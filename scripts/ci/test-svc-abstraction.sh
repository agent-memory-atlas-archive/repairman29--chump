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

echo "=== all svc-abstraction tests passed ==="
