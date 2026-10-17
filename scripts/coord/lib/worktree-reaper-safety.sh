#!/usr/bin/env bash
# scripts/coord/lib/worktree-reaper-safety.sh — INFRA-1074
#
# Shared "is this worktree actively in use?" guard for the worktree / cargo
# target reapers. A worktree is ACTIVE (must NOT be reaped, even under
# disk-critical pressure) if ANY of:
#
#   1. an active lease (.chump-locks/*.json) references it with a heartbeat
#      (heartbeat_at / updated_at / created_at) within
#      CHUMP_REAPER_ACTIVE_LEASE_MIN (default 15) minutes, OR an unexpired
#      expires_at;
#   2. its git index was touched within CHUMP_REAPER_INDEX_MIN (default 5)
#      minutes — an in-flight `git add` / commit / checkout;
#   3. it has uncommitted changes OR unpushed commits — work not yet safe on a
#      remote, so reaping it destroys real work;
#   4. (RESILIENT-1609) a bot-merge ship is live in it: a fresh
#      .chump-locks/bot-merge-*.steps file names it, or a live process has it
#      as its cwd. Reported as reason=bot_merge_live. A recovery-mode ship
#      (CHUMP_BOT_MERGE_RECOVERY_MODE=1) takes no lease and leaves the git
#      index idle during clippy, so checks 1-3 alone let the reaper remove
#      infra-8180 mid-push on 2026-10-16.
#
# WHY (the INFRA-1074 bug): the critical-mode cargo target reaper used the
# active lease as its ONLY guard. A worktree created via `git worktree add`
# (no lease), or one whose lease was reaped out from under it, then got its
# target/ deleted MID-BUILD — losing the binary and forcing a 2-3 min rebuild
# (observed repeatedly on 2026-06-04 while disk sat in critical mode).
#
# Reaping build artifacts of a *finished* worktree is fine; reaping an
# *actively building / committing / unpushed* one is not. This guard draws
# that line independent of lease state.
#
# Bypass (for tests that exercise the reaper itself): CHUMP_REAPER_SAFETY_CHECK=0.
#
# Usage (source, then guard each candidate):
#   source "$(dirname "$0")/lib/worktree-reaper-safety.sh"
#   if worktree_is_active "$wt" "$REPO_ROOT"; then continue; fi   # skip reaping
#
# Or standalone (exit 0 = active/protect, 1 = safe to reap):
#   scripts/coord/lib/worktree-reaper-safety.sh /private/tmp/chump-foo [repo_root]
#
# Returns 0 = ACTIVE (protect/skip), 1 = safe to reap.
# On protect, emits kind=worktree_reaper_skipped_active to ambient.jsonl.

# RESILIENT-1609: wt_has_live_bot_merge lives in the shared reaper lib.
# shellcheck source=../../lib/worktree-iter.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/../../lib/worktree-iter.sh" 2>/dev/null || true

# Returns 0 (active) / 1 (reapable). Never deletes anything.
worktree_is_active() {
  local wt="$1"
  local repo_root="${2:-${CHUMP_REPO:-${REPO_ROOT:-}}}"
  [ -d "$wt" ] || return 1 # gone → nothing to protect

  # Test bypass: pretend nothing is active so the reaper logic can be exercised.
  if [ "${CHUMP_REAPER_SAFETY_CHECK:-1}" = "0" ]; then
    return 1
  fi

  local lease_min="${CHUMP_REAPER_ACTIVE_LEASE_MIN:-15}"
  local index_min="${CHUMP_REAPER_INDEX_MIN:-5}"
  local reason=""

  # Resolve the repo root that owns .chump-locks (the main checkout) if not given.
  if [ -z "$repo_root" ]; then
    repo_root="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  local lock_dir="$repo_root/.chump-locks"

  # ── 0. Live bot-merge ship (RESILIENT-1609) ────────────────────────────────
  if declare -F wt_has_live_bot_merge >/dev/null 2>&1 \
     && wt_has_live_bot_merge "$wt" "$lock_dir"; then
    reason="bot_merge_live"
  fi

  # ── 1. Fresh lease referencing this worktree ───────────────────────────────
  # RESILIENT-218: `chump claim` writes worktrees at the deterministic path
  # <base>/chump-<gap_id.lower()> (crates/chump-atomic-claim), but its lease
  # JSON (write_basic_lease) never carries the worktree path or basename —
  # only session_id/paths/taken_at/expires_at/heartbeat_at/purpose/gap_id.
  # `grep -q "$base" "$lease"` therefore silently fails to correlate a real
  # lease to its worktree (e.g. basename "chump-effective-330" never appears
  # in a lease whose purpose is "gap:EFFECTIVE-330"), so a genuinely-claimed
  # worktree can fall through this guard entirely once its git-index/
  # uncommitted/unpushed signals (checks 2-3 below) go quiet — the exact
  # tier3-destroys-a-live-claim incident in RESILIENT-218's evidence. Derive
  # the gap_id the worktree basename implies and match it directly against
  # each lease's gap_id field (a real field lookup) in addition to the old
  # substring grep, which stays as a fallback for leases that do embed the
  # worktree path/basename in free text.
  if [ -z "$reason" ] && [ -d "$lock_dir" ]; then
    local base; base="$(basename "$wt")"
    local expected_gap=""
    case "$base" in
      chump-*) expected_gap="$(printf '%s' "${base#chump-}" | tr '[:lower:]' '[:upper:]')" ;;
    esac
    local lease
    for lease in "$lock_dir"/*.json; do
      [ -f "$lease" ] || continue
      case "$lease" in */inbox/*) continue ;; esac
      if ! grep -q "$base" "$lease" 2>/dev/null; then
        # No substring match — only proceed if the lease's gap_id field
        # directly matches the gap this worktree's basename implies.
        if [ -n "$expected_gap" ]; then
          local gap_match
          gap_match="$(LEASE="$lease" EXPECTED="$expected_gap" python3 - <<'PY' 2>/dev/null
import json, os
lease = os.environ["LEASE"]; expected = os.environ["EXPECTED"]
try:
    d = json.load(open(lease))
    print("1" if str(d.get("gap_id", "")).upper() == expected else "0")
except Exception:
    print("0")
PY
)"
          [ "$gap_match" = "1" ] || continue
        else
          continue
        fi
      fi
      local fresh
      fresh="$(LEASE="$lease" LEASE_MIN="$lease_min" python3 - <<'PY' 2>/dev/null
import json, os, time, datetime
lease = os.environ["LEASE"]; lim = float(os.environ["LEASE_MIN"]) * 60
def ts(v):
    if isinstance(v, (int, float)): return float(v)
    try:
        return datetime.datetime.fromisoformat(
            str(v).rstrip("Z").replace("+00:00", "")).timestamp()
    except Exception:
        return None
try:
    d = json.load(open(lease)); now = time.time()
    e = ts(d.get("expires_at"))
    if e is not None and e > now:
        print("1"); raise SystemExit
    for k in ("heartbeat_at", "updated_at", "created_at"):
        t = ts(d.get(k))
        if t is not None and (now - t) < lim:
            print("1"); raise SystemExit
except SystemExit:
    pass
except Exception:
    pass
PY
)"
      if [ "$fresh" = "1" ]; then
        reason="active lease (heartbeat <${lease_min}m / unexpired)"
        break
      fi
    done
  fi

  # ── 2. Git index touched very recently (in-flight add/commit/checkout) ──────
  if [ -z "$reason" ]; then
    local idx
    idx="$(git -C "$wt" rev-parse --git-path index 2>/dev/null)"
    # rev-parse may return a path relative to the worktree.
    case "$idx" in /*) : ;; *) [ -n "$idx" ] && idx="$wt/$idx" ;; esac
    if [ -n "$idx" ] && [ -f "$idx" ]; then
      if find "$idx" -mmin -"$index_min" 2>/dev/null | grep -q .; then
        reason="git index touched <${index_min}m ago"
      fi
    fi
  fi

  # ── 3. Uncommitted changes or unpushed commits ─────────────────────────────
  if [ -z "$reason" ]; then
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      reason="uncommitted changes"
    elif git -C "$wt" rev-parse '@{upstream}' >/dev/null 2>&1; then
      if [ -n "$(git -C "$wt" rev-list '@{upstream}..HEAD' 2>/dev/null | head -1)" ]; then
        reason="unpushed commits (ahead of upstream)"
      fi
    else
      # No upstream configured: if HEAD is on no remote branch, it's unpushed work.
      local head; head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
      if [ -n "$head" ] && [ -z "$(git -C "$wt" branch -r --contains "$head" 2>/dev/null | head -1)" ]; then
        reason="unpushed work (HEAD on no remote)"
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    local amb="$repo_root/.chump-locks/ambient.jsonl"
    if [ -d "$(dirname "$amb")" ]; then
      printf '{"ts":"%s","kind":"worktree_reaper_skipped_active","worktree":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt" "$reason" >> "$amb" 2>/dev/null || true
    fi
    return 0 # ACTIVE — protect
  fi
  return 1 # safe to reap
}

# Standalone entry point: exit 0 = active/protect, 1 = safe to reap.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  if worktree_is_active "${1:?usage: worktree-reaper-safety.sh <worktree> [repo_root]}" "${2:-}"; then
    echo "ACTIVE — protect (do not reap): $1"
    exit 0
  else
    echo "reapable (no active signal): $1"
    exit 1
  fi
fi
