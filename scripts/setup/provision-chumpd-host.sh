#!/usr/bin/env bash
# provision-chumpd-host.sh — RESILIENT-176 (PREP slice)
#
# Idempotent provisioner for a FRESH macOS or Linux host that will become
# the fleet's always-on substrate: chumpd + N supervised Sonnet workers,
# per docs/design/GROUND_UP_2026-07-19.md step 5 and the runbook at
# docs/process/OFF_LAPTOP_SUBSTRATE.md.
#
# STATUS (2026-07-19): RESILIENT-176 depends_on MISSION-051 (the chumpd
# binary), which has NOT merged to main yet. This script is deliberately
# PREP-ONLY: it provisions everything a fresh host needs (git, gh, claude
# CLI, cargo, repo clone, build) and CHECKS FOR the chumpd binary +
# scripts/setup/install-chumpd.sh before attempting to install/start the
# service. When those aren't present yet, it prints a clear BLOCKED
# message and stops that step rather than pretending to install something
# that doesn't exist — "reporting a mechanism active before verifying it"
# is a banned move per docs/process/DURABLE_FIX_DOCTRINE.md. Re-run this
# script after MISSION-051 lands to pick up where it left off (idempotent).
#
# NO REMOTE ACTIONS: this script only touches the LOCAL filesystem/service
# manager of the host it runs ON. It does not SSH anywhere, does not spawn
# fleet workers, and does not talk to any chumpd socket. Run it ON the
# target host (laptop, Pi, mini, or cloud droplet) — see the host-candidate
# table in docs/process/OFF_LAPTOP_SUBSTRATE.md for how to pick one.
#
# NO CREDENTIALS EMBEDDED: this script never reads, prints, or writes a
# credential VALUE. It only checks presence of the files/env vars the
# operator is expected to provision per CLAUDE.md → "GitHub credentials for
# agents (INFRA-AGENT-CREDS)" and RESILIENT-173 ("no secrets in argv —
# env files only"), and prints exactly what's missing.
#
# Safe to run repeatedly (idempotent) — every mutating step first checks
# whether its target state already holds.
#
# Usage:
#   scripts/setup/provision-chumpd-host.sh --install-deps   # FRESH UBUNTU BOX: install system deps (apt + rustup + gh + GTK libs + swap), then provision
#   scripts/setup/provision-chumpd-host.sh                # provision assuming deps already present
#   scripts/setup/provision-chumpd-host.sh --check         # report readiness only; exit 0 (ready) / 1 (missing deps)
#   scripts/setup/provision-chumpd-host.sh --dry-run        # print every action, mutate nothing
#   scripts/setup/provision-chumpd-host.sh --uninstall       # stop + remove the chumpd service (leaves repo clone)
#   scripts/setup/provision-chumpd-host.sh --creds-file PATH  # zero-touch: materialize chumpd.env from a ready-made env file
#
# FRESH UBUNTU 24.04 QUICKSTART (headless cabinet box), from a clean install:
#   git clone https://github.com/repairman29/chump.git ~/chump-host
#   cd ~/chump-host && bash scripts/setup/provision-chumpd-host.sh --install-deps
#   # then fill in ~/.chump/chumpd.env (GH token + LLM backend) and:
#   systemctl --user start chumpd && systemctl --user status chumpd
#
# Zero-touch creds (INFRA-3629/INFRA-7815, the "bot told to do it" path — no
# human ever opens an editor): supply creds from exactly ONE source and the
# chumpd.env write step materializes it for you instead of a TODO_ template:
#   --creds-file PATH          path to a ready-made env file (KEY=VALUE lines:
#                               GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, etc.)
#   $CHUMP_BOOTSTRAP_CREDS     the same file body, inline, e.g.:
#     CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=%s\n' "$OAUTH" "$GH")" \
#       bash scripts/setup/provision-chumpd-host.sh --install-deps
# Neither source's VALUES ever appear in `ps`, argv, or this script's logs —
# only the source used and which required keys are present/missing are
# logged. If ~/.chump/chumpd.env already exists it is left alone (idempotent).
#
# Env overrides:
#   CHUMPD_PROVISION_DIR       clone target dir (default: $HOME/chump-host)
#   CHUMPD_PROVISION_REPO_URL  https clone URL (default: https://github.com/repairman29/chump.git)
#   CHUMPD_PROVISION_BRANCH    branch to build (default: main)
#
# Rust-First-Bypass: one-shot host-bootstrap wrapper around git/gh/cargo/
# launchctl/systemctl — pure CLI glue, no state.db/ambient.jsonl/gap-yaml
# mutation, runs once per host (not a hot path). Per META-064 shell-OK
# criteria (glue between existing CLI tools, exploratory-until-MISSION-051,
# no regression-test maintenance burden beyond the shape smoke test).

set -euo pipefail

# ── HOME guard ────────────────────────────────────────────────────────────
# Every mutating path in this script is derived from $HOME (clone dir,
# ~/.chump/oauth-token.json check, ~/Library/LaunchAgents, ~/.config/systemd).
# Refuse to run with HOME unset rather than silently resolving into an
# undefined location.
if [[ -z "${HOME:-}" ]]; then
  echo "ERROR: HOME is unset — refusing to run (every path below is HOME-relative)." >&2
  exit 1
fi

MODE="run"
INSTALL_DEPS=0   # RESILIENT-185: --install-deps installs system packages on a fresh box
CREDS_FILE=""    # INFRA-7815 (INFRA-3629 slice): zero-touch creds, see materialize_chumpd_env below
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)        MODE="check"; shift ;;
    --dry-run)      MODE="dry-run"; shift ;;
    --uninstall)    MODE="uninstall"; shift ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --creds-file)   CREDS_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,60p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    # fail() isn't defined yet at parse time — use a plain echo here.
    *) echo "[provision-chumpd-host] FAIL: unknown argument: $1" >&2; exit 2 ;;
  esac
done

CHUMPD_PROVISION_DIR="${CHUMPD_PROVISION_DIR:-$HOME/chump-host}"
CHUMPD_PROVISION_REPO_URL="${CHUMPD_PROVISION_REPO_URL:-https://github.com/repairman29/chump.git}"
CHUMPD_PROVISION_BRANCH="${CHUMPD_PROVISION_BRANCH:-main}"

log()  { echo "[provision-chumpd-host] $*"; }
warn() { echo "[provision-chumpd-host] WARN: $*" >&2; }
fail() { echo "[provision-chumpd-host] FAIL: $*" >&2; }

# run <description> -- <cmd...>
# In --dry-run mode, prints what would happen and returns 0 without
# executing. In --check mode, callers should not invoke run() for mutating
# steps at all (check is read-only by construction). Otherwise executes.
run() {
  local desc="$1"; shift
  if [[ "$MODE" == "dry-run" ]]; then
    log "[dry-run] would: $desc"
    return 0
  fi
  log "$desc"
  "$@"
}

# ── RESILIENT-185: fresh-Ubuntu system-dependency install (--install-deps) ──
# On a truly fresh box, git/gh/cargo and the GTK build libs don't exist yet —
# the dependency inventory below would just fail. --install-deps installs them
# first. Every command here was run by hand provisioning the Helsinki host on
# 2026-07-22 (Ubuntu 24.04); this codifies that sequence. sudo is used only
# when not already root. No-op on macOS (use brew there).
_sudo() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

ensure_swap() {
  # Release builds of the ~35-crate workspace OOM on 8GB (rustc jobs ~1.2GB
  # each). Add an 8GB swapfile when total RAM < 12GB and no swap is active.
  local mem_gb
  mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [[ "$mem_gb" -ge 12 ]]; then
    log "RAM ${mem_gb}GB >= 12GB — no swap needed"
    return 0
  fi
  if swapon --show 2>/dev/null | grep -q .; then
    log "RAM ${mem_gb}GB is tight but swap is already active — leaving as-is"
    return 0
  fi
  log "RAM ${mem_gb}GB is tight for release builds — adding an 8GB swapfile"
  run "fallocate /swapfile"  _sudo fallocate -l 8G /swapfile
  run "chmod 600 /swapfile"  _sudo chmod 600 /swapfile
  run "mkswap /swapfile"     _sudo mkswap /swapfile
  run "swapon /swapfile"     _sudo swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
    run "persist swap in /etc/fstab" bash -c "echo '/swapfile none swap sw 0 0' | $( [[ $(id -u) -eq 0 ]] || echo sudo ) tee -a /etc/fstab >/dev/null"
  fi
}

install_linux_deps() {
  [[ "$OS_KIND" == "linux" ]] || { log "not Linux — skipping apt dep install (use brew on macOS)"; return 0; }
  command -v apt-get >/dev/null 2>&1 || { warn "--install-deps supports apt (Debian/Ubuntu) only; install deps manually on this distro"; return 0; }

  run "apt-get update" _sudo apt-get update -y
  # RESILIENT-183: the GTK/webkit dev libs are required because the workspace
  # includes the Tauri desktop crate (until ZERO-WASTE-026 splits it out).
  run "install build + fleet system deps" _sudo apt-get install -y \
    build-essential pkg-config git curl wget python3 sqlite3 \
    libssl-dev \
    libwebkit2gtk-4.1-dev libjavascriptcoregtk-4.1-dev libsoup-3.0-dev

  # gh (GitHub CLI) via the official apt repo, if not already present.
  if ! command -v gh >/dev/null 2>&1; then
    log "installing gh (GitHub CLI) from the official apt repo"
    run "add gh keyring + repo, install" bash -c '
      set -e
      SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
      $SUDO mkdir -p -m 755 /etc/apt/keyrings
      wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      $SUDO apt-get update -y
      $SUDO apt-get install -y gh
    '
  fi

  # rustup (cargo) — user-level, no sudo. Minimal profile is enough to build.
  if ! command -v cargo >/dev/null 2>&1; then
    run "install rustup (stable, minimal)" bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal"
    export PATH="$HOME/.cargo/bin:$PATH"
  fi

  # RESILIENT-191: the `claude` backend dispatches via the Claude Code CLI
  # (`claude -p`). Install it (user-level, official native installer) so a
  # claude-backend node ships out of the box. Harmless for chump-local nodes.
  if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/claude" ]]; then
    run "install Claude Code CLI (native, user-level)" bash -c "curl -fsSL https://claude.ai/install.sh | bash"
    export PATH="$HOME/.local/bin:$PATH"
  fi

  ensure_swap
}

# EFFECTIVE-426: fast linker (mold on Linux, lld on macOS) — cheapest big
# build-speed win, applies to every worker's incremental rebuilds. Runs on
# both OS_KIND branches (the script itself is OS-aware) and is best-effort:
# a failure here must not block the rest of provisioning.
install_fast_linker() {
  local script="$CHUMPD_PROVISION_DIR/scripts/setup/install-fast-linker.sh"
  if [[ ! -f "$script" ]]; then
    warn "scripts/setup/install-fast-linker.sh not found in checkout — skipping fast-linker wiring"
    return 0
  fi
  run "install + wire fast linker (mold/lld)" bash "$script" || \
    warn "fast-linker install failed — continuing with default linker"
}

# ── OS / arch detection ──────────────────────────────────────────────────
OS_KIND=""
case "$(uname -s)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
  *) fail "unsupported OS $(uname -s) — chumpd host provisioning supports macOS and Linux only"; exit 1 ;;
esac
ARCH="$(uname -m)"
log "detected OS=$OS_KIND arch=$ARCH"

# RESILIENT-185: install system deps FIRST on a fresh box (before the
# inventory below tries to use them). Only when --install-deps was passed.
if [[ "$INSTALL_DEPS" -eq 1 && "$MODE" != "check" ]]; then
  log "-- installing system dependencies (--install-deps) --"
  install_linux_deps
fi

READY=1  # flips to 0 on any missing hard dependency

# ── Dependency checks ─────────────────────────────────────────────────────
check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    log "OK: $cmd found ($(command -v "$cmd"))"
  else
    warn "$cmd NOT found — $hint"
    READY=0
  fi
}

log "-- dependency inventory --"
check_cmd git   "install via https://git-scm.com/downloads or your package manager (brew install git / apt install git)"
check_cmd gh    "install via https://cli.github.com (brew install gh / apt install gh)"
check_cmd claude "install the Claude Code CLI: https://docs.claude.com/en/docs/claude-code — required to run chumpd's supervised Sonnet workers"
check_cmd cargo "install Rust via https://rustup.rs (curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh)"

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    log "OK: gh is authenticated"
  else
    warn "gh is installed but NOT authenticated — run 'gh auth login' (interactive, operator-only step)"
    READY=0
  fi
fi

# Disk headroom: ~20GB minimum for chumpd + 2 sonnet workers per repo docs
# (docs/process/DISK_COST_MODEL.yaml cargo_build + worktree + target dirs).
AVAIL_GB=0
if [[ "$OS_KIND" == "macos" ]]; then
  AVAIL_GB=$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
else
  AVAIL_GB=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
fi
AVAIL_GB="${AVAIL_GB:-0}"
if [[ "$AVAIL_GB" -ge 20 ]]; then
  log "OK: ${AVAIL_GB}GB available at \$HOME (>= 20GB floor)"
else
  warn "${AVAIL_GB}GB available at \$HOME — below the 20GB floor chumpd + 2 workers need"
  READY=0
fi

# Network reachability (read-only checks; no data sent). Deliberately NOT
# using curl -f: some hosts (e.g. api.anthropic.com's bare root) return a
# non-2xx for "/" by design — a TLS handshake + any HTTP response proves
# reachability, a connect-level failure (curl exit 6/7/28) does not.
for host in github.com api.anthropic.com; do
  http_code=""
  if command -v curl >/dev/null 2>&1; then
    http_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "https://${host}" 2>/dev/null || true)"
  fi
  if [[ -n "$http_code" && "$http_code" != "000" ]]; then
    log "OK: network reaches https://${host} (HTTP ${http_code})"
  else
    warn "could not reach https://${host} — required for gh/git push and the Claude API"
    READY=0
  fi
done

# ── Auth material — presence-only checks, NEVER print values ─────────────
log "-- auth material (INFRA-AGENT-CREDS / RESILIENT-173: presence only, no values) --"
if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
  log "OK: GH_TOKEN/GITHUB_TOKEN is set in this shell's environment"
else
  warn "GH_TOKEN/GITHUB_TOKEN not set — gh falls back to keyring/SSH (implicit mode); on a" \
       "fresh host with no keyring, export GH_TOKEN from an ENV FILE (never argv) before" \
       "running chumpd. See docs/process/OFF_LAPTOP_SUBSTRATE.md 'Auth material checklist'."
fi
OAUTH_TOKEN_PATH="${CHUMP_OAUTH_TOKEN_PATH:-$HOME/.chump/oauth-token.json}"
if [[ -f "$OAUTH_TOKEN_PATH" ]]; then
  log "OK: oauth token file present at $OAUTH_TOKEN_PATH (not read; presence only)"
else
  warn "no oauth token file at $OAUTH_TOKEN_PATH — fleet subscription auth (CHUMP_AUTH_MODE=oauth)" \
       "won't be available until the operator copies/refreshes it onto this host"
fi

if [[ "$MODE" == "check" ]]; then
  if [[ "$READY" -eq 1 ]]; then
    log "READY: all hard dependencies present. Auth-material warnings above (if any) are operator TODOs."
    exit 0
  else
    fail "NOT READY — see warnings above."
    exit 1
  fi
fi

# ── Uninstall path ─────────────────────────────────────────────────────
if [[ "$MODE" == "uninstall" ]]; then
  if [[ "$OS_KIND" == "macos" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.chump.chumpd.plist"
    if [[ -f "$PLIST" ]]; then
      run "unload + remove $PLIST" launchctl unload "$PLIST"
      run "rm $PLIST" rm -f "$PLIST"
    else
      log "no chumpd launchd plist installed — nothing to remove"
    fi
  else
    if systemctl --user list-unit-files 2>/dev/null | grep -q '^chumpd\.service'; then
      run "stop chumpd.service" systemctl --user stop chumpd.service
      run "disable chumpd.service" systemctl --user disable chumpd.service
      run "remove unit file" rm -f "$HOME/.config/systemd/user/chumpd.service"
      run "daemon-reload" systemctl --user daemon-reload
    else
      log "no chumpd systemd unit installed — nothing to remove"
    fi
  fi
  log "uninstall complete. Repo clone at $CHUMPD_PROVISION_DIR left in place (rm -rf it manually if desired)."
  exit 0
fi

# ── Repo clone / update (idempotent) ─────────────────────────────────────
log "-- repo checkout --"
if [[ -d "$CHUMPD_PROVISION_DIR/.git" ]]; then
  log "OK: repo already cloned at $CHUMPD_PROVISION_DIR"
  run "fetch latest $CHUMPD_PROVISION_BRANCH" git -C "$CHUMPD_PROVISION_DIR" fetch origin "$CHUMPD_PROVISION_BRANCH" --quiet
else
  run "clone $CHUMPD_PROVISION_REPO_URL -> $CHUMPD_PROVISION_DIR" \
    git clone --branch "$CHUMPD_PROVISION_BRANCH" "$CHUMPD_PROVISION_REPO_URL" "$CHUMPD_PROVISION_DIR"
fi

# ── Fast linker (EFFECTIVE-426) ───────────────────────────────────────────
if [[ "$MODE" != "dry-run" ]]; then
  log "-- fast linker --"
  install_fast_linker
fi

# ── Build ──────────────────────────────────────────────────────────────
log "-- build --"
if [[ "$MODE" == "dry-run" ]]; then
  log "[dry-run] would: cd $CHUMPD_PROVISION_DIR && cargo build --release --bin chump"
  log "[dry-run] would: check whether the checkout has a chumpd binary target yet" \
      "(BLOCKED-until-MISSION-051 gate); if present, would install + validate the service"
  log "[dry-run] stopping here — dry-run never clones, so it cannot inspect Cargo.toml for" \
      "the chumpd target. Run without --dry-run (or --check) against a real checkout to" \
      "see the actual BLOCKED / service-install outcome."
  log "done (dry-run). See docs/process/OFF_LAPTOP_SUBSTRATE.md for the cutover checklist."
  exit 0
else
  # RESILIENT-185: on low-RAM Linux, build with LTO off + more codegen units +
  # capped jobs so rustc doesn't OOM (the 8GB Helsinki box needed this).
  BUILD_ENV=()
  if [[ "$OS_KIND" == "linux" ]]; then
    _mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
    if [[ "$_mem_gb" -lt 12 ]]; then
      log "low RAM (${_mem_gb}GB) — building with LTO off, 16 codegen units, 3 jobs to avoid OOM"
      BUILD_ENV=(CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 CARGO_BUILD_JOBS=3)
    fi
  fi
  ( cd "$CHUMPD_PROVISION_DIR" && env ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} cargo build --release --bin chump )
  log "OK: built chump"
  # RESILIENT-185: also build the chumpd supervisor binary the service runs.
  ( cd "$CHUMPD_PROVISION_DIR" && env ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} cargo build --release -p chumpd )
  log "OK: built chumpd"

  # RESILIENT-191: put `chump` on PATH. Worker loops call bare `chump gap …`;
  # without this they log "chump binary not on PATH" and stall every cycle.
  if [[ -x "$CHUMPD_PROVISION_DIR/target/release/chump" ]]; then
    mkdir -p "$HOME/.local/bin"
    cp -f "$CHUMPD_PROVISION_DIR/target/release/chump" "$HOME/.local/bin/chump"
    export PATH="$HOME/.local/bin:$PATH"
    log "OK: installed chump -> $HOME/.local/bin/chump"
  fi

  # RESILIENT-191: materialize the local gap DB from the tracked YAML mirror
  # (state.db is gitignored; the registry travels as .chump/state.sql). Best-effort
  # + time-bounded: `chump restore --from-sql` currently probes a model endpoint at
  # startup, so it can fail on a node whose backend secrets aren't filled yet — the
  # runbook (docs/process/ADD_A_FLEET_NODE.md §2) covers the post-secrets re-run.
  if [[ ! -s "$CHUMPD_PROVISION_DIR/.chump/state.db" && -f "$CHUMPD_PROVISION_DIR/.chump/state.sql" ]]; then
    if ( cd "$CHUMPD_PROVISION_DIR" && timeout 60 "$HOME/.local/bin/chump" restore --from-sql >/dev/null 2>&1 ); then
      log "OK: materialized state.db from state.sql ($(sqlite3 "$CHUMPD_PROVISION_DIR/.chump/state.db" "SELECT COUNT(*) FROM gaps WHERE status='open'" 2>/dev/null) open gaps)"
    else
      warn "could not materialize state.db yet (restore needs a reachable backend) —" \
           "fill secrets then re-run: cd $CHUMPD_PROVISION_DIR && chump restore --from-sql"
    fi
  fi
fi

# ── chumpd availability gate (BLOCKED-until-MISSION-051) ─────────────────
CHUMPD_BIN_TARGET_PRESENT=0
if grep -qE '^\s*\[\[bin\]\]' "$CHUMPD_PROVISION_DIR/Cargo.toml" 2>/dev/null \
   && grep -q 'name = "chumpd"' "$CHUMPD_PROVISION_DIR/Cargo.toml" 2>/dev/null; then
  CHUMPD_BIN_TARGET_PRESENT=1
fi
if [[ -d "$CHUMPD_PROVISION_DIR/crates/chumpd" ]]; then
  CHUMPD_BIN_TARGET_PRESENT=1
fi

if [[ "$CHUMPD_BIN_TARGET_PRESENT" -eq 0 ]]; then
  cat <<'EOF'
[provision-chumpd-host] BLOCKED: no chumpd binary target found in this checkout.
[provision-chumpd-host]   RESILIENT-176 depends_on MISSION-051 (chumpd supervisor
[provision-chumpd-host]   umbrella), which has not merged yet. Host + toolchain +
[provision-chumpd-host]   repo checkout above ARE complete and idempotent — re-run
[provision-chumpd-host]   this script after MISSION-051 lands (git pull happens
[provision-chumpd-host]   automatically above) to build + install the service.
EOF
  log "stopping here. Everything through 'repo checkout + toolchain' is done; service install is deferred."
  exit 0
fi

# ── Service install ────────────────────────────────────────────────────
log "-- service install --"
INSTALL_CHUMPD_SH="$CHUMPD_PROVISION_DIR/scripts/setup/install-chumpd.sh"
if [[ "$OS_KIND" == "macos" ]]; then
  if [[ -f "$INSTALL_CHUMPD_SH" ]]; then
    run "invoke install-chumpd.sh" bash "$INSTALL_CHUMPD_SH"
  else
    warn "chumpd binary target exists but scripts/setup/install-chumpd.sh does not yet" \
         "(MISSION-051 landed a binary without its installer, or this repo is between" \
         "commits) — install manually once it ships, or re-run this script."
  fi
else
  TEMPLATE="$CHUMPD_PROVISION_DIR/scripts/setup/chumpd.service"
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT_DST="$UNIT_DIR/chumpd.service"
  if [[ -f "$TEMPLATE" ]]; then
    # RESILIENT-185: write a chumpd.env template (the service reads it via
    # EnvironmentFile=). No secret VALUES — just the keys with TODO markers,
    # so the operator fills them in out-of-band (RESILIENT-173).
    CHUMPD_ENV="$HOME/.chump/chumpd.env"
    # INFRA-7815 (INFRA-3629 slice): zero-touch creds — if the caller handed
    # us a ready-made env body via --creds-file or $CHUMP_BOOTSTRAP_CREDS,
    # materialize chumpd.env straight from it instead of the TODO_ template
    # below. Never echoes secret VALUES — only which source was used and
    # which required keys are present/missing (RESILIENT-173).
    if [[ ! -f "$CHUMPD_ENV" && "$MODE" != "dry-run" && ( -n "$CREDS_FILE" || -n "${CHUMP_BOOTSTRAP_CREDS:-}" ) ]]; then
      mkdir -p "$HOME/.chump"
      if [[ -n "$CREDS_FILE" ]]; then
        [[ -f "$CREDS_FILE" ]] || { fail "--creds-file not found: $CREDS_FILE"; exit 1; }
        { printf 'CHUMP_REPO=%s\n' "$CHUMPD_PROVISION_DIR"; cat "$CREDS_FILE"; } > "$CHUMPD_ENV"
        log "materialized $CHUMPD_ENV from --creds-file (path only; values not logged)"
      else
        { printf 'CHUMP_REPO=%s\n' "$CHUMPD_PROVISION_DIR"; printf '%s\n' "$CHUMP_BOOTSTRAP_CREDS"; } > "$CHUMPD_ENV"
        log "materialized $CHUMPD_ENV from \$CHUMP_BOOTSTRAP_CREDS (env var; values not logged)"
      fi
      chmod 600 "$CHUMPD_ENV"
      missing=""
      grep -qE '^(export )?GH_TOKEN=.+' "$CHUMPD_ENV" || missing="$missing GH_TOKEN"
      if [[ -n "$missing" ]]; then
        fail "chumpd.env materialized but missing required keys:$missing — supply via --creds-file/\$CHUMP_BOOTSTRAP_CREDS and re-run"
        exit 1
      fi
      log "chumpd.env ok ($(grep -cE '^(export )?[A-Z_]+=' "$CHUMPD_ENV") keys, mode $(stat -c %a "$CHUMPD_ENV" 2>/dev/null || stat -f %Lp "$CHUMPD_ENV" 2>/dev/null))"
    fi
    if [[ ! -f "$CHUMPD_ENV" && "$MODE" != "dry-run" ]]; then
      mkdir -p "$HOME/.chump"
      cat > "$CHUMPD_ENV" <<'ENVEOF'
# chumpd.env — chumpd service environment. chmod 0600. NO SECRET VALUES IN GIT.
# Fill in the TODO_ values before starting chumpd, then: systemctl --user start chumpd
#
# Repo checkout this node operates on. MUST be set — without it chumpd falls
# back to its $HOME/Projects/Chump default and drives a phantom path (the exact
# root-of-roots path-confusion class from the EU migration). Injected below.
CHUMP_REPO=__CHUMP_REPO__
#
# Backend: "claude" (Claude subscription/API) or "chump-local" (open models via OpenRouter)
# EFFECTIVE-445 lesson: with backend=chump-local, config presence is NOT enough.
# The worker process env must actually SOURCE the ladder (this file / providers.env)
# so CHUMP_MODEL_ESCALATION_LADDER + OPENROUTER_API_KEY are in-path. Verify with a
# live 'chump --execute-gap' receipt showing 'free-tier: trying provider ... deepseek',
# never by config inspection alone (a fleet can read backend=chump-local yet still
# spawn 'claude -p' if the wrapper pins FLEET_BACKEND=claude -- the CJ divergence 2026-08-23).
CHUMPD_FLEET_BACKEND=claude
#
# --- GitHub access for PR ops (set ONE) ---
# GH_TOKEN=TODO_github_token
#
# --- If backend=claude: long-lived subscription OAuth token (from `claude setup-token`).
# This is the whole auth story for the claude backend — no refreshing token file.
# Force the oauth path so a stale/absent API key can't outrank it (project auth memory).
# CLAUDE_CODE_OAUTH_TOKEN=TODO_claude_oauth_token
# CHUMP_AUTH_MODE=oauth
#
# --- Cross-machine coordination (optional; set on every node to share one queue).
# Point at the hub's TAILNET ip (nats-broker-install.sh prints how to propagate).
# Bump the timeout on high-latency (home-NAT / DERP) links or claims fall back local.
# CHUMP_NATS_URL=nats://chump:TODO_secret@100.x.y.z:4222
# CHUMP_NATS_TIMEOUT_MS=8000
#
# --- If backend=chump-local: open-model routing (EFFECTIVE-314 cost ladder) ---
# OPENAI_API_BASE=https://openrouter.ai/api/v1
# OPENAI_MODEL=deepseek/deepseek-v4-flash
# OPENAI_API_KEY=TODO_openrouter_key
# OPENROUTER_API_KEY=TODO_openrouter_key
# RESILIENT-1009 (RESILIENT-596 slice): the floor model, escalation ladder,
# and free-tier provider list are single-sourced from the repo-committed
# scripts/setup/model-escalation-ladder.env manifest, NOT hand-copied here.
# scripts/dispatch/worker.sh sources that manifest directly (after this file)
# so it always wins — do not set CHUMP_MODEL_ESCALATION_LADDER /
# CHUMP_FREE_TIER_PROVIDERS / CHUMP_FLOOR_MODEL in this file, edits here would
# be silently overridden and would drift from the fleet's intended ladder.
# Only the referenced API-key VALUES belong here:
# OPENROUTER_API_KEY=TODO_openrouter_key
# GROQ_API_KEY=TODO_groq_key
ENVEOF
      # Substitute the real checkout path (heredoc is quoted, so do it here).
      sed -i.bak "s|__CHUMP_REPO__|$CHUMPD_PROVISION_DIR|g" "$CHUMPD_ENV" && rm -f "$CHUMPD_ENV.bak"
      chmod 600 "$CHUMPD_ENV"
      log "wrote $CHUMPD_ENV template (CHUMP_REPO=$CHUMPD_PROVISION_DIR) — fill in TODO_ secrets before starting chumpd"
    fi
    run "mkdir -p $UNIT_DIR" mkdir -p "$UNIT_DIR"
    sed -e "s|__REPO_ROOT__|$CHUMPD_PROVISION_DIR|g" -e "s|__HOME__|$HOME|g" \
      -e "s|__RUN_USER__|$(id -un)|g" \
      "$TEMPLATE" > "$UNIT_DST"
    log "wrote $UNIT_DST"
    # RESILIENT-191: workers spawned by the --user service inherit a minimal PATH
    # that lacks ~/.local/bin (chump, claude) and ~/.cargo/bin. Drop in a PATH so
    # `chump gap …` and `claude -p` resolve, or every cycle stalls "not on PATH".
    mkdir -p "$UNIT_DIR/chumpd.service.d"
    cat > "$UNIT_DIR/chumpd.service.d/path.conf" <<PATHDROP
[Service]
Environment=PATH=$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin
PATHDROP
    log "wrote PATH drop-in (chumpd.service.d/path.conf)"
    run "daemon-reload" systemctl --user daemon-reload
    run "enable chumpd.service (not started — fill chumpd.env first, then: systemctl --user start chumpd)" systemctl --user enable chumpd.service
    # RESILIENT-185: linger keeps the --user service running after SSH logout —
    # essential for a headless cabinet box you're not logged into.
    run "enable-linger (survive logout)" loginctl enable-linger "$(id -un)"

    # ── MISSION-058: self-running mission improve loop ───────────────────────
    # A systemd --user timer runs ONE `chump improve <repo> --apply` cycle per tick
    # (via `chump onboard --iter-once`), gated on AUTONOMY_LEVEL — so a provisioned
    # node autonomously works its mission repos with ZERO hand-config. Target repos:
    # CHUMP_MISSION_REPOS (comma-separated owner/repo); default = the MISSION-010
    # proof target. Cadence: CHUMP_MISSION_IMPROVE_INTERVAL_MIN (default 30).
    if [[ "$MODE" != "dry-run" ]]; then
      MISSION_REPOS="${CHUMP_MISSION_REPOS:-repairman29/BEAST-MODE}"
      IMPROVE_INTERVAL_MIN="${CHUMP_MISSION_IMPROVE_INTERVAL_MIN:-30}"
      CHUMP_BIN_PATH="$HOME/.local/bin/chump"
      IFS=',' read -r -a _mrepos <<< "$MISSION_REPOS"
      for _mr in "${_mrepos[@]}"; do
        _mr="$(echo "$_mr" | xargs)"; [[ -n "$_mr" ]] || continue
        _slug="$(echo "$_mr" | tr '/' '_' | tr 'A-Z' 'a-z')"
        _repo_dir="$HOME/.chump/external/${_mr}"
        # register + first-scan (idempotent) so the improve loop has a scan to pick from
        "$CHUMP_BIN_PATH" repos add "$_mr" >/dev/null 2>&1 || true
        if [[ ! -d "$_repo_dir/scans" ]]; then
          log "onboard $_mr (first scan for the mission loop)"
          ( set -a; [[ -f "$HOME/.chump/chumpd.env" ]] && source "$HOME/.chump/chumpd.env"; set +a
            "$CHUMP_BIN_PATH" onboard "$_mr" --apply >/dev/null 2>&1 ) \
            || warn "onboard $_mr failed (fill chumpd.env secrets, then: chump onboard $_mr --apply)"
        fi
        cat > "$UNIT_DIR/mission-improve-${_slug}.service" <<SVCEOF
[Unit]
Description=chump mission improve loop — ${_mr} (MISSION-058)
[Service]
Type=oneshot
Environment=PATH=$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-$HOME/.chump/chumpd.env
ExecStart=$CHUMP_BIN_PATH onboard --iter-once $_repo_dir
SVCEOF
        cat > "$UNIT_DIR/mission-improve-${_slug}.timer" <<TMREOF
[Unit]
Description=fire the ${_mr} improve loop every ${IMPROVE_INTERVAL_MIN}min (MISSION-058)
[Timer]
OnBootSec=5min
OnUnitActiveSec=${IMPROVE_INTERVAL_MIN}min
Persistent=true
[Install]
WantedBy=timers.target
TMREOF
        run "enable mission-improve timer for $_mr" systemctl --user enable "mission-improve-${_slug}.timer"
        log "MISSION-058: mission loop scheduled for $_mr (every ${IMPROVE_INTERVAL_MIN}min, gated on AUTONOMY_LEVEL)"
      done
    fi
  else
    warn "scripts/setup/chumpd.service template not found — skipping systemd install"
  fi
fi

# ── Validation dry-run ─────────────────────────────────────────────────
# Once chumpd exists, validate the install WITHOUT taking over fleet
# coordination: CHUMPD_TAKEOVER=0 + --mode=off means "start, prove the
# supervisor tree boots, touch no shared state, exit clean." This is
# chumpd's OWN dry-run flag (once MISSION-051 defines it), distinct from
# this provisioning script's --dry-run (which exits before reaching here).
CHUMPD_BIN="$CHUMPD_PROVISION_DIR/target/release/chumpd"
if [[ -x "$CHUMPD_BIN" ]]; then
  log "-- validation dry-run (CHUMPD_TAKEOVER=0, mode=off) --"
  # chumpd --dry-run --mode=off brings up the supervisor loop and STAYS up (it
  # never self-exits), so run it under a bounded timeout: coming up cleanly and
  # surviving the window IS the pass signal. timeout's 124 (SIGTERM window
  # elapsed) therefore counts as success; any other non-zero is a real failure.
  _rc=0
  CHUMPD_TAKEOVER=0 timeout 15 "$CHUMPD_BIN" --mode=off --dry-run || _rc=$?
  if [[ "$_rc" -eq 0 || "$_rc" -eq 124 || "$_rc" -eq 143 ]]; then
    log "OK: chumpd validation dry-run passed (came up cleanly, rc=$_rc)"
  else
    warn "chumpd validation dry-run failed or --mode=off/--dry-run flags don't exist yet" \
         "in this build — check MISSION-051's actual CLI surface once it ships."
  fi
else
  log "chumpd binary not built yet at $CHUMPD_BIN (expected pre-MISSION-051) — skipping validation dry-run"
fi

log "done. See docs/process/OFF_LAPTOP_SUBSTRATE.md for the cutover checklist."
