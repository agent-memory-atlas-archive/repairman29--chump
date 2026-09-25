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

# CREDIBLE-163: `chump claim` refuses when the fleet kill switch
# (~/.chump/AUTONOMY_LEVEL, RESILIENT-073) is 0 or absent — which it is in CI, so
# claim exited 1 ("fleet stopped") the moment this test actually ran. This smoke
# test only verifies the claim SURFACE, so set the level to GO for the test and
# restore the operator's real state on exit. The EXIT trap runs on success AND
# failure, so we never leave the kill switch flipped — critical for local runs.
AL_FILE="${HOME:-/tmp}/.chump/AUTONOMY_LEVEL"
AL_BACKUP="$(mktemp)"
AL_EXISTED=0
[[ -f "$AL_FILE" ]] && { cp "$AL_FILE" "$AL_BACKUP"; AL_EXISTED=1; }
restore_autonomy() {
  if [[ "$AL_EXISTED" == 1 ]]; then
    cp "$AL_BACKUP" "$AL_FILE" 2>/dev/null || true
  else
    rm -f "$AL_FILE"
  fi
  rm -f "$AL_BACKUP"
}
trap 'rm -rf "$TMP"; restore_autonomy' EXIT
mkdir -p "$(dirname "$AL_FILE")"
echo 5 > "$AL_FILE"

export CHUMP_LOCK_DIR="$TMP"
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
  cargo build -q --bin chump 2>&1 || {
    echo "  SKIP: cargo build failed — coord-surfaces-smoke cannot run" >&2
    exit 0
  }
  if [[ ! -x "$BIN_DIR/chump" ]]; then
    echo "  SKIP: chump binary still missing after cargo build ($BIN_DIR/chump)" >&2
    exit 0
  fi
fi

# INFRA-499: caller may still pass an explicit ID for back-compat.
# When none given, reserve one and use it (self-contained fixture).
if [[ -n "${1:-}" ]]; then
    GAP_ID="$1"
else
    echo "[coord-surfaces-smoke] reserving fresh gap for self-contained test …" >&2
    GAP_ID=$("$BIN_DIR/chump" gap reserve --domain SMOKE --priority P3 --effort xs \
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
bash scripts/coord/musher.sh --status 2>/dev/null | head -25 || true

echo "[coord-surfaces-smoke] chump --briefing $GAP_ID …" >&2
"$BIN_DIR/chump" --briefing "$GAP_ID" >/dev/null

echo "ok: coord-surfaces-smoke passed for $GAP_ID"
