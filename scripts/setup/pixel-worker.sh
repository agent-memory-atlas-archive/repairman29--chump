#!/data/data/com.termux/files/usr/bin/bash
# pixel-worker.sh — Pixel 8 Pro express-lane fleet worker (RESILIENT-336 Stage 1).
# Picks a small (xs/s), non-rust, non-external gap and executes it via the
# cascade (deepseek-v4-pro primary). Failed gaps get a cooldown so the loop
# advances instead of re-hammering one hard gap.
set -uo pipefail

# RESILIENT-805: kill switch for the cap-wasting loop (Aug 26 pause). Set
# PIXEL_WORKER_DISABLE=1 or touch $PIXEL_WORKER_DISABLE_FILE to refuse to start.
PIXEL_WORKER_DISABLE_FILE="${PIXEL_WORKER_DISABLE_FILE:-$HOME/.chump/pixel-worker.disabled}"
if [ "${PIXEL_WORKER_DISABLE:-0}" = "1" ] || [ -e "$PIXEL_WORKER_DISABLE_FILE" ]; then
  echo "[pixel-worker] disabled (PIXEL_WORKER_DISABLE / $PIXEL_WORKER_DISABLE_FILE); not starting loop"
  exit 0
fi

export CHUMP_HOME="${CHUMP_HOME:-$HOME/chump}"
export CHUMP_REPO="${CHUMP_REPO:-$HOME/chump-repo}"
cd "$CHUMP_REPO" || { echo "[pixel-worker] no repo at $CHUMP_REPO" >&2; exit 1; }

if [ -f "$CHUMP_HOME/.env" ]; then
  set -a; . "$CHUMP_HOME/.env"; set +a
fi

# EFFECTIVE-445 in-path fix: layer the funded DeepSeek cost floor ON TOP of
# chump/.env so the worker build routes deepseek-v4-flash->pro (OpenRouter),
# not the stale/unfunded Mistral ladder that shipped in older chump/.env files.
# Sourced LAST so CHUMP_MODEL_ESCALATION_LADDER + CHUMP_FREE_TIER_PROVIDERS +
# OPENROUTER_API_KEY from providers.env win. Config presence alone is not
# enough: the worker env must actually SOURCE the ladder to be in-path.
if [ -f "$CHUMP_STATE_DIR/providers.env" ]; then
  set -a; . "$CHUMP_STATE_DIR/providers.env"; set +a
elif [ -f "$HOME/.chump/providers.env" ]; then
  set -a; . "$HOME/.chump/providers.env"; set +a
fi

export WORKER_SKILLS="${WORKER_SKILLS:-docs,shell,scripts,md}"
export WORKER_MACHINE="${WORKER_MACHINE:-pixel-8-pro}"
export CHUMP_WORK_BACKEND="${CHUMP_WORK_BACKEND:-chump-local}"
export FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P1,P2}"
# RESILIENT-411: backend selector for the execute step. FLEET_BACKEND=claude
# routes inference through the Anthropic subscription (OAuth), which chump-local
# can only reach by shelling out to `claude -p` (there is NO CLI-free OAuth path
# in chump-local). On Termux the npm `claude` has no aarch64-Android binary, so
# the wrapper runs the linux-arm64 (glibc) claude build inside proot-distro and
# injects the OAuth token + ship toolchain env. Default stays chump-local so
# non-Pixel nodes are unaffected; the Pixel node sets FLEET_BACKEND=claude in
# ~/chump/.env (via setup-pixel-node.sh set_env).
export FLEET_BACKEND="${FLEET_BACKEND:-chump-local}"
export FLEET_MODEL="${FLEET_MODEL:-sonnet}"
# Node-local (survives the periodic `git reset --hard origin/main` below).
# setup-pixel-node.sh installs both from scripts/setup/ into ~/.chumpnode/bin/.
CLAUDE_PROOT_WRAPPER="${CLAUDE_PROOT_WRAPPER:-$HOME/.chumpnode/bin/claude-proot}"
PIXEL_SHIP="${PIXEL_SHIP:-$HOME/.chumpnode/bin/pixel-ship.sh}"

BIN="${CHUMP_BIN:-$CHUMP_HOME/chump}"
IDLE_S="${PIXEL_WORKER_IDLE_S:-60}"
COOLDOWN_S="${PIXEL_WORKER_COOLDOWN_S:-3600}"
REFRESH_S="${PIXEL_WORKER_REFRESH_S:-1800}"
# Wedge-kill: a claude-in-proot run that exceeds this wall-clock is killed (with
# its proot children) and the gap cooled down, so one hung glibc claude cannot
# stall the whole Pixel loop.
WEDGE_S="${PIXEL_WORKER_WEDGE_S:-1500}"
FAILED_FILE="$HOME/pixel-worker-failed.tsv"   # gap_id<TAB>epoch_s
LAST_REFRESH=0

# INFRA-3664: claim atomically via `chump claim` (INFRA-513 fix — single DB
# transaction) instead of executing straight off a `gap list` pick. Without
# this, a second worker picking the same gap in the same window races the
# first and produces a silent_agent event (fleet-scaling-2026-05-06.md).
# Termux ($PREFIX/tmp via TMPDIR) is app-writable; bare /tmp is NOT on
# Android, so a node-setup regeneration would wipe the live hand-crank and
# break `chump claim` with "Permission denied". Prefer $CHUMP_WORKTREE_BASE,
# then $TMPDIR (Termux sets it), then /tmp (datacenter Linux — unchanged).
WORKTREE_BASE="${CHUMP_WORKTREE_BASE:-${TMPDIR:-/tmp}}"

[ -x "$BIN" ] || { echo "[pixel-worker] chump binary not found at $BIN" >&2; exit 1; }

echo "[pixel-worker] up: skills=$WORKER_SKILLS machine=$WORKER_MACHINE backend=$CHUMP_WORK_BACKEND bin=$BIN cooldown=${COOLDOWN_S}s"

while true; do
  echo "[pixel-worker] $(date -u +%FT%TZ) tick"
  NOW=$(date +%s)

  # Periodic state refresh (INFRA-3628): the node's local registry drifts from
  # origin/main. Every REFRESH_S pull fresh docs/gaps and insert any gap the
  # local store has never seen. INFRA-8193: `gap sync --pull` (YAML overwrites
  # the store) is retired; `gap import` is insert-only, so status changes made
  # elsewhere no longer flow in from the mirror — `chump store reconcile`
  # (INFRA-8222) is the replacement for that half.
  if [ $(( NOW - LAST_REFRESH )) -ge "$REFRESH_S" ]; then
    echo "[pixel-worker] refreshing state from origin/main..."
    git -C "$CHUMP_REPO" fetch origin main --depth 1 >/dev/null 2>&1 \
      && git -C "$CHUMP_REPO" reset --hard origin/main >/dev/null 2>&1
    CHUMP_GAP_IMPORT_NO_SIMILARITY=1 "$BIN" gap import --yaml "$CHUMP_REPO/docs/gaps" >/dev/null 2>&1 || true
    LAST_REFRESH="$NOW"
    echo "[pixel-worker] state refreshed"
  fi

  # Prune expired cooldown entries (gap_id<TAB>epoch, keep only still-cooling).
  if [ -f "$FAILED_FILE" ]; then
    awk -v now="$NOW" -v cd="$COOLDOWN_S" 'now - $2 < cd {print}' "$FAILED_FILE" > "$FAILED_FILE.tmp" 2>/dev/null
    mv "$FAILED_FILE.tmp" "$FAILED_FILE" 2>/dev/null || rm -f "$FAILED_FILE"
  fi

  GAP="$("$BIN" gap list --status open --json 2>/dev/null | COOLDOWN_FILE="$FAILED_FILE" python3 -c '
import sys, json, os
skills = {s.strip() for s in os.environ.get("WORKER_SKILLS", "").split(",") if s.strip()}
prio = set(os.environ.get("FLEET_PRIORITY_FILTER", "P1,P2").split(","))
cool = set()
cf = os.environ.get("COOLDOWN_FILE", "")
if cf and os.path.exists(cf):
    for line in open(cf):
        p = line.strip().split("\t")
        if p:
            cool.add(p[0])
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for g in rows:
    gid = g.get("id", "")
    if gid in cool:
        continue
    req = {s.strip() for s in (g.get("skills_required") or "").split(",") if s.strip()}
    if any(r.startswith("external_repo:") for r in req):
        continue
    if "workspace_scope" in req:
        continue
    if "rust" in req:
        continue
    if req and not (req & skills):
        continue
    if g.get("effort") not in ("xs", "s"):
        continue
    if prio and g.get("priority") not in prio:
        continue
    print(gid)
    break
')"

  if [ -z "$GAP" ]; then
    NCOOL=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    echo "[pixel-worker] no pickable gap (${NCOOL} in cooldown); sleep ${IDLE_S}s"
    sleep "$IDLE_S"
    continue
  fi

  echo "[pixel-worker] claiming gap=$GAP"
  CHUMP_WORKTREE_BASE="$WORKTREE_BASE" "$BIN" claim "$GAP" 2>&1 | tail -20
  claim_rc=${PIPESTATUS[0]}

  if [ "$claim_rc" -ne 0 ]; then
    # Lost the atomic-claim race (or a gate blocked it) — another worker won
    # this gap. Not a gap failure: don't cooldown, just re-pick next tick.
    echo "[pixel-worker] claim failed for gap=$GAP (rc=$claim_rc); skipping this tick"
    sleep "$IDLE_S"
    continue
  fi

  gap_lower="$(echo "$GAP" | tr 'A-Z' 'a-z')"
  wt_path="$WORKTREE_BASE/chump-$gap_lower"
  if [ ! -d "$wt_path" ]; then
    echo "[pixel-worker] claim reported success but worktree missing at $wt_path" >&2
    printf "%s\t%s\n" "$GAP" "$(date +%s)" >> "$FAILED_FILE"
    sleep "$IDLE_S"
    continue
  fi

  echo "[pixel-worker] executing gap=$GAP in $wt_path (backend=$FLEET_BACKEND model=$FLEET_MODEL)"
  cd "$wt_path" || { echo "[pixel-worker] cannot cd to $wt_path" >&2; sleep "$IDLE_S"; continue; }
  if [ "$FLEET_BACKEND" = "claude" ] && [ -x "$CLAUDE_PROOT_WRAPPER" ]; then
    # RESILIENT-411: subscription/OAuth ship on Sonnet. chump-local has no
    # CLI-free OAuth path; the Termux npm claude has no aarch64-Android binary;
    # so run the linux-arm64 (glibc) claude build inside proot-distro. Split of
    # duties: claude-in-proot IMPLEMENTS + COMMITS only; the SHIP (push + PR +
    # auto-merge) runs on the Termux side via pixel-ship.sh — because the
    # bot-merge local `cargo clippy --fix` cold-compiles the whole workspace and
    # is prohibitively slow on the Pixel. The worker only picks non-rust gaps, so
    # GitHub CI (audit/test + clippy) is authoritative and skips the heavy lanes.
    impl_prompt="Implement gap $GAP in this repository. First run: chump gap show $GAP  to read the full spec. The gap is already claimed for this session; the lease is in .chump-locks/. Implement it per its acceptance criteria, then commit with: bash scripts/coord/chump-commit.sh <changed-files> -m \"$GAP: <subject>\". Do NOT push, do NOT open a PR, do NOT run bot-merge — the node ships separately. Reply DONE once the commit exists."
    printf "%s" "$impl_prompt" | timeout -k 30 "$WEDGE_S" "$CLAUDE_PROOT_WRAPPER" -p --dangerously-skip-permissions --model "$FLEET_MODEL" 2>&1 | tail -60
    impl_rc=${PIPESTATUS[1]}
    if [ "$impl_rc" -eq 124 ] || [ "$impl_rc" -eq 137 ]; then
      echo "[pixel-worker] gap=$GAP wedge-kill: claude-proot exceeded ${WEDGE_S}s (rc=$impl_rc)" >&2
      pkill -KILL -f "claude-proot-guest.sh" 2>/dev/null || true
      pkill -KILL -f "proot-distro login debian" 2>/dev/null || true
    fi
    if [ "$impl_rc" -eq 0 ] && [ -n "$(git -C "$wt_path" log --oneline origin/main..HEAD 2>/dev/null)" ]; then
      bash "$PIXEL_SHIP" "$GAP" "$wt_path" 2>&1 | tail -30
      rc=${PIPESTATUS[0]}
    else
      echo "[pixel-worker] claude produced no commit for $GAP (impl_rc=$impl_rc)" >&2
      rc=1
    fi
  else
    if [ "$FLEET_BACKEND" = "claude" ]; then
      echo "[pixel-worker] WARN: FLEET_BACKEND=claude but wrapper missing at $CLAUDE_PROOT_WRAPPER; falling back to chump-local" >&2
    fi
    "$BIN" --execute-gap "$GAP" 2>&1 | tail -40
    rc=${PIPESTATUS[0]}
  fi
  cd "$CHUMP_REPO" || exit 1

  if [ "$rc" -eq 0 ]; then
    echo "[pixel-worker] gap=$GAP shipped (rc=0)"
    if [ -f "$FAILED_FILE" ]; then
      grep -v "^${GAP}	" "$FAILED_FILE" > "$FAILED_FILE.tmp" 2>/dev/null && mv "$FAILED_FILE.tmp" "$FAILED_FILE" 2>/dev/null || true
    fi
  else
    echo "[pixel-worker] gap=$GAP failed rc=$rc; cooldown ${COOLDOWN_S}s"
    printf "%s\t%s\n" "$GAP" "$(date +%s)" >> "$FAILED_FILE"
  fi
  sleep "$IDLE_S"
done
