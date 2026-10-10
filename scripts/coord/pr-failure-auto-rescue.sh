#!/usr/bin/env bash
# pr-failure-auto-rescue.sh — INFRA-1600 MVP.
#
# Linchpin daemon for PR-merge automation. Watches the operator's open
# PRs, pattern-matches CI failure logs against known handlers, and
# auto-applies the corresponding fix. Tonight's manual cascade-fix
# pattern (cargo fmt / adjacent-string-literal / cargo-not-on-PATH /
# chump-binary-not-found / tauri-flake-timeout) is encoded here.
#
# Usage:
#   bash scripts/coord/pr-failure-auto-rescue.sh           # one-shot
#   bash scripts/coord/pr-failure-auto-rescue.sh --loop    # daemon (60s)
#   bash scripts/coord/pr-failure-auto-rescue.sh --dry-run # diagnose only
#
# Env:
#   AUTO_RESCUE_AUTHOR     gh @me or specific user (default: @me)
#   AUTO_RESCUE_COOLDOWN_S 30 min between rescues per (PR, handler) (default 1800)
#   AUTO_RESCUE_MAX_PER_PR 3 lifetime rescues per PR (default 3)
#   GH_TOKEN               must be set
#
# Cool-down + max-per-PR safety: no infinite-loop fix-fix-fix.

set -uo pipefail

DRY_RUN="${DRY_RUN:-0}"  # INFRA-1618: honor env-var override (for tests + ops)
LOOP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --loop)      LOOP=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

AUTHOR="${AUTO_RESCUE_AUTHOR:-@me}"
COOLDOWN_S="${AUTO_RESCUE_COOLDOWN_S:-1800}"
MAX_PER_PR="${AUTO_RESCUE_MAX_PER_PR:-3}"
# INFRA-3542 (COTG terminal disposition): a red-armed PR no fixer can clear, past
# this age, is closed + its gap reopened for a clean redo. Conservative on purpose.
PR_TERMINAL_HOURS="${PR_TERMINAL_HOURS:-6}"
PR_TERMINAL_ENABLED="${PR_TERMINAL_ENABLED:-1}"
# RESILIENT-379 (alert-not-reap): default 0 = NEVER close an auto-merge-armed PR;
# alert the operator and leave it open instead (an armed PR is vouched-for work;
# reaping it on a real-but-trivially-fixable red destroyed #4173/#4175 on 2026-08-23).
# Set to 1 only to opt back into the legacy close+refile for genuinely-abandoned rot.
PR_TERMINAL_CLOSE_ARMED="${PR_TERMINAL_CLOSE_ARMED:-0}"
# RESILIENT-296: freshness gate mirroring the reaper's INFRA-1195 window — skip
# the terminal close if the PR was updated (a fix pushed, CI re-kicked) more
# recently than this many minutes ago, even if the cumulative-red age looks
# terminal. Without this, a fix pushed at minute X can be closed at minute
# X+few because the age computation only looks at PR createdAt, not the most
# recent activity (#3598 false-closed 2026-08-10 this way).
PR_TERMINAL_FRESHNESS_MIN="${PR_TERMINAL_FRESHNESS_MIN:-10}"
CHECK_PR="${CHECK_PR:-}"   # set to a PR number to dry-run the terminal check on it and exit
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/safe-reopen-gap.sh"
# RESILIENT-263: operator escalation to the phone (Discord DM). Sourced, not
# required — if the helper is missing this daemon must still run, so define a
# no-op fallback rather than let a missing notifier take down PR automation.
# shellcheck source=lib/notify-operator.sh
if [[ -f "$SCRIPT_DIR/lib/notify-operator.sh" ]]; then
    source "$SCRIPT_DIR/lib/notify-operator.sh"
else
    notify_operator() { echo "[notify-operator] MISSING lib/notify-operator.sh" >&2; return 0; }
fi
RESCUE_LOG="$REPO_ROOT/.chump-locks/pr-rescue.log"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

mkdir -p "$(dirname "$RESCUE_LOG")"

say() { echo "[pr-rescue $(date -u +%H:%M:%S)] $*"; }

# Emit an ambient event.
emit_event() {
    local kind="$1"; shift
    local fields="$*"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry] would emit kind=$kind $fields"
        return 0
    fi
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$fields" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# Append a rescue-log line. JSON per line for parseability.
log_rescue() {
    local pr="$1"; local handler="$2"; local outcome="$3"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","pr":%s,"handler":"%s","outcome":"%s"}\n' \
        "$ts" "$pr" "$handler" "$outcome" >> "$RESCUE_LOG"
}

# Count past rescue actions for a PR (max-per-PR enforcement).
# NOTE: grep -c outputs "0" on zero-match AND exits 1; piping `|| true`
# triggers another `0` write → captures "0\n0". Use awk for clean count.
count_past_rescues() {
    local pr="$1"
    [[ ! -f "$RESCUE_LOG" ]] && { echo 0; return; }
    awk -v pr="$pr" 'BEGIN{n=0} index($0,"\"pr\":"pr",")>0 {n++} END{print n}' "$RESCUE_LOG"
}

# Check if a (PR, handler) is in cool-down.
in_cooldown() {
    local pr="$1"; local handler="$2"
    [[ ! -f "$RESCUE_LOG" ]] && return 1
    local last_ts
    last_ts=$(grep "\"pr\":$pr," "$RESCUE_LOG" 2>/dev/null \
              | grep "\"handler\":\"$handler\"" \
              | tail -1 \
              | sed -nE 's/.*"ts":"([^"]+)".*/\1/p')
    [[ -z "$last_ts" ]] && return 1
    local last_epoch now_epoch
    last_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null \
                 || date -u -d "$last_ts" "+%s" 2>/dev/null || echo 0)
    now_epoch=$(date -u +%s)
    local delta=$((now_epoch - last_epoch))
    [[ $delta -lt $COOLDOWN_S ]]
}

# Fetch first FAILURE check's job ID for a PR.
first_failed_job_id() {
    local pr="$1"
    gh pr view "$pr" --json statusCheckRollup 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for c in d.get('statusCheckRollup',[]):
        if c.get('conclusion') == 'FAILURE':
            u = c.get('detailsUrl','')
            if '/job/' in u:
                print(u.split('/job/')[1].split('?')[0])
                break
except Exception:
    pass
"
}

# Fetch log excerpt for a job.
fetch_log_excerpt() {
    local job_id="$1"
    [[ -z "$job_id" ]] && return 1
    curl -sL "https://api.github.com/repos/repairman29/chump/actions/jobs/${job_id}/logs" \
        -H "Authorization: token $(gh auth token 2>/dev/null)" 2>/dev/null | tail -200
}

# Resolve branch + headRefName for a PR.
pr_branch() {
    gh pr view "$1" --json headRefName --jq '.headRefName' 2>/dev/null
}

# ── HANDLERS ──────────────────────────────────────────────────────────────────
# Each returns 0 on success, non-zero on failure. Each is responsible for
# its OWN rebase / commit / push. Cool-down + max enforced by main loop.

handle_cargo_fmt_drift() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "^Diff in .*\.rs:"; then
        return 99  # not my pattern
    fi
    say "  → handler: cargo_fmt_drift on PR $pr"
    [[ $DRY_RUN -eq 1 ]] && { log_rescue "$pr" "cargo_fmt_drift" "dry_run_skip"; return 0; }
    local branch wt
    branch=$(pr_branch "$pr")
    wt="/tmp/auto-rescue-${pr}"
    rm -rf "$wt"
    git clone --shared "$REPO_ROOT" "$wt" 2>&1 >/dev/null
    (
        cd "$wt" || return 1
        git remote remove origin 2>/dev/null
        git remote add chump https://github.com/repairman29/chump.git
        git fetch chump "$branch" 2>&1 >/dev/null
        git checkout -B "$branch" "chump/$branch" 2>&1 >/dev/null
        export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
        cargo fmt 2>&1 >/dev/null
        if ! git diff --quiet; then
            git -c commit.gpgsign=false commit --no-verify -am "fix(ci): cargo fmt (auto-rescue INFRA-1600)" 2>&1 >/dev/null
            git push --force-with-lease chump "HEAD:refs/heads/$branch" 2>&1 >/dev/null
            log_rescue "$pr" "cargo_fmt_drift" "fixed"
            emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"cargo_fmt_drift\",\"outcome\":\"fixed\""
        else
            log_rescue "$pr" "cargo_fmt_drift" "noop"
        fi
    )
    rm -rf "$wt"
    return 0
}

handle_cargo_not_found() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "cargo: command not found"; then
        return 99
    fi
    say "  → handler: cargo_not_found on PR $pr — needs ensure-cargo-on-path.sh helper"
    # Just emit info — actual fix is to wait for #2266 to land + rebase.
    # Future iteration: cherry-pick the helper file from main if it exists on main.
    [[ $DRY_RUN -eq 1 ]] && return 0
    log_rescue "$pr" "cargo_not_found" "awaiting_pr_2266_merge"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"cargo_not_found\",\"outcome\":\"awaiting_pr_2266_merge\""
    return 0
}

handle_chump_bin_not_found() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "chump binary not found"; then
        return 99
    fi
    say "  → handler: chump_bin_not_found on PR $pr"
    [[ $DRY_RUN -eq 1 ]] && return 0
    log_rescue "$pr" "chump_bin_not_found" "awaiting_pr_2266_merge"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"chump_bin_not_found\",\"outcome\":\"awaiting_pr_2266_merge\""
    return 0
}

handle_tauri_flake() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "Wait timed out.*chump-chat"; then
        return 99
    fi
    say "  → handler: tauri_flake on PR $pr — rerunning failed checks"
    [[ $DRY_RUN -eq 1 ]] && return 0
    local run_id
    run_id=$(gh pr view "$pr" --json statusCheckRollup 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin).get('statusCheckRollup',[]):
    if c.get('conclusion')=='FAILURE' and 'tauri' in (c.get('name','') or '').lower():
        u=c.get('detailsUrl','')
        if '/runs/' in u: print(u.split('/runs/')[1].split('/')[0]); break
")
    if [[ -n "$run_id" ]]; then
        gh run rerun "$run_id" --failed --repo repairman29/chump 2>&1 | tail -1
        log_rescue "$pr" "tauri_flake" "rerun_triggered"
        emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"tauri_flake\",\"outcome\":\"rerun_triggered\""
    fi
    return 0
}

handle_audit_chump_bin_hardcoded() {
    # INFRA-1618: ACTIVE-FIX handler. Detects workflow-YAML-level CHUMP_BIN
    # hardcode failures (audit job step 7, ACP smoke). When the fix commits
    # are already on main, rebases the failing PR via `gh pr update-branch`.
    # When they're not yet on main, falls back to a stub (inline-patch is
    # complex enough to file separately if it ever becomes critical).
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -qE "target/(debug|release)/chump not found"; then
        return 99  # not my pattern
    fi
    say "  → handler: audit_chump_bin_hardcoded on PR $pr (ACTIVE-FIX)"
    [[ $DRY_RUN -eq 1 ]] && { log_rescue "$pr" "audit_chump_bin_hardcoded" "dry_run_skip"; return 0; }

    # Check if the two known-good fix commits are on origin/main yet.
    # We look for them by commit message (stable across cherry-picks).
    git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
    local audit_fix_on_main acp_fix_on_main
    audit_fix_on_main=$(git -C "$REPO_ROOT" log origin/main --oneline -100 \
        --grep "audit job honors CARGO_TARGET_DIR" 2>/dev/null | head -1)
    acp_fix_on_main=$(git -C "$REPO_ROOT" log origin/main --oneline -100 \
        --grep "ACP workflow sources cargo PATH" 2>/dev/null | head -1)

    if [[ -n "$audit_fix_on_main" && -n "$acp_fix_on_main" ]]; then
        say "    fix is on main; rebasing PR $pr via gh pr update-branch"
        local out
        out=$(bash "$(dirname "${BASH_SOURCE[0]}")/lib/pr_rebase.sh" "$pr" repairman29/chump main 2>&1)
        if echo "$out" | grep -qi "updated\|success\|skipping rebase"; then
            say "    REBASED: $pr"
            log_rescue "$pr" "audit_chump_bin_hardcoded" "rebased_against_main"
            emit_event "pr_auto_rescue_invoked" \
                "\"pr\":$pr,\"handler\":\"audit_chump_bin_hardcoded\",\"outcome\":\"rebased_against_main\""
        else
            say "    rebase failed: $(echo "$out" | head -1)"
            log_rescue "$pr" "audit_chump_bin_hardcoded" "rebase_failed"
            emit_event "pr_auto_rescue_invoked" \
                "\"pr\":$pr,\"handler\":\"audit_chump_bin_hardcoded\",\"outcome\":\"rebase_failed\""
        fi
    else
        say "    fix NOT on main yet (audit=$audit_fix_on_main acp=$acp_fix_on_main); inline-patch not implemented"
        log_rescue "$pr" "audit_chump_bin_hardcoded" "waiting_for_main"
        emit_event "pr_auto_rescue_invoked" \
            "\"pr\":$pr,\"handler\":\"audit_chump_bin_hardcoded\",\"outcome\":\"waiting_for_main\""
    fi
    return 0
}

handle_adjacent_string_eprintln() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -qE "expected.*\`,\`.*found.*\"Usage:"; then
        return 99
    fi
    say "  → handler: adjacent_string_eprintln on PR $pr — needs manual diagnosis"
    # This pattern is from union-merge. Auto-fix would need to identify the
    # specific eprintln! call and combine the strings. Punt to operator for now.
    [[ $DRY_RUN -eq 1 ]] && return 0
    log_rescue "$pr" "adjacent_string_eprintln" "operator_alert"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"adjacent_string_eprintln\",\"outcome\":\"operator_alert\""
    # RESILIENT-263: this outcome has been called `operator_alert` since
    # INFRA-1600 while alerting no operator — it wrote a log line and an ambient
    # event and stopped. Now it actually reaches the phone. This is the
    # "no handler can fix it, a human must decide" case, which is precisely what
    # the operator asked to be told about.
    notify_operator "$(printf '⚠️ **PR #%s needs you** — no auto-handler can fix it.\n\nPattern: `adjacent_string_eprintln` (from a union-merge). Fixing it means identifying the specific `eprintln!` call and combining the string literals — deliberately not automated, because guessing at it would corrupt the message.\n\nhttps://github.com/repairman29/chump/pull/%s\n\nLeft open, not closed.' "$pr" "$pr")" || true
    return 0
}

# RESILIENT-299: count other OPEN PRs (excluding $1) whose statusCheckRollup
# has a FAILURE conclusion on any of the check names in the comma-separated
# list $2 (e.g. "audit,test"). Prints "SYSTEMIC|<check>|<n>" for the first
# check found FAILURE on >=2 other PRs, else "ISOLATED".
count_shared_red_prs() {
    local pr="$1"; local red_csv="$2"
    [[ -z "$red_csv" ]] && { echo "ISOLATED"; return; }
    local list
    list=$(gh pr list --repo repairman29/chump --state open --limit 100 \
           --json number,statusCheckRollup 2>/dev/null) || { echo "ISOLATED"; return; }
    echo "$list" | python3 -c "
import json, sys
pr = int(sys.argv[1])
red = [c.strip() for c in sys.argv[2].split(',') if c.strip()]
try:
    prs = json.load(sys.stdin)
except Exception:
    print('ISOLATED'); sys.exit(0)
for name in red:
    n = 0
    for p in prs:
        if p.get('number') == pr:
            continue
        roll = p.get('statusCheckRollup') or []
        if any(c.get('name') == name and c.get('conclusion') == 'FAILURE' for c in roll):
            n += 1
    if n >= 2:
        print('SYSTEMIC|%s|%d' % (name, n))
        sys.exit(0)
print('ISOLATED')
" "$pr" "$red_csv"
}

# ── COTG terminal disposition (INFRA-3542) ────────────────────────────────────
# A red-armed PR that no fix handler cleared, past the terminal age, is closed with
# an honest comment and its gap reopened for a clean redo. Without this, unfixable-
# real-red PRs (compile / test / audit failures — matching none of the handlers
# above) rot armed forever, which is exactly how #3499/#3510/#3527 sat 22-31h.
# Conservative: fires ONLY on auto-merge-armed + BLOCKED + a REQUIRED-check FAILURE
# (never CANCELLED or pending — those are flakes for the rerun handlers) past
# PR_TERMINAL_HOURS. Returns 0 iff it disposed the PR.
try_terminal_dispose() {
    local pr="$1"
    [[ "$PR_TERMINAL_ENABLED" != "1" ]] && return 1
    local j verdict
    j=$(gh pr view "$pr" --repo repairman29/chump \
        --json autoMergeRequest,mergeStateStatus,createdAt,updatedAt,headRefName,statusCheckRollup 2>/dev/null) || return 1
    verdict=$(echo "$j" | python3 -c '
import json,sys,datetime
d=json.load(sys.stdin); hrs=float(sys.argv[1]); fresh_min=float(sys.argv[2])
armed=d.get("autoMergeRequest") is not None
blocked=d.get("mergeStateStatus")=="BLOCKED"
req={"audit","test","ACP protocol smoke test (Zed / JetBrains compatible)"}
roll=d.get("statusCheckRollup") or []
red=[c.get("name") for c in roll if c.get("name") in req and c.get("conclusion")=="FAILURE"]
created=datetime.datetime.fromisoformat(d["createdAt"].replace("Z","+00:00"))
now=datetime.datetime.now(datetime.timezone.utc)
age=(now-created).total_seconds()/3600
updated=d.get("updatedAt")
fresh_age_min=None
if updated:
    updated_dt=datetime.datetime.fromisoformat(updated.replace("Z","+00:00"))
    fresh_age_min=(now-updated_dt).total_seconds()/60
if armed and blocked and red and age>=hrs:
    if fresh_age_min is not None and fresh_age_min < fresh_min:
        print("FRESH|%s|%.1f|%.1f" % (d.get("headRefName",""), age, fresh_age_min))
    else:
        print("DISPOSE|%s|%.1f|%s" % (d.get("headRefName",""), age, ",".join(red)))
else:
    print("SKIP|armed=%s blocked=%s red=%s age=%.1f" % (armed, blocked, ",".join(red) or "-", age))
' "$PR_TERMINAL_HOURS" "$PR_TERMINAL_FRESHNESS_MIN" 2>/dev/null)

    if [[ "$verdict" == FRESH* ]]; then
        # RESILIENT-296: PR was updated (fix pushed, CI re-running) more
        # recently than the freshness window — the cumulative-red history is
        # stale. Defer instead of destroying in-flight work (#3598 class).
        local _fresh_age; _fresh_age=$(echo "$verdict" | cut -d'|' -f4)
        say "  → terminal: PR #$pr SKIP CLOSE (RESILIENT-296) — updated ${_fresh_age}m ago (< ${PR_TERMINAL_FRESHNESS_MIN}m freshness window), deferring"
        emit_event "curator_skip_active_rebase" "\"pr\":$pr,\"reason\":\"updated_within_freshness_window\",\"age_minutes\":${_fresh_age}"
        return 1
    fi

    if [[ "$verdict" != DISPOSE* ]]; then
        [[ $DRY_RUN -eq 1 ]] && say "  → terminal: PR #$pr not a candidate (${verdict#SKIP|})"
        return 1
    fi

    local branch age red gap
    branch=$(echo "$verdict" | cut -d'|' -f2)
    age=$(echo "$verdict" | cut -d'|' -f3)
    red=$(echo "$verdict" | cut -d'|' -f4)
    # Gap id from the claim branch: chump/<gap-id>-claim → GAP-ID (upcased).
    gap=$(echo "$branch" | sed -nE 's#^chump/([a-zA-Z]+-[0-9]+)-claim$#\1#p' | tr '[:lower:]' '[:upper:]')

    # RESILIENT-299: before disposing, check whether this PR's red is unique
    # to it, or shared across other open PRs — i.e. a systemic gate outage
    # (e.g. the bypass-var ceiling bug) rather than a per-PR failure. If N>=2
    # other open PRs share the same failing check, this is fleet-wide red;
    # closing this PR would be reaping good work for someone else's outage
    # (#3633, #3623, #3598).
    local shared_verdict
    shared_verdict=$(count_shared_red_prs "$pr" "$red")
    if [[ "$shared_verdict" == SYSTEMIC* ]]; then
        local _check _n
        _check=$(echo "$shared_verdict" | cut -d'|' -f2)
        _n=$(echo "$shared_verdict" | cut -d'|' -f3)
        say "  → terminal: PR #$pr SKIP CLOSE (RESILIENT-299) — check '$_check' is red on $_n other open PR(s), systemic gate outage, not per-PR failure"
        emit_event "curator_skip_active_rebase" "\"pr\":$pr,\"reason\":\"systemic_shared_red\",\"check\":\"${_check}\",\"shared_count\":${_n}"
        if [[ $DRY_RUN -ne 1 ]]; then
            notify_operator "$(printf '⚠️ **Systemic red detected — PR #%s left OPEN** (RESILIENT-299)\n\nCheck `%s` is FAILING on %s other open PR(s) too — this looks like a fleet-wide gate outage, not a per-PR bug. auto-rescue is refusing to close it.\n\nhttps://github.com/repairman29/chump/pull/%s' \
                "$pr" "$_check" "$_n" "$pr")" || true
        fi
        return 1
    fi

    # RESILIENT-379 (alert-not-reap, incident 2026-08-23): an auto-merge-ARMED PR is
    # one the fleet/operator VOUCHED for. Summarily CLOSING it on a real-but-usually-
    # trivially-fixable required-check red destroys vouched-for work — exactly how
    # #4173 (RESILIENT-376, the Pixel $0 worker) and #4175 (INFRA-3677) were reaped:
    # each red was a genuine 1-line CI-hygiene failure (#4173 preflight-parity
    # allowlist, #4175 bypass-var ceiling), NOT shared and NOT flaky, so the
    # systemic-shared-red guard above never fired (it needs the SAME check red on >=2
    # OTHER open PRs, and here the two PRs failed DIFFERENT checks). The reaper cannot
    # tell "trivially-fixable" from "genuinely dead," and the DISPOSE path only ever
    # reaches here for ARMED PRs (see the python gate: armed and blocked and red).
    # So the safe default disposition for a vouched-for PR no handler could clear is
    # to ALERT a human and LEAVE IT OPEN — never to reap it. Closing stays available
    # behind an explicit opt-in (PR_TERMINAL_CLOSE_ARMED=1) for genuinely-abandoned
    # armed rot, but the default is alert-only.
    if [[ "${PR_TERMINAL_CLOSE_ARMED:-0}" != "1" ]]; then
        say "  → terminal: PR #$pr ALERT-NOT-REAP (RESILIENT-379) — armed+red[$red] ${age}h, no handler cleared it; leaving OPEN and escalating (close is opt-in via PR_TERMINAL_CLOSE_ARMED=1)"
        emit_event "pr_terminal_alert_not_reaped" "\"pr\":$pr,\"red\":\"$red\",\"age_h\":${age},\"branch\":\"$branch\""
        if [[ $DRY_RUN -ne 1 ]]; then
            local on_main_a="unknown" first_red_a
            first_red_a="$(echo "$red" | tr ',' '\n' | head -1 | sed 's/^ *//;s/ *$//')"
            if [[ -n "$first_red_a" ]]; then
                on_main_a="$(gh run list --branch main --limit 15 --json conclusion,name \
                    --jq "[.[] | select(.name==\"${first_red_a}\")][0].conclusion // \"no-recent-run\"" \
                    2>/dev/null || echo "lookup-failed")"
            fi
            notify_operator "$(printf '⚠️ **Armed PR #%s needs you — LEFT OPEN, not reaped** (RESILIENT-379 alert-not-reap)\n\nAuto-merge was armed but required check(s) `%s` stayed RED for **%sh** and no auto-handler cleared it.\n`%s` on main right now: **%s**\nBranch: `%s`\n\nhttps://github.com/repairman29/chump/pull/%s\n\nThis PR was vouched-for (armed), so auto-rescue is escalating instead of closing. If the red is a trivial CI-hygiene failure (parity allowlist / bypass ceiling / fmt), push the 1-line fix and it lands. If it is genuinely dead, close it by hand.' \
                "$pr" "${red:-?}" "$age" "${first_red_a:-?}" "$on_main_a" "${branch}" "$pr")" || true
        fi
        return 1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        say "  → TERMINAL (dry-run): PR #$pr armed+red[$red] ${age}h ≥ ${PR_TERMINAL_HOURS}h — WOULD close + reopen gap ${gap:-<unparsed:$branch>} (PR_TERMINAL_CLOSE_ARMED=1 opt-in)"
        return 1   # dry-run never acts
    fi

    local body
    body="Auto-closed by pr-failure-auto-rescue (INFRA-3542, COTG self-heal): auto-merge was armed but required check(s) [$red] stayed RED for ${age}h and no fix handler could clear it. Closing so the queue stays honest.${gap:+ Gap ${gap} has been reopened for a clean redo.} This is not a rejection of the work — the branch is red and stale, and the fleet will pick it up fresh."
    if ! gh pr close "$pr" --repo repairman29/chump --comment "$body" >/dev/null 2>&1; then
        say "  terminal: gh pr close failed for #$pr"; return 1
    fi
    [[ -n "$gap" ]] && { safe_reopen_gap "$gap" || true; }
    say "  → TERMINAL: closed PR #$pr (red[$red] ${age}h) + reopened gap ${gap:-<none>}"
    log_rescue "$pr" "terminal_dispose" "closed_refiled"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"terminal_dispose\",\"outcome\":\"closed_refiled\",\"gap\":\"${gap}\",\"age_h\":${age}"

    # RESILIENT-263: this is the moment a production line stops — a PR the fleet
    # had already armed for merge is destroyed. Until now the operator's only
    # notice was a GitHub comment he had to go looking for. PR #3510 died right
    # here on 2026-08-08 and he found out hours later, by asking.
    #
    # The "on main right now" lookup is the load-bearing part: it is exactly the
    # question that separates a real failure from a false red, and exactly the
    # one he would otherwise have to go answer by hand at 11pm.
    local on_main="unknown" first_red
    first_red="$(echo "$red" | tr ',' '\n' | head -1 | sed 's/^ *//;s/ *$//')"
    if [[ -n "$first_red" ]]; then
        on_main="$(gh run list --branch main --limit 15 --json conclusion,name \
            --jq "[.[] | select(.name==\"${first_red}\")][0].conclusion // \"no-recent-run\"" \
            2>/dev/null || echo "lookup-failed")"
    fi
    notify_operator "$(printf '🛑 **Auto-closed PR #%s** — a line stopped.\n\nRed required check(s): `%s`\nStayed red: **%sh**\n`%s` on main right now: **%s**\nGap: %s (reopened)\n\nhttps://github.com/repairman29/chump/pull/%s\n\nIf that check is **green on main**, this was probably a false red and the work is fine — reopen and re-run. RESILIENT-262 tracks making that call automatically instead of asking you.' \
        "$pr" "${red:-?}" "$age" "${first_red:-?}" "$on_main" "${gap:-<none>}" "$pr")" || true
    return 0
}

# ── MAIN LOOP ─────────────────────────────────────────────────────────────────
run_once() {
    say "scanning open PRs by $AUTHOR…"
    local pr_list
    pr_list=$(gh pr list --repo repairman29/chump --state open \
              --author "$AUTHOR" --limit 50 \
              --json number,title 2>/dev/null) || {
        say "ERROR: gh pr list failed"
        return 1
    }
    local prs
    prs=$(echo "$pr_list" | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    print(p['number'])
")
    local seen=0 rescued=0
    for pr in $prs; do
        seen=$((seen + 1))
        # COTG terminal disposition (INFRA-3542) runs FIRST and self-gates on age,
        # so an aged red-armed PR gets closed+refiled even if it maxed out on
        # rescue attempts (or never matched any handler, so past-count is 0).
        if try_terminal_dispose "$pr"; then rescued=$((rescued + 1)); continue; fi
        local past=$(count_past_rescues "$pr")
        if [[ "$past" -ge "$MAX_PER_PR" ]]; then
            continue
        fi
        local job_id
        job_id=$(first_failed_job_id "$pr")
        [[ -z "$job_id" ]] && continue

        local log
        log=$(fetch_log_excerpt "$job_id")
        [[ -z "$log" ]] && continue

        say "PR $pr: examining failure (past rescues: $past)"

        # Dispatch in order; each handler self-checks pattern.
        # INFRA-1618: audit_chump_bin_hardcoded is ACTIVE (rebases) — try first
        # so it preempts the passive chump_bin_not_found handler that just logs.
        for handler in audit_chump_bin_hardcoded cargo_fmt_drift tauri_flake cargo_not_found chump_bin_not_found adjacent_string_eprintln; do
            if in_cooldown "$pr" "$handler"; then
                continue
            fi
            "handle_$handler" "$pr" "$log"
            local rc=$?
            if [[ $rc -eq 0 ]]; then
                rescued=$((rescued + 1))
                break  # one handler per PR per scan
            fi
        done
    done
    say "scan complete: $seen PRs, $rescued action(s) taken"
}

if [[ -n "$CHECK_PR" ]]; then
    DRY_RUN=1
    say "terminal-dispose check for PR #$CHECK_PR (dry-run, no action):"
    try_terminal_dispose "$CHECK_PR" || true
    exit 0
fi

if [[ $LOOP -eq 1 ]]; then
    say "starting loop mode (interval 60s)…"
    while true; do
        run_once
        sleep 60
    done
else
    run_once
fi
