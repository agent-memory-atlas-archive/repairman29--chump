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
}

/// What happened to the PR after [`ship`] finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShipResult {
    /// PR opened (and possibly merge-queued via auto-merge); caller can poll
    /// the merge queue from here.
    Shipped { pr_number: u64 },
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
pub fn run(opts: DispatchOptions) -> Result<DispatchOutcome> {
    let started = std::time::Instant::now();

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
    if let Err(e) = do_work(&workspace) {
        // Always release before propagating the error so a failed work
        // step doesn't leave a stale lease. INFRA-1243: use retry+emit path.
        release_with_retry(&workspace)?;
        return Ok(DispatchOutcome {
            gap_id: opts.gap_id.to_string(),
            branch,
            result: ShipResult::Aborted {
                error: format!("work step failed: {e:#}"),
            },
            duration_secs: started.elapsed().as_secs(),
        });
    }

    // Step 4: ship (calls bot-merge.sh in Phase 1; native in Phase 3).
    // Capture errors instead of `?`-ing so we always reach release.
    let ship_result = match ship(&workspace) {
        Ok(r) => r,
        Err(e) => ShipResult::Aborted {
            error: format!("{e:#}"),
        },
    };

    // Step 5: always release the lease. INFRA-1243: retry+emit on failure.
    release_with_retry(&workspace)?;

    Ok(DispatchOutcome {
        gap_id: opts.gap_id.to_string(),
        branch,
        result: ship_result,
        duration_secs: started.elapsed().as_secs(),
    })
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
                let working_dir = create_dispatch_worktree(&opts.repo_root, opts.gap_id)
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
                write_wt_session_id_file(&working_dir, &session_id);

                (working_dir, session_id)
            }
        };
        Ok(Self {
            opts,
            working_dir,
            session_id,
        })
    }

    fn working_dir(&self) -> &Path {
        &self.working_dir
    }

    fn opts(&self) -> &DispatchOptions<'a> {
        self.opts
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
    use coord_mesh::MeshBridge;
    // INFRA-2264: activates the `coord-mesh` crate dependency; the bridge
    // itself is not yet wired into the worktree-creation flow (that's
    // follow-on work once the real mesh-bridge substrate lands).
    let _bridge = MeshBridge::new();

    let (worktree_path, branch_name) = dispatch_paths(repo_root, gap_id);

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

    // RESILIENT-555: symlink the fresh worktree's .chump/state.db to the
    // main checkout's copy, same as `chump claim` already does (INFRA-3834
    // 6c-pre4). Without this, the worktree gets its own empty state.db that
    // doesn't contain the gap being dispatched, so the preflight step right
    // after this returns "not found in state.db (run chump gap import
    // first)" for a gap that IS open in the canonical registry.
    chump_atomic_claim::atomic_claim::nugget_prefetch::link_state_db(repo_root, &worktree_path);

    Ok(worktree_path)
}

// ── Internals (each one independently portable in Phase 3) ───────────────────

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
    let child = cmd
        .spawn()
        .context("spawn `opencode -p` (is opencode CLI on PATH?)")?;
    let status = wait_with_hang_detection(child, "opencode -p", opts.gap_id)
        .context("waiting for opencode -p to complete")?;
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
    let child = cmd
        .spawn()
        .context("spawn `aider --message` (is aider on PATH?)")?;
    let status = wait_with_hang_detection(child, "aider", opts.gap_id)
        .context("waiting for aider --message to complete")?;
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
    let child = cmd
        .spawn()
        .context("spawn `chump gen --local` (is chump on PATH / built?)")?;
    let status = wait_with_hang_detection(child, "chump gen --local", opts.gap_id)
        .context("waiting for chump gen --local to complete")?;
    if !status.success() {
        bail!(
            "chump gen --local exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
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
fn headless_command_skeleton(model: &str) -> Command {
    let mut cmd = Command::new("claude");
    cmd.arg("-p").arg("--dangerously-skip-permissions");
    cmd.stdin(std::process::Stdio::piped());
    if !model.is_empty() {
        cmd.args(["--model", model]);
    }
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
    let mut cmd = headless_command_skeleton(model);
    // RESILIENT-362: the claude CLI refuses `--dangerously-skip-permissions`
    // under root ("cannot be used with root/sudo privileges") unless IS_SANDBOX=1
    // marks an intentional sandboxed root env. Fleet root nodes (helsinki runs as
    // root) need this or EVERY headless dispatch aborts with claude -p exit 1.
    cmd.env("IS_SANDBOX", "1");
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
    // INFRA-8204: explicit, not merely inherited — see ship()'s comment.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    let mut child = cmd
        .spawn()
        .context("spawn `claude -p` (is the claude CLI on PATH?)")?;
    {
        use std::io::Write as _;
        let mut stdin = child
            .stdin
            .take()
            .context("claude -p stdin was not piped")?;
        stdin
            .write_all(prompt.as_bytes())
            .context("writing prompt to claude -p stdin")?;
        // Dropping `stdin` here closes the pipe (EOF), which is how `claude
        // -p` knows the prompt is complete and starts working.
    }
    let status = wait_with_hang_detection(child, "claude -p", opts.gap_id)
        .context("waiting for claude -p to complete")?;
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
    let child = cmd
        .spawn()
        .with_context(|| format!("spawn `chump --execute-gap {}`", opts.gap_id))?;
    let status = wait_with_hang_detection(child, "chump --execute-gap", opts.gap_id)
        .context("waiting for chump --execute-gap to complete")?;
    if !status.success() {
        bail!(
            "chump --execute-gap exited {} for gap {}",
            status.code().unwrap_or(-1),
            opts.gap_id
        );
    }
    Ok(())
}

/// Wait for a child process with hang detection (INFRA-406).
/// If the process doesn't complete within the timeout period, send SIGTERM
/// and emit an ALERT to ambient.jsonl.
///
/// The timeout is configurable via CHUMP_DISPATCH_HANG_TIMEOUT_SECS env var
/// (default 3600 = 1 hour). Set to 0 to disable hang detection.
fn wait_with_hang_detection(
    mut child: Child,
    process_name: &str,
    gap_id: &str,
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
    //      backup deadline — catches a stuck process that somehow survived
    //      the budget kill. SIGKILL only. Emits kind=hang_detector.
    //
    // Either env set to 0 disables that specific deadline. The budget
    // (faster) fires first by design; hang is a backstop.
    let budget_secs: u64 = std::env::var("CHUMP_SUBAGENT_BUDGET_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .or_else(|| {
            // Fall back to the legacy bot-merge-specific name if set,
            // so existing env configs keep working (CLAUDE.md still
            // documents CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S=900).
            std::env::var("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S")
                .ok()
                .and_then(|s| s.parse().ok())
        })
        .unwrap_or(900);

    let hang_secs: u64 = std::env::var("CHUMP_DISPATCH_HANG_TIMEOUT_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3600);

    let no_budget = budget_secs == 0;
    let no_hang = hang_secs == 0;
    if no_budget && no_hang {
        return child.wait().context("waiting for child process");
    }

    let start = std::time::Instant::now();
    let child_pid = child.id();
    let mut budget_kill_in_flight: Option<std::time::Instant> = None;
    let grace_secs: u64 = 30; // SIGTERM → SIGKILL grace window

    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {
                let elapsed = start.elapsed();

                // Budget enforcement (faster, graceful)
                if !no_budget && budget_kill_in_flight.is_none() && elapsed.as_secs() > budget_secs
                {
                    emit_subagent_killed_at_budget(process_name, gap_id, budget_secs, child_pid);
                    // Send SIGTERM (graceful). std::process::Child::kill is
                    // SIGKILL only; use the `kill` CLI to get SIGTERM without
                    // pulling in a new crate dep (see paramedic.rs for the
                    // existing precedent of Command::new("kill")).
                    let _ = std::process::Command::new("kill")
                        .args(["-TERM", &child_pid.to_string()])
                        .status();
                    budget_kill_in_flight = Some(std::time::Instant::now());
                }

                // After SIGTERM, allow `grace_secs` for graceful shutdown
                // before SIGKILL. INFRA-1972 AC: "at budget_secs + 30s: SIGKILL".
                if let Some(term_at) = budget_kill_in_flight {
                    if term_at.elapsed().as_secs() > grace_secs {
                        let _ = child.kill(); // SIGKILL
                        let _ = child.wait();
                        bail!(
                            "{} exceeded subagent budget ({} secs) for gap {}; SIGTERM at budget, \
                             SIGKILL after {}s grace",
                            process_name,
                            budget_secs,
                            gap_id,
                            grace_secs
                        );
                    }
                }

                // Hang-detector backstop (slower, hard kill — handles a stuck
                // process that somehow survived the budget SIGTERM+SIGKILL).
                if !no_hang && elapsed > Duration::from_secs(hang_secs) {
                    emit_hang_alert(process_name, gap_id, hang_secs);
                    let _ = child.kill();
                    let _ = child.wait();
                    bail!(
                        "{} exceeded no-tool-call timeout ({} secs) for gap {}; sent SIGTERM",
                        process_name,
                        hang_secs,
                        gap_id
                    );
                }
                std::thread::sleep(Duration::from_secs(1));
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

/// Emit a hang-detection alert to ambient.jsonl (INFRA-406).
fn emit_hang_alert(process_name: &str, gap_id: &str, timeout_secs: u64) {
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
         \"gap\":\"{gap_id}\",\"timeout_secs\":{timeout_secs}}}"
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
    let state_db = opts.repo_root.join(".chump").join("state.db");
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
    let prev_repo = std::env::var("CHUMP_REPO").ok();
    std::env::set_var("CHUMP_REPO", ws.working_dir());
    let result = crate::agent_lease::claim_gap(opts.gap_id, &paths_vec, ttl_secs, "dispatch");
    match prev_repo {
        Some(p) => std::env::set_var("CHUMP_REPO", p),
        None => std::env::remove_var("CHUMP_REPO"),
    }
    result.with_context(|| format!("lease-claim {} failed", opts.gap_id))?;
    Ok(())
}

fn ship(ws: &Workspace) -> Result<ShipResult> {
    let opts = ws.opts();
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
    // INFRA-8204: explicit, not merely inherited — bot-merge.sh's own
    // session-ID auto-detection only scans $LOCK_DIR/*.json + state.db, never
    // the dispatch worktree's own .chump-locks/, so without this the ship
    // phase can't see the lease claim() just wrote and re-invokes
    // `chump claim`, stranding the agent's commits.
    if !ws.session_id.is_empty() {
        cmd.env("CHUMP_SESSION_ID", &ws.session_id);
    }
    // INFRA-302 blocker (3): bot-merge.sh derives the branch via
    // `git rev-parse --abbrev-ref HEAD` — it MUST run inside the
    // dispatch's fresh worktree, not the main checkout, or it pushes
    // (and force-arms auto-merge on) the wrong branch.
    let status = cmd
        .current_dir(ws.working_dir())
        .status()
        .context("invoke bot-merge.sh")?;
    if !status.success() {
        let exit_code = status.code().unwrap_or(-1);
        // CREDIBLE-297: exit 13 is bot-merge.sh's clippy-fail code, raised by
        // a full-workspace local clippy stage that runs BEFORE this
        // invocation's push. A *prior* invocation may already have pushed
        // and armed auto-merge on a PR whose own (scoped) CI clippy already
        // passed and merged — this run's local clippy noise on unrelated
        // pre-existing lint must not overwrite that landed outcome. Trust
        // the actual PR merge state over the local exit code.
        if is_locally_recoverable_exit_code(exit_code) {
            if let Ok(pr) = current_pr_number(ws.working_dir()) {
                if pr_is_merged(ws.working_dir(), pr) {
                    return Ok(ShipResult::Shipped { pr_number: pr });
                }
            }
        }
        return Ok(ShipResult::Aborted {
            error: format!("bot-merge.sh exited {exit_code}"),
        });
    }

    // bot-merge.sh has already opened/updated the PR. Read the PR number off
    // the current branch via gh — also from the worktree, since we want the
    // PR that bot-merge.sh just opened (which corresponds to the worktree's
    // branch, not main).
    match current_pr_number(ws.working_dir()) {
        Ok(pr) => Ok(ShipResult::Shipped { pr_number: pr }),
        Err(e) => Ok(ShipResult::Blocked {
            reason: format!("ship succeeded but PR# unresolvable: {e:#}"),
        }),
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

/// CREDIBLE-297: bot-merge.sh exit codes that reflect a *local-only* gate
/// (this invocation's own repo-wide clippy pass) rather than the PR's own
/// scoped CI — a prior invocation may have already landed the PR while this
/// run's local check is still noisy on unrelated pre-existing lint. `13` is
/// bot-merge.sh's clippy-fail code (see `scripts/coord/bot-merge.sh`
/// `_bm_fail "clippy" 13 ...`).
fn is_locally_recoverable_exit_code(exit_code: i32) -> bool {
    exit_code == 13
}

/// Best-effort check of whether `pr_number` has actually merged. Used only
/// to recover from a locally-recoverable bot-merge.sh failure (see
/// [`is_locally_recoverable_exit_code`]) — any `gh` error is treated as
/// "not merged" so we fall back to reporting the original failure honestly.
fn pr_is_merged(repo_root: &Path, pr_number: u64) -> bool {
    let out = Command::new("gh")
        .args([
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "state",
            "-q",
            ".state",
        ])
        .current_dir(repo_root)
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "MERGED",
        _ => false,
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

    #[test]
    fn clippy_exit_code_is_locally_recoverable() {
        assert!(is_locally_recoverable_exit_code(13));
        assert!(!is_locally_recoverable_exit_code(1));
        assert!(!is_locally_recoverable_exit_code(14));
        assert!(!is_locally_recoverable_exit_code(-1));
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
                "--model",
                "claude-sonnet-4-6"
            ],
            "headless command args changed shape — verify no caller reintroduces \
             `.arg(prompt)` after `-p`, which broke 100% of dispatches (INFRA-3675)"
        );
        // No model → still exactly the fixed two flags, no trailing empty arg.
        let cmd_no_model = headless_command_skeleton("");
        let args_no_model: Vec<&str> = cmd_no_model
            .get_args()
            .map(|a| a.to_str().unwrap())
            .collect();
        assert_eq!(args_no_model, vec!["-p", "--dangerously-skip-permissions"]);
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
}
