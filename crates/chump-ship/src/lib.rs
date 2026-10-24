//! Chump ship pipeline — pure planner (INFRA-1229 slice 1) + Ship trait
//! and ManualShipPath executor (INFRA-2001 Phase 2 of META-107 Rust-First
//! Migration Blueprint).
//!
//! ## Crate shape
//!
//! - [`plan`] + [`ShipPlan`] (this file) — pure planner extracted from
//!   `scripts/coord/bot-merge.sh`. No I/O.
//! - [`decide_steps`] + [`ExecutorStep`] (this file) — pure step list.
//! - [`Ship`] / [`ShipIntent`] / [`ShipMode`] / [`ShipReceipt`] /
//!   [`ShipError`] (see [`ship`] module) — typed surface for the
//!   executor in Phase 2.
//! - [`ManualShipPath`] (see [`manual_ship`] module) — concrete impl
//!   for the manual ship pipeline (subprocess `git` + `gh`).
//!   Single-instance via PID-locked Unix socket — fixes INFRA-1532
//!   double-instance class BY CONSTRUCTION.
//! - [`BotMergePath`] (see [`bot_merge`] module) — STUBBED. Phase 2
//!   sub-gap will port the 3044 LOC bash `scripts/coord/bot-merge.sh`.
//!
//! ## Phase 1 non-goals (deferred to follow-up sub-gaps)
//!
//! - No port of bot-merge.sh body. The 3044 LOC bash stays UNTOUCHED
//!   below the feature-flag shim in `scripts/coord/bot-merge.sh`.
//! - No `--stack-on` (PR stacking) support — flat-merge only.
//! - No new ambient event kinds. Phase 1 logs via `tracing` only.
//! - No edits to `docs/observability/EVENT_REGISTRY.yaml` or
//!   `scripts/ci/event-registry-reserved.txt`.
//!
//! ## Decision priority (matches bot-merge.sh today)
//!
//!   1. PR merged or closed → AlreadyDone
//!   2. No PR + commits → CreatePr
//!   3. behind > stale_threshold → StaleBranch (refuse)
//!   4. behind > 0 → RebaseAndPush
//!   5. mergeable=false + dirty → ConflictRecover
//!   6. all green + mergeable → RestDirectMerge (INFRA-1166 fast path)
//!   7. mergeable + pending checks + unarmed → ArmAutoMerge
//!   8. already armed → WaitForChecks
//!   9. mergeable=null (GH computing) → WaitForChecks
//!  10. unstable + failures (not conflict) → ConflictRecover
//!  11. anything else → OperatorAction

pub mod arm_policy;
pub mod bot_merge;
pub mod landing;
pub mod manual_ship;
pub mod ship;

pub use landing::{
    landed, landed_with, GithubLandingSource, LandingError, LandingProvider, LandingSource,
    MergeSha,
};
pub use ship::{
    ChildrenDoneReceipt, ImportedReceipt, LandingReceipt, PreflightGate, PreflightReport, Ship,
    ShipError, ShipIntent, ShipMode, ShipReceipt,
};

use serde::{Deserialize, Serialize};

/// PR existence + lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PrState {
    /// The PR doesn't exist yet on GitHub.
    None,
    Open,
    Closed,
    Merged,
}

/// GitHub's mergeable_state taxonomy. Values per the REST API; unknown
/// values map to `Unknown` so we fall through to OperatorAction safely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeableState {
    /// Mergeable + all required checks passing.
    Clean,
    /// Mergeable but branch needs to be updated to base.
    Behind,
    /// Mergeable but blocked by required-reviewers / branch protection.
    Blocked,
    /// Merge conflict; needs manual resolution.
    Dirty,
    /// Some required checks are failing (not a merge conflict).
    Unstable,
    /// Pre-merge hooks (e.g. status checks) still running.
    HasHooks,
    /// GitHub hasn't computed mergeability yet, or unknown taxonomy value.
    Unknown,
}

/// Roll-up of CI check states for the PR's head commit.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChecksSummary {
    pub total: u32,
    pub completed_success: u32,
    pub completed_failure: u32,
    /// pending, in-flight, queued
    pub incomplete: u32,
    /// neutral, skipped, cancelled — informational, don't gate merge
    pub neutral_or_skipped: u32,
}

impl ChecksSummary {
    /// All required checks resolved to success.
    pub fn all_green(&self) -> bool {
        self.total > 0 && self.incomplete == 0 && self.completed_failure == 0
    }
    pub fn any_failed(&self) -> bool {
        self.completed_failure > 0
    }
}

/// Snapshot of the PR (or its absence).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrSnapshot {
    /// PR number; None means no PR exists yet for this branch.
    pub number: Option<u64>,
    pub state: PrState,
    /// GitHub-side `mergeable` boolean (None = still computing).
    pub mergeable: Option<bool>,
    pub mergeable_state: MergeableState,
    pub auto_merge_set: bool,
    pub head_sha: String,
    pub base_sha: String,
    pub checks: ChecksSummary,
}

impl PrSnapshot {
    /// Convenience: PR exists in any state (open/closed/merged).
    pub fn exists(&self) -> bool {
        self.number.is_some() && self.state != PrState::None
    }
}

/// Snapshot of the local branch + its position vs `origin/main`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoSnapshot {
    pub branch: String,
    /// Commits in `origin/main` not in HEAD.
    pub behind_main: u32,
    /// Commits in HEAD not in `origin/main`.
    pub ahead_main: u32,
    pub has_uncommitted: bool,
    /// CHUMP_BOT_MERGE_STALE_THRESHOLD — refuse rebase past this point.
    pub stale_threshold: u32,
}

/// Outcome of the planner. Each variant carries enough info for either a
/// machine consumer (slice 2's executor) or a human operator to act.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "PascalCase")]
pub enum ShipPlan {
    /// PR already merged or closed — nothing to ship; close registry side.
    AlreadyDone {
        pr: u64,
        state: PrState,
        recovery_hint: String,
    },
    /// Branch has commits but no PR yet — push (if needed) and create PR.
    CreatePr { branch: String, ahead: u32 },
    /// Branch behind main, within stale threshold — rebase + force-push.
    RebaseAndPush { behind_count: u32 },
    /// All required checks green, mergeable → REST PUT directly (INFRA-1166).
    RestDirectMerge {
        pr: u64,
        head_sha: String,
        checks_verified: u32,
    },
    /// Mergeable, checks still resolving → arm auto-merge.
    ArmAutoMerge { pr: u64, reason: String },
    /// Already armed and waiting on checks/review.
    WaitForChecks {
        pr: u64,
        incomplete: u32,
        reason: String,
    },
    /// Behind main past the stale threshold — refuse to rebase blindly.
    StaleBranch {
        pr: Option<u64>,
        behind: u32,
        threshold: u32,
        recovery_hint: String,
    },
    /// Mergeable=false + dirty (merge conflict) OR unstable failures.
    ConflictRecover { pr: u64, recovery_hint: String },
    /// State the planner can't handle confidently — surface to operator.
    OperatorAction {
        reason: String,
        recovery_hint: String,
    },
}

/// Pure planner. No I/O. Decisions only.
pub fn plan(pr: &PrSnapshot, repo: &RepoSnapshot) -> ShipPlan {
    // 1. PR already merged or closed.
    if let Some(num) = pr.number {
        match pr.state {
            PrState::Merged => {
                return ShipPlan::AlreadyDone {
                    pr: num,
                    state: PrState::Merged,
                    recovery_hint: format!(
                        "PR #{num} merged. Run `chump gap ship <ID> --closed-pr {num} --update-yaml` to close the registry side."
                    ),
                };
            }
            PrState::Closed => {
                return ShipPlan::AlreadyDone {
                    pr: num,
                    state: PrState::Closed,
                    recovery_hint: format!(
                        "PR #{num} closed without merging. Inspect with `gh pr view {num}` before re-opening or filing a new gap."
                    ),
                };
            }
            _ => {}
        }
    }

    // 2. No PR yet — if branch is ahead of main, create one.
    if !pr.exists() {
        if repo.ahead_main > 0 {
            return ShipPlan::CreatePr {
                branch: repo.branch.clone(),
                ahead: repo.ahead_main,
            };
        }
        return ShipPlan::OperatorAction {
            reason: "Branch has no PR and no commits ahead of main — nothing to ship.".to_string(),
            recovery_hint: "Make commits on this branch before invoking ship, or check that you're on the intended branch.".to_string(),
        };
    }

    let pr_num = pr.number.expect("pr.exists() ensures number is Some");

    // 3. Branch too far behind — refuse.
    if repo.behind_main > repo.stale_threshold {
        return ShipPlan::StaleBranch {
            pr: Some(pr_num),
            behind: repo.behind_main,
            threshold: repo.stale_threshold,
            recovery_hint: format!(
                "Branch is {} commits behind main (threshold {}). Manual rebase recommended — run `git fetch && git rebase origin/main` and inspect for non-trivial conflicts before pushing.",
                repo.behind_main, repo.stale_threshold
            ),
        };
    }

    // 4. Behind main but within threshold — rebase + force-push.
    if repo.behind_main > 0 {
        return ShipPlan::RebaseAndPush {
            behind_count: repo.behind_main,
        };
    }

    // 5. PR exists, mergeable=false + dirty → conflict recovery.
    if pr.mergeable == Some(false) && pr.mergeable_state == MergeableState::Dirty {
        return ShipPlan::ConflictRecover {
            pr: pr_num,
            recovery_hint: format!(
                "PR #{pr_num} has merge conflicts. Run `gh pr checkout {pr_num}`, resolve conflicts in the affected files, then force-push the rebased branch."
            ),
        };
    }

    // 10. Unstable state — at least one check failing (not a merge conflict).
    if pr.checks.any_failed() && pr.mergeable_state == MergeableState::Unstable {
        return ShipPlan::ConflictRecover {
            pr: pr_num,
            recovery_hint: format!(
                "PR #{pr_num} has {} failing check(s). Inspect with `gh pr checks {pr_num}` — fix the failures and force-push, OR file a flake-rerun follow-up if the failure is known-flaky.",
                pr.checks.completed_failure
            ),
        };
    }

    // 6. All required checks green + mergeable → REST PUT fast path.
    if pr.checks.all_green() && pr.mergeable == Some(true) && !pr.auto_merge_set {
        return ShipPlan::RestDirectMerge {
            pr: pr_num,
            head_sha: pr.head_sha.clone(),
            checks_verified: pr.checks.total,
        };
    }

    // 7. mergeable=true + pending checks + not yet armed → arm auto-merge.
    if pr.mergeable == Some(true) && !pr.auto_merge_set && pr.checks.incomplete > 0 {
        return ShipPlan::ArmAutoMerge {
            pr: pr_num,
            reason: format!(
                "PR #{pr_num} mergeable, {}/{} checks completed, {} in-flight. Arm auto-merge to fire when CI finishes.",
                pr.checks.completed_success,
                pr.checks.total,
                pr.checks.incomplete
            ),
        };
    }

    // 8. Already armed — let the queue handle it.
    if pr.auto_merge_set {
        return ShipPlan::WaitForChecks {
            pr: pr_num,
            incomplete: pr.checks.incomplete,
            reason: format!(
                "PR #{pr_num} already armed; {} check(s) outstanding. No action needed.",
                pr.checks.incomplete
            ),
        };
    }

    // 9. mergeable=null — GitHub still computing. Wait for the next pass.
    if pr.mergeable.is_none() {
        return ShipPlan::WaitForChecks {
            pr: pr_num,
            incomplete: pr.checks.incomplete,
            reason: format!(
                "PR #{pr_num} mergeability still being computed by GitHub. Retry shortly."
            ),
        };
    }

    // Fallback.
    ShipPlan::OperatorAction {
        reason: format!(
            "Uncovered state for PR #{pr_num}: mergeable={:?}, mergeable_state={:?}, auto_merge_set={}, checks={:?}",
            pr.mergeable, pr.mergeable_state, pr.auto_merge_set, pr.checks
        ),
        recovery_hint: format!(
            "Inspect manually with `gh pr view {pr_num} --json mergeStateStatus,statusCheckRollup` and either retry once the state resolves OR file a planner-gap to handle this case."
        ),
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 2 — pure executor-step decision.
//
// `decide_steps(plan)` translates a ShipPlan into a list of shell
// commands to run (git or gh). It's pure — no I/O — so the planner +
// executor pair can be unit-tested end-to-end without a network or repo.
// The CLI wrapper in `src/main.rs` walks the steps via std::process::Command.
// ──────────────────────────────────────────────────────────────────────

/// One shell command in the executor pipeline. `expect_success=true`
/// means the runner aborts the chain on non-zero exit; `false` means
/// best-effort (warn + continue).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutorStep {
    pub program: String,
    pub args: Vec<String>,
    pub expect_success: bool,
    pub note: String,
}

impl ExecutorStep {
    fn git(args: &[&str], note: &str) -> Self {
        Self {
            program: "git".to_string(),
            args: args.iter().map(|s| s.to_string()).collect(),
            expect_success: true,
            note: note.to_string(),
        }
    }
    fn gh(args: &[&str], note: &str) -> Self {
        Self {
            program: "gh".to_string(),
            args: args.iter().map(|s| s.to_string()).collect(),
            expect_success: true,
            note: note.to_string(),
        }
    }
}

/// Translate a [`ShipPlan`] into the executor's command list. Empty list
/// means "no action needed for this plan variant" (e.g. AlreadyDone,
/// WaitForChecks, OperatorAction).
pub fn decide_steps(plan: &ShipPlan) -> Vec<ExecutorStep> {
    match plan {
        ShipPlan::RebaseAndPush { .. } => vec![
            ExecutorStep::git(
                &["fetch", "origin", "main", "--quiet"],
                "fetch origin/main",
            ),
            ExecutorStep::git(
                &["rebase", "origin/main"],
                "rebase onto origin/main",
            ),
            ExecutorStep::git(
                &["push", "--force-with-lease", "origin", "HEAD"],
                "force-with-lease push",
            ),
        ],
        ShipPlan::RestDirectMerge { pr, .. } => {
            // REST PUT bypasses the GraphQL enablePullRequestAutoMerge mutation
            // (INFRA-1166 fast path). Owner/repo are filled by the CLI from
            // `gh repo view`; we leave a placeholder marker the runner replaces.
            vec![ExecutorStep {
                program: "gh".to_string(),
                args: vec![
                    "api".to_string(),
                    format!("repos/{{OWNER_REPO}}/pulls/{pr}/merge"),
                    "-X".to_string(),
                    "PUT".to_string(),
                    "-f".to_string(),
                    "merge_method=squash".to_string(),
                ],
                expect_success: true,
                note: format!("REST PUT direct merge for PR #{pr} (no GraphQL)"),
            }]
        }
        ShipPlan::ArmAutoMerge { pr, .. } => vec![ExecutorStep::gh(
            &["pr", "merge", &pr.to_string(), "--auto", "--squash"],
            "arm auto-merge (GraphQL enablePullRequestAutoMerge — last GraphQL mutation pending INFRA-1076)",
        )
        .into_lenient_on_secondary_limit()],
        // Variants below are observation-only — no executor action needed.
        ShipPlan::AlreadyDone { .. }
        | ShipPlan::WaitForChecks { .. }
        | ShipPlan::StaleBranch { .. }
        | ShipPlan::ConflictRecover { .. }
        | ShipPlan::OperatorAction { .. }
        | ShipPlan::CreatePr { .. } => vec![],
    }
}

/// INFRA-8221: what the executor must ask the arm policy before running
/// `decide_steps(plan)`. `Some((selector, action))` — the PR number for
/// RestDirectMerge / ArmAutoMerge, the branch for RebaseAndPush (its
/// force-push rewrites the PR's head). `None` = the plan touches no PR.
pub fn plan_gate_target(plan: &ShipPlan, branch: &str) -> Option<(String, arm_policy::GateAction)> {
    match plan {
        ShipPlan::RestDirectMerge { pr, .. } => {
            Some((pr.to_string(), arm_policy::GateAction::Touch))
        }
        ShipPlan::ArmAutoMerge { pr, .. } => Some((pr.to_string(), arm_policy::GateAction::Arm)),
        ShipPlan::RebaseAndPush { .. } if !branch.is_empty() && branch != "HEAD" => {
            Some((branch.to_string(), arm_policy::GateAction::Touch))
        }
        _ => None,
    }
}

/// Current checkout's branch (`git symbolic-ref --short HEAD`), or "HEAD"
/// when detached / unreadable.
pub fn current_branch_name() -> String {
    std::process::Command::new("git")
        .args(["symbolic-ref", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "HEAD".to_string())
}

/// INFRA-8221: the executor's arm-policy gate. `Err` = the PR is held; run
/// no step (the refusal is already emitted as `kind=pr_arm_skipped_hold`).
pub fn gate_plan(
    plan: &ShipPlan,
    branch: &str,
    repo: &str,
    armer: &str,
) -> Result<(), arm_policy::ArmHeld> {
    match plan_gate_target(plan, branch) {
        Some((sel, action)) => arm_policy::require_allowed(&sel, repo, armer, action),
        None => Ok(()),
    }
}

impl ExecutorStep {
    /// The auto-merge arm mutation can fail with a secondary rate-limit
    /// error even when the bucket has plenty of quota; the runner should
    /// surface that distinctly rather than treat it as a hard fault.
    /// Marker for the CLI runner to attach retry/backoff logic.
    fn into_lenient_on_secondary_limit(mut self) -> Self {
        self.expect_success = false;
        self
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 3 — behind-recovery (pure helpers).
//
// Slice 2 emits 3 git steps for RebaseAndPush. In practice the 3rd step
// (`git push --force-with-lease`) loses to origin races during the
// build/test window — bot-merge.sh handles this with ~400 LOC of
// shell-side retry + conflict detection + pre-push freshness gate.
//
// This slice extracts that decision logic into pure functions:
//   - `classify_step_failure()` — given a failed step's rc + stderr,
//     return a RetryAction (retry, abort-as-conflict, fail).
//   - `freshness_verdict()` — given a behind-count + threshold,
//     decide if we should refuse the push.
//
// The CLI runner consumes these to drive a stateful retry loop without
// shell-style branching.
// ──────────────────────────────────────────────────────────────────────

/// What the runner should do after a failed step in a RebaseAndPush chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "PascalCase")]
pub enum RetryAction {
    /// Step succeeded (or non-failing-as-classified) — proceed.
    Continue,
    /// Force-push rejected by stale-info race; re-rebase and re-push.
    RetryRebaseAndPush { attempt: u32, max: u32 },
    /// `git rebase` produced merge conflicts. Operator must resolve.
    AbortAsConflict { reason: String },
    /// Pre-push freshness check found behind > threshold. Abort.
    AbortAsStaleBranch { behind: u32, threshold: u32 },
    /// Other unrecoverable failure.
    Fail { reason: String },
}

/// Classify a single failed step into a RetryAction. Pure — no I/O.
///
/// Heuristics (matched to bot-merge.sh today):
/// - `git push` + non-zero + stderr mentions "stale info" OR
///   "rejected" + "force-with-lease" → RetryRebaseAndPush
/// - `git rebase` + non-zero + stderr contains "CONFLICT" →
///   AbortAsConflict
/// - rc == 0 → Continue
/// - attempt >= max → Fail
/// - anything else → Fail
pub fn classify_step_failure(
    program: &str,
    args: &[String],
    rc: i32,
    stderr: &str,
    attempt: u32,
    max_attempts: u32,
) -> RetryAction {
    if rc == 0 {
        return RetryAction::Continue;
    }
    let is_git = program == "git";
    let first_arg = args.first().map(|s| s.as_str()).unwrap_or("");
    let stderr_l = stderr.to_lowercase();

    if is_git && first_arg == "push" {
        let stale_info = stderr_l.contains("stale info");
        let rejected_lease = stderr_l.contains("rejected") && stderr_l.contains("force-with-lease");
        if stale_info || rejected_lease {
            if attempt >= max_attempts {
                return RetryAction::Fail {
                    reason: format!(
                        "push --force-with-lease still rejected after {attempt} attempt(s); origin moved repeatedly. Manual rebase recommended."
                    ),
                };
            }
            return RetryAction::RetryRebaseAndPush {
                attempt: attempt + 1,
                max: max_attempts,
            };
        }
        return RetryAction::Fail {
            reason: format!(
                "git push failed (rc={rc}) and stderr does not look like a stale-info race; inspect: {}",
                truncate_for_log(stderr, 240)
            ),
        };
    }

    if is_git && first_arg == "rebase" {
        if stderr.contains("CONFLICT") || stderr_l.contains("merge conflict") {
            return RetryAction::AbortAsConflict {
                reason: "git rebase produced merge conflicts. Run `git rebase --abort`, then `gh pr checkout <N>` to inspect and resolve manually.".to_string(),
            };
        }
        return RetryAction::Fail {
            reason: format!(
                "git rebase failed (rc={rc}) without visible CONFLICT markers; stderr tail: {}",
                truncate_for_log(stderr, 240)
            ),
        };
    }

    RetryAction::Fail {
        reason: format!(
            "{program} {first_arg} failed (rc={rc}); stderr: {}",
            truncate_for_log(stderr, 240)
        ),
    }
}

fn truncate_for_log(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

/// Result of the pre-push freshness recheck (INFRA-995): is the branch
/// now too far behind main to safely push?
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FreshnessCheck {
    pub behind: u32,
    pub threshold: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FreshnessVerdict {
    Fresh,
    Stale,
}

/// Pure verdict: stale when `behind > threshold` (strict; equal is fresh).
pub fn freshness_verdict(c: &FreshnessCheck) -> FreshnessVerdict {
    if c.behind > c.threshold {
        FreshnessVerdict::Stale
    } else {
        FreshnessVerdict::Fresh
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_pr(num: u64, state: PrState) -> PrSnapshot {
        PrSnapshot {
            number: Some(num),
            state,
            mergeable: None,
            mergeable_state: MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: "abc1234".into(),
            base_sha: "def5678".into(),
            checks: ChecksSummary::default(),
        }
    }
    fn no_pr() -> PrSnapshot {
        PrSnapshot {
            number: None,
            state: PrState::None,
            mergeable: None,
            mergeable_state: MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: "abc1234".into(),
            base_sha: "def5678".into(),
            checks: ChecksSummary::default(),
        }
    }
    fn mk_repo(behind: u32, ahead: u32) -> RepoSnapshot {
        RepoSnapshot {
            branch: "chump/test".into(),
            behind_main: behind,
            ahead_main: ahead,
            has_uncommitted: false,
            stale_threshold: 15,
        }
    }

    #[test]
    fn merged_pr_yields_already_done() {
        let pr = mk_pr(1913, PrState::Merged);
        let repo = mk_repo(0, 0);
        match plan(&pr, &repo) {
            ShipPlan::AlreadyDone { pr: n, state, .. } => {
                assert_eq!(n, 1913);
                assert_eq!(state, PrState::Merged);
            }
            other => panic!("expected AlreadyDone(Merged), got {other:?}"),
        }
    }

    #[test]
    fn closed_pr_yields_already_done() {
        let pr = mk_pr(1913, PrState::Closed);
        let repo = mk_repo(0, 0);
        assert!(matches!(
            plan(&pr, &repo),
            ShipPlan::AlreadyDone {
                state: PrState::Closed,
                ..
            }
        ));
    }

    #[test]
    fn no_pr_with_commits_yields_create_pr() {
        let pr = no_pr();
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::CreatePr { ahead, .. } => assert_eq!(ahead, 3),
            other => panic!("expected CreatePr, got {other:?}"),
        }
    }

    #[test]
    fn no_pr_no_commits_yields_operator_action() {
        let pr = no_pr();
        let repo = mk_repo(0, 0);
        assert!(matches!(plan(&pr, &repo), ShipPlan::OperatorAction { .. }));
    }

    #[test]
    fn behind_threshold_yields_stale_branch() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        let repo = mk_repo(20, 5); // 20 > 15 threshold
        match plan(&pr, &repo) {
            ShipPlan::StaleBranch {
                behind, threshold, ..
            } => {
                assert_eq!(behind, 20);
                assert_eq!(threshold, 15);
            }
            other => panic!("expected StaleBranch, got {other:?}"),
        }
    }

    #[test]
    fn behind_within_threshold_yields_rebase_and_push() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        let repo = mk_repo(5, 3); // 5 <= 15 threshold
        match plan(&pr, &repo) {
            ShipPlan::RebaseAndPush { behind_count } => assert_eq!(behind_count, 5),
            other => panic!("expected RebaseAndPush, got {other:?}"),
        }
    }

    #[test]
    fn dirty_mergeable_state_yields_conflict_recover() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(false);
        pr.mergeable_state = MergeableState::Dirty;
        let repo = mk_repo(0, 3);
        assert!(matches!(plan(&pr, &repo), ShipPlan::ConflictRecover { .. }));
    }

    #[test]
    fn all_checks_green_unarmed_yields_rest_direct_merge() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::Clean;
        pr.checks = ChecksSummary {
            total: 7,
            completed_success: 7,
            completed_failure: 0,
            incomplete: 0,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::RestDirectMerge {
                pr: n,
                checks_verified,
                ..
            } => {
                assert_eq!(n, 1913);
                assert_eq!(checks_verified, 7);
            }
            other => panic!("expected RestDirectMerge, got {other:?}"),
        }
    }

    #[test]
    fn mergeable_with_pending_checks_yields_arm_auto_merge() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::HasHooks;
        pr.checks = ChecksSummary {
            total: 10,
            completed_success: 6,
            completed_failure: 0,
            incomplete: 4,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(0, 3);
        assert!(matches!(plan(&pr, &repo), ShipPlan::ArmAutoMerge { .. }));
    }

    #[test]
    fn already_armed_yields_wait_for_checks() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.auto_merge_set = true;
        pr.checks.incomplete = 2;
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::WaitForChecks {
                pr: n, incomplete, ..
            } => {
                assert_eq!(n, 1913);
                assert_eq!(incomplete, 2);
            }
            other => panic!("expected WaitForChecks, got {other:?}"),
        }
    }

    #[test]
    fn mergeable_null_yields_wait_for_checks() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = None;
        let repo = mk_repo(0, 3);
        assert!(matches!(plan(&pr, &repo), ShipPlan::WaitForChecks { .. }));
    }

    #[test]
    fn unstable_with_failures_yields_conflict_recover() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::Unstable;
        pr.checks = ChecksSummary {
            total: 10,
            completed_success: 8,
            completed_failure: 2,
            incomplete: 0,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::ConflictRecover { recovery_hint, .. } => {
                assert!(recovery_hint.contains("failing check"));
            }
            other => panic!("expected ConflictRecover (CI failure), got {other:?}"),
        }
    }

    #[test]
    fn behind_takes_priority_over_arm() {
        // Even if PR is mergeable, behind > 0 should rebase first.
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::Clean;
        pr.checks = ChecksSummary {
            total: 5,
            completed_success: 5,
            completed_failure: 0,
            incomplete: 0,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(3, 1);
        assert!(matches!(plan(&pr, &repo), ShipPlan::RebaseAndPush { .. }));
    }

    #[test]
    fn merged_pr_with_behind_still_already_done() {
        // Merged PR with branch behind main — still AlreadyDone, no rebase.
        let pr = mk_pr(1913, PrState::Merged);
        let repo = mk_repo(5, 0);
        assert!(matches!(plan(&pr, &repo), ShipPlan::AlreadyDone { .. }));
    }

    // ── INFRA-1229 slice 2: decide_steps() tests ─────────────────────────

    #[test]
    fn rebase_and_push_yields_three_git_steps() {
        let steps = decide_steps(&ShipPlan::RebaseAndPush { behind_count: 3 });
        assert_eq!(steps.len(), 3);
        // fetch
        assert_eq!(steps[0].program, "git");
        assert_eq!(steps[0].args[0], "fetch");
        assert!(steps[0].expect_success);
        // rebase
        assert_eq!(steps[1].program, "git");
        assert_eq!(steps[1].args[0], "rebase");
        // push with --force-with-lease
        assert_eq!(steps[2].program, "git");
        assert_eq!(steps[2].args[0], "push");
        assert!(steps[2].args.contains(&"--force-with-lease".to_string()));
    }

    #[test]
    fn rest_direct_merge_yields_gh_api_put() {
        let plan = ShipPlan::RestDirectMerge {
            pr: 1913,
            head_sha: "abc1234567".into(),
            checks_verified: 7,
        };
        let steps = decide_steps(&plan);
        assert_eq!(steps.len(), 1);
        let s = &steps[0];
        assert_eq!(s.program, "gh");
        assert_eq!(s.args[0], "api");
        // PR number is encoded in the path
        assert!(
            s.args.iter().any(|a| a.contains("/pulls/1913/merge")),
            "step args missing /pulls/1913/merge: {:?}",
            s.args
        );
        // -X PUT + merge_method=squash present
        assert!(s.args.contains(&"PUT".to_string()));
        assert!(s.args.iter().any(|a| a.contains("merge_method=squash")));
    }

    #[test]
    fn arm_auto_merge_yields_gh_pr_merge() {
        let plan = ShipPlan::ArmAutoMerge {
            pr: 1913,
            reason: "stuff".into(),
        };
        let steps = decide_steps(&plan);
        assert_eq!(steps.len(), 1);
        let s = &steps[0];
        assert_eq!(s.program, "gh");
        assert_eq!(s.args[..4], ["pr", "merge", "1913", "--auto"]);
        assert_eq!(s.args[4], "--squash");
        // Lenient on secondary rate-limit — the runner can retry.
        assert!(!s.expect_success,
                "arm step should be lenient (expect_success=false) so the runner can retry on secondary limit");
    }

    #[test]
    fn observation_only_variants_yield_no_steps() {
        let cases = [
            ShipPlan::AlreadyDone {
                pr: 1,
                state: PrState::Merged,
                recovery_hint: "x".into(),
            },
            ShipPlan::WaitForChecks {
                pr: 1,
                incomplete: 3,
                reason: "x".into(),
            },
            ShipPlan::StaleBranch {
                pr: Some(1),
                behind: 50,
                threshold: 15,
                recovery_hint: "x".into(),
            },
            ShipPlan::ConflictRecover {
                pr: 1,
                recovery_hint: "x".into(),
            },
            ShipPlan::OperatorAction {
                reason: "x".into(),
                recovery_hint: "x".into(),
            },
            ShipPlan::CreatePr {
                branch: "b".into(),
                ahead: 2,
            },
        ];
        for plan in &cases {
            let steps = decide_steps(plan);
            assert!(
                steps.is_empty(),
                "{:?} should yield zero executor steps, got {:?}",
                plan,
                steps
            );
        }
    }

    #[test]
    fn executor_step_serializes_to_stable_json() {
        let s = ExecutorStep::git(&["status", "--porcelain"], "check tree");
        let j = serde_json::to_string(&s).unwrap();
        assert!(j.contains("\"program\":\"git\""));
        assert!(j.contains("\"status\""));
        assert!(j.contains("\"--porcelain\""));
        assert!(j.contains("\"expect_success\":true"));
    }

    // ── INFRA-1229 slice 3: retry classification tests ───────────────────

    fn arg(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn push_rejection_stale_info_triggers_retry() {
        let stderr = "To github.com:x/y.git\n ! [rejected] HEAD -> branch (stale info)";
        let act = classify_step_failure(
            "git",
            &[
                arg("push"),
                arg("--force-with-lease"),
                arg("origin"),
                arg("HEAD"),
            ],
            1,
            stderr,
            0,
            3,
        );
        match act {
            RetryAction::RetryRebaseAndPush { attempt, max } => {
                assert_eq!(attempt, 1);
                assert_eq!(max, 3);
            }
            other => panic!("expected RetryRebaseAndPush, got {other:?}"),
        }
    }

    #[test]
    fn push_rejection_force_with_lease_triggers_retry() {
        let stderr = "error: failed to push some refs to 'x'\n ! [rejected] (force-with-lease)";
        let act = classify_step_failure(
            "git",
            &[
                arg("push"),
                arg("--force-with-lease"),
                arg("origin"),
                arg("HEAD"),
            ],
            1,
            stderr,
            1,
            3,
        );
        assert!(
            matches!(act, RetryAction::RetryRebaseAndPush { attempt: 2, .. }),
            "got {act:?}"
        );
    }

    #[test]
    fn rebase_conflict_aborts() {
        let stderr = "CONFLICT (content): Merge conflict in src/main.rs\n";
        let act =
            classify_step_failure("git", &[arg("rebase"), arg("origin/main")], 1, stderr, 0, 3);
        match act {
            RetryAction::AbortAsConflict { reason } => {
                assert!(
                    reason.contains("rebase --abort"),
                    "reason should mention rebase --abort: {reason}"
                );
            }
            other => panic!("expected AbortAsConflict, got {other:?}"),
        }
    }

    #[test]
    fn clean_step_yields_continue() {
        let act = classify_step_failure(
            "git",
            &[arg("push"), arg("--force-with-lease")],
            0,
            "",
            0,
            3,
        );
        assert_eq!(act, RetryAction::Continue);
    }

    #[test]
    fn attempt_at_max_yields_fail() {
        let stderr = "rejected (stale info)";
        let act = classify_step_failure(
            "git",
            &[arg("push"), arg("--force-with-lease")],
            1,
            stderr,
            3, // already at max
            3,
        );
        match act {
            RetryAction::Fail { reason } => {
                assert!(
                    reason.contains("attempt"),
                    "reason should mention attempts: {reason}"
                );
            }
            other => panic!("expected Fail (max exceeded), got {other:?}"),
        }
    }

    #[test]
    fn unrelated_rc_yields_fail() {
        // Non-push, non-rebase failure: opaque "Fail".
        let act = classify_step_failure(
            "git",
            &[arg("fetch"), arg("origin"), arg("main")],
            128,
            "fatal: could not resolve host: github.com",
            0,
            3,
        );
        assert!(matches!(act, RetryAction::Fail { .. }), "got {act:?}");
    }

    #[test]
    fn push_failure_without_stale_marker_yields_fail() {
        let act = classify_step_failure(
            "git",
            &[arg("push"), arg("--force-with-lease")],
            1,
            "error: src refspec HEAD does not match any",
            0,
            3,
        );
        match act {
            RetryAction::Fail { reason } => {
                assert!(
                    reason.contains("does not look like a stale-info race"),
                    "reason: {reason}"
                );
            }
            other => panic!("expected Fail (non-stale push failure), got {other:?}"),
        }
    }

    #[test]
    fn freshness_fresh_under_threshold() {
        let v = freshness_verdict(&FreshnessCheck {
            behind: 5,
            threshold: 15,
        });
        assert_eq!(v, FreshnessVerdict::Fresh);
    }

    #[test]
    fn freshness_stale_over_threshold() {
        let v = freshness_verdict(&FreshnessCheck {
            behind: 16,
            threshold: 15,
        });
        assert_eq!(v, FreshnessVerdict::Stale);
    }

    #[test]
    fn freshness_equal_threshold_is_fresh() {
        // Equal-to-threshold is fresh (strict greater-than for stale).
        let v = freshness_verdict(&FreshnessCheck {
            behind: 15,
            threshold: 15,
        });
        assert_eq!(v, FreshnessVerdict::Fresh);
    }

    /// INFRA-8221: the executor gate covers every PR-touching plan variant
    /// and refuses a held PR (the call site in `chump ship execute`).
    #[test]
    fn gate_plan_targets_and_refuses_held_pr() {
        use arm_policy::GateAction;
        let arm = ShipPlan::ArmAutoMerge {
            pr: 7,
            reason: String::new(),
        };
        assert_eq!(
            plan_gate_target(&arm, "b"),
            Some(("7".into(), GateAction::Arm))
        );
        let rebase = ShipPlan::RebaseAndPush { behind_count: 3 };
        assert_eq!(
            plan_gate_target(&rebase, "chump/x"),
            Some(("chump/x".into(), GateAction::Touch))
        );
        assert_eq!(plan_gate_target(&rebase, "HEAD"), None);
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = arm_policy::testing::FakeFetcher::held_by_label("CHUMP_HOLD");
        let _g = arm_policy::override_for_tests(fake.clone(), &amb);
        let held = gate_plan(&arm, "b", "o/r", "chump ship execute").unwrap_err();
        assert_eq!(
            held.reason,
            arm_policy::HoldReason::Label("CHUMP_HOLD".into())
        );
        assert!(gate_plan(&rebase, "chump/x", "o/r", "chump ship execute").is_err());
        let done = ShipPlan::WaitForChecks {
            pr: 7,
            incomplete: 1,
            reason: String::new(),
        };
        assert!(gate_plan(&done, "b", "o/r", "x").is_ok());
        assert_eq!(fake.calls.get(), 2, "no read for a plan that touches no PR");
    }
}
