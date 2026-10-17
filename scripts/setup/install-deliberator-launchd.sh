#!/usr/bin/env bash
# install-deliberator-launchd.sh — RESILIENT-212
#
# Installs the com.chump.deliberator LaunchAgent: the vote-tally daemon that
# runs `scripts/coord/deliberator-loop.sh tick` every 30 min, tallies
# accumulated FEEDBACK kind=vote/preference events per corr_id, emits
# kind=consensus_result on PASSED/FAILED, and escalates NO_QUORUM proposals to
# the operator via operator-recall after deadline+24h.
#
# ROOT CAUSE this script fixes (RESILIENT-212): the daemon was listed in
# chump-fleet-bootstrap.sh's REQUIRED_DAEMONS array
# ("com.chump.deliberator|scripts/setup/install-deliberator-launchd.sh") since
# META-162, but this installer script itself was never committed. The
# REQUIRED_DAEMONS loop `continue`s (silently, no MISSING flag) whenever the
# referenced installer file doesn't exist on disk — so `chump-fleet-bootstrap.sh
# --check` never surfaced the gap, and `chump-fleet-bootstrap.sh` (install mode)
# never installed it. A plist was manually copied to ~/Library/LaunchAgents at
# some point (per the manual-install steps documented in
# .chump/launchd/com.chump.deliberator.plist) but never `launchctl load`ed —
# consistent with `launchctl list | grep deliberator` returning nothing and zero
# log output ever existing at /tmp/chump-deliberator.{out,err}.log. This is why
# `kind=consensus_result` has never fired once in this project's history despite
# RESILIENT-061 (the tally shell-arithmetic crash) and CREDIBLE-122 (the
# vote-source dedup bug) both landing — the fixed code was simply never run.
#
# Canonical plist template: .chump/launchd/com.chump.deliberator.plist
# (kept as human-readable documentation + manual-install fallback); this
# script generates the installed copy directly so REPO path substitution and
# the INFRA-2515 belt-and-suspenders CHUMP_FLEET_RECV_SIDE_V0=1 are always
# correct, matching the sibling install-conductor-launchd.sh /
# install-oauth-refresh-launchd.sh pattern.
#
# After install:
#   launchctl list | grep chump.deliberator
# Manual run (smoke test):
#   launchctl start com.chump.deliberator
#   tail /tmp/chump-deliberator.out.log
# Force-tally now regardless of the 30-min schedule:
#   CHUMP_FLEET_RECV_SIDE_V0=1 bash scripts/coord/deliberator-loop.sh audit
# Uninstall:
#   launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.chump.deliberator.plist
#   rm ~/Library/LaunchAgents/com.chump.deliberator.plist
#
# Override interval (seconds) for testing:
#   CHUMP_DELIBERATOR_INTERVAL=300 ./install-deliberator-launchd.sh

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.deliberator.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
INTERVAL="${CHUMP_DELIBERATOR_INTERVAL:-1800}"

# PATH must let the deliberator resolve jq, git, gh, python3 (all used by
# scripts/coord/deliberator-loop.sh).
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.deliberator</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO}/scripts/coord/deliberator-loop.sh</string>
    <string>tick</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-deliberator.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-deliberator.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
    <!-- INFRA-2515 (operator mandate 2026-06-05): A2A is ALWAYS-ON. Belt-and-
         suspenders alongside the launchd-session setenv (see
         chump-fleet-bootstrap.sh's "launchctl setenv CHUMP_FLEET_RECV_SIDE_V0 1")
         so the deliberator does real tally work even if the session-level
         setenv hasn't propagated yet at boot. -->
    <key>CHUMP_FLEET_RECV_SIDE_V0</key>
    <string>1</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload: unload (uncomplain on missing) + load -w (uncomplain on already-loaded).
# `launchctl load -w` rather than `bootstrap`/`bootout`: this repo's sibling
# installers use both patterns (grep shows ~85 use load, ~31 use bootstrap),
# but `bootstrap` returned "Input/output error" (5) when run from this agent's
# shell context during RESILIENT-212 verification, while `load -w` succeeded
# cleanly — matching the majority pattern and avoiding that failure mode.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load -w "$DEST"

echo "Installed: $DEST"
echo "  command: scripts/coord/deliberator-loop.sh tick"
echo "  interval: ${INTERVAL}s"
echo "  verify: launchctl list | grep chump.deliberator"
echo "  on-demand: launchctl start com.chump.deliberator"
