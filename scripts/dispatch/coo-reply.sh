#!/usr/bin/env bash
# coo-reply.sh — RESILIENT-1655 (PHASE-R R6): in-repo read-only COO Discord reply helper.
#
# Replaces out-of-repo /home/ubuntu/coo/* and untracked peer/ reply wrappers.
# Invokes `claude -p` with a strict read-only tool allowlist (Read, Grep, Glob)
# and explicit disallowlist — never write/edit/bash tools in the canonical checkout.
#
# Usage:
#   scripts/dispatch/coo-reply.sh [--dry-run] [--model MODEL] [--budget-usd N] \
#       [--prompt-file FILE | --prompt TEXT | <author> <channel_id> <message>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 2

CLAUDE_BIN="${CHUMP_CLAUDE_BIN:-claude}"
MODEL="${CHUMP_COO_MODEL:-sonnet}"
BUDGET_USD="${CHUMP_COO_BUDGET_USD:-0.50}"
DRY_RUN=0
PROMPT_FILE=""
PROMPT_TEXT=""

while (( $# )); do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --claude-bin)  CLAUDE_BIN="${2:?}"; shift 2 ;;
        --model)       MODEL="${2:?}"; shift 2 ;;
        --budget-usd)  BUDGET_USD="${2:?}"; shift 2 ;;
        --prompt-file) PROMPT_FILE="${2:?}"; shift 2 ;;
        --prompt)      PROMPT_TEXT="${2:?}"; shift 2 ;;
        --)            shift; break ;;
        -*)            echo "coo-reply: unknown flag: $1" >&2; exit 2 ;;
        *)             break ;;
    esac
done

if [[ -n "$PROMPT_FILE" ]]; then
    [[ -f "$PROMPT_FILE" ]] || { echo "coo-reply: prompt file not found: $PROMPT_FILE" >&2; exit 2; }
    PROMPT_TEXT="$(<"$PROMPT_FILE")"
elif [[ -z "$PROMPT_TEXT" && $# -ge 1 ]]; then
    AUTHOR="${1:-operator}"
    CHANNEL_ID="${2:-discord}"
    MESSAGE="${3:-$1}"
    PROMPT_TEXT="Discord operator message from ${AUTHOR} (channel ${CHANNEL_ID}): ${MESSAGE}

Reply concisely as the Chump COO using only read-only repo inspection (Read, Grep, Glob)."
fi

ALLOWED_TOOLS=(
    "Read"
    "Grep"
    "Glob"
)

DENIED_TOOLS=(
    "Edit"
    "Write"
    "NotebookEdit"
    "Bash"
    "WebFetch"
    "WebSearch"
    "Bash(gh pr merge*)"
    "Bash(gh api*)"
    "Bash(git push*)"
    "Bash(bash*)"
    "Bash(sh*)"
    "Bash(env*)"
    "Bash(python*)"
    "Bash(perl*)"
    "Bash(sqlite3*)"
    "Bash(git fetch*)"
    "Bash(git log*)"
)

ARGV=(
    "$CLAUDE_BIN"
    -p
    --model "$MODEL"
    --max-budget-usd "$BUDGET_USD"
    --permission-mode dontAsk
    --no-session-persistence
    --tools "Read,Grep,Glob"
    --allowedTools "Read,Grep,Glob"
    --allowedTools "${ALLOWED_TOOLS[@]}"
    --disallowedTools "${DENIED_TOOLS[@]}"
)

if (( DRY_RUN )); then
    printf '%s\n' "${ARGV[@]}"
    exit 0
fi

[[ -n "$PROMPT_TEXT" ]] || { echo "coo-reply: empty prompt" >&2; exit 2; }

printf '%s\n' "$PROMPT_TEXT" | "${ARGV[@]}"
