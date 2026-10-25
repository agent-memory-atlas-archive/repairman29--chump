#!/usr/bin/env bash
# merge-serializer.sh — RESILIENT-372. Native-merge-queue substitute.
#
# WHY THIS EXISTS
# --------------
# GitHub's native merge queue is a paid-plan (Team/Enterprise) capability and is
# NOT exposed on `repairman29/chump` (a personal-account repo). Three API attempts
# to enable it all failed — see docs/process/MERGE_QUEUE_SETUP.md. Without it, the
# fleet hit this failure mode:
#
#   The sole required check on `main` is `verified` — a slow aggregator. Every time
#   `main` moves under an open PR, armed-pr-rebaser.sh (INFRA-3473) rebases that PR
#   and force-pushes, which RESTARTS `verified` from scratch. With many open PRs and
#   frequent merges, `main` moves constantly, so an individual PR almost never holds
#   one uninterrupted `verified` pass — it ages 10-20h, its check perpetually reset.
#
# THE FIX (serialize the final merge step)
# ----------------------------------------
# Process ONE PR at a time: rebase the single OLDEST viable candidate onto the very
# latest origin/main, wait for ITS `verified` to go green on that rebased head, merge
# it (squash), then loop to the next. Because the serializer only ever rebases the
# ONE candidate it is currently driving — never the whole armed set — the other open
# PRs are left untouched and their `verified` is not reset. Each PR therefore gets a
# clean, undisturbed `verified` pass, exactly as a native merge queue with build
# concurrency 1 would give.
#
# OLDEST-FIRST is deliberate: an aging PR is a bullet. The clock is the priority.
#
# LOCKING
# -------
#   * merge-serializer.lock (flock -n)  — single-instance guard: overlapping timer
#     fires never double-drive a merge. This is the serializer's own global lock.
#   * bot-merge.lock (INFRA-860, reused) — acquired briefly around each MUTATING step
#     (rebase+force-push, and the squash-merge) so a concurrent bot-merge.sh can't
#     race a push/merge. Released during the (potentially minutes-long) `verified`
#     poll so the serializer never starves fleet bot-merge shipping. Main moving
#     under the waiting PR does NOT reset its check (nothing rebases it while we
#     wait — the serializer is the sole rebaser), so releasing the lock during the
#     poll is safe.
#
# COMPANION CHANGE (important): where the serializer runs, chump-armed-rebaser.timer
# (the parallel rebase-everyone organ) should be DISABLED — it is the thing that was
# resetting `verified` on every main move. The serializer supersedes it for the
# BEHIND/clean-rebase case; real-conflict PRs are still emitted for the
# conflict-resolution consumer. See docs/process/MERGE_QUEUE_SETUP.md.
#
# IDEMPOTENT + BOUNDED: one invocation drives up to CHUMP_MERGE_SERIALIZER_MAX_MERGES
# PRs (default 1) then exits; the timer re-fires for the next. Every wait is bounded.
# Respects a trunk-RED gate (skips if main's `verified` is failing or a systemic-red
# shared-gate wedge is active — serializing can't help a globally broken gate).
#
# Usage:
#   scripts/coord/merge-serializer.sh            # drive up to MAX_MERGES PRs, emit, exit 0
#   scripts/coord/merge-serializer.sh --dry-run  # select + report only; no rebase/push/merge
#   scripts/coord/merge-serializer.sh --once      # alias for MAX_MERGES=1 (default)
#
# Env:
#   CHUMP_MERGE_SERIALIZER_DISABLED=1     bypass, exit 0 immediately (no-op)
#   CHUMP_PR_REPO                         repo slug (default repairman29/chump)
#   CHUMP_REPO_ROOT                       main repo checkout (default $HOME/Projects/chump)
#   CHUMP_MERGE_SERIALIZER_MAX_MERGES     PRs to drive per run (default 1)
#   CHUMP_MERGE_SERIALIZER_VERIFY_TIMEOUT_S  verified-green wait budget per PR (default 900)
#   CHUMP_MERGE_SERIALIZER_POLL_S         verified poll interval (default 30)
#   CHUMP_MERGE_SERIALIZER_PR_LIMIT       max open PRs to scan (default 60)
#   CHUMP_MERGE_SERIALIZER_LOCK_WAIT_S    bot-merge.lock acquire wait (default 60)
#   CHUMP_MERGE_SERIALIZER_TRUNK_GATE=0   disable the trunk-RED gate
#   TMPDIR                                worktree scratch root (default honored; NEVER /tmp on CJ)
#
# Events emitted to .chump-locks/ambient.jsonl (source=merge_serializer):
#   merge_serializer_run_started        — candidates=<n>
#   merge_serializer_trunk_red_skip     — reason=verified_failure|systemic_red
#   merge_serializer_selected           — pr, branch, age_h, mergeStateStatus
#   merge_serializer_rebase_conflict    — pr, branch  (real conflict; left for resolver)
#   merge_serializer_verify_timeout     — pr, waited_s
#   merge_serializer_verify_failed      — pr
#   merge_serializer_merged             — pr, branch, waited_verify_s   (the win)
#   merge_serializer_run_completed      — merged=<n>, elapsed_s
#
# CI gate: scripts/ci/test-merge-serializer.sh
set -uo pipefail

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ "${CHUMP_MERGE_SERIALIZER_DISABLED:-0}" == "1" ]]; then
    echo "[merge-serializer] CHUMP_MERGE_SERIALIZER_DISABLED=1 — exiting"
    exit 0
fi

REPO="${CHUMP_PR_REPO:-repairman29/chump}"
ROOT="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
MAX_MERGES="${CHUMP_MERGE_SERIALIZER_MAX_MERGES:-1}"
VERIFY_TIMEOUT_S="${CHUMP_MERGE_SERIALIZER_VERIFY_TIMEOUT_S:-900}"
POLL_S="${CHUMP_MERGE_SERIALIZER_POLL_S:-30}"
PR_LIMIT="${CHUMP_MERGE_SERIALIZER_PR_LIMIT:-60}"
LOCK_WAIT_S="${CHUMP_MERGE_SERIALIZER_LOCK_WAIT_S:-60}"
TRUNK_GATE="${CHUMP_MERGE_SERIALIZER_TRUNK_GATE:-1}"
DRY_RUN=0

for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --once) MAX_MERGES=1 ;;
        --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

cd "$ROOT" 2>/dev/null || { echo "[merge-serializer] repo root not found: $ROOT" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "[merge-serializer] gh not found" >&2; exit 0; }

# Cache-first / throttle-aware GitHub access (INFRA-1081 / INFRA-1274).
# Every GitHub call below is a LIVE, correctness-sensitive merge-queue read or
# write (fresh check-run state on a just-rebased head; the squash/disable-auto
# mutations). They can't be served from the webhook cache — cache_query_open_prs
# lacks createdAt (this organ selects OLDEST-first) and cache_lookup_checks has
# no REST fallback, so a stale/empty read would drive the wrong merge. So we
# route them through chump_gh (scripts/coord/lib/github.sh): the sanctioned
# throttle + secondary-rate-limit-backoff wrapper — NOT raw gh. Fallback to a
# thin wrapper if the lib is unavailable (mirrors chump-pr-nudge.sh).
# shellcheck source=lib/github.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/github.sh" 2>/dev/null || chump_gh() { gh "$@"; }
command -v chump_gh >/dev/null 2>&1 || chump_gh() { gh "$@"; }

# FLOCK_BIN discovery (INFRA-1600) — same helper bot-merge uses.
# shellcheck source=../lib/discover-flock.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh" 2>/dev/null || {
    command -v flock >/dev/null 2>&1 && FLOCK_BIN="$(command -v flock)" || { echo "[merge-serializer] flock unavailable" >&2; exit 0; }
}

# Canonical main-repo lock dir (INFRA-109) — resolve to main repo, not a worktree.
# shellcheck source=../lib/repo-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-paths.sh" 2>/dev/null || {
    MAIN_REPO="$ROOT"; LOCK_DIR="${CHUMP_LOCK_DIR:-$ROOT/.chump-locks}";
}
mkdir -p "$LOCK_DIR" 2>/dev/null || true
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
BOT_MERGE_LOCK="${CHUMP_BOT_MERGE_LOCK_DIR:-$LOCK_DIR}/bot-merge.lock"
SELF_LOCK="$LOCK_DIR/merge-serializer.lock"

# RESILIENT-1563: shared merge-pipeline-driver.lock — every force-push/
# update-branch/pr-merge path acquires this ONE lock or no-ops, so this
# organ can never race another merge-mutation organ on the same branch.
# Distinct from SELF_LOCK above (that one is a single-instance guard against
# an overlapping copy of THIS script; this one is the cross-organ authority).
# shellcheck source=lib/merge-pipeline-lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/merge-pipeline-lock.sh"
# INFRA-8221 (RESILIENT-1613 arm policy): this organ rebases, force-pushes and
# squash-merges directly, bypassing every armer; it must still honor a hold.
# shellcheck source=lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_emit() { # _emit <kind> [extra-json-without-braces]
    local kind="$1" extra="${2:-}" line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$(_ts)\",\"source\":\"merge_serializer\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$(_ts)\",\"source\":\"merge_serializer\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

# ── Single-instance guard (the serializer's own global lock) ────────────────────
exec 201>"$SELF_LOCK" || { echo "[merge-serializer] cannot open self-lock" >&2; exit 0; }
if ! "$FLOCK_BIN" -n 201; then
    echo "[merge-serializer] another instance holds $SELF_LOCK — exiting (idempotent)"
    exit 0
fi

# ── bot-merge.lock (INFRA-860) helpers — brief holds around mutations only ──────
_bm_lock_acquire() { # returns 0 if acquired on fd 200
    exec 200>"$BOT_MERGE_LOCK" 2>/dev/null || return 1
    if "$FLOCK_BIN" -w "$LOCK_WAIT_S" 200; then
        printf '%s %s\n' "$$" "$(date +%s)" > "${BOT_MERGE_LOCK}.holder" 2>/dev/null || true
        return 0
    fi
    exec 200>&- 2>/dev/null || true
    return 1
}
_bm_lock_release() {
    rm -f "${BOT_MERGE_LOCK}.holder" 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
}

# ── Trunk-RED gate ──────────────────────────────────────────────────────────────
# The right signal is "is MAIN itself broken" — main's own latest `verified` run
# failing. We deliberately do NOT gate on systemic-red-detector: on this repo
# `verified` is the SOLE required check, so ">=3 PRs failing verified" is just
# "the backlog is red" (many are DIRTY conflicts whose fix IS a rebase) — not a
# broken shared gate. Using it here would make the serializer skip almost always,
# which defeats the purpose. (Opt in with CHUMP_MERGE_SERIALIZER_SYSTEMIC_GATE=1
# on repos where a systemic-red wedge is a meaningful, distinct signal.)
_trunk_red() {
    [[ "$TRUNK_GATE" == "1" ]] || return 1
    local concl
    concl="$(chump_gh api "repos/$REPO/commits/main/check-runs" \
        --jq '[.check_runs[] | select(.name=="verified")] | sort_by(.started_at) | last | .conclusion // ""' 2>/dev/null || echo "")"
    if [[ "$concl" == "FAILURE" || "$concl" == "TIMED_OUT" || "$concl" == "CANCELLED" ]]; then
        _emit merge_serializer_trunk_red_skip '"reason":"verified_failure"'
        echo "[merge-serializer] trunk RED (main verified=$concl) — skipping"
        return 0
    fi
    if [[ "${CHUMP_MERGE_SERIALIZER_SYSTEMIC_GATE:-0}" == "1" ]]; then
        local srd="$MAIN_REPO/scripts/coord/systemic-red-detector.sh"
        if [[ -x "$srd" ]] && ! CHUMP_REPO_ROOT="$MAIN_REPO" "$srd" --check-only >/dev/null 2>&1; then
            _emit merge_serializer_trunk_red_skip '"reason":"systemic_red"'
            echo "[merge-serializer] systemic-red wedge active (opt-in gate) — skipping"
            return 0
        fi
    fi
    return 1
}

# ── Candidate selection: armed + non-draft open PRs, OLDEST-first ───────────────
# We do NOT hard-require pre-rebase verified=SUCCESS: the rebase re-runs `verified`
# on a fresh head anyway, so a currently-stale/pending check is fine. We do skip
# obvious non-starters (DRAFT). Real conflicts are discovered at rebase time and
# skipped there.
_candidates() {
    chump_gh pr list --repo "$REPO" --state open --limit "$PR_LIMIT" \
        --json number,createdAt,headRefName,mergeStateStatus,autoMergeRequest,isDraft \
        --jq '[ .[]
                | select(.isDraft==false)
                | select(.autoMergeRequest!=null)
                | {n:.number, br:.headRefName, ms:.mergeStateStatus, created:.createdAt} ]
              | sort_by(.created)
              | .[] | "\(.n)\t\(.br)\t\(.ms)\t\(.created)"' 2>/dev/null
}

_age_h() { # ISO8601 -> integer hours old
    local created="$1" now cs
    now="$(date +%s)"; cs="$(date -d "$created" +%s 2>/dev/null || echo "$now")"
    echo $(( (now - cs) / 3600 ))
}

# ── verified poll (bounded), NOT holding bot-merge.lock ─────────────────────────
# stdout = waited-seconds (captured by caller); progress → stderr.
#
# Returns SUCCESS only when the `verified` aggregate is green. Returns FAIL as soon
# as EITHER `verified` itself fails OR any BLOCKING sub-check fails — the aggregate
# `verified` doesn't post FAILURE until every input job finishes, so a PR already
# doomed by one failed required shard would otherwise hold the serializer for the
# full slow-job duration (observed: audit-shard failed at minute 3 but fast-checks
# didn't finish for ~18 more). An aging PR is a bullet — don't burn a whole CI
# cycle on one that can't possibly go green. Blocking = `verified`, any `*-required`
# aggregator, `fast-checks`, or any `audit-shard (N)`. Advisory checks (named
# "(advisory)"/"(non-blocking)") never match, so a flaky advisory can't false-fail.
_verified_state() { # <pr> -> echoes SUCCESS|FAIL|PENDING
    chump_gh pr view "$1" --repo "$REPO" --json statusCheckRollup --jq '
      [.statusCheckRollup[]?] as $c
      | (([$c[]|select(.name=="verified")|(.conclusion // .status)]|first) // "") as $v
      | if $v=="SUCCESS" then "SUCCESS"
        elif ($v|test("FAILURE|TIMED_OUT|CANCELLED|ERROR|ACTION_REQUIRED|STALE|STARTUP_FAILURE")) then "FAIL"
        elif ([ $c[]
                | select(.name|test("-required$|^audit-shard|^fast-checks$|^verified$"))
                | (.conclusion // "")
                | select(test("FAILURE|TIMED_OUT|CANCELLED|ERROR|ACTION_REQUIRED|STARTUP_FAILURE"))
              ]|length > 0) then "FAIL"
        else "PENDING" end' 2>/dev/null || echo "PENDING"
}
_wait_verified() { # <pr>  -> 0 green, 1 failed, 2 timeout
    local pr="$1" start deadline st ms waited
    start="$(date +%s)"; deadline=$(( start + VERIFY_TIMEOUT_S ))
    while true; do
        st="$(_verified_state "$pr")"
        waited=$(( $(date +%s) - start ))
        case "$st" in
            SUCCESS) echo "$waited"; return 0 ;;
            FAIL)    echo "$waited"; return 1 ;;
        esac
        if (( $(date +%s) >= deadline )); then echo "$waited"; return 2; fi
        ms="$(chump_gh pr view "$pr" --repo "$REPO" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "")"
        printf '[merge-serializer] #%s verified=pending ms=%s waited=%ds/%ds\n' \
            "$pr" "$ms" "$waited" "$VERIFY_TIMEOUT_S" >&2
        sleep "$POLL_S"
    done
}

# ── Drive ONE PR: rebase -> wait verified -> squash-merge ───────────────────────
# returns 0 if merged, 1 if skipped (conflict/fail/timeout), 2 if hard error
_drive_pr() {
    local pr="$1" br="$2" ms="$3"
    local wt="${TMPDIR:-/tmp}/merge-serializer-${pr}.$$"

    # INFRA-8221: a held PR (no-auto-merge / hold label, `Auto-merge: hold` line)
    # is never rebased, force-pushed or merged by the serializer. arm_policy_allows
    # emits kind=pr_arm_skipped_hold and logs the reason on stderr.
    if ! arm_policy_allows "$pr" "merge-serializer.sh" "$REPO"; then
        echo "[merge-serializer] #$pr: HELD (arm policy) — refusing to rebase or merge, skipping"
        return 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[merge-serializer] (dry-run) would rebase #$pr ($br) onto origin/main, wait verified, squash-merge"
        return 1
    fi

    # ---- MUTATION 1: rebase + force-push (under merge-pipeline-driver.lock + bot-merge.lock) ----
    # RESILIENT-1563: merge-pipeline-driver.lock is the cross-ORGAN authority
    # (acquired first); bot-merge.lock below remains the pre-existing
    # intra-bot-merge-pipeline guard. No-op (defer to next tick) if either is held.
    if ! merge_pipeline_lock_acquire; then
        echo "[merge-serializer] merge-pipeline-driver.lock held elsewhere for #$pr rebase — no-op (RESILIENT-1563)"
        return 2
    fi
    if ! _bm_lock_acquire; then
        echo "[merge-serializer] could not acquire bot-merge.lock for #$pr rebase — deferring to next tick"
        merge_pipeline_lock_release
        return 2
    fi
    local rebase_ok=0
    # RESILIENT-1537: when a candidate PR is green on checks but BEHIND main
    # (mergeStateStatus == "BEHIND"), run `gh pr update-branch` before merging
    # (falling back to local worktree rebase if update-branch fails).
    if [[ "$ms" == "BEHIND" ]]; then
        echo "[merge-serializer] #$pr mergeStateStatus=BEHIND — running gh pr update-branch before merge (RESILIENT-1537)"
        if chump_gh pr update-branch "$pr" --repo "$REPO" --rebase >/dev/null 2>&1; then
            rebase_ok=1
        fi
    fi
    if [[ "$rebase_ok" != "1" ]]; then
        git fetch origin main --quiet 2>/dev/null || true
        if ! git fetch origin "$br" --quiet 2>/dev/null; then
            _bm_lock_release
            merge_pipeline_lock_release
            echo "[merge-serializer] #$pr fetch $br failed"
            return 1
        fi
        git worktree remove "$wt" --force 2>/dev/null || true
        # -B forces local ref to the freshly-fetched remote tip so we can only ADD
        # commits from main, never drop commits already on the remote branch (RESILIENT-350).
        if git worktree add -B "$br" "$wt" "origin/$br" >/dev/null 2>&1; then
            if ( cd "$wt" && git rebase origin/main >/dev/null 2>&1 \
                 && [[ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]] ); then
                if ( cd "$wt" && git push origin "$br" --force-with-lease --no-verify >/dev/null 2>&1 ); then
                    rebase_ok=1
                fi
            else
                ( cd "$wt" && git rebase --abort 2>/dev/null || true )
            fi
        fi
        git worktree remove "$wt" --force 2>/dev/null || true
    fi
    _bm_lock_release
    merge_pipeline_lock_release

    if [[ "$rebase_ok" != "1" ]]; then
        _emit merge_serializer_rebase_conflict "\"pr\":$pr,\"branch\":\"$br\""
        echo "[merge-serializer] #$pr: rebase not clean (real conflict) — flagged for conflict-resolution, skipping"
        return 1
    fi
    # Disable any armed auto-merge so GitHub can't race-merge this PR the instant
    # verified goes green mid-wait — the serializer is the deterministic merger, so
    # the landing is attributable to it and can't slip out from under the wait.
    chump_gh pr merge "$pr" --repo "$REPO" --disable-auto >/dev/null 2>&1 || true
    echo "[merge-serializer] #$pr: rebased clean onto latest origin/main + pushed — waiting for verified"

    # ---- WAIT: verified green on the rebased head (lock RELEASED) ----
    local waited rc
    waited="$(_wait_verified "$pr")"; rc=$?
    case "$rc" in
        1) _emit merge_serializer_verify_failed "\"pr\":$pr"; echo "[merge-serializer] #$pr: verified FAILED post-rebase — skipping"; return 1 ;;
        2) _emit merge_serializer_verify_timeout "\"pr\":$pr,\"waited_s\":${waited:-0}"; echo "[merge-serializer] #$pr: verified TIMEOUT (${waited}s) — skipping"; return 1 ;;
    esac

    # INFRA-8221: the verified wait can take many minutes; a hold placed during it
    # must still stop the squash-merge. Re-check immediately before the mutation.
    if ! arm_policy_allows "$pr" "merge-serializer.sh" "$REPO"; then
        echo "[merge-serializer] #$pr: HELD (arm policy) while waiting for verified — refusing to squash-merge, skipping"
        return 1
    fi

    # ---- MUTATION 2: squash-merge (under merge-pipeline-driver.lock + bot-merge.lock) ----
    if ! merge_pipeline_lock_acquire; then
        echo "[merge-serializer] #$pr: merge-pipeline-driver.lock held elsewhere — no-op, will retry next tick (RESILIENT-1563)"
        return 2
    fi
    if ! _bm_lock_acquire; then
        echo "[merge-serializer] #$pr: verified green but could not acquire bot-merge.lock to merge — will retry next tick"
        merge_pipeline_lock_release
        return 2
    fi
    local post_ms
    post_ms="$(chump_gh pr view "$pr" --repo "$REPO" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || echo "")"
    if [[ "$post_ms" == "BEHIND" ]]; then
        echo "[merge-serializer] #$pr still BEHIND main after verified green — running gh pr update-branch before merge (RESILIENT-1537)"
        chump_gh pr update-branch "$pr" --repo "$REPO" --rebase >/dev/null 2>&1 || true
    fi
    local merged=0
    if chump_gh pr merge "$pr" --repo "$REPO" --squash >/dev/null 2>&1; then
        merged=1
    else
        # Merge call failed — check whether it already landed (auto-merge race).
        local state
        state="$(chump_gh pr view "$pr" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "")"
        [[ "$state" == "MERGED" ]] && merged=1
    fi
    _bm_lock_release
    merge_pipeline_lock_release

    if [[ "$merged" == "1" ]]; then
        _emit merge_serializer_merged "\"pr\":$pr,\"branch\":\"$br\",\"waited_verify_s\":${waited:-0}"
        echo "[merge-serializer] #$pr: MERGED (squash) under serializer after ${waited}s verified wait ✓"
        return 0
    fi
    echo "[merge-serializer] #$pr: verified green but merge call failed — leaving for next tick"
    return 1
}

# ── Main loop ───────────────────────────────────────────────────────────────────
main() {
    local start; start="$(date +%s)"

    if _trunk_red; then
        _emit merge_serializer_run_completed '"merged":0,"skipped":"trunk_red"'
        exit 0
    fi

    git fetch origin main --quiet 2>/dev/null || true

    mapfile -t rows < <(_candidates)
    local ncand=${#rows[@]}
    _emit merge_serializer_run_started "\"candidates\":$ncand"
    echo "[merge-serializer] $ncand armed candidate(s); driving up to $MAX_MERGES this run (oldest-first)"
    if (( ncand == 0 )); then
        _emit merge_serializer_run_completed '"merged":0'
        echo "[merge-serializer] nothing to do"
        exit 0
    fi

    local merged=0 row pr br ms created ageh
    for row in "${rows[@]}"; do
        (( merged >= MAX_MERGES )) && break
        IFS=$'\t' read -r pr br ms created <<< "$row"
        [[ -z "$pr" ]] && continue
        ageh="$(_age_h "$created")"
        _emit merge_serializer_selected "\"pr\":$pr,\"branch\":\"$br\",\"age_h\":$ageh,\"mergeStateStatus\":\"$ms\""
        echo "[merge-serializer] selected #$pr ($br) age=${ageh}h ms=$ms"
        _drive_pr "$pr" "$br" "$ms"
        case $? in
            0) merged=$(( merged + 1 )) ;;
            2) break ;;  # lock contention / hard error — stop, retry next tick
            *) : ;;      # skipped (conflict/fail/timeout) — try next candidate
        esac
    done

    _emit merge_serializer_run_completed "\"merged\":$merged,\"elapsed_s\":$(( $(date +%s) - start ))"
    echo "[merge-serializer] run complete — merged $merged PR(s)"
    exit 0
}

main "$@"
