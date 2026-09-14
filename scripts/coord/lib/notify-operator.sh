#!/usr/bin/env bash
# notify-operator.sh — RESILIENT-263: reach the operator's PHONE when a
# production line stops.
#
# WHY THIS EXISTS. On 2026-08-08 pr-failure-auto-rescue closed PR #3510 after
# 23.2h on a single required check that was RED-but-false (a flake whose gate
# sat outside the retry wrapper). 23 hours of ready work was destroyed and
# nothing told the operator — he found out by asking, hours later. The daemon
# even had an outcome string named `operator_alert`, which wrote a log line and
# an ambient event and alerted nobody. A label, not an alert.
#
# WHY DISCORD AND NOT A NEW CHANNEL. The capability was already built,
# credentialed, addressed and in daily use — src/discord_dm.rs
# (send_dm_if_configured) has five live callers. DISCORD_TOKEN and
# CHUMP_READY_DM_USER_ID were already set. A Discord DM lands on the phone via
# the mobile app. Adding Pushover/iMessage/Telegram instead would have been the
# fleet's most-repeated mistake: building a second thing while the first sits
# uncalled. (TELEGRAM_BOT_TOKEN is also present but TELEGRAM_CHAT_ID is not, so
# that path is not addressable today — it is the documented fallback, not this.)
#
# CONTRACT — this is a bash mirror of src/discord_dm.rs's REST calls:
#   notify_operator "<message>"        → 0 on delivery, 1 on failure, 0 no-op
#                                        when unconfigured
#
# INVARIANTS, all load-bearing:
#   * NEVER prints the token, not even partially. Only lengths and HTTP codes.
#   * NEVER exits or kills its caller. A broken notifier must not break the
#     daemon it reports on — that would trade a silent failure for a louder one.
#   * Silent no-op when unconfigured, matching send_dm_if_configured's shape.
#   * SEVERITY-GATED BY THE CALLER, deliberately. Only "a line stopped" reaches
#     the phone. An escalation channel that cries wolf gets muted, and a muted
#     channel is the dead operator-recall handler all over again (RESILIENT-262:
#     that handler has been configured-but-not-running since 2026-05-08).
#
# shellcheck shell=bash

_notify_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd
}

# Candidate .env locations, most-specific first.
#
# The worktree case is load-bearing, not defensive: .env is GITIGNORED, so it
# exists only in the main checkout. `chump claim` creates a worktree for every
# gap, so anything invoked from one would silently find no credentials and skip
# the alert — the precise fail-silently mode this file exists to prevent.
# `git rev-parse --git-common-dir` resolves a worktree back to the main .git,
# whose parent is the checkout that actually holds .env.
_notify_env_files() {
    local root common
    root="$(_notify_repo_root)"
    [[ -n "$root" ]] && printf '%s\n' "$root/.env"
    [[ -n "${CHUMP_HOME:-}" ]] && printf '%s\n' "${CHUMP_HOME}/.env"
    common="$(git -C "${root:-.}" rev-parse --git-common-dir 2>/dev/null)" || true
    if [[ -n "$common" ]]; then
        [[ "$common" != /* ]] && common="${root}/${common}"
        printf '%s\n' "$(dirname "$common")/.env"
    fi
}

# Read a var from the process environment first, else from the first .env that
# has it. Never echoes the value.
_notify_env() {
    local key="$1" val f
    # Indirect expansion; this file is bash-only (see shebang) by design.
    val="${!key:-}"
    if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
    while read -r f; do
        [[ -f "$f" ]] || continue
        val="$(grep -m1 "^${key}=" "$f" 2>/dev/null \
            | cut -d= -f2- \
            | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/[[:space:]]*$//')"
        if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
    done < <(_notify_env_files)
}

# RESILIENT-274 escalation discipline. Operator decision (Jeff, 2026-08-10):
# "don't hear from the fleet unless it's way out of line or we don't have a
# playbook for it." Quiet by default. A page reaches the phone ONLY when the
# signal is halt-class OR novel (no playbook). Known signals that have an
# auto-heal / runbook are SUPPRESSED here — logged to ambient, not DM'd — so the
# escalation channel never cries wolf (a muted channel is the RESILIENT-262 dead
# operator-recall handler all over again).
#
# Classification input (both optional, set by the caller):
#   CHUMP_NOTIFY_KIND      the ambient/signal kind (e.g. discord_gateway_down)
#   CHUMP_NOTIFY_SEVERITY  set to "halt" to force a page regardless of registry
# Registry: scripts/coord/operator-escalation-registry.txt — "<kind><TAB>suppress|page|direct".
# Rules: halt severity → PAGE, always, bypassing the registry entirely. Below
# halt, kind in registry → its verdict. Unknown kind or no kind → BUFFER
# (RESILIENT-1094: fail-loud-by-page made NOISE the default — every new organ
# that DMs without a registry line paged the phone; hold it durably instead so
# a single curated voice summarizes it, never-silently-drop preserved by
# durability, not immediacy).
#   suppress → log operator_notify_suppressed, DO NOT DM.
#   page     → emit operator_paged (counts against page-rate) AND DM the phone.
#              Only for kinds EXPLICITLY registered as page — a documented,
#              known escalation, not a novel one.
#   direct   → INFRA-3835: emit operator_direct_message and DM, but it is NOT an
#              escalation (no operator_paged). For normal messages the fleet owes
#              the operator, e.g. the Advisor's answer — the DM IS the payload,
#              a parallel "you were paged" event would be pure noise.
#   unclassified → RESILIENT-1094: no registry entry (or no kind, or no
#              registry file). Append to the durable discord-cos
#              hold-and-summarize buffer (.chump-locks/discord-cos-buffer.jsonl)
#              and emit operator_notify_buffered. DO NOT DM.
_notify_ambient_log() {
    local root; root="$(_notify_repo_root)"
    printf '%s\n' "${CHUMP_AMBIENT_LOG:-${root}/.chump-locks/ambient.jsonl}"
}

_notify_emit() {  # kind, extra_json_fragment
    local log; log="$(_notify_ambient_log)"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$log" 2>/dev/null || true
}

# Returns "page", "suppress", "direct", or "unclassified" on stdout.
# Whitespace-split (space OR tab); anything after the verdict is an inline
# comment. "direct" (INFRA-3835) means a normal DM the fleet owes the operator
# — deliver it, but it is NOT an escalation. "unclassified" (RESILIENT-1094)
# is the never-silently-drop default for a kind with NO registry entry (or no
# kind, or no registry file at all) — the caller routes this into the
# discord-cos hold-and-summarize buffer rather than paging, so a brand-new
# organ DM'ing without a registry line doesn't cry wolf on the phone. Only an
# EXPLICIT `page` line in the registry (or a typo'd verdict on a known kind —
# still fail loud, since that's a registered-but-broken entry, not a novel
# one) returns "page".
_notify_escalation_verdict() {
    local kind="$1" root reg k verdict _rest
    [[ -n "$kind" ]] || { echo "unclassified"; return; }   # no kind at all
    root="$(_notify_repo_root)"
    reg="${root}/scripts/coord/operator-escalation-registry.txt"
    [[ -f "$reg" ]] || { echo "unclassified"; return; }    # no registry at all
    while read -r k verdict _rest; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        if [[ "$kind" == "$k" ]]; then
            case "$verdict" in
                suppress) echo "suppress" ;;
                direct)   echo "direct" ;;
                *)        echo "page" ;;            # page or any typo → fail loud
            esac
            return
        fi
    done < "$reg"
    echo "unclassified"                             # unlisted kind = novel = buffer, not page
}

# Durable hold-and-summarize buffer (RESILIENT-1094, feeds the discord-cos
# curation buffer of RESILIENT-1093). Never-silently-drop is preserved by
# durability, not by an immediate page: the signal lands on disk so a single
# curated voice can summarize it later, instead of every unclassified DM
# firing its own operator_paged straight to the phone.
_notify_buffer_path() {
    local root; root="$(_notify_repo_root)"
    printf '%s\n' "${CHUMP_DISCORD_COS_BUFFER:-${root}/.chump-locks/discord-cos-buffer.jsonl}"
}

_notify_buffer_signal() {
    local kind="$1" content="$2" buf ts; buf="$(_notify_buffer_path)"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$buf")" 2>/dev/null || true
    TS="$ts" KIND="$kind" CONTENT="$content" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "ts": os.environ["TS"],
    "kind": os.environ.get("KIND", ""),
    "content": os.environ["CONTENT"],
}) + "\n")' >> "$buf" 2>/dev/null
}

# RESILIENT-1093: single-voice curation queue. Path to the JSONL file that
# page-verdict signals land in instead of hitting Discord immediately — see
# _notify_curate_enqueue / discord-curator-flush.sh.
_notify_queue_path() {
    local root; root="$(_notify_repo_root)"
    printf '%s\n' "${CHUMP_DISCORD_CURATION_QUEUE:-${root}/.chump-locks/discord-curation-queue.jsonl}"
}

_notify_curate_enqueue() {  # content, kind
    local content="$1" kind="$2" queue; queue="$(_notify_queue_path)"
    mkdir -p "$(dirname "$queue")" 2>/dev/null || true
    CONTENT="$content" KIND="$kind" TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 -c '
import os, json
print(json.dumps({
    "ts": os.environ.get("TS", ""),
    "kind": os.environ.get("KIND", "") or "unclassified",
    "content": os.environ["CONTENT"],
}))' >> "$queue" 2>/dev/null || true
}

# RESILIENT-1095: global page-rate ceiling. RESILIENT-1093 batches every
# "page"-verdict signal into the curation queue unconditionally, so those
# already coalesce at flush cadence. "direct" owed-messages (chump_digest,
# board_ceo_briefing, discord_advisor_reply — see operator-escalation-
# registry.txt) skip that queue on purpose ("deliver every time") and dial
# Discord immediately, one call = one DM. That path has no ceiling: three
# direct messages landing in the same window are three separate DMs, the
# exact cross-source burst RESILIENT-1093 exists to prevent. This tracks
# recent direct deliveries in a rolling window; once the ceiling is hit,
# further direct messages are coalesced into the curation queue too instead
# of dialing out again immediately. Halt severity never reaches here — it's
# checked before notify_operator does any of this.
_notify_rate_state_file() {
    local root; root="$(_notify_repo_root)"
    printf '%s\n' "${CHUMP_NOTIFY_RATE_LOG:-${root}/.chump-locks/discord-notify-rate.log}"
}

# Returns 0 (true) when the direct-delivery ceiling is already hit in the
# trailing window — caller should coalesce instead of delivering immediately.
# Returns 1 (false) and records "now" as a delivery timestamp otherwise.
_notify_rate_over_ceiling() {
    local state ceiling window now cutoff count tmp t
    state="$(_notify_rate_state_file)"
    mkdir -p "$(dirname "$state")" 2>/dev/null || true
    touch "$state" 2>/dev/null || true
    ceiling="${CHUMP_NOTIFY_RATE_CEILING:-3}"
    window="${CHUMP_NOTIFY_RATE_WINDOW_S:-300}"
    now="$(date -u +%s)"
    cutoff=$((now - window))

    count=0
    tmp="${state}.tmp.$$"
    : > "$tmp"
    while read -r t; do
        [[ -n "$t" ]] || continue
        if (( t >= cutoff )); then
            printf '%s\n' "$t" >> "$tmp"
            count=$((count + 1))
        fi
    done < "$state"

    if (( count >= ceiling )); then
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi

    printf '%s\n' "$now" >> "$tmp"
    mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    return 1
}

notify_operator() {
    local content="${1:-}"
    [[ -n "${content//[[:space:]]/}" ]] || return 0

    # Escalation gate — suppress known-playbook'd routine before touching Discord.
    local _kind="${CHUMP_NOTIFY_KIND:-}" _sev="${CHUMP_NOTIFY_SEVERITY:-}"
    if [[ "$_sev" != "halt" ]]; then
        local _verdict; _verdict="$(_notify_escalation_verdict "$_kind")"
        if [[ "$_verdict" == "suppress" ]]; then
            _notify_emit "operator_notify_suppressed" ",\"signal\":\"${_kind}\",\"reason\":\"has-playbook\""
            echo "[notify-operator] SUPPRESSED (playbook exists, quiet-by-default): kind=${_kind}" >&2
            return 0
        fi
        if [[ "$_verdict" == "direct" ]]; then
            # INFRA-3835: a normal DM the fleet owes the operator (e.g. the
            # Advisor's answer). DELIVER it (fall through to the Discord send),
            # but emit operator_direct_message rather than operator_paged — it is
            # not an escalation, so it must not inflate the page-rate vital sign.
            _notify_emit "operator_direct_message" ",\"signal\":\"${_kind}\""

            # RESILIENT-1095: global page-rate ceiling. Direct messages skip the
            # curation queue by design, but that made them the one uncapped
            # burst path — hold this one and coalesce it once the ceiling is hit.
            # scanner-anchor: "kind":"operator_notify_rate_held"
            if _notify_rate_over_ceiling; then
                _notify_emit "operator_notify_rate_held" ",\"signal\":\"${_kind}\""
                echo "[notify-operator] DIRECT held (page-rate ceiling hit, coalescing): kind=${_kind}" >&2
                _notify_curate_enqueue "$content" "$_kind"
                return 0
            fi
            echo "[notify-operator] DIRECT (owed-message, delivered without paging): kind=${_kind}" >&2
        elif [[ "$_verdict" == "unclassified" ]]; then
            # RESILIENT-1094: no registry entry (or no kind at all) is no longer
            # an automatic page — that made NOISE the default: every new organ
            # that DMs without a registry line paged the phone. Hold it in the
            # durable discord-cos buffer (RESILIENT-1093) instead, so a single
            # curated voice can summarize it later. Never-silently-drop is kept
            # by durability, not by an immediate page.
            _notify_buffer_signal "$_kind" "$content"
            # scanner-anchor: "kind":"operator_notify_buffered"
            _notify_emit "operator_notify_buffered" ",\"signal\":\"${_kind}\",\"reason\":\"unclassified-non-halt\""
            echo "[notify-operator] BUFFERED (unclassified, non-halt): kind=${_kind}" >&2
            return 0
        else
            # Explicit page-classified kind: record the escalation. RESILIENT-1094
            # routes unclassified / no-kind signals to the hold-and-summarize
            # buffer above, so reaching here means the verdict was an EXPLICIT
            # registry `page` entry and $_kind is always non-empty — the old
            # `|| unclassified-caller` fallback is now unreachable, dropped here.
            _notify_emit "operator_paged" ",\"signal\":\"${_kind}\",\"class\":\"registry-page\""

            # RESILIENT-1093: this is the multi-source burst the single-voice
            # curation layer exists for. 18 independent call sites each used to
            # dial Discord the moment they had something page-worthy to say, so
            # N organs firing in one window produced N separate DMs. Defer to the
            # curation queue instead; discord-curator-flush.sh (run on a cadence)
            # drains it into ONE combined DM. CHUMP_NOTIFY_CURATE=0 opts a caller
            # back into the old immediate-send behavior (e.g. discord-curator-
            # flush.sh itself, delivering the already-combined message).
            if [[ "${CHUMP_NOTIFY_CURATE:-1}" != "0" ]]; then
                _notify_curate_enqueue "$content" "$_kind"
                return 0
            fi
        fi
    fi

    _notify_deliver "$content"
}

# _notify_deliver — the actual Discord REST send, extracted out of
# notify_operator so discord-curator-flush.sh can deliver ONE combined message
# without re-running the per-signal escalation classification above.
# CHUMP_OPERATOR_AUTOPOST_DM — operator kill-switch for AUTOMATED operator DMs
# (Jeff, 2026-09-13: "kill everything automated"). Default (unset/empty/0/false/
# off/no) = automated DMs OFF. Set to 1/true/on/yes to restore the pre-2026-09-13
# behavior where pages, digests and briefings DM the operator again. Deliberately
# a plain descriptive name (not a *_BYPASS/_SKIP/_IGNORE var) so it neither reads
# as a gate-bypass nor counts against the bypass-var debt ceiling.
_notify_autopost_dm_enabled() {
    case "$(printf '%s' "${CHUMP_OPERATOR_AUTOPOST_DM:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|on|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# The ONLY DMs that still leave the fleet when autoposts are off are REPLIES to a
# message Jeff sent: the two-way command gateway's answer (discord_command_reply)
# and the Advisor's answer to a Jeff DM (discord_advisor_reply). Everything else —
# pages, digests (chump_digest), briefings (board_ceo_briefing), halt-class
# incidents, curated batches, an unset kind — is an automated send and is
# withheld unless the operator re-enables it. Classification, ambient events and
# buffering all still run upstream; only the outbound Discord call is gated, so
# no functional organ is disabled — it just stops DMing.
_notify_is_command_reply_kind() {
    case "${1:-}" in
        discord_command_reply|discord_advisor_reply) return 0 ;;
        *) return 1 ;;
    esac
}

_notify_deliver() {
    local content="${1:-}"
    [[ -n "${content//[[:space:]]/}" ]] || return 0

    # Automated-DM kill-switch (Jeff, 2026-09-13). Command-replies always deliver;
    # every other kind is suppressed unless CHUMP_OPERATOR_AUTOPOST_DM re-enables it.
    if ! _notify_is_command_reply_kind "${CHUMP_NOTIFY_KIND:-}" && ! _notify_autopost_dm_enabled; then
        _notify_emit "operator_notify_suppressed" \
            ",\"signal\":\"${CHUMP_NOTIFY_KIND:-none}\",\"reason\":\"autoposts-off\""
        echo "[notify-operator] SUPPRESSED (automated operator DMs are off; set CHUMP_OPERATOR_AUTOPOST_DM=1 to re-enable): kind=${CHUMP_NOTIFY_KIND:-<none>}" >&2
        return 0
    fi

    local token uid
    token="$(_notify_env DISCORD_TOKEN)"
    uid="$(_notify_env CHUMP_READY_DM_USER_ID)"
    if [[ -z "$token" || -z "$uid" ]]; then
        # Unconfigured is not an error — same shape as send_dm_if_configured.
        echo "[notify-operator] SKIP: DISCORD_TOKEN or CHUMP_READY_DM_USER_ID unset" >&2
        return 0
    fi

    local api="https://discord.com/api/v10"
    local ch_json ch_id
    ch_json="$(curl -sS --max-time 10 -X POST "${api}/users/@me/channels" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"recipient_id\":\"${uid}\"}" 2>/dev/null)" || {
        echo "[notify-operator] FAIL: could not open DM channel (curl error)" >&2
        return 1
    }
    ch_id="$(printf '%s' "$ch_json" | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
    if [[ -z "$ch_id" ]]; then
        # Print Discord's error message, which never contains the token.
        echo "[notify-operator] FAIL: open DM channel: $(printf '%s' "$ch_json" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("message","?"))' 2>/dev/null)" >&2
        return 1
    fi

    # CHUNK RATHER THAN TRUNCATE. Discord hard-caps message content at 2000
    # chars. The first cut of this file truncated at 1900 and appended "…",
    # which silently drops the tail — and on an escalation the tail is the link
    # and the ask, i.e. the part that lets the operator act. Split on paragraph
    # then line then word boundaries, and number the parts so a message arriving
    # out of order is still readable.
    #
    # Approach borrowed from openclaw's src/discord/chunk.ts (MIT). Rewritten
    # here, not copied — see DOC-093 for the port policy.
    local -a parts=()
    while IFS= read -r part; do
        [[ -n "$part" ]] && parts+=("$(printf '%b' "$part")")
    done < <(printf '%s' "$content" | python3 -c '
import sys
LIMIT = 1900
text = sys.stdin.read()
out, buf = [], ""
def flush():
    global buf
    if buf.strip():
        out.append(buf.rstrip("\n"))
    buf = ""
for para in text.split("\n"):
    # A single line longer than LIMIT still has to be broken; do it on words.
    while len(para) > LIMIT:
        cut = para.rfind(" ", 0, LIMIT)
        if cut <= 0:
            cut = LIMIT
        if len(buf) + len(para[:cut]) + 1 > LIMIT:
            flush()
        buf += para[:cut] + "\n"
        para = para[cut:].lstrip()
    if len(buf) + len(para) + 1 > LIMIT:
        flush()
    buf += para + "\n"
flush()
for i, chunk in enumerate(out, 1):
    if len(out) > 1:
        chunk = f"({i}/{len(out)}) " + chunk
    # One line per part; escape newlines so bash read can take it whole.
    print(chunk.replace("\\", "\\\\").replace("\n", "\\n"))
' 2>/dev/null)

    if (( ${#parts[@]} == 0 )); then parts=("$content"); fi

    local code sent=0 failed=0
    for part in "${parts[@]}"; do
        code="$(printf '%s' "$part" \
            | python3 -c 'import json,sys;print(json.dumps({"content":sys.stdin.read()}))' \
            | curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
                -X POST "${api}/channels/${ch_id}/messages" \
                -H "Authorization: Bot ${token}" \
                -H "Content-Type: application/json" \
                --data @- 2>/dev/null)" || true
        if [[ "$code" == "200" || "$code" == "201" ]]; then
            sent=$((sent + 1))
        else
            failed=$((failed + 1))
            echo "[notify-operator] FAIL: part returned HTTP ${code:-000}" >&2
        fi
    done

    if (( failed == 0 && sent > 0 )); then
        echo "[notify-operator] delivered (${sent} part(s))" >&2
        return 0
    fi
    echo "[notify-operator] FAIL: ${failed} of $((sent + failed)) part(s) failed" >&2
    return 1
}

# notify_operator_buttons — RESILIENT-265 "approve-from-phone". Send ONE operator
# DM that carries an interactive button row (Discord message components), so a
# decision the operator would otherwise make on GitHub is one phone tap instead.
#
#   notify_operator_buttons "<content>" "<components-json-array>"
#     → 0 on delivery, 1 on failure, 0 no-op when unconfigured
#
# The caller builds the components array (Discord "action row" of type-2 buttons
# with the custom_ids the gateway's INTERACTION_CREATE handler parses, e.g.
# `mergepr:owner/repo/number`). This deliberately BYPASSES the escalation
# suppress-registry: an approval prompt is operator-requested action, never
# cry-wolf routine — it must always reach the phone. It also does NOT chunk:
# an approval message is short and components must ride the single message that
# owns the buttons. Reuses notify_operator's env/token resolution + curl shape.
notify_operator_buttons() {
    local content="${1:-}" components="${2:-[]}"
    [[ -n "${content//[[:space:]]/}" ]] || return 0

    # Automated-DM kill-switch (Jeff, 2026-09-13). An approval prompt is a
    # fleet-initiated page, never a reply to a message Jeff sent, so it is
    # withheld unless CHUMP_OPERATOR_AUTOPOST_DM re-enables automated DMs.
    if ! _notify_autopost_dm_enabled; then
        _notify_emit "operator_notify_suppressed" \
            ",\"signal\":\"${CHUMP_NOTIFY_KIND:-buttons}\",\"reason\":\"autoposts-off\""
        echo "[notify-operator] SUPPRESSED (buttons): automated operator DMs are off; set CHUMP_OPERATOR_AUTOPOST_DM=1 to re-enable" >&2
        return 0
    fi

    local token uid
    token="$(_notify_env DISCORD_TOKEN)"
    uid="$(_notify_env CHUMP_READY_DM_USER_ID)"
    if [[ -z "$token" || -z "$uid" ]]; then
        echo "[notify-operator] SKIP (buttons): DISCORD_TOKEN or CHUMP_READY_DM_USER_ID unset" >&2
        return 0
    fi

    local api="https://discord.com/api/v10"
    local ch_json ch_id
    ch_json="$(curl -sS --max-time 10 -X POST "${api}/users/@me/channels" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"recipient_id\":\"${uid}\"}" 2>/dev/null)" || {
        echo "[notify-operator] FAIL (buttons): could not open DM channel" >&2; return 1; }
    ch_id="$(printf '%s' "$ch_json" | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
    if [[ -z "$ch_id" ]]; then
        echo "[notify-operator] FAIL (buttons): open DM channel: $(printf '%s' "$ch_json" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("message","?"))' 2>/dev/null)" >&2
        return 1
    fi

    # Build the message payload (content + components) with python so the JSON is
    # always valid regardless of what's in content/components.
    local payload code
    payload="$(CONTENT="$content" COMPONENTS="$components" python3 -c '
import os,json
print(json.dumps({
    "content": os.environ["CONTENT"][:1990],
    "components": json.loads(os.environ["COMPONENTS"] or "[]"),
}))' 2>/dev/null)"
    if [[ -z "$payload" ]]; then
        echo "[notify-operator] FAIL (buttons): could not build payload (bad components JSON?)" >&2; return 1; fi

    code="$(printf '%s' "$payload" | curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST "${api}/channels/${ch_id}/messages" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        --data @- 2>/dev/null)" || true
    if [[ "$code" == "200" || "$code" == "201" ]]; then
        echo "[notify-operator] delivered (buttons)" >&2; return 0
    fi
    echo "[notify-operator] FAIL (buttons): HTTP ${code:-000}" >&2
    return 1
}

# Direct-execution entry point — INFRA-3602. Restrictive Bash allowlists
# (e.g. `claude --permission-mode dontAsk`) deny `source X && fn args` as a
# compound command regardless of how precisely the allowlist pattern matches
# the literal string: a permission engine can't statically verify what a
# dynamically-sourced function does, so it refuses the whole chain. Running
# this file directly — `CHUMP_NOTIFY_KIND=x notify-operator.sh "<msg>"` — is
# a single non-compound invocation of one known executable and is allowed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    notify_operator "$@"
fi
