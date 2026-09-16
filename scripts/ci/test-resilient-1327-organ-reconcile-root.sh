#!/usr/bin/env bash
# test-resilient-1327-organ-reconcile-root.sh — RESILIENT-1327
#
# chump-organ-reconcile.service declares User=root in-tree, but on an owned
# node install-helsinki-atc.sh's generic host-rewrite flips EVERY unit's
# User=root -> the box's run-user UNLESS the unit is listed in the
# _KEEP_ROOT_ORGANS exemption (RESILIENT-374). organ-reconcile.sh itself needs
# root to write /etc/systemd/system (see its own `id -u != 0` ->
# organ_reconcile_skipped guard) — exactly like chump-organ-deploy — so
# without the exemption the installed unit runs as the non-root run-user
# (e.g. User=ubuntu on cuphead/mugman) and organ-reconcile.sh no-ops every
# cycle instead of converging systemd state to the manifest.
#
# This proves (a) install-helsinki-atc.sh's _KEEP_ROOT_ORGANS declares both
# chump-organ-reconcile.service and .timer, and (b) the shared host-rewrite
# lib actually re-asserts User=root on the reconcile unit when invoked with
# keep_root=1 (the flag install-helsinki-atc.sh now passes for it) — and
# fails to keep User=root when keep_root=0 (the pre-fix behavior), so the
# test would have failed before RESILIENT-1327.

set -uo pipefail
FAIL=0
ok()   { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
INSTALLER="$ROOT/scripts/setup/install-helsinki-atc.sh"
LIB="$ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
SRC="$ROOT/scripts/dispatch/chump-organ-reconcile.service"

[[ -f "$INSTALLER" ]] || fail "install-helsinki-atc.sh missing"
[[ -f "$LIB" ]] || fail "organ-unit-install-lib.sh missing"
[[ -f "$SRC" ]] || fail "chump-organ-reconcile.service missing"

# ── 1. _KEEP_ROOT_ORGANS declares the reconcile unit (service + timer) ──────
# Extract the declare -A block verbatim and eval it in isolation so this test
# tracks the REAL array in install-helsinki-atc.sh, not a hand-copied guess.
ARRAY_SNIPPET="$(awk '/declare -A _KEEP_ROOT_ORGANS=\(/,/^\)/' "$INSTALLER")"
[[ -n "$ARRAY_SNIPPET" ]] || fail "could not extract _KEEP_ROOT_ORGANS array from install-helsinki-atc.sh"
eval "$ARRAY_SNIPPET"

[[ "${_KEEP_ROOT_ORGANS[chump-organ-reconcile.service]:-0}" == "1" ]] \
  || fail "_KEEP_ROOT_ORGANS must exempt chump-organ-reconcile.service (root needed to write /etc/systemd/system)"
[[ "${_KEEP_ROOT_ORGANS[chump-organ-reconcile.timer]:-0}" == "1" ]] \
  || fail "_KEEP_ROOT_ORGANS must exempt chump-organ-reconcile.timer"
ok "_KEEP_ROOT_ORGANS exempts chump-organ-reconcile.service + .timer"

# ── 2. source unit has no explicit User= override (sanity — the repo manifest
#       is the tracked helsinki-shaped unit, systemd defaults an unset User= to
#       root, matching organ_unit_host_rewrite's own src_user fallback) ──────
! grep -q "^User=" "$SRC" \
  || fail "chump-organ-reconcile.service source unexpectedly declares an explicit non-default User="
ok "source unit has no User= override (defaults to root, as the manifest intends)"

# ── 3. host-rewrite mechanics: keep_root=1 (what install-helsinki-atc.sh now
#       passes for this unit) re-asserts User=root even on an ubuntu run-user;
#       keep_root=0 (the pre-fix behavior) demotes it — proving this test
#       would fail without the RESILIENT-1327 wiring. ────────────────────────
# shellcheck source=scripts/ops/lib/organ-unit-install-lib.sh
source "$LIB"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

organ_unit_host_rewrite "$SRC" "$TMP/kept.service" "ubuntu" "/home/ubuntu" 1 "/home/ubuntu/chump"
grep -q "^User=root" "$TMP/kept.service" \
  || fail "keep_root=1 must produce User=root on cuphead/mugman-shaped rewrite"
ok "keep_root=1 (the fixed wiring) keeps User=root on an ubuntu run-user rewrite"

organ_unit_host_rewrite "$SRC" "$TMP/demoted.service" "ubuntu" "/home/ubuntu" 0 "/home/ubuntu/chump"
grep -q "^User=ubuntu" "$TMP/demoted.service" \
  || fail "keep_root=0 (the pre-fix path) is expected to demote to the run-user — reproduces the reported no-op bug"
! grep -q "^User=root" "$TMP/demoted.service" \
  || fail "keep_root=0 unexpectedly kept User=root (test's own repro is broken)"
ok "keep_root=0 reproduces the reported bug (User=ubuntu, not root) — confirms (2) is the actual fix"

if [ "$FAIL" -eq 0 ]; then echo "PASS test-resilient-1327-organ-reconcile-root"; else echo "FAILED test-resilient-1327-organ-reconcile-root"; exit 1; fi
