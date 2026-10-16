#!/usr/bin/env bash
# scripts/ops/lib/disarm-classify.sh — INFRA-8178
#
# Pure classification: is a GitHub `auto_merge_disabled` timeline event a
# genuine HUMAN disarm, or just GitHub's own disarm-on-failed-required-check
# behavior? auto-arm-sweeper.sh (INFRA-8047) was treating every
# auto_merge_disabled event attributed to the automation login as a
# permanent human hold and never re-arming — but GitHub attributes
# auto_merge_disabled to whoever *enabled* auto-merge (almost always the
# automation login itself) whenever a required check fails after arming.
# Receipts: PR #5488 disarmed 09:41Z/11:50Z/13:35Z and PR #5476 at 04:05Z,
# all attributed to repairman29, with no human present.
#
# A disarm counts as HUMAN only if:
#   1. the timeline actor is NOT the automation login, AND
#   2. the disarm timestamp is NOT within DISARM_WINDOW_S seconds after a
#      failed/timed-out required check completed on the same head SHA.
#
# Everything here is a pure function (data in, verdict out via exit code) so
# it can be unit-tested with synthetic fixtures without a real `gh` session
# — see scripts/ci/test-auto-arm-sweeper.sh.

[[ -n "${_CHUMP_DISARM_CLASSIFY_LIB_LOADED:-}" ]] && return 0
_CHUMP_DISARM_CLASSIFY_LIB_LOADED=1

CHUMP_AUTOARM_DISARM_WINDOW_S="${CHUMP_AUTOARM_DISARM_WINDOW_S:-600}"

# to_epoch <ISO8601Z timestamp> -> epoch seconds on stdout, rc 0.
# Portable across GNU date (-d) and BSD/macOS date (-j -f).
to_epoch() {
    date -u -d "$1" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

# failed_check_near_disarm <disarm_ts> [<window_s>]
# stdin: one check `completed_at` ISO8601 timestamp per line (caller passes
# only failed/timed-out checks). rc 0 if any of them completed in the
# `window_s` seconds immediately BEFORE disarm_ts (check failed, then
# auto-merge got disabled as a direct consequence). rc 1 otherwise.
failed_check_near_disarm() {
    local disarm_ts="$1" window="${2:-$CHUMP_AUTOARM_DISARM_WINDOW_S}"
    local disarm_epoch cts cepoch delta
    disarm_epoch="$(to_epoch "$disarm_ts")" || return 1
    [[ -z "$disarm_epoch" ]] && return 1
    while IFS= read -r cts; do
        [[ -z "$cts" ]] && continue
        cepoch="$(to_epoch "$cts")" || continue
        [[ -z "$cepoch" ]] && continue
        delta=$(( disarm_epoch - cepoch ))
        if (( delta >= 0 && delta <= window )); then
            return 0
        fi
    done
    return 1
}

# is_bot_actor <actor_login>
# rc 0 if the login is a bot/app account (GitHub Apps and Actions logins
# carry a `[bot]` suffix; `github-actions` itself sometimes shows up
# suffix-less in older timeline payloads) — never a real human, regardless
# of timing. rc 1 otherwise.
is_bot_actor() {
    local actor="$1"
    [[ -z "$actor" ]] && return 1
    case "$actor" in
        *'[bot]'|github-actions) return 0 ;;
    esac
    return 1
}

# is_human_disarm <actor_login> <automation_login> <disarm_ts> [<window_s>]
# stdin: failed/timed-out required-check completion timestamps (one per
# line), same as failed_check_near_disarm.
# rc 0 = HUMAN disarm, respect it (don't re-arm until a new push).
# rc 1 = bot/gate-triggered disarm, safe to re-arm once the head is green.
is_human_disarm() {
    local actor="$1" automation_login="$2" disarm_ts="$3" window="${4:-$CHUMP_AUTOARM_DISARM_WINDOW_S}"
    local checks
    checks="$(cat)"
    if [[ -n "$actor" ]] && { [[ "$actor" == "$automation_login" ]] || is_bot_actor "$actor"; }; then
        return 1
    fi
    if [[ -n "$disarm_ts" ]] && printf '%s\n' "$checks" | failed_check_near_disarm "$disarm_ts" "$window"; then
        return 1
    fi
    return 0
}
