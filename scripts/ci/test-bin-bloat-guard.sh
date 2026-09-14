#!/usr/bin/env bash
# test-bin-bloat-guard.sh — EFFECTIVE-1666 (EFFECTIVE-414 slice)
#
# Self-fixture for scripts/ci/bin-bloat-guard.sh: proves the size-detection
# gate warns on an oversized new src/*.rs file and passes on a small one.
#
# Tier: C (advisory — this test validates a warn-only gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/bin-bloat-guard.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT

git init -q "$TMP_REPO"
git -C "$TMP_REPO" config user.email "test@example.com"
git -C "$TMP_REPO" config user.name "test"
mkdir -p "$TMP_REPO/src"
echo "// base" > "$TMP_REPO/src/lib.rs"
git -C "$TMP_REPO" add -A
git -C "$TMP_REPO" commit -q -m "base"
git -C "$TMP_REPO" branch -q -m main

# Case 1: new small file → PASS, no warning.
git -C "$TMP_REPO" checkout -q -b feature-small
echo "fn small() {}" > "$TMP_REPO/src/small_new_file.rs"
git -C "$TMP_REPO" add -A
git -C "$TMP_REPO" commit -q -m "add small file"

out=$(REPO_ROOT="$TMP_REPO" bash "$GUARD" --base main --threshold-kb 40 2>&1)
if echo "$out" | grep -q "WARN:"; then
    fail "small new file unexpectedly triggered a warning"
else
    ok "small new file passes silently"
fi

# Case 2: new oversized file → WARN, exit 0 (advisory by default).
git -C "$TMP_REPO" checkout -q main
git -C "$TMP_REPO" checkout -q -b feature-big
python3 -c "print('x' * (41 * 1024))" > "$TMP_REPO/src/big_new_file.rs" 2>/dev/null \
    || head -c $((41 * 1024)) /dev/zero | tr '\0' 'x' > "$TMP_REPO/src/big_new_file.rs"
git -C "$TMP_REPO" add -A
git -C "$TMP_REPO" commit -q -m "add big file"

set +e
out=$(REPO_ROOT="$TMP_REPO" bash "$GUARD" --base main --threshold-kb 40 2>&1)
rc=$?
set -e
if echo "$out" | grep -q "WARN: src/big_new_file.rs"; then
    ok "oversized new file triggers a warning"
else
    fail "oversized new file did not trigger a warning: $out"
fi
if [[ "$rc" -eq 0 ]]; then
    ok "advisory mode exits 0 despite warning"
else
    fail "advisory mode should exit 0, got $rc"
fi

# Case 3: fail-on-warn mode with no bypass trailer → exit 1.
set +e
out=$(REPO_ROOT="$TMP_REPO" CHUMP_BIN_BLOAT_FAIL_ON_WARN=1 bash "$GUARD" --base main --threshold-kb 40 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
    ok "fail-on-warn mode exits 1 without bypass trailer"
else
    fail "fail-on-warn mode should exit 1, got $rc"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
