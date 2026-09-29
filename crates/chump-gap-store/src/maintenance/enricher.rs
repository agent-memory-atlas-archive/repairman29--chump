//! EFFECTIVE-446: proactive gap-spec **enricher** — turn thin, vague open gaps
//! into CONCRETE, file-pointed specs the cheap DeepSeek-v4-flash floor can ship.
//!
//! EFFECTIVE-449 (this module's slice of EFFECTIVE-446): the pure, unit-tested
//! core — [`classify_thinness`], [`build_enrich_prompt`], [`parse_enriched_spec`],
//! and [`EnrichedSpec::to_field_update`] — lives entirely below with no I/O in
//! the detection/parsing path, so it's covered by the `#[cfg(test)]` module at
//! the bottom without a live Almanac or LLM call.
//!
//! ## Why (the proven basis — EFFECTIVE-445)
//!
//! DeepSeek-v4-flash lands a CONCRETE gap with a named target file for ~$0.01
//! (receipt: CREDIBLE-111 → PR #4180, real `str_replace` edits) but SPINS on
//! thin-spec investigate gaps (CREDIBLE-120: 30 iters, 0 edits; CREDIBLE-110:
//! gave up). The dividing line is **gap-spec concreteness, not model power**
//! (`docs/strategy/MODEL_ROUTING_LADDER_2026-07-22.md`). So: enrich the spec
//! ONCE upstream and the whole cheap floor eats far more of the backlog. The
//! capable enrichment call (deepseek-v4-pro, ~$0.01–0.03 once) costs far less
//! than the repeated cheap-floor spins + Claude escalations it prevents.
//!
//! ## What this EXTENDS (mine-before-build — not a rebuild)
//!
//! - [`super::architect`] — reuses its [`super::architect::LlmClient`] trait,
//!   the YAML fence-stripping parse pattern, and the
//!   build-prompt → call-model → parse spine. architect DECOMPOSES one big gap
//!   into many sub-gaps; this enricher REWRITES one thin gap **in place** (never
//!   manufactures new gaps — anti-bloat).
//! - [`crate::acceptance_criteria_is_vague`] + [`crate::parse_json_ac_list`] —
//!   reused verbatim for thin-spec detection (no new heuristic invented).
//! - [`crate::GapStore::set_fields`] / [`crate::GapFieldUpdate`] — the in-place
//!   write-back to the EXISTING gap.
//! - **Almanac** (`almanac search --json`) — the KEY new input: `file:line` for
//!   WHERE the gap's target lives, which is exactly the pointer thin gaps lack.
//!
//! The LLM and Almanac boundaries are both traits so the whole pipeline is
//! unit-tested with mocks and never makes a live call in CI.

use serde::{Deserialize, Serialize};

use crate::{GapFieldUpdate, GapRow, GapStore};

pub use super::architect::{ArchitectError, LlmClient};

/// A description shorter than this (after trim) counts as thin. A one-line
/// title-echo description gives a weak model nothing to anchor on.
const THIN_DESCRIPTION_CHARS: usize = 120;

/// Why a gap reads as thin-spec — the signals the cheap floor spins on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThinReason {
    /// Neither the description nor any AC bullet names a file path — the model
    /// has no pointer to where the change lives.
    NoFilePointer,
    /// `acceptance_criteria` is empty (nothing to converge toward).
    EmptyAc,
    /// `acceptance_criteria` is present but vague (TODO/TBD/placeholder) per
    /// [`crate::acceptance_criteria_is_vague`].
    VagueAc,
    /// The description is empty or a one-line title-echo.
    ThinDescription,
}

impl ThinReason {
    /// Short stable tag for JSON / logs.
    pub fn tag(self) -> &'static str {
        match self {
            ThinReason::NoFilePointer => "no_file_pointer",
            ThinReason::EmptyAc => "empty_ac",
            ThinReason::VagueAc => "vague_ac",
            ThinReason::ThinDescription => "thin_description",
        }
    }
}

/// The result of classifying a gap's spec quality.
#[derive(Debug, Clone, Default)]
pub struct Thinness {
    pub reasons: Vec<ThinReason>,
}

impl Thinness {
    /// True when the gap carries at least one thin-spec signal — i.e. the cheap
    /// floor is at risk of spinning on it.
    pub fn is_thin(&self) -> bool {
        !self.reasons.is_empty()
    }

    /// Comma-joined reason tags (stable order), for logs / JSON.
    pub fn tags(&self) -> String {
        self.reasons
            .iter()
            .map(|r| r.tag())
            .collect::<Vec<_>>()
            .join(",")
    }
}

/// True if `text` contains a path-like token: a `dir/file` slash-path or a bare
/// filename ending in a code/config extension. Deliberately conservative — this
/// mirrors the file-pointer signal `pr_ac_coverage::rule_a` keys off, ported
/// here so this dep-light crate needn't pull in `chump-verify`.
fn has_file_pointer(text: &str) -> bool {
    const EXTS: &[&str] = &[
        ".rs", ".sh", ".py", ".yaml", ".yml", ".toml", ".md", ".ts", ".tsx", ".js", ".jsx", ".sql",
        ".json", ".css", ".html",
    ];
    for raw in text.split(|c: char| c.is_whitespace()) {
        let token = raw.trim_matches(|c: char| "'\"`(),;:[]{}".contains(c));
        if token.len() < 3 {
            continue;
        }
        // A slash-path that plausibly names a file: >=2 non-empty segments
        // AND either a dotted filename or real depth (>=2 slashes). This keeps
        // `src/foo.rs`, `crates/x/src/lib.rs`, `scripts/ci/test-foo.sh` while
        // rejecting prose fragments like `and/or` or a bare `a/b`.
        if token.contains('/') {
            let segs = token.split('/').filter(|s| !s.is_empty()).count();
            let slashes = token.matches('/').count();
            if segs >= 2 && (token.contains('.') || slashes >= 2) {
                return true;
            }
        }
        // A bare filename with a known extension.
        if EXTS.iter().any(|ext| token.ends_with(ext)) {
            return true;
        }
    }
    false
}

/// Classify a gap's spec quality. Pure — reuses the crate's own vagueness
/// detector and AC parser rather than inventing a new heuristic.
pub fn classify_thinness(gap: &GapRow) -> Thinness {
    let mut reasons = Vec::new();

    let ac_items = crate::parse_json_ac_list(&gap.acceptance_criteria);
    if ac_items.is_empty() {
        reasons.push(ThinReason::EmptyAc);
    } else if crate::acceptance_criteria_is_vague(&gap.acceptance_criteria) {
        reasons.push(ThinReason::VagueAc);
    }

    let desc = gap.description.trim();
    if desc.len() < THIN_DESCRIPTION_CHARS {
        reasons.push(ThinReason::ThinDescription);
    }

    // A file pointer anywhere in the description OR the AC bullets clears the
    // NoFilePointer flag — that is the single signal that most separates a
    // flash-shippable gap from a spin.
    let ac_blob = ac_items.join("\n");
    if !has_file_pointer(desc) && !has_file_pointer(&ac_blob) {
        reasons.push(ThinReason::NoFilePointer);
    }

    Thinness { reasons }
}

// ── Almanac boundary ────────────────────────────────────────────────────────

/// One Almanac search hit — the `file:line` pointer a thin gap lacks.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AlmanacHit {
    /// `path:line` (e.g. `scripts/dispatch/fleet-brief.sh:43`).
    pub citation: String,
    pub path: String,
    #[serde(default)]
    pub line: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub kind: String,
}

/// Where a gap's target lives — the Almanac lookup boundary. Mockable so the
/// pipeline is testable without a live index.
pub trait AlmanacClient {
    /// Return up to `limit` ranked hits for `query` (empty on any failure —
    /// enrichment degrades to LLM-only rather than erroring).
    fn search(&self, query: &str, limit: usize) -> Vec<AlmanacHit>;
}

/// Shells out to the `almanac` CLI (`almanac search <query> <repo> --json`).
/// Binary path via `CHUMP_ALMANAC_BIN` (default `almanac`); repo name via the
/// constructor. Host-agnostic: a missing binary or a zero-hit index yields an
/// empty vec, never a hard failure.
pub struct CliAlmanacClient {
    pub bin: String,
    pub repo: String,
}

impl CliAlmanacClient {
    pub fn new(repo: impl Into<String>) -> Self {
        let bin = std::env::var("CHUMP_ALMANAC_BIN").unwrap_or_else(|_| "almanac".to_string());
        Self {
            bin,
            repo: repo.into(),
        }
    }
}

impl AlmanacClient for CliAlmanacClient {
    fn search(&self, query: &str, limit: usize) -> Vec<AlmanacHit> {
        let out = std::process::Command::new(&self.bin)
            .arg("search")
            .arg(query)
            .arg(&self.repo)
            .arg("--json")
            .arg("--limit")
            .arg(limit.to_string())
            .output();
        let out = match out {
            Ok(o) if o.status.success() => o,
            _ => return Vec::new(),
        };
        parse_almanac_hits(&String::from_utf8_lossy(&out.stdout))
    }
}

/// Parse the `hits` array out of `almanac search --json` output. Tolerant: a
/// malformed body or a missing `hits` key yields an empty vec.
pub fn parse_almanac_hits(json: &str) -> Vec<AlmanacHit> {
    let v: serde_json::Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let Some(arr) = v.get("hits").and_then(|h| h.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|h| serde_json::from_value::<AlmanacHit>(h.clone()).ok())
        .collect()
}

// ── enriched spec ───────────────────────────────────────────────────────────

/// The concrete spec the capable model produces — the three things a thin gap
/// lacks: named target file(s), a specific change intent, and testable AC.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct EnrichedSpec {
    /// Named target file paths (relative to repo root).
    #[serde(default)]
    pub target_files: Vec<String>,
    /// One paragraph: the specific change to make.
    #[serde(default)]
    pub change_intent: String,
    /// Concrete, individually-testable acceptance criteria.
    #[serde(default)]
    pub acceptance_criteria: Vec<String>,
}

impl EnrichedSpec {
    /// True when the model returned something usable (a target file AND at
    /// least one AC bullet). A spec missing either is not written back.
    pub fn is_usable(&self) -> bool {
        !self.target_files.is_empty() && !self.acceptance_criteria.is_empty()
    }

    /// Build the in-place [`GapFieldUpdate`]: a rewritten description that leads
    /// with the change intent and names the target files, plus AC stored in the
    /// canonical JSON-array-string column shape. The original description is
    /// preserved as trailing context so no filer intent is lost.
    pub fn to_field_update(&self, original_description: &str) -> GapFieldUpdate {
        let mut desc = String::new();
        desc.push_str(self.change_intent.trim());
        desc.push_str("\n\nTarget file(s):\n");
        for f in &self.target_files {
            desc.push_str("- ");
            desc.push_str(f.trim());
            desc.push('\n');
        }
        desc.push_str("\n(Spec enriched by chump-gap-enricher — EFFECTIVE-446. ");
        desc.push_str("Original filer context preserved below.)\n");
        let orig = original_description.trim();
        if !orig.is_empty() {
            desc.push_str("\n--- original ---\n");
            desc.push_str(orig);
            desc.push('\n');
        }

        // AC stored as a JSON array string (the canonical column shape
        // `parse_json_ac_list` reads back).
        let ac_json =
            serde_json::to_string(&self.acceptance_criteria).unwrap_or_else(|_| "[]".into());

        GapFieldUpdate {
            description: Some(desc),
            acceptance_criteria: Some(ac_json),
            ..Default::default()
        }
    }
}

/// Strip a leading ```yaml / ``` fence and trailing ``` (LLMs love to add them),
/// mirroring `architect::parse_yaml_from_response`.
fn strip_fences(text: &str) -> String {
    let trimmed = text.trim();
    let mut body = trimmed.to_string();
    for fence in ["```yaml\n", "```yml\n", "```json\n", "```\n"] {
        if let Some(rest) = body.strip_prefix(fence) {
            body = rest.to_string();
            break;
        }
    }
    if let Some(end) = body.rfind("```") {
        body.truncate(end);
    }
    body
}

/// Parse the capable model's reply into an [`EnrichedSpec`]. JSON-first, YAML
/// fallback (EFFECTIVE-447): we now ask the model for a JSON object, whose
/// double-quoted strings make colons/brackets in `change_intent` safe —
/// serde_yaml choked on the model's `>-` folded scalar with unquoted colons
/// (~33% of enrichments lost). JSON is tried first because serde_yaml parses
/// JSON too but the reverse is not true; YAML fallback keeps older/looser
/// replies working.
pub fn parse_enriched_spec(text: &str) -> Result<EnrichedSpec, ArchitectError> {
    let body = strip_fences(text);
    let v: serde_yaml::Value = match serde_json::from_str::<serde_json::Value>(&body) {
        Ok(j) => serde_yaml::to_value(j)
            .map_err(|e| ArchitectError::Parse(format!("enriched-spec json->value: {e}")))?,
        Err(_) => serde_yaml::from_str(&body)
            .map_err(|e| ArchitectError::Parse(format!("enriched-spec parse: {e}")))?,
    };
    Ok(EnrichedSpec {
        target_files: coerce_str_list(v.get("target_files")),
        change_intent: v
            .get("change_intent")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .to_string(),
        acceptance_criteria: coerce_str_list(v.get("acceptance_criteria")),
    })
}

/// Coerce a YAML value into a list of strings, tolerating models that emit a
/// bare scalar, or list entries that are maps / nested values rather than plain
/// strings (a real DeepSeek-v4 formatting variance observed in the EFFECTIVE-446
/// proof runs — an AC bullet came back as a `{check: ..., expect: ...}` map).
/// Nothing is dropped: a non-string entry is compacted to a one-line YAML
/// string so the spec stays usable.
fn coerce_str_list(v: Option<&serde_yaml::Value>) -> Vec<String> {
    fn one(v: &serde_yaml::Value) -> Option<String> {
        match v {
            serde_yaml::Value::String(s) => {
                let t = s.trim();
                (!t.is_empty()).then(|| t.to_string())
            }
            serde_yaml::Value::Null => None,
            other => {
                let s = serde_yaml::to_string(other).ok()?;
                let s = s.trim().trim_end_matches("\n...").trim().replace('\n', " ");
                (!s.is_empty()).then_some(s)
            }
        }
    }
    match v {
        Some(serde_yaml::Value::Sequence(seq)) => seq.iter().filter_map(one).collect(),
        Some(scalar @ serde_yaml::Value::String(_)) => one(scalar).into_iter().collect(),
        _ => Vec::new(),
    }
}

// ── prompt ──────────────────────────────────────────────────────────────────

/// Build the query Almanac is asked to locate the gap's target with: the title
/// plus the domain, with the pillar-prefix noise trimmed.
pub fn build_almanac_query(gap: &GapRow) -> String {
    // Drop a leading "PILLAR:" / "PILLAR PN:" tag so the query is about the work.
    let title = gap.title.trim();
    let after_colon = title
        .split_once(':')
        .map(|(_, r)| r.trim())
        .unwrap_or(title);
    after_colon.to_string()
}

/// Build the ONE capable-model enrichment prompt. Pure — the Almanac hits are
/// injected as candidate locations so the model names REAL files (grounded),
/// never a hallucinated path.
pub fn build_enrich_prompt(gap: &GapRow, hits: &[AlmanacHit]) -> String {
    let mut hits_block = String::new();
    if hits.is_empty() {
        hits_block.push_str("(no Almanac hits — infer the target from the title/description)\n");
    } else {
        for h in hits {
            hits_block.push_str("- ");
            hits_block.push_str(&h.citation);
            if !h.name.is_empty() {
                hits_block.push_str("  (");
                hits_block.push_str(&h.kind);
                hits_block.push(' ');
                hits_block.push_str(&h.name);
                hits_block.push(')');
            }
            hits_block.push('\n');
        }
    }

    let desc = if gap.description.trim().is_empty() {
        "(no description)"
    } else {
        gap.description.trim()
    };

    format!(
        "You are enriching a THIN software-gap spec into a CONCRETE one so a cheap, \
weak coding model can ship it in one pass. The weak model FAILS on vague gaps \
(it investigates forever and never edits) and SUCCEEDS when told exactly which \
file to change and what 'done' looks like.\n\
\n\
GAP\n\
  id: {id}\n\
  title: {title}\n\
  domain: {domain}\n\
  current description: {desc}\n\
  current acceptance_criteria: {ac}\n\
\n\
ALMANAC HITS (real file:line locations in this repo for the gap's topic — \
prefer these; do NOT invent paths):\n\
{hits}\n\
\n\
TASK\n\
  Emit ONE JSON object (no prose, no markdown fence) with EXACTLY these keys:\n\
    \"target_files\": array of 1-3 real repo-relative file-path strings this change touches\n\
    \"change_intent\": one-paragraph string naming the specific edit: which function/section changes and how\n\
    \"acceptance_criteria\": array of 2-4 CONCRETE, individually-testable bullet strings\n\
  Output valid JSON only — every string double-quoted, so colons, brackets and\n\
  other punctuation inside a value can never break parsing.\n\
\n\
RULES\n\
  - target_files MUST be real paths — use the Almanac hits above when relevant.\n\
  - Every acceptance_criteria bullet must name a file, function, command, or an \
observable output — never 'works correctly' or 'is fixed'.\n\
  - Keep the ORIGINAL intent of the gap; make it precise, do not redefine it.\n\
  - Prefer the smallest correct change (xs/s shippable).\n",
        id = gap.id,
        title = gap.title,
        domain = gap.domain,
        desc = desc,
        ac = if gap.acceptance_criteria.trim().is_empty() {
            "(none)"
        } else {
            gap.acceptance_criteria.trim()
        },
        hits = hits_block.trim_end(),
    )
}

// ── orchestrator ────────────────────────────────────────────────────────────

/// What the enricher did / would do, for JSON output + tests.
#[derive(Debug)]
pub struct EnrichOutcome {
    pub gap_id: String,
    pub thinness: Thinness,
    pub hits: Vec<AlmanacHit>,
    /// The built prompt (always present — useful for `--dry-run`).
    pub prompt: String,
    /// The parsed spec (None in dry-run or when the gap was skipped).
    pub spec: Option<EnrichedSpec>,
    /// True when the enriched spec was written back to the store.
    pub applied: bool,
    /// Set when the gap was skipped (already concrete, or spec unusable).
    pub skipped_reason: Option<String>,
}

/// How far to run the pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnrichMode {
    /// Detect + Almanac + build prompt only. No LLM call, no write.
    DryRun,
    /// Detect + Almanac + LLM. Parse the spec but do NOT write it back.
    Preview,
    /// Full pipeline: detect + Almanac + LLM + write-back to the gap in place.
    Apply,
}

/// Repo-rooted enricher over an [`AlmanacClient`] + [`LlmClient`].
pub struct Enricher<A: AlmanacClient, L: LlmClient> {
    repo_root: std::path::PathBuf,
    almanac: A,
    llm: L,
    /// When true, enrich even a gap that classifies as already-concrete.
    pub force: bool,
    /// Almanac hit budget.
    pub almanac_limit: usize,
}

impl<A: AlmanacClient, L: LlmClient> Enricher<A, L> {
    pub fn new(repo_root: impl AsRef<std::path::Path>, almanac: A, llm: L) -> Self {
        Self {
            repo_root: repo_root.as_ref().to_path_buf(),
            almanac,
            llm,
            force: false,
            almanac_limit: 6,
        }
    }

    /// Run the pipeline for one gap.
    pub async fn enrich(
        &self,
        gap_id: &str,
        mode: EnrichMode,
    ) -> Result<EnrichOutcome, ArchitectError> {
        let store =
            GapStore::open(&self.repo_root).map_err(|e| ArchitectError::Store(e.to_string()))?;
        let gap = store
            .get(gap_id)
            .map_err(|e| ArchitectError::Store(e.to_string()))?
            .ok_or_else(|| ArchitectError::GapNotFound(gap_id.to_string()))?;

        let thinness = classify_thinness(&gap);
        if !thinness.is_thin() && !self.force {
            return Ok(EnrichOutcome {
                gap_id: gap.id.clone(),
                thinness,
                hits: Vec::new(),
                prompt: String::new(),
                spec: None,
                applied: false,
                skipped_reason: Some("already concrete (no thin-spec signals)".to_string()),
            });
        }

        let query = build_almanac_query(&gap);
        let hits = self.almanac.search(&query, self.almanac_limit);
        let prompt = build_enrich_prompt(&gap, &hits);

        if mode == EnrichMode::DryRun {
            return Ok(EnrichOutcome {
                gap_id: gap.id.clone(),
                thinness,
                hits,
                prompt,
                spec: None,
                applied: false,
                skipped_reason: None,
            });
        }

        let raw = self.llm.complete(&prompt).await?;
        let spec = parse_enriched_spec(&raw)?;

        if !spec.is_usable() {
            return Ok(EnrichOutcome {
                gap_id: gap.id.clone(),
                thinness,
                hits,
                prompt,
                spec: Some(spec),
                applied: false,
                skipped_reason: Some(
                    "model returned no usable target_files + acceptance_criteria".to_string(),
                ),
            });
        }

        let applied = if mode == EnrichMode::Apply {
            let update = spec.to_field_update(&gap.description);
            store
                .set_fields(&gap.id, update)
                .map_err(|e| ArchitectError::Store(e.to_string()))?;
            true
        } else {
            false
        };

        Ok(EnrichOutcome {
            gap_id: gap.id.clone(),
            thinness,
            hits,
            prompt,
            spec: Some(spec),
            applied,
            skipped_reason: None,
        })
    }
}

// ── a configurable-command LLM client (shared with the bin) ─────────────────

/// An [`LlmClient`] that shells a configurable command, writing the prompt to
/// its stdin and reading the completion from stdout. This is how the enricher
/// reaches the capable model host-agnostically: the default command is
/// `chump llm-complete` (the sanctioned provider-cascade gateway → DeepSeek-v4
/// on a funded host), overridable via `CHUMP_ENRICH_LLM_CMD` (space-split argv)
/// for a specific model (e.g. a curl-to-OpenRouter wrapper pinning
/// `deepseek-v4-pro`).
pub struct CommandLlmClient {
    pub argv: Vec<String>,
}

impl CommandLlmClient {
    /// Build from `CHUMP_ENRICH_LLM_CMD` (space-split) or the default
    /// `chump llm-complete --max-tokens 1200`.
    pub fn from_env() -> Self {
        let argv = match std::env::var("CHUMP_ENRICH_LLM_CMD") {
            Ok(s) if !s.trim().is_empty() => s.split_whitespace().map(|t| t.to_string()).collect(),
            // 4096 gives reasoning models (DeepSeek-v4 flash/pro spend
            // `reasoning_tokens` before emitting content) headroom to still
            // return the small YAML spec; a low cap yields empty content (the
            // EFFECTIVE-445 gotcha). Enrichment output itself is tiny.
            _ => vec![
                "chump".to_string(),
                "llm-complete".to_string(),
                "--max-tokens".to_string(),
                "4096".to_string(),
            ],
        };
        Self { argv }
    }
}

#[async_trait::async_trait]
impl LlmClient for CommandLlmClient {
    async fn complete(&self, prompt: &str) -> Result<String, ArchitectError> {
        use std::io::Write;
        use std::process::Stdio;

        let argv = self.argv.clone();
        let prompt = prompt.to_string();
        let handle = tokio::task::spawn_blocking(move || -> Result<String, ArchitectError> {
            let (cmd, rest) = argv
                .split_first()
                .ok_or_else(|| ArchitectError::Llm("empty CHUMP_ENRICH_LLM_CMD".to_string()))?;
            let mut child = std::process::Command::new(cmd)
                .args(rest)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| ArchitectError::Llm(format!("spawn {cmd} failed: {e}")))?;
            if let Some(mut si) = child.stdin.take() {
                si.write_all(prompt.as_bytes())
                    .map_err(|e| ArchitectError::Llm(format!("write stdin: {e}")))?;
            }
            let out = child
                .wait_with_output()
                .map_err(|e| ArchitectError::Llm(format!("wait failed: {e}")))?;
            if !out.status.success() {
                return Err(ArchitectError::Llm(format!(
                    "{cmd} exited {} stderr={}",
                    out.status,
                    String::from_utf8_lossy(&out.stderr)
                )));
            }
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        });
        match handle.await {
            Ok(r) => r,
            Err(e) => Err(ArchitectError::Llm(format!("join: {e}"))),
        }
    }
}

// ── OpenRouter model metadata (EFFECTIVE-1298, EFFECTIVE-409 slice) ─────────

/// Raw `openrouter.ai/api/v1/models` GET boundary — a trait so tests never
/// make a live network call, mirroring [`AlmanacClient`] and [`LlmClient`]
/// above.
#[async_trait::async_trait]
pub trait OpenRouterClient {
    /// Fetch the full model catalog. `Err` carries a human-readable reason
    /// (HTTP status, transport error, or parse failure).
    async fn fetch_models(&self) -> Result<Vec<crate::OpenRouterModel>, String>;
}

/// GETs `https://openrouter.ai/api/v1/models` with the configured slot-11 key
/// (`CHUMP_PROVIDER_11_KEY`, the same env-var naming `provider_cascade.rs`
/// uses for every numbered slot) as a Bearer token.
pub struct HttpOpenRouterClient {
    pub base_url: String,
    pub api_key: String,
}

impl HttpOpenRouterClient {
    /// Reads the key from `CHUMP_PROVIDER_11_KEY` (empty if unset — the
    /// request is still attempted so the resulting 401 is logged like any
    /// other API failure rather than silently skipped).
    pub fn from_env() -> Self {
        Self {
            base_url: "https://openrouter.ai/api/v1/models".to_string(),
            api_key: std::env::var("CHUMP_PROVIDER_11_KEY").unwrap_or_default(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct OpenRouterModelsResponse {
    #[serde(default)]
    data: Vec<crate::OpenRouterModel>,
}

#[async_trait::async_trait]
impl OpenRouterClient for HttpOpenRouterClient {
    async fn fetch_models(&self) -> Result<Vec<crate::OpenRouterModel>, String> {
        let resp = reqwest::Client::new()
            .get(&self.base_url)
            .bearer_auth(&self.api_key)
            .send()
            .await
            .map_err(|e| format!("openrouter GET {} failed: {e}", self.base_url))?;
        if !resp.status().is_success() {
            return Err(format!(
                "openrouter GET {} returned HTTP {}",
                self.base_url,
                resp.status()
            ));
        }
        let body: OpenRouterModelsResponse = resp
            .json()
            .await
            .map_err(|e| format!("openrouter response parse failed: {e}"))?;
        Ok(body.data)
    }
}

/// Fetch the OpenRouter catalog via `client` and mutate the store's
/// `openrouter_model_metadata` index in place (see
/// [`GapStore::upsert_openrouter_model_metadata`] — a per-row UPSERT, never a
/// full table rebuild). Logs a one-line success/failure receipt either way so
/// a scheduled run leaves an audit trail without a dedicated event kind.
pub async fn fetch_and_store_openrouter_models(
    store: &GapStore,
    client: &dyn OpenRouterClient,
) -> Result<usize, String> {
    match client.fetch_models().await {
        Ok(models) => {
            let n = models.len();
            match store.upsert_openrouter_model_metadata(&models) {
                Ok(count) => {
                    eprintln!(
                        "[openrouter-enrich] fetched {n} models, upserted {count} into openrouter_model_metadata"
                    );
                    Ok(count)
                }
                Err(e) => {
                    eprintln!("[openrouter-enrich] store upsert failed: {e}");
                    Err(format!("store upsert failed: {e}"))
                }
            }
        }
        Err(e) => {
            eprintln!("[openrouter-enrich] fetch failed: {e}");
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn gap(id: &str, desc: &str, ac_json: &str) -> GapRow {
        GapRow {
            id: id.to_string(),
            domain: "INFRA".to_string(),
            title: "INFRA: fix the fleet brief exit code".to_string(),
            description: desc.to_string(),
            priority: "P2".to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: ac_json.to_string(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: String::new(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    // Mock LLM: returns a fixed canned reply regardless of prompt.
    struct MockLlm(String);
    #[async_trait::async_trait]
    impl LlmClient for MockLlm {
        async fn complete(&self, _prompt: &str) -> Result<String, ArchitectError> {
            Ok(self.0.clone())
        }
    }

    // Mock Almanac: returns fixed hits.
    struct MockAlmanac(Vec<AlmanacHit>);
    impl AlmanacClient for MockAlmanac {
        fn search(&self, _q: &str, _l: usize) -> Vec<AlmanacHit> {
            self.0.clone()
        }
    }

    #[test]
    fn has_file_pointer_detects_paths_and_extensions() {
        assert!(has_file_pointer("touch src/dispatch/worker.sh line 20"));
        assert!(has_file_pointer("edit crates/chump-gap-store/src/lib.rs"));
        assert!(has_file_pointer("the file worker.sh needs a guard"));
        assert!(!has_file_pointer(
            "make the fleet brief exit non-zero on failure"
        ));
        assert!(!has_file_pointer("a/b")); // too-trivial slash-path, no real segment
    }

    #[test]
    fn thin_gap_flagged_concrete_gap_cleared() {
        // Thin: empty AC, one-line title-echo description, no path.
        let thin = gap("INFRA-1", "fix the exit code", "");
        let t = classify_thinness(&thin);
        assert!(t.is_thin());
        assert!(t.reasons.contains(&ThinReason::EmptyAc));
        assert!(t.reasons.contains(&ThinReason::NoFilePointer));
        assert!(t.reasons.contains(&ThinReason::ThinDescription));

        // Concrete: names a file, long description, specific AC.
        let ac = serde_json::to_string(&vec![
            "scripts/dispatch/fleet-brief.sh returns exit 1 when git log is empty",
        ])
        .unwrap();
        let concrete = gap(
            "INFRA-2",
            "In scripts/dispatch/fleet-brief.sh the _git_log_1h function swallows the \
             empty case; make it return non-zero so run-fleet.sh can detect a stalled fleet.",
            &ac,
        );
        let t2 = classify_thinness(&concrete);
        assert!(!t2.is_thin(), "reasons: {}", t2.tags());
    }

    #[test]
    fn vague_ac_is_thin() {
        let ac = serde_json::to_string(&vec!["TODO: write acceptance criteria"]).unwrap();
        let g = gap(
            "INFRA-3",
            "A sufficiently long description that names crates/chump-gap-store/src/lib.rs so \
             the file-pointer signal is satisfied and only the vague AC remains.",
            &ac,
        );
        let t = classify_thinness(&g);
        assert!(t.reasons.contains(&ThinReason::VagueAc));
        assert!(!t.reasons.contains(&ThinReason::NoFilePointer));
    }

    #[test]
    fn prompt_embeds_almanac_citations_and_title() {
        let g = gap("INFRA-4", "thin", "");
        let hits = vec![AlmanacHit {
            citation: "scripts/dispatch/fleet-brief.sh:43".to_string(),
            path: "scripts/dispatch/fleet-brief.sh".to_string(),
            line: 43,
            name: "_git_log_1h".to_string(),
            kind: "fn".to_string(),
        }];
        let p = build_enrich_prompt(&g, &hits);
        assert!(p.contains("scripts/dispatch/fleet-brief.sh:43"));
        assert!(p.contains("_git_log_1h"));
        assert!(p.contains("fix the fleet brief exit code"));
        assert!(p.contains("target_files"));
    }

    #[test]
    fn parse_spec_coerces_map_ac_entry() {
        // DeepSeek-v4 sometimes emits an AC bullet as a map rather than a string.
        let raw = "target_files:\n  - src/foo.rs\nchange_intent: do the thing\nacceptance_criteria:\n  - a plain string bullet\n  - {check: run tests, expect: green}\n";
        let spec = parse_enriched_spec(raw).unwrap();
        assert_eq!(spec.target_files, vec!["src/foo.rs"]);
        assert_eq!(spec.acceptance_criteria.len(), 2);
        assert!(spec.is_usable());
    }

    #[test]
    fn parse_spec_json_with_colons_and_brackets() {
        // EFFECTIVE-447 regression: the model now returns a JSON object. Its
        // double-quoted change_intent contains colons and brackets that would
        // break serde_yaml tokenization ("found character that cannot start any
        // token"), but parse cleanly as JSON via the JSON-first path.
        let raw = "{\"target_files\": [\"src/foo.rs\"], \"change_intent\": \"In fn bar: replace s[..n] with s.get(..n); note the [dep] block\", \"acceptance_criteria\": [\"cargo test bar_boundary passes\", \"no panic on multibyte input\"]}";
        let spec = parse_enriched_spec(raw).unwrap();
        assert_eq!(spec.target_files, vec!["src/foo.rs"]);
        assert!(spec.change_intent.contains("s.get(..n)"));
        assert_eq!(spec.acceptance_criteria.len(), 2);
        assert!(spec.is_usable());
    }

    #[test]
    fn parse_spec_fenced_json() {
        // The model may still wrap the JSON in a ```json fence; strip_fences
        // handles it and JSON-first parses the body.
        let raw = "```json\n{\"target_files\": [\"a.rs\"], \"change_intent\": \"do: it\", \"acceptance_criteria\": [\"x works\"]}\n```";
        let spec = parse_enriched_spec(raw).unwrap();
        assert_eq!(spec.target_files, vec!["a.rs"]);
        assert!(spec.is_usable());
    }

    #[test]
    fn parse_spec_handles_fenced_yaml() {
        let raw = "```yaml\ntarget_files:\n  - scripts/dispatch/fleet-brief.sh\nchange_intent: make it exit 1\nacceptance_criteria:\n  - fleet-brief.sh exits 1 on empty log\n```";
        let spec = parse_enriched_spec(raw).unwrap();
        assert_eq!(spec.target_files, vec!["scripts/dispatch/fleet-brief.sh"]);
        assert!(spec.is_usable());
    }

    #[test]
    fn to_field_update_encodes_ac_as_json_and_names_files() {
        let spec = EnrichedSpec {
            target_files: vec!["scripts/dispatch/fleet-brief.sh".to_string()],
            change_intent: "Return non-zero on empty log.".to_string(),
            acceptance_criteria: vec![
                "fleet-brief.sh exits 1 when git log is empty".to_string(),
                "scripts/ci/test-fleet-brief.sh asserts the exit code".to_string(),
            ],
        };
        let upd = spec.to_field_update("original thin desc");
        let ac = upd.acceptance_criteria.unwrap();
        let parsed = crate::parse_json_ac_list(&ac);
        assert_eq!(parsed.len(), 2);
        // The rewritten description must NO LONGER be thin: it names the file.
        let desc = upd.description.unwrap();
        assert!(has_file_pointer(&desc));
        assert!(desc.contains("original thin desc"));
    }

    #[tokio::test]
    async fn end_to_end_apply_rewrites_gap_in_place() {
        use tempfile::TempDir;
        let dir = TempDir::new().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        // Seed a thin gap (empty AC, short desc, no path).
        let id = store
            .reserve("INFRA", "INFRA: make fleet brief fail loudly", "P2", "s")
            .unwrap();

        // Before: classifies as thin.
        let before = store.get(&id).unwrap().unwrap();
        assert!(classify_thinness(&before).is_thin());

        let canned = "target_files:\n  - scripts/dispatch/fleet-brief.sh\nchange_intent: Make _git_log_1h return non-zero when the log is empty.\nacceptance_criteria:\n  - scripts/dispatch/fleet-brief.sh exits 1 on empty 1h log\n  - run-fleet.sh reaps the fleet when brief exits non-zero";
        let almanac = MockAlmanac(vec![AlmanacHit {
            citation: "scripts/dispatch/fleet-brief.sh:43".to_string(),
            path: "scripts/dispatch/fleet-brief.sh".to_string(),
            line: 43,
            name: "_git_log_1h".to_string(),
            kind: "fn".to_string(),
        }]);
        let enricher = Enricher::new(dir.path(), almanac, MockLlm(canned.to_string()));
        let outcome = enricher.enrich(&id, EnrichMode::Apply).await.unwrap();
        assert!(outcome.applied);

        // After: the stored gap is no longer thin — it names a file and has
        // concrete AC.
        let after = store.get(&id).unwrap().unwrap();
        let t = classify_thinness(&after);
        assert!(!t.is_thin(), "still thin after enrich: {}", t.tags());
        assert!(after.acceptance_criteria.contains("fleet-brief.sh"));

        // Silence unused-Arc lint parity with architect's test module.
        let _ = Arc::new(0u8);
    }

    struct MockOpenRouter(Result<Vec<crate::OpenRouterModel>, String>);

    #[async_trait::async_trait]
    impl OpenRouterClient for MockOpenRouter {
        async fn fetch_models(&self) -> Result<Vec<crate::OpenRouterModel>, String> {
            self.0.clone()
        }
    }

    fn sample_model(id: &str) -> crate::OpenRouterModel {
        crate::OpenRouterModel {
            id: id.to_string(),
            context_length: 128_000,
            pricing: serde_json::json!({"prompt": "0", "completion": "0"}),
            per_request_limits: serde_json::json!(null),
            expiration_date: String::new(),
            knowledge_cutoff: "2026-01".to_string(),
            architecture: serde_json::json!({"modality": "text"}),
            reasoning: serde_json::json!(false),
            supported_parameters: vec!["tools".to_string()],
        }
    }

    #[tokio::test]
    async fn fetch_and_store_success_upserts_and_logs() {
        use tempfile::TempDir;
        let dir = TempDir::new().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        let client = MockOpenRouter(Ok(vec![
            sample_model("nvidia/nemotron-3-ultra-550b:free"),
            sample_model("deepseek/deepseek-v4-pro"),
        ]));

        let count = fetch_and_store_openrouter_models(&store, &client)
            .await
            .unwrap();
        assert_eq!(count, 2);

        let row = store
            .get_openrouter_model_metadata("deepseek/deepseek-v4-pro")
            .unwrap()
            .expect("row persisted");
        assert_eq!(row.context_length, 128_000);
        assert_eq!(row.knowledge_cutoff, "2026-01");
        assert_eq!(row.supported_parameters, vec!["tools".to_string()]);

        // A second fetch of the same model id mutates the existing row
        // in place rather than duplicating it.
        let mut updated = sample_model("deepseek/deepseek-v4-pro");
        updated.context_length = 256_000;
        let client2 = MockOpenRouter(Ok(vec![updated]));
        let count2 = fetch_and_store_openrouter_models(&store, &client2)
            .await
            .unwrap();
        assert_eq!(count2, 1);
        let row2 = store
            .get_openrouter_model_metadata("deepseek/deepseek-v4-pro")
            .unwrap()
            .expect("row still present");
        assert_eq!(row2.context_length, 256_000);
    }

    #[tokio::test]
    async fn fetch_failure_is_reported_and_store_is_untouched() {
        use tempfile::TempDir;
        let dir = TempDir::new().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        let client = MockOpenRouter(Err("openrouter GET ... returned HTTP 401".to_string()));

        let err = fetch_and_store_openrouter_models(&store, &client)
            .await
            .unwrap_err();
        assert!(err.contains("401"));
        assert!(store
            .get_openrouter_model_metadata("anything")
            .unwrap()
            .is_none());
    }
}
