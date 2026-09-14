//! INFRA-3495 (COTG-3.2): anti-over-claim watchdog — the "umbrella-done !=
//! actually-done" sweep over DONE gaps.
//!
//! The gardener audits OPEN gaps for hygiene; nothing audited DONE gaps for
//! hollowness. `pr_ac_coverage` (INFRA-1541) scores a PR's diff against its
//! gap's acceptance bullets, but only PRE-merge, per-PR. This re-runs that SAME
//! coverage engine AFTER the fact, against each recently-closed gap's PR, and
//! flags any whose acceptance bullets shipped uncovered and unwaived — a gap
//! marked `done` whose AC weren't actually met. Reuses the coverage engine
//! wholesale; only the "sweep what already shipped" loop is new.

use crate::pr_ac_coverage::{self, AcCoverageResult};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};

/// Pure decision (no network) over an already-computed coverage result: a done
/// gap over-claims if its PR left acceptance bullets uncovered AND unwaived.
/// Returns the uncovered bullet indices, or None when every bullet is covered or
/// waived. Split out from the network sweep so the flag rule is unit-testable.
pub fn is_over_claim(coverage: &AcCoverageResult) -> Option<Vec<usize>> {
    let uncovered: Vec<usize> = coverage
        .bullets
        .iter()
        .filter(|b| !b.covered && !b.waived)
        .map(|b| b.index)
        .collect();
    if uncovered.is_empty() {
        None
    } else {
        Some(uncovered)
    }
}

/// One flagged over-claim.
#[derive(Debug, Clone)]
pub struct OverClaim {
    pub gap_id: String,
    pub closed_pr: i64,
    pub uncovered: Vec<usize>,
    pub total_bullets: usize,
}

/// Result of a done-gap audit sweep.
#[derive(Debug, Default)]
pub struct DoneAuditReport {
    pub audited: usize,
    pub skipped_no_pr: usize,
    pub skipped_no_ac: usize,
    pub fetch_errors: usize,
    pub flagged: Vec<OverClaim>,
}

impl DoneAuditReport {
    /// True when at least one done gap over-claims — the CI/daemon exit signal.
    pub fn failing(&self) -> bool {
        !self.flagged.is_empty()
    }

    pub fn render(&self) -> String {
        let mut out = format!(
            "done-gap over-claim audit: {} audited, {} flagged ({} no-pr, {} no-ac, {} fetch-err skipped)\n",
            self.audited,
            self.flagged.len(),
            self.skipped_no_pr,
            self.skipped_no_ac,
            self.fetch_errors
        );
        for oc in &self.flagged {
            out.push_str(&format!(
                "  \u{26a0} {} (#{}) over-claims: {}/{} acceptance bullets uncovered+unwaived (indices {:?})\n",
                oc.gap_id,
                oc.closed_pr,
                oc.uncovered.len(),
                oc.total_bullets,
                oc.uncovered
            ));
        }
        if self.flagged.is_empty() {
            out.push_str("  \u{2713} no over-claims among audited done gaps\n");
        }
        out
    }
}

/// CREDIBLE-1203: resume cursor persisted between runs so consecutive
/// bounded sweeps make forward progress across the whole DONE set instead
/// of re-auditing the same head-of-list gaps every time.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct AuditCursor {
    /// (closed_at, id) of the last gap examined by the previous run.
    /// `closed_at` mirrors SQLite's ASC NULL-first ordering: `None` sorts
    /// before any `Some(_)`, matching `Option<i64>`'s derived `Ord`.
    last_closed_at: Option<i64>,
    last_id: String,
}

fn cursor_path(repo_root: &Path) -> PathBuf {
    repo_root
        .join(".chump-locks")
        .join("done_auditor_cursor.json")
}

fn load_cursor(repo_root: &Path) -> AuditCursor {
    std::fs::read_to_string(cursor_path(repo_root))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_cursor(repo_root: &Path, cursor: &AuditCursor) {
    let path = cursor_path(repo_root);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string(cursor) {
        let _ = std::fs::write(path, json);
    }
}

/// Select the next `limit` gaps to examine, starting strictly after
/// `cursor` in (closed_at, id) order and wrapping around to the start of
/// `done` when fewer than `limit` remain — so a populated store is fully
/// covered (and re-covered) over successive runs rather than stalling once
/// the cursor reaches the tail.
fn select_window<'a>(
    done: &'a [chump_gap_store::GapRow],
    cursor: &AuditCursor,
) -> Vec<&'a chump_gap_store::GapRow> {
    let after_cursor: Vec<&chump_gap_store::GapRow> = done
        .iter()
        .filter(|g| (g.closed_at, g.id.as_str()) > (cursor.last_closed_at, cursor.last_id.as_str()))
        .collect();
    if after_cursor.is_empty() {
        // Cursor is at or past the tail (or stale/empty) — wrap to the start.
        done.iter().collect()
    } else {
        after_cursor
    }
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep.
///
/// CREDIBLE-339: gaps returned oldest-closed-first so each limited run
/// makes forward progress without re-auditing the same set.
/// CREDIBLE-1203: a persistent cursor (`.chump-locks/done_auditor_cursor.json`)
/// tracks the last examined `(closed_at, id)` so consecutive runs examine
/// disjoint windows of the DONE set (wrapping once the tail is reached)
/// rather than always re-auditing the oldest `limit` gaps.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list_by_status_ordered("done")?;
    let cursor = load_cursor(repo_root);
    let window = select_window(&done, &cursor);
    let mut report = DoneAuditReport::default();
    let mut last_examined: Option<(Option<i64>, String)> = None;
    for g in window.into_iter().take(limit) {
        last_examined = Some((g.closed_at, g.id.clone()));
        let pr = match g.closed_pr {
            Some(p) if p > 0 => p,
            _ => {
                report.skipped_no_pr += 1;
                continue;
            }
        };
        if g.acceptance_criteria.trim().is_empty() {
            report.skipped_no_ac += 1;
            continue;
        }
        report.audited += 1;
        let coverage = match pr_ac_coverage::run(pr as u64) {
            Ok(c) => c,
            Err(_) => {
                report.fetch_errors += 1;
                continue;
            }
        };
        if let Some(uncovered) = is_over_claim(&coverage) {
            emit_over_claim(repo_root, &g.id, pr, &uncovered, coverage.bullets.len());
            report.flagged.push(OverClaim {
                gap_id: g.id.clone(),
                closed_pr: pr,
                uncovered,
                total_bullets: coverage.bullets.len(),
            });
        }
    }
    if let Some((last_closed_at, last_id)) = last_examined {
        save_cursor(
            repo_root,
            &AuditCursor {
                last_closed_at,
                last_id,
            },
        );
    }
    Ok(report)
}

/// Best-effort append of an `over_claim_suspected` event to the ambient stream.
fn emit_over_claim(repo_root: &Path, gap_id: &str, pr: i64, uncovered: &[usize], total: usize) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let path = lock_dir.join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    // scanner-anchor: "kind":"over_claim_suspected"
    let line = format!(
        r#"{{"ts":"{ts}","kind":"over_claim_suspected","gap_id":"{gap_id}","closed_pr":{pr},"uncovered_bullets":{},"total_bullets":{total}}}"#,
        uncovered.len()
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pr_ac_coverage::{AcCoverageResult, BulletResult, CoverageStatus};

    fn bullet(index: usize, covered: bool, waived: bool) -> BulletResult {
        BulletResult {
            index,
            text: format!("bullet {index}"),
            covered,
            waived,
            waive_reason: None,
            rules_hit: vec![],
            is_proof: false,
            proof_detail: None,
        }
    }

    #[test]
    fn is_over_claim_flags_uncovered_unwaived_bullets() {
        // bullet 0 covered; bullet 1 uncovered+unwaived (over-claim); bullet 2 waived (ok).
        let cov = AcCoverageResult {
            pr_number: 1,
            gap_id: Some("INFRA-1".into()),
            status: CoverageStatus::Pass,
            bullets: vec![
                bullet(0, true, false),
                bullet(1, false, false),
                bullet(2, false, true),
            ],
        };
        assert_eq!(is_over_claim(&cov), Some(vec![1]));
    }

    #[test]
    fn is_over_claim_none_when_all_covered_or_waived() {
        let cov = AcCoverageResult {
            pr_number: 2,
            gap_id: Some("INFRA-2".into()),
            status: CoverageStatus::Pass,
            bullets: vec![bullet(0, true, false), bullet(1, false, true)],
        };
        assert!(is_over_claim(&cov).is_none());
    }

    #[test]
    fn is_over_claim_none_when_no_bullets() {
        let cov = AcCoverageResult {
            pr_number: 3,
            gap_id: None,
            status: CoverageStatus::Pass,
            bullets: vec![],
        };
        assert!(is_over_claim(&cov).is_none());
    }

    fn done_gap(id: &str, closed_at: i64) -> chump_gap_store::GapRow {
        chump_gap_store::GapRow {
            id: id.to_string(),
            domain: "CREDIBLE".to_string(),
            title: format!("gap {id}"),
            description: String::new(),
            priority: "P2".to_string(),
            effort: "s".to_string(),
            status: "done".to_string(),
            acceptance_criteria: "1. did the thing".to_string(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: closed_at,
            closed_at: Some(closed_at),
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: Some(1),
            skills_required: String::new(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    // CREDIBLE-1203 AC1/AC3: select_window starts strictly after the cursor,
    // so two consecutive windows (with the cursor advanced between them)
    // examine disjoint sets of gaps.
    #[test]
    fn select_window_two_runs_are_disjoint() {
        let done: Vec<_> = (0..20).map(|i| done_gap(&format!("G-{i}"), i)).collect();

        let cursor = AuditCursor::default();
        let first: Vec<&chump_gap_store::GapRow> =
            select_window(&done, &cursor).into_iter().take(5).collect();
        assert_eq!(first.len(), 5);

        let cursor2 = AuditCursor {
            last_closed_at: first.last().unwrap().closed_at,
            last_id: first.last().unwrap().id.clone(),
        };
        let second: Vec<&chump_gap_store::GapRow> =
            select_window(&done, &cursor2).into_iter().take(5).collect();
        assert_eq!(second.len(), 5);

        let first_ids: std::collections::HashSet<&str> =
            first.iter().map(|g| g.id.as_str()).collect();
        let second_ids: std::collections::HashSet<&str> =
            second.iter().map(|g| g.id.as_str()).collect();
        assert!(
            first_ids.is_disjoint(&second_ids),
            "expected disjoint windows, got {first_ids:?} and {second_ids:?}"
        );
        // and forward progress: second window picks up right where first left off.
        assert_eq!(second[0].id, "G-5");
    }

    // CREDIBLE-1203 AC2: cursor round-trips through save/load.
    #[test]
    fn cursor_round_trips_through_disk() {
        let dir = tempfile::tempdir().unwrap();
        let cursor = AuditCursor {
            last_closed_at: Some(42),
            last_id: "CREDIBLE-1203".to_string(),
        };
        save_cursor(dir.path(), &cursor);
        let loaded = load_cursor(dir.path());
        assert_eq!(loaded, cursor);
    }

    #[test]
    fn load_cursor_defaults_when_absent() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load_cursor(dir.path()), AuditCursor::default());
    }

    // CREDIBLE-1203 AC4: repeatedly advancing the cursor by a bounded window
    // and wrapping at the tail examines >94% of a populated set within a
    // handful of runs (proving forward progress rather than churn on the head).
    #[test]
    fn repeated_windows_cover_over_94_percent_of_gaps() {
        let total = 47;
        let done: Vec<_> = (0..total).map(|i| done_gap(&format!("G-{i}"), i)).collect();
        let limit = 10;

        let mut cursor = AuditCursor::default();
        let mut examined: std::collections::HashSet<String> = std::collections::HashSet::new();
        for _ in 0..6 {
            let window: Vec<&chump_gap_store::GapRow> = select_window(&done, &cursor)
                .into_iter()
                .take(limit)
                .collect();
            for g in &window {
                examined.insert(g.id.clone());
            }
            if let Some(last) = window.last() {
                cursor = AuditCursor {
                    last_closed_at: last.closed_at,
                    last_id: last.id.clone(),
                };
            }
        }

        let coverage_pct = examined.len() as f64 / total as f64 * 100.0;
        assert!(
            coverage_pct > 94.0,
            "expected >94% coverage after 6 runs, got {coverage_pct:.1}% ({}/{})",
            examined.len(),
            total
        );
    }
}
