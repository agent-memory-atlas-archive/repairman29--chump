#!/usr/bin/env bash
# scripts/setup/install-trunk-sentinel.sh — Trunk Health Sentinel + Fix-Trunk Dispatcher launchd installer
#
# Idempotently installs TWO launchd agents (INFRA-2338 / INFRA-2340):
#   1. com.chump.trunk-sentinel        — runs trunk-sentinel-daemon.sh every 60s
#   2. com.chump.fix-trunk-dispatcher  — runs fix-trunk-dispatcher.sh every 30s
#
# Both daemons can spawn `claude -p` sub-agents and therefore need
# CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY in their EnvironmentVariables
# block (launchd does NOT inherit the operator shell's env). This installer
# reads:
#   - $HOME/.chump/oauth-token.json  (key: token)  — OAUTH path
#   - $ANTHROPIC_API_KEY env         — API-key path
# …and substitutes the placeholders in the source plists. If both are empty,
# the placeholder lines are deleted so we don't ship empty-string auth.
#
# Usage:
#   bash scripts/setup/install-trunk-sentinel.sh        # install both + load
#
# Does NOT start the daemons if already loaded — unloads first to pick up
# any plist changes, then loads fresh (idempotent pattern from INFRA-1779).

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
ROOT="$(resolve_main_worktree "$0")"

# ── Sentinel (trunk-sentinel-daemon.sh) ──────────────────────────────────────
SENTINEL_LABEL="com.chump.trunk-sentinel"
SENTINEL_PLIST="$HOME/Library/LaunchAgents/${SENTINEL_LABEL}.plist"
SENTINEL_BOT_SCRIPT="$ROOT/scripts/coord/trunk-sentinel-daemon.sh"
SENTINEL_LOG_OUT="$HOME/.chump/logs/trunk-sentinel.out"
SENTINEL_LOG_ERR="$HOME/.chump/logs/trunk-sentinel.err"
SENTINEL_INTERVAL_S=60

# ── Dispatcher (fix-trunk-dispatcher.sh) ─────────────────────────────────────
DISPATCHER_LABEL="com.chump.fix-trunk-dispatcher"
DISPATCHER_PLIST="$HOME/Library/LaunchAgents/${DISPATCHER_LABEL}.plist"
DISPATCHER_BOT_SCRIPT="$ROOT/scripts/dispatch/fix-trunk-dispatcher.sh"
DISPATCHER_LOG="$ROOT/.chump-locks/fix-trunk-dispatcher.log"
DISPATCHER_INTERVAL_S=30

# ── Sanity: both scripts must exist ──────────────────────────────────────────
if [[ ! -f "$SENTINEL_BOT_SCRIPT" ]]; then
    echo "ERROR: $SENTINEL_BOT_SCRIPT not found — daemon must land first." >&2
    exit 2
fi
[[ -x "$SENTINEL_BOT_SCRIPT" ]] || chmod +x "$SENTINEL_BOT_SCRIPT"

if [[ ! -f "$DISPATCHER_BOT_SCRIPT" ]]; then
    echo "ERROR: $DISPATCHER_BOT_SCRIPT not found — daemon must land first." >&2
    exit 2
fi
[[ -x "$DISPATCHER_BOT_SCRIPT" ]] || chmod +x "$DISPATCHER_BOT_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"
mkdir -p "$ROOT/.chump-locks"

# ── INFRA-2340: resolve auth sources for plist EnvironmentVariables ──────────
# Read OAUTH token from refresh file (key: token, mode 0600 file). The token
# itself is NEVER logged — we only print its presence + length.
_oauth_token=""
if [[ -r "$HOME/.chump/oauth-token.json" ]]; then
    _oauth_token=$(python3 -c "import json; print(json.load(open('$HOME/.chump/oauth-token.json')).get('token',''))" 2>/dev/null || true)
fi
_api_key="${ANTHROPIC_API_KEY:-}"

# Auth-line emission helper. We want to write the literal XML for the auth keys
# ONLY when the corresponding value is non-empty. Both empty → skip both lines
# entirely (don't ship blank-string auth). Either present → include just that
# one. The escaping uses bash heredoc inside a function so values with shell
# metacharacters (rare in tokens, but safe) survive.
_auth_xml() {
    local oauth="$1" apikey="$2"
    if [[ -n "$oauth" ]]; then
        printf '        <key>CLAUDE_CODE_OAUTH_TOKEN</key>\n'
        # XML-escape: tokens are alphanumeric + dashes/underscores; no escaping
        # needed in practice, but use printf %s defensively rather than echo.
        printf '        <string>'
        printf '%s' "$oauth"
        printf '</string>\n'
    fi
    if [[ -n "$apikey" ]]; then
        printf '        <key>ANTHROPIC_API_KEY</key>\n'
        printf '        <string>'
        printf '%s' "$apikey"
        printf '</string>\n'
    fi
}

_auth_block=$(_auth_xml "$_oauth_token" "$_api_key")

# Log auth resolution status (length only, NEVER the secret).
if [[ -n "$_oauth_token" ]]; then
    echo "auth: CLAUDE_CODE_OAUTH_TOKEN resolved from ~/.chump/oauth-token.json (len=${#_oauth_token})"
fi
if [[ -n "$_api_key" ]]; then
    echo "auth: ANTHROPIC_API_KEY resolved from env (len=${#_api_key})"
fi
if [[ -z "$_oauth_token" && -z "$_api_key" ]]; then
    echo "WARN: no OAUTH token and no ANTHROPIC_API_KEY available — installed plists will not pass auth env vars."
    echo "      The daemon's defensive read of ~/.chump/oauth-token.json (INFRA-2340) is the runtime fallback."
fi

# ── Write sentinel plist ─────────────────────────────────────────────────────
cat > "$SENTINEL_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SENTINEL_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SENTINEL_BOT_SCRIPT}</string>
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${SENTINEL_INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SENTINEL_LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${SENTINEL_LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/Users/${USER}/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <!-- META-248: explicit absolute path to ambient.jsonl so the daemon
             does not compute it relative to a stale /tmp worktree under
             launchd's execution context. -->
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
${_auth_block}    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${SENTINEL_PLIST}"

# ── Write dispatcher plist ───────────────────────────────────────────────────
cat > "$DISPATCHER_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DISPATCHER_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DISPATCHER_BOT_SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${DISPATCHER_INTERVAL_S}</integer>
    <key>ThrottleInterval</key>
    <integer>${DISPATCHER_INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${DISPATCHER_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${DISPATCHER_LOG}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/Users/${USER}/.local/bin:/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:/usr/bin:/bin</string>
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
        <key>CHUMP_FIX_TRUNK_DISPATCH</key>
        <string>1</string>
${_auth_block}    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${DISPATCHER_PLIST}"

# Clear the secrets from this process before we shell out.
unset _oauth_token _api_key _auth_block

# ── Validate both plists ─────────────────────────────────────────────────────
if ! plutil -lint "$SENTINEL_PLIST" >/dev/null 2>&1; then
    echo "ERROR: ${SENTINEL_PLIST} is not valid XML — refusing to load" >&2
    plutil -lint "$SENTINEL_PLIST" >&2 || true
    exit 3
fi
if ! plutil -lint "$DISPATCHER_PLIST" >/dev/null 2>&1; then
    echo "ERROR: ${DISPATCHER_PLIST} is not valid XML — refusing to load" >&2
    plutil -lint "$DISPATCHER_PLIST" >&2 || true
    exit 3
fi
echo "plutil -lint passed for both plists"

# ── Reload (unload + load is idempotent) ─────────────────────────────────────
launchctl unload "$SENTINEL_PLIST" 2>/dev/null || true
launchctl load "$SENTINEL_PLIST"
launchctl unload "$DISPATCHER_PLIST" 2>/dev/null || true
launchctl load "$DISPATCHER_PLIST"

echo ""
echo "Loaded launchd job ${SENTINEL_LABEL}"
echo "  Cadence: every ${SENTINEL_INTERVAL_S}s (RunAtLoad=true)"
echo "  Stdout:  ${SENTINEL_LOG_OUT}"
echo "  Stderr:  ${SENTINEL_LOG_ERR}"
echo "  Verify:  launchctl list | grep ${SENTINEL_LABEL}"
echo "  Disable: launchctl unload ${SENTINEL_PLIST}"
echo ""
echo "Loaded launchd job ${DISPATCHER_LABEL}"
echo "  Cadence: every ${DISPATCHER_INTERVAL_S}s (RunAtLoad=false)"
echo "  Log:     ${DISPATCHER_LOG}"
echo "  Verify:  launchctl list | grep ${DISPATCHER_LABEL}"
echo "  Disable: launchctl unload ${DISPATCHER_PLIST}"
