#!/usr/bin/env bash
# chump-commit.sh — explicit-file commit wrapper.
#
# Purpose: stop the "pre-staged WIP from another agent leaks into my commit"
# stomp that shared worktrees produce. Standard `git add foo.rs && git
# commit` includes ANYTHING already staged by any other session. This
# wrapper reset-staged-everything, stages ONLY the files you name, then
# commits — so another agent's in-flight `git add` can't ride along.
#
# Usage:
#   scripts/coord/chump-commit.sh <file1> [file2 ...] -m "message"
#   scripts/coord/chump-commit.sh <file1> [file2 ...] -F <msg-file>
#
# The `--` separator is optional; all paths before -m/-F/-F are the
# files to commit. Everything after -m/-F is passed through to git commit.
#
# Example:
#   scripts/coord/chump-commit.sh src/foo.rs docs/bar.md -m "feat(bar): ..."
#
# Environment:
#   CHUMP_ALLOW_MAIN_WORKTREE=1  suppress the "you're in the main worktree"
#                                warning. Recommended for CI and one-off
#                                scripts; bot sessions should get their
#                                own `.claude/worktrees/<name>/` instead.

set -euo pipefail

# INFRA-1600: brew util-linux flock not on default PATH on self-hosted CI runners.
# shellcheck source=../lib/discover-flock.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"


# INFRA-956: default harness to a schema-valid value (kills missing_attribution noise).
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

# INFRA-379: heal a wedged chump binary before any CLI call (see
# scripts/lib/chump-preflight.sh). Silent no-op on healthy binaries.
# shellcheck source=../lib/chump-preflight.sh
# shellcheck disable=SC1091  # dynamic path; source target verified above
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/chump-preflight.sh"

# ── Escalation mode (INFRA-AGENT-ESCALATION) ─────────────────────────────────
# When called with --escalate "reason", emit an ALERT kind=escalation event to
# .chump-locks/ambient.jsonl and exit 0. This path skips all commit logic and
# is intended for agents that are stuck and need operator attention.
#
# Usage:
#   scripts/coord/chump-commit.sh --escalate "cargo check fails: error[E0499]" \
#       --gap INFRA-FOO-001 \
#       [--agent-id <id>] \
#       [--suggested-action "human review needed"]
if [[ "${1:-}" == "--escalate" ]]; then
    shift
    ESCALATE_REASON="${1:-unspecified}"
    shift || true

    # Optional keyword args after the reason.
    ESCALATE_GAP=""
    ESCALATE_AGENT_ID=""
    ESCALATE_SUGGESTED_ACTION="human review needed"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gap)        shift; ESCALATE_GAP="$1"        ;;
            --agent-id)   shift; ESCALATE_AGENT_ID="$1"   ;;
            --suggested-action) shift; ESCALATE_SUGGESTED_ACTION="$1" ;;
            *) ;;
        esac
        shift || true
    done

    # INFRA-109: resolve LOCK_DIR via main-repo path so the escalation
    # event lands in the SHARED ambient.jsonl, not the worktree-local one.
    _ESC_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _ESC_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$_ESC_GIT_COMMON" == ".git" ]]; then
        _ESC_MAIN_REPO="$_ESC_REPO_ROOT"
    else
        _ESC_MAIN_REPO="$(cd "$_ESC_GIT_COMMON/.." 2>/dev/null && pwd || echo "$_ESC_REPO_ROOT")"
    fi
    _ESC_LOCK_DIR="$_ESC_MAIN_REPO/.chump-locks"
    _ESC_AMBIENT="$_ESC_LOCK_DIR/ambient.jsonl"
    mkdir -p "$_ESC_LOCK_DIR"

    # Resolve session ID (same precedence as atomic_claim::derive_session_id).
    _ESC_SESSION="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    if [[ -z "$_ESC_SESSION" ]]; then
        _ESC_WT_CACHE="$_ESC_LOCK_DIR/.wt-session-id"
        [[ -f "$_ESC_WT_CACHE" ]] && _ESC_SESSION="$(cat "$_ESC_WT_CACHE" 2>/dev/null || true)"
    fi
    if [[ -z "$_ESC_SESSION" && -f "$HOME/.chump/session_id" ]]; then
        _ESC_SESSION="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
    fi
    _ESC_SESSION="${_ESC_SESSION:-escalate-$$-$(date +%s)}"

    _ESC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Build JSON and append to ambient.jsonl.
    _ESC_JSON="$(python3 -c "
import json, sys
d = {
    'ts':               sys.argv[1],
    'session':          sys.argv[2],
    'event':            'ALERT',
    'kind':             'escalation',
    'gap_id':           sys.argv[3],
    'agent_id':         sys.argv[4],
    'stuck_at':         sys.argv[5],
    'last_error':       sys.argv[5],
    'suggested_action': sys.argv[6],
}
print(json.dumps(d))
" "$_ESC_TS" "$_ESC_SESSION" "${ESCALATE_GAP:-}" "${ESCALATE_AGENT_ID:-$_ESC_SESSION}" "$ESCALATE_REASON" "$ESCALATE_SUGGESTED_ACTION")"

    # Try ambient-emit.sh if available, otherwise direct append.
    _ESC_EMIT="$_ESC_REPO_ROOT/scripts/dev/ambient-emit.sh"
    if [[ -x "$_ESC_EMIT" ]]; then
        printf '%s\n' "$_ESC_JSON" | "$_ESC_EMIT" 2>/dev/null || printf '%s\n' "$_ESC_JSON" >> "$_ESC_AMBIENT"
    else
        _ESC_TMP="$(mktemp "$_ESC_LOCK_DIR/.escalate_XXXXXX")"
        printf '%s\n' "$_ESC_JSON" >> "$_ESC_TMP"
        cat "$_ESC_TMP" >> "$_ESC_AMBIENT"
        rm -f "$_ESC_TMP"
    fi

    echo "[chump-commit] ESCALATION emitted to ambient.jsonl" >&2
    printf '[broadcast] ALERT   kind=escalation  gap=%s  reason=%s\n' "${ESCALATE_GAP:-}" "$ESCALATE_REASON"
    exit 0
fi

# ── Post-ship guard (INFRA-BOT-MERGE-LOCK) ───────────────────────────────────
# bot-merge.sh writes .bot-merge-shipped on successful PR ship to enforce the
# "PR frozen once shipped" rule (PR #52 retrospective). Any further commits
# would be dropped by GitHub's squash-merge, repeating the same data-loss.
# Bypass only when you genuinely need to e.g. fix a CI script in-place and
# know what you are doing — not for "just one more small thing".
_repo_root_early="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$_repo_root_early" && -f "$_repo_root_early/.bot-merge-shipped" ]] \
   && [[ "${CHUMP_POST_SHIP_COMMIT:-0}" != "1" ]]; then
    echo "[chump-commit] ERROR: This worktree has already been shipped." >&2
    echo "[chump-commit]   $(cat "$_repo_root_early/.bot-merge-shipped")" >&2
    echo "" >&2
    echo "[chump-commit] Do NOT push more commits to an in-flight PR — they will be" >&2
    echo "[chump-commit] silently dropped by GitHub squash-merge (see PR #52 post-mortem)." >&2
    echo "" >&2
    echo "[chump-commit] To do more work: open a new worktree for a new gap." >&2
    echo "[chump-commit]   git worktree add .claude/worktrees/<new-name> -b claude/<new-name>" >&2
    echo "" >&2
    echo "[chump-commit] Bypass (dangerous): CHUMP_POST_SHIP_COMMIT=1 scripts/coord/chump-commit.sh ..." >&2
    exit 1
fi

if [[ $# -lt 2 ]]; then
  sed -n '2,25p' "$0"
  exit 2
fi

# Split args into files and git-commit passthroughs.
FILES=()
GIT_ARGS=()
SEEN_DIVIDER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|-F|--message|--file|-C|--reedit-message|--reuse-message|--amend|--signoff|-s|--no-edit|--allow-empty|--allow-empty-message|-n|--no-verify)
      SEEN_DIVIDER=1
      GIT_ARGS+=("$1")
      if [[ "$1" == "-m" || "$1" == "-F" || "$1" == "--message" || "$1" == "--file" || "$1" == "-C" ]]; then
        shift
        GIT_ARGS+=("$1")
      fi
      ;;
    --)
      SEEN_DIVIDER=1
      ;;
    *)
      if [[ $SEEN_DIVIDER -eq 0 ]]; then
        FILES+=("$1")
      else
        GIT_ARGS+=("$1")
      fi
      ;;
  esac
  shift || true
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no files given before -m/-F" >&2
  exit 2
fi

# INFRA-1834: --no-verify audit guard. When the caller passes --no-verify
# (or short form -n), require CHUMP_NO_VERIFY_REASON='<non-empty text>' env
# and emit an audit event so the bypass is auditable. The hook bypass IS
# the operator's escape hatch (CLAUDE.md hard rule: "--no-verify is the
# reason most regressions ship") — we don't block it, we just demand a
# reason and log it. Run this check BEFORE the git commit fires so a
# reasonless --no-verify exits fast.
_chump_no_verify_used=0
for _a in "${GIT_ARGS[@]}"; do
  if [[ "$_a" == "--no-verify" || "$_a" == "-n" ]]; then
    _chump_no_verify_used=1
    break
  fi
done
if [[ "$_chump_no_verify_used" == "1" ]]; then
  _reason="${CHUMP_NO_VERIFY_REASON:-}"
  # Trim leading whitespace (the trailing trim happens naturally in the test).
  _reason_trimmed="${_reason#"${_reason%%[![:space:]]*}"}"
  _reason_trimmed="${_reason_trimmed%"${_reason_trimmed##*[![:space:]]}"}"
  if [[ -z "$_reason_trimmed" ]]; then
    echo "[chump-commit] INFRA-1834: --no-verify requires CHUMP_NO_VERIFY_REASON='<text>' env (empty/whitespace rejected)." >&2
    echo "[chump-commit] Example: CHUMP_NO_VERIFY_REASON='hook hung 90s; emergency push for INFRA-XXXX rescue' bash scripts/coord/chump-commit.sh ..." >&2
    exit 3
  fi
  # Emit audit event to BOTH the ambient stream and the dedicated audit log
  # so the operator's daily reviewer (planned in INFRA-1834 AC #6) can grep
  # one file and a dashboards can subscribe to the kind on ambient.
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _session="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
  _branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  _root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  _gitdir="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)"
  if [[ "$_gitdir" == ".git" ]]; then
    _main="$_root"
  else
    _main="$(cd "$_gitdir/.." 2>/dev/null && pwd)"
  fi
  _locks="$_main/.chump-locks"
  mkdir -p "$_locks" 2>/dev/null || true
  _reason_esc="${_reason_trimmed//\\/\\\\}"
  _reason_esc="${_reason_esc//\"/\\\"}"
  _line="{\"ts\":\"$_ts\",\"kind\":\"audit_no_verify\",\"session\":\"$_session\",\"branch\":\"$_branch\",\"caller\":\"chump-commit.sh\",\"reason\":\"$_reason_esc\"}"
  printf '%s\n' "$_line" >> "$_locks/ambient.jsonl"
  printf '%s\n' "$_line" >> "$_locks/no-verify-audit.jsonl"
  echo "[chump-commit] INFRA-1834: --no-verify bypass logged (reason: $_reason_trimmed)" >&2
fi

# INFRA-109: resolve REPO_ROOT + LOCK_DIR via main-repo path (linked worktree safe).
# Note: cd "$REPO_ROOT" below is intentional — chump-commit.sh stages files
# in the CURRENT worktree (whatever the caller's checkout is), not the main
# repo. REPO_ROOT here is the local worktree; LOCK_DIR (set by repo-paths.sh)
# is the main-repo .chump-locks/.
# shellcheck source=../lib/repo-paths.sh
# shellcheck disable=SC1091  # dynamic path; source target verified above
source "$(dirname "$0")/../lib/repo-paths.sh"
cd "$REPO_ROOT"

# ZERO-WASTE-134: ONE cargo target resolver (scripts/ci/lib/resolve-cargo-target-dir.sh).
# $CARGO_TARGET_DIR > $CHUMP_CARGO_TARGET > ~/.cargo/chump-shared-target. Never a
# path inside the worktree: the old INFRA-1374 per-worktree default grew a private
# 2.4-3 GB build dir in every worktree (4 dirs, 10 GiB measured 2026-10-17) because
# the hook path does not inherit the agent's shell. Prints one line per commit.
# shellcheck source=../ci/lib/resolve-cargo-target-dir.sh
# shellcheck disable=SC1091
if [[ -f "$(dirname "$0")/../ci/lib/resolve-cargo-target-dir.sh" ]]; then
    source "$(dirname "$0")/../ci/lib/resolve-cargo-target-dir.sh"
    chump_export_cargo_target_dir
fi

# Warn (non-blocking) when operating in the main checkout. Separate
# worktrees are the long-term fix for the shared-worktree stomp class.
MAIN_WORKTREE="/Users/jeffadkins/Projects/Chump"
if [[ "$REPO_ROOT" == "$MAIN_WORKTREE" && -z "${CHUMP_ALLOW_MAIN_WORKTREE:-}" ]]; then
  echo "[chump-commit] WARNING: operating in the main worktree ($REPO_ROOT)." >&2
  echo "[chump-commit] Consider using .claude/worktrees/<name>/ for bot sessions." >&2
  echo "[chump-commit] Suppress this warning: CHUMP_ALLOW_MAIN_WORKTREE=1" >&2
fi

# ── Git index mutex (META-011) ─────────────────────────────────────────────────
# Serialize git reset/add/commit across concurrent agents sharing the same
# worktree. Without this, two concurrent chump-commit.sh calls can interleave
# their git-reset and git-add calls, causing one agent to unstage another
# agent's in-flight changes (silently producing an empty or wrong commit).
#
# Uses a dedicated mutex file (.chump-index-mutex in the git dir) rather than
# locking .git/index directly — git uses .git/index.lock for its own internal
# locking and we must not interfere with that mechanism.
#
# Uses $(git rev-parse --git-dir) instead of $REPO_ROOT/.git because linked
# worktrees have .git as a FILE (not a directory) — the actual git dir is
# e.g. $MAIN_REPO/.git/worktrees/<name>/. BUG: previous code used
# $REPO_ROOT/.git which failed on linked worktrees (CREDIBLE-017 session,
# 2026-05-10). Fixed in INFRA-793.
#
# flock(1) is available on Linux (util-linux); BSD/macOS ships without it.
# Fallback: print a warning and proceed unprotected. Still safe when only one
# agent operates in a given worktree (the recommended discipline), and linked
# worktrees each have their own .git/index so the race doesn't cross trees.
#
# The lock FD (200) is inherited by `exec git commit` at the end of this
# script, so it remains held for the entire reset → add → commit sequence and
# is released when git exits.
#
# Bypass: CHUMP_INDEX_LOCK=0
_INDEX_MUTEX="$(git rev-parse --git-dir)/.chump-index-mutex"

if [[ "${CHUMP_INDEX_LOCK:-1}" != "0" ]] && command -v "$FLOCK_BIN" >/dev/null 2>&1; then
    exec 200>>"$_INDEX_MUTEX"
    if ! "$FLOCK_BIN" -w 30 200; then
        echo "[chump-commit] ERROR: could not acquire git index mutex after 30s." >&2
        echo "[chump-commit]   Another agent is committing to this worktree." >&2
        echo "[chump-commit]   Retry once that commit completes." >&2
        echo "[chump-commit]   Bypass (removes serialization): CHUMP_INDEX_LOCK=0" >&2
        exit 1
    fi
elif [[ "${CHUMP_INDEX_LOCK:-1}" != "0" ]]; then
    echo "[chump-commit] WARNING: flock(1) not found — git index unprotected." >&2
    echo "[chump-commit]   Install util-linux for concurrent-commit safety on Linux." >&2
    echo "[chump-commit]   Safe to ignore on single-agent or isolated-worktree setups." >&2
fi

# Verify every file the user named actually exists OR is a deletion.
for f in "${FILES[@]}"; do
  if [[ ! -e "$f" ]]; then
    # Might be a staged deletion; check git.
    if ! git ls-files --deleted --modified --others --cached -- "$f" | grep -q .; then
      echo "ERROR: $f not found and not in git index" >&2
      exit 2
    fi
  fi
done

# If there's a current index that doesn't match the files we want, reset it
# all first. Preserves working-tree changes — only touches the index.
# Using a while-read loop rather than `mapfile` because macOS ships bash 3.2
# which predates the builtin.
STAGED_BEFORE=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$STAGED_BEFORE" ]]; then
  EXTRA=()
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    keep=0
    for w in "${FILES[@]}"; do
      if [[ "$h" == "$w" ]]; then keep=1; break; fi
    done
    [[ $keep -eq 0 ]] && EXTRA+=("$h")
  done <<< "$STAGED_BEFORE"
  if [[ ${#EXTRA[@]} -gt 0 ]]; then
    echo "[chump-commit] Un-staging files you didn't ask to commit:" >&2
    for e in "${EXTRA[@]}"; do echo "  - $e" >&2; done
    git reset HEAD -- "${EXTRA[@]}" >/dev/null
  fi
fi

# Stage exactly the files the user named.
git add -- "${FILES[@]}"

# ── Ambient glance (INFRA-083) ───────────────────────────────────────────────
# Before locking in the commit, scan ambient.jsonl for sibling sessions that
# recently edited any of the staged paths. Advisory only here (the pre-commit
# hook's lease-collision guard is the hard gate); this surfaces near-misses
# the lease layer can't see (e.g. a sibling without a path-lease).
# shellcheck disable=SC2034  # reserved for future caller-relative path; glance currently uses REPO_ROOT
SCRIPT_DIR_GLANCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" ]] && [[ "${CHUMP_AMBIENT_GLANCE:-1}" != "0" ]]; then
    _STAGED_CSV="$(IFS=,; printf '%s' "${FILES[*]}")"
    "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" --paths "$_STAGED_CSV" --since-secs 600 --limit 5 || true
fi

# Wrong-worktree guard (2026-04-18 incident): if NONE of the named files
# actually have changes in this worktree (staged or unstaged), the commit
# will be empty — usually because the user's edits landed in a DIFFERENT
# worktree (typical when a python script with absolute paths writes to
# /Users/jeffadkins/Projects/Chump while the user is in a worktree).
# Detect by re-checking after the add: if the index is unchanged from
# HEAD on every named file, something's off.
if [[ "${CHUMP_WRONG_WORKTREE_CHECK:-1}" != "0" ]]; then
  any_changed=0
  for f in "${FILES[@]}"; do
    if ! git diff --cached --quiet -- "$f" 2>/dev/null; then
      any_changed=1
      break
    fi
  done
  if [[ $any_changed -eq 0 ]]; then
    echo "[chump-commit] WARNING: none of the named files have any changes in this worktree." >&2
    echo "[chump-commit]   pwd: $(pwd)" >&2
    # Look for the same paths in other worktrees that DO have changes.
    while IFS= read -r wt; do
      [[ -z "$wt" ]] && continue
      [[ "$wt" == "$REPO_ROOT" ]] && continue
      [[ ! -d "$wt" ]] && continue
      for f in "${FILES[@]}"; do
        if [[ -f "$wt/$f" ]] && (cd "$wt" && ! git diff --quiet -- "$f" 2>/dev/null); then
          echo "[chump-commit]   ⚠️  found unstaged changes for $f in: $wt" >&2
          echo "[chump-commit]      → run from that worktree, or copy the file in." >&2
        fi
      done
    done < <(git worktree list --porcelain | awk '/^worktree / { print $2 }')
    echo "[chump-commit] Bypass: CHUMP_WRONG_WORKTREE_CHECK=0 git commit ..." >&2
    exit 1
  fi
fi

# ── Path-lease conflict advisory (INFRA-FILE-LEASE) ──────────────────────────
# Check staged files against ALL active lease files in .chump-locks/. If a
# staged file appears in another session's `paths` list, print a CONFLICT
# warning. Advisory only — does not block the commit — so agents can still
# ship when they're certain the overlap is safe.
#
# Bypass: CHUMP_LEASE_CHECK=0
if [[ "${CHUMP_LEASE_CHECK:-1}" != "0" ]]; then
    LOCKS_DIR="$REPO_ROOT/.chump-locks"
    if [[ -d "$LOCKS_DIR" ]]; then
        # Resolve my session ID (same priority order as atomic_claim::derive_session_id).
        _MY_SID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
        if [[ -z "$_MY_SID" ]]; then
            _WT_CACHE="$LOCKS_DIR/.wt-session-id"
            [[ -f "$_WT_CACHE" ]] && _MY_SID="$(cat "$_WT_CACHE")"
        fi
        if [[ -z "$_MY_SID" ]] && [[ -f "$HOME/.chump/session_id" ]]; then
            _MY_SID="$(head -n1 "$HOME/.chump/session_id" 2>/dev/null | tr -d '[:space:]')"
        fi

        if [[ -n "$_MY_SID" ]]; then
            _STAGED_FILES="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
            if [[ -n "$_STAGED_FILES" ]]; then
                _now_epoch="$(date -u +%s)"
                _path_conflicts=""

                for _lease in "$LOCKS_DIR"/*.json; do
                    [[ -f "$_lease" ]] || continue

                    _holder="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_lease" | head -n1)"
                    [[ -n "$_holder" ]] || continue
                    [[ "$_holder" = "$_MY_SID" ]] && continue

                    # Skip expired leases.
                    _expires="$(sed -n 's/.*"expires_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_lease" | head -n1)"
                    _exp_epoch=""
                    if [[ -n "$_expires" ]]; then
                        if [[ "$(uname -s)" = "Darwin" ]]; then
                            _exp_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_expires" +%s 2>/dev/null || true)"
                        else
                            _exp_epoch="$(date -u -d "$_expires" +%s 2>/dev/null || true)"
                        fi
                    fi
                    if [[ -n "$_exp_epoch" ]] && [[ "$_exp_epoch" -le "$_now_epoch" ]]; then
                        continue
                    fi

                    # Extract paths[] from lease JSON (handles pretty-printed and compact).
                    _lease_paths="$(awk '
                        /"paths"[[:space:]]*:/ { flag=1 }
                        flag            { print }
                        flag && /\]/    { flag=0 }
                    ' "$_lease" \
                        | grep -oE '"[^"]+"' \
                        | sed 's/^"//;s/"$//' \
                        | grep -vx 'paths' || true)"

                    [[ -n "$_lease_paths" ]] || continue

                    # Check each lease path against staged files.
                    while IFS= read -r _lpat; do
                        [[ -n "$_lpat" ]] || continue
                        while IFS= read -r _staged; do
                            [[ -n "$_staged" ]] || continue
                            # Exact match or prefix match (foo/bar/ prefix).
                            _matched=0
                            if [[ "$_lpat" = "$_staged" ]]; then
                                _matched=1
                            elif [[ "${_lpat%/}" != "$_lpat" ]]; then
                                # Trailing slash → prefix match.
                                case "$_staged" in
                                    "${_lpat}"*) _matched=1 ;;
                                esac
                            elif [[ "${_lpat%/\*\*}" != "$_lpat" ]]; then
                                # foo/bar/** → prefix match on foo/bar/.
                                _pfx="${_lpat%/\*\*}/"
                                case "$_staged" in
                                    "${_pfx}"*) _matched=1 ;;
                                esac
                            fi
                            if [[ "$_matched" = "1" ]]; then
                                _path_conflicts="${_path_conflicts}  ${_staged}  (claimed by session ${_holder} in $(basename "$_lease"))\n"
                            fi
                        done <<< "$_STAGED_FILES"
                    done <<< "$_lease_paths"
                done

                if [[ -n "$_path_conflicts" ]]; then
                    echo "[chump-commit] PATH-LEASE CONFLICT (advisory) — staged file(s) claimed by another session:" >&2
                    printf '%b' "$_path_conflicts" >&2
                    echo "[chump-commit]" >&2
                    echo "[chump-commit] This is advisory — the commit is NOT blocked. Proceed if you are certain" >&2
                    echo "[chump-commit] the overlap is safe, or coordinate with the other session first." >&2
                    echo "[chump-commit] To silence: CHUMP_LEASE_CHECK=0 scripts/coord/chump-commit.sh ..." >&2
                fi
            fi
        fi
    fi
fi

# ── INFRA-085: auto-write lease from gap-IDs in commit message ───────────────
# The third bypass-path closure (after INFRA-236 commit-subject closer and
# INFRA-237 bot-merge.sh --gap auto-derive). Manual-ship paths (gh pr
# create after chump-commit.sh) used to skip gap claiming entirely, leaving
# no lease for siblings to see — they could pick the same gap and both
# sessions would silently race. This block parses the commit message we're
# about to pass to git, extracts gap-IDs, and idempotently writes a lease
# for each before the commit lands. chump claim is no-op when this session
# already holds the gap.
#
# Disable: CHUMP_AUTO_LEASE_FROM_MSG=0
if [[ "${CHUMP_AUTO_LEASE_FROM_MSG:-1}" != "0" ]]; then
    # Reconstruct the commit message text from GIT_ARGS:
    #   -m "msg"             → next arg is literal message
    #   -F path              → read message from file
    #   --message / --file   → same shape, less common
    # Editor / -C / --amend  → skip (rare in bot workflow; lease is
    #                          best-effort, not load-bearing)
    _commit_msg_text=""
    _next_is_msg=0
    _next_is_file=0
    for _a in "${GIT_ARGS[@]}"; do
        if [[ $_next_is_msg -eq 1 ]]; then
            _commit_msg_text+="$_a"$'\n'
            _next_is_msg=0
            continue
        fi
        if [[ $_next_is_file -eq 1 ]]; then
            if [[ -r "$_a" ]]; then
                _commit_msg_text+="$(cat "$_a")"$'\n'
            fi
            _next_is_file=0
            continue
        fi
        case "$_a" in
            -m|--message) _next_is_msg=1 ;;
            -F|--file)    _next_is_file=1 ;;
        esac
    done
    if [[ -n "$_commit_msg_text" ]]; then
        # INFRA-1059: derive known domain prefixes from state.db to avoid
        # matching non-gap tokens like SHA-256, P0-1, HTTP-200. Fall back to
        # a hard-coded list if sqlite3 or state.db is unavailable.
        _state_db="$REPO_ROOT/.chump/state.db"
        _known_prefixes=""
        if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_state_db" ]]; then
            # RESILIENT-065-class guard: an empty/uninitialized state.db (no
            # `gaps` table — e.g. a fresh worktree checkout) makes sqlite3
            # exit non-zero; under `set -euo pipefail` that silently aborts
            # this script before it ever reaches `git commit`. `|| true`
            # keeps the fallback prefix list path (below) reachable instead.
            _known_prefixes=$( (sqlite3 "$_state_db" \
                "SELECT DISTINCT substr(id,1,instr(id,'-')-1) FROM gaps;" 2>/dev/null \
                | tr '\n' '|' | sed 's/|$//') || true)
        fi
        if [[ -z "$_known_prefixes" ]]; then
            _known_prefixes="INFRA|CREDIBLE|EFFECTIVE|RESILIENT|EVAL|COG|DOC|FLEET|META|PRODUCT|SMOKE|ACP|AGT|AUTO|COMP|FRONTIER|MEM|QUALITY|RELIABILITY|RESEARCH|SECURITY|SENSE|SWARM|UX"
        fi
        # Extract gap-IDs (e.g. INFRA-127, RESEARCH-026) — both leading
        # "INFRA-127:" and inline "Closes INFRA-127" patterns.
        _gap_ids=$(echo "$_commit_msg_text" | grep -oE "(${_known_prefixes})-[0-9]+" | sort -u || true)
        if [[ -n "$_gap_ids" ]]; then
            for _gid in $_gap_ids; do
                # Only attempt to claim gaps that exist on origin/main
                # (avoid spurious claims on filing PRs that just-reserved
                # IDs the local DB hasn't synced). chump claim has its
                # own preflight that handles the not-yet-on-main case
                # gracefully via CHUMP_ALLOW_UNREGISTERED_GAP, so we
                # just call it and let it decide. Output goes to /dev/null
                # — this is best-effort, not load-bearing.
                chump claim "$_gid" >/dev/null 2>&1 || true
            done
            echo "[chump-commit] auto-leased gap(s) from commit message: $(echo "$_gap_ids" | tr '\n' ' ')" >&2
        fi
    fi
fi

# ── INFRA-1467: auto-inject bypass trailers when CHUMP_*_BYPASS env vars set ──
# Each bypass env var has a documented trailer convention. Operators were
# manually `git commit --amend --trailer ...`ing after every blocked commit.
# Auto-inject the trailer when the bypass env is set + the trailer isn't
# already present. Idempotent and reason-less by default; operator can
# override via CHUMP_BYPASS_REASON="<text>".
#
# Mapping (env var → trailer):
#   CHUMP_BYPASS_BOT_MERGE=1       → Bot-Merge-Bypass: <reason>
#   CHUMP_TEST_GATE=0              → Test-Gate-Bypass: <reason>
#   CHUMP_RUST_FIRST_CHECK=0       → Rust-First-Bypass: <reason>
#   CHUMP_HARDCODED_DATE_CHECK=0   → Hardcoded-Date-Bypass: <reason>
_bypass_reason="${CHUMP_BYPASS_REASON:-bypass env set in commit invocation}"
_inject_trailer() {
    # $1 = env-var, $2 = trailer-name, $3 = positive value ("1" or "0")
    local var="$1" trailer="$2" positive="$3"
    local cur="${!var:-}"
    [[ "$cur" != "$positive" ]] && return 0
    # Walk GIT_ARGS for -m / --message; append trailer if not already present.
    local i
    for ((i=0; i<${#GIT_ARGS[@]}; i++)); do
        case "${GIT_ARGS[$i]}" in
            -m|--message)
                local idx=$((i+1))
                if [[ $idx -lt ${#GIT_ARGS[@]} ]]; then
                    local msg="${GIT_ARGS[$idx]}"
                    if ! grep -qE "^${trailer}:" <<<"$msg"; then
                        # Append a blank line + trailer (trailer block convention).
                        msg="${msg}"$'\n\n'"${trailer}: ${_bypass_reason}"
                        GIT_ARGS[idx]="$msg"
                        echo "[chump-commit] INFRA-1467: auto-injected ${trailer}: (${var}=${cur})" >&2
                    fi
                fi
                return 0
                ;;
        esac
    done
}
_inject_trailer "CHUMP_BYPASS_BOT_MERGE"      "Bot-Merge-Bypass"     "1"
_inject_trailer "CHUMP_TEST_GATE"             "Test-Gate-Bypass"     "0"
_inject_trailer "CHUMP_RUST_FIRST_CHECK"      "Rust-First-Bypass"    "0"
_inject_trailer "CHUMP_HARDCODED_DATE_CHECK"  "Hardcoded-Date-Bypass" "0"
unset _bypass_reason
unset -f _inject_trailer

# ── INFRA-1367: stamp COMMIT_EDITMSG before pre-commit hooks run ──────────────
# pre-commit-rust-first.sh (and other hooks) read Rust-First-Bypass: from
# $(git rev-parse --git-common-dir)/COMMIT_EDITMSG. However, git only writes
# that file AFTER pre-commit hooks complete — so inline -m messages are never
# visible to the hook, silently breaking bypass trailers.
#
# Fix: write the inline message ourselves before invoking git. The gate uses
# --git-common-dir so we do too (linked worktrees share the common gitdir and
# git writes COMMIT_EDITMSG there, not to the per-worktree gitdir).
#
# Only -m/--message is handled here; -F/--file paths are already on disk and
# the hook can read them via the path argument. -C/--amend/--reuse-message
# reference an existing commit — git populates COMMIT_EDITMSG from the
# referenced commit before running hooks, so no action is needed.
_GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
_next_is_inline_msg=0
for _ga in "${GIT_ARGS[@]}"; do
    if [[ $_next_is_inline_msg -eq 1 ]]; then
        printf '%s\n' "$_ga" > "$_GIT_COMMON_DIR/COMMIT_EDITMSG"
        _next_is_inline_msg=0
        break
    fi
    case "$_ga" in
        -m|--message) _next_is_inline_msg=1 ;;
    esac
done
unset _next_is_inline_msg _ga _GIT_COMMON_DIR

# INFRA-2205: assign _staged_paths unconditionally so INFRA-1833 / INFRA-1853
# blocks below can reference it safely under set -u regardless of which
# branch the INFRA-1673 preflight check takes.
_staged_paths=$(git diff --cached --name-only 2>/dev/null)

# INFRA-2422: CHUMP_PREFLIGHT_SKIP deleted — the audit block that warned
# when the bypass was used without a Preflight-Skip-Reason trailer is removed.
# preflight now auto-skips only main-RED gates; no bypass env is accepted.

# RESILIENT-065: never silently abort before git commit. With `set -euo pipefail`
# a non-zero anywhere in the auto-fix blocks below (classically a grep-no-match in
# the INFRA-1853 env-var scan when a code commit adds no new CHUMP_* var — the
# COMMON case) kills the script mid-way, leaving files STAGED but uncommitted with
# ZERO output: the "stages but never commits, no error" bug. Armed HERE (after all
# intentional gate-refusals above, which exit <665) so it only guards the
# should-always-commit region; converts any pre-commit abort into a loud diagnostic.
_commit_started=0
_chump_commit_exit_trap() {
    local _rc=$?
    if [[ "${_commit_started:-0}" != "1" && "$_rc" -ne 0 ]]; then
        echo "[chump-commit] ERROR: aborted (exit $_rc) BEFORE git commit — files are STAGED but NOT committed. Recover: re-run scripts/coord/chump-commit.sh, or commit manually: git commit ${GIT_ARGS[*]:-<your -m args>}" >&2
    fi
}
trap _chump_commit_exit_trap EXIT

# INFRA-1833: auto-fmt-on-commit. Run `cargo fmt --all` BEFORE commit so
# the cargo fmt --check CI gate never fails. Auto-fix beats check-and-fail —
# agents can't bypass what they don't see. Only runs when:
#   - staged delta includes any .rs file (skip for docs-only commits)
#   - cargo is on PATH
#   - CHUMP_AUTO_FMT != "0" (bypass with audit-trail emit)
_has_rust_staged=0
if echo "$_staged_paths" | grep -qE '\.rs$|^Cargo\.(toml|lock)$' 2>/dev/null; then
    _has_rust_staged=1
fi
if [[ "$_has_rust_staged" -eq 1 ]] && command -v cargo >/dev/null 2>&1; then
    if [[ "${CHUMP_AUTO_FMT:-1}" == "0" ]]; then
        _amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"auto_fmt_bypassed","session":"%s","reason":"CHUMP_AUTO_FMT=0"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}" \
            >> "$_amb" 2>/dev/null || true
        echo "[chump-commit] INFRA-1833: skipping cargo fmt (CHUMP_AUTO_FMT=0); audit emitted" >&2
    else
        echo "[chump-commit] INFRA-1833: cargo fmt --all (auto-fix, kills fmt-check CI failures)" >&2
        # RESILIENT-065: bound cargo fmt so cargo package-cache lock contention
        # (many fleet cargo procs) can't hang the commit indefinitely. On timeout
        # (124) or fmt failure, fall through to the non-fatal else and still commit.
        if timeout "${CHUMP_AUTO_FMT_TIMEOUT:-120}" cargo fmt --all 200>&- 2>&1 | tail -3 >&2; then
            # Re-stage any files cargo fmt touched. If nothing changed, this is a no-op.
            git add -A 2>/dev/null || true
            _amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
            mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"auto_fmt_applied","session":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}" \
                >> "$_amb" 2>/dev/null || true
        else
            echo "[chump-commit] INFRA-1833: cargo fmt --all failed (non-fatal); proceeding to commit" >&2
        fi
    fi
fi

# INFRA-1853: auto-append new CHUMP_* env refs to scripts/ci/env-vars-internal.txt.
# Same auto-fix philosophy as INFRA-1833: detect drift at commit-time, fix it
# silently, agent can't bypass what they don't see. Caught ~5× today
# (CHUMP_PREFLIGHT_SKIP_GAPSINT/PRSCOPE/CLAUDELEAK/ENVVARS forgotten allowlists
# → CI env-var-coverage failures).
#
# Scope: only fires when staged delta has .rs/.sh/.py changes (skip docs-only).
# Bypass: CHUMP_AUTO_ENVVAR=0 emits auto_envvar_bypassed audit event.
_envvar_file="${REPO_ROOT}/scripts/ci/env-vars-internal.txt"
_has_code_staged=0
if echo "$_staged_paths" | grep -qE '\.(rs|sh|py)$' 2>/dev/null; then
    _has_code_staged=1
fi
if [[ "$_has_code_staged" -eq 1 ]] && [[ -f "$_envvar_file" ]]; then
    _amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
    if [[ "${CHUMP_AUTO_ENVVAR:-1}" == "0" ]]; then
        printf '{"ts":"%s","kind":"auto_envvar_bypassed","session":"%s","reason":"CHUMP_AUTO_ENVVAR=0"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}" \
            >> "$_amb" 2>/dev/null || true
        echo "[chump-commit] INFRA-1853: skipping auto-envvar-append (CHUMP_AUTO_ENVVAR=0); audit emitted" >&2
    else
        # Extract CHUMP_* refs from staged diff hunks only (not whole files).
        # Restrict to .rs/.sh/.py to avoid noise from docs/comments in markdown.
        _new_envvars=$(
            git diff --cached --no-color -U0 -- '*.rs' '*.sh' '*.py' 2>/dev/null \
              | grep -oE '\bCHUMP_[A-Z][A-Z0-9_]+\b' \
              | sort -u \
              | while read -r ev; do
                    # Skip if already in env-vars-internal.txt (exact-line match
                    # to avoid substring false positives — entries are typically
                    # "CHUMP_FOO" on their own line, possibly trailing comment).
                    if ! grep -qE "^${ev}\b" "$_envvar_file" 2>/dev/null; then
                        echo "$ev"
                    fi
                done
        ) || true   # RESILIENT-065: grep-no-match (commit adds no new CHUMP_*) exits 1 under pipefail; without this guard the bare assignment trips set -e and silently aborts before git commit
        if [[ -n "$_new_envvars" ]]; then
            # Find which staged file(s) introduce each new env (breadcrumb).
            {
                echo ""
                echo "# AUTO (INFRA-1853): chump-commit.sh detected new CHUMP_* env refs."
                echo "# Replace the AUTO marker with a real description on the next commit."
                while read -r ev; do
                    [[ -z "$ev" ]] && continue
                    _origin=$(git diff --cached --no-color -- '*.rs' '*.sh' '*.py' 2>/dev/null \
                        | grep -lE "\b${ev}\b" 2>/dev/null \
                        | head -1 || true)
                    # `git diff -l` gives paths — fall back to grep-on-diff if not.
                    if [[ -z "$_origin" ]]; then
                        _origin=$(git diff --cached --name-only --no-color 2>/dev/null \
                            | while read -r f; do
                                git diff --cached --no-color -- "$f" 2>/dev/null \
                                    | grep -q "\b${ev}\b" && echo "$f" && break
                              done | head -1)
                    fi
                    [[ -z "$_origin" ]] && _origin="(unknown)"
                    echo "# detected in: ${_origin}"
                    echo "${ev}"
                done <<<"$_new_envvars"
            } >> "$_envvar_file"
            git add "$_envvar_file" 2>/dev/null || true
            _count=$(echo "$_new_envvars" | grep -c '.' || true)
            printf '{"ts":"%s","kind":"auto_envvar_applied","session":"%s","count":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}}" \
                "$_count" \
                >> "$_amb" 2>/dev/null || true
            echo "[chump-commit] INFRA-1853: auto-appended $_count new CHUMP_* env(s) to env-vars-internal.txt" >&2
            echo "  $(echo "$_new_envvars" | tr '\n' ' ')" >&2
        fi
    fi
fi

# Commit with the passed-through git args.
# Note: using `git commit` (not `exec`) so that FD 200 (the index mutex) is
# closed and the lock released after git exits. With exec the FD is also
# inherited and released on git exit — both work — but the non-exec form is
# cleaner when callers capture the exit code via $?.
_commit_started=1  # RESILIENT-065: past here the EXIT trap stays silent; a real git-commit failure surfaces its own exit code
# RESILIENT-117: `200>&-` keeps FD 200 (the index mutex) out of git's process tree. Hooks
# spawn cargo/rustc/sccache, and a long-lived daemon inheriting the flock FD kept the
# mutex held after this script exited, blocking commits in sibling worktrees. This
# shell keeps its own FD 200, so the lock is still held for the whole commit.
git commit "${GIT_ARGS[@]}" 200>&-
