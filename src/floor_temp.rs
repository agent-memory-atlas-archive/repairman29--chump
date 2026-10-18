//! INFRA-1992 (THE FLOOR Phase 1): floor-temperature signal.
//!
//! Reads `.chump-locks/ambient.jsonl` over a trailing 24-hour window and
//! counts three event kinds that indicate "the floor is unstable":
//!
//!   1. `hook_silent_passthrough` — a git hook exited 0 without doing its
//!      main work (INFRA-1988 emits this). Hot signal: silent regressions.
//!   2. `ci_failure_cluster` — N≥3 PRs blocked on the IDENTICAL failing-check
//!      set (INFRA-1987 emits this). Hot signal: trunk/shared-layer bugs.
//!   3. `admin_merge_executed` — operator (or recovery queue) bypassed
//!      gates to merge. Hot signal: floor needed manual intervention.
//!
//! Scoring:
//!   - COLD: 0 of the above in trailing 24h → ship aggressively
//!   - WARM: 1-2 → prefer non-env-mutating work, double-verify
//!   - HOT:  3+ → only xs/docs gaps, no new shell glue
//!
//! Output:
//!   - `chump health --temp`        → one-word: `COLD` | `WARM` | `HOT`
//!   - `chump health --temp --json` → full JSON with component counts
//!
//! Side effect: emits `kind=floor_temp` ambient event on each invocation
//! so we can observe the signal itself over time.
//!
//! Phase 1 (this module): signal + CLI surface ONLY. Worker integration
//! (workers read the signal and adapt their behavior) ships in a Phase 2
//! follow-up gap.

use crate::ambient_emit::{emit, EmitArgs};
use serde::Serialize;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Default trailing window for floor-temp scoring.
pub const DEFAULT_WINDOW_SECS: u64 = 24 * 60 * 60; // 24h

/// Default WARM threshold (>=1 hot event in window).
pub const WARM_THRESHOLD: usize = 1;

/// Default HOT threshold (>=3 hot events in window).
pub const HOT_THRESHOLD: usize = 3;

/// The three event kinds that count toward floor temperature.
pub const HOT_EVENT_KINDS: &[&str] = &[
    "hook_silent_passthrough",
    "ci_failure_cluster",
    "admin_merge_executed",
];

/// Floor temperature classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum FloorTemp {
    Cold,
    Warm,
    Hot,
}

impl FloorTemp {
    pub fn as_str(&self) -> &'static str {
        match self {
            FloorTemp::Cold => "COLD",
            FloorTemp::Warm => "WARM",
            FloorTemp::Hot => "HOT",
        }
    }

    /// Operator-facing one-line behavior recommendation.
    pub fn recommendation(&self) -> &'static str {
        match self {
            FloorTemp::Cold => "ship aggressively — floor is stable",
            FloorTemp::Warm => "prefer non-env-mutating work; double-verify before commit",
            FloorTemp::Hot => "only xs/docs gaps; no new shell glue; focus on triage",
        }
    }
}

/// Per-event-kind count within the window.
#[derive(Debug, Clone, Serialize)]
pub struct ComponentCount {
    pub kind: String,
    pub count: usize,
}

/// Full report for `--json` output.
#[derive(Debug, Clone, Serialize)]
pub struct FloorTempReport {
    pub temp: FloorTemp,
    pub temp_str: String,
    pub window_secs: u64,
    pub total_hot_events: usize,
    pub components: Vec<ComponentCount>,
    pub recommendation: String,
    /// CREDIBLE-1525: the `admin_merges_7d` counter surfaced by
    /// `chump kpi report` — the *same* number, computed by the same calculator
    /// (`chump_kpi_report::admin_merges`). `None` when not populated (the pure
    /// `compute()` path leaves it unset; the CLI arm fills it in).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub admin_merges_7d: Option<u64>,
}

/// Compute floor temperature by reading the ambient log.
///
/// Returns `FloorTempReport`. Pure function — no side effects beyond the
/// file read. Caller emits the `floor_temp` ambient event separately.
pub fn compute(ambient_path: &Path, window_secs: u64) -> FloorTempReport {
    let cutoff = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs().saturating_sub(window_secs))
        .unwrap_or(0);

    let mut counts: std::collections::HashMap<String, usize> =
        HOT_EVENT_KINDS.iter().map(|k| (k.to_string(), 0)).collect();

    if let Ok(file) = File::open(ambient_path) {
        let reader = BufReader::new(file);
        for line in reader.lines().map_while(Result::ok) {
            // Parse minimally — we only need ts + kind. Avoid pulling
            // in full serde_json overhead for cold-path counting.
            if line.is_empty() {
                continue;
            }
            // Quick check: is this one of our kinds?
            let mut matched_kind: Option<&str> = None;
            for &k in HOT_EVENT_KINDS {
                let needle = format!("\"kind\":\"{}\"", k);
                if line.contains(&needle) {
                    matched_kind = Some(k);
                    break;
                }
            }
            let Some(kind) = matched_kind else {
                continue;
            };

            // Check timestamp window. Find "ts":"<rfc3339>".
            let ts_secs = extract_ts_secs(&line);
            if let Some(t) = ts_secs {
                if t < cutoff {
                    continue;
                }
            }
            // If we couldn't parse the ts, count it (fail-open — better to
            // over-report HOT than to silently under-report).

            *counts.entry(kind.to_string()).or_insert(0) += 1;
        }
    }

    let total: usize = counts.values().sum();
    let temp = if total >= HOT_THRESHOLD {
        FloorTemp::Hot
    } else if total >= WARM_THRESHOLD {
        FloorTemp::Warm
    } else {
        FloorTemp::Cold
    };

    let mut components: Vec<ComponentCount> = counts
        .into_iter()
        .map(|(k, c)| ComponentCount { kind: k, count: c })
        .collect();
    components.sort_by(|a, b| a.kind.cmp(&b.kind));

    FloorTempReport {
        temp,
        temp_str: temp.as_str().to_string(),
        window_secs,
        total_hot_events: total,
        components,
        recommendation: temp.recommendation().to_string(),
        admin_merges_7d: None,
    }
}

/// Extract the ts field as unix seconds. Returns None on parse failure.
/// Looks for `"ts":"YYYY-MM-DDTHH:MM:SSZ"` substring.
fn extract_ts_secs(line: &str) -> Option<u64> {
    let key = "\"ts\":\"";
    let start = line.find(key)? + key.len();
    let end = line[start..].find('"')? + start;
    let s = &line[start..end];
    parse_rfc3339_to_secs(s)
}

/// Parse RFC3339 Z-suffixed timestamp to unix seconds.
/// Accepts: 2026-05-25T16:30:45Z
fn parse_rfc3339_to_secs(s: &str) -> Option<u64> {
    if s.len() < 20 || !s.ends_with('Z') {
        return None;
    }
    let year: i32 = s[0..4].parse().ok()?;
    let mon: u32 = s[5..7].parse().ok()?;
    let day: u32 = s[8..10].parse().ok()?;
    let hr: u32 = s[11..13].parse().ok()?;
    let mn: u32 = s[14..16].parse().ok()?;
    let sc: u32 = s[17..19].parse().ok()?;

    // Days from civil (Howard Hinnant). Source-of-truth UTC seconds.
    let y = year - if mon <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u32;
    let doy = (153 * (if mon > 2 { mon - 3 } else { mon + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era as i64 * 146097 + doe as i64 - 719468;
    let secs = days * 86400 + hr as i64 * 3600 + mn as i64 * 60 + sc as i64;
    if secs < 0 {
        None
    } else {
        Some(secs as u64)
    }
}

/// Emit kind=floor_temp ambient event with the report fields.
/// Call after `compute()` if you want to record the signal.
pub fn emit_floor_temp(report: &FloorTempReport) {
    let _ = emit(&EmitArgs {
        kind: "floor_temp".to_string(),
        source: Some("floor_temp".to_string()),
        fields: vec![
            ("temp".to_string(), report.temp_str.clone()),
            (
                "total_hot_events".to_string(),
                report.total_hot_events.to_string(),
            ),
            ("window_secs".to_string(), report.window_secs.to_string()),
            (
                "hook_silent_passthrough".to_string(),
                report
                    .components
                    .iter()
                    .find(|c| c.kind == "hook_silent_passthrough")
                    .map(|c| c.count.to_string())
                    .unwrap_or_else(|| "0".to_string()),
            ),
            (
                "ci_failure_cluster".to_string(),
                report
                    .components
                    .iter()
                    .find(|c| c.kind == "ci_failure_cluster")
                    .map(|c| c.count.to_string())
                    .unwrap_or_else(|| "0".to_string()),
            ),
            (
                "admin_merge_executed".to_string(),
                report
                    .components
                    .iter()
                    .find(|c| c.kind == "admin_merge_executed")
                    .map(|c| c.count.to_string())
                    .unwrap_or_else(|| "0".to_string()),
            ),
        ],
        ..Default::default()
    });
}

/// Helper: locate the ambient log given the repo root.
pub fn ambient_path_for(repo_root: &Path) -> std::path::PathBuf {
    // Prefer CHUMP_AMBIENT_LOG override (tests + alternative repos).
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        if !p.is_empty() {
            return std::path::PathBuf::from(p);
        }
    }
    repo_root.join(".chump-locks").join("ambient.jsonl")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    fn make_ambient(lines: &[(&str, &str)]) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempdir().unwrap();
        let p = dir.path().join("ambient.jsonl");
        let mut f = File::create(&p).unwrap();
        for (ts, kind) in lines {
            writeln!(f, r#"{{"ts":"{}","kind":"{}","source":"test"}}"#, ts, kind).unwrap();
        }
        (dir, p)
    }

    /// Pick a recent timestamp so the events fall inside the 24h window.
    fn recent_ts() -> String {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // Round to nearest hour for stability — but use NOW so we're in-window.
        let _ = now;
        // Compose a 1-min-ago timestamp deterministically by using chrono-ish format.
        // Simpler: just use the year 2099 (always in-window relative to 24h).
        // Actually we need IN window, not out. Use today's date.
        // chrono crate may not be available — synthesize via the same algorithm.
        // Easiest: use a hard-coded recent date that we know is in window when
        // tests run. Tests are time-sensitive; use a synthetic NOW marker.
        // For determinism, parse our own format back to seconds.
        // We'll use a timestamp 1 hour in the future to always be in-window
        // relative to compute()'s SystemTime::now() at test runtime.
        // 1 hour future: still ≥ now - 24h, so counts.
        let future = now + 3600;
        // Convert back to RFC3339 by re-deriving year/mo/day from days-since-epoch.
        secs_to_rfc3339(future)
    }

    fn old_ts() -> String {
        // 2 days ago — outside the 24h window.
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let two_days_ago = now.saturating_sub(48 * 3600);
        secs_to_rfc3339(two_days_ago)
    }

    fn secs_to_rfc3339(s: u64) -> String {
        let days = (s / 86400) as i64;
        let secs_of_day = (s % 86400) as u32;
        let hr = secs_of_day / 3600;
        let mn = (secs_of_day % 3600) / 60;
        let sc = secs_of_day % 60;
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

    #[test]
    fn cold_when_no_events() {
        let (_dir, p) = make_ambient(&[]);
        let r = compute(&p, DEFAULT_WINDOW_SECS);
        assert_eq!(r.temp, FloorTemp::Cold);
        assert_eq!(r.total_hot_events, 0);
    }

    #[test]
    fn cold_when_no_hot_event_kinds() {
        let ts = recent_ts();
        let (_dir, p) = make_ambient(&[
            (&ts, "fleet_health"),
            (&ts, "pr_stuck"),
            (&ts, "session_end"),
        ]);
        let r = compute(&p, DEFAULT_WINDOW_SECS);
        assert_eq!(r.temp, FloorTemp::Cold);
        assert_eq!(r.total_hot_events, 0);
    }

    #[test]
    fn warm_when_one_hot_event() {
        let ts = recent_ts();
        let (_dir, p) = make_ambient(&[(&ts, "ci_failure_cluster")]);
        let r = compute(&p, DEFAULT_WINDOW_SECS);
        assert_eq!(r.temp, FloorTemp::Warm);
        assert_eq!(r.total_hot_events, 1);
    }

    #[test]
    fn warm_when_two_hot_events() {
        let ts = recent_ts();
        let (_dir, p) = make_ambient(&[
            (&ts, "ci_failure_cluster"),
            (&ts, "hook_silent_passthrough"),
        ]);
        let r = compute(&p, DEFAULT_WINDOW_SECS);
        assert_eq!(r.temp, FloorTemp::Warm);
        assert_eq!(r.total_hot_events, 2);
    }

    #[test]
    fn hot_when_three_or_more_hot_events() {
        let ts = recent_ts();
        let (_dir, p) = make_ambient(&[
            (&ts, "ci_failure_cluster"),
            (&ts, "hook_silent_passthrough"),
            (&ts, "admin_merge_executed"),
        ]);
        let r = compute(&p, DEFAULT_WINDOW_SECS);
        assert_eq!(r.temp, FloorTemp::Hot);
        assert_eq!(r.total_hot_events, 3);
    }

    #[test]
    fn out_of_window_events_dont_count() {
        let old = old_ts();
        let (_dir, p) = make_ambient(&[
            (&old, "ci_failure_cluster"),
            (&old, "ci_failure_cluster"),
            (&old, "admin_merge_executed"),
        ]);
        let r = compute(&p, DEFAULT_WINDOW_SECS);
        assert_eq!(r.temp, FloorTemp::Cold);
        assert_eq!(r.total_hot_events, 0);
    }

    #[test]
    fn recommendation_strings_present() {
        assert!(FloorTemp::Cold.recommendation().contains("ship"));
        assert!(FloorTemp::Warm.recommendation().contains("verify"));
        assert!(FloorTemp::Hot.recommendation().contains("triage"));
    }
}
