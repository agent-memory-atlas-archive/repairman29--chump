#!/usr/bin/env bash
# install-autonomous-mode-launchd.sh — install a LaunchAgent that polls operator
# presence every 15 minutes and updates CHUMP_OPERATOR_LAST_SEEN_UNIX in a
# companion env file read by fleet workers.
#
# What it does:
#   - Stamps ~/.chump-operator-last-seen with the current epoch when the
#     operator's ~/.claude/ directory was touched in the last 15 minutes.
#   - Writes CHUMP_OPERATOR_LAST_SEEN_UNIX=<ts> to ~/.chump-operator-env so
#     fleet workers launched by launchd can inherit the value.
#   - Emits an autonomous_mode_entered or autonomous_mode_exited event to
#     .chump-locks/ambient.jsonl when the threshold crosses.
#
# Threshold: CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS (default 4) — see
#            src/operator_presence.rs and docs/process/AUTONOMOUS_MODE.md.
#
# Idempotent — safe to re-run after upgrades.
#
# Verify:
#   launchctl list | grep dev.chump.autonomous-mode
# Logs:
#   /tmp/chump-autonomous-mode.out.log
#   /tmp/chump-autonomous-mode.err.log
# Disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.autonomous-mode.plist
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="dev.chump.autonomous-mode.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
POLLER="$REPO/scripts/setup/autonomous-mode-poller.sh"

mkdir -p "$HOME/Library/LaunchAgents"

# ── Write the poller helper script ───────────────────────────────────────────
cat >"$POLLER" <<'POLLER_EOF'
#!/usr/bin/env bash
# autonomous-mode-poller.sh — run by launchd every 15 minutes.
# Updates CHUMP_OPERATOR_LAST_SEEN_UNIX from ~/.claude/ mtime.
set -euo pipefail

CLAUDE_DIR="${CHUMP_OPERATOR_ACTIVITY_PATH:-$HOME/.claude}"
ENV_FILE="$HOME/.chump-operator-env"
AMBIENT="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
THRESHOLD_HOURS="${CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS:-4}"
THRESHOLD_SECS=$(( THRESHOLD_HOURS * 3600 ))

# Get mtime of ~/.claude/ in epoch seconds (stat is BSD on macOS).
if [[ -d "$CLAUDE_DIR" ]]; then
    LAST_SEEN=$(stat -f "%m" "$CLAUDE_DIR" 2>/dev/null || echo "0")
else
    LAST_SEEN=0
fi

NOW=$(date +%s)
ELAPSED=$(( NOW - LAST_SEEN ))

# Write env file for fleet-worker subprocesses.
echo "CHUMP_OPERATOR_LAST_SEEN_UNIX=$LAST_SEEN" > "$ENV_FILE"

# Emit ambient event when threshold boundary is crossed.
STATE_FILE="$HOME/.chump-operator-presence-state"
PREV_STATE="present"
[[ -f "$STATE_FILE" ]] && PREV_STATE="$(cat "$STATE_FILE")"

if (( ELAPSED >= THRESHOLD_SECS )); then
    CUR_STATE="absent"
else
    CUR_STATE="present"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$PREV_STATE" != "$CUR_STATE" ]]; then
    if [[ "$CUR_STATE" == "absent" ]]; then
        HOURS_FLOAT="$(echo "scale=2; $ELAPSED / 3600" | bc)"
        printf '{"ts":"%s","kind":"autonomous_mode_entered","absent_hours":%s}\n' \
            "$TS" "$HOURS_FLOAT" >> "$AMBIENT" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"autonomous_mode_exited"}\n' "$TS" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    echo "$CUR_STATE" > "$STATE_FILE"
fi
POLLER_EOF

chmod +x "$POLLER"

# ── Write the plist ──────────────────────────────────────────────────────────
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.autonomous-mode</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$POLLER</string>
  </array>
  <!-- Poll every 15 minutes (900 seconds). -->
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-autonomous-mode.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-autonomous-mode.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS</key>
    <string>${CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS:-4}</string>
    <key>CHUMP_AMBIENT_LOG</key>
    <string>$REPO/.chump-locks/ambient.jsonl</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
echo "Poller script:        $POLLER"
echo "Env file (workers):   $HOME/.chump-operator-env"
launchctl list | grep -F "dev.chump.autonomous-mode" || true
