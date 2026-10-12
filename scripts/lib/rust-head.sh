#!/usr/bin/env bash
# scripts/lib/rust-head.sh (INFRA-8098) — Rust-aware deploy/lag helpers.
#
# The chump binary only changes when a *Rust-compiled* source changes. Doc,
# script, yaml and markdown commits advance origin/main HEAD but produce a
# byte-identical binary. Deploy + lag logic that compares the installed binary
# to origin/main HEAD therefore rebuilds the ~190k-LOC binary and pages
# "stale binary" on every non-Rust commit — burning build cores the workers
# need and crying wolf forever (the recurring merged-not-running false alarm,
# INFRA-8098). These helpers make that logic compare against the last
# Rust-affecting commit instead of HEAD.
#
# Rust-compiled surface — a change to any of these can alter the binary:
#   *.rs, Cargo.toml, Cargo.lock, rust-toolchain.toml, build.rs
# (source, dependency graph, toolchain pin, codegen).

_RUST_HEAD_PATHS=('*.rs' 'Cargo.toml' 'Cargo.lock' 'rust-toolchain.toml' 'build.rs')

# rust_head_sha [repo] [ref] — full SHA of the last commit on <ref>
# (default origin/main) that touches the Rust-compiled surface. Prints empty
# when none is found or git is unavailable.
rust_head_sha() {
    local repo="${1:-.}" ref="${2:-origin/main}"
    git -C "$repo" log -1 --format=%H "$ref" -- "${_RUST_HEAD_PATHS[@]}" 2>/dev/null
}

# binary_has_rust_head <rust_sha> <binary_sha> [repo] — returns 0 (true) when a
# binary built from <binary_sha> already contains <rust_sha> (i.e. rust_sha is
# an ancestor-or-equal of binary_sha). Returns non-zero when a Rust change is
# missing (genuine staleness) OR when either SHA is empty/"unknown"/unresolvable
# — failing toward "needs attention" so a real stale binary is never hidden.
binary_has_rust_head() {
    local rust_sha="$1" binary_sha="$2" repo="${3:-.}"
    [ -n "$rust_sha" ] && [ -n "$binary_sha" ] || return 1
    [ "$binary_sha" != "unknown" ] || return 1
    git -C "$repo" merge-base --is-ancestor "$rust_sha" "$binary_sha" 2>/dev/null
}
