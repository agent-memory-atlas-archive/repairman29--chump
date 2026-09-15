//! Shared `StructuredFinding` types for the ChumpOS comprehension organs
//! (comprehend / flagmap / gatemap / livemap / tracemap). Organs currently
//! emit human prose only; this crate defines the structured shape they need
//! to instead emit machine-parseable findings that a thin filer can pipe into
//! holler and a verifier can consume (INFRA-3470 slice).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One structured observation emitted by a comprehension organ.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StructuredFinding {
    /// Which organ dimension this finding belongs to.
    pub category: FindingCategory,
    /// Where the finding applies — a file path, symbol name, or gate/flag
    /// identifier, depending on `category`.
    pub location: String,
    /// How urgent the finding is.
    pub severity: Severity,
    /// Free-form key/value context (e.g. `flag_name`, `bypass_count`,
    /// `coverage_status`). Kept as a map instead of fixed fields since each
    /// organ's context shape differs.
    pub metadata: BTreeMap<String, String>,
}

/// Which comprehension organ produced (or would produce) a finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FindingCategory {
    /// comprehend: is a capability wired up and reachable.
    Wiring,
    /// gatemap: CI/hook gates a change trips + their bypasses.
    Gate,
    /// flagmap: config flags + inconsistent-default drift.
    Config,
    /// whymap: git-blame provenance for why code exists.
    Provenance,
    /// tracemap: PR/issue history traces.
    Trace,
}

/// Finding severity, ordered least to most urgent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Info,
    Low,
    Medium,
    High,
    Critical,
}

impl StructuredFinding {
    pub fn new(category: FindingCategory, location: impl Into<String>, severity: Severity) -> Self {
        Self {
            category,
            location: location.into(),
            severity,
            metadata: BTreeMap::new(),
        }
    }

    pub fn with_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_json() {
        let finding =
            StructuredFinding::new(FindingCategory::Gate, "ci.yml:fast-checks", Severity::High)
                .with_metadata("bypass_count", "3")
                .with_metadata("coverage_status", "full");

        let json = serde_json::to_string(&finding).expect("serialize");
        let back: StructuredFinding = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(back, finding);
        assert_eq!(back.category, FindingCategory::Gate);
        assert_eq!(back.severity, Severity::High);
        assert_eq!(
            back.metadata.get("bypass_count").map(String::as_str),
            Some("3")
        );
    }

    #[test]
    fn category_and_severity_serialize_as_snake_case() {
        let finding =
            StructuredFinding::new(FindingCategory::Provenance, "src/foo.rs", Severity::Info);
        let json = serde_json::to_value(&finding).expect("serialize");
        assert_eq!(json["category"], "provenance");
        assert_eq!(json["severity"], "info");
    }

    #[test]
    fn severity_orders_least_to_most_urgent() {
        assert!(Severity::Info < Severity::Low);
        assert!(Severity::Low < Severity::Medium);
        assert!(Severity::Medium < Severity::High);
        assert!(Severity::High < Severity::Critical);
    }
}
