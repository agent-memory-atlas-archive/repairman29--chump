//! INFRA-608: `chump cost-watch` — running tally of Anthropic spend vs per-cycle budget.
//!
//! Reads `kind=session_end` rows from `.chump-locks/ambient.jsonl`, groups by model,
//! computes today's spend (UTC), projects monthly, and warns when over budget.
//!
//! Budget threshold: `--budget X` flag or `CHUMP_DAILY_BUDGET` env var (default $5.00/day).
//! Hard-cap mode: `--hard-cap` exits 1 when today's spend exceeds the budget.
//!
//! INFRA-642: token anomaly detection.
//!
//! `check_token_anomaly` scans the past 30 days of `session_end` events, computes a
//! rolling P50 (median) of total tokens per gap_class (effort:domain), and returns an
//! anomaly record when the supplied session exceeds `CHUMP_TOKEN_ANOMALY_FACTOR × P50`
//! (default 3.0).  Callers write the result to ambient.jsonl via `emit_token_anomaly`
//! and optionally fire an operator-recall webhook via `CHUMP_TOKEN_ANOMALY_WEBHOOK`.

use std::collections::BTreeMap;
use std::path::Path;

/// Per-model spend summary.
#[derive(Debug, Default, Clone)]
pub struct ModelSpend {
    pub model: String,
    pub sessions: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cost_usd: f64,
}

/// Full cost-watch report.
#[derive(Debug)]
pub struct CostWatchReport {
    pub today_spend_usd: f64,
    pub projected_monthly_usd: f64,
    pub budget_usd_per_day: f64,
    pub over_budget: bool,
    pub by_model: Vec<ModelSpend>,
    /// UTC date string for display, e.g. "2026-05-06"
    pub date_utc: String,
}

impl CostWatchReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let indicator = if self.over_budget { "🔴" } else { "🟢" };
        out.push_str(&format!("═══ Cost Watch ({}) ═══\n", self.date_utc));
        out.push_str(&format!(
            "  Today:     ${:.4}  (budget ${:.2}/day)  {}\n",
            self.today_spend_usd, self.budget_usd_per_day, indicator
        ));
        out.push_str(&format!(
            "  Monthly ▶  ${:.2}  (projected)\n",
            self.projected_monthly_usd
        ));
        if !self.by_model.is_empty() {
            out.push_str("\n  By model:\n");
            for m in &self.by_model {
                out.push_str(&format!(
                    "    {:<30}  sessions={:>3}  ${:.4}\n",
                    m.model, m.sessions, m.cost_usd
                ));
            }
        }
        out
    }

    pub fn render_json(&self) -> String {
        let models_json: Vec<String> = self
            .by_model
            .iter()
            .map(|m| {
                format!(
                    r#"{{"model":"{}","sessions":{},"input_tokens":{},"output_tokens":{},"cache_read_tokens":{},"cost_usd":{:.6}}}"#,
                    json_escape(&m.model),
                    m.sessions,
                    m.input_tokens,
                    m.output_tokens,
                    m.cache_read_tokens,
                    m.cost_usd
                )
            })
            .collect();
        format!(
            r#"{{"date_utc":"{}","today_spend_usd":{:.6},"projected_monthly_usd":{:.4},"budget_usd_per_day":{:.2},"over_budget":{},"by_model":[{}]}}"#,
            self.date_utc,
            self.today_spend_usd,
            self.projected_monthly_usd,
            self.budget_usd_per_day,
            self.over_budget,
            models_json.join(",")
        )
    }
}

/// Build the cost-watch report by scanning `ambient.jsonl`.
pub fn build_report(repo_root: &Path, budget_usd_per_day: f64) -> CostWatchReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    // UTC midnight for today (seconds since epoch).
    let now_unix = current_unix();
    let today_start_unix = now_unix - (now_unix % 86_400);
    let date_utc = unix_to_date_utc(today_start_unix);

    let mut by_model: BTreeMap<String, ModelSpend> = BTreeMap::new();

    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < today_start_unix {
            continue;
        }
        let input = extract_int_field(line, "input_tokens").unwrap_or(0);
        let output = extract_int_field(line, "output_tokens").unwrap_or(0);
        let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
        let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
        let cost = crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache);

        let entry = by_model.entry(model.clone()).or_insert_with(|| ModelSpend {
            model: model.clone(),
            ..Default::default()
        });
        entry.sessions += 1;
        entry.input_tokens += input;
        entry.output_tokens += output;
        entry.cache_read_tokens += cache;
        entry.cost_usd += cost;
    }

    let today_spend_usd: f64 = by_model.values().map(|m| m.cost_usd).sum();
    // Project: today's spend extrapolated to 30 days.
    let hours_elapsed = ((now_unix - today_start_unix) as f64 / 3600.0).max(1.0);
    let daily_rate = today_spend_usd * 24.0 / hours_elapsed;
    let projected_monthly_usd = daily_rate * 30.0;

    let over_budget = today_spend_usd > budget_usd_per_day;

    let by_model_vec: Vec<ModelSpend> = by_model.into_values().collect();

    CostWatchReport {
        today_spend_usd,
        projected_monthly_usd,
        budget_usd_per_day,
        over_budget,
        by_model: by_model_vec,
        date_utc,
    }
}

fn current_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn unix_to_date_utc(ts: u64) -> String {
    // Simple Julian-day conversion — no chrono needed.
    let days = ts / 86_400;
    // Algorithm from https://en.wikipedia.org/wiki/Julian_day#Julian_or_Gregorian_calendar_from_Julian_day_number
    let j = days as i64 + 2_440_588; // Unix epoch = JD 2440588
    let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
    let e = 4 * f + 3;
    let g = (e % 1461) / 4;
    let h = 5 * g + 2;
    let day = (h % 153) / 5 + 1;
    let month = (h / 153 + 2) % 12 + 1;
    let year = e / 1461 - 4716 + (14 - month) / 12;
    format!("{:04}-{:02}-{:02}", year, month, day)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    // Expect format "2026-05-06T12:34:56Z" (subset only).
    let s = s.trim_end_matches('Z');
    let mut parts = s.splitn(2, 'T');
    let date_part = parts.next()?;
    let time_part = parts.next().unwrap_or("00:00:00");
    let mut dp = date_part.splitn(3, '-');
    let year: i64 = dp.next()?.parse().ok()?;
    let month: i64 = dp.next()?.parse().ok()?;
    let day: i64 = dp.next()?.parse().ok()?;
    let mut tp = time_part.splitn(3, ':');
    let hour: u64 = tp.next()?.parse().ok()?;
    let min: u64 = tp.next()?.parse().ok()?;
    let sec: u64 = tp
        .next()
        .and_then(|s| s.split('.').next())
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    // Days since Unix epoch via simplified formula.
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32_045;
    let unix_epoch_jdn: i64 = 2_440_588;
    let days = (jdn - unix_epoch_jdn) as u64;
    Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    // Bug fix (INFRA-608 follow-up): the previous needle pre-consumed the
    // opening value-quote which left `rest` already inside the string,
    // bypassing the strip_prefix branch and dragging the closing quote
    // into the result. Use a needle that stops at the colon so the
    // strip_prefix('"') branch works as intended.
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    if let Some(inner) = rest.strip_prefix('"') {
        let end = inner.find('"')?;
        Some(inner[..end].to_string())
    } else {
        let end = rest.find([',', '}']).unwrap_or(rest.len());
        let v = rest[..end].trim().to_string();
        if v == "null" {
            None
        } else {
            Some(v)
        }
    }
}

fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    extract_field(line, field)?.parse().ok()
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

// ─── INFRA-642: token anomaly detection ──────────────────────────────────────

/// Gap class bucket used for P50 grouping: `"<effort>:<domain>"`.
/// Domain is derived from the gap_id prefix (e.g. "INFRA" from "INFRA-642").
/// Effort is taken from an optional `effort` field in the session_end event,
/// falling back to `"unknown"` when absent (backwards compatible).
fn gap_class_from_line(line: &str) -> String {
    let gap_id = extract_field(line, "gap_id").unwrap_or_else(|| "unknown".to_string());
    let domain = gap_id.split('-').next().unwrap_or("unknown").to_uppercase();
    let effort = extract_field(line, "effort").unwrap_or_else(|| "unknown".to_string());
    format!("{}:{}", effort, domain)
}

fn total_tokens_from_line(line: &str) -> u64 {
    let input = extract_int_field(line, "input_tokens").unwrap_or(0);
    let output = extract_int_field(line, "output_tokens").unwrap_or(0);
    let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
    input + output + cache
}

fn p50(mut values: Vec<u64>) -> u64 {
    if values.is_empty() {
        return 0;
    }
    values.sort_unstable();
    let mid = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[mid - 1] + values[mid]) / 2
    } else {
        values[mid]
    }
}

/// Result returned by `check_token_anomaly`.
#[derive(Debug, Clone)]
pub struct TokenAnomalyResult {
    /// The gap class that triggered the anomaly (e.g. `"xs:INFRA"`).
    pub gap_class: String,
    /// Total tokens for the session being checked.
    pub session_tokens: u64,
    /// Rolling 30-day P50 for this gap_class.
    pub p50_tokens: u64,
    /// Configured threshold factor (default 3.0).
    pub factor: f64,
    /// Gap ID of the session being checked.
    pub gap_id: String,
    /// Session ID of the session being checked.
    pub session_id: String,
}

/// Check whether the most-recent completed session (identified by `session_id` +
/// `gap_id`) exceeds the anomaly threshold.
///
/// Returns `Some(TokenAnomalyResult)` if the session's total tokens are greater
/// than `factor × P50` for its gap_class; `None` otherwise.
///
/// `session_tokens` must be the total tokens (input + output + cache_read) for
/// the session.  The function also reads historical data from `ambient.jsonl` to
/// build the P50 baseline, skipping the current session_id to avoid
/// self-contamination.
pub fn check_token_anomaly(
    repo_root: &Path,
    session_id: &str,
    gap_id: &str,
    session_tokens: u64,
) -> Option<TokenAnomalyResult> {
    let factor: f64 = std::env::var("CHUMP_TOKEN_ANOMALY_FACTOR")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3.0_f64);

    let gap_class = {
        let domain = gap_id.split('-').next().unwrap_or("unknown").to_uppercase();
        // effort not available at call site without a DB lookup; use "unknown"
        // unless the caller passes it encoded into gap_id (it won't).
        // The historical lines do carry effort when present.
        format!("unknown:{}", domain)
    };

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let now_unix = current_unix();
    let window_start = now_unix.saturating_sub(30 * 86_400);

    let mut historical: Vec<u64> = Vec::new();
    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        // Skip the current session to avoid self-contamination.
        if let Some(sid) = extract_field(line, "session_id") {
            if sid == session_id {
                continue;
            }
        }
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < window_start {
            continue;
        }
        let lc = gap_class_from_line(line);
        if lc != gap_class {
            continue;
        }
        let tokens = total_tokens_from_line(line);
        if tokens > 0 {
            historical.push(tokens);
        }
    }

    if historical.is_empty() {
        // No baseline — cannot determine anomaly.
        return None;
    }

    let median = p50(historical);
    if median == 0 {
        return None;
    }

    if session_tokens as f64 > factor * median as f64 {
        Some(TokenAnomalyResult {
            gap_class,
            session_tokens,
            p50_tokens: median,
            factor,
            gap_id: gap_id.to_string(),
            session_id: session_id.to_string(),
        })
    } else {
        None
    }
}

/// Emit a `kind=token_anomaly` event to `ambient.jsonl`.
pub fn emit_token_anomaly(repo_root: &Path, result: &TokenAnomalyResult) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();
    let json = format!(
        r#"{{"kind":"token_anomaly","ts":"{ts}","session_id":"{}","gap_id":"{}","gap_class":"{}","session_tokens":{},"p50_tokens":{},"factor":{:.2}}}"#,
        json_escape(&result.session_id),
        json_escape(&result.gap_id),
        json_escape(&result.gap_class),
        result.session_tokens,
        result.p50_tokens,
        result.factor,
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
    maybe_fire_recall_webhook(&json);
}

/// If `CHUMP_TOKEN_ANOMALY_WEBHOOK` is set, POST the anomaly JSON to that URL.
/// Best-effort: silently ignores all errors (no `curl`/`reqwest` dep needed —
/// we shell out to curl which is always present on the fleet hosts).
fn maybe_fire_recall_webhook(payload: &str) {
    let url = match std::env::var("CHUMP_TOKEN_ANOMALY_WEBHOOK") {
        Ok(u) if !u.is_empty() => u,
        _ => return,
    };
    // Best-effort fire-and-forget via curl.
    let _ = std::process::Command::new("curl")
        .args([
            "-s",
            "-o",
            "/dev/null",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-d",
            payload,
            &url,
        ])
        .spawn();
}

fn current_iso8601() -> String {
    // Re-use the unix timestamp helper already in this file.
    let ts = current_unix();
    let date = unix_to_date_utc(ts);
    let secs = ts % 86_400;
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    format!("{date}T{h:02}:{m:02}:{s:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unix_to_date_utc() {
        // 2024-01-01T00:00:00Z = 1704067200 (year-agnostic fixture)
        assert_eq!(unix_to_date_utc(1_704_067_200), "2024-01-01");
        // 2025-05-06T00:00:00Z = 1746489600
        assert_eq!(unix_to_date_utc(1_746_489_600), "2025-05-06");
    }

    #[test]
    fn test_parse_iso8601() {
        assert_eq!(
            parse_iso8601_to_unix("2024-01-01T00:00:00Z"),
            Some(1_704_067_200)
        );
        assert_eq!(
            parse_iso8601_to_unix("2025-05-06T00:00:00Z"),
            Some(1_746_489_600)
        );
    }

    #[test]
    fn test_extract_field() {
        let line = r#"{"kind":"session_end","model":"claude-sonnet","input_tokens":1000}"#;
        assert_eq!(
            extract_field(line, "model").as_deref(),
            Some("claude-sonnet")
        );
        assert_eq!(extract_int_field(line, "input_tokens"), Some(1000));
    }

    #[test]
    #[serial_test::serial]
    fn test_build_report_empty() {
        let dir = tempfile::tempdir().unwrap();
        let report = build_report(dir.path(), 5.0);
        assert_eq!(report.today_spend_usd, 0.0);
        assert!(!report.over_budget);
    }

    #[test]
    #[serial_test::serial]
    fn test_over_budget_flag() {
        std::env::remove_var("CHUMP_COST_INPUT_PER_MTK");
        std::env::remove_var("CHUMP_COST_OUTPUT_PER_MTK");
        std::env::remove_var("CHUMP_COST_CACHE_READ_PER_MTK");
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Write a session_end with today's timestamp and huge token counts.
        let now = current_unix();
        let ts = format!("{}T12:00:00Z", unix_to_date_utc(now - now % 86_400));
        let line = format!(
            r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000000,"output_tokens":500000,"cache_read_tokens":0}}"#
        );
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        writeln!(f, "{}", line).unwrap();
        let report = build_report(dir.path(), 1.0); // $1 budget
        assert!(report.today_spend_usd > 1.0);
        assert!(report.over_budget);
    }

    // ── INFRA-642: token anomaly tests ────────────────────────────────────────

    fn write_ambient_lines(root: &std::path::Path, lines: &[&str]) {
        use std::io::Write;
        let locks = root.join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        for l in lines {
            writeln!(f, "{}", l).unwrap();
        }
    }

    fn session_end_line(
        session_id: &str,
        gap_id: &str,
        total_tokens: u64,
        days_ago: u64,
    ) -> String {
        let now = current_unix();
        let ts_unix = now.saturating_sub(days_ago * 86_400);
        let date = unix_to_date_utc(ts_unix - ts_unix % 86_400);
        let ts = format!("{date}T10:00:00Z");
        format!(
            r#"{{"kind":"session_end","ts":"{ts}","session_id":"{session_id}","gap_id":"{gap_id}","outcome":"shipped","elapsed_seconds":600,"input_tokens":{total_tokens},"output_tokens":0,"cache_read_tokens":0}}"#
        )
    }

    #[test]
    fn test_p50_odd() {
        assert_eq!(p50(vec![10, 20, 30]), 20);
    }

    #[test]
    fn test_p50_even() {
        assert_eq!(p50(vec![10, 20, 30, 40]), 25);
    }

    #[test]
    fn test_p50_single() {
        assert_eq!(p50(vec![100]), 100);
    }

    #[test]
    fn test_no_anomaly_within_threshold() {
        let dir = tempfile::tempdir().unwrap();
        // Baseline: 5 sessions at 1000 tokens each (P50 = 1000)
        let lines: Vec<String> = (0..5)
            .map(|i| session_end_line(&format!("hist-{i}"), "INFRA-100", 1000, i + 1))
            .collect();
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        write_ambient_lines(dir.path(), &refs);

        // Current session at 2999 tokens < 3.0 × 1000
        let result = check_token_anomaly(dir.path(), "cur-1", "INFRA-200", 2999);
        assert!(result.is_none(), "2999 < 3×1000 should not trigger anomaly");
    }

    #[test]
    fn test_anomaly_triggered_above_threshold() {
        let dir = tempfile::tempdir().unwrap();
        // Baseline: 5 sessions at 1000 tokens each (P50 = 1000)
        let lines: Vec<String> = (0..5)
            .map(|i| session_end_line(&format!("hist-{i}"), "INFRA-100", 1000, i + 1))
            .collect();
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        write_ambient_lines(dir.path(), &refs);

        // Current session at 4000 tokens > 3.0 × 1000
        let result = check_token_anomaly(dir.path(), "cur-2", "INFRA-300", 4000);
        assert!(result.is_some(), "4000 > 3×1000 should trigger anomaly");
        let r = result.unwrap();
        assert_eq!(r.p50_tokens, 1000);
        assert_eq!(r.session_tokens, 4000);
        assert!((r.factor - 3.0).abs() < 1e-9);
    }

    #[test]
    fn test_no_anomaly_empty_baseline() {
        let dir = tempfile::tempdir().unwrap();
        // No historical data — cannot judge anomaly
        let result = check_token_anomaly(dir.path(), "cur-3", "INFRA-400", 999_999);
        assert!(result.is_none(), "no baseline should return None");
    }

    #[test]
    fn test_window_excludes_old_events() {
        let dir = tempfile::tempdir().unwrap();
        // 5 old events (31 days ago) — outside 30-day window
        let lines: Vec<String> = (0..5)
            .map(|i| session_end_line(&format!("old-{i}"), "INFRA-100", 1000, 31 + i))
            .collect();
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        write_ambient_lines(dir.path(), &refs);

        // No in-window baseline → None
        let result = check_token_anomaly(dir.path(), "cur-4", "INFRA-500", 50_000);
        assert!(result.is_none(), "out-of-window events should not count");
    }

    #[test]
    fn test_current_session_excluded_from_baseline() {
        let dir = tempfile::tempdir().unwrap();
        // One historical line (normal), plus the "current" session at high tokens
        let hist = session_end_line("hist-0", "INFRA-100", 1000, 1);
        let cur_as_hist = session_end_line("cur-self", "INFRA-100", 99_000, 0);
        write_ambient_lines(dir.path(), &[hist.as_str(), cur_as_hist.as_str()]);

        // If cur-self were counted in the baseline, P50 would be 50000 and 4000 ≯ 3×50000
        // but cur-self must be excluded, leaving P50 = 1000 and 4000 > 3×1000
        let result = check_token_anomaly(dir.path(), "cur-self", "INFRA-600", 4000);
        assert!(
            result.is_some(),
            "self-session must be excluded from baseline"
        );
    }

    #[test]
    fn test_emit_token_anomaly_writes_jsonl() {
        let dir = tempfile::tempdir().unwrap();
        let r = TokenAnomalyResult {
            gap_class: "unknown:INFRA".to_string(),
            session_tokens: 9000,
            p50_tokens: 1000,
            factor: 3.0,
            gap_id: "INFRA-999".to_string(),
            session_id: "sess-xyz".to_string(),
        };
        emit_token_anomaly(dir.path(), &r);
        let contents =
            std::fs::read_to_string(dir.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(contents.contains(r#""kind":"token_anomaly""#));
        assert!(contents.contains("INFRA-999"));
        assert!(contents.contains("\"session_tokens\":9000"));
        assert!(contents.contains("\"p50_tokens\":1000"));
    }
}
