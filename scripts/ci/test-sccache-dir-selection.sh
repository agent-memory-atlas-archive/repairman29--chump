#!/usr/bin/env bash
# scripts/ci/test-sccache-dir-selection.sh — INFRA-7113
#
# Unit tests for detect_sccache_dir() in scripts/setup/install-sccache.sh
# (INFRA-3661: SCCACHE_DIR defaults to $HOME when /home has >=25G free,
# else falls back to a writable mounted USB/data disk). Sources the
# install script (its BASH_SOURCE guard skips the install/write/verify
# side effects) and drives detect_sccache_dir() against a faked $HOME and
# a stubbed `df` on PATH, so no real disk layout is required.
#
#   1. SCCACHE_DIR already set in env — returned verbatim (explicit override wins)
#   2. /home free >= 25G — returns $HOME/.cache/sccache (the default location, AC3)
#   3. /home free  < 25G — falls back to the writable mount with the most free space (AC2)
#   4. /home free  < 25G, no mounted candidates — last-resort fallback to $HOME (AC2/AC3 edge)
#   5. AC4 — SCCACHE_DIR is exported for subsequent commands (structural check)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-sccache.sh"

pass() { printf '\033[0;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m  %s\n' "$*"; exit 1; }
info() { printf '\033[0;36m→\033[0m    %s\n' "$*"; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install script not found: $INSTALL_SCRIPT"

TMPDIR_BASE=$(mktemp -d /tmp/test-sccache-dir-XXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_BIN_DIR="$TMPDIR_BASE/bin"
mkdir -p "$FAKE_BIN_DIR"
cat > "$FAKE_BIN_DIR/df" <<'FAKEDF'
#!/usr/bin/env bash
# Stub df for test-sccache-dir-selection.sh — output driven by env vars so
# the test doesn't depend on the real machine's mount layout.
args="$*"
case "$args" in
  *"-Pk /home"*)
    echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
    echo "devhome        100000000  1000000 ${FAKE_HOME_AVAIL_KB:-99999999} 1% /home"
    ;;
  "-P /")
    echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
    echo "${FAKE_ROOT_FS:-/dev/root} 100000000 1000000 99999999 1% /"
    ;;
  *"-PkT"*)
    echo "Filesystem     Type 1024-blocks      Used Available Capacity Mounted on"
    if [[ -n "${FAKE_MNT_ROWS:-}" ]]; then
      while IFS='|' read -r fs fstype avail mnt; do
        [[ -z "$fs" ]] && continue
        echo "$fs $fstype 100000000 1000000 $avail 1% $mnt"
      done <<< "$FAKE_MNT_ROWS"
    fi
    ;;
  *)
    command df "$@"
    ;;
esac
FAKEDF
chmod +x "$FAKE_BIN_DIR/df"
export PATH="$FAKE_BIN_DIR:$PATH"

# Source the install script for its function defs only — the BASH_SOURCE
# guard inside it skips the install/write/verify body when sourced.
# shellcheck source=/dev/null
source "$INSTALL_SCRIPT"

# ── Test 1: explicit SCCACHE_DIR override wins, no free-space check ───────
FAKE_TMP_HOME="$TMPDIR_BASE/home1"
mkdir -p "$FAKE_TMP_HOME"
result="$(HOME="$FAKE_TMP_HOME" SCCACHE_DIR="/explicit/override" FAKE_HOME_AVAIL_KB=1 detect_sccache_dir)"
[[ "$result" == "/explicit/override" ]] || fail "test 1: expected explicit override, got '$result'"
pass "explicit SCCACHE_DIR env override is respected"

# ── Test 2: /home free >= 25G -> default $HOME/.cache/sccache (AC1, AC3) ──
FAKE_TMP_HOME="$TMPDIR_BASE/home2"
mkdir -p "$FAKE_TMP_HOME"
unset SCCACHE_DIR
result="$(HOME="$FAKE_TMP_HOME" FAKE_HOME_AVAIL_KB=$((30 * 1024 * 1024)) detect_sccache_dir)"
[[ "$result" == "$FAKE_TMP_HOME/.cache/sccache" ]] || fail "test 2: expected default \$HOME location, got '$result'"
pass "free space >= 25G uses the default \$HOME/.cache/sccache location"

# ── Test 3: /home free < 25G -> USB/mounted fallback, most-free writable (AC2) ──
FAKE_TMP_HOME="$TMPDIR_BASE/home3"
mkdir -p "$FAKE_TMP_HOME"
USB_A="$TMPDIR_BASE/mnt-usb-a"
USB_B="$TMPDIR_BASE/mnt-usb-b"
mkdir -p "$USB_A" "$USB_B"
result="$(HOME="$FAKE_TMP_HOME" \
  FAKE_HOME_AVAIL_KB=$((10 * 1024 * 1024)) \
  FAKE_ROOT_FS="/dev/root" \
  FAKE_MNT_ROWS=$'/dev/root|ext4|5000000|/'$'\n'"usba|ext4|8000000|$USB_A"$'\n'"usbb|ext4|20000000|$USB_B" \
  detect_sccache_dir)"
[[ "$result" == "$USB_B/sccache" ]] || fail "test 3: expected most-free USB mount '$USB_B/sccache', got '$result'"
pass "free space < 25G falls back to the mounted disk with the most free space"

# ── Test 4: /home free < 25G, no mount candidates -> last-resort \$HOME ────
FAKE_TMP_HOME="$TMPDIR_BASE/home4"
mkdir -p "$FAKE_TMP_HOME"
result="$(HOME="$FAKE_TMP_HOME" \
  FAKE_HOME_AVAIL_KB=$((10 * 1024 * 1024)) \
  FAKE_ROOT_FS="/dev/root" \
  FAKE_MNT_ROWS="" \
  detect_sccache_dir)"
[[ "$result" == "$FAKE_TMP_HOME/.cache/sccache" ]] || fail "test 4: expected last-resort \$HOME fallback, got '$result'"
pass "no mounted candidates falls back to \$HOME/.cache/sccache as last resort"

# ── Test 5: AC4 — chosen dir is exported for subsequent commands ──────────
grep -q 'export SCCACHE_DIR="\$SCCACHE_DIR_RESOLVED"' "$INSTALL_SCRIPT" \
  || fail "test 5: install script does not export SCCACHE_DIR"
grep -q 'SCCACHE_DIR = "\$SCCACHE_DIR_RESOLVED"' "$INSTALL_SCRIPT" \
  || fail "test 5: install script does not write SCCACHE_DIR into .cargo/config.toml [env]"
pass "chosen SCCACHE_DIR is exported + persisted in .cargo/config.toml for subsequent commands"

info "all detect_sccache_dir tests passed"
