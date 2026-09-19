#!/usr/bin/env bash
# test-refresh-runner-binary-almanac.sh — INFRA-7581 (INFRA-3639 slice)
#
# Proves `scripts/setup/refresh-runner-binary.sh --almanac`'s SHA-idempotent
# build logic (INFRA-3716):
#   1. installed binary present + SHA matches almanac origin/main HEAD ->
#      true no-op (install-almanac-organ.sh is NOT invoked, exit 0,
#      almanac_binary_healthy emitted)
#   2. binary missing -> install-almanac-organ.sh IS invoked to rebuild
#      (almanac_binary_refreshed emitted, new binary in place)
#   3. binary present but SHA mismatches origin/main -> install-almanac-organ.sh
#      IS invoked to rebuild
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d -t refresh-runner-binary-almanac-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO_ROOT="$TMP/chump-repo"
mkdir -p "$REPO_ROOT/.chump-locks"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

# --- fake sibling almanac repo (origin + clone) ----------------------------
ALMANAC_ORIGIN="$TMP/almanac-origin.git"
ALMANAC_REPO="$TMP/almanac"
git init --quiet --bare "$ALMANAC_ORIGIN"
git init --quiet "$ALMANAC_REPO"
git -C "$ALMANAC_REPO" config user.email "test@example.com"
git -C "$ALMANAC_REPO" config user.name "Test"
echo "v1" > "$ALMANAC_REPO/src.rs"
git -C "$ALMANAC_REPO" add src.rs
git -C "$ALMANAC_REPO" commit --quiet -m "v1"
git -C "$ALMANAC_REPO" branch -M main
git -C "$ALMANAC_REPO" remote add origin "$ALMANAC_ORIGIN"
git -C "$ALMANAC_REPO" push --quiet origin main
MAIN_SHA="$(git -C "$ALMANAC_REPO" rev-parse --short=12 origin/main)"

ALMANAC_BIN="$TMP/bin/almanac"
mkdir -p "$(dirname "$ALMANAC_BIN")"

# fake install-almanac-organ.sh lives where the script under test expects it:
# $ALMANAC_REPO/scripts/install-almanac-organ.sh
INSTALL_LOG="$TMP/install-calls.log"
mkdir -p "$ALMANAC_REPO/scripts"
cat > "$ALMANAC_REPO/scripts/install-almanac-organ.sh" <<EOF
#!/bin/sh
echo ran >> "$INSTALL_LOG"
printf '#!/bin/sh\necho "almanac 0.1.0 ($MAIN_SHA built test)"\n' > "$ALMANAC_BIN"
chmod +x "$ALMANAC_BIN"
EOF
chmod +x "$ALMANAC_REPO/scripts/install-almanac-organ.sh"

write_fake_binary() {  # write_fake_binary <path> <version-sha>
    cat > "$1" <<EOF
#!/bin/sh
echo "almanac 0.1.0 ($2 built test)"
EOF
    chmod +x "$1"
}

run_refresh() {
    CHUMP_REPO_ROOT="$REPO_ROOT" \
    ALMANAC_REPO="$ALMANAC_REPO" \
    ALMANAC_BIN="$ALMANAC_BIN" \
    ALMANAC_KNOWN_GOOD_HASH_FILE="$TMP/known-good.sha256" \
    ALMANAC_MARKER="$TMP/last-indexed-commit" \
        bash scripts/setup/refresh-runner-binary.sh --almanac
}

# --- Case 1: healthy binary + matching SHA -> true no-op -------------------
write_fake_binary "$ALMANAC_BIN" "$MAIN_SHA"
run_refresh
[ -f "$INSTALL_LOG" ] && { echo "FAIL: case1 must not invoke install-almanac-organ.sh on a healthy binary"; exit 1; }
grep -q "\"kind\":\"almanac_binary_healthy\"" "$AMBIENT" || { echo "FAIL: case1 missing almanac_binary_healthy emission"; exit 1; }
echo "OK case1: healthy binary + matching SHA is a true no-op"

# --- Case 2: binary missing -> rebuild via install-almanac-organ.sh -------
rm -f "$ALMANAC_BIN"
run_refresh
[ -f "$INSTALL_LOG" ] || { echo "FAIL: case2 install-almanac-organ.sh was not invoked for a missing binary"; exit 1; }
[ -x "$ALMANAC_BIN" ] || { echo "FAIL: case2 binary was not installed"; exit 1; }
grep -q "\"kind\":\"almanac_binary_refreshed\"" "$AMBIENT" || { echo "FAIL: case2 missing almanac_binary_refreshed emission"; exit 1; }
echo "OK case2: missing binary triggers rebuild via install-almanac-organ.sh"

# --- Case 3: binary present but SHA mismatches -> rebuild ------------------
: > "$INSTALL_LOG"
write_fake_binary "$ALMANAC_BIN" "deadbeef0000"
run_refresh
[ -f "$INSTALL_LOG" ] || { echo "FAIL: case3 install-almanac-organ.sh was not invoked for a SHA mismatch"; exit 1; }
CALLS3=$(wc -l < "$INSTALL_LOG")
[ "$CALLS3" -eq 1 ] || { echo "FAIL: case3 expected exactly 1 rebuild call, got $CALLS3"; exit 1; }
OUT="$("$ALMANAC_BIN" --version)"
echo "$OUT" | grep -q "$MAIN_SHA" || { echo "FAIL: case3 reinstalled binary does not match main SHA: $OUT"; exit 1; }
echo "OK case3: SHA mismatch triggers rebuild via install-almanac-organ.sh"

echo "OK: refresh-runner-binary.sh --almanac is SHA-idempotent (no-op when healthy, rebuilds via install-almanac-organ.sh when missing/mismatched)"
