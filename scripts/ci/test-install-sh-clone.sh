#!/usr/bin/env bash
# test-install-sh-clone.sh — INFRA-7102
#
# Exercises the CLONE stage of scripts/setup/install.sh in isolation:
#   1. bare box (no repo at $NODE_DIR/repo) -> clone succeeds
#   2. re-run on a box where the repo already exists -> no re-clone, no error
#   3. bad --repo-url (network/permission failure) -> non-zero exit
#
# Uses a local bare git repo as the "remote" so this test has no network
# dependency and runs fast in CI.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/setup/install.sh"

PASS=0
FAIL=0
FAILS=()

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# A minimal local "remote": a bare repo with one commit, plus a stub
# chump-node-install.sh so the hand-off step succeeds without needing the
# real (large) node installer.
FAKE_REMOTE_SRC="$TMPROOT/fake-remote-src"
FAKE_REMOTE="$TMPROOT/fake-remote.git"
mkdir -p "$FAKE_REMOTE_SRC/scripts/setup"
cat > "$FAKE_REMOTE_SRC/scripts/setup/chump-node-install.sh" <<'EOF'
#!/usr/bin/env bash
# stub node installer for test-install-sh-clone.sh — always succeeds
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

echo "=== INFRA-7102 install.sh CLONE stage gate ==="

# ---------- AC1: bare box -> clone into predefined dir ----------
NODE_DIR_1="$TMPROOT/box1"
if bash "$INSTALL_SH" --home "$NODE_DIR_1" --repo-url "$FAKE_REMOTE" >"$TMPROOT/ac1.log" 2>&1; then
  if [ -d "$NODE_DIR_1/repo/.git" ]; then
    PASS=$((PASS + 1))
    echo "PASS: AC1 fresh clone landed at \$NODE_DIR/repo"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("AC1: install.sh exited 0 but $NODE_DIR_1/repo/.git is missing")
  fi
else
  FAIL=$((FAIL + 1))
  FAILS+=("AC1: install.sh exited non-zero on a clean bare-box clone (see $TMPROOT/ac1.log)")
fi

# ---------- AC2: idempotent re-run does not re-clone or error ----------
if [ -d "$NODE_DIR_1/repo/.git" ]; then
  before_head="$(git -C "$NODE_DIR_1/repo" rev-parse HEAD 2>/dev/null || echo MISSING)"
  if bash "$INSTALL_SH" --home "$NODE_DIR_1" --repo-url "$FAKE_REMOTE" >"$TMPROOT/ac2.log" 2>&1; then
    after_head="$(git -C "$NODE_DIR_1/repo" rev-parse HEAD 2>/dev/null || echo MISSING)"
    if grep -q "repo already present" "$TMPROOT/ac2.log" && [ "$before_head" = "$after_head" ]; then
      PASS=$((PASS + 1))
      echo "PASS: AC2 re-run is idempotent (no re-clone, no error)"
    else
      FAIL=$((FAIL + 1))
      FAILS+=("AC2: re-run did not report 'repo already present' or HEAD changed ($before_head -> $after_head)")
    fi
  else
    FAIL=$((FAIL + 1))
    FAILS+=("AC2: re-run on existing repo exited non-zero (see $TMPROOT/ac2.log)")
  fi
else
  FAIL=$((FAIL + 1))
  FAILS+=("AC2: skipped — AC1 setup left no repo to re-run against")
fi

# ---------- AC3: exit non-zero on clone failure (bad remote) ----------
NODE_DIR_3="$TMPROOT/box3"
BAD_REMOTE="$TMPROOT/does-not-exist.git"
if bash "$INSTALL_SH" --home "$NODE_DIR_3" --repo-url "$BAD_REMOTE" >"$TMPROOT/ac3.log" 2>&1; then
  FAIL=$((FAIL + 1))
  FAILS+=("AC3: install.sh exited 0 despite an unreachable/invalid --repo-url")
else
  PASS=$((PASS + 1))
  echo "PASS: AC3 unreachable repo-url yields non-zero exit"
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
