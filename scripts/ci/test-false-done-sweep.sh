#!/usr/bin/env bash
# scripts/ci/test-false-done-sweep.sh — CREDIBLE-336
#
# Regression test for scripts/ops/false-done-sweep.py's BOOKKEEPING tier: a
# closing PR whose diff contains zero implementation files cannot have shipped
# the work it is credited with (see the module docstring for the full case).
#
# Fixture-based: constructs a docs-only file list and a file list containing
# a .rs implementation file, then asserts the classification each produces
# against the exact function main() uses (is_implementation), not a re-
# implementation of the logic.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/ops/false-done-sweep.py"

# CREDIBLE-1087 — grep-target-sweep mode: walks scripts/ci, finds `grep`
# invocations whose path argument names a file that doesn't exist (a
# "vacuous grep" — it can never match anything), and reports them. This is
# a slice of CREDIBLE-274 (false-done detection generalized to CI scripts
# that silently no-op because their target never existed).
case "${1:-}" in
  grep-target-sweep)
    cd "$REPO_ROOT"
    count=0
    findings=""
    while IFS= read -r -d '' f; do
      rel="${f#"$REPO_ROOT"/}"
      lineno=0
      while IFS= read -r line; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"|"* ]] && continue
        [[ "$line" == *grep* ]] || continue
        # Only the unambiguous single-shot form counts: grep <bool-flags>
        # <quoted pattern> <target> <clause end>. Requiring a quoted pattern
        # before the target keeps a grep's own search text (which often
        # contains path-shaped substrings) from being mistaken for its
        # target argument.
        target="$(grep -oP '\bgrep\s+(?:-[qniEFvwrlxcoPs]+\s+)*(?:"[^"]*"|'"'"'[^'"'"']*'"'"')\s+\K(?:"[^"$]*"|'"'"'[^'"'"'$]*'"'"'|[A-Za-z0-9_./-]+)(?=\s*(?:;|\)|&&|\|\||#|$|2>))' <<<"$line" | tail -1)"
        target="${target%\"}"; target="${target#\"}"
        target="${target%\'}"; target="${target#\'}"
        [[ "$target" == */*.* || "$target" =~ \.[A-Za-z0-9]+$ ]] || continue
        [[ "$target" == \$* || "$target" == -* ]] && continue
        [[ -e "$REPO_ROOT/$target" ]] && continue
        count=$((count + 1))
        findings+="${rel}:${lineno} – ${target}"$'\n'
      done < "$f"
    done < <(find "$REPO_ROOT/scripts/ci" -type f \( -name '*.sh' -o -name '*.py' \) -print0 | sort -z)
    echo "Vacuous grep count: $count"
    [[ -n "$findings" ]] && printf '%s' "$findings"
    exit 0
    ;;
esac

echo "=== CREDIBLE-336 false-done-sweep.py tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "script is executable" || fail "script is not executable"

RESULT="$(
  cd "$REPO_ROOT" && python3 - "$TARGET" <<'PYEOF'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("false_done_sweep", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Fixture PR touching only docs/gaps/*.yaml — must classify as BOOKKEEPING
# (no file in the diff is an implementation file).
docs_only = ["docs/gaps/CREDIBLE-999.yaml", "docs/gaps/CREDIBLE-1000.yaml"]
is_bookkeeping_docs_only = not any(mod.is_implementation(f) for f in docs_only)

# Fixture PR containing a .rs implementation file — must NOT classify as
# BOOKKEEPING (the diff shipped at least one implementation file).
with_rs = ["docs/gaps/CREDIBLE-999.yaml", "src/foo.rs"]
is_bookkeeping_with_rs = not any(mod.is_implementation(f) for f in with_rs)

print("docs_only_bookkeeping=%s" % is_bookkeeping_docs_only)
print("with_rs_bookkeeping=%s" % is_bookkeeping_with_rs)
PYEOF
)"

echo "$RESULT" | grep -q "^docs_only_bookkeeping=True$" \
  && ok "docs/gaps/*.yaml-only fixture classified BOOKKEEPING" \
  || fail "docs/gaps/*.yaml-only fixture NOT classified BOOKKEEPING"

echo "$RESULT" | grep -q "^with_rs_bookkeeping=False$" \
  && ok "fixture with a .rs file NOT classified BOOKKEEPING" \
  || fail "fixture with a .rs file wrongly classified BOOKKEEPING"

python3 -m py_compile "$TARGET" \
  && ok "script compiles" \
  || fail "script fails to compile"

# --- End-to-end: --multi-close-only --json against a controlled fixture ---
# The unit tests above only exercise is_implementation() in isolation. This
# drives the real CLI (argument parsing, multi-close grouping, JSON shape)
# against fake `chump`/`gh` binaries so the assertion is deterministic —
# unlike live registry counts, which drift as the fleet ships more PRs.
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/bin"
cat > "$FIXTURE_DIR/bin/chump" <<'FAKE_CHUMP'
#!/usr/bin/env bash
# Fixture: 4 done gaps closed by PR 1001 (bookkeeping — docs/gaps/*.yaml only,
# 3 gaps, meets --multi-threshold 3) and PR 1002 (2 gaps, below threshold, and
# one PR 1003 gap with a real implementation file so it is NOT bookkeeping).
cat <<'JSON'
[
  {"id": "FIX-1", "status": "done", "closed_pr": 1001, "priority": "P1", "title": "one"},
  {"id": "FIX-2", "status": "done", "closed_pr": 1001, "priority": "P2", "title": "two"},
  {"id": "FIX-3", "status": "done", "closed_pr": 1001, "priority": "P2", "title": "three"},
  {"id": "FIX-4", "status": "done", "closed_pr": 1002, "priority": "P2", "title": "four"},
  {"id": "FIX-5", "status": "done", "closed_pr": 1003, "priority": "P1", "title": "five, src/foo.rs"}
]
JSON
FAKE_CHUMP
chmod +x "$FIXTURE_DIR/bin/chump"

cat > "$FIXTURE_DIR/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# args: pr view <N> --repo ... --json files
pr="$3"
case "$pr" in
  1001) echo '{"files":[{"path":"docs/gaps/FIX-1.yaml"},{"path":"docs/gaps/FIX-2.yaml"},{"path":"docs/gaps/FIX-3.yaml"}]}' ;;
  1002) echo '{"files":[{"path":"docs/gaps/FIX-4.yaml"}]}' ;;
  1003) echo '{"files":[{"path":"src/foo.rs"}]}' ;;
  *) echo '{"files":[]}' ;;
esac
FAKE_GH
chmod +x "$FIXTURE_DIR/bin/gh"

FIXTURE_JSON="$(
  cd "$REPO_ROOT" && HOME="$FIXTURE_DIR" PATH="$FIXTURE_DIR/bin:$PATH" \
    python3 scripts/ops/false-done-sweep.py --multi-close-only --json
)"
FIXTURE_EXIT=$?

[[ $FIXTURE_EXIT -eq 0 ]] && ok "CLI exits 0 on success" || fail "CLI exited $FIXTURE_EXIT"

echo "$FIXTURE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['examined'] == 3, f\"expected 3 gaps examined (only PR 1001 clears the multi-close threshold), got {d['examined']}\"
assert len(d['bookkeeping_closed']) == 3, f\"expected 3 bookkeeping-closed gaps, got {len(d['bookkeeping_closed'])}\"
ids = sorted(b['gap'] for b in d['bookkeeping_closed'])
assert ids == ['FIX-1', 'FIX-2', 'FIX-3'], f'unexpected gap ids: {ids}'
assert d['bookkeeping_closed'][0]['pr'] == 1001
print('shape_ok=True')
" && ok "--multi-close-only --json groups by PR and reports bookkeeping tier correctly" \
  || fail "--multi-close-only --json output did not match the fixture"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
