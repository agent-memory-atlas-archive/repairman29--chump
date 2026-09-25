#!/usr/bin/env bash
# orphan-allowlist-daemon.sh — INFRA-5426 (INFRA-1861 slice: extends INFRA-1714)
#
# Extends the pr-rescue closed loop (INFRA-1714) with a new arm: when a new
# EVENT_REGISTRY.yaml orphan (a `kind:` entry with no emit site anywhere in
# the tree — "register-without-emit", INFRA-1287) lands on main, this daemon
# emits kind=audit_orphan_landed and opens a batch-allowlist PR that adds the
# orphan to scripts/ci/event-registry-reserved.txt, so the next unrelated PR
# touching the event-registry rule isn't blocked by drift nobody caused.
#
# Two-phase per pass, both idempotent against the state file
# (.chump-locks/orphan-allowlist-daemon-state.json):
#
#   1. DETECT — reuse scripts/ci/test-event-registry-coverage.sh's own
#      report-mode orphan scan (single source of truth for "what counts as
#      an orphan" — no reimplementation of the INFRA-1287 detection logic).
#      Any orphan not yet tracked in the state file gets
#      kind=audit_orphan_landed emitted, keyed to the current HEAD sha.
#
#   2. RESCUE — any state entry still status=landed (not yet PR'd) gets a
#      branch + commit (append to event-registry-reserved.txt) + `gh pr
#      create`. PR title: `auto-allowlist: add orphan <SHA>`.
#
# Modes:
#   --once      single detect+rescue pass (default)
#   --daemon    loop forever, sleeping CHUMP_ORPHAN_DAEMON_INTERVAL_S
#               (default 120s) between passes — keeps this comfortably
#               inside the "within 5 minutes" SLA from INFRA-1861 AC3.
#   --dry-run   detect + print only; never emits ambient or mutates
#               git/gh/state.
#
# Safety rails (mirrors INFRA-1714's pr_rescue.rs):
#   - never pushes to main directly — branch + PR only
#   - skips an orphan that's already reserved by rescue time (someone else
#     fixed it first)
#   - skips an orphan that already has an open PR for its branch — re-run
#     safe, never opens duplicate PRs
#
# Ambient events: audit_orphan_landed {orphan_kind, sha},
#   orphan_allowlist_pr_opened {orphan_kind, sha, pr},
#   orphan_allowlist_pr_failed {orphan_kind, sha, error}
#
# Test hooks (scripts/ci/test-orphan-allowlist-daemon.sh):
#   CHUMP_ORPHAN_DAEMON_COVERAGE_SCRIPT  — override the orphan-lister script
#   CHUMP_ORPHAN_DAEMON_GIT_BIN          — stub git binary
#   CHUMP_ORPHAN_DAEMON_GH_BIN           — stub gh binary
#   CHUMP_ORPHAN_DAEMON_STATE            — override state file path
#   CHUMP_ORPHAN_DAEMON_RESERVED         — override event-registry-reserved.txt path
#   CHUMP_ORPHAN_DAEMON_REPO_ROOT        — override repo root used for git ops
#   CHUMP_ORPHAN_DAEMON_HEAD_SHA         — override HEAD sha (test determinism)
#   CHUMP_AMBIENT_LOG                    — override ambient.jsonl path
#
# Bypass: CHUMP_ORPHAN_ALLOWLIST_DAEMON=0 silently exits 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_ORPHAN_DAEMON_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="${CHUMP_ORPHAN_DAEMON_STATE:-$LOCK_DIR/orphan-allowlist-daemon-state.json}"
RESERVED_TXT="${CHUMP_ORPHAN_DAEMON_RESERVED:-$REPO_ROOT/scripts/ci/event-registry-reserved.txt}"
COVERAGE_SCRIPT="${CHUMP_ORPHAN_DAEMON_COVERAGE_SCRIPT:-$SCRIPT_DIR/../ci/test-event-registry-coverage.sh}"
GIT_BIN="${CHUMP_ORPHAN_DAEMON_GIT_BIN:-git}"
GH_BIN="${CHUMP_ORPHAN_DAEMON_GH_BIN:-gh}"
INTERVAL_S="${CHUMP_ORPHAN_DAEMON_INTERVAL_S:-120}"

MODE="once"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --once)    MODE="once"; shift ;;
        --daemon)  MODE="daemon"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "orphan-allowlist-daemon: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_ORPHAN_ALLOWLIST_DAEMON:-1}" == "0" ]]; then
    echo "[orphan-allowlist-daemon] bypassed via CHUMP_ORPHAN_ALLOWLIST_DAEMON=0"
    exit 0
fi

mkdir -p "$LOCK_DIR"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

emit() {
    local kind="$1" extra_json="$2"
    [[ "$DRY_RUN" == "1" ]] && return 0
    python3 - "$kind" "$extra_json" "$AMBIENT_LOG" <<'PYEOF'
import json, sys, datetime
kind, extra_json, log = sys.argv[1], sys.argv[2], sys.argv[3]
rec = {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "kind": kind}
rec.update(json.loads(extra_json))
with open(log, "a") as f:
    f.write(json.dumps(rec, separators=(",", ":")) + "\n")
PYEOF
}

# List of reserved kind names (comment/whitespace stripped), one per line.
reserved_kinds() {
    sed 's/[[:space:]]*#.*//' "$RESERVED_TXT" 2>/dev/null | sed 's/[[:space:]]*$//' | sed '/^$/d'
}

is_reserved() {
    grep -qxF "$1" <(reserved_kinds)
}

list_orphans() {
    # Reuse the coverage script's own report-mode scan — single source of
    # truth for "what is an orphan" (INFRA-1287 register-without-emit logic).
    CHUMP_REGISTRY_GATE_MODE=report bash "$COVERAGE_SCRIPT" 2>/dev/null \
        | sed -n 's/^  ORPHAN: //p'
}

state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE"; }
state_set() {
    local key="$1" value_json="$2" tmp
    tmp="$(mktemp)"
    jq --arg k "$key" --argjson v "$value_json" '.[$k] = $v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

detect_pass() {
    local head_sha orphan existing
    head_sha="${CHUMP_ORPHAN_DAEMON_HEAD_SHA:-$("$GIT_BIN" -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
    while IFS= read -r orphan; do
        [[ -z "$orphan" ]] && continue
        existing="$(state_get "$orphan")"
        [[ -n "$existing" ]] && continue   # already tracked (landed or pr_opened)
        is_reserved "$orphan" && continue  # already reserved — not a live orphan

        echo "[orphan-allowlist-daemon] new orphan landed: $orphan (sha=$head_sha)"
        emit "audit_orphan_landed" "$(jq -nc --arg k "$orphan" --arg sha "$head_sha" '{orphan_kind:$k, sha:$sha}')"
        [[ "$DRY_RUN" == "1" ]] && continue
        state_set "$orphan" "$(jq -nc --arg sha "$head_sha" '{sha:$sha, status:"landed", pr:null}')"
    done < <(list_orphans)
}

rescue_pass() {
    local orphan sha branch pr_title existing_pr pr_number
    while IFS= read -r orphan; do
        [[ -z "$orphan" ]] && continue
        sha="$(jq -r --arg k "$orphan" '.[$k].sha' "$STATE_FILE")"

        # Someone beat us to it (manual fix landed on main in the meantime).
        if is_reserved "$orphan"; then
            state_set "$orphan" "$(jq -nc --arg sha "$sha" '{sha:$sha, status:"already_reserved", pr:null}')"
            continue
        fi

        branch="auto-allowlist-orphan-${orphan}-${sha}"
        pr_title="auto-allowlist: add orphan ${sha}"

        # Re-run safety: an open PR for this branch already exists.
        existing_pr="$("$GH_BIN" pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || echo "")"
        if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
            state_set "$orphan" "$(jq -nc --arg sha "$sha" --argjson pr "$existing_pr" '{sha:$sha, status:"pr_opened", pr:$pr}')"
            continue
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[orphan-allowlist-daemon] DRY-RUN would open PR '$pr_title' on branch $branch for orphan $orphan"
            continue
        fi

        if ! (
            cd "$REPO_ROOT" &&
            "$GIT_BIN" fetch origin main --quiet &&
            "$GIT_BIN" checkout -B "$branch" origin/main --quiet &&
            printf '%s  # reason: %s — auto-filed by scripts/coord/orphan-allowlist-daemon.sh (INFRA-5426); register-without-emit orphan landed at %s.\n' \
                "$orphan" "$pr_title" "$sha" >> "$RESERVED_TXT" &&
            "$GIT_BIN" add "$RESERVED_TXT" &&
            "$GIT_BIN" commit -m "$pr_title" --quiet &&
            "$GIT_BIN" push -u origin "$branch" --force-with-lease --quiet
        ); then
            emit "orphan_allowlist_pr_failed" "$(jq -nc --arg k "$orphan" --arg sha "$sha" '{orphan_kind:$k, sha:$sha, error:"git_push_failed"}')"
            continue
        fi

        pr_number="$("$GH_BIN" pr create --base main --head "$branch" --title "$pr_title" \
            --body "Auto-filed by scripts/coord/orphan-allowlist-daemon.sh (INFRA-5426, INFRA-1861 slice). Adds registry orphan \`$orphan\` (register-without-emit, landed at $sha) to scripts/ci/event-registry-reserved.txt." \
            --json number 2>/dev/null | jq -r '.number // empty' 2>/dev/null || echo "")"

        if [[ -z "$pr_number" ]]; then
            emit "orphan_allowlist_pr_failed" "$(jq -nc --arg k "$orphan" --arg sha "$sha" '{orphan_kind:$k, sha:$sha, error:"gh_pr_create_failed"}')"
            continue
        fi

        emit "orphan_allowlist_pr_opened" "$(jq -nc --arg k "$orphan" --arg sha "$sha" --argjson pr "$pr_number" '{orphan_kind:$k, sha:$sha, pr:$pr}')"
        state_set "$orphan" "$(jq -nc --arg sha "$sha" --argjson pr "$pr_number" '{sha:$sha, status:"pr_opened", pr:$pr}')"
    done < <(jq -r 'to_entries[] | select(.value.status=="landed") | .key' "$STATE_FILE")
}

run_pass() {
    detect_pass
    rescue_pass
}

if [[ "$MODE" == "daemon" ]]; then
    while true; do
        run_pass
        sleep "$INTERVAL_S"
    done
else
    run_pass
fi
