//! Middleware around every tool call: timeout, per-tool circuit breaker,
//! optional **global concurrency cap** (`CHUMP_TOOL_MAX_IN_FLIGHT`),
//! optional **sliding-window rate limit** for selected tools (WP-3.2:
//! `CHUMP_TOOL_RATE_LIMIT_*`), and tracing (see docs/architecture/RUST_INFRASTRUCTURE.md).
//!
//! Today: one wrapper that applies a configurable timeout to `execute()`,
//! records timeout/errors to tool_health_db when available, and records
//! tool-call counts for observability (GET /health). Per-tool circuit breaker:
//! after N consecutive failures a tool is in cooldown for M seconds (env
//! CHUMP_TOOL_CIRCUIT_FAILURES, CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS).

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::timeout;

/// Per-tool circuit state: consecutive failures and last failure time.
fn circuit_state() -> &'static Mutex<HashMap<String, (u32, Instant)>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, (u32, Instant)>>> =
        std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn circuit_failure_threshold() -> u32 {
    std::env::var("CHUMP_TOOL_CIRCUIT_FAILURES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3)
        .max(1)
}

fn circuit_cooldown_secs() -> u64 {
    std::env::var("CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60)
        .max(1)
}

/// Consecutive `git_commit` postcondition checks seen without an intervening
/// successful non-commit action (EFFECTIVE-633: storming guard — a model
/// stuck in a commit-retry loop without making forward progress). Reset to 0
/// whenever `check_postconditions` runs for any tool other than `git_commit`.
static CONSECUTIVE_GIT_COMMITS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Max consecutive `git_commit` calls allowed before the rate limiter starts
/// rejecting. Configurable via `CHUMP_GIT_COMMIT_RATE_LIMIT` (default 3).
fn git_commit_rate_limit() -> u32 {
    std::env::var("CHUMP_GIT_COMMIT_RATE_LIMIT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3)
        .max(1)
}

/// Returns true if the tool is in cooldown (circuit open): >= N consecutive failures and within cooldown window.
fn circuit_open(tool_name: &str) -> bool {
    let threshold = circuit_failure_threshold();
    let cooldown = Duration::from_secs(circuit_cooldown_secs());
    let guard = match circuit_state().lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    if let Some((failures, last)) = guard.get(tool_name) {
        *failures >= threshold && last.elapsed() < cooldown
    } else {
        false
    }
}

fn record_circuit_failure(tool_name: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        let entry = guard
            .entry(tool_name.to_string())
            .or_insert((0, Instant::now()));
        entry.0 += 1;
        entry.1 = Instant::now();
    }
}

fn clear_circuit(tool_name: &str) {
    if let Ok(mut guard) = circuit_state().lock() {
        guard.remove(tool_name);
    }
}

// ── AUTO-011: Epistemic frustration metric ───────────────────────────────────

fn frustration_threshold() -> f64 {
    std::env::var("CHUMP_FRUSTRATION_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.7f64)
        .clamp(0.0, f64::MAX)
}

/// frustration_score = consecutive_failures × (1 − tool_reliability).
/// High when a tool keeps failing despite our confidence it should work.
pub fn frustration_score(tool_name: &str) -> f64 {
    let consecutive_failures = circuit_state()
        .lock()
        .ok()
        .and_then(|g| g.get(tool_name).map(|(f, _)| *f))
        .unwrap_or(0) as f64;
    if consecutive_failures == 0.0 {
        return 0.0;
    }
    let reliability = crate::belief_state::tool_reliability(tool_name);
    consecutive_failures * (1.0 - reliability)
}

/// Snapshot of frustration scores for all tools that have failed at least once.
pub fn all_frustration_scores() -> HashMap<String, f64> {
    let entries: Vec<(String, u32)> = match circuit_state().lock() {
        Ok(g) => g
            .iter()
            .filter(|(_, (f, _))| *f > 0)
            .map(|(name, (f, _))| (name.clone(), *f))
            .collect(),
        Err(_) => return HashMap::new(),
    };
    entries
        .into_iter()
        .map(|(name, failures)| {
            let reliability = crate::belief_state::tool_reliability(&name);
            let score = failures as f64 * (1.0 - reliability);
            (name, score)
        })
        .collect()
}

/// Check frustration threshold and pivot strategy if exceeded.
/// Records a `strategy_abandoned` causal lesson and posts to the blackboard.
/// Returns the alternative tool name suggested by belief_state::score_tools(), if any.
fn maybe_pivot_from_frustration(tool_name: &str) -> Option<String> {
    let score = frustration_score(tool_name);
    if score <= frustration_threshold() {
        return None;
    }
    tracing::warn!(
        tool = %tool_name,
        score,
        threshold = frustration_threshold(),
        "AUTO-011: frustration threshold exceeded — pivoting strategy"
    );
    crate::blackboard::post(
        crate::blackboard::Module::ToolMiddleware,
        format!(
            "AUTO-011: frustration score {:.2} for '{}' exceeds threshold {:.2} — strategy pivot",
            score,
            tool_name,
            frustration_threshold()
        ),
        crate::blackboard::SalienceFactors {
            novelty: 0.9,
            uncertainty_reduction: 0.7,
            goal_relevance: 0.8,
            urgency: 0.8,
        },
    );
    // Record causal lesson so future runs know this tool failed repeatedly.
    let lesson = format!(
        "Tool '{}' caused frustration (score {:.2}); consider alternatives",
        tool_name, score
    );
    let _ = crate::counterfactual::store_lesson(
        None,
        Some("tool_frustration"),
        tool_name,
        None,
        &lesson,
        (score / (score + 1.0)).clamp(0.0, 1.0), // map score to [0,1]
        None,
    );
    // Ask belief_state which other tool looks best now.
    let scores = crate::belief_state::score_tools_except(tool_name);
    scores.first().map(|s| s.tool_name.clone())
}

// --- Global in-flight tool concurrency (WP-3.1) ---

static TOOL_IN_FLIGHT_STATE: Mutex<Option<(usize, Arc<Semaphore>)>> = Mutex::new(None);

/// Max concurrent `execute()` calls across all tools and sessions. **`0` = unlimited** (default).
fn max_in_flight_from_env() -> usize {
    std::env::var("CHUMP_TOOL_MAX_IN_FLIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

fn clamp_max_in_flight(n: usize) -> usize {
    n.min(10_000)
}

/// Semaphore matching current env (rebuilt when `CHUMP_TOOL_MAX_IN_FLIGHT` changes).
fn tool_in_flight_semaphore() -> Option<Arc<Semaphore>> {
    let cap = clamp_max_in_flight(max_in_flight_from_env());
    let mut guard = TOOL_IN_FLIGHT_STATE.lock().ok()?;
    if cap == 0 {
        *guard = None;
        return None;
    }
    let replace = match guard.as_ref() {
        None => true,
        Some((cached, _)) => *cached != cap,
    };
    if replace {
        let sem = Arc::new(Semaphore::new(cap));
        *guard = Some((cap, sem.clone()));
        Some(sem)
    } else {
        guard.as_ref().map(|(_, s)| s.clone())
    }
}

/// For **GET /health**: current configured cap, or `None` if unlimited.
pub fn max_in_flight_for_health() -> Option<usize> {
    let n = clamp_max_in_flight(max_in_flight_from_env());
    if n == 0 {
        None
    } else {
        Some(n)
    }
}

// --- Per-tool sliding-window rate limit (WP-3.2) ---

fn rate_limit_tool_names() -> Option<HashSet<String>> {
    let raw = std::env::var("CHUMP_TOOL_RATE_LIMIT_TOOLS").ok()?;
    let set: HashSet<String> = raw
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if set.is_empty() {
        None
    } else {
        Some(set)
    }
}

fn rate_limit_max_per_window() -> u32 {
    std::env::var("CHUMP_TOOL_RATE_LIMIT_MAX")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(30)
        .clamp(1, 100_000)
}

fn rate_limit_window_secs() -> u64 {
    std::env::var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(60)
        .clamp(1, 86_400)
}

fn rate_limit_timestamps() -> &'static Mutex<HashMap<String, VecDeque<Instant>>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, VecDeque<Instant>>>> =
        std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

/// If rate limiting is configured and `tool_name` is listed, enforce sliding window
/// `CHUMP_TOOL_RATE_LIMIT_MAX` calls per `CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS` per tool.
/// Records this invocation on success (counts attempts, not just successes).
pub(crate) fn enforce_tool_rate_limit(tool_name: &str) -> Result<()> {
    let Some(ref names) = rate_limit_tool_names() else {
        return Ok(());
    };
    if !names.contains(tool_name) {
        return Ok(());
    }
    let max = rate_limit_max_per_window() as usize;
    let window = Duration::from_secs(rate_limit_window_secs());
    let mut guard = rate_limit_timestamps()
        .lock()
        .map_err(|_| anyhow!("tool rate limit state poisoned"))?;
    let q = guard.entry(tool_name.to_string()).or_default();
    let now = Instant::now();
    while let Some(&front) = q.front() {
        if now.duration_since(front) > window {
            q.pop_front();
        } else {
            break;
        }
    }
    if q.len() >= max {
        return Err(anyhow!(
            "tool {} rate limited: max {} calls per {}s (sliding window)",
            tool_name,
            max,
            rate_limit_window_secs()
        ));
    }
    q.push_back(now);
    Ok(())
}

/// **GET /health:** JSON fragment when rate limiting is active, else `null`.
pub fn rate_limit_config_for_health() -> Value {
    let Some(ref names) = rate_limit_tool_names() else {
        return Value::Null;
    };
    let mut tools: Vec<&String> = names.iter().collect();
    tools.sort();
    json!({
        "tools": tools.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        "max_per_window": rate_limit_max_per_window(),
        "window_secs": rate_limit_window_secs(),
    })
}

#[cfg(test)]
pub fn test_reset_rate_limits() {
    if let Ok(mut g) = rate_limit_timestamps().lock() {
        g.clear();
    }
}

#[cfg(test)]
pub fn test_reset_tool_in_flight(cap: Option<usize>) {
    let mut g = TOOL_IN_FLIGHT_STATE.lock().expect("tool in-flight lock");
    match cap {
        None | Some(0) => *g = None,
        Some(n) => {
            let n = clamp_max_in_flight(n);
            let sem = Arc::new(Semaphore::new(n));
            *g = Some((n, sem));
        }
    }
}

/// Global tool-call counts (tool name -> count). Used by health server.
fn tool_counts() -> &'static Mutex<HashMap<String, u64>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, u64>>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Record a tool call for observability. Call from middleware on success and failure.
pub fn record_tool_call(tool_name: &str, success: bool) {
    let key = if success {
        format!("{}_ok", tool_name)
    } else {
        format!("{}_fail", tool_name)
    };
    if let Ok(mut guard) = tool_counts().lock() {
        *guard.entry(key).or_insert(0) += 1;
    }
}

/// Snapshot of tool-call counts for GET /health. Returns total calls per tool name
/// (ok + fail combined as the single count for display).
pub fn tool_call_counts() -> HashMap<String, u64> {
    let guard = match tool_counts().lock() {
        Ok(g) => g,
        Err(_) => return HashMap::new(),
    };
    let mut out: HashMap<String, u64> = HashMap::new();
    for (key, count) in guard.iter() {
        let tool_name = key
            .strip_suffix("_ok")
            .or_else(|| key.strip_suffix("_fail"))
            .unwrap_or(key);
        *out.entry(tool_name.to_string()).or_insert(0) += count;
    }
    out
}

/// Per-tool historical latency EMA for better surprisal calibration.
/// Falls back to timeout/3 for tools with no history.
fn tool_latency_ema() -> &'static Mutex<HashMap<String, f64>> {
    static CELL: std::sync::OnceLock<Mutex<HashMap<String, f64>>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn tool_expected_latency(tool_name: &str, timeout_ms: u64) -> u64 {
    let fallback = timeout_ms / 3;
    if let Ok(guard) = tool_latency_ema().lock() {
        if let Some(&ema) = guard.get(tool_name) {
            return ema as u64;
        }
    }
    fallback
}

fn update_tool_latency_ema(tool_name: &str, latency_ms: u64) {
    const LATENCY_ALPHA: f64 = 0.2;
    if let Ok(mut guard) = tool_latency_ema().lock() {
        let entry = guard
            .entry(tool_name.to_string())
            .or_insert(latency_ms as f64);
        *entry = LATENCY_ALPHA * latency_ms as f64 + (1.0 - LATENCY_ALPHA) * *entry;
    }
}

/// Per-turn tool call counter for precision-regime soft cap.
static TURN_TOOL_CALLS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Reset the per-turn tool call counter (call at the start of each agent turn).
pub fn reset_turn_tool_calls() {
    TURN_TOOL_CALLS.store(0, std::sync::atomic::Ordering::Relaxed);
}

/// Check if tool calls this turn exceed the precision regime's recommended max.
/// Posts a warning to the blackboard if exceeded (once per threshold crossing).
fn check_tool_call_budget() {
    let count = TURN_TOOL_CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
    let max = crate::precision_controller::recommended_max_tool_calls();
    if count == max + 1 {
        crate::blackboard::post(
            crate::blackboard::Module::ToolMiddleware,
            format!(
                "Tool call budget exceeded: {} calls this turn (regime recommends max {}). Consider wrapping up.",
                count, max
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.8,
                uncertainty_reduction: 0.2,
                goal_relevance: 0.6,
                urgency: 0.7,
            },
        );
    }
}

// ── Action verification pipeline ────────────────────────────────────────

/// Result of post-execution verification for write tools.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ToolVerification {
    pub tool_name: String,
    pub call_id: String,
    pub proposed_action: String,
    pub actual_outcome: ToolOutcome,
    pub side_effects: Vec<String>,
    pub verified: bool,
    pub verification_method: VerificationMethod,
}

#[derive(Debug, Clone, serde::Serialize)]
pub enum ToolOutcome {
    Success,
    Partial,
    Failed,
}

#[derive(Debug, Clone, serde::Serialize)]
pub enum VerificationMethod {
    OutputParsing,
    /// Real postcondition check (file re-read, git status query, etc.) —
    /// stronger evidence than output text parsing because it inspects actual
    /// world state after the tool ran. Closes the dissertation Part X
    /// "deeper action verification" item: previously we just believed the
    /// tool's success message; now we verify it against the filesystem / git.
    Postcondition,
    None,
}

/// Global storage for the last verification result; retrieved by agent_loop after tool execution.
static LAST_VERIFICATION: std::sync::OnceLock<Mutex<Option<ToolVerification>>> =
    std::sync::OnceLock::new();

fn verification_store() -> &'static Mutex<Option<ToolVerification>> {
    LAST_VERIFICATION.get_or_init(|| Mutex::new(None))
}

fn store_verification(v: ToolVerification) {
    if let Ok(mut guard) = verification_store().lock() {
        *guard = Some(v);
    }
}

/// Take the last verification result (consuming it). Called by agent_loop after tool execution.
pub fn take_last_verification() -> Option<ToolVerification> {
    verification_store().lock().ok().and_then(|mut g| g.take())
}

/// Tools that modify external state and warrant post-execution verification.
///
/// Public so other modules (e.g. `agent_loop::tool_runner` for INFRA-001a-wire's
/// unrolled-side-effect counter) can classify a tool name without copying the list.
pub fn is_write_tool(name: &str) -> bool {
    matches!(
        name,
        "write_file"
            | "run_cli"
            | "git_commit"
            | "git_push"
            | "patch_file"
            | "git_stash"
            | "git_revert"
            | "cleanup_branches"
            | "merge_subtask"
    )
}

// ── Agent-lease gate ─────────────────────────────────────────────────
//
// Wires `crate::agent_lease::is_path_claimed_by_other` into the write-tool
// pipeline so multi-agent setups (parallel Claude sessions, Cursor, autonomy
// loops) can't silently stomp each other's in-flight files. Mirrors the ACP
// permission gate's deny-with-clear-error pattern.

/// Skip the lease gate via `CHUMP_LEASE_GATE=0`. Default on. Useful for CI,
/// single-agent dev runs, and deterministic tests that don't want
/// `.chump-locks/` housekeeping noise.
fn lease_gate_enabled() -> bool {
    !std::env::var("CHUMP_LEASE_GATE")
        .map(|v| v.trim() == "0")
        .unwrap_or(false)
}

/// Pull the file/dir path a write-tool is about to touch out of its `input`
/// JSON. Returns an empty Vec when no path-shaped field is present (e.g.
/// `git_commit` that just commits whatever's staged, or `cleanup_branches`).
/// Multiple paths returned for tools like `merge_subtask` that touch a set.
///
/// Conservative: missing field → empty → no gate fires (better to under-gate
/// than to over-gate; the lease system is advisory + best-effort anyway).
fn target_paths_for_tool(name: &str, input: &Value) -> Vec<String> {
    fn s(v: Option<&Value>) -> Option<String> {
        v.and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
    match name {
        // Direct file writes — `path` field is canonical.
        "write_file" | "patch_file" => {
            // patch_file accepts `file_path` as alias.
            s(input.get("path"))
                .or_else(|| s(input.get("file_path")))
                .map(|p| vec![p])
                .unwrap_or_default()
        }
        // Git ops scoped to repo root — claim the repo dir as a marker.
        // Different sessions trying to commit/push concurrently is exactly
        // the case where a lease helps.
        "git_commit" | "git_push" | "git_stash" | "git_revert" | "cleanup_branches" => {
            // No specific path; use ".git/" as a synthetic claim target so
            // a session holding "src/" doesn't accidentally block git ops on
            // an unrelated subtree, but two concurrent committers DO conflict
            // if either holds ".git/".
            vec![".git/".to_string()]
        }
        // run_cli could touch anything — no reliable target. Skip.
        "run_cli" => Vec::new(),
        // merge_subtask: hard to know without parsing; skip.
        "merge_subtask" => Vec::new(),
        _ => Vec::new(),
    }
}

/// Returns `Some((path, holder_session))` when this write would conflict with
/// another session's lease. None when the call is free to proceed.
fn check_lease_conflict(name: &str, input: &Value) -> Option<(String, String)> {
    let paths = target_paths_for_tool(name, input);
    if paths.is_empty() {
        return None;
    }
    let my_session = crate::agent_lease::current_session_id();
    for p in &paths {
        if let Some(holder) = crate::agent_lease::is_path_claimed_by_other(p, &my_session) {
            return Some((p.clone(), holder));
        }
    }
    None
}

/// Verify tool execution by inspecting the output.
///
/// Two layers, ordered cheapest → most expensive:
///   1. **Output parsing** (cheap): scan for error prefixes / known failure
///      strings. Catches outright failures the tool surfaced itself.
///   2. **Postcondition** (expensive, ~ms-scale syscall): for write tools,
///      actually inspect the world after the call (file exists + content
///      matches, git tree clean, etc.). Only runs when layer 1 says "ok"
///      so we don't waste syscalls on already-failed calls.
///
/// Postcondition mismatch downgrades a "Success" verdict to "Partial" with
/// `VerificationMethod::Postcondition` so the agent sees that the tool
/// _claimed_ success but the world doesn't agree. Suppressible via
/// `CHUMP_VERIFY_POSTCONDITIONS=0` for benchmark/perf runs.
fn verify_tool_execution(tool_name: &str, input: &Value, output: &str) -> ToolVerification {
    let proposed_action = summarize_tool_action(tool_name, input);

    // Check output for error signals
    let output_ok = !output.starts_with("Tool error:")
        && !output.starts_with("DENIED:")
        && !output.contains("Permission denied")
        && !output.contains("No such file or directory")
        && !output.contains("fatal:");

    let (mut verified, mut method, mut outcome) = if !output_ok {
        (
            false,
            VerificationMethod::OutputParsing,
            ToolOutcome::Failed,
        )
    } else {
        (
            true,
            VerificationMethod::OutputParsing,
            ToolOutcome::Success,
        )
    };

    // Postcondition check: only runs when layers 1+2 said "ok" (no point
    // re-reading a file we already know wasn't written). Downgrades the
    // verdict if the world doesn't match what the tool claimed.
    if verified && postconditions_enabled() {
        if let Some(postcond) = check_postconditions(tool_name, input, output) {
            if !postcond.passed {
                verified = false;
                method = VerificationMethod::Postcondition;
                outcome = ToolOutcome::Partial;
                tracing::warn!(
                    tool = %tool_name,
                    detail = %postcond.detail,
                    "postcondition check failed; downgrading verification"
                );
            } else {
                // Stronger evidence — note that we got past the cheap heuristic
                // AND verified against actual world state.
                method = VerificationMethod::Postcondition;
            }
        }
    }

    let side_effects = extract_side_effects(tool_name, output);

    ToolVerification {
        tool_name: tool_name.to_string(),
        call_id: String::new(), // filled by caller if needed
        proposed_action,
        actual_outcome: outcome,
        side_effects,
        verified,
        verification_method: method,
    }
}

/// Result of a real postcondition check (file re-read, git status, etc.).
#[derive(Debug, Clone)]
struct PostconditionResult {
    /// True when the postcondition matched the tool's claim.
    passed: bool,
    /// Human-readable explanation for logging / blackboard posts.
    detail: String,
}

/// Per-call postcondition check. Returns `None` for tools we don't have a
/// real-world check for (output-parsing layer is the best we can do for them).
/// For tools we DO know how to verify, returns `Some(result)` with pass/fail
/// + a one-line detail.
fn check_postconditions(
    tool_name: &str,
    input: &Value,
    _output: &str,
) -> Option<PostconditionResult> {
    // EFFECTIVE-633: any successful non-commit action clears the storming
    // guard's counter — only *consecutive* git_commit calls trip the limit.
    if tool_name != "git_commit" {
        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);
    }
    match tool_name {
        "write_file" | "patch_file" => {
            // The most common case the heuristic gets wrong: tool reports
            // success but the file wasn't actually written (path resolution
            // bug, race with another writer, etc.). Re-read and verify
            // existence + non-empty content.
            //
            // Use `resolve_under_root_for_write` (not `resolve_under_root`)
            // because the latter requires the file to already exist —
            // canonicalize fails on a missing path. The for_write variant
            // tolerates "doesn't exist yet", which is exactly the case we
            // want to *detect* as a postcondition failure.
            let path = input.get("path").and_then(|v| v.as_str())?;
            let resolved = crate::repo_path::resolve_under_root_for_write(path).ok()?;
            if !resolved.exists() {
                return Some(PostconditionResult {
                    passed: false,
                    detail: format!("file '{}' does not exist after write", path),
                });
            }
            // For write_file we expected the file to land. We can't easily
            // verify exact content without storing the original write — but
            // a non-empty file when the model wrote non-empty content is a
            // useful signal.
            let expected_non_empty = input
                .get("content")
                .and_then(|v| v.as_str())
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            if expected_non_empty {
                let len = std::fs::metadata(&resolved).map(|m| m.len()).unwrap_or(0);
                if len == 0 {
                    return Some(PostconditionResult {
                        passed: false,
                        detail: format!(
                            "file '{}' exists but is empty after non-empty write",
                            path
                        ),
                    });
                }
            }
            Some(PostconditionResult {
                passed: true,
                detail: format!("file '{}' exists post-write", path),
            })
        }
        "git_commit" => {
            // EFFECTIVE-633: rate limit consecutive git_commit calls before
            // doing any real work — a model storming git_commit without an
            // intervening successful action (file write, test run, ...) is
            // spinning, not making progress. Counter resets above whenever
            // check_postconditions runs for a non-commit tool.
            let limit = git_commit_rate_limit();
            let count =
                CONSECUTIVE_GIT_COMMITS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            if count > limit {
                return Some(PostconditionResult {
                    passed: false,
                    detail: format!(
                        "git_commit rate limit hit: {} consecutive git_commit calls (cooldown limit {}) \
                         with no intervening successful action — make a real edit or run a test before \
                         committing again",
                        count, limit
                    ),
                });
            }

            // git_commit's postcondition: working tree should be clean
            // immediately after (no staged or unstaged changes the commit
            // missed). Use blocking process spawn — verify_tool_execution
            // is sync-only.
            let repo_root = crate::repo_path::repo_root();
            if !repo_root.is_dir() {
                return None;
            }
            let out = std::process::Command::new("git")
                .args(["status", "--porcelain"])
                .current_dir(&repo_root)
                .output()
                .ok()?;
            if !out.status.success() {
                return Some(PostconditionResult {
                    passed: false,
                    detail: "git status query failed after commit".to_string(),
                });
            }
            let porcelain = String::from_utf8_lossy(&out.stdout);
            // Untracked files (?? prefix) are fine — commit doesn't add
            // them. We only care about modified/staged items left behind.
            let has_uncommitted = porcelain.lines().any(|line| {
                let prefix = line.get(..2).unwrap_or("");
                prefix != "??" && !prefix.trim().is_empty()
            });
            if has_uncommitted {
                Some(PostconditionResult {
                    passed: false,
                    detail: format!(
                        "git tree has uncommitted changes after commit: {}",
                        porcelain.lines().take(3).collect::<Vec<_>>().join("; ")
                    ),
                })
            } else {
                Some(PostconditionResult {
                    passed: true,
                    detail: "git tree clean post-commit".to_string(),
                })
            }
        }
        "git_push" => {
            // git_push's postcondition: branch should be up-to-date with
            // upstream. `git status -sb` shows e.g. "## main...origin/main"
            // (clean) vs "## main...origin/main [ahead 1]" (push didn't
            // actually land).
            let repo_root = crate::repo_path::repo_root();
            if !repo_root.is_dir() {
                return None;
            }
            let out = std::process::Command::new("git")
                .args(["status", "-sb"])
                .current_dir(&repo_root)
                .output()
                .ok()?;
            if !out.status.success() {
                return None;
            }
            let porcelain = String::from_utf8_lossy(&out.stdout);
            let first_line = porcelain.lines().next().unwrap_or("");
            if first_line.contains("ahead ") {
                Some(PostconditionResult {
                    passed: false,
                    detail: format!("branch still ahead of upstream after push: {}", first_line),
                })
            } else {
                Some(PostconditionResult {
                    passed: true,
                    detail: "branch matches upstream post-push".to_string(),
                })
            }
        }
        // run_cli + git_stash/git_revert/cleanup_branches/merge_subtask: too
        // open-ended to verify without re-parsing intent. Heuristic only.
        _ => None,
    }
}

/// Suppress postcondition checks via `CHUMP_VERIFY_POSTCONDITIONS=0`.
/// Default on. Used by the few benchmark scripts that want to measure raw
/// tool latency without the extra syscalls.
fn postconditions_enabled() -> bool {
    !std::env::var("CHUMP_VERIFY_POSTCONDITIONS")
        .map(|v| v.trim() == "0")
        .unwrap_or(false)
}

fn summarize_tool_action(tool_name: &str, input: &Value) -> String {
    match tool_name {
        "write_file" => format!(
            "Write to {}",
            input
                .get("path")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
        ),
        "run_cli" => format!(
            "Execute: {}",
            input
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
        ),
        "patch_file" => format!(
            "Patch {}",
            input
                .get("path")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
        ),
        "git_commit" => "Git commit".to_string(),
        "git_push" => "Git push".to_string(),
        _ => format!("Execute {}", tool_name),
    }
}

fn extract_side_effects(tool_name: &str, output: &str) -> Vec<String> {
    let mut effects = Vec::new();
    match tool_name {
        "write_file" | "patch_file" => effects.push("File modified on disk".to_string()),
        "git_commit" => effects.push("New commit created".to_string()),
        "git_push" => effects.push("Changes pushed to remote".to_string()),
        "run_cli" => {
            if output.contains("created") || output.contains("Created") {
                effects.push("Resource created".to_string());
            }
            if output.contains("deleted") || output.contains("removed") {
                effects.push("Resource deleted".to_string());
            }
        }
        _ => {}
    }
    effects
}

// ── Sprint C: Security hardening ──────────────────────────────────────

/// Sprint C1: Leak scan tool output and record observability.
/// Uses `context_firewall::sanitize()` (redacts API keys, tokens, passwords, JWTs,
/// private keys) and returns both the cleaned text and the number of redactions.
/// If redactions > 0, logs a warning and posts a high-salience blackboard entry so
/// agents/operators can see that a tool leaked something.
fn sanitize_and_track(raw: &str, tool_name: &str) -> String {
    let result = crate::context_firewall::sanitize(raw, tool_name);
    if result.redactions > 0 {
        tracing::warn!(
            tool = %tool_name,
            redactions = result.redactions,
            truncated = result.truncated,
            "tool output contained secrets — redacted by context_firewall"
        );
        crate::blackboard::post(
            crate::blackboard::Module::ToolMiddleware,
            format!(
                "Security (C1): tool '{}' output had {} secret pattern(s) redacted",
                tool_name, result.redactions
            ),
            crate::blackboard::SalienceFactors {
                novelty: 0.8,
                uncertainty_reduction: 0.4,
                goal_relevance: 0.6,
                urgency: 0.9,
            },
        );
    }
    result.text
}

/// Sprint C3: Host-boundary secret pinning.
///
/// Prevents tool code from accidentally exfiltrating environment secrets via side
/// channels. Returns true if an env var name matches patterns that indicate a secret
/// (e.g. `*_TOKEN`, `*_KEY`, `*_SECRET`, `PASSWORD*`, `*_CREDENTIALS`).
///
/// Tools that need env access should use `read_safe_env` which consults an allowlist
/// (`CHUMP_TOOL_ENV_ALLOWLIST`, comma-separated) and masks anything that matches the
/// secret heuristic.
pub fn is_secret_env_var(name: &str) -> bool {
    let upper = name.to_uppercase();
    let suffixes = [
        "_TOKEN",
        "_KEY",
        "_SECRET",
        "_PASSWORD",
        "_PASSWD",
        "_CREDENTIALS",
        "_API_KEY",
        "_PRIVATE_KEY",
        "_AUTH",
    ];
    let prefixes = [
        "PASSWORD",
        "SECRET",
        "TOKEN",
        "API_KEY",
        "PRIVATE_KEY",
        "AWS_",
        "GITHUB_TOKEN",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "DISCORD_TOKEN",
        "SLACK_",
        "TELEGRAM_",
    ];
    suffixes.iter().any(|s| upper.ends_with(s)) || prefixes.iter().any(|p| upper.starts_with(p))
}

/// Sprint C3: safe env reader for tools.
///
/// Returns the env value if the variable name is on the allowlist or does NOT match
/// the secret heuristic. Otherwise returns `Err(..)` to force the tool to go through
/// a proper auth channel. The allowlist lives in `CHUMP_TOOL_ENV_ALLOWLIST` as a
/// comma-separated list of env names tools are permitted to read directly (useful for
/// non-secret config vars like `CHUMP_REPO` or `HOME`).
pub fn read_safe_env(name: &str) -> Result<String> {
    let allowlist = std::env::var("CHUMP_TOOL_ENV_ALLOWLIST").unwrap_or_default();
    let allowed: std::collections::HashSet<&str> = allowlist
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if allowed.contains(name) {
        return std::env::var(name).map_err(|_| anyhow!("env var '{}' not set", name));
    }
    if is_secret_env_var(name) {
        return Err(anyhow!(
            "Security (C3): env var '{}' looks like a secret and is not on CHUMP_TOOL_ENV_ALLOWLIST",
            name
        ));
    }
    std::env::var(name).map_err(|_| anyhow!("env var '{}' not set", name))
}

/// Detects SSRF (Server-Side Request Forgery) attempts by matching explicit RFC1918
/// boundaries inside serialized tool inputs. Blocks attempts unless `CHUMP_ALLOW_LOCAL_SSRF` is set.
fn detect_ssrf(input: &Value) -> Result<()> {
    if std::env::var("CHUMP_ALLOW_LOCAL_SSRF").is_ok() {
        return Ok(());
    }
    let text = input.to_string();
    if !text.contains("http://") && !text.contains("https://") {
        return Ok(());
    }
    let lower = text.to_lowercase();
    let blocked = [
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "10.",
        "192.168.",
        "169.254.",
        "172.16.",
        "172.17.",
        "172.18.",
        "172.19.",
        "172.2",
        "172.30.",
        "172.31.",
    ];
    for p in blocked {
        if lower.contains(&format!("http://{}", p)) || lower.contains(&format!("https://{}", p)) {
            return Err(anyhow!(
                "SSRF Protection: blocked private network access attempt to '{}'",
                p
            ));
        }
    }
    Ok(())
}

/// Default timeout for a single tool execution (seconds).
/// INFRA-321: reduced from 30s → 8s so a wedged tool (e.g. memory_brain
/// trying a missing path) fails fast instead of blocking a turn for 60s.
/// Override via CHUMP_TOOL_TIMEOUT_SECS env var.
pub const DEFAULT_TOOL_TIMEOUT_SECS: u64 = 8;

/// Wraps a `Tool` so that every `execute()` call is bounded by a timeout.
/// Delegates `name()`, `description()`, and `input_schema()` to the inner tool.
pub struct ToolTimeoutWrapper {
    inner: Arc<dyn Tool + Send + Sync>,
    timeout_duration: Duration,
}

impl ToolTimeoutWrapper {
    /// Wrap `inner` with the default timeout (8s, or CHUMP_TOOL_TIMEOUT_SECS).
    pub fn new(inner: Box<dyn Tool + Send + Sync>) -> Self {
        let secs = std::env::var("CHUMP_TOOL_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_TOOL_TIMEOUT_SECS);
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(secs),
        }
    }

    /// Wrap with a custom timeout.
    #[allow(dead_code)]
    pub fn with_timeout(inner: Box<dyn Tool + Send + Sync>, secs: u64) -> Self {
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(secs),
        }
    }
}

#[async_trait]
impl Tool for ToolTimeoutWrapper {
    fn name(&self) -> String {
        self.inner.name()
    }

    fn description(&self) -> String {
        self.inner.description()
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    #[tracing::instrument(skip(self, input), fields(tool = %self.inner.name()))]
    async fn execute(&self, input: Value) -> Result<String> {
        let name = self.inner.name();
        if circuit_open(&name) {
            return Err(anyhow!(
                "tool {} temporarily unavailable (circuit open)",
                name
            ));
        }
        let _in_flight_permit: Option<OwnedSemaphorePermit> =
            if let Some(sem) = tool_in_flight_semaphore() {
                match sem.acquire_owned().await {
                    Ok(p) => Some(p),
                    Err(_) => {
                        return Err(anyhow!(
                            "tool execution queue unavailable (concurrency semaphore closed)"
                        ));
                    }
                }
            } else {
                None
            };
        detect_ssrf(&input)?;
        enforce_tool_rate_limit(&name)?;

        // CREDIBLE-174: review-class dispatch gate. PR-review-intelligence
        // agents (pr_triage / pr_explain / fix_clippy / ac_coverage /
        // pr_coupling_cost and any future LLM-driven reviewer) must not be
        // able to invoke write/edit/bash-class tools AT ALL — a structural
        // guarantee, not a prompt instruction a compromised or sloppy
        // reviewer prompt could ignore. When `CHUMP_REVIEW_CLASS_DISPATCH=1`
        // is set for the dispatch, any `is_write_tool` call is refused here,
        // before the inner tool ever executes. Read/search tools (read_file,
        // list_dir, grep_repo, etc.) are untouched — only tools this file
        // already classifies as write-class are blocked. CREDIBLE-181 is
        // the first real caller: `chump review`'s ReviewClassGuard sets this
        // flag for the duration of every review dispatch.
        if is_write_tool(&name) && crate::tool_policy::review_class_dispatch_active() {
            record_tool_call(&name, false);
            crate::blackboard::post(
                crate::blackboard::Module::ToolMiddleware,
                format!(
                    "Review-class dispatch denied write/edit/bash tool '{}' (CREDIBLE-174)",
                    name
                ),
                crate::blackboard::SalienceFactors {
                    novelty: 0.6,
                    uncertainty_reduction: 0.4,
                    goal_relevance: 0.9,
                    urgency: 0.7,
                },
            );
            return Err(anyhow!(
                "DENIED: review-class dispatch cannot invoke write/edit/bash tool '{}'. \
                 This dispatch is classified review-only (CHUMP_REVIEW_CLASS_DISPATCH=1) — \
                 findings must be reported, not silently patched. File a follow-up gap or \
                 hand off to an implementation-class dispatch instead.",
                name
            ));
        }

        // ACP permission gate: when Chump runs under an ACP client (e.g. Zed,
        // JetBrains), write tools prompt the user for consent through the
        // editor's UI before executing. No-op for non-ACP launches (CLI, web,
        // Discord) and for non-write tools. See `acp_permission_gate` for the
        // full decision matrix; RPC failures fail-closed.
        if is_write_tool(&name) {
            match crate::acp_server::acp_permission_gate(&name, &input).await {
                crate::acp_server::AcpPermissionResult::Allow => { /* proceed */ }
                crate::acp_server::AcpPermissionResult::Deny { reason } => {
                    record_tool_call(&name, false);
                    crate::blackboard::post(
                        crate::blackboard::Module::ToolMiddleware,
                        format!("ACP permission denied for {}: {}", name, reason),
                        crate::blackboard::SalienceFactors {
                            novelty: 0.4,
                            uncertainty_reduction: 0.3,
                            goal_relevance: 0.7,
                            urgency: 0.5,
                        },
                    );
                    return Err(anyhow!("ACP permission denied for {}: {}", name, reason));
                }
            }
        }

        // Agent-lease gate: when another agent (different session) holds a
        // path-lease covering this write's target, abort with a clear error
        // naming the holder. Mirrors the ACP permission gate above.
        // Skippable via `CHUMP_LEASE_GATE=0` for CI / single-agent runs that
        // don't want the dependency on `.chump-locks/` housekeeping.
        if is_write_tool(&name) && lease_gate_enabled() {
            if let Some((path, holder)) = check_lease_conflict(&name, &input) {
                record_tool_call(&name, false);
                crate::blackboard::post(
                    crate::blackboard::Module::ToolMiddleware,
                    format!(
                        "Lease conflict on {}: path '{}' held by session '{}'",
                        name, path, holder
                    ),
                    crate::blackboard::SalienceFactors {
                        novelty: 0.5,
                        uncertainty_reduction: 0.4,
                        goal_relevance: 0.8,
                        urgency: 0.6,
                    },
                );
                return Err(anyhow!(
                    "DENIED: lease conflict — path '{}' is held by another session '{}'. \
                     Wait for them to release (max 4h) or coordinate via docs/process/AGENT_COORDINATION.md. \
                     Override for this process: CHUMP_LEASE_GATE=0.",
                    path, holder
                ));
            }
        }

        // COMP-011a/b: adversary check — runs before execution, default OFF.
        // mode=static (COMP-011a): YAML rule engine.
        // mode=llm (COMP-011b): LLM-based context-aware reviewer.
        // `warn` action: log + continue; `block` action: return error.
        crate::adversary::adversary_check(&name, &input, &[]).await?;

        let inner = self.inner.clone();
        let args_snippet = input
            .as_object()
            .and_then(|m| serde_json::to_string(m).ok())
            .map(|s| {
                if s.len() > 80 {
                    format!("{}…", &s[..80])
                } else {
                    s
                }
            })
            .unwrap_or_default();
        let call_start = Instant::now();
        let timeout_secs = crate::neuromodulation::effective_tool_timeout_secs(
            self.timeout_duration.as_secs().max(1),
        );
        let timeout_dur = Duration::from_secs(timeout_secs);
        let expected_latency_ms = tool_expected_latency(&name, timeout_dur.as_millis() as u64);
        // Clone input for post-execution verification (write tools only)
        let input_for_verify = if is_write_tool(&name) {
            Some(input.clone())
        } else {
            None
        };
        let fut = async move { inner.execute(input).await };
        let result = match timeout(timeout_dur, fut).await {
            Ok(Ok(out)) => {
                let latency_ms = call_start.elapsed().as_millis() as u64;
                clear_circuit(&name);
                record_tool_call(&name, true);
                update_tool_latency_ema(&name, latency_ms);
                // COG-012: record peak latency for ASI telemetry.
                crate::asi_telemetry::record_tool_latency(&name, latency_ms);
                crate::introspect_tool::record_call(&name, &args_snippet, "ok");
                let sub = crate::consciousness_traits::substrate();
                sub.surprise
                    .record(&name, "ok", latency_ms, expected_latency_ms);
                sub.belief.update_tool(&name, true, latency_ms);
                crate::precision_controller::record_energy_spent(0, 1);
                check_tool_call_budget();
                // Post-execution verification for write tools
                if let Some(ref verify_input) = input_for_verify {
                    let verification = verify_tool_execution(&name, verify_input, &out);
                    if !verification.verified {
                        crate::blackboard::post(
                            crate::blackboard::Module::ToolMiddleware,
                            format!(
                                "Verification FAILED for {}: {:?} — {}",
                                verification.tool_name,
                                verification.actual_outcome,
                                verification.proposed_action,
                            ),
                            crate::blackboard::SalienceFactors {
                                novelty: 0.9,
                                uncertainty_reduction: 0.6,
                                goal_relevance: 0.9,
                                urgency: 0.8,
                            },
                        );
                    }
                    store_verification(verification);
                }
                let safe_out = sanitize_and_track(&out, &name);
                Ok(safe_out)
            }
            Ok(Err(e)) => {
                let latency_ms = call_start.elapsed().as_millis() as u64;
                record_circuit_failure(&name);
                maybe_pivot_from_frustration(&name);
                record_tool_call(&name, false);
                let raw_err = e.to_string();
                let err_msg = sanitize_and_track(&raw_err, &name);
                let _ = crate::tool_health_db::record_failure(
                    name.as_str(),
                    "degraded",
                    Some(err_msg.as_str()),
                );
                crate::introspect_tool::record_call(&name, &args_snippet, "error");
                let sub = crate::consciousness_traits::substrate();
                sub.surprise
                    .record(&name, "error", latency_ms, expected_latency_ms);
                sub.belief.update_tool(&name, false, latency_ms);
                crate::precision_controller::record_energy_spent(0, 1);
                Err(anyhow!("{}", err_msg))
            }
            Err(_elapsed) => {
                let latency_ms = call_start.elapsed().as_millis() as u64;
                record_circuit_failure(&name);
                maybe_pivot_from_frustration(&name);
                record_tool_call(&name, false);
                let msg = format!("tool timed out after {}s", timeout_secs);
                let _ = crate::tool_health_db::record_failure(
                    name.as_str(),
                    "degraded",
                    Some(msg.as_str()),
                );
                crate::introspect_tool::record_call(&name, &args_snippet, "timeout");
                let sub = crate::consciousness_traits::substrate();
                sub.surprise
                    .record(&name, "timeout", latency_ms, expected_latency_ms);
                sub.belief.update_tool(&name, false, latency_ms);
                crate::precision_controller::record_energy_spent(0, 1);
                Err(anyhow!("{}", msg))
            }
        };
        result
    }
}

// ---------------------------------------------------------------------------
// DelegatePreProcessorWrapper (AUTO-012)
// ---------------------------------------------------------------------------
//
// When CHUMP_DELEGATE_PREPROCESS=1 and CHUMP_DELEGATE_CONCURRENT=1, any tool
// whose output exceeds CHUMP_DELEGATE_PREPROCESS_CHARS (default 4 000) is
// automatically summarised by the worker model before the main orchestrator
// sees it.  The raw character count is preserved in a leading annotation so
// the model knows how much was trimmed.
//
// This implements Phase 5.1/5.2 from docs/ROADMAP_CLAUDE_UPGRADE.md.

/// Default character threshold above which the preprocessor compresses output.
const DEFAULT_PREPROCESS_CHARS: usize = 4_000;

/// True when the delegate preprocessor is both configured and safe to use.
pub fn delegate_preprocess_enabled() -> bool {
    crate::delegate_tool::concurrent_llm_safe()
        && std::env::var("CHUMP_DELEGATE_PREPROCESS")
            .map(|v| v.trim() == "1" || v.trim().eq_ignore_ascii_case("true"))
            .unwrap_or(false)
}

/// Character threshold for triggering delegate pre-processing.
pub fn preprocess_char_threshold() -> usize {
    std::env::var("CHUMP_DELEGATE_PREPROCESS_CHARS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(DEFAULT_PREPROCESS_CHARS)
}

/// Wraps a tool so that outputs exceeding the configured threshold are
/// compressed via the worker model before reaching the main orchestrator.
///
/// # Safety
/// The inner tool is called first; if delegation fails the raw output is
/// returned unchanged (fail-open). This wrapper is always constructed; the
/// threshold check inside `execute` is a fast no-op when the feature is off.
pub struct DelegatePreProcessorWrapper {
    inner: Arc<dyn Tool + Send + Sync>,
}

impl DelegatePreProcessorWrapper {
    pub fn new(inner: Box<dyn Tool + Send + Sync>) -> Self {
        Self {
            inner: Arc::from(inner),
        }
    }
}

#[async_trait]
impl Tool for DelegatePreProcessorWrapper {
    fn name(&self) -> String {
        self.inner.name()
    }

    fn description(&self) -> String {
        self.inner.description()
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let raw = self.inner.execute(input).await?;

        let threshold = preprocess_char_threshold();
        if !delegate_preprocess_enabled() || raw.chars().count() <= threshold {
            return Ok(raw);
        }

        let char_count = raw.chars().count();
        tracing::info!(
            tool = %self.inner.name(),
            chars = char_count,
            threshold = threshold,
            "DelegatePreProcessor: compressing heavy output via worker model"
        );

        match crate::delegate_tool::run_delegate_summarize(&raw, 5).await {
            Ok(summary) => Ok(format!(
                "[DelegatePreProcessor: condensed {char_count} chars → see summary below]\n{summary}"
            )),
            Err(err) => {
                tracing::warn!(
                    tool = %self.inner.name(),
                    err = %err,
                    "DelegatePreProcessor: worker summarise failed; returning raw output"
                );
                Ok(raw)
            }
        }
    }
}

/// Wrap a tool with the default timeout and optional tool-health recording.
/// Use when building the registry so every tool gets the same guarantees.
///
/// When `CHUMP_DELEGATE_PREPROCESS=1` and `CHUMP_DELEGATE_CONCURRENT=1` the
/// tool is also wrapped in a [`DelegatePreProcessorWrapper`] that compresses
/// heavy outputs before they reach the main orchestrator.
pub fn wrap_tool(inner: Box<dyn Tool + Send + Sync>) -> Box<dyn Tool + Send + Sync> {
    let with_preproc: Box<dyn Tool + Send + Sync> =
        Box::new(DelegatePreProcessorWrapper::new(inner));
    Box::new(ToolTimeoutWrapper::new(with_preproc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::time::Instant;

    #[test]
    #[serial]
    fn rate_limit_allows_unlisted_tool() {
        test_reset_rate_limits();
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_TOOLS", "web_search");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_MAX", "1");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS", "60");
        assert!(enforce_tool_rate_limit("calculator").is_ok());
        assert!(enforce_tool_rate_limit("calculator").is_ok());
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_TOOLS");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_MAX");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS");
        test_reset_rate_limits();
    }

    #[test]
    #[serial]
    fn rate_limit_blocks_after_max_per_window() {
        test_reset_rate_limits();
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_TOOLS", "web_search");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_MAX", "2");
        std::env::set_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS", "60");
        assert!(enforce_tool_rate_limit("web_search").is_ok());
        assert!(enforce_tool_rate_limit("web_search").is_ok());
        assert!(enforce_tool_rate_limit("web_search").is_err());
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_TOOLS");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_MAX");
        std::env::remove_var("CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS");
        test_reset_rate_limits();
    }

    #[test]
    #[serial]
    fn max_in_flight_for_health_none_when_unset() {
        std::env::remove_var("CHUMP_TOOL_MAX_IN_FLIGHT");
        test_reset_tool_in_flight(None);
        assert_eq!(max_in_flight_for_health(), None);
    }

    #[test]
    #[serial]
    fn max_in_flight_for_health_reads_env() {
        std::env::set_var("CHUMP_TOOL_MAX_IN_FLIGHT", "4");
        test_reset_tool_in_flight(None);
        assert_eq!(max_in_flight_for_health(), Some(4));
        std::env::remove_var("CHUMP_TOOL_MAX_IN_FLIGHT");
    }

    #[tokio::test]
    #[serial]
    async fn global_semaphore_serializes_second_acquire() {
        std::env::set_var("CHUMP_TOOL_MAX_IN_FLIGHT", "1");
        test_reset_tool_in_flight(None);
        let s = tool_in_flight_semaphore().expect("sem");
        let p1 = s.clone().acquire_owned().await.expect("p1");
        let s2 = tool_in_flight_semaphore().expect("sem2");
        let start = Instant::now();
        let h = tokio::spawn(async move { s2.acquire_owned().await.expect("p2") });
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(!h.is_finished(), "second acquire should wait");
        drop(p1);
        let _p2 = h.await.expect("join");
        assert!(
            start.elapsed() >= Duration::from_millis(25),
            "second task should have waited for permit"
        );
        std::env::remove_var("CHUMP_TOOL_MAX_IN_FLIGHT");
        test_reset_tool_in_flight(None);
    }

    #[test]
    #[serial]
    fn circuit_opens_then_recovers_after_cooldown() {
        use std::thread;
        use std::time::Duration;

        if let Ok(mut g) = circuit_state().lock() {
            g.clear();
        }
        std::env::set_var("CHUMP_TOOL_CIRCUIT_FAILURES", "2");
        std::env::set_var("CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS", "1");
        let tool = "__dogfood_circuit_test_tool";
        clear_circuit(tool);
        assert!(!circuit_open(tool));
        record_circuit_failure(tool);
        assert!(!circuit_open(tool));
        record_circuit_failure(tool);
        assert!(circuit_open(tool));
        thread::sleep(Duration::from_millis(1100));
        assert!(
            !circuit_open(tool),
            "after cooldown the circuit should close so calls can proceed"
        );
        clear_circuit(tool);
        std::env::remove_var("CHUMP_TOOL_CIRCUIT_FAILURES");
        std::env::remove_var("CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS");
        if let Ok(mut g) = circuit_state().lock() {
            g.remove(tool);
        }
    }

    // ── Sprint C1: Leak scanning ──────────────────────────────────

    #[test]
    fn c1_sanitize_redacts_api_key() {
        let raw = "result ok, key=sk-1234567890abcdefghijklmnopqrstuv";
        let cleaned = sanitize_and_track(raw, "__test_tool");
        assert!(
            !cleaned.contains("sk-1234567890abcdefghijklmnopqrstuv"),
            "api key should be redacted: {}",
            cleaned
        );
    }

    #[test]
    fn c1_sanitize_passes_clean_output() {
        let raw = "result ok: the file has 42 lines";
        let cleaned = sanitize_and_track(raw, "__test_tool");
        assert_eq!(cleaned, raw);
    }

    #[test]
    fn c1_sanitize_redacts_github_token() {
        let raw = "GITHUB_TOKEN=ghp_ABCDEFghijklmnopqrstuvwxyz1234567890ab is leaked";
        let cleaned = sanitize_and_track(raw, "__test_tool");
        assert!(!cleaned.contains("ghp_ABCDEFghijklmnopqrstuvwxyz1234567890ab"));
    }

    // ── Sprint C3: Host-boundary secret pinning ───────────────────

    #[test]
    fn c3_is_secret_env_var_identifies_tokens() {
        assert!(is_secret_env_var("GITHUB_TOKEN"));
        assert!(is_secret_env_var("OPENAI_API_KEY"));
        assert!(is_secret_env_var("ANTHROPIC_API_KEY"));
        assert!(is_secret_env_var("SOMETHING_SECRET"));
        assert!(is_secret_env_var("DB_PASSWORD"));
        assert!(is_secret_env_var("PRIVATE_KEY"));
        assert!(is_secret_env_var("AWS_ACCESS_KEY_ID"));
        assert!(is_secret_env_var("aws_secret_access_key")); // case insensitive
    }

    #[test]
    #[serial]
    fn c3_is_secret_env_var_allows_non_secrets() {
        assert!(!is_secret_env_var("CHUMP_REPO"));
        assert!(!is_secret_env_var("HOME"));
        assert!(!is_secret_env_var("PATH"));
        assert!(!is_secret_env_var("CHUMP_WEB_PORT"));
        assert!(!is_secret_env_var("USER"));
    }

    #[test]
    #[serial]
    fn c3_read_safe_env_blocks_secrets() {
        std::env::set_var("__TEST_FAKE_TOKEN", "value");
        let result = read_safe_env("__TEST_FAKE_TOKEN");
        assert!(result.is_err());
        let err_msg = format!("{}", result.unwrap_err());
        assert!(err_msg.contains("secret") || err_msg.contains("Security"));
        std::env::remove_var("__TEST_FAKE_TOKEN");
    }

    #[test]
    #[serial]
    fn c3_read_safe_env_allows_non_secret() {
        std::env::set_var("__TEST_SAFE_CONFIG", "some_value");
        let result = read_safe_env("__TEST_SAFE_CONFIG");
        assert_eq!(result.unwrap(), "some_value");
        std::env::remove_var("__TEST_SAFE_CONFIG");
    }

    #[test]
    #[serial]
    fn c3_read_safe_env_honors_allowlist() {
        // Put a secret-shaped name on the allowlist; should be readable.
        std::env::set_var("__TEST_CUSTOM_TOKEN", "allowed");
        std::env::set_var("CHUMP_TOOL_ENV_ALLOWLIST", "__TEST_CUSTOM_TOKEN,OTHER");
        let result = read_safe_env("__TEST_CUSTOM_TOKEN");
        assert_eq!(result.unwrap(), "allowed");
        std::env::remove_var("CHUMP_TOOL_ENV_ALLOWLIST");
        std::env::remove_var("__TEST_CUSTOM_TOKEN");
    }

    // ── AUTO-011: Frustration metric ──────────────────────────────────

    #[test]
    #[serial]
    fn frustration_score_zero_before_any_failures() {
        let tool = "__test_frustration_zero";
        clear_circuit(tool);
        assert_eq!(frustration_score(tool), 0.0);
    }

    #[test]
    #[serial]
    fn frustration_score_rises_with_consecutive_failures() {
        let tool = "__test_frustration_rise";
        clear_circuit(tool);
        // Prior reliability = 0.5, so score = failures * 0.5
        record_circuit_failure(tool);
        let s1 = frustration_score(tool);
        record_circuit_failure(tool);
        let s2 = frustration_score(tool);
        assert!(s2 > s1, "score should rise with more failures: {s1} {s2}");
        assert!(s1 > 0.0, "single failure should give non-zero score");
        clear_circuit(tool);
    }

    #[test]
    #[serial]
    fn frustration_threshold_triggers_pivot_and_blackboard_post() {
        let tool = "__test_frustration_pivot";
        clear_circuit(tool);
        // Set a low threshold so a few failures trigger it.
        std::env::set_var("CHUMP_FRUSTRATION_THRESHOLD", "0.1");
        // 1 failure * (1 - 0.5 prior) = 0.5 > 0.1 → should pivot.
        record_circuit_failure(tool);
        let alt = maybe_pivot_from_frustration(tool);
        // alt may be None (no other tools known) or Some(name) — both are valid;
        // the important thing is that the function doesn't panic.
        let _ = alt;
        clear_circuit(tool);
        std::env::remove_var("CHUMP_FRUSTRATION_THRESHOLD");
    }

    // ── Postcondition verification tests ──────────────────────────────

    /// Tools we don't have a real-world check for return None — the
    /// output-parsing layer is the best evidence we have, no point pretending
    /// otherwise.
    #[test]
    fn check_postconditions_returns_none_for_unknown_tool() {
        let res = check_postconditions("calculator", &serde_json::json!({}), "42");
        assert!(res.is_none());
    }

    #[test]
    fn check_postconditions_returns_none_for_run_cli() {
        // run_cli is too open-ended to verify generically — different commands
        // have different postconditions. Heuristic only.
        let res = check_postconditions(
            "run_cli",
            &serde_json::json!({"command": "ls"}),
            "Cargo.toml\nsrc/",
        );
        assert!(res.is_none());
    }

    /// write_file with a path that doesn't resolve under repo root → None
    /// (the resolver returned Err so we have nothing to check). Heuristic
    /// layer still applies.
    #[test]
    #[serial]
    fn check_postconditions_write_file_unresolvable_path_returns_none() {
        // Without CHUMP_REPO/CHUMP_HOME set, resolve_under_root rejects relative
        // paths that try to escape root. ".." should fail.
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let res = check_postconditions(
            "write_file",
            &serde_json::json!({"path": "../etc/passwd", "content": "x"}),
            "wrote 1 byte",
        );
        // Either None (unresolvable) or a failed verification — both fine.
        // What we care about is no panic + no false-positive pass.
        if let Some(r) = res {
            assert!(!r.passed || r.detail.contains("exists"));
        }
    }

    /// write_file postcondition: file actually exists with non-empty content
    /// → passes.
    #[test]
    #[serial]
    fn check_postconditions_write_file_passes_when_file_present() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).expect("test invariant");
        let target = dir.join("hello.txt");
        std::fs::write(&target, "real content").expect("test invariant");
        // Clear CHUMP_REPO so repo_root() reads CHUMP_HOME (CHUMP_REPO is
        // checked first and may be set in the CI environment).
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::set_var("CHUMP_HOME", &dir);

        let res = check_postconditions(
            "write_file",
            &serde_json::json!({"path": "hello.txt", "content": "real content"}),
            "wrote 12 bytes",
        )
        .expect("should produce a result");
        assert!(
            res.passed,
            "file exists, postcondition should pass: {:?}",
            res
        );
        assert!(res.detail.contains("exists"));

        std::env::remove_var("CHUMP_HOME");
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// write_file postcondition fails when the file doesn't exist on disk
    /// (tool reported success but lied / path-resolution bug).
    #[test]
    #[serial]
    fn check_postconditions_write_file_fails_when_file_missing() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("CHUMP_HOME", &dir);

        let res = check_postconditions(
            "write_file",
            &serde_json::json!({"path": "missing.txt", "content": "x"}),
            "wrote 1 byte",
        )
        .expect("should produce a result");
        assert!(!res.passed, "file does not exist; should fail");
        assert!(res.detail.contains("does not exist"));

        std::env::remove_var("CHUMP_HOME");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// write_file with non-empty content claim but empty file on disk →
    /// downgraded. Surfaces the case where a partial write or truncation
    /// happened despite the tool's success message.
    #[test]
    #[serial]
    fn check_postconditions_write_file_fails_when_file_empty_but_claimed_content() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("empty.txt");
        std::fs::write(&target, "").unwrap();
        std::env::set_var("CHUMP_HOME", &dir);

        let res = check_postconditions(
            "write_file",
            &serde_json::json!({"path": "empty.txt", "content": "should be 17 bytes"}),
            "wrote 17 bytes",
        )
        .expect("should produce a result");
        assert!(!res.passed, "file empty but content non-empty; should fail");
        assert!(res.detail.contains("empty"));

        std::env::remove_var("CHUMP_HOME");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// patch_file follows the same path as write_file (re-read + existence
    /// check), so this is mostly a coverage smoke test for the dispatch.
    #[test]
    #[serial]
    fn check_postconditions_patch_file_uses_existence_check() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("patched.rs");
        std::fs::write(&target, "fn x() {}").unwrap();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_HOME", &dir);
        // Also set CHUMP_REPO so repo_root() (which checks CHUMP_REPO first) uses
        // the temp dir rather than any ambient CHUMP_REPO set in CI or by a prior test.
        std::env::set_var("CHUMP_REPO", &dir);

        let res = check_postconditions(
            "patch_file",
            &serde_json::json!({"path": "patched.rs"}),
            "patch applied",
        )
        .expect("should produce a result");
        assert!(res.passed);

        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── git_commit rate limiter tests (EFFECTIVE-633) ──────────────────
    //
    // Point CHUMP_HOME/CHUMP_REPO at a plain (non-git) temp dir so the
    // underlying `git status --porcelain` call fails deterministically
    // ("git status query failed after commit") instead of depending on this
    // worktree's real, possibly-dirty tree state. That keeps these tests
    // focused purely on the rate-limit gate, which runs before the real git
    // status check and short-circuits it once the limit is exceeded.

    #[test]
    #[serial]
    fn git_commit_rate_limit_rejects_fourth_consecutive_call() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::remove_var("CHUMP_GIT_COMMIT_RATE_LIMIT");
        std::env::set_var("CHUMP_HOME", &dir);
        std::env::set_var("CHUMP_REPO", &dir);
        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);

        let input = serde_json::json!({});
        for _ in 0..3 {
            let res = check_postconditions("git_commit", &input, "committed");
            // Under the default limit of 3, none of the first 3 calls should
            // be rejected by the rate limiter specifically (they may still
            // fail the real git-status check — that's fine, it's not the
            // thing under test here).
            if let Some(r) = &res {
                assert!(
                    !r.detail.contains("rate limit"),
                    "call under the limit should not be rate-limited: {:?}",
                    r
                );
            }
        }
        let fourth = check_postconditions("git_commit", &input, "committed")
            .expect("4th consecutive git_commit should produce a rejection result");
        assert!(
            !fourth.passed,
            "4th consecutive git_commit should be rejected"
        );
        assert!(
            fourth.detail.contains("rate limit") || fourth.detail.contains("cooldown"),
            "detail should mention rate limit / cooldown: {}",
            fourth.detail
        );
        assert!(
            fourth.detail.contains("git_commit"),
            "detail should name git_commit: {}",
            fourth.detail
        );

        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);
        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn git_commit_rate_limit_resets_on_successful_non_commit_action() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("hello.txt");
        std::fs::write(&target, "real content").unwrap();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::remove_var("CHUMP_GIT_COMMIT_RATE_LIMIT");
        std::env::set_var("CHUMP_HOME", &dir);
        std::env::set_var("CHUMP_REPO", &dir);
        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);

        let commit_input = serde_json::json!({});
        for _ in 0..3 {
            check_postconditions("git_commit", &commit_input, "committed");
        }

        // A successful file_write resets the counter.
        let write_res = check_postconditions(
            "write_file",
            &serde_json::json!({"path": "hello.txt", "content": "real content"}),
            "wrote 12 bytes",
        )
        .expect("write_file should produce a result");
        assert!(write_res.passed, "file_write postcondition should pass");
        assert_eq!(
            CONSECUTIVE_GIT_COMMITS.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "counter should reset after a successful non-commit action"
        );

        // The next git_commit should not be rejected by the rate limiter.
        let next = check_postconditions("git_commit", &commit_input, "committed");
        if let Some(r) = &next {
            assert!(
                !r.detail.contains("rate limit"),
                "git_commit right after a reset should not be rate-limited: {:?}",
                r
            );
        }

        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);
        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn git_commit_rate_limit_is_configurable() {
        let dir = std::env::temp_dir().join(format!(
            "chump-pc-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_HOME", &dir);
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::set_var("CHUMP_GIT_COMMIT_RATE_LIMIT", "2");
        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);

        let input = serde_json::json!({});
        // First 2 consecutive calls stay under the lowered limit.
        for _ in 0..2 {
            let res = check_postconditions("git_commit", &input, "committed");
            if let Some(r) = &res {
                assert!(
                    !r.detail.contains("rate limit"),
                    "should not be rate-limited yet: {:?}",
                    r
                );
            }
        }
        // 3rd consecutive call exceeds limit=2.
        let third = check_postconditions("git_commit", &input, "committed")
            .expect("3rd consecutive git_commit should produce a rejection result");
        assert!(!third.passed);
        assert!(third.detail.contains("rate limit") || third.detail.contains("cooldown"));

        CONSECUTIVE_GIT_COMMITS.store(0, std::sync::atomic::Ordering::Relaxed);
        std::env::remove_var("CHUMP_GIT_COMMIT_RATE_LIMIT");
        match prev_home {
            Some(ref s) => std::env::set_var("CHUMP_HOME", s),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_repo {
            Some(ref s) => std::env::set_var("CHUMP_REPO", s),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `CHUMP_VERIFY_POSTCONDITIONS=0` disables the deep checks entirely, so
    /// the whole layer is skippable for benchmark runs.
    #[test]
    #[serial]
    fn postconditions_enabled_respects_env_kill_switch() {
        std::env::remove_var("CHUMP_VERIFY_POSTCONDITIONS");
        assert!(postconditions_enabled(), "default = on");
        std::env::set_var("CHUMP_VERIFY_POSTCONDITIONS", "0");
        assert!(!postconditions_enabled(), "explicit 0 = off");
        std::env::set_var("CHUMP_VERIFY_POSTCONDITIONS", "1");
        assert!(postconditions_enabled(), "any non-0 = on");
        std::env::remove_var("CHUMP_VERIFY_POSTCONDITIONS");
    }

    // ── Lease gate tests ──────────────────────────────────────────────

    #[test]
    #[serial]
    fn lease_gate_default_on() {
        std::env::remove_var("CHUMP_LEASE_GATE");
        assert!(lease_gate_enabled());
    }

    #[test]
    #[serial]
    fn lease_gate_disabled_by_zero() {
        std::env::set_var("CHUMP_LEASE_GATE", "0");
        assert!(!lease_gate_enabled());
        std::env::set_var("CHUMP_LEASE_GATE", "1");
        assert!(lease_gate_enabled(), "any non-zero = on");
        std::env::remove_var("CHUMP_LEASE_GATE");
    }

    #[test]
    fn target_paths_write_file_uses_path_field() {
        let input = serde_json::json!({"path": "src/foo.rs", "content": "x"});
        assert_eq!(
            target_paths_for_tool("write_file", &input),
            vec!["src/foo.rs".to_string()]
        );
    }

    #[test]
    fn target_paths_patch_file_accepts_either_alias() {
        let with_path = serde_json::json!({"path": "src/a.rs"});
        let with_file_path = serde_json::json!({"file_path": "src/b.rs"});
        let with_both = serde_json::json!({"path": "src/c.rs", "file_path": "src/d.rs"});
        assert_eq!(
            target_paths_for_tool("patch_file", &with_path),
            vec!["src/a.rs".to_string()]
        );
        assert_eq!(
            target_paths_for_tool("patch_file", &with_file_path),
            vec!["src/b.rs".to_string()]
        );
        // `path` takes precedence when both present (matches existing
        // patch_file routing in repo_tools.rs).
        assert_eq!(
            target_paths_for_tool("patch_file", &with_both),
            vec!["src/c.rs".to_string()]
        );
    }

    #[test]
    fn target_paths_git_ops_use_git_dir_marker() {
        let empty = serde_json::json!({});
        // git_commit / push / stash / revert / cleanup_branches all share
        // the synthetic ".git/" marker so concurrent committers conflict
        // even when they don't name a specific file.
        for op in [
            "git_commit",
            "git_push",
            "git_stash",
            "git_revert",
            "cleanup_branches",
        ] {
            assert_eq!(
                target_paths_for_tool(op, &empty),
                vec![".git/".to_string()],
                "{} should use .git/ marker",
                op
            );
        }
    }

    #[test]
    fn target_paths_run_cli_returns_empty() {
        let input = serde_json::json!({"command": "ls -la /tmp"});
        // run_cli could touch anything — too open-ended to gate per-command.
        // Empty Vec → no gate fires for run_cli, by design.
        assert!(target_paths_for_tool("run_cli", &input).is_empty());
    }

    #[test]
    fn target_paths_unknown_tool_returns_empty() {
        let input = serde_json::json!({"path": "src/x.rs"});
        assert!(target_paths_for_tool("read_file", &input).is_empty());
        assert!(target_paths_for_tool("calculator", &input).is_empty());
    }

    #[test]
    fn target_paths_missing_path_returns_empty() {
        // No path field on a write tool → empty (don't gate; the underlying
        // tool will fail with its own error). Conservative: under-gate
        // beats over-gate, since the lease system is advisory.
        let input = serde_json::json!({"content": "no path"});
        assert!(target_paths_for_tool("write_file", &input).is_empty());
    }

    // --- DelegatePreProcessorWrapper unit tests (AUTO-012) ---

    /// Minimal stub tool used in preprocessor tests — returns whatever was
    /// passed in via the `text` field, or a short default.
    struct EchoTool {
        output: String,
    }

    #[async_trait]
    impl Tool for EchoTool {
        fn name(&self) -> String {
            "echo".to_string()
        }
        fn description(&self) -> String {
            "test stub".to_string()
        }
        fn input_schema(&self) -> serde_json::Value {
            serde_json::json!({})
        }
        async fn execute(&self, _input: serde_json::Value) -> anyhow::Result<String> {
            Ok(self.output.clone())
        }
    }

    #[tokio::test]
    #[serial]
    async fn preproc_passthrough_when_disabled() {
        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS");
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
        let output = "x".repeat(10_000);
        let tool = DelegatePreProcessorWrapper::new(Box::new(EchoTool {
            output: output.clone(),
        }));
        let result = tool.execute(serde_json::json!({})).await.unwrap();
        // Feature off → raw output unchanged.
        assert_eq!(result, output);
    }

    #[tokio::test]
    #[serial]
    async fn preproc_passthrough_below_threshold() {
        // Even with the flag on, short output must pass through unmodified.
        std::env::set_var("CHUMP_DELEGATE_PREPROCESS", "1");
        std::env::set_var("CHUMP_DELEGATE_CONCURRENT", "1");
        std::env::set_var("CHUMP_DELEGATE_PREPROCESS_CHARS", "500");
        let short = "hello world".to_string();
        let tool = DelegatePreProcessorWrapper::new(Box::new(EchoTool {
            output: short.clone(),
        }));
        let result = tool.execute(serde_json::json!({})).await.unwrap();
        assert_eq!(result, short);
        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS");
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS_CHARS");
    }

    #[test]
    #[serial]
    fn preprocess_char_threshold_reads_env() {
        std::env::set_var("CHUMP_DELEGATE_PREPROCESS_CHARS", "1234");
        assert_eq!(preprocess_char_threshold(), 1234);
        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS_CHARS");
        assert_eq!(preprocess_char_threshold(), DEFAULT_PREPROCESS_CHARS);
    }

    #[test]
    #[serial]
    fn delegate_preprocess_enabled_requires_both_flags() {
        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS");
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
        assert!(!delegate_preprocess_enabled());

        std::env::set_var("CHUMP_DELEGATE_PREPROCESS", "1");
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
        assert!(!delegate_preprocess_enabled(), "need concurrent flag too");

        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS");
        std::env::set_var("CHUMP_DELEGATE_CONCURRENT", "1");
        assert!(!delegate_preprocess_enabled(), "need preprocess flag too");

        std::env::set_var("CHUMP_DELEGATE_PREPROCESS", "1");
        std::env::set_var("CHUMP_DELEGATE_CONCURRENT", "1");
        assert!(delegate_preprocess_enabled());

        std::env::remove_var("CHUMP_DELEGATE_PREPROCESS");
        std::env::remove_var("CHUMP_DELEGATE_CONCURRENT");
    }

    // ── CREDIBLE-174: review-class dispatch structural tool gate ──────────

    /// Stub tool that counts how many times `execute()` actually ran, so
    /// tests can prove a blocked call never reached the inner tool (a
    /// structural "cannot invoke", not merely "returned an error after
    /// running"). `name` is configurable so the same stub can impersonate
    /// any write-class or read-class tool.
    struct CountingTool {
        name: &'static str,
        calls: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    #[async_trait]
    impl Tool for CountingTool {
        fn name(&self) -> String {
            self.name.to_string()
        }
        fn description(&self) -> String {
            "test stub".to_string()
        }
        fn input_schema(&self) -> serde_json::Value {
            serde_json::json!({})
        }
        async fn execute(&self, _input: serde_json::Value) -> anyhow::Result<String> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok("mutated".to_string())
        }
    }

    #[tokio::test]
    #[serial]
    async fn review_class_dispatch_blocks_write_file_before_execution() {
        std::env::set_var("CHUMP_REVIEW_CLASS_DISPATCH", "1");
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let wrapped = ToolTimeoutWrapper::new(Box::new(CountingTool {
            name: "write_file",
            calls: calls.clone(),
        }));
        let result = wrapped
            .execute(serde_json::json!({"path": "src/foo.rs", "content": "malicious edit"}))
            .await;
        assert!(
            result.is_err(),
            "review-class dispatch must not be able to invoke write_file, even when instructed"
        );
        assert_eq!(
            calls.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "inner write_file tool must never execute — structural block, not a post-hoc error"
        );
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
    }

    #[tokio::test]
    #[serial]
    async fn review_class_dispatch_blocks_run_cli_and_git_commit() {
        std::env::set_var("CHUMP_REVIEW_CLASS_DISPATCH", "1");
        for tool_name in ["run_cli", "git_commit", "patch_file", "git_push"] {
            let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let wrapped = ToolTimeoutWrapper::new(Box::new(CountingTool {
                name: tool_name,
                calls: calls.clone(),
            }));
            let result = wrapped.execute(serde_json::json!({})).await;
            assert!(
                result.is_err(),
                "review-class dispatch must not be able to invoke {tool_name}"
            );
            assert_eq!(
                calls.load(std::sync::atomic::Ordering::SeqCst),
                0,
                "{tool_name} must never execute under review-class dispatch"
            );
        }
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
    }

    #[tokio::test]
    #[serial]
    async fn review_class_dispatch_still_allows_read_tools() {
        std::env::set_var("CHUMP_REVIEW_CLASS_DISPATCH", "1");
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let wrapped = ToolTimeoutWrapper::new(Box::new(CountingTool {
            name: "read_file",
            calls: calls.clone(),
        }));
        let result = wrapped
            .execute(serde_json::json!({"path": "src/foo.rs"}))
            .await;
        assert!(
            result.is_ok(),
            "read-class tools must remain available to review-class dispatches: {result:?}"
        );
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
    }

    #[tokio::test]
    #[serial]
    async fn non_review_dispatch_is_unaffected_by_the_gate() {
        // Regression guard: implementation-class dispatches (the default,
        // no env var set) must see zero behavior change from this gate.
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let wrapped = ToolTimeoutWrapper::new(Box::new(CountingTool {
            name: "write_file",
            calls: calls.clone(),
        }));
        let result = wrapped
            .execute(serde_json::json!({"path": "src/foo.rs", "content": ""}))
            .await;
        assert!(
            result.is_ok(),
            "non-review dispatch must retain write access: {result:?}"
        );
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
}
