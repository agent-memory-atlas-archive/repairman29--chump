#!/usr/bin/env bash
# scripts/ci/test-arm-policy-native.sh — INFRA-8221 (slice 2, PHASE-R R3)
#
# The Rust and Python half of the one arm policy (the shell half is
# scripts/ci/test-arm-policy.sh). A held PR (no-auto-merge / hold /
# do-not-merge / CHUMP_HOLD label, or an `Auto-merge: hold` line in the body or
# a comment) is never armed, merged, update-branched or force-pushed by a Rust
# or Python organ either.
#
# Depth: (a) structural inventory: every .rs file under src/ and crates/ that
# arms, merges or update-branches a PR (`"pr", "merge"` / `"pr",
# "update-branch"` arrays across line breaks, REST `/pulls/{..}/merge`,
# enablePullRequestAutoMerge) must call chump_ship::arm_policy, every Python
# armer under scripts/ must call arm_allowed, src/execute_gap.rs must keep
# delegating to bot-merge.sh, whose arm path calls arm_policy_allows, and the
# Rust policy keeps its literal kinds. (b) behavioural, Python: the gardener's
# pr_hold_reason on each hold shape plus near misses, arm_allowed emits
# pr_arm_skipped_hold for a held PR, allows a clean one, fails open on a read
# error. The Rust behaviour (one test per call site with a scripted fetcher)
# runs under cargo test: crates/chump-ship arm_policy + gate_plan +
# manual_ship, chump-integrator, chump-verify, chump-bench, chump-paramedic,
# src/{rebase_stuck,pr_rescue,pr_triage,improve}.rs.
# Gaps: no live GitHub call; the scanner is pattern-based (a merge spelled
# some other way, e.g. a raw GraphQL body built at runtime, is not seen).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

POLICY=crates/chump-ship/src/arm_policy.rs
[[ -f "$POLICY" ]] || { echo "FAIL: $POLICY missing" >&2; exit 1; }

echo "[a] Rust + Python arm/merge/rebase sites must call the arm policy"

# Files that match the pattern without arming anything. <path>  # reason
NATIVE_ALLOW='
src/pr_explain.rs        # reason: string match on a check name ("update-branch" in a hint), no gh call
'

out="$(python3 - "$NATIVE_ALLOW" <<'PY'
import glob, re, sys
allow = {l.split()[0] for l in sys.argv[1].splitlines() if l.strip() and not l.strip().startswith('#')}
rust = re.compile(r'"pr"\s*,\s*"(?:merge|update-branch)"|"update-branch"|/pulls/\{[A-Za-z_]*\}/merge|enablePullRequestAutoMerge\s*\(')
py = re.compile(r'''["']pr["']\s*,\s*["'](?:merge|update-branch)["']''')
rows = []
for f in sorted(glob.glob('src/**/*.rs', recursive=True) + glob.glob('crates/**/*.rs', recursive=True)):
    if f.endswith('arm_policy.rs'):
        continue
    t = open(f, encoding='utf-8', errors='replace').read()
    hits = [t.count('\n', 0, m.start()) + 1 for m in rust.finditer(t)]
    if hits:
        state = 'ALLOW' if f in allow else ('OK' if 'arm_policy::' in t else 'MISSING')
        rows.append(f"{state}\trust\t{f}\t{','.join(map(str, hits))}")
for f in sorted(glob.glob('scripts/**/*.py', recursive=True)):
    if '/ci/' in f:
        continue
    t = open(f, encoding='utf-8', errors='replace').read()
    hits = [t.count('\n', 0, m.start()) + 1 for m in py.finditer(t)]
    if hits:
        state = 'OK' if re.search(r'\barm_allowed\(', t) else 'MISSING'
        rows.append(f"{state}\tpython\t{f}\t{','.join(map(str, hits))}")
for a in sorted(allow):
    if not any(r.split('\t')[2] == a for r in rows):
        rows.append(f"STALE\tallow\t{a}\t-")
print('\n'.join(rows))
PY
)"
n_rust=0
while IFS=$'\t' read -r state lang file lines; do
    [[ -z "$state" ]] && continue
    [[ "$lang" == rust ]] && n_rust=$((n_rust + 1))
    case "$state" in
        OK)      ok "$lang $file:$lines calls the arm policy" ;;
        ALLOW)   ok "$lang $file allowlisted ($(grep -F "$file" <<<"$NATIVE_ALLOW" | sed 's/.*# reason: //' | cut -c1-60))" ;;
        MISSING) bad "$lang $file:$lines arms/merges/rebases a PR without chump_ship::arm_policy (Rust) / arm_allowed (Python)" ;;
        STALE)   bad "allowlist entry $file no longer matches; delete it" ;;
    esac
done <<<"$out"
[[ "$n_rust" -ge 10 ]] && ok "found $n_rust Rust site files (sanity floor 10)" \
    || bad "only $n_rust Rust site files found; detector regex broke?"
grep -q 'scripts/coord/gap-gardener.py' <<<"$out" && ok "gap-gardener.py is in the inventory" \
    || bad "gap-gardener.py not detected as an armer; detector regex broke?"

# Sites the pattern scan cannot see (git force-push, or the step runner that
# executes chump-ship's planned gh steps) must still call the policy.
for spec in "src/rebase_stuck.rs:arm_policy::require_touch_allowed" "src/main.rs:chump_ship::gate_plan"; do
    f="${spec%%:*}"; sym="${spec#*:}"
    grep -q "$sym" "$f" && ok "$f calls $sym" || bad "$f does not call $sym"
done

# execute-gap arms through bot-merge.sh, whose arm path is policy-gated.
if grep -q 'bot-merge.sh' src/execute_gap.rs && grep -q 'arm-policy: delegated' src/execute_gap.rs \
    && grep -q 'auto-merge-armer.sh' scripts/coord/bot-merge.sh \
    && grep -q 'arm_policy_allows' scripts/coord/auto-merge-armer.sh; then
    ok "src/execute_gap.rs delegates arming to bot-merge.sh -> auto-merge-armer.sh (arm_policy_allows)"
else
    bad "src/execute_gap.rs delegation chain to arm_policy_allows is broken"
fi

for k in pr_arm_skipped_hold pr_rearmed; do
    grep -q "scanner-anchor: \"kind\":\"$k\"" "$POLICY" && ok "Rust literal \"kind\":\"$k\" anchored" \
        || bad "no scanner-anchor \"kind\":\"$k\" in $POLICY"
done
grep -q 'scanner-anchor: "kind":"pr_arm_skipped_hold"' scripts/coord/gap-gardener.py \
    && ok "Python literal \"kind\":\"pr_arm_skipped_hold\" anchored" || bad "gap-gardener.py lacks the kind anchor"
grep -q 'kind: pr_cut$' docs/observability/EVENT_REGISTRY.yaml && ok "pr_cut registered" || bad "pr_cut missing from EVENT_REGISTRY.yaml"
grep -q 'commands::pr_cut::run_cli' src/main.rs && ok "chump pr cut arm wired in src/main.rs" \
    || bad "chump pr cut arm missing from src/main.rs"

echo "[b] gap-gardener.py: hold detection + arm_allowed"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" python3 - "$REPO_ROOT/scripts/coord/gap-gardener.py" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("gap_gardener", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
fails = []
def check(name, got, want):
    if got != want:
        fails.append(f"{name}: got {got!r}, want {want!r}")
check("label", g.pr_hold_reason({"labels": [{"name": "No-Auto-Merge"}]}), "label:No-Auto-Merge")
check("legacy", g.pr_hold_reason({"labels": [{"name": "CHUMP_HOLD"}]}), "label:CHUMP_HOLD")
check("body", g.pr_hold_reason({"labels": [], "body": "x\n  auto-merge: HOLD until y"}), "marker:body")
check("comment", g.pr_hold_reason({"body": "", "comments": [{"body": "lgtm"}, {"body": "Auto-merge: hold"}]}), "marker:comment")
check("holding", g.pr_hold_reason({"body": "Auto-merge: holding pattern"}), None)
check("midline", g.pr_hold_reason({"body": "said Auto-merge: hold"}), None)
check("clean", g.pr_hold_reason({"labels": [{"name": "holdover"}], "body": "plain"}), None)
check("held arm", g.arm_allowed("101", g.REPO_ROOT, fetch=lambda pr, root: {"labels": [{"name": "hold"}]}), False)
check("clean arm", g.arm_allowed("102", g.REPO_ROOT, fetch=lambda pr, root: {"labels": [], "body": ""}), True)
def boom(pr, root):
    raise RuntimeError("gh down")
check("fail open", g.arm_allowed("103", g.REPO_ROOT, fetch=boom), True)
lines = [json.loads(l) for l in open(os.environ["CHUMP_AMBIENT_LOG"])]
check("one event", len(lines), 1)
if lines:
    e = lines[0]
    check("event", (e["kind"], e["pr"], e["armer"], e["reason"]), ("pr_arm_skipped_hold", 101, "gap-gardener.py", "label:hold"))
raw = open(os.environ["CHUMP_AMBIENT_LOG"]).read()
check("literal kind", '"kind":"pr_arm_skipped_hold"' in raw, True)
for f in fails:
    print("    " + f, file=sys.stderr)
sys.exit(1 if fails else 0)
PY
then
    ok "gardener: labels / body / comment markers held, near misses clean, held arm emits pr_arm_skipped_hold, read error fails open"
else
    bad "gardener arm policy behaviour (see above)"
fi
grep -q 'if not arm_allowed(' scripts/coord/gap-gardener.py && ok "gardener's arm site calls arm_allowed before gh pr merge --auto" \
    || bad "gardener's arm site does not call arm_allowed"

echo
echo "=== test-arm-policy-native: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
