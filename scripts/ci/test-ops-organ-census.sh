#!/usr/bin/env bash
# test-ops-organ-census.sh — INFRA-8576 (PHASE-R R6, INFRA-8195 AC4)
#
# CI-side organ census. META-064's scripts/git-hooks/pre-commit-rust-first.sh
# gates a NEW scripts/ops/*.sh organ at COMMIT time (it requires a
# `Rust-First-Bypass:` trailer when the Rust-first criteria fire). This gate is
# the CI-side mirror: a new organ (one not grandfathered in
# scripts/ci/ops-organ-census-allowlist.txt) fails unless it satisfies ONE of
# the three escape hatches the commit hook's trailer is only one of:
#
#   (1) RUST TWIN — the organ declares `# Rust-Twin: <relpath>` in its header
#       and <relpath> is an existing crates/**/*.rs or src/**/*.rs file. This
#       is the author-declared signal that a Rust implementation owns the
#       invariant and the shell is thin glue over it.
#   (2) BYPASS TRAILER — the commit that ADDED the organ carries a
#       `Rust-First-Bypass:` trailer. This REUSES the trailer contract defined
#       by scripts/git-hooks/pre-commit-rust-first.sh (META-064); we do not
#       re-implement that hook's Rust-first criteria here — commit-time
#       enforcement stays the hook's job, this gate only reads the same trailer
#       CI-side so a bypass can't be laundered by a shallow local hook skip.
#   (3) TIER-D LINE — docs/process/CI_GATES_INVENTORY.md's "## Tier D" section
#       names the organ (cannot-mirror-locally class), same inventory the
#       preflight-vs-CI parity gate already consults.
#
# Existing organs are grandfathered in the shrink-only allowlist (AC3).
#
# ENV
#   CHUMP_OPS_CENSUS_ROOT   repo root override (default: resolved from script path)
#   CHUMP_OPS_CENSUS_ALLOWLIST  allowlist path override (default: sibling file)
#   CHUMP_OPS_CENSUS_INVENTORY  CI_GATES_INVENTORY.md path override

set -uo pipefail

ROOT="${CHUMP_OPS_CENSUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ALLOWLIST="${CHUMP_OPS_CENSUS_ALLOWLIST:-$ROOT/scripts/ci/ops-organ-census-allowlist.txt}"
INVENTORY="${CHUMP_OPS_CENSUS_INVENTORY:-$ROOT/docs/process/CI_GATES_INVENTORY.md}"
OPS_DIR="$ROOT/scripts/ops"

echo "=== INFRA-8576 ops-organ census gate ==="
echo "root: $ROOT"

# ── Parse the grandfather allowlist into a set ──────────────────────────────
declare -A GRANDFATHERED
if [[ -f "$ALLOWLIST" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
        GRANDFATHERED["${line%% *}"]=1
    done < "$ALLOWLIST"
fi

# ── Extract the Tier-D block of the inventory once (basename substring match) ─
TIERD_BLOCK=""
if [[ -f "$INVENTORY" ]]; then
    TIERD_BLOCK="$(awk '/^## Tier D/{f=1;next} /^## /{f=0} f' "$INVENTORY" 2>/dev/null)"
fi

# ── Per-organ twin detection: declared `# Rust-Twin: <relpath>` header ──────
has_rust_twin() {
    local organ="$1"
    local rel
    rel="$(grep -m1 -E '^#[[:space:]]*Rust-Twin:' "$organ" 2>/dev/null \
        | sed -E 's/^#[[:space:]]*Rust-Twin:[[:space:]]*//' | tr -d '[:space:]')"
    [[ -z "$rel" ]] && return 1
    # Must point at a real .rs file under crates/ or src/.
    case "$rel" in
        crates/*.rs|src/*.rs) [[ -f "$ROOT/$rel" ]] && return 0 ;;
    esac
    return 1
}

# ── Per-organ bypass trailer: on the commit that ADDED the organ ────────────
# REUSES the pre-commit-rust-first.sh trailer contract (META-064). Only
# consulted for a NEW (non-grandfathered) organ, so a shallow CI checkout of
# the all-grandfathered main tree never needs git history.
added_with_bypass() {
    local organ="$1"
    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    local rel="${organ#"$ROOT"/}"
    # Capture then test — never end a pipefail pipeline in `grep -q` (an early
    # grep exit can SIGPIPE `git log` and mask a real match).
    local msgs
    msgs="$(git -C "$ROOT" log --diff-filter=A --format='%B' -- "$rel" 2>/dev/null)"
    grep -qE '^Rust-First-Bypass:' <<<"$msgs" && return 0
    return 1
}

# ── Per-organ Tier-D listing (basename substring in the Tier-D block) ───────
in_tier_d() {
    local base="$1"
    [[ -z "$TIERD_BLOCK" ]] && return 1
    grep -qF "$base" <<<"$TIERD_BLOCK" && return 0
    return 1
}

shopt -s nullglob
VIOLATIONS=()
for organ in "$OPS_DIR"/*.sh; do
    base="$(basename "$organ")"
    # (AC3) Grandfathered organs always pass.
    [[ -n "${GRANDFATHERED[$base]:-}" ]] && continue
    # (AC2) Any one of the three escape hatches passes.
    has_rust_twin "$organ" && continue
    added_with_bypass "$organ" && continue
    in_tier_d "$base" && continue
    VIOLATIONS+=("$base")
done
shopt -u nullglob

AMBIENT="${CHUMP_AMBIENT_LOG:-$ROOT/.chump-locks/ambient.jsonl}"
if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
    echo "✓ every scripts/ops organ is grandfathered or carries a twin / bypass / Tier-D line"
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"ops_organ_census","status":"ok","violations":0}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

echo "✗ new scripts/ops organ(s) with no Rust twin, no Rust-First-Bypass trailer, and no Tier-D line:"
for v in "${VIOLATIONS[@]}"; do
    echo "    - scripts/ops/$v"
done
echo ""
echo "Fix one of:"
echo "  1. Add a header to the organ:  # Rust-Twin: crates/<crate>/src/<file>.rs"
echo "     pointing at the Rust implementation that owns the invariant."
echo "  2. Add a 'Rust-First-Bypass: <reason>' trailer to the commit that adds it"
echo "     (same trailer scripts/git-hooks/pre-commit-rust-first.sh already asks for)."
echo "  3. Add a Tier-D line naming it in docs/process/CI_GATES_INVENTORY.md."
echo ""
echo "Grandfathering (adding to scripts/ci/ops-organ-census-allowlist.txt) is"
echo "NOT an option for new organs — that list is shrink-only."
if [[ -d "$(dirname "$AMBIENT")" ]]; then
    printf '{"ts":"%s","kind":"ops_organ_census","status":"violation","violations":%d,"organs":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#VIOLATIONS[@]}" "$(IFS=,; echo "${VIOLATIONS[*]}")" \
        >> "$AMBIENT" 2>/dev/null || true
fi
exit 1
