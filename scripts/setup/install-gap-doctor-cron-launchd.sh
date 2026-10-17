#!/usr/bin/env bash
# install-gap-doctor-cron-launchd.sh — INFRA-308: install 15-min launchd
# agent that runs scripts/coord/gap-doctor.py safe-sweep.
#
# Without continuous reconciliation, state.db ↔ docs/gaps/<ID>.yaml drift
# accumulates between manual `gap-doctor doctor` runs. On 2026-05-02 a
# single dispatcher session produced 21 drifts (12 DB-done/YAML-open,
# 8 DB-open/YAML-done, 1 YAML-only) AFTER multiple manual sync runs.
# At fleet scale this drift is unbounded — every PR shipped via the
# manual ship path (INFRA-028), every CLI bypass (CHUMP_RAW_YAML_LOCK=0),
# every chump-binary-unwedge.sh recovery from a wedged binary, leaves drift
# the next agent inherits.
#
# What this installs:
#   gap-doctor.py safe-sweep auto-fixes the SAFE drift buckets
#   (Bucket 1 = DB done / YAML open; Bucket 2 = DB open / YAML done) and
#   emits ALERT events to .chump-locks/ambient.jsonl for the UNSAFE
#   buckets (Bucket 3 = DB-only orphans; Bucket 4 = YAML-only).
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-gap-doctor-cron.plist
# Manual fire: launchctl start ai.openclaw.chump-gap-doctor-cron
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-451: resolve to the *main* worktree (not the linked worktree this
# install script may be running from), so the plist absolute path survives
# worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="ai.openclaw.chump-gap-doctor-cron.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-gap-doctor-cron</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" && (test -x ${BREW_PREFIX}/bin/python3 && ${BREW_PREFIX}/bin/python3 scripts/coord/gap-doctor.py safe-sweep) || (test -x /usr/local/bin/python3 && /usr/local/bin/python3 scripts/coord/gap-doctor.py safe-sweep) || python3 scripts/coord/gap-doctor.py safe-sweep</string>
  </array>
  <!-- Every 15 minutes (900s). Auto-fixes safe drift buckets in-place;
       emits ALERT kind=gap_drift_orphan / gap_drift_yaml_only into
       .chump-locks/ambient.jsonl for unsafe buckets so operators see
       them in the standard pre-flight ambient tail. -->
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-gap-doctor-cron.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-gap-doctor-cron.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

# Reload (unload + load) so the new plist takes effect immediately.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-gap-doctor-cron] Installed: $DEST"
echo "[install-gap-doctor-cron] Schedule:  every 15 min, runs at load"
echo "[install-gap-doctor-cron] Logs:      /tmp/chump-gap-doctor-cron.{out,err}.log"
echo "[install-gap-doctor-cron] Verify:    launchctl list | grep ai.openclaw.chump-gap-doctor-cron"
echo "[install-gap-doctor-cron] Manual:    launchctl start ai.openclaw.chump-gap-doctor-cron"
echo "[install-gap-doctor-cron] Disable:   launchctl unload $DEST"
