//! INFRA-617 / INFRA-640: `chump kpi report` — exec-summary view of mission progress.
//!
//! Sections:
//!   1. Ship rate trend (1d/7d/30d) with pillar breakdown
//!   2. Mission grade history (last 10 snapshots from ambient.jsonl)
//!   3. Cost-saving vs Anthropic-only baseline
//!   4. Leverage ranking: top gaps by depends_on frequency
//!   5. Tokens-per-ship (P50/P90/Max, top-5 most expensive)
//!
//! Output: markdown to stdout, optional `--json` for machine-readable.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

// ── EFFECTIVE-418: injected pricing function ─────────────────────────────────
//
// The one non-data outbound coupling this module had at extraction time was the
// per-model pricing lookup (`session_ledger::cost_usd_from_tokens`, still inline
// in the bin). Rather than promote that foundation module to a crate (out of
// scope — the EFFECTIVE-406 trap), the pricing function is *injected* by the bin
// at startup via [`set_cost_fn`], the same contract `chump-waste-tally` uses
// (EFFECTIVE-411). This keeps the crate a clean leaf.

/// Per-model pricing function signature: `(model_id, input, output, cache_read)
/// -> usd`. Mirrors the source function the bin injects
/// (`session_ledger::cost_usd_from_tokens`).
pub type CostFn = fn(&str, u64, u64, u64) -> f64;

/// Per-model pricing function, injected by the bin at startup (see `main.rs`,
/// which registers `session_ledger::cost_usd_from_tokens`).
static COST_FN: OnceLock<CostFn> = OnceLock::new();

/// Register the per-model pricing function. Called once from `main()`. Idempotent
/// (first writer wins); subsequent calls are ignored.
pub fn set_cost_fn(f: CostFn) {
    let _ = COST_FN.set(f);
}

/// Price a token bundle via the injected pricing function. Returns `0.0` when no
/// pricing function has been registered — the bin always registers one at
/// startup; the crate's own tests register a fixture pricing fn (see the test
/// module) so the cost-asserting cases stay real.
fn cost_usd_from_tokens(model_id: &str, input: u64, output: u64, cache_read: u64) -> f64 {
    match COST_FN.get() {
        Some(f) => f(model_id, input, output, cache_read),
        None => 0.0,
    }
}

// ── Existing INFRA-640 types (unchanged) ─────────────────────────────────────

/// Per-ship token summary.
#[derive(Debug, Clone)]
pub struct ShipTokens {
    pub gap_id: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub total_tokens: u64,
    pub cost_usd: f64,
}

/// Full tokens-per-ship report.
#[derive(Debug)]
pub struct TokensPerShipReport {
    pub window_days: u64,
    pub ship_count: usize,
    pub p50_tokens: Option<u64>,
    pub p90_tokens: Option<u64>,
    pub max_tokens: Option<u64>,
    pub p50_cost_usd: Option<f64>,
    pub p90_cost_usd: Option<f64>,
    pub max_cost_usd: Option<f64>,
    pub top5: Vec<ShipTokens>,
}

impl TokensPerShipReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "═══ Tokens-per-Ship Report (last {} days) ═══\n",
            self.window_days
        ));
        out.push_str(&format!("  Ships analysed: {}\n", self.ship_count));
        if self.ship_count == 0 {
            out.push_str("  No shipped gaps with token data in window.\n");
            return out;
        }
        let fmt_tok = |v: Option<u64>| {
            v.map(|n| format!("{:>10}", n))
                .unwrap_or_else(|| "         —".to_string())
        };
        let fmt_usd = |v: Option<f64>| {
            v.map(|d| format!("${:.4}", d))
                .unwrap_or_else(|| "      —".to_string())
        };
        out.push_str("\n  Tokens per ship:\n");
        out.push_str(&format!(
            "    P50:  {}  ({})\n",
            fmt_tok(self.p50_tokens),
            fmt_usd(self.p50_cost_usd)
        ));
        out.push_str(&format!(
            "    P90:  {}  ({})\n",
            fmt_tok(self.p90_tokens),
            fmt_usd(self.p90_cost_usd)
        ));
        out.push_str(&format!(
            "    Max:  {}  ({})\n",
            fmt_tok(self.max_tokens),
            fmt_usd(self.max_cost_usd)
        ));
        if !self.top5.is_empty() {
            out.push_str("\n  Top-5 most expensive ships:\n");
            out.push_str(&format!(
                "    {:<20}  {:>12}  {:>10}\n",
                "gap_id", "total_tokens", "cost_usd"
            ));
            for s in &self.top5 {
                out.push_str(&format!(
                    "    {:<20}  {:>12}  ${:.4}\n",
                    s.gap_id, s.total_tokens, s.cost_usd
                ));
            }
        }
        out
    }

    pub fn render_json(&self) -> String {
        let top5_json: Vec<String> = self
            .top5
            .iter()
            .map(|s| {
                format!(
                    r#"{{"gap_id":"{}","input_tokens":{},"output_tokens":{},"cache_read_tokens":{},"total_tokens":{},"cost_usd":{:.6}}}"#,
                    json_escape(&s.gap_id),
                    s.input_tokens,
                    s.output_tokens,
                    s.cache_read_tokens,
                    s.total_tokens,
                    s.cost_usd
                )
            })
            .collect();
        let opt_u64 = |v: Option<u64>| {
            v.map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string())
        };
        let opt_f64 = |v: Option<f64>| {
            v.map(|d| format!("{:.6}", d))
                .unwrap_or_else(|| "null".to_string())
        };
        format!(
            r#"{{"window_days":{},"ship_count":{},"p50_tokens":{},"p90_tokens":{},"max_tokens":{},"p50_cost_usd":{},"p90_cost_usd":{},"max_cost_usd":{},"top5":[{}]}}"#,
            self.window_days,
            self.ship_count,
            opt_u64(self.p50_tokens),
            opt_u64(self.p90_tokens),
            opt_u64(self.max_tokens),
            opt_f64(self.p50_cost_usd),
            opt_f64(self.p90_cost_usd),
            opt_f64(self.max_cost_usd),
            top5_json.join(",")
        )
    }
}

// ── INFRA-617 new sections ───────────────────────────────────────────────────

/// Ship counts per window (1d/7d/30d), broken down by pillar.
#[derive(Debug, Default)]
pub struct ShipRateSection {
    pub windows: Vec<WindowShipCount>,
}

#[derive(Debug)]
pub struct WindowShipCount {
    pub label: String,
    pub total: u64,
    pub effective: u64,
    pub credible: u64,
    pub resilient: u64,
    pub zero_waste: u64,
    pub untagged: u64,
}

impl ShipRateSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Ship Rate Trend ═══\n");
        if self.windows.is_empty() {
            out.push_str("  No shipped gaps found.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<8} {:>8} {:>10} {:>9} {:>10} {:>11} {:>10}\n",
            "window", "total", "effective", "credible", "resilient", "zero-waste", "untagged"
        ));
        for w in &self.windows {
            out.push_str(&format!(
                "  {:<8} {:>8} {:>10} {:>9} {:>10} {:>11} {:>10}\n",
                w.label, w.total, w.effective, w.credible, w.resilient, w.zero_waste, w.untagged
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let windows_json: Vec<String> = self
            .windows
            .iter()
            .map(|w| {
                format!(
                    r#"{{"label":"{}","total":{},"effective":{},"credible":{},"resilient":{},"zero_waste":{},"untagged":{}}}"#,
                    w.label, w.total, w.effective, w.credible, w.resilient, w.zero_waste, w.untagged
                )
            })
            .collect();
        format!(r#"{{"windows":[{}]}}"#, windows_json.join(","))
    }
}

/// A single mission-grade snapshot from ambient.jsonl.
#[derive(Debug, Clone)]
pub struct MissionGradeSnapshot {
    pub ts: String,
    pub effective_shipped: u64,
    pub credible_shipped: u64,
    pub resilient_shipped: u64,
    pub zero_waste_shipped: u64,
    pub total_pickable: u64,
    pub total_in_flight: u64,
}

#[derive(Debug, Default)]
pub struct MissionGradeHistorySection {
    pub snapshots: Vec<MissionGradeSnapshot>,
}

impl MissionGradeHistorySection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Mission Grade History (last 10) ═══\n");
        if self.snapshots.is_empty() {
            out.push_str("  No mission-grade snapshots recorded yet.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<22} {:>8} {:>9} {:>10} {:>11} {:>10} {:>11}\n",
            "ts", "eff", "cred", "resil", "z-waste", "pickable", "in-flight"
        ));
        for s in &self.snapshots {
            let short_ts = if s.ts.len() > 19 { &s.ts[..19] } else { &s.ts };
            out.push_str(&format!(
                "  {:<22} {:>8} {:>9} {:>10} {:>11} {:>10} {:>11}\n",
                short_ts,
                s.effective_shipped,
                s.credible_shipped,
                s.resilient_shipped,
                s.zero_waste_shipped,
                s.total_pickable,
                s.total_in_flight
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let snaps_json: Vec<String> = self
            .snapshots
            .iter()
            .map(|s| {
                format!(
                    r#"{{"ts":"{}","effective_shipped":{},"credible_shipped":{},"resilient_shipped":{},"zero_waste_shipped":{},"total_pickable":{},"total_in_flight":{}}}"#,
                    s.ts, s.effective_shipped, s.credible_shipped, s.resilient_shipped,
                    s.zero_waste_shipped, s.total_pickable, s.total_in_flight
                )
            })
            .collect();
        format!(r#"{{"snapshots":[{}]}}"#, snaps_json.join(","))
    }
}

// ── Mission Binary repeatability (MISSION-066) ──────────────────────────────
// docs/MISSION.md ① THE BINARY answers "did it happen this run". Repeatability
// answers "does it keep happening" — the gap this section closes, per the
// scoreboard's own evidence note ("verify zero-touch + repeatable until
// instrumented"). Reads the `mission_binary_check` events that
// scripts/dev/mission-scoreboard.sh appends to ambient.jsonl on every run.

/// One recorded scoreboard run of ① THE BINARY.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissionBinaryCheck {
    pub ts: String,
    pub repo: String,
    pub beast_merges_7d: u64,
    pub beast_zero_touch_7d: u64,
}

impl MissionBinaryCheck {
    /// True when this run counts as ① YES (at least one zero-touch merge).
    pub fn is_yes(&self) -> bool {
        self.beast_zero_touch_7d > 0
    }
}

#[derive(Debug, Default)]
pub struct MissionBinarySection {
    /// Most-recent-first history of recorded runs.
    pub checks: Vec<MissionBinaryCheck>,
    /// Consecutive YES runs counting back from the most recent (0 if the
    /// latest run is NO or there is no history yet).
    pub current_streak: u64,
    /// Longest consecutive-YES run streak seen in the recorded history.
    pub longest_streak: u64,
}

impl MissionBinarySection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Mission Binary Repeatability (① — MISSION-066) ═══\n");
        if self.checks.is_empty() {
            out.push_str("  No mission_binary_check runs recorded yet — run scripts/dev/mission-scoreboard.sh.\n");
            return out;
        }
        out.push_str(&format!(
            "  current streak: {} run(s)   longest streak: {} run(s)   recorded runs: {}\n",
            self.current_streak,
            self.longest_streak,
            self.checks.len()
        ));
        for c in self.checks.iter().take(10) {
            let short_ts = if c.ts.len() > 19 { &c.ts[..19] } else { &c.ts };
            out.push_str(&format!(
                "  {:<22} {}  zero-touch {} of {} merge(s)\n",
                short_ts,
                if c.is_yes() { "✅ YES" } else { "❌ NO " },
                c.beast_zero_touch_7d,
                c.beast_merges_7d
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let checks_json: Vec<String> = self
            .checks
            .iter()
            .map(|c| {
                format!(
                    r#"{{"ts":"{}","repo":"{}","beast_merges_7d":{},"beast_zero_touch_7d":{},"is_yes":{}}}"#,
                    c.ts,
                    c.repo,
                    c.beast_merges_7d,
                    c.beast_zero_touch_7d,
                    c.is_yes()
                )
            })
            .collect();
        format!(
            r#"{{"current_streak":{},"longest_streak":{},"checks":[{}]}}"#,
            self.current_streak,
            self.longest_streak,
            checks_json.join(",")
        )
    }
}

/// Pure computation over recorded checks (most-recent-first) — split out from
/// the ambient-log parser so the streak logic is directly unit-testable.
fn compute_mission_binary_streaks(checks_most_recent_first: &[MissionBinaryCheck]) -> (u64, u64) {
    let mut current = 0u64;
    for c in checks_most_recent_first {
        if c.is_yes() {
            current += 1;
        } else {
            break;
        }
    }

    let mut longest = 0u64;
    let mut run = 0u64;
    // Walk oldest-first so consecutive runs are contiguous in time.
    for c in checks_most_recent_first.iter().rev() {
        if c.is_yes() {
            run += 1;
            longest = longest.max(run);
        } else {
            run = 0;
        }
    }

    (current, longest)
}

pub fn build_mission_binary_section(repo_root: &Path) -> MissionBinarySection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let mut checks = Vec::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "mission_binary_check" {
            continue;
        }
        checks.push(MissionBinaryCheck {
            ts: extract_field(line, "ts").unwrap_or_default(),
            repo: extract_field(line, "repo").unwrap_or_default(),
            beast_merges_7d: extract_int_field(line, "beast_merges_7d").unwrap_or(0),
            beast_zero_touch_7d: extract_int_field(line, "beast_zero_touch_7d").unwrap_or(0),
        });
    }

    // Most recent first (matches MissionGradeHistorySection convention).
    checks.reverse();
    checks.truncate(50);

    let (current_streak, longest_streak) = compute_mission_binary_streaks(&checks);

    MissionBinarySection {
        checks,
        current_streak,
        longest_streak,
    }
}

/// Cost-saving estimate vs Anthropic-only baseline.
#[derive(Debug, Default)]
pub struct CostSavingsSection {
    /// Total actual cost (USD) across all sessions in window.
    pub actual_cost_usd: f64,
    /// Estimated cost if all sessions used Anthropic Sonnet rates.
    pub anthropic_only_cost_usd: f64,
    pub window_days: u64,
}

impl CostSavingsSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "═══ Cost Savings vs Anthropic-Only (last {} days) ═══\n",
            self.window_days
        ));
        let saved = self.anthropic_only_cost_usd - self.actual_cost_usd;
        let pct = if self.anthropic_only_cost_usd > 0.0 {
            (saved / self.anthropic_only_cost_usd) * 100.0
        } else {
            0.0
        };
        out.push_str(&format!(
            "  Actual cost:        ${:.4}\n",
            self.actual_cost_usd
        ));
        out.push_str(&format!(
            "  Anthropic-only:     ${:.4}\n",
            self.anthropic_only_cost_usd
        ));
        out.push_str(&format!(
            "  Savings:            ${:.4} ({:.1}%)\n",
            saved, pct
        ));
        out
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"actual_cost_usd":{:.6},"anthropic_only_cost_usd":{:.6},"window_days":{}}}"#,
            self.actual_cost_usd, self.anthropic_only_cost_usd, self.window_days
        )
    }
}

/// ZERO-WASTE-060: free/local-tier routing savings, built from `cascade_routed`
/// ambient events (INFRA-1004, extended by ZERO-WASTE-060 to carry a `tokens`
/// field). Every cascade slot — cloud (Groq/Cerebras/Mistral/OpenRouter/Gemini/
/// GitHub Models/NVIDIA NIM/SambaNova) or local (Ollama) — is a free-tier
/// provider the cascade prefers *before* ever falling back to a paid
/// Anthropic-only call, so this section answers "how much of the fleet's
/// inference did we get for free, and what would it have cost otherwise."
#[derive(Debug, Default)]
pub struct FreeTierSavingsSection {
    /// Total estimated tokens served by a free (cloud-cascade or local) slot.
    pub free_tokens_used: u64,
    /// Tokens served by a cloud free-tier slot (Groq, Cerebras, Gemini, ...).
    pub free_cloud_tokens: u64,
    /// Tokens served by the local (Ollama) slot.
    pub free_local_tokens: u64,
    /// Count of cascade_routed events in the window.
    pub routed_calls: u64,
    /// Estimated USD saved: what `free_tokens_used` would have cost at
    /// Anthropic-only (Sonnet) rates, priced entirely as output tokens (the
    /// cascade doesn't currently split input/output at the ambient-event
    /// granularity, so this is a conservative-ish single-bucket estimate).
    pub dollars_saved_usd: f64,
    pub window_days: u64,
}

impl FreeTierSavingsSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "═══ Free/Local-Tier Routing Savings (last {} days) ═══\n",
            self.window_days
        ));
        out.push_str(&format!("  Routed calls:        {}\n", self.routed_calls));
        out.push_str(&format!(
            "  Free tokens used:    {} (cloud: {}, local: {})\n",
            self.free_tokens_used, self.free_cloud_tokens, self.free_local_tokens
        ));
        out.push_str(&format!(
            "  Dollars saved:       ${:.4}\n",
            self.dollars_saved_usd
        ));
        out
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"free_tokens_used":{},"free_cloud_tokens":{},"free_local_tokens":{},"routed_calls":{},"dollars_saved_usd":{:.6},"window_days":{}}}"#,
            self.free_tokens_used,
            self.free_cloud_tokens,
            self.free_local_tokens,
            self.routed_calls,
            self.dollars_saved_usd,
            self.window_days
        )
    }
}

fn build_free_tier_savings_section(repo_root: &Path, window_days: u64) -> FreeTierSavingsSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let window_secs = window_days * 86_400;
    let now_unix = current_unix();
    let cutoff = now_unix.saturating_sub(window_secs);

    let mut free_cloud_tokens = 0u64;
    let mut free_local_tokens = 0u64;
    let mut routed_calls = 0u64;

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "cascade_routed" {
            continue;
        }
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < cutoff {
            continue;
        }
        let tokens = extract_int_field(line, "tokens").unwrap_or(0);
        let tier = extract_field(line, "tier").unwrap_or_default();
        routed_calls += 1;
        if tier == "local" {
            free_local_tokens += tokens;
        } else {
            free_cloud_tokens += tokens;
        }
    }

    let free_tokens_used = free_cloud_tokens + free_local_tokens;
    // Priced as pure output tokens at Anthropic-only (Sonnet) rates — the
    // conservative side of the estimate, since output tokens are the
    // expensive half of the rate table.
    let dollars_saved_usd = cost_usd_from_tokens("unknown", 0, free_tokens_used, 0);

    FreeTierSavingsSection {
        free_tokens_used,
        free_cloud_tokens,
        free_local_tokens,
        routed_calls,
        dollars_saved_usd,
        window_days,
    }
}

/// One gap's leverage score: how many other gaps depend on it.
#[derive(Debug)]
pub struct LeverageEntry {
    pub gap_id: String,
    pub depended_by_count: usize,
}

#[derive(Debug, Default)]
pub struct LeverageSection {
    pub entries: Vec<LeverageEntry>,
}

impl LeverageSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Top Productizations by Leverage ═══\n");
        if self.entries.is_empty() {
            out.push_str("  No dependency data available.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<4} {:<22} {:>10}\n",
            "rank", "gap_id", "unblocks"
        ));
        for (i, e) in self.entries.iter().enumerate() {
            out.push_str(&format!(
                "  {:<4} {:<22} {:>10}\n",
                i + 1,
                e.gap_id,
                e.depended_by_count
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                format!(
                    r#"{{"gap_id":"{}","depended_by_count":{}}}"#,
                    // CREDIBLE-1493: depends_on can hold a JSON array string
                    // (`["META-086"]`); unescaped it broke `kpi report --json`
                    // for every consumer (found by the first calibration run).
                    json_escape(&e.gap_id),
                    e.depended_by_count
                )
            })
            .collect();
        format!(r#"{{"leverage":[{}]}}"#, entries_json.join(","))
    }
}

// ── Handoff self-heal rate (INFRA-773) ───────────────────────────────────────

/// Tracks the Review-as-Handoff self-heal rate over the report window.
///
/// Self-heal rate = applied / initiated. Reviewer-error rate = (failed + timeout) / initiated.
/// Source: ambient.jsonl kinds review_handoff_initiated / applied / failed / timeout.
#[derive(Debug, Default)]
pub struct HandoffRateSection {
    pub initiated: u64,
    pub applied: u64,
    pub failed: u64,
    pub timeout: u64,
}

impl HandoffRateSection {
    pub fn self_heal_rate(&self) -> f64 {
        if self.initiated == 0 {
            0.0
        } else {
            self.applied as f64 / self.initiated as f64
        }
    }

    pub fn reviewer_error_rate(&self) -> f64 {
        if self.initiated == 0 {
            0.0
        } else {
            (self.failed + self.timeout) as f64 / self.initiated as f64
        }
    }

    pub fn render_text(&self) -> String {
        if self.initiated == 0 {
            return "Review-as-Handoff: no handoffs initiated in window.\n".to_string();
        }
        format!(
            "Review-as-Handoff (INFRA-773)\n  Initiated: {}  Applied: {}  Failed: {}  Timeout: {}\n  Self-heal rate: {:.0}%  Reviewer-error rate: {:.0}%\n",
            self.initiated,
            self.applied,
            self.failed,
            self.timeout,
            self.self_heal_rate() * 100.0,
            self.reviewer_error_rate() * 100.0,
        )
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"initiated":{},"applied":{},"failed":{},"timeout":{},"self_heal_rate_pct":{:.1},"reviewer_error_rate_pct":{:.1}}}"#,
            self.initiated,
            self.applied,
            self.failed,
            self.timeout,
            self.self_heal_rate() * 100.0,
            self.reviewer_error_rate() * 100.0,
        )
    }
}

/// Scan ambient.jsonl and count review_handoff_* events within the time window.
fn build_handoff_rate_section(repo_root: &Path, window_days: u64) -> HandoffRateSection {
    use crate::kpi_report::{extract_field, parse_iso8601_to_unix};

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    };
    let cutoff = now.saturating_sub(window_days * 86400);

    let mut section = HandoffRateSection::default();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if !kind.starts_with("review_handoff_") {
            continue;
        }
        if let Some(ts_str) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts_str) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        match kind.as_str() {
            "review_handoff_initiated" => section.initiated += 1,
            "review_handoff_applied" => section.applied += 1,
            "review_handoff_failed" => section.failed += 1,
            "review_handoff_timeout" => section.timeout += 1,
            _ => {}
        }
    }
    section
}

// ── Claim-Lint Bust Rate Section (CREDIBLE-208) ─────────────────────────────

/// Per-model claim-lint bust rate, aggregated from `kind=claim_lint_result`
/// events in ambient.jsonl.
#[derive(Debug, Clone, Default)]
pub struct ClaimBustRow {
    pub model: String,
    pub total_claims: u64,
    pub ungrounded_claims: u64,
    pub runs: u64,
    pub busts: u64,
}

impl ClaimBustRow {
    pub fn bust_rate_pct(&self) -> f64 {
        if self.runs == 0 {
            0.0
        } else {
            (self.busts as f64 / self.runs as f64) * 100.0
        }
    }
}

#[derive(Debug, Default)]
pub struct ClaimBustSection {
    pub rows: Vec<ClaimBustRow>,
}

impl ClaimBustSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Claim-Lint Bust Rate (CREDIBLE-208) ═══\n");
        if self.rows.is_empty() {
            out.push_str("  No claim_lint_result events found.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<24} {:>6} {:>10} {:>12} {:>10}\n",
            "model", "runs", "busts", "bust_rate%", "claims"
        ));
        for row in &self.rows {
            out.push_str(&format!(
                "  {:<24} {:>6} {:>10} {:>11.1}% {:>10}\n",
                row.model,
                row.runs,
                row.busts,
                row.bust_rate_pct(),
                row.total_claims,
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let rows_json: Vec<String> = self
            .rows
            .iter()
            .map(|r| {
                format!(
                    r#"{{"model":"{}","runs":{},"busts":{},"bust_rate_pct":{:.1},"total_claims":{},"ungrounded_claims":{}}}"#,
                    json_escape(&r.model),
                    r.runs,
                    r.busts,
                    r.bust_rate_pct(),
                    r.total_claims,
                    r.ungrounded_claims,
                )
            })
            .collect();
        format!(r#"{{"models":[{}]}}"#, rows_json.join(","))
    }
}

/// Scan ambient.jsonl and aggregate claim_lint_result events per model.
pub fn build_claim_bust_section(repo_root: &Path) -> ClaimBustSection {
    use std::collections::BTreeMap;

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut map: BTreeMap<String, ClaimBustRow> = BTreeMap::new();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "claim_lint_result" {
            continue;
        }
        let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
        let bust = extract_field(line, "bust").as_deref() == Some("true");
        let total_claims: u64 = extract_field(line, "total_claims")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let ungrounded: u64 = extract_field(line, "ungrounded_count")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        let row = map.entry(model.clone()).or_insert_with(|| ClaimBustRow {
            model: model.clone(),
            ..Default::default()
        });
        row.runs += 1;
        if bust {
            row.busts += 1;
        }
        row.total_claims += total_claims;
        row.ungrounded_claims += ungrounded;
    }

    let mut rows: Vec<ClaimBustRow> = map.into_values().collect();
    rows.sort_by(|a, b| {
        b.bust_rate_pct()
            .partial_cmp(&a.bust_rate_pct())
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    ClaimBustSection { rows }
}

// ── Green-First-Try Rate Section (CREDIBLE-1112, slice of CREDIBLE-272) ─────

/// Ship-pipeline green-first-try%: of the gaps that shipped (`kind=gap_shipped`),
/// what fraction had zero `kind=bot_merge_phase_failure` events recorded against
/// the same `gap_id` before shipping — i.e. the pipeline went green without a
/// failed phase (fmt/clippy/test/push/pr-create) forcing a retry.
#[derive(Debug, Default, Clone)]
pub struct GreenFirstTrySection {
    pub total_ships: u64,
    pub green_first_try: u64,
}

impl GreenFirstTrySection {
    pub fn green_first_try_pct(&self) -> f64 {
        if self.total_ships == 0 {
            0.0
        } else {
            (self.green_first_try as f64 / self.total_ships as f64) * 100.0
        }
    }

    pub fn render_text(&self) -> String {
        if self.total_ships == 0 {
            return "═══ Green-First-Try% (CREDIBLE-1112) ═══\n  No gap_shipped events found.\n"
                .to_string();
        }
        format!(
            "═══ Green-First-Try% (CREDIBLE-1112) ═══\n  {}/{} ships green on first try ({:.1}%)\n",
            self.green_first_try,
            self.total_ships,
            self.green_first_try_pct(),
        )
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"total_ships":{},"green_first_try":{},"green_first_try_pct":{:.1}}}"#,
            self.total_ships,
            self.green_first_try,
            self.green_first_try_pct(),
        )
    }
}

/// Scan ambient.jsonl and correlate `gap_shipped` events against
/// `bot_merge_phase_failure` events sharing the same `gap_id`.
pub fn build_green_first_try_section(repo_root: &Path) -> GreenFirstTrySection {
    use std::collections::HashSet;

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut failed_gap_ids: HashSet<String> = HashSet::new();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "bot_merge_phase_failure" {
            continue;
        }
        if let Some(gap_id) = extract_field(line, "gap_id") {
            failed_gap_ids.insert(gap_id);
        }
    }

    let mut section = GreenFirstTrySection::default();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "gap_shipped" {
            continue;
        }
        let gap_id = match extract_field(line, "gap_id") {
            Some(id) => id,
            None => continue,
        };
        section.total_ships += 1;
        if !failed_gap_ids.contains(&gap_id) {
            section.green_first_try += 1;
        }
    }
    section
}

// ── Time-to-Land Section (CREDIBLE-1113, slice of CREDIBLE-272) ─────────────

/// Ship-pipeline time-to-land: wall-clock seconds from `kind=gap_claimed` to
/// `kind=gap_shipped` for the same `gap_id`, aggregated as p50/p90/max.
#[derive(Debug, Default, Clone)]
pub struct TimeToLandSection {
    pub sample_count: u64,
    pub p50_seconds: Option<u64>,
    pub p90_seconds: Option<u64>,
    pub max_seconds: Option<u64>,
}

impl TimeToLandSection {
    pub fn render_text(&self) -> String {
        if self.sample_count == 0 {
            return "═══ Time-to-Land (CREDIBLE-1113) ═══\n  No claim→ship pairs found.\n"
                .to_string();
        }
        format!(
            "═══ Time-to-Land (CREDIBLE-1113) ═══\n  n={} p50={}s p90={}s max={}s\n",
            self.sample_count,
            self.p50_seconds.unwrap_or(0),
            self.p90_seconds.unwrap_or(0),
            self.max_seconds.unwrap_or(0),
        )
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"sample_count":{},"p50_seconds":{},"p90_seconds":{},"max_seconds":{}}}"#,
            self.sample_count,
            opt_u64(self.p50_seconds),
            opt_u64(self.p90_seconds),
            opt_u64(self.max_seconds),
        )
    }
}

fn opt_u64(v: Option<u64>) -> String {
    match v {
        Some(n) => n.to_string(),
        None => "null".to_string(),
    }
}

fn percentile_u64_slice(sorted: &[u64], pct: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (pct * sorted.len()).div_ceil(100);
    let idx = rank.saturating_sub(1).min(sorted.len() - 1);
    Some(sorted[idx])
}

/// Scan ambient.jsonl and correlate `gap_claimed` events against `gap_shipped`
/// events sharing the same `gap_id`, taking the earliest claim before each ship.
pub fn build_time_to_land_section(repo_root: &Path) -> TimeToLandSection {
    use std::collections::HashMap;

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut claimed_at: HashMap<String, u64> = HashMap::new();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "gap_claimed" {
            continue;
        }
        let (Some(gap_id), Some(ts)) = (
            extract_field(line, "gap_id"),
            extract_field(line, "ts").and_then(|t| parse_iso8601_to_unix(&t)),
        ) else {
            continue;
        };
        claimed_at
            .entry(gap_id)
            .and_modify(|existing| *existing = (*existing).min(ts))
            .or_insert(ts);
    }

    let mut durations: Vec<u64> = Vec::new();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "gap_shipped" {
            continue;
        }
        let (Some(gap_id), Some(shipped_ts)) = (
            extract_field(line, "gap_id"),
            extract_field(line, "ts").and_then(|t| parse_iso8601_to_unix(&t)),
        ) else {
            continue;
        };
        if let Some(&claim_ts) = claimed_at.get(&gap_id) {
            if shipped_ts >= claim_ts {
                durations.push(shipped_ts - claim_ts);
            }
        }
    }

    let mut section = TimeToLandSection {
        sample_count: durations.len() as u64,
        ..Default::default()
    };
    durations.sort_unstable();
    section.p50_seconds = percentile_u64_slice(&durations, 50);
    section.p90_seconds = percentile_u64_slice(&durations, 90);
    section.max_seconds = durations.last().copied();
    section
}

// ── Gate False-Positive Rate Section (CREDIBLE-1115, slice of CREDIBLE-272) ─

/// Ship-pipeline gate FP rate: of the halt-class/gate signals routed through
/// the duty-officer quiet gate (`kind=duty_officer_action`), what fraction
/// were determined to be false positives (`verdict=refuted`) rather than
/// genuine (`verdict=healed|suppressed|runbook_needed`).
#[derive(Debug, Default, Clone)]
pub struct GateFalsePositiveSection {
    pub total_signals: u64,
    pub false_positives: u64,
}

impl GateFalsePositiveSection {
    pub fn fp_rate_pct(&self) -> f64 {
        if self.total_signals == 0 {
            0.0
        } else {
            (self.false_positives as f64 / self.total_signals as f64) * 100.0
        }
    }

    pub fn render_text(&self) -> String {
        if self.total_signals == 0 {
            return "═══ Gate FP Rate (CREDIBLE-1115) ═══\n  No duty_officer_action events found.\n"
                .to_string();
        }
        format!(
            "═══ Gate FP Rate (CREDIBLE-1115) ═══\n  {}/{} signals refuted as false positive ({:.1}%)\n",
            self.false_positives,
            self.total_signals,
            self.fp_rate_pct(),
        )
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"total_signals":{},"false_positives":{},"fp_rate_pct":{:.1}}}"#,
            self.total_signals,
            self.false_positives,
            self.fp_rate_pct(),
        )
    }
}

/// Scan ambient.jsonl for `kind=duty_officer_action` events and tally verdicts.
pub fn build_gate_false_positive_section(repo_root: &Path) -> GateFalsePositiveSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut section = GateFalsePositiveSection::default();
    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "duty_officer_action" {
            continue;
        }
        section.total_signals += 1;
        if extract_field(line, "verdict").as_deref() == Some("refuted") {
            section.false_positives += 1;
        }
    }
    section
}

// ── Shell Invariant Writers Section (CREDIBLE-1509, R6.4 gauge) ──────────────

/// The R6.4 gauge: how many shell/Python files under `scripts/` the
/// invariant-boundary gate (`scripts/ci/test-invariant-boundary.sh`,
/// INFRA-8218) flags for writing an invariant (the store, a lease file, a gap
/// status) directly. Target zero for seven clean days. See
/// docs/strategy/PHASE_R_ARCHITECTURE_PROGRAM_2026-10-15.md §R6.
///
/// The gate's last stdout line is the `kind=invariant_boundary_violation`
/// event it also appends to `.chump-locks/ambient.jsonl`, carrying `count`.
/// One gate run takes ~20s, so a reading under 24h old in the ambient stream
/// is reused instead of re-running it; no reading at all is reported as
/// unavailable, never as a fabricated zero.
#[derive(Debug, Default, Clone)]
pub struct ShellInvariantWritersSection {
    /// Violator file count. `None` when no reading is available.
    pub file_count: Option<u64>,
    /// Date of the reading, `YYYY-MM-DD` (UTC): the event's `ts` date.
    pub reading_date: Option<String>,
    /// Where the reading came from: "gate" (ran now), "ambient" (a recorded
    /// gate reading), or "unavailable".
    pub source: String,
}

impl ShellInvariantWritersSection {
    pub fn render_text(&self) -> String {
        let mut out = String::from("═══ Shell Invariant Writers (R6.4) ═══\n");
        match self.file_count {
            Some(n) => {
                out.push_str(&format!("  shell_invariant_writers: {n}  (target 0)\n"));
                out.push_str(&format!(
                    "  read {} from {}\n",
                    self.reading_date.as_deref().unwrap_or("?"),
                    self.source,
                ));
            }
            None => out.push_str(
                "  No reading: scripts/ci/test-invariant-boundary.sh not run and no invariant_boundary_violation event recorded.\n",
            ),
        }
        out
    }

    pub fn render_json(&self) -> String {
        let count = self
            .file_count
            .map(|n| n.to_string())
            .unwrap_or_else(|| "null".to_string());
        let date = self
            .reading_date
            .as_deref()
            .map(|d| format!(r#""{}""#, json_escape(d)))
            .unwrap_or_else(|| "null".to_string());
        format!(
            r#"{{"shell_invariant_writers":{},"reading_date":{},"source":"{}","target":0}}"#,
            count,
            date,
            json_escape(&self.source),
        )
    }
}

/// A gate reading parsed from one `invariant_boundary_violation` JSON line:
/// (count, ts as unix seconds if parseable, `YYYY-MM-DD` date).
fn parse_invariant_boundary_reading(line: &str) -> Option<(u64, Option<i64>, Option<String>)> {
    let v = serde_json::from_str::<serde_json::Value>(line.trim()).ok()?;
    if v.get("kind").and_then(|k| k.as_str()) != Some("invariant_boundary_violation") {
        return None;
    }
    let count = v.get("count").and_then(|x| x.as_u64())?;
    let ts = v.get("ts").and_then(|t| t.as_str());
    let unix = ts.and_then(|t| {
        chrono::DateTime::parse_from_rfc3339(t)
            .ok()
            .map(|d| d.timestamp())
    });
    let date = ts.map(|t| t.chars().take(10).collect::<String>());
    Some((count, unix, date))
}

/// Max age of a recorded gate reading that is reused instead of re-running
/// the ~20s gate.
const SHELL_INVARIANT_WRITERS_FRESH_SECS: i64 = 24 * 3600;

/// Build the R6.4 `shell_invariant_writers` gauge (CREDIBLE-1509).
///
/// Order: (1) the latest `invariant_boundary_violation` reading in the ambient
/// stream if it is under 24h old; (2) a live run of the gate in shadow mode
/// (it records a fresh reading as a side effect); (3) the latest recorded
/// reading of any age (its date shows the staleness); (4) unavailable.
/// `run_gate = false` skips step 2, for callers that must stay fast (the
/// fleet-brief banner, via `kpi report --shell-invariant-writers --no-gate`).
/// A CLI flag, not an env var: the R6 gauge must not ship a bypass var of its
/// own (INFRA-2429 debt ceiling).
pub fn build_shell_invariant_writers_section(repo_root: &Path) -> ShellInvariantWritersSection {
    build_shell_invariant_writers_section_with(repo_root, true)
}

/// [`build_shell_invariant_writers_section`] with the live gate run made
/// explicit (`run_gate`).
pub fn build_shell_invariant_writers_section_with(
    repo_root: &Path,
    run_gate: bool,
) -> ShellInvariantWritersSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let latest = contents
        .lines()
        .filter_map(parse_invariant_boundary_reading)
        .next_back();
    let now = chrono::Utc::now().timestamp();
    let from_ambient =
        |(n, _, date): (u64, Option<i64>, Option<String>)| ShellInvariantWritersSection {
            file_count: Some(n),
            reading_date: date,
            source: "ambient".to_string(),
        };

    if let Some(r) = latest.clone() {
        if r.1
            .is_some_and(|t| now - t < SHELL_INVARIANT_WRITERS_FRESH_SECS)
        {
            return from_ambient(r);
        }
    }

    let script = repo_root.join("scripts/ci/test-invariant-boundary.sh");
    if run_gate && script.is_file() {
        if let Ok(out) = std::process::Command::new("bash")
            .arg(&script)
            .env("CHUMP_BOUNDARY_GATE", "shadow")
            .current_dir(repo_root)
            .output()
        {
            // The gate prints the violator list first; the reading is the
            // last line that parses as an invariant_boundary_violation event.
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Some((n, _, date)) = stdout
                .lines()
                .rev()
                .find_map(parse_invariant_boundary_reading)
            {
                return ShellInvariantWritersSection {
                    file_count: Some(n),
                    reading_date: date
                        .or_else(|| Some(chrono::Utc::now().format("%Y-%m-%d").to_string())),
                    source: "gate".to_string(),
                };
            }
        }
    }

    if let Some(r) = latest {
        return from_ambient(r);
    }

    ShellInvariantWritersSection {
        file_count: None,
        reading_date: None,
        source: "unavailable".to_string(),
    }
}

// ── Shell LOC by Month Section (INFRA-8577, R6 gauge) ────────────────────────

/// One month's shell-LOC reading: total lines of `.sh` and `.py` files under
/// `scripts/` at the **first commit of that month**, read straight out of git
/// objects (`git ls-tree` + `git cat-file --batch`, no checkout). Lines are
/// counted `wc -l`-style (newline bytes), so a file with no trailing newline
/// does not count its final partial line.
#[derive(Debug, Clone)]
pub struct ShellLocMonth {
    /// `YYYY-MM`.
    pub month: String,
    /// First commit SHA of that month on `HEAD`'s history. `None` when the
    /// month has no commit in range.
    pub commit: Option<String>,
    /// Total `.sh` + `.py` LOC under `scripts/` at `commit`. `None` when there
    /// is no commit, or git could not be read.
    pub loc: Option<u64>,
}

/// The R6 falling-trend gauge: shell LOC under `scripts/` at the first commit
/// of each of the last three months, so the batch-of-5-files-per-PR shrink
/// (INFRA-8195) is measurable. Months are oldest → newest so the trend reads
/// left-to-right. See docs/strategy/PHASE_R_ARCHITECTURE_PROGRAM_2026-10-15.md §R6.
#[derive(Debug, Default, Clone)]
pub struct ShellLocByMonthSection {
    pub months: Vec<ShellLocMonth>,
}

impl ShellLocByMonthSection {
    pub fn render_text(&self) -> String {
        let mut out = String::from("═══ Shell LOC by Month (R6) ═══\n");
        if self.months.is_empty() {
            out.push_str("  No git history available.\n");
            return out;
        }
        // One trend line, oldest → newest, joined by arrows (AC3).
        let cells: Vec<String> = self
            .months
            .iter()
            .map(|m| {
                let v = m
                    .loc
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "n/a".to_string());
                format!("{}={}", m.month, v)
            })
            .collect();
        out.push_str(&format!("  trend: {}\n", cells.join(" → ")));
        out
    }

    pub fn render_json(&self) -> String {
        let rows: Vec<String> = self
            .months
            .iter()
            .map(|m| {
                let commit = m
                    .commit
                    .as_deref()
                    .map(|c| format!(r#""{}""#, json_escape(c)))
                    .unwrap_or_else(|| "null".to_string());
                let loc = m
                    .loc
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "null".to_string());
                format!(
                    r#"{{"month":"{}","commit":{},"loc":{}}}"#,
                    json_escape(&m.month),
                    commit,
                    loc,
                )
            })
            .collect();
        format!("[{}]", rows.join(","))
    }
}

/// The `(year, month)` of the `n` months ending at `(year, month0)`, oldest
/// first. `month0` is 1..=12. Arithmetic is modular so year boundaries wrap
/// correctly (e.g. Jan of year Y looks back to Nov/Dec of Y-1).
fn last_n_months(year: i32, month0: u32, n: usize) -> Vec<(i32, u32)> {
    let base = year as i64 * 12 + (month0 as i64 - 1);
    (0..n as i64)
        .rev()
        .map(|back| {
            let total = base - back;
            let y = total.div_euclid(12) as i32;
            let m = total.rem_euclid(12) as u32 + 1;
            (y, m)
        })
        .collect()
}

/// First commit SHA of each requested `(year, month)` on `HEAD`'s history, in
/// the same order as `months`. Reads `git log` once (`%H %cd` with a `%Y-%m`
/// date format) and keeps the earliest commit per month (log is newest-first,
/// so the last-seen line for a month is its earliest commit).
fn first_commit_of_each_month(repo_root: &Path, months: &[(i32, u32)]) -> Vec<Option<String>> {
    let out = std::process::Command::new("git")
        .args(["-C", &repo_root.to_string_lossy()])
        .args(["log", "--format=%H %cd", "--date=format:%Y-%m"])
        .output();
    let mut earliest: BTreeMap<String, String> = BTreeMap::new();
    if let Ok(out) = out {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout);
            for line in stdout.lines() {
                if let Some((sha, ym)) = line.split_once(' ') {
                    // Newest-first: overwrite so the last write (oldest commit)
                    // of each month wins.
                    earliest.insert(ym.trim().to_string(), sha.trim().to_string());
                }
            }
        }
    }
    months
        .iter()
        .map(|(y, m)| earliest.get(&format!("{y:04}-{m:02}")).cloned())
        .collect()
}

/// Total `.sh` + `.py` LOC under `scripts/` at `commit`, read from git objects
/// with no checkout. `ls-tree` lists the blobs; a single `cat-file --batch`
/// streams their contents and lines are counted by newline byte. `None` on git
/// failure; `Some(0)` when the tree has no matching files.
fn count_shell_loc_at_commit(repo_root: &Path, commit: &str) -> Option<u64> {
    let root = repo_root.to_string_lossy().to_string();
    let listing = std::process::Command::new("git")
        .args(["-C", &root, "ls-tree", "-r", commit, "--", "scripts"])
        .output()
        .ok()?;
    if !listing.status.success() {
        return None;
    }
    let listing = String::from_utf8_lossy(&listing.stdout);
    let mut hashes: Vec<String> = Vec::new();
    for line in listing.lines() {
        // Format: "<mode> <type> <object>\t<path>"
        let Some((meta, path)) = line.split_once('\t') else {
            continue;
        };
        if !(path.ends_with(".sh") || path.ends_with(".py")) {
            continue;
        }
        if let Some(obj) = meta.split_whitespace().nth(2) {
            hashes.push(obj.to_string());
        }
    }
    if hashes.is_empty() {
        return Some(0);
    }

    let mut child = std::process::Command::new("git")
        .args(["-C", &root, "cat-file", "--batch"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    // Write hashes from a thread so a large stdout can't deadlock the pipe
    // while we're still feeding stdin.
    let mut stdin = child.stdin.take()?;
    let input = {
        let mut s = hashes.join("\n");
        s.push('\n');
        s
    };
    let writer = std::thread::spawn(move || {
        use std::io::Write;
        let _ = stdin.write_all(input.as_bytes());
    });
    let out = child.wait_with_output().ok()?;
    let _ = writer.join();
    if !out.status.success() {
        return None;
    }

    // Parse the --batch stream: per entry a header line
    // "<sha> <type> <size>\n" followed by <size> content bytes and a trailing
    // newline. A missing object is "<sha> missing\n" with no body.
    let buf = &out.stdout;
    let n = buf.len();
    let mut i = 0usize;
    let mut total: u64 = 0;
    for _ in 0..hashes.len() {
        if i >= n {
            break;
        }
        let mut j = i;
        while j < n && buf[j] != b'\n' {
            j += 1;
        }
        let header = String::from_utf8_lossy(&buf[i..j]);
        i = j + 1; // past the header newline
        let parts: Vec<&str> = header.split_whitespace().collect();
        if parts.len() < 3 {
            // "missing" or malformed — no body to skip.
            continue;
        }
        let Ok(size) = parts[2].parse::<usize>() else {
            continue;
        };
        if i + size > n {
            break;
        }
        total += buf[i..i + size].iter().filter(|&&b| b == b'\n').count() as u64;
        i += size;
        if i < n && buf[i] == b'\n' {
            i += 1; // trailing newline git appends after the body
        }
    }
    Some(total)
}

/// Build the shell-LOC-by-month gauge for the last three months ending at the
/// current UTC month.
pub fn build_shell_loc_by_month_section(repo_root: &Path) -> ShellLocByMonthSection {
    use chrono::Datelike;
    let now = chrono::Utc::now();
    let months = last_n_months(now.year(), now.month(), 3);
    build_shell_loc_by_month_section_with(repo_root, &months)
}

/// [`build_shell_loc_by_month_section`] with an explicit month list, so tests
/// can pin the window against a fixture repo with known counts.
pub fn build_shell_loc_by_month_section_with(
    repo_root: &Path,
    months: &[(i32, u32)],
) -> ShellLocByMonthSection {
    let commits = first_commit_of_each_month(repo_root, months);
    let months = months
        .iter()
        .zip(commits)
        .map(|((y, m), commit)| {
            let loc = commit
                .as_deref()
                .and_then(|c| count_shell_loc_at_commit(repo_root, c));
            ShellLocMonth {
                month: format!("{y:04}-{m:02}"),
                commit,
                loc,
            }
        })
        .collect();
    ShellLocByMonthSection { months }
}

// ── CI Test Census (CREDIBLE-1514) ──────────────────────────────────────────

/// `ci_tests_unwired` / `ci_tests_red` from docs/observability/ci-test-census.json,
/// written by scripts/ci/census.sh (nightly via ci-test-census.yml). `None`
/// when the census file is absent or unreadable.
#[derive(Debug, Default, Clone)]
pub struct CiCensusSection {
    pub unwired: Option<u64>,
    pub red: Option<u64>,
    pub total: Option<u64>,
    pub run_date: String,
    pub mode: String,
}

impl CiCensusSection {
    pub fn render_text(&self) -> String {
        match (self.unwired, self.red) {
            (Some(u), Some(r)) => format!(
                "═══ CI Test Census (CREDIBLE-1514) ═══\n  ci_tests_unwired: {u}\n  ci_tests_red: {r}\n  of {} scripts/ci tests; census {} ({})\n",
                self.total.unwrap_or(0),
                self.run_date,
                self.mode,
            ),
            _ => "═══ CI Test Census (CREDIBLE-1514) ═══\n  No docs/observability/ci-test-census.json (run scripts/ci/census.sh).\n".to_string(),
        }
    }

    pub fn render_json(&self) -> String {
        let n = |v: Option<u64>| v.map_or("null".to_string(), |x| x.to_string());
        format!(
            r#"{{"ci_tests_unwired":{},"ci_tests_red":{},"ci_tests_total":{},"run_date":"{}"}}"#,
            n(self.unwired),
            n(self.red),
            n(self.total),
            json_escape(&self.run_date),
        )
    }
}

pub fn build_ci_census_section(repo_root: &Path) -> CiCensusSection {
    let path = repo_root.join("docs/observability/ci-test-census.json");
    let Some(json) = std::fs::read_to_string(&path)
        .ok()
        .and_then(|c| serde_json::from_str::<serde_json::Value>(&c).ok())
    else {
        return CiCensusSection::default();
    };
    let count = |k: &str| {
        json.get("counts")
            .and_then(|c| c.get(k))
            .and_then(|v| v.as_u64())
    };
    let text = |k: &str| {
        json.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    CiCensusSection {
        unwired: count("unwired"),
        red: count("red"),
        total: count("total"),
        run_date: text("run_date"),
        mode: text("mode"),
    }
}

// ── Combined KPI Report ──────────────────────────────────────────────────────

/// Full KPI report wrapping all sections.
#[derive(Debug)]
pub struct KpiReport {
    pub ship_rate: ShipRateSection,
    pub mission_history: MissionGradeHistorySection,
    pub cost_savings: CostSavingsSection,
    pub free_tier_savings: FreeTierSavingsSection,
    pub leverage: LeverageSection,
    pub tokens_per_ship: TokensPerShipReport,
    pub handoff_rate: HandoffRateSection,
    pub green_first_try: GreenFirstTrySection,
    pub time_to_land: TimeToLandSection,
    pub gate_false_positive: GateFalsePositiveSection,
    pub shell_invariant_writers: ShellInvariantWritersSection,
    /// INFRA-8577: shell LOC under scripts/ at the first commit of each of the
    /// last three months — the R6 falling-trend gauge.
    pub shell_loc_by_month: ShellLocByMonthSection,
    /// CREDIBLE-1512: CI runner pickup-latency (p50/p95 per hour) + queued count.
    pub ci_pickup: crate::ci_pickup::CiPickupReport,
    pub ci_census: CiCensusSection,
    /// CREDIBLE-1525: admin_merges_7d — merges that bypassed the verified gate.
    pub admin_merges: crate::admin_merges::AdminMergesSection,
}

impl KpiReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("╔══════════════════════════════════════════════╗\n");
        out.push_str("║        Chump KPI Report (INFRA-617)        ║\n");
        out.push_str("╚══════════════════════════════════════════════╝\n\n");
        out.push_str(&self.ship_rate.render_text());
        out.push('\n');
        out.push_str(&self.mission_history.render_text());
        out.push('\n');
        out.push_str(&self.cost_savings.render_text());
        out.push('\n');
        out.push_str(&self.free_tier_savings.render_text());
        out.push('\n');
        out.push_str(&self.leverage.render_text());
        out.push('\n');
        out.push_str(&self.tokens_per_ship.render_text());
        out.push('\n');
        out.push_str(&self.handoff_rate.render_text());
        out.push('\n');
        out.push_str(&self.green_first_try.render_text());
        out.push('\n');
        out.push_str(&self.time_to_land.render_text());
        out.push('\n');
        out.push_str(&self.gate_false_positive.render_text());
        out.push('\n');
        out.push_str(&self.shell_invariant_writers.render_text());
        out.push('\n');
        out.push_str(&self.shell_loc_by_month.render_text());
        out.push('\n');
        out.push_str(&self.ci_pickup.render_text());
        out.push('\n');
        out.push_str(&self.ci_census.render_text());
        out.push('\n');
        out.push_str(&self.admin_merges.render_text());
        out
    }

    pub fn render_json(&self) -> String {
        format!(
            r#"{{"ship_rate":{},"mission_history":{},"cost_savings":{},"free_tier_savings":{},"leverage":{},"tokens_per_ship":{},"handoff_rate":{},"green_first_try":{},"time_to_land":{},"gate_false_positive":{},"shell_invariant_writers":{},"shell_loc_by_month":{},"ci_pickup":{},"ci_census":{},"admin_merges":{}}}"#,
            self.ship_rate.render_json(),
            self.mission_history.render_json(),
            self.cost_savings.render_json(),
            self.free_tier_savings.render_json(),
            self.leverage.render_json(),
            self.tokens_per_ship.render_json(),
            self.handoff_rate.render_json(),
            self.green_first_try.render_json(),
            self.time_to_land.render_json(),
            self.gate_false_positive.render_json(),
            self.shell_invariant_writers.render_json(),
            self.shell_loc_by_month.render_json(),
            self.ci_pickup.render_json(),
            self.ci_census.render_json(),
            self.admin_merges.render_json(),
        )
    }
}

// ── Agent Throughput Section (FLEET-044) ────────────────────────────────────

/// Per-agent throughput row parsed from .chump/metrics/agent-throughput-DATE.json.
#[derive(Debug, Clone)]
pub struct AgentThroughputRow {
    pub agent_id: String,
    pub ships: u64,
    pub fails: u64,
    pub p50_minutes_per_ship: Option<f64>,
    pub top_fail_modes: Vec<String>,
}

#[derive(Debug, Default)]
pub struct AgentThroughputSection {
    pub date: String,
    pub rows: Vec<AgentThroughputRow>,
    pub total_ships: u64,
    pub total_fails: u64,
}

impl AgentThroughputSection {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Agent Throughput ═══\n");
        if self.date.is_empty() {
            out.push_str(
                "  No throughput data found. Run: scripts/ops/agent-throughput-tracker.sh\n",
            );
            return out;
        }
        out.push_str(&format!("  Date: {}\n", self.date));
        out.push_str(&format!(
            "  Total ships: {}  Total fails: {}\n\n",
            self.total_ships, self.total_fails
        ));
        if self.rows.is_empty() {
            out.push_str("  No agent sessions recorded.\n");
            return out;
        }
        out.push_str(&format!(
            "  {:<36} {:>6} {:>6} {:>16}  {}\n",
            "agent_id", "ships", "fails", "P50_min/ship", "top_fail_modes"
        ));
        for row in &self.rows {
            let p50 = row
                .p50_minutes_per_ship
                .map(|v| format!("{:.1}", v))
                .unwrap_or_else(|| "—".to_string());
            out.push_str(&format!(
                "  {:<36} {:>6} {:>6} {:>16}  {}\n",
                row.agent_id,
                row.ships,
                row.fails,
                p50,
                row.top_fail_modes.join(", ")
            ));
        }
        out
    }

    pub fn render_json(&self) -> String {
        let rows_json: Vec<String> = self
            .rows
            .iter()
            .map(|r| {
                let p50 = r
                    .p50_minutes_per_ship
                    .map(|v| format!("{:.1}", v))
                    .unwrap_or_else(|| "null".to_string());
                let modes = r
                    .top_fail_modes
                    .iter()
                    .map(|m| format!(r#""{}""#, json_escape(m)))
                    .collect::<Vec<_>>()
                    .join(",");
                format!(
                    r#"{{"agent_id":"{}","ships":{},"fails":{},"P50_minutes_per_ship":{},"top_fail_modes":[{}]}}"#,
                    json_escape(&r.agent_id),
                    r.ships,
                    r.fails,
                    p50,
                    modes
                )
            })
            .collect();
        format!(
            r#"{{"date":"{}","total_ships":{},"total_fails":{},"agents":[{}]}}"#,
            json_escape(&self.date),
            self.total_ships,
            self.total_fails,
            rows_json.join(",")
        )
    }
}

/// CREDIBLE-099 AC-4/AC-7: when no `.chump/metrics/agent-throughput-*.json`
/// snapshot exists (the tracker script never ran, or hasn't run for this
/// date), fall back to the worker-presence registry's own audit trail:
/// `ambient.jsonl` `kind=gap_shipped` events, which every ship path emits
/// with a `session` field (see `src/execute_gap.rs`'s
/// `# scanner-anchor: "kind":"gap_shipped"`). This is the same source
/// `chump_coord::presence::ships_today_counts` reads for "today", generalized
/// to an arbitrary date so `--date YYYY-MM-DD` also gets real data instead of
/// silently reporting nothing. `gap_failed` events are detector-emitted and
/// carry no session attribution today, so `fails` stays 0 in this fallback —
/// real, just incomplete, rather than fabricated.
fn build_agent_throughput_section_from_ambient(
    repo_root: &Path,
    date: &str,
) -> AgentThroughputSection {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let Ok(contents) = std::fs::read_to_string(&ambient_path) else {
        return AgentThroughputSection::default();
    };

    let mut ships_by_session: std::collections::BTreeMap<String, u64> =
        std::collections::BTreeMap::new();
    for line in contents.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if v.get("kind").and_then(|k| k.as_str()) != Some("gap_shipped") {
            continue;
        }
        let Some(ts) = v.get("ts").and_then(|t| t.as_str()) else {
            continue;
        };
        if !ts.starts_with(date) {
            continue;
        }
        let Some(session) = v.get("session").and_then(|s| s.as_str()) else {
            continue;
        };
        *ships_by_session.entry(session.to_string()).or_insert(0) += 1;
    }

    if ships_by_session.is_empty() {
        return AgentThroughputSection::default();
    }

    let total_ships: u64 = ships_by_session.values().sum();
    let rows = ships_by_session
        .into_iter()
        .map(|(agent_id, ships)| AgentThroughputRow {
            agent_id,
            ships,
            fails: 0,
            p50_minutes_per_ship: None,
            top_fail_modes: vec![],
        })
        .collect();

    AgentThroughputSection {
        date: date.to_string(),
        rows,
        total_ships,
        total_fails: 0,
    }
}

/// Read agent throughput from .chump/metrics/agent-throughput-DATE.json,
/// falling back to the ambient `gap_shipped` audit trail (CREDIBLE-099
/// AC-4/AC-7) when no tracker snapshot exists for the date.
pub fn build_agent_throughput_section(
    repo_root: &Path,
    date_str: Option<&str>,
) -> AgentThroughputSection {
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let date = date_str.unwrap_or(today.as_str());
    let metrics_path = repo_root
        .join(".chump/metrics")
        .join(format!("agent-throughput-{date}.json"));
    let content = match std::fs::read_to_string(&metrics_path) {
        Ok(c) => c,
        Err(_) => return build_agent_throughput_section_from_ambient(repo_root, date),
    };
    let json: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return build_agent_throughput_section_from_ambient(repo_root, date),
    };
    let mut section = AgentThroughputSection {
        date: json
            .get("date")
            .and_then(|v| v.as_str())
            .unwrap_or(date)
            .to_string(),
        total_ships: json
            .get("total_ships")
            .and_then(|v| v.as_u64())
            .unwrap_or(0),
        total_fails: json
            .get("total_fails")
            .and_then(|v| v.as_u64())
            .unwrap_or(0),
        rows: vec![],
    };
    if let Some(agents) = json.get("agents").and_then(|v| v.as_array()) {
        for a in agents {
            section.rows.push(AgentThroughputRow {
                agent_id: a
                    .get("agent_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string(),
                ships: a.get("ships").and_then(|v| v.as_u64()).unwrap_or(0),
                fails: a.get("fails").and_then(|v| v.as_u64()).unwrap_or(0),
                p50_minutes_per_ship: a.get("P50_minutes_per_ship").and_then(|v| v.as_f64()),
                top_fail_modes: a
                    .get("top_fail_modes")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|m| m.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default(),
            });
        }
    }
    section
}

// ── Build functions ──────────────────────────────────────────────────────────

/// Build the full KPI report for the given repo.
pub fn build_full_report(repo_root: &Path, window_days: u64) -> KpiReport {
    KpiReport {
        ship_rate: build_ship_rate_section(repo_root),
        mission_history: build_mission_history_section(repo_root),
        cost_savings: build_cost_savings_section(repo_root, window_days),
        free_tier_savings: build_free_tier_savings_section(repo_root, window_days),
        leverage: build_leverage_section(repo_root),
        tokens_per_ship: build_report(repo_root, window_days),
        handoff_rate: build_handoff_rate_section(repo_root, window_days),
        green_first_try: build_green_first_try_section(repo_root),
        time_to_land: build_time_to_land_section(repo_root),
        gate_false_positive: build_gate_false_positive_section(repo_root),
        shell_invariant_writers: build_shell_invariant_writers_section(repo_root),
        shell_loc_by_month: build_shell_loc_by_month_section(repo_root),
        // CREDIBLE-1512: default 24h window for the embedded CI-pickup section.
        ci_pickup: crate::ci_pickup::build_ci_pickup_report(repo_root, 24),
        ci_census: build_ci_census_section(repo_root),
        admin_merges: crate::admin_merges::build_admin_merges_section(repo_root),
    }
}

/// Parse a `YYYY-MM-DD` close date (the TEXT `closed_date` the ship path writes)
/// to a unix timestamp at midnight UTC, dependency-free (days-from-civil). Lets
/// the ship gauge count closes recorded without the INTEGER `closed_at`
/// (CREDIBLE-1485/1486 — the split-brain where the writer sets `closed_date` but
/// the reader read `closed_at`).
fn parse_closed_date(s: &str) -> Option<i64> {
    let s = s.trim();
    if s.len() < 10 {
        return None;
    }
    let y: i64 = s.get(0..4)?.parse().ok()?;
    let m: i64 = s.get(5..7)?.parse().ok()?;
    let d: i64 = s.get(8..10)?.parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // Howard Hinnant's days_from_civil: days since 1970-01-01.
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400)
}

fn build_ship_rate_section(repo_root: &Path) -> ShipRateSection {
    let store = match chump_gap_store::GapStore::open(repo_root) {
        Ok(s) => s,
        Err(_) => return ShipRateSection::default(),
    };
    let done_gaps = match store.list(Some("done")) {
        Ok(v) => v,
        Err(_) => return ShipRateSection::default(),
    };
    let now = current_unix();

    // CREDIBLE-421: title-prefix tagging (`EFFECTIVE: ...`) is opt-in and most
    // gaps are titled `<DOMAIN>-<NUM>: ...` instead, so a title-only check
    // left 70% of 30d ships "untagged" even though the gap's `domain` field
    // already carries the pillar. Fall back to domain when the title has no
    // explicit prefix.
    let pillar_of = |title: &str, domain: &str| -> Option<&'static str> {
        let up = title.to_uppercase();
        if up.starts_with("EFFECTIVE:") {
            return Some("effective");
        } else if up.starts_with("CREDIBLE:") {
            return Some("credible");
        } else if up.starts_with("RESILIENT:") {
            return Some("resilient");
        } else if up.starts_with("ZERO-WASTE:") {
            return Some("zero_waste");
        }
        match domain.to_uppercase().as_str() {
            "EFFECTIVE" => Some("effective"),
            "CREDIBLE" => Some("credible"),
            "RESILIENT" => Some("resilient"),
            "ZERO-WASTE" | "ZERO_WASTE" | "ZEROWASTE" => Some("zero_waste"),
            _ => None,
        }
    };

    let mut windows = Vec::new();
    for (label, days) in [("1d", 1u64), ("7d", 7), ("30d", 30)] {
        let cutoff = now.saturating_sub(days * 86_400);
        let mut total = 0u64;
        let mut effective = 0;
        let mut credible = 0;
        let mut resilient = 0;
        let mut zero_waste = 0;
        let mut untagged = 0;

        for g in &done_gaps {
            // CREDIBLE-1485/1486: the ship path reliably sets closed_date (TEXT
            // YYYY-MM-DD) but historically NOT closed_at (INTEGER unix ts) — only
            // 4 of 2481 done gaps had closed_at vs 1731 with closed_date — so
            // reading closed_at alone undercounted ships ~10-40x (kpi said 3/1d
            // while git showed 30 closes/24h). Prefer closed_at; fall back to
            // parsing closed_date so the gauge counts every real close.
            if let Some(closed) = g.closed_at.or_else(|| parse_closed_date(&g.closed_date)) {
                if closed >= cutoff as i64 {
                    total += 1;
                    match pillar_of(&g.title, &g.domain) {
                        Some("effective") => effective += 1,
                        Some("credible") => credible += 1,
                        Some("resilient") => resilient += 1,
                        Some("zero_waste") => zero_waste += 1,
                        _ => untagged += 1,
                    }
                }
            }
        }

        windows.push(WindowShipCount {
            label: label.to_string(),
            total,
            effective,
            credible,
            resilient,
            zero_waste,
            untagged,
        });
    }

    ShipRateSection { windows }
}

fn build_mission_history_section(repo_root: &Path) -> MissionGradeHistorySection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let mut snapshots = Vec::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "mission_grade" {
            continue;
        }
        let ts = extract_field(line, "ts").unwrap_or_default();
        let extract_pillar = |pfx: &str, field: &str| -> u64 {
            let needle = format!(r#""{}":{{"#, pfx);
            let start = line.find(&needle);
            start
                .and_then(|s| {
                    let rest = &line[s..];
                    let f = format!(r#""{}":"#, field);
                    rest.find(&f).and_then(|p| {
                        let val_start = p + f.len();
                        let val_rest = &rest[val_start..];
                        let end = val_rest.find([',', '}']).unwrap_or(val_rest.len());
                        val_rest[..end].trim().parse().ok()
                    })
                })
                .unwrap_or(0)
        };
        snapshots.push(MissionGradeSnapshot {
            ts,
            effective_shipped: extract_pillar("effective", "count_shipped_24h"),
            credible_shipped: extract_pillar("credible", "count_shipped_24h"),
            resilient_shipped: extract_pillar("resilient", "count_shipped_24h"),
            zero_waste_shipped: extract_pillar("zero_waste", "count_shipped_24h"),
            total_pickable: {
                let ep = extract_pillar("effective", "count_pickable");
                let cp = extract_pillar("credible", "count_pickable");
                let rp = extract_pillar("resilient", "count_pickable");
                let zp = extract_pillar("zero_waste", "count_pickable");
                ep + cp + rp + zp
            },
            total_in_flight: {
                let ei = extract_pillar("effective", "count_in_flight");
                let ci = extract_pillar("credible", "count_in_flight");
                let ri = extract_pillar("resilient", "count_in_flight");
                let zi = extract_pillar("zero_waste", "count_in_flight");
                ei + ci + ri + zi
            },
        });
    }

    // Keep last 10, most recent first.
    snapshots.reverse();
    snapshots.truncate(10);

    MissionGradeHistorySection { snapshots }
}

fn build_cost_savings_section(repo_root: &Path, window_days: u64) -> CostSavingsSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let window_secs = window_days * 86_400;
    let now_unix = current_unix();
    let cutoff = now_unix.saturating_sub(window_secs);

    let mut actual_cost = 0.0_f64;
    let mut anthropic_cost = 0.0_f64;

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < cutoff {
            continue;
        }
        if kind != "session_end" && kind != "token_usage_partial" {
            continue;
        }
        let input = extract_int_field(line, "input_tokens").unwrap_or(0);
        let output = extract_int_field(line, "output_tokens").unwrap_or(0);
        let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);

        // Actual cost: use the model_id if present, else "unknown".
        let model = extract_field(line, "model_id").unwrap_or_default();
        let model_ref = if model.is_empty() { "unknown" } else { &model };
        actual_cost += cost_usd_from_tokens(model_ref, input, output, cache);

        // Anthropic-only cost: always use Sonnet rates ("unknown" → Sonnet).
        anthropic_cost += cost_usd_from_tokens("unknown", input, output, cache);
    }

    CostSavingsSection {
        actual_cost_usd: actual_cost,
        anthropic_only_cost_usd: anthropic_cost,
        window_days,
    }
}

fn build_leverage_section(repo_root: &Path) -> LeverageSection {
    let store = match chump_gap_store::GapStore::open(repo_root) {
        Ok(s) => s,
        Err(_) => return LeverageSection::default(),
    };
    let all_gaps = match store.list(None) {
        Ok(v) => v,
        Err(_) => return LeverageSection::default(),
    };

    let mut dep_count: BTreeMap<String, usize> = BTreeMap::new();
    for g in &all_gaps {
        if g.depends_on.is_empty() {
            continue;
        }
        for dep in g.depends_on.split(',') {
            let dep = dep.trim();
            if !dep.is_empty() {
                *dep_count.entry(dep.to_string()).or_insert(0) += 1;
            }
        }
    }

    // Also count how many gaps have a `depends_on` referencing another gap.
    // We already counted above. Now sort by count descending.
    let mut entries: Vec<LeverageEntry> = dep_count
        .into_iter()
        .map(|(gap_id, count)| LeverageEntry {
            gap_id,
            depended_by_count: count,
        })
        .collect();
    entries.sort_by_key(|b| std::cmp::Reverse(b.depended_by_count));
    entries.truncate(10);

    LeverageSection { entries }
}

/// Build the tokens-per-ship report by scanning `ambient.jsonl`.
pub fn build_report(repo_root: &Path, window_days: u64) -> TokensPerShipReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let window_secs = window_days * 86_400;
    let now_unix = current_unix();
    let cutoff = now_unix.saturating_sub(window_secs);

    let mut per_gap: BTreeMap<String, (u64, u64, u64)> = BTreeMap::new();
    let mut shipped_gaps: std::collections::HashSet<String> = std::collections::HashSet::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < cutoff {
            continue;
        }

        match kind.as_str() {
            "session_end" => {
                let gap_id = match extract_field(line, "gap_id") {
                    Some(g) => g,
                    None => continue,
                };
                let outcome = extract_field(line, "outcome").unwrap_or_default();
                let input = extract_int_field(line, "input_tokens").unwrap_or(0);
                let output = extract_int_field(line, "output_tokens").unwrap_or(0);
                let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);

                let entry = per_gap.entry(gap_id.clone()).or_insert((0, 0, 0));
                entry.0 += input;
                entry.1 += output;
                entry.2 += cache;

                if outcome == "shipped" {
                    shipped_gaps.insert(gap_id);
                }
            }
            "token_usage_partial" => {
                let gap_id = match extract_field(line, "gap_id") {
                    Some(g) => g,
                    None => continue,
                };
                let input = extract_int_field(line, "input_tokens").unwrap_or(0);
                let output = extract_int_field(line, "output_tokens").unwrap_or(0);
                let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
                let entry = per_gap.entry(gap_id).or_insert((0, 0, 0));
                entry.0 += input;
                entry.1 += output;
                entry.2 += cache;
            }
            _ => {}
        }
    }

    let mut ships: Vec<ShipTokens> = per_gap
        .into_iter()
        .filter(|(gap_id, _)| shipped_gaps.contains(gap_id))
        .map(|(gap_id, (input, output, cache))| {
            let cost = cost_usd_from_tokens("unknown", input, output, cache);
            ShipTokens {
                gap_id,
                input_tokens: input,
                output_tokens: output,
                cache_read_tokens: cache,
                total_tokens: input + output + cache,
                cost_usd: cost,
            }
        })
        .collect();

    let ship_count = ships.len();
    if ship_count == 0 {
        return TokensPerShipReport {
            window_days,
            ship_count: 0,
            p50_tokens: None,
            p90_tokens: None,
            max_tokens: None,
            p50_cost_usd: None,
            p90_cost_usd: None,
            max_cost_usd: None,
            top5: vec![],
        };
    }

    ships.sort_by_key(|s| s.total_tokens);

    let p50_tokens = percentile_u64(&ships, 50);
    let p90_tokens = percentile_u64(&ships, 90);
    let max_tokens = ships.last().map(|s| s.total_tokens);

    let p50_cost_usd = p50_tokens.map(|t| {
        ships
            .iter()
            .min_by_key(|s| {
                let d = s.total_tokens as i64 - t as i64;
                d.unsigned_abs()
            })
            .map(|s| s.cost_usd)
            .unwrap_or(0.0)
    });
    let p90_cost_usd = p90_tokens.map(|t| {
        ships
            .iter()
            .min_by_key(|s| {
                let d = s.total_tokens as i64 - t as i64;
                d.unsigned_abs()
            })
            .map(|s| s.cost_usd)
            .unwrap_or(0.0)
    });
    let max_cost_usd = ships.last().map(|s| s.cost_usd);

    ships.sort_by(|a, b| {
        b.cost_usd
            .partial_cmp(&a.cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let top5 = ships.into_iter().take(5).collect();

    TokensPerShipReport {
        window_days,
        ship_count,
        p50_tokens,
        p90_tokens,
        max_tokens,
        p50_cost_usd,
        p90_cost_usd,
        max_cost_usd,
        top5,
    }
}

fn percentile_u64(sorted: &[ShipTokens], pct: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (pct * sorted.len()).div_ceil(100);
    let idx = rank.saturating_sub(1).min(sorted.len() - 1);
    Some(sorted[idx].total_tokens)
}

// ── Helpers ─────────────────────────────────────────────────────────────────

pub(crate) fn current_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub(crate) fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
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
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32_045;
    let unix_epoch_jdn: i64 = 2_440_588;
    let days = (jdn - unix_epoch_jdn) as u64;
    Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
}

fn extract_field(line: &str, field: &str) -> Option<String> {
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

pub(crate) fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    extract_field(line, field)?.parse().ok()
}

pub(crate) fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

// ── FLEET-048: Gap impact ratings ────────────────────────────────────────────

/// One operator-rated gap.
#[derive(Debug, Clone)]
pub struct ImpactRatingEntry {
    pub gap_id: String,
    pub rating: u8,
    pub comment: String,
    pub ts: String,
    pub pr_number: Option<i64>,
}

/// Aggregated impact ratings section for `chump kpi report --impact`.
#[derive(Debug, Clone, Default)]
pub struct ImpactRatingSection {
    pub entries: Vec<ImpactRatingEntry>,
    pub fleet_avg: Option<f64>,
    pub total_ratings: usize,
    /// INFRA-1555: mean rating per domain class (e.g. "INFRA", "FLEET").
    /// Populated by `build_impact_section`; empty when no ratings exist.
    pub class_ratings: Vec<ClassRatingRow>,
}

/// One row in the "Gap rating by class" subsection (INFRA-1555).
#[derive(Debug, Clone)]
pub struct ClassRatingRow {
    pub class: String,
    pub mean: f64,
    pub count: usize,
    /// `true` when mean < 2.5 and count >= 2 — picker applies one-tier demotion.
    pub demoted: bool,
}

impl ImpactRatingSection {
    pub fn render_text(&self) -> String {
        if self.entries.is_empty() {
            return "## Gap Impact Ratings\n\nNo ratings recorded yet.\n\
                    Run: chump gap rate <ID> <1-5> [--comment \"text\"]\n\n"
                .to_string();
        }
        let avg_str = self
            .fleet_avg
            .map(|a| format!("{:.2}", a))
            .unwrap_or_else(|| "n/a".to_string());
        let mut out = format!(
            "## Gap Impact Ratings ({} rated, fleet avg {}/5)\n\n",
            self.total_ratings, avg_str
        );
        out.push_str(&format!(
            "{:<14} {:>6}  {}\n",
            "Gap ID", "Rating", "Comment"
        ));
        out.push_str(&format!("{:-<14} {:->6}  {:-<40}\n", "", "", ""));
        let mut sorted = self.entries.clone();
        sorted.sort_by(|a, b| b.rating.cmp(&a.rating).then(a.gap_id.cmp(&b.gap_id)));
        for e in &sorted {
            let comment = if e.comment.is_empty() {
                "(no comment)".to_string()
            } else if e.comment.len() > 60 {
                format!("{}…", &e.comment[..59])
            } else {
                e.comment.clone()
            };
            out.push_str(&format!("{:<14} {:>6}  {}\n", e.gap_id, e.rating, comment));
        }
        out.push('\n');

        // INFRA-1555: "Gap rating by class" subsection.
        if !self.class_ratings.is_empty() {
            out.push_str("### Gap rating by class\n\n");
            out.push_str(&format!(
                "{:<12} {:>6}  {:>6}  {}\n",
                "Class", "Mean", "Count", "Picker effect"
            ));
            out.push_str(&format!(
                "{:-<12} {:->6}  {:->6}  {:-<20}\n",
                "", "", "", ""
            ));
            let mut rows = self.class_ratings.clone();
            rows.sort_by(|a, b| a.class.cmp(&b.class));
            for row in &rows {
                let effect = if row.demoted {
                    "demoted 1 tier"
                } else {
                    "no change"
                };
                out.push_str(&format!(
                    "{:<12} {:>6.2}  {:>6}  {}\n",
                    row.class, row.mean, row.count, effect
                ));
            }
            out.push('\n');
        }

        out
    }

    pub fn render_json(&self) -> String {
        let avg_str = self
            .fleet_avg
            .map(|a| format!("{:.2}", a))
            .unwrap_or_else(|| "null".to_string());
        let avg_json = if avg_str == "null" {
            "null".to_string()
        } else {
            avg_str
        };
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                let pr = e
                    .pr_number
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "null".to_string());
                format!(
                    "{{\"gap_id\":\"{}\",\"rating\":{},\"comment\":\"{}\",\"ts\":\"{}\",\"pr_number\":{}}}",
                    json_escape(&e.gap_id),
                    e.rating,
                    json_escape(&e.comment),
                    json_escape(&e.ts),
                    pr
                )
            })
            .collect();
        // INFRA-1555: include class_ratings in JSON output.
        let class_json: Vec<String> = self
            .class_ratings
            .iter()
            .map(|r| {
                format!(
                    "{{\"class\":\"{}\",\"mean\":{:.2},\"count\":{},\"demoted\":{}}}",
                    json_escape(&r.class),
                    r.mean,
                    r.count,
                    r.demoted
                )
            })
            .collect();
        format!(
            "{{\"total_ratings\":{},\"fleet_avg\":{},\"entries\":[{}],\"class_ratings\":[{}]}}",
            self.total_ratings,
            avg_json,
            entries_json.join(","),
            class_json.join(",")
        )
    }
}

/// Build impact rating section by scanning ambient.jsonl for `gap_impact_rated` events.
/// INFRA-1555: also computes per-class (domain) mean ratings for the picker subsection.
pub fn build_impact_section(repo_root: &Path) -> ImpactRatingSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut entries: Vec<ImpactRatingEntry> = Vec::new();
    // INFRA-1555: accumulate (sum, count) per domain class for the subsection.
    let mut class_acc: std::collections::HashMap<String, (f64, usize)> =
        std::collections::HashMap::new();

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        if kind != "gap_impact_rated" {
            continue;
        }
        let gap_id = match extract_field(line, "gap_id") {
            Some(g) => g,
            None => continue,
        };
        let rating: u8 = match extract_int_field(line, "rating") {
            Some(r) if (1..=5).contains(&r) => r as u8,
            _ => continue,
        };
        let comment = extract_field(line, "comment").unwrap_or_default();
        let ts = extract_field(line, "ts").unwrap_or_default();
        let pr_number = extract_int_field(line, "pr_number").map(|n| n as i64);

        // Accumulate class stats (domain prefix of gap_id, e.g. "INFRA").
        let class = gap_id.split('-').next().unwrap_or("UNKNOWN").to_uppercase();
        let e = class_acc.entry(class).or_insert((0.0, 0));
        e.0 += rating as f64;
        e.1 += 1;

        entries.push(ImpactRatingEntry {
            gap_id,
            rating,
            comment,
            ts,
            pr_number,
        });
    }

    let total_ratings = entries.len();
    let fleet_avg = if total_ratings == 0 {
        None
    } else {
        let sum: u32 = entries.iter().map(|e| e.rating as u32).sum();
        Some(sum as f64 / total_ratings as f64)
    };

    // INFRA-1555: build class_ratings rows (demotion threshold mirrors atomic_claim).
    const LOW_THRESHOLD: f64 = 2.5;
    const MIN_SAMPLES: usize = 2;
    let mut class_ratings: Vec<ClassRatingRow> = class_acc
        .into_iter()
        .map(|(class, (sum, count))| {
            let mean = sum / count as f64;
            let demoted = count >= MIN_SAMPLES && mean < LOW_THRESHOLD;
            ClassRatingRow {
                class,
                mean,
                count,
                demoted,
            }
        })
        .collect();
    class_ratings.sort_by(|a, b| a.class.cmp(&b.class));

    ImpactRatingSection {
        entries,
        fleet_avg,
        total_ratings,
        class_ratings,
    }
}

// ── Debt Index — Crown Gauge + NBA (CREDIBLE-357) ───────────────────────────
//
// Maps the live gap registry (`.chump/state.db`) onto `debt_index::Capability`
// so the crown gauge (live_pct/debt/top-5 dormant-by-Crit) and the
// next_best_action candidate list are computed from real, current fleet
// state rather than a fixture. Priority maps to criticality (P0/P1 -> Crit,
// P2 -> Warn, else Info); status maps to liveness (done/shipped -> Complete,
// in_progress/claimed -> Running, else Pending — dormant); effort maps to
// `stages_short` (xs=1 .. xl=5, unknown effort defaults to 2) as the "how far
// behind" proxy since the registry doesn't track literal pipeline stages.
pub struct DebtIndexSection {
    pub gauge: crate::debt_index::CrownGauge,
    pub nba_text: String,
    pub nba_candidate_count: usize,
}

impl DebtIndexSection {
    pub fn render_text(&self) -> String {
        format!("{}\n{}", self.gauge.render_text(), self.nba_text)
    }

    pub fn render_json(&self) -> String {
        let top5 = self
            .gauge
            .top5_dormant_names
            .iter()
            .map(|n| format!("{:?}", n))
            .collect::<Vec<_>>()
            .join(",");
        format!(
            r#"{{"live_pct":{:.4},"debt":{:.2},"top5_dormant":[{}],"nba_candidate_count":{}}}"#,
            self.gauge.live_pct, self.gauge.debt, top5, self.nba_candidate_count,
        )
    }
}

fn gap_priority_to_criticality(priority: &str) -> crate::live_pct::Criticality {
    use crate::live_pct::Criticality;
    match priority {
        "P0" | "P1" => Criticality::Crit,
        "P2" => Criticality::Warn,
        _ => Criticality::Info,
    }
}

fn gap_status_to_stage_status(status: &str) -> crate::live_pct::StageStatus {
    use crate::live_pct::StageStatus;
    match status {
        "done" | "shipped" => StageStatus::Complete,
        "in_progress" | "claimed" | "running" => StageStatus::Running,
        _ => StageStatus::Pending,
    }
}

fn gap_effort_to_stages_short(effort: &str) -> u32 {
    match effort {
        "xs" => 1,
        "s" => 2,
        "m" => 3,
        "l" => 4,
        "xl" => 5,
        _ => 2,
    }
}

/// Build the crown-gauge + NBA section from the current gap registry.
pub fn build_debt_index_section(repo_root: &Path) -> DebtIndexSection {
    let capabilities: Vec<crate::debt_index::Capability> =
        match chump_gap_store::GapStore::open(repo_root) {
            Ok(store) => store
                .list(None)
                .unwrap_or_default()
                .into_iter()
                .map(|g| crate::debt_index::Capability {
                    name: format!("{} {}", g.id, g.title),
                    criticality: gap_priority_to_criticality(&g.priority),
                    status: gap_status_to_stage_status(&g.status),
                    stages_short: gap_effort_to_stages_short(&g.effort),
                })
                .collect(),
            Err(_) => Vec::new(),
        };

    let gauge = crate::debt_index::compute_crown_gauge(&capabilities);
    let nba_text = crate::debt_index::render_nba_candidates(&capabilities);
    let nba_candidate_count = crate::debt_index::next_best_action_candidates(&capabilities).len();

    DebtIndexSection {
        gauge,
        nba_text,
        nba_candidate_count,
    }
}

// ── Integration Cycle Dashboard (INFRA-2143) ────────────────────────────────
//
// Cross-references: INFRA-2132 (integration_cycle_* ambient events read here),
// INFRA-2137 (bisect_quarantined status + `bisect_quarantine` event), INFRA-2142
// (SLO thresholds shown alongside each metric), DOC-063 (the CI-bottleneck
// review this dashboard measures success against).
//
// Data sources:
//   - ambient.jsonl: integration_cycle_started/completed/shipped/failed/
//     dry_run_completed, integration_preflight_started/failed, bisect_quarantine,
//     graphql_exhausted, ci_flake_rerun (all within the requested window).
//   - GitHub Actions API (best-effort, `gh` CLI): CI-runs-per-shipped-gap. When
//     `gh` is unavailable/unauthenticated (e.g. in tests, or an offline
//     checkout) the section renders "—" for that one metric rather than
//     failing the whole report — every other metric is ambient-only and does
//     not depend on network access.

/// One resolved integration cycle: its `cycle_id`, start time, and (if it
/// reached a terminal state within the window) end time.
#[derive(Debug, Clone, Default)]
struct CycleSpan {
    started_at: Option<u64>,
    ended_at: Option<u64>,
    shipped_gap_count: Option<u64>,
    shipped: bool,
    preflight_failed: bool,
}

/// `chump kpi report --integration` dashboard section.
#[derive(Debug, Clone, Default)]
pub struct IntegrationCycleSection {
    pub window_days: f64,
    pub cycles_started: u64,
    pub cycles_shipped: u64,
    pub gaps_shipped: u64,
    pub p50_wall_minutes: Option<f64>,
    pub p95_wall_minutes: Option<f64>,
    pub ci_runs_per_shipped_gap: Option<f64>,
    pub runner_peak_util_pct: Option<f64>,
    pub wall_time_saved_hours: f64,
    pub quarantined_count: u64,
    pub bisect_quarantine_rate_pct: f64,
    pub cycles_zero_fail: u64,
    pub rerun_cycles: u64,
    pub graphql_exhaustion_per_day: f64,
    pub operator_flake_rerun_per_day: f64,
}

impl IntegrationCycleSection {
    pub fn mean_gaps_per_cycle(&self) -> f64 {
        if self.cycles_shipped == 0 {
            0.0
        } else {
            self.gaps_shipped as f64 / self.cycles_shipped as f64
        }
    }

    pub fn cycles_zero_fail_pct(&self) -> f64 {
        if self.cycles_started == 0 {
            0.0
        } else {
            self.cycles_zero_fail as f64 / self.cycles_started as f64 * 100.0
        }
    }

    pub fn render_text(&self) -> String {
        let fmt_min = |v: Option<f64>| {
            v.map(|m| format!("{m:.1} min"))
                .unwrap_or_else(|| "—".to_string())
        };
        let fmt_pct = |v: Option<f64>| {
            v.map(|p| format!("{p:.0}%"))
                .unwrap_or_else(|| "—".to_string())
        };
        let fmt_ratio = |v: Option<f64>| {
            v.map(|r| format!("{r:.2}"))
                .unwrap_or_else(|| "—".to_string())
        };
        let mut out = String::new();
        out.push_str(&format!(
            "═══ Integration Cycle Dashboard (last {}d) ═══\n\n",
            self.window_days
        ));
        out.push_str("SHIP VELOCITY\n");
        out.push_str(&format!(
            "  Cycles shipped:        {}\n",
            self.cycles_shipped
        ));
        out.push_str(&format!("  Gaps shipped:          {}\n", self.gaps_shipped));
        out.push_str(&format!(
            "  Mean gaps per cycle:   {:.2}\n",
            self.mean_gaps_per_cycle()
        ));
        out.push_str(&format!(
            "  P50 cycle wall time:   {}\n",
            fmt_min(self.p50_wall_minutes)
        ));
        out.push_str(&format!(
            "  P95 cycle wall time:   {}\n\n",
            fmt_min(self.p95_wall_minutes)
        ));
        out.push_str("EFFICIENCY VS PER-PR BASELINE\n");
        out.push_str(&format!(
            "  CI runs / shipped gap: {}  (target: < 0.15)\n",
            fmt_ratio(self.ci_runs_per_shipped_gap)
        ));
        out.push_str(&format!(
            "  Runner peak util:      {}   (target: < 50%)\n",
            fmt_pct(self.runner_peak_util_pct)
        ));
        out.push_str(&format!(
            "  Wall time saved est:   {:.1} hours (vs hypothetical per-PR baseline)\n\n",
            self.wall_time_saved_hours
        ));
        out.push_str("QUALITY\n");
        out.push_str(&format!(
            "  Bisect-quarantine rate: {:.1}%  (target: < 5%)\n",
            self.bisect_quarantine_rate_pct
        ));
        out.push_str(&format!(
            "  Cycles with 0 fails:    {}/{} ({:.0}%)\n",
            self.cycles_zero_fail,
            self.cycles_started,
            self.cycles_zero_fail_pct()
        ));
        out.push_str(&format!(
            "  Rerun cycles:           {}\n\n",
            self.rerun_cycles
        ));
        out.push_str("EXTERNAL COSTS\n");
        out.push_str(&format!(
            "  GraphQL exhaustion / day:  {:.1}  (target: < 0.5)\n",
            self.graphql_exhaustion_per_day
        ));
        out.push_str(&format!(
            "  Operator flake-rerun interventions / day: {:.1} (target: < 1)\n",
            self.operator_flake_rerun_per_day
        ));
        out
    }

    pub fn render_json(&self) -> String {
        let opt_f64 = |v: Option<f64>| {
            v.map(|n| n.to_string())
                .unwrap_or_else(|| "null".to_string())
        };
        format!(
            r#"{{"window_days":{},"cycles_started":{},"cycles_shipped":{},"gaps_shipped":{},"mean_gaps_per_cycle":{:.2},"p50_wall_minutes":{},"p95_wall_minutes":{},"ci_runs_per_shipped_gap":{},"runner_peak_util_pct":{},"wall_time_saved_hours":{:.2},"quarantined_count":{},"bisect_quarantine_rate_pct":{:.1},"cycles_zero_fail":{},"cycles_zero_fail_pct":{:.1},"rerun_cycles":{},"graphql_exhaustion_per_day":{:.2},"operator_flake_rerun_per_day":{:.2}}}"#,
            self.window_days,
            self.cycles_started,
            self.cycles_shipped,
            self.gaps_shipped,
            self.mean_gaps_per_cycle(),
            opt_f64(self.p50_wall_minutes),
            opt_f64(self.p95_wall_minutes),
            opt_f64(self.ci_runs_per_shipped_gap),
            opt_f64(self.runner_peak_util_pct),
            self.wall_time_saved_hours,
            self.quarantined_count,
            self.bisect_quarantine_rate_pct,
            self.cycles_zero_fail,
            self.cycles_zero_fail_pct(),
            self.rerun_cycles,
            self.graphql_exhaustion_per_day,
            self.operator_flake_rerun_per_day,
        )
    }
}

fn percentile_f64(sorted: &[f64], pct: usize) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (pct * sorted.len()).div_ceil(100);
    let idx = rank.saturating_sub(1).min(sorted.len() - 1);
    Some(sorted[idx])
}

/// Build the integration-cycle dashboard by scanning `ambient.jsonl` for the
/// last `window_hours` hours. `window_hours` of 168 == 7d (the default),
/// 720 == 30d.
pub fn build_integration_cycle_section(
    repo_root: &Path,
    window_hours: u64,
) -> IntegrationCycleSection {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let cutoff = current_unix().saturating_sub(window_hours * 3600);

    let mut cycles: BTreeMap<String, CycleSpan> = BTreeMap::new();
    let mut quarantined_count: u64 = 0;
    let mut graphql_exhausted_count: u64 = 0;
    let mut ci_flake_rerun_count: u64 = 0;

    for line in contents.lines() {
        let kind = extract_field(line, "kind").unwrap_or_default();
        let ts_unix = extract_field(line, "ts").and_then(|t| parse_iso8601_to_unix(&t));
        let in_window = ts_unix.map(|t| t >= cutoff).unwrap_or(false);
        if !in_window {
            continue;
        }

        match kind.as_str() {
            "integration_cycle_started" => {
                if let Some(cid) = extract_field(line, "cycle_id") {
                    cycles.entry(cid).or_default().started_at = ts_unix;
                }
            }
            "integration_cycle_shipped" => {
                if let Some(cid) = extract_field(line, "cycle_id") {
                    let span = cycles.entry(cid).or_default();
                    span.ended_at = ts_unix;
                    span.shipped = true;
                    span.shipped_gap_count = extract_int_field(line, "gap_count");
                }
            }
            "integration_cycle_failed" | "integration_cycle_dry_run_completed" => {
                if let Some(cid) = extract_field(line, "cycle_id") {
                    let span = cycles.entry(cid).or_default();
                    if span.ended_at.is_none() {
                        span.ended_at = ts_unix;
                    }
                }
            }
            "integration_preflight_failed" => {
                if let Some(cid) = extract_field(line, "cycle_id") {
                    cycles.entry(cid).or_default().preflight_failed = true;
                }
            }
            "bisect_quarantine" => {
                quarantined_count += 1;
            }
            "graphql_exhausted" => {
                graphql_exhausted_count += 1;
            }
            "ci_flake_rerun" => {
                ci_flake_rerun_count += 1;
            }
            _ => {}
        }
    }

    let cycles_started = cycles.values().filter(|c| c.started_at.is_some()).count() as u64;
    let shipped_spans: Vec<&CycleSpan> = cycles.values().filter(|c| c.shipped).collect();
    let cycles_shipped = shipped_spans.len() as u64;
    let gaps_shipped: u64 = shipped_spans
        .iter()
        .filter_map(|c| c.shipped_gap_count)
        .sum();
    let rerun_cycles = cycles.values().filter(|c| c.preflight_failed).count() as u64;
    let cycles_zero_fail = cycles
        .values()
        .filter(|c| c.started_at.is_some() && !c.preflight_failed)
        .count() as u64;

    let mut wall_minutes: Vec<f64> = cycles
        .values()
        .filter_map(|c| match (c.started_at, c.ended_at) {
            (Some(s), Some(e)) if e >= s => Some((e - s) as f64 / 60.0),
            _ => None,
        })
        .collect();
    wall_minutes.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p50_wall_minutes = percentile_f64(&wall_minutes, 50);
    let p95_wall_minutes = percentile_f64(&wall_minutes, 95);

    let total_candidates = gaps_shipped + quarantined_count;
    let bisect_quarantine_rate_pct = if total_candidates == 0 {
        0.0
    } else {
        quarantined_count as f64 / total_candidates as f64 * 100.0
    };

    // Wall-time-saved heuristic: gaps that rode along in a shared cycle instead
    // of paying for a dedicated per-PR CI cycle each. Baseline = one cycle's
    // worth of wall time per gap; actual = one cycle's worth per cycle shipped.
    let avg_wall_minutes = if wall_minutes.is_empty() {
        0.0
    } else {
        wall_minutes.iter().sum::<f64>() / wall_minutes.len() as f64
    };
    let wall_time_saved_hours = if cycles_shipped == 0 || gaps_shipped <= cycles_shipped {
        0.0
    } else {
        (gaps_shipped - cycles_shipped) as f64 * avg_wall_minutes / 60.0
    };

    let window_days = window_hours as f64 / 24.0;
    let graphql_exhaustion_per_day = graphql_exhausted_count as f64 / window_days.max(1.0 / 24.0);
    let operator_flake_rerun_per_day = ci_flake_rerun_count as f64 / window_days.max(1.0 / 24.0);

    let (ci_runs_per_shipped_gap, runner_peak_util_pct) =
        fetch_gh_actions_metrics(repo_root, window_hours, gaps_shipped);

    IntegrationCycleSection {
        window_days,
        cycles_started,
        cycles_shipped,
        gaps_shipped,
        p50_wall_minutes,
        p95_wall_minutes,
        ci_runs_per_shipped_gap,
        runner_peak_util_pct,
        wall_time_saved_hours,
        quarantined_count,
        bisect_quarantine_rate_pct,
        cycles_zero_fail,
        rerun_cycles,
        graphql_exhaustion_per_day,
        operator_flake_rerun_per_day,
    }
}

/// Best-effort GitHub Actions run count via the `gh` CLI. Returns
/// `(ci_runs_per_shipped_gap, runner_peak_util_pct)`, both `None` when `gh`
/// is missing/unauthenticated, the repo has no `origin` remote, or the API
/// call otherwise fails — callers render `None` as "—" rather than treating
/// it as an error. Runner peak util is a point-in-time snapshot of
/// in-progress runs (true peak-over-window tracking is a follow-up: it needs
/// a sampling daemon, not a single report-time API call).
fn fetch_gh_actions_metrics(
    repo_root: &Path,
    window_hours: u64,
    gaps_shipped: u64,
) -> (Option<f64>, Option<f64>) {
    if gaps_shipped == 0 {
        return (None, None);
    }
    let Some((owner, repo)) = resolve_repo_slug(repo_root) else {
        return (None, None);
    };
    let since = current_unix().saturating_sub(window_hours * 3600);
    let since_iso = unix_to_iso8601(since);

    let runs_out = std::process::Command::new("gh")
        .args([
            "api",
            &format!("repos/{owner}/{repo}/actions/runs?per_page=100&created=>={since_iso}"),
            "-q",
            ".total_count",
        ])
        .output();
    let ci_runs_per_shipped_gap = match runs_out {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse::<u64>()
            .ok()
            .map(|n| n as f64 / gaps_shipped as f64),
        _ => None,
    };

    let inflight_out = std::process::Command::new("gh")
        .args([
            "api",
            &format!("repos/{owner}/{repo}/actions/runs?status=in_progress&per_page=100"),
            "-q",
            ".total_count",
        ])
        .output();
    // CHUMP_RUNNER_POOL_SIZE: number of self-hosted runners in the pool, used
    // to turn an in-flight-run count into a utilization percentage.
    let pool_size: f64 = std::env::var("CHUMP_RUNNER_POOL_SIZE")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(4.0)
        .max(1.0);
    let runner_peak_util_pct = match inflight_out {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse::<u64>()
            .ok()
            .map(|n| (n as f64 / pool_size * 100.0).min(100.0)),
        _ => None,
    };

    (ci_runs_per_shipped_gap, runner_peak_util_pct)
}

/// Resolve `OWNER/REPO` from `git remote get-url origin`. Falls back to
/// `CHUMP_INVENTORY_REPO` (form: "owner/repo") for tests — same env var
/// `chump-inventory::resolve_repo_slug` uses, so a single override works
/// fleet-wide.
fn resolve_repo_slug(root: &Path) -> Option<(String, String)> {
    if let Ok(slug) = std::env::var("CHUMP_INVENTORY_REPO") {
        let parts: Vec<&str> = slug.split('/').collect();
        if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() {
            return Some((parts[0].to_string(), parts[1].to_string()));
        }
    }
    let out = std::process::Command::new("git")
        .args(["remote", "get-url", "origin"])
        .current_dir(root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stripped = url
        .trim_end_matches(".git")
        .trim_end_matches('/')
        .to_string();
    let idx = stripped.find("github.com")?;
    let after = &stripped[idx + "github.com".len()..];
    let tail = after.trim_start_matches(':').trim_start_matches('/');
    let parts: Vec<&str> = tail.split('/').collect();
    if parts.len() >= 2 && !parts[0].is_empty() && !parts[1].is_empty() {
        Some((parts[0].to_string(), parts[1].to_string()))
    } else {
        None
    }
}

fn unix_to_iso8601(ts: u64) -> String {
    let days = ts / 86_400;
    let rem = ts % 86_400;
    let hour = rem / 3600;
    let min = (rem % 3600) / 60;
    let sec = rem % 60;
    let jdn = days as i64 + 2_440_588;
    let a = jdn + 32_044;
    let b = (4 * a + 3) / 146_097;
    let c = a - (146_097 * b) / 4;
    let d = (4 * c + 3) / 1461;
    let e = c - (1461 * d) / 4;
    let m = (5 * e + 2) / 153;
    let day = e - (153 * m + 2) / 5 + 1;
    let month = m + 3 - 12 * (m / 10);
    let year = 100 * b + d - 4800 + m / 10;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}Z")
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// EFFECTIVE-418: fixture pricing fn injected in place of the bin's
    /// `session_ledger::cost_usd_from_tokens`. Reproduces the exact rates the
    /// real function returns for the models these tests exercise, so the
    /// cost-asserting cases (`infra640_dollar_math`, `infra617_*`) stay real:
    ///   - `together-deepseek-v3`: $0.85 / $0.85 / $0.00 per MTok
    ///   - anything else (incl. "unknown" → Sonnet fallback): $3 / $15 / $0.30
    fn fixture_price(model_id: &str, input: u64, output: u64, cache_read: u64) -> f64 {
        let (i, o, c) = if model_id == "together-deepseek-v3" {
            (0.85_f64, 0.85_f64, 0.0_f64)
        } else {
            (3.00_f64, 15.00_f64, 0.30_f64)
        };
        (input as f64 * i + output as f64 * o + cache_read as f64 * c) / 1_000_000.0
    }

    /// Register the fixture pricing fn. Idempotent (OnceLock, first-writer-wins);
    /// safe to call from every cost-asserting test regardless of run order.
    fn ensure_pricing() {
        set_cost_fn(fixture_price);
    }

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra617-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    /// Create a minimal git repo + .chump/state.db with synthetic done gaps.
    /// `entries`: (title, closed_unix_ts). IDs are auto-generated (INFRA-NNN).
    /// Uses raw SQL because set_fields doesn't update the `closed_at` column
    /// (only `closed_date`), but the gap store's `list()` method reads `closed_at`.
    fn seed_gap_store(dir: &Path, entries: &[(&str, i64)]) {
        let chump_dir = dir.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();

        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(dir)
            .output();

        let store = chump_gap_store::GapStore::open(dir).unwrap();
        for (title, closed_ts) in entries {
            let reserved = store.reserve("INFRA", title, "P1", "s").unwrap();
            store
                .ship_for_test_with_opts(&reserved, Some(*closed_ts), Some(999))
                .unwrap();
        }
    }

    fn seed_gap_store_with_domain(dir: &Path, entries: &[(&str, &str, i64)]) {
        let chump_dir = dir.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();

        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(dir)
            .output();

        let store = chump_gap_store::GapStore::open(dir).unwrap();
        for (domain, title, closed_ts) in entries {
            let reserved = store.reserve(domain, title, "P1", "s").unwrap();
            store
                .ship_for_test_with_opts(&reserved, Some(*closed_ts), Some(999))
                .unwrap();
        }
    }

    fn unix_to_iso_date(ts: i64) -> String {
        let d = (ts / 86_400) + 2_440_588;
        let f = d + 1401 + ((((4 * d + 274_277) / 146_097) * 3) / 4) - 38;
        let e = 4 * f + 3;
        let g = (e % 1461) / 4;
        let h = 5 * g + 2;
        let day = (h % 153) / 5 + 1;
        let month = (h / 153 + 2) % 12 + 1;
        let year = e / 1461 - 4716 + (14 - month) / 12;
        format!("{:04}-{:02}-{:02}", year, month, day)
    }

    fn write_ambient(dir: &Path, lines: &[&str]) {
        let locks = dir.join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        for line in lines {
            writeln!(f, "{}", line).unwrap();
        }
    }

    fn fixture_ts() -> String {
        let ts = current_unix() - 2 * 86_400;
        let d = ts / 86_400;
        let j = d as i64 + 2_440_588;
        let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
        let e = 4 * f + 3;
        let g = (e % 1461) / 4;
        let h = 5 * g + 2;
        let day = (h % 153) / 5 + 1;
        let month = (h / 153 + 2) % 12 + 1;
        let year = e / 1461 - 4716 + (14 - month) / 12;
        let hh = (ts % 86_400) / 3600;
        let mm = (ts % 3600) / 60;
        let ss = ts % 60;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            year, month, day, hh, mm, ss
        )
    }

    // ── INFRA-640 tests (unchanged) ────────────────────────────────────────

    #[test]
    fn infra640_empty_window_returns_zero_ships() {
        let tmp = tempdir();
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 0);
        assert!(report.p50_tokens.is_none());
        assert!(report.top5.is_empty());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_only_shipped_gaps_counted() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-1","outcome":"shipped","elapsed_seconds":300,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":500}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s2","gap_id":"TEST-2","outcome":"abandoned","elapsed_seconds":100,"input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1, "only shipped gaps counted");
        assert_eq!(report.top5.len(), 1);
        assert_eq!(report.top5[0].gap_id, "TEST-1");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_percentiles_and_top5() {
        ensure_pricing(); // top5 sorts by cost_usd; without pricing (nextest isolates
                          // each test in its own process) all costs are 0 and the ordering breaks.
        let tmp = tempdir();
        let ts = fixture_ts();
        let lines: Vec<String> = (1..=5u64)
            .map(|i| {
                format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s{i}","gap_id":"TEST-{i}","outcome":"shipped","elapsed_seconds":60,"input_tokens":{tok},"output_tokens":0,"cache_read_tokens":0}}"#,
                    tok = i * 1000
                )
            })
            .collect();
        let lines_ref: Vec<&str> = lines.iter().map(String::as_str).collect();
        write_ambient(&tmp, &lines_ref);
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 5);
        assert_eq!(report.p50_tokens, Some(3000));
        assert_eq!(report.p90_tokens, Some(5000));
        assert_eq!(report.max_tokens, Some(5000));
        assert_eq!(report.top5[0].gap_id, "TEST-5");
        assert_eq!(report.top5.len(), 5);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_token_usage_partial_accumulated() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"kind":"token_usage_partial","ts":"{ts}","session_id":"s1","gap_id":"TEST-10","input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-10","outcome":"shipped","elapsed_seconds":300,"input_tokens":3000,"output_tokens":500,"cache_read_tokens":200}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1);
        let ship = &report.top5[0];
        assert_eq!(ship.input_tokens, 8000);
        assert_eq!(ship.output_tokens, 1500);
        assert_eq!(ship.cache_read_tokens, 200);
        assert_eq!(ship.total_tokens, 9700);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_window_filters_old_events() {
        let tmp = tempdir();
        let old_ts = {
            let ts = current_unix() - 10 * 86_400;
            let d = ts / 86_400;
            let j = d as i64 + 2_440_588;
            let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
            let e = 4 * f + 3;
            let g = (e % 1461) / 4;
            let h = 5 * g + 2;
            let day = (h % 153) / 5 + 1;
            let month = (h / 153 + 2) % 12 + 1;
            let year = e / 1461 - 4716 + (14 - month) / 12;
            let hh = (ts % 86_400) / 3600;
            let mm = (ts % 3600) / 60;
            let ss = ts % 60;
            format!(
                "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
                year, month, day, hh, mm, ss
            )
        };
        let recent_ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"kind":"session_end","ts":"{old_ts}","session_id":"s-old","gap_id":"TEST-99","outcome":"shipped","elapsed_seconds":60,"input_tokens":9000,"output_tokens":0,"cache_read_tokens":0}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{recent_ts}","session_id":"s-new","gap_id":"TEST-100","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":0,"cache_read_tokens":0}}"#
                ),
            ],
        );
        let report = build_report(&tmp, 7);
        assert_eq!(report.ship_count, 1, "old event filtered by window");
        assert_eq!(report.top5[0].gap_id, "TEST-100");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_dollar_math() {
        ensure_pricing();
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-200","outcome":"shipped","elapsed_seconds":60,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":0}}"#
            )],
        );
        let report = build_report(&tmp, 7);
        let expected = 0.060_f64;
        let got = report.max_cost_usd.unwrap_or(0.0);
        assert!(
            (got - expected).abs() < 1e-9,
            "expected ${:.4} got ${:.4}",
            expected,
            got
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_render_text_contains_key_fields() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-300","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":500,"cache_read_tokens":0}}"#
            )],
        );
        let report = build_report(&tmp, 7);
        let text = report.render_text();
        assert!(text.contains("Ships analysed: 1"));
        assert!(text.contains("TEST-300"));
        assert!(text.contains("P50"));
        assert!(text.contains("P90"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra640_render_json_valid_structure() {
        let tmp = tempdir();
        let report = build_report(&tmp, 7);
        let json = report.render_json();
        assert!(json.contains(r#""window_days":7"#));
        assert!(json.contains(r#""ship_count":0"#));
        assert!(json.contains(r#""top5":[]"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── INFRA-617 new tests ────────────────────────────────────────────────

    #[test]
    fn infra617_ship_rate_returns_windows() {
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store(&tmp, &[("EFFECTIVE: ship faster", now)]);
        let section = build_ship_rate_section(&tmp);
        assert_eq!(section.windows.len(), 3);
        assert!(
            section.windows[0].total >= 1,
            "1d window should have at least 1"
        );
        assert_eq!(section.windows[0].effective, 1);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1485_ship_rate_counts_closed_date_without_closed_at() {
        // The split-brain: the ship path writes closed_date (TEXT) but historically
        // NOT closed_at (INTEGER), so a gauge reading closed_at alone undercounted
        // ~10-40x. Seed a done gap with closed_date=today and closed_at=NULL — the
        // real-world shape — and assert the 1d window counts it.
        let tmp = tempdir();
        std::fs::create_dir_all(tmp.join(".chump")).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(&tmp)
            .output();
        let reserved = {
            let store = chump_gap_store::GapStore::open(&tmp).unwrap();
            let id = store
                .reserve("INFRA", "closed_date only", "P1", "s")
                .unwrap();
            let today = unix_to_iso_date(current_unix() as i64);
            store
                .ship_for_test_null_closed_at(&id, &today, 999)
                .unwrap();
            id
        };
        let _ = reserved;
        let section = build_ship_rate_section(&tmp);
        assert!(
            section.windows[0].total >= 1,
            "1d window must count a gap closed with closed_date but no closed_at (CREDIBLE-1485): {:?}",
            section.windows[0]
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1485_parse_closed_date() {
        assert_eq!(parse_closed_date("1970-01-01"), Some(0));
        assert_eq!(parse_closed_date("1970-01-02"), Some(86_400));
        let t = parse_closed_date("2026-10-01").unwrap();
        assert!(
            t > 1_700_000_000 && t % 86_400 == 0,
            "midnight-aligned, got {t}"
        );
        assert_eq!(parse_closed_date(""), None);
        assert_eq!(parse_closed_date("2026-13-01"), None);
        assert_eq!(parse_closed_date("not-a-date"), None);
    }

    #[test]
    fn infra617_ship_rate_pillar_classification() {
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store(
            &tmp,
            &[
                ("EFFECTIVE: speed up", now),
                ("CREDIBLE: add scorecard", now),
                ("RESILIENT: watchdog", now),
                ("ZERO-WASTE: trim", now),
                ("untagged work", now),
            ],
        );
        let section = build_ship_rate_section(&tmp);
        assert!(section.windows[0].effective >= 1, "effective pillar");
        assert!(section.windows[0].credible >= 1, "credible pillar");
        assert!(section.windows[0].resilient >= 1, "resilient pillar");
        assert!(section.windows[0].zero_waste >= 1, "zero_waste pillar");
        assert!(section.windows[0].untagged >= 1, "untagged");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible421_ship_rate_pillar_classification_falls_back_to_domain() {
        // CREDIBLE-421: most gaps are titled "<DOMAIN>-<NUM>: ..." rather than
        // an explicit "EFFECTIVE: ..." prefix, so the domain field must also
        // classify a ship into its pillar instead of leaving it untagged.
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store_with_domain(
            &tmp,
            &[
                ("EFFECTIVE", "EFFECTIVE-1: speed up", now),
                ("CREDIBLE", "CREDIBLE-2: add scorecard", now),
                ("RESILIENT", "RESILIENT-3: watchdog", now),
                ("ZERO-WASTE", "ZERO-WASTE-4: trim", now),
                ("INFRA", "INFRA-5: unrelated plumbing", now),
            ],
        );
        let section = build_ship_rate_section(&tmp);
        assert_eq!(section.windows[0].effective, 1, "effective via domain");
        assert_eq!(section.windows[0].credible, 1, "credible via domain");
        assert_eq!(section.windows[0].resilient, 1, "resilient via domain");
        assert_eq!(section.windows[0].zero_waste, 1, "zero_waste via domain");
        assert_eq!(section.windows[0].untagged, 1, "only INFRA stays untagged");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_mission_history_parses_ambient() {
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"ts":"{ts}","kind":"mission_grade","effective":{{"count_pickable":5,"count_in_flight":2,"count_shipped_24h":1}},"credible":{{"count_pickable":3,"count_in_flight":1,"count_shipped_24h":0}},"resilient":{{"count_pickable":2,"count_in_flight":0,"count_shipped_24h":0}},"zero_waste":{{"count_pickable":1,"count_in_flight":0,"count_shipped_24h":0}}}}"#
            )],
        );
        let section = build_mission_history_section(&tmp);
        assert_eq!(section.snapshots.len(), 1);
        assert_eq!(section.snapshots[0].effective_shipped, 1);
        assert_eq!(section.snapshots[0].credible_shipped, 0);
        assert_eq!(section.snapshots[0].total_pickable, 11);
        assert_eq!(section.snapshots[0].total_in_flight, 3);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn mission066_binary_section_empty_without_history() {
        let tmp = tempdir();
        let section = build_mission_binary_section(&tmp);
        assert!(section.checks.is_empty());
        assert_eq!(section.current_streak, 0);
        assert_eq!(section.longest_streak, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn mission066_binary_section_computes_current_and_longest_streak() {
        let tmp = tempdir();
        // Oldest-first in the log: NO, YES, YES, YES, NO, YES.
        // Longest run of YES = 3 (runs 2-4). Current streak (most recent run
        // back until a NO) = 1 (just the final YES).
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2026-08-01T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":1,"beast_zero_touch_7d":0}"#,
                r#"{"ts":"2026-08-02T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":1,"beast_zero_touch_7d":1}"#,
                r#"{"ts":"2026-08-03T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":2,"beast_zero_touch_7d":2}"#,
                r#"{"ts":"2026-08-04T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":2,"beast_zero_touch_7d":1}"#,
                r#"{"ts":"2026-08-05T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":1,"beast_zero_touch_7d":0}"#,
                r#"{"ts":"2026-08-06T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":1,"beast_zero_touch_7d":1}"#,
            ],
        );
        let section = build_mission_binary_section(&tmp);
        assert_eq!(section.checks.len(), 6);
        // Most-recent-first: the newest entry (08-06, YES) is checks[0].
        assert_eq!(section.checks[0].ts, "2026-08-06T00:00:00Z");
        assert!(section.checks[0].is_yes());
        assert_eq!(section.current_streak, 1);
        assert_eq!(section.longest_streak, 3);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn mission066_binary_section_all_yes_streak_equals_history_len() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2026-08-01T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":1,"beast_zero_touch_7d":1}"#,
                r#"{"ts":"2026-08-02T00:00:00Z","kind":"mission_binary_check","repo":"repairman29/BEAST-MODE","beast_merges_7d":2,"beast_zero_touch_7d":2}"#,
            ],
        );
        let section = build_mission_binary_section(&tmp);
        assert_eq!(section.current_streak, 2);
        assert_eq!(section.longest_streak, 2);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_cost_savings_computes_baseline() {
        ensure_pricing();
        let tmp = tempdir();
        let ts = fixture_ts();
        // Session with together-deepseek-v3 (cheaper than Sonnet fallback).
        // together-deepseek-v3: $0.85/$0.85/$0.0 per MTok
        // unknown (Sonnet):     $3/$15/$0.30 per MTok
        write_ambient(
            &tmp,
            &[&format!(
                r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-S","outcome":"shipped","elapsed_seconds":60,"input_tokens":10000,"output_tokens":2000,"cache_read_tokens":0,"model_id":"together-deepseek-v3"}}"#
            )],
        );
        let section = build_cost_savings_section(&tmp, 30);
        assert!(
            section.actual_cost_usd < section.anthropic_only_cost_usd,
            "deepseek model ({}) should cost less than anthropic-only baseline ({})",
            section.actual_cost_usd,
            section.anthropic_only_cost_usd
        );
        assert!(section.anthropic_only_cost_usd > 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn zero_waste_060_free_tier_savings_sums_cascade_routed_tokens() {
        ensure_pricing();
        let tmp = tempdir();
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{ts}","kind":"cascade_routed","slot":"groq-llama","tier":"cloud","cascade_mode":"cloud-first","tokens":5000}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"cascade_routed","slot":"ollama-local","tier":"local","cascade_mode":"cloud-first","tokens":1000}}"#
                ),
                // Wrong kind: must not contribute to the tally.
                &format!(
                    r#"{{"ts":"{ts}","kind":"session_end","session_id":"s1","gap_id":"TEST-S","outcome":"shipped","input_tokens":1,"output_tokens":1,"cache_read_tokens":0,"model_id":"unknown"}}"#
                ),
            ],
        );
        let section = build_free_tier_savings_section(&tmp, 30);
        assert_eq!(section.routed_calls, 2);
        assert_eq!(section.free_cloud_tokens, 5000);
        assert_eq!(section.free_local_tokens, 1000);
        assert_eq!(section.free_tokens_used, 6000);
        assert!(
            section.dollars_saved_usd > 0.0,
            "6000 free tokens at Anthropic-only rates must price above $0, got {}",
            section.dollars_saved_usd
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn zero_waste_060_free_tier_savings_ignores_old_events() {
        ensure_pricing();
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2000-01-01T00:00:00Z","kind":"cascade_routed","slot":"groq-llama","tier":"cloud","cascade_mode":"cloud-first","tokens":9999}"#,
            ],
        );
        let section = build_free_tier_savings_section(&tmp, 30);
        assert_eq!(section.routed_calls, 0);
        assert_eq!(section.free_tokens_used, 0);
        assert_eq!(section.dollars_saved_usd, 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_leverage_counts_depends_on() {
        let tmp = tempdir();
        let chump_dir = tmp.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(&tmp)
            .output();

        let now = current_unix() as i64;
        let store = chump_gap_store::GapStore::open(&tmp).unwrap();

        // Reserve 3 gaps, capture auto-generated IDs.
        let id_x = store
            .reserve("INFRA", "EFFECTIVE: infra core", "P1", "s")
            .unwrap();
        let id_y = store
            .reserve("INFRA", "CREDIBLE: depends on X", "P1", "s")
            .unwrap();
        let id_z = store
            .reserve("INFRA", "RESILIENT: also depends on X", "P1", "s")
            .unwrap();

        // Mark all three done
        for id in &[&id_x, &id_y, &id_z] {
            store
                .ship_for_test_with_opts(id, Some(now), Some(999))
                .unwrap();
        }

        // Set depends_on: Y→X, Z→X
        store
            .set_fields(
                &id_y,
                chump_gap_store::GapFieldUpdate {
                    depends_on: Some(id_x.clone()),
                    status: None,
                    closed_date: None,
                    closed_pr: None,
                    title: None,
                    description: None,
                    acceptance_criteria: None,
                    notes: None,
                    source_doc: None,
                    priority: None,
                    effort: None,
                    opened_date: None,
                    skills_required: None,
                    preferred_backend: None,
                    preferred_machine: None,
                    estimated_minutes: None,
                    required_model: None,
                    outcome_id: None,
                    evidence: None,
                    artifact_type: None,
                },
            )
            .unwrap();
        store
            .set_fields(
                &id_z,
                chump_gap_store::GapFieldUpdate {
                    depends_on: Some(id_x.clone()),
                    status: None,
                    closed_date: None,
                    closed_pr: None,
                    title: None,
                    description: None,
                    acceptance_criteria: None,
                    notes: None,
                    source_doc: None,
                    priority: None,
                    effort: None,
                    opened_date: None,
                    skills_required: None,
                    preferred_backend: None,
                    preferred_machine: None,
                    estimated_minutes: None,
                    required_model: None,
                    outcome_id: None,
                    evidence: None,
                    artifact_type: None,
                },
            )
            .unwrap();

        let section = build_leverage_section(&tmp);
        assert!(!section.entries.is_empty(), "should have leverage entries");
        let top = &section.entries[0];
        assert_eq!(top.gap_id, id_x);
        assert_eq!(top.depended_by_count, 2);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra617_full_report_renders_all_sections() {
        let tmp = tempdir();
        let now = current_unix() as i64;
        seed_gap_store(&tmp, &[("EFFECTIVE: full report", now)]);
        let ts = fixture_ts();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{ts}","kind":"mission_grade","effective":{{"count_pickable":1,"count_in_flight":0,"count_shipped_24h":1}},"credible":{{"count_pickable":0,"count_in_flight":0,"count_shipped_24h":0}},"resilient":{{"count_pickable":0,"count_in_flight":0,"count_shipped_24h":0}},"zero_waste":{{"count_pickable":0,"count_in_flight":0,"count_shipped_24h":0}}}}"#
                ),
                &format!(
                    r#"{{"kind":"session_end","ts":"{ts}","session_id":"s1","gap_id":"TEST-R","outcome":"shipped","elapsed_seconds":60,"input_tokens":1000,"output_tokens":500,"cache_read_tokens":0}}"#
                ),
            ],
        );

        let report = build_full_report(&tmp, 7);
        let text = report.render_text();
        assert!(text.contains("Ship Rate Trend"));
        assert!(text.contains("Mission Grade History"));
        assert!(text.contains("Cost Savings vs Anthropic-Only"));
        assert!(text.contains("Productizations by Leverage"));
        assert!(text.contains("Tokens-per-Ship"));

        let json = report.render_json();
        assert!(json.contains(r#""ship_rate""#));
        assert!(json.contains(r#""mission_history""#));
        assert!(json.contains(r#""cost_savings""#));
        assert!(json.contains(r#""leverage""#));
        assert!(json.contains(r#""tokens_per_ship""#));
        assert!(json.contains(r#""handoff_rate""#));
        // CREDIBLE-1525: admin_merges_7d present (no cache in tmp → source none, 0).
        assert!(json.contains(r#""admin_merges":{"admin_merges_7d":0,"source":"none"}"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── INFRA-773: HandoffRateSection tests ──────────────────────────────────

    fn write_ambient_handoff(root: &std::path::Path, lines: &[&str]) {
        let locks = root.join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        for line in lines {
            writeln!(f, "{}", line).unwrap();
        }
    }

    fn recent_ts() -> String {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // Approximate ISO-8601 with just the unix timestamp as string; extract_field parses it
        format!("{secs}")
    }

    #[test]
    fn handoff_rate_zero_when_no_events() {
        let tmp = tempdir();
        let section = build_handoff_rate_section(&tmp, 7);
        assert_eq!(section.initiated, 0);
        assert_eq!(section.self_heal_rate(), 0.0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn handoff_rate_counts_correctly() {
        let tmp = tempdir();
        let ts = recent_ts();
        write_ambient_handoff(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_initiated","pr":"123","reviewer_session":"s1","failure_surface":"test"}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_initiated","pr":"124","reviewer_session":"s2","failure_surface":"lint"}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_applied","pr":"123","author_session":"s3","handoff_comment_id":"c1"}}"#
                ),
                &format!(
                    r#"{{"ts":"{ts}","kind":"review_handoff_failed","pr":"124","author_session":"s4","failure_detail":"still red"}}"#
                ),
            ],
        );
        let section = build_handoff_rate_section(&tmp, 7);
        assert_eq!(section.initiated, 2);
        assert_eq!(section.applied, 1);
        assert_eq!(section.failed, 1);
        assert_eq!(section.timeout, 0);
        assert!((section.self_heal_rate() - 0.5).abs() < 0.01);
        assert!((section.reviewer_error_rate() - 0.5).abs() < 0.01);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn handoff_rate_render_text_no_handoffs() {
        let section = HandoffRateSection::default();
        let text = section.render_text();
        assert!(text.contains("no handoffs initiated"));
    }

    #[test]
    fn handoff_rate_render_text_with_data() {
        let section = HandoffRateSection {
            initiated: 4,
            applied: 3,
            failed: 1,
            timeout: 0,
        };
        let text = section.render_text();
        assert!(text.contains("Self-heal rate: 75%"));
        assert!(text.contains("Reviewer-error rate: 25%"));
    }

    #[test]
    fn handoff_rate_render_json() {
        let section = HandoffRateSection {
            initiated: 2,
            applied: 2,
            failed: 0,
            timeout: 0,
        };
        let json = section.render_json();
        assert!(json.contains(r#""initiated":2"#));
        assert!(json.contains(r#""applied":2"#));
        assert!(json.contains(r#""self_heal_rate_pct":100"#));
    }

    #[test]
    fn waste_kinds_includes_handoff_failed_and_timeout() {
        use chump_waste_tally::waste_tally::WASTE_KINDS;
        assert!(WASTE_KINDS.contains(&"review_handoff_failed"));
        assert!(WASTE_KINDS.contains(&"review_handoff_timeout"));
    }

    // ── INFRA-2143: Integration Cycle Dashboard tests ───────────────────────

    /// ISO-8601 timestamp `hours_ago` hours before now (test-only helper;
    /// exercises the same `unix_to_iso8601` the production gh-metrics path uses).
    fn ts_hours_ago(hours_ago: u64) -> String {
        unix_to_iso8601(current_unix().saturating_sub(hours_ago * 3600))
    }

    #[test]
    fn integration_cycle_empty_dataset() {
        let tmp = tempdir();
        let section = build_integration_cycle_section(&tmp, 168);
        assert_eq!(section.cycles_started, 0);
        assert_eq!(section.cycles_shipped, 0);
        assert_eq!(section.gaps_shipped, 0);
        assert_eq!(section.mean_gaps_per_cycle(), 0.0);
        assert!(section.p50_wall_minutes.is_none());
        assert!(section.p95_wall_minutes.is_none());
        assert_eq!(section.bisect_quarantine_rate_pct, 0.0);
        assert_eq!(section.wall_time_saved_hours, 0.0);
        assert_eq!(section.graphql_exhaustion_per_day, 0.0);
        assert_eq!(section.operator_flake_rerun_per_day, 0.0);
    }

    #[test]
    fn integration_cycle_one_cycle_zero_quarantine() {
        let tmp = tempdir();
        let t_start = ts_hours_ago(2);
        let t_end = ts_hours_ago(1);
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{t_start}","kind":"integration_cycle_started","cycle_id":"c1"}}"#
                ),
                &format!(
                    r#"{{"ts":"{t_end}","kind":"integration_cycle_shipped","cycle_id":"c1","gap_count":3}}"#
                ),
            ],
        );
        let section = build_integration_cycle_section(&tmp, 168);
        assert_eq!(section.cycles_started, 1);
        assert_eq!(section.cycles_shipped, 1);
        assert_eq!(section.gaps_shipped, 3);
        assert_eq!(section.cycles_zero_fail, 1);
        assert_eq!(section.rerun_cycles, 0);
        assert_eq!(section.quarantined_count, 0);
        assert_eq!(section.bisect_quarantine_rate_pct, 0.0);
        assert!(section.p50_wall_minutes.is_some());
        // 1 hour = 60 minutes wall time.
        assert!((section.p50_wall_minutes.unwrap() - 60.0).abs() < 0.5);
    }

    #[test]
    fn integration_cycle_multi_cycle_mixed_quality() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                // Cycle 1: clean ship, 2 gaps.
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_started","cycle_id":"c1"}}"#,
                    ts_hours_ago(10)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_shipped","cycle_id":"c1","gap_count":2}}"#,
                    ts_hours_ago(9)
                ),
                // Cycle 2: preflight failure, one gap quarantined, then ships 1 gap.
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_started","cycle_id":"c2"}}"#,
                    ts_hours_ago(8)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_preflight_failed","cycle_id":"c2"}}"#,
                    ts_hours_ago(7)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"bisect_quarantine","cycle_id":"c2","gap_id":"INFRA-9"}}"#,
                    ts_hours_ago(7)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_shipped","cycle_id":"c2","gap_count":1}}"#,
                    ts_hours_ago(6)
                ),
                // Cycle 3: aborted entirely (failed, nothing shipped).
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_started","cycle_id":"c3"}}"#,
                    ts_hours_ago(5)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_failed","cycle_id":"c3"}}"#,
                    ts_hours_ago(4)
                ),
                // External costs.
                &format!(
                    r#"{{"ts":"{}","kind":"graphql_exhausted"}}"#,
                    ts_hours_ago(3)
                ),
                &format!(r#"{{"ts":"{}","kind":"ci_flake_rerun"}}"#, ts_hours_ago(3)),
            ],
        );
        let section = build_integration_cycle_section(&tmp, 168);
        assert_eq!(section.cycles_started, 3);
        assert_eq!(section.cycles_shipped, 2);
        assert_eq!(section.gaps_shipped, 3);
        assert_eq!(section.quarantined_count, 1);
        assert_eq!(section.rerun_cycles, 1);
        assert_eq!(section.cycles_zero_fail, 2);
        // quarantine rate = 1 / (3 shipped + 1 quarantined) = 25%.
        assert!((section.bisect_quarantine_rate_pct - 25.0).abs() < 0.01);
        assert!(section.graphql_exhaustion_per_day > 0.0);
        assert!(section.operator_flake_rerun_per_day > 0.0);
        // gaps_shipped(3) > cycles_shipped(2) → some wall time saved.
        assert!(section.wall_time_saved_hours > 0.0);
    }

    #[test]
    fn integration_cycle_events_outside_window_excluded() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_started","cycle_id":"old"}}"#,
                    ts_hours_ago(1000)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_shipped","cycle_id":"old","gap_count":9}}"#,
                    ts_hours_ago(999)
                ),
            ],
        );
        // 168h (7d) window — a 1000h-old event must not count.
        let section = build_integration_cycle_section(&tmp, 168);
        assert_eq!(section.cycles_started, 0);
        assert_eq!(section.gaps_shipped, 0);
    }

    #[test]
    fn integration_cycle_window_override_30d() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_started","cycle_id":"c1"}}"#,
                    ts_hours_ago(400)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_shipped","cycle_id":"c1","gap_count":1}}"#,
                    ts_hours_ago(399)
                ),
            ],
        );
        // 400h ago is outside 7d (168h) but inside 30d (720h).
        let narrow = build_integration_cycle_section(&tmp, 168);
        let wide = build_integration_cycle_section(&tmp, 720);
        assert_eq!(narrow.cycles_started, 0);
        assert_eq!(wide.cycles_started, 1);
        assert_eq!(wide.gaps_shipped, 1);
    }

    #[test]
    fn integration_cycle_render_text_contains_sections() {
        let tmp = tempdir();
        let section = build_integration_cycle_section(&tmp, 168);
        let text = section.render_text();
        assert!(text.contains("Integration Cycle Dashboard"));
        assert!(text.contains("SHIP VELOCITY"));
        assert!(text.contains("EFFICIENCY VS PER-PR BASELINE"));
        assert!(text.contains("QUALITY"));
        assert!(text.contains("EXTERNAL COSTS"));
    }

    #[test]
    fn integration_cycle_render_json_shape() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_started","cycle_id":"c1"}}"#,
                    ts_hours_ago(2)
                ),
                &format!(
                    r#"{{"ts":"{}","kind":"integration_cycle_shipped","cycle_id":"c1","gap_count":2}}"#,
                    ts_hours_ago(1)
                ),
            ],
        );
        let section = build_integration_cycle_section(&tmp, 168);
        let json = section.render_json();
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        assert_eq!(parsed["cycles_shipped"], 1);
        assert_eq!(parsed["gaps_shipped"], 2);
        assert!(parsed.get("bisect_quarantine_rate_pct").is_some());
        assert!(parsed.get("p50_wall_minutes").is_some());
    }

    #[test]
    fn integration_cycle_gh_metrics_none_when_no_remote() {
        // No git remote configured in the temp dir → best-effort gh lookup
        // degrades to None rather than erroring the whole report.
        let tmp = tempdir();
        let (ci_runs, runner_util) = fetch_gh_actions_metrics(&tmp, 168, 5);
        assert!(ci_runs.is_none());
        assert!(runner_util.is_none());
    }

    #[test]
    fn integration_cycle_gh_metrics_none_when_zero_gaps_shipped() {
        let tmp = tempdir();
        let (ci_runs, runner_util) = fetch_gh_actions_metrics(&tmp, 168, 0);
        assert!(ci_runs.is_none());
        assert!(runner_util.is_none());
    }

    #[test]
    fn resolve_repo_slug_env_override() {
        std::env::set_var("CHUMP_INVENTORY_REPO", "repairman29/chump");
        let tmp = tempdir();
        let slug = resolve_repo_slug(&tmp);
        std::env::remove_var("CHUMP_INVENTORY_REPO");
        assert_eq!(slug, Some(("repairman29".to_string(), "chump".to_string())));
    }

    // ── CREDIBLE-099 AC-4/AC-7: kpi --agents ambient fallback ──────────────

    #[test]
    fn agent_throughput_falls_back_to_ambient_when_no_metrics_file() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2026-08-18T10:00:00Z","session":"worker-a","kind":"gap_shipped","gap_id":"CREDIBLE-1"}"#,
                r#"{"ts":"2026-08-18T11:00:00Z","session":"worker-a","kind":"gap_shipped","gap_id":"CREDIBLE-2"}"#,
                r#"{"ts":"2026-08-18T12:00:00Z","session":"worker-b","kind":"gap_shipped","gap_id":"CREDIBLE-3"}"#,
                r#"{"ts":"2026-08-17T12:00:00Z","session":"worker-a","kind":"gap_shipped","gap_id":"CREDIBLE-0"}"#,
                r#"{"ts":"2026-08-18T13:00:00Z","session":"worker-a","kind":"gap_claimed","gap_id":"CREDIBLE-4"}"#,
            ],
        );
        let section = build_agent_throughput_section(&tmp, Some("2026-08-18"));
        assert_eq!(section.date, "2026-08-18");
        assert_eq!(section.total_ships, 3);
        let a = section
            .rows
            .iter()
            .find(|r| r.agent_id == "worker-a")
            .expect("worker-a row present");
        assert_eq!(a.ships, 2);
        let b = section
            .rows
            .iter()
            .find(|r| r.agent_id == "worker-b")
            .expect("worker-b row present");
        assert_eq!(b.ships, 1);
        let text = section.render_text();
        assert!(!text.contains("No throughput data found"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn agent_throughput_prefers_metrics_file_over_ambient() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2026-08-18T10:00:00Z","session":"worker-a","kind":"gap_shipped","gap_id":"CREDIBLE-1"}"#,
            ],
        );
        let metrics_dir = tmp.join(".chump/metrics");
        std::fs::create_dir_all(&metrics_dir).unwrap();
        std::fs::write(
            metrics_dir.join("agent-throughput-2026-08-18.json"),
            r#"{"date":"2026-08-18","total_ships":9,"total_fails":1,"agents":[{"agent_id":"worker-file","ships":9,"fails":1}]}"#,
        )
        .unwrap();
        let section = build_agent_throughput_section(&tmp, Some("2026-08-18"));
        assert_eq!(section.total_ships, 9);
        assert_eq!(section.rows.len(), 1);
        assert_eq!(section.rows[0].agent_id, "worker-file");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn agent_throughput_no_data_when_ambient_and_metrics_both_empty() {
        let tmp = tempdir();
        let section = build_agent_throughput_section(&tmp, Some("2026-08-18"));
        assert!(section.date.is_empty());
        assert!(section.render_text().contains("No throughput data found"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1112_green_first_try_pct_computed_correctly() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                // CREDIBLE-1: shipped clean, no phase failure recorded.
                r#"{"ts":"2026-09-01T00:00:00Z","kind":"gap_shipped","gap_id":"CREDIBLE-1","pr_number":"101","commit_sha":"aaa"}"#,
                // CREDIBLE-2: hit a clippy failure before shipping — NOT green-first-try.
                r#"{"ts":"2026-09-01T00:05:00Z","kind":"bot_merge_phase_failure","step":"clippy","exit_code":13,"gap_id":"CREDIBLE-2","branch":"chump/credible-2"}"#,
                r#"{"ts":"2026-09-01T00:10:00Z","kind":"gap_shipped","gap_id":"CREDIBLE-2","pr_number":"102","commit_sha":"bbb"}"#,
                // CREDIBLE-3: shipped clean, no phase failure recorded.
                r#"{"ts":"2026-09-01T00:15:00Z","kind":"gap_shipped","gap_id":"CREDIBLE-3","pr_number":"103","commit_sha":"ccc"}"#,
                // Unrelated phase failure for a gap that never shipped — must not affect the ratio.
                r#"{"ts":"2026-09-01T00:20:00Z","kind":"bot_merge_phase_failure","step":"test","exit_code":14,"gap_id":"CREDIBLE-4","branch":"chump/credible-4"}"#,
            ],
        );
        let section = build_green_first_try_section(&tmp);
        assert_eq!(section.total_ships, 3);
        assert_eq!(section.green_first_try, 2);
        assert!((section.green_first_try_pct() - (200.0 / 3.0)).abs() < 0.01);
        assert!(section
            .render_text()
            .contains("2/3 ships green on first try"));
        assert!(section
            .render_json()
            .contains(r#""total_ships":3,"green_first_try":2"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1112_green_first_try_zero_when_no_ships() {
        let tmp = tempdir();
        let section = build_green_first_try_section(&tmp);
        assert_eq!(section.total_ships, 0);
        assert_eq!(section.green_first_try, 0);
        assert_eq!(section.green_first_try_pct(), 0.0);
        assert!(section
            .render_text()
            .contains("No gap_shipped events found"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1113_time_to_land_computed_correctly() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                // CREDIBLE-1: claimed at t0, shipped 100s later.
                r#"{"ts":"2026-09-01T00:00:00Z","kind":"gap_claimed","gap_id":"CREDIBLE-1"}"#,
                r#"{"ts":"2026-09-01T00:01:40Z","kind":"gap_shipped","gap_id":"CREDIBLE-1"}"#,
                // CREDIBLE-2: claimed at t0, shipped 200s later.
                r#"{"ts":"2026-09-01T01:00:00Z","kind":"gap_claimed","gap_id":"CREDIBLE-2"}"#,
                r#"{"ts":"2026-09-01T01:03:20Z","kind":"gap_shipped","gap_id":"CREDIBLE-2"}"#,
                // CREDIBLE-3: shipped with no matching claim — excluded from the sample.
                r#"{"ts":"2026-09-01T02:00:00Z","kind":"gap_shipped","gap_id":"CREDIBLE-3"}"#,
            ],
        );
        let section = build_time_to_land_section(&tmp);
        assert_eq!(section.sample_count, 2);
        assert_eq!(section.max_seconds, Some(200));
        assert!(section.render_text().contains("n=2"));
        assert!(section.render_json().contains(r#""sample_count":2"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1113_time_to_land_empty_when_no_pairs() {
        let tmp = tempdir();
        let section = build_time_to_land_section(&tmp);
        assert_eq!(section.sample_count, 0);
        assert!(section.p50_seconds.is_none());
        assert!(section.render_text().contains("No claim→ship pairs found"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1115_gate_fp_rate_computed_correctly() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2026-09-01T00:00:00Z","kind":"duty_officer_action","signal":"a","tier":"T2","verdict":"refuted","detail":"x"}"#,
                r#"{"ts":"2026-09-01T00:01:00Z","kind":"duty_officer_action","signal":"b","tier":"T1","verdict":"healed","detail":"x"}"#,
                r#"{"ts":"2026-09-01T00:02:00Z","kind":"duty_officer_action","signal":"c","tier":"T3","verdict":"suppressed","detail":"x"}"#,
                // Unrelated event kind must not affect the tally.
                r#"{"ts":"2026-09-01T00:03:00Z","kind":"gap_shipped","gap_id":"CREDIBLE-1"}"#,
            ],
        );
        let section = build_gate_false_positive_section(&tmp);
        assert_eq!(section.total_signals, 3);
        assert_eq!(section.false_positives, 1);
        assert!((section.fp_rate_pct() - (100.0 / 3.0)).abs() < 0.01);
        assert!(section
            .render_text()
            .contains("1/3 signals refuted as false positive"));
        assert!(section
            .render_json()
            .contains(r#""total_signals":3,"false_positives":1"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1514_ci_census_reads_counts() {
        let tmp = tempdir();
        let dir = tmp.join("docs/observability");
        std::fs::create_dir_all(&dir).unwrap();
        assert!(build_ci_census_section(&tmp)
            .render_text()
            .contains("No docs/observability"));
        std::fs::write(
            dir.join("ci-test-census.json"),
            r#"{"run_date":"2026-10-17","mode":"no-run","counts":{"total":1611,"unwired":1231,"red":12},"tests":[]}"#,
        )
        .unwrap();
        let section = build_ci_census_section(&tmp);
        assert_eq!(section.unwired, Some(1231));
        assert_eq!(section.red, Some(12));
        assert!(section.render_text().contains("ci_tests_unwired: 1231"));
        assert!(section
            .render_json()
            .contains(r#""ci_tests_unwired":1231,"ci_tests_red":12"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1115_gate_fp_rate_zero_when_no_signals() {
        let tmp = tempdir();
        let section = build_gate_false_positive_section(&tmp);
        assert_eq!(section.total_signals, 0);
        assert_eq!(section.fp_rate_pct(), 0.0);
        assert!(section
            .render_text()
            .contains("No duty_officer_action events found"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1509_shell_invariant_writers_unavailable_when_no_source() {
        let tmp = tempdir();
        let section = build_shell_invariant_writers_section(&tmp);
        assert_eq!(section.file_count, None);
        assert_eq!(section.source, "unavailable");
        assert!(section.render_text().contains("No reading"));
        assert!(section
            .render_json()
            .contains(r#""shell_invariant_writers":null"#));
        assert!(section.render_json().contains(r#""target":0"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Writes a stub gate that prints a violator list then the reading line,
    /// mirroring scripts/ci/test-invariant-boundary.sh's real output.
    fn write_stub_gate(root: &std::path::Path, count: u64) {
        let ci = root.join("scripts/ci");
        std::fs::create_dir_all(&ci).unwrap();
        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
        std::fs::write(
            ci.join("test-invariant-boundary.sh"),
            format!(
                "#!/usr/bin/env bash\necho '  • bot-merge.sh'\necho 'Total violators: {count}'\necho '{{\"ts\":\"{ts}\",\"kind\":\"invariant_boundary_violation\",\"count\":{count},\"mode\":\"shadow\"}}'\n"
            ),
        )
        .unwrap();
    }

    #[test]
    fn credible1509_shell_invariant_writers_stale_ambient_without_gate() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                // Earlier reading, then a later one: latest must win.
                r#"{"ts":"2026-10-16T00:00:00Z","kind":"invariant_boundary_violation","count":41,"mode":"shadow"}"#,
                r#"{"ts":"2026-10-17T00:00:00Z","kind":"invariant_boundary_violation","count":39,"mode":"shadow"}"#,
                r#"{"ts":"2026-10-17T01:00:00Z","kind":"gap_shipped","gap_id":"X-1"}"#,
            ],
        );
        // No gate script in this tree: the stale recorded reading is reported
        // with its own date.
        let section = build_shell_invariant_writers_section(&tmp);
        assert_eq!(section.file_count, Some(39));
        assert_eq!(section.source, "ambient");
        assert_eq!(section.reading_date.as_deref(), Some("2026-10-17"));
        assert!(section
            .render_text()
            .contains("shell_invariant_writers: 39"));
        assert!(section
            .render_json()
            .contains(r#""shell_invariant_writers":39"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1509_shell_invariant_writers_runs_gate_when_reading_stale() {
        let tmp = tempdir();
        write_ambient(
            &tmp,
            &[
                r#"{"ts":"2026-01-01T00:00:00Z","kind":"invariant_boundary_violation","count":99,"mode":"shadow"}"#,
            ],
        );
        write_stub_gate(&tmp, 7);
        let section = build_shell_invariant_writers_section(&tmp);
        assert_eq!(section.file_count, Some(7));
        assert_eq!(section.source, "gate");
        assert!(section.reading_date.is_some());

        // --no-gate: the stale recorded reading is used instead of the gate.
        let cached = build_shell_invariant_writers_section_with(&tmp, false);
        assert_eq!(cached.file_count, Some(99));
        assert_eq!(cached.source, "ambient");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible1509_shell_invariant_writers_reuses_fresh_reading() {
        let tmp = tempdir();
        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
        let fresh = format!(
            r#"{{"ts":"{ts}","kind":"invariant_boundary_violation","count":5,"mode":"shadow"}}"#
        );
        write_ambient(&tmp, &[fresh.as_str()]);
        // A gate that would say 7 must not run while the reading is fresh.
        write_stub_gate(&tmp, 7);
        let section = build_shell_invariant_writers_section(&tmp);
        assert_eq!(section.file_count, Some(5));
        assert_eq!(section.source, "ambient");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ── INFRA-8577: shell LOC by month ──────────────────────────────────────

    #[test]
    fn infra8577_last_n_months_wraps_year_boundary() {
        assert_eq!(
            last_n_months(2026, 10, 3),
            vec![(2026, 8), (2026, 9), (2026, 10)]
        );
        // January looks back into the prior year.
        assert_eq!(
            last_n_months(2026, 1, 3),
            vec![(2025, 11), (2025, 12), (2026, 1)]
        );
    }

    /// `n` lines, each newline-terminated, so `wc -l` (newline count) == `n`.
    fn n_lines(n: usize) -> String {
        (0..n).map(|i| format!("line{i}\n")).collect()
    }

    /// Replace the repo's `scripts/` tree with `files` and commit, dating both
    /// the author and committer at `date` (RFC3339-ish, git-parseable).
    fn commit_scripts(dir: &Path, date: &str, files: &[(&str, usize)]) {
        let scripts = dir.join("scripts");
        let _ = std::fs::remove_dir_all(&scripts);
        std::fs::create_dir_all(&scripts).unwrap();
        for (name, n) in files {
            std::fs::write(scripts.join(name), n_lines(*n)).unwrap();
        }
        let add = std::process::Command::new("git")
            .args(["-C", &dir.to_string_lossy(), "add", "-A"])
            .output()
            .unwrap();
        assert!(add.status.success());
        let commit = std::process::Command::new("git")
            .args([
                "-C",
                &dir.to_string_lossy(),
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "commit",
                "-m",
                "fixture",
            ])
            .env("GIT_AUTHOR_DATE", date)
            .env("GIT_COMMITTER_DATE", date)
            .output()
            .unwrap();
        assert!(
            commit.status.success(),
            "commit failed: {}",
            String::from_utf8_lossy(&commit.stderr)
        );
    }

    #[test]
    fn infra8577_shell_loc_by_month_matches_fixture_counts() {
        let tmp = tempdir();
        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(&tmp)
            .output();

        // August: a.sh(10) + b.py(5) + a non-shell file that must be ignored.
        commit_scripts(
            &tmp,
            "2026-08-01T12:00:00",
            &[("a.sh", 10), ("b.py", 5), ("README.md", 7)],
        );
        // September: a.sh shrinks to 6, b.py stays 5 → 11.
        commit_scripts(
            &tmp,
            "2026-09-02T09:00:00",
            &[("a.sh", 6), ("b.py", 5), ("README.md", 7)],
        );
        // October: b.py dropped, a.sh shrinks to 4 → 4.
        commit_scripts(
            &tmp,
            "2026-10-03T08:00:00",
            &[("a.sh", 4), ("README.md", 7)],
        );

        let months = [(2026, 8), (2026, 9), (2026, 10)];
        let section = build_shell_loc_by_month_section_with(&tmp, &months);

        assert_eq!(section.months.len(), 3);
        assert_eq!(section.months[0].month, "2026-08");
        assert_eq!(section.months[0].loc, Some(15)); // .md excluded
        assert_eq!(section.months[1].month, "2026-09");
        assert_eq!(section.months[1].loc, Some(11));
        assert_eq!(section.months[2].month, "2026-10");
        assert_eq!(section.months[2].loc, Some(4));
        assert!(section.months.iter().all(|m| m.commit.is_some()));

        // AC3: text report prints the trend line.
        let text = section.render_text();
        assert!(text.contains("trend:"), "text: {text}");
        assert!(text.contains("2026-08=15"), "text: {text}");
        assert!(text.contains("2026-10=4"), "text: {text}");

        // AC1: JSON carries the three months with loc values.
        let json = section.render_json();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v.as_array().unwrap().len(), 3);
        assert_eq!(v[0]["month"], "2026-08");
        assert_eq!(v[0]["loc"], 15);
        assert_eq!(v[2]["loc"], 4);

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra8577_month_with_no_commit_is_null() {
        let tmp = tempdir();
        let _ = std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(&tmp)
            .output();
        commit_scripts(&tmp, "2026-10-01T12:00:00", &[("a.sh", 3)]);

        // Ask for a month (August) that has no commit — loc/commit are None.
        let section = build_shell_loc_by_month_section_with(&tmp, &[(2026, 8), (2026, 10)]);
        assert_eq!(section.months[0].commit, None);
        assert_eq!(section.months[0].loc, None);
        assert_eq!(section.months[1].loc, Some(3));

        let json = section.render_json();
        assert!(json.contains(r#""month":"2026-08","commit":null,"loc":null"#));
        let text = section.render_text();
        assert!(text.contains("2026-08=n/a"), "text: {text}");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
