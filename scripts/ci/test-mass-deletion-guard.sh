#!/usr/bin/env bash
# test-mass-deletion-guard.sh — CREDIBLE-027 + CREDIBLE-038: fixture-based tests for check-mass-deletion.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ci/check-mass-deletion.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-mass-del.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Helper: create a throwaway git repo with a controlled diff ───────────────
make_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.invalid"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
}

# ── Test 1: vague commit title 'first' is flagged ────────────────────────────
REPO1="$TMP/repo1"
make_repo "$REPO1"
# base commit
printf 'initial content\n' > "$REPO1/file.txt"
git -C "$REPO1" add file.txt
git -C "$REPO1" commit -q -m "chore: init repo"
git -C "$REPO1" checkout -q -b feature
printf 'changed\n' > "$REPO1/file.txt"
git -C "$REPO1" add file.txt
git -C "$REPO1" commit -q -m "first"

out="$(cd "$REPO1" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "Vague commit title" || fail "Test 1: should detect 'first' as vague title"
pass "Test 1: vague commit 'first' flagged"

# ── Test 2: legitimate commit title passes ───────────────────────────────────
REPO2="$TMP/repo2"
make_repo "$REPO2"
printf 'initial content\n' > "$REPO2/file.txt"
git -C "$REPO2" add file.txt
git -C "$REPO2" commit -q -m "chore: init repo"
git -C "$REPO2" checkout -q -b feature
printf 'changed\n' > "$REPO2/file.txt"
git -C "$REPO2" add file.txt
git -C "$REPO2" commit -q -m "fix(auth): correct token expiry calculation"

out="$(cd "$REPO2" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "No vague commit titles" || fail "Test 2: clean commit should pass vague-title check"
pass "Test 2: clean commit title passes"

# ── Test 3: mass deletion from unrelated file is flagged (--warn-only) ───────
REPO3="$TMP/repo3"
make_repo "$REPO3"
# Create a file with 200 lines
python3 -c "print('\n'.join(f'line {i}' for i in range(200)))" > "$REPO3/bigfile.py"
printf 'readme content\n' > "$REPO3/README.md"
git -C "$REPO3" add bigfile.py README.md
git -C "$REPO3" commit -q -m "chore: initial"
git -C "$REPO3" checkout -q -b feature
# Delete most lines from bigfile.py (unrelated to commit message)
printf 'only one line left\n' > "$REPO3/bigfile.py"
git -C "$REPO3" add bigfile.py
git -C "$REPO3" commit -q -m "feat(README): update readme content"

out="$(cd "$REPO3" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "Mass deletion" || fail "Test 3: should detect mass deletion from bigfile.py (unrelated to 'readme')"
pass "Test 3: mass deletion from unrelated file flagged"

# ── Test 4: mass deletion from mentioned file passes ─────────────────────────
REPO4="$TMP/repo4"
make_repo "$REPO4"
python3 -c "print('\n'.join(f'line {i}' for i in range(200)))" > "$REPO4/bigfile.py"
git -C "$REPO4" add bigfile.py
git -C "$REPO4" commit -q -m "chore: initial"
git -C "$REPO4" checkout -q -b feature
printf 'refactored\n' > "$REPO4/bigfile.py"
git -C "$REPO4" add bigfile.py
# Commit message mentions 'bigfile' so mass deletion is intentional
git -C "$REPO4" commit -q -m "refactor(bigfile): collapse bigfile into single declaration"

out="$(cd "$REPO4" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "No mass unrelated deletions" || fail "Test 4: mentioned-file deletion should pass"
pass "Test 4: mentioned-file mass deletion passes"

# ── Test 4b (INFRA-5744): explicit Revert commit exempts unrelated mass deletion ──
REPO4B="$TMP/repo4b"
make_repo "$REPO4B"
python3 -c "print('\n'.join(f'line {i}' for i in range(200)))" > "$REPO4B/big_module.rs"
git -C "$REPO4B" add big_module.rs
git -C "$REPO4B" commit -q -m "chore: initial"
git -C "$REPO4B" checkout -q -b feature
rm "$REPO4B/big_module.rs"
git -C "$REPO4B" add -A
# Commit subject starts with 'Revert' but neither commit nor body names the file —
# without the INFRA-5744 fix this false-positived as an "unrelated" mass deletion.
git -C "$REPO4B" commit -q -m "Revert: undo accidental addition"

out="$(cd "$REPO4B" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
echo "$out" | grep -q "Explicit Revert commit detected" || fail "Test 4b: explicit Revert commit should exempt mass-deletion check"
echo "$out" | grep -q "Mass deletion" && fail "Test 4b: Revert commit should not be flagged as mass deletion"
pass "Test 4b: explicit Revert commit exempts unrelated mass deletion"

# ── Test 5: --warn-only exits 0 even with violations ─────────────────────────
REPO5="$TMP/repo5"
make_repo "$REPO5"
printf 'x\n' > "$REPO5/f.txt"
git -C "$REPO5" add f.txt
git -C "$REPO5" commit -q -m "chore: initial"
git -C "$REPO5" checkout -q -b feature
printf 'y\n' > "$REPO5/f.txt"
git -C "$REPO5" add f.txt
git -C "$REPO5" commit -q -m "wip"

cd "$REPO5" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only > /dev/null 2>&1 \
    && pass "Test 5: --warn-only exits 0 even with violations" \
    || fail "Test 5: --warn-only should not exit non-zero"

# ── Test 6: without --warn-only, violation exits 1 ───────────────────────────
REPO6="$TMP/repo6"
make_repo "$REPO6"
printf 'x\n' > "$REPO6/f.txt"
git -C "$REPO6" add f.txt
git -C "$REPO6" commit -q -m "chore: initial"
git -C "$REPO6" checkout -q -b feature
printf 'y\n' > "$REPO6/f.txt"
git -C "$REPO6" add f.txt
git -C "$REPO6" commit -q -m "init"

if cd "$REPO6" && GITHUB_BASE_REF=main bash "$GUARD" > /dev/null 2>&1; then
    fail "Test 6: should exit 1 on vague title without --warn-only"
else
    pass "Test 6: strict mode exits 1 on violation"
fi


# ── Test 7: chore(gaps) title + 60 docs/gaps/*.yaml → PASS (CREDIBLE-038) ───
REPO7="$TMP/repo7"
make_repo "$REPO7"
mkdir -p "$REPO7/docs/gaps"
for i in $(seq 1 60); do printf 'id: GAP-%03d\n' "$i" > "$REPO7/docs/gaps/GAP-$(printf '%03d' $i).yaml"; done
git -C "$REPO7" add docs/
git -C "$REPO7" commit -q -m "chore: initial"
git -C "$REPO7" checkout -q -b feature
# Modify all 60 gap files (simulates mass-AC additions)
for i in $(seq 1 60); do printf 'id: GAP-%03d\nacceptance_criteria: ["done"]\n' "$i" > "$REPO7/docs/gaps/GAP-$(printf '%03d' $i).yaml"; done
git -C "$REPO7" add docs/
git -C "$REPO7" commit -q -m "chore(gaps): add concrete AC to 60 gaps"

out="$(cd "$REPO7" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "out-of-scope\|narrow scope\|CREDIBLE-038.*title prefix"; then
    fail "Test 7: chore(gaps) with only docs/gaps/* files should PASS rule C"
else
    pass "Test 7: chore(gaps) mass-AC addition (60 docs/gaps/* files) passes rule C"
fi

# ── Test 8: chore(gaps) title + docs/gaps/* AND src/* → FAIL (CREDIBLE-038) ──
REPO8="$TMP/repo8"
make_repo "$REPO8"
mkdir -p "$REPO8/docs/gaps" "$REPO8/src"
for i in $(seq 1 5); do printf 'id: GAP-%03d\n' "$i" > "$REPO8/docs/gaps/GAP-$(printf '%03d' $i).yaml"; done
printf 'fn main() {}\n' > "$REPO8/src/main.rs"
git -C "$REPO8" add docs/ src/
git -C "$REPO8" commit -q -m "chore: initial"
git -C "$REPO8" checkout -q -b feature
for i in $(seq 1 5); do printf 'id: GAP-%03d\nacceptance_criteria: ["done"]\n' "$i" > "$REPO8/docs/gaps/GAP-$(printf '%03d' $i).yaml"; done
printf 'fn main() { println!("changed"); }\n' > "$REPO8/src/main.rs"
git -C "$REPO8" add docs/ src/
git -C "$REPO8" commit -q -m "chore(gaps): add AC to gaps"

out="$(cd "$REPO8" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "out-of-scope\|promises narrow scope\|title prefix.*promises"; then
    pass "Test 8: chore(gaps) + src/* triggers rule C violation"
else
    fail "Test 8: should detect out-of-scope src/main.rs under chore(gaps) title: $out"
fi

# ── Test 9: docs: title + docs/** only → PASS (CREDIBLE-038) ─────────────────
REPO9="$TMP/repo9"
make_repo "$REPO9"
mkdir -p "$REPO9/docs/process"
printf 'some doc\n' > "$REPO9/docs/process/GUIDE.md"
git -C "$REPO9" add docs/
git -C "$REPO9" commit -q -m "chore: initial"
git -C "$REPO9" checkout -q -b feature
printf 'updated doc\n' > "$REPO9/docs/process/GUIDE.md"
git -C "$REPO9" add docs/
git -C "$REPO9" commit -q -m "docs: update process guide"

out="$(cd "$REPO9" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "out-of-scope\|promises narrow scope\|title prefix.*promises"; then
    fail "Test 9: docs: title with only docs/** should PASS rule C: $out"
else
    pass "Test 9: docs: title with docs/ only passes rule C"
fi

# ── Test 10: docs: title + scripts/* → FAIL (CREDIBLE-038) ──────────────────
REPO10="$TMP/repo10"
make_repo "$REPO10"
mkdir -p "$REPO10/docs" "$REPO10/scripts"
printf 'readme\n' > "$REPO10/docs/README.md"
printf 'echo hi\n' > "$REPO10/scripts/helper.sh"
git -C "$REPO10" add docs/ scripts/
git -C "$REPO10" commit -q -m "chore: initial"
git -C "$REPO10" checkout -q -b feature
printf 'readme updated\n' > "$REPO10/docs/README.md"
printf 'echo updated\n' > "$REPO10/scripts/helper.sh"
git -C "$REPO10" add docs/ scripts/
git -C "$REPO10" commit -q -m "docs: update readme"

out="$(cd "$REPO10" && GITHUB_BASE_REF=main bash "$GUARD" --warn-only 2>&1 || true)"
if echo "$out" | grep -q "out-of-scope\|promises narrow scope\|title prefix.*promises"; then
    pass "Test 10: docs: title + scripts/* triggers rule C violation"
else
    fail "Test 10: should detect out-of-scope scripts/helper.sh under docs: title: $out"
fi

echo ""
echo "All CREDIBLE-027/CREDIBLE-038 mass-deletion guard checks passed."
