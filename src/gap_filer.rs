//! RESILIENT-1356: Gap filing and deduplication for fleet-doctor health checks.
//!
//! When a health check fails, fleet-doctor needs to file a gap documenting the issue.
//! This module provides:
//! - Filing a new gap with a tag matching the check identifier
//! - Deduplication: if an open gap with the same tag already exists, the call is a no-op
//! - Clear result indicating success or reason for no-op

use anyhow::Result;
use std::path::Path;

/// Outcome of filing a gap for a health check failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileGapOutcome {
    /// Successfully created a new gap with the given ID.
    Created(String),
    /// Gap already existed as open; no-op (idempotent).
    AlreadyOpen(String),
}

impl FileGapOutcome {
    /// Human-readable message describing what happened.
    pub fn message(&self) -> String {
        match self {
            Self::Created(id) => format!("created new gap {}", id),
            Self::AlreadyOpen(id) => format!("gap {} already exists (open); no-op", id),
        }
    }

    /// Return the gap ID (either newly created or already existing).
    pub fn gap_id(&self) -> &str {
        match self {
            Self::Created(id) | Self::AlreadyOpen(id) => id,
        }
    }
}

/// Convert a check identifier to a tag string used for deduplication.
/// The tag is derived from the check_id and will be stored in the gap's `notes` field.
fn make_tag_from_check_id(check_id: &str) -> String {
    format!("health-check:{}", check_id)
}

/// Try to find an existing open gap with the given tag.
/// Returns the gap ID if found, or None if not found.
fn find_existing_gap_by_tag(
    store: &chump_gap_store::GapStore,
    tag: &str,
) -> Result<Option<String>> {
    let all_gaps = store.list(Some("open"))?;
    Ok(all_gaps
        .into_iter()
        .find(|g| g.notes.contains(tag))
        .map(|g| g.id))
}

/// File a new gap for a health check failure with deduplication.
///
/// When called, either:
/// 1. Creates a new gap with a tag matching the check identifier (returns `Created(id)`), or
/// 2. Finds an existing open gap with the same tag and returns `AlreadyOpen(id)` (idempotent no-op).
///
/// The function uses `notes` field to store the dedup tag (`health-check:<check_id>`).
///
/// # Arguments
/// * `repo_root` - Path to the chump repository root (used to locate state.db)
/// * `check_id` - The health check identifier (e.g., "gap-drift", "p0-budget")
/// * `title` - Title for the gap (only used when creating a new gap)
/// * `domain` - Gap domain, typically "INFRA"
/// * `priority` - Gap priority ("P0".."P3"), typically "P1" for health check gaps
/// * `effort` - Estimated effort ("xs", "s", "m", "l")
///
/// # Returns
/// * `Ok(FileGapOutcome)` - Either created or already exists
/// * `Err(...)` - Error opening store or updating gap
pub fn file_gap_with_dedup(
    repo_root: &Path,
    check_id: &str,
    title: &str,
    domain: &str,
    priority: &str,
    effort: &str,
) -> Result<FileGapOutcome> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let tag = make_tag_from_check_id(check_id);

    // Check if we already have an open gap with this tag
    if let Some(existing_id) = find_existing_gap_by_tag(&store, &tag)? {
        return Ok(FileGapOutcome::AlreadyOpen(existing_id));
    }

    // No existing gap; create a new one
    let gap_id = store.reserve(domain, title, priority, effort)?;

    // Record the tag in notes for future dedup lookups
    let update = chump_gap_store::GapFieldUpdate {
        notes: Some(tag),
        ..Default::default()
    };
    store.set_fields(&gap_id, update)?;

    Ok(FileGapOutcome::Created(gap_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn make_tag_from_check_id_formats_correctly() {
        assert_eq!(
            make_tag_from_check_id("gap-drift"),
            "health-check:gap-drift"
        );
        assert_eq!(
            make_tag_from_check_id("p0-budget"),
            "health-check:p0-budget"
        );
    }

    #[test]
    fn file_gap_outcome_created_returns_gap_id() {
        let outcome = FileGapOutcome::Created("INFRA-1234".to_string());
        assert_eq!(outcome.gap_id(), "INFRA-1234");
        assert_eq!(outcome.message(), "created new gap INFRA-1234");
    }

    #[test]
    fn file_gap_outcome_already_open_returns_gap_id() {
        let outcome = FileGapOutcome::AlreadyOpen("INFRA-5678".to_string());
        assert_eq!(outcome.gap_id(), "INFRA-5678");
        assert_eq!(
            outcome.message(),
            "gap INFRA-5678 already exists (open); no-op"
        );
    }

    #[test]
    fn file_gap_with_dedup_creates_new_gap() {
        let dir = tempdir().unwrap();
        let repo_root = dir.path();

        let outcome = file_gap_with_dedup(
            repo_root,
            "gap-drift",
            "test gap drift gap",
            "INFRA",
            "P2",
            "s",
        )
        .unwrap();

        assert!(matches!(outcome, FileGapOutcome::Created(_)));
        let gap_id = outcome.gap_id();

        // Verify the gap exists
        let store = chump_gap_store::GapStore::open(repo_root).unwrap();
        let gap = store.get(gap_id).unwrap().unwrap();
        assert!(gap.notes.contains("health-check:gap-drift"));
    }

    #[test]
    fn file_gap_with_dedup_returns_already_open_on_second_call() {
        let dir = tempdir().unwrap();
        let repo_root = dir.path();

        // First call: creates a gap
        let outcome1 =
            file_gap_with_dedup(repo_root, "p0-budget", "test p0 budget", "INFRA", "P2", "s")
                .unwrap();
        assert!(matches!(outcome1, FileGapOutcome::Created(_)));
        let gap_id1 = outcome1.gap_id().to_string();

        // Second call: finds the existing gap
        let outcome2 = file_gap_with_dedup(
            repo_root,
            "p0-budget",
            "different title (ignored on dedup)",
            "INFRA",
            "P1",
            "m",
        )
        .unwrap();
        assert!(matches!(outcome2, FileGapOutcome::AlreadyOpen(_)));
        assert_eq!(outcome2.gap_id(), &gap_id1);
    }

    #[test]
    fn file_gap_with_dedup_creates_separate_gaps_for_different_checks() {
        let dir = tempdir().unwrap();
        let repo_root = dir.path();

        let outcome1 = file_gap_with_dedup(
            repo_root,
            "gap-drift",
            "gap drift issue",
            "INFRA",
            "P2",
            "s",
        )
        .unwrap();

        let outcome2 = file_gap_with_dedup(
            repo_root,
            "p0-budget",
            "p0 budget exceeded",
            "INFRA",
            "P2",
            "s",
        )
        .unwrap();

        // Both should be created (different tags)
        assert!(matches!(outcome1, FileGapOutcome::Created(_)));
        assert!(matches!(outcome2, FileGapOutcome::Created(_)));

        // Should be different IDs
        assert_ne!(outcome1.gap_id(), outcome2.gap_id());
    }
}
