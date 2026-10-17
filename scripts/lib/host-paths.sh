#!/usr/bin/env bash
# scripts/lib/host-paths.sh — INFRA-8194 (Phase R R5, slice 2)
#
# Shell mirror of the host-path resolver in crates/chump-provision, for
# installers that run before (or without) the `chump` binary. Source it; it only
# defines functions.
#
#   chump_brew_prefix
#       The Homebrew prefix for THIS host, the value `__BREW_PREFIX__` renders
#       to. Same rule as chump_provision::brew_prefix: macOS with the Apple
#       Silicon prefix present -> that prefix; anything else (Intel Mac, Linux,
#       Termux) -> /usr/local. Installers write "${BREW_PREFIX}/bin" instead of
#       baking the Apple Silicon path into a launchd PATH (wrong on an Intel Mac,
#       meaningless on Linux: the INFRA-8112 brew-only-bootstrap class).
#       `chump node host --field brew-prefix` answers the same question.
#
#   chump_render_template <template> <dest> [repo_root] [host]
#       Render a placeholder template (__HOME__ __REPO_ROOT__ __BIN_DIR__
#       __NODE_ENV__ __BREW_PREFIX__) for this host into <dest>: the typed
#       renderer (`chump node render-unit`) first, this sed mirror when no
#       binary is on PATH yet. Used by every launchd installer that places a
#       tracked plist (they used to `cp` a file baked for one Mac). [host] pins
#       the variant (e.g. linux-systemd-user for a ~/.config/systemd/user unit);
#       omitted, the binary detects it. The sed mirror never writes User=.
#
# The placeholder values match organ_unit_host_rewrite
# (scripts/ops/lib/organ-unit-install-lib.sh) and chump_provision::render.

# The ONE shell copy of the Apple Silicon prefix (the Rust copy is
# chump_provision::APPLE_SILICON_BREW_PREFIX).
_CHUMP_APPLE_SILICON_BREW_PREFIX="/opt/homebrew"

# chump_brew_prefix [os] [apple-silicon-prefix]
#   The two optional positional args fake the host for tests (uname -s, and the
#   directory probed for bin/); callers pass none.
chump_brew_prefix() {
  local os="${1:-$(uname -s 2>/dev/null || echo unknown)}"
  local dir="${2:-$_CHUMP_APPLE_SILICON_BREW_PREFIX}"
  if [ "$os" = "Darwin" ] && [ -d "$dir/bin" ]; then
    echo "$dir"
  else
    echo "/usr/local"
  fi
}

chump_render_template() {
  local src="$1" dest="$2" repo_root="${3:-}" host="${4:-}"
  [ -f "$src" ] || { echo "chump_render_template: missing template $src" >&2; return 1; }
  if [ -z "$repo_root" ]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)"
  fi
  local chump_bin
  chump_bin="${CHUMP_BIN:-$(command -v chump 2>/dev/null || true)}"
  # Trust the binary only when it rendered every token (an older build without
  # __BREW_PREFIX__ support refuses the template, and one without render-unit
  # at all exits non-zero; both fall through to the sed mirror).
  local host_args=()
  [ -n "$host" ] && host_args=(--host "$host")
  if [ -n "$chump_bin" ] && "$chump_bin" node render-unit "$src" ${host_args[@]+"${host_args[@]}"} \
        --repo-root "$repo_root" --out "$dest" 2>/dev/null \
     && [ -s "$dest" ] && ! grep -qE '__(HOME|REPO_ROOT|BIN_DIR|NODE_ENV|BREW_PREFIX)__' "$dest"; then
    return 0
  fi
  local home="${HOME%/}" brew
  brew="$(chump_brew_prefix)"
  sed -e "s#__REPO_ROOT__#${repo_root%/}#g" \
      -e "s#__BIN_DIR__#${home}/.cargo/bin#g" \
      -e "s#__NODE_ENV__#${home}/.chump/node.env#g" \
      -e "s#__BREW_PREFIX__#${brew}#g" \
      -e "s#__HOME__#${home}#g" "$src" > "$dest"
}
