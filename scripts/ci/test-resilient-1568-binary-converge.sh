#!/usr/bin/env bash
# RESILIENT-1568: _converge_stale_binaries repoints stray chump copies at the canonical one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.cargo/bin" "$HOME/.local/bin"
printf 'old\n' > "$HOME/.cargo/bin/chump"; chmod +x "$HOME/.cargo/bin/chump"
printf 'new\n' > "$HOME/.local/bin/chump"; chmod +x "$HOME/.local/bin/chump"
fn="$(sed -n '/^_converge_stale_binaries() {/,/^}/p' "$ROOT/scripts/ops/node-refresh-chump.sh")"
[[ -n "$fn" ]] || { echo "FAIL: function missing"; exit 1; }
log() { :; }; emit() { :; }
TARGET_BIN="$HOME/.local/bin/chump"
eval "$fn"
_converge_stale_binaries
[[ "$(readlink -f "$HOME/.cargo/bin/chump")" == "$(readlink -f "$TARGET_BIN")" ]] || { echo "FAIL: not converged"; exit 1; }
[[ "$(cat "$HOME/.cargo/bin/chump")" == "new" ]] || { echo "FAIL: content"; exit 1; }
echo "PASS: stale ~/.cargo/bin/chump repointed at canonical"
