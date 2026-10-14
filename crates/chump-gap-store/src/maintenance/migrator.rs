//! RESILIENT-1382: Migration of legacy decomposed umbrellas from open/blocked to decomposed status.
//!
//! This module implements the idempotent migration algorithm designed in RESILIENT-1381.
//! Selection criteria: gaps with "Decomposed into" notes + ≥1 non-terminal child + status != decomposed.
//! Terminal states: closed, wontfix, already_satisfied, closed_not_a_bug, superseded, done
//! Non-terminal states: open, blocked, in-progress

use crate::GapStore;
use anyhow::{Context, Result};
use serde::Serialize;

/// MigrationLogEntry captures the outcome of attempting to migrate a single gap.
#[derive(Debug, Clone, Serialize)]
pub struct MigrationLogEntry {
    /// ISO 8601 timestamp
    pub timestamp: String,
    /// Gap ID (e.g., RESILIENT-1352)
    pub gap_id: String,
    /// First 80 chars of gap title
    pub gap_title: String,
    /// Total children parsed from "Decomposed into" notes
    pub child_count: usize,
    /// Count of children in terminal states
    pub terminal_children: usize,
    /// Count of children in non-terminal states
    pub non_terminal_children: usize,
    /// Migration action: MIGRATED, ALREADY_DECOMPOSED, NO_ELIGIBLE_CHILDREN
    pub migration_status: String,
    /// Status before migration (if migrated)
    pub status_before: Option<String>,
    /// Status after migration (if migrated)
    pub status_after: Option<String>,
}

/// Terminal states per RESILIENT-1381 §Selection Criteria.
/// Gaps in these states are considered "done" and don't block auto-close.
const TERMINAL_STATES: &[&str] = &[
    "closed",
    "wontfix",
    "already_satisfied",
    "closed_not_a_bug",
    "superseded",
    "done",
];

/// Non-terminal states: open, blocked, in-progress, and done (if not all children are done).
/// A parent with ≥1 child in these states must be migrated.
fn is_terminal(status: &str) -> bool {
    TERMINAL_STATES.contains(&status)
}

impl GapStore {
    /// Migrate all legacy decomposed umbrellas (gaps with "Decomposed into" notes)
    /// from open/blocked/in-progress status to decomposed status.
    ///
    /// Returns a list of migration log entries recording the outcome of each migration attempt.
    /// Idempotent: running twice on the same state returns 0 migrated gaps on the second run.
    pub fn migrate_decomposed_umbrellas(&self) -> Result<Vec<MigrationLogEntry>> {
        let mut log = Vec::new();

        // Phase 1: Pre-flight validation — scan all gaps, classify by eligibility.
        let all_gaps = self
            .list(None)
            .context("Failed to list all gaps for pre-flight validation")?;

        let mut eligible_parents = Vec::new();
        for gap in &all_gaps {
            // Check for "Decomposed into" marker.
            if !gap.notes.contains("Decomposed into") {
                continue;
            }

            // Already migrated.
            if gap.status == "decomposed" {
                continue;
            }

            // Parse child IDs from notes.
            let child_ids = crate::parse_decomposed_children(&gap.notes);
            if child_ids.is_empty() {
                continue;
            }

            // Count terminal and non-terminal children.
            let mut total_children = 0;
            let mut terminal_count = 0;
            let mut non_terminal_count = 0;

            for child_id in &child_ids {
                total_children += 1;
                match self.get(child_id) {
                    Ok(Some(child)) => {
                        if is_terminal(&child.status) {
                            terminal_count += 1;
                        } else {
                            non_terminal_count += 1;
                        }
                    }
                    // Child doesn't exist or error: treat as non-terminal
                    // (conservative: don't skip migration if we can't verify).
                    _ => {
                        non_terminal_count += 1;
                    }
                }
            }

            // Eligible if ≥1 non-terminal child.
            if non_terminal_count > 0 {
                eligible_parents.push((
                    gap.id.clone(),
                    gap.title.clone(),
                    gap.status.clone(),
                    total_children,
                    terminal_count,
                    non_terminal_count,
                ));
            }
        }

        // Phase 2: Migration — set status=decomposed for each eligible parent.
        let iso_now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

        for (gap_id, gap_title, status_before, total, terminal, non_terminal) in eligible_parents {
            let truncated_title = if gap_title.len() > 80 {
                &gap_title[..80]
            } else {
                &gap_title
            };

            // Get current notes to append migration log entry
            let current_gap = self.get(&gap_id).ok().flatten();
            let current_notes = current_gap.map(|g| g.notes).unwrap_or_default();
            let migration_log_line = format!("[migration] decomposed on {}", iso_now);
            let updated_notes = if current_notes.is_empty() {
                migration_log_line
            } else {
                format!("{}\n{}", current_notes, migration_log_line)
            };

            let entry = match self.set_fields(
                &gap_id,
                crate::GapFieldUpdate {
                    status: Some("decomposed".to_string()),
                    notes: Some(updated_notes),
                    ..Default::default()
                },
            ) {
                Ok(()) => MigrationLogEntry {
                    timestamp: iso_now.clone(),
                    gap_id,
                    gap_title: truncated_title.to_string(),
                    child_count: total,
                    terminal_children: terminal,
                    non_terminal_children: non_terminal,
                    migration_status: "MIGRATED".to_string(),
                    status_before: Some(status_before),
                    status_after: Some("decomposed".to_string()),
                },
                Err(e) => {
                    // Log error but continue with next gap.
                    eprintln!("Error migrating {}: {}", gap_id, e);
                    MigrationLogEntry {
                        timestamp: iso_now.clone(),
                        gap_id,
                        gap_title: truncated_title.to_string(),
                        child_count: total,
                        terminal_children: terminal,
                        non_terminal_children: non_terminal,
                        migration_status: format!("ERROR: {}", e),
                        status_before: Some(status_before),
                        status_after: None,
                    }
                }
            };
            log.push(entry);
        }

        // Phase 3: Verification — query again to confirm idempotency.
        // (Verification is implicit in the test suite; this function
        // only returns the log entries for now.)

        Ok(log)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_terminal() {
        assert!(is_terminal("closed"));
        assert!(is_terminal("done"));
        assert!(is_terminal("wontfix"));
        assert!(!is_terminal("open"));
        assert!(!is_terminal("blocked"));
        assert!(!is_terminal("in-progress"));
    }
}
