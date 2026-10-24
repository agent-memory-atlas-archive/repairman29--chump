#!/usr/bin/env bash
# Bootstrap Chump's CLI toolkit (34-tool roster in src/tool_routing.rs).
# Run once on a fresh machine or via node provisioner. Idempotent.
# Usage: ./scripts/setup/bootstrap-toolkit.sh [--check]
#        SKIP_CARGO=1 ./scripts/setup/bootstrap-toolkit.sh   # skip cargo installs (slow)
#        SKIP_BREW=1 ./scripts/setup/bootstrap-toolkit.sh     # skip brew/apt installs
#        INCLUDE_OLLAMA=1 ./scripts/setup/bootstrap-toolkit.sh # also install ollama

set -e

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Canonical 34-tool roster matching src/tool_routing.rs::ToolAvailability
ROSTER_BINS=(
  rg fd tree tokei ast-grep
  cargo-nextest cargo-audit cargo-outdated cargo-deny cargo-tarpaulin cargo-expand cargo-watch flamegraph
  jq yq xsv sd htmlq
  btm dust procs bandwhich
  xh dog
  delta git-absorb gitleaks
  pandoc mdbook
  just watchexec hyperfine nu
  ollama
)

check_roster() {
  local ok=0 missing=()
  for bin in "${ROSTER_BINS[@]}"; do
    if command -v "$bin" &>/dev/null; then
      ok=$((ok + 1))
    else
      missing+=("$bin")
    fi
  done
  local total="${#ROSTER_BINS[@]}"
  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "[tool_routing] Tools: ${ok}/${total} installed. Missing: none"
    return 0
  else
    echo "[tool_routing] Tools: ${ok}/${total} installed. Missing: ${missing[*]}"
    return 1
  fi
}

if [[ "${1:-}" == "--check" || "${CHECK_ONLY:-}" == "1" ]]; then
  check_roster
  exit $?
fi

echo "=== Chump toolkit bootstrap (INFRA-8091) ==="
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
ARCH_NAME="$(uname -m 2>/dev/null || echo unknown)"
mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin" 2>/dev/null || true

# --- System packages: Linux (apt + direct release binaries, no Homebrew) vs macOS (Homebrew) ---
if [[ -z "${SKIP_BREW:-}" ]]; then
  if [[ "$OS_NAME" == "Linux" ]]; then
    echo ""
    echo "--- Linux system packages (apt + release binaries, no Homebrew) ---"
    if command -v apt-get &>/dev/null; then
      sudo -n apt-get update -qq 2>/dev/null || true
      sudo -n apt-get install -y -qq ripgrep fd-find tree jq pandoc curl unzip git 2>/dev/null || true
    fi
    if ! command -v fd &>/dev/null && command -v fdfind &>/dev/null; then
      ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi
    if ! command -v yq &>/dev/null; then
      if [[ "$ARCH_NAME" == "aarch64" || "$ARCH_NAME" == "arm64" ]]; then
        curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 -o "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq" || true
      elif [[ "$ARCH_NAME" == "x86_64" || "$ARCH_NAME" == "amd64" ]]; then
        curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq" || true
      fi
    fi
    if ! command -v dog &>/dev/null; then
      if [[ "$ARCH_NAME" == "aarch64" || "$ARCH_NAME" == "arm64" ]]; then
        curl -fsSL https://github.com/mr-karan/doggo/releases/download/v1.0.5/doggo_1.0.5_Linux_arm64.tar.gz -o /tmp/doggo.tar.gz && \
          tar -xzf /tmp/doggo.tar.gz -C /tmp && \
          install -m 0755 /tmp/doggo_1.0.5_Linux_arm64/doggo "$HOME/.cargo/bin/dog" && \
          rm -rf /tmp/doggo.tar.gz /tmp/doggo_1.0.5_Linux_arm64 || true
      elif [[ "$ARCH_NAME" == "x86_64" || "$ARCH_NAME" == "amd64" ]]; then
        curl -fsSL https://github.com/ogham/dog/releases/download/v0.1.0/dog-v0.1.0-x86_64-unknown-linux-gnu.zip -o /tmp/dog.zip && \
          unzip -q -o /tmp/dog.zip -d /tmp/dog-extract && \
          install -m 0755 /tmp/dog-extract/bin/dog "$HOME/.cargo/bin/dog" && \
          rm -rf /tmp/dog.zip /tmp/dog-extract || true
      fi
    fi
    if [[ -n "${INCLUDE_OLLAMA:-}" ]] && ! command -v ollama &>/dev/null; then
      curl -fsSL https://ollama.com/install.sh | sh || true
    fi
  else
    if ! command -v brew &>/dev/null; then
      echo "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    BREW_PKGS=(
      # Code search & navigation
      ripgrep fd tree
      # Data processing
      jq yq
      # System monitoring
      bottom
      # Git
      git-delta gh gitleaks
      # Network
      dog
      # Docs
      pandoc
      # Shell
      nushell
    )

    echo ""
    echo "--- Brew packages ---"
    for pkg in "${BREW_PKGS[@]}"; do
      if brew list "$pkg" &>/dev/null 2>&1; then
        echo "  ✅ $pkg"
      else
        echo "  📦 Installing $pkg..."
        brew install "$pkg" || echo "  ⚠️  $pkg install failed (non-fatal)"
      fi
    done

    if [[ -n "${INCLUDE_OLLAMA:-}" ]]; then
      if ! command -v ollama &>/dev/null; then
        echo "  📦 Installing ollama..."
        brew install ollama
      else
        echo "  ✅ ollama"
      fi
    fi
  fi
fi

# --- Cargo packages (prefer cargo-binstall prebuilt binaries on Linux/macOS) ---
if [[ -z "${SKIP_CARGO:-}" ]]; then
  if ! command -v cargo &>/dev/null; then
    echo "Rust not installed. Install via: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
  fi

  if ! command -v cargo-binstall &>/dev/null; then
    curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash 2>/dev/null || true
  fi

  # Map of cargo-package → binary-name (for checking if already installed)
  CARGO_PKGS=(
    "tokei:tokei"
    "ast-grep:ast-grep"
    "cargo-nextest:cargo-nextest"
    "cargo-audit:cargo-audit"
    "cargo-outdated:cargo-outdated"
    "cargo-deny:cargo-deny"
    "cargo-tarpaulin:cargo-tarpaulin"
    "cargo-expand:cargo-expand"
    "cargo-watch:cargo-watch"
    "flamegraph:flamegraph"
    "xsv:xsv"
    "sd:sd"
    "htmlq:htmlq"
    "du-dust:dust"
    "bottom:btm"
    "procs:procs"
    "bandwhich:bandwhich"
    "xh:xh"
    "git-delta:delta"
    "just:just"
    "watchexec-cli:watchexec"
    "hyperfine:hyperfine"
    "mdbook:mdbook"
    "git-absorb:git-absorb"
    "nu:nu"
  )

  echo ""
  echo "--- Cargo packages (cargo-binstall preferred, cargo install fallback) ---"
  for entry in "${CARGO_PKGS[@]}"; do
    pkg="${entry%%:*}"
    bin="${entry##*:}"
    if command -v "$bin" &>/dev/null; then
      echo "  ✅ $pkg ($bin)"
    else
      echo "  📦 Installing $pkg..."
      if command -v cargo-binstall &>/dev/null; then
        cargo binstall --no-confirm --disable-strategies compile "$pkg" 2>/dev/null || \
          cargo install "$pkg" 2>/dev/null || echo "  ⚠️  $pkg install failed (non-fatal)"
      else
        cargo install "$pkg" 2>/dev/null || echo "  ⚠️  $pkg install failed (non-fatal)"
      fi
    fi
  done
fi

# --- Python tools (optional, lightweight) ---
if command -v pip3 &>/dev/null; then
  echo ""
  echo "--- Python tools ---"
  if command -v llm &>/dev/null; then
    echo "  ✅ llm"
  else
    echo "  📦 Installing llm..."
    pip3 install --user llm 2>/dev/null || echo "  ⚠️  llm install failed (non-fatal)"
  fi
fi

echo ""
check_roster || true
echo "=== Bootstrap complete ==="
echo "Run ./scripts/ci/verify-toolkit.sh to check what's available."
echo "Run with INCLUDE_OLLAMA=1 to also install Ollama (large download)."
