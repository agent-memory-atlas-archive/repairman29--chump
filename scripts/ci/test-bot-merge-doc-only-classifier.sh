#!/usr/bin/env bash
# test-bot-merge-doc-only-classifier.sh (INFRA-8112) — guard the bot-merge
# DOC_ONLY diff classifier (scripts/coord/bot-merge.sh ~line 2735).
#
# Depth: edge. Verifies the path-category logic that decides whether a PR can
# skip the local `cargo clippy --workspace` (CI clippy stays the gate). The
# classifier timed out shipping INFRA-8112 because .yml / .github/* were not in
# the safe-set, so a gate-wiring PR ran full workspace clippy and blew the 900s
# budget. Gaps: does not run bot-merge.sh end-to-end; it asserts the pure
# classification the script applies, plus that the live script still contains
# the broadened safe-set + the Cargo-manifest guard (regression tripwire).
set -u

BOT_MERGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/coord/bot-merge.sh"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# classify() mirrors bot-merge.sh's case logic. KEEP IN SYNC with the
# "# INFRA-8112:" block in scripts/coord/bot-merge.sh. Prints "doc_only" when a
# whole fileset is clippy-irrelevant, else "needs_clippy".
classify() {
    local rs=0 unsafe=0 f
    for f in "$@"; do
        case "$f" in
            Cargo.toml|Cargo.lock|*/Cargo.toml|*/Cargo.lock) unsafe=$((unsafe+1)) ;;
            *.rs)                              rs=$((rs+1)) ;;
            scripts/*|docs/*|.github/*|*.md|*.yaml|*.yml|*.sh) ;;
            *)                                 unsafe=$((unsafe+1)) ;;
        esac
    done
    if [ "$rs" -eq 0 ] && [ "$unsafe" -eq 0 ]; then echo doc_only; else echo needs_clippy; fi
}

assert() { local exp="$1"; shift; local got; got="$(classify "$@")"; [ "$got" = "$exp" ] && ok "$exp: $*" || bad "expected $exp got $got for: $*"; }

# non-Rust diffs → skip local clippy
assert doc_only scripts/setup/bootstrap-toolkit.sh scripts/ci/verify-toolkit.sh
assert doc_only .github/workflows/ci.yml                      # the INFRA-8112 regression path
assert doc_only scripts/ci/x.sh .github/workflows/audit.yml README.md
assert doc_only docs/PROCESS.md config.yaml release.yml
# Rust / build-graph diffs → MUST run clippy
assert needs_clippy src/main.rs
assert needs_clippy scripts/setup/bootstrap-toolkit.sh crates/foo/src/lib.rs
assert needs_clippy Cargo.toml                                # manifest changes the build
assert needs_clippy crates/foo/Cargo.toml
assert needs_clippy scripts/x.sh Cargo.lock
# an unknown top-level file is still conservative (needs clippy)
assert needs_clippy some_binary.bin

# Regression tripwire: the live script must carry the broadened safe-set + guard.
grep -q '.github/\*|\*.md|\*.yaml|\*.yml|\*.sh' "$BOT_MERGE" && ok "bot-merge.sh safe-set broadened (.github/*, *.yml)" \
    || bad "bot-merge.sh safe-set missing .github/* or *.yml"
grep -q 'Cargo.toml|Cargo.lock|\*/Cargo.toml|\*/Cargo.lock' "$BOT_MERGE" && ok "bot-merge.sh keeps Cargo manifests out of the safe-set" \
    || bad "bot-merge.sh missing Cargo-manifest guard"

if [ "$fails" -eq 0 ]; then echo "PASS: bot-merge doc-only classifier"; else echo "FAIL: $fails assertion(s)"; exit 1; fi
