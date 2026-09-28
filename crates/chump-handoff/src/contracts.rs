//! The three concrete contracts called out by INFRA-1720 AC #3.
//!
//! These are *real* contract shapes — i.e. when (not if) we rewrite the
//! current markdown-prompt subagent spawn sites in `src/agent_factory.rs`
//! and the auto-decompose path, these are the types they'll use.
//!
//! Each contract:
//!
//! * Has `Input`/`Output` structs with `#[derive]` for serde.
//! * Implements [`crate::Validate`] on `Output` (semantic checks beyond schema).
//! * Implements [`crate::HandoffContract`] with a `prompt()` template that
//!   tells the subagent the exact JSON shape it must emit.
//! * Picks a `model_tier` appropriate to the work.

use crate::{HandoffContract, ModelTier, Validate, ValidationError};
use serde::{Deserialize, Serialize};

// ── (a) GapReviewContract ─────────────────────────────────────────────────

/// Input to a "review this gap" subagent: the gap ID + optional context.
#[derive(Debug, Clone, Serialize)]
pub struct GapReviewInput {
    /// Gap identifier (e.g. `INFRA-1720`).
    pub gap_id: String,
    /// Free-form context the parent already has (gap description, related PRs).
    pub context: String,
}

/// Output from gap-review: a verdict + reasoning + any blocking concerns.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct GapReviewOutput {
    /// Verdict tag — one of `approve` | `revise` | `block`.
    pub verdict: String,
    /// Free-form reasoning supporting the verdict.
    pub reasoning: String,
    /// Specific concerns the parent must address before proceeding (may be empty).
    pub blocking_concerns: Vec<String>,
}

impl Validate for GapReviewOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        // Verdict is the only field the parent routes on — narrow it to the
        // three allowed tags. Reasoning + concerns are free-form by design.
        match self.verdict.as_str() {
            "approve" | "revise" | "block" => {}
            other => {
                return Err(ValidationError::new(format!(
                    "verdict must be approve|revise|block, got {other:?}"
                )))
            }
        }
        if self.reasoning.trim().is_empty() {
            return Err(ValidationError::new("reasoning cannot be empty"));
        }
        Ok(())
    }
}

/// Subagent reviews a gap's spec and returns a verdict.
///
/// Use case: opus-curator (META-046) wants a second-opinion review before
/// promoting a gap to P0; spawn a Sonnet under this contract so the verdict +
/// reasoning come back typed instead of as text the curator has to re-parse.
pub struct GapReviewContract;

impl HandoffContract for GapReviewContract {
    type Input = GapReviewInput;
    type Output = GapReviewOutput;

    fn name() -> &'static str {
        "GapReviewContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are reviewing gap {gap_id} for the Chump fleet.

Context the parent has already gathered:
{context}

Decide one of:
  - "approve"  — the gap is ready to pick up as-is
  - "revise"   — the gap needs AC / scope / priority tweaks first (list them)
  - "block"    — the gap should not be picked up at all (explain why)

Emit a single fenced JSON block of this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "verdict": "approve" | "revise" | "block",
  "reasoning": "<2-4 sentence justification>",
  "blocking_concerns": ["<concern 1>", "<concern 2>", ...]
}}
```

Use an empty `blocking_concerns` array for `approve`. Be specific in `reasoning` — what about this gap drove the verdict?
"#,
            gap_id = input.gap_id,
            context = input.context
        )
    }

    fn model_tier() -> ModelTier {
        // Review = judgement work; Sonnet is the right default. Opus reserved
        // for cases Sonnet routinely waffles on (e.g. cross-pillar trade-off).
        ModelTier::Sonnet
    }
}

// ── (b) CodeFixContract ───────────────────────────────────────────────────

/// Input: where the symptom is and what it looks like.
#[derive(Debug, Clone, Serialize)]
pub struct CodeFixInput {
    /// Repository-relative path to the file the parent suspects.
    pub file_path: String,
    /// Description of the symptom (test failure text, panic, lint output).
    pub symptom: String,
}

/// Output: the unified diff the parent should apply + the test it added/changed.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CodeFixOutput {
    /// Unified diff in `diff --git a/X b/X` form, ready to feed `git apply`.
    pub unified_diff: String,
    /// Files the diff actually touches (parent uses this to gate lease overlap).
    pub files_touched: Vec<String>,
    /// Repository-relative path to the test file the subagent added/changed.
    pub tests_added: Vec<String>,
}

impl Validate for CodeFixOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        let head = self.unified_diff.trim_start();
        if !head.starts_with("diff --git") && !head.starts_with("---") {
            return Err(ValidationError::new(
                "unified_diff must start with `diff --git` or `---` header",
            ));
        }
        if self.files_touched.is_empty() {
            return Err(ValidationError::new("files_touched cannot be empty"));
        }
        // Tests-added may be empty (some fixes don't need a new test — e.g. a
        // typo in a string literal). Parent applies its own policy on top.
        Ok(())
    }
}

/// Subagent diagnoses a symptom + emits a unified diff.
///
/// Use case: pr-rescue v2 (INFRA-1714 follow-up) when classifier hits an
/// `Unknown` pattern — spawn a Sonnet under this contract for a one-shot
/// fix attempt. Output is a diff the parent can apply via `git apply` after
/// running the listed files through the lease-overlap check.
pub struct CodeFixContract;

impl HandoffContract for CodeFixContract {
    type Input = CodeFixInput;
    type Output = CodeFixOutput;

    fn name() -> &'static str {
        "CodeFixContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are fixing a code symptom in the Chump repo.

File suspected: {file_path}
Symptom:
{symptom}

Investigate the file (read it, look at related modules), then emit a single fenced JSON block with this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "unified_diff": "diff --git a/path b/path\n--- a/path\n+++ b/path\n@@ ... @@\n...",
  "files_touched": ["path/relative/to/repo/root", ...],
  "tests_added": ["path/to/test/file", ...]
}}
```

Rules:
- `unified_diff` MUST start with `diff --git` (or `---` for a pure file-add) and be appliable via `git apply`.
- `files_touched` MUST list every file the diff modifies — the parent uses this to check for lease collisions before applying.
- `tests_added` MAY be empty if the fix is too small to need a new test, but prefer adding one.
"#,
            file_path = input.file_path,
            symptom = input.symptom
        )
    }

    fn model_tier() -> ModelTier {
        ModelTier::Sonnet
    }
}

// ── (c) DecomposeContract ─────────────────────────────────────────────────

/// Input: gap ID + the AST-derived map of relevant files (from INFRA-1719).
///
/// `ast_map` is a JSON blob the parent assembles; the subagent is *not*
/// expected to re-traverse the codebase, only to reason over the supplied map.
#[derive(Debug, Clone, Serialize)]
pub struct DecomposeInput {
    /// Gap identifier (e.g. `INFRA-1720`).
    pub gap_id: String,
    /// JSON serialised AST map (output of INFRA-1719's crawler).
    pub ast_map_json: String,
}

/// A single sub-gap proposed by the decomposer.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SubGap {
    /// One-paragraph description suitable for a gap description field.
    pub description: String,
    /// Repo-relative paths the sub-gap is expected to touch (lease scope).
    pub files_to_modify: Vec<String>,
    /// Branch name in `chump/<id>-claim` style (decomposer can suggest).
    pub branch_name: String,
    /// Command the parent should run to verify the sub-gap's AC.
    pub test_command: String,
    /// Other sub-gap branch names this one depends on (topological order).
    pub depends_on: Vec<String>,
}

/// Output: the proposed sub-gap list, plus optional context for the parent.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DecomposeOutput {
    /// Proposed sub-gaps in topological order.
    pub sub_gaps: Vec<SubGap>,
    /// Decomposer's reasoning (why this split).
    pub reasoning: String,
}

impl Validate for DecomposeOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.sub_gaps.is_empty() {
            return Err(ValidationError::new("sub_gaps cannot be empty"));
        }
        for (i, sg) in self.sub_gaps.iter().enumerate() {
            if sg.description.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].description cannot be empty"
                )));
            }
            if sg.files_to_modify.is_empty() {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].files_to_modify cannot be empty"
                )));
            }
            if !sg.branch_name.starts_with("chump/") {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].branch_name must start with `chump/`"
                )));
            }
            if sg.test_command.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].test_command cannot be empty"
                )));
            }
        }
        Ok(())
    }
}

/// Subagent decomposes a gap into sub-gaps using an AST map as context.
///
/// Use case: `chump gap decompose <ID>` (current markdown-prompt path) is the
/// archetype for this contract — typed output means the CLI can write the
/// sub-gaps directly to state.db instead of regex-parsing free-form text.
pub struct DecomposeContract;

impl HandoffContract for DecomposeContract {
    type Input = DecomposeInput;
    type Output = DecomposeOutput;

    fn name() -> &'static str {
        "DecomposeContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are decomposing gap {gap_id} into sub-gaps.

AST map (JSON; do not re-traverse the codebase, work from this):
```json
{ast}
```

Propose sub-gaps in topological order (depends_on must reference earlier branch_names). Emit a single fenced JSON block with this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "sub_gaps": [
    {{
      "description": "...",
      "files_to_modify": ["src/foo.rs", ...],
      "branch_name": "chump/<short-id>-claim",
      "test_command": "cargo test --bin chump my_test_name",
      "depends_on": []
    }},
    ...
  ],
  "reasoning": "Why this particular split"
}}
```

Rules:
- `sub_gaps` MUST be non-empty.
- Every `files_to_modify` entry must be reachable from the AST map (don't invent paths).
- `branch_name` MUST start with `chump/`.
- `test_command` MUST be the exact command the parent will run to verify AC.
- `depends_on` must reference earlier `branch_name` values (no forward refs, no cycles).
"#,
            gap_id = input.gap_id,
            ast = input.ast_map_json
        )
    }

    fn model_tier() -> ModelTier {
        // Decomposition is the original "Opus decides, Sonnet executes" job.
        // Pin to Opus by default; callers can override if budget tight.
        ModelTier::Opus
    }
}

// ── (d) ExternalRepoContract ──────────────────────────────────────────────

/// Input: what repo to touch, where it is locally, and what change to make.
#[derive(Debug, Clone, Serialize)]
pub struct ExternalRepoInput {
    /// External repo in `owner/repo` form (e.g. `ehippy/derelict`).
    pub external_repo: String,
    /// Absolute path to a local clone of the external repo.
    pub repo_local_path: String,
    /// Description of the change to ship (gap description style).
    pub proposed_gap_description: String,
    /// Base branch to open the PR against (e.g. `main`).
    pub base_branch: String,
    /// Fork owner for fork-PR mode (e.g. `repairman29`). `None` means
    /// direct-push to a branch on the upstream (only valid if the subagent
    /// has push rights).
    pub fork_owner: Option<String>,
}

/// Output: evidence the change was shipped — PR URL + supporting metadata.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ExternalRepoOutput {
    /// Full GitHub PR URL, e.g. `https://github.com/ehippy/derelict/pull/42`.
    pub pr_url: String,
    /// Head branch name the PR was opened from.
    pub head_ref: String,
    /// Base branch the PR targets.
    pub base_ref: String,
    /// Repo-relative paths the change touches (used for lease-overlap audit).
    pub files_touched: Vec<String>,
    /// Full commit SHA of the head commit.
    pub commit_sha: String,
    /// Free-form notes on what was done (for operator review).
    pub notes: String,
}

/// Returns `true` if `url` matches `https://github.com/<owner>/<repo>/pull/<N>`
/// where `<N>` is one or more digits. No external crate needed.
fn is_valid_github_pr_url(url: &str) -> bool {
    // Must start with the canonical prefix.
    let Some(rest) = url.strip_prefix("https://github.com/") else {
        return false;
    };
    // Expect <owner>/<repo>/pull/<N>
    let parts: Vec<&str> = rest.splitn(4, '/').collect();
    if parts.len() != 4 {
        return false;
    }
    let (owner, repo, pull_literal, pr_number) = (parts[0], parts[1], parts[2], parts[3]);
    !owner.is_empty()
        && !repo.is_empty()
        && pull_literal == "pull"
        && !pr_number.is_empty()
        && pr_number.chars().all(|c| c.is_ascii_digit())
}

impl Validate for ExternalRepoOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.pr_url.trim().is_empty() {
            return Err(ValidationError::new("pr_url cannot be empty"));
        }
        // Require a well-formed GitHub PR URL: https://github.com/<owner>/<repo>/pull/<N>
        if !is_valid_github_pr_url(self.pr_url.trim()) {
            return Err(ValidationError::new(
                "pr_url must match https://github.com/<owner>/<repo>/pull/<N>",
            ));
        }
        if self.files_touched.is_empty() {
            return Err(ValidationError::new("files_touched cannot be empty"));
        }
        if self.commit_sha.trim().is_empty() {
            return Err(ValidationError::new("commit_sha cannot be empty"));
        }
        Ok(())
    }
}

/// Subagent ships a change into an external repo and opens a PR.
///
/// Use case: META-123 flow — Scout proposes, external-collab reviews, Target
/// picks, then this contract dispatches a Sonnet worker that clones (or uses an
/// existing clone at `repo_local_path`), branches, makes the change described
/// in `proposed_gap_description`, commits, pushes, and opens the PR. The typed
/// output gives the parent a PR URL it can track without regex-parsing free text.
pub struct ExternalRepoContract;

impl HandoffContract for ExternalRepoContract {
    type Input = ExternalRepoInput;
    type Output = ExternalRepoOutput;

    fn name() -> &'static str {
        "ExternalRepoContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are making a code change in an external repository on behalf of the Chump
fleet. The fleet handles ALL git operations — you ONLY edit files in the working tree.

External repo   : {external_repo}
Working checkout: {repo_local_path}   (already on a fresh per-agent branch — do NOT create or switch branches)
Base branch     : {base_branch}       (the PR the fleet opens will target this)

Proposed change:
{proposed_gap_description}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MERGE BAR — your PR MUST satisfy ALL of the following or it
will NOT be merged (EFFECTIVE-215 / CREDIBLE-096).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Gate 1 — CI green
  The external repo's CI must be GREEN on your PR head commit.
  Every non-advisory check-run on the head SHA must be SUCCESS
  (or NEUTRAL/SKIPPED for intentional opt-outs).  A single
  failing check-run → HELD(ci).  Zero check-runs → HELD(no-gates).

Gate 2 — Anti-cosmetic: a test that FAILS on base and PASSES on head
  This is the decisive gate.  Your PR diff MUST add or modify at
  least one test file (heuristic: path contains `test`/`spec`, or
  filename matches `*_test.*`, `test_*.*`, `*.test.*`, `*.spec.*`,
  `__tests__/*`, etc.).  That test MUST:
    • FAIL (non-zero exit) when run against the BASE commit, AND
    • PASS (exit 0) when run against your HEAD commit.

  A test that also passes on the base commit proves nothing —
  HELD(unproven).  A PR with no changed test file at all →
  HELD(cosmetic).

  Therefore: identify a concrete, testable behavioral defect or
  missing behavior your change addresses, write a test that
  demonstrably FAILS before your change and PASSES after, and
  include it.  If the proposed change is pure config/docs with no
  testable behavior, reframe it as the underlying behavioral defect
  and prove THAT with a test — do NOT open an unprovable PR.

Gate 3 — No regression
  The repo's FULL existing test suite MUST pass on your head commit.
  If the repo's CI already runs the full test suite (Gate 1 covers
  this), Gate 3 is satisfied by CI.  If CI only lints or builds,
  run the full test suite locally on the head commit.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELF-VERIFY — run ALL three checks BEFORE opening the PR:
  1. Checkout the BASE commit; run your changed test → must FAIL.
  2. Checkout your HEAD commit; run your changed test → must PASS.
  3. Run the FULL test suite on HEAD → must be GREEN.
  Only open the PR if all three hold.  If any check is wrong,
  fix the implementation or the test before pushing.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Steps — EDIT ONLY, no git:
1. Work in {repo_local_path} on the current branch. Do NOT create or switch branches, and
   do NOT `git commit`, `git push`, or `gh pr create` — the fleet performs the commit,
   push, and PR deterministically after you finish (this is why your change ships reliably
   instead of depending on you to run git correctly).
2. Identify the behavioral defect or missing behavior, and write a test for it.
3. Confirm the test FAILS on the base commit.
4. Implement the change that makes the test pass. HOW TO EDIT: use `str_replace`
   (read the file first, copy the EXACT snippet to change into `old_string` with its
   indentation, put the corrected text in `new_string` — it must match exactly once).
   Do NOT rewrite an entire existing file with `write_file` — that truncates/clobbers
   large files and the ship guard will reject it. `write_file` is ONLY for creating a
   brand-new file.
5. Confirm the test PASSES and the full suite is GREEN with your change.
6. Leave EVERY change UNCOMMITTED in the working tree, then stop and briefly summarize:
   what you changed, which test proves it, and your self-verify result (failed on base,
   passed on head, full suite green).

If you cannot satisfy the MERGE BAR, make NO changes and say why — an empty working tree
is an honest outcome the fleet will report; a fabricated or unprovable change is not."#,
            external_repo = input.external_repo,
            repo_local_path = input.repo_local_path,
            base_branch = input.base_branch,
            proposed_gap_description = input.proposed_gap_description,
        )
    }

    fn model_tier() -> ModelTier {
        // Execution work — Sonnet is the standard tier for workers that ship code.
        ModelTier::Sonnet
    }
}

// ── (e) IntegrationCycleContract ─────────────────────────────────────────

/// Why the integration cycle was triggered.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "PascalCase")]
pub enum TriggerReason {
    /// Scheduled cadence (e.g. nightly, weekly).
    Cadence,
    /// Gap-count threshold crossed.
    Volume,
    /// LOC-budget threshold crossed.
    LocBudget,
    /// Operator explicitly triggered.
    OperatorManual,
}

/// Input: everything the integrator daemon knows when it kicks off a cycle.
#[derive(Debug, Clone, Serialize)]
pub struct IntegrationCycleInput {
    /// Cycle identifier — must match `^integration-\d{4}-\d{2}-\d{2}-\d{4}$`.
    pub cycle_id: String,
    /// Gap IDs the integrator wants to land in this cycle.
    pub candidate_gap_ids: Vec<String>,
    /// Git branch the cycle lands onto (non-empty).
    pub integration_branch: String,
    /// Repo-relative path to the preflight log produced before landing.
    pub preflight_log_path: String,
    /// Why this cycle was triggered.
    pub trigger_reason: TriggerReason,
}

/// Final disposition of the cycle.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "PascalCase")]
pub enum CycleStatus {
    /// All candidates landed successfully.
    Shipped,
    /// Bisect ran; some candidates quarantined.
    BisectQuarantined,
    /// Could not determine success or failure.
    Inconclusive,
    /// Cycle aborted (e.g. preflight fail, operator cancel).
    Aborted,
}

/// One entry in the shipped manifest.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManifestEntry {
    /// Gap ID that landed.
    pub gap_id: String,
    /// Full 40-char commit SHA on the integration branch.
    pub commit_sha: String,
}

/// Output from the integration cycle subagent.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct IntegrationCycleOutput {
    /// Disposition of the cycle.
    pub cycle_status: CycleStatus,
    /// Gaps that landed, with their commit SHAs.
    pub manifest: Vec<ManifestEntry>,
    /// Gap IDs quarantined by bisect (empty if no bisect ran).
    pub quarantined_gap_ids: Vec<String>,
    /// Bisect-derived failure signature, if any.
    pub root_cause_signature: Option<String>,
    /// Number of bisect runs executed (0 if bisect did not run).
    pub bisect_runs: u32,
}

impl Validate for IntegrationCycleOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        // cycle_status + manifest coherence
        if self.cycle_status == CycleStatus::Shipped && !self.quarantined_gap_ids.is_empty() {
            return Err(ValidationError::new(
                "cycle_status Shipped but quarantined_gap_ids is non-empty",
            ));
        }
        if self.cycle_status == CycleStatus::BisectQuarantined
            && self.quarantined_gap_ids.is_empty()
        {
            return Err(ValidationError::new(
                "cycle_status BisectQuarantined but quarantined_gap_ids is empty",
            ));
        }
        // All manifest entries must have non-empty gap_id and commit_sha.
        for (i, entry) in self.manifest.iter().enumerate() {
            if entry.commit_sha.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "manifest[{i}].commit_sha cannot be empty"
                )));
            }
            if entry.gap_id.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "manifest[{i}].gap_id cannot be empty"
                )));
            }
        }
        Ok(())
    }
}

impl IntegrationCycleOutput {
    /// Cross-field validation against the input — checks the conservation law.
    ///
    /// `manifest.len() + quarantined_gap_ids.len() == candidate_gap_ids.len()`
    /// Also validates `cycle_id` regex and `integration_branch` non-empty.
    pub fn validate_against_input(
        &self,
        input: &IntegrationCycleInput,
    ) -> Result<(), ValidationError> {
        // Output-internal checks first.
        self.validate()?;

        // cycle_id regex: ^integration-\d{4}-\d{2}-\d{2}-\d{4}$
        let id = &input.cycle_id;
        if !is_valid_cycle_id(id) {
            return Err(ValidationError::new(format!(
                "cycle_id {id:?} does not match \
                 ^integration-\\d{{4}}-\\d{{2}}-\\d{{2}}-\\d{{4}}$"
            )));
        }

        if input.integration_branch.trim().is_empty() {
            return Err(ValidationError::new("integration_branch cannot be empty"));
        }

        let shipped = self.manifest.len();
        let quarantined = self.quarantined_gap_ids.len();
        let total = shipped + quarantined;
        let expected = input.candidate_gap_ids.len();
        if total != expected {
            return Err(ValidationError::new(format!(
                "manifest ({shipped}) + quarantined ({quarantined}) = {total}, \
                 expected {expected} (candidate_gap_ids.len())"
            )));
        }
        Ok(())
    }
}

/// Returns `true` if `id` matches `^integration-\d{4}-\d{2}-\d{2}-\d{4}$`.
fn is_valid_cycle_id(id: &str) -> bool {
    // "integration-" prefix = 12 chars; remainder = "YYYY-MM-DD-HHMM" = 15 chars
    let Some(rest) = id.strip_prefix("integration-") else {
        return false;
    };
    if rest.len() != 15 {
        return false;
    }
    let b = rest.as_bytes();
    // b: 0123-56-89-1234  (dashes at indices 4, 7, 10)
    b[0..4].iter().all(|c| c.is_ascii_digit())
        && b[4] == b'-'
        && b[5..7].iter().all(|c| c.is_ascii_digit())
        && b[7] == b'-'
        && b[8..10].iter().all(|c| c.is_ascii_digit())
        && b[10] == b'-'
        && b[11..15].iter().all(|c| c.is_ascii_digit())
}

/// Subagent runs an integration cycle — preflight, land candidates, bisect on
/// failure — and returns typed evidence of what landed and what was quarantined.
///
/// Use case: META-124 C2 (the Mode A integrator daemon, INFRA-2130) dispatches
/// this contract to coordinate a batched land. The typed output lets the daemon
/// update `state.db` without regex-parsing free text.
pub struct IntegrationCycleContract;

impl HandoffContract for IntegrationCycleContract {
    type Input = IntegrationCycleInput;
    type Output = IntegrationCycleOutput;

    fn name() -> &'static str {
        "IntegrationCycleContract"
    }

    fn prompt(input: &Self::Input) -> String {
        let candidates_json =
            serde_json::to_string_pretty(&input.candidate_gap_ids).unwrap_or_default();
        let trigger = serde_json::to_string(&input.trigger_reason).unwrap_or_default();
        format!(
            r#"You are the Chump integration-cycle executor for cycle {cycle_id}.

Integration branch : {integration_branch}
Trigger reason     : {trigger_reason}
Preflight log      : {preflight_log_path}

Candidate gap IDs (land all of these, or bisect-quarantine those that break CI):
```json
{candidates_json}
```

Steps:
1. Verify the integration branch exists and is clean.
2. Cherry-pick / merge each candidate in order, running CI after each batch.
3. If CI breaks, bisect to find the culprit gap(s) and quarantine them.
4. Record the final commit SHA for each gap that landed.
5. Emit a single fenced JSON block with this exact shape (no other JSON, no extra
   commentary outside the block):

```json
{{
  "cycle_status": "Shipped" | "BisectQuarantined" | "Inconclusive" | "Aborted",
  "manifest": [
    {{ "gap_id": "<gap-id>", "commit_sha": "<40-char SHA>" }},
    ...
  ],
  "quarantined_gap_ids": ["<gap-id>", ...],
  "root_cause_signature": "<short failure description>" | null,
  "bisect_runs": <integer>
}}
```

Conservation law (HARD CONSTRAINT):
  manifest.len() + quarantined_gap_ids.len() MUST equal {candidate_count}
  (the total number of candidates). Every candidate must appear in exactly one
  of the two lists — no silent drops.

Rules:
- `cycle_status` MUST be one of: Shipped, BisectQuarantined, Inconclusive, Aborted.
- Each `manifest` entry needs a real 40-char commit SHA (`git rev-parse HEAD`).
- `quarantined_gap_ids` is empty when `cycle_status` is `Shipped`.
- `root_cause_signature` is null unless bisect identified a specific root cause.
- `bisect_runs` is 0 if no bisect was needed.
"#,
            cycle_id = input.cycle_id,
            integration_branch = input.integration_branch,
            trigger_reason = trigger,
            preflight_log_path = input.preflight_log_path,
            candidates_json = candidates_json,
            candidate_count = input.candidate_gap_ids.len(),
        )
    }

    fn model_tier() -> ModelTier {
        // Integration execution is Sonnet-class work: sequential steps,
        // well-specified output shape, no ambiguous pillar trade-offs.
        ModelTier::Sonnet
    }
}

// ── (f) RoadmapFromVisionContract ────────────────────────────────────────────
//
// INFRA-2267 Phase 1: typed contract ONLY.
// Phase 2 (CLI wiring, LLM pipeline, ambient event registration) is gated on
// operator/consensus review of this contract shape.

/// How to group the emitted gaps in the roadmap.
///
/// The grouping strategy the LLM should use when clustering proposed gaps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupBy {
    /// Group by product line / theme (default — good for vision docs).
    ProductLine,
    /// Group by Chump pillar (Credible / Effective / Resilient / Zero-Waste).
    Pillar,
    /// Group by effort band (xs/s together, m alone, l/xl together).
    Effort,
}

/// Priority tier for a proposed gap (mirrors `chump gap reserve` vocabulary).
///
/// Defined locally to keep `chump-handoff` free of cross-crate coupling to
/// `chump-planner`. Values must serialize to the same lowercase strings that
/// `state.db` expects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RoadmapPriority {
    /// Blocker / critical path.
    P0,
    /// High — should be picked next.
    P1,
    /// Medium — normal queue.
    P2,
    /// Low — nice to have.
    P3,
}

/// Effort sizing for a proposed gap (mirrors `chump gap reserve` vocabulary).
///
/// Defined locally — same rationale as [`RoadmapPriority`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RoadmapEffort {
    /// Extra-small — 1-2 hour task.
    Xs,
    /// Small — half-day task.
    S,
    /// Medium — 1-2 day task.
    M,
    /// Large — multi-day task.
    L,
    /// Extra-large — week-plus; consider splitting.
    Xl,
}

/// A single gap proposed by the roadmap generator.
///
/// Shape mirrors a `chump gap reserve` call so consumers can batch-insert
/// these into `state.db` without translation (Phase 2 work).
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct GapDraft {
    /// Short, imperative title (< 100 chars). No TODO placeholders.
    pub title: String,
    /// One-paragraph description suitable for the gap's `description` field.
    pub description: String,
    /// Suggested priority tier.
    pub priority: RoadmapPriority,
    /// Suggested effort size.
    pub effort: RoadmapEffort,
    /// Concrete acceptance criteria — the LLM must emit at least one non-empty,
    /// non-TODO criterion. Mirrors the AC rules in `CLAUDE.md`.
    pub acceptance_criteria: Vec<String>,
    /// Ordered list of prerequisite titles (intra-roadmap) or filed gap IDs
    /// matching `<DOMAIN>-<NUM>` (e.g. `INFRA-1720`). Empty means no deps.
    pub depends_on: Vec<String>,
}

/// A named cluster of related [`GapDraft`]s.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RoadmapGroup {
    /// Short theme label (e.g. "Authentication", "Credible" pillar, "Small wins").
    pub name: String,
    /// 1-2 sentence rationale for why these gaps belong together.
    pub rationale: String,
    /// Gaps in this group, ordered by suggested pick order within the group.
    pub gaps: Vec<GapDraft>,
}

/// Full roadmap emitted by the LLM.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Roadmap {
    /// Ordered groups — consumers display/file them in this order.
    pub groups: Vec<RoadmapGroup>,
    /// 2-4 sentence narrative summarising the overall roadmap arc.
    pub narrative: String,
    /// LLM self-assessed confidence in the plan [0.0, 1.0]. Lower means the
    /// intent doc was ambiguous and operator review is especially important.
    pub confidence: f64,
}

/// Regex pattern for a filed gap ID — `<DOMAIN>-<NUM>` where DOMAIN is
/// uppercase letters and NUM is one or more digits. Used in `Validate`.
fn is_filed_gap_id(s: &str) -> bool {
    let mut parts = s.splitn(2, '-');
    let domain = parts.next().unwrap_or("");
    let num = parts.next().unwrap_or("");
    !domain.is_empty()
        && domain.chars().all(|c| c.is_ascii_uppercase())
        && !num.is_empty()
        && num.chars().all(|c| c.is_ascii_digit())
}

impl Validate for Roadmap {
    fn validate(&self) -> Result<(), ValidationError> {
        // 1. Must have at least one group.
        if self.groups.is_empty() {
            return Err(ValidationError::new(
                "roadmap must contain at least one group",
            ));
        }

        // 2. Confidence must be in [0.0, 1.0].
        if !(0.0..=1.0).contains(&self.confidence) {
            return Err(ValidationError::new(format!(
                "confidence {:.3} is outside [0.0, 1.0]",
                self.confidence
            )));
        }

        // 3. Collect all intra-roadmap titles for depends_on resolution.
        let all_titles: std::collections::HashSet<&str> = self
            .groups
            .iter()
            .flat_map(|g| g.gaps.iter().map(|d| d.title.as_str()))
            .collect();

        // 4. Per-group, per-gap validation.
        for (gi, group) in self.groups.iter().enumerate() {
            for (di, draft) in group.gaps.iter().enumerate() {
                let loc = format!("groups[{gi}].gaps[{di}]");

                if draft.title.trim().is_empty() {
                    return Err(ValidationError::new(format!("{loc}.title cannot be empty")));
                }

                if draft.acceptance_criteria.is_empty() {
                    return Err(ValidationError::new(format!(
                        "{loc}.acceptance_criteria cannot be empty"
                    )));
                }
                for (ai, ac) in draft.acceptance_criteria.iter().enumerate() {
                    let ac_lower = ac.to_lowercase();
                    if ac.trim().is_empty()
                        || ac_lower.contains("todo")
                        || ac_lower.contains("tbd")
                        || ac_lower.contains("<fill in>")
                    {
                        return Err(ValidationError::new(format!(
                            "{loc}.acceptance_criteria[{ai}] is empty or placeholder"
                        )));
                    }
                }

                // 5. depends_on: each entry must be an intra-roadmap title OR a filed gap ID.
                for dep in &draft.depends_on {
                    if !all_titles.contains(dep.as_str()) && !is_filed_gap_id(dep) {
                        return Err(ValidationError::new(format!(
                            "{loc}.depends_on entry {dep:?} is neither an intra-roadmap title \
                             nor a filed gap ID (<DOMAIN>-<NUM>)"
                        )));
                    }
                }
            }
        }

        Ok(())
    }
}

/// Input to the roadmap-from-vision subagent.
#[derive(Debug, Clone, Serialize)]
pub struct RoadmapFromVisionInput {
    /// Full text of the intent / vision document. The LLM reads this to extract
    /// themes and propose gaps. Do NOT pre-summarise — send the raw doc so the
    /// LLM can apply its own judgement about what matters.
    pub intent_doc: String,
    /// Domain prefix for the proposed gaps (e.g. `INFRA`, `PRODUCT`, `META`).
    pub domain: String,
    /// Upper bound on total gap count across all groups. The LLM must not emit
    /// more than this many [`GapDraft`]s in total.
    pub max_gaps: u32,
    /// Grouping strategy the LLM should use when clustering gaps.
    pub group_by: GroupBy,
    /// Optional additional context lines (e.g. "existing P0s to avoid
    /// duplicating", "roadmap horizon is 60 days"). Joined with newlines.
    pub context: Vec<String>,
    /// If set, a human-readable target directory hint the LLM can surface in
    /// gap descriptions (e.g. `crates/chump-foo/`). Not a filesystem path the
    /// LLM traverses — purely informational.
    pub target_dir: Option<std::path::PathBuf>,
}

/// Subagent reads a vision/intent document and emits a structured product roadmap
/// as N grouped [`GapDraft`]s that consumers can batch-insert into `state.db`.
///
/// Use case: `chump roadmap-from-vision <intent-doc>` (CLI wired in Phase 2,
/// INFRA-2267). Also called by `chump bootstrap --with-roadmap` (INFRA-2265)
/// after architecture-decision to generate the initial gap backlog. This is the
/// substrate primitive — consumer surfaces own the founder-facing UX.
///
/// **Phase 1 scope:** contract types + Validate + prompt() ONLY.
/// Phase 2 (CLI handler, LLM pipeline, ambient event registration) is gated on
/// operator/consensus review via PR consensus vote.
pub struct RoadmapFromVisionContract;

impl HandoffContract for RoadmapFromVisionContract {
    type Input = RoadmapFromVisionInput;
    type Output = Roadmap;

    fn name() -> &'static str {
        "RoadmapFromVisionContract"
    }

    fn prompt(input: &Self::Input) -> String {
        let group_by_str = match input.group_by {
            GroupBy::ProductLine => "product line / theme",
            GroupBy::Pillar => "Chump pillar (Credible / Effective / Resilient / Zero-Waste)",
            GroupBy::Effort => "effort band (xs+s / m / l+xl)",
        };
        let context_str = if input.context.is_empty() {
            "(none)".to_string()
        } else {
            input.context.join("\n")
        };
        let target_dir_str = match &input.target_dir {
            Some(p) => format!("`{}`", p.display()),
            None => "(not specified)".to_string(),
        };
        format!(
            r#"You are the Chump roadmap generator. Read the intent document below and
propose a structured product roadmap as typed JSON.

Domain            : {domain}
Max gaps (hard cap): {max_gaps}  — you must not emit more gaps in total
Group by          : {group_by}
Target directory  : {target_dir}
Additional context:
{context}

════════════════════════ INTENT DOCUMENT ════════════════════════
{intent_doc}
═════════════════════════════════════════════════════════════════

Instructions:
1. Read the intent document carefully. Identify the key product themes / pillars
   / effort bands (depending on "Group by" above).
2. Propose up to {max_gaps} gaps total, clustered into groups. Fewer is fine if
   the document doesn't justify more.
3. For each gap:
   - Write a concrete, imperative `title` (< 100 chars, no TODO placeholders).
   - Write a one-paragraph `description` that a Chump worker can act on cold.
   - Choose `priority` (P0 | P1 | P2 | P3). Reserve P0 for genuine unblockers.
   - Choose `effort` (xs | s | m | l | xl).
   - Write at least one concrete, non-placeholder `acceptance_criteria` entry.
     Each criterion must be a full sentence describing a verifiable outcome.
     Do NOT write "TODO", "TBD", or "<fill in>" — these will be rejected.
   - List `depends_on` as intra-roadmap titles OR filed gap IDs (<DOMAIN>-<NUM>).
     Use an empty list if there are no prerequisites.
4. Write a 2-4 sentence `narrative` summarising the overall roadmap arc.
5. Set `confidence` in [0.0, 1.0]: 1.0 means the intent doc was unambiguous;
   0.0 means you are guessing — prefer low confidence + a good narrative over
   hallucinating a confident plan.

Emit a SINGLE fenced JSON block (no other JSON, no commentary outside the block):

```json
{{
  "groups": [
    {{
      "name": "<theme / pillar / effort band>",
      "rationale": "<why these gaps belong together>",
      "gaps": [
        {{
          "title": "<imperative, < 100 chars>",
          "description": "<one paragraph>",
          "priority": "P0" | "P1" | "P2" | "P3",
          "effort": "xs" | "s" | "m" | "l" | "xl",
          "acceptance_criteria": ["<concrete AC>", ...],
          "depends_on": ["<intra-roadmap title or DOMAIN-NUM>", ...]
        }},
        ...
      ]
    }},
    ...
  ],
  "narrative": "<2-4 sentences>",
  "confidence": 0.0
}}
```

Hard constraints (enforced by Validate — violations will be rejected):
- `groups` must be non-empty.
- Every `title` must be non-empty.
- Every `acceptance_criteria` must be non-empty and contain no TODO/TBD placeholders.
- Total gaps across all groups must not exceed {max_gaps}.
- Each `depends_on` entry must be an intra-roadmap title that appears in this
  output, OR a filed gap ID matching `<UPPERCASE_LETTERS>-<DIGITS>`.
- `confidence` must be in [0.0, 1.0].
"#,
            domain = input.domain,
            max_gaps = input.max_gaps,
            group_by = group_by_str,
            target_dir = target_dir_str,
            context = context_str,
            intent_doc = input.intent_doc,
        )
    }

    fn model_tier() -> ModelTier {
        // Vision-to-structured-plan is the highest cognitive-load task in the
        // handoff taxonomy: the LLM must synthesise an ambiguous narrative into
        // a prioritised, AC-complete gap list. Sonnet has been shown to
        // hallucinate ACs and underweight depends_on on even moderately complex
        // intent docs. Opus is the correct tier; consumers can override via a
        // wrapper if budget is a concern.
        ModelTier::Opus
    }
}

#[cfg(test)]
mod tests_roadmap_from_vision {
    use super::*;
    use std::path::PathBuf;

    // ── helpers ───────────────────────────────────────────────────────────────

    fn good_draft() -> GapDraft {
        GapDraft {
            title: "Add retry logic to fetch pipeline".into(),
            description: "Implement exponential backoff in the fetch layer.".into(),
            priority: RoadmapPriority::P1,
            effort: RoadmapEffort::S,
            acceptance_criteria: vec![
                "cargo test -p chump-fetch fetch_retry passes with zero network calls on first attempt mocked".into(),
            ],
            depends_on: vec![],
        }
    }

    fn good_roadmap() -> Roadmap {
        Roadmap {
            groups: vec![RoadmapGroup {
                name: "Resilience".into(),
                rationale: "These gaps harden the fetch pipeline against transient failures."
                    .into(),
                gaps: vec![good_draft()],
            }],
            narrative: "This roadmap focuses on making the fetch pipeline resilient. \
                        The single P1 gap is small and can be picked immediately."
                .into(),
            confidence: 0.9,
        }
    }

    // ── Validate: accept ──────────────────────────────────────────────────────

    #[test]
    fn accepts_well_formed_roadmap() {
        assert!(good_roadmap().validate().is_ok());
    }

    #[test]
    fn accepts_intra_roadmap_depends_on() {
        let mut r = good_roadmap();
        let dep_title = "Bootstrap auth module".to_string();
        // Add the dep gap as a peer so the title resolves.
        r.groups[0].gaps.push(GapDraft {
            title: dep_title.clone(),
            description: "Scaffold auth".into(),
            priority: RoadmapPriority::P1,
            effort: RoadmapEffort::Xs,
            acceptance_criteria: vec!["Auth module compiles".into()],
            depends_on: vec![],
        });
        r.groups[0].gaps[0].depends_on = vec![dep_title];
        assert!(r.validate().is_ok());
    }

    #[test]
    fn accepts_filed_gap_id_depends_on() {
        let mut r = good_roadmap();
        r.groups[0].gaps[0].depends_on = vec!["INFRA-1720".into()];
        assert!(r.validate().is_ok());
    }

    #[test]
    fn accepts_zero_confidence() {
        let mut r = good_roadmap();
        r.confidence = 0.0;
        assert!(r.validate().is_ok());
    }

    #[test]
    fn accepts_full_confidence() {
        let mut r = good_roadmap();
        r.confidence = 1.0;
        assert!(r.validate().is_ok());
    }

    // ── Validate: reject — empty groups ──────────────────────────────────────

    #[test]
    fn rejects_empty_groups() {
        let r = Roadmap {
            groups: vec![],
            narrative: "nothing here".into(),
            confidence: 0.5,
        };
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("at least one group"));
    }

    // ── Validate: reject — missing AC ─────────────────────────────────────────

    #[test]
    fn rejects_empty_acceptance_criteria() {
        let mut r = good_roadmap();
        r.groups[0].gaps[0].acceptance_criteria = vec![];
        let err = r.validate().unwrap_err();
        assert!(err
            .message()
            .contains("acceptance_criteria cannot be empty"));
    }

    #[test]
    fn rejects_todo_acceptance_criteria() {
        let mut r = good_roadmap();
        r.groups[0].gaps[0].acceptance_criteria = vec!["TODO: fill this in".into()];
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("empty or placeholder"));
    }

    #[test]
    fn rejects_tbd_acceptance_criteria() {
        let mut r = good_roadmap();
        r.groups[0].gaps[0].acceptance_criteria = vec!["TBD".into()];
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("empty or placeholder"));
    }

    // ── Validate: reject — empty gap title ────────────────────────────────────

    #[test]
    fn rejects_empty_gap_title() {
        let mut r = good_roadmap();
        r.groups[0].gaps[0].title = "   ".into();
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("title cannot be empty"));
    }

    // ── Validate: reject — bad depends_on ─────────────────────────────────────

    #[test]
    fn rejects_unresolvable_depends_on() {
        let mut r = good_roadmap();
        // "some-random-thing" is neither an intra-roadmap title nor a gap ID.
        r.groups[0].gaps[0].depends_on = vec!["some-random-thing".into()];
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("depends_on entry"));
        assert!(err.message().contains("some-random-thing"));
    }

    #[test]
    fn rejects_lowercase_domain_in_gap_id() {
        let mut r = good_roadmap();
        // "infra-1720" has lowercase domain — should be rejected.
        r.groups[0].gaps[0].depends_on = vec!["infra-1720".into()];
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("depends_on entry"));
    }

    #[test]
    fn rejects_gap_id_with_no_number() {
        let mut r = good_roadmap();
        r.groups[0].gaps[0].depends_on = vec!["INFRA-".into()];
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("depends_on entry"));
    }

    // ── Validate: reject — confidence out of range ────────────────────────────

    #[test]
    fn rejects_confidence_above_one() {
        let mut r = good_roadmap();
        r.confidence = 1.001;
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("outside [0.0, 1.0]"));
    }

    #[test]
    fn rejects_confidence_below_zero() {
        let mut r = good_roadmap();
        r.confidence = -0.1;
        let err = r.validate().unwrap_err();
        assert!(err.message().contains("outside [0.0, 1.0]"));
    }

    // ── serde roundtrip ───────────────────────────────────────────────────────

    #[test]
    fn serde_roundtrip() {
        let original = good_roadmap();
        let json = serde_json::to_string(&original).expect("serialize");
        let decoded: Roadmap = serde_json::from_str(&json).expect("deserialize");
        // Re-validate after roundtrip.
        assert!(decoded.validate().is_ok());
        // Key field spot-check.
        assert_eq!(decoded.groups[0].name, original.groups[0].name);
        assert_eq!(
            decoded.groups[0].gaps[0].title,
            original.groups[0].gaps[0].title
        );
    }

    // ── prompt(): all 6 interpolation points present ──────────────────────────

    #[test]
    fn prompt_contains_all_interpolation_points() {
        let input = RoadmapFromVisionInput {
            intent_doc: "UNIQUE_INTENT_DOC_MARKER".into(),
            domain: "INFRA".into(),
            max_gaps: 12,
            group_by: GroupBy::ProductLine,
            context: vec!["UNIQUE_CONTEXT_LINE".into()],
            target_dir: Some(PathBuf::from("crates/chump-foo/")),
        };
        let p = RoadmapFromVisionContract::prompt(&input);

        assert!(
            p.contains("UNIQUE_INTENT_DOC_MARKER"),
            "missing {{intent_doc}}"
        );
        assert!(p.contains("INFRA"), "missing {{domain}}");
        assert!(p.contains("12"), "missing {{max_gaps}}");
        assert!(p.contains("product line"), "missing {{group_by}} rendering");
        assert!(p.contains("UNIQUE_CONTEXT_LINE"), "missing {{context}}");
        assert!(p.contains("chump-foo"), "missing {{target_dir}}");
    }

    #[test]
    fn prompt_renders_without_optional_target_dir() {
        let input = RoadmapFromVisionInput {
            intent_doc: "some vision".into(),
            domain: "PRODUCT".into(),
            max_gaps: 5,
            group_by: GroupBy::Pillar,
            context: vec![],
            target_dir: None,
        };
        // Must not panic and must still include key fields.
        let p = RoadmapFromVisionContract::prompt(&input);
        assert!(p.contains("PRODUCT"));
        // GroupBy::Pillar renders as "Chump pillar (Credible / Effective / ...)"
        assert!(p.contains("pillar"));
        assert!(p.contains("(not specified)"));
    }

    // ── model tier ────────────────────────────────────────────────────────────

    #[test]
    fn model_tier_is_opus() {
        assert_eq!(RoadmapFromVisionContract::model_tier(), ModelTier::Opus);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // GapReviewOutput validation ───────────────────────────────────────────

    #[test]
    fn gap_review_accepts_valid_verdict() {
        let v = GapReviewOutput {
            verdict: "approve".into(),
            reasoning: "scope is tight, AC concrete".into(),
            blocking_concerns: vec![],
        };
        assert!(v.validate().is_ok());
    }

    #[test]
    fn gap_review_rejects_unknown_verdict() {
        let v = GapReviewOutput {
            verdict: "maybe".into(),
            reasoning: "x".into(),
            blocking_concerns: vec![],
        };
        let err = v.validate().unwrap_err();
        assert!(err.message().contains("approve|revise|block"));
    }

    #[test]
    fn gap_review_rejects_empty_reasoning() {
        let v = GapReviewOutput {
            verdict: "approve".into(),
            reasoning: "   ".into(),
            blocking_concerns: vec![],
        };
        assert!(v.validate().is_err());
    }

    // CodeFixOutput validation ──────────────────────────────────────────────

    #[test]
    fn code_fix_accepts_proper_diff() {
        let v = CodeFixOutput {
            unified_diff: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n".into(),
            files_touched: vec!["x".into()],
            tests_added: vec!["x_test.rs".into()],
        };
        assert!(v.validate().is_ok());
    }

    #[test]
    fn code_fix_rejects_non_diff() {
        let v = CodeFixOutput {
            unified_diff: "here is what i would do".into(),
            files_touched: vec!["x".into()],
            tests_added: vec![],
        };
        assert!(v.validate().is_err());
    }

    #[test]
    fn code_fix_rejects_empty_files_touched() {
        let v = CodeFixOutput {
            unified_diff: "diff --git a/x b/x\n".into(),
            files_touched: vec![],
            tests_added: vec![],
        };
        assert!(v.validate().is_err());
    }

    // DecomposeOutput validation ────────────────────────────────────────────

    fn good_sub_gap() -> SubGap {
        SubGap {
            description: "Add foo module".into(),
            files_to_modify: vec!["src/foo.rs".into()],
            branch_name: "chump/foo-claim".into(),
            test_command: "cargo test foo".into(),
            depends_on: vec![],
        }
    }

    #[test]
    fn decompose_accepts_well_formed_sub_gap() {
        let v = DecomposeOutput {
            sub_gaps: vec![good_sub_gap()],
            reasoning: "single-file scope".into(),
        };
        assert!(v.validate().is_ok());
    }

    #[test]
    fn decompose_rejects_bad_branch_name() {
        let mut sg = good_sub_gap();
        sg.branch_name = "feat/foo".into();
        let v = DecomposeOutput {
            sub_gaps: vec![sg],
            reasoning: "x".into(),
        };
        let err = v.validate().unwrap_err();
        assert!(err.message().contains("chump/"));
    }

    #[test]
    fn decompose_rejects_empty_files_to_modify() {
        let mut sg = good_sub_gap();
        sg.files_to_modify = vec![];
        let v = DecomposeOutput {
            sub_gaps: vec![sg],
            reasoning: "x".into(),
        };
        assert!(v.validate().is_err());
    }

    #[test]
    fn decompose_rejects_empty_sub_gaps() {
        let v = DecomposeOutput {
            sub_gaps: vec![],
            reasoning: "x".into(),
        };
        assert!(v.validate().is_err());
    }

    // Smoke test: prompts render without panicking and include the inputs.
    #[test]
    fn prompts_include_inputs() {
        let p = GapReviewContract::prompt(&GapReviewInput {
            gap_id: "INFRA-1720".into(),
            context: "xyz".into(),
        });
        assert!(p.contains("INFRA-1720"));
        assert!(p.contains("xyz"));

        let p = CodeFixContract::prompt(&CodeFixInput {
            file_path: "src/foo.rs".into(),
            symptom: "panicked at X".into(),
        });
        assert!(p.contains("src/foo.rs"));
        assert!(p.contains("panicked at X"));

        let p = DecomposeContract::prompt(&DecomposeInput {
            gap_id: "INFRA-1720".into(),
            ast_map_json: "{}".into(),
        });
        assert!(p.contains("INFRA-1720"));
    }

    // Default tier selections (regression: if someone flips Decompose to
    // Sonnet by accident, the cost picture changes).
    #[test]
    fn tiers_are_intentional() {
        assert_eq!(GapReviewContract::model_tier(), ModelTier::Sonnet);
        assert_eq!(CodeFixContract::model_tier(), ModelTier::Sonnet);
        assert_eq!(DecomposeContract::model_tier(), ModelTier::Opus);
        assert_eq!(ExternalRepoContract::model_tier(), ModelTier::Sonnet);
        assert_eq!(IntegrationCycleContract::model_tier(), ModelTier::Sonnet);
    }

    // ExternalRepoOutput validation ───────────────────────────────────────────

    fn good_external_output() -> ExternalRepoOutput {
        ExternalRepoOutput {
            pr_url: "https://github.com/ehippy/derelict/pull/42".into(),
            head_ref: "chump/fix-foo".into(),
            base_ref: "main".into(),
            files_touched: vec!["src/main.rs".into()],
            commit_sha: "abc123def456abc123def456abc123def456abc1".into(),
            notes: "Fixed the thing".into(),
        }
    }

    #[test]
    fn external_repo_accepts_valid_output() {
        assert!(good_external_output().validate().is_ok());
    }

    #[test]
    fn external_repo_rejects_bad_pr_url() {
        let mut out = good_external_output();
        out.pr_url = "https://github.com/ehippy/derelict/issues/42".into();
        let err = out.validate().unwrap_err();
        assert!(err.message().contains("pr_url must match"));

        let mut out2 = good_external_output();
        out2.pr_url = "not-a-url".into();
        assert!(out2.validate().is_err());

        let mut out3 = good_external_output();
        out3.pr_url = "https://github.com/ehippy/derelict/pull/abc".into();
        assert!(out3.validate().is_err());
    }

    #[test]
    fn external_repo_rejects_empty_files_touched() {
        let mut out = good_external_output();
        out.files_touched = vec![];
        let err = out.validate().unwrap_err();
        assert!(err.message().contains("files_touched cannot be empty"));
    }

    #[test]
    fn external_repo_rejects_empty_commit_sha() {
        let mut out = good_external_output();
        out.commit_sha = "".into();
        let err = out.validate().unwrap_err();
        assert!(err.message().contains("commit_sha cannot be empty"));
    }

    #[test]
    fn external_repo_prompt_includes_inputs() {
        let input = ExternalRepoInput {
            external_repo: "ehippy/derelict".into(),
            repo_local_path: "/tmp/derelict".into(),
            proposed_gap_description: "Add retry logic to fetch".into(),
            base_branch: "main".into(),
            fork_owner: Some("repairman29".into()),
        };
        let p = ExternalRepoContract::prompt(&input);
        assert!(p.contains("ehippy/derelict"));
        assert!(p.contains("/tmp/derelict"));
        assert!(p.contains("Add retry logic to fetch"));
        assert!(p.contains("main"));
        // COTG-1.2/INFRA-3484: the contract is now EDIT-ONLY — the agent does not commit,
        // push, or open a PR (the fleet's deterministic_ship does), so the prompt must tell
        // it so and must NOT ask it to emit a pr_url. Fork ownership is a fleet concern now,
        // no longer surfaced to the agent.
        assert!(p.contains("EDIT ONLY"), "prompt must instruct edit-only");
        assert!(p.contains("do NOT"), "prompt must forbid git ops");
        assert!(
            !p.contains("pr_url"),
            "edit-only prompt must not ask for a pr_url"
        );
    }

    // IntegrationCycleContract tests ──────────────────────────────────────────

    fn good_cycle_input() -> IntegrationCycleInput {
        IntegrationCycleInput {
            cycle_id: "integration-2026-05-29-1430".into(),
            candidate_gap_ids: vec!["INFRA-100".into(), "INFRA-101".into()],
            integration_branch: "integration/2026-05-29".into(),
            preflight_log_path: "logs/preflight-2026-05-29-1430.log".into(),
            trigger_reason: TriggerReason::Cadence,
        }
    }

    fn good_cycle_output() -> IntegrationCycleOutput {
        IntegrationCycleOutput {
            cycle_status: CycleStatus::Shipped,
            manifest: vec![
                ManifestEntry {
                    gap_id: "INFRA-100".into(),
                    commit_sha: "aabbccddaabbccddaabbccddaabbccddaabbccdd".into(),
                },
                ManifestEntry {
                    gap_id: "INFRA-101".into(),
                    commit_sha: "1122334411223344112233441122334411223344".into(),
                },
            ],
            quarantined_gap_ids: vec![],
            root_cause_signature: None,
            bisect_runs: 0,
        }
    }

    #[test]
    fn accept_valid_output() {
        let input = good_cycle_input();
        let output = good_cycle_output();
        assert!(output.validate_against_input(&input).is_ok());
    }

    #[test]
    fn reject_manifest_quarantined_mismatch() {
        let input = good_cycle_input(); // 2 candidates
        let mut output = good_cycle_output();
        // Remove one manifest entry — total becomes 1, expected 2.
        output.manifest.pop();
        let err = output.validate_against_input(&input).unwrap_err();
        assert!(
            err.message().contains("expected 2"),
            "unexpected error: {}",
            err.message()
        );
    }

    #[test]
    fn reject_bad_cycle_id_format() {
        let mut input = good_cycle_input();
        input.cycle_id = "run-2026-05-29-1430".into(); // wrong prefix
        let output = good_cycle_output();
        let err = output.validate_against_input(&input).unwrap_err();
        assert!(err.message().contains("cycle_id"));

        let mut input2 = good_cycle_input();
        input2.cycle_id = "integration-26-05-29-1430".into(); // short year
        let err2 = good_cycle_output()
            .validate_against_input(&input2)
            .unwrap_err();
        assert!(err2.message().contains("cycle_id"));
    }

    #[test]
    fn reject_empty_branch() {
        let mut input = good_cycle_input();
        input.integration_branch = "   ".into();
        let output = good_cycle_output();
        let err = output.validate_against_input(&input).unwrap_err();
        assert!(err.message().contains("integration_branch"));
    }

    #[test]
    fn prompt_includes_all_inputs() {
        let input = good_cycle_input();
        let p = IntegrationCycleContract::prompt(&input);
        assert!(
            p.contains("integration-2026-05-29-1430"),
            "missing cycle_id"
        );
        assert!(p.contains("INFRA-100"), "missing candidate gap id");
        assert!(p.contains("INFRA-101"), "missing candidate gap id");
        assert!(
            p.contains("integration/2026-05-29"),
            "missing integration_branch"
        );
        assert!(
            p.contains("logs/preflight-2026-05-29-1430.log"),
            "missing preflight_log_path"
        );
        // TriggerReason::Cadence serialises to "Cadence"
        assert!(p.contains("Cadence"), "missing trigger_reason");
    }
}

// ── (INFRA-2265) ArchitectureDecisionContract ─────────────────────────────────

/// Input to the arch-decision subagent: the product intent string + any
/// constraints the parent already knows (e.g. team language, existing stack).
#[derive(Debug, Clone, Serialize)]
pub struct ArchitectureDecisionInput {
    /// One-sentence product intent (from `chump bootstrap <intent>`).
    pub intent: String,
    /// Optional free-form constraints (existing team language, infra, etc.).
    /// Empty string means "no constraints".
    pub constraints: String,
}

/// Output: the decided architecture for the new product.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ArchitectureDecisionOutput {
    /// Primary language (e.g. `"rust"`, `"python"`, `"typescript"`).
    pub language: String,
    /// Framework or approach (e.g. `"axum"`, `"fastapi"`, `"minimal"`).
    pub framework: String,
    /// Test harness (e.g. `"cargo test"`, `"pytest"`, `"jest"`).
    pub test_harness: String,
    /// Core library dependencies to add at project creation time.
    pub deps: Vec<String>,
    /// Brief rationale for why this architecture fits the intent.
    pub rationale: String,
}

impl Validate for ArchitectureDecisionOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.language.trim().is_empty() {
            return Err(ValidationError::new(
                "language cannot be empty — must specify a primary language (e.g. rust, python, typescript)",
            ));
        }
        if self.framework.trim().is_empty() {
            return Err(ValidationError::new("framework cannot be empty"));
        }
        if self.test_harness.trim().is_empty() {
            return Err(ValidationError::new("test_harness cannot be empty"));
        }
        if self.rationale.trim().is_empty() {
            return Err(ValidationError::new("rationale cannot be empty"));
        }
        Ok(())
    }
}

/// Subagent decides the architecture for a new product given an intent string.
///
/// Use case: `chump bootstrap <intent>` (INFRA-2265) uses this contract to get a
/// typed architecture decision before scaffolding the project. The parent uses the
/// `language` field to choose between Cargo.toml / package.json / pyproject.toml.
///
/// When `--skip-arch-decision` is passed (for tests), the parent uses the
/// default output directly without spawning a subagent under this contract.
pub struct ArchitectureDecisionContract;

impl HandoffContract for ArchitectureDecisionContract {
    type Input = ArchitectureDecisionInput;
    type Output = ArchitectureDecisionOutput;

    fn name() -> &'static str {
        "ArchitectureDecisionContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are deciding the technology architecture for a new product.

Product intent: {intent}

Constraints: {constraints}

Choose the primary language, framework, test harness, and core dependencies that
best fit this intent. Prefer well-tested, production-ready choices. For systems-level
or performance-critical work, prefer Rust. For data/ML work, prefer Python.
For web/API work with a small team, prefer TypeScript or Python.

Emit a single fenced JSON block with this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "language": "rust" | "python" | "typescript" | ...,
  "framework": "axum" | "fastapi" | "minimal" | ...,
  "test_harness": "cargo test" | "pytest" | "jest" | ...,
  "deps": ["dep1", "dep2", ...],
  "rationale": "<2-3 sentence justification for why this architecture fits the intent>"
}}
```

Rules:
- `language` MUST be a single lowercase string (no version numbers).
- `framework` SHOULD be a well-known framework for the chosen language; use `"minimal"` if none applies.
- `deps` MAY be empty if no core libraries are needed at project creation.
- `rationale` MUST explain why this architecture fits the stated intent specifically.
"#,
            intent = input.intent,
            constraints = if input.constraints.is_empty() {
                "none"
            } else {
                &input.constraints
            }
        )
    }

    fn model_tier() -> ModelTier {
        // Architecture decisions benefit from Sonnet-level reasoning.
        // Opus reserved for genuinely complex cross-pillar trade-offs.
        ModelTier::Sonnet
    }
}

#[cfg(test)]
mod arch_decision_tests {
    use super::*;
    use crate::HandoffContract;

    #[test]
    fn arch_decision_validate_rejects_empty_language() {
        let out = ArchitectureDecisionOutput {
            language: String::new(),
            framework: "minimal".to_string(),
            test_harness: "cargo test".to_string(),
            deps: vec![],
            rationale: "some rationale".to_string(),
        };
        assert!(
            out.validate().is_err(),
            "empty language should fail validation"
        );
    }

    #[test]
    fn arch_decision_validate_accepts_valid_output() {
        let out = ArchitectureDecisionOutput {
            language: "rust".to_string(),
            framework: "minimal".to_string(),
            test_harness: "cargo test".to_string(),
            deps: vec![],
            rationale: "test fixture default".to_string(),
        };
        assert!(
            out.validate().is_ok(),
            "valid output should pass validation"
        );
    }

    #[test]
    fn arch_decision_prompt_contains_intent() {
        let input = ArchitectureDecisionInput {
            intent: "A CLI tool that syncs files across machines".to_string(),
            constraints: String::new(),
        };
        let p = ArchitectureDecisionContract::prompt(&input);
        assert!(
            p.contains("A CLI tool that syncs files across machines"),
            "intent missing from prompt"
        );
        assert!(p.contains("none"), "empty constraints should show 'none'");
    }
}

// ── Unit tests: ExternalRepoContract prompt bar-awareness (EFFECTIVE-215) ──

#[cfg(test)]
mod external_repo_bar_aware_tests {
    use super::*;
    use crate::HandoffContract;

    /// Build a minimal but valid ExternalRepoInput for prompt-content assertions.
    fn sample_input() -> ExternalRepoInput {
        ExternalRepoInput {
            external_repo: "ehippy/derelict".to_string(),
            repo_local_path: "/tmp/derelict".to_string(),
            proposed_gap_description: "Add a health-check endpoint".to_string(),
            base_branch: "main".to_string(),
            fork_owner: Some("repairman29".to_string()),
        }
    }

    /// Gate 1 — prompt must tell the agent that external repo CI must be GREEN.
    #[test]
    fn prompt_mentions_ci_green() {
        let p = ExternalRepoContract::prompt(&sample_input());
        // Both "CI" and "green" (or "GREEN") must appear in the MERGE BAR section.
        let lower = p.to_ascii_lowercase();
        assert!(
            lower.contains("ci") && lower.contains("green"),
            "prompt must mention CI and green; got:\n{p}"
        );
    }

    /// Gate 2 — prompt must describe the fail-on-base / pass-on-head requirement.
    #[test]
    fn prompt_mentions_fail_on_base_pass_on_head() {
        let p = ExternalRepoContract::prompt(&sample_input());
        let lower = p.to_ascii_lowercase();
        // "fail" (or "fails") on "base" and "pass" (or "passes") on "head" must appear.
        assert!(
            lower.contains("fail") && lower.contains("base"),
            "prompt must state test FAILS on base; got:\n{p}"
        );
        assert!(
            lower.contains("pass") && lower.contains("head"),
            "prompt must state test PASSES on head; got:\n{p}"
        );
    }

    /// Gate 2 — prompt must reject cosmetic PRs (no test file changed).
    #[test]
    fn prompt_mentions_cosmetic_rejection() {
        let p = ExternalRepoContract::prompt(&sample_input());
        let lower = p.to_ascii_lowercase();
        // "cosmetic" or "no test" must appear to warn the agent about this class of held PRs.
        assert!(
            lower.contains("cosmetic") || lower.contains("no test"),
            "prompt must warn about cosmetic (no-test) PRs; got:\n{p}"
        );
    }

    /// Gate 3 — prompt must mention regression.
    #[test]
    fn prompt_mentions_regression() {
        let p = ExternalRepoContract::prompt(&sample_input());
        let lower = p.to_ascii_lowercase();
        assert!(
            lower.contains("regression"),
            "prompt must mention regression gate; got:\n{p}"
        );
    }

    /// Self-verify requirement — prompt must tell the agent to self-verify before opening.
    #[test]
    fn prompt_mentions_self_verify() {
        let p = ExternalRepoContract::prompt(&sample_input());
        let lower = p.to_ascii_lowercase();
        assert!(
            lower.contains("self-verify")
                || lower.contains("self_verify")
                || lower.contains("verify"),
            "prompt must instruct the agent to self-verify; got:\n{p}"
        );
    }

    /// Sanity: proposed_gap_description and external_repo are interpolated.
    #[test]
    fn prompt_interpolates_input_fields() {
        let input = sample_input();
        let p = ExternalRepoContract::prompt(&input);
        assert!(
            p.contains(&input.external_repo),
            "external_repo missing from prompt"
        );
        assert!(
            p.contains(&input.proposed_gap_description),
            "proposed_gap_description missing from prompt"
        );
    }
}

// ── (g) VisionIntakeContract ───────────────────────────────────────────────
//
// INFRA-3480: CREATE-mode conversational intake. Sits downstream of the
// front-door router (src/front_door.rs, EFFECTIVE-330) — that layer decides
// CREATE vs FIX vs UNSURE; this contract owns turning a free-text CREATE
// problem statement into a plain-language restatement + clarifying questions
// + proposed definition-of-done. The golden-transcript guarantee (no software
// jargon ever reaches the user) is enforced structurally in `Output::validate`,
// not left to prompt discipline alone.

/// Case-insensitive, word-boundary software-jargon banlist. Any of these
/// leaking into `restatement`, a clarifying question, or `proposed_dod` is a
/// [`ValidationError`] — see [`VisionIntakeOutput::validate`].
const JARGON_BANLIST: &[&str] = &[
    "pull request",
    "pr",
    "branch",
    "ci",
    "test",
    "deploy",
    "commit",
    "merge",
    "repository",
    "repo",
    "gap",
];

/// True if `term` appears in `haystack` on a word boundary (case-insensitive).
///
/// A plain substring check would reject "prepare" for containing "pr" or
/// "greeting" for containing "gap"-adjacent letters; this walks each match of
/// `term` and only counts it when the characters immediately before/after are
/// not alphanumeric (or the match sits at a string edge).
fn contains_banned_term(haystack: &str, term: &str) -> bool {
    let text = haystack.to_lowercase();
    let term = term.to_lowercase();
    let hbytes = text.as_bytes();
    if term.is_empty() || hbytes.len() < term.len() {
        return false;
    }
    let mut search_from = 0usize;
    while let Some(rel) = text[search_from..].find(&term) {
        let start = search_from + rel;
        let end = start + term.len();
        let before_ok = start == 0 || !hbytes[start - 1].is_ascii_alphanumeric();
        let after_ok = end >= hbytes.len() || !hbytes[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        search_from = start + 1;
    }
    false
}

/// Scan every banlist term against `haystack`; returns the first hit (for the
/// `ValidationError` message) or `None` when clean.
fn first_jargon_hit(haystack: &str) -> Option<&'static str> {
    JARGON_BANLIST
        .iter()
        .find(|term| contains_banned_term(haystack, term))
        .copied()
}

/// Input to the vision-intake subagent: the user's free-text problem
/// statement plus any prior clarifying answers already gathered (empty on the
/// first turn).
#[derive(Debug, Clone, Serialize)]
pub struct VisionIntakeInput {
    /// The user's problem statement, verbatim, in their own words.
    pub problem: String,
    /// Answers to previously asked clarifying questions, in order asked.
    /// Empty on the first turn of a conversation.
    pub prior_answers: Vec<String>,
}

/// EFFECTIVE-505 (EFFECTIVE-443 slice): the JTBD-sharpen triple — who is
/// struggling, what the struggling moment looks like, and what signal tells
/// them the struggle is over. Optional on [`VisionIntakeOutput`] (`#[serde(default)]`)
/// so payloads produced before this slice still deserialize (AC3).
///
/// EFFECTIVE-1457 (EFFECTIVE-443 slice): this is the canonical `who` /
/// `struggling_moment` / `done_signal` triple for the EFFECTIVE intake data
/// model — [`VisionIntakeOutput::jtbd`] and
/// `chump_gap_store::Outcome::jtbd_who` /
/// `jtbd_struggling_moment` / `jtbd_done_signal` both round-trip these three
/// fields verbatim, so there is exactly one shape to keep in sync.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct JtbdSummary {
    /// Plain-language description of who is struggling (the "who" in JTBD).
    pub who: String,
    /// Plain-language description of the moment the struggle shows up.
    pub struggling_moment: String,
    /// Plain-language description of the signal that tells them it's solved.
    pub done_signal: String,
}

/// Output from vision-intake: a plain-language restatement of the problem,
/// 1-3 clarifying questions, and a plain-language proposed definition-of-done.
///
/// None of the three original fields (plus `jtbd`'s three fields, when
/// present) may contain software-vocabulary terms — see [`JARGON_BANLIST`].
/// This is the load-bearing guarantee of INFRA-3480: a non-technical founder
/// never sees "PR", "branch", "CI", etc. in this flow.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct VisionIntakeOutput {
    /// Plain-language restatement of the user's problem, proving it was understood.
    pub restatement: String,
    /// 1-3 plain-language clarifying questions.
    pub clarifying_questions: Vec<String>,
    /// Plain-language proposed definition-of-done for the resulting outcome.
    pub proposed_dod: String,
    /// EFFECTIVE-505: who/struggling-moment/done-signal, when the model
    /// supplies it. `None` for payloads produced before this slice.
    #[serde(default)]
    pub jtbd: Option<JtbdSummary>,
}

impl Validate for VisionIntakeOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.restatement.trim().is_empty() {
            return Err(ValidationError::new("restatement cannot be empty"));
        }
        if self.clarifying_questions.is_empty() || self.clarifying_questions.len() > 3 {
            return Err(ValidationError::new(format!(
                "clarifying_questions must contain 1-3 entries, got {}",
                self.clarifying_questions.len()
            )));
        }
        for (i, q) in self.clarifying_questions.iter().enumerate() {
            if q.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "clarifying_questions[{i}] cannot be empty"
                )));
            }
        }
        if self.proposed_dod.trim().is_empty() {
            return Err(ValidationError::new("proposed_dod cannot be empty"));
        }

        if let Some(term) = first_jargon_hit(&self.restatement) {
            return Err(ValidationError::new(format!(
                "restatement leaks software jargon term {term:?} — vision intake must stay in plain language"
            )));
        }
        for (i, q) in self.clarifying_questions.iter().enumerate() {
            if let Some(term) = first_jargon_hit(q) {
                return Err(ValidationError::new(format!(
                    "clarifying_questions[{i}] leaks software jargon term {term:?} — vision intake must stay in plain language"
                )));
            }
        }
        if let Some(term) = first_jargon_hit(&self.proposed_dod) {
            return Err(ValidationError::new(format!(
                "proposed_dod leaks software jargon term {term:?} — vision intake must stay in plain language"
            )));
        }

        if let Some(jtbd) = &self.jtbd {
            if jtbd.who.trim().is_empty() {
                return Err(ValidationError::new("jtbd.who cannot be empty"));
            }
            if jtbd.struggling_moment.trim().is_empty() {
                return Err(ValidationError::new(
                    "jtbd.struggling_moment cannot be empty",
                ));
            }
            if jtbd.done_signal.trim().is_empty() {
                return Err(ValidationError::new("jtbd.done_signal cannot be empty"));
            }
            if let Some(term) = first_jargon_hit(&jtbd.who) {
                return Err(ValidationError::new(format!(
                    "jtbd.who leaks software jargon term {term:?} — vision intake must stay in plain language"
                )));
            }
            if let Some(term) = first_jargon_hit(&jtbd.struggling_moment) {
                return Err(ValidationError::new(format!(
                    "jtbd.struggling_moment leaks software jargon term {term:?} — vision intake must stay in plain language"
                )));
            }
            if let Some(term) = first_jargon_hit(&jtbd.done_signal) {
                return Err(ValidationError::new(format!(
                    "jtbd.done_signal leaks software jargon term {term:?} — vision intake must stay in plain language"
                )));
            }
        }

        Ok(())
    }
}

/// Subagent reads a free-text CREATE-mode problem statement and reflects back
/// a plain-language restatement + 1-3 clarifying questions + a proposed
/// definition-of-done. Used by `chump intake "<text>"` (src/vision_intake.rs).
pub struct VisionIntakeContract;

impl HandoffContract for VisionIntakeContract {
    type Input = VisionIntakeInput;
    type Output = VisionIntakeOutput;

    fn name() -> &'static str {
        "VisionIntakeContract"
    }

    fn prompt(input: &Self::Input) -> String {
        let prior_str = if input.prior_answers.is_empty() {
            "(none yet — this is the first turn)".to_string()
        } else {
            input
                .prior_answers
                .iter()
                .enumerate()
                .map(|(i, a)| format!("{}. {a}", i + 1))
                .collect::<Vec<_>>()
                .join("\n")
        };
        format!(
            r#"You are a friendly intake assistant talking to someone who wants to
describe a problem they want solved. They are NOT a software engineer — they
may never have written code. Your job is to make them feel heard and to
gather just enough detail to scope the work, entirely in plain language.

Problem statement (their words):
{problem}

Prior answers already gathered:
{prior_str}

Instructions:
1. Write a `restatement` — 1-3 sentences reflecting their problem back in
   plain language, proving you understood it.
2. Write 1 to 3 `clarifying_questions` — plain-language questions that would
   help scope the work. Ask about outcomes and constraints, not implementation.
3. Write a `proposed_dod` — a plain-language description of what "done" would
   look like to the person asking, from their point of view.
4. Write a `jtbd` object sharpening the "job to be done": `who` is struggling
   (in plain language, e.g. "a solo dog walker juggling paper routes"),
   `struggling_moment` is the specific moment the struggle shows up, and
   `done_signal` is the plain-language signal that tells them it's solved.

HARD RULE: none of the fields may use software-engineering vocabulary.
Never write any of these words or phrases, in any form: "PR" / "pull request",
"branch", "CI", "test", "deploy", "commit", "merge", "repo" / "repository",
"gap". Describe outcomes the way you'd explain them to a friend, not a
developer. Violating this rule will cause your response to be rejected.

Emit a SINGLE fenced JSON block (no other JSON, no commentary outside the block):

```json
{{
  "restatement": "<1-3 plain-language sentences>",
  "clarifying_questions": ["<question 1>", "<question 2 (optional)>", "<question 3 (optional)>"],
  "proposed_dod": "<plain-language description of done>",
  "jtbd": {{
    "who": "<plain-language who is struggling>",
    "struggling_moment": "<plain-language moment the struggle shows up>",
    "done_signal": "<plain-language signal it's solved>"
  }}
}}
```
"#,
            problem = input.problem,
            prior_str = prior_str,
        )
    }
}

#[cfg(test)]
mod tests_vision_intake {
    use super::*;
    use crate::transport::StubTransport;

    fn good_output() -> VisionIntakeOutput {
        VisionIntakeOutput {
            restatement: "You want a simple way for customers to book a time slot online \
                          without calling your office."
                .into(),
            clarifying_questions: vec![
                "How many time slots do you usually offer in a day?".into(),
                "Should customers be able to cancel a booking themselves?".into(),
            ],
            proposed_dod: "A customer can pick an open time, get a confirmation, and you can \
                           see all upcoming bookings in one place."
                .into(),
            jtbd: Some(JtbdSummary {
                who: "A small shop owner who takes bookings by phone.".into(),
                struggling_moment: "The phone rings while they're mid-task and they lose track \
                                     of who booked what."
                    .into(),
                done_signal: "They can glance at one place and see every upcoming booking.".into(),
            }),
        }
    }

    #[test]
    fn accepts_clean_output() {
        assert!(good_output().validate().is_ok());
    }

    #[test]
    fn rejects_empty_restatement() {
        let mut o = good_output();
        o.restatement = "   ".into();
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("restatement cannot be empty"));
    }

    #[test]
    fn rejects_zero_clarifying_questions() {
        let mut o = good_output();
        o.clarifying_questions = vec![];
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("1-3 entries"));
    }

    #[test]
    fn rejects_too_many_clarifying_questions() {
        let mut o = good_output();
        o.clarifying_questions = vec!["a".into(), "b".into(), "c".into(), "d".into()];
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("1-3 entries"));
    }

    #[test]
    fn rejects_empty_dod() {
        let mut o = good_output();
        o.proposed_dod = "".into();
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("proposed_dod cannot be empty"));
    }

    /// AC #2 — a jargon leak anywhere is a hard `ValidationError`, proven by
    /// feeding jargon-laden output through `validate()` directly.
    #[test]
    fn vision_intake_rejects_jargon_leak() {
        let mut o = good_output();
        o.restatement = "We'll open a PR against your repo once the branch is ready.".into();
        let err = o.validate().unwrap_err();
        assert!(
            err.message().contains("software jargon"),
            "expected jargon rejection, got: {}",
            err.message()
        );
    }

    #[test]
    fn rejects_jargon_in_clarifying_question() {
        let mut o = good_output();
        o.clarifying_questions = vec!["Should we run the test suite before we merge?".into()];
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("clarifying_questions[0]"));
    }

    #[test]
    fn rejects_jargon_in_dod() {
        let mut o = good_output();
        o.proposed_dod = "The commit is merged and deployed.".into();
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("proposed_dod"));
    }

    /// AC1/AC3 (EFFECTIVE-505): `jtbd` is optional — a payload with no `jtbd`
    /// key at all still deserializes and validates, so pre-slice callers/tests
    /// keep working unchanged.
    #[test]
    fn jtbd_absent_deserializes_and_validates() {
        let json = r#"{
            "restatement": "You want customers to book online.",
            "clarifying_questions": ["How many slots per day?"],
            "proposed_dod": "A customer can pick a time and get a confirmation."
        }"#;
        let o: VisionIntakeOutput = serde_json::from_str(json).unwrap();
        assert!(o.jtbd.is_none());
        assert!(o.validate().is_ok());
    }

    #[test]
    fn rejects_empty_jtbd_who() {
        let mut o = good_output();
        if let Some(jtbd) = o.jtbd.as_mut() {
            jtbd.who = "  ".into();
        }
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("jtbd.who cannot be empty"));
    }

    #[test]
    fn rejects_jargon_in_jtbd_done_signal() {
        let mut o = good_output();
        if let Some(jtbd) = o.jtbd.as_mut() {
            jtbd.done_signal = "The PR is merged and deployed.".into();
        }
        let err = o.validate().unwrap_err();
        assert!(err.message().contains("jtbd.done_signal"));
    }

    #[test]
    fn word_boundary_does_not_false_positive_on_substrings() {
        // "prepare" contains "pr", "greeting" is nowhere near "gap" but this
        // guards the boundary logic explicitly for a "gap"-adjacent word.
        let mut o = good_output();
        o.restatement = "We will prepare a gapless schedule so nothing overlaps.".into();
        // "gapless" contains "gap" as a substring but not on a word boundary.
        assert!(o.validate().is_ok());
    }

    /// AC #3 — golden-transcript: drive 3 vague, non-technical visions through
    /// the full dispatch pipeline via `StubTransport` and assert the produced
    /// restatement + questions + DoD contain zero banlist terms.
    #[tokio::test]
    async fn golden_transcript_no_jargon_leak() {
        let clean_reply = r#"Here you go:
```json
{
  "restatement": "You want your regular customers to get a friendly reminder before their membership runs out.",
  "clarifying_questions": ["How many days before it runs out should the reminder go out?", "Should the reminder go by text, email, or both?"],
  "proposed_dod": "Every customer gets a heads-up message a few days before their membership ends, automatically."
}
```"#;
        let visions = [
            "People keep forgetting to renew their gym membership and we lose them.",
            "I run a small bakery and I want customers to be able to order a custom cake without emailing back and forth ten times.",
            "My team keeps double-booking the same meeting room and it's causing fights.",
        ];
        for vision in visions {
            let stub = StubTransport::new(clean_reply);
            let input = VisionIntakeInput {
                problem: vision.to_string(),
                prior_answers: vec![],
            };
            let output = crate::dispatch::<VisionIntakeContract>(&stub, "test-agent", input)
                .await
                .unwrap_or_else(|e| {
                    panic!("golden transcript dispatch failed for {vision:?}: {e}")
                });

            for term in JARGON_BANLIST {
                assert!(
                    !contains_banned_term(&output.restatement, term),
                    "restatement leaked jargon {term:?} for vision {vision:?}"
                );
                for q in &output.clarifying_questions {
                    assert!(
                        !contains_banned_term(q, term),
                        "clarifying question leaked jargon {term:?} for vision {vision:?}"
                    );
                }
                assert!(
                    !contains_banned_term(&output.proposed_dod, term),
                    "proposed_dod leaked jargon {term:?} for vision {vision:?}"
                );
            }
        }
    }

    #[test]
    fn prompt_interpolates_problem() {
        let input = VisionIntakeInput {
            problem: "Customers can't find our opening hours.".into(),
            prior_answers: vec![],
        };
        let p = VisionIntakeContract::prompt(&input);
        assert!(p.contains(&input.problem));
    }

    #[test]
    fn prompt_bans_jargon_explicitly() {
        let input = VisionIntakeInput {
            problem: "test".into(),
            prior_answers: vec![],
        };
        let p = VisionIntakeContract::prompt(&input).to_lowercase();
        assert!(p.contains("pull request") && p.contains("branch") && p.contains("commit"));
    }
}
