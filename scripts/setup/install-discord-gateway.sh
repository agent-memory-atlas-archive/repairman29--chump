#!/usr/bin/env bash
# install-discord-gateway.sh — RESILIENT-266: run the Discord gateway as a
# managed daemon so Chump can RECEIVE replies and button taps.
#
# THE PROBLEM THIS SOLVES. Chump can already send: src/discord_dm.rs is plain
# REST and needs no bot (proven live 2026-08-09). It cannot receive: the shipped
# binary is built with `--cfg feature="default"` and `default = []`, so the
# `discord` feature (and its serenity dependency) is compiled OUT, and no
# gateway process runs. src/discord.rs is otherwise COMPLETE — gateway bot with
# DIRECT_MESSAGES intent, owner verification at :932/:964/:999, and
# interaction_create at :1210 already parsing chump_approve:<id> /
# chump_deny:<id> into approval_resolver. This is a build-and-run gap, not a
# feature gap.
#
# Usage:
#   bash scripts/setup/install-discord-gateway.sh            # build, install, load
#   bash scripts/setup/install-discord-gateway.sh --no-build # install/load only
#   bash scripts/setup/install-discord-gateway.sh --uninstall
set -uo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABEL="ai.chump.discord-gateway"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/.chump/logs"
RUNNER="${REPO_ROOT}/scripts/coord/discord-gateway-run.sh"
DO_BUILD=1

for a in "$@"; do
    case "$a" in
        --no-build)  DO_BUILD=0 ;;
        --uninstall)
            launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
            rm -f "$PLIST"
            echo "uninstalled ${LABEL}"
            exit 0 ;;
    esac
done

# Resolve .env across worktrees. It is GITIGNORED, so it exists only in the
# main checkout — and `chump claim` creates a worktree per gap, which is where
# this installer will usually be run from. `git rev-parse --git-common-dir`
# resolves a worktree back to the main .git, whose parent holds the .env.
# (Same defect and same fix as notify-operator.sh in RESILIENT-263; it showed up
# there as an alert that skipped SILENTLY, and here as a false "token not set".)
_env_files() {
    printf '%s\n' "${REPO_ROOT}/.env"
    [[ -n "${CHUMP_HOME:-}" ]] && printf '%s\n' "${CHUMP_HOME}/.env"
    local common
    common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
    [[ -n "$common" ]] || return 0
    [[ "$common" != /* ]] && common="${REPO_ROOT}/${common}"
    printf '%s\n' "$(dirname "$common")/.env"
}

_have_key() {
    local key="$1" f
    [[ -n "${!key:-}" ]] && return 0
    while read -r f; do
        [[ -f "$f" ]] || continue
        grep -qE "^${key}=." "$f" 2>/dev/null && return 0
    done < <(_env_files)
    return 1
}

# ── Preconditions. Fail LOUDLY here rather than install a daemon that will
#    no-op forever — a silently useless daemon is this gap's whole subject.
missing=0
for key in DISCORD_TOKEN CHUMP_READY_DM_USER_ID; do
    if ! _have_key "$key"; then
        echo "ERROR: ${key} is not set (env, .env, or the main checkout's .env)." >&2
        echo "       The gateway cannot run without it." >&2
        missing=1
    fi
done
(( missing == 0 )) || exit 1

mkdir -p "$LOG_DIR" "${HOME}/Library/LaunchAgents"

if (( DO_BUILD )); then
    echo "building with --features discord (pulls in serenity) …"
    if ! (cd "$REPO_ROOT" && cargo build --release --features discord --bin chump); then
        echo "ERROR: build failed — not installing a daemon that cannot start." >&2
        exit 1
    fi
fi

# Resolve the binary via the shared helper rather than assuming
# $REPO_ROOT/target. INFRA-3517 documents the trap: .cargo/config.toml sets
# [build] target-dir = ~/.cargo/chump-shared-target (ZERO-WASTE-029, to stop
# per-repo target/ dirs eating disk), which the naive path and $CARGO_TARGET_DIR
# both MISS — it made preflight report "binary not found" on every such host.
# shellcheck source=../ci/lib/discover-chump-bin.sh
if [[ -f "${REPO_ROOT}/scripts/ci/lib/discover-chump-bin.sh" ]]; then
    export REPO_ROOT
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/scripts/ci/lib/discover-chump-bin.sh"
fi
CHUMP_BIN="${CHUMP_BIN:-${REPO_ROOT}/target/release/chump}"

# The binary must actually have the feature compiled in. A default-feature
# binary starts and silently never connects, which is indistinguishable from
# "installed and working" until someone tries to reply.
if [[ ! -x "$CHUMP_BIN" ]] || ! "$CHUMP_BIN" --help 2>&1 | grep -q -- "--discord"; then
    echo "ERROR: ${CHUMP_BIN} has no --discord flag — the feature is not compiled in." >&2
    echo "       Re-run without --no-build, or: cargo build --release --features discord" >&2
    exit 1
fi
echo "built binary: ${CHUMP_BIN}"

# COPY THE BINARY TO A STABLE PATH. Do NOT point the daemon at the build output.
# ZERO-WASTE-029 sends every local cargo build to ~/.cargo/chump-shared-target,
# and the fleet runs ~145 workers that build constantly — so any default-feature
# build silently REPLACES the discord-enabled binary underneath a running
# daemon. Observed live 2026-08-09: the binary lost its --discord flag between
# two installer runs minutes apart. With KeepAlive, that turns into a daemon
# restarting forever into a binary that cannot serve its purpose.
STABLE_BIN="${HOME}/.chump/bin/chump-discord"
mkdir -p "$(dirname "$STABLE_BIN")"
cp -f "$CHUMP_BIN" "$STABLE_BIN" || { echo "ERROR: could not copy binary to $STABLE_BIN" >&2; exit 1; }
chmod +x "$STABLE_BIN"
echo "stable copy:  ${STABLE_BIN}"

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
        <string>${RUNNER}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <!-- KeepAlive, not StartInterval: this is a long-running gateway, not a
         periodic job. Restart it if it dies; that is the entire point. -->
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <!-- Do not hot-loop if it crashes on startup (bad token, API outage). -->
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/discord-gateway.out</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/discord-gateway.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <!-- NOTE: this heredoc is UNQUOTED so shell variables expand. So do
             backticks, as command substitution: an earlier version of this
             comment wrote cargo metadata in backticks, bash RAN it, and the
             whole JSON package dump was injected into the plist. launchd then
             failed with "Bootstrap failed: 5: Input/output error" and plutil
             reported a parse error. Never put backticks in this heredoc.
             ~/.cargo/bin goes FIRST because discover-chump-bin.sh shells out
             to cargo metadata, and under rustup cargo lives in ~/.cargo/bin,
             not ${BREW_PREFIX}/bin — omitting it breaks binary discovery under
             launchd while working fine in an interactive shell. -->
        <string>${HOME}/.cargo/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>CHUMP_HOME</key>
        <string>${REPO_ROOT}</string>
        <!-- PRODUCT-014 opt-in, required IN ADDITION to the discord cargo
             feature and the --discord flag. Without it the binary starts and
             exits with an error, which launchd would restart forever. -->
        <key>CHUMP_DISCORD_ENABLED</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "loaded ${LABEL}"
else
    echo "WARN: bootstrap failed; try: launchctl bootstrap gui/$(id -u) $PLIST" >&2
fi

echo ""
echo "Verify it is actually running (do NOT assume — that assumption is why"
echo "operator-recall sat dead from 2026-05-08):"
echo "  bash scripts/coord/discord-gateway-liveness.sh"
