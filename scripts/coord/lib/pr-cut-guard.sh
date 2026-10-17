#!/usr/bin/env bash
# scripts/coord/lib/pr-cut-guard.sh — RESILIENT-1616
#
# ONE shared predicate for "is this PR deliberately cut?" that every PR-mutating
# organ consults BEFORE it reopens, arms, rebases or comments. A PR a human or
# architect cut on purpose (scripts/coord/pr-cut.sh / `chump pr cut`) is
# TERMINAL — no organ may bring it back. RESILIENT-1606/1607 (#5527) taught only
# post-push-integrity-watch.sh and trunk-recovery-reviver.sh this; the receipt
# for this gap is auto-arm-sweeper.sh re-arming the cut duplicate #5562 at
# 18:29Z 2026-10-17, which would have landed the same diff twice. This lib is
# the single source of truth so no future organ can forget.
#
# A PR is "cut" when EITHER signal is present:
#   1. it carries the `pr-cut` label (the terminal label pr-cut.sh stamps), OR
#   2. a kind=pr_cut ambient event names that PR (the label may not be visible
#      yet, or gh reads may be rate-limited, but the event is local and cheap).
#
# Source this file, then:
#
#   pr_is_cut <N> [labels_hint] [repo]
#       rc 0  → PR is cut (skip)         rc 1 → not cut (proceed)
#     labels_hint (optional) is a space/comma-separated label list the caller
#     already fetched — pass it to avoid an extra gh read in a hot loop. When
#     omitted, falls back to `gh pr view <N> --json labels`.
#
#   pr_cut_honored <N> <organ> <action> [labels_hint] [repo]
#       rc 0  → PR is cut; a kind=pr_cut_honored event was emitted and the
#               caller MUST skip the action.
#       rc 1  → not cut; proceed.
#     <organ> is the honoring script's basename, <action> the thing being
#     skipped (reopen|arm|rebase|comment).
#
# Env: CHUMP_AMBIENT_PATH / CHUMP_AMBIENT_LOG override ambient.jsonl.
#      CHUMP_PR_CUT_REPO overrides the repo for gh reads (default repairman29/chump).
#
# scanner-anchor: "kind":"pr_cut_honored"

# Guard against double-source.
[[ -n "${__PR_CUT_GUARD_SH:-}" ]] && return 0
__PR_CUT_GUARD_SH=1

_PR_CUT_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/coord/lib/ambient-write.sh
source "$_PR_CUT_GUARD_DIR/ambient-write.sh" 2>/dev/null || _ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }

_pr_cut_ambient_path() {
    if [[ -n "${CHUMP_AMBIENT_PATH:-}" ]]; then printf '%s' "$CHUMP_AMBIENT_PATH"; return; fi
    if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then printf '%s' "$CHUMP_AMBIENT_LOG"; return; fi
    printf '%s' "$_PR_CUT_GUARD_DIR/../../../.chump-locks/ambient.jsonl"
}

# pr_is_cut <N> [labels_hint] [repo] -> rc 0 if cut
pr_is_cut() {
    local pr="$1" labels_hint="${2:-}" repo="${3:-${CHUMP_PR_CUT_REPO:-repairman29/chump}}"
    [[ "$pr" =~ ^[0-9]+$ ]] || return 1

    # Signal 1: label. Prefer the caller's pre-fetched list (no gh read).
    if [[ -n "$labels_hint" ]]; then
        # Normalize commas and underscores (sweeper stores labels with _ for spaces).
        case " ${labels_hint//,/ } " in
            *" pr-cut "*|*" pr_cut "*) return 0 ;;
        esac
    else
        local labels_json
        labels_json="$(gh pr view "$pr" --repo "$repo" --json labels 2>/dev/null)" || labels_json=""
        if [[ -n "$labels_json" ]] && printf '%s' "$labels_json" \
            | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any((l.get("name","")=="pr-cut") for l in (d.get("labels") or [])) else 1)' 2>/dev/null; then
            return 0
        fi
    fi

    # Signal 2: a local kind=pr_cut ambient event for this PR.
    local ambient; ambient="$(_pr_cut_ambient_path)"
    if [[ -f "$ambient" ]]; then
        if grep -F '"kind":"pr_cut"' "$ambient" 2>/dev/null | grep -qE "\"pr\":${pr}([,}])"; then
            return 0
        fi
    fi
    return 1
}

# pr_cut_honored <N> <organ> <action> [labels_hint] [repo] -> rc 0 if cut (emitted + skip)
pr_cut_honored() {
    local pr="$1" organ="${2:-unknown}" action="${3:-mutate}" labels_hint="${4:-}" repo="${5:-}"
    if pr_is_cut "$pr" "$labels_hint" "$repo"; then
        local ambient; ambient="$(_pr_cut_ambient_path)"
        mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
        _ambient_write "$ambient" "$(printf '{"ts":"%s","kind":"pr_cut_honored","pr":%s,"organ":"%s","action":"%s"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$organ" "$action")"
        return 0
    fi
    return 1
}
