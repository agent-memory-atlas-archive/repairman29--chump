//! Drift detector + healer between `docs/gaps/<ID>.yaml` and `state.db`.
//!
//! Rust port of `scripts/coord/gap-doctor.py` (INFRA-155). Phase 1 of
//! INFRA-2000 / META-107: same buckets, same exit codes, no new event
//! kinds, no operator-visible behavior changes.
//!
//! ## The four drift buckets
//!
//! | Bucket | Condition | Safe to auto-fix? |
//! |--------|-----------|-------------------|
//! | 1 | DB done / YAML open  | yes — regenerate YAML from DB |
//! | 2 | DB open / YAML done  | yes — UPDATE state.db from YAML |
//! | 3 | DB-only IDs (no YAML)| no — emit ALERT, operator review |
//! | 4 | YAML-only IDs (no DB)| no — emit ALERT, operator review |
//!
//! ## Additional detection classes (per INFRA-2000 brief)
//!
//! Phase 1 also surfaces (read-only):
//!
//! - **missing-dep**: `depends_on` entries referencing non-existent gap IDs
//! - **double-encoded depends_on**: depends_on stored as a JSON-string-of-JSON
//! - **ghost gaps**: `status: open` but `closed_pr` is set
//! - **race-fixture pollution**: gap title starts with `race-` (test leak)
//!
//! These match `chump gap audit-priorities`' invariants but live here so the
//! Rust gap-doctor can report them in a single pass.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use anyhow::{Context, Result};
use rusqlite::Connection;

use super::{load_yaml_status_map, yaml_status};

/// Mode controlling how aggressively `doctor` mutates state.
///
/// Phase 1 maps directly to the existing Python tool's three modes
/// (`doctor` / `sync-from-yaml --apply` / `sync-from-db --apply`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealMode {
    /// Report only — no mutations. Mirrors `gap-doctor.py doctor`.
    ScanOnly,
    /// Auto-fix the two safe buckets (DB->YAML and YAML->DB) only.
    /// Bucket 3 + Bucket 4 still ALERT (in the Python tool's safe-sweep);
    /// in this Rust port they're report-only — operators run the Python
    /// safe-sweep when they want ambient ALERTs.
    FixSafe,
    /// Reserved for follow-up sub-gaps. Phase 1 treats this the same as
    /// `FixSafe` and emits a note in the report; no destructive ops.
    FixDestructive,
}

/// One detected drift bucket with the IDs that fell into it.
#[derive(Debug, Clone, Default)]
pub struct BucketReport {
    /// DB row says `done` but the YAML mirror still has `open` (or absent).
    pub db_done_yaml_open: Vec<String>,
    /// YAML mirror says `done` but the DB row still has `open`.
    pub db_open_yaml_done: Vec<String>,
    /// Gap ID present in state.db but no matching `docs/gaps/<ID>.yaml`.
    pub db_only: Vec<String>,
    /// Gap ID present in `docs/gaps/<ID>.yaml` but no matching DB row.
    pub yaml_only: Vec<String>,
}

/// Additional registry-integrity detection classes that audit-priorities
/// also tracks. Phase 1 reports counts + IDs but does not auto-fix.
#[derive(Debug, Clone, Default)]
pub struct IntegrityFindings {
    /// IDs whose `depends_on` references a gap that doesn't exist.
    pub missing_dep_refs: Vec<String>,
    /// IDs whose `depends_on` column is double-encoded (JSON-string-of-JSON).
    pub double_encoded_depends_on: Vec<String>,
    /// IDs with `status: open` but `closed_pr` is non-null (post-merge leak).
    pub open_with_closed_pr: Vec<String>,
    /// IDs whose title starts with `race-` (test-fixture pollution leak).
    pub race_fixture_titles: Vec<String>,
}

/// Result of one [`GapDoctor::heal`] invocation.
#[derive(Debug, Clone, Default)]
pub struct HealReport {
    /// Total number of gaps loaded from each source.
    pub total_yaml: usize,
    /// Total number of gaps loaded from each source.
    pub total_db: usize,
    /// Per-bucket drift findings.
    pub buckets: BucketReport,
    /// Per-class integrity findings (auxiliary detections per INFRA-2000 brief).
    pub integrity: IntegrityFindings,
    /// Number of rows mutated. Zero unless `mode == FixSafe`/`FixDestructive`.
    pub rows_updated: usize,
}

impl HealReport {
    /// Total drift count across all four buckets — used for the CLI exit code.
    /// Matches `gap-doctor.py::cmd_doctor`'s `drift_total` calculation.
    pub fn drift_total(&self) -> usize {
        self.buckets.db_done_yaml_open.len()
            + self.buckets.db_open_yaml_done.len()
            + self.buckets.db_only.len()
            + self.buckets.yaml_only.len()
    }

    /// Render the same `== gap-doctor: drift report ==` block the Python
    /// tool emits to stdout, then the additional integrity findings.
    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str("== gap-doctor: drift report ==\n");
        out.push_str(&format!("  Total gaps in YAML : {}\n", self.total_yaml));
        out.push_str(&format!("  Total gaps in DB   : {}\n", self.total_db));
        out.push('\n');
        out.push_str(&format!(
            "  Bucket 1 — DB done / YAML open   : {:3} (regenerate YAML)\n",
            self.buckets.db_done_yaml_open.len()
        ));
        for gid in &self.buckets.db_done_yaml_open {
            out.push_str(&format!("      {}\n", gid));
        }
        out.push_str(&format!(
            "  Bucket 2 — DB open / YAML done   : {:3} (sync DB from YAML)\n",
            self.buckets.db_open_yaml_done.len()
        ));
        for gid in &self.buckets.db_open_yaml_done {
            out.push_str(&format!("      {}\n", gid));
        }
        out.push_str(&format!(
            "  Bucket 3 — DB-only / YAML missing: {:3} (orphan rows in DB)\n",
            self.buckets.db_only.len()
        ));
        for gid in &self.buckets.db_only {
            out.push_str(&format!("      {}\n", gid));
        }
        out.push_str(&format!(
            "  Bucket 4 — YAML-only / DB missing: {:3} (import skipped)\n",
            self.buckets.yaml_only.len()
        ));
        for gid in self.buckets.yaml_only.iter().take(20) {
            out.push_str(&format!("      {}\n", gid));
        }
        if self.buckets.yaml_only.len() > 20 {
            out.push_str(&format!(
                "      ... {} more\n",
                self.buckets.yaml_only.len() - 20
            ));
        }
        out.push('\n');
        out.push_str(&format!("  Total drift entries: {}\n", self.drift_total()));

        // INFRA-2000: auxiliary integrity findings (audit-priorities parity).
        let aux = &self.integrity;
        let aux_total = aux.missing_dep_refs.len()
            + aux.double_encoded_depends_on.len()
            + aux.open_with_closed_pr.len()
            + aux.race_fixture_titles.len();
        if aux_total > 0 {
            out.push('\n');
            out.push_str("== gap-doctor: integrity findings ==\n");
            out.push_str(&format!(
                "  missing-dep refs      : {:3}\n",
                aux.missing_dep_refs.len()
            ));
            for gid in aux.missing_dep_refs.iter().take(10) {
                out.push_str(&format!("      {}\n", gid));
            }
            out.push_str(&format!(
                "  double-encoded deps   : {:3}\n",
                aux.double_encoded_depends_on.len()
            ));
            for gid in aux.double_encoded_depends_on.iter().take(10) {
                out.push_str(&format!("      {}\n", gid));
            }
            out.push_str(&format!(
                "  open w/ closed_pr     : {:3}\n",
                aux.open_with_closed_pr.len()
            ));
            for gid in aux.open_with_closed_pr.iter().take(10) {
                out.push_str(&format!("      {}\n", gid));
            }
            out.push_str(&format!(
                "  race-fixture titles   : {:3}\n",
                aux.race_fixture_titles.len()
            ));
            for gid in aux.race_fixture_titles.iter().take(10) {
                out.push_str(&format!("      {}\n", gid));
            }
        }

        if self.rows_updated > 0 {
            out.push('\n');
            out.push_str(&format!("  applied: {} rows\n", self.rows_updated));
        }
        out
    }
}

/// Repo-rooted gap-doctor instance. Phase 1 wraps a [`Connection`] +
/// [`Path`] rather than the heavier `GapStore` because we need both
/// the canonical DB and direct filesystem reads of `docs/gaps/*.yaml`.
pub struct GapDoctor {
    repo_root: std::path::PathBuf,
}

impl GapDoctor {
    /// Build a doctor rooted at `repo_root` (typically [`super::resolve_repo_root`]'s output).
    pub fn new(repo_root: impl AsRef<Path>) -> Self {
        Self {
            repo_root: repo_root.as_ref().to_path_buf(),
        }
    }

    /// Path to the canonical state DB.
    pub fn db_path(&self) -> std::path::PathBuf {
        if let Ok(p) = std::env::var("CHUMP_STATE_DB") {
            return std::path::PathBuf::from(p);
        }
        self.repo_root.join(".chump").join("state.db")
    }

    /// Run one detection-and-(optional)-heal pass.
    ///
    /// In [`HealMode::ScanOnly`] this is purely read-only. In
    /// [`HealMode::FixSafe`] and [`HealMode::FixDestructive`], this detects
    /// drift but does NOT mutate the database. Callers that need to reconcile
    /// Bucket 2 (DB open / YAML done) must use the public `ship()` method on
    /// `GapStore` to respect the receipt gate (INFRA-1392). Buckets 3 + 4 are
    /// always read-only — emitting ambient ALERTs for those is the Python
    /// safe-sweep's job and isn't replicated here (Phase 1 has no ambient
    /// writes).
    pub fn heal(&self, mode: HealMode) -> Result<HealReport> {
        let db_path = self.db_path();
        let yaml_view =
            load_yaml_status_map(&self.repo_root).context("failed to read docs/gaps/*.yaml")?;
        let db_view = load_db_status_map(&db_path).context("failed to read state.db")?;

        let mut report = HealReport {
            total_yaml: yaml_view.len(),
            total_db: db_view.len(),
            ..Default::default()
        };

        let mut all_ids: BTreeSet<&str> = BTreeSet::new();
        for k in yaml_view.keys() {
            all_ids.insert(k.as_str());
        }
        for k in db_view.keys() {
            all_ids.insert(k.as_str());
        }

        for gid in &all_ids {
            let gid = *gid;
            let y = yaml_view.get(gid);
            let d = db_view.get(gid);
            match (d, y) {
                (None, Some(_)) => report.buckets.yaml_only.push(gid.to_string()),
                (Some(_), None) => report.buckets.db_only.push(gid.to_string()),
                (Some(drow), Some(yrow)) => {
                    let y_status = yaml_status(yrow);
                    if drow.status == "done" && y_status != "done" {
                        report.buckets.db_done_yaml_open.push(gid.to_string());
                    } else if drow.status == "open" && y_status == "done" {
                        report.buckets.db_open_yaml_done.push(gid.to_string());
                    }
                }
                _ => unreachable!("all_ids is union of yaml_view + db_view"),
            }
        }

        // Auxiliary integrity findings — match audit-priorities classes.
        report.integrity = compute_integrity_findings(&db_path, &all_ids)?;

        // CREDIBLE-1501: Bucket 2 reconciliation (DB open / YAML done) is
        // now read-only. The HealMode flags are retained for API compatibility
        // but do not trigger direct UPDATE statements. Callers that need to
        // flip status=done must use GapStore::ship() which is gated on receipt
        // (INFRA-1392 proof-of-merge).
        if matches!(mode, HealMode::FixSafe | HealMode::FixDestructive) {
            report.rows_updated = 0;
        }

        Ok(report)
    }
}

/// Minimal DB row used by the doctor — status + closed_pr only.
struct DbView {
    status: String,
    #[allow(dead_code)]
    closed_pr: Option<i64>,
}

fn load_db_status_map(db_path: &Path) -> Result<BTreeMap<String, DbView>> {
    let conn = Connection::open(db_path)
        .with_context(|| format!("open state.db: {}", db_path.display()))?;
    let mut stmt = conn.prepare("SELECT id, status, closed_pr FROM gaps")?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            DbView {
                status: row.get(1)?,
                closed_pr: row.get(2)?,
            },
        ))
    })?;
    let mut out = BTreeMap::new();
    for r in rows {
        let (id, v) = r?;
        out.insert(id, v);
    }
    Ok(out)
}

/// Compute the auxiliary integrity findings called out in INFRA-2000:
/// missing-dep refs, double-encoded depends_on, open-with-closed_pr, and
/// race-fixture titles.
fn compute_integrity_findings(
    db_path: &Path,
    known_ids: &BTreeSet<&str>,
) -> Result<IntegrityFindings> {
    let conn = Connection::open(db_path)?;
    let mut stmt = conn.prepare("SELECT id, status, title, depends_on, closed_pr FROM gaps")?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<i64>>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let known: BTreeSet<&str> = known_ids.iter().copied().collect();
    let mut findings = IntegrityFindings::default();
    for (id, status, title, depends_on, closed_pr) in rows {
        // race-* test pollution detection.
        if title.trim_start().to_ascii_lowercase().starts_with("race-") {
            findings.race_fixture_titles.push(id.clone());
        }
        // Ghost gap: status=open with closed_pr set.
        if status == "open" && closed_pr.is_some() {
            findings.open_with_closed_pr.push(id.clone());
        }
        // depends_on inspection.
        let dep_trimmed = depends_on.trim();
        if dep_trimmed.is_empty() || dep_trimmed == "[]" {
            continue;
        }
        // Detect double-encoded depends_on: a JSON string whose payload is
        // itself a JSON array, e.g. "\"[\\\"INFRA-1\\\"]\"".
        if let Ok(s) = serde_json::from_str::<String>(dep_trimmed) {
            if serde_json::from_str::<Vec<String>>(&s).is_ok() {
                findings.double_encoded_depends_on.push(id.clone());
                continue;
            }
        }
        // Parse the dep list; any reference to an unknown ID counts.
        if let Ok(deps) = serde_json::from_str::<Vec<String>>(dep_trimmed) {
            for d in &deps {
                let needle = d.as_str();
                if !needle.is_empty() && !known.contains(needle) {
                    findings.missing_dep_refs.push(id.clone());
                    break;
                }
            }
        }
    }
    findings.missing_dep_refs.sort();
    findings.missing_dep_refs.dedup();
    findings.double_encoded_depends_on.sort();
    findings.double_encoded_depends_on.dedup();
    findings.open_with_closed_pr.sort();
    findings.open_with_closed_pr.dedup();
    findings.race_fixture_titles.sort();
    findings.race_fixture_titles.dedup();
    Ok(findings)
}

/// Parse `YYYY-MM-DD` -> unix epoch (UTC midnight). Returns 0 on failure.
/// Mirrors `gap-doctor.py::parse_iso_to_unix`.
fn parse_iso_to_unix(s: &str) -> i64 {
    use chrono::{NaiveDate, TimeZone, Utc};
    let s = s.trim().trim_matches('\'').trim_matches('"');
    if s.is_empty() {
        return 0;
    }
    match NaiveDate::parse_from_str(s, "%Y-%m-%d") {
        Ok(d) => Utc
            .from_utc_datetime(&d.and_hms_opt(0, 0, 0).expect("valid midnight"))
            .timestamp(),
        Err(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_iso_handles_quoted_dates() {
        assert!(parse_iso_to_unix("2026-05-27") > 0);
        assert!(parse_iso_to_unix("'2026-05-27'") > 0);
        assert!(parse_iso_to_unix("\"2026-05-27\"") > 0);
        assert_eq!(parse_iso_to_unix(""), 0);
        assert_eq!(parse_iso_to_unix("not a date"), 0);
    }

    #[test]
    fn heal_report_render_includes_bucket_headers() {
        let report = HealReport {
            total_yaml: 5,
            total_db: 5,
            ..Default::default()
        };
        let s = report.render();
        assert!(s.contains("== gap-doctor: drift report =="));
        assert!(s.contains("Bucket 1"));
        assert!(s.contains("Bucket 4"));
    }
}
