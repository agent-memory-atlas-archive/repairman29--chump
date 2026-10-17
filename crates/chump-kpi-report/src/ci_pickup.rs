//! CI runner pickup-latency measurement (CREDIBLE-1512).
//!
//! Hosted-runner starvation is invisible to GitHub's status page: `ubuntu-latest`
//! jobs sit with `runner=none` for 20-40 min while the queue backs up, yet every
//! API says "operational". This module turns that into a measured KPI:
//!   - `ci_pickup_latency_s` — per-job `started_at - created_at` (time a job waited
//!     for a runner to pick it up), bucketed by UTC hour with p50/p95.
//!   - `ci_runs_queued` — count of workflow runs currently in `queued` status.
//!
//! The data is collected out-of-band by `scripts/ci/ci-pickup-collect.sh` (gh+jq
//! glue — the github webhook cache's `check_runs` table has `started_at`/
//! `completed_at` but NOT the job `created_at` needed for queue-wait, so the
//! collector falls back to `gh api .../jobs` per the CREDIBLE-1512 AC). The
//! collector appends one JSONL sample per job to
//! `.chump/metrics/ci_pickup.jsonl` and writes the live queued count to
//! `.chump/metrics/ci_runs_queued`. This module (the Rust owner of the logic)
//! reads those cache files, computes the percentiles, decides the
//! starvation verdict, and emits `kind=ci_runner_starved` — keeping the
//! detection logic in Rust (testable) and the network I/O in shell glue
//! (PHASE-R R6 invariant/glue split).

use std::path::Path;

/// One pickup-latency sample: a single CI job's queue wait.
#[derive(Debug, Clone)]
pub struct PickupSample {
    /// Job `created_at` (when it was enqueued), RFC3339.
    pub ts: String,
    /// `started_at - created_at` in whole seconds (the runner-pickup wait).
    pub pickup_s: u64,
}

/// p50/p95 for one UTC-hour bucket.
#[derive(Debug, Clone)]
pub struct HourBucket {
    /// `YYYY-MM-DDTHH` (UTC).
    pub hour: String,
    pub count: usize,
    pub p50_s: u64,
    pub p95_s: u64,
}

#[derive(Debug, Clone, Default)]
pub struct CiPickupReport {
    pub window_hours: u64,
    pub buckets: Vec<HourBucket>,
    pub runs_queued: u64,
    /// True when the last-30-min p50 pickup exceeds the 10-min threshold.
    pub starved: bool,
    /// p50 over the last 30 min of samples (0 when too few samples).
    pub recent_p50_s: u64,
    /// Number of samples in the last 30-min window (the starvation evidence base).
    pub recent_sample_count: usize,
}

/// The starvation threshold: p50 pickup > 10 minutes.
pub const STARVED_P50_THRESHOLD_S: u64 = 600;
/// Minimum samples in the trailing 30-min window before the detector will fire —
/// guards against a single outlier job tripping a page.
pub const STARVED_MIN_SAMPLES: usize = 3;
/// The trailing window the "for 30 min" clause measures over.
pub const STARVED_WINDOW_MIN: u64 = 30;

/// Nearest-rank percentile over whole-second samples. `sorted` must be ascending.
/// Returns 0 for an empty slice. `p` is a fraction in `[0.0, 1.0]`.
pub fn percentile(sorted: &[u64], p: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    let p = p.clamp(0.0, 1.0);
    // Nearest-rank: rank = ceil(p * n), 1-indexed, clamped to [1, n].
    let n = sorted.len();
    let rank = (p * n as f64).ceil() as usize;
    let idx = rank.saturating_sub(1).min(n - 1);
    sorted[idx]
}

/// Pure starvation verdict: given the pickup seconds of every job enqueued in
/// the trailing 30-min window, the runners are "starved" iff there are enough
/// samples to be meaningful AND their p50 exceeds the 10-min threshold.
pub fn is_starved(recent_pickups_s: &[u64]) -> bool {
    if recent_pickups_s.len() < STARVED_MIN_SAMPLES {
        return false;
    }
    let mut sorted = recent_pickups_s.to_vec();
    sorted.sort_unstable();
    percentile(&sorted, 0.50) > STARVED_P50_THRESHOLD_S
}

/// Parse one JSONL sample line. Tolerant: returns `None` on any malformed line
/// so a single bad row never poisons the whole report.
fn parse_sample(line: &str) -> Option<PickupSample> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    let ts = v.get("ts")?.as_str()?.to_string();
    let pickup_s = v.get("pickup_s")?.as_u64()?;
    Some(PickupSample { ts, pickup_s })
}

/// Epoch-seconds of an RFC3339 timestamp (UTC), or `None` if unparseable.
fn epoch_s(ts: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(ts)
        .ok()
        .map(|dt| dt.timestamp())
}

/// Build the per-hour pickup-latency report from `.chump/metrics/ci_pickup.jsonl`
/// (samples) + `.chump/metrics/ci_runs_queued` (live queued count). `window_hours`
/// bounds which samples are included (by their `ts`); samples with an unparseable
/// `ts` are kept (they still carry a real measurement) but land in an `"?"` bucket.
pub fn build_ci_pickup_report(repo_root: &Path, window_hours: u64) -> CiPickupReport {
    let now = chrono::Utc::now().timestamp();
    let window_cutoff = now - (window_hours as i64) * 3600;
    let recent_cutoff = now - (STARVED_WINDOW_MIN as i64) * 60;

    let samples_path = repo_root.join(".chump/metrics/ci_pickup.jsonl");
    let samples: Vec<PickupSample> = std::fs::read_to_string(&samples_path)
        .map(|c| c.lines().filter_map(parse_sample).collect())
        .unwrap_or_default();

    // Bucket by UTC hour; also gather the trailing-30-min samples for the verdict.
    let mut by_hour: std::collections::BTreeMap<String, Vec<u64>> =
        std::collections::BTreeMap::new();
    let mut recent: Vec<u64> = Vec::new();
    for s in &samples {
        let ep = epoch_s(&s.ts);
        if let Some(ep) = ep {
            if ep < window_cutoff {
                continue;
            }
            if ep >= recent_cutoff {
                recent.push(s.pickup_s);
            }
        }
        // "YYYY-MM-DDTHH" — first 13 chars of RFC3339; "?" when the ts is odd.
        let hour = if s.ts.len() >= 13 {
            s.ts[..13].to_string()
        } else {
            "?".to_string()
        };
        by_hour.entry(hour).or_default().push(s.pickup_s);
    }

    let mut buckets: Vec<HourBucket> = by_hour
        .into_iter()
        .map(|(hour, mut v)| {
            v.sort_unstable();
            HourBucket {
                hour,
                count: v.len(),
                p50_s: percentile(&v, 0.50),
                p95_s: percentile(&v, 0.95),
            }
        })
        .collect();
    buckets.sort_by(|a, b| a.hour.cmp(&b.hour));

    let runs_queued = std::fs::read_to_string(repo_root.join(".chump/metrics/ci_runs_queued"))
        .ok()
        .and_then(|c| c.trim().parse::<u64>().ok())
        .unwrap_or(0);

    let starved = is_starved(&recent);
    let recent_p50_s = {
        let mut r = recent.clone();
        r.sort_unstable();
        percentile(&r, 0.50)
    };

    CiPickupReport {
        window_hours,
        buckets,
        runs_queued,
        starved,
        recent_p50_s,
        recent_sample_count: recent.len(),
    }
}

impl CiPickupReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ CI Runner Pickup Latency (CREDIBLE-1512) ═══\n");
        out.push_str(&format!(
            "  Window: last {}h   ci_runs_queued (now): {}\n",
            self.window_hours, self.runs_queued
        ));
        if self.buckets.is_empty() {
            out.push_str(
                "  No ci_pickup_latency_s samples found.\n  Collect with: scripts/ci/ci-pickup-collect.sh\n",
            );
            return out;
        }
        out.push_str(&format!(
            "  {:<16} {:>8} {:>9} {:>9}\n",
            "hour (UTC)", "samples", "p50(s)", "p95(s)"
        ));
        for b in &self.buckets {
            out.push_str(&format!(
                "  {:<16} {:>8} {:>9} {:>9}\n",
                b.hour, b.count, b.p50_s, b.p95_s
            ));
        }
        out.push_str(&format!(
            "  Runner-starved: {} (last-30m p50={}s over {} samples; threshold {}s)\n",
            if self.starved { "YES" } else { "no" },
            self.recent_p50_s,
            self.recent_sample_count,
            STARVED_P50_THRESHOLD_S
        ));
        out
    }

    pub fn render_json(&self) -> String {
        let buckets: Vec<String> = self
            .buckets
            .iter()
            .map(|b| {
                format!(
                    r#"{{"hour":"{}","count":{},"p50_s":{},"p95_s":{}}}"#,
                    b.hour, b.count, b.p50_s, b.p95_s
                )
            })
            .collect();
        format!(
            r#"{{"window_hours":{},"ci_runs_queued":{},"starved":{},"recent_p50_s":{},"recent_sample_count":{},"buckets":[{}]}}"#,
            self.window_hours,
            self.runs_queued,
            self.starved,
            self.recent_p50_s,
            self.recent_sample_count,
            buckets.join(",")
        )
    }
}

/// Emit `kind=ci_runner_starved` to `.chump-locks/ambient.jsonl` when the report
/// says the runners are starved. Returns `Ok(true)` if an event was written,
/// `Ok(false)` if the report was healthy (no event). Appends a single line
/// carrying the literal `"kind":"ci_runner_starved"` (registry scanner-anchor —
/// see docs/observability/EVENT_REGISTRY.yaml).
pub fn emit_runner_starved_if_needed(
    repo_root: &Path,
    report: &CiPickupReport,
) -> std::io::Result<bool> {
    if !report.starved {
        return Ok(false);
    }
    use std::io::Write;
    let lock_dir = repo_root.join(".chump-locks");
    std::fs::create_dir_all(&lock_dir)?;
    let path = lock_dir.join("ambient.jsonl");
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    // scanner-anchor: "kind":"ci_runner_starved"
    let line = format!(
        r#"{{"ts":"{}","kind":"ci_runner_starved","p50_pickup_s":{},"runs_queued":{},"window_min":{},"sample_count":{}}}"#,
        ts, report.recent_p50_s, report.runs_queued, STARVED_WINDOW_MIN, report.recent_sample_count
    );
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(f, "{line}")?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentile_nearest_rank() {
        let v: Vec<u64> = vec![10, 20, 30, 40, 50];
        assert_eq!(percentile(&v, 0.50), 30);
        assert_eq!(percentile(&v, 0.95), 50);
        assert_eq!(percentile(&v, 0.0), 10);
        assert_eq!(percentile(&v, 1.0), 50);
        assert_eq!(percentile(&[], 0.5), 0);
        assert_eq!(percentile(&[42], 0.5), 42);
    }

    #[test]
    fn not_starved_below_threshold() {
        // p50 under 10 min → healthy even with many samples.
        let pickups = vec![60, 120, 300, 400, 500];
        assert!(!is_starved(&pickups));
    }

    #[test]
    fn not_starved_too_few_samples() {
        // Two slow jobs is not enough evidence to page.
        let pickups = vec![1200, 1800];
        assert!(!is_starved(&pickups));
    }

    #[test]
    fn starved_when_p50_exceeds_ten_min() {
        // p50 (nearest-rank) of these 5 is 1300s = ~21m > 600s.
        let pickups = vec![900, 1200, 1300, 1800, 2400];
        assert!(is_starved(&pickups));
    }

    #[test]
    fn starved_boundary_exclusive() {
        // Exactly 600s p50 is NOT starved (> threshold, not >=).
        let pickups = vec![600, 600, 600];
        assert!(!is_starved(&pickups));
        let pickups = vec![601, 601, 601];
        assert!(is_starved(&pickups));
    }

    #[test]
    fn report_from_fixture_dir() {
        let tmp = std::env::temp_dir().join(format!("ci-pickup-test-{}", std::process::id()));
        let metrics = tmp.join(".chump/metrics");
        std::fs::create_dir_all(&metrics).unwrap();
        // All samples stamped "now" so they land in both the window and the 30-min verdict.
        let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let hour = &now[..13];
        let lines: Vec<String> = [900u64, 1200, 1300, 1800, 2400]
            .iter()
            .map(|p| format!(r#"{{"ts":"{now}","pickup_s":{p}}}"#))
            .collect();
        std::fs::write(metrics.join("ci_pickup.jsonl"), lines.join("\n")).unwrap();
        std::fs::write(metrics.join("ci_runs_queued"), "32\n").unwrap();

        let report = build_ci_pickup_report(&tmp, 24);
        assert_eq!(report.runs_queued, 32);
        assert!(report.starved, "p50 1300s should trip starvation");
        assert_eq!(report.recent_sample_count, 5);
        assert!(report
            .buckets
            .iter()
            .any(|b| b.hour == hour && b.count == 5));
        assert!(report.render_text().contains("Runner-starved: YES"));
        assert!(report.render_json().contains(r#""starved":true"#));

        // Emit path writes exactly one ci_runner_starved line.
        let wrote = emit_runner_starved_if_needed(&tmp, &report).unwrap();
        assert!(wrote);
        let ambient = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(ambient.contains(r#""kind":"ci_runner_starved""#));
        assert!(ambient.contains(r#""runs_queued":32"#));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn healthy_report_emits_nothing() {
        let tmp = std::env::temp_dir().join(format!("ci-pickup-healthy-{}", std::process::id()));
        let report = CiPickupReport {
            window_hours: 24,
            starved: false,
            ..Default::default()
        };
        assert!(!emit_runner_starved_if_needed(&tmp, &report).unwrap());
        assert!(!tmp.join(".chump-locks/ambient.jsonl").exists());
    }
}
