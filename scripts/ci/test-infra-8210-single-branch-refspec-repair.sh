#!/usr/bin/env bash
# scripts/ci/test-infra-8210-single-branch-refspec-repair.sh — INFRA-8210
#
# Proves the single-branch-fetch-refspec repair end to end:
#
#   1. A fixture clone made with `git clone --single-branch` only fetches
#      origin/main — a remote FEATURE branch is invisible to `git fetch origin`.
#   2. The installer step (repair_fetch_refspec, the shared primitive
#      scripts/setup/chump-node-install.sh drives via ensure_full_refspec in
#      ensure_home) rewrites remote.origin.fetch to the all-branches refspec.
#   3. After repair, `git fetch origin` populates the remote feature branch —
#      the exact capability dispatch resume / salvage / rebases depend on.
#   4. The repair is idempotent (a second call reports already-correct).
#   5. chump-node-install.sh actually WIRES the repair (sources the lib + calls
#      ensure_full_refspec from ensure_home) — not just ships the primitive.
#   6. The fleet-doctor check (check_fetch_refspec_single_branch) FAILS on a
#      single-branch checkout and PASSES once repaired.
#
# The root cause (INFRA-8210): the cuphead hub's main checkout carried a
# single-branch refspec, so remote feature branches were never fetched and
# dispatch resume / salvage / rebases silently broke.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/setup/lib/refspec-repair.sh"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
CONVERGE="$REPO_ROOT/scripts/ops/node-converge.sh"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '\033[0;31mFAIL\033[0m %s\n' "$*"; }

# ── 0. presence + syntax ────────────────────────────────────────────────────
for f in "$LIB" "$INSTALLER" "$CONVERGE" "$DOCTOR"; do
    [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }
    bash -n "$f" || { echo "FATAL: syntax error in $f"; exit 1; }
done
ok "all scripts present + bash -n clean"

# shellcheck source=/dev/null
source "$LIB"
command -v repair_fetch_refspec >/dev/null 2>&1 \
    && ok "repair_fetch_refspec sourced" \
    || { fail "repair_fetch_refspec not defined after sourcing lib"; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

# ── Fixture: bare origin with main + a feature branch ───────────────────────
ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
git init --bare -q "$ORIGIN"
git init -q "$SEED"
git -C "$SEED" config user.email test@example.com
git -C "$SEED" config user.name "Test"
git -C "$SEED" checkout -q -b main
echo seed > "$SEED/file"
git -C "$SEED" add -A && git -C "$SEED" commit -qm seed
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b feature/remote-only
echo feat > "$SEED/feat"
git -C "$SEED" add -A && git -C "$SEED" commit -qm feat
git -C "$SEED" push -q origin feature/remote-only

# ── 1. single-branch clone hides the feature branch ────────────────────────
CLONE="$TMP/clone"
git clone -q --single-branch --branch main "$ORIGIN" "$CLONE"
narrow="$(git -C "$CLONE" config --get-all remote.origin.fetch)"
case "$narrow" in
    *'refs/heads/*'*) fail "fixture clone unexpectedly has all-branches refspec: $narrow" ;;
    *) ok "fixture --single-branch clone has narrow refspec ($narrow)" ;;
esac
git -C "$CLONE" fetch origin --quiet
if git -C "$CLONE" rev-parse --verify -q refs/remotes/origin/feature/remote-only >/dev/null; then
    fail "feature branch visible BEFORE repair (fixture is not single-branch)"
else
    ok "feature branch invisible before repair (reproduces the bug)"
fi

# ── 2. installer step repairs the refspec ───────────────────────────────────
repair_fetch_refspec "$CLONE" origin; rc=$?
[ "$rc" -eq 10 ] && ok "repair returned 'repaired' (rc=10)" || fail "repair rc=$rc (expected 10)"
full="$(git -C "$CLONE" config --get-all remote.origin.fetch)"
[ "$full" = '+refs/heads/*:refs/remotes/origin/*' ] \
    && ok "refspec rewritten to all-branches" \
    || fail "refspec not all-branches after repair: $full"

# ── 3. feature branch now fetches ───────────────────────────────────────────
git -C "$CLONE" fetch origin --quiet
if git -C "$CLONE" rev-parse --verify -q refs/remotes/origin/feature/remote-only >/dev/null; then
    ok "feature branch visible AFTER repair + fetch"
else
    fail "feature branch still invisible after repair + fetch"
fi

# ── 4. idempotent ───────────────────────────────────────────────────────────
repair_fetch_refspec "$CLONE" origin; rc=$?
[ "$rc" -eq 0 ] && ok "second repair is a no-op (rc=0 already-correct)" || fail "idempotent repair rc=$rc (expected 0)"

# ── 5. installer actually wires the repair ──────────────────────────────────
if grep -q 'source .*lib/refspec-repair.sh' "$INSTALLER" && grep -q 'ensure_full_refspec "\$NODE_DIR/repo"' "$INSTALLER"; then
    ok "installer sources the lib AND calls ensure_full_refspec from ensure_home"
else
    fail "installer does not wire ensure_full_refspec into ensure_home"
fi
# node-converge re-asserts it every tick
grep -q 'repair_fetch_refspec "\$REPO_ROOT"' "$CONVERGE" \
    && ok "node-converge re-asserts the refspec each tick" \
    || fail "node-converge does not call repair_fetch_refspec"

# ── 6. fleet-doctor check flags single-branch, passes once repaired ─────────
# Source the doctor in test mode (FLEET_DOCTOR_SOURCED=1 returns before the
# networked sweep) and drive the one check against our fixture checkout.
NARROW="$TMP/doctor-narrow"
git clone -q --single-branch --branch main "$ORIGIN" "$NARROW"
(
    export FLEET_DOCTOR_SOURCED=1
    # shellcheck source=/dev/null
    source "$DOCTOR" >/dev/null 2>&1
    REPO_ROOT="$NARROW"
    CHUMP_AMBIENT_LOG="$TMP/doctor-ambient.jsonl"
    FAIL_COUNT=0
    check_fetch_refspec_single_branch
    # register_check bumps FAIL_COUNT on a fail; surface the last status.
    echo "${STATUSES[-1]}" > "$TMP/doctor-narrow-status"
) || true
[ "$(cat "$TMP/doctor-narrow-status" 2>/dev/null)" = "fail" ] \
    && ok "fleet-doctor check FAILS on single-branch checkout" \
    || fail "fleet-doctor check did not fail on single-branch checkout (got '$(cat "$TMP/doctor-narrow-status" 2>/dev/null)')"
# ambient finding emitted
grep -q '"kind":"checkout_single_branch_refspec"' "$TMP/doctor-ambient.jsonl" 2>/dev/null \
    && ok "fleet-doctor emitted checkout_single_branch_refspec finding" \
    || fail "fleet-doctor did not emit the ambient finding"

repair_fetch_refspec "$NARROW" origin >/dev/null
(
    export FLEET_DOCTOR_SOURCED=1
    # shellcheck source=/dev/null
    source "$DOCTOR" >/dev/null 2>&1
    REPO_ROOT="$NARROW"
    check_fetch_refspec_single_branch
    echo "${STATUSES[-1]}" > "$TMP/doctor-repaired-status"
) || true
[ "$(cat "$TMP/doctor-repaired-status" 2>/dev/null)" = "pass" ] \
    && ok "fleet-doctor check PASSES once refspec repaired" \
    || fail "fleet-doctor check still failing after repair (got '$(cat "$TMP/doctor-repaired-status" 2>/dev/null)')"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
printf '\033[0;32mALL PASS\033[0m %s\n' "$(basename "$0")"
