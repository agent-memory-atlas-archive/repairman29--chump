#!/usr/bin/env bash
# Build Chump Cowork as a double-clickable macOS .app (Dock / Applications).
#
# Prerequisites: Rust, Xcode CLT; once: `cargo install tauri-cli` (script can install if missing).
# Usage (repo root):
#   ./scripts/setup/macos-cowork-dock-app.sh
# Optional:
#   CHUMP_HOME=/path/to/Chump  — repo with .env (defaults to parent of scripts/)
#   CHUMP_BUNDLE_RETAIL=1     — omit CHUMP_HOME / CHUMP_REPO from LSEnvironment so the first-run
#                               wizard writes ~/Library/Application Support/Chump/.env (novice OOTB).
#   OPEN_APP=1                — open the .app when done
#
# After build: drag "Chump.app" to /Applications or the Dock. First launch may require
# Right-click → Open (Gatekeeper) until Apple notarizes a distribution build.

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"
[[ "$(uname -s)" == "Darwin" ]] || {
  echo "This script is macOS-only."
  exit 2
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_HOME="${CHUMP_HOME:-$ROOT}"
export PATH="${HOME}/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:${PATH}"

command -v cargo >/dev/null 2>&1 || {
  echo "cargo not found"
  exit 1
}

if ! cargo tauri --version >/dev/null 2>&1; then
  echo "Installing tauri-cli (one-time, ~minutes)…"
  cargo install tauri-cli --locked
fi

echo "== 1/4 Release chump (workspace) =="
cargo build --release --manifest-path "$ROOT/Cargo.toml" --bin chump

echo "== 2/4 Tauri bundle =="
cd "$ROOT/desktop/src-tauri"
cargo tauri build

echo "== 3/4 Locate Chump.app and copy chump into MacOS/ =="
# Workspace packages put the bundle under repo-root target/ (not always desktop/src-tauri/target/).
APP="$(find "$ROOT/target" "$ROOT/desktop/src-tauri/target" -name "Chump.app" -type d 2>/dev/null | head -n 1 || true)"

if [[ -z "${APP:-}" ]] || [[ ! -d "$APP" ]]; then
  echo "Could not find Chump.app under target/. Try: cd $ROOT/desktop/src-tauri && cargo tauri build" >&2
  exit 1
fi

MACOS="$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"
SRC="$ROOT/target/release/chump"
[[ -x "$SRC" ]] || SRC="$ROOT/target/release/chump"
if [[ ! -x "$SRC" ]]; then
  echo "Missing $ROOT/target/release/chump (build chump --release first)" >&2
  exit 1
fi
cp -f "$SRC" "$MACOS/chump"
chmod +x "$MACOS/chump"

echo "== 4/4 Info.plist LSEnvironment (CHUMP_BINARY + PATH; optional CHUMP_HOME) =="
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST" 2>/dev/null || true
for key in CHUMP_HOME CHUMP_REPO CHUMP_BINARY PATH; do
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:${key}" "$PLIST" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHUMP_BINARY string ${MACOS}/chump" "$PLIST"
PATH_EXPORT="${HOME}/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:PATH string ${PATH_EXPORT}" "$PLIST"
if [[ "${CHUMP_BUNDLE_RETAIL:-}" == "1" ]]; then
  echo "Retail OOTB: LSEnvironment has no CHUMP_HOME (sidecar cwd comes from Application Support after wizard)."
else
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHUMP_HOME string ${CHUMP_HOME}" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHUMP_REPO string ${CHUMP_HOME}" "$PLIST"
fi

if codesign --force --deep -s - "$APP" 2>/dev/null; then
  echo "Ad-hoc codesign OK."
else
  echo "codesign not applied; if the app won't open, try: codesign --force --deep -s - \"$APP\""
fi

echo ""
echo "Done."
echo "  App: $APP"
if [[ "${CHUMP_BUNDLE_RETAIL:-}" == "1" ]]; then
  echo "  LSEnvironment: retail OOTB (no CHUMP_HOME; wizard writes Application Support .env)."
else
  echo "  CHUMP_HOME in bundle: $CHUMP_HOME"
fi
echo "  → Drag Chump.app to /Applications or the Dock, then open it."
echo "  First time: if blocked, Right-click → Open."
if [[ "${OPEN_APP:-}" == "1" ]]; then
  open "$APP"
fi
