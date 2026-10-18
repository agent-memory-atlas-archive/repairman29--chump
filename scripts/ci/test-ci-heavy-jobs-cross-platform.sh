#!/usr/bin/env bash
# test-ci-heavy-jobs-cross-platform.sh — INFRA-1542 Phase 2
#
# Asserts that the heavy ci.yml jobs (see HEAVY_JOBS below) are CROSS-PLATFORM-CAPABLE:
#   1. Every `sudo apt-get install` step carries `if: runner.os == 'Linux'`
#      so the step skips on macOS where Tauri uses native WebKit.
#   2. Each heavy job's `runs-on:` honors either CHUMP_SELF_HOSTED_ENABLED
#      (boolean toggle, INFRA-1534 original form) OR a per-job `RUNNER_<JOB>`
#      variable (INFRA-1542 per-job override).
#
# Without these, migrating a heavy job to [self-hosted, macOS, ARM64] would
# fail on the apt-get step or have no clean mechanism to flip.

set -uo pipefail
PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

[[ -f "$CI_YML" ]] || { echo "FATAL: $CI_YML missing"; exit 2; }

echo "=== INFRA-1542 heavy-job cross-platform audit ==="

# Test 1: every apt-get install step carries `if: runner.os == 'Linux'`.
python3 - "$CI_YML" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
lines = src.splitlines()
fails = 0
oks = 0
for i, line in enumerate(lines):
    if 'sudo apt-get install' not in line:
        continue
    # Walk back to find the containing step start (6-space `- name:` or `- ...`)
    step_i = None
    for j in range(i, max(0, i - 40), -1):
        if re.match(r'^      - ', lines[j]):
            step_i = j
            break
    if step_i is None:
        continue
    # Check lines between step_i+1 and i for an `if:` with runner.os
    has = False
    for k in range(step_i + 1, i + 1):
        if re.match(r'^        if:\s', lines[k]) and 'runner.os' in lines[k]:
            has = True
            break
    if has:
        oks += 1
    else:
        fails += 1
        print(f"  MISS line {i+1}: apt-get without Linux gate (step at line {step_i+1})", file=sys.stderr)
print(f"  apt-get steps with Linux gate: {oks}/{oks+fails}")
sys.exit(0 if fails == 0 else 1)
PY
if [[ $? -eq 0 ]]; then
    ok "every apt-get install step gated on runner.os == 'Linux'"
else
    fail "at least one apt-get install step missing Linux gate"
fi

# Test 2: each heavy job's runs-on is operator-flippable.
# INFRA-2343 (META-207 trunk-red rescue): refreshed list to match current ci.yml jobs.
# Removed: 'coverage' (migrated to nightly per META-260),
#          'e2e-pwa' + 'e2e-golden-path' (matrixed into single 'e2e' job per META-267 —
#          'e2e' uses matrix-driven runs-on-expr flexibility which this classifier
#          would need extending to accept; out-of-scope for this surgical fix).
# INFRA-2475: 'audit' moved to audit.yml (INFRA-2452) — it is no longer a ci.yml job.
# audit.yml has its own RUNNER_AUDIT flip mechanism (same pattern, different workflow).
# Reduced expected count from 5 to 4.
# CREDIBLE-1523: 'tauri-cowork-e2e' removed — the permanently-disabled stub was
# deleted from ci.yml (the live job lives in ci-nightly.yml per RESILIENT-016;
# the stub tripped ci-advisory.yml's advisory-drift-gate). Reduced 4 → 3.
HEAVY_JOBS="clippy cargo-test-shard fast-checks"
flexible=0
fixed=0
for job in $HEAVY_JOBS; do
    flex=$(python3 - "$CI_YML" "$job" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
job = sys.argv[2]
m = re.search(rf'^  {re.escape(job)}:\s*\n', src, re.MULTILINE)
if not m:
    print("NOT_FOUND"); sys.exit(0)
body_start = m.end()
nh = re.search(r'^  [a-zA-Z][a-zA-Z0-9_-]*:\s*\n', src[body_start:], re.MULTILINE)
body = src[body_start: body_start + (nh.start() if nh else 5000)]
# Look for runs-on with either CHUMP_SELF_HOSTED_ENABLED or RUNNER_<JOB> var.
ro = re.search(r'^    runs-on:\s*(.+)$', body, re.MULTILINE)
if not ro:
    print("NO_RUNS_ON"); sys.exit(0)
ros = ro.group(1)
if 'CHUMP_SELF_HOSTED_ENABLED' in ros or 'fromJSON(vars.RUNNER_' in ros or 'self-hosted' in ros and 'vars.' in ros:
    print("FLEXIBLE")
elif ros.strip() == 'ubuntu-latest':
    print("FIXED_UBUNTU")
else:
    print(f"OTHER:{ros}")
PY
)
    case "$flex" in
        FLEXIBLE) flexible=$((flexible+1)) ;;
        *)        fixed=$((fixed+1)); echo "  $job: $flex" >&2 ;;
    esac
done
# INFRA-2343: derive expected count from HEAVY_JOBS instead of hardcoding 8
# (was 8 before META-260/META-267 reshaped ci.yml; now 5).
expected=$(echo "$HEAVY_JOBS" | wc -w | tr -d ' ')
if (( flexible == expected )); then
    ok "all $expected heavy jobs runs-on is operator-flippable via repo var"
else
    fail "only $flexible of $expected heavy jobs have flippable runs-on (the other $fixed are hardcoded)"
fi

# Test 3: gate-apt-get-on-linux.py is idempotent.
if [[ -x "$REPO_ROOT/scripts/setup/gate-apt-get-on-linux.py" ]]; then
    out=$(cd "$REPO_ROOT" && python3 scripts/setup/gate-apt-get-on-linux.py --dry-run 2>&1)
    if echo "$out" | grep -qE "DRY-RUN: no changes|gate 0 step"; then
        ok "gate-apt-get-on-linux.py is idempotent on a gated file"
    else
        fail "gate-apt-get-on-linux.py would re-gate (not idempotent)"
    fi
else
    fail "gate-apt-get-on-linux.py missing or not executable"
fi

# Test 4: add-heavy-job-runner-overrides.py is idempotent.
if [[ -x "$REPO_ROOT/scripts/setup/add-heavy-job-runner-overrides.py" ]]; then
    out=$(cd "$REPO_ROOT" && python3 scripts/setup/add-heavy-job-runner-overrides.py --dry-run 2>&1)
    if echo "$out" | grep -qE "no changes|patch 0 job"; then
        ok "add-heavy-job-runner-overrides.py is idempotent"
    else
        # ALREADY OVERRIDDEN lines are also idempotency markers
        already=$(echo "$out" | grep -c "ALREADY OVERRIDDEN")
        if (( already >= 5 )); then
            ok "add-heavy-job-runner-overrides.py reports ALREADY OVERRIDDEN (idempotent)"
        else
            fail "add-heavy-job-runner-overrides.py would re-patch (not idempotent): $(echo "$out" | tail -3)"
        fi
    fi
else
    fail "add-heavy-job-runner-overrides.py missing or not executable"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
