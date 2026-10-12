#!/usr/bin/env bash
# test-rust-aware-deploy.sh (INFRA-8098) — verify the Rust-aware deploy/lag
# helpers in scripts/lib/rust-head.sh.
#
# Depth: edge. Builds a synthetic git repo with interleaved Rust / non-Rust
# commits and asserts rust_head_sha + binary_has_rust_head classify staleness
# by the last *Rust-affecting* commit, not by HEAD.
# Gaps: does not exercise the live auto-deploy.sh / watchdog wiring end-to-end
# (those are covered by their own smoke paths); this isolates the comparison
# logic that was the root of the INFRA-8098 false-alarm loop.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/rust-head.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }
# shellcheck source=scripts/lib/rust-head.sh
. "$LIB"

fails=0
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# c1: a Rust change (the real binary-affecting commit)
echo 'fn main(){}' > "$REPO/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "rust change"
C_RUST="$(git -C "$REPO" rev-parse HEAD)"
# c2, c3: non-Rust commits (docs/scripts) that advance HEAD but not the binary
echo doc > "$REPO/README.md"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "docs"
echo 'echo hi' > "$REPO/x.sh"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "script"
C_HEAD="$(git -C "$REPO" rev-parse HEAD)"
# point a local 'origin/main' ref at HEAD so rust_head_sha's default ref resolves
git -C "$REPO" update-ref refs/remotes/origin/main "$C_HEAD"

# 1. rust_head_sha picks the Rust commit, not the later doc/script HEAD
RH="$(rust_head_sha "$REPO" "origin/main")"
[ "$RH" = "$C_RUST" ] && ok "rust_head_sha = last Rust commit (ignores doc/script)" \
    || bad "rust_head_sha=$RH expected $C_RUST"

# 2. a binary built at HEAD (non-Rust ahead) contains the Rust head → current
if binary_has_rust_head "$C_RUST" "$C_HEAD" "$REPO"; then
    ok "binary at non-Rust HEAD counts as current (contains rust head)"
else bad "binary at HEAD should be current"; fi

# 3. a binary built exactly at the Rust commit → current
if binary_has_rust_head "$C_RUST" "$C_RUST" "$REPO"; then
    ok "binary at the Rust commit is current"
else bad "binary at rust commit should be current"; fi

# 4. a NEW Rust commit the binary predates → stale (must rebuild)
echo 'fn main(){println!("v2");}' > "$REPO/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "rust v2"
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse HEAD)"
RH2="$(rust_head_sha "$REPO" "origin/main")"
if binary_has_rust_head "$RH2" "$C_HEAD" "$REPO"; then
    bad "binary predating a new Rust commit should be STALE"
else ok "new Rust commit → binary correctly flagged stale"; fi

# 5. unknown / empty binary sha → not-current (fail safe, never hide staleness)
binary_has_rust_head "$RH2" "unknown" "$REPO" && bad "unknown sha must not read as current" || ok "unknown binary sha fails safe (stale)"
binary_has_rust_head "" "$C_HEAD" "$REPO" && bad "empty rust sha must not read as current" || ok "empty rust sha fails safe"

if [ "$fails" -eq 0 ]; then echo "PASS: rust-aware deploy helpers"; else echo "FAIL: $fails assertion(s)"; exit 1; fi
