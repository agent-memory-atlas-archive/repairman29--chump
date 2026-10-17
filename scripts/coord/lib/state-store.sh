#!/usr/bin/env bash
# scripts/coord/lib/state-store.sh — the ONE shell resolver for the gap store
# (state.db) path. INFRA-8190, Phase R R4 "one canonical store".
#
# Mirrors crates/chump-store-path (the Rust resolver every GapStore call goes
# through) EXACTLY, so a shell organ and the chump binary can never disagree:
#
#   1. CHUMP_STATE_DB, if set and non-empty (a leading ~ expands to $HOME).
#   2. The git checkout containing <root> (walking up): the MAIN checkout's
#      .chump/state.db. A linked worktree (.git is a FILE whose gitdir holds a
#      `commondir`) resolves to its main checkout — same convention as
#      scripts/lib/lease.sh (--git-common-dir) and the worktree state.db
#      symlinks `chump claim` / `chump dispatch` create.
#   3. No checkout above <root>: <root>/.chump/state.db. When <root> is $HOME
#      that is the legacy ~/.chump/state.db; a one-line warning goes to stderr.
#
# <root> defaults to ${CHUMP_REPO:-${CHUMP_HOME:-$PWD}}, matching the Rust
# CLI's repo_path::repo_root().
#
# CHUMP_STATE_DIR is deliberately NOT consulted: it is the node-state dir
# (providers.env, node.env, heartbeats), not a store selector. Pointing it at
# the store is what split cuphead (CLI ~/.chump 8264 gaps vs fleet-server +
# workers <repo>/.chump 465 gaps, 2026-10-15).
#
# Usage (source it):
#   . scripts/coord/lib/state-store.sh
#   db="$(chump_state_db [<root>])"            # path only
#   src="$(chump_state_db_source [<root>])"    # env|main-checkout|linked-worktree|no-checkout|home-fallback
#
# Pure filesystem walk (no git subprocess) so it is cheap on hot paths and
# behaves identically to the Rust walk.

# _chump_store_resolve <root>  ->  prints "<source>\t<path>"
_chump_store_resolve() {
    local root="${1:-${CHUMP_REPO:-${CHUMP_HOME:-$PWD}}}"
    local env_db="${CHUMP_STATE_DB:-}"
    # trim surrounding whitespace (blank == unset, like the Rust resolver)
    env_db="${env_db#"${env_db%%[![:space:]]*}"}"
    env_db="${env_db%"${env_db##*[![:space:]]}"}"
    if [[ -n "$env_db" ]]; then
        case "$env_db" in
            "~") env_db="$HOME" ;;
            "~/"*) env_db="$HOME/${env_db#\~/}" ;;
        esac
        printf 'env\t%s\n' "$env_db"
        return 0
    fi
    [[ "$root" == /* ]] || root="$PWD/$root"
    local dir="$root" gitdir commondir common
    while :; do
        if [[ -d "$dir/.git" ]]; then
            printf 'main-checkout\t%s/.chump/state.db\n' "$dir"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            gitdir="$(sed -n 's/^gitdir:[[:space:]]*//p' "$dir/.git" | head -1)"
            if [[ -n "$gitdir" ]]; then
                [[ "$gitdir" == /* ]] || gitdir="$dir/$gitdir"
                if [[ -f "$gitdir/commondir" ]]; then
                    commondir="$(head -1 "$gitdir/commondir")"
                    [[ "$commondir" == /* ]] || commondir="$gitdir/$commondir"
                    common="$(cd "$commondir" 2>/dev/null && pwd -P)"
                    if [[ -n "$common" && "$(basename "$common")" == ".git" ]]; then
                        printf 'linked-worktree\t%s/.chump/state.db\n' "$(dirname "$common")"
                        return 0
                    fi
                fi
            fi
            # submodule / bare common dir: the directory itself is the checkout
            printf 'main-checkout\t%s/.chump/state.db\n' "$dir"
            return 0
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="$(dirname "$dir")"
    done
    local root_real home_real
    root_real="$(cd "$root" 2>/dev/null && pwd -P)"
    home_real="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)"
    if [[ -n "$root_real" && "$root_real" == "$home_real" ]]; then
        printf 'home-fallback\t%s/.chump/state.db\n' "${root%/}"
    else
        printf 'no-checkout\t%s/.chump/state.db\n' "${root%/}"
    fi
}

# chump_state_db [<root>]  ->  the resolved state.db path
chump_state_db() {
    local line src
    line="$(_chump_store_resolve "$@")"
    src="${line%%$'\t'*}"
    if [[ "$src" == "home-fallback" ]]; then
        printf 'chump: warning: not inside a git checkout; gap store falls back to %s (set CHUMP_STATE_DB or run from the chump checkout) [INFRA-8190]\n' \
            "${line#*$'\t'}" >&2
    fi
    printf '%s\n' "${line#*$'\t'}"
}

# chump_state_db_source [<root>]  ->  which precedence rule fired
chump_state_db_source() {
    local line
    line="$(_chump_store_resolve "$@")"
    printf '%s\n' "${line%%$'\t'*}"
}
