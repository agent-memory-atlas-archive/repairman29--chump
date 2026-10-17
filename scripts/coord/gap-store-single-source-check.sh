#!/usr/bin/env bash
# gap-store-single-source-check.sh — assert ONE source of truth for the gap store.
#
# WHY THIS EXISTS ([[gap-store-split-brain-swamp]] / RESILIENT-1057):
#   The fleet's gap registry has three representations:
#     1. sqlite  .chump/state.db   — THE canonical store (what the CLI + workers
#                                     actually read/write).
#     2. YAML    docs/gaps/*.yaml  — a DERIVED git mirror, reconciled by
#                                     `chump gap sync` / gap-doctor (drift here is
#                                     expected staleness, not a second truth).
#     3. postgrest shared_gaps     — a DORMANT future backend (INFRA-2092,
#                                     postgres-backend cargo feature, OFF by
#                                     default). Empty until a migration + backfill
#                                     lands. It must NEVER be silently treated as
#                                     canonical while it diverges from state.db.
#
#   The split-brain that cost us: postgrest was "configured" but broken
#   (permission denied to set role "chump_anon"), so the fleet silently ran on
#   sqlite while a second, empty store sat there looking authoritative. This
#   guard makes any such divergence LOUD instead of silent.
#
# CHECKS (exit non-zero on ANY split-brain):
#   C) RESOLVER AGREEMENT (INFRA-8190, Phase R R4 — the HARD gate): every
#      process class must resolve the SAME state.db:
#        - this shell's env              (chump_state_db, scripts/coord/lib/state-store.sh)
#        - pin-less (what worker.sh's `CHUMP_REPO=$REPO_ROOT chump ...` and
#          chump-fleet-server's `chump` subprocess at cwd=<repo> resolve when
#          nothing pins CHUMP_STATE_DB)
#        - node.env-sourced (what an interactive shell / an organ with
#          EnvironmentFile=node.env resolves)
#        - the chump binary itself (`chump gap store-path`), pinned and pin-less
#      Any disagreement -> FAIL. This is the check that would have caught the
#      2026-10-15 cuphead split (CLI ~/.chump 8264 gaps vs API+workers
#      <repo>/.chump 465 gaps): A) below could never see it, because the CLI
#      and the sqlite3 probe both inherited the same CHUMP_STATE_DB.
#   A) CLI open-count == sqlite open-count           (CLI and store agree)
#   B) if a postgrest gap store is reachable AND non-empty AND its open-count
#      diverges from state.db  -> FAIL (a real second store is diverging).
#      (unreachable / empty postgrest == expected dormant state == OK)
#
# Flags: --resolver-only  run only check C (no sqlite3, no network; CI uses it).
#
# Receipts on stdout. Designed to be run by hand or by a scheduled organ.
set -uo pipefail

RESOLVER_ONLY=0
for _a in "$@"; do
  case "$_a" in
    --resolver-only) RESOLVER_ONLY=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
  esac
done

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=lib/state-store.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/state-store.sh"
STATE_DB="$(chump_state_db "$REPO_ROOT")"
CHUMP_BIN="${CHUMP_BIN:-$(command -v chump || echo chump)}"
NODE_ENV_FILE="${CHUMP_NODE_ENV_FILE:-${CHUMP_STATE_DIR:-$HOME/.chump}/node.env}"
# Dormant postgrest store; only checked if reachable. Same var the substrate
# installer and node-install env-pin resolve (INFRA-3634).
GAP_STORE_URL="${CHUMP_GAP_STORE_URL:-http://100.90.52.126:3000}"

fail=0
say() { printf '[gap-store-single-source] %s\n' "$*"; }

# Normalize a path whose leaf may not exist yet: realpath(dirname)/basename.
_norm() {
  local p="$1" d b
  d="$(dirname "$p")"; b="$(basename "$p")"
  if d="$(cd "$d" 2>/dev/null && pwd -P)"; then printf '%s/%s\n' "$d" "$b"; else printf '%s\n' "$p"; fi
}

# ---- C) resolver agreement (INFRA-8190 hard gate) ----
declare -a _c_names=() _c_paths=()
_c_add() { _c_names+=("$1"); _c_paths+=("$(_norm "$2")"); }
_c_add "shell(current env)" "$STATE_DB"
_c_add "pin-less(worker.sh / fleet-server)" "$(unset CHUMP_STATE_DB; chump_state_db "$REPO_ROOT" 2>/dev/null)"
if [[ -f "$NODE_ENV_FILE" ]]; then
  _c_add "node.env($NODE_ENV_FILE)" "$(unset CHUMP_STATE_DB; set +u; . "$NODE_ENV_FILE" >/dev/null 2>&1; chump_state_db "$REPO_ROOT" 2>/dev/null)"
else
  say "info(C): no node.env at $NODE_ENV_FILE — skipping the node.env-sourced resolution"
fi
_cli_store_path() {  # $1 = pinned|pinless
  if [[ "$1" == pinless ]]; then
    (cd "$REPO_ROOT" && env -u CHUMP_STATE_DB CHUMP_REPO="$REPO_ROOT" "$CHUMP_BIN" gap store-path 2>/dev/null)
  else
    (cd "$REPO_ROOT" && CHUMP_REPO="$REPO_ROOT" "$CHUMP_BIN" gap store-path 2>/dev/null)
  fi
}
if _cli_out="$(_cli_store_path pinned)" && [[ "$_cli_out" == /* ]]; then
  _c_add "chump gap store-path(current env)" "$(printf '%s' "$_cli_out" | head -1)"
  if _cli_out2="$(_cli_store_path pinless)" && [[ "$_cli_out2" == /* ]]; then
    _c_add "chump gap store-path(pin-less)" "$(printf '%s' "$_cli_out2" | head -1)"
  fi
else
  say "WARN(C): $CHUMP_BIN has no 'gap store-path' (pre-INFRA-8190 binary) — binary resolution not compared"
fi
_c_ref="${_c_paths[0]}"; _c_split=0
for _i in "${!_c_paths[@]}"; do
  say "resolver(C) ${_c_names[$_i]} -> ${_c_paths[$_i]}"
  [[ "${_c_paths[$_i]}" == "$_c_ref" ]] || _c_split=1
done
if [[ "$_c_split" -ne 0 ]]; then
  say "FAIL(C): processes resolve DIFFERENT gap stores — split-brain (fix: pin CHUMP_STATE_DB in node.env to the repo-local store, or unset it; see INFRA-8190)"
  fail=1
else
  say "OK(C): all ${#_c_paths[@]} resolutions agree on $_c_ref"
fi

if [[ "$RESOLVER_ONLY" -eq 1 ]]; then
  if [[ "$fail" -ne 0 ]]; then say "RESULT: SPLIT-BRAIN DETECTED"; exit 1; fi
  say "RESULT: one gap-store resolution confirmed ($_c_ref)"
  exit 0
fi

# ---- A) CLI vs sqlite ----
if [[ ! -f "$STATE_DB" ]]; then
  say "FAIL: canonical store $STATE_DB missing"; exit 2
fi
sqlite_open="$(sqlite3 "$STATE_DB" 'SELECT count(*) FROM gaps WHERE status="open";' 2>/dev/null)"
# CLI prints: "--- 1945 shown / 1946 total open across N domains ..."
cli_line="$("$CHUMP_BIN" gap list --status open 2>/dev/null | grep -oE '[0-9]+ total open' | head -1)"
cli_open="${cli_line%% *}"
say "canonical(sqlite state.db) open = ${sqlite_open:-<none>}"
say "CLI (chump gap list)      open = ${cli_open:-<none>}"
if [[ -z "$sqlite_open" || -z "$cli_open" ]]; then
  say "FAIL(A): could not read one of the counts"; fail=1
elif [[ "$sqlite_open" != "$cli_open" ]]; then
  say "FAIL(A): CLI and canonical store DISAGREE ($cli_open vs $sqlite_open) — split-brain between CLI and store"; fail=1
else
  say "OK(A): CLI and canonical store agree ($sqlite_open open)"
fi

# ---- B) dormant postgrest must not silently diverge ----
pg_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$GAP_STORE_URL/shared_gaps?select=id&limit=1" 2>/dev/null)"
if [[ "$pg_code" == "200" ]]; then
  pg_count="$(curl -s -m 8 -H 'Prefer: count=exact' -D - -o /dev/null "$GAP_STORE_URL/shared_gaps?select=id" 2>/dev/null | grep -i content-range | grep -oE '/[0-9]+' | tr -d '/')"
  pg_count="${pg_count:-0}"
  say "postgrest(shared_gaps) reachable, rows = $pg_count (dormant backend)"
  if [[ "$pg_count" != "0" && "$pg_count" != "$sqlite_open" ]]; then
    say "FAIL(B): postgrest store is NON-EMPTY ($pg_count) and diverges from canonical ($sqlite_open) — second store diverging. Either finish the INFRA-2092 migration (backfill+wire) or clear shared_gaps."; fail=1
  else
    say "OK(B): postgrest is dormant (empty) — not a competing source of truth"
  fi
elif [[ "$pg_code" == "000" ]]; then
  say "OK(B): postgrest unreachable — dormant, not a competing source of truth"
else
  say "OK(B): postgrest returned HTTP $pg_code (not serving gaps) — dormant"
fi

if [[ "$fail" -ne 0 ]]; then
  say "RESULT: SPLIT-BRAIN DETECTED"; exit 1
fi
say "RESULT: single source of truth confirmed (sqlite state.db)"
exit 0
