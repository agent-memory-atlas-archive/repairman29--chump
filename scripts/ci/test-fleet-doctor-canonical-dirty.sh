#!/usr/bin/env bash
# test-fleet-doctor-canonical-dirty.sh — RESILIENT-1686
#
# Verifies fleet-doctor-strict.sh's canonical-checkout-dirty check
# (check_canonical_checkout_dirty):
#   1. Clean canonical checkout → pass.
#   2. ONLY Cargo.lock modified → fail, detail names Cargo.lock, and a
#      kind=canonical_checkout_dirty event with lock_residue:1 lands in
#      ambient.jsonl. THIS case is the mutant-killer: a mutant that drops
#      Cargo.lock from the scan would see a "clean" tree here and pass,
#      which this assertion catches.
#   3. ONLY workspace-hack/Cargo.toml modified → fail (residue class).
#   4. A non-lock tracked file modified → fail (general dirtiness is loud too).
#   5. Untracked files only (expected .chump/ etc.) → pass (-uno).
#
# Reproduces the RESILIENT-1686 incident: `chump gap ship` ran
# `cargo hakari generate` in the canonical checkout, rewriting Cargo.lock
# (-156/+18) and workspace-hack/Cargo.toml, and that residue then made the
# NEXT ship refuse (INFRA-2423 auto-fetch-on-dirty). This test fails on a
# checkout without RESILIENT-1686's check_canonical_checkout_dirty function
# (undefined function error).
set -uo pipefail

REPO_ROOT_REAL="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT_REAL/scripts/coord/fleet-doctor-strict.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-canonical-dirty-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

FIXTURE="$TMPDIR_BASE/repo"
mkdir -p "$FIXTURE/workspace-hack"
git -C "$FIXTURE" init -q --initial-branch=main
git -C "$FIXTURE" config user.email test@test.local
git -C "$FIXTURE" config user.name test
printf '[workspace]\nmembers = []\n' > "$FIXTURE/Cargo.toml"
printf '# lockfile sentinel\nversion = 4\n' > "$FIXTURE/Cargo.lock"
printf '[package]\nname = "workspace-hack"\n' > "$FIXTURE/workspace-hack/Cargo.toml"
printf 'fn main() {}\n' > "$FIXTURE/other.rs"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m init

AMB="$TMPDIR_BASE/ambient.jsonl"

# ── Test 1: clean → pass ────────────────────────────────────────────────────
REPO_ROOT="$FIXTURE"
CHUMP_AMBIENT_LOG="$AMB" check_canonical_checkout_dirty
if [[ "$(last_status)" == "pass" ]] && [[ "$(last_detail)" == *"clean"* ]]; then
    pass "clean canonical checkout → pass"
else
    fail "expected pass on clean tree, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 2: ONLY Cargo.lock modified → fail + lock_residue event (MUTANT KILLER)
printf '# lockfile sentinel\nversion = 4\nmutated = true\n' > "$FIXTURE/Cargo.lock"
REPO_ROOT="$FIXTURE"
CHUMP_AMBIENT_LOG="$AMB" check_canonical_checkout_dirty
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"Cargo.lock"* ]]; then
    pass "Cargo.lock-only residue → fail, detail names Cargo.lock"
else
    fail "expected fail naming Cargo.lock, got status=$(last_status) detail=$(last_detail)"
fi
if [[ -f "$AMB" ]] && grep -q '"kind":"canonical_checkout_dirty"' "$AMB" \
    && grep -q '"lock_residue":1' "$AMB"; then
    pass "kind=canonical_checkout_dirty with lock_residue:1 written to ambient.jsonl"
else
    fail "expected kind=canonical_checkout_dirty + lock_residue:1 in $AMB"
fi
git -C "$FIXTURE" checkout -q -- Cargo.lock

# ── Test 3: ONLY workspace-hack/Cargo.toml modified → fail ──────────────────
printf '[package]\nname = "workspace-hack"\nmutated = true\n' > "$FIXTURE/workspace-hack/Cargo.toml"
REPO_ROOT="$FIXTURE"
CHUMP_AMBIENT_LOG="$AMB" check_canonical_checkout_dirty
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"workspace-hack/Cargo.toml"* ]]; then
    pass "workspace-hack/Cargo.toml residue → fail, detail names it"
else
    fail "expected fail naming workspace-hack, got status=$(last_status) detail=$(last_detail)"
fi
git -C "$FIXTURE" checkout -q -- workspace-hack/Cargo.toml

# ── Test 4: a non-lock tracked file modified → fail (general dirtiness) ─────
printf 'fn main() { /* edited */ }\n' > "$FIXTURE/other.rs"
REPO_ROOT="$FIXTURE"
CHUMP_AMBIENT_LOG="$AMB" check_canonical_checkout_dirty
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"other.rs"* ]]; then
    pass "non-lock tracked modification → fail (loud)"
else
    fail "expected fail naming other.rs, got status=$(last_status) detail=$(last_detail)"
fi
git -C "$FIXTURE" checkout -q -- other.rs

# ── Test 5: untracked-only → pass (-uno ignores expected .chump/, target/) ──
mkdir -p "$FIXTURE/.chump"
printf 'junk\n' > "$FIXTURE/.chump/state.db"
REPO_ROOT="$FIXTURE"
CHUMP_AMBIENT_LOG="$AMB" check_canonical_checkout_dirty
if [[ "$(last_status)" == "pass" ]]; then
    pass "untracked-only files → pass (not the residue class)"
else
    fail "expected pass with only untracked files, got status=$(last_status) detail=$(last_detail)"
fi

echo "=== all fleet-doctor canonical-checkout-dirty tests passed ==="
