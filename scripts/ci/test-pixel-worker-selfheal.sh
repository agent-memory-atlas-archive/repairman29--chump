#!/usr/bin/env bash
# RESILIENT-803: pixel-worker (proot-glibc path) carries cooldown + wedge-kill.
set -euo pipefail
f="$(dirname "$0")/../setup/pixel-worker.sh"
bash -n "$f"
grep -q 'PIXEL_WORKER_COOLDOWN_S' "$f"
grep -q 'FAILED_FILE' "$f"
grep -q 'timeout -k 30 "\$WEDGE_S" "\$CLAUDE_PROOT_WRAPPER"' "$f"
grep -q 'wedge-kill' "$f"
echo "PASS: pixel-worker self-heal (cooldown + wedge-kill) present"
