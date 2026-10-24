use crate::perception::PerceivedInput;
use crate::reflection_db;
use crate::task_db;
use std::sync::Once;

// INFRA-424: visibility for spawn-time lessons injection. Without this,
// CHUMP_LESSONS_AT_SPAWN_N can sit in a shell profile or .env and silently
// add N×~500 input tokens to every spawn. The first time per process we
// see N>0, log to ambient.jsonl + (when N>5 without ack) warn to stderr.
static LESSONS_VISIBILITY_ONCE: Once = Once::new();

fn announce_lessons_injection_active(n: usize) {
    LESSONS_VISIBILITY_ONCE.call_once(|| {
        // Stderr warning if N>5 without explicit ack.
        if n > 5 && std::env::var("CHUMP_LESSONS_AT_SPAWN_ACK").as_deref() != Ok("1") {
            eprintln!(
                "[chump] WARNING: CHUMP_LESSONS_AT_SPAWN_N={n} adds ~{}K input tokens per spawn. \
                 Set CHUMP_LESSONS_AT_SPAWN_ACK=1 to silence; set CHUMP_LESSONS_AT_SPAWN_N=0 to disable.",
                n / 2
            );
        }

        // Best-effort ambient.jsonl append. Resolve repo root via env or cwd;
        // skip silently on any io error so this never breaks a real spawn.
        let repo_root = std::env::var("CHUMP_REPO_ROOT")
            .ok()
            .or_else(|| std::env::current_dir().ok().and_then(|p| p.to_str().map(String::from)))
            .unwrap_or_else(|| ".".to_string());
        let path = std::env::var("CHUMP_AMBIENT_LOG")
            .unwrap_or_else(|_| format!("{repo_root}/.chump-locks/ambient.jsonl"));
        let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let line = format!(
            r#"{{"event":"alert","kind":"lessons_injection_active","ts":"{ts}","n":{n}}}"#,
        );
        if let Some(parent) = std::path::Path::new(&path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        {
            use std::io::Write;
            let _ = writeln!(f, "{line}");
        }
    });
}

// ---------------------------------------------------------------------------
// COG-027: Task-class-aware perception clarification directive gate
// ---------------------------------------------------------------------------
//
// EVAL-029 established that the "ask one clarifying question" directive harms
// conditional-chain (procedural) tasks. EVAL-030 gated that directive in the
// lessons block. COG-027 extends the same gate to the perception context
// summary, which independently emits "Ambiguity: X.X (consider clarifying)"
// when ambiguity_level > 0.6.
//
// On procedural tasks — identified by the same `is_conditional_chain`
// heuristic — the clarification nudge triggers early-stopping mid-chain just
// as the lessons-block directive did. This gate strips that fragment from the
// perception context string before it is injected into the system prompt.
//
// Default: ON. Set `CHUMP_COG027_GATE=0` to restore unfiltered behavior for
// A/B harness sweeps measuring the v1 baseline.

/// Returns `true` when the prompt describes a procedural / conditional-chain
/// task. Uses `reflection_db::is_conditional_chain` as the sole heuristic —
/// the same detector that drives the EVAL-030 lessons-block gate — so the
/// two gates stay in sync without duplicating logic.
pub fn is_procedural_task(prompt: &str) -> bool {
    reflection_db::is_conditional_chain(prompt)
}

/// Whether the COG-027 perception-clarification gate is active.
/// Default ON; set `CHUMP_COG027_GATE=0` to disable for A/B harness sweeps.
pub fn cog027_gate_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_COG027_GATE")
            .unwrap_or_default()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

/// Strip the "(consider clarifying)" fragment from a perception context string
/// when the COG-027 gate determines it should be suppressed. Returns the
/// original string unchanged when the gate is inactive or the fragment is absent.
fn suppress_clarify_hint_if_procedural(perception_ctx: &str, user_prompt: &str) -> String {
    if cog027_gate_enabled() && is_procedural_task(user_prompt) {
        // Remove the "Ambiguity: X.X (consider clarifying)" segment, including
        // any leading separator so the join stays clean.
        let cleaned = perception_ctx
            .split(" | ")
            .filter(|seg| !seg.contains("consider clarifying"))
            .collect::<Vec<_>>()
            .join(" | ");
        cleaned
    } else {
        perception_ctx.to_string()
    }
}

/// How many recent improvement targets to surface in the "Lessons" block.
/// Cap is intentionally small — reflections are advisory context, not the main
/// instruction. More than ~5 risks crowding out the actual task prompt.
const LESSONS_LIMIT: usize = 5;

pub struct PromptAssembler {
    pub base_system_prompt: Option<String>,
}

impl PromptAssembler {
    /// Backwards-compatible wrapper: assemble with no explicit tool hint.
    /// Falls through to perception entities for lesson scope filtering.
    pub fn assemble(&self, perception: &PerceivedInput) -> Option<String> {
        self.assemble_with_hint(perception, None)
    }

    /// Assemble with an optional `tool_hint` that overrides perception entities
    /// when filtering reflection lessons (COG-009). When the caller knows
    /// which tool just failed (or which tool is about to be called), pass its
    /// name here so the lessons block surfaces directives scoped to that tool.
    /// Falls back to perception entities when `None`.
    ///
    /// Wiring: orchestrator currently passes `None` — wiring the actual
    /// "last failed tool" signal from BatchOutcome is tracked as COG-009b.
    pub fn assemble_with_hint(
        &self,
        perception: &PerceivedInput,
        tool_hint: Option<&str>,
    ) -> Option<String> {
        // MEM-006 / CREDIBLE-1606: spawn-time lessons. Defensively gated — only
        // fires when spawn_lessons_n() > 0 AND the DB is reachable AND
        // [`reflection_db::lessons_enabled_for_model`] permits injection for the
        // active agent model (enforcing COG-023 Sonnet carve-out and INFRA-016
        // DeepSeek deny-list) AND the ranking returns at least one row.
        let agent_model = reflection_db::current_agent_model();
        let spawn_block: Option<String> = match reflection_db::spawn_lessons_n() {
            Some(n)
                if n > 0
                    && reflection_db::reflection_available()
                    && reflection_db::lessons_enabled_for_model(&agent_model) =>
            {
                // INFRA-424: surface this to the operator (once per process).
                announce_lessons_injection_active(n);
                // Domain hint: reuse the first detected entity, else explicit
                // tool_hint, else "" (global).
                let domain = tool_hint
                    .or_else(|| perception.detected_entities.first().map(|s| s.as_str()))
                    .unwrap_or("");
                let targets = reflection_db::load_spawn_lessons(domain, n);
                // EVAL-030: pass user prompt for task-class-aware suppression.
                let block = reflection_db::format_lessons_block_with_prompt(
                    &targets,
                    Some(perception.raw_text.as_str()),
                );
                if block.is_empty() {
                    None
                } else {
                    Some(block)
                }
            }
            _ => None,
        };

        let mut effective_system = match (spawn_block, self.base_system_prompt.clone()) {
            (Some(spawn), Some(base)) if !base.trim().is_empty() => {
                Some(format!("{}\n\n{}", spawn.trim_end(), base))
            }
            (Some(spawn), _) => Some(spawn),
            (None, base) => base,
        };

        // Inject task planner block if available
        if task_db::task_available() {
            if let Ok(Some(block)) = task_db::planner_active_prompt_block() {
                effective_system = match effective_system {
                    Some(s) if !s.trim().is_empty() => Some(format!("{}\n\n{}", s, block)),
                    _ => Some(block),
                };
            }
        }

        // COG-007 / COG-009 / COG-011: inject reflection learnings. Gated on
        // (a) the DB being reachable AND (b) the COG-016 unified gate
        // [`lessons_enabled_for_model`] — which combines the legacy
        // CHUMP_REFLECTION_INJECTION kill-switch with the COG-016
        // model-tier check (default: only inject on Frontier-class agents
        // per the n=100 sweep evidence; controllable via
        // CHUMP_LESSONS_MIN_TIER=frontier|capable|small|none).
        // Scope filter priority: explicit tool_hint > first detected
        // perception entity > None.
        if reflection_db::reflection_available()
            && reflection_db::lessons_enabled_for_model(&agent_model)
        {
            let scope_hint: Option<&str> =
                tool_hint.or_else(|| perception.detected_entities.first().map(|s| s.as_str()));
            if let Ok(targets) =
                reflection_db::load_recent_high_priority_targets(LESSONS_LIMIT, scope_hint)
            {
                // EVAL-030: task-class-aware suppression keyed off the raw prompt.
                let block = reflection_db::format_lessons_block_with_prompt(
                    &targets,
                    Some(perception.raw_text.as_str()),
                );
                if !block.is_empty() {
                    effective_system = match effective_system {
                        Some(s) if !s.trim().is_empty() => Some(format!("{}\n\n{}", s, block)),
                        _ => Some(block),
                    };
                }
            }
        }

        // COG-015: inject entity-keyed persisted blackboard facts.
        // Gated on CHUMP_ENTITY_PREFETCH (default on); no-ops when entities
        // list is empty or the DB has no matching rows.
        // EVAL-058: skip entirely when CHUMP_BYPASS_BLACKBOARD=1 (ablation A/B flag).
        if !crate::env_flags::chump_bypass_blackboard()
            && crate::blackboard::entity_prefetch_enabled()
            && !perception.detected_entities.is_empty()
        {
            if let Some(block) = crate::blackboard::query_persist_for_entities(
                &perception.detected_entities,
                crate::blackboard::ENTITY_PREFETCH_MAX_ENTRIES,
                crate::blackboard::ENTITY_PREFETCH_MAX_CHARS,
            ) {
                effective_system = match effective_system {
                    Some(s) if !s.trim().is_empty() => {
                        Some(format!("{}\n\n{}", s, block.trim_end()))
                    }
                    _ => Some(block.trim_end().to_string()),
                };
            }
        }

        // INFRA-084: inject ambient sibling-activity summary. Layer 2 of the
        // ambient-glance discipline — Layer 1 is the shell wrappers
        // (chump-ambient-glance.sh) that gate gap-claim/commit/push. This
        // block surfaces the same signal in-prompt for the chump-local
        // multi-turn loop, so an agent making mid-task decisions sees what
        // siblings are doing without relying on the wrappers being called.
        // Gated on CHUMP_AMBIENT_IN_PROMPT (default ON; "0" disables).
        // Skipped on trivial chat prompts (<30 chars trimmed) per the same
        // task-class-aware rule used for the lessons block (EVAL-030).
        let ambient_in_prompt = std::env::var("CHUMP_AMBIENT_IN_PROMPT")
            .map(|v| v != "0")
            .unwrap_or(true);
        if ambient_in_prompt && perception.raw_text.trim().len() >= 30 {
            if let Ok(cwd) = std::env::current_dir() {
                if let Some(path) = crate::ambient_stream::locate_ambient(&cwd) {
                    let self_sid = crate::ambient_stream::current_session_id(&cwd);
                    let gap = std::env::var("CHUMP_GAP_ID").ok().filter(|s| !s.is_empty());
                    let events = crate::ambient_stream::recent_sibling_events(
                        &path,
                        self_sid.as_deref(),
                        gap.as_deref(),
                        &[],
                        300,
                        5,
                    );
                    let block = crate::ambient_stream::format_ambient_block(&events);
                    if !block.is_empty() {
                        effective_system = match effective_system {
                            Some(s) if !s.trim().is_empty() => {
                                Some(format!("{}\n\n{}", s, block.trim_end()))
                            }
                            _ => Some(block.trim_end().to_string()),
                        };
                    }
                }
            }
        }

        // Inject perception summary into system prompt when non-trivial.
        // EVAL-032: skip when CHUMP_BYPASS_PERCEPTION=1 (ablation A/B flag).
        // COG-027: strip the "(consider clarifying)" fragment on procedural tasks
        // before injecting — the clarification nudge harms conditional-chain
        // prompts just as the lessons-block directive did (EVAL-029 / EVAL-030).
        if !crate::env_flags::chump_bypass_perception() {
            let perception_ctx = crate::perception::context_summary(perception);
            if !perception_ctx.is_empty() {
                let perception_ctx =
                    suppress_clarify_hint_if_procedural(&perception_ctx, &perception.raw_text);
                if !perception_ctx.is_empty() {
                    effective_system = match effective_system {
                        Some(s) => Some(format!("{}\n\n[Perception] {}", s, perception_ctx)),
                        None => Some(format!("[Perception] {}", perception_ctx)),
                    };
                }
            }
        }

        effective_system
    }

    pub fn assemble_no_tools_guard(&self, effective_system: Option<String>) -> Option<String> {
        let guard = "\n\nCRITICAL: No tools available right now. Rules:\n\
            1. NEVER say \"Creating...\", \"Saved as...\", \"Checking...\", or claim you did something.\n\
            2. NEVER pretend to create files, run commands, list tasks, or take actions.\n\
            3. Just chat naturally. Answer questions from your knowledge.\n\
            4. If they want you to DO something (create, check, list, run), say: \
               \"Sure, let me do that for you\" — the system will give me tools on the next turn.\n\
            VIOLATION = saying you did something you didn't. That is lying. Don't lie.";

        match effective_system {
            Some(s) => Some(format!("{}{}", s, guard)),
            None => Some(guard.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    //! Tests for the no-tools-guard assembly. The full `assemble()` method
    //! pulls in task_db + perception state which are global and harder to
    //! isolate; the guard wrapper is pure and easy to pin.

    use super::{is_procedural_task, suppress_clarify_hint_if_procedural, PromptAssembler};

    #[test]
    fn no_tools_guard_appends_to_existing_prompt() {
        let pa = PromptAssembler {
            base_system_prompt: Some("base prompt".to_string()),
        };
        let out = pa
            .assemble_no_tools_guard(Some("existing system".to_string()))
            .expect("guarded prompt");
        assert!(out.starts_with("existing system"));
        assert!(out.contains("CRITICAL: No tools available"));
        assert!(out.contains("VIOLATION = saying you did something"));
    }

    #[test]
    fn no_tools_guard_creates_prompt_when_none() {
        let pa = PromptAssembler {
            base_system_prompt: None,
        };
        let out = pa.assemble_no_tools_guard(None).expect("guarded prompt");
        assert!(out.starts_with("\n\nCRITICAL"));
        assert!(out.contains("CRITICAL: No tools available"));
    }

    #[test]
    fn no_tools_guard_preserves_content_verbatim() {
        let pa = PromptAssembler {
            base_system_prompt: None,
        };
        let original = "preserve me exactly".to_string();
        let out = pa.assemble_no_tools_guard(Some(original.clone())).unwrap();
        // The guard MUST come after the original, never modify it.
        assert!(out.starts_with("preserve me exactly"));
    }

    #[test]
    fn no_tools_guard_includes_anti_hallucination_examples() {
        let pa = PromptAssembler {
            base_system_prompt: None,
        };
        let out = pa.assemble_no_tools_guard(None).unwrap();
        // The guard exists specifically to stop the model from claiming it
        // did things. These exemplar phrases must be present so the model
        // has concrete things to avoid.
        assert!(out.contains("Creating..."));
        assert!(out.contains("Saved as..."));
        assert!(out.contains("Checking..."));
    }

    // ── COG-009: explicit tool_hint precedence ─────────────────────────
    //
    // These check the priority ordering at the API boundary without standing
    // up the reflection DB. They deliberately don't assert on the lessons
    // *content* — that's covered in `reflection_db::tests`. What we want
    // here is: assemble_with_hint(_, Some("X")) must call the underlying
    // load with scope_filter == Some("X") regardless of perception entities.
    // We can't observe that call directly without DI, but we CAN observe that
    // the call doesn't panic and returns Some/None matching base_system_prompt
    // when the reflection DB is unavailable in the test process.

    use crate::perception::{PerceivedInput, TaskType};

    fn dummy_perception(entities: Vec<&str>) -> PerceivedInput {
        PerceivedInput {
            raw_text: "test".to_string(),
            likely_needs_tools: false,
            detected_entities: entities.iter().map(|s| s.to_string()).collect(),
            detected_constraints: vec![],
            ambiguity_level: 0.0,
            risk_indicators: vec![],
            question_count: 0,
            task_type: TaskType::Question,
        }
    }

    #[test]
    fn assemble_with_hint_preserves_base_when_no_db() {
        // No reflection DB available in unit-test process → no lessons block.
        // Output should equal base_system_prompt (modulo perception summary,
        // which is empty for our trivial PerceivedInput).
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let out = pa
            .assemble_with_hint(&dummy_perception(vec!["patch_file"]), Some("git_commit"))
            .expect("base preserved");
        // Either pure BASE (no DB) or BASE + lessons block. Never replaces BASE.
        assert!(out.starts_with("BASE"));
    }

    // ── MEM-006: spawn-lessons env-gated injection ──────────────────────
    use serial_test::serial;

    #[test]
    #[serial(reflection_db)]
    fn assemble_does_not_inject_spawn_lessons_when_env_unset() {
        // Defensive default: with CHUMP_LESSONS_AT_SPAWN_N unset, the
        // spawn-lessons branch must be silent regardless of DB state.
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let out = pa
            .assemble_with_hint(&dummy_perception(vec![]), None)
            .expect("base preserved");
        assert!(out.starts_with("BASE"));
        assert!(
            !out.contains("## Lessons from prior episodes"),
            "no spawn lessons block when env unset, got: {out}"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn assemble_spawn_lessons_n_zero_is_silent() {
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "0");
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let out = pa
            .assemble_with_hint(&dummy_perception(vec![]), None)
            .expect("base preserved");
        assert!(out.starts_with("BASE"));
        assert!(!out.contains("## Lessons from prior episodes"));
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
    }

    #[test]
    #[serial(reflection_db)]
    fn credible_1606_spawn_lessons_suppressed_for_denied_or_unopted_models() {
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "5");
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");

        // DeepSeek-R1 is on the default INFRA-016 deny-list even when tier gate is open.
        std::env::set_var("CHUMP_AGENT_MODEL", "deepseek-ai/DeepSeek-R1");
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let out_ds = pa
            .assemble_with_hint(&dummy_perception(vec![]), None)
            .expect("base preserved");
        assert!(
            !out_ds.contains("## Lessons from prior episodes"),
            "CREDIBLE-1606: DeepSeek must never receive spawn lessons when deny-listed, got: {out_ds}"
        );

        // Sonnet is carved out by COG-023 even when CHUMP_LESSONS_MIN_TIER=capable.
        std::env::set_var("CHUMP_AGENT_MODEL", "claude-sonnet-4-5-20250929");
        let out_sonnet = pa
            .assemble_with_hint(&dummy_perception(vec![]), None)
            .expect("base preserved");
        assert!(
            !out_sonnet.contains("## Lessons from prior episodes"),
            "CREDIBLE-1606: Sonnet must never receive spawn lessons via tier gate (COG-023), got: {out_sonnet}"
        );

        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_AGENT_MODEL");
    }

    // Note: removed `assemble_falls_back_to_assemble_with_hint_none` because
    // it was racy in the full test suite — both `assemble()` and
    // `assemble_with_hint(p, None)` query the shared reflection_db, and any
    // other test inserting between the two calls makes the assert_eq fail.
    // The contract "assemble() == assemble_with_hint(p, None)" is verified
    // by inspection: assemble's body is literally `self.assemble_with_hint(p, None)`.

    // ── EVAL-058: CHUMP_BYPASS_BLACKBOARD ablation gate ─────────────────
    // Verifies that when the flag is set, the COG-015 entity-prefetch block
    // is skipped. Since the entity-prefetch path requires a live DB, we
    // verify the gate itself is read correctly and that the env-flag function
    // returns the expected value; the full integration path is covered by
    // blackboard::tests.

    #[test]
    #[serial(reflection_db)]
    fn bypass_blackboard_flag_off_by_default() {
        std::env::remove_var("CHUMP_BYPASS_BLACKBOARD");
        assert!(
            !crate::env_flags::chump_bypass_blackboard(),
            "CHUMP_BYPASS_BLACKBOARD must default to off"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn bypass_blackboard_flag_on_when_set() {
        std::env::set_var("CHUMP_BYPASS_BLACKBOARD", "1");
        assert!(
            crate::env_flags::chump_bypass_blackboard(),
            "CHUMP_BYPASS_BLACKBOARD=1 must enable the bypass"
        );
        std::env::remove_var("CHUMP_BYPASS_BLACKBOARD");
    }

    // ── EVAL-032: CHUMP_BYPASS_PERCEPTION ablation gate ─────────────────
    // Verifies that when the flag is set, the [Perception] block is NOT
    // injected, and when it is unset (default), the block CAN be injected
    // for a perception-bearing input.  We use a PerceivedInput whose
    // risk_indicators / task_type would normally produce a non-empty
    // context_summary (verified by the chump-perception crate tests).

    #[test]
    #[serial(reflection_db)]
    fn bypass_perception_flag_suppresses_perception_block() {
        std::env::set_var("CHUMP_BYPASS_PERCEPTION", "1");
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        // A PerceivedInput that would normally produce a non-empty perception
        // summary (risk indicators present).
        let p = PerceivedInput {
            raw_text: "delete the production database".to_string(),
            likely_needs_tools: true,
            detected_entities: vec!["production".to_string()],
            detected_constraints: vec![],
            ambiguity_level: 0.3,
            risk_indicators: vec!["delete".to_string(), "production".to_string()],
            question_count: 0,
            task_type: crate::perception::TaskType::Action,
        };
        let out = pa.assemble_with_hint(&p, None).expect("output present");
        assert!(
            !out.contains("[Perception]"),
            "CHUMP_BYPASS_PERCEPTION=1 must suppress perception block; got: {out}"
        );
        std::env::remove_var("CHUMP_BYPASS_PERCEPTION");
    }

    #[test]
    #[serial(reflection_db)]
    fn bypass_perception_flag_off_by_default() {
        // Default: flag unset → perception block should be present when the
        // input carries meaningful perception data (risk indicator).
        std::env::remove_var("CHUMP_BYPASS_PERCEPTION");
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let p = PerceivedInput {
            raw_text: "delete the production database".to_string(),
            likely_needs_tools: true,
            detected_entities: vec!["production".to_string()],
            detected_constraints: vec![],
            ambiguity_level: 0.3,
            risk_indicators: vec!["delete".to_string(), "production".to_string()],
            question_count: 0,
            task_type: crate::perception::TaskType::Action,
        };
        let out = pa.assemble_with_hint(&p, None).expect("output present");
        assert!(
            out.contains("[Perception]"),
            "CHUMP_BYPASS_PERCEPTION unset: perception block must be present; got: {out}"
        );
    }

    // ── COG-027: Task-class-aware perception clarification directive gate ────
    //
    // Three tests that exercise the suppress_clarify_hint_if_procedural gate:
    //   1. Procedural task (conditional chain) → "consider clarifying" stripped.
    //   2. Ambiguous/static task → "consider clarifying" preserved.
    //   3. Gate disabled via CHUMP_COG027_GATE=0 → "consider clarifying" preserved
    //      even on procedural tasks.

    #[test]
    #[serial(reflection_db)]
    fn perception_clarify_directive_suppressed_on_procedural_task() {
        std::env::remove_var("CHUMP_COG027_GATE");
        // A perception context that would contain the ambiguity hint.
        // We test the helper directly — assemble_with_hint integration is
        // covered by bypass_perception tests; here we want to isolate the gate.
        let ctx = "Task: Action | Ambiguity: 0.8 (consider clarifying) | Risk: delete";
        // Conditional-chain prompt = procedural task.
        let prompt = "Run the migration, if it fails roll back, then if rollback fails alert ops.";
        assert!(
            is_procedural_task(prompt),
            "test precondition: prompt must be classified as procedural"
        );
        let result = suppress_clarify_hint_if_procedural(ctx, prompt);
        assert!(
            !result.contains("consider clarifying"),
            "procedural task: clarify hint must be stripped; got: {result}"
        );
        // Other segments must survive.
        assert!(
            result.contains("Task: Action"),
            "non-clarify segments must survive; got: {result}"
        );
        assert!(
            result.contains("Risk: delete"),
            "risk segment must survive; got: {result}"
        );
    }

    #[test]
    fn perception_clarify_directive_active_on_ambiguous_static_task() {
        std::env::remove_var("CHUMP_COG027_GATE");
        let ctx = "Task: Action | Entities: src/main.rs | Ambiguity: 0.8 (consider clarifying)";
        // A simple ambiguous/static prompt — NOT a conditional chain.
        let prompt = "Fix the bug.";
        assert!(
            !is_procedural_task(prompt),
            "test precondition: static prompt must NOT be procedural"
        );
        let result = suppress_clarify_hint_if_procedural(ctx, prompt);
        assert!(
            result.contains("consider clarifying"),
            "ambiguous/static task: clarify hint must be preserved; got: {result}"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn cog027_gate_disabled_via_env() {
        std::env::set_var("CHUMP_COG027_GATE", "0");
        let ctx = "Task: Action | Ambiguity: 0.8 (consider clarifying)";
        // Even a procedural prompt must NOT have the hint stripped when the gate is off.
        let prompt = "Run tests, if it fails rerun, then if still failing notify.";
        assert!(
            is_procedural_task(prompt),
            "test precondition: prompt is procedural"
        );
        let result = suppress_clarify_hint_if_procedural(ctx, prompt);
        assert!(
            result.contains("consider clarifying"),
            "CHUMP_COG027_GATE=0: clarify hint must NOT be stripped; got: {result}"
        );
        std::env::remove_var("CHUMP_COG027_GATE");
    }
}
