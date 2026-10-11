#!/usr/bin/env bash
# scripts/ops/cargo-sweep-gc.sh — ZERO-WASTE-053
#
# Steady-state GC for the shared cargo target so chump runs for DAYS without a
# disk wedge. Uses `cargo-sweep --maxsize` (LRU eviction by access time) to hold
# the shared target under a hard cap, turning cargo's unbounded monotonic growth
# into a bounded plateau.
#
# Why this and not the existing reapers: the three mtime-based target-reapers
# froze 0 bytes under an active fleet (everything looked "hot"). cargo-sweep
# understands cargo's fingerprint structure and removes the OLDEST-ACCESSED
# artifacts first — so it is SAFE to run mid-build (it never evicts what a live
# build just touched). On this single-disk Mac (no volume to relocate onto), this
# bounding is the load-bearing days-and-days fix; the RESILIENT-273 self-heal is
# only the emergency backstop.
#
# Usage: cargo-sweep-gc.sh [--dry-run]
# Env:
#   CHUMP_REPO                 repo root (default /Users/jeffadkins/Projects/Chump)
#   CHUMP_CARGO_TARGET_CAP_MB  hard cap in MB (default 20000 = 20 GB)
#   CHUMP_CARGO_SWEEP_TIME_DAYS  age-based prune horizon in days (default 14; RESILIENT-239)
set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo $HOME/Projects/chump)}}"
CAP_MB="${CHUMP_CARGO_TARGET_CAP_MB:-20000}"
TIME_DAYS="${CHUMP_CARGO_SWEEP_TIME_DAYS:-14}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY=""; [[ "${1:-}" == "--dry-run" ]] && DRY="--dry-run"

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMB" 2>/dev/null || true; }
# Scanner anchors for the event-registry verify rule (emit() escapes quotes):
#   "kind":"cargo_sweep_gc_ran"
#   "kind":"cargo_sweep_gc_skipped"
#   "kind":"cargo_sweep_gc_errored"
#   "kind":"cargo_sweep_gc_time_pruned"
#   "kind":"wedged_inode_binaries_reaped"

# ZERO-WASTE-054: locate the REAL cargo. On this host cargo is $HOME/bin/cargo;
# ~/.cargo/bin/cargo is only a symlink to the rustup shim, which resolves under
# launchd's minimal env but then fails `cargo metadata` (cargo-not-found) — so the
# GC silently no-op'd every 30 min while looking alive. Prepend the real dirs.
export PATH="$HOME/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "[cargo-sweep-gc] cargo not on PATH — cargo-sweep needs it for metadata; skipping" >&2
  emit "\"kind\":\"cargo_sweep_gc_skipped\",\"reason\":\"cargo-not-found\""
  exit 0
fi
if ! command -v cargo-sweep >/dev/null 2>&1; then
  echo "[cargo-sweep-gc] cargo-sweep not installed — RED (install: cargo install cargo-sweep)" >&2
  emit "\"kind\":\"cargo_sweep_gc_skipped\",\"reason\":\"cargo-sweep-not-installed\""
  # RESILIENT-1590: a GC that cannot GC must go RED (non-zero + errored event), not skip quietly.
  emit "\"kind\":\"cargo_sweep_gc_errored\",\"cap_mb\":$CAP_MB,\"rc\":3,\"error\":\"cargo-sweep-not-installed\""
  exit 3
fi
if [[ ! -f "$REPO_ROOT/Cargo.toml" ]]; then
  echo "[cargo-sweep-gc] no Cargo.toml at $REPO_ROOT — skipping" >&2
  emit "\"kind\":\"cargo_sweep_gc_skipped\",\"reason\":\"no-cargo-toml\",\"repo\":\"$REPO_ROOT\""
  exit 0
fi

# RESILIENT-1590: sweep EVERY target dir builds actually write to, each with its own cap.
# CHUMP_CARGO_SWEEP_TARGET_DIRS = colon-separated "path[=capMB]" entries (default list below).
# cargo-sweep honors CARGO_TARGET_DIR, so each dir is swept by pointing it there.
DEFAULT_DIRS="$REPO_ROOT/target:$HOME/.cargo/chump-shared-target:$HOME/.cache/chump-fleet-target:$HOME/.cargo/chump-coord-release-target"
[[ -n "${CARGO_TARGET_DIR:-}" ]] && DEFAULT_DIRS="$DEFAULT_DIRS:$CARGO_TARGET_DIR"
DIRS="${CHUMP_CARGO_SWEEP_TARGET_DIRS:-$DEFAULT_DIRS}"
DRYJ=false; [[ -n "$DRY" ]] && DRYJ=true
worst_rc=0; seen=":"

IFS=':' read -ra ENTRIES <<< "$DIRS"
for entry in "${ENTRIES[@]}"; do
  [[ -z "$entry" ]] && continue
  tdir="${entry%%=*}"; dcap="$CAP_MB"
  [[ "$entry" == *=* ]] && dcap="${entry#*=}"
  [[ -d "$tdir" ]] || continue
  [[ "$seen" == *":$tdir:"* ]] && continue
  seen="$seen$tdir:"

  out="$(cd "$REPO_ROOT" && CARGO_TARGET_DIR="$tdir" cargo-sweep sweep --maxsize "$dcap" $DRY . 2>&1)"
  rc=$?
  # ZERO-WASTE-054 HONEST SIGNAL: an errored GC must never report "nothing to clean".
  if [[ $rc -ne 0 ]]; then
    err="$(printf '%s' "$out" | grep -iE 'error|failed|no such|not found' | head -2 | tr '\n' ' ')"
    echo "[cargo-sweep-gc] ERROR dir=$tdir rc=$rc: ${err:-$out}" >&2
    emit "\"kind\":\"cargo_sweep_gc_errored\",\"target_dir\":\"$tdir\",\"cap_mb\":$dcap,\"rc\":$rc,\"error\":\"$(printf '%s' "${err:-see-log}" | tr '"' "'" | cut -c1-200)\""
    worst_rc=$rc
    continue
  fi
  cleaned="$(printf '%s' "$out" | grep -oiE '(Would clean|Cleaned):? *[0-9.]+ *[KMG]i?B' | head -1)"
  cleaned="${cleaned:-nothing to clean}"
  echo "[cargo-sweep-gc] dir=$tdir cap=${dcap}MB $([ -n "$DRY" ] && echo dry-run || echo execute) -> ${cleaned} (rc=$rc)"
  emit "\"kind\":\"cargo_sweep_gc_ran\",\"target_dir\":\"$tdir\",\"cap_mb\":$dcap,\"dry_run\":$DRYJ,\"result\":\"$(printf '%s' "$cleaned" | tr '"' "'")\",\"rc\":$rc"

  # RESILIENT-239: age-based prune complements --maxsize (bounds file COUNT, not just bytes).
  time_out="$(cd "$REPO_ROOT" && CARGO_TARGET_DIR="$tdir" cargo-sweep sweep --time "$TIME_DAYS" --recursive $DRY . 2>&1)"
  time_rc=$?
  time_cleaned="$(printf '%s' "$time_out" | grep -oiE '(Would clean|Cleaned):? *[0-9.]+ *[KMG]i?B' | head -1)"
  time_cleaned="${time_cleaned:-nothing to clean}"
  echo "[cargo-sweep-gc] dir=$tdir time-prune days=${TIME_DAYS} -> ${time_cleaned} (rc=$time_rc)"
  emit "\"kind\":\"cargo_sweep_gc_time_pruned\",\"target_dir\":\"$tdir\",\"time_days\":$TIME_DAYS,\"dry_run\":$DRYJ,\"result\":\"$(printf '%s' "$time_cleaned" | tr '"' "'")\",\"rc\":$time_rc"
done

# RESILIENT-1590: reap chump-*.wedged-inode-* binary copies (69MB each, accumulate from
# the binary-unwedge/refresh path) — keep only the newest per binary.
reaped=0
for d in "$REPO_ROOT/target/release" "$REPO_ROOT/target/debug" "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/bin" "$HOME/.chump/bin"; do
  [[ -d "$d" ]] || continue
  for base in $(ls "$d" 2>/dev/null | sed -n 's/\(.*\)\.wedged-inode-.*/\1/p' | sort -u); do
    while IFS= read -r old; do
      [[ -z "$old" ]] && continue
      if [[ -z "$DRY" ]]; then rm -f -- "$old" && reaped=$((reaped+1)); else reaped=$((reaped+1)); fi
    done < <(ls -1t "$d/$base".wedged-inode-* 2>/dev/null | tail -n +2)
  done
done
emit "\"kind\":\"wedged_inode_binaries_reaped\",\"count\":$reaped,\"dry_run\":$DRYJ"
echo "[cargo-sweep-gc] wedged-inode binaries reaped (kept newest-1): $reaped"

exit "$worst_rc"
