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

if [ "$fail" -ne 0 ]; then
  echo "gap-store single-source invariants VIOLATED"; exit 1
fi
echo "gap-store single-source invariants hold"
exit 0
