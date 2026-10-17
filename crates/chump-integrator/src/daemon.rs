//! Integration daemon — lifecycle orchestrator.
//!
//! Runs a polling loop; each iteration:
//!
//! 1. **CLAIM** — lock the integration slot in NATS KV (atomic CAS).  Falls
//!    back to an advisory file lock when NATS is unavailable.
//!    1b. **SAMPLING** — deterministic hash of `cycle_id` decides live vs dry-run
//!        (Phase 2 gate, INFRA-2139). Emits `cycle_sampling_decision`.
//! 2. **SELECT** — call `cycle::select::select_candidates` against the
//!    NATS work-board (state.db fallback when NATS absent).
//! 3. **POLICY** — apply `policy::evaluate`; skip if below volume threshold.
//! 4. **MERGE** — call `cycle::merge_branch::build_integration_branch`.
//! 5. **PREFLIGHT** — shell out to `chump preflight` or
//!    `bash scripts/dev/cross-build-linux.sh`.
//! 6. **DECISION** — LIVE cycles push + create PR + auto-merge via `gh`;
//!    dry-run cycles log manifest + emit `integration_cycle_dry_run_completed`.
//!
//! ## LIVE-mode safety rails (SCALE-A, INFRA-2130)
//!
//! Before any cycle runs in LIVE mode (`dry_run = false`), the daemon checks:
//!
//! 1. **Trunk-RED gate** — reads `.chump-locks/trunk-red-detector-state.json`.
//!    If `is_red = true`, emits `integration_trunk_red_hold` and skips.
//! 2. **Batch cap** — candidates capped at `config.batch_max_live` (default 5)
//!    in addition to the general `max_batch`. Conservative v1 starting point.
//! 3. **`do-not-batch` label** — candidates with the configured label are
//!    excluded before the batch is assembled.
//! 4. **Circuit breaker** — on LIVE merge/push failure, emits
//!    `integration_cycle_failed`, rolls back the integration branch, and sets
//!    `circuit_broken = true` so the next cycle runs as dry-run.
//!
//! Emits ambient events at each step boundary:
//!
//! | Step | kind |
//! |---|---|
//! | cycle starts | `integration_cycle_started` |
//! | trunk-RED hold | `integration_trunk_red_hold` |
//! | sampling gate | `cycle_sampling_decision` |
//! | candidates selected | `integration_candidates_selected` |
//! | per-candidate merge | `integration_branch_merged` |
//! | preflight starts | `integration_preflight_started` |
//! | preflight fails | `integration_preflight_failed` |
//! | LIVE ship complete | `integration_cycle_completed` |
//! | LIVE ship failure | `integration_cycle_failed` |
//! | dry-run skip | `integration_dry_run_skip` |
//! | dry-run complete | `integration_cycle_dry_run_completed` |
//! | merge conflict | `integration_merge_conflict` |

use anyhow::{Context, Result};
use chrono::Utc;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

use crate::config::IntegratorConfig;
use crate::cycle::merge_branch::build_integration_branch;
use crate::cycle::select::{select_candidates, StateDbWorkBoard};
use crate::cycle::CycleManifest;
use crate::policy::{evaluate, PolicyDecision};
use crate::pr_body::{generate_pr_body, generate_pr_title, IntegrationPrInput};
use crate::sampling::sampling_decision;

use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_gap_store::GapFieldUpdate;

/// Integration slot key in the NATS KV `chump_gaps` bucket.
const INTEGRATION_SLOT_KEY: &str = "integration_slot";

/// Path to the trunk-RED detector state file (RESILIENT-050).
const TRUNK_RED_STATE_FILE: &str = ".chump-locks/trunk-red-detector-state.json";

/// The daemon polls the work-board and fires integration cycles.
pub struct IntegratorDaemon {
    pub config: IntegratorConfig,
    /// Path to the repo root (used for git operations).
    pub repo_root: PathBuf,
    /// Path to dry-run log file. Default: `~/.chump/integrator-dry-run.log`.
    pub dry_run_log: PathBuf,
    /// Optional chump-coord client (None when NATS unavailable).
    /// Wrapped in Arc so the Drop guard can hold a cheap clone.
    pub coord: Option<Arc<chump_coord::CoordClient>>,
    /// Circuit breaker: set to true when a LIVE cycle fails.
    /// The next cycle runs as dry-run regardless of config; resets on success.
    circuit_broken: Arc<AtomicBool>,
}

impl IntegratorDaemon {
    /// Create a daemon with defaults derived from env + repo root discovery.
    pub async fn new(repo_root: PathBuf) -> Result<Self> {
        let config = IntegratorConfig::from_env();
        let dry_run_log = Self::default_dry_run_log();
        let coord = chump_coord::CoordClient::connect_or_skip()
            .await
            .map(Arc::new);
        Ok(Self {
            config,
            repo_root,
            dry_run_log,
            coord,
            circuit_broken: Arc::new(AtomicBool::new(false)),
        })
    }

    fn default_dry_run_log() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".chump")
            .join("integrator-dry-run.log")
    }

    /// Run the daemon poll loop indefinitely.
    ///
    /// Each iteration fires one integration cycle attempt, then sleeps for
    /// `CHUMP_INTEGRATOR_POLL_S` seconds.
    pub async fn run(&self) -> Result<()> {
        eprintln!(
            "[integrator] starting (dry_run={}, poll={}s, volume_threshold={}, batch_max_live={})",
            self.config.dry_run,
            self.config.poll_interval.as_secs(),
            self.config.volume_threshold,
            self.config.batch_max_live,
        );

        loop {
            if let Err(e) = self.run_cycle().await {
                eprintln!("[integrator] cycle error: {e:#}");
            }
            tokio::time::sleep(self.config.poll_interval).await;
        }
    }

    /// Run one integration cycle. Returns Ok(()) even when the cycle is
    /// skipped; only hard errors (NATS unavailable and state.db unreadable)
    /// propagate as Err.
    pub async fn run_cycle(&self) -> Result<()> {
        // Cycle name uses datetime format per INFRA-2135 AC.
        // e.g. "integration-2026-05-29-1430"
        let cycle_name = datetime_cycle_name();
        let cycle_id = cycle_name.clone();

        // ── Step 0: LIVE-mode safety rails ────────────────────────────────
        // Determine whether this cycle runs LIVE before claiming the slot.
        // Circuit breaker: if the last LIVE cycle failed, force dry-run.
        let circuit_broken = self.circuit_broken.load(Ordering::SeqCst);
        let config_dry_run = self.config.dry_run || circuit_broken;

        if circuit_broken && !self.config.dry_run {
            eprintln!("[integrator] circuit breaker active — forcing dry-run for cycle {cycle_id}");
            emit_event(
                "integration_dry_run_skip",
                &[("cycle_id", &cycle_id), ("reason", "circuit_breaker")],
            );
        }

        // Trunk-RED gate: only relevant when we might go LIVE.
        if !config_dry_run && self.is_trunk_red() {
            eprintln!("[integrator] trunk is RED — holding LIVE cycle {cycle_id}");
            emit_event("integration_trunk_red_hold", &[("cycle_id", &cycle_id)]);
            return Ok(());
        }

        // Dirty-tree gate (EFFECTIVE-417): the cycle switches branches and builds
        // an integration branch off the working checkout — any uncommitted change
        // is carried into the batch. Observed 2026-08-08: a dry-run cycle dragged
        // 13 uncommitted gap-yamls onto the integration branch. Refuse on a dirty
        // tree so a batch never ships contaminated. Fail-closed: if git status
        // can't be read, hold (we can't prove the tree is clean).
        if self.working_tree_is_dirty() {
            eprintln!(
                "[integrator] working tree DIRTY — holding cycle {cycle_id} (uncommitted changes would contaminate the batch)"
            );
            emit_event("integration_dirty_tree_hold", &[("cycle_id", &cycle_id)]);
            return Ok(());
        }

        // ── Step 1: CLAIM ────────────────────────────────────────────────
        let claimed = self.try_claim_integration_slot(&cycle_id).await;
        if !claimed {
            eprintln!("[integrator] another cycle is active — skipping");
            return Ok(());
        }

        let _slot_guard = IntegrationSlotGuard {
            coord: self.coord.clone(),
        };

        let started_at = Utc::now().to_rfc3339();
        let preflight_start = std::time::Instant::now();

        emit_event("integration_cycle_started", &[("cycle_id", &cycle_id)]);

        // ── Step 1b: SAMPLING ─────────────────────────────────────────────
        // Deterministic hash of cycle_id decides live vs dry-run for this
        // cycle. `config_dry_run=true` always overrides to DRY-RUN regardless
        // of sampling_pct. This gate is the Phase 2 knob.
        let (sample_decision, sample_roll) = sampling_decision(&cycle_id, self.config.sampling_pct);

        let cycle_is_live = !config_dry_run && sample_decision.is_live();

        emit_event(
            "cycle_sampling_decision",
            &[
                ("cycle_id", &cycle_id),
                ("roll", &sample_roll.to_string()),
                ("threshold", &self.config.sampling_pct.to_string()),
                ("decision", sample_decision.as_str()),
                ("dry_run_override", &config_dry_run.to_string()),
                ("cycle_is_live", &cycle_is_live.to_string()),
            ],
        );
        eprintln!(
            "[integrator] sampling: roll={} threshold={} decision={} live={}",
            sample_roll,
            self.config.sampling_pct,
            sample_decision.as_str(),
            cycle_is_live,
        );

        // ── Step 2: SELECT ────────────────────────────────────────────────
        let all_candidates = self.select_candidates().await?;

        // Apply LIVE-mode filters: do-not-batch label exclusion + batch cap.
        let candidates = if cycle_is_live {
            let filtered: Vec<_> = all_candidates
                .into_iter()
                .filter(|c| !self.has_do_not_batch_label(c))
                .collect();
            // Cap at batch_max_live (conservative v1 limit).
            filtered
                .into_iter()
                .take(self.config.batch_max_live)
                .collect::<Vec<_>>()
        } else {
            all_candidates
        };

        // ── Step 3: POLICY ────────────────────────────────────────────────
        match evaluate(&candidates, &self.config) {
            PolicyDecision::Skip(reason) => {
                eprintln!("[integrator] cycle {cycle_id} skipped: {reason}");
                return Ok(());
            }
            PolicyDecision::Proceed => {}
            PolicyDecision::StaleSla { oldest_stale_hours } => {
                // Stale-SLA fallback (INFRA-2418): below volume threshold but at
                // least one candidate has aged past the SLA. Proceed with what
                // we have and emit the ambient signal so operators can observe.
                eprintln!(
                    "[integrator] stale-SLA fired: {} candidate(s) aged {}h >= SLA {}h — proceeding",
                    candidates.len(),
                    oldest_stale_hours,
                    self.config.stale_sla_hours,
                );
                emit_event(
                    "integrator_stale_sla_fired",
                    &[
                        ("cycle_id", &cycle_id),
                        ("candidates_shipped", &candidates.len().to_string()),
                        ("oldest_stale_hours", &oldest_stale_hours.to_string()),
                        ("threshold", &self.config.volume_threshold.to_string()),
                    ],
                );
            }
        }

        emit_event(
            "integration_candidates_selected",
            &[
                ("cycle_id", &cycle_id),
                ("count", &candidates.len().to_string()),
                (
                    "gap_ids",
                    &candidates
                        .iter()
                        .map(|c| c.gap_id.as_str())
                        .collect::<Vec<_>>()
                        .join(","),
                ),
            ],
        );

        let manifest = CycleManifest::new(cycle_id.clone(), candidates.clone());

        // ── Step 4: MERGE ─────────────────────────────────────────────────
        // Integration branch named after the cycle for traceability.
        let integration_branch = format!("chump/{}", cycle_name);
        let merge_outcome = match self.run_merge(&candidates, &integration_branch).await {
            Ok(outcome) => outcome,
            Err(e) => {
                eprintln!("[integrator] merge step failed: {e:#}");
                return Ok(());
            }
        };

        // RESILIENT-269: conflicting/stale candidates are SKIPPED by
        // build_integration_branch (like CREDIBLE-158 fetch-failures), not a
        // cycle-abort. Emit one event per skipped conflict for audit, then keep
        // going as long as *something* merged cleanly. Only abort when the batch
        // is empty — a batch of zero is nothing to ship. This is what lets one
        // bad branch be dropped while the rest of the batch still lands.
        for conflict in &merge_outcome.conflicts {
            emit_event(
                "integration_merge_conflict",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_id", &conflict.gap_id),
                    ("files", &conflict.conflicted_files.join(",")),
                ],
            );
            eprintln!(
                "[integrator] cycle {cycle_id} skipped {} on merge conflict — shipping the rest",
                conflict.gap_id
            );
        }

        if merge_outcome.merged_gaps.is_empty() {
            eprintln!(
                "[integrator] cycle {cycle_id} aborted — no candidate merged cleanly ({} skipped)",
                merge_outcome.conflicts.len()
            );
            return Ok(());
        }

        for mg in &merge_outcome.merged_gaps {
            emit_event(
                "integration_branch_merged",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_id", &mg.gap_id),
                    ("merge_sha", &mg.merge_sha),
                ],
            );
        }

        // ── Step 5: PREFLIGHT + bisect-quarantine loop (INFRA-2137) ──────────
        // Max 3 quarantine cycles: on each preflight failure we bisect to find
        // the offending gap, quarantine it, rebuild the integration branch
        // without it, and retry.  After 3 quarantine passes we abort entirely.
        const MAX_QUARANTINE_CYCLES: usize = 3;
        // RESILIENT-269: only the gaps that actually merged are in the
        // integration branch — quarantine/bisect must operate on those, not on
        // the full candidate set (which still includes the skipped conflicts).
        let merged_ids: std::collections::HashSet<&str> = merge_outcome
            .merged_gaps
            .iter()
            .map(|mg| mg.gap_id.as_str())
            .collect();
        let mut remaining_candidates: Vec<_> = candidates
            .iter()
            .filter(|c| merged_ids.contains(c.gap_id.as_str()))
            .cloned()
            .collect();
        let mut quarantine_count: usize = 0;

        loop {
            if remaining_candidates.is_empty() {
                eprintln!("[integrator] no candidates remain after quarantine — aborting cycle {cycle_id}");
                return Ok(());
            }

            emit_event(
                "integration_preflight_started",
                &[("cycle_id", &cycle_id), ("branch", &integration_branch)],
            );

            let preflight_ok = self.run_preflight(&integration_branch).await;

            if preflight_ok {
                // Preflight passed — proceed to DECISION below.
                break;
            }

            emit_event(
                "integration_preflight_failed",
                &[("cycle_id", &cycle_id), ("branch", &integration_branch)],
            );
            eprintln!("[integrator] preflight FAILED for cycle {cycle_id} (quarantine_count={quarantine_count})");

            if quarantine_count >= MAX_QUARANTINE_CYCLES {
                eprintln!(
                    "[integrator] reached max quarantine cycles ({MAX_QUARANTINE_CYCLES}) — aborting cycle {cycle_id}"
                );
                return Ok(());
            }
            quarantine_count += 1;

            // Bisect: identify the offending gap (currently: first candidate as
            // a conservative heuristic; INFRA-2136 replaces with git-bisect oracle).
            let offending = remaining_candidates[0].clone();
            eprintln!(
                "[integrator] quarantining {} (cycle {cycle_id}, pass {quarantine_count})",
                offending.gap_id
            );

            // Quarantine in state.db.
            if let Ok(store) = chump_gap_store::GapStore::open(&self.repo_root) {
                let reason = format!(
                    "Quarantined from integration-{cycle_id}: preflight failure (quarantine pass {quarantine_count})"
                );
                let _ = store.set_fields(
                    &offending.gap_id,
                    GapFieldUpdate {
                        status: Some("bisect_quarantined".to_string()),
                        ..Default::default()
                    },
                );
                let _ = store.append_notes_for_gap(&offending.gap_id, &reason);
            }

            // Emit ambient bisect_quarantine event.
            emit_event(
                "bisect_quarantine",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_id", &offending.gap_id),
                    ("quarantine_pass", &quarantine_count.to_string()),
                ],
            );

            // Post to work-board for operator review (best-effort; NATS may be absent).
            if let Some(coord) = &self.coord {
                use chump_coord::work_board::{Requirement, Subtask};
                let mut subtask = Subtask::new(
                    &offending.gap_id,
                    &format!(
                        "Manual review needed: {} failed integration {}",
                        offending.gap_id, cycle_id
                    ),
                    "chump-integrator",
                    Requirement {
                        task_class: "bisect-review".to_string(),
                        ..Default::default()
                    },
                );
                subtask.description = format!(
                    "Gap {} was quarantined by the integration daemon on cycle {} \
                     (quarantine pass {}). Run `chump gap requeue {}` after fixing \
                     the underlying failure.",
                    offending.gap_id, cycle_id, quarantine_count, offending.gap_id
                );
                if let Err(e) = coord.post_subtask(&subtask).await {
                    eprintln!("[integrator] work-board post failed (best-effort): {e:#}");
                }
            }

            // Remove offending gap from remaining candidates and rebuild branch.
            remaining_candidates.retain(|c| c.gap_id != offending.gap_id);

            if remaining_candidates.is_empty() {
                eprintln!(
                    "[integrator] no candidates remain after quarantining {} — aborting",
                    offending.gap_id
                );
                return Ok(());
            }

            // Rebuild integration branch without the offending gap.
            let _ = tokio::process::Command::new("git")
                .args(["checkout", "-B", &integration_branch, "HEAD"])
                .current_dir(&self.repo_root)
                .status()
                .await;
            match build_integration_branch(
                &remaining_candidates,
                &integration_branch,
                &self.repo_root,
            )
            .await
            {
                Ok(_) => {
                    eprintln!(
                        "[integrator] rebuilt integration branch without {} — retrying preflight",
                        offending.gap_id
                    );
                }
                Err(e) => {
                    eprintln!("[integrator] failed to rebuild integration branch: {e:#}");
                    return Ok(());
                }
            }
        }

        // Capture elapsed time for PR body (INFRA-2135).
        let preflight_duration = format!("{}s", preflight_start.elapsed().as_secs());

        // ── Step 6: DECISION ─────────────────────────────────────────────
        // Step 6a: generate PR body from template (INFRA-2135).
        let pr_input = IntegrationPrInput::from_cycle(
            &cycle_name,
            "volume_threshold reached",
            &started_at,
            &preflight_duration,
            &candidates,
            &merge_outcome,
        );
        let pr_title = generate_pr_title(&pr_input);
        let pr_body = generate_pr_body(&pr_input, &self.repo_root);

        let gap_ids = manifest
            .candidates
            .iter()
            .map(|c| c.gap_id.as_str())
            .collect::<Vec<_>>()
            .join(",");

        if cycle_is_live {
            // LIVE SHIP path: push integration branch, open PR, arm auto-merge.
            eprintln!(
                "[integrator] LIVE SHIP cycle={cycle_id} gaps=[{gap_ids}] loc={}",
                manifest.total_loc,
            );
            eprintln!("[integrator] PR title ready: {pr_title}");

            // Persist PR body preview alongside dry-run output for inspection.
            let _ = self.write_pr_body_preview(&cycle_name, &pr_body);

            match self
                .ship_integration_branch(&integration_branch, &cycle_id, &manifest)
                .await
            {
                Ok(pr_url) => {
                    // Clear circuit breaker on success.
                    self.circuit_broken.store(false, Ordering::SeqCst);
                    emit_event(
                        "integration_cycle_completed",
                        &[
                            ("cycle_id", &cycle_id),
                            ("gap_count", &manifest.candidates.len().to_string()),
                            ("total_loc", &manifest.total_loc.to_string()),
                            ("gap_ids", &gap_ids),
                            ("pr_url", &pr_url),
                        ],
                    );
                    // Also emit the legacy shipped event for kpi-report consumers.
                    emit_event(
                        "integration_cycle_shipped",
                        &[
                            ("cycle_id", &cycle_id),
                            ("gap_count", &manifest.candidates.len().to_string()),
                            ("total_loc", &manifest.total_loc.to_string()),
                            ("gap_ids", &gap_ids),
                            ("stubbed", "false"),
                        ],
                    );
                }
                Err(e) => {
                    eprintln!("[integrator] LIVE ship FAILED cycle={cycle_id}: {e:#}");
                    // Circuit breaker: next cycle runs as dry-run.
                    self.circuit_broken.store(true, Ordering::SeqCst);
                    // Roll back the integration branch.
                    self.rollback_integration_branch(&integration_branch).await;
                    emit_event(
                        "integration_cycle_failed",
                        &[
                            ("cycle_id", &cycle_id),
                            ("gap_ids", &gap_ids),
                            ("error", &format!("{e:#}")),
                            ("circuit_breaker", "armed"),
                        ],
                    );
                }
            }
        } else {
            // DRY-RUN: log manifest + emit dry-run completed event.
            let summary = manifest.dry_run_summary();
            eprintln!("[integrator] DRY-RUN: {summary}");
            eprintln!("[integrator] PR title: {pr_title}");
            self.write_dry_run_log(&manifest)
                .with_context(|| "writing dry-run log")?;
            self.write_pr_body_preview(&cycle_name, &pr_body)
                .with_context(|| "writing PR body preview")?;
            emit_event(
                "integration_cycle_dry_run_completed",
                &[
                    ("cycle_id", &cycle_id),
                    ("gap_count", &manifest.candidates.len().to_string()),
                    ("total_loc", &manifest.total_loc.to_string()),
                    (
                        "gap_ids",
                        &manifest
                            .candidates
                            .iter()
                            .map(|c| c.gap_id.as_str())
                            .collect::<Vec<_>>()
                            .join(","),
                    ),
                    ("pr_title", &pr_title),
                ],
            );
        }

        Ok(())
    }

    // ── safety-rail helpers ───────────────────────────────────────────────

    /// Returns true if trunk-red-detector-state.json signals trunk is RED.
    ///
    /// Reads `{repo_root}/.chump-locks/trunk-red-detector-state.json` and
    /// checks the `is_red` boolean field. Missing file or parse error → false
    /// (safe default: don't block on detector absence).
    fn is_trunk_red(&self) -> bool {
        let state_path = self.repo_root.join(TRUNK_RED_STATE_FILE);
        let Ok(bytes) = std::fs::read(&state_path) else {
            return false;
        };
        let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            eprintln!("[integrator] trunk-red state file unreadable; assuming not red");
            return false;
        };
        val.get("is_red").and_then(|v| v.as_bool()).unwrap_or(false)
    }

    /// Returns true if the repo working tree has uncommitted changes.
    ///
    /// The integration cycle switches branches and builds an integration branch
    /// off `repo_root`; a dirty tree carries uncommitted files into the batch
    /// (observed 2026-08-08, EFFECTIVE-417). Fail-closed: a `git status` error
    /// returns `true` (hold) — we can't prove the tree is clean, so don't ship.
    fn working_tree_is_dirty(&self) -> bool {
        git_working_tree_dirty(&self.repo_root)
    }

    /// Returns true if a candidate has the do-not-batch label.
    ///
    /// Checks three surfaces (case-insensitive):
    ///   1. `candidate.tags` — comma-separated tags from the work-board
    ///      (the authoritative surface; set on the originating gap).
    ///   2. `candidate.branch` — proxy for branches named after the label.
    ///   3. `candidate.author` — proxy for author logins that embed the label.
    ///
    /// Surfaces 2 and 3 catch the case where the operator names a branch or
    /// author to encode intent but never sets the tag on the gap.
    fn has_do_not_batch_label(&self, candidate: &crate::cycle::GapCandidate) -> bool {
        Self::candidate_has_label(&self.config.do_not_batch_label, candidate)
    }

    /// Pure helper for `has_do_not_batch_label` — extracted for unit testing.
    fn candidate_has_label(label: &str, candidate: &crate::cycle::GapCandidate) -> bool {
        let label = label.to_lowercase();
        if label.is_empty() {
            return false;
        }
        let tag_matches = candidate
            .tags
            .split(',')
            .any(|t| t.trim().to_lowercase() == label);
        let author_matches = candidate
            .author
            .as_deref()
            .unwrap_or("")
            .to_lowercase()
            .contains(&label);
        let branch_matches = candidate.branch.to_lowercase().contains(&label);
        tag_matches || author_matches || branch_matches
    }

    /// Push the integration branch, open a PR, and arm auto-merge.
    ///
    /// Returns the PR URL on success. On any failure the caller triggers
    /// the circuit breaker and calls `rollback_integration_branch`.
    async fn ship_integration_branch(
        &self,
        branch: &str,
        cycle_id: &str,
        manifest: &CycleManifest,
    ) -> Result<String> {
        let repo = &self.repo_root;
        let gap_ids: Vec<&str> = manifest
            .candidates
            .iter()
            .map(|c| c.gap_id.as_str())
            .collect();
        let gap_list = gap_ids.join(", ");

        // 1. Push the integration branch.
        let push_status = tokio::process::Command::new("git")
            .args(["push", "-u", "origin", branch, "--force-with-lease"])
            .current_dir(repo)
            .status()
            .await
            .with_context(|| format!("git push for branch {branch}"))?;

        if !push_status.success() {
            anyhow::bail!("git push failed for branch {branch}");
        }

        // 2. Create the PR via gh cli.
        let pr_title = format!(
            "feat(SCALE-A): integration-{cycle_id} — batch {} gaps",
            manifest.candidates.len()
        );
        let pr_body = format!(
            "Batched integration cycle `{cycle_id}`.\n\n\
             Gaps: {gap_list}\n\
             Total estimated LOC: {}\n\n\
             Batched-Under: {branch}\n\
             Integration-Cycle-Id: {cycle_id}\n",
            manifest.total_loc,
        );

        let pr_output = tokio::process::Command::new("gh")
            .args([
                "pr", "create", "--base", "main", "--head", branch, "--title", &pr_title, "--body",
                &pr_body,
            ])
            .current_dir(repo)
            .output()
            .await
            .with_context(|| "gh pr create")?;

        if !pr_output.status.success() {
            let stderr = String::from_utf8_lossy(&pr_output.stderr);
            anyhow::bail!("gh pr create failed: {stderr}");
        }

        let pr_url = String::from_utf8_lossy(&pr_output.stdout)
            .trim()
            .to_string();

        // 3. Extract PR number and arm auto-merge.
        // gh pr create outputs the PR URL as the last line; parse number from it.
        let pr_number = pr_url
            .rsplit('/')
            .next()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .with_context(|| format!("could not parse PR number from gh output: {pr_url}"))?;

        if !arm_integration_pr(pr_number, repo).await? {
            eprintln!("[integrator] LIVE ship: PR #{pr_number} ({pr_url}) is HELD by the arm policy — left unarmed");
            return Ok(pr_url);
        }

        eprintln!("[integrator] LIVE ship complete: PR #{pr_number} ({pr_url}) — auto-merge armed");
        Ok(pr_url)
    }

    /// Roll back the integration branch to HEAD on main.
    ///
    /// Best-effort: errors are logged but not propagated so the circuit
    /// breaker path completes cleanly.
    async fn rollback_integration_branch(&self, branch: &str) {
        eprintln!("[integrator] rolling back integration branch {branch}");
        let result = tokio::process::Command::new("git")
            .args(["branch", "-D", branch])
            .current_dir(&self.repo_root)
            .status()
            .await;
        match result {
            Ok(s) if s.success() => {
                eprintln!("[integrator] rollback complete: deleted local branch {branch}");
            }
            Ok(s) => {
                eprintln!(
                    "[integrator] rollback: git branch -D {branch} exited {}",
                    s.code().unwrap_or(-1)
                );
            }
            Err(e) => {
                eprintln!("[integrator] rollback: could not delete branch {branch}: {e:#}");
            }
        }
    }

    // ── core helpers ──────────────────────────────────────────────────────

    async fn try_claim_integration_slot(&self, cycle_id: &str) -> bool {
        if let Some(coord) = &self.coord {
            match coord.try_claim_gap(INTEGRATION_SLOT_KEY, cycle_id).await {
                Ok(claimed) => claimed,
                Err(e) => {
                    eprintln!("[integrator] NATS slot claim error: {e:#}; proceeding without lock");
                    true // degrade gracefully
                }
            }
        } else {
            // NATS unavailable — proceed without distributed lock.
            eprintln!("[integrator] NATS unavailable; integration slot lock skipped");
            true
        }
    }

    async fn select_candidates(&self) -> Result<Vec<crate::cycle::GapCandidate>> {
        // Try NATS work-board first; fall back to state.db.
        // Phase 1: always use state.db path (NATS work-board protocol is
        // defined by subtasks, not gaps — future phase will wire this up).
        let store = chump_gap_store::GapStore::open(&self.repo_root)
            .with_context(|| "opening state.db for candidate selection")?;

        let rows = store
            .list(Some("ready_to_ship"))
            .with_context(|| "listing ready_to_ship gaps")?;

        if rows.is_empty() {
            eprintln!("[integrator] state.db fallback: no ready_to_ship gaps");
        } else {
            eprintln!(
                "[integrator] state.db fallback: {} ready_to_ship gap(s)",
                rows.len()
            );
        }

        let board = StateDbWorkBoard::from_gap_rows(rows);
        Ok(select_candidates(
            &board,
            self.config.max_batch,
            self.config.loc_budget,
        ))
    }

    async fn run_merge(
        &self,
        candidates: &[crate::cycle::GapCandidate],
        integration_branch: &str,
    ) -> Result<crate::cycle::merge_branch::IntegrationBranchOutcome> {
        // Ensure integration branch exists.
        let _ = tokio::process::Command::new("git")
            .args(["checkout", "-B", integration_branch, "HEAD"])
            .current_dir(&self.repo_root)
            .status()
            .await;

        build_integration_branch(candidates, integration_branch, &self.repo_root).await
    }

    async fn run_preflight(&self, branch: &str) -> bool {
        let timeout = self.config.preflight_timeout;
        let repo = &self.repo_root;

        // Prefer `chump preflight` if available, else cross-build-linux.sh.
        let chump_bin = which_chump(repo);
        let result = if let Some(bin) = chump_bin {
            run_with_timeout(
                tokio::process::Command::new(bin)
                    .arg("preflight")
                    .current_dir(repo),
                timeout,
            )
            .await
        } else {
            let script = repo.join("scripts/dev/cross-build-linux.sh");
            if script.exists() {
                run_with_timeout(
                    tokio::process::Command::new("bash")
                        .args([script.to_str().unwrap(), "-p", "chump-integrator"])
                        .current_dir(repo),
                    timeout,
                )
                .await
            } else {
                eprintln!(
                    "[integrator] preflight: neither `chump preflight` nor \
                     scripts/dev/cross-build-linux.sh found; skipping (pass)"
                );
                return true;
            }
        };

        match result {
            Ok(status) => {
                if status {
                    eprintln!("[integrator] preflight passed (branch={branch})");
                } else {
                    eprintln!("[integrator] preflight FAILED (branch={branch})");
                }
                status
            }
            Err(e) => {
                eprintln!("[integrator] preflight error: {e:#}");
                false
            }
        }
    }

    fn write_pr_body_preview(&self, cycle_name: &str, pr_body: &str) -> Result<()> {
        if let Some(parent) = self.dry_run_log.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let path = self
            .dry_run_log
            .parent()
            .unwrap_or(std::path::Path::new("/tmp"))
            .join(format!("{cycle_name}-pr-body.md"));
        std::fs::write(&path, pr_body)?;
        eprintln!("[integrator] PR body preview written to {}", path.display());
        Ok(())
    }

    fn write_dry_run_log(&self, manifest: &CycleManifest) -> Result<()> {
        // Ensure ~/.chump/ exists.
        if let Some(parent) = self.dry_run_log.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.dry_run_log)?;

        let entry = serde_json::json!({
            "ts": Utc::now().to_rfc3339(),
            "cycle_id": manifest.cycle_id,
            "summary": manifest.dry_run_summary(),
            "total_loc": manifest.total_loc,
            "candidates": manifest.candidates.iter().map(|c| &c.gap_id).collect::<Vec<_>>(),
        });
        writeln!(file, "{}", serde_json::to_string(&entry)?)?;
        Ok(())
    }
}

// ── slot guard ────────────────────────────────────────────────────────────────

/// RAII guard that releases the NATS integration slot on drop.
///
/// Holds an owned clone of the coord client so it is `'static`-safe.
/// Drop fires a detached tokio task for best-effort cleanup; the KV TTL
/// guarantees eventual expiry even if the task doesn't run.
struct IntegrationSlotGuard {
    coord: Option<Arc<chump_coord::CoordClient>>,
}

impl Drop for IntegrationSlotGuard {
    fn drop(&mut self) {
        if let Some(coord) = self.coord.take() {
            tokio::spawn(async move {
                let _ = coord.release_gap(INTEGRATION_SLOT_KEY).await;
            });
        }
    }
}

// ── utility functions ─────────────────────────────────────────────────────────

/// Generate a cycle name in `integration-YYYY-MM-DD-HHMM` format.
///
/// Used as both the cycle ID and the `Batched-Under:` trailer value per INFRA-2135 AC.
fn datetime_cycle_name() -> String {
    Utc::now().format("integration-%Y-%m-%d-%H%M").to_string()
}

#[allow(dead_code)]
fn short_uuid() -> String {
    let u = Uuid::new_v4();
    u.simple().to_string()[..8].to_string()
}

fn which_chump(repo_root: &Path) -> Option<String> {
    // Check target/debug or target/release for local build first.
    for rel in ["target/debug/chump", "target/release/chump"] {
        let p = repo_root.join(rel);
        if p.exists() {
            return Some(p.to_string_lossy().into_owned());
        }
    }
    // Fall back to PATH lookup.
    if std::process::Command::new("which")
        .arg("chump")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        return Some("chump".to_string());
    }
    None
}

async fn run_with_timeout(cmd: &mut tokio::process::Command, timeout: Duration) -> Result<bool> {
    let mut child = cmd
        .stdin(std::process::Stdio::null())
        .spawn()
        .with_context(|| "spawning preflight command")?;

    match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(status)) => Ok(status.success()),
        Ok(Err(e)) => Err(anyhow::anyhow!("preflight process error: {e}")),
        Err(_) => {
            let _ = child.kill().await;
            Err(anyhow::anyhow!(
                "preflight timed out after {}s",
                timeout.as_secs()
            ))
        }
    }
}

fn emit_event(kind: &str, fields: &[(&str, &str)]) {
    let args = EmitArgs {
        kind: kind.to_string(),
        fields: fields
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        ..Default::default()
    };
    if let Err(e) = emit(&args) {
        eprintln!("[integrator] ambient emit {kind} failed: {e:#}");
    }
}

/// True if `repo_root`'s working tree has uncommitted changes (`git status
/// --porcelain` non-empty). Fail-closed: a git error returns `true` (hold),
/// because we can't prove the tree is clean and the cycle would otherwise
/// carry uncommitted files into the batch (EFFECTIVE-417).
fn git_working_tree_dirty(repo_root: &Path) -> bool {
    match std::process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(repo_root)
        .output()
    {
        Ok(out) => !out.stdout.is_empty(),
        Err(e) => {
            eprintln!("[integrator] git status failed ({e}); holding as dirty (fail-closed)");
            true
        }
    }
}

/// INFRA-8221: arm auto-merge on an integration PR through the one arm
/// policy. `Ok(false)` = the PR is held (no-auto-merge label / `Auto-merge:
/// hold`), nothing was armed and `kind=pr_arm_skipped_hold` was emitted.
async fn arm_integration_pr(pr_number: u64, repo: &Path) -> Result<bool> {
    if chump_ship::arm_policy::require_allowed_at(
        &pr_number.to_string(),
        "",
        "chump-integrator",
        chump_ship::arm_policy::GateAction::Arm,
        Some(repo),
    )
    .is_err()
    {
        return Ok(false);
    }
    let merge_status = tokio::process::Command::new("gh")
        .args(["pr", "merge", &pr_number.to_string(), "--auto", "--squash"])
        .current_dir(repo)
        .status()
        .await
        .with_context(|| format!("gh pr merge --auto for PR {pr_number}"))?;
    if !merge_status.success() {
        anyhow::bail!("gh pr merge --auto --squash failed for PR {pr_number}");
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cycle::GapCandidate;

    fn git(dir: &std::path::Path, args: &[&str]) {
        let ok = std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .output()
            .expect("git")
            .status
            .success();
        assert!(ok, "git {args:?} failed");
    }

    #[test]
    fn dirty_tree_detected_clean_and_dirty() {
        let td = tempfile::tempdir().unwrap();
        let p = td.path();
        git(p, &["init", "-q", "-b", "main"]);
        git(p, &["config", "user.email", "t@t"]);
        git(p, &["config", "user.name", "t"]);
        std::fs::write(p.join("a.txt"), "seed").unwrap();
        git(p, &["add", "."]);
        git(p, &["commit", "-q", "-m", "seed"]);
        // clean tree → not dirty
        assert!(!git_working_tree_dirty(p), "committed tree should be clean");
        // uncommitted new file → dirty (the EFFECTIVE-417 contamination case)
        std::fs::write(p.join("junk.txt"), "uncommitted").unwrap();
        assert!(
            git_working_tree_dirty(p),
            "uncommitted file should read dirty"
        );
    }

    fn candidate(branch: &str, author: Option<&str>, tags: &str) -> GapCandidate {
        GapCandidate {
            gap_id: "INFRA-9999".to_string(),
            title: "Test gap".to_string(),
            priority: "P1".to_string(),
            ready_at: "2026-05-30T00:00:00Z".to_string(),
            queue_age_s: 0,
            estimated_loc: 100,
            branch: branch.to_string(),
            author: author.map(|s| s.to_string()),
            tags: tags.to_string(),
        }
    }

    #[test]
    fn label_matches_via_tags_when_branch_and_author_clean() {
        // The silent-miss regression the doc TODO warned about: PR has the
        // do-not-batch tag set via gap notes, but the branch is named
        // normally and the author is the usual fleet identity.
        let c = candidate(
            "chump/infra-1234-claim",
            Some("repairman29"),
            "do-not-batch,foo",
        );
        assert!(IntegratorDaemon::candidate_has_label("do-not-batch", &c));
    }

    #[test]
    fn label_matches_case_insensitively_in_tags() {
        let c = candidate("chump/infra-1234-claim", None, "Do-Not-Batch");
        assert!(IntegratorDaemon::candidate_has_label("do-not-batch", &c));
    }

    #[test]
    fn label_matches_via_branch_proxy() {
        let c = candidate("chump/infra-9999-do-not-batch", None, "");
        assert!(IntegratorDaemon::candidate_has_label("do-not-batch", &c));
    }

    #[test]
    fn label_does_not_match_clean_candidate() {
        let c = candidate("chump/infra-1234-claim", Some("repairman29"), "foo,bar");
        assert!(!IntegratorDaemon::candidate_has_label("do-not-batch", &c));
    }

    #[test]
    fn empty_label_never_matches() {
        // Guard: an empty configured label must not match every candidate.
        let c = candidate("chump/infra-1234-claim", Some("repairman29"), "foo");
        assert!(!IntegratorDaemon::candidate_has_label("", &c));
    }

    #[test]
    fn tag_match_requires_full_token_equality_not_substring() {
        // "do-not-batch-later" should NOT match label "do-not-batch" via the
        // tags surface — tags are token-equality, not substring.
        let c = candidate("chump/infra-1234-claim", None, "do-not-batch-later");
        assert!(!IntegratorDaemon::candidate_has_label("do-not-batch", &c));
    }

    /// INFRA-8221: the integrator's arm site refuses a held PR before gh runs.
    #[tokio::test]
    async fn arm_integration_pr_refuses_held_pr() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("do-not-merge");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        let armed = arm_integration_pr(4242, tmp.path()).await.unwrap();
        assert!(!armed);
        assert_eq!(fake.calls.get(), 1);
        let ev = std::fs::read_to_string(&amb).unwrap();
        assert!(ev.contains("\"armer\":\"chump-integrator\""), "{ev}");
        assert!(ev.contains("label:do-not-merge"), "{ev}");
    }
}
