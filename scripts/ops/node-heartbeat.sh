#!/usr/bin/env bash
# scripts/ops/node-heartbeat.sh — RESILIENT-1687
#
# The brain's proof-of-life: stamp a fresh UTC timestamp into the node
# heartbeat file every 60s so the fleet grader can tell this node is alive.
#
# WHY THIS EXISTS AS A TRACKED REPO COPY (verified live 2026-10-21). The only
# node-heartbeat that ran on cuphead was an 11-line wrapper GENERATED inline by
# scripts/setup/chump-node-install.sh (install_organs, ~line 1483) into
# /root/.chumpnode/organs/node-heartbeat.sh — never a repo file. Its unit ran
# as root with no HOME/CHUMP_STATE_DIR, so it wrote "/.chump/node-heartbeat"
# (nonexistent) and crash-logged every minute. RESILIENT-1687 migrates the two
# live root organs to User=ubuntu running the repo copies; this is the repo
# copy node-heartbeat never had.
#
# Portable shebang: /usr/bin/env resolves bash on every supported host
# (systemd Linux, macOS), matching the sentinel/process-organ-heal wrappers
# written alongside the old generated wrapper.
#
# STATE DIR SEAM (STANDING RULE, Chief 2026-10-20): the write target is
# resolved from $HOME only — NOT from a CHUMP_STATE_DIR env default, which is a
# safety-input bypass by construction. The migration drop-in runs this as
# User=ubuntu, so systemd sets HOME=/home/ubuntu and the file lands in
# /home/ubuntu/.chump/node-heartbeat. Tests exercise the real path by running
# under a sandbox HOME.
set -uo pipefail
STATE="$HOME/.chump"
mkdir -p "$STATE" 2>/dev/null || true
while true; do
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/node-heartbeat"
  sleep 60
done
