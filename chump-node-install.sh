#!/usr/bin/env bash
# chump-node-install.sh — INFRA-7351 (INFRA-3657 slice): the single file a
# truly bare Linux box needs to fetch to become a ChumpOS node.
#
# Usage (bare box, no repo, no binaries):
#   curl -fsSL https://raw.githubusercontent.com/repairman29/chump/main/chump-node-install.sh | bash -s -- --role brain
#
# This script does the absolute minimum itself: verify git is present, git
# clone the repository into a temp dir (or $CHUMP_NODE_DIR/repo if set), then
# hand off to the real installer (scripts/setup/install.sh, which in turn
# drives scripts/setup/chump-node-install.sh's DETECT->HOME->CREDS->BINARY->
# SEED->ORGANS->SUBSTRATE->EYES->SUPERVISE->SELF-TEST phase engine). All args
# are forwarded verbatim.
#
# Exits non-zero if git is missing, the clone fails, or the install flow
# reports failure.
set -euo pipefail

REPO_URL="${CHUMP_NODE_REPO_URL:-https://github.com/repairman29/chump.git}"
CLONE_DIR="${CHUMP_NODE_INSTALL_CLONE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/chump-node-install.XXXXXX")}"

info(){ printf '\033[35m[chump-node-install]\033[0m %s\n' "$*"; }
fail(){ printf '\033[31m[chump-node-install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git not found — install git and re-run"

info "cloning $REPO_URL -> $CLONE_DIR"
git clone --quiet --depth 1 "$REPO_URL" "$CLONE_DIR" || fail "git clone failed: $REPO_URL -> $CLONE_DIR"

INSTALL_SCRIPT="$CLONE_DIR/scripts/setup/install.sh"
[ -f "$INSTALL_SCRIPT" ] || fail "clone succeeded but $INSTALL_SCRIPT is missing — repo layout mismatch?"
chmod +x "$INSTALL_SCRIPT"

info "handing off to scripts/setup/install.sh"
CHUMP_NODE_REPO_URL="$REPO_URL" bash "$INSTALL_SCRIPT" "$@"
