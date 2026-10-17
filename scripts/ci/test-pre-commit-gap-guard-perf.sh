#!/usr/bin/env bash
# test-pre-commit-gap-guard-perf.sh — INFRA-8211.
#
# The pre-commit gap guards reconstruct the whole gap set as one monolithic
# YAML string at the index and a base ref (to diff title/status/description
# across the set). The historical code did one `git show <ref>:<path>`
# subprocess PER docs/gaps/*.yaml file — 4,000+ process spawns per call,
# several calls per commit, so a one-line gap edit took ~40s on a fast box
# and minutes on the 4-core node. INFRA-8211 batched that into a single
# `git cat-file --batch` read keyed on the blob OIDs the file listing
# already carries (scripts/git-hooks/lib/gaps_text.py).
#
# Three guarantees:
#   1. BEHAVIOUR — gaps_text() output is byte-identical to the old
#      one-git-show-per-file loop, at both the index (ref=None) and a ref,
#      AND the fallback paths return "" without crashing. Proven on a small
#      fixture (fast; parsing is file-count-independent).
#   2. PERFORMANCE — the batched whole-tree read stays well under budget on
#      a 4,000-gap repo.
#   3. END-TO-END — the REAL pre-commit hook, on a one-line gap edit in a
#      4,000-gap repo, finishes under a 10s budget (the regression this gap
#      fixes). Fails loudly if it creeps back toward minutes.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-8211 pre-commit gap-guard perf + behaviour ==="
echo

# Isolate from any caller-set git env (self-hosted-runner leak class).
unset GIT_WORK_TREE GIT_DIR GIT_COMMON_DIR GIT_INDEX_FILE

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MODULE="$REPO_ROOT/scripts/git-hooks/lib/gaps_text.py"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"
[[ -f "$MODULE" ]] || { echo "FATAL: helper not found: $MODULE"; exit 2; }
[[ -f "$HOOK"   ]] || { echo "FATAL: hook not found: $HOOK";    exit 2; }

N_GAPS="${CHUMP_PERF_TEST_GAPS:-4000}"   # task-fixed fixture size for timing
BUDGET_S="${CHUMP_PERF_TEST_BUDGET_S:-10}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# seed_repo <repo-dir> <n-gaps> — N gap files committed, then a one-line edit
# to one gap staged so the index diverges from HEAD (the real scenario).
seed_repo() {
    local dir="$1" n="$2"
    mkdir -p "$dir/docs/gaps"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    python3 - "$dir" "$n" <<'PY'
import sys, os
root, n = sys.argv[1], int(sys.argv[2])
d = os.path.join(root, "docs", "gaps")
for i in range(n):
    with open(os.path.join(d, f"INFRA-{i:05d}.yaml"), "w") as f:
        f.write(
            f"- id: INFRA-{i:05d}\n"
            f"  title: synthetic gap {i}\n"
            f"  status: open\n"
            f"  priority: P2\n"
            f"  acceptance_criteria:\n    - does a thing\n"
            f"  description: |\n    body for gap {i}\n"
        )
PY
    git -C "$dir" add -A
    git -C "$dir" commit -qm "seed $n gaps"
    # Portable one-line edit (BSD/GNU `sed -i` differ on the backup-suffix arg).
    python3 - "$dir/docs/gaps/INFRA-00007.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("title: synthetic gap 7\n", "title: synthetic gap 7 edited\n")
open(p, "w").write(s)
PY
    git -C "$dir" add "docs/gaps/INFRA-00007.yaml"
}

# ── 1. BEHAVIOUR (small fixture; parsing cost is file-count-independent) ─────
SMALL="$TMP/small"
seed_repo "$SMALL" 40
BEHAVIOUR="$(cd "$SMALL" && MODULE="$MODULE" python3 - <<'PY'
import os, sys, subprocess, importlib.util
spec = importlib.util.spec_from_file_location("gaps_text", os.environ["MODULE"])
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)

def old(ref=None):
    """The pre-INFRA-8211 one-git-show-per-file implementation, verbatim."""
    prefix = f"{ref}:" if ref else ":"
    cmd = (["git", "ls-files", "--cached", "docs/gaps/"] if ref is None
           else ["git", "ls-tree", "--name-only", "-r", ref, "docs/gaps/"])
    files = sorted(f for f in subprocess.check_output(cmd, text=True).splitlines()
                   if f.endswith(".yaml"))
    parts = [subprocess.check_output(["git", "show", f"{prefix}{f}"], text=True).rstrip()
             for f in files]
    return "gaps:\n" + "\n".join(parts) + "\n"

match = all(old(ref) == G.gaps_text(ref) for ref in (None, "HEAD"))
fb_ok = (G.gaps_text("definitely-not-a-ref") == "")
print(f"MATCH={'1' if match else '0'}")
print(f"FALLBACK={'1' if fb_ok else '0'}")
PY
)"
echo "$BEHAVIOUR" | grep -q "^MATCH=1"    && ok "gaps_text byte-identical to old per-file loop (index + ref)" \
                                          || fail "gaps_text output diverges from old per-file loop"
echo "$BEHAVIOUR" | grep -q "^FALLBACK=1" && ok "missing-ref / empty-tree falls back to \"\" without crashing" \
                                          || fail "fallback path crashed or returned non-empty"

# ── 2 + 3. PERFORMANCE + END-TO-END (4,000-gap fixture) ──────────────────────
echo "  seeding $N_GAPS gap files…"
BIG="$TMP/big"
seed_repo "$BIG" "$N_GAPS"

# Batched whole-tree read cost at both refs (the guard does up to 3 per commit).
PERF="$(cd "$BIG" && MODULE="$MODULE" BUDGET_S="$BUDGET_S" python3 - <<'PY'
import os, sys, time, importlib.util
spec = importlib.util.spec_from_file_location("gaps_text", os.environ["MODULE"])
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)
budget = float(os.environ["BUDGET_S"]) / 3.0   # up to 3 reads per commit
worst = 0.0
for ref in (None, "HEAD"):
    t = time.time(); txt = G.gaps_text(ref); dt = time.time() - t
    worst = max(worst, dt)
    print(f"INFO ref={ref!r} bytes={len(txt)} batched={dt:.2f}s", file=sys.stderr)
print(f"PERF={'1' if worst <= budget else '0'}")
print(f"WORST={worst:.2f}")
print(f"PERCALL_BUDGET={budget:.2f}")
PY
)"
if echo "$PERF" | grep -q "^PERF=1"; then
    ok "batched whole-tree read under per-call budget (worst $(echo "$PERF" | sed -n 's/^WORST=/~/p')s of $(echo "$PERF" | sed -n 's/^PERCALL_BUDGET=/~/p')s)"
else
    fail "a batched whole-tree read exceeded the per-call budget — batching regressed"
fi

# The headline regression: time the REAL pre-commit hook on the one-line edit.
# Other sub-hooks it sources are optional (`[ -r ]`/`[ -x ]` guarded) and skip
# when absent; `timeout` caps a pathological hang so the test fails loudly.
# The hook's exit code is irrelevant — we only measure wall-clock.
mkdir -p "$BIG/scripts/git-hooks/lib"
cp "$HOOK" "$BIG/.git/hooks/pre-commit"
cp "$MODULE" "$BIG/scripts/git-hooks/lib/gaps_text.py"
chmod +x "$BIG/.git/hooks/pre-commit"
hook_t0=$(date +%s.%N)
( cd "$BIG" && timeout "$BUDGET_S" bash .git/hooks/pre-commit ) >/dev/null 2>&1
hook_rc=$?
hook_t1=$(date +%s.%N)
HOOK_S=$(awk "BEGIN{printf \"%.2f\", $hook_t1-$hook_t0}")
if [[ "$hook_rc" -eq 124 ]]; then
    fail "pre-commit hook exceeded ${BUDGET_S}s budget on a one-line gap edit (timed out)"
elif awk "BEGIN{exit !($HOOK_S > $BUDGET_S)}"; then
    fail "pre-commit hook took ${HOOK_S}s (> ${BUDGET_S}s budget) on a one-line gap edit"
else
    ok "real pre-commit hook ran in ${HOOK_S}s (< ${BUDGET_S}s budget) on a one-line gap edit ($N_GAPS gaps)"
fi

echo
echo "=== results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILS[@]}" >&2
    exit 1
fi
exit 0
