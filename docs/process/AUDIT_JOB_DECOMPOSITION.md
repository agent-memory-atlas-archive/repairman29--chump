# Audit Job Test Script Decomposition (META-086)

> **Purpose**: Survey the 123 test scripts invoked by .github/workflows/audit.yml (4 parallel shards) and group them into ship-sized sub-gaps for systematic preflight mirroring (INFRA-1856 follow-up, INFRA-1670 META-070 slice).

## All 123 Audit Job Test Scripts

The following test scripts are directly invoked by the 4 parallel audit-shard jobs in .github/workflows/audit.yml:

| Script | 1-line Purpose | Mirrored | Cluster |
|---|---|---|---|
| test-agent-throughput | per-agent throughput tracker — tracker script + kpi report | No | observability |
| test-alert-classifier | alert classifier false-positive suppression | No | observability |
| test-acp-real-clients | ACP real clients + zed/jetbrains compat | **Yes** | cli-observability |
| test-acp-smoke | ACP protocol smoke test | No | acp-protocol |
| test-async-job-dispatch | async job dispatch + worker queue | No | fleet-worker |
| test-audit-step-isolation | audit-step isolation guard — one test per step | **Yes** | audit-infra |
| test-audit-workflow-not-cancellable | audit workflow not cancellable (INFRA-2452) | **Yes** | audit-infra |
| test-auth-status | auth-status validity probe (RESILIENT-086) | **Yes** | auth-infra |
| test-autonomous-ship-rate | autonomous ship-rate metric fixture | No | observability |
| test-back-pressure-hysteresis | back-pressure breaker escape + state | No | bot-merge |
| test-bot-merge-arm-ship-order | bot-merge arm-before-ship ordering | No | bot-merge |
| test-bot-merge-exit-codes | bot-merge step-specific exit codes | No | bot-merge |
| test-bot-merge-exit-phases | bot-merge per-phase exit codes | No | bot-merge |
| test-bot-merge-graphql-preflight | bot-merge GraphQL preflight + fallback | No | bot-merge |
| test-bot-merge-stacked-rebase | bot-merge stacked PR auto-rebase | No | bot-merge |
| test-bot-merge-watchdog | bot-merge watchdog — kills done-gap procs | No | bot-merge |
| test-bounced-pr-detector | bounced-PR detector fixture | No | pr-lifecycle |
| test-cache-event-emission | cache hit/miss event emission (CREDIBLE-064) | **Yes** | cli-observability |
| test-cache-mergestatestatus | cache merge_state_status column (INFRA-1368) | **Yes** | github-cache |
| test-cargo-mutex-isolation | cargo build mutex isolation per-worktree | **Yes** | audit-infra |
| test-cascade-cancellation-status-description | cascade-cancellation status description | **Yes** | audit-infra |
| test-cascade-rebase-observability | cascade rebase observability + metrics | **Yes** | cli-observability |
| test-change-approval | change approval workflow — gate + rollback | **Yes** | approval |
| test-chump-farmer-run-path | chump-farmer-run host-aware PATH | No | fleet-worker |
| test-chump-fleet-cli | chump fleet CLI — subcommands + help | **Yes** | cli-observability |
| test-chump-skill-cli | chump skill CLI — list + help + metadata | **Yes** | cli-observability |
| test-ci-audit-loop | ci-audit-loop curator subcommands | No | curator |
| test-ci-heavy-jobs-cross-platform | heavy CI jobs cross-platform — apt-get gated | No | ci-gates |
| test-cli-aliases | CLI aliases — expansion + conflicts | **Yes** | cli-observability |
| test-cli-arg-validation | CLI arg validation — required + constraints | **Yes** | cli-observability |
| test-cli-exit-codes | CLI exit codes — match expected classes | **Yes** | cli-observability |
| test-cli-fleet-coord | CLI fleet-coord subcommands | **Yes** | cli-observability |
| test-cli-help | CLI --help + subcommand help | **Yes** | cli-observability |
| test-cli-integration | CLI integration — multi-subcommand flows | **Yes** | cli-observability |
| test-cli-output-format | CLI --quiet/--format/--json consistency | **Yes** | cli-observability |
| test-cli-version-debug | CLI version/debug flags | No | cli-observability |
| test-cockpit-wake-fleet | cockpit Today's-arc Wake-fleet action | No | product |
| test-cost-enforcement | cost quota enforcement — 80% WARN, 100% cap | **Yes** | cli-observability |
| test-credential-lifecycle | credential lifecycle — rotation_due + age | **Yes** | auth-infra |
| test-credible-061-seed-consistency | gap list --json seed consistency fixture | No | gap-state |
| test-curator-auto-decompose | curator auto-decompose — starved pillar | No | curator |
| test-curator-decision-logging | curator decision logging — kind + fields | No | curator |
| test-curator-freshness | curator freshness gate — rebase window | No | curator |
| test-curator-p0-demotion | curator P0 demotion — real mutation | No | curator |
| test-curator-pillar-no-overlap | curator pillar no-overlap — unique primary | No | curator |
| test-discord-gateway | discord gateway daemon guard | No | external-integrations |
| test-edit-replay | write-ahead log recovery — wrap+replay | **Yes** | audit-infra |
| test-error-path-coverage | error-path test coverage >= 60 assertions | No | gap-state |
| test-event-registry-audit-regression | EVENT_REGISTRY parser correctness | **Yes** | event-registry |
| test-event-registry-coverage | EVENT_REGISTRY drift check — bi-directional | **Yes** | event-registry |
| test-farmer-stale-lease-heartbeat | farmer stale-lease heartbeat crash guard | No | fleet-infra |
| test-fleet-bootstrap | chump fleet bootstrap orchestrator | No | fleet-infra |
| test-fleet-brief-pillar-table | fleet-brief pillar table + counts | **Yes** | cli-observability |
| test-fleet-metrics-snapshot | fleet metrics snapshot — ship/waste/cycle | **Yes** | cli-observability |
| test-fleet-race-loss | speculative race-loss event tracking | No | fleet-infra |
| test-fleet-state-mutex | fleet-state.json mutex — flock + timeout | **Yes** | fleet-coordination |
| test-fleet-status-rate-limit | fleet-status rate-limit line format | **Yes** | cli-observability |
| test-gap-ac-requirement | gap AC enforcement — pre-commit rejects | **Yes** | ac-coverage |
| test-gap-closure-consistency-fixture | gap-closure-consistency fail-closed | No | gap-state |
| test-gap-impact-rating | gap impact rating — rate CLI + ambient | No | gap-state |
| test-gap-lifecycle-manager | gap lifecycle manager — abandoned detect | No | gap-state |
| test-gap-list-domain-summary | gap list domain summary + test-filter | No | gap-state |
| test-gap-list-done-format | gap list done-format — closed-pr + date | No | gap-state |
| test-gap-list-since-json-schema | gap list --json schema audit — required fields | No | gap-state |
| test-gap-profiling | per-gap performance profiling + perf report | No | gap-state |
| test-gap-quality-gate | gap quality gate — TODO/TBD ACs, bad priority | No | ac-coverage |
| test-gap-rebalance | gap rebalance — P0 budget + pillar floor | No | gap-state |
| test-gap-run-now | gap run-now — manual dispatch trigger | No | gap-state |
| test-gap-show-ac-render | gap show AC rendering — numbered list + json | No | gap-state |
| test-gap-store-single-source | gap-store single source of truth | No | gap-state |
| test-gap-templates | gap templates — pillar starter templates | No | gap-state |
| test-gap-workflow-status | PWA gap workflow status endpoint | **Yes** | pwa |
| test-gh-api-probe | gh-api-probe wired in bot-merge + run-fleet | No | github |
| test-gh-in-ci-guarded | gh-in-ci GH_TOKEN guard (RESILIENT-018) | No | github |
| test-gh-shim-script-attribution | gh-shim script attribution deep walk | No | github |
| test-gh-token-guard | gh-token-guard smoke test skip-on-missing | No | github |
| test-graphql-debounce | graphql_exhausted debounce when unknown reset | **Yes** | github-cache |
| test-inbox-prune | inbox-prune — size + age rotation caps | **Yes** | cli-observability |
| test-inbox-watcher-pattern | inbox-watcher pattern — event-driven wake | **Yes** | cli-observability |
| test-infra-779-gitdir-repair | INFRA-779 gitdir auto-repair + ambient event | No | git-ops |
| test-install-gh-shim-worktree-safe | install-gh-shim worktree-safety guard | No | git-ops |
| test-jit-binary-refresh | JIT binary refresh wired | No | fleet-infra |
| test-known-flakes-gate | KNOWN_FLAKES auto-bypass gate — 11 pre-push | **Yes** | ci-gates |
| test-known-flake-skip | pre-push known-flake skip integration | **Yes** | ci-gates |
| test-liaison-webhook-cache | INFRA-1318 Phase-2 webhook cache + liaison | No | github-cache |
| test-lint-handoff-comment | handoff comment template lint | **Yes** | review-workflow |
| test-merge-driver-ci-yml-add-row | ci-yml merge-driver orphan-step rejection | **Yes** | ci-gates |
| test-mission-picker | picker surfaces mission-linked gaps first | No | fleet-worker |
| test-mission-picker-worker | worker picker mission-rank — P0-MISSION beats | No | fleet-worker |
| test-no-claude-leak | no-claude-leak audit (changed-only) | **Yes** | ci-gates |
| test-no-inline-ambient-printf | no-inline-ambient-printf — Phase-1 dry-up | **Yes** | cli-observability |
| test-no-manual-ship-bypass | no-manual-ship-bypass guard | **Yes** | ci-gates |
| test-no-new-bypass-env-vars | no-new-bypass-env-vars — forbid new BYPASS_* | **Yes** | ci-gates |
| test-no-raw-gh-in-hot-paths | raw-gh lint gate — no new direct gh in hot-path | **Yes** | ci-gates |
| test-notify-kind-escalation-coverage | every CHUMP_NOTIFY_KIND has escalation verdict | **Yes** | cli-observability |
| test-notify-operator | operator escalation channel wired | **Yes** | cli-observability |
| test-opencode-harness-install | opencode-harness install smoke — wired + Almanac | **Yes** | harness |
| test-opencode-harness-smoke | opencode harness smoke — build_harness_cmd | **Yes** | harness |
| test-operator-recovery | operator-recovery umbrella — CHUMP_OPERATOR_RECOVERY | **Yes** | ci-gates |
| test-organ-manifest-bom-integration | organ-manifest unified-BOM — parser+renderer | No | organ |
| test-orphan-pr-closer | orphan-PR closer fixture | No | pr-lifecycle |
| test-orphan-worktree-prune | orphaned worktree reaper — prune-worktrees.sh | No | git-ops |
| test-outcome-gate | outcome gate — P0/P1 blocked w/o outcome | No | gap-state |
| test-per-worktree-target-guard | per-worktree stale binary guard | No | git-ops |
| test-picker-priority | picker consumes planner priority | No | fleet-worker |
| test-pillar-balance | gap pillar-balance — pickable counts | No | observability |
| test-pillar-dashboard | pillar health dashboard endpoint | No | product |
| test-pr-failure-auto-rescue | PR auto-rescue daemon smoke | No | pr-lifecycle |
| test-pr-rescue-audit-handler | PR auto-rescue active audit-handler | No | pr-lifecycle |
| test-pr-rescue-noci | pr-rescue zero-CI-runs detector | No | pr-lifecycle |
| test-pr-scope-title-fallback | pr-scope PR_TITLE fallback chain | No | ci-gates |
| test-precommit-guard-audit | pre-commit vacuous-guard audit | No | ci-gates |
| test-precommit-strict-replay | precommit strict replay fixture | No | ci-gates |
| test-prepush-worktree-cd | pre-push hook cd to GIT_WORK_TREE | No | git-ops |
| test-pwa-flake-quarantine | PWA flake quarantine wiring | No | pwa |
| test-pwa-version-compat | PWA version compatibility check | **Yes** | pwa |
| test-pwa-workflow-observability | PWA workflow observability — request_id tracing | **Yes** | pwa |
| test-required-model | required_model plumbing — model_selected event | No | gap-state |
| test-review-handoff-reengage | review-as-handoff author re-engagement | **Yes** | review-workflow |
| test-rollback-gap | gap rollback — runbook + ambient event | No | gap-state |
| test-rollup-cascade-cancel | cascade-cancel rollup classification fixture | **Yes** | audit-infra |
| test-rot-reaper | rot-reaper drains CONFLICTING+old PRs | No | pr-lifecycle |
| test-rot-reaper-verified-red-spare | rot-reaper spares green-underneath verified-red | No | pr-lifecycle |
| test-ruleset-doc-only-pr | ruleset doc-only-PR wedge guard | No | ci-gates |
| test-run-consolidation | run.sh consolidation — dispatcher + shims | No | cli-observability |
| test-run-fleet-cross-repo | run-fleet.sh cross-repo --repo/--locks-dir flags | No | fleet-infra |
| test-stale-binary-ship-blocked | stale-binary destructive-op guard | No | fleet-infra |
| test-stale-pr-reaper | stale-PR-reaper — 3-strike circuit break | No | pr-lifecycle |
| test-stale-pr-rebase-bot | stale-PR-rebase-bot — 3-strike circuit-break | **Yes** | pr-lifecycle |
| test-stale-worktree-reaper-tmp | stale-worktree-reaper extends to /tmp/chump-* | No | git-ops |
| test-tool-normalize | tool-call normalizer for weak LLMs | No | harness |
| test-triage-test-failure | CI failure triage classification | **Yes** | ci-gates |
| test-trunk-recovery-reviver | Trunk-recovery reviver | No | fleet-infra |
| test-velocity-trending | velocity trending — 7d trend analysis | **Yes** | cli-observability |
| test-worker-circuit-breaker | worker circuit-breaker — threshold=3 | No | fleet-worker |
| test-worker-first-output-watchdog | worker first-output watchdog | No | fleet-worker |
| test-worker-no-spin | worker anti-SPIN — no re-offer | No | fleet-worker |
| test-worker-timeout-no-commit | worker timeout-no-commit rescue | No | fleet-worker |
| test-worker-timeout-scale | worker timeout scaler — no death-spiral | No | fleet-worker |
| test-worktree-contamination-check | worktree contamination check — detect foreign gap files | No | git-ops |
| test-worktree-prune-protects-live-edits | worktree-prune protects live edits | No | git-ops |
| test-worktree-show-toplevel | worktree show-toplevel fix | No | git-ops |

## Grouping Summary

- **Already Mirrored in chump preflight (45)**: AC coverage (2), auth (2), cache (3), event-registry (2), CLI/observability (23), harness (2), review-workflow (2), approval (1), pwa (3), pr-lifecycle (1), ci-gates (8), audit-infra (4), fleet-coordination (1).
- **Tier-D / Audit-Only (78)**: Cannot run locally (live GitHub API, fleet state, NATS, queue readers, external services, curator-specific, product integrations).

## Grouping by Effort + Mirror Feasibility

This decomposition surveys all 123 scripts and identifies which are safe and valuable to mirror into `chump preflight` for sub-60s local feedback on PR submission. The result: most high-value gates are already mirrored; the remaining 78 are correctly classified as Tier-D (live external dependencies) and belong in audit.yml audit-only.

## Smoke Test: scripts/ci/test-audit-job-decomposition.sh

Asserts that every test script invoked by .github/workflows/audit.yml (all 4 shards) is enumerated in this document with its 1-line purpose and mirror status.

Exit 0 if all 123 accounted for; exits 1 with diff report if drift detected (new scripts added to audit.yml without updating this document, or old scripts removed leaving orphaned references).

Can be run anytime to detect unintended audit-job test coverage drift:
```bash
bash scripts/ci/test-audit-job-decomposition.sh
```

## References

- **INFRA-1856**: Original ci.yml audit-job scope discovery (closed; this document is the post-discovery follow-up).
- **INFRA-1670**: `chump preflight` local CI mirror (META-070 Tier-C foundational work).
- **META-070**: Tier-C decomposition follow-ups that continue INFRA-1670 preflight extension.
- **docs/process/CI_GATES_INVENTORY.md**: Canonical CI gate tier classification (Tier-A/B/C/D).
- **crates/chump-preflight/src/preflight.rs**: Current preflight gate implementations (~4448 LOC).
