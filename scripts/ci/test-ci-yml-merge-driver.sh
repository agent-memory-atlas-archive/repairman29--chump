#!/usr/bin/env bash
# test-ci-yml-merge-driver.sh — INFRA-1482
#
# Tests the YAML-aware last-resort fallback (scripts/git/ci-yml-yaml-merge.py)
# wired into scripts/git/merge-driver-ci-yml-add-row.sh. Covers the case the
# line-diff heuristics can't resolve: interleaved additions where ours inserts
# a step between two steps that theirs also touched in the same job.
# shellcheck disable=SC2015  # ok() always exits 0; A && ok || fail is safe here
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="$REPO_ROOT/scripts/git/merge-driver-ci-yml-add-row.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1482 ci.yml YAML-aware merge driver test ==="
echo

[[ -x "$DRIVER" ]] || { echo "FATAL: driver not found or not executable: $DRIVER"; exit 2; }
command -v python3 > /dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }

TMPBASE="$(mktemp -d)"
AMB="$TMPBASE/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMB"
trap 'rm -rf "$TMPBASE"' EXIT

# ── Test 1: additive-only (both append after the same last step) ────────────
echo "--- Test 1: additive-only, both append ---"
T1="$TMPBASE/t1"; mkdir -p "$T1"
cat > "$T1/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
EOF
cat > "$T1/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
      - name: ours-step
        run: echo ours
EOF
cat > "$T1/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
      - name: theirs-step
        run: echo theirs
EOF
rc=0; "$DRIVER" "$T1/ancestor.yml" "$T1/ours.yml" "$T1/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -eq 0 ]] && ok "additive-only auto-resolves (rc=0)" || fail "additive-only should resolve (got $rc)"
python3 -c "import yaml,sys; yaml.safe_load(open('$T1/ours.yml'))" 2>/dev/null \
  && ok "additive-only merged output is valid YAML" || fail "additive-only merged output is NOT valid YAML"
grep -q 'ours-step' "$T1/ours.yml" && grep -q 'theirs-step' "$T1/ours.yml" \
  && ok "additive-only merged output contains both new steps" \
  || fail "additive-only merged output missing a new step"

# ── Test 2: interleaved additions — ours inserts between two theirs-touched steps ──
echo "--- Test 2: interleaved additions (the reported #2088 case) ---"
T2="$TMPBASE/t2"; mkdir -p "$T2"
cat > "$T2/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: setup
        run: echo setup
      - name: build
        run: echo build
      - name: test
        run: echo test
      - name: lint
        run: echo lint
EOF
cat > "$T2/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: setup
        run: echo setup
      - name: ours-added-step
        run: echo ours
      - name: build
        run: echo build
      - name: test
        run: echo test
      - name: lint
        run: echo lint
EOF
cat > "$T2/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: setup
        run: echo setup
      - name: build
        run: echo build
      - name: theirs-added-step
        run: echo theirs
      - name: test
        run: echo test
      - name: lint
        run: echo lint --strict
EOF
rc=0; "$DRIVER" "$T2/ancestor.yml" "$T2/ours.yml" "$T2/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -eq 0 ]] && ok "interleaved additions auto-resolve via YAML-aware fallback (rc=0)" \
  || fail "interleaved additions should auto-resolve (got $rc)"
python3 -c "import yaml,sys; yaml.safe_load(open('$T2/ours.yml'))" 2>/dev/null \
  && ok "interleaved merged output is valid YAML" || fail "interleaved merged output is NOT valid YAML"
grep -q 'ours-added-step' "$T2/ours.yml" && grep -q 'theirs-added-step' "$T2/ours.yml" \
  && ok "interleaved merged output contains both new steps" \
  || fail "interleaved merged output missing a new step"
grep -q -- '--strict' "$T2/ours.yml" \
  && ok "interleaved merge carried theirs' single-side edit to lint step" \
  || fail "interleaved merge lost theirs' edit to lint step"

# ── Test 3: both sides modify the SAME step differently → keep conflict ─────
echo "--- Test 3: same-step conflicting modification (must NOT auto-resolve) ---"
T3="$TMPBASE/t3"; mkdir -p "$T3"
cat > "$T3/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
EOF
cat > "$T3/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build --ours
EOF
cat > "$T3/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build --theirs
EOF
before_ours="$(cat "$T3/ours.yml")"
rc=0; "$DRIVER" "$T3/ancestor.yml" "$T3/ours.yml" "$T3/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] && ok "conflicting same-step edits refused (non-zero rc)" \
  || fail "conflicting same-step edits should be refused (got rc=0)"
[[ "$(cat "$T3/ours.yml")" == "$before_ours" ]] \
  && ok "ours.yml left untouched on refusal" \
  || fail "ours.yml was mutated despite refusal"

# ── Test 4: both sides rename the same step (ambiguous) → keep conflict ─────
echo "--- Test 4: both rename the same base step (must NOT auto-resolve) ---"
T4="$TMPBASE/t4"; mkdir -p "$T4"
cat > "$T4/ancestor.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build
        run: echo build
EOF
cat > "$T4/ours.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build-ours-renamed
        run: echo build
EOF
cat > "$T4/theirs.yml" <<'EOF'
jobs:
  ci:
    steps:
      - name: checkout
        uses: actions/checkout@v4
      - name: build-theirs-renamed
        run: echo build
EOF
rc=0; "$DRIVER" "$T4/ancestor.yml" "$T4/ours.yml" "$T4/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] && ok "both-sides rename refused (non-zero rc)" \
  || fail "both-sides rename of the same base step should be refused (got rc=0)"

# ── Test 5: give_up() emits kind=merge_driver_fallback on true refusal ──────
echo "--- Test 5: ambient emission on refusal ---"
grep -q '"kind":"merge_driver_fallback"' "$AMB" 2>/dev/null \
  && ok "kind=merge_driver_fallback emitted to ambient log on refusal" \
  || fail "kind=merge_driver_fallback NOT emitted on refusal"

# ── Source assertions ────────────────────────────────────────────────────────
echo "--- Source assertions ---"
grep -q 'ci-yml-yaml-merge.py' "$DRIVER" \
  && ok "driver wires in the YAML-aware fallback script" \
  || fail "driver does NOT reference ci-yml-yaml-merge.py"
[[ -f "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" ]] \
  && ok "ci-yml-yaml-merge.py exists" \
  || fail "ci-yml-yaml-merge.py NOT found"
grep -q 'merge_driver_fallback' "$DRIVER" \
  && ok "driver references merge_driver_fallback ambient kind" \
  || fail "driver does NOT reference merge_driver_fallback"

# ── Test 6 (CREDIBLE-1545 AC1): multi-job conflict or base-step deletion in one job
#    must NEVER keep ours while dropping theirs' new steps in another job ───────
echo "--- Test 6 (CREDIBLE-1545 AC1): driver exits non-zero instead of dropping theirs' steps ---"
T6="$TMPBASE/t6"; mkdir -p "$T6"
cat > "$T6/ancestor.yml" <<'EOF'
jobs:
  changes:
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
      - name: tauri-cowork-e2e
        run: echo tauri
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: verify-base
        run: echo base
EOF
# Ours deletes tauri-cowork-e2e in changes and adds a step in fast-checks
cat > "$T6/ours.yml" <<'EOF'
jobs:
  changes:
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes --ours
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: verify-base
        run: echo base
      - name: ours-new-gate
        run: echo ours-gate
EOF
# Theirs (main) adds RESILIENT-1624 and INFRA-8576 in fast-checks
cat > "$T6/theirs.yml" <<'EOF'
jobs:
  changes:
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
      - name: tauri-cowork-e2e
        run: echo tauri
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: verify-base
        run: echo base
      - name: RESILIENT-1624 gate
        run: echo resilient-1624
      - name: INFRA-8576 ops-organ gate
        run: echo infra-8576
EOF
before_t6_ours="$(cat "$T6/ours.yml")"
rc=0; "$DRIVER" "$T6/ancestor.yml" "$T6/ours.yml" "$T6/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] \
  && ok "CREDIBLE-1545 AC1 (6a): driver exits non-zero when one job cannot auto-merge instead of dropping theirs' fast-checks steps" \
  || fail "CREDIBLE-1545 AC1 (6a): driver exited 0 and silently dropped theirs' steps!"
[[ "$(cat "$T6/ours.yml")" == "$before_t6_ours" ]] \
  && ok "CREDIBLE-1545 AC1 (6a): ours.yml restored untouched on refusal" \
  || fail "CREDIBLE-1545 AC1 (6a): ours.yml mutated on refusal"

# 6b: One job merges cleanly (changes), second job (fast-checks) has a same-step conflict -> must exit non-zero!
T6B="$TMPBASE/t6b"; mkdir -p "$T6B"
cat > "$T6B/ancestor.yml" <<'EOF'
jobs:
  changes:
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: verify-base
        run: echo base
EOF
cat > "$T6B/ours.yml" <<'EOF'
jobs:
  changes:
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
      - name: ours-changes-step
        run: echo ours-changes
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: verify-base
        run: echo base --ours-conflict
      - name: ours-fast-step
        run: echo ours-fast
EOF
cat > "$T6B/theirs.yml" <<'EOF'
jobs:
  changes:
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
      - name: theirs-changes-step
        run: echo theirs-changes
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: verify-base
        run: echo base --theirs-conflict
      - name: RESILIENT-1624 gate
        run: echo resilient-1624
EOF
rc=0; "$DRIVER" "$T6B/ancestor.yml" "$T6B/ours.yml" "$T6B/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] \
  && ok "CREDIBLE-1545 AC1 (6b): partial multi-job merge refused when fast-checks cannot place both sides' steps" \
  || fail "CREDIBLE-1545 AC1 (6b): partial multi-job merge exited 0 and dropped fast-checks steps!"

# ── Test 7 (CREDIBLE-1545 AC3): both sides add steps AND both edit a nearby comment ──
echo "--- Test 7 (CREDIBLE-1545 AC3): both-sides-add plus nearby comment edits keeps every step ---"
T7="$TMPBASE/t7"; mkdir -p "$T7"
cat > "$T7/ancestor.yml" <<'EOF'
# Workflow header comment: base
jobs:
  changes:
    # Job comment: base
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      # Comment above setup: base
      - name: setup
        run: echo setup
      # Comment above lint: base
      - name: lint
        run: echo lint
EOF
cat > "$T7/ours.yml" <<'EOF'
# Workflow header comment: edited by ours
jobs:
  changes:
    # Job comment: base
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      # Comment above setup: edited by ours
      - name: setup
        run: echo setup
      # Ours added step comment
      - name: ours-added-gate
        run: echo ours-gate
      # Comment above lint: base
      - name: lint
        run: echo lint
EOF
cat > "$T7/theirs.yml" <<'EOF'
# Workflow header comment: base
jobs:
  changes:
    # Job comment: edited by theirs
    steps:
      - uses: actions/checkout@v7
      - name: detect-changes
        run: echo changes
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      # Comment above setup: base
      - name: setup
        run: echo setup
      # Comment above lint: edited by theirs
      - name: lint
        run: echo lint
      # Theirs added RESILIENT-1624 comment
      - name: RESILIENT-1624 gate
        run: echo resilient-1624
      # Theirs added INFRA-8576 comment
      - name: INFRA-8576 ops-organ gate
        run: echo infra-8576
EOF
rc=0; "$DRIVER" "$T7/ancestor.yml" "$T7/ours.yml" "$T7/theirs.yml" 2>/dev/null || rc=$?
[[ $rc -eq 0 ]] \
  && ok "CREDIBLE-1545 AC3: both-sides-add + nearby comment edits auto-merged (rc=0)" \
  || fail "CREDIBLE-1545 AC3: both-sides-add + nearby comment edits failed to merge (rc=$rc)"
python3 -c "import yaml; yaml.safe_load(open('$T7/ours.yml'))" 2>/dev/null \
  && ok "CREDIBLE-1545 AC3: merged output is valid YAML" \
  || fail "CREDIBLE-1545 AC3: merged output is NOT valid YAML"
for required_step in "ours-added-gate" "RESILIENT-1624 gate" "INFRA-8576 ops-organ gate" "setup" "lint" "detect-changes"; do
  grep -q "$required_step" "$T7/ours.yml" \
    && ok "CREDIBLE-1545 AC3: merged output retained step '$required_step'" \
    || fail "CREDIBLE-1545 AC3: merged output lost step '$required_step'"
done
grep -q "Comment above setup: edited by ours" "$T7/ours.yml" \
  && grep -q "Comment above lint: edited by theirs" "$T7/ours.yml" \
  && grep -q "Workflow header comment: edited by ours" "$T7/ours.yml" \
  && grep -q "Job comment: edited by theirs" "$T7/ours.yml" \
  && ok "CREDIBLE-1545 AC3: merged output retained nearby comment edits from both sides" \
  || fail "CREDIBLE-1545 AC3: merged output lost a nearby comment edit"

# ── Test 8 (CREDIBLE-1545 AC2): structural step-retention check ──────────────
echo "--- Test 8 (CREDIBLE-1545 AC2): structural check fails when origin/main step dropped unintentionally ---"
T8="$TMPBASE/t8-repo"
mkdir -p "$T8"
git -C "$T8" init -q -b main
git -C "$T8" config user.email "fixture@example.com"
git -C "$T8" config user.name "Fixture"
mkdir -p "$T8/.github/workflows"
cat > "$T8/.github/workflows/ci.yml" <<'EOF'
jobs:
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: base-gate
        run: echo base
      - name: legacy-gate
        run: echo legacy
EOF
git -C "$T8" add .github/workflows/ci.yml
git -C "$T8" commit -q -m "base commit"
BASE_SHA="$(git -C "$T8" rev-parse HEAD)"

# Advance main with a new step (RESILIENT-1624 gate)
cat > "$T8/.github/workflows/ci.yml" <<'EOF'
jobs:
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: base-gate
        run: echo base
      - name: legacy-gate
        run: echo legacy
      - name: RESILIENT-1624 gate
        run: echo resilient-1624
EOF
git -C "$T8" commit -q -am "main adds RESILIENT-1624 gate"
MAIN_SHA="$(git -C "$T8" rev-parse HEAD)"
git -C "$T8" update-ref refs/remotes/origin/main "$MAIN_SHA"

# Branch off BASE_SHA: intentionally deletes legacy-gate and adds pr-gate
git -C "$T8" checkout -q -b pr-branch "$BASE_SHA"
cat > "$T8/.github/workflows/ci.yml" <<'EOF'
jobs:
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: base-gate
        run: echo base
      - name: pr-gate
        run: echo pr
EOF
git -C "$T8" commit -q -am "pr intentionally deletes legacy-gate and adds pr-gate"

# Simulate a broken merge commit that keeps ours and drops RESILIENT-1624 from origin/main
git -C "$T8" merge -q -s ours origin/main -m "broken merge dropping origin/main step"
rc=0
err_out="$(python3 "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" --check-repo-step-retention "$T8" origin/main 2>&1)" || rc=$?
[[ $rc -ne 0 ]] && grep -q "RESILIENT-1624 gate" <<<"$err_out" \
  && ok "CREDIBLE-1545 AC2 (8a): structural check FAILS when merge commit drops RESILIENT-1624 gate from origin/main" \
  || fail "CREDIBLE-1545 AC2 (8a): structural check did not fail on dropped RESILIENT-1624 gate (rc=$rc, out=$err_out)"

# Now fix the merge so RESILIENT-1624 gate is retained while legacy-gate (intentionally deleted in PR diff) stays deleted
cat > "$T8/.github/workflows/ci.yml" <<'EOF'
jobs:
  fast-checks:
    steps:
      - uses: actions/checkout@v7
      - name: base-gate
        run: echo base
      - name: pr-gate
        run: echo pr
      - name: RESILIENT-1624 gate
        run: echo resilient-1624
EOF
git -C "$T8" commit -q --amend --no-edit -a
rc=0
err_out="$(python3 "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" --check-repo-step-retention "$T8" origin/main 2>&1)" || rc=$?
[[ $rc -eq 0 ]] \
  && ok "CREDIBLE-1545 AC2 (8b): structural check PASSES when origin/main steps are retained and only PR's own intentional deletion is absent" \
  || fail "CREDIBLE-1545 AC2 (8b): structural check falsely failed on intentional deletion (rc=$rc, out=$err_out)"

# Live repo step-retention check (kills any working-tree or branch mutant that drops a step from .github/workflows/ci.yml)
rc=0
live_out="$(python3 "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" --check-repo-step-retention "$REPO_ROOT" 2>&1)" || rc=$?
[[ $rc -eq 0 ]] \
  && ok "CREDIBLE-1545 AC2 (8c): live repo .github/workflows/ci.yml passes structural step-retention check against origin/main" \
  || fail "CREDIBLE-1545 AC2 (8c): live repo .github/workflows/ci.yml failed step-retention check: $live_out"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
