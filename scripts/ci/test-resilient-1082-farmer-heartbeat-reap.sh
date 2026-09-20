#!/usr/bin/env bash
# scripts/ci/test-resilient-1082-farmer-heartbeat-reap.sh — RESILIENT-1082
#
# Proves the fix for "brain->muscle role switch leaves a stale
# farmer-heartbeat that gates the worker RED forever": a muscle-scoped
# organ-reconcile.sh --apply that reaps the out-of-role chump-farmer.timer
# (brain-only organ) must also delete the LAST heartbeat file it left
# behind, so `chump farmer status`'s heartbeat_fresh check (vacuous-PASS
# only while the file is ABSENT, src/farmer_status.rs) goes back to GREEN
# immediately instead of staying pinned RED until a human runs `rm` by hand
# (VERIFIED on mugman 2026-09-08: 4 days dark, 1,900+ gaps unclaimed).
#
# Two-part regression guard:
#   (a) shell-level: the reap actually removes the repo-local heartbeat file
#       (drives the real reap_unit_and_sibling() via a stubbed systemctl).
#   (b) binary-level: `chump farmer status` against that same scratch repo
#       root, with a stale heartbeat present BEFORE the reap and absent
#       AFTER, flips RED -> GREEN — proving the fix closes the actual gate,
#       not just that a file happens to vanish.
#
# Both assertions FAIL without the RESILIENT-1082 change.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

[[ -f "$RECONCILE" ]] || { echo "FAIL: reconcile script missing: $RECONCILE"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-resilient-1082-farmer-heartbeat-reap.sh (RESILIENT-1082) ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1082-farmer-heartbeat-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Scratch "repo root" the reconcile + the chump binary both read .chump/ from.
SCRATCH_REPO="$TMP/scratch-repo"
mkdir -p "$SCRATCH_REPO/.chump"
HEARTBEAT_FILE="$SCRATCH_REPO/.chump/farmer-heartbeat"
DURABLE_HEARTBEAT="$TMP/home/.chump/farmer-heartbeat"
mkdir -p "$(dirname "$DURABLE_HEARTBEAT")"

# Simulate: farmer was alive on this host (brain role), then the host was
# switched to muscle — the timer stops getting installed but its last
# heartbeat write (>120s old, RESILIENT-069's HEARTBEAT_MAX_AGE_S) is left on
# disk in BOTH the repo-local and $HOME-durable locations (RESILIENT-313
# dual-write in scripts/coord/farmer.sh).
echo "2026-09-03T00:00:00Z" > "$HEARTBEAT_FILE"
touch -d "@$(( $(date +%s) - 365707 ))" "$HEARTBEAT_FILE" 2>/dev/null \
    || touch -A -240000 "$HEARTBEAT_FILE" 2>/dev/null || true
echo "2026-09-03T00:00:00Z" > "$DURABLE_HEARTBEAT"
touch -d "@$(( $(date +%s) - 365707 ))" "$DURABLE_HEARTBEAT" 2>/dev/null \
    || touch -A -240000 "$DURABLE_HEARTBEAT" 2>/dev/null || true

# ── (b, before) prove the scenario actually gates RED pre-fix-application ──
source "$SCRIPT_DIR/lib/discover-chump-bin.sh" 2>/dev/null || true
if [[ -x "${CHUMP_BIN:-}" ]]; then
    if HOME="$TMP/home" CHUMP_REPO="$SCRATCH_REPO" "$CHUMP_BIN" farmer status --quiet; then
        fail "sanity: farmer status should be RED before the reap (stale heartbeat present)"
    else
        pass "sanity: farmer status is RED before the reap (stale heartbeat present)"
    fi
else
    echo "  SKIP binary-level assertions: no chump binary found (set CHUMP_BIN)" >&2
fi

# ── (a) muscle-scoped --apply reaps chump-farmer AND clears the heartbeat ──
ACTIVE_FILE="$TMP/active.txt"; ENABLED_FILE="$TMP/enabled.txt"
UNITFILES_FILE="$TMP/unitfiles.txt"; CALL_LOG="$TMP/calls.log"
printf 'chump-farmer.service\nchump-farmer.timer\n' > "$UNITFILES_FILE"
printf 'chump-farmer.service\nchump-farmer.timer\n' > "$ACTIVE_FILE"
cp "$ACTIVE_FILE" "$ENABLED_FILE"

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    list-unit-files)
        case "$*" in
            *--type=timer*)   grep '\.timer$' "$UNITFILES_FILE" | awk '{print $1"  enabled"}';;
            *--type=service*) grep '\.service$' "$UNITFILES_FILE" | awk '{print $1"  enabled"}';;
            *)                cat "$UNITFILES_FILE" | awk '{print $1"  enabled"}';;
        esac
        exit 0 ;;
    is-active)  unit="${@: -1}"; grep -qxF "$unit" "$ACTIVE_FILE"  2>/dev/null && exit 0 || exit 3 ;;
    is-enabled) unit="${@: -1}"; grep -qxF "$unit" "$ENABLED_FILE" 2>/dev/null && exit 0 || exit 1 ;;
    is-failed)  echo "active"; exit 0 ;;
    disable)
        unit="${@: -1}"
        grep -vxF "$unit" "$ACTIVE_FILE"  > "$ACTIVE_FILE.t"  2>/dev/null; mv "$ACTIVE_FILE.t"  "$ACTIVE_FILE"
        grep -vxF "$unit" "$ENABLED_FILE" > "$ENABLED_FILE.t" 2>/dev/null; mv "$ENABLED_FILE.t" "$ENABLED_FILE"
        exit 0 ;;
    show) echo "ExecStart=/bin/true"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$STUB"

# Muscle manifest that does NOT declare chump-farmer (it is brain-only) —
# mirrors the real scripts/ops/organ-manifest.txt entry
# `enabled  chump-farmer.timer  role=brain requires=bin:chump`.
MANIFEST="$TMP/organ-manifest.txt"
printf 'enabled  chump-muscle-organ.service  role=muscle requires=\n' > "$MANIFEST"

: > "$CALL_LOG"
ACTIVE_FILE="$ACTIVE_FILE" ENABLED_FILE="$ENABLED_FILE" UNITFILES_FILE="$UNITFILES_FILE" CALL_LOG="$CALL_LOG" \
CHUMP_ORGAN_RECONCILE_ROLE="muscle" \
CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
CHUMP_ORGAN_RECONCILE_FARMER_HEARTBEAT="$HEARTBEAT_FILE" \
CHUMP_ORGAN_RECONCILE_FARMER_HEARTBEAT_DURABLE="$DURABLE_HEARTBEAT" \
CHUMP_ORGAN_MANIFEST="$MANIFEST" \
bash "$RECONCILE" --apply >"$TMP/reconcile.log" 2>&1

grep -q "disable --now chump-farmer.timer" "$CALL_LOG" \
    && pass "muscle-scoped --apply reaps the out-of-role chump-farmer.timer" \
    || fail "should disable chump-farmer.timer; calls: $(cat "$CALL_LOG")"

if [[ -f "$HEARTBEAT_FILE" ]]; then
    fail "repo-local farmer-heartbeat should be removed after the farmer organ is reaped: $HEARTBEAT_FILE still present"
else
    pass "repo-local farmer-heartbeat is removed when chump-farmer is reaped"
fi
if [[ -f "$DURABLE_HEARTBEAT" ]]; then
    fail "\$HOME-durable farmer-heartbeat should be removed after the farmer organ is reaped: $DURABLE_HEARTBEAT still present"
else
    pass "\$HOME-durable farmer-heartbeat is removed when chump-farmer is reaped"
fi

# ── (b, after) the worker readiness gate is GREEN again post-reap ─────────
if [[ -x "${CHUMP_BIN:-}" ]]; then
    if HOME="$TMP/home" CHUMP_REPO="$SCRATCH_REPO" "$CHUMP_BIN" farmer status --quiet; then
        pass "chump farmer status is GREEN after the role-switch cleanup (regression guard, AC3)"
    else
        fail "chump farmer status should be GREEN once the stale heartbeat is cleared by the reap"
    fi
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: farmer-heartbeat cleared on brain->muscle reap ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
