#!/usr/bin/env bash
# RESILIENT-1574: pre-CI short-circuit for close-as-duplicate PRs.
# dup_close_guard_match <subject> <gap-id> [<main-ref>]
#   returns 0 when <subject> is a close-as-duplicate / not-a-bug closure AND the
#   gap already has a real ship commit on <main-ref> (default origin/main).
dup_close_guard_match() {
    local subject="$1" gid="$2" ref="${3:-origin/main}"
    shopt -s nocasematch
    if ! [[ "$subject" =~ (close[sd]?[[:space:]-]+as[[:space:]-]+(a[[:space:]-]+)?(duplicate|dup|not[[:space:]-]+a[[:space:]-]+bug|already[[:space:]-]+shipped)|duplicate[[:space:]-]+of[[:space:]-]+(already[[:space:]-]+)?shipped) ]]; then
        shopt -u nocasematch; return 1
    fi
    shopt -u nocasematch
    # An existing non-closure ship of this gap on main (subject starts with "<GID>:" and is not itself a dup-close).
    git log "$ref" --format=%s --grep="^${gid}[: ]" -n 50 2>/dev/null \
        | grep -ivE 'close[sd]? as|duplicate of|not-a-bug|not a bug' | grep -q . 
}
