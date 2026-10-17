#!/usr/bin/env bash
# INFRA-3687: regression lock for the stale-checkout gap-ID collision class.
#
# Bug: `GapStore::reserve_with_external()` used to compute its allocation
# ceiling from ONLY the local `.chump/state.db` (`existing_max`) and cheap
# external sources (`extra_max` — `.chump-locks/*.json` leases + open-PR
# titles), never consulting the canonical registry dump
# (`.chump/state.sql`). A checkout N commits behind origin/main therefore has
# a stale local `gaps` table and can re-issue an ID that canonically
# already belongs to an already-merged gap. Real repro: a checkout 177
# commits behind reserved INFRA-3680, canonically a merged "parse_verdict"
# gap.
#
# Fix (three parts, all covered here):
#   1. `GapStore::canonical_max_id()` reads `registry/main:.chump/state.sql`
#      (INFRA-8193: the private registry remote only; origin/main no longer
#      tracks the file and is never read) via `git show` (best-effort
#      auto-fetch first) and folds its result
#      into `combined_max` in `reserve_with_external` — id-column-only
#      extraction, so junk `<DOMAIN>-N`-shaped substrings elsewhere in the
#      dump (notes/titles/descriptions) can never poison the allocator.
#   2. `reserve_with_external` fails closed (returns `Err`) when this
#      checkout is genuinely behind origin/main AND a configured registry is
#      unreadable, bypassable via the audited `CHUMP_RESERVE_ALLOW_STALE=1`
#      escape hatch. With no registry remote a behind checkout reserves
#      normally (INFRA-8193).
#   3. `chump gap list` prints a loud, non-blocking stderr warning when the
#      checkout is behind origin/main (covered by the pure-git behind-count
#      helper's unit tests below; the CLI wiring itself is a 6-line
#      stderr-only print with no independent test file — see
#      `src/main.rs`'s `"list" =>` arm).
#
# This script runs the cargo unit tests that lock all three invariants deterministically —
# no network, no `gh`, local `file://`-style git remotes only (see
# `auto_fetch_tests` helpers in crates/chump-gap-store/src/lib.rs).
#
# Run from repo root: bash scripts/ci/test-gap-reserve-no-stale-collision.sh

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

echo "[test-gap-reserve-no-stale-collision] running INFRA-3687 regression tests (serial — the fail-closed test mutates a process-global env var)..."

cargo test -p chump-gap-store --lib -- --test-threads=1 \
  canonical_max_id_reads_registry_state_sql_and_reserve_beats_stale_local \
  canonical_max_id_never_reads_origin_legacy_copy \
  reserve_fails_closed_when_behind_and_canonical_unreadable_bypass_works \
  canonical_max_id_parse_tests:: \
  2>&1 | tail -40

echo "[test-gap-reserve-no-stale-collision] PASS — canonical_max_id folds in correctly, fail-closed gate + CHUMP_RESERVE_ALLOW_STALE bypass both verified, junk-id extraction verified."
exit 0
