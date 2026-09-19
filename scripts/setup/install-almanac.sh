#!/usr/bin/env bash
# install-almanac.sh — RESILIENT-403 (RESILIENT-367 slice)
#
# WHY THIS EXISTS. scripts/setup/install-almanac-organ.sh has called a
# script by this exact name to auto-clone almanac onto a factory node with
# no existing checkout since INFRA-3710 — but the file never existed, so a
# fresh node's "eyes" phase died at the very first missing-repo check.
# Separately, scripts/ops/almanac-liveness-refresh.sh already rebuilds a
# MISSING binary from an EXISTING checkout, and gap-reserve's dedupe path
# (ZERO-WASTE-045, src/almanac_tool.rs::almanac_available()) already
# resolves CHUMP_ALMANAC_MCP_BIN + ALMANAC_DB from env or common paths — but
# nothing wrote CHUMP_ALMANAC_MCP_BIN into a config a fresh shell actually
# sources, so a from-scratch node kept surfacing "almanac-unavailable" even
# after the binary existed on disk.
#
# This script closes both gaps: clone-if-absent (else update) + build +
# install the binaries where PATH and chump's own config both find them.
#
# INFRA-7576 (INFRA-3637 slice) extends this with the two remaining
# post-install wiring steps that used to require a separate hand-run of
# `almanac init` / manual git-hook symlinks: writing the 'almanac' MCP
# server entry into chump-mcp.json directly (no full reindex needed — the
# entry only names the binary path + embed host), and installing the
# managed post-commit/post-merge freshness hooks via `almanac hook install`
# instead of a hardcoded hook-script symlink. Both steps are best-effort:
# a fresh node where chump isn't registered with almanac yet degrades to a
# loud failure event, not a broken install.
#
# Usage:
#   scripts/setup/install-almanac.sh              # clone/update + build + install + wire config + wire mcp + install hooks
#   scripts/setup/install-almanac.sh --check       # verify only, exit non-zero if incomplete
#   scripts/setup/install-almanac.sh --dry-run
#
# Idempotent: re-running updates an existing checkout (git pull --ff-only,
# skipped with a warning if the tree is dirty), always rebuilds+reinstalls
# (cargo itself is a no-op on an unchanged tree), rewrites the
# CHUMP_ALMANAC_MCP_BIN line in $CHUMP_ENV_FILE in place instead of
# appending duplicates, rewrites (not duplicates) the 'almanac' entry in
# chump-mcp.json, and `almanac hook install` itself appends-or-updates a
# single marked block rather than stacking hooks on re-run.
#
# Env overrides:
#   CHUMP_ALMANAC_REPO    almanac source checkout      (default: $HOME/Projects/almanac)
#   ALMANAC_CLONE_URL     git remote to clone from      (default: https://github.com/repairman29/almanac.git)
#   ALMANAC_BUILD_CMD     override the build command    (default: cargo build --release --manifest-path <repo>/Cargo.toml)
#   ALMANAC_INSTALL_DIR   where binaries land            (default: /usr/local/bin, falls back to $HOME/.local/bin)
#   CHUMP_ENV_FILE        chump config env file          (default: $HOME/.chump/env)
#   CHUMP_REPO_ROOT        chump checkout whose ambient.jsonl to emit to (also the repo whose
#                          chump-mcp.json is wired and whose git hooks are installed)
#   CHUMP_MCP_CONFIG      path to chump-mcp.json         (default: $CHUMP_REPO_ROOT/chump-mcp.json)
#   ALMANAC_EMBED_URL     embed/rerank inference host written into the MCP entry
#                          (default: http://100.101.188.30:11434)
#
# Emits ambient kinds: almanac_install_completed, almanac_install_failed,
#   almanac_mcp_wire_failed, almanac_hook_install_failed
set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

ALMANAC_REPO="${CHUMP_ALMANAC_REPO:-$HOME/Projects/almanac}"
ALMANAC_CLONE_URL="${ALMANAC_CLONE_URL:-https://github.com/repairman29/almanac.git}"
ALMANAC_BUILD_CMD="${ALMANAC_BUILD_CMD:-cargo build --release --manifest-path \"$ALMANAC_REPO/Cargo.toml\"}"
ALMANAC_INSTALL_DIR="${ALMANAC_INSTALL_DIR:-/usr/local/bin}"
CHUMP_ENV_FILE="${CHUMP_ENV_FILE:-$HOME/.chump/env}"
CHUMP_MCP_CONFIG="${CHUMP_MCP_CONFIG:-$REPO_ROOT/chump-mcp.json}"
ALMANAC_EMBED_URL="${ALMANAC_EMBED_URL:-http://100.101.188.30:11434}"

MODE="install"; DRY=0
for a in "$@"; do
  case "$a" in
    --check) MODE="check";;
    --dry-run) DRY=1;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $a" >&2; exit 2;;
  esac
done

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[ALMANAC]\033[0m %s\n' "$*"; }
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

emit() {  # kind extra_json
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [ -n "$extra" ]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

# ---------- 1. clone-if-absent, else idempotent update ----------
clone_or_update() {
  if [ -d "$ALMANAC_REPO/.git" ]; then
    if [ -n "$(git -C "$ALMANAC_REPO" status --porcelain 2>/dev/null)" ]; then
      info "checkout at $ALMANAC_REPO has local changes — skipping pull, building as-is"
      return 0
    fi
    info "updating existing checkout: $ALMANAC_REPO"
    run "git -C '$ALMANAC_REPO' pull --ff-only --quiet" || {
      no "git pull --ff-only failed — building existing checkout as-is"
      return 0
    }
    ok "checkout up to date"
  else
    info "no checkout at $ALMANAC_REPO — cloning $ALMANAC_CLONE_URL"
    run "mkdir -p '$(dirname "$ALMANAC_REPO")'"
    run "git clone --quiet '$ALMANAC_CLONE_URL' '$ALMANAC_REPO'" || {
      no "git clone failed ($ALMANAC_CLONE_URL -> $ALMANAC_REPO)"
      return 1
    }
    ok "cloned almanac -> $ALMANAC_REPO"
  fi
}

# ---------- 2. build ----------
build_almanac() {
  info "building ($ALMANAC_BUILD_CMD)"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: $ALMANAC_BUILD_CMD"
    return 0
  fi
  if ! eval "$ALMANAC_BUILD_CMD" >/tmp/almanac-install-build.log 2>&1; then
    no "build failed — see /tmp/almanac-install-build.log"
    return 1
  fi
  ok "build succeeded"
}

# ---------- 3. install binaries where PATH finds them ----------
resolve_install_dir() {
  if [ -w "$ALMANAC_INSTALL_DIR" ] 2>/dev/null; then
    printf '%s' "$ALMANAC_INSTALL_DIR"; return 0
  fi
  if [ "$DRY" != 1 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    printf '%s' "$ALMANAC_INSTALL_DIR"; return 0
  fi
  printf '%s' "$HOME/.local/bin"
}

install_bin() {  # install_bin <name>
  local name="$1"
  local built="$ALMANAC_REPO/target/release/$name"
  if [ ! -x "$built" ] && [ "$DRY" != 1 ]; then
    no "$name not found at $built after build — skipping install"
    return 1
  fi
  local dest_dir; dest_dir="$(resolve_install_dir)"
  local dest="$dest_dir/$name"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: install -m755 '$built' '$dest'" >&2
    printf '%s' "$dest"
    return 0
  fi
  run "mkdir -p '$dest_dir'" >&2
  if [ -w "$dest_dir" ]; then
    run "install -m755 '$built' '$dest'" >&2
  elif command -v sudo >/dev/null 2>&1; then
    run "sudo install -m755 '$built' '$dest'" >&2
  else
    no "$dest_dir not writable and no sudo available — cannot install $name" >&2
    return 1
  fi
  ok "$name -> $dest" >&2
  printf '%s' "$dest"
}

# ---------- 4. wire chump config so dedupe finds it (idempotent) ----------
wire_config() {  # wire_config <mcp_bin_path>
  local mcp_bin="$1"
  mkdir -p "$(dirname "$CHUMP_ENV_FILE")"
  [ -f "$CHUMP_ENV_FILE" ] || : > "$CHUMP_ENV_FILE"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: set CHUMP_ALMANAC_MCP_BIN=$mcp_bin in $CHUMP_ENV_FILE"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  grep -v '^CHUMP_ALMANAC_MCP_BIN=' "$CHUMP_ENV_FILE" > "$tmp" 2>/dev/null || true
  printf 'CHUMP_ALMANAC_MCP_BIN=%s\n' "$mcp_bin" >> "$tmp"
  mv "$tmp" "$CHUMP_ENV_FILE"
  ok "wired CHUMP_ALMANAC_MCP_BIN=$mcp_bin -> $CHUMP_ENV_FILE"

  # Make sure a login shell actually sources it — a value sitting in
  # ~/.chump/env that nothing exports is invisible to the `chump` process
  # env (src/almanac_tool.rs reads std::env::var, not this file directly).
  local marker="# >>> chump env (RESILIENT-403 install-almanac.sh) >>>"
  local block
  block="$marker"$'\n'"[ -f \"$CHUMP_ENV_FILE\" ] && set -a && . \"$CHUMP_ENV_FILE\" && set +a"$'\n'"# <<< chump env <<<"
  for rc in ${CHUMP_ALMANAC_RC_FILES:-"$HOME/.bashrc" "$HOME/.zshrc"}; do
    [ -f "$rc" ] || continue
    if ! grep -qF "$marker" "$rc" 2>/dev/null; then
      printf '\n%s\n' "$block" >> "$rc"
      ok "wired \"source $CHUMP_ENV_FILE\" into $rc"
    fi
  done
  # export into THIS process too, so a --check run immediately after
  # install (same shell invocation, e.g. CI) sees it without a re-login.
  export CHUMP_ALMANAC_MCP_BIN="$mcp_bin"
}

# ---------- 5. wire chump-mcp.json (idempotent, no reindex) ----------
wire_mcp_json() {  # wire_mcp_json <mcp_bin_path>
  local mcp_bin="$1"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: wire 'almanac' server (command=$mcp_bin) -> $CHUMP_MCP_CONFIG"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    no "python3 not found — cannot wire $CHUMP_MCP_CONFIG"
    return 1
  fi
  if ! ALMANAC_MCP_BIN_ENV="$mcp_bin" ALMANAC_EMBED_URL_ENV="$ALMANAC_EMBED_URL" \
    python3 - "$CHUMP_MCP_CONFIG" <<'PY'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
if not isinstance(cfg.get("mcpServers"), dict):
    cfg["mcpServers"] = {}
cfg["mcpServers"]["almanac"] = {
    "command": os.environ["ALMANAC_MCP_BIN_ENV"],
    "args": [],
    "env": {
        "ALMANAC_EMBED_URL": os.environ["ALMANAC_EMBED_URL_ENV"],
        "ALMANAC_DEFAULT_REPO": "chump",
    },
    "enabled": True,
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  then
    no "failed to wire 'almanac' server into $CHUMP_MCP_CONFIG"
    return 1
  fi
  ok "wired 'almanac' MCP server -> $CHUMP_MCP_CONFIG"
}

# ---------- 6. install dynamic git hooks (post-commit/post-merge) ----------
install_git_hooks() {  # install_git_hooks <almanac_bin_path>
  local almanac_bin="$1"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: '$almanac_bin' hook install '$REPO_ROOT'"
    return 0
  fi
  if ! "$almanac_bin" repos 2>/dev/null | grep -qF "[$REPO_ROOT]"; then
    info "repo not yet registered with almanac — indexing $REPO_ROOT before hook install"
    run "'$almanac_bin' index '$REPO_ROOT' --json >/tmp/almanac-index-for-hooks.log 2>&1" || {
      no "'$almanac_bin' index '$REPO_ROOT' failed — see /tmp/almanac-index-for-hooks.log"
      return 1
    }
  fi
  if ! run "'$almanac_bin' hook install '$REPO_ROOT' >/tmp/almanac-hook-install.log 2>&1"; then
    no "'$almanac_bin' hook install '$REPO_ROOT' failed — see /tmp/almanac-hook-install.log"
    return 1
  fi
  ok "git hooks installed via 'almanac hook install' -> $REPO_ROOT"
}

do_install() {
  # scanner-anchor: "kind":"almanac_install_failed"
  clone_or_update || { emit almanac_install_failed '"reason":"clone_or_update_failed"'; exit 1; }
  build_almanac || { emit almanac_install_failed '"reason":"build_failed"'; exit 1; }

  local almanac_dest mcp_dest
  almanac_dest="$(install_bin almanac)" || { emit almanac_install_failed '"reason":"install_almanac_bin_failed"'; exit 1; }
  mcp_dest="$(install_bin almanac-mcp)" || { emit almanac_install_failed '"reason":"install_almanac_mcp_bin_failed"'; exit 1; }

  wire_config "$mcp_dest"

  # scanner-anchor: "kind":"almanac_mcp_wire_failed"
  wire_mcp_json "$mcp_dest" || emit almanac_mcp_wire_failed "\"config\":\"$CHUMP_MCP_CONFIG\""

  # scanner-anchor: "kind":"almanac_hook_install_failed"
  install_git_hooks "$almanac_dest" || emit almanac_hook_install_failed "\"repo\":\"$REPO_ROOT\""

  # scanner-anchor: "kind":"almanac_install_completed"
  emit almanac_install_completed "\"repo\":\"$ALMANAC_REPO\",\"almanac_bin\":\"$almanac_dest\",\"almanac_mcp_bin\":\"$mcp_dest\""
  info "done: almanac=$almanac_dest almanac-mcp=$mcp_dest"
}

do_check() {
  local fail=0
  if [ -d "$ALMANAC_REPO/.git" ]; then ok "almanac checkout present: $ALMANAC_REPO"
  else no "almanac checkout missing: $ALMANAC_REPO"; fail=1; fi

  local dest_dir; dest_dir="$(resolve_install_dir)"
  if [ -x "$dest_dir/almanac" ]; then ok "almanac binary installed: $dest_dir/almanac"
  else no "almanac binary NOT installed at $dest_dir/almanac"; fail=1; fi
  if [ -x "$dest_dir/almanac-mcp" ]; then ok "almanac-mcp binary installed: $dest_dir/almanac-mcp"
  else no "almanac-mcp binary NOT installed at $dest_dir/almanac-mcp"; fail=1; fi

  if grep -q '^CHUMP_ALMANAC_MCP_BIN=' "$CHUMP_ENV_FILE" 2>/dev/null; then
    ok "CHUMP_ALMANAC_MCP_BIN wired in $CHUMP_ENV_FILE"
  else
    no "CHUMP_ALMANAC_MCP_BIN NOT wired in $CHUMP_ENV_FILE"; fail=1
  fi

  if grep -q '"almanac"' "$CHUMP_MCP_CONFIG" 2>/dev/null; then
    ok "chump-mcp.json contains 'almanac' server entry: $CHUMP_MCP_CONFIG"
  else
    no "chump-mcp.json missing 'almanac' server entry: $CHUMP_MCP_CONFIG"; fail=1
  fi

  if [ -x "$dest_dir/almanac" ]; then
    local hook_status; hook_status="$("$dest_dir/almanac" hook status "$REPO_ROOT" 2>/dev/null)"
    if printf '%s' "$hook_status" | grep -q 'post-commit *present' \
      && printf '%s' "$hook_status" | grep -q 'post-merge *present'; then
      ok "git hooks active (post-commit + post-merge) via 'almanac hook status'"
    else
      no "git hooks NOT active — run '$dest_dir/almanac hook install $REPO_ROOT'"; fail=1
    fi
  fi

  [ "$fail" = 0 ] && ok "almanac install: complete + idempotent" || no "almanac install: incomplete"
  return "$fail"
}

if [ "$MODE" = "check" ]; then do_check; exit $?; fi
do_install
do_check
