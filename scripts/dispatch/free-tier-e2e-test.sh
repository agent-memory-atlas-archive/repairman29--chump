#!/usr/bin/env bash
# EFFECTIVE-006: automated free-tier dispatch e2e test
#
# Exercises the full free-tier path: seed gap → dispatch → verify commit.
# Replaces the manual 5-step cycle that was run ad-hoc during EFFECTIVE-001/005.
#
# Usage:
#   scripts/dispatch/free-tier-e2e-test.sh --provider groq
#   scripts/dispatch/free-tier-e2e-test.sh --provider nvidia --model llama-3.3-70b-versatile
#   scripts/dispatch/free-tier-e2e-test.sh --provider cerebras
#   scripts/dispatch/free-tier-e2e-test.sh --provider github
#
# Env overrides (optional):
#   OPENAI_API_KEY     — provider key (or set per-provider: GROQ_API_KEY, etc.)
#   OPENAI_MODEL       — model name (auto-set per provider if omitted)
#   E2E_TIMEOUT        — dispatch timeout in seconds (default: 120)
#   E2E_MAX_ITER       — agent loop iterations (default: 12)
#   E2E_KEEP_WORKTREE  — set to 1 to skip cleanup on success
#
# Exit codes:
#   0 — model read → patched → committed successfully
#   1 — dispatch failed (model error, wrong tool use, etc.)
#   2 — setup/argument error

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_GAP_ID="E2E-$(date +%s)"
WT_PATH="/private/tmp/chump-e2e-test-$$"
E2E_TIMEOUT="${E2E_TIMEOUT:-120}"
E2E_MAX_ITER="${E2E_MAX_ITER:-12}"

# ── Provider presets (bash 3.2 compat — no associative arrays) ─────────
_provider_base() {
    case "$1" in
        groq)       echo "https://api.groq.com/openai/v1" ;;
        nvidia)     echo "https://integrate.api.nvidia.com/v1" ;;
        cerebras)   echo "https://api.cerebras.ai/v1" ;;
        github)     echo "https://models.github.ai/inference/v1" ;;
        together)   echo "https://api.together.xyz/v1" ;;
        hyperbolic) echo "https://api.hyperbolic.xyz/v1" ;;
        *)          return 1 ;;
    esac
}

_provider_model() {
    case "$1" in
        groq)       echo "llama-3.3-70b-versatile" ;;
        nvidia)     echo "meta/llama-3.3-70b-instruct" ;;
        cerebras)   echo "qwen-3-235b-a22b-instruct-2507" ;;
        github)     echo "meta-llama-3.3-70b-instruct" ;;
        together)   echo "meta-llama/Llama-3.3-70B-Instruct-Turbo" ;;
        hyperbolic) echo "meta-llama/Llama-3.3-70B-Instruct" ;;
        *)          return 1 ;;
    esac
}

_provider_keyvar() {
    case "$1" in
        groq)       echo "GROQ_API_KEY" ;;
        nvidia)     echo "NVIDIA_API_KEY" ;;
        cerebras)   echo "CEREBRAS_API_KEY" ;;
        github)     echo "GITHUB_TOKEN" ;;
        together)   echo "TOGETHER_API_KEY" ;;
        hyperbolic) echo "HYPERBOLIC_API_KEY" ;;
        *)          return 1 ;;
    esac
}

KNOWN_PROVIDERS="groq nvidia cerebras github together hyperbolic"

# ── Helpers ────────────────────────────────────────────────────────────
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo "[$(_ts)] [e2e] $*"; }
err()  { echo "[$(_ts)] [e2e] ERROR: $*" >&2; }
die()  { err "$@"; exit 2; }

cleanup() {
    if [[ "${E2E_KEEP_WORKTREE:-0}" == "1" ]]; then
        log "keeping worktree at $WT_PATH (E2E_KEEP_WORKTREE=1)"
        return
    fi
    if [[ -d "$WT_PATH" ]]; then
        log "cleaning up worktree $WT_PATH"
        git -C "$REPO_ROOT" worktree remove "$WT_PATH" --force 2>/dev/null || rm -rf "$WT_PATH"
    fi
}
trap cleanup EXIT

# Emit ambient event for fleet observability (INFRA-754 / EFFECTIVE-006)
_emit_ambient() {
    local result="$1" detail="${2:-}"
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$amb")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"free_tier_e2e","provider":"%s","model":"%s","result":"%s","detail":"%s"}\n' \
        "$(_ts)" "${PROVIDER:-unknown}" "${MODEL:-unknown}" "$result" "$detail" \
        >> "$amb" 2>/dev/null || true
}

# ── Argument parsing ───────────────────────────────────────────────────
PROVIDER=""
MODEL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) PROVIDER="$2"; shift 2 ;;
        --model)    MODEL_OVERRIDE="$2"; shift 2 ;;
        --timeout)  E2E_TIMEOUT="$2"; shift 2 ;;
        --max-iter) E2E_MAX_ITER="$2"; shift 2 ;;
        --keep)     E2E_KEEP_WORKTREE=1; shift ;;
        --help|-h)
            echo "Usage: $0 --provider <groq|nvidia|cerebras|github|together|hyperbolic> [--model MODEL] [--timeout SECS] [--keep]"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$PROVIDER" ]] || die "missing --provider ($KNOWN_PROVIDERS)"

# Validate provider
BASE_URL=$(_provider_base "$PROVIDER") || die "unknown provider: $PROVIDER (known: $KNOWN_PROVIDERS)"

# ── Resolve API key ───────────────────────────────────────────────────
KEYVAR=$(_provider_keyvar "$PROVIDER")
# Indirect variable expansion (bash 3.2 compat)
eval "PROVIDER_KEY=\${$KEYVAR:-}"
API_KEY="${OPENAI_API_KEY:-$PROVIDER_KEY}"
[[ -n "$API_KEY" ]] || die "no API key: set OPENAI_API_KEY or $KEYVAR"

# ── Resolve model ─────────────────────────────────────────────────────
DEFAULT_MODEL=$(_provider_model "$PROVIDER")
MODEL="${MODEL_OVERRIDE:-$DEFAULT_MODEL}"

log "provider=$PROVIDER model=$MODEL base=$BASE_URL"
log "timeout=${E2E_TIMEOUT}s max_iter=$E2E_MAX_ITER"

# ── Step 1: Create throwaway worktree ─────────────────────────────────
log "step 1/6: creating worktree at $WT_PATH"
git -C "$REPO_ROOT" worktree add "$WT_PATH" -b "e2e-test-$$" origin/main 2>/dev/null \
    || die "failed to create worktree"

# ── Step 2: Seed a trivial gap ────────────────────────────────────────
log "step 2/6: seeding test gap $TEST_GAP_ID"

# Create a minimal gap YAML that asks the model to add a comment to a file
TEST_FILE="src/execute_gap.rs"
mkdir -p "$WT_PATH/docs/gaps"
cat > "$WT_PATH/docs/gaps/$TEST_GAP_ID.yaml" <<YAML
- id: $TEST_GAP_ID
  domain: EFFECTIVE
  title: "E2E test: add a comment to execute_gap.rs"
  status: open
  priority: P3
  effort: xs
  acceptance_criteria: |
    Add a single-line comment "// $TEST_GAP_ID: e2e test marker" at the
    top of src/execute_gap.rs (after any existing comments/doc-comments,
    before the first use/mod statement). Then commit.
YAML

log "  seeded gap YAML at docs/gaps/$TEST_GAP_ID.yaml"
log "  target file: $TEST_FILE"

# Record pre-dispatch state
PRE_HASH=$(git -C "$WT_PATH" rev-parse HEAD)

# ── Step 3: Build binary ──────────────────────────────────────────────
log "step 3/6: building chump binary"

# ZERO-WASTE-134: one shared cargo target (no per-worktree build dir); the binary
# path below is read from $CARGO_TARGET_DIR, not from a worktree-local target/.
# shellcheck source=../ci/lib/resolve-cargo-target-dir.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/ci/lib/resolve-cargo-target-dir.sh"
export CARGO_TARGET_DIR="$(chump_cargo_target_dir)"
if ! cargo build --release --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null; then
    # Fallback: use the repo's existing binary
    log "  WARN: cargo build failed; falling back to existing binary"
    CHUMP_BIN=$(which chump 2>/dev/null || echo "$REPO_ROOT/target/release/chump")
else
    CHUMP_BIN="$CARGO_TARGET_DIR/release/chump"
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    # Last resort: find any chump binary
    CHUMP_BIN=$(find "$REPO_ROOT/target" -name chump -type f -perm +111 2>/dev/null | head -1)
    [[ -x "$CHUMP_BIN" ]] || die "no chump binary found"
fi
log "  using binary: $CHUMP_BIN"

# ── Step 4: Run dispatch ──────────────────────────────────────────────
log "step 4/6: dispatching $TEST_GAP_ID via $PROVIDER/$MODEL"

DISPATCH_LOG="$WT_PATH/dispatch.log"

(
    cd "$WT_PATH"
    export OPENAI_API_BASE="$BASE_URL"
    export OPENAI_API_KEY="$API_KEY"
    export OPENAI_MODEL="$MODEL"
    export CHUMP_AUTH_MODE="api-key"
    export CHUMP_CASCADE_ENABLED=0
    export CHUMP_AGENT_MAX_ITER="$E2E_MAX_ITER"
    export CHUMP_DISPATCH_DEPTH=1
    export CHUMP_TOOLS_ASK=""
    # Prevent ambient hooks from firing in throwaway worktree
    export CHUMP_AMBIENT_INSTALL_SKIP=1

    timeout "${E2E_TIMEOUT}s" "$CHUMP_BIN" --execute-gap "$TEST_GAP_ID"
) >"$DISPATCH_LOG" 2>&1
DISPATCH_RC=$?

# ── Step 5: Inspect results ───────────────────────────────────────────
log "step 5/6: inspecting results (exit code=$DISPATCH_RC)"

POST_HASH=$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null || echo "NONE")
COMMITTED=false
TOOL_TRACE=""

# Extract tool calls from dispatch log
if [[ -f "$DISPATCH_LOG" ]]; then
    # Look for tool-call indicators in the output
    TOOL_TRACE=$(grep -E 'tool_call|read_file|patch_file|write_file|git_commit|list_dir|free-tier' "$DISPATCH_LOG" 2>/dev/null | head -30 || true)
fi

if [[ "$PRE_HASH" != "$POST_HASH" ]]; then
    COMMITTED=true
    COMMIT_MSG=$(git -C "$WT_PATH" log --oneline -1 2>/dev/null || echo "(unknown)")
    log "  ✓ NEW COMMIT: $COMMIT_MSG"
else
    log "  ✗ no new commit (HEAD unchanged)"
fi

# Check if the test marker exists in the target file
MARKER_FOUND=false
if grep -q "$TEST_GAP_ID" "$WT_PATH/$TEST_FILE" 2>/dev/null; then
    MARKER_FOUND=true
    log "  ✓ test marker found in $TEST_FILE"
else
    log "  ✗ test marker NOT found in $TEST_FILE"
fi

# Check if any files were modified at all
MODIFIED_FILES=$(git -C "$WT_PATH" diff --name-only "$PRE_HASH" HEAD 2>/dev/null || echo "")

# ── Step 6: Print summary ────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  FREE-TIER E2E TEST RESULTS"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Provider:      $PROVIDER"
echo "  Model:         $MODEL"
echo "  Gap:           $TEST_GAP_ID"
echo "  Exit code:     $DISPATCH_RC"
echo "  Committed:     $COMMITTED"
echo "  Marker found:  $MARKER_FOUND"
echo ""

if [[ -n "$MODIFIED_FILES" ]]; then
    echo "  Modified files:"
    echo "$MODIFIED_FILES" | sed 's/^/    /'
    echo ""
fi

if [[ -n "$TOOL_TRACE" ]]; then
    echo "  Tool trace (first 30 lines):"
    echo "$TOOL_TRACE" | sed 's/^/    /'
    echo ""
fi

echo "  Dispatch log:  $DISPATCH_LOG"
echo "  Worktree:      $WT_PATH"
echo ""

# ── Verdict ───────────────────────────────────────────────────────────
if [[ "$COMMITTED" == "true" ]] && [[ "$MARKER_FOUND" == "true" ]]; then
    _emit_ambient "pass" "read+patch+commit"
    echo "  ✅ PASS — model read → patched → committed correctly"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    exit 0
elif [[ "$COMMITTED" == "true" ]]; then
    _emit_ambient "partial" "committed but marker missing"
    echo "  ⚠️  PARTIAL — committed but marker not in target file"
    echo "     (model may have edited wrong file or used wrong content)"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    exit 1
elif [[ "$DISPATCH_RC" -eq 124 ]]; then
    _emit_ambient "timeout" "exceeded ${E2E_TIMEOUT}s"
    echo "  ❌ FAIL — timed out after ${E2E_TIMEOUT}s"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    exit 1
else
    _emit_ambient "fail" "rc=$DISPATCH_RC"
    echo "  ❌ FAIL — no commit produced (rc=$DISPATCH_RC)"
    echo ""
    # Show last 20 lines of dispatch log for debugging
    if [[ -f "$DISPATCH_LOG" ]]; then
        echo "  Last 20 lines of dispatch log:"
        tail -20 "$DISPATCH_LOG" | sed 's/^/    /'
        echo ""
    fi
    echo "═══════════════════════════════════════════════════════════"
    exit 1
fi
