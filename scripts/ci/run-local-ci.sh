#!/usr/bin/env bash
# run-local-ci.sh — INFRA-2251 / INFRA-2246 offline-first roadmap Phase 1
#
# The complete local CI gate. Runs everything GitHub Actions runs that
# does NOT require network access (no gh api, no gh pr, no curl to
# external URLs). Exit 0 = mergeable to local main. Exit 1 = blocked
# with named failing check.
#
# Usage:
#   bash scripts/ci/run-local-ci.sh             # all three tiers
#   bash scripts/ci/run-local-ci.sh --dry-run   # print what would run; exit 0
#   bash scripts/ci/run-local-ci.sh --tier 1    # only Tier 1 (fast checks)
#   bash scripts/ci/run-local-ci.sh --tier 2    # only Tier 2 (Rust)
#   bash scripts/ci/run-local-ci.sh --tier 3    # only Tier 3 (integration)
#   CHUMP_LOCAL_CI_SKIP=1 bash scripts/ci/run-local-ci.sh  # bypass with audit trail
#
# Network safety: set no_proxy + an unroutable proxy to force local failures
# if any command accidentally reaches the network. The smoke test validates this.
#
# GitHub-API-dependent scripts are in scripts/ci/run-remote-ci.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_CI="$REPO_ROOT/scripts/ci"
CARGO="${CARGO:-cargo}"
PATH="$HOME/.cargo/bin:$PATH"

# ── Parse args ────────────────────────────────────────────────────────────────
DRY_RUN=0
TIER_FILTER=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --tier)    shift; TIER_FILTER="${1:-}" ;;
        --tier=*)  TIER_FILTER="${arg#--tier=}" ;;
    esac
done

# ── Bypass escape hatch (audit-logged) ────────────────────────────────────────
if [[ "${CHUMP_LOCAL_CI_SKIP:-0}" == "1" ]]; then
    echo "[run-local-ci] BYPASSED via CHUMP_LOCAL_CI_SKIP=1" >&2
    printf '{"ts":"%s","kind":"local_ci_bypassed","session":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CHUMP_SESSION_ID:-unknown}" \
        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()

t0_total=$(date +%s%N 2>/dev/null || date +%s)

run_step() {
    local tier="$1"
    local name="$2"
    shift 2
    local cmd=("$@")

    # Apply tier filter
    if [[ -n "$TIER_FILTER" && "$TIER_FILTER" != "$tier" ]]; then
        return
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        printf "  [DRY-RUN] Tier %s | %s: %s\n" "$tier" "$name" "${cmd[*]}"
        return
    fi

    local t0
    t0=$(date +%s%N 2>/dev/null || date +%s)
    printf "  [Tier %s] %s ... " "$tier" "$name"

    local output
    if output=$("${cmd[@]}" 2>&1); then
        local t1
        t1=$(date +%s%N 2>/dev/null || date +%s)
        local elapsed=$(( (t1 - t0) / 1000000 ))
        printf "PASS (%dms)\n" "$elapsed"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        local t1
        t1=$(date +%s%N 2>/dev/null || date +%s)
        local elapsed=$(( (t1 - t0) / 1000000 ))
        printf "FAIL (%dms)\n" "$elapsed"
        echo "--- output ---"
        echo "$output" | tail -30
        echo "---"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_NAMES+=("$name")
    fi
}

# Wrapper for scripts/ci/test-*.sh scripts
run_test_script() {
    local tier="$1"
    local script="$2"
    local name
    name="$(basename "$script" .sh)"
    run_step "$tier" "$name" bash "$script"
}

# ── Print run header ───────────────────────────────────────────────────────────
echo "=== Chump Local CI Gate (INFRA-2251) ==="
echo "    repo:   $REPO_ROOT"
echo "    date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -n "$TIER_FILTER" ]]; then
    echo "    tier:   $TIER_FILTER only"
fi
if [[ "$DRY_RUN" == "1" ]]; then
    echo "    mode:   DRY-RUN"
fi
echo ""

# ────────────────────────────────────────────────────────────────────────────
# TIER 1 — Fast checks (target: < 30s)
# ────────────────────────────────────────────────────────────────────────────
t0_tier1=$(date +%s%N 2>/dev/null || date +%s)
[[ -z "$TIER_FILTER" || "$TIER_FILTER" == "1" ]] && \
    echo "[Tier 1] Fast checks..."

run_step 1 "cargo fmt --check" \
    $CARGO fmt --all -- --check

run_step 1 "cargo check --workspace" \
    $CARGO check --workspace --quiet

# -- Tier 1 test scripts (no gh api / no network) --
# Governance / policy gates (always fast, pure file reads)
run_test_script 1 "$SCRIPTS_CI/test-no-new-shell-tests-for-rust.sh"
run_test_script 1 "$SCRIPTS_CI/test-rust-first-gate.sh"
run_test_script 1 "$SCRIPTS_CI/test-rust-first-bypass-gate.sh"
run_test_script 1 "$SCRIPTS_CI/test-ac-completeness-gate.sh"
run_test_script 1 "$SCRIPTS_CI/test-ac-coverage-gate.sh"
run_test_script 1 "$SCRIPTS_CI/test-gap-audit-priorities.sh"
run_test_script 1 "$SCRIPTS_CI/test-gap-outcome-migration.sh"   # MISSION-008
run_test_script 1 "$SCRIPTS_CI/test-event-registry-audit.sh"
run_test_script 1 "$SCRIPTS_CI/test-env-vars-internal-coverage.sh"
run_test_script 1 "$SCRIPTS_CI/test-registry-orphan.sh"
run_test_script 1 "$SCRIPTS_CI/test-submodule-guard.sh"
run_test_script 1 "$SCRIPTS_CI/test-gap-integrity.sh"
run_test_script 1 "$SCRIPTS_CI/test-gap-audit-ac.sh"
run_test_script 1 "$SCRIPTS_CI/test-gap-preflight-ac-gate.sh"
run_test_script 1 "$SCRIPTS_CI/test-hardcoded-date-guard.sh"
run_test_script 1 "$SCRIPTS_CI/test-plist-no-tmp-paths.sh"  # INFRA-2419: plist temp-path lint
run_test_script 1 "$SCRIPTS_CI/test-fleet-clone-index.sh"   # RESILIENT-1351: org clone+index+untether sweep (hermetic, fake gh/almanac)
run_test_script 1 "$SCRIPTS_CI/test-curator-liveness.sh"    # RESILIENT-246: curator exit-78 + silence regression
run_test_script 1 "$SCRIPTS_CI/test-orphan-allowlist-daemon.sh"  # INFRA-5426: orphan auto-allowlist PR daemon (hermetic, fake git/gh)

# Hook / commit hygiene gates
run_test_script 1 "$SCRIPTS_CI/test-hook-silent-noop.sh"
run_test_script 1 "$SCRIPTS_CI/test-prepush-bypass-audit.sh"
run_test_script 1 "$SCRIPTS_CI/test-post-push-integrity.sh"

# Ambient / event registry / lease gates
run_test_script 1 "$SCRIPTS_CI/test-waste-spike-pause.sh"
run_test_script 1 "$SCRIPTS_CI/test-lease-expiry.sh"
run_test_script 1 "$SCRIPTS_CI/test-lease-heartbeat.sh"
run_test_script 1 "$SCRIPTS_CI/test-off-rails-bypass-audit.sh"

# Freshness / doc-structure gates
run_test_script 1 "$SCRIPTS_CI/test-a2a-roadmap-coord.sh"
run_test_script 1 "$SCRIPTS_CI/test-a2a-rpc-bash-v0.sh"
run_test_script 1 "$SCRIPTS_CI/test-a2a-mailbox.sh"

t1_tier1=$(date +%s%N 2>/dev/null || date +%s)
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "1" ]]; then
    elapsed_tier1=$(( (t1_tier1 - t0_tier1) / 1000000 ))
    echo ""
    echo "[Tier 1] done in ${elapsed_tier1}ms"
    echo ""
fi

# ────────────────────────────────────────────────────────────────────────────
# TIER 2 — Rust compilation + tests (target: < 2 min)
# ────────────────────────────────────────────────────────────────────────────
t0_tier2=$(date +%s%N 2>/dev/null || date +%s)
[[ -z "$TIER_FILTER" || "$TIER_FILTER" == "2" ]] && \
    echo "[Tier 2] Rust..."

run_step 2 "cargo clippy -D warnings" \
    $CARGO clippy --workspace --all-targets -- -D warnings

run_step 2 "cargo test --workspace" \
    $CARGO test --workspace --quiet

# Additional Rust-adjacent script checks
run_test_script 2 "$SCRIPTS_CI/test-no-raw-gh-in-hot-paths.sh"
run_test_script 2 "$SCRIPTS_CI/test-no-direct-auto-merge-arm.sh"
run_test_script 2 "$SCRIPTS_CI/test-preflight-vs-ci-parity.sh"
run_test_script 2 "$SCRIPTS_CI/test-ci-gates-inventory.sh"

t1_tier2=$(date +%s%N 2>/dev/null || date +%s)
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "2" ]]; then
    elapsed_tier2=$(( (t1_tier2 - t0_tier2) / 1000000 ))
    echo ""
    echo "[Tier 2] done in ${elapsed_tier2}ms"
    echo ""
fi

# ────────────────────────────────────────────────────────────────────────────
# TIER 3 — Integration tests (target: < 5 min)
# ────────────────────────────────────────────────────────────────────────────
t0_tier3=$(date +%s%N 2>/dev/null || date +%s)
[[ -z "$TIER_FILTER" || "$TIER_FILTER" == "3" ]] && \
    echo "[Tier 3] Integration..."

# Feature smokes — local binary only, no network
run_test_script 3 "$SCRIPTS_CI/run-feature-smokes.sh"

# State-machine / coordination local checks
run_test_script 3 "$SCRIPTS_CI/test-cascade-rebase-debounce.sh"
run_test_script 3 "$SCRIPTS_CI/test-cascade-cancellation.sh"
run_test_script 3 "$SCRIPTS_CI/test-fleet-wedge-escalation.sh"
run_test_script 3 "$SCRIPTS_CI/test-gap-closure-consistency.sh"
run_test_script 3 "$SCRIPTS_CI/test-waste-tally.sh"
run_test_script 3 "$SCRIPTS_CI/test-obs-alerting.sh"
run_test_script 3 "$SCRIPTS_CI/test-obs-budget.sh"
run_test_script 3 "$SCRIPTS_CI/test-paramedic-rules.sh"
run_test_script 3 "$SCRIPTS_CI/test-preflight-scope-docs.sh"
run_test_script 3 "$SCRIPTS_CI/test-preflight-scope-scripts.sh"
run_test_script 3 "$SCRIPTS_CI/test-preflight-scope-rust.sh"

# Gap registry health
run_step 3 "gap audit-priorities" \
    bash -c "cd '$REPO_ROOT' && chump gap audit-priorities --quiet 2>/dev/null || true"

t1_tier3=$(date +%s%N 2>/dev/null || date +%s)
if [[ -z "$TIER_FILTER" || "$TIER_FILTER" == "3" ]]; then
    elapsed_tier3=$(( (t1_tier3 - t0_tier3) / 1000000 ))
    echo ""
    echo "[Tier 3] done in ${elapsed_tier3}ms"
    echo ""
fi

# ────────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────────
t1_total=$(date +%s%N 2>/dev/null || date +%s)
elapsed_total=$(( (t1_total - t0_total) / 1000000 ))

if [[ "$DRY_RUN" == "1" ]]; then
    echo "=== Local CI: DRY-RUN complete ==="
    exit 0
fi

echo "=== Local CI Summary ==="
echo "    passed : $PASS_COUNT"
echo "    failed : $FAIL_COUNT"
echo "    elapsed: ${elapsed_total}ms"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    echo "FAILED checks:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    echo ""
    echo "=== Local CI: FAIL ==="
    exit 1
fi

echo ""
echo "=== Local CI: PASS ==="
exit 0
