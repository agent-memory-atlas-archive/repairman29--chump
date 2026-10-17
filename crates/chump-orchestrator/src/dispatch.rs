//! Subprocess spawn for dispatched subagents — AUTO-013 MVP step 2.
//!
//! `dispatch_gap` creates a linked worktree for a gap, claims the lease in
//! that worktree, and spawns a `claude` CLI subprocess with a focused prompt.
//! The spawned agent follows `docs/architecture/TEAM_OF_AGENTS.md`: read CLAUDE.md, do the
//! work, ship via `scripts/coord/bot-merge.sh`, reply only with the PR number.
//!
//! Monitor loop + reflection writes land in steps 3-4. This module only
//! returns a `DispatchHandle` — the caller owns tracking.
//!
//! ## Depth-1 enforcement (design doc §2, Q5)
//!
//! Dispatched subagents MUST NOT spawn further subagents. We set
//! `CHUMP_DISPATCH_DEPTH=1` in the subprocess env; a future guard in
//! `dispatch_gap` will refuse when that env var is already set.
//!
//! ## Why `std::process::Command`, not `tokio::process`
//!
//! Step 2 only needs to *start* the subprocess and return a handle. The
//! monitor loop (step 3) is where async polling matters. Keeping this
//! synchronous avoids pulling tokio into the crate for no gain.
//!
//! ## Fault-injection test mode (INFRA-DISPATCH-FAULT-INJECTION)
//!
//! Set `CHUMP_FAULT_INJECT` to a comma-separated list of fault specs to
//! exercise dispatch/monitor/retry paths without running a real `claude`
//! subprocess:
//!
//! - `spawn_fail` — `spawn_claude` returns an error immediately (no process).
//! - `exit_1` — spawns `sh -c 'sleep 0.1; exit 1'`; subprocess exits 1.
//! - `exit_0_no_pr` — spawns `sh -c 'sleep 0.1; exit 0'`; process exits 0
//!   but produces no PR number (tests the clean-exit-no-PR path).
//! - `monitor_timeout` — spawns `sh -c 'sleep 3600'`; the monitor's deadline
//!   ladder fires before the process exits (use a tiny soft_deadline in tests).
//!
//! The first spec in the list that applies wins. When `CHUMP_FAULT_INJECT` is
//! unset or empty, behavior is unchanged (production path).

use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::routing::{Candidate, RoutingTable};
use crate::thompson::{rank_by_thompson, ArmStats};
use crate::Gap;
use std::collections::HashMap;

// ── Fault-injection ──────────────────────────────────────────────────────────

/// A single fault spec parsed from `CHUMP_FAULT_INJECT`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FaultMode {
    /// `spawn_claude` returns an error immediately — no process is forked.
    SpawnFail,
    /// Spawns `sh -c 'sleep 0.1; exit 1'` — process exits non-zero after
    /// 100 ms.
    Exit1,
    /// Spawns `sh -c 'sleep 0.1; exit 0'` — process exits 0 but produces
    /// no PR number in output (tests the clean-exit-no-PR monitor path).
    Exit0NoPr,
    /// Spawns `sh -c 'sleep 3600'` — a long-running process that the
    /// monitor's soft-deadline ladder will kill before it exits naturally.
    /// Use a tiny `soft_deadline_secs` in tests to trigger this quickly.
    MonitorTimeout,
}

/// Parse `CHUMP_FAULT_INJECT` into the first matching [`FaultMode`].
///
/// The env var accepts a comma-separated list; only the *first* recognised
/// token is returned (callers that need multiple faults in sequence drive
/// them in separate dispatches). Returns `None` when the env var is absent,
/// empty, or contains no recognised tokens.
pub fn active_fault_mode() -> Option<FaultMode> {
    let raw = std::env::var("CHUMP_FAULT_INJECT").ok()?;
    for token in raw.split(',') {
        match token.trim() {
            "spawn_fail" => return Some(FaultMode::SpawnFail),
            "exit_1" => return Some(FaultMode::Exit1),
            "exit_0_no_pr" => return Some(FaultMode::Exit0NoPr),
            "monitor_timeout" => return Some(FaultMode::MonitorTimeout),
            _ => {}
        }
    }
    None
}

/// Default cap on lines retained in [`DispatchHandle::stderr_tail`].
/// Anything past this is dropped — PRODUCT-006 only needs a representative
/// sample of WARN/ERROR lines, not the whole transcript.
pub const STDERR_TAIL_CAP: usize = 64;

/// Shared, lock-protected ring of WARN/ERROR lines tailed off a subagent's
/// stderr. Held by both the spawning thread and the [`DispatchHandle`].
pub type StderrTail = Arc<Mutex<Vec<String>>>;

/// Which subagent binary the spawner forked. COG-025 added the second arm so
/// dispatched subagents can run on Together / mistral.rs / Ollama (cost
/// routing) instead of the Anthropic-only `claude` CLI.
///
/// Selected at spawn time via env `CHUMP_DISPATCH_BACKEND`. The value is
/// captured on every [`DispatchHandle`] so [`crate::reflect::DispatchReflection`]
/// rows can be filtered/aggregated per-backend (COG-026 A/B reads this).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchBackend {
    /// `claude -p <prompt>` via `scripts/coord/claude-retry.sh` — original AUTO-013
    /// baseline. Anthropic-only, costs ~$1-2/PR shipped.
    Claude,
    /// `target/release/chump --execute-gap <GAP-ID>` — drives Chump's own
    /// multi-turn agent loop through whatever provider $OPENAI_API_BASE +
    /// $OPENAI_MODEL resolve to. Free-tier-capable.
    ChumpLocal,
}

impl DispatchBackend {
    /// Resolve the backend from env. Default = `Claude` (preserves AUTO-013
    /// baseline behaviour for any caller who hasn't opted in). Unknown values
    /// fall back to the default with a one-line stderr warning so a typo
    /// doesn't silently send everything to claude when the operator wanted
    /// the cheap path.
    pub fn from_env() -> Self {
        match std::env::var("CHUMP_DISPATCH_BACKEND")
            .ok()
            .as_deref()
            .map(str::trim)
        {
            Some("") | None => DispatchBackend::Claude,
            Some("claude") => DispatchBackend::Claude,
            Some("chump-local") | Some("chump_local") | Some("local") => {
                DispatchBackend::ChumpLocal
            }
            Some(other) => {
                eprintln!(
                    "[dispatch] WARN unknown CHUMP_DISPATCH_BACKEND={other:?}; \
                     falling back to 'claude' (valid: claude | chump-local)"
                );
                DispatchBackend::Claude
            }
        }
    }

    /// Short stable label for logging + reflection notes.
    pub fn label(self) -> &'static str {
        match self {
            DispatchBackend::Claude => "claude",
            DispatchBackend::ChumpLocal => "chump-local",
        }
    }

    /// INFRA-065 — combined env + advisor resolution. Precedence:
    ///
    /// 1. If `CHUMP_DISPATCH_BACKEND` is set to a recognised value, use it
    ///    (operator override always wins). Rationale = `"env:<value>"`.
    /// 2. Otherwise consult [`select_backend_for_gap`] for the rule-based
    ///    advisor pick from gap priority + effort.
    ///
    /// Unknown env values fall through to the advisor with a one-line
    /// stderr warning (mirrors [`Self::from_env`] semantics so a typo
    /// doesn't silently send everything to claude).
    pub fn resolve_for_gap(priority: &str, effort: &str) -> (Self, String) {
        match std::env::var("CHUMP_DISPATCH_BACKEND")
            .ok()
            .as_deref()
            .map(str::trim)
        {
            Some("") | None => {
                let (b, why) = select_backend_for_gap(priority, effort);
                (b, format!("advisor:{why}"))
            }
            Some("claude") => (DispatchBackend::Claude, "env:claude".to_string()),
            Some("chump-local") | Some("chump_local") | Some("local") => {
                (DispatchBackend::ChumpLocal, "env:chump-local".to_string())
            }
            Some(other) => {
                eprintln!(
                    "[dispatch] WARN unknown CHUMP_DISPATCH_BACKEND={other:?}; \
                     falling back to advisor (valid: claude | chump-local)"
                );
                let (b, why) = select_backend_for_gap(priority, effort);
                (b, format!("advisor-after-bad-env:{why}"))
            }
        }
    }
}

/// COG-035 — derive the optional `task_class` for a gap from its id prefix.
///
/// `EVAL-*` and `RESEARCH-*` ids surface as `Some("research")`; `COG-*`
/// ids surface as `Some("cognition")` — both task classes the routing
/// table can match against to force frontier-only candidates (free-tier
/// cascade is too risky for cognitive-architecture experiments where
/// false positives are dressed up as real findings, see EVAL-074
/// retraction in docs/RESEARCH_INTEGRITY.md). Other id prefixes return
/// `None` and fall through to priority/effort matching. Future task
/// classes (`infra`, `feature`) are reserved namespace expansions — the
/// routing table already accepts them as match keys (INFRA-265).
pub fn task_class_for_gap_id(gap_id: &str) -> Option<&'static str> {
    let upper = gap_id.trim().to_ascii_uppercase();
    if upper.starts_with("EVAL-") || upper.starts_with("RESEARCH-") {
        Some("research")
    } else if upper.starts_with("COG-") {
        // INFRA-265: cognitive-architecture work routes to claude only.
        // The free-tier cascade can produce confident-sounding wrong
        // answers on belief-state / Active Inference / synthetic
        // neuromodulation code where the operator has no quick way to
        // detect failures from the agent's output alone.
        Some("cognition")
    } else {
        None
    }
}

/// COG-035 — load `<repo_root>/docs/dispatch/routing.yaml` and return the
/// ordered candidate cascade for `gap_id`. Falls back to the hardcoded
/// pre-COG-035 routing table when the YAML is missing or fails to load
/// (we log a warn line so operator drift is visible without taking the
/// dispatcher offline). Malformed YAML logs the parse error verbatim so
/// the operator can fix it; the fallback table preserves dispatch.
///
/// The returned `Vec<Candidate>` is the v1 shape of the cascade contract
/// that COG-036 (scoreboard) and COG-037 (Thompson sampler) will reuse —
/// only the *source* of the list will change.
pub fn select_candidates_for_gap(
    repo_root: &Path,
    gap_id: &str,
    priority: &str,
    effort: &str,
) -> Vec<Candidate> {
    let table = match RoutingTable::load(repo_root) {
        Ok(t) => t,
        Err(e) => {
            eprintln!(
                "[dispatch] WARN failed to load routing.yaml ({e:#}); \
                 falling back to hardcoded routing table"
            );
            RoutingTable::hardcoded_fallback()
        }
    };
    let task_class = task_class_for_gap_id(gap_id);
    let cands = table.select(priority, effort, task_class);

    // COG-037: when the `cog_037` runtime flag is enabled, reorder the
    // candidate cascade by Thompson-sampling argmax over the routing
    // scoreboard. Default OFF — flag-off path is byte-identical to the
    // YAML-driven COG-035 ordering above.
    if cog_037_enabled() {
        let stats = load_scoreboard_signatures(repo_root);
        let mut rng = rand::rng();
        return rank_by_thompson(cands, &stats, &mut rng);
    }
    cands
}

/// COG-037 — Thompson router: same-as-cog_035 path but with an injectable
/// RNG so tests can pin the ordering with a seeded `StdRng`. Production
/// callers should use [`select_candidates_for_gap`] which uses the thread RNG.
///
/// Behaviour matches `select_candidates_for_gap` on the flag-off path:
/// loads the YAML routing table, applies the cascade, then (always — this
/// helper is the deterministic flag-on path) ranks by Thompson sampling.
pub fn select_candidates_for_gap_with_rng<R: rand::Rng + ?Sized>(
    repo_root: &Path,
    gap_id: &str,
    priority: &str,
    effort: &str,
    rng: &mut R,
) -> Vec<Candidate> {
    let table = match RoutingTable::load(repo_root) {
        Ok(t) => t,
        Err(_) => RoutingTable::hardcoded_fallback(),
    };
    let task_class = task_class_for_gap_id(gap_id);
    let cands = table.select(priority, effort, task_class);
    let stats = load_scoreboard_signatures(repo_root);
    rank_by_thompson(cands, &stats, rng)
}

/// Returns true when `CHUMP_FLAGS` contains `cog_037` (case-insensitive,
/// comma-separated). Inlined here to keep the orchestrator crate
/// independent of the chump binary's `runtime_flags` module — both speak
/// the same env-var contract.
fn cog_037_enabled() -> bool {
    std::env::var("CHUMP_FLAGS")
        .ok()
        .map(|raw| {
            raw.split(',')
                .map(|s| s.trim().to_ascii_lowercase())
                .any(|s| s == "cog_037")
        })
        .unwrap_or(false)
}

/// Read the routing scoreboard from `<repo_root>/.chump/state.db` and
/// project it down to a `signature -> ArmStats` map.
///
/// "Best-effort" by spec — if the DB doesn't exist, the schema isn't
/// present, or any row is malformed, we log a warning to stderr and
/// return whatever we managed to read (empty map on a hard failure).
/// **Never panics**: bad scoreboard data must not crash the dispatcher.
///
/// The orchestrator crate cannot depend on the bin's `gap_store::GapStore`
/// (that module lives in `src/gap_store.rs`, the chump binary's tree),
/// so this helper opens the DB directly via rusqlite. It mirrors the
/// `routing_outcomes` schema set up in both `gap_store.rs` and
/// `monitor::write_routing_outcome`.
pub fn load_scoreboard_signatures(repo_root: &Path) -> HashMap<String, ArmStats> {
    let db_path = chump_store_path::state_db_path(repo_root); // INFRA-8190
    if !db_path.exists() {
        return HashMap::new();
    }
    let conn = match rusqlite::Connection::open_with_flags(
        &db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "[dispatch] WARN cog_037 scoreboard load: cannot open {} ({e}); \
                 falling back to YAML-only ordering",
                db_path.display()
            );
            return HashMap::new();
        }
    };
    let mut stmt = match conn.prepare(
        "SELECT backend, model, provider_pfx,
                SUM(CASE WHEN outcome='shipped' THEN 1 ELSE 0 END) AS successes,
                SUM(CASE WHEN outcome='shipped' THEN 0 ELSE 1 END) AS failures
         FROM routing_outcomes
         GROUP BY backend, model, provider_pfx",
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[dispatch] WARN cog_037 scoreboard load: prepare failed ({e}); \
                 falling back to YAML-only ordering"
            );
            return HashMap::new();
        }
    };

    let rows = match stmt.query_map([], |r| {
        let backend: String = r.get(0).unwrap_or_default();
        let model: String = r.get(1).unwrap_or_default();
        let provider_pfx: String = r.get(2).unwrap_or_default();
        let successes: i64 = r.get(3).unwrap_or(0);
        let failures: i64 = r.get(4).unwrap_or(0);
        // Clamp negatives (shouldn't happen but defensive — SUMs of CASE
        // WHEN are always non-negative, but a corrupted DB could surprise).
        let succ_u = successes.max(0) as u64;
        let fail_u = failures.max(0) as u64;
        Ok((
            format!("{backend}|{model}|{provider_pfx}"),
            ArmStats {
                successes: succ_u,
                failures: fail_u,
            },
        ))
    }) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[dispatch] WARN cog_037 scoreboard load: query failed ({e})");
            return HashMap::new();
        }
    };

    let mut out = HashMap::new();
    for row in rows.flatten() {
        out.insert(row.0, row.1);
    }
    out
}

/// INFRA-063 (M5) — rule-based backend selector for cost-routed dispatch.
///
/// **Post-COG-035:** thin wrapper around [`select_candidates_for_gap`] that
/// returns the *first* candidate's backend. The hardcoded fallback table in
/// [`crate::routing::RoutingTable::hardcoded_fallback`] preserves the
/// original 2-rule heuristic (effort=xs → cheap, P1+l/xl → claude, else
/// cheap), so callers and tests that don't have a `routing.yaml` keep their
/// pre-COG-035 behaviour. The `&'static str` rationale is degraded to
/// constant labels — for the full per-candidate `why`, callers should
/// migrate to [`select_candidates_for_gap`].
///
/// Operators retain full override power: env vars `CHUMP_DISPATCH_BACKEND`
/// (per-process) and per-call wiring still take precedence. This function
/// is the *advisory* router whose output gets logged for cost-split
/// telemetry and informs M5 acceptance criterion 2 ("dispatcher logs show
/// per-gap backend selection rationale").
pub fn select_backend_for_gap(priority: &str, effort: &str) -> (DispatchBackend, &'static str) {
    // Use the hardcoded fallback table directly — `select_backend_for_gap`
    // historically had no `repo_root` parameter and is called from contexts
    // (tests, in-process resolve) that don't have one. Callers that want
    // YAML-driven routing should call `select_candidates_for_gap`.
    let table = RoutingTable::hardcoded_fallback();
    let cands = table.select(priority, effort, None);
    let first = match cands.first() {
        Some(c) => c.clone(),
        None => {
            // Defensive: hardcoded_fallback always seeds at least one
            // default candidate, so this branch is unreachable in practice.
            return (
                DispatchBackend::ChumpLocal,
                "default → cheap tier (override via CHUMP_DISPATCH_BACKEND=claude)",
            );
        }
    };
    let why: &'static str = match (
        first.backend,
        priority.trim(),
        effort.trim().to_ascii_lowercase().as_str(),
    ) {
        (DispatchBackend::ChumpLocal, _, "xs") => "effort=xs → cheap tier (trivial codemod-class)",
        (DispatchBackend::Claude, "P1", "l") | (DispatchBackend::Claude, "P1", "xl") => {
            "priority=P1 + effort>=l → frontier (high-stakes large work)"
        }
        (DispatchBackend::ChumpLocal, _, _) => {
            "default → cheap tier (override via CHUMP_DISPATCH_BACKEND=claude)"
        }
        (DispatchBackend::Claude, _, _) => "see docs/dispatch/routing.yaml",
    };
    (first.backend, why)
}

/// Result of [`Spawner::spawn_claude`]: an optional child handle plus the
/// optional stderr-tail buffer the spawner attached.
///
/// Method name preserved (it's the trait API); the arm actually invoked is
/// recorded on [`DispatchHandle::backend`].
pub type SpawnResult = (Option<Child>, Option<StderrTail>);

/// Handle returned after a successful spawn. The monitor loop (step 3) will
/// consume these to track outcomes.
///
/// `child` is `Some` for real spawns and `None` for tests / injection-mode
/// runs that skip the actual process fork.
#[derive(Debug)]
pub struct DispatchHandle {
    pub gap_id: String,
    pub worktree_path: PathBuf,
    pub branch_name: String,
    pub child_pid: Option<u32>,
    pub started_at_unix: u64,
    /// Held so the child isn't reaped as a zombie before the monitor loop
    /// exists. In step 3 the monitor takes ownership.
    pub child: Option<Child>,
    /// Bounded ring of WARN/ERROR lines captured from the subagent's
    /// stderr. Populated by a background thread spawned in
    /// [`RealSpawner::spawn_claude`]; the monitor reads it when the
    /// subprocess reaches a terminal outcome and feeds the snapshot into
    /// the dispatch reflection (AUTO-013 step 4 — see
    /// [`crate::reflect::DispatchReflection`]).
    ///
    /// `None` for test spawners that don't fork a real process.
    pub stderr_tail: Option<StderrTail>,
    /// Which subagent binary the spawner forked. Default `Claude` for
    /// back-compat; `ChumpLocal` when CHUMP_DISPATCH_BACKEND=chump-local.
    /// Recorded into reflection notes by the monitor (COG-025/COG-026 A/B).
    pub backend: DispatchBackend,
    /// COG-038 — provider model id (e.g. `openai/gpt-oss-120b`) carried
    /// through from the chosen [`Candidate`] so the monitor can write it
    /// into `routing_outcomes.model` without re-reading env vars. `None`
    /// for the `claude` backend (which selects its own model via the CLI)
    /// and for env-overridden dispatches that don't set
    /// `CHUMP_DISPATCH_MODEL`.
    pub model: Option<String>,
    /// COG-038 — provider prefix (`TOGETHER`, `GROQ`, …) carried through
    /// from the chosen [`Candidate`]. Pairs with `model` to form the
    /// scoreboard signature COG-037 joins on.
    pub provider_pfx: Option<String>,
}

impl DispatchHandle {
    /// Snapshot the captured stderr tail as a single newline-joined string
    /// (empty when no buffer was attached or no lines matched). Cheap —
    /// holds the mutex only long enough to clone the `Vec`.
    pub fn stderr_tail_snapshot(&self) -> String {
        match &self.stderr_tail {
            Some(buf) => match buf.lock() {
                Ok(g) => g.join("\n"),
                Err(_) => String::new(),
            },
            None => String::new(),
        }
    }
}

/// How to create worktrees + claim leases + spawn the claude CLI. Injecting
/// this makes `dispatch_gap` unit-testable without forking real processes
/// (which would burn budget and require a live `claude` binary).
pub trait Spawner {
    fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()>;
    fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()>;
    /// Returns `(child, stderr_tail)` — the child handle and an optional
    /// shared buffer the spawner attached to a stderr-tailing thread.
    /// Test spawners that don't fork a real process return `(None, None)`.
    ///
    /// `backend` is the resolved dispatch backend the caller has chosen for
    /// this spawn (INFRA-065). Production [`RealSpawner`] honors it directly;
    /// historical "read CHUMP_DISPATCH_BACKEND from env inside spawn_claude"
    /// behavior is gone — env resolution happens once, in `dispatch_gap_with`.
    fn spawn_claude(
        &self,
        worktree: &Path,
        prompt: &str,
        backend: DispatchBackend,
    ) -> Result<SpawnResult>;
}

/// Production spawner: shells out to git, gap-claim.sh, and the `claude` CLI.
pub struct RealSpawner;

impl Spawner for RealSpawner {
    fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()> {
        let status = Command::new("git")
            .args([
                "worktree",
                "add",
                worktree.to_str().context("worktree path not utf-8")?,
                "-b",
                branch,
                base,
            ])
            .status()
            .context("spawning git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed for {}", worktree.display());
        }
        Ok(())
    }

    fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()> {
        // gap-claim.sh refuses from the main worktree root, so cwd MUST be the
        // new linked worktree. That's the caller's contract.
        let script = worktree.join("scripts").join("gap-claim.sh");
        let status = Command::new("bash")
            .arg(script)
            .arg(gap_id)
            .current_dir(worktree)
            .status()
            .context("spawning gap-claim.sh")?;
        if !status.success() {
            bail!("gap-claim.sh failed for {gap_id} in {}", worktree.display());
        }
        Ok(())
    }

    fn spawn_claude(
        &self,
        worktree: &Path,
        prompt: &str,
        backend: DispatchBackend,
    ) -> Result<SpawnResult> {
        // INFRA-DISPATCH-FAULT-INJECTION: when CHUMP_FAULT_INJECT is set,
        // short-circuit to a synthetic process instead of the real backend.
        // This lets callers exercise dispatch/monitor/retry paths without a
        // live `claude` binary or a GitHub account.
        if let Some(fault) = active_fault_mode() {
            return spawn_fault_process(fault);
        }
        // COG-025 / INFRA-065: backend is resolved once by the caller (see
        // `DispatchBackend::resolve_for_gap`) and passed in here. `claude`
        // forks the Anthropic CLI; `chump-local` runs Chump's own multi-turn
        // agent loop through whatever provider OPENAI_API_BASE+OPENAI_MODEL
        // resolve to (Together free tier, mistral.rs, Ollama, hosted OpenAI).
        match backend {
            DispatchBackend::Claude => self.spawn_claude_cli(worktree, prompt),
            DispatchBackend::ChumpLocal => self.spawn_chump_local(worktree, prompt),
        }
    }
}

/// Spawn the synthetic process for the given fault mode (or return an error
/// for `SpawnFail`). Used by both `RealSpawner` and any test harness that
/// wants to exercise this path without a full dispatch flow.
pub fn spawn_fault_process(fault: FaultMode) -> Result<SpawnResult> {
    match fault {
        FaultMode::SpawnFail => {
            bail!("[fault-inject] spawn_fail: dispatch returns error immediately");
        }
        FaultMode::Exit1 => {
            // Exits non-zero after 100 ms — triggers Killed("exit code 1").
            let child = Command::new("sh")
                .args(["-c", "sleep 0.1; exit 1"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("[fault-inject] exit_1: spawning sh")?;
            Ok((Some(child), None))
        }
        FaultMode::Exit0NoPr => {
            // Exits 0 after 100 ms with no PR number in output — tests the
            // clean-exit-no-PR monitor path (process exits OK but agent never
            // opened a PR; monitor waits for the soft-deadline ladder).
            let child = Command::new("sh")
                .args(["-c", "sleep 0.1; exit 0"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("[fault-inject] exit_0_no_pr: spawning sh")?;
            Ok((Some(child), None))
        }
        FaultMode::MonitorTimeout => {
            // Runs for 1 hour — the monitor's deadline ladder fires first.
            // Tests use a tiny `soft_deadline_secs` (e.g. 1 s) so this
            // resolves in milliseconds without burning real time.
            let child = Command::new("sh")
                .args(["-c", "sleep 3600"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .context("[fault-inject] monitor_timeout: spawning sh")?;
            Ok((Some(child), None))
        }
    }
}

impl RealSpawner {
    /// Original AUTO-013 spawn — `claude -p <prompt>` via claude-retry.sh.
    fn spawn_claude_cli(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
        // `claude -p <prompt>` is non-interactive. CWD is the worktree.
        // CHUMP_DISPATCH_DEPTH=1 prevents recursive dispatch in the child.
        //
        // We invoke through scripts/coord/claude-retry.sh (INFRA-CHUMP-API-RETRY,
        // shipped 2026-04-19) which wraps claude with retry-on-transient-5xx.
        // Override the binary via env CHUMP_CLAUDE_BIN for tests.
        // Fallback to bare `claude` if the wrapper isn't found (e.g. running
        // from outside the repo).
        //
        // stderr is piped + tailed in a background thread so the AUTO-013
        // step-4 dispatch reflection can include WARN/ERROR lines without
        // buffering the whole transcript. The buffer is bounded by
        // [`STDERR_TAIL_CAP`].
        let claude_bin = std::env::var("CHUMP_CLAUDE_BIN").unwrap_or_else(|_| {
            // Look up the wrapper relative to the orchestrator's worktree
            // (cwd of the parent process). If found, use it; else fall back
            // to bare `claude`.
            let wrapper = std::env::current_dir()
                .ok()
                .map(|d| d.join("scripts").join("claude-retry.sh"));
            match wrapper {
                Some(p) if p.exists() => p.to_string_lossy().into_owned(),
                _ => "claude".to_string(),
            }
        });
        // INFRA-DISPATCH-PERMISSIONS-FLAG (2026-04-19): the dispatched
        // subagent runs unattended (no terminal, no human) so per-tool
        // permission prompts cause the subprocess to STALL forever (caught
        // by autonomy-test V3, marked STALLED by monitor at soft-deadline).
        // --dangerously-skip-permissions is appropriate here: the subagent
        // IS sandboxed-by-context (its own worktree, gap-scoped, atomic PR).
        // INFRA-017: stamp dispatched-agent git identity so Red Letter and
        // the ambient stream can distinguish bot commits from foreign actors.
        // Setting both AUTHOR and COMMITTER env covers the `git commit
        // --amend` path in bot-merge.sh as well as any fresh commits the
        // subagent makes during gap work.
        // INFRA-097 (2026-04-27): pipe prompt via stdin instead of argv.
        // CHUMP_DISPATCH_RULES.md starts with YAML frontmatter (---), so
        // passing the prompt as a positional argv made claude's clap parser
        // exit with `error: unknown option ---<frontmatter>` before the
        // agent even started. Writing to stdin sidesteps argv entirely.
        let mut child = Command::new(&claude_bin)
            .arg("-p")
            .arg("--dangerously-skip-permissions")
            .current_dir(worktree)
            .env("CHUMP_DISPATCH_DEPTH", "1")
            .env("GIT_AUTHOR_NAME", "Chump Dispatched")
            .env("GIT_AUTHOR_EMAIL", "chump-dispatch@chump.bot")
            .env("GIT_COMMITTER_NAME", "Chump Dispatched")
            .env("GIT_COMMITTER_EMAIL", "chump-dispatch@chump.bot")
            .stdin(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawning claude CLI via {claude_bin}"))?;

        if let Some(mut stdin) = child.stdin.take() {
            use std::io::Write;
            stdin
                .write_all(prompt.as_bytes())
                .context("writing dispatch prompt to claude stdin")?;
            // Drop closes stdin so claude knows the prompt is complete.
        }

        let buf: StderrTail = Arc::new(Mutex::new(Vec::new()));
        if let Some(stderr) = child.stderr.take() {
            let buf_thread = Arc::clone(&buf);
            std::thread::Builder::new()
                .name("orchestrator-stderr-tail".into())
                .spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        // Cheap filter — only retain lines that look like
                        // diagnostic noise. PRODUCT-006 wants signals,
                        // not the full info-stream.
                        let upper = line.to_uppercase();
                        if upper.contains("ERROR")
                            || upper.contains("WARN")
                            || upper.contains("FAIL")
                            || upper.contains("PANIC")
                        {
                            if let Ok(mut g) = buf_thread.lock() {
                                if g.len() >= STDERR_TAIL_CAP {
                                    // Drop oldest; keep the most-recent
                                    // window (terminal failures cluster
                                    // near the end of the transcript).
                                    g.remove(0);
                                }
                                g.push(line);
                            }
                        }
                    }
                })
                .ok(); // best-effort — failing to spawn the tailer must
                       // not abort dispatch.
        }

        Ok((Some(child), Some(buf)))
    }

    /// COG-025 backend: spawn `chump --execute-gap <GAP-ID>` so the dispatched
    /// subagent runs through Chump's own multi-turn agent loop (provider =
    /// $OPENAI_API_BASE+$OPENAI_MODEL — Together/mistral.rs/Ollama/OpenAI).
    ///
    /// The chump binary is resolved (in priority order):
    ///   1. `$CHUMP_LOCAL_BIN` — explicit override (tests, custom builds).
    ///   2. `<worktree>/target/release/chump` — typical release build.
    ///   3. `<worktree>/target/debug/chump` — dev fallback.
    ///   4. bare `chump` on $PATH — last resort.
    ///
    /// We pass through any OPENAI_* env the parent process holds so the
    /// caller's provider config flows into the child without a config file.
    fn spawn_chump_local(&self, worktree: &Path, prompt: &str) -> Result<SpawnResult> {
        // Resolve gap id from the prompt. The prompt is the canonical
        // `build_prompt` output ("...working on gap <ID>...") so a cheap
        // tokenizer is enough; we don't need to thread the id through the
        // trait (which would break the back-compat contract).
        let gap_id = parse_gap_id_from_prompt(prompt).ok_or_else(|| {
            anyhow::anyhow!(
                "spawn_chump_local: could not extract gap id from prompt — \
                 expected `working on gap <ID>` token"
            )
        })?;

        let bin = resolve_chump_local_bin(worktree);
        let mut cmd = Command::new(&bin);
        // INFRA-017: same dispatched-agent git identity as the claude
        // backend so attribution is uniform across COG-025 A/B arms.
        cmd.arg("--execute-gap")
            .arg(&gap_id)
            .current_dir(worktree)
            .env("CHUMP_DISPATCH_DEPTH", "1")
            .env("CHUMP_DISPATCH_BACKEND_LABEL", "chump-local")
            .env("GIT_AUTHOR_NAME", "Chump Dispatched")
            .env("GIT_AUTHOR_EMAIL", "chump-dispatch@chump.bot")
            .env("GIT_COMMITTER_NAME", "Chump Dispatched")
            .env("GIT_COMMITTER_EMAIL", "chump-dispatch@chump.bot")
            .stderr(Stdio::piped());

        // Pass through provider env explicitly so the child inherits it
        // even when the parent was launched with a stripped env (e.g. cron).
        // (Command::new already inherits the parent env by default — these
        // calls are belt-and-braces and document the contract.)
        for var in ["OPENAI_API_BASE", "OPENAI_MODEL", "OPENAI_API_KEY"] {
            if let Ok(v) = std::env::var(var) {
                cmd.env(var, v);
            }
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawning chump-local backend via {}", bin.display()))?;

        let buf: StderrTail = Arc::new(Mutex::new(Vec::new()));
        if let Some(stderr) = child.stderr.take() {
            let buf_thread = Arc::clone(&buf);
            std::thread::Builder::new()
                .name("orchestrator-stderr-tail-chump-local".into())
                .spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        let upper = line.to_uppercase();
                        if upper.contains("ERROR")
                            || upper.contains("WARN")
                            || upper.contains("FAIL")
                            || upper.contains("PANIC")
                        {
                            if let Ok(mut g) = buf_thread.lock() {
                                if g.len() >= STDERR_TAIL_CAP {
                                    g.remove(0);
                                }
                                g.push(line);
                            }
                        }
                    }
                })
                .ok();
        }

        Ok((Some(child), Some(buf)))
    }
}

/// Resolve the chump binary used by the `chump-local` backend. Priority:
/// `$CHUMP_LOCAL_BIN` → `<worktree>/target/release/chump` →
/// `<worktree>/target/debug/chump` → bare `chump`.
fn resolve_chump_local_bin(worktree: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_LOCAL_BIN") {
        return PathBuf::from(p);
    }
    // Try the worktree-local target/ first; subagents typically share the
    // top-level Cargo workspace, so target/ lives in the parent repo, not
    // the linked worktree. Walk up to find the closest `target/release/chump`.
    let mut probe = worktree.to_path_buf();
    for _ in 0..5 {
        let release = probe.join("target/release/chump");
        if release.is_file() {
            return release;
        }
        let debug = probe.join("target/debug/chump");
        if debug.is_file() {
            return debug;
        }
        if !probe.pop() {
            break;
        }
    }
    PathBuf::from("chump")
}

/// Extract the gap id from a `build_prompt`-shaped prompt string. Returns
/// `None` if the marker `working on gap ` isn't present (e.g. the caller
/// hand-crafted a prompt that doesn't follow the contract).
fn parse_gap_id_from_prompt(prompt: &str) -> Option<String> {
    let marker = "working on gap ";
    let start = prompt.find(marker)? + marker.len();
    let rest = &prompt[start..];
    // Gap id ends at the first whitespace, period, or punctuation.
    let end = rest
        .find(|c: char| !(c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-'))
        .unwrap_or(rest.len());
    let id = &rest[..end];
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
}

/// Build the prompt handed to the dispatched subagent. See
/// `docs/architecture/TEAM_OF_AGENTS.md` — the contract every dispatched subagent follows.
///
/// `repo_root` is used to read two files injected inline:
///
///   1. `docs/process/CHUMP_DISPATCH_RULES.md` — distilled coordination rules
///      (header of the prompt).
///   2. `scripts/dispatch/subagent-shipping-epilogue.md` — the
///      `subagent-shipping-epilogue` canonical token (footer). INFRA-332
///      injects this verbatim so every dispatched subagent gets the same
///      bot-merge / chump-doctor / manual-recovery / final-report contract
///      that the single self-shipping subagent in the META-025 trial had.
///      Both backends — `claude -p` and `chump --execute-gap` — receive
///      the same epilogue. CI guard
///      `scripts/ci/test-subagent-epilogue-ref.sh` enforces both prompt
///      builders include the canonical token.
///
/// Order is rules → task → epilogue: coordination context first, per-gap
/// task in the middle, recovery / final-report contract last (closest to
/// where the agent does the ship).
pub fn build_prompt(gap_id: &str, repo_root: &Path) -> String {
    let rules = std::fs::read_to_string(repo_root.join("docs/process/CHUMP_DISPATCH_RULES.md"))
        .unwrap_or_default();
    let rules_block = if rules.is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    };
    // INFRA-332: subagent-shipping-epilogue (canonical token).
    let epilogue =
        std::fs::read_to_string(repo_root.join("scripts/dispatch/subagent-shipping-epilogue.md"))
            .unwrap_or_default();
    let epilogue_block = if epilogue.is_empty() {
        String::new()
    } else {
        format!("\n\n---\n\n{epilogue}")
    };
    format!(
        "{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry via `chump gap show {gap}` for full acceptance criteria \
(state.db is canonical, ZERO-WASTE-020 retired the docs/gaps/<ID>.yaml mirror). \
Do the work, then ship via:\n  scripts/coord/bot-merge.sh --gap {gap} --auto-merge\n\
After ship, exit. Reply ONLY with the PR number.{epilogue}",
        rules = rules_block,
        gap = gap_id,
        epilogue = epilogue_block,
    )
}

/// How many grounded starting points to inject. Small on purpose: this is a
/// pointer into the codebase, not a substitute for the agent doing its own
/// reading, and a long list would push the epilogue's shipping contract further
/// from where the agent acts.
const ALMANAC_GROUNDING_HITS: usize = 5;

/// Hard ceiling on the pre-query. Dispatch must never block on Almanac: a query
/// is ~3s when inference is healthy, and if the box is unreachable the liveness
/// probe alone can burn seconds before it degrades to keyword.
const ALMANAC_GROUNDING_TIMEOUT_SECS: u64 = 12;

/// Resolve the `almanac` CLI: `CHUMP_ALMANAC_BIN`, then the usual checkout.
fn almanac_cli_bin() -> Option<String> {
    if let Ok(b) = std::env::var("CHUMP_ALMANAC_BIN") {
        if Path::new(&b).is_file() {
            return Some(b);
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/Projects/almanac/target/release/almanac"),
        format!("{home}/Projects/almanac/target/debug/almanac"),
    ]
    .into_iter()
    .find(|c| Path::new(c).is_file())
}

/// Run a child to completion under a wall-clock ceiling, killing it on timeout.
/// `Command::output()` has no timeout, and an unbounded pre-query would let a
/// wedged inference host stall every dispatch on the box.
fn output_with_timeout(mut cmd: Command, limit: std::time::Duration) -> Option<Vec<u8>> {
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return None;
                }
                let mut buf = Vec::new();
                use std::io::Read;
                child.stdout.take()?.read_to_end(&mut buf).ok()?;
                return Some(buf);
            }
            Ok(None) => {
                if start.elapsed() >= limit {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(_) => return None,
        }
    }
}

/// Phase D — proactive grounding.
///
/// Pre-query Almanac with the gap's own words and hand the agent grounded
/// `path:line` starting points BEFORE it begins, rather than relying on it to
/// remember that the tool exists. The static briefing directive
/// (`context_assembly.rs`) is a nudge; this is the pull.
///
/// Every failure path returns `None` and the prompt is unchanged: no binary, no
/// index, non-zero exit, unparseable output, timeout, or zero hits. A dispatch
/// must never fail, hang, or wait on Almanac.
///
/// Honesty rules baked into the block, because an agent cannot verify these
/// itself: a STALE index says so inline, and a degraded (keyword-only) answer
/// says so too. Grounded-but-stale silently presented as current is worse than
/// no context at all — the agent would trust `path:line` citations that moved.
///
/// Disable with `CHUMP_ALMANAC_ENABLED=0` (kills all Almanac use) or
/// `CHUMP_ALMANAC_DISPATCH_GROUNDING=0` (kills only this pre-query).
fn almanac_grounding_block(gap: &Gap, repo_root: &Path) -> Option<String> {
    if std::env::var("CHUMP_ALMANAC_ENABLED").as_deref() == Ok("0")
        || std::env::var("CHUMP_ALMANAC_DISPATCH_GROUNDING").as_deref() == Ok("0")
    {
        return None;
    }
    // The gap's title is the query. A bare id like "INFRA-3530" retrieves
    // nothing useful, so if there is no title there is nothing worth asking.
    let query = gap.title.trim();
    if query.is_empty() {
        return None;
    }
    let bin = almanac_cli_bin()?;

    // Name the repo EXPLICITLY by path instead of relying on the CLI's default
    // resolution. With ~100 repos in Almanac's registry a bare query fails with
    // "multiple repos registered", and dispatch runs from a worktree whose cwd
    // is not the registered repo root anyway.
    let mut cmd = Command::new(bin);
    cmd.current_dir(repo_root)
        .arg("search")
        .arg(query)
        .arg(repo_root.as_os_str())
        .arg("--json")
        .arg("--limit")
        .arg(ALMANAC_GROUNDING_HITS.to_string());
    let out = output_with_timeout(
        cmd,
        std::time::Duration::from_secs(ALMANAC_GROUNDING_TIMEOUT_SECS),
    )?;
    let v: serde_json::Value = serde_json::from_slice(&out).ok()?;

    let hits = v.get("hits")?.as_array()?;
    if hits.is_empty() {
        return None;
    }

    let mut block = String::from(
        "\n\n---\n\n[Almanac — grounded starting points for this gap, pre-fetched]\n\
         These came from searching the index for this gap's title. They are a map, not \
         the answer: verify before you rely on any of them, and call almanac_search / \
         almanac_api yourself for anything they do not cover.\n",
    );
    for h in hits {
        let citation = h.get("citation").and_then(|c| c.as_str()).unwrap_or("");
        if citation.is_empty() {
            continue;
        }
        let kind = h.get("kind").and_then(|c| c.as_str()).unwrap_or("");
        let name = h.get("name").and_then(|c| c.as_str()).unwrap_or("");
        block.push_str(&format!("  - {citation}  ({kind} {name})\n"));
    }

    let stale = v
        .get("grounding")
        .and_then(|g| g.get("stale"))
        .and_then(|s| s.as_bool())
        .unwrap_or(false);
    if stale {
        block.push_str(
            "  NOTE: the index is STALE (HEAD has moved past the indexed commit). Line \
             numbers may have shifted — treat these as hints, not citations.\n",
        );
    }
    if let Some(reason) = v.get("fallback_reason").and_then(|r| r.as_str()) {
        block.push_str(&format!(
            "  NOTE: semantic search degraded ({reason}) — these are keyword matches only, \
             so conceptually-related files are probably missing.\n"
        ));
    }
    Some(block)
}

/// `build_prompt` plus Almanac's pre-fetched grounding, when available.
///
/// Kept separate from `build_prompt` so that builder — and the
/// `scripts/ci/test-subagent-epilogue-ref.sh` guard over it — stays unchanged,
/// and so the grounding can be tested without spawning a subagent.
pub fn build_prompt_grounded(gap: &Gap, repo_root: &Path) -> String {
    let mut prompt = build_prompt(&gap.id, repo_root);
    if let Some(block) = almanac_grounding_block(gap, repo_root) {
        prompt.push_str(&block);
    }
    prompt
}

/// Derive the worktree path + branch name for a gap. Lowercased, underscores
/// rewritten to hyphens (matching the conventions in musher.sh and the
/// existing `.claude/worktrees/<name>/` tree).
pub fn dispatch_paths(repo_root: &Path, gap_id: &str) -> (PathBuf, String) {
    let slug = gap_id.to_ascii_lowercase().replace('_', "-");
    let worktree = repo_root.join(".claude").join("worktrees").join(&slug);
    let branch = format!("claude/{slug}");
    (worktree, branch)
}

/// Dispatch a single gap. Creates the worktree, claims the lease, spawns
/// `claude -p <prompt>`, returns a handle for the monitor loop.
///
/// `repo_root` is the top-level git repo. `base_ref` is the git ref the new
/// worktree branches off (caller typically passes `"origin/main"`).
pub fn dispatch_gap_with<S: Spawner>(
    spawner: &S,
    gap: &Gap,
    repo_root: &Path,
    base_ref: &str,
) -> Result<DispatchHandle> {
    let (worktree, branch) = dispatch_paths(repo_root, &gap.id);

    spawner
        .create_worktree(&worktree, &branch, base_ref)
        .with_context(|| format!("creating worktree {} for {}", worktree.display(), gap.id))?;

    spawner
        .claim_gap(&worktree, &gap.id)
        .with_context(|| format!("claiming lease for {} in {}", gap.id, worktree.display()))?;

    // COG-038: resolve the full routing tuple (backend + model + provider)
    // once, log rationale, and carry every component on the DispatchHandle.
    // Env override still wins (operator always); otherwise we take the
    // *head* of the YAML cascade so `routing_outcomes.model` /
    // `routing_outcomes.provider_pfx` get populated and the COG-037
    // Thompson sampler has the join key it needs to learn from outcomes.
    let (backend, model, provider_pfx, why) =
        resolve_route_for_gap(repo_root, &gap.id, &gap.priority, &gap.effort);
    eprintln!(
        "[dispatch] route gap={} priority={} effort={} → backend={} model={} provider={} reason={}",
        gap.id,
        gap.priority,
        gap.effort,
        backend.label(),
        model.as_deref().unwrap_or("-"),
        provider_pfx.as_deref().unwrap_or("-"),
        why,
    );

    let prompt = build_prompt_grounded(gap, repo_root);
    let (child, stderr_tail) = spawner
        .spawn_claude(&worktree, &prompt, backend)
        .with_context(|| format!("spawning claude for {}", gap.id))?;

    let pid = child.as_ref().map(|c| c.id());
    let started_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before UNIX epoch")?
        .as_secs();

    Ok(DispatchHandle {
        gap_id: gap.id.clone(),
        worktree_path: worktree,
        branch_name: branch,
        child_pid: pid,
        started_at_unix,
        child,
        stderr_tail,
        backend,
        model,
        provider_pfx,
    })
}

/// COG-038 — resolve the full `(backend, model, provider_pfx, why)` tuple
/// for a gap. Precedence:
///
/// 1. **Env override** (`CHUMP_DISPATCH_BACKEND`) wins — operator always
///    has the last word. When set, model/provider come from the matching
///    `CHUMP_DISPATCH_MODEL` / `CHUMP_DISPATCH_PROVIDER_PFX` env vars
///    (None when unset). Rationale = `"env:<value>"`.
/// 2. **YAML cascade head** otherwise — first candidate from
///    [`select_candidates_for_gap`]. Carries the full
///    `(backend, model, provider_pfx)` tuple from the chosen
///    [`Candidate`]. Rationale = `"cascade:<candidate.why>"`.
///
/// The cascade head is what COG-035 (YAML routing), COG-036 (scoreboard),
/// and COG-037 (Thompson sampler) all converge on — using it here is what
/// finally connects dispatch decisions to learned outcomes.
fn resolve_route_for_gap(
    repo_root: &Path,
    gap_id: &str,
    priority: &str,
    effort: &str,
) -> (DispatchBackend, Option<String>, Option<String>, String) {
    // Env override path — preserved for back-compat with CHUMP_DISPATCH_*.
    let env_raw = std::env::var("CHUMP_DISPATCH_BACKEND")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    if let Some(raw) = env_raw {
        let backend = match raw.as_str() {
            "claude" => Some(DispatchBackend::Claude),
            "chump-local" | "chump_local" | "local" => Some(DispatchBackend::ChumpLocal),
            _ => None,
        };
        if let Some(b) = backend {
            let model = std::env::var("CHUMP_DISPATCH_MODEL")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            let provider_pfx = std::env::var("CHUMP_DISPATCH_PROVIDER_PFX")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            return (b, model, provider_pfx, format!("env:{}", b.label()));
        }
        eprintln!(
            "[dispatch] WARN unknown CHUMP_DISPATCH_BACKEND={raw:?}; \
             falling back to cascade (valid: claude | chump-local)"
        );
    }

    // Cascade head — full tuple from the first Candidate.
    let cands = select_candidates_for_gap(repo_root, gap_id, priority, effort);
    if let Some(head) = cands.first() {
        return (
            head.backend,
            head.model.clone(),
            head.provider_pfx.clone(),
            format!("cascade:{}", head.why),
        );
    }
    // Cascade returned nothing (shouldn't happen — hardcoded fallback always
    // seeds at least one). Keep the dispatcher running rather than panic.
    let (b, why) = select_backend_for_gap(priority, effort);
    (b, None, None, format!("fallback:{why}"))
}

/// Production entry point: dispatch a gap using the real `RealSpawner`.
pub fn dispatch_gap(gap: &Gap, repo_root: &Path, base_ref: &str) -> Result<DispatchHandle> {
    dispatch_gap_with(&RealSpawner, gap, repo_root, base_ref)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Test spawner that records every call and never touches the real
    /// filesystem or forks a process. This is the contract enforcement: the
    /// dispatch flow must call create_worktree → claim_gap → spawn_claude in
    /// order, with the correctly-derived paths.
    #[derive(Default)]
    struct RecordingSpawner {
        calls: RefCell<Vec<String>>,
    }

    impl Spawner for RecordingSpawner {
        fn create_worktree(&self, worktree: &Path, branch: &str, base: &str) -> Result<()> {
            self.calls.borrow_mut().push(format!(
                "worktree:{}:{}:{}",
                worktree.display(),
                branch,
                base
            ));
            Ok(())
        }
        fn claim_gap(&self, worktree: &Path, gap_id: &str) -> Result<()> {
            self.calls
                .borrow_mut()
                .push(format!("claim:{}:{}", worktree.display(), gap_id));
            Ok(())
        }
        fn spawn_claude(
            &self,
            worktree: &Path,
            prompt: &str,
            backend: DispatchBackend,
        ) -> Result<SpawnResult> {
            self.calls.borrow_mut().push(format!(
                "spawn:{}:{}:{}",
                worktree.display(),
                prompt.len(),
                backend.label()
            ));
            Ok((None, None))
        }
    }

    fn fake_gap(id: &str) -> Gap {
        Gap {
            id: id.into(),
            title: "t".into(),
            priority: "P1".into(),
            effort: "m".into(),
            status: "open".into(),
            kind: String::new(),
            depends_on: None,
            closed_date: None,
        }
    }

    // --- Phase D: Almanac pre-fetched grounding -----------------------------
    // These assert the FAILURE paths, because the whole design constraint is
    // that a dispatch must never fail, hang, or wait on Almanac.

    #[test]
    fn grounding_is_skipped_when_disabled() {
        let g = fake_gap("INFRA-1");
        std::env::set_var("CHUMP_ALMANAC_DISPATCH_GROUNDING", "0");
        assert!(almanac_grounding_block(&g, Path::new("/nonexistent")).is_none());
        std::env::remove_var("CHUMP_ALMANAC_DISPATCH_GROUNDING");

        std::env::set_var("CHUMP_ALMANAC_ENABLED", "0");
        assert!(almanac_grounding_block(&g, Path::new("/nonexistent")).is_none());
        std::env::remove_var("CHUMP_ALMANAC_ENABLED");
    }

    #[test]
    fn grounding_is_skipped_without_a_title_to_query_with() {
        // A bare id like "INFRA-3530" retrieves nothing useful; querying with it
        // would spend seconds to inject noise.
        let mut g = fake_gap("INFRA-3530");
        g.title = "   ".into();
        std::env::set_var("CHUMP_ALMANAC_BIN", "/definitely/not/a/binary");
        assert!(almanac_grounding_block(&g, Path::new("/nonexistent")).is_none());
        std::env::remove_var("CHUMP_ALMANAC_BIN");
    }

    #[test]
    fn grounded_prompt_falls_back_to_the_plain_prompt_when_almanac_is_absent() {
        // The load-bearing guarantee: no almanac binary must leave dispatch
        // behaving exactly as it did before Phase D existed.
        std::env::set_var("CHUMP_ALMANAC_DISPATCH_GROUNDING", "0");
        let g = fake_gap("AUTO-013");
        let plain = build_prompt(&g.id, Path::new("/nonexistent"));
        let grounded = build_prompt_grounded(&g, Path::new("/nonexistent"));
        std::env::remove_var("CHUMP_ALMANAC_DISPATCH_GROUNDING");
        assert_eq!(plain, grounded);
        assert!(grounded.contains("AUTO-013"));
    }

    #[test]
    fn output_with_timeout_kills_a_hung_child() {
        // Dispatch cannot be held hostage by a wedged inference host.
        let mut cmd = Command::new("sleep");
        cmd.arg("30");
        let started = std::time::Instant::now();
        let out = output_with_timeout(cmd, std::time::Duration::from_millis(300));
        assert!(out.is_none(), "a timed-out child must yield no output");
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "timeout did not actually bound the wait: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn output_with_timeout_returns_stdout_on_success() {
        let mut cmd = Command::new("echo");
        cmd.arg("hello");
        let out = output_with_timeout(cmd, std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(String::from_utf8_lossy(&out).trim(), "hello");
    }

    #[test]
    fn output_with_timeout_rejects_a_nonzero_exit() {
        // A failing almanac must not be parsed as an empty-but-valid answer.
        let cmd = Command::new("false");
        assert!(output_with_timeout(cmd, std::time::Duration::from_secs(5)).is_none());
    }

    #[test]
    fn dispatch_paths_lowercases_and_replaces_underscores() {
        let (wt, branch) = dispatch_paths(Path::new("/repo"), "AUTO_013");
        assert_eq!(wt, PathBuf::from("/repo/.claude/worktrees/auto-013"));
        assert_eq!(branch, "claude/auto-013");
    }

    /// INFRA-WORKTREE-PATH-CASE: `dispatch_paths` must preserve the exact
    /// capitalization of `repo_root`. Only the gap slug is lowercased;
    /// the repo root prefix is passed through verbatim. On macOS HFS+/APFS
    /// a wrong-case repo root silently resolves but breaks case-sensitive
    /// tools. The fix is in `resolve_repo_root` (main.rs) which canonicalizes
    /// the path before it reaches here — this test documents the contract.
    #[test]
    fn dispatch_paths_preserves_repo_root_case() {
        // Simulate a correct-cased repo root — slug alone is lowercased.
        let (wt, branch) = dispatch_paths(Path::new("/Users/JeffAdkins/Projects/Chump"), "MEM-007");
        assert_eq!(
            wt,
            PathBuf::from("/Users/JeffAdkins/Projects/Chump/.claude/worktrees/mem-007")
        );
        assert_eq!(branch, "claude/mem-007");
        // The repo root prefix is NOT lowercased — only the gap slug is.
        assert!(
            wt.to_str()
                .unwrap()
                .starts_with("/Users/JeffAdkins/Projects/Chump"),
            "repo root case must be preserved; got {}",
            wt.display()
        );
    }

    #[test]
    fn dispatch_calls_steps_in_order() {
        let spawner = RecordingSpawner::default();
        let gap = fake_gap("AUTO-013");
        let handle = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();

        let calls = spawner.calls.borrow();
        assert_eq!(calls.len(), 3);
        assert!(calls[0].starts_with("worktree:"), "first call = worktree");
        assert!(calls[1].starts_with("claim:"), "second call = claim");
        assert!(calls[2].starts_with("spawn:"), "third call = spawn");

        assert_eq!(handle.gap_id, "AUTO-013");
        assert_eq!(handle.branch_name, "claude/auto-013");
        assert_eq!(
            handle.worktree_path,
            PathBuf::from("/repo/.claude/worktrees/auto-013")
        );
        assert!(handle.child_pid.is_none(), "recording spawner = no pid");
        assert!(handle.started_at_unix > 0);
    }

    #[test]
    fn claim_receives_exact_gap_id() {
        let spawner = RecordingSpawner::default();
        let gap = fake_gap("EVAL-031");
        let _ = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
        let calls = spawner.calls.borrow();
        assert!(
            calls[1].ends_with(":EVAL-031"),
            "claim must pass exact gap id, got {}",
            calls[1]
        );
    }

    #[test]
    fn build_prompt_contains_gap_id_and_ship_command() {
        let prompt = build_prompt("AUTO-013", Path::new("/nonexistent"));
        assert!(prompt.contains("AUTO-013"));
        assert!(prompt.contains("scripts/coord/bot-merge.sh --gap AUTO-013 --auto-merge"));
        assert!(prompt.contains("PR number"));
    }

    #[test]
    fn build_prompt_injects_dispatch_rules_when_file_present() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("process");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("CHUMP_DISPATCH_RULES.md"),
            "## rule\n- do the thing\n",
        )
        .unwrap();
        let prompt = build_prompt("MEM-001", dir.path());
        assert!(
            prompt.contains("do the thing"),
            "rules block should be injected"
        );
        assert!(prompt.contains("MEM-001"));
    }

    #[test]
    fn build_prompt_gracefully_missing_rules_file() {
        let prompt = build_prompt("EVAL-001", Path::new("/nonexistent"));
        assert!(prompt.contains("EVAL-001"));
        assert!(prompt.contains("bot-merge.sh"));
    }

    #[test]
    fn stderr_tail_snapshot_returns_empty_when_no_buffer() {
        let h = DispatchHandle {
            gap_id: "X".into(),
            worktree_path: PathBuf::from("/tmp"),
            branch_name: "claude/x".into(),
            child_pid: None,
            started_at_unix: 0,
            child: None,
            stderr_tail: None,
            backend: DispatchBackend::Claude,
            model: None,
            provider_pfx: None,
        };
        assert_eq!(h.stderr_tail_snapshot(), "");
    }

    #[test]
    fn stderr_tail_snapshot_joins_lines_with_newlines() {
        let buf = Arc::new(Mutex::new(vec![
            "ERROR: foo".to_string(),
            "WARN: bar".to_string(),
        ]));
        let h = DispatchHandle {
            gap_id: "X".into(),
            worktree_path: PathBuf::from("/tmp"),
            branch_name: "claude/x".into(),
            child_pid: None,
            started_at_unix: 0,
            child: None,
            stderr_tail: Some(buf),
            backend: DispatchBackend::Claude,
            model: None,
            provider_pfx: None,
        };
        assert_eq!(h.stderr_tail_snapshot(), "ERROR: foo\nWARN: bar");
    }

    // ── COG-025: backend selector ────────────────────────────────────────

    /// Run a closure with `CHUMP_DISPATCH_BACKEND` set to `value` and
    /// restore the previous env after, even on panic. Required because
    /// `from_env` reads process env and tests run in the same process.
    fn with_backend_env(value: Option<&str>, f: impl FnOnce()) {
        let prev = std::env::var("CHUMP_DISPATCH_BACKEND").ok();
        match value {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_BACKEND", v),
            None => std::env::remove_var("CHUMP_DISPATCH_BACKEND"),
        }
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
        match prev {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_BACKEND", v),
            None => std::env::remove_var("CHUMP_DISPATCH_BACKEND"),
        }
        if let Err(e) = result {
            std::panic::resume_unwind(e);
        }
    }

    #[test]
    #[serial_test::serial]
    fn backend_default_is_claude() {
        with_backend_env(None, || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::Claude);
        });
    }

    #[test]
    #[serial_test::serial]
    fn backend_recognises_chump_local() {
        with_backend_env(Some("chump-local"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::ChumpLocal);
        });
        with_backend_env(Some("chump_local"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::ChumpLocal);
        });
        with_backend_env(Some("local"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::ChumpLocal);
        });
    }

    #[test]
    #[serial_test::serial]
    fn backend_unknown_falls_back_to_claude() {
        with_backend_env(Some("ollama-direct"), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::Claude);
        });
        with_backend_env(Some(""), || {
            assert_eq!(DispatchBackend::from_env(), DispatchBackend::Claude);
        });
    }

    /// INFRA-097 regression: a dispatch prompt that begins with `---`
    /// (which CHUMP_DISPATCH_RULES.md does — YAML frontmatter) must NOT
    /// be passed as an argv positional to `claude`. clap interprets a
    /// `---`-leading argv as an unknown long option and exits before the
    /// agent ever starts. The fix pipes the prompt through stdin instead.
    #[test]
    #[serial_test::serial]
    fn spawn_claude_cli_pipes_prompt_via_stdin_not_argv() {
        let tmp = tempfile::tempdir().unwrap();
        let argv_log = tmp.path().join("argv.log");
        let stdin_log = tmp.path().join("stdin.log");
        let fake_claude = tmp.path().join("fake-claude.sh");

        // Fake claude: record argv (one per line) + stdin, exit 0.
        std::fs::write(
            &fake_claude,
            format!(
                "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > {argv}\ncat > {stdin}\nexit 0\n",
                argv = argv_log.display(),
                stdin = stdin_log.display(),
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        let prev = std::env::var("CHUMP_CLAUDE_BIN").ok();
        std::env::set_var("CHUMP_CLAUDE_BIN", &fake_claude);

        // Prompt starts with `---` exactly like CHUMP_DISPATCH_RULES.md does.
        let prompt = "---\ndoc_tag: canonical\n---\n\nYou are a Chump dispatched agent working on gap INFRA-097.\n";

        let spawner = RealSpawner;
        let (child_opt, _tail) = spawner
            .spawn_claude_cli(tmp.path(), prompt)
            .expect("spawn_claude_cli must succeed against fake binary");
        let mut child = child_opt.expect("real spawn returns Some(child)");
        let status = child.wait().expect("fake claude exits cleanly");
        assert!(status.success(), "fake claude exited non-zero: {status:?}");

        let argv = std::fs::read_to_string(&argv_log).unwrap_or_default();
        let stdin_seen = std::fs::read_to_string(&stdin_log).unwrap_or_default();

        // The flag args are still on argv, but the prompt body is NOT.
        assert!(
            argv.contains("-p"),
            "argv should still contain -p: {argv:?}"
        );
        assert!(
            argv.contains("--dangerously-skip-permissions"),
            "argv should still contain perms flag: {argv:?}"
        );
        assert!(
            !argv.contains("INFRA-097"),
            "prompt body must NOT appear on argv (clap parses ---): {argv:?}"
        );
        assert!(
            !argv.contains("---"),
            "leading frontmatter must NOT appear on argv: {argv:?}"
        );

        // The full prompt MUST be on stdin.
        assert_eq!(stdin_seen, prompt, "prompt must arrive verbatim via stdin");

        match prev {
            Some(v) => std::env::set_var("CHUMP_CLAUDE_BIN", v),
            None => std::env::remove_var("CHUMP_CLAUDE_BIN"),
        }
    }

    // ── INFRA-063 (M5): cost-routed backend selector ────────────────────

    #[test]
    fn select_backend_xs_is_cheap() {
        let (b, why) = select_backend_for_gap("P1", "xs");
        assert_eq!(b, DispatchBackend::ChumpLocal);
        assert!(why.contains("xs"));
    }

    #[test]
    fn select_backend_p1_large_is_frontier() {
        let (b, why) = select_backend_for_gap("P1", "l");
        assert_eq!(b, DispatchBackend::Claude);
        assert!(why.contains("frontier"));
        let (b, _) = select_backend_for_gap("P1", "xl");
        assert_eq!(b, DispatchBackend::Claude);
    }

    #[test]
    fn select_backend_default_is_cheap() {
        let (b, why) = select_backend_for_gap("P2", "m");
        assert_eq!(b, DispatchBackend::ChumpLocal);
        assert!(why.contains("default"));
        let (b, _) = select_backend_for_gap("P2", "s");
        assert_eq!(b, DispatchBackend::ChumpLocal);
    }

    #[test]
    fn select_backend_handles_case_and_whitespace() {
        let (b, _) = select_backend_for_gap("P1", "  XS ");
        assert_eq!(b, DispatchBackend::ChumpLocal);
    }

    #[test]
    fn backend_label_is_stable() {
        // Reflection rows depend on these labels — changing them silently
        // breaks downstream A/B aggregation in COG-026.
        assert_eq!(DispatchBackend::Claude.label(), "claude");
        assert_eq!(DispatchBackend::ChumpLocal.label(), "chump-local");
    }

    #[test]
    #[serial_test::serial]
    fn dispatch_handle_records_backend() {
        // INFRA-065: handle.backend reflects the resolved choice — env when
        // set, advisor pick otherwise. fake_gap is P1/m which the advisor
        // routes to ChumpLocal (default → cheap tier); operator override
        // via env wins.
        with_backend_env(Some("chump-local"), || {
            let spawner = RecordingSpawner::default();
            let gap = fake_gap("COG-025");
            let h = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
            assert_eq!(h.backend, DispatchBackend::ChumpLocal);
        });
        with_backend_env(Some("claude"), || {
            let spawner = RecordingSpawner::default();
            let gap = fake_gap("COG-025");
            let h = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
            assert_eq!(h.backend, DispatchBackend::Claude);
        });
        with_backend_env(None, || {
            let spawner = RecordingSpawner::default();
            let gap = fake_gap("COG-025"); // P1 + m → advisor default → cheap
            let h = dispatch_gap_with(&spawner, &gap, Path::new("/repo"), "origin/main").unwrap();
            assert_eq!(h.backend, DispatchBackend::ChumpLocal);
        });
    }

    // INFRA-065: env-vs-advisor precedence

    #[test]
    #[serial_test::serial]
    fn resolve_for_gap_env_overrides_advisor() {
        with_backend_env(Some("claude"), || {
            // Advisor would pick ChumpLocal here, but env wins.
            let (b, why) = DispatchBackend::resolve_for_gap("P2", "xs");
            assert_eq!(b, DispatchBackend::Claude);
            assert!(why.starts_with("env:"));
        });
    }

    #[test]
    #[serial_test::serial]
    fn resolve_for_gap_advisor_when_env_unset() {
        with_backend_env(None, || {
            let (b, why) = DispatchBackend::resolve_for_gap("P1", "l");
            assert_eq!(b, DispatchBackend::Claude);
            assert!(why.starts_with("advisor:"));
            let (b, why) = DispatchBackend::resolve_for_gap("P2", "xs");
            assert_eq!(b, DispatchBackend::ChumpLocal);
            assert!(why.starts_with("advisor:"));
        });
    }

    #[test]
    #[serial_test::serial]
    fn resolve_for_gap_unknown_env_falls_back_to_advisor() {
        with_backend_env(Some("ollama-direct"), || {
            let (b, why) = DispatchBackend::resolve_for_gap("P1", "l");
            assert_eq!(b, DispatchBackend::Claude); // advisor: P1+l → frontier
            assert!(why.starts_with("advisor-after-bad-env:"));
        });
    }

    // ── COG-038: full-tuple route resolution (backend + model + provider) ──

    /// Scoped helper: run `f` with `CHUMP_DISPATCH_{MODEL,PROVIDER_PFX}` set,
    /// restoring previous values after (panic-safe via Drop guard pattern).
    fn with_model_env(model: Option<&str>, provider: Option<&str>, f: impl FnOnce()) {
        let prev_m = std::env::var("CHUMP_DISPATCH_MODEL").ok();
        let prev_p = std::env::var("CHUMP_DISPATCH_PROVIDER_PFX").ok();
        match model {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_MODEL", v),
            None => std::env::remove_var("CHUMP_DISPATCH_MODEL"),
        }
        match provider {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_PROVIDER_PFX", v),
            None => std::env::remove_var("CHUMP_DISPATCH_PROVIDER_PFX"),
        }
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
        match prev_m {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_MODEL", v),
            None => std::env::remove_var("CHUMP_DISPATCH_MODEL"),
        }
        match prev_p {
            Some(v) => std::env::set_var("CHUMP_DISPATCH_PROVIDER_PFX", v),
            None => std::env::remove_var("CHUMP_DISPATCH_PROVIDER_PFX"),
        }
        if let Err(p) = r {
            std::panic::resume_unwind(p);
        }
    }

    #[test]
    #[serial_test::serial]
    fn resolve_route_for_gap_env_override_carries_model_and_provider() {
        with_backend_env(Some("chump-local"), || {
            with_model_env(Some("openai/gpt-oss-120b"), Some("GROQ"), || {
                let dir = tempfile::tempdir().unwrap();
                let (b, m, p, why) = resolve_route_for_gap(dir.path(), "INFRA-001", "P2", "xs");
                assert_eq!(b, DispatchBackend::ChumpLocal);
                assert_eq!(m.as_deref(), Some("openai/gpt-oss-120b"));
                assert_eq!(p.as_deref(), Some("GROQ"));
                assert!(why.starts_with("env:"), "got: {why}");
            });
        });
    }

    #[test]
    #[serial_test::serial]
    fn resolve_route_for_gap_env_override_without_model_returns_none() {
        with_backend_env(Some("claude"), || {
            with_model_env(None, None, || {
                let dir = tempfile::tempdir().unwrap();
                let (b, m, p, why) = resolve_route_for_gap(dir.path(), "INFRA-001", "P2", "xs");
                assert_eq!(b, DispatchBackend::Claude);
                assert_eq!(m, None);
                assert_eq!(p, None);
                assert_eq!(why, "env:claude");
            });
        });
    }

    #[test]
    #[serial_test::serial]
    fn resolve_route_for_gap_cascade_head_carries_candidate_tuple() {
        with_backend_env(None, || {
            with_model_env(None, None, || {
                let dir = tempfile::tempdir().unwrap();
                let docs = dir.path().join("docs").join("dispatch");
                std::fs::create_dir_all(&docs).unwrap();
                std::fs::write(
                    docs.join("routing.yaml"),
                    r#"
default_candidates:
  - { backend: chump-local, model: openai/gpt-oss-120b, provider_pfx: GROQ, why: cheap-default }
"#,
                )
                .unwrap();
                let (b, m, p, why) = resolve_route_for_gap(dir.path(), "INFRA-001", "P2", "xs");
                assert_eq!(b, DispatchBackend::ChumpLocal);
                assert_eq!(m.as_deref(), Some("openai/gpt-oss-120b"));
                assert_eq!(p.as_deref(), Some("GROQ"));
                assert!(why.starts_with("cascade:"), "got: {why}");
            });
        });
    }

    #[test]
    #[serial_test::serial]
    fn resolve_route_for_gap_unknown_env_falls_through_to_cascade() {
        with_backend_env(Some("ollama-direct"), || {
            with_model_env(None, None, || {
                let dir = tempfile::tempdir().unwrap();
                // No routing.yaml → hardcoded fallback. xs → cheap.
                let (b, _m, _p, why) = resolve_route_for_gap(dir.path(), "INFRA-001", "P2", "xs");
                assert_eq!(b, DispatchBackend::ChumpLocal);
                assert!(why.starts_with("cascade:"), "got: {why}");
            });
        });
    }

    #[test]
    fn parse_gap_id_from_prompt_extracts_canonical() {
        let prompt = build_prompt("COG-025", Path::new("/nonexistent"));
        assert_eq!(
            parse_gap_id_from_prompt(&prompt).as_deref(),
            Some("COG-025")
        );
        let p2 = build_prompt("AUTO-013", Path::new("/nonexistent"));
        assert_eq!(parse_gap_id_from_prompt(&p2).as_deref(), Some("AUTO-013"));
    }

    #[test]
    fn parse_gap_id_from_prompt_returns_none_on_unknown_shape() {
        assert_eq!(parse_gap_id_from_prompt("hello world"), None);
        assert_eq!(parse_gap_id_from_prompt(""), None);
        // marker present but no id after
        assert_eq!(
            parse_gap_id_from_prompt("working on gap "),
            None,
            "empty id after marker should yield None"
        );
    }

    #[test]
    #[serial_test::serial(chump_local_bin_env)]
    fn resolve_chump_local_bin_honors_env_override() {
        std::env::set_var("CHUMP_LOCAL_BIN", "/opt/custom/chump");
        let p = resolve_chump_local_bin(Path::new("/nonexistent/worktree"));
        std::env::remove_var("CHUMP_LOCAL_BIN");
        assert_eq!(p, PathBuf::from("/opt/custom/chump"));
    }

    #[test]
    #[serial_test::serial(chump_local_bin_env)]
    fn resolve_chump_local_bin_falls_back_to_path_when_no_target() {
        // Use a dir that definitely has no target/ tree.
        std::env::remove_var("CHUMP_LOCAL_BIN");
        let p = resolve_chump_local_bin(Path::new("/tmp/cog-025-no-target-here-xyz"));
        assert_eq!(p, PathBuf::from("chump"));
    }

    // ── COG-035: legacy wrapper sanity ────────────────────────────────

    /// `select_backend_for_gap` is now a thin wrapper around
    /// `RoutingTable::hardcoded_fallback().select(...)`. Its first-candidate
    /// projection MUST still match the pre-COG-035 heuristic for the cases
    /// callers historically relied on.
    #[test]
    fn select_backend_for_gap_still_returns_xs_chump_local() {
        let (b, _) = select_backend_for_gap("P2", "xs");
        assert_eq!(b, DispatchBackend::ChumpLocal);
        let (b, _) = select_backend_for_gap("P1", "xs");
        assert_eq!(b, DispatchBackend::ChumpLocal);
    }

    #[test]
    fn task_class_for_gap_id_recognises_research_prefixes() {
        assert_eq!(task_class_for_gap_id("EVAL-031"), Some("research"));
        assert_eq!(task_class_for_gap_id("RESEARCH-014"), Some("research"));
        assert_eq!(task_class_for_gap_id("eval-031"), Some("research"));
        assert_eq!(task_class_for_gap_id("INFRA-080"), None);
        assert_eq!(task_class_for_gap_id(""), None);
    }

    #[test]
    fn task_class_for_gap_id_recognises_cognition_prefix() {
        // INFRA-265: COG-* surfaces as Some("cognition") so routing.yaml
        // can pin cognitive-architecture work to claude only.
        assert_eq!(task_class_for_gap_id("COG-035"), Some("cognition"));
        assert_eq!(task_class_for_gap_id("COG-001"), Some("cognition"));
        assert_eq!(task_class_for_gap_id("cog-035"), Some("cognition"));
        // Adjacent prefixes don't false-match.
        assert_eq!(task_class_for_gap_id("COGNITION-1"), None);
        assert_eq!(task_class_for_gap_id("COGS-1"), None);
    }

    #[test]
    fn select_candidates_for_gap_falls_back_when_yaml_missing() {
        // tempdir → no docs/dispatch/routing.yaml → hardcoded fallback path.
        let dir = tempfile::tempdir().unwrap();
        let cands = select_candidates_for_gap(dir.path(), "INFRA-080", "P1", "xs");
        assert!(!cands.is_empty());
        assert_eq!(cands[0].backend, DispatchBackend::ChumpLocal);

        let cands = select_candidates_for_gap(dir.path(), "INFRA-080", "P1", "xl");
        assert_eq!(cands[0].backend, DispatchBackend::Claude);
    }

    #[test]
    fn select_candidates_for_gap_routes_research_to_claude_with_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("dispatch");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("routing.yaml"),
            r#"
default_candidates:
  - { backend: chump-local, why: default-cheap }
routes:
  - match: { task_class: research }
    why: research-needs-frontier
    candidates:
      - { backend: claude, why: research-needs-frontier }
"#,
        )
        .unwrap();

        // EVAL-* gap → task_class=research → claude.
        let cands = select_candidates_for_gap(dir.path(), "EVAL-007", "P2", "m");
        assert_eq!(cands[0].backend, DispatchBackend::Claude);

        // INFRA-* gap → no task_class match → default candidates (cheap).
        let cands = select_candidates_for_gap(dir.path(), "INFRA-007", "P2", "m");
        assert_eq!(cands[0].backend, DispatchBackend::ChumpLocal);
    }

    // ── COG-037: Thompson-sampling self-learning router ─────────────────

    /// Helper that scopes `CHUMP_FLAGS` for the duration of a closure. The
    /// chump binary's `runtime_flags` caches at first use via OnceLock; the
    /// orchestrator-crate path (`cog_037_enabled`) re-reads each call so we
    /// can toggle reliably here.
    fn with_chump_flags<F: FnOnce()>(value: Option<&str>, f: F) {
        let prev = std::env::var("CHUMP_FLAGS").ok();
        match value {
            Some(v) => std::env::set_var("CHUMP_FLAGS", v),
            None => std::env::remove_var("CHUMP_FLAGS"),
        }
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
        match prev {
            Some(v) => std::env::set_var("CHUMP_FLAGS", v),
            None => std::env::remove_var("CHUMP_FLAGS"),
        }
        if let Err(e) = result {
            std::panic::resume_unwind(e);
        }
    }

    /// Flag-OFF path must be byte-identical to the COG-035 YAML-driven
    /// ordering. We assert on the full (backend, model, provider_pfx, why)
    /// tuple of every candidate in the cascade.
    #[test]
    #[serial_test::serial(chump_flags_env)]
    fn select_candidates_flag_off_is_byte_identical_to_cog_035() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("dispatch");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("routing.yaml"),
            r#"
default_candidates:
  - { backend: chump-local, model: meta-llama/Llama-3.3-70B-Instruct-Turbo-Free, provider_pfx: TOGETHER, why: free-tier-default }
  - { backend: chump-local, model: openai/gpt-oss-120b, provider_pfx: GROQ, why: groq-fallback }
  - { backend: claude, why: frontier-fallback }
routes:
  - match: { effort: xs }
    why: x
    candidates:
      - { backend: chump-local, model: openai/gpt-oss-120b, provider_pfx: GROQ, why: groq-fast-cheap }
      - { backend: chump-local, model: meta-llama/Llama-3.3-70B-Instruct-Turbo-Free, provider_pfx: TOGETHER, why: together-free-fallback }
"#,
        )
        .unwrap();

        with_chump_flags(None, || {
            let cands = select_candidates_for_gap(dir.path(), "INFRA-007", "P2", "xs");
            assert_eq!(cands.len(), 2);
            assert_eq!(cands[0].provider_pfx.as_deref(), Some("GROQ"));
            assert_eq!(cands[1].provider_pfx.as_deref(), Some("TOGETHER"));
            // P2/m/no-class falls through to default_candidates in order.
            let cands = select_candidates_for_gap(dir.path(), "INFRA-007", "P2", "m");
            assert_eq!(cands.len(), 3);
            assert_eq!(cands[0].provider_pfx.as_deref(), Some("TOGETHER"));
            assert_eq!(cands[1].provider_pfx.as_deref(), Some("GROQ"));
            assert_eq!(cands[2].backend, DispatchBackend::Claude);
        });

        // Setting CHUMP_FLAGS to a flag we DON'T care about must also
        // leave behaviour identical — only `cog_037` flips the path.
        with_chump_flags(Some("cog_999_unrelated"), || {
            let cands = select_candidates_for_gap(dir.path(), "INFRA-007", "P2", "m");
            assert_eq!(cands.len(), 3);
            assert_eq!(cands[0].provider_pfx.as_deref(), Some("TOGETHER"));
        });
    }

    /// Flag-ON path with an empty scoreboard must still return a non-empty
    /// candidate list (graceful default — every arm samples from the
    /// uniform Beta(1,1) prior, so the order may differ but no candidate
    /// is dropped).
    #[test]
    #[serial_test::serial(chump_flags_env)]
    fn select_candidates_flag_on_empty_scoreboard_returns_full_cascade() {
        let dir = tempfile::tempdir().unwrap();
        // No .chump/state.db at all — load_scoreboard_signatures must
        // gracefully return an empty map, and rank_by_thompson must still
        // produce a permutation of the YAML cascade.
        let docs = dir.path().join("docs").join("dispatch");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("routing.yaml"),
            r#"
default_candidates:
  - { backend: chump-local, model: a, provider_pfx: X, why: x }
  - { backend: chump-local, model: b, provider_pfx: Y, why: y }
  - { backend: claude, why: z }
routes: []
"#,
        )
        .unwrap();

        with_chump_flags(Some("cog_037"), || {
            let cands = select_candidates_for_gap(dir.path(), "INFRA-007", "P2", "m");
            assert_eq!(
                cands.len(),
                3,
                "no candidate must be dropped on empty scoreboard"
            );
            // Permutation check — every input arm appears exactly once.
            let sigs: Vec<String> = cands.iter().map(|c| c.signature()).collect();
            assert!(sigs.contains(&"chump-local|a|X".to_string()));
            assert!(sigs.contains(&"chump-local|b|Y".to_string()));
            assert!(sigs.contains(&"claude||".to_string()));
        });
    }

    /// `load_scoreboard_signatures` must never panic on a missing DB —
    /// it returns an empty map and lets the caller fall through to the
    /// YAML-only ordering.
    #[test]
    fn load_scoreboard_missing_db_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        let stats = load_scoreboard_signatures(dir.path());
        assert!(stats.is_empty(), "no DB → empty stats map");
    }

    #[test]
    fn worktree_create_failure_aborts_claim_and_spawn() {
        struct FailingWorktree;
        impl Spawner for FailingWorktree {
            fn create_worktree(&self, _w: &Path, _b: &str, _r: &str) -> Result<()> {
                bail!("worktree add failed");
            }
            fn claim_gap(&self, _w: &Path, _g: &str) -> Result<()> {
                panic!("must not be called");
            }
            fn spawn_claude(
                &self,
                _w: &Path,
                _p: &str,
                _b: DispatchBackend,
            ) -> Result<SpawnResult> {
                panic!("must not be called");
            }
        }
        let gap = fake_gap("AUTO-013");
        let err = dispatch_gap_with(&FailingWorktree, &gap, Path::new("/repo"), "origin/main")
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("worktree add failed"), "got: {msg}");
    }

    // ── INFRA-718: scope invariants ──────────────────────────────────

    /// INFRA-718: dispatch prompt must include scope invariants that
    /// prevent agents from accepting SWARM-/PRIVATE-/INTERNAL- prefixed
    /// gaps. The rules are injected from CHUMP_DISPATCH_RULES.md, which
    /// is loaded and prepended to the prompt.
    #[test]
    fn build_prompt_includes_scope_invariants_refusing_swarm_gaps() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("process");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("CHUMP_DISPATCH_RULES.md"),
            "---\ndoc_tag: canonical\nowner_gap:\nlast_audited: 2026-04-25\n---\n\n\
             ## SCOPE INVARIANTS (defense-in-depth)\n\n\
             - **Refuse SWARM-, PRIVATE-, INTERNAL- prefixed gaps.** \
             If the gap ID starts with `SWARM-`, `PRIVATE-`, or `INTERNAL-`, \
             immediately reply `SCOPE-REFUSE: this gap domain is out of scope` and exit.\n",
        )
        .unwrap();
        let prompt = build_prompt("SWARM-001", dir.path());
        assert!(
            prompt.contains("SCOPE-REFUSE"),
            "prompt must contain SCOPE-REFUSE instruction"
        );
        assert!(
            prompt.contains("SWARM-"),
            "prompt must mention SWARM- prefix"
        );
    }

    /// INFRA-718: test that the scope invariants block is actually
    /// injected from the rules file and present in the prompt sent
    /// to dispatched agents. This verifies the defense-in-depth
    /// component of INFRA-718 alongside the picker exclusion (INFRA-710).
    #[test]
    fn build_prompt_injects_scope_invariants_from_rules() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("process");
        std::fs::create_dir_all(&docs).unwrap();
        let rules = "## SCOPE INVARIANTS\n\
                    - **Refuse SWARM- gaps.** Reply `SCOPE-REFUSE: blocked scope` and exit.\n\
                    - **Refuse files outside gap.paths.**\n\
                    - **Refuse Cargo.toml dep additions without approval.**\n";
        std::fs::write(docs.join("CHUMP_DISPATCH_RULES.md"), rules).unwrap();

        let prompt = build_prompt("INFRA-718", dir.path());
        assert!(
            prompt.contains("SCOPE-REFUSE"),
            "dispatch prompt must include scope-refuse language"
        );
        assert!(
            prompt.contains("gap.paths"),
            "dispatch prompt must mention gap.paths restriction"
        );
        assert!(
            prompt.contains("Cargo.toml"),
            "dispatch prompt must mention Cargo.toml restriction"
        );
    }
}
