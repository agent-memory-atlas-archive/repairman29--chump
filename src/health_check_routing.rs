//! RESILIENT-1354: Routing configuration for fleet health checks.
//!
//! Defines a static mapping from health check identifiers to the action type
//! that should be invoked when a check fails. This enables the health-check
//! dispatcher to route remediation actions appropriately.
//!
//! Check identifiers supported:
//! - `gap-drift`: detects orphaned gaps or staleness in the gap registry
//! - `p0-budget`: monitors P0 budget compliance (≤5 open P0s)
//! - `a2a-consensus`: verifies A2A coordination layer is functional
//! - `curator-silent`: detects curator roles that have stopped emitting signals

use std::collections::HashMap;
use std::sync::OnceLock;

/// Action type for health check remediation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FixerAction {
    /// File a new gap to address the health issue.
    GapFile,
    /// Wake/restart a curator role that has gone silent.
    CuratorWake,
}

impl FixerAction {
    /// Return the string representation of the fixer action.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::GapFile => "gap_file",
            Self::CuratorWake => "curator_wake",
        }
    }
}

impl std::fmt::Display for FixerAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// Health check identifier constants.
pub mod check_id {
    pub const GAP_DRIFT: &str = "gap-drift";
    pub const P0_BUDGET: &str = "p0-budget";
    pub const A2A_CONSENSUS: &str = "a2a-consensus";
    pub const CURATOR_SILENT: &str = "curator-silent";
}

/// Build the static routing map from check ID to fixer action.
fn build_routing_map() -> HashMap<String, FixerAction> {
    let mut map = HashMap::new();

    // `gap-drift`: orphaned gaps or stale registry → file a gap to investigate
    map.insert(check_id::GAP_DRIFT.to_string(), FixerAction::GapFile);

    // `p0-budget`: P0 budget exceeded (>5 open) → file a gap to review and demote
    map.insert(check_id::P0_BUDGET.to_string(), FixerAction::GapFile);

    // `a2a-consensus`: A2A coordination layer not functional → wake the deliberator
    map.insert(
        check_id::A2A_CONSENSUS.to_string(),
        FixerAction::CuratorWake,
    );

    // `curator-silent`: curator role has not emitted signals → wake the role
    map.insert(
        check_id::CURATOR_SILENT.to_string(),
        FixerAction::CuratorWake,
    );

    map
}

/// Get the routing map (lazy-initialized).
fn routing_map() -> &'static HashMap<String, FixerAction> {
    static MAP: OnceLock<HashMap<String, FixerAction>> = OnceLock::new();
    MAP.get_or_init(build_routing_map)
}

/// Look up the fixer action for a given health check identifier.
///
/// Returns `Some(action)` if the check is recognized, `None` otherwise.
pub fn fixer_for_check(check_id: &str) -> Option<FixerAction> {
    routing_map().get(check_id).copied()
}

/// List all known health check identifiers.
pub fn all_checks() -> Vec<&'static str> {
    vec![
        check_id::GAP_DRIFT,
        check_id::P0_BUDGET,
        check_id::A2A_CONSENSUS,
        check_id::CURATOR_SILENT,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gap_drift_maps_to_gap_file() {
        assert_eq!(
            fixer_for_check(check_id::GAP_DRIFT),
            Some(FixerAction::GapFile)
        );
    }

    #[test]
    fn p0_budget_maps_to_gap_file() {
        assert_eq!(
            fixer_for_check(check_id::P0_BUDGET),
            Some(FixerAction::GapFile)
        );
    }

    #[test]
    fn a2a_consensus_maps_to_curator_wake() {
        assert_eq!(
            fixer_for_check(check_id::A2A_CONSENSUS),
            Some(FixerAction::CuratorWake)
        );
    }

    #[test]
    fn curator_silent_maps_to_curator_wake() {
        assert_eq!(
            fixer_for_check(check_id::CURATOR_SILENT),
            Some(FixerAction::CuratorWake)
        );
    }

    #[test]
    fn unknown_check_returns_none() {
        assert_eq!(fixer_for_check("unknown-check"), None);
    }

    #[test]
    fn all_checks_returns_four_checks() {
        let checks = all_checks();
        assert_eq!(checks.len(), 4);
        assert!(checks.contains(&check_id::GAP_DRIFT));
        assert!(checks.contains(&check_id::P0_BUDGET));
        assert!(checks.contains(&check_id::A2A_CONSENSUS));
        assert!(checks.contains(&check_id::CURATOR_SILENT));
    }

    #[test]
    fn fixer_action_display() {
        assert_eq!(FixerAction::GapFile.to_string(), "gap_file");
        assert_eq!(FixerAction::CuratorWake.to_string(), "curator_wake");
    }

    #[test]
    fn fixer_action_as_str() {
        assert_eq!(FixerAction::GapFile.as_str(), "gap_file");
        assert_eq!(FixerAction::CuratorWake.as_str(), "curator_wake");
    }
}
