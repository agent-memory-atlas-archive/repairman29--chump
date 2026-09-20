#!/usr/bin/env bash
# registry-remote.sh — where the gap registry (.chump/state.sql) is published.
#
# The gap registry is private data. It is published to a separate private git
# repo, wired into each node's checkout as a plain git remote named `registry`:
#
#     git -C <checkout> remote add registry <private registry repo url>
#
# No env flag: the remote IS the configuration. `git fetch registry main` keeps
# refs/remotes/registry/main current, and the registry is read with
#     git show registry/main:.chump/state.sql
# The registry history is unrelated to this repo's history; it only shares the
# object store of the checkout and is never pushed to origin.
#
# Source this file; it defines functions only.

REGISTRY_REMOTE_NAME="registry"

# registry_remote_url <repo>: print the registry remote url, or nothing.
registry_remote_url() {
  git -C "${1:?repo}" remote get-url "$REGISTRY_REMOTE_NAME" 2>/dev/null || true
}

# registry_legacy_tracked <repo>: true while origin/main still TRACKS the
# registry file (the pre-cutover layout). Once the public repo stops tracking
# it, this is false forever and every legacy fallback below closes.
registry_legacy_tracked() {
  git -C "${1:?repo}" cat-file -e "origin/main:.chump/state.sql" 2>/dev/null
}

# registry_ref <repo>: print the ref that carries the published registry:
#   registry/main   when the registry remote is configured
#   origin/main     only while the legacy tracked layout still exists
#   (nothing, rc=1) otherwise — callers must treat this as "unverifiable".
registry_ref() {
  local repo="${1:?repo}"
  if [[ -n "$(registry_remote_url "$repo")" ]]; then
    printf '%s/main' "$REGISTRY_REMOTE_NAME"; return 0
  fi
  if registry_legacy_tracked "$repo"; then
    printf 'origin/main'; return 0
  fi
  return 1
}

# registry_same_repo <url-a> <url-b>: true when both urls name the same
# owner/repo (ssh, https and host-alias spellings compared by owner/repo tail).
registry_same_repo() {
  local a b
  a="$(printf '%s' "${1:-}" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' | tr 'A-Z' 'a-z')"
  b="$(printf '%s' "${2:-}" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' | tr 'A-Z' 'a-z')"
  [[ -n "$a" && "$a" == "$b" ]]
}
