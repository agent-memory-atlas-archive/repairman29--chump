#!/usr/bin/env bash
# scripts/ci/test-infra-8190-gap-store-single-source-gate.sh — INFRA-8190
#
# Phase R R4 "one canonical store". Proves, against throwaway fixtures (two
# temp dirs: a git repo + its linked worktree, and a fake $HOME), that:
#
#   1. scripts/coord/lib/state-store.sh (the ONE shell resolver) implements
#      the precedence CHUMP_STATE_DB > main checkout (worktrees resolve to
#      their MAIN checkout) > explicit root, with the ~/.chump legacy fallback
#      labelled home-fallback.
#   2. scripts/coord/gap-store-single-source-check.sh --resolver-only is a
#      HARD gate: exit 0 when every process class resolves the same store,
#      exit 1 when a node.env pin, the current env, or the chump binary
#      disagrees with the pin-less (fleet-server / worker.sh) resolution —
#      i.e. the 2026-10-15 cuphead split (CLI ~/.chump 8264 gaps vs API +
#      workers <repo>/.chump 465 gaps).
#   3. Optional Rust/shell parity: when CHUMP_STORE_PATH_PARITY_BIN points at
#      a built `chump`, its `gap store-path` agrees with the shell resolver
#      for the repo, the worktree, a subdir and a non-git dir.
#
# Network-free, no sqlite3, no real state.db touched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/state-store.sh"
CHECK="$REPO_ROOT/scripts/coord/gap-store-single-source-check.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK missing"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }
eq(){ if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

echo "=== test-infra-8190-gap-store-single-source-gate.sh ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-8190-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# Hermetic env: no inherited pins, fake HOME.
unset CHUMP_STATE_DB CHUMP_REPO CHUMP_HOME CHUMP_STATE_DIR CHUMP_NODE_ENV_FILE
export HOME="$TMP/home"
mkdir -p "$HOME/.chump"

# ── fixture: main checkout + linked worktree ───────────────────────────────
MAIN="$TMP/repo"
WT="$TMP/wt"
mkdir -p "$MAIN"
g(){ git -C "$MAIN" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
g init -q -b main && : > "$MAIN/f" && g add f && g commit -q -m init && g worktree add -q "$WT" -b w \
  || { echo "FAIL: could not build git fixture"; exit 1; }
[ -f "$WT/.git" ] || { echo "FAIL: worktree .git is not a file"; exit 1; }
mkdir -p "$MAIN/crates/x" "$TMP/plain"
CANON="$MAIN/.chump/state.db"

# shellcheck source=../coord/lib/state-store.sh
. "$LIB"

echo "--- 1. shell resolver precedence"
eq "main checkout resolves repo-local"            "$(chump_state_db "$MAIN")"          "$CANON"
eq "main checkout source label"                   "$(chump_state_db_source "$MAIN")"   "main-checkout"
eq "subdir walks up to the checkout"              "$(chump_state_db "$MAIN/crates/x")" "$CANON"
eq "linked worktree resolves to MAIN's store"     "$(chump_state_db "$WT")"            "$CANON"
eq "linked worktree source label"                 "$(chump_state_db_source "$WT")"     "linked-worktree"
eq "explicit non-git root is honored"             "$(chump_state_db "$TMP/plain")"     "$TMP/plain/.chump/state.db"
eq "non-git root source label"                    "$(chump_state_db_source "$TMP/plain")" "no-checkout"
eq "\$HOME without a checkout is home-fallback"   "$(chump_state_db_source "$HOME")"   "home-fallback"
warn="$(chump_state_db "$HOME" 2>&1 >/dev/null)"
case "$warn" in *"falls back to"*INFRA-8190*) pass "home-fallback prints a one-line stderr warning";; *) fail "home-fallback warning missing (got '$warn')";; esac
eq "CHUMP_STATE_DB wins"                          "$(CHUMP_STATE_DB=/x/y.db chump_state_db "$WT")" "/x/y.db"
eq "CHUMP_STATE_DB ~ expands to \$HOME"           "$(CHUMP_STATE_DB='~/s.db' chump_state_db "$WT")" "$HOME/s.db"
eq "blank CHUMP_STATE_DB is treated as unset"     "$(CHUMP_STATE_DB='  ' chump_state_db "$WT")" "$CANON"
eq "CHUMP_STATE_DIR is NOT a store selector"      "$(CHUMP_STATE_DIR="$HOME/.chump" chump_state_db "$WT")" "$CANON"
eq "root defaults to CHUMP_REPO"                  "$(cd "$TMP/plain" && CHUMP_REPO="$WT" chump_state_db)" "$CANON"

# ── stub chump binaries ────────────────────────────────────────────────────
BIN_DIR="$TMP/bin"; mkdir -p "$BIN_DIR"
# A correct binary: `gap store-path` resolves exactly like the shell lib.
cat > "$BIN_DIR/chump-good" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "gap store-path" ] || exit 2
. "$LIB"
chump_state_db "\${CHUMP_REPO:-\$PWD}" 2>/dev/null
EOF
# A binary that resolves somewhere else (Rust/shell divergence).
cat > "$BIN_DIR/chump-divergent" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "gap store-path" ] || exit 2
echo "$HOME/.chump/state.db"
EOF
# A pre-INFRA-8190 binary without the subcommand.
cat > "$BIN_DIR/chump-old" <<'EOF'
#!/usr/bin/env bash
echo "chump gap: unknown subcommand '$2'" >&2
exit 2
EOF
chmod +x "$BIN_DIR"/chump-*

gate(){  # gate <bin> [extra env assignments...]
  local bin="$1"; shift
  env "$@" CHUMP_REPO_ROOT="$MAIN" CHUMP_BIN="$BIN_DIR/$bin" HOME="$HOME" \
    bash "$CHECK" --resolver-only 2>&1
}

echo "--- 2. single-source gate (hard)"
out="$(gate chump-good)"; rc=$?
eq "agreement with no node.env -> exit 0" "$rc" "0"
case "$out" in *"OK(C)"*) pass "gate reports OK(C)";; *) fail "gate output missing OK(C): $out";; esac

printf 'export CHUMP_STATE_DIR=%s\nexport CHUMP_STATE_DB=%s\n' "$HOME/.chump" "$CANON" > "$HOME/.chump/node.env"
out="$(gate chump-good)"; rc=$?
eq "node.env pinned to the repo-local store -> exit 0" "$rc" "0"
case "$out" in *"node.env("*"$CANON"*) pass "node.env resolution is compared";; *) fail "node.env resolution not listed: $out";; esac

# The cuphead split: node.env pins the legacy home store, organs do not.
printf 'export CHUMP_STATE_DIR=%s\nexport CHUMP_STATE_DB=%s\n' "$HOME/.chump" "$HOME/.chump/state.db" > "$HOME/.chump/node.env"
out="$(gate chump-good)"; rc=$?
eq "node.env pinned to ~/.chump (cuphead split) -> exit 1" "$rc" "1"
case "$out" in *"FAIL(C)"*"SPLIT-BRAIN"*) pass "gate names the split";; *) fail "gate output missing FAIL(C)/SPLIT-BRAIN: $out";; esac
rm -f "$HOME/.chump/node.env"

out="$(gate chump-good CHUMP_STATE_DB="$TMP/elsewhere.db")"; rc=$?
eq "current-env pin disagreeing with pin-less -> exit 1" "$rc" "1"

out="$(gate chump-divergent)"; rc=$?
eq "binary resolving a different store -> exit 1" "$rc" "1"

out="$(gate chump-old)"; rc=$?
eq "pre-INFRA-8190 binary (no store-path) -> still exit 0 on shell agreement" "$rc" "0"
case "$out" in *"WARN(C)"*) pass "old binary is called out with WARN(C)";; *) fail "missing WARN(C) for old binary: $out";; esac

# Same gate run from the WORKTREE's copy of the repo root resolves the same.
out="$(env CHUMP_REPO_ROOT="$WT" CHUMP_BIN="$BIN_DIR/chump-good" HOME="$HOME" bash "$CHECK" --resolver-only 2>&1)"; rc=$?
eq "gate rooted at the linked worktree -> exit 0" "$rc" "0"
case "$out" in *"agree on $CANON"*) pass "worktree-rooted gate agrees on MAIN's store";; *) fail "worktree-rooted gate did not resolve MAIN's store: $out";; esac

echo "--- 3. Rust/shell parity (optional)"
PB="${CHUMP_STORE_PATH_PARITY_BIN:-}"
if [ -n "$PB" ] && [ -x "$PB" ]; then
  for d in "$MAIN" "$WT" "$MAIN/crates/x" "$TMP/plain"; do
    rust="$(cd "$d" && env -u CHUMP_STATE_DB -u CHUMP_REPO -u CHUMP_HOME "$PB" gap store-path 2>"$TMP/parity.err" | head -1)"; [ -n "$rust" ] || cat "$TMP/parity.err" >&2
    # .chump/ does not exist in the fixture; normalize via the checkout dir.
    rust_n="$(cd "$(dirname "$(dirname "$rust")")" 2>/dev/null && pwd -P)/.chump/state.db"
    shell="$(chump_state_db "$d" 2>/dev/null)"
    eq "rust == shell for ${d#$TMP/}" "$rust_n" "$shell"
  done
else
  echo "  SKIP (set CHUMP_STORE_PATH_PARITY_BIN to a built chump to compare)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILURE(S)"; exit 1
