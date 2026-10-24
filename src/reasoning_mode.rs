//! Reasoning-mode detection and parameter building for frontier models.
//!
//! Frontier models (o3, Gemini Deep Think, Claude extended thinking) expose
//! test-time compute via model-specific "thinking" parameters. This module:
//!
//! 1. Reads `CHUMP_REASONING_MODE` (`off` / `auto` / `always`, default `off`)
//! 2. Detects whether a given model supports reasoning/extended-thinking
//! 3. Builds the model-specific JSON parameters to inject into API calls
//!
//! # Wiring into provider calls
//!
//! When `CHUMP_REASONING_MODE=always` (or `auto` with a complex task), merge
//! the `Option<serde_json::Value>` returned by [`build_reasoning_params`] into
//! the request body before the HTTP call:
//!
//! ```text
//! if let Some(params) = build_reasoning_params(model_id) {
//!     if let Some(obj) = params.as_object() {
//!         for (k, v) in obj { body[k] = v.clone(); }
//!     }
//! }
//! ```
//!
//! The function returns `None` when the model does not support reasoning
//! (unknown model, or a model where we have no parameter spec), so callers
//! can unconditionally call it and skip the merge when `None`.
//!
//! `CHUMP_REASONING_BUDGET_TOKENS` overrides the default budget (10 000) for
//! Claude-style models.

use serde_json::{json, Value};

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Parsed value of `CHUMP_REASONING_MODE`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReasoningMode {
    /// Never add reasoning parameters (default).
    Off,
    /// Add reasoning parameters only when the task looks complex (long prompt,
    /// chain-of-thought keywords, etc.). Falls back to provider heuristics.
    Auto,
    /// Always add reasoning parameters for every model call, if the model supports it.
    Always,
}

/// Parse `CHUMP_REASONING_MODE` env var. Unset / empty / unrecognised ⇒ `Off`.
pub fn chump_reasoning_mode() -> ReasoningMode {
    match std::env::var("CHUMP_REASONING_MODE") {
        Ok(v) => parse_reasoning_mode(v.trim()),
        Err(_) => ReasoningMode::Off,
    }
}

/// `true` when `model_id` is a known reasoning-capable model.
///
/// Matching is case-insensitive prefix/substring: `claude-3-7-sonnet` matches
/// `claude-3-7-sonnet-20250219` and similar revision suffixes.
pub fn model_supports_reasoning(model_id: &str) -> bool {
    let m = model_id.trim().to_ascii_lowercase();
    REASONING_MODELS.iter().any(|pat| m.contains(pat))
}

/// Build the model-specific reasoning parameter object to merge into an API
/// request body, or `None` when the model is not recognised as a reasoning
/// model.
///
/// The returned `Value` is always a JSON object (`{}`). Callers merge its
/// fields into their existing request body.
///
/// `CHUMP_REASONING_BUDGET_TOKENS` (positive integer) overrides the default
/// 10 000-token Claude thinking budget.
pub fn build_reasoning_params(model_id: &str) -> Option<Value> {
    let m = model_id.trim().to_ascii_lowercase();
    if m.contains("claude") {
        Some(build_claude_reasoning_params())
    } else if m.contains("o1") || m.contains("o3") || m.contains("o4") {
        Some(build_openai_reasoning_params())
    } else if m.contains("gemini")
        && (m.contains("think")
            || m.contains("2.5-pro")
            || m.contains("3-pro")
            || m.contains("3.1-pro")
            || m.contains("3.8-flash")
            || m.contains("gemini-4"))
    {
        Some(build_gemini_reasoning_params())
    } else if m.contains("deepseek-r") || m.contains("deepseek-reasoner") {
        // DeepSeek-R1 and descendants: just set temperature to 0.6 (their docs recommend ≤ 1.0).
        Some(json!({ "temperature": 0.6 }))
    } else {
        None
    }
}

/// Decide whether to add reasoning params for this model+task combination,
/// given the current `CHUMP_REASONING_MODE`.
///
/// `task_hint` is an optional short description of the current task; when
/// `auto` mode is in effect, this is used for lightweight complexity detection.
pub fn should_use_reasoning(model_id: &str, task_hint: Option<&str>) -> bool {
    if !model_supports_reasoning(model_id) {
        return false;
    }
    match chump_reasoning_mode() {
        ReasoningMode::Off => false,
        ReasoningMode::Always => true,
        ReasoningMode::Auto => task_looks_complex(task_hint.unwrap_or("")),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Hardcoded list of reasoning-capable model id substrings (lower-case).
///
/// These are prefix/substring patterns: a model whose id *contains* the
/// pattern is treated as reasoning-capable.
const REASONING_MODELS: &[&str] = &[
    // Claude extended thinking (3.7 Sonnet, Claude 4 Opus, etc.)
    "claude-3-7-sonnet",
    "claude-3-5-sonnet",
    "claude-opus-4",
    "claude-sonnet-4",
    "claude-haiku-4",
    // OpenAI reasoning models
    "o1",
    "o1-mini",
    "o1-preview",
    "o3",
    "o3-mini",
    "o4",
    "o4-mini",
    // Gemini extended thinking
    "gemini-2.0-flash-thinking",
    "gemini-2.5-flash-thinking",
    "gemini-2.5-pro",
    "gemini-3-pro",
    "gemini-3.1-pro",
    "gemini-3.8-flash",
    "gemini-4",
    // DeepSeek reasoning models
    "deepseek-r1",
    "deepseek-r2",
    "deepseek-reasoner",
];

fn parse_reasoning_mode(s: &str) -> ReasoningMode {
    match s.to_ascii_lowercase().as_str() {
        "auto" => ReasoningMode::Auto,
        "always" | "on" | "1" | "true" => ReasoningMode::Always,
        _ => ReasoningMode::Off,
    }
}

/// Build Claude-style extended-thinking parameters.
///
/// Docs: <https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking>
fn build_claude_reasoning_params() -> Value {
    let budget_tokens: u32 = std::env::var("CHUMP_REASONING_BUDGET_TOKENS")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(10_000)
        .clamp(1_024, 100_000);
    json!({
        "thinking": {
            "type": "enabled",
            "budget_tokens": budget_tokens
        }
    })
}

/// Build OpenAI `reasoning_effort` parameter for o1/o3/o4-series.
///
/// `CHUMP_REASONING_EFFORT` can be set to `low`, `medium`, or `high`
/// (default `high`).
fn build_openai_reasoning_params() -> Value {
    let effort = std::env::var("CHUMP_REASONING_EFFORT").unwrap_or_else(|_| "high".to_string());
    let effort = match effort.trim().to_ascii_lowercase().as_str() {
        "low" => "low",
        "medium" | "med" => "medium",
        _ => "high",
    };
    json!({ "reasoning_effort": effort })
}

/// Build Gemini thinking-mode parameter.
///
/// For `gemini-2.x-flash-thinking` and `gemini-2.5-pro` the field is
/// `thinkingConfig` inside the generation config.  We return it as a
/// top-level key that callers can merge; the cascade can wrap it in
/// `generationConfig` if needed.
fn build_gemini_reasoning_params() -> Value {
    let budget: u32 = std::env::var("CHUMP_REASONING_BUDGET_TOKENS")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(10_000)
        .clamp(1_024, 32_768);
    json!({
        "thinkingConfig": {
            "thinkingBudget": budget
        }
    })
}

/// Lightweight task complexity probe for `auto` mode.
///
/// Returns `true` when the task looks like it warrants extended reasoning.
/// Heuristics (conservative — prefers false negatives over false positives):
/// - Prompt is longer than 500 characters
/// - Contains reasoning-heavy keywords
fn task_looks_complex(task: &str) -> bool {
    if task.len() > 500 {
        return true;
    }
    let t = task.to_ascii_lowercase();
    let keywords = [
        "proof",
        "prove",
        "derive",
        "algorithm",
        "optimize",
        "optimise",
        "multi-step",
        "step by step",
        "complex",
        "reason",
        "analyse",
        "analyze",
        "compare and contrast",
        "trade-off",
        "tradeoff",
        "mathematical",
        "theorem",
    ];
    keywords.iter().any(|kw| t.contains(kw))
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    // ── env var parsing ──────────────────────────────────────────────────────

    #[test]
    #[serial]
    fn reasoning_mode_unset_is_off() {
        std::env::remove_var("CHUMP_REASONING_MODE");
        assert_eq!(chump_reasoning_mode(), ReasoningMode::Off);
    }

    #[test]
    #[serial]
    fn reasoning_mode_off_explicit() {
        std::env::set_var("CHUMP_REASONING_MODE", "off");
        assert_eq!(chump_reasoning_mode(), ReasoningMode::Off);
        std::env::set_var("CHUMP_REASONING_MODE", "OFF");
        assert_eq!(chump_reasoning_mode(), ReasoningMode::Off);
        std::env::set_var("CHUMP_REASONING_MODE", "0");
        assert_eq!(chump_reasoning_mode(), ReasoningMode::Off);
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    #[test]
    #[serial]
    fn reasoning_mode_auto() {
        std::env::set_var("CHUMP_REASONING_MODE", "auto");
        assert_eq!(chump_reasoning_mode(), ReasoningMode::Auto);
        std::env::set_var("CHUMP_REASONING_MODE", "AUTO");
        assert_eq!(chump_reasoning_mode(), ReasoningMode::Auto);
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    #[test]
    #[serial]
    fn reasoning_mode_always_variants() {
        for val in ["always", "ALWAYS", "on", "1", "true", "TRUE"] {
            std::env::set_var("CHUMP_REASONING_MODE", val);
            assert_eq!(
                chump_reasoning_mode(),
                ReasoningMode::Always,
                "failed for value: {val}"
            );
        }
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    // ── model_supports_reasoning ─────────────────────────────────────────────

    #[test]
    fn model_supports_reasoning_claude_37() {
        assert!(model_supports_reasoning("claude-3-7-sonnet-20250219"));
    }

    #[test]
    fn model_supports_reasoning_claude_opus4() {
        assert!(model_supports_reasoning("claude-opus-4-20251101"));
        assert!(model_supports_reasoning("claude-opus-4-5"));
    }

    #[test]
    fn model_supports_reasoning_o3_models() {
        assert!(model_supports_reasoning("o3"));
        assert!(model_supports_reasoning("o3-mini"));
        assert!(model_supports_reasoning("o1-preview"));
        assert!(model_supports_reasoning("o4-mini"));
    }

    #[test]
    fn model_supports_reasoning_gemini_thinking() {
        assert!(model_supports_reasoning("gemini-2.0-flash-thinking-exp"));
        assert!(model_supports_reasoning("gemini-2.5-pro-preview"));
    }

    #[test]
    fn model_supports_reasoning_deepseek_r1() {
        assert!(model_supports_reasoning("deepseek-r1-distill-qwen-32b"));
        assert!(model_supports_reasoning("deepseek-reasoner"));
    }

    #[test]
    fn model_does_not_support_reasoning_gpt4() {
        assert!(!model_supports_reasoning("gpt-4o"));
        assert!(!model_supports_reasoning("gpt-5-mini"));
        assert!(!model_supports_reasoning("llama-3-8b-instruct"));
        assert!(!model_supports_reasoning("mistral-7b-instruct"));
    }

    #[test]
    fn model_supports_reasoning_case_insensitive() {
        assert!(model_supports_reasoning("Claude-3-7-Sonnet-20250219"));
        assert!(model_supports_reasoning("O3-MINI"));
    }

    // ── build_reasoning_params ───────────────────────────────────────────────

    #[test]
    #[serial]
    fn build_claude_params_default_budget() {
        std::env::remove_var("CHUMP_REASONING_BUDGET_TOKENS");
        let p = build_reasoning_params("claude-opus-4-20251101").unwrap();
        assert_eq!(p["thinking"]["type"], "enabled");
        assert_eq!(p["thinking"]["budget_tokens"], 10_000);
    }

    #[test]
    #[serial]
    fn build_claude_params_custom_budget() {
        std::env::set_var("CHUMP_REASONING_BUDGET_TOKENS", "20000");
        let p = build_reasoning_params("claude-3-7-sonnet-20250219").unwrap();
        assert_eq!(p["thinking"]["budget_tokens"], 20_000);
        std::env::remove_var("CHUMP_REASONING_BUDGET_TOKENS");
    }

    #[test]
    #[serial]
    fn build_claude_params_budget_clamped_low() {
        std::env::set_var("CHUMP_REASONING_BUDGET_TOKENS", "10");
        let p = build_reasoning_params("claude-sonnet-4-20251001").unwrap();
        assert_eq!(p["thinking"]["budget_tokens"], 1_024);
        std::env::remove_var("CHUMP_REASONING_BUDGET_TOKENS");
    }

    #[test]
    #[serial]
    fn build_openai_params_default_effort() {
        std::env::remove_var("CHUMP_REASONING_EFFORT");
        let p = build_reasoning_params("o3").unwrap();
        assert_eq!(p["reasoning_effort"], "high");
    }

    #[test]
    #[serial]
    fn build_openai_params_custom_effort() {
        std::env::set_var("CHUMP_REASONING_EFFORT", "low");
        let p = build_reasoning_params("o1-preview").unwrap();
        assert_eq!(p["reasoning_effort"], "low");
        std::env::set_var("CHUMP_REASONING_EFFORT", "medium");
        let p2 = build_reasoning_params("o3-mini").unwrap();
        assert_eq!(p2["reasoning_effort"], "medium");
        std::env::remove_var("CHUMP_REASONING_EFFORT");
    }

    #[test]
    #[serial]
    fn build_gemini_params_default_budget() {
        std::env::remove_var("CHUMP_REASONING_BUDGET_TOKENS");
        let p = build_reasoning_params("gemini-2.0-flash-thinking-exp").unwrap();
        assert_eq!(p["thinkingConfig"]["thinkingBudget"], 10_000);
    }

    #[test]
    fn build_params_returns_none_for_unknown_model() {
        assert!(build_reasoning_params("gpt-4o").is_none());
        assert!(build_reasoning_params("llama-3-8b-instruct").is_none());
        assert!(build_reasoning_params("mistral-nemo").is_none());
    }

    #[test]
    fn build_params_deepseek_r1() {
        let p = build_reasoning_params("deepseek-r1-distill-llama-70b").unwrap();
        // DeepSeek uses temperature override
        assert!(p.get("temperature").is_some());
    }

    // ── should_use_reasoning ─────────────────────────────────────────────────

    #[test]
    #[serial]
    fn should_use_reasoning_off_mode_never() {
        std::env::set_var("CHUMP_REASONING_MODE", "off");
        assert!(!should_use_reasoning("claude-opus-4-20251101", None));
        assert!(!should_use_reasoning(
            "claude-opus-4-20251101",
            Some("prove this theorem")
        ));
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    #[test]
    #[serial]
    fn should_use_reasoning_always_mode() {
        std::env::set_var("CHUMP_REASONING_MODE", "always");
        assert!(should_use_reasoning("claude-3-7-sonnet-20250219", None));
        assert!(should_use_reasoning("o3-mini", Some("hello")));
        // Unknown model still returns false
        assert!(!should_use_reasoning("gpt-4o", None));
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    #[test]
    #[serial]
    fn should_use_reasoning_auto_simple_task() {
        std::env::set_var("CHUMP_REASONING_MODE", "auto");
        // Short simple task → no reasoning
        assert!(!should_use_reasoning(
            "claude-opus-4-20251101",
            Some("hello world")
        ));
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    #[test]
    #[serial]
    fn should_use_reasoning_auto_complex_task() {
        std::env::set_var("CHUMP_REASONING_MODE", "auto");
        assert!(should_use_reasoning(
            "claude-opus-4-20251101",
            Some("prove this theorem and derive the algorithm step by step")
        ));
        std::env::remove_var("CHUMP_REASONING_MODE");
    }

    #[test]
    #[serial]
    fn should_use_reasoning_auto_long_task() {
        std::env::set_var("CHUMP_REASONING_MODE", "auto");
        // 501-char task → triggers auto reasoning
        let long_task = "a".repeat(501);
        assert!(should_use_reasoning("o3", Some(&long_task)));
        std::env::remove_var("CHUMP_REASONING_MODE");
    }
}
