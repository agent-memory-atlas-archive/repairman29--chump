#!/usr/bin/env bash
# install-almanac-organ.sh — INFRA-3710 (INFRA-3635 slice).
#
# The "eyes" phase: registers periodic supervision of
# scripts/ops/almanac-liveness-refresh.sh (INFRA-3643/TREK-17) so a
# freshly-installed node keeps its almanac fusion-search index alive without
# a human ever running anything by hand. Before this gap, that liveness
# script existed and was wired into the ROOT-only, helsinki-shaped
# install-helsinki-atc.sh system-unit roster — but chump-node-install.sh (the
# per-user, host-agnostic node installer) never called it, so an owned node
# installed via node-install got every organ EXCEPT eyes.
#
# This script is deliberately independent of install-helsinki-atc.sh's
# root/system-unit path: it runs as the invoking user, picks the lightest
# supervisor available (systemd --user timer > launchd agent > cron
# fallback), and is idempotent + safe to re-run.
#
# Usage:
#   scripts/setup/install-almanac-organ.sh                # install + run once now
#   scripts/setup/install-almanac-organ.sh --check         # verify only, exit non-zero if incomplete
#   scripts/setup/install-almanac-organ.sh --dry-run
#
# Env (mirrors almanac-liveness-refresh.sh so both agree on the same paths):
#   CHUMP_ALMANAC_BIN     — almanac binary (default: $HOME/Projects/almanac/target/release/almanac)
#   CHUMP_ALMANAC_REPO    — almanac source checkout (default: $HOME/Projects/almanac)
#   CHUMP_STATE_DIR       — chump state dir, for the ambient log (default: $HOME/.chump)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIVENESS_SCRIPT="$REPO_ROOT/scripts/ops/almanac-liveness-refresh.sh"
export CHUMP_STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
export CHUMP_ALMANAC_REPO="${CHUMP_ALMANAC_REPO:-$HOME/Projects/almanac}"
export CHUMP_ALMANAC_BIN="${CHUMP_ALMANAC_BIN:-$CHUMP_ALMANAC_REPO/target/release/almanac}"
# Bare aliases so the rest of this script (written before RESILIENT-1111's
# rename to exported CHUMP_* vars) keeps working without a full rename.
STATE_DIR="$CHUMP_STATE_DIR"
ALMANAC_REPO="$CHUMP_ALMANAC_REPO"
ALMANAC_BIN="$CHUMP_ALMANAC_BIN"

MODE="install"; DRY=0
for a in "$@"; do
  case "$a" in
    --check) MODE="check";;
    --dry-run) DRY=1;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $a" >&2; exit 2;;
  esac
done

# ---------- PREFLIGHT (INFRA-3710) ----------
# Reuse detect_host()/ensure_home()/toolchain_preflight()/ensure_rust() from
# chump-node-install.sh instead of re-deriving OS branches here. That file
# guards its own top-level "run" body behind a `BASH_SOURCE == $0` check
# (INFRA-3710) specifically so it can be sourced for its functions without
# also triggering a full node install as a side effect.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chump-node-install.sh"
if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "ERROR: $INSTALL_SCRIPT not found — cannot proceed" >&2
  exit 1
fi
# Preserve our own --dry-run choice and clear our own args before sourcing
# so (a) chump-node-install.sh's arg parser (which reads "$@") doesn't choke
# on this script's --check/--dry-run, and (b) its unconditional "DRY=0"
# doesn't silently clobber ours.
_ORGAN_DRY="$DRY"
set --
# shellcheck disable=SC1091
source "$INSTALL_SCRIPT"
DRY="$_ORGAN_DRY"

# Local helpers redefined AFTER sourcing so they take precedence over
# chump-node-install.sh's same-named ok/no/info/run (its info() takes a
# separate tag arg; this script's callers pass one combined message).
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[EYES]\033[0m %s\n' "$*"; }
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

detect_host
info "detected host=$HOST_KIND arch=$ARCH"
info "ALMANAC_DIR=$ALMANAC_REPO"

# AC4: provision the Rust toolchain via the existing host-agnostic path
# before any cargo build could happen below.
toolchain_preflight

# INFRA-4660 (INFRA-3637 slice): clone+build was carved out into
# install-almanac.sh (RESILIENT-403) instead of being re-derived here.
# Call it on a clean host (install mode only) so ensure_eyes actually
# results in a live checkout instead of silently no-op'ing forever.
# --check never mutates; it falls through to do_check() below, which
# already reports a missing binary/checkout as a failure.
if [ ! -d "$ALMANAC_REPO" ] && [ "$MODE" != "check" ]; then
  installer="$REPO_ROOT/scripts/setup/install-almanac.sh"
  if [ -x "$installer" ]; then
    info "no almanac checkout at $ALMANAC_REPO — cloning+building via install-almanac.sh"
    if [ "$DRY" = 1 ]; then
      bash "$installer" --dry-run || true
    else
      bash "$installer" || { no "install-almanac.sh failed — see above"; exit 1; }
    fi
  else
    no "no almanac checkout at $ALMANAC_REPO and install-almanac.sh not found — cannot provision eyes"
    exit 1
  fi
fi

if [ ! -x "$LIVENESS_SCRIPT" ]; then
  no "liveness script missing or not executable: $LIVENESS_SCRIPT"
  exit 1
fi

LABEL="com.chump.almanac-liveness"
LOG_DIR="$STATE_DIR/logs"

detect_supervisor() {
  if [ -n "${PREFIX:-}" ] && printf '%s' "$PREFIX" | grep -q 'com.termux'; then
    echo "runit"
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    echo "systemd-user"
  elif command -v launchctl >/dev/null 2>&1; then
    echo "launchd"
  elif command -v crontab >/dev/null 2>&1; then
    echo "cron"
  else
    echo "none"
  fi
}

install_systemd_user() {
  local unit_dir="$HOME/.config/systemd/user"
  run "mkdir -p '$unit_dir' '$LOG_DIR'"
  run "cat > '$unit_dir/chump-almanac-liveness.service' <<EOF
[Unit]
Description=Chump almanac liveness/refresh — binary presence + index freshness (INFRA-3710/INFRA-3643)

[Service]
Type=oneshot
Environment=CHUMP_STATE_DIR=$STATE_DIR
Environment=CHUMP_ALMANAC_REPO=$ALMANAC_REPO
Environment=CHUMP_ALMANAC_BIN=$ALMANAC_BIN
ExecStart=$LIVENESS_SCRIPT
EOF"
  run "cat > '$unit_dir/chump-almanac-liveness.timer' <<EOF
[Unit]
Description=Chump almanac liveness/refresh beat (INFRA-3710/INFRA-3643)

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF"
  run "systemctl --user daemon-reload"
  run "systemctl --user enable --now chump-almanac-liveness.timer"
  ok "systemd --user timer installed: chump-almanac-liveness.timer (every 15min)"
}

install_launchd() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/$LABEL.plist"
  run "mkdir -p '$plist_dir' '$LOG_DIR'"
  run "cat > '$plist_path' <<PLIST
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>-lc</string><string>$LIVENESS_SCRIPT</string></array>
    <key>StartInterval</key><integer>900</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/almanac-liveness.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/almanac-liveness.err.log</string>
</dict>
</plist>
PLIST"
  run "launchctl unload '$plist_path' 2>/dev/null || true"
  run "launchctl load '$plist_path'"
  ok "launchd agent installed: $plist_path (every 15min)"
}

install_cron() {
  run "mkdir -p '$LOG_DIR'"
  local marker="# chump-almanac-liveness (INFRA-3710)"
  local line="*/15 * * * * $LIVENESS_SCRIPT >> $LOG_DIR/almanac-liveness.log 2>&1 $marker"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: crontab -l | grep -v '$marker' ; append: $line"
  else
    ( crontab -l 2>/dev/null | grep -vF "$marker"; echo "$line" ) | crontab -
  fi
  ok "cron fallback installed: every 15min ($marker)"
}

install_runit() {
  local svc_dir="$PREFIX/var/service/chump-almanac-liveness"
  run "mkdir -p '$svc_dir/log' '$LOG_DIR'"
  run "cat > '$svc_dir/run' <<'RUNEOF'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
CHUMP_STATE_DIR=${CHUMP_STATE_DIR:-$HOME/.chump}
CHUMP_ALMANAC_REPO=${CHUMP_ALMANAC_REPO:-$HOME/Projects/almanac}
CHUMP_ALMANAC_BIN=${CHUMP_ALMANAC_BIN:-$CHUMP_ALMANAC_REPO/target/release/almanac}
while true; do
  $LIVENESS_SCRIPT
  sleep 900
done
RUNEOF"
  run "chmod +x '$svc_dir/run'"
  run "cat > '$svc_dir/log/run' <<'LOGEOF'
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt '$LOG_DIR'
LOGEOF"
  run "chmod +x '$svc_dir/log/run'"
  ok "runit service installed: $svc_dir (every 15min loop)"
}

do_install() {
  local sup; sup="$(detect_supervisor)"
  info "supervisor=$sup"
  case "$sup" in
    systemd-user) install_systemd_user;;
    launchd) install_launchd;;
    cron) install_cron;;
    runit) install_runit;;
    *) no "no supervisor available (systemd --user, launchd, cron, runit) — organ not supervised; run $LIVENESS_SCRIPT by hand periodically"; return 1;;
  esac
  info "running liveness/refresh once now (immediate self-heal, no hand steps)"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: $LIVENESS_SCRIPT"
  else
    CHUMP_STATE_DIR="$STATE_DIR" CHUMP_ALMANAC_REPO="$ALMANAC_REPO" CHUMP_ALMANAC_BIN="$ALMANAC_BIN" "$LIVENESS_SCRIPT" || true
  fi
}

do_check() {
  local fail=0
  if [ -x "$ALMANAC_BIN" ]; then ok "almanac binary present: $ALMANAC_BIN"
  else no "almanac binary missing: $ALMANAC_BIN"; fail=1; fi
  local sup; sup="$(detect_supervisor)"
  case "$sup" in
    systemd-user)
      if systemctl --user is-enabled chump-almanac-liveness.timer >/dev/null 2>&1; then
        ok "systemd --user timer enabled: chump-almanac-liveness.timer"
      else no "systemd --user timer NOT enabled"; fail=1; fi
      ;;
    launchd)
      if launchctl list 2>/dev/null | grep -q "$LABEL"; then ok "launchd agent loaded: $LABEL"
      else no "launchd agent NOT loaded: $LABEL"; fail=1; fi
      ;;
    cron)
      if crontab -l 2>/dev/null | grep -q "chump-almanac-liveness"; then ok "cron entry present"
      else no "cron entry missing"; fail=1; fi
      ;;
    runit)
      if [ -d "$PREFIX/var/service/chump-almanac-liveness" ]; then ok "runit service present: chump-almanac-liveness"
      else no "runit service NOT present: chump-almanac-liveness"; fail=1; fi
      ;;
  esac
  # best-effort stats probe: at least one registered repo with a nonzero row
  # count proves the index is actually populated, not just present-but-empty.
  if [ -x "$ALMANAC_BIN" ] && command -v timeout >/dev/null 2>&1; then
    local repos; repos="$(timeout 10 "$ALMANAC_BIN" repos 2>/dev/null | awk 'NR>1{print $1}')"
    if [ -n "$repos" ]; then
      ok "almanac has $(echo "$repos" | wc -l | tr -d ' ') registered repo(s)"
    else
      no "almanac stats probe inconclusive (no repos listed / binary slow) — not fatal, check by hand"
    fi
  fi
  [ "$fail" = 0 ] && ok "EYES organ: installed + supervised" || no "EYES organ incomplete"
  return "$fail"
}

if [ "$MODE" = "check" ]; then do_check; exit $?; fi
do_install
do_check
