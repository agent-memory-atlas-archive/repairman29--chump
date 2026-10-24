//! Persistence + retrieval for structured reflections (GEPA, COG-006).
//!
//! Two tables (schema lives in `db_pool::init_schema`):
//!
//! - `chump_reflections`: one row per completed task / episode, with the
//!   typed fields from `reflection::Reflection` minus the improvements list
//!   (which is normalized into the next table).
//! - `chump_improvement_targets`: one row per directive, FK to parent
//!   reflection. Indexed on (priority, created_at) so the prompt assembler
//!   can pull the freshest high-priority targets cheaply.
//!
//! The "feedback flywheel" closes here:
//!
//! 1. Autonomy loop completes a task → `save_reflection()` (autonomy_loop.rs)
//! 2. Next task starts → `load_recent_high_priority_targets()` (prompt_assembler)
//! 3. Targets render into the system prompt as a "Lessons" block.
//!
//! Without persistence, `reflection.rs`'s typed analysis was throwaway. With
//! it, the agent gets to read its own postmortems.

#[cfg(test)]
use crate::reflection::{ErrorPattern, OutcomeClass};
use crate::reflection::{ImprovementTarget, Priority, Reflection};
use anyhow::Result;
#[cfg(test)]
use rusqlite::Connection;

#[cfg(not(test))]
fn open_db() -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>> {
    crate::db_pool::get()
}

#[cfg(test)]
thread_local! {
    static TEST_DB_ROOT: std::cell::RefCell<Option<std::path::PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
pub(crate) fn set_test_db_root(path: Option<std::path::PathBuf>) {
    TEST_DB_ROOT.with(|cell| *cell.borrow_mut() = path);
}

#[cfg(test)]
fn open_db() -> Result<Connection> {
    let base = TEST_DB_ROOT
        .with(|cell| cell.borrow().clone())
        .unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        });
    let path = base.join("sessions/chump_memory.db");
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = Connection::open(&path)?;
    // Mirror schema from db_pool::init_schema for isolated tests.
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_reflections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_id INTEGER,
            intended_goal TEXT NOT NULL DEFAULT '',
            observed_outcome TEXT NOT NULL DEFAULT '',
            outcome_class TEXT NOT NULL DEFAULT 'failure',
            error_pattern TEXT,
            hypothesis TEXT NOT NULL DEFAULT '',
            surprisal_at_reflect REAL,
            confidence_at_reflect REAL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );
         CREATE TABLE IF NOT EXISTS chump_improvement_targets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reflection_id INTEGER NOT NULL,
            directive TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'medium',
            scope TEXT,
            actioned_as TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );
         CREATE TABLE IF NOT EXISTS chump_causal_lessons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_type TEXT,
            action_taken TEXT NOT NULL,
            alternative TEXT,
            lesson TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5,
            times_applied INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );",
    )?;
    Ok(conn)
}

/// Whether the reflection store is reachable. Mirrors `episode_db::episode_available()`.
pub fn reflection_available() -> bool {
    open_db().is_ok()
}

/// COG-011 gate: whether the "Lessons from prior episodes" block should be
/// injected into assembled prompts. Default on. Set `CHUMP_REFLECTION_INJECTION=0`
/// (also accepts "false" or "off") to run a baseline-prompt A/B without
/// recompiling. The gap test rig flips this flag across 20 tasks to measure
/// whether lesson injection actually improves task success.
pub fn reflection_injection_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_REFLECTION_INJECTION").as_deref(),
        Ok("0") | Ok("false") | Ok("off")
    )
}

// ---------------------------------------------------------------------------
// COG-016: model-tier-aware lessons injection
//
// The n=100 sweep (PRs #80 + #82, results in docs/research/CONSCIOUSNESS_AB_RESULTS.md)
// established statistically (p<0.05 across 3 fixtures, 10.7× A/A noise floor)
// that injecting the lessons block triggers fake-tool-call emission by mean
// +0.14 percentage points on weak agent models (haiku-4-5). The Llama-3.3-70B
// probe (2026-04-19) showed the failure mode is Anthropic-pretrain-specific;
// Llama doesn't exhibit it. Production should gate injection on agent
// capability + add an explicit anti-hallucination guardrail to the lessons
// content itself.
// ---------------------------------------------------------------------------

/// Coarse capability tier for the agent model the lessons block would be
/// injected into. Used by [`lessons_enabled_for_model`] to gate injection.
///
/// Ordering is meaningful: `Frontier` > `Sonnet` > `Capable` > `Small` > `Unknown`.
///
/// COG-023: `Sonnet` was carved out from `Frontier` because EVAL-027c (n=100,
/// non-overlapping CIs) confirmed the COG-016 anti-hallucination directive
/// ACTIVELY HARMS sonnet-4-5 — it triggers ~33% fake-tool-call emission per
/// response under cell A (full directive + lessons). Carving the tier below
/// `Frontier` means the default `CHUMP_LESSONS_MIN_TIER=frontier` excludes
/// sonnet, while operators can opt back in by lowering the threshold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ModelTier {
    /// Unrecognized model id — safest default is to NOT inject (avoid
    /// surprising any environment running a model we haven't classified).
    Unknown,
    /// Sub-14B local models (qwen2.5:7b, llama3.2:3b, etc.).
    Small,
    /// 14B-32B local mid-tier models (qwen2.5:14b, gpt-oss:20b).
    Capable,
    /// Anthropic Sonnet-class models (claude-sonnet-4-5+). Carved out from
    /// `Frontier` per COG-023 / EVAL-027c: the COG-016 directive backfires
    /// on Sonnet (33% fake-tool emission), so default-frontier injection
    /// must skip them. Below `Frontier` so default `CHUMP_LESSONS_MIN_TIER=
    /// frontier` does NOT inject; opt-in via `=capable` or lower.
    Sonnet,
    /// Frontier-class: claude-haiku-4-5+, opus-4-5+, gpt-4*,
    /// gemini-1.5-pro+, llama-3.x-70B+.
    /// (Sonnet intentionally excluded — see [`ModelTier::Sonnet`].)
    Frontier,
}

/// Map a model id (from `OPENAI_MODEL`, the agent backend, etc.) to a coarse
/// capability tier. Returns [`ModelTier::Unknown`] for unrecognized strings.
///
/// Matching is **case-insensitive substring** so it survives provider
/// variations like `claude-haiku-4-5-20251001` and
/// `meta-llama/Llama-3.3-70B-Instruct-Turbo`.
pub fn model_tier(model_id: &str) -> ModelTier {
    let m = model_id.to_lowercase();

    // COG-023: Sonnet carve-out — must be checked BEFORE the frontier
    // matchers (some legacy patterns like "claude-3-5-sonnet" would otherwise
    // hit a frontier marker). EVAL-027c confirmed the COG-016 directive
    // backfires on Sonnet (33% fake-tool emission per response, n=100).
    // Match any model id containing "sonnet" (case-insensitive). Opus and
    // haiku do NOT match this branch.
    if m.contains("sonnet") {
        return ModelTier::Sonnet;
    }

    // Frontier: cloud APIs + flagship locals (Sonnet is carved out above).
    let frontier_markers: &[&str] = &[
        "claude-haiku-4",
        "claude-opus-4",
        "claude-3-5-haiku",
        "claude-3-7",
        "claude-3-haiku",
        "gpt-4",
        "gpt-5",
        "o1",
        "o3",
        "gemini-1.5-pro",
        "gemini-2",
        "gemini-3-pro",
        "gemini-3.1-pro",
        "gemini-3.8-flash",
        "gemini-3.6-flash",
        "gemini-4",
        "codestral",
        "mistral-code",
        "deepseek-v4",
        "llama-3.3-70b",
        "llama-3.1-70b",
        "llama-3.1-405b",
        "qwen2.5-72b",
        "qwen2.5:72b",
    ];
    if frontier_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Frontier;
    }

    // Capable: 14B-32B local mid-tier + fast Gemini Flash / Qwen 3.8
    let capable_markers: &[&str] = &[
        "qwen2.5:14b",
        "qwen2.5-14b",
        "qwen3:14b",
        "qwen3-14b",
        "qwen3:32b",
        "qwen3-32b",
        "qwen2.5:32b",
        "qwen2.5-32b",
        "qwen3.8",
        "qwen-3.8",
        "llama-3.1-8b",
        "gpt-oss:20b",
        "gpt-oss-20b",
        "gemini-1.5-flash",
        "gemini-2.5-flash",
        "gemini-3-flash",
        "gemini-3.5-flash",
        "gemini-3.1-flash",
    ];
    if capable_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Capable;
    }

    // Small: sub-14B
    let small_markers: &[&str] = &[
        "llama-3.2-1b",
        "llama-3.2-3b",
        "llama3.2:1b",
        "llama3.2:3b",
        "qwen2.5:7b",
        "qwen2.5-7b",
        "qwen3:8b",
        "qwen3-8b",
        "qwen3:7b",
        "qwen3-7b",
    ];
    if small_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Small;
    }

    ModelTier::Unknown
}

/// Read `CHUMP_LESSONS_MIN_TIER` env var to determine the minimum agent tier
/// at which the lessons block should be injected.
///
/// Accepted values (case-insensitive): `frontier`, `capable`, `small`, `none`.
/// `none` (or unset) disables tier gating entirely — no model receives lessons
/// via the tier path. To re-enable, set `CHUMP_LESSONS_MIN_TIER=frontier` or
/// (preferred) opt models in individually via [`lessons_opt_in_for_model`].
///
/// **Default: `None`** (COG-024) — lessons OFF unless explicitly opted-in
/// per-model via `CHUMP_LESSONS_OPT_IN_MODELS`. Per EVAL-027c full Anthropic-
/// family results, no model has UNIVERSAL benefit, so per-model opt-in is
/// the only safe default. Prior `CHUMP_LESSONS_MIN_TIER=frontier` users
/// should switch to per-model opt-in (see docs/process/COG-024-MIGRATION.md).
pub fn min_tier_for_lessons() -> Option<ModelTier> {
    let raw = std::env::var("CHUMP_LESSONS_MIN_TIER").ok();
    let normalized = raw.as_deref().map(|s| s.trim().to_lowercase());
    match normalized.as_deref() {
        Some("none") | Some("off") | Some("disabled") => None,
        Some("small") => Some(ModelTier::Small),
        Some("capable") => Some(ModelTier::Capable),
        Some("frontier") => Some(ModelTier::Frontier),
        Some(_) => None,
        None => None,
    }
}

/// COG-024: per-model opt-in lookup. Returns the validated lessons variant
/// (e.g. `"cog016"`, `"v1"`, `"sake"`) for `model_id` if it appears in the
/// `CHUMP_LESSONS_OPT_IN_MODELS` CSV, else `None`.
///
/// CSV format: `model_id:variant,model_id:variant,...`
///
/// Examples:
/// - `claude-haiku-4-5:cog016,claude-opus-4-5:cog016` — both opted in
/// - `claude-haiku-4-5:cog016` — haiku only
///
/// Matching is **case-insensitive substring** on the model_id portion (same
/// semantics as [`model_tier`]) so it survives provider variations like
/// `claude-haiku-4-5-20251001`. Malformed entries (no colon, empty halves)
/// are silently skipped.
pub fn lessons_opt_in_for_model(model_id: &str) -> Option<String> {
    let raw = std::env::var("CHUMP_LESSONS_OPT_IN_MODELS").ok()?;
    let needle = model_id.to_lowercase();
    if needle.is_empty() {
        return None;
    }
    for entry in raw.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let (id, variant) = match entry.split_once(':') {
            Some(pair) => pair,
            None => continue, // malformed — skip
        };
        let id = id.trim().to_lowercase();
        let variant = variant.trim();
        if id.is_empty() || variant.is_empty() {
            continue;
        }
        if needle.contains(&id) {
            return Some(variant.to_string());
        }
    }
    None
}

/// Resolve the agent model id from environment. Tries `CHUMP_AGENT_MODEL`
/// first (explicit chump-side override), then `OPENAI_MODEL` (the standard
/// OpenAI-compat backend env var).
pub fn current_agent_model() -> String {
    std::env::var("CHUMP_AGENT_MODEL")
        .or_else(|_| std::env::var("OPENAI_MODEL"))
        .unwrap_or_default()
}

/// INFRA-016: architecture-family deny-list for lesson injection.
///
/// Reads `CHUMP_LESSONS_DENY_FAMILIES` (CSV, default `"deepseek"`). If the
/// model id (case-insensitive) contains any deny-list entry as a substring,
/// returns `true` — injection must be suppressed regardless of the opt-in
/// flag or tier gate. Logs a WARN when suppression fires so operators notice.
///
/// Motivation: EVAL-071 showed DeepSeek-V3.1 loses -6.56pp task correctness
/// when the COG-016 lessons block is injected, while Anthropic models retain
/// the original halluc-reduction benefit. Defaulting to deny for "deepseek"
/// prevents silent harm on new non-Anthropic backends until per-family
/// evidence (EVAL-074) establishes a safe rewrite. Operators can clear the
/// deny-list with `CHUMP_LESSONS_DENY_FAMILIES=""` once the risk is resolved.
pub fn lessons_family_denied(model_id: &str) -> bool {
    let raw =
        std::env::var("CHUMP_LESSONS_DENY_FAMILIES").unwrap_or_else(|_| "deepseek".to_string());
    let needle = model_id.to_lowercase();
    for family in raw.split(',') {
        let family = family.trim().to_lowercase();
        if family.is_empty() {
            continue;
        }
        if needle.contains(&family) {
            tracing::warn!(
                model_id = %model_id,
                family = %family,
                "lessons suppressed — model family in CHUMP_LESSONS_DENY_FAMILIES deny-list (INFRA-016)"
            );
            return true;
        }
    }
    false
}

/// COG-016 / COG-024 unified gate: should the lessons block be injected for
/// the current agent model?
///
/// Returns true iff the [`reflection_injection_enabled`] kill-switch is on
/// AND the model is not in the [`lessons_family_denied`] deny-list (INFRA-016)
/// AND **either** of:
///   (a) the model is explicitly opted-in via [`lessons_opt_in_for_model`]
///       (CHUMP_LESSONS_OPT_IN_MODELS CSV — preferred path post-COG-024), OR
///   (b) the legacy tier gate [`min_tier_for_lessons`] passes (only active
///       when `CHUMP_LESSONS_MIN_TIER` is explicitly set to a tier name).
///
/// `Unknown` model tiers are NEVER injected via the tier path (safer
/// default — don't surprise an unknown environment with extra prompt
/// content). The opt-in CSV bypasses this — if you name a model explicitly,
/// you want it on.
///
/// COG-024: with `CHUMP_LESSONS_MIN_TIER` unset, [`min_tier_for_lessons`]
/// returns `None`, so only the opt-in CSV can enable injection. Default is
/// OFF for every model — see docs/process/COG-024-MIGRATION.md.
pub fn lessons_enabled_for_model(model_id: &str) -> bool {
    if !reflection_injection_enabled() {
        return false;
    }
    // INFRA-016: deny-list check wins over both opt-in and tier gate.
    if lessons_family_denied(model_id) {
        return false;
    }
    // (a) per-model opt-in (preferred path)
    if lessons_opt_in_for_model(model_id).is_some() {
        return true;
    }
    // (b) legacy tier gate — only fires if CHUMP_LESSONS_MIN_TIER is set
    let min = match min_tier_for_lessons() {
        None => return false, // COG-024: default OFF
        Some(t) => t,
    };
    let tier = model_tier(model_id);
    if tier == ModelTier::Unknown {
        return false;
    }
    tier >= min
}

// ---------------------------------------------------------------------------
// MEM-006: lessons-loaded-at-spawn
//
// PRODUCT-006 (PR #125) writes reflection lessons into chump_improvement_targets
// via harvest-synthesis-lessons.sh. MEM-006 closes the loop by reading top-N
// relevant lessons at agent spawn-time, not just on per-task assembly.
//
// This is the SECOND opt-in path (alongside CHUMP_LESSONS_OPT_IN_MODELS). Both
// require explicit env-var activation — neither fires by default. This
// preserves the COG-024 safe-by-default policy: zero injection unless the
// operator actively chose it.
// ---------------------------------------------------------------------------

/// Default cap for spawn-loaded lessons. Same as the per-task LESSONS_LIMIT
/// (5) in prompt_assembler.rs — keeps prompt overhead bounded.
const SPAWN_LESSONS_DEFAULT_N: usize = 5;
/// Hard ceiling. Operators can request fewer, but never more — past 20 the
/// prompt starts crowding out the actual task.
const SPAWN_LESSONS_MAX_N: usize = 20;

/// Read CHUMP_LESSONS_AT_SPAWN_N env var.
///
/// FLEET-049: defaults to `SPAWN_LESSONS_DEFAULT_N` (5) when unset — lessons
/// are ON by default with the quality gate active. Set to `0` to disable.
/// When set, the value is clamped to [0, SPAWN_LESSONS_MAX_N]. Malformed
/// values fall back to the default.
///
/// COG-024 invariant: returning `None` means the spawn-lessons path is
/// completely silent. `Some(0)` means lessons are explicitly disabled.
pub fn spawn_lessons_n() -> Option<usize> {
    let raw = match std::env::var("CHUMP_LESSONS_AT_SPAWN_N") {
        Ok(s) => s,
        Err(_) => return Some(SPAWN_LESSONS_DEFAULT_N),
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Some(SPAWN_LESSONS_DEFAULT_N);
    }
    let parsed: usize = trimmed.parse().unwrap_or(SPAWN_LESSONS_DEFAULT_N);
    Some(parsed.min(SPAWN_LESSONS_MAX_N))
}

/// Map a reflection's `outcome_class` string to a quality score (MEM-009).
///
/// Scoring:
///   "pass" | "success" → 1.0
///   "partial"          → 0.5
///   "failure" | "abandoned" | other → 0.0
///   NULL / missing     → 0.5 (conservative default)
///
/// Used by [`load_spawn_lessons`] to filter lessons by parent-reflection quality.
fn outcome_quality(outcome_class: Option<&str>) -> f64 {
    match outcome_class {
        None | Some("") => 0.5,
        Some("pass") | Some("success") => 1.0,
        Some("partial") => 0.5,
        _ => 0.0,
    }
}

/// Default quality threshold for lesson injection (FLEET-049).
/// Matches the documented default in docs/operations/FLEET_ENV_VARS_H_N.md.
const LESSON_QUALITY_THRESHOLD_DEFAULT: f64 = 0.6;

/// Read `CHUMP_LESSON_QUALITY_THRESHOLD` env var (float 0.0–1.0).
///
/// FLEET-049: defaults to 0.6 when unset — lessons with cosine similarity
/// below 0.6 are filtered out at spawn time. Set to 0.0 to disable the
/// quality gate (inject all lessons regardless of score).
/// Clamps the parsed value to [0.0, 1.0].
/// Malformed values fall back to the default.
pub fn lesson_quality_threshold() -> f64 {
    let raw = match std::env::var("CHUMP_LESSON_QUALITY_THRESHOLD") {
        Ok(s) => s,
        Err(_) => return LESSON_QUALITY_THRESHOLD_DEFAULT,
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return LESSON_QUALITY_THRESHOLD_DEFAULT;
    }
    let parsed: f64 = trimmed.parse().unwrap_or(LESSON_QUALITY_THRESHOLD_DEFAULT);
    parsed.clamp(0.0, 1.0)
}

/// Load the top-N most-relevant improvement targets for a spawning agent.
///
/// Ranking heuristic (recency × frequency surrogate):
///   score = COUNT(*) by directive * exp(-age_days / 7.0)
///
/// Lessons that recur across multiple reflections in the past week outrank
/// one-off lessons from a month ago. This favors directives that the
/// reflection harvester has independently confirmed multiple times.
///
/// `domain` filter behaviour:
///   - empty / "any" / "global" → all high+medium lessons regardless of scope
///   - non-empty → exact scope match OR universal (NULL/empty) scope.
///     Mirrors the lax-scope behaviour of [`load_recent_high_priority_targets`].
///
/// `quality_threshold` — minimum quality score [0.0, 1.0] for the parent
/// reflection. Quality is derived from the parent reflection's `outcome_class`:
///   "pass"/"success" = 1.0, "partial" = 0.5, "failure"/"abandoned" = 0.0,
///   NULL/missing = 0.5. Pass 0.0 to load all lessons regardless of quality
/// (the default / backward-compatible behaviour). The env var
/// `CHUMP_LESSON_QUALITY_THRESHOLD` is read by the prompt assembler and passed
/// here; individual callers can also supply an explicit value for testing.
///
/// Always excludes ab_seed reflections (consistent with the per-task path).
/// `max_n` is clamped to [0, SPAWN_LESSONS_MAX_N].
///
/// Returns empty Vec when the DB is unreachable or the query produces no rows
/// — never errors out at the callsite. Spawn-time injection is best-effort:
/// a missing DB must not block agent startup.
pub fn load_spawn_lessons(domain: &str, max_n: usize) -> Vec<ImprovementTarget> {
    // EVAL-056: memory ablation gate — bypass flag short-circuits before any DB work.
    if crate::env_flags::chump_bypass_spawn_lessons() {
        return Vec::new();
    }
    load_spawn_lessons_with_threshold(domain, max_n, lesson_quality_threshold())
}

/// Inner implementation of [`load_spawn_lessons`] with an explicit quality
/// threshold. Kept separate so tests can supply any threshold without touching
/// the env var (which would require serial test coordination).
pub fn load_spawn_lessons_with_threshold(
    domain: &str,
    max_n: usize,
    quality_threshold: f64,
) -> Vec<ImprovementTarget> {
    let max_n = max_n.min(SPAWN_LESSONS_MAX_N);
    if max_n == 0 {
        return Vec::new();
    }
    let conn = match open_db() {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let domain_norm = domain.trim().to_lowercase();
    let use_domain_filter =
        !domain_norm.is_empty() && domain_norm != "any" && domain_norm != "global";

    // Clamp threshold into [0.0, 1.0] in case caller passes an out-of-range value.
    let quality_threshold = quality_threshold.clamp(0.0, 1.0);

    // Build the quality filter clause. We join chump_improvement_targets with
    // chump_reflections to access outcome_class. The CASE expression maps
    // outcome_class to a numeric quality score:
    //   'pass'/'success' → 1.0, 'partial' → 0.5, NULL/'' → 0.5, else → 0.0
    // When threshold = 0.0, the condition is always true (no-op filter).
    //
    // Recency-frequency ranking: per-directive count * exp(-age_days/7)
    // SQLite has no exp(); approximate with 1.0 / (1.0 + age_days / 7.0).
    // Equivalent ordering for our purposes (monotonic decreasing in age).
    // MIN(priority) over text picks 'high' over 'medium' lexicographically
    // (h < m), which happens to give us the semantically correct "promote a
    // directive to its highest-ever priority." MAX(scope) collapses to any
    // representative scope when the same directive appears with multiple.
    // Column order MUST match `row_from_target` (directive, priority, scope,
    // actioned_as). We embed NULL for actioned_as (spawn lessons don't carry
    // a per-instance action trace — they're aggregated across reflections).
    // Ranking columns (freq, latest_at, score) trail and are only used by
    // ORDER BY, never read back.
    let quality_clause = if quality_threshold <= 0.0 {
        // No-op: include everything — avoid the join cost when not needed.
        String::new()
    } else {
        format!(
            "  AND reflection_id IN (
              SELECT id FROM chump_reflections
              WHERE CASE
                WHEN outcome_class IS NULL OR outcome_class = '' THEN 0.5
                WHEN outcome_class = 'pass' OR outcome_class = 'success' THEN 1.0
                WHEN outcome_class = 'partial' THEN 0.5
                ELSE 0.0
              END >= {quality_threshold}
            )"
        )
    };

    let sql_common = format!(
        "
        SELECT directive,
               MIN(priority) AS priority,
               MAX(scope) AS scope,
               NULL AS actioned_as,
               COUNT(*) AS freq,
               MAX(created_at) AS latest_at,
               (CAST(COUNT(*) AS REAL) /
                (1.0 + (julianday('now') - julianday(MAX(created_at))) / 7.0)) AS score
        FROM chump_improvement_targets
        WHERE priority IN ('high', 'medium')
          AND reflection_id NOT IN (
              SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
          )
        {quality_clause}"
    );

    let rows: Result<Vec<ImprovementTarget>, rusqlite::Error> = if use_domain_filter {
        let q = format!(
            "{sql_common}
              AND (scope IS NULL OR scope = '' OR LOWER(scope) = ?1)
            GROUP BY directive
            ORDER BY score DESC, latest_at DESC
            LIMIT ?2"
        );
        let mut stmt = match conn.prepare(&q) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let iter = match stmt.query_map(
            rusqlite::params![domain_norm, max_n as i64],
            row_from_target,
        ) {
            Ok(it) => it,
            Err(_) => return Vec::new(),
        };
        iter.collect()
    } else {
        let q = format!(
            "{sql_common}
            GROUP BY directive
            ORDER BY score DESC, latest_at DESC
            LIMIT ?1"
        );
        let mut stmt = match conn.prepare(&q) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let iter = match stmt.query_map(rusqlite::params![max_n as i64], row_from_target) {
            Ok(it) => it,
            Err(_) => return Vec::new(),
        };
        iter.collect()
    };

    rows.unwrap_or_default()
}

/// Hypothesis-field marker `ci_lesson.rs` stamps on every reflection it
/// writes, so `load_ci_lessons` can find them by construction rather than by
/// guessing at error_pattern overlap with ordinary agent self-reflections.
pub const CI_LESSON_HYPOTHESIS_MARKER: &str = "ci_lesson:";

/// Load recent CI-failure lessons (INFRA-1765) for `domain`, capped at
/// `max_n`.
///
/// Deliberately bypasses [`load_spawn_lessons`]'s quality-score filter:
/// that filter treats `outcome_class = "failure"` as low-trust noise, which
/// is the right call for an *agent's own self-reflection* on an abandoned
/// trajectory (uncertain, possibly hallucinated advice) but wrong for a CI
/// lesson, whose outcome_class is deliberately "failure" (the CI check did
/// fail) while the directive itself comes from a fixed keyword taxonomy
/// ([`crate::ci_lesson::classify_ci_failure`]) — deterministic, not a
/// self-report, so there is no "uncertain trajectory" to discount.
pub fn load_ci_lessons(domain: &str, max_n: usize) -> Vec<ImprovementTarget> {
    let max_n = max_n.min(SPAWN_LESSONS_MAX_N);
    if max_n == 0 {
        return Vec::new();
    }
    let conn = match open_db() {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let domain_norm = domain.trim().to_lowercase();
    let use_domain_filter =
        !domain_norm.is_empty() && domain_norm != "any" && domain_norm != "global";

    let sql_common = format!(
        "SELECT t.directive, t.priority, t.scope, NULL AS actioned_as
         FROM chump_improvement_targets t
         JOIN chump_reflections r ON r.id = t.reflection_id
         WHERE r.hypothesis LIKE '{CI_LESSON_HYPOTHESIS_MARKER}%'"
    );

    let rows: Result<Vec<ImprovementTarget>, rusqlite::Error> = if use_domain_filter {
        let q = format!(
            "{sql_common}
              AND (t.scope IS NULL OR t.scope = '' OR LOWER(t.scope) = ?1)
            ORDER BY r.created_at DESC
            LIMIT ?2"
        );
        let mut stmt = match conn.prepare(&q) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let iter = match stmt.query_map(
            rusqlite::params![domain_norm, max_n as i64],
            row_from_target,
        ) {
            Ok(it) => it,
            Err(_) => return Vec::new(),
        };
        iter.collect()
    } else {
        let q = format!(
            "{sql_common}
            ORDER BY r.created_at DESC
            LIMIT ?1"
        );
        let mut stmt = match conn.prepare(&q) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let iter = match stmt.query_map(rusqlite::params![max_n as i64], row_from_target) {
            Ok(it) => it,
            Err(_) => return Vec::new(),
        };
        iter.collect()
    };

    rows.unwrap_or_default()
}

// ---------------------------------------------------------------------------
// COG-041: Semantic lesson retrieval
// ---------------------------------------------------------------------------
//
// `load_spawn_lessons` ranks by recency × frequency: lessons that
// recurred in the past week outrank one-off lessons from a month ago.
// That heuristic surfaces NOISE as readily as SIGNAL — a lesson that
// fires in 12 reflections about something completely unrelated to the
// current gap still beats a once-seen but precisely-relevant lesson.
//
// `load_relevant_lessons_semantic` ranks by TF-IDF cosine similarity
// between each directive and the query text (typically the gap's
// title + acceptance criteria). No external embedding model required
// — pure Rust, ~100 lines, zero new dependencies.
//
// Trade-off vs. real embeddings: TF-IDF can't match synonyms ("auth"
// vs "credentials") or paraphrases. For a first cut over a corpus of
// ~1k lessons that share a vocabulary anyway, TF-IDF is sufficient
// signal. Swap to nomic-embed-text later — the public API
// (load_relevant_lessons_semantic) stays stable.
//
// Gate: `CHUMP_LESSONS_SEMANTIC=1` env. Default OFF until validated.

/// Return whether semantic retrieval is enabled. Default OFF.
pub fn lessons_semantic_enabled() -> bool {
    matches!(
        std::env::var("CHUMP_LESSONS_SEMANTIC").as_deref(),
        Ok("1") | Ok("true") | Ok("on")
    )
}

/// English stop words to drop during tokenization. Kept minimal — too
/// aggressive a stop list throws away lesson signal (e.g. "always",
/// "never" are loaded with semantic content here).
const STOPWORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "is", "are", "was", "were", "be", "been", "being", "to",
    "of", "in", "on", "at", "for", "with", "by", "from", "as", "this", "that", "these", "those",
    "it", "its", "if", "then", "else", "do", "does", "did", "have", "has", "had", "i", "you", "we",
    "they", "he", "she", "will", "would", "should", "could", "can", "may", "might", "not", "no",
    "yes", "so", "up", "down", "out", "into", "than", "vs", "via", "per",
];

/// Tokenize free text into lowercase alphanumeric tokens, length>=3,
/// not numeric-only, not in the stop list. Stable, allocation-aware.
fn tokenize(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            cur.push(ch.to_ascii_lowercase());
        } else if !cur.is_empty() {
            push_token(&mut out, std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        push_token(&mut out, cur);
    }
    out
}

fn push_token(out: &mut Vec<String>, t: String) {
    if t.len() < 3 {
        return;
    }
    if t.chars().all(|c| c.is_ascii_digit()) {
        return;
    }
    if STOPWORDS.contains(&t.as_str()) {
        return;
    }
    out.push(t);
}

/// Compute cosine similarity between two TF-IDF-weighted bags of words.
/// Returns 0.0 when either input is empty (no overlap, no signal).
fn cosine_similarity(
    a: &std::collections::HashMap<String, f64>,
    b: &std::collections::HashMap<String, f64>,
) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0_f64;
    for (k, va) in a.iter() {
        if let Some(vb) = b.get(k) {
            dot += va * vb;
        }
    }
    let na: f64 = a.values().map(|v| v * v).sum::<f64>().sqrt();
    let nb: f64 = b.values().map(|v| v * v).sum::<f64>().sqrt();
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na * nb)
}

/// Build a TF-IDF vector for `tokens` given the precomputed IDF map.
/// Tokens not in the IDF map (rare-in-corpus) contribute zero — they
/// don't push the vector toward unrelated lessons.
fn tfidf_vector(
    tokens: &[String],
    idf: &std::collections::HashMap<String, f64>,
) -> std::collections::HashMap<String, f64> {
    use std::collections::HashMap;
    let mut tf: HashMap<String, f64> = HashMap::new();
    for t in tokens {
        *tf.entry(t.clone()).or_insert(0.0) += 1.0;
    }
    let mut out = HashMap::new();
    for (term, count) in tf {
        if let Some(idf_val) = idf.get(&term) {
            out.insert(term, count * idf_val);
        }
    }
    out
}

/// Load top-N lessons by semantic similarity to `query_text`.
///
/// `query_text`: typically `<gap_title> <acceptance criteria>`. Empty
/// query falls back to `load_spawn_lessons(domain, max_n)` (recency x
/// frequency) so callers get *something* useful rather than nothing.
///
/// `domain` filter behaves identically to `load_spawn_lessons`:
/// empty/"any"/"global" returns global pool; non-empty returns
/// scope-match OR universal scope.
///
/// `max_n` is clamped to [0, SPAWN_LESSONS_MAX_N] (same cap as the
/// recency-frequency path so the briefing's lesson block doesn't
/// suddenly balloon when this is enabled).
///
/// COG-046: embedding-backed retrieval. Same shape as
/// `load_relevant_lessons_semantic` but uses Ollama embeddings (or any
/// configured embedding endpoint) instead of TF-IDF. Catches synonyms
/// TF-IDF can't ("auth" ≈ "credentials", "fleet" ≈ "dispatcher").
///
/// Falls back to `load_relevant_lessons_semantic` (TF-IDF) when:
///   - CHUMP_LESSONS_EMBEDDING is not enabled
///   - the embedding endpoint is unreachable
///   - query embedding succeeds but ALL directive embeddings fail
///   - resulting top-k all score 0.0 (no signal)
///
/// Caller (briefing.rs) chains: embedding → semantic → recency. Each
/// step is best-effort and gives the next a chance.
pub fn load_relevant_lessons_embedding(
    query_text: &str,
    max_n: usize,
    domain: &str,
) -> Vec<ImprovementTarget> {
    if !crate::lesson_embeddings::embedding_enabled() {
        return load_relevant_lessons_semantic(query_text, max_n, domain);
    }
    let max_n = max_n.min(SPAWN_LESSONS_MAX_N);
    if max_n == 0 || query_text.trim().is_empty() {
        return Vec::new();
    }

    // Embed the query first. If this fails, no point embedding any
    // directives — fall back immediately.
    let q_embed = match crate::lesson_embeddings::embed_text(query_text) {
        Some(v) => v,
        None => return load_relevant_lessons_semantic(query_text, max_n, domain),
    };

    // Pull eligible (directive, priority, scope) rows, same filter as
    // the TF-IDF path so the cells are comparable.
    let conn = match open_db() {
        Ok(c) => c,
        Err(_) => return load_relevant_lessons_semantic(query_text, max_n, domain),
    };
    let domain_norm = domain.trim().to_lowercase();
    let use_domain_filter =
        !domain_norm.is_empty() && domain_norm != "any" && domain_norm != "global";

    let sql = if use_domain_filter {
        "SELECT directive,
                MIN(priority) AS priority,
                MAX(scope) AS scope
         FROM chump_improvement_targets
         WHERE priority IN ('high', 'medium')
           AND reflection_id NOT IN (
               SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
           )
           AND (scope IS NULL OR scope = '' OR LOWER(scope) = ?1)
         GROUP BY directive"
    } else {
        "SELECT directive,
                MIN(priority) AS priority,
                MAX(scope) AS scope
         FROM chump_improvement_targets
         WHERE priority IN ('high', 'medium')
           AND reflection_id NOT IN (
               SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
           )
         GROUP BY directive"
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(_) => return load_relevant_lessons_semantic(query_text, max_n, domain),
    };

    struct Row {
        directive: String,
        priority: Priority,
        scope: Option<String>,
    }
    let row_mapper = |r: &rusqlite::Row| -> rusqlite::Result<Row> {
        let priority_str: String = r.get(1)?;
        Ok(Row {
            directive: r.get(0)?,
            priority: match priority_str.as_str() {
                "high" => Priority::High,
                "low" => Priority::Low,
                _ => Priority::Medium,
            },
            scope: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
        })
    };
    let rows: Vec<Row> = if use_domain_filter {
        match stmt.query_map(rusqlite::params![domain_norm], row_mapper) {
            Ok(it) => it.filter_map(|r| r.ok()).collect(),
            Err(_) => return load_relevant_lessons_semantic(query_text, max_n, domain),
        }
    } else {
        match stmt.query_map([], row_mapper) {
            Ok(it) => it.filter_map(|r| r.ok()).collect(),
            Err(_) => return load_relevant_lessons_semantic(query_text, max_n, domain),
        }
    };
    if rows.is_empty() {
        return Vec::new();
    }

    // Embed each directive. We embed serially (the Ollama instance is
    // single-machine and benefits zero from parallelism). Failures are
    // tolerated — directives that don't embed get score 0 and naturally
    // fall to the bottom.
    let mut scored: Vec<(f32, &Row)> = Vec::with_capacity(rows.len());
    let mut any_embedded = false;
    for row in &rows {
        let dvec = crate::lesson_embeddings::embed_text(&row.directive);
        let s = match dvec {
            Some(v) => {
                any_embedded = true;
                crate::lesson_embeddings::cosine_similarity_f32(&q_embed, &v)
            }
            None => 0.0,
        };
        scored.push((s, row));
    }
    if !any_embedded {
        return load_relevant_lessons_semantic(query_text, max_n, domain);
    }

    fn priority_rank(p: Priority) -> u8 {
        match p {
            Priority::High => 0,
            Priority::Medium => 1,
            Priority::Low => 2,
        }
    }
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| priority_rank(a.1.priority).cmp(&priority_rank(b.1.priority)))
    });

    let picks: Vec<ImprovementTarget> = scored
        .into_iter()
        .filter(|(s, _)| *s > 0.0)
        .take(max_n)
        .map(|(_, r)| ImprovementTarget {
            directive: r.directive.clone(),
            priority: r.priority,
            scope: r.scope.clone(),
            actioned_as: None,
        })
        .collect();

    if picks.is_empty() {
        // Embeddings ran but zero positive cosines — degenerate. Fall through.
        load_relevant_lessons_semantic(query_text, max_n, domain)
    } else {
        picks
    }
}

/// Best-effort: returns empty Vec if the DB is unreachable or empty.
pub fn load_relevant_lessons_semantic(
    query_text: &str,
    max_n: usize,
    domain: &str,
) -> Vec<ImprovementTarget> {
    use std::collections::HashMap;

    let max_n = max_n.min(SPAWN_LESSONS_MAX_N);
    if max_n == 0 {
        return Vec::new();
    }
    let query_tokens = tokenize(query_text);
    if query_tokens.is_empty() {
        // Nothing to score against — fall back to recency-frequency.
        return load_spawn_lessons(domain, max_n);
    }

    let conn = match open_db() {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let domain_norm = domain.trim().to_lowercase();
    let use_domain_filter =
        !domain_norm.is_empty() && domain_norm != "any" && domain_norm != "global";

    // Pull all eligible (directive, priority, scope) rows. We reuse the
    // load_spawn_lessons priority + ab_seed filters but skip the recency
    // ranking — semantic ranking happens in Rust below.
    let sql = if use_domain_filter {
        "SELECT directive,
                MIN(priority) AS priority,
                MAX(scope) AS scope
         FROM chump_improvement_targets
         WHERE priority IN ('high', 'medium')
           AND reflection_id NOT IN (
               SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
           )
           AND (scope IS NULL OR scope = '' OR LOWER(scope) = ?1)
         GROUP BY directive"
    } else {
        "SELECT directive,
                MIN(priority) AS priority,
                MAX(scope) AS scope
         FROM chump_improvement_targets
         WHERE priority IN ('high', 'medium')
           AND reflection_id NOT IN (
               SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
           )
         GROUP BY directive"
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    // Collect (directive, priority, scope) into a vec we'll re-tokenize.
    struct Row {
        directive: String,
        priority: Priority,
        scope: Option<String>,
    }
    let row_mapper = |r: &rusqlite::Row| -> rusqlite::Result<Row> {
        let priority_str: String = r.get(1)?;
        Ok(Row {
            directive: r.get(0)?,
            priority: match priority_str.as_str() {
                "high" => Priority::High,
                "low" => Priority::Low,
                _ => Priority::Medium,
            },
            scope: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
        })
    };

    let rows: Vec<Row> = if use_domain_filter {
        match stmt.query_map(rusqlite::params![domain_norm], row_mapper) {
            Ok(it) => it.filter_map(|r| r.ok()).collect(),
            Err(_) => return Vec::new(),
        }
    } else {
        match stmt.query_map([], row_mapper) {
            Ok(it) => it.filter_map(|r| r.ok()).collect(),
            Err(_) => return Vec::new(),
        }
    };

    if rows.is_empty() {
        return Vec::new();
    }

    // Build IDF over the corpus.
    let total_docs = rows.len() as f64;
    let mut df: HashMap<String, usize> = HashMap::new();
    let docs_tokens: Vec<Vec<String>> = rows
        .iter()
        .map(|r| {
            let toks = tokenize(&r.directive);
            // Each unique term in this doc gets +1 to its document frequency.
            let unique: std::collections::HashSet<&String> = toks.iter().collect();
            for t in unique {
                *df.entry(t.clone()).or_insert(0) += 1;
            }
            toks
        })
        .collect();

    // IDF = ln(1 + N / (1 + df)). Smoothed to avoid division-by-zero
    // and to keep terms that appear in every doc from going to 0.
    let idf: HashMap<String, f64> = df
        .into_iter()
        .map(|(term, df_count)| {
            let v: f64 = 1.0_f64 + total_docs / (1.0_f64 + df_count as f64);
            (term, v.ln())
        })
        .collect();

    // Build query vector + score each doc.
    let q_vec = tfidf_vector(&query_tokens, &idf);
    let mut scored: Vec<(f64, &Row)> = rows
        .iter()
        .zip(docs_tokens.iter())
        .map(|(row, toks)| {
            let v = tfidf_vector(toks, &idf);
            (cosine_similarity(&q_vec, &v), row)
        })
        .collect();

    // Sort desc by similarity; tiebreak by priority (high > medium > low).
    fn priority_rank(p: Priority) -> u8 {
        match p {
            Priority::High => 0,
            Priority::Medium => 1,
            Priority::Low => 2,
        }
    }
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| priority_rank(a.1.priority).cmp(&priority_rank(b.1.priority)))
    });

    // Drop zero-similarity rows so we don't fill the lesson slot with
    // pure-noise picks. If everything scored 0, return empty (caller
    // can fall back to load_spawn_lessons).
    scored
        .into_iter()
        .filter(|(s, _)| *s > 0.0)
        .take(max_n)
        .map(|(_, r)| ImprovementTarget {
            directive: r.directive.clone(),
            priority: r.priority,
            scope: r.scope.clone(),
            actioned_as: None,
        })
        .collect()
}

/// COG-011d variant (b): when ON, only inject lessons whose `scope` exactly
/// matches the current `tool_hint`. Excludes the universal (NULL-scope)
/// lessons that get returned by default. Tests the hypothesis that
/// "irrelevant lessons act as noise" — if true, strict-scope mode should
/// recover some of the -0.30 gotcha penalty seen in COG-011b.
///
/// Default OFF (current behavior — universal lessons surface for every prompt).
pub fn reflection_strict_scope_enabled() -> bool {
    matches!(
        std::env::var("CHUMP_REFLECTION_STRICT_SCOPE").as_deref(),
        Ok("1") | Ok("true") | Ok("on")
    )
}

/// Persist a Reflection plus its improvement targets in a single transaction.
/// Returns the new reflection_id. On any error, the whole insert rolls back.
pub fn save_reflection(reflection: &Reflection, task_id: Option<i64>) -> Result<i64> {
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO chump_reflections (
            episode_id, task_id, intended_goal, observed_outcome,
            outcome_class, error_pattern, hypothesis,
            surprisal_at_reflect, confidence_at_reflect
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
            reflection.episode_id,
            task_id,
            reflection.intended_goal,
            reflection.observed_outcome,
            reflection.outcome_class.as_str(),
            reflection.error_pattern.map(|p| p.as_str()),
            reflection.hypothesis,
            reflection.surprisal_at_reflect,
            reflection.confidence_at_reflect,
        ],
    )?;
    let reflection_id = tx.last_insert_rowid();
    for target in &reflection.improvements {
        tx.execute(
            "INSERT INTO chump_improvement_targets (
                reflection_id, directive, priority, scope, actioned_as
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                reflection_id,
                target.directive,
                target.priority.as_str(),
                target.scope,
                target.actioned_as,
            ],
        )?;
    }
    tx.commit()?;
    Ok(reflection_id)
}

/// Load the most-recent high+medium priority improvement targets, capped at `limit`.
///
/// `scope_filter`:
///   - `Some(scope)` + `CHUMP_REFLECTION_STRICT_SCOPE=1` → exact scope matches only
///     (no NULL-scope universal lessons). The COG-011d variant (b) test path.
///   - `Some(scope)` + default → exact match OR NULL/empty scope (universal lessons
///     ride along). Original COG-007 behavior.
///   - `None` + `CHUMP_REFLECTION_STRICT_SCOPE=1` → return empty (no signal to
///     filter on, strict mode refuses to inject noise).
///   - `None` + default → all high+medium-priority targets regardless of scope.
///
/// Order: priority DESC (high → medium), then created_at DESC (freshest wins).
/// Low-priority targets are never returned — they exist for analytics only.
pub fn load_recent_high_priority_targets(
    limit: usize,
    scope_filter: Option<&str>,
) -> Result<Vec<ImprovementTarget>> {
    let conn = open_db()?;
    let limit = limit.min(20);
    let strict = reflection_strict_scope_enabled();

    let rows: Vec<ImprovementTarget> = match (scope_filter, strict) {
        (Some(scope), true) => {
            // Strict: exact scope match only. No NULL/empty scope catch-all.
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND scope = ?1
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?2";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
        (Some(scope), false) => {
            // Default: exact scope match OR NULL/empty (universal).
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND (scope IS NULL OR scope = '' OR scope = ?1)
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?2";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
        (None, true) => {
            // Strict + no signal → return empty. Caller's lesson block stays empty,
            // matching the COG-011b "lessons hurt when injected indiscriminately" finding.
            Vec::new()
        }
        (None, false) => {
            // No filter: all high/medium targets.
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?1";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
    };
    Ok(rows)
}

fn row_from_target(r: &rusqlite::Row) -> Result<ImprovementTarget, rusqlite::Error> {
    let priority_str: String = r.get(1)?;
    let priority = match priority_str.as_str() {
        "high" => Priority::High,
        "low" => Priority::Low,
        _ => Priority::Medium,
    };
    Ok(ImprovementTarget {
        directive: r.get(0)?,
        priority,
        scope: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
        actioned_as: r.get::<_, Option<String>>(3)?.filter(|s| !s.is_empty()),
    })
}

// ---------------------------------------------------------------------------
// EVAL-030: Task-class-aware lessons gating
// ---------------------------------------------------------------------------
//
// EVAL-029 mechanism analysis (docs/eval/EVAL-029-neuromod-task-drilldown.md)
// showed the v1 lessons block hurts the neuromod fixture by 10–16 pp on
// `is_correct` across 4 models. The harm concentrates in two task classes:
//
//   1. **Conditional-chain prompts** ("do X, if it fails do Y, then if Y fails
//      do Z") — the perception directive "ask one clarifying question rather
//      than guessing" causes early-stopping on multi-step chains. Suppress
//      that specific directive when the user prompt contains 2+ conditional
//      markers or an explicit step-numbered chain.
//
//   2. **Monosyllabic chat tokens** (`lol`, `sup`, `k thx`) — the lessons
//      block dwarfs the prompt and the agent over-formalizes the response.
//      Skip the entire block when the prompt is shorter than 30 chars.
//
// Both detectors are pure heuristics over the raw user prompt — no LLM call,
// no DB read. Default ON; `CHUMP_LESSONS_TASK_AWARE=0` disables the gating
// so harness sweeps can re-measure the v1 baseline.

/// Returns true when the prompt looks like a multi-step conditional chain
/// (2+ conditional markers OR explicit step-numbered sequence). On these
/// tasks the perception "ask one clarifying question" directive harms
/// outcomes by triggering early-stopping mid-chain.
pub fn is_conditional_chain(prompt: &str) -> bool {
    let lc = prompt.to_lowercase();
    let cond_markers = [
        "if it fails",
        "if that fails",
        "then if",
        "else if",
        "if not",
    ];
    let cond_count = cond_markers.iter().filter(|m| lc.contains(*m)).count();
    let step_pattern = lc.contains("step 1") && lc.contains("step 2");
    cond_count >= 2 || step_pattern
}

/// Returns true when the prompt is a trivial chat token (under 30 chars
/// trimmed). On these the lessons block dwarfs the actual input and the
/// agent over-formalizes — best to skip lessons entirely.
pub fn is_trivial_token(prompt: &str) -> bool {
    prompt.trim().len() < 30
}

/// Whether EVAL-030 task-class-aware lessons gating is active. Default ON;
/// set `CHUMP_LESSONS_TASK_AWARE=0` to restore the v1-uniform behavior for
/// A/B harness sweeps.
pub fn task_aware_lessons_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_LESSONS_TASK_AWARE")
            .unwrap_or_default()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

/// Heuristic: does this directive read like the perception "ask one
/// clarifying question" line that EVAL-029 identified as harmful on
/// conditional-chain tasks? We match on the substring rather than equality
/// so paraphrases survive (e.g. "ask a clarifying question first").
fn is_perception_clarify_directive(directive: &str) -> bool {
    let lc = directive.to_lowercase();
    lc.contains("clarifying question") || lc.contains("clarify") && lc.contains("ambig")
}

/// Render a list of improvement targets as a system-prompt block. Returns
/// empty string when input is empty so callers can `if !block.is_empty()` cheaply.
///
/// Format chosen for low-distraction injection: short header, bullet list,
/// priority and scope inlined when present. Designed to be appended to the
/// existing system prompt, not to replace any task-planner block.
pub fn format_lessons_block(targets: &[ImprovementTarget]) -> String {
    format_lessons_block_with_prompt(targets, None)
}

/// EVAL-030: variant of [`format_lessons_block`] that accepts the raw user
/// prompt for task-class-aware suppression. When `user_prompt` is `Some` and
/// `task_aware_lessons_enabled()` is true:
///
/// * trivial-token prompts → return empty string (skip the block entirely)
/// * conditional-chain prompts → filter out the perception "ask one
///   clarifying question" directive (the rest of the block still renders)
///
/// `user_prompt = None` and `CHUMP_LESSONS_TASK_AWARE=0` both fall through
/// to the legacy uniform behavior.
pub fn format_lessons_block_with_prompt(
    targets: &[ImprovementTarget],
    user_prompt: Option<&str>,
) -> String {
    // EVAL-030 gating — runs only when caller passes a prompt and the env
    // var hasn't disabled the feature.
    let filtered: Vec<ImprovementTarget>;
    let effective_targets: &[ImprovementTarget] = match user_prompt {
        Some(p) if task_aware_lessons_enabled() => {
            if is_trivial_token(p) {
                // Skip the entire block on monosyllabic chat — EVAL-029 row 4–13.
                return String::new();
            }
            if is_conditional_chain(p) {
                // Drop the harmful perception directive only; keep the rest.
                filtered = targets
                    .iter()
                    .filter(|t| !is_perception_clarify_directive(&t.directive))
                    .cloned()
                    .collect();
                &filtered[..]
            } else {
                targets
            }
        }
        _ => targets,
    };
    if effective_targets.is_empty() {
        return String::new();
    }
    let targets = effective_targets;
    // COG-016: explicit anti-hallucination guardrail prepended to the lessons
    // header. The n=100 sweep showed the original block (without this line)
    // reliably increased fake-tool-call emission by +0.14 on weak agents
    // (haiku-4-5, n=600 trials, p<0.05 across 3 fixtures). The directive
    // tells the model NOT to emit fake tool-call markup when it has no
    // actual tool access — addressing the failure mode observed in the
    // forensic in docs/research/CONSCIOUSNESS_AB_RESULTS.md.
    let mut out = String::from(
        "## Lessons from prior episodes\n\
         The following directives came from structured reflections on previous tasks. \
         Apply them when relevant; do not narrate that you are applying them.\n\
         \n\
         IMPORTANT: if you do not have actual tool access in this context, do NOT \
         emit `<function_calls>`, `<tool_call>`, `<tool_use>`, or similar markup. \
         Instead, describe in plain prose what you would do if tools were available, \
         and acknowledge that you cannot execute commands directly.\n",
    );
    for t in targets {
        let scope = match &t.scope {
            Some(s) if !s.is_empty() => format!(" [{}]", s),
            _ => String::new(),
        };
        out.push_str(&format!(
            "- ({}){} {}\n",
            t.priority.as_str(),
            scope,
            t.directive
        ));
    }
    out
}

// ---------------------------------------------------------------------------
// COG-014: AB harness lesson seeding
// ---------------------------------------------------------------------------

/// A single authored directive for AB harness seeding.
#[derive(Debug, serde::Deserialize)]
pub struct SeedDirective {
    pub directive: String,
    /// "high" | "medium" | "low"
    pub priority: String,
    pub scope: Option<String>,
}

/// JSON structure for a domain lesson seed file.
#[derive(Debug, serde::Deserialize)]
pub struct LessonSeedFile {
    pub domain: String,
    pub directives: Vec<SeedDirective>,
}

/// Tag written to `error_pattern` for AB-seeded reflections so they can be
/// deleted cleanly without touching real reflections.
const AB_SEED_TAG_PREFIX: &str = "ab_seed:";

/// Remove all AB-seeded reflections and their associated improvement targets,
/// and also remove causal lessons seeded for AB testing.
/// Returns the number of rows deleted from `chump_reflections`.
///
/// Explicitly deletes from `chump_improvement_targets` first because SQLite
/// FK enforcement (`PRAGMA foreign_keys`) is off by default, so `ON DELETE
/// CASCADE` does not fire automatically.
pub fn clear_ab_seed_lessons() -> Result<usize> {
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    // Delete orphaned targets first — FK cascade may not be active.
    tx.execute(
        "DELETE FROM chump_improvement_targets \
         WHERE reflection_id IN ( \
             SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%' \
         )",
        [],
    )?;
    let deleted = tx.execute(
        "DELETE FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'",
        [],
    )?;
    // Also clear causal lessons seeded for AB testing (task_type = 'ab_seed').
    tx.execute(
        "DELETE FROM chump_causal_lessons WHERE task_type = 'ab_seed'",
        [],
    )?;
    tx.commit()?;
    Ok(deleted)
}

/// Seed domain-specific lessons into `chump_reflections` + `chump_improvement_targets`
/// AND into `chump_causal_lessons` for use by the A/B harness.
///
/// The improvement-targets path is gated only by reflection injection (not consciousness).
/// The causal-lessons path (`task_type = 'ab_seed'`) is the consciousness-gated path
/// used by `find_relevant_lessons` as a fallback when keyword matching returns nothing.
/// Creates a single parent reflection tagged with `error_pattern = 'ab_seed:<domain>'`
/// so it can be cleared later.
///
/// Returns the number of directives inserted.
pub fn seed_ab_lessons(domain: &str, directives: &[SeedDirective]) -> Result<usize> {
    if directives.is_empty() {
        return Ok(0);
    }
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO chump_reflections (
            intended_goal, observed_outcome, outcome_class, error_pattern, hypothesis
         ) VALUES (?1, 'seeded', 'ab_seed', ?2, ?3)",
        rusqlite::params![
            format!("AB harness seed — {domain}"),
            format!("{AB_SEED_TAG_PREFIX}{domain}"),
            format!("Task-specific lessons for {domain} domain A/B testing"),
        ],
    )?;
    let reflection_id = tx.last_insert_rowid();

    let mut count = 0usize;
    for d in directives {
        tx.execute(
            "INSERT INTO chump_improvement_targets (reflection_id, directive, priority, scope)
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![reflection_id, d.directive, d.priority, d.scope],
        )?;
        // Also seed into chump_causal_lessons so the consciousness-gated
        // lessons_for_context_with_ids() path can find them via the ab_seed fallback.
        tx.execute(
            "INSERT INTO chump_causal_lessons (task_type, action_taken, lesson, confidence)
             VALUES ('ab_seed', ?1, ?2, 0.95)",
            rusqlite::params![d.scope.as_deref().unwrap_or(""), d.directive],
        )?;
        count += 1;
    }
    tx.commit()?;
    Ok(count)
}

/// Load a [`LessonSeedFile`] from a JSON path and seed it into the DB.
/// Convenience wrapper used by the `--seed-ab-lessons` CLI.
pub fn seed_ab_lessons_from_file(path: &std::path::Path) -> Result<usize> {
    let content = std::fs::read_to_string(path)?;
    let seed: LessonSeedFile = serde_json::from_str(&content)?;
    seed_ab_lessons(&seed.domain, &seed.directives)
}

/// Count of `chump_reflections` rows grouped by `outcome_class`
/// (pass/partial/failure/abandoned). Used by `chump brain status`
/// (INFRA-1773) for a fleet-wide reflection-store summary.
pub fn outcome_class_counts() -> Result<Vec<(String, i64)>> {
    let conn = open_db()?;
    let mut stmt = conn.prepare(
        "SELECT outcome_class, COUNT(*) FROM chump_reflections GROUP BY outcome_class ORDER BY COUNT(*) DESC",
    )?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// One row summary for `chump brain query reflections`. Kept separate from
/// the full [`Reflection`] struct (which also carries improvements + a task
/// link) because the CLI listing only needs enough to identify + skim rows.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ReflectionBrief {
    pub id: i64,
    pub outcome_class: String,
    pub intended_goal: String,
    pub created_at: String,
}

/// Most recent reflections (any outcome class), newest first, capped at
/// `limit` (hard cap 200 to keep the CLI listing bounded).
pub fn recent_reflections_brief(limit: usize) -> Result<Vec<ReflectionBrief>> {
    let conn = open_db()?;
    let limit = limit.min(200);
    let mut stmt = conn.prepare(
        "SELECT id, outcome_class, intended_goal, created_at
         FROM chump_reflections
         ORDER BY created_at DESC, id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(rusqlite::params![limit as i64], |r| {
        Ok(ReflectionBrief {
            id: r.get(0)?,
            outcome_class: r.get(1)?,
            intended_goal: r.get(2)?,
            created_at: r.get(3)?,
        })
    })?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    //! Tests use a temp DB root so they never touch the user's real chump_memory.db.
    //! `serial(reflection_db)` because all tests share the same TEST_DB_ROOT
    //! thread-local — running them in parallel would interleave inserts.

    use super::*;
    use serial_test::serial;

    /// Per-test fresh DB root. Uses uuid like episode_db tests so concurrent
    /// runs (or repeated runs after failure) never collide.
    fn fresh_test_root() {
        let dir = std::env::temp_dir().join(format!(
            "chump_reflection_db_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        set_test_db_root(Some(dir));
    }

    fn sample_reflection(directive: &str, priority: Priority, scope: Option<&str>) -> Reflection {
        Reflection {
            id: None,
            episode_id: None,
            intended_goal: "test goal".into(),
            observed_outcome: "test outcome".into(),
            outcome_class: OutcomeClass::Failure,
            error_pattern: Some(ErrorPattern::ToolMisuse),
            improvements: vec![ImprovementTarget {
                directive: directive.into(),
                priority,
                scope: scope.map(String::from),
                actioned_as: None,
            }],
            hypothesis: "test hypothesis".into(),
            surprisal_at_reflect: Some(0.5),
            confidence_at_reflect: Some(0.7),
            created_at: "2026-04-17T00:00:00Z".into(),
        }
    }

    #[test]
    #[serial(reflection_db)]
    fn save_then_load_returns_high_priority_first() {
        fresh_test_root();
        let mut low = sample_reflection("low priority lesson", Priority::Low, None);
        // Tag a low-priority target — it must NOT appear in load.
        low.improvements[0].priority = Priority::Low;
        save_reflection(&low, Some(1)).expect("test invariant");

        let med = sample_reflection("medium lesson", Priority::Medium, None);
        save_reflection(&med, Some(2)).expect("test invariant");

        let high = sample_reflection("HIGH urgency lesson", Priority::High, None);
        save_reflection(&high, Some(3)).expect("test invariant");

        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert_eq!(targets.len(), 2, "low-priority must be filtered out");
        assert_eq!(targets[0].directive, "HIGH urgency lesson");
        assert_eq!(targets[0].priority, Priority::High);
        assert_eq!(targets[1].directive, "medium lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn scope_filter_includes_null_scope_targets() {
        fresh_test_root();
        // Universal lesson (no scope) — must always surface.
        save_reflection(
            &sample_reflection("universal lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        // Tool-scoped lesson — surfaces only when scope matches.
        save_reflection(
            &sample_reflection("patch-specific lesson", Priority::High, Some("patch_file")),
            None,
        )
        .expect("test invariant");
        // Different-tool lesson — must NOT surface for patch_file scope.
        save_reflection(
            &sample_reflection("git-specific lesson", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        let targets =
            load_recent_high_priority_targets(10, Some("patch_file")).expect("test invariant");
        let directives: Vec<_> = targets.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"universal lesson"));
        assert!(directives.contains(&"patch-specific lesson"));
        assert!(
            !directives.contains(&"git-specific lesson"),
            "scope filter must exclude other tools' lessons"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn save_persists_all_typed_fields_roundtrip() {
        fresh_test_root();
        let r = sample_reflection(
            "verify file exists before patch",
            Priority::High,
            Some("patch_file"),
        );
        let id = save_reflection(&r, Some(42)).expect("test invariant");
        assert!(id > 0);

        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert_eq!(targets.len(), 1);
        let t = &targets[0];
        assert_eq!(t.directive, "verify file exists before patch");
        assert_eq!(t.priority, Priority::High);
        assert_eq!(t.scope.as_deref(), Some("patch_file"));
    }

    #[test]
    #[serial(reflection_db)]
    fn load_with_no_data_returns_empty() {
        fresh_test_root();
        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert!(targets.is_empty());
    }

    #[test]
    #[serial(reflection_db)]
    fn limit_respected() {
        fresh_test_root();
        for i in 0..5 {
            save_reflection(
                &sample_reflection(&format!("lesson {}", i), Priority::High, None),
                None,
            )
            .expect("test invariant");
        }
        let targets = load_recent_high_priority_targets(3, None).expect("test invariant");
        assert_eq!(targets.len(), 3);
    }

    #[test]
    #[serial(reflection_db)]
    fn reflection_injection_default_on() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        assert!(reflection_injection_enabled());
    }

    #[test]
    #[serial(reflection_db)]
    fn reflection_injection_off_via_env() {
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "0");
        assert!(!reflection_injection_enabled());
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "false");
        assert!(!reflection_injection_enabled());
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "off");
        assert!(!reflection_injection_enabled());
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
    }

    // ── COG-011d variant (b): strict-scope mode ──────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_default_off() {
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
        assert!(!reflection_strict_scope_enabled());
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_on_via_env() {
        for v in ["1", "true", "on"] {
            std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", v);
            assert!(reflection_strict_scope_enabled(), "expected on for {v}");
        }
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_excludes_universal_lessons() {
        // Default (non-strict) returns BOTH a NULL-scope lesson and a
        // patch_file-scoped one when filter is "patch_file". Strict mode
        // returns ONLY the exact match.
        fresh_test_root();
        save_reflection(
            &sample_reflection("universal directive", Priority::High, None),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection(
                "patch-specific directive",
                Priority::High,
                Some("patch_file"),
            ),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("git-specific directive", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
        let lax =
            load_recent_high_priority_targets(10, Some("patch_file")).expect("test invariant");
        let lax_directives: Vec<_> = lax.iter().map(|t| t.directive.as_str()).collect();
        assert!(lax_directives.contains(&"universal directive"));
        assert!(lax_directives.contains(&"patch-specific directive"));
        assert!(!lax_directives.contains(&"git-specific directive"));

        std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", "1");
        let strict =
            load_recent_high_priority_targets(10, Some("patch_file")).expect("test invariant");
        let strict_directives: Vec<_> = strict.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(
            strict_directives,
            vec!["patch-specific directive"],
            "strict mode must exclude universal AND off-scope lessons"
        );
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_with_no_filter_returns_empty() {
        // Strict mode + no scope hint → nothing to filter on, so refuse to
        // inject. The "noise reduction" hypothesis behind COG-011d (b).
        fresh_test_root();
        save_reflection(&sample_reflection("any lesson", Priority::High, None), None)
            .expect("test invariant");
        save_reflection(
            &sample_reflection("scoped lesson", Priority::High, Some("patch_file")),
            None,
        )
        .expect("test invariant");

        std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", "1");
        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert!(
            targets.is_empty(),
            "strict mode + None filter should return []"
        );
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn format_lessons_block_empty_returns_empty_string() {
        // Pure function — no DB needed. Cheap regression guard so the
        // assembler can `if !block.is_empty()` without surprise newlines.
        let s = format_lessons_block(&[]);
        assert!(s.is_empty());
    }

    // ── COG-014: AB seed helpers ────────────��─────────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn seed_ab_lessons_inserts_and_clears() {
        fresh_test_root();
        let directives = vec![
            SeedDirective {
                directive: "entity lesson one".into(),
                priority: "high".into(),
                scope: Some("perception".into()),
            },
            SeedDirective {
                directive: "entity lesson two".into(),
                priority: "medium".into(),
                scope: Some("perception".into()),
            },
        ];
        let count = seed_ab_lessons("perception", &directives).expect("test invariant");
        assert_eq!(count, 2);

        // Seeded rows land in chump_improvement_targets, but are intentionally
        // excluded from the prompt-assembly path — load_recent_high_priority_targets
        // filters out reflection_ids tagged `ab_seed:*`.  Verify presence via a
        // direct count rather than going through the prompt-assembly query.
        {
            let conn = open_db().expect("test invariant");
            let it_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM chump_improvement_targets WHERE scope = 'perception'",
                    [],
                    |row| row.get(0),
                )
                .expect("test invariant");
            assert_eq!(
                it_count, 2,
                "two directives stored in chump_improvement_targets"
            );

            // The consciousness-gated path (chump_causal_lessons) also gets them.
            let cl_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM chump_causal_lessons WHERE task_type = 'ab_seed'",
                    [],
                    |row| row.get(0),
                )
                .expect("test invariant");
            assert_eq!(cl_count, 2, "two lessons stored in chump_causal_lessons");
        }
        // Confirm ab_seed rows do NOT bleed through to prompt assembly.
        let visible =
            load_recent_high_priority_targets(10, Some("perception")).expect("test invariant");
        assert!(
            visible.is_empty(),
            "ab_seed rows must be excluded from prompt-assembly path"
        );

        // Clearing removes them without touching other data.
        let deleted = clear_ab_seed_lessons().expect("test invariant");
        assert_eq!(deleted, 1, "one parent reflection row deleted");

        let after = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert!(after.is_empty(), "all seeded targets gone after clear");
    }

    #[test]
    #[serial(reflection_db)]
    fn seed_ab_lessons_empty_slice_is_noop() {
        fresh_test_root();
        let count = seed_ab_lessons("perception", &[]).expect("test invariant");
        assert_eq!(count, 0);
    }

    #[test]
    #[serial(reflection_db)]
    fn clear_ab_seed_lessons_zero_when_nothing_seeded() {
        fresh_test_root();
        let deleted = clear_ab_seed_lessons().expect("test invariant");
        assert_eq!(deleted, 0);
    }

    #[test]
    #[serial(reflection_db)]
    fn clear_does_not_remove_real_reflections() {
        fresh_test_root();
        // Save a real reflection.
        save_reflection(
            &sample_reflection("real lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        // Seed an AB lesson.
        seed_ab_lessons(
            "neuromod",
            &[SeedDirective {
                directive: "calibrate confidence".into(),
                priority: "high".into(),
                scope: Some("neuromod".into()),
            }],
        )
        .expect("test invariant");

        // Clearing removes only the seeded one.
        let deleted = clear_ab_seed_lessons().expect("test invariant");
        assert_eq!(deleted, 1);

        let remaining = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].directive, "real lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn format_lessons_block_renders_priority_and_scope() {
        let targets = vec![
            ImprovementTarget {
                directive: "verify before patch".into(),
                priority: Priority::High,
                scope: Some("patch_file".into()),
                actioned_as: None,
            },
            ImprovementTarget {
                directive: "ask clarifying questions when ambiguous".into(),
                priority: Priority::Medium,
                scope: None,
                actioned_as: None,
            },
        ];
        let s = format_lessons_block(&targets);
        assert!(s.contains("## Lessons from prior episodes"));
        assert!(s.contains("(high) [patch_file] verify before patch"));
        assert!(s.contains("(medium) ask clarifying questions"));
    }

    // ── COG-016: model-tier-aware lessons injection ──────────────────────

    #[test]
    fn model_tier_classifies_frontier_correctly() {
        // COG-023: sonnet entries removed — they now classify as ModelTier::Sonnet
        // (see model_tier_classifies_sonnet_correctly below).
        for m in &[
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-opus-4-5",
            "claude-3-5-haiku-20241022",
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-5",
            "o1-preview",
            "o3-mini",
            "gemini-1.5-pro",
            "gemini-2.0-flash",
            "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo",
            "meta-llama/Meta-Llama-3.1-405B-Instruct",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Frontier,
                "expected Frontier for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_classifies_sonnet_correctly() {
        // COG-023: any model id containing "sonnet" (case-insensitive) classifies
        // as Sonnet — carved out from Frontier because the COG-016 directive
        // backfires on it (EVAL-027c, 33% fake-tool emission, n=100).
        for m in &[
            "claude-sonnet-4-5",
            "claude-sonnet-4-5-20250101",
            "claude-sonnet-4",
            "claude-3-5-sonnet-20241022",
            "claude-3-5-Sonnet-20241022", // case-insensitive
            "anthropic/claude-sonnet-4-5",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Sonnet,
                "expected Sonnet for {}",
                m
            );
        }

        // Negative controls: opus and haiku must NOT classify as Sonnet.
        assert_eq!(model_tier("claude-opus-4-5"), ModelTier::Frontier);
        assert_eq!(model_tier("claude-haiku-4-5"), ModelTier::Frontier);
    }

    #[test]
    fn model_tier_classifies_capable_correctly() {
        for m in &[
            "qwen2.5:14b",
            "ollama:qwen2.5-14b",
            "qwen3:14b",
            "qwen3:32b",
            "qwen2.5:32b",
            "gpt-oss:20b",
            "gemini-1.5-flash",
            "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Capable,
                "expected Capable for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_classifies_small_correctly() {
        for m in &[
            "llama3.2:1b",
            "llama3.2:3b",
            "qwen2.5:7b",
            "qwen3:8b",
            "qwen3:7b",
        ] {
            assert_eq!(model_tier(m), ModelTier::Small, "expected Small for {}", m);
        }
    }

    #[test]
    fn model_tier_unknown_for_unrecognized() {
        for m in &["", "foo-bar-baz", "mistral-7b", "phi-3-mini"] {
            assert_eq!(
                model_tier(m),
                ModelTier::Unknown,
                "expected Unknown for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_ord_is_correct() {
        // Used by lessons_enabled_for_model: tier >= min_tier check.
        // COG-023: full chain is Unknown < Small < Capable < Sonnet < Frontier.
        assert!(ModelTier::Frontier > ModelTier::Sonnet);
        assert!(ModelTier::Sonnet > ModelTier::Capable);
        assert!(ModelTier::Capable > ModelTier::Small);
        assert!(ModelTier::Small > ModelTier::Unknown);
        // The full chain
        assert!(ModelTier::Frontier > ModelTier::Unknown);
        // Sonnet specifically must sit BELOW Frontier so default
        // CHUMP_LESSONS_MIN_TIER=frontier excludes it (the COG-023 fix).
        assert!(ModelTier::Sonnet < ModelTier::Frontier);
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_default_is_none_post_cog024() {
        // COG-024: default flipped from Some(Frontier) to None. Lessons OFF
        // by default; opt-in per model via CHUMP_LESSONS_OPT_IN_MODELS.
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        assert_eq!(min_tier_for_lessons(), None);
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_none_disables_gating() {
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "off");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "disabled");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_explicit_values_parse() {
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "small");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Small));
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Capable));
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "FRONTIER"); // case insensitive
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Frontier));
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_default_off_post_cog024() {
        // COG-024: with neither CHUMP_LESSONS_MIN_TIER nor
        // CHUMP_LESSONS_OPT_IN_MODELS set, EVERY model is off — including
        // former Frontier defaults. Lessons require explicit opt-in now.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(!lessons_enabled_for_model("claude-opus-4-5"));
        assert!(!lessons_enabled_for_model("gpt-4o"));
        assert!(!lessons_enabled_for_model("qwen2.5:14b"));
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));
        assert!(!lessons_enabled_for_model("foo-unknown"));
        assert!(!lessons_enabled_for_model(""));
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_capable_min() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");

        assert!(lessons_enabled_for_model("claude-haiku-4-5")); // Frontier >= Capable
        assert!(lessons_enabled_for_model("qwen2.5:14b")); // Capable >= Capable
        assert!(!lessons_enabled_for_model("qwen2.5:7b")); // Small < Capable
        assert!(!lessons_enabled_for_model("foo-unknown")); // Unknown still off

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_none_means_off_post_cog024() {
        // COG-024 semantic flip: `none` no longer means "preserve legacy
        // behavior of always-on" — it now collapses to default OFF (same as
        // unset). The opt-in CSV is the only way to enable injection.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");

        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));
        assert!(!lessons_enabled_for_model("foo-unknown"));

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_kill_switch_still_works() {
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "0");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-haiku-4-5:cog016");

        // Kill-switch wins over EVERYTHING — both tier and opt-in CSV.
        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));

        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    // ── COG-023: Sonnet carve-out from cog016 directive injection ────────

    #[test]
    #[serial(reflection_db)]
    fn cog023_sonnet_excluded_at_default_and_at_frontier_tier() {
        // EVAL-027c CONFIRMED: the COG-016 directive triggers ~33% fake-tool
        // emission per response on sonnet-4-5 (n=100, non-overlapping CIs).
        // Sonnet must be off (a) by default per COG-024 and (b) when tier
        // gate is at frontier (Sonnet < Frontier).
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        // (a) COG-024 default: nothing set → off everywhere including sonnet.
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5"));

        // (b) Legacy MIN_TIER=frontier path: sonnet still excluded by COG-023.
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");
        assert!(
            !lessons_enabled_for_model("claude-sonnet-4-5"),
            "sonnet-4-5 must NOT receive injection at frontier tier — \
             COG-016 directive backfires per EVAL-027c"
        );
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5-20250101"));
        assert!(!lessons_enabled_for_model("claude-3-5-sonnet-20241022"));
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog023_sonnet_opt_in_at_capable_tier() {
        // Operators who explicitly want sonnet to receive lessons can
        // opt in by lowering CHUMP_LESSONS_MIN_TIER. Sonnet > Capable in
        // the ordering, so capable-tier minimum re-enables sonnet.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");

        assert!(
            lessons_enabled_for_model("claude-sonnet-4-5"),
            "sonnet-4-5 must receive injection when MIN_TIER=capable (opt-in)"
        );

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog023_haiku_off_by_default_post_cog024_but_on_via_opt_in() {
        // COG-024 supersedes COG-023 for the default behavior: haiku-4-5
        // no longer receives injection by default. It must be opted-in
        // explicitly via CHUMP_LESSONS_OPT_IN_MODELS.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        assert!(
            !lessons_enabled_for_model("claude-haiku-4-5"),
            "post-COG-024 default OFF — haiku-4-5 must NOT inject without opt-in"
        );

        // Opt-in re-enables it.
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-haiku-4-5:cog016");
        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog023_opus_off_by_default_post_cog024_but_on_via_opt_in() {
        // COG-024: opus-4-5 also defaults OFF now (was: ON via Frontier).
        // Per CONSCIOUSNESS_AB_RESULTS post-EVAL-027c, opus is in the
        // recommended opt-in list (cog016, partial fix).
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        assert!(!lessons_enabled_for_model("claude-opus-4-5"));

        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-opus-4-5:cog016");
        assert!(lessons_enabled_for_model("claude-opus-4-5"));
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    // ── COG-024: per-model opt-in via CHUMP_LESSONS_OPT_IN_MODELS ─────────

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_lookup_returns_variant() {
        std::env::set_var(
            "CHUMP_LESSONS_OPT_IN_MODELS",
            "claude-haiku-4-5:cog016,claude-opus-4-5:cog016",
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-haiku-4-5"),
            Some("cog016".to_string())
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-haiku-4-5-20251001"),
            Some("cog016".to_string()),
            "substring match must accept dated suffixes"
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-opus-4-5"),
            Some("cog016".to_string())
        );
        assert_eq!(lessons_opt_in_for_model("claude-sonnet-4-5"), None);
        assert_eq!(lessons_opt_in_for_model("qwen2.5:7b"), None);
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_unset_returns_none() {
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        assert_eq!(lessons_opt_in_for_model("claude-haiku-4-5"), None);
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_malformed_csv_handled_gracefully() {
        // Malformed entries (no colon, empty halves, stray commas) must be
        // skipped without panicking. The good entry should still match.
        std::env::set_var(
            "CHUMP_LESSONS_OPT_IN_MODELS",
            ",  , no-colon-here, :empty-id, empty-variant: ,claude-haiku-4-5:cog016,",
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-haiku-4-5"),
            Some("cog016".to_string())
        );
        assert_eq!(lessons_opt_in_for_model("no-colon-here"), None);
        assert_eq!(lessons_opt_in_for_model(""), None);
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_alone_enables_lessons() {
        // Tier gate unset (default None post-COG-024) but opt-in CSV names
        // haiku → injection ON for haiku, OFF for everything else.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-haiku-4-5:cog016");

        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(!lessons_enabled_for_model("claude-opus-4-5"));
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5"));
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));

        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_tier_gate_alone_still_works() {
        // Operators who already use CHUMP_LESSONS_MIN_TIER=frontier keep
        // working — the tier path is preserved as a secondary gate.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");

        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(lessons_enabled_for_model("claude-opus-4-5"));
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5")); // Sonnet < Frontier (COG-023)
        assert!(!lessons_enabled_for_model("qwen2.5:14b"));

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_and_tier_both_active_or_combine() {
        // Opt-in OR tier — either route enables. Test sonnet (excluded by
        // tier even at frontier) gets re-enabled if explicitly opted-in.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-sonnet-4-5:custom");

        // Tier path: haiku ON (Frontier ≥ Frontier).
        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        // Opt-in path overrides Sonnet's tier exclusion.
        assert!(lessons_enabled_for_model("claude-sonnet-4-5"));
        // Neither path: still off.
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    // ── INFRA-016: architecture-family deny-list ──────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn deny_list_default_blocks_deepseek() {
        // Default deny-list: "deepseek" — should block DeepSeek models.
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES");
        assert!(
            lessons_family_denied("deepseek-v3"),
            "default deny-list must block deepseek"
        );
        assert!(
            lessons_family_denied("DeepSeek-V3.1"),
            "matching must be case-insensitive"
        );
        assert!(!lessons_family_denied("claude-haiku-4-5"));
        assert!(!lessons_family_denied("qwen3-235b"));
    }

    #[test]
    #[serial(reflection_db)]
    fn deny_list_wins_over_opt_in() {
        // Even if DeepSeek is explicitly opted in, the deny-list must win.
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "1");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "deepseek-v3:cog016");
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES"); // use default "deepseek"

        assert!(
            !lessons_enabled_for_model("deepseek-v3"),
            "deny-list must win over opt-in"
        );
        // Anthropic model in same opt-in CSV is unaffected.
        std::env::set_var(
            "CHUMP_LESSONS_OPT_IN_MODELS",
            "deepseek-v3:cog016,claude-haiku-4-5:cog016",
        );
        assert!(
            lessons_enabled_for_model("claude-haiku-4-5"),
            "claude model must remain enabled"
        );

        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn deny_list_empty_allows_all() {
        // Operator can clear the deny-list with CHUMP_LESSONS_DENY_FAMILIES=""
        std::env::set_var("CHUMP_LESSONS_DENY_FAMILIES", "");
        assert!(!lessons_family_denied("deepseek-v3"));
        assert!(!lessons_family_denied("claude-haiku-4-5"));
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES");
    }

    // ── MEM-006: lessons-loaded-at-spawn ─────────────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn fleet049_spawn_lessons_n_unset_returns_default_n() {
        // FLEET-049: lessons default-ON — unset env → Some(SPAWN_LESSONS_DEFAULT_N)
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        assert_eq!(
            spawn_lessons_n(),
            Some(5),
            "lessons must be ON by default (FLEET-049)"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_n_parses_and_clamps() {
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "3");
        assert_eq!(spawn_lessons_n(), Some(3));
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "999");
        assert_eq!(spawn_lessons_n(), Some(20), "must clamp to MAX_N=20");
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "0");
        assert_eq!(spawn_lessons_n(), Some(0));
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "garbage");
        assert_eq!(
            spawn_lessons_n(),
            Some(5),
            "malformed value falls back to default 5"
        );
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_empty_db_returns_empty() {
        fresh_test_root();
        let lessons = load_spawn_lessons("", 5);
        assert!(lessons.is_empty());
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_respects_max_n() {
        fresh_test_root();
        for i in 0..10 {
            save_reflection(
                &sample_reflection(&format!("lesson {}", i), Priority::High, None),
                None,
            )
            .expect("test invariant");
        }
        // Use threshold=0.0: this test is about max_n capping, not quality filtering.
        let lessons = load_spawn_lessons_with_threshold("", 3, 0.0);
        assert_eq!(lessons.len(), 3);
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_zero_n_returns_empty() {
        fresh_test_root();
        save_reflection(&sample_reflection("any lesson", Priority::High, None), None)
            .expect("test invariant");
        let lessons = load_spawn_lessons("", 0);
        assert!(lessons.is_empty(), "max_n=0 must short-circuit to empty");
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_excludes_low_priority_and_ab_seed() {
        fresh_test_root();
        // High priority — must surface.
        save_reflection(
            &sample_reflection("real high lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        // Low priority — must NOT surface (consistent with per-task path).
        let mut low = sample_reflection("low priority lesson", Priority::Low, None);
        low.improvements[0].priority = Priority::Low;
        save_reflection(&low, None).expect("test invariant");
        // ab_seed — must NOT surface.
        seed_ab_lessons(
            "perception",
            &[SeedDirective {
                directive: "seeded lesson".into(),
                priority: "high".into(),
                scope: Some("perception".into()),
            }],
        )
        .expect("test invariant");

        // Use threshold=0.0: this test checks priority/seed exclusion, not quality filtering.
        let lessons = load_spawn_lessons_with_threshold("", 10, 0.0);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"real high lesson"));
        assert!(!directives.contains(&"low priority lesson"));
        assert!(!directives.contains(&"seeded lesson"));
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_ranks_frequent_recent_higher() {
        fresh_test_root();
        // "recurring lesson" appears 3 times — should outrank a one-off
        // even though all share the same created_at. Frequency dominates.
        for _ in 0..3 {
            save_reflection(
                &sample_reflection("recurring lesson", Priority::High, None),
                None,
            )
            .expect("test invariant");
        }
        save_reflection(
            &sample_reflection("one-off lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");

        // Use threshold=0.0: this test checks ranking by frequency, not quality filtering.
        let lessons = load_spawn_lessons_with_threshold("", 10, 0.0);
        // The recurring one must be first; both unique directives should
        // appear (GROUP BY collapses dupes).
        assert_eq!(lessons.len(), 2, "duplicates collapsed via GROUP BY");
        assert_eq!(lessons[0].directive, "recurring lesson");
        assert_eq!(lessons[1].directive, "one-off lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_domain_filter_includes_universal() {
        fresh_test_root();
        save_reflection(
            &sample_reflection("universal lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("patch-scoped lesson", Priority::High, Some("patch_file")),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("git-scoped lesson", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        // Use threshold=0.0: this test checks domain filtering, not quality filtering.
        let lessons = load_spawn_lessons_with_threshold("patch_file", 10, 0.0);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"universal lesson"));
        assert!(directives.contains(&"patch-scoped lesson"));
        assert!(
            !directives.contains(&"git-scoped lesson"),
            "off-domain lesson must be excluded"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_global_domain_returns_all() {
        fresh_test_root();
        save_reflection(
            &sample_reflection("a", Priority::High, Some("perception")),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("b", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        // Use threshold=0.0: this test checks global domain behaviour, not quality filtering.
        let lessons = load_spawn_lessons_with_threshold("global", 10, 0.0);
        assert_eq!(
            lessons.len(),
            2,
            "global/empty domain returns lessons regardless of scope"
        );
    }

    #[test]
    fn format_lessons_block_includes_anti_hallucination_directive() {
        let targets = vec![ImprovementTarget {
            directive: "do the thing".to_string(),
            priority: Priority::High,
            scope: None,
            actioned_as: None,
        }];
        let s = format_lessons_block(&targets);
        // The COG-016 anti-hallucination guardrail must appear in every
        // emitted block — it's the literal text that addresses the
        // documented hallucination failure mode.
        assert!(
            s.contains("do NOT") && s.contains("function_calls"),
            "block must contain anti-hallucination directive, got: {}",
            s
        );
    }

    // ── EVAL-030: task-class-aware lessons gating ────────────────────────

    fn make_targets() -> Vec<ImprovementTarget> {
        vec![
            ImprovementTarget {
                directive:
                    "If the user prompt is ambiguous, ask one clarifying question rather than guessing."
                        .into(),
                priority: Priority::High,
                scope: Some("perception".into()),
                actioned_as: None,
            },
            ImprovementTarget {
                directive: "verify file exists before patch_file".into(),
                priority: Priority::High,
                scope: Some("patch_file".into()),
                actioned_as: None,
            },
        ]
    }

    #[test]
    fn eval030_is_conditional_chain_matches_two_markers() {
        let p = "do X, if it fails do Y, then if Y fails do Z";
        assert!(is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_conditional_chain_matches_step_pattern() {
        let p = "Step 1: read foo. Step 2: write bar.";
        assert!(is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_conditional_chain_does_not_match_clean_prompt() {
        let p = "Summarize the design doc and propose three improvements.";
        assert!(!is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_conditional_chain_single_marker_does_not_match() {
        let p = "Run the tests and tell me if it fails.";
        assert!(!is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_trivial_token_matches_short_chat() {
        for p in &["lol", "thanks", "k thx", "sup", "noice"] {
            assert!(is_trivial_token(p), "expected trivial: {}", p);
        }
    }

    #[test]
    fn eval030_is_trivial_token_does_not_match_real_prompt() {
        let p = "Please analyze the database schema and report any normalization issues.";
        assert!(!is_trivial_token(p));
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_format_returns_empty_for_trivial_token() {
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        let targets = make_targets();
        let s = format_lessons_block_with_prompt(&targets, Some("lol"));
        assert!(
            s.is_empty(),
            "trivial token should suppress whole block, got: {:?}",
            s
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_format_suppresses_perception_directive_on_conditional_chain() {
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        let targets = make_targets();
        let prompt = "Please do A, if it fails do B, then if B fails do C.";
        let s = format_lessons_block_with_prompt(&targets, Some(prompt));
        assert!(
            !s.is_empty(),
            "conditional chain still has the patch_file lesson, block must render"
        );
        assert!(
            !s.to_lowercase().contains("clarifying question"),
            "perception clarifying directive must be filtered, got: {}",
            s
        );
        assert!(
            s.contains("verify file exists before patch_file"),
            "non-perception directives must survive, got: {}",
            s
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_default_env_preserves_existing_behavior_when_prompt_unset() {
        // No prompt → identical to legacy format_lessons_block path.
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        let targets = make_targets();
        let legacy = format_lessons_block(&targets);
        let new_no_prompt = format_lessons_block_with_prompt(&targets, None);
        assert_eq!(legacy, new_no_prompt);
        assert!(legacy.to_lowercase().contains("clarifying question"));
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_opt_out_disables_gating() {
        std::env::set_var("CHUMP_LESSONS_TASK_AWARE", "0");
        let targets = make_targets();
        // Trivial prompt — would normally suppress; opt-out keeps the block.
        let s = format_lessons_block_with_prompt(&targets, Some("lol"));
        assert!(
            s.to_lowercase().contains("clarifying question"),
            "opt-out must restore v1 uniform behavior, got: {}",
            s
        );
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_task_aware_default_on() {
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        assert!(task_aware_lessons_enabled());
    }

    // ── MEM-009: quality-threshold filtering ─────────────────────────────

    /// Build a reflection with a specific outcome_class for quality-threshold tests.
    fn sample_reflection_with_outcome(directive: &str, outcome: OutcomeClass) -> Reflection {
        Reflection {
            id: None,
            episode_id: None,
            intended_goal: "test goal".into(),
            observed_outcome: "test outcome".into(),
            outcome_class: outcome,
            error_pattern: None,
            improvements: vec![ImprovementTarget {
                directive: directive.into(),
                priority: Priority::High,
                scope: None,
                actioned_as: None,
            }],
            hypothesis: "test hypothesis".into(),
            surprisal_at_reflect: None,
            confidence_at_reflect: None,
            created_at: "2026-04-19T00:00:00Z".into(),
        }
    }

    #[test]
    fn mem009_outcome_quality_mapping() {
        // Verify the pure-function mapping matches the acceptance criteria.
        assert_eq!(outcome_quality(Some("pass")), 1.0);
        assert_eq!(outcome_quality(Some("success")), 1.0);
        assert_eq!(outcome_quality(Some("partial")), 0.5);
        assert_eq!(outcome_quality(Some("failure")), 0.0);
        assert_eq!(outcome_quality(Some("abandoned")), 0.0);
        assert_eq!(
            outcome_quality(Some("")),
            0.5,
            "empty string defaults to 0.5"
        );
        assert_eq!(outcome_quality(None), 0.5, "NULL defaults to 0.5");
        assert_eq!(outcome_quality(Some("unknown_value")), 0.0, "unknown → 0.0");
    }

    #[test]
    #[serial(reflection_db)]
    fn fleet049_lesson_quality_threshold_default_is_0_6() {
        // FLEET-049: quality gate default raised from 0.0 to 0.6 to match docs.
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        assert!(
            (lesson_quality_threshold() - 0.6).abs() < f64::EPSILON,
            "default threshold must be 0.6 (FLEET-049)"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_lesson_quality_threshold_parses_and_clamps() {
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "0.5");
        assert_eq!(lesson_quality_threshold(), 0.5);
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "1.0");
        assert_eq!(lesson_quality_threshold(), 1.0);
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "0.0");
        assert_eq!(lesson_quality_threshold(), 0.0);
        // Out-of-range values clamp.
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "2.5");
        assert_eq!(lesson_quality_threshold(), 1.0, "above 1.0 clamps to 1.0");
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "-0.5");
        assert_eq!(lesson_quality_threshold(), 0.0, "below 0.0 clamps to 0.0");
        // Malformed value falls back to the default (LESSON_QUALITY_THRESHOLD_DEFAULT = 0.6).
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "garbage");
        assert_eq!(
            lesson_quality_threshold(),
            LESSON_QUALITY_THRESHOLD_DEFAULT,
            "malformed falls back to default (FLEET-049: 0.6)"
        );
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_threshold_zero_loads_all() {
        // threshold=0.0 must load lessons from all outcome classes.
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("partial lesson", OutcomeClass::PartialSuccess),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons_with_threshold("", 10, 0.0);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(
            directives.contains(&"success lesson"),
            "threshold=0.0 must include success"
        );
        assert!(
            directives.contains(&"partial lesson"),
            "threshold=0.0 must include partial"
        );
        assert!(
            directives.contains(&"failure lesson"),
            "threshold=0.0 must include failure"
        );
        assert_eq!(
            directives.len(),
            3,
            "all three lessons visible at threshold=0.0"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_threshold_one_loads_only_successes() {
        // threshold=1.0 must return only lessons from reflections with outcome "pass".
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("partial lesson", OutcomeClass::PartialSuccess),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("abandoned lesson", OutcomeClass::Abandoned),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons_with_threshold("", 10, 1.0);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(
            directives,
            vec!["success lesson"],
            "threshold=1.0 must include only pass/success outcome"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_threshold_half_loads_successes_and_partials() {
        // threshold=0.5 must return lessons from pass and partial outcomes,
        // excluding failure and abandoned.
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("partial lesson", OutcomeClass::PartialSuccess),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons_with_threshold("", 10, 0.5);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(
            directives.contains(&"success lesson"),
            "threshold=0.5 must include success"
        );
        assert!(
            directives.contains(&"partial lesson"),
            "threshold=0.5 must include partial"
        );
        assert!(
            !directives.contains(&"failure lesson"),
            "threshold=0.5 must exclude failure"
        );
        assert_eq!(directives.len(), 2);
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_env_var_threshold_applied_by_load_spawn_lessons() {
        // load_spawn_lessons (the public API) reads CHUMP_LESSON_QUALITY_THRESHOLD.
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");

        // With threshold=1.0 set, only success should surface.
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "1.0");
        let lessons = load_spawn_lessons("", 10);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(directives, vec!["success lesson"]);

        // Remove threshold → default 0.6 gate applies; failure-class (quality=0.0) excluded.
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        let all_lessons = load_spawn_lessons("", 10);
        assert_eq!(
            all_lessons.len(),
            1,
            "no threshold → default 0.6 gate, only success-class returned"
        );
    }
}

// ---------------------------------------------------------------------------
// INFRA-127: end-to-end record → query → use coverage.
//
// Existing tests cover individual functions in isolation but never trace the
// full lesson-injection pathway: a session writes a reflection row, the
// spawn-lessons assembler queries it, and the rendered block contains the
// directive in the form the prompt assembler will paste into a child agent's
// system prompt. Without this, the COG-016 / COG-024 / MEM-006 lesson
// injection feature is functionally unverified end to end — a regression in
// any of save_reflection, load_spawn_lessons,
// format_lessons_block_with_prompt, CHUMP_LESSONS_AT_SPAWN_N parsing,
// CHUMP_BYPASS_SPAWN_LESSONS bypass, or the quality-threshold filter would
// slip past the existing unit tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod e2e_record_query_use {
    use super::*;
    use serial_test::serial;

    /// Per-test fresh DB root with isolated env vars.
    fn fresh_test_root() {
        let dir = std::env::temp_dir().join(format!(
            "chump_reflection_db_e2e_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        set_test_db_root(Some(dir));
    }

    /// Build a reflection row matching the shape the autonomy loop produces.
    fn reflection_with_directive(
        directive: &str,
        priority: Priority,
        scope: Option<&str>,
        outcome: OutcomeClass,
    ) -> Reflection {
        Reflection {
            id: None,
            episode_id: None,
            intended_goal: "e2e test goal".into(),
            observed_outcome: "e2e test outcome".into(),
            outcome_class: outcome,
            error_pattern: match outcome {
                OutcomeClass::Pass => None,
                _ => Some(ErrorPattern::ToolMisuse),
            },
            improvements: vec![ImprovementTarget {
                directive: directive.into(),
                priority,
                scope: scope.map(String::from),
                actioned_as: None,
            }],
            hypothesis: "e2e hypothesis".into(),
            surprisal_at_reflect: Some(0.5),
            confidence_at_reflect: Some(0.7),
            created_at: "2026-04-17T00:00:00Z".into(),
        }
    }

    /// Mirrors the prompt_assembler.rs:96-116 spawn-block assembly path.
    /// Returns the rendered block text the assembler would prepend to the
    /// system prompt (empty string when no lessons would be injected — same
    /// contract as the real path).
    fn assembler_path(domain: &str, user_prompt: &str) -> String {
        let n = match spawn_lessons_n() {
            Some(n) if n > 0 => n,
            _ => return String::new(),
        };
        if !reflection_available() {
            return String::new();
        }
        let targets = load_spawn_lessons(domain, n);
        format_lessons_block_with_prompt(&targets, Some(user_prompt))
    }

    /// Save → query → assembler-render → assert directive appears in block.
    /// This is the load-bearing contract: a recorded directive reaches the
    /// next agent's system prompt unmodified.
    #[test]
    #[serial(reflection_db)]
    fn full_path_directive_reaches_assembled_block() {
        fresh_test_root();
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "5");
        std::env::remove_var("CHUMP_BYPASS_SPAWN_LESSONS");
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        std::env::set_var("CHUMP_LESSONS_TASK_AWARE", "0");

        save_reflection(
            &reflection_with_directive(
                "verify file exists before patch",
                Priority::High,
                Some("patch_file"),
                OutcomeClass::Pass,
            ),
            Some(101),
        )
        .expect("save_reflection should persist row");

        let block = assembler_path("patch_file", "implement the new feature please");

        assert!(
            !block.is_empty(),
            "assembler must produce non-empty block when a high-priority directive matches the domain"
        );
        assert!(
            block.contains("verify file exists before patch"),
            "directive text must reach the assembled prompt verbatim; got:\n{}",
            block
        );
        assert!(
            block.contains("[patch_file]"),
            "scope tag must render alongside the directive; got:\n{}",
            block
        );
        assert!(
            block.contains("Lessons from prior episodes"),
            "block must carry the COG-016 header that frames the directives; got:\n{}",
            block
        );

        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
    }

    /// CHUMP_LESSONS_AT_SPAWN_N unset → no block, even with rows in the DB.
    #[test]
    #[serial(reflection_db)]
    fn no_spawn_n_means_no_block() {
        fresh_test_root();
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        std::env::remove_var("CHUMP_BYPASS_SPAWN_LESSONS");

        save_reflection(
            &reflection_with_directive(
                "should not appear",
                Priority::High,
                None,
                OutcomeClass::Pass,
            ),
            Some(102),
        )
        .expect("save_reflection should persist row");

        let block = assembler_path("", "do the thing");
        assert!(
            block.is_empty(),
            "without CHUMP_LESSONS_AT_SPAWN_N the assembler must not inject anything; got:\n{}",
            block
        );
    }

    /// CHUMP_BYPASS_SPAWN_LESSONS=1 short-circuits load_spawn_lessons before
    /// any DB work. EVAL-056 ablation gate.
    #[test]
    #[serial(reflection_db)]
    fn bypass_env_returns_empty_lessons() {
        fresh_test_root();
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "5");
        std::env::set_var("CHUMP_BYPASS_SPAWN_LESSONS", "1");

        save_reflection(
            &reflection_with_directive(
                "ablation suppressed",
                Priority::High,
                None,
                OutcomeClass::Pass,
            ),
            Some(103),
        )
        .expect("save_reflection should persist row");

        let direct = load_spawn_lessons("", 5);
        assert!(
            direct.is_empty(),
            "CHUMP_BYPASS_SPAWN_LESSONS=1 must short-circuit load_spawn_lessons; got {:?}",
            direct.iter().map(|t| &t.directive).collect::<Vec<_>>()
        );

        let block = assembler_path("", "do the thing");
        assert!(
            block.is_empty(),
            "bypass must propagate end-to-end through the assembler path"
        );

        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        std::env::remove_var("CHUMP_BYPASS_SPAWN_LESSONS");
    }

    /// Quality threshold filters out lessons whose parent reflection had a
    /// failure outcome. Save one Pass + one Failure, set threshold above
    /// failure quality, verify only Pass reaches the block.
    #[test]
    #[serial(reflection_db)]
    fn quality_threshold_filters_failure_lessons_end_to_end() {
        fresh_test_root();
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "5");
        std::env::remove_var("CHUMP_BYPASS_SPAWN_LESSONS");
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "0.75");
        std::env::set_var("CHUMP_LESSONS_TASK_AWARE", "0");

        save_reflection(
            &reflection_with_directive(
                "lesson from clean pass",
                Priority::High,
                None,
                OutcomeClass::Pass,
            ),
            Some(201),
        )
        .expect("save_reflection should persist row");
        save_reflection(
            &reflection_with_directive(
                "lesson from failure run",
                Priority::High,
                None,
                OutcomeClass::Failure,
            ),
            Some(202),
        )
        .expect("save_reflection should persist row");

        let block = assembler_path("", "implement the new feature");
        assert!(
            block.contains("lesson from clean pass"),
            "Pass-derived lesson must surface above 0.75 quality threshold; got:\n{}",
            block
        );
        assert!(
            !block.contains("lesson from failure run"),
            "Failure-derived lesson (quality=0.0) must be filtered at threshold 0.75; got:\n{}",
            block
        );

        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
    }

    /// Scope filter: a directive scoped to "patch_file" must surface under
    /// that domain hint AND under universal queries, but a directive scoped
    /// to a different tool must NOT surface for the patch_file domain.
    /// End-to-end via the assembler path so a regression in load_spawn_lessons
    /// or the assembler surfaces here.
    #[test]
    #[serial(reflection_db)]
    fn scope_hint_filters_unrelated_lessons_in_assembled_block() {
        fresh_test_root();
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "5");
        std::env::remove_var("CHUMP_BYPASS_SPAWN_LESSONS");
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        std::env::set_var("CHUMP_LESSONS_TASK_AWARE", "0");

        save_reflection(
            &reflection_with_directive(
                "patch-only lesson",
                Priority::High,
                Some("patch_file"),
                OutcomeClass::Pass,
            ),
            Some(301),
        )
        .expect("save_reflection should persist row");
        save_reflection(
            &reflection_with_directive(
                "git-only lesson",
                Priority::High,
                Some("git_commit"),
                OutcomeClass::Pass,
            ),
            Some(302),
        )
        .expect("save_reflection should persist row");
        save_reflection(
            &reflection_with_directive(
                "universal lesson",
                Priority::High,
                None,
                OutcomeClass::Pass,
            ),
            Some(303),
        )
        .expect("save_reflection should persist row");

        let patch_block = assembler_path("patch_file", "patch this file");
        assert!(
            patch_block.contains("patch-only lesson"),
            "patch-scoped lesson must surface for patch_file domain; got:\n{}",
            patch_block
        );
        assert!(
            patch_block.contains("universal lesson"),
            "universal-scope lessons must surface under any domain hint; got:\n{}",
            patch_block
        );
        assert!(
            !patch_block.contains("git-only lesson"),
            "different-tool lesson must be filtered out by scope; got:\n{}",
            patch_block
        );

        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
    }

    /// EVAL-030 task-class-aware suppression: trivial-token user prompts
    /// (single-word chat like "hi") must skip the entire block even when
    /// rows are present and CHUMP_LESSONS_AT_SPAWN_N is set. Default-on; only
    /// disabled by CHUMP_LESSONS_TASK_AWARE=0. End-to-end coverage so a
    /// regression in is_trivial_token or the assembler's prompt-passthrough
    /// surfaces here.
    #[test]
    #[serial(reflection_db)]
    fn trivial_token_prompt_skips_entire_block() {
        fresh_test_root();
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "5");
        std::env::remove_var("CHUMP_BYPASS_SPAWN_LESSONS");
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE"); // default-on

        save_reflection(
            &reflection_with_directive(
                "should not appear for trivial chat",
                Priority::High,
                None,
                OutcomeClass::Pass,
            ),
            Some(401),
        )
        .expect("save_reflection should persist row");

        let trivial_block = assembler_path("", "hi");
        assert!(
            trivial_block.is_empty(),
            "EVAL-030: trivial-token prompts must skip the entire lessons block; got:\n{}",
            trivial_block
        );

        let real_block = assembler_path("", "implement the authentication feature end to end");
        assert!(
            !real_block.is_empty(),
            "substantive prompts must still receive the lessons block when rows exist"
        );

        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
    }

    // -----------------------------------------------------------------
    // COG-041: tokenizer + cosine_similarity unit coverage
    // -----------------------------------------------------------------

    #[test]
    fn cog041_tokenize_drops_short_and_stopwords() {
        let toks = tokenize("The fleet is auth-storming");
        // "the" and "is" are stopwords; len-3 minimum drops nothing here.
        // "auth" + "storming" survive; "fleet" survives.
        assert!(toks.contains(&"fleet".to_string()));
        assert!(toks.contains(&"auth".to_string()));
        assert!(toks.contains(&"storming".to_string()));
        assert!(!toks.contains(&"the".to_string()));
        assert!(!toks.contains(&"is".to_string()));
    }

    #[test]
    fn cog041_tokenize_drops_pure_numbers_and_short() {
        let toks = tokenize("INFRA-468 fixes 7 bugs in 2026 ok");
        assert!(toks.contains(&"infra".to_string()));
        assert!(!toks.contains(&"468".to_string())); // pure-numeric dropped
        assert!(!toks.contains(&"2026".to_string()));
        assert!(toks.contains(&"fixes".to_string()));
        assert!(toks.contains(&"bugs".to_string()));
        assert!(!toks.contains(&"ok".to_string())); // len 2
    }

    #[test]
    fn cog041_cosine_similarity_orthogonal() {
        use std::collections::HashMap;
        let mut a = HashMap::new();
        a.insert("foo".to_string(), 1.0);
        let mut b = HashMap::new();
        b.insert("bar".to_string(), 1.0);
        assert_eq!(cosine_similarity(&a, &b), 0.0);
    }

    #[test]
    fn cog041_cosine_similarity_identical() {
        use std::collections::HashMap;
        let mut a = HashMap::new();
        a.insert("auth".to_string(), 2.0);
        a.insert("fleet".to_string(), 1.0);
        let b = a.clone();
        let s = cosine_similarity(&a, &b);
        assert!(
            (s - 1.0).abs() < 1e-9,
            "identical vectors → similarity 1.0; got {}",
            s
        );
    }

    #[test]
    fn cog041_cosine_similarity_partial_overlap() {
        use std::collections::HashMap;
        let mut a = HashMap::new();
        a.insert("auth".to_string(), 1.0);
        a.insert("fleet".to_string(), 1.0);
        let mut b = HashMap::new();
        b.insert("auth".to_string(), 1.0);
        b.insert("storm".to_string(), 1.0);
        // 1 shared term out of 2 each → cos = 1 / (sqrt(2) * sqrt(2)) = 0.5
        let s = cosine_similarity(&a, &b);
        assert!(
            (s - 0.5).abs() < 1e-9,
            "expected 0.5 for one-of-two overlap, got {}",
            s
        );
    }

    #[test]
    fn cog041_semantic_empty_query_falls_back_or_empty() {
        // Empty query should not panic and should return an empty Vec
        // OR fall back to recency-frequency. Either is acceptable.
        // We just want to confirm no crash on empty input.
        fresh_test_root();
        let v = load_relevant_lessons_semantic("", 5, "INFRA");
        assert!(v.len() <= 5);
    }
}
