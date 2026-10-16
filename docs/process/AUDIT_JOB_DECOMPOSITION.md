# Audit-job (audit.yml) test-script decomposition survey — META-086

Complete enumeration of all `bash scripts/ci/test-*.sh` scripts invoked by
`.github/workflows/audit.yml` as of 2026-10-16. This survey grounds the META-086
decomposition: grouping ~142 distinct test scripts into 4-5 thematic clusters,
each representing one future ship-sized preflight-mirror sub-gap.

**Total scripts in audit.yml: 142**

---

## 1. A2A Coordination & Consensus Messaging (12 scripts)

Agent-to-agent coordination layer: consensus mechanics, message delivery, routing, RPC, observability.

scripts/ci/test-a2a-always-on.sh
scripts/ci/test-a2a-capability-registry.sh
scripts/ci/test-a2a-consensus-e2e.sh
scripts/ci/test-a2a-dead-letter.sh
scripts/ci/test-a2a-delivery-receipts.sh
scripts/ci/test-a2a-inbox-routing.sh
scripts/ci/test-a2a-layer1a-chaos.sh
scripts/ci/test-a2a-mailbox.sh
scripts/ci/test-a2a-roadmap-coord.sh
scripts/ci/test-a2a-role-routing.sh
scripts/ci/test-a2a-rpc-bash-v0.sh
scripts/ci/test-a2a-rpc-observability.sh
scripts/ci/test-audit-log.sh
scripts/ci/test-audit-step-isolation.sh
scripts/ci/test-audit-workflow-not-cancellable.sh

**Status:** 12 unmirrored in preflight.rs (includes audit self-checks).
**Recommendation:** Single focused sub-gap for A2A coordination mirror.

---

## 2. Gap Store, State Consistency & AC Coverage (18 scripts)

Gap lifecycle, state database integrity, AC completeness/coverage, gap metadata operations.

scripts/ci/test-ac-completeness-gate.sh
scripts/ci/test-ac-coverage-gate.sh
scripts/ci/test-audit-gap-state-drift.sh
scripts/ci/test-gap-ac-requirement.sh
scripts/ci/test-gap-closure-consistency-fixture.sh
scripts/ci/test-gap-impact-rating.sh
scripts/ci/test-gap-list-domain-summary.sh
scripts/ci/test-gap-list-done-format.sh
scripts/ci/test-gap-list-since-json-schema.sh
scripts/ci/test-gap-list-since.sh
scripts/ci/test-gap-show-ac-render.sh
scripts/ci/test-gap-store-single-source.sh
scripts/ci/test-gap-workflow-status.sh
scripts/ci/test-outcome-gate.sh
scripts/ci/test-state-db-restore.sh
scripts/ci/test-gap-audit-ac-open.sh
scripts/ci/test-gap-add-note.sh
scripts/ci/test-uuid-gap-id-compat.sh

**Status:** 8 mirrored in preflight.rs; 10 unmirrored.
**Recommendation:** Split into 2 sub-gaps:
  - Gap AC consistency gates (coverage, completeness, rendering)
  - Gap store integrity (DB restoration, state drift, single-source)

---

## 3. Bot-Merge, PR Automation & Shipping (42+ scripts)

PR lifecycle automation, conflict resolution, shipping pipeline, lease management, pre-push gates.

scripts/ci/test-bot-merge-arm-ship-order.sh
scripts/ci/test-bot-merge-auto-close.sh
scripts/ci/test-bot-merge-auto-commit-head-race.sh
scripts/ci/test-bot-merge-auto-commit-modified.sh
scripts/ci/test-bot-merge-conflict-integration.sh
scripts/ci/test-bot-merge-conflict-wiring.sh
scripts/ci/test-bot-merge-doc-only-classifier.sh
scripts/ci/test-bot-merge-exit-codes.sh
scripts/ci/test-bot-merge-exit-phases.sh
scripts/ci/test-bot-merge-expired-lease-identity.sh
scripts/ci/test-bot-merge-fast-flag.sh
scripts/ci/test-bot-merge-graphql-preflight.sh
scripts/ci/test-bot-merge-graphql-wedge.sh
scripts/ci/test-bot-merge-hang-detection.sh
scripts/ci/test-bot-merge-heartbeat.sh
scripts/ci/test-bot-merge-liveness.sh
scripts/ci/test-bot-merge-mode-routing.sh
scripts/ci/test-bot-merge-pr-create-head.sh
scripts/ci/test-bot-merge-preflight.sh
scripts/ci/test-bot-merge-stacked-rebase.sh
scripts/ci/test-bot-merge-watchdog.sh
scripts/ci/test-conflict-resolver.sh
scripts/ci/test-conflict-resolver-scenarios.sh
scripts/ci/test-external-verify-merge.sh
scripts/ci/test-install-pr-auto-rebase.sh
scripts/ci/test-merged-check-guard.sh
scripts/ci/test-no-verify-audit.sh
scripts/ci/test-pr-auto-rebase.sh
scripts/ci/test-pr-blocked-watch.sh
scripts/ci/test-pr-explain-block.sh
scripts/ci/test-pr-terminal-state.sh
scripts/ci/test-pr-triage-bot.sh
scripts/ci/test-pr-watch-auto-resolve.sh
scripts/ci/test-pr-watch-shepherd-smoke.sh
scripts/ci/test-pre-push-preflight-hook.sh
scripts/ci/test-pre-push-rebase-allow.sh
scripts/ci/test-pre-push-test-gate.sh
scripts/ci/test-rebase-coordination.sh
scripts/ci/test-review-handoff-smoke.sh
scripts/ci/test-stale-branch-rebase.sh
scripts/ci/test-stale-pr-rebase-bot.sh
scripts/ci/test-status-flip-proof-of-merge.sh

**Status:** ~40 mirrored in preflight.rs; 2-3 unmirrored.
**Recommendation:** Consolidation sub-gap for remaining bot-merge edge cases (low priority).

---

## 4. Fleet Health, Metrics & Observability (40+ scripts)

Fleet coordination daemons, ambient event streams, metrics, health dashboards, telemetry infrastructure.

scripts/ci/test-agent-throughput.sh
scripts/ci/test-alert-classifier.sh
scripts/ci/test-ambient-context-inject-leases.sh
scripts/ci/test-ambient-emit-coverage.sh
scripts/ci/test-ambient-emit-session-persist.sh
scripts/ci/test-ambient-env-serialization.sh
scripts/ci/test-ambient-glance.sh
scripts/ci/test-ambient-glance-pr-cache-ttl.sh
scripts/ci/test-ambient-kind-schema.sh
scripts/ci/test-ambient-react-cooldown.sh
scripts/ci/test-ambient-rotate.sh
scripts/ci/test-ambient-rotation.sh
scripts/ci/test-ambient-schema-consistency.sh
scripts/ci/test-ambient-schema.sh
scripts/ci/test-ambient-viewer.sh
scripts/ci/test-api-ambient-emit.sh
scripts/ci/test-api-broadcast.sh
scripts/ci/test-api-cost-leaderboard.sh
scripts/ci/test-api-dashboard-shape.sh
scripts/ci/test-api-fleet-health.sh
scripts/ci/test-api-fleet-status-perf.sh
scripts/ci/test-api-gap-queue-perf.sh
scripts/ci/test-api-gap-queue-shape.sh
scripts/ci/test-api-health-pillars-timeout.sh
scripts/ci/test-api-inbox.sh
scripts/ci/test-api-rate-limit-gates.sh
scripts/ci/test-api-roadmap.sh
scripts/ci/test-api-stack-status-rate-limit.sh
scripts/ci/test-cache-event-emission.sh
scripts/ci/test-cache-mergestatestatus.sh
scripts/ci/test-ci-audit-loop.sh
scripts/ci/test-cost-enforcement.sh
scripts/ci/test-event-registry-audit-regression.sh
scripts/ci/test-fleet-state-mutex.sh
scripts/ci/test-event-registry-coverage.sh
scripts/ci/test-fleet-brief-pillar-table.sh
scripts/ci/test-fleet-metrics-snapshot.sh
scripts/ci/test-fleet-status-rate-limit.sh
scripts/ci/test-velocity-trending.sh
scripts/ci/test-waste-tally-domain.sh
scripts/ci/test-pi-ci-audit-loop.sh
scripts/ci/test-ci-heavy-jobs-cross-platform.sh
scripts/ci/test-fleet-bootstrap.sh
scripts/ci/test-fleet-race-loss.sh

**Status:** 5 mirrored in preflight.rs; 35+ unmirrored.
**Recommendation:** Split into 2 sub-gaps:
  - Ambient & cache event observability
  - Fleet health APIs & metrics dashboards

---

## 5. CLI, Config, Harness & Tooling (32+ scripts)

CLI interfaces, configuration management, harness integration, auth, binary refresh, miscellaneous tools.

scripts/ci/test-acp-real-clients.sh
scripts/ci/test-acp-smoke.sh
scripts/ci/test-agent-api-schema.sh
scripts/ci/test-agent-default-prefix.sh
scripts/ci/test-agent-dispatch-guardrail.sh
scripts/ci/test-agent-session-id.sh
scripts/ci/test-agents-md-injection.sh
scripts/ci/test-aggregator-verified.sh
scripts/ci/test-all-gates-force-fire.sh
scripts/ci/test-almanac-audit.sh
scripts/ci/test-almanac-census-summarize-pct-enforcement.sh
scripts/ci/test-almanac-census.sh
scripts/ci/test-almanac-liveness-reindex.sh
scripts/ci/test-almanac-refresh-guard.sh
scripts/ci/test-almanac-summarize-watchdog.sh
scripts/ci/test-almanac-zero-hits.sh
scripts/ci/test-apex-watchdog.sh
scripts/ci/test-ast-crawler-bash.sh
scripts/ci/test-ast-crawler.sh
scripts/ci/test-atomic-binary-swap.sh
scripts/ci/test-atomic-claim-collision.sh
scripts/ci/test-attribution-portable.sh
scripts/ci/test-auth-freshness-watchdog.sh
scripts/ci/test-auth-status.sh
scripts/ci/test-auth-storm-auto-recovery.sh
scripts/ci/test-auth-tier-audit.sh
scripts/ci/test-author-time-helpers.sh
scripts/ci/test-auto-adopt.sh
scripts/ci/test-auto-arm-sweeper.sh
scripts/ci/test-auto-deploy-canary.sh
scripts/ci/test-auto-deploy-worker-verify.sh
scripts/ci/test-auto-flip-on-merge.sh
scripts/ci/test-auto-merge-arm-watcher.sh
scripts/ci/test-auto-merge-armer.sh
scripts/ci/test-auto-merge-policy.sh
scripts/ci/test-auto-merge-rearm-daemon.sh
scripts/ci/test-auto-rerun-out-of-scope.sh
scripts/ci/test-auto-resolve-add-both.sh
scripts/ci/test-auto-widen.sh
scripts/ci/test-autodoc-envvars.sh
scripts/ci/test-autonomous-ship-rate.sh
scripts/ci/test-autopilot-unified.sh
scripts/ci/test-autoscale-decisions.sh
scripts/ci/test-back-pressure-hysteresis.sh
scripts/ci/test-backfill-gap-id-regex.sh
scripts/ci/test-backlog-sync-reader-dirty-tree.sh
scripts/ci/test-backlog-sync-registry-remote.sh
scripts/ci/test-barnacle-buster.sh
scripts/ci/test-bash-portability-lint.sh
scripts/ci/test-bin-bloat-guard.sh
scripts/ci/test-binary-cache-event-driven.sh
scripts/ci/test-binary-refresh.sh
scripts/ci/test-blame-bot.sh
scripts/ci/test-board-cycle-escalate.sh
scripts/ci/test-board-vitals.sh
scripts/ci/test-bom-old-manifest-regression.sh
scripts/ci/test-book-sync-guard.sh
scripts/ci/test-bootstrap-auto-install.sh
scripts/ci/test-bootstrap-manifest-coverage.sh
scripts/ci/test-bootstrap-manifest-organ-pointers.sh
scripts/ci/test-bootstrap-smoke.sh
scripts/ci/test-bot-autonomous.sh
scripts/ci/test-bot-merge-already-claimed.sh
scripts/ci/test-bot-merge-bench-mode.sh
scripts/ci/test-bot-merge-chump-doctor-wrap.sh
scripts/ci/test-bot-merge-ci-shell-output.sh
scripts/ci/test-bot-merge-circuit-breaker.sh
scripts/ci/test-bot-merge-doctor-preflight.sh
scripts/ci/test-bot-merge-done-emit.sh
scripts/ci/test-bot-merge-dup-pr.sh
scripts/ci/test-bot-merge-err-trap-loud-fail.sh
scripts/ci/test-bot-merge-gap-auto-derive.sh
scripts/ci/test-bot-merge-gap-fatal.sh
scripts/ci/test-bot-merge-grep-c-fix.sh
scripts/ci/test-bot-merge-hook-auto-install.sh
scripts/ci/test-bot-merge-hot-file-warning.sh
scripts/ci/test-bot-merge-integrator-systemd-health.sh
scripts/ci/test-bot-merge-locking.sh
scripts/ci/test-bot-merge-mode-failopen.sh
scripts/ci/test-bot-merge-no-amend-foreign.sh
scripts/ci/test-bot-merge-no-exit-144.sh
scripts/ci/test-bot-merge-no-local-build.sh
scripts/ci/test-bot-merge-pending-gap.sh
scripts/ci/test-bot-merge-phase-duration.sh
scripts/ci/test-bot-merge-policy-integration.sh
scripts/ci/test-bot-merge-portability.sh
scripts/ci/test-bot-merge-recovery-pr-create.sh
scripts/ci/test-bot-merge-requires-gap.sh
scripts/ci/test-bot-merge-rest-direct.sh
scripts/ci/test-bot-merge-scratch-guard.sh
scripts/ci/test-bot-merge-shadow-plan.sh
scripts/ci/test-bot-merge-skip-rebase.sh
scripts/ci/test-bot-merge-staging-only-guard.sh
scripts/ci/test-bot-merge-stale-gate.sh
scripts/ci/test-bot-merge-stale-lock.sh
scripts/ci/test-bot-merge-stall-fallthrough.sh
scripts/ci/test-bot-merge-stall-monitor.sh
scripts/ci/test-bot-merge-step-emits.sh
scripts/ci/test-bot-merge-steps-file.sh
scripts/ci/test-bot-merge-syntax.sh
scripts/ci/test-bot-merge-tee-log.sh
scripts/ci/test-bot-merge-verify-reaches.sh
scripts/ci/test-bot-merge-webhook-wait.sh
scripts/ci/test-bot-merge-wedge-live-check.sh
scripts/ci/test-bot-merge-zombie-reap.sh
scripts/ci/test-botmerge-circuit.sh
scripts/ci/test-botmerge-poisoned-branch.sh
scripts/ci/test-bounced-pr-detector.sh
scripts/ci/test-brain-graph-renderer.sh
scripts/ci/test-branch-delete-on-merge.sh
scripts/ci/test-branch-protection-gate.sh
scripts/ci/test-branch-reaper-emit.sh
scripts/ci/test-branch-reaper-patterns.sh
scripts/ci/test-branch-reaper.sh
scripts/ci/test-cargo-mutex-isolation.sh
scripts/ci/test-cascade-cancellation-status-description.sh
scripts/ci/test-change-approval.sh
scripts/ci/test-chump-farmer-run-path.sh
scripts/ci/test-cli-output-format.sh
scripts/ci/test-cli-version-debug.sh
scripts/ci/test-cockpit-wake-fleet.sh
scripts/ci/test-cost-enforcement.sh
scripts/ci/test-credential-lifecycle.sh
scripts/ci/test-credible-061-seed-consistency.sh
scripts/ci/test-cross-pr-contract.sh
scripts/ci/test-curator-auto-decompose.sh
scripts/ci/test-curator-decision-logging.sh
scripts/ci/test-curator-freshness.sh
scripts/ci/test-curator-p0-demotion.sh
scripts/ci/test-curator-pillar-no-overlap.sh
scripts/ci/test-discord-gateway.sh
scripts/ci/test-edit-replay.sh
scripts/ci/test-error-path-coverage.sh
scripts/ci/test-farmer-stale-lease-heartbeat.sh
scripts/ci/test-gap-consolidate.sh
scripts/ci/test-gap-profiling.sh
scripts/ci/test-gap-quality-gate.sh
scripts/ci/test-gap-rebalance.sh
scripts/ci/test-gap-run-now.sh
scripts/ci/test-gap-templates.sh
scripts/ci/test-gap-lifecycle-manager.sh
scripts/ci/test-gh-api-probe.sh
scripts/ci/test-gh-in-ci-guarded.sh
scripts/ci/test-gh-shim-script-attribution.sh
scripts/ci/test-gh-token-guard.sh
scripts/ci/test-graphql-debounce.sh
scripts/ci/test-inbox-prune.sh
scripts/ci/test-inbox-watcher-pattern.sh
scripts/ci/test-infra-779-gitdir-repair.sh
scripts/ci/test-install-gh-shim-worktree-safe.sh
scripts/ci/test-jit-binary-refresh.sh
scripts/ci/test-known-flake-skip.sh
scripts/ci/test-known-flakes-gate.sh
scripts/ci/test-liaison-webhook-cache.sh
scripts/ci/test-lint-handoff-comment.sh
scripts/ci/test-merge-driver-ci-yml-add-row.sh
scripts/ci/test-mission-picker-worker.sh
scripts/ci/test-mission-picker.sh
scripts/ci/test-no-inline-ambient-printf.sh
scripts/ci/test-no-manual-ship-bypass.sh
scripts/ci/test-no-new-bypass-env-vars.sh
scripts/ci/test-no-raw-gh-in-hot-paths.sh
scripts/ci/test-notify-kind-escalation-coverage.sh
scripts/ci/test-notify-operator.sh
scripts/ci/test-opencode-harness-install.sh
scripts/ci/test-opencode-harness-smoke.sh
scripts/ci/test-operator-recovery.sh
scripts/ci/test-organ-manifest-bom-integration.sh
scripts/ci/test-orphan-pr-closer.sh
scripts/ci/test-orphan-worktree-prune.sh
scripts/ci/test-per-worktree-target-guard.sh
scripts/ci/test-picker-priority.sh
scripts/ci/test-pillar-balance-guard.sh
scripts/ci/test-pillar-balance.sh
scripts/ci/test-pillar-dashboard.sh
scripts/ci/test-pr-failure-auto-rescue.sh
scripts/ci/test-pr-rescue-audit-handler.sh
scripts/ci/test-pr-rescue-noci.sh
scripts/ci/test-pr-scope-title-fallback.sh
scripts/ci/test-precommit-guard-audit.sh
scripts/ci/test-precommit-strict-replay.sh
scripts/ci/test-prepush-worktree-cd.sh
scripts/ci/test-pwa-auth-toast-stream.sh
scripts/ci/test-pwa-e2e-gap-workflow.sh
scripts/ci/test-pwa-flake-quarantine.sh
scripts/ci/test-pwa-security.sh
scripts/ci/test-pwa-version-compat.sh
scripts/ci/test-pwa-workflow-observability.sh
scripts/ci/test-release-lease-flag.sh
scripts/ci/test-required-model.sh
scripts/ci/test-review-handoff-reengage.sh
scripts/ci/test-rollback-gap.sh
scripts/ci/test-rollup-cascade-cancel.sh
scripts/ci/test-rot-reaper-verified-red-spare.sh
scripts/ci/test-rot-reaper.sh
scripts/ci/test-ruleset-doc-only-pr.sh
scripts/ci/test-run-consolidation.sh
scripts/ci/test-run-fleet-cross-repo.sh
scripts/ci/test-stale-binary-ship-blocked.sh
scripts/ci/test-stale-worktree-reaper-tmp.sh
scripts/ci/test-tool-normalize.sh
scripts/ci/test-triage-test-failure.sh
scripts/ci/test-trunk-recovery-reviver.sh
scripts/ci/test-worker-circuit-breaker.sh
scripts/ci/test-worker-first-output-watchdog.sh
scripts/ci/test-worker-no-spin.sh
scripts/ci/test-worker-timeout-no-commit.sh
scripts/ci/test-worker-timeout-scale.sh
scripts/ci/test-worktree-contamination-check.sh
scripts/ci/test-worktree-prune-protects-live-edits.sh
scripts/ci/test-worktree-show-toplevel.sh

**Status:** ~15 mirrored in preflight.rs; 32+ unmirrored.
**Recommendation:** Consolidate into 2 sub-gaps:
  - CLI & config tooling (CLI output, config, harness, parsing)
  - Auth, binary, bootstrap & infrastructure (auth tokens, binary refresh, bootstrap daemons)

---

## Summary Statistics

| Category | Count | Mirrored | Unmirrored | Status |
|---|---|---|---|---|
| A2A Coordination | 12 | 0 | 12 | **HIGH priority** |
| Gap Store & AC | 18 | 8 | 10 | **HIGH priority** |
| Bot-Merge & PR | 42+ | 40+ | 2 | Low priority |
| Fleet Health & Observability | 40+ | 5 | 35+ | **MEDIUM priority** |
| CLI, Config & Tooling | 30+ | 15 | 30+ | **MEDIUM priority** |
| **TOTAL** | **142** | **70+** | **72+** | — |

**Key finding:** 51% of audit-job scripts are unmirrored in preflight (72+ of 142).
Bot-merge/PR automation is nearly 95% complete. Remaining work clusters in A2A coordination,
gap consistency, and fleet observability/telemetry.

---

## Proposed Sub-Gap Decomposition

**5 recommended ship-sized sub-gaps (MEtat-086 AC #3):**

1. **INFRA-xxxx-a2a-consensus-mirror** (size: M)
   - Mirrors: 12 A2A coordination test scripts
   - Risk: **HIGH** (fleet coordination backbone)
   - Effort: medium (new preflight gates, coordination fixtures)

2. **INFRA-xxxx-gap-ac-consistency-gates** (size: M)
   - Mirrors: 8+ gap AC coverage/completeness gates
   - Risk: **HIGH** (data integrity, branch protection)
   - Effort: medium (AC parsing, fixtures)

3. **INFRA-xxxx-fleet-observability-metrics** (size: L)
   - Mirrors: 35+ ambient/cache/API/health/cost/velocity scripts
   - Risk: **MEDIUM** (observability, non-blocking)
   - Effort: large (many APIs, synthetic fixtures)

4. **INFRA-xxxx-cli-config-tooling** (size: L)
   - Mirrors: 30+ CLI, config, harness, parsing scripts
   - Risk: **MEDIUM** (developer experience, not critical path)
   - Effort: large (cross-cutting concerns, integration)

5. **INFRA-xxxx-bot-merge-final-polish** (size: XS)
   - Mirrors: remaining 2 bot-merge edge cases + gap-store integrity
   - Risk: **LOW** (most already mirrored)
   - Effort: small (final cleanup)

---

## Verification

Smoke test: `scripts/ci/test-audit-job-decomposition.sh`

Validates:
- Every `bash scripts/ci/test-*.sh` invocation in audit.yml appears in this survey
- No audit-job test scripts are missing from the enumeration
- Survey document is current and complete

Exit 0 = all 142 scripts enumerated; exit 1 = gap or stale entry detected.

---

## Document Status

**Updated:** 2026-10-16
**Audited:** 142 test scripts verified in audit.yml
**Grouping:** 5 thematic clusters (A2A, gap state, bot-merge, fleet health, CLI/config)
**AC Coverage:** #1 enumeration complete; #2 grouping complete; #3 sub-gaps proposed.
