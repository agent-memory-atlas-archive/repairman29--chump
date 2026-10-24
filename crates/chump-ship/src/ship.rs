//! Ship trait + typed envelope/receipt/error surface (INFRA-2001 Phase 2).
//!
//! This module defines the **executor-side API** for the chump ship
//! pipeline. The planner in [`crate`] root decides WHAT to do; this
//! module defines the contract for DOING it.
//!
//! ## Why a trait
//!
//! `scripts/coord/bot-merge.sh` (3044 LOC of bash) handles three flavours
//! of ship under one roof:
//!
//! 1. **Manual ship**  — agent has finished work, push branch + open PR +
//!    arm auto-merge. The "happy path" — ~80% of fleet ships go this way.
//! 2. **Bot-merge ship** — autonomous mode, may retry/rebase/conflict-recover
//!    across multiple rounds. ~15% of ships.
//! 3. **Stack-on ship** — like Manual but with `--base=<prev-PR-head>`.
//!    ~5% of ships (related work that would file-conflict otherwise).
//!
//! Hiding all three behind a `Ship` trait gives us:
//!
//! - **Per-mode tests** without a giant bash script under test.
//! - **A typed receipt** ([`ShipReceipt`]) instead of parsing stdout.
//! - **A typed error** ([`ShipError`]) with the failure class baked in,
//!   not regex'd out of `gh` stderr.
//! - **Single-instance guarantees by construction** — see
//!   [`crate::manual_ship::ManualShipPath`] which uses a PID-locked
//!   Unix socket and returns [`ShipError::BotMergeDoubleInstance`] on
//!   collision (the INFRA-1532 fix that was previously enforced by
//!   ad-hoc bash convention).
//!
//! ## Phase 1 scope
//!
//! - Trait + types only here (this file).
//! - **One** concrete impl ([`crate::manual_ship::ManualShipPath`]) —
//!   the happy-path manual ship.
//! - [`crate::bot_merge::BotMergePath`] is **STUBBED** — `ship()` returns
//!   [`ShipError::BotMergeDoubleInstance`] with a "Phase 1: not
//!   implemented" diagnostic. Phase 2 sub-gap will port the bash body.
//!
//! Phase 1 does NOT emit any new ambient event kinds.

use std::borrow::Cow;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Receipt documenting a landing event: gap shipped with PR info.
/// Constructed from gap_id and closed_pr, then validated before
/// status transitions. CREDIBLE-1495: enforces idempotency + single
/// event emission on first transition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LandingReceipt {
    /// Gap ID (e.g. `INFRA-2001`).
    pub gap_id: String,
    /// GitHub PR number that closed/merged this gap (if available).
    pub closed_pr: Option<i64>,
    /// CREDIBLE-1550 (Phase R R2, AC3): the merge commit SHA on `origin/main`
    /// that `verify_proof_of_merge` matched for this gap. `None` when the
    /// close has no PR-backed proof (reconciler imports, synthetic test repos
    /// with no `.git`). Carries the proof-of-landing inline on the receipt so a
    /// later audit does not have to re-run the git-log lookup.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merge_sha: Option<String>,
    /// CREDIBLE-1579: when this gap landed in an external repository
    /// (`external_repo:<owner>/<name>`), records the `owner/name` repository
    /// where `closed_pr` and `merge_sha` were verified.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_repo: Option<String>,
    /// UTC timestamp of receipt creation.
    pub created_at: DateTime<Utc>,
}

impl LandingReceipt {
    /// Construct a receipt from gap_id and optional closed_pr.
    pub fn new(gap_id: impl Into<String>, closed_pr: Option<i64>) -> Self {
        LandingReceipt {
            gap_id: gap_id.into(),
            closed_pr,
            merge_sha: None,
            external_repo: None,
            created_at: Utc::now(),
        }
    }

    /// CREDIBLE-1550 (AC3): attach the proof-of-merge SHA. Builder-style so the
    /// common `new(..)` path stays unchanged and callers that have the SHA
    /// (ship's `proof_of_merge_sha`) chain it on.
    pub fn with_merge_sha(mut self, merge_sha: Option<String>) -> Self {
        self.merge_sha = merge_sha;
        self
    }

    /// CREDIBLE-1579: attach the external repository slug (`owner/name`) where
    /// the PR merge was verified.
    pub fn with_external_repo(mut self, external_repo: Option<String>) -> Self {
        self.external_repo = external_repo;
        self
    }

    /// Validate this receipt: check gap_id is non-empty, closed_pr (if present) is positive.
    /// Returns Ok(()) if valid, Err(reason) if not.
    pub fn validate(&self) -> Result<(), String> {
        if self.gap_id.is_empty() {
            return Err("gap_id cannot be empty".to_string());
        }
        if let Some(pr) = self.closed_pr {
            if pr <= 0 {
                return Err(format!("closed_pr must be positive, got {pr}"));
            }
        }
        Ok(())
    }
}

/// CREDIBLE-1508: receipt documenting a decomposed-umbrella auto-close —
/// every child slice of a `decomposed` parent reached `done`, so the parent
/// closes with no PR of its own (the children's own [`LandingReceipt`]s are
/// the actual proof-of-merge).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChildrenDoneReceipt {
    /// Parent gap ID being auto-closed.
    pub gap_id: String,
    /// Child gap IDs that were all `done` at close time.
    pub children: Vec<String>,
    /// UTC timestamp of receipt creation.
    pub created_at: DateTime<Utc>,
}

impl ChildrenDoneReceipt {
    pub fn new(gap_id: impl Into<String>, children: Vec<String>) -> Self {
        ChildrenDoneReceipt {
            gap_id: gap_id.into(),
            children,
            created_at: Utc::now(),
        }
    }

    /// Validate: gap_id non-empty, at least one child.
    pub fn validate(&self) -> Result<(), String> {
        if self.gap_id.is_empty() {
            return Err("gap_id cannot be empty".to_string());
        }
        if self.children.is_empty() {
            return Err("children cannot be empty".to_string());
        }
        Ok(())
    }
}

/// CREDIBLE-1508: receipt documenting a terminal-status row reconciled into
/// state.db from an out-of-band source (the `docs/gaps/*.yaml` mirror, or a
/// canonical peer store) rather than a live `ship()` — the PR/merge proof (if
/// any) already happened in the past and is not re-verified here. This is the
/// "explicit reconciler receipt variant" the single done-writer accepts in
/// place of a `closed_pr`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportedReceipt {
    /// Gap ID being reconciled.
    pub gap_id: String,
    /// Where the terminal status was reconciled from, e.g. "yaml_sync" or
    /// "canonical_peer".
    pub source: String,
    /// UTC timestamp of receipt creation.
    pub created_at: DateTime<Utc>,
}

impl ImportedReceipt {
    pub fn new(gap_id: impl Into<String>, source: impl Into<String>) -> Self {
        ImportedReceipt {
            gap_id: gap_id.into(),
            source: source.into(),
            created_at: Utc::now(),
        }
    }

    /// Validate: gap_id and source both non-empty.
    pub fn validate(&self) -> Result<(), String> {
        if self.gap_id.is_empty() {
            return Err("gap_id cannot be empty".to_string());
        }
        if self.source.trim().is_empty() {
            return Err("source cannot be empty".to_string());
        }
        Ok(())
    }
}

/// Selection of which executor path runs the ship.
///
/// Mirrors the three flavours of `scripts/coord/bot-merge.sh` today:
/// manual (default for agent-initiated ships) and bot-merge (autonomous).
/// Stack-on is a Phase 2 sub-gap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "kebab-case")]
pub enum ShipMode {
    /// The default. Agent has finished work; push branch + open PR + arm
    /// auto-merge. Phase 1 implements this in
    /// [`crate::manual_ship::ManualShipPath`].
    Manual,
    /// Autonomous ship that may retry/rebase/conflict-recover across
    /// rounds. Phase 1 is STUBBED — see [`crate::bot_merge::BotMergePath`].
    /// `bot_session_id` is the worker session id used for the single-instance
    /// guarantee — two workers cannot bot-merge the same gap simultaneously.
    BotMerge {
        /// Worker session id; load-bearing for single-instance guarantee.
        bot_session_id: String,
    },
}

impl ShipMode {
    /// Short stable name suitable for log keys.
    pub fn name(&self) -> &'static str {
        match self {
            ShipMode::Manual => "manual",
            ShipMode::BotMerge { .. } => "bot-merge",
        }
    }
}

/// Inputs to [`Ship::ship`] — everything an executor needs to do the work.
///
/// Uses `Cow<'a, str>` so callers in the CLI hot-path can pass borrowed
/// env-derived values without an allocation. The receipt
/// [`ShipReceipt`] is always owned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShipIntent<'a> {
    /// Gap id this ship is for (e.g. `INFRA-2001`). Surfaces in
    /// commit messages, PR titles, ambient event metadata.
    pub gap_id: Cow<'a, str>,
    /// Local branch name to push.
    pub branch: Cow<'a, str>,
    /// PR base branch (typically `main`).
    pub base: Cow<'a, str>,
    /// Commit message subject — caller-supplied; the executor does NOT
    /// invent one (sticking to single-responsibility: the executor pushes
    /// what's there).
    pub commit_message: Cow<'a, str>,
    /// Caller session id — used by [`crate::manual_ship::ManualShipPath`]
    /// to derive the single-instance socket path
    /// `/tmp/chump-ship-{session_id}.sock`.
    pub session_id: Cow<'a, str>,
}

impl<'a> ShipIntent<'a> {
    /// Owned-string convenience constructor (for tests / non-perf paths).
    pub fn owned(
        gap_id: impl Into<String>,
        branch: impl Into<String>,
        base: impl Into<String>,
        commit_message: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Self {
        ShipIntent {
            gap_id: Cow::Owned(gap_id.into()),
            branch: Cow::Owned(branch.into()),
            base: Cow::Owned(base.into()),
            commit_message: Cow::Owned(commit_message.into()),
            session_id: Cow::Owned(session_id.into()),
        }
    }
}

/// One pre-flight gate result. `passed=false` means [`Ship::ship`] must
/// not proceed; it returns [`ShipError::PreflightFailed`] carrying the
/// gate name + detail for the operator.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreflightGate {
    /// Short stable identifier (e.g. `branch_exists`, `cargo_check`).
    pub name: String,
    /// Did this gate pass?
    pub passed: bool,
    /// Operator-facing diagnostic when `passed=false`. Empty otherwise.
    pub detail: String,
}

/// Roll-up of pre-flight gate outcomes.
///
/// Phase 1's [`crate::manual_ship::ManualShipPath`] runs a small set of
/// cheap gates (branch exists, has commits ahead of base). Future phases
/// can add `cargo fmt/check/clippy/test` parity with `chump preflight`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreflightReport {
    /// One row per gate. Order is execution order.
    pub gates: Vec<PreflightGate>,
}

impl PreflightReport {
    /// True iff every gate passed.
    pub fn all_passed(&self) -> bool {
        self.gates.iter().all(|g| g.passed)
    }

    /// First failing gate (for [`ShipError::PreflightFailed`]).
    pub fn first_failure(&self) -> Option<&PreflightGate> {
        self.gates.iter().find(|g| !g.passed)
    }
}

/// What a successful ship produced.
///
/// Stable JSON-serializable record so the bash shim, the CLI runner,
/// and any future audit harness can all consume the same shape.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShipReceipt {
    /// GitHub PR number (e.g. 1913).
    pub pr_number: u64,
    /// Full PR URL.
    pub pr_url: String,
    /// PR head commit SHA.
    pub head_sha: String,
    /// True iff auto-merge was successfully armed on the PR.
    pub auto_merge_armed: bool,
    /// UTC timestamp at which the receipt was finalised.
    pub shipped_at: DateTime<Utc>,
}

/// Failure modes for [`Ship::ship`] and [`Ship::preflight`].
///
/// Each variant carries enough info for an operator to act without
/// re-parsing logs. The trait surface is async, but errors are not —
/// constructing an error is cheap and synchronous.
#[derive(Debug, Error)]
pub enum ShipError {
    /// One or more pre-flight gates failed. Carries the name of the
    /// first failing gate + its diagnostic.
    #[error("preflight gate `{gate_name}` failed: {detail}")]
    PreflightFailed {
        /// Stable gate identifier (matches a [`PreflightGate::name`]).
        gate_name: String,
        /// Operator-facing diagnostic.
        detail: String,
    },
    /// A `.chump-locks/claim-*.json` lease on a path this ship was about
    /// to mutate was held by another session. The shipper aborts rather
    /// than racing.
    #[error("lease collision on `{path}` (held by `{holder}`)")]
    LeaseCollision {
        /// Path being mutated.
        path: String,
        /// Session id of the lease holder.
        holder: String,
    },
    /// The gap registry refused to mark the gap as shipped because a
    /// proof-of-merge check did not pass (typically: PR not merged or
    /// commit-trailer assertion failed). The PR was opened/merged via
    /// GitHub but the local registry side-effect was refused.
    #[error("proof-of-merge refused for gap `{gap_id}`: {reason}")]
    ProofOfMergeRefused {
        /// Gap id (e.g. `INFRA-2001`).
        gap_id: String,
        /// Operator-facing reason.
        reason: String,
    },
    /// A second `ManualShipPath` for the same `session_id` attempted to
    /// bind the PID-locked socket. The second one returns this error
    /// rather than running concurrently.
    ///
    /// **Naming**: kept as `BotMergeDoubleInstance` for symmetry with
    /// INFRA-1532, the historical incident class this fix prevents.
    /// `ManualShipPath` is the first impl to enforce single-instance
    /// BY CONSTRUCTION; future bot-merge ports will reuse the same
    /// variant.
    #[error("ship double-instance refused: {detail}")]
    BotMergeDoubleInstance {
        /// Diagnostic including the contested socket path.
        detail: String,
    },
    /// Subprocess `git` returned non-zero. Wraps the rc + stderr tail.
    #[error("git subprocess failed (rc={rc}): {stderr_tail}")]
    Git {
        /// Exit code from `git`.
        rc: i32,
        /// Tail of stderr (truncated to 480 bytes for log sanity).
        stderr_tail: String,
    },
    /// Subprocess `gh` returned non-zero (PR create/arm-auto-merge/etc.).
    #[error("gh subprocess failed (rc={rc}): {stderr_tail}")]
    Gh {
        /// Exit code from `gh`.
        rc: i32,
        /// Tail of stderr (truncated to 480 bytes for log sanity).
        stderr_tail: String,
    },
    /// `gh pr create` succeeded but the PR number could not be parsed
    /// from its stdout. Different from [`ShipError::Gh`] because the
    /// rc was zero — the output shape is unexpected.
    #[error("could not parse PR number from `gh pr create` output: {raw}")]
    UnparseablePrNumber {
        /// Raw stdout from `gh pr create`.
        raw: String,
    },
    /// IO error (socket bind, file read, etc.). The single-instance
    /// EADDRINUSE case is NOT this variant — it's [`ShipError::BotMergeDoubleInstance`].
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// JSON (de)serialization of the receipt failed.
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Truncate a stderr/stdout blob for inclusion in a [`ShipError`].
///
/// The Phase 1 limit (480 bytes) keeps log lines under ~10 lines while
/// still preserving enough context to debug subprocess failures. Used
/// by [`crate::manual_ship`] to populate [`ShipError::Git`] /
/// [`ShipError::Gh`].
pub fn truncate_for_log(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}

/// The ship executor contract.
///
/// Implementations:
/// - [`crate::manual_ship::ManualShipPath`] — happy-path manual ship
///   (Phase 1).
/// - [`crate::bot_merge::BotMergePath`] — STUBBED in Phase 1; Phase 2
///   sub-gap will port `scripts/coord/bot-merge.sh` body.
#[async_trait]
pub trait Ship: Send + Sync {
    /// The intent that constructed this shipper (gap, branch, etc).
    fn intent(&self) -> &ShipIntent<'_>;

    /// Run pre-flight gates synchronously (no I/O against GitHub —
    /// only local state). Returns the full report so callers can log
    /// the breakdown even if one gate failed.
    async fn preflight(&self) -> Result<PreflightReport, ShipError>;

    /// Execute the ship. Returns a [`ShipReceipt`] on success.
    ///
    /// Implementations MUST short-circuit if `preflight()` did not
    /// pass — they should call `preflight()` themselves rather than
    /// trusting the caller to have done so.
    async fn ship(&self) -> Result<ShipReceipt, ShipError>;
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn landing_receipt_new() {
        let r = LandingReceipt::new("INFRA-2001", Some(42));
        assert_eq!(r.gap_id, "INFRA-2001");
        assert_eq!(r.closed_pr, Some(42));
    }

    #[test]
    fn landing_receipt_new_no_pr() {
        let r = LandingReceipt::new("INFRA-2001", None);
        assert_eq!(r.gap_id, "INFRA-2001");
        assert_eq!(r.closed_pr, None);
    }

    #[test]
    fn landing_receipt_validate_ok() {
        let r = LandingReceipt::new("INFRA-2001", Some(42));
        assert!(r.validate().is_ok());
    }

    #[test]
    fn landing_receipt_validate_ok_no_pr() {
        let r = LandingReceipt::new("INFRA-2001", None);
        assert!(r.validate().is_ok());
    }

    #[test]
    fn landing_receipt_validate_empty_gap_id() {
        let r = LandingReceipt::new("", Some(42));
        assert!(r.validate().is_err());
        assert!(r.validate().unwrap_err().contains("empty"));
    }

    #[test]
    fn landing_receipt_validate_negative_pr() {
        let r = LandingReceipt::new("INFRA-2001", Some(-1));
        assert!(r.validate().is_err());
        assert!(r.validate().unwrap_err().contains("positive"));
    }

    #[test]
    fn landing_receipt_validate_zero_pr() {
        let r = LandingReceipt::new("INFRA-2001", Some(0));
        assert!(r.validate().is_err());
        assert!(r.validate().unwrap_err().contains("positive"));
    }

    #[test]
    fn landing_receipt_serialize_to_json() {
        let r = LandingReceipt::new("INFRA-2001", Some(42));
        let j = serde_json::to_string(&r).expect("serialize");
        assert!(j.contains("\"gap_id\":\"INFRA-2001\""));
        assert!(j.contains("\"closed_pr\":42"));
    }

    // CREDIBLE-1550 (Phase R R2, AC3): LandingReceipt carries merge_sha.
    #[test]
    fn landing_receipt_merge_sha_defaults_none() {
        let r = LandingReceipt::new("INFRA-2001", Some(42));
        assert_eq!(r.merge_sha, None);
    }

    #[test]
    fn landing_receipt_with_merge_sha_sets_field() {
        let r = LandingReceipt::new("INFRA-2001", Some(42))
            .with_merge_sha(Some("deadbeefcafe".to_string()));
        assert_eq!(r.merge_sha.as_deref(), Some("deadbeefcafe"));
        assert!(r.validate().is_ok());
    }

    #[test]
    fn landing_receipt_merge_sha_serializes_when_present_omitted_when_absent() {
        let with =
            LandingReceipt::new("INFRA-2001", Some(42)).with_merge_sha(Some("abc123".to_string()));
        let j = serde_json::to_string(&with).expect("serialize");
        assert!(j.contains("\"merge_sha\":\"abc123\""));

        let without = LandingReceipt::new("INFRA-2001", Some(42));
        let j2 = serde_json::to_string(&without).expect("serialize");
        assert!(!j2.contains("merge_sha"));

        // Round-trips back with the SHA intact.
        let back: LandingReceipt = serde_json::from_str(&j).expect("deserialize");
        assert_eq!(back.merge_sha.as_deref(), Some("abc123"));
    }

    #[test]
    fn ship_mode_name_manual() {
        assert_eq!(ShipMode::Manual.name(), "manual");
    }

    #[test]
    fn ship_mode_name_bot_merge() {
        let m = ShipMode::BotMerge {
            bot_session_id: "worker-1".into(),
        };
        assert_eq!(m.name(), "bot-merge");
    }

    #[test]
    fn ship_intent_owned_constructor() {
        let i = ShipIntent::owned("INFRA-2001", "chump/feat", "main", "msg", "sess-a");
        assert_eq!(&*i.gap_id, "INFRA-2001");
        assert_eq!(&*i.branch, "chump/feat");
        assert_eq!(&*i.base, "main");
        assert_eq!(&*i.session_id, "sess-a");
    }

    #[test]
    fn preflight_report_all_passed_empty_is_true() {
        let r = PreflightReport { gates: vec![] };
        assert!(r.all_passed());
        assert!(r.first_failure().is_none());
    }

    #[test]
    fn preflight_report_all_passed_true() {
        let r = PreflightReport {
            gates: vec![
                PreflightGate {
                    name: "a".into(),
                    passed: true,
                    detail: String::new(),
                },
                PreflightGate {
                    name: "b".into(),
                    passed: true,
                    detail: String::new(),
                },
            ],
        };
        assert!(r.all_passed());
        assert!(r.first_failure().is_none());
    }

    #[test]
    fn preflight_report_first_failure_returns_first_failing() {
        let r = PreflightReport {
            gates: vec![
                PreflightGate {
                    name: "a".into(),
                    passed: true,
                    detail: String::new(),
                },
                PreflightGate {
                    name: "b".into(),
                    passed: false,
                    detail: "broke".into(),
                },
                PreflightGate {
                    name: "c".into(),
                    passed: false,
                    detail: "also broke".into(),
                },
            ],
        };
        assert!(!r.all_passed());
        let f = r.first_failure().unwrap();
        assert_eq!(f.name, "b");
        assert_eq!(f.detail, "broke");
    }

    #[test]
    fn ship_error_preflight_failed_display() {
        let e = ShipError::PreflightFailed {
            gate_name: "branch_exists".into(),
            detail: "branch foo not found".into(),
        };
        let s = format!("{e}");
        assert!(s.contains("branch_exists"));
        assert!(s.contains("branch foo not found"));
    }

    #[test]
    fn ship_error_double_instance_display() {
        let e = ShipError::BotMergeDoubleInstance {
            detail: "socket /tmp/chump-ship-sess-a.sock in use".into(),
        };
        let s = format!("{e}");
        assert!(s.contains("double-instance"));
        assert!(s.contains("sock"));
    }

    #[test]
    fn ship_receipt_serializes_to_json() {
        let r = ShipReceipt {
            pr_number: 1913,
            pr_url: "https://github.com/x/y/pull/1913".into(),
            head_sha: "abc1234".into(),
            auto_merge_armed: true,
            shipped_at: Utc::now(),
        };
        let j = serde_json::to_string(&r).expect("serialize");
        assert!(j.contains("\"pr_number\":1913"));
        assert!(j.contains("\"auto_merge_armed\":true"));
        assert!(j.contains("\"head_sha\":\"abc1234\""));
    }

    #[test]
    fn truncate_for_log_short_unchanged() {
        let s = "hello";
        assert_eq!(truncate_for_log(s, 100), "hello");
    }

    #[test]
    fn truncate_for_log_long_truncated() {
        let s = "0123456789".repeat(100);
        let t = truncate_for_log(&s, 50);
        assert_eq!(t.chars().count(), 51); // 50 chars + ellipsis
        assert!(t.ends_with('…'));
    }

    #[test]
    fn ship_mode_serde_round_trip() {
        let m = ShipMode::BotMerge {
            bot_session_id: "worker-3".into(),
        };
        let j = serde_json::to_string(&m).unwrap();
        let back: ShipMode = serde_json::from_str(&j).unwrap();
        assert_eq!(back, m);
    }
}
