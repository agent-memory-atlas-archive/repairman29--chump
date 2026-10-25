//! INFRA-646: weekly health digest — Sunday 23:00 summary of fleet metrics.
//!
//! Reads `.chump-locks/ambient.jsonl` and the gap registry (`.chump/state.db`)
//! for the past 7 days and produces a compact operator summary covering:
//!
//!   - ships count + ship rate trend
//!   - waste $ by class (top-5 waste kinds)
//!   - top-3 burning gaps by cumulative token spend
//!   - P0 budget compliance (≤5 open P0s)
//!   - pillar balance: EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE open count
//!   - SLO breaches: fleet_wedge, silent_agent, pr_stuck incident counts
//!   - productizations: EFFECTIVE:-tagged gaps filed vs shipped in window
//!
//! ## Ambient event emitted (`--emit`)
//!
//! ```json
//! {"ts":"...","kind":"weekly_health_digest","ships":12,"ship_rate_pct":85.0,
//!  "waste_usd":2.34,"p0_count":3,"p0_compliant":true,
//!  "slo_breaches":2,"effective_filed":4,"effective_shipped":2}
//! ```
//!
//! ## Webhook delivery
//!
//! Set `CHUMP_WEBHOOK_URL` to POST the digest JSON to an endpoint.
//! Optional: `CHUMP_WEBHOOK_TOKEN` adds a `Authorization: Bearer <token>` header.
//! Set `CHUMP_WEBHOOK_SLACK=1` to format as a Slack Block Kit message.

use std::collections::{BTreeMap, HashSet};
use std::io::Write as IoWrite;
use std::path::Path;

#[allow(unused_imports)]
pub use crate::doctor::{
    check_gap_stores, check_load_aware_deadman, check_load_aware_deadman_at,
    classify_node_gap_stores, DEADMAN_MAX_AGE_SECS,
};

// ── Public types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct WeekSummary {
    pub window_secs: u64,
    /// Total PR ships (ship_grade events) in the window.
    pub ships_count: u64,
    /// Ships / (ships + abandoned) as 0-100. None if no data.
    pub ship_rate_pct: Option<f64>,
    /// Waste incidents + USD cost per kind, descending by incidents.
    pub waste_by_class: Vec<WasteClass>,
    pub total_waste_usd: f64,
    /// Top-3 gap_ids by cumulative input+output token spend.
    pub top_burning_gaps: Vec<BurningGap>,
    /// Current open P0 count (from gap DB; 0 if DB unavailable).
    pub p0_count: u64,
    /// True when p0_count ≤ 5.
    pub p0_compliant: bool,
    /// Open gap counts per pillar prefix (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE).
    pub pillar_counts: Vec<PillarCount>,
    /// Incident counts for key SLO event kinds in the window.
    pub slo_breaches: Vec<SloBreachCount>,
    /// EFFECTIVE:-tagged gaps filed (open or done) in the window.
    pub effective_filed: u64,
    /// EFFECTIVE:-tagged gaps shipped (status=done) in the window.
    pub effective_shipped: u64,
}

#[derive(Debug, Clone, Default)]
pub struct WasteClass {
    pub kind: String,
    pub incidents: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Default)]
pub struct BurningGap {
    pub gap_id: String,
    pub total_tokens: u64,
}

#[derive(Debug, Clone, Default)]
pub struct PillarCount {
    pub pillar: String,
    pub open_count: u64,
}

#[derive(Debug, Clone, Default)]
pub struct SloBreachCount {
    pub kind: String,
    pub incidents: u64,
}

// ── Builder ───────────────────────────────────────────────────────────────────

/// Build a weekly health summary from ambient.jsonl + gap DB.
/// `since_secs` defaults to 604800 (7 days).
pub fn build_week_summary(repo_root: &Path, since_secs: u64) -> WeekSummary {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let cutoff = current_unix().saturating_sub(since_secs);

    // ── Pass 1: scan ambient.jsonl ────────────────────────────────────────────
    let mut ships_count = 0u64;
    let mut abandoned_count = 0u64;
    // waste incident dedup: kind → set of entity strings
    let mut waste_by_kind: BTreeMap<String, (u64, f64, HashSet<String>)> = BTreeMap::new();
    // token spend: gap_id → total tokens
    let mut token_by_gap: BTreeMap<String, u64> = BTreeMap::new();
    // SLO breach event kinds
    let slo_kinds = ["fleet_wedge", "silent_agent", "pr_stuck"];
    let mut slo_by_kind: BTreeMap<String, HashSet<String>> = BTreeMap::new();
    // waste taxonomy (subset; see waste_tally.rs for full list)
    let waste_taxonomy = [
        "fleet_wedge",
        "fleet_starved",
        "lease_expired_server",
        "reaper_silent",
        "queue_stuck",
        "pr_stuck",
        "silent_agent",
        "session_abandoned",
        "session_starved",
        "worker_exit_timeout",
        "worker_exit_oom",
    ];
    let mut anon_seq: u64 = 0;

    for line in contents.lines() {
        // Timestamp filter
        if let Some(ts) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts) {
                if unix < cutoff {
                    continue;
                }
            }
        }

        let raw_kind = extract_field(line, "kind").unwrap_or_default();

        // Ships
        if raw_kind == "ship_grade" {
            ships_count += 1;
            continue;
        }

        // Session end — abandoned = waste, shipped = contributed to ship rate
        if raw_kind == "session_end" {
            match extract_field(line, "outcome").as_deref() {
                Some("abandoned") | Some("starved") => {
                    abandoned_count += 1;
                    let kind = if extract_field(line, "outcome").as_deref() == Some("starved") {
                        "session_starved"
                    } else {
                        "session_abandoned"
                    };
                    let entity = extract_field(line, "session_id")
                        .or_else(|| extract_field(line, "gap_id"))
                        .unwrap_or_else(|| {
                            anon_seq += 1;
                            format!("__anon_{}", anon_seq)
                        });
                    let input = extract_int_field(line, "input_tokens").unwrap_or(0);
                    let output = extract_int_field(line, "output_tokens").unwrap_or(0);
                    let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
                    let model =
                        extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
                    let cost =
                        crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache);
                    let bucket = waste_by_kind
                        .entry(kind.to_string())
                        .or_insert_with(|| (0, 0.0, HashSet::new()));
                    bucket.0 += 1;
                    bucket.1 += cost;
                    bucket.2.insert(entity);
                    // Token spend for burning-gap accounting
                    if let Some(gid) = extract_field(line, "gap_id") {
                        if !gid.is_empty() {
                            *token_by_gap.entry(gid).or_default() += input + output;
                        }
                    }
                }
                Some("shipped") => {
                    // Count as a ship if no ship_grade event was emitted.
                    // We use ship_grade as primary counter; this is a fallback.
                }
                _ => {}
            }
            continue;
        }

        // Token spend from session_end already handled; also pick up from any
        // session_start context logs if present (best-effort).

        // Waste ALERT events
        if raw_kind != "session_end" && waste_taxonomy.contains(&raw_kind.as_str()) {
            let cost = extract_int_field(line, "cooldown_secs")
                .or_else(|| extract_int_field(line, "elapsed_seconds"))
                .unwrap_or(0) as f64
                / 3600.0
                * 0.015; // rough $/hr estimate for fleet compute
            let entity = extract_field(line, "gap_id")
                .or_else(|| extract_field(line, "session"))
                .or_else(|| extract_int_field(line, "pr").map(|n| format!("#{}", n)))
                .or_else(|| extract_field(line, "reaper"))
                .or_else(|| extract_field(line, "agent"))
                .unwrap_or_else(|| {
                    anon_seq += 1;
                    format!("__anon_{}", anon_seq)
                });
            let bucket = waste_by_kind
                .entry(raw_kind.clone())
                .or_insert_with(|| (0, 0.0, HashSet::new()));
            bucket.0 += 1;
            bucket.1 += cost;
            bucket.2.insert(entity.clone());

            // SLO breach tracking
            if slo_kinds.contains(&raw_kind.as_str()) {
                slo_by_kind
                    .entry(raw_kind.clone())
                    .or_default()
                    .insert(entity);
            }
        }
    }

    // ── Waste top-5 by incidents ──────────────────────────────────────────────
    let mut waste_vec: Vec<WasteClass> = waste_by_kind
        .into_iter()
        .map(|(kind, (_count, cost, entities))| WasteClass {
            kind,
            incidents: entities.len() as u64,
            cost_usd: cost,
        })
        .collect();
    waste_vec.sort_by_key(|w| std::cmp::Reverse(w.incidents));
    waste_vec.truncate(5);
    let total_waste_usd: f64 = waste_vec.iter().map(|w| w.cost_usd).sum();

    // ── Top-3 burning gaps by tokens ─────────────────────────────────────────
    let mut token_vec: Vec<BurningGap> = token_by_gap
        .into_iter()
        .map(|(gap_id, total_tokens)| BurningGap {
            gap_id,
            total_tokens,
        })
        .collect();
    token_vec.sort_by_key(|b| std::cmp::Reverse(b.total_tokens));
    token_vec.truncate(3);

    // ── SLO breaches ─────────────────────────────────────────────────────────
    let mut slo_vec: Vec<SloBreachCount> = slo_by_kind
        .into_iter()
        .map(|(kind, entities)| SloBreachCount {
            kind,
            incidents: entities.len() as u64,
        })
        .collect();
    slo_vec.sort_by(|a, b| a.kind.cmp(&b.kind));

    // ── Ship rate ─────────────────────────────────────────────────────────────
    let ship_rate_pct = if ships_count + abandoned_count > 0 {
        Some(100.0 * ships_count as f64 / (ships_count + abandoned_count) as f64)
    } else {
        None
    };

    // ── Gap DB: P0 count + pillar balance + productizations ──────────────────
    let (p0_count, pillar_counts, effective_filed, effective_shipped) =
        summarise_gaps(repo_root, cutoff);
    let p0_compliant = p0_count <= 5;

    WeekSummary {
        window_secs: since_secs,
        ships_count,
        ship_rate_pct,
        waste_by_class: waste_vec,
        total_waste_usd,
        top_burning_gaps: token_vec,
        p0_count,
        p0_compliant,
        pillar_counts,
        slo_breaches: slo_vec,
        effective_filed,
        effective_shipped,
    }
}

/// Read the gap DB to extract P0 count, pillar balance, and productization metrics.
/// Returns (p0_count, pillar_counts, effective_filed, effective_shipped).
fn summarise_gaps(repo_root: &Path, window_cutoff_unix: u64) -> (u64, Vec<PillarCount>, u64, u64) {
    let store = match crate::gap_store::GapStore::open(repo_root) {
        Ok(s) => s,
        Err(_) => return (0, Vec::new(), 0, 0),
    };
    let all_gaps = match store.list(None) {
        Ok(g) => g,
        Err(_) => return (0, Vec::new(), 0, 0),
    };

    let mut p0_count = 0u64;
    let mut pillar_map: BTreeMap<String, u64> = BTreeMap::new();
    let mut effective_filed = 0u64;
    let mut effective_shipped = 0u64;

    for gap in &all_gaps {
        let is_open = gap.status == "open";
        let is_done = gap.status == "done";

        // P0 compliance
        if is_open && gap.priority == "P0" {
            p0_count += 1;
        }

        // Pillar balance (open gaps only)
        if is_open {
            let pillar = pillar_from_title(&gap.title);
            *pillar_map.entry(pillar).or_default() += 1;
        }

        // Productizations (EFFECTIVE:-tagged)
        if gap.title.starts_with("EFFECTIVE:") {
            // Filed: created in window
            if gap.created_at as u64 >= window_cutoff_unix {
                effective_filed += 1;
            }
            // Shipped: closed in window
            if is_done {
                if let Some(closed) = gap.closed_at {
                    if closed as u64 >= window_cutoff_unix {
                        effective_shipped += 1;
                    }
                }
            }
        }
    }

    let pillar_order = [
        "EFFECTIVE",
        "CREDIBLE",
        "RESILIENT",
        "ZERO-WASTE",
        "(other)",
    ];
    let pillar_counts: Vec<PillarCount> = pillar_order
        .iter()
        .filter_map(|p| {
            pillar_map.get(*p).map(|&count| PillarCount {
                pillar: p.to_string(),
                open_count: count,
            })
        })
        .collect();

    (p0_count, pillar_counts, effective_filed, effective_shipped)
}

fn pillar_from_title(title: &str) -> String {
    if title.starts_with("EFFECTIVE:") {
        "EFFECTIVE".to_string()
    } else if title.starts_with("CREDIBLE:") {
        "CREDIBLE".to_string()
    } else if title.starts_with("RESILIENT:") {
        "RESILIENT".to_string()
    } else if title.starts_with("ZERO-WASTE:") {
        "ZERO-WASTE".to_string()
    } else if title.starts_with("MISSION:") {
        "MISSION".to_string()
    } else {
        "(other)".to_string()
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

impl WeekSummary {
    pub fn render_text(&self) -> String {
        let days = self.window_secs / 86400;
        let mut out = format!(
            "╔══════════════════════════════════════════════════════╗\n\
             ║  Chump Weekly Health Digest — last {} days            ║\n\
             ╚══════════════════════════════════════════════════════╝\n\n",
            days
        );

        // Ships + ship rate
        let rate_str = match self.ship_rate_pct {
            Some(r) => format!("{:.0}%", r),
            None => "n/a".to_string(),
        };
        out.push_str(&format!(
            "Ships:        {} PRs   Ship rate: {}\n",
            self.ships_count, rate_str
        ));

        // P0 compliance
        let p0_icon = if self.p0_compliant {
            "OK"
        } else {
            "OVER BUDGET"
        };
        out.push_str(&format!(
            "P0 budget:    {} open  (≤5 required) — {}\n",
            self.p0_count, p0_icon
        ));

        // Pillar balance
        if !self.pillar_counts.is_empty() {
            out.push_str("\nPillar balance (open gaps):\n");
            for p in &self.pillar_counts {
                out.push_str(&format!("  {:12} {:>4}\n", p.pillar, p.open_count));
            }
        }

        // Waste
        out.push_str(&format!(
            "\nWaste — total est. cost: ${:.4}\n",
            self.total_waste_usd
        ));
        if self.waste_by_class.is_empty() {
            out.push_str("  (no waste events — fleet healthy)\n");
        } else {
            for w in &self.waste_by_class {
                out.push_str(&format!(
                    "  {:>4} incidents  {:<26} ${:.4}\n",
                    w.incidents, w.kind, w.cost_usd
                ));
            }
        }

        // Top burning gaps
        if !self.top_burning_gaps.is_empty() {
            out.push_str("\nTop-3 burning gaps (tokens):\n");
            for (i, b) in self.top_burning_gaps.iter().enumerate() {
                out.push_str(&format!(
                    "  {}. {:>12}  {:>10} tokens\n",
                    i + 1,
                    b.gap_id,
                    b.total_tokens
                ));
            }
        }

        // SLO breaches
        let total_breaches: u64 = self.slo_breaches.iter().map(|s| s.incidents).sum();
        if total_breaches == 0 {
            out.push_str("\nSLO: no breaches\n");
        } else {
            out.push_str(&format!("\nSLO breaches: {} total\n", total_breaches));
            for s in &self.slo_breaches {
                if s.incidents > 0 {
                    out.push_str(&format!("  {:>4}  {}\n", s.incidents, s.kind));
                }
            }
        }

        // Productizations
        out.push_str(&format!(
            "\nProductizations (EFFECTIVE:): filed {} / shipped {}\n",
            self.effective_filed, self.effective_shipped
        ));

        out
    }

    pub fn render_json(&self) -> String {
        let rate_str = match self.ship_rate_pct {
            Some(r) => format!("{:.1}", r),
            None => "null".to_string(),
        };
        let waste_json: Vec<String> = self
            .waste_by_class
            .iter()
            .map(|w| {
                format!(
                    r#"{{"kind":"{}","incidents":{},"cost_usd":{:.6}}}"#,
                    json_escape(&w.kind),
                    w.incidents,
                    w.cost_usd
                )
            })
            .collect();
        let burning_json: Vec<String> = self
            .top_burning_gaps
            .iter()
            .map(|b| {
                format!(
                    r#"{{"gap_id":"{}","total_tokens":{}}}"#,
                    json_escape(&b.gap_id),
                    b.total_tokens
                )
            })
            .collect();
        let pillar_json: Vec<String> = self
            .pillar_counts
            .iter()
            .map(|p| {
                format!(
                    r#"{{"pillar":"{}","open_count":{}}}"#,
                    json_escape(&p.pillar),
                    p.open_count
                )
            })
            .collect();
        let slo_json: Vec<String> = self
            .slo_breaches
            .iter()
            .map(|s| {
                format!(
                    r#"{{"kind":"{}","incidents":{}}}"#,
                    json_escape(&s.kind),
                    s.incidents
                )
            })
            .collect();

        let total_slo: u64 = self.slo_breaches.iter().map(|s| s.incidents).sum();

        format!(
            r#"{{"kind":"weekly_health_digest","window_secs":{ws},"ships":{ships},"ship_rate_pct":{rate},"waste_usd":{waste:.6},"p0_count":{p0},"p0_compliant":{p0c},"slo_breaches":{slo},"effective_filed":{ef},"effective_shipped":{es},"waste_by_class":[{waste_j}],"top_burning_gaps":[{burn_j}],"pillar_counts":[{pillar_j}],"slo_detail":[{slo_j}]}}"#,
            ws = self.window_secs,
            ships = self.ships_count,
            rate = rate_str,
            waste = self.total_waste_usd,
            p0 = self.p0_count,
            p0c = self.p0_compliant,
            slo = total_slo,
            ef = self.effective_filed,
            es = self.effective_shipped,
            waste_j = waste_json.join(","),
            burn_j = burning_json.join(","),
            pillar_j = pillar_json.join(","),
            slo_j = slo_json.join(","),
        )
    }
}

// ── Ambient emission ──────────────────────────────────────────────────────────

/// Append a `weekly_health_digest` compact event to `.chump-locks/ambient.jsonl`.
pub fn emit_to_ambient(repo_root: &Path, summary: &WeekSummary) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = current_iso8601();
    let total_slo: u64 = summary.slo_breaches.iter().map(|s| s.incidents).sum();
    let rate_str = match summary.ship_rate_pct {
        Some(r) => format!("{:.1}", r),
        None => "null".to_string(),
    };
    let line = format!(
        r#"{{"ts":"{ts}","kind":"weekly_health_digest","ships":{ships},"ship_rate_pct":{rate},"waste_usd":{waste:.6},"p0_count":{p0},"p0_compliant":{p0c},"slo_breaches":{slo},"effective_filed":{ef},"effective_shipped":{es}}}"#,
        ts = ts,
        ships = summary.ships_count,
        rate = rate_str,
        waste = summary.total_waste_usd,
        p0 = summary.p0_count,
        p0c = summary.p0_compliant,
        slo = total_slo,
        ef = summary.effective_filed,
        es = summary.effective_shipped,
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", line);
    }
}

// ── Webhook delivery ──────────────────────────────────────────────────────────

/// POST the digest JSON to `CHUMP_WEBHOOK_URL` if set.
/// Optionally adds `Authorization: Bearer $CHUMP_WEBHOOK_TOKEN`.
/// If `CHUMP_WEBHOOK_SLACK=1`, wraps JSON in a minimal Slack Block Kit payload.
pub fn deliver_webhook(summary: &WeekSummary) -> bool {
    let url = match std::env::var("CHUMP_WEBHOOK_URL")
        .ok()
        .filter(|s| !s.is_empty())
    {
        Some(u) => u,
        None => return false,
    };
    let token = std::env::var("CHUMP_WEBHOOK_TOKEN").unwrap_or_default();
    let slack_mode = std::env::var("CHUMP_WEBHOOK_SLACK")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    let body = if slack_mode {
        slack_block_kit(summary)
    } else {
        summary.render_json()
    };

    // Use curl(1): available everywhere, no async runtime needed.
    let mut cmd = std::process::Command::new("curl");
    cmd.args(["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST"]);
    cmd.args(["-H", "Content-Type: application/json"]);
    if !token.is_empty() {
        cmd.args(["-H", &format!("Authorization: Bearer {}", token)]);
    }
    cmd.args(["--data", &body, &url]);

    match cmd.output() {
        Ok(out) => {
            let code = String::from_utf8_lossy(&out.stdout);
            let code_n: u32 = code.trim().parse().unwrap_or(0);
            (200..300).contains(&code_n)
        }
        Err(_) => false,
    }
}

fn slack_block_kit(summary: &WeekSummary) -> String {
    let rate_str = match summary.ship_rate_pct {
        Some(r) => format!("{:.0}%", r),
        None => "n/a".to_string(),
    };
    let p0_icon = if summary.p0_compliant {
        ":white_check_mark:"
    } else {
        ":warning:"
    };
    let total_slo: u64 = summary.slo_breaches.iter().map(|s| s.incidents).sum();
    let text = format!(
        "Chump Weekly Health | Ships: {} | Rate: {} | Waste: ${:.4} | P0: {} {} | SLO breaches: {} | EFFECTIVE {}/{}",
        summary.ships_count,
        rate_str,
        summary.total_waste_usd,
        summary.p0_count,
        p0_icon,
        total_slo,
        summary.effective_shipped,
        summary.effective_filed,
    );
    format!(
        r#"{{"text":"{}","blocks":[{{"type":"section","text":{{"type":"mrkdwn","text":"{}"}}}}]}}"#,
        json_escape(&text),
        json_escape(&text),
    )
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn current_iso8601() -> String {
    if let Ok(out) = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
    {
        if out.status.success() {
            return String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    format!("{}Z", current_unix())
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if out2.status.success() {
        return String::from_utf8_lossy(&out2.stdout).trim().parse().ok();
    }
    None
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                'u' => {
                    for _ in 0..4 {
                        chars.next()?;
                    }
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    rest[..end].parse().ok()
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra646-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_ambient(root: &std::path::Path, lines: &[&str]) {
        let lock_dir = root.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        std::fs::write(lock_dir.join("ambient.jsonl"), lines.join("\n") + "\n").unwrap();
    }

    fn now_iso() -> String {
        std::process::Command::new("date")
            .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|| "2026-05-06T23:00:00Z".to_string())
    }

    #[test]
    fn infra646_empty_ambient_returns_zero_counts() {
        let tmp = tmpdir();
        let summary = build_week_summary(&tmp, 604800);
        assert_eq!(summary.ships_count, 0);
        assert_eq!(summary.total_waste_usd, 0.0);
        assert!(summary.waste_by_class.is_empty());
        assert!(summary.top_burning_gaps.is_empty());
        assert!(summary.ship_rate_pct.is_none());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_counts_ship_grade_events() {
        let tmp = tmpdir();
        let ts = now_iso();
        let lines: Vec<String> = (0..5)
            .map(|i| {
                format!(
                    r#"{{"kind":"ship_grade","ts":"{}","gap_id":"INFRA-{}","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#,
                    ts, i
                )
            })
            .collect();
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let summary = build_week_summary(&tmp, 604800);
        assert_eq!(summary.ships_count, 5);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_ship_rate_from_abandoned_sessions() {
        let tmp = tmpdir();
        let ts = now_iso();
        let lines = [
            format!(
                r#"{{"kind":"ship_grade","ts":"{}","gap_id":"INFRA-1","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#,
                ts
            ),
            format!(
                r#"{{"kind":"ship_grade","ts":"{}","gap_id":"INFRA-2","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#,
                ts
            ),
            format!(
                r#"{{"kind":"ship_grade","ts":"{}","gap_id":"INFRA-3","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}}"#,
                ts
            ),
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-A","gap_id":"INFRA-4","outcome":"abandoned","elapsed_seconds":300}}"#,
                ts
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let summary = build_week_summary(&tmp, 604800);
        assert_eq!(summary.ships_count, 3);
        // rate = 3/(3+1) = 75%
        let rate = summary.ship_rate_pct.unwrap();
        assert!((rate - 75.0).abs() < 1.0, "expected ~75%, got {}", rate);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_waste_events_counted() {
        let tmp = tmpdir();
        let ts = now_iso();
        let lines = [
            format!(
                r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-1","cooldown_secs":14400}}"#,
                ts
            ),
            format!(
                r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-1","cooldown_secs":14400}}"#,
                ts
            ),
            format!(
                r#"{{"event":"ALERT","kind":"pr_stuck","ts":"{}","pr":42}}"#,
                ts
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let summary = build_week_summary(&tmp, 604800);
        assert!(!summary.waste_by_class.is_empty());
        let wedge = summary
            .waste_by_class
            .iter()
            .find(|w| w.kind == "fleet_wedge");
        assert!(wedge.is_some(), "expected fleet_wedge in waste");
        // Two fleet_wedge lines but same gap_id entity → 1 incident after dedup
        assert_eq!(wedge.unwrap().incidents, 1);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_top_burning_gaps_from_session_end_tokens() {
        let tmp = tmpdir();
        let ts = now_iso();
        let lines = [
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"s1","gap_id":"INFRA-10","outcome":"abandoned","input_tokens":50000,"output_tokens":10000,"cache_read_tokens":0,"elapsed_seconds":300}}"#,
                ts
            ),
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"s2","gap_id":"INFRA-20","outcome":"abandoned","input_tokens":20000,"output_tokens":5000,"cache_read_tokens":0,"elapsed_seconds":200}}"#,
                ts
            ),
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"s3","gap_id":"INFRA-30","outcome":"abandoned","input_tokens":5000,"output_tokens":1000,"cache_read_tokens":0,"elapsed_seconds":100}}"#,
                ts
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let summary = build_week_summary(&tmp, 604800);
        assert!(!summary.top_burning_gaps.is_empty());
        assert_eq!(summary.top_burning_gaps[0].gap_id, "INFRA-10");
        assert_eq!(summary.top_burning_gaps[0].total_tokens, 60000);
        assert_eq!(summary.top_burning_gaps[1].gap_id, "INFRA-20");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_slo_breaches_tracked() {
        let tmp = tmpdir();
        let ts = now_iso();
        let lines = [
            format!(
                r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-1"}}"#,
                ts
            ),
            format!(
                r#"{{"event":"ALERT","kind":"pr_stuck","ts":"{}","pr":11}}"#,
                ts
            ),
            format!(
                r#"{{"event":"ALERT","kind":"pr_stuck","ts":"{}","pr":12}}"#,
                ts
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let summary = build_week_summary(&tmp, 604800);
        let total_breaches: u64 = summary.slo_breaches.iter().map(|s| s.incidents).sum();
        assert_eq!(total_breaches, 3); // 1 wedge + 2 distinct pr_stuck
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_render_text_contains_key_sections() {
        let summary = WeekSummary {
            window_secs: 604800,
            ships_count: 8,
            ship_rate_pct: Some(80.0),
            p0_count: 3,
            p0_compliant: true,
            effective_filed: 2,
            effective_shipped: 1,
            ..Default::default()
        };
        let text = summary.render_text();
        assert!(text.contains("Ships:        8"), "got: {}", text);
        assert!(text.contains("80%"), "got: {}", text);
        assert!(text.contains("P0 budget:"), "got: {}", text);
        assert!(text.contains("Productizations"), "got: {}", text);
    }

    #[test]
    fn infra646_render_json_is_valid_structure() {
        let summary = WeekSummary {
            window_secs: 604800,
            ships_count: 5,
            ship_rate_pct: Some(71.4),
            p0_count: 2,
            p0_compliant: true,
            total_waste_usd: 1.23,
            effective_filed: 3,
            effective_shipped: 1,
            ..Default::default()
        };
        let json = summary.render_json();
        assert!(
            json.contains(r#""kind":"weekly_health_digest""#),
            "got: {}",
            json
        );
        assert!(json.contains(r#""ships":5"#), "got: {}", json);
        assert!(json.contains(r#""p0_count":2"#), "got: {}", json);
        assert!(json.contains(r#""p0_compliant":true"#), "got: {}", json);
        assert!(json.contains(r#""effective_filed":3"#), "got: {}", json);
    }

    #[test]
    fn infra646_old_events_excluded_by_window() {
        let tmp = tmpdir();
        // Ancient timestamp — outside any window.
        let lines = [
            r#"{"kind":"ship_grade","ts":"2020-01-01T00:00:00Z","gap_id":"INFRA-1","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}"#,
        ];
        write_ambient(&tmp, &lines);
        let summary = build_week_summary(&tmp, 604800);
        assert_eq!(summary.ships_count, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_emit_to_ambient_appends_event() {
        let tmp = tmpdir();
        let lock_dir = tmp.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        let summary = WeekSummary {
            ships_count: 7,
            ship_rate_pct: Some(87.5),
            p0_count: 4,
            p0_compliant: true,
            ..Default::default()
        };
        emit_to_ambient(&tmp, &summary);
        let contents = std::fs::read_to_string(lock_dir.join("ambient.jsonl")).unwrap();
        assert!(contents.contains(r#""kind":"weekly_health_digest""#));
        assert!(contents.contains(r#""ships":7"#));
        assert!(contents.contains(r#""p0_count":4"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra646_pillar_from_title_classifies_prefixes() {
        assert_eq!(pillar_from_title("EFFECTIVE: add X"), "EFFECTIVE");
        assert_eq!(pillar_from_title("CREDIBLE: measure Y"), "CREDIBLE");
        assert_eq!(pillar_from_title("RESILIENT: handle Z"), "RESILIENT");
        assert_eq!(pillar_from_title("ZERO-WASTE: prune W"), "ZERO-WASTE");
        assert_eq!(pillar_from_title("MISSION: overall"), "MISSION");
        assert_eq!(pillar_from_title("fix some bug"), "(other)");
    }
}
