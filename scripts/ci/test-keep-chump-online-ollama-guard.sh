#!/usr/bin/env bash
# RESILIENT-1502: when the `ollama` binary is not installed on a host, keep-chump-online.sh
# must emit exactly one clear health error and skip startup — not retry-loop `nohup ollama
# serve` on every invocation (that's what filled logs/ollama-serve.log with repeated
# "nohup: failed to run command 'ollama': No such file or directory" on cuphead, a node
# that never installed Ollama because its fleet workers route through FLEET_BACKEND=claude).
#
# Usage: bash scripts/ci/test-keep-chump-online-ollama-guard.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake CHUMP_HOME so the script's `mkdir -p logs` / log file don't touch the real repo,
# and so it doesn't pick up a real .env / inference-primary override.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/logs" "$FAKE_HOME/scripts/dispatch"
cp "$ROOT/scripts/dev/keep-chump-online.sh" "$FAKE_HOME/keep-chump-online.sh"

# PATH with no `ollama` binary (strip it out of the real PATH if present).
FAKE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do
  [[ -x "$d/ollama" ]] || printf '%s:' "$d"
done)"
FAKE_PATH="${FAKE_PATH%:}"

echo "1. Running keep-chump-online.sh with ollama absent from PATH..."
CHUMP_HOME="$FAKE_HOME" \
CHUMP_KEEPALIVE_EMBED=0 \
CHUMP_KEEPALIVE_DISCORD=0 \
PATH="$FAKE_PATH" \
  bash "$FAKE_HOME/keep-chump-online.sh" >"$WORK/stdout.log" 2>&1 || {
    echo "ERROR: keep-chump-online.sh exited non-zero" >&2
    cat "$WORK/stdout.log" >&2
    exit 1
  }

LOG="$FAKE_HOME/logs/keep-chump-online.log"
echo "2. Checking for exactly one clear health error, no retry attempt..."

if [[ ! -f "$LOG" ]]; then
  echo "ERROR: expected log file $LOG not written" >&2
  cat "$WORK/stdout.log" >&2
  exit 1
fi

err_count="$(grep -c "HEALTH ERROR:.*ollama.*not installed" "$LOG" || true)"
if [[ "$err_count" -ne 1 ]]; then
  echo "ERROR: expected exactly 1 health-error line, got $err_count" >&2
  cat "$LOG" >&2
  exit 1
fi
echo "   ✓ exactly one HEALTH ERROR line"

if grep -q "Starting Ollama" "$LOG"; then
  echo "ERROR: 'Starting Ollama...' logged despite missing binary — guard did not skip startup" >&2
  cat "$LOG" >&2
  exit 1
fi
echo "   ✓ no 'Starting Ollama...' attempt logged"

if [[ -f "$FAKE_HOME/logs/ollama-serve.log" ]]; then
  echo "ERROR: ollama-serve.log written — nohup ollama serve was still invoked" >&2
  cat "$FAKE_HOME/logs/ollama-serve.log" >&2
  exit 1
fi
echo "   ✓ no ollama-serve.log (nohup never invoked)"

echo ""
echo "=== keep-chump-online ollama-guard test: PASS ==="
exit 0
