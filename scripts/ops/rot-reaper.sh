#!/usr/bin/env bash
# rot-reaper.sh — the NO-ABANDON JANITOR: drive EVERY open fleet PR toward a
# terminal state so nothing can rot (RESILIENT-311 / RESILIENT-324).
#
# THE GUARANTEE (RESILIENT-311, operator law "one way or the other, this queue
# stays managed"): on every beat, each open fleet-authored PR is pushed toward a
# terminal state (MERGED, or CLOSED+requeued) within a bounded time. No PR sits
# abandoned. The classes this organ drives:
#   • CONFLICTING beyond CONFLICT age +
#     conflict-resolution EXHAUSTED         → close + requeue + label rot-reaped
#   • CONFLICTING but resolution NOT yet
#     exhausted (savable)                   → hand off to consumer + DEFER [339]
#   • MERGEABLE but a REQUIRED check has
#     FAILED beyond REALFAIL age           → close + requeue + label rot-reaped
#   • MERGEABLE + green + UNARMED beyond
#     ARM age (minutes)                    → arm auto-merge (backstop the lander)
#   • BEHIND                               → left for chump-armed-rebaser
#   • fresh anything                       → left (owner/CI still working)
# Plus a NO-ABANDON METRIC each beat (kind=pr_no_abandon_backlog): the count of
# open PRs older than the deadline still in a non-terminal state. Target 0.
#
# WHY the label (RESILIENT-311, 2026-08-15 reap/revive deadlock): the rot-reaper
# was closing CONFLICTING PR #3792 every 30 min AND requeuing its gap to `open`
# — but post-push-integrity-watch.sh (a reviver that reopens closed-not-merged
# fleet PRs) saw "closed PR + open gap" as "work lost, reopen it" and reopened
# the dead, unmergeable branch within ~60s. The reaper's close never STUCK: an
# infinite reap↔revive fight, and the PR rotted OPEN forever. The reaper's
# filters were never the problem — its close was being undone. Fix: every reaper
# close now stamps a `rot-reaped` label; revivers skip any PR bearing it (an
# intentional terminal close is not a lost-work incident — a fresh PR comes from
# the requeued gap). The label makes the close terminal.
#
# WHY (operator, 2026-08-14 deadlock): the back-pressure controller
# (scripts/ops/back-pressure-controller.sh) HALTS production when the "stuck
# pile" (open PRs that are BLOCKED or DIRTY) hits HALT_AT (6). It RESUMES when
# the pile drains below RESUME_AT (3). The armed-rebaser
# (scripts/coord/armed-pr-rebaser.sh) drains the pile by rebasing PRs that are
# BEHIND — but it CANNOT resolve a real merge CONFLICT. So when the jam is
# mostly CONFLICTING PRs, the rebaser drains the pile partway (to 4–5), it
# lands in the 3–6 hysteresis dead-zone, and the fleet stays HALTED forever
# with no auto-recovery. That is exactly what deadlocked the fleet for hours.
#
# This organ is the missing drain: it CLOSES open PRs that are truly
# CONFLICTING and old enough that they are never going to auto-rebase, and
# RE-QUEUES their gap so the fleet re-does the work cleanly on fresh main. A
# CONFLICTING PR represents work that must be redone anyway (the branch and
# main diverged in the same lines); reaping it loses nothing and unblocks the
# breaker.
#
# What it does, per open PR authored by the fleet:
#   1. Skip filing PRs ("chore(gaps): file/reserve …") — never self-close.
#   2. Only act when mergeable == "CONFLICTING". BLOCKED-but-MERGEABLE PRs are
#      NOT touched — those just need CI/approval, not reaping (the pr-lander /
#      ci-flake-rerun organs handle them).
#   3. Age gate: only close PRs older than MIN_AGE_HOURS (default 4h). A fresh
#      conflict may still be actively rebased by its owner; never reap it.
#   4. Re-queue each cited gap: if its status is not already `open` and not
#      `done`, `chump gap set --status open` + an audit note. If the gap is
#      already `done` (a stale DUPLICATE PR whose work landed elsewhere), do
#      NOT try to reopen it — the recycled-ID guard blocks that and it would
#      be wrong anyway; just close the PR.
#   5. Close the PR with an explanatory comment.
#
# Idempotent (a PR it closes leaves the open set; the gap note is tagged),
# logged, and dry-run-able. Safe to run on a timer.
#
# Usage:
#   ./scripts/ops/rot-reaper.sh              # live run
#   ./scripts/ops/rot-reaper.sh --dry-run    # print what would happen, no changes
#
# Environment:
#   CHUMP_ROT_REAPER_MIN_AGE_HOURS  min PR age (hours) before a CONFLICTING PR
#                                   can be reaped (default 4). Excludes fresh
#                                   conflicts.
#   CHUMP_ROT_REAPER_REALFAIL_AGE_HOURS  min PR age (hours) before a MERGEABLE
#                                   PR that is failing a REQUIRED check can be
#                                   reaped (default 8). Longer than the conflict
#                                   gate: a red check may be a transient flake a
#                                   rerun clears, so give the fix/rerun organs
#                                   more room before declaring the work lost.
#   CHUMP_ROT_REAPER_ARM_AGE_MIN    min PR age (minutes) before a green-but-
#                                   UNARMED PR is armed as a backstop to the
#                                   pr-lander (default 15).
#   CHUMP_ROT_REAPER_MAX            safety cap: max PRs to close per run
#                                   (default 10). Prevents a runaway mass-close.
#   CHUMP_ROT_REAPER_LABEL          terminal-close label (default rot-reaped).
#                                   Revivers skip any PR bearing it.
#   CHUMP_ROT_REAPER_RESPAWN_CAP    EFFECTIVE-434: max times a gap may be
#                                   auto-closed+re-queued before the reaper
#                                   stops re-queuing it and escalates to the
#                                   operator instead (default 3). The PR still
#                                   gets closed either way; only the automatic
#                                   respawn stops. Prevents a genuinely-buggy
#                                   PR from recycling forever.
#   CHUMP_ROT_REAPER_REQUIRED_CHECKS  comma-separated override of the required-
#                                   check set (default: fetched from branch
#                                   protection, fallback to the known 4).
#   CHUMP_ROT_REAPER_TRUNK_RED_MAX_AGE_MIN  RESILIENT-1188 systemic-red guard:
#                                   freshness window (min) for consuming the
#                                   trunk-sentinel's main-red signal from
#                                   ambient.jsonl (default 90). When main is RED
#                                   per the trunk-sentinel within this window,
#                                   ALL required-red PRs are HELD (not reaped) —
#                                   their red is inherited from the broken trunk,
#                                   not their own work. A trunk-red event older
#                                   than this is stale and ignored, so a
#                                   long-recovered red never holds PRs forever.
#                                   The HOLD is unconditional (no disable knob);
#                                   only this freshness window is tunable.
#   CHUMP_ROT_REAPER_CONFLICT_STATE_DIR  RESILIENT-339 resolve-first: dir the
#                                   conflict-resolution-consumer records per-PR
#                                   attempt state in (default:
#                                   <repo>/.chump-locks/conflict-resolution-attempts).
#                                   A CONFLICTING PR is reaped ONLY once its state
#                                   here shows attempts >= CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS
#                                   or an escalation — i.e. resolution was tried
#                                   and genuinely failed. No state = still savable
#                                   = handed off + deferred, never discarded.
#   CHUMP_ROT_REAPER_PR_JSON        TEST HOOK: path to a JSON file used INSTEAD
#                                   of `gh pr list`. Lets CI exercise the
#                                   selection logic without a live GitHub. Each
#                                   row may carry autoMergeRequest, isDraft, and
#                                   statusCheckRollup to exercise the new classes.
#   REMOTE / BASE                   git remote / base branch (default origin/main)
set -uo pipefail

# ── shared reaper instrumentation (heartbeat + reaper_run event + log rotate) ─
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup rot
reaper_rotate_log /tmp/chump-rot-reaper.out.log
reaper_rotate_log /tmp/chump-rot-reaper.err.log

# EFFECTIVE-434: escalate-to-operator path once a gap's respawn cap is hit.
# Sourced, not required — a missing notifier must not take the reaper down.
# shellcheck source=../coord/lib/notify-operator.sh
if [[ -f "$(dirname "$0")/../coord/lib/notify-operator.sh" ]]; then
    # shellcheck source=../coord/lib/notify-operator.sh
    source "$(dirname "$0")/../coord/lib/notify-operator.sh"
else
    notify_operator() { echo "[notify-operator] MISSING lib/notify-operator.sh" >&2; return 0; }
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

MIN_AGE_HOURS="${CHUMP_ROT_REAPER_MIN_AGE_HOURS:-4}"
REALFAIL_AGE_HOURS="${CHUMP_ROT_REAPER_REALFAIL_AGE_HOURS:-8}"
ARM_AGE_MIN="${CHUMP_ROT_REAPER_ARM_AGE_MIN:-15}"
MAX_CLOSE="${CHUMP_ROT_REAPER_MAX:-10}"
LABEL="${CHUMP_ROT_REAPER_LABEL:-rot-reaped}"
REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
# EFFECTIVE-434 (COTG recycle path): a gap re-queued this many times by the
# reaper's own "rot-reaper: PR #... auto-closed" notes is no longer a flake or
# a fixable red — the same failure keeps recurring across fresh attempts, so
# another automatic redo just burns another PR/CI cycle. Past the cap, stop
# re-queuing (the PR still closes) and escalate to the operator instead.
RESPAWN_CAP="${CHUMP_ROT_REAPER_RESPAWN_CAP:-3}"
# NO-ABANDON DEADLINE: past this age (hours) an open PR must be terminal; any
# still non-terminal is counted in the pr_no_abandon_backlog metric (target 0).
NO_ABANDON_DEADLINE_HOURS="${CHUMP_ROT_REAPER_DEADLINE_HOURS:-$REALFAIL_AGE_HOURS}"
# RESILIENT-1188 SYSTEMIC-RED guard: freshness window (minutes) for the trunk-
# sentinel's main-red signal. A trunk-red event older than this is treated as
# stale and ignored, so a long-recovered red never holds PRs forever.
TRUNK_RED_MAX_AGE_MIN="${CHUMP_ROT_REAPER_TRUNK_RED_MAX_AGE_MIN:-90}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== rot-reaper / no-abandon janitor (conflict≥${MIN_AGE_HOURS}h, required-red≥${REALFAIL_AGE_HOURS}h, arm≥${ARM_AGE_MIN}m, max=${MAX_CLOSE}, spare-recoverable=always) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no PRs will be closed and no gaps re-queued."

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"

# ── required-check set ────────────────────────────────────────────────────────
# The branch-protection required checks: a PR that is MERGEABLE (no conflict)
# but has one of THESE failing is stuck on a real content gate, not a flake or a
# pending approval. Fetched live so the set stays correct as protection evolves;
# fall back to the known-4 (2026-08-15) if the API is unavailable.
REQUIRED_CHECKS_DEFAULT="cargo-test-required,audit-required,clippy-required,ACP protocol smoke test (Zed / JetBrains compatible)"
if [[ -n "${CHUMP_ROT_REAPER_REQUIRED_CHECKS:-}" ]]; then
    REQUIRED_CHECKS="$CHUMP_ROT_REAPER_REQUIRED_CHECKS"
elif [[ -n "${CHUMP_ROT_REAPER_PR_JSON:-}" ]]; then
    # Test mode: don't hit the network; use the default set unless overridden.
    REQUIRED_CHECKS="$REQUIRED_CHECKS_DEFAULT"
else
    REQUIRED_CHECKS="$(gh api "repos/$ME/${BASE_REPO:-chump}/branches/${BASE}/protection/required_status_checks" \
        --jq '.contexts | join(",")' 2>/dev/null || true)"
    [[ -z "$REQUIRED_CHECKS" ]] && REQUIRED_CHECKS="$REQUIRED_CHECKS_DEFAULT"
fi
info "Required checks: ${REQUIRED_CHECKS}"

# ── source of candidate PRs ───────────────────────────────────────────────────
# TEST HOOK: CHUMP_ROT_REAPER_PR_JSON supplies a fixture so CI can exercise the
# selection logic (age gates + class detection) without a live GitHub.
PR_JSON=""
if [[ -n "${CHUMP_ROT_REAPER_PR_JSON:-}" ]]; then
    PR_JSON="$(cat "$CHUMP_ROT_REAPER_PR_JSON" 2>/dev/null || echo '[]')"
    info "Using fixture PR list from \$CHUMP_ROT_REAPER_PR_JSON."
else
    PR_JSON="$(gh pr list --author "$ME" --state open --limit 100 \
        --json number,title,mergeStateStatus,mergeable,createdAt,headRefName,isDraft,autoMergeRequest,statusCheckRollup \
        2>/dev/null || echo '[]')"
fi

# Rows as TSV: number \t mergeable \t createdAt \t title \t mergeState \t
#              isDraft \t hasAutoMerge \t requiredFail
# requiredFail = "1" iff a branch-protection-REQUIRED check has concluded
# FAILURE/ERROR/TIMED_OUT (not pending, not skipped) — the "real content gate is
# red" signal that separates a stuck PR from one merely waiting on CI/approval.
ROWS="$(printf '%s' "$PR_JSON" | REQ_CHECKS="$REQUIRED_CHECKS" python3 -c '
import json, os, sys
required = {c.strip() for c in os.environ.get("REQ_CHECKS","").split(",") if c.strip()}
FAIL = {"FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    num   = r.get("number", "")
    mrg   = r.get("mergeable", "")
    made  = r.get("createdAt", "")
    title = (r.get("title") or "").replace("\t", " ").replace("\n", " ")
    mstate = r.get("mergeStateStatus", "") or ""
    draft = "1" if r.get("isDraft") else "0"
    has_am = "1" if r.get("autoMergeRequest") else "0"
    req_fail = "0"
    fail_checks = []  # RESILIENT-1188: the required checks red on THIS PR — surfaced
                      # for context in the systemic-HOLD log line + ambient event.
    for c in (r.get("statusCheckRollup") or []):
        name = c.get("name") or c.get("context") or ""
        # CheckRun uses conclusion; StatusContext uses state.
        concl = (c.get("conclusion") or c.get("state") or "").upper()
        if name in required and concl in FAIL:
            req_fail = "1"
            if name not in fail_checks:
                fail_checks.append(name)
    head = (r.get("headRefName") or "").replace("\t", " ").replace("\n", " ")
    # req_fail_checks: comma-joined red required gate names (no tabs/commas in
    # our check names). Emitted LAST so it is safe to append without shifting
    # any existing field position in the reader.
    req_fail_checks = ",".join(n.replace("\t", " ").replace(",", " ") for n in fail_checks)
    print(f"{num}\t{mrg}\t{made}\t{title}\t{mstate}\t{draft}\t{has_am}\t{req_fail}\t{head}\t{req_fail_checks}")
' 2>/dev/null || true)"

# age_hours ISO8601 — whole hours since createdAt (python, bash-free of `date -d`).
age_hours() {
    python3 -c '
import sys
from datetime import datetime, timezone
try:
    dt = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    print(int((datetime.now(timezone.utc) - dt).total_seconds() // 3600))
except Exception:
    print(-1)
' "$1" 2>/dev/null || echo -1
}

is_filing_pr_title() {
    case "$1" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

CLOSED=0
REQUEUED=0
SKIPPED=0
ARMED=0
HELD=0             # RESILIENT-1188: PRs HELD (not closed) because their required-
                   # red is SYSTEMIC (a shared/trunk gate broken fleet-wide)
HELD_PRS=""
SYSTEMIC_ALERTED=0 # one operator page per beat, not per held PR
BACKLOG=0          # open PRs past the no-abandon deadline still non-terminal
BACKLOG_PRS=""

AMBIENT_LOG="${NODE_AMBIENT:-$(cd "$(dirname "$0")/../.." && pwd)/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

# ── VERIFIED-RED SPARE (RESILIENT-311 completion, this change) ────────────────
# CLASS 2 closes a MERGEABLE PR whose branch-protection-required check `verified`
# has been RED past the deadline. But `verified` is a SLOW AGGREGATE over the
# real gates (cargo-test/clippy/audit/fast-checks/parity). An aggregate going red
# does NOT prove the work is dead: it goes red when a parity mirror reports late,
# a sub-job is CI-cancelled, a known flake trips, or CI is simply still finishing.
# Closing that PR destroys correct work that only needs a re-run (the
# #4598/#4615/#4618 incident: a 22-min-late parity gate, a flake, a CI-cancel —
# all reaped as if dead). Before any CLASS 2 close we now classify WHY verified
# is red, REUSING the green-underneath classifier from #4606
# (scripts/ops/lib/classify-blocked-pr.py), and SPARE the recoverable verdicts
# (green_underneath / pending / cancelled / blocked_no_failure / flake_exhausted)
# — re-arming the auto-merge backstop or the flake budget, and escalating to the
# operator past a bound rather than fighting forever. Only genuinely-dead PRs
# (hard_fail / conflict) fall through to the close.
#
# The green-underneath spare is UNCONDITIONAL: the reaper always spares
# recoverable/green-underneath PRs. There is no toggle to disable it — a switch
# that restores close-good-PRs behavior is exactly the safety-fix-off escape
# hatch the bypass-debt ceiling forbids, so it does not exist.
# The classifier is a sibling of THIS script (resolved relative to the reaper's
# own dir, not any operated-repo root).
CLASSIFY_HELPER="$(cd "$(dirname "$0")" && pwd)/lib/classify-blocked-pr.py"
# The REAL gate checks the aggregate `verified` is built over. Deliberately does
# NOT include `^verified$` — verified is the aggregate we are looking underneath.
# FIXED POLICY, not operator-tunable: an override of WHICH checks count as
# "blocking" is a soft-bypass seam (it could make the reaper ignore a real red
# gate), so there is no env knob — the blocking-check set is hardcoded.
BLOCKING_CHECK_RE='-required$|^audit-shard|^fast-checks$'
# INFRA-304 flake-budget markers (same dir ci-flake-rerun.sh writes).
FLAKE_COOLDOWN_DIR="${CHUMP_ROT_REAPER_FLAKE_COOLDOWN_DIR:-$(dirname "$AMBIENT_LOG")/ci-flake-cooldown}"
# Bounded spare bookkeeping — never spare-forever. Past the cap the reaper still
# does NOT close (the work is not dead) but escalates to the operator once so a
# perpetually-red aggregate (e.g. an unregistered parity gate) gets a human.
SPARE_STATE_DIR="${CHUMP_ROT_REAPER_SPARE_STATE_DIR:-$(dirname "$AMBIENT_LOG")/rot-reaper-spare-state}"
SPARE_ESCALATE_CAP="${CHUMP_ROT_REAPER_SPARE_ESCALATE_CAP:-8}"
FLAKE_REARM_MAX="${CHUMP_ROT_REAPER_FLAKE_REARM_MAX:-1}"
SPARED=0

# classify_verified_red PR_NUM — reuse classify-blocked-pr.py against this PR's
# already-fetched statusCheckRollup + mergeable (from PR_JSON, so it works for
# both the live `gh pr list` and the CHUMP_ROT_REAPER_PR_JSON test fixture).
# Echoes one verdict: pending | flake_exhausted | blocked_no_failure |
# green_underneath | cancelled | hard_fail | conflict.
# Fail-safe: any missing helper / unparseable input echoes green_underneath
# (a spare verdict) so a fetch error NEVER causes a destructive close.
classify_verified_red() {  # <pr_num>
    local pr="$1"
    [[ -f "$CLASSIFY_HELPER" ]] || { echo "green_underneath"; return; }
    local rollup_file mergeable
    rollup_file="$(mktemp "${TMPDIR:-/tmp}/rot-rollup-XXXXXX" 2>/dev/null || echo "")"
    [[ -z "$rollup_file" ]] && { echo "green_underneath"; return; }
    mergeable="$(printf '%s' "$PR_JSON" | PR="$pr" python3 -c '
import json, os, sys
pr = os.environ.get("PR", "")
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
row = {}
for r in rows:
    if str(r.get("number", "")) == str(pr):
        row = r; break
json.dump(row.get("statusCheckRollup") or [], open(sys.argv[1], "w"))
print((row.get("mergeable") or ""))
' "$rollup_file" 2>/dev/null || echo "")"
    python3 "$CLASSIFY_HELPER" \
        --rollup-file "$rollup_file" \
        --mergeable "$mergeable" \
        --pr "$pr" \
        --cooldown-dir "$FLAKE_COOLDOWN_DIR" \
        --blocking-check="$BLOCKING_CHECK_RE" \
        --flake-budget "${CHUMP_FLAKE_BUDGET:-3}" 2>/dev/null \
        || echo "green_underneath"
    rm -f "$rollup_file" 2>/dev/null || true
}

# rearm_flake_budget PR_NUM — reset the INFRA-304 per-PR flake budget so
# ci-flake-rerun.sh may retry the known flake. Deletes the count + comment
# markers only (same as stale-pr-reaper's re-arm).
rearm_flake_budget() {  # <pr_num>
    rm -f "$FLAKE_COOLDOWN_DIR/pr-${1}.count" \
          "$FLAKE_COOLDOWN_DIR/pr-${1}.commented" 2>/dev/null || true
}

# bump_spare_count PR_NUM — increment + echo this PR's cumulative spare count
# (a simple counter file). Used to bound sparing so a perpetually-red aggregate
# escalates to the operator instead of being spared silently forever.
bump_spare_count() {  # <pr_num>
    local pr="$1" f n
    mkdir -p "$SPARE_STATE_DIR" 2>/dev/null || true
    f="$SPARE_STATE_DIR/${pr}.count"
    n="$(cat "$f" 2>/dev/null || echo 0)"; n=$((n + 1))
    echo "$n" > "$f" 2>/dev/null || true
    echo "$n"
}

# arm_backstop PR_NUM — best-effort re-arm of auto-merge so the merge-serializer
# drives the spared PR to land once `verified` finally goes green. Non-fatal.
arm_backstop() {  # <pr_num>
    local armer; armer="$(dirname "$0")/../coord/auto-merge-armer.sh"
    [[ -x "$armer" ]] || return 0
    bash "$armer" --pr "$1" >/dev/null 2>&1 || true
}

# emit_spare_event PR_NUM VERDICT COUNT — board-visible spare signal. The kind
# is a LITERAL (not a %s) so the event-registry coverage scanner can grep it:
# emits {"kind":"pr_reap_spared"} — registered in docs/observability/EVENT_REGISTRY.yaml.
emit_spare_event() {  # <pr> <verdict> <count>
    printf '{"ts":"%s","kind":"pr_reap_spared","source":"rot-reaper","pr":%s,"verdict":"%s","spare_count":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# spare_verified_red PR_NUM VERDICT AGE TITLE — the SPARE action for a CLASS 2
# PR whose verified-red is recoverable. Re-arms (auto-merge backstop, and the
# flake budget for flake_exhausted), records a bounded spare count, escalates to
# the operator ONCE past the cap, and NEVER closes. Returns 0 always (the caller
# `continue`s afterward).
spare_verified_red() {  # <pr_num> <verdict> <age_h> <title>
    local pr="$1" verdict="$2" age="$3" title="$4" n
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would SPARE PR #$pr (verified-red but $verdict — recoverable; re-arm, never close)"
        SPARED=$((SPARED + 1)); return 0
    fi
    n="$(bump_spare_count "$pr")"
    case "$verdict" in
        flake_exhausted)
            if [[ "$n" -le "$FLAKE_REARM_MAX" ]]; then
                rearm_flake_budget "$pr"
                green "  SPARE PR #$pr — verified-red is a budget-spent known flake; re-armed flake budget (spare $n), NOT closing."
            else
                warn "  PR #$pr — flake re-exhausted after ${FLAKE_REARM_MAX} re-arm(s); escalating to operator, still NOT closing (anti-memento: keep correct work)."
                notify_operator "$(printf '⚠️ **PR #%s verified-red persists as a flake after re-arm** — rot-reaper is sparing it, NOT closing (its work is green underneath). It has been spared %s time(s); a human should look at why the known flake keeps recurring.' "$pr" "$n")" || true
            fi
            arm_backstop "$pr"
            ;;
        *)
            green "  SPARE PR #$pr — verified-red but $verdict (real gates green / transient); re-armed auto-merge backstop (spare $n), NOT closing."
            arm_backstop "$pr"
            if [[ "$n" -ge "$SPARE_ESCALATE_CAP" ]]; then
                warn "  PR #$pr — spared ${n} times (>= cap ${SPARE_ESCALATE_CAP}); escalating to operator, still NOT closing."
                notify_operator "$(printf '⚠️ **PR #%s has been spared %s times by rot-reaper** (verdict: %s, %sh old).\n\nIts required verified aggregate is stuck RED while the real gates look green/transient — likely an unregistered parity gate or a wedged aggregate. The reaper will NOT close it (the work is not dead), but it needs a human to clear the aggregate.' "$pr" "$n" "$verdict" "$age")" || true
            fi
            ;;
    esac
    emit_spare_event "$pr" "$verdict" "$n"
    SPARED=$((SPARED + 1))
    return 0
}

# ── NO-ABANDON METRIC ─────────────────────────────────────────────────────────
# The count of open PRs past the deadline still in a non-terminal state. The
# guarantee's health gauge — target 0. A persistent non-zero here means a rot
# class is escaping every driver and must be handled.
emit_backlog_metric() {  # <count> <pr_list>
    local n="$1" prs="$2"
    printf '{"ts":"%s","kind":"pr_no_abandon_backlog","source":"rot-reaper","count":%s,"deadline_h":%s,"prs":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$NO_ABANDON_DEADLINE_HOURS" "$(printf '%s' "$prs" | tr -s ' ')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
    if [[ "$n" -gt 0 ]]; then
        red "NO-ABANDON BACKLOG: ${n} open PR(s) past ${NO_ABANDON_DEADLINE_HOURS}h still non-terminal: ${prs}"
    else
        green "NO-ABANDON BACKLOG: 0 — every open PR is terminal or on-track."
    fi
}

# EFFECTIVE-434: a gap that hit its respawn cap — recorded so the operator
# escalation is observable in ambient.jsonl, not just a Discord ping.
emit_respawn_cap_event() {  # <gap_id> <pr_num> <respawn_count>
    local gid="$1" pr="$2" n="$3"
    printf '{"ts":"%s","kind":"gap_respawn_cap_reached","source":"rot-reaper","gap":"%s","pr":%s,"respawn_count":%s,"cap":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gid" "$pr" "$n" "$RESPAWN_CAP" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

if [[ -z "$ROWS" ]]; then
    info "No open PRs found — nothing to reap."
    emit_backlog_metric 0 ""
    reaper_finish ok '{"closed":0,"requeued":0,"skipped":0,"armed":0,"spared":0,"held":0,"backlog":0}'
    exit 0
fi

# ── requeue every cited gap of a PR we are reaping ────────────────────────────
# Sets status:open (unless already open/done) + an audit note. Increments the
# global REQUEUED. A `done` gap (work landed elsewhere) is left done.
requeue_gaps() {  # <pr_num> <age_h> <reason_short> <title>
    local pr="$1" age="$2" reason="$3" title="$4" gid cur status note
    local prior_notes respawn_count cap_note
    local ids; ids="$(printf '%s\n' "$title" | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u || true)"
    for gid in $ids; do
        [[ -z "$gid" ]] && continue
        if ! command -v chump >/dev/null 2>&1; then
            info "  (chump CLI unavailable — skipping re-queue of $gid)"; continue
        fi
        cur="$(chump gap show "$gid" 2>/dev/null || true)"
        [[ -z "$cur" ]] && { info "  $gid not found in gap store — nothing to re-queue."; continue; }
        status="$(awk '/^[[:space:]]*status:/{sub(/^[[:space:]]*status:[[:space:]]*/,""); print; exit}' <<<"$cur")"
        if [[ "$status" == "done" ]]; then
            info "  $gid already done — stale duplicate PR; closing without re-queue."; continue
        fi

        # EFFECTIVE-434: respawn cap. Count how many times this gap has already
        # been auto-closed+re-queued by the reaper (each prior cycle leaves a
        # "rot-reaper: PR #... auto-closed" note). Past RESPAWN_CAP, the same
        # failure is recurring across fresh attempts — stop re-queuing and
        # escalate to the operator instead of recycling forever. The PR itself
        # still gets closed by the caller; only the gap re-open is skipped.
        prior_notes="$(chump gap show "$gid" --field notes 2>/dev/null || true)"
        respawn_count="$(printf '%s' "$prior_notes" | grep -oE 'rot-reaper: PR #[0-9]+ auto-closed' | wc -l | tr -d ' ')"
        if [[ "${respawn_count:-0}" -ge "$RESPAWN_CAP" ]]; then
            warn "  $gid respawn cap reached (${respawn_count} >= ${RESPAWN_CAP}) — escalating to operator, NOT re-queuing"
            if [[ $DRY_RUN -eq 1 ]]; then dry "would escalate $gid to operator (respawn cap ${RESPAWN_CAP} reached)"; continue; fi
            cap_note="rot-reaper: PR #${pr} auto-closed (${reason}, ${age}h) $(date -u +%Y-%m-%d); RESPAWN CAP ${RESPAWN_CAP} reached (${respawn_count} prior recycles) — NOT re-queued, escalating to operator."
            chump gap set "$gid" --add-note "$cap_note" >/dev/null 2>&1 \
                || warn "chump gap set $gid --add-note failed"
            emit_respawn_cap_event "$gid" "$pr" "$respawn_count"
            notify_operator "$(printf '🛑 **%s hit its respawn cap (%s)** — rot-reaper will not re-queue it again.\n\nPR #%s just closed (%s, %sh). This gap has been auto-closed+re-queued %s time(s) already by the reaper; the same failure keeps recurring, which means it needs a human, not another automatic redo.\n\nGap left CLOSED — reopen manually after diagnosing.' \
                "$gid" "$RESPAWN_CAP" "$pr" "$reason" "$age" "$respawn_count")" || true
            continue
        fi

        note="rot-reaper: PR #${pr} auto-closed (${reason}, ${age}h) $(date -u +%Y-%m-%d); re-attempt on fresh main."
        if [[ $DRY_RUN -eq 1 ]]; then dry "would re-queue $gid (status=$status) + note"; continue; fi
        [[ "$status" != "open" ]] && { chump gap set "$gid" --status open >/dev/null 2>&1 \
            || warn "chump gap set $gid --status open failed"; }
        chump gap set "$gid" --add-note "$note" >/dev/null 2>&1 \
            || warn "chump gap set $gid --add-note failed"
        info "  re-queued $gid (was $status)"
        REQUEUED=$((REQUEUED + 1))
    done
}

# ── label + close a PR terminally ─────────────────────────────────────────────
# The label is what makes the close STICK: revivers (post-push-integrity-watch)
# skip any PR bearing it, so the reap↔revive fight that rotted #3792 can't recur.
LABEL_ENSURED=0
ensure_label() {
    [[ "$LABEL_ENSURED" == 1 ]] && return 0
    LABEL_ENSURED=1
    if gh label list --limit 300 2>/dev/null | grep -qE "^${LABEL}([[:space:]]|$)"; then return 0; fi
    gh label create "$LABEL" --color B60205 \
        --description "Closed terminally by the no-abandon janitor (RESILIENT-311); do not reopen — a fresh PR comes from the requeued gap." \
        >/dev/null 2>&1 || true
}
label_and_close() {  # <pr_num> <close_msg>
    local pr="$1" msg="$2"
    ensure_label
    # Label BEFORE close so a reviver polling in the close window already sees it.
    # (Guarded with `if` so this line does not begin with a bare `gh pr edit`,
    # which the INFRA-1274 raw-gh hot-path lint forbids at line start.)
    if ! gh pr edit "$pr" --add-label "$LABEL" >/dev/null 2>&1; then
        warn "could not add label '$LABEL' to PR #$pr (continuing to close)"
    fi
    if gh pr close "$pr" --comment "$msg" 2>/dev/null; then
        green "  closed PR #$pr (labeled $LABEL)"
        CLOSED=$((CLOSED + 1))
        # Loud, board-visible signal that a line was terminated (not a silent rot).
        printf '{"ts":"%s","kind":"pr_reaped","source":"rot-reaper","pr":%s,"label":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$LABEL" >> "$AMBIENT_LOG" 2>/dev/null || true
        return 0
    fi
    warn "gh pr close $pr failed."
    return 1
}

# ── RESILIENT-339 RESOLVE-FIRST: never discard a savable CONFLICTING PR ───────
# A CONFLICTING PR is reaped ONLY after the standing conflict-resolution-consumer
# (scripts/coord/conflict-resolution-consumer.sh, RESILIENT-301) has ALREADY
# tried to rebase-resolve it onto the base (its union / append-only merge drivers
# dissolve the hot-file collisions) AND declared the conflict genuinely
# unresolvable — its per-PR attempt counter hit CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS
# or it escalated to the operator. Until then the PR is still savable, so the
# reaper HANDS IT OFF (emits the armed_pr_needs_conflict_resolution signal the
# consumer drains) and DEFERS the reap. Net: a PR is only ever MERGED (the
# consumer's push lands it) or sent-to-rework — never discarded while resolution
# is still possible.
CONFLICT_ATTEMPT_DIR="${CHUMP_ROT_REAPER_CONFLICT_STATE_DIR:-$(dirname "$AMBIENT_LOG")/conflict-resolution-attempts}"
CONFLICT_MAX_ATTEMPTS="${CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS:-3}"

# 0 = resolution EXHAUSTED (consumer already gave up → safe to reap);
# 1 = not exhausted (savable → must hand off + defer, never reap).
conflict_resolution_exhausted() {  # <pr_num>
    local pr="$1"
    local sf="$CONFLICT_ATTEMPT_DIR/$pr.json" a esc
    [[ -f "$sf" ]] || return 1
    esc="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("escalated_at",""))' "$sf" 2>/dev/null || echo '')"
    [[ -n "$esc" ]] && return 0
    a="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("attempts",0))' "$sf" 2>/dev/null || echo 0)"
    [[ "${a:-0}" -ge "$CONFLICT_MAX_ATTEMPTS" ]] && return 0
    return 1
}

# Hand a savable CONFLICTING PR to the standing conflict-resolution-consumer by
# emitting the signal it drains (same kind armed-pr-rebaser emits). Idempotent;
# the consumer dedups to the latest sighting per PR.
hand_off_to_conflict_consumer() {  # <pr_num> <head_branch>
    local pr="$1" head="$2"
    printf '{"ts":"%s","kind":"armed_pr_needs_conflict_resolution","source":"rot-reaper","pr":%s,"branch":"%s","via":"rot-reaper-resolve-first"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$head" >> "$AMBIENT_LOG" 2>/dev/null || true
    printf '{"ts":"%s","kind":"rot_reaper_resolve_first_deferred","source":"rot-reaper","pr":%s,"branch":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$head" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── RESILIENT-1188 SYSTEMIC-RED GUARD (the BROADER guard past #4637) ──────────
# #4637 taught CLASS 2 to SPARE a PR whose real gates are green underneath a red
# `verified` aggregate — the INDIVIDUAL green-underneath case. But when a SHARED
# / trunk gate breaks (a required job regresses on main), the required aggregate
# goes RED across MANY open PRs at once, each with a genuine COMPLETED failure on
# that gate — so #4637's per-PR classifier reads each one as hard_fail and the
# reaper closes them ALL. That is the fleet-wide self-strangle (INFRA-3542 /
# auto-rescue-reaps-systemic-red): none of those PRs did anything wrong
# individually; the redness is not theirs — it's the trunk's.
#
# THE RELIABLE SIGNAL IS MAIN-RED, NOT "N PRs share a gate". Two open PRs failing
# the SAME-NAMED required gate is NOT proof of a shared break: each can have its
# OWN independent real failure in that gate (a genuinely broken cargo-test on
# each), and those SHOULD still reap. The one thing that distinguishes a shared/
# trunk break from independent failures is whether MAIN ITSELF is red on that
# gate. So this guard's systemic signal is exactly the trunk-sentinel's main-red
# verdict — when main is green, a required-red PR reaps as before (independent
# failure); when main is RED, the whole required-red class is held (its redness
# is inherited from the broken trunk, not the PR's own work).
#
# (The green-main "N PRs share one false-red gate" case — e.g. a farmer-flap —
# is still DETECTED and alarmed by scripts/coord/systemic-red-detector.sh, W-015;
# it is deliberately NOT auto-held here, because green-main same-gate failures
# are overwhelmingly independent and holding them would strand real dead work.)
#
# The signal is CONSUMED from the trunk-sentinel-daemon (no re-detection, no
# extra network call — deterministic + fast on the timer, and exercisable by the
# CHUMP_ROT_REAPER_PR_JSON fixture with a seeded ambient log). Like #4637's
# spare, the HOLD is UNCONDITIONAL — there is deliberately NO env toggle to
# disable it (a switch that restores mass-closing good PRs during a trunk-red is
# exactly the safety-off escape hatch the bypass-debt ceiling forbids). Only the
# trunk-red freshness window is tunable.

# MAIN_RED: consume the trunk-sentinel signal from ambient.jsonl. Echoes "1" iff
# the freshest trunk state event (within TRUNK_RED_MAX_AGE_MIN) says main is red.
MAIN_RED="$(AMBIENT="$AMBIENT_LOG" MAXAGE="$TRUNK_RED_MAX_AGE_MIN" python3 -c '
import json, os, sys
from datetime import datetime, timezone
path = os.environ.get("AMBIENT","")
try:
    maxage = float(os.environ.get("MAXAGE","90") or "90")
except ValueError:
    maxage = 90.0
best_ts = None
best_red = None  # True=red, False=green, None=unknown
def parse(ts):
    try:
        return datetime.fromisoformat((ts or "").replace("Z","+00:00"))
    except Exception:
        return None
try:
    fh = open(path)
except OSError:
    print("0"); sys.exit(0)
with fh:
    for line in fh:
        line = line.strip()
        if not line or "trunk" not in line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        kind = e.get("kind","")
        red = None
        if kind == "trunk_red_persistent":
            red = True
        elif kind == "trunk_recovered":
            red = False
        elif kind == "trunk_state_change":
            to = (e.get("to") or "").upper()
            if to == "TRUNK_RED": red = True
            elif to == "TRUNK_GREEN": red = False
        else:
            continue
        ts = parse(e.get("ts"))
        if ts is None:
            continue
        if best_ts is None or ts >= best_ts:
            best_ts, best_red = ts, red
if best_ts is None or best_red is not True:
    print("0"); sys.exit(0)
age_min = (datetime.now(timezone.utc) - best_ts).total_seconds() / 60.0
print("1" if age_min <= maxage else "0")
' 2>/dev/null || echo 0)"
[[ "$MAIN_RED" == "1" ]] && red "SYSTEMIC-RED: trunk-sentinel reports main RED (within ${TRUNK_RED_MAX_AGE_MIN}m) — HOLDING all required-red PRs this beat (their red is inherited from the broken trunk, not their own work)."

# is_systemic_red — 0 (systemic → HOLD) iff the trunk-sentinel says main is red
# within the freshness window. Green main ⇒ a required-red PR is an independent
# failure ⇒ reap as before (NOT held).
is_systemic_red() {
    [[ "$MAIN_RED" == "1" ]] && return 0
    return 1
}

# emit_systemic_hold_event PR GATES REASON — board-visible HOLD signal. Literal
# kind (not a %s) so the event-registry coverage scanner can grep it:
# emits {"kind":"pr_reap_held_systemic"} — registered in EVENT_REGISTRY.yaml.
emit_systemic_hold_event() {  # <pr> <gates_csv> <reason>
    printf '{"ts":"%s","kind":"pr_reap_held_systemic","source":"rot-reaper","pr":%s,"gates":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# hold_systemic_red PR REQ_FAIL_CHECKS AGE TITLE — the HOLD action: never close,
# re-arm the auto-merge backstop so the PR lands once the shared gate recovers,
# emit the board signal, and page the operator ONCE per beat (a real trunk-red
# needs a human, not mass-closure). Returns 0 (caller `continue`s).
hold_systemic_red() {  # <pr> <req_fail_checks> <age_h> <title>
    local pr="$1" checks="$2" age="$3" title="$4" reason="main-red"
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would HOLD PR #$pr (required-red is SYSTEMIC: $reason [$checks]; never close, re-arm + alert)"
        HELD=$((HELD + 1)); HELD_PRS+="${pr} "; return 0
    fi
    green "  HOLD PR #$pr — required-red is SYSTEMIC ($reason: $checks); NOT closing (trunk break, not this PR's fault), re-armed backstop."
    arm_backstop "$pr"
    emit_systemic_hold_event "$pr" "$checks" "$reason"
    HELD=$((HELD + 1)); HELD_PRS+="${pr} "
    return 0
}

while IFS=$'\t' read -r PR_NUM MERGEABLE CREATED TITLE MSTATE ISDRAFT HASAM REQFAIL HEAD REQ_FAIL_CHECKS; do
    [[ -z "$PR_NUM" ]] && continue

    # Never self-close a gap-filing PR (belt: also excluded from every class).
    if is_filing_pr_title "$TITLE"; then
        info "PR #$PR_NUM — filing PR, skipping."
        continue
    fi

    AGE="$(age_hours "$CREATED")"
    if [[ "$AGE" -lt 0 ]]; then
        warn "PR #$PR_NUM — could not parse createdAt ($CREATED); skipping (fail-safe)."
        SKIPPED=$((SKIPPED + 1)); continue
    fi

    # ── CLASS 1: CONFLICTING beyond CONFLICT age → close + requeue ────────────
    if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
        if [[ "$AGE" -lt "$MIN_AGE_HOURS" ]]; then
            info "PR #$PR_NUM — CONFLICTING but only ${AGE}h old (< ${MIN_AGE_HOURS}h); leaving for the owner/rebaser."
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        # ── RESILIENT-339 RESOLVE-FIRST guard ────────────────────────────────
        # NEVER discard a savable PR. Reap only once the conflict-resolution
        # consumer has ALREADY tried and given up (attempts exhausted/escalated);
        # otherwise hand it off and defer, so the union-driver rebase gets its
        # shot and a resolvable PR is never closed.
        if ! conflict_resolution_exhausted "$PR_NUM"; then
            info "PR #$PR_NUM — CONFLICTING, ${AGE}h old, but conflict-resolution NOT yet exhausted → hand to conflict-resolution-consumer + DEFER reap (RESILIENT-339 resolve-first)."
            if [[ $DRY_RUN -eq 1 ]]; then
                dry "would hand PR #$PR_NUM ($HEAD) to conflict-resolution-consumer and defer reap"
                SKIPPED=$((SKIPPED + 1)); continue
            fi
            hand_off_to_conflict_consumer "$PR_NUM" "$HEAD"
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        if [[ "$CLOSED" -ge "$MAX_CLOSE" ]]; then
            warn "Reached MAX_CLOSE=$MAX_CLOSE this run; deferring the rest."
            BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "; continue
        fi
        red "PR #$PR_NUM — CONFLICTING, ${AGE}h old, conflict-resolution EXHAUSTED (consumer gave up) → REAP"
        info "  title: $TITLE"
        requeue_gaps "$PR_NUM" "$AGE" "CONFLICTING" "$TITLE"
        MSG="Auto-closing (rot-reaper / RESILIENT-311 no-abandon janitor): this PR is **CONFLICTING** with \`${BASE}\` and is ${AGE}h old. The armed-rebaser only rebases *behind* PRs — it cannot resolve a real merge conflict — so this branch would sit unmerged indefinitely and keep the back-pressure breaker halted. The cited gap(s) have been re-queued to be re-done cleanly on fresh \`${BASE}\`. The conflict-resolution-consumer (RESILIENT-301) already tried to rebase-resolve this branch and could not (attempts exhausted / escalated) — resolution was attempted BEFORE this close, so nothing savable is being discarded. Labeled \`${LABEL}\` so revivers won't fight this deliberate close. (RESILIENT-339/RESILIENT-324/RESILIENT-311)"
        if [[ $DRY_RUN -eq 1 ]]; then dry "would label+close PR #$PR_NUM (CONFLICTING)"; CLOSED=$((CLOSED + 1)); continue; fi
        label_and_close "$PR_NUM" "$MSG"
        continue
    fi

    # ── CLASS 2: MERGEABLE but a REQUIRED check FAILED beyond REALFAIL age ────
    # A real content gate is red (raw-gh lint, bypass ceiling, a failing test) —
    # no organ fixes it, so it would sit BLOCKED forever. Past the deadline,
    # close + requeue so the fleet redoes it clean rather than let it rot.
    if [[ "$REQFAIL" == "1" ]]; then
        if [[ "$AGE" -lt "$REALFAIL_AGE_HOURS" ]]; then
            info "PR #$PR_NUM — failing a required check but only ${AGE}h old (< ${REALFAIL_AGE_HOURS}h); leaving for a fix/rerun."
            SKIPPED=$((SKIPPED + 1)); continue
        fi
        # ── VERIFIED-RED SPARE: classify WHY verified is red before closing ───
        # The required check that is red is the slow `verified` AGGREGATE. Do NOT
        # close a PR whose real gates are green underneath (parity-late / aggregate
        # glitch), whose red is a CI-cancel, a still-pending run, or a known flake.
        # Reuse the #4606 green-underneath classifier; only hard_fail / conflict
        # fall through to the close. (RESILIENT-311 completion — spares
        # #4598/#4615/#4618-class PRs the reaper was destroying.)
        SPARE_VERDICT="$(classify_verified_red "$PR_NUM")"
        case "$SPARE_VERDICT" in
            pending|blocked_no_failure|green_underneath|cancelled|flake_exhausted)
                info "PR #$PR_NUM — required(verified)-red ${AGE}h but RECOVERABLE ($SPARE_VERDICT) → SPARE (re-arm / escalate, never close)."
                spare_verified_red "$PR_NUM" "$SPARE_VERDICT" "$AGE" "$TITLE"
                continue
                ;;
            conflict)
                # Shouldn't happen here (CLASS 1 handles CONFLICTING), but if
                # the rollup says conflict, let CLASS 1's resolve-first path own
                # it next beat rather than reaping from the required-red class.
                info "PR #$PR_NUM — required-red classified as conflict; deferring to CLASS 1 resolve-first next beat."
                SKIPPED=$((SKIPPED + 1)); continue
                ;;
            hard_fail|*)
                : # individually dead → still subject to the SYSTEMIC guard below.
                ;;
        esac
        # ── RESILIENT-1188 SYSTEMIC-RED GUARD ────────────────────────────────
        # The per-PR classifier says this PR is an individual hard_fail. But if
        # the trunk-sentinel reports main/trunk RED (within the freshness
        # window), the PR's red is inherited from the broken trunk, NOT its own
        # work — and closing it (along with every sibling in the same beat/loop)
        # is the fleet-wide self-strangle. HOLD instead: re-arm the backstop,
        # alert, never close. Green main ⇒ this is an independent failure ⇒ reap.
        if is_systemic_red; then
            info "PR #$PR_NUM — required-red is SYSTEMIC (main/trunk RED per trunk-sentinel; red gate(s): ${REQ_FAIL_CHECKS:-<aggregate>}) → HOLD, not reap (RESILIENT-1188)."
            hold_systemic_red "$PR_NUM" "$REQ_FAIL_CHECKS" "$AGE" "$TITLE"
            continue
        fi
        if [[ "$CLOSED" -ge "$MAX_CLOSE" ]]; then
            warn "Reached MAX_CLOSE=$MAX_CLOSE this run; deferring the rest."
            BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "; continue
        fi
        red "PR #$PR_NUM — MERGEABLE but REQUIRED check RED (hard-fail, not recoverable), ${AGE}h old → REAP"
        info "  title: $TITLE"
        requeue_gaps "$PR_NUM" "$AGE" "required-check-red" "$TITLE"
        MSG="Auto-closing (rot-reaper / RESILIENT-311 no-abandon janitor): this PR is mergeable but a **branch-protection-required check has been RED for ${AGE}h** (≥ ${REALFAIL_AGE_HOURS}h) and no fix/rerun organ cleared it — it would sit BLOCKED forever. Required set: \`${REQUIRED_CHECKS}\`. The cited gap(s) have been re-queued to be re-done cleanly on fresh \`${BASE}\`. If that check is actually a flake that is now green on main, reopen and re-run. Labeled \`${LABEL}\`. (RESILIENT-311)"
        if [[ $DRY_RUN -eq 1 ]]; then dry "would label+close PR #$PR_NUM (required-check-red)"; CLOSED=$((CLOSED + 1)); continue; fi
        label_and_close "$PR_NUM" "$MSG"
        continue
    fi

    # ── CLASS 3: MERGEABLE + green + UNARMED beyond ARM age → arm ─────────────
    # Backstop the pr-lander: a green PR that never got its auto-merge armed
    # (the #3792-was-green-but-unmerged class) is driven forward, not left.
    if [[ "$MERGEABLE" == "MERGEABLE" && "$HASAM" == "0" && "$ISDRAFT" == "0" && "$MSTATE" != "DIRTY" ]]; then
        AGE_MIN=$(( AGE * 60 ))
        # AGE is whole hours; approximate minutes are fine for a ≥15m backstop
        # gate (a PR younger than 1h reads AGE=0 → 0min → still below 15m unless
        # we also honor sub-hour freshness, so only arm once it's ≥1h old).
        if [[ "$AGE_MIN" -ge "$ARM_AGE_MIN" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                dry "would ARM green-unarmed PR #$PR_NUM (${AGE}h old)"
                ARMED=$((ARMED + 1))
            else
                if [[ -x "$(dirname "$0")/../coord/auto-merge-armer.sh" ]] \
                   && bash "$(dirname "$0")/../coord/auto-merge-armer.sh" --pr "$PR_NUM" >/dev/null 2>&1; then
                    green "PR #$PR_NUM — green + unarmed ${AGE}h → ARMED (lander backstop)"
                    ARMED=$((ARMED + 1))
                else
                    warn "PR #$PR_NUM — arm backstop failed (likely needs review); counting as backlog."
                    [[ "$AGE" -ge "$NO_ABANDON_DEADLINE_HOURS" ]] && { BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "; }
                fi
            fi
            continue
        fi
    fi

    # ── Everything else: is a driver actively moving it toward terminal? ─────
    # An armed + mergeable PR is on-track (auto-merge lands it once green); a
    # BEHIND PR is owned by chump-armed-rebaser. Those are NOT abandoned. Only a
    # PR past the deadline with NO driver — unarmed-and-couldn't-arm, or a state
    # no organ handles — counts toward the backlog metric, so an escaping rot
    # class can't hide behind "someone else will get it."
    if [[ "$AGE" -ge "$NO_ABANDON_DEADLINE_HOURS" ]]; then
        local_on_driver=0
        [[ "$HASAM" == "1" && "$MERGEABLE" == "MERGEABLE" ]] && local_on_driver=1  # auto-merge
        [[ "$MSTATE" == "BEHIND" ]] && local_on_driver=1                            # rebaser
        if [[ "$local_on_driver" == "0" ]]; then
            info "PR #$PR_NUM — ${AGE}h old, non-terminal + NO driver (merge=$MERGEABLE state=$MSTATE armed=$HASAM); counting as no-abandon backlog."
            BACKLOG=$((BACKLOG + 1)); BACKLOG_PRS+="${PR_NUM} "
        fi
    fi
done <<< "$ROWS"

# ── NO-ABANDON METRIC ─────────────────────────────────────────────────────────
emit_backlog_metric "$BACKLOG" "$BACKLOG_PRS"

# ── RESILIENT-1188: page the operator ONCE per beat if we HELD any PR for a
# systemic red. A real trunk-red / shared-gate break needs a human to clear the
# gate — the reaper deliberately will not mass-close, so nothing else advances
# these PRs until the shared break is fixed.
if [[ "$HELD" -gt 0 && $DRY_RUN -eq 0 && "$SYSTEMIC_ALERTED" -eq 0 ]]; then
    SYSTEMIC_ALERTED=1
    notify_operator "$(printf '🚨 **SYSTEMIC RED — rot-reaper HELD %s PR(s), did NOT close them.**\n\nThe trunk-sentinel reports main/trunk is RED, so these PRs inherit a broken-trunk failure — none of them is individually wrong. Held PRs: %s.\n\nMass-closing them would be the fleet-wide self-strangle (INFRA-3542). A human needs to fix trunk / rerun the broken required job; the held PRs are re-armed and will land on their own once main goes green.' \
        "$HELD" "$(printf '%s' "$HELD_PRS" | tr -s ' ')")" || true
fi

green "=== rot-reaper done: closed=$CLOSED requeued=$REQUEUED armed=$ARMED spared=$SPARED held=$HELD skipped=$SKIPPED backlog=$BACKLOG ==="
reaper_finish ok "{\"closed\":$CLOSED,\"requeued\":$REQUEUED,\"armed\":$ARMED,\"spared\":$SPARED,\"held\":$HELD,\"skipped\":$SKIPPED,\"backlog\":$BACKLOG}"
