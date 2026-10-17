#!/usr/bin/env bash
# scripts/setup/lib/refspec-repair.sh — INFRA-8210
#
# One small, sourceable primitive: force the standard all-branches fetch
# refspec onto an owned node's checkout.
#
# A clone made with `--single-branch` (or `git clone --branch main <url>`)
# carries only
#     remote.<remote>.fetch = +refs/heads/<branch>:refs/remotes/<remote>/<branch>
# so a bare `git fetch <remote>` never populates refs/remotes/<remote>/* for any
# OTHER branch. On the cuphead hub that silently broke dispatch resume, salvage,
# and rebases — they look for remote feature branches that were never fetched.
#
# This logic is shared by the installer (scripts/setup/chump-node-install.sh,
# which repairs at install time) and the converge organ
# (scripts/ops/node-converge.sh, which re-asserts it every tick) so a checkout
# self-heals without a reinstall. Pure glue: only git + the two args, no
# dependency on any caller's logging helpers, so scripts/ci can source and
# drive it against a fixture clone directly.

# repair_fetch_refspec <repo_dir> [remote]
#
# Rewrites remote.<remote>.fetch to the all-branches refspec unless the sole
# existing entry is already exactly that (idempotent). Prints nothing; the
# caller decides how to log. Returns:
#   0  — already correct, nothing to do
#   10 — repaired (was narrow / unset / multi-entry)
#   11 — `git config` write failed
#   2  — not a git checkout (no .git) / missing arg
repair_fetch_refspec() {
    local repo="${1:-}" remote="${2:-origin}"
    [ -n "$repo" ] || return 2
    [ -d "$repo/.git" ] || return 2
    local full="+refs/heads/*:refs/remotes/${remote}/*"
    local current
    # --get-all so a checkout carrying MULTIPLE narrow refspecs is still treated
    # as needing repair unless its one-and-only entry is the full refspec.
    current="$(git -C "$repo" config --get-all "remote.${remote}.fetch" 2>/dev/null)"
    if [ "$current" = "$full" ]; then
        return 0
    fi
    if git -C "$repo" config --replace-all "remote.${remote}.fetch" "$full" 2>/dev/null; then
        return 10
    fi
    return 11
}
