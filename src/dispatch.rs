//! INFRA-191 — `chump dispatch` (Phase 1 skeleton).
//!
//! Single command that runs the whole ship cycle:
//!   preflight → claim → (caller's work happened already) → ship → release
//!
//! ## Phase 1 scope (PR #783, MERGED)
//!
//! - Public API surface: [`DispatchOptions`], [`DispatchOutcome`],
//!   [`ShipResult`], [`WorkBackend`], [`run`].
//! - Internals **wrap the existing shell scripts** via `std::process::Command`
//!   (gap-preflight.sh, gap-claim.sh, bot-merge.sh).
//! - Only [`WorkBackend::Interactive`] supported.
//!
//! ## Phase 2 scope (THIS PR)
//!
//! - [`WorkBackend::Headless`] — spawn `claude -p <prompt>
//!   --dangerously-skip-permissions` and wait for exit. Used by
//!   `chump-orchestrator` / `run-fleet.sh` (INFRA-211) to do the actual
//!   coding work between claim and ship.
//! - [`WorkBackend::ExecGap`] — spawn `chump --execute-gap <ID>` (chump-local
//!   backend, COG-025). Same surface, different binary; used when
//!   `CHUMP_DISPATCH_BACKEND=chump-local` for cost-routing.
//!
//! ## INFRA-1964 — closing the mission-reality gap on local-LLM
//!
//! - [`WorkBackend::Local`] — spawn `chump gen --local <prompt> --work-dir
//!   <ws>`, which drives the *already-shipped* offline-LLM agent loop
//!   (`src/gen.rs` + `src/agent_loop.rs`, INFRA-593/PRODUCT-050) headlessly
//!   against an OpenAI-compatible local endpoint (Ollama by default; point
//!   `OPENAI_API_BASE` at an MLX server or mistral.rs for those runtimes).
//!   Before this, `chump dispatch` / `run-fleet.sh` only ever reached
//!   [`WorkBackend::Headless`] (`claude -p`), so every fleet worker required
//!   an Anthropic credential regardless of what `CHUMP_WORK_BACKEND` implied
//!   was configurable — the local/offline agent loop existed but had no path
//!   from dispatch into it. Select via `CHUMP_WORK_BACKEND=local`.
//!
//! ## Future phases (NOT this PR)
//!
//! - Phase 3: port [`ship`] to native Rust git/gh calls (replace the
//!   bot-merge.sh wrap).
//! - Phase 4: flip the CLAUDE.md/AGENTS.md ship-pipeline guidance from
//!   `bot-merge.sh` to `chump dispatch`.
//! - Phase 5: retire `scripts/coord/bot-merge.sh`.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::Duration;

// INFRA-302 blocker (3): reuse the orchestrator's worktree-path convention
// so the stale-worktree-reaper (`scripts/ops/stale-worktree-reaper.sh`) +
// the `.claude/worktrees/<gap-slug>/` tree the operator already knows
// about all stay consistent. See [`create_dispatch_worktree`].
use chump_orchestrator::dispatch::dispatch_paths;

/// ZERO-WASTE-133: per-tool-call timeout env + stalled tool-call watchdog.
#[path = "dispatch_tool_watch.rs"]
mod tool_watch;

/// How the actual work between claim and ship gets done.
#[derive(Debug, Clone)]
pub enum WorkBackend {
    /// Caller drives the work directly (e.g. interactive editing in this
    /// shell). `dispatch::run` only orchestrates preflight → claim →
    /// ship → release. The Phase 1 default.
    Interactive,

    /// Spawn `claude -p <prompt> --dangerously-skip-permissions` and wait.
    /// `model` is forwarded via `--model <…>`; pass an empty string to use
    /// the user's `claude` config default. The spawned process inherits the
    /// parent's stdin/stdout/stderr so progress is visible inline.
    Headless { model: String, prompt: String },

    /// Spawn `chump --execute-gap <ID>` (chump-local backend, COG-025).
    /// Used when the operator set `CHUMP_DISPATCH_BACKEND=chump-local` for
    /// cost-routing through Together/mistral.rs/Ollama instead of Anthropic.
    ExecGap,

    /// EFFECTIVE-017: spawn `opencode -p <prompt>` (opencode CLI by SST).
    /// Operator selects via `CHUMP_WORK_BACKEND=opencode`.
    Opencode { model: String, prompt: String },

    /// EFFECTIVE-017: spawn `aider --message <prompt>` (Aider).
    /// Operator selects via `CHUMP_WORK_BACKEND=aider`.
    Aider { model: String, prompt: String },

    /// INFRA-1964: spawn `chump gen --local <prompt> --work-dir <ws>`.
    /// Drives the *existing* offline-LLM agent loop (`src/gen.rs`,
    /// `src/agent_loop.rs`) against an OpenAI-compatible local endpoint
    /// (Ollama/MLX-server/mistral.rs — whatever `OPENAI_API_BASE` points
    /// at) headlessly, so fleet workers can actually run without a
    /// `claude -p` / Anthropic credential. Operator selects via
    /// `CHUMP_WORK_BACKEND=local`.
    Local { prompt: String },
}

/// EFFECTIVE-017: select a `WorkBackend` from `CHUMP_WORK_BACKEND` env var.
/// Mapping: claude/unset → Headless; opencode → Opencode; aider → Aider;
/// chump-local/exec-gap → ExecGap; local/ollama/mlx → Local; anything else →
/// warn + fallback Headless.
///
/// Per the chump-first doctrine, this is the single seam where operators
/// pick the worker binary without editing source.
pub fn backend_from_env(model: String, prompt: String) -> WorkBackend {
    match std::env::var("CHUMP_WORK_BACKEND").as_deref() {
        Ok("opencode") => WorkBackend::Opencode { model, prompt },
        Ok("aider") => WorkBackend::Aider { model, prompt },
        Ok("chump-local") | Ok("exec-gap") => WorkBackend::ExecGap,
        // INFRA-1964: distinct from ExecGap's "chump-local" alias above —
        // this routes to the offline-LLM `chump gen --local` path, not
        // `chump --execute-gap` (which itself defaults to Headless/claude).
        Ok("local") | Ok("ollama") | Ok("mlx") => WorkBackend::Local { prompt },
        Ok("claude") | Ok("") | Err(_) => WorkBackend::Headless { model, prompt },
        Ok(other) => {
            eprintln!(
                "[chump] WARNING: unknown CHUMP_WORK_BACKEND={other:?} — falling back to claude. \
                 Supported: claude, opencode, aider, chump-local, local"
            );
            WorkBackend::Headless { model, prompt }
        }
    }
}

/// INFRA-8199: what kind of cycle this dispatch is. Selected by the thin
/// `chump dispatch` arm from the open-PR gate (`crate::dispatch_repair`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum DispatchMode {
    /// Fresh worktree off `origin/main`, work, ship. The default.
    #[default]
    Work,
    /// An open PR already covers the gap and the operator set
    /// `CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1`: the worktree starts from the PR's
    /// head branch (not `origin/main`) so the repair lands on that PR.
    Repair { head_branch: String },
    /// The agent only proposes (e.g. `chump gap decompose <ID> --dry-run`)
    /// and stops for review: no ship step runs.
    ReviewOnly,
}

/// Options for one dispatch invocation.
#[derive(Debug)]
pub struct DispatchOptions<'a> {
    /// Gap ID to dispatch (e.g. "INFRA-191"). Must be in the gap registry.
    pub gap_id: &'a str,
    /// How the work happens; see [`WorkBackend`].
    pub work: WorkBackend,
    /// Pass `--auto-merge` to the underlying ship command.
    pub auto_merge: bool,
    /// Pass `--skip-tests` to the underlying ship command.
    pub skip_tests: bool,
    /// Optional comma-separated path scope (forwarded to gap-claim --paths,
    /// honored by INFRA-189 out-of-scope guard).
    pub paths: Option<&'a str>,
    /// Repo root. Phase 1 derives this from the caller; the binary entry
    /// point uses `repo_path::repo_root()`.
    pub repo_root: PathBuf,
    /// INFRA-8199: work / repair-an-open-PR / review-only. See [`DispatchMode`].
    pub mode: DispatchMode,
}

/// What happened to the PR after [`ship`] finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShipResult {
    /// PR opened and already landed on main (merged), or opened without
    /// auto-merge — either way the ship produced a real PR. Caller can poll
    /// the merge queue from here. A **success** (exit 0).
    Shipped { pr_number: u64 },
    /// CREDIBLE-1506: PR opened and GitHub auto-merge is armed, but the merge
    /// hasn't landed yet — it will when CI greens. This is the normal zero-touch
    /// steady state right after `chump dispatch --auto-merge`, and it is a
    /// **success** (exit 0): the OS did its whole job. Previously this path
    /// (when a post-arm step bubbled a non-zero bot-merge exit) was reported as
    /// [`ShipResult::Aborted`], so the 2026-10-16 CREDIBLE-301 proof run armed
    /// PR #5500 and auto-merged it with zero manual steps yet dispatch exited 1.
    Armed { pr_number: u64 },
    /// Ship pipeline ran but couldn't queue the PR (CI red, branch
    /// protection failure, etc.).
    Blocked { reason: String },
    /// Hard error — ship pipeline aborted before producing a PR.
    Aborted { error: String },
}

/// Summary of one full dispatch cycle.
#[derive(Debug)]
pub struct DispatchOutcome {
    pub gap_id: String,
    pub branch: String,
    pub result: ShipResult,
    pub duration_secs: u64,
}

/// Run one full dispatch cycle for a single gap.
///
/// Always calls [`release`] at the end, even on error, so a process kill
/// mid-cycle leaves no stale lease. (The lease layer also has a TTL —
/// double belt-and-suspenders.)
///
/// ## INFRA-302 blocker (3) — worktree resolution
///
/// For [`WorkBackend::Headless`] and [`WorkBackend::ExecGap`], `run()`
/// creates a **fresh linked worktree** at `<repo_root>/.claude/worktrees/<gap-slug>`
/// off `origin/main` (matching `chump-orchestrator`'s convention via
/// [`chump_orchestrator::dispatch::dispatch_paths`]) and runs every
/// subsequent step (preflight, claim, work, ship, release) inside it.
/// Without this, the dispatched child runs in `opts.repo_root` (the
/// main checkout) on whatever branch `git rev-parse --abbrev-ref HEAD`
/// returns — which is exactly the 2026-05-02 dogfood failure mode where
/// `chump dispatch INFRA-247` reported `branch=chump/close-ghosts-batch-3`
/// (the operator's leftover branch) and the dispatched work would have
/// committed there if the run hadn't 402'd first.
///
/// For [`WorkBackend::Interactive`] the caller is already in their own
/// worktree (per the CLAUDE.md "always work in a linked worktree" rule
/// plus `gap-claim.sh`'s main-checkout refusal), so `run()` keeps using
/// `opts.repo_root` as the working directory unchanged.
/// CREDIBLE-1577 / CREDIBLE-1526 AC5: shared constant of gate-file globs that
/// must never be dispatched with `--auto-merge`. Matches the union of
/// `BOT_MERGE_GATE_FILE_GLOBS` (`scripts/coord/bot-merge.sh`, CREDIBLE-1576)
/// and `CHUMP_SHIP_GATE_GLOBS` (`scripts/coord/lib/ship-gate-files.sh`,
/// CREDIBLE-1590), plus `crates/chump-ship/*` and
/// `scripts/coord/code-reviewer-agent.sh` (CREDIBLE-1526 AC5).
///
/// Standing rule (Chief 2026-10-20): constant only — NEVER read from any
/// `CHUMP_*` env var (no env override on a safety input).
pub const DISPATCH_GATE_FILE_GLOBS: &[&str] = &[
    ".github/workflows/*",
    "scripts/ci/*",
    "scripts/git-hooks/*",
    "scripts/coord/bot-merge.sh",
    "scripts/coord/code-reviewer-agent.sh",
    "crates/chump-preflight/*",
    "crates/chump-ship/*",
    "*verified-wait*",
];

/// CREDIBLE-1577: return true when `raw_path` matches any entry in
/// [`DISPATCH_GATE_FILE_GLOBS`]. Reads no env var.
pub fn is_dispatch_gate_file(raw_path: &str) -> bool {
    let p = raw_path
        .trim()
        .trim_start_matches("./")
        .trim_end_matches('/');
    if p.is_empty() {
        return false;
    }
    p == ".github/workflows"
        || p.starts_with(".github/workflows/")
        || p == "scripts/ci"
        || p.starts_with("scripts/ci/")
        || p == "scripts/git-hooks"
        || p.starts_with("scripts/git-hooks/")
        || p == "scripts/coord/bot-merge.sh"
        || p == "scripts/coord/code-reviewer-agent.sh"
        || p == "crates/chump-preflight"
        || p.starts_with("crates/chump-preflight/")
        || p == "crates/chump-ship"
        || p.starts_with("crates/chump-ship/")
        || p.contains("verified-wait")
}

/// CREDIBLE-1577: pure gate-file check for `--auto-merge`. Reads no env var.
/// When `auto_merge` is true and any path in `paths` (comma-separated `--paths`
/// lease scope) or `diff_files` (branch diff vs `origin/main`) matches
/// [`is_dispatch_gate_file`], returns `Err(<first matching gate file>)`.
pub fn check_auto_merge_gate_refusal(
    auto_merge: bool,
    paths: Option<&str>,
    diff_files: &[String],
) -> std::result::Result<(), String> {
    if !auto_merge {
        return Ok(());
    }
    if let Some(raw) = paths {
        for entry in raw.split(|c: char| c == ',' || c.is_whitespace()) {
            let trimmed = entry.trim();
            if !trimmed.is_empty() && is_dispatch_gate_file(trimmed) {
                return Err(trimmed.to_string());
            }
        }
    }
    for f in diff_files {
        let trimmed = f.trim();
        if !trimmed.is_empty() && is_dispatch_gate_file(trimmed) {
            return Err(trimmed.to_string());
        }
    }
    Ok(())
}

/// Collect `git diff --name-only origin/main...HEAD` in `dir` when `HEAD` is on
/// a feature/repair branch. Best-effort empty list when `origin/main` is not
/// present in a throwaway repo.
fn collect_branch_diff_files(dir: &Path) -> Vec<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["diff", "--name-only", "origin/main...HEAD"])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

/// INFRA-8083 / MISSION-046: extract `OWNER/REPO` from a gap's `skills_required`
/// (or `notes` tag list) if it carries an `external_repo:OWNER/REPO` tag (single
/// tag or comma/space/tab/newline-separated list).
pub fn external_repo_target_from_skills(skills: &str) -> Option<String> {
    skills
        .split([',', ' ', '\t', '\n', '\r'])
        .find_map(|tok| tok.trim().strip_prefix("external_repo:"))
        .map(|s| s.trim_matches(|c: char| c == '"' || c == '\'').to_string())
        .filter(|s| !s.is_empty() && s.contains('/') && !s.contains('<') && !s.contains('>'))
}

/// Emit `kind=dispatch_auto_merge_refused` to `<repo_root>/.chump-locks/ambient.jsonl`
/// (CREDIBLE-1577 / CREDIBLE-1526 AC5).
// scanner-anchor: "kind":"dispatch_auto_merge_refused"
pub fn emit_dispatch_auto_merge_refused(repo_root: &Path, gap_id: &str, gate_file: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = lock_dir.join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{}\n",
        serde_json::json!({
            "ts": ts,
            "kind": "dispatch_auto_merge_refused",
            "gap_id": gap_id,
            "gate_file": gate_file,
            "reason": "gate_file_touched",
        })
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// CREDIBLE-1577 AC1: pre-spawn check invoked by `chump dispatch` before
/// spawning the agent. Inspects `--paths` and any existing branch diff vs
/// `origin/main`; if `auto_merge` is true and a gate file is touched, emits
/// `kind=dispatch_auto_merge_refused` and returns `Err(gate_file)`.
pub fn check_workspace_auto_merge_gate(
    repo_root: &Path,
    gap_id: &str,
    auto_merge: bool,
    paths: Option<&str>,
) -> std::result::Result<(), String> {
    if !auto_merge {
        return Ok(());
    }
    let diff_files = collect_branch_diff_files(repo_root);
    if let Err(hit) = check_auto_merge_gate_refusal(auto_merge, paths, &diff_files) {
        emit_dispatch_auto_merge_refused(repo_root, gap_id, &hit);
        return Err(hit);
    }
    Ok(())
}

/// INFRA-8114 / RESILIENT-1494: Resolve the path to `~/.chump/oauth-token.json`
/// (honoring `CHUMP_OAUTH_TOKEN_FILE`, `CHUMP_OAUTH_TOKEN_PATH`, `CHUMP_HOME`,
/// and `HOME`).
pub fn oauth_token_file_path() -> Option<PathBuf> {
    for var in ["CHUMP_OAUTH_TOKEN_FILE", "CHUMP_OAUTH_TOKEN_PATH"] {
        if let Ok(v) = std::env::var(var) {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return Some(PathBuf::from(trimmed));
            }
        }
    }
    if let Ok(chump_home) = std::env::var("CHUMP_HOME") {
        let trimmed = chump_home.trim();
        if !trimmed.is_empty() {
            let candidate = PathBuf::from(trimmed).join(".chump/oauth-token.json");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let trimmed = home.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed).join(".chump/oauth-token.json"));
        }
    }
    None
}

/// INFRA-8114 / RESILIENT-1494: Read an OAuth token from `path`
/// (`~/.chump/oauth-token.json`), supporting `"token"`, `"access_token"`,
/// `"claudeAiOauthToken"`, `"oauth_token"`, or a raw token string.
pub fn read_oauth_token_from_file(path: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(trimmed) {
        for key in ["token", "access_token", "claudeAiOauthToken", "oauth_token"] {
            if let Some(s) = val.get(key).and_then(|v| v.as_str()) {
                let t = s.trim();
                if !t.is_empty() {
                    return Some(t.to_string());
                }
            }
        }
        return None;
    }
    Some(trimmed.to_string())
}

/// INFRA-8114 / RESILIENT-1494: Ensure `CLAUDE_CODE_OAUTH_TOKEN` is populated
/// in the caller environment (and on `cmd`, if provided) by sourcing
/// `~/.chump/oauth-token.json` when `CLAUDE_CODE_OAUTH_TOKEN` is absent in the
/// caller environment.
pub fn ensure_oauth_token_env(cmd: Option<&mut Command>) -> Option<String> {
    let existing = std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let token = match existing {
        Some(tok) => Some(tok),
        None => {
            let path = oauth_token_file_path()?;
            let tok = read_oauth_token_from_file(&path)?;
            std::env::set_var("CLAUDE_CODE_OAUTH_TOKEN", &tok);
            Some(tok)
        }
    };
    if let (Some(c), Some(ref tok)) = (cmd, &token) {
        c.env("CLAUDE_CODE_OAUTH_TOKEN", tok);
    }
    token
}

/// INFRA-8114: Return true iff `git log <base>..<branch>` in `repo_dir` shows
/// at least 1 commit. Used by the resume path and pre-ship guard so dispatch
/// NEVER skips `IMPLEMENT` or marks a gap implemented on a zero-commit branch.
pub fn branch_has_commits_ahead(repo_dir: &Path, base: &str, branch: &str) -> bool {
    let range = format!("{base}..{branch}");
    let out = Command::new("git")
        .arg("-C")
        .arg(repo_dir)
        .args(["log", "--oneline", &range])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .any(|l| !l.trim().is_empty()),
        _ => false,
    }
}

/// INFRA-8114: Resume gate — returns `true` ONLY when `branch` has `>= 1`
/// commit ahead of `base` (`origin/main`). A branch with zero commits must
/// never skip `IMPLEMENT`.
pub fn can_resume_skip_implement(repo_dir: &Path, base: &str, branch: &str) -> bool {
    branch_has_commits_ahead(repo_dir, base, branch)
}

/// INFRA-8114: Clean up orphan worktree, local branch, and lease file when a
/// dispatch/ship fails on an unshipped branch so no orphan is left to re-pick
/// or false-close.
pub fn cleanup_failed_dispatch_workspace(
    repo_root: &Path,
    worktree: &Path,
    branch: &str,
    session_id: &str,
) {
    if !session_id.is_empty() {
        let wt_lease = worktree
            .join(".chump-locks")
            .join(format!("{session_id}.json"));
        let _ = std::fs::remove_file(wt_lease);
        let root_lease = repo_root
            .join(".chump-locks")
            .join(format!("{session_id}.json"));
        let _ = std::fs::remove_file(root_lease);
    }
    if worktree != repo_root && worktree.exists() {
        let _ = Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(worktree)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        let _ = std::fs::remove_dir_all(worktree);
    }
    if !branch.is_empty() && branch != "main" && branch != "HEAD" {
        let _ = Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["branch", "-D", branch])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

/// RESILIENT-1642: Resolve the single node-wide shared `CARGO_TARGET_DIR`
/// (matching `scripts/ci/lib/resolve-cargo-target-dir.sh` from `ZERO-WASTE-134`):
///   1. `CARGO_TARGET_DIR` if set, non-empty, and not inside `.claude/worktrees/`
///   2. `CHUMP_CARGO_TARGET` if set, non-empty, and not inside `.claude/worktrees/`
///   3. `$HOME/.cargo/chump-shared-target`
pub fn resolve_shared_cargo_target_dir() -> PathBuf {
    for var in ["CARGO_TARGET_DIR", "CHUMP_CARGO_TARGET"] {
        if let Ok(val) = std::env::var(var) {
            let trimmed = val.trim();
            if !trimmed.is_empty() && !trimmed.contains(".claude/worktrees/") {
                let p = PathBuf::from(trimmed);
                let _ = std::fs::create_dir_all(&p);
                return p;
            }
        }
    }
    let base = std::env::var("HOME")
        .ok()
        .map(|h| h.trim().to_string())
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let shared = base.join(".cargo/chump-shared-target");
    let _ = std::fs::create_dir_all(&shared);
    shared
}

/// RESILIENT-1494: Default subagent budget when no effort or env override is
/// present (`>= 1800s`, replacing the old 900s cliff).
pub const DEFAULT_SUBAGENT_BUDGET_SECS: u64 = 1800;

/// RESILIENT-1494: Effort-scaled subagent budget:
/// `xs` -> 1200s, `s` -> 2400s, `m` -> 3600s, `l` -> 5400s, `xl`/unknown -> 5400s.
pub fn budget_secs_for_effort(effort: &str) -> u64 {
    match effort.trim().to_ascii_lowercase().as_str() {
        "xs" => 1200,
        "s" => 2400,
        "m" => 3600,
        "l" => 5400,
        "xl" => 5400,
        _ => 5400,
    }
}

/// RESILIENT-1494: Resolve subagent budget in seconds, honoring
/// `CHUMP_SUBAGENT_BUDGET_S`, `CHUMP_DISPATCH_TIMEOUT_SECS`, and legacy
/// `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S` before scaling by `effort` (or falling
/// back to [`DEFAULT_SUBAGENT_BUDGET_SECS`]).
pub fn resolve_subagent_budget_secs(effort: Option<&str>) -> u64 {
    for var in [
        "CHUMP_SUBAGENT_BUDGET_S",
        "CHUMP_DISPATCH_TIMEOUT_SECS",
        "CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S",
    ] {
        if let Ok(val) = std::env::var(var) {
            if let Ok(parsed) = val.trim().parse::<u64>() {
                return parsed;
            }
        }
    }
    match effort.map(str::trim).filter(|e| !e.is_empty()) {
        Some(eff) => budget_secs_for_effort(eff),
        None => DEFAULT_SUBAGENT_BUDGET_SECS,
    }
}

/// RESILIENT-1494: Resolve the subagent budget for `gap_id` by checking env
/// overrides first, then looking up the gap's `effort` in the canonical store.
pub fn resolve_subagent_budget_secs_for_gap(repo_root: &Path, gap_id: &str) -> u64 {
    let effort = crate::dispatch_repair::load_canonical_gap(repo_root, gap_id)
        .ok()
        .map(|row| row.effort);
    resolve_subagent_budget_secs(effort.as_deref())
}

/// RESILIENT-1494: Pure predicate — returns `true` when the 1-minute load
/// average exceeds `nproc` (`load_1m > nproc as f64`), pausing the dispatch
/// budget clock while the host is CPU-saturated.
pub fn is_load_exceeding_nproc(load_1m: f64, nproc: usize) -> bool {
    nproc > 0 && load_1m > (nproc as f64)
}

/// Read `(load_1m, nproc)` from the OS.
pub fn current_load_1m_and_nproc() -> (f64, usize) {
    let nproc = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    #[cfg(unix)]
    let load_1m = {
        let mut avg = [0.0f64; 1];
        // SAFETY: getloadavg writes at most 1 element into `avg`.
        let n = unsafe { libc::getloadavg(avg.as_mut_ptr(), 1) };
        if n == 1 {
            avg[0]
        } else {
            0.0
        }
    };
    #[cfg(not(unix))]
    let load_1m = 0.0;
    (load_1m, nproc)
}

fn host_load_exceeds_nproc() -> bool {
    let (load_1m, nproc) = current_load_1m_and_nproc();
    is_load_exceeding_nproc(load_1m, nproc)
}

/// RESILIENT-1494: Before a budget kill (`SIGTERM`), commit any staged or
/// modified work with a `wip:` subject, push `HEAD` to
/// `origin refs/stash/<gap>-<ts>`, and append an entry to
/// `docs/process/STASHED_WORK.md`. Returns `Some(stash_ref)` if a commit was
/// salvaged/pushed.
pub fn salvage_wip_before_budget_kill(worktree: &Path, gap_id: &str) -> Option<String> {
    if !worktree.is_dir() {
        return None;
    }
    let status_out = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["status", "--porcelain"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let dirty = status_out.status.success()
        && String::from_utf8_lossy(&status_out.stdout)
            .lines()
            .any(|l| !l.trim().is_empty());
    if dirty {
        let _ = Command::new("git")
            .arg("-C")
            .arg(worktree)
            .args(["add", "-A"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        let msg = format!("wip({gap_id}): partial progress salvaged before budget kill");
        let _ = Command::new("git")
            .arg("-C")
            .arg(worktree)
            .args([
                "-c",
                "user.name=chump-dispatch",
                "-c",
                "user.email=chump@fleet.local",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "--no-verify",
                "-m",
                &msg,
            ])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    } else if !branch_has_commits_ahead(worktree, "origin/main", "HEAD") {
        return None;
    }

    let head_sha = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["rev-parse", "--short", "HEAD"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())?;

    let now = chrono::Utc::now();
    let ts = now.format("%Y%m%d-%H%M%S").to_string();
    let date = now.format("%Y-%m-%d").to_string();
    let slug = gap_id.to_ascii_lowercase().replace('_', "-");
    let stash_ref = format!("refs/stash/{slug}-{ts}");
    let refspec = format!("HEAD:{stash_ref}");
    let _ = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["push", "--no-verify", "origin", &refspec])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    let row = format!(
        "| `{stash_ref}` | {gap_id} | {date} | `{head_sha}` | wip: dispatch budget-kill salvage |\n"
    );
    let mut targets = vec![worktree.join("docs/process/STASHED_WORK.md")];
    if let Some(checkout) = chump_gap_store::store_path::resolve(worktree).checkout {
        let main_doc = checkout.join("docs/process/STASHED_WORK.md");
        if !targets.contains(&main_doc) {
            targets.push(main_doc);
        }
    }
    for doc in targets {
        if let Some(parent) = doc.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        use std::io::Write as _;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&doc)
        {
            let _ = f.write_all(row.as_bytes());
        }
    }
    Some(stash_ref)
}

pub fn run(opts: DispatchOptions) -> Result<DispatchOutcome> {
    let started = std::time::Instant::now();

    // INFRA-8114 / RESILIENT-1494: source ~/.chump/oauth-token.json into
    // CLAUDE_CODE_OAUTH_TOKEN when absent in caller env so manual `chump dispatch`
    // and `claude -p` authenticate from any shell.
    ensure_oauth_token_env(None);

    // CREDIBLE-1577 AC1: refuse --auto-merge before creating worktree or
    // spawning the agent when --paths or the existing branch diff touches a
    // gate file.
    if let Err(hit) =
        check_workspace_auto_merge_gate(&opts.repo_root, opts.gap_id, opts.auto_merge, opts.paths)
    {
        bail!(
            "CREDIBLE-1577: refusing --auto-merge for {} — touches gate file {}",
            opts.gap_id,
            hit
        );
    }

    // INFRA-8083: When not repairing an in-repo PR, resolve the gap from the
    // canonical store before creating a chump worktree or running bot-merge.sh.
    // If the gap carries `external_repo:<owner>/<repo>` in `skills_required`
    // (or `notes`), route directly to `chump improve <owner>/<repo> --gap <ID>
    // --apply` so external-repo gaps never create a chump worktree or invoke
    // in-repo bot-merge.sh.
    if !matches!(opts.mode, DispatchMode::Repair { .. }) {
        let canonical_row =
            crate::dispatch_repair::load_canonical_gap(&opts.repo_root, opts.gap_id);
        if let Ok(ref row) = canonical_row {
            let ext_target = external_repo_target_from_skills(&row.skills_required)
                .or_else(|| external_repo_target_from_skills(&row.notes));
            if let Some(owner_repo) = ext_target {
                eprintln!(
                    "[dispatch] INFRA-8083: gap {} is tagged external_repo:{} — routing to chump improve {} --gap {} --apply",
                    opts.gap_id, owner_repo, owner_repo, opts.gap_id
                );
                let dry_run =
                    std::env::var("CHUMP_DISPATCH_EXTERNAL_DRY_RUN").as_deref() == Ok("1");
                if dry_run {
                    println!("chump improve {} --gap {} --apply", owner_repo, opts.gap_id);
                    return Ok(DispatchOutcome {
                        gap_id: opts.gap_id.to_string(),
                        branch: format!("external:{owner_repo}"),
                        result: ShipResult::Shipped { pr_number: 0 },
                        duration_secs: started.elapsed().as_secs(),
                    });
                }
                let improve_args = vec![
                    owner_repo.clone(),
                    "--gap".to_string(),
                    opts.gap_id.to_string(),
                    "--apply".to_string(),
                ];
                let rc = crate::improve::run(&improve_args);
                let duration_secs = started.elapsed().as_secs();
                if rc == 0 {
                    return Ok(DispatchOutcome {
                        gap_id: opts.gap_id.to_string(),
                        branch: format!("external:{owner_repo}"),
                        result: ShipResult::Shipped { pr_number: 0 },
                        duration_secs,
                    });
                } else {
                    return Ok(DispatchOutcome {
                        gap_id: opts.gap_id.to_string(),
                        branch: format!("external:{owner_repo}"),
                        result: ShipResult::Aborted {
                            error: format!(
                                "chump improve {} --gap {} --apply exited {}",
                                owner_repo, opts.gap_id, rc
                            ),
                        },
                        duration_secs,
                    });
                }
            }
        }
        // RESILIENT-1494: Resolve the gap from the CANONICAL store before creating
        // a worktree or spawning an agent; fail loud if the gap cannot be loaded so
        // we never spawn `claude -p` on an empty/fallback prompt.
        if opts.mode == DispatchMode::Work && !matches!(opts.work, WorkBackend::Interactive) {
            let row = canonical_row.map_err(|e| anyhow::anyhow!("{e}"))?;
            if std::env::var_os("CHUMP_SUBAGENT_BUDGET_S").is_none()
                && std::env::var_os("CHUMP_DISPATCH_TIMEOUT_SECS").is_none()
                && std::env::var_os("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S").is_none()
            {
                let effort_budget = budget_secs_for_effort(&row.effort);
                std::env::set_var("CHUMP_SUBAGENT_BUDGET_S", effort_budget.to_string());
            }
        }
    }

    // Build the workspace: working_dir is either a fresh worktree (Headless
    // / ExecGap) or the caller's repo_root (Interactive). See [`Workspace`].
    let workspace = Workspace::new(&opts)
        .context("resolving workspace (worktree creation for ExecGap/Headless)")?;
    let branch = current_branch(workspace.working_dir())?;

    // INFRA-8204: one session id for the whole dispatch cycle, printed once
    // so the ship-phase log and the "released session_id=" line (src/main.rs)
    // are visibly the same id — see [`Workspace::new`] for where it's
    // resolved/exported/persisted.
    if !workspace.session_id.is_empty() {
        eprintln!(
            "[dispatch] {} session_id={}",
            opts.gap_id, workspace.session_id
        );
    }

    // Step 1: preflight (read-only check).
    preflight(&workspace).context("preflight")?;

    // Step 2: claim (writes .chump-locks/<session>.json).
    claim(&workspace).context("claim")?;

    // Step 3: caller's work happens here. Interactive = caller already did
    // it; Headless / ExecGap = spawn the work-doing process and wait.
    // INFRA-8114: if resume is requested, verify the branch actually has >= 1
    // commit ahead of origin/main before skipping IMPLEMENT. Never skip
    // IMPLEMENT on an empty/commitless branch.
    let resume_skip = std::env::var("CHUMP_DISPATCH_RESUME").as_deref() == Ok("1")
        && can_resume_skip_implement(workspace.working_dir(), "origin/main", &branch);
    let work_result = if resume_skip {
        eprintln!(
            "[dispatch] {}: resume verified commits on origin/main..{} — skipping IMPLEMENT",
            opts.gap_id, branch
        );
        Ok(())
    } else {
        do_work(&workspace)
    };
    // INFRA-8203: a work child that exited (or was killed) with its changes
    // uncommitted and nothing committed above origin/main has stranded its
    // work. Save it as <GAP>.stranded.patch and emit kind=dispatch_work_stranded
    // instead of handing bot-merge a dirty tree to auto-commit.
    let stranded = detect_stranded_work(&workspace);
    let result = if let Err(e) = work_result {
        // Always release before propagating the error so a failed work
        // step doesn't leave a stale lease. INFRA-1243: use retry+emit path.
        release_with_retry(&workspace)?;
        cleanup_failed_dispatch_workspace(
            &opts.repo_root,
            workspace.working_dir(),
            &branch,
            &workspace.session_id,
        );
        ShipResult::Aborted {
            error: format!("work step failed: {e:#}"),
        }
    } else if let Some(s) = stranded {
        release_with_retry(&workspace)?;
        cleanup_failed_dispatch_workspace(
            &opts.repo_root,
            workspace.working_dir(),
            &branch,
            &workspace.session_id,
        );
        ShipResult::Aborted {
            error: format!(
                "work stranded: {} uncommitted path(s), no commit above origin/main; \
                 patch saved to {} (INFRA-8203)",
                s.files,
                s.patch_path.display()
            ),
        }
    } else if opts.mode == DispatchMode::Work
        && !matches!(opts.work, WorkBackend::Interactive)
        && !branch_has_commits_ahead(workspace.working_dir(), "origin/main", "HEAD")
    {
        // INFRA-8114: never ship or mark a gap implemented when the branch has
        // ZERO commits ahead of origin/main.
        release_with_retry(&workspace)?;
        cleanup_failed_dispatch_workspace(
            &opts.repo_root,
            workspace.working_dir(),
            &branch,
            &workspace.session_id,
        );
        ShipResult::Aborted {
            error: format!(
                "INFRA-8114: branch {branch} has zero commits ahead of origin/main — refusing to ship empty branch"
            ),
        }
    } else {
        // Step 4: ship (calls bot-merge.sh in Phase 1; native in Phase 3).
        // Capture errors instead of `?`-ing so we always reach release.
        // INFRA-8199: a review-only cycle (decompose --dry-run proposal)
        // never ships; filing/landing is the operator's call.
        let ship_result = if opts.mode == DispatchMode::ReviewOnly {
            ShipResult::Blocked {
                reason: "review-only: proposal printed, nothing shipped; filing sub-gaps \
                         is the operator's or the decompose curator's call (INFRA-8199)"
                    .to_string(),
            }
        } else {
            match ship(&workspace) {
                Ok(r) => r,
                Err(e) => ShipResult::Aborted {
                    error: format!("{e:#}"),
                },
            }
        };

        // Step 5: always release the lease. INFRA-1243: retry+emit on failure.
        release_with_retry(&workspace)?;
        if matches!(ship_result, ShipResult::Aborted { .. }) {
            cleanup_failed_dispatch_workspace(
                &opts.repo_root,
                workspace.working_dir(),
                &branch,
                &workspace.session_id,
            );
        }
        ship_result
    };

    // Single exit point (INFRA-8198 AC2): report exit code, reason, and
    // whether the spawned work child is still alive. By this point
    // `do_work`'s spawn_* helper has either returned normally (its
    // `ChildGroupGuard` released, child reaped) or been force-killed by
    // `wait_with_hang_detection` (group signaled) — so
    // `child_alive_at_exit` should read `false` on every path; a `true`
    // here is exactly the INFRA-8198 bug reproducing.
    let child_pid = workspace.child_pid();
    let (exit_code, reason, status) = classify_exit(&result);
    let child_alive_at_exit = child_pid.map(|pid| child_is_alive(pid)).unwrap_or(false);
    let duration_secs = started.elapsed().as_secs();
    eprintln!(
        "[dispatch] {} exit={} status={} reason={} child_pid={} child_alive_at_exit={}",
        opts.gap_id,
        exit_code,
        status,
        reason,
        child_pid.unwrap_or(0),
        child_alive_at_exit
    );
    emit_dispatch_exit(DispatchExitEvent {
        gap_id: opts.gap_id,
        session_id: &workspace.session_id,
        exit_code,
        status,
        reason: &reason,
        child_pid: child_pid.unwrap_or(0),
        child_alive_at_exit,
        duration_s: duration_secs,
    });

    // RESILIENT-1624: the SessionStart hook inside a headless `claude -p`
    // daemonizes an urgent-inbox poll loop out of the work child's process
    // group, so INFRA-8198's process-group kill above never reaches it. Kill
    // it explicitly on the way out so no immortal poller is left pinning the
    // worktree cwd against the Class-D reaper. The loop also self-exits on its
    // next tick (its session is this dispatch's child), so this is the fast
    // path, not the only one.
    kill_urgent_inbox_poll_loop(workspace.working_dir());

    Ok(DispatchOutcome {
        gap_id: opts.gap_id.to_string(),
        branch,
        result,
        duration_secs,
    })
}

/// CREDIBLE-1506: map a terminal [`ShipResult`] to the process exit code, the
/// human-facing final line (which always names the PR), and a stable status
/// token for the `kind=dispatch_exit` ambient event. Pure + total so the
/// decision is unit-tested directly (89-self-audit keeps logic out of
/// `src/main.rs`, and the exit-code contract is the credible/ground-truth
/// surface this gap is about).
///
/// Success vs. failure, honestly:
/// - [`ShipResult::Shipped`] → a landed (or opened) PR, exit 0.
/// - [`ShipResult::Armed`] → auto-merge armed and pending, exit 0. This is the
///   case CREDIBLE-301 (#5500) regressed on: an armed PR that later merged with
///   zero manual steps must NOT read as `aborted`.
/// - [`ShipResult::Blocked`] → ran but couldn't queue the PR, exit 2.
/// - [`ShipResult::Aborted`] → never produced/armed a PR, exit 1 (genuine fail).
fn classify_exit(result: &ShipResult) -> (i32, String, &'static str) {
    match result {
        ShipResult::Shipped { pr_number } => (0, format!("shipped pr=#{pr_number}"), "shipped"),
        ShipResult::Armed { pr_number } => {
            (0, format!("armed pr=#{pr_number} awaiting merge"), "armed")
        }
        ShipResult::Blocked { reason } => (2, format!("blocked: {reason}"), "blocked"),
        ShipResult::Aborted { error } => (1, format!("aborted: {error}"), "failed"),
    }
}

/// INFRA-8198: probe whether `pid` is still alive via a signal-0 `kill`
/// (doesn't actually signal; just checks the process exists and we have
/// permission to signal it). Used for the `child_alive_at_exit` report.
#[cfg(unix)]
fn child_is_alive(pid: u32) -> bool {
    // SAFETY: kill(pid, 0) with signal 0 sends no signal — it only probes
    // whether `pid` exists and is signalable, which is safe for any pid.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

#[cfg(not(unix))]
fn child_is_alive(_pid: u32) -> bool {
    false
}

/// RESILIENT-1624: kill the urgent-inbox poll loop that the SessionStart hook
/// (`scripts/setup/session-start-urgent-inbox-poll.sh`) daemonized for this
/// worktree. The hook writes the loop's pid to
/// `<working_dir>/.chump-locks/urgent-inbox-poll-loop.pid`; because the hook
/// runs inside the headless `claude -p` work child and nohup/disowns the loop
/// out of the process group, INFRA-8198's `kill_process_group` never reaches
/// it — so it would otherwise survive as an immortal poller pinning the
/// worktree cwd against the Class-D reaper. Best-effort: a missing pidfile, a
/// stale pid, or a non-unix host is a no-op.
#[cfg(unix)]
fn kill_urgent_inbox_poll_loop(working_dir: &Path) {
    let pidfile = working_dir
        .join(".chump-locks")
        .join("urgent-inbox-poll-loop.pid");
    let Ok(contents) = std::fs::read_to_string(&pidfile) else {
        return;
    };
    let Some(pid) = contents
        .lines()
        .next()
        .and_then(|l| l.trim().parse::<i32>().ok())
    else {
        return;
    };
    if pid > 1 && child_is_alive(pid as u32) {
        // SAFETY: SIGTERM to a specific, still-live pid read from our own
        // worktree's pidfile; no negative pid / process-group semantics here.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
    }
    let _ = std::fs::remove_file(&pidfile);
}

#[cfg(not(unix))]
fn kill_urgent_inbox_poll_loop(_working_dir: &Path) {}

/// INFRA-8198: signal a whole process group (negative pid). `pid` must be a
/// pgid produced by [`configure_child_lifetime`]'s `process_group(0)` (which
/// makes the child its own group leader, so its pgid equals its pid) — used
/// by the budget/hang kill paths in [`wait_with_hang_detection`] so a
/// child's own subprocesses (cargo, git, …) die with it instead of being
/// orphaned onto PPID 1.
fn kill_process_group(pid: u32, sig: libc::c_int) {
    // SAFETY: `pid` is a process group this `chump dispatch` process itself
    // created for its spawned child; signaling `-pid` can only reach that
    // group.
    unsafe {
        libc::kill(-(pid as libc::pid_t), sig);
    }
}

/// INFRA-8083: Terminate a child process and its entire process group (`-pgid`,
/// where `pgid == child.id()` from `process_group(0)`). Sends `SIGTERM` first,
/// polls briefly for exit, then sends `SIGKILL` to the group, calls
/// `child.kill()`, and reaps `child.wait()`.
#[cfg(unix)]
pub fn kill_child_process_group(child: &mut Child) {
    let pid = child.id();
    if pid > 1 {
        kill_process_group(pid, libc::SIGTERM);
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_millis(200) {
            if let Ok(Some(_)) = child.try_wait() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        kill_process_group(pid, libc::SIGKILL);
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(not(unix))]
pub fn kill_child_process_group(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Internal bundle of `(DispatchOptions, working_dir)` so step functions
/// don't have to repeat the resolution. INFRA-302 blocker (3) introduced
/// this so working_dir can differ from `opts.repo_root` (fresh worktree
/// for ExecGap/Headless).
///
/// Owned `working_dir: PathBuf` so the worktree path stays valid for the
/// whole dispatch lifetime (the worktree is created in [`Self::new`] and
/// outlives any borrows of `opts`).
struct Workspace<'a> {
    opts: &'a DispatchOptions<'a>,
    working_dir: PathBuf,
    /// INFRA-8204: the single session id used for the entire dispatch cycle
    /// (claim, work child, ship, release, every ambient emit). Empty for
    /// [`WorkBackend::Interactive`] — the caller already owns a session id
    /// from its own shell. See [`resolve_dispatch_session_id`].
    session_id: String,
    /// INFRA-8198: pid of the spawned work child (`claude -p`, `chump
    /// --execute-gap`, …), recorded by [`Workspace::set_child_pid`] right
    /// after `spawn()` succeeds so [`run`]'s single exit point can report
    /// `child_pid=`/`child_alive_at_exit=` regardless of which `do_work`
    /// branch returned. `Cell` because the spawn_* helpers only hold `&
    /// Workspace`. `None` for [`WorkBackend::Interactive`], which never
    /// spawns a child.
    child_pid: std::cell::Cell<Option<u32>>,
}

impl<'a> Workspace<'a> {
    fn new(opts: &'a DispatchOptions) -> Result<Self> {
        let (working_dir, session_id) = match opts.work {
            WorkBackend::Interactive => {
                // Caller is already in their worktree (per CLAUDE.md +
                // gap-claim.sh enforcement). No worktree creation needed;
                // matches the pre-INFRA-302 behavior so the Interactive
                // ledger-flip flow doesn't regress.
                (opts.repo_root.clone(), String::new())
            }
            WorkBackend::Headless { .. }
            | WorkBackend::ExecGap
            | WorkBackend::Opencode { .. }
            | WorkBackend::Aider { .. }
            | WorkBackend::Local { .. } => {
                // Fresh linked worktree off origin/main. INFRA-302 blocker
                // (3): without this, the dispatched child runs in the main
                // checkout on the operator's stale branch. The worktree is
                // intentionally NOT torn down on success — bot-merge.sh
                // writes `.bot-merge-shipped` and the
                // stale-worktree-reaper sweeps it up later (see CLAUDE.md
                // "Worktree disk hygiene"). On hard failure we also leave
                // it in place so the operator can inspect.
                // INFRA-8199: a repair starts from the open PR's head branch.
                let repair_base = match &opts.mode {
                    DispatchMode::Repair { head_branch } => Some(head_branch.as_str()),
                    _ => None,
                };
                let working_dir =
                    create_dispatch_worktree_from(&opts.repo_root, opts.gap_id, repair_base)
                        .with_context(|| format!("creating worktree for {}", opts.gap_id))?;

                // INFRA-8204: resolve ONE session id for the whole dispatch
                // cycle and export it into THIS process's env so every
                // subsequent step (claim(), release(), the spawned work
                // child, every ambient emit) inherits it by default — the
                // explicit `cmd.env(...)` calls in ship()/spawn_* are
                // belt-and-suspenders on top of that inheritance. Without
                // this, claim() writes the lease under a node-wide session
                // id that ship()'s `bot-merge.sh` (run without
                // CHUMP_SESSION_ID exported) can never find in the
                // worktree's own `.chump-locks/`, so bot-merge re-invokes
                // `chump claim` and either spawns a stray second worktree
                // or fails outright (INFRA-8204).
                let session_id = resolve_dispatch_session_id(opts.gap_id);
                std::env::set_var("CHUMP_SESSION_ID", &session_id);
                std::env::set_var("CHUMP_DISPATCH_GAP", opts.gap_id);
                write_wt_session_id_file(&working_dir, &session_id);

                (working_dir, session_id)
            }
        };
        Ok(Self {
            opts,
            working_dir,
            session_id,
            child_pid: std::cell::Cell::new(None),
        })
    }

    fn working_dir(&self) -> &Path {
        &self.working_dir
    }

    fn opts(&self) -> &DispatchOptions<'a> {
        self.opts
    }

    /// INFRA-8198: record the pid of the just-spawned work child so [`run`]
    /// can report it at the single exit point.
    fn set_child_pid(&self, pid: u32) {
        self.child_pid.set(Some(pid));
    }

    fn child_pid(&self) -> Option<u32> {
        self.child_pid.get()
    }
}

/// INFRA-8204: resolve the single session id to use for an entire dispatch
/// cycle on a worktree-creating backend. `CHUMP_SESSION_ID` wins if already
/// set (trimmed, non-empty) — e.g. an orchestrator that already assigned one
/// — otherwise derive `dispatch-<slug>-<pid>-<unix_ts>`, where `slug` is the
/// same lowercase gap slug [`create_dispatch_worktree`] uses for the worktree
/// directory (via [`chump_orchestrator::dispatch::dispatch_paths`]).
fn resolve_dispatch_session_id(gap_id: &str) -> String {
    if let Ok(v) = std::env::var("CHUMP_SESSION_ID") {
        let v = v.trim();
        if !v.is_empty() {
            return v.to_string();
        }
    }
    let slug = gap_id.to_ascii_lowercase().replace('_', "-");
    let pid = std::process::id();
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("dispatch-{slug}-{pid}-{ts}")
}

/// INFRA-8204: persist the resolved session id to
/// `<working_dir>/.chump-locks/.wt-session-id`, the same file
/// `ambient_emit.rs::resolve_session_id` already reads as a fallback when
/// `CHUMP_SESSION_ID`/`CLAUDE_SESSION_ID` are unset — so a child process that
/// somehow drops the env var still resolves the same id. Best-effort: a
/// write failure here doesn't abort the dispatch (the env var export is the
/// primary path).
fn write_wt_session_id_file(working_dir: &Path, session_id: &str) {
    let lock_dir = working_dir.join(".chump-locks");
    if std::fs::create_dir_all(&lock_dir).is_ok() {
        let _ = std::fs::write(lock_dir.join(".wt-session-id"), session_id);
    }
}

/// INFRA-302 blocker (3): create a fresh linked worktree for a dispatched
/// agent. Path + branch follow [`chump_orchestrator::dispatch::dispatch_paths`]
/// (`<repo_root>/.claude/worktrees/<gap-slug>` + `claude/<gap-slug>`)
/// so the stale-worktree-reaper, the orchestrator's spawn path, and
/// `chump dispatch` all point at the same conventions.
///
/// Idempotent: if a leftover worktree from a prior killed dispatch
/// exists at the same path, it is force-removed first (along with the
/// orphan branch). The lease system already prevents two live sessions
/// from claiming the same gap in parallel (assuming single-host lease
/// visibility — INFRA-274 covers cross-host), so the only legitimate
/// pre-existing worktree at that path is detritus.
fn create_dispatch_worktree(repo_root: &Path, gap_id: &str) -> Result<PathBuf> {
    create_dispatch_worktree_from(repo_root, gap_id, None)
}

/// INFRA-8199: like [`create_dispatch_worktree`], but with
/// `repair_branch = Some(<PR head>)` the worktree checks out that branch at
/// `origin/<PR head>` instead of cutting `claude/<slug>` from `origin/main`.
/// Before this, a re-dispatch of a gap whose PR was already open deleted the
/// local `claude/<slug>` branch and started over from main (the 2026-10-16
/// 00:35Z CREDIBLE-1491 receipt). A local copy of the head branch that is not
/// an ancestor of the remote head is preserved under
/// `refs/dispatch-backup/<branch>` before being reset (archive, never delete).
fn create_dispatch_worktree_from(
    repo_root: &Path,
    gap_id: &str,
    repair_branch: Option<&str>,
) -> Result<PathBuf> {
    use coord_mesh::MeshBridge;
    // INFRA-2264: activates the `coord-mesh` crate dependency; the bridge
    // itself is not yet wired into the worktree-creation flow (that's
    // follow-on work once the real mesh-bridge substrate lands).
    let _bridge = MeshBridge::new();

    let (worktree_path, default_branch) = dispatch_paths(repo_root, gap_id);
    if let Some(head) = repair_branch {
        return create_repair_worktree(repo_root, &worktree_path, head);
    }
    let branch_name = default_branch;

    // Idempotent cleanup of any leftover worktree at the target path.
    // Failure is non-fatal — the subsequent `worktree add` will report a
    // clearer error if the path is genuinely contended (e.g. a live
    // sibling has it open).
    if worktree_path.exists() {
        let _ = Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(&worktree_path)
            .status();
    }
    // Same for any leftover branch from a prior dispatch that was
    // worktree-removed without `git branch -D`. Without this, the next
    // `git worktree add -b <branch>` fails with "branch already exists".
    let _ = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["branch", "-D", &branch_name])
        .status();

    let status = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["worktree", "add"])
        .arg(&worktree_path)
        .args(["-b", &branch_name, "origin/main"])
        .status()
        .with_context(|| {
            format!(
                "spawning git worktree add {} -b {} origin/main",
                worktree_path.display(),
                branch_name
            )
        })?;
    if !status.success() {
        bail!(
            "git worktree add failed for {} (branch {}, base origin/main)",
            worktree_path.display(),
            branch_name
        );
    }

    // INFRA-8207: `git worktree add -b <branch> origin/main` sets <branch>'s
    // upstream to origin/main (git prints "set up to track remote branch
    // 'main' from 'origin'"). `gh pr create` without --head infers the head
    // branch from the current branch's upstream, so a dispatch-created
    // branch would otherwise point `gh pr create` at main's PR, not its own
    // — forcing a manual `--head` rescue. Re-point the upstream at the
    // branch itself so `gh pr create` (and `git push` without `-u`) resolve
    // correctly from here on.
    set_dispatch_branch_upstream(&worktree_path, &branch_name);

    // RESILIENT-555: symlink the fresh worktree's .chump/state.db to the
    // main checkout's copy, same as `chump claim` already does (INFRA-3834
    // 6c-pre4). Without this, the worktree gets its own empty state.db that
    // doesn't contain the gap being dispatched, so the preflight step right
    // after this returns "not found in state.db (run chump gap import
    // first)" for a gap that IS open in the canonical registry.
    chump_atomic_claim::atomic_claim::nugget_prefetch::link_state_db(repo_root, &worktree_path);
    write_worktree_search_ignore(&worktree_path);

    Ok(worktree_path)
}

/// ZERO-WASTE-133: every dispatch worktree carries a `.ignore` that keeps
/// agent searches (rg / fd / ag) out of build output; the same writer runs in
/// `chump claim`. Best-effort: a failure is logged, never fatal.
fn write_worktree_search_ignore(worktree: &Path) {
    use chump_atomic_claim::atomic_claim::worktree_search_ignore as wsi;
    if let Err(e) = wsi::write_search_ignore(worktree) {
        eprintln!("[dispatch] ZERO-WASTE-133: could not write .ignore: {e}");
    }
}

/// INFRA-8199: check out an open PR's head branch into `worktree_path`,
/// based at `origin/<head>`. See [`create_dispatch_worktree_from`].
fn create_repair_worktree(repo_root: &Path, worktree_path: &Path, head: &str) -> Result<PathBuf> {
    if worktree_path.exists() {
        let _ = Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(worktree_path)
            .status();
    }
    let remote_ref = format!("refs/remotes/origin/{head}");
    let fetched = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["fetch", "--quiet", "origin"])
        .arg(format!("+refs/heads/{head}:{remote_ref}"))
        .status()
        .with_context(|| format!("spawning git fetch origin {head}"))?;
    if !fetched.success() {
        bail!("git fetch origin {head} failed: cannot base the repair on the PR head");
    }
    // Preserve a diverged local copy before `-B` resets it.
    let rev = |r: &str| -> Option<String> {
        Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["rev-parse", "--verify", "--quiet", r])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    if let Some(local) = rev(&format!("refs/heads/{head}")) {
        let is_ancestor = Command::new("git")
            .arg("-C")
            .arg(repo_root)
            .args(["merge-base", "--is-ancestor", &local, &remote_ref])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !is_ancestor {
            let backup = format!("refs/dispatch-backup/{head}");
            let _ = Command::new("git")
                .arg("-C")
                .arg(repo_root)
                .args(["update-ref", &backup, &local])
                .status();
            eprintln!("[dispatch] preserved diverged local {head} at {backup} ({local})");
        }
    }
    let status = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["worktree", "add"])
        .arg(worktree_path)
        .args(["-B", head, &remote_ref])
        .status()
        .with_context(|| format!("spawning git worktree add -B {head} {remote_ref}"))?;
    if !status.success() {
        bail!(
            "git worktree add failed for {} (branch {head}, base {remote_ref})",
            worktree_path.display()
        );
    }
    set_dispatch_branch_upstream(worktree_path, head);
    chump_atomic_claim::atomic_claim::nugget_prefetch::link_state_db(repo_root, worktree_path);
    write_worktree_search_ignore(worktree_path);
    eprintln!("[dispatch] repair worktree on PR head {head} (base {remote_ref}, not origin/main)");
    Ok(worktree_path.to_path_buf())
}

/// Point `branch`'s upstream at `origin/<branch>` instead of whatever
/// `git worktree add -b <branch> origin/main` left it tracking (origin/main).
/// Best-effort: a failure here doesn't block dispatch, it just means the
/// INFRA-8207 `--head`-inference convenience won't apply for this branch.
fn set_dispatch_branch_upstream(worktree: &Path, branch: &str) {
    let remote_status = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["config", &format!("branch.{branch}.remote"), "origin"])
        .status();
    let merge_status = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args([
            "config",
            &format!("branch.{branch}.merge"),
            &format!("refs/heads/{branch}"),
        ])
        .status();

    let failed = !matches!(remote_status, Ok(s) if s.success())
        || !matches!(merge_status, Ok(s) if s.success());
    if failed {
        eprintln!("[dispatch] warn: could not set upstream for {branch}");
    }
}

// ── Internals (each one independently portable in Phase 3) ───────────────────

/// INFRA-8177: Returns `true` when a gap's priority (`P0` / `critical`) or
/// tags/skills/title (`keystone` / `unwedge`) require a minimum `sonnet`
/// routing floor regardless of `xs`/`s` effort size.
pub fn is_keystone_or_p0_floor(priority: &str, tags_or_skills: &str, title: &str) -> bool {
    let p = priority.trim();
    if p.eq_ignore_ascii_case("P0") || p.eq_ignore_ascii_case("critical") {
        return true;
    }
    let tags_lower = tags_or_skills.to_ascii_lowercase();
    let title_lower = title.to_ascii_lowercase();
    for marker in ["keystone", "unwedge"] {
        if tags_lower.contains(marker) || title_lower.contains(marker) {
            return true;
        }
    }
    false
}

/// INFRA-8177: Select model class (`haiku` | `sonnet` | `opus`) for a gap
/// given `(priority, effort, tags_or_skills, title)`.
///
/// Effort tiers default to `xs`/`s` -> `haiku`, `m`/`l` -> `sonnet`,
/// `xl` -> `opus`, but any `P0`/`critical` or `keystone`/`unwedge` gap has a
/// hard floor of `sonnet` (never `haiku`).
pub fn select_model_for_gap(
    priority: &str,
    effort: &str,
    tags_or_skills: &str,
    title: &str,
) -> &'static str {
    let base = match effort.trim().to_ascii_lowercase().as_str() {
        "xl" => "opus",
        "m" | "l" => "sonnet",
        _ => "haiku",
    };
    if base == "haiku" && is_keystone_or_p0_floor(priority, tags_or_skills, title) {
        "sonnet"
    } else {
        base
    }
}

/// INFRA-8177: Upgrade `model` to `"sonnet"` if it is below the `sonnet` floor
/// (`haiku` / `flash`) on a `P0`/`critical` or `keystone`/`unwedge` gap.
pub fn enforce_routing_floor(
    model: &str,
    priority: &str,
    tags_or_skills: &str,
    title: &str,
) -> String {
    let trimmed = model.trim();
    let lower = trimmed.to_ascii_lowercase();
    let is_below_sonnet = lower == "haiku" || lower == "flash" || lower.contains("haiku");
    if is_below_sonnet && is_keystone_or_p0_floor(priority, tags_or_skills, title) {
        "sonnet".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Execute the user-provided work for a dispatch cycle. Variant-dispatched
/// per [`WorkBackend`].
fn do_work(ws: &Workspace) -> Result<()> {
    match &ws.opts().work {
        WorkBackend::Interactive => {
            // Caller already did the work; nothing to spawn.
            Ok(())
        }
        WorkBackend::Headless { model, prompt } => spawn_headless(ws, model, prompt),
        WorkBackend::ExecGap => spawn_exec_gap(ws),
        WorkBackend::Opencode { model, prompt } => spawn_opencode(ws, model, prompt),
        WorkBackend::Aider { model, prompt } => spawn_aider(ws, model, prompt),
        WorkBackend::Local { prompt } => spawn_local(ws, prompt),
    }
}

/// RESILIENT-203: opencode's project init/context-load does not scale to
/// the full Chump repo (746k LOC) — reproduced hanging deterministically at
/// `init` on BOTH `opencode-go/kimi-k2.7-code` and `opencode-go/deepseek-v4-pro`,
/// so it is model-independent, not a model-quality problem. Left unguarded,
/// `wait_with_hang_detection` burns its full timeout on every large-repo
/// dispatch before giving up. Fail fast instead by counting tracked files
/// before spawning; point the operator at `CHUMP_WORK_BACKEND=chump-local`
/// (the proven cheap-fleet path — native `chump --execute-gap` tools are
/// scoped to the worktree, not a repo-wide scan).
const OPENCODE_MAX_TRACKED_FILES: u64 = 5_000;

/// INFRA-2090 slice: default per-subagent token budget (in tokens) used by
/// the fleet dispatch cost-accounting path. Sub-agents spawned via
/// [`WorkBackend::Headless`] / `Agent`-tool dispatch are expected to stay
/// under this ceiling absent an explicit `subagent_token_budget` override.
/// This constant is the *default*; [`subagent_token_budget`] is the
/// resolved value once the `CHUMP_SUBAGENT_TOKEN_BUDGET` config key is
/// taken into account.
pub const CHOMP_SUBAGENT_TOKEN_BUDGET: u64 = 100_000;

/// Resolve the effective per-subagent token budget: `subagent_token_budget`
/// config key (via `CHUMP_SUBAGENT_TOKEN_BUDGET` env var) if set and
/// parseable, else [`CHOMP_SUBAGENT_TOKEN_BUDGET`].
pub fn subagent_token_budget() -> u64 {
    std::env::var("CHUMP_SUBAGENT_TOKEN_BUDGET")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(CHOMP_SUBAGENT_TOKEN_BUDGET)
}

/// INFRA-2090 slice: default per-subagent dollar budget (USD) used by the
/// fleet dispatch cost-accounting path. Sub-agents spawned via
/// [`WorkBackend::Headless`] / `Agent`-tool dispatch are expected to stay
/// under this ceiling absent an explicit `subagent_dollar_budget` override.
/// This constant is the *default*; [`subagent_dollar_budget`] is the
/// resolved value once the `CHUMP_SUBAGENT_DOLLAR_BUDGET` config key is
/// taken into account.
pub const CHOMP_SUBAGENT_DOLLAR_BUDGET: f64 = 5.0;

/// Resolve the effective per-subagent dollar budget: `subagent_dollar_budget`
/// config key (via `CHUMP_SUBAGENT_DOLLAR_BUDGET` env var) if set and
/// parseable, else [`CHOMP_SUBAGENT_DOLLAR_BUDGET`].
pub fn subagent_dollar_budget() -> f64 {
    std::env::var("CHUMP_SUBAGENT_DOLLAR_BUDGET")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(CHOMP_SUBAGENT_DOLLAR_BUDGET)
}

/// Count tracked files in `working_dir` and bail if the count exceeds the
/// threshold where opencode is known to hang at init. Returns `Ok(())`
/// (does not block) when the file count can't be determined — e.g. `git`
/// isn't available or `working_dir` isn't a git repo — since that's not the
/// condition this guard exists to catch.
fn opencode_repo_size_guard(working_dir: &Path) -> Result<()> {
    let max_files: u64 = std::env::var("CHUMP_OPENCODE_MAX_FILES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(OPENCODE_MAX_TRACKED_FILES);

    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(working_dir)
        .output();
    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return Ok(()),
    };
    let file_count = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .count() as u64;

    if file_count > max_files {
        bail!(
            "opencode repo-size guard (RESILIENT-203): {file_count} tracked files \
             in {} exceeds the {max_files}-file threshold where opencode's \
             init/context-load hangs deterministically (reproduced \
             model-independently on the 746k-LOC Chump repo). Use \
             CHUMP_WORK_BACKEND=chump-local instead.",
            working_dir.display()
        );
    }
    Ok(())
}

/// EFFECTIVE-017 — `WorkBackend::Opencode`.
fn spawn_opencode(ws: &Workspace, model: &str, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!(
            "WorkBackend::Opencode: prompt is empty (gap={})",
            opts.gap_id
        );
    }
    opencode_repo_size_guard(ws.working_dir())
        .with_context(|| format!("opencode repo-size guard for gap {}", opts.gap_id))?;
    let mut cmd = Command::new("opencode");
    cmd.arg("-p").arg(prompt).arg("--auto-approve");
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
    cmd.current_dir(ws.working_dir());
    // INFRA-8204: explicit, not merely inherited — see ship()'s comment.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    cmd.env("CHUMP_DISPATCH_GAP", opts.gap_id);
    // INFRA-8198: tie the child's lifetime to this dispatch process.
    configure_child_lifetime(&mut cmd);
    let child = cmd
        .spawn()
        .context("spawn `opencode -p` (is opencode CLI on PATH?)")?;
    let child_pid = child.id();
    ws.set_child_pid(child_pid);
    let mut group_guard = ChildGroupGuard::new(child_pid, opts.gap_id);
    let status =
        wait_with_hang_detection(child, "opencode -p", opts.gap_id, Some(ws.working_dir()))
            .context("waiting for opencode -p to complete")?;
    group_guard.release();
    if !status.success() {
        bail!(
            "opencode -p exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// EFFECTIVE-017 — `WorkBackend::Aider`.
fn spawn_aider(ws: &Workspace, model: &str, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!("WorkBackend::Aider: prompt is empty (gap={})", opts.gap_id);
    }
    let mut cmd = Command::new("aider");
    cmd.arg("--message").arg(prompt).arg("--yes");
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
    cmd.current_dir(ws.working_dir());
    // INFRA-8204: explicit, not merely inherited — see ship()'s comment.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    cmd.env("CHUMP_DISPATCH_GAP", opts.gap_id);
    // INFRA-8198: tie the child's lifetime to this dispatch process.
    configure_child_lifetime(&mut cmd);
    let child = cmd
        .spawn()
        .context("spawn `aider --message` (is aider on PATH?)")?;
    let child_pid = child.id();
    ws.set_child_pid(child_pid);
    let mut group_guard = ChildGroupGuard::new(child_pid, opts.gap_id);
    let status = wait_with_hang_detection(child, "aider", opts.gap_id, Some(ws.working_dir()))
        .context("waiting for aider --message to complete")?;
    group_guard.release();
    if !status.success() {
        bail!(
            "aider exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// INFRA-1964 — `WorkBackend::Local`. Spawns
/// `chump gen --local <prompt> --work-dir <ws> --quiet`, which drives the
/// existing offline-LLM agent loop (`src/gen.rs`) against whatever
/// OpenAI-compatible endpoint `OPENAI_API_BASE` points at (Ollama, an
/// MLX-server, mistral.rs, …) instead of the Anthropic-only `claude -p`
/// path. This is the fleet-worker seam the mission-reality critique (C1)
/// found missing: `WorkBackend::Headless` was the *only* backend actually
/// reachable from `chump dispatch` / `run-fleet.sh`, so every fleet worker
/// silently required an Anthropic credential no matter what
/// `CHUMP_WORK_BACKEND` claimed to support.
fn spawn_local(ws: &Workspace, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!("WorkBackend::Local: prompt is empty (gap={})", opts.gap_id);
    }
    let chump_bin = resolve_chump_binary(&opts.repo_root);
    let mut cmd = Command::new(chump_bin);
    cmd.args(["gen", prompt, "--local", "--work-dir"])
        .arg(ws.working_dir())
        // INFRA-302 blocker (3): cwd is the fresh worktree, same convention
        // as the other backends, even though `gen` also takes --work-dir
        // explicitly (gen resolves relative paths off cwd otherwise).
        .current_dir(ws.working_dir());
    // INFRA-8204: explicit, not merely inherited — see ship()'s comment.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    cmd.env("CHUMP_DISPATCH_GAP", opts.gap_id);
    // INFRA-8198: tie the child's lifetime to this dispatch process.
    configure_child_lifetime(&mut cmd);
    let child = cmd
        .spawn()
        .context("spawn `chump gen --local` (is chump on PATH / built?)")?;
    let child_pid = child.id();
    ws.set_child_pid(child_pid);
    let mut group_guard = ChildGroupGuard::new(child_pid, opts.gap_id);
    let status = wait_with_hang_detection(
        child,
        "chump gen --local",
        opts.gap_id,
        Some(ws.working_dir()),
    )
    .context("waiting for chump gen --local to complete")?;
    group_guard.release();
    if !status.success() {
        bail!(
            "chump gen --local exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// INFRA-8203: tools a headless agent must not have. ScheduleWakeup and
/// Monitor end the turn to wait for a later event; in `claude -p` no harness
/// delivers it, so the process exits with the work uncommitted.
const HEADLESS_DISALLOWED_TOOLS: &str = "ScheduleWakeup,Monitor";

/// INFRA-8203: appended to every headless `claude -p` prompt, whatever built
/// it (auto prompt, repair brief, operator `--prompt`).
const HEADLESS_EPILOGUE: &str = "\n\n## Headless run rules (INFRA-8203)\n\
- This is a headless `claude -p` run: ending your turn ENDS THE PROCESS and nothing will wake you. \
ScheduleWakeup and Monitor are disabled; never wait on a background task or end a turn while work is pending.\n\
- Wait synchronously: run the command in the foreground with a bounded timeout and read its result.\n\
- COMMIT before any wait longer than 60 seconds (git add + commit, gap id leading the subject), \
so a timeout or kill never strands your work.\n\
- Bound every local build or test with a wall-clock cap (for example `timeout 900 cargo clippy ...`); \
never start an unbounded build.\n";

/// The prompt actually written to a headless child's stdin.
fn headless_prompt(prompt: &str) -> String {
    format!("{prompt}{HEADLESS_EPILOGUE}")
}

/// Builds the argv/stdio skeleton for a `claude -p` headless invocation,
/// with no prompt, cwd, or credential env attached yet — split out from
/// [`spawn_headless`] purely so the arg-construction is unit-testable
/// without actually spawning a process (INFRA-3675).
///
/// INFRA-3675: the prompt is deliberately NEVER passed as a `-p <value>`
/// argv token here. Every dispatched prompt is prefixed with the
/// DISPATCH_RULES doc, whose YAML frontmatter starts with `---`; the claude
/// CLI's arg parser rejects a `-p` value beginning with `-` as an
/// unrecognized option ("error: unknown option '---...'"), which failed
/// 100% of headless dispatches in production. Reproduced + fixed by testing
/// directly against the claude binary: passing the same content via stdin
/// (with `-p` given no value) clears arg parsing cleanly — this is the
/// documented `cat file | claude -p` pattern. Callers must write the prompt
/// to `child.stdin` after spawning and close it (EOF) to signal completion.
/// CREDIBLE-1585 (PHASE-R): allowlist predicate for environment variables
/// passed into headless `claude -p` agent subprocesses.
///
/// Explicitly excludes database, cloud, billing, and service-role secrets
/// (`SUPABASE_SERVICE_ROLE_KEY`, `POSTGRES_PASSWORD`, `OCI_*`,
/// `AWS_SECRET_ACCESS_KEY`, `STRIPE_*`, `CHUMP_SUBSTRATE_DB_PASSWORD`, etc.).
pub fn is_allowlisted_headless_env_key(key: &str) -> bool {
    if matches!(
        key,
        "PATH"
            | "HOME"
            | "USER"
            | "LOGNAME"
            | "SHELL"
            | "LANG"
            | "LC_ALL"
            | "TERM"
            | "TMPDIR"
            | "CARGO_TARGET_DIR"
            | "CARGO_HOME"
            | "RUSTUP_HOME"
            | "ANTHROPIC_API_KEY"
            | "ANTHROPIC_DEFAULT_SONNET_MODEL"
            | "ANTHROPIC_DEFAULT_HAIKU_MODEL"
            | "ANTHROPIC_DEFAULT_OPUS_MODEL"
            | "CLAUDE_CODE_OAUTH_TOKEN"
            | "OPENAI_API_KEY"
            | "GEMINI_API_KEY"
            | "GOOGLE_API_KEY"
            | "OPENROUTER_API_KEY"
            | "GH_TOKEN"
            | "GITHUB_TOKEN"
            | "IS_SANDBOX"
            | "CLAUDE_SESSION_ID"
    ) {
        return true;
    }
    if key.starts_with("CHUMP_") {
        let upper = key.to_ascii_uppercase();
        if upper.contains("PASSWORD") || upper.contains("SECRET") || upper.contains("SERVICE_ROLE")
        {
            return false;
        }
        return true;
    }
    false
}

/// CREDIBLE-1585 (PHASE-R): clear the child `Command` environment and populate
/// only allowlisted variables from the parent environment.
pub fn scrub_headless_claude_env(cmd: &mut Command) {
    cmd.env_clear();
    for (k, v) in std::env::vars() {
        if is_allowlisted_headless_env_key(&k) {
            cmd.env(k, v);
        }
    }
}

fn headless_command_skeleton(model: &str) -> Command {
    let mut cmd = Command::new("claude");
    // CREDIBLE-1585: scrub non-allowlisted secrets from headless claude spawns.
    scrub_headless_claude_env(&mut cmd);
    cmd.arg("-p").arg("--dangerously-skip-permissions");
    // INFRA-8203: in `claude -p` nothing fires a wakeup — ending the turn
    // ends the process — so the tools that end a turn to "wait" are removed.
    // Probe on cuphead (claude 2.1.197): with this flag a haiku session lists
    // NONE for tools named *Wakeup*/*Monitor*; without it, both are listed.
    cmd.args(["--disallowedTools", HEADLESS_DISALLOWED_TOOLS]);
    // CREDIBLE-1581: disable all project hooks in headless `claude -p` runs so
    // PreToolUse/PostToolUse hooks (inbox-check-urgent.sh, ambient-context-inject.sh)
    // cannot inject unfiltered URGENT-INBOX or ambient text into fleet workers.
    cmd.args(["--settings", "{\"disableAllHooks\":true}"]);
    cmd.stdin(std::process::Stdio::piped());
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
    // RESILIENT-1642: always export the node-wide shared CARGO_TARGET_DIR into
    // the `claude -p` child so worktrees never grow private target/ dirs.
    cmd.env("CARGO_TARGET_DIR", resolve_shared_cargo_target_dir());
    // INFRA-8114 / RESILIENT-1494: populate CLAUDE_CODE_OAUTH_TOKEN from
    // ~/.chump/oauth-token.json when absent in caller env.
    ensure_oauth_token_env(Some(&mut cmd));
    cmd
}

/// Phase 2 — `WorkBackend::Headless`. Spawns
/// `claude -p --dangerously-skip-permissions [--model <model>]` with the
/// prompt written to stdin (see [`headless_command_skeleton`]), inherits
/// stdout/stderr so the operator sees progress inline, and waits for exit.
fn spawn_headless(ws: &Workspace, model: &str, prompt: &str) -> Result<()> {
    let opts = ws.opts();
    if prompt.trim().is_empty() {
        bail!(
            "WorkBackend::Headless: prompt is empty (gap={})",
            opts.gap_id
        );
    }
    let effective_model = chump_gap_store::GapStore::open(&opts.repo_root)
        .ok()
        .and_then(|s| s.get(opts.gap_id).ok().flatten())
        .map(|g| enforce_routing_floor(model, &g.priority, &g.skills_required, &g.title))
        .unwrap_or_else(|| model.to_string());
    let mut cmd = headless_command_skeleton(&effective_model);
    // RESILIENT-362: the claude CLI refuses `--dangerously-skip-permissions`
    // under root ("cannot be used with root/sudo privileges") unless IS_SANDBOX=1
    // marks an intentional sandboxed root env. Fleet root nodes (helsinki runs as
    // root) need this or EVERY headless dispatch aborts with claude -p exit 1.
    cmd.env("IS_SANDBOX", "1");
    // RESILIENT-1642: export the ZERO-WASTE-134 shared CARGO_TARGET_DIR into
    // the `claude -p` child environment at the spawn site.
    cmd.env("CARGO_TARGET_DIR", resolve_shared_cargo_target_dir());
    // Inherit env so spawned process sees CLAUDE_SESSION_ID / CHUMP_SESSION_ID
    // / lease metadata. Inherit stdio so the operator can see progress.
    // INFRA-302 blocker (3): cwd is the FRESH WORKTREE, NOT opts.repo_root —
    // see Workspace::new for the resolution.
    cmd.current_dir(ws.working_dir());
    // RESILIENT-057: validate-before-use — if the credential this spawn
    // would otherwise inherit is cached as recently dead (a prior spawn
    // already hit an auth rejection), switch to the fallback floor BEFORE
    // spawning instead of letting this worker rediscover it live.
    let active_auth = crate::auth::resolve_for_spawn(None);
    for (k, v) in active_auth.env_pairs() {
        cmd.env(k, v);
    }
    // INFRA-8114 / RESILIENT-1494: ensure CLAUDE_CODE_OAUTH_TOKEN is sourced
    // from ~/.chump/oauth-token.json when absent in caller env.
    ensure_oauth_token_env(Some(&mut cmd));
    // INFRA-8204: explicit, not merely inherited — see ship()'s comment.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    // CREDIBLE-1566: export CHUMP_DISPATCH_GAP so git hooks refuse bypasses inside dispatch.
    // scanner-anchor: "kind":"agent_bypass_refused" (CREDIBLE-1566, emitted by scripts/git-hooks/{pre-push,commit-msg})
    cmd.env("CHUMP_DISPATCH_GAP", opts.gap_id);
    // ZERO-WASTE-133: bound every agent tool call. Background tasks off so a
    // call that hits its timeout is killed (not auto-backgrounded) and the
    // agent reads the error and continues; see dispatch_tool_watch.rs.
    for (k, v) in tool_watch::headless_tool_timeout_env(tool_watch::tool_call_timeout_secs()) {
        cmd.env(k, v);
    }
    // INFRA-8198: tie the child's lifetime to this dispatch process — the
    // exact gap this whole gap closes: a `claude -p` headless child that
    // outlived its 1800s budget with no lease, ship phase, or supervisor.
    configure_child_lifetime(&mut cmd);
    // INFRA-8219: node-wide admission ceiling (ports RESILIENT-1604). Bounded,
    // fail-open wait so independent spawn sites don't pile `claude -p` children
    // past CHUMP_MAX_CONCURRENT_CLAUDE on a small node; proceeds anyway if the
    // ceiling never clears (a stuck gate is worse than a busy node).
    crate::admit::gate_before_spawn(
        crate::admit::Resource::Claude,
        &crate::repo_path::repo_root(),
    );
    let mut child = cmd
        .spawn()
        .context("spawn `claude -p` (is the claude CLI on PATH?)")?;
    let child_pid = child.id();
    ws.set_child_pid(child_pid);
    let mut group_guard = ChildGroupGuard::new(child_pid, opts.gap_id);
    {
        use std::io::Write as _;
        let mut stdin = child
            .stdin
            .take()
            .context("claude -p stdin was not piped")?;
        stdin
            .write_all(headless_prompt(prompt).as_bytes())
            .context("writing prompt to claude -p stdin")?;
        // Dropping `stdin` here closes the pipe (EOF), which is how `claude
        // -p` knows the prompt is complete and starts working.
    }
    let status = wait_with_hang_detection(child, "claude -p", opts.gap_id, Some(ws.working_dir()))
        .context("waiting for claude -p to complete")?;
    group_guard.release();
    if !status.success() {
        bail!(
            "claude -p exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// Phase 2 — `WorkBackend::ExecGap`. Spawns `chump --execute-gap <ID>` (the
/// chump-local backend introduced in COG-025). Same stdio + env inheritance
/// as headless. Resolves the chump binary by trying common install paths
/// before falling back to PATH lookup; this avoids needing $HOME/.local/bin
/// in PATH at every callsite (parallel to INFRA-231's overnight wrapper fix).
fn spawn_exec_gap(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // Resolve binary against repo_root (binary lives under
    // `<repo_root>/target/...`, NOT under the worktree's target/).
    let chump_bin = resolve_chump_binary(&opts.repo_root);
    let mut cmd = Command::new(chump_bin);
    cmd.args(["--execute-gap", opts.gap_id])
        // INFRA-302 blocker (3): cwd is the FRESH WORKTREE so the
        // dispatched child commits + ships from the gap's own branch,
        // not from whatever was checked out in the main repo when the
        // operator typed `chump dispatch …`.
        .current_dir(ws.working_dir());
    // INFRA-8204: explicit, not merely inherited — see ship()'s comment.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    cmd.env("CHUMP_DISPATCH_GAP", opts.gap_id);
    // INFRA-8198: tie the child's lifetime to this dispatch process.
    configure_child_lifetime(&mut cmd);
    let child = cmd
        .spawn()
        .with_context(|| format!("spawn `chump --execute-gap {}`", opts.gap_id))?;
    let child_pid = child.id();
    ws.set_child_pid(child_pid);
    let mut group_guard = ChildGroupGuard::new(child_pid, opts.gap_id);
    let status = wait_with_hang_detection(
        child,
        "chump --execute-gap",
        opts.gap_id,
        Some(ws.working_dir()),
    )
    .context("waiting for chump --execute-gap to complete")?;
    group_guard.release();
    if !status.success() {
        bail!(
            "chump --execute-gap exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// Tuning for [`wait_with_hang_detection`], split out (RESILIENT-1612) so the
/// loop can be driven in tests with second-scale values instead of the
/// production 900s/3600s deadlines, without mutating process env.
struct HangConfig {
    /// CHUMP_SUBAGENT_BUDGET_S / CHUMP_DISPATCH_TIMEOUT_SECS (legacy
    /// CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S), effort-scaled (default >= 1800s).
    /// Wall-clock (paused while 1m load > nproc); 0 disables.
    budget_secs: u64,
    /// CHUMP_DISPATCH_HANG_TIMEOUT_SECS, default 3600. IDLE time (no observed
    /// worktree activity), not wall-clock since spawn; 0 disables.
    hang_secs: u64,
    /// CHUMP_DISPATCH_ACTIVITY_POLL_SECS, default 20 (clamped to >= 1): how
    /// often the worktree is re-fingerprinted for activity.
    activity_poll: Duration,
    /// How often the child is polled for exit.
    tick: Duration,
    /// SIGTERM → SIGKILL grace window for the budget and salvage kill paths.
    grace_secs: u64,
    /// ZERO-WASTE-133: age past which one agent tool call is stalled
    /// (derived from CHUMP_DISPATCH_TOOL_CALL_TIMEOUT_SECS); 0 disables.
    tool_stall_secs: u64,
    /// RESILIENT-1494: returns true when the 1-minute load average exceeds
    /// `nproc`, pausing the budget clock while the host is CPU-saturated.
    load_paused_probe: Option<fn() -> bool>,
}

impl HangConfig {
    fn from_env() -> Self {
        let budget_secs: u64 = resolve_subagent_budget_secs(None);
        let hang_secs: u64 = std::env::var("CHUMP_DISPATCH_HANG_TIMEOUT_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(3600);
        let poll_secs: u64 = std::env::var("CHUMP_DISPATCH_ACTIVITY_POLL_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(20)
            .max(1);
        HangConfig {
            budget_secs,
            hang_secs,
            activity_poll: Duration::from_secs(poll_secs),
            tick: Duration::from_secs(1),
            grace_secs: 30,
            tool_stall_secs: tool_watch::stall_threshold_secs(tool_watch::tool_call_timeout_secs()),
            // Enable host load pause on real dispatch budgets (>= 60s) so short
            // synthetic 3s smoke tests don't block on busy CI runners.
            load_paused_probe: (budget_secs >= 60)
                .then_some(host_load_exceeds_nproc as fn() -> bool),
        }
    }
}

/// What the hang/budget loop reports. Production routes these to ambient
/// emitters; tests collect them.
#[derive(Debug, Clone, PartialEq)]
enum HangEvent {
    /// No activity source could be read: the hang detector is disabled for
    /// this dispatch instead of firing at start+timeout (RESILIENT-1612 AC2).
    Blind { reason: String },
    /// Parent-enforced wall-clock budget exceeded (INFRA-1972).
    BudgetKill { pid: u32 },
    /// No worktree activity for `idle_secs`. `committed` = the worktree's
    /// HEAD moved since spawn, in which case the child is stopped and the
    /// dispatch proceeds to its ship step instead of aborting.
    HangKill { idle_secs: u64, committed: bool },
    /// ZERO-WASTE-133: one agent tool call outlived every timeout the
    /// harness allows; its subtree was killed so the agent continues.
    ToolCallStalled {
        pid: u32,
        age_secs: u64,
        cmd: String,
    },
}

/// Directory names never walked when fingerprinting a worktree for activity:
/// build output (cargo writes there continuously during a build that may
/// itself be hung), git internals (probed explicitly below instead),
/// vendored deps, and lease/heartbeat state that other processes touch.
const ACTIVITY_EXCLUDED_DIRS: &[&str] = &[
    "target",
    ".git",
    "node_modules",
    ".chump-locks",
    ".cargo-build-target",
];

/// Upper bound on entries visited per fingerprint so a pathological tree
/// cannot turn a 20s poll into a multi-second stall.
const ACTIVITY_MAX_ENTRIES: usize = 400_000;

/// RESILIENT-1612: the activity signal for the dispatch hang detector.
///
/// The old detector compared wall-clock time since spawn against the
/// timeout and read no activity signal at all, so it fired at exactly
/// start+timeout even when the agent had edited and committed minutes
/// earlier (receipt: RESILIENT-1610 dispatch, commit 02:33:38Z, killed
/// 02:40:27Z = start+1200s). `claude -p` in this invocation prints no
/// stream-json, so there is no tool_use marker to read; the cheapest robust
/// signal is the worktree itself: file mtimes (excluding
/// [`ACTIVITY_EXCLUDED_DIRS`]) plus the worktree's git index, HEAD, and HEAD
/// reflog, so a `git add` or `git commit` counts as activity.
struct ActivityProbe {
    root: PathBuf,
    git_files: Vec<PathBuf>,
}

/// (wrapping sum of mtimes in ns, max mtime in ns, entry count). Any file
/// write, creation, or deletion changes at least one component.
type ActivityFingerprint = (u128, u128, u64);

impl ActivityProbe {
    /// `None` when `root` is not a readable directory (→ detector blind).
    fn new(root: &Path) -> Option<Self> {
        if !root.is_dir() {
            return None;
        }
        let git_files = resolve_git_dir(root)
            .map(|g| vec![g.join("index"), g.join("HEAD"), g.join("logs").join("HEAD")])
            .unwrap_or_default();
        Some(ActivityProbe {
            root: root.to_path_buf(),
            git_files,
        })
    }

    /// `None` when the root itself cannot be listed.
    fn fingerprint(&self) -> Option<ActivityFingerprint> {
        let mut sum: u128 = 0;
        let mut max: u128 = 0;
        let mut count: u64 = 0;
        let mut fold = |md: &std::fs::Metadata| {
            let ns = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            sum = sum.wrapping_add(ns);
            max = max.max(ns);
            count += 1;
        };
        // The root must be listable, or the probe is blind.
        let root_iter = std::fs::read_dir(&self.root).ok()?;
        let mut stack: Vec<std::fs::ReadDir> = vec![root_iter];
        let mut visited = 0usize;
        while let Some(iter) = stack.last_mut() {
            let Some(entry) = iter.next() else {
                stack.pop();
                continue;
            };
            visited += 1;
            if visited > ACTIVITY_MAX_ENTRIES {
                break;
            }
            let Ok(entry) = entry else { continue };
            // symlink_metadata: never follow links (the dispatch worktree's
            // state.db is a symlink into the main checkout, whose mtime moves
            // with every other agent's writes).
            let Ok(md) = std::fs::symlink_metadata(entry.path()) else {
                continue;
            };
            if md.is_dir() {
                let name = entry.file_name();
                let skip = name
                    .to_str()
                    .is_some_and(|n| ACTIVITY_EXCLUDED_DIRS.contains(&n));
                if !skip {
                    if let Ok(sub) = std::fs::read_dir(entry.path()) {
                        stack.push(sub);
                    }
                }
                continue;
            }
            fold(&md);
        }
        for f in &self.git_files {
            if let Ok(md) = std::fs::metadata(f) {
                fold(&md);
            }
        }
        Some((sum, max, count))
    }
}

/// Resolve a worktree's git dir: `<root>/.git` when it is a directory, or
/// the `gitdir: <path>` target when it is a linked-worktree pointer file.
fn resolve_git_dir(root: &Path) -> Option<PathBuf> {
    let dot_git = root.join(".git");
    if dot_git.is_dir() {
        return Some(dot_git);
    }
    let text = std::fs::read_to_string(&dot_git).ok()?;
    let rel = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
    let p = PathBuf::from(rel);
    Some(if p.is_absolute() { p } else { root.join(p) })
}

/// Current `HEAD` commit of the worktree at `root`, if it is a git checkout.
fn worktree_head(root: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "--verify", "-q", "HEAD"])
        .current_dir(root)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

/// Wait for a child process with hang detection (INFRA-406, RESILIENT-1612).
///
/// `activity_root` is the directory the child works in (the dispatch
/// worktree). The hang timeout (CHUMP_DISPATCH_HANG_TIMEOUT_SECS, default
/// 3600, 0 disables) is measured as IDLE time: the clock resets whenever the
/// worktree fingerprint changes ([`ActivityProbe`]). With no readable
/// activity root the detector logs `kind=dispatch_hang_detector_blind` and
/// stays off rather than firing at start+timeout. If the idle timeout fires
/// after the child has committed, the child is stopped and this returns a
/// success status so the dispatch still runs its ship step.
fn wait_with_hang_detection(
    child: Child,
    process_name: &str,
    gap_id: &str,
    activity_root: Option<&Path>,
) -> Result<std::process::ExitStatus> {
    let cfg = HangConfig::from_env();
    let mut sink = |ev: HangEvent| match ev {
        HangEvent::Blind { reason } => {
            emit_hang_detector_blind(process_name, gap_id, cfg.hang_secs, &reason)
        }
        HangEvent::BudgetKill { pid } => {
            emit_subagent_killed_at_budget(process_name, gap_id, cfg.budget_secs, pid)
        }
        HangEvent::HangKill {
            idle_secs,
            committed,
        } => emit_hang_alert(process_name, gap_id, cfg.hang_secs, idle_secs, committed),
        HangEvent::ToolCallStalled { pid, age_secs, cmd } => emit_tool_call_stalled(
            process_name,
            gap_id,
            cfg.tool_stall_secs,
            pid,
            age_secs,
            &cmd,
        ),
    };
    wait_with_hang_detection_cfg(child, process_name, gap_id, activity_root, &cfg, &mut sink)
}

fn wait_with_hang_detection_cfg(
    mut child: Child,
    process_name: &str,
    gap_id: &str,
    activity_root: Option<&Path>,
    cfg: &HangConfig,
    on_event: &mut dyn FnMut(HangEvent),
) -> Result<std::process::ExitStatus> {
    // Two cooperating deadlines:
    //   1. SUBAGENT BUDGET (CHUMP_SUBAGENT_BUDGET_S, default 900s):
    //      parent-enforced upper bound on wall-clock per subagent dispatch.
    //      INFRA-1972 (critique H3): CLAUDE.md documents this as a
    //      "self-discipline rule" for the subagent itself, but yesterday's
    //      ci-audit + md-links dispatches burned 144K + 157K tokens past
    //      budget without self-honoring it. This is the parent-side hard
    //      enforcement that didn't exist before. On exceed: SIGTERM, then
    //      30s grace, then SIGKILL. Emits kind=subagent_killed_at_budget.
    //   2. HANG TIMEOUT (CHUMP_DISPATCH_HANG_TIMEOUT_SECS, default 3600s):
    //      IDLE deadline (RESILIENT-1612) — fires only after that long with
    //      no worktree activity. SIGKILL. Emits kind=hang_detector.
    //
    // Either set to 0 disables that specific deadline.
    let no_budget = cfg.budget_secs == 0;
    let mut hang_enabled = cfg.hang_secs != 0;
    if no_budget && !hang_enabled && cfg.tool_stall_secs == 0 {
        return child.wait().context("waiting for child process");
    }

    let start = std::time::Instant::now();
    let child_pid = child.id();
    let mut budget_kill_in_flight: Option<std::time::Instant> = None;

    // RESILIENT-1612: activity source. Blind → detector off, loudly.
    let probe = activity_root.and_then(ActivityProbe::new);
    let mut last_fp = probe.as_ref().and_then(|p| p.fingerprint());
    if hang_enabled && last_fp.is_none() {
        let reason = match activity_root {
            None => "no activity root (no worktree for this backend)".to_string(),
            Some(p) => format!("activity root unreadable: {}", p.display()),
        };
        eprintln!(
            "[dispatch] {gap_id}: hang detector blind ({reason}); \
             not enforcing the {}s idle timeout",
            cfg.hang_secs
        );
        on_event(HangEvent::Blind { reason });
        hang_enabled = false;
    }
    let head_at_start = if hang_enabled {
        activity_root.and_then(worktree_head)
    } else {
        None
    };
    let mut last_activity = start;
    let mut last_poll = start;
    let mut last_tool_poll = start;
    let mut stalled_reported: Vec<u32> = Vec::new();
    let mut budget_elapsed = Duration::ZERO;
    let mut last_budget_tick = start;

    // Re-fingerprint; true (and clock reset) when the worktree changed.
    let refresh = |last_fp: &mut Option<ActivityFingerprint>,
                   last_activity: &mut std::time::Instant|
     -> bool {
        let Some(fp) = probe.as_ref().and_then(|p| p.fingerprint()) else {
            return false; // transient unreadability: not activity
        };
        if Some(fp) != *last_fp {
            *last_fp = Some(fp);
            *last_activity = std::time::Instant::now();
            return true;
        }
        false
    };

    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {
                let now = std::time::Instant::now();
                let tick_delta = now.saturating_duration_since(last_budget_tick);
                last_budget_tick = now;
                let load_paused = cfg.load_paused_probe.map(|probe| probe()).unwrap_or(false);
                if !load_paused {
                    budget_elapsed += tick_delta;
                }

                // Budget enforcement (faster, graceful)
                if !no_budget
                    && budget_kill_in_flight.is_none()
                    && budget_elapsed.as_secs() > cfg.budget_secs
                {
                    on_event(HangEvent::BudgetKill { pid: child_pid });
                    // RESILIENT-1494: before sending SIGTERM on budget kill,
                    // commit any dirty/staged work with a `wip:` subject, push
                    // it to `origin refs/stash/<gap>-<ts>`, and append an entry
                    // to `docs/process/STASHED_WORK.md`.
                    if let Some(root) = activity_root {
                        let _ = salvage_wip_before_budget_kill(root, gap_id);
                    }
                    // INFRA-8198: signal the whole GROUP (negative pgid),
                    // not just the direct child pid — `configure_child_lifetime`
                    // made the child its own process-group leader, so this
                    // also reaches any subprocess it spawned (cargo, git,
                    // …) that would otherwise survive the direct-pid kill.
                    kill_process_group(child_pid, libc::SIGTERM);
                    budget_kill_in_flight = Some(std::time::Instant::now());
                }

                // After SIGTERM, allow `grace_secs` for graceful shutdown
                // before SIGKILL. INFRA-1972 AC: "at budget_secs + 30s: SIGKILL".
                if let Some(term_at) = budget_kill_in_flight {
                    if term_at.elapsed().as_secs() > cfg.grace_secs {
                        kill_process_group(child_pid, libc::SIGKILL);
                        let _ = child.wait();
                        bail!(
                            "{} exceeded subagent budget ({} secs) for gap {}; SIGTERM at budget, \
                             SIGKILL after {}s grace",
                            process_name,
                            cfg.budget_secs,
                            gap_id,
                            cfg.grace_secs
                        );
                    }
                }

                if hang_enabled && last_poll.elapsed() >= cfg.activity_poll {
                    last_poll = std::time::Instant::now();
                    refresh(&mut last_fp, &mut last_activity);
                }

                // ZERO-WASTE-133: stalled tool-call watchdog. Reported once
                // per call; the call's subtree is killed so the agent gets an
                // error for that one call and keeps working.
                if cfg.tool_stall_secs > 0 && last_tool_poll.elapsed() >= cfg.activity_poll {
                    last_tool_poll = std::time::Instant::now();
                    let procs = tool_watch::ps_snapshot();
                    for st in tool_watch::find_stalled(&procs, child_pid, cfg.tool_stall_secs) {
                        if stalled_reported.contains(&st.pid) {
                            continue;
                        }
                        stalled_reported.push(st.pid);
                        eprintln!(
                            "[dispatch] {gap_id}: tool call pid {} alive {}s (limit {}s), killing: {}",
                            st.pid, st.age_secs, cfg.tool_stall_secs, st.cmd
                        );
                        tool_watch::kill_subtree(&st.subtree);
                        on_event(HangEvent::ToolCallStalled {
                            pid: st.pid,
                            age_secs: st.age_secs,
                            cmd: st.cmd,
                        });
                    }
                }

                // Idle hang detector (RESILIENT-1612): fires on no ACTIVITY
                // for hang_secs, not on wall-clock since spawn. One fresh
                // probe first, since the last poll may be up to
                // activity_poll stale.
                if hang_enabled
                    && last_activity.elapsed() > Duration::from_secs(cfg.hang_secs)
                    && !refresh(&mut last_fp, &mut last_activity)
                {
                    let idle_secs = last_activity.elapsed().as_secs();
                    let committed = head_at_start.is_some()
                        && activity_root.and_then(worktree_head) != head_at_start;
                    on_event(HangEvent::HangKill {
                        idle_secs,
                        committed,
                    });
                    if committed {
                        // The agent committed and then went quiet: its work
                        // is finished. Stop it (gracefully first) and let the
                        // dispatch ship what it committed instead of
                        // aborting the ship step (RESILIENT-1612 AC3).
                        eprintln!(
                            "[dispatch] {gap_id}: {process_name} idle {idle_secs}s after \
                             committing; stopping it and proceeding to ship"
                        );
                        kill_process_group(child_pid, libc::SIGTERM);
                        let term_at = std::time::Instant::now();
                        while term_at.elapsed().as_secs() <= cfg.grace_secs {
                            if let Ok(Some(_)) = child.try_wait() {
                                break;
                            }
                            std::thread::sleep(Duration::from_millis(200));
                        }
                        kill_process_group(child_pid, libc::SIGKILL);
                        let _ = child.wait();
                        use std::os::unix::process::ExitStatusExt as _;
                        return Ok(std::process::ExitStatus::from_raw(0));
                    }
                    kill_child_process_group(&mut child);
                    bail!(
                        "{} showed no worktree activity for {} secs (hang timeout {} secs) \
                         for gap {}; sent SIGKILL",
                        process_name,
                        idle_secs,
                        cfg.hang_secs,
                        gap_id
                    );
                }
                std::thread::sleep(cfg.tick);
            }
            Err(e) => return Err(e).context("checking child process status"),
        }
    }
}

/// Emit `kind=subagent_killed_at_budget` to ambient.jsonl (INFRA-1972, H3).
/// Distinct from `kind=hang_detector` — this is the parent-enforced subagent
/// budget exceed; hang_detector is the longer fall-through wall-clock guard.
fn emit_subagent_killed_at_budget(
    process_name: &str,
    gap_id: &str,
    budget_secs: u64,
    child_pid: u32,
) {
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

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"subagent_killed_at_budget\",\"kind\":\"subagent_killed_at_budget\",\
         \"process\":\"{process_name}\",\"gap\":\"{gap_id}\",\"pid\":{child_pid},\
         \"budget_secs\":{budget_secs}}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }

    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("subagent_killed_at_budget")
            .arg(format!("process={}", process_name))
            .arg(format!("gap={}", gap_id))
            .arg(format!("pid={}", child_pid))
            .arg(format!("budget_secs={}", budget_secs))
            .status();
    }
}

/// CREDIBLE-1506: fields of one `kind=dispatch_exit` emit, bundled so the
/// emitter stays under clippy's argument ceiling (the `status` field added
/// here pushed the old positional signature to 8 args).
struct DispatchExitEvent<'a> {
    gap_id: &'a str,
    session_id: &'a str,
    exit_code: i32,
    /// Stable outcome token: shipped | armed | blocked | failed.
    status: &'a str,
    reason: &'a str,
    child_pid: u32,
    child_alive_at_exit: bool,
    duration_s: u64,
}

// scanner-anchor: "kind":"dispatch_exit"
/// Emit `kind=dispatch_exit` to ambient.jsonl (INFRA-8198). Mirrors
/// [`emit_subagent_killed_at_budget`]'s append pattern. [`run`] emits
/// exactly one of these per dispatch cycle, on every exit path — this is
/// the fix for the bug where a dispatch could exit 0 (or hard-fail) with no
/// line distinguishing "child reaped cleanly" from "child still running
/// unsupervised" (the INFRA-8198 repro: preflight printed, dispatch exited
/// 0, the `claude -p` child kept running with PPID 1 for 25+ minutes).
fn emit_dispatch_exit(ev: DispatchExitEvent) {
    let DispatchExitEvent {
        gap_id,
        session_id,
        exit_code,
        status,
        reason,
        child_pid,
        child_alive_at_exit,
        duration_s,
    } = ev;
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = if session_id.is_empty() {
        crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string())
    } else {
        session_id.to_string()
    };

    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let reason_escaped = reason.replace('\\', "\\\\").replace('"', "\\\"");

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"dispatch_exit\",\"session\":\"{session}\",\
         \"gap_id\":\"{gap_id}\",\"exit_code\":{exit_code},\"status\":\"{status}\",\
         \"reason\":\"{reason_escaped}\",\
         \"child_pid\":{child_pid},\"child_alive_at_exit\":{child_alive_at_exit},\
         \"duration_s\":{duration_s}}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }

    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("dispatch_exit")
            .arg(format!("gap_id={}", gap_id))
            .arg(format!("exit_code={}", exit_code))
            .arg(format!("status={}", status))
            .arg(format!("child_pid={}", child_pid))
            .arg(format!("child_alive_at_exit={}", child_alive_at_exit))
            .status();
    }
}

/// AC1 (INFRA-8198): make every spawned work-child's lifetime tied to this
/// `chump dispatch` process. Two layers: (1) `process_group(0)` makes the
/// child the leader of its own process group so cargo/git grandchildren it
/// spawns share that group and can be killed together (see
/// [`ChildGroupGuard`] and the budget/hang kill paths in
/// [`wait_with_hang_detection`]); (2) on Linux, `PR_SET_PDEATHSIG` is a
/// kernel-enforced backstop that fires even if dispatch is SIGKILLed or
/// calls `std::process::exit` (which skips Rust's `Drop` entirely, so
/// `ChildGroupGuard` alone cannot cover that case — this is the exact
/// mechanism gap the INFRA-8198 bug report calls out).
#[cfg(unix)]
fn configure_child_lifetime(cmd: &mut Command) {
    use std::os::unix::process::CommandExt;
    cmd.process_group(0);
    #[cfg(target_os = "linux")]
    {
        // SAFETY: `pre_exec` itself is `unsafe` only because the closure
        // runs in the forked child between `fork()` and `exec()`, where very
        // few operations are safe (no allocation, no locking). `prctl` is
        // safe to call unconditionally in that window.
        unsafe {
            cmd.pre_exec(|| {
                // SAFETY: PR_SET_PDEATHSIG with SIGTERM only arms a
                // kernel-delivered signal for when our parent (this `chump
                // dispatch` process) exits; it has no other side effect.
                // Already inside the enclosing `unsafe` block above (unsafe
                // is lexical, not runtime-scoped, so it covers this closure
                // body too) — no nested `unsafe` needed here.
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
    }
}

#[cfg(not(unix))]
fn configure_child_lifetime(_cmd: &mut Command) {}

/// RAII guard that kills a spawned work-child's entire process group (see
/// [`configure_child_lifetime`]) unless [`ChildGroupGuard::release`] was
/// called first. Catches exit paths that skip explicit cleanup — an early
/// `?`-propagated error out of a `spawn_*` function, a panic, or any other
/// return path that doesn't reach a hand-written kill call. `PR_SET_PDEATHSIG`
/// (Linux-only) is the backstop for the case this guard's own `Drop` cannot
/// cover: `std::process::exit` or a SIGKILL of the dispatch process itself.
#[cfg(unix)]
struct ChildGroupGuard {
    /// Equal to `pid`: [`configure_child_lifetime`] makes the child the
    /// leader of its own process group (`process_group(0)`), so its pgid
    /// is its own pid.
    pgid: u32,
    pid: u32,
    gap: String,
    released: bool,
}

#[cfg(unix)]
impl ChildGroupGuard {
    fn new(pid: u32, gap: &str) -> Self {
        Self {
            pgid: pid,
            pid,
            gap: gap.to_string(),
            released: false,
        }
    }

    /// Mark the child as having exited on its own via a normal `wait()` —
    /// `Drop` becomes a no-op.
    fn release(&mut self) {
        self.released = true;
    }

    fn signal_group(&self, sig: libc::c_int) {
        // SAFETY: `pgid` is the process group chump dispatch itself created
        // for this child via `process_group(0)`; signaling `-pgid` can only
        // reach that group, never an unrelated one it doesn't own.
        unsafe {
            libc::kill(-(self.pgid as libc::pid_t), sig);
        }
    }
}

#[cfg(unix)]
impl Drop for ChildGroupGuard {
    fn drop(&mut self) {
        if self.released {
            return;
        }
        eprintln!(
            "[dispatch] {} ChildGroupGuard: killing orphaned process group pgid={} (pid={})",
            self.gap, self.pgid, self.pid
        );
        self.signal_group(libc::SIGTERM);
        let start = std::time::Instant::now();
        while start.elapsed().as_secs() < 10 {
            if !child_is_alive(self.pid) {
                return;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        self.signal_group(libc::SIGKILL);
    }
}

#[cfg(not(unix))]
struct ChildGroupGuard;

#[cfg(not(unix))]
impl ChildGroupGuard {
    fn new(_pid: u32, _gap: &str) -> Self {
        Self
    }
    fn release(&mut self) {}
}

/// Emit a hang-detection alert to ambient.jsonl (INFRA-406). RESILIENT-1612
/// adds `idle_secs` (time since the last observed worktree activity) and
/// `committed` (HEAD moved since spawn → the dispatch proceeds to ship).
fn emit_hang_alert(
    process_name: &str,
    gap_id: &str,
    timeout_secs: u64,
    idle_secs: u64,
    committed: bool,
) {
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

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"worktree\":\"{worktree}\",\
         \"event\":\"hang_detected\",\"kind\":\"hang_detector\",\"process\":\"{process_name}\",\
         \"gap\":\"{gap_id}\",\"timeout_secs\":{timeout_secs},\"idle_secs\":{idle_secs},\
         \"committed\":{committed}}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }

    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("hang_detected")
            .arg(format!("process={}", process_name))
            .arg(format!("gap={}", gap_id))
            .arg(format!("timeout_secs={}", timeout_secs))
            .env("CHUMP_SESSION_ID", &session)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// ZERO-WASTE-133: emit `kind=agent_tool_call_stalled` when one agent tool
/// call outlived every timeout the harness allows and the watchdog killed it.
fn emit_tool_call_stalled(
    process_name: &str,
    gap_id: &str,
    limit_secs: u64,
    pid: u32,
    age_secs: u64,
    cmd: &str,
) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let cmd = serde_json::to_string(cmd).unwrap_or_else(|_| "\"\"".to_string());
    // scanner anchor: "kind":"agent_tool_call_stalled"
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"agent_tool_call_stalled\",\
         \"process\":\"{process_name}\",\"gap\":\"{gap_id}\",\"pid\":{pid},\
         \"age_secs\":{age_secs},\"limit_secs\":{limit_secs},\"action\":\"killed\",\"cmd\":{cmd}}}"
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

/// RESILIENT-1612: emit `kind=dispatch_hang_detector_blind` when the hang
/// detector has no readable activity source for a dispatch and therefore
/// stays off (rather than firing at start+timeout on a child it cannot see).
fn emit_hang_detector_blind(process_name: &str, gap_id: &str, timeout_secs: u64, reason: &str) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let reason = reason.replace('\\', "\\\\").replace('"', "\\\"");
    // scanner anchor: "kind":"dispatch_hang_detector_blind"
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"dispatch_hang_detector_blind\",\
         \"process\":\"{process_name}\",\"gap\":\"{gap_id}\",\"timeout_secs\":{timeout_secs},\
         \"reason\":\"{reason}\"}}"
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

/// INFRA-8203: stranded-work detector (dirty worktree, no commit).
#[path = "dispatch_stranded.rs"]
mod stranded;

/// INFRA-8203: run the stranded-work check for a dispatch that owns a fresh
/// worktree (never for Interactive, which works in the caller's checkout,
/// and never in review-only mode, which ships nothing). Emits
/// `kind=dispatch_work_stranded` when it fires.
fn detect_stranded_work(ws: &Workspace) -> Option<stranded::Stranded> {
    let opts = ws.opts();
    if matches!(opts.work, WorkBackend::Interactive) {
        return None;
    }
    // A repair worktree starts at the PR head, so "no new commit" is
    // measured against that branch rather than origin/main.
    let base = match &opts.mode {
        DispatchMode::Work => "origin/main".to_string(),
        DispatchMode::Repair { head_branch } => format!("origin/{head_branch}"),
        DispatchMode::ReviewOnly => return None,
    };
    match stranded::check_and_save(
        ws.working_dir(),
        opts.gap_id,
        &base,
        &stranded::dispatch_logs_dir(),
    ) {
        Ok(Some(s)) => {
            eprintln!(
                "[dispatch] {}: work stranded ({} uncommitted path(s), no commit above \
                 origin/main); patch saved to {}",
                opts.gap_id,
                s.files,
                s.patch_path.display()
            );
            emit_dispatch_work_stranded(opts.gap_id, &s);
            Some(s)
        }
        Ok(None) => None,
        Err(e) => {
            eprintln!(
                "[dispatch] {}: INFRA-8203 stranded-work check failed: {e}",
                opts.gap_id
            );
            None
        }
    }
}

/// INFRA-8203: emit `kind=dispatch_work_stranded`.
fn emit_dispatch_work_stranded(gap_id: &str, s: &stranded::Stranded) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let stat: String = s.diffstat.chars().take(2000).collect();
    let stat = serde_json::to_string(&stat).unwrap_or_else(|_| "\"\"".to_string());
    let patch = serde_json::to_string(&s.patch_path.display().to_string())
        .unwrap_or_else(|_| "\"\"".to_string());
    // scanner anchor: "kind":"dispatch_work_stranded"
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"dispatch_work_stranded\",\
         \"gap\":\"{gap_id}\",\"files\":{},\"diffstat\":{stat},\"patch\":{patch}}}",
        s.files
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

/// Find the `chump` binary. Tries the in-tree `target/release` and
/// `target/debug` first (so `chump dispatch` always re-uses the same binary
/// the user is invoking), then `$HOME/.local/bin/chump` (the cargo-install
/// default), then bare `chump` (relying on PATH).
fn resolve_chump_binary(repo_root: &Path) -> PathBuf {
    for candidate in [
        repo_root.join("target/release/chump"),
        repo_root.join("target/debug/chump"),
    ] {
        if candidate.exists() {
            return candidate;
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let dot_local = PathBuf::from(home).join(".local/bin/chump");
        if dot_local.exists() {
            return dot_local;
        }
    }
    PathBuf::from("chump")
}

fn current_branch(repo_root: &Path) -> Result<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .context("git rev-parse --abbrev-ref")?;
    if !out.status.success() {
        bail!(
            "git rev-parse failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn preflight(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // INFRA-987 completion: scripts/coord/gap-preflight.sh was deleted (#2014) in
    // favor of the `chump gap preflight` subcommand. worker.sh migrated (INFRA-379)
    // but this dispatch caller was missed, so a fresh install (no gap-preflight.sh)
    // failed here with "gap-preflight.sh missing". Shell out to our own binary's
    // subcommand — the exact check worker.sh uses.
    let exe = std::env::current_exe().context("resolve chump binary for gap preflight")?;
    // RESILIENT-1491: cwd for this subprocess is the FRESH worktree (so
    // worktree-scoped lease files at `<wt>/.chump-locks/` stay visible to
    // the check), but `.chump/state.db` is gitignored and never populated
    // in a brand-new worktree — `GapStore::db_path` would otherwise resolve
    // to `<wt>/.chump/state.db`, an empty/nonexistent file, and preflight
    // WARNs "not found in state.db" even though the gap is right there in
    // the main checkout's canonical db. Point it at the main checkout's
    // state.db explicitly (db_path() checks CHUMP_STATE_DB first).
    // INFRA-8190: the ONE resolver (CHUMP_STATE_DB > main checkout).
    let state_db = chump_gap_store::store_path::state_db_path(&opts.repo_root);
    let status = Command::new(&exe)
        .args(["gap", "preflight", opts.gap_id])
        // INFRA-302 blocker (3): run from the worktree so any worktree-scoped
        // state (lease files at `<wt>/.chump-locks/`) is visible to the check.
        .current_dir(ws.working_dir())
        .env("CHUMP_STATE_DB", &state_db)
        .status()
        .context("invoke chump gap preflight")?;
    if !status.success() {
        bail!(
            "chump gap preflight rejected {} (exit {})",
            opts.gap_id,
            status.code().unwrap_or(-1)
        );
    }
    Ok(())
}

fn claim(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // INFRA-987 completion: scripts/coord/gap-claim.sh was deleted (#2014) and its
    // lease-write ported to Rust. dispatch already created the worktree in
    // Workspace::new, so it needs a LEASE-ONLY claim — NOT `chump claim`, which is the
    // FULL atomic claim (creates its OWN worktree AND trips the RESILIENT-073 autonomy
    // kill-switch). Call the lease primitive directly.
    let paths_vec: Vec<&str> = opts
        .paths
        .map(|p| {
            p.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let ttl_secs = std::env::var("CHUMP_GAP_CLAIM_TTL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(3600);
    // The lease must land in THIS worktree's `.chump-locks/` (as gap-claim.sh did via
    // cwd=working_dir). `agent_lease::locks_dir()` resolves via CHUMP_REPO; point it at
    // the worktree for the duration of the claim (same pattern as execute_gap.rs:999).
    // CREDIBLE-1566: record the PR's head branch on the lease during a --repair dispatch
    // so off-rails branch guards pass without needing an Off-Rails-Bypass trailer.
    let lease_branch = match &opts.mode {
        DispatchMode::Repair { head_branch } => Some(head_branch.as_str()),
        _ => None,
    };
    let prev_repo = std::env::var("CHUMP_REPO").ok();
    std::env::set_var("CHUMP_REPO", ws.working_dir());
    let result = crate::agent_lease::claim_gap_with_branch(
        opts.gap_id,
        &paths_vec,
        ttl_secs,
        "dispatch",
        lease_branch,
    );
    match prev_repo {
        Some(p) => std::env::set_var("CHUMP_REPO", p),
        None => std::env::remove_var("CHUMP_REPO"),
    }
    result.with_context(|| format!("lease-claim {} failed", opts.gap_id))?;
    Ok(())
}

fn ship(ws: &Workspace) -> Result<ShipResult> {
    let opts = ws.opts();
    // RESILIENT-1640: call `admit cargo` before the ship phase (not only
    // `admit claude` before spawning `claude -p`). Waits bounded by step budget,
    // emits `kind=admission_deferred` once on contention, and does NOT fail open
    // into a contended build.
    let step_budget = resolve_subagent_budget_secs_for_gap(&opts.repo_root, opts.gap_id);
    if let Err(msg) = crate::admit::gate_cargo_before_ship(&opts.repo_root, step_budget) {
        return Ok(ShipResult::Aborted { error: msg });
    }
    let script = opts.repo_root.join("scripts/coord/bot-merge.sh");
    if !script.exists() {
        bail!("bot-merge.sh missing at {}", script.display());
    }
    let mut cmd = Command::new("bash");
    cmd.arg(&script).args(["--gap", opts.gap_id]);
    if opts.auto_merge {
        cmd.arg("--auto-merge");
    }
    if opts.skip_tests {
        cmd.arg("--skip-tests");
    }
    // RESILIENT-1642: export shared CARGO_TARGET_DIR into the ship phase too.
    cmd.env("CARGO_TARGET_DIR", resolve_shared_cargo_target_dir());
    // INFRA-8204: explicit, not merely inherited — bot-merge.sh's own
    // session-ID auto-detection only scans $LOCK_DIR/*.json + state.db, never
    // the dispatch worktree's own .chump-locks/, so without this the ship
    // phase can't see the lease claim() just wrote and re-invokes
    // `chump claim`, stranding the agent's commits.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    cmd.env("CHUMP_DISPATCH_GAP", opts.gap_id);
    // INFRA-302 blocker (3): bot-merge.sh derives the branch via
    // `git rev-parse --abbrev-ref HEAD` — it MUST run inside the
    // dispatch's fresh worktree, not the main checkout, or it pushes
    // (and force-arms auto-merge on) the wrong branch.
    // INFRA-8083: spawn bot-merge.sh in its own process group (`process_group(0)`)
    // so terminating or dropping the dispatch also terminates all bot-merge
    // descendants.
    cmd.current_dir(ws.working_dir());
    configure_child_lifetime(&mut cmd);
    let mut child = cmd.spawn().context("invoke bot-merge.sh")?;
    let child_pid = child.id();
    let mut group_guard = ChildGroupGuard::new(child_pid, opts.gap_id);
    let status = match child.wait() {
        Ok(s) => {
            group_guard.release();
            s
        }
        Err(e) => {
            kill_child_process_group(&mut child);
            group_guard.release();
            return Err(e).context("wait for bot-merge.sh");
        }
    };

    // CREDIBLE-1506: bot-merge.sh's exit code is advisory, not authoritative.
    // bot-merge arms GitHub auto-merge and THEN runs the INFRA-154 post-arm
    // auto-close; that tail (or any post-arm step) can bubble a non-zero exit
    // even though the PR has already landed or is armed and pending — exactly
    // the CREDIBLE-301 (#5500) regression where a fully successful zero-touch
    // ship reported `aborted` / exit 1. Trust the PR's real state on GitHub
    // over the local exit code: a merged (landed) PR, or an armed+pending PR
    // when auto-merge was requested, is a success; only a run that never got
    // a PR opened/armed is a genuine failure. (Generalizes CREDIBLE-297, which
    // only recovered exit 13 + merged — any exit code is now recoverable when
    // the ground-truth PR state proves the ship succeeded.)
    let pr = current_pr_number(ws.working_dir()).ok();
    let pr_state = pr
        .map(|n| probe_pr_state(ws.working_dir(), n))
        .unwrap_or(PrState::Unknown);
    let exit_code = status.code().unwrap_or(-1);
    Ok(classify_ship(
        status.success(),
        exit_code,
        opts.auto_merge,
        pr,
        pr_state,
    ))
}

/// CREDIBLE-1506: ground-truth state of the branch's PR on GitHub, used to
/// decide the real ship outcome independent of bot-merge.sh's exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PrState {
    /// PR has merged (landed on main).
    Merged,
    /// PR is open and GitHub auto-merge is enabled — lands when CI greens.
    Armed,
    /// PR is open but auto-merge is not enabled (e.g. a plain `dispatch`
    /// without `--auto-merge`).
    Open,
    /// No PR resolvable for the branch, or `gh` errored — treated as "no
    /// ground-truth success signal" so a failing bot-merge stays a failure.
    Unknown,
}

/// CREDIBLE-1506: pure decision table from (bot-merge exit) × (PR ground
/// truth) → [`ShipResult`]. Total + side-effect-free so the exit-code contract
/// is unit-tested directly.
fn classify_ship(
    bot_merge_succeeded: bool,
    exit_code: i32,
    auto_merge_requested: bool,
    pr: Option<u64>,
    pr_state: PrState,
) -> ShipResult {
    // 1. Landed on main — unambiguous success regardless of the local exit code.
    if pr_state == PrState::Merged {
        if let Some(pr_number) = pr {
            return ShipResult::Shipped { pr_number };
        }
    }
    // 2. Armed + pending — success only when auto-merge was actually requested,
    //    so an externally-armed PR can't mask a genuinely failed run.
    if pr_state == PrState::Armed && auto_merge_requested {
        if let Some(pr_number) = pr {
            return ShipResult::Armed { pr_number };
        }
    }
    // 3. bot-merge reported success and we have a PR — opened/shipped.
    if bot_merge_succeeded {
        return match pr {
            Some(pr_number) => ShipResult::Shipped { pr_number },
            None => ShipResult::Blocked {
                reason: "ship succeeded but no PR is resolvable for the branch".to_string(),
            },
        };
    }
    // 4. bot-merge failed and the PR neither landed nor armed — genuine failure.
    ShipResult::Aborted {
        error: format!("bot-merge.sh exited {exit_code}"),
    }
}

fn current_pr_number(repo_root: &Path) -> Result<u64> {
    let out = Command::new("gh")
        .args(["pr", "view", "--json", "number", "-q", ".number"])
        .current_dir(repo_root)
        .output()
        .context("gh pr view")?;
    if !out.status.success() {
        bail!(
            "gh pr view failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    s.parse::<u64>()
        .with_context(|| format!("parse PR# from {s:?}"))
}

/// CREDIBLE-1506: best-effort ground-truth of the branch's PR on GitHub.
/// One `gh pr view` fetches `state` + `autoMergeRequest` so [`classify_ship`]
/// can tell a landed/armed ship from a genuine failure regardless of
/// bot-merge.sh's exit code. Any `gh`/parse error degrades to
/// [`PrState::Unknown`] (no success signal), so a failing bot-merge stays a
/// failure rather than being masked. (Generalizes CREDIBLE-297's exit-13 +
/// merged-only recovery to any post-arm non-zero exit.)
fn probe_pr_state(repo_root: &Path, pr_number: u64) -> PrState {
    let out = Command::new("gh")
        .args([
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "state,autoMergeRequest",
        ])
        .current_dir(repo_root)
        .output();
    let o = match out {
        Ok(o) if o.status.success() => o,
        _ => return PrState::Unknown,
    };
    let v: serde_json::Value = match serde_json::from_slice(&o.stdout) {
        Ok(v) => v,
        Err(_) => return PrState::Unknown,
    };
    let state = v.get("state").and_then(|s| s.as_str()).unwrap_or("");
    if state == "MERGED" {
        return PrState::Merged;
    }
    let armed = v
        .get("autoMergeRequest")
        .map(|a| !a.is_null())
        .unwrap_or(false);
    if state == "OPEN" && armed {
        PrState::Armed
    } else {
        PrState::Open
    }
}

/// Attempt one `chump --release` subprocess call. Returns an error if the
/// subprocess fails to spawn or exits non-zero.
fn release(ws: &Workspace) -> Result<()> {
    let opts = ws.opts();
    // Re-use [`resolve_chump_binary`] so we honor the same precedence as
    // Phase 2's exec-gap path (in-tree target/ → $HOME/.local/bin → PATH).
    let chump = resolve_chump_binary(&opts.repo_root);
    // INFRA-302 blocker (3): release from the worktree so the same
    // session-ID resolution that wrote the lease (under
    // `<worktree>/.chump-locks/`) sees it for cleanup.
    //
    // RESILIENT-293: dispatch always knows exactly which session it's
    // releasing (the current one) — this is never an interactive call.
    // Without `--force`, `chump --release` prints "Confirm? [y/N]" and
    // blocks on `stdin::read_line`. Under `--backend headless` there is no
    // TTY feeding that prompt, so the subprocess (and the whole dispatch
    // cycle behind it) hangs indefinitely instead of failing fast. Passing
    // `--force` skips the prompt entirely, matching the non-interactive
    // nature of this call site. `.stdin(Stdio::null())` is a second,
    // defense-in-depth guard: even if a future code path re-adds a prompt,
    // reading from a closed stdin returns immediately (EOF) instead of
    // blocking on an inherited-but-never-fed pipe.
    let status = Command::new(&chump)
        .arg("--release")
        .arg("--force")
        .stdin(std::process::Stdio::null())
        .current_dir(ws.working_dir())
        .status()
        .with_context(|| format!("spawning chump --release (binary: {})", chump.display()))?;
    if !status.success() {
        bail!("chump --release exited with {}", status);
    }
    Ok(())
}

/// Release the lease with retries on transient failure (e.g. a sibling
/// worker holding a brief SQLite write-lock on the fleet's shared state.db —
/// "database is locked" under load, RESILIENT-293). On final failure:
/// - emits `kind=lease_release_failed` to ambient.jsonl (INFRA-1243)
/// - logs via `tracing::error!`
/// - propagates via `bail!` so the dispatch caller sees the failure
///
/// Lease files carry a TTL so a missed release auto-recovers; this function
/// makes the gap deliberate and observable rather than silently lost.
///
/// RESILIENT-293: bumped from a single 500ms retry to 4 attempts with
/// exponential backoff (250ms → 2s, ~3.75s total budget). A hot node under
/// fleet load can hold a sibling worker's write-lock on state.db for longer
/// than one 500ms window; a single retry wasn't enough headroom to ride out
/// that contention, so `chump dispatch --backend headless` aborted (and
/// leaked the lease until TTL) on nodes that were otherwise healthy.
fn release_with_retry(ws: &Workspace) -> Result<()> {
    const MAX_ATTEMPTS: u32 = 4;
    let mut delay_ms: u64 = 250;
    for attempt in 1..=MAX_ATTEMPTS {
        match release(ws) {
            Ok(()) => return Ok(()),
            Err(e) if attempt < MAX_ATTEMPTS => {
                eprintln!(
                    "[dispatch] WARNING: lease release failed (attempt {attempt}/{MAX_ATTEMPTS}), retrying: {e:#}"
                );
                std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                delay_ms = (delay_ms * 2).min(2000);
            }
            Err(e) => {
                let msg = format!("{e:#}");
                emit_lease_release_failed(ws.opts().gap_id, &msg);
                tracing::error!(
                    gap_id = ws.opts().gap_id,
                    error = %e,
                    "lease release failed after {MAX_ATTEMPTS} attempts — lease may persist until TTL"
                );
                bail!("lease release failed after {MAX_ATTEMPTS} attempts: {e:#}");
            }
        }
    }
    unreachable!("loop always returns via Ok/bail! within MAX_ATTEMPTS iterations");
}

/// Emit a `lease_release_failed` event to ambient.jsonl (INFRA-1243).
fn emit_lease_release_failed(gap_id: &str, error: &str) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    // Escape the error string for JSON (replace backslash and quote).
    let error_escaped = error.replace('\\', "\\\\").replace('"', "\\\"");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\
         \"kind\":\"lease_release_failed\",\"gap\":\"{gap_id}\",\
         \"error\":\"{error_escaped}\"}}"
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", line);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn dispatch_options_round_trip() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: true,
            skip_tests: false,
            paths: Some("src/dispatch.rs"),
            repo_root: PathBuf::from("/tmp/nonexistent-dispatch-test"),
            mode: DispatchMode::Work,
        };
        assert_eq!(opts.gap_id, "INFRA-191");
        assert!(opts.auto_merge);
        assert!(!opts.skip_tests);
        assert_eq!(opts.paths, Some("src/dispatch.rs"));
        match opts.work {
            WorkBackend::Interactive => {}
            _ => panic!("expected Interactive"),
        }
    }

    #[test]
    fn ship_result_variants_construct() {
        assert_eq!(
            ShipResult::Shipped { pr_number: 770 },
            ShipResult::Shipped { pr_number: 770 }
        );
        assert_ne!(
            ShipResult::Shipped { pr_number: 770 },
            ShipResult::Shipped { pr_number: 771 }
        );
        let blocked = ShipResult::Blocked {
            reason: "test".into(),
        };
        match blocked {
            ShipResult::Blocked { ref reason } => assert_eq!(reason, "test"),
            _ => panic!("expected Blocked"),
        }
    }

    // ── CREDIBLE-1506: exit-code contract ────────────────────────────────────
    #[test]
    fn classify_exit_landed_and_armed_are_success() {
        // A landed PR is exit 0 with a line naming the PR.
        let (code, reason, status) = classify_exit(&ShipResult::Shipped { pr_number: 5500 });
        assert_eq!(code, 0);
        assert_eq!(status, "shipped");
        assert!(reason.contains("5500"), "reason must name the PR: {reason}");

        // An armed+pending PR is ALSO exit 0 — this is the CREDIBLE-301 (#5500)
        // regression: a fully successful zero-touch ship must not read `aborted`.
        let (code, reason, status) = classify_exit(&ShipResult::Armed { pr_number: 5500 });
        assert_eq!(code, 0, "armed+pending must be success, not aborted");
        assert_eq!(status, "armed");
        assert!(reason.contains("5500"), "reason must name the PR: {reason}");
        assert!(!reason.contains("aborted"));
    }

    #[test]
    fn classify_exit_genuine_failure_stays_exit_one() {
        let (code, reason, status) = classify_exit(&ShipResult::Aborted {
            error: "bot-merge.sh exited 15".into(),
        });
        assert_eq!(code, 1, "a genuine failure must stay exit 1");
        assert_eq!(status, "failed");
        assert!(reason.contains("aborted"));

        let (code, _, status) = classify_exit(&ShipResult::Blocked {
            reason: "CI red".into(),
        });
        assert_eq!(code, 2);
        assert_eq!(status, "blocked");
    }

    // ── CREDIBLE-1506: ship classification decision table ─────────────────────
    #[test]
    fn classify_ship_armed_pending_is_success_even_when_bot_merge_failed() {
        // The CREDIBLE-301 shape: bot-merge exited non-zero (post-arm auto-close
        // crashed before the merge could exist) BUT the PR is armed + pending.
        let r = classify_ship(
            /* bot_merge_succeeded */ false,
            /* exit_code */ 1,
            /* auto_merge_requested */ true,
            Some(5500),
            PrState::Armed,
        );
        assert_eq!(r, ShipResult::Armed { pr_number: 5500 });
    }

    #[test]
    fn classify_ship_landed_is_success_on_any_nonzero_exit() {
        // Generalizes CREDIBLE-297: any non-zero bot-merge exit is recoverable
        // when ground truth says the PR already merged.
        for exit in [1, 13, 15, 144] {
            let r = classify_ship(false, exit, true, Some(5500), PrState::Merged);
            assert_eq!(
                r,
                ShipResult::Shipped { pr_number: 5500 },
                "exit {exit} + merged PR must be Shipped"
            );
        }
    }

    #[test]
    fn classify_ship_failure_with_no_landed_or_armed_pr_aborts() {
        // bot-merge failed and the PR neither merged nor armed → genuine failure.
        let r = classify_ship(false, 15, true, Some(5500), PrState::Open);
        assert_eq!(
            r,
            ShipResult::Aborted {
                error: "bot-merge.sh exited 15".into()
            }
        );
        // No PR at all is also a genuine failure.
        let r = classify_ship(false, 15, true, None, PrState::Unknown);
        assert!(matches!(r, ShipResult::Aborted { .. }));
    }

    #[test]
    fn classify_ship_armed_without_request_is_not_masked() {
        // An externally-armed PR must NOT turn a failed run (auto-merge NOT
        // requested) into a success — keeps genuine failures honest.
        let r = classify_ship(
            false,
            15,
            /* auto_merge_requested */ false,
            Some(7),
            PrState::Armed,
        );
        assert!(matches!(r, ShipResult::Aborted { .. }));
    }

    #[test]
    fn classify_ship_success_exit_opens_pr() {
        // bot-merge clean exit + PR resolvable → Shipped (opened).
        let r = classify_ship(true, 0, false, Some(42), PrState::Open);
        assert_eq!(r, ShipResult::Shipped { pr_number: 42 });
        // clean exit but no PR → Blocked (not Aborted).
        let r = classify_ship(true, 0, true, None, PrState::Unknown);
        assert!(matches!(r, ShipResult::Blocked { .. }));
    }

    /// Test helper: build a Workspace with a fixed working_dir, skipping
    /// the [`Workspace::new`] worktree-creation path (which needs a real
    /// git repo). Tests that exercise step fns just need a `(opts,
    /// working_dir)` bundle.
    fn ws_with_dir<'a>(opts: &'a DispatchOptions<'a>, dir: PathBuf) -> Workspace<'a> {
        Workspace {
            opts,
            working_dir: dir,
            session_id: String::new(),
            child_pid: std::cell::Cell::new(None),
        }
    }

    // INFRA-987: `preflight_bails_when_script_missing` was retired here. `preflight()`
    // no longer shells to the removed scripts/coord/gap-preflight.sh — it delegates to
    // the `chump gap preflight` subcommand via current_exe(). That subcommand is the
    // one worker.sh uses (INFRA-379) and is covered by its own integration tests; the
    // old "missing-file" failure mode this asserted no longer exists.

    #[test]
    fn ship_bails_when_script_missing() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        let err = ship(&ws).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("bot-merge.sh missing"),
            "expected missing-file error, got: {msg}"
        );
    }

    // Phase 1.5+: integration test that exercises a full run() against a
    // tmpdir-staged fake repo (mock git/gh via shimmed PATH). Skipped here;
    // tracked in INFRA-191 design doc test plan.

    // ── Phase 2 tests ────────────────────────────────────────────────────────

    #[test]
    fn headless_backend_constructs() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Headless {
                model: "claude-sonnet-4-6".into(),
                prompt: "ship gap INFRA-191".into(),
            },
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
            mode: DispatchMode::Work,
        };
        match opts.work {
            WorkBackend::Headless {
                ref model,
                ref prompt,
            } => {
                assert_eq!(model, "claude-sonnet-4-6");
                assert_eq!(prompt, "ship gap INFRA-191");
            }
            _ => panic!("expected Headless"),
        }
    }

    /// INFRA-3675 regression guard: the prompt must never become a `-p
    /// <value>` argv token, because the DISPATCH_RULES doc it's built from
    /// starts with YAML frontmatter (`---`), which the claude CLI's arg
    /// parser rejects as an unrecognized option. `headless_command_skeleton`
    /// takes no `prompt` parameter at all, so this asserts the built
    /// command's args are exactly the fixed flag set — structurally
    /// impossible for a prompt string to leak into argv this way.
    #[test]
    fn headless_command_skeleton_never_puts_prompt_in_argv() {
        let cmd = headless_command_skeleton("claude-sonnet-4-6");
        let args: Vec<&str> = cmd.get_args().map(|a| a.to_str().unwrap()).collect();
        assert_eq!(
            args,
            vec![
                "-p",
                "--dangerously-skip-permissions",
                "--disallowedTools",
                "ScheduleWakeup,Monitor",
                "--settings",
                "{\"disableAllHooks\":true}",
                "--model",
                "claude-sonnet-4-6"
            ],
            "headless command args changed shape — verify no caller reintroduces \
             `.arg(prompt)` after `-p`, which broke 100% of dispatches (INFRA-3675)"
        );
        // No model → still exactly the fixed flags, no trailing empty arg.
        let cmd_no_model = headless_command_skeleton("");
        let args_no_model: Vec<&str> = cmd_no_model
            .get_args()
            .map(|a| a.to_str().unwrap())
            .collect();
        assert_eq!(
            args_no_model,
            vec![
                "-p",
                "--dangerously-skip-permissions",
                "--disallowedTools",
                "ScheduleWakeup,Monitor",
                "--settings",
                "{\"disableAllHooks\":true}"
            ]
        );
    }

    /// CREDIBLE-1581 AC2: spawn a stub claude binary with the exact argv built by
    /// `headless_command_skeleton` and assert `--settings {"disableAllHooks":true}`
    /// is delivered to the child process.
    #[test]
    fn credible_1581_headless_spawn_argv_disables_all_hooks() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().expect("tempdir");
        let stub = tmp.path().join("claude");
        let out_file = tmp.path().join("argv.txt");
        let script = format!(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"{}\"\n",
            out_file.display()
        );
        std::fs::write(&stub, script).expect("write stub");
        let mut perms = std::fs::metadata(&stub).expect("meta").permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&stub, perms).expect("chmod");

        let skel = headless_command_skeleton("claude-sonnet-4-6");
        let mut cmd = Command::new(&stub);
        cmd.args(skel.get_args());
        let status = cmd.status().expect("spawn stub claude");
        assert!(status.success(), "stub claude exited non-zero");

        let captured: Vec<String> = std::fs::read_to_string(&out_file)
            .expect("read argv.txt")
            .lines()
            .map(str::to_string)
            .collect();
        let i = captured
            .iter()
            .position(|a| a == "--settings")
            .expect("--settings flag present in spawned argv");
        assert_eq!(
            captured.get(i + 1).map(String::as_str),
            Some("{\"disableAllHooks\":true}"),
            "expected disableAllHooks setting immediately after --settings"
        );
    }

    /// INFRA-8203 AC1 + AC3: headless children cannot schedule a wakeup or
    /// monitor (flag), and the prompt epilogue forbids it, demands a commit
    /// before any wait over 60s, and caps every local build.
    #[test]
    fn infra_8203_headless_disallows_wakeup_and_epilogue_says_commit_first() {
        let args: Vec<String> = headless_command_skeleton("")
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let i = args
            .iter()
            .position(|a| a == "--disallowedTools")
            .expect("--disallowedTools flag");
        let denied: Vec<&str> = args[i + 1].split(',').collect();
        assert!(denied.contains(&"ScheduleWakeup") && denied.contains(&"Monitor"));

        let p = headless_prompt("do the gap");
        assert!(p.starts_with("do the gap"));
        for needle in [
            "ending your turn ENDS THE PROCESS",
            "ScheduleWakeup and Monitor are disabled",
            "COMMIT before any wait longer than 60 seconds",
            "wall-clock cap",
        ] {
            assert!(p.contains(needle), "epilogue missing {needle:?}");
        }
    }

    #[test]
    fn exec_gap_backend_constructs() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::ExecGap,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
            mode: DispatchMode::Work,
        };
        matches!(opts.work, WorkBackend::ExecGap);
    }

    #[test]
    fn headless_bails_on_empty_prompt() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive, // value unused; we test the helper directly
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        let err = spawn_headless(&ws, "claude-sonnet-4-6", "   ").unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("prompt is empty"),
            "expected empty-prompt error, got: {msg}"
        );
    }

    #[test]
    fn resolve_chump_binary_falls_back_to_path() {
        // Empty repo_root with no target/ subdir; HOME unset (or home doesn't
        // contain .local/bin/chump). Should fall back to bare `chump` so the
        // OS resolves via PATH.
        let bin = resolve_chump_binary(&PathBuf::from("/tmp/no-such-repo-root"));
        // Either a real path (Jeff's machine has $HOME/.local/bin/chump) or
        // bare "chump" (CI). Both are valid resolutions. The contract is "we
        // never panic and we always return *something*".
        let s = bin.to_string_lossy().to_string();
        assert!(
            s == "chump" || s.ends_with("/chump") || s.contains("chump"),
            "unexpected resolution: {s}"
        );
    }

    #[test]
    fn do_work_interactive_is_noop() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp"),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/tmp"));
        // Interactive should just return Ok(()) without spawning anything.
        do_work(&ws).expect("Interactive backend must always succeed");
    }

    // ── INFRA-302 blocker (3) — stale-branch / no-worktree fix ──────────────

    /// Workspace::new for Interactive must NOT touch the worktree
    /// machinery — the caller is already in their own worktree per
    /// CLAUDE.md. Regression guard: don't accidentally spawn a worktree
    /// for the ledger-flip flow.
    #[test]
    fn workspace_interactive_uses_repo_root_unchanged() {
        let opts = DispatchOptions {
            gap_id: "INFRA-302",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/tmp/some-existing-worktree"),
            mode: DispatchMode::Work,
        };
        let ws = Workspace::new(&opts).expect("Interactive must not touch git");
        assert_eq!(
            ws.working_dir(),
            opts.repo_root.as_path(),
            "Interactive backend must use opts.repo_root verbatim — caller is \
             already in their worktree (CLAUDE.md \"always work in a linked worktree\")"
        );
    }

    /// The dispatched-worktree path must follow the
    /// chump_orchestrator::dispatch_paths convention so the
    /// stale-worktree-reaper sweeps both orchestrator-spawned AND
    /// `chump dispatch`-spawned trees uniformly. Regression guard for
    /// path/branch drift between the two entry points.
    #[test]
    fn dispatch_paths_match_orchestrator_convention() {
        // Direct call into the orchestrator helper — confirms the import
        // resolves AND the path shape we depend on hasn't drifted. If
        // this changes, the stale-worktree-reaper's glob needs updating
        // in lockstep.
        let (wt, branch) =
            chump_orchestrator::dispatch::dispatch_paths(Path::new("/repo"), "INFRA-302");
        assert_eq!(
            wt,
            PathBuf::from("/repo/.claude/worktrees/infra-302"),
            "worktree path drifted — stale-worktree-reaper glob may need updating"
        );
        assert_eq!(
            branch, "claude/infra-302",
            "branch convention drifted — bot-merge.sh's gap-from-branch \
             auto-derive (INFRA-237) parses this prefix"
        );
    }

    // ── INFRA-8204: one session id for the whole dispatch cycle ──────────────

    /// With no `CHUMP_SESSION_ID` set, the derived id must start with
    /// `dispatch-<slug>-` (slug = the same lowercase gap slug used for the
    /// worktree dir) and must never be empty — this is the id claim(),
    /// ship(), and every spawned work child share so bot-merge.sh's
    /// session-ID auto-detection can actually find the lease claim() wrote.
    #[test]
    #[serial_test::serial(dispatch_session_id_env)]
    fn resolve_dispatch_session_id_derives_from_slug_when_unset() {
        std::env::remove_var("CHUMP_SESSION_ID");
        let id = resolve_dispatch_session_id("INFRA_8204");
        assert!(!id.is_empty(), "derived session id must not be empty");
        assert!(
            id.starts_with("dispatch-infra-8204-"),
            "expected id to start with 'dispatch-infra-8204-' (slug lowercased, \
             underscores replaced with hyphens, matching dispatch_paths), got: {id}"
        );
    }

    /// An explicit, non-empty `CHUMP_SESSION_ID` set before dispatch (e.g. by
    /// an orchestrator that already assigned one) must win over the derived
    /// id — [`Workspace::new`] relies on this so it doesn't clobber an
    /// intentionally-assigned id.
    #[test]
    #[serial_test::serial(dispatch_session_id_env)]
    fn resolve_dispatch_session_id_prefers_explicit_env_var() {
        std::env::set_var("CHUMP_SESSION_ID", "explicit-session-xyz");
        let id = resolve_dispatch_session_id("INFRA-8204");
        std::env::remove_var("CHUMP_SESSION_ID");
        assert_eq!(id, "explicit-session-xyz");
    }

    /// A whitespace-only `CHUMP_SESSION_ID` must be treated as unset (same
    /// trim-and-check-non-empty contract as
    /// `chump_agent_lease::current_session_id`), falling through to the
    /// derived id rather than returning blank/whitespace.
    #[test]
    #[serial_test::serial(dispatch_session_id_env)]
    fn resolve_dispatch_session_id_treats_blank_env_as_unset() {
        std::env::set_var("CHUMP_SESSION_ID", "   ");
        let id = resolve_dispatch_session_id("INFRA-8204");
        std::env::remove_var("CHUMP_SESSION_ID");
        assert!(
            id.starts_with("dispatch-infra-8204-"),
            "blank CHUMP_SESSION_ID should fall through to the derived id, got: {id}"
        );
    }

    /// The pre-INFRA-302 bug was that `chump dispatch INFRA-247` ran in
    /// the main checkout and reported `branch=chump/close-ghosts-batch-3`
    /// (operator's stale leftover branch). After the fix, the
    /// dispatched-worktree branch derives from `gap_id`, NOT from the
    /// caller's `git rev-parse --abbrev-ref HEAD`. This test pins the
    /// derivation contract.
    #[test]
    fn dispatched_worktree_branch_derives_from_gap_id_not_head() {
        // Two calls with the same repo_root but different gap_ids must
        // produce different branches — proving the branch is a function
        // of gap_id, not of the repo's current HEAD (which is the same
        // for both calls).
        let (_w1, b1) =
            chump_orchestrator::dispatch::dispatch_paths(Path::new("/repo"), "INFRA-247");
        let (_w2, b2) =
            chump_orchestrator::dispatch::dispatch_paths(Path::new("/repo"), "INFRA-302");
        assert_ne!(
            b1, b2,
            "branches must differ when gap_ids differ — otherwise the \
             pre-INFRA-302 stale-branch-pickup bug regresses"
        );
        assert!(
            b1.contains("infra-247"),
            "branch must encode gap_id, got: {b1}"
        );
        assert!(
            b2.contains("infra-302"),
            "branch must encode gap_id, got: {b2}"
        );
        // Critically: neither branch matches a typical operator-leftover
        // branch name (the 2026-05-02 incident leftover was
        // `chump/close-ghosts-batch-3`).
        assert!(
            !b1.contains("close-ghosts"),
            "regression: branch derived from operator's stale HEAD"
        );
    }

    /// `create_dispatch_worktree` is best-effort idempotent on a
    /// pre-existing target path (force-removes a leftover worktree
    /// before re-adding). Without a real git repo we can't run the
    /// happy path, but we CAN verify that the function doesn't panic
    /// when handed a nonexistent repo_root — the underlying git
    /// commands fail gracefully with a clear `Result<Err>` instead of
    /// blowing up the dispatch.
    #[test]
    fn create_dispatch_worktree_returns_err_on_invalid_repo_root() {
        let res = create_dispatch_worktree(
            Path::new("/tmp/definitely-not-a-git-repo-infra-302"),
            "INFRA-302",
        );
        // We expect Err — but the important thing is it does NOT panic.
        // If git is unavailable in the test environment we'd also Err.
        assert!(
            res.is_err(),
            "expected Err from invalid repo_root; got: {:?}",
            res.map(|p| p.display().to_string())
        );
    }

    /// RESILIENT-555 regression: a worktree created by `chump dispatch` must
    /// end up with a `.chump/state.db` that contains whatever gap is open
    /// in the main checkout's canonical state.db — not an independent,
    /// empty file. Builds a real git repo with an `origin/main` ref (the
    /// base `create_dispatch_worktree` branches from) plus a sentinel
    /// `.chump/state.db`, runs the real worktree-creation path, and asserts
    /// the resulting worktree's `.chump/state.db` is a symlink resolving to
    /// the same content as main's — i.e. the dispatched gap is always
    /// visible, closing the "not found in state.db" split-brain.
    #[test]
    fn create_dispatch_worktree_links_state_db_to_main_checkout() {
        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let repo_root = tmp.path().join("main");
        std::fs::create_dir_all(&repo_root).expect("mk repo_root");

        let run_git = |args: &[&str]| {
            assert!(
                Command::new("git")
                    .args(args)
                    .current_dir(&repo_root)
                    .status()
                    .expect("spawn git")
                    .success(),
                "git {args:?} failed"
            );
        };
        run_git(&["init", "--quiet", "-b", "main"]);
        run_git(&["config", "user.email", "test@example.com"]);
        run_git(&["config", "user.name", "Test"]);
        std::fs::write(repo_root.join("f.txt"), "x").expect("write file");
        run_git(&["add", "."]);
        run_git(&["commit", "-m", "init", "--quiet"]);

        // Fake an `origin/main` remote-tracking ref without a real remote:
        // bare-clone the repo into a sibling dir and fetch it back as
        // "origin" so `git worktree add -b <branch> origin/main` (the exact
        // invocation create_dispatch_worktree uses) resolves.
        let bare = tmp.path().join("origin.git");
        assert!(Command::new("git")
            .args(["clone", "--quiet", "--bare"])
            .arg(&repo_root)
            .arg(&bare)
            .status()
            .expect("spawn git clone")
            .success());
        run_git(&["remote", "add", "origin", bare.to_str().unwrap()]);
        run_git(&["fetch", "--quiet", "origin"]);

        std::fs::create_dir_all(repo_root.join(".chump")).expect("mk .chump");
        std::fs::write(repo_root.join(".chump/state.db"), b"canonical-sentinel")
            .expect("write sentinel state.db");

        let worktree_path =
            create_dispatch_worktree(&repo_root, "RESILIENT-TEST-555").expect("worktree created");

        let worktree_db = worktree_path.join(".chump/state.db");
        let meta = std::fs::symlink_metadata(&worktree_db)
            .expect("worktree .chump/state.db should exist after dispatch worktree creation");
        assert!(
            meta.file_type().is_symlink(),
            "worktree .chump/state.db should be a symlink to main's, not an \
             independent file — otherwise the dispatched gap is invisible \
             to `chump gap preflight` run inside the worktree"
        );
        assert_eq!(
            std::fs::read(&worktree_db).expect("read worktree state.db through symlink"),
            b"canonical-sentinel",
            "worktree state.db must resolve to main's content, proving a gap \
             present on main is visible from the fresh worktree"
        );

        let _ = Command::new("git")
            .arg("-C")
            .arg(&repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(&worktree_path)
            .status();
    }

    /// INFRA-8199 AC2: a repair dispatch's worktree must start from the open
    /// PR's head branch, not origin/main. Builds a repo whose origin has a
    /// `claude/credible-9999` branch one commit ahead of main (the "PR
    /// head"), plus a stale diverged local copy of that branch, and asserts
    /// the worktree is on that branch at the PR head commit and that the
    /// diverged local copy was preserved under refs/dispatch-backup/.
    #[test]
    fn repair_worktree_is_based_on_pr_head_not_origin_main() {
        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let repo_root = tmp.path().join("main");
        std::fs::create_dir_all(&repo_root).expect("mk repo_root");
        let git = |dir: &Path, args: &[&str]| -> String {
            let out = Command::new("git")
                .args(args)
                .current_dir(dir)
                .output()
                .expect("spawn git");
            assert!(out.status.success(), "git {args:?} failed: {out:?}");
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        };
        git(&repo_root, &["init", "--quiet", "-b", "main"]);
        git(&repo_root, &["config", "user.email", "test@example.com"]);
        git(&repo_root, &["config", "user.name", "Test"]);
        std::fs::write(repo_root.join("f.txt"), "x").unwrap();
        git(&repo_root, &["add", "."]);
        git(&repo_root, &["commit", "-m", "init", "--quiet"]);
        let main_sha = git(&repo_root, &["rev-parse", "HEAD"]);

        // The PR head: one commit ahead of main on claude/credible-9999.
        git(
            &repo_root,
            &["checkout", "--quiet", "-b", "claude/credible-9999"],
        );
        std::fs::write(repo_root.join("pr.txt"), "pr work").unwrap();
        git(&repo_root, &["add", "."]);
        git(&repo_root, &["commit", "-m", "pr work", "--quiet"]);
        let pr_sha = git(&repo_root, &["rev-parse", "HEAD"]);

        let bare = tmp.path().join("origin.git");
        assert!(Command::new("git")
            .args(["clone", "--quiet", "--bare"])
            .arg(&repo_root)
            .arg(&bare)
            .status()
            .unwrap()
            .success());
        git(
            &repo_root,
            &["remote", "add", "origin", bare.to_str().unwrap()],
        );
        git(&repo_root, &["fetch", "--quiet", "origin"]);

        // A stale local copy of the head branch that diverged from the PR.
        git(&repo_root, &["checkout", "--quiet", "main"]);
        git(
            &repo_root,
            &["branch", "-f", "claude/credible-9999", "main"],
        );
        git(&repo_root, &["checkout", "--quiet", "-b", "scratch"]);
        std::fs::write(repo_root.join("local.txt"), "unpushed").unwrap();
        git(&repo_root, &["add", "."]);
        git(&repo_root, &["commit", "-m", "unpushed local", "--quiet"]);
        let local_sha = git(&repo_root, &["rev-parse", "HEAD"]);
        git(
            &repo_root,
            &["branch", "-f", "claude/credible-9999", &local_sha],
        );
        git(&repo_root, &["checkout", "--quiet", "main"]);

        let wt = create_dispatch_worktree_from(
            &repo_root,
            "CREDIBLE-9999",
            Some("claude/credible-9999"),
        )
        .expect("repair worktree created");

        assert_eq!(
            git(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "claude/credible-9999",
            "repair worktree must be on the PR head branch"
        );
        let head = git(&wt, &["rev-parse", "HEAD"]);
        assert_eq!(
            head, pr_sha,
            "repair worktree must start at the PR head commit"
        );
        assert_ne!(
            head, main_sha,
            "repair worktree must not start from origin/main"
        );
        assert_eq!(
            git(
                &repo_root,
                &["rev-parse", "refs/dispatch-backup/claude/credible-9999"]
            ),
            local_sha,
            "diverged local branch must be preserved, not destroyed"
        );
        assert_eq!(
            git(&wt, &["config", "branch.claude/credible-9999.merge"]),
            "refs/heads/claude/credible-9999"
        );

        let _ = Command::new("git")
            .arg("-C")
            .arg(&repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(&wt)
            .status();
    }

    /// INFRA-8207 regression: `set_dispatch_branch_upstream` must point a
    /// branch's upstream at itself (origin/<branch>), not leave it tracking
    /// whatever `git worktree add -b <branch> origin/main` set up (origin/main) —
    /// that mistracking is exactly what made `gh pr create` (no --head) fail
    /// with "aborted: you must first push the current branch to a remote,
    /// or use the --head flag" on dispatch-created branches.
    #[test]
    fn set_dispatch_branch_upstream_points_at_own_branch() {
        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let repo_root = tmp.path().to_path_buf();

        let run_git = |args: &[&str]| {
            assert!(
                Command::new("git")
                    .args(args)
                    .current_dir(&repo_root)
                    .status()
                    .expect("spawn git")
                    .success(),
                "git {args:?} failed"
            );
        };
        run_git(&["init", "--quiet", "-b", "main"]);
        run_git(&["config", "user.email", "test@example.com"]);
        run_git(&["config", "user.name", "Test"]);
        std::fs::write(repo_root.join("f.txt"), "x").expect("write file");
        run_git(&["add", "."]);
        run_git(&["commit", "-m", "init", "--quiet"]);
        run_git(&["branch", "claude/infra-8207-test"]);

        set_dispatch_branch_upstream(&repo_root, "claude/infra-8207-test");

        let remote_out = Command::new("git")
            .arg("-C")
            .arg(&repo_root)
            .args(["config", "branch.claude/infra-8207-test.remote"])
            .output()
            .expect("spawn git config remote");
        assert_eq!(
            String::from_utf8_lossy(&remote_out.stdout).trim(),
            "origin",
            "branch.<name>.remote must be origin"
        );

        let merge_out = Command::new("git")
            .arg("-C")
            .arg(&repo_root)
            .args(["config", "branch.claude/infra-8207-test.merge"])
            .output()
            .expect("spawn git config merge");
        assert_eq!(
            String::from_utf8_lossy(&merge_out.stdout).trim(),
            "refs/heads/claude/infra-8207-test",
            "branch.<name>.merge must be refs/heads/<name>, not refs/heads/main"
        );
    }

    #[test]
    fn claim_writes_lease_via_primitive() {
        // INFRA-987: claim() no longer shells to the removed gap-claim.sh — it writes a
        // lease via agent_lease::claim_gap into the worktree's .chump-locks/ (CHUMP_REPO
        // is pinned to working_dir). Verify the lease-only claim succeeds and lands a
        // lease file, rather than the old "script missing" bail.
        let tmp = std::env::temp_dir().join(format!(
            "chump-dispatch-claim-{}-{}",
            std::process::id(),
            "test-001"
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("mk tmp worktree");
        let opts = DispatchOptions {
            gap_id: "TEST-001",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: tmp.clone(),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, tmp.clone());
        let res = claim(&ws);
        let locks = tmp.join(".chump-locks");
        let wrote_lease = std::fs::read_dir(&locks)
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .any(|e| e.path().extension().map(|x| x == "json").unwrap_or(false))
            })
            .unwrap_or(false);
        let _ = std::fs::remove_dir_all(&tmp);
        res.expect("lease-only claim should succeed in a writable dir");
        assert!(
            wrote_lease,
            "expected a lease .json under {}",
            locks.display()
        );
    }

    #[test]
    fn dispatch_outcome_tracks_gap_and_result() {
        let outcome = DispatchOutcome {
            gap_id: "INFRA-191".to_string(),
            branch: "claude/infra-191".to_string(),
            result: ShipResult::Shipped { pr_number: 1234 },
            duration_secs: 42,
        };
        assert_eq!(outcome.gap_id, "INFRA-191");
        assert_eq!(outcome.branch, "claude/infra-191");
        assert_eq!(outcome.duration_secs, 42);
        match outcome.result {
            ShipResult::Shipped { pr_number } => assert_eq!(pr_number, 1234),
            _ => panic!("expected Shipped result"),
        }
    }

    #[test]
    fn dispatch_options_with_paths() {
        let opts = DispatchOptions {
            gap_id: "INFRA-302",
            work: WorkBackend::Interactive,
            auto_merge: true,
            skip_tests: false,
            paths: Some("src/,scripts/"),
            repo_root: PathBuf::from("/repo"),
            mode: DispatchMode::Work,
        };
        assert_eq!(opts.paths, Some("src/,scripts/"));
    }

    #[test]
    fn ship_result_aborted_variant() {
        let aborted = ShipResult::Aborted {
            error: "test error message".into(),
        };
        match aborted {
            ShipResult::Aborted { ref error } => assert_eq!(error, "test error message"),
            _ => panic!("expected Aborted variant"),
        }
    }

    #[test]
    fn workspace_accessors_expose_opts_and_dir() {
        let opts = DispatchOptions {
            gap_id: "INFRA-191",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: PathBuf::from("/repo"),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, PathBuf::from("/working"));
        assert_eq!(ws.opts().gap_id, "INFRA-191");
        assert_eq!(ws.working_dir(), PathBuf::from("/working"));
    }

    // ── INFRA-1243: release_with_retry error handling ────────────────────────

    /// When the `chump --release` subprocess fails twice, `release_with_retry`
    /// must:
    ///   (a) return an Err (not swallow it),
    ///   (b) emit a `lease_release_failed` line to the ambient log.
    ///
    /// We exercise this by placing a mock `chump` binary at
    /// `<tmp>/target/release/chump` that always exits 1 — `resolve_chump_binary`
    /// finds it before falling back to PATH, so the real chump is never called.
    #[test]
    #[serial_test::serial(ambient_env)]
    fn release_with_retry_emits_ambient_event_and_propagates_on_double_failure() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        // Fake chump binary that always exits 1.
        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        std::fs::write(&fake_chump, "#!/usr/bin/env bash\nexit 1\n").unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        // Point ambient log at a temp file so we can inspect it.
        let ambient = dir.join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", ambient.to_string_lossy().as_ref());

        let opts = DispatchOptions {
            gap_id: "INFRA-1243-TEST",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        let err = release_with_retry(&ws).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("failed after 4 attempts"),
            "expected '4 attempts' in error message, got: {msg}"
        );

        let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
        assert!(
            contents.contains("lease_release_failed"),
            "expected 'lease_release_failed' event in ambient log, got: {contents}"
        );
        assert!(
            contents.contains("INFRA-1243-TEST"),
            "expected gap_id in ambient event, got: {contents}"
        );

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    /// Single `release()` call must propagate a non-zero exit status as Err
    /// rather than silently succeeding.
    #[test]
    fn release_returns_err_on_nonzero_exit() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        std::fs::write(&fake_chump, "#!/usr/bin/env bash\nexit 2\n").unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        let opts = DispatchOptions {
            gap_id: "INFRA-1243-UNIT",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        let result = release(&ws);
        assert!(
            result.is_err(),
            "release() must return Err on non-zero exit, got Ok"
        );
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("chump --release exited with"),
            "expected exit-status error, got: {msg}"
        );
    }

    // ── RESILIENT-293: headless release must never block on stdin ────────────

    /// `release()` must pass `--force` to the `chump --release` subprocess so
    /// the interactive "Confirm? [y/N]" prompt (src/main.rs) is never
    /// triggered. Before the fix, this call had no `--force`, so under
    /// `--backend headless` (no TTY feeding stdin) the subprocess would hang
    /// forever on `stdin::read_line`.
    ///
    /// The fake `chump` binary here exits 1 unless invoked with `--force` —
    /// exactly mirroring the real binary's behavior of only skipping the
    /// prompt (and thus succeeding non-interactively) when `--force` is
    /// present. Without the fix, this test fails because `release()` returns
    /// `Err("chump --release exited with exit status: 1")`.
    #[test]
    fn release_passes_force_flag_to_avoid_interactive_prompt() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        std::fs::write(
            &fake_chump,
            "#!/usr/bin/env bash\n\
             for a in \"$@\"; do [ \"$a\" = \"--force\" ] && exit 0; done\n\
             exit 1\n",
        )
        .unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        let opts = DispatchOptions {
            gap_id: "RESILIENT-293-FORCE",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        let result = release(&ws);
        assert!(
            result.is_ok(),
            "release() must pass --force so the fake binary (and by extension \
             the real one) never hits the interactive confirm prompt, got: {result:?}"
        );
    }

    /// `release()` must run with stdin closed (`Stdio::null`), so that even
    /// if a prompt is ever (re-)triggered, a `read_line` call sees immediate
    /// EOF instead of blocking on an inherited-but-unfed pipe — the second,
    /// defense-in-depth half of the RESILIENT-293 fix.
    #[test]
    fn release_runs_with_stdin_closed() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        // `read` on a closed stdin returns immediately with a non-zero exit
        // (no data): if stdin were inherited (a live, unfed pipe) this would
        // hang instead of returning promptly, and the test would time out.
        std::fs::write(&fake_chump, "#!/usr/bin/env bash\nread -r line\nexit 0\n").unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        let opts = DispatchOptions {
            gap_id: "RESILIENT-293-STDIN",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        // If this call hangs, the test binary itself will hang/timeout —
        // that failure mode is the bug this test guards against.
        let result = release(&ws);
        assert!(
            result.is_ok(),
            "release() should complete promptly with stdin closed, got: {result:?}"
        );
    }

    /// `release_with_retry` must survive transient failures that clear up
    /// within the retry budget (simulating a sibling worker's brief
    /// "database is locked" hold on state.db under fleet load). Before the
    /// RESILIENT-293 bump (1 retry / 500ms), a lock held across the single
    /// retry window aborted the whole dispatch cycle; the 4-attempt,
    /// exponential-backoff budget (~3.75s) rides it out.
    #[test]
    #[serial_test::serial(ambient_env)]
    fn release_with_retry_survives_transient_failures_within_budget() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = tempfile::TempDir::new().expect("create tempdir");
        let dir = tmp.path();

        let target_dir = dir.join("target/release");
        std::fs::create_dir_all(&target_dir).unwrap();
        let fake_chump = target_dir.join("chump");
        let counter = dir.join("attempts");
        std::fs::write(&counter, "0").unwrap();
        // Fails on the first 3 invocations ("database is locked"), succeeds
        // on the 4th — exactly the attempt budget release_with_retry now has.
        std::fs::write(
            &fake_chump,
            format!(
                "#!/usr/bin/env bash\n\
                 n=$(cat '{counter}')\n\
                 n=$((n + 1))\n\
                 echo \"$n\" > '{counter}'\n\
                 if [ \"$n\" -lt 4 ]; then exit 1; fi\n\
                 exit 0\n",
                counter = counter.display()
            ),
        )
        .unwrap();
        let mut perms = std::fs::metadata(&fake_chump).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_chump, perms).unwrap();

        let ambient = dir.join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", ambient.to_string_lossy().as_ref());

        let opts = DispatchOptions {
            gap_id: "RESILIENT-293-RETRY",
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: dir.to_path_buf(),
            mode: DispatchMode::Work,
        };
        let ws = ws_with_dir(&opts, dir.to_path_buf());

        let result = release_with_retry(&ws);
        assert!(
            result.is_ok(),
            "release_with_retry should survive 3 transient failures within its \
             4-attempt budget, got: {result:?}"
        );
        let final_count = std::fs::read_to_string(&counter).unwrap();
        assert_eq!(final_count.trim(), "4", "expected exactly 4 attempts");

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    // ── RESILIENT-203: opencode repo-size guard ───────────────────────────────

    /// Creates a git repo at `dir` with `n` tracked files committed, so
    /// `git ls-files` reports exactly `n`.
    fn init_git_repo_with_n_files(dir: &Path, n: usize) {
        let run = |args: &[&str]| {
            let status = Command::new("git")
                .args(args)
                .current_dir(dir)
                .status()
                .expect("spawn git");
            assert!(status.success(), "git {args:?} failed");
        };
        run(&["init", "-q"]);
        run(&["config", "user.email", "test@example.com"]);
        run(&["config", "user.name", "test"]);
        for i in 0..n {
            std::fs::write(dir.join(format!("file{i}.txt")), "x").unwrap();
        }
        run(&["add", "-A"]);
        run(&["commit", "-q", "-m", "init"]);
    }

    /// Below the threshold, the guard is a no-op.
    #[test]
    #[serial_test::serial(opencode_size_guard_env)]
    fn opencode_repo_size_guard_allows_small_repo() {
        let tmp = tempfile::TempDir::new().expect("create tempdir");
        init_git_repo_with_n_files(tmp.path(), 3);

        std::env::set_var("CHUMP_OPENCODE_MAX_FILES", "10");

        let result = opencode_repo_size_guard(tmp.path());

        std::env::remove_var("CHUMP_OPENCODE_MAX_FILES");
        assert!(result.is_ok(), "expected Ok for small repo, got {result:?}");
    }

    /// Above the threshold, the guard fails fast with a message pointing at
    /// the chump-local fallback — this is the behavior that replaces
    /// letting opencode hang at init until `wait_with_hang_detection`'s
    /// timeout expires (the RESILIENT-203 failure mode).
    #[test]
    #[serial_test::serial(opencode_size_guard_env)]
    fn opencode_repo_size_guard_blocks_large_repo() {
        let tmp = tempfile::TempDir::new().expect("create tempdir");
        init_git_repo_with_n_files(tmp.path(), 5);

        std::env::set_var("CHUMP_OPENCODE_MAX_FILES", "2");

        let result = opencode_repo_size_guard(tmp.path());

        std::env::remove_var("CHUMP_OPENCODE_MAX_FILES");
        let err = result.expect_err("expected Err for large repo");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("chump-local"),
            "expected fallback guidance in error, got: {msg}"
        );
    }

    /// INFRA-1964: `CHUMP_WORK_BACKEND=local` (and its `ollama`/`mlx`
    /// aliases) must route to [`WorkBackend::Local`], not fall through to
    /// the Anthropic-only Headless default — that fallthrough is exactly
    /// the mission-reality gap this gap closes.
    #[test]
    #[serial_test::serial(work_backend_env)]
    fn backend_from_env_selects_local_and_aliases() {
        for value in ["local", "ollama", "mlx"] {
            std::env::set_var("CHUMP_WORK_BACKEND", value);
            let backend = backend_from_env("".to_string(), "do the thing".to_string());
            std::env::remove_var("CHUMP_WORK_BACKEND");
            assert!(
                matches!(backend, WorkBackend::Local { .. }),
                "CHUMP_WORK_BACKEND={value:?} should select WorkBackend::Local, got {backend:?}"
            );
        }
    }

    #[test]
    #[serial_test::serial(work_backend_env)]
    fn backend_from_env_defaults_to_headless_when_unset() {
        std::env::remove_var("CHUMP_WORK_BACKEND");
        let backend = backend_from_env("".to_string(), "do the thing".to_string());
        assert!(matches!(backend, WorkBackend::Headless { .. }));
    }

    // ── RESILIENT-1612: hang detector advances on real activity ────────────

    /// Second-scale config: hang after `hang_secs` idle, poll every second,
    /// budget off so only the hang detector is under test.
    fn hang_test_cfg(hang_secs: u64) -> HangConfig {
        HangConfig {
            budget_secs: 0,
            hang_secs,
            activity_poll: Duration::from_secs(1),
            tick: Duration::from_millis(100),
            grace_secs: 1,
            tool_stall_secs: 0,
            load_paused_probe: None,
        }
    }

    /// ZERO-WASTE-133 AC1/AC3: a tool call (shell carrying the Claude Code
    /// tool-call marker) that outlives the stall limit is killed, reported
    /// once as ToolCallStalled, and the parent process continues to its end.
    #[test]
    fn zero_waste_133_stalled_tool_call_is_killed_and_agent_continues() {
        let td = tempfile::tempdir().unwrap();
        let cfg = HangConfig {
            budget_secs: 0,
            hang_secs: 0,
            activity_poll: Duration::from_secs(1),
            tick: Duration::from_millis(100),
            grace_secs: 1,
            tool_stall_secs: 1,
            load_paused_probe: None,
        };
        let marker = td.path().join("continued");
        let script = format!(
            "bash -c ': shell-snapshots; sleep 60; true'; touch '{}'",
            marker.display()
        );
        let (res, events, took) = run_hang(None, td.path(), &script, &cfg);
        assert!(res.unwrap().success());
        assert!(took < Duration::from_secs(30), "took {took:?}");
        assert!(marker.exists(), "agent did not continue after the kill");
        let stalled: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, HangEvent::ToolCallStalled { .. }))
            .collect();
        assert_eq!(stalled.len(), 1, "{events:?}");
    }

    fn spawn_sh(dir: &Path, script: &str) -> Child {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg(script).current_dir(dir);
        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::null());
        configure_child_lifetime(&mut cmd);
        cmd.spawn().expect("spawn sh")
    }

    fn run_hang(
        dir: Option<&Path>,
        script_dir: &Path,
        script: &str,
        cfg: &HangConfig,
    ) -> (Result<std::process::ExitStatus>, Vec<HangEvent>, Duration) {
        let child = spawn_sh(script_dir, script);
        let mut events = Vec::new();
        let t0 = std::time::Instant::now();
        let res = wait_with_hang_detection_cfg(
            child,
            "test-child",
            "RESILIENT-1612",
            dir,
            cfg,
            &mut |e| events.push(e),
        );
        (res, events, t0.elapsed())
    }

    fn git(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
            ])
            .args(args)
            .current_dir(dir)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .expect("git");
        assert!(st.success(), "git {args:?} failed");
    }

    /// AC1: a child that touches a file well inside the idle window survives
    /// past 2x the hang timeout (the old wall-clock detector killed it at
    /// exactly 1x), and exits on its own with success.
    #[test]
    fn hang_detector_active_child_survives_twice_the_timeout() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("seed.txt"), "0").unwrap();
        let cfg = hang_test_cfg(3);
        // Touches every 1s for ~7.5s total (> 2 x 3s), then exits 0.
        let script = "i=0; while [ $i -lt 7 ]; do sleep 1; echo $i > work.txt; i=$((i+1)); done";
        let (res, events, elapsed) = run_hang(Some(tmp.path()), tmp.path(), script, &cfg);
        let status = res.expect("active child must not be killed by the hang detector");
        assert!(status.success());
        assert!(elapsed >= Duration::from_secs(6), "child ran {elapsed:?}");
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, HangEvent::HangKill { .. })),
            "no hang kill expected, got {events:?}"
        );
    }

    /// AC1 contrast: a silent child is killed once it has been idle past the
    /// timeout.
    #[test]
    fn hang_detector_silent_child_is_killed() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("seed.txt"), "0").unwrap();
        let cfg = hang_test_cfg(2);
        let (res, events, elapsed) = run_hang(Some(tmp.path()), tmp.path(), "sleep 60", &cfg);
        let err = res.expect_err("silent child must be killed");
        assert!(
            format!("{err:#}").contains("no worktree activity"),
            "unexpected error: {err:#}"
        );
        assert!(elapsed < Duration::from_secs(15), "kill took {elapsed:?}");
        assert!(events.iter().any(|e| matches!(
            e,
            HangEvent::HangKill {
                committed: false,
                ..
            }
        )));
    }

    /// AC2: with no activity source the detector logs blind and does NOT
    /// fire at start+timeout — the child outlives the timeout and exits 0.
    #[test]
    fn hang_detector_blind_does_not_fire() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = hang_test_cfg(1);
        let missing = tmp.path().join("does-not-exist");
        for root in [None, Some(missing.as_path())] {
            let (res, events, elapsed) = run_hang(root, tmp.path(), "sleep 3", &cfg);
            let status = res.expect("blind detector must not kill");
            assert!(status.success());
            assert!(elapsed >= Duration::from_secs(3));
            assert!(
                matches!(events.first(), Some(HangEvent::Blind { .. })),
                "expected Blind event, got {events:?}"
            );
            assert!(!events
                .iter()
                .any(|e| matches!(e, HangEvent::HangKill { .. })));
        }
    }

    /// AC3: a child that commits and then goes silent is not aborted: the
    /// commit counts as activity, and when the idle timeout later fires the
    /// child is stopped with a SUCCESS status so the dispatch ships.
    #[test]
    fn hang_detector_committed_child_proceeds_to_ship() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        git(dir, &["init", "-q"]);
        std::fs::write(dir.join("a.txt"), "a").unwrap();
        git(dir, &["add", "a.txt"]);
        git(dir, &["commit", "-qm", "base"]);
        let cfg = hang_test_cfg(3);
        let script = "sleep 1; echo b > b.txt; \
             git add b.txt && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
             -c core.hooksPath=/dev/null commit -qm work; sleep 60";
        let (res, events, elapsed) = run_hang(Some(dir), dir, script, &cfg);
        let status = res.expect("committed child must not abort the dispatch");
        assert!(
            status.success(),
            "salvage must report success, got {status:?}"
        );
        // Commit landed at ~1s; killed only after a full idle window after it.
        assert!(elapsed >= Duration::from_secs(4), "fired at {elapsed:?}");
        assert!(elapsed < Duration::from_secs(20), "took {elapsed:?}");
        assert!(
            events.iter().any(|e| matches!(
                e,
                HangEvent::HangKill {
                    committed: true,
                    ..
                }
            )),
            "expected committed HangKill, got {events:?}"
        );
    }

    /// The probe ignores build output and git internals but sees a commit
    /// through the index / HEAD reflog.
    #[test]
    fn activity_probe_ignores_target_and_sees_commits() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        git(dir, &["init", "-q"]);
        std::fs::write(dir.join("a.txt"), "a").unwrap();
        git(dir, &["add", "a.txt"]);
        git(dir, &["commit", "-qm", "base"]);
        std::fs::create_dir_all(dir.join("target/debug")).unwrap();
        let probe = ActivityProbe::new(dir).expect("probe");
        let fp0 = probe.fingerprint().expect("fp");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(dir.join("target/debug/out.o"), "x").unwrap();
        assert_eq!(probe.fingerprint(), Some(fp0), "target/ must be ignored");
        // Commit an already-tracked change to an existing file without
        // touching the working tree after the probe: index + reflog move.
        std::fs::write(dir.join("a.txt"), "a2").unwrap();
        let fp1 = probe.fingerprint().unwrap();
        assert_ne!(fp1, fp0);
        std::thread::sleep(Duration::from_millis(20));
        git(dir, &["commit", "-qam", "c2"]);
        assert_ne!(
            probe.fingerprint(),
            Some(fp1),
            "commit must count as activity"
        );
    }

    // ── CREDIBLE-1577: dispatch refuses --auto-merge on gate files ──────────

    #[test]
    fn credible1577_auto_merge_gate_refuses_gate_paths_and_diffs_and_allows_non_gate() {
        // 1) Refuses when --paths touches any gate file glob.
        for gate_path in [
            ".github/workflows/ci.yml",
            "scripts/ci/test-arm-policy.sh",
            "scripts/git-hooks/pre-push",
            "scripts/coord/bot-merge.sh",
            "scripts/coord/code-reviewer-agent.sh",
            "crates/chump-preflight/src/preflight.rs",
            "crates/chump-ship/src/lib.rs",
            "scripts/ci/verified-wait.sh",
        ] {
            let res = check_auto_merge_gate_refusal(true, Some(gate_path), &[]);
            assert_eq!(
                res,
                Err(gate_path.to_string()),
                "expected --paths={gate_path} with auto_merge=true to be refused"
            );
        }

        // 2) Refuses when the branch diff touches a gate file even if --paths is None or clean.
        let diff = vec![
            "src/farmer_status.rs".to_string(),
            ".github/workflows/ci.yml".to_string(),
        ];
        assert_eq!(
            check_auto_merge_gate_refusal(true, Some("src/farmer_status.rs"), &diff),
            Err(".github/workflows/ci.yml".to_string()),
            "expected diff touching ci.yml with auto_merge=true to be refused"
        );

        // 3) Allows when auto_merge=true and neither --paths nor diff touches a gate file.
        let clean_diff = vec![
            "src/farmer_status.rs".to_string(),
            "docs/process/CODEREVIEW_POLICY.md".to_string(),
        ];
        assert_eq!(
            check_auto_merge_gate_refusal(true, Some("src/farmer_status.rs"), &clean_diff),
            Ok(()),
            "non-gate paths and diff must be allowed"
        );

        // 4) Allows when auto_merge=false even if --paths and diff touch gate files.
        assert_eq!(
            check_auto_merge_gate_refusal(
                false,
                Some("scripts/coord/bot-merge.sh"),
                &[".github/workflows/ci.yml".to_string()]
            ),
            Ok(()),
            "auto_merge=false must never be refused by the auto-merge gate guard"
        );
    }

    #[test]
    fn credible1577_workspace_gate_emits_dispatch_auto_merge_refused_event() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let res = check_workspace_auto_merge_gate(
            root,
            "CREDIBLE-1577",
            true,
            Some("src/main.rs,scripts/git-hooks/pre-push"),
        );
        assert_eq!(res, Err("scripts/git-hooks/pre-push".to_string()));

        let amb = root.join(".chump-locks/ambient.jsonl");
        let body = std::fs::read_to_string(&amb).expect("ambient.jsonl written");
        let v: serde_json::Value =
            serde_json::from_str(body.lines().next().expect("1 line")).expect("valid json");
        assert_eq!(v["kind"], "dispatch_auto_merge_refused");
        assert_eq!(v["gap_id"], "CREDIBLE-1577");
        assert_eq!(v["gate_file"], "scripts/git-hooks/pre-push");
    }

    // ── INFRA-8114 / RESILIENT-1494 / RESILIENT-1642 / RESILIENT-1640 tests ──

    #[test]
    fn infra_8114_resume_refuses_to_skip_implement_on_zero_commit_branch() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        git(dir, &["init", "-q", "-b", "main"]);
        std::fs::write(dir.join("seed.txt"), "base").unwrap();
        git(dir, &["add", "seed.txt"]);
        git(dir, &["commit", "-qm", "base"]);
        git(dir, &["update-ref", "refs/remotes/origin/main", "HEAD"]);
        git(dir, &["checkout", "-qb", "claude/infra-8114"]);

        // Zero commits ahead of origin/main → must NOT skip IMPLEMENT.
        assert!(
            !branch_has_commits_ahead(dir, "origin/main", "claude/infra-8114"),
            "empty branch must report 0 commits ahead of origin/main"
        );
        assert!(
            !can_resume_skip_implement(dir, "origin/main", "claude/infra-8114"),
            "INFRA-8114: resume must not skip IMPLEMENT on a zero-commit branch"
        );

        // Once >= 1 commit lands on the branch, resume may skip IMPLEMENT.
        std::fs::write(dir.join("work.txt"), "implemented").unwrap();
        git(dir, &["add", "work.txt"]);
        git(dir, &["commit", "-qm", "feat: implement gap"]);
        assert!(
            branch_has_commits_ahead(dir, "origin/main", "claude/infra-8114"),
            "branch with 1 commit must report ahead of origin/main"
        );
        assert!(
            can_resume_skip_implement(dir, "origin/main", "claude/infra-8114"),
            "INFRA-8114: resume may skip IMPLEMENT once >= 1 commit exists"
        );
    }

    #[test]
    #[serial_test::serial(oauth_env)]
    fn infra_8114_resilient_1494_oauth_token_loaded_from_file_when_absent_in_env() {
        let tmp = tempfile::tempdir().unwrap();
        let tok_file = tmp.path().join("oauth-token.json");
        let expected = format!("sk-ant-oat01-{}", "unit-test-token-fixture");
        std::fs::write(
            &tok_file,
            format!("{{\"token\":\"{expected}\",\"source\":\"test\"}}"),
        )
        .unwrap();

        let prev_tok = std::env::var("CLAUDE_CODE_OAUTH_TOKEN").ok();
        let prev_file = std::env::var("CHUMP_OAUTH_TOKEN_FILE").ok();
        std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
        std::env::set_var("CHUMP_OAUTH_TOKEN_FILE", &tok_file);

        let mut cmd = Command::new("claude");
        let resolved = ensure_oauth_token_env(Some(&mut cmd));

        assert_eq!(resolved.as_deref(), Some(expected.as_str()));
        assert_eq!(
            std::env::var("CLAUDE_CODE_OAUTH_TOKEN").ok().as_deref(),
            Some(expected.as_str())
        );
        let cmd_envs: Vec<(String, String)> = cmd
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_string(), v?.to_str()?.to_string())))
            .collect();
        assert!(
            cmd_envs
                .iter()
                .any(|(k, v)| k == "CLAUDE_CODE_OAUTH_TOKEN" && v == &expected),
            "expected CLAUDE_CODE_OAUTH_TOKEN on Command env, got {cmd_envs:?}"
        );

        match prev_tok {
            Some(v) => std::env::set_var("CLAUDE_CODE_OAUTH_TOKEN", v),
            None => std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN"),
        }
        match prev_file {
            Some(v) => std::env::set_var("CHUMP_OAUTH_TOKEN_FILE", v),
            None => std::env::remove_var("CHUMP_OAUTH_TOKEN_FILE"),
        }
    }

    #[test]
    fn resilient_1494_canonical_gap_resolves_from_main_checkout_and_fails_loud_when_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let main_repo = tmp.path().join("main-repo");
        std::fs::create_dir_all(&main_repo).unwrap();
        git(&main_repo, &["init", "-q", "-b", "main"]);
        std::fs::write(main_repo.join("README.md"), "init\n").unwrap();
        git(&main_repo, &["add", "README.md"]);
        git(&main_repo, &["commit", "-qm", "init"]);

        // Seed a gap into the canonical store at main_repo/.chump/state.db.
        let store = chump_gap_store::GapStore::open(&main_repo).expect("open canonical store");
        let gap_id = store
            .reserve(
                "RESILIENT",
                "RESILIENT-1494 canonical store test",
                "P1",
                "m",
            )
            .expect("reserve gap");
        drop(store);

        // Create a linked worktree with its own empty .chump/ directory.
        let wt = tmp.path().join("wt-resilient-1494");
        git(
            &main_repo,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "claude/resilient-1494",
                wt.to_str().unwrap(),
                "main",
            ],
        );
        std::fs::create_dir_all(wt.join(".chump")).unwrap();

        // 1. Resolving from the linked worktree finds the gap in main_repo's canonical state.db.
        let loaded = crate::dispatch_repair::load_canonical_gap(&wt, &gap_id)
            .expect("linked worktree must resolve gap from canonical store");
        assert_eq!(loaded.id, gap_id);
        assert_eq!(loaded.effort, "m");

        // 2. A missing gap ID fails loud (Err) instead of returning an empty/fallback prompt.
        let err = crate::dispatch_repair::build_auto_prompt_checked("RESILIENT-999999", &wt, None)
            .expect_err("missing gap must fail loud");
        assert!(
            err.contains("RESILIENT-1494") && err.contains("not found in canonical gap store"),
            "unexpected error: {err}"
        );
    }

    #[test]
    #[serial_test::serial(budget_env)]
    fn resilient_1494_budget_scales_with_effort_and_honors_env_overrides() {
        assert_eq!(budget_secs_for_effort("xs"), 1200);
        assert_eq!(budget_secs_for_effort("s"), 2400);
        assert_eq!(budget_secs_for_effort("m"), 3600);
        assert_eq!(budget_secs_for_effort("l"), 5400);
        assert_eq!(budget_secs_for_effort("xl"), 5400);
        assert_eq!(budget_secs_for_effort("unknown"), 5400);
        assert_eq!(budget_secs_for_effort(""), 5400);
        const {
            assert!(
                DEFAULT_SUBAGENT_BUDGET_SECS >= 1800,
                "default subagent budget must be >= 1800s"
            );
        }

        std::env::remove_var("CHUMP_SUBAGENT_BUDGET_S");
        std::env::remove_var("CHUMP_DISPATCH_TIMEOUT_SECS");
        std::env::remove_var("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S");
        assert_eq!(resolve_subagent_budget_secs(Some("xs")), 1200);
        assert_eq!(resolve_subagent_budget_secs(Some("m")), 3600);
        assert_eq!(
            resolve_subagent_budget_secs(None),
            DEFAULT_SUBAGENT_BUDGET_SECS
        );

        std::env::set_var("CHUMP_DISPATCH_TIMEOUT_SECS", "2700");
        assert_eq!(resolve_subagent_budget_secs(Some("xs")), 2700);
        std::env::set_var("CHUMP_SUBAGENT_BUDGET_S", "4200");
        assert_eq!(resolve_subagent_budget_secs(Some("xs")), 4200);
        std::env::remove_var("CHUMP_SUBAGENT_BUDGET_S");
        std::env::remove_var("CHUMP_DISPATCH_TIMEOUT_SECS");
    }

    #[test]
    fn resilient_1494_budget_clock_pauses_while_load_exceeds_nproc() {
        assert!(is_load_exceeding_nproc(4.5, 4));
        assert!(!is_load_exceeding_nproc(4.0, 4));
        assert!(!is_load_exceeding_nproc(2.0, 4));

        // With budget_secs=1 and load_paused_probe always returning true
        // (simulating 1m load > nproc), a 2.5s child must NOT be killed at 1s.
        fn always_overloaded() -> bool {
            true
        }
        let td = tempfile::tempdir().unwrap();
        let cfg = HangConfig {
            budget_secs: 1,
            hang_secs: 0,
            activity_poll: Duration::from_secs(1),
            tick: Duration::from_millis(100),
            grace_secs: 1,
            tool_stall_secs: 0,
            load_paused_probe: Some(always_overloaded),
        };
        let (res, events, elapsed) = run_hang(None, td.path(), "sleep 2", &cfg);
        let status = res.expect("child should survive when budget clock is paused by high load");
        assert!(status.success());
        assert!(elapsed >= Duration::from_secs(2));
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, HangEvent::BudgetKill { .. })),
            "budget kill must not fire while load > nproc pauses clock, got {events:?}"
        );
    }

    #[test]
    fn resilient_1494_pre_sigterm_salvages_wip_to_origin_refs_stash_and_stashed_work_md() {
        let tmp = tempfile::tempdir().unwrap();
        let origin = tmp.path().join("origin.git");
        let worktree = tmp.path().join("worktree");
        std::fs::create_dir_all(&origin).unwrap();
        std::fs::create_dir_all(&worktree).unwrap();

        let st = Command::new("git")
            .args(["init", "--quiet", "--bare"])
            .arg(&origin)
            .status()
            .unwrap();
        assert!(st.success());

        git(&worktree, &["init", "-q", "-b", "main"]);
        std::fs::write(worktree.join("README.md"), "base\n").unwrap();
        git(&worktree, &["add", "README.md"]);
        git(&worktree, &["commit", "-qm", "init"]);
        git(
            &worktree,
            &["remote", "add", "origin", origin.to_str().unwrap()],
        );
        git(&worktree, &["push", "-q", "origin", "main"]);
        git(&worktree, &["checkout", "-qb", "claude/resilient-1494"]);

        // Simulate a child that modifies a file and then stalls past the 1s budget.
        let cfg = HangConfig {
            budget_secs: 1,
            hang_secs: 0,
            activity_poll: Duration::from_secs(1),
            tick: Duration::from_millis(100),
            grace_secs: 1,
            tool_stall_secs: 0,
            load_paused_probe: None,
        };
        let script = "echo 'partial wip change' >> README.md; sleep 60";
        let (_res, events, _elapsed) = run_hang(Some(&worktree), &worktree, script, &cfg);
        assert!(
            events
                .iter()
                .any(|e| matches!(e, HangEvent::BudgetKill { .. })),
            "expected BudgetKill event, got {events:?}"
        );

        // Verify wip: commit landed on the worktree before SIGTERM.
        let log_out = Command::new("git")
            .arg("-C")
            .arg(&worktree)
            .args(["log", "-1", "--pretty=%s"])
            .output()
            .unwrap();
        let subj = String::from_utf8_lossy(&log_out.stdout).trim().to_string();
        assert!(
            subj.starts_with("wip("),
            "expected wip: commit subject before budget kill, got: {subj}"
        );

        // Verify refs/stash/<gap>-<ts> was pushed to origin.
        let refs_out = Command::new("git")
            .arg("-C")
            .arg(&origin)
            .args(["for-each-ref", "--format=%(refname)", "refs/stash/"])
            .output()
            .unwrap();
        let refs = String::from_utf8_lossy(&refs_out.stdout);
        assert!(
            refs.contains("refs/stash/resilient-1612-"),
            "expected refs/stash/<gap>-<ts> in origin, got: {refs}"
        );

        // Verify docs/process/STASHED_WORK.md has the appended entry.
        let manifest = std::fs::read_to_string(worktree.join("docs/process/STASHED_WORK.md"))
            .expect("docs/process/STASHED_WORK.md must be written");
        assert!(
            manifest.contains("refs/stash/resilient-1612-") && manifest.contains("RESILIENT-1612"),
            "STASHED_WORK.md missing stash row: {manifest}"
        );
    }

    #[test]
    #[serial_test::serial(cargo_target_env)]
    fn resilient_1642_headless_command_skeleton_exports_shared_cargo_target_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let custom_shared = tmp.path().join("shared-target");
        let prev = std::env::var("CARGO_TARGET_DIR").ok();
        std::env::set_var("CARGO_TARGET_DIR", &custom_shared);

        let resolved = resolve_shared_cargo_target_dir();
        assert_eq!(resolved, custom_shared);

        let cmd = headless_command_skeleton("claude-sonnet-4-6");
        let envs: Vec<(String, String)> = cmd
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_string(), v?.to_str()?.to_string())))
            .collect();
        assert!(
            envs.iter()
                .any(|(k, v)| k == "CARGO_TARGET_DIR" && Path::new(v) == custom_shared.as_path()),
            "RESILIENT-1642: headless_command_skeleton must export CARGO_TARGET_DIR, got {envs:?}"
        );

        // Worktree-local target path in CARGO_TARGET_DIR must be rejected in favor of shared target.
        std::env::set_var("CARGO_TARGET_DIR", "/repo/.claude/worktrees/foo/target");
        let fallback = resolve_shared_cargo_target_dir();
        assert!(
            !fallback.to_string_lossy().contains(".claude/worktrees/"),
            "resolver must reject worktree-private target dir, got {}",
            fallback.display()
        );

        match prev {
            Some(v) => std::env::set_var("CARGO_TARGET_DIR", v),
            None => std::env::remove_var("CARGO_TARGET_DIR"),
        }
    }

    #[test]
    #[serial_test::serial(cargo_target_env)]
    fn credible_1585_headless_command_skeleton_scrubs_non_allowlisted_secrets() {
        let forbidden = [
            ("SUPABASE_SERVICE_ROLE_KEY", "fake-secret"),
            ("POSTGRES_PASSWORD", "fake-db-pass"),
            ("OCI_CLI_KEY_CONTENT", "fake-oci-key"),
            ("AWS_SECRET_ACCESS_KEY", "fake-aws-secret"),
            ("STRIPE_SECRET_KEY", "fake-stripe-key"),
            ("CHUMP_SUBSTRATE_DB_PASSWORD", "fake-substrate-db-pass"),
        ];
        let allowed = [
            ("ANTHROPIC_API_KEY", "fake-anthropic-key"),
            ("GH_TOKEN", "fake-gh-token"),
            ("CHUMP_SESSION_ID", "test-credible-1585-sess"),
        ];
        let mut prev: Vec<(&str, Option<String>)> = Vec::new();
        for &(k, v) in forbidden.iter().chain(allowed.iter()) {
            prev.push((k, std::env::var(k).ok()));
            std::env::set_var(k, v);
        }

        let skel = headless_command_skeleton("claude-sonnet-4-6");
        let skel_envs: std::collections::BTreeMap<String, String> = skel
            .get_envs()
            .filter_map(|(k, v)| Some((k.to_str()?.to_string(), v?.to_str()?.to_string())))
            .collect();

        for &(bad_k, _) in &forbidden {
            assert!(
                !skel_envs.contains_key(bad_k),
                "CREDIBLE-1585: forbidden secret {bad_k} leaked into headless_command_skeleton env"
            );
        }
        for &(ok_k, ok_v) in &allowed {
            assert_eq!(
                skel_envs.get(ok_k).map(String::as_str),
                Some(ok_v),
                "CREDIBLE-1585: allowlisted {ok_k} missing from headless_command_skeleton env"
            );
        }

        // Also verify a real spawned child process sees the scrubbed environment.
        let mut child_cmd = Command::new("env");
        scrub_headless_claude_env(&mut child_cmd);
        let out = child_cmd.output().expect("spawn env");
        assert!(out.status.success());
        let child_stdout = String::from_utf8_lossy(&out.stdout);
        for &(bad_k, _) in &forbidden {
            assert!(
                !child_stdout
                    .lines()
                    .any(|l| l.starts_with(&format!("{bad_k}="))),
                "CREDIBLE-1585: spawned child inherited forbidden secret {bad_k}"
            );
        }
        for &(ok_k, ok_v) in &allowed {
            assert!(
                child_stdout.lines().any(|l| l == format!("{ok_k}={ok_v}")),
                "CREDIBLE-1585: spawned child missing allowlisted {ok_k}={ok_v}"
            );
        }

        for (k, old) in prev {
            match old {
                Some(v) => std::env::set_var(k, v),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    #[serial_test::serial(cargo_target_env)]
    fn infra_8083_dispatch_external_repo_routes_to_improve_without_bot_merge() {
        let tmp = tempfile::tempdir().unwrap();
        let main_repo = tmp.path().join("main-repo");
        std::fs::create_dir_all(main_repo.join("scripts/coord")).unwrap();
        git(&main_repo, &["init", "-q", "-b", "main"]);
        std::fs::write(main_repo.join("README.md"), "init\n").unwrap();
        git(&main_repo, &["add", "README.md"]);
        git(&main_repo, &["commit", "-qm", "init"]);

        // Write a poison bot-merge.sh that writes a marker file if executed.
        let marker = tmp.path().join("bot-merge-ran.marker");
        let bot_merge_script = main_repo.join("scripts/coord/bot-merge.sh");
        std::fs::write(
            &bot_merge_script,
            format!(
                "#!/usr/bin/env bash\necho ran > '{}'\nexit 1\n",
                marker.display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&bot_merge_script).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&bot_merge_script, perms).unwrap();
        }

        // Seed an external_repo gap in the canonical GapStore.
        let store = chump_gap_store::GapStore::open(&main_repo).expect("open canonical store");
        let gap_id = store
            .reserve("INFRA", "INFRA-8083 external routing fixture", "P1", "s")
            .expect("reserve gap");
        store
            .set_fields(
                &gap_id,
                chump_gap_store::GapFieldUpdate {
                    skills_required: Some("external_repo:repairman29/upshift-cli".to_string()),
                    ..Default::default()
                },
            )
            .expect("set skills_required");
        drop(store);

        let prev_dry = std::env::var("CHUMP_DISPATCH_EXTERNAL_DRY_RUN").ok();
        std::env::set_var("CHUMP_DISPATCH_EXTERNAL_DRY_RUN", "1");

        let opts = DispatchOptions {
            gap_id: &gap_id,
            work: WorkBackend::Interactive,
            auto_merge: false,
            skip_tests: true,
            paths: None,
            repo_root: main_repo.clone(),
            mode: DispatchMode::Work,
        };
        let outcome = run(opts).expect("dispatch on external_repo gap should succeed");

        match prev_dry {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_EXTERNAL_DRY_RUN", v),
            None => std::env::remove_var("CHUMP_DISPATCH_EXTERNAL_DRY_RUN"),
        }

        assert_eq!(outcome.branch, "external:repairman29/upshift-cli");
        assert_eq!(outcome.result, ShipResult::Shipped { pr_number: 0 });
        assert!(
            !marker.exists(),
            "in-repo bot-merge.sh must NEVER run for an external_repo gap"
        );
        assert!(
            !main_repo.join(".claude/worktrees").exists(),
            "in-repo worktree must not be created for an external_repo gap"
        );
    }

    #[cfg(unix)]
    #[test]
    fn infra_8083_kill_child_process_group_terminates_grandchild() {
        let tmp = tempfile::tempdir().unwrap();
        let pid_file = tmp.path().join("grandchild.pid");
        let script = format!("sleep 300 &\necho $! > '{}'\nwait\n", pid_file.display());
        let mut child = spawn_sh(tmp.path(), &script);

        // Wait up to 3s for the grandchild PID file to appear.
        let mut grandchild_pid: Option<u32> = None;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            if let Ok(raw) = std::fs::read_to_string(&pid_file) {
                if let Ok(p) = raw.trim().parse::<u32>() {
                    if p > 1 {
                        grandchild_pid = Some(p);
                        break;
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        let gpid = grandchild_pid.expect("grandchild sleep pid must be recorded");
        assert!(
            child_is_alive(gpid),
            "grandchild pid {gpid} should be alive before kill_child_process_group"
        );

        kill_child_process_group(&mut child);

        // Poll briefly in case reaping takes a few ms.
        let mut dead = false;
        let wait_start = std::time::Instant::now();
        while wait_start.elapsed() < Duration::from_secs(2) {
            if !child_is_alive(gpid) {
                dead = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        assert!(
            dead,
            "grandchild pid {gpid} must be terminated by kill_child_process_group"
        );
    }

    #[test]
    fn infra_8177_p0_small_or_xs_routes_to_at_least_sonnet_never_haiku() {
        assert_eq!(
            select_model_for_gap("P0", "s", "", "normal title"),
            "sonnet"
        );
        assert_eq!(
            select_model_for_gap("P0", "xs", "", "normal title"),
            "sonnet"
        );
        assert_eq!(
            select_model_for_gap("critical", "xs", "", "urgent fix"),
            "sonnet"
        );
        assert_eq!(select_model_for_gap("P0", "xl", "", "large P0"), "opus");
        assert_eq!(
            enforce_routing_floor("haiku", "P0", "", "small P0"),
            "sonnet"
        );
        assert_eq!(
            enforce_routing_floor("claude-haiku-4-5", "P0", "", "small P0"),
            "sonnet"
        );
    }

    #[test]
    fn infra_8177_p2_keystone_or_unwedge_with_xs_routes_to_at_least_sonnet() {
        assert_eq!(
            select_model_for_gap("P2", "xs", "rust,keystone", "foundation piece"),
            "sonnet"
        );
        assert_eq!(
            select_model_for_gap("P2", "s", "unwedge", "fix stuck queue"),
            "sonnet"
        );
        assert_eq!(
            select_model_for_gap("P2", "xs", "", "Keystone: wire planner rank"),
            "sonnet"
        );
        assert_eq!(
            enforce_routing_floor("haiku", "P2", "keystone", "tagged gap"),
            "sonnet"
        );
    }

    #[test]
    fn infra_8177_normal_p2_or_p3_small_routes_to_haiku() {
        assert_eq!(
            select_model_for_gap("P2", "s", "rust,docs", "routine cleanup"),
            "haiku"
        );
        assert_eq!(
            select_model_for_gap("P3", "xs", "", "minor doc typo"),
            "haiku"
        );
        assert_eq!(
            select_model_for_gap("P2", "m", "", "medium feature"),
            "sonnet"
        );
        assert_eq!(
            enforce_routing_floor("haiku", "P2", "rust", "routine cleanup"),
            "haiku"
        );
    }

    /// CREDIBLE-1566: repair dispatch lease records the PR's head branch so
    /// verify-claim-branch and off-rails guards pass without Off-Rails-Bypass:,
    /// and CHUMP_DISPATCH_GAP is allowlisted for headless child spawns.
    #[test]
    #[serial_test::serial(ambient_env)]
    fn credible_1566_repair_lease_records_branch_and_allowlists_dispatch_gap() {
        assert!(is_allowlisted_headless_env_key("CHUMP_DISPATCH_GAP"));
        let tmp = tempfile::tempdir().expect("tempdir");
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_sid = std::env::var("CHUMP_SESSION_ID").ok();
        std::env::set_var("CHUMP_REPO", tmp.path());
        std::env::set_var("CHUMP_SESSION_ID", "dispatch-credible-1566-test");

        let lease = crate::agent_lease::claim_gap_with_branch(
            "CREDIBLE-1566",
            &["src/dispatch.rs"],
            3600,
            "dispatch",
            Some("claude/repair-pr-5555"),
        )
        .expect("claim_gap_with_branch");
        assert_eq!(lease.branch.as_deref(), Some("claude/repair-pr-5555"));

        let lease_file = tmp
            .path()
            .join(".chump-locks")
            .join("dispatch-credible-1566-test.json");
        let on_disk: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease_file).expect("read lease"))
                .expect("parse lease json");
        assert_eq!(
            on_disk.get("branch").and_then(|v| v.as_str()),
            Some("claude/repair-pr-5555")
        );

        let verdict = crate::verify_claim_branch::verify(
            "claude/repair-pr-5555",
            "dispatch-credible-1566-test",
            &[lease],
        );
        assert!(matches!(
            verdict,
            crate::verify_claim_branch::Verdict::Ok { ref gap_id } if gap_id == "CREDIBLE-1566"
        ));

        match prev_repo {
            Some(v) => std::env::set_var("CHUMP_REPO", v),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        match prev_sid {
            Some(v) => std::env::set_var("CHUMP_SESSION_ID", v),
            None => std::env::remove_var("CHUMP_SESSION_ID"),
        }
    }
}
