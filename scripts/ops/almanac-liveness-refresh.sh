#!/usr/bin/env bash
# scripts/ops/almanac-liveness-refresh.sh — INFRA-3643 (TREK-17)
#
# WHY THIS EXISTS. scripts/ops/almanac-summarize-watchdog.sh (RESILIENT-354) is
# a launchd-only supervisor — it heals the almanac summarize driver and pages
# on coverage-drop, but ONLY on macOS. The Linux owned-node factory (CJ,
# INFRA-3642) has no almanac liveness/refresh organ at all: a missing or
# stale `almanac` binary on CJ silently degrades fusion search to
# keyword-only with nothing watching for it, the same "designed but never
# wired into the revivable gate" blind spot RESILIENT-366's roll-call test
# exists to catch for systemd timers generally.
#
# This is the systemd-side complement (not a port of the macOS coverage-page
# path — that stays launchd/summarize-driver-specific): it covers the three
# things a Linux factory node actually needs locally —
#
#   1. BINARY PRESENCE — is `almanac` on PATH / at the expected install dir?
#      If not, build it from the tracked almanac checkout (best-effort,
#      mirrors node-refresh-chump.sh's "build from repo" fallback) so a fresh
#      CJ clone doesn't sit with a permanently-missing binary.
#   2. INDEX FRESHNESS — is the last-indexed commit marker (written by
#      scripts/dev/almanac-refresh-guard.py) within the staleness floor of
#      wall-clock time? A marker older than the floor means the refresh loop
#      itself has stopped running, even if rc=0 on its last real cycle.
#   3. FLEET INDEX EMPTY/STALE (INFRA-3639/TREK-14) — is `almanac stats`
#      actually reporting indexed files, and is scripts/ops/index-almanac.sh's
#      own fleet-wide-sweep marker fresh? Both (1) and (2) above can read
#      "healthy" while the fleet index is completely empty, because
#      index-almanac.sh is a SEPARATE organ installed by
#      scripts/setup/install-index-almanac-timer.sh — on a node where that
#      installer was never run, nothing ever reindexes the fleet repos. This
#      organ drives index-almanac.sh itself when the index is empty or its
#      sweep marker is stale/missing, so that blind spot self-heals.
#
# Usage:
#   scripts/ops/almanac-liveness-refresh.sh              # scan + heal
#   scripts/ops/almanac-liveness-refresh.sh --dry-run     # report only
#
# Env:
#   CHUMP_ALMANAC_BIN            — path to the almanac binary
#                                   (default: $HOME/Projects/almanac/target/release/almanac)
#   CHUMP_ALMANAC_REPO           — path to the almanac source checkout whose
#                                   git origin the builder tracks (INFRA-8038 builds
#                                   from a dedicated ~/.almanac/almanac-build-src clone
#                                   pinned to origin/main) (default: $HOME/Projects/almanac)
#   CHUMP_ALMANAC_MARKER         — path to the last-indexed-commit marker file
#                                   written by almanac-refresh-guard.py
#                                   (default: $HOME/Projects/almanac.last-indexed-commit)
#   CHUMP_ALMANAC_STALE_FLOOR_S  — max marker age in seconds before flagged
#                                   stale (default 86400 = 24h)
#   CHUMP_ALMANAC_HEALTH_REPO    — repo slug/path passed to `almanac stats` for
#                                   the almanac_health probe's indexed_files
#                                   count (default: chump)
#   CHUMP_ALMANAC_MCP_BIN        — path to the almanac-mcp binary probed for
#                                   mcp_reachable (default: sibling of
#                                   CHUMP_ALMANAC_BIN, almanac-mcp)
#   CHUMP_ALMANAC_FLEET_INDEX_MARKER — path to index-almanac.sh's own sweep
#                                   marker (default: $HOME/.almanac/fleet-index.last);
#                                   missing/stale (>STALE_FLOOR_S) or
#                                   indexed_files==0 triggers index-almanac.sh
#   CHUMP_AMBIENT_LOG            — override ambient.jsonl path
#
# Exit codes:
#   0  normal (whether or not anything needed healing)
#   1  internal failure only (never for "binary absent, build failed" — that's
#      logged and left for the next cycle, same non-fatal posture as
#      almanac-summarize-watchdog.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

ALMANAC_REPO="${CHUMP_ALMANAC_REPO:-$HOME/Projects/almanac}"
ALMANAC_BIN="${CHUMP_ALMANAC_BIN:-$ALMANAC_REPO/target/release/almanac}"
MARKER="${CHUMP_ALMANAC_MARKER:-${ALMANAC_REPO}.last-indexed-commit}"
STALE_FLOOR_S="${CHUMP_ALMANAC_STALE_FLOOR_S:-86400}"
HEALTH_REPO="${CHUMP_ALMANAC_HEALTH_REPO:-chump}"
MCP_BIN="${CHUMP_ALMANAC_MCP_BIN:-$(dirname "$ALMANAC_BIN")/almanac-mcp}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── 1. Binary freshness ──────────────────────────────────────────────────────
# INFRA-8038: keep the index-builder BINARY current, not merely present. The old
# logic built ONLY when the binary was absent (a present-but-stale binary lived
# forever), built --bin almanac ONLY (never the almanac-mcp server agents query),
# never pulled the source, and built from the WORKER checkout ($ALMANAC_REPO) —
# which fleet workers move onto feature branches — so a node could silently run
# months-old almanac. Fix: a DEDICATED build checkout that only ever tracks
# origin/main (nothing else touches it, so a hard reset is safe), rebuild BOTH
# bins whenever the built commit drifts from origin/main (stamped beside the
# binary), reusing the existing target dir so the rebuild is incremental and
# lands exactly where consumers already read it.
built=0
BUILD_SRC="$HOME/.almanac/almanac-build-src"
BIN_STAMP="${ALMANAC_BIN}.commit"
BIN_DIR="$(dirname "$ALMANAC_BIN")"
TARGET_DIR="$(dirname "$BIN_DIR")"
# Track whatever origin the node's almanac checkout uses (GitHub is canonical),
# falling back to the known canonical remote when there is no checkout.
ALMANAC_REMOTE="$(git -C "$ALMANAC_REPO" config --get remote.origin.url 2>/dev/null || echo "https://github.com/repairman29/almanac.git")"

want_commit=""
if command -v git >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
        [[ -d "$BUILD_SRC/.git" ]] || echo "[almanac-liveness-refresh]   (dry-run) would clone $ALMANAC_REMOTE -> $BUILD_SRC"
    elif [[ ! -d "$BUILD_SRC/.git" ]]; then
        git clone --quiet "$ALMANAC_REMOTE" "$BUILD_SRC" 2>/dev/null || true
    fi
    if [[ "$DRY_RUN" != "1" && -d "$BUILD_SRC/.git" ]]; then
        ( cd "$BUILD_SRC" \
            && git fetch --quiet origin main 2>/dev/null \
            && git reset --hard --quiet origin/main 2>/dev/null ) || true
    fi
    want_commit="$(git -C "$BUILD_SRC" rev-parse --short HEAD 2>/dev/null || true)"
fi

have_commit=""
[[ -f "$BIN_STAMP" ]] && have_commit="$(cat "$BIN_STAMP" 2>/dev/null || true)"

# Rebuild when a binary is missing OR the built commit has drifted from
# origin/main. With no stamp yet (first run after INFRA-8038) a present binary
# reads as drifted and is rebuilt once, which stamps it going forward.
build_reason=""
if [[ ! -x "$ALMANAC_BIN" || ! -x "$MCP_BIN" ]]; then
    build_reason="missing"
elif [[ -n "$want_commit" && "$want_commit" != "$have_commit" ]]; then
    build_reason="drift"
fi

if [[ -z "$build_reason" ]]; then
    echo "[almanac-liveness-refresh] binary current: $ALMANAC_BIN @ ${have_commit:-unknown}"
elif [[ "$DRY_RUN" == "1" ]]; then
    echo "[almanac-liveness-refresh]   (dry-run) would rebuild ($build_reason): ${have_commit:-none} -> ${want_commit:-?}"
elif [[ -d "$BUILD_SRC/.git" ]]; then
    if ( cd "$BUILD_SRC" && CARGO_TARGET_DIR="$TARGET_DIR" cargo build --release --bin almanac --bin almanac-mcp ) >/dev/null 2>&1; then
        printf '%s\n' "$want_commit" > "$BIN_STAMP" 2>/dev/null || true
        echo "[almanac-liveness-refresh]   rebuilt ($build_reason): ${have_commit:-none} -> ${want_commit}"
        if [[ "$build_reason" == "drift" ]]; then
            # scanner-anchor: "kind":"almanac_liveness_binary_rebuilt"  (INFRA-8038;
            # fires when a PRESENT binary was stale vs origin/main and got rebuilt
            # — the exact drift the old absent-only build logic silently missed)
            emit almanac_liveness_binary_rebuilt "\"from\":\"${have_commit:-none}\",\"to\":\"$want_commit\""
        else
            # scanner-anchor: "kind":"almanac_liveness_binary_built"  (INFRA-3643;
            # fires when the systemd organ finds the almanac binary missing on
            # a Linux factory node and builds it from the tracked checkout)
            emit almanac_liveness_binary_built "\"repo\":\"$BUILD_SRC\""
        fi
        built=1
    else
        echo "[almanac-liveness-refresh]   WARN: build failed (non-fatal; retried next cycle)" >&2
        # scanner-anchor: "kind":"almanac_liveness_binary_build_failed"
        emit almanac_liveness_binary_build_failed "\"repo\":\"$BUILD_SRC\""
    fi
else
    echo "[almanac-liveness-refresh]   SKIP: no build checkout at $BUILD_SRC or no git/cargo on PATH"
fi

# ── 2. Index freshness ───────────────────────────────────────────────────────
stale=0
marker_age=""
if [[ -f "$MARKER" ]]; then
    marker_mtime="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER" 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    marker_age=$(( now_epoch - marker_mtime ))
    if (( marker_age > STALE_FLOOR_S )); then
        stale=1
        echo "[almanac-liveness-refresh] STALE: index marker is ${marker_age}s old (floor ${STALE_FLOOR_S}s)"
        # scanner-anchor: "kind":"almanac_liveness_index_stale"  (INFRA-3643;
        # fires when the last-indexed-commit marker is older than the
        # staleness floor — the refresh loop itself has stopped moving, even
        # if its last real cycle exited 0)
        emit almanac_liveness_index_stale "\"marker\":\"$MARKER\",\"age_s\":$marker_age,\"floor_s\":$STALE_FLOOR_S,\"dry_run\":$DRY_RUN"
    else
        echo "[almanac-liveness-refresh] index fresh: marker is ${marker_age}s old (floor ${STALE_FLOOR_S}s)"
    fi
else
    echo "[almanac-liveness-refresh] no marker at $MARKER — nothing indexed yet on this node (skip)"
fi

# ── 3. almanac_health probe (INFRA-3638/TREK-13) ────────────────────────────
# Measurable "eyes-alive" signal: is the binary present, is the index
# populated, and is the index fresh — every liveness cycle, not just on
# binary-missing / marker-stale transitions (those two conditions above are
# edge-triggered; this is the level-triggered heartbeat a dashboard can plot).
binary_present=0
[[ -x "$ALMANAC_BIN" ]] && binary_present=1

indexed_files=0
if [[ "$binary_present" == "1" ]] && command -v timeout >/dev/null 2>&1; then
    stats_out="$(timeout 10 "$ALMANAC_BIN" stats "$HEALTH_REPO" 2>/dev/null || true)"
    files_line="$(printf '%s\n' "$stats_out" | awk '/^files:/{print $2}')"
    [[ "$files_line" =~ ^[0-9]+$ ]] && indexed_files="$files_line"
fi

# ── 2b. Fleet reindex (empty or stale index) ─────────────────────────────────
# INFRA-3639 (TREK-14): a present, healthy binary with an EMPTY index is the
# exact "tonight-blindness" this gap exists to fix. Section 2 above only ever
# watched almanac's OWN self-index marker — it never drove
# scripts/ops/index-almanac.sh (the actual fleet-repo reindex sweep), which
# is a separate organ installed by scripts/setup/install-index-almanac-timer.sh.
# On any factory node where that installer was never run, indexed_files
# silently stays 0 forever: this liveness organ reports "healthy" every cycle
# while the index behind it is completely empty. Trigger the sweep directly
# here so an empty/stale fleet index self-heals even if its own installer
# step was skipped.
reindexed=0
INDEX_SCRIPT="$SCRIPT_DIR/index-almanac.sh"
FLEET_INDEX_MARKER="${CHUMP_ALMANAC_FLEET_INDEX_MARKER:-$HOME/.almanac/fleet-index.last}"
fleet_marker_age=""
if [[ -f "$FLEET_INDEX_MARKER" ]]; then
    fleet_mtime="$(stat -c %Y "$FLEET_INDEX_MARKER" 2>/dev/null || stat -f %m "$FLEET_INDEX_MARKER" 2>/dev/null || echo 0)"
    fleet_marker_age=$(( $(date -u +%s) - fleet_mtime ))
fi
needs_fleet_reindex=0
if [[ "$binary_present" == "1" ]]; then
    if [[ "$indexed_files" == "0" ]]; then
        needs_fleet_reindex=1
    elif [[ -z "$fleet_marker_age" ]]; then
        needs_fleet_reindex=1
    elif (( fleet_marker_age > STALE_FLOOR_S )); then
        needs_fleet_reindex=1
    fi
fi

if [[ "$needs_fleet_reindex" == "1" && -x "$INDEX_SCRIPT" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[almanac-liveness-refresh]   (dry-run) would trigger fleet reindex: $INDEX_SCRIPT"
    else
        echo "[almanac-liveness-refresh]   index empty/stale (indexed_files=$indexed_files fleet_marker_age=${fleet_marker_age:-none}) — triggering fleet reindex"
        if CHUMP_REPO_ROOT="$REPO_ROOT" ALMANAC_BIN="$ALMANAC_BIN" ALMANAC_INDEX_MARKER="$FLEET_INDEX_MARKER" "$INDEX_SCRIPT" >/tmp/almanac-liveness-reindex.log 2>&1; then
            reindexed=1
            # scanner-anchor: "kind":"almanac_liveness_reindex_triggered"  (INFRA-3639;
            # fires when this organ found an empty/stale fleet index and drove
            # scripts/ops/index-almanac.sh itself rather than waiting on a
            # separate hourly organ that may never have been installed)
            emit almanac_liveness_reindex_triggered "\"indexed_files_before\":$indexed_files,\"fleet_marker_age_s\":${fleet_marker_age:-null}"
            # re-probe so the almanac_health line below shows the before/after
            # recovery in the same cycle
            if command -v timeout >/dev/null 2>&1; then
                stats_out="$(timeout 10 "$ALMANAC_BIN" stats "$HEALTH_REPO" 2>/dev/null || true)"
                files_line="$(printf '%s\n' "$stats_out" | awk '/^files:/{print $2}')"
                [[ "$files_line" =~ ^[0-9]+$ ]] && indexed_files="$files_line"
            fi
        else
            echo "[almanac-liveness-refresh]   WARN: fleet reindex failed (non-fatal; retried next cycle); see /tmp/almanac-liveness-reindex.log" >&2
            # scanner-anchor: "kind":"almanac_liveness_reindex_failed"
            emit almanac_liveness_reindex_failed "\"indexed_files\":$indexed_files"
        fi
    fi
fi

last_index_age_s="${marker_age:-null}"

mcp_reachable=0
[[ -x "$MCP_BIN" ]] && mcp_reachable=1

echo "[almanac-liveness-refresh] health: binary_present=$binary_present indexed_files=$indexed_files last_index_age_s=$last_index_age_s mcp_reachable=$mcp_reachable"
# scanner-anchor: "kind":"almanac_health"  (INFRA-3638/TREK-13; measurable
# eyes-alive probe emitted every liveness cycle — binary presence, indexed
# file count, index freshness, and almanac-mcp binary reachability)
emit almanac_health "\"indexed_files\":$indexed_files,\"last_index_age_s\":$last_index_age_s,\"binary_present\":$([[ $binary_present == 1 ]] && echo true || echo false),\"mcp_reachable\":$([[ $mcp_reachable == 1 ]] && echo true || echo false)"

# Heartbeat — always emit so a dead unit is itself observable via ambient.jsonl.
# scanner-anchor: "kind":"almanac_liveness_refresh_tick"  (INFRA-3643; emitted
# every cycle, success or no-op — proof the systemd organ itself is alive)
emit almanac_liveness_refresh_tick "\"built\":$built,\"stale\":$stale,\"marker_age_s\":${marker_age:-null},\"reindexed\":$reindexed,\"dry_run\":$DRY_RUN"

echo "[almanac-liveness-refresh] cycle complete: built=$built stale=$stale marker_age_s=${marker_age:-n/a} reindexed=$reindexed dry_run=$DRY_RUN"
exit 0
