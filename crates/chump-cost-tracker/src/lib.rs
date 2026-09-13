//! Per-session cost visibility: Tavily usage and model call/token counts.
//! Optional session budgets (CHUMP_SESSION_BUDGET_TAVILY, CHUMP_SESSION_BUDGET_REQUESTS) log and can inject a warning when exceeded.
//! Phase 5b: per-provider call/token tracking for daily Discord summary.
//! INFRA-COST-CEILING: hard spend ceiling + soft warn via CHUMP_COST_CEILING_USD / CHUMP_COST_WARN_USD.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

static TAVILY_CALLS: AtomicU64 = AtomicU64::new(0);
static TAVILY_CREDITS: AtomicU64 = AtomicU64::new(0);
static MODEL_REQUESTS: AtomicU64 = AtomicU64::new(0);
static MODEL_INPUT_TOKENS: AtomicU64 = AtomicU64::new(0);
static MODEL_OUTPUT_TOKENS: AtomicU64 = AtomicU64::new(0);

/// Accumulated session spend in micro-USD (1 USD = 1_000_000 units).
/// Updated via `add_session_cost_usd`.
static SESSION_COST_MICRO_USD: AtomicU64 = AtomicU64::new(0);

static PROVIDER_CALLS: Mutex<Option<HashMap<String, (u64, u64)>>> = Mutex::new(None);

/// Record one Tavily call. Credits: 1 for basic/fast/ultra-fast, 2 for advanced.
pub fn record_tavily(calls: u64, credits: u64) {
    TAVILY_CALLS.fetch_add(calls, Ordering::Relaxed);
    TAVILY_CREDITS.fetch_add(credits, Ordering::Relaxed);
}

/// Record one model completion (request count and token usage).
pub fn record_completion(requests: u64, input_tokens: u64, output_tokens: u64) {
    MODEL_REQUESTS.fetch_add(requests, Ordering::Relaxed);
    MODEL_INPUT_TOKENS.fetch_add(input_tokens, Ordering::Relaxed);
    MODEL_OUTPUT_TOKENS.fetch_add(output_tokens, Ordering::Relaxed);
}

/// Record a provider call for daily summary (slot_name, estimated output tokens from response chars/4).
pub fn record_provider_call(slot_name: &str, estimated_tokens: u64) {
    if slot_name.is_empty() {
        return;
    }
    if let Ok(mut guard) = PROVIDER_CALLS.lock() {
        let map = guard.get_or_insert_with(HashMap::new);
        let entry = map.entry(slot_name.to_string()).or_insert((0, 0));
        entry.0 += 1;
        entry.1 = entry.1.saturating_add(estimated_tokens);
    }
}

/// Per-slot call count and estimated tokens for daily Discord summary.
pub fn provider_daily_summary() -> String {
    let mut lines: Vec<String> = if let Ok(guard) = PROVIDER_CALLS.lock() {
        guard
            .as_ref()
            .map(|m| {
                m.iter()
                    .map(|(name, (calls, tokens))| {
                        format!("{}: {} calls, ~{}k tokens", name, calls, tokens / 1000)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    } else {
        return String::new();
    };
    if lines.is_empty() {
        return String::new();
    }
    lines.sort();
    format!("Provider usage: {}.", lines.join("; "))
}

/// CREDIBLE-189: the raw (input, output) model-token totals for this process, so a
/// subprocess (e.g. `chump agent-run`) can emit its own per-run cost on exit — the
/// in-process tracker is invisible to the parent otherwise, and `summary()` only
/// returns a string. Mirrors `summary()`'s atomic loads.
pub fn token_totals() -> (u64, u64) {
    (
        MODEL_INPUT_TOKENS.load(Ordering::Relaxed),
        MODEL_OUTPUT_TOKENS.load(Ordering::Relaxed),
    )
}

/// One-line summary for context or logs.
pub fn summary() -> String {
    let tavily = TAVILY_CALLS.load(Ordering::Relaxed);
    let credits = TAVILY_CREDITS.load(Ordering::Relaxed);
    let requests = MODEL_REQUESTS.load(Ordering::Relaxed);
    let inp = MODEL_INPUT_TOKENS.load(Ordering::Relaxed);
    let out = MODEL_OUTPUT_TOKENS.load(Ordering::Relaxed);
    format!(
        "this session: {} model requests ({} in / {} out tokens), {} Tavily calls ({} credits)",
        requests, inp, out, tavily, credits
    )
}

/// If session budgets are set and exceeded, returns a short warning to inject into context.
pub fn budget_warning() -> Option<String> {
    let tavily_budget = std::env::var("CHUMP_SESSION_BUDGET_TAVILY")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok());
    let requests_budget = std::env::var("CHUMP_SESSION_BUDGET_REQUESTS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok());
    let credits = TAVILY_CREDITS.load(Ordering::Relaxed);
    let requests = MODEL_REQUESTS.load(Ordering::Relaxed);
    let mut over = Vec::new();
    if let Some(b) = tavily_budget {
        if credits >= b {
            over.push(format!("Tavily credits at or over session budget ({})", b));
        }
    }
    if let Some(b) = requests_budget {
        if requests >= b {
            over.push(format!("model requests at or over session budget ({})", b));
        }
    }
    if over.is_empty() {
        None
    } else {
        Some(format!("Session budget exceeded: {}.", over.join("; ")))
    }
}

/// Reset counters (e.g. at start of a new session if you want per-session accounting across restarts you'd need persistence).
#[allow(dead_code)]
pub fn reset() {
    TAVILY_CALLS.store(0, Ordering::Relaxed);
    TAVILY_CREDITS.store(0, Ordering::Relaxed);
    MODEL_REQUESTS.store(0, Ordering::Relaxed);
    MODEL_INPUT_TOKENS.store(0, Ordering::Relaxed);
    MODEL_OUTPUT_TOKENS.store(0, Ordering::Relaxed);
    SESSION_COST_MICRO_USD.store(0, Ordering::Relaxed);
}

// ── INFRA-COST-CEILING ────────────────────────────────────────────────────────

const DEFAULT_COST_CEILING_USD: f64 = 5.00;
const DEFAULT_COST_WARN_USD: f64 = 2.00;

/// Add `usd` to the session spend accumulator.
/// Call this after each provider call with the estimated cost.
pub fn add_session_cost_usd(usd: f64) {
    if usd <= 0.0 {
        return;
    }
    let micro = (usd * 1_000_000.0) as u64;
    SESSION_COST_MICRO_USD.fetch_add(micro, Ordering::Relaxed);
}

/// Current accumulated session spend in USD.
pub fn session_cost_usd() -> f64 {
    // CHUMP_SESSION_COST_USD: test/CI injection point — overrides the in-process atomic.
    if let Ok(v) = std::env::var("CHUMP_SESSION_COST_USD") {
        if let Ok(cost) = v.trim().parse::<f64>() {
            return cost;
        }
    }
    SESSION_COST_MICRO_USD.load(Ordering::Relaxed) as f64 / 1_000_000.0
}

/// Read the hard ceiling from `CHUMP_COST_CEILING_USD` (default 5.00).
pub fn cost_ceiling_usd() -> f64 {
    std::env::var("CHUMP_COST_CEILING_USD")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0)
        .unwrap_or(DEFAULT_COST_CEILING_USD)
}

/// Read the soft warn threshold from `CHUMP_COST_WARN_USD` (default 2.00).
pub fn cost_warn_usd() -> f64 {
    std::env::var("CHUMP_COST_WARN_USD")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&v| v > 0.0)
        .unwrap_or(DEFAULT_COST_WARN_USD)
}

/// Check the spend ceiling before making a provider call.
///
/// - Returns `Err(String)` if the hard ceiling has been reached (caller must NOT
///   make the API call).
/// - Returns `Ok(true)` if the soft warn threshold has been crossed but the hard
///   ceiling has not (caller should print a warning to stderr; the call is still
///   permitted).
/// - Returns `Ok(false)` if spend is below both thresholds (normal path).
///
/// The caller is responsible for actually printing the warning so that the
/// message lands on the right stderr stream.
pub fn check_ceiling() -> Result<bool, String> {
    let current = session_cost_usd();
    let ceiling = cost_ceiling_usd();
    let warn = cost_warn_usd();

    if current >= ceiling {
        return Err(format!(
            "COST CEILING REACHED: ${:.2} spent this session (hard limit: ${:.2}); \
             raise CHUMP_COST_CEILING_USD to continue",
            current, ceiling
        ));
    }

    if current > warn {
        return Ok(true);
    }

    Ok(false)
}

// ── Tests (INFRA-125) ───────────────────────────────────────────────────────
//
// All public state lives in process-global atomics + a Mutex. Parallel test
// execution would interleave reads/writes, so every test that touches state
// takes STATE_LOCK first and calls `fresh()` to start from a known floor.
// Tests that rely on env vars hold the lock for the full body so the
// set/remove doesn't race with sibling tests.

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static STATE_LOCK: Mutex<()> = Mutex::new(());

    fn fresh() {
        reset();
        if let Ok(mut g) = PROVIDER_CALLS.lock() {
            *g = None;
        }
        std::env::remove_var("CHUMP_SESSION_BUDGET_TAVILY");
        std::env::remove_var("CHUMP_SESSION_BUDGET_REQUESTS");
        std::env::remove_var("CHUMP_COST_CEILING_USD");
        std::env::remove_var("CHUMP_COST_WARN_USD");
    }

    #[test]
    fn record_tavily_accumulates() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_tavily(1, 2);
        record_tavily(3, 5);
        let s = summary();
        assert!(s.contains("4 Tavily calls"), "got: {s}");
        assert!(s.contains("7 credits"), "got: {s}");
    }

    #[test]
    fn record_completion_accumulates() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_completion(1, 100, 50);
        record_completion(2, 200, 150);
        let s = summary();
        assert!(s.contains("3 model requests"), "got: {s}");
        assert!(s.contains("300 in"), "got: {s}");
        assert!(s.contains("200 out"), "got: {s}");
    }

    #[test]
    fn token_totals_reflects_recorded_completions() {
        // CREDIBLE-189: the numeric getter a subprocess (agent-run) reads to emit
        // its own per-run token cost on exit — must mirror what record_completion
        // accumulated, not just the summary() string.
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_completion(1, 100, 50);
        record_completion(2, 200, 150);
        assert_eq!(
            token_totals(),
            (300, 200),
            "input/output token totals should sum"
        );
    }

    #[test]
    fn record_provider_call_groups_by_slot() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_provider_call("haiku", 4_000);
        record_provider_call("haiku", 6_000);
        record_provider_call("sonnet", 12_000);
        let s = provider_daily_summary();
        // sorted alphabetically per impl
        assert!(s.contains("haiku: 2 calls"), "got: {s}");
        assert!(s.contains("sonnet: 1 calls"), "got: {s}");
        assert!(
            s.contains("~10k tokens"),
            "haiku 4k+6k = 10k tokens; got: {s}"
        );
        assert!(s.contains("~12k tokens"), "got: {s}");
    }

    #[test]
    fn record_provider_call_ignores_empty_slot() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_provider_call("", 1_000);
        assert_eq!(provider_daily_summary(), "", "empty slot should be no-op");
    }

    #[test]
    fn provider_daily_summary_empty_when_no_calls() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        assert_eq!(provider_daily_summary(), "");
    }

    #[test]
    fn budget_warning_none_when_unset() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_tavily(10, 100);
        record_completion(50, 0, 0);
        assert!(budget_warning().is_none(), "no env var → no warning");
    }

    #[test]
    fn budget_warning_fires_at_or_over_tavily_threshold() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_SESSION_BUDGET_TAVILY", "5");
        record_tavily(1, 5);
        let w = budget_warning().expect("at-threshold should warn");
        assert!(w.contains("Tavily"), "got: {w}");
        assert!(w.contains("(5)"), "got: {w}");
    }

    #[test]
    fn budget_warning_fires_for_requests_too() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_SESSION_BUDGET_REQUESTS", "3");
        record_completion(3, 0, 0);
        let w = budget_warning().expect("at-threshold should warn");
        assert!(w.contains("model requests"), "got: {w}");
    }

    #[test]
    fn budget_warning_combines_both_overruns() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_SESSION_BUDGET_TAVILY", "1");
        std::env::set_var("CHUMP_SESSION_BUDGET_REQUESTS", "1");
        record_tavily(1, 2);
        record_completion(2, 0, 0);
        let w = budget_warning().expect("both budgets exceeded");
        assert!(
            w.contains("Tavily") && w.contains("model requests"),
            "got: {w}"
        );
    }

    #[test]
    fn add_session_cost_usd_accumulates_microdollars() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        add_session_cost_usd(0.10);
        add_session_cost_usd(0.25);
        let v = session_cost_usd();
        assert!((v - 0.35).abs() < 1e-6, "expected ~0.35, got {v}");
    }

    #[test]
    fn add_session_cost_usd_ignores_zero_and_negative() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        add_session_cost_usd(0.0);
        add_session_cost_usd(-1.50);
        assert_eq!(session_cost_usd(), 0.0);
    }

    #[test]
    fn cost_ceiling_defaults_when_unset() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        assert!((cost_ceiling_usd() - DEFAULT_COST_CEILING_USD).abs() < 1e-9);
        assert!((cost_warn_usd() - DEFAULT_COST_WARN_USD).abs() < 1e-9);
    }

    #[test]
    fn cost_ceiling_reads_env_var() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_COST_CEILING_USD", "42.50");
        std::env::set_var("CHUMP_COST_WARN_USD", "10.00");
        assert!((cost_ceiling_usd() - 42.50).abs() < 1e-6);
        assert!((cost_warn_usd() - 10.00).abs() < 1e-6);
    }

    #[test]
    fn cost_ceiling_falls_back_to_default_on_invalid_env() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_COST_CEILING_USD", "not-a-number");
        std::env::set_var("CHUMP_COST_WARN_USD", "0");
        assert!(
            (cost_ceiling_usd() - DEFAULT_COST_CEILING_USD).abs() < 1e-9,
            "non-numeric should fall back to default"
        );
        assert!(
            (cost_warn_usd() - DEFAULT_COST_WARN_USD).abs() < 1e-9,
            "zero is filtered out → fallback to default"
        );
    }

    #[test]
    fn check_ceiling_below_warn_returns_false() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_COST_CEILING_USD", "5.00");
        std::env::set_var("CHUMP_COST_WARN_USD", "2.00");
        add_session_cost_usd(1.00);
        assert_eq!(check_ceiling(), Ok(false));
    }

    #[test]
    fn check_ceiling_above_warn_returns_true() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_COST_CEILING_USD", "5.00");
        std::env::set_var("CHUMP_COST_WARN_USD", "2.00");
        add_session_cost_usd(2.01); // above the warn threshold
        assert_eq!(check_ceiling(), Ok(true), "above warn → soft warn");
    }

    #[test]
    fn check_ceiling_at_warn_returns_false() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_COST_CEILING_USD", "5.00");
        std::env::set_var("CHUMP_COST_WARN_USD", "2.00");
        add_session_cost_usd(2.00); // exactly at warn
        assert_eq!(
            check_ceiling(),
            Ok(false),
            "at warn → no soft warn (must be above)"
        );
    }

    #[test]
    fn check_ceiling_at_hard_returns_err() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        std::env::set_var("CHUMP_COST_CEILING_USD", "5.00");
        std::env::set_var("CHUMP_COST_WARN_USD", "2.00");
        add_session_cost_usd(5.00);
        let r = check_ceiling();
        assert!(r.is_err(), "at hard ceiling → Err");
        let msg = r.unwrap_err();
        assert!(msg.contains("COST CEILING REACHED"), "got: {msg}");
        assert!(msg.contains("CHUMP_COST_CEILING_USD"), "got: {msg}");
    }

    #[test]
    fn reset_clears_all_counters() {
        let _g = STATE_LOCK.lock().unwrap();
        fresh();
        record_tavily(5, 10);
        record_completion(3, 100, 200);
        add_session_cost_usd(1.50);
        reset();
        let s = summary();
        assert!(s.contains("0 model requests"), "got: {s}");
        assert!(s.contains("0 Tavily"), "got: {s}");
        assert_eq!(session_cost_usd(), 0.0);
    }
}

// ── Per-PR cost telemetry (INFRA-405, 2026-05-03) ────────────────────────────
//
// Persistent record of cost metrics per PR so `chump dispatch cost-report` can
// aggregate token spend, USD cost, and model distribution by domain.
// Stored in `.chump/pr_costs.db` (separate from gap_store to avoid bloating
// the main state.db with telemetry rows).

use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct PrCostRecord {
    pub pr_number: i64,
    pub gap_id: String,
    pub model: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub usd_cost: f64,
    pub duration_secs: i64,
    pub shipped_at: i64,
    pub backend: String,
}

pub fn pr_costs_db_path(repo_root: &Path) -> PathBuf {
    repo_root.join(".chump").join("pr_costs.db")
}

pub fn record_pr_cost(repo_root: &Path, record: &PrCostRecord) -> anyhow::Result<()> {
    let path = pr_costs_db_path(repo_root);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let conn = rusqlite::Connection::open(&path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_pr_costs (
            pr_number INTEGER PRIMARY KEY,
            gap_id TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens_in INTEGER DEFAULT 0,
            tokens_out INTEGER DEFAULT 0,
            usd_cost REAL DEFAULT 0.0,
            duration_secs INTEGER DEFAULT 0,
            shipped_at INTEGER NOT NULL,
            backend TEXT
        )",
    )?;

    conn.execute(
        "INSERT OR REPLACE INTO chump_pr_costs
         (pr_number, gap_id, model, tokens_in, tokens_out, usd_cost, duration_secs, shipped_at, backend)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        rusqlite::params![
            record.pr_number,
            &record.gap_id,
            &record.model,
            record.tokens_in,
            record.tokens_out,
            record.usd_cost,
            record.duration_secs,
            record.shipped_at,
            &record.backend,
        ],
    )?;

    Ok(())
}

pub fn query_pr_costs(repo_root: &Path) -> anyhow::Result<Vec<PrCostRecord>> {
    let path = pr_costs_db_path(repo_root);
    if !path.exists() {
        return Ok(Vec::new());
    }

    let conn = rusqlite::Connection::open(&path)?;
    let mut stmt = conn.prepare(
        "SELECT pr_number, gap_id, model, tokens_in, tokens_out, usd_cost, duration_secs, shipped_at, backend
         FROM chump_pr_costs
         ORDER BY shipped_at DESC"
    )?;

    let records = stmt
        .query_map([], |row| {
            Ok(PrCostRecord {
                pr_number: row.get(0)?,
                gap_id: row.get(1)?,
                model: row.get(2)?,
                tokens_in: row.get(3)?,
                tokens_out: row.get(4)?,
                usd_cost: row.get(5)?,
                duration_secs: row.get(6)?,
                shipped_at: row.get(7)?,
                backend: row.get(8)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    Ok(records)
}

#[cfg(test)]
mod pr_cost_tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_pr_cost_record_and_query() {
        let tmpdir = std::env::temp_dir().join(format!(
            "chump-pr-cost-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&tmpdir);
        fs::create_dir_all(&tmpdir).unwrap();

        let repo_root = &tmpdir;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;

        let record = PrCostRecord {
            pr_number: 12345,
            gap_id: "INFRA-405".to_string(),
            model: "claude-haiku".to_string(),
            tokens_in: 1000,
            tokens_out: 500,
            usd_cost: 0.02,
            duration_secs: 120,
            shipped_at: now,
            backend: "claude".to_string(),
        };

        record_pr_cost(repo_root, &record).unwrap();
        let records = query_pr_costs(repo_root).unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].pr_number, 12345);
        assert_eq!(records[0].gap_id, "INFRA-405");
        assert_eq!(records[0].tokens_in, 1000);
        assert_eq!(records[0].usd_cost, 0.02);

        let _ = fs::remove_dir_all(&tmpdir);
    }

    #[test]
    fn test_pr_cost_upsert() {
        let tmpdir = std::env::temp_dir().join(format!(
            "chump-pr-cost-upsert-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&tmpdir);
        fs::create_dir_all(&tmpdir).unwrap();

        let repo_root = &tmpdir;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;

        let record1 = PrCostRecord {
            pr_number: 999,
            gap_id: "TEST-1".to_string(),
            model: "claude-opus".to_string(),
            tokens_in: 100,
            tokens_out: 50,
            usd_cost: 0.01,
            duration_secs: 60,
            shipped_at: now,
            backend: "claude".to_string(),
        };

        record_pr_cost(repo_root, &record1).unwrap();
        let records = query_pr_costs(repo_root).unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].tokens_in, 100);

        let record2 = PrCostRecord {
            pr_number: 999,
            gap_id: "TEST-1".to_string(),
            model: "claude-opus".to_string(),
            tokens_in: 200,
            tokens_out: 100,
            usd_cost: 0.02,
            duration_secs: 120,
            shipped_at: now,
            backend: "claude".to_string(),
        };

        record_pr_cost(repo_root, &record2).unwrap();
        let records = query_pr_costs(repo_root).unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].tokens_in, 200);

        let _ = fs::remove_dir_all(&tmpdir);
    }
}
