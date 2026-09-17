#!/usr/bin/env bash
# scripts/ops/fleet-clone-index.sh — RESILIENT-1351
#
# WHY THIS EXISTS. scripts/ops/index-almanac.sh (RESILIENT-404) reindexes the
# LOCAL git checkouts under $HOME/Projects — but on the factory node (CJ) only
# chump + almanac are checked out there, so almanac (the fleet's mine-before-
# build code memory) saw 2 of ~109 repairman29 repos and cross-repo search was
# effectively BLIND fleet-wide. Decision 2026-09-17: CJ is the canonical almanac
# home. This sweep gives almanac the WHOLE org WITHOUT a 109-repo standing
# checkout, and without ever touching the shared fleet worktree.
#
# WHAT IT DOES (extends the existing almanac index infra — index/untether/refresh
# are almanac's own primitives; this is the org-clone orchestrator around them,
# not a parallel indexer):
#   1. `gh repo list <org>` — the authoritative repo set (picks up NEW org repos
#      every cycle, which `almanac refresh` alone never discovers).
#   2. For each repo NOT already registered: a shallow, single-branch clone
#      (--depth 1, NO history) into a DEDICATED cache tree (never the shared
#      fleet worktree — that races the workers' git lock), then `almanac index`
#      (pure AST, NO embeds — plain index gives the file:line receipts that ARE
#      mine-before-build; embed/summarize is a separate, deferred subcommand),
#      then `almanac untether --drop-worktree` so the INDEX is kept and the
#      SOURCE is dropped. Standing disk = indexes only, not 109 worktrees.
#   3. `almanac refresh` — ls-remote-probes every untethered clone (~0.7s, zero
#      disk) and re-materializes a throwaway shallow clone ONLY when the origin
#      sha actually moved, re-indexes, and drops again. This is the disk-safe
#      equivalent of the per-cycle `git fetch --depth 1 && reset --hard` the
#      gap describes.
#
# ⛔ DISK SAFETY (CJ is the coordinator; filling its disk breaks the WHOLE fleet):
#   - A hard floor of ALMANAC_DISK_FLOOR_GB (default 5 GB, the fleet-doctor
#     threshold) free on the index mount, re-checked BEFORE every clone.
#   - On breach: STOP cloning, KEEP what already indexed, emit an escalation
#     event with exact numbers (cloned X of N, GB free), and exit 0 with a
#     PARTIAL index. A partial index that keeps CJ healthy beats a full one
#     that wedges the coordinator.
#   - Clone/index failures (private, archived, huge, transient) are skipped +
#     logged, never fatal — one broken repo must not blind the rest of the fleet.
#
# Runs niced/ioniced so it never fights the coordinator/workers.
#
# Usage:
#   scripts/ops/fleet-clone-index.sh                 # full org sweep
#   scripts/ops/fleet-clone-index.sh --dry-run       # list + disk-check, no clone/index
#   scripts/ops/fleet-clone-index.sh --limit 10      # cap new clones this run (partial/testing)
#   scripts/ops/fleet-clone-index.sh --no-refresh    # skip the trailing `almanac refresh`
#
# Env overrides:
#   ALMANAC_BIN            almanac CLI (default: $HOME/Projects/almanac/target/release/almanac,
#                          else `command -v almanac`)
#   CHUMP_FLEET_ORG        GitHub org/owner to sweep (default: repairman29)
#   ALMANAC_REPO_CACHE     dedicated shallow-clone tree (default: $HOME/.almanac/repos-cache)
#   ALMANAC_DISK_FLOOR_GB  hard free-space floor in GB on the index mount (default: 5)
#   ALMANAC_MAX_REPOS      gh repo list --limit (default: 300)
#   ALMANAC_HOME           almanac data home (default: $HOME/.almanac)
#   CHUMP_REPO_ROOT        chump checkout whose ambient.jsonl to emit to
#   ALMANAC_CLONE_MARKER   "last full org sweep" marker (default: $ALMANAC_HOME/fleet-clone-index.last)
#   ALMANAC_CLONE_LOG      human-readable run log (default: $ALMANAC_HOME/fleet-clone-index.log)
#
# Exit codes:
#   0  sweep ran to completion OR stopped cleanly at the disk floor (partial).
#   1  almanac CLI absent, gh absent/unauthed, or zero repos discovered.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

ALMANAC_HOME="${ALMANAC_HOME:-$HOME/.almanac}"
ALMANAC_REPO_DEFAULT="$HOME/Projects/almanac"
ALMANAC_BIN="${ALMANAC_BIN:-$ALMANAC_REPO_DEFAULT/target/release/almanac}"
[ -x "$ALMANAC_BIN" ] || ALMANAC_BIN="$(command -v almanac 2>/dev/null || echo "$ALMANAC_BIN")"
CHUMP_FLEET_ORG="${CHUMP_FLEET_ORG:-repairman29}"
ALMANAC_REPO_CACHE="${ALMANAC_REPO_CACHE:-$ALMANAC_HOME/repos-cache}"
ALMANAC_DISK_FLOOR_GB="${ALMANAC_DISK_FLOOR_GB:-5}"
ALMANAC_MAX_REPOS="${ALMANAC_MAX_REPOS:-300}"
ALMANAC_CLONE_MARKER="${ALMANAC_CLONE_MARKER:-$ALMANAC_HOME/fleet-clone-index.last}"
ALMANAC_CLONE_LOG="${ALMANAC_CLONE_LOG:-$ALMANAC_HOME/fleet-clone-index.log}"

DRY_RUN=0
DO_REFRESH=1
LIMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-refresh) DO_REFRESH=0 ;;
    --limit) shift; LIMIT="${1:-0}" ;;
    --limit=*) LIMIT="${1#*=}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$ALMANAC_REPO_CACHE" "$(dirname "$ALMANAC_CLONE_MARKER")" "$(dirname "$ALMANAC_CLONE_LOG")" 2>/dev/null || true
export ALMANAC_HOME

# nice/ionice prefixes so the sweep yields to the coordinator/workers.
NICE=""; command -v nice   >/dev/null 2>&1 && NICE="nice -n 19"
IONICE="";command -v ionice >/dev/null 2>&1 && IONICE="ionice -c3"
LOW="$NICE $IONICE"

emit() {  # kind extra_json
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [ -n "$extra" ]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

log() {
    local msg="[fleet-clone-index] $*"
    echo "$msg"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$ALMANAC_CLONE_LOG" 2>/dev/null || true
}

# free GB on the mount that holds the index cache (POSIX df, portable).
free_gb() {
    df -Pk "$ALMANAC_REPO_CACHE" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'
}

# ---------- preflight ----------
if [ ! -x "$ALMANAC_BIN" ]; then
    log "FAIL: almanac binary not found/executable at $ALMANAC_BIN"
    # scanner-anchor: "kind":"almanac_fleet_clone_no_binary"  (RESILIENT-1351)
    emit almanac_fleet_clone_no_binary "\"bin\":\"$ALMANAC_BIN\""
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    log "FAIL: gh CLI not found — cannot enumerate the org"
    # scanner-anchor: "kind":"almanac_fleet_clone_no_gh"  (RESILIENT-1351)
    emit almanac_fleet_clone_no_gh "\"reason\":\"gh_missing\""
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    log "FAIL: gh not authenticated — cannot enumerate the org"
    emit almanac_fleet_clone_no_gh "\"reason\":\"gh_unauthed\""
    exit 1
fi

# ---------- enumerate the org ----------
mapfile -t ORG_REPOS < <(gh repo list "$CHUMP_FLEET_ORG" --limit "$ALMANAC_MAX_REPOS" --json name --jq '.[].name' 2>/dev/null | sort)
ORG_COUNT="${#ORG_REPOS[@]}"
if [ "$ORG_COUNT" -eq 0 ]; then
    log "FAIL: gh repo list returned 0 repos for org '$CHUMP_FLEET_ORG'"
    exit 1
fi

# repos already registered in the almanac index (by slug, first column) — skip
# them (their INDEX is kept; `almanac refresh` freshens them at the end).
registered="$($LOW "$ALMANAC_BIN" repos 2>/dev/null | awk 'NR>1{print $1}')"

slugify() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/-+/-/g; s/^-|-$//g'; }

START_FREE="$(free_gb)"
log "org '$CHUMP_FLEET_ORG': $ORG_COUNT repo(s); cache=$ALMANAC_REPO_CACHE; free=${START_FREE}GB; floor=${ALMANAC_DISK_FLOOR_GB}GB; dry_run=$DRY_RUN; limit=$LIMIT"
# scanner-anchor: "kind":"almanac_fleet_clone_started"  (RESILIENT-1351)
emit almanac_fleet_clone_started "\"org\":\"$CHUMP_FLEET_ORG\",\"repo_count\":$ORG_COUNT,\"free_gb\":${START_FREE:-0},\"floor_gb\":$ALMANAC_DISK_FLOOR_GB,\"dry_run\":$DRY_RUN"

OK=0; SKIP=0; FAIL=0; NEW=0
DISK_STOP=0; DISK_STOP_REPO=""

for name in "${ORG_REPOS[@]}"; do
    [ -z "$name" ] && continue
    slug="$(slugify "$name")"

    # already indexed → skip clone; refresh handles freshness.
    if echo "$registered" | grep -qx "$slug"; then
        SKIP=$((SKIP + 1))
        continue
    fi

    # per-run cap on NEW clones (partial/testing).
    if [ "$LIMIT" -gt 0 ] && [ "$NEW" -ge "$LIMIT" ]; then
        log "limit $LIMIT reached — stopping new clones (remaining repos will be picked up next sweep)"
        break
    fi

    # ⛔ disk floor check BEFORE every clone.
    cur_free="$(free_gb)"
    if [ -z "$cur_free" ]; then cur_free=0; fi
    if [ "$cur_free" -lt "$ALMANAC_DISK_FLOOR_GB" ]; then
        DISK_STOP=1; DISK_STOP_REPO="$name"
        log "⛔ DISK FLOOR: ${cur_free}GB free < ${ALMANAC_DISK_FLOOR_GB}GB floor before cloning '$name' — STOPPING (partial index kept)"
        break
    fi

    if [ "$DRY_RUN" = 1 ]; then
        log "DRY: would clone+index+untether $name (slug=$slug), free=${cur_free}GB"
        NEW=$((NEW + 1))
        continue
    fi

    dir="$ALMANAC_REPO_CACHE/$name"
    rm -rf "$dir" 2>/dev/null || true   # never reuse a half-clone from a prior crash

    # shallow, single-branch, no history. gh clone uses the authed HTTPS token.
    if ! $LOW gh repo clone "$CHUMP_FLEET_ORG/$name" "$dir" -- --depth 1 --single-branch --no-tags --quiet >>"$ALMANAC_CLONE_LOG" 2>&1; then
        FAIL=$((FAIL + 1))
        log "SKIP: clone failed for $name (private/archived/transient) — see $ALMANAC_CLONE_LOG"
        # scanner-anchor: "kind":"almanac_fleet_clone_repo_failed"  (RESILIENT-1351)
        emit almanac_fleet_clone_repo_failed "\"repo\":\"$name\",\"stage\":\"clone\""
        rm -rf "$dir" 2>/dev/null || true
        continue
    fi

    # pure-AST index (no embeds) into the canonical CJ index.
    if ! $LOW "$ALMANAC_BIN" index "$dir" >>"$ALMANAC_CLONE_LOG" 2>&1; then
        FAIL=$((FAIL + 1))
        log "SKIP: index failed for $name — see $ALMANAC_CLONE_LOG"
        emit almanac_fleet_clone_repo_failed "\"repo\":\"$name\",\"stage\":\"index\""
        rm -rf "$dir" 2>/dev/null || true
        continue
    fi

    # keep the INDEX, drop the SOURCE — standing disk = indexes only.
    if ! $LOW "$ALMANAC_BIN" untether "$slug" --drop-worktree >>"$ALMANAC_CLONE_LOG" 2>&1; then
        # index landed but worktree not dropped — reclaim disk directly so a
        # failed untether can't leave 100+ worktrees on the coordinator.
        rm -rf "$dir" 2>/dev/null || true
        log "WARN: untether reported non-zero for $name; worktree removed manually (index kept)"
    fi

    OK=$((OK + 1)); NEW=$((NEW + 1))
    log "OK: indexed + untethered $name (slug=$slug)"
done

# ---------- trailing freshness sweep (the disk-safe per-cycle refresh) ----------
if [ "$DRY_RUN" = 0 ] && [ "$DO_REFRESH" = 1 ] && [ "$DISK_STOP" = 0 ]; then
    log "refresh: ls-remote-probing all registered repos (re-materialize only on sha move)"
    $LOW "$ALMANAC_BIN" refresh >>"$ALMANAC_CLONE_LOG" 2>&1 || log "WARN: almanac refresh reported non-zero (see log)"
fi

END_FREE="$(free_gb)"; [ -z "$END_FREE" ] && END_FREE=0
TOTAL_REGISTERED="$($LOW "$ALMANAC_BIN" repos 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)"

if [ "$DRY_RUN" = 1 ]; then
    log "dry-run complete: $NEW repo(s) would be newly cloned/indexed, $SKIP already-registered"
    exit 0
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$ALMANAC_CLONE_MARKER" 2>/dev/null || true

if [ "$DISK_STOP" = 1 ]; then
    log "⚠️ PARTIAL: stopped at disk floor. newly-indexed=$OK, failed=$FAIL, already-registered=$SKIP, org=$ORG_COUNT, free=${END_FREE}GB (floor ${ALMANAC_DISK_FLOOR_GB}GB), stopped-before='$DISK_STOP_REPO'"
    # scanner-anchor: "kind":"almanac_fleet_clone_disk_floor"  (RESILIENT-1351;
    # ESCALATION — the coordinator's disk cannot hold the full org index; this
    # is the "needs a dedicated indexer box" signal feeding the Oracle rethink)
    emit almanac_fleet_clone_disk_floor "\"org\":\"$CHUMP_FLEET_ORG\",\"org_count\":$ORG_COUNT,\"newly_indexed\":$OK,\"already_registered\":$SKIP,\"free_gb\":$END_FREE,\"floor_gb\":$ALMANAC_DISK_FLOOR_GB,\"stopped_before\":\"$DISK_STOP_REPO\""
else
    log "sweep complete: newly-indexed=$OK, failed=$FAIL, already-registered=$SKIP, org=$ORG_COUNT, total-registered=${TOTAL_REGISTERED:-?}, free=${START_FREE}GB→${END_FREE}GB"
fi

# scanner-anchor: "kind":"almanac_fleet_clone_completed"  (RESILIENT-1351)
emit almanac_fleet_clone_completed "\"org\":\"$CHUMP_FLEET_ORG\",\"org_count\":$ORG_COUNT,\"newly_indexed\":$OK,\"failed\":$FAIL,\"already_registered\":$SKIP,\"total_registered\":${TOTAL_REGISTERED:-0},\"free_gb\":$END_FREE,\"disk_stop\":$DISK_STOP"

exit 0
