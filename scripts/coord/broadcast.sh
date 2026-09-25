#!/usr/bin/env bash
# broadcast.sh — Structured agent-to-agent messaging via the ambient stream.
#
# Phase 1: dual-publishes to both ambient.jsonl (file-based, always) and
# NATS JetStream (chump.events.*, when chump-coord is available). Agents
# that haven't installed NATS yet continue to receive events via the file
# stream; NATS-connected agents get real-time fanout without polling.
#
# INFRA-1115 (mailboxes): every event type now accepts a leading
# --to <recipient-session-id> flag. When set, the event is ALSO appended
# to .chump-locks/inbox/<recipient>.jsonl so the recipient can read
# targeted messages without scanning the whole ambient stream.
# Glob recipients (e.g. --to fleet-worker-*) expand at send-time against
# live session lease files in .chump-locks/.
#
# Usage:
#   scripts/coord/broadcast.sh [--to <recipient>] [--reply-to <parent-corr-id>] [--urgency INFO|WARN|CRIT|EMERGENCY] INTENT  <gap-id> [file1,file2,...]
#   scripts/coord/broadcast.sh [--to <recipient>] [--reply-to <parent-corr-id>] [--urgency INFO|WARN|CRIT|EMERGENCY] HANDOFF <gap-id> <to-session>
#   scripts/coord/broadcast.sh [--to <recipient>] [--reply-to <parent-corr-id>] [--urgency INFO|WARN|CRIT|EMERGENCY] STUCK   <gap-id> "<reason>"
#   scripts/coord/broadcast.sh [--to <recipient>] [--reply-to <parent-corr-id>] [--urgency INFO|WARN|CRIT|EMERGENCY] DONE    <gap-id> [commit-sha]
#   scripts/coord/broadcast.sh [--to <recipient>] [--reply-to <parent-corr-id>] [--urgency INFO|WARN|CRIT|EMERGENCY] WARN    "<message>"
#   scripts/coord/broadcast.sh [--to <recipient>] [--reply-to <parent-corr-id>] [--urgency INFO|WARN|CRIT|EMERGENCY] ALERT   kind=<kind> "<message>"
#   scripts/coord/broadcast.sh --reply-to <proposal-corr-id> FEEDBACK preference <subject> "<rationale>" +1|-1
#
# EFFECTIVE-028 — corr_id threading (--reply-to):
#   --reply-to <parent-corr-id>
#     Sets corr_id=<parent-corr-id> in the emitted payload so this event
#     threads under the parent broadcast. Also writes parent_corr_id=<parent-corr-id>
#     for explicit lineage. Use when voting on a specific proposal:
#       broadcast.sh --reply-to abc-123 FEEDBACK preference some-subject "vote +1" +1
#     The deliberator tallies FEEDBACK/preference votes keyed by corr_id, so
#     --reply-to ensures the vote lands on the correct proposal's tally.
#
# Urgency tiers (INFRA-2015):
#   INFO      (default) — inbox + ambient only; next-session pickup
#   WARN      — inbox + ambient + kind=urgent_broadcast event (5-min loop tick)
#   CRIT      — inbox + ambient + URGENT-INBOX.jsonl (PostToolUse hook, ~1 tool call)
#   EMERGENCY — all of above + inbox-injector.sh (immediate tmux send-keys)
#
# Event schema (all events):
#   event          — one of: INTENT HANDOFF STUCK DONE WARN ALERT FEEDBACK
#   session        — sender's session ID
#   ts             — ISO-8601 UTC timestamp
#   gap            — gap ID (when applicable)
#   files          — comma-separated file paths (INTENT only)
#   to             — recipient session (HANDOFF, or any event with --to)
#   reason         — free-form note (STUCK, WARN, ALERT)
#   commit         — sha (DONE only)
#   kind           — alert sub-type (ALERT only)
#   corr_id        — correlation ID; auto-derived from gap-id/branch/ts unless overridden
#   parent_corr_id — set when --reply-to used; links this event to a parent broadcast
#
# Agents should check ambient.jsonl for INTENT events from the last 5 minutes
# before claiming a gap. If another session announced INTENT for the same gap,
# pause 10 seconds and re-check before proceeding.
#
# INFRA-1998 (Rust-first Phase 1): when CHUMP_MESSAGING_RUST=1 and the
# chump-broadcast binary is on $PATH, exec the Rust port. Otherwise the
# legacy bash body below runs unchanged. Phase 1 ships both paths; Phase
# 2 (separate gap) flips the default; Phase 3 removes bash.
#
# INFRA-1944 (delivery-confirmation receipts, slice A of INFRA-1862):
#   --await <seconds>  — after sending, block up to <seconds> waiting for
#     the recipient's chump-inbox.sh read to consume the message (which
#     emits kind=a2a_msg_delivered to ambient.jsonl). Returns 0 if
#     delivered in time, 2 if not. Default 0 = fire-and-forget (legacy,
#     unchanged behavior — returns 0 immediately after send).
#   Every --to send also writes a side-record to
#     .chump-locks/inbox/<sender>-sent-pending.jsonl with
#     {ts, corr_id, to, expires_at} so a sender can audit outstanding
#     unconfirmed sends without blocking (see a2a-delivery-tail.sh).
#
# INFRA-1948 (schema validation, slice E of INFRA-1862):
#   --strict  — reject calls whose required fields are missing/defaulted
#     instead of silently substituting a placeholder. Today's non-strict
#     default lets `STUCK <gap-id>` (no reason) silently emit
#     reason="unspecified" — the exact positional-arg-confusion failure
#     mode that motivated INFRA-1862. Opt-in per INFRA-1862 AC #7
#     (backward-compat): existing callers are unaffected until they add
#     --strict. Flip to default after a 7-day clean window per AC #7.

# ── INFRA-1998: Rust pass-through (opt-in via CHUMP_MESSAGING_RUST=1) ─────────
if [[ "${CHUMP_MESSAGING_RUST:-0}" == "1" ]]; then
    if command -v chump-broadcast >/dev/null 2>&1; then
        exec chump-broadcast "$@"
    fi
    # Binary not on $PATH — fall through to legacy bash body silently.
    # The smoke test scripts/ci/test-messaging-rust-parity.sh asserts
    # this fallback path doesn't surface to operators in CI.
fi

set -euo pipefail

# INFRA-1600: brew util-linux flock not on default PATH on self-hosted CI runners.
# shellcheck source=../lib/discover-flock.sh
# shellcheck disable=SC1091  # CREDIBLE-001 smoke runs shellcheck without -x
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
EMIT_SCRIPT="$REPO_ROOT/scripts/dev/ambient-emit.sh"

# ── Resolve session ID ────────────────────────────────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    _WT_CACHE="$LOCK_DIR/.wt-session-id"
    [[ -f "$_WT_CACHE" ]] && SESSION_ID="$(cat "$_WT_CACHE" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
SESSION_ID="${SESSION_ID:-broadcast-$$-$(date +%s)}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# CREDIBLE-025: include worker model in all events so per-model stats are attributable.
MODEL="${FLEET_MODEL:-${CHUMP_MODEL:-unknown}}"
# CREDIBLE-037: include harness attribution in all events so per-harness stats are attributable.
HARNESS="${CHUMP_AGENT_HARNESS:-unknown}"

# INFRA-1255: correlation_id ties INTENT/STUCK/HANDOFF (the "request" side)
# to DONE/ACK (the "response" side). When events share a corr_id, inbox-reap
# can clear the inbox on completion. Default precedence:
#   --corr <id>  >  gap-id (when applicable)  >  current branch  >  ts
# Callers can pass --corr to override; otherwise the per-event handler
# auto-derives. Set CHUMP_CORR_ID in env to force across nested calls.
CORR_ID_OVERRIDE="${CHUMP_CORR_ID:-}"

# INFRA-1297: stable operator-id for two-way comms. Every event gets
# operator_id when resolvable so messages targeted at the operator can be
# delivered to a durable inbox (rather than a per-tab transient session).
_BROADCAST_OP_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/operator-id.sh"
if [[ -f "$_BROADCAST_OP_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$_BROADCAST_OP_LIB"
    OPERATOR_ID="$(operator_id 2>/dev/null || echo "")"
else
    OPERATOR_ID="${CHUMP_OPERATOR_ID:-}"
fi

# ── Build JSON payload ────────────────────────────────────────────────────────
build_json() {
    python3 -c "import json,sys; print(json.dumps(dict(zip(sys.argv[1::2],sys.argv[2::2]))))" "$@"
}

# ── Write to ambient.jsonl (always — file-based fallback) ────────────────────
emit_to_file() {
    local json="$1"
    mkdir -p "$LOCK_DIR"
    if [[ -x "$EMIT_SCRIPT" ]]; then
        echo "$json" | "$EMIT_SCRIPT" 2>/dev/null && return
    fi
    local tmp
    tmp="$(mktemp "$LOCK_DIR/.broadcast_XXXXXX")"
    printf '%s\n' "$json" >> "$tmp"
    cat "$tmp" >> "$AMBIENT"
    rm -f "$tmp"
}

# ── Publish to NATS JetStream (Phase 1 — when chump-coord available) ─────────
emit_to_nats() {
    local event_type="$1"
    shift
    local coord_bin
    coord_bin="$(command -v chump-coord 2>/dev/null || true)"
    [[ -n "$coord_bin" ]] || return 0
    # Build key=value args from remaining positional pairs
    CHUMP_SESSION_ID="$SESSION_ID" "$coord_bin" emit "$event_type" "$@" 2>/dev/null || true
}

# INFRA-1115: write the JSON event into the recipient session's inbox.
# Concurrent-append safety via flock; max wait 5s before fallback to
# ambient-only with WARN.
#
# META-158 / CHUMP_FLEET_RECV_SIDE_V0: fan-out mode.
# When called with empty recipient AND fanout_event=1 AND CHUMP_FLEET_RECV_SIDE_V0=1:
#   - expand recipient list by globbing .chump-locks/.curator-opus-*.lock files
#   - strip leading dot + .lock suffix to get session_ids
#   - write the JSON event to each curator's inbox
#   - if zero .curator-opus-*.lock files match, print WARN and return 0 (best-effort)
# The --no-fanout flag or CHUMP_NO_FANOUT=1 suppresses this and falls through
# to the current single-recipient behaviour (silent no-op for empty recipient).
emit_to_inbox() {
    local recipient="$1" json="$2" fanout_event="${3:-0}"
    # META-158: FEEDBACK fan-out path (feature-flagged, best-effort)
    if [[ -z "$recipient" && "$fanout_event" == "1" \
          && "${CHUMP_FLEET_RECV_SIDE_V0:-0}" == "1" \
          && "${NO_FANOUT:-0}" != "1" ]]; then
        # Expand recipients from live .curator-opus-*.lock sentinel files.
        # Each such file is created by curator-loop harnesses to signal liveness.
        # Session ID = basename with leading dot and .lock suffix stripped.
        local curator_recipients=()
        shopt -s nullglob
        for lf in "$LOCK_DIR"/.curator-opus-*.lock; do
            local session_base
            session_base="$(basename "$lf")"        # e.g. .curator-opus-foo.lock
            session_base="${session_base#.}"         # strip leading dot → curator-opus-foo.lock
            session_base="${session_base%.lock}"     # strip .lock → curator-opus-foo
            curator_recipients+=("$session_base")
        done
        shopt -u nullglob
        if [[ ${#curator_recipients[@]} -eq 0 ]]; then
            printf '[broadcast] WARN: FEEDBACK fan-out found 0 .curator-opus-*.lock files — inbox write skipped (ambient retained)\n' >&2
            # Emit observable event so watchdogs can detect zero-curator condition.
            printf '{"ts":"%s","kind":"feedback_fanout_skipped","reason":"no_curator_locks","session":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" >> "$AMBIENT" 2>/dev/null || true
            return 0
        fi
        local cr
        for cr in "${curator_recipients[@]}"; do
            emit_to_inbox "$cr" "$json" "0"
        done
        # Emit observable event: fan-out delivered to N curators.
        printf '{"ts":"%s","kind":"feedback_fanout_delivered","recipient_count":%d,"session":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#curator_recipients[@]}" "$SESSION_ID" >> "$AMBIENT" 2>/dev/null || true
        return 0
    fi
    [[ -n "$recipient" ]] || return 0
    local inbox_dir="$LOCK_DIR/inbox"
    mkdir -p "$inbox_dir" 2>/dev/null || true
    # Glob recipient: expand against live session leases. A glob is any
    # recipient containing one of [*?[]. Non-glob → single recipient list.
    local recipients=()
    if [[ "$recipient" == *[*?[]* ]]; then
        local pattern="${recipient}"
        # Match against .chump-locks/<session>.json filenames.
        shopt -s nullglob
        local matches=()
        for f in "$LOCK_DIR"/*.json; do
            local base
            base="$(basename "$f" .json)"
            # Skip non-session JSON files (e.g. fleet-state.json).
            [[ "$base" == fleet-state || "$base" == health-* ]] && continue
            # shellcheck disable=SC2053
            if [[ "$base" == $pattern ]]; then
                matches+=("$base")
            fi
        done
        shopt -u nullglob
        recipients=("${matches[@]}")
        if [[ ${#recipients[@]} -eq 0 ]]; then
            printf '[broadcast] WARN: --to %s expanded to 0 live sessions\n' "$recipient" >&2
            return 0
        fi
    else
        recipients=("$recipient")
    fi
    local r lock_file
    for r in "${recipients[@]}"; do
        local inbox_file="$inbox_dir/$r.jsonl"
        lock_file="$inbox_dir/.$r.lock"

        if command -v "$FLOCK_BIN" >/dev/null 2>&1; then
            (
                exec 200>"$lock_file"
                if "$FLOCK_BIN" -w 5 200; then
                    printf '%s\n' "$json" >> "$inbox_file"
                else
                    printf '[broadcast] WARN: could not lock inbox %s within 5s; skipping inbox write (ambient retained)\n' "$inbox_file" >&2
                fi
            )
        else
            # No "$FLOCK_BIN" available — best-effort append. Single-machine fleets
            # with one process per session rarely race here.
            printf '%s\n' "$json" >> "$inbox_file"
        fi
    done
}

# INFRA-1944: record an outstanding delivery receipt for a single-recipient
# send. Best-effort — never fatal to the send path. Skips glob/fanout
# recipients (a glob resolves to N recipients server-side in emit_to_inbox;
# tracking per-recipient receipts for those is out of scope for slice A).
record_sent_pending() {
    local to="$1" corr_id="$2"
    [[ -n "$to" ]] || return 0
    [[ "$to" == *[*?[]* ]] && return 0
    local timeout="${CHUMP_A2A_DELIVERY_TIMEOUT:-300}"
    local expires_at
    expires_at="$(date -u -d "+${timeout} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v"+${timeout}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "$TS")"
    local inbox_dir="$LOCK_DIR/inbox"
    mkdir -p "$inbox_dir" 2>/dev/null || true
    local pending_file="$inbox_dir/${SESSION_ID}-sent-pending.jsonl"
    printf '{"ts":"%s","corr_id":"%s","to":"%s","expires_at":"%s"}\n' \
        "$TS" "$corr_id" "$to" "$expires_at" >> "$pending_file" 2>/dev/null || true
}

# ── INFRA-2015: urgency-tier routing ─────────────────────────────────────────
# Called AFTER the primary emit_to_file + emit_to_inbox so the main event
# always lands in ambient regardless of urgency side-effects.
#
# Tiers (in ascending urgency order):
#   INFO      — no extra routing; inbox + ambient is sufficient.
#   WARN      — emit kind=urgent_broadcast to ambient so the 5-min loop tick
#               surfaces it to watchdog consumers.
#   CRIT      — write to .chump-locks/URGENT-INBOX.jsonl; inbox-check-urgent.sh
#               PostToolUse hook delivers within ~1 tool call.
#   EMERGENCY — CRIT + invoke inbox-injector.sh once explicitly for immediate
#               tmux send-keys injection to any matching pane.
#
# scanner-anchor: "kind":"urgent_broadcast"
route_by_urgency() {
    local urgency="$1" json="$2" msg_body="$3"
    case "$urgency" in
        INFO|"") return 0 ;;  # no extra routing; default / legacy path
        WARN)
            # Emit a secondary ambient event so the 5-min loop tick sees it.
            printf '{"ts":"%s","kind":"urgent_broadcast","urgency":"WARN","source_session":"%s","body":%s}\n' \
                "$TS" "$SESSION_ID" \
                "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg_body")" \
                >> "$AMBIENT" 2>/dev/null || true
            ;;
        CRIT)
            # Write to global urgent inbox — PostToolUse hook reads it within ~1 tool call.
            local urgent_inbox="$LOCK_DIR/URGENT-INBOX.jsonl"
            python3 -c "
import json, sys
entry = {
    'ts': sys.argv[1],
    'urgency': 'CRIT',
    'from': sys.argv[2],
    'to': sys.argv[3] if sys.argv[3] else 'fleet-wide',
    'body': sys.argv[4],
}
print(json.dumps(entry))
" "$TS" "$SESSION_ID" "$TO" "$msg_body" >> "$urgent_inbox" 2>/dev/null || true
            # Also emit urgent_broadcast ambient marker
            printf '{"ts":"%s","kind":"urgent_broadcast","urgency":"CRIT","source_session":"%s","body":%s}\n' \
                "$TS" "$SESSION_ID" \
                "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg_body")" \
                >> "$AMBIENT" 2>/dev/null || true
            ;;
        EMERGENCY)
            # Write to global urgent inbox (same as CRIT).
            local urgent_inbox="$LOCK_DIR/URGENT-INBOX.jsonl"
            python3 -c "
import json, sys
entry = {
    'ts': sys.argv[1],
    'urgency': 'EMERGENCY',
    'from': sys.argv[2],
    'to': sys.argv[3] if sys.argv[3] else 'fleet-wide',
    'body': sys.argv[4],
}
print(json.dumps(entry))
" "$TS" "$SESSION_ID" "$TO" "$msg_body" >> "$urgent_inbox" 2>/dev/null || true
            # Emit urgent_broadcast ambient marker
            printf '{"ts":"%s","kind":"urgent_broadcast","urgency":"EMERGENCY","source_session":"%s","body":%s}\n' \
                "$TS" "$SESSION_ID" \
                "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg_body")" \
                >> "$AMBIENT" 2>/dev/null || true
            # Invoke inbox-injector.sh once for immediate tmux send-keys injection.
            local injector
            injector="$(dirname "${BASH_SOURCE[0]}")/inbox-injector.sh"
            if [[ -x "$injector" ]]; then
                CHUMP_SESSION_ID="$SESSION_ID" \
                    "$injector" --urgency EMERGENCY --body "$msg_body" 2>/dev/null || true
            fi
            ;;
    esac
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--to <recipient>] INTENT|HANDOFF|STUCK|DONE|WARN|ALERT [args...]" >&2
    exit 1
fi

# INFRA-1115: optional --to <recipient> targets the inbox(es) named.
# INFRA-1255: optional --corr <id> sets correlation_id explicitly.
# EFFECTIVE-028: optional --reply-to <parent-corr-id> threads this event under a
#   parent broadcast. Sets corr_id=<parent-corr-id> (so deliberator tallies land on
#   the parent's tally bucket) and adds parent_corr_id=<parent-corr-id> for lineage.
#   Use when voting on a specific proposal:
#     broadcast.sh --reply-to <proposal-corr-id> FEEDBACK preference <subject> "..." +1
# INFRA-2015: optional --urgency INFO|WARN|CRIT|EMERGENCY controls routing tier.
#   INFO      (default) — file inbox only; next-session pickup. No extra side-effects.
#   WARN      — file inbox + emit kind=urgent_broadcast to ambient (5 min loop tick).
#   CRIT      — file inbox + write to .chump-locks/URGENT-INBOX.jsonl (PostToolUse
#               hook via inbox-check-urgent.sh delivers within ~1 tool call).
#   EMERGENCY — all of the above + invoke inbox-injector.sh once explicitly
#               (immediate tmux send-keys for any matching pane).
# Backwards compat: default urgency is INFO — callers that omit --urgency are unchanged.
# INFRA-1299 note: prior values now|hours|digest are accepted as aliases for INFO
# so legacy callers continue working without modification.
# META-158: optional --no-fanout suppresses FEEDBACK fan-out-to-inbox expansion;
#   when set, emit_to_inbox falls back to single-recipient (silent no-op for empty --to).
#   CHUMP_NO_FANOUT=1 env var has the same effect.
# All flags can appear in any order before the event-type positional.
TO=""
CORR_FLAG=""
REPLY_TO=""
URGENCY="INFO"
NO_FANOUT="${CHUMP_NO_FANOUT:-0}"
AWAIT=0
STRICT=0
while :; do
    case "${1:-}" in
        --strict)
            STRICT=1
            shift
            ;;
        --await)
            AWAIT="${2:-0}"
            [[ "$AWAIT" =~ ^[0-9]+$ ]] || { echo "Usage: $0 --await <seconds>" >&2; exit 1; }
            shift 2
            ;;
        --no-await)
            AWAIT=0
            shift
            ;;
        --to)
            TO="${2:-}"
            [[ -z "$TO" ]] && { echo "Usage: $0 --to <recipient> EVENT [args...]" >&2; exit 1; }
            shift 2
            ;;
        --corr)
            CORR_FLAG="${2:-}"
            [[ -z "$CORR_FLAG" ]] && { echo "Usage: $0 --corr <id> EVENT [args...]" >&2; exit 1; }
            shift 2
            ;;
        --reply-to)
            # EFFECTIVE-028: thread this event under a parent broadcast's corr_id.
            REPLY_TO="${2:-}"
            [[ -z "$REPLY_TO" ]] && { echo "Usage: $0 --reply-to <parent-corr-id> EVENT [args...]" >&2; exit 1; }
            shift 2
            ;;
        --urgency)
            URGENCY="${2:-}"
            case "$URGENCY" in
                INFO|WARN|CRIT|EMERGENCY) : ;;
                # INFRA-1299 backwards compat: legacy reach-classifier values map to INFO
                now|hours|digest) URGENCY="INFO" ;;
                *) echo "Usage: $0 --urgency INFO|WARN|CRIT|EMERGENCY" >&2; exit 1 ;;
            esac
            shift 2
            ;;
        --no-fanout)
            NO_FANOUT="1"
            shift
            ;;
        *) break ;;
    esac
done

EVENT="$1"
shift

# INFRA-1255: corr_id derivation. Precedence:
#   --reply-to > --corr flag > env > gap-id > branch name > ts.
# EFFECTIVE-028: --reply-to sets highest precedence so the emitted event
# threads under the parent broadcast's tally bucket in the deliberator.
# Per-event handlers set CORR_ID after they parse their own gap argument.
_derive_corr() {
    local from_gap="${1:-}"
    if [[ -n "$REPLY_TO" ]]; then echo "$REPLY_TO"; return; fi
    if [[ -n "$CORR_FLAG" ]]; then echo "$CORR_FLAG"; return; fi
    if [[ -n "$CORR_ID_OVERRIDE" ]]; then echo "$CORR_ID_OVERRIDE"; return; fi
    if [[ -n "$from_gap" ]]; then echo "$from_gap"; return; fi
    local br
    br="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [[ -n "$br" && "$br" != "HEAD" ]]; then echo "branch:$br"; return; fi
    echo "ts:$TS"
}

# EFFECTIVE-028: inject parent_corr_id into an already-built JSON payload when
# --reply-to was specified. No-op when REPLY_TO is empty (default path unchanged).
# Uses python3 (same runtime as build_json) to guarantee valid JSON output.
_maybe_add_parent_corr_id() {
    local json="$1"
    if [[ -z "$REPLY_TO" ]]; then
        printf '%s' "$json"
        return
    fi
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['parent_corr_id'] = sys.argv[2]
print(json.dumps(d))
" "$json" "$REPLY_TO"
}

# INFRA-1948: strict-mode field validation. Called after an event's
# positional args are parsed but before the JSON payload is built. Exits 1
# with a message pointing at the expected shape when a required field is
# missing or was silently defaulted to a placeholder — the class of bug
# that shipped a STUCK event with reason=unspecified instead of failing.
_strict_check() {
    local field="$1" value="$2" usage="$3"
    [[ "$STRICT" == "1" ]] || return 0
    if [[ -z "$value" ]]; then
        echo "[broadcast --strict] missing required field: $field" >&2
        echo "Usage: $usage" >&2
        exit 1
    fi
}

_strict_check_gap_id() {
    local gap="$1" usage="$2"
    [[ "$STRICT" == "1" ]] || return 0
    if [[ ! "$gap" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
        echo "[broadcast --strict] malformed gap id: '$gap' (expected DOMAIN-NNN, e.g. INFRA-1862)" >&2
        echo "Usage: $usage" >&2
        exit 1
    fi
}

case "$EVENT" in

    INTENT)
        GAP="${1:-}"
        FILES="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 INTENT <gap-id> [files]" >&2; exit 1; }
        _strict_check_gap_id "$GAP" "$0 [--strict] INTENT <gap-id> [files]"
        CORR_ID="$(_derive_corr "$GAP")"
        if [[ -n "$TO" ]]; then
            JSON="$(_maybe_add_parent_corr_id "$(build_json event INTENT session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" files "$FILES" to "$TO" model "$MODEL" harness "$HARNESS")")"
        else
            JSON="$(_maybe_add_parent_corr_id "$(build_json event INTENT session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" files "$FILES" model "$MODEL" harness "$HARNESS")")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        record_sent_pending "$TO" "$CORR_ID"
        emit_to_nats INTENT "gap=$GAP" "files=$FILES" "model=$MODEL" "harness=$HARNESS"
        route_by_urgency "$URGENCY" "$JSON" "INTENT gap=$GAP files=$FILES"
        printf '[broadcast] INTENT  session=%s  gap=%s  urgency=%s\n' "$SESSION_ID" "$GAP" "$URGENCY"
        ;;

    HANDOFF)
        GAP="${1:-}"; POS_TO="${2:-}"
        # Back-compat: HANDOFF accepts the recipient as positional arg 2. If
        # --to was also given, --to wins; otherwise the positional value is
        # used as both the JSON "to" field AND the inbox target.
        EFFECTIVE_TO="${TO:-$POS_TO}"
        [[ -n "$GAP" && -n "$EFFECTIVE_TO" ]] || { echo "Usage: $0 [--to <recipient>] HANDOFF <gap-id> [<to-session>]" >&2; exit 1; }
        _strict_check_gap_id "$GAP" "$0 [--strict] [--to <recipient>] HANDOFF <gap-id> [<to-session>]"
        CORR_ID="$(_derive_corr "$GAP")"
        JSON="$(_maybe_add_parent_corr_id "$(build_json event HANDOFF session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" to "$EFFECTIVE_TO")")"
        emit_to_file "$JSON"
        emit_to_inbox "$EFFECTIVE_TO" "$JSON"
        record_sent_pending "$EFFECTIVE_TO" "$CORR_ID"
        emit_to_nats HANDOFF "gap=$GAP" "to=$EFFECTIVE_TO"
        route_by_urgency "$URGENCY" "$JSON" "HANDOFF gap=$GAP to=$EFFECTIVE_TO"
        printf '[broadcast] HANDOFF gap=%s → %s  urgency=%s\n' "$GAP" "$EFFECTIVE_TO" "$URGENCY"
        ;;

    STUCK)
        GAP="${1:-}"; REASON="${2:-unspecified}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 STUCK <gap-id> \"<reason>\"" >&2; exit 1; }
        _strict_check_gap_id "$GAP" "$0 [--strict] STUCK <gap-id> \"<reason>\""
        _strict_check "reason" "${2:-}" "$0 [--strict] STUCK <gap-id> \"<reason>\"  (reason must not be omitted — got positional-arg confusion defaulting to 'unspecified')"
        # INFRA-5763 (AC #2): in non-strict mode, warn on stderr when the
        # reason was omitted and silently defaulted — the exact
        # positional-arg-confusion failure mode --strict exists to catch.
        if [[ "$STRICT" != "1" && -z "${2:-}" ]]; then
            printf '[broadcast] WARN: STUCK %s called with no reason — defaulting reason=unspecified (use --strict to make this an error)\n' "$GAP" >&2
        fi
        CORR_ID="$(_derive_corr "$GAP")"
        if [[ -n "$TO" ]]; then
            JSON="$(_maybe_add_parent_corr_id "$(build_json event STUCK session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" reason "$REASON" to "$TO")")"
        else
            JSON="$(_maybe_add_parent_corr_id "$(build_json event STUCK session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" reason "$REASON")")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        record_sent_pending "$TO" "$CORR_ID"
        emit_to_nats STUCK "gap=$GAP" "reason=$REASON"
        route_by_urgency "$URGENCY" "$JSON" "STUCK gap=$GAP reason=$REASON"
        printf '[broadcast] STUCK   gap=%s  reason=%s  urgency=%s\n' "$GAP" "$REASON" "$URGENCY"
        ;;

    DONE)
        GAP="${1:-}"; COMMIT="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 DONE <gap-id> [commit-sha]" >&2; exit 1; }
        _strict_check_gap_id "$GAP" "$0 [--strict] DONE <gap-id> [commit-sha]"
        CORR_ID="$(_derive_corr "$GAP")"
        if [[ -n "$TO" ]]; then
            JSON="$(_maybe_add_parent_corr_id "$(build_json event DONE session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" commit "$COMMIT" to "$TO" model "$MODEL" harness "$HARNESS")")"
        else
            JSON="$(_maybe_add_parent_corr_id "$(build_json event DONE session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" gap "$GAP" commit "$COMMIT" model "$MODEL" harness "$HARNESS")")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        record_sent_pending "$TO" "$CORR_ID"
        emit_to_nats DONE "gap=$GAP" "commit=$COMMIT" "model=$MODEL" "harness=$HARNESS"
        route_by_urgency "$URGENCY" "$JSON" "DONE gap=$GAP commit=$COMMIT"
        printf '[broadcast] DONE    gap=%s  commit=%s  urgency=%s\n' "$GAP" "$COMMIT" "$URGENCY"
        ;;

    WARN)
        MSG="${1:-}"
        [[ -n "$MSG" ]] || { echo "Usage: $0 WARN \"<message>\"" >&2; exit 1; }
        CORR_ID="$(_derive_corr "")"
        if [[ -n "$TO" ]]; then
            JSON="$(_maybe_add_parent_corr_id "$(build_json event WARN session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" reason "$MSG" to "$TO")")"
        else
            JSON="$(_maybe_add_parent_corr_id "$(build_json event WARN session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" reason "$MSG")")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        record_sent_pending "$TO" "$CORR_ID"
        emit_to_nats WARN "reason=$MSG"
        route_by_urgency "$URGENCY" "$JSON" "$MSG"
        printf '[broadcast] WARN    %s  urgency=%s\n' "$MSG" "$URGENCY"
        ;;

    ALERT)
        KIND_ARG="${1:-}"; MSG="${2:-}"
        KIND="${KIND_ARG#kind=}"
        [[ -n "$KIND" ]] || { echo "Usage: $0 ALERT kind=<kind> \"<message>\"" >&2; exit 1; }
        _strict_check "message" "$MSG" "$0 [--strict] ALERT kind=<kind> \"<message>\""
        CORR_ID="$(_derive_corr "")"
        if [[ -n "$TO" ]]; then
            JSON="$(_maybe_add_parent_corr_id "$(build_json event ALERT session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" kind "$KIND" reason "$MSG" to "$TO")")"
        else
            JSON="$(_maybe_add_parent_corr_id "$(build_json event ALERT session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" kind "$KIND" reason "$MSG")")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        record_sent_pending "$TO" "$CORR_ID"
        emit_to_nats ALERT "kind=$KIND" "reason=$MSG"
        route_by_urgency "$URGENCY" "$JSON" "ALERT kind=$KIND $MSG"
        printf '[broadcast] ALERT   kind=%s  %s  urgency=%s\n' "$KIND" "$MSG" "$URGENCY"
        ;;

    FEEDBACK)
        # INFRA-1271: structured opinion / preference channel for agents.
        # Kinds:
        #   defect      — bug or pain-point the agent observed
        #   proposal    — suggested improvement, may reference an existing subject
        #   preference  — vote (+1/-1) on an existing default/policy
        #   retro       — post-ship reflection on what fit / didn't
        # Lands in $LOCK_DIR/feedback.jsonl (NOT session inboxes) — curator territory.
        FB_KIND="${1:-}"
        FB_SUBJECT="${2:-}"
        FB_RATIONALE="${3:-}"
        FB_VOTE="${4:-}"  # used by preference kind
        [[ -n "$FB_KIND" && -n "$FB_SUBJECT" ]] || {
            echo "Usage: $0 FEEDBACK <defect|proposal|preference|retro> <subject> [\"rationale\"] [+1|-1|0]" >&2
            exit 1
        }
        case "$FB_KIND" in
            # META-189: vote-request — a curator/daemon asks the fleet to cast
            # consensus votes on a subject (e.g. "pr-N" for a MERGEABLE PR).
            # corr_id derives from FB_SUBJECT so `chump vote <corr_id>` calls
            # and `chump consensus-tally --corr-id <id>` land on the same bucket.
            defect|proposal|preference|retro|vote-request) : ;;
            *) echo "FEEDBACK kind must be one of: defect proposal preference retro vote-request (got $FB_KIND)" >&2; exit 1 ;;
        esac
        # corr_id: when --reply-to is given, use the parent's corr_id so this
        # vote lands in the correct deliberator tally bucket. Otherwise fall
        # back to subject (gap-id or policy name) so DONE/inbox-reap lifecycle
        # naturally clears retro entries once the gap ships.
        CORR_ID="$(_derive_corr "$FB_SUBJECT")"
        if [[ "$FB_KIND" == "preference" ]]; then
            : "${FB_VOTE:=0}"
            JSON="$(_maybe_add_parent_corr_id "$(build_json event FEEDBACK kind "$FB_KIND" session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" subject "$FB_SUBJECT" rationale "$FB_RATIONALE" vote "$FB_VOTE" model "$MODEL" harness "$HARNESS")")"
        else
            JSON="$(_maybe_add_parent_corr_id "$(build_json event FEEDBACK kind "$FB_KIND" session "$SESSION_ID" operator_id "$OPERATOR_ID" ts "$TS" corr_id "$CORR_ID" urgency "$URGENCY" subject "$FB_SUBJECT" rationale "$FB_RATIONALE" model "$MODEL" harness "$HARNESS")")"
        fi
        # File-mode emit: still write to ambient.jsonl (audit trail) AND to the
        # dedicated feedback.jsonl that the curator (INFRA-1272) + the deliberator
        # tally read. CREDIBLE-122: honor CHUMP_FEEDBACK_LOG so the durable vote
        # record is sandboxable in tests (matches deliberator/consensus-tally,
        # which already respect it) and the e2e path can be verified end-to-end.
        emit_to_file "$JSON"
        _fb_log="${CHUMP_FEEDBACK_LOG:-$LOCK_DIR/feedback.jsonl}"
        mkdir -p "$(dirname "$_fb_log")" 2>/dev/null || true
        printf '%s\n' "$JSON" >> "$_fb_log"
        # META-158: fan-out FEEDBACK kinds to all live curator inboxes.
        # When --to is set, behave as before (single-recipient inbox write).
        # When --to is unset and CHUMP_FLEET_RECV_SIDE_V0=1 and --no-fanout is not set,
        # expand recipient list via .curator-opus-*.lock glob (best-effort, never fatal).
        # When --to is unset and flag/env opts out, falls back to silent no-op (legacy).
        if [[ -n "$TO" ]]; then
            emit_to_inbox "$TO" "$JSON" "0"
            record_sent_pending "$TO" "$CORR_ID"
        else
            emit_to_inbox "" "$JSON" "1"
        fi
        # NATS topic: chump.events.FEEDBACK (Phase 1 keeps the type uppercase like the rest).
        emit_to_nats FEEDBACK "kind=$FB_KIND" "subject=$FB_SUBJECT" "rationale=$FB_RATIONALE" "vote=${FB_VOTE:-0}"
        route_by_urgency "$URGENCY" "$JSON" "FEEDBACK kind=$FB_KIND subject=$FB_SUBJECT"
        printf '[broadcast] FEEDBACK kind=%s subject=%s  urgency=%s\n' "$FB_KIND" "$FB_SUBJECT" "$URGENCY"
        ;;

    *)
        echo "Unknown event type: $EVENT" >&2
        echo "Valid types: INTENT HANDOFF STUCK DONE WARN ALERT FEEDBACK" >&2
        exit 1
        ;;
esac

# INFRA-1944: --await <seconds> — block waiting for the recipient's
# chump-inbox.sh read to consume this message (kind=a2a_msg_delivered).
# Default 0 = fire-and-forget, unchanged legacy behavior (exit 0 immediately).
if [[ "$AWAIT" -gt 0 ]]; then
    AWAIT_TARGET="${TO:-${EFFECTIVE_TO:-}}"
    if [[ -z "$AWAIT_TARGET" ]]; then
        printf '[broadcast] --await ignored: no --to recipient specified\n' >&2
        exit 0
    fi
    TAIL_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/a2a-delivery-tail.sh"
    if [[ -x "$TAIL_SCRIPT" ]]; then
        if "$TAIL_SCRIPT" --corr-id "$CORR_ID" --timeout "$AWAIT"; then
            printf '[broadcast] AWAIT delivered corr_id=%s\n' "$CORR_ID"
            exit 0
        else
            printf '[broadcast] AWAIT timeout corr_id=%s (not delivered within %ss)\n' "$CORR_ID" "$AWAIT" >&2
            exit 2
        fi
    else
        printf '[broadcast] WARN: a2a-delivery-tail.sh not found; --await skipped\n' >&2
    fi
fi
