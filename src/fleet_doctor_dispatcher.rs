//! RESILIENT-1355: Routing dispatcher for fleet-doctor health check failures.
//!
//! When `chump fleet doctor --strict` detects a health check FAIL, this dispatcher
//! routes the failure to the appropriate remediation handler based on the
//! `health_check_routing` configuration.
//!
//! Handlers:
//! - `gap_file`: Creates a new gap documenting the health issue for fleet review.
//! - `curator_wake`: Triggers a restart of the silent/stuck curator role.
//!
//! Each dispatch logs the chosen action at INFO level via ambient events for audit trail visibility.

use crate::ambient_emit::{emit, EmitArgs};
use crate::gap_filer;
use crate::health_check_routing::{self, FixerAction};
use anyhow::Result;
use std::path::Path;

/// Result of dispatching a single health check failure.
#[derive(Debug, Clone)]
pub struct DispatchOutcome {
    pub check_id: String,
    pub action: FixerAction,
    pub success: bool,
    pub message: String,
}

/// Dispatch a single health check FAIL to its handler.
///
/// Looks up the check_id in the routing config to determine the appropriate
/// action (gap_file or curator_wake), then invokes the handler.
/// Logs the chosen action at INFO level via ambient events.
///
/// # Arguments
/// * `repo_root` - Path to the chump repository root (used for gap store access)
/// * `check_id` - The health check identifier (e.g., "gap-drift")
///
/// Returns a DispatchOutcome documenting what was attempted and whether it succeeded.
pub fn dispatch_fail(repo_root: &Path, check_id: &str) -> DispatchOutcome {
    match health_check_routing::fixer_for_check(check_id) {
        Some(action) => {
            let _ = emit(&EmitArgs {
                kind: "fleet_doctor_dispatcher_invoked".to_string(),
                source: Some("fleet_doctor_dispatcher".to_string()),
                fields: vec![
                    ("check_id".to_string(), check_id.to_string()),
                    ("action".to_string(), action.as_str().to_string()),
                ],
                ..Default::default()
            });
            match action {
                FixerAction::GapFile => handle_gap_file(repo_root, check_id),
                FixerAction::CuratorWake => handle_curator_wake(check_id),
            }
        }
        None => {
            let message = format!("unknown health check: {}; no action configured", check_id);
            let _ = emit(&EmitArgs {
                kind: "fleet_doctor_dispatcher_unknown_check".to_string(),
                source: Some("fleet_doctor_dispatcher".to_string()),
                fields: vec![("check_id".to_string(), check_id.to_string())],
                ..Default::default()
            });
            DispatchOutcome {
                check_id: check_id.to_string(),
                action: FixerAction::GapFile,
                success: false,
                message,
            }
        }
    }
}

/// Handler for `gap_file` action: file a new gap documenting the health issue.
fn handle_gap_file(repo_root: &Path, check_id: &str) -> DispatchOutcome {
    let title = match check_id {
        health_check_routing::check_id::GAP_DRIFT => {
            "INFRA: Fleet doctor detected gap registry drift — investigate orphaned or stale gaps"
        }
        health_check_routing::check_id::P0_BUDGET => {
            "INFRA: Fleet doctor P0 budget exceeded — review and demote lower-priority P0s"
        }
        _ => "INFRA: Fleet doctor health check failed — investigate and remediate",
    };

    // Attempt to file the gap with deduplication
    match gap_filer::file_gap_with_dedup(repo_root, check_id, title, "INFRA", "P1", "s") {
        Ok(outcome) => {
            let (message, gap_id) = match outcome {
                gap_filer::FileGapOutcome::Created(id) => {
                    (format!("gap_file handler: created new gap {}", id), id)
                }
                gap_filer::FileGapOutcome::AlreadyOpen(id) => (
                    format!("gap_file handler: gap {} already exists (idempotent)", id),
                    id,
                ),
            };

            let _ = emit(&EmitArgs {
                kind: "fleet_doctor_dispatcher_gap_file".to_string(),
                source: Some("fleet_doctor_dispatcher".to_string()),
                fields: vec![
                    ("check_id".to_string(), check_id.to_string()),
                    ("action".to_string(), "gap_file".to_string()),
                    ("gap_id".to_string(), gap_id.clone()),
                    ("title".to_string(), title.to_string()),
                ],
                ..Default::default()
            });

            DispatchOutcome {
                check_id: check_id.to_string(),
                action: FixerAction::GapFile,
                success: true,
                message,
            }
        }
        Err(e) => {
            let message = format!("gap_file handler: error filing gap: {}", e);
            let _ = emit(&EmitArgs {
                kind: "fleet_doctor_dispatcher_gap_file_error".to_string(),
                source: Some("fleet_doctor_dispatcher".to_string()),
                fields: vec![
                    ("check_id".to_string(), check_id.to_string()),
                    ("error".to_string(), e.to_string()),
                ],
                ..Default::default()
            });

            DispatchOutcome {
                check_id: check_id.to_string(),
                action: FixerAction::GapFile,
                success: false,
                message,
            }
        }
    }
}

/// Send a wake signal to a curator via the existing communication channel.
///
/// Sends a wake message to the specified curator identifier via the ambient event
/// system, logging the wake event at DEBUG level.
///
/// # Arguments
/// * `curator_id` - The curator identifier (e.g., "deliberator", "handoff")
///
/// # Returns
/// A Result confirming delivery via the ambient event system.
pub fn curator_wake_signal(curator_id: &str) -> Result<()> {
    tracing::debug!(
        "curator_wake_signal: sending wake message to curator '{}'",
        curator_id
    );

    let _ = emit(&EmitArgs {
        kind: "curator_wake_signal".to_string(),
        source: Some("fleet_doctor_dispatcher".to_string()),
        fields: vec![
            ("curator_id".to_string(), curator_id.to_string()),
            ("action".to_string(), "wake".to_string()),
        ],
        ..Default::default()
    })?;

    tracing::debug!(
        "curator_wake_signal: wake message delivered to curator '{}'",
        curator_id
    );
    Ok(())
}

/// Handler for `curator_wake` action: trigger restart of silent curator role.
fn handle_curator_wake(check_id: &str) -> DispatchOutcome {
    let curator_label = match check_id {
        health_check_routing::check_id::A2A_CONSENSUS => "deliberator",
        health_check_routing::check_id::CURATOR_SILENT => "silent-curator",
        _ => "unknown-curator",
    };

    let _ = emit(&EmitArgs {
        kind: "fleet_doctor_dispatcher_curator_wake".to_string(),
        source: Some("fleet_doctor_dispatcher".to_string()),
        fields: vec![
            ("check_id".to_string(), check_id.to_string()),
            ("action".to_string(), "curator_wake".to_string()),
            ("curator".to_string(), curator_label.to_string()),
        ],
        ..Default::default()
    });

    match curator_wake_signal(curator_label) {
        Ok(()) => {
            let updated_message = format!(
                "curator_wake handler: sent wake signal to curator '{}'",
                curator_label
            );
            DispatchOutcome {
                check_id: check_id.to_string(),
                action: FixerAction::CuratorWake,
                success: true,
                message: updated_message,
            }
        }
        Err(e) => {
            let error_message = format!(
                "curator_wake handler: failed to wake curator '{}': {}",
                curator_label, e
            );
            DispatchOutcome {
                check_id: check_id.to_string(),
                action: FixerAction::CuratorWake,
                success: false,
                message: error_message,
            }
        }
    }
}

/// Dispatch all failures from a health report.
pub fn dispatch_all_failures(repo_root: &Path, check_ids: &[&str]) -> Vec<DispatchOutcome> {
    check_ids
        .iter()
        .map(|id| dispatch_fail(repo_root, id))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn gap_drift_routes_to_gap_file() {
        let dir = tempdir().unwrap();
        let outcome = dispatch_fail(dir.path(), health_check_routing::check_id::GAP_DRIFT);
        assert_eq!(outcome.check_id, "gap-drift");
        assert_eq!(outcome.action, FixerAction::GapFile);
        assert!(outcome.success);
    }

    #[test]
    fn p0_budget_routes_to_gap_file() {
        let dir = tempdir().unwrap();
        let outcome = dispatch_fail(dir.path(), health_check_routing::check_id::P0_BUDGET);
        assert_eq!(outcome.check_id, "p0-budget");
        assert_eq!(outcome.action, FixerAction::GapFile);
        assert!(outcome.success);
    }

    #[test]
    fn a2a_consensus_routes_to_curator_wake() {
        let dir = tempdir().unwrap();
        let outcome = dispatch_fail(dir.path(), health_check_routing::check_id::A2A_CONSENSUS);
        assert_eq!(outcome.check_id, "a2a-consensus");
        assert_eq!(outcome.action, FixerAction::CuratorWake);
        assert!(outcome.success);
    }

    #[test]
    fn curator_silent_routes_to_curator_wake() {
        let dir = tempdir().unwrap();
        let outcome = dispatch_fail(dir.path(), health_check_routing::check_id::CURATOR_SILENT);
        assert_eq!(outcome.check_id, "curator-silent");
        assert_eq!(outcome.action, FixerAction::CuratorWake);
        assert!(outcome.success);
    }

    #[test]
    fn unknown_check_fails_gracefully() {
        let dir = tempdir().unwrap();
        let outcome = dispatch_fail(dir.path(), "unknown-check-id");
        assert_eq!(outcome.check_id, "unknown-check-id");
        assert!(!outcome.success);
    }

    #[test]
    fn dispatch_all_failures_processes_multiple_checks() {
        let dir = tempdir().unwrap();
        let checks = vec![
            health_check_routing::check_id::GAP_DRIFT,
            health_check_routing::check_id::P0_BUDGET,
        ];
        let outcomes = dispatch_all_failures(dir.path(), &checks);
        assert_eq!(outcomes.len(), 2);
        assert!(outcomes[0].success);
        assert!(outcomes[1].success);
    }

    #[test]
    fn curator_wake_signal_sends_wake_message() {
        let result = curator_wake_signal("test-curator");
        assert!(result.is_ok());
    }

    #[test]
    fn curator_wake_signal_returns_result_on_delivery() {
        let curator_id = "deliberator";
        let result = curator_wake_signal(curator_id);
        assert!(
            result.is_ok(),
            "curator_wake_signal should return Ok on successful delivery"
        );
    }

    #[test]
    fn handle_curator_wake_calls_curator_wake_signal() {
        let dir = tempdir().unwrap();
        let outcome = dispatch_fail(dir.path(), health_check_routing::check_id::A2A_CONSENSUS);
        assert_eq!(outcome.check_id, "a2a-consensus");
        assert_eq!(outcome.action, FixerAction::CuratorWake);
        assert!(outcome.success);
        assert!(outcome.message.contains("sent wake signal"));
    }

    /// RESILIENT-1359: Integration test for synthetic FAIL triggering gap filing.
    /// 1. Use synthetic FAIL generator for `gap-drift` health check
    /// 2. After fleet-doctor processes the payload, query gap store and assert
    ///    a new gap with tag `gap-drift` exists
    /// 3. Running the test a second time does not create a duplicate gap
    #[test]
    fn synthetic_fail_triggers_gap_filing_with_dedup() {
        let dir = tempdir().unwrap();
        let repo_root = dir.path();

        // First call: dispatch_fail processes a synthetic FAIL for gap-drift
        let outcome1 = dispatch_fail(repo_root, health_check_routing::check_id::GAP_DRIFT);
        assert_eq!(outcome1.check_id, "gap-drift");
        assert_eq!(outcome1.action, FixerAction::GapFile);
        assert!(outcome1.success);

        // Verify the gap was created by querying the gap store
        let store = chump_gap_store::GapStore::open(repo_root).expect("gap store should open");
        let gaps = store.list(Some("open")).expect("should list open gaps");

        // Find the gap with the gap-drift tag
        let gap_with_drift_tag = gaps
            .iter()
            .find(|g| g.notes.contains("health-check:gap-drift"))
            .expect("gap with gap-drift tag should exist");

        assert!(gap_with_drift_tag.notes.contains("health-check:gap-drift"));
        let first_gap_id = gap_with_drift_tag.id.clone();

        // Second call: dispatch_fail processes the same synthetic FAIL for gap-drift again
        let outcome2 = dispatch_fail(repo_root, health_check_routing::check_id::GAP_DRIFT);
        assert_eq!(outcome2.check_id, "gap-drift");
        assert_eq!(outcome2.action, FixerAction::GapFile);
        assert!(outcome2.success);

        // Verify the gap was NOT duplicated — the same gap ID should be returned
        let gaps = store.list(Some("open")).expect("should list open gaps");

        let gap_drift_gaps = gaps
            .iter()
            .filter(|g| g.notes.contains("health-check:gap-drift"))
            .collect::<Vec<_>>();

        // Should still be exactly one gap with the gap-drift tag (idempotent)
        assert_eq!(
            gap_drift_gaps.len(),
            1,
            "should not create duplicate gap-drift gaps"
        );
        assert_eq!(
            gap_drift_gaps[0].id, first_gap_id,
            "second call should return the same gap ID"
        );
    }
}
