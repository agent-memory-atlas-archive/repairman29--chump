#!/usr/bin/env bash
# install-postgrest.sh — INFRA-7303 (INFRA-6804 / INFRA-3631 slice).
#
# Standalone slice of install-gap-substrate.sh's POSTGREST phase: installs
# the PostgREST binary (via chump-node-install.sh's svc_install supervisor
# abstraction, reused per the INFRA-3710 source-for-functions pattern — see
# install-almanac-organ.sh for the precedent) and writes ~/.chump/postgrest.conf
# pointed at the chump_fleet DB via the authenticator role. Idempotent: an
# existing postgrest.conf is left untouched.
#
# Usage:
#   bash scripts/setup/install-postgrest.sh
#   bash scripts/setup/install-postgrest.sh --dry-run
set -uo pipefail

log() { printf '[install-postgrest] %s\n' "$*"; }
die() { printf '[install-postgrest] ERROR: %s\n' "$*" >&2; exit 1; }

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $a";;
  esac
done

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"
DB_NAME="${CHUMP_SUBSTRATE_DB_NAME:-chump_fleet}"
DB_PORT="${CHUMP_SUBSTRATE_DB_PORT:-5432}"
DB_HOST="${CHUMP_SUBSTRATE_DB_HOST:-localhost}"
REST_PORT="${CHUMP_SUBSTRATE_PORT:-3000}"
PG_AUTHENTICATOR="chump_authenticator"
POSTGREST_CONF="$STATE_DIR/postgrest.conf"
SUBSTRATE_PW="${CHUMP_SUBSTRATE_PW:-REDACTED}"

mkdir -p "$STATE_DIR" "$NODE_DIR/bin"

# ---------- PREFLIGHT (INFRA-3710) ----------
# Reuse detect_host()/svc_install()/svc_up()/svc_status() from
# chump-node-install.sh instead of re-deriving supervisor branches here. That
# file guards its own top-level "run" body behind a `BASH_SOURCE == $0` check
# specifically so it can be sourced for its functions without also triggering
# a full node install as a side effect.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chump-node-install.sh"
[ -f "$INSTALL_SCRIPT" ] || die "$INSTALL_SCRIPT not found — cannot proceed"
_PG_DRY="$DRY"
set --
# shellcheck disable=SC1091
source "$INSTALL_SCRIPT"
DRY="$_PG_DRY"

run() { [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

detect_host

# ---------- AC1: install postgrest binary if not already present ----------
ensure_postgrest_binary() {
  POSTGREST_BIN="$NODE_DIR/bin/postgrest"
  local candidate
  for candidate in "$(command -v postgrest 2>/dev/null)" "$HOME/.local/bin/postgrest" "$POSTGREST_BIN"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      POSTGREST_BIN="$candidate"
      log "postgrest binary already installed: $POSTGREST_BIN"
      return 0
    fi
  done
  log "installing postgrest binary"
  local ver="v12.2.8" os_tag
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) os_tag="linux-static-x64";;
    Linux-aarch64|Linux-arm64) os_tag="linux-static-arm64";;
    Darwin-arm64) os_tag="macos-arm64";;
    Darwin-x86_64) os_tag="macos";;
    *) die "unsupported host for postgrest binary: $(uname -s)-$(uname -m)";;
  esac
  local url="https://github.com/PostgREST/postgrest/releases/download/${ver}/postgrest-${ver}-${os_tag}.tar.xz"
  if [ "$DRY" = 1 ]; then
    log "DRY: would download $url -> $POSTGREST_BIN"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  curl -sL "$url" -o "$tmp/postgrest.tar.xz" || die "failed to download postgrest from $url"
  tar xf "$tmp/postgrest.tar.xz" -C "$tmp"
  install -m 0755 "$tmp/postgrest" "$POSTGREST_BIN"
  rm -rf "$tmp"
  log "postgrest installed: $POSTGREST_BIN"
}

# ---------- AC2 + AC3: write postgrest.conf once, idempotent ----------
write_postgrest_conf() {
  if [ -f "$POSTGREST_CONF" ]; then
    log "postgrest.conf already exists — leaving as-is (no-op): $POSTGREST_CONF"
    return 0
  fi
  local uri="postgres://${PG_AUTHENTICATOR}:${SUBSTRATE_PW}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  run "cat > '$POSTGREST_CONF' <<CONF
db-uri = \"$uri\"
db-schemas = \"public\"
db-anon-role = \"chump_anon\"
server-host = \"127.0.0.1\"
server-port = $REST_PORT
CONF"
  run "chmod 600 '$POSTGREST_CONF'"
  log "postgrest.conf written: $POSTGREST_CONF (contains DB password — 0600)"
}

ensure_postgrest_binary
write_postgrest_conf

log "DONE. postgrest binary=$POSTGREST_BIN conf=$POSTGREST_CONF (db=$DB_NAME role=$PG_AUTHENTICATOR)"
exit 0
