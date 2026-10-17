#!/usr/bin/env bash
# install-weekly-digest-launchd.sh — install a LaunchAgent that emits a
# weekly health digest every Sunday at 23:00 local time.
#
# INFRA-646: ships count, ship rate trend, waste $ by class, top-3 burning
# gaps (tokens), P0 budget compliance, pillar balance, SLO breaches, and
# EFFECTIVE productizations shipped vs filed.
#
# The digest is appended to .chump-locks/ambient.jsonl and optionally posted
# to a webhook (set CHUMP_WEBHOOK_URL in ~/.chump-operator-env or the plist).
#
# Idempotent — safe to re-run after upgrades.
#
# Verify:
#   launchctl list | grep dev.chump.weekly-digest
# Logs:
#   /tmp/chump-weekly-digest.out.log
#   /tmp/chump-weekly-digest.err.log
# Disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.weekly-digest.plist
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

PLIST_NAME="dev.chump.weekly-digest.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
RUNNER="$REPO/scripts/setup/weekly-digest-runner.sh"

CHUMP_BIN="${CHUMP_BIN:-$HOME/.cargo/bin/chump}"

mkdir -p "$HOME/Library/LaunchAgents"

# ── Write the runner helper script ───────────────────────────────────────────
cat >"$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
# weekly-digest-runner.sh — run by launchd every Sunday at 23:00.
# Emits weekly_health_digest event to ambient.jsonl and optionally
# posts to webhook (CHUMP_WEBHOOK_URL).
set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-$HOME/.cargo/bin/chump}"
ENV_FILE="$HOME/.chump-operator-env"

# Inherit operator env (webhook token etc.)
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true

WEBHOOK_FLAG=""
[[ -n "${CHUMP_WEBHOOK_URL:-}" ]] && WEBHOOK_FLAG="--webhook"

"$CHUMP_BIN" health-digest --since 7d --emit $WEBHOOK_FLAG
RUNNER_EOF

chmod +x "$RUNNER"

# ── Write the plist ──────────────────────────────────────────────────────────
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.weekly-digest</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$RUNNER</string>
  </array>
  <!-- Run every Sunday at 23:00. Weekday=0 is Sunday on macOS launchd. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>23</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-weekly-digest.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-weekly-digest.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_BIN</key>
    <string>$CHUMP_BIN</string>
    <key>CHUMP_AMBIENT_LOG</key>
    <string>$REPO/.chump-locks/ambient.jsonl</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
echo "Runner script:        $RUNNER"
echo "Schedule:             Every Sunday at 23:00 local time"
echo "Logs:                 /tmp/chump-weekly-digest.{out,err}.log"
launchctl list | grep -F "dev.chump.weekly-digest" || true
