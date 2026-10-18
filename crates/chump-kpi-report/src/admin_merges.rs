//! CREDIBLE-1525 (PHASE-R R3 slice of umbrella CREDIBLE-1492): `admin_merges_7d`.
//!
//! An **admin merge** is a merged PR whose merge was *not* via auto-merge AND
//! whose branch-protection-required `verified` check was *not* `success` at
//! merge time. It is the credibility-costly path — a human (or recovery queue)
//! clicked past a red/incomplete gate rather than letting the merge train carry
//! a green PR through. Counting it over a trailing 7-day window is the honest
//! measure of "how often did we bypass our own gates".
//!
//! ## Data source — cache-first, gh-fallback
//!
//! Matches the reader contract every other fleet surface uses
//! (`scripts/coord/lib/github_cache.sh`): read `.chump/github_cache.db`
//! (`pr_state` + `check_runs`) first; fall back to a best-effort `gh` call only
//! when the cache has no merge history (missing DB, no merged rows, or a read
//! error). The cache is fed in real-time by the webhook receiver, so for a live
//! fleet it is always the hot path.
//!
//! ## Emission (AC2)
//!
//! On detection, [`emit_admin_merge_events`] appends one
//! `kind=admin_merge_executed` line per newly-detected PR to
//! `.chump-locks/ambient.jsonl` (deduped by PR number against the events
//! already in the log, so re-running `chump kpi report` is idempotent). That is
//! the same event `floor_temp` already counts toward its HOT score, so
//! `floor_temp` surfaces the same number (AC3).

use crate::kpi_report::{current_unix, json_escape, parse_iso8601_to_unix};
use std::path::Path;

/// Trailing window for the admin-merge counter.
pub const ADMIN_MERGE_WINDOW_DAYS: u64 = 7;

/// Branch-protection-required check whose non-success (combined with a
/// non-auto-merge) defines an admin merge. `enforce_admins=true; required=[verified]`
/// per the umbrella's evidence block.
const VERIFIED_CHECK_NAME: &str = "verified";

/// One detected admin merge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminMerge {
    pub number: u64,
    pub merged_at: String,
}

/// `admin_merges_7d` section for `chump kpi report`.
#[derive(Debug, Clone, Default)]
pub struct AdminMergesSection {
    pub admin_merges_7d: u64,
    /// Where the number came from: `cache` | `gh` | `none`.
    pub source: String,
    /// PR numbers behind the count (used by the emitter for dedup).
    pub merges: Vec<AdminMerge>,
}

impl AdminMergesSection {
    pub fn render_text(&self) -> String {
        format!(
            "═══ Admin Merges (CREDIBLE-1525) ═══\n  admin_merges_7d: {} (source: {})\n",
            self.admin_merges_7d,
            if self.source.is_empty() {
                "none"
            } else {
                &self.source
            },
        )
    }

    pub fn render_json(&self) -> String {
        let src = if self.source.is_empty() {
            "none"
        } else {
            &self.source
        };
        format!(
            r#"{{"admin_merges_7d":{},"source":"{}"}}"#,
            self.admin_merges_7d,
            json_escape(src),
        )
    }
}

/// Build the section: github cache first, gh fallback.
pub fn build_admin_merges_section(repo_root: &Path) -> AdminMergesSection {
    let cutoff = current_unix().saturating_sub(ADMIN_MERGE_WINDOW_DAYS * 86_400);
    let db = repo_root.join(".chump/github_cache.db");
    if db.exists() {
        if let Some(merges) = detect_from_cache(&db, cutoff) {
            return AdminMergesSection {
                admin_merges_7d: merges.len() as u64,
                source: "cache".to_string(),
                merges,
            };
        }
    }
    // Cache absent or carried no merge history → best-effort gh fallback.
    match detect_from_gh(repo_root, cutoff) {
        Some(merges) => AdminMergesSection {
            admin_merges_7d: merges.len() as u64,
            source: "gh".to_string(),
            merges,
        },
        None => AdminMergesSection {
            admin_merges_7d: 0,
            source: "none".to_string(),
            merges: Vec::new(),
        },
    }
}

/// Read admin merges from the github cache DB. Returns `None` when the cache
/// cannot be opened or has *no merge history at all* (so the caller falls back
/// to gh); returns `Some(vec![])` when the cache has merge history but zero
/// admin merges in the window (a real, trusted zero — no fallback).
fn detect_from_cache(db: &Path, cutoff: u64) -> Option<Vec<AdminMerge>> {
    let conn =
        rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;

    // Does the cache carry any merge history? If not, treat as a cache miss.
    let merged_total: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pr_state WHERE merged_at IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .ok()?;
    if merged_total == 0 {
        return None;
    }

    // Admin merge := merged, not auto-merge, and no `verified` check_run whose
    // conclusion is success (case-insensitive — webhook writes lowercase,
    // statusCheckRollup is uppercase). Window-filter merged_at in Rust so the
    // iso8601 parser matches the rest of the crate exactly.
    let mut stmt = conn
        .prepare(
            "SELECT p.number, p.merged_at \
             FROM pr_state p \
             WHERE p.merged_at IS NOT NULL \
               AND p.auto_merge_enabled = 0 \
               AND NOT EXISTS ( \
                   SELECT 1 FROM check_runs c \
                   WHERE c.head_sha = p.head_sha \
                     AND LOWER(c.name) = ?1 \
                     AND LOWER(c.conclusion) = 'success' \
               ) \
             ORDER BY p.number DESC",
        )
        .ok()?;
    let rows = stmt
        .query_map([VERIFIED_CHECK_NAME], |row| {
            let number: i64 = row.get(0)?;
            let merged_at: String = row.get(1)?;
            Ok((number as u64, merged_at))
        })
        .ok()?;

    let mut merges = Vec::new();
    for row in rows {
        let (number, merged_at) = row.ok()?;
        if let Some(ts) = parse_iso8601_to_unix(&merged_at) {
            if ts >= cutoff {
                merges.push(AdminMerge { number, merged_at });
            }
        }
    }
    Some(merges)
}

/// Best-effort gh fallback. Returns `None` on any resolution/auth/network
/// failure (so the section renders `source:none, 0` rather than an error —
/// mirrors the always-degrade-gracefully contract of the bash cache helpers).
fn detect_from_gh(repo_root: &Path, cutoff: u64) -> Option<Vec<AdminMerge>> {
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "merged",
            "--limit",
            "200",
            "--json",
            "number,mergedAt,autoMergeRequest,statusCheckRollup",
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    let arr = json.as_array()?;
    Some(admin_merges_from_gh_json(arr, cutoff))
}

/// Pure classifier over the `gh pr list --json ...` array shape. Split out so a
/// fixture can exercise the gh path without a live `gh`.
pub(crate) fn admin_merges_from_gh_json(prs: &[serde_json::Value], cutoff: u64) -> Vec<AdminMerge> {
    let mut merges = Vec::new();
    for pr in prs {
        let Some(merged_at) = pr.get("mergedAt").and_then(|v| v.as_str()) else {
            continue;
        };
        if merged_at.is_empty() {
            continue;
        }
        match parse_iso8601_to_unix(merged_at) {
            Some(ts) if ts >= cutoff => {}
            _ => continue,
        }
        // Not via auto-merge: autoMergeRequest is null/absent.
        let auto_merge = pr
            .get("autoMergeRequest")
            .map(|v| !v.is_null())
            .unwrap_or(false);
        if auto_merge {
            continue;
        }
        // verified check was not success at merge time.
        let verified_success = pr
            .get("statusCheckRollup")
            .and_then(|v| v.as_array())
            .map(|checks| {
                checks.iter().any(|c| {
                    let name = c
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    let concl = c
                        .get("conclusion")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    name == VERIFIED_CHECK_NAME && concl == "success"
                })
            })
            .unwrap_or(false);
        if verified_success {
            continue;
        }
        if let Some(number) = pr.get("number").and_then(|v| v.as_u64()) {
            merges.push(AdminMerge {
                number,
                merged_at: merged_at.to_string(),
            });
        }
    }
    merges
}

/// Emit one `kind=admin_merge_executed` line per newly-detected admin merge,
/// deduped by PR number against the events already in `ambient.jsonl`. Returns
/// the number of events actually written. Idempotent: re-running over the same
/// detection set writes nothing.
pub fn emit_admin_merge_events(
    repo_root: &Path,
    section: &AdminMergesSection,
) -> std::io::Result<usize> {
    if section.merges.is_empty() {
        return Ok(0);
    }
    use std::io::Write;
    let lock_dir = repo_root.join(".chump-locks");
    std::fs::create_dir_all(&lock_dir)?;
    let path = lock_dir.join("ambient.jsonl");

    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let already: std::collections::HashSet<u64> = existing
        .lines()
        .filter(|l| l.contains(r#""kind":"admin_merge_executed""#))
        .filter_map(|l| crate::kpi_report::extract_int_field(l, "pr"))
        .collect();

    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut written = 0usize;
    for m in &section.merges {
        if already.contains(&m.number) {
            continue;
        }
        // scanner-anchor: "kind":"admin_merge_executed"
        let line = format!(
            r#"{{"ts":"{}","kind":"admin_merge_executed","pr":{},"merged_at":"{}","source":"{}"}}"#,
            ts,
            m.number,
            json_escape(&m.merged_at),
            json_escape(&section.source),
        );
        writeln!(f, "{line}")?;
        written += 1;
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    fn recent_iso() -> String {
        // 1 hour ago — comfortably inside a 7d window at test runtime.
        let now = current_unix().saturating_sub(3_600);
        iso_from_unix(now)
    }

    fn old_iso() -> String {
        // 10 days ago — outside the 7d window.
        let now = current_unix().saturating_sub(10 * 86_400);
        iso_from_unix(now)
    }

    fn iso_from_unix(s: u64) -> String {
        let days = (s / 86_400) as i64;
        let sod = (s % 86_400) as u32;
        let (hr, mn, sc) = (sod / 3600, (sod % 3600) / 60, sod % 60);
        let z = days + 719_468;
        let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
        let doe = (z - era * 146_097) as u64;
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let y = yoe as i64 + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let yr = y + if m <= 2 { 1 } else { 0 };
        format!("{yr:04}-{m:02}-{d:02}T{hr:02}:{mn:02}:{sc:02}Z")
    }

    fn seed_db(path: &Path) -> rusqlite::Connection {
        let conn = rusqlite::Connection::open(path).unwrap();
        conn.execute_batch(
            "CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_sha TEXT, \
             auto_merge_enabled INTEGER NOT NULL DEFAULT 0, merged_at TEXT); \
             CREATE TABLE check_runs (head_sha TEXT, name TEXT, conclusion TEXT, \
             PRIMARY KEY (head_sha, name));",
        )
        .unwrap();
        conn
    }

    fn add_pr(conn: &rusqlite::Connection, n: i64, sha: &str, auto: i64, merged_at: &str) {
        conn.execute(
            "INSERT INTO pr_state (number, head_sha, auto_merge_enabled, merged_at) \
             VALUES (?1, ?2, ?3, ?4)",
            params![n, sha, auto, merged_at],
        )
        .unwrap();
    }

    fn add_check(conn: &rusqlite::Connection, sha: &str, name: &str, concl: &str) {
        conn.execute(
            "INSERT INTO check_runs (head_sha, name, conclusion) VALUES (?1, ?2, ?3)",
            params![sha, name, concl],
        )
        .unwrap();
    }

    #[test]
    fn cache_counts_admin_merge_but_not_green_or_auto() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("gh.db");
        let recent = recent_iso();
        {
            let conn = seed_db(&db);
            // #1: admin merge — manual + verified failed.
            add_pr(&conn, 1, "sha1", 0, &recent);
            add_check(&conn, "sha1", "verified", "failure");
            // #2: clean auto-merge, verified green → not admin.
            add_pr(&conn, 2, "sha2", 1, &recent);
            add_check(&conn, "sha2", "verified", "success");
            // #3: manual merge but verified green → not admin.
            add_pr(&conn, 3, "sha3", 0, &recent);
            add_check(&conn, "sha3", "verified", "success");
            // #4: manual merge, NO verified check at all → admin.
            add_pr(&conn, 4, "sha4", 0, &recent);
            // #5: manual + verified failed but 10 days old → out of window.
            add_pr(&conn, 5, "sha5", 0, &old_iso());
            add_check(&conn, "sha5", "verified", "failure");
        }
        let cutoff = current_unix().saturating_sub(ADMIN_MERGE_WINDOW_DAYS * 86_400);
        let merges = detect_from_cache(&db, cutoff).unwrap();
        let mut nums: Vec<u64> = merges.iter().map(|m| m.number).collect();
        nums.sort_unstable();
        assert_eq!(nums, vec![1, 4]);
    }

    #[test]
    fn case_insensitive_verified_success() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("gh.db");
        let recent = recent_iso();
        {
            let conn = seed_db(&db);
            add_pr(&conn, 1, "sha1", 0, &recent);
            add_check(&conn, "sha1", "verified", "SUCCESS"); // uppercase → still green
        }
        let cutoff = current_unix().saturating_sub(ADMIN_MERGE_WINDOW_DAYS * 86_400);
        assert_eq!(detect_from_cache(&db, cutoff).unwrap().len(), 0);
    }

    #[test]
    fn empty_cache_is_a_miss_not_a_zero() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("gh.db");
        {
            let _conn = seed_db(&db); // schema but no rows
        }
        let cutoff = current_unix().saturating_sub(ADMIN_MERGE_WINDOW_DAYS * 86_400);
        // No merge history → None (caller falls back to gh).
        assert!(detect_from_cache(&db, cutoff).is_none());
    }

    #[test]
    fn gh_json_classifier_matches_definition() {
        let recent = recent_iso();
        let old = old_iso();
        let prs: Vec<serde_json::Value> = vec![
            serde_json::json!({"number":1,"mergedAt":recent,"autoMergeRequest":null,
                "statusCheckRollup":[{"name":"verified","conclusion":"FAILURE"}]}),
            serde_json::json!({"number":2,"mergedAt":recent,
                "autoMergeRequest":{"enabledAt":"x"},
                "statusCheckRollup":[{"name":"verified","conclusion":"FAILURE"}]}),
            serde_json::json!({"number":3,"mergedAt":recent,"autoMergeRequest":null,
                "statusCheckRollup":[{"name":"verified","conclusion":"SUCCESS"}]}),
            serde_json::json!({"number":4,"mergedAt":old,"autoMergeRequest":null,
                "statusCheckRollup":[{"name":"verified","conclusion":"FAILURE"}]}),
        ];
        let cutoff = current_unix().saturating_sub(ADMIN_MERGE_WINDOW_DAYS * 86_400);
        let merges = admin_merges_from_gh_json(&prs, cutoff);
        assert_eq!(merges.len(), 1);
        assert_eq!(merges[0].number, 1);
    }

    #[test]
    fn emit_is_deduped_by_pr_number() {
        let tmp = tempfile::tempdir().unwrap();
        let section = AdminMergesSection {
            admin_merges_7d: 2,
            source: "cache".to_string(),
            merges: vec![
                AdminMerge {
                    number: 11,
                    merged_at: "2026-10-18T00:00:00Z".into(),
                },
                AdminMerge {
                    number: 22,
                    merged_at: "2026-10-18T00:00:00Z".into(),
                },
            ],
        };
        // First emit writes both.
        assert_eq!(emit_admin_merge_events(tmp.path(), &section).unwrap(), 2);
        // Second emit over the same set writes nothing (idempotent).
        assert_eq!(emit_admin_merge_events(tmp.path(), &section).unwrap(), 0);
        let log = std::fs::read_to_string(tmp.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert_eq!(log.matches(r#""kind":"admin_merge_executed""#).count(), 2);
        assert!(log.contains(r#""pr":11"#));
    }

    #[test]
    fn render_json_shape() {
        let section = AdminMergesSection {
            admin_merges_7d: 3,
            source: "cache".to_string(),
            merges: Vec::new(),
        };
        assert_eq!(
            section.render_json(),
            r#"{"admin_merges_7d":3,"source":"cache"}"#
        );
    }
}
