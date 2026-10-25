#!/usr/bin/env bash
# coo-tick.sh — RESILIENT-1655 (PHASE-R R6): in-repo read-only COO periodic tick.
#
# Replaces the out-of-repo ~/chump/peer/coo-tick.sh and /home/ubuntu/coo/run.sh
# organs. Runs `claude -p` with a strict read-only tool allowlist (Read, Grep,
# Glob) and explicit disallowlist so the canonical checkout is never mutated.
#
# Usage:
#   scripts/dispatch/coo-tick.sh [--dry-run] [--model MODEL] [--budget-usd N] [--prompt-file FILE]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 2

CLAUDE_BIN="${CHUMP_CLAUDE_BIN:-claude}"
MODEL="${CHUMP_COO_MODEL:-sonnet}"
BUDGET_USD="${CHUMP_COO_BUDGET_USD:-0.50}"
DRY_RUN=0
PROMPT_FILE=""

while (( $# )); do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --claude-bin)  CLAUDE_BIN="${2:?}"; shift 2 ;;
        --model)       MODEL="${2:?}"; shift 2 ;;
        --budget-usd)  BUDGET_USD="${2:?}"; shift 2 ;;
        --prompt-file) PROMPT_FILE="${2:?}"; shift 2 ;;
        -*)            echo "coo-tick: unknown flag: $1" >&2; exit 2 ;;
        *)             break ;;
    esac
done

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

if [[ -n "$PROMPT_FILE" ]]; then
    [[ -f "$PROMPT_FILE" ]] || { echo "coo-tick: prompt file not found: $PROMPT_FILE" >&2; exit 2; }
    PROMPT_BODY="$(<"$PROMPT_FILE")"
else
    HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    PROMPT_BODY="Chump COO read-only tick at HEAD ${HEAD_SHA}. Summarize current fleet status and urgent risks in <= 5 lines using only Read, Grep, Glob."
fi

printf '%s\n' "$PROMPT_BODY" | "${ARGV[@]}"
