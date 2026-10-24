//! `chump --execute-gap <GAP-ID>` — unattended single-gap dispatch mode.
//!
//! COG-025: lets `chump-orchestrator` route a dispatched subagent through
//! Chump's own multi-turn agent loop (and therefore through any
//! OpenAI-compatible backend — Together, mistral.rs, Ollama) instead of
//! shelling out to the Anthropic-only `claude -p` CLI. Cost-routing path
//! for autonomous PR shipping; pairs with `CHUMP_DISPATCH_BACKEND=chump-local`
//! in `crates/chump-orchestrator/src/dispatch.rs`.
//!
//! ## Contract (mirrors `chump_orchestrator::dispatch::build_prompt`)
//!
//! 1. Read `docs/gaps.yaml` for the gap entry (acceptance criteria).
//! 2. Build the same dispatched-agent prompt the `claude` baseline sees.
//! 3. Drive `ChumpAgent::run` with that prompt — single user turn,
//!    multi-iteration tool-use loop. Provider is whatever
//!    `provider_cascade::build_provider()` resolves from `OPENAI_API_BASE` +
//!    `OPENAI_MODEL` env (Together, mistral.rs, Ollama, hosted OpenAI…).
//! 4. Print the agent's final reply to stdout. Caller (orchestrator monitor)
//!    parses the PR number from the reply or polls `gh pr list` like the
//!    `claude` path.
//!
//! ## Exit codes
//!
//! * `0` — agent loop returned a reply (success, regardless of whether the
//!   reply contains a PR number — monitor parses).
//! * `1` — agent loop errored, generic class (provider unreachable,
//!   max iterations, cancellation, network timeout, etc.).
//! * `2` — usage error (missing or malformed gap id).
//! * `75` — agent loop errored with **billing-exhausted** class (HTTP 402,
//!   `credit_limit`, `insufficient_quota`, `payment required`). Distinct from
//!   `1` so the orchestrator's stderr-tailer (see
//!   `crates/chump-orchestrator/src/dispatch.rs:766`) can detect this
//!   specifically and decide whether to respawn the dispatched child against
//!   the next routing-table candidate (TOGETHER → GROQ → Claude). Matches
//!   `EX_TEMPFAIL` per `sysexits.h`. INFRA-302 blocker (1).
//!
//!   Today the cascade-respawn lives only at the per-call layer
//!   (`provider_cascade::should_cascade_on_error_string`, INFRA-300 PR #890).
//!   This exit-code-plus-stderr-marker contract is the *signal* the
//!   orchestrator-level cascade-respawn (filed separately) needs to act on
//!   — without it, the orchestrator can't tell a billing-exhausted Together
//!   exit from a network blip from a tool-format failure, and either retries
//!   the same provider blindly (worsens the credit hole) or gives up
//!   uniformly (the 2026-05-02 dogfood failure mode).
//!
//! ## Why no per-tool approval gating
//!
//! [`crate::agent_loop::ChumpAgent`] only prompts for tool approval when
//! `CHUMP_TOOLS_ASK` is set. Dispatched runs leave it unset, so the loop
//! runs unattended end-to-end (mirrors `--dangerously-skip-permissions`
//! on the `claude` baseline — see dispatch.rs INFRA-DISPATCH-PERMISSIONS-FLAG
//! comment).
//!
//! ## Gemini tool-call validation (EFFECTIVE-007)
//!
//! Gemini 2.5 Flash has been validated (2026-05-15) as the preferred sonnet-tier
//! provider for autonomous dispatch. Tool-call quality verified equal to or better
//! than Llama 3.3 70B: proper OpenAI-format tool_calls, valid unified diffs on
//! first attempt, no fuzzy-match fallback needed. See docs/architecture/FREE_TIER_PROVIDER_COMPAT.md
//! for test methodology and full results.

use anyhow::{anyhow, Context, Result};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio_util::sync::CancellationToken;

use crate::agent_factory::build_chump_agent_cli;
use crate::agent_loop::ChumpAgent;
use crate::ambient_stream::locate_ambient;
use crate::model_overlay::{
    detect_model_family, maybe_overlay_from_env, maybe_system_directive_from_env, ModelFamily,
};
use crate::plan_mode::{self, PlanOutcome};

// ──────────────────────────────────────────────────────────────────────
// INFRA-2055 — terminal outcome emission
// Every exit path from chump --execute-gap MUST emit exactly one of:
//   gap_shipped  — PR opened, status flipped to done
//   gap_blocked  — any non-clean exit (error, timeout, panic, signal)
//   gap_deferred — agent explicitly punted to wait for external event
//
// This is the authoritative fix for the wizard wheel-spin: wizard-daemon
// was re-dispatching the same gap forever because chump --execute-gap
// could exit silently with no structured outcome. Now wizard reads the
// explicit kind instead of heuristic-guessing from PID death + PR state.
// ──────────────────────────────────────────────────────────────────────

/// The three terminal outcome kinds a chump --execute-gap run can emit.
/// # scanner-anchor: "kind":"gap_shipped"
/// # scanner-anchor: "kind":"gap_blocked"
/// # scanner-anchor: "kind":"gap_deferred"
#[derive(Debug, Clone)]
pub enum ExecuteGapOutcome {
    /// Happy path: PR was opened and gap status flipped to done.
    Shipped {
        gap_id: String,
        /// PR number parsed from the agent reply (empty string if not found).
        pr_number: String,
        /// HEAD commit SHA at ship time (empty string if unavailable).
        commit_sha: String,
    },
    /// Any non-clean exit: uncaught error, timeout, panic, signal, or
    /// an explicit "I can't make progress" return.
    Blocked {
        gap_id: String,
        /// Human-readable reason phrase (max ~200 chars).
        reason: String,
        /// Optional hint for recovery (e.g. "wait_for_ci", "fix_billing",
        /// "manual_rescue"). Empty string when unknown.
        recoverable_by: String,
    },
    /// Agent decided to pause and wait for an external event.
    Deferred {
        gap_id: String,
        reason: String,
        /// Name of the event the agent is waiting on (e.g. "upstream_pr_landed").
        defer_until_event: String,
    },
}

/// Emit one terminal outcome to ambient.jsonl. Call this ONCE per
/// `chump --execute-gap` run, immediately before process exit.
///
/// Best-effort: write failures are silently discarded so they can never
/// prevent the parent process from exiting with the right code.
pub fn emit_terminal_outcome(outcome: &ExecuteGapOutcome) {
    use std::io::Write;
    let cwd = std::env::current_dir().unwrap_or_default();
    let ambient =
        locate_ambient(&cwd).unwrap_or_else(|| cwd.join(".chump-locks").join("ambient.jsonl"));
    let _ = std::fs::create_dir_all(ambient.parent().unwrap_or(&cwd));
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let session = crate::ambient_stream::env_session_id().unwrap_or_default();
    let line = match outcome {
        ExecuteGapOutcome::Shipped {
            gap_id,
            pr_number,
            commit_sha,
        } => format!(
            "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"gap_shipped\",\
             \"gap_id\":\"{gap_id}\",\"pr_number\":\"{pr_number}\",\
             \"commit_sha\":\"{commit_sha}\",\"emitter\":\"execute_gap\"}}"
        ),
        ExecuteGapOutcome::Blocked {
            gap_id,
            reason,
            recoverable_by,
        } => {
            let reason_esc = escape_json(reason);
            let rec_esc = escape_json(recoverable_by);
            format!(
                "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"gap_blocked\",\
                 \"gap_id\":\"{gap_id}\",\"reason\":\"{reason_esc}\",\
                 \"recoverable_by\":\"{rec_esc}\",\"emitter\":\"execute_gap\"}}"
            )
        }
        ExecuteGapOutcome::Deferred {
            gap_id,
            reason,
            defer_until_event,
        } => {
            let reason_esc = escape_json(reason);
            let evt_esc = escape_json(defer_until_event);
            format!(
                "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"gap_deferred\",\
                 \"gap_id\":\"{gap_id}\",\"reason\":\"{reason_esc}\",\
                 \"defer_until_event\":\"{evt_esc}\",\"emitter\":\"execute_gap\"}}"
            )
        }
    };
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Minimal JSON string escaping for the reason/event fields.
/// Only handles the subset that can appear in error messages and gap IDs.
fn escape_json(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c => vec![c],
        })
        .collect()
}

/// Parse a PR number from the agent reply string. Returns empty string if
/// not found. Accepts numeric sequences that follow "PR #NNN", "#NNN", or
/// are standalone digit-only tokens.
pub fn parse_pr_number_from_reply(reply: &str) -> String {
    // Try "PR #NNN" or "#NNN" first (most common agent reply shapes).
    for token in reply.split_whitespace() {
        let digits = token.trim_start_matches('#');
        if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
            // Only accept if the preceding token was "PR" or token starts with '#'
            if token.starts_with('#') {
                return digits.to_string();
            }
        }
    }
    // Fallback: first standalone number in the reply
    for token in reply.split_whitespace() {
        if !token.is_empty() && token.chars().all(|c| c.is_ascii_digit()) {
            return token.to_string();
        }
    }
    String::new()
}

/// Read HEAD commit SHA from git. Returns empty string if git is unavailable.
pub fn current_head_sha() -> String {
    std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default()
}

/// Build the dispatched-subagent prompt. Mirrors `chump_orchestrator::dispatch::build_prompt`
/// so reflection rows from both backends compare apples-to-apples on COG-026 A/B.
/// Reads `docs/process/CHUMP_DISPATCH_RULES.md` from `repo_root` and injects it inline so
/// the chump-local backend receives coordination rules regardless of whether it
/// reads files unprompted.
///
/// COG-031 step 1: when `OPENAI_MODEL` matches a known non-Sonnet family, a
/// model-shape overlay (from [`crate::model_overlay`]) is prepended ahead of
/// the rules block. The overlay addresses the specific failure modes observed
/// in the COG-026 V2-V5 trials (read-loop iter-cap on chat-Instruct, chatty
/// "Would you like me to..." exit on coder-Instruct). Sonnet and unknown
/// models get no overlay (Sonnet ships fine on the bare prompt; Other lacks
/// empirical signal to justify a guess).
pub fn build_execute_gap_prompt(gap_id: &str, repo_root: &std::path::Path) -> String {
    let row = crate::dispatch_repair::load_canonical_gap(repo_root, gap_id).ok();
    build_execute_gap_prompt_with_row(gap_id, repo_root, row.as_ref())
}

/// Build the execute-gap prompt, inlining the canonical gap's title,
/// description, and acceptance criteria when available from the canonical
/// `state.db` store (`RESILIENT-1494`).
pub fn build_execute_gap_prompt_with_row(
    gap_id: &str,
    repo_root: &std::path::Path,
    row: Option<&chump_gap_store::GapRow>,
) -> String {
    let rules = std::fs::read_to_string(repo_root.join("docs/process/CHUMP_DISPATCH_RULES.md"))
        .unwrap_or_default();
    let rules_block = if rules.is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    };
    let overlay_block = maybe_overlay_from_env().unwrap_or_default();
    // INFRA-332: subagent-shipping-epilogue (canonical token). Same
    // injection as crates/chump-orchestrator/src/dispatch.rs::build_prompt
    // so both backends present an identical recovery / final-report
    // contract. Closes the META-025 25-33% self-ship gap.
    let epilogue =
        std::fs::read_to_string(repo_root.join("scripts/dispatch/subagent-shipping-epilogue.md"))
            .unwrap_or_default();
    let epilogue_block = if epilogue.is_empty() {
        String::new()
    } else {
        format!("\n\n---\n\n{epilogue}")
    };
    let gap_spec_block = match row {
        Some(r) => {
            let ac = if r.acceptance_criteria.trim().is_empty() {
                String::new()
            } else {
                format!("\nAcceptance Criteria:\n{}\n", r.acceptance_criteria)
            };
            format!(
                "\n\nCanonical Gap Specification ({gap}):\nTitle: {title}\nEffort: {effort}\n\n{desc}\n{ac}\n",
                gap = gap_id,
                title = r.title,
                effort = r.effort,
                desc = r.description,
                ac = ac,
            )
        }
        None => String::new(),
    };
    format!(
        "{overlay}{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps/<ID>.yaml for full acceptance criteria.{spec} \
Do the work, then ship via:\n  scripts/coord/bot-merge.sh --gap {gap} --auto-merge\n\
After ship, exit. Reply ONLY with the PR number.{epilogue}",
        overlay = overlay_block,
        rules = rules_block,
        gap = gap_id,
        spec = gap_spec_block,
        epilogue = epilogue_block,
    )
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-733: free-tier dispatch harness (Groq, Cerebras, NVIDIA, etc.)
// ──────────────────────────────────────────────────────────────────────

/// Detect whether `OPENAI_MODEL` + `OPENAI_API_BASE` point at a non-Claude
/// free-tier provider. When true, `execute_gap` uses a slim 5-tool profile
/// and a simplified prompt that avoids confusing non-Claude models.
fn is_free_tier_model() -> bool {
    // EFFECTIVE-324: an explicitly-configured free-tier rotation is a direct
    // operator instruction to use free-tier dispatch. Don't let a stale
    // OPENAI_API_BASE (e.g. the local-ollama default baked into .env) veto it
    // and silently fall back to the web-slim chat profile — that profile lacks
    // patch_file AND any search tool, so the worker explores blind and ships
    // nothing. The provider (and a cloud OPENAI_API_BASE) is set later in the
    // rotation loop via activate_free_tier_provider.
    if std::env::var("CHUMP_FREE_TIER_PROVIDERS")
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false)
        || std::env::var("CHUMP_FREE_TIER_MODE").as_deref() == Ok("1")
    {
        // RESILIENT (CJ silent-bail root cause): a free-tier rotation is only
        // *usable* if at least one of its providers actually has an API key in
        // the environment. The repo-committed model-escalation-ladder manifest
        // (scripts/setup/model-escalation-ladder.env) is sourced by EVERY
        // worker on EVERY node, so CHUMP_FREE_TIER_PROVIDERS is set even on
        // nodes deliberately configured for the Anthropic subscription
        // (CHUMP_AUTH_MODE=oauth, FLEET_MODEL=sonnet, a valid
        // CLAUDE_CODE_OAUTH_TOKEN) that carry NO OpenRouter/Groq keys. Letting
        // the mere presence of the list force free-tier made such a node pick
        // the slim free-tier profile upfront, skip every keyless provider, and
        // bail in ~5s every cycle — never once trying the sub it was told to
        // use. When no free-tier key is present but a valid Anthropic sub
        // credential IS, fall through to the normal sub agent instead
        // (honoring FLEET_MODEL/oauth). Nodes that actually have free-tier
        // keys, or that have no sub credential at all, are unaffected.
        if !free_tier_has_usable_key() && anthropic_sub_available() {
            eprintln!(
                "[execute-gap] free-tier configured (CHUMP_FREE_TIER_PROVIDERS/MODE) but no \
                 provider key is present; a valid Anthropic sub credential IS present — \
                 routing to the subscription (e.g. sonnet via oauth), NOT a keyless free-tier"
            );
            return false;
        }
        return true;
    }
    let model = std::env::var("OPENAI_MODEL")
        .unwrap_or_default()
        .to_lowercase();
    let base = std::env::var("OPENAI_API_BASE")
        .unwrap_or_default()
        .to_lowercase();

    // Anything that resolves to a non-Claude family is free-tier candidate
    let family = detect_model_family(&model);
    let is_non_claude = !matches!(family, ModelFamily::Sonnet | ModelFamily::OtherClaude);

    // Double-check: base URL must point at a known free-tier endpoint, not Ollama
    let is_cloud_endpoint = base.contains("groq.com")
        || base.contains("cerebras.ai")
        || base.contains("together.xyz")
        || base.contains("nvidia.com")
        || base.contains("openrouter.ai")
        || base.contains("github.ai")
        || base.contains("googleapis.com")
        || base.contains("hyperbolic.xyz");

    is_non_claude && is_cloud_endpoint
}

/// True when at least one configured free-tier provider has a usable API key in
/// the environment. Mirrors the per-provider `has_key` check in the rotation
/// loop (see `execute_gap`) EXACTLY so the up-front free-tier decision and the
/// loop agree on what "usable" means — a provider whose key env is set (to any
/// value), or a non-empty generic `OPENAI_API_KEY`.
fn free_tier_has_usable_key() -> bool {
    if std::env::var("OPENAI_API_KEY")
        .map(|k| !k.is_empty())
        .unwrap_or(false)
    {
        return true;
    }
    parse_free_tier_providers()
        .iter()
        .any(|spec| std::env::var(&spec.api_key_env).is_ok())
}

/// True when an Anthropic subscription / API credential is available for the
/// normal (non-free-tier) dispatch path — i.e. the worker can transact with
/// the sub even though no free-tier provider key is configured.
fn anthropic_sub_available() -> bool {
    std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
        .map(|t| !t.trim().is_empty())
        .unwrap_or(false)
        || std::env::var("ANTHROPIC_API_KEY")
            .map(|k| !k.trim().is_empty())
            .unwrap_or(false)
}

// ──────────────────────────────────────────────────────────────────────
// EFFECTIVE-002: free-tier provider rotation
// ──────────────────────────────────────────────────────────────────────

/// One entry in the ordered rotation list.
struct FreeTierProviderSpec {
    model: String,
    base_url: String,
    /// Name of the env var holding the API key for this provider
    /// (e.g. `"GROQ_API_KEY"`).  Falls back to `OPENAI_API_KEY` when unset.
    api_key_env: String,
}

/// Parse `CHUMP_FREE_TIER_PROVIDERS` (format: `model@base_url:KEY_ENV,...`)
/// or return the built-in worker-floor default order.
///
/// EFFECTIVE-445: the worker FLOOR is DeepSeek-primary, not free-first. Free
/// tiers (nemotron:free / groq gpt-oss) 429 under sustained worker load, so a
/// free-first floor STALLS. The funded OpenRouter DeepSeek paid rungs
/// (deepseek-v4-flash → -pro, ~$0.01/gap, no rate cap) lead; the free tiers
/// stay ONLY as a last cheap escalation BEHIND DeepSeek. This default is the
/// fresh-checkout fallback; each node's providers.env sets the same order.
///
/// RESILIENT-1002: Cerebras sits immediately behind the two DeepSeek rungs.
/// When OpenRouter's balance runs dry, DeepSeek returns HTTP 402 on both
/// flash and pro — the rotation loop (see `execute_gap`'s free-tier branch)
/// cascades on `should_cascade_on_error_string`, so a bare DeepSeek-only
/// floor would run straight out of rungs and surface as
/// `BillingExhausted` (exit 75). Cerebras is a separate account (its own
/// `CEREBRAS_API_KEY`), so a DeepSeek 402 never touches it.
fn parse_free_tier_providers() -> Vec<FreeTierProviderSpec> {
    const DEFAULTS: &str = concat!(
        "deepseek/deepseek-v4-flash@https://openrouter.ai/api/v1:OPENROUTER_API_KEY,",
        "deepseek/deepseek-v4-pro@https://openrouter.ai/api/v1:OPENROUTER_API_KEY,",
        "qwen-3-235b-a22b-instruct-2507@https://api.cerebras.ai/v1:CEREBRAS_API_KEY,",
        "nvidia/nemotron-3-super-120b-a12b:free@https://openrouter.ai/api/v1:OPENROUTER_API_KEY,",
        "openai/gpt-oss-20b@https://api.groq.com/openai/v1:GROQ_API_KEY"
    );
    let raw = std::env::var("CHUMP_FREE_TIER_PROVIDERS").unwrap_or_else(|_| DEFAULTS.to_string());
    raw.split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            // Split on last ':' to get KEY_ENV, then '@' to get model vs base_url
            let (model_base, key_env) = entry.rsplit_once(':')?;
            let (model, base_url) = model_base.split_once('@')?;
            if model.is_empty() || base_url.is_empty() || key_env.is_empty() {
                return None;
            }
            Some(FreeTierProviderSpec {
                model: model.trim().to_string(),
                base_url: base_url.trim().to_string(),
                api_key_env: key_env.trim().to_string(),
            })
        })
        .collect()
}

/// Point env vars at `spec` so `build_provider_single_pub` picks it up.
fn activate_free_tier_provider(spec: &FreeTierProviderSpec) {
    std::env::set_var("OPENAI_API_BASE", &spec.base_url);
    std::env::set_var("OPENAI_MODEL", &spec.model);
    // Prefer the provider-specific key; fall back to the generic one.
    if let Ok(key) = std::env::var(&spec.api_key_env) {
        std::env::set_var("OPENAI_API_KEY", key);
    }
    // EFFECTIVE-1933: only force CHUMP_FREE_TIER_MODE=1 (which injects a 5,000ms
    // inter-turn sleep) when CHUMP_PAID_TIER is not set to "1".
    if std::env::var("CHUMP_PAID_TIER").as_deref() != Ok("1") {
        std::env::set_var("CHUMP_FREE_TIER_MODE", "1");
    }
}

/// INFRA-3459: does this gap touch the repo's wiring/architecture (adds or
/// registers a capability/tool/gate/profile, or is about wiring/consumption
/// itself) — the class where the comprehension REPO MAP earns its ~750 tokens?
/// Narrow bug-fixes return false so the lean free-tier prompt is preserved.
/// Pure over (title, ac) so it's deterministic and unit-testable.
fn gap_touches_wiring(title: &str, ac: &str) -> bool {
    let hay = format!("{title} {ac}").to_lowercase();
    // Signals kept specific to architecture/wiring so we don't inject the map
    // into most gaps (that would defeat "targeted"). Leading spaces on the
    // risky short words avoid matching investigate/mitigate/delegates/etc.
    const SIGNALS: &[&str] = &[
        "wire",
        "wiring",
        "unwired",
        "not wired",
        "register",
        "registration",
        "registered but",
        "activation profile",
        "tool profile",
        "tool inventory",
        "dispatch profile",
        "capability",
        "capabilities",
        " gate ",
        " gates",
        "git hook",
        "pre-commit",
        "pre-push",
        "ci gate",
        "mcp server",
        "mcp tool",
        "inconsistent default",
        "flag drift",
        "consume",
        "consumed",
    ];
    SIGNALS.iter().any(|s| hay.contains(s))
}

/// INFRA-3459: run `comprehend` on `root` and wrap its report as a REPO MAP
/// section for the free-tier prompt, or `""` on any failure. Best-effort by
/// construction (mirrors `briefing::build_comprehension`): disabled by
/// `CHUMP_COMPREHEND_ENABLED=0`, `""` when the binary is absent, killed +
/// dropped past the wall-clock budget, and byte-capped so a huge report can't
/// bloat a weak model's prompt.
fn free_tier_comprehend_section(root: &std::path::Path) -> String {
    use std::io::Read;

    if std::env::var("CHUMP_COMPREHEND_ENABLED").as_deref() == Ok("0") {
        return String::new();
    }
    let Some(bin) = crate::comprehend_tool::comprehend_bin() else {
        return String::new();
    };
    let timeout_s: u64 = std::env::var("CHUMP_COMPREHEND_TIMEOUT_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(20);

    let Ok(mut child) = std::process::Command::new(&bin)
        .arg("--repo")
        .arg(root)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        return String::new();
    };

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_s);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return String::new();
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            Err(_) => return String::new(),
        }
    }

    let mut buf = String::new();
    if let Some(mut so) = child.stdout.take() {
        let _ = so.read_to_string(&mut buf);
    }
    let text = buf.trim();
    if text.is_empty() {
        return String::new();
    }

    const MAX: usize = 3000;
    let body = if text.len() > MAX {
        let mut end = MAX;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        &text[..end]
    } else {
        text
    };
    // Fenced + clearly labelled as reference so a weak model treats it as
    // grounding, not as another instruction to act on.
    format!("\n## Repo map (comprehension — reference, only if your change touches wiring/gates)\n```\n{body}\n```\n")
}

/// Build a simplified prompt for free-tier models. Key differences from
/// `build_execute_gap_prompt`:
///
/// 1. Inlines the gap YAML directly (no "read the file" indirection)
/// 2. Lists only the 4 available tools with clear descriptions
/// 3. Explicit step-by-step workflow: read → patch → commit → reply "done"
/// 4. No defensive SCOPE-REFUSE clauses (Llama hallucinated refusals)
/// 5. No `run_cli`/`run_test`/`git_push` — push + PR creation is handled
///    by `execute_gap` as post-processing after the agent returns "done"
///    (INFRA-733 follow-up: free-tier models must not call push tools —
///    too many schema tokens and observed hallucination of wrong tool names)
fn build_free_tier_prompt(gap_id: &str, repo_root: &std::path::Path) -> String {
    // EFFECTIVE-311: the per-file YAML mirrors were retired — reading them
    // handed every open-model dispatch "(gap YAML not found)" as its ENTIRE
    // task spec, so models explored read-only and shipped nothing. state.db
    // is canonical; the YAML file remains only as a legacy fallback.
    // Follow-up (same gap): dispatches run INSIDE a linked worktree where
    // <worktree>/.chump/state.db doesn't exist — GapStore::open would create
    // an EMPTY db there and the model stayed blind. Resolve the MAIN checkout
    // (shared .git parent), which owns the canonical state.db.
    let canonical_root = crate::repo_path::main_checkout_root();
    let gap_row = chump_gap_store::GapStore::open(&canonical_root)
        .ok()
        .and_then(|store| store.get(gap_id).ok().flatten());
    // INFRA-3459: only wiring/architecture gaps get the comprehension REPO MAP.
    // Narrow bug-fixes keep the lean weak-model prompt (weak free-tier models
    // ship less when distracted — RESILIENT-187/EFFECTIVE-311 scar tissue), so
    // spend the ~750 grounding tokens only where they earn their keep.
    let wiring_gap = gap_row
        .as_ref()
        .map(|r| gap_touches_wiring(&r.title, &r.acceptance_criteria))
        .unwrap_or(false);
    let gap_yaml = gap_row
        .map(|row| {
            let almanac_grounding = if crate::almanac_tool::almanac_available() {
                let client =
                    chump_gap_store::maintenance::enricher::CliAlmanacClient::new("chump");
                chump_gap_store::maintenance::enricher::deterministic_almanac_grounding(
                    &row, &client, 5,
                )
                .unwrap_or_default()
            } else {
                String::new()
            };
            let full_desc = format!("{}{}", row.description, almanac_grounding);
            format!(
                "id: {}\ntitle: {}\npriority: {}\neffort: {}\ndescription: |\n  {}\nacceptance_criteria: |\n  {}",
                row.id,
                row.title,
                row.priority,
                row.effort,
                full_desc.replace('\n', "\n  "),
                row.acceptance_criteria.replace('\n', "\n  "),
            )
        })
        .or_else(|| {
            std::fs::read_to_string(repo_root.join(format!("docs/gaps/{gap_id}.yaml"))).ok()
        })
        .unwrap_or_else(|| format!("(gap spec not found — work on gap {gap_id})"));

    // INFRA-3459: for wiring gaps, embed the comprehend summary inline. The
    // free-tier agent CAN'T call comprehend_repo (not in its slim tool set) and
    // is too weak to reliably call tools anyway, so grounding must be in the
    // prompt, not a directive. Best-effort: "" when disabled, binary absent,
    // timed out, or not a wiring gap — so the lean path is byte-for-byte unchanged.
    let repo_map = if wiring_gap {
        free_tier_comprehend_section(&canonical_root)
    } else {
        String::new()
    };

    let overlay = maybe_overlay_from_env().unwrap_or_default();

    // RESILIENT-187: weak free-tier models (glm-5.2, minimax-m3, …) emit
    // structurally-broken unified diffs — blank context lines missing the
    // leading space ("corrupt patch at line N"), wrong hunk counts, and
    // overlapping hunks. Neither git apply, GNU patch, nor our strict→fuzzy→
    // tier-c applier can rescue a truly-broken diff, so the patch lands in
    // $CHUMP_PATCH_DEBUG_DIR, the model retries patch_file until the cycle
    // wall, zero commits result, and bot-merge refuses (CREDIBLE-162). When
    // CHUMP_FREE_TIER_WRITE_FILE is set, steer the model to write_file
    // (whole-file rewrite) instead — no diff structure means nothing to
    // corrupt. Capable free models keep the leaner patch_file path.
    let write_mode = std::env::var("CHUMP_FREE_TIER_WRITE_FILE")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);

    // INFRA-3445: route weak free-tier models to almanac_search as the
    // grounding step. EFFECTIVE-324 wired almanac_search into the free-tier
    // tool set, but this workflow still said "Step 1: grep_repo" and never
    // mentioned almanac — so the model did exactly what it was told, grepped
    // blind, and shipped non-fixes the verify gate (CREDIBLE-170) then
    // rejected. Affordance over gate: point the model at the tool it has.
    let (locate_step, locate_rule) =
        free_tier_locate_step(crate::almanac_tool::almanac_available());

    // EFFECTIVE-355: str_replace is the PRIMARY edit affordance for open/weak models —
    // anchored old->new means no @@ hunks to mis-format (patch_file) and no whole-file
    // rewrite to truncate/clobber (write_file). The clobber failure mode: an open model
    // told to "rewrite the ENTIRE file" reproduced a 14KB file as 467 bytes and the
    // ship guard had to reject it. str_replace can only change the snippet it names.
    let (edit_step, edit_rule) = if write_mode {
        (
            "Step 3: str_replace — make your edit by replacing an EXACT snippet. Read the file first, \
   copy the exact text to change into `old_string` (verbatim, including indentation), and put the \
   corrected text in `new_string`. `old_string` MUST match EXACTLY ONCE — include enough surrounding \
   lines to be unique. Do NOT rewrite the whole file and do NOT emit a diff. Use write_file ONLY to \
   create a brand-new file.",
            "- Prefer str_replace (anchored old->new) for ALL edits; it changes only the snippet you name. write_file is ONLY for creating a new file — never rewrite an existing file whole.",
        )
    } else {
        (
            "Step 3: str_replace — make your edit by replacing an EXACT snippet. Read the file first, \
   copy the exact text to change into `old_string` (verbatim, including indentation), and put the \
   corrected text in `new_string`. `old_string` MUST match EXACTLY ONCE — include enough surrounding \
   lines to be unique. Do NOT rewrite the whole file and do NOT emit a diff. For a large multi-site \
   change you may fall back to patch_file.",
            "- Prefer str_replace (anchored old->new) for ALL edits; it changes only the snippet you name.",
        )
    };

    format!(
        "{overlay}You are a code agent working in a Rust repository. \
Your ONLY job is to make code changes that satisfy the gap below, then commit.

## Gap
```yaml
{gap_yaml}
```
{repo_map}
## Workflow (follow exactly, ONE tool call per response)
{locate_step}
Step 2: read_file — read the file the previous step pointed you to.
{edit_step}
Step 4: git_commit — commit with message \"{gap_id}: <short summary>\". \
   This automatically stages modified files.
Step 5: Respond with the single word: done

## Rules
- ONE tool call per response. Do NOT call multiple tools at once.
{locate_rule}
- NEVER write documentation, plans, or markdown files.
- NEVER explain what you will do — just call the tool.
- NEVER create new files (no chump-plan.md, no docs/*.md).
{edit_rule}
- You MUST read a file with read_file BEFORE editing it.
- After git_commit succeeds, respond \"done\" and stop.",
        overlay = overlay,
        gap_yaml = gap_yaml,
        repo_map = repo_map,
        locate_step = locate_step,
        locate_rule = locate_rule,
        edit_step = edit_step,
        edit_rule = edit_rule,
        gap_id = gap_id,
    )
}

/// INFRA-3445: pick the "locate the code" workflow step + rule for the
/// free-tier prompt. When almanac_search is available, route the model to
/// ground itself in the codebase graph FIRST — EFFECTIVE-324 wired the tool
/// into the free-tier set but the workflow still said "Step 1: grep_repo" and
/// never named almanac, so weak models grepped blind and shipped non-fixes the
/// verify gate then rejected. Pure (no I/O) so both branches are unit-testable.
fn free_tier_locate_step(almanac_on: bool) -> (&'static str, &'static str) {
    if almanac_on {
        (
            "Step 1: almanac_search — ground yourself FIRST. Query the codebase graph \
   with a phrase from the gap (function name, symbol, error string, or concept) to \
   pinpoint the exact file(s), symbols, and call-sites this gap touches. Prefer it \
   over grep_repo; use grep_repo only if almanac_search returns nothing. Do NOT guess \
   file paths or walk directories with list_dir.",
            "- START with almanac_search to ground yourself in the codebase graph; fall back to grep_repo only on an empty result.",
        )
    } else {
        (
            "Step 1: grep_repo — search for a function name, error string, or key phrase \
   from the gap to FIND the file that needs changing. Do NOT guess file paths \
   or walk directories with list_dir — search first.",
            "- START with grep_repo to locate code — it is far faster than list_dir.",
        )
    }
}

/// Build a [`ChumpAgent`] with the slim 5-tool free-tier profile.
/// Bypasses the full system prompt and session manager — free-tier runs
/// are single-shot (no conversation history needed).
fn build_free_tier_agent() -> Result<ChumpAgent> {
    // Force cascade OFF for free-tier — we want direct-to-provider, not
    // cascading through 8 slots with varying rate limits.
    std::env::set_var("CHUMP_CASCADE_ENABLED", "0");

    // Clear tool approval gating — unattended dispatch must not wait for
    // human approval. The .env may have CHUMP_TOOLS_ASK=write_file,...
    // which blocks write_file/patch_file/git_commit indefinitely when
    // there's no event channel to receive approval.
    std::env::remove_var("CHUMP_TOOLS_ASK");

    let provider: Box<dyn axonerai::provider::Provider + Send + Sync> =
        crate::provider_cascade::build_provider_single_pub();

    let mut registry = axonerai::tool::ToolRegistry::new();
    crate::tool_inventory::register_free_dispatch_tools(&mut registry);

    let max_iter = std::env::var("CHUMP_AGENT_MAX_ITER")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(30);

    // EFFECTIVE-1932 (COG-031 step 3c): inject the per-family autonomous-job
    // directive into the system prompt so weak instruction-following models
    // weight both the system channel and the user-turn exemplar.
    let system_prompt = maybe_system_directive_from_env();

    Ok(ChumpAgent::new(
        provider,
        registry,
        system_prompt,
        None, // no session manager — single-shot
        None, // no event channel for CLI
        max_iter,
    ))
}

/// Push the current branch and open a PR via `bot-merge.sh`.
///
/// Called by `execute_gap` after the free-tier agent returns "done".
/// The agent can only commit (no `git_push`/`run_cli` in its tool set);
/// this function owns the push+PR step so the orchestrator can find a PR to poll.
/// Uses `--fast` to skip local clippy/test — CI is the gate, and free-tier
/// dispatch runs against tight task-budget walls (INFRA-252 / INFRA-733).
async fn free_tier_ship(gap_id: &str, repo_root: &std::path::Path) -> Result<()> {
    // INFRA-3406: the agent run pins CHUMP_REPO to the worktree so file
    // tools write HERE — but bot-merge's claim/registry paths need the MAIN
    // checkout. Restore it for the ship subprocess.
    std::env::set_var("CHUMP_REPO", crate::repo_path::main_checkout_root());
    // EFFECTIVE-312: open models routinely patch_file and then skip the
    // git_commit step (observed: first sighted M3 cycle patched 1 file,
    // committed nothing). Uncommitted agent work would either vanish or be
    // swept into an INFRA-472 staging commit that INFRA-997 then refuses to
    // ship. Auto-commit it honestly instead so real work reaches the PR.
    let dirty = tokio::process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(repo_root)
        .output()
        .await
        .map(|o| !o.stdout.is_empty())
        .unwrap_or(false);
    if dirty {
        eprintln!(
            "[execute-gap] EFFECTIVE-312 (restored): {gap_id} left a dirty tree, auto-committing the real edit instead of discarding it"
        );
        let _ = tokio::process::Command::new("git")
            .args(["add", "-A"])
            .current_dir(repo_root)
            .status()
            .await;
        let _ = tokio::process::Command::new("git")
            .args([
                "-c",
                "user.name=chump-fleet",
                "-c",
                "user.email=fleet@chump.local",
                "commit",
                "-m",
                &format!("{gap_id}: agent changes (auto-committed, model skipped git_commit)"),
            ])
            .current_dir(repo_root)
            .status()
            .await;
    }
    // CREDIBLE-170: verify the fix actually accomplishes the gap BEFORE shipping.
    // Cheap free-tier drafts are frequently plausible-but-ineffective (dead code,
    // shadowed dups, no-ops) — CI stays green because nothing broke, so the
    // gap would close with a non-fix. A skeptical model review of the diff-vs-AC
    // gates that. FAIL aborts the ship; the gap stays open for a retry.
    verify_fix_before_ship(gap_id, repo_root).await?;

    // arm-policy: delegated (INFRA-8221). execute-gap never arms or merges a PR
    // itself: bot-merge.sh opens the PR and arms it through auto-merge-armer.sh,
    // which calls arm_policy_allows (scripts/coord/lib/arm-policy.sh), so a held
    // PR (no-auto-merge label / `Auto-merge: hold`) is refused there.
    let script = repo_root.join("scripts/coord/bot-merge.sh");
    eprintln!("[execute-gap] free-tier ship: bot-merge.sh --gap {gap_id} --fast --auto-merge");
    let status = tokio::process::Command::new("bash")
        .arg(&script)
        .arg("--gap")
        .arg(gap_id)
        .arg("--fast")
        .arg("--auto-merge")
        .current_dir(repo_root)
        .status()
        .await
        .with_context(|| format!("launching bot-merge.sh for {gap_id}"))?;
    if !status.success() {
        return Err(anyhow!(
            "bot-merge.sh exited {} for gap {}",
            status.code().unwrap_or(-1),
            gap_id
        ));
    }
    Ok(())
}

/// CREDIBLE-170: skeptical model review of the agent's diff against the gap AC,
/// run before bot-merge. Fails plausible-but-ineffective changes (no-ops, dead
/// code, shadowed/duplicate defs, edits not wired into the real path) so a
/// cheap-model non-fix never merges and closes a gap (green != covered, applied
/// to the fleet's own output). Bypass: CHUMP_VERIFY_DISABLE=1. The reviewer uses
/// the active provider by default; a stronger tier can be routed in later.
/// CREDIBLE-170: classify a reviewer verdict as a fail. Skeptical: an explicit
/// FAIL, or a FAIL mentioned without a PASS, blocks the ship. Pure — unit-tested.
fn verdict_is_fail(verdict: &str) -> bool {
    let up = verdict.trim().to_uppercase();
    up.starts_with("FAIL") || (up.contains("FAIL") && !up.contains("PASS"))
}

async fn verify_fix_before_ship(gap_id: &str, repo_root: &std::path::Path) -> Result<()> {
    if std::env::var("CHUMP_VERIFY_DISABLE").as_deref() == Ok("1") {
        eprintln!("[verify] disabled (CHUMP_VERIFY_DISABLE=1) — shipping {gap_id} unverified");
        return Ok(());
    }
    // Net diff of the agent's work vs the branch base.
    let diff = tokio::process::Command::new("git")
        .args(["diff", "origin/main...HEAD"])
        .current_dir(repo_root)
        .output()
        .await
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    if diff.trim().is_empty() {
        return Err(anyhow!(
            "verify gate: empty diff for {gap_id} — the agent changed nothing to ship"
        ));
    }
    // Gap acceptance criteria (the canonical checkout owns state.db).
    let canonical = crate::repo_path::main_checkout_root();
    let ac = chump_gap_store::GapStore::open(&canonical)
        .ok()
        .and_then(|s| s.get(gap_id).ok().flatten())
        .map(|r| {
            format!(
                "title: {}\ndescription: {}\nacceptance_criteria: {}",
                r.title, r.description, r.acceptance_criteria
            )
        })
        .unwrap_or_else(|| format!("gap {gap_id} (acceptance criteria unavailable)"));

    let diff_trunc: String = diff.chars().take(8000).collect();
    let system = "You are a skeptical senior code reviewer. Judge whether a DIFF actually \
        accomplishes a TASK. Reply with ONE line: 'PASS: <reason>' or 'FAIL: <reason>'. \
        FAIL plausible-but-ineffective changes: no-ops, dead code, a new function that \
        DUPLICATES or SHADOWS an existing one, edits that do not wire into the real code \
        path, or changes that do not address the stated acceptance criteria. When unsure, FAIL.";
    let user = format!(
        "TASK:\n{ac}\n\nDIFF:\n{diff_trunc}\n\nDoes this diff actually accomplish the task?"
    );

    let provider = crate::provider_cascade::build_provider_single_pub();
    let resp = provider
        .complete(
            vec![axonerai::provider::Message {
                role: "user".to_string(),
                content: user,
            }],
            None,
            Some(256),
            Some(system.to_string()),
        )
        .await
        .with_context(|| format!("verify gate: reviewer call failed for {gap_id}"))?;
    let verdict = resp.text.unwrap_or_default();
    let failed = verdict_is_fail(&verdict);

    // scanner-anchor: "kind":"fix_verify_failed"
    // scanner-anchor: "kind":"fix_verify_passed"
    let amb = locate_ambient(&canonical)
        .unwrap_or_else(|| canonical.join(".chump-locks").join("ambient.jsonl"));
    let kind = if failed {
        "fix_verify_failed"
    } else {
        "fix_verify_passed"
    };
    let line = format!(
        "{{\"kind\":\"{}\",\"gap_id\":\"{}\",\"verdict\":{},\"source\":\"execute_gap\"}}\n",
        kind,
        gap_id,
        serde_json::to_string(verdict.trim()).unwrap_or_else(|_| "\"\"".into())
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });

    if failed {
        eprintln!("[verify] FAIL for {gap_id}: {verdict}");
        return Err(anyhow!(
            "verify gate: fix does not accomplish {gap_id} — {verdict}. Gap stays open for retry."
        ));
    }
    eprintln!("[verify] PASS for {gap_id}: {verdict}");
    Ok(())
}

/// Minimal gap-id syntactic check (INFRA-630). Accepts:
///   - Classic `DOMAIN-NUMBER` form: `[A-Z][A-Z0-9]+-\d+` (e.g. INFRA-630)
///   - Full RFC-4122 UUID: 8-4-4-4-12 lowercase hex (e.g. 8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9)
///   - 8-char hex short-prefix used by chump-proprietary display (e.g. 8d3f2c0e)
///
/// Fails the run early if the caller passed garbage so we don't waste a
/// provider call building a prompt for a non-gap.
pub(crate) fn validate_gap_id(gap_id: &str) -> Result<()> {
    if gap_id.is_empty() {
        return Err(anyhow!("gap id is empty"));
    }

    // INFRA-630: accept 8-char hex short-prefix (chump-proprietary display form)
    if gap_id.len() == 8 && gap_id.chars().all(|c| c.is_ascii_hexdigit()) {
        tracing::debug!(gap_id, "INFRA-630: UUID short-prefix gap id accepted");
        return Ok(());
    }

    // INFRA-630: accept full RFC-4122 UUID (8-4-4-4-12 hex groups, lowercase)
    // Pattern: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    let parts: Vec<&str> = gap_id.split('-').collect();
    if parts.len() == 5 {
        let lengths = [8usize, 4, 4, 4, 12];
        if parts
            .iter()
            .zip(lengths.iter())
            .all(|(p, &len)| p.len() == len && p.chars().all(|c| c.is_ascii_hexdigit()))
        {
            tracing::debug!(gap_id, "INFRA-630: RFC-4122 UUID gap id accepted");
            return Ok(());
        }
    }

    // Classic DOMAIN-NUMBER form. INFRA-3404: split on the LAST hyphen so
    // double-hyphen domains (ZERO-WASTE-015) validate; the prefix charset
    // therefore admits '-' as well.
    let Some((prefix, num)) = gap_id.rsplit_once('-') else {
        return Err(anyhow!("gap id missing '-': {gap_id}"));
    };
    if prefix.is_empty()
        || !prefix
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(anyhow!(
            "gap id prefix must be uppercase letters/digits: {gap_id}"
        ));
    }
    if num.is_empty() || !num.chars().all(|c| c.is_ascii_digit()) {
        return Err(anyhow!("gap id suffix must be digits: {gap_id}"));
    }
    Ok(())
}

/// INFRA-2056: emit a subagent heartbeat to ambient.jsonl.
/// Writes kind=subagent_heartbeat so wizard-daemon can detect stalled agents
/// within 2min (heartbeat >120s stale → infer dying/dead).
///
/// Fields match the INFRA-2056 AC:
///   gap_id, pid, last_action (last tool name), iter_count (tool call count)
fn emit_subagent_heartbeat(gap_id: &str, pid: u32, last_action: &str, iter_count: u64) {
    use std::io::Write;
    let cwd = std::env::current_dir().unwrap_or_default();
    let ambient =
        locate_ambient(&cwd).unwrap_or_else(|| cwd.join(".chump-locks").join("ambient.jsonl"));
    let _ = std::fs::create_dir_all(ambient.parent().unwrap_or(&cwd));
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let session = crate::ambient_stream::env_session_id().unwrap_or_default();
    // Sanitise last_action: strip any chars that would break JSON (quotes, backslashes)
    let safe_action: String = last_action
        .chars()
        .map(|c| if c == '"' || c == '\\' { '_' } else { c })
        .take(64)
        .collect();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"subagent_heartbeat\",\
         \"gap_id\":\"{gap_id}\",\"pid\":{pid},\"last_action\":\"{safe_action}\",\
         \"iter_count\":{iter_count}}}"
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Run the agent loop on the dispatched-gap prompt. Used by main.rs's
/// `--execute-gap` arm. Returns `Ok(reply)` on success.
pub async fn execute_gap(gap_id: &str) -> Result<String> {
    validate_gap_id(gap_id).with_context(|| format!("validating gap id {gap_id:?}"))?;

    // EFFECTIVE-448: this command is expected to PRODUCE an edit. Signal the
    // agent loop (iteration_controller) to fire the force-edit nudge when a
    // (weak) model investigates but never applies a str_replace, instead of
    // Completing into an empty diff that free_tier_ship then rejects.
    std::env::set_var("CHUMP_REQUIRE_EDIT", "1");

    // Mirror the contract in dispatch.rs: subagents must not recursively
    // dispatch. The orchestrator sets CHUMP_DISPATCH_DEPTH=1 in the env;
    // we honor it as a tripwire here too (defensive — if a chump-local
    // subagent somehow respawns chump --execute-gap, we'd recurse).
    if std::env::var("CHUMP_DISPATCH_DEPTH")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .map(|d| d >= 2)
        .unwrap_or(false)
    {
        return Err(anyhow!(
            "CHUMP_DISPATCH_DEPTH >= 2 — refusing to recurse (subagents must not dispatch further subagents)"
        ));
    }

    let repo_root = std::env::current_dir().unwrap_or_default();

    // INFRA-733: detect free-tier model before plan-mode (skip plan-mode
    // for free-tier — plan_mode calls `gh pr list` and reads DISPATCH_RULES
    // which confuses non-Claude models).
    let free_tier = is_free_tier_model();
    if free_tier {
        let model = std::env::var("OPENAI_MODEL").unwrap_or_default();
        eprintln!("[execute-gap] free-tier mode: model={model}, slim dispatch profile");
        // INFRA-3406: file tools (read/patch/git_commit) resolve paths via
        // CHUMP_REPO — inherited as the MAIN checkout from worker env, so
        // every model patch and commit landed OUTSIDE the dispatch worktree
        // (found stranded in /root/Chump after 15 cycles of "zero-commit
        // branch"). Point the tools at THIS worktree; the canonical state.db
        // is still resolved via main_checkout_root() (git-common-dir),
        // unaffected.
        if let Ok(cwd) = std::env::current_dir() {
            std::env::set_var("CHUMP_REPO", &cwd);
            eprintln!(
                "[execute-gap] INFRA-3406: tool root pinned to worktree {}",
                cwd.display()
            );
        }
        // INFRA-784: signal the agent loop to insert inter-request delays so we
        // don't exhaust the provider's RPM quota on multi-step dispatches.
        // CHUMP_FREE_TIER_DELAY_MS takes precedence if set; this is the fallback
        // that triggers the default 5 000 ms delay when neither flag was set
        // explicitly by the operator. EFFECTIVE-1933: skip for paid BYOK tiers.
        if std::env::var("CHUMP_PAID_TIER").as_deref() != Ok("1") {
            std::env::set_var("CHUMP_FREE_TIER_MODE", "1");
        }
    }

    // INFRA-060 (M2): plan-mode gate. Skip for free-tier — saves latency
    // and avoids `gh pr list` hangs in cold worktrees.
    if !free_tier {
        match plan_mode::run_plan_mode(gap_id, &repo_root)? {
            PlanOutcome::Proceed { plan_path } => {
                if let Some(p) = plan_path {
                    eprintln!("[execute-gap] plan-mode: wrote {}", p.display());
                }
            }
            PlanOutcome::Abort { reason, conflicts } => {
                return Err(anyhow!(
                    "plan-mode aborted: {reason}\nconflicts: {conflicts:?}"
                ));
            }
        }
    }

    let prompt = if free_tier {
        build_free_tier_prompt(gap_id, &repo_root)
    } else {
        build_execute_gap_prompt(gap_id, &repo_root)
    };

    if free_tier {
        // RESILIENT (CJ silent-bail root cause): FAIL LOUD when free-tier was
        // selected but NO provider has a usable key. Reaching here means
        // `is_free_tier_model()` already declined to route to the sub — so
        // there is no key AND no Anthropic sub credential. That is a worker
        // MISCONFIGURATION (it can do no work at all), not a transient
        // provider exhaustion, and the old path swallowed it as a generic
        // ~5s rc=1 bail that hot-looped every cycle. Surface it explicitly
        // with an actionable message so the condition is unmistakable in the
        // worker log / journal instead of masquerading as "providers
        // exhausted".
        if !free_tier_has_usable_key() {
            eprintln!(
                "[execute-gap] ALERT: no usable inference provider for gap {gap_id} — \
                 free-tier dispatch was selected (CHUMP_FREE_TIER_PROVIDERS/MODE set) but \
                 none of its providers has an API key in the environment, AND no Anthropic \
                 sub credential (CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY) is present. \
                 This worker cannot transact. Fix: set a provider key, or configure the sub \
                 (CHUMP_AUTH_MODE=oauth + a valid CLAUDE_CODE_OAUTH_TOKEN)."
            );
            return Err(anyhow!(
                "no usable inference provider for gap {gap_id}: free-tier selected but no \
                 provider key present and no Anthropic sub credential available \
                 (worker misconfiguration — not a transient exhaustion)"
            ));
        }
        // EFFECTIVE-002: rotate through Groq → Cerebras → NVIDIA on 429/exhaustion.
        let providers = parse_free_tier_providers();
        // Start from the provider already configured (match by base URL), or index 0.
        let current_base = std::env::var("OPENAI_API_BASE")
            .unwrap_or_default()
            .to_lowercase();
        let start = providers
            .iter()
            .position(|s| current_base.contains(&s.base_url.to_lowercase()))
            .unwrap_or(0);

        let mut last_err: Option<anyhow::Error> = None;
        let total = providers.len();
        for offset in 0..total {
            let idx = (start + offset) % total;
            let spec = &providers[idx];

            // Skip providers whose API key is not available.
            let has_key = std::env::var(&spec.api_key_env).is_ok()
                || std::env::var("OPENAI_API_KEY")
                    .map(|k| !k.is_empty())
                    .unwrap_or(false);
            if !has_key {
                eprintln!(
                    "[execute-gap] free-tier rotation: skipping {} — no key ({} unset)",
                    spec.model, spec.api_key_env
                );
                continue;
            }

            activate_free_tier_provider(spec);
            eprintln!(
                "[execute-gap] free-tier: trying provider {}/{} — {}",
                offset + 1,
                total,
                spec.model
            );

            let agent = build_free_tier_agent()
                .with_context(|| format!("building free-tier agent for {}", spec.model))?;

            // INFRA-2056: background heartbeat task for this provider attempt.
            // Shared state updated by the agent loop (see iter_count_ft / last_action_ft).
            let ft_iter_count = Arc::new(AtomicU64::new(0));
            let ft_last_action: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
            let ft_hb_cancel = CancellationToken::new();
            let ft_hb_handle = {
                let cancel = ft_hb_cancel.clone();
                let gid = gap_id.to_string();
                let pid = std::process::id();
                let iter_count_ref = Arc::clone(&ft_iter_count);
                let last_action_ref = Arc::clone(&ft_last_action);
                tokio::spawn(async move {
                    let interval = std::env::var("CHUMP_SUBAGENT_HEARTBEAT_SECS")
                        .ok()
                        .and_then(|s| s.parse::<u64>().ok())
                        .unwrap_or(60);
                    loop {
                        tokio::select! {
                            _ = cancel.cancelled() => break,
                            _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {
                                let count = iter_count_ref.load(Ordering::Relaxed);
                                let action = last_action_ref
                                    .lock()
                                    .map(|g| g.clone())
                                    .unwrap_or_default();
                                emit_subagent_heartbeat(&gid, pid, &action, count);
                            }
                        }
                    }
                })
            };

            match agent.run(&prompt).await {
                Ok(outcome) => {
                    ft_hb_cancel.cancel();
                    let _ = ft_hb_handle.await;
                    match free_tier_ship(gap_id, &repo_root).await {
                        Ok(()) => return Ok(outcome.reply),
                        Err(ship_err) => {
                            let se = format!("{ship_err:#}");
                            // EFFECTIVE-465: the agent "ran" but shipped nothing —
                            // the verify gate rejected an EMPTY DIFF (the model
                            // investigated and never applied a str_replace). Do NOT
                            // abort here: ESCALATE up the free-tier ladder (this list
                            // IS the escalation ladder — deepseek-v4-flash →
                            // deepseek-v4-pro → …). A stronger rung may make the edit
                            // the current one wouldn't. Only when the whole ladder has
                            // empty-diffed do we surface the failure (a real finding:
                            // "even flash+pro couldn't edit this"). Non-empty-diff ship
                            // failures (verify-FAIL, push error) are NOT escalated —
                            // those are genuine rejections, not "wrong model".
                            let is_empty_diff =
                                se.contains("empty diff") || se.contains("changed nothing");
                            let is_skipped_commit =
                                se.contains("dirty tree") || se.contains("skipped git_commit");
                            if (is_empty_diff || is_skipped_commit) && offset + 1 < total {
                                let reason = if is_empty_diff {
                                    "EMPTY DIFF"
                                } else {
                                    "SKIPPED GIT_COMMIT"
                                };
                                eprintln!(
                                    "[execute-gap] EFFECTIVE-465: {} produced an {reason} \
                                     for {gap_id} (agent never edited) — escalating to next \
                                     model rung",
                                    spec.model
                                );
                                last_err = Some(ship_err.context(format!(
                                    "free-tier ship step failed for gap {gap_id}"
                                )));
                                continue;
                            }
                            return Err(ship_err).with_context(|| {
                                format!("free-tier ship step failed for gap {gap_id}")
                            });
                        }
                    }
                }
                Err(e) => {
                    ft_hb_cancel.cancel();
                    let _ = ft_hb_handle.await;
                    let e_str = format!("{e:#}");
                    if crate::provider_cascade::should_cascade_on_error_string(&e_str)
                        && offset + 1 < total
                    {
                        // RESILIENT-1002: name the reason code explicitly so a
                        // DeepSeek 402 -> Cerebras fallback is greppable from
                        // the cycle log, not just inferable from the raw error.
                        let reason_code =
                            if crate::provider_cascade::is_billing_exhausted_error_string(&e_str) {
                                "402"
                            } else {
                                "cascade"
                            };
                        eprintln!(
                            "[execute-gap] free-tier rotation: {} exhausted (reason={reason_code}, {e_str:.120}), \
                             trying next provider",
                            spec.model
                        );
                        last_err = Some(e);
                        continue;
                    }
                    return Err(e).with_context(|| format!("agent loop failed for gap {gap_id}"));
                }
            }
        }
        return Err(last_err
            .unwrap_or_else(|| anyhow!("no free-tier providers with API keys configured"))
            .context(format!(
                "all free-tier providers exhausted for gap {gap_id}"
            )));
    }

    let (agent, _ready_session) = build_chump_agent_cli()
        .context("building Chump agent for --execute-gap (provider config? OPENAI_API_BASE?)")?;

    // INFRA-2056: background heartbeat task — emits kind=subagent_heartbeat every 60s.
    // Shared atomic state lets the agent loop update last_action/iter_count without
    // the heartbeat task holding a lock during the sleep interval.
    let hb_iter_count = Arc::new(AtomicU64::new(0));
    let hb_last_action: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let hb_cancel = CancellationToken::new();
    let hb_handle = {
        let cancel = hb_cancel.clone();
        let gid = gap_id.to_string();
        let pid = std::process::id();
        let iter_count_ref = Arc::clone(&hb_iter_count);
        let last_action_ref = Arc::clone(&hb_last_action);
        tokio::spawn(async move {
            let interval = std::env::var("CHUMP_SUBAGENT_HEARTBEAT_SECS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(60);
            loop {
                tokio::select! {
                    _ = cancel.cancelled() => break,
                    _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {
                        let count = iter_count_ref.load(Ordering::Relaxed);
                        let action = last_action_ref
                            .lock()
                            .map(|g| g.clone())
                            .unwrap_or_default();
                        emit_subagent_heartbeat(&gid, pid, &action, count);
                    }
                }
            }
        })
    };

    let outcome = agent
        .run(&prompt)
        .await
        .with_context(|| format!("agent loop failed for gap {gap_id}"))?;

    // Cancel heartbeat task once agent completes.
    hb_cancel.cancel();
    let _ = hb_handle.await;

    Ok(outcome.reply)
}

/// Same as [`execute_gap`] but lets tests inject a pre-built [`ChumpAgent`]
/// (avoiding a real provider). Production caller uses [`execute_gap`].
pub async fn execute_gap_with_agent(agent: &ChumpAgent, gap_id: &str) -> Result<String> {
    validate_gap_id(gap_id)?;
    let repo_root = std::env::current_dir().unwrap_or_default();
    let prompt = build_execute_gap_prompt(gap_id, &repo_root);

    // INFRA-2056: background heartbeat task for test-scoped subagents.
    let hb_iter_count = Arc::new(AtomicU64::new(0));
    let hb_last_action: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let hb_cancel = CancellationToken::new();
    let hb_handle = {
        let cancel = hb_cancel.clone();
        let gid = gap_id.to_string();
        let pid = std::process::id();
        let iter_count_ref = Arc::clone(&hb_iter_count);
        let last_action_ref = Arc::clone(&hb_last_action);
        tokio::spawn(async move {
            let interval = std::env::var("CHUMP_SUBAGENT_HEARTBEAT_SECS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(60);
            loop {
                tokio::select! {
                    _ = cancel.cancelled() => break,
                    _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {
                        let count = iter_count_ref.load(Ordering::Relaxed);
                        let action = last_action_ref
                            .lock()
                            .map(|g| g.clone())
                            .unwrap_or_default();
                        emit_subagent_heartbeat(&gid, pid, &action, count);
                    }
                }
            }
        })
    };

    let outcome = agent.run(&prompt).await?;

    hb_cancel.cancel();
    let _ = hb_handle.await;

    Ok(outcome.reply)
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-302 blocker (1) — agent-loop-boundary error classification
// ──────────────────────────────────────────────────────────────────────
//
// The agent loop today (`src/agent_loop/iteration_controller.rs:191`)
// bubbles ALL provider errors uniformly via `result?`. When the
// dispatched child (`chump --execute-gap`) is wired to a single
// non-cascading provider — the typical free-tier setup, since
// `CHUMP_CASCADE_ENABLED=1` requires explicit slot configuration —
// every provider error escapes as a generic anyhow::Error and main.rs
// exits 1.
//
// Result on the 2026-05-02 dogfood run (filed as INFRA-302):
// Together returned HTTP 402 / credit_limit on the first call; the
// agent loop bailed; the orchestrator's stderr-tailer captured the
// "ERROR" line but had no way to distinguish "billing exhausted —
// switch routing candidate" from "network blip — retry same provider"
// from "tool format failure — try a different model family".
//
// The full fix (orchestrator-level cascade-respawn across routing
// candidates, mapping `provider_pfx` → API base/key) is multi-PR and
// touches `crates/chump-orchestrator/src/dispatch.rs:710` —
// `spawn_chump_local`. This PR ships the upstream half:
// classify the error at the execute-gap exit boundary so a
// distinguishable exit code (75 = `EX_TEMPFAIL`) and a single-line
// structured stderr marker reach the orchestrator's tailer. The
// orchestrator then has the signal it needs to do the cascade-respawn
// in the follow-up PR — without it, no amount of orchestrator-side
// retry logic can work, because every dispatched-child failure looks
// the same.

/// INFRA-302 blocker (1) / INFRA-347: classification of errors returned by
/// [`execute_gap`].
///
/// Three variants — billing-exhausted, transport-unreachable, and
/// everything-else — because those are the discriminators the
/// orchestrator-level cascade-respawn needs:
///
/// * [`BillingExhausted`]: provider returned 402 / credit_limit → switch
///   provider or top up credits.
/// * [`TransportUnreachable`]: local daemon is down or the network path to
///   `OPENAI_API_BASE` is broken → restart the daemon, or cascade to a
///   cloud slot via `CHUMP_CASCADE_ENABLED=1`. INFRA-347: this was
///   previously classified as `Other` (exit 1), making it
///   indistinguishable from a tool storm. Now distinct (exit 76) so the
///   orchestrator can respawn against a reachable provider.
/// * [`Other`]: generic failure (max iterations, tool storm, bad request,
///   model crash). Legacy exit code 1 so existing tooling is unaffected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecuteGapErrorKind {
    /// HTTP 402 / credit_limit / insufficient_quota / payment required /
    /// billing-exhausted class. Operator/orchestrator should switch
    /// provider, top up credits, or cascade to the next routing
    /// candidate. Detected via
    /// [`crate::provider_cascade::is_billing_exhausted_error_string`]
    /// — the same predicate INFRA-300 (PR #890) added the per-call
    /// cascade fail-over for, factored out so it can be reused above
    /// the cascade layer.
    BillingExhausted,
    /// Local daemon unreachable / transport-level failure — "connection
    /// refused", "error sending request", "model HTTP unreachable",
    /// "operation timed out", "no route to host", etc. INFRA-347:
    /// factored out of the per-call cascade predicate so the
    /// orchestrator-level cascade-respawn (exit code 76) can distinguish
    /// "Ollama down" from "billing exhausted" (exit 75) and from generic
    /// failures (exit 1). Detected via
    /// [`crate::provider_cascade::is_transport_unreachable_error_string`].
    TransportUnreachable,
    /// Anything else — generic agent-loop failure (network blip,
    /// max-iterations cap, tool storm, model crash, etc.). Maps to
    /// the legacy exit code 1 so existing operator tooling that
    /// `if [ $? -ne 0 ]` keeps working unchanged.
    Other,
}

impl ExecuteGapErrorKind {
    /// Per-class exit code for `chump --execute-gap`'s main-process
    /// exit. `75` follows BSD `EX_TEMPFAIL` from `sysexits.h` for
    /// billing-exhausted. `76` (`EX_PROTOCOL` — "remote error in
    /// protocol") is the analogous code for transport-unreachable:
    /// the local daemon or the network path is broken, not the
    /// orchestrator's logic. Both are outside the 0–2 range existing
    /// tooling uses for usage / generic-failure, distinct enough that
    /// the orchestrator can pattern-match on each. Stays `1` for the
    /// generic case so `bot-merge.sh` and other shell-level callers
    /// see no behavioral change. INFRA-347 adds the
    /// `TransportUnreachable → 76` mapping.
    pub fn exit_code(self) -> i32 {
        match self {
            Self::BillingExhausted => 75,
            Self::TransportUnreachable => 76,
            Self::Other => 1,
        }
    }

    /// One-line structured marker the orchestrator's stderr-tailer (see
    /// `crates/chump-orchestrator/src/dispatch.rs:766`) can grep for
    /// when deciding whether to respawn the dispatched child against
    /// the next routing-table candidate. Returns `None` for the
    /// `Other` variant so we don't spam stderr on every generic
    /// failure — the marker is a dedicated signal, not a log line.
    ///
    /// Format is intentionally stable (one greppable token at column 1
    /// followed by `:` and human-readable context) so future
    /// orchestrator-side parsers can rely on it.
    pub fn stderr_marker(self) -> Option<&'static str> {
        match self {
            Self::BillingExhausted => Some(
                "BILLING_EXHAUSTED: provider returned 402 / credit_limit class; \
                 orchestrator should respawn against next routing-table candidate \
                 (TOGETHER → GROQ → Claude). INFRA-302 blocker (1).",
            ),
            Self::TransportUnreachable => Some(
                "TRANSPORT_UNREACHABLE: local daemon is down or network path to \
                 OPENAI_API_BASE is broken (connection refused, error sending request, \
                 model HTTP unreachable, operation timed out, etc.); orchestrator \
                 should restart the daemon or respawn against a reachable provider \
                 slot. INFRA-347.",
            ),
            Self::Other => None,
        }
    }
}

/// INFRA-302 blocker (1) / INFRA-347: inspect an [`anyhow::Error`] from
/// [`execute_gap`] and classify it for exit-code mapping.
///
/// Walks the formatted error chain (using `format!("{err:#}")` so the
/// full Context-wrapped chain is visible) and matches against
/// [`crate::provider_cascade::is_billing_exhausted_error_string`] and
/// [`crate::provider_cascade::is_transport_unreachable_error_string`].
///
/// Priority: billing-exhausted is checked first (more specific signal for
/// the orchestrator); transport-unreachable second; everything else
/// falls through to `Other`.
///
/// Centralizing this on the formatted chain (not the typed `&Error`)
/// matches the existing INFRA-300 cascade predicate's contract —
/// HTTP-error-bearing strings carry the discriminator (`402`,
/// `credit_limit`, `connection refused`, ...) regardless of which
/// transport layer wrapped them, so a string-based check is correct AND
/// robust to the provider library swapping its concrete error type.
pub fn classify_execute_gap_error(err: &anyhow::Error) -> ExecuteGapErrorKind {
    let chain_str = format!("{err:#}");
    if crate::provider_cascade::is_billing_exhausted_error_string(&chain_str) {
        ExecuteGapErrorKind::BillingExhausted
    } else if crate::provider_cascade::is_transport_unreachable_error_string(&chain_str) {
        ExecuteGapErrorKind::TransportUnreachable
    } else {
        ExecuteGapErrorKind::Other
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    // INFRA-3445: free-tier locate-step routing (almanac grounding vs grep).
    #[test]
    fn locate_step_grounds_via_almanac_when_available() {
        let (step, rule) = free_tier_locate_step(true);
        assert!(
            step.contains("almanac_search") && step.starts_with("Step 1:"),
            "almanac-on: Step 1 must route to almanac_search, got: {step}"
        );
        assert!(
            rule.contains("almanac_search") && rule.contains("fall back to grep_repo"),
            "almanac-on: rule must steer to almanac with grep fallback, got: {rule}"
        );
    }

    #[test]
    fn locate_step_falls_back_to_grep_without_almanac() {
        let (step, rule) = free_tier_locate_step(false);
        assert!(
            step.contains("grep_repo") && !step.contains("almanac_search"),
            "almanac-off: Step 1 must be grep_repo only, got: {step}"
        );
        assert!(
            rule.contains("grep_repo") && !rule.contains("almanac_search"),
            "almanac-off: rule must be grep-only, got: {rule}"
        );
    }

    // INFRA-3459: the REPO MAP is targeted at wiring/architecture gaps only, so
    // narrow bug-fixes keep the lean weak-model prompt.
    #[test]
    fn gap_touches_wiring_matches_architecture_gaps() {
        assert!(gap_touches_wiring(
            "EFFECTIVE: fleet consumes comprehension — inject directive",
            "wire comprehend_repo into the tool profile"
        ));
        assert!(gap_touches_wiring(
            "add comprehend_repo to LIGHT_CHAT tool profile",
            ""
        ));
        assert!(gap_touches_wiring(
            "capability registered but in NO activation profile",
            ""
        ));
        assert!(gap_touches_wiring(
            "",
            "add a new pre-commit gate for CSS tokens"
        ));
    }

    #[test]
    fn gap_touches_wiring_skips_narrow_fixes() {
        assert!(!gap_touches_wiring(
            "fix typo in README",
            "correct the spelling"
        ));
        assert!(!gap_touches_wiring(
            "off-by-one in date parser",
            "the loop should stop at len, not len+1"
        ));
        // False-positive guard: words that merely CONTAIN a signal substring
        // must not trip it (leading-space signals).
        assert!(!gap_touches_wiring(
            "investigate slow query in dashboard",
            "mitigate the N+1 and delegate paging"
        ));
    }

    // INFRA-3459: the comprehend section is best-effort. Disabled path is
    // deterministic everywhere; the present path is exercised only on a host
    // that actually has the `comprehend` binary (CI won't — it must not fail there).
    #[test]
    #[serial]
    fn free_tier_comprehend_section_is_best_effort() {
        std::env::set_var("CHUMP_COMPREHEND_ENABLED", "0");
        assert_eq!(
            free_tier_comprehend_section(std::path::Path::new(".")),
            "",
            "disabled flag must yield an empty section (lean prompt unchanged)"
        );
        std::env::remove_var("CHUMP_COMPREHEND_ENABLED");

        if crate::comprehend_tool::comprehend_bin().is_some() {
            let root = crate::repo_path::main_checkout_root();
            let sect = free_tier_comprehend_section(&root);
            assert!(
                sect.contains("Repo map") && sect.contains("WIRING"),
                "on a host with the binary, a wiring gap's section carries the comprehend report; got: {sect:.120}"
            );
        }
    }

    // CREDIBLE-170 verify-gate verdict classification.
    #[test]
    fn verdict_pass_is_not_fail() {
        assert!(!verdict_is_fail(
            "PASS: correctly modifies the parser to check all paths"
        ));
        assert!(!verdict_is_fail("  pass: looks good  "));
        assert!(!verdict_is_fail(
            "The change looks correct and wires in properly. PASS"
        ));
    }

    #[test]
    fn verdict_fail_blocks_ship() {
        assert!(verdict_is_fail(
            "FAIL: adds a shadowed duplicate is_mirrored (dead code)"
        ));
        assert!(verdict_is_fail("  fail: this is a no-op  "));
        assert!(verdict_is_fail(
            "This diff never wires into the call path. FAIL"
        ));
    }

    #[test]
    fn verdict_empty_or_ambiguous_defaults_safe() {
        // Empty / non-committal reply is not a FAIL token, so it does not block
        // (the empty-diff guard and reviewer-call error handle the real gaps).
        assert!(!verdict_is_fail(""));
        assert!(!verdict_is_fail("PASS"));
    }

    #[test]
    fn prompt_contains_gap_id_and_ship_command() {
        let p = build_execute_gap_prompt("COG-025", std::path::Path::new("/nonexistent"));
        assert!(p.contains("COG-025"));
        assert!(p.contains("scripts/coord/bot-merge.sh --gap COG-025 --auto-merge"));
        assert!(p.contains("PR number"));
    }

    #[test]
    fn prompt_shape_with_rules_file() {
        // When rules file is present it is injected before the task instruction.
        // The orchestrator's COG-026 A/B measures model performance, not prompt
        // shape, so both backends may include the rules block.
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("process");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("CHUMP_DISPATCH_RULES.md"),
            "## rules\n- test rule\n",
        )
        .unwrap();
        let p = build_execute_gap_prompt("AUTO-013", dir.path());
        assert!(p.contains("AUTO-013"));
        assert!(p.contains("test rule"), "dispatch rules must be injected");
        assert!(p.contains("bot-merge.sh"));
    }

    #[test]
    fn validate_gap_id_accepts_canonical() {
        assert!(validate_gap_id("COG-025").is_ok());
        assert!(validate_gap_id("AUTO-013").is_ok());
        assert!(validate_gap_id("EVAL-031").is_ok());
    }

    #[test]
    fn validate_gap_id_accepts_double_hyphen_domains() {
        // INFRA-3404: split on the LAST hyphen, not the first.
        assert!(validate_gap_id("ZERO-WASTE-015").is_ok());
        assert!(validate_gap_id("ZERO-WASTE-1").is_ok());
    }

    #[test]
    fn validate_gap_id_accepts_uuid_forms() {
        // INFRA-630: full RFC-4122 UUID
        assert!(validate_gap_id("8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9").is_ok());
        assert!(validate_gap_id("00000000-0000-0000-0000-000000000000").is_ok());
        // INFRA-630: 8-char hex short-prefix (chump-proprietary display form)
        assert!(validate_gap_id("8d3f2c0e").is_ok());
        assert!(validate_gap_id("deadbeef").is_ok());
    }

    #[test]
    fn validate_gap_id_rejects_garbage() {
        assert!(validate_gap_id("").is_err());
        assert!(validate_gap_id("nodash").is_err());
        assert!(validate_gap_id("lowercase-001").is_err());
        assert!(validate_gap_id("COG-").is_err());
        assert!(validate_gap_id("-001").is_err());
        assert!(validate_gap_id("COG-abc").is_err());
    }

    #[test]
    fn validate_gap_id_rejects_recursion_in_prompt() {
        let p = build_execute_gap_prompt("COG-025", std::path::Path::new("/nonexistent"));
        assert!(
            !p.contains("--execute-gap"),
            "prompt accidentally tells agent to re-dispatch"
        );
    }

    /// COG-031 step 1: when OPENAI_MODEL matches a known non-Sonnet family,
    /// the model-shape overlay must be prepended. Uses `#[serial(openai_model_env)]`
    /// because both this test and `overlay_skipped_for_sonnet_baseline` mutate
    /// OPENAI_MODEL — without serialization they race and corrupt each other's
    /// env state under cargo's parallel test runner.
    #[test]
    #[serial(openai_model_env)]
    fn overlay_prepended_for_known_problem_model() {
        let prev = std::env::var("OPENAI_MODEL").ok();
        std::env::set_var("OPENAI_MODEL", "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8");

        let p = build_execute_gap_prompt("COG-031", std::path::Path::new("/nonexistent"));
        assert!(
            p.to_lowercase().contains("autonomous job"),
            "expected COG-031 model overlay to be prepended for Qwen-Coder"
        );
        assert!(
            p.to_lowercase().contains("would you like me to"),
            "Qwen-Coder overlay must call out the chatty-exit failure phrase"
        );
        // Original task content must still be present.
        assert!(p.contains("scripts/coord/bot-merge.sh --gap COG-031 --auto-merge"));

        // Restore env so we don't leak to other tests.
        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }

    #[test]
    #[serial(openai_model_env)]
    fn overlay_skipped_for_sonnet_baseline() {
        let prev = std::env::var("OPENAI_MODEL").ok();
        std::env::set_var("OPENAI_MODEL", "claude-sonnet-4-5-20250929");

        let p = build_execute_gap_prompt("COG-031", std::path::Path::new("/nonexistent"));
        assert!(
            !p.to_lowercase().contains("autonomous job"),
            "Sonnet baseline must not get an overlay (ships fine on bare prompt)"
        );
        assert!(p.contains("COG-031"));

        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // INFRA-302 blocker (1) — error classification at the
    // execute-gap exit boundary.
    // ──────────────────────────────────────────────────────────────────

    #[test]
    fn classify_billing_exhausted_real_dispatch_incident_string() {
        // Verbatim error from /tmp/dispatch-infra-247.log of the
        // 2026-05-02 dogfood run that motivated INFRA-302. The agent
        // loop wraps the provider error with `with_context("agent loop
        // failed for gap {gap_id}")`, so the formatted chain looks like:
        let raw = anyhow::anyhow!(
            "Local API error 402 Payment Required: {{\n  \"id\": \"ohYGX6i-2kFHot-9f5b21e0e8bcaf3a\",\n  \"error\": {{\n    \"message\": \"Credit limit exceeded, please [add credits](https://api.together.ai/settings/billing). If you've already made a payment, please wait up to 5 minutes for balances to update and try again.\",\n    \"type\": \"credit_limit\",\n    \"param\": null,\n    \"code\": null\n  }}\n}}"
        );
        let wrapped = raw.context("agent loop failed for gap INFRA-247");
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::BillingExhausted,
            "the exact 2026-05-02 incident string MUST classify as BillingExhausted — \
             this is the regression test for INFRA-302 blocker (1)"
        );
    }

    #[test]
    fn classify_billing_exit_code_is_75_ex_tempfail() {
        assert_eq!(
            ExecuteGapErrorKind::BillingExhausted.exit_code(),
            75,
            "75 = EX_TEMPFAIL per BSD sysexits.h; the orchestrator's \
             stderr-tailer pattern-matches on this to decide cascade-respawn"
        );
    }

    #[test]
    fn classify_other_exit_code_unchanged_at_1() {
        assert_eq!(
            ExecuteGapErrorKind::Other.exit_code(),
            1,
            "generic failures must keep exit code 1 — bot-merge.sh and \
             other shell-level callers expect that contract"
        );
    }

    #[test]
    fn classify_billing_emits_structured_stderr_marker() {
        let m = ExecuteGapErrorKind::BillingExhausted
            .stderr_marker()
            .expect("billing-exhausted must emit a marker");
        // Stable column-1 token the orchestrator's stderr-tailer can grep:
        assert!(
            m.starts_with("BILLING_EXHAUSTED:"),
            "marker must start with the stable token at column 1; got: {m:?}"
        );
        // Human-readable rationale must mention the cascade direction:
        assert!(m.contains("TOGETHER"));
        assert!(m.contains("GROQ"));
        assert!(m.contains("Claude"));
        assert!(m.contains("INFRA-302"));
    }

    #[test]
    fn classify_other_emits_no_marker() {
        assert!(
            ExecuteGapErrorKind::Other.stderr_marker().is_none(),
            "generic failures must NOT spam stderr with a marker — the marker is \
             a dedicated cascade-respawn signal, not a log line"
        );
    }

    #[test]
    fn classify_negative_cases_route_to_other() {
        // These must NOT be classified as BillingExhausted or TransportUnreachable.
        for s in [
            "agent loop failed for gap INFRA-247: max iterations (50) reached without an answer",
            "agent loop failed for gap INFRA-247: HTTP 500 Internal Server Error",
            "agent loop failed for gap INFRA-247: tool storm: 5 consecutive failed batches",
            "agent loop failed for gap INFRA-247: HTTP 400 Bad Request: missing field 'tools'",
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::Other,
                "{s:?} must route to Other (not billing-exhausted or transport-unreachable)"
            );
        }
    }

    #[test]
    fn classify_billing_positive_cases() {
        for s in [
            "Local API error 402 Payment Required",
            "openai/quota error: insufficient_quota",
            "Provider error: billing required",
            "CREDIT_LIMIT exceeded",
            "Payment Required",
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::BillingExhausted,
                "{s:?} must classify as BillingExhausted"
            );
        }
    }

    #[test]
    fn classify_walks_full_anyhow_context_chain() {
        // The agent loop's `result?` bubbles the provider error;
        // execute_gap wraps with `with_context("agent loop failed for
        // gap {gap_id}")`. The classifier must see the WRAPPED chain,
        // not just the top-level message — otherwise it'd miss every
        // real-world dispatched-child failure (the top-level is always
        // the with_context message; the discriminator is one layer
        // deeper).
        let inner = anyhow::anyhow!(
            "Local API error 402 Payment Required: {{\"error\": {{\"type\": \"credit_limit\"}}}}"
        );
        let wrapped = inner.context("agent loop failed for gap INFRA-247");
        // Sanity check: the top-level message alone does NOT contain "402".
        assert!(
            !wrapped.to_string().contains("402"),
            "preconditions for the test changed — top-level no longer hides 402"
        );
        // The classifier must still detect billing-exhausted via the chain.
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::BillingExhausted,
            "classifier must walk the full anyhow context chain, not just the top message"
        );
    }

    // ──────────────────────────────────────────────────────────────────
    // INFRA-347 — TransportUnreachable classification at the
    // execute-gap exit boundary.
    // ──────────────────────────────────────────────────────────────────

    #[test]
    fn classify_transport_real_dogfood_incident_string() {
        // Verbatim error from the 2026-05-02 dogfood repro (INFRA-347 /
        // INFRA-348). The agent loop wraps the provider error with
        // `with_context("agent loop failed for gap {gap_id}")`, so
        // the formatted chain is:
        let raw = anyhow::anyhow!(
            "error sending request for url (http://127.0.0.1:11434/v1/chat/completions) \
             — model HTTP unreachable (daemon down, crashed, or still starting). \
             Ollama: brew services start ollama (or restart); probe: curl -s \
             http://127.0.0.1:11434/api/tags."
        );
        let wrapped = raw.context("agent loop failed for gap INFRA-234");
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::TransportUnreachable,
            "exact 2026-05-02 dogfood repro string (Ollama down, INFRA-347) MUST classify \
             as TransportUnreachable — this is the regression test for INFRA-347"
        );
    }

    #[test]
    fn classify_transport_exit_code_is_76_ex_protocol() {
        assert_eq!(
            ExecuteGapErrorKind::TransportUnreachable.exit_code(),
            76,
            "76 = EX_PROTOCOL per BSD sysexits.h; orchestrator pattern-matches on this \
             to distinguish transport-unreachable (daemon down) from billing-exhausted (75) \
             and generic failures (1). INFRA-347."
        );
    }

    #[test]
    fn classify_transport_emits_structured_stderr_marker() {
        let m = ExecuteGapErrorKind::TransportUnreachable
            .stderr_marker()
            .expect("transport-unreachable must emit a marker");
        assert!(
            m.starts_with("TRANSPORT_UNREACHABLE:"),
            "marker must start with the stable column-1 token; got: {m:?}"
        );
        assert!(
            m.contains("INFRA-347"),
            "marker must cite INFRA-347 for traceability; got: {m:?}"
        );
    }

    #[test]
    fn classify_transport_positive_cases() {
        for (s, label) in [
            (
                "agent loop failed for gap INFRA-234: connection refused (os error 61)",
                "connection refused",
            ),
            (
                "agent loop failed for gap INFRA-234: error sending request for url (http://127.0.0.1:11434/v1/chat/completions)",
                "error sending request",
            ),
            (
                "agent loop failed for gap INFRA-234: model HTTP unreachable",
                "model HTTP unreachable",
            ),
            (
                "agent loop failed for gap INFRA-234: operation timed out connecting to 127.0.0.1:11434",
                "operation timed out",
            ),
            (
                "agent loop failed for gap INFRA-234: no route to host",
                "no route to host",
            ),
            (
                "agent loop failed for gap INFRA-234: name resolution failed for localhost",
                "name resolution failed",
            ),
            (
                "agent loop failed for gap INFRA-234: tcp connect error (os error 61)",
                "tcp connect error",
            ),
            (
                "agent loop failed for gap INFRA-234: model temporarily unavailable",
                "model temporarily unavailable",
            ),
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::TransportUnreachable,
                "{label:?} ({s:?}) must classify as TransportUnreachable — \
                 INFRA-347: before this fix these exited 1 (Other), \
                 indistinguishable from a tool storm"
            );
        }
    }

    #[test]
    fn classify_transport_does_not_overlap_billing() {
        // Billing-exhausted takes priority over transport in the classifier.
        // A string that matches BOTH (pathological but possible if a provider
        // embeds "connection refused" in a 402 body) classifies as billing
        // because that's the more actionable signal.
        let s = "Local API error 402 Payment Required: connection refused";
        let e = anyhow::anyhow!("{s}");
        assert_eq!(
            classify_execute_gap_error(&e),
            ExecuteGapErrorKind::BillingExhausted,
            "billing-exhausted should take priority over transport-unreachable \
             when both patterns match"
        );
    }

    #[test]
    fn classify_transport_context_chain_visible() {
        // Same as classify_walks_full_anyhow_context_chain but for transport.
        // The "connection refused" discriminator is inside the provider error;
        // the top-level is the with_context wrapper.
        let inner = anyhow::anyhow!("connection refused (os error 61)");
        let wrapped = inner.context("agent loop failed for gap INFRA-234");
        assert!(
            !wrapped.to_string().contains("connection refused"),
            "precondition: top-level Display must hide the inner message"
        );
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::TransportUnreachable,
            "classifier must walk the full chain to find 'connection refused' \
             even when it is wrapped by with_context"
        );
    }

    // ──────────────────────────────────────────────────────────────────
    // CREDIBLE-011 — free-tier dispatch integration tests
    // Mock OpenAI-compat server verifies the tool loop end-to-end.
    // ──────────────────────────────────────────────────────────────────

    fn restore_env_var(key: &str, val: Option<String>) {
        match val {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
    }

    #[test]
    #[serial(openai_model_env)]
    fn credible011_is_free_tier_model_true_for_groq_llama() {
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::set_var("OPENAI_MODEL", "llama-3.3-70b");
        std::env::set_var("OPENAI_API_BASE", "https://api.groq.com/openai/v1");
        // INFRA-3459: neutralise the free-tier flag env so this asserts ONLY the
        // model/base logic, immune to a leaked CHUMP_FREE_TIER_MODE/PROVIDERS
        // from a sibling test (the source of the parallel flake).
        let prev_ftmode = std::env::var("CHUMP_FREE_TIER_MODE").ok();
        let prev_ftprov = std::env::var("CHUMP_FREE_TIER_PROVIDERS").ok();
        std::env::remove_var("CHUMP_FREE_TIER_MODE");
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        let result = is_free_tier_model();
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("OPENAI_API_BASE", prev_base);
        restore_env_var("CHUMP_FREE_TIER_MODE", prev_ftmode);
        restore_env_var("CHUMP_FREE_TIER_PROVIDERS", prev_ftprov);
        assert!(
            result,
            "Groq endpoint + non-Claude model must detect as free-tier"
        );
    }

    #[test]
    #[serial(openai_model_env)]
    fn credible011_is_free_tier_model_false_for_claude_on_groq() {
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::set_var("OPENAI_MODEL", "claude-sonnet-4-5-20250929");
        std::env::set_var("OPENAI_API_BASE", "https://api.groq.com/openai/v1");
        // INFRA-3459: neutralise leaked free-tier flags (see sibling test).
        let prev_ftmode = std::env::var("CHUMP_FREE_TIER_MODE").ok();
        let prev_ftprov = std::env::var("CHUMP_FREE_TIER_PROVIDERS").ok();
        std::env::remove_var("CHUMP_FREE_TIER_MODE");
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        let result = is_free_tier_model();
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("OPENAI_API_BASE", prev_base);
        restore_env_var("CHUMP_FREE_TIER_MODE", prev_ftmode);
        restore_env_var("CHUMP_FREE_TIER_PROVIDERS", prev_ftprov);
        assert!(
            !result,
            "Claude model must never be classified as free-tier"
        );
    }

    #[test]
    #[serial(openai_model_env)]
    fn credible011_is_free_tier_model_false_for_llama_on_ollama() {
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::set_var("OPENAI_MODEL", "llama-3.3-70b");
        std::env::set_var("OPENAI_API_BASE", "http://localhost:11434/v1");
        // INFRA-3459: neutralise leaked free-tier flags (see sibling test).
        let prev_ftmode = std::env::var("CHUMP_FREE_TIER_MODE").ok();
        let prev_ftprov = std::env::var("CHUMP_FREE_TIER_PROVIDERS").ok();
        std::env::remove_var("CHUMP_FREE_TIER_MODE");
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        let result = is_free_tier_model();
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("OPENAI_API_BASE", prev_base);
        restore_env_var("CHUMP_FREE_TIER_MODE", prev_ftmode);
        restore_env_var("CHUMP_FREE_TIER_PROVIDERS", prev_ftprov);
        assert!(!result, "Local Ollama is not a free-tier cloud endpoint");
    }

    // ──────────────────────────────────────────────────────────────────
    // RESILIENT — CJ silent-bail root cause: a free-tier list with no keys
    // must NOT hijack a node that has a valid Anthropic sub credential.
    // ──────────────────────────────────────────────────────────────────

    /// Snapshot + clear every env var these tests touch, returning a restorer.
    fn snapshot_dispatch_env() -> Vec<(&'static str, Option<String>)> {
        let keys = [
            "CHUMP_FREE_TIER_PROVIDERS",
            "CHUMP_FREE_TIER_MODE",
            "OPENAI_API_KEY",
            "OPENAI_MODEL",
            "OPENAI_API_BASE",
            "GROQ_API_KEY",
            "OPENROUTER_API_KEY",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "ANTHROPIC_API_KEY",
        ];
        let snap: Vec<(&'static str, Option<String>)> =
            keys.iter().map(|k| (*k, std::env::var(k).ok())).collect();
        for k in keys {
            std::env::remove_var(k);
        }
        snap
    }

    fn restore_dispatch_env(snap: Vec<(&'static str, Option<String>)>) {
        for (k, v) in snap {
            restore_env_var(k, v);
        }
    }

    const TEST_FT_CASCADE: &str = "openai/gpt-oss-20b@https://api.groq.com/openai/v1:GROQ_API_KEY";

    #[test]
    #[serial(openai_model_env)]
    fn resilient_free_tier_no_key_with_sub_routes_to_sub() {
        let snap = snapshot_dispatch_env();
        // Free-tier list configured (as every node gets from the ladder
        // manifest), but NO provider key present, and a valid sub token IS.
        std::env::set_var("CHUMP_FREE_TIER_PROVIDERS", TEST_FT_CASCADE);
        std::env::set_var("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-test-token");
        let result = is_free_tier_model();
        restore_dispatch_env(snap);
        assert!(
            !result,
            "free-tier list with no key but a valid sub credential must route to the sub, \
             not keyless free-tier (CJ silent-bail root cause)"
        );
    }

    #[test]
    #[serial(openai_model_env)]
    fn resilient_free_tier_no_key_no_sub_stays_free_tier() {
        let snap = snapshot_dispatch_env();
        // No provider key AND no sub credential → stay free-tier so the
        // caller hits the explicit loud-fail guard (not a routing change).
        std::env::set_var("CHUMP_FREE_TIER_PROVIDERS", TEST_FT_CASCADE);
        let result = is_free_tier_model();
        restore_dispatch_env(snap);
        assert!(
            result,
            "with neither a provider key nor a sub credential, free-tier stays selected \
             so execute_gap can fail loud on the misconfiguration"
        );
    }

    #[test]
    #[serial(openai_model_env)]
    fn resilient_free_tier_with_key_stays_free_tier_even_with_sub() {
        let snap = snapshot_dispatch_env();
        // A real free-tier key present → an explicit operator free-tier
        // instruction still wins, even when a sub credential also exists.
        std::env::set_var("CHUMP_FREE_TIER_PROVIDERS", TEST_FT_CASCADE);
        std::env::set_var("GROQ_API_KEY", "gsk-test-key");
        std::env::set_var("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-test-token");
        let result = is_free_tier_model();
        restore_dispatch_env(snap);
        assert!(
            result,
            "a configured free-tier provider WITH a key must remain free-tier even when a \
             sub credential is also present"
        );
    }

    /// Integration test: mock OpenAI-compat server → native tool_call for
    /// read_file → tool executes → model replies "done" → loop terminates.
    /// Verifies the complete provider → tool-dispatch → reply cycle without
    /// a real model or any cloud dependency.
    #[tokio::test]
    #[serial]
    async fn credible011_free_tier_tool_loop_read_file_then_done() {
        use serde_json::json;
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let dir =
            std::env::temp_dir().join(format!("credible011_{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        std::fs::write(
            dir.join("hello.txt"),
            "hello from free-tier integration test\n",
        )
        .expect("write test file");

        let mock = MockServer::start().await;

        // Turn 1: native tool_call asking for read_file.
        // Priority 1 = highest precedence in wiremock (lower number = matched first).
        // up_to_n_times(1) exhausts this mock after the first request.
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [{
                            "id": "call_001",
                            "type": "function",
                            "function": {
                                "name": "read_file",
                                "arguments": "{\"path\": \"hello.txt\"}"
                            }
                        }]
                    },
                    "finish_reason": "tool_calls"
                }],
                "model": "llama-3.3-70b",
                "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}
            })))
            .up_to_n_times(1)
            .with_priority(1)
            .mount(&mock)
            .await;

        // Turn 2 (after tool result): model terminates with "done".
        // Priority 2 = lower precedence, acts as fallback once turn-1 is exhausted.
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": "done",
                        "tool_calls": null
                    },
                    "finish_reason": "stop"
                }],
                "model": "llama-3.3-70b",
                "usage": {"prompt_tokens": 150, "completion_tokens": 5, "total_tokens": 155}
            })))
            .with_priority(2)
            .mount(&mock)
            .await;

        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();

        std::env::set_var("OPENAI_API_BASE", mock.uri());
        std::env::set_var("OPENAI_MODEL", "llama-3.3-70b");
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::set_var("CHUMP_HOME", &dir);

        let agent = build_free_tier_agent().expect("build free-tier agent");
        let outcome = agent.run("Read hello.txt then reply done.").await;

        restore_env_var("OPENAI_API_BASE", prev_base);
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("CHUMP_REPO", prev_repo);
        restore_env_var("CHUMP_HOME", prev_home);
        let _ = std::fs::remove_dir_all(&dir);

        let reply = outcome.expect("agent run must not error").reply;
        assert!(
            reply.contains("done"),
            "expected final reply to contain 'done'; got: {reply:?}"
        );

        // Verify the mock received the post-tool follow-up call: at least 2 requests.
        let received = mock.received_requests().await.unwrap_or_default();
        assert!(
            received.len() >= 2,
            "expected ≥2 model calls (initial + after read_file result); got {}",
            received.len()
        );
    }

    // ── EFFECTIVE-002: provider rotation ──────────────────────────────────

    #[test]
    #[serial(free_tier_env)]
    fn effective445_parse_defaults_deepseek_primary() {
        // EFFECTIVE-445: the worker FLOOR default must be DeepSeek-primary
        // (funded OpenRouter paid rungs first), NOT free-first — free tiers 429
        // under sustained worker load and stall the floor.
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        let specs = parse_free_tier_providers();
        assert_eq!(specs.len(), 5, "default rotation must have 5 providers");
        assert_eq!(
            specs[0].model, "deepseek/deepseek-v4-flash",
            "slot 1 must be deepseek-v4-flash (the DeepSeek floor)"
        );
        assert_eq!(
            specs[1].model, "deepseek/deepseek-v4-pro",
            "slot 2 must be deepseek-v4-pro"
        );
        // RESILIENT-1002: Cerebras sits immediately behind DeepSeek so a
        // DeepSeek 402 (OpenRouter balance exhausted) falls to a provider
        // on a completely separate account, not another OpenRouter model.
        assert_eq!(
            specs[2].model, "qwen-3-235b-a22b-instruct-2507",
            "slot 3 must be Cerebras, directly behind the DeepSeek rungs"
        );
        assert_eq!(specs[2].base_url, "https://api.cerebras.ai/v1");
        assert_eq!(specs[2].api_key_env, "CEREBRAS_API_KEY");
        // Free tiers only AFTER DeepSeek — never ahead of it.
        assert!(
            specs[3].model.contains(":free"),
            "free tiers must sit behind the DeepSeek rungs"
        );
    }

    #[test]
    fn resilient1002_deepseek_402_cascades_toward_cerebras() {
        // AC1/AC3: a DeepSeek HTTP 402 must be classified as cascade-worthy
        // (so the rotation loop advances rather than aborting), and the
        // reason it classifies on is the billing-exhausted (402) class —
        // the same discriminator the fallback log line reports.
        let deepseek_402 = "Local API error 402 Payment Required: {\"error\":{\"message\":\"This request requires more credits, or fewer max_tokens.\",\"code\":402}}";
        assert!(
            crate::provider_cascade::should_cascade_on_error_string(deepseek_402),
            "DeepSeek 402 must be cascade-worthy so rotation falls to Cerebras"
        );
        assert!(
            crate::provider_cascade::is_billing_exhausted_error_string(deepseek_402),
            "DeepSeek 402 must classify as billing-exhausted (reason code 402)"
        );

        // AC2: Cerebras is reachable as the very next rung behind both
        // DeepSeek slots in the default rotation (see
        // effective445_parse_defaults_deepseek_primary for the full order).
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        let specs = parse_free_tier_providers();
        let deepseek_last_idx = specs
            .iter()
            .rposition(|s| s.model.starts_with("deepseek/"))
            .expect("default rotation must contain a deepseek slot");
        assert_eq!(
            specs[deepseek_last_idx + 1].base_url,
            "https://api.cerebras.ai/v1",
            "Cerebras must be the immediate fallback rung after DeepSeek exhausts"
        );
    }

    #[test]
    #[serial(free_tier_env)]
    fn effective002_parse_custom_env_overrides_defaults() {
        std::env::set_var(
            "CHUMP_FREE_TIER_PROVIDERS",
            "my-model@https://api.example.com/v1:MY_KEY",
        );
        let specs = parse_free_tier_providers();
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].model, "my-model");
        assert_eq!(specs[0].base_url, "https://api.example.com/v1");
        assert_eq!(specs[0].api_key_env, "MY_KEY");
    }

    #[test]
    #[serial(free_tier_env)]
    fn effective002_parse_skips_malformed_entries() {
        std::env::set_var(
            "CHUMP_FREE_TIER_PROVIDERS",
            // Second entry is malformed (no '@'), third is good
            "good-model@https://api.example.com/v1:KEY,bad-entry,other@https://b.com/v1:K2",
        );
        let specs = parse_free_tier_providers();
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        assert_eq!(specs.len(), 2, "malformed entry must be silently skipped");
        assert_eq!(specs[0].model, "good-model");
        assert_eq!(specs[1].model, "other");
    }

    #[test]
    #[serial(openai_model_env)]
    fn effective002_activate_sets_env_vars() {
        let orig_base = std::env::var("OPENAI_API_BASE").ok();
        let orig_model = std::env::var("OPENAI_MODEL").ok();
        let orig_key = std::env::var("OPENAI_API_KEY").ok();
        // INFRA-3459: activate_free_tier_provider ALSO sets the process-global
        // CHUMP_FREE_TIER_MODE=1. Capturing + restoring it here fixes a parallel
        // test race: without this, MODE=1 leaked for the rest of the process and
        // any later is_free_tier_model() test (e.g. credible011_*_llama_on_ollama)
        // saw free-tier=true regardless of its model, failing intermittently
        // depending on scheduler order.
        let orig_mode = std::env::var("CHUMP_FREE_TIER_MODE").ok();

        std::env::set_var("MY_TEST_KEY_002", "sk-test-token");
        let spec = FreeTierProviderSpec {
            model: "llama-test".to_string(),
            base_url: "https://api.test.com/v1".to_string(),
            api_key_env: "MY_TEST_KEY_002".to_string(),
        };
        activate_free_tier_provider(&spec);

        assert_eq!(
            std::env::var("OPENAI_API_BASE").unwrap(),
            "https://api.test.com/v1"
        );
        assert_eq!(std::env::var("OPENAI_MODEL").unwrap(), "llama-test");
        assert_eq!(std::env::var("OPENAI_API_KEY").unwrap(), "sk-test-token");

        // Restore
        restore_env_var("OPENAI_API_BASE", orig_base);
        restore_env_var("OPENAI_MODEL", orig_model);
        restore_env_var("OPENAI_API_KEY", orig_key);
        restore_env_var("CHUMP_FREE_TIER_MODE", orig_mode);
        std::env::remove_var("MY_TEST_KEY_002");
    }
}
