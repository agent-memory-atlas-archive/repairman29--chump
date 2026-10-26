#!/usr/bin/env bash
# INFRA-987 / RESILIENT-009: thin wrapper delegating to `chump claim` with
# post-add worktree `.git` pointer verification + repair (`worktree_gitdir_repaired_postadd`).
set -euo pipefail
verify_and_repair_worktree_gitdir() {
    local wt_dir="$1" gap_id="${2:-}" repo_root="${CHUMP_REPO:-$(pwd)}"
    [[ -d "$wt_dir" ]] || return 0
    if ! git -C "$wt_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
        local git_file="$wt_dir/.git" wt_name old_ptr="" expected_gitdir
        wt_name="$(basename "$wt_dir")"
        expected_gitdir="$repo_root/.git/worktrees/$wt_name"
        [[ -f "$git_file" ]] && old_ptr="$(tr -d '\r\n' < "$git_file" || true)"
        mkdir -p "$expected_gitdir" 2>/dev/null || true
        printf 'gitdir: %s\n' "$expected_gitdir" > "$git_file"
        printf '%s/.git\n' "$wt_dir" > "$expected_gitdir/gitdir"
        printf '../..\n' > "$expected_gitdir/commondir"
        git -C "$repo_root" worktree repair "$wt_dir" >/dev/null 2>&1 || true
        local amb="${CHUMP_AMBIENT_LOG:-$repo_root/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$amb")" 2>/dev/null || true
        # scanner-anchor: "kind":"worktree_gitdir_repaired_postadd"
        printf '{"ts":"%s","kind":"worktree_gitdir_repaired_postadd","worktree":"%s","gap_id":"%s","repaired_from":"%s","repaired_to":"gitdir: %s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt_dir" "$gap_id" "$old_ptr" "$expected_gitdir" >> "$amb" 2>/dev/null || true
    fi
    git -C "$wt_dir" rev-parse --show-toplevel >/dev/null 2>&1
}
if [[ "${1:-}" == "--verify-gitdir" ]]; then
    shift; verify_and_repair_worktree_gitdir "$@"; exit $?
fi
[[ "${BASH_SOURCE[0]}" == "$0" ]] && exec chump claim "$@"
