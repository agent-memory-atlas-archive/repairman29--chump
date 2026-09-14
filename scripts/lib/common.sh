#!/usr/bin/env bash
# scripts/lib/common.sh — INFRA-6394 (INFRA-1966 slice)
#
# Small set of bash primitives that were copy-pasted (with drifting
# prefixes/formats) across orchestrator scripts — starting with the
# scripts/coord/chump-edit-wrap.sh / chump-edit-replay.sh pair, which each
# hand-rolled an identical die() and .chump-plans/<GAP-ID> path resolution.
#
# Usage (in caller, before calling die()):
#
#     # shellcheck source=../lib/common.sh
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#     SCRIPT_NAME="my-script"
#     die "usage: ..."
#
# Deliberately does NOT call `set` — sourcing must not change the caller's
# shell options (a bare `set -uo pipefail` here would silently drop a
# caller's `-e`, since `set` is process-wide, not scoped to this file).

# die <message> — print "[$SCRIPT_NAME] ERROR: <message>" to stderr and exit 1.
# Falls back to $(basename "$0") if the caller didn't set SCRIPT_NAME.
die() {
    printf '[%s] ERROR: %s\n' "${SCRIPT_NAME:-$(basename "$0")}" "$1" >&2
    exit 1
}

# common_gap_dir <repo_root> <gap_id> — canonical .chump-plans/<GAP-ID> path,
# honoring the CHUMP_PLANS_DIR override.
common_gap_dir() {
    local repo_root="$1" gap_id="$2"
    printf '%s/%s\n' "${CHUMP_PLANS_DIR:-$repo_root/.chump-plans}" "$gap_id"
}
