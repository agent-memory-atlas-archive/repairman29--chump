//! Single-iteration worker loop body (INFRA-2002 / META-107 sub-gap #6).
//!
//! ## What this module is
//!
//! The minimum code path to take one pickable open gap from `state.db`,
//! claim it atomically, run `chump --execute-gap <ID>` as a child process,
//! and return a structured outcome. The outer binary (`chump-worker`)
//! decides whether to sleep and loop, exit on `--once`, or be supervised
//! by `chump-fleet`.
//!
//! ## Phase 1 simplifications (deferred to follow-ups)
//!
//! - **No NATS PUSH consumption.** `CHUMP_NATS_URL` is read but the path is
//!   stubbed to fall through to PULL with a debug message. The actual
//!   `chump.work.<priority>.<class>.<machine>` subscribe lives in
//!   FLEET-034 sub-gaps.
//! - **No KV capability publish.** [`super::capability::WorkerCapability`]
//!   builds the manifest but doesn't publish it; that requires `async-nats`
//!   plumbing per INFRA-1760 follow-ups.
//! - **No speculative `replicas: N` envelopes.** Single-claim only.
//! - **No new ambient event kinds.** Emissions are limited to existing
//!   registered kinds: `worker_exit` (on child exit), `worker_stuck`
//!   (on every exit-without-ship path).

use crate::worker::capability::{has_external_repo_tag, WorkerCapability};
use crate::worker::worktree::{create_worktree, remove_worktree, worktree_dir_for};
use anyhow::{Context, Result};
use chump_ambient_cli::ambient_emit::{emit, EmitArgs};
use chump_gap_store::{GapRow, GapStore};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;
use tokio::time::timeout;

/// Default per-cycle execution timeout (matches `FLEET_TIMEOUT_S` in worker.sh).
pub const DEFAULT_EXEC_TIMEOUT_S: u64 = 1800;

/// Outcome of a single loop iteration. The binary uses this to decide the
/// sleep duration and whether the parent supervisor should restart it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CycleOutcome {
    /// A gap was claimed and `chump --execute-gap` returned exit code 0.
    Shipped { gap_id: String },
    /// A gap was claimed but the child exited non-zero. Lease is left in
    /// place for the next cycle (the operator / recovery-queue can decide
    /// whether to re-attempt or release).
    ChildFailed { gap_id: String, rc: i32 },
    /// A gap was claimed but the child execution timed out.
    ChildTimeout { gap_id: String, timeout_s: u64 },
    /// No pickable gap matched this worker's capabilities right now.
    NoPickableGap,
    /// Could not open state.db or query it (transient).
    StateError { reason: String },
    /// Tried to claim a gap, but a sibling won the race.
    LostClaimRace { gap_id: String },
    /// `git worktree add` failed.
    WorktreeError { gap_id: String, reason: String },
}

impl CycleOutcome {
    pub fn shipped(&self) -> bool {
        matches!(self, CycleOutcome::Shipped { .. })
    }

    /// True if the outcome is one of the "no progress" classes that should
    /// emit `worker_stuck` (existing registered kind).
    pub fn is_stuck(&self) -> bool {
        matches!(
            self,
            CycleOutcome::NoPickableGap
                | CycleOutcome::StateError { .. }
                | CycleOutcome::WorktreeError { .. }
        )
    }

    /// Short slug used for the `reason` field of `worker_stuck`.
    pub fn stuck_reason(&self) -> &'static str {
        match self {
            CycleOutcome::NoPickableGap => "no_pickable_gap",
            CycleOutcome::StateError { .. } => "state_error",
            CycleOutcome::WorktreeError { .. } => "worktree_create_fail",
            CycleOutcome::LostClaimRace { .. } => "lost_claim_race",
            CycleOutcome::ChildFailed { .. } => "child_failed",
            CycleOutcome::ChildTimeout { .. } => "child_timeout",
            CycleOutcome::Shipped { .. } => "shipped",
        }
    }

    /// True if the outer binary should sleep before next cycle.
    pub fn should_idle_sleep(&self) -> bool {
        matches!(
            self,
            CycleOutcome::NoPickableGap | CycleOutcome::StateError { .. }
        )
    }
}

/// Per-cycle parameters resolved by the binary entrypoint before calling
/// [`run_one_cycle`]. Splitting this out makes the loop body unit-testable.
pub struct CycleEnv {
    pub repo_root: PathBuf,
    pub session_id: String,
    pub capability: WorkerCapability,
    /// Override the executable used for `chump --execute-gap`. Defaults to
    /// `"chump"` (resolved via PATH). Tests set this to `/usr/bin/true` or
    /// a fixture script.
    pub exec_override: Option<String>,
    /// Per-cycle timeout for the child process.
    pub exec_timeout_s: u64,
    /// Lease TTL in seconds (default 14400 = 4h; matches `CHUMP_GAP_CLAIM_TTL_SECS`).
    pub lease_ttl_s: i64,
}

impl CycleEnv {
    /// Build from env. Honors `CHUMP_WORKER_EXEC_OVERRIDE` (test seam),
    /// `FLEET_TIMEOUT_S`, `CHUMP_GAP_CLAIM_TTL_SECS`.
    pub fn from_env(repo_root: PathBuf, session_id: String) -> Self {
        let capability = WorkerCapability::from_env(&session_id);
        let exec_override = std::env::var("CHUMP_WORKER_EXEC_OVERRIDE").ok();
        let exec_timeout_s = std::env::var("FLEET_TIMEOUT_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_EXEC_TIMEOUT_S);
        let lease_ttl_s = std::env::var("CHUMP_GAP_CLAIM_TTL_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(14_400);
        Self {
            repo_root,
            session_id,
            capability,
            exec_override,
            exec_timeout_s,
            lease_ttl_s,
        }
    }
}

/// Run exactly one cycle. Returns the outcome; the caller decides what to do.
pub async fn run_one_cycle(env: &CycleEnv) -> CycleOutcome {
    // 1. Open state.db.
    let store = match GapStore::open(&env.repo_root) {
        Ok(s) => s,
        Err(e) => {
            let outcome = CycleOutcome::StateError {
                reason: format!("open state.db failed: {e}"),
            };
            emit_stuck_if_needed(&outcome, &env.session_id);
            return outcome;
        }
    };

    // 2. Pick the first eligible open gap that matches our capability.
    //    PULL-mode happy path: scan `status=open` rows, filter by
    //    capability, return the first one. NATS PUSH path is stubbed
    //    (CHUMP_NATS_URL is read but not consumed in Phase 1).
    let pick = pick_eligible_gap(&store, &env.capability);
    let gap = match pick {
        Ok(Some(g)) => g,
        Ok(None) => {
            let outcome = CycleOutcome::NoPickableGap;
            emit_stuck_if_needed(&outcome, &env.session_id);
            return outcome;
        }
        Err(e) => {
            let outcome = CycleOutcome::StateError {
                reason: format!("list gaps failed: {e}"),
            };
            emit_stuck_if_needed(&outcome, &env.session_id);
            return outcome;
        }
    };

    // 3. Atomic claim.
    let wt = worktree_dir_for(&gap.id);
    let wt_str = wt.to_string_lossy().to_string();
    if let Err(e) = store.claim(&gap.id, &env.session_id, &wt_str, env.lease_ttl_s) {
        let outcome = CycleOutcome::LostClaimRace {
            gap_id: gap.id.clone(),
        };
        // Don't emit worker_stuck on a lost race — it's expected fleet
        // behavior, not a stuck condition. Just log to stderr.
        eprintln!(
            "[chump-worker] {} lost claim race for {}: {}",
            env.session_id, gap.id, e
        );
        return outcome;
    }

    // 4. Create worktree.
    if let Err(e) = create_worktree(&env.repo_root, &gap.id, &wt).await {
        let outcome = CycleOutcome::WorktreeError {
            gap_id: gap.id.clone(),
            reason: format!("{e}"),
        };
        emit_stuck_if_needed(&outcome, &env.session_id);
        return outcome;
    }

    // 5. Spawn `chump --execute-gap <ID>` (or override).
    let exec = env
        .exec_override
        .clone()
        .unwrap_or_else(|| "chump".to_string());
    let rc = match spawn_execute_gap(&exec, &gap.id, &env.repo_root, env.exec_timeout_s).await {
        Ok(Some(code)) => code,
        Ok(None) => {
            // Timed out — emit worker_exit with classified rc + leave lease in place.
            let outcome = CycleOutcome::ChildTimeout {
                gap_id: gap.id.clone(),
                timeout_s: env.exec_timeout_s,
            };
            emit_worker_exit(&env.session_id, &gap.id, 124, "timeout");
            return outcome;
        }
        Err(e) => {
            // Spawn itself failed — best-effort cleanup, emit worker_stuck.
            let outcome = CycleOutcome::WorktreeError {
                gap_id: gap.id.clone(),
                reason: format!("spawn failed: {e}"),
            };
            emit_stuck_if_needed(&outcome, &env.session_id);
            // best-effort worktree cleanup
            let _ = remove_worktree(&env.repo_root, &wt).await;
            return outcome;
        }
    };

    // 6. Classify outcome based on rc.
    if rc == 0 {
        emit_worker_exit(&env.session_id, &gap.id, 0, "shipped");
        CycleOutcome::Shipped {
            gap_id: gap.id.clone(),
        }
    } else {
        emit_worker_exit(&env.session_id, &gap.id, rc, "child_failed");
        CycleOutcome::ChildFailed {
            gap_id: gap.id.clone(),
            rc,
        }
    }
}

/// Pick the first eligible gap for the given capability.
///
/// Phase 1: simple linear scan over `status=open` rows ordered by
/// priority (P0 first), then by id. The legacy picker (musher.py /
/// `chump gap list`) does the same — we mirror its surface and defer
/// scoring sophistication to a follow-up.
pub fn pick_eligible_gap(store: &GapStore, cap: &WorkerCapability) -> Result<Option<GapRow>> {
    let mut rows = store.list(Some("open")).context("listing open gaps")?;
    rows.sort_by(|a, b| {
        // P0 < P1 < P2 < P3 alphabetically — good enough for Phase 1.
        a.priority.cmp(&b.priority).then(a.id.cmp(&b.id))
    });
    let blocked_external = if cap.external_repo_enabled {
        0
    } else {
        rows.iter().filter(|r| has_external_repo_tag(r)).count()
    };
    let mut skipped_external = 0usize;
    let mut picked = None;
    for row in rows {
        if !cap.external_repo_enabled && has_external_repo_tag(&row) {
            skipped_external += 1;
            continue;
        }
        if cap.matches(&row) {
            picked = Some(row);
            break;
        }
    }
    if cap.external_repo_enabled {
        eprintln!("[chump-worker] external_repo gate: open");
    } else {
        if skipped_external > 0 {
            eprintln!(
                "[chump-worker] {} external gaps skipped: gate closed",
                skipped_external
            );
        }
        eprintln!(
            "[chump-worker] external_repo gate: closed ({} gaps blocked)",
            blocked_external
        );
    }
    Ok(picked)
}

/// Spawn the child with a timeout. Returns:
/// - `Ok(Some(code))` on clean exit (code can be non-zero).
/// - `Ok(None)` on timeout (child killed).
/// - `Err(...)` if the spawn itself failed.
async fn spawn_execute_gap(
    exec: &str,
    gap_id: &str,
    cwd: &Path,
    timeout_s: u64,
) -> Result<Option<i32>> {
    let mut cmd = Command::new(exec);
    // The test override (CHUMP_WORKER_EXEC_OVERRIDE=/usr/bin/true) ignores
    // args; production "chump" expects `--execute-gap <ID>`. Pass both;
    // /usr/bin/true ignores them harmlessly.
    cmd.arg("--execute-gap").arg(gap_id).current_dir(cwd);
    cmd.kill_on_drop(true);
    let child = cmd.spawn().context("spawning chump --execute-gap")?;
    // Wait with timeout. tokio's child.wait() takes &mut self.
    let mut child = child;
    let result = timeout(Duration::from_secs(timeout_s), child.wait()).await;
    match result {
        Ok(Ok(status)) => Ok(Some(status.code().unwrap_or(-1))),
        Ok(Err(e)) => Err(anyhow::anyhow!("waiting on child: {e}")),
        Err(_elapsed) => {
            // Timed out — kill_on_drop will SIGKILL when `child` goes out of scope.
            let _ = child.start_kill();
            Ok(None)
        }
    }
}

fn emit_worker_exit(session_id: &str, gap_id: &str, rc: i32, exit_class: &str) {
    let args = EmitArgs {
        kind: "worker_exit".to_string(),
        gap: Some(gap_id.to_string()),
        source: Some("chump-worker".to_string()),
        fields: vec![
            ("agent_id".to_string(), session_id.to_string()),
            ("rc".to_string(), rc.to_string()),
            ("exit_class".to_string(), exit_class.to_string()),
            ("gap_id".to_string(), gap_id.to_string()),
        ],
        ..Default::default()
    };
    let _ = emit(&args);
}

fn emit_stuck_if_needed(outcome: &CycleOutcome, session_id: &str) {
    if !outcome.is_stuck() {
        return;
    }
    let gap_id = match outcome {
        CycleOutcome::WorktreeError { gap_id, .. } => gap_id.clone(),
        _ => String::new(),
    };
    let mut fields = vec![
        ("reason".to_string(), outcome.stuck_reason().to_string()),
        ("worker_id".to_string(), session_id.to_string()),
    ];
    if !gap_id.is_empty() {
        fields.push(("gap_id".to_string(), gap_id.clone()));
    }
    let args = EmitArgs {
        kind: "worker_stuck".to_string(),
        gap: if gap_id.is_empty() {
            None
        } else {
            Some(gap_id)
        },
        source: Some("chump-worker".to_string()),
        fields,
        ..Default::default()
    };
    let _ = emit(&args);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cycle_outcome_classification() {
        assert!(CycleOutcome::Shipped {
            gap_id: "x".to_string()
        }
        .shipped());
        assert!(!CycleOutcome::NoPickableGap.shipped());
        assert!(CycleOutcome::NoPickableGap.is_stuck());
        assert!(CycleOutcome::NoPickableGap.should_idle_sleep());
        assert!(!CycleOutcome::ChildFailed {
            gap_id: "x".to_string(),
            rc: 1,
        }
        .is_stuck());
    }

    #[test]
    fn stuck_reason_slugs() {
        assert_eq!(
            CycleOutcome::NoPickableGap.stuck_reason(),
            "no_pickable_gap"
        );
        assert_eq!(
            CycleOutcome::WorktreeError {
                gap_id: "x".to_string(),
                reason: "y".to_string(),
            }
            .stuck_reason(),
            "worktree_create_fail"
        );
    }
}
