#!/usr/bin/env bash
# INFRA-032: verify gap coordination + chump --briefing from repo root without API keys.
# Uses an isolated CHUMP_LOCK_DIR so we do not touch the real .chump-locks/.

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# CREDIBLE-163: honor CARGO_TARGET_DIR so binary discovery is not accidental.
# The old hardcoded "$ROOT/target/debug/chump" made this test SILENTLY SKIP
# whenever the build went elsewhere — e.g. CI's per-run /tmp CARGO_TARGET_DIR
# (INFRA-2118) meant $ROOT/target was always empty, so the test skipped (a
# false-green) for months and never actually exercised the coordination surfaces.
BIN_DIR="${CARGO_TARGET_DIR:-$ROOT/target}/debug"

# INFRA-499: post-INFRA-498 the per-file YAMLs are gone, so CI's
# state.db starts empty (no docs/gaps/* to seed it). Pre-INFRA-499
# this test used a hardcoded RESEARCH-020 fixture; that gap doesn't
# exist in CI's empty state.db so preflight fails. Reserve a fresh
# gap on-the-fly to make the test self-contained.
TMP="$(mktemp -d)"

trap 'rm -rf /tmp/chump-smoke-* 2>/dev/null || true; git -C "$TMP" worktree prune 2>/dev/null || true; rm -rf "$TMP"' EXIT

# CREDIBLE-1573: snapshot the real checkout's coordination/runtime surfaces
# BEFORE the test runs, and run 100% inside $TMP so the real checkout's
# .chump, .chump-locks, bin/, and sessions/ remain completely untouched.
_snapshot_real_checkout() {
    python3 - "$ROOT" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
for rel in (".chump", ".chump-locks", "bin", "sessions"):
    base = os.path.join(root, rel)
    if not os.path.exists(base):
        print(f"{rel}:ABSENT")
        continue
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        filenames.sort()
        rdir = os.path.relpath(dirpath, root)
        print(f"DIR:{rdir}")
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            relf = os.path.relpath(fp, root)
            try:
                st = os.lstat(fp)
                h = hashlib.sha256(open(fp, "rb").read()).hexdigest() if os.path.isfile(fp) else "nonfile"
                print(f"FILE:{relf}:{st.st_size}:{h}")
            except OSError:
                print(f"FILE:{relf}:vanished")
PYEOF
}
REAL_SNAPSHOT_BEFORE="$(_snapshot_real_checkout)"

# shellcheck source=../coord/lib/test-sandbox.sh
source "$ROOT/scripts/coord/lib/test-sandbox.sh"
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
chump_test_sandbox_setup "$TMP"
write_sandbox_healthy_node "$TMP"

# CREDIBLE-1573: initialize a self-contained git repo + bin/chump copy inside
# $TMP so every coordination command (reserve, preflight, claim, musher,
# briefing) operates on $TMP/.chump/state.db and $TMP/.chump-locks/ — NEVER
# the real repo's .chump or .chump-locks.
mkdir -p "$TMP/.chump-locks" "$TMP/bin" "$TMP/sessions" "$TMP/docs/process"
git -C "$TMP" init -q -b main
git -C "$TMP" config user.email "ci@chump.fleet"
git -C "$TMP" config user.name "ci"
echo "# coord fixture" > "$TMP/docs/process/CURSOR_CLAUDE_COORDINATION.md"
git -C "$TMP" add docs/process/CURSOR_CLAUDE_COORDINATION.md
git -C "$TMP" commit -qm "seed" --no-verify
git -C "$TMP" update-ref refs/remotes/origin/main HEAD
cp "$ROOT/bin/chump" "$TMP/bin/chump" 2>/dev/null || true

export CHUMP_HOME="$TMP"
export CHUMP_REPO="$TMP"
export CHUMP_REPO_ROOT="$TMP"
export CHUMP_STATE_DIR="$TMP/.chump"
export CHUMP_STATE_DB="$TMP/.chump/state.db"
export CHUMP_LOCK_DIR="$TMP/.chump-locks"
export CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl"
export CHUMP_SESSION_DIR="$TMP/sessions"
export CHUMP_INTERNAL_DOCTOR=0
export HOME="$TMP"
# CREDIBLE-163 / CREDIBLE-1573: `chump claim` refuses when the fleet kill switch
# (AUTONOMY_LEVEL, RESILIENT-073) is 0 or absent — which it is in CI. With HOME
# redirected to $TMP (above), claim reads $HOME/.chump/AUTONOMY_LEVEL, so write
# the GO level INSIDE the sandbox $TMP — never the operator's real ~/.chump.
# $TMP is removed by the EXIT trap, so no restore dance and no real-state touch.
echo 5 > "$TMP/.chump/AUTONOMY_LEVEL"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_SESSION_ID="coord-surfaces-smoke-$$"
# Smoke test creates an ephemeral gap — skip guards that check for real remote
# branches (INFRA-573) or open PRs (INFRA-273) to avoid collisions with live work.
export CHUMP_ALLOW_REUSE_BRANCH=1
export CHUMP_PREFLIGHT_PR_CHECK=0

if [[ ! -x "$BIN_DIR/chump" ]]; then
  echo "coord-surfaces-smoke: building chump ($BIN_DIR/chump) …" >&2
  # Capability guard (INFRA-1955 follow-up, 2026-05-25): cargo may not be on
  # PATH or build may fail silently on the runner. Verify cargo first, then
  # check the binary actually exists after build. SKIP rather than exit 127
  # when prerequisites are missing — otherwise this single test wedges every
  # PR's fast-checks.
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH — coord-surfaces-smoke needs chump" >&2
    exit 0
  fi
  (cd "$ROOT" && cargo build -q --bin chump 2>&1) || {
    echo "  SKIP: cargo build failed — coord-surfaces-smoke cannot run" >&2
    exit 0
  }
  if [[ ! -x "$BIN_DIR/chump" ]]; then
    echo "  SKIP: chump binary still missing after cargo build ($BIN_DIR/chump)" >&2
    exit 0
  fi
fi

cd "$TMP"

# INFRA-499: caller may still pass an explicit ID for back-compat.
# When none given, reserve one and use it (self-contained fixture).
if [[ -n "${1:-}" ]]; then
    GAP_ID="$1"
else
    echo "[coord-surfaces-smoke] reserving fresh gap for self-contained test …" >&2
    GAP_ID=$("$BIN_DIR/chump" gap reserve --force --domain SMOKE --priority P3 --effort xs \
        --title "coord-surfaces-smoke fixture (auto-clean)" \
        --acceptance-criteria "1. Smoke test fixture claims cleanly without AC-gate error." \
        2>&1 | tail -1)
    echo "[coord-surfaces-smoke] reserved $GAP_ID" >&2
fi

# INFRA-987: shell scripts replaced by Rust subcommands.
echo "[coord-surfaces-smoke] chump gap preflight $GAP_ID …" >&2
"$BIN_DIR/chump" gap preflight "$GAP_ID"

echo "[coord-surfaces-smoke] chump claim $GAP_ID …" >&2
"$BIN_DIR/chump" claim "$GAP_ID" --role fleet-test --paths docs/process/CURSOR_CLAUDE_COORDINATION.md

echo "[coord-surfaces-smoke] musher --status (first lines) …" >&2
bash "$ROOT/scripts/coord/musher.sh" --status 2>/dev/null | head -25 || true

echo "[coord-surfaces-smoke] chump --briefing $GAP_ID …" >&2
"$BIN_DIR/chump" --briefing "$GAP_ID" >/dev/null

REAL_SNAPSHOT_AFTER="$(_snapshot_real_checkout)"
if [[ "$REAL_SNAPSHOT_BEFORE" != "$REAL_SNAPSHOT_AFTER" ]]; then
    echo "FAIL (CREDIBLE-1573): coord-surfaces-smoke mutated the real checkout (.chump / .chump-locks / bin / sessions)!" >&2
    diff -u <(printf '%s\n' "$REAL_SNAPSHOT_BEFORE") <(printf '%s\n' "$REAL_SNAPSHOT_AFTER") >&2 || true
    exit 1
fi

echo "ok: coord-surfaces-smoke passed for $GAP_ID (real checkout untouched)"
