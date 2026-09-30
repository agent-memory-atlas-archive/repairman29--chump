#!/usr/bin/env bash
# scripts/coord/disk-pressure-reaper.sh — INFRA-1471
#
# Pressure-tiered worktree + artifact reaper. Escalates aggression as disk
# fills. Wraps INFRA-1349 target-dir-reaper and adds whole-worktree reap at
# higher pressure tiers.
#
# Pressure ladder (defaults; tunable via env):
#   ≥ 50 GB free → IDLE (no action)
#   20-50 GB    → Tier 1: target/ idle > 6h (delegates to target-dir-reaper) + git worktree prune
#   10-20 GB    → Tier 2: target/ idle > 2h + whole-worktree if PR merged + branch deleted + sccache reap if >5GB
#    5-10 GB    → Tier 3: whole-worktree idle > 30min, no active lease, no uncommitted edits + target/debug/incremental reap
#    < 5 GB     → Tier 4 (RED): emit ALERT, fall back to operator escalation per INFRA-1471
#
# Each tier is strictly safe: never deletes a worktree with uncommitted/
# unpushed work (per INFRA-1347 contract) or a live lease.
#
# Usage:
#   disk-pressure-reaper.sh                   # dry-run
#   disk-pressure-reaper.sh --execute         # actually delete
#   disk-pressure-reaper.sh --execute --tier 3 # force Tier 3 regardless of disk

set -uo pipefail
REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-/Users/jeffadkins/Projects/Chump}}"
TARGET_REAPER="$REPO_ROOT/scripts/coord/target-dir-reaper.sh"

# INFRA-1074: shared active-worktree guard (fresh lease heartbeat / git index /
# uncommitted / unpushed work) — protect in-flight worktrees from whole-worktree
# reaping, which destroys source + git state, not just reproducible build output.
source "$(dirname "$0")/lib/worktree-reaper-safety.sh"

DRY_RUN=1
TIER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) DRY_RUN=0; shift ;;
    --tier)    TIER_OVERRIDE="$2"; shift 2 ;;
    --help|-h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

ok()    { printf '\033[0;32m✓\033[0m  %s\n' "$*"; }
warn()  { printf '\033[0;33m⚠\033[0m  %s\n' "$*"; }
alert() { printf '\033[0;31m‼\033[0m  %s\n' "$*"; }
info()  { printf '\033[0;36m→\033[0m  %s\n' "$*"; }

# Detect disk free (macOS df -g format).
free_gb=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -z "$free_gb" ]]; then
  free_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
fi
free_gb="${free_gb:-999}"

# RESILIENT-1045: proactive, cap-based reap of the shared cargo build cache
# (~/.cargo/chump-shared-target). Runs unconditionally, even on the ≥50GB
# early-exit path below — the old reactive-only path (disk-critical-reactor's
# quiesce_and_reclaim) only ever touches this dir at tier-4 disk pressure, so
# the cache could grow past its own cap for weeks on a box that otherwise has
# plenty of headroom. Idle + no-active-build guarded; dry-run unless --execute.
SHARED_TARGET_REAPER="$REPO_ROOT/scripts/coord/shared-target-cache-reaper.sh"
if [[ -x "$SHARED_TARGET_REAPER" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    "$SHARED_TARGET_REAPER" 2>&1 | tail -3
  else
    "$SHARED_TARGET_REAPER" --execute 2>&1 | tail -3
  fi
fi

if [[ -n "$TIER_OVERRIDE" ]]; then
  tier="$TIER_OVERRIDE"
  info "tier $tier forced via --tier (disk free ${free_gb}GB)"
elif [[ "$free_gb" -ge 50 ]]; then
  ok "disk free ${free_gb}GB — idle (≥ 50GB threshold)"
  exit 0
elif [[ "$free_gb" -ge 20 ]]; then
  tier=1
elif [[ "$free_gb" -ge 10 ]]; then
  tier=2
elif [[ "$free_gb" -ge 5 ]]; then
  tier=3
else
  tier=4
fi

info "disk free ${free_gb}GB → tier $tier"

emit_ambient() {
  local payload="$1"
  if [[ -d "$REPO_ROOT/.chump-locks" ]]; then
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s",%s}\n' "$ts" "$payload" >> "$REPO_ROOT/.chump-locks/ambient.jsonl"
  fi
}

# ── Tier 1: target/ idle > 6h + git worktree prune ───────────────────────
SCCACHE_REAPER="$REPO_ROOT/scripts/coord/sccache-reaper.sh"
# INFRA-2188: cargo-target-reaper (ops) covers ~/.cache/chump-runner that target-dir-reaper misses.
CARGO_TARGET_REAPER_OPS="$REPO_ROOT/scripts/ops/cargo-target-reaper.sh"

if [[ "$tier" -ge 1 ]]; then
  info "tier $tier: delegate to target-dir-reaper (idle > 6h)"
  if [[ -x "$TARGET_REAPER" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      CHUMP_TARGET_REAPER_DISK_MIN_GB=$((free_gb + 100)) "$TARGET_REAPER" 2>&1 | tail -10
    else
      CHUMP_TARGET_REAPER_DISK_MIN_GB=$((free_gb + 100)) "$TARGET_REAPER" --execute --force 2>&1 | tail -10
    fi
  else
    warn "target-dir-reaper not found at $TARGET_REAPER"
  fi

  # Prune stale worktree registrations. Safe: only removes entries whose
  # backing dir is already gone; never deletes live dirs. INFRA-2303.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[DRY-RUN] would run: git worktree prune -v"
  else
    prune_out=$(git -C "$REPO_ROOT" worktree prune -v 2>&1 || true)
    prune_count=$(echo "$prune_out" | grep -c "^Removing" || true)
    if [[ "$prune_count" -gt 0 ]]; then
      ok "git worktree prune removed $prune_count stale entries"
      emit_ambient "\"kind\":\"git_worktree_pruned\",\"count\":${prune_count}"
    else
      ok "git worktree prune: no stale entries found"
    fi
  fi
fi

# ── Tier 2+: tighter idle window for target/, whole-worktree if PR merged ────
# INFRA-2188: sccache reap moved to AFTER all build-target reaping (see bottom of
# this tier block) so that the build accelerator is only touched when build-artifact
# reaping alone cannot free enough space. The old ordering reaped sccache mid-tier
# before whole-worktree reap, which caused cold-build cascades when disk recovered.
if [[ "$tier" -ge 2 ]]; then
  info "tier $tier: target/ idle > 2h + whole-worktree if PR merged & branch deleted"
  if [[ -x "$TARGET_REAPER" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      CHUMP_TARGET_REAPER_IDLE_H=2 CHUMP_TARGET_REAPER_DISK_MIN_GB=$((free_gb + 100)) \
        "$TARGET_REAPER" 2>&1 | tail -5
    else
      CHUMP_TARGET_REAPER_IDLE_H=2 CHUMP_TARGET_REAPER_DISK_MIN_GB=$((free_gb + 100)) \
        "$TARGET_REAPER" --execute --force 2>&1 | tail -5
    fi
  fi

  # INFRA-2188: also invoke ops/cargo-target-reaper which covers
  # ~/.cache/chump-runner/cargo-target (the 40-60GB runner path that
  # target-dir-reaper misses entirely).
  #
  # PRODUCT-256: this does NOT cover ~/.cargo/chump-shared-target (the
  # shared CARGO_TARGET_DIR most workers actually build into, 156G
  # observed 2026-08-09). That path is reaped separately by
  # shared-target-cache-reaper.sh, invoked unconditionally above at the
  # top of this script's every tick — see the RESILIENT-1045 block near
  # the top of this file.
  if [[ -x "$CARGO_TARGET_REAPER_OPS" ]]; then
    info "tier $tier: invoking ops/cargo-target-reaper (covers ~/.cache/chump-runner only; chump-shared-target reaped separately above)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      "$CARGO_TARGET_REAPER_OPS" 2>&1 | tail -5
    else
      "$CARGO_TARGET_REAPER_OPS" --execute 2>&1 | tail -5
    fi
  else
    warn "ops/cargo-target-reaper not found at $CARGO_TARGET_REAPER_OPS"
  fi

  # Whole-worktree reap when its branch is gone from remote (merged-and-deleted).
  scan_pattern="/private/tmp/chump-*"
  reaped_wt=0
  for wt in $scan_pattern; do
    [[ -d "$wt" ]] || continue
    wt_name=$(basename "$wt" | sed 's|^chump-||')
    # Skip if any file modified in last 2h.
    if find "$wt" -mmin -120 -not -path '*/target/*' -print -quit 2>/dev/null | grep -q .; then continue; fi
    # Skip if remote branch still exists.
    branch="chump/${wt_name}"
    if git -C "$REPO_ROOT" ls-remote --heads chump "$branch" 2>/dev/null | grep -q .; then continue; fi
    # Skip if uncommitted changes inside.
    if [[ -d "$wt/.git" ]] && git -C "$wt" status --porcelain 2>/dev/null | grep -q .; then continue; fi
    # INFRA-1074: skip actively-in-use worktrees (fresh git index / unpushed /
    # freshly-leased) that the cheaper checks above can miss.
    if worktree_is_active "$wt" "$REPO_ROOT"; then continue; fi
    # Safe to reap.
    size=$(du -sm "$wt" 2>/dev/null | awk '{print $1}')
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "would reap whole worktree $wt (~${size}MB)"
    else
      rm -rf "$wt" 2>/dev/null && {
        reaped_wt=$((reaped_wt + 1))
        emit_ambient "\"kind\":\"worktree_orphan_pruned_tier2\",\"path\":\"$wt\",\"freed_mb\":${size:-0}"
        info "reaped $wt (~${size}MB)"
      }
    fi
  done
  [[ "$reaped_wt" -gt 0 ]] && ok "tier 2 reaped $reaped_wt worktrees"

  # INFRA-2188: sccache reap runs LAST within the tier — after all build-target
  # artifacts are reaped — so the build accelerator is only pruned when disk
  # pressure persists after cheaper reaping. Reaped only if >5GB.
  SCCACHE_DIR="${SCCACHE_DIR:-$HOME/Library/Caches/Mozilla.sccache}"
  if [[ -d "$SCCACHE_DIR" ]]; then
    sccache_kb=$(du -sk "$SCCACHE_DIR" 2>/dev/null | awk '{print $1}')
    sccache_threshold_kb=$(( 5 * 1024 * 1024 ))  # 5GB in KB
    if [[ "$sccache_kb" -gt "$sccache_threshold_kb" ]]; then
      info "tier 2 (last): sccache dir is ${sccache_kb}KB (>5GB) — invoking sccache-reaper (build-target reap done first)"
      if [[ -x "$SCCACHE_REAPER" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          SCCACHE_DIR="$SCCACHE_DIR" "$SCCACHE_REAPER" --dry-run 2>&1 | tail -5
        else
          SCCACHE_DIR="$SCCACHE_DIR" "$SCCACHE_REAPER" --execute 2>&1 | tail -5
        fi
      else
        warn "sccache-reaper not found at $SCCACHE_REAPER"
      fi
    else
      ok "sccache dir ${sccache_kb}KB (≤5GB) — skipping sccache reap at tier 2"
    fi
  fi
fi

# ── Tier 3: aggressive — whole-worktree + target/debug/incremental reap ──
if [[ "$tier" -ge 3 ]]; then
  warn "tier $tier (5-10GB free): aggressive whole-worktree reap"
  # Build active-lease gap-id set.
  active_gaps=""
  for lease in "$REPO_ROOT"/.chump-locks/*.json; do
    [[ -f "$lease" ]] || continue
    gap=$(basename "$lease" .json | sed -E 's/^claim-([a-z]+)-([0-9]+).*/\1-\2/' | tr '[:lower:]' '[:upper:]')
    active_gaps+=" $gap"
  done
  reaped_t3=0
  for wt in /private/tmp/chump-*; do
    [[ -d "$wt" ]] || continue
    wt_name=$(basename "$wt" | sed 's|^chump-||')
    gap_id=$(echo "$wt_name" | tr '[:lower:]' '[:upper:]')
    [[ " $active_gaps " == *" $gap_id "* ]] && continue
    # 30 min idle threshold.
    if find "$wt" -mmin -30 -not -path '*/target/*' -print -quit 2>/dev/null | grep -q .; then continue; fi
    # Uncommitted check.
    if [[ -d "$wt/.git" ]] && git -C "$wt" status --porcelain 2>/dev/null | grep -q .; then continue; fi
    # INFRA-1074: skip actively-in-use worktrees (fresh git index / unpushed /
    # freshly-leased) — protects committed-but-unpushed work with no recent edit
    # that the 30m-idle + uncommitted checks miss.
    if worktree_is_active "$wt" "$REPO_ROOT"; then continue; fi
    size=$(du -sm "$wt" 2>/dev/null | awk '{print $1}')
    if [[ "$DRY_RUN" -eq 1 ]]; then
      warn "would reap $wt (~${size}MB) — tier 3"
    else
      rm -rf "$wt" 2>/dev/null && {
        reaped_t3=$((reaped_t3 + 1))
        emit_ambient "\"kind\":\"worktree_orphan_pruned_tier3\",\"path\":\"$wt\",\"freed_mb\":${size:-0}"
      }
    fi
  done
  [[ "$reaped_t3" -gt 0 ]] && ok "tier 3 reaped $reaped_t3 worktrees"

  # Reap target/debug/incremental from the main repo if no active rustc
  # process is writing to it. Safe: cargo regenerates incrementals lazily.
  # Only touch main repo target — worktree targets are handled above. INFRA-2303.
  INCREMENTAL_DIR="$REPO_ROOT/target/debug/incremental"
  if [[ -d "$INCREMENTAL_DIR" ]]; then
    if pgrep -x rustc >/dev/null 2>&1; then
      info "tier 3: active rustc process detected — skipping incremental reap"
    else
      incr_kb=$(du -sk "$INCREMENTAL_DIR" 2>/dev/null | awk '{print $1}')
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[DRY-RUN] would rm -rf $INCREMENTAL_DIR (~${incr_kb}KB) — no active rustc"
      else
        rm -rf "${INCREMENTAL_DIR:?}"/* 2>/dev/null || true
        incr_freed_bytes=$(( incr_kb * 1024 ))
        ok "tier 3: reaped target/debug/incremental (~${incr_kb}KB freed)"
        emit_ambient "\"kind\":\"incremental_reaped\",\"bytes_freed\":${incr_freed_bytes},\"freed_kb\":${incr_kb},\"dir\":\"${INCREMENTAL_DIR}\""
      fi
    fi
  else
    info "tier 3: $INCREMENTAL_DIR does not exist — skipping"
  fi
fi

# ── Tier 4 (RED): operator escalation ────────────────────────────────────
if [[ "$tier" -ge 4 ]]; then
  alert "tier 4 (RED): disk < 5GB. Operator action required per INFRA-1471."
  emit_ambient "\"kind\":\"disk_pressure_red\",\"free_gb\":${free_gb},\"note\":\"manual intervention required\""
  alert "Suggested: identify + kill 3-5 large worktrees:"
  du -sm /private/tmp/chump-* 2>/dev/null | sort -rn | head -5 | awk '{print "    "$2"  ("$1"MB)"}'
fi

# Final disk report
final_free=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
echo
ok "disk free now ${final_free}GB (was ${free_gb}GB, tier ${tier})"
