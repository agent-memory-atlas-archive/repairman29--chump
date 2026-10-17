#!/usr/bin/env bash
# scripts/setup/install-pr-shepherd-daemon.sh — META-192
#
# Idempotently installs the launchd agent that runs pr-shepherd-daemon.sh
# every 60 seconds (StartInterval: 60).
#
# The daemon classifies all open PRs into 8 states (BEHIND/MERGEABLE/ARMED/
# DIRTY/BLOCKED_GREEN/BLOCKED_REAL_FAIL/UNKNOWN/CONFLICTING), auto-rebases
# BEHIND PRs, arms auto-merge on BLOCKED_GREEN, and files follow-up gaps on
# BLOCKED_REAL_FAIL. See META-180 through META-184 for the full story.
#
# Usage:
#   bash scripts/setup/install-pr-shepherd-daemon.sh        # install + load
#   launchctl unload ~/Library/LaunchAgents/com.chump.pr-shepherd.plist
#
# Does NOT start the daemon if already loaded — unloads first to pick up
# any plist changes, then loads fresh (idempotent pattern from INFRA-1779).
#
# Env knobs (read at install time):
#   CHUMP_PR_SHEPHERD_DRY_RUN           — set to 1 to install in dry-run mode
#   CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK — override max rebases per tick

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve main worktree so the plist path survives worktree reaping (INFRA-451).
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

LABEL="com.chump.pr-shepherd"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$ROOT/scripts/coord/pr-shepherd-daemon.sh"
LOG_OUT="$HOME/.chump/logs/pr-shepherd.out"
LOG_ERR="$HOME/.chump/logs/pr-shepherd.err"
INTERVAL_S=60   # every 60 seconds — matches META-181 default tick

if [[ ! -f "$DAEMON_SCRIPT" ]]; then
    echo "ERROR: $DAEMON_SCRIPT not found — META-180/META-181 must land first." >&2
    exit 2
fi
[[ -x "$DAEMON_SCRIPT" ]] || chmod +x "$DAEMON_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"

# Build optional env var block for dry-run mode
DRY_RUN_KEY=""
if [[ -n "${CHUMP_PR_SHEPHERD_DRY_RUN:-}" ]]; then
    DRY_RUN_KEY="        <key>CHUMP_PR_SHEPHERD_DRY_RUN</key>
        <string>1</string>"
fi

MAX_REBASES_KEY=""
if [[ -n "${CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK:-}" ]]; then
    MAX_REBASES_KEY="        <key>CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK</key>
        <string>${CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK}</string>"
fi

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DAEMON_SCRIPT}</string>
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true: exercises the daemon immediately on install so
         "did the plist land correctly?" is answered at install time, not
         60 seconds later (INFRA-351 lesson). -->
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive=false: pr-shepherd-daemon.sh tick is a single-shot script.
         launchd re-launches it every StartInterval seconds. -->
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- gh CLI needs HOME for auth token; PATH for git + python3 (INFRA-802). -->
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <!-- CHUMP_AMBIENT_PATH: explicit absolute path to ambient.jsonl (META-248).
             Prevents the daemon from computing the path relative to SCRIPT_DIR, which
             can resolve to a stale /tmp worktree under launchd's execution context. -->
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
${DRY_RUN_KEY}
${MAX_REBASES_KEY}
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

# Unload first (idempotent — fails silently if not loaded).
# Use launchctl bootout + bootstrap (modern API) with fallback to unload/load
# for older macOS. bootout is graceful: waits for running instance to exit.
UID_VAL="$(id -u)"
if launchctl bootout "gui/${UID_VAL}/${LABEL}" 2>/dev/null; then
    echo "Unloaded existing ${LABEL} via bootout"
else
    launchctl unload "$PLIST" 2>/dev/null || true
fi
if launchctl bootstrap "gui/${UID_VAL}" "$PLIST" 2>/dev/null; then
    echo "Loaded ${LABEL} via bootstrap"
else
    launchctl load "$PLIST"
fi

echo ""
echo "Loaded launchd job ${LABEL}"
echo "  Cadence:  every ${INTERVAL_S}s (RunAtLoad=true, KeepAlive=false)"
echo "  WorkDir:  ${ROOT}"
echo "  Ambient:  ${ROOT}/.chump-locks/ambient.jsonl"
echo "  Stdout:   ${LOG_OUT}"
echo "  Stderr:   ${LOG_ERR}"
echo "  Verify:   launchctl list | grep ${LABEL}"
echo "  Disable:  launchctl bootout gui/${UID_VAL}/${LABEL}"
echo "  Dry-run:  CHUMP_PR_SHEPHERD_DRY_RUN=1 bash $0"
echo ""
echo "Smoke test (wait 10s after install for RunAtLoad tick):"
echo "  pre=\$(wc -l < ${ROOT}/.chump-locks/ambient.jsonl)"
echo "  launchctl kickstart -k gui/${UID_VAL}/${LABEL}"
echo "  sleep 10"
echo "  post=\$(wc -l < ${ROOT}/.chump-locks/ambient.jsonl)"
echo "  echo \"delta: \$((post-pre))\"  # expect 30+"
