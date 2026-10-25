//! INFRA-1995 (THE FLOOR Phase 2): single-pane fleet status.
//!
//! `chump fleet pulse [--json]` — one command that returns
//! operator-readable status in one frame.
//!
//! Replaces the 5-surface manual workflow: chump health + chump fleet
//! status + tail ambient.jsonl + gh pr list + launchctl list.
//!
//! Sections:
//!   1. floor_temp        — COLD/WARM/HOT + hot-event counts (INFRA-1992)
//!   2. active_leases     — count + top 5 oldest
//!   3. fleet_hold        — active cluster auto-HOLD status (INFRA-2004)
//!   4. last_wedges       — last 5 kind=wedge_detected events
//!   5. last_admin_merges — last 5 kind=admin_merge_executed
//!   6. last_alerts       — last 5 kind=ALERT
//!   7. last_clusters     — last 5 kind=ci_failure_cluster
//!   8. admin_merge_count — total kind=admin_merge_executed events in the
//!      trailing floor_temp window (CREDIBLE-1114, CREDIBLE-272 slice)
//!
//! Read-only aggregator. Zero state mutation. Completes in <500ms by
//! reading local files; no live `gh` API calls.
//!
//! Phase 2 ships this CLI. HTTP endpoint (/api/fleet/pulse) + PWA panel
//! ship in a follow-up gap; this PR establishes the data shape.

use crate::floor_temp;
use serde::Serialize;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Single lease summary for the active_leases section.
#[derive(Debug, Clone, Serialize)]
pub struct LeaseSummary {
    pub session: String,
    pub gap_id: String,
    pub age_secs: u64,
    pub paths: String,
}

/// One ambient event surface for the "last N" sections.
#[derive(Debug, Clone, Serialize)]
pub struct AmbientEvent {
    pub ts: String,
    pub kind: String,
    pub summary: String,
}

/// fleet_hold section. Mirrors INFRA-2004's fleet-hold.txt shape.
#[derive(Debug, Clone, Serialize, Default)]
pub struct FleetHold {
    pub active: bool,
    pub cluster_id: Option<String>,
    pub reason: Option<String>,
    pub since: Option<String>,
    pub advisory: Option<String>,
}

/// Composite report.
#[derive(Debug, Clone, Serialize)]
pub struct FleetPulse {
    pub generated_at: String,
    pub floor_temp: floor_temp::FloorTempReport,
    pub fleet_hold: FleetHold,
    pub active_leases: ActiveLeases,
    pub last_wedges: Vec<AmbientEvent>,
    pub last_admin_merges: Vec<AmbientEvent>,
    pub last_alerts: Vec<AmbientEvent>,
    pub last_clusters: Vec<AmbientEvent>,
    /// Total kind=admin_merge_executed events in the trailing floor_temp
    /// window (`floor_temp.window_secs`). CREDIBLE-1114: distinct from
    /// `last_admin_merges` (which caps at 5 and drops the count once >5
    /// events land in the window).
    pub admin_merge_count: usize,
    /// INFRA-8603: Whether the external_repo gate (`CHUMP_EXTERNAL_REPO_PICK_OK`)
    /// is open (`"open"`) or closed (`"closed"`).
    pub external_repo_gate: String,
    /// INFRA-8603: Aggregated count of skipped external gaps across workers.
    pub skipped_external_gaps: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct ActiveLeases {
    pub count: usize,
    pub oldest: Vec<LeaseSummary>,
}

/// Build the pulse by reading local files. Read-only.
pub fn build(repo_root: &Path) -> FleetPulse {
    let ambient = floor_temp::ambient_path_for(repo_root);
    let floor = floor_temp::compute(&ambient, floor_temp::DEFAULT_WINDOW_SECS);
    let hold = read_fleet_hold(repo_root);
    let leases = scan_leases(repo_root);
    let last_wedges = tail_events(&ambient, "wedge_detected", 5);
    let last_admin_merges = tail_events(&ambient, "admin_merge_executed", 5);
    let last_alerts = tail_events(&ambient, "ALERT", 5);
    let last_clusters = tail_events(&ambient, "ci_failure_cluster", 5);
    let admin_merge_count = floor
        .components
        .iter()
        .find(|c| c.kind == "admin_merge_executed")
        .map(|c| c.count)
        .unwrap_or(0);
    let (external_repo_gate, skipped_external_gaps) =
        scan_external_repo_skipped(repo_root, &ambient);

    FleetPulse {
        generated_at: now_rfc3339(),
        floor_temp: floor,
        fleet_hold: hold,
        active_leases: leases,
        last_wedges,
        last_admin_merges,
        last_alerts,
        last_clusters,
        admin_merge_count,
        external_repo_gate,
        skipped_external_gaps,
    }
}

/// INFRA-8603: Aggregate skipped external gaps count across workers and
/// report external_repo gate status (`"open"` or `"closed"`).
fn scan_external_repo_skipped(repo_root: &Path, ambient: &Path) -> (String, usize) {
    let mut gate_open = std::env::var("CHUMP_EXTERNAL_REPO_PICK_OK")
        .ok()
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false);

    let dir = repo_root.join(".chump-locks").join("external-repo-skipped");
    let mut total_skipped: usize = 0;
    let mut found_worker_files = false;
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            if let Ok(content) = fs::read_to_string(&path) {
                found_worker_files = true;
                if let Some(n) = extract_json_usize(&content, "skipped_external_gaps") {
                    total_skipped += n;
                }
                if extract_json_string(&content, "external_repo_gate").as_deref() == Some("open") {
                    gate_open = true;
                }
            }
        }
    }

    if !found_worker_files {
        if let Ok(file) = fs::File::open(ambient) {
            let reader = BufReader::new(file);
            for line in reader.lines().map_while(Result::ok) {
                if let Some(n) = extract_json_usize(&line, "skipped_external_gaps") {
                    total_skipped += n;
                } else if let Some(n) = extract_json_usize(&line, "external_repo_gate_closed") {
                    total_skipped += n;
                }
            }
        }
    }

    let gate_str = if gate_open {
        "open".to_string()
    } else {
        "closed".to_string()
    };
    (gate_str, total_skipped)
}

fn extract_json_usize(s: &str, key: &str) -> Option<usize> {
    let needle = format!("\"{}\":", key);
    let start = s.find(&needle)? + needle.len();
    let rest = s[start..].trim_start();
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    rest[..end].parse::<usize>().ok()
}

/// Read .chump-locks/fleet-hold.txt (written by INFRA-2004 cluster-detector).
fn read_fleet_hold(repo_root: &Path) -> FleetHold {
    let p = repo_root.join(".chump-locks").join("fleet-hold.txt");
    if !p.exists() {
        return FleetHold::default();
    }
    let Ok(s) = fs::read_to_string(&p) else {
        return FleetHold::default();
    };
    // Minimal field extraction — avoid pulling serde_json in cold path.
    FleetHold {
        active: extract_json_bool(&s, "active").unwrap_or(false),
        cluster_id: extract_json_string(&s, "cluster_id"),
        reason: extract_json_string(&s, "reason"),
        since: extract_json_string(&s, "since"),
        advisory: extract_json_string(&s, "advisory"),
    }
}

/// Scan .chump-locks/claim-*.json files. Returns count + top 5 oldest.
fn scan_leases(repo_root: &Path) -> ActiveLeases {
    let dir = repo_root.join(".chump-locks");
    let mut all: Vec<(SystemTime, LeaseSummary)> = Vec::new();
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if !name.starts_with("claim-") || !name.ends_with(".json") {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            let mtime = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            let Ok(content) = fs::read_to_string(&path) else {
                continue;
            };
            let session = extract_json_string(&content, "session").unwrap_or_default();
            let gap_id = extract_json_string(&content, "gap_id").unwrap_or_default();
            let paths = extract_json_string(&content, "paths")
                .or_else(|| extract_json_string(&content, "branch"))
                .unwrap_or_default();
            let age_secs = SystemTime::now()
                .duration_since(mtime)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            all.push((
                mtime,
                LeaseSummary {
                    session,
                    gap_id,
                    age_secs,
                    paths,
                },
            ));
        }
    }
    let count = all.len();
    all.sort_by_key(|a| a.0); // oldest first
    let oldest: Vec<LeaseSummary> = all.into_iter().take(5).map(|(_, s)| s).collect();
    ActiveLeases { count, oldest }
}

/// Return the last N events of a given kind from ambient.jsonl.
fn tail_events(ambient: &Path, kind_filter: &str, n: usize) -> Vec<AmbientEvent> {
    let Ok(file) = std::fs::File::open(ambient) else {
        return Vec::new();
    };
    let reader = BufReader::new(file);
    let needle = format!("\"kind\":\"{}\"", kind_filter);
    let mut matched: Vec<AmbientEvent> = Vec::new();
    for line in reader.lines().map_while(Result::ok) {
        if !line.contains(&needle) {
            continue;
        }
        let ts = extract_json_string(&line, "ts").unwrap_or_default();
        let kind = extract_json_string(&line, "kind").unwrap_or_default();
        // Short summary: pull "note" or "reason" or first 80 chars of remainder.
        let summary = extract_json_string(&line, "note")
            .or_else(|| extract_json_string(&line, "reason"))
            .or_else(|| extract_json_string(&line, "msg"))
            .unwrap_or_else(|| {
                let line_short = if line.len() > 80 { &line[..80] } else { &line };
                line_short.to_string()
            });
        matched.push(AmbientEvent { ts, kind, summary });
    }
    let take_from = matched.len().saturating_sub(n);
    matched.split_off(take_from)
}

/// Tiny JSON string-field extractor (no serde_json dep for cold path).
/// Finds `"key":` optionally followed by whitespace + `"value"` and returns
/// the value. Doesn't handle escapes.
fn extract_json_string(s: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":", key);
    let start_colon = s.find(&needle)? + needle.len();
    // Skip whitespace after colon
    let after_ws = s[start_colon..]
        .find(|c: char| !c.is_whitespace())
        .map(|i| start_colon + i)?;
    // Must be a quoted string for this helper
    if !s[after_ws..].starts_with('"') {
        return None;
    }
    let val_start = after_ws + 1;
    let val_end = s[val_start..].find('"')? + val_start;
    Some(s[val_start..val_end].to_string())
}

fn extract_json_bool(s: &str, key: &str) -> Option<bool> {
    let needle = format!("\"{}\":", key);
    let start = s.find(&needle)? + needle.len();
    let rest = s[start..].trim_start();
    if rest.starts_with("true") {
        Some(true)
    } else if rest.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

fn now_rfc3339() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Reuse the same algorithm as floor_temp tests
    let days = (secs / 86400) as i64;
    let sod = (secs % 86400) as u32;
    let hr = sod / 3600;
    let mn = (sod % 3600) / 60;
    let sc = sod % 60;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i32 + era as i32 * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let yr = y + if m <= 2 { 1 } else { 0 };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", yr, m, d, hr, mn, sc)
}

/// Render the pulse as operator-readable text.
pub fn render_text(p: &FleetPulse) -> String {
    let mut out = String::new();
    out.push_str(&format!("=== Fleet pulse — {} ===\n\n", p.generated_at));
    out.push_str(&format!(
        "Floor temperature: {} ({} hot events in trailing {}h)\n  → {}\n\n",
        p.floor_temp.temp_str,
        p.floor_temp.total_hot_events,
        p.floor_temp.window_secs / 3600,
        p.floor_temp.recommendation
    ));
    if p.fleet_hold.active {
        out.push_str(&format!(
            "Fleet HOLD: ACTIVE (cluster {}, since {})\n  → {}\n\n",
            p.fleet_hold.cluster_id.as_deref().unwrap_or("?"),
            p.fleet_hold.since.as_deref().unwrap_or("?"),
            p.fleet_hold.advisory.as_deref().unwrap_or("(no advisory)")
        ));
    } else {
        out.push_str("Fleet HOLD: not active\n\n");
    }
    out.push_str(&format!("Active leases: {}\n", p.active_leases.count));
    for l in &p.active_leases.oldest {
        out.push_str(&format!(
            "  - {} ({}s old, gap={}, paths={})\n",
            l.session, l.age_secs, l.gap_id, l.paths
        ));
    }
    out.push('\n');
    if p.external_repo_gate == "open" {
        out.push_str(&format!(
            "external_repo gate: open (skipped across workers: {})\n\n",
            p.skipped_external_gaps
        ));
    } else {
        out.push_str(&format!(
            "external_repo gate: closed ({} gaps blocked, {} external gaps skipped: gate closed)\n\n",
            p.skipped_external_gaps, p.skipped_external_gaps
        ));
    }
    out.push_str(&format!("Last {} wedge detections:\n", p.last_wedges.len()));
    for e in &p.last_wedges {
        out.push_str(&format!("  [{}] {}: {}\n", e.ts, e.kind, e.summary));
    }
    out.push('\n');
    out.push_str(&format!(
        "Admin-merge count (last {}h): {}\n",
        p.floor_temp.window_secs / 3600,
        p.admin_merge_count
    ));
    out.push_str(&format!(
        "Last {} admin-merges:\n",
        p.last_admin_merges.len()
    ));
    for e in &p.last_admin_merges {
        out.push_str(&format!("  [{}] {}\n", e.ts, e.summary));
    }
    out.push('\n');
    out.push_str(&format!("Last {} alerts:\n", p.last_alerts.len()));
    for e in &p.last_alerts {
        out.push_str(&format!("  [{}] {}\n", e.ts, e.summary));
    }
    out.push('\n');
    out.push_str(&format!(
        "Last {} CI failure clusters:\n",
        p.last_clusters.len()
    ));
    for e in &p.last_clusters {
        out.push_str(&format!("  [{}] {}\n", e.ts, e.summary));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    fn make_ambient(dir: &Path, lines: &[(&str, &str, &str)]) {
        let p = dir.join("ambient.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        for (ts, kind, extra) in lines {
            writeln!(
                f,
                r#"{{"ts":"{}","kind":"{}","source":"test","note":"{}"}}"#,
                ts, kind, extra
            )
            .unwrap();
        }
    }

    #[test]
    #[serial_test::serial(ambient_env)]
    fn empty_pulse_has_all_sections() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", locks.join("ambient.jsonl"));
        let p = build(dir.path());
        assert_eq!(p.active_leases.count, 0);
        assert_eq!(p.last_wedges.len(), 0);
        assert_eq!(p.last_admin_merges.len(), 0);
        assert!(!p.fleet_hold.active);
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    #[serial_test::serial(ambient_env)]
    fn fleet_hold_active_when_file_present() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        std::fs::write(
            locks.join("fleet-hold.txt"),
            r#"{"active": true, "cluster_id": "abc123", "since": "2026-05-25T17:00:00Z", "reason": "ci_failure_cluster", "advisory": "pivot"}"#,
        )
        .unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", locks.join("ambient.jsonl"));
        let p = build(dir.path());
        assert!(p.fleet_hold.active);
        assert_eq!(p.fleet_hold.cluster_id.as_deref(), Some("abc123"));
        assert_eq!(p.fleet_hold.reason.as_deref(), Some("ci_failure_cluster"));
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    fn tail_events_returns_last_n_in_order() {
        let dir = tempdir().unwrap();
        std::fs::create_dir_all(dir.path()).unwrap();
        make_ambient(
            dir.path(),
            &[
                ("2026-05-25T17:00:00Z", "wedge_detected", "first"),
                ("2026-05-25T17:01:00Z", "wedge_detected", "second"),
                ("2026-05-25T17:02:00Z", "fleet_health", "noise"),
                ("2026-05-25T17:03:00Z", "wedge_detected", "third"),
            ],
        );
        let ambient = dir.path().join("ambient.jsonl");
        let events = tail_events(&ambient, "wedge_detected", 5);
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].summary, "first");
        assert_eq!(events[2].summary, "third");
    }

    #[test]
    fn extract_json_string_handles_basic_kv() {
        let s = r#"{"foo":"bar","baz":"qux"}"#;
        assert_eq!(extract_json_string(s, "foo"), Some("bar".to_string()));
        assert_eq!(extract_json_string(s, "baz"), Some("qux".to_string()));
        assert_eq!(extract_json_string(s, "missing"), None);
    }

    #[test]
    fn extract_json_bool_handles_true_false() {
        assert_eq!(
            extract_json_bool(r#"{"active": true}"#, "active"),
            Some(true)
        );
        assert_eq!(
            extract_json_bool(r#"{"active": false}"#, "active"),
            Some(false)
        );
        assert_eq!(extract_json_bool(r#"{"foo": "bar"}"#, "active"), None);
    }

    #[test]
    #[serial_test::serial(ambient_env)]
    fn admin_merge_count_matches_events_in_window() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // 7 admin-merges within the trailing 24h window + 1 unrelated event.
        // last_admin_merges caps at 5, so 7 proves the aggregate count
        // doesn't silently truncate the way the "last N" list does.
        // floor_temp::compute() filters by a real wall-clock cutoff, so
        // these must be recent timestamps, not fixed historical ones.
        let now = now_rfc3339();
        make_ambient(
            &locks,
            &[
                (now.as_str(), "admin_merge_executed", "one"),
                (now.as_str(), "admin_merge_executed", "two"),
                (now.as_str(), "wedge_detected", "noise"),
                (now.as_str(), "admin_merge_executed", "three"),
                (now.as_str(), "admin_merge_executed", "four"),
                (now.as_str(), "admin_merge_executed", "five"),
                (now.as_str(), "admin_merge_executed", "six"),
                (now.as_str(), "admin_merge_executed", "seven"),
            ],
        );
        std::env::set_var("CHUMP_AMBIENT_LOG", locks.join("ambient.jsonl"));
        let p = build(dir.path());
        assert_eq!(p.admin_merge_count, 7);
        // last_admin_merges is capped at 5 — the aggregate count must not be.
        assert_eq!(p.last_admin_merges.len(), 5);
        let text = render_text(&p);
        assert!(text.contains("Admin-merge count (last 24h): 7"));
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    #[serial_test::serial(ambient_env)]
    fn render_text_includes_all_sections() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", locks.join("ambient.jsonl"));
        let p = build(dir.path());
        let text = render_text(&p);
        assert!(text.contains("Fleet pulse"));
        assert!(text.contains("Floor temperature"));
        assert!(text.contains("Fleet HOLD"));
        assert!(text.contains("Active leases"));
        assert!(text.contains("external_repo gate:"));
        assert!(text.contains("admin-merges"));
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    #[serial_test::serial(ambient_env)]
    fn aggregates_skipped_external_gaps_across_workers() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        let skipped_dir = locks.join("external-repo-skipped");
        std::fs::create_dir_all(&skipped_dir).unwrap();
        std::fs::write(
            skipped_dir.join("w1.json"),
            r#"{"worker_id":"1","external_repo_gate":"closed","skipped_external_gaps":3}"#,
        )
        .unwrap();
        std::fs::write(
            skipped_dir.join("w2.json"),
            r#"{"worker_id":"2","external_repo_gate":"closed","skipped_external_gaps":4}"#,
        )
        .unwrap();
        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
        std::env::set_var("CHUMP_AMBIENT_LOG", locks.join("ambient.jsonl"));
        let p = build(dir.path());
        assert_eq!(p.external_repo_gate, "closed");
        assert_eq!(p.skipped_external_gaps, 7);
        let text = render_text(&p);
        assert!(text.contains("external_repo gate: closed (7 gaps blocked"));
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }
}
