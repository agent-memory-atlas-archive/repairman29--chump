#!/usr/bin/env bash
# test-gap-store-single-source.sh — CI guard against REINTRODUCING the gap-store
# split-brain ([[gap-store-split-brain-swamp]] / RESILIENT-1057).
#
# The runtime guard (scripts/coord/gap-store-single-source-check.sh) proves the
# LIVE fleet has one source of truth. THIS test proves the CODEBASE can't quietly
# grow a second one: it pins the structural invariants that keep sqlite
# (.chump/state.db) canonical and the postgres/postgrest backend dormant until an
# explicit, reviewed INFRA-2092 migration flips it on with a backfill.
#
# Exits non-zero if any invariant is violated. No network / no state.db needed —
# pure source inspection, safe for a fresh CI checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
fail=0
ok()   { printf 'ok   - %s\n' "$*"; }
bad()  { printf 'FAIL - %s\n' "$*"; fail=1; }

CARGO="crates/chump-gap-store/Cargo.toml"
LIB="crates/chump-gap-store/src/lib.rs"

# 1) postgres-backend must NOT be a default feature. If it becomes default-on,
#    every build silently compiles the remote backend and the empty-store
#    fallback risk returns.
if grep -qE '^\s*default\s*=' "$CARGO"; then
  if grep -E '^\s*default\s*=' "$CARGO" | grep -q 'postgres-backend'; then
    bad "chump-gap-store default features enable postgres-backend — must stay opt-in (INFRA-2092)"
  else
    ok "chump-gap-store default features do not enable postgres-backend"
  fi
else
  ok "chump-gap-store declares no default features (postgres-backend stays opt-in)"
fi

# 2) The canonical store path must resolve to sqlite .chump/state.db, through
#    the ONE resolver (INFRA-8190, crates/chump-store-path) that GapStore
#    delegates to.
RESOLVER="crates/chump-store-path/src/lib.rs"
if grep -qE 'join\("\.chump"\)\.join\("state\.db"\)' "$RESOLVER" \
   && grep -qE 'store_path::state_db_path\(repo_root\)' "$LIB"; then
  ok "gap store default path resolves to sqlite .chump/state.db via chump-store-path"
else
  bad "could not confirm GapStore::db_path -> chump-store-path -> .chump/state.db ($LIB, $RESOLVER)"
fi

# 3) No crate may silently wire CHUMP_GAP_STORE_URL into the gap-store selection.
#    The dormant postgrest store is reached (if ever) only by an explicit,
#    reviewed migration path — not by an env var quietly redirecting reads.
#    Two legitimate references are NOT store-selection wiring and are excluded:
#      - the chump-gap-doctor binary READS the var only to probe-and-alarm on a
#        misconfigured second store (it is the detector FOR this hazard, and never
#        routes gap operations through it);
#      - doc comments (//, ///, //!) that merely document the var's meaning.
#    Any other crate reference still fails this gate.
hits="$(grep -rnE 'CHUMP_GAP_STORE_URL' crates/ 2>/dev/null \
  | grep -v '/chump-gap-doctor\.rs:' \
  | grep -vE ':[0-9]+:[[:space:]]*//' \
  || true)"
if [ -n "$hits" ]; then
  echo "$hits"
  bad "CHUMP_GAP_STORE_URL is referenced in crate source — a silent remote-store redirect. Wire the store only via the explicit INFRA-2092 migration + backfill, not an env var."
else
  ok "no crate silently redirects the gap store via CHUMP_GAP_STORE_URL"
fi

# 4) Doctrine doc must exist so the canonical decision is discoverable.
if [ -f docs/architecture/CANONICAL_GAP_STORE.md ]; then
  ok "canonical-store doctrine doc present"
else
  bad "docs/architecture/CANONICAL_GAP_STORE.md missing — the single-source decision must be documented"
fi

# 5) CREDIBLE-1602 runtime: a node must carry exactly ONE live gap store.
#    fleet-doctor-strict.sh's check_single_store REDs a node with more than one
#    live state.db and PASSes once the extras are renamed aside with a
#    CHUMP_STORE_ARCHIVED marker (scripts/coord/archive-stale-gap-store.sh).
#    This is the runtime half of the single-source invariant — the live cuphead
#    split (three state.db on one node, the organ shipping against the wrong one)
#    that the source checks above cannot see. Scanned from $HOME, so the fixture
#    runs under a sandbox HOME (the real path, per the standing seam rule).
#    MUTANT (killed here): change `(( n > 1 ))` to `(( n > 99 ))` in
#    check_single_store (ignore the extra store) → the three-store case no longer
#    REDs and the first assertion fails.
DOCTOR="$ROOT/scripts/coord/fleet-doctor-strict.sh"
ARCHIVER="$ROOT/scripts/coord/archive-stale-gap-store.sh"
if [ -f "$DOCTOR" ] && [ -f "$ARCHIVER" ]; then
  sb="$(mktemp -d "${TMPDIR:-/tmp}/single-store-rt.XXXXXX")"
  mkdir -p "$sb/chump/.chump" "$sb/.chump" "$sb/.chumpnode/repo/.chump" "$sb/tmp/.scratch/.chump"
  : > "$sb/chump/.chump/state.db"           # canonical
  : > "$sb/.chump/state.db"                 # stale home store
  : > "$sb/.chumpnode/repo/.chump/state.db" # stale node-clone store
  : > "$sb/tmp/.scratch/.chump/state.db"    # ephemeral — must be pruned, never counted
  # worktree-style symlink into the canonical store — must NOT count as a store.
  ln -s "$sb/chump/.chump/state.db" "$sb/wt-state.db" 2>/dev/null || true
  st_multi="$(FLEET_DOCTOR_SOURCED=1 HOME="$sb" bash -c 'source "$0"; check_single_store; printf "%s" "${STATUSES[-1]:-}"' "$DOCTOR" 2>/dev/null)"
  if [ "$st_multi" = fail ]; then
    ok "fleet-doctor check_single_store REDs a node with >1 live state.db"
  else
    bad "fleet-doctor check_single_store did NOT RED with 3 live stores (status='$st_multi')"
  fi
  bash "$ARCHIVER" "$sb/.chump/state.db"                 --reason "stale home store (CREDIBLE-1602 fixture)" --canonical "$sb/chump/.chump/state.db" >/dev/null 2>&1
  bash "$ARCHIVER" "$sb/.chumpnode/repo/.chump/state.db" --reason "stale node-clone store (CREDIBLE-1602 fixture)" --canonical "$sb/chump/.chump/state.db" >/dev/null 2>&1
  st_one="$(FLEET_DOCTOR_SOURCED=1 HOME="$sb" bash -c 'source "$0"; check_single_store; printf "%s" "${STATUSES[-1]:-}"' "$DOCTOR" 2>/dev/null)"
  if [ "$st_one" = pass ]; then
    ok "fleet-doctor check_single_store PASSes once the extras carry a CHUMP_STORE_ARCHIVED marker"
  else
    bad "fleet-doctor check_single_store did NOT PASS after archiving the extras (status='$st_one')"
  fi
  rm -rf "$sb"

  # 6) RESILIENT-1650 runtime: 1 canonical store + 1 NONCANONICAL-marked copy
  #    (reported as non-canonical, never synced toward canonical) + 1 unmarked
  #    copy (flagged as UNMARKED). Also verifies that once the unmarked copy is
  #    marked NONCANONICAL, the check PASSes while still reporting both
  #    canonical and non-canonical stores.
  sb2="$(mktemp -d "${TMPDIR:-/tmp}/single-store-r1650.XXXXXX")"
  mkdir -p "$sb2/chump/.chump" "$sb2/.chump" "$sb2/.chumpnode/repo/.chump"
  : > "$sb2/chump/.chump/state.db"           # canonical
  : > "$sb2/.chump/state.db"                 # NONCANONICAL-marked copy
  printf 'NONCANONICAL: retired home store\n' > "$sb2/.chump/NONCANONICAL"
  : > "$sb2/.chumpnode/repo/.chump/state.db" # UNMARKED extra copy
  r1650_out="$(FLEET_DOCTOR_SOURCED=1 HOME="$sb2" bash -c 'source "$0"; check_single_store; printf "%s|%s" "${STATUSES[-1]:-}" "${DETAILS[-1]:-}"' "$DOCTOR" 2>/dev/null)"
  r1650_st="${r1650_out%%|*}"
  r1650_det="${r1650_out#*|}"
  if [ "$r1650_st" = fail ] \
     && printf '%s' "$r1650_det" | grep -qF "canonical: $sb2/chump/.chump/state.db" \
     && printf '%s' "$r1650_det" | grep -qF "non-canonical: $sb2/.chump/state.db" \
     && printf '%s' "$r1650_det" | grep -qF "UNMARKED: $sb2/.chumpnode/repo/.chump/state.db"; then
    ok "RESILIENT-1650: 1 canonical + 1 NONCANONICAL + 1 UNMARKED classifies all three and REDs on UNMARKED"
  else
    bad "RESILIENT-1650: expected fail classifying canonical/non-canonical/UNMARKED, got status='$r1650_st' detail='$r1650_det'"
  fi
  printf 'NONCANONICAL: retired node clone\n' > "$sb2/.chumpnode/repo/.chump/NONCANONICAL"
  r1650_ok_out="$(FLEET_DOCTOR_SOURCED=1 HOME="$sb2" bash -c 'source "$0"; check_single_store; printf "%s|%s" "${STATUSES[-1]:-}" "${DETAILS[-1]:-}"' "$DOCTOR" 2>/dev/null)"
  r1650_ok_st="${r1650_ok_out%%|*}"
  r1650_ok_det="${r1650_ok_out#*|}"
  if [ "$r1650_ok_st" = pass ] \
     && printf '%s' "$r1650_ok_det" | grep -qF "canonical: $sb2/chump/.chump/state.db" \
     && printf '%s' "$r1650_ok_det" | grep -qF "non-canonical:" \
     && printf '%s' "$r1650_ok_det" | grep -qF "$sb2/.chump/state.db" \
     && printf '%s' "$r1650_ok_det" | grep -qF "$sb2/.chumpnode/repo/.chump/state.db" \
     && grep -q 'store_noncanonical_marker(canonical_db)\.is_some()' "$LIB"; then
    ok "RESILIENT-1650: 1 canonical + NONCANONICAL copies PASSes, reports non-canonical copies, and blocks sync toward canonical"
  else
    bad "RESILIENT-1650: expected pass reporting canonical + non-canonical copies, got status='$r1650_ok_st' detail='$r1650_ok_det'"
  fi
  rm -rf "$sb2"
else
  bad "fleet-doctor-strict.sh or archive-stale-gap-store.sh missing (CREDIBLE-1602)"
fi

if [ "$fail" -ne 0 ]; then
  echo "gap-store single-source invariants VIOLATED"; exit 1
fi
echo "gap-store single-source invariants hold"
exit 0
