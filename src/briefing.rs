//! MEM-007 — `chump --briefing <GAP-ID>` agent context-query.
//!
//! Returns a structured briefing for "what should I know before working on
//! gap X?". Pairs with MEM-006 (`load_spawn_lessons`) which injects lessons
//! systemically at spawn time. MEM-007 is the explicit per-gap query path,
//! intended to be run by an agent right after `gap-preflight.sh` and before
//! `gap-claim.sh`.
//!
//! Sources read:
//! - `docs/gaps.yaml` for the gap entry (title, acceptance, depends_on, ...)
//! - `chump_improvement_targets` (via `reflection_db`) for relevant lessons
//! - `.chump-locks/ambient.jsonl` for recent peripheral-vision events
//! - `docs/STRATEGY_VS_GOOSE.md`, `docs/architecture/CHUMP_FACULTY_MAP.md`,
//!   `docs/research/RESEARCH_PLAN_2026Q3.md`, `docs/research/CONSCIOUSNESS_AB_RESULTS.md`,
//!   `docs/briefs/CHUMP_RESEARCH_BRIEF.md` for cross-references that mention the
//!   gap ID
//! - `gh pr list --search <gap-id> --state closed` for prior PRs (best-effort,
//!   silently skipped if `gh` is unavailable)

use crate::gap_store;
use crate::reflection::ImprovementTarget;
use crate::reflection_db;
use crate::repo_path;
use std::fs;
use std::path::Path;
use std::process::Command;

/// Strategic docs scanned for cross-references. Order matters for output
/// stability in tests.
const STRATEGIC_DOCS: &[&str] = &[
    "docs/architecture/CHUMP_FACULTY_MAP.md",
    "docs/STRATEGY_VS_GOOSE.md",
    "docs/research/RESEARCH_PLAN_2026Q3.md",
    "docs/research/CONSCIOUSNESS_AB_RESULTS.md",
    "docs/briefs/CHUMP_RESEARCH_BRIEF.md",
];

/// Umbrella context for a gap that depends on a META-NNN parent.
///
/// INFRA-2165: surfaced before "Recent File Activity" so spawned Sonnet
/// workers arrive with full integration-cycle awareness — no "read META-124
/// first" instruction needed in dispatch prompts.
#[derive(Debug, Clone, Default)]
pub struct UmbrellaContext {
    /// Parent META gap ID (e.g. "META-124").
    pub meta_id: String,
    /// Parent META gap title.
    pub meta_title: String,
    /// Parent META acceptance_criteria, truncated to 80 lines with an
    /// ellipsis hint when longer. Empty string when the parent has no AC.
    pub meta_ac_truncated: String,
    /// Whether the AC was truncated (hint to renderer to emit "… run chump
    /// gap show <meta_id> for full AC").
    pub ac_truncated: bool,
    /// Up to 5 integration-cycle ambient events from the last 24 h, drawn
    /// from kinds: integration_cycle_started, integration_candidates_selected,
    /// integration_cycle_shipped, bisect_quarantine. Raw JSON lines.
    pub recent_cycle_events: Vec<String>,
}

/// One structured briefing for a gap.
///
/// **INFRA-482:** derives `Default` so test construction sites can use
/// `GapBriefing { gap_id: "X".into(), ..Default::default() }`. This
/// cuts the merge-conflict surface when two parallel PRs each add a
/// new field — adding a field touches only the struct definition and
/// the two real constructors (early-return + happy path), not five
/// test sites.
#[derive(Debug, Clone, Default)]
pub struct GapBriefing {
    pub gap_id: String,
    pub gap_title: String,
    pub gap_acceptance: Option<String>,
    pub gap_priority: String,
    pub gap_effort: String,
    pub gap_domain: String,
    pub depends_on: Vec<String>,
    pub relevant_reflections: Vec<ImprovementTarget>,
    pub recent_ambient_events: Vec<String>,
    pub strategic_doc_refs: Vec<String>,
    pub similar_closed_prs: Vec<u32>,
    /// INFRA-AGENT-ESCALATION: escalation ALERT events from ambient.jsonl for
    /// this gap from the last 24 hours. Each entry is a raw JSON line.
    pub escalation_events: Vec<String>,
    /// COG-042: differential reflections — recent `delta_recorded` events
    /// from past sessions on similar (same-domain) gaps. Each entry is
    /// the human-readable text the past agent recorded as "what I did
    /// differently this time."
    pub recent_deltas: Vec<crate::reflect_delta::DeltaRecord>,
    /// INFRA-477: aggregate stats for past sessions on the same domain
    /// — n, median/min/max elapsed seconds, shipped/abandoned/starved
    /// counts. Surfaced as a one-liner in the rendered briefing so the
    /// next agent sees historical cost ("median 24m, range 8–67m").
    pub session_stats: crate::session_ledger::SessionStats,
    /// COG-051: recent git commits that touched file paths mentioned in the
    /// gap's title or acceptance criteria. Each entry is one formatted log
    /// line: `<path>: <sha> <subject>`. Capped at 10 commits per path, 5
    /// paths max. Empty when no recognisable paths appear in gap text or git
    /// is unavailable.
    pub recent_path_edits: Vec<String>,
    /// `true` when the gap was not found in `docs/gaps.yaml`. Renderer prints
    /// a clear error in this case rather than a misleading half-empty briefing.
    pub gap_not_found: bool,
    /// INFRA-2165: umbrella context injected when the gap depends on a META
    /// umbrella gap. `None` when no META dependency exists or the parent
    /// lookup fails gracefully.
    pub umbrella_context: Option<UmbrellaContext>,
    /// INFRA-1121 (A2A Layer 3d slice 3/4): snapshot of prompt-injectable
    /// scratchpad seed keys at session start. Each entry is `(key, value)`.
    /// Empty when no keys have been written to `.chump-locks/scratch/` yet,
    /// or when `CHUMP_SCRATCHPAD_INJECT=0` is set. Capped at 5 keys / ~500
    /// tokens total by `scratchpad::prompt_inject_snapshot`.
    pub scratchpad_context: Vec<(String, String)>,
    /// INFRA-1718: fleet-mode snapshot (auth/backend/effort/cost ceiling),
    /// computed fresh at briefing time — never cached — so agents don't
    /// misroute work based on a stale auth or backend state.
    pub fleet_mode: crate::fleet_mode::FleetMode,
    /// INFRA-3456 (comprehension-first loop): the unified `comprehend`
    /// (ChumpOS comprehension-organs) report for `root` — WIRING / GATES /
    /// CONFIG with honest coverage labels — so the agent grounds in how the
    /// repo is actually wired BEFORE editing, instead of rediscovering "we
    /// have X but it's not wired" by trial. `None` when the organs aren't
    /// built here (`comprehend` binary absent), the consult is disabled
    /// (`CHUMP_BRIEFING_COMPREHEND=0`), the subprocess times out, or the
    /// report is empty. Best-effort: never blocks the rest of the briefing.
    pub comprehension: Option<String>,
    /// RESILIENT-258: "how we work here" block — the exact almanac command
    /// (with repo + gap-relevant query pre-filled), the `chump voice`
    /// friction-report one-liner, and the organs entrypoint, all rendered
    /// with this gap's own ID/title so the practice is advertised AT THE
    /// POINT OF WORK instead of living only in CLAUDE.md (which is read
    /// once and skipped thereafter). Always populated — deterministic
    /// string construction, no subprocess calls, never `None`.
    pub practices_block: String,
    /// CREDIBLE-167: ceiling on the share of recent commits that may be
    /// automated coherence syncs before the picker stops handing out work.
    /// `None` = no ceiling configured. INFRA-8060: loaded from the shared
    /// `scripts/dispatch/picker-policy.json` (the same file the canonical picker
    /// `_pick_and_claim_gap.py` enforces, INFRA-8224) by
    /// [`load_sync_overhead_ceiling`], and compared against
    /// [`GapBriefing::sync_overhead_ratio`] via
    /// [`GapBriefing::sync_overhead_exceeded`].
    pub sync_overhead_ceiling: Option<f64>,
}

/// INFRA-8060: path of the picker policy shared with the canonical picker
/// `scripts/dispatch/_pick_and_claim_gap.py` (INFRA-8224).
pub const PICKER_POLICY_PATH: &str = "scripts/dispatch/picker-policy.json";

/// INFRA-8060: read `sync_overhead_ceiling` (0.0-1.0) from the shared picker
/// policy under `root`. `None` when the file/key is absent, null, or invalid —
/// matching the python picker's "unset/invalid = off" rule.
pub fn load_sync_overhead_ceiling(root: &Path) -> Option<f64> {
    let text = std::fs::read_to_string(root.join(PICKER_POLICY_PATH)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    v.get("sync_overhead_ceiling")?.as_f64()
}

/// CREDIBLE-167: a commit subject is an automated coherence sync when it
/// contains "coherence sync" (case-insensitive), e.g.
/// `chore(backlog): coherence sync — 0 gaps closed, state.sql regenerated`.
/// Mirrored in the canonical picker `scripts/dispatch/_pick_and_claim_gap.py`
/// (`_sync_overhead_guard`, INFRA-8224).
pub fn is_coherence_sync_subject(subject: &str) -> bool {
    subject.to_lowercase().contains("coherence sync")
}

impl GapBriefing {
    /// CREDIBLE-167: proportion (0.0–1.0) of the last 50 commits in
    /// `repo_path` whose subject is an automated coherence sync. Returns 0.0
    /// when git is unavailable or the repo has no commits.
    pub fn sync_overhead_ratio(&self, repo_path: &Path) -> f64 {
        let Ok(out) = Command::new("git")
            .arg("-C")
            .arg(repo_path)
            .args(["log", "-n", "50", "--format=%s"])
            .output()
        else {
            return 0.0;
        };
        if !out.status.success() {
            return 0.0;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let subjects: Vec<&str> = text.lines().collect();
        if subjects.is_empty() {
            return 0.0;
        }
        let syncs = subjects
            .iter()
            .filter(|s| is_coherence_sync_subject(s))
            .count();
        syncs as f64 / subjects.len() as f64
    }

    /// INFRA-8060: `Some(ratio)` when a ceiling is configured and the recent
    /// sync ratio in `repo_path` is strictly above it (the same `>` comparison
    /// the python picker uses); `None` otherwise.
    pub fn sync_overhead_exceeded(&self, repo_path: &Path) -> Option<f64> {
        let ceiling = self.sync_overhead_ceiling?;
        let ratio = self.sync_overhead_ratio(repo_path);
        (ratio > ceiling).then_some(ratio)
    }
}

/// Build a briefing for the given gap ID. Returns `gap_not_found = true` when
/// the gap is missing from both per-file and legacy locations (no error —
/// agents may pass typos).
///
/// **INFRA-331 (2026-05-02):** prefers per-file `docs/gaps/<ID>.yaml` (the
/// canonical layout post-INFRA-188), then falls back to the legacy monolithic
/// `docs/gaps.yaml` for any caller still on the old layout. Pre-INFRA-331
/// this only read the monolithic file, which silently broke every briefing
/// on this repo because INFRA-188 deleted it. The lessons pool
/// (`chump_improvement_targets`) was queried only AFTER the gap parse
/// succeeded, so the broken parse silently disabled lessons-injection too.
///
/// **INFRA-760 (2026-05-08):** state.db is now the primary source. The
/// per-file YAML mirror is queried only as a fallback (e.g. pre-import
/// branches that haven't run `chump gap reserve`). Before this change, 184
/// of 199 open gaps had no YAML mirror because gap-reserve wrote rows to
/// state.db but the YAML write was best-effort; agents claiming those gaps
/// got a half-empty briefing with no title/AC/priority/effort/domain. The
/// state.db row carries every field we need, so reading from it directly
/// closes the briefing-degradation hole and makes the YAML mirror an
/// optional human-readable artifact instead of load-bearing.
pub fn build_briefing(gap_id: &str) -> GapBriefing {
    build_briefing_at(gap_id, &repo_path::repo_root())
}

/// Test-friendly variant of [`build_briefing`] that accepts an explicit
/// repo root. Production code calls [`build_briefing`]; tests call this
/// directly with a tempdir to avoid CHUMP_REPO env-var racing under
/// parallel test execution.
pub fn build_briefing_at(gap_id: &str, root: &std::path::Path) -> GapBriefing {
    let gap_id = gap_id.trim().to_string();

    // INFRA-760: try state.db first (canonical). This handles the 184-of-199
    // open gaps that had no YAML mirror in the legacy code path.
    let parsed = parse_gap_from_db(root, &gap_id).or_else(|| {
        // Per-file YAML (canonical post-INFRA-188 for human readers).
        let per_file_path = root.join("docs/gaps").join(format!("{gap_id}.yaml"));
        fs::read_to_string(&per_file_path)
            .ok()
            .and_then(|s| parse_gap(&s, &gap_id))
            .or_else(|| {
                // INFRA-689: closed-gap archive (docs/gaps/closed/<ID>.yaml).
                // Allows chump --briefing to surface lessons from shipped gaps.
                let closed_path = root.join("docs/gaps/closed").join(format!("{gap_id}.yaml"));
                fs::read_to_string(&closed_path)
                    .ok()
                    .and_then(|s| parse_gap(&s, &gap_id))
            })
            .or_else(|| {
                // Fallback: legacy monolithic gaps.yaml (pre-INFRA-188 layout).
                let gaps_path = root.join("docs/gaps.yaml");
                fs::read_to_string(&gaps_path)
                    .ok()
                    .and_then(|s| parse_gap(&s, &gap_id))
            })
    });

    let Some(parsed) = parsed else {
        return GapBriefing {
            gap_id,
            gap_title: String::new(),
            gap_acceptance: None,
            gap_priority: String::new(),
            gap_effort: String::new(),
            gap_domain: String::new(),
            depends_on: Vec::new(),
            relevant_reflections: Vec::new(),
            recent_ambient_events: Vec::new(),
            strategic_doc_refs: Vec::new(),
            similar_closed_prs: Vec::new(),
            escalation_events: Vec::new(),
            recent_deltas: Vec::new(),
            session_stats: crate::session_ledger::SessionStats::default(),
            recent_path_edits: Vec::new(),
            gap_not_found: true,
            umbrella_context: None,
            scratchpad_context: Vec::new(),
            fleet_mode: crate::fleet_mode::compute(""),
            comprehension: None,
            practices_block: String::new(),
            sync_overhead_ceiling: None,
        };
    };

    // COG-041: when CHUMP_LESSONS_SEMANTIC=1, rank lessons by semantic
    // similarity to the gap text instead of recency × frequency. Falls
    // back to the recency-frequency path when the env is unset OR when
    // semantic ranking returns 0 hits (no overlap with corpus).
    //
    // COG-046: when CHUMP_LESSONS_EMBEDDING=1, prefer embedding-backed
    // retrieval (Ollama). Cascade order is embedding → TF-IDF → recency.
    // Each mode is best-effort; ranking_mode records the final tier so
    // EVAL-099 / META-040 attribute outcomes correctly.
    let embedding_enabled = crate::lesson_embeddings::embedding_enabled();
    let semantic_mode_used = reflection_db::lessons_semantic_enabled();
    let mut ranking_mode = if embedding_enabled {
        "embedding"
    } else if semantic_mode_used {
        "semantic"
    } else {
        "recency"
    };
    let query_text = format!(
        "{} {}",
        parsed.title,
        parsed.acceptance.as_deref().unwrap_or("")
    );
    let relevant_reflections = if embedding_enabled {
        let picks = reflection_db::load_relevant_lessons_embedding(&query_text, 5, &parsed.domain);
        if picks.is_empty() {
            let sem = reflection_db::load_relevant_lessons_semantic(&query_text, 5, &parsed.domain);
            if sem.is_empty() {
                ranking_mode = "recency_fallback_from_embedding";
                query_relevant_reflections(&parsed.domain, 5)
            } else {
                ranking_mode = "semantic_fallback_from_embedding";
                sem
            }
        } else {
            picks
        }
    } else if semantic_mode_used {
        let semantic =
            reflection_db::load_relevant_lessons_semantic(&query_text, 5, &parsed.domain);
        if semantic.is_empty() {
            ranking_mode = "recency_fallback_from_semantic";
            query_relevant_reflections(&parsed.domain, 5)
        } else {
            semantic
        }
    } else {
        query_relevant_reflections(&parsed.domain, 5)
    };

    // INFRA-1765: merge in CI-failure lessons captured by `chump ci-lesson
    // capture` — a separate query path because they deliberately bypass the
    // self-reflection quality-score filter (see `load_ci_lessons` doc
    // comment). Deduped by directive so a lesson that somehow matched both
    // paths isn't shown twice; capped so CI lessons can't crowd out the
    // ranked self-reflection lessons above.
    let mut relevant_reflections = relevant_reflections;
    let seen_directives: std::collections::HashSet<String> = relevant_reflections
        .iter()
        .map(|r| r.directive.clone())
        .collect();
    for ci_lesson in reflection_db::load_ci_lessons(&parsed.domain, 3) {
        if !seen_directives.contains(&ci_lesson.directive) {
            relevant_reflections.push(ci_lesson);
        }
    }

    // COG-043: emit a `lessons_shown` event so downstream telemetry
    // (lesson-grade subcommand, META-040 audit, EVAL-099 quality eval)
    // knows which directives were surfaced for this gap+session+mode.
    // Best-effort — never blocks the briefing render.
    let session_id =
        crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let directives: Vec<String> = relevant_reflections
        .iter()
        .map(|r| r.directive.clone())
        .collect();
    crate::lesson_action::emit_lessons_shown(root, &session_id, &gap_id, ranking_mode, &directives);

    let ambient_path = root.join(".chump-locks/ambient.jsonl");
    let recent_ambient_events = filter_ambient(&ambient_path, &parsed.domain, 20);

    let strategic_doc_refs = scan_strategic_docs(root, &gap_id);

    let similar_closed_prs = find_similar_prs(&gap_id);

    let escalation_events = filter_escalation_events(&ambient_path, &gap_id, 24 * 3600);

    // COG-051: surface recent git edits to paths mentioned in gap text so
    // the agent arrives with architectural context instead of grepping blind.
    let gap_text = format!(
        "{} {}",
        parsed.title,
        parsed.acceptance.as_deref().unwrap_or("")
    );
    let mentioned_paths = extract_paths_from_text(&gap_text);
    let recent_path_edits = recent_edits_for_paths(root, &mentioned_paths, 10);

    // COG-042: surface recent `delta_recorded` events for same-domain
    // gaps so the next agent sees how past attempts on this class
    // differed from each other.
    let recent_deltas = crate::reflect_delta::recent_deltas_for_domain(root, &parsed.domain, 5);
    // INFRA-477: surface aggregate session stats for the same domain
    // so the next agent sees how long similar work has historically
    // taken (and what fraction shipped).
    let session_stats = crate::session_ledger::session_stats_for_domain(root, &parsed.domain);

    // INFRA-2165: inject umbrella context when the gap depends on a META-NNN.
    // Graceful: logs debug on miss, never blocks the rest of the briefing.
    let umbrella_context = build_umbrella_context(root, &parsed.depends_on, &ambient_path);

    // INFRA-1121 (A2A Layer 3d slice 3/4): snapshot prompt-injectable
    // scratchpad seed keys. Graceful: empty vec when no keys are set,
    // inject is disabled (CHUMP_SCRATCHPAD_INJECT=0), or we're not
    // inside a tokio runtime.
    let scratchpad_context = collect_scratchpad_context();

    // INFRA-1718: computed fresh here (not cached) so the briefing always
    // reflects current auth/backend state at the moment it's requested.
    let fleet_mode = crate::fleet_mode::compute(&parsed.effort);

    // INFRA-3456: comprehension-first — consult the ChumpOS organs for this
    // repo so the briefing grounds the agent in wiring/gates/config before any
    // edit. Best-effort: None when the organs are absent, disabled, timed out,
    // or produce nothing. Never blocks the rest of the briefing.
    let comprehension = build_comprehension(root);

    // RESILIENT-258: advertise mine-almanac / holler-friction / use-organs
    // AT THE POINT OF WORK — in the briefing itself, with this gap's own
    // ID/title/domain pre-filled into the exact commands, not just in
    // CLAUDE.md (read once, then skipped every subsequent session).
    let practices_block = build_practices_block(root, &gap_id, &parsed.title, &parsed.domain);

    let mut briefing = GapBriefing {
        gap_id,
        gap_title: parsed.title,
        gap_acceptance: parsed.acceptance,
        gap_priority: parsed.priority,
        gap_effort: parsed.effort,
        gap_domain: parsed.domain,
        depends_on: parsed.depends_on,
        relevant_reflections,
        recent_ambient_events,
        strategic_doc_refs,
        similar_closed_prs,
        escalation_events,
        recent_deltas,
        session_stats,
        recent_path_edits,
        gap_not_found: false,
        umbrella_context,
        scratchpad_context,
        fleet_mode,
        comprehension,
        practices_block,
        sync_overhead_ceiling: load_sync_overhead_ceiling(root),
    };
    // INFRA-8060: consume the ceiling — surface a breach where the agent reads.
    if let Some(ratio) = briefing.sync_overhead_exceeded(root) {
        briefing.practices_block.push_str(&format!(
            "\n**Warning:** automated coherence syncs are {:.0}% of the last 50 commits (ceiling {:.0}%); the picker will not hand out new work until this drops.\n",
            ratio * 100.0,
            briefing.sync_overhead_ceiling.unwrap_or(0.0) * 100.0
        ));
    }
    briefing
}

/// Collect prompt-injectable scratchpad keys synchronously.
///
/// Calls `chump_coord::scratchpad::prompt_inject_snapshot` via
/// `tokio::runtime::Handle::try_current()` so it works whether the
/// caller is inside a tokio runtime (most production paths) or a sync
/// test. Returns empty vec when:
/// - `CHUMP_SCRATCHPAD_INJECT=0` is set (opt-out)
/// - no tokio runtime is running (sync test contexts without `#[tokio::test]`)
/// - no scratchpad keys have been written yet
fn collect_scratchpad_context() -> Vec<(String, String)> {
    // Operator opt-out.
    if std::env::var("CHUMP_SCRATCHPAD_INJECT")
        .map(|v| v == "0")
        .unwrap_or(false)
    {
        return Vec::new();
    }

    match tokio::runtime::Handle::try_current() {
        Ok(handle) => {
            // We're inside a tokio runtime — block_in_place so we don't
            // nest runtimes. block_in_place is a no-op on current_thread
            // runtimes but works correctly on multi_thread (the normal case).
            tokio::task::block_in_place(|| {
                handle.block_on(chump_coord::scratchpad::prompt_inject_snapshot(5))
            })
        }
        Err(_) => {
            // No runtime — caller is a sync context; return empty gracefully.
            Vec::new()
        }
    }
}

/// INFRA-2165: scan `depends_on` for a META-NNN reference, fetch the parent
/// gap's title + AC from state.db (or YAML fallback), and pull recent
/// integration-cycle events from ambient.jsonl.
///
/// Returns `None` gracefully when:
/// - no META dep exists
/// - parent gap not found (logged at debug level)
/// - ambient.jsonl is missing (cycle events sub-section simply omitted)
fn build_umbrella_context(
    root: &Path,
    depends_on: &[String],
    ambient_path: &Path,
) -> Option<UmbrellaContext> {
    // Detect first META-NNN reference in depends_on.
    let meta_id = depends_on
        .iter()
        .find(|dep| {
            let upper = dep.to_uppercase();
            // Match "META-NNN" pattern: starts with META- followed by digits.
            upper.starts_with("META-")
                && upper[5..]
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_digit())
                    .unwrap_or(false)
        })?
        .clone();

    // Fetch parent gap — try state.db first, then per-file YAML.
    let parent = parse_gap_from_db(root, &meta_id).or_else(|| {
        let per_file = root.join("docs/gaps").join(format!("{meta_id}.yaml"));
        fs::read_to_string(&per_file)
            .ok()
            .and_then(|s| parse_gap(&s, &meta_id))
            .or_else(|| {
                let closed = root
                    .join("docs/gaps/closed")
                    .join(format!("{meta_id}.yaml"));
                fs::read_to_string(&closed)
                    .ok()
                    .and_then(|s| parse_gap(&s, &meta_id))
            })
    });

    let Some(parent) = parent else {
        // Graceful degradation: emit to stderr at debug level, don't fail the briefing.
        if std::env::var("CHUMP_DEBUG").is_ok() {
            eprintln!(
                "[briefing] umbrella-context: parent gap {} not found — skipping",
                meta_id
            );
        }
        return None;
    };

    // Truncate AC to 80 lines.
    let (meta_ac_truncated, ac_truncated) = match &parent.acceptance {
        None => (String::new(), false),
        Some(ac) => {
            let lines: Vec<&str> = ac.lines().collect();
            if lines.len() > 80 {
                (lines[..80].join("\n"), true)
            } else {
                (ac.clone(), false)
            }
        }
    };

    // Pull recent integration-cycle events from ambient.jsonl (last 24 h).
    let recent_cycle_events = filter_cycle_events(ambient_path, 24 * 3600, 5);

    Some(UmbrellaContext {
        meta_id,
        meta_title: parent.title,
        meta_ac_truncated,
        ac_truncated,
        recent_cycle_events,
    })
}

/// Integration-cycle ambient event kinds to surface in the umbrella context.
const CYCLE_EVENT_KINDS: &[&str] = &[
    "integration_cycle_started",
    "integration_candidates_selected",
    "integration_cycle_shipped",
    "bisect_quarantine",
];

/// Read the tail of `ambient.jsonl` and keep the most recent `limit` lines
/// whose `"kind"` field is one of the integration-cycle kinds, emitted within
/// `within_secs` seconds of now.
pub fn filter_cycle_events(path: &Path, within_secs: u64, limit: usize) -> Vec<String> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };

    use std::time::{SystemTime, UNIX_EPOCH};
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let cutoff_secs = now_secs.saturating_sub(within_secs);

    let mut hits: Vec<String> = contents
        .lines()
        .filter(|line| {
            let lower = line.to_lowercase();
            // Must be one of the integration-cycle kinds.
            if !CYCLE_EVENT_KINDS
                .iter()
                .any(|k| lower.contains(&format!("\"kind\":\"{}\"", k)))
            {
                return false;
            }
            // Must be within the time window.
            if let Some(ts_start) = line.find("\"ts\":\"") {
                let rest = &line[ts_start + 6..];
                if let Some(ts_end) = rest.find('"') {
                    let ts = &rest[..ts_end];
                    if let Some(event_secs) = parse_iso8601_utc_to_epoch(ts) {
                        return event_secs >= cutoff_secs;
                    }
                }
            }
            // Unparseable timestamp — include conservatively.
            true
        })
        .map(|s| s.to_string())
        .collect();

    if hits.len() > limit {
        let start = hits.len() - limit;
        hits = hits.split_off(start);
    }
    hits
}

/// Extract file-path-like tokens from arbitrary gap text.
///
/// Matches tokens that contain `/` but are not URLs (`://`) and whose first
/// segment starts with an alphanumeric character. Caps at 5 unique paths so
/// the git-log fan-out stays bounded. Preserves first-seen order.
pub fn extract_paths_from_text(text: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut paths = Vec::new();
    for token in text.split_whitespace() {
        // Three-pass strip: punctuation → trailing sentence period → punctuation
        // again (trimming the period may expose another backtick/comma).
        let punctuation = |c: char| matches!(c, '`' | ',' | '(' | ')' | '"' | '\'' | ';' | '!');
        let token = token.trim_matches(punctuation);
        let token = token.trim_end_matches('.');
        let token = token.trim_matches(punctuation);
        if token.contains('/') && !token.contains("://") {
            // First segment must start with an alphanumeric (not a leading /).
            let first_char = token.chars().next().unwrap_or('/');
            if first_char.is_alphanumeric() && seen.insert(token.to_string()) {
                paths.push(token.to_string());
                if paths.len() >= 5 {
                    break;
                }
            }
        }
    }
    paths
}

/// Run `git log --oneline -<limit> -- <path>` for each path and return
/// formatted entries `"<path>: <sha> <subject>"`. Best-effort: silently
/// skips paths that produce no output or when git is unavailable.
pub fn recent_edits_for_paths(root: &Path, paths: &[String], limit: usize) -> Vec<String> {
    let mut result = Vec::new();
    for path in paths {
        let output = Command::new("git")
            .arg("-C")
            .arg(root)
            .arg("log")
            .arg(format!("-{limit}"))
            .arg("--oneline")
            .arg("--")
            .arg(path)
            .output();
        let Ok(out) = output else { continue };
        if !out.status.success() {
            continue;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        for line in text.lines() {
            let line = line.trim();
            if !line.is_empty() {
                result.push(format!("{path}: {line}"));
            }
        }
    }
    result
}

/// Parsed gap fields used by the briefing. Keep this struct private to the
/// module — external callers go through `build_briefing`.
struct ParsedGap {
    title: String,
    acceptance: Option<String>,
    priority: String,
    effort: String,
    domain: String,
    depends_on: Vec<String>,
}

/// INFRA-760: read a gap's metadata directly from `.chump/state.db` and
/// shape it into the [`ParsedGap`] the briefing renderer expects. Returns
/// `None` if state.db is missing or the row isn't there — caller falls
/// back to YAML.
///
/// Conversions:
/// - `acceptance_criteria` is stored as a JSON array of strings; we join
///   it as a bullet-list ("- a\n- b") so the rendered briefing reads the
///   same way it does from YAML's `acceptance: >` block.
/// - `depends_on` is stored as a JSON array; we parse it directly into
///   `Vec<String>`. Falls back to single-element vec on parse failure
///   so a malformed entry doesn't lose the dep entirely.
fn parse_gap_from_db(root: &Path, gap_id: &str) -> Option<ParsedGap> {
    let store = gap_store::GapStore::open(root).ok()?;
    let row = store.get(gap_id).ok().flatten()?;

    // Acceptance: JSON array → bullet-prefixed multi-line block.
    let acceptance = if row.acceptance_criteria.trim().is_empty() {
        None
    } else if let Ok(items) = serde_json::from_str::<Vec<String>>(&row.acceptance_criteria) {
        if items.is_empty() {
            None
        } else {
            Some(
                items
                    .iter()
                    .map(|s| format!("- {}", s.trim()))
                    .collect::<Vec<_>>()
                    .join("\n"),
            )
        }
    } else {
        // Not a JSON array — treat the whole field as one acceptance blob.
        Some(row.acceptance_criteria.trim().to_string())
    };

    // depends_on: JSON array of IDs → Vec<String>.
    let depends_on: Vec<String> = serde_json::from_str(&row.depends_on).unwrap_or_default();

    Some(ParsedGap {
        title: row.title,
        acceptance,
        priority: row.priority,
        effort: row.effort,
        domain: row.domain,
        depends_on,
    })
}

/// Tiny line-based YAML parser tuned for `docs/gaps.yaml`'s shape. Avoids
/// pulling serde_yaml into the briefing module's hot path and keeps test
/// fixtures small. Recognizes:
/// - `- id: <ID>` at line start (root `gaps:` list items in `docs/gaps.yaml`)
/// - `  title: "..."` / `  title: ...` fields for that entry
/// - `    priority: ...`
/// - `    effort: ...`
/// - `    domain: ...`
/// - `    acceptance: >` followed by indented continuation lines
/// - `    depends_on:` followed by `      - <ID>` lines
///
/// Returns the FIRST matching gap entry in the file. Skips quotation marks
/// when present.
fn parse_gap(yaml: &str, target_id: &str) -> Option<ParsedGap> {
    let target_id = target_id.trim();
    let mut lines = yaml.lines().peekable();
    while let Some(line) = lines.next() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("- id:") {
            let id = strip_quotes(rest.trim());
            if id != target_id {
                continue;
            }
            // Found the entry; consume until the next root `- id:` line or EOF.
            let mut title = String::new();
            let mut acceptance: Option<String> = None;
            let mut priority = String::new();
            let mut effort = String::new();
            let mut domain = String::new();
            let mut depends_on: Vec<String> = Vec::new();

            while let Some(peek) = lines.peek() {
                let peek_trim = peek.trim_start();
                // Next gap entry — `- id:` after common YAML list indentation.
                if peek_trim.starts_with("- id:") {
                    break;
                }
                // SAFETY: peeked above in the while condition, so next() will always return Some.
                let line = lines.next().expect("peeked above; always Some");
                let t = line.trim_start();
                if let Some(v) = t.strip_prefix("title:") {
                    title = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("priority:") {
                    priority = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("effort:") {
                    effort = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("domain:") {
                    domain = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("acceptance:") {
                    let v = v.trim();
                    if v == ">" || v == "|" {
                        // Multi-line scalar — collect indented continuation.
                        let mut buf = String::new();
                        while let Some(p) = lines.peek() {
                            // Stop on next field (4-space indented key:) or
                            // next entry.
                            let pt = p.trim_start();
                            if pt.is_empty() {
                                lines.next();
                                continue;
                            }
                            // A new top-level field at the same 4-space indent
                            // looks like `<key>:` with no leading list marker.
                            // Heuristic: if the line is indented exactly 4
                            // spaces and contains a `:` before any space, it's
                            // a sibling field — stop.
                            let leading = p.len() - p.trim_start().len();
                            if leading <= 4 && pt.contains(':') && !pt.starts_with('-') {
                                let key = pt.split(':').next().unwrap_or("");
                                if !key.contains(' ') && !key.is_empty() {
                                    break;
                                }
                            }
                            // Stop on next gap entry.
                            if p.trim_start().starts_with("- id:") {
                                break;
                            }
                            if !buf.is_empty() {
                                buf.push(' ');
                            }
                            buf.push_str(pt);
                            lines.next();
                        }
                        if !buf.is_empty() {
                            acceptance = Some(buf);
                        }
                    } else if !v.is_empty() {
                        acceptance = Some(strip_quotes(v).to_string());
                    }
                } else if t.starts_with("depends_on:") {
                    while let Some(p) = lines.peek() {
                        if p.trim_start().starts_with("- id:") {
                            break;
                        }
                        let pt = p.trim_start();
                        if let Some(dep) = pt.strip_prefix("- ") {
                            // Strip inline comments.
                            let dep = dep.split('#').next().unwrap_or("").trim();
                            let dep = strip_quotes(dep);
                            if !dep.is_empty() {
                                depends_on.push(dep.to_string());
                            }
                            lines.next();
                        } else {
                            break;
                        }
                    }
                }
            }

            return Some(ParsedGap {
                title,
                acceptance,
                priority,
                effort,
                domain,
                depends_on,
            });
        }
    }
    None
}

fn strip_quotes(s: &str) -> &str {
    let s = s.trim();
    let s = s.strip_prefix('"').unwrap_or(s);
    let s = s.strip_suffix('"').unwrap_or(s);
    let s = s.strip_prefix('\'').unwrap_or(s);
    s.strip_suffix('\'').unwrap_or(s)
}

/// Query `chump_improvement_targets` for lessons whose scope matches the
/// gap's domain. Recency × frequency ranking, mirrors `load_spawn_lessons`.
/// Empty domain returns the global top-N.
pub fn query_relevant_reflections(domain: &str, limit: usize) -> Vec<ImprovementTarget> {
    reflection_db::load_spawn_lessons(domain, limit)
}

/// Read the tail of `ambient.jsonl` and keep the most recent `limit` lines
/// whose JSON body mentions the gap's domain (case-insensitive substring on
/// `path`/`cmd`/`gap_id` fields). Stays substring-based so we don't pull
/// serde_json just for filtering.
pub fn filter_ambient(path: &Path, domain: &str, limit: usize) -> Vec<String> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let domain_norm = domain.trim().to_lowercase();
    let domain_paths = domain_path_hints(&domain_norm);

    let mut hits: Vec<String> = contents
        .lines()
        .filter(|line| {
            let lower = line.to_lowercase();
            // Always keep ALERT lines — they're cross-cutting peripheral
            // vision regardless of domain.
            if lower.contains("\"kind\":\"alert\"") || lower.contains("alert ") {
                return true;
            }
            if domain_norm.is_empty() {
                return true;
            }
            if lower.contains(&domain_norm) {
                return true;
            }
            domain_paths.iter().any(|p| lower.contains(p))
        })
        .map(|s| s.to_string())
        .collect();

    if hits.len() > limit {
        let start = hits.len() - limit;
        hits = hits.split_off(start);
    }
    hits
}

/// INFRA-AGENT-ESCALATION: scan ambient.jsonl for escalation ALERT events that
/// reference `gap_id` and were emitted within `within_secs` seconds of now.
/// Returns raw JSON lines, most-recent last, capped at 20.
pub fn filter_escalation_events(path: &Path, gap_id: &str, within_secs: u64) -> Vec<String> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };

    use std::time::{SystemTime, UNIX_EPOCH};
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let cutoff_secs = now_secs.saturating_sub(within_secs);

    let gap_id_lower = gap_id.to_lowercase();
    let mut hits: Vec<String> = contents
        .lines()
        .filter(|line| {
            let lower = line.to_lowercase();
            // Must be an escalation ALERT.
            if !lower.contains("\"kind\":\"escalation\"") {
                return false;
            }
            // Must reference this gap.
            if !lower.contains(&gap_id_lower) {
                return false;
            }
            // Must be recent: extract "ts":"<value>" and convert ISO-8601 UTC to
            // epoch seconds for an exact numeric comparison. If we can't parse
            // the timestamp, include conservatively so events aren't silently
            // dropped due to a format we didn't anticipate.
            if let Some(ts_start) = line.find("\"ts\":\"") {
                let rest = &line[ts_start + 6..];
                if let Some(ts_end) = rest.find('"') {
                    let ts = &rest[..ts_end];
                    if let Some(event_secs) = parse_iso8601_utc_to_epoch(ts) {
                        return event_secs >= cutoff_secs;
                    }
                }
            }
            // Unparseable timestamp — include conservatively.
            true
        })
        .map(|s| s.to_string())
        .collect();

    if hits.len() > 20 {
        let start = hits.len() - 20;
        hits = hits.split_off(start);
    }
    hits
}

/// Parse an ISO-8601 UTC timestamp of the form `YYYY-MM-DDTHH:MM:SSZ` into
/// Unix epoch seconds. Returns `None` for any other format.
///
/// Avoids pulling in the `time` or `chrono` crates for this one call site.
/// Handles leap years and variable-length months correctly.
fn parse_iso8601_utc_to_epoch(ts: &str) -> Option<u64> {
    // Expected format: YYYY-MM-DDTHH:MM:SSZ  (20 chars)
    let ts = ts.trim_end_matches('Z');
    let ts = ts.trim_end_matches("+00:00");
    // Split on 'T'
    let (date_part, time_part) = ts.split_once('T')?;
    let mut date_iter = date_part.splitn(3, '-');
    let year: u64 = date_iter.next()?.parse().ok()?;
    let month: u64 = date_iter.next()?.parse().ok()?;
    let day: u64 = date_iter.next()?.parse().ok()?;
    let mut time_iter = time_part.splitn(3, ':');
    let hour: u64 = time_iter.next()?.parse().ok()?;
    let min: u64 = time_iter.next()?.parse().ok()?;
    let sec: u64 = time_iter.next()?.parse().ok()?;

    if !(1u64..=12).contains(&month) || !(1u64..=31).contains(&day) || year < 1970 {
        return None;
    }

    // Days from epoch to start of year.
    let years_since_epoch = year - 1970;
    let leap_days = leap_days_before_year(year);
    let days_to_year = years_since_epoch * 365 + leap_days;

    // Days from start of year to start of month.
    let days_to_month = days_in_months_before(month, year);

    let total_days = days_to_year + days_to_month + (day - 1);
    let epoch_secs = total_days * 86400 + hour * 3600 + min * 60 + sec;
    Some(epoch_secs)
}

/// Count leap days (Feb 29 occurrences) between 1970-01-01 and Jan 1 of `year`.
fn leap_days_before_year(year: u64) -> u64 {
    // Leap years since 1970 up to (but not including) `year`.
    // A year is a leap year if divisible by 4, except centuries unless div by 400.
    if year <= 1970 {
        return 0;
    }
    let y = year - 1; // last year to include
    let base = 1969u64; // last year before 1970
    (y / 4 - base / 4) - (y / 100 - base / 100) + (y / 400 - base / 400)
}

/// Sum of days in months 1..(month-1) for the given year.
fn days_in_months_before(month: u64, year: u64) -> u64 {
    const DAYS: [u64; 13] = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let is_leap = year.is_multiple_of(4) && !year.is_multiple_of(100) || year.is_multiple_of(400);
    let mut days = 0u64;
    for m in 1..month {
        days += DAYS[m as usize];
        if m == 2 && is_leap {
            days += 1;
        }
    }
    days
}

/// Heuristic mapping from a gap domain to file-path substrings worth
/// matching in ambient events. Conservative — only well-known domains; an
/// unknown domain falls back to bare substring match on the domain string.
fn domain_path_hints(domain: &str) -> Vec<&'static str> {
    match domain {
        "memory" => vec!["src/reflection", "src/memory", "src/briefing"],
        "eval" => vec![
            "scripts/ab-harness",
            "docs/consciousness_ab_results",
            "src/eval",
        ],
        "coordination" => vec![
            ".chump-locks",
            "scripts/coord/gap-",
            "scripts/coord/bot-merge",
        ],
        "infra" => vec!["scripts/", ".github/workflows", "docs/merge_queue"],
        "tools" => vec!["src/tools", "_tool.rs"],
        "messaging" => vec!["src/discord", "src/slack", "src/messaging_adapters"],
        "product" => vec!["docs/strategy", "docs/research_plan"],
        _ => Vec::new(),
    }
}

/// Grep strategic docs for cross-references to the gap ID. Returns one entry
/// per matching `(doc_path, line_excerpt)` pair, capped at 10.
pub fn scan_strategic_docs(root: &Path, gap_id: &str) -> Vec<String> {
    let mut hits = Vec::new();
    for rel in STRATEGIC_DOCS {
        let path = root.join(rel);
        let Ok(contents) = fs::read_to_string(&path) else {
            continue;
        };
        for (i, line) in contents.lines().enumerate() {
            if line.contains(gap_id) {
                let excerpt = line.trim();
                let excerpt = if excerpt.len() > 140 {
                    format!("{}…", &excerpt[..140])
                } else {
                    excerpt.to_string()
                };
                hits.push(format!("{}:{} — {}", rel, i + 1, excerpt));
                if hits.len() >= 10 {
                    return hits;
                }
            }
        }
    }
    hits
}

/// Best-effort `gh pr list --search <gap-id> --state closed` lookup.
/// Returns an empty vec if `gh` isn't installed, isn't authed, or times out.
pub fn find_similar_prs(gap_id: &str) -> Vec<u32> {
    let output = Command::new("gh")
        .args([
            "pr", "list", "--state", "closed", "--search", gap_id, "--limit", "10", "--json",
            "number",
        ])
        .output();
    let Ok(out) = output else { return Vec::new() };
    if !out.status.success() {
        return Vec::new();
    }
    let body = String::from_utf8_lossy(&out.stdout);
    // Tiny parse — avoid pulling serde_json. Body looks like
    // `[{"number":151},{"number":156}]`.
    let mut prs = Vec::new();
    for chunk in body.split("\"number\":").skip(1) {
        let digits: String = chunk.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(n) = digits.parse::<u32>() {
            prs.push(n);
        }
    }
    prs
}

/// INFRA-3456 (comprehension-first loop): shell to the `comprehend` binary —
/// the unified ChumpOS comprehension-organs report — for `root`, so the
/// briefing can ground the agent in the repo's wiring / gates / config BEFORE
/// it edits, instead of rediscovering "we have X but it's not wired" by trial.
///
/// Best-effort by construction — every failure mode degrades to `None`, never a
/// panic or a hang, so the organs being absent (or slow) can't break briefings:
///   - `CHUMP_BRIEFING_COMPREHEND=0` disables the consult outright.
///   - `None` when the `comprehend` binary isn't installed (organs not built
///     on this machine) — reuses `comprehend_tool::comprehend_bin` for parity
///     with the `comprehend_repo` native tool.
///   - Wall-clock budget `CHUMP_BRIEFING_COMPREHEND_TIMEOUT_S` (default 20s):
///     on overrun the child is killed and we return `None`, so a pathological
///     repo can never wedge a briefing.
///   - Output is byte-capped (char-boundary safe) so a huge report can't bloat
///     the briefing.
fn build_comprehension(root: &Path) -> Option<String> {
    use std::io::Read;

    if std::env::var("CHUMP_BRIEFING_COMPREHEND").as_deref() == Ok("0") {
        return None;
    }
    let bin = crate::comprehend_tool::comprehend_bin()?;
    let timeout_s: u64 = std::env::var("CHUMP_BRIEFING_COMPREHEND_TIMEOUT_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(20);

    let mut child = Command::new(&bin)
        .arg("--repo")
        .arg(root)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    // Poll for completion within the wall-clock budget. `comprehend`'s report
    // is a small summary (well under the OS pipe buffer), so the child never
    // blocks writing stdout while we sleep between polls.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_s);
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => break,
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            Err(_) => return None,
        }
    }

    // Child has exited; drain the buffered stdout (try_wait does not take it).
    let mut buf = String::new();
    if let Some(mut so) = child.stdout.take() {
        let _ = so.read_to_string(&mut buf);
    }
    let text = buf.trim();
    if text.is_empty() {
        return None;
    }

    const MAX: usize = 4000;
    if text.len() > MAX {
        let mut end = MAX;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        Some(format!(
            "{}\n… (truncated at {MAX} bytes — run `comprehend --repo {}` for the full report)",
            &text[..end],
            root.display()
        ))
    } else {
        Some(text.to_string())
    }
}

/// Resolve the repo name almanac expects for its `--repo` flag: the git
/// remote `origin` basename (stripped of `.git`), falling back to the
/// checkout directory's basename when there's no remote (e.g. a fresh
/// `git init`) or `git` isn't available. Best-effort — never fails, never
/// blocks the briefing.
pub fn derive_repo_name(root: &Path) -> String {
    let from_remote = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| {
            let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
            let name = url
                .rsplit('/')
                .next()
                .unwrap_or("")
                .trim_end_matches(".git");
            if name.is_empty() {
                None
            } else {
                Some(name.to_string())
            }
        });

    from_remote.unwrap_or_else(|| {
        root.file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("repo")
            .to_string()
    })
}

/// RESILIENT-258: build the "how we work here" block — the exact
/// almanac-mining command, the `chump voice` friction-report one-liner, and
/// the comprehension-organs entrypoint, all with THIS gap's own repo/ID/
/// title/domain pre-filled. The gap (via `chump --briefing`) is the agent's
/// context at work-time; CLAUDE.md is read once and skipped, so the
/// practices we want (mine almanac before build, holler friction via
/// `chump voice`, use the comprehend organs) have to be advertised where the
/// agent actually looks — not just documented in a manual nobody re-reads.
///
/// Deterministic string construction only (no subprocess beyond the cheap
/// `git remote get-url` in [`derive_repo_name`]) — always populated, never
/// blocks or degrades the rest of the briefing.
pub fn build_practices_block(
    root: &Path,
    gap_id: &str,
    gap_title: &str,
    gap_domain: &str,
) -> String {
    let repo = derive_repo_name(root);
    let query = if gap_title.trim().is_empty() {
        gap_id.to_string()
    } else {
        gap_title.trim().to_string()
    };
    let domain_hint = if gap_domain.trim().is_empty() {
        "this area".to_string()
    } else {
        gap_domain.trim().to_string()
    };

    format!(
        "- **Mine almanac first** — before writing code that touches {domain_hint}, ground in \
         what's already indexed instead of grepping blind:\n  \
         `~/Projects/almanac/target/release/almanac search --repo {repo} \"{query}\"`\n  \
         New to this area? `almanac architecture --repo {repo}` first.\n\
         - **Use the organs** — before editing a shared file, check what's wired/gated/configured: \
         `almanac comprehend --repo {repo}`; before deleting or rewriting a line that looks wrong: \
         `almanac why --repo {repo} <path> <line>`.\n\
         - **Holler friction** — if something about {gap_id} surprises you or wastes time, file it \
         instead of silently working around it:\n  \
         `chump voice --wedge-class <short-id> --minutes-lost <n> --workaround \"<what you did>\" \
         --fix-shape <doc|tooling|gate|new-subcommand|other> --fix \"<what should exist instead>\" \
         --evidence {gap_id}`\n"
    )
}

/// Render the briefing as agent-readable markdown.
/// INFRA-1548: JSON rendering with schema_version:1 for harness consumers.
pub fn render_json(b: &GapBriefing) -> String {
    let escape = |s: &str| {
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
    };
    let reflections: Vec<String> = b
        .relevant_reflections
        .iter()
        .map(|r| format!("\"{}\"", escape(&r.directive)))
        .collect();
    let deps: Vec<String> = b
        .depends_on
        .iter()
        .map(|d| format!("\"{}\"", escape(d)))
        .collect();
    let prs: Vec<String> = b.similar_closed_prs.iter().map(|n| n.to_string()).collect();
    format!(
        concat!(
            r#"{{"schema_version":1,"gap_id":"{id}","gap_title":"{title}","gap_priority":"{prio}","#,
            r#""gap_effort":"{effort}","gap_domain":"{domain}","gap_not_found":{nf},"#,
            r#""gap_acceptance":{ac},"depends_on":[{deps}],"#,
            r#""relevant_reflections":[{refs}],"similar_closed_prs":[{prs}],"#,
            r#""comprehension":{comp},"practices_block":"{practices}","fleet_mode":{fleet_mode}}}"#
        ),
        id = escape(&b.gap_id),
        title = escape(&b.gap_title),
        prio = escape(&b.gap_priority),
        effort = escape(&b.gap_effort),
        domain = escape(&b.gap_domain),
        nf = b.gap_not_found,
        ac = b
            .gap_acceptance
            .as_deref()
            .map(|s| format!("\"{}\"", escape(s)))
            .unwrap_or_else(|| "null".to_string()),
        deps = deps.join(","),
        refs = reflections.join(","),
        prs = prs.join(","),
        comp = b
            .comprehension
            .as_deref()
            .map(|s| format!("\"{}\"", escape(s)))
            .unwrap_or_else(|| "null".to_string()),
        practices = escape(&b.practices_block),
        fleet_mode = crate::fleet_mode::render_json(&b.fleet_mode),
    )
}

pub fn render_markdown(b: &GapBriefing) -> String {
    if b.gap_not_found {
        return format!(
            "# Briefing: {gid}\n\n**Gap not found in docs/gaps.yaml.** Check the ID or run `grep -n '{gid}' docs/gaps.yaml`.\n",
            gid = b.gap_id
        );
    }
    let mut out = String::new();

    // Clean up escaped quotes in the title
    let clean_title = b.gap_title.replace("\\\"", "\"");

    // Header with ID and title
    out.push_str(&format!("# {}: {}\n\n", b.gap_id, clean_title));

    // Metadata in a cleaner format
    out.push_str("**Metadata**\n");
    if !b.gap_domain.is_empty() {
        out.push_str(&format!("- Domain: `{}`\n", b.gap_domain));
    }
    if !b.gap_priority.is_empty() {
        out.push_str(&format!("- Priority: {}\n", b.gap_priority));
    }
    if !b.gap_effort.is_empty() {
        out.push_str(&format!("- Effort: {}\n", b.gap_effort));
    }
    if !b.depends_on.is_empty() {
        out.push_str(&format!("- Depends on: {}\n", b.depends_on.join(", ")));
    }
    out.push('\n');

    // RESILIENT-258: "how we work here" — advertised at point-of-work, with
    // this gap's own repo/ID/title/domain pre-filled into the commands, so
    // the practice happens because it's in front of the agent right now.
    if !b.practices_block.is_empty() {
        out.push_str("## How we work here\n\n");
        out.push_str(&b.practices_block);
        out.push('\n');
    }

    // INFRA-1718: fleet-mode snapshot — auth/backend/effort/cost ceiling,
    // computed fresh at briefing time.
    out.push_str(&crate::fleet_mode::render_markdown_section(&b.fleet_mode));

    // INFRA-3456: comprehension-first — the ChumpOS organs' read on this repo's
    // wiring / gates / config, surfaced BEFORE the agent starts editing so it
    // grounds in how the repo is actually wired instead of guessing. Hidden
    // when the organs are absent/disabled (best-effort, keeps briefings clean).
    if let Some(c) = &b.comprehension {
        out.push_str("## Comprehension (organs)\n\n");
        out.push_str(
            "_ChumpOS comprehension organs' read on this repo — ground here before editing._\n\n",
        );
        out.push_str("```\n");
        out.push_str(c);
        out.push_str("\n```\n\n");
    }

    // INFRA-1121: scratchpad context — fleet state snapshot at session start.
    // Only rendered when at least one key is set; hidden when empty to keep
    // the briefing clean for agents working without the scratchpad populated.
    if !b.scratchpad_context.is_empty() {
        out.push_str("## Fleet Scratchpad (session-start snapshot)\n\n");
        for (k, v) in &b.scratchpad_context {
            out.push_str(&format!("- `{}` = {}\n", k, v));
        }
        out.push('\n');
    }

    // Acceptance criteria
    out.push_str("## Acceptance Criteria\n\n");
    match &b.gap_acceptance {
        Some(a) => {
            out.push_str(a);
            out.push_str("\n\n");
        }
        None => out.push_str("_(none recorded)_\n\n"),
    }

    // Relevant reflections
    out.push_str("## Reflections\n\n");
    if b.relevant_reflections.is_empty() {
        out.push_str("_(no previous lessons for this domain)_\n\n");
    } else {
        for r in &b.relevant_reflections {
            let scope = r.scope.as_deref().unwrap_or("global");
            out.push_str(&format!(
                "- **{:?}** — {}\n  _{}_\n",
                r.priority, r.directive, scope
            ));
        }
        out.push('\n');
    }

    // INFRA-2165: umbrella context — inserted before Recent File Activity so
    // spawned workers see integration-cycle state first.
    if let Some(ref uc) = b.umbrella_context {
        out.push_str("## Umbrella context\n\n");
        out.push_str(&format!(
            "**Parent umbrella:** {} — {}\n\n",
            uc.meta_id, uc.meta_title
        ));
        if !uc.meta_ac_truncated.is_empty() {
            out.push_str("**Parent AC:**\n\n");
            out.push_str(&uc.meta_ac_truncated);
            out.push('\n');
            if uc.ac_truncated {
                out.push_str(&format!(
                    "\n_(truncated — run `chump gap show {}` for full AC)_\n",
                    uc.meta_id
                ));
            }
            out.push('\n');
        }
        if !uc.recent_cycle_events.is_empty() {
            out.push_str("**Recent integration-cycle events (last 24 h):**\n\n");
            for ev in &uc.recent_cycle_events {
                let summary = summarize_ambient_event(ev);
                out.push_str(&format!("- {}\n", summary));
            }
            out.push('\n');
        } else {
            out.push_str("_No integration-cycle events in the last 24 h._\n\n");
        }
    }

    // Recent path edits
    if !b.recent_path_edits.is_empty() {
        out.push_str("## Recent File Activity\n\n");
        for entry in &b.recent_path_edits {
            out.push_str(&format!("- {}\n", entry));
        }
        out.push('\n');
    }

    // Ambient events - extract key information
    if !b.recent_ambient_events.is_empty() {
        out.push_str("## Recent Activity\n\n");
        for ev in &b.recent_ambient_events {
            let event_summary = summarize_ambient_event(ev);
            out.push_str(&format!("- {}\n", event_summary));
        }
        out.push('\n');
    }

    // Strategic doc references
    if !b.strategic_doc_refs.is_empty() {
        out.push_str("## Related Documentation\n\n");
        for r in &b.strategic_doc_refs {
            out.push_str(&format!("- {}\n", r));
        }
        out.push('\n');
    }

    // Similar PRs
    if !b.similar_closed_prs.is_empty() {
        out.push_str("## Similar Closed PRs\n\n");
        let list: Vec<String> = b
            .similar_closed_prs
            .iter()
            .map(|n| format!("#{}", n))
            .collect();
        out.push_str(&format!("{}\n\n", list.join(", ")));
    }

    // Escalation events (most important, show prominently if present)
    if !b.escalation_events.is_empty() {
        out.push_str("## ⚠️  Escalation Alert\n\n");
        out.push_str(
            "> A previous agent was stuck on this gap. Review carefully before starting.\n\n",
        );
        for ev in &b.escalation_events {
            let event_summary = summarize_ambient_event(ev);
            out.push_str(&format!("> - {}\n", event_summary));
        }
        out.push('\n');
    }

    out
}

/// Extract human-readable summary from JSON event line.
fn summarize_ambient_event(line: &str) -> String {
    if line.is_empty() {
        return "_(empty event)_".to_string();
    }

    // Extract event type (field may be "kind" or "event")
    let event_type = extract_json_field(line, "kind")
        .or_else(|| extract_json_field(line, "event"))
        .unwrap_or_else(|| "unknown".to_string());

    // Extract timestamp for conciseness
    let ts = extract_json_field(line, "ts")
        .map(|t| {
            // Extract just the time part: "2026-05-08T14:39:03Z" -> "14:39:03"
            if let Some(time_start) = t.find('T') {
                let time_end = time_start + 9; // "T" + HH:MM:SS
                if time_end <= t.len() {
                    t[time_start + 1..time_end].to_string()
                } else {
                    t
                }
            } else {
                t
            }
        })
        .unwrap_or_default();

    // Build summary based on event type
    let summary = match event_type.as_str() {
        "file_edit" => {
            let path = extract_json_field(line, "path").unwrap_or_else(|| "unknown".to_string());
            let path_short = path.split('/').next_back().unwrap_or(&path);
            format!("📝 file edited: {}", path_short)
        }
        "bash_call" => {
            let cmd = extract_json_field(line, "cmd").unwrap_or_else(|| "unknown".to_string());
            // Extract just the command name
            let cmd_short = cmd.split_whitespace().next().unwrap_or(&cmd);
            format!("⌨️  {}", cmd_short)
        }
        "alert" => {
            let msg = extract_json_field(line, "msg")
                .or_else(|| extract_json_field(line, "message"))
                .unwrap_or_else(|| "alert".to_string());
            format!("⚠️  alert: {}", msg)
        }
        "escalation" => {
            let stuck_at =
                extract_json_field(line, "stuck_at").unwrap_or_else(|| "unknown".to_string());
            format!("🚨 escalation: {}", stuck_at)
        }
        _ => {
            let worktree =
                extract_json_field(line, "worktree").unwrap_or_else(|| "unknown".to_string());
            format!("event ({})", worktree)
        }
    };

    if ts.is_empty() {
        summary
    } else {
        format!("{} {}", ts, summary)
    }
}

/// Extract a JSON field value as a string, handling basic JSON escaping.
fn extract_json_field(line: &str, field: &str) -> Option<String> {
    let search = format!("\"{}\":\"", field);
    let start = line.find(&search)? + search.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    let value = &rest[..end];
    Some(
        value
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
            .replace("\\n", "\n"),
    )
}

/// A single item parsed from a repo's defined backlog file (MISSION-089
/// slice of MISSION-055). Deliberately minimal — just the title — since
/// `parse_backlog_file` is a format-detection/parse step, not a gap-filing
/// step (that's `ingest_backlog::run_import`).
#[derive(Debug, Clone, PartialEq)]
pub struct Task {
    pub title: String,
}

/// Error returned by [`parse_backlog_file`].
#[derive(Debug)]
pub enum BacklogParseError {
    /// The file couldn't be read (missing, permissions, ...).
    Io(String),
    /// The file ends in `.json` but its contents are not valid JSON, or not
    /// shaped as an array of task objects / `{"tasks": [...]}`.
    MalformedJson(String),
}

impl std::fmt::Display for BacklogParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BacklogParseError::Io(msg) => write!(f, "{msg}"),
            BacklogParseError::MalformedJson(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for BacklogParseError {}

/// Read `path` and parse it into a list of [`Task`]s. Format is detected by
/// extension: `.json` is parsed as a JSON array of task objects (or a
/// `{"tasks": [...]}` wrapper), anything else is treated as plain text with
/// one task per non-empty line.
pub fn parse_backlog_file(path: &Path) -> Result<Vec<Task>, BacklogParseError> {
    let raw = fs::read_to_string(path)
        .map_err(|e| BacklogParseError::Io(format!("failed to read {}: {e}", path.display())))?;

    let is_json = path
        .extension()
        .map(|ext| ext.eq_ignore_ascii_case("json"))
        .unwrap_or(false);

    if !is_json {
        let tasks = raw
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(|line| Task {
                title: line.to_string(),
            })
            .collect();
        return Ok(tasks);
    }

    let value: serde_json::Value = serde_json::from_str(&raw).map_err(|e| {
        BacklogParseError::MalformedJson(format!("malformed JSON in {}: {e}", path.display()))
    })?;

    let array = value
        .as_array()
        .cloned()
        .or_else(|| value.get("tasks").and_then(|v| v.as_array()).cloned())
        .ok_or_else(|| {
            BacklogParseError::MalformedJson(format!(
                "malformed JSON in {}: expected an array or {{\"tasks\": [...]}}",
                path.display()
            ))
        })?;

    let tasks = array
        .iter()
        .filter_map(|item| {
            let title = item
                .get("title")
                .or_else(|| item.get("task"))
                .or_else(|| item.get("name"))
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())?;
            Some(Task {
                title: title.to_string(),
            })
        })
        .collect();

    Ok(tasks)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r#"
gaps:
  - id: MEM-007
    title: "Agent context-query — what should I know"
    domain: memory
    priority: P2
    effort: m
    status: open
    description: >
      Test gap entry.
    acceptance: >
      (1) chump --briefing returns markdown.
      (2) CLAUDE.md updated.
    depends_on:
      - MEM-006
      - COG-024
    notes: >
      pairs with MEM-006

  - id: EVAL-030
    title: "Some other gap"
    domain: eval
    priority: P3
    effort: s
    status: open
    acceptance: >
      Single-line acceptance.
"#;

    #[test]
    fn parse_gap_finds_target() {
        let g = parse_gap(FIXTURE, "MEM-007").expect("found");
        assert_eq!(g.title, "Agent context-query — what should I know");
        assert_eq!(g.domain, "memory");
        assert_eq!(g.priority, "P2");
        assert_eq!(g.effort, "m");
        assert!(g
            .acceptance
            .as_deref()
            .unwrap()
            .contains("CLAUDE.md updated"));
        assert_eq!(g.depends_on, vec!["MEM-006", "COG-024"]);
    }

    #[test]
    fn parse_gap_finds_second_entry() {
        let g = parse_gap(FIXTURE, "EVAL-030").expect("found");
        assert_eq!(g.domain, "eval");
        assert!(g.acceptance.as_deref().unwrap().contains("Single-line"));
        assert!(g.depends_on.is_empty());
    }

    #[test]
    fn parse_gap_returns_none_when_missing() {
        assert!(parse_gap(FIXTURE, "NONEXISTENT-999").is_none());
    }

    /// Root-level `- id:` lines (no indent before `-`), matching `docs/gaps.yaml`.
    const ROOT_LIST_FIXTURE: &str = r#"gaps:
- id: ZZ-001
  title: First root entry
  domain: infra
  priority: P1
  effort: s
- id: ZZ-002
  title: Second root entry
  domain: infra
  priority: P2
  effort: m
  depends_on:
    - ZZ-001
"#;

    #[test]
    fn parse_gap_root_level_list_stops_at_next_id() {
        let g = parse_gap(ROOT_LIST_FIXTURE, "ZZ-001").expect("found ZZ-001");
        assert_eq!(g.title, "First root entry");
        assert_eq!(g.priority, "P1");
        assert!(g.depends_on.is_empty());

        let g2 = parse_gap(ROOT_LIST_FIXTURE, "ZZ-002").expect("found ZZ-002");
        assert_eq!(g2.title, "Second root entry");
        assert_eq!(g2.depends_on, vec!["ZZ-001"]);
    }

    #[test]
    fn strip_quotes_handles_double_and_single() {
        assert_eq!(strip_quotes("\"hello\""), "hello");
        assert_eq!(strip_quotes("'world'"), "world");
        assert_eq!(strip_quotes("bare"), "bare");
    }

    #[test]
    fn filter_ambient_keeps_domain_matches_and_alerts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        let body = r#"{"kind":"file_edit","path":"src/reflection_db.rs","sha":"a"}
{"kind":"file_edit","path":"src/unrelated.rs","sha":"b"}
{"kind":"alert","msg":"lease overlap"}
{"kind":"file_edit","path":"src/memory_db.rs","sha":"c"}
"#;
        fs::write(&path, body).unwrap();
        let out = filter_ambient(&path, "memory", 10);
        // 3 hits: reflection (path hint), alert, memory_db (path hint).
        assert_eq!(out.len(), 3, "got {:?}", out);
        assert!(out.iter().any(|l| l.contains("reflection_db")));
        assert!(out.iter().any(|l| l.contains("memory_db")));
        assert!(out.iter().any(|l| l.contains("alert")));
    }

    #[test]
    fn filter_ambient_caps_at_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        let mut body = String::new();
        for i in 0..50 {
            body.push_str(&format!(
                "{{\"kind\":\"file_edit\",\"path\":\"src/reflection_db_{i}.rs\"}}\n"
            ));
        }
        fs::write(&path, body).unwrap();
        let out = filter_ambient(&path, "memory", 5);
        assert_eq!(out.len(), 5);
        // Should be the LAST 5 (most recent).
        assert!(out.last().unwrap().contains("reflection_db_49"));
    }

    #[test]
    fn filter_ambient_missing_file_returns_empty() {
        let out = filter_ambient(Path::new("/nonexistent/ambient.jsonl"), "memory", 10);
        assert!(out.is_empty());
    }

    #[test]
    fn scan_strategic_docs_finds_gap_id() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("architecture");
        fs::create_dir_all(&docs).unwrap();
        fs::write(
            docs.join("CHUMP_FACULTY_MAP.md"),
            "# Map\n\nMEM-007 closes the per-gap learning loop.\nUnrelated line.\n",
        )
        .unwrap();
        let hits = scan_strategic_docs(dir.path(), "MEM-007");
        assert_eq!(hits.len(), 1);
        assert!(hits[0].contains("CHUMP_FACULTY_MAP.md"));
        assert!(hits[0].contains("MEM-007"));
        assert!(hits[0].contains(":3"));
    }

    #[test]
    fn scan_strategic_docs_caps_at_10() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("architecture");
        fs::create_dir_all(&docs).unwrap();
        let mut body = String::new();
        for i in 0..20 {
            body.push_str(&format!("MEM-007 mention {i}\n"));
        }
        fs::write(docs.join("CHUMP_FACULTY_MAP.md"), body).unwrap();
        let hits = scan_strategic_docs(dir.path(), "MEM-007");
        assert_eq!(hits.len(), 10);
    }

    #[test]
    fn render_markdown_for_not_found_is_clear() {
        let b = GapBriefing {
            gap_id: "BOGUS-1".into(),
            gap_not_found: true,
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(md.contains("BOGUS-1"));
        assert!(md.to_lowercase().contains("not found"));
    }

    #[test]
    fn render_markdown_includes_all_sections() {
        let b = GapBriefing {
            gap_id: "MEM-007".into(),
            gap_title: "Agent context-query".into(),
            gap_acceptance: Some("(1) outputs markdown.".into()),
            gap_priority: "P2".into(),
            gap_effort: "m".into(),
            gap_domain: "memory".into(),
            depends_on: vec!["MEM-006".into()],
            recent_ambient_events: vec!["{\"kind\":\"file_edit\"}".into()],
            strategic_doc_refs: vec!["docs/architecture/CHUMP_FACULTY_MAP.md:42 — MEM-007".into()],
            similar_closed_prs: vec![123, 145],
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(md.contains("# MEM-007:"));
        assert!(md.contains("## Acceptance Criteria"));
        assert!(md.contains("## Reflections"));
        assert!(md.contains("## Recent Activity"));
        assert!(md.contains("## Related Documentation"));
        assert!(md.contains("## Similar Closed PRs"));
        assert!(md.contains("#123"));
        assert!(md.contains("Depends on: MEM-006"));
    }

    #[test]
    fn build_practices_block_prefills_repo_gap_and_domain() {
        let dir = tempfile::tempdir().unwrap();
        // No git remote in this bare tempdir — falls back to dir basename,
        // exercised separately below. Here we just check the gap-specific
        // fields land in the right commands.
        let block = build_practices_block(
            dir.path(),
            "RESILIENT-258",
            "advertise practices",
            "resilient",
        );
        assert!(
            block.contains("almanac search --repo"),
            "missing almanac search command: {block}"
        );
        assert!(
            block.contains("\"advertise practices\""),
            "gap title not pre-filled into almanac query: {block}"
        );
        assert!(
            block.contains("almanac comprehend --repo"),
            "missing organs (comprehend) command: {block}"
        );
        assert!(
            block.contains("chump voice"),
            "missing chump voice friction one-liner: {block}"
        );
        assert!(
            block.contains("--evidence RESILIENT-258"),
            "voice one-liner doesn't reference this gap's ID: {block}"
        );
        assert!(
            block.contains("touches resilient"),
            "domain hint not pre-filled: {block}"
        );
    }

    #[test]
    fn build_practices_block_never_empty_even_without_title_or_domain() {
        let dir = tempfile::tempdir().unwrap();
        let block = build_practices_block(dir.path(), "X-1", "", "");
        assert!(!block.is_empty());
        assert!(block.contains("X-1"));
    }

    #[test]
    fn derive_repo_name_falls_back_to_dir_basename_without_remote() {
        let dir = tempfile::tempdir().unwrap();
        let repo_dir = dir.path().join("my-repo-checkout");
        fs::create_dir_all(&repo_dir).unwrap();
        let name = derive_repo_name(&repo_dir);
        assert_eq!(name, "my-repo-checkout");
    }

    #[test]
    fn sync_overhead_ratio_counts_coherence_sync_commits() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        let git = |args: &[&str]| {
            let st = Command::new("git")
                .arg("-C")
                .arg(p)
                .args(["-c", "user.email=t@t", "-c", "user.name=t"])
                .args(["-c", "commit.gpgsign=false"])
                .args(args)
                .output()
                .unwrap();
            assert!(st.status.success(), "git {args:?} failed");
        };
        git(&["init", "-q"]);
        for i in 0..50 {
            let msg = if i < 32 {
                format!("chore(backlog): coherence sync — {i} gaps closed")
            } else {
                format!("real work {i}")
            };
            git(&["commit", "-q", "--allow-empty", "-m", &msg]);
        }
        let b = GapBriefing::default();
        assert!((b.sync_overhead_ratio(p) - 0.64).abs() < 1e-9);
    }

    #[test]
    fn sync_overhead_ceiling_loads_from_shared_picker_policy() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load_sync_overhead_ceiling(dir.path()), None);
        fs::create_dir_all(dir.path().join("scripts/dispatch")).unwrap();
        let policy = dir.path().join(PICKER_POLICY_PATH);
        fs::write(&policy, r#"{"sync_overhead_ceiling": 0.6}"#).unwrap();
        assert_eq!(load_sync_overhead_ceiling(dir.path()), Some(0.6));
        fs::write(&policy, r#"{"sync_overhead_ceiling": null}"#).unwrap();
        assert_eq!(load_sync_overhead_ceiling(dir.path()), None);
        // The committed policy file must stay parseable by this loader.
        let real = Path::new(env!("CARGO_MANIFEST_DIR"));
        assert!(real.join(PICKER_POLICY_PATH).exists());
    }

    #[test]
    fn sync_overhead_exceeded_uses_configured_ceiling() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        let git = |args: &[&str]| {
            let st = Command::new("git")
                .arg("-C")
                .arg(p)
                .args(["-c", "user.email=t@t", "-c", "user.name=t"])
                .args(["-c", "commit.gpgsign=false"])
                .args(args)
                .output()
                .unwrap();
            assert!(st.status.success(), "git {args:?} failed");
        };
        git(&["init", "-q"]);
        for i in 0..10 {
            let msg = if i < 7 {
                "chore: coherence sync"
            } else {
                "real work"
            };
            git(&["commit", "-q", "--allow-empty", "-m", msg]);
        }
        let mut b = GapBriefing::default();
        assert_eq!(b.sync_overhead_exceeded(p), None, "no ceiling = off");
        b.sync_overhead_ceiling = Some(0.6);
        assert!((b.sync_overhead_exceeded(p).unwrap() - 0.7).abs() < 1e-9);
        b.sync_overhead_ceiling = Some(0.8);
        assert_eq!(b.sync_overhead_exceeded(p), None);
    }

    #[test]
    fn sync_overhead_ratio_is_zero_without_git_history() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(GapBriefing::default().sync_overhead_ratio(dir.path()), 0.0);
    }

    #[test]
    fn render_markdown_includes_how_we_work_here_section() {
        let b = GapBriefing {
            gap_id: "RESILIENT-258".into(),
            gap_title: "advertise practices".into(),
            practices_block: build_practices_block(
                Path::new("/nonexistent"),
                "RESILIENT-258",
                "advertise practices",
                "resilient",
            ),
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(md.contains("## How we work here"));
        assert!(md.contains("almanac search --repo"));
        assert!(md.contains("chump voice"));
    }

    #[test]
    fn render_markdown_omits_how_we_work_here_when_empty() {
        // Before RESILIENT-258, this section did not exist at all — a gap
        // with an empty practices_block (e.g. the not-found early return)
        // must not render a half-empty header.
        let b = GapBriefing {
            gap_id: "X-1".into(),
            practices_block: String::new(),
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(!md.contains("## How we work here"));
    }

    #[test]
    fn extract_paths_finds_rust_and_script_paths() {
        let text =
            "edit src/briefing.rs and scripts/coord/bot-merge.sh, then update docs/ROADMAP.md";
        let paths = extract_paths_from_text(text);
        assert!(
            paths.contains(&"src/briefing.rs".to_string()),
            "got {:?}",
            paths
        );
        assert!(
            paths.contains(&"scripts/coord/bot-merge.sh".to_string()),
            "got {:?}",
            paths
        );
        assert!(
            paths.contains(&"docs/ROADMAP.md".to_string()),
            "got {:?}",
            paths
        );
    }

    #[test]
    fn extract_paths_ignores_urls() {
        let text = "see https://example.com/foo for context, edit src/foo.rs";
        let paths = extract_paths_from_text(text);
        assert!(
            !paths.iter().any(|p| p.contains("://")),
            "URL leaked: {:?}",
            paths
        );
        assert!(paths.contains(&"src/foo.rs".to_string()));
    }

    #[test]
    fn extract_paths_caps_at_five() {
        let text = "a/b.rs c/d.rs e/f.rs g/h.rs i/j.rs k/l.rs m/n.rs";
        let paths = extract_paths_from_text(text);
        assert_eq!(paths.len(), 5);
    }

    #[test]
    fn extract_paths_strips_trailing_punctuation() {
        let text = "edit `src/briefing.rs`, then `src/main.rs`.";
        let paths = extract_paths_from_text(text);
        assert!(
            paths.contains(&"src/briefing.rs".to_string()),
            "got {:?}",
            paths
        );
        assert!(
            paths.contains(&"src/main.rs".to_string()),
            "got {:?}",
            paths
        );
    }

    #[test]
    fn render_markdown_includes_recent_path_edits_section() {
        let b = GapBriefing {
            gap_id: "COG-051".into(),
            gap_title: "Test".into(),
            gap_domain: "cog".into(),
            recent_path_edits: vec!["src/briefing.rs: abc1234 add path edits".into()],
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(md.contains("## Recent File Activity"));
        assert!(md.contains("src/briefing.rs: abc1234"));
    }

    #[test]
    fn render_markdown_shows_empty_path_edits_message() {
        let b = GapBriefing {
            gap_id: "COG-099".into(),
            gap_title: "No paths here".into(),
            gap_domain: "cog".into(),
            recent_path_edits: vec![],
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(!md.contains("## Recent File Activity"));
    }

    #[test]
    fn render_markdown_shows_escalation_alert_when_events_present() {
        let b = GapBriefing {
            gap_id: "FOO-001".into(),
            gap_title: "Test gap".into(),
            gap_priority: "P1".into(),
            gap_effort: "s".into(),
            gap_domain: "infra".into(),
            escalation_events: vec![
                r#"{"ts":"2026-04-20T00:00:00Z","session":"s","event":"ALERT","kind":"escalation","gap_id":"FOO-001","stuck_at":"cargo check fails","last_error":"borrow checker","suggested_action":"human review needed"}"#.into(),
            ],
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(md.contains("## ⚠️  Escalation Alert"));
        assert!(md.contains("escalation"));
    }

    #[test]
    fn filter_escalation_events_returns_matching_events() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        // Use a timestamp far in the future to ensure within_secs is always satisfied.
        let body = concat!(
            r#"{"ts":"2099-01-01T00:00:00Z","event":"ALERT","kind":"escalation","gap_id":"FOO-001","stuck_at":"test error","last_error":"e","suggested_action":"review"}"#,
            "\n",
            r#"{"ts":"2099-01-01T00:00:00Z","event":"ALERT","kind":"escalation","gap_id":"BAR-002","stuck_at":"other error","last_error":"e","suggested_action":"review"}"#,
            "\n",
            r#"{"ts":"2099-01-01T00:00:00Z","event":"file_edit","kind":"other","gap_id":"FOO-001","path":"src/foo.rs"}"#,
            "\n",
        );
        fs::write(&path, body).unwrap();
        // within_secs large enough to catch 2099 timestamps from 2026.
        let hits = filter_escalation_events(&path, "FOO-001", 999_999_999);
        assert_eq!(hits.len(), 1, "got {:?}", hits);
        assert!(hits[0].contains("FOO-001"));
        assert!(hits[0].contains("escalation"));
    }

    #[test]
    fn filter_escalation_events_missing_file_returns_empty() {
        let hits =
            filter_escalation_events(Path::new("/nonexistent/ambient.jsonl"), "FOO-001", 86400);
        assert!(hits.is_empty());
    }

    #[test]
    fn filter_escalation_events_excludes_old_events() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        // Timestamp from 1970 — well outside a 24h window from any real "now".
        let body = r#"{"ts":"1970-01-01T00:00:01Z","event":"ALERT","kind":"escalation","gap_id":"FOO-001","stuck_at":"old","last_error":"e","suggested_action":"review"}"#;
        fs::write(&path, format!("{body}\n")).unwrap();
        let hits = filter_escalation_events(&path, "FOO-001", 86400);
        assert!(
            hits.is_empty(),
            "expected old event to be filtered: {hits:?}"
        );
    }

    #[test]
    fn parse_iso8601_utc_known_values() {
        assert_eq!(parse_iso8601_utc_to_epoch("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_iso8601_utc_to_epoch("1970-01-02T00:00:00Z"),
            Some(86400)
        );
        // 2026-04-20 should be a large but sane epoch value (> 1.7 billion).
        let v = parse_iso8601_utc_to_epoch("2026-04-20T00:00:00Z").unwrap();
        assert!(v > 1_700_000_000, "expected > 2023 epoch, got {v}");
        // Bad input returns None.
        assert!(parse_iso8601_utc_to_epoch("not-a-date").is_none());
    }

    #[test]
    fn build_briefing_for_unknown_gap_marks_not_found() {
        let b = build_briefing("DEFINITELY-NOT-A-REAL-GAP-9999");
        assert!(b.gap_not_found);
        assert!(b.gap_title.is_empty());
    }

    /// INFRA-331: post-INFRA-188 the canonical gap layout is per-file
    /// `docs/gaps/<ID>.yaml`, not the deleted monolithic `docs/gaps.yaml`.
    /// build_briefing was reading only the monolith, so every briefing
    /// silently returned "Gap not found" on this repo. This test pins the
    /// per-file lookup so the regression can't quietly come back.
    #[test]
    fn build_briefing_at_finds_per_file_yaml_post_infra_188() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();
        fs::write(
            gaps_dir.join("INFRA-331.yaml"),
            "- id: INFRA-331\n  domain: infra\n  title: per-file briefing fix\n  status: open\n  priority: P1\n  effort: s\n",
        )
        .unwrap();

        let b = build_briefing_at("INFRA-331", dir.path());
        assert!(!b.gap_not_found, "expected per-file YAML to be found");
        assert_eq!(b.gap_title, "per-file briefing fix");
        assert_eq!(b.gap_priority, "P1");
        assert_eq!(b.gap_domain, "infra");
    }

    /// INFRA-331: the legacy monolithic `docs/gaps.yaml` path must keep
    /// working for any pre-INFRA-188 caller (e.g. external repos still on
    /// the old layout). Per-file is preferred but legacy is the fallback.
    #[test]
    fn build_briefing_at_falls_back_to_monolithic_gaps_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs");
        fs::create_dir_all(&docs).unwrap();
        fs::write(
            docs.join("gaps.yaml"),
            "- id: LEGACY-1\n  domain: infra\n  title: legacy monolith works\n  status: open\n  priority: P2\n  effort: xs\n",
        )
        .unwrap();
        // No docs/gaps/ dir — exercises the fallback path.

        let b = build_briefing_at("LEGACY-1", dir.path());
        assert!(!b.gap_not_found, "expected legacy monolith fallback");
        assert_eq!(b.gap_title, "legacy monolith works");
    }

    /// INFRA-331: when both per-file AND legacy exist, per-file wins.
    /// Defends against an old monolith laying around with stale data
    /// shadowing the canonical per-file mirror.
    #[test]
    fn build_briefing_at_prefers_per_file_over_monolith() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();
        fs::write(
            gaps_dir.join("DUP-1.yaml"),
            "- id: DUP-1\n  domain: infra\n  title: per-file wins\n  status: open\n  priority: P1\n  effort: s\n",
        )
        .unwrap();
        fs::write(
            dir.path().join("docs").join("gaps.yaml"),
            "- id: DUP-1\n  domain: infra\n  title: stale monolith\n  status: open\n  priority: P3\n  effort: xs\n",
        )
        .unwrap();

        let b = build_briefing_at("DUP-1", dir.path());
        assert_eq!(b.gap_title, "per-file wins");
        assert_eq!(b.gap_priority, "P1");
    }

    #[test]
    fn domain_path_hints_known_domains() {
        assert!(!domain_path_hints("memory").is_empty());
        assert!(!domain_path_hints("eval").is_empty());
        assert!(domain_path_hints("totally-unknown").is_empty());
    }

    /// INFRA-760: state.db is now the primary source for gap metadata.
    /// This test seeds ONLY the database (no YAML mirror) and asserts the
    /// briefing renders fully populated — the architectural property that
    /// closes the 184-of-199-open-gaps degradation hole.
    #[test]
    fn build_briefing_at_reads_from_state_db_when_no_yaml() {
        let dir = tempfile::tempdir().unwrap();

        // Seed state.db via GapStore::open (creates schema), then INSERT
        // a row directly so we don't tangle with reserve() side effects.
        let store = gap_store::GapStore::open(dir.path()).unwrap();
        let conn = store.conn_for_test();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, priority, effort, status,
                               acceptance_criteria, depends_on)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                "INFRA-760-A",
                "infra",
                "test gap from state.db",
                "P1",
                "s",
                "open",
                r#"["AC item one","AC item two"]"#,
                r#"["INFRA-754"]"#,
            ],
        )
        .unwrap();
        drop(store);

        // No docs/gaps/<ID>.yaml exists — only state.db.
        let b = build_briefing_at("INFRA-760-A", dir.path());

        assert!(
            !b.gap_not_found,
            "expected state.db read to populate the briefing"
        );
        assert_eq!(b.gap_title, "test gap from state.db");
        assert_eq!(b.gap_priority, "P1");
        assert_eq!(b.gap_effort, "s");
        assert_eq!(b.gap_domain, "infra");
        assert_eq!(b.depends_on, vec!["INFRA-754".to_string()]);

        // Acceptance is rendered as a bullet list joined from the JSON array.
        let ac = b.gap_acceptance.expect("acceptance should be Some");
        assert!(ac.contains("- AC item one"), "got: {ac}");
        assert!(ac.contains("- AC item two"), "got: {ac}");
    }

    /// INFRA-760: state.db wins over YAML when both exist. This protects
    /// against a stale YAML lying around with old data while state.db has
    /// the real current row (e.g. after `chump gap update`).
    #[test]
    fn build_briefing_at_prefers_state_db_over_yaml() {
        let dir = tempfile::tempdir().unwrap();

        // Seed state.db with one title.
        let store = gap_store::GapStore::open(dir.path()).unwrap();
        let conn = store.conn_for_test();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, priority, effort, status)
             VALUES ('CLASH-1', 'infra', 'db is canonical', 'P1', 's', 'open')",
            [],
        )
        .unwrap();
        drop(store);

        // Seed a YAML mirror with a DIFFERENT (stale) title.
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();
        fs::write(
            gaps_dir.join("CLASH-1.yaml"),
            "- id: CLASH-1\n  domain: infra\n  title: stale yaml\n  status: open\n  priority: P3\n  effort: l\n",
        )
        .unwrap();

        let b = build_briefing_at("CLASH-1", dir.path());
        assert_eq!(b.gap_title, "db is canonical");
        assert_eq!(b.gap_priority, "P1");
        assert_eq!(b.gap_effort, "s");
    }

    /// INFRA-760: when state.db lacks a row but YAML has it, fall back to
    /// YAML (preserves existing INFRA-331 behavior for any edge case).
    #[test]
    fn build_briefing_at_falls_back_to_yaml_when_db_lacks_row() {
        let dir = tempfile::tempdir().unwrap();

        // Initialise state.db schema but DON'T seed the gap.
        let store = gap_store::GapStore::open(dir.path()).unwrap();
        drop(store);

        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();
        fs::write(
            gaps_dir.join("YAML-ONLY.yaml"),
            "- id: YAML-ONLY\n  domain: infra\n  title: yaml-only fallback\n  status: open\n  priority: P2\n  effort: xs\n",
        )
        .unwrap();

        let b = build_briefing_at("YAML-ONLY", dir.path());
        assert!(!b.gap_not_found);
        assert_eq!(b.gap_title, "yaml-only fallback");
        assert_eq!(b.gap_priority, "P2");
    }

    // ── INFRA-2165: umbrella context tests ──────────────────────────────────

    /// Synthetic fixture: INFRA-XXXX depends on META-YYY; META-YYY has AC;
    /// ambient.jsonl has 3 integration_cycle_started events within 24 h.
    /// Assert briefing output contains parent AC + event manifest.
    #[test]
    fn build_umbrella_context_surfaces_parent_ac_and_cycle_events() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();

        // Seed META-YYY as the parent umbrella.
        fs::write(
            gaps_dir.join("META-900.yaml"),
            concat!(
                "- id: META-900\n",
                "  domain: infra\n",
                "  title: Test umbrella\n",
                "  status: open\n",
                "  priority: P0\n",
                "  effort: xl\n",
                "  acceptance: >\n",
                "    Mode A: dry-run.\n",
                "    Mode B: ship.\n",
            ),
        )
        .unwrap();

        // Seed INFRA-XXXX that depends on META-900.
        fs::write(
            gaps_dir.join("INFRA-9001.yaml"),
            concat!(
                "- id: INFRA-9001\n",
                "  domain: infra\n",
                "  title: child gap\n",
                "  status: open\n",
                "  priority: P1\n",
                "  effort: s\n",
                "  depends_on:\n",
                "    - META-900\n",
            ),
        )
        .unwrap();

        // Seed ambient.jsonl with 3 integration_cycle_started events (future ts
        // so they are always within any reasonable within_secs window).
        let locks_dir = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks_dir).unwrap();
        let ambient = locks_dir.join("ambient.jsonl");
        let body = concat!(
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"integration_cycle_started\",\"cycle_id\":\"c1\"}\n",
            "{\"ts\":\"2099-01-01T00:01:00Z\",\"kind\":\"integration_cycle_started\",\"cycle_id\":\"c2\"}\n",
            "{\"ts\":\"2099-01-01T00:02:00Z\",\"kind\":\"integration_cycle_started\",\"cycle_id\":\"c3\"}\n",
            "{\"ts\":\"2099-01-01T00:03:00Z\",\"kind\":\"file_edit\",\"path\":\"unrelated.rs\"}\n",
        );
        fs::write(&ambient, body).unwrap();

        let b = build_briefing_at("INFRA-9001", dir.path());

        {
            let uc = b
                .umbrella_context
                .as_ref()
                .expect("umbrella_context should be Some");
            assert_eq!(uc.meta_id, "META-900");
            assert_eq!(uc.meta_title, "Test umbrella");
            assert!(
                uc.meta_ac_truncated.contains("Mode A"),
                "AC missing: {}",
                uc.meta_ac_truncated
            );
            assert!(!uc.ac_truncated, "short AC should not be truncated");
            // 3 cycle events, file_edit excluded.
            assert_eq!(
                uc.recent_cycle_events.len(),
                3,
                "got {:?}",
                uc.recent_cycle_events
            );
            assert!(uc.recent_cycle_events[0].contains("integration_cycle_started"));
        }

        // Rendered markdown must include the umbrella section before file activity.
        let md = render_markdown(&b);
        assert!(md.contains("## Umbrella context"), "missing section: {md}");
        assert!(md.contains("META-900"), "missing meta id: {md}");
        assert!(md.contains("Test umbrella"), "missing title: {md}");
        assert!(md.contains("Mode A"), "missing AC: {md}");

        // Umbrella section must appear before Recent File Activity.
        let umbrella_pos = md.find("## Umbrella context").unwrap_or(usize::MAX);
        let file_activity_pos = md.find("## Recent File Activity").unwrap_or(usize::MAX);
        assert!(
            umbrella_pos < file_activity_pos,
            "umbrella context should appear before Recent File Activity"
        );
    }

    /// When no META dependency exists, umbrella_context is None and the
    /// rendered markdown has no umbrella section.
    #[test]
    fn build_umbrella_context_none_when_no_meta_dep() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();
        fs::write(
            gaps_dir.join("INFRA-9002.yaml"),
            concat!(
                "- id: INFRA-9002\n",
                "  domain: infra\n",
                "  title: no umbrella dep\n",
                "  status: open\n",
                "  priority: P2\n",
                "  effort: s\n",
            ),
        )
        .unwrap();

        let b = build_briefing_at("INFRA-9002", dir.path());
        assert!(
            b.umbrella_context.is_none(),
            "expected None with no META dep"
        );
        let md = render_markdown(&b);
        assert!(
            !md.contains("## Umbrella context"),
            "unexpected umbrella section in: {md}"
        );
    }

    /// When META parent not found, build_umbrella_context returns None
    /// (graceful degradation).
    #[test]
    fn build_umbrella_context_none_when_parent_missing() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();
        fs::write(
            gaps_dir.join("INFRA-9003.yaml"),
            concat!(
                "- id: INFRA-9003\n",
                "  domain: infra\n",
                "  title: orphaned child\n",
                "  status: open\n",
                "  priority: P1\n",
                "  effort: s\n",
                "  depends_on:\n",
                "    - META-9999\n",
            ),
        )
        .unwrap();
        // META-9999 deliberately not seeded.

        let b = build_briefing_at("INFRA-9003", dir.path());
        assert!(
            b.umbrella_context.is_none(),
            "expected None when parent not found"
        );
    }

    /// AC longer than 80 lines is truncated with ac_truncated=true.
    #[test]
    fn build_umbrella_context_truncates_ac_beyond_80_lines() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs").join("gaps");
        fs::create_dir_all(&gaps_dir).unwrap();

        // Seed META-901 via state.db so the acceptance JSON array produces
        // 100 bullet lines — the YAML `>` block scalar collapses to one line
        // through the tiny parser, so state.db is the right path for this test.
        let store = gap_store::GapStore::open(dir.path()).unwrap();
        let conn = store.conn_for_test();
        // Build a 100-element JSON array.
        let items: Vec<String> = (0..100).map(|i| format!("line {i}")).collect();
        let ac_json = serde_json::to_string(&items).unwrap();
        conn.execute(
            "INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                "META-901", "infra", "long AC", "P0", "xl", "open",
                ac_json,
                "[]",
            ],
        )
        .unwrap();
        // Seed INFRA-9004 child with depends_on=["META-901"].
        conn.execute(
            "INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                "INFRA-9004", "infra", "child of long-ac parent", "P1", "s", "open",
                "[]",
                r#"["META-901"]"#,
            ],
        )
        .unwrap();
        drop(store);

        let b = build_briefing_at("INFRA-9004", dir.path());
        {
            let uc = b
                .umbrella_context
                .as_ref()
                .expect("should have umbrella context");
            assert!(uc.ac_truncated, "expected truncation flag for >80-line AC");
            let line_count = uc.meta_ac_truncated.lines().count();
            assert!(
                line_count <= 80,
                "truncated AC has {line_count} lines, expected <=80"
            );
        }
        let md = render_markdown(&b);
        assert!(
            md.contains("chump gap show META-901"),
            "truncation hint missing: {md}"
        );
    }

    /// filter_cycle_events only returns integration-cycle kinds, ignores others.
    #[test]
    fn filter_cycle_events_returns_only_cycle_kinds() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        let body = concat!(
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"integration_cycle_started\"}\n",
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"integration_candidates_selected\"}\n",
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"bisect_quarantine\"}\n",
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"integration_cycle_shipped\"}\n",
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"file_edit\",\"path\":\"unrelated\"}\n",
            "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"pr_merged\"}\n",
        );
        fs::write(&path, body).unwrap();
        // Use a huge within_secs so all timestamps qualify.
        let hits = filter_cycle_events(&path, 999_999_999, 10);
        assert_eq!(hits.len(), 4, "got {:?}", hits);
        assert!(hits.iter().all(|h| {
            h.contains("integration_cycle_started")
                || h.contains("integration_candidates_selected")
                || h.contains("bisect_quarantine")
                || h.contains("integration_cycle_shipped")
        }));
    }

    /// filter_cycle_events caps at limit.
    #[test]
    fn filter_cycle_events_caps_at_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        let mut body = String::new();
        for _ in 0..20 {
            body.push_str(
                "{\"ts\":\"2099-01-01T00:00:00Z\",\"kind\":\"integration_cycle_started\"}\n",
            );
        }
        fs::write(&path, body).unwrap();
        let hits = filter_cycle_events(&path, 999_999_999, 5);
        assert_eq!(hits.len(), 5);
    }

    /// filter_cycle_events returns empty when file missing.
    #[test]
    fn filter_cycle_events_missing_file_returns_empty() {
        let hits = filter_cycle_events(Path::new("/nonexistent/ambient.jsonl"), 86400, 5);
        assert!(hits.is_empty());
    }

    // ---- INFRA-3456: comprehension-first briefing ----

    /// The consult is opt-out: `CHUMP_BRIEFING_COMPREHEND=0` short-circuits to
    /// `None` before we ever look for the binary — the deterministic disable
    /// path (the present-binary path depends on machine state, so we don't
    /// exercise it in a unit test).
    #[test]
    fn build_comprehension_disabled_flag_yields_none() {
        std::env::set_var("CHUMP_BRIEFING_COMPREHEND", "0");
        let got = build_comprehension(Path::new("/nonexistent/repo"));
        std::env::remove_var("CHUMP_BRIEFING_COMPREHEND");
        assert!(got.is_none(), "disable flag must force None, got {got:?}");
    }

    /// An unknown-gap briefing (the not-found early return) carries no
    /// comprehension — nothing to comprehend for a gap that doesn't exist.
    #[test]
    fn unknown_gap_briefing_has_no_comprehension() {
        let dir = std::env::temp_dir().join(format!("brief-comp-nf-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let b = build_briefing_at("NOPE-9999", &dir);
        assert!(b.gap_not_found);
        assert!(b.comprehension.is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    /// render_markdown surfaces the comprehension section (prominently, before
    /// the acceptance criteria) when the organ report is present.
    #[test]
    fn render_markdown_includes_comprehension_when_present() {
        let b = GapBriefing {
            gap_id: "INFRA-1".into(),
            gap_title: "t".into(),
            comprehension: Some("WIRING: full (12 live)\nGATES: partial".into()),
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(md.contains("## Comprehension (organs)"), "md=\n{md}");
        assert!(md.contains("WIRING: full (12 live)"));
        // Grounds before editing: the section precedes acceptance criteria.
        let comp_at = md.find("## Comprehension (organs)").unwrap();
        let ac_at = md.find("## Acceptance Criteria").unwrap();
        assert!(comp_at < ac_at, "comprehension must precede acceptance");
    }

    /// render_markdown hides the section entirely when there's no report, so
    /// briefings on organ-less machines stay clean.
    #[test]
    fn render_markdown_omits_comprehension_when_none() {
        let b = GapBriefing {
            gap_id: "INFRA-2".into(),
            comprehension: None,
            ..Default::default()
        };
        let md = render_markdown(&b);
        assert!(!md.contains("Comprehension (organs)"));
    }

    /// render_json emits an escaped string when present and a bare `null` when
    /// absent — a stable field for harness consumers either way.
    #[test]
    fn render_json_carries_comprehension_field() {
        let present = GapBriefing {
            gap_id: "INFRA-3".into(),
            comprehension: Some("line1\n\"q\"".into()),
            ..Default::default()
        };
        let j = render_json(&present);
        assert!(
            j.contains(r#""comprehension":"line1\n\"q\"""#),
            "json=\n{j}"
        );

        let absent = GapBriefing {
            gap_id: "INFRA-4".into(),
            comprehension: None,
            ..Default::default()
        };
        assert!(render_json(&absent).contains(r#""comprehension":null"#));
    }

    #[test]
    fn parse_backlog_file_valid_beast_mode_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".beast-mode-tasks.json");
        fs::write(&path, r#"[{"title":"Add retries"},{"title":"Fix flake"}]"#).unwrap();

        let tasks = parse_backlog_file(&path).unwrap();
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].title, "Add retries");
        assert_eq!(tasks[1].title, "Fix flake");
    }

    #[test]
    fn parse_backlog_file_valid_plain_text() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("TODO");
        let lines = ["Write tests", "Ship feature", "Update docs"];
        fs::write(&path, lines.join("\n")).unwrap();

        let tasks = parse_backlog_file(&path).unwrap();
        assert_eq!(tasks.len(), lines.len());
        for (task, line) in tasks.iter().zip(lines.iter()) {
            assert_eq!(task.title, *line);
        }
    }

    #[test]
    fn parse_backlog_file_malformed_json_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".beast-mode-tasks.json");
        fs::write(&path, r#"[{"title": "missing closing brace""#).unwrap();

        let err = parse_backlog_file(&path).unwrap_err();
        match err {
            BacklogParseError::MalformedJson(msg) => {
                assert!(msg.contains("malformed"), "msg=\n{msg}");
            }
            other => panic!("expected MalformedJson, got {other:?}"),
        }
    }
}
