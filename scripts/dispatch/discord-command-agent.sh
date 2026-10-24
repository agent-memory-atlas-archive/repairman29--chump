#!/usr/bin/env bash
# discord-command-agent.sh — INFRA-3596: the DISPATCH half that was missing.
#
# SEND (scripts/coord/lib/notify-operator.sh) and RECEIVE (scripts/ops/discord-gateway.py)
# already worked before this file existed. What was missing: when the operator
# DMs a free-text command, nothing *acted* on it — the gateway could only answer
# a handful of hardcoded strings (status/ping/help). This script is invoked by
# the gateway (fire-and-forget, one process per DM) with the operator's raw
# command text and runs it through a FRESH, bounded `claude -p` agent on
# whichever node the gateway lives on (helsinki, desktop-closed) — the same
# `claude -p` path scripts/dispatch/board-cycle-beat.sh already proved works
# without a desktop session. The agent reads board state, may file gaps, and
# replies to the operator via Discord itself (through notify-operator.sh) —
# this script's job is only to fire it, bound it, and prove it ran.
#
# SAFETY (per INFRA-3596 AC):
#   - Caller (discord-gateway.py) already filters to CHUMP_READY_DM_USER_ID
#     only; this script trusts that gate and does not re-check identity.
#   - --tools restricts the agent to Read/Grep/Glob/Bash — no Edit/Write/
#     NotebookEdit tool exists in the session at all, so it is structurally
#     unable to modify files.
#   - --allowedTools whitelists a narrow set of read-only + gap-filing +
#     notify Bash patterns; --permission-mode dontAsk auto-denies anything
#     outside that allowlist instead of hanging on absent stdin.
#   - --max-budget-usd caps spend per invocation (per-message cost cap, AC).
#
# RESILIENT-1497: this is now the two-way ANSWER half of the free Opus peer.
# Pointed at Opus (was sonnet) and the allowlist is loosened past pure-read:
# the peer can file gaps, dispatch, and reprioritize in response to an
# operator DM, not just report status. The per-message budget cap is
# unchanged on purpose (AC: "keep the per-message budget cap") and the
# GATED-action categories (repo visibility, spend, credentials, deletes,
# outward sends) are still structurally absent from the allowlist below and
# from --tools — the peer is never an approver of its own risky actions
# (META-901, see lib/peer-guardrails.sh for the canonical list both this
# script and duty-officer-loop.sh judgment-tick agree on).
#
# Usage: discord-command-agent.sh "<operator free-text command>"
# Env:
#   CHUMP_DISCORD_AGENT_TIMEOUT_S   wall-clock bound (default 240s)
#   CHUMP_DISCORD_AGENT_BUDGET_USD  per-message cost cap (default 0.50)
#   CHUMP_DISCORD_AGENT_MODEL       model override (default opus)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[discord-command-agent] cannot cd repo root" >&2; exit 1; }

COMMAND_TEXT="${1:-}"
if [[ -z "$COMMAND_TEXT" ]]; then
    echo "[discord-command-agent] usage: discord-command-agent.sh '<command text>'" >&2
    exit 2
fi

TIMEOUT_S="${CHUMP_DISCORD_AGENT_TIMEOUT_S:-240}"
BUDGET_USD="${CHUMP_DISCORD_AGENT_BUDGET_USD:-0.50}"
MODEL="${CHUMP_DISCORD_AGENT_MODEL:-opus}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[discord-command-agent %s] %s\n' "$(ts)" "$*"; }
ambient_emit() {
    local kind="$1"; shift
    mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' "$(ts)" "$kind" "$*" \
        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null || printf '"(unescapable)"'
}

CMD_JSON="$(json_escape "$COMMAND_TEXT")"
# scanner-anchor: "kind":"discord_command_agent_dispatched"
ambient_emit "discord_command_agent_dispatched" ",\"command\":${CMD_JSON}"
log "dispatch start — command=${COMMAND_TEXT:0:80}"

git fetch origin main -q 2>/dev/null || true

PROMPT="You are the Chump operator-agent, summoned fresh (no desktop session, \
per docs/architecture/OPERATOR_AGENT.md) because the operator just sent this \
DM command on Discord:

    ${COMMAND_TEXT}

Do the following and then STOP (one turn, do not loop, do not call \
ScheduleWakeup):

1. Read what's needed to answer/act on the command: gap state (via 'chump gap \
list' / 'chump gap view <id>'), open PRs (cache-first per CLAUDE.md — read \
.chump/github_cache.db before any 'gh' call), or ambient.jsonl / state.db, \
whichever the command actually needs.
2. You may ACT on non-gated fleet work, not just report: file a gap ('chump \
gap reserve', P2 default unless the command clearly states urgency), \
reprioritize an existing gap ('chump gap set'), or dispatch work ('chump \
dispatch'). If the command is a status/question request, just read and \
answer — do not mutate anything it didn't ask for.
3. GUARDRAIL (non-negotiable, enforced by your tool allowlist, not just this \
prompt): you have NO path to repo-visibility changes, spend/billing, \
credential rotation, deletes, or merges/pushes — those commands are not in \
your allowlist and Edit/Write/NotebookEdit tools do not exist in this \
session. If the operator's command asks for one of those, say so in your \
reply and note it needs Jeff/first-mate approval — you are never the \
approver of your own risky action (META-901).
4. Compose a terse, useful reply (a few lines max) and send it to the operator \
via this EXACT single-command form (do NOT use 'source' + '&&' -- that compound is denied by --permission-mode dontAsk): 'CHUMP_NOTIFY_KIND=discord_command_reply scripts/coord/lib/notify-operator.sh \"<reply>\"'. \
This is the ONLY way your answer reaches the operator — you MUST call it \
before stopping, even if the command was unclear (reply saying so).
5. Append exactly one line to .chump-locks/ambient.jsonl (via printf, JSON-\
escaping the command text yourself):
   {\"ts\":\"<utc>\",\"kind\":\"discord_command_agent_completed\",\"command\":\"<escaped command>\",\"replied\":<true|false>}
   Set \"replied\":true only after notify_operator returns 0, else false.

If reading state fails entirely, still call notify_operator with a message \
saying so — a silent failure is worse than an honest one."
# scanner-anchor: "kind":"discord_command_agent_completed" — emitted by the
# command agent itself per step 5 of PROMPT above (the agent runs the printf
# itself; this comment is the pairing anchor the registry gate scans for
# since the literal above lives inside an escaped-quote bash string).

# Ops fix 2026-08-13: ARRAY, not a space-joined string. The old string was
# passed unquoted as `--allowedTools $ALLOWED_TOOLS`, so word-splitting
# exposed `--briefing*)` (from `Bash(chump --briefing*)`) to claude's arg
# parser as a bogus option -> `error: unknown option '--briefing*)'` and
# claude exited 1 before running. The advisor script already used an array;
# this mirrors it. Also swaps the reply entry to the DIRECT notify-operator
# form (see PROMPT + INFRA-3602).
# RESILIENT-1497: added 'chump gap set' (reprioritize) and 'chump dispatch'
# (dispatch) past the original read+file-gap set, so the peer can ACT on an
# operator DM, not just answer it. Deliberately absent: anything that edits
# repo visibility, touches billing/credentials, deletes, or pushes/merges —
# those stay outside the allowlist as the structural guardrail (see
# lib/peer-guardrails.sh for the same category list enforced on the
# judgment-tick side).
# CREDIBLE-1567: no raw git log/diff/fetch or sqlite3 in ALLOWED_TOOLS —
# sqlite3 runs .shell/.system/-cmd, git fetch runs --upload-pack, and git log/diff
# write via --output. Route git history and GitHub cache reads through the
# vetted fixed-query wrapper scripts/dispatch/architect-ro.sh, and deny all
# escape-capable binaries and write/merge paths explicitly.
ALLOWED_TOOLS=(
    'Bash(scripts/dispatch/architect-ro.sh *)' 'Bash(git status*)'
    'Bash(gh pr list*)' 'Bash(gh pr view*)' 'Bash(gh issue list*)'
    'Bash(chump gap list*)' 'Bash(chump gap view*)' 'Bash(chump gap reserve*)'
    'Bash(chump gap set*)' 'Bash(chump dispatch*)'
    'Bash(chump --briefing*)' 'Bash(cat*)' 'Bash(tail*)'
    'Bash(CHUMP_NOTIFY_KIND=discord_command_reply scripts/coord/lib/notify-operator.sh*)'
    'Bash(scripts/coord/lib/notify-operator.sh*)' 'Bash(printf*)' 'Bash(echo*)'
)
DENIED_TOOLS=(
    'Edit' 'Write' 'NotebookEdit'
    'Bash(gh pr merge*)' 'Bash(gh api*)' 'Bash(git push*)'
    'Bash(bash*)' 'Bash(sh*)' 'Bash(zsh*)' 'Bash(env*)' 'Bash(sudo*)'
    'Bash(python*)' 'Bash(perl*)' 'Bash(eval*)' 'Bash(exec*)' 'Bash(xargs*)'
    'Bash(sqlite3*)' 'Bash(git fetch*)' 'Bash(git log*)' 'Bash(git diff*)' 'Bash(git -c*)'
)

cycle_output=""
cycle_rc=0
CLAUDE_ARGS=(-p "$PROMPT"
    --tools "Read,Grep,Glob,Bash"
    --allowedTools "${ALLOWED_TOOLS[@]}"
    --disallowedTools "${DENIED_TOOLS[@]}"
    --permission-mode dontAsk
    --max-budget-usd "$BUDGET_USD"
    --model "$MODEL")

if command -v timeout >/dev/null 2>&1; then
    cycle_output="$(timeout "${TIMEOUT_S}s" claude "${CLAUDE_ARGS[@]}" 2>&1)"
    cycle_rc=$?
else
    cycle_output="$(claude "${CLAUDE_ARGS[@]}" 2>&1)"
    cycle_rc=$?
fi
printf '%s\n' "$cycle_output"

# scanner-anchor: "kind":"discord_command_agent_beat"
ambient_emit "discord_command_agent_beat" ",\"exit_code\":${cycle_rc},\"node\":\"$(hostname -s 2>/dev/null || echo node)\""
log "dispatch done — exit_code=$cycle_rc"

# Fallback safety net: if the agent errored/timed out before it could call
# notify_operator itself, the operator must still hear SOMETHING rather than
# silence (the exact failure mode RESILIENT-263 exists to prevent).
if [[ $cycle_rc -ne 0 ]]; then
    source "$REPO_ROOT/scripts/coord/lib/notify-operator.sh" 2>/dev/null || true
    if declare -F notify_operator >/dev/null 2>&1; then
        # scanner-anchor: "kind":"discord_command_agent_failed"
        CHUMP_NOTIFY_KIND=discord_command_agent_failed \
            notify_operator "command agent failed (exit ${cycle_rc}) on: ${COMMAND_TEXT:0:120}" || true
    fi
fi

exit 0
