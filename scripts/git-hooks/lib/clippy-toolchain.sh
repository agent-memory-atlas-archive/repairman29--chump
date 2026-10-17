#!/usr/bin/env bash
# scripts/git-hooks/lib/clippy-toolchain.sh
#
# INFRA-8225: resolve the cargo-clippy invocation so the pre-push lint gate
# (Guard 0c, INFRA-1390) runs against the PINNED toolchain in
# rust-toolchain.toml — not whatever `cargo`/`clippy` happens to be first on
# PATH.
#
# The failure class this fixes: a Mac lane with a Homebrew rust 1.97 on PATH
# failed three pushes on src/routes/settings_repo.rs:204 `manual_filter`, a
# lint the pinned 1.96 toolchain (and therefore CI, INFRA-3524) never emit.
# A homebrew rust is NOT a rustup proxy, so it ignores rust-toolchain.toml
# entirely and lints with its own newer lint set — false-blocking a push that
# the authoritative CI would pass.
#
# Extracted into a sourced lib (sibling of off-rails-guard.sh) so the
# resolution logic is unit-testable in isolation
# (scripts/ci/test-pre-push-lint-gate.sh, newer-clippy fixture).
#
# Policy (never a silent pass):
#   rustup present      → `rustup run <pin> cargo clippy …` (GATING). rustup
#                         auto-installs the channel on first use, so this works
#                         on a fresh checkout with only rustup installed.
#   rustup absent,
#     local == pin (or
#     older than pin)   → `cargo clippy …` directly (GATING; legacy behaviour).
#   rustup absent,
#     local NEWER
#     than pin          → cannot reproduce the pinned lint set. Run clippy for
#                         SIGNAL but DEFER the gate to CI (non-gating) with one
#                         loud line + ambient event. A newer-clippy-only lint
#                         must not block a push the pin + CI never see.

# --- version parsing helpers ---------------------------------------------

# _chump_rust_minor "1.96.0" → "96"   (echoes empty on parse failure)
_chump_rust_minor() {
    printf '%s' "$1" | sed -nE 's/^1\.([0-9]+).*/\1/p' | head -1
}

# _chump_clippy_minor_local → the local clippy's Rust minor, e.g. "96".
# clippy reports `clippy 0.1.<minor> (hash date)`; <minor> maps 1:1 to the
# Rust minor (clippy 0.1.96 == Rust 1.96). Echoes empty if clippy is absent
# or unparsable.
_chump_clippy_minor_local() {
    local v
    v="$(cargo clippy --version 2>/dev/null || true)"
    [[ -z "$v" ]] && v="$(cargo-clippy --version 2>/dev/null || true)"
    printf '%s' "$v" | sed -nE 's/^clippy 0\.1\.([0-9]+).*/\1/p' | head -1
}

# --- plan resolver --------------------------------------------------------

# chump_clippy_toolchain_plan <repo_root>
#
# Echoes exactly one plan token on stdout (sets no globals):
#   rustup:<pin>            → invoke `rustup run <pin> cargo clippy` (gating)
#   direct                  → run `cargo clippy` directly (gating)
#   defer:0.1.<minor>:<pin> → local clippy NEWER than pin AND no rustup; the
#                             caller runs clippy non-gating + prints a loud
#                             line + emits ambient. NEVER a silent pass.
chump_clippy_toolchain_plan() {
    local repo_root="${1:-.}"
    local toml="$repo_root/rust-toolchain.toml"

    # Operator opt-out (registered in scripts/ci/env-vars-internal.txt):
    # CHUMP_CLIPPY_PIN=0 restores the legacy raw-PATH clippy behaviour.
    if [[ "${CHUMP_CLIPPY_PIN:-1}" == "0" ]]; then
        echo "direct"
        return 0
    fi

    local pin=""
    if [[ -f "$toml" ]]; then
        pin="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"?([^"#]+)"?.*/\1/p' "$toml" \
              | head -1 | tr -d '[:space:]')"
    fi

    # No pin to resolve → preserve legacy behaviour (run clippy directly).
    if [[ -z "$pin" ]]; then
        echo "direct"
        return 0
    fi

    # rustup present → always honour the pin explicitly.
    if command -v rustup &>/dev/null; then
        echo "rustup:$pin"
        return 0
    fi

    # No rustup: compare the local clippy version to the pin.
    local local_minor pin_minor
    local_minor="$(_chump_clippy_minor_local)"
    pin_minor="$(_chump_rust_minor "$pin")"

    # Unparsable on either side → fall back to running clippy directly (a
    # loud-but-run default; never a silent skip).
    if [[ -z "$local_minor" || -z "$pin_minor" ]]; then
        echo "direct"
        return 0
    fi

    if [[ "$local_minor" -gt "$pin_minor" ]]; then
        echo "defer:0.1.$local_minor:$pin"
        return 0
    fi

    echo "direct"
}
