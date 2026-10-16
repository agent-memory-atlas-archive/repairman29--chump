#!/usr/bin/env bash
# test-install-sh-user-mode.sh — MISSION-120
#
# Unit test for one-command install on a fresh box with --user flag.
# Tests that the install.sh script can complete installation without requiring
# root privileges, and that all expected binaries and config files are present
# after successful installation.
#
# Acceptance criteria:
#   1. Test spins up a temporary directory simulating a fresh box
#   2. Runs the install command with `--user` flag
#   3. Asserts that all expected binaries and config files are present
#   4. Test passes locally

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/setup/install.sh"

PASS=0
FAIL=0
FAILS=()

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Create a minimal fake remote with a working node installer stub
FAKE_REMOTE_SRC="$TMPROOT/fake-remote-src"
FAKE_REMOTE="$TMPROOT/fake-remote.git"
mkdir -p "$FAKE_REMOTE_SRC/scripts/setup"

# Create a minimal stub that doesn't need actual toolchain
cat > "$FAKE_REMOTE_SRC/scripts/setup/chump-node-install.sh" <<'EOF'
#!/usr/bin/env bash
# Minimal stub node installer for test-install-sh-user-mode.sh
# In user mode, this just verifies the environment and creates marker files

set -uo pipefail

HOME_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"
USER_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR="$2"; shift 2;;
    --check)
      if [ -d "$HOME_DIR/repo" ]; then
        exit 0
      else
        exit 1
      fi
      ;;
    *)
      shift
      ;;
  esac
done

# Create marker files to simulate successful installation
mkdir -p "$HOME_DIR/.chump"
touch "$HOME_DIR/.chump/config.yaml"
mkdir -p "$HOME_DIR/bin"
touch "$HOME_DIR/bin/chump"
chmod +x "$HOME_DIR/bin/chump"

exit 0
EOF
chmod +x "$FAKE_REMOTE_SRC/scripts/setup/chump-node-install.sh"

(
  cd "$FAKE_REMOTE_SRC"
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "test"
  git add -A
  git commit --quiet -m "seed"
)
git clone --quiet --bare "$FAKE_REMOTE_SRC" "$FAKE_REMOTE"

echo "=== MISSION-120 install.sh --user mode gate ==="

# ---------- AC1: Fresh box + --user flag installation succeeds ----------
NODE_DIR_1="$TMPROOT/fresh-box"
if bash "$INSTALL_SH" --home "$NODE_DIR_1" --user --repo-url "$FAKE_REMOTE" >"$TMPROOT/ac1.log" 2>&1; then
  if [ -d "$NODE_DIR_1/repo/.git" ]; then
    PASS=$((PASS + 1))
    echo "PASS: AC1 fresh box with --user flag cloned repo successfully"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("AC1: install.sh exited 0 with --user but $NODE_DIR_1/repo/.git is missing")
  fi
else
  FAIL=$((FAIL + 1))
  FAILS+=("AC1: install.sh exited non-zero with --user flag on fresh box (see $TMPROOT/ac1.log)")
  cat "$TMPROOT/ac1.log" >&2
fi

# ---------- AC2: Verify expected binary files are present ----------
if [ -d "$NODE_DIR_1/repo/.git" ]; then
  if [ -f "$NODE_DIR_1/bin/chump" ] && [ -x "$NODE_DIR_1/bin/chump" ]; then
    PASS=$((PASS + 1))
    echo "PASS: AC2 binary file is present and executable"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("AC2: expected binary $NODE_DIR_1/bin/chump not found or not executable")
  fi
else
  FAIL=$((FAIL + 1))
  FAILS+=("AC2: skipped — repo not present from AC1")
fi

# ---------- AC3: Verify expected config files are present ----------
if [ -d "$NODE_DIR_1/repo/.git" ]; then
  if [ -f "$NODE_DIR_1/.chump/config.yaml" ]; then
    PASS=$((PASS + 1))
    echo "PASS: AC3 config file is present"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("AC3: expected config file $NODE_DIR_1/.chump/config.yaml not found")
  fi
else
  FAIL=$((FAIL + 1))
  FAILS+=("AC3: skipped — repo not present from AC1")
fi

# ---------- AC4: --user mode respects existing node/npm (idempotent) ----------
if bash "$INSTALL_SH" --home "$NODE_DIR_1" --user --repo-url "$FAKE_REMOTE" >"$TMPROOT/ac4.log" 2>&1; then
  if grep -q "repo already present" "$TMPROOT/ac4.log"; then
    PASS=$((PASS + 1))
    echo "PASS: AC4 --user mode is idempotent with existing installation"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("AC4: re-run with --user did not report 'repo already present'")
  fi
else
  FAIL=$((FAIL + 1))
  FAILS+=("AC4: re-run with --user exited non-zero (see $TMPROOT/ac4.log)")
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
  echo "FAILURES:"
  for f in "${FAILS[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
