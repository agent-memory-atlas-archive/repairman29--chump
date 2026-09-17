#!/usr/bin/env bash
# install.sh — INFRA-3657 (MISSION: RIBBON-02, MISSION-010).
#
# THE single bare-box entrypoint: a box with NO repo, NO binary, NO creds, NO
# substrate, NO organs runs ONE command and reaches FACTORY INSTALLED.
#
#   curl -fsSL https://raw.githubusercontent.com/repairman29/chump/main/scripts/setup/install.sh | bash -s -- --role brain
#
# WHY THIS EXISTS (the chicken-egg this closes). chump-node-install.sh is the
# real phase engine (DETECT->HOME->CREDS->BINARY->SEED->ORGANS->SUBSTRATE->
# EYES->SUPERVISE->SELF-TEST) but it LIVES INSIDE the repo it clones — a bare
# box has nothing to `bash scripts/setup/chump-node-install.sh` yet. This
# script is the clone-wrapper: it is the only file a truly bare box needs to
# fetch, and its entire job is (a) get git, (b) get the repo, (c) hand off to
# the real installer from inside the fresh clone, forwarding every arg.
#
# Usage:
#   install.sh [--role brain|muscle|all] [--home DIR] [--creds-file PATH]
#              [--repo-url URL] [--check] [--dry-run]
#
# All creds/role/home flags pass straight through to chump-node-install.sh —
# see that script's own header for the zero-touch creds contract
# (--creds-file / $CHUMP_BOOTSTRAP_CREDS, GH_TOKEN + CLAUDE_CODE_OAUTH_TOKEN
# required, DISCORD_TOKEN optional for the walk-away pager).
#
# --check: idempotent audit-only mode. Exits non-zero if ANY stage
# (repo clone, creds, binary, seed, organs, substrate, eyes, supervise) is
# incomplete. Safe to run repeatedly (e.g. from a monitor loop) — never
# mutates state, only reports.
set -uo pipefail

ROLE="brain"; NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"; CREDS_FILE=""
REPO_URL="${CHUMP_NODE_REPO_URL:-https://github.com/repairman29/chump.git}"
CHECK=0; DRY=0
FORWARD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; FORWARD_ARGS+=(--role "$2"); shift 2;;
    --home) NODE_DIR="$2"; shift 2;;
    --creds-file) CREDS_FILE="$2"; FORWARD_ARGS+=(--creds-file "$2"); shift 2;;
    --repo-url) REPO_URL="$2"; shift 2;;
    --check) CHECK=1; shift;;
    --dry-run) DRY=1; FORWARD_ARGS+=(--dry-run); shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[35m[FACTORY]\033[0m %s\n' "$*"; }

REPO_DIR="$NODE_DIR/repo"
NODE_INSTALL="$REPO_DIR/scripts/setup/chump-node-install.sh"

printf '\033[1m=== chump install.sh: bare-box -> FACTORY INSTALLED (role=%s home=%s) ===\033[0m\n' "$ROLE" "$NODE_DIR"

# ---------- --check short-circuit: never mutates, just audits every stage ----------
if [ "$CHECK" = 1 ]; then
  fail=0
  if [ ! -d "$REPO_DIR/.git" ]; then
    no "stage CLONE incomplete: no repo at $REPO_DIR — run install.sh (no --check) first"
    fail=1
  else
    ok "stage CLONE: repo present at $REPO_DIR"
  fi
  if [ -x "$NODE_INSTALL" ]; then
    if bash "$NODE_INSTALL" --home "$NODE_DIR" --check; then
      ok "stage NODE-INSTALL: all phases complete"
    else
      no "stage NODE-INSTALL: one or more phases incomplete (see above)"
      fail=1
    fi
  else
    no "stage NODE-INSTALL: $NODE_INSTALL missing — clone incomplete or repo layout changed"
    fail=1
  fi
  echo
  if [ "$fail" = 0 ]; then
    printf '\033[42m FACTORY INSTALLED \033[0m role=%s home=%s\n' "$ROLE" "$NODE_DIR"
    exit 0
  else
    printf '\033[41m NOT FACTORY INSTALLED \033[0m — fix the \xe2\x9c\x97 above, then re-run install.sh (no --check)\n'
    exit 1
  fi
fi

# ---------- 0. GIT (the one tool this wrapper cannot live without) ----------
if ! command -v git >/dev/null 2>&1; then
  no "git not found — this is the one dependency install.sh cannot self-provision"
  case "$(uname -s)" in
    Darwin) echo "  fix: brew install git (or: xcode-select --install)" >&2;;
    Linux)
      if command -v apt >/dev/null 2>&1; then echo "  fix: sudo apt install -y git" >&2
      elif command -v dnf >/dev/null 2>&1; then echo "  fix: sudo dnf install -y git" >&2
      else echo "  fix: install git via your distro's package manager" >&2; fi
      ;;
    *) echo "  fix: install git" >&2;;
  esac
  exit 1
fi
ok "git present ($(git --version))"

# ---------- 0.5 TOOLCHAIN (node, npm, etc.) ----------
# Install node and npm if missing.
# Use host-specific package managers.
install_node_npm() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "node and npm present ($(node --version))"
    return 0
  fi
  info TOOLCHAIN "node/npm missing — installing for host=$(uname -s)"
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        if [ "$DRY" = 1 ]; then
          echo "  DRY: brew install node"
        else
          brew install node
        fi
      else
        no "Homebrew not found — install brew first"
        return 1
      fi
      ;;
    Linux)
      if command -v apt >/dev/null 2>&1; then
        if [ "$DRY" = 1 ]; then
          echo "  DRY: sudo apt update && sudo apt install -y nodejs npm"
        else
          sudo apt update && sudo apt install -y nodejs npm
        fi
      elif command -v dnf >/dev/null 2>&1; then
        if [ "$DRY" = 1 ]; then
          echo "  DRY: sudo dnf install -y nodejs npm"
        else
          sudo dnf install -y nodejs npm
        fi
      else
        no "Please install nodejs and npm via your distro's package manager"
        return 1
      fi
      ;;
    *)
      no "Unsupported OS for automatic node/npm installation"
      return 1
      ;;
  esac
  # Verify installation
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "node and npm installed ($(node --version))"
    return 0
  else
    no "node/npm installation failed"
    return 1
  fi
}

# Invoke toolchain installation
if ! install_node_npm; then
  exit 1
fi

# ---------- 1. CLONE (the chicken-egg break) ----------
mkdir -p "$NODE_DIR"
if [ -d "$REPO_DIR/.git" ]; then
  ok "repo already present: $REPO_DIR (node-install will sync it to origin/main)"
elif [ "$DRY" = 1 ]; then
  echo "  DRY: git clone --quiet '$REPO_URL' '$REPO_DIR'"
else
  info "cloning $REPO_URL -> $REPO_DIR"
  if git clone --quiet "$REPO_URL" "$REPO_DIR"; then
    ok "cloned: $REPO_DIR"
  else
    no "clone FAILED: $REPO_URL -> $REPO_DIR"
    exit 1
  fi
fi

# ---------- 2. HAND OFF to the real installer, now that it exists on disk ----------
# In --dry-run, step 1 didn't actually clone (matches chump-node-install.sh's
# own DRY convention of never touching disk), so there is nothing on disk to
# hand off to yet — just show what would run and stop here.
if [ "$DRY" = 1 ]; then
  echo "  DRY: bash '$NODE_INSTALL' --home '$NODE_DIR' ${FORWARD_ARGS[*]}"
  echo
  info "dry-run complete — no state was mutated"
  exit 0
fi
if [ ! -x "$NODE_INSTALL" ] && [ -f "$NODE_INSTALL" ]; then chmod +x "$NODE_INSTALL"; fi
if [ ! -f "$NODE_INSTALL" ]; then
  no "clone succeeded but $NODE_INSTALL missing — repo layout mismatch?"
  exit 1
fi
info "handing off to chump-node-install.sh (DETECT->HOME->CREDS->BINARY->SEED->ORGANS->SUBSTRATE->EYES->SUPERVISE->SELF-TEST)"
CHUMP_NODE_REPO_URL="$REPO_URL" bash "$NODE_INSTALL" --home "$NODE_DIR" "${FORWARD_ARGS[@]}"
install_rc=$?

echo
if [ "$install_rc" -eq 0 ]; then
  printf '\033[42m FACTORY INSTALLED \033[0m role=%s home=%s\n' "$ROLE" "$NODE_DIR"
else
  printf '\033[41m NOT FACTORY INSTALLED \033[0m — chump-node-install.sh reported failures above; fix and re-run install.sh (idempotent)\n'
fi
exit "$install_rc"
