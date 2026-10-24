#!/usr/bin/env bash
# test-ci-verified-shape.sh — CREDIBLE-1554 (PHASE-R R7), item 2
#
# PyYAML ci.yml-shape test for the sole required `verified` job. Pins the
# WIRING that #5602 claimed but did not contain: the fix-forward replaced the
# verified job's poll(120s)+aggregate-once step pair with a single
# `bash scripts/ci/verified-wait.sh` step and raised timeout-minutes to 95.
# A comment-only edit (as #5602 shipped) leaves the verified job byte-identical,
# so this test parses the REAL structure and fails if the wiring regresses.
#
# Asserts, against .github/workflows/ci.yml's `verified` job:
#   1. some step's `run:` invokes `scripts/ci/verified-wait.sh`
#   2. that run passes BOTH cross lanes:
#        --cross "audit"
#        --cross "ACP protocol smoke test (Zed / JetBrains compatible)"
#   3. timeout-minutes >= 91 (the in-job wait is 90 min; the runner must outlive it)
#   4. the stale poll/aggregate pair is GONE — no direct
#      poll-cross-workflow-checks.sh or aggregator-verified.sh call, and no
#      `--timeout-s 120` grace window — so verified can only reach its verdict
#      through the wait loop.
#
# CREDIBLE-1554 item 2 tightens the binding against the reviewer's Mutant B (an
# `if:` on the wait step + a dispatch-only step without --cross) by reading the
# STRUCTURE per-step, not a joined run blob:
#   5. EXACTLY ONE step in verified runs verified-wait.sh (a 2nd call FAILs);
#   6. NO step in verified has a step-level `if:` (the binding is unconditional;
#      the job-level `if: always()` is not a step and is unaffected);
#   7. the call's --lane names EQUAL the job's needs: (all six);
#   8. the --cross set is EXACTLY {audit, ACP smoke};
#   9. the call passes NO --timeout-s (the per-event budget resolves from
#      --event-name inside verified-wait.sh);
#  10. the call's only ${{ }} expressions are needs.*.result + the sha/pr/
#      event_name inputs — nothing else drives the wait.
#
# CREDIBLE-1554 repair 5 (architect review 6273863218) closes the last hole:
#  11. the call carries EXACTLY ONE --event-name, ONE --sha and ONE --pr flag of
#      ANY value (the live-expression counts only counted the RIGHT value, and
#      verified-wait.sh's parser kept the LAST one, so a 2nd
#      `--event-name "workflow_dispatch"` handed merge_group the 300s window);
#  12. the wait step's run: is a SINGLE command: after joining `\`-continuations
#      it is one logical line of the exact form
#        bash scripts/ci/verified-wait.sh --flag "value" [--flag "value" ...]
#      so no second command (a `;`-chained one, or a new line that runs the
#      script through a variable, `W=...; bash "$W.sh"`) can hide in the step.
#  Mutant self-test: after the real ci.yml passes, the script re-runs itself
#  against deliberately broken copies of ci.yml (MUTANTS at the bottom) and
#  FAILs unless EVERY mutant is rejected, so a guard that stops biting is caught.
#
# Usage:
#   bash scripts/ci/test-ci-verified-shape.sh
#   CI_YML=path/to/ci.yml bash scripts/ci/test-ci-verified-shape.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CI_YML="${CI_YML:-$REPO_ROOT/.github/workflows/ci.yml}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required for ci.yml-shape parse" >&2
  exit 2
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FATAL: PyYAML required (pip install pyyaml) — see scripts/ci/test-precommit-pyyaml-required.sh" >&2
  exit 2
fi
[[ -f "$CI_YML" ]] || { echo "FAIL: ci.yml not found at $CI_YML" >&2; exit 1; }

CI_YML="$CI_YML" python3 <<'PY'
import os, sys, yaml

ci_yml = os.environ["CI_YML"]
with open(ci_yml) as f:
    data = yaml.safe_load(f)

jobs = data.get("jobs", {})
if "verified" not in jobs:
    print("FAIL: no `verified` job in ci.yml", file=sys.stderr)
    sys.exit(1)
v = jobs["verified"]

fail = 0
def ok(msg):  print(f"PASS: {msg}")
def bad(msg):
    global fail
    print(f"FAIL: {msg}", file=sys.stderr); fail = 1

run_blob = "\n".join(s.get("run", "") for s in v.get("steps", []) if isinstance(s, dict))

# 1. verified-wait.sh is wired in.
if "scripts/ci/verified-wait.sh" in run_blob:
    ok("verified job runs scripts/ci/verified-wait.sh")
else:
    bad("verified job does not call scripts/ci/verified-wait.sh (was it comment-only, like #5602?)")

# 2. both cross lanes present.
if '--cross "audit"' in run_blob:
    ok('verified-wait call passes --cross "audit"')
else:
    bad('verified-wait call missing --cross "audit"')
acp = '--cross "ACP protocol smoke test (Zed / JetBrains compatible)"'
if acp in run_blob:
    ok("verified-wait call passes the ACP smoke --cross lane")
else:
    bad("verified-wait call missing the ACP smoke --cross lane")

# 3. timeout-minutes >= 91 (wait is 90 min).
tm = v.get("timeout-minutes")
if isinstance(tm, int) and tm >= 91:
    ok(f"timeout-minutes is {tm} (>= 91, outlives the 90-min in-job wait)")
else:
    bad(f"timeout-minutes is {tm!r}; must be an int >= 91 so the runner outlives the 90-min wait")

# 4. the stale poll+aggregate pair is gone.
if "poll-cross-workflow-checks.sh" in run_blob:
    bad("verified job still calls poll-cross-workflow-checks.sh directly — the wait loop owns cross polling now")
else:
    ok("no direct poll-cross-workflow-checks.sh call in verified")
if "aggregator-verified.sh" in run_blob:
    bad("verified job still calls aggregator-verified.sh directly — the wait loop owns aggregation now")
else:
    ok("no direct aggregator-verified.sh call in verified")
if "--timeout-s 120" in run_blob:
    bad("stale 120s grace window still present in verified")
else:
    ok("no stale --timeout-s 120 grace window in verified")

# ── CREDIBLE-1554 item 2: tighten the binding so its mutants cannot pass ──────
# The reviewer's Mutant B (an `if:` on the wait step + a dispatch-only step
# without --cross) slipped past the join-every-run-into-one-string checks above.
# These assertions read the STRUCTURE (per-step), not a joined blob.
import re

steps = [s for s in v.get("steps", []) if isinstance(s, dict)]

# 5. EXACTLY ONE step runs verified-wait.sh (Mutant B adds a 2nd dispatch-only
#    step → count 2 → FAIL). The verdict must flow through a single call site.
wait_steps = [s for s in steps if "scripts/ci/verified-wait.sh" in s.get("run", "")]
if len(wait_steps) == 1:
    ok("exactly one step in verified runs verified-wait.sh")
else:
    bad(f"expected exactly one verified-wait.sh step in verified, found {len(wait_steps)}")

# 6. NO step in verified has a step-level `if:` (Mutant B puts
#    `if: github.event_name != 'workflow_dispatch'` on the wait step → FAIL).
#    The job-level `if: always()` (v["if"]) is NOT a step and is unaffected.
steps_with_if = [s for s in steps if "if" in s]
if not steps_with_if:
    ok("no step in verified has a step-level `if:` (the lane set is unconditional)")
else:
    bad(f"{len(steps_with_if)} step(s) in verified carry a step-level `if:` — the binding must be unconditional for every event")

# Parse the single verified-wait call's run for the remaining assertions. If
# there is not exactly one, the assertions above already failed; guard anyway.
wait_run = wait_steps[0].get("run", "") if wait_steps else ""

# 7. The --lane names equal the job's needs: (all six). A lane added/dropped vs
#    needs means a local lane goes unclassified or a phantom lane is waited on.
lane_names = set(re.findall(r'--lane\s+"([^="]+)=', wait_run))
needs = v.get("needs", [])
needs_set = set(needs) if isinstance(needs, list) else {needs}
if lane_names == needs_set:
    ok(f"verified-wait --lane names equal the job's needs: ({sorted(needs_set)})")
else:
    bad(f"--lane names {sorted(lane_names)} != job needs: {sorted(needs_set)} "
        f"(missing: {sorted(needs_set - lane_names)}; extra: {sorted(lane_names - needs_set)})")

# 8. The --cross set is EXACTLY {audit, ACP smoke} — no more, no fewer.
cross_set = set(re.findall(r'--cross\s+"([^"]+)"', wait_run))
expect_cross = {"audit", "ACP protocol smoke test (Zed / JetBrains compatible)"}
if cross_set == expect_cross:
    ok("verified-wait --cross set is exactly {audit, ACP smoke}")
else:
    bad(f"--cross set {sorted(cross_set)} != expected {sorted(expect_cross)} "
        f"(missing: {sorted(expect_cross - cross_set)}; extra: {sorted(cross_set - expect_cross)})")

# 9. The call passes NO --timeout-s at all (the per-event budget is resolved
#    inside verified-wait.sh from --event-name; a hard-coded --timeout-s would
#    override the budget and could shrink the pull_request/merge_group window).
if re.search(r'--timeout-s\b', wait_run):
    bad("verified-wait call passes --timeout-s — the per-event budget must resolve from --event-name, not a hard-coded flag")
else:
    ok("verified-wait call passes no --timeout-s (per-event budget resolves from --event-name)")

# 10. The call's only ${{ }} expressions are needs.*.result and the
#     sha/pr/event_name inputs — nothing else drives the wait. A stray expression
#     (e.g. a Mutant-B-style `if:` condition smuggled into the run, or an
#     event-name-switched arg) would show up here.
exprs = [e.strip() for e in re.findall(r'\$\{\{(.*?)\}\}', wait_run)]
allowed_exact = {
    "github.event.pull_request.head.sha || github.sha",  # --sha input
    "github.event.pull_request.number",                  # --pr input
    "github.event_name",                                 # --event-name input
}
bad_exprs = []
for e in exprs:
    norm = " ".join(e.split())
    if re.fullmatch(r"needs\.[A-Za-z0-9_-]+\.result", norm):
        continue
    if norm in allowed_exact:
        continue
    bad_exprs.append(norm)
if not bad_exprs:
    ok(f"verified-wait run uses only needs.*.result + sha/pr/event_name expressions ({len(exprs)} total)")
else:
    bad(f"verified-wait run has disallowed ${{{{ }}}} expression(s): {bad_exprs}")

# ── CREDIBLE-1554 delta item 1: pin the live event-name/sha/pr expressions ────
# Assertion 10 only rejects DISALLOWED expressions; it does not REQUIRE the live
# ones to be present. So hard-coding `--event-name "workflow_dispatch"` (reviewer
# Mutant C) removes the ${{ github.event_name }} expression without adding a
# disallowed one — and merge_group then borrows the 300s dispatch budget, letting
# `verified` conclude FAILURE while audit (15-40 min) is still running: the exact
# bug this gap fixes, reachable by a one-token ci.yml edit. Require each of the
# three live expressions to appear EXACTLY ONCE as its flag's value.
def count_arg(flag, value):
    # matches the literal `--flag "value"` (value treated as a literal, incl. ${{ }})
    return len(re.findall(r'--' + re.escape(flag) + r'\s+"' + re.escape(value) + r'"', wait_run))

en = count_arg("event-name", "${{ github.event_name }}")
if en == 1:
    ok('verified-wait passes --event-name "${{ github.event_name }}" exactly once')
else:
    bad(f'expected exactly one --event-name "${{{{ github.event_name }}}}", found {en} '
        "— a hard-coded --event-name lets one event borrow another's wait budget")

sha_n = count_arg("sha", "${{ github.event.pull_request.head.sha || github.sha }}")
if sha_n == 1:
    ok('verified-wait passes the live --sha expression exactly once')
else:
    bad(f'expected exactly one live --sha expression, found {sha_n}')

pr_n = count_arg("pr", "${{ github.event.pull_request.number }}")
if pr_n == 1:
    ok('verified-wait passes the live --pr expression exactly once')
else:
    bad(f'expected exactly one live --pr expression, found {pr_n}')

# ── CREDIBLE-1554 delta item 2: the wait step's run holds ONE unconditional call
# `verified-wait.sh` must appear EXACTLY ONCE in the single wait step's whole
# run: text (assertion 5 counts STEPS, so it misses a 2nd call in the SAME step),
# and the run must carry no GITHUB_EVENT_NAME reference and no shell conditional
# (if/case/&&/||). Reviewer Mutant b adds a 2nd verified-wait.sh call in the same
# step branched on $GITHUB_EVENT_NAME == merge_group without --cross — this kills
# it. Strip ${{ }} GitHub expressions before the shell-conditional scan so the
# `||` inside the --sha fallback expression is not misread as a shell OR.
vw_calls = len(re.findall(r'verified-wait\.sh', wait_run))
if vw_calls == 1:
    ok("verified-wait.sh appears exactly once in the wait step's run text")
else:
    bad(f"verified-wait.sh appears {vw_calls}x in the wait step's run — the verdict "
        "must flow through a single unconditional call, not an event-branched second call")

if "GITHUB_EVENT_NAME" in wait_run:
    bad("wait step run references GITHUB_EVENT_NAME — the event is passed via "
        "--event-name only; a shell branch on it is a second-path smell")
else:
    ok("wait step run has no GITHUB_EVENT_NAME reference")

wait_run_shell = re.sub(r'\$\{\{.*?\}\}', '', wait_run)
if re.search(r'&&|\|\||(?:^|\s)(?:if|case)\s', wait_run_shell):
    bad("wait step run contains a shell conditional (if/case/&&/||) — the single "
        "verified-wait.sh call must be unconditional for every event")
else:
    ok("wait step run has no shell conditional (if/case/&&/||)")

# ── CREDIBLE-1554 repair 5: ONE flag of ANY value + ONE command ───────────────
# 11. Count the single-valued flags by NAME, whatever their value. The counts
#     above (count_arg) only see the live expression, so `--event-name
#     "${{ github.event_name }}"` followed by `--event-name "workflow_dispatch"`
#     scored 1 there, and verified-wait.sh kept the last value. Require exactly
#     one of each (the `--flag=value` spelling is counted too).
from collections import Counter
flag_counts = Counter(re.findall(r'(?<![\w-])--([a-z][a-z-]*)', wait_run))
for flag in ("event-name", "sha", "pr"):
    n = flag_counts.get(flag, 0)
    if n == 1:
        ok(f"verified-wait call has exactly one --{flag} flag (of any value)")
    else:
        bad(f"verified-wait call has {n} --{flag} flag(s); exactly one is allowed "
            "(a repeated flag silently overrides the live value: last one wins)")

# 12. The wait step's run: is ONE command. Join `\`-newline continuations, drop
#     blank lines, and require a single logical line that is exactly
#     `bash scripts/ci/verified-wait.sh` followed only by `--flag "value"` pairs
#     (a value may hold ${{ }} expressions but no other `$`, backtick or `\`).
#     This rejects a `;`/`|`/`&` chain, a redirect, a `$(...)`, and a second
#     line that runs the script through a variable (`W=...; bash "$W.sh"`):
#     the shapes the "verified-wait.sh appears once" count cannot see.
logical = [ln.strip() for ln in re.sub(r'\\\n', ' ', wait_run).split("\n") if ln.strip()]
VAL = r'"(?:[^"$`\\]|\$\{\{[^}]*\}\})*"'
CMD = r'bash scripts/ci/verified-wait\.sh(?:\s+--[a-z][a-z-]*\s+' + VAL + r')*'
if len(logical) == 1 and re.fullmatch(CMD, logical[0]):
    ok('wait step run is a single command: bash scripts/ci/verified-wait.sh + --flag "value" pairs only')
elif len(logical) != 1:
    bad(f"wait step run has {len(logical)} logical lines; it must be ONE "
        "verified-wait.sh command (a second line can hide a second call)")
else:
    bad('wait step run is not exactly `bash scripts/ci/verified-wait.sh --flag "value" ...`; '
        f"extra shell (chain/redirect/substitution/variable call) found in: {logical[0]!r}")

# ── CREDIBLE-1572: reject continue-on-error (job + step) and require exact --lane values ──
# 13. Neither the verified job nor any step inside it may carry continue-on-error.
if v.get("continue-on-error") is not None:
    bad(f"verified job carries continue-on-error: {v.get('continue-on-error')!r} — required gate must never swallow failure")
else:
    ok("verified job has no continue-on-error")

steps_with_coe = [st for st in steps if st.get("continue-on-error") is not None]
if steps_with_coe:
    bad(f"{len(steps_with_coe)} step(s) in verified carry continue-on-error — wait step must never swallow failure")
else:
    ok("no step in verified carries continue-on-error")

# 14. Every --lane "<lane>=<val>" argument must have <val> equal to the live
#     ${{ needs.<lane>.result }} expression for that exact lane (no hard-coded
#     --lane "test=success" or cross-wired lane result), and --lane flag count
#     must equal len(needs_set).
lane_pairs = re.findall(r'--lane\s+"([^="]+)=([^"]*)"', wait_run)
bad_lane_vals = []
for lname, lval in lane_pairs:
    m_expr = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", lval.strip())
    expected_inner = f"needs.{lname}.result"
    if not m_expr or " ".join(m_expr.group(1).split()) != expected_inner:
        bad_lane_vals.append(f"{lname}={lval}")
if not bad_lane_vals and len(lane_pairs) == len(needs_set) and flag_counts.get("lane", 0) == len(needs_set):
    ok(f"every --lane value is the exact ${{{{ needs.<lane>.result }}}} expression ({len(lane_pairs)} lanes)")
else:
    bad(f"--lane values invalid or count mismatch (bad={bad_lane_vals}, pairs={len(lane_pairs)}, flag_count={flag_counts.get('lane', 0)}, needs={len(needs_set)})")

sys.exit(1 if fail else 0)
PY
rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo 'PASS: ci.yml verified job is wired to verified-wait.sh (CREDIBLE-1554)'
fi

# ── Mutant self-test (CREDIBLE-1554 repair 5) ─────────────────────────────────
# Re-run this test against deliberately broken copies of ci.yml; EVERY mutant
# must FAIL it. A mutant whose anchor text is missing from ci.yml is itself a
# FAIL (the list is updated alongside the call site, never silently skipped).
# The recursive runs set SHAPE_TEST_NO_MUTANTS=1 so they do not recurse.
if [[ "$rc" -eq 0 && -z "${SHAPE_TEST_NO_MUTANTS:-}" ]]; then
  MUT_DIR="$(mktemp -d)"
  trap 'rm -rf "$MUT_DIR"' EXIT
  CI_YML="$CI_YML" MUT_DIR="$MUT_DIR" python3 <<'MUTANTS_PY'
import os, sys
src = open(os.environ["CI_YML"]).read()
I = " " * 12  # indent of the wait step's run: lines
BS = "\\"     # the shell line-continuation backslash
EV  = I + '--event-name "${{ github.event_name }}" ' + BS + "\n"
SHA = I + '--sha "${{ github.event.pull_request.head.sha || github.sha }}" ' + BS + "\n"
PR  = I + '--pr "${{ github.event.pull_request.number }}" ' + BS + "\n"
ACP = I + '--cross "ACP protocol smoke test (Zed / JetBrains compatible)"' + "\n"
MUTANTS = [
    # (name, anchor, replacement); the anchor must occur EXACTLY once in ci.yml.
    # repair 5 blocker: a 2nd --event-name AFTER the live one (last value wins).
    ("dup-event-name-after-live", EV, EV + I + '--event-name "workflow_dispatch" ' + BS + "\n"),
    # the same hole for the other single-valued flags.
    ("dup-sha-after-live", SHA, SHA + I + '--sha "deadbeef" ' + BS + "\n"),
    ("dup-pr-after-live", PR, PR + I + '--pr "1" ' + BS + "\n"),
    # repair 5 item 2: a hidden 2nd call through a variable, on its own line.
    ("hidden-var-call-new-line", ACP,
     ACP + I + 'W=scripts/ci/verified-wait; bash "$W.sh" --lane "test=success" --cross "audit"' + "\n"),
    # the same, chained onto the last line with `;`.
    ("hidden-var-call-chained", ACP,
     ACP[:-1] + '; W=scripts/ci/verified-wait; bash "$W.sh" --lane "test=success"' + "\n"),
    # regression anchor (reviewer Mutant C, killed since repair 4).
    ("hard-coded-event-name", EV, I + '--event-name "workflow_dispatch" ' + BS + "\n"),
    # CREDIBLE-1572 AC1: continue-on-error: true on verified job or wait step.
    ("job-continue-on-error",
     "  verified:\n    name: verified\n",
     "  verified:\n    name: verified\n    continue-on-error: true\n"),
    ("step-continue-on-error",
     "      - name: Wait in-job for every lane then aggregate (CREDIBLE-1554 / META-134)\n",
     "      - name: Wait in-job for every lane then aggregate (CREDIBLE-1554 / META-134)\n        continue-on-error: true\n"),
    # CREDIBLE-1572 AC2: hard-coded --lane "test=success" instead of needs.test.result.
    ("hard-coded-lane-value",
     I + '--lane "test=${{ needs.test.result }}" ' + BS + "\n",
     I + '--lane "test=success" ' + BS + "\n"),
]
for i, (name, anchor, repl) in enumerate(MUTANTS):
    n = src.count(anchor)
    if n != 1:
        print(f"FAIL: mutant {name}: anchor occurs {n}x in ci.yml (expected 1); update MUTANTS", file=sys.stderr)
        sys.exit(1)
    mut = src.replace(anchor, repl)
    assert mut != src
    with open(os.path.join(os.environ["MUT_DIR"], f"{i:02d}-{name}.yml"), "w") as f:
        f.write(mut)
MUTANTS_PY
  for m in "$MUT_DIR"/*.yml; do
    name="$(basename "$m" .yml)"
    if SHAPE_TEST_NO_MUTANTS=1 CI_YML="$m" bash "$0" >/dev/null 2>&1; then
      echo "FAIL: mutant ${name} PASSED the shape test (a guard stopped biting)" >&2
      rc=1
    else
      echo "PASS: mutant ${name} is rejected"
    fi
  done
fi
exit "$rc"
