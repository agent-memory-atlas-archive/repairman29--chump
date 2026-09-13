#!/usr/bin/env bash
# chump-node-install.sh — COTG: one command to turn an OWNED box into a clean,
# reproducible, self-supervising, self-testing ChumpOS node.
#
# Host-agnostic: Termux(Android/aarch64, runit) / systemd-Linux / macOS(launchd).
# Replaces hand-assembly (helsinki's bespoke organs; the RESILIENT-336 Pixel node)
# with an INSTALLED node whose organs all come from a manifest — never hand-placed.
# See docs/process/COTG_NODE_INSTALL.md.  RESILIENT-318 / RESILIENT-364.
#
# Usage:
#   chump-node-install.sh --role brain|muscle|all [--home DIR] [--self-test-only] [--dry-run]
#                          [--creds-file PATH] [--control-plane-only] [--with-fleet-server]
#
# Zero-touch creds (INFRA-3629, the "bot told to do it" path — no human ever
# opens an editor): supply creds from exactly ONE source and the CREDS phase
# materializes ~/.chump/providers.env itself:
#   --creds-file PATH          path to a ready-made providers.env (KEY=VALUE lines)
#   $CHUMP_BOOTSTRAP_CREDS     the same file body, inline, e.g.:
#     CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=%s\n' "$OAUTH" "$GH")" \
#       curl -fsSL .../chump-node-install.sh | bash -s -- --role brain
# Neither source's VALUES ever appear in `ps`, argv, or this script's logs —
# only the source used and which required keys are present/missing are logged.
# If ~/.chump/providers.env already exists it is left alone (idempotent).
#
# Phases: DETECT -> HOME -> CREDS -> BINARY -> ORGANS -> SUPERVISE -> SELF-TEST.
# A missing or deliberately-disabled work provider produces a successful
# control-plane install: inventory, health, refresh, and the cockpit substrate
# are safe to use, while the token-consuming worker remains stopped.
# Idempotent + non-destructive: installs into $NODE_DIR (default ~/.chumpnode) and
# supervises via the host's native supervisor; state stays at ~/.chump.
set -uo pipefail

# ---------- args ----------
ROLE="brain"; NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"; SELF_TEST_ONLY=0; DRY=0; CREDS_FILE=""
CONTROL_PLANE_ONLY=0
WITH_FLEET_SERVER=0
RECONCILE_ORGANS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --home) NODE_DIR="$2"; shift 2;;
    --self-test-only|--check) SELF_TEST_ONLY=1; shift;;
    --dry-run) DRY=1; shift;;
    --control-plane-only) CONTROL_PLANE_ONLY=1; shift;;
    --with-fleet-server) WITH_FLEET_SERVER=1; shift;;
    --creds-file) CREDS_FILE="$2"; shift 2;;
    # RESILIENT-1035: fast path for the per-node auto-deploy timer
    # (scripts/ops/node-refresh-chump.sh). A full run re-clones/re-fetches
    # $NODE_DIR/repo, re-checks creds, and rebuilds the binary — all
    # redundant work when the caller already git-pulled + refreshed the
    # binary in ITS OWN mirror checkout a moment ago. This flag skips
    # straight to detect_host + install_organs (writes/updates the
    # role-scoped organ wrappers, e.g. muscle's worker.sh, and runs
    # reconcile_role_organs to restart any organ whose manifest entry
    # changed) so a timer-driven refresh actually converges organs to the
    # freshly-deployed code, not just the binary on disk.
    --reconcile-organs-only) RECONCILE_ORGANS_ONLY=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$ROLE" in brain|muscle|all) ;; *) echo "role must be brain|muscle|all" >&2; exit 2;; esac

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
# INFRA-3633: pin the canonical gap store here, once, so every phase below
# (and every organ this script launches) resolves the same state.db instead
# of some falling back to a repo-local $NODE_DIR/repo/.chump/state.db that
# would silently diverge from the machine's real gap backlog.
STATE_DB="${CHUMP_STATE_DB:-$STATE_DIR/state.db}"
export CHUMP_STATE_DB="$STATE_DB"
CREDS="$STATE_DIR/providers.env"
# INFRA-3634: pin the canonical *shared* gap store (PostgREST-fronted
# Postgres, currently CJ per docs/strategy/DATA_HOME_PLAN.md's dated note)
# the same way CHUMP_STATE_DB pins the local sqlite path above — one var,
# read here on the connect side and by install-gap-substrate.sh on the
# provision side, so the two never drift on which host is canonical.
# Precedence: explicit env > providers.env pin > CJ default.
GAP_STORE_URL="${CHUMP_GAP_STORE_URL:-}"
if [ -z "$GAP_STORE_URL" ] && [ -f "$CREDS" ]; then
  GAP_STORE_URL="$(grep -E '^CHUMP_GAP_STORE_URL=' "$CREDS" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
GAP_STORE_URL="${GAP_STORE_URL:-http://100.90.52.126:3000}"
export CHUMP_GAP_STORE_URL="$GAP_STORE_URL"
REPO_URL="${CHUMP_NODE_REPO_URL:-https://github.com/repairman29/chump.git}"
LOG_DIR="$NODE_DIR/logs"
ORGAN_DIR="$NODE_DIR/organs"
BIN="$NODE_DIR/bin/chump"
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[%s]\033[0m %s\n' "$1" "$2"; }
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

# ---------- install budget + per-phase timeouts (RESILIENT-1015) ----------
# The 2026-09-05 mugman repro (2-core aarch64) verified chump-node-install.sh
# hanging past BINARY even with the binary pre-placed + fetch disabled — a
# downstream phase (SUBSTRATE postgres provisioning, EYES almanac clone+build)
# ran synchronously with no ceiling and stalled the one-shot install
# indefinitely. INSTALL_START_S anchors an overall wall-clock budget;
# run_timeout wraps any single blocking subprocess with a per-phase ceiling
# so no one step can consume the whole budget by itself.
INSTALL_START_S="$SECONDS"
INSTALL_BUDGET_S="${CHUMP_INSTALL_BUDGET_S:-280}"
install_budget_remaining_s() { echo $(( INSTALL_BUDGET_S - (SECONDS - INSTALL_START_S) )); }
install_budget_exceeded() { [ "$(install_budget_remaining_s)" -le 0 ]; }
# run_timeout <seconds> <cmd...> — runs cmd bounded by `timeout` when present
# (Termux/older hosts may lack coreutils timeout; degrade to unbounded rather
# than fail the whole phase over a missing tool).
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else "$@"; fi
}

# ---------- 1. DETECT ----------
detect_host() {
  ARCH="$(uname -m)"; OS="$(uname -s)"
  if [ -n "${PREFIX:-}" ] && printf '%s' "$PREFIX" | grep -q 'com.termux'; then
    HOST_KIND="termux"; SUPERVISOR="runit"
    BOOT_DIR="$HOME/.termux/boot"; SVC_DIR="$PREFIX/var/service"
  elif [ "$OS" = "Darwin" ]; then
    HOST_KIND="macos"; SUPERVISOR="launchd"; BOOT_DIR=""; SVC_DIR="$HOME/Library/LaunchAgents"
  elif command -v systemctl >/dev/null 2>&1; then
    HOST_KIND="linux-systemd"; SUPERVISOR="systemd"; BOOT_DIR=""; SVC_DIR="/etc/systemd/system"
  else
    HOST_KIND="linux-nosystemd"; SUPERVISOR="nohup"; BOOT_DIR=""; SVC_DIR="$NODE_DIR/services"
  fi
  info DETECT "host=$HOST_KIND arch=$ARCH supervisor=$SUPERVISOR"
}

# ---------- supervisor abstraction (the reusable core) ----------
# svc_install <name> <exec-command>   — define a supervised, restart-always service
# svc_up <name> / svc_status <name>   — start / query
svc_install() {
  local name="$1" cmd="$2"
  case "$SUPERVISOR" in
    runit)
      run "mkdir -p '$SVC_DIR/$name/log'"
      run "printf '#!/data/data/com.termux/files/usr/bin/sh\nexec 2>&1\ntermux-wake-lock 2>/dev/null || true\nexec %s\n' \"$cmd\" > '$SVC_DIR/$name/run'"
      run "chmod +x '$SVC_DIR/$name/run'"
      run "printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s\n' \"$LOG_DIR/$name\" > '$SVC_DIR/$name/log/run'"
      run "chmod +x '$SVC_DIR/$name/log/run'"; run "mkdir -p '$LOG_DIR/$name'"
      ;;
    systemd)
      run "cat > '$SVC_DIR/chump-$name.service' <<EOF
[Unit]
Description=ChumpOS organ $name
[Service]
# providers.env accepts both KEY=value and `export KEY=value`; source it via
# bash so every installer-supported form reaches the organ without writing a
# secret value into the unit file.
ExecStart=/bin/bash -c 'set -a; [ -r "$CREDS" ] && . "$CREDS"; set +a; exec "$cmd"'
Restart=always
Environment=CHUMP_NODE_DIR=$NODE_DIR
[Install]
WantedBy=multi-user.target
EOF"
      run "systemctl daemon-reload"
      ;;
    *) run "mkdir -p '$SVC_DIR'"; run "echo '$cmd' > '$SVC_DIR/$name.cmd'";;
  esac
}
svc_down() {
  local name="$1"
  case "$SUPERVISOR" in
    runit) run "sv down '$SVC_DIR/$name' 2>/dev/null || true";;
    systemd) run "systemctl disable --now 'chump-$name' 2>/dev/null || true";;
    *) :;;
  esac
}
svc_up() {
  local name="$1"
  case "$SUPERVISOR" in
    # explicit service path: Termux leaves SVDIR unset, so bare names hit sv's
    # compiled default (/var/service) which doesn't exist. runsvdir also auto-starts
    # new dirs within ~5s, so this `sv up` is just a nudge — give runsvdir a moment.
    runit) run "sleep 6; sv up '$SVC_DIR/$name' 2>/dev/null || true";;
    systemd) run "systemctl enable --now 'chump-$name' 2>/dev/null || true";;
    *) :;;
  esac
}
svc_status() {  # prints "up" or "down"
  local name="$1"
  case "$SUPERVISOR" in
    runit) sv status "$SVC_DIR/$name" 2>/dev/null | grep -q '^run:' && echo up || echo down;;
    systemd) systemctl is-active "chump-$name" 2>/dev/null | grep -q '^active' && echo up || echo down;;
    *) [ -f "$SVC_DIR/$name.cmd" ] && echo up || echo down;;
  esac
}

# ---------- 1.5 TOOLCHAIN PREFLIGHT (INFRA-3621) ----------
# Runs before HOME so a partial install never happens on a box missing a
# basic tool. Host-agnostic: termux pkg / linux apt|dnf / macos brew hints,
# reusing detect_host()'s HOST_KIND rather than re-detecting.
install_hint() {
  local tool="$1"
  case "$HOST_KIND" in
    termux) echo "pkg install -y $tool";;
    macos) echo "brew install $tool";;
    linux-systemd|linux-nosystemd)
      if command -v apt >/dev/null 2>&1; then echo "sudo apt install -y $tool"
      elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install -y $tool"
      else echo "install $tool via your distro's package manager"; fi
      ;;
    *) echo "install $tool";;
  esac
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    ok "rust toolchain present ($(rustc --version 2>/dev/null))"
    return 0
  fi
  info TOOLCHAIN "cargo/rustc missing — installing for host=$HOST_KIND"
  case "$HOST_KIND" in
    termux) run "pkg install -y rust";;
    macos|linux-systemd|linux-nosystemd)
      run "curl https://sh.rustup.rs -sSf | sh -s -- -y"
      # shellcheck disable=SC1091
      [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
      ;;
  esac
  if command -v cargo >/dev/null 2>&1; then ok "rust toolchain installed"
  else no "rust toolchain install failed ($(install_hint rust))"; return 1; fi
}

toolchain_preflight() {
  info PREFLIGHT "checking required tools (host=$HOST_KIND)"
  local required="git jq curl" missing=""
  for t in $required; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    for t in $missing; do no "missing: $t -> install with: $(install_hint "$t")"; done
    echo "fix missing tools above, then re-run" >&2
    exit 1
  fi
  ok "required tools present (git, jq, curl)"
  ensure_rust || { echo "fix rust toolchain above (see hint), then re-run" >&2; exit 1; }
}

# ---------- 2. HOME ----------
ensure_home() {
  run "mkdir -p '$NODE_DIR/bin' '$ORGAN_DIR' '$LOG_DIR' '$STATE_DIR'"
  # GH_TOKEN from providers.env, if present, for an authenticated clone of a
  # private repo. Never pass the token through run()'s echo path (--dry-run
  # would leak it) — build the token-injected URL only on the execute path.
  local gh_token=""
  if [ -f "$CREDS" ]; then
    gh_token="$(grep -E '^(export )?GH_TOKEN=' "$CREDS" | tail -1 | sed -E 's/^(export )?GH_TOKEN=//; s/^"(.*)"$/\1/')"
  fi
  local clone_url="$REPO_URL"
  case "$REPO_URL" in
    https://github.com/*) [ -n "$gh_token" ] && clone_url="https://x-access-token:${gh_token}@${REPO_URL#https://}";;
  esac
  if [ -d "$NODE_DIR/repo/.git" ]; then
    if [ "$DRY" = 1 ]; then
      echo "  DRY: git -C '$NODE_DIR/repo' fetch origin main --quiet"
      echo "  DRY: git -C '$NODE_DIR/repo' reset --hard origin/main --quiet"
    elif run_timeout "${CHUMP_GIT_TIMEOUT_S:-120}" git -C "$NODE_DIR/repo" fetch origin main --quiet \
      && run_timeout "${CHUMP_GIT_TIMEOUT_S:-120}" git -C "$NODE_DIR/repo" reset --hard origin/main --quiet; then
      ok "repo present ($NODE_DIR/repo), synced to origin/main"
    else
      no "repo fetch/reset FAILED or timed out ($NODE_DIR/repo)"; return 1
    fi
  else
    if [ "$DRY" = 1 ]; then
      echo "  DRY: git clone --quiet '$REPO_URL' '$NODE_DIR/repo'  # authenticated via GH_TOKEN from $CREDS if present"
    else
      [ -z "$gh_token" ] && info HOME "no GH_TOKEN in $CREDS; attempting unauthenticated clone (public repos only)"
      if run_timeout "${CHUMP_GIT_TIMEOUT_S:-120}" git clone --quiet "$clone_url" "$NODE_DIR/repo"; then
        ok "repo cloned: $NODE_DIR/repo"
      else
        no "repo clone FAILED: $NODE_DIR/repo"; return 1
      fi
    fi
  fi
  ok "node home: $NODE_DIR"
}

# ---------- 3. CREDS ----------
REQUIRED_CRED_KEYS="CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN"
# INFRA-3657: DISCORD_TOKEN is optional (not every node needs to page) but is
# self-provisioned the same zero-touch way when supplied, so the walk-away
# pager path (scripts/discord.sh) actually has a token to read once the
# operator does wire one in — no separate manual step or editor.
OPTIONAL_CRED_KEYS="DISCORD_TOKEN CHUMP_TEAM_URL CHUMP_TEAM_API_KEY"

# A node remains useful before an LLM provider is configured: it can keep a
# verified binary current, expose local state, retain its health signals, and
# accept a provider later. Keep "provider-ready" separate from "installed" so
# a token outage never turns first boot into a false failure. The explicit
# --control-plane-only switch also covers a present-but-exhausted subscription.
provider_creds_ready() {
  [ -f "$CREDS" ] || return 1
  local k
  for k in $REQUIRED_CRED_KEYS; do
    grep -qE "^(export )?$k=.+" "$CREDS" || return 1
  done
  return 0
}

worker_execution_enabled() {
  [ "$CONTROL_PLANE_ONLY" != 1 ] || return 1
  if [ -n "${CHUMP_NODE_WORK_ENABLED:-}" ]; then
    [ "$CHUMP_NODE_WORK_ENABLED" = 1 ]
  else
    provider_creds_ready
  fi
}

# Zero-touch acquire (INFRA-3629): materialize $CREDS from --creds-file or
# $CHUMP_BOOTSTRAP_CREDS. Never echoes secret VALUES — only which source was
# used. Leaves an existing file untouched (idempotent, no clobber).
materialize_creds() {
  [ -f "$CREDS" ] && return 0
  if [ -n "$CREDS_FILE" ]; then
    [ -f "$CREDS_FILE" ] || { no "--creds-file not found: $CREDS_FILE"; return 1; }
    if [ "$DRY" = 1 ]; then echo "  DRY: install '$CREDS_FILE' -> '$CREDS' (mode 600)"; return 0; fi
    mkdir -p "$STATE_DIR"
    install -m 600 "$CREDS_FILE" "$CREDS"
    ok "materialized creds from --creds-file (path only; values not logged)"
  elif [ -n "${CHUMP_BOOTSTRAP_CREDS:-}" ]; then
    if [ "$DRY" = 1 ]; then echo "  DRY: write \$CHUMP_BOOTSTRAP_CREDS -> '$CREDS' (mode 600)"; return 0; fi
    mkdir -p "$STATE_DIR"
    ( umask 077; printf '%s\n' "$CHUMP_BOOTSTRAP_CREDS" > "$CREDS" )
    ok "materialized creds from \$CHUMP_BOOTSTRAP_CREDS (env var; values not logged)"
  fi
}

# Interactive acquire (INFRA-3688): prompt user for GitHub auth method and
# run claude setup-token to obtain CLAUDE_CODE_OAUTH_TOKEN. Writes
# ~/.chump/providers.env with CHUMP_AUTH_MODE=oauth and the acquired tokens.
# Never echoes secret values to stdout or logs. File created with mode 0600.
# Returns 0 on success, non-zero on failure.
acquire_creds() {
  [ -f "$CREDS" ] && { ok "creds already exist at $CREDS — skipping acquire"; return 0; }
  echo
  printf '\033[1m=== Interactive Credential Acquisition ===\033[0m\n'
  printf 'No pre-supplied creds found. Two ways to authenticate:\n'
  printf '  1) GitHub Device Flow (gh auth login) — recommended\n'
  printf '  2) Paste a GH_TOKEN directly\n'
  printf '\n'
  local choice=""
  while [ -z "$choice" ]; do
    printf 'Choose method [1/2]: '
    read -r choice
    case "$choice" in
      1|2) ;;
      *) choice="";;
    esac
  done

  local gh_token=""
  if [ "$choice" = 1 ]; then
    info ACQUIRE "running gh auth login --hostname github.com --git-protocol https --web"
    if command -v gh >/dev/null 2>&1; then
      gh auth login --hostname github.com --git-protocol https --web || {
        no "gh auth login failed"
        return 1
      }
      gh_token="$(gh auth token 2>/dev/null)" || {
        no "failed to retrieve GH_TOKEN from gh"
        return 1
      }
    else
      no "gh CLI not found — install GitHub CLI first, then re-run"
      return 1
    fi
  else
    printf 'Paste your GitHub personal access token (will not echo): '
    stty -echo 2>/dev/null
    read -r gh_token
    stty echo 2>/dev/null
    printf '\n'
    if [ -z "$gh_token" ]; then
      no "empty token — aborting"
      return 1
    fi
  fi

  local oauth_token=""
  if command -v claude >/dev/null 2>&1; then
    info ACQUIRE "running claude setup-token to obtain CLAUDE_CODE_OAUTH_TOKEN..."
    oauth_token="$(claude setup-token 2>/dev/null)" || true
    [ -z "$oauth_token" ] && no "claude setup-token failed or returned empty — falling back to manual entry"
  else
    no "claude CLI not found — falling back to manual entry"
  fi

  if [ -z "$oauth_token" ]; then
    printf 'Paste your CLAUDE_CODE_OAUTH_TOKEN (will not echo): '
    stty -echo 2>/dev/null
    read -r oauth_token
    stty echo 2>/dev/null
    printf '\n'
  fi

  if [ -z "$oauth_token" ]; then
    no "empty CLAUDE_CODE_OAUTH_TOKEN — aborting"
    return 1
  fi

  # Write providers.env with mode 0600, never echoing values
  mkdir -p "$STATE_DIR"
  (
    umask 077
    cat > "$CREDS" <<EOF
CHUMP_AUTH_MODE=oauth
GH_TOKEN=$gh_token
CLAUDE_CODE_OAUTH_TOKEN=$oauth_token
EOF
  )
  chmod 600 "$CREDS" 2>/dev/null || true
  ok "creds written to $CREDS (mode 600; values not logged)"
  return 0
}

# ---------- 3b. CREDS CHECK ----------
check_creds() {
  materialize_creds
  [ -f "$CREDS" ] || { no "creds missing: $CREDS (supply --creds-file PATH or \$CHUMP_BOOTSTRAP_CREDS)"; return 1; }
  local missing="" k
  for k in $REQUIRED_CRED_KEYS; do
    grep -qE "^(export )?$k=.+" "$CREDS" || missing="$missing $k"
  done
  [ -n "$missing" ] && { no "creds present but missing keys:$missing — supply via --creds-file/\$CHUMP_BOOTSTRAP_CREDS and re-run"; return 1; }
  ok "creds ok ($(grep -cE '^(export )?[A-Z_]+=' "$CREDS") keys, incl OAuth+GH, mode $(stat -c %a "$CREDS" 2>/dev/null || stat -f %Lp "$CREDS" 2>/dev/null))"
  local opt_missing=""
  for k in $OPTIONAL_CRED_KEYS; do
    grep -qE "^(export )?$k=" "$CREDS" || opt_missing="$opt_missing $k"
  done
  # INFRA-3657 AC2: DISCORD_TOKEN missing is a WARNING, not a failure — the
  # node is fully installed either way, but the walk-away pager is dead
  # until it's supplied. Surface loudly so that's not discovered at 3am.
  [ -n "$opt_missing" ] && info CREDS "optional creds not set:$opt_missing (pager dead without DISCORD_TOKEN — supply via --creds-file/\$CHUMP_BOOTSTRAP_CREDS)"
}

# ---------- 3c. NODE ENV (INFRA-3703: canonical store env file) ----------
# Writes ~/.chump/node.env with the canonical store settings every organ and
# later step needs, then sources it so subsequent phases (SEED/SUBSTRATE/
# ORGANS) all resolve the same values instead of re-deriving them. Values come
# from the environment first, then providers.env, then the canonical defaults
# already pinned above — and the API-key value is never echoed to stdout/logs
# (written straight to the file).
write_node_env() {
  local node_env="$STATE_DIR/node.env"
  local team_url="${CHUMP_TEAM_URL:-}"
  local team_api_key="${CHUMP_TEAM_API_KEY:-}"
  if [ -z "$team_url" ] && [ -f "$CREDS" ]; then
    team_url="$(grep -E '^(export )?CHUMP_TEAM_URL=' "$CREDS" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_TEAM_URL=//; s/^"(.*)"$/\1/')"
  fi
  if [ -z "$team_api_key" ] && [ -f "$CREDS" ]; then
    team_api_key="$(grep -E '^(export )?CHUMP_TEAM_API_KEY=' "$CREDS" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_TEAM_API_KEY=//; s/^"(.*)"$/\1/')"
  fi
  local _chump_localhost="localhost"
  team_url="${team_url:-http://${_chump_localhost}:3000}"
  local store_backend="${CHUMP_STORE_BACKEND:-postgrest}"
  local work_enabled=0 node_mode="control-plane"
  if [ "$CONTROL_PLANE_ONLY" != 1 ] && provider_creds_ready; then
    work_enabled=1
    node_mode="work-ready"
  fi
  mkdir -p "$STATE_DIR"
  ( umask 077
    {
      printf 'export CHUMP_STATE_DIR=%s\n' "$STATE_DIR"
      printf 'export CHUMP_TEAM_URL=%s\n' "$team_url"
      printf 'export CHUMP_TEAM_API_KEY=%s\n' "$team_api_key"
      printf 'export CHUMP_STORE_BACKEND=%s\n' "$store_backend"
      # RESILIENT-1083: persist this node's role OUTSIDE the repo so the recurring
      # organ-reconcile can self-scope to it (and survive `git reset --hard`).
      printf 'export CHUMP_NODE_ROLE=%s\n' "$ROLE"
      # OOTB contract: safe control-plane operation is valid without a provider;
      # workers start only after a credentialed re-install enables work mode.
      printf 'export CHUMP_NODE_WORK_ENABLED=%s\n' "$work_enabled"
      printf 'export CHUMP_NODE_MODE=%s\n' "$node_mode"
    } > "$node_env"
  )
  # Source now so subsequent phases inherit the canonical settings.
  # shellcheck disable=SC1090
  . "$node_env"
  export CHUMP_STATE_DIR CHUMP_TEAM_URL CHUMP_TEAM_API_KEY CHUMP_STORE_BACKEND CHUMP_NODE_ROLE CHUMP_NODE_WORK_ENABLED CHUMP_NODE_MODE
  ok "node.env written + sourced: $node_env (mode=$CHUMP_NODE_MODE)"
}

# ---------- 4. BINARY ----------
# sha256 of a file as lowercase hex (host-agnostic: coreutils | BSD/macOS).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else return 1; fi
}

# Map this host to the cargo target triple the release workflow (dist-workspace.toml
# `targets`) publishes a pre-built artifact for, or fail (no artifact → build).
# Honors detect_host()'s $ARCH/$OS; termux/android has no release artifact.
host_target_triple() {
  case "${HOST_KIND:-}" in termux) return 1;; esac
  local arch os
  case "${ARCH:-}" in
    x86_64|amd64) arch=x86_64;;
    aarch64|arm64) arch=aarch64;;
    *) return 1;;
  esac
  case "${OS:-}" in
    Linux) os=unknown-linux-gnu;;
    Darwin) os=apple-darwin;;
    *) return 1;;
  esac
  printf '%s-%s\n' "$arch" "$os"
}

# Provenance gate — the heart of the false-pass fix. A binary at $1 is trusted
# ONLY if it is one of:
#   (a) release-sourced: its on-disk sha256 still matches the sha recorded when
#       fetch_release_binary downloaded + published-checksum-verified it, or
#   (b) built-from-this-repo-HEAD: its embedded build SHA (`chump --version`,
#       baked by build.rs) is a prefix of the cloned repo's HEAD commit.
# An arbitrary/inherited/stale `chump` (no marker, or SHA that matches neither)
# FAILS — it must never be accepted as "INSTALLED".
binary_provenance_ok() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  if [ -f "$bin.provenance" ] && grep -q '^source=release' "$bin.provenance" 2>/dev/null; then
    local want got
    want="$(grep '^binsha256=' "$bin.provenance" 2>/dev/null | cut -d= -f2)"
    got="$(sha256_hex "$bin")"
    [ -n "$want" ] && [ "$want" = "$got" ] && return 0
    return 1
  fi
  local head_full ver_sha
  head_full="$(git -C "$NODE_DIR/repo" rev-parse HEAD 2>/dev/null)"
  ver_sha="$("$bin" --version 2>/dev/null | grep -oiE '[0-9a-f]{7,40}' | head -1)"
  if [ -n "$head_full" ] && [ -n "$ver_sha" ] && [ "$ver_sha" != "unknown" ]; then
    case "$head_full" in
      "$ver_sha"*)
        printf 'source=build\nsha=%s\nverified=%s\n' \
          "$ver_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$bin.provenance" 2>/dev/null || true
        return 0;;
    esac
  fi
  return 1
}

# Export GH_TOKEN from providers.env (if present) so `gh api` / `gh run
# download` can authenticate on a bare box — Actions artifacts require a token
# even for public repos. Never echoes the value.
_load_gh_token_for_fetch() {
  [ -n "${GH_TOKEN:-}" ] && return 0
  [ -f "$CREDS" ] || return 0
  local t; t="$(grep -E '^(export )?GH_TOKEN=' "$CREDS" 2>/dev/null | tail -1 | sed -E 's/^(export )?GH_TOKEN=//; s/^"(.*)"$/\1/')"
  [ -n "$t" ] && export GH_TOKEN="$t"
  return 0
}

# PRIMARY fast path: pull the HEAD-exact pre-built binary that the fleet's free
# GH-hosted CI already built for the repo's checked-out commit
# (.github/workflows/build-fleet-binaries.yml → per-SHA Actions artifact
# `chump-<target>-<full-sha>`), verify its sha256 + that `chump --version`
# embeds that commit, and install it to $BIN — instead of a multi-minute cold
# compile. This is the SAME artifact source scripts/ops/node-refresh-chump.sh
# uses for the running-node refresh path (mine-before-build). HEAD-exact, so
# the installed binary's provenance is "built-from-this-repo-HEAD" — no
# staleness. Returns 1 (caller falls back) on any miss: fetch disabled, no gh,
# unknown arch, no successful run for the SHA, or integrity/version mismatch.
#   CHUMP_BINARY_NO_FETCH=1      skip all pre-built fetch (force build-from-source)
#   CHUMP_ARTIFACT_WORKFLOW=...  workflow file to query (default build-fleet-binaries.yml)
fetch_ci_artifact_binary() {
  [ "${CHUMP_BINARY_NO_FETCH:-0}" = 1 ] && { info BINARY "pre-built fetch disabled (CHUMP_BINARY_NO_FETCH=1) — building from source"; return 1; }
  local triple
  triple="$(host_target_triple)" || { info BINARY "no pre-built target triple for ${OS:-?}/${ARCH:-?} — building from source"; return 1; }
  command -v gh >/dev/null 2>&1 || { info BINARY "gh unavailable — cannot pull CI artifact; trying next source"; return 1; }
  sha256_hex /dev/null >/dev/null 2>&1 || { info BINARY "no sha256 tool — cannot verify CI artifact; trying next source"; return 1; }
  [ -d "$NODE_DIR/repo/.git" ] || { info BINARY "no repo checkout — cannot resolve HEAD for CI artifact; trying next source"; return 1; }
  _load_gh_token_for_fetch

  local slug; slug="$(printf '%s' "$REPO_URL" | sed -E 's#^https?://github.com/##; s#\.git$##')"
  local full_sha short_sha
  full_sha="$(git -C "$NODE_DIR/repo" rev-parse HEAD 2>/dev/null)"
  short_sha="$(git -C "$NODE_DIR/repo" rev-parse --short=12 HEAD 2>/dev/null)"
  [ -n "$full_sha" ] || { info BINARY "cannot resolve repo HEAD — trying next source"; return 1; }

  # Idempotent accept: $BIN already built-from-this-HEAD (release/reset re-run).
  if [ -x "$BIN" ] && binary_provenance_ok "$BIN"; then
    ok "binary already present + provenance verified for HEAD — no fetch needed: $BIN"
    return 0
  fi

  local wf="${CHUMP_ARTIFACT_WORKFLOW:-build-fleet-binaries.yml}"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: gh api runs?head_sha=$short_sha&status=success -> gh run download chump-$triple-$full_sha, sha256+version verify, install -> $BIN"
    return 0
  fi

  local run_id
  run_id="$(gh api "repos/$slug/actions/workflows/$wf/runs?head_sha=$full_sha&status=success&per_page=1" \
    --jq '.workflow_runs[0].id' 2>/dev/null | grep -vE '^(null)?$' || true)"
  if [ -z "$run_id" ]; then
    info BINARY "no successful $wf run for HEAD $short_sha — trying next source"
    return 1
  fi
  local dl="$NODE_DIR/bin/.dlci" aname="chump-${triple}-${full_sha}"
  run "rm -rf '$dl'"; run "mkdir -p '$dl'"
  info BINARY "pulling CI artifact $aname (run $run_id) — download, not compile"
  if ! gh run download "$run_id" --repo "$slug" -n "$aname" --dir "$dl" >/dev/null 2>&1; then
    no "CI artifact download failed ($aname, run $run_id) — trying next source"; rm -rf "$dl"; return 1
  fi
  local pulled="$dl/chump"
  [ -f "$pulled" ] || { no "CI artifact held no chump binary — trying next source"; rm -rf "$dl"; return 1; }
  # Integrity: sha256 the artifact ships must match the binary.
  if [ -f "$dl/chump.sha256" ]; then
    local want got; want="$(awk '{print $1}' "$dl/chump.sha256" | head -1)"; got="$(sha256_hex "$pulled")"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      no "CI artifact sha256 MISMATCH (published=$want computed=$got) — refusing, trying next source"; rm -rf "$dl"; return 1
    fi
    ok "sha256 verified: $aname ($got)"
  fi
  chmod +x "$pulled" 2>/dev/null || true
  run "mkdir -p '$NODE_DIR/bin'"
  install -m 755 "$pulled" "$BIN" 2>/dev/null || { cp -f "$pulled" "$BIN"; chmod +x "$BIN"; }
  # Provenance: --version must embed the HEAD commit we resolved above.
  local warm; warm="$("$BIN" --version 2>&1)"
  case "$warm" in
    *"$short_sha"*) ok "CI artifact installed + HEAD-verified: $BIN ($warm)";;
    *) no "CI artifact --version ('$warm') does not embed HEAD $short_sha — discarding, trying next source"; rm -f "$BIN"; rm -rf "$dl"; return 1;;
  esac
  printf 'source=ci-artifact\nrun_id=%s\ntriple=%s\nsha=%s\ninstalled=%s\n' \
    "$run_id" "$triple" "$short_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BIN.provenance"
  rm -rf "$dl"
  return 0
}

# SECONDARY pre-built path (opt-in): fetch a SHA-pinned cargo-dist GitHub
# *Release* tarball for this host's triple and verify its sha256 against the
# published checksum. OFF by default: published releases can lag origin/main by
# months (v0.1.2 vs 0.2.0), so silently installing one would freshly-install a
# STALE binary — worse than building current. Enable only when a fast install
# matters more than currency (CHUMP_BINARY_ALLOW_STALE_RELEASE=1).
#   CHUMP_RELEASE_TAG=<tag>     pin a specific release (default: latest published)
#   CHUMP_BINARY_NO_FETCH=1     skip the fetch entirely (force build-from-source)
fetch_release_binary() {
  [ "${CHUMP_BINARY_NO_FETCH:-0}" = 1 ] && { info BINARY "release fetch disabled (CHUMP_BINARY_NO_FETCH=1) — building from source"; return 1; }
  [ "${CHUMP_BINARY_ALLOW_STALE_RELEASE:-0}" = 1 ] || { info BINARY "stale-release fallback off (set CHUMP_BINARY_ALLOW_STALE_RELEASE=1 to enable) — building from source"; return 1; }
  local triple
  triple="$(host_target_triple)" || { info BINARY "no pre-built target triple for ${OS:-?}/${ARCH:-?} — building from source"; return 1; }
  command -v tar  >/dev/null 2>&1 || { info BINARY "tar missing — cannot use pre-built; building"; return 1; }
  command -v curl >/dev/null 2>&1 || { info BINARY "curl missing — cannot fetch pre-built; building"; return 1; }
  sha256_hex /dev/null >/dev/null 2>&1 || { info BINARY "no sha256 tool — cannot verify pre-built; building"; return 1; }

  local slug; slug="$(printf '%s' "$REPO_URL" | sed -E 's#^https?://github.com/##; s#\.git$##')"

  # Resolve the pinned tag: explicit env > latest published release.
  local tag="${CHUMP_RELEASE_TAG:-}"
  if [ -z "$tag" ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      tag="$(gh release view --repo "$slug" --json tagName -q .tagName 2>/dev/null)"
    fi
    [ -z "$tag" ] && tag="$(curl -fsSL "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4)"
  fi
  [ -n "$tag" ] && [ "$tag" != "null" ] || { info BINARY "no published release for $slug — building from source"; return 1; }

  # Idempotent accept: a prior release install we can re-verify by sha (no
  # re-download on every reset-loop tick).
  if [ -x "$BIN" ] && [ -f "$BIN.provenance" ] && grep -q '^source=release' "$BIN.provenance" 2>/dev/null; then
    local pv_tag pv_sha now_sha
    pv_tag="$(grep '^tag=' "$BIN.provenance" | cut -d= -f2)"
    pv_sha="$(grep '^binsha256=' "$BIN.provenance" | cut -d= -f2)"
    now_sha="$(sha256_hex "$BIN")"
    if [ "$pv_tag" = "$tag" ] && [ -n "$pv_sha" ] && [ "$pv_sha" = "$now_sha" ]; then
      ok "pre-built release $tag already installed + sha-verified: $BIN"
      return 0
    fi
  fi

  local asset="chump-${triple}.tar.xz"
  local dl="$NODE_DIR/bin/.dl"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: download $asset (+ .sha256) from $slug@$tag, sha256-verify, install -> $BIN"
    return 0
  fi
  run "rm -rf '$dl'"; run "mkdir -p '$dl'"

  local base="https://github.com/$slug/releases/download/$tag"
  info BINARY "fetching pre-built $asset ($slug@$tag) — download, not compile"
  if ! curl -fsSL "$base/$asset" -o "$dl/$asset"; then
    no "download failed: $base/$asset — falling back to build"; rm -rf "$dl"; return 1
  fi
  if ! curl -fsSL "$base/$asset.sha256" -o "$dl/$asset.sha256"; then
    no "checksum download failed: $base/$asset.sha256 — falling back to build"; rm -rf "$dl"; return 1
  fi
  local want got
  want="$(awk '{print $1}' "$dl/$asset.sha256" | head -1)"
  got="$(sha256_hex "$dl/$asset")"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    no "sha256 MISMATCH for $asset (published=$want computed=$got) — refusing unverified binary, building instead"
    rm -rf "$dl"; return 1
  fi
  ok "sha256 verified: $asset ($got)"
  if ! tar -xJf "$dl/$asset" -C "$dl" 2>/dev/null; then
    no "extract failed for $asset — building"; rm -rf "$dl"; return 1
  fi
  local built="$dl/chump-${triple}/chump"
  [ -f "$built" ] || built="$(find "$dl" -type f -name chump 2>/dev/null | head -1)"
  if [ ! -f "$built" ]; then
    no "no chump binary inside $asset — building"; rm -rf "$dl"; return 1
  fi
  run "mkdir -p '$NODE_DIR/bin'"
  install -m 755 "$built" "$BIN" 2>/dev/null || { cp -f "$built" "$BIN"; chmod +x "$BIN"; }
  # WARM smoke: the downloaded binary must answer --version before it's trusted.
  local warm; warm="$("$BIN" --version 2>&1)"
  if [ -z "$warm" ]; then no "WARM smoke failed on downloaded binary — discarding"; rm -f "$BIN"; rm -rf "$dl"; return 1; fi
  local binsha; binsha="$(sha256_hex "$BIN")"
  printf 'source=release\ntag=%s\ntriple=%s\nasset_sha256=%s\nbinsha256=%s\ninstalled=%s\n' \
    "$tag" "$triple" "$got" "$binsha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BIN.provenance"
  rm -rf "$dl"
  ok "pre-built release binary installed + sha-verified: $BIN ($warm)"
  return 0
}

ensure_binary() {
  # (A) An already-present $BIN is accepted ONLY with valid provenance
  # (release-verified OR built-from-repo-HEAD). A stray/foreign/stale/inherited
  # binary is discarded, never trusted — this closes the freeload false-pass
  # where the installer symlinked any `chump` on PATH and reported INSTALLED ✓
  # without ever building or verifying provenance (COTG node-install).
  if [ -x "$BIN" ]; then
    if binary_provenance_ok "$BIN"; then
      ok "binary present + provenance verified: $BIN"
      return 0
    fi
    no "existing $BIN has no valid provenance (foreign/stale) — discarding, will fetch/build a verified one"
    run "rm -f '$BIN' '$BIN.provenance'"
  fi
  # (B) Fast path: HEAD-exact pre-built CI artifact (download + verify), then
  # the opt-in stale-release tarball. Never a silent stale install by default.
  if fetch_ci_artifact_binary; then
    return 0
  fi
  if fetch_release_binary; then
    return 0
  fi
  # (C) Fallback: build from the cloned repo HEAD, then gate on provenance.
  build_binary_from_repo || return 1
  if binary_provenance_ok "$BIN"; then
    ok "binary built from repo HEAD + provenance verified: $BIN"
    return 0
  fi
  no "built binary failed provenance gate ($BIN) — refusing to report INSTALLED"
  return 1
}

# No binary found: build it from $NODE_DIR/repo. Reuses the resolve+build
# logic already hardened in refresh-runner-binary.sh (linux/macos — worktree
# @ origin/main, warm shared target dir, codesign) and build-android.sh
# (termux cross-compile) instead of reimplementing cargo invocation here.
# Gates the artifact behind a WARM smoke (mirrors deploy-pixel-node.sh) before
# it is ever symlinked to $BIN.
build_binary_from_repo() {
  local repo="$NODE_DIR/repo"
  if [ ! -d "$repo/.git" ]; then
    no "no binary and no repo checkout at $repo — clone chump there first"
    return 1
  fi
  local staged="$NODE_DIR/bin/chump.new"
  run "mkdir -p '$LOG_DIR'"
  local build_log="$LOG_DIR/binary-build-$(date -u +%Y%m%dT%H%M%SZ).log"

  if [ "$DRY" = 1 ]; then
    case "$HOST_KIND" in
      termux) echo "  DRY: (cd '$repo' && bash scripts/setup/build-android.sh)  # then cp -> $staged";;
      *) echo "  DRY: CHUMP_REPO_ROOT='$repo' CHUMP_RUNNER_BIN='$staged' bash '$repo/scripts/setup/refresh-runner-binary.sh'";;
    esac
    echo "  DRY: WARM smoke ('$staged' --version) before symlink -> $BIN"
    return 0
  fi

  # RESILIENT-1015: a cold source build on a 2-core box is the slowest legit
  # phase in the whole installer — bound it so a wedged/thrashing compile
  # can't hang the one-shot install forever. CHUMP_BINARY_BUILD_TIMEOUT_S
  # default (900s) is generous for a 2-core cold build but finite.
  info BINARY "no binary found — building from $repo (log: $build_log, budget ${CHUMP_BINARY_BUILD_TIMEOUT_S:-900}s)"
  case "$HOST_KIND" in
    termux)
      if ! run_timeout "${CHUMP_BINARY_BUILD_TIMEOUT_S:-900}" bash -c "cd '$repo' && bash scripts/setup/build-android.sh" >"$build_log" 2>&1; then
        no "android cross-build failed or timed out — see $build_log"
        return 1
      fi
      local built="$repo/target-android/aarch64-linux-android/release/chump"
      [ -f "$built" ] || built="$repo/target/aarch64-linux-android/release/chump"
      if [ ! -f "$built" ]; then
        no "build reported success but no binary at $built — see $build_log"
        return 1
      fi
      cp -f "$built" "$staged"
      ;;
    *)
      if ! CHUMP_REPO_ROOT="$repo" CHUMP_RUNNER_BIN="$staged" \
           run_timeout "${CHUMP_BINARY_BUILD_TIMEOUT_S:-900}" bash "$repo/scripts/setup/refresh-runner-binary.sh" >"$build_log" 2>&1; then
        no "cargo build failed or timed out — see $build_log"
        return 1
      fi
      if [ ! -x "$staged" ]; then
        no "build reported success but binary missing at $staged — see $build_log"
        return 1
      fi
      ;;
  esac
  chmod +x "$staged"

  # WARM: the built binary must answer a trivial prompt before it's trusted.
  info BINARY "warming freshly built binary (WARM smoke)..."
  local warm_out
  warm_out="$("$staged" --version 2>&1)"
  if [ -z "$warm_out" ]; then
    no "WARM smoke failed — '$staged --version' produced no output; see $build_log"
    rm -f "$staged"
    return 1
  fi
  ok "WARM smoke ok: $warm_out"

  mv -f "$staged" "$BIN"
  chmod +x "$BIN"
  ok "binary built + warm-verified: $BIN"
}

# ---------- 4b. SEED (INFRA-3633: first-boot canonical-store bootstrap) ----------
# One-shot YAML -> DB sync so a freshly-cloned box boots with the real
# backlog (docs/gaps/*.yaml) instead of an empty state.db. Reuses
# `chump gap sync --pull`, which already respects the INFRA-3606
# terminal-status guard (never reverts a done/superseded/etc row back to
# open), so this is safe to re-run on every install.
ensure_seed() {
  local gaps_dir="$NODE_DIR/repo/docs/gaps"
  # Only the provenance-verified $BIN the BINARY phase installed — never a
  # stray on-PATH chump (that was the freeload path this ship killed).
  local bin=""
  [ -x "$BIN" ] && { bin="$BIN"; }
  if [ -z "$bin" ]; then
    info SEED "no chump binary yet — skipping (BINARY phase hasn't installed one); re-run after it does"
    return 0
  fi
  if [ ! -d "$gaps_dir" ]; then
    info SEED "no $gaps_dir — skipping (repo clone missing docs/gaps?)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    echo "  DRY: '$bin' gap sync --pull --state-db '$STATE_DB' --gaps-dir '$gaps_dir' --json"
    return 0
  fi
  local out
  if out="$(run_timeout "${CHUMP_SEED_TIMEOUT_S:-60}" "$bin" gap sync --pull --state-db "$STATE_DB" --gaps-dir "$gaps_dir" --json 2>&1)"; then
    ok "seed: canonical store synced from docs/gaps ($out)"
  else
    # AC2: substrate-unreachable (missing state.db dir, locked db, etc.) is a
    # clear warning, not a hard install failure — the node is still usable
    # without a seeded backlog (organs/CREDS/BINARY phases already ran).
    no "seed: gap sync --pull FAILED — substrate unreachable, continuing without seed"
    info SEED "$out"
  fi
}

# ---------- 5. ORGANS (from manifest) ----------
brain_organs() {  # name|exec
  echo "node-heartbeat|$ORGAN_DIR/node-heartbeat.sh"
}
muscle_organs() { echo "worker|$ORGAN_DIR/worker.sh"; }
# INFRA-3650 (PEER-HEAL-03): organs every role needs regardless of brain vs
# muscle — currently just the process-organ heal loop (revives raw
# background bash procs like almanac-vision-keeper that aren't systemd
# units, so it must land on every owned node, not be a hand-op per role).
common_organs() {
  echo "process-organ-heal|$ORGAN_DIR/process-organ-heal.sh"
  # RESILIENT-1052: the anti-Memento fleet-health sentinel — scan+heal failed
  # chump units and re-enable inactive healers, and heartbeat so a dead
  # sentinel is itself visible. Common to every role: the exact hole it closes
  # (cuphead+mugman running with zero drift protection and no alarm) was a
  # per-node one, so it must land on every owned node, not be a hand-op.
  echo "fleet-health-sentinel|$ORGAN_DIR/fleet-health-sentinel.sh"
}
# RESILIENT-746: maps --role to the organ-manifest.txt role= tags that node
# should carry. brain = coordination/registry/reporting (everything the
# manifest doesn't tag muscle); muscle = the worker/ship-code organs only
# (per docs/process/COTG_NODE_INSTALL.md's role split); all = every tagged
# role (empty filter = organ-reconcile.sh applies the whole manifest).
organ_role_filter() {
  case "$ROLE" in
    brain) echo "brain,data,janitor,trust";;
    muscle) echo "muscle";;
    all) echo "";;
  esac
}
# RESILIENT-746 / RESILIENT-318: the ORGANS phase previously stopped at the
# two hand-coded organs above (node-heartbeat, process-organ-heal) and NEVER
# installed the role's real organ set from scripts/ops/organ-manifest.txt —
# the exact half-built hole from the helsinki teardown (docs said "install
# the role's organ set... from a manifest", the code never called the
# manifest-driven reconciler). This resolves + runs organ-reconcile.sh
# --apply, scoped to this node's role, so a fresh install converges to the
# SAME manifest-declared organ set the primary node's own reconcile timer
# enforces — reproducible, not hand-`cp`.
reconcile_role_organs() {
  local reconcile="$NODE_DIR/repo/scripts/ops/organ-reconcile.sh"
  [ -f "$reconcile" ] || reconcile="$(dirname "$0")/../ops/organ-reconcile.sh"
  if [ ! -f "$reconcile" ]; then
    info ORGANS "organ-reconcile.sh not found — skipping manifest-driven organ set"
    return 0
  fi
  local rf; rf="$(organ_role_filter)"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: CHUMP_ORGAN_RECONCILE_ROLE='$rf' bash '$reconcile' --apply"
    return 0
  fi
  info ORGANS "reconciling manifest organ set (role=$ROLE, role-filter=[${rf:-all}])..."
  if CHUMP_ORGAN_RECONCILE_ROLE="$rf" run_timeout "${CHUMP_ORGAN_RECONCILE_TIMEOUT_S:-90}" bash "$reconcile" --apply \
       >"$LOG_DIR/organ-reconcile-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1; then
    ok "manifest organ set reconciled (role=$ROLE)"
  else
    no "manifest organ set reconcile had issues — see $LOG_DIR/organ-reconcile-*.log; non-fatal (e.g. non-root), re-run to retry"
  fi
}

# RESILIENT-1055: PLACE the role's manifest unit FILES before reconcile enables
# them. THE ROOT BUG this closes: reconcile_role_organs above only runs
# `systemctl enable --now <unit>` — it never COPIES the tracked unit file into
# /etc/systemd/system. On a fresh box those files don't exist, so every
# manifest organ enable-failed -> `backoff:` forever, and bring-up was
# incomplete no matter how many times it ran (the exact cuphead/mugman symptom:
# ~17 manifest units with NO file on the box, reconcile logging perpetual
# backoff). This function copies each role-matched manifest unit (and its paired
# .service/.timer sibling) from scripts/dispatch/, HOST-REWRITTEN via the shared
# organ-unit-install-lib.sh, into /etc/systemd/system — so `enable --now` finds
# a real, correctly-pathed unit. It also:
#   * rewrites the tracked units' baked ~/Projects/chump repo path to this box's
#     actual $NODE_DIR/repo (node-install clones there, not ~/Projects/chump),
#   * symlinks the installed binary onto the organs' PATH ($RUN_HOME/.cargo/bin)
#     so `requires=bin:chump` organs resolve and organ ExecStarts find `chump`,
#   * always places chump-organ-reconcile.{service,timer} (the manifest
#     self-excludes it) and scopes ITS recurring reconcile to this node's role
#     via a drop-in, so the timer-driven self-heal converges to the role roster
#     instead of the whole manifest (which would re-add out-of-role organs).
# Systemd hosts only; needs root to write /etc/systemd/system (warns + skips
# non-root, non-fatal — reconcile_role_organs degrades the same way).
# RESILIENT-1097: break the chicken-and-egg that left ~18 manifest organs
# un-installable on cuphead. place_role_unit_files() below needs root to
# write /etc/systemd/system and skips ENTIRELY when the install ran as a
# non-root user; reconcile_role_organs() (organ-reconcile.sh) also runs as
# that same non-root user and can only `enable --now` a unit that already
# has a file on disk, so every role-matched organ backs off forever
# ("WARN could not enable --now ... +7 more"). chump-organ-deploy.timer
# (RESILIENT-374, User=root) is the ONE organ built to break exactly this:
# once it is armed, its OWN root-run cycles call install-helsinki-atc.sh
# --auto AS ROOT and place the REST of the role roster. So bootstrapping
# just this one keystone unit via `sudo` (when available) unsticks the
# whole roster on the very next timer tick — reproducible on any fresh box,
# no hand-run installer, no full-root re-install required.
bootstrap_organ_deploy_via_sudo() {
  local repo="$1" lib_manifest="$2" lib_unit="$3" dispatch="$4"
  # chump-organ-deploy.timer is role=janitor in the manifest — only brain/all
  # role-filters include janitor (organ_role_filter), so a muscle-only node
  # has no business installing it.
  case "$ROLE" in brain|all) ;; *) return 0;; esac
  command -v sudo >/dev/null 2>&1 || {
    info ORGANS "no sudo on PATH — cannot bootstrap chump-organ-deploy.timer, role roster will stay dark until a root install"
    return 0
  }
  if ! sudo -n true 2>/dev/null; then
    info ORGANS "no passwordless sudo for $(whoami 2>/dev/null || id -un) — cannot bootstrap chump-organ-deploy.timer; grant NOPASSWD sudo for systemctl/install, or run install as root once"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$lib_manifest"; . "$lib_unit"
  local run_user run_home; run_user="$(organ_unit_run_user "$repo")"; run_home="$(organ_unit_run_home "$run_user")"
  local dest_dir="${CHUMP_NODE_INSTALL_SYSTEMD_DIR:-/etc/systemd/system}"
  local tmp; tmp="$(mktemp -d)"
  local placed=0 f
  for f in chump-organ-deploy.service chump-organ-deploy.timer; do
    [ -f "$dispatch/$f" ] || continue
    if organ_unit_host_rewrite "$dispatch/$f" "$tmp/$f" "$run_user" "$run_home" 1 "$repo" \
        && sudo mkdir -p "$dest_dir" \
        && sudo install -m 644 "$tmp/$f" "$dest_dir/$f"; then
      placed=$((placed + 1))
    fi
  done
  rm -rf "$tmp"
  if [ "$placed" -gt 0 ]; then
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl enable --now chump-organ-deploy.timer 2>/dev/null || true
    ok "bootstrapped chump-organ-deploy.timer via sudo ($placed unit file(s) placed) — its own root cycle will place the rest of the role roster"
  else
    info ORGANS "chump-organ-deploy unit files not found under $dispatch — cannot bootstrap"
  fi
}
place_role_unit_files() {
  [ "${HOST_KIND:-}" = "linux-systemd" ] || { info ORGANS "unit-file placement is systemd-only (host=${HOST_KIND:-unset}) — skipping"; return 0; }
  local repo="$NODE_DIR/repo"
  local manifest="$repo/scripts/ops/organ-manifest.txt"
  local dispatch="$repo/scripts/dispatch"
  local lib_manifest="$repo/scripts/ops/lib/organ-manifest-lib.sh"
  local lib_unit="$repo/scripts/ops/lib/organ-unit-install-lib.sh"
  if [ ! -f "$manifest" ] || [ ! -f "$lib_manifest" ] || [ ! -f "$lib_unit" ]; then
    info ORGANS "manifest/libs not found under $repo — skipping unit-file placement"
    return 0
  fi
  if [ "$(id -u)" != "0" ] && [ "${CHUMP_NODE_INSTALL_ALLOW_NONROOT_PLACE:-0}" != "1" ]; then
    bootstrap_organ_deploy_via_sudo "$repo" "$lib_manifest" "$lib_unit" "$dispatch"
    no "unit-file placement needs root to write /etc/systemd/system — skipping (re-run install as root/sudo)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "  DRY: place role-matched manifest unit files (role=$ROLE) into /etc/systemd/system"; return 0; fi

  # shellcheck source=/dev/null
  . "$lib_manifest"; . "$lib_unit"
  local run_user run_home; run_user="$(organ_unit_run_user "$repo")"; run_home="$(organ_unit_run_home "$run_user")"
  local dest_dir="${CHUMP_NODE_INSTALL_SYSTEMD_DIR:-/etc/systemd/system}"
  mkdir -p "$dest_dir"
  info ORGANS "placing role-matched manifest unit files (role=$ROLE, user=$run_user, home=$run_home)"

  # Make `chump` resolvable on the organs' injected PATH ($RUN_HOME/.cargo/bin).
  if [ -x "$BIN" ]; then
    mkdir -p "$run_home/.cargo/bin" 2>/dev/null || true
    ln -sf "$BIN" "$run_home/.cargo/bin/chump" 2>/dev/null || true
  fi

  local PAGING_OFF=() ENABLED=(); declare -A ORGAN_ROLE ORGAN_REQUIRES
  organ_manifest_parse "$manifest" PAGING_OFF ENABLED ORGAN_ROLE ORGAN_REQUIRES || { no "manifest parse failed — skipping placement"; return 0; }

  local rf; rf="$(organ_role_filter)"
  declare -A _want_base    # base-unit-name -> 1 for role-matched units
  local unit role tok in_role
  for unit in "${ENABLED[@]}"; do
    role="${ORGAN_ROLE[$unit]:-brain}"
    in_role=0
    if [ -z "$rf" ]; then in_role=1
    else
      IFS=',' read -ra _toks <<< "$rf"
      for tok in "${_toks[@]}"; do [ "$tok" = "$role" ] && { in_role=1; break; }; done
    fi
    [ "$in_role" = 1 ] || continue
    local base="${unit%.service}"; base="${base%.timer}"
    _want_base["$base"]=1
  done
  # Self-heal beat: organ-reconcile is intentionally absent from the manifest
  # (self-exclusion), so add it explicitly for EVERY role.
  _want_base["chump-organ-reconcile"]=1

  declare -A _KEEP_ROOT=( [chump-organ-deploy.service]=1 [chump-organ-deploy.timer]=1 )
  local placed=() skipped_nofile=() base f keep suffix
  for base in "${!_want_base[@]}"; do
    for suffix in service timer; do
      f="${base}.${suffix}"
      local src="$dispatch/$f" dest="$dest_dir/$f"
      [ -f "$src" ] || continue    # not every base has both a .service and a .timer
      keep=0; [ -n "${_KEEP_ROOT[$f]:-}" ] && keep=1
      # RESILIENT-1102: pass this box's ACTUAL repo ($NODE_DIR/repo, where
      # node-install clones — NOT ~/Projects/chump) so the shared rewriter bakes
      # a WorkingDirectory/ExecStart that exists. The repo-path rewrite now lives
      # in organ_unit_host_rewrite itself (single source of truth), so both this
      # placer and install-helsinki-atc.sh converge identically — no post-hoc sed.
      if organ_unit_host_rewrite "$src" "$dest" "$run_user" "$run_home" "$keep" "$repo"; then
        placed+=("$f")
      fi
    done
    # A base named in the role set but with NO tracked file at all (the
    # CJ-legacy hand-installed chump-cj-* units) — record it; the manifest's
    # file: requires guard makes the reconcile skip it cleanly, so this is a
    # note, not an error.
    if [ ! -f "$dispatch/${base}.service" ] && [ ! -f "$dispatch/${base}.timer" ]; then
      skipped_nofile+=("$base")
    fi
  done

  systemctl daemon-reload 2>/dev/null || true

  # Scope the recurring organ-reconcile timer to THIS node's role (unless --role
  # all) so the timer-driven self-heal converges to the role roster, not the
  # whole manifest. A drop-in beats editing the unit (survives re-copy).
  if [ -f "$dest_dir/chump-organ-reconcile.service" ] && [ "$ROLE" != all ]; then
    mkdir -p "$dest_dir/chump-organ-reconcile.service.d"
    cat > "$dest_dir/chump-organ-reconcile.service.d/zz-node-role.conf" <<EOF
# RESILIENT-1055 — scope this node's recurring reconcile to its --role roster so
# the timer-driven self-heal never re-adds out-of-role organs. Written by
# chump-node-install.sh at bring-up (role=$ROLE).
[Service]
Environment=CHUMP_ORGAN_RECONCILE_ROLE=$rf
EOF
    systemctl daemon-reload 2>/dev/null || true
  fi

  # Arm the reconcile beat itself (not a manifest 'enabled' line, so
  # reconcile_role_organs won't enable it).
  [ -f "$dest_dir/chump-organ-reconcile.timer" ] && systemctl enable --now chump-organ-reconcile.timer 2>/dev/null || true

  ok "placed ${#placed[@]} role-matched unit file(s): ${placed[*]:-none}"
  [ "${#skipped_nofile[@]}" -gt 0 ] && info ORGANS "role-matched but no tracked file (skipped, guarded by requires=file:): ${skipped_nofile[*]}"
  return 0
}
# RESILIENT-1099: render the tracked, node-neutral
# scripts/dispatch/worker-launcher.template.sh into a live per-node launcher
# at $ORGAN_DIR/worker.sh. Node identity is the ONLY per-node input this
# function supplies (AGENT_ID / WORKER_MACHINE / FLEET_SESSION /
# WORKER_SKILLS / FLEET_DOMAIN_FILTER / REPO_ROOT) — self-heal policy and
# model-routing are sourced by worker.sh itself from the tracked
# worker-policy.env / model-escalation-ladder.env, so this launcher never
# carries fleet policy that could drift between nodes. Replaces the
# untracked, hand-copied ~/nodeN-worker-run.sh class of launcher (the exact
# drift that froze the fleet ~15h on 2026-09-08: see
# scripts/setup/worker-policy.env header).
#
# Falls back to a minimal inline launcher (same shape as before RESILIENT-1099)
# if the template isn't present yet in this node's checkout (e.g. mid-upgrade
# from a pre-RESILIENT-1099 clone) so a fresh install never hard-fails here.
render_worker_launcher() {
  local repo="${CHUMP_NODE_REPO:-$NODE_DIR/repo}"
  local template="$repo/scripts/dispatch/worker-launcher.template.sh"
  local agent_id="${CHUMP_WORKER_AGENT_ID:-$(hostname -s 2>/dev/null || echo node1)-worker}"
  local machine="${CHUMP_WORKER_MACHINE:-$(hostname -s 2>/dev/null || echo node1)}"
  local session="${CHUMP_WORKER_SESSION:-$machine}"
  local skills="${CHUMP_WORKER_SKILLS:-}"
  local domain="${CHUMP_WORKER_DOMAIN_FILTER:-}"
  # INFRA-471: model class + effort band for this launcher. Defaults preserve
  # the pre-existing single-worker behavior (sonnet; xs,s,m). scripts/dispatch/
  # spawn-worker-fleet.sh renders ADDITIONAL launchers with different classes
  # (e.g. a haiku/xs instance that eats the xs backlog a sonnet worker refuses).
  local model="${CHUMP_WORKER_MODEL:-sonnet}"
  local effort="${CHUMP_WORKER_EFFORT:-xs,s,m}"

  if [ ! -f "$template" ]; then
    info ORGANS "worker-launcher.template.sh not found in checkout — falling back to minimal inline launcher"
    run "cat > '$ORGAN_DIR/worker.sh' <<'WK'
#!/usr/bin/env bash
export AGENT_ID=\"\${CHUMP_WORKER_AGENT_ID:-\$(hostname -s 2>/dev/null || echo node1)-worker}\"
export REPO_ROOT=\"\${CHUMP_NODE_REPO:-$NODE_DIR/repo}\"
export FLEET_LOG_DIR=\"\${FLEET_LOG_DIR:-$LOG_DIR}\"
exec bash \"\$REPO_ROOT/scripts/dispatch/worker.sh\"
WK"
    run "chmod +x '$ORGAN_DIR/worker.sh'"
    return 0
  fi

  if [ "$DRY" = 1 ]; then
    echo "  DRY: render $template -> $ORGAN_DIR/worker.sh (AGENT_ID=$agent_id WORKER_MACHINE=$machine FLEET_SESSION=$session WORKER_SKILLS=$skills FLEET_DOMAIN_FILTER=$domain REPO_ROOT=$repo FLEET_MODEL=$model FLEET_EFFORT_FILTER=$effort)"
    return 0
  fi

  sed \
    -e "s|__AGENT_ID__|$agent_id|g" \
    -e "s|__WORKER_MACHINE__|$machine|g" \
    -e "s|__FLEET_SESSION__|$session|g" \
    -e "s|__WORKER_SKILLS__|$skills|g" \
    -e "s|__FLEET_DOMAIN_FILTER__|$domain|g" \
    -e "s|__REPO_ROOT__|$repo|g" \
    -e "s|__FLEET_MODEL__|$model|g" \
    -e "s|__FLEET_EFFORT_FILTER__|$effort|g" \
    "$template" > "$ORGAN_DIR/worker.sh"
  chmod +x "$ORGAN_DIR/worker.sh"
  ok "rendered worker launcher (agent_id=$agent_id machine=$machine skills=${skills:-any} domain=${domain:-any} model=$model effort=$effort)"
}
install_organs() {
  # write the heartbeat organ (brain's proof-of-life: refresh heartbeat + node profile)
  run "cat > '$ORGAN_DIR/node-heartbeat.sh' <<'HB'
#!/data/data/com.termux/files/usr/bin/env bash
STATE=\"\${CHUMP_STATE_DIR:-\$HOME/.chump}\"
while true; do
  date -u +%Y-%m-%dT%H:%M:%SZ > \"\$STATE/node-heartbeat\"
  sleep 60
done
HB"
  run "chmod +x '$ORGAN_DIR/node-heartbeat.sh'"
  # INFRA-3650: the process-organ heal loop itself — a plain while-true
  # wrapper around the tracked scripts/ops/process-organ-heal.sh (one pass
  # per invocation, testable in isolation), same shape as node-heartbeat.sh
  # above so it installs identically across supervisors (systemd/runit/
  # fallback).
  run "cat > '$ORGAN_DIR/process-organ-heal.sh' <<'PH'
#!/usr/bin/env bash
STATE=\"\${CHUMP_STATE_DIR:-\$HOME/.chump}\"
REPO=\"\${CHUMP_NODE_REPO:-$NODE_DIR/repo}\"
while true; do
  CHUMP_REPO_ROOT=\"\$REPO\" \\
    bash \"\$REPO/scripts/ops/process-organ-heal.sh\" >> \"$LOG_DIR/process-organ-heal.log\" 2>&1 || true
  sleep \"\${CHUMP_PROCESS_ORGAN_HEAL_INTERVAL_S:-300}\"
done
PH"
  run "chmod +x '$ORGAN_DIR/process-organ-heal.sh'"
  # RESILIENT-1052: the fleet-health sentinel organ — a while-true wrapper
  # around the tracked scripts/ops/fleet-health-sentinel.sh (one --local pass
  # per invocation, testable in isolation), same shape as the two organs above
  # so it installs identically across supervisors. Each pass scans+heals this
  # node's failed chump units, re-enables any inactive required healer (durable
  # activation — healers converge back to active every cycle), and writes the
  # heartbeat the --fleet grader watches.
  run "cat > '$ORGAN_DIR/fleet-health-sentinel.sh' <<'FHS'
#!/usr/bin/env bash
STATE=\"\${CHUMP_STATE_DIR:-\$HOME/.chump}\"
REPO=\"\${CHUMP_NODE_REPO:-$NODE_DIR/repo}\"
while true; do
  CHUMP_STATE_DIR=\"\$STATE\" \\
    bash \"\$REPO/scripts/ops/fleet-health-sentinel.sh\" --local >> \"$LOG_DIR/fleet-health-sentinel.log\" 2>&1 || true
  sleep \"\${CHUMP_SENTINEL_CADENCE_MIN:-5}m\" 2>/dev/null || sleep 300
done
FHS"
  run "chmod +x '$ORGAN_DIR/fleet-health-sentinel.sh'"
  # RESILIENT-1016 (b): muscle_organs() has always declared a "worker" organ,
  # but nothing ever materialized $ORGAN_DIR/worker.sh — svc_install wired a
  # systemd unit whose ExecStart pointed at a script that never existed, so
  # the CORE muscle organ installed (unit present, "organ installed+up"
  # logged) but could never actually go active: ExecStart failed instantly,
  # Restart=always spun it into a failed loop forever (VERIFIED on mugman:
  # 64 active units but worker DOWN + failures). This writes the real
  # wrapper — same shape as node-heartbeat.sh/process-organ-heal.sh above —
  # that execs the tracked scripts/dispatch/worker.sh (which already loops
  # internally), so a fresh --role muscle install self-starts the worker
  # instead of silently staying loaded-not-active.
  if [ "$ROLE" = muscle ] || [ "$ROLE" = all ]; then
    render_worker_launcher
  fi
  local list; case "$ROLE" in brain) list="$(brain_organs; common_organs)";; muscle) list="$(muscle_organs; common_organs)";; all) list="$(brain_organs; muscle_organs; common_organs)";; esac
  echo "$list" | while IFS='|' read -r name exec; do
    [ -z "$name" ] && continue
    svc_install "$name" "$exec"
    if [ "$name" = worker ] && ! worker_execution_enabled; then
      svc_down "$name"
      info ORGANS "worker installed but deliberately stopped (mode=control-plane; add working provider credentials and re-run without --control-plane-only to enable it)"
      continue
    fi
    svc_up "$name"; ok "organ installed+up: $name"
  done
  # RESILIENT-1055: PLACE the role's manifest unit files (host-rewritten) BEFORE
  # reconcile enables them — otherwise reconcile's `enable --now` hits a
  # never-copied unit and backs it off forever. Placement + reconcile together
  # are what make a fresh `--role` box come up with its COMPLETE role roster.
  place_role_unit_files
  reconcile_role_organs
}

# ---------- background-phase helper (RESILIENT-1015) ----------
# Launches a potentially slow, non-blocking phase (SUBSTRATE, EYES) in the
# background under a hard timeout, so it can never stall the one-shot
# install (verified repro: mugman, 2-core aarch64, hung past BINARY with the
# binary pre-placed — the stall was a downstream synchronous phase, not
# BINARY itself). A "<name>.pending" marker exists while the background job
# runs and is removed when it exits (success or failure); self_test reads
# the marker to distinguish "still provisioning" from "actually failed"
# instead of blocking on it.
run_phase_async() {
  local name="$1" timeout_s="$2" script="$3" log="$4"
  local pending="$STATE_DIR/.${name}.pending"
  run "mkdir -p '$STATE_DIR'"
  : > "$pending" 2>/dev/null || true
  (
    run_timeout "$timeout_s" bash "$script" >"$log" 2>&1
    rc=$?
    echo "$rc" > "$STATE_DIR/.${name}.exit" 2>/dev/null || true
    rm -f "$pending" 2>/dev/null || true
  ) &
  disown "$!" 2>/dev/null || true
  ok "$name launched in background (pid $!, budget ${timeout_s}s) — log: $log"
}

# ---------- 5b. SUBSTRATE (INFRA-3631, via INFRA-3657) ----------
# Calls the checked-in substrate provisioner so a bare-box install ends with
# a live, self-hosted Postgres+PostgREST gap store instead of the provisioner
# sitting on disk unwired (the exact "designed but never called" gap this
# ships closes). RESILIENT-1015: this used to `bash "$script"` in the
# foreground — postgres provisioning on a 2-core box is exactly the kind of
# multi-minute synchronous step that stalled the mugman repro. Now launched
# async + time-bounded: a substrate failure/slowness must not block
# BINARY/ORGANS from having already installed a usable node — self_test
# surfaces the real state via the pending marker or postgrest liveness.
ensure_substrate() {
  local script="$NODE_DIR/repo/scripts/setup/install-gap-substrate.sh"
  [ -f "$script" ] || script="$(dirname "$0")/install-gap-substrate.sh"
  if [ ! -x "$script" ]; then
    info SUBSTRATE "install-gap-substrate.sh not found — skipping"
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "  DRY: (background, budget ${CHUMP_SUBSTRATE_TIMEOUT_S:-600}s) bash '$script'"; return 0; fi
  info SUBSTRATE "provisioning gap store (postgres+postgrest) in background — install will not wait on it"
  run_phase_async substrate "${CHUMP_SUBSTRATE_TIMEOUT_S:-600}" "$script" \
    "$LOG_DIR/substrate-install-$(date -u +%Y%m%dT%H%M%SZ).log"
}

# ---------- 5c. EYES (almanac liveness/refresh organ, INFRA-3657) ----------
# Brings up the almanac fusion-search "eyes" so a fresh node isn't blind —
# closes the "ZERO almanac/eyes phase" gap in this ship's description.
# RESILIENT-1015: install-almanac-organ.sh clones + cargo-builds a *separate*
# repo (almanac) on first run when no checkout exists — another multi-minute
# synchronous step on a 2-core box. Same async + time-bounded treatment as
# SUBSTRATE above.
ensure_eyes() {
  local script="$NODE_DIR/repo/scripts/setup/install-almanac-organ.sh"
  [ -f "$script" ] || script="$(dirname "$0")/install-almanac-organ.sh"
  if [ ! -x "$script" ]; then
    info EYES "install-almanac-organ.sh not found — skipping"
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "  DRY: (background, budget ${CHUMP_EYES_TIMEOUT_S:-600}s) bash '$script'"; return 0; fi
  info EYES "installing almanac liveness/refresh organ in background — install will not wait on it"
  run_phase_async eyes "${CHUMP_EYES_TIMEOUT_S:-600}" "$script" \
    "$LOG_DIR/eyes-install-$(date -u +%Y%m%dT%H%M%SZ).log"
}

# ---------- 6. SUPERVISE (survive reboot) ----------
# Linux nodes must refresh the same verified binary the worker resolves
# ($NODE_DIR/bin/chump). Calling the existing installer here closes the old
# hand-run gap where a fresh node had a one-time binary but no durable update
# path after its first boot.
install_binary_refresh() {
  [ "$HOST_KIND" = linux-systemd ] || return 0
  local refresh="$NODE_DIR/repo/scripts/setup/install-node-refresh-systemd.sh"
  [ -f "$refresh" ] || refresh="$(dirname "$0")/install-node-refresh-systemd.sh"
  if [ ! -f "$refresh" ]; then
    no "binary refresh installer missing: $refresh"
    return 1
  fi
  if [ "$DRY" = 1 ]; then
    echo "  DRY: CHUMP_NODE_REPO='$NODE_DIR/repo' CHUMP_NODE_BIN='$BIN' bash '$refresh'"
    return 0
  fi
  if CHUMP_NODE_REPO="$NODE_DIR/repo" CHUMP_NODE_BIN="$BIN" CHUMP_NODE_ROLE="$ROLE" bash "$refresh"; then
    ok "binary refresh timer installed for canonical binary: $BIN"
  else
    no "binary refresh timer install failed; node cannot claim a durable installation"
    return 1
  fi
}

# The cockpit is an opt-in control-plane organ: nodes that only need a local
# CLI do not need to expose HTTP, while CJ/Pixel can request it explicitly with
# --with-fleet-server. The server installer itself only pulls a prebuilt binary
# (never cargo-builds on a live node); make its absence a hard failure here so
# an opted-in cockpit is never reported as installed when it cannot serve.
install_fleet_server() {
  [ "$WITH_FLEET_SERVER" = 1 ] || return 0
  [ "$HOST_KIND" = linux-systemd ] || {
    info FLEET-SERVER "not installed on host=$HOST_KIND (Linux systemd only)"
    return 0
  }
  local installer="$NODE_DIR/repo/scripts/setup/install-fleet-server-node.sh"
  [ -f "$installer" ] || installer="$(dirname "$0")/install-fleet-server-node.sh"
  if [ ! -f "$installer" ]; then
    no "fleet-server installer missing: $installer"
    return 1
  fi
  local server_bin="$NODE_DIR/bin/chump-fleet-server"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: CHUMP_NODE_REPO='$NODE_DIR/repo' CHUMP_NODE_DIR='$NODE_DIR' CHUMP_FLEET_SERVER_BIN='$server_bin' bash '$installer'"
    return 0
  fi
  if ! CHUMP_NODE_REPO="$NODE_DIR/repo" CHUMP_NODE_DIR="$NODE_DIR" CHUMP_FLEET_SERVER_BIN="$server_bin" bash "$installer"; then
    no "fleet-server installer failed"
    return 1
  fi
  if [ ! -x "$server_bin" ]; then
    no "fleet-server binary unavailable after install: $server_bin (wait for a prebuilt artifact, then re-run)"
    return 1
  fi
  ok "fleet-server installed at canonical node path: $server_bin"
}

install_supervise() {
  case "$HOST_KIND" in
    termux)
      run "mkdir -p '$BOOT_DIR'"
      run "cat > '$BOOT_DIR/10-chump-node.sh' <<'BT'
#!/data/data/com.termux/files/usr/bin/sh
sshd 2>/dev/null; termux-wake-lock 2>/dev/null
# runit (termux-services) auto-restores services on boot
BT"
      run "chmod +x '$BOOT_DIR/10-chump-node.sh'"; ok "reboot hook: $BOOT_DIR/10-chump-node.sh"
      ;;
    linux-systemd)
      ok "systemd enables organs on boot (done in svc_up)"
      install_binary_refresh
      install_fleet_server
      ;;
    *) info SUPERVISE "manual supervision on $HOST_KIND";;
  esac
}

# ---------- 7. SELF-TEST (defines 'installed') ----------
# INFRA-3641 AC3: --dry-run on a systemd host prints the EXACT manifest-derived
# organ set this role WOULD supervise (unit, kind, applicable/skip + reason) —
# read-only, no systemctl mutation, no live-status query needed since nothing
# has actually been installed yet. Reuses organ-role-roster.sh (already the
# read-only "what would this role run" primitive RESILIENT-1055 shipped) so
# there is no second per-host organ-listing implementation to drift.
self_test_dry_run_organs() {
  [ "$HOST_KIND" = linux-systemd ] || { info SELF-TEST "--dry-run organ roster is systemd-only (host=$HOST_KIND) — skipping"; return 0; }
  local roster="$NODE_DIR/repo/scripts/ops/organ-role-roster.sh"
  [ -f "$roster" ] || roster="$(dirname "$0")/../ops/organ-role-roster.sh"
  if [ ! -f "$roster" ]; then info SELF-TEST "organ-role-roster.sh not found — skipping dry-run roster"; return 0; fi
  local rf; rf="$(organ_role_filter)"
  info SELF-TEST "--dry-run: manifest-derived organ set this role WOULD supervise (role=$ROLE, role-filter=[${rf:-all}])"
  CHUMP_ORGAN_RECONCILE_ROLE="$rf" bash "$roster" | while IFS=$'\t' read -r state unit kind reason; do
    [ -z "$unit" ] && continue
    if [ "$state" = SKIP ]; then printf '  SKIP  %s (%s) — %s\n' "$unit" "$kind" "$reason"
    else printf '  WOULD-SUPERVISE  %s (%s)\n' "$unit" "$kind"; fi
  done
}
self_test() {
  info SELF-TEST "verifying node is installed & healthy"
  if [ "$DRY" = 1 ]; then self_test_dry_run_organs; return 0; fi
  # `--self-test-only` starts a fresh process; restore the persisted mode so it
  # judges a control-plane install by its honest contract rather than demanding
  # a provider that was intentionally absent at first boot.
  local node_env="$STATE_DIR/node.env"
  if [ -f "$node_env" ]; then
    # shellcheck disable=SC1090
    . "$node_env"
  fi
  if [ "$CONTROL_PLANE_ONLY" = 1 ]; then
    CHUMP_NODE_WORK_ENABLED=0
    CHUMP_NODE_MODE="control-plane"
  fi
  local fail=0
  [ -n "$HOST_KIND" ] && ok "host detected: $HOST_KIND/$ARCH" || { no "host detect"; fail=1; }
  if provider_creds_ready && [ "${CHUMP_NODE_WORK_ENABLED:-1}" = 1 ]; then
    check_creds || fail=1
  else
    info CREDS "provider unavailable or intentionally disabled — control-plane mode is healthy; worker execution remains stopped"
  fi
  if git -C "$NODE_DIR/repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local head_sha origin_sha
    head_sha="$(git -C "$NODE_DIR/repo" rev-parse HEAD 2>/dev/null)"
    origin_sha="$(git -C "$NODE_DIR/repo" rev-parse origin/main 2>/dev/null)"
    if [ -n "$head_sha" ] && [ "$head_sha" = "$origin_sha" ]; then ok "repo HEAD at origin/main ($head_sha)"
    else no "repo HEAD not at origin/main (HEAD=$head_sha origin/main=$origin_sha)"; fail=1; fi
  else no "repo missing: $NODE_DIR/repo/.git"; fail=1; fi
  # Binary bar = present AND provenance-verified (release-sha-verified OR
  # built-from-repo-HEAD). A bare `[ -x ]` here was the self-test half of the
  # freeload false-pass: it green-lit any executable at $BIN regardless of
  # where it came from. Provenance is now part of "INSTALLED".
  if [ -x "$BIN" ] && binary_provenance_ok "$BIN"; then ok "binary present + provenance verified: $BIN"
  elif [ -x "$BIN" ]; then no "binary at $BIN FAILED provenance (foreign/stale/unverified) — not a trusted install"; fail=1
  else no "binary missing: $BIN"; fail=1; fi
  # INFRA-3633: post-seed sanity — canonical store should have picked up the
  # real backlog from docs/gaps/*.yaml, not sit empty. Compare PICKABLE
  # (non-terminal) counts on both sides: sync_pull's insert path (a brand
  # new DB row has nothing to guard) faithfully copies every YAML's status,
  # terminal or not, so a fresh box's total row count equals yaml_total —
  # but the number of rows a picker would ever see (status not in the
  # terminal set — see is_terminal_status in chump-gap-store::sync) is the
  # meaningful "did the real backlog show up" signal.
  local terminal_status_re='^\s*status:\s*"?(done|superseded|wontfix|wont_fix|closed|closed_not_a_bug|already_satisfied|obsolete|duplicate)"?\s*$'
  if command -v sqlite3 >/dev/null 2>&1 && [ -f "$STATE_DB" ] && [ -d "$NODE_DIR/repo/docs/gaps" ]; then
    local db_total db_pickable yaml_total yaml_terminal yaml_pickable
    db_total="$(sqlite3 "$STATE_DB" 'SELECT COUNT(*) FROM gaps;' 2>/dev/null || echo 0)"
    db_pickable="$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps WHERE status NOT IN ('done','superseded','wontfix','wont_fix','closed','closed_not_a_bug','already_satisfied','obsolete','duplicate');" 2>/dev/null || echo 0)"
    yaml_total="$(find "$NODE_DIR/repo/docs/gaps" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
    yaml_terminal="$(grep -lE "$terminal_status_re" "$NODE_DIR/repo/docs/gaps"/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
    yaml_pickable=$(( yaml_total - yaml_terminal ))
    if [ "$db_total" -gt 0 ] 2>/dev/null; then
      if [ "$db_pickable" -eq "$yaml_pickable" ] 2>/dev/null; then
        ok "seed: canonical store has $db_total gaps, $db_pickable pickable (matches docs/gaps: $yaml_pickable non-terminal of $yaml_total)"
      else
        ok "seed: canonical store has $db_total gaps, $db_pickable pickable (docs/gaps: $yaml_pickable non-terminal of $yaml_total — drift expected if state.db has rows not sourced from this box's YAML)"
      fi
    else
      no "seed: canonical store empty (0 gaps) — SEED phase may have failed; re-run chump-node-install.sh"
      fail=1
    fi
  fi
  # each role organ supervised & up (INFRA-3650: common_organs, e.g.
  # process-organ-heal, must be part of the "installed" bar for every role)
  local list; case "$ROLE" in brain) list="$(brain_organs; common_organs)";; muscle) list="$(muscle_organs; common_organs)";; all) list="$(brain_organs; muscle_organs; common_organs)";; esac
  echo "$list" | while IFS='|' read -r name _; do [ -z "$name" ] && continue
    if [ "$name" = worker ] && ! worker_execution_enabled; then
      info SELF-TEST "worker intentionally stopped (control-plane mode)"
      continue
    fi
    if [ "$(svc_status "$name")" = up ]; then ok "organ up: $name"; else no "organ DOWN: $name"; fi
  done
  # heartbeat freshness (< 180s old)
  local hb="$STATE_DIR/node-heartbeat"
  if [ -f "$hb" ]; then
    local age=$(( $(date -u +%s) - $(date -u -d "$(cat "$hb")" +%s 2>/dev/null || echo 0) ))
    [ "$age" -lt 180 ] 2>/dev/null && ok "heartbeat fresh (${age}s)" || no "heartbeat stale (${age}s)"
  else no "no heartbeat yet (organ just started; re-run --self-test-only in ~70s)"; fi
  # aggregate organ-down check (subshell above can't set fail; re-check here)
  echo "$list" | while IFS='|' read -r name _; do
    [ -z "$name" ] && continue
    [ "$name" = worker ] && ! worker_execution_enabled && continue
    [ "$(svc_status "$name")" = up ] || exit 1
  done || fail=1
  # RESILIENT-746: the role's MANIFEST-declared organ set (organ-manifest.txt,
  # role-scoped via organ_role_filter) must also be UP — the ORGANS phase is
  # only "installed" once the fleet-wide organ-reconcile source of truth
  # agrees, not just the two hand-coded organs above. --check is read-only
  # (no root needed) and reports DRIFT for any role-matched `enabled` unit
  # that is not active.
  local recon_script="$NODE_DIR/repo/scripts/ops/organ-reconcile.sh"
  [ -f "$recon_script" ] || recon_script="$(dirname "$0")/../ops/organ-reconcile.sh"
  if [ -f "$recon_script" ]; then
    local recon_rf; recon_rf="$(organ_role_filter)"
    local recon_out
    if recon_out="$(CHUMP_ORGAN_RECONCILE_ROLE="$recon_rf" bash "$recon_script" --check 2>&1)"; then
      ok "organs: role-matched organ-manifest units up to date (role=$ROLE, role-filter=[${recon_rf:-all}])"
    else
      no "organs: role-matched organ-manifest units DRIFT (role=$ROLE) — $recon_out"
      fail=1
    fi
  else
    info ORGANS "organ-reconcile.sh not found — skipping manifest organ-set self-test"
  fi
  # INFRA-3657 AC3: SUBSTRATE + EYES are part of the FACTORY INSTALLED bar,
  # not optional add-ons — a node without a gap store or almanac eyes is not
  # "factory installed" per this gap's AC. Best-effort: --check reports the
  # phase's own verdict rather than re-implementing its self-test.
  # RESILIENT-1015: SUBSTRATE/EYES now run async (see run_phase_async) so a
  # slow postgres provision or almanac clone+build can't stall the install.
  # A ".<name>.pending" marker means the background job is still running —
  # that is "not ready yet", not "failed", so it's reported as info and does
  # NOT flip fail=1 (the install genuinely can't be blocked on it finishing).
  local substrate_script="$NODE_DIR/repo/scripts/setup/install-gap-substrate.sh"
  [ -f "$substrate_script" ] || substrate_script="$(dirname "$0")/install-gap-substrate.sh"
  if [ -x "$substrate_script" ]; then
    if [ -f "$STATE_DIR/.substrate.pending" ]; then
      info SUBSTRATE "still provisioning in background (non-fatal) — re-run --self-test-only shortly"
    elif command -v pgrep >/dev/null 2>&1 && pgrep -f postgrest >/dev/null 2>&1; then
      ok "substrate: postgrest running"
    else no "substrate: postgrest not running (re-run: bash $substrate_script)"; fail=1; fi
  fi
  local eyes_script="$NODE_DIR/repo/scripts/setup/install-almanac-organ.sh"
  [ -f "$eyes_script" ] || eyes_script="$(dirname "$0")/install-almanac-organ.sh"
  if [ -x "$eyes_script" ]; then
    if [ -f "$STATE_DIR/.eyes.pending" ]; then
      info EYES "still installing in background (non-fatal) — re-run --self-test-only shortly"
    elif bash "$eyes_script" --check >/dev/null 2>&1; then ok "eyes: almanac organ supervised"
    else no "eyes: almanac organ incomplete (re-run: bash $eyes_script)"; fail=1; fi
  fi
  echo
  if [ "$fail" = 0 ]; then printf '\033[42m INSTALLED ✓ \033[0m role=%s host=%s mode=%s\n' "$ROLE" "$HOST_KIND" "${CHUMP_NODE_MODE:-work-ready}"; return 0
  else printf '\033[41m NOT FULLY INSTALLED \033[0m — fix the ✗ above\n'; return 1; fi
}

# ---------- run ----------
# INFRA-3710: guard the top-level install run so sibling organ-install
# scripts (e.g. install-almanac-organ.sh) can `source` this file to reuse
# detect_host()/ensure_home()/toolchain_preflight()/ensure_rust() without
# also triggering a full node install as a side effect of sourcing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
printf '\033[1m=== chump-node-install: role=%s home=%s ===\033[0m\n' "$ROLE" "$NODE_DIR"
info GAP-STORE "canonical shared gap store pinned: CHUMP_GAP_STORE_URL=$CHUMP_GAP_STORE_URL"
detect_host
if [ "$RECONCILE_ORGANS_ONLY" = 1 ]; then
  run "mkdir -p '$ORGAN_DIR' '$LOG_DIR' '$STATE_DIR'"
  install_organs
  echo
  ok "organs reconciled (role=$ROLE, reconcile-organs-only — clone/creds/binary/substrate/eyes untouched)"
  exit 0
fi
if [ "$SELF_TEST_ONLY" = 1 ]; then self_test; exit $?; fi
toolchain_preflight
ensure_home || { no "HOME phase failed (repo clone/fetch) — fix and re-run"; exit 1; }
if check_creds; then
  info CREDS "provider credentials accepted — worker mode will be enabled"
elif [ "$CONTROL_PLANE_ONLY" = 1 ]; then
  info CREDS "provider intentionally disabled — installing control-plane only"
else
  info CREDS "provider unavailable — installing a healthy control plane; worker remains stopped until credentials are supplied"
fi
write_node_env
ensure_binary || info BINARY "install a binary, then re-run"
ensure_seed
install_organs
ensure_substrate
ensure_eyes
install_supervise || { no "SUPERVISE phase failed — fix the binary refresh timer and re-run"; exit 1; }
# RESILIENT-318: install the self-management suite (orchestrator + reapers + disk-monitor).
# RESILIENT-1015: SUBSTRATE/EYES are already async (see run_phase_async), so
# they no longer eat this budget — this check guards the one remaining
# optional-but-synchronous step against a slow/hung housekeeping install
# blowing past the overall install budget on a constrained box.
if [ "$SELF_TEST_ONLY" = 1 ]; then :
elif install_budget_exceeded; then
  info ORGANS "install budget (${INSTALL_BUDGET_S}s) exhausted — skipping housekeeping install this run, re-run to retry"
else
  run_timeout "$(install_budget_remaining_s)" bash "$(dirname "$0")/install-node-housekeeping.sh" \
    || info ORGANS "housekeeping install skipped or timed out"
fi
echo
self_test
fi
