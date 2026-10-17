#!/usr/bin/env bash
# install-self-hosted-runner.sh — INFRA-1534
#
# Provisions a GitHub Actions self-hosted runner on this machine and registers
# it as a launchd service so it survives reboots. The runner lets Chump
# bypass GitHub's org-tier concurrency cap that gates CI throughput today.
#
# Architecture rationale: docs/process/SELF_HOSTED_RUNNERS.md
#
# Usage:
#   scripts/setup/install-self-hosted-runner.sh                # interactive install
#   scripts/setup/install-self-hosted-runner.sh --check        # verify registered + online; exit 0/1
#   scripts/setup/install-self-hosted-runner.sh --uninstall    # remove cleanly
#   scripts/setup/install-self-hosted-runner.sh --token TOKEN  # non-interactive with explicit token
#   scripts/setup/install-self-hosted-runner.sh --upgrade      # patch existing runners' plists in-place (PATH + reload)
#
# Idempotent: re-running does nothing if a healthy runner is already registered.
# --upgrade is idempotent too: scans com.chump.actions-runner*.plist, rewrites
# PATH to include ~/.cargo/bin + ~/.local/bin, bootouts + bootstraps each.
#
# Runner PATH includes ~/.cargo/bin and ~/.local/bin so workflow steps that
# invoke `chump`, `cargo`, or other user-built binaries resolve correctly.
# Discovered 2026-05-16 (INFRA-1556): bare /opt/homebrew/bin PATH caused
# `chump gap show` to exit 127, breaking fast-checks on the M4 lane.
#
# Rust-First-Bypass: install wrapper around the upstream GitHub actions-runner
# tarball; pure shell glue around curl + tar + launchctl + gh api; no state
# mutation outside ~/actions-runner-chump/. Per META-064 shell-OK criteria.

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-chump}"
RUNNER_NAME_DEFAULT="$(hostname -s | tr '[:upper:]' '[:lower:]')"
RUNNER_NAME="${RUNNER_NAME:-$RUNNER_NAME_DEFAULT}"
RUNNER_LABELS_DEFAULT="self-hosted,macos-arm64,chump-fleet"
RUNNER_LABELS="${RUNNER_LABELS:-$RUNNER_LABELS_DEFAULT}"

# PATH baked into the launchd plist. INFRA-1556:
#   - ~/.cargo/bin: rustup shim location (cargo, rustc when rustup-managed)
#   - ~/.rustup/toolchains/<host-triple>/bin: real toolchain when ~/.cargo/bin
#     shim is broken/missing (real-world case discovered on M4 where the
#     ~/.cargo/bin/cargo symlink dangles)
#   - ~/.local/bin: alternate chump install location
RUNNER_RUSTUP_HOST_BIN=""
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  RUNNER_RUSTUP_HOST_BIN="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin" ;;
  Darwin-x86_64) RUNNER_RUSTUP_HOST_BIN="$HOME/.rustup/toolchains/stable-x86_64-apple-darwin/bin" ;;
  Linux-aarch64) RUNNER_RUSTUP_HOST_BIN="$HOME/.rustup/toolchains/stable-aarch64-unknown-linux-gnu/bin" ;;
  Linux-x86_64)  RUNNER_RUSTUP_HOST_BIN="$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin" ;;
esac
RUNNER_PATH_DEFAULT="$HOME/.cargo/bin"
[ -n "$RUNNER_RUSTUP_HOST_BIN" ] && RUNNER_PATH_DEFAULT="$RUNNER_PATH_DEFAULT:$RUNNER_RUSTUP_HOST_BIN"
RUNNER_PATH_DEFAULT="$RUNNER_PATH_DEFAULT:$HOME/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
RUNNER_PATH="${RUNNER_PATH:-$RUNNER_PATH_DEFAULT}"

# Detect arch + os for the right tarball
case "$(uname -s)" in
  Darwin)  PLATFORM="osx"  ;;
  Linux)   PLATFORM="linux" ;;
  *)       echo "ERROR: unsupported OS $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="x64"   ;;
  *)             echo "ERROR: unsupported arch $(uname -m)"; exit 1 ;;
esac

LATEST_VERSION_URL="https://api.github.com/repos/actions/runner/releases/latest"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

cmd_check() {
  # Health check: query GH API for runners; assert at least one online for this repo.
  # INFRA-1568: --check now ALSO delegates to the broad canary so a runner is
  # never declared ready until the full production-step set passes against it.
  # Set CHUMP_SKIP_CANARY=1 to skip (emits kind=runner_canary_skipped to
  # .chump-locks/ambient.jsonl for audit).
  if ! command -v gh >/dev/null 2>&1; then
    echo "FAIL: gh CLI not installed"
    exit 1
  fi
  local online
  online=$(gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.status=="online") | .name' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$online" -lt 1 ]; then
    echo "FAIL: no online self-hosted runners for $REPO_OWNER/$REPO_NAME"
    echo "Hint: install one with 'scripts/setup/install-self-hosted-runner.sh'"
    exit 1
  fi

  echo "OK: $online self-hosted runner(s) online for $REPO_OWNER/$REPO_NAME"
  gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | "  - \(.name) [\(.os)] labels=\(.labels | map(.name) | join(","))"' 2>/dev/null

  # INFRA-1568: broad canary gates "runner is ready" — narrow registration
  # check is necessary but not sufficient. The 2026-05-16 cascade landed
  # because narrow canary returned OK while three production steps were
  # broken (INFRA-1556 chump-PATH, INFRA-1539 apt-guard, INFRA-1561 acp).
  emit_canary_skipped_event() {
    local reason="$1"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local ambient="$repo_root/.chump-locks/ambient.jsonl"
    mkdir -p "$repo_root/.chump-locks" 2>/dev/null || true
    printf '{"ts":"%s","kind":"runner_canary_skipped","reason":"%s","host":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" "$(hostname -s 2>/dev/null || echo unknown)" \
      >> "$ambient" 2>/dev/null || true
  }

  if [ "${CHUMP_SKIP_CANARY:-0}" = "1" ] || [ "${SKIP_CANARY:-0}" = "1" ]; then
    echo "WARN: --skip-canary set (CHUMP_SKIP_CANARY=1) — runner declared ready WITHOUT broad-canary pass."
    echo "WARN: This bypasses the INFRA-1568 lane-readiness gate. Logging to ambient.jsonl."
    emit_canary_skipped_event "operator_override"
    exit 0
  fi

  local canary_script
  canary_script="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/setup/test-runner-lane-broad-canary.sh"
  if [ ! -x "$canary_script" ]; then
    echo "WARN: broad canary script not found at $canary_script"
    echo "WARN: skipping canary gate. Run from a Chump checkout for full validation."
    emit_canary_skipped_event "canary_script_missing"
    exit 0
  fi

  echo
  echo "── Broad canary (INFRA-1568) ──"
  echo "Running full production-step set against this lane. Set CHUMP_SKIP_CANARY=1 to skip."
  if bash "$canary_script"; then
    echo "OK: broad canary passed — runner is ready."
    exit 0
  else
    echo "FAIL: broad canary detected production-step failures. Runner is NOT ready." >&2
    echo "Fix the failing steps before relying on this lane for production CI." >&2
    exit 1
  fi
}

ensure_chump_installed() {
  # INFRA-1556: workflow steps call `chump`; ensure the binary exists somewhere
  # on $RUNNER_PATH before the runner registers. If absent + we're in a Chump
  # checkout, attempt to install. If absent + not in a Chump checkout, warn.
  if command -v chump >/dev/null 2>&1; then
    return 0
  fi
  for d in "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    if [ -x "$d/chump" ]; then return 0; fi
  done

  # Not on PATH and not in expected install dirs. Try to install if we're in a
  # Chump checkout.
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo_root" ] && [ -f "$repo_root/Cargo.toml" ] && grep -q '^name = "chump"' "$repo_root/Cargo.toml"; then
    echo "Installing chump binary via cargo install (one-time setup)..."
    (cd "$repo_root" && cargo install --path . --bin chump --quiet) || {
      echo "WARN: cargo install chump failed. Workflow steps that call chump will exit 127 until fixed."
      return 1
    }
    echo "Installed chump to $HOME/.cargo/bin/chump"
    return 0
  fi

  echo "WARN: chump binary not found on PATH and we're not in a Chump checkout."
  echo "WARN: Workflow steps that call 'chump' will fail with exit 127 on this runner."
  echo "WARN: To fix: run from a chump repo clone, or 'cargo install --path /path/to/chump'."
  return 1
}

cmd_upgrade() {
  # INFRA-1556: retroactively patch the PATH of every existing chump runner plist.
  # Idempotent — safe to re-run.
  shopt -s nullglob
  local plists=( "$HOME/Library/LaunchAgents/com.chump.actions-runner"*.plist )
  if [ "${#plists[@]}" -eq 0 ]; then
    echo "No chump runner plists found at ~/Library/LaunchAgents/com.chump.actions-runner*.plist"
    echo "Nothing to upgrade. Run install (no args) to add a new runner."
    exit 0
  fi
  local patched=0
  for plist in "${plists[@]}"; do
    # Extract current PATH from the plist and compare exactly to RUNNER_PATH.
    local current
    current=$(awk '
      /<key>PATH<\/key>/ { in_path=1; next }
      in_path && /<string>/ {
        sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit
      }
    ' "$plist" 2>/dev/null)
    if [ "$current" = "$RUNNER_PATH" ]; then
      echo "  already up-to-date: $plist"
      continue
    fi
    # Replace the <string>...PATH...</string> line under the PATH key.
    local tmp
    tmp=$(mktemp)
    awk -v new_path="$RUNNER_PATH" '
      /<key>PATH<\/key>/ { in_path=1; print; next }
      in_path && /<string>/ { sub(/<string>[^<]*<\/string>/, "<string>" new_path "</string>"); in_path=0 }
      { print }
    ' "$plist" > "$tmp" && mv "$tmp" "$plist"
    # Reload
    launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$plist" 2>&1 | head -1 | sed 's/^/    /'
    echo "  upgraded + reloaded: $plist"
    patched=$((patched + 1))
  done
  echo "Upgrade complete: $patched plist(s) patched."
  exit 0
}

cmd_uninstall() {
  local plist="$HOME/Library/LaunchAgents/com.chump.actions-runner.plist"
  if [ -f "$plist" ]; then
    launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "Removed launchd plist."
  fi
  if [ -d "$RUNNER_DIR" ]; then
    if [ -x "$RUNNER_DIR/config.sh" ] && [ -n "${TOKEN:-}" ]; then
      (cd "$RUNNER_DIR" && ./config.sh remove --token "$TOKEN") || true
    fi
    rm -rf "$RUNNER_DIR"
    echo "Removed runner directory $RUNNER_DIR."
  fi
  echo "Uninstall complete. Verify via: ./install-self-hosted-runner.sh --check"
}

cmd_install() {
  # 0. Pre-flight
  if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
    echo "Runner already configured at $RUNNER_DIR — re-running is a no-op."
    echo "Use --uninstall to remove, --upgrade to refresh plist PATH, or --check to verify."
    exit 0
  fi

  # 0b. Ensure chump CLI is reachable from the runner's effective PATH (INFRA-1556)
  ensure_chump_installed || true   # warn-only; runner still installs

  if [ -z "${TOKEN:-}" ]; then
    if command -v gh >/dev/null 2>&1; then
      echo "Fetching registration token from GitHub API..."
      TOKEN=$(gh api -X POST "/repos/$REPO_OWNER/$REPO_NAME/actions/runners/registration-token" \
        --jq '.token' 2>/dev/null || true)
    fi
  fi

  if [ -z "${TOKEN:-}" ]; then
    cat <<EOF
ERROR: no registration token available.

Get one manually:
  1. Visit https://github.com/$REPO_OWNER/$REPO_NAME/settings/actions/runners/new
  2. Copy the token shown
  3. Re-run: $0 --token <TOKEN>

Or ensure 'gh' CLI is installed and authenticated with admin:repo scope.
EOF
    exit 1
  fi

  # 1. Get latest version
  echo "Fetching latest actions-runner version..."
  local version tarball_url
  version=$(curl -fsSL "$LATEST_VERSION_URL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
  tarball_url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-${PLATFORM}-${ARCH}-${version}.tar.gz"
  echo "Version: $version"
  echo "Tarball: $tarball_url"

  # 2. Download + extract
  mkdir -p "$RUNNER_DIR"
  cd "$RUNNER_DIR"
  echo "Downloading runner..."
  curl -fsSL -o runner.tar.gz "$tarball_url"
  tar xzf runner.tar.gz
  rm runner.tar.gz

  # 3. Configure (non-interactive)
  echo "Registering runner $RUNNER_NAME with labels $RUNNER_LABELS..."
  ./config.sh \
    --url "https://github.com/$REPO_OWNER/$REPO_NAME" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work "_work" \
    --unattended \
    --replace

  # 4. Install as launchd service (macOS)
  if [ "$PLATFORM" = "osx" ]; then
    local plist="$HOME/Library/LaunchAgents/com.chump.actions-runner.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Chump"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.actions-runner</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RUNNER_DIR/run.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$RUNNER_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/Chump/actions-runner.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/Chump/actions-runner.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$RUNNER_PATH</string>
    </dict>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$UID" "$plist"
    echo "launchd service installed: $plist"
  else
    echo "On Linux: install as systemd unit manually. Service script at $RUNNER_DIR/svc.sh"
  fi

  echo
  echo "Install complete. Verify in 30 seconds with:"
  echo "  scripts/setup/install-self-hosted-runner.sh --check"
  echo
  echo "View logs:"
  echo "  tail -f $HOME/Library/Logs/Chump/actions-runner.log"

  # INFRA-1568: tighten exit condition — installing the runner is not the same
  # as declaring the lane production-ready. The broad canary asserts every
  # production workflow step still passes on this lane before we exit 0.
  if [ "${SKIP_CANARY:-0}" = "1" ]; then
    echo
    echo "WARN: --skip-canary / CHUMP_SKIP_CANARY=1 — exiting 0 without broad-canary validation."
    echo "WARN: Lane is registered but NOT validated for production CI."
    emit_install_canary_skipped_event() {
      local repo_root
      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      local ambient="$repo_root/.chump-locks/ambient.jsonl"
      mkdir -p "$repo_root/.chump-locks" 2>/dev/null || true
      printf '{"ts":"%s","kind":"runner_canary_skipped","reason":"%s","host":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "install_skip_canary_flag" "$(hostname -s 2>/dev/null || echo unknown)" \
        >> "$ambient" 2>/dev/null || true
    }
    emit_install_canary_skipped_event
    exit 0
  fi

  local canary_script
  canary_script="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/setup/test-runner-lane-broad-canary.sh"
  if [ -x "$canary_script" ]; then
    echo
    echo "── Broad canary (INFRA-1568) — gates exit-0 ──"
    echo "Asserting full production-step set passes on this lane before declaring ready."
    if ! bash "$canary_script"; then
      echo "FAIL: broad canary detected production-step failures." >&2
      echo "Runner is registered with GitHub but is NOT yet production-ready." >&2
      echo "Fix the failing steps, then re-run --check to confirm readiness." >&2
      exit 1
    fi
    echo "OK: broad canary passed — runner is production-ready."
  fi
}

# Dispatch
TOKEN=""
SKIP_CANARY="${SKIP_CANARY:-${CHUMP_SKIP_CANARY:-0}}"
# Allow --skip-canary anywhere in the argv.
for a in "$@"; do
  case "$a" in
    --skip-canary) SKIP_CANARY=1 ;;
  esac
done
export SKIP_CANARY CHUMP_SKIP_CANARY="$SKIP_CANARY"

case "${1:-}" in
  --check)     cmd_check  ;;
  --uninstall) shift; while [ $# -gt 0 ]; do case "$1" in --token) TOKEN="$2"; shift 2 ;; *) shift ;; esac; done; cmd_uninstall ;;
  --upgrade)   cmd_upgrade ;;
  --token)     TOKEN="${2:-}"; cmd_install ;;
  --skip-canary) cmd_install ;;
  -h|--help)   usage 0 ;;
  "")          cmd_install ;;
  *)           echo "Unknown arg: $1"; usage 1 ;;
esac
