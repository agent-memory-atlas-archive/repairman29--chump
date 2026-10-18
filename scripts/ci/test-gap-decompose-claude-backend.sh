#!/usr/bin/env bash
# test-gap-decompose-claude-backend.sh — INFRA-8573
#
# `chump gap decompose` historically built its LLM provider with
# provider_cascade::build_provider(), whose last-resort slot on an
# un-configured node is a localhost Ollama (http://127.0.0.1:11434/v1). On a
# build node like cuphead there is no Ollama daemon and no cloud cascade, so
# every decompose died — even though `chump dispatch` on the same node reaches
# Opus fine via `claude -p`. INFRA-8573 gives decompose the same `claude -p`
# reach via a --backend flag and a cascade→claude fallthrough.
#
# This validates:
#   Static (always):
#     1. decompose_backend module exists with the three backends.
#     2. decompose arm parses --backend and routes through
#        build_decompose_provider.
#     3. FallthroughProvider lists every provider tried on total failure.
#     4. --backend documented in the usage string + CHUMP_DECOMPOSE_MODEL
#        registered in env-vars-internal.txt.
#   Runtime (requires CHUMP_BIN), with STUB providers:
#     5. --backend auto: cascade (dead Ollama endpoint) fails, decompose falls
#        through to a stub `claude` and succeeds — the core cuphead scenario.
#     6. --backend claude: reaches the stub `claude` directly (no cascade).
#     7. total failure lists each provider tried in order (cascade, claude -p).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-8573 gap decompose claude -p backend test ==="
echo

# ── Static source checks (no binary required) ────────────────────────────────

MOD="$REPO_ROOT/src/decompose_backend.rs"

# 1. Module exists with the three backends.
if [[ -f "$MOD" ]] && grep -q 'enum DecomposeBackend' "$MOD"; then
    ok "src/decompose_backend.rs defines DecomposeBackend"
else
    fail "src/decompose_backend.rs missing or lacks DecomposeBackend"
fi

if grep -q 'ClaudeCliProvider' "$MOD" && grep -q 'claude' "$MOD"; then
    ok "ClaudeCliProvider (claude -p backend) present"
else
    fail "ClaudeCliProvider missing from decompose_backend.rs"
fi

# 2. decompose arm parses --backend and routes through build_decompose_provider.
if grep -q 'DecomposeBackend::resolve' "$REPO_ROOT/src/main.rs"; then
    ok "decompose arm resolves --backend"
else
    fail "decompose arm does not resolve --backend"
fi

if grep -q 'decompose_backend::build_decompose_provider' "$REPO_ROOT/src/main.rs"; then
    ok "decompose routes through build_decompose_provider"
else
    fail "decompose does not call build_decompose_provider"
fi

# 3. FallthroughProvider lists every provider tried on failure.
if grep -q 'tried in order' "$MOD" && grep -q 'FallthroughProvider' "$MOD"; then
    ok "FallthroughProvider lists providers tried on failure"
else
    fail "FallthroughProvider / 'tried in order' message missing"
fi

# 4. --backend documented + env var registered.
if grep -q '\-\-backend auto|cascade|claude' "$REPO_ROOT/src/main.rs"; then
    ok "--backend documented in decompose usage string"
else
    fail "--backend missing from decompose usage string"
fi

if grep -q '^CHUMP_DECOMPOSE_MODEL$' "$REPO_ROOT/scripts/ci/env-vars-internal.txt"; then
    ok "CHUMP_DECOMPOSE_MODEL registered in env-vars-internal.txt"
else
    fail "CHUMP_DECOMPOSE_MODEL not registered in env-vars-internal.txt"
fi

# ── Runtime checks with stub providers ───────────────────────────────────────

# Resolve a built chump binary (honors CHUMP_BIN, then the cargo target dir).
# No binary is a hard failure, never a SKIP-pass (CREDIBLE-1528 class): a
# runtime gate that silently skips proves nothing.
# shellcheck source=scripts/ci/lib/discover-chump-bin.sh
source "$REPO_ROOT/scripts/ci/lib/discover-chump-bin.sh"
CHUMP="$CHUMP_BIN"
{
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    TMPDB="$WORK/state.db"
    STUBDIR="$WORK/bin"
    mkdir -p "$STUBDIR"

    # Stub `claude` binary: ignores argv, drains stdin (the prompt), prints a
    # fixed JSON array of two slices to stdout and exits 0. This is the
    # stand-in for a working `claude -p` on a node with no Ollama/cascade.
    ALPHA="INFRA-8573-stub-slice-alpha"
    BETA="INFRA-8573-stub-slice-beta"
    cat >"$STUBDIR/claude" <<EOF
#!/usr/bin/env bash
cat >/dev/null   # drain the prompt on stdin
cat <<'JSON'
[
  {"title": "$ALPHA", "effort": "xs", "priority": "P2", "acceptance_criteria": ["a is testable"], "depends_on": []},
  {"title": "$BETA", "effort": "s", "priority": "P2", "acceptance_criteria": ["b is testable"], "depends_on": [0]}
]
JSON
EOF
    chmod +x "$STUBDIR/claude"

    # Create a synthetic medium gap. Keep the description path-free so the AST
    # pre-step surfaces no candidates (no repo crawl needed).
    FIXTURE_TITLE="INFRA-8573-test-fixture-claude-backend"
    CHUMP_GAP_RESERVE_NO_SIMILARITY=1 CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap reserve \
        --domain INFRA --title "$FIXTURE_TITLE" --force-duplicate 2>/dev/null || true
    # `gap list --json` is pretty-printed: `"id": "INFRA-NNNN"` (note the space).
    FIXTURE_ID=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap list --status open --json 2>/dev/null \
        | grep -o '"id": *"[^"]*"' | tail -1 | sed 's/.*"id": *"//;s/"//') || true

    if [[ -z "${FIXTURE_ID:-}" ]]; then
        fail "could not create fixture gap — runtime tests skipped"
    else
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap set "$FIXTURE_ID" --effort m 2>/dev/null || true
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap set "$FIXTURE_ID" \
            --description "decompose this placeholder work into slices" 2>/dev/null || true

        # Common env for the runtime decompose calls: a DEAD Ollama endpoint so
        # the cascade path fails fast, forcing the fallthrough. Unset cascade so
        # build_provider() returns the single local provider at this dead base.
        run_decompose() {
            local backend="$1"
            PATH="$STUBDIR:$PATH" \
            CHUMP_STATE_DB="$TMPDB" \
            OPENAI_API_BASE="http://127.0.0.1:9/v1" \
            OPENAI_API_KEY="ollama" \
            CHUMP_CASCADE_ENABLED="" \
            CHUMP_WORK_BACKEND="" \
            CHUMP_DECOMPOSE_AST="0" \
                "$CHUMP" gap decompose "$FIXTURE_ID" --backend "$backend" --json 2>&1 || true
        }

        # 5. --backend auto: cascade (dead endpoint) fails → fall through to the
        #    stub claude → success. The stub's slice titles must appear.
        AUTO_OUT="$(run_decompose auto)"
        if echo "$AUTO_OUT" | grep -q "$ALPHA" && echo "$AUTO_OUT" | grep -q "$BETA"; then
            ok "--backend auto falls through to claude when Ollama is down"
        else
            fail "--backend auto did not reach claude stub; output: $AUTO_OUT"
        fi

        # 6. --backend claude: reach the stub directly (no cascade build).
        CLAUDE_OUT="$(run_decompose claude)"
        if echo "$CLAUDE_OUT" | grep -q "$ALPHA"; then
            ok "--backend claude reaches the claude -p backend directly"
        else
            fail "--backend claude did not reach claude stub; output: $CLAUDE_OUT"
        fi

        # 7. Total failure lists each provider tried in order. Replace the stub
        #    with one that exits non-zero so BOTH cascade and claude fail.
        cat >"$STUBDIR/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "stub claude forced failure" >&2
exit 1
EOF
        chmod +x "$STUBDIR/claude"
        FAIL_OUT="$(run_decompose auto)"
        if echo "$FAIL_OUT" | grep -q "tried in order" \
           && echo "$FAIL_OUT" | grep -q "cascade" \
           && echo "$FAIL_OUT" | grep -q "claude -p"; then
            ok "total failure lists each provider tried in order"
        else
            fail "failure message did not list providers in order; output: $FAIL_OUT"
        fi
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
