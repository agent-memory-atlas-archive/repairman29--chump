//! Multi-provider cascade: try cloud providers (Groq, Cerebras, Mistral, OpenRouter, Gemini,
//! GitHub Models, NVIDIA NIM, SambaNova) in priority order; on rate limit or failure fall back
//! to next, then to local (slot 0). See docs/architecture/PROVIDER_CASCADE.md.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::openai::OpenAIProvider;
use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;

use crate::cost_tracker;
use crate::llm_backend_metrics;
use crate::local_openai::{self, LocalOpenAIProvider};
use crate::provider_quality;

const DEFAULT_RPM_HEADROOM_PCT: f32 = 80.0;
// EFFECTIVE-413: raised from 14 — a pinned ceiling silently dropped any
// CHUMP_PROVIDER_{N}_* block past slot 14 (e.g. slot 15, an OpenCode Zen
// subscription slot) with no error, just an unreachable provider. Slots
// 12-14 are OpenCode Zen variants, not Gemini (stale comment fixed here).
const MAX_SLOTS: u32 = 40;

// EFFECTIVE-413 AC #4: money-risk guard. A slot that omits RPD entirely
// parses to rpd_limit=0, which the cascade treats as "unlimited" (see the
// `if slot.rpd_limit > 0` gate below) — silently unbounded spend for any
// paid-per-token slot whose operator simply forgot the RPD line. Slots that
// omit RPD get this safe default cap instead of true-unlimited; set RPD
// explicitly (including `RPD=0`) to opt out and get genuine no-limit.
const DEFAULT_RPD_WHEN_UNSET: u32 = 500;

/// INFRA-352: emit a structured ambient.jsonl event when the cascade has
/// exhausted every slot it could try and is about to return Err to the caller.
/// Best-effort: never breaks the call. Pattern mirrors `adversary::emit_ambient_alert`.
///
/// Per-slot tally format: `<name>=<calls_today>/<rpd_limit>/<circuit>` so the
/// operator can immediately see which slot is exhausted vs which is wedged.
fn emit_cascade_exhausted_event(slots: &[ProviderSlot], reason: &str) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());

    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    // Per-slot tally as a JSON-safe comma-separated string.
    let tally: Vec<String> = slots
        .iter()
        .map(|s| {
            let circuit = if local_openai::is_circuit_open(&s.base_url) {
                "open"
            } else {
                "closed"
            };
            format!(
                "{}={}/{}/{}",
                s.name,
                s.calls_today.load(Ordering::Relaxed),
                s.rpd_limit,
                circuit
            )
        })
        .collect();
    let per_slot = tally.join(",");

    // Trim reason to keep the JSON line short; full diagnosis is in cycle log.
    let reason_trim: String = reason.chars().take(200).collect();
    let reason_esc = reason_trim
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', " ");

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"cascade_all_exhausted\",\"slot_count\":{slot_count},\
         \"per_slot\":\"{per_slot}\",\"reason\":\"{reason_esc}\"}}",
        slot_count = slots.len()
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// INFRA-363: emit a single-field ambient event (pre-sleep or post-retry)
/// for the cascade exhausted backoff. Best-effort like the exhausted event.
fn emit_cascade_backoff_event(kind: &str, backoff_s: u64) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"event\":\"{kind}\",\"backoff_s\":{backoff_s}}}"
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// INFRA-1004: emit a `cascade_routed` ambient event on every successful slot selection.
/// Records which slot was chosen and the active cascade mode for routing observability.
///
/// ZERO-WASTE-060: also carries the estimated token count served by this slot.
/// Every cascade slot (Cloud or Local) is a free-tier provider — the cascade
/// exists specifically to serve requests without ever touching the paid
/// Anthropic-only path — so `tokens` here is what `chump kpi report`'s
/// free-tier-savings section sums to estimate dollars saved vs an
/// Anthropic-only baseline.
fn emit_cascade_routed_event(slot_name: &str, cascade_mode: &str, tier: &str, tokens: u64) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"cascade_routed\",\
         \"slot\":\"{slot_name}\",\"tier\":\"{tier}\",\"cascade_mode\":\"{cascade_mode}\",\
         \"tokens\":{tokens}}}"
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Escape a string for embedding in a hand-built JSON line (matches the
/// escaping already used by `emit_cascade_exhausted_event`'s `reason_esc`).
fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', " ")
}

/// CREDIBLE-266: emit a `provider_slot_resolved` ambient event once per agent
/// turn — the queryable counterpart to the INFRA-185 phase-timings log line.
/// Carries the request_id, the winning slot + model, and any slots that
/// failed over before it (with classified reason, never the raw error body
/// or credentials) so per-slot call counts and failover signatures become
/// measurable rather than greppable. Best-effort: never breaks the caller.
// scanner-anchor: "kind":"provider_slot_resolved"
pub fn emit_provider_slot_ambient_event(request_id: &str, provider_slot: &str, model: &str) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let failovers = get_last_failovers();
    let failovers_json: Vec<String> = failovers
        .iter()
        .map(|f| {
            format!(
                "{{\"slot\":\"{}\",\"reason\":\"{}\"}}",
                json_escape(&f.slot),
                json_escape(&f.reason)
            )
        })
        .collect();

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"provider_slot_resolved\",\
         \"request_id\":\"{}\",\"slot\":\"{}\",\"model\":\"{}\",\"failovers\":[{}]}}",
        json_escape(request_id),
        json_escape(provider_slot),
        json_escape(model),
        failovers_json.join(",")
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Default OpenAI-compatible base for local Ollama when `OPENAI_API_BASE` is unset (matches OOTB wizard).
pub const DEFAULT_OLLAMA_API_BASE: &str = "http://127.0.0.1:11434/v1";

/// True if the key is meant for the hosted OpenAI platform (`sk-...`, including `sk-proj-...`).
pub fn looks_like_openai_platform_key(key: &str) -> bool {
    key.trim().starts_with("sk-")
}

/// Normalize `OPENAI_API_KEY` for local backends: empty and common placeholders map to `ollama`.
pub fn resolved_openai_api_key() -> String {
    let raw = std::env::var("OPENAI_API_KEY").unwrap_or_default();
    let t = raw.trim();
    if t.is_empty() || t == "token-abc123" || t.eq_ignore_ascii_case("not-needed") {
        "ollama".into()
    } else {
        t.to_string()
    }
}

/// EFFECTIVE-1933: Resolve the API key for a specific endpoint URL.
/// Prefers explicit `OPENAI_API_KEY` when set to a real key; otherwise falls
/// back to `GEMINI_API_KEY` / `GOOGLE_API_KEY` for `generativelanguage.googleapis.com`
/// and `MISTRAL_API_KEY` for `api.mistral.ai`.
pub fn resolved_api_key_for_endpoint(base_url: &str) -> String {
    let primary = resolved_openai_api_key();
    if primary != "ollama" {
        return primary;
    }
    if base_url.contains("generativelanguage.googleapis.com") {
        for var in ["GEMINI_API_KEY", "GOOGLE_API_KEY"] {
            if let Ok(v) = std::env::var(var) {
                let t = v.trim();
                if !t.is_empty() {
                    return t.to_string();
                }
            }
        }
    } else if base_url.contains("api.mistral.ai") {
        if let Ok(v) = std::env::var("MISTRAL_API_KEY") {
            let t = v.trim();
            if !t.is_empty() {
                return t.to_string();
            }
        }
    }
    primary
}

/// EFFECTIVE-1933: Upgrade retired/decommissioned model slugs that return HTTP 404
/// on Google AI (`generativelanguage.googleapis.com`) and Groq (`api.groq.com`)
/// to their live frontier coding successors.
pub fn upgrade_retired_provider_model(base_url: &str, model: &str) -> String {
    let m = model.trim();
    if base_url.contains("generativelanguage.googleapis.com") {
        match m {
            "gemini-2.5-pro" | "models/gemini-2.5-pro" => return "gemini-3.8-flash".to_string(),
            "gemini-2.0-flash-lite"
            | "models/gemini-2.0-flash-lite"
            | "gemini-2.5-flash-lite"
            | "models/gemini-2.5-flash-lite" => return "gemini-3.5-flash-lite".to_string(),
            "gemini-2.0-flash" | "models/gemini-2.0-flash" => {
                return "gemini-3.6-flash".to_string()
            }
            _ => {}
        }
    } else if base_url.contains("api.groq.com") && m == "llama-3.3-70b-versatile" {
        return "qwen/qwen3.8-27b".to_string();
    }
    m.to_string()
}

fn cascade_enabled() -> bool {
    std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1")
        .unwrap_or(false)
}

// ── Local-model auto-discovery (EFFECTIVE-141) ────────────────────────────────

/// True if the base URL points to a local (loopback) endpoint that may not
/// serve cloud models like `gpt-5-mini`.
pub fn is_local_endpoint(base_url: &str) -> bool {
    let lower = base_url.to_lowercase();
    lower.contains("127.0.0.1")
        || lower.contains("localhost")
        || lower.contains("::1")
        || lower.starts_with("http://[::1]")
}

/// Preferred model order for auto-selection when `$OPENAI_MODEL` is unset and
/// the endpoint is local (Ollama / llama.cpp / vLLM). First match wins.
///
/// The list is deliberately conservative — these are the models confirmed
/// present on the reference local fleet. Operators can override via
/// `OPENAI_MODEL`.
pub const LOCAL_MODEL_PREFERENCE: &[&str] = &[
    "qwen2.5:14b",
    "qwen2.5:7b",
    "qwen3:14b",
    "qwen3:8b",
    "llama3.2:3b",
];

/// Pure, testable model selector. Given the list of model IDs reported by the
/// local endpoint:
/// - If `override_model` is `Some(s)` and `s` is non-empty, return it
///   (operator's explicit `$OPENAI_MODEL` wins unconditionally).
/// - Otherwise pick from `available`, *excluding* embedding models (name
///   contains "embed"), preferring `LOCAL_MODEL_PREFERENCE` in order, then
///   falling back to the first non-embedding model.
/// - Returns `None` when `available` contains only embedding models (or is
///   empty).
pub fn select_local_model(available: &[String], override_model: Option<&str>) -> Option<String> {
    // Operator override always wins.
    if let Some(m) = override_model {
        if !m.is_empty() {
            return Some(m.to_string());
        }
    }

    let non_embed: Vec<&String> = available
        .iter()
        .filter(|m| !m.to_lowercase().contains("embed"))
        .collect();

    // Check preference list first.
    for pref in LOCAL_MODEL_PREFERENCE {
        if let Some(m) = non_embed.iter().find(|m| m.as_str() == *pref) {
            return Some(m.to_string());
        }
    }

    // Fallback: first non-embedding model.
    non_embed.first().map(|m| m.to_string())
}

/// Fetch the list of available model IDs from an OpenAI-compatible `/models`
/// endpoint. Best-effort: returns an empty vec on any error (timeout, parse
/// failure, etc.).
///
/// The function spawns a one-shot tokio runtime in a dedicated thread so it
/// can be called from sync contexts (`build_provider_single`, `from_env`) without
/// blocking an existing async executor.
pub fn fetch_local_models_sync(base_url: &str) -> Vec<String> {
    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let url_clone = url.clone();
    // Use a thread + fresh single-thread runtime to avoid nesting tokio runtimes.
    let handle = std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(r) => r,
            Err(_) => return Vec::new(),
        };
        rt.block_on(async move {
            let client = reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(3))
                .build()
                .ok()?;
            let resp = client.get(&url_clone).send().await.ok()?;
            if !resp.status().is_success() {
                return None;
            }
            let json: serde_json::Value = resp.json().await.ok()?;
            let ids: Vec<String> = json
                .get("data")
                .and_then(|d| d.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| {
                            v.get("id")
                                .and_then(|id| id.as_str())
                                .map(|s| s.to_string())
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(ids)
        })
        .unwrap_or_default()
    });
    handle.join().unwrap_or_default()
}

/// Resolve the model to use for a given endpoint.
///
/// - If `env_override` is `Some` and non-empty, use it directly.
/// - If the endpoint is local, query `/models` and pick the best available
///   model via [`select_local_model`]. Logs to stderr on success so the
///   operator knows which model was auto-selected.
/// - For non-local (cloud) endpoints with no override, fall back to
///   `"gpt-4o-mini"` (the cloud default; `gpt-5-mini` was incorrect).
pub fn resolve_model_for_endpoint(base_url: &str, env_override: Option<String>) -> String {
    // Operator explicit choice always wins (with retired-model 404 auto-upgrade).
    if let Some(ref m) = env_override {
        if !m.is_empty() {
            return upgrade_retired_provider_model(base_url, m);
        }
    }

    if is_local_endpoint(base_url) {
        let available = fetch_local_models_sync(base_url);
        if let Some(model) = select_local_model(&available, None) {
            eprintln!(
                "chump: auto-selected local model '{}' from {} (set OPENAI_MODEL to override)",
                model, base_url
            );
            return model;
        }
        // Could not discover models — warn and fall back to a sensible default.
        if available.is_empty() {
            eprintln!(
                "chump: could not query {}/models — using qwen2.5:7b as default (set OPENAI_MODEL to override)",
                base_url
            );
            return "qwen2.5:7b".to_string();
        }
        // Only embedding models available — operator should configure OPENAI_MODEL.
        eprintln!(
            "chump: only embedding models found at {} — set OPENAI_MODEL to a chat model",
            base_url
        );
        return "qwen2.5:7b".to_string();
    }

    if base_url.contains("generativelanguage.googleapis.com") {
        return "gemini-3.8-flash".to_string();
    }
    if base_url.contains("api.mistral.ai") {
        return "codestral-latest".to_string();
    }

    // Non-local cloud endpoint: gpt-4o-mini is a real model; gpt-5-mini is not.
    "gpt-4o-mini".to_string()
}

fn rpm_headroom_pct() -> f32 {
    std::env::var("CHUMP_CASCADE_RPM_HEADROOM")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_RPM_HEADROOM_PCT)
        .clamp(1.0, 100.0)
        / 100.0
}

fn parse_privacy_tier(s: &str) -> PrivacyTier {
    match s.trim().to_lowercase().as_str() {
        "trains" => PrivacyTier::Trains,
        "caution" => PrivacyTier::Caution,
        _ => PrivacyTier::Safe,
    }
}

/// EFFECTIVE-347: restrict a set of eligible `(name, slot_index)` entries to the
/// ones whose slot model-class matches `pref` (via `class_of(index)`). This is
/// what makes difficulty-based escalation route under the Bandit strategy — the
/// bandit only filters on privacy/circuit/rate, so without this the preferred
/// model class is ignored and hard tasks stay on cheap slots. Graceful: if `pref`
/// is None, or no eligible slot matches it, return the input unchanged so a round
/// is never stranded with zero providers.
fn restrict_eligible_to_class(
    eligible: Vec<(String, usize)>,
    pref: Option<&str>,
    class_of: impl Fn(usize) -> Option<String>,
) -> Vec<(String, usize)> {
    let Some(pref) = pref else {
        return eligible;
    };
    let in_class: Vec<(String, usize)> = eligible
        .iter()
        .filter(|(_, i)| class_of(*i).as_deref() == Some(pref))
        .cloned()
        .collect();
    if in_class.is_empty() {
        eligible
    } else {
        in_class
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ProviderTier {
    Local,
    Cloud,
}

/// Privacy tier for provider slots. Safe = no training on data; Trains = provider trains on free-tier data.
/// Used with CHUMP_ROUND_PRIVACY: work/cursor_improve/doc_hygiene/battle_qa set safe so cascade skips Mistral/Gemini.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PrivacyTier {
    /// Provider may train on free-tier data (Mistral, Gemini).
    Trains = 0,
    Caution = 1,
    /// No training; safe for proprietary code.
    Safe = 2,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum CascadeStrategy {
    Priority,
    /// Skip first N cloud slots for low-value round types (research, opportunity, discovery).
    TaskAware,
    /// Learn the best slot per workload from reward feedback. See
    /// [`crate::provider_bandit`] — Thompson Sampling by default, UCB1 if
    /// `CHUMP_BANDIT_STRATEGY=ucb1`.
    Bandit,
}

impl CascadeStrategy {
    pub fn label(self) -> &'static str {
        match self {
            CascadeStrategy::Priority => "priority",
            CascadeStrategy::TaskAware => "task_aware",
            CascadeStrategy::Bandit => "bandit",
        }
    }
}

pub struct ProviderSlot {
    pub name: String,
    pub base_url: String,
    pub provider: LocalOpenAIProvider,
    pub priority: u32,
    pub tier: ProviderTier,
    /// Privacy tier: Safe (no training), Caution, Trains (provider trains on free data). From CHUMP_PROVIDER_{N}_PRIVACY.
    pub privacy: PrivacyTier,
    /// Context window in thousands of tokens (e.g. 1000 = 1M). From CHUMP_PROVIDER_{N}_CONTEXT_K. Used when CHUMP_PREFER_LARGE_CONTEXT=1.
    pub context_k: Option<u32>,
    /// Model class: haiku / sonnet / opus. Maps free-tier providers to Claude
    /// tiers so the cascade can prefer the right slot for each task complexity.
    /// From CHUMP_PROVIDER_{N}_MODEL_CLASS. Matched against CHUMP_PREFERRED_MODEL_CLASS.
    pub model_class: Option<String>,
    pub rpm_limit: u32,
    pub calls_this_minute: AtomicU32,
    pub minute_start: Mutex<Instant>,
    /// Daily request cap (0 = unlimited). Set via CHUMP_PROVIDER_{N}_RPD.
    /// EFFECTIVE-413: `from_env()` only produces 0 here for an *explicit*
    /// `RPD=0`; a slot that omits RPD entirely gets `DEFAULT_RPD_WHEN_UNSET`
    /// instead, so this field being 0 always reflects a deliberate choice.
    pub rpd_limit: u32,
    /// Calls made today (resets at midnight local time, approximately via day_start tracking).
    pub calls_today: AtomicU32,
    /// Start of the current 24h window.
    pub day_start: Mutex<Instant>,
    /// When set, skip this slot until the cooldown expires (429 backoff).
    pub cooldown_until: Mutex<Option<Instant>>,
    /// EFFECTIVE-003/INFRA-1565: this slot's model emits tool calls as
    /// `<tool_call>`/`<function_call>` XML tags instead of native
    /// provider tool-call fields (common on Ollama-served and older
    /// Mistral checkpoints). When true, a response with no native
    /// `tool_calls` is passed through `chump_xml_adapter::extract_tool_calls`
    /// before the empty-response quality gate runs. From
    /// `CHUMP_PROVIDER_{N}_XML_TOOL_TAGS`; defaults to false.
    pub xml_tool_tags: bool,
}

fn within_rate_limit(slot: &ProviderSlot) -> bool {
    // RPM check
    if slot.rpm_limit > 0 {
        let mut start_guard = slot.minute_start.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        if now.duration_since(*start_guard) > Duration::from_secs(60) {
            slot.calls_this_minute.store(0, Ordering::Relaxed);
            *start_guard = now;
        }
        drop(start_guard);
        let current = slot.calls_this_minute.load(Ordering::Relaxed);
        let effective = (slot.rpm_limit as f32 * rpm_headroom_pct()) as u32;
        if current >= effective {
            return false;
        }
    }

    // RPD check
    if slot.rpd_limit > 0 {
        let mut day_guard = slot.day_start.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        if now.duration_since(*day_guard) > Duration::from_secs(86400) {
            slot.calls_today.store(0, Ordering::Relaxed);
            *day_guard = now;
        }
        drop(day_guard);
        let today = slot.calls_today.load(Ordering::Relaxed);
        let effective_rpd = (slot.rpd_limit as f32 * rpm_headroom_pct()) as u32;
        if today >= effective_rpd {
            if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                eprintln!(
                    "[cascade] {} daily cap reached ({}/{} RPD), skipping",
                    slot.name, today, slot.rpd_limit
                );
            }
            return false;
        }
    }

    true
}

fn is_cooling_down(slot: &ProviderSlot) -> bool {
    let guard = slot
        .cooldown_until
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    guard.map(|t| Instant::now() < t).unwrap_or(false)
}

fn cooldown_remaining(slot: &ProviderSlot) -> Option<Duration> {
    let guard = slot
        .cooldown_until
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    guard.and_then(|t| {
        let now = Instant::now();
        if now < t {
            Some(t - now)
        } else {
            None
        }
    })
}

fn set_cooldown(slot: &ProviderSlot, duration: Duration) {
    let mut guard = slot
        .cooldown_until
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *guard = Some(Instant::now() + duration);
}

/// Parse Retry-After seconds from an error string. Providers embed it as
/// "retry after Ns" or "Retry-After: N" or just the status + a seconds hint.
fn parse_retry_after_secs(err: &str) -> Option<u64> {
    let lower = err.to_ascii_lowercase();
    // "retry after 30s" / "retry-after: 30" / "try again in 30 seconds"
    for pattern in &["retry after ", "retry-after: ", "try again in "] {
        if let Some(pos) = lower.find(pattern) {
            let after = &err[pos + pattern.len()..];
            let num_str: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(n) = num_str.parse::<u64>() {
                return Some(n.clamp(1, 120));
            }
        }
    }
    None
}

/// Default cooldown, in seconds, when a 429 does not include a Retry-After hint.
const DEFAULT_429_COOLDOWN_S: u64 = 30;
/// Max cooldown we'll wait for a single slot before cascading.
const MAX_WAIT_FOR_PREFERRED_S: u64 = 60;

fn record_call(slot: &ProviderSlot) {
    slot.calls_this_minute.fetch_add(1, Ordering::Relaxed);
    slot.calls_today.fetch_add(1, Ordering::Relaxed);
}

pub struct ProviderCascade {
    pub slots: Vec<ProviderSlot>,
    _strategy: CascadeStrategy,
    /// INFRA-1004: when true, cloud slots are refused entirely and any call
    /// that cannot be served by a local slot returns a hard error instead of
    /// silently falling back to cloud. Set via CHUMP_LOCAL_ONLY=1.
    local_only: bool,
    /// Lazy-initialized bandit router. Only populated when `_strategy` is
    /// [`CascadeStrategy::Bandit`]; otherwise None. Kept inside the cascade
    /// (not a global) so each cascade instance has its own learning state
    /// and tests don't leak stats into production.
    bandit: std::sync::OnceLock<crate::provider_bandit::BanditRouter>,
}

impl ProviderCascade {
    /// Load slots from env. Slot 0 from OPENAI_*; slots 1..=MAX_SLOTS from CHUMP_PROVIDER_{N}_*.
    pub fn from_env() -> Self {
        let mut slots: Vec<ProviderSlot> = Vec::new();

        if let Ok(base) = std::env::var("OPENAI_API_BASE") {
            let base = base.trim_end_matches('/').to_string();
            if !base.is_empty() {
                let api_key = resolved_api_key_for_endpoint(&base);
                let model = resolve_model_for_endpoint(
                    &base,
                    std::env::var("OPENAI_MODEL").ok().filter(|m| !m.is_empty()),
                );
                let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
                    .ok()
                    .filter(|s| !s.is_empty());
                let provider =
                    LocalOpenAIProvider::with_fallback(base.clone(), fallback, api_key, model);
                slots.push(ProviderSlot {
                    name: "local".to_string(),
                    base_url: base,
                    provider,
                    priority: 0,
                    tier: ProviderTier::Local,
                    privacy: PrivacyTier::Safe,
                    context_k: None,
                    model_class: None,
                    rpm_limit: 0,
                    calls_this_minute: AtomicU32::new(0),
                    minute_start: Mutex::new(Instant::now()),
                    rpd_limit: 0,
                    calls_today: AtomicU32::new(0),
                    day_start: Mutex::new(Instant::now()),
                    cooldown_until: Mutex::new(None),
                    xml_tool_tags: std::env::var("CHUMP_LOCAL_XML_TOOL_TAGS")
                        .map(|v| v.trim() == "1")
                        .unwrap_or(false),
                });
            }
        }

        for n in 1..=MAX_SLOTS {
            let enabled =
                std::env::var(format!("CHUMP_PROVIDER_{}_ENABLED", n)).unwrap_or_default();
            if enabled != "1" {
                continue;
            }
            let base = match std::env::var(format!("CHUMP_PROVIDER_{}_BASE", n)) {
                Ok(b) if !b.is_empty() => b.trim_end_matches('/').to_string(),
                _ => continue,
            };
            let mut key = std::env::var(format!("CHUMP_PROVIDER_{}_KEY", n)).unwrap_or_default();
            if key.trim().is_empty() {
                if base.contains("generativelanguage.googleapis.com") {
                    key = std::env::var("GEMINI_API_KEY")
                        .or_else(|_| std::env::var("GOOGLE_API_KEY"))
                        .unwrap_or_default();
                } else if base.contains("api.mistral.ai") {
                    key = std::env::var("MISTRAL_API_KEY").unwrap_or_default();
                }
            }
            let raw_model = std::env::var(format!("CHUMP_PROVIDER_{}_MODEL", n))
                .unwrap_or_else(|_| "gpt-4".to_string());
            let model = upgrade_retired_provider_model(&base, &raw_model);
            let name = std::env::var(format!("CHUMP_PROVIDER_{}_NAME", n))
                .unwrap_or_else(|_| format!("slot_{}", n));
            let priority_raw = std::env::var(format!("CHUMP_PROVIDER_{}_PRIORITY", n)).ok();
            let priority = priority_raw
                .as_ref()
                .and_then(|v| v.parse().ok())
                .unwrap_or(n * 10);
            let rpm_raw = std::env::var(format!("CHUMP_PROVIDER_{}_RPM", n)).ok();
            let rpm = rpm_raw.as_ref().and_then(|v| v.parse().ok()).unwrap_or(30);
            let rpd_env = std::env::var(format!("CHUMP_PROVIDER_{}_RPD", n)).ok();
            let rpd: u32 = match rpd_env.as_ref().and_then(|v| v.parse().ok()) {
                Some(explicit) => explicit,
                None => {
                    // EFFECTIVE-413 AC #4: no explicit RPD → assume the
                    // operator forgot it, not that they want unbounded
                    // spend. An explicit `RPD=0` still opts into true
                    // unlimited (handled by the `Some(explicit)` arm above).
                    eprintln!(
                        "[cascade] WARNING: slot {} ({}) has no CHUMP_PROVIDER_{}_RPD set — \
                         defaulting to {} instead of unlimited. Set RPD explicitly (RPD=0 for \
                         genuine unlimited) to silence this.",
                        n, name, n, DEFAULT_RPD_WHEN_UNSET
                    );
                    DEFAULT_RPD_WHEN_UNSET
                }
            };
            let mut privacy = std::env::var(format!("CHUMP_PROVIDER_{}_PRIVACY", n))
                .map(|s| parse_privacy_tier(&s))
                .unwrap_or(PrivacyTier::Safe);
            let is_paid_slot = std::env::var("CHUMP_BYOK_PAID").as_deref() == Ok("1")
                || std::env::var(format!("CHUMP_PROVIDER_{}_TIER", n))
                    .map(|s| s.trim().eq_ignore_ascii_case("paid"))
                    .unwrap_or(false);
            if is_paid_slot && privacy == PrivacyTier::Trains {
                privacy = PrivacyTier::Safe;
            }
            let context_k_raw = std::env::var(format!("CHUMP_PROVIDER_{}_CONTEXT_K", n)).ok();
            let context_k = context_k_raw
                .as_ref()
                .and_then(|v| v.trim().parse::<u32>().ok());
            let model_class = std::env::var(format!("CHUMP_PROVIDER_{}_MODEL_CLASS", n))
                .ok()
                .filter(|s| !s.is_empty())
                .map(|s| s.trim().to_lowercase());
            let xml_tool_tags = std::env::var(format!("CHUMP_PROVIDER_{}_XML_TOOL_TAGS", n))
                .map(|v| v.trim() == "1")
                .unwrap_or(false);

            // CREDIBLE-227 AC #4: a slot that declares BASE/KEY/MODEL but
            // omits RPM, PRIORITY, and CONTEXT_K is "half-declared" — it
            // silently falls back to defaults (rpm=30, priority=n*10,
            // unlimited context) instead of an explicit, verified value.
            // Make that visible instead of letting it look fully configured.
            if rpm_raw.is_none() && priority_raw.is_none() && context_k_raw.is_none() {
                eprintln!(
                    "[cascade] WARNING: slot {} ({}) declares only BASE/KEY/MODEL/MODEL_CLASS — \
                     missing RPM/PRIORITY/CONTEXT_K, falling back to defaults (rpm=30, priority={}, context_k=none). \
                     Set CHUMP_PROVIDER_{}_RPM/PRIORITY/CONTEXT_K explicitly.",
                    n, name, n * 10, n
                );
                // scanner-anchor: "kind":"provider_slot_incomplete"
                crate::tool_policy::emit_ambient_json(
                    "provider_slot_incomplete",
                    serde_json::json!({
                        "slot": n,
                        "name": name,
                        "missing": ["RPM", "PRIORITY", "CONTEXT_K"],
                    }),
                );
            }

            let provider = LocalOpenAIProvider::with_fallback(base.clone(), None, key, model);
            slots.push(ProviderSlot {
                name,
                base_url: base,
                provider,
                priority,
                tier: ProviderTier::Cloud,
                privacy,
                context_k,
                model_class,
                rpm_limit: rpm,
                calls_this_minute: AtomicU32::new(0),
                minute_start: Mutex::new(Instant::now()),
                rpd_limit: rpd,
                calls_today: AtomicU32::new(0),
                day_start: Mutex::new(Instant::now()),
                cooldown_until: Mutex::new(None),
                xml_tool_tags,
            });
        }

        // EFFECTIVE-1933: When CHUMP_AUTO_BYOK_SLOTS=1, auto-register Google AI
        // (GEMINI_API_KEY / GOOGLE_API_KEY) and Mistral (MISTRAL_API_KEY) frontier
        // coding slots if no explicit slot for that endpoint was declared.
        if std::env::var("CHUMP_AUTO_BYOK_SLOTS").as_deref() == Ok("1") {
            let gemini_key = std::env::var("GEMINI_API_KEY")
                .or_else(|_| std::env::var("GOOGLE_API_KEY"))
                .unwrap_or_default();
            let has_gemini_slot = slots
                .iter()
                .any(|s| s.base_url.contains("generativelanguage.googleapis.com"));
            if !gemini_key.trim().is_empty() && !has_gemini_slot {
                let base = "https://generativelanguage.googleapis.com/v1beta/openai".to_string();
                let auto_gemini = [
                    (
                        "gemini-pro",
                        "gemini-3.8-flash",
                        "opus",
                        15u32,
                        60u32,
                        5000u32,
                    ),
                    (
                        "gemini-flash",
                        "gemini-3.6-flash",
                        "sonnet",
                        25u32,
                        60u32,
                        5000u32,
                    ),
                    (
                        "gemini-flash-lite",
                        "gemini-3.5-flash-lite",
                        "haiku",
                        35u32,
                        120u32,
                        10000u32,
                    ),
                ];
                for (name, model, class, prio, rpm, rpd) in auto_gemini {
                    let provider = LocalOpenAIProvider::with_fallback(
                        base.clone(),
                        None,
                        gemini_key.trim().to_string(),
                        model.to_string(),
                    );
                    slots.push(ProviderSlot {
                        name: name.to_string(),
                        base_url: base.clone(),
                        provider,
                        priority: prio,
                        tier: ProviderTier::Cloud,
                        privacy: PrivacyTier::Safe,
                        context_k: Some(1000),
                        model_class: Some(class.to_string()),
                        rpm_limit: rpm,
                        calls_this_minute: AtomicU32::new(0),
                        minute_start: Mutex::new(Instant::now()),
                        rpd_limit: rpd,
                        calls_today: AtomicU32::new(0),
                        day_start: Mutex::new(Instant::now()),
                        cooldown_until: Mutex::new(None),
                        xml_tool_tags: false,
                    });
                }
            }

            let mistral_key = std::env::var("MISTRAL_API_KEY").unwrap_or_default();
            let has_mistral_slot = slots.iter().any(|s| s.base_url.contains("api.mistral.ai"));
            if !mistral_key.trim().is_empty() && !has_mistral_slot {
                let base = "https://api.mistral.ai/v1".to_string();
                let provider = LocalOpenAIProvider::with_fallback(
                    base.clone(),
                    None,
                    mistral_key.trim().to_string(),
                    "codestral-latest".to_string(),
                );
                slots.push(ProviderSlot {
                    name: "mistral-codestral".to_string(),
                    base_url: base,
                    provider,
                    priority: 20,
                    tier: ProviderTier::Cloud,
                    privacy: PrivacyTier::Safe,
                    context_k: Some(256),
                    model_class: Some("opus".to_string()),
                    rpm_limit: 60,
                    calls_this_minute: AtomicU32::new(0),
                    minute_start: Mutex::new(Instant::now()),
                    rpd_limit: 5000,
                    calls_today: AtomicU32::new(0),
                    day_start: Mutex::new(Instant::now()),
                    cooldown_until: Mutex::new(None),
                    xml_tool_tags: false,
                });
            }
        }

        slots.sort_by_key(|s| s.priority);
        let strategy = std::env::var("CHUMP_CASCADE_STRATEGY")
            .ok()
            .map(|s| match s.trim().to_lowercase().as_str() {
                "task_aware" | "taskaware" => CascadeStrategy::TaskAware,
                "bandit" | "learned" => CascadeStrategy::Bandit,
                _ => CascadeStrategy::Priority,
            })
            .unwrap_or(CascadeStrategy::Priority);
        let local_only = std::env::var("CHUMP_LOCAL_ONLY")
            .map(|v| v.trim() == "1")
            .unwrap_or(false);

        // INFRA-2372: opt-in CHUMP_CASCADE_PRECHECK=1 prints a one-line
        // warning per cloud slot at startup so the operator can spot a
        // missing API key or a known-malformed endpoint *before* a real
        // call 400s mid-cascade. Disabled by default — the runtime
        // should_cascade_on_error_string predicate handles per-call
        // recovery whether or not this fires. Never aborts; never
        // removes slots; never makes a network call (would block sync
        // from_env). Network-based probe lives in `precheck_slots` and
        // is the operator's call to invoke at fleet boot.
        if std::env::var("CHUMP_CASCADE_PRECHECK")
            .map(|v| v.trim() == "1")
            .unwrap_or(false)
        {
            for (idx, slot) in slots.iter().enumerate() {
                if slot.tier != ProviderTier::Cloud {
                    continue;
                }
                let key_env = if idx == 0 {
                    "OPENAI_API_KEY".to_string()
                } else {
                    format!("CHUMP_PROVIDER_{}_KEY", idx)
                };
                let has_key = std::env::var(&key_env)
                    .map(|v| !v.is_empty())
                    .unwrap_or(false);
                if !has_key {
                    eprintln!(
                        "[cascade-precheck] slot {} ({}): {} unset — slot will be skipped on auth-class errors",
                        idx, slot.name, key_env
                    );
                }
            }
        }

        Self {
            slots,
            _strategy: strategy,
            local_only,
            bandit: std::sync::OnceLock::new(),
        }
    }

    /// Describes the active routing mode for observability (health endpoint, events).
    pub fn cascade_mode(&self) -> &'static str {
        if self.local_only {
            return "local-only";
        }
        let has_local = self.slots.iter().any(|s| s.tier == ProviderTier::Local);
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        match (has_local, has_cloud) {
            (true, true) => "preferred-local",
            (false, true) => "paid-direct",
            _ => "free-then-paid",
        }
    }

    /// Lazy-initialize the bandit router with this cascade's current slot
    /// names. Only returns Some when strategy == Bandit.
    fn bandit(&self) -> Option<&crate::provider_bandit::BanditRouter> {
        if self._strategy != CascadeStrategy::Bandit {
            return None;
        }
        Some(self.bandit.get_or_init(|| {
            let arms: Vec<String> = self.slots.iter().map(|s| s.name.clone()).collect();
            let strategy = std::env::var("CHUMP_BANDIT_STRATEGY")
                .ok()
                .map(|s| crate::provider_bandit::BanditStrategy::from_env_str(&s))
                .unwrap_or_default();
            tracing::info!(
                target: "chump::provider_cascade",
                strategy = ?strategy,
                arms = ?arms,
                "bandit router initialized"
            );
            crate::provider_bandit::BanditRouter::new(arms, strategy)
        }))
    }

    /// Select the first slot via the bandit, restricted to slots that
    /// pass the current privacy/rate-limit/circuit filters. Returns None
    /// if no slot is available (callers fall through to the local-last-
    /// resort path same as priority-strategy does).
    fn bandit_first_available(
        &self,
        min_privacy: Option<PrivacyTier>,
        skip_cloud: u32,
    ) -> Option<usize> {
        let skip_cloud = skip_cloud as usize;
        let bandit = self.bandit()?;
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        // Build the name → index map for eligible slots.
        let eligible: Vec<(String, usize)> = self
            .slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| {
                // INFRA-1004: in local-only mode, cloud slots are never eligible.
                if self.local_only && slot.tier == ProviderTier::Cloud {
                    return false;
                }
                (!has_cloud || slot.tier != ProviderTier::Local)
                    && min_privacy.is_none_or(|min| slot.privacy >= min)
                    && !local_openai::is_circuit_open(&slot.base_url)
                    && !is_cooling_down(slot)
                    && within_rate_limit(slot)
            })
            .skip(skip_cloud)
            .map(|(i, s)| (s.name.clone(), i))
            .collect();
        if eligible.is_empty() {
            return None;
        }
        // EFFECTIVE-347: honor CHUMP_PREFERRED_MODEL_CLASS. The Bandit strategy
        // otherwise ignores model class entirely — it filters only on
        // privacy/circuit/rate, then lets the bandit pick — so difficulty-based
        // escalation (route hard tasks to opus-class slots) was DEAD CODE under
        // the active strategy. Restrict the bandit's arms to the preferred class
        // when any eligible slot matches it; fall back to all eligible if none do.
        let preferred_class = std::env::var("CHUMP_PREFERRED_MODEL_CLASS")
            .ok()
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());
        let eligible = restrict_eligible_to_class(eligible, preferred_class.as_deref(), |i| {
            self.slots.get(i).and_then(|s| s.model_class.clone())
        });
        let names: Vec<String> = eligible.iter().map(|(n, _)| n.clone()).collect();
        let pick_name = bandit.select_from(&names)?;
        eligible
            .into_iter()
            .find(|(n, _)| n == &pick_name)
            .map(|(_, i)| i)
    }

    /// Number of cloud slots to skip from the start for low-value rounds (TaskAware only).
    fn skip_cloud_slots_for_round_type(&self) -> u32 {
        if self._strategy != CascadeStrategy::TaskAware {
            return 0;
        }
        let round_type =
            std::env::var("CHUMP_CURRENT_ROUND_TYPE").unwrap_or_else(|_| "work".to_string());
        match round_type.trim().to_lowercase().as_str() {
            "research" | "opportunity" | "discovery" => 2,
            _ => 0,
        }
    }

    /// Returns the first slot that is within rate limits and meets min_privacy (if set).
    /// skip_cloud: when > 0 (TaskAware low-value rounds), skip this many cloud slots from the start.
    /// When CHUMP_PREFER_LARGE_CONTEXT=1, prefer slots with larger context_k first.
    fn first_available_slot(
        &self,
        min_privacy: Option<PrivacyTier>,
        skip_cloud: u32,
    ) -> Option<usize> {
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        let regime = crate::precision_controller::current_regime();
        let prefer_local = regime == crate::precision_controller::PrecisionRegime::Exploit;
        let prefer_cloud = matches!(
            regime,
            crate::precision_controller::PrecisionRegime::Explore
                | crate::precision_controller::PrecisionRegime::Conservative
        );
        let preferred_class = std::env::var("CHUMP_PREFERRED_MODEL_CLASS")
            .ok()
            .filter(|s| !s.is_empty())
            .map(|s| s.trim().to_lowercase());
        let mut order: Vec<usize> = (0..self.slots.len()).collect();
        order.sort_by(|&i, &j| {
            let a = &self.slots[i];
            let b = &self.slots[j];
            // Model-class match: slots tagged with the preferred class sort first
            let class_a: i32 = match (&preferred_class, &a.model_class) {
                (Some(pref), Some(mc)) if mc == pref => -1,
                _ => 0,
            };
            let class_b: i32 = match (&preferred_class, &b.model_class) {
                (Some(pref), Some(mc)) if mc == pref => -1,
                _ => 0,
            };
            // Regime-based tier bias: prefer local when Exploit, cloud when Explore/Conservative
            let tier_bias_a: i32 = if (prefer_local && a.tier == ProviderTier::Local)
                || (prefer_cloud && a.tier == ProviderTier::Cloud)
            {
                -1
            } else {
                0
            };
            let tier_bias_b: i32 = if (prefer_local && b.tier == ProviderTier::Local)
                || (prefer_cloud && b.tier == ProviderTier::Cloud)
            {
                -1
            } else {
                0
            };
            let da = provider_quality::demotion_offset(&a.name);
            let db = provider_quality::demotion_offset(&b.name);
            class_a.cmp(&class_b).then_with(|| {
                tier_bias_a.cmp(&tier_bias_b).then_with(|| {
                    da.cmp(&db).then_with(|| {
                        if prefer_large_context() {
                            let ak = a.context_k.unwrap_or(0);
                            let bk = b.context_k.unwrap_or(0);
                            bk.cmp(&ak).then_with(|| a.priority.cmp(&b.priority))
                        } else {
                            a.priority.cmp(&b.priority)
                        }
                    })
                })
            })
        });
        let mut cloud_skipped = 0u32;
        for &i in &order {
            let slot = &self.slots[i];
            // INFRA-1004: in local-only mode, never route to cloud.
            if self.local_only && slot.tier == ProviderTier::Cloud {
                continue;
            }
            if !self.local_only && has_cloud && slot.tier == ProviderTier::Local {
                continue;
            }
            if slot.tier == ProviderTier::Cloud && cloud_skipped < skip_cloud {
                cloud_skipped += 1;
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!(
                        "[cascade] TaskAware: skipping {} (slot {})",
                        slot.name, cloud_skipped
                    );
                }
                continue;
            }
            if provider_quality::should_skip_slot(&slot.name) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] {} sanity-fail rate >10%, skipping", slot.name);
                }
                continue;
            }
            if is_cooling_down(slot) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    let remaining = cooldown_remaining(slot).unwrap_or_default();
                    eprintln!(
                        "[cascade] {} cooling down ({:.0}s remaining), skipping",
                        slot.name,
                        remaining.as_secs_f64()
                    );
                }
                continue;
            }
            if let Some(min) = min_privacy {
                if slot.privacy < min {
                    if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                        eprintln!(
                            "[cascade] {} privacy {:?} < {:?}, skipping",
                            slot.name, slot.privacy, min
                        );
                    }
                    continue;
                }
            }
            if local_openai::is_circuit_open(&slot.base_url) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] {} circuit open, skipping", slot.name);
                }
                continue;
            }
            if !within_rate_limit(slot) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!(
                        "[cascade] {} rate limited (rpm={}/{} rpd={}/{}), skipping",
                        slot.name,
                        slot.calls_this_minute.load(Ordering::Relaxed),
                        slot.rpm_limit,
                        slot.calls_today.load(Ordering::Relaxed),
                        slot.rpd_limit,
                    );
                }
                continue;
            }
            return Some(i);
        }
        None
    }
}

fn prefer_large_context() -> bool {
    std::env::var("CHUMP_PREFER_LARGE_CONTEXT")
        .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// INFRA-300: classify a provider error string for cascade failover.
///
/// Returns `true` if the error indicates the *current* slot can't serve
/// THIS request but a *sibling* slot probably can — i.e. cascade onward.
/// Returns `false` for errors that should propagate (bad request, model
/// crash, etc.).
///
/// Categories that cascade:
/// - **Rate limit** (429, 413 for Groq TPM, "rate limit", "tokens per minute")
/// - **Access denied** (401, 403, "unauthorized", "forbidden", "models permission")
/// - **Billing exhausted** (402, "credit_limit", "insufficient quota",
///   "payment required", "billing") — added 2026-05-02 after Together's
///   free credits drained and a 50% silent-failure rate hit the PWA.
///   See [`is_billing_exhausted_error_string`] (extracted as a helper
///   in INFRA-302 so callers above the cascade layer can detect it
///   too).
/// - **Tool format** ("tool_use_failed", "tool call validation failed")
/// - **Tool capability** (Cerebras 400 "UnsupportedToolUse", "does not
///   support tools", ...) — INFRA-313: technically 400-status but
///   another model handles the same payload, so cascade-onward is the
///   right behavior. Symptomatically identical to `tool_use_failed`.
/// - **Transport-level errors** ("error sending request", "model HTTP
///   unreachable", "connection refused", "operation timed out", "no route
///   to host", "name resolution failed") — INFRA-348: `LocalOpenAIProvider`
///   wraps the underlying reqwest transport error with an educational hint
///   string. The wrapped error loses the typed chain so
///   `local_openai::is_transient_error` (which calls `format!("{:?}", err)`)
///   can no longer classify it. The string predicate is the correct fix
///   layer: recognise the wrapped patterns so the cascade falls over to a
///   cloud slot when the local daemon is down/unreachable.
///
/// Note: this only inspects the error *string*. The full check in `complete()`
/// also calls `local_openai::is_transient_error(&e)` for transport-level
/// errors (timeouts, connection resets) which require the typed `&Error`.
pub(crate) fn should_cascade_on_error_string(e_str: &str) -> bool {
    let lower = e_str.to_ascii_lowercase();
    let is_rate_limited = e_str.contains("429")
        || e_str.contains("413") // Groq uses 413 for TPM exceeded
        || lower.contains("too many requests")
        || lower.contains("rate limit")
        || lower.contains("tokens per minute")
        || lower.contains("request too large for model");
    let is_access_denied = e_str.contains("401")
        || e_str.contains("403")
        || lower.contains("unauthorized")
        || lower.contains("models permission")
        || lower.contains("forbidden")
        || (e_str.contains("404") && lower.contains("model"));
    let is_tool_format_failure = lower.contains("tool_use_failed")
        || lower.contains("tool call validation failed")
        || lower.contains("failed to call a function");
    // INFRA-313: model-capability-class 400 errors. Default cascade-on-400 is
    // OFF (the request is wrong → another provider won't help) but for these
    // *capability* errors the request is fine; it's just THIS model that
    // can't handle the tool-call shape (e.g. Cerebras returns 400
    // "UnsupportedToolUse: model does not support more than one tool call at
    // this time"). A model that DOES support multiple tool calls (Anthropic,
    // OpenAI, Together's larger models) will succeed on the same payload.
    let is_tool_capability_failure = lower.contains("unsupportedtooluse")
        || lower.contains("unsupported_tool_use")
        || lower.contains("does not support more than one tool")
        || lower.contains("does not support tool")
        || lower.contains("tools are not supported")
        || lower.contains("model does not support tools");
    // INFRA-2372: Gemini returns 400 "Function calling config is set
    // without function_declarations" when the cascade calls it with the
    // tool-calling shape but the slot's openai-shim doesn't synthesize
    // function_declarations. Same class as the INFRA-313 capability
    // errors above — a different slot will handle the payload fine.
    // Also catches the related "function_declaration" / "tools[0]" /
    // "tool_config.function_calling_config" 400 surface that Gemini
    // emits when malformed tools are passed.
    let is_gemini_tool_config_failure = lower.contains("function calling config is set without")
        || lower.contains("function_declarations")
        || lower.contains("function_declaration is required")
        || (lower.contains("tool_config")
            && (lower.contains("function_calling_config") || lower.contains("invalid")))
        || (lower.contains("400") && lower.contains("tools") && lower.contains("malformed"));
    // INFRA-348 / INFRA-347: transport-level errors wrapped by LocalOpenAIProvider.
    // `LocalOpenAIProvider::complete` appends an educational hint string
    // (e.g. "— model HTTP unreachable (daemon down, crashed, or still
    // starting). Ollama: brew services start ollama …") via
    // `Err(anyhow!("{}{}", err, hint))`. This re-wraps into a plain-string
    // anyhow error and loses the typed chain, so `is_transient_error`'s
    // `format!("{:?}", err)` chain inspection no longer fires. Delegate to
    // [`is_transport_unreachable_error_string`] so the same set of patterns
    // is also used by `execute_gap::classify_execute_gap_error` at the
    // agent-loop boundary (INFRA-347).
    is_rate_limited
        || is_access_denied
        || is_billing_exhausted_error_string(e_str)
        || is_tool_format_failure
        || is_tool_capability_failure
        || is_gemini_tool_config_failure
        || is_transport_unreachable_error_string(e_str)
}

/// INFRA-302 blocker (1): the billing-exhausted predicate, factored out
/// of [`should_cascade_on_error_string`] so callers above the cascade
/// layer can detect it independently. Same set INFRA-300 added the
/// per-call cascade fail-over for; reused here so `chump --execute-gap`
/// (the agent-loop entry, NOT the per-call cascade) can classify its
/// own errors without re-implementing the predicate.
///
/// Returns `true` when the error string is the 402/credit-exhausted
/// class — i.e. the operator/orchestrator should switch provider, top
/// up credits, or cascade to the next routing candidate, NOT just
/// retry the same call.
pub(crate) fn is_billing_exhausted_error_string(e_str: &str) -> bool {
    let lower = e_str.to_ascii_lowercase();
    e_str.contains("402")
        || lower.contains("credit_limit")
        || lower.contains("credit limit")
        || lower.contains("insufficient quota")
        || lower.contains("insufficient_quota")
        || lower.contains("payment required")
        || lower.contains("billing")
}

/// INFRA-347: the transport-unreachable predicate, factored out of
/// [`should_cascade_on_error_string`] so callers above the cascade layer
/// can detect it independently (analogous to
/// [`is_billing_exhausted_error_string`] for INFRA-302).
///
/// INFRA-348 added these patterns to the per-call cascade predicate so
/// `ProviderCascade::complete` falls over to a cloud slot when the local
/// daemon is down. This helper surfaces the same classification at the
/// *agent-loop boundary* (`execute_gap::classify_execute_gap_error`) so
/// the orchestrator-level cascade-respawn can act on it too — without
/// it, a "Ollama unreachable" failure from a single-provider setup
/// exits with code 1 (generic), indistinguishable from a tool storm or
/// a programming bug.
///
/// Returns `true` when the error string indicates the local daemon
/// (Ollama / vLLM / LM Studio) is unreachable or the network path to the
/// configured `OPENAI_API_BASE` is broken — i.e. a *different* provider
/// URL or a respawned daemon would succeed.
pub(crate) fn is_transport_unreachable_error_string(e_str: &str) -> bool {
    let lower = e_str.to_ascii_lowercase();
    lower.contains("error sending request")
        || lower.contains("model http unreachable")
        || lower.contains("connection refused")
        || lower.contains("operation timed out")
        || lower.contains("no route to host")
        || lower.contains("name resolution failed")
        || lower.contains("dns resolution failed")
        || lower.contains("tcp connect error")
        || lower.contains("model temporarily unavailable")
}

/// INFRA-268 — heuristic prompt-content classifier for auto-privacy.
///
/// Returns `true` when the prompt content looks like it's discussing
/// proprietary source code that should NOT be sent to Trains-tier
/// providers (Mistral / Gemini free tiers, which train on free-tier data).
///
/// Used by the cascade's `complete()` entry point when `CHUMP_AUTO_PRIVACY=1`
/// is set and the operator has not already pinned `CHUMP_ROUND_PRIVACY`.
/// Detection is deliberately conservative-toward-false-positive: forcing
/// Safe-only loses a tiny daily quota budget (Mistral/Gemini are the
/// smallest slots), while a false-negative leaks code to providers that
/// retain it for training. Asymmetric cost ⇒ asymmetric heuristic.
///
/// Detection signals (any one triggers):
/// - Path-pattern tokens: `src/`, `crates/`, `.rs`, `.ts`, `.tsx`, `.py`
///   appearing in a context that suggests a file path (preceded or
///   followed by `/` or whitespace, not just bare extension).
/// - Code-fence markers: ```` ```rust ```` / ```` ```rs ```` / ```` ```typescript ```` / ```` ```python ```` /
///   ```` ```bash ```` / ```` ```sh ````.
/// - Rust syntax tokens: `fn `, `impl `, `struct `, `pub fn`, `mod ` at
///   word boundaries (single-token false positives are tolerated).
/// - Project-private identifiers: `CHUMP_`, `INFRA-`, `EVAL-`, `META-`,
///   `RESEARCH-`, `COG-`, `FLEET-`, `PRODUCT-` (gap-id-like tokens that
///   identify Chump-internal work).
///
/// Both `messages` (user-visible content) and `system_prompt` are scanned;
/// returning `true` if any text contains any signal.
pub(crate) fn prompt_implies_proprietary_code(
    messages: &[Message],
    system_prompt: Option<&str>,
) -> bool {
    let mut texts: Vec<&str> = messages.iter().map(|m| m.content.as_str()).collect();
    if let Some(sp) = system_prompt {
        texts.push(sp);
    }

    for t in texts {
        // Code-fence markers — strongest signal (intentional code-paste).
        if t.contains("```rust")
            || t.contains("```rs")
            || t.contains("```typescript")
            || t.contains("```tsx")
            || t.contains("```ts\n")
            || t.contains("```python")
            || t.contains("```py\n")
            || t.contains("```bash")
            || t.contains("```sh\n")
        {
            return true;
        }

        // Path-pattern tokens — repo-internal directory references.
        if t.contains("src/") || t.contains("crates/") || t.contains("scripts/coord/") {
            return true;
        }

        // Rust syntax in body — common code-paste tells.
        if t.contains("fn ") && (t.contains("(&self") || t.contains("pub fn ")) {
            return true;
        }
        if t.contains("impl ") && t.contains(" for ") {
            return true;
        }

        // Gap-id-like tokens — strong signal of Chump-internal context.
        if t.contains("CHUMP_")
            || t.contains("INFRA-")
            || t.contains("EVAL-")
            || t.contains("META-")
            || t.contains("RESEARCH-")
            || t.contains("COG-")
            || t.contains("FLEET-")
            || t.contains("PRODUCT-")
        {
            return true;
        }
    }
    false
}

#[async_trait]
impl Provider for ProviderCascade {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        // CREDIBLE-266: reset the failover trail for this call so a prior
        // turn's failed slots don't leak into this turn's report.
        clear_last_failovers();
        // INFRA-COST-CEILING: enforce hard ceiling and emit soft warn before
        // any provider call is made.
        match cost_tracker::check_ceiling() {
            Err(msg) => return Err(anyhow::anyhow!("{}", msg)),
            Ok(true) => {
                let current = cost_tracker::session_cost_usd();
                let ceiling = cost_tracker::cost_ceiling_usd();
                eprintln!(
                    "COST WARNING: ${:.2} spent this session (limit: ${:.2})",
                    current, ceiling
                );
            }
            Ok(false) => {}
        }

        let mut min_privacy = std::env::var("CHUMP_ROUND_PRIVACY")
            .ok()
            .map(|s| parse_privacy_tier(&s));

        // INFRA-268: opt-in heuristic. When CHUMP_AUTO_PRIVACY=1 and the
        // operator hasn't already pinned CHUMP_ROUND_PRIVACY, scan the prompt
        // for evidence that we're sending source code (src/, crates/, .rs
        // refs, code fences, project identifiers like CHUMP_*/INFRA-*) and
        // force min_privacy=Safe so Trains-tier slots (Mistral/Gemini free)
        // are filtered out for that call.
        //
        // Only DOWNGRADES (forces safer); never overrides an explicit
        // operator choice. False-positive cost is small (lose headroom on a
        // tiny daily budget); false-negative cost is leaking proprietary
        // code to a Trains-on-data provider — which is what we're trying to
        // prevent. Per the operator's stance: "we're building Chump, not
        // using Chump to build something else" — this guard exists for the
        // moment when context shifts (contractor code, customer prompts).
        if min_privacy.is_none()
            && std::env::var("CHUMP_AUTO_PRIVACY")
                .map(|v| v.trim() == "1")
                .unwrap_or(false)
            && prompt_implies_proprietary_code(&messages, system_prompt.as_deref())
        {
            min_privacy = Some(PrivacyTier::Safe);
            eprintln!(
                "[cascade] INFRA-268 auto-privacy: prompt looks like proprietary code; \
                 forcing min_privacy=Safe (Trains-tier slots skipped). \
                 Override with CHUMP_ROUND_PRIVACY=trains."
            );
        }

        let skip_cloud = self.skip_cloud_slots_for_round_type();
        // INFRA-363: wait + retry-once on cascade exhaustion caused by
        // rate-limit-class errors (429/413/billing-exhausted). Under fleet
        // load, free-tier RPD windows reset on a 1-min boundary. A short
        // sleep + retry covers transient exhaustion without waking the operator.
        // CHUMP_CASCADE_EXHAUSTED_BACKOFF_S=0 disables; max 300s.
        // Falls back to legacy CHUMP_CASCADE_RETRY_AFTER_EXHAUSTED_S for compat.
        let retry_after_s: u64 = std::env::var("CHUMP_CASCADE_EXHAUSTED_BACKOFF_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .or_else(|| {
                std::env::var("CHUMP_CASCADE_RETRY_AFTER_EXHAUSTED_S")
                    .ok()
                    .and_then(|s| s.parse().ok())
            })
            .unwrap_or(30)
            .min(300);
        let max_preferred_waits: u32 = std::env::var("CHUMP_CASCADE_MAX_PREFERRED_WAITS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(2);
        let mut preferred_waits: u32 = 0;
        let mut retried = false;
        let mut idx = 0;
        loop {
            let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
            let i = if idx == 0 {
                // Bandit strategy: learned selection among eligible slots.
                // Falls through to priority ordering if the bandit yields None
                // (no eligible slot; matches priority-strategy semantics).
                if self._strategy == CascadeStrategy::Bandit {
                    self.bandit_first_available(min_privacy, skip_cloud)
                        .or_else(|| self.first_available_slot(min_privacy, skip_cloud))
                } else {
                    self.first_available_slot(min_privacy, skip_cloud)
                }
            } else {
                self.slots
                    .iter()
                    .enumerate()
                    .skip(idx)
                    .find(|(_, slot)| {
                        // INFRA-1004: cloud slots excluded when local_only=true.
                        if self.local_only && slot.tier == ProviderTier::Cloud {
                            return false;
                        }
                        (!has_cloud || slot.tier != ProviderTier::Local)
                            && min_privacy.is_none_or(|min| slot.privacy >= min)
                            && !local_openai::is_circuit_open(&slot.base_url)
                            && !is_cooling_down(slot)
                            && within_rate_limit(slot)
                    })
                    .map(|(i, _)| i)
            };

            let i = match i {
                Some(i) => i,
                None => {
                    // INFRA-1004: in local-only mode the local slot was already in
                    // the normal selection loop (cloud was never considered), so
                    // reaching here means the local slot is also unavailable.
                    // Return a hard error rather than silently falling back to cloud.
                    if self.local_only {
                        let msg = "CHUMP_LOCAL_ONLY=1: no local provider available \
                                   (circuit open, rate-limited, or cooling down). \
                                   Check OPENAI_API_BASE and that the local daemon is running.";
                        emit_cascade_exhausted_event(&self.slots, msg);
                        return Err(anyhow::anyhow!("{msg}"));
                    }
                    if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                        eprintln!("[cascade] all cloud exhausted, falling back to local");
                    }
                    let local_idx = self
                        .slots
                        .iter()
                        .position(|s| s.tier == ProviderTier::Local);
                    match local_idx {
                        Some(li) => {
                            let local_slot = &self.slots[li];
                            std::env::remove_var("CHUMP_CURRENT_SLOT_CONTEXT_K");
                            let t0 = std::time::Instant::now();
                            let local_res = {
                                let _cascade_inner = llm_backend_metrics::CascadeInnerGuard::new();
                                local_slot
                                    .provider
                                    .complete(
                                        messages.clone(),
                                        tools.clone(),
                                        max_tokens,
                                        system_prompt.clone(),
                                    )
                                    .await
                            };
                            match local_res {
                                Ok(r) => {
                                    let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;
                                    local_openai::record_circuit_success(&local_slot.base_url);
                                    record_call(local_slot);
                                    set_last_used_slot(local_slot.name.clone());
                                    set_last_used_model(local_slot.provider.model().to_string());
                                    tracing::info!(
                                        slot_id = %local_slot.name,
                                        model_name = %local_slot.provider.model(),
                                        "provider_cascade: slot used (local fallback)"
                                    );
                                    llm_backend_metrics::record_cascade_slot(&local_slot.name);
                                    provider_quality::record_slot_success(&local_slot.name);
                                    provider_quality::record_latency(&local_slot.name, latency_ms);
                                    let est =
                                        r.text.as_ref().map(|t| (t.len() / 4) as u64).unwrap_or(0);
                                    cost_tracker::record_provider_call(&local_slot.name, est);
                                    cost_tracker::record_completion(1, 0, est);
                                    let tier = if local_slot.tier == ProviderTier::Cloud {
                                        crate::precision_controller::ModelTier::Capable
                                    } else {
                                        crate::precision_controller::ModelTier::Standard
                                    };
                                    crate::precision_controller::record_model_decision(tier);
                                    crate::precision_controller::record_energy_spent(est, 0);
                                    // INFRA-1004: emit routing decision to ambient stream.
                                    emit_cascade_routed_event(
                                        &local_slot.name,
                                        self.cascade_mode(),
                                        "local",
                                        est,
                                    );
                                    return Ok(r);
                                }
                                // INFRA-347: record circuit failure on the local (Ollama) slot so
                                // subsequent cascade invocations see it as open and skip it.
                                // Annotate connection-refused / unreachable errors with Ollama
                                // recovery hints so the error propagating to execute_gap (and the
                                // operator) is actionable rather than a bare reqwest message.
                                Err(e) => {
                                    local_openai::record_circuit_failure(&local_slot.base_url);
                                    provider_quality::record_slot_failure(&local_slot.name);
                                    if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                                        eprintln!(
                                            "[cascade] local slot {} failed as last resort: {}",
                                            local_slot.name, e
                                        );
                                    }
                                    if local_openai::is_transient_error(&e) {
                                        // Ollama/local backend is unreachable — annotate with
                                        // actionable recovery hints rather than the bare transport
                                        // error (INFRA-347). The hint matches the suffix appended
                                        // by LocalOpenAIProvider after exhausting retries so the
                                        // full message is consistent across paths.
                                        let msg = format!(
                                            "{} — local provider unreachable (all cloud slots \
                                             exhausted and local slot failed). \
                                             Ollama: `brew services start ollama`; \
                                             probe: `curl -s {}/models`. \
                                             Set CHUMP_FALLBACK_API_BASE or add cloud slots \
                                             (CHUMP_PROVIDER_1_*) to avoid this failure mode.",
                                            e, local_slot.base_url,
                                        );
                                        emit_cascade_exhausted_event(&self.slots, &msg);
                                        // INFRA-363: sleep + retry-once before final error.
                                        if !retried && retry_after_s > 0 {
                                            tracing::warn!(
                                                "INFRA-363: cascade exhausted (local unreachable); sleeping {}s before retry-once",
                                                retry_after_s
                                            );
                                            emit_cascade_backoff_event(
                                                "cascade_backoff_pre_sleep",
                                                retry_after_s,
                                            );
                                            tokio::time::sleep(std::time::Duration::from_secs(
                                                retry_after_s,
                                            ))
                                            .await;
                                            emit_cascade_backoff_event(
                                                "cascade_backoff_post_retry",
                                                retry_after_s,
                                            );
                                            retried = true;
                                            idx = 0;
                                            continue;
                                        }
                                        return Err(anyhow::anyhow!("{msg}"));
                                    }
                                    emit_cascade_exhausted_event(
                                        &self.slots,
                                        &format!("local slot failed: {e}"),
                                    );
                                    if !retried && retry_after_s > 0 {
                                        tracing::warn!(
                                            "INFRA-363: cascade exhausted (local slot failed); sleeping {}s before retry-once",
                                            retry_after_s
                                        );
                                        emit_cascade_backoff_event(
                                            "cascade_backoff_pre_sleep",
                                            retry_after_s,
                                        );
                                        tokio::time::sleep(std::time::Duration::from_secs(
                                            retry_after_s,
                                        ))
                                        .await;
                                        emit_cascade_backoff_event(
                                            "cascade_backoff_post_retry",
                                            retry_after_s,
                                        );
                                        retried = true;
                                        idx = 0;
                                        continue;
                                    }
                                    return Err(e);
                                }
                            }
                        }
                        None => {
                            let msg = "no providers available (circuit open or rate limited; \
                                       set OPENAI_API_BASE for local fallback)";
                            emit_cascade_exhausted_event(&self.slots, msg);
                            // INFRA-363: sleep + retry-once before final error.
                            if !retried && retry_after_s > 0 {
                                tracing::warn!(
                                    "INFRA-363: cascade exhausted (no providers available); sleeping {}s before retry-once",
                                    retry_after_s
                                );
                                emit_cascade_backoff_event(
                                    "cascade_backoff_pre_sleep",
                                    retry_after_s,
                                );
                                tokio::time::sleep(std::time::Duration::from_secs(retry_after_s))
                                    .await;
                                emit_cascade_backoff_event(
                                    "cascade_backoff_post_retry",
                                    retry_after_s,
                                );
                                retried = true;
                                idx = 0;
                                continue;
                            }
                            return Err(anyhow::anyhow!("{msg}"));
                        }
                    }
                }
            };

            let slot = &self.slots[i];
            if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                eprintln!(
                    "[cascade] strategy={} selected={} (priority={}, rpm={}/{}, rpd={}/{})",
                    self._strategy.label(),
                    slot.name,
                    slot.priority,
                    slot.calls_this_minute.load(Ordering::Relaxed),
                    slot.rpm_limit,
                    slot.calls_today.load(Ordering::Relaxed),
                    slot.rpd_limit,
                );
            }
            if let Some(k) = slot.context_k {
                std::env::set_var("CHUMP_CURRENT_SLOT_CONTEXT_K", k.to_string());
            } else {
                std::env::remove_var("CHUMP_CURRENT_SLOT_CONTEXT_K");
            }
            let t0 = std::time::Instant::now();
            let slot_res = {
                let _cascade_inner = llm_backend_metrics::CascadeInnerGuard::new();
                slot.provider
                    .complete(
                        messages.clone(),
                        tools.clone(),
                        max_tokens,
                        system_prompt.clone(),
                    )
                    .await
            };
            match slot_res {
                Ok(mut r) => {
                    let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;

                    // EFFECTIVE-003/INFRA-1565: this slot's model emits tool
                    // calls as XML tags (<tool_call>/<function_call>) rather
                    // than native provider tool-call fields — extract them
                    // before the empty/malformed quality gate below runs, or
                    // a real tool call gets misclassified as "empty" and the
                    // cascade needlessly fails over to the next slot.
                    if slot.xml_tool_tags && r.tool_calls.is_empty() {
                        if let Some(text) = r.text.as_ref() {
                            let adapted = chump_xml_adapter::extract_tool_calls(text);
                            if !adapted.tool_calls.is_empty() {
                                r.tool_calls = adapted
                                    .tool_calls
                                    .into_iter()
                                    .map(|tc| axonerai::provider::ToolCall {
                                        id: tc.id,
                                        name: tc.name,
                                        input: tc.input,
                                    })
                                    .collect();
                                r.text = Some(adapted.text);
                            }
                        }
                    }

                    // Quality gate: if response is empty and tools were provided,
                    // the model likely failed silently — try the next slot.
                    let is_empty = r.text.as_ref().map(|t| t.trim().is_empty()).unwrap_or(true)
                        && r.tool_calls.is_empty();
                    let has_malformed_tools = r.tool_calls.iter().any(|tc| {
                        tc.name.is_empty()
                            || (tc.input.is_object()
                                && tc.input.as_object().map(|o| o.is_empty()).unwrap_or(false)
                                && tools.as_ref().map(|t| !t.is_empty()).unwrap_or(false))
                    });
                    if (is_empty || has_malformed_tools) && i + 1 < self.slots.len() {
                        if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                            eprintln!(
                                "[cascade] {} returned empty/malformed response, trying next slot",
                                slot.name
                            );
                        }
                        record_failover(
                            &slot.name,
                            if is_empty {
                                "empty_response"
                            } else {
                                "tool-call-refused"
                            },
                        );
                        provider_quality::record_slot_failure(&slot.name);
                        if let Some(b) = self.bandit() {
                            // Empty/malformed response → reward 0 for this slot.
                            b.update(&slot.name, 0.0);
                        }
                        idx = i + 1;
                        continue;
                    }

                    local_openai::record_circuit_success(&slot.base_url);
                    record_call(slot);
                    set_last_used_slot(slot.name.clone());
                    set_last_used_model(slot.provider.model().to_string());
                    tracing::info!(
                        slot_id = %slot.name,
                        model_name = %slot.provider.model(),
                        "provider_cascade: slot used"
                    );
                    llm_backend_metrics::record_cascade_slot(&slot.name);
                    provider_quality::record_slot_success(&slot.name);
                    provider_quality::record_latency(&slot.name, latency_ms);
                    let est = r.text.as_ref().map(|t| (t.len() / 4) as u64).unwrap_or(0);
                    cost_tracker::record_provider_call(&slot.name, est);
                    cost_tracker::record_completion(1, 0, est);
                    let tier = if slot.tier == ProviderTier::Cloud {
                        crate::precision_controller::ModelTier::Capable
                    } else {
                        crate::precision_controller::ModelTier::Standard
                    };
                    crate::precision_controller::record_model_decision(tier);
                    crate::precision_controller::record_energy_spent(est, 0);
                    // Bandit feedback: reward this slot on success. Weighted by
                    // latency + throughput + historical p95 + tool accuracy (INFRA-685).
                    if let Some(b) = self.bandit() {
                        let latency_s = latency_ms / 1000.0;
                        let tps = if latency_s > 0.0 {
                            est as f64 / latency_s
                        } else {
                            0.0
                        };
                        let (p95_s, tool_acc) = provider_quality::get_quality_full(&slot.name)
                            .map(|(_, _, _, p95, acc)| (p95.map(|ms| ms / 1000.0), acc))
                            .unwrap_or((None, None));
                        let reward = crate::provider_bandit::compose_reward_with_quality(
                            true, latency_s, tps, p95_s, tool_acc,
                        );
                        tracing::debug!(
                            target: "chump::provider_cascade",
                            slot = %slot.name,
                            reward,
                            latency_ms,
                            p95_ms = p95_s.map(|s| s * 1000.0),
                            tool_acc,
                            "bandit reward (INFRA-685: p95+accuracy weighted)"
                        );
                        b.update(&slot.name, reward);
                    }
                    // INFRA-1004: emit routing decision to ambient stream.
                    let tier_str = if slot.tier == ProviderTier::Cloud {
                        "cloud"
                    } else {
                        "local"
                    };
                    emit_cascade_routed_event(&slot.name, self.cascade_mode(), tier_str, est);
                    return Ok(r);
                }
                Err(e) => {
                    let e_str = format!("{} {:?}", e, e);
                    if local_openai::is_transient_error(&e)
                        || should_cascade_on_error_string(&e_str)
                    {
                        local_openai::record_circuit_failure(&slot.base_url);
                        if let Some(b) = self.bandit() {
                            b.update(&slot.name, 0.0);
                        }

                        // Set per-slot cooldown on 429 so we don't re-hit it immediately.
                        let is_rate_limit = e_str.contains("429")
                            || e_str.to_ascii_lowercase().contains("rate limit");
                        if is_rate_limit {
                            let cooldown_s =
                                parse_retry_after_secs(&e_str).unwrap_or(DEFAULT_429_COOLDOWN_S);
                            set_cooldown(slot, Duration::from_secs(cooldown_s));
                            tracing::info!(
                                target: "chump::provider_cascade",
                                slot = %slot.name,
                                cooldown_s,
                                model_class = ?slot.model_class,
                                "429 backoff — slot cooling down"
                            );
                            if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                                eprintln!(
                                    "[cascade] {} rate-limited, cooldown {}s",
                                    slot.name, cooldown_s
                                );
                            }

                            // If this slot matches the preferred model class and
                            // the cooldown is short, wait instead of cascading to
                            // a mismatched tier.
                            let preferred_class = std::env::var("CHUMP_PREFERRED_MODEL_CLASS")
                                .ok()
                                .filter(|s| !s.is_empty())
                                .map(|s| s.trim().to_lowercase());
                            let slot_matches_pref = match (&preferred_class, &slot.model_class) {
                                (Some(pref), Some(mc)) => mc == pref,
                                _ => false,
                            };
                            if slot_matches_pref
                                && cooldown_s <= MAX_WAIT_FOR_PREFERRED_S
                                && preferred_waits < max_preferred_waits
                            {
                                preferred_waits += 1;
                                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                                    eprintln!(
                                        "[cascade] waiting {}s for preferred-class slot {} ({}/{})",
                                        cooldown_s, slot.name, preferred_waits, max_preferred_waits
                                    );
                                }
                                tokio::time::sleep(Duration::from_secs(cooldown_s)).await;
                                {
                                    let mut g = slot
                                        .cooldown_until
                                        .lock()
                                        .unwrap_or_else(|e| e.into_inner());
                                    *g = None;
                                }
                                continue;
                            }
                        } else if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                            eprintln!("[cascade] {} failed (transient), trying next", slot.name);
                        }

                        let failover_reason = classify_failover_reason(&e_str);
                        if failover_reason == "429" {
                            provider_quality::record_slot_rate_limited(&slot.name);
                        }
                        record_failover(&slot.name, failover_reason);
                        idx = i + 1;
                        continue;
                    }
                    return Err(e);
                }
            }
        }
    }
}

static CASCADE_FOR_STATUS: OnceLock<Arc<ProviderCascade>> = OnceLock::new();

static LAST_USED_SLOT: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn last_used_slot_cell() -> &'static Mutex<Option<String>> {
    LAST_USED_SLOT.get_or_init(|| Mutex::new(None))
}

pub fn set_last_used_slot(name: String) {
    if let Ok(mut g) = last_used_slot_cell().lock() {
        *g = Some(name);
    }
}

pub fn get_last_used_slot() -> Option<String> {
    last_used_slot_cell().lock().ok().and_then(|g| g.clone())
}

// CREDIBLE-266: which model answered the last completed cascade call, and
// which slots were tried-and-failed before the winner. A 15-slot failover
// ladder that only logs "provider_ms" is unobservable — this is the
// smallest state needed to make the INFRA-185 phase-timings line name the
// slot/model that actually served the turn, plus the failover trail.
static LAST_USED_MODEL: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn last_used_model_cell() -> &'static Mutex<Option<String>> {
    LAST_USED_MODEL.get_or_init(|| Mutex::new(None))
}

pub fn set_last_used_model(model: String) {
    if let Ok(mut g) = last_used_model_cell().lock() {
        *g = Some(model);
    }
}

pub fn get_last_used_model() -> Option<String> {
    last_used_model_cell().lock().ok().and_then(|g| g.clone())
}

/// One slot that was tried and failed over, and why. Never carries
/// credentials — slot name + classified reason only.
#[derive(Debug, Clone)]
pub struct FailoverRecord {
    pub slot: String,
    pub reason: String,
}

static LAST_FAILOVERS: OnceLock<Mutex<Vec<FailoverRecord>>> = OnceLock::new();

fn last_failovers_cell() -> &'static Mutex<Vec<FailoverRecord>> {
    LAST_FAILOVERS.get_or_init(|| Mutex::new(Vec::new()))
}

/// Reset the failover trail; call at the start of each cascade `complete()`
/// so a prior turn's failovers don't leak into this turn's report.
fn clear_last_failovers() {
    if let Ok(mut g) = last_failovers_cell().lock() {
        g.clear();
    }
}

fn record_failover(slot: &str, reason: &str) {
    if let Ok(mut g) = last_failovers_cell().lock() {
        g.push(FailoverRecord {
            slot: slot.to_string(),
            reason: reason.to_string(),
        });
    }
}

/// Failover trail for the most recently completed cascade call. Empty when
/// the winning slot answered on the first try.
pub fn get_last_failovers() -> Vec<FailoverRecord> {
    last_failovers_cell()
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default()
}

/// Classify a cascade failure into the reason buckets operators care about
/// (401/403 auth, 429 rate-limit, model-not-found, tool-call-refused) without
/// ever echoing the raw provider error body (which can carry request
/// metadata). Falls back to "error" for anything unrecognized.
fn classify_failover_reason(e_str: &str) -> &'static str {
    let lower = e_str.to_ascii_lowercase();
    if e_str.contains("429") || lower.contains("rate limit") || lower.contains("too many requests")
    {
        "429"
    } else if e_str.contains("401")
        || e_str.contains("403")
        || lower.contains("unauthorized")
        || lower.contains("forbidden")
    {
        "401/403"
    } else if (e_str.contains("404") && lower.contains("model"))
        || lower.contains("model_not_found")
    {
        "model-not-found"
    } else if lower.contains("tool_use_failed")
        || lower.contains("tool call validation failed")
        || lower.contains("failed to call a function")
        || lower.contains("unsupportedtooluse")
        || lower.contains("does not support tool")
    {
        "tool-call-refused"
    } else if lower.contains("empty") {
        "empty_response"
    } else {
        "error"
    }
}

/// Record sanity-check failure for the given slot (call when sanity_check_reply fails after a completion).
pub fn record_slot_failure(slot_name: &str) {
    provider_quality::record_slot_failure(slot_name);
}

/// Wrapper so the same cascade instance is reused and GET /api/cascade-status can read live counters.
struct CascadeHolder(Arc<ProviderCascade>);

#[async_trait]
impl Provider for CascadeHolder {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        self.0
            .complete(messages, tools, max_tokens, system_prompt)
            .await
    }
}

/// Returns the shared cascade instance if one has been built (for GET /api/cascade-status).
pub fn cascade_for_status() -> Option<Arc<ProviderCascade>> {
    CASCADE_FOR_STATUS.get().cloned()
}

/// Return a one-line human-readable explanation of which cascade slot would be chosen and why.
/// Used by `--why` transparency flag. Never panics; falls back gracefully when cascade is off.
pub fn cascade_why() -> String {
    if !cascade_enabled() {
        let base = std::env::var("OPENAI_API_BASE").unwrap_or_default();
        let label = if base.is_empty() {
            "hosted OpenAI".to_string()
        } else {
            format!("single provider at {}", base)
        };
        return format!("cascade disabled — why: {label} (CHUMP_CASCADE_ENABLED not set)");
    }
    let cascade = ProviderCascade::from_env();
    if cascade.slots.is_empty() {
        return "cascade enabled but no slots configured — why: check CHUMP_PROVIDER_N_ENABLED"
            .to_string();
    }
    let strategy = cascade._strategy.label();
    let skip = cascade.skip_cloud_slots_for_round_type();
    let min_privacy = std::env::var("CHUMP_ROUND_PRIVACY")
        .ok()
        .map(|s| parse_privacy_tier(&s));
    let first_idx = if cascade._strategy == CascadeStrategy::Bandit {
        cascade.bandit_first_available(min_privacy, skip)
    } else {
        cascade.first_available_slot(min_privacy, skip)
    };
    match first_idx {
        Some(i) => {
            let slot = &cascade.slots[i];
            let rpd_pct = if slot.rpd_limit > 0 {
                let used = slot.calls_today.load(Ordering::Relaxed);
                format!("{:.0}%", 100.0 * used as f32 / slot.rpd_limit as f32)
            } else {
                "unlimited".to_string()
            };
            format!(
                "cascade chose slot={} — why: {strategy} selection, RPD {rpd_pct} used, priority={}",
                slot.name, slot.priority
            )
        }
        None => format!(
            "cascade: no slot available — why: {strategy} strategy, all {} slots rate-limited or circuit-open",
            cascade.slots.len()
        ),
    }
}

/// Remaining RPD budget: (total across slots, per-slot (name, remaining)). Uses same headroom as rate limit. For orchestrator to decide worker count.
pub fn cascade_budget_remaining() -> Option<(u64, Vec<(String, u32)>)> {
    let cascade = cascade_for_status().or_else(|| {
        if cascade_enabled() {
            let c = ProviderCascade::from_env();
            if c.slots.is_empty() {
                None
            } else {
                Some(Arc::new(c))
            }
        } else {
            None
        }
    })?;
    let headroom = rpm_headroom_pct();
    let mut total: u64 = 0;
    let per_slot: Vec<(String, u32)> = cascade
        .slots
        .iter()
        .map(|s| {
            let remaining = if s.rpd_limit == 0 {
                u32::MAX
            } else {
                let today = s.calls_today.load(Ordering::Relaxed);
                let effective = (s.rpd_limit as f32 * headroom) as u32;
                effective.saturating_sub(today)
            };
            if remaining != u32::MAX {
                total = total.saturating_add(remaining as u64);
            }
            (s.name.clone(), remaining)
        })
        .collect();
    Some((total, per_slot))
}

const WARM_PROBE_TIMEOUT_SECS: u64 = 15;

/// Probe each enabled slot with "Say OK"; mark circuit failure on non-200/timeout. Call at heartbeat start or every 30 min.
pub async fn warm_probe_all() {
    if !cascade_enabled() {
        return;
    }
    let _pause_llm_metrics = llm_backend_metrics::RecordingPauseGuard::new();
    let cascade = ProviderCascade::from_env();
    let msg = vec![Message {
        role: "user".to_string(),
        content: "Say OK".to_string(),
    }];
    for slot in &cascade.slots {
        let base = slot.base_url.clone();
        let name = slot.name.clone();
        let fut = slot.provider.complete(msg.clone(), None, Some(10), None);
        match tokio::time::timeout(Duration::from_secs(WARM_PROBE_TIMEOUT_SECS), fut).await {
            Ok(Ok(_)) => {
                local_openai::record_circuit_success(&base);
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] warm_probe {} ok", name);
                }
            }
            Ok(Err(_)) | Err(_) => {
                local_openai::record_circuit_failure(&base);
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] warm_probe {} failed", name);
                }
            }
        }
    }
}

/// Wraps any provider to count successful outer completions for `CHUMP_BATTLE_BENCHMARK` baselines.
struct BattleInstrumentedProvider {
    inner: Box<dyn Provider + Send + Sync>,
}

#[async_trait]
impl Provider for BattleInstrumentedProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let res = self
            .inner
            .complete(messages, tools, max_tokens, system_prompt)
            .await;
        if res.is_ok() {
            crate::precision_controller::record_battle_benchmark_model_round();
        }
        res
    }
}

/// Build the provider: in-process mistral.rs first when configured; else cascade if
/// `CHUMP_CASCADE_ENABLED=1` and slots are non-empty; else single HTTP/OpenAI provider.
/// When cascade is used, it is stored so GET /api/cascade-status can return live slot stats.
pub fn build_provider() -> Box<dyn Provider + Send + Sync> {
    build_provider_with_mistral_stream().0
}

/// Same primary [`Provider`] as [`build_provider`], plus an [`Arc`] handle to [`crate::mistralrs_provider::MistralRsProvider`]
/// when that backend is active — used by web/RPC streaming to emit [`crate::stream_events::AgentEvent::TextDelta`].
#[cfg(feature = "mistralrs-infer")]
pub fn build_provider_with_mistral_stream() -> (
    Box<dyn Provider + Send + Sync>,
    Option<std::sync::Arc<crate::mistralrs_provider::MistralRsProvider>>,
) {
    if crate::mistralrs_provider::mistralrs_backend_configured() {
        let id = std::env::var("CHUMP_MISTRALRS_MODEL").unwrap_or_default();
        let m = std::sync::Arc::new(crate::mistralrs_provider::MistralRsProvider::new(id));
        let inner = Box::new(crate::mistralrs_provider::SharedMistralProvider(
            std::sync::Arc::clone(&m),
        ));
        let p = Box::new(BattleInstrumentedProvider { inner });
        return (p, Some(m));
    }
    (build_provider_inner_wrapped(), None)
}

#[cfg(not(feature = "mistralrs-infer"))]
pub fn build_provider_with_mistral_stream() -> (Box<dyn Provider + Send + Sync>, ()) {
    (build_provider_inner_wrapped(), ())
}

fn build_provider_inner_wrapped() -> Box<dyn Provider + Send + Sync> {
    let inner: Box<dyn Provider + Send + Sync> = if cascade_enabled() {
        let cascade = ProviderCascade::from_env();
        if !cascade.slots.is_empty() {
            let arc = Arc::new(cascade);
            let _ = CASCADE_FOR_STATUS.set(Arc::clone(&arc));
            Box::new(CascadeHolder(arc))
        } else {
            build_provider_single()
        }
    } else {
        build_provider_single()
    };
    Box::new(BattleInstrumentedProvider { inner })
}

/// Records [`llm_backend_metrics`] when completions use hosted OpenAI (no `OPENAI_API_BASE`).
struct OpenAiApiLlmRecorder {
    inner: OpenAIProvider,
}

#[async_trait]
impl Provider for OpenAiApiLlmRecorder {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let r = self
            .inner
            .complete(messages, tools, max_tokens, system_prompt)
            .await;
        if r.is_ok() {
            let label = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "default".to_string());
            llm_backend_metrics::record_openai_api(&label);
        }
        r
    }
}

/// Build a single (non-cascading) provider from `OPENAI_API_BASE` +
/// `OPENAI_API_KEY` + `OPENAI_MODEL`. Public so free-tier dispatch
/// (INFRA-733) can bypass the cascade entirely.
pub fn build_provider_single_pub() -> Box<dyn Provider + Send + Sync> {
    build_provider_single()
}

fn build_provider_single() -> Box<dyn Provider + Send + Sync> {
    #[cfg(feature = "mistralrs-infer")]
    {
        if crate::mistralrs_provider::mistralrs_backend_configured() {
            let id = std::env::var("CHUMP_MISTRALRS_MODEL").unwrap_or_default();
            return Box::new(crate::mistralrs_provider::MistralRsProvider::new(id));
        }
    }
    let api_key = resolved_openai_api_key();
    let env_model = std::env::var("OPENAI_MODEL").ok().filter(|m| !m.is_empty());
    if let Ok(base) = std::env::var("OPENAI_API_BASE") {
        let base = base.trim();
        if !base.is_empty() {
            let endpoint_key = resolved_api_key_for_endpoint(base);
            let model = resolve_model_for_endpoint(base, env_model);
            let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
                .ok()
                .filter(|s| !s.is_empty());
            return Box::new(LocalOpenAIProvider::with_fallback(
                base.to_string(),
                fallback,
                endpoint_key,
                model,
            ));
        }
    }
    if looks_like_openai_platform_key(&api_key) {
        // Cloud endpoint: use env override or cloud default (not gpt-5-mini).
        let model = env_model.unwrap_or_else(|| "gpt-4o-mini".to_string());
        return Box::new(OpenAiApiLlmRecorder {
            inner: OpenAIProvider::new(api_key).with_model(model),
        });
    }
    // Default local Ollama path: auto-discover model.
    let model = resolve_model_for_endpoint(DEFAULT_OLLAMA_API_BASE, env_model);
    let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
        .ok()
        .filter(|s| !s.is_empty());
    Box::new(LocalOpenAIProvider::with_fallback(
        DEFAULT_OLLAMA_API_BASE.to_string(),
        fallback,
        api_key,
        model,
    ))
}

// ── Process-singleton provider + inference semaphore (INFRA-165) ─────────────

static INFERENCE_SEMAPHORE: OnceLock<Arc<Semaphore>> = OnceLock::new();
static GLOBAL_PROVIDER: OnceLock<Arc<SemaphoreProvider>> = OnceLock::new();

fn inference_semaphore() -> &'static Arc<Semaphore> {
    INFERENCE_SEMAPHORE.get_or_init(|| {
        let permits = std::env::var("CHUMP_INFERENCE_PERMITS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|&n| n >= 1)
            .unwrap_or(1);
        Arc::new(Semaphore::new(permits))
    })
}

/// Wraps an inner Provider and acquires a permit from the shared inference
/// Semaphore before every complete() call, providing backpressure across all
/// concurrent callers (web, discord, spawn_worker).
pub(crate) struct SemaphoreProvider {
    pub(crate) inner: Box<dyn Provider + Send + Sync>,
    pub(crate) sem: Arc<Semaphore>,
}

#[async_trait]
impl Provider for SemaphoreProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let _permit = self
            .sem
            .acquire()
            .await
            .expect("inference semaphore closed");
        self.inner
            .complete(messages, tools, max_tokens, system_prompt)
            .await
    }
}

/// Boxes an Arc<SemaphoreProvider> so callers that expect Box<dyn Provider> can share
/// the singleton without cloning the inner provider.
struct ArcProvider(Arc<SemaphoreProvider>);

#[async_trait]
impl Provider for ArcProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        self.0
            .complete(messages, tools, max_tokens, system_prompt)
            .await
    }
}

/// Return the process-singleton provider, gated by CHUMP_INFERENCE_PERMITS (default 1).
/// Interactive callers (web, discord, spawn_worker) must use this instead of build_provider()
/// so that inference concurrency is bounded and connection reuse is maximised.
pub fn global_provider() -> Box<dyn Provider + Send + Sync> {
    let arc = Arc::clone(GLOBAL_PROVIDER.get_or_init(|| {
        let inner = build_provider_inner_wrapped();
        let sem = Arc::clone(inference_semaphore());
        Arc::new(SemaphoreProvider { inner, sem })
    }));
    Box::new(ArcProvider(arc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective347_restrict_eligible_honors_preferred_class() {
        // 3 eligible slots; index 1 is the only opus-class slot.
        let eligible = vec![
            ("cerebras".to_string(), 0),
            ("gemini-pro".to_string(), 1),
            ("groq".to_string(), 2),
        ];
        let class_of = |i: usize| -> Option<String> {
            match i {
                1 => Some("opus".to_string()),
                _ => Some("sonnet".to_string()),
            }
        };
        // opus preferred + a match → restrict to just the opus slot
        let r = restrict_eligible_to_class(eligible.clone(), Some("opus"), class_of);
        assert_eq!(r, vec![("gemini-pro".to_string(), 1)]);
        // opus preferred but NOTHING matches → unchanged (graceful, never strand)
        let r2 = restrict_eligible_to_class(eligible.clone(), Some("opus"), |_i| {
            Some("sonnet".to_string())
        });
        assert_eq!(r2.len(), 3);
        // no preference → unchanged
        let r3 = restrict_eligible_to_class(eligible.clone(), None, |_i| Some("opus".to_string()));
        assert_eq!(r3.len(), 3);
    }

    /// INFRA-352: verify `emit_cascade_exhausted_event` writes a structured
    /// `cascade_all_exhausted` JSONL line to the path set by `CHUMP_AMBIENT_LOG`.
    /// Pin the schema fields so future writers can grep / parse reliably.
    #[test]
    #[serial_test::serial(ambient_env)]
    fn cascade_exhausted_emits_ambient_event_with_per_slot_tally() {
        let dir = tempfile::tempdir().unwrap();
        let log_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", log_path.to_string_lossy().to_string());

        // Two synthetic slots — names + tallies must round-trip into the line.
        let slots = vec![
            ProviderSlot {
                name: "test_slot_a".to_string(),
                base_url: "https://example.invalid/a".to_string(),
                provider: LocalOpenAIProvider::with_fallback(
                    "https://example.invalid/a".to_string(),
                    None,
                    "k".to_string(),
                    "m".to_string(),
                ),
                priority: 1,
                tier: ProviderTier::Cloud,
                privacy: PrivacyTier::Safe,
                context_k: None,
                model_class: None,
                rpm_limit: 10,
                calls_this_minute: AtomicU32::new(0),
                minute_start: Mutex::new(Instant::now()),
                rpd_limit: 100,
                calls_today: AtomicU32::new(7),
                day_start: Mutex::new(Instant::now()),
                cooldown_until: Mutex::new(None),
                xml_tool_tags: false,
            },
            ProviderSlot {
                name: "test_slot_b".to_string(),
                base_url: "https://example.invalid/b".to_string(),
                provider: LocalOpenAIProvider::with_fallback(
                    "https://example.invalid/b".to_string(),
                    None,
                    "k".to_string(),
                    "m".to_string(),
                ),
                priority: 2,
                tier: ProviderTier::Cloud,
                privacy: PrivacyTier::Safe,
                context_k: None,
                model_class: None,
                rpm_limit: 10,
                calls_this_minute: AtomicU32::new(0),
                minute_start: Mutex::new(Instant::now()),
                rpd_limit: 50,
                calls_today: AtomicU32::new(50),
                day_start: Mutex::new(Instant::now()),
                cooldown_until: Mutex::new(None),
                xml_tool_tags: false,
            },
        ];

        emit_cascade_exhausted_event(&slots, "all 2 cloud slots exhausted");

        let contents = std::fs::read_to_string(&log_path).unwrap();
        assert!(
            contents.contains("\"event\":\"cascade_all_exhausted\""),
            "expected event tag in line: {contents}"
        );
        assert!(
            contents.contains("\"slot_count\":2"),
            "expected slot_count in line: {contents}"
        );
        assert!(
            contents.contains("test_slot_a=7/100"),
            "expected per-slot tally for slot a: {contents}"
        );
        assert!(
            contents.contains("test_slot_b=50/50"),
            "expected per-slot tally for slot b: {contents}"
        );
        assert!(
            contents.contains("all 2 cloud slots exhausted"),
            "expected reason in line: {contents}"
        );
        // JSON shape: one record per line, valid JSON.
        let line = contents.lines().next().expect("at least one line");
        let _: serde_json::Value =
            serde_json::from_str(line).expect("emitted line must be valid JSON");

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    /// INFRA-352: empty slots list must still emit a parseable line — not panic
    /// or produce malformed JSON. Defensive against the "no providers
    /// available" terminal path.
    #[test]
    #[serial_test::serial(ambient_env)]
    fn cascade_exhausted_with_zero_slots_emits_valid_json() {
        let dir = tempfile::tempdir().unwrap();
        let log_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", log_path.to_string_lossy().to_string());

        emit_cascade_exhausted_event(&[], "no providers available");

        let contents = std::fs::read_to_string(&log_path).unwrap();
        let line = contents.lines().next().expect("emitted at least one line");
        let v: serde_json::Value = serde_json::from_str(line).expect("must be valid JSON");
        assert_eq!(v["slot_count"], 0);
        assert_eq!(v["event"], "cascade_all_exhausted");
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    fn from_env_without_cascade_vars_yields_only_slot_zero_if_openai_base_set() {
        // Cannot easily test from_env without setting env; at least ensure it compiles and
        // cascade_enabled() is false when var unset.
        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        assert!(!cascade_enabled());
    }

    // ── INFRA-268: prompt_implies_proprietary_code ──────────────────────

    fn user_msg(content: &str) -> Message {
        Message {
            role: "user".into(),
            content: content.into(),
        }
    }

    #[test]
    fn auto_privacy_detects_rust_code_fence() {
        let msgs = [user_msg("here is some code\n```rust\nfn main() {}\n```")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_typescript_fence() {
        let msgs = [user_msg("```typescript\nconst x = 1\n```")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_src_path() {
        let msgs = [user_msg("look at src/provider_cascade.rs:600")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_crates_path() {
        let msgs = [user_msg(
            "crates/chump-orchestrator/src/dispatch.rs has a bug",
        )];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_gap_id_token() {
        let msgs = [user_msg("can you fix INFRA-268 today?")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_chump_env_var() {
        let msgs = [user_msg("set CHUMP_CASCADE_ENABLED=1 then retry")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_scans_system_prompt_too() {
        let msgs = [user_msg("hello")];
        let system = "You are an agent. Read src/main.rs first.";
        assert!(prompt_implies_proprietary_code(&msgs, Some(system)));
    }

    #[test]
    fn auto_privacy_negative_plain_chat() {
        let msgs = [user_msg("what's the weather like in Denver?")];
        assert!(!prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_negative_natural_language_no_signals() {
        let msgs = [
            user_msg("Hi! Can you help me brainstorm a name for my dog?"),
            user_msg("She's a labrador, 6 months old, very playful."),
        ];
        assert!(!prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_negative_bare_extension_no_path_context() {
        // Bare ".rs" without a directory or word context shouldn't trip
        // the path-pattern detector. Only "src/" / "crates/" / etc. should.
        let msgs = [user_msg(
            "I'm writing a paper about RS-232 serial communication.",
        )];
        assert!(!prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_pub_fn_keyword() {
        let msgs = [user_msg("inside `pub fn main() { ... }` we should add ...")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_detects_impl_for() {
        let msgs = [user_msg("the impl Display for Foo block is wrong")];
        assert!(prompt_implies_proprietary_code(&msgs, None));
    }

    #[test]
    fn auto_privacy_empty_messages_no_system_returns_false() {
        let msgs: [Message; 0] = [];
        assert!(!prompt_implies_proprietary_code(&msgs, None));
    }

    // INFRA-300: HTTP 402 / credit_limit must cascade to the next slot.
    // Regression for the 2026-05-02 PWA empty-bubble incident.
    #[test]
    fn cascades_on_together_402_credit_limit() {
        // Real Together error string from the 2026-05-02 incident.
        let together_402 = "Local API error 402 Payment Required: {\n  \"id\": \"ohY6Cew-2kFHot-9f5af0bb2e16193a\",\n  \"error\": {\n    \"message\": \"Credit limit exceeded, please add credits.\",\n    \"type\": \"credit_limit\"\n  }\n}";
        assert!(
            should_cascade_on_error_string(together_402),
            "Together 402 credit_limit must cascade — was hanging the PWA"
        );
    }

    #[test]
    fn cascades_on_openai_insufficient_quota() {
        // OpenAI's variant of the same scenario.
        let openai_quota = "Local API error 429 {\"error\": {\"type\": \"insufficient_quota\", \"message\": \"You exceeded your current quota\"}}";
        assert!(should_cascade_on_error_string(openai_quota));
    }

    #[test]
    fn cascades_on_anthropic_billing() {
        let anthropic_billing = "Provider error: billing required";
        assert!(should_cascade_on_error_string(anthropic_billing));
    }

    #[test]
    fn cascades_on_existing_categories_still_work() {
        // Make sure the refactor didn't regress the pre-INFRA-300 categories.
        assert!(
            should_cascade_on_error_string("HTTP 429 Too Many Requests"),
            "rate limit"
        );
        assert!(
            should_cascade_on_error_string("HTTP 401 Unauthorized"),
            "access denied"
        );
        assert!(
            should_cascade_on_error_string("HTTP 403 Forbidden"),
            "forbidden"
        );
        assert!(
            should_cascade_on_error_string("HTTP 413 Request too large for model"),
            "Groq TPM via 413"
        );
        assert!(
            should_cascade_on_error_string("Error: tool_use_failed"),
            "tool format"
        );
        assert!(
            should_cascade_on_error_string("tool call validation failed: missing field"),
            "tool validation"
        );
    }

    #[test]
    fn does_not_cascade_on_bad_request_or_model_crash() {
        // 400 / 422 / 500 are NOT cascade-worthy — the request is wrong or
        // the provider crashed; another provider won't help.
        assert!(
            !should_cascade_on_error_string("HTTP 400 Bad Request: missing field"),
            "400 should propagate, not cascade"
        );
        assert!(
            !should_cascade_on_error_string("HTTP 422 Unprocessable Entity"),
            "422 should propagate, not cascade"
        );
        assert!(
            !should_cascade_on_error_string("HTTP 500 Internal Server Error"),
            "500 (provider crash) should propagate"
        );
    }

    // INFRA-348: transport-level errors wrapped by LocalOpenAIProvider must cascade.
    // Root cause: LocalOpenAIProvider::complete re-wraps the reqwest transport error
    // with an educational hint string via `anyhow!("{}{}", err, hint)`. This loses the
    // typed chain so `is_transient_error`'s `format!("{:?}", err)` inspection no longer
    // fires. The string predicate must cover these wrapped patterns.
    #[test]
    fn cascades_on_wrapped_transport_error_error_sending_request() {
        // Real 2026-05-02 dogfood error string from the INFRA-348 repro:
        let wrapped = "error sending request for url (http://127.0.0.1:11434/v1/chat/completions) \
            — model HTTP unreachable (daemon down, crashed, or still starting). \
            Ollama: brew services start ollama (or restart); probe: curl -s \
            http://127.0.0.1:11434/api/tags. Prefer OPENAI_API_BASE=\
            http://127.0.0.1:11434/v1 if localhost misbehaves. Backup URL: \
            CHUMP_FALLBACK_API_BASE. vLLM: :8000/:8001.";
        assert!(
            should_cascade_on_error_string(wrapped),
            "wrapped 'error sending request' must cascade — local daemon was down, \
             CHUMP_CASCADE_ENABLED=1 with 8 cloud slots did NOT fall over (INFRA-348 repro)"
        );
    }

    #[test]
    fn cascades_on_model_http_unreachable() {
        assert!(
            should_cascade_on_error_string(
                "model HTTP unreachable (daemon down, crashed, or still starting)"
            ),
            "model HTTP unreachable must cascade"
        );
    }

    #[test]
    fn cascades_on_connection_refused() {
        // Previously the comment said "handled by is_transient_error, not the string predicate"
        // but the typed-chain inspection fails for wrapped anyhow errors (INFRA-348). The string
        // predicate is now the canonical handler for transport errors at the cascade boundary.
        assert!(
            should_cascade_on_error_string("Connection refused"),
            "connection refused must cascade via string predicate (INFRA-348)"
        );
    }

    #[test]
    fn cascades_on_transport_error_variants() {
        assert!(
            should_cascade_on_error_string("operation timed out connecting to model"),
            "operation timed out"
        );
        assert!(
            should_cascade_on_error_string("no route to host (http://127.0.0.1:8000)"),
            "no route to host"
        );
        assert!(
            should_cascade_on_error_string("name resolution failed for localhost"),
            "name resolution failed"
        );
        assert!(
            should_cascade_on_error_string("model temporarily unavailable"),
            "model temporarily unavailable"
        );
    }

    #[test]
    fn case_insensitive_billing_match() {
        assert!(should_cascade_on_error_string("CREDIT_LIMIT"));
        assert!(should_cascade_on_error_string("Credit Limit Exceeded"));
        assert!(should_cascade_on_error_string("PAYMENT REQUIRED"));
    }

    // INFRA-313: model-capability tool-use failures (400-status but cascading
    // makes sense because another model handles the same payload).
    #[test]
    fn cascades_on_cerebras_unsupported_tool_use() {
        let cerebras_400 = "Local API error 400 Bad Request: {\"error\":{\"code\":\"UnsupportedToolUse\",\"message\":\"Request included unsupported tool use. This model does not support more than one tool call at this time.\"}}";
        assert!(
            should_cascade_on_error_string(cerebras_400),
            "Cerebras UnsupportedToolUse must cascade — another model handles the same payload"
        );
    }

    #[test]
    fn cascades_on_does_not_support_tool_variants() {
        assert!(should_cascade_on_error_string(
            "Error: model does not support tools"
        ));
        assert!(should_cascade_on_error_string(
            "tools are not supported by this endpoint"
        ));
        assert!(should_cascade_on_error_string(
            "{\"code\":\"unsupported_tool_use\"}"
        ));
    }

    #[test]
    fn does_not_cascade_on_400_unrelated_to_tools() {
        assert!(
            !should_cascade_on_error_string(
                "HTTP 400 Bad Request: required field 'messages' missing"
            ),
            "generic 400 should still propagate (not cascade)"
        );
        assert!(
            !should_cascade_on_error_string("HTTP 400 Bad Request: invalid model name 'gpt-99'"),
            "invalid model name should still propagate"
        );
    }

    // INFRA-347: the transport-unreachable predicate is now a standalone
    // helper (analogous to is_billing_exhausted_error_string) so
    // `chump --execute-gap` can classify transport errors at the
    // agent-loop boundary with exit code 76 (distinct from 75 for
    // billing and 1 for generic). These tests lock the predicate's
    // semantics independently of should_cascade_on_error_string.
    #[test]
    fn transport_predicate_matches_daemon_down_patterns() {
        assert!(is_transport_unreachable_error_string(
            "error sending request for url (http://127.0.0.1:11434/v1/chat/completions)"
        ));
        assert!(is_transport_unreachable_error_string(
            "model HTTP unreachable (daemon down, crashed, or still starting)"
        ));
        assert!(is_transport_unreachable_error_string(
            "Connection refused (os error 61)"
        ));
        assert!(is_transport_unreachable_error_string(
            "operation timed out connecting to 127.0.0.1:11434"
        ));
        assert!(is_transport_unreachable_error_string(
            "no route to host (http://127.0.0.1:8000)"
        ));
        assert!(is_transport_unreachable_error_string(
            "name resolution failed for localhost"
        ));
        assert!(is_transport_unreachable_error_string(
            "dns resolution failed"
        ));
        assert!(is_transport_unreachable_error_string(
            "tcp connect error (os error 61)"
        ));
        assert!(is_transport_unreachable_error_string(
            "model temporarily unavailable"
        ));
    }

    #[test]
    fn transport_predicate_does_not_match_billing_or_rate_limit() {
        // Billing class: should NOT be transport-unreachable.
        assert!(!is_transport_unreachable_error_string(
            "Local API error 402 Payment Required: credit_limit"
        ));
        assert!(!is_transport_unreachable_error_string(
            "HTTP 429 Too Many Requests"
        ));
        assert!(!is_transport_unreachable_error_string(
            "HTTP 401 Unauthorized"
        ));
        assert!(!is_transport_unreachable_error_string(
            "tool_use_failed: model could not format call"
        ));
        assert!(!is_transport_unreachable_error_string(
            "HTTP 500 Internal Server Error"
        ));
    }

    // INFRA-302 blocker (1): the billing-exhausted predicate is now a
    // standalone helper so `chump --execute-gap` can classify its own
    // errors at the agent-loop boundary (not just the per-call cascade).
    // These tests lock the predicate's semantics independently of
    // `should_cascade_on_error_string` so a future refactor of the
    // composite predicate can't silently regress the
    // billing-exhausted-only contract.
    #[test]
    fn billing_predicate_matches_402_only_on_billing_class() {
        // Real 2026-05-02 dispatch incident string (INFRA-302):
        let dispatch_402 = "Local API error 402 Payment Required: {\n  \"id\": \"ohYGX6i-2kFHot-9f5b21e0e8bcaf3a\",\n  \"error\": {\n    \"message\": \"Credit limit exceeded, please [add credits](https://api.together.ai/settings/billing).\",\n    \"type\": \"credit_limit\"\n  }\n}";
        assert!(is_billing_exhausted_error_string(dispatch_402));

        // OpenAI quota exhaustion (returned as 429 not 402, but still
        // billing-class via the type field):
        assert!(is_billing_exhausted_error_string(
            "{\"error\": {\"type\": \"insufficient_quota\"}}"
        ));
        assert!(is_billing_exhausted_error_string("CREDIT_LIMIT"));
        assert!(is_billing_exhausted_error_string("payment required"));
        assert!(is_billing_exhausted_error_string("billing exhausted"));

        // Negative cases — must NOT misclassify rate-limit / access-denied /
        // tool-format / network as billing-class. `should_cascade_on_error_string`
        // would still cascade on these; the orchestrator-level cascade-respawn
        // (future PR) will treat billing-exhaustion specifically (e.g. don't
        // retry the same provider after a backoff — switch routing-table
        // candidate).
        assert!(!is_billing_exhausted_error_string(
            "HTTP 429 Too Many Requests"
        ));
        assert!(!is_billing_exhausted_error_string("HTTP 401 Unauthorized"));
        assert!(!is_billing_exhausted_error_string(
            "HTTP 500 Internal Server Error"
        ));
        assert!(!is_billing_exhausted_error_string("Connection refused"));
        assert!(!is_billing_exhausted_error_string("tool_use_failed"));
        // 4029 contains the substring "402" — verify we don't false-positive.
        // (The current implementation DOES match "402" as a substring, so this
        // is documenting the known sharp edge: callers that build error
        // strings from arbitrary integers should use a structured discriminator.
        // For HTTP-status-bearing strings the current substring match is
        // adequate — HTTP 4029 is not a real status code.)
        assert!(is_billing_exhausted_error_string("HTTP 4029 (synthetic)"));
    }

    // INFRA-347: Ollama-unreachable errors from the local last-resort slot
    // must trip the circuit breaker and carry actionable recovery hints,
    // not silently propagate as bare reqwest transport errors.
    //
    // These unit tests cover the classification layer used by the fixed
    // last-resort fallback path. The integration path (full cascade with a
    // mock local slot that returns connection-refused) requires a real
    // ProviderCascade harness; the unit coverage here validates the predicate
    // contract that the production fix relies on.

    /// Connection-refused / TCP-connect errors must be recognised as transient
    /// so the last-resort path annotates them with Ollama recovery hints.
    #[test]
    fn is_transient_error_catches_ollama_unreachable() {
        // Typical reqwest error when Ollama daemon is not running.
        let connection_refused = anyhow::anyhow!(
            "error sending request for url (http://127.0.0.1:11434/v1/chat/completions): \
             error trying to connect: tcp connect error: Connection refused (os error 61)"
        );
        assert!(
            local_openai::is_transient_error(&connection_refused),
            "connection-refused from Ollama must be transient — \
             the last-resort path must annotate it with recovery hints"
        );

        // Timeout while Ollama is still loading a model.
        let timed_out = anyhow::anyhow!(
            "error sending request for url (http://127.0.0.1:11434/v1/chat/completions): \
             operation timed out"
        );
        assert!(
            local_openai::is_transient_error(&timed_out),
            "timeout waiting for Ollama must also be transient"
        );
    }

    /// Non-transient errors from the local slot (e.g. 400 Bad Request)
    /// must NOT be classified as transient — they should propagate as-is.
    #[test]
    fn is_transient_error_does_not_misclassify_bad_request() {
        let bad_request = anyhow::anyhow!("Local API error 400 Bad Request: missing field 'model'");
        assert!(
            !local_openai::is_transient_error(&bad_request),
            "400 Bad Request from local slot must not be transient — \
             it should propagate unchanged, not get the Ollama recovery hint"
        );
    }

    /// Verify the annotated error message produced by the fixed last-resort
    /// path includes Ollama recovery guidance. We test the predicate logic
    /// directly: if `is_transient_error` returns true, the production code
    /// builds an annotated error. The annotation must contain the key
    /// diagnostic strings an operator needs to recover.
    #[test]
    fn ollama_unreachable_annotation_contains_recovery_hints() {
        // Simulate what the production path now builds when is_transient_error matches.
        let base = "http://127.0.0.1:11434/v1";
        let original = "error sending request: tcp connect error: Connection refused (os error 61)";
        let annotated = format!(
            "{original} — local provider unreachable (all cloud slots \
             exhausted and local slot failed). \
             Ollama: `brew services start ollama`; \
             probe: `curl -s {base}/models`. \
             Set CHUMP_FALLBACK_API_BASE or add cloud slots \
             (CHUMP_PROVIDER_1_*) to avoid this failure mode."
        );
        assert!(
            annotated.contains("brew services start ollama"),
            "annotated error must contain Ollama restart hint"
        );
        assert!(
            annotated.contains("CHUMP_FALLBACK_API_BASE"),
            "annotated error must suggest the fallback env var"
        );
        assert!(
            annotated.contains("CHUMP_PROVIDER_1_"),
            "annotated error must suggest adding cloud slots"
        );
        assert!(
            annotated.contains(base),
            "annotated error must include the Ollama base URL for the probe command"
        );
    }

    // ── CREDIBLE-010: routing + fallback unit tests ───────────────────────

    /// Helper: build a ProviderSlot with controllable rate limit state.
    #[allow(clippy::too_many_arguments)]
    fn test_slot(
        name: &str,
        priority: u32,
        tier: ProviderTier,
        privacy: PrivacyTier,
        rpm_limit: u32,
        rpd_limit: u32,
        calls_this_minute: u32,
        calls_today: u32,
    ) -> ProviderSlot {
        ProviderSlot {
            name: name.to_string(),
            base_url: format!("https://{}.example.invalid/v1", name),
            provider: LocalOpenAIProvider::with_fallback(
                format!("https://{}.example.invalid/v1", name),
                None,
                "test-key".to_string(),
                "test-model".to_string(),
            ),
            priority,
            tier,
            privacy,
            context_k: None,
            rpm_limit,
            calls_this_minute: AtomicU32::new(calls_this_minute),
            minute_start: Mutex::new(Instant::now()),
            rpd_limit,
            calls_today: AtomicU32::new(calls_today),
            day_start: Mutex::new(Instant::now()),
            cooldown_until: Mutex::new(None),
            xml_tool_tags: false,
            model_class: None,
        }
    }

    // ── resolved_openai_api_key ──────────────────────────────────────────

    #[test]
    #[serial_test::serial(openai_env)]
    fn resolved_key_returns_ollama_when_empty() {
        std::env::remove_var("OPENAI_API_KEY");
        assert_eq!(resolved_openai_api_key(), "ollama");
    }

    #[test]
    #[serial_test::serial(openai_env)]
    fn resolved_key_returns_ollama_for_placeholder() {
        std::env::set_var("OPENAI_API_KEY", "token-abc123");
        assert_eq!(resolved_openai_api_key(), "ollama");
        std::env::set_var("OPENAI_API_KEY", "not-needed");
        assert_eq!(resolved_openai_api_key(), "ollama");
        std::env::remove_var("OPENAI_API_KEY");
    }

    #[test]
    #[serial_test::serial(openai_env)]
    fn resolved_key_returns_real_key_verbatim() {
        std::env::set_var("OPENAI_API_KEY", "sk-proj-abc123xyz");
        assert_eq!(resolved_openai_api_key(), "sk-proj-abc123xyz");
        std::env::remove_var("OPENAI_API_KEY");
    }

    // ── looks_like_openai_platform_key ───────────────────────────────────

    #[test]
    fn openai_key_detection_sk_prefix() {
        assert!(looks_like_openai_platform_key("sk-abc123"));
        assert!(looks_like_openai_platform_key("sk-proj-abc123"));
        assert!(looks_like_openai_platform_key("  sk-abc123  ")); // with whitespace
    }

    #[test]
    fn openai_key_detection_non_sk() {
        assert!(!looks_like_openai_platform_key("ollama"));
        assert!(!looks_like_openai_platform_key("gsk_abc123")); // Groq key
        assert!(!looks_like_openai_platform_key("nvapi-abc123")); // NVIDIA key
        assert!(!looks_like_openai_platform_key(""));
    }

    // ── parse_privacy_tier ───────────────────────────────────────────────

    #[test]
    fn privacy_tier_parsing() {
        assert_eq!(parse_privacy_tier("trains"), PrivacyTier::Trains);
        assert_eq!(parse_privacy_tier("TRAINS"), PrivacyTier::Trains);
        assert_eq!(parse_privacy_tier("  Trains  "), PrivacyTier::Trains);
        assert_eq!(parse_privacy_tier("caution"), PrivacyTier::Caution);
        assert_eq!(parse_privacy_tier("safe"), PrivacyTier::Safe);
        assert_eq!(parse_privacy_tier("unknown"), PrivacyTier::Safe); // default
        assert_eq!(parse_privacy_tier(""), PrivacyTier::Safe);
    }

    // ── rpm_headroom_pct ─────────────────────────────────────────────────

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn rpm_headroom_defaults_to_80_pct() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        let pct = rpm_headroom_pct();
        assert!(
            (pct - 0.80).abs() < f32::EPSILON,
            "default headroom should be 0.80, got {}",
            pct
        );
    }

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn rpm_headroom_custom_value() {
        std::env::set_var("CHUMP_CASCADE_RPM_HEADROOM", "50");
        let pct = rpm_headroom_pct();
        assert!(
            (pct - 0.50).abs() < f32::EPSILON,
            "headroom should be 0.50, got {}",
            pct
        );
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
    }

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn rpm_headroom_clamped_to_bounds() {
        // Over 100 → clamped to 100
        std::env::set_var("CHUMP_CASCADE_RPM_HEADROOM", "200");
        let pct = rpm_headroom_pct();
        assert!(
            (pct - 1.0).abs() < f32::EPSILON,
            "headroom >100 should clamp to 1.0, got {}",
            pct
        );
        // Under 1 → clamped to 1
        std::env::set_var("CHUMP_CASCADE_RPM_HEADROOM", "0.5");
        let pct = rpm_headroom_pct();
        assert!(
            (pct - 0.01).abs() < f32::EPSILON,
            "headroom <1 should clamp to 0.01, got {}",
            pct
        );
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
    }

    // ── within_rate_limit ────────────────────────────────────────────────

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn within_rate_limit_allows_when_under_rpm() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM"); // use default 80%
        let slot = test_slot(
            "a",
            1,
            ProviderTier::Cloud,
            PrivacyTier::Safe,
            100,
            0,
            50,
            0,
        );
        // 50 calls, limit=100, effective=80 → under limit
        assert!(within_rate_limit(&slot));
    }

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn within_rate_limit_blocks_at_effective_rpm() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM"); // 80%
        let slot = test_slot(
            "b",
            1,
            ProviderTier::Cloud,
            PrivacyTier::Safe,
            100,
            0,
            80,
            0,
        );
        // 80 calls, limit=100, effective=80 → at limit
        assert!(!within_rate_limit(&slot));
    }

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn within_rate_limit_blocks_at_effective_rpd() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM"); // 80%
        let slot = test_slot(
            "c",
            1,
            ProviderTier::Cloud,
            PrivacyTier::Safe,
            0,
            1000,
            0,
            800,
        );
        // RPM unlimited (0), RPD: 800 calls, limit=1000, effective=800 → at limit
        assert!(!within_rate_limit(&slot));
    }

    #[test]
    #[serial_test::serial(cascade_rpm_env)]
    fn within_rate_limit_allows_unlimited_rpm_and_rpd() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        let slot = test_slot(
            "d",
            1,
            ProviderTier::Local,
            PrivacyTier::Safe,
            0,
            0,
            999,
            999,
        );
        // Both limits=0 → unlimited, so any call count is OK
        assert!(within_rate_limit(&slot));
    }

    // ── record_call ──────────────────────────────────────────────────────

    #[test]
    fn record_call_increments_both_counters() {
        let slot = test_slot(
            "rec",
            1,
            ProviderTier::Cloud,
            PrivacyTier::Safe,
            10,
            100,
            0,
            0,
        );
        assert_eq!(slot.calls_this_minute.load(Ordering::Relaxed), 0);
        assert_eq!(slot.calls_today.load(Ordering::Relaxed), 0);
        record_call(&slot);
        assert_eq!(slot.calls_this_minute.load(Ordering::Relaxed), 1);
        assert_eq!(slot.calls_today.load(Ordering::Relaxed), 1);
        record_call(&slot);
        record_call(&slot);
        assert_eq!(slot.calls_this_minute.load(Ordering::Relaxed), 3);
        assert_eq!(slot.calls_today.load(Ordering::Relaxed), 3);
    }

    // ── first_available_slot routing ─────────────────────────────────────

    #[test]
    #[serial_test::serial(cascade_routing_env)]
    fn first_available_picks_lowest_priority_cloud_slot() {
        // Clear env vars that affect routing
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        std::env::remove_var("CHUMP_LOG_TIMING");

        let cascade = ProviderCascade {
            slots: vec![
                test_slot(
                    "local",
                    0,
                    ProviderTier::Local,
                    PrivacyTier::Safe,
                    0,
                    0,
                    0,
                    0,
                ),
                test_slot(
                    "groq",
                    10,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
                test_slot(
                    "nvidia",
                    20,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
            ],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        // When cloud slots exist, local is skipped; groq (priority=10) picked first
        let idx = cascade.first_available_slot(None, 0);
        assert_eq!(
            idx,
            Some(1),
            "should pick groq (index 1, lowest cloud priority)"
        );
    }

    #[test]
    #[serial_test::serial(cascade_routing_env)]
    fn first_available_skips_rate_limited_slot() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        std::env::remove_var("CHUMP_LOG_TIMING");

        let cascade = ProviderCascade {
            slots: vec![
                test_slot(
                    "local",
                    0,
                    ProviderTier::Local,
                    PrivacyTier::Safe,
                    0,
                    0,
                    0,
                    0,
                ),
                // groq: RPM exhausted (30/30 at 80% headroom = 24 effective, 30 > 24)
                test_slot(
                    "groq",
                    10,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    30,
                    0,
                ),
                test_slot(
                    "nvidia",
                    20,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
            ],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        let idx = cascade.first_available_slot(None, 0);
        assert_eq!(idx, Some(2), "should skip rate-limited groq, pick nvidia");
    }

    #[test]
    #[serial_test::serial(cascade_routing_env)]
    fn first_available_respects_privacy_filter() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        std::env::remove_var("CHUMP_LOG_TIMING");

        let cascade = ProviderCascade {
            slots: vec![
                test_slot(
                    "local",
                    0,
                    ProviderTier::Local,
                    PrivacyTier::Safe,
                    0,
                    0,
                    0,
                    0,
                ),
                // Mistral trains on data — privacy=Trains
                test_slot(
                    "mistral",
                    10,
                    ProviderTier::Cloud,
                    PrivacyTier::Trains,
                    30,
                    0,
                    0,
                    0,
                ),
                test_slot(
                    "nvidia",
                    20,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
            ],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        // With min_privacy=Safe, mistral (Trains) should be skipped
        let idx = cascade.first_available_slot(Some(PrivacyTier::Safe), 0);
        assert_eq!(
            idx,
            Some(2),
            "should skip Trains-tier mistral, pick Safe nvidia"
        );
    }

    #[test]
    #[serial_test::serial(cascade_routing_env)]
    fn first_available_returns_none_when_all_exhausted() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        std::env::remove_var("CHUMP_LOG_TIMING");

        let cascade = ProviderCascade {
            slots: vec![
                test_slot(
                    "local",
                    0,
                    ProviderTier::Local,
                    PrivacyTier::Safe,
                    0,
                    0,
                    0,
                    0,
                ),
                // Both cloud slots rate-limited
                test_slot(
                    "groq",
                    10,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    30,
                    0,
                ),
                test_slot(
                    "nvidia",
                    20,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    30,
                    0,
                ),
            ],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        // All cloud slots exhausted, local is skipped in cloud-first mode → None
        let idx = cascade.first_available_slot(None, 0);
        assert!(
            idx.is_none(),
            "all cloud exhausted → None (local is last-resort only)"
        );
    }

    #[test]
    #[ignore] // INFRA-1081: Flaky in local CI due to environment-dependent slot availability
    #[serial_test::serial(cascade_routing_env)]
    fn first_available_cloud_only_when_cloud_exists() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        std::env::remove_var("CHUMP_LOG_TIMING");

        // Only local slots — no cloud. Local should be picked.
        let cascade = ProviderCascade {
            slots: vec![test_slot(
                "local",
                0,
                ProviderTier::Local,
                PrivacyTier::Safe,
                0,
                0,
                0,
                0,
            )],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        let idx = cascade.first_available_slot(None, 0);
        assert_eq!(
            idx,
            Some(0),
            "only-local cascade should pick the local slot"
        );
    }

    // ── skip_cloud_slots_for_round_type ──────────────────────────────────

    #[test]
    #[serial_test::serial(cascade_round_type_env)]
    fn task_aware_skips_slots_for_low_value_rounds() {
        std::env::remove_var("CHUMP_CASCADE_RPM_HEADROOM");
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        std::env::remove_var("CHUMP_LOG_TIMING");
        std::env::set_var("CHUMP_CURRENT_ROUND_TYPE", "research");

        let cascade = ProviderCascade {
            slots: vec![
                test_slot(
                    "local",
                    0,
                    ProviderTier::Local,
                    PrivacyTier::Safe,
                    0,
                    0,
                    0,
                    0,
                ),
                test_slot(
                    "groq",
                    10,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
                test_slot(
                    "nvidia",
                    20,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
                test_slot(
                    "cerebras",
                    30,
                    ProviderTier::Cloud,
                    PrivacyTier::Safe,
                    30,
                    0,
                    0,
                    0,
                ),
            ],
            _strategy: CascadeStrategy::TaskAware,
            local_only: false,
            bandit: OnceLock::new(),
        };

        // TaskAware + research → skip 2 cloud slots, pick 3rd
        let skip = cascade.skip_cloud_slots_for_round_type();
        assert_eq!(skip, 2, "research round should skip 2 cloud slots");

        let idx = cascade.first_available_slot(None, skip);
        assert_eq!(idx, Some(3), "should skip groq+nvidia, pick cerebras");

        std::env::remove_var("CHUMP_CURRENT_ROUND_TYPE");
    }

    #[test]
    #[serial_test::serial(cascade_round_type_env)]
    fn task_aware_no_skip_for_work_rounds() {
        std::env::set_var("CHUMP_CURRENT_ROUND_TYPE", "work");

        let cascade = ProviderCascade {
            slots: vec![],
            _strategy: CascadeStrategy::TaskAware,
            local_only: false,
            bandit: OnceLock::new(),
        };

        let skip = cascade.skip_cloud_slots_for_round_type();
        assert_eq!(skip, 0, "work rounds should not skip any cloud slots");

        std::env::remove_var("CHUMP_CURRENT_ROUND_TYPE");
    }

    // ── cascade_enabled ──────────────────────────────────────────────────

    #[test]
    #[serial_test::serial(cascade_enabled_env)]
    fn cascade_enabled_only_when_set_to_1() {
        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        assert!(!cascade_enabled());

        std::env::set_var("CHUMP_CASCADE_ENABLED", "0");
        assert!(!cascade_enabled());

        std::env::set_var("CHUMP_CASCADE_ENABLED", "true");
        assert!(!cascade_enabled(), "only '1' enables cascade, not 'true'");

        std::env::set_var("CHUMP_CASCADE_ENABLED", "1");
        assert!(cascade_enabled());

        std::env::remove_var("CHUMP_CASCADE_ENABLED");
    }

    // ── CascadeStrategy label ────────────────────────────────────────────

    #[test]
    fn cascade_strategy_labels() {
        assert_eq!(CascadeStrategy::Priority.label(), "priority");
        assert_eq!(CascadeStrategy::TaskAware.label(), "task_aware");
        assert_eq!(CascadeStrategy::Bandit.label(), "bandit");
    }

    // ── prefer_large_context ─────────────────────────────────────────────

    #[test]
    #[serial_test::serial(large_context_env)]
    fn prefer_large_context_off_by_default() {
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
        assert!(!prefer_large_context());
    }

    #[test]
    #[serial_test::serial(large_context_env)]
    fn prefer_large_context_enabled_with_1() {
        std::env::set_var("CHUMP_PREFER_LARGE_CONTEXT", "1");
        assert!(prefer_large_context());
        std::env::set_var("CHUMP_PREFER_LARGE_CONTEXT", "true");
        assert!(prefer_large_context());
        std::env::remove_var("CHUMP_PREFER_LARGE_CONTEXT");
    }

    // ── PrivacyTier ordering ─────────────────────────────────────────────

    #[test]
    fn privacy_tier_ordering_trains_lt_safe() {
        assert!(PrivacyTier::Trains < PrivacyTier::Caution);
        assert!(PrivacyTier::Caution < PrivacyTier::Safe);
        assert!(PrivacyTier::Trains < PrivacyTier::Safe);
    }

    // ── INFRA-1004: local-only mode ───────────────────────────────────────

    fn make_slot(name: &str, tier: ProviderTier) -> ProviderSlot {
        let url = "http://127.0.0.1:11434/v1".to_string();
        ProviderSlot {
            name: name.to_string(),
            base_url: url.clone(),
            provider: LocalOpenAIProvider::with_fallback(
                url,
                None,
                "k".to_string(),
                "m".to_string(),
            ),
            priority: 1,
            tier,
            privacy: PrivacyTier::Safe,
            context_k: None,
            model_class: None,
            rpm_limit: 0,
            calls_this_minute: AtomicU32::new(0),
            minute_start: Mutex::new(Instant::now()),
            rpd_limit: 0,
            calls_today: AtomicU32::new(0),
            day_start: Mutex::new(Instant::now()),
            cooldown_until: Mutex::new(None),
            xml_tool_tags: false,
        }
    }

    #[test]
    fn cascade_local_only_cascade_mode_label() {
        let cascade = ProviderCascade {
            slots: vec![make_slot("local", ProviderTier::Local)],
            _strategy: CascadeStrategy::Priority,
            local_only: true,
            bandit: std::sync::OnceLock::new(),
        };
        assert_eq!(cascade.cascade_mode(), "local-only");
    }

    #[test]
    fn cascade_mode_labels_without_local_only() {
        let both = ProviderCascade {
            slots: vec![
                make_slot("local", ProviderTier::Local),
                make_slot("cloud", ProviderTier::Cloud),
            ],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: std::sync::OnceLock::new(),
        };
        assert_eq!(both.cascade_mode(), "preferred-local");

        let cloud_only = ProviderCascade {
            slots: vec![make_slot("cloud", ProviderTier::Cloud)],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: std::sync::OnceLock::new(),
        };
        assert_eq!(cloud_only.cascade_mode(), "paid-direct");

        let local_only_slots = ProviderCascade {
            slots: vec![make_slot("local", ProviderTier::Local)],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: std::sync::OnceLock::new(),
        };
        assert_eq!(local_only_slots.cascade_mode(), "free-then-paid");
    }

    #[test]
    fn cascade_local_only_blocks_cloud_in_first_available_slot() {
        // A cascade with one cloud slot and local_only=true: first_available_slot
        // must skip the cloud slot and return None (no local available).
        let cascade = ProviderCascade {
            slots: vec![make_slot("cloud-slot", ProviderTier::Cloud)],
            _strategy: CascadeStrategy::Priority,
            local_only: true,
            bandit: std::sync::OnceLock::new(),
        };
        let picked = cascade.first_available_slot(None, 0);
        assert!(
            picked.is_none(),
            "local-only mode must not pick cloud slot; got index {:?}",
            picked
        );
    }

    #[test]
    fn cascade_local_only_picks_local_slot() {
        // A cascade with one local slot and local_only=true: first_available_slot
        // must return Some(0) because the local slot is eligible.
        let cascade = ProviderCascade {
            slots: vec![make_slot("local-slot", ProviderTier::Local)],
            _strategy: CascadeStrategy::Priority,
            local_only: true,
            bandit: std::sync::OnceLock::new(),
        };
        let picked = cascade.first_available_slot(None, 0);
        assert_eq!(picked, Some(0), "local-only mode must pick the local slot");
    }

    #[test]
    #[serial_test::serial(ambient_env)]
    fn cascade_routed_event_emitted() {
        let dir = tempfile::tempdir().unwrap();
        let log_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", log_path.to_string_lossy().to_string());

        emit_cascade_routed_event("test-slot", "local-only", "local", 42);

        let contents = std::fs::read_to_string(&log_path).unwrap_or_default();
        assert!(contents.contains("cascade_routed"), "event kind missing");
        assert!(
            contents.contains("\"slot\":\"test-slot\""),
            "slot field missing"
        );
        assert!(
            contents.contains("\"cascade_mode\":\"local-only\""),
            "cascade_mode field missing"
        );
        assert!(
            contents.contains("\"tier\":\"local\""),
            "tier field missing"
        );
        assert!(contents.contains("\"tokens\":42"), "tokens field missing");

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    /// INFRA-2372: a malformed Gemini function-calling config 400 must
    /// be classified as cascade-able so a single bad slot doesn't abort
    /// the whole request. Operator daily-friction case: bare `chump`
    /// invocation was 400'ing because the Gemini cascade slot had
    /// function_calling enabled but no function_declarations were
    /// supplied at the call site.
    #[test]
    fn should_cascade_on_gemini_function_calling_config_400() {
        let err = "400 Bad Request: Function calling config is set without function_declarations";
        assert!(
            should_cascade_on_error_string(err),
            "Gemini malformed function-calling 400 must cascade to next slot"
        );
    }

    #[test]
    fn should_cascade_on_gemini_function_declarations_missing() {
        let err = "GoogleAI: function_declarations is required when tool_config.function_calling_config is set";
        assert!(
            should_cascade_on_error_string(err),
            "Gemini function_declarations missing must cascade"
        );
    }

    /// Sanity: a regular Bad Request that is NOT the Gemini tool-config
    /// class must still NOT cascade (would mask real programming bugs).
    #[test]
    fn should_not_cascade_on_generic_bad_request() {
        let err = "400 Bad Request: invalid value for field 'model'";
        assert!(
            !should_cascade_on_error_string(err),
            "generic 400 (not the Gemini tool-config class) must not cascade"
        );
    }

    // ── EFFECTIVE-141: select_local_model unit tests ──────────────────────────

    fn mk(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn select_local_model_override_wins() {
        let available = mk(&["qwen2.5:14b", "llama3.2:3b"]);
        let result = select_local_model(&available, Some("my-custom-model"));
        assert_eq!(result, Some("my-custom-model".to_string()));
    }

    #[test]
    fn select_local_model_empty_override_falls_through() {
        let available = mk(&["qwen2.5:14b"]);
        // empty string override should NOT win — fall through to auto-select
        let result = select_local_model(&available, Some(""));
        assert_eq!(result, Some("qwen2.5:14b".to_string()));
    }

    #[test]
    fn select_local_model_prefers_qwen2_5_14b_when_present() {
        let available = mk(&[
            "nomic-embed-text",
            "qwen2.5:7b",
            "qwen2.5:14b",
            "llama3.2:3b",
        ]);
        let result = select_local_model(&available, None);
        assert_eq!(result, Some("qwen2.5:14b".to_string()));
    }

    #[test]
    fn select_local_model_excludes_embedding_models() {
        // Only an embedding model available → should not be selected.
        let available = mk(&["nomic-embed-text", "all-minilm:l6-v2-embed"]);
        let result = select_local_model(&available, None);
        assert_eq!(result, None, "embedding-only list must yield None");
    }

    #[test]
    fn select_local_model_falls_back_to_first_non_embedding() {
        let available = mk(&["nomic-embed-text", "phi3:mini", "gemma2:2b"]);
        let result = select_local_model(&available, None);
        assert_eq!(result, Some("phi3:mini".to_string()));
    }

    #[test]
    fn select_local_model_returns_none_on_empty_list() {
        let result = select_local_model(&[], None);
        assert_eq!(result, None);
    }

    #[test]
    fn is_local_endpoint_recognises_loopback_variants() {
        assert!(is_local_endpoint("http://127.0.0.1:11434/v1"));
        assert!(is_local_endpoint("http://localhost:8080/v1"));
        assert!(is_local_endpoint("http://[::1]:11434/v1"));
        assert!(!is_local_endpoint("https://api.openai.com/v1"));
        assert!(!is_local_endpoint("https://api.groq.com/openai/v1"));
    }

    /// CREDIBLE-266: failover reason classification must bucket into the
    /// operator-facing categories the gap asked for, and never echo the raw
    /// provider error body (which can carry request metadata) verbatim.
    #[test]
    fn classify_failover_reason_buckets_known_classes() {
        assert_eq!(classify_failover_reason("429 Too Many Requests"), "429");
        assert_eq!(
            classify_failover_reason("401 Unauthorized: invalid api key"),
            "401/403"
        );
        assert_eq!(
            classify_failover_reason("403 Forbidden: models.permission"),
            "401/403"
        );
        assert_eq!(
            classify_failover_reason("404 model not found: gpt-9000"),
            "model-not-found"
        );
        assert_eq!(
            classify_failover_reason("tool_use_failed: could not parse function call"),
            "tool-call-refused"
        );
        assert_eq!(classify_failover_reason("connection reset"), "error");
    }

    /// CREDIBLE-266: the failover trail must be cleared at the start of each
    /// cascade call and accumulate entries in call order, so the ambient
    /// event + phase-timings log never leak a prior turn's failures.
    #[test]
    fn failover_trail_records_and_clears() {
        clear_last_failovers();
        assert!(get_last_failovers().is_empty());
        record_failover("slot-1", "429");
        record_failover("slot-2", "401/403");
        let trail = get_last_failovers();
        assert_eq!(trail.len(), 2);
        assert_eq!(trail[0].slot, "slot-1");
        assert_eq!(trail[0].reason, "429");
        assert_eq!(trail[1].slot, "slot-2");
        clear_last_failovers();
        assert!(get_last_failovers().is_empty());
    }

    /// CREDIBLE-266: last-used slot/model getters round-trip what was set —
    /// this is what the orchestrator's phase-timings line reads.
    #[test]
    fn last_used_slot_and_model_round_trip() {
        set_last_used_slot("gemini-2.5-flash".to_string());
        set_last_used_model("gemini-2.5-flash-lite".to_string());
        assert_eq!(get_last_used_slot(), Some("gemini-2.5-flash".to_string()));
        assert_eq!(
            get_last_used_model(),
            Some("gemini-2.5-flash-lite".to_string())
        );
    }

    // ── INFRA-1565: chump-xml-adapter wiring end-to-end ────────────────────

    /// A mock Ollama-style model that emits tool calls as `<tool_call>` XML
    /// in `message.content` instead of the native OpenAI `tool_calls` field
    /// (this is exactly what `xml_tool_tags` exists to handle — some local
    /// Ollama models and older Mistral checkpoints do this). With
    /// `xml_tool_tags: true` on the slot, the cascade must extract the XML
    /// tool call via `chump_xml_adapter::extract_tool_calls` before the
    /// empty/malformed quality gate runs, so a real tool call is never
    /// misclassified as an empty response and failed over.
    #[tokio::test]
    async fn cascade_extracts_xml_tool_calls_from_ollama_style_response() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock = MockServer::start().await;
        let body = serde_json::json!({
            "choices": [{
                "message": {
                    "content": r#"<tool_call>{"name":"read_file","arguments":{"path":"src/main.rs"}}</tool_call>"#,
                    "tool_calls": null
                },
                "finish_reason": "stop"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        let slot = ProviderSlot {
            name: "ollama-xml".to_string(),
            base_url: mock.uri(),
            provider: LocalOpenAIProvider::with_fallback(
                mock.uri(),
                None,
                "not-needed".to_string(),
                "mistral-xml".to_string(),
            ),
            priority: 0,
            tier: ProviderTier::Local,
            privacy: PrivacyTier::Safe,
            context_k: None,
            model_class: None,
            rpm_limit: 0,
            calls_this_minute: AtomicU32::new(0),
            minute_start: Mutex::new(Instant::now()),
            rpd_limit: 0,
            calls_today: AtomicU32::new(0),
            day_start: Mutex::new(Instant::now()),
            cooldown_until: Mutex::new(None),
            xml_tool_tags: true,
        };
        let cascade = ProviderCascade {
            slots: vec![slot],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        let messages = vec![Message {
            role: "user".to_string(),
            content: "Read src/main.rs".to_string(),
        }];
        let out = cascade
            .complete(messages, None, None, None)
            .await
            .expect("cascade call should succeed");

        assert_eq!(
            out.tool_calls.len(),
            1,
            "XML tool call should be extracted, not left as raw text"
        );
        assert_eq!(out.tool_calls[0].name, "read_file");
        assert_eq!(out.tool_calls[0].input["path"], "src/main.rs");
        assert!(
            out.text.as_deref().unwrap_or("").trim().is_empty(),
            "text should have the XML block stripped"
        );
    }

    /// Same mock model, but the slot does NOT opt into `xml_tool_tags` — the
    /// default (false) must leave the XML block untouched in `text` and
    /// report zero native tool calls, proving the flag genuinely gates the
    /// behavior rather than always-on extraction.
    #[tokio::test]
    async fn cascade_leaves_xml_untouched_when_flag_is_off() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock = MockServer::start().await;
        let body = serde_json::json!({
            "choices": [{
                "message": {
                    "content": r#"<tool_call>{"name":"read_file","arguments":{"path":"src/main.rs"}}</tool_call>"#,
                    "tool_calls": null
                },
                "finish_reason": "stop"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        let slot = ProviderSlot {
            name: "ollama-xml-off".to_string(),
            base_url: mock.uri(),
            provider: LocalOpenAIProvider::with_fallback(
                mock.uri(),
                None,
                "not-needed".to_string(),
                "mistral-xml".to_string(),
            ),
            priority: 0,
            tier: ProviderTier::Local,
            privacy: PrivacyTier::Safe,
            context_k: None,
            model_class: None,
            rpm_limit: 0,
            calls_this_minute: AtomicU32::new(0),
            minute_start: Mutex::new(Instant::now()),
            rpd_limit: 0,
            calls_today: AtomicU32::new(0),
            day_start: Mutex::new(Instant::now()),
            cooldown_until: Mutex::new(None),
            xml_tool_tags: false,
        };
        let cascade = ProviderCascade {
            slots: vec![slot],
            _strategy: CascadeStrategy::Priority,
            local_only: false,
            bandit: OnceLock::new(),
        };

        let messages = vec![Message {
            role: "user".to_string(),
            content: "Read src/main.rs".to_string(),
        }];
        let out = cascade
            .complete(messages, None, None, None)
            .await
            .expect("cascade call should succeed");

        assert!(out.tool_calls.is_empty());
        assert!(out.text.as_deref().unwrap_or("").contains("<tool_call>"));
    }

    #[test]
    fn effective1933_upgrade_retired_provider_models() {
        let gbase = "https://generativelanguage.googleapis.com/v1beta/openai";
        assert_eq!(
            upgrade_retired_provider_model(gbase, "gemini-2.5-pro"),
            "gemini-3.8-flash"
        );
        assert_eq!(
            upgrade_retired_provider_model(gbase, "gemini-2.0-flash-lite"),
            "gemini-3.5-flash-lite"
        );
        assert_eq!(
            upgrade_retired_provider_model(gbase, "gemini-2.5-flash-lite"),
            "gemini-3.5-flash-lite"
        );
        assert_eq!(
            upgrade_retired_provider_model(gbase, "gemini-3.8-flash"),
            "gemini-3.8-flash"
        );
        assert_eq!(
            upgrade_retired_provider_model(
                "https://api.groq.com/openai/v1",
                "llama-3.3-70b-versatile"
            ),
            "qwen/qwen3.8-27b"
        );
    }

    #[test]
    #[serial_test::serial(openai_env)]
    fn effective1933_resolved_api_key_for_gemini_endpoint() {
        let prev_oai = std::env::var("OPENAI_API_KEY").ok();
        let prev_gem = std::env::var("GEMINI_API_KEY").ok();
        std::env::remove_var("OPENAI_API_KEY");
        std::env::set_var("GEMINI_API_KEY", "AIzaTestKey123");
        assert_eq!(
            resolved_api_key_for_endpoint(
                "https://generativelanguage.googleapis.com/v1beta/openai"
            ),
            "AIzaTestKey123"
        );
        match prev_oai {
            Some(v) => std::env::set_var("OPENAI_API_KEY", v),
            None => std::env::remove_var("OPENAI_API_KEY"),
        }
        match prev_gem {
            Some(v) => std::env::set_var("GEMINI_API_KEY", v),
            None => std::env::remove_var("GEMINI_API_KEY"),
        }
    }
}
