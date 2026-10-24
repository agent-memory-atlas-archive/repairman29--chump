#!/usr/bin/env bash
# discord-advisor-agent.sh — INFRA-3597: The Advisor, DISTINCT from the ops
# Discord agent (INFRA-3596, scripts/dispatch/discord-command-agent.sh).
#
# The ops command agent ACTS (files gaps, treats the DM as a command). The
# Advisor's whole job per docs/design/VOICE_ADVISOR.md is the opposite: KNOW
# everything (almanac_search as the proxy for the whole fleet + live state)
# and TALK to Jeff — it never writes code, never files gaps, never mutates
# anything. Anything actionable gets described in the reply; Jeff (or the
# ops agent) acts on it separately.
#
# Discord text is slice 1 (this script). Voice via the Olive Siri-Shortcut
# pattern (docs/design/VOICE_ADVISOR.md) is slice 2 — not built here.
#
# SAFETY (advisor-only, per INFRA-3597 AC #3):
#   - Caller (discord-gateway.py) already filters to CHUMP_READY_DM_USER_ID
#     only; this script trusts that gate and does not re-check identity.
#   - --tools restricts the agent to Read/Grep/Glob/Bash — no Edit/Write/
#     NotebookEdit tool exists in the session at all, so it is structurally
#     unable to modify files.
#   - --allowedTools whitelists a READ-ONLY set: almanac queries, gap/PR/
#     ambient reads, and the single notify_operator reply call. Notably
#     ABSENT: `chump gap reserve` and any git/gh write verb — the advisor
#     hands actionable items to Jeff or the board, it does not act.
#   - --permission-mode dontAsk auto-denies anything outside that allowlist
#     instead of hanging on absent stdin.
#   - --max-budget-usd caps spend per invocation (per-message cost cap).
#
# Usage: discord-advisor-agent.sh "<Jeff's question>"
# Env:
#   CHUMP_DISCORD_ADVISOR_TIMEOUT_S    wall-clock bound (default 240s)
#   CHUMP_DISCORD_ADVISOR_BUDGET_USD   per-message cost cap (default 0.50)
#   CHUMP_DISCORD_ADVISOR_MODEL        model override (default sonnet)
set -uo pipefail

# INFRA-3607: the Discord gateway runs this from a systemd service whose env has
# NO HOME (systemd does not set it, unlike an interactive shell / launchd). Under
# `set -u`, the FIRST ${HOME} reference (ALMANAC_BIN below, plus the oauth-token
# read) aborts the whole script with "HOME: unbound variable" BEFORE `claude` is
# ever invoked -- a silent crash the gateway hid by discarding stderr, and the
# reason a manual run (HOME set) delivered while the gateway run produced nothing.
# Default HOME from the passwd entry so this works under systemd, cron, or a shell.
if [[ -z "${HOME:-}" ]]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    export HOME
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[discord-advisor-agent] cannot cd repo root" >&2; exit 1; }

QUESTION_TEXT="${1:-}"
if [[ -z "$QUESTION_TEXT" ]]; then
    echo "[discord-advisor-agent] usage: discord-advisor-agent.sh '<question>'" >&2
    exit 2
fi

TIMEOUT_S="${CHUMP_DISCORD_ADVISOR_TIMEOUT_S:-240}"
BUDGET_USD="${CHUMP_DISCORD_ADVISOR_BUDGET_USD:-0.50}"
MODEL="${CHUMP_DISCORD_ADVISOR_MODEL:-sonnet}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[discord-advisor-agent %s] %s\n' "$(ts)" "$*"; }
ambient_emit() {
    local kind="$1"; shift
    mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' "$(ts)" "$kind" "$*" \
        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null || printf '"(unescapable)"'
}

Q_JSON="$(json_escape "$QUESTION_TEXT")"
# scanner-anchor: "kind":"discord_advisor_agent_dispatched"
ambient_emit "discord_advisor_agent_dispatched" ",\"question\":${Q_JSON}"
log "dispatch start — question=${QUESTION_TEXT:0:80}"

ALMANAC_BIN="${HOME}/Projects/almanac/target/release/almanac"
ALMANAC_HINT=""
if [[ -x "$ALMANAC_BIN" ]]; then
    ALMANAC_HINT="Almanac CLI is available at ${ALMANAC_BIN} — call it FIRST for \
any question about code, a repo, or 'where does X live' (it spans the whole \
fleet, not just ChumpOS)."
else
    ALMANAC_HINT="Almanac CLI was not found at ${ALMANAC_BIN} — say so plainly \
if a question needs it rather than guessing at code facts."
fi

PROMPT="You are The Advisor — Chump's full-time conversational companion \
(docs/design/VOICE_ADVISOR.md, INFRA-3597). You are summoned fresh (no \
desktop session) because Jeff just sent this DM:

    ${QUESTION_TEXT}

You are an ADVISOR, NOT A DEVELOPER. Your whole job is to KNOW everything \
about the fleet (almanac as the proxy for the whole fleet, plus live gap/PR/ \
ambient state) and TALK to Jeff. Do the following and then STOP (one turn, \
do not loop, do not call ScheduleWakeup):

1. Read whatever the question needs: almanac (see hint below) for code/repo \
questions, gap state ('chump gap list' / 'chump gap view <id>'), open PRs \
(cache-first per CLAUDE.md — read .chump/github_cache.db before any 'gh' \
call), or ambient.jsonl / state.db.
   ${ALMANAC_HINT}
2. You are READ-ONLY. You have no Edit/Write tools and no write-verb Bash \
commands (no 'chump gap reserve', no git push/commit, no 'gh pr merge', \
nothing that mutates anything). If the answer surfaces something actionable \
(a gap to file, a PR to rescue), DESCRIBE it in your reply — do not do it. \
Jeff or the ops agent (INFRA-3596) acts on it, you only advise.
3. Every concrete claim — a PR's status, a gap's state, a file's path, a \
repo's structure, whether something exists — MUST come from a tool result \
you got this turn. NEVER invent, estimate, or guess a repo/PR/gate/file \
fact. If you don't know, say so, or call a tool.
4. Compose a terse, useful reply (a few sentences, conversational — this may \
be read aloud per the voice slice later, so avoid markdown tables/headers) \
and send it to Jeff via this EXACT single-command form (do not use 'source' \
+ '&&' — that compound is denied outright): \
'CHUMP_NOTIFY_KIND=discord_advisor_reply scripts/coord/lib/notify-operator.sh \
\"<reply>\"'. This is the ONLY way your answer reaches Jeff — you MUST call \
it before stopping, even if the question was unclear (reply saying so).
5. Append exactly one line to .chump-locks/ambient.jsonl (via printf, JSON-\
escaping the question text yourself):
   {\"ts\":\"<utc>\",\"kind\":\"discord_advisor_agent_completed\",\"question\":\"<escaped question>\",\"replied\":<true|false>}
   Set \"replied\":true only after notify_operator returns 0, else false.

If reading state fails entirely, still call notify_operator with a message \
saying so — a silent failure is worse than an honest one."
# scanner-anchor: "kind":"discord_advisor_agent_completed" — emitted by the
# advisor agent itself per step 5 of PROMPT above (the agent runs the printf
# itself; this comment is the pairing anchor the registry gate scans for
# since the literal above lives inside an escaped-quote bash string).

# CREDIBLE-1567: route git history and GitHub cache reads through the vetted
# read-only wrapper scripts/dispatch/architect-ro.sh instead of raw git/sqlite3,
# and explicitly deny all escape-capable binaries and write/merge paths.
ALLOWED_TOOLS=(
    "Bash(${ALMANAC_BIN}*)"
    "Bash(scripts/dispatch/architect-ro.sh *)"
    "Bash(git status*)"
    "Bash(gh pr list*)"
    "Bash(gh pr view*)"
    "Bash(gh issue list*)"
    "Bash(chump gap list*)"
    "Bash(chump gap view*)"
    "Bash(chump --briefing*)"
    "Bash(cat*)"
    "Bash(tail*)"
    "Bash(CHUMP_NOTIFY_KIND=discord_advisor_reply scripts/coord/lib/notify-operator.sh*)"
    "Bash(scripts/coord/lib/notify-operator.sh*)"
    "Bash(printf*)"
    "Bash(echo*)"
)
DENIED_TOOLS=(
    'Edit' 'Write' 'NotebookEdit'
    'Bash(gh pr merge*)' 'Bash(gh api*)' 'Bash(git push*)'
    'Bash(bash*)' 'Bash(sh*)' 'Bash(zsh*)' 'Bash(env*)' 'Bash(sudo*)'
    'Bash(python*)' 'Bash(perl*)' 'Bash(eval*)' 'Bash(exec*)' 'Bash(xargs*)'
    'Bash(sqlite3*)' 'Bash(git fetch*)' 'Bash(git log*)' 'Bash(git diff*)' 'Bash(git -c*)'
)

# INFRA-3602: OAUTH defensive read — the Discord gateway invokes this script
# from a bare process (launchd/cron-style), not an interactive `claude`
# session, so CLAUDE_CODE_OAUTH_TOKEN is not inherited. Same pattern as
# fix-trunk-dispatcher.sh's INFRA-2340 fix: load it from the fleet's
# refreshed copy at ~/.chump/oauth-token.json if neither auth env var is
# already set (env wins for explicit overrides / api-key mode).
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
    if [[ -r "$HOME/.chump/oauth-token.json" ]]; then
        _token=$(python3 -c "import json; print(json.load(open('$HOME/.chump/oauth-token.json')).get('token',''))" 2>/dev/null)
        if [[ -n "$_token" ]]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$_token"
            log "loaded CLAUDE_CODE_OAUTH_TOKEN from ~/.chump/oauth-token.json (len=${#_token})"
        else
            log "WARN: ~/.chump/oauth-token.json present but token key empty"
        fi
        unset _token
    else
        log "WARN: no CLAUDE_CODE_OAUTH_TOKEN, no ANTHROPIC_API_KEY, no readable ~/.chump/oauth-token.json — advisor will likely 401"
    fi
fi

cycle_output=""
cycle_rc=0
CLAUDE_ARGS=(-p "$PROMPT"
    --tools "Read,Grep,Glob,Bash"
    --allowedTools "${ALLOWED_TOOLS[@]}"
    --disallowedTools "${DENIED_TOOLS[@]}"
    --permission-mode dontAsk
    --max-budget-usd "$BUDGET_USD"
    --model "$MODEL")

# INFRA-3835: authoritative "did the agent get an answer out?" signal. The agent
# sends its reply via `CHUMP_NOTIFY_KIND=discord_advisor_reply notify-operator.sh`,
# which writes an ambient event carrying `"signal":"discord_advisor_reply"` (an
# operator_direct_message once this fix is deployed, an operator_paged before it).
# Counting that marker on disk before/after the turn is decoupled from claude's
# stdout/stderr plumbing, so it survives a non-zero exit that still replied.
ADVISOR_REPLY_MARKER='"signal":"discord_advisor_reply"'
_replies_before="$(grep -c "$ADVISOR_REPLY_MARKER" "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)"

if command -v timeout >/dev/null 2>&1; then
    cycle_output="$(timeout "${TIMEOUT_S}s" claude "${CLAUDE_ARGS[@]}" 2>&1)"
    cycle_rc=$?
else
    cycle_output="$(claude "${CLAUDE_ARGS[@]}" 2>&1)"
    cycle_rc=$?
fi
printf '%s\n' "$cycle_output"

# scanner-anchor: "kind":"discord_advisor_agent_beat"
ambient_emit "discord_advisor_agent_beat" ",\"exit_code\":${cycle_rc},\"node\":\"$(hostname -s 2>/dev/null || echo node)\""
log "dispatch done — exit_code=$cycle_rc"

# Fallback safety net (INFRA-3835 rewrite). A non-zero exit is NOT the same as
# "Jeff heard nothing": in the incident that motivated this fix, the agent
# replied successfully and THEN exited 1 (budget/tool-deny after the answer), so
# the old unconditional fallback fired a SECOND "advisor agent failed" DM on top
# of the real answer — two back-to-back pages. The rule is now:
#   (a) ALWAYS record one QUIET diagnostic. discord_advisor_agent_failed is
#       classified `suppress` in operator-escalation-registry.txt → it lands in
#       ambient.jsonl (operator_notify_suppressed), never on the phone.
#   (b) ONLY DM Jeff a graceful "let me get back to you" when NO answer already
#       reached him this turn — preserving the RESILIENT-263 no-silence
#       guarantee for a genuine crash-before-reply, without double-DMing when
#       the agent did reply. That apology rides discord_advisor_reply (`direct`)
#       so it is delivered as a normal DM, not a page.
if [[ $cycle_rc -ne 0 ]]; then
    source "$REPO_ROOT/scripts/coord/lib/notify-operator.sh" 2>/dev/null || true
    _replies_after="$(grep -c "$ADVISOR_REPLY_MARKER" "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)"
    if declare -F notify_operator >/dev/null 2>&1; then
        # (a) Quiet diagnostic — suppressed to ambient, never DM'd.
        # scanner-anchor: "kind":"discord_advisor_agent_failed"
        CHUMP_NOTIFY_KIND=discord_advisor_agent_failed \
            notify_operator "advisor agent failed (exit ${cycle_rc}) on: ${QUESTION_TEXT:0:120}" || true
        # (b) Graceful answer ONLY if no reply landed this turn (no-silence net).
        if [[ "${_replies_after:-0}" -le "${_replies_before:-0}" ]]; then
            log "no advisor reply landed (before=${_replies_before} after=${_replies_after}) — sending graceful fallback DM"
            CHUMP_NOTIFY_KIND=discord_advisor_reply \
                notify_operator "I hit an error looking into that one (exit ${cycle_rc}). Let me get back to you." || true
        else
            log "advisor reply already landed (before=${_replies_before} after=${_replies_after}) — suppressing redundant failure DM"
        fi
    fi
fi

exit 0
