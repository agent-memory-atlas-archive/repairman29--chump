//! COG-031 step 1: static model-shape prompt overlays for dispatched
//! `chump --execute-gap` runs.
//!
//! INFRA-739: `detect_model_family()` now checks `docs/dispatch/model_registry.yaml`
//! first (via a `OnceLock<HashMap<String, ModelFamily>>` cache), then falls back to
//! the existing substring logic for unregistered models.
//!
//! ## Why
//!
//! COG-026 V2-V5 trials proved that Together's Instruct-family models
//! (Qwen3-235B chat, Llama-3.3-70B chat, Qwen3-Coder-480B coder) all default
//! to *conversational* behavior on Chump's gap-execution prompt. Three
//! distinct failure modes — chat models iter-cap on read loops, coder model
//! exits early with "Would you like me to focus on a specific domain?" —
//! one shared root cause: the prompt is implicitly Sonnet-tuned and other
//! Instruct models honor the contract differently.
//!
//! Step 1 of the COG-031 autotuner is the cheapest possible intervention:
//! detect the model family from `OPENAI_MODEL` and prepend a short overlay
//! that explicitly addresses both observed failure modes (over-exploration
//! and chatty meta-exit). This is *not* the full per-iteration runtime
//! detector specified in the COG-031 acceptance criteria — that's step 2
//! once we have empirical signal that overlays move the ship rate. Step 1
//! ships a static overlay so we can A/B-test "vanilla prompt vs overlay"
//! on the same Together model and decide whether the autotuner thesis
//! deserves the larger investment.
//!
//! ## What's included
//!
//! * [`ModelFamily`] — coarse classification by `OPENAI_MODEL` substring.
//! * [`detect_model_family`] — string → family.
//! * [`overlay_for_family`] — returns `Some(static_str)` overlay or `None`
//!   for Sonnet (which already converges on the bare prompt).
//! * [`maybe_overlay_from_env`] — convenience: read `OPENAI_MODEL` env and
//!   return the appropriate overlay or `None`.
//!
//! Overlays are intentionally short (~5 lines each) so they don't dominate
//! the prompt or change the underlying task. They target the specific
//! observed failure shapes from the COG-026 traces.

use serde::Deserialize;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Coarse model-family classification driven by `OPENAI_MODEL` substring
/// matching. Used by the dispatched-gap prompt builder to choose a per-family
/// overlay. `Other` and `Sonnet` both get no overlay (Sonnet ships fine on
/// the bare prompt; Other is the "we don't have enough signal yet" bucket).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelFamily {
    /// Anthropic Sonnet (any version). Baseline — ships on the bare prompt;
    /// no overlay applied.
    Sonnet,
    /// Anthropic Haiku/Opus or other Claude variant. Same overlay decision
    /// as Sonnet for now; tracked as a separate variant for future per-model
    /// tuning.
    OtherClaude,
    /// Qwen family chat-Instruct (Qwen3-235B etc). COG-026 V2/V3 failure:
    /// iter-cap on depth-first read loop.
    QwenChat,
    /// Qwen family Coder-Instruct (Qwen3-Coder-480B). COG-026 V5 failure:
    /// chatty "Would you like me to..." exit.
    QwenCoder,
    /// Meta Llama Instruct (Llama-3.3-70B etc). COG-026 V4 failure: same
    /// as QwenChat (read-loop iter-cap).
    LlamaInstruct,
    /// DeepSeek family (V3/R1/etc). Untested as of COG-026; speculative
    /// overlay applied based on family-similarity heuristic.
    DeepSeek,
    /// Unrecognized model — no overlay applied. Caller should NOT assume
    /// safe defaults; this is an explicit "we don't know yet" signal.
    Other,
}

// ── INFRA-739: registry-backed family lookup ───────────────────────────────

/// Minimal deserialize target for the `family` field in model_registry.yaml.
#[derive(Debug, Deserialize)]
struct RegistryFamilyEntry {
    model_id: String,
    family: String,
}

#[derive(Debug, Deserialize)]
struct FamilyRegistry {
    models: Vec<RegistryFamilyEntry>,
}

fn family_str_to_enum(s: &str) -> Option<ModelFamily> {
    match s {
        "Sonnet" => Some(ModelFamily::Sonnet),
        "Haiku" | "Opus" | "OtherClaude" => Some(ModelFamily::OtherClaude),
        "QwenChat" => Some(ModelFamily::QwenChat),
        "QwenCoder" => Some(ModelFamily::QwenCoder),
        "LlamaInstruct" => Some(ModelFamily::LlamaInstruct),
        "DeepSeek" => Some(ModelFamily::DeepSeek),
        "Other" => Some(ModelFamily::Other),
        _ => None,
    }
}

/// Cached map of model_id → [`ModelFamily`] loaded from
/// `docs/dispatch/model_registry.yaml`. Empty on load failure — callers fall
/// back to substring logic automatically. Loaded once via [`OnceLock`].
fn registry_family_map() -> &'static HashMap<String, ModelFamily> {
    static CACHE: OnceLock<HashMap<String, ModelFamily>> = OnceLock::new();
    CACHE.get_or_init(|| {
        let candidates = [
            std::env::var("CHUMP_REPO_ROOT")
                .map(|r| format!("{}/docs/dispatch/model_registry.yaml", r))
                .ok(),
            Some(format!(
                "{}/docs/dispatch/model_registry.yaml",
                env!("CARGO_MANIFEST_DIR")
            )),
        ];
        for candidate in candidates.iter().flatten() {
            if let Ok(text) = std::fs::read_to_string(candidate) {
                match serde_yaml::from_str::<FamilyRegistry>(&text) {
                    Ok(reg) => {
                        return reg
                            .models
                            .into_iter()
                            .filter_map(|e| {
                                let fam = family_str_to_enum(&e.family)?;
                                Some((e.model_id, fam))
                            })
                            .collect();
                    }
                    Err(err) => {
                        tracing::warn!(
                            path = %candidate,
                            error = %err,
                            "INFRA-739: failed to parse model_registry.yaml family map"
                        );
                    }
                }
            }
        }
        HashMap::new()
    })
}

// ──────────────────────────────────────────────────────────────────────────────

/// Detect [`ModelFamily`] from a model ID string (typically the value of
/// `OPENAI_MODEL`). INFRA-739: checks `docs/dispatch/model_registry.yaml`
/// first (exact match), then falls back to case-insensitive substring matching
/// for unregistered models. Order-of-checks favors specificity (e.g. `Coder`
/// must be checked before bare `Qwen` so Qwen3-Coder routes to QwenCoder
/// and not QwenChat).
pub fn detect_model_family(model_id: &str) -> ModelFamily {
    // Registry-first: exact match on model_id.
    let map = registry_family_map();
    if let Some(&fam) = map.get(model_id) {
        return fam;
    }

    // Fallback: legacy substring logic for models not in the registry.
    let m = model_id.to_lowercase();

    // Anthropic — Sonnet first (most common baseline); other Claude bucket
    // covers Haiku/Opus/etc.
    if m.contains("sonnet") {
        return ModelFamily::Sonnet;
    }
    if m.contains("claude") || m.contains("haiku") || m.contains("opus") {
        return ModelFamily::OtherClaude;
    }

    // Qwen — coder variants must be checked BEFORE the generic Qwen branch
    // so "qwen3-coder-480b" doesn't accidentally route to QwenChat.
    if m.contains("coder") && m.contains("qwen") {
        return ModelFamily::QwenCoder;
    }
    if m.contains("qwen") {
        return ModelFamily::QwenChat;
    }

    // Llama Instruct — anything with "llama" + "instruct" in the name.
    // Covers Llama-3.3-70B-Instruct, Llama-3.1-8B-Instruct, etc.
    if m.contains("llama") && m.contains("instruct") {
        return ModelFamily::LlamaInstruct;
    }

    // DeepSeek family — V3, V3.1, R1, distill variants, etc.
    if m.contains("deepseek") {
        return ModelFamily::DeepSeek;
    }

    ModelFamily::Other
}

/// COG-031 step 2: a one-shot exemplar trace appended to every non-Sonnet
/// overlay. Step 1 (V6/V7) proved that instructional preamble alone cannot
/// outweigh Together-served Instruct models' chat-RLHF prior — the model
/// reads the directive and produces a chat-bot reply anyway. Step 2 follows
/// known LLM behavior research: in-context demonstrations weight more
/// strongly than instructional preamble for instruct-tuned LLMs. Show the
/// model what a successful agent loop *looks like* and let pattern-matching
/// do the work.
///
/// The exemplar is compact (≈25 lines, ≈400 tokens) and synthesizes a real
/// shipped PR (COMP-014, PR #183) into the canonical Chump tool-use shape:
/// read_file → patch_file → chump-commit.sh → bot-merge.sh → terminal PR#.
const FEW_SHOT_EXEMPLAR: &str = "\
\n\
## EXAMPLE — what a successful run looks like\n\
\n\
For gap COMP-014 (cost ledger $0.00 bug), a successful agent run produced \
exactly this trace (tool calls only, no commentary):\n\
\n\
```\n\
iter 1: read_file docs/gaps.yaml                  — find COMP-014 acceptance criteria\n\
iter 2: read_file src/cost_tracker.rs             — locate the bug\n\
iter 3: read_file src/cost_tracker.rs lines 130-160  — confirm fix site\n\
iter 4: patch_file src/cost_tracker.rs            — apply the fix\n\
iter 5: run_cli cargo check --bin chump --tests   — verify it compiles\n\
iter 6: run_cli scripts/coord/chump-commit.sh src/cost_tracker.rs -m \"fix(COMP-014): ...\"\n\
iter 7: run_cli scripts/coord/bot-merge.sh --gap COMP-014 --auto-merge\n\
final reply: PR #183\n\
```\n\
\n\
Notice what the successful run did NOT do: no \"What should I call you?\", \
no \"Would you like me to focus on a specific area?\", no preamble explaining \
the project structure. Read enough to find the bug, fix it, ship, exit. \
Total iterations: 7. Total reply text: 7 characters.\n\
\n\
## SHIP RULE — CRITICAL\n\
\n\
The MOMENT you have made any commit (any successful chump-commit.sh / git \
commit call), your VERY NEXT tool call MUST be:\n\
\n\
```\n\
run_cli scripts/coord/bot-merge.sh --gap <YOUR-GAP-ID> --auto-merge\n\
```\n\
\n\
No exceptions. Not \"verify the commit landed\" first. Not \"check if there's \
more to do.\" Not \"summarize what I did.\" The next action after any commit \
is bot-merge.sh — anything else is wasted budget that may exhaust your \
iteration cap before you ship. Commits that are not pushed via bot-merge.sh \
are invisible to the orchestrator and the run is marked failed.\n\
\n\
## RECOVERY — if the gap is already satisfied on main\n\
\n\
If after reading the target file and running the acceptance check you verify \
the work is ALREADY implemented on main, do NOT fabricate a cosmetic or \
documentation commit (phantom commits are rejected by the ship gate). \
Instead, reply with `GAP_ALREADY_SATISFIED: <file:line proof>` (or \
`BLOCKED: <file:line + reason>` if a concrete blocker prevents the fix) and \
exit immediately. Do NOT ask the user to clarify.\n\
\n\
Now do the same for your gap.\n\
\n";

/// Per-family static overlay. Returns `None` when no overlay should be
/// prepended (Sonnet, OtherClaude, Other). Overlays are intentionally short
/// so they don't crowd out the gap-acceptance content; each one targets a
/// specific failure mode observed in the COG-026 traces.
///
/// COG-031 step 2: every non-Sonnet overlay now ends with [`FEW_SHOT_EXEMPLAR`]
/// — an in-context demonstration of a successful Sonnet trace. Returns a
/// `String` (instead of `&'static str`) so the exemplar can be concatenated
/// at runtime; the per-family directive itself is still a static slice.
pub fn overlay_for_family(family: ModelFamily) -> Option<String> {
    let directive = overlay_directive_for_family(family)?;
    Some(format!("{directive}{FEW_SHOT_EXEMPLAR}"))
}

/// Step-1 per-family directive only — the instructional preamble without
/// the few-shot exemplar. Exposed publicly for COG-031 step 3c (EFFECTIVE-1932)
/// so callers can inject the autonomous-job directive into the system prompt
/// while keeping the few-shot exemplar in the user message.
pub fn overlay_directive_for_family(family: ModelFamily) -> Option<&'static str> {
    match family {
        ModelFamily::Sonnet | ModelFamily::OtherClaude => None,
        ModelFamily::Other => None,

        // Chat-Instruct families — observed failure: depth-first
        // exploration loop (V2/V3/V4 in COG-026). Overlay forces a
        // first-action deadline.
        ModelFamily::QwenChat | ModelFamily::LlamaInstruct => Some(
            "## OPERATING MODE: AUTONOMOUS JOB, NOT CHAT\n\
             You are running unattended inside chump-orchestrator. There is no human in this loop \
             to answer questions. Your sole success criterion is shipping a PR via \
             scripts/coord/bot-merge.sh.\n\
             \n\
             FIRST-ACTION DEADLINE: by iteration 5 you MUST have issued at least one patch_file, \
             write_file, or scripts/coord/chump-commit.sh call. Reading more files past iteration 5 \
             without writing is wasted budget. If after 5 reads you don't yet know the exact \
             patch, write a 1-line plan to /tmp/chump-plan.md as your first action, then \
             proceed. Do not stall in exploration.\n\
             \n",
        ),

        // Qwen-Coder — observed failure: clean exit with chatty "Would you
        // like me to..." meta-summary (V5 in COG-026). Overlay explicitly
        // bans interactive question-asking and demands ship-or-explicit-blocker.
        ModelFamily::QwenCoder => Some(
            "## OPERATING MODE: AUTONOMOUS JOB, NOT CHAT\n\
             You are running unattended inside chump-orchestrator. There is no user in this \
             session to answer questions. Your sole success criterion is shipping a PR via \
             scripts/coord/bot-merge.sh.\n\
             \n\
             DO NOT END YOUR RESPONSE WITH A QUESTION. Phrases like \"Would you like me \
             to...\", \"Should I...\", \"Do you want me to focus on...\" are forbidden — they \
             will never be answered and the run will be marked failed. Acceptable terminal \
             states: (a) you shipped the PR and reply with the PR number, or (b) you hit a \
             concrete blocker and report it explicitly with the file/line/error that stopped \
             you. Silence-and-stop counts as failure.\n\
             \n",
        ),

        // DeepSeek — speculative overlay, identical to chat-Instruct family
        // until we have empirical V6+ data to differentiate. Same failure
        // mode is plausible (instruction-following defaults to thorough chat).
        ModelFamily::DeepSeek => Some(
            "## OPERATING MODE: AUTONOMOUS JOB, NOT CHAT\n\
             You are running unattended inside chump-orchestrator. There is no human in this \
             loop. Ship a PR via scripts/coord/bot-merge.sh — that is the only success state.\n\
             \n\
             First action (patch_file / write_file / chump-commit.sh) by iteration 5. Do not \
             ask clarifying questions; either act or report a concrete blocker.\n\
             \n",
        ),
    }
}

/// Convenience: read `OPENAI_MODEL` from the environment and return the
/// appropriate overlay, or `None` when the env is unset / the model is
/// recognized as not needing one (Sonnet) / unrecognized.
///
/// Returns `Option<String>` rather than `Option<&'static str>` because the
/// step-2 overlay concatenates the static directive with the [`FEW_SHOT_EXEMPLAR`]
/// at runtime. The per-family directive itself is still a static slice — see
/// [`overlay_directive_for_family`].
///
/// Caller pattern in `build_execute_gap_prompt`:
/// ```ignore
/// let overlay = maybe_overlay_from_env().unwrap_or_default();
/// format!("{overlay}{rules_block}{task}")
/// ```
pub fn maybe_overlay_from_env() -> Option<String> {
    let model = std::env::var("OPENAI_MODEL").ok()?;
    overlay_for_family(detect_model_family(&model))
}

/// COG-031 step 3c (EFFECTIVE-1932): return the per-family behavioral directive
/// (`OPERATING MODE: AUTONOMOUS JOB, NOT CHAT`) for injection into the agent's
/// system prompt when `OPENAI_MODEL` matches a non-Sonnet problem family.
///
/// Pairing this with [`maybe_overlay_from_env`] in the user message ensures
/// open-weight models weight the autonomous-job contract across both system and
/// user channels instead of letting chat-RLHF priors override a user-only preamble.
pub fn maybe_system_directive_from_env() -> Option<String> {
    let model = std::env::var("OPENAI_MODEL").ok()?;
    overlay_directive_for_family(detect_model_family(&model)).map(str::to_string)
}

/// INFRA-741: return a human-readable capability summary for `model` using the
/// probe cache. Returns `None` if no cached probe exists for the model+base combo.
///
/// Used by `chump doctor` to report detected capabilities without blocking on a
/// live probe (doctor should be fast and non-destructive).
pub fn cached_capability_summary(model: &str, base_url: &str) -> Option<String> {
    let probe = crate::model_probe::get_cached(model, base_url)?;
    let tool = if probe.has_tool_use {
        "tool-use=yes"
    } else {
        "tool-use=no"
    };
    let think = if probe.has_think_tags {
        "think-tags=yes"
    } else {
        "think-tags=no"
    };
    let ctx = probe
        .context_window
        .map(|n| format!("ctx={}k", n / 1024))
        .unwrap_or_else(|| "ctx=unknown".to_string());
    Some(format!(
        "{} {} {} (probed {})",
        tool, think, ctx, probe.probed_at
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn detects_sonnet() {
        assert_eq!(
            detect_model_family("claude-sonnet-4-5-20250929"),
            ModelFamily::Sonnet
        );
        assert_eq!(
            detect_model_family("anthropic/claude-3-5-sonnet-latest"),
            ModelFamily::Sonnet
        );
    }

    #[test]
    fn detects_other_claude() {
        assert_eq!(
            detect_model_family("claude-haiku-4-5"),
            ModelFamily::OtherClaude
        );
        assert_eq!(
            detect_model_family("claude-opus-4"),
            ModelFamily::OtherClaude
        );
    }

    #[test]
    fn detects_qwen_chat_vs_coder() {
        // Generic Qwen3 chat
        assert_eq!(
            detect_model_family("Qwen/Qwen3-235B-A22B-Instruct-2507-tput"),
            ModelFamily::QwenChat
        );
        // Coder variant must take precedence
        assert_eq!(
            detect_model_family("Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8"),
            ModelFamily::QwenCoder
        );
        assert_eq!(
            detect_model_family("Qwen/Qwen2.5-Coder-32B-Instruct"),
            ModelFamily::QwenCoder
        );
    }

    #[test]
    fn detects_llama_instruct() {
        assert_eq!(
            detect_model_family("meta-llama/Llama-3.3-70B-Instruct-Turbo"),
            ModelFamily::LlamaInstruct
        );
        assert_eq!(
            detect_model_family("meta-llama/Llama-3.1-8B-Instruct"),
            ModelFamily::LlamaInstruct
        );
    }

    #[test]
    fn detects_deepseek() {
        assert_eq!(
            detect_model_family("deepseek-ai/DeepSeek-V3"),
            ModelFamily::DeepSeek
        );
        assert_eq!(
            detect_model_family("deepseek-ai/DeepSeek-R1"),
            ModelFamily::DeepSeek
        );
    }

    #[test]
    fn unknown_models_route_to_other() {
        assert_eq!(detect_model_family("gpt-4o"), ModelFamily::Other);
        assert_eq!(detect_model_family(""), ModelFamily::Other);
        assert_eq!(detect_model_family("mistral-large"), ModelFamily::Other);
    }

    #[test]
    fn overlay_skipped_for_sonnet_and_unknown() {
        assert!(overlay_for_family(ModelFamily::Sonnet).is_none());
        assert!(overlay_for_family(ModelFamily::OtherClaude).is_none());
        assert!(overlay_for_family(ModelFamily::Other).is_none());
    }

    #[test]
    fn overlay_present_for_known_problem_families() {
        for f in [
            ModelFamily::QwenChat,
            ModelFamily::QwenCoder,
            ModelFamily::LlamaInstruct,
            ModelFamily::DeepSeek,
        ] {
            let o = overlay_for_family(f).unwrap_or_default();
            assert!(
                o.contains("AUTONOMOUS JOB"),
                "{f:?} overlay should mark autonomous mode"
            );
            assert!(
                o.contains("bot-merge.sh"),
                "{f:?} overlay should reference ship pipeline"
            );
        }
    }

    #[test]
    fn chat_overlay_contains_first_action_deadline() {
        // QwenChat + LlamaInstruct: failure mode is read-loop, so overlay
        // must address it explicitly.
        for f in [ModelFamily::QwenChat, ModelFamily::LlamaInstruct] {
            let o = overlay_for_family(f).unwrap();
            assert!(
                o.to_lowercase().contains("iteration 5"),
                "{f:?} chat-overlay should set first-action deadline"
            );
        }
    }

    #[test]
    fn coder_overlay_bans_chatty_exit() {
        // QwenCoder failure mode is chatty "Would you like me to..." exit.
        let o = overlay_for_family(ModelFamily::QwenCoder).unwrap();
        assert!(
            o.to_lowercase().contains("would you like me to"),
            "QwenCoder overlay must explicitly call out the failure phrase"
        );
    }

    /// COG-031 step 2: every non-Sonnet overlay must include the few-shot
    /// exemplar trace. This is the in-context demonstration that V6/V7 proved
    /// missing — directives alone don't outweigh chat-RLHF prior; showing
    /// what success looks like *might*.
    #[test]
    fn step2_few_shot_exemplar_appended_for_problem_families() {
        for f in [
            ModelFamily::QwenChat,
            ModelFamily::QwenCoder,
            ModelFamily::LlamaInstruct,
            ModelFamily::DeepSeek,
        ] {
            let o = overlay_for_family(f).unwrap_or_default();
            assert!(
                o.contains("EXAMPLE — what a successful run looks like"),
                "{f:?} overlay missing step-2 few-shot exemplar header"
            );
            assert!(
                o.contains("PR #183"),
                "{f:?} overlay missing concrete terminal-state demonstration"
            );
            assert!(
                o.contains("iter 1: read_file"),
                "{f:?} overlay missing trace shape demonstration"
            );
        }
    }

    /// COG-031 step 3a: V8 made commits but never reached bot-merge.sh.
    /// The exemplar now includes an explicit SHIP RULE forcing bot-merge as
    /// the next call after ANY commit. Verify it's present in every problem-
    /// family overlay so the directive isn't accidentally dropped.
    #[test]
    fn step3a_ship_rule_present_for_problem_families() {
        for f in [
            ModelFamily::QwenChat,
            ModelFamily::QwenCoder,
            ModelFamily::LlamaInstruct,
            ModelFamily::DeepSeek,
        ] {
            let o = overlay_for_family(f).unwrap_or_default();
            assert!(
                o.contains("SHIP RULE — CRITICAL"),
                "{f:?} overlay missing step-3a SHIP RULE section"
            );
            assert!(
                o.contains("VERY NEXT tool call MUST be"),
                "{f:?} overlay must explicitly mandate bot-merge as next call after commit"
            );
            assert!(
                o.contains("GAP_ALREADY_SATISFIED")
                    && o.contains("do NOT fabricate a cosmetic or documentation commit"),
                "{f:?} overlay must require honest GAP_ALREADY_SATISFIED exit instead of phantom commits"
            );
        }
    }

    /// CREDIBLE-1605: verify the RECOVERY block never instructs models to
    /// fabricate documentation commits when a gap is already satisfied on main.
    #[test]
    fn credible_1605_recovery_bans_phantom_doc_commits_and_requires_honest_exit() {
        for f in [
            ModelFamily::QwenChat,
            ModelFamily::QwenCoder,
            ModelFamily::LlamaInstruct,
            ModelFamily::DeepSeek,
        ] {
            let o = overlay_for_family(f).unwrap_or_default();
            assert!(
                !o.contains("write the documentation file as your patch_file action"),
                "{f:?} overlay must not instruct model to fabricate doc files"
            );
            assert!(
                o.contains("GAP_ALREADY_SATISFIED"),
                "{f:?} overlay must instruct model to emit GAP_ALREADY_SATISFIED"
            );
        }
    }

    /// EFFECTIVE-1932 (COG-031 step 3c): verify system-directive helper returns
    /// the behavioral framing without duplicating the few-shot exemplar.
    #[test]
    #[serial(openai_model_env)]
    fn effective_1932_system_directive_from_env_splits_framing_from_exemplar() {
        let prev = std::env::var("OPENAI_MODEL").ok();

        std::env::set_var("OPENAI_MODEL", "deepseek-ai/DeepSeek-V3");
        let sys = maybe_system_directive_from_env().expect("deepseek should get system directive");
        assert!(sys.contains("OPERATING MODE: AUTONOMOUS JOB, NOT CHAT"));
        assert!(
            !sys.contains("EXAMPLE — what a successful run looks like"),
            "system directive must stay concise and exclude the user-turn exemplar"
        );

        std::env::set_var("OPENAI_MODEL", "claude-sonnet-4-5-20250929");
        assert!(maybe_system_directive_from_env().is_none());

        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }

    #[test]
    fn step2_exemplar_skipped_for_sonnet() {
        // Sonnet ships fine on the bare prompt; no overlay → no exemplar
        // overhead either.
        assert!(overlay_for_family(ModelFamily::Sonnet).is_none());
    }

    #[test]
    #[serial(openai_model_env)]
    fn maybe_overlay_from_env_respects_env() {
        // Use a unique env var per test invocation to avoid contaminating
        // other parallel tests reading OPENAI_MODEL. We set + read + restore.
        let prev = std::env::var("OPENAI_MODEL").ok();

        std::env::set_var("OPENAI_MODEL", "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8");
        let o = maybe_overlay_from_env().unwrap_or_default();
        assert!(o.to_lowercase().contains("would you like me to"));
        // Step 2 verification: the env-driven path also gets the exemplar.
        assert!(o.contains("PR #183"));

        std::env::set_var("OPENAI_MODEL", "claude-sonnet-4-5-20250929");
        assert!(maybe_overlay_from_env().is_none());

        std::env::remove_var("OPENAI_MODEL");
        assert!(maybe_overlay_from_env().is_none());

        // Restore prior env so we don't pollute other tests in the binary.
        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }
}
