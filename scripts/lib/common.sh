#!/usr/bin/env bash
# scripts/lib/common.sh — INFRA-6394 (INFRA-1966 slice)
#
# Shared error-handling + repo-root resolution for scripts/coord and
# scripts/dispatch orchestrator scripts. Source this instead of
# hand-rolling die()/REPO_ROOT boilerplate per script.
#
# Usage:
#     # shellcheck source=scripts/lib/common.sh
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#     die "something broke"
#     echo "$REPO_ROOT"
#
# REPO_ROOT/MAIN_REPO/LOCK_DIR come from scripts/lib/repo-paths.sh
# (INFRA-109) — this file does not re-derive them to avoid a second,
# drifting copy of the git-common-dir worktree logic.
#
# For execution-step logging (START/STEP/END to a log file), see
# scripts/lib/orchestrator-log.sh instead (INFRA-6128) — a separate,
# already-extracted concern.

_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/repo-paths.sh
source "$_COMMON_LIB_DIR/repo-paths.sh"

unset _COMMON_LIB_DIR

# die MESSAGE — print an error tagged with the calling script's basename
# to stderr and exit 1.
die() {
    printf '[%s] ERROR: %s\n' "$(basename "${0%.sh}")" "$*" >&2
    exit 1
}
