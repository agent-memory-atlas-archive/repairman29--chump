#!/usr/bin/env bash
# install_chump_gap_timer.sh — RESILIENT-1370
#
# Install chump-gap-close-decomposed systemd timer and service to ~/.config/systemd/user/
# This timer runs periodically to auto-close decomposed umbrella gaps when all child slices
# are done (see RESILIENT-1366 for context).
#
# INFRA-8194 (Phase R R5): the service is a placeholder TEMPLATE
# (scripts/dispatch/chump-gap-close-decomposed.service) and is RENDERED for this
# host, never copied verbatim. The old verbatim copy of a unit baked for one
# machine (a hardcoded User= plus that user's /home paths) made cuphead's user
# manager exit 217/USER every ten minutes (RESILIENT-1601). Rendering goes
# through the typed host enum (`chump node render-unit --host linux-systemd-user`,
# which never writes User= for a user manager); when no chump binary is on PATH
# yet, the shell mirror organ_unit_host_rewrite (scope=user) renders the same
# placeholders.
#
# Usage:
#   scripts/install_chump_gap_timer.sh              # install + enable + activate
#   scripts/install_chump_gap_timer.sh --check      # verify only, exit non-zero if incomplete
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_SRC="$REPO_ROOT/scripts/dispatch/chump-gap-close-decomposed.service"
TIMER_SRC="$REPO_ROOT/scripts/dispatch/chump-gap-close-decomposed.timer"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

SERVICE_NAME="chump-gap-close-decomposed.service"
TIMER_NAME="chump-gap-close-decomposed.timer"

MODE="install"
for a in "$@"; do
  case "$a" in
    --check) MODE="check" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[CHUMP-GAP-TIMER]\033[0m %s\n' "$*"; }

# render_service <dest> — typed renderer first, shell mirror as the fallback.
render_service() {
  local dest="$1" chump_bin
  chump_bin="${CHUMP_BIN:-$(command -v chump 2>/dev/null || true)}"
  if [ -n "$chump_bin" ] && "$chump_bin" node render-unit "$SERVICE_SRC" \
        --host linux-systemd-user --repo-root "$REPO_ROOT" --out "$dest" 2>/dev/null; then
    return 0
  fi
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh" || return 1
  organ_unit_host_rewrite "$SERVICE_SRC" "$dest" "$(id -un)" "$HOME" 0 "$REPO_ROOT" user
}

do_install() {
  local fail=0

  # Verify source files exist
  if [ ! -f "$SERVICE_SRC" ]; then
    no "service file not found: $SERVICE_SRC"
    return 1
  fi
  if [ ! -f "$TIMER_SRC" ]; then
    no "timer file not found: $TIMER_SRC"
    return 1
  fi

  # Create systemd user directory if it doesn't exist
  mkdir -p "$SYSTEMD_USER_DIR" || { no "failed to create $SYSTEMD_USER_DIR"; return 1; }

  # Render the service template for THIS host (INFRA-8194), then copy the timer.
  render_service "$SYSTEMD_USER_DIR/$SERVICE_NAME" || { no "failed to render service file"; return 1; }
  ok "rendered $SERVICE_NAME into $SYSTEMD_USER_DIR (no User=: user manager)"

  cp "$TIMER_SRC" "$SYSTEMD_USER_DIR/$TIMER_NAME" || { no "failed to copy timer file"; return 1; }
  ok "copied $TIMER_NAME to $SYSTEMD_USER_DIR"

  # Reload systemd configuration
  systemctl --user daemon-reload || { no "systemctl --user daemon-reload failed"; return 1; }
  ok "systemctl --user daemon-reload"

  # Enable and start the timer
  systemctl --user enable --now "$TIMER_NAME" || { no "systemctl --user enable --now failed"; return 1; }
  ok "systemctl --user enable --now $TIMER_NAME"

  # Verify the timer is active
  if systemctl --user is-active "$TIMER_NAME" >/dev/null 2>&1; then
    ok "timer is active: $TIMER_NAME"
  else
    no "timer is not active after installation"
    return 1
  fi

  info "installation complete"
  return 0
}

do_check() {
  local fail=0

  # Check if service file is in place
  if [ -f "$SYSTEMD_USER_DIR/$SERVICE_NAME" ]; then
    ok "service file exists: $SYSTEMD_USER_DIR/$SERVICE_NAME"
  else
    no "service file missing: $SYSTEMD_USER_DIR/$SERVICE_NAME"
    fail=1
  fi

  # Check if timer file is in place
  if [ -f "$SYSTEMD_USER_DIR/$TIMER_NAME" ]; then
    ok "timer file exists: $SYSTEMD_USER_DIR/$TIMER_NAME"
  else
    no "timer file missing: $SYSTEMD_USER_DIR/$TIMER_NAME"
    fail=1
  fi

  # Check if timer is enabled
  if systemctl --user is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
    ok "timer is enabled: $TIMER_NAME"
  else
    no "timer is not enabled: $TIMER_NAME"
    fail=1
  fi

  # Check if timer is active
  if systemctl --user is-active "$TIMER_NAME" >/dev/null 2>&1; then
    ok "timer is active: $TIMER_NAME"
  else
    no "timer is not active: $TIMER_NAME"
    fail=1
  fi

  return "$fail"
}

if [ "$MODE" = "check" ]; then
  info "checking installation"
  do_check
  exit $?
else
  info "installing chump-gap-close-decomposed timer"
  do_install
  exit $?
fi
