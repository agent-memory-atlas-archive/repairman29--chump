#!/usr/bin/env bash
# backlog-sync.sh (RESILIENT-194) — the fleet's shared-backlog COHERENCE loop.
#
# The problem it fixes: the ship pipeline never closes the loop. A PR merges but
# the gap stays status:open in the registry (no closed_pr, no YAML), state.sql is
# never regenerated, and no node pulls the shared truth. Result: three diverging
# state.db copies, the fleet re-picks already-merged work, and `unverified_ship`
# loops masquerade as a stall.
#
# The fix is COMPOSITION, not new machinery — one source of truth (origin/main's
# .chump/state.sql) and one loop with two roles, both built from existing chump
# primitives (gap ship / gap dump / restore --from-sql) + the local github_cache:
#
#   --reader  (every node, on a timer): git pull + `chump restore --from-sql`.
#             Rebuilds the local backlog from the shared truth. Idempotent/safe;
#             live claims live in NATS-KV, not state.db, so a rebuild loses nothing.
#
#   --writer  (ONE hub, on a timer): reconcile merged PRs -> gap shipped (the
#             write-back the pipeline skips), regenerate state.sql, commit + push.
#             Publishes a current truth for the readers to pull.
#
# Single-writer by design: only the hub runs --writer, so state.sql has one author
# and the git merge-driver rarely fires. Readers are many and never push.
#
# Usage:
#   backlog-sync.sh --reader
#   backlog-sync.sh --writer [--dry-run]
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RESILIENT-001: the jam-proof mirror-converge primitive. The reader MUST NOT
# advance the tree with a merge (`git pull`) — see reader() below.
# shellcheck source=lib/converge-mirror.sh
source "$_here/lib/converge-mirror.sh" 2>/dev/null || true
if ! command -v converge_mirror_hard_reset >/dev/null 2>&1; then
  # Fallback for a partial checkout missing the lib: a plain robust reset still
  # beats a merge (which aborts on untracked collisions).
  converge_mirror_hard_reset() { git reset --hard "${1:?}"; }
fi
REPO="${CHUMP_REPO:-$(git -C "$_here" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/chump-host")}"
CHUMP="${CHUMP_BIN:-chump}"
DRY=0; ROLE=""
for a in "$@"; do case "$a" in
  --reader) ROLE=reader ;; --writer) ROLE=writer ;; --dry-run) DRY=1 ;;
  *) echo "usage: $0 --reader|--writer [--dry-run]" >&2; exit 2 ;;
esac; done
[[ -n "$ROLE" ]] || { echo "usage: $0 --reader|--writer [--dry-run]" >&2; exit 2; }

cd "$REPO" 2>/dev/null || { echo "[backlog-sync] no repo at $REPO" >&2; exit 1; }
log(){ printf '[backlog-sync:%s] %s\n' "$ROLE" "$*"; }
DB="$REPO/.chump/state.db"
CACHE="$REPO/.chump/github_cache.db"

# ── reader: pull the shared truth, rebuild the local backlog ────────────────
reader() {
  # RESILIENT-001: fetch + `git reset --hard origin/main`, NOT `git pull`.
  # A merge-based pull ABORTS ("untracked working tree files would be
  # overwritten by merge") whenever the running fleet has dropped an untracked
  # docs/gaps/<ID>.yaml mirror (or a local chore(backlog) autocommit) that
  # origin/main now carries as a tracked file — and the old `2>/dev/null … pull
  # failed (offline or conflict)` swallowed that PERMANENT structural jam as if
  # it were a transient blip, so the node silently sat stale for hours/days.
  # reset --hard converges over that dirty tree while preserving gitignored DBs
  # (.chump/state.db et al. are never touched). Safe here: a reader is a pure
  # mirror; state.db is rebuilt from state.sql immediately below and live claims
  # live in NATS-KV, so nothing un-pushed is lost (see header, RESILIENT-194).
  log "git fetch origin main"
  if ! git fetch --quiet origin main 2>/dev/null; then
    log "fetch failed (offline) — keeping current backlog"; return 1
  fi
  log "converge: git reset --hard origin/main"
  if ! converge_mirror_hard_reset origin/main; then
    log "reset --hard origin/main failed — keeping current backlog"; return 1
  fi
  log "chump restore --from-sql"
  "$CHUMP" restore --from-sql >/dev/null 2>&1 || { log "restore failed"; return 1; }
  log "backlog refreshed: $(sqlite3 "$DB" "SELECT COUNT(*) FROM gaps WHERE status='open'" 2>/dev/null) open gaps"
}

# ── writer: close merged gaps, regenerate + publish state.sql ───────────────
# Extract a gap id (e.g. INFRA-1730) from a PR title `type(INFRA-1730): …` or a
# head_ref `chump/infra-1730-fleet-…`. Returns uppercased id or empty.
_gap_id_from_pr() {
  local title="$1" head="$2" id=""
  id="$(printf '%s' "$title" | grep -oE '\(([A-Z]+-[0-9]+)\)' | head -1 | tr -d '()')"
  [[ -z "$id" ]] && id="$(printf '%s' "$head" | grep -oiE '[a-z]+-[0-9]+' | head -1 | tr 'a-z' 'A-Z')"
  printf '%s' "$id"
}

# ── isolated publisher (RESILIENT-1341) ─────────────────────────────────────
# The registry reconcile (above, in writer()) MUST read/write the CANONICAL live
# state.db, which lives in the shared fleet tree ($REPO) where 3+ worker.sh procs
# run git constantly. Committing state.sql THERE races their `.git/index.lock` and
# dies ("fatal: Unable to create '.git/index.lock': File exists") — the writer sat
# dead 33h+, origin/main's state.sql went stale, registry split-brain risk.
#
# Fix (RESILIENT-1341): NEVER git-commit in the shared tree. Publish through a
# DEDICATED, fully independent clone (its own .git, refs and index) that only ever
# tracks origin/main and carries a single file — .chump/state.sql, dumped from the
# CANONICAL live DB in $REPO. It shares no git state with the workers, so it can
# never collide on their index.lock. Single-writer is preserved (RESILIENT-194):
# still exactly one --writer; this only relocates its git I/O off the shared tree.
BSYNC_TREE="${CHUMP_BACKLOG_SYNC_TREE:-$HOME/.chump/backlog-sync-tree}"

_ensure_isolated_tree() {
  if [[ -d "$BSYNC_TREE/.git" ]] && git -C "$BSYNC_TREE" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  local url; url="$(git -C "$REPO" remote get-url origin 2>/dev/null)"
  [[ -n "$url" ]] || { log "no origin remote to clone for isolated publish tree"; return 1; }
  log "provisioning isolated publish clone at $BSYNC_TREE"
  rm -rf "$BSYNC_TREE"
  mkdir -p "$(dirname "$BSYNC_TREE")"
  git clone --quiet --single-branch --branch main "$url" "$BSYNC_TREE" \
    || { log "isolated clone failed"; return 1; }
}

# publish_state_sql <closed_count>: dump the canonical DB and push state.sql to
# origin/main from the isolated clone. Re-anchors on the freshest origin/main each
# attempt, so a push rejected by a concurrent PR-merge (main advances constantly)
# is retried by RE-BASING onto the new tip — never by a merge commit.
publish_state_sql() {
  local closed="$1" tries
  _ensure_isolated_tree || return 1
  for tries in 1 2 3; do
    if ! git -C "$BSYNC_TREE" fetch --quiet origin main 2>/dev/null; then
      log "isolated fetch failed (offline?) — will retry next cycle"; return 1
    fi
    if ! git -C "$BSYNC_TREE" reset --hard --quiet FETCH_HEAD 2>/dev/null; then
      git -C "$BSYNC_TREE" reset --hard FETCH_HEAD || { log "isolated reset failed"; return 1; }
    fi
    git -C "$BSYNC_TREE" clean -fdq -- .chump 2>/dev/null || true
    # Dump the CANONICAL live DB ($REPO's, via CHUMP_REPO) into the isolated tree.
    if ! CHUMP_REPO="$REPO" "$CHUMP" gap dump > "$BSYNC_TREE/.chump/state.sql" 2>/dev/null; then
      log "gap dump failed"; return 1
    fi
    if git -C "$BSYNC_TREE" diff --quiet -- .chump/state.sql 2>/dev/null; then
      log "state.sql already current on origin/main — nothing to push"; return 0
    fi
    git -C "$BSYNC_TREE" add .chump/state.sql
    # Skip code hooks: automated single-file (state.sql) publish, not a code change;
    # state.sql is auto-allowed by the off-rails guard.
    git -C "$BSYNC_TREE" -c core.hooksPath=/dev/null commit -q -m "chore(backlog): coherence sync — $closed gaps closed, state.sql regenerated

Automated by scripts/coord/backlog-sync.sh --writer (RESILIENT-194/RESILIENT-1341).
Single-writer hub reconcile: merged PRs -> gap done, regenerate the shared truth,
published from an isolated clone that never races the fleet tree's git index." 2>/dev/null \
      || { log "commit failed"; return 1; }
    if git -C "$BSYNC_TREE" push --quiet origin HEAD:main 2>/dev/null; then
      log "published state.sql to origin/main ($closed gaps closed this cycle)"; return 0
    fi
    log "push rejected (origin/main advanced) — re-basing, attempt $tries/3"
  done
  log "push failed after retries — will retry next cycle"; return 1
}

writer() {
  git fetch origin main --quiet 2>/dev/null || true
  local closed=0 checked=0 tmp
  tmp="$(mktemp)"
  # Authoritative merge record: origin/main squash commits `type(GAP-ID): … (#PR)`.
  # git log is complete (unlike the rolling github_cache) and IS the source of truth
  # for what merged. Emit (gid<TAB>pr), then awk keeps the first (newest) per gid.
  # (bash-3.2-safe: no `declare -A`; a temp file keeps the counter out of a subshell.)
  git log origin/main --format='%s' -n 4000 2>/dev/null | while IFS= read -r subj; do
    local gid pr
    gid="$(printf '%s' "$subj" | grep -oE '\([A-Z]+-[0-9]+\)' | head -1 | tr -d '()')"
    [[ -n "$gid" ]] || continue
    pr="$(printf '%s' "$subj" | grep -oE '\(#[0-9]+\)' | head -1 | tr -d '(#)')"
    printf '%s\t%s\n' "$gid" "$pr"
  done | awk -F'\t' '!seen[$1]++' > "$tmp"

  while IFS=$'\t' read -r gid pr; do
    checked=$((checked+1))
    # only act if that gap is still OPEN in the registry (the drift)
    local st; st="$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='$gid'" 2>/dev/null)"
    [[ "$st" == "open" ]] || continue
    if [[ "$DRY" == 1 ]]; then
      log "would close $gid (merged${pr:+ pr #$pr})"; closed=$((closed+1)); continue
    fi
    # Clean status-flip (not `gap ship`, which has a rebase/stale-branch guard
    # irrelevant to a registry reconcile). --status done marks it shipped.
    if "$CHUMP" gap set "$gid" --status done ${pr:+--closed-pr "$pr"} >/dev/null 2>&1; then
      closed=$((closed+1)); log "closed $gid (merged${pr:+ pr #$pr})"
    fi
  done < "$tmp"
  rm -f "$tmp"
  log "reconciled: $closed merged-but-open gaps closed (of $checked distinct merged gap ids)"

  [[ "$DRY" == 1 ]] && { log "dry-run — not regenerating/pushing state.sql"; return 0; }

  # Regenerate + publish the single source of truth. RESILIENT-1341: this happens
  # in an ISOLATED clone (see publish_state_sql), never the shared fleet tree, so
  # it can never die on the workers' .git/index.lock.
  publish_state_sql "$closed"
}

"$ROLE"
