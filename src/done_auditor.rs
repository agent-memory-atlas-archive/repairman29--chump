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
use std::io::Write;
use std::path::Path;

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
    /// CREDIBLE-1094: gap IDs considered this run, in closed_at-ascending
    /// order — the audit-log sequence used to verify disjoint runs.
    pub processed_ids: Vec<String>,
    /// Total DONE gaps in the store at sweep time (denominator for coverage %).
    pub total_done: usize,
}

impl DoneAuditReport {
    /// True when at least one done gap over-claims — the CI/daemon exit signal.
    pub fn failing(&self) -> bool {
        !self.flagged.is_empty()
    }

    /// Percentage of all DONE gaps considered by this run.
    pub fn coverage_pct(&self) -> f64 {
        if self.total_done == 0 {
            0.0
        } else {
            (self.processed_ids.len() as f64 / self.total_done as f64) * 100.0
        }
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
        out.push_str(&format!(
            "coverage: {}/{} done gaps processed this run ({:.1}%)\n",
            self.processed_ids.len(),
            self.total_done,
            self.coverage_pct()
        ));
        out.push_str(&format!(
            "processed gap ids (closed_at ascending): {}\n",
            self.processed_ids.join(", ")
        ));
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

/// Path to the persisted cursor tracking the last `(closed_at, id)` processed
/// by `audit`. CREDIBLE-1094: lets consecutive runs process disjoint gap sets
/// instead of re-sweeping the same oldest-N gaps every time. The id is part
/// of the cursor (not just closed_at) because gaps shipped within the same
/// second tie on closed_at — `list_by_status_ordered` breaks that tie with
/// `id ASC`, so the cursor must break it the same way or a same-second gap
/// gets skipped forever (or re-processed) depending on rounding.
fn cursor_path(repo_root: &Path) -> std::path::PathBuf {
    repo_root
        .join(".chump-locks")
        .join("done_auditor_cursor.json")
}

/// Reads the persisted cursor `(closed_at, id)`, defaulting to `(0, "")`
/// (process everything) when absent or unreadable.
fn read_cursor(repo_root: &Path) -> (i64, String) {
    std::fs::read_to_string(cursor_path(repo_root))
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .map(|v| {
            let closed_at = v
                .get("last_closed_at")
                .and_then(|x| x.as_i64())
                .unwrap_or(0);
            let id = v
                .get("last_id")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            (closed_at, id)
        })
        .unwrap_or((0, String::new()))
}

/// Persists the cursor. Best-effort — a write failure just means the next
/// run re-sweeps from the old cursor rather than losing correctness.
fn write_cursor(repo_root: &Path, last_closed_at: i64, last_id: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let body = serde_json::json!({"last_closed_at": last_closed_at, "last_id": last_id});
    let _ = std::fs::write(cursor_path(repo_root), body.to_string());
}

/// Sweep up to `limit` DONE gaps (bounded because each check fetches its PR via
/// `pr_ac_coverage::run`, a `gh` call) and flag over-claims. Emits an
/// `over_claim_suspected` ambient event per flag. A fetch/coverage error skips
/// that gap rather than failing the whole sweep.
///
/// CREDIBLE-339: gaps returned oldest-closed-first so each limited run
/// makes forward progress without re-auditing the same set.
///
/// CREDIBLE-1094: a persisted `(closed_at, id)` cursor
/// (`.chump-locks/done_auditor_cursor.json`) is consulted before the sweep
/// and advanced after it, so two consecutive runs process disjoint gap sets
/// instead of both starting from the oldest done gap.
pub fn audit(repo_root: &Path, limit: usize) -> Result<DoneAuditReport> {
    let store = chump_gap_store::GapStore::open(repo_root)?;
    let done = store.list_by_status_ordered("done")?;
    let mut report = DoneAuditReport::default();
    report.total_done = done.len();
    let cursor = read_cursor(repo_root);
    let mut last_seen = cursor.clone();
    for g in done
        .iter()
        .filter(|g| (g.closed_at.unwrap_or(0), g.id.as_str()) > (cursor.0, cursor.1.as_str()))
        .take(limit)
    {
        report.processed_ids.push(g.id.clone());
        last_seen = (g.closed_at.unwrap_or(last_seen.0), g.id.clone());
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
    if last_seen > cursor {
        write_cursor(repo_root, last_seen.0, &last_seen.1);
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

    // CREDIBLE-1094: two consecutive `audit` runs must process disjoint gap
    // sets once a cursor is persisted. Uses gaps with no closed_pr so the
    // sweep never reaches `pr_ac_coverage::run` (no network in unit tests).
    #[test]
    fn cursor_persists_and_second_run_processes_disjoint_ids() {
        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
        }
        let dir = tempfile::TempDir::new().unwrap();
        let store = chump_gap_store::GapStore::open(dir.path()).unwrap();
        let a = store.reserve("INFRA", "gap a", "P2", "s").unwrap();
        let b = store.reserve("INFRA", "gap b", "P2", "s").unwrap();
        let c = store.reserve("INFRA", "gap c", "P2", "s").unwrap();
        store
            .ship(&a, "test-session", None)
            .unwrap_or_else(|_| panic!("ship {a} failed"));
        store
            .ship(&b, "test-session", None)
            .unwrap_or_else(|_| panic!("ship {b} failed"));
        store
            .ship(&c, "test-session", None)
            .unwrap_or_else(|_| panic!("ship {c} failed"));

        let first = audit(dir.path(), 2).unwrap();
        assert_eq!(first.processed_ids.len(), 2);

        let second = audit(dir.path(), 2).unwrap();
        assert_eq!(second.processed_ids.len(), 1);

        let first_set: std::collections::HashSet<_> = first.processed_ids.iter().collect();
        let second_set: std::collections::HashSet<_> = second.processed_ids.iter().collect();
        assert!(
            first_set.is_disjoint(&second_set),
            "consecutive audit runs must not overlap: {:?} vs {:?}",
            first.processed_ids,
            second.processed_ids
        );
    }

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
}
