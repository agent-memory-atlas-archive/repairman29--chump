#!/usr/bin/env bash
# test-code-reviewer-authskip.sh — regression test for INFRA-3457.
#
# The Tier-2 review call in scripts/coord/code-reviewer-agent.sh runs through
# `chump llm-complete` (the shared cascade gateway, INFRA-3462), which owns
# auth (API key, OAuth ladder, provider fallback) internally. If the gateway
# can't produce a review for any reason — including an OAuth-only session with
# no ANTHROPIC_API_KEY and no other provider configured — the reviewer must
# SKIP (exit 3) rather than block. The reviewer is a BONUS gate; GitHub's
# required checks are the real protection, so a purely environmental auth-miss
# must never leave auto-merge disarmed.
#
# This test stubs `gh` (PR diff plumbing) and `chump llm-complete` (gateway)
# to simulate "gateway unavailable" and asserts:
#   (1) exit code is 3 (SKIP), not 4 (ERROR/blocking).
#   (2) stdout/stderr surfaces a SKIP: line so a chronically-skipping
#       reviewer stays visible in bot-merge's log.
#
# Run:
#   ./scripts/ci/test-code-reviewer-authskip.sh
#
# Exits non-zero on any failure.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-3457 code-reviewer auth-miss-is-SKIP regression test ==="
echo

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ── Fake `gh` — serves a small, non-docs, non-sensitive diff for PR 999 ──────
cat > "$TMPDIR/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
    if [[ "$*" == *"--name-only"* ]]; then
        echo "src/fake_module.rs"
    else
        cat <<'DIFF'
diff --git a/src/fake_module.rs b/src/fake_module.rs
index 0000000..1111111 100644
--- a/src/fake_module.rs
+++ b/src/fake_module.rs
@@ -1,1 +1,2 @@
 fn existing() {}
+fn added() {}
DIFF
    fi
    exit 0
fi
echo "fake gh: unhandled args: $*" >&2
exit 1
GHEOF
chmod +x "$TMPDIR/gh"

# ── Fake `chump` — simulates the gateway finding no configured provider ─────
cat > "$TMPDIR/chump" <<'CHUMPEOF'
#!/usr/bin/env bash
# Simulate the ProviderCascade gateway with no provider available: no
# stdout, non-zero exit — exactly what code-reviewer-agent.sh sees when
# no ANTHROPIC_API_KEY / OAuth token / cascade slot is configured.
exit 1
CHUMPEOF
chmod +x "$TMPDIR/chump"

# (1) Gateway-unavailable → SKIP (exit 3), never ERROR (exit 4).
set +e
OUTPUT=$(PATH="$TMPDIR:$PATH" CHUMP_LLM_BIN="$TMPDIR/chump" CHUMP_TWO_TIER_REVIEW=0 \
    bash "$REPO_ROOT/scripts/coord/code-reviewer-agent.sh" 999 2>&1)
RC=$?
set -e

if [[ $RC -eq 3 ]]; then
    ok "gateway-unavailable auth-miss exits 3 (SKIP), not 4 (blocking ERROR)"
else
    fail "expected exit 3 (SKIP) on gateway-unavailable, got exit $RC. Output:\n$OUTPUT"
fi

if echo "$OUTPUT" | grep -q "^SKIP: reviewer gateway unavailable"; then
    ok "SKIP: line surfaced for bot-merge log visibility"
else
    fail "no 'SKIP: reviewer gateway unavailable' line in output. Output:\n$OUTPUT"
fi

# ── (2) Nothing configured at all (INFRA-5005) — fast SKIP, gateway never
# invoked. Stub `chump` to sleep well past any reasonable test timeout so a
# regression that falls through to the gateway (and its ~30s cascade
# exhaustion retry, INFRA-363) fails this test instead of merely being slow.
FAKEHOME="$TMPDIR/fakehome"
mkdir -p "$FAKEHOME"
cat > "$TMPDIR/chump-should-not-run" <<'CHUMPEOF'
#!/usr/bin/env bash
sleep 60
CHUMPEOF
chmod +x "$TMPDIR/chump-should-not-run"

set +e
OUTPUT2=$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u OPENAI_API_KEY -u OPENAI_API_BASE \
    -u CHUMP_PROVIDER_1_ENABLED -u CHUMP_PROVIDER_2_ENABLED -u CHUMP_PROVIDER_3_ENABLED \
    HOME="$FAKEHOME" PATH="$TMPDIR:$PATH" CHUMP_LLM_BIN="$TMPDIR/chump-should-not-run" \
    CHUMP_TWO_TIER_REVIEW=0 timeout 10 \
    bash "$REPO_ROOT/scripts/coord/code-reviewer-agent.sh" 999 2>&1)
RC2=$?
set -e

if [[ $RC2 -eq 3 ]]; then
    ok "no-auth-configured-at-all exits 3 (SKIP) without invoking the gateway"
else
    fail "expected exit 3 (SKIP) with no auth configured, got exit $RC2 (124 = timed out waiting on gateway). Output:\n$OUTPUT2"
fi

if echo "$OUTPUT2" | grep -q "^SKIP: reviewer gateway unavailable"; then
    ok "SKIP: line surfaced for the no-auth-at-all case"
else
    fail "no 'SKIP: reviewer gateway unavailable' line in no-auth-at-all output. Output:\n$OUTPUT2"
fi

echo
echo "=== Result ==="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
