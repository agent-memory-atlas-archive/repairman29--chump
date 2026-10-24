#!/usr/bin/env bash
# test-code-reviewer-authskip.sh — regression test for CREDIBLE-1529 (supersedes INFRA-3457).
#
# CREDIBLE-1529 (PHASE-R R3): scripts/coord/code-reviewer-agent.sh must NEVER
# exit 3 (SKIP, reserved strictly for docs-only PRs) when a src/* PR review
# did not run because the LLM gateway (`chump llm-complete`) was unavailable.
# Instead:
#   (1) gateway failure/empty output on a src/* PR exits 5 (UNAVAILABLE) and
#       prints `UNAVAILABLE: reviewer gateway unavailable ...`.
#   (2) no-auth-configured fast path on a src/* PR exits 5 (UNAVAILABLE) without
#       invoking the gateway.
#   (3) a docs-only PR still exits 3 (`SKIP: docs-only PR`).
#   (4) scripts/coord/bot-merge.sh handles exit 5 separately from `0|3`, emits
#       `kind=code_review_unavailable` to ambient.jsonl, and holds auto-merge.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== CREDIBLE-1529 code-reviewer unavailable-exit-5 regression test ==="
echo

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ── Fake `gh` — serves a src/* diff for PR 999 and a docs/* diff for PR 997 ─
cat > "$TMPDIR/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
    pr="$3"
    if [[ "$pr" == "997" ]]; then
        if [[ "$*" == *"--name-only"* ]]; then
            echo "docs/some_doc.md"
        else
            cat <<'DIFF'
diff --git a/docs/some_doc.md b/docs/some_doc.md
index 0000000..1111111 100644
--- a/docs/some_doc.md
+++ b/docs/some_doc.md
@@ -1,1 +1,2 @@
 # Doc
+More text
DIFF
        fi
        exit 0
    fi
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
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
    exit 0
fi
echo "fake gh: unhandled args: $*" >&2
exit 1
GHEOF
chmod +x "$TMPDIR/gh"

# ── Fake `chump` — simulates the gateway finding no configured provider ─────
cat > "$TMPDIR/chump" <<'CHUMPEOF'
#!/usr/bin/env bash
exit 1
CHUMPEOF
chmod +x "$TMPDIR/chump"

# (1) Gateway-unavailable on src/* PR → UNAVAILABLE (exit 5), never SKIP (exit 3).
set +e
OUTPUT=$(OPENAI_API_KEY="stub-key" PATH="$TMPDIR:$PATH" CHUMP_LLM_BIN="$TMPDIR/chump" CHUMP_TWO_TIER_REVIEW=0 \
    bash "$REPO_ROOT/scripts/coord/code-reviewer-agent.sh" 999 2>&1)
RC=$?
set -e

if [[ $RC -eq 5 ]]; then
    ok "gateway-unavailable on src/* PR exits 5 (UNAVAILABLE), never 3 (SKIP)"
else
    fail "expected exit 5 (UNAVAILABLE) on gateway-unavailable, got exit $RC. Output:
$OUTPUT"
fi

if echo "$OUTPUT" | grep -q "^UNAVAILABLE: reviewer gateway unavailable"; then
    ok "UNAVAILABLE: line surfaced for bot-merge log visibility"
else
    fail "no 'UNAVAILABLE: reviewer gateway unavailable' line in output. Output:
$OUTPUT"
fi

# ── (2) Nothing configured at all — fast UNAVAILABLE (exit 5), gateway never invoked.
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

if [[ $RC2 -eq 5 ]]; then
    ok "no-auth-configured-at-all on src/* PR exits 5 (UNAVAILABLE) without invoking gateway"
else
    fail "expected exit 5 (UNAVAILABLE) with no auth configured, got exit $RC2. Output:
$OUTPUT2"
fi

if echo "$OUTPUT2" | grep -q "^UNAVAILABLE: reviewer gateway unavailable"; then
    ok "UNAVAILABLE: line surfaced for the no-auth-at-all case"
else
    fail "no 'UNAVAILABLE: reviewer gateway unavailable' line in no-auth-at-all output. Output:
$OUTPUT2"
fi

# ── (3) Docs-only PR still exits 3 (SKIP).
set +e
OUTPUT3=$(PATH="$TMPDIR:$PATH" CHUMP_LLM_BIN="$TMPDIR/chump" \
    bash "$REPO_ROOT/scripts/coord/code-reviewer-agent.sh" 997 2>&1)
RC3=$?
set -e

if [[ $RC3 -eq 3 ]] && echo "$OUTPUT3" | grep -q "^SKIP: docs-only PR"; then
    ok "docs-only PR still exits 3 (SKIP: docs-only PR)"
else
    fail "expected exit 3 + SKIP: docs-only PR, got exit $RC3. Output:
$OUTPUT3"
fi

# ── (4) bot-merge.sh handles exit 5 by emitting kind=code_review_unavailable and holding.
if grep -qE "^[[:space:]]*5\)" "$REPO_ROOT/scripts/coord/bot-merge.sh" \
    && grep -q '"kind":"code_review_unavailable"' "$REPO_ROOT/scripts/coord/bot-merge.sh"; then
    ok "bot-merge.sh handles exit 5 explicitly and emits kind=code_review_unavailable"
else
    fail "bot-merge.sh missing explicit 5) handler or kind=code_review_unavailable emission"
fi

echo
echo "=== Result ==="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
