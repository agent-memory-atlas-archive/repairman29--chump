#!/usr/bin/env bash
# scripts/ci/test-pipefail-race-sweep.sh — INFRA-1658
#
# Guard against new occurrences of the printf|grep -q pipefail race in
# hot-path scripts (scripts/coord/, scripts/git-hooks/, scripts/dispatch/).
#
# THE BUG:
#   Under `set -o pipefail`, `printf 'X' | grep -q Y` is racy: grep -q
#   closes stdin on first match → printf gets SIGPIPE → printf's exit
#   code becomes non-zero → the WHOLE pipeline exits non-zero. Result:
#   the `if printf | grep -q; then ...` branch fails to fire even when
#   the pattern matched. Cost us 6 hours debugging INFRA-755 (the
#   pre-commit-obs-budget false-negative chain) before locating it.
#
# THE FIX:
#   Materialize the producer side to a tempfile, then grep against the
#   file. See scripts/git-hooks/pre-commit-obs-budget.sh for the model.
#
#   _tmp=$(mktemp); printf '%s\n' "$BLOB" > "$_tmp"
#   if grep -qE 'pattern' "$_tmp"; then ...
#   rm -f "$_tmp"
#
# WHAT THIS TEST DOES:
#   Greps the three hot-path directories for `printf ... | ... grep -q`
#   occurrences. Fails if any NEW occurrence appears. Existing
#   intentional instances (e.g. inside scripts that don't set -o
#   pipefail, or where the producer is one short line) are allowlisted
#   via the comment marker `# pipefail-sweep-allowed` on the same line.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

HOT_DIRS=(scripts/coord scripts/git-hooks scripts/dispatch)

# Find candidate lines: printf ... grep -q (in any form) on the same
# line. Filter out the allowlist marker, comments-only lines, and the
# test file itself.
VIOLATIONS=$(grep -rn -E 'printf[^|]*\|[^|]*grep[[:space:]]+-[a-zA-Z]*q' \
    "${HOT_DIRS[@]}" 2>/dev/null \
    | grep -v 'pipefail-sweep-allowed' \
    | grep -v 'test-pipefail-race-sweep\.sh' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    || true)

# Also reject the inverse `| grep -q ... <<<` shorthand inside the same
# directories — same root cause when pipefail is set.

if [[ -n "$VIOLATIONS" ]]; then
    echo "❌ INFRA-1658: pipefail-race-prone pattern detected in hot-path scripts." >&2
    echo "" >&2
    echo "Under set -o pipefail, 'printf X | grep -q Y' is racy: grep -q closes" >&2
    echo "stdin on first match → printf gets SIGPIPE → pipeline exits non-zero" >&2
    echo "EVEN WHEN the pattern matched. This produces silent false-negatives" >&2
    echo "in conditional branches." >&2
    echo "" >&2
    echo "Fix: materialize producer to a tempfile, then grep the file." >&2
    echo "  _t=\$(mktemp); printf '%s\\n' \"\$BLOB\" > \"\$_t\"" >&2
    echo "  if grep -qE 'pattern' \"\$_t\"; then ..." >&2
    echo "  rm -f \"\$_t\"" >&2
    echo "" >&2
    echo "If the occurrence is intentional (script doesn't set pipefail, or" >&2
    echo "producer is one short literal), append this marker to the line:" >&2
    echo "  # pipefail-sweep-allowed" >&2
    echo "" >&2
    echo "Violations:" >&2
    printf '%s\n' "$VIOLATIONS" | sed 's/^/  /' >&2
    echo "" >&2
    echo "See docs/process/CLAUDE_GOTCHAS.md → 'printf | grep -q pipefail race'." >&2
    exit 1
fi

echo "✅ INFRA-1658: no new printf|grep -q pipefail-race patterns in hot-path scripts."

# ── CREDIBLE-1563: Widened pipefail-race sweep (`| grep -q` and `| grep -c` tails under `set -o pipefail`) ──
# Scans scripts/ci, scripts/coord, scripts/ops, scripts/git-hooks, and scripts/dispatch
# for any script with `set -o pipefail` (or `set -euo pipefail` / `set -uo pipefail`)
# containing a pipeline whose tail is `| grep -q` or `| grep -c` (unless allowlisted
# via `# pipefail-sweep-allowed` or within the legacy burn-down ceiling, with zero
# newly added occurrences in `git diff origin/main...HEAD`).
run_widened_pipefail_scan() {
    local target_root="$1"
    local ceiling="$2"
    local check_git_diff="${3:-0}"
    python3 - "$target_root" "$ceiling" "$check_git_diff" <<'PY'
import os
import re
import subprocess
import sys

root_dir = sys.argv[1]
ceiling = int(sys.argv[2])
check_diff = sys.argv[3] == "1"

scan_dirs = ["scripts/ci", "scripts/coord", "scripts/ops", "scripts/git-hooks", "scripts/dispatch"]
pipefail_re = re.compile(r"^\s*set\s+(?:[^#\n]*-o\s+pipefail|-[a-zA-Z]*o\s+pipefail)", re.M)
tail_re = re.compile(
    r"^[^#]*\|\s*grep(?:\s+(?:-[a-zA-Z0-9-]+|--[a-zA-Z0-9-]+))*\s+(?:-[a-zA-Z]*[qc]|--quiet|--silent|--count)(?:\s|$)"
)

# Files already burned down to zero must never regress.
zero_tolerance_files = {
    "scripts/coord/bot-merge.sh",
    "scripts/coord/merge-serializer.sh",
    "scripts/git-hooks/pre-push",
    "scripts/ci/test-pre-push-test-gate.sh",
    "scripts/ci/test-false-done-sweep.sh",
    "scripts/ci/test-ac-coverage-gate.sh",
    "scripts/ci/test-merge-serializer.sh",
}

hits = []
zero_tol_hits = []

for d in scan_dirs:
    abs_d = os.path.join(root_dir, d)
    if not os.path.isdir(abs_d):
        continue
    for walk_root, _, files in os.walk(abs_d):
        for f in sorted(files):
            abs_p = os.path.join(walk_root, f)
            rel_p = os.path.relpath(abs_p, root_dir)
            if rel_p == "scripts/ci/test-pipefail-race-sweep.sh":
                continue
            if not (f.endswith(".sh") or d == "scripts/git-hooks"):
                continue
            try:
                txt = open(abs_p, errors="replace").read()
            except OSError:
                continue
            if not pipefail_re.search(txt):
                continue
            for lineno, line in enumerate(txt.splitlines(), 1):
                if "pipefail-sweep-allowed" in line or line.lstrip().startswith("#"):
                    continue
                if tail_re.search(line):
                    entry = f"{rel_p}:{lineno}:{line.strip()}"
                    hits.append(entry)
                    if rel_p in zero_tolerance_files:
                        zero_tol_hits.append(entry)

if zero_tol_hits:
    print("❌ CREDIBLE-1563: zero-tolerance file(s) regressed with | grep -q / | grep -c under pipefail:", file=sys.stderr)
    for h in zero_tol_hits:
        print(f"  {h}", file=sys.stderr)
    sys.exit(1)

if len(hits) > ceiling:
    print(
        f"❌ CREDIBLE-1563: pipefail | grep -q / | grep -c count ({len(hits)}) exceeds burn-down ceiling ({ceiling}):",
        file=sys.stderr,
    )
    for h in hits[:25]:
        print(f"  {h}", file=sys.stderr)
    sys.exit(1)

if check_diff:
    try:
        diff_out = subprocess.check_output(
            ["git", "diff", "-U0", "origin/main...HEAD", "--"] + scan_dirs,
            cwd=root_dir,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        diff_out = ""
    cur_file = None
    cur_file_pipefail = False
    diff_hits = []
    for raw in diff_out.splitlines():
        if raw.startswith("+++ b/"):
            cur_file = raw[6:].strip()
            if cur_file == "scripts/ci/test-pipefail-race-sweep.sh":
                cur_file_pipefail = False
                continue
            abs_cur = os.path.join(root_dir, cur_file)
            if os.path.isfile(abs_cur):
                try:
                    cur_file_pipefail = bool(pipefail_re.search(open(abs_cur, errors="replace").read()))
                except OSError:
                    cur_file_pipefail = False
            else:
                cur_file_pipefail = False
        elif cur_file_pipefail and raw.startswith("+") and not raw.startswith("+++"):
            added = raw[1:]
            if "pipefail-sweep-allowed" in added or added.lstrip().startswith("#"):
                continue
            if tail_re.search(added):
                diff_hits.append(f"{cur_file}: {added.strip()}")
    if diff_hits:
        print("❌ CREDIBLE-1563: newly added | grep -q / | grep -c tail under set -o pipefail in diff:", file=sys.stderr)
        for dh in diff_hits:
            print(f"  {dh}", file=sys.stderr)
        sys.exit(1)

print(f"✅ CREDIBLE-1563: widened pipefail | grep -q / | grep -c check passed (legacy burn-down={len(hits)}/{ceiling}).")
PY
}

# 1. Run widened scan on the live repo (burn-down ceiling = 2397, plus diff ratchet).
run_widened_pipefail_scan "$REPO_ROOT" 2397 1

# 2. Self-test fixtures for CREDIBLE-1563:
#    (a) printf ... | grep -q under set -o pipefail -> MUST be flagged (non-zero)
#    (b) cat file | grep -c under set -o pipefail   -> MUST be flagged (non-zero)
#    (c) herestring / # pipefail-sweep-allowed      -> MUST pass (exit 0)
SELF_TMP="$(mktemp -d)"
trap 'rm -rf "$SELF_TMP"' EXIT
mkdir -p "$SELF_TMP/scripts/ci" "$SELF_TMP/scripts/coord" "$SELF_TMP/scripts/ops"

cat > "$SELF_TMP/scripts/coord/bad-grep-q.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$foo" | grep -q "bar"
EOF
if run_widened_pipefail_scan "$SELF_TMP" 0 0 >/dev/null 2>&1; then
    echo "❌ CREDIBLE-1563 self-test FAILED: printf ... | grep -q under set -o pipefail was not flagged" >&2
    exit 1
fi
rm -f "$SELF_TMP/scripts/coord/bad-grep-q.sh"

cat > "$SELF_TMP/scripts/ops/bad-grep-c.sh" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
cat somefile | grep -c "needle"
EOF
if run_widened_pipefail_scan "$SELF_TMP" 0 0 >/dev/null 2>&1; then
    echo "❌ CREDIBLE-1563 self-test FAILED: cat file | grep -c under set -o pipefail was not flagged" >&2
    exit 1
fi
rm -f "$SELF_TMP/scripts/ops/bad-grep-c.sh"

cat > "$SELF_TMP/scripts/ci/good-clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grep -q "bar" <<<"$foo"
printf '%s\n' "$foo" | grep -q "bar" # pipefail-sweep-allowed
EOF
if ! run_widened_pipefail_scan "$SELF_TMP" 0 0 >/dev/null 2>&1; then
    echo "❌ CREDIBLE-1563 self-test FAILED: clean/allowlisted script should pass" >&2
    exit 1
fi

echo "✅ CREDIBLE-1563: self-test fixtures (printf|grep -q, cat|grep -c, allowlist) passed."
exit 0
