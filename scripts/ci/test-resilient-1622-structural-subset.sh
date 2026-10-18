#!/usr/bin/env bash
# scripts/ci/test-resilient-1622-structural-subset.sh — RESILIENT-1622 regression.
#
# The dispatch/bot-merge ship path runs fmt/clippy/test and delegates the heavy
# cargo suite to CI (INFRA-1399), while the pre-push hook used to SKIP preflight
# entirely for bot-merge pushes (INFRA-3521). The structural no-build gates
# (census shrink-only, preflight-ci-parity, env-var coverage, event-registry
# audit, path-filter allowlist, no-new-bypass-env-vars, raw-gh lint) therefore
# ran NOWHERE before push on the fleet's own ship path — so an unwired new
# scripts/ci test (#5582) or a raw gh call in a hot path (#5585) surfaced only
# after a 30-45 min CI round + a repair dispatch.
#
# This test proves the fix end-to-end, with no cargo build:
#   1. `chump preflight --structural` exists as a flag and STRUCTURAL_GATES
#      lists the seven no-build gates (preflight.rs, the single source of truth).
#   2. bot-merge.sh runs `chump preflight --structural` before the push step and
#      fails the ship (via _bm_fail) with the gate name on red.
#   3. the pre-push hook runs the structural subset under CHUMP_BOT_MERGE_IN_PROGRESS
#      (INFRA-3521 narrowed, not reverted — it no longer skips preflight).
#   4. BEHAVIORAL: a synthetic unwired scripts/ci test fails the census-shrink-only
#      gate — the exact gate the bot-merge structural subset runs before push —
#      and the failing test is named. This is the #5582 class, caught locally.
#   5. (best-effort) if a prebuilt `chump` binary is on PATH, `chump preflight
#      --structural` is recognized (not "bad usage"), proving the wiring compiles.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/crates/chump-preflight/src/preflight.rs"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
CENSUS="$REPO_ROOT/scripts/ci/census.sh"

echo "=== RESILIENT-1622: structural preflight subset on the bot-merge push path ==="

for f in "$PREFLIGHT" "$BOT_MERGE" "$HOOK" "$CENSUS"; do
    [[ -f "$f" ]] || { echo "[FAIL] required file missing: $f"; exit 1; }
done

# ── 1. preflight.rs: --structural flag + STRUCTURAL_GATES membership ─────────────
if grep -q '"--structural" => a.structural = true' "$PREFLIGHT"; then
    ok "preflight.rs parses the --structural flag"
else
    fail "preflight.rs does not parse --structural"
fi

if grep -q 'const STRUCTURAL_GATES' "$PREFLIGHT"; then
    ok "preflight.rs defines STRUCTURAL_GATES (single source of truth)"
else
    fail "preflight.rs is missing the STRUCTURAL_GATES const"
fi

# The seven no-build gates the gap + architect note require, by their gate names.
# Capture the block first, then grep a here-string: an `awk | grep -q` pipeline
# under pipefail can SIGPIPE awk on grep's early exit and read as a false FAIL
# (fleet CI class 31).
structural_gates_block=$(awk '/const STRUCTURAL_GATES/,/^\];/' "$PREFLIGHT")
for gate in event-registry-audit env-var-coverage path-filter-coverage \
            no-new-bypass-env-vars census-shrink-only preflight-ci-parity-smoke \
            raw-gh-lint; do
    if grep -q "\"$gate\"" <<<"$structural_gates_block"; then
        ok "STRUCTURAL_GATES includes $gate"
    else
        fail "STRUCTURAL_GATES is missing $gate"
    fi
done

# The subset must short-circuit BEFORE the cargo/scope pipeline (no build).
if grep -q 'return run_structural(' "$PREFLIGHT"; then
    ok "run() short-circuits to run_structural (skips the cargo pipeline)"
else
    fail "run() does not short-circuit to run_structural — the subset would still build"
fi

# ── 2. bot-merge.sh: runs the subset before push, fails with the gate name ───────
# The structural stage must appear BEFORE the push step (_bm_step_start "push").
bm_struct_line=$(grep -n 'chump preflight --structural' "$BOT_MERGE" | head -1 | cut -d: -f1)
bm_push_line=$(grep -n '_bm_step_start "push"' "$BOT_MERGE" | head -1 | cut -d: -f1)
if [[ -n "$bm_struct_line" && -n "$bm_push_line" ]] && (( bm_struct_line < bm_push_line )); then
    ok "bot-merge runs 'chump preflight --structural' BEFORE push (line $bm_struct_line < $bm_push_line)"
else
    fail "bot-merge must run 'chump preflight --structural' before the push step (struct=$bm_struct_line push=$bm_push_line)"
fi

if grep -q 'RESILIENT-1622 structural subset refused' "$BOT_MERGE"; then
    ok "bot-merge fails the ship (_bm_fail) with the failing structural gate name"
else
    fail "bot-merge does not fail the ship with the structural gate name on red"
fi

# bot-merge's capability gate must CAPTURE `chump preflight --help` and then
# test the string — never pipe it into `grep -q` (under pipefail, grep's early
# exit can SIGPIPE the upstream and read as false, silently skipping the gate:
# fleet CI class 31).
if grep -q '_bm_pf_help="$(chump preflight --help' "$BOT_MERGE" \
    && grep -qF '[[ "$_bm_pf_help" == *--structural* ]]' "$BOT_MERGE"; then
    ok "bot-merge capability gate captures --help then tests it (pipefail-safe)"
else
    fail "bot-merge capability gate must capture 'chump preflight --help' into a var and test it with [[ == *--structural* ]]"
fi
if grep -qE 'preflight --help[^|]*\| *grep -q' "$BOT_MERGE"; then
    fail "bot-merge still pipes 'chump preflight --help' into grep -q (pipefail SIGPIPE class 31)"
else
    ok "bot-merge has no 'preflight --help | grep -q' pipeline"
fi

# No phantom bypass hint: nothing reads the advertised *_STRUCTURAL_GATE_DISABLE var, and the
# fleet forbids new bypass env vars (INFRA-2429 ceiling). --fast is the escape.
if grep -q 'STRUCTURAL_GATE_DISABLE' "$BOT_MERGE"; then
    fail "bot-merge advertises STRUCTURAL_GATE_DISABLE, which nothing reads"
else
    ok "bot-merge advertises no phantom structural-gate bypass env var"
fi

# ── 3. pre-push hook: INFRA-3521 narrowed to the structural subset ──────────────
guard_0a_block=$(awk '/^# Guard 0a:/,/^# Guard 0: cargo fmt/' "$HOOK")
if grep -q 'chump preflight \$_pf_structural_arg' <<<"$guard_0a_block" \
    && grep -q 'RESILIENT-1622' <<<"$guard_0a_block"; then
    ok "pre-push runs 'chump preflight --structural' under bot-merge (INFRA-3521 narrowed)"
else
    fail "pre-push should run the structural subset under bot-merge, not skip preflight entirely"
fi

# Rollout safety: the narrowing must be CAPABILITY-GATED. `chump preflight`
# ignores unknown flags, so a stale binary handed --structural would run the
# FULL cargo-build preflight here and blow bot-merge's 300s push budget (the
# META-156 regression). Only run --structural when the binary advertises it;
# otherwise fall back to the old INFRA-3521 skip until the new binary is live.
# The capability check captures --help into a var and tests the string; a
# `--help | grep -q` pipeline is the banned pipefail shape (fleet CI class 31).
botmerge_narrow_block=$(awk '/CHUMP_BOT_MERGE_IN_PROGRESS.*== "1"/,/^    fi/' <<<"$guard_0a_block")
if grep -q '_pf_help="$(chump preflight --help' <<<"$botmerge_narrow_block" \
    && grep -qF '[[ "$_pf_help" == *--structural* ]]' <<<"$botmerge_narrow_block"; then
    ok "pre-push narrowing is capability-gated (stale binary falls back to the old skip — no budget-blow)"
else
    fail "pre-push structural narrowing must be guarded by a captured 'chump preflight --help' + [[ == *--structural* ]] capability check"
fi
if grep -qE 'preflight --help[^|]*\| *grep -q' <<<"$botmerge_narrow_block"; then
    fail "pre-push still pipes 'chump preflight --help' into grep -q (pipefail SIGPIPE class 31)"
else
    ok "pre-push capability check has no 'preflight --help | grep -q' pipeline"
fi

# ── 4. BEHAVIORAL: a synthetic unwired scripts/ci test fails the census gate ────
# census-shrink-only is a member of the structural subset (asserted in §1), and
# it is the gate that caught #5582. Prove it fails on a synthetic unwired test
# the way the bot-merge push path now would — hermetic fixture, no cargo build.
T="$(mktemp -d "${TMPDIR:-/tmp}/resilient-1622.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fx="$T/repo"
mkdir -p "$fx/scripts/ci" "$fx/.github/workflows" "$fx/crates/chump-preflight/src"
for n in a b; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/scripts/ci/test-$n.sh"; done
printf 'jobs:\n  x:\n    steps:\n      - run: bash scripts/ci/test-a.sh\n' \
    > "$fx/.github/workflows/ci.yml"
printf 'step("b", &["bash", "scripts/ci/test-b.sh"]);\n' \
    > "$fx/crates/chump-preflight/src/preflight.rs"
CHUMP_CENSUS_ROOT="$fx" bash "$CENSUS" --no-run --out-dir "$T/base" >/dev/null 2>&1
base="$T/base/ci-test-census.json"
if [[ ! -f "$base" ]]; then
    fail "census fixture base json was not produced"
else
    # Baseline (no unwired test) passes.
    if CHUMP_CENSUS_ROOT="$fx" bash "$CENSUS" --check-shrink "$base" --head-json "$base" >"$T/out" 2>&1; then
        ok "census baseline (no unwired test) passes the structural gate"
    else
        fail "census baseline unexpectedly failed: $(cat "$T/out")"
    fi
    # Add a synthetic UNWIRED scripts/ci test — the #5582 class.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/scripts/ci/test-resilient-1622-UNWIRED.sh"
    if CHUMP_CENSUS_ROOT="$fx" bash "$CENSUS" --check-shrink "$base" --head-json "$base" >"$T/out" 2>&1; then
        fail "a synthetic unwired scripts/ci test PASSED the structural census gate (would reach CI)"
    else
        if grep -q 'test-resilient-1622-UNWIRED.sh' "$T/out"; then
            ok "synthetic unwired scripts/ci test FAILS the structural census gate and is named (bot-merge push blocked locally)"
        else
            ok "synthetic unwired scripts/ci test FAILS the structural census gate (bot-merge push blocked locally)"
        fi
    fi
fi

# ── 5. advisory: the real binary recognizes --structural ────────────────────────
# Best-effort only — NEVER fails the gate. The preflight.rs source (§1) is the
# single source of truth; a prebuilt binary that predates this change is a
# build-staleness condition, not a wiring defect in the diff. CI fast-checks has
# no prebuilt chump binary, so this path is advisory everywhere.
if command -v chump >/dev/null 2>&1 && chump preflight --help >/dev/null 2>&1; then
    _chump_pf_help="$(chump preflight --help 2>&1 || true)"
    if [[ "$_chump_pf_help" == *--structural* ]]; then
        ok "prebuilt chump binary advertises --structural in --help"
    else
        echo "  SKIP: prebuilt chump binary predates --structural (stale build) — rebuild to pick it up; source wiring verified above"
    fi
else
    echo "  SKIP: no prebuilt chump binary on PATH — structural-binary smoke skipped (static checks above cover wiring)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
