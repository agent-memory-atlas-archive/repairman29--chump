#!/usr/bin/env bash
# run-remote-ci.sh — INFRA-2251 / INFRA-2246 offline-first roadmap Phase 1
#
# GitHub-API-dependent CI checks. These require network access (gh api, gh pr,
# curl to GitHub, etc.) and CANNOT run on airplane mode.
#
# This script is NOT part of the offline path. It runs in GitHub Actions CI
# and optionally locally when network is available.
#
# Usage:
#   bash scripts/ci/run-remote-ci.sh             # all remote checks
#   bash scripts/ci/run-remote-ci.sh --dry-run   # print what would run
#
# For the local (offline-safe) gate, see: scripts/ci/run-local-ci.sh
#
# Tests move here from run-local-ci.sh only when they use:
#   - gh api / gh pr / gh pr list / gh pr merge
#   - curl or wget to external URLs
#   - live GitHub state (PR status, check-run conclusions, etc.)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_CI="$REPO_ROOT/scripts/ci"

# ── Parse args ────────────────────────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()

t0_total=$(date +%s%N 2>/dev/null || date +%s)

run_step() {
    local name="$1"
    shift
    local cmd=("$@")

    if [[ "$DRY_RUN" == "1" ]]; then
        printf "  [DRY-RUN] %s: %s\n" "$name" "${cmd[*]}"
        return
    fi

    local t0
    t0=$(date +%s%N 2>/dev/null || date +%s)
    printf "  %s ... " "$name"

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

run_test_script() {
    local script="$1"
    local name
    name="$(basename "$script" .sh)"
    run_step "$name" bash "$script"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo "=== Chump Remote CI Gate (INFRA-2251) ==="
echo "    repo:   $REPO_ROOT"
echo "    date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    note:   requires GitHub API access (gh auth status)"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "    mode:   DRY-RUN"
fi
echo ""

# ── Guard: check gh auth ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
    if ! gh auth status &>/dev/null; then
        echo "ERROR: gh auth not configured. Run 'gh auth login' or set GH_TOKEN." >&2
        exit 2
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# Remote checks — GitHub API required
# ────────────────────────────────────────────────────────────────────────────
echo "[Remote] GitHub-API-dependent checks..."

# PR merge state / auto-merge checks
run_test_script "$SCRIPTS_CI/test-arm-auto-merge.sh"
run_test_script "$SCRIPTS_CI/test-auto-merge-armer.sh"
run_test_script "$SCRIPTS_CI/test-auto-arm-sweeper.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-dup-pr.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-graphql-preflight.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-hang-detection.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-hot-file-warning.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-rest-direct.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-stacked-rebase.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-arm-ship-order.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-gap-fatal.sh"
run_test_script "$SCRIPTS_CI/test-bot-autonomous.sh"
run_test_script "$SCRIPTS_CI/test-bot-merge-portability.sh"
run_test_script "$SCRIPTS_CI/test-branch-delete-on-merge.sh"
run_test_script "$SCRIPTS_CI/test-merge-queue-armed.sh"

# PR state / check runs
run_test_script "$SCRIPTS_CI/test-check-runs-cache.sh"
run_test_script "$SCRIPTS_CI/test-merged-check-guard.sh"
run_test_script "$SCRIPTS_CI/test-required-check-health.sh"
run_test_script "$SCRIPTS_CI/test-pr-auto-rebase.sh"
run_test_script "$SCRIPTS_CI/test-pr-auto-rebase-blocked.sh"
run_test_script "$SCRIPTS_CI/test-pr-auto-rebase-falsepositive.sh"
run_test_script "$SCRIPTS_CI/test-pr-create-gate.sh"
run_test_script "$SCRIPTS_CI/test-pr-rescue-cache-migration.sh"
run_test_script "$SCRIPTS_CI/test-pr-rescue-fork-aware.sh"
run_test_script "$SCRIPTS_CI/test-pr-rescue-rest-only.sh"
run_test_script "$SCRIPTS_CI/test-pr-stuck-announcer.sh"
run_test_script "$SCRIPTS_CI/test-pr-stuck-auto-respawn.sh"
run_test_script "$SCRIPTS_CI/test-pr-nudge.sh"
run_test_script "$SCRIPTS_CI/test-pr-rescue-audit-handler.sh"
run_test_script "$SCRIPTS_CI/test-pr-title-drift-detector.sh"
run_test_script "$SCRIPTS_CI/test-pr-triage.sh"

# GitHub-side admin / merge cycle
run_test_script "$SCRIPTS_CI/test-admin-merge-cycle-noise-class.sh"
run_test_script "$SCRIPTS_CI/test-all-gates-force-fire.sh"
run_test_script "$SCRIPTS_CI/test-autonomous-ship-rate.sh"
run_test_script "$SCRIPTS_CI/test-bounced-pr-detector.sh"
run_test_script "$SCRIPTS_CI/test-claim-open-pr-abort.sh"
run_test_script "$SCRIPTS_CI/test-closer-batcher-filing-pr.sh"
run_test_script "$SCRIPTS_CI/test-cluster-detector.sh"
run_test_script "$SCRIPTS_CI/test-fleet029-cache-overlap.sh"
run_test_script "$SCRIPTS_CI/test-gap-closure-reconcile.sh"
run_test_script "$SCRIPTS_CI/test-gap-already-satisfied.sh"
run_test_script "$SCRIPTS_CI/test-gap-workflow-status.sh"
run_test_script "$SCRIPTS_CI/test-gh-preempt.sh"
run_test_script "$SCRIPTS_CI/test-gh-self-throttle.sh"
run_test_script "$SCRIPTS_CI/test-gh-shim-auth-token-cache.sh"
run_test_script "$SCRIPTS_CI/test-gh-shim-pr-view-rewrite.sh"
run_test_script "$SCRIPTS_CI/test-github-api-telemetry.sh"
run_test_script "$SCRIPTS_CI/test-github-api-telemetry-shim.sh"
run_test_script "$SCRIPTS_CI/test-graphql-exhausted-signal.sh"
run_test_script "$SCRIPTS_CI/test-infra-1111-gh-backoff.sh"
run_test_script "$SCRIPTS_CI/test-infra-1129-check-runs-backfill.sh"
run_test_script "$SCRIPTS_CI/test-infra-1130-bot-merge-cache-checks.sh"
run_test_script "$SCRIPTS_CI/test-infra-119-bot-merge-hang.sh"
run_test_script "$SCRIPTS_CI/test-merge-group-coverage.sh"
run_test_script "$SCRIPTS_CI/test-operator-recall.sh"
run_test_script "$SCRIPTS_CI/test-operator-recall-channel.sh"
run_test_script "$SCRIPTS_CI/test-orphan-pr-closer.sh"
run_test_script "$SCRIPTS_CI/test-orphan-pr-closer-evidence.sh"
run_test_script "$SCRIPTS_CI/test-orphan-closer-immunity.sh"
run_test_script "$SCRIPTS_CI/test-pr-fix-clippy.sh"
run_test_script "$SCRIPTS_CI/test-stale-branch-rebase.sh"
run_test_script "$SCRIPTS_CI/test-stuck-pr-filer.sh"
run_test_script "$SCRIPTS_CI/test-stuck-pr-filer-shared-blocker.sh"

# API / webhook / external-URL tests
run_test_script "$SCRIPTS_CI/test-api-broadcast.sh"
run_test_script "$SCRIPTS_CI/test-api-chat-cost-kill.sh"
run_test_script "$SCRIPTS_CI/test-api-dashboard-shape.sh"
run_test_script "$SCRIPTS_CI/test-api-fleet-health.sh"
run_test_script "$SCRIPTS_CI/test-api-fleet-status-perf.sh"
run_test_script "$SCRIPTS_CI/test-api-gap-queue-perf.sh"
run_test_script "$SCRIPTS_CI/test-api-gap-queue-shape.sh"
run_test_script "$SCRIPTS_CI/test-api-inbox.sh"
run_test_script "$SCRIPTS_CI/test-api-release-expired.sh"
run_test_script "$SCRIPTS_CI/test-api-repo-init.sh"
run_test_script "$SCRIPTS_CI/test-api-roadmap.sh"
run_test_script "$SCRIPTS_CI/test-cache-n1-migration.sh"
run_test_script "$SCRIPTS_CI/test-check-pr-scope-title.sh"
run_test_script "$SCRIPTS_CI/test-chump-ship-execute.sh"
run_test_script "$SCRIPTS_CI/test-ci-flake-rerun.sh"
run_test_script "$SCRIPTS_CI/test-ci-qa-score.sh"
run_test_script "$SCRIPTS_CI/test-cockpit-action-endpoints.sh"
run_test_script "$SCRIPTS_CI/test-credible-001-incremental.sh"
run_test_script "$SCRIPTS_CI/test-fanout-reference-flag.sh"
run_test_script "$SCRIPTS_CI/test-fleet-brief-recap.sh"
run_test_script "$SCRIPTS_CI/test-fleet-scrubber.sh"
run_test_script "$SCRIPTS_CI/test-fleet-server.sh"
run_test_script "$SCRIPTS_CI/test-fleet-stalled-alert.sh"
run_test_script "$SCRIPTS_CI/test-fleet-wedge-escalation.sh"
run_test_script "$SCRIPTS_CI/test-infra-254-pwa-root-redirect.sh"
run_test_script "$SCRIPTS_CI/test-infra-559-checkpoint-integration.sh"
run_test_script "$SCRIPTS_CI/test-infra-watcher-loop.sh"
run_test_script "$SCRIPTS_CI/test-infra-watcher-pty-check.sh"
run_test_script "$SCRIPTS_CI/test-install-gh-shim.sh"
run_test_script "$SCRIPTS_CI/test-liaison-webhook-cache.sh"
run_test_script "$SCRIPTS_CI/test-liaison-webhook-health.sh"
run_test_script "$SCRIPTS_CI/test-main-health-watchdog.sh"
run_test_script "$SCRIPTS_CI/test-markdown-intra-doc-links.sh"
run_test_script "$SCRIPTS_CI/test-migration-pipeline-gates.sh"
run_test_script "$SCRIPTS_CI/test-no-direct-auto-merge-arm-fixture.sh"
run_test_script "$SCRIPTS_CI/test-obs-alerting.sh"
run_test_script "$SCRIPTS_CI/test-pwa-auth-middleware.sh"
run_test_script "$SCRIPTS_CI/test-pwa-auth-toast-stream.sh"
run_test_script "$SCRIPTS_CI/test-pwa-doctor-banner.sh"
run_test_script "$SCRIPTS_CI/test-pwa-e2e-gap-workflow.sh"
run_test_script "$SCRIPTS_CI/test-pwa-events-view.sh"
run_test_script "$SCRIPTS_CI/test-pwa-orchestrator-sessions-view.sh"
run_test_script "$SCRIPTS_CI/test-pwa-pr-actions.sh"
run_test_script "$SCRIPTS_CI/test-pwa-pr-list.sh"
run_test_script "$SCRIPTS_CI/test-pwa-repo-switcher.sh"
run_test_script "$SCRIPTS_CI/test-pwa-secrets-flow.sh"
run_test_script "$SCRIPTS_CI/test-pwa-security.sh"
run_test_script "$SCRIPTS_CI/test-pwa-sse-consumer.sh"
run_test_script "$SCRIPTS_CI/test-pwa-stuck-items.sh"
run_test_script "$SCRIPTS_CI/test-pwa-version-compat.sh"
run_test_script "$SCRIPTS_CI/test-pwa-workflow-observability.sh"
run_test_script "$SCRIPTS_CI/test-readme-links.sh"
run_test_script "$SCRIPTS_CI/test-recovery-queue.sh"
run_test_script "$SCRIPTS_CI/test-research-cursor-round.sh"
run_test_script "$SCRIPTS_CI/test-roadmap-update-agent.sh"
run_test_script "$SCRIPTS_CI/test-sccache-wired.sh"
run_test_script "$SCRIPTS_CI/test-ship-chassis-round.sh"
run_test_script "$SCRIPTS_CI/test-status.sh"
run_test_script "$SCRIPTS_CI/test-web-push-subscribe.sh"
run_test_script "$SCRIPTS_CI/test-webhook-cache-write.sh"
run_test_script "$SCRIPTS_CI/test-webhook-health-endpoint.sh"
run_test_script "$SCRIPTS_CI/test-webhook-pr-merge-prune.sh"
run_test_script "$SCRIPTS_CI/test-webhook-receiver.sh"
run_test_script "$SCRIPTS_CI/test-webpush-escalation.sh"
run_test_script "$SCRIPTS_CI/test-wizard-daemon.sh"
run_test_script "$SCRIPTS_CI/test-wizard-daemon-merge-state-parse.sh"

# ── Summary ───────────────────────────────────────────────────────────────────
t1_total=$(date +%s%N 2>/dev/null || date +%s)
elapsed_total=$(( (t1_total - t0_total) / 1000000 ))

if [[ "$DRY_RUN" == "1" ]]; then
    echo "=== Remote CI: DRY-RUN complete ==="
    exit 0
fi

echo ""
echo "=== Remote CI Summary ==="
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
    echo "=== Remote CI: FAIL ==="
    exit 1
fi

echo ""
echo "=== Remote CI: PASS ==="
exit 0
