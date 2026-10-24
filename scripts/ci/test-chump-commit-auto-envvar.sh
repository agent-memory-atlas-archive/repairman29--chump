#!/usr/bin/env bash
# scripts/ci/test-chump-commit-auto-envvar.sh — INFRA-1853
#
# Verifies scripts/coord/chump-commit.sh contains the auto-envvar-append
# block: detects new CHUMP_* env refs in staged Rust/scripts, appends to
# env-vars-internal.txt with AUTO breadcrumb, honors CHUMP_AUTO_ENVVAR=0
# bypass with audit emit.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/chump-commit.sh"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }

ag "$SCRIPT" "INFRA-1853" "chump-commit.sh has INFRA-1853 attribution"
ag "$SCRIPT" "env-vars-internal.txt" "chump-commit.sh references env-vars-internal.txt"
ag "$SCRIPT" "CHUMP_\[A-Z\]\[A-Z0-9_\]\+" "chump-commit.sh uses CHUMP_* env-detection regex"
ag "$SCRIPT" "CHUMP_AUTO_ENVVAR" "chump-commit.sh honors CHUMP_AUTO_ENVVAR bypass"
ag "$SCRIPT" "auto_envvar_applied" "chump-commit.sh emits auto_envvar_applied"
ag "$SCRIPT" "auto_envvar_bypassed" "chump-commit.sh emits auto_envvar_bypassed on bypass"
ag "$SCRIPT" "AUTO \(INFRA-1853\)" "chump-commit.sh writes AUTO breadcrumb comment"
ag "$SCRIPT" "git add .*_envvar_file" "chump-commit.sh re-stages env-vars-internal.txt"

ag "$RESERVED" "^auto_envvar_applied" "reserved.txt allowlists auto_envvar_applied"
ag "$RESERVED" "^auto_envvar_bypassed" "reserved.txt allowlists auto_envvar_bypassed"

# Structural: the new block must appear BEFORE git commit
new_block=$(grep -n "INFRA-1853:" "$SCRIPT" | head -1 | cut -d: -f1)
commit_line=$(grep -n "^git commit \"\${GIT_ARGS\[@\]}\"" "$SCRIPT" | tail -1 | cut -d: -f1)
if [[ -n "$new_block" && -n "$commit_line" && "$new_block" -ge "$commit_line" ]]; then
    echo "FAIL: INFRA-1853 block (line $new_block) must precede git commit (line $commit_line)"
    failures=$((failures+1))
fi

# ── INFRA-8579 AC3: detector rules documented in chump-commit.sh header ──────
if head -n 45 "$SCRIPT" | grep -q "INFRA-8579 env-var auto-register detector rules"; then
    echo "PASS: INFRA-8579 AC3: detector rules documented in chump-commit.sh header"
else
    echo "FAIL: INFRA-8579 AC3: detector rules missing from chump-commit.sh header"
    failures=$((failures+1))
fi

# ── INFRA-8579 AC1 + AC2: fixture commits exercising chump-commit.sh ─────────
TMP_REPO="$(mktemp -d /tmp/test-infra-8579-XXXXXX)"
trap 'rm -rf "$TMP_REPO"' EXIT

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email "test@chump.bot"
git -C "$TMP_REPO" config user.name "Test"
git -C "$TMP_REPO" config commit.gpgsign false
git -C "$TMP_REPO" checkout -q -b claude/test-8579

mkdir -p "$TMP_REPO/scripts/ci" "$TMP_REPO/scripts/ops" "$TMP_REPO/src" "$TMP_REPO/.chump-locks"
cat > "$TMP_REPO/scripts/ci/env-vars-internal.txt" <<'EOF'
CHUMP_KNOWN_EXISTING
EOF
git -C "$TMP_REPO" add scripts/ci/env-vars-internal.txt
git -C "$TMP_REPO" commit -q -m "chore: init fixture"

# Make hooks no-op in the temp repo so chump-commit.sh exercises its own logic fast.
mkdir -p "$TMP_REPO/.git/hooks"
rm -f "$TMP_REPO/.git/hooks/pre-commit" "$TMP_REPO/.git/hooks/commit-msg"

# AC1 fixture commit: scripts/ci test that only greps/asserts for CHUMP_FORBIDDEN_GREP_8579
# and mentions CHUMP_COMMENT_ONLY_8579 in a comment -> MUST NOT write env-vars-internal.txt.
cat > "$TMP_REPO/scripts/ci/test-neg-env.sh" <<'EOF'
#!/usr/bin/env bash
# Comment mention: CHUMP_COMMENT_ONLY_8579 must not be registered.
if grep -q "CHUMP_FORBIDDEN_GREP_8579" some_file; then
    echo "FAIL: CHUMP_FORBIDDEN_GREP_8579 should be absent"
    exit 1
fi
EOF

(
    cd "$TMP_REPO"
    CHUMP_ALLOW_MAIN_WORKTREE=1 CHUMP_AUTO_FMT=0 \
        bash "$SCRIPT" scripts/ci/test-neg-env.sh -m "test(ci): negative grep fixture (INFRA-8579)" >/dev/null 2>&1
)

if grep -qE "CHUMP_FORBIDDEN_GREP_8579|CHUMP_COMMENT_ONLY_8579" "$TMP_REPO/scripts/ci/env-vars-internal.txt"; then
    echo "FAIL: INFRA-8579 AC1: negative grep/comment in scripts/ci test polluted env-vars-internal.txt"
    cat "$TMP_REPO/scripts/ci/env-vars-internal.txt"
    failures=$((failures+1))
else
    echo "PASS: INFRA-8579 AC1: scripts/ci test grep/comment did not register CHUMP_FORBIDDEN_GREP_8579"
fi

# Ambiguous mention in non-test script -> warns on stderr, does NOT register.
cat > "$TMP_REPO/scripts/ops/ambiguous.sh" <<'EOF'
#!/usr/bin/env bash
echo "mentioning CHUMP_AMBIGUOUS_TOKEN_8579 in prose output"
EOF

amb_err="$(
    cd "$TMP_REPO"
    CHUMP_ALLOW_MAIN_WORKTREE=1 CHUMP_AUTO_FMT=0 \
        bash "$SCRIPT" scripts/ops/ambiguous.sh -m "chore: ambiguous token fixture (INFRA-8579)" 2>&1 >/dev/null
)"
if grep -q "CHUMP_AMBIGUOUS_TOKEN_8579" "$TMP_REPO/scripts/ci/env-vars-internal.txt"; then
    echo "FAIL: INFRA-8579: ambiguous token was written to env-vars-internal.txt"
    failures=$((failures+1))
elif echo "$amb_err" | grep -q "INFRA-8579: warning.*CHUMP_AMBIGUOUS_TOKEN_8579"; then
    echo "PASS: INFRA-8579: ambiguous token printed warning without writing env-vars-internal.txt"
else
    echo "FAIL: INFRA-8579: ambiguous token did not emit expected warning (got: $amb_err)"
    failures=$((failures+1))
fi

# AC2 fixture commit: real ${CHUMP_REAL_SH_8579} expansion + Rust std::env::var("CHUMP_REAL_RS_8579") -> MUST auto-register!
cat > "$TMP_REPO/scripts/ops/real-read.sh" <<'EOF'
#!/usr/bin/env bash
val="${CHUMP_REAL_SH_8579:-default}"
echo "$val"
EOF
cat > "$TMP_REPO/src/lib.rs" <<'EOF'
pub fn read_env() -> Option<String> {
    std::env::var("CHUMP_REAL_RS_8579").ok()
}
EOF

(
    cd "$TMP_REPO"
    CHUMP_ALLOW_MAIN_WORKTREE=1 CHUMP_AUTO_FMT=0 \
        bash "$SCRIPT" scripts/ops/real-read.sh src/lib.rs -m "feat: real env reads (INFRA-8579)" >/dev/null 2>&1
)

if grep -q "^CHUMP_REAL_SH_8579$" "$TMP_REPO/scripts/ci/env-vars-internal.txt" && \
   grep -q "^CHUMP_REAL_RS_8579$" "$TMP_REPO/scripts/ci/env-vars-internal.txt"; then
    echo "PASS: INFRA-8579 AC2: real \${CHUMP_REAL_SH_8579} and std::env::var(\"CHUMP_REAL_RS_8579\") auto-registered"
else
    echo "FAIL: INFRA-8579 AC2: real reads did not auto-register into env-vars-internal.txt"
    cat "$TMP_REPO/scripts/ci/env-vars-internal.txt"
    failures=$((failures+1))
fi

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1853: $failures"; exit 1; }
echo "OK INFRA-1853: chump-commit.sh auto-appends new CHUMP_* envs to env-vars-internal.txt"
