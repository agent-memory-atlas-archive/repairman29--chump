#!/usr/bin/env bash
# test-disk-pressure-guard.sh — RESILIENT-1444
#
# Unit test for the percentage-based disk-pressure guard added to
# scripts/lib/disk-check.sh (chump_disk_pressure_check /
# chump_disk_used_pct) and wired into chump_disk_check_pause_worker.
#
# Verifies:
#   1. chump_disk_used_pct parses df's Use% column correctly.
#   2. chump_disk_pressure_check returns 1 + emits kind=disk_pressure_pause
#      when a path is at/above CHUMP_DISK_PRESSURE_PCT (default 90).
#   3. chump_disk_pressure_check returns 0 + emits nothing when below threshold.
#   4. CHUMP_DISK_CHECK_DISABLE=1 short-circuits the guard.
#   5. chump_disk_check_pause_worker (the worker.sh entry point) also fails
#      on percentage pressure even when the absolute-GB threshold passes —
#      the "large disk, still 95% full" case this gap exists to catch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/disk-check.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

FAKE_BIN="$TMP/fakebin"
mkdir -p "$FAKE_BIN"

make_fake_df() {
    local used_pct="$1"
    cat > "$FAKE_BIN/df" <<EOF
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/fake      500G  400G  100G  ${used_pct}% /fake"
EOF
    chmod +x "$FAKE_BIN/df"
}

AMBIENT="$TMP/ambient.jsonl"

# ── Test 1: chump_disk_used_pct parses Use% ───────────────────────────────
make_fake_df 87
(
    PATH="$FAKE_BIN:$PATH"
    # shellcheck disable=SC1090
    source "$LIB"
    got="$(chump_disk_used_pct /fake)"
    [[ "$got" == "87" ]] || { echo "got=$got"; exit 1; }
) || fail "chump_disk_used_pct did not parse 87% from fake df"
ok "chump_disk_used_pct parses df Use% column"

# ── Test 2: breach (95% used, threshold 90) → return 1 + emit event ──────
make_fake_df 95
rm -f "$AMBIENT"
exit_code=0
(
    PATH="$FAKE_BIN:$PATH"
    REPO_ROOT="$TMP"
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_DISK_PRESSURE_PATHS="/fake"
    CHUMP_DISK_PRESSURE_PCT="90"
    export REPO_ROOT CHUMP_AMBIENT_LOG CHUMP_DISK_PRESSURE_PATHS CHUMP_DISK_PRESSURE_PCT
    # shellcheck disable=SC1090
    source "$LIB"
    chump_disk_pressure_check
) 2>/dev/null || exit_code=$?
[[ "$exit_code" -eq 1 ]] || fail "chump_disk_pressure_check should return 1 at 95% used (threshold 90); got $exit_code"
grep -q '"kind":"disk_pressure_pause"' "$AMBIENT" \
    || fail "expected kind=disk_pressure_pause in ambient.jsonl: $(cat "$AMBIENT" 2>/dev/null || echo MISSING)"
grep -q '"used_pct":95' "$AMBIENT" \
    || fail "expected used_pct:95 in ambient.jsonl: $(cat "$AMBIENT")"
ok "chump_disk_pressure_check breaches at 95%>=90% threshold and emits disk_pressure_pause"

# ── Test 3: healthy (60% used, threshold 90) → return 0, no event ────────
make_fake_df 60
rm -f "$AMBIENT"
exit_code=0
(
    PATH="$FAKE_BIN:$PATH"
    REPO_ROOT="$TMP"
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_DISK_PRESSURE_PATHS="/fake"
    CHUMP_DISK_PRESSURE_PCT="90"
    export REPO_ROOT CHUMP_AMBIENT_LOG CHUMP_DISK_PRESSURE_PATHS CHUMP_DISK_PRESSURE_PCT
    # shellcheck disable=SC1090
    source "$LIB"
    chump_disk_pressure_check
) 2>/dev/null || exit_code=$?
[[ "$exit_code" -eq 0 ]] || fail "chump_disk_pressure_check should return 0 at 60% used (threshold 90); got $exit_code"
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"disk_pressure_pause"' "$AMBIENT"; then
    fail "unexpected disk_pressure_pause emitted at healthy 60%: $(cat "$AMBIENT")"
fi
ok "chump_disk_pressure_check passes at 60% used, no event emitted"

# ── Test 4: CHUMP_DISK_CHECK_DISABLE=1 short-circuits ─────────────────────
make_fake_df 99
rm -f "$AMBIENT"
exit_code=0
(
    PATH="$FAKE_BIN:$PATH"
    REPO_ROOT="$TMP"
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_DISK_PRESSURE_PATHS="/fake"
    CHUMP_DISK_CHECK_DISABLE="1"
    export REPO_ROOT CHUMP_AMBIENT_LOG CHUMP_DISK_PRESSURE_PATHS CHUMP_DISK_CHECK_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    chump_disk_pressure_check
) 2>/dev/null || exit_code=$?
[[ "$exit_code" -eq 0 ]] || fail "CHUMP_DISK_CHECK_DISABLE=1 should bypass the guard even at 99% used"
ok "CHUMP_DISK_CHECK_DISABLE=1 short-circuits chump_disk_pressure_check"

# ── Test 5: chump_disk_check_pause_worker fails on pct even with GB pass ──
# Fake df reports 95% used but a huge Avail column in real KB units
# (100 GB free = 104857600 KB), so the absolute-GB threshold
# (CHUMP_DISK_CRITICAL_GB, default 1) passes — only the percentage guard
# should catch this. chump_disk_free_gb reads column 4 as raw KB (df -k
# semantics), so unlike the human-readable fixtures above this one must use
# real KB integers.
cat > "$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem     1024-blocks     Used    Avail Use% Mounted on"
echo "/dev/fake      524288000 419430400 104857600  95% /fake"
EOF
chmod +x "$FAKE_BIN/df"
rm -f "$AMBIENT"
exit_code=0
(
    PATH="$FAKE_BIN:$PATH"
    REPO_ROOT="$TMP"
    CHUMP_AMBIENT_LOG="$AMBIENT"
    CHUMP_DISK_CHECK_PATH="/fake"
    CHUMP_DISK_PRESSURE_PATHS="/fake"
    CHUMP_DISK_PRESSURE_PCT="90"
    CHUMP_DISK_CRITICAL_GB="1"
    export REPO_ROOT CHUMP_AMBIENT_LOG CHUMP_DISK_CHECK_PATH CHUMP_DISK_PRESSURE_PATHS CHUMP_DISK_PRESSURE_PCT CHUMP_DISK_CRITICAL_GB
    # shellcheck disable=SC1090
    source "$LIB"
    chump_disk_check_pause_worker
) 2>/dev/null || exit_code=$?
[[ "$exit_code" -eq 1 ]] || fail "chump_disk_check_pause_worker should pause on 95% used even though 100G free clears the GB floor; got $exit_code"
grep -q '"kind":"disk_pressure_pause"' "$AMBIENT" \
    || fail "chump_disk_check_pause_worker did not emit disk_pressure_pause: $(cat "$AMBIENT" 2>/dev/null || echo MISSING)"
ok "chump_disk_check_pause_worker pauses on percentage pressure even when GB-free threshold passes"

printf '\n\033[0;32mall tests passed\033[0m\n'
