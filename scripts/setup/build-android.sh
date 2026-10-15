#!/usr/bin/env bash
# Cross-compile Chump for Android (aarch64) from macOS.
# Requires: rustup target add aarch64-linux-android, Android NDK installed.
#
# Usage:
#   ./scripts/setup/build-android.sh              # build only
#   ./scripts/setup/build-android.sh --deploy user@192.168.1.42   # build + scp to Pixel

set -e
cd "$(dirname "$0")/.."

# --- NDK detection ---
if [[ -z "$ANDROID_NDK_HOME" ]]; then
  for candidate in \
    /opt/homebrew/share/android-ndk \
    "$HOME/Library/Android/sdk/ndk/"* \
    /usr/local/share/android-ndk; do
    if [[ -d "$candidate/toolchains" ]]; then
      export ANDROID_NDK_HOME="$candidate"
      break
    fi
  done
fi

if [[ -z "$ANDROID_NDK_HOME" ]]; then
  echo "Error: ANDROID_NDK_HOME not set and NDK not found in common locations."
  echo "Install via: brew install --cask android-ndk"
  echo "Or set ANDROID_NDK_HOME to your NDK path."
  exit 1
fi

# Prefer darwin-aarch64 on Apple Silicon, fallback to darwin-x86_64
if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-aarch64/bin" ]]; then
  TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-aarch64/bin"
else
  TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
fi
export CC_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"
# RESILIENT-336: openssl-vendored (target-scoped) cross-build needs llvm-ranlib —
# openssl-src guesses a nonexistent `aarch64-linux-android-ranlib` otherwise and
# dies with `make install_dev Error 127`.
export RANLIB_aarch64_linux_android="$TOOLCHAIN/llvm-ranlib"
# Cargo invokes the linker for the final binary; rustc defaults to "cc" otherwise
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN/aarch64-linux-android28-clang"

if [[ ! -f "$CC_aarch64_linux_android" ]]; then
  echo "Error: Clang not found at $CC_aarch64_linux_android"
  echo "Check your NDK installation. Expected API level 28+ linker."
  echo "Contents of toolchain bin:"
  ls "$TOOLCHAIN"/aarch64-linux-android*-clang 2>/dev/null || echo "  (none found)"
  exit 1
fi

echo "=== Chump Android Build ==="
echo "NDK:    $ANDROID_NDK_HOME"
echo "CC:     $CC_aarch64_linux_android"
echo "Target: aarch64-linux-android"
echo ""

# Ensure target std is installed. rustup is not always on PATH (this machine
# symlinks cargo/rustc directly into the toolchain), so fall back to checking the
# rustlib dir directly before trying `rustup target add`.
_rustlib_target="$(rustc --print sysroot 2>/dev/null)/lib/rustlib/aarch64-linux-android"
if [[ ! -d "$_rustlib_target" ]]; then
  if command -v rustup >/dev/null 2>&1; then
    echo "Installing Rust target aarch64-linux-android..."
    rustup target add aarch64-linux-android
  else
    echo "Error: aarch64-linux-android rust-std not installed and rustup not on PATH."
    echo "Install manually: download rust-std-<ver>-aarch64-linux-android.tar.xz from"
    echo "static.rust-lang.org/dist and extract its rustlib dir into:"
    echo "  $(rustc --print sysroot 2>/dev/null)/lib/rustlib/"
    exit 1
  fi
fi

echo "Building (release, --no-default-features: drop web-push so the Android"
echo "  cross-build does not pull web-push -> ece -> openssl-sys)..."

# RESILIENT-468: Enable sccache for Android builds if available.
SCCACHE_WRAPPER="${SCCACHE_WRAPPER_LIB:-$(dirname "$0")/../coord/lib/sccache-wrapper.sh}"
if [ -f "$SCCACHE_WRAPPER" ]; then
    # shellcheck source=/dev/null
    source "$SCCACHE_WRAPPER"
    sccache_maybe_enable
    echo "sccache: $([ "${RUSTC_WRAPPER:-}" = "sccache" ] && echo "enabled" || echo "not available")"
fi

# Use a dedicated target dir for Android builds so concurrent Mac builds
# (e.g. deploy-mac.sh or self-reboot.sh) never hit the cargo lock contention.
# The intermediate caches are NOT shared (no sysroot overlap) so this is safe.
ANDROID_TARGET_DIR="${ANDROID_TARGET_DIR:-$PWD/target-android}"
CARGO_TARGET_DIR="$ANDROID_TARGET_DIR" \
    RUSTC_WRAPPER="${RUSTC_WRAPPER:-}" \
    SCCACHE_DIR="${SCCACHE_DIR:-}" \
    SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-}" \
    cargo build --release --target aarch64-linux-android --no-default-features

# RESILIENT-468: Report sccache statistics if caching was active.
if [ -n "${SCCACHE_WRAPPER:-}" ] && command -v sccache >/dev/null 2>&1; then
    sccache_maybe_report
fi

# Binary name comes from Cargo.toml [[bin]] (chump); keep rust-agent symlink for scripts.
BINARY="$ANDROID_TARGET_DIR/aarch64-linux-android/release/chump"
if [[ ! -f "$BINARY" ]]; then
  BINARY="$ANDROID_TARGET_DIR/aarch64-linux-android/release/rust-agent"
fi
if [[ ! -f "$BINARY" ]]; then
  echo "Error: Binary not found at $ANDROID_TARGET_DIR/aarch64-linux-android/release/chump or rust-agent"
  exit 1
fi
# Symlink rust-agent -> chump so deploy scripts that expect rust-agent still work.
RELEASE_DIR="$ANDROID_TARGET_DIR/aarch64-linux-android/release"
ln -sf "$(basename "$BINARY")" "$RELEASE_DIR/rust-agent" 2>/dev/null || true
mkdir -p "target/aarch64-linux-android/release"
ln -sf "$BINARY" "target/aarch64-linux-android/release/rust-agent" 2>/dev/null || true

SIZE=$(du -sh "$BINARY" | cut -f1)
echo ""
echo "Built: $BINARY ($SIZE)"

# --- Optional deploy via SSH ---
if [[ "$1" == "--deploy" ]]; then
  DEST="${2:-}"
  PORT="${DEPLOY_PORT:-8022}"

  if [[ -z "$DEST" ]]; then
    echo ""
    echo "Usage: $0 --deploy user@<pixel-ip>"
    echo "  Set DEPLOY_PORT to override SSH port (default: 8022)"
    exit 1
  fi

  echo ""
  echo "Deploying to $DEST:~/chump/ (SSH port $PORT)..."
  ssh -p "$PORT" "$DEST" "mkdir -p ~/chump/sessions ~/chump/logs" 2>/dev/null || true
  scp -P "$PORT" "$BINARY" "$DEST:~/chump/chump"
  if [[ -f "$(dirname "$0")/start-companion.sh" ]]; then
    scp -P "$PORT" "$(dirname "$0")/start-companion.sh" "$DEST:~/chump/start-companion.sh"
    ssh -p "$PORT" "$DEST" "chmod +x ~/chump/start-companion.sh"
  fi
  echo "Deployed."
  echo ""
  echo "To run (e.g. Mabel):"
  echo "  ssh -p $PORT $DEST"
  echo "  cd ~/chump && ./start-companion.sh"
  echo "  # Or: set -a && source .env && set +a && ./chump --discord"
fi
