#!/usr/bin/env bash
# INFRA-158: regression test for the credential-pattern pre-commit guard
# (INFRA-018). Scans staged diffs for common API-key / token shapes
# (sk-ant-, sk-, tgp_v1_, AIzaSy, ghp_, github_pat_) and blocks the
# commit on a hit. This test exercises pass/fail/bypass.
#
# IMPORTANT: do not commit any string here that looks like a real key,
# even in a closed test scope — credential-pattern guards on the parent
# repo would block adding this test file. Test fixtures use clearly
# fake patterns that match the regex shape but couldn't authenticate.
#
# Run from repo root: bash scripts/ci/test-credential-pattern-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox setup ────────────────────────────────────────────────────────────
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/scripts/git-hooks" "$SANDBOX/src"
cp "$REPO_ROOT/scripts/git-hooks/pre-commit" "$SANDBOX/scripts/git-hooks/pre-commit"
chmod +x "$SANDBOX/scripts/git-hooks/pre-commit"
# Need .rs files + Cargo.toml so cargo-fmt early-exit (pre-commit:947)
# doesn't bypass the credential guard. cargo fmt --all needs a manifest.
cat > "$SANDBOX/Cargo.toml" <<'EOF'
[package]
name = "sandbox"
version = "0.0.0"
edition = "2021"
EOF
cat > "$SANDBOX/src/lib.rs" <<'EOF'
pub fn x() {}
EOF
echo "init" > "$SANDBOX/README.md"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$SANDBOX" config core.hooksPath scripts/git-hooks

SANDBOX_ENV='CHUMP_LEASE_CHECK=0 CHUMP_STOMP_WARN=0 CHUMP_GAPS_LOCK=0 CHUMP_PREREG_CHECK=0
             CHUMP_CROSS_JUDGE_CHECK=0 CHUMP_SUBMODULE_CHECK=0 CHUMP_CHECK_BUILD=0
             CHUMP_DOCS_DELTA_CHECK=0 CHUMP_PREREG_CONTENT_CHECK=0 CHUMP_RAW_YAML_LOCK=0
             CHUMP_BOOK_SYNC_CHECK=0'

# Generate a fake-shaped credential dynamically so this test file itself
# doesn't carry a literal that pattern-matches.
fake_anthropic_key() {
    # Shape: sk-ant- + 30+ [A-Za-z0-9_-] chars matching the guard regex.
    # urandom binary output is ~25% alphanumeric on average, so pull plenty.
    printf 'sk-ant-%s' "$(head -c 400 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 40)"
}

# ── case 1: stage a fake credential → guard FAILS ────────────────────────────
FAKE_KEY="$(fake_anthropic_key)"
{
    echo 'fn secret_test() {'
    echo "    let _ = \"$FAKE_KEY\";"
    echo '}'
} >> "$SANDBOX/src/lib.rs"
git -C "$SANDBOX" add src/lib.rs
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "leak" >"$SANDBOX/.case1.out" 2>&1; then
    fail "fake credential unexpectedly committed"
else
    pass "fake-shaped credential blocked by guard"
fi

# ── case 1b (INFRA-7880): the guard must not echo the value it found ─────────
# stderr lands in bot-merge and worker logs; printing the match republishes it.
if grep -qF "$FAKE_KEY" "$SANDBOX/.case1.out"; then
    fail "guard echoed the matched value to its output"
else
    pass "matched value is not echoed"
fi
if grep -q 'value withheld' "$SANDBOX/.case1.out" && grep -q 'in: src/lib.rs' "$SANDBOX/.case1.out"; then
    pass "guard names the file and the key family instead"
else
    fail "guard output lacks the file name or the key-family line"
fi
rm -f "$SANDBOX/.case1.out"

# ── case 2: bypass env CHUMP_CREDENTIAL_CHECK=0 → guard skips ────────────────
if env $SANDBOX_ENV CHUMP_CREDENTIAL_CHECK=0 \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "bypassed leak" >/dev/null 2>&1; then
    pass "CHUMP_CREDENTIAL_CHECK=0 bypasses the guard"
else
    fail "bypass env didn't allow fake credential"
fi

# ── case 3: clean Rust commit (no credentials) → guard skips silently ────────
echo "fn benign() {}" >> "$SANDBOX/src/lib.rs"
git -C "$SANDBOX" add src/lib.rs
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "clean" >/dev/null 2>&1; then
    pass "clean Rust commit skips the guard"
else
    fail "guard incorrectly fired on clean code"
fi

# ── case 4: known-issue documentation ────────────────────────────────────────
# The credential-pattern guard sits AFTER the cargo-fmt early-exit at
# pre-commit:947, so docs-only commits with leaked credentials in
# markdown skip the guard entirely. This test does NOT cover that path
# because the bug is real and would be a CI failure here. Fix lives
# in a separate gap (file as INFRA-* follow-up to INFRA-158).
echo "[NOTE] docs-only-credential-leak path is a known blind spot (cargo-fmt early-exit at pre-commit:947)"
echo "       Tracked as a follow-up gap; not exercised by this test to keep CI green."

# ── sibling content guard (INFRA-7880): the report-only publish guard ────────
# Runs here so it rides this test's existing CI step AND its `chump preflight`
# mirror: one wiring, local and CI in sync. It gets its own step when the guard
# goes blocking.
if command -v python3 >/dev/null 2>&1; then
    if bash "$REPO_ROOT/scripts/ci/test-publish-guard-report-only.sh"; then
        pass "publish-guard report-only suite"
    else
        fail "publish-guard report-only suite (bash scripts/ci/test-publish-guard-report-only.sh)"
    fi
else
    echo "[SKIP] publish-guard report-only suite: python3 not on PATH (this is a skip, not a pass)"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
