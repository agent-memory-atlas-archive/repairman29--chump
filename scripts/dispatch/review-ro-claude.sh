#!/usr/bin/env bash
# review-ro-claude.sh — CREDIBLE-1542 (PHASE-R R3): the ONE self-contained file
# that holds the independent review organ's read-only `claude -p` argv.
#
# WHY A DEDICATED FILE: the reviewer is the delegated independent review for a
# code-reviewer ESCALATE (operator decision 2026-10-18: Jeff is not a
# developer). It runs on a PUBLIC repo checkout that also holds live tokens on
# disk (~/.cache/chump-gh-shim/auth-token.txt and friends). So the argv is the
# safety boundary, and it is kept in one place, reviewed as a unit, and asserted
# by scripts/ci/test-arm-policy.sh (AC2). The reviewer has NO write tools: no
# Bash, no Edit, no Write, no WebFetch/WebSearch — only Read/Grep/Glob, and Read
# is SCOPED to the review run dir and the repo checkout (never HOME), so it
# cannot read ~/.ssh, ~/.config, ~/.claude or wander the filesystem.
#
# HARD RULES honoured here (Chief 2026-10-20): the tool allowlist, the brief
# (prompt) source, the claude binary and the scoped read roots are SAFETY
# INPUTS and are NEVER read from a CHUMP_* environment variable — a default that
# an env var could widen is a bypass by construction. The only test seam is
# explicit CLI arguments the systemd unit never passes (--claude-bin, --run-dir,
# --checkout, --prompt-file, --dry-run). The prompt is passed as DATA in a file;
# the fixed review brief that wraps it lives in the ORGAN
# (review-organ-tick.sh), which writes the prompt file.
#
# Usage:
#   review-ro-claude.sh --run-dir DIR --checkout DIR --prompt-file FILE \
#       [--claude-bin BIN] [--budget-usd N] [--model M] [--dry-run]
#
#   --dry-run prints the exact claude argv (one token per line) and exits 0
#   WITHOUT spawning — this is the seam scripts/ci/test-arm-policy.sh parses to
#   prove the allowlist has no write tool (it changes nothing about the real
#   spawn, so it is a diagnostic flag, not an env safety override).
#
# OUTPUT: the reviewer's stdout is piped through a token scrubber before it is
# returned, so no gh token / API key that leaked into the model's output is ever
# posted to the PUBLIC PR (repair item 5).
set -uo pipefail

die() { echo "review-ro-claude: $*" >&2; exit 2; }

RUN_DIR=""; CHECKOUT=""; PROMPT_FILE=""; DRY_RUN=0
# Defaults are CONSTANTS, not env reads. --claude-bin/--model/--budget-usd are
# explicit CLI args a test may pass; the unit passes none of them.
CLAUDE_BIN="claude"; MODEL="opus"; BUDGET_USD="2.00"

while (( $# )); do
    case "$1" in
        --run-dir)     RUN_DIR="${2:-}"; shift 2 ;;
        --checkout)    CHECKOUT="${2:-}"; shift 2 ;;
        --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
        --claude-bin)  CLAUDE_BIN="${2:-}"; shift 2 ;;
        --model)       MODEL="${2:-}"; shift 2 ;;
        --budget-usd)  BUDGET_USD="${2:-}"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     sed -n '2,37p' "$0"; exit 0 ;;
        *)             die "unknown argument '$1'" ;;
    esac
done

[[ -n "$RUN_DIR" ]]     || die "--run-dir is required"
[[ -n "$CHECKOUT" ]]    || die "--checkout is required"
[[ -n "$PROMPT_FILE" ]] || die "--prompt-file is required"
[[ -d "$RUN_DIR" ]]     || die "run dir '$RUN_DIR' is not a directory"
[[ -d "$CHECKOUT" ]]    || die "checkout '$CHECKOUT' is not a directory"
[[ -r "$PROMPT_FILE" ]] || die "prompt file '$PROMPT_FILE' is not readable"
[[ "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--budget-usd must be a number"
case "$MODEL" in ''|*[!A-Za-z0-9._-]*) die "--model has an unexpected value" ;; esac

RUN_DIR="$(cd "$RUN_DIR" && pwd)"
CHECKOUT="$(cd "$CHECKOUT" && pwd)"

# ── The tool allowlist IS the enforcement (AC2). --permission-mode dontAsk
# default-denies everything NOT listed, so the ABSENCE of Bash/Edit/Write is
# what forbids them; the explicit --disallowedTools are belt-and-suspenders
# (deny wins). Read is SCOPED to the two roots — never a bare `Read` and never
# HOME — so a leaked path outside them is denied. ──
RO_ALLOWED_TOOLS=(
    "Read(${RUN_DIR}/**)"
    "Read(${CHECKOUT}/**)"
    "Grep"
    "Glob"
)
RO_DISALLOWED_TOOLS=(
    'Edit' 'Write' 'NotebookEdit'
    'Bash' 'WebFetch' 'WebSearch'
)

# The claude argv. --setting-sources '' ignores every settings.json on disk (no
# project/user hooks or permissions leak in), --settings disables all hooks
# explicitly, --strict-mcp-config ignores any MCP server config. --tools lists
# ONLY the read tools (no Bash). --add-dir scopes the filesystem roots to the
# run dir and the checkout — NOT HOME.
CLAUDE_ARGS=(
    -p "$(cat -- "$PROMPT_FILE")"
    --setting-sources ''
    --settings '{"disableAllHooks":true}'
    --strict-mcp-config
    --tools 'Read,Grep,Glob'
    --allowedTools "${RO_ALLOWED_TOOLS[@]}"
    --disallowedTools "${RO_DISALLOWED_TOOLS[@]}"
    --add-dir "$RUN_DIR"
    --add-dir "$CHECKOUT"
    --permission-mode dontAsk
    --max-budget-usd "$BUDGET_USD"
    --model "$MODEL"
)

if (( DRY_RUN )); then
    # Print the resolved argv the real spawn would use (prompt body collapsed to
    # a marker so the allowlist/flags are greppable one-per-line). The test
    # asserts there is no Bash/Edit/Write allow and that Read is scoped.
    printf '%s\n' "$CLAUDE_BIN"
    for a in "${CLAUDE_ARGS[@]}"; do
        case "$a" in
            "$(cat -- "$PROMPT_FILE")") printf '%s\n' '<PROMPT-BODY>' ;;
            *) printf '%s\n' "$a" ;;
        esac
    done
    exit 0
fi

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "claude binary '$CLAUDE_BIN' not on PATH"

# scrub_tokens — redact any token-shaped string from the reviewer's output
# before it is returned for posting to a PUBLIC PR (repair item 5). Covers gh
# tokens (ghp_/gho_/ghu_/ghs_/ghr_/github_pat_), Anthropic keys (sk-ant-), and
# the literal content of the on-disk gh token file if it exists.
scrub_tokens() {
    local tok_file="$HOME/.cache/chump-gh-shim/auth-token.txt" live=""
    [[ -r "$tok_file" ]] && live="$(tr -d '\r\n' < "$tok_file" 2>/dev/null || true)"
    sed -E \
        -e 's/gh[opusr]_[A-Za-z0-9]{20,}/[REDACTED-GH-TOKEN]/g' \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED-GH-PAT]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED-ANTHROPIC-KEY]/g' \
    | { if [[ -n "$live" ]]; then LIVE="$live" python3 -c '
import os,sys
live=os.environ.get("LIVE","")
data=sys.stdin.read()
if live:
    data=data.replace(live,"[REDACTED-GH-TOKEN]")
sys.stdout.write(data)
'; else cat; fi; }
}

# MINIMAL ENV (repair item 5): spawn claude with env -i and only the few
# variables it needs — HOME (for its config/cache), PATH, TERM, and the
# subscription OAuth token / API key if present. providers.env is NEVER sourced
# here, so no extra secrets ride into the reviewer process.
run_minimal() {
    local -a env_kv=(
        "HOME=${HOME:-/tmp}"
        "PATH=${PATH:-/usr/bin:/bin}"
        "TERM=${TERM:-dumb}"
    )
    [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && env_kv+=("CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
    [[ -n "${ANTHROPIC_API_KEY:-}" ]]       && env_kv+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
    [[ "$(id -u)" == "0" ]] && env_kv+=("IS_SANDBOX=1")
    env -i "${env_kv[@]}" "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}"
}

run_minimal 2>&1 | scrub_tokens
exit "${PIPESTATUS[0]}"
