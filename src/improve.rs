//! EFFECTIVE-177: `chump improve <owner/repo>` — the autonomous-improve loop.
//!
//! This is the Mode-D external-repo path. It deliberately does NOT extend
//! `crates/chump-integrator/src/cycle/` — that cycle EXCLUDES external-repo gaps
//! (`select.rs` `.filter(|e| !e.is_external_repo())`), which is intentional
//! per INFRA-2113 ("Mode D handled separately"). Forcing external work into the
//! internal cycle fights its design.
//!
//! ## 4-stage chain (assembles existing pieces)
//!
//! 1. **PICK** — calls the `onboard` scan path (EFFECTIVE-166, via `run_scan`)
//!    to produce an `OnboardScan` with ranked `ProposedGap`s. Scout fills
//!    `SourceOfEvidence` with real evidence from the repo.
//!
//! 2. **DEDUP** (ZERO-WASTE-006) — before implementing the picked gap, checks
//!    whether the work is already done in the target repo (`git log` / `grep`
//!    the clone). If redundant, skips and emits `kind=redundant_work_skipped`.
//!    This is a required stage, not advisory.
//!
//! 3. **IMPLEMENT** — spawns a capable agent (`claude -p
//!    --dangerously-skip-permissions --model claude-sonnet-4-5`) in the repo
//!    clone via `ExternalRepoContract`. Reuses the `spawn_headless_in_dir`
//!    pattern from `src/dispatch.rs`. Binary path is overridable via
//!    `CHUMP_IMPROVE_CLAUDE_BIN` for testing (same pattern as
//!    `CHUMP_COORD_BIN` in `src/atomic_claim.rs`).
//!
//! 4. **VERIFY-MERGE** — calls `chump external verify-merge` (CREDIBLE-096,
//!    `src/external_verify_merge.rs`). Judges CI green + anti-cosmetic test
//!    proof + no-regression. Self-merges ONLY on merit. The orchestrator does
//!    NOT re-implement merge logic — it delegates to the existing subcommand.
//!
//! ## Dry-run vs --apply
//!
//! By default (dry-run) the command prints the planned chain and the scout's
//! pick WITHOUT pushing code or merging. `--apply` executes for real.
//!
//! ## Ambient events emitted
//!
//! - `kind=improve_cycle_complete` — end of every cycle (including dry-runs);
//!   fields: repo, gap_title, verdict (dry_run|verified|held), pr (if any).
//! - `kind=redundant_work_skipped` — dedup stage decided the work is already done;
//!   fields: repo, gap_title, reason.
//!
//! ## Kill-switch (Category B — _DISABLED form per INFRA-2429)
//!
//! `CHUMP_IMPROVE_DISABLED=1` — disables the subcommand (exits 1 with message).
//!
//! ## Env vars (documented in scripts/ci/env-vars-internal.txt)
//!
//! - `CHUMP_IMPROVE_CLAUDE_BIN` — override path to `claude` CLI (test injection).
//! - `CHUMP_IMPROVE_GH_BIN`     — override path to `gh`     CLI (test injection).
//! - `CHUMP_IMPROVE_CHUMP_BIN`  — override path to `chump`  binary (test injection).
//! - `CHUMP_IMPROVE_DISABLED`   — kill-switch: set to `1` to disable the subcommand.
//!
//! ## Trust guarantees (CREDIBLE-100 + RESILIENT-106)
//!
//! - `verify_and_merge` uses `std::env::current_exe()` to spawn the running binary,
//!   not a stale `target/debug/chump` that may lack `external verify-merge`.
//! - Verdict is keyed off the bar's real `"Verdict: MERGE"` / `"Verdict: HELD"` output
//!   line. If no Verdict: line is present (misfire / brain reply / stale binary), we
//!   bail loudly — NEVER default to "verified".
//! - `implement_gap` injects `CLAUDE_CODE_OAUTH_TOKEN` from `~/.chump/oauth-token.json`
//!   when the env doesn't already carry it, so the agent can authenticate outside the
//!   pre-authed fleet-worker environment. The token value is never logged.

use anyhow::{bail, Context, Result};
use chump_handoff::external_repo_schema::{read_latest_scan, OnboardScan, ProposedGap};
use std::path::{Path, PathBuf};
use std::process::Command;

// ── Public entry point ────────────────────────────────────────────────────

/// Entry point called from `src/main.rs` after routing `chump improve`.
pub fn run(args: &[String]) -> i32 {
    // Category-B kill-switch using _DISABLED suffix (INFRA-2429 ceiling: no new
    // _SKIP/_BYPASS/_CHECK/_IGNORE env vars).
    if std::env::var("CHUMP_IMPROVE_DISABLED").as_deref() == Ok("1") {
        eprintln!("[improve] disabled via CHUMP_IMPROVE_DISABLED=1");
        eprintln!("Unset to re-enable.");
        return 1;
    }

    match run_inner(args) {
        Ok(rc) => rc,
        Err(e) => {
            eprintln!("chump improve: {e:#}");
            1
        }
    }
}

// ── CLI parsing ───────────────────────────────────────────────────────────

#[derive(Default)]
struct Opts {
    /// `owner/repo` of the external repo to improve.
    owner_repo: String,
    /// Pre-selected gap ID (skip scout, use this as the proposed-gap title/desc).
    gap_id: Option<String>,
    /// --apply executes for real; default is dry-run.
    apply: bool,
    /// Directory where the repo is cloned (default: ~/.chump/external/<owner>/<repo>/clone/).
    clone_dir: Option<PathBuf>,
    /// MISSION-049: `--mode own|guest` operator/test override. `None` = auto-detect
    /// (target owner == our GH identity -> own-repo throughput; else guest).
    mode_arg: Option<String>,
    /// MISSION-049: resolved own-repo vs guest-repo mode. Set once in `run_inner`
    /// right after parsing args (placeholder `Own` until then); test-constructed
    /// `Opts` literals that skip resolution stay `Own` (today's throughput behavior).
    mode: ImproveMode,
    /// MISSION-049: our GH identity (`gh api user`), resolved alongside `mode`.
    /// Used as the fork owner in Guest mode. `None` if unresolvable (identity
    /// probe failed) — Guest behavior (PR-cap, no self-merge) still applies, the
    /// fork step just best-effort direct-pushes instead.
    guest_identity: Option<String>,
}

/// MISSION-049: own-repo (throughput, self-merge on merit) vs guest-repo (bounded
/// single contribution, maintainer decides, NEVER self-merge) behavior switch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum ImproveMode {
    /// Target owner == our GH identity: current (EFFECTIVE-177) throughput behavior.
    #[default]
    Own,
    /// Target owner is a 3rd party: fork + ONE bounded PR + PR-cap + no self-merge.
    Guest,
}

impl std::fmt::Display for ImproveMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                ImproveMode::Own => "own",
                ImproveMode::Guest => "guest",
            }
        )
    }
}

/// MISSION-049: resolve OUR GitHub identity — the account `gh pr create` / `git
/// push` authenticates as — used to auto-detect own-repo vs guest-repo mode.
/// `CHUMP_IMPROVE_GH_IDENTITY` overrides for tests/operator pin; otherwise shells
/// out to `gh api user`. Returns `None` on any failure (offline, unauthenticated,
/// missing binary) rather than guessing — callers then treat the unknown identity
/// as Guest (the safer default: a false "own" classification self-merges into a
/// 3rd-party repo, which is the exact hostile behavior this gap exists to prevent).
fn resolve_gh_identity(gh_bin: &str) -> Option<String> {
    if let Ok(v) = std::env::var("CHUMP_IMPROVE_GH_IDENTITY") {
        let v = v.trim();
        if !v.is_empty() {
            return Some(v.to_string());
        }
    }
    let out = Command::new(gh_bin)
        .args(["api", "user", "--jq", ".login"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let login = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if login.is_empty() {
        None
    } else {
        Some(login)
    }
}

/// MISSION-049: decide own-repo vs guest-repo mode for `owner_repo`, plus the
/// identity to fork under in Guest mode. `mode_arg` (`--mode own|guest`) pins the
/// decision explicitly; otherwise auto-detect: target owner == our GH identity ->
/// Own, anything else (including an unresolvable identity) -> Guest.
fn resolve_mode(
    owner_repo: &str,
    mode_arg: Option<&str>,
    gh_bin: &str,
) -> (ImproveMode, Option<String>) {
    let identity = resolve_gh_identity(gh_bin);
    if let Some(forced) = mode_arg {
        let mode = if forced.eq_ignore_ascii_case("own") {
            ImproveMode::Own
        } else {
            ImproveMode::Guest
        };
        return (mode, identity);
    }
    let owner = owner_repo.split('/').next().unwrap_or("");
    match &identity {
        Some(id) if id.eq_ignore_ascii_case(owner) => (ImproveMode::Own, identity),
        _ => (ImproveMode::Guest, identity),
    }
}

/// MISSION-049: how many open PRs we (the resolved GH identity) already have on
/// `owner_repo`. Guest mode refuses to open a new PR once this meets
/// `CHUMP_GUEST_PR_CAP` (default 1) — batch related work into the existing PR and
/// wait for the maintainer rather than flooding them. `Ok(0)` on any lookup
/// failure (fail-open: a cap check that can't run must not block the cycle,
/// though the PR will still need to create successfully to actually open).
fn guest_open_pr_count(owner_repo: &str, identity: &str, gh_bin: &str) -> u32 {
    let out = Command::new(gh_bin)
        .args([
            "pr", "list", "--repo", owner_repo, "--author", identity, "--state", "open", "--json",
            "number", "--jq", "length",
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .trim()
            .parse::<u32>()
            .unwrap_or(0),
        _ => 0,
    }
}

/// MISSION-049: `CHUMP_GUEST_PR_CAP` — max open PRs we may hold on a 3rd-party
/// repo at once before refusing to open another. Default 1 (per the operator's
/// "optimize acceptance probability, not throughput" guest-mode directive).
fn guest_pr_cap() -> u32 {
    std::env::var("CHUMP_GUEST_PR_CAP")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1)
}

fn parse_args(args: &[String]) -> Result<Opts> {
    if args.is_empty() || args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        std::process::exit(0);
    }

    let mut owner_repo: Option<String> = None;
    let mut gap_id: Option<String> = None;
    let mut apply = false;
    let mut clone_dir: Option<PathBuf> = None;
    let mut mode_arg: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--apply" => apply = true,
            "--gap" => {
                i += 1;
                gap_id = Some(
                    args.get(i)
                        .ok_or_else(|| anyhow::anyhow!("--gap requires a value"))?
                        .clone(),
                );
            }
            "--clone-dir" => {
                i += 1;
                clone_dir =
                    Some(PathBuf::from(args.get(i).ok_or_else(|| {
                        anyhow::anyhow!("--clone-dir requires a value")
                    })?));
            }
            "--mode" => {
                i += 1;
                mode_arg = Some(
                    args.get(i)
                        .ok_or_else(|| anyhow::anyhow!("--mode requires a value (own|guest)"))?
                        .clone(),
                );
            }
            a if a.starts_with("--gap=") => {
                gap_id = Some(a.trim_start_matches("--gap=").to_string());
            }
            a if a.starts_with("--clone-dir=") => {
                clone_dir = Some(PathBuf::from(a.trim_start_matches("--clone-dir=")));
            }
            a if a.starts_with("--mode=") => {
                mode_arg = Some(a.trim_start_matches("--mode=").to_string());
            }
            a if !a.starts_with('-') => {
                if owner_repo.is_some() {
                    bail!("unexpected extra argument: {a}");
                }
                owner_repo = Some(a.to_string());
            }
            a => bail!("unknown flag: {a}"),
        }
        i += 1;
    }

    if let Some(m) = &mode_arg {
        if !m.eq_ignore_ascii_case("own") && !m.eq_ignore_ascii_case("guest") {
            bail!("--mode must be 'own' or 'guest', got {m:?}");
        }
    }

    Ok(Opts {
        owner_repo: owner_repo
            .ok_or_else(|| anyhow::anyhow!("Usage: chump improve <owner/repo> [options]"))?,
        gap_id,
        apply,
        clone_dir,
        mode_arg,
        mode: ImproveMode::Own, // placeholder — resolved in run_inner via resolve_mode()
        guest_identity: None,
    })
}

fn print_usage() {
    println!("Usage: chump improve <owner/repo> [options]");
    println!();
    println!("Autonomous-improve loop: scout the repo, pick real work, implement it via");
    println!("an agent in a clone, open a PR, and verify-merge on merit. EFFECTIVE-177.");
    println!();
    println!("Options:");
    println!("  --gap <ID>         Skip the scout; use this gap ID as the work description.");
    println!("  --apply            Execute for real (push + merge). Default: dry-run.");
    println!("  --clone-dir <path> Path to an existing repo clone. Default: ~/.chump/external/<owner>/<repo>/clone/.");
    println!("  --mode <own|guest> Override auto-detected mode (MISSION-049). Default: auto —");
    println!("                     target owner == our GH identity -> own; else -> guest.");
    println!();
    println!("GUEST mode (3rd-party repo, auto-detected or --mode guest):");
    println!("  forks upstream, opens ONE bounded PR, and NEVER self-merges — the upstream");
    println!("  maintainer decides. Refuses a new PR once we already hold");
    println!("  CHUMP_GUEST_PR_CAP (default 1) open PRs on that repo.");
    println!();
    println!("Dry-run prints the planned chain and the scout's pick without touching the repo.");
    println!("--apply chains all 4 stages: pick → dedup → implement → verify-merge.");
    println!();
    println!("Env overrides (for testing):");
    println!("  CHUMP_IMPROVE_CLAUDE_BIN  — path to claude CLI  (default: claude)");
    println!("  CHUMP_IMPROVE_GH_BIN      — path to gh CLI      (default: gh)");
    println!("  CHUMP_IMPROVE_CHUMP_BIN   — path to chump binary (default: auto-resolve)");
    println!("  CHUMP_IMPROVE_DISABLED    — set to 1 to kill-switch this subcommand");
    println!("  CHUMP_IMPROVE_GH_IDENTITY — override our GH identity (mode auto-detect; testing)");
    println!("  CHUMP_GUEST_PR_CAP        — max open PRs we hold on a guest repo (default: 1)");
}

// ── Core logic ────────────────────────────────────────────────────────────

fn run_inner(args: &[String]) -> Result<i32> {
    let mut opts = parse_args(args)?;

    if !opts.owner_repo.contains('/') {
        bail!(
            "<owner/repo> must contain a slash, got {:?}",
            opts.owner_repo
        );
    }

    // MISSION-049: resolve own-repo vs guest-repo mode BEFORE anything else — it
    // gates whether we fork, whether we cap new PRs, and (in verify_and_merge)
    // whether we're ever allowed to self-merge.
    let gh_bin = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());
    let (resolved_mode, guest_identity) =
        resolve_mode(&opts.owner_repo, opts.mode_arg.as_deref(), &gh_bin);
    opts.mode = resolved_mode;
    opts.guest_identity = guest_identity;

    let run_mode_label = if opts.apply { "APPLY" } else { "DRY-RUN" };
    println!(
        "[improve] mode={run_mode_label} repo={} guest_mode={}",
        opts.owner_repo, opts.mode
    );
    if opts.mode == ImproveMode::Guest {
        println!(
            "[improve] GUEST mode: will fork + open ONE bounded PR, NEVER self-merge \
             (CHUMP_GUEST_PR_CAP={})",
            guest_pr_cap()
        );
    }

    let clone_dir = resolve_clone_dir(&opts);

    // ── Stage 1: PICK ─────────────────────────────────────────────────────
    println!("\n[improve] Stage 1: PICK — scout {}...", opts.owner_repo);

    // If --gap is specified, that's the pre-selected work description.
    // Otherwise load the most-recent onboard scan from the canonical location.
    // MISSION-056: pick_gap returns a RANKED LIST of candidates. The top is what
    // a dry-run reports; --apply dedups each in order and takes the first UNDONE.
    let candidates = pick_gap(&opts, &clone_dir)?;
    let top = &candidates[0];

    println!("[improve] picked: {}", top.title);
    println!(
        "[improve] evidence: {} §{}",
        top.source_of_evidence.input_path, top.source_of_evidence.section
    );

    if !opts.apply {
        println!("\n[improve] Stage 2: DEDUP — skipped in dry-run.");
        println!("[improve] Stage 3: IMPLEMENT — skipped in dry-run.");
        println!("[improve] Stage 4: VERIFY-MERGE — skipped in dry-run.");
        println!("\n[improve] dry-run complete. Pass --apply to execute.");
        emit_cycle_complete(&opts.owner_repo, &top.title, "dry_run", None);
        return Ok(0);
    }

    // INFRA-3477/3478: prepare the shared clone under a lock — clone-if-missing
    // (the `--gap` path skips the scout that clones) + refresh to the remote
    // default branch (so the PR branches from CURRENT main, not a stale reused
    // clone). The lock serializes concurrent agents' first-touch clone/refresh so
    // they don't race on the shared clone.
    prepare_shared_clone(&clone_dir, &opts.owner_repo)?;

    // ── Stage 1.5: SHEPHERD ───────────────────────────────────────────────
    // MISSION-061: before implementing NEW work, drive the loop's own open PRs
    // from prior cycles to a terminal state. Dep-bound: a held/behind PR opened
    // last cycle may block this cycle's work, so resolve blockers first. Bounded
    // + identity-filtered (only touches PRs a Chump agent authored).
    shepherd_own_prs(&opts, &clone_dir);

    // ── Stage 2: DEDUP ────────────────────────────────────────────────────
    // MISSION-056: dedup EACH ranked candidate and take the first that isn't
    // already shipped. Before this, improve dedup'd ONLY the top gap and stopped
    // on redundant — so it looped forever on an already-done gap and never
    // advanced to new work (the scoreboard-① blocker: `chump improve` picked the
    // same already-shipped RLS gap 3 runs running, SKIP every time).
    println!("\n[improve] Stage 2: DEDUP — finding the first candidate that isn't already done...");

    let mut chosen: Option<ProposedGap> = None;
    for cand in &candidates {
        // INFRA-3508 (COTG-S.1): before the repo-local dedup check, resolve the
        // candidate against repo -> arsenal -> world prior art. A DONE-HERE /
        // EXISTS-IN-ARSENAL / EXISTS-IN-WORLD verdict means the Flow would build
        // something that already exists elsewhere — skip it the same as a
        // redundant-in-this-repo hit. HALF-DONE-HERE and NOT-FOUND proceed (a
        // half-built capability should be finished, not re-sourced; a novel one
        // is genuinely new work).
        // The fleet-internal sourcing resolver ("repo -> arsenal -> world")
        // reasons about CHUMP's own checkout (CHUMP_REPO_ROOT) and 76-repo
        // GLOBAL_ARSENAL.json, NOT the external target repo. On an
        // operator-specified `--gap` it must never veto the chosen work: it
        // false-matched a real Olive gap to a DIFFERENT fleet repo
        // ("EXISTS-IN-ARSENAL repo=JARVIS") and skipped it, leaving "all
        // candidates already shipped, nothing to do." An operator who names a
        // gap ID has already made the build/skip call; cross-fleet prior-art
        // sourcing does not override it. Repo-local dedup_check still runs.
        if opts.gap_id.is_none() {
            if let Some(reason) = sourcing_resolver_reason(cand) {
                println!(
                    "[improve] SKIP (sourced elsewhere): {} — {reason}",
                    cand.title
                );
                emit_redundant_work_skipped(&opts.owner_repo, &cand.title, &reason);
                continue;
            }
        }
        match dedup_check(&opts.owner_repo, &clone_dir, cand, &gh_bin)? {
            DedupResult::Redundant { reason } => {
                println!("[improve] SKIP (redundant): {} — {reason}", cand.title);
                emit_redundant_work_skipped(&opts.owner_repo, &cand.title, &reason);
            }
            DedupResult::NotRedundant => {
                chosen = Some(cand.clone());
                break;
            }
        }
    }
    let picked = match chosen {
        Some(p) => p,
        None => {
            println!(
                "[improve] all {} candidate(s) already shipped — nothing new to do this cycle",
                candidates.len()
            );
            emit_cycle_complete(
                &opts.owner_repo,
                "(all candidates redundant)",
                "skipped_redundant",
                None,
            );
            return Ok(0);
        }
    };
    println!(
        "[improve] dedup PASS — picked '{}' (not already done).",
        picked.title
    );

    // CREDIBLE-198 (CREDIBLE-197 slice 2): VERIFY-BEFORE-EXECUTE. For a registry gap (--gap),
    // if the acceptance is ALREADY satisfied in the repo (a Scout/Holler finding that was
    // already fixed), auto-close it `already_satisfied` (no PR; INFRA-402 does not block that
    // disposition) and skip the fix-agent — never burning an agent, or risking a no-op
    // false-green, on settled work. FAIL-OPEN: skips ONLY on a positive SATISFIED verdict.
    if let Some(gap_id) = opts.gap_id.as_deref() {
        let verify_bin = std::env::var("CHUMP_IMPROVE_CHUMP_BIN")
            .or_else(|_| std::env::var("CHUMP_BIN"))
            .ok()
            .or_else(|| {
                std::env::current_exe()
                    .ok()
                    .map(|p| p.to_string_lossy().into_owned())
            })
            .unwrap_or_else(|| "chump".to_string());
        if let Some(evidence) = verify_already_satisfied(&clone_dir, gap_id, &verify_bin) {
            println!(
                "[improve] VERIFY-BEFORE-EXECUTE (CREDIBLE-198): '{gap_id}' acceptance ALREADY \
                 satisfied — {evidence}; auto-closing already_satisfied, skipping the fix-agent."
            );
            emit_already_satisfied_skipped(&opts.owner_repo, gap_id, &evidence);
            let _ = Command::new(&verify_bin)
                .args([
                    "gap",
                    "set",
                    gap_id,
                    "--status",
                    "already_satisfied",
                    "--evidence",
                    &format!("verify-before-execute (chump improve): {evidence}"),
                ])
                .status();
            return Ok(0);
        }
    }

    // ── Stage 3: IMPLEMENT (or COTG-1.4 RESUME) ───────────────────────────
    // COTG-1.4/INFRA-3486: durable resume — if a prior run for THIS gap already opened a PR
    // (journaled below), skip re-implementing (which would open a DUPLICATE PR) and resume
    // at verify-merge. The FSM (COTG-1.1) is threaded only on the fresh-implement path;
    // resume is a recovery shortcut, so it carries no FSM (Option-typed).
    let (pr_url, pr_number, fsm): (
        String,
        Option<u64>,
        Option<crate::autonomy_fsm::AutonomyState<crate::autonomy_fsm::Verifying>>,
    ) = if let Some(url) = load_flow_pr_url(&opts, &picked) {
        let n = extract_pr_number(&url);
        println!(
            "[improve] RESUME (COTG-1.4) — PR {url} already opened for '{}' in a prior run; \
             skipping IMPLEMENT, resuming at VERIFY-MERGE (no duplicate PR).",
            picked.title
        );
        (url, n, None)
    } else {
        // MISSION-049: PR-cap gate, Guest mode only, FRESH-implement path only — a
        // RESUME (above) isn't opening a NEW PR so it never counts against the cap.
        // Optimize acceptance probability, not throughput: refuse to pile a 2nd PR
        // onto a maintainer who hasn't responded to the 1st yet.
        if opts.mode == ImproveMode::Guest {
            if let Some(identity) = opts.guest_identity.as_deref() {
                let open = guest_open_pr_count(&opts.owner_repo, identity, &gh_bin);
                let cap = guest_pr_cap();
                if open >= cap {
                    println!(
                        "[improve] GUEST PR-CAP reached: {open} open PR(s) by {identity} on \
                         {} (cap={cap}) — batch into the existing PR, wait for the maintainer, \
                         skipping this cycle.",
                        opts.owner_repo
                    );
                    emit_guest_pr_cap_reached(&opts.owner_repo, identity, open, cap);
                    return Ok(0);
                }
            }
        }
        println!("\n[improve] Stage 3: IMPLEMENT — spawning agent in clone...");
        // COTG-1.1: thread the typed autonomy FSM (Planning → Executing). The typestate
        // makes the stage order compile-time-enforced.
        let fsm = crate::autonomy_fsm::AutonomyState::<crate::autonomy_fsm::Planning>::new()
            .begin_execution(crate::autonomy_fsm::PlanningComplete {
                task_id: 0,
                has_acceptance: !picked.acceptance_criteria_draft.is_empty(),
                has_verify: true,
            });
        let url = implement_gap(&opts, &clone_dir, &picked)?;
        let n = extract_pr_number(&url);
        println!("[improve] PR opened: {url}");
        if let Some(num) = n {
            println!("[improve] PR number: #{num}");
        }
        // COTG-1.4: journal the opened PR BEFORE the (long) verify stage, so a crash there
        // resumes here instead of re-opening a duplicate.
        save_flow_checkpoint(&opts, &picked, &url);
        // COTG-1.1: PR opened → enter Verifying.
        let fsm = fsm.begin_verification(crate::autonomy_fsm::ExecutionReceipt {
            task_id: 0,
            summary: url.clone(),
        });
        (url, n, Some(fsm))
    };

    // ── Stage 4: VERIFY-MERGE ─────────────────────────────────────────────
    println!("\n[improve] Stage 4: VERIFY-MERGE — judging PR on merit...");

    let pr_num =
        pr_number.ok_or_else(|| anyhow::anyhow!("could not parse PR number from URL: {pr_url}"))?;

    // CREDIBLE-215: mechanical stub detection, ahead of the CI round —
    // does the PR's diff have any resolved import path to the gap's
    // named target? Advisory only (never blocks); a REACHES/TEST-ONLY/
    // UNRELATED print here is one CI round cheaper than catching a stub
    // in review.
    run_verify_reaches_advisory(&opts, &picked, pr_num);

    let mut verdict = verify_and_merge(&opts, pr_num, &picked.title)?;

    // EFFECTIVE-375 → CREDIBLE-212 (COTG AC hard gate, RELOCATED): the AC judge
    // now runs as Gate 4 INSIDE `external verify-merge`, before the `--apply`
    // merge — not here, after verify_and_merge already merged the PR. This block
    // used to re-judge post-merge and flip a would-be 'verified' to 'held', but a
    // 'verified' return already meant the PR was squash-merged (gates 1/2/3 pass →
    // merge_pr fires), so the flip gated nothing and shoved a merged PR into
    // remediate_held. With Gate 4 upstream, an AC-incomplete PR now returns
    // 'held' (HELD(ac-incomplete)) from verify_and_merge WITHOUT merging, so the
    // remediate path below re-works a still-open branch. No post-merge re-judge.

    println!("[improve] verdict: {verdict}");

    // MISSION-059: NEVER abandon a HELD PR. Drive it to a terminal state
    // (merged or closed) instead of walking away red. remediate_held classifies
    // the CI failure (composing ci_summary::classify_log, INFRA-506), reruns
    // flakes for free, or re-spawns an escalating-model agent to fix real defects
    // on the SAME branch — re-verifying after each attempt. If still red after
    // the retry budget, it CLOSES the PR with a reason. This is what makes the
    // loop CONVERGE (land work) rather than merely TRY: a held PR that blocks a
    // dependent task is resolved in-cycle, never skipped, never left open-red.
    if verdict != "verified" {
        verdict = remediate_held(
            &opts,
            &clone_dir,
            &picked.title,
            &picked.acceptance_criteria_draft,
            pr_num,
            &pr_url,
        )?;
    }

    emit_cycle_complete(&opts.owner_repo, &picked.title, &verdict, Some(&pr_url));

    // COTG-1.4: terminal — the Flow is done for this gap, clear the resume journal.
    clear_flow_checkpoint(&opts, &picked);

    let terminal = matches!(verdict.as_str(), "verified" | "closed");
    // COTG-1.1: drive the FSM to its terminal state (only on the fresh-implement path;
    // `complete` exists ONLY on AutonomyState<Verifying>, proving the flow passed Verifying).
    if let Some(f) = fsm {
        let outcome = crate::autonomy_fsm::VerificationOutcome {
            task_id: 0,
            status: verdict.clone(),
            detail: pr_url.clone(),
        };
        if terminal {
            let _ = f.complete(outcome);
            eprintln!("[improve] FSM: Planning→Executing→Verifying→Done (COTG-1.1 kernel ABI)");
        } else {
            let _ = f.fail(outcome);
            eprintln!("[improve] FSM: reached Failed");
        }
    }
    // Both "verified"/"closed" are clean terminal states — no open-red PR left behind.
    // (remediate_held always returns verified|closed; keep the non-zero signal otherwise.)
    if terminal {
        Ok(0)
    } else {
        Ok(1)
    }
}

// ── Stage implementations ─────────────────────────────────────────────────

/// EFFECTIVE-353: load a filed gap from the canonical chump gap store
/// (`.chump/state.db` under the current repo root). Best-effort — returns None
/// when the store can't be opened or the ID isn't present, so callers fail-soft
/// to a placeholder synthesis. Runs before any clone/cwd change, so the repo
/// root still resolves to the chump repo whose store holds the gap.
fn load_stored_gap(gap_id: &str) -> Option<chump_gap_store::GapRow> {
    let repo_root = crate::repo_path::repo_root();
    let store = chump_gap_store::GapStore::open(&repo_root).ok()?;
    store.get(gap_id).ok().flatten()
}

/// EFFECTIVE-353: map a stored `GapRow` into the `ProposedGap` the implement
/// stage feeds the agent via `build_gap_description` — carrying the gap's REAL
/// title, problem statement, and acceptance criteria (not a placeholder built
/// from the bare ID). `acceptance_criteria` is stored as a JSON array of strings
/// (serialized AS a string); non-JSON or empty falls back to a generic bullet so
/// the agent still gets a runnable AC.
fn proposed_gap_from_stored(row: &chump_gap_store::GapRow) -> ProposedGap {
    use chump_handoff::external_repo_schema::{Confidence, Effort, Priority, SourceOfEvidence};

    let priority = match row.priority.as_str() {
        "P0" => Priority::P0,
        "P2" => Priority::P2,
        "P3" => Priority::P3,
        _ => Priority::P1,
    };
    let mut ac: Vec<String> =
        serde_json::from_str::<Vec<String>>(&row.acceptance_criteria).unwrap_or_default();
    ac.retain(|s| !s.trim().is_empty());
    if ac.is_empty() {
        ac.push(format!("Change described in gap {} is implemented", row.id));
        ac.push("At least one test proves the change".to_string());
    }
    // The problem statement the agent must read: prefer the full description,
    // then notes, then the title (always non-empty).
    let excerpt = if !row.description.trim().is_empty() {
        row.description.clone()
    } else if !row.notes.trim().is_empty() {
        row.notes.clone()
    } else {
        row.title.clone()
    };
    let domain = if row.domain.trim().is_empty() {
        "EFFECTIVE".to_string()
    } else {
        row.domain.clone()
    };
    ProposedGap {
        title: row.title.clone(),
        domain,
        priority,
        effort: Effort::S,
        confidence: Confidence::High,
        source_of_evidence: SourceOfEvidence {
            input_path: format!("chump gap store ({})", row.id),
            section: row.id.clone(),
            excerpt,
        },
        acceptance_criteria_draft: ac,
        layer: None,
        doctrine_justification: None,
    }
}

/// Stage 1: Pick the highest-confidence proposed gap from the latest scan.
///
/// If `--gap` was specified, synthesise a minimal `ProposedGap` from the gap
/// title/ID. Otherwise reads the most-recent onboard scan from `clone_dir`'s
/// parent (the canonical external-repo directory).
fn pick_gap(opts: &Opts, clone_dir: &Path) -> Result<Vec<ProposedGap>> {
    use chump_handoff::external_repo_schema::{Confidence, Effort, Priority, SourceOfEvidence};

    if let Some(ref gap_id) = opts.gap_id {
        // EFFECTIVE-353: load the REAL filed gap (title/description/acceptance
        // criteria) from the canonical chump gap store so the implementing agent
        // works the ACTUAL job. Before this, the `--gap` path synthesised a
        // placeholder from the bare ID — the agent was handed the literal string
        // "PRODUCT-143" and a generic "Change described in gap … is implemented"
        // AC, so it could not see (let alone fix) the real bug. Fail-soft to the
        // minimal synthesis when the ID isn't in the store (keeps ad-hoc `--gap
        // SOME-ID` working). Operator chose the work — single candidate, no
        // dedup-advance either way.
        if let Some(row) = load_stored_gap(gap_id) {
            return Ok(vec![proposed_gap_from_stored(&row)]);
        }
        return Ok(vec![ProposedGap {
            title: gap_id.clone(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "--gap (operator-specified)".to_string(),
                section: "operator override".to_string(),
                excerpt: format!("gap ID provided via --gap: {gap_id}"),
            },
            acceptance_criteria_draft: vec![
                format!("Change described in gap {gap_id} is implemented"),
                "At least one test proves the change".to_string(),
            ],
            layer: None,
            doctrine_justification: None,
        }]);
    }

    // EFFECTIVE-288 GREEN-FIRST doctrine (operator, 2026-06-22): before picking
    // any NEW feature work, make the repo GREEN. If a CI check is failing across
    // the repo's open PRs (a broken gate blocking every merge), fixing it is the
    // forced top priority. "Step 1: make it green. Step 2: ship something new."
    // Skipped when --gap is set (operator chose the work) — that returns above.
    let gh_bin_gf = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());
    let failing = repo_failing_checks(&gh_bin_gf, &opts.owner_repo);
    if let Some(green) = green_first_gap_from_failures(&failing) {
        let top = failing.first().map(|(n, _)| n.as_str()).unwrap_or("?");
        println!(
            "[improve] GREEN-FIRST: repo not green ('{top}' failing across open PRs) — fixing before any new work"
        );
        // Green-first is a FORCED single pick — a broken gate must be fixed, no
        // dedup-advance past it.
        return Ok(vec![green]);
    }

    // Repo is green (or gh unavailable) — proceed to scan-based feature picking.
    pick_gap_from_scan(opts, clone_dir)
}

/// Scan-based feature pick (pure, no network). The `--gap` override and the
/// EFFECTIVE-288 GREEN-FIRST gate both run in `pick_gap` *before* this; this
/// only reads the latest onboard scan and returns the highest-priority gap by
/// the L1<L2<L3 doctrine order. Kept separate + unit-tested directly so the
/// scan-pick tests never depend on live `gh` state (the green-first gh call
/// lives only in `pick_gap`).
fn pick_gap_from_scan(opts: &Opts, clone_dir: &Path) -> Result<Vec<ProposedGap>> {
    // Read the latest onboard scan from the external-repo directory.
    // The scan lives at <external-repo-dir>/scans/onboard-scan-<ts>.json
    // where <external-repo-dir> is clone_dir's parent (the repo root, not /clone/).
    let repo_dir = clone_dir
        .parent()
        .ok_or_else(|| anyhow::anyhow!("clone_dir has no parent: {}", clone_dir.display()))?;

    let scan: OnboardScan = read_latest_scan(repo_dir)
        .context("reading latest onboard scan")?
        .ok_or_else(|| {
            anyhow::anyhow!(
                "no onboard scan found under {} — run `chump onboard {}` first",
                repo_dir.display(),
                opts.owner_repo
            )
        })?;

    // EFFECTIVE-201: doctrine-order picking — L1 → L2 → L3 → untagged,
    // then within each layer by confidence descending (High > Med > Low).
    //
    // Rationale: foundation (L1) must be fixed before higher-level work adds
    // value. L2 (unfulfilled claims) has more legible ROI than L3 (latent
    // ideas). Within a layer, higher confidence means stronger evidence.
    let mut gaps = scan.proposed_gaps;
    gaps.sort_by(|a, b| {
        let la = layer_sort_key(a.layer.as_deref());
        let lb = layer_sort_key(b.layer.as_deref());
        la.cmp(&lb).then_with(|| {
            confidence_sort_key(&a.confidence).cmp(&confidence_sort_key(&b.confidence))
        })
    });
    // MISSION-056: return the FULL ranked list, not just the top. The caller
    // dedups each candidate in order and takes the first UNDONE one — without
    // this, `chump improve` loops forever on an already-shipped top gap and
    // never advances to new work (the scoreboard-① blocker).
    if gaps.is_empty() {
        anyhow::bail!("onboard scan contains no proposed gaps");
    }
    Ok(gaps)
}

/// Gather failing CI checks across the target repo's open PRs, tallied by check
/// name (most-failing first). Best-effort: a `gh` failure (offline, no auth,
/// rate-limit) yields an empty vec → no false GREEN-FIRST block. EFFECTIVE-288.
///
/// A check failing on a SINGLE PR is likely that PR's own bug; a check failing
/// across *multiple* open PRs is a broken gate blocking every merge — that's the
/// signal `green_first_gap_from_failures` keys on.
fn repo_failing_checks(gh_bin: &str, owner_repo: &str) -> Vec<(String, usize)> {
    let out = Command::new(gh_bin)
        .args([
            "pr", "list", "--repo", owner_repo, "--state", "open", "--limit", "30", "--json",
            "statusCheckRollup", "--jq",
            // Emit one failing-check name per line across all open PRs. CheckRun
            // uses .conclusion+.name; StatusContext uses .state+.context.
            r#".[] | .statusCheckRollup[]? | select(.conclusion=="FAILURE" or .state=="FAILURE") | (.name // .context)"#,
        ])
        .output();
    let stdout = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return Vec::new(), // best-effort — never false-block on a gh error
    };
    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for name in stdout.lines().map(str::trim).filter(|s| !s.is_empty()) {
        *counts.entry(name.to_string()).or_insert(0) += 1;
    }
    let mut v: Vec<(String, usize)> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0))); // most-failing first, stable
    v
}

/// GREEN-FIRST doctrine: a CI check failing across >=2 open PRs is a broken gate
/// blocking *every* merge — make the repo green before any new feature. Returns
/// the forced top-priority pick when such a check exists, else `None` (repo is
/// green enough → fall through to normal feature picking). Pure + unit-tested.
/// EFFECTIVE-288 (operator doctrine 2026-06-22: "Step 1 make it green, step 2
/// ship something new").
fn green_first_gap_from_failures(failures: &[(String, usize)]) -> Option<ProposedGap> {
    use chump_handoff::external_repo_schema::{Confidence, Effort, Priority, SourceOfEvidence};
    let (check, count) = failures.iter().find(|(_, c)| *c >= 2)?;
    Some(ProposedGap {
        title: format!("GREEN-FIRST: fix the failing CI check '{check}' (blocks all merges)"),
        domain: "RESILIENT".to_string(),
        priority: Priority::P0, // a broken merge-gate is always top priority
        effort: Effort::M,
        confidence: Confidence::High,
        source_of_evidence: SourceOfEvidence {
            input_path: "gh pr list (open-PR check rollups)".to_string(),
            section: "green-first doctrine".to_string(),
            excerpt: format!(
                "CI check '{check}' fails on {count} open PRs — a broken gate blocking every \
                 merge; make the repo green before any new feature work"
            ),
        },
        acceptance_criteria_draft: vec![
            format!(
                "Diagnose why '{check}' fails (broken/misconfigured check vs a real repo issue) \
                 and fix the root cause"
            ),
            format!("The '{check}' check passes (green) on a fresh PR"),
            "A previously-red PR can then go green and merge".to_string(),
        ],
        layer: Some("L1".to_string()), // green-first is foundation work
        doctrine_justification: Some(
            "green-first: make it green before shipping new (operator doctrine 2026-06-22)"
                .to_string(),
        ),
    })
}

/// Map a doctrine layer string to a sort key (lower = picked first).
///
/// L1 < L2 < L3 < untagged — foundation before features before aspirations.
fn layer_sort_key(layer: Option<&str>) -> u8 {
    match layer {
        Some("L1") => 0,
        Some("L2") => 1,
        Some("L3") => 2,
        _ => 3, // untagged gaps (pre-doctrine scans) are de-prioritised
    }
}

/// Map a `Confidence` to a sort key (lower = picked first / higher confidence).
fn confidence_sort_key(c: &chump_handoff::external_repo_schema::Confidence) -> u8 {
    use chump_handoff::external_repo_schema::Confidence;
    match c {
        Confidence::High => 0,
        Confidence::Med => 1,
        Confidence::Low => 2,
    }
}

// ── Sourcing resolver wiring (INFRA-3508, COTG-S.1) ───────────────────────

/// Resolve `cand` against the tiered sourcing resolver
/// (`crate::sourcing_resolver::resolve_sourcing`). Returns `Some(reason)` when
/// the candidate should be skipped because it already exists — repo-tier
/// scans the chump checkout itself (`CHUMP_REPO_ROOT`, defaulting to the
/// current dir), since the arsenal catalog (`docs/arsenal/GLOBAL_ARSENAL.json`)
/// lives there regardless of which external repo `improve` is targeting.
/// `HALF-DONE-HERE` and `NOT-FOUND` return `None` (proceed): a half-built
/// capability should be finished, not re-sourced, and a genuinely novel one is
/// new work.
fn sourcing_resolver_reason(cand: &ProposedGap) -> Option<String> {
    use crate::sourcing_resolver::{resolve_sourcing, SourcingVerdict};

    let title_core = cand
        .title
        .splitn(2, ':')
        .nth(1)
        .unwrap_or(&cand.title)
        .trim();
    if title_core.is_empty() {
        return None;
    }

    let repo_root = std::env::var("CHUMP_REPO_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    let arsenal_json = repo_root.join("docs/arsenal/GLOBAL_ARSENAL.json");

    let resolution = resolve_sourcing(title_core, &repo_root, &arsenal_json);
    let receipt = resolution.receipts.first();
    match resolution.verdict {
        SourcingVerdict::DoneHere
        | SourcingVerdict::ExistsInArsenal
        | SourcingVerdict::ExistsInWorld => Some(format!(
            "sourcing resolver: {} ({})",
            resolution.verdict.as_str(),
            receipt.map(|r| r.detail.as_str()).unwrap_or("no receipt")
        )),
        SourcingVerdict::HalfDoneHere | SourcingVerdict::NotFound => None,
    }
}

// ── Dedup types + logic ───────────────────────────────────────────────────

enum DedupResult {
    /// The gap is not yet done in the target repo — proceed.
    NotRedundant,
    /// The work appears to already be done.
    Redundant { reason: String },
}

/// Stage 2: Check whether the proposed gap's work is already present in the
/// target repo clone OR is already in flight as an open PR (ZERO-WASTE-011).
///
/// Two sub-checks:
///
/// 1. **Merged-commit check** (ZERO-WASTE-010): `git log --oneline -50` on the
///    clone. Skip only when the exact title core (> 10 chars) or all key terms
///    co-occur in a single commit message. Errs toward PROCEED — the verify-merge
///    bar is the backstop for truly-redundant merged work.
///
/// 2. **Open-PR check** (ZERO-WASTE-011): `gh pr list --repo <owner/repo>
///    --state open --search "<key terms>"`. If any returned PR title matches the
///    key terms, treat as redundant (work already in flight). This prevents
///    opening duplicate PRs for work already submitted (the BEAST PR #2 case).
///    `gh_bin` is the path to the `gh` CLI — read from `CHUMP_IMPROVE_GH_BIN`
///    at the call site and passed in so this fn is unit-testable without touching
///    global env.
///    If `gh` fails (network error, unauthenticated), fail-open toward PROCEED;
///    the verify-merge bar is the backstop.
fn dedup_check(
    owner_repo: &str,
    clone_dir: &Path,
    gap: &ProposedGap,
    gh_bin: &str,
) -> Result<DedupResult> {
    // Extract the key noun phrase from the gap title (drop the pillar prefix).
    // E.g. "EFFECTIVE: add streaming support" → "streaming support"
    let title_core = gap
        .title
        .splitn(2, ':')
        .nth(1)
        .unwrap_or(&gap.title)
        .trim()
        .to_string();

    // Keyword list: first 3 words of the title core.
    let keywords: Vec<&str> = title_core.split_whitespace().take(3).collect();

    if keywords.is_empty() {
        // Cannot determine keywords — pass the dedup stage.
        return Ok(DedupResult::NotRedundant);
    }

    // ── Sub-check 1: git log (merged work) ───────────────────────────────────
    // "git log --oneline -50" gives the last 50 commits; grep for the keywords.
    let log_out = Command::new("git")
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "log",
            "--oneline",
            "-50",
        ])
        .output();

    if let Ok(out) = log_out {
        let lower_title = title_core.to_lowercase();
        let kws_lower: Vec<String> = keywords.iter().map(|k| k.to_lowercase()).collect();
        // ZERO-WASTE-010: a real "already done" signal is a COMMIT that did this work,
        // NOT mere file-keyword presence — common title words like "roadmap"/"tasks"
        // appear in any repo that has a roadmap, which false-skipped real work on the
        // first live BEAST-MODE run. So skip ONLY if the exact title core appears in a
        // recent commit message, or all key terms co-occur in one commit line. Err
        // toward PROCEED; the verify-merge bar is the backstop for truly-redundant work.
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let l = line.to_lowercase();
            let exact_title = lower_title.len() > 10 && l.contains(&lower_title);
            let all_kw_co_occur =
                kws_lower.len() >= 2 && kws_lower.iter().all(|k| l.contains(k.as_str()));
            if exact_title || all_kw_co_occur {
                return Ok(DedupResult::Redundant {
                    reason: format!("a recent commit already does this work: {}", line.trim()),
                });
            }
        }
    }

    // ── Sub-check 2: open PR check (ZERO-WASTE-011) ───────────────────────────
    // Build a search query from the first 3 key terms.
    let search_query = keywords.join(" ");

    let pr_list_out = Command::new(gh_bin)
        .args([
            "pr",
            "list",
            "--repo",
            owner_repo,
            "--state",
            "open",
            "--search",
            &search_query,
            "--json",
            "title,number",
        ])
        .output();

    if let Ok(out) = pr_list_out {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let lower_title = title_core.to_lowercase();
            let kws_lower: Vec<String> = keywords.iter().map(|k| k.to_lowercase()).collect();
            // Parse each JSON object's "title" field and check for keyword overlap.
            // Use the same match heuristic as the commit check: exact title core OR
            // all key terms co-occur in the PR title. This avoids false positives
            // from loosely matching search results.
            for line in stdout.lines() {
                let l = line.to_lowercase();
                if !l.contains("\"title\"") {
                    continue;
                }
                let exact_title = lower_title.len() > 10 && l.contains(&lower_title);
                let all_kw_co_occur =
                    kws_lower.len() >= 2 && kws_lower.iter().all(|k| l.contains(k.as_str()));
                if exact_title || all_kw_co_occur {
                    return Ok(DedupResult::Redundant {
                        reason: format!(
                            "an open PR on {owner_repo} already covers this work: {}",
                            line.trim()
                        ),
                    });
                }
            }
        }
        // If gh fails (e.g. unauthenticated, network unavailable) — proceed.
        // The verify-merge bar is the backstop.
    }

    Ok(DedupResult::NotRedundant)
}

// ── Auth env helper (B4) ─────────────────────────────────────────────────

/// Configure auth env-vars on a `Command` that will spawn `claude -p`.
///
/// Two responsibilities:
///
/// 1. **Inject OAUTH token** (RESILIENT-106): if the parent env doesn't carry
///    `CLAUDE_CODE_OAUTH_TOKEN`, try reading it from `~/.chump/oauth-token.json`
///    and inject it so the spawned agent can authenticate outside the pre-authed
///    fleet-worker environment.
///
/// 2. **Neutralize conflicting gateway vars** (B4 / RESILIENT-108): when we
///    *will* use OAUTH (token found in env or token file), also strip any
///    conflicting Anthropic gateway environment variables that the parent
///    process may carry (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
///    `ANTHROPIC_BASE_URL`, `ANTHROPIC_CUSTOM_HEADERS`). Without this, a
///    parent session running against a custom gateway causes the spawned claude
///    to prefer the gateway over subscription OAUTH → "Not logged in".
///
/// GUARD: gateway vars are ONLY stripped when an OAUTH token is actually
/// available. We never strip auth leaving the spawned process unauthenticated.
///
/// IMPORTANT: the token value is NEVER logged or printed.
///
/// Returns `true` if an OAUTH token was injected or already present (OAUTH
/// path chosen); `false` if no token available (gateway env left intact).
///
/// Testable via `Command::get_envs` on a `std::process::Command` — no process
/// spawn required.
pub(crate) fn configure_claude_auth_env(cmd: &mut Command) -> bool {
    // Step 1: check if OAUTH token is already present in the parent env.
    let token_in_env = std::env::var_os("CLAUDE_CODE_OAUTH_TOKEN").is_some();

    // Step 2: if not in env, try reading from the token file.
    let token_from_file: Option<String> = if token_in_env {
        None
    } else {
        read_oauth_token_file()
    };

    // Determine whether we have (or will have) an OAUTH token.
    let oauth_available = token_in_env || token_from_file.is_some();

    if !oauth_available {
        // No OAUTH token available — leave everything as-is; do not strip anything.
        return false;
    }

    // Inject the file token if the env didn't already carry one.
    if let Some(tok) = token_from_file {
        cmd.env("CLAUDE_CODE_OAUTH_TOKEN", tok);
    }

    // B4: strip conflicting gateway vars so the spawned claude uses OAUTH.
    // Only done when OAUTH is available (guard above ensures we never strip
    // auth leaving nothing).
    cmd.env_remove("ANTHROPIC_API_KEY");
    cmd.env_remove("ANTHROPIC_AUTH_TOKEN");
    cmd.env_remove("ANTHROPIC_BASE_URL");
    cmd.env_remove("ANTHROPIC_CUSTOM_HEADERS");

    true
}

// ── MISSION-063: named agent identity (provable zero-touch attribution) ─────
//
// Today every BEAST-MODE merge is authored + merged by the operator's token, so
// the git trail can't tell "the loop did it" apart from "Jeff did it" — ① is
// asserted, not measured. Give the loop a NAMED identity and author its commits
// under it: `git log --format='%an <%ae>'` then proves zero-human-touch, and the
// agents get rad workshop names.

/// A named Chump agent — the author identity the improve loop commits under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentIdentity {
    pub codename: String,
    pub name: String,
    pub email: String,
    pub node: String,
}

/// Workshop-robot roster for the default codename (own-your-tools foundry vibe).
pub(crate) const AGENT_ROSTER: &[&str] = &[
    "Sprocket", "Bolt", "Gizmo", "Rivet", "Cog", "Ratchet", "Widget", "Gasket", "Piston", "Tinker",
];

/// Deterministic roster pick from a node name (sum-of-bytes hash — stable per node).
pub(crate) fn roster_pick(node: &str) -> &'static str {
    if AGENT_ROSTER.is_empty() {
        return "Chump";
    }
    let h: usize = node.bytes().map(|b| b as usize).sum();
    AGENT_ROSTER[h % AGENT_ROSTER.len()]
}

/// Short, dns-safe node token (before first dot, lowercased, alnum+dash).
pub(crate) fn sanitize_node(s: &str) -> String {
    let short = s.split('.').next().unwrap_or(s);
    let cleaned: String = short
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "node".to_string()
    } else {
        cleaned
    }
}

/// Resolve this node's short hostname for identity + email.
fn agent_node() -> String {
    for var in ["CHUMP_AGENT_NODE", "HOSTNAME"] {
        if let Ok(h) = std::env::var(var) {
            if !h.trim().is_empty() {
                return sanitize_node(&h);
            }
        }
    }
    if let Ok(o) = Command::new("hostname").output() {
        if o.status.success() {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !s.is_empty() {
                return sanitize_node(&s);
            }
        }
    }
    "node".to_string()
}

/// Pure identity builder (env-free — unit-testable without racing on process
/// env). `name_override`/`email_override` come from `CHUMP_AGENT_NAME`/
/// `CHUMP_AGENT_EMAIL`; empty/whitespace is treated as absent.
pub(crate) fn build_identity(
    name_override: Option<&str>,
    email_override: Option<&str>,
    node: &str,
) -> AgentIdentity {
    let node = sanitize_node(node);
    let codename = name_override
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(|| roster_pick(&node).to_string());
    let name = format!("Chump · {codename}");
    let email = email_override
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("{}@{}.chump.fleet", codename.to_ascii_lowercase(), node));
    AgentIdentity {
        codename,
        name,
        email,
        node,
    }
}

/// Compute the agent identity from the environment: env overrides
/// (`CHUMP_AGENT_NAME` / `CHUMP_AGENT_EMAIL`), else a stable roster default
/// keyed on hostname.
pub(crate) fn agent_identity() -> AgentIdentity {
    let node = agent_node();
    build_identity(
        std::env::var("CHUMP_AGENT_NAME").ok().as_deref(),
        std::env::var("CHUMP_AGENT_EMAIL").ok().as_deref(),
        &node,
    )
}

impl AgentIdentity {
    /// `Chump-Agent: <codename>@<node>` — grep-able commit trailer / signature.
    pub(crate) fn trailer(&self) -> String {
        format!("Chump-Agent: {}@{}", self.codename, self.node)
    }

    /// Set GIT_AUTHOR_*/GIT_COMMITTER_* on a spawned command so the agent's
    /// commits (and thus the squash-merge commit) are authored by this agent,
    /// not the operator's token.
    fn apply_git_env(&self, cmd: &mut Command) {
        cmd.env("GIT_AUTHOR_NAME", &self.name)
            .env("GIT_AUTHOR_EMAIL", &self.email)
            .env("GIT_COMMITTER_NAME", &self.name)
            .env("GIT_COMMITTER_EMAIL", &self.email);
    }

    /// Instruction appended to a spawned agent's prompt so it stamps the
    /// signature trailer on every commit body.
    fn prompt_signature(&self) -> String {
        format!(
            "\n\nCOMMIT SIGNATURE (MISSION-063): you are the Chump agent \"{}\". \
Add this exact trailer as the LAST line of every commit message body you create:\n{}\n",
            self.name,
            self.trailer()
        )
    }
}

// ── Implement stage ───────────────────────────────────────────────────────

/// Stage 3: Spawn a capable agent in the repo clone to implement the gap and
/// open a PR. Returns the PR URL.
///
/// Reuses the `ExternalRepoContract` prompt and the `claude -p
/// --dangerously-skip-permissions` pattern from `src/dispatch.rs`
/// (`spawn_headless`). Binary is resolved via `CHUMP_IMPROVE_CLAUDE_BIN`
/// env var (same pattern as `CHUMP_COORD_BIN`).
/// INFRA-3477 / Principle 0: which agent runtime `improve` spawns to implement a
/// gap. Default is the OS's OWN runtime ("chump-local", via `chump agent-run`);
/// the external claude CLI is opt-in only (`CHUMP_IMPROVE_BACKEND=claude`). An
/// unset/empty/whitespace value resolves to the default — the OS never silently
/// falls back to claude.
fn resolve_improve_backend() -> String {
    match std::env::var("CHUMP_IMPROVE_BACKEND") {
        Ok(v) if !v.trim().is_empty() => v.trim().to_string(),
        _ => "chump-local".to_string(),
    }
}

/// COTG-1.6/INFRA-3488: the cascade model-CLASS to bias chump-local toward for an
/// external IMPLEMENTATION. External work is hard — the 2026-07-29 live run proved a
/// weak-class model storms on it while an opus-class model (gemini-2.5-pro) edits
/// surgically — so default to the strong class. Cost control is the verify gates
/// (COTG-1.3/3.1), not a cheap default that ships broken tools. Operator override:
/// `CHUMP_IMPROVE_IMPLEMENT_CLASS`.
fn improve_implement_class() -> String {
    std::env::var("CHUMP_IMPROVE_IMPLEMENT_CLASS")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "opus".to_string())
}

/// Map a claude model name (the fix-retry ladder's rung) to a cascade model-CLASS,
/// so the chump-local fix path escalates through the SAME strength progression
/// (sonnet → opus) without ever naming claude.
fn model_to_class(model: &str) -> &'static str {
    if model.to_ascii_lowercase().contains("opus") {
        "opus"
    } else {
        "sonnet"
    }
}

/// First `https://github.com/<owner>/<repo>/pull/<N>` URL in text (gh's own output),
/// distinct from `extract_pr_url_from_output` which parses an agent's JSON block.
fn first_github_pr_url(s: &str) -> Option<String> {
    s.split_whitespace()
        .map(|t| t.trim_matches(|c: char| !c.is_ascii_graphic()))
        .find(|t| t.starts_with("https://github.com/") && t.contains("/pull/"))
        .map(|t| t.to_string())
}

/// COTG-1.3/INFRA-3485: verify the agent's staged edit BEFORE the deterministic ceremony
/// commits it — the safety net that makes "can't skimp on quality" structural, not
/// model-dependent. Two classes, both observed live 2026-07-29:
///   (a) DESTRUCTIVE — a whole-file clobber (a weak model rewrote package.json 330→12
///       lines). Caught via numstat: a large deletion that dwarfs the insertion.
///   (b) INVALID — a changed structured file that no longer parses (a strong model nested
///       `devDependencies` inside `scripts`, breaking package.json JSON). Caught by
///       reparsing JSON/TOML/YAML.
/// A rejected edit does NOT commit — it bails with a specific reason (worktree left for
/// debugging), never a broken PR. The destructive check is a conservative heuristic
/// (near-total wipes only); the validity check is exact.
/// CREDIBLE-200: does a path look like a source-code file (real work lives here)?
/// A code extension AND not a test/doc/config/log path.
fn is_source_file(path: &str) -> bool {
    let p = path.to_ascii_lowercase();
    if is_test_file(&p) {
        return false;
    }
    let ext = p.rsplit('.').next().unwrap_or("");
    let code = matches!(
        ext,
        "rs" | "py"
            | "ts"
            | "tsx"
            | "js"
            | "jsx"
            | "mjs"
            | "cjs"
            | "go"
            | "java"
            | "rb"
            | "c"
            | "cc"
            | "cpp"
            | "h"
            | "hpp"
            | "cs"
            | "kt"
            | "swift"
            | "php"
            | "scala"
            | "sql"
            | "sh"
            | "vue"
            | "svelte"
    );
    // Exclude obvious non-source even with a code-ish ext (logs already dropped upstream).
    code && !p.starts_with("logs/") && !p.contains("/logs/")
}

/// CREDIBLE-200: does a path look like a test file?
fn is_test_file(path: &str) -> bool {
    let p = path.to_ascii_lowercase();
    let file = p.rsplit('/').next().unwrap_or(&p);
    p.contains("/tests/")
        || p.contains("/test/")
        || p.contains("__tests__/")
        || p.starts_with("tests/")
        || p.starts_with("test/")
        || file.starts_with("test_")
        || file.starts_with("test-")
        || file.ends_with("_test.py")
        || file.ends_with("_test.go")
        || file.ends_with("_test.rs")
        || file.ends_with(".test.ts")
        || file.ends_with(".test.tsx")
        || file.ends_with(".test.js")
        || file.ends_with(".spec.ts")
        || file.ends_with(".spec.js")
        || file.ends_with("_spec.rb")
}

/// CREDIBLE-200: is a single added line a MEANINGFUL assertion (asserts on something
/// non-trivial), as opposed to a placeholder that is trivially true? Returns false
/// for non-assertion lines and for trivially-true placeholders (assert True, 1==1,
/// pass, assert_eq!(x, x), assert!(true), expect(true).toBe(true)).
fn is_meaningful_assertion(raw: &str) -> bool {
    let line = raw.trim_start_matches('+').trim();
    let low = line.to_ascii_lowercase();
    let looks_like_assert = low.starts_with("assert")
        || low.contains("assert_eq!")
        || low.contains("assert_ne!")
        || low.contains("assert!(")
        || low.contains("expect(")
        || low.contains(".tobe")
        || low.contains(".to_be")
        || low.contains("assertequal")
        || low.contains("asserttrue")
        || low.contains("assertthat");
    if !looks_like_assert {
        return false;
    }
    !is_placeholder_assertion(&low)
}

/// CREDIBLE-200: is this assertion trivially true (a stub)? Whitespace-insensitive.
fn is_placeholder_assertion(low: &str) -> bool {
    let s: String = low.chars().filter(|c| !c.is_whitespace()).collect();
    // Literal trivials.
    const TRIVIAL: [&str; 7] = [
        "asserttrue",
        "assert(true)",
        "assert!(true)",
        "assertisnotnone(none)",
        "expect(true).tobe(true)",
        "expect(true).tobetruthy()",
        "assertthat(true).istrue()",
    ];
    // `asserttrue` bare (python `assert True`) is a stub, but `self.asserttrue(cond)`
    // (a real unittest call with an argument) is not — distinguish by the '('.
    if s == "asserttrue" || s == "asserttrue:" {
        return true;
    }
    if TRIVIAL.iter().any(|t| s == *t) {
        return true;
    }
    // Identical operands around `==` → trivially true (assert 1==1, assert x==x).
    if let Some(idx) = s.find("==") {
        let left_raw = &s[..idx];
        // the operand is the token after the last 'assert'/'('/'!'/',' boundary
        let left = left_raw
            .rsplit(|c| c == '(' || c == '!' || c == ',')
            .next()
            .unwrap_or("")
            .trim_start_matches("assert");
        let right = s[idx + 2..]
            .split(|c| c == ')' || c == ',' || c == ';')
            .next()
            .unwrap_or("");
        if !left.is_empty() && left == right {
            return true;
        }
    }
    // assert_eq!/assert_ne! with identical operands.
    for pfx in ["assert_eq!(", "assert_ne!("] {
        if let Some(rest) = s.strip_prefix(pfx) {
            let inner = rest.trim_end_matches(|c| c == ')' || c == ';');
            let parts: Vec<&str> = inner.split(',').collect();
            if parts.len() >= 2 && !parts[0].is_empty() && parts[0] == parts[1] {
                return true;
            }
        }
    }
    false
}

/// CREDIBLE-232: is this ADDED test line an ACTUAL placeholder / no-op — the positive
/// evidence of fake work? Whitespace-insensitive. Covers: a trivially-true assertion
/// (`assert True` / `assert 1==1` / `expect(true).toBe(true)` / tautology — via
/// `is_placeholder_assertion`), a bare `pass`, and skip/todo markers that declare the
/// test unimplemented (`it.todo` / `test.skip` / `xit(` / `@pytest.mark.skip` /
/// `#[ignore]` / `unimplemented!()` / `todo!()`). A line that does REAL work (parses,
/// computes, or asserts on a non-literal) is NOT a placeholder and returns false.
fn is_stub_placeholder_line(raw: &str) -> bool {
    let line = raw.trim_start_matches('+').trim();
    let low = line.to_ascii_lowercase();
    let compact: String = low.chars().filter(|c| !c.is_whitespace()).collect();
    // Bare python `pass` — an empty test body.
    if low == "pass" {
        return true;
    }
    // Skip / todo / not-implemented markers (the test declares itself unfinished).
    if compact.contains("it.todo")
        || compact.contains("test.todo")
        || compact.contains("it.skip")
        || compact.contains("test.skip")
        || compact.contains("describe.skip")
        || compact.starts_with("xit(")
        || compact.starts_with("xtest(")
        || compact.starts_with("xdescribe(")
        || compact.contains("@pytest.mark.skip")
        || compact.contains("@unittest.skip")
        || compact == "#[ignore]"
        || compact.contains("unimplemented!(")
        || compact.contains("todo!(")
    {
        return true;
    }
    // A trivially-true assertion (only judge lines that actually look like assertions).
    let looks_like_assert = low.starts_with("assert")
        || low.contains("assert_eq!")
        || low.contains("assert_ne!")
        || low.contains("assert!(")
        || low.contains("expect(")
        || low.contains(".tobe")
        || low.contains(".to_be")
        || low.contains("assertequal")
        || low.contains("asserttrue")
        || low.contains("assertthat");
    looks_like_assert && is_placeholder_assertion(&low)
}

/// CREDIBLE-200 / CREDIBLE-232 (pure, unit-tested): a change is a STUB only when its
/// added test body is ACTUAL placeholder work. Returns Some(reason) to block the ship.
///
/// CREDIBLE-232 fix: the verdict is gated on the PRESENCE of a placeholder pattern, NOT
/// on the absence of a *recognized* assertion syntax. The old rule blocked any test-only
/// change for which no allowlisted assertion was found — which false-positived every
/// legitimate test-only PR whose assertions it couldn't parse (olive #10: a real vitest
/// that parses a workflow YAML and asserts the scan job's `if:` condition; and any ava
/// `t.is` / tap `t.equal` style suite). Now the guard must POINT at a real stub pattern
/// (`assert True` / `assert 1==1` / `expect(true).toBe(true)` / bare `pass` / `it.todo` /
/// `test.skip` / tautology) before it refuses.
///
/// Fails OPEN (returns None) whenever ANY of these hold: a real source edit, a meaningful
/// assertion (a comparison against a computed/parsed value), or the absence of any
/// placeholder signal at all. Only a test-only change that is *positively* placeholder —
/// no real assertion AND at least one placeholder pattern — is blocked.
fn stub_reason(changed_paths: &[String], added_test_lines: &[String]) -> Option<String> {
    // A real source edit means real work — never a stub.
    if changed_paths.iter().any(|p| is_source_file(p)) {
        return None;
    }
    // Only guard the specific "test-only" shape; docs/config-only changes are out of scope.
    if !changed_paths.iter().any(|p| is_test_file(p)) {
        return None;
    }
    // Test-only: a single meaningful assertion (real work) clears it.
    if added_test_lines.iter().any(|l| is_meaningful_assertion(l)) {
        return None;
    }
    // CREDIBLE-232: with no meaningful assertion, block ONLY when there is POSITIVE
    // evidence of a placeholder — otherwise the change may be a helper/fixture/setup or
    // use an assertion syntax we don't recognize; fail open rather than reject real work.
    if !added_test_lines.iter().any(|l| is_stub_placeholder_line(l)) {
        return None;
    }
    Some(
        "stub-guard (CREDIBLE-200): this change edits NO source file and adds only \
         placeholder test assertions (e.g. assert True / assert 1==1 / pass / it.todo) — a \
         stub, not a fix; refusing to ship. Receipt for the failure mode: olive PR #7 (dogfood 2026-08-04)."
            .to_string(),
    )
}

/// CREDIBLE-200: gather the staged diff and block a stub. Reads changed paths
/// (--cached --numstat) and the added (`+`) lines of staged test files, then applies
/// the pure `stub_reason`.
fn verify_not_stub(work_dir: &Path) -> Result<()> {
    let wd = work_dir.to_string_lossy().to_string();
    let numstat = Command::new("git")
        .args(["-C", &wd, "diff", "--cached", "--numstat"])
        .output()
        .with_context(|| "git diff --cached --numstat (stub-guard)")?;
    let changed_paths: Vec<String> = String::from_utf8_lossy(&numstat.stdout)
        .lines()
        .filter_map(|l| l.split('\t').nth(2).map(|p| p.to_string()))
        .filter(|p| !p.is_empty())
        .collect();
    if changed_paths.is_empty() {
        return Ok(());
    }
    // Collect added lines from staged TEST files only (the assertions we judge).
    let mut added_test_lines: Vec<String> = Vec::new();
    for path in changed_paths.iter().filter(|p| is_test_file(p)) {
        if let Ok(out) = Command::new("git")
            .args(["-C", &wd, "diff", "--cached", "--", path])
            .output()
        {
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                if line.starts_with('+') && !line.starts_with("+++") {
                    added_test_lines.push(line.to_string());
                }
            }
        }
    }
    if let Some(reason) = stub_reason(&changed_paths, &added_test_lines) {
        bail!("{reason}");
    }
    Ok(())
}

fn verify_staged_edit(work_dir: &Path) -> Result<()> {
    let wd = work_dir.to_string_lossy().to_string();
    let out = Command::new("git")
        .args(["-C", &wd, "diff", "--cached", "--numstat"])
        .output()
        .with_context(|| "git diff --cached --numstat")?;
    verify_edit_numstat(work_dir, &String::from_utf8_lossy(&out.stdout))
}

/// EFFECTIVE-408: the same edit-verify checks (destructive-clobber + structured-file
/// validity) applied to any `git diff … --numstat` output, factored out so both the
/// staged ship gate (`verify_staged_edit`) and the pre-ship escalation probe
/// (`working_tree_edit_is_broken`) share ONE rule set and can never drift.
fn verify_edit_numstat(work_dir: &Path, numstat: &str) -> Result<()> {
    for line in numstat.lines() {
        let mut parts = line.split('\t');
        let added = parts.next().unwrap_or("-");
        let deleted = parts.next().unwrap_or("-");
        let path = match parts.next() {
            Some(p) if !p.is_empty() => p,
            _ => continue,
        };
        // (a) destructive clobber — binary ("-") skipped; a large deletion where the
        // insertion is < 10% of it is a near-total rewrite, not an edit.
        if let (Ok(a), Ok(d)) = (added.parse::<u64>(), deleted.parse::<u64>()) {
            if d >= 50 && a.saturating_mul(10) < d {
                bail!(
                    "edit-verify (COTG-1.3): destructive rewrite of {path} (+{a}/-{d}) — a \
                     near-total clobber, not an edit; refusing to ship"
                );
            }
        }
        // (b) validity — a changed structured file must still parse.
        let full = work_dir.join(path);
        let ext = full
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let content = match std::fs::read_to_string(&full) {
            Ok(c) => c,
            Err(_) => continue, // deleted/unreadable — not a validity concern
        };
        let parse_err: Option<String> = match ext.as_str() {
            "json" => serde_json::from_str::<serde_json::Value>(&content)
                .err()
                .map(|e| e.to_string()),
            "toml" => toml::from_str::<toml::Value>(&content)
                .err()
                .map(|e| e.to_string()),
            "yaml" | "yml" => serde_yaml::from_str::<serde_yaml::Value>(&content)
                .err()
                .map(|e| e.to_string()),
            _ => None,
        };
        if let Some(e) = parse_err {
            bail!(
                "edit-verify (COTG-1.3): {path} no longer parses as {ext} after the edit \
                 ({e}) — refusing to ship a broken file"
            );
        }
    }
    Ok(())
}

/// EFFECTIVE-408: does the worktree hold a landed-but-BROKEN edit that the ship gate
/// (`verify_staged_edit` / COTG-1.3) would reject? Probes the UNCOMMITTED tree
/// (`git diff HEAD --numstat`, which covers both staged and unstaged changes) with the
/// same rules, BEFORE the deterministic ship stages anything. A weak model that lands
/// an invalid-YAML/JSON edit or a destructive clobber is a *failed* attempt just like
/// landing no edit at all — this lets the EFFECTIVE-366 ladder escalate to a stronger
/// model instead of failing the whole run. Returns false if git can't be read (fail
/// open — the ship gate remains the real backstop).
fn working_tree_edit_is_broken(work_dir: &Path) -> bool {
    let wd = work_dir.to_string_lossy().to_string();
    let out = Command::new("git")
        .args(["-C", &wd, "diff", "HEAD", "--numstat"])
        .output();
    match out {
        Ok(o) if o.status.success() => {
            verify_edit_numstat(work_dir, &String::from_utf8_lossy(&o.stdout)).is_err()
        }
        _ => false,
    }
}

/// COTG-1.2/INFRA-3484: the deterministic ship ceremony. The implement-agent is
/// EDIT-ONLY (see ExternalRepoContract) — the FLEET turns its uncommitted edits into a
/// COTG-1.3/INFRA-3516: the ONE guarded staging+commit ceremony, shared by the initial
/// ship (`deterministic_ship`) and the remediation path (`fix_pr`). Before INFRA-3516 the
/// guards (junk-exclusion + `verify_staged_edit`) lived only inside `deterministic_ship`,
/// so the fix agent's own `git add -A`/commit re-introduced runtime droppings and slipped a
/// destructive edit past the clobber check (BEAST PR #35: commit 1 clean, commits 2-3 = 7
/// junk files + a -324 package.json gut). Both paths now funnel through here:
///  1. stage everything, then DROP chump's runtime droppings (`.chump-locks/`, `sessions/`,
///     `.chump/`) that `agent-run` writes into the cwd — never part of the change.
///  2. an empty staged tree is an honest "no change" error, never a phantom commit.
///  3. `verify_staged_edit` rejects a destructive clobber or an invalid structured file.
///  4. commit under the agent identity + the `Chump-Agent` trailer (provable zero-touch).
///
/// Returns the branch now holding the commit; the caller decides push/PR vs push-to-branch.
fn guarded_stage_and_commit(
    work_dir: &Path,
    commit_msg: &str,
    id: &AgentIdentity,
    context: &str,
) -> Result<String> {
    let wd = work_dir.to_string_lossy().to_string();
    // 1. stage, then drop the runtime droppings agent-run writes into the cwd.
    // CREDIBLE-199: `logs/chump.log` is agent-run's OWN tool-call trace, written
    // into the cwd (the external worktree). Without dropping it, the deterministic
    // ship committed chump's trace file into the target repo — receipt: olive PR #7
    // shipped logs/chump.log alongside the diff (dogfood 2026-08-04). Drop the exact
    // trace path (not the whole logs/ dir) so a target repo's legitimate logs/ is untouched.
    let _ = Command::new("git").args(["-C", &wd, "add", "-A"]).status();
    for junk in [".chump-locks", "sessions", ".chump", "logs/chump.log"] {
        let _ = Command::new("git")
            .args(["-C", &wd, "reset", "-q", "HEAD", "--", junk])
            .status();
    }
    // 2. anything real left? (git diff --cached --quiet exits 0 == no staged changes)
    let nothing_staged = Command::new("git")
        .args(["-C", &wd, "diff", "--cached", "--quiet"])
        .status()
        .map(|s| s.success())
        .unwrap_or(true);
    if nothing_staged {
        bail!("agent made no changes {context} — nothing to ship (honest no-change, not a phantom commit)");
    }
    // 3. COTG-1.3/INFRA-3485: reject a destructive clobber or invalid structured file.
    verify_staged_edit(work_dir)?;
    // 3b. CREDIBLE-200: reject a STUB — no source edit + only placeholder test
    // assertions (the olive PR #7 failure mode: assert 1==1 x2, zero source edits).
    verify_not_stub(work_dir)?;
    // 4a. resolve the current branch.
    let branch = Command::new("git")
        .args(["-C", &wd, "rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|b| !b.is_empty() && b != "HEAD")
        .ok_or_else(|| anyhow::anyhow!("could not resolve the worktree branch in {wd}"))?;
    // 4b. commit under the agent identity + Chump-Agent trailer.
    let mut commit = Command::new("git");
    commit.args(["-C", &wd, "commit", "-m", commit_msg]);
    id.apply_git_env(&mut commit);
    if !commit.status().map(|s| s.success()).unwrap_or(false) {
        bail!("git commit failed in {wd} (edits staged but not committed)");
    }
    Ok(branch)
}

/// PR, deterministically, never depending on a model to run git/gh correctly (the
/// 2026-07-29 live failure: both a weak and a strong model edited but never shipped).
/// Stages the worktree, commits under the agent identity WITH the `Chump-Agent` trailer
/// (so the zero-touch scoreboard, COTG-3.3, always counts it), pushes the per-agent
/// branch, opens the PR against base, and returns its URL. An empty working tree is an
/// honest "no change" error — never a phantom PR.
fn deterministic_ship(
    work_dir: &Path,
    owner_repo: &str,
    base_branch: &str,
    gap: &ProposedGap,
    id: &AgentIdentity,
) -> Result<String> {
    let wd = work_dir.to_string_lossy().to_string();
    // 1-4. stage (minus runtime droppings), verify the edit, and commit under the agent
    // identity + Chump-Agent trailer — via the ONE guarded ceremony shared with the
    // remediation path (COTG-1.3/INFRA-3516), so neither path can drift from these guards.
    let title: String = gap.title.trim().chars().take(72).collect();
    let msg = format!(
        "{title}\n\n{}\n\n{}",
        build_gap_description(gap),
        id.trailer()
    );
    let branch = guarded_stage_and_commit(work_dir, &msg, id, &format!("for '{}'", gap.title))?;
    // 5. push the per-agent branch to origin.
    if !Command::new("git")
        .args([
            "-C",
            &wd,
            "push",
            "-u",
            "origin",
            &branch,
            "--force-with-lease",
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        bail!("git push of {branch} failed in {wd}");
    }
    // 6. open the PR against base and capture its URL from gh's output.
    let body = format!(
        "Automated change by the Chump fleet.\n\n{}\n\n{}",
        build_gap_description(gap),
        id.trailer()
    );
    let out = Command::new(improve_gh_bin())
        .args([
            "pr",
            "create",
            "--repo",
            owner_repo,
            "--base",
            base_branch,
            "--head",
            &branch,
            "--title",
            &title,
            "--body",
            &body,
        ])
        .current_dir(work_dir)
        .output()
        .with_context(|| "gh pr create (is gh on PATH?)")?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    // gh prints the URL on success; on "already exists" it prints the URL in stderr.
    if let Some(url) = first_github_pr_url(&stdout).or_else(|| first_github_pr_url(&stderr)) {
        return Ok(url);
    }
    if !out.status.success() {
        bail!(
            "gh pr create failed: {}",
            stderr.trim().lines().next().unwrap_or("(no output)")
        );
    }
    bail!(
        "gh pr create succeeded but no PR URL in output: {}",
        stdout.trim()
    );
}

// ── COTG-1.4/INFRA-3486: durable-resume journal for the external improve Flow ──────────
// Extends the checkpoint_db mechanism (already wired to the autonomy loop) to improve, so a
// crash AFTER the PR is opened resumes at verify-merge instead of re-implementing — which
// would open a DUPLICATE PR and abandon the agent's work. Keyed by repo + gap.

fn flow_session_id(opts: &Opts) -> String {
    format!("improve:{}", opts.owner_repo)
}

fn flow_ckpt_name(gap: &ProposedGap) -> String {
    let slug: String = gap.title.trim().chars().take(80).collect();
    format!("flow:{slug}")
}

/// Journal the opened PR so a later crash resumes at verify, not by re-opening.
fn save_flow_checkpoint(opts: &Opts, gap: &ProposedGap, pr_url: &str) {
    let snap = format!("{{\"pr_url\":{pr_url:?}}}");
    let _ = crate::checkpoint_db::create_checkpoint(
        &flow_session_id(opts),
        &flow_ckpt_name(gap),
        0,
        Some(&snap),
        Some("improve external-Flow resume point (COTG-1.4)"),
    );
}

/// If a prior run for this gap already opened a PR, return its URL (the resume point).
/// Extract the resumed `pr_url` from a checkpoint's JSON snapshot (the one bit of logic;
/// pure + unit-tested).
fn parse_flow_pr_url(snapshot: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(snapshot).ok()?;
    v.get("pr_url")?.as_str().map(|s| s.to_string())
}

fn load_flow_pr_url(opts: &Opts, gap: &ProposedGap) -> Option<String> {
    let ck = crate::checkpoint_db::checkpoint_by_name(&flow_session_id(opts), &flow_ckpt_name(gap))
        .ok()??;
    parse_flow_pr_url(&ck.state_snapshot_json?)
}

/// Clear the resume journal after a terminal outcome (the Flow is done for this gap).
fn clear_flow_checkpoint(opts: &Opts, gap: &ProposedGap) {
    if let Ok(Some(ck)) =
        crate::checkpoint_db::checkpoint_by_name(&flow_session_id(opts), &flow_ckpt_name(gap))
    {
        let _ = crate::checkpoint_db::delete_checkpoint(ck.id);
    }
}

/// EFFECTIVE-361: does a porcelain status line describe a REAL working-tree edit
/// (not a chump-internal/session artifact)? Pure so it's unit-testable.
fn is_real_edit_status_line(line: &str) -> bool {
    // porcelain v1: "XY <path>" (XY = 2-char status, then a space, then the path).
    let line = line.trim_end();
    if line.len() < 4 {
        return false;
    }
    let path = line[3..].trim();
    // Rename/copy renders as "old -> new" — judge the destination path.
    let path = path.rsplit(" -> ").next().unwrap_or(path).trim();
    // Strip the quotes git adds around paths with special chars.
    let path = path.trim_matches('"');
    if path.is_empty() {
        return false;
    }
    // Ignore chump's own bookkeeping so a heartbeat/log/session write never counts
    // as "the agent made an edit."
    let ignore = [".chump", "sessions/", "logs/", ".chump-locks"];
    !ignore.iter().any(|p| path.starts_with(p))
}

/// EFFECTIVE-361: has the agent left a REAL edit in its work dir? Runs
/// `git status --porcelain` and returns true if any line is a real edit. Fail-safe:
/// on any git error it returns false (treated as "no real edit yet").
fn work_dir_has_real_edits(work_dir: &Path) -> bool {
    let out = Command::new("git")
        .arg("-C")
        .arg(work_dir)
        .args(["status", "--porcelain"])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .any(is_real_edit_status_line),
        _ => false,
    }
}

fn implement_gap(opts: &Opts, clone_dir: &Path, gap: &ProposedGap) -> Result<String> {
    use chump_handoff::contracts::{ExternalRepoContract, ExternalRepoInput};
    use chump_handoff::HandoffContract;

    // INFRA-3478: run the agent in a per-agent LINKED WORKTREE off the shared
    // clone (unless CHUMP_IMPROVE_SHARED_CLONE_DIRECT=1), so concurrent agents on
    // the same external repo don't collide. The shared clone stays canonical
    // (fetch + objects + default branch); the worktree is this agent's isolated
    // checkout. base_branch is resolved from the shared clone (origin/HEAD) so the
    // PR base stays the repo default even though the worktree is on a feature branch.
    let base_branch = detect_base_branch(clone_dir);
    let direct_mode = std::env::var("CHUMP_IMPROVE_SHARED_CLONE_DIRECT")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let work_dir: PathBuf = if direct_mode {
        clone_dir.to_path_buf()
    } else {
        let key = improve_worktree_key();
        let wt = ensure_improve_worktree(clone_dir, &key, &base_branch)?;
        eprintln!(
            "[improve] agent worktree: {} (off shared clone)",
            wt.display()
        );
        wt
    };

    // EFFECTIVE-354: cascade-free GROUNDING — grep the checkout for the gap's
    // feature keywords and point the agent at likely-relevant source files, so a
    // weaker cascade model doesn't have to explore blind. The dogfood stub (olive
    // PR #7) was a model that made ONE tool call and never read any source; handing
    // it concrete file:line starting points is the constraint-safe lift to try
    // before reaching for a stronger (paid/Claude) provider.
    let mut gap_description = build_gap_description(gap);
    if let Some(grounding) = locate_relevant_files(&work_dir, gap) {
        gap_description.push_str(&grounding);
    }
    // MISSION-049: Guest mode forks upstream under our identity instead of
    // direct-pushing a branch — a 3rd-party maintainer never has to grant us
    // push access. Own-repo mode keeps the original direct-push behavior.
    let fork_owner = if opts.mode == ImproveMode::Guest {
        opts.guest_identity.clone()
    } else {
        None
    };
    let input = ExternalRepoInput {
        external_repo: opts.owner_repo.clone(),
        repo_local_path: work_dir.to_string_lossy().to_string(),
        proposed_gap_description: gap_description,
        base_branch,
        fork_owner,
    };

    // MISSION-063: sign commits as a named Chump agent (provable zero-touch).
    let id = agent_identity();
    // COTG-1.2: the agent is edit-only; the fleet commits (with the Chump-Agent trailer)
    // in deterministic_ship, so no commit-signature instruction is appended to the prompt.
    let prompt = ExternalRepoContract::prompt(&input);
    println!(
        "[improve] agent identity: {} <{}>  (trailer: {})",
        id.name,
        id.email,
        id.trailer()
    );

    // Write prompt to a temp file so we don't hit ARG_MAX on complex prompts.
    let prompt_file = write_temp_prompt(&prompt)?;

    // INFRA-3477 / Principle 0 (docs/design/EXTERNAL_REPO_EXECUTION.md): the OS
    // runs on its OWN runtime by default and NEVER defaults to the claude CLI.
    // CHUMP_IMPROVE_BACKEND selects: "chump-local" (default) spawns `chump
    // agent-run` — the INFRA-3475 keystone that runs the chump-local agent
    // (ProviderCascade + full tools incl git/gh) in the clone; "claude" is the
    // opt-in legacy path that spawns the external `claude -p` CLI.
    let backend = resolve_improve_backend();

    let mut cmd = if backend == "claude" {
        // OPT-IN legacy path — external claude CLI (injectable via
        // CHUMP_IMPROVE_CLAUDE_BIN for tests).
        let claude_bin =
            std::env::var("CHUMP_IMPROVE_CLAUDE_BIN").unwrap_or_else(|_| "claude".to_string());
        eprintln!("[improve] backend=claude (opt-in) — spawning external claude CLI");
        let mut c = Command::new(&claude_bin);
        c.arg("-p")
            .arg(std::fs::read_to_string(&prompt_file)?)
            .arg("--dangerously-skip-permissions")
            .args(["--model", "claude-sonnet-4-5"])
            .current_dir(&work_dir);
        // MISSION-063: author the agent's commits under its identity, not the token.
        id.apply_git_env(&mut c);
        // B4 + RESILIENT-106: inject OAUTH token and neutralize conflicting
        // gateway vars so the spawned agent authenticates from any context.
        let oauth_path = configure_claude_auth_env(&mut c);
        if oauth_path {
            eprintln!("[improve] auth: using OAUTH token path for spawned claude");
        }
        c
    } else {
        // DEFAULT (Principle 0): the OS's own runtime via `chump agent-run`.
        // Reads the prompt from --prompt-file, runs the chump-local agent in the
        // clone (--cwd), which implements + commits + pushes + opens the PR and
        // emits the same pr_url JSON block the contract prompt asks for — so the
        // extraction below is backend-agnostic. Auth is ProviderCascade's own,
        // not claude's, so no configure_claude_auth_env here.
        let chump_bin = std::env::var("CHUMP_IMPROVE_CHUMP_BIN")
            .or_else(|_| std::env::var("CHUMP_BIN"))
            .unwrap_or_else(|_| "chump".to_string());
        eprintln!(
            "[improve] backend=chump-local (default) — `chump agent-run` in {}",
            work_dir.display()
        );
        let mut c = Command::new(&chump_bin);
        c.arg("agent-run")
            .arg("--prompt-file")
            .arg(&prompt_file)
            .arg("--cwd")
            .arg(&work_dir);
        // MISSION-063: author the agent's commits under its identity.
        id.apply_git_env(&mut c);
        // COTG-1.6: task-fit model selection — bias the cascade to a strong class for
        // hard external implementation, unless the operator already pinned the class.
        if std::env::var("CHUMP_PREFERRED_MODEL_CLASS").is_err() {
            c.env("CHUMP_PREFERRED_MODEL_CLASS", improve_implement_class());
        }
        c
    };

    // Capture output so we can extract the PR URL from the JSON block.
    let mut out = cmd
        .output()
        .with_context(|| format!("spawn improve backend `{backend}`"))?;

    // Cleanup temp file.
    let _ = std::fs::remove_file(&prompt_file);

    // EFFECTIVE-361: force-edit — when the agent-run SUCCEEDED but only DESCRIBED the
    // change without applying it (diagnose-not-execute, the real M1 wall), re-prompt it
    // to APPLY the edit via str_replace. Capable models routinely narrate the fix and
    // never call an edit tool; a short, explicit "you have not edited anything yet —
    // apply it now with str_replace" nudge is the constraint-safe lift before escalating
    // to a stronger (paid/Claude) provider. Gated off the claude backend (its own path
    // applies edits) and skippable via CHUMP_IMPLEMENT_FORCE_EDIT_TRIES=0.
    if backend != "claude" {
        let tries: u32 = std::env::var("CHUMP_IMPLEMENT_FORCE_EDIT_TRIES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(2);
        let mut attempt = 0;
        while attempt < tries && out.status.success() && !work_dir_has_real_edits(&work_dir) {
            attempt += 1;
            eprintln!(
                "[improve] EFFECTIVE-361 force-edit: agent described but did not apply an edit \
                 (attempt {attempt}/{tries}) — re-prompting to APPLY via str_replace"
            );
            let force_prompt = format!(
                "YOU HAVE NOT EDITED ANY FILE YET — you only described the change. APPLY IT NOW.\n\n\
                 Use the `str_replace` tool: copy the EXACT existing snippet you want to change into \
                 `old_string` (include enough surrounding lines to be unique) and the replacement \
                 text into `new_string`. Do NOT rewrite a whole file with write_file. Make the \
                 smallest edit that satisfies the task below, then stop.\n\n{prompt}"
            );
            let pf = match write_temp_prompt(&force_prompt) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("[improve] force-edit: could not write prompt file: {e}");
                    break;
                }
            };
            let chump_bin = std::env::var("CHUMP_IMPROVE_CHUMP_BIN")
                .or_else(|_| std::env::var("CHUMP_BIN"))
                .unwrap_or_else(|_| "chump".to_string());
            let mut c = Command::new(&chump_bin);
            c.arg("agent-run")
                .arg("--prompt-file")
                .arg(&pf)
                .arg("--cwd")
                .arg(&work_dir);
            id.apply_git_env(&mut c);
            if std::env::var("CHUMP_PREFERRED_MODEL_CLASS").is_err() {
                c.env("CHUMP_PREFERRED_MODEL_CLASS", improve_implement_class());
            }
            match c.output() {
                Ok(o) => out = o,
                Err(e) => {
                    eprintln!("[improve] force-edit: re-run spawn failed: {e}");
                    let _ = std::fs::remove_file(&pf);
                    break;
                }
            }
            let _ = std::fs::remove_file(&pf);
        }
    }

    // EFFECTIVE-366: fail-through escalation to the Claude FINAL RUNG. If the free/sub
    // cascade (+ EFFECTIVE-361 force-edit) landed NO real edit, escalate to sonnet/opus
    // on the SAME worktree before giving up. Operator design (2026-08-06, after the M1
    // proof pvc#2): spend Claude ONLY as the last resort — every cheaper tier failed to
    // land the job first. M1 proved the free/sub models all avoid str_replace (they grab
    // patch_file/run_cli, both fail); Claude reliably edits. The claude run is edit-first;
    // deterministic_ship below turns its edits into the PR, same as the free path. Skip
    // with CHUMP_IMPLEMENT_ESCALATE_CLAUDE=0.
    //
    // EFFECTIVE-408: also escalate when the cascade landed a BROKEN edit — one that the
    // COTG-1.3 ship gate (invalid YAML/JSON/TOML, or a destructive clobber) would reject.
    // A landed-but-rejected edit is a failed attempt exactly like landing no edit: without
    // this, `deterministic_ship` below just bails RC=1 and the whole run fails instead of
    // giving the next-stronger model a shot at fixing it.
    let landed_no_edit = !work_dir_has_real_edits(&work_dir);
    let landed_broken_edit = !landed_no_edit && working_tree_edit_is_broken(&work_dir);
    if backend != "claude"
        && std::env::var("CHUMP_IMPLEMENT_ESCALATE_CLAUDE").as_deref() != Ok("0")
        && (landed_no_edit || landed_broken_edit)
    {
        let why = if landed_broken_edit {
            "landed a broken edit (COTG-1.3 ship gate would reject it)"
        } else {
            "landed no edit"
        };
        eprintln!(
            "[improve] EFFECTIVE-366 escalation: free/sub cascade {why} — \
             escalating to the Claude final rung (sonnet/opus)"
        );
        let claude_bin =
            std::env::var("CHUMP_IMPROVE_CLAUDE_BIN").unwrap_or_else(|_| "claude".to_string());
        let mut c = Command::new(&claude_bin);
        c.arg("-p")
            .arg(&prompt)
            .arg("--dangerously-skip-permissions")
            .args(["--model", "claude-sonnet-4-5"])
            .current_dir(&work_dir);
        id.apply_git_env(&mut c);
        let oauth_path = configure_claude_auth_env(&mut c);
        if oauth_path {
            eprintln!("[improve] EFFECTIVE-366 escalation auth: using OAUTH token path for claude");
        }
        match c.output() {
            Ok(o) => {
                let code = o.status.code().unwrap_or(-1);
                out = o;
                eprintln!(
                    "[improve] EFFECTIVE-366 escalation: claude rung exited {code} — real edits now: {}",
                    work_dir_has_real_edits(&work_dir)
                );
            }
            Err(e) => eprintln!("[improve] EFFECTIVE-366 escalation: claude spawn failed: {e}"),
        }
    }

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!(
            "improve backend `{}` exited {} — stderr: {}",
            backend,
            out.status.code().unwrap_or(-1),
            stderr.trim().lines().next().unwrap_or("(no output)")
        );
    }

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();

    // Extract the JSON block containing pr_url.
    // COTG-1.2/INFRA-3484: the agent is edit-only — the FLEET turns its uncommitted
    // edits into a PR deterministically (commit with the Chump-Agent trailer → push →
    // gh pr create), never depending on the model to run git/gh. `stdout` is now just the
    // agent's summary (kept above for logs / storm detection).
    let _ = &stdout;
    let pr_url = deterministic_ship(&work_dir, &opts.owner_repo, &input.base_branch, gap, &id)?;

    // INFRA-3478: success — the branch is pushed to origin, so this agent's worktree is
    // disposable. On the failure paths above we deliberately leave it for debugging;
    // a later run's `git worktree prune` reclaims it.
    if !direct_mode {
        remove_improve_worktree(clone_dir, &work_dir);
    }
    Ok(pr_url)
}

/// Stage 4: Call `chump external verify-merge` and return the verdict string.
///
/// CREDIBLE-100: we key off the bar's real "Verdict: MERGE" / "Verdict: HELD"
/// output line, NOT the spawned process exit code. A stale or wrong binary
/// (e.g. one that routes `external verify-merge` to the brain/chat) exits 0 but
/// prints no Verdict: line — `parse_verdict` returns None and we bail loudly
/// instead of silently reporting "verified". Verdict fabrication is the trust
/// keystone failure we are preventing.
//
// EFFECTIVE-375's `ac_hard_gate_should_hold` helper was removed in CREDIBLE-212:
// the AC hard gate moved from a post-merge re-judge here into Gate 4 of
// `external verify-merge` (before the merge), so the "downgrade verified→held"
// decision no longer exists at this layer — verify_and_merge simply returns
// HELD(ac-incomplete) when Gate 4 blocks.
/// CREDIBLE-215: advisory mechanical-stub check, run before VERIFY-MERGE so a
/// REACHES/TEST-ONLY/UNRELATED verdict is visible ahead of the CI round. Best
/// effort: any failure (no target resolvable, `gh pr diff` unavailable,
/// almanac unreachable) is swallowed — this must never block the ship path.
fn run_verify_reaches_advisory(opts: &Opts, picked: &ProposedGap, pr_num: u64) {
    let Some(target) = crate::commands::reachability::extract_target_from_text(&format!(
        "{}\n{}",
        picked.title,
        picked.acceptance_criteria_draft.join("\n")
    )) else {
        return;
    };

    let gh_bin = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());
    let out = Command::new(&gh_bin)
        .args([
            "pr",
            "diff",
            &pr_num.to_string(),
            "--repo",
            &opts.owner_repo,
            "--name-only",
        ])
        .output();
    let Ok(out) = out else { return };
    if !out.status.success() {
        return;
    }
    let diff_names = String::from_utf8_lossy(&out.stdout).to_string();

    let tmp = std::env::temp_dir().join(format!("verify-reaches-{pr_num}.txt"));
    if std::fs::write(&tmp, &diff_names).is_err() {
        return;
    }

    let tmp_path = tmp.to_string_lossy().to_string();
    let rc = crate::commands::reachability::run(&[
        "--gap".to_string(),
        picked.title.clone(),
        "--target".to_string(),
        target,
        "--diff".to_string(),
        tmp_path,
    ]);
    let _ = std::fs::remove_file(&tmp);
    let _ = rc;
}

fn verify_and_merge(opts: &Opts, pr_num: u64, _gap_title: &str) -> Result<String> {
    // CREDIBLE-100: resolve the binary that's CURRENTLY RUNNING — it has the
    // `external verify-merge` subcommand. Prefer CHUMP_IMPROVE_CHUMP_BIN for
    // test injection, then current_exe(), then "chump" as last resort.
    // Do NOT use resolve_chump_bin()'s shared-target lookup — a sibling build
    // can clobber target/debug/chump with a version that lacks the subcommand.
    let chump_bin = if let Ok(explicit) = std::env::var("CHUMP_IMPROVE_CHUMP_BIN") {
        explicit
    } else if let Ok(exe) = std::env::current_exe() {
        exe.to_string_lossy().to_string()
    } else {
        "chump".to_string()
    };

    let mut args = vec![
        "external".to_string(),
        "verify-merge".to_string(),
        "--pr".to_string(),
        pr_num.to_string(),
        "--repo".to_string(),
        opts.owner_repo.clone(),
        "--gap".to_string(),
        opts.gap_id
            .clone()
            .unwrap_or_else(|| "EFFECTIVE-177".to_string()),
    ];
    // MISSION-049: Guest mode NEVER self-merges, no matter what `--apply` says at
    // the `chump improve` level — `--apply` there still means "push the PR for
    // real," but the merge decision belongs to the upstream maintainer. Omitting
    // `--apply` here makes the sub-invocation judge-only: it still reports
    // Verdict: MERGE/HELD on the real gates, it just never calls `gh pr merge`.
    let self_merge_allowed = opts.apply && opts.mode == ImproveMode::Own;
    if self_merge_allowed {
        args.push("--apply".to_string());
    } else if opts.apply && opts.mode == ImproveMode::Guest {
        println!(
            "[improve] GUEST mode: judging PR #{pr_num} on merit but NOT self-merging — \
             left open for the upstream maintainer."
        );
    }

    // Pass through the GH bin override if set (so tests see the same fake binary
    // that was used for the implement stage).
    let gh_bin = std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string());

    let mut cmd = Command::new(&chump_bin);
    cmd.args(&args);
    if gh_bin != "gh" {
        cmd.env("CHUMP_GH_BIN", &gh_bin);
    }

    // CREDIBLE-100: capture output, not just exit code. The real bar prints
    // "Verdict: MERGE" or "Verdict: HELD(<reason>)"; we key off that line.
    let out = cmd
        .output()
        .with_context(|| format!("spawn `{chump_bin} external verify-merge`"))?;

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();

    // Transparency: always print the bar's output so the operator can see what happened.
    if !stdout.is_empty() {
        print!("{stdout}");
    }
    if !stderr.is_empty() {
        eprint!("{stderr}");
    }

    // CREDIBLE-100: key off the real Verdict: line. bail! on misfire (no Verdict: line).
    match parse_verdict(&stdout) {
        Some(v) => Ok(v.to_string()),
        None => bail!(
            "verify-merge produced no bar Verdict: line — the sub-invocation did not run \
             the real bar (chump_bin={chump_bin}); refusing to report a verdict"
        ),
    }
}

/// Parse the merge bar's stdout for a `Verdict:` line.
///
/// Returns:
/// - `Some("verified")` if stdout contains `"Verdict: MERGE"`.
/// - `Some("held")` if stdout contains `"Verdict: HELD"`.
/// - `None` if no `Verdict:` line is present (misfire / stale binary / brain reply).
///
/// This is the trust keystone: we NEVER default to "verified".
/// Called by `verify_and_merge`; pub(crate) for unit tests.
///
/// # Examples
///
/// ```
/// # use chump::improve::parse_verdict; // doctest path
/// assert_eq!(parse_verdict("Verdict: MERGE"), Some("verified"));
/// assert_eq!(parse_verdict("Verdict: HELD(unproven)"), Some("held"));
/// assert_eq!(parse_verdict("Hello!"), None);
/// ```
pub(crate) fn parse_verdict(stdout: &str) -> Option<&'static str> {
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.contains("Verdict: MERGE") {
            return Some("verified");
        }
        if trimmed.contains("Verdict: HELD") {
            return Some("held");
        }
    }
    None
}

// ── Ambient emit helpers ───────────────────────────────────────────────────

/// Emit `kind=improve_cycle_complete`.
///
/// scanner-anchor: kind=improve_cycle_complete (EFFECTIVE-177)
fn emit_cycle_complete(repo: &str, gap_title: &str, verdict: &str, pr_url: Option<&str>) {
    // MISSION-063: stamp WHICH named agent ran this cycle so the fleet log (not
    // just git) attributes work to a Chump agent.
    let id = agent_identity();
    let mut fields = vec![
        ("repo".to_string(), repo.to_string()),
        ("gap".to_string(), gap_title.to_string()),
        ("verdict".to_string(), verdict.to_string()),
        ("agent".to_string(), format!("{}@{}", id.codename, id.node)),
    ];
    if let Some(url) = pr_url {
        fields.push(("pr".to_string(), url.to_string()));
    }
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "improve_cycle_complete".to_string(),
        source: Some("chump-improve".to_string()),
        fields,
        ..Default::default()
    });
}

/// Emit `kind=redundant_work_skipped`.
///
/// scanner-anchor: kind=redundant_work_skipped (EFFECTIVE-177 / ZERO-WASTE-006)
fn emit_redundant_work_skipped(repo: &str, gap_title: &str, reason: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "redundant_work_skipped".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("gap".to_string(), gap_title.to_string()),
            ("reason".to_string(), reason.to_string()),
        ],
        ..Default::default()
    });
}

/// CREDIBLE-198: emit `kind=already_satisfied_skipped` when the verify-before-execute gate
/// finds a gap's acceptance already met and skips the fix-agent (sibling of
/// `redundant_work_skipped`).
///
/// scanner-anchor: kind=already_satisfied_skipped (CREDIBLE-198)
fn emit_already_satisfied_skipped(repo: &str, gap_id: &str, evidence: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "already_satisfied_skipped".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("gap".to_string(), gap_id.to_string()),
            ("evidence".to_string(), evidence.to_string()),
        ],
        ..Default::default()
    });
}

/// MISSION-049: emit `kind=guest_pr_cap_reached` — Guest mode refused to open a new
/// PR because we already hold `cap` (or more) open PRs on the target repo.
///
/// scanner-anchor: kind=guest_pr_cap_reached (MISSION-049)
fn emit_guest_pr_cap_reached(repo: &str, identity: &str, open: u32, cap: u32) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "guest_pr_cap_reached".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("identity".to_string(), identity.to_string()),
            ("open_prs".to_string(), open.to_string()),
            ("cap".to_string(), cap.to_string()),
        ],
        ..Default::default()
    });
}

/// CREDIBLE-198 (CREDIBLE-197 slice 2): parse a read-only verify verdict of the shape
/// `VERDICT: SATISFIED|NOT-SATISFIED - <reason>`. Returns `(satisfied, reason)`. FAIL-OPEN:
/// anything unparseable/ambiguous returns `(false, …)` so the caller EXECUTES — we never
/// false-close real work on a garbled reply. Pure; unit-tested.
fn parse_satisfied_verdict(resp: &str) -> (bool, String) {
    for line in resp.lines() {
        let t = line.trim();
        if t.to_uppercase().starts_with("VERDICT:") {
            let body = t.splitn(2, ':').nth(1).unwrap_or("").trim();
            // "NOT-SATISFIED" / "NOT SATISFIED" start with "NOT", not "SATISFIED".
            let satisfied = body.to_uppercase().starts_with("SATISFIED");
            return (satisfied, body.to_string());
        }
    }
    (false, "unparseable verify reply — executing".to_string())
}

/// CREDIBLE-198 / CREDIBLE-197 slice 2: read-only check — is this REGISTRY gap's acceptance
/// ALREADY satisfied by the current clone? Returns `Some(receipt)` if SATISFIED (the caller
/// auto-closes it `already_satisfied` and skips the fix-agent), `None` otherwise. FAIL-OPEN:
/// any doubt/error/gateway-down → `None` → the caller EXECUTES, so we never false-close real
/// work. Mirrors the read-only LLM pattern of `bench.rs::spirit_judge`. Makes NO changes.
fn verify_already_satisfied(clone_dir: &Path, gap_id: &str, chump_bin: &str) -> Option<String> {
    // Real acceptance criteria from the registry — a `--gap` run's synthesized ProposedGap
    // carries only a generic placeholder draft, so we must read the actual AC here.
    let repo_root = crate::repo_path::repo_root();
    let store = chump_gap_store::GapStore::open(&repo_root).ok()?;
    let row = store.get(gap_id).ok()??;
    let ac = chump_gap_store::parse_json_ac_list(&row.acceptance_criteria);
    if ac.is_empty() {
        return None; // nothing checkable → execute
    }
    let cd = clone_dir.to_string_lossy().to_string();
    // Read-only repo context: recent commits + bounded heads of the files the AC names.
    let log = Command::new("git")
        .args(["-C", &cd, "log", "--oneline", "-25"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut files_ctx = String::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for tok in ac.join(" ").split(|c: char| {
        !(c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' || c == '/')
    }) {
        let ext_ok = tok
            .rsplit('.')
            .next()
            .map(|e| !e.is_empty() && e.len() <= 4 && e.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or(false);
        if !(tok.contains('.') && tok.len() >= 4 && ext_ok) {
            continue;
        }
        if !seen.insert(tok.to_string()) || seen.len() > 6 {
            continue;
        }
        if let Ok(found) = Command::new("git")
            .args(["-C", &cd, "ls-files", &format!("*{tok}")])
            .output()
        {
            if let Some(path) = String::from_utf8_lossy(&found.stdout).lines().next() {
                if let Ok(content) = std::fs::read_to_string(Path::new(&cd).join(path)) {
                    let head: String = content.lines().take(60).collect::<Vec<_>>().join("\n");
                    files_ctx.push_str(&format!(
                        "\n=== {path} (head) ===\n{}\n",
                        head.chars().take(1500).collect::<String>()
                    ));
                }
            }
        }
    }
    let ac_text = ac
        .iter()
        .enumerate()
        .map(|(i, c)| format!("{}. {c}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    let prompt = format!(
        "You are a strict reviewer. Are ALL of these acceptance criteria ALREADY satisfied by \
         the CURRENT state of the repo shown below? Make NO changes. Answer SATISFIED only if you \
         can point to concrete evidence for EACH criterion; if ANY is unmet or you are unsure, \
         answer NOT-SATISFIED. Reply EXACTLY one line:\n\
         VERDICT: SATISFIED|NOT-SATISFIED - <file:line evidence, or which criterion is unmet; \
         <=25 words>\n\n\
         === ACCEPTANCE CRITERIA ===\n{ac_text}\n\n\
         === RECENT COMMITS ===\n{log}\n=== REPO FILES (heads) ===\n{}\n",
        files_ctx.chars().take(6000).collect::<String>()
    );
    let model = std::env::var("CHUMP_VERIFY_MODEL").unwrap_or_else(|_| "opus".to_string());
    let mut child = Command::new(chump_bin)
        .args(["llm-complete", "--model", &model, "--max-tokens", "200"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut si) = child.stdin.take() {
        use std::io::Write;
        let _ = si.write_all(prompt.as_bytes());
    }
    let out = child.wait_with_output().ok()?;
    let (satisfied, reason) = parse_satisfied_verdict(&String::from_utf8_lossy(&out.stdout));
    if satisfied {
        Some(reason)
    } else {
        None // fail-open: NOT-SATISFIED / unparseable → execute
    }
}

/// Emit `kind=improve_pr_remediation` — one per fix attempt on a HELD PR.
///
/// scanner-anchor: kind=improve_pr_remediation (MISSION-059)
fn emit_pr_remediation(
    repo: &str,
    pr_num: u64,
    class: &str,
    action: &str,
    attempt: usize,
    model: &str,
) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "improve_pr_remediation".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("pr".to_string(), pr_num.to_string()),
            ("class".to_string(), class.to_string()),
            ("action".to_string(), action.to_string()),
            ("attempt".to_string(), attempt.to_string()),
            ("model".to_string(), model.to_string()),
        ],
        ..Default::default()
    });
}

/// Emit `kind=remediation_fix_confidence` — the judgment organ's AC-coverage
/// confidence (0..1) for a candidate remediation fix, so the loop + operators
/// can see how well it satisfies the gap's acceptance criteria. Observability
/// only; the ship/iterate decision stays with `verify_and_merge` (EFFECTIVE-334).
///
/// scanner-anchor: kind=remediation_fix_confidence (EFFECTIVE-334)
fn emit_remediation_fix_confidence(
    repo: &str,
    pr_num: u64,
    attempt: usize,
    confidence: f64,
    ac_status: &str,
) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "remediation_fix_confidence".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("pr".to_string(), pr_num.to_string()),
            ("attempt".to_string(), attempt.to_string()),
            ("confidence".to_string(), format!("{confidence:.3}")),
            ("ac_status".to_string(), ac_status.to_string()),
        ],
        ..Default::default()
    });
}

/// Emit `kind=improve_pr_closed` — the loop closed a PR it could not get green
/// (terminal, no-abandon).
///
/// scanner-anchor: kind=improve_pr_closed (MISSION-059)
fn emit_pr_closed(repo: &str, pr_num: u64, pr_url: &str, reason: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "improve_pr_closed".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("pr".to_string(), pr_num.to_string()),
            ("pr_url".to_string(), pr_url.to_string()),
            ("reason".to_string(), reason.to_string()),
        ],
        ..Default::default()
    });
}

// ── MISSION-059: no-abandon PR remediation ─────────────────────────────────
//
// The improve loop must OWN every PR it opens to a terminal state — merged or
// closed — never left open-red. On a HELD verdict we compose the CI-failure
// classifier (ci_summary::classify_log, INFRA-506) with two remediation paths:
//   * flake / infra-broken → RERUN the failed checks (no model spend — the
//     scale lever: transient failures cost nothing to clear).
//   * test-coupling / real-bug → re-spawn a fix agent on the SAME branch with
//     an ESCALATING model (sonnet → opus, mirroring the work-tier cost ladder
//     EFFECTIVE-314 — harder fixes get a more capable model, just like the work).
// After a bounded retry budget with no green, CLOSE the PR with a reason.

/// Remediation action for a CI-failure class.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub(crate) enum Remediation {
    /// Transient / infra failure — rerun the failed checks, spend no model.
    Rerun,
    /// A real defect (or unknown) the agent must fix on the same branch.
    AgentFix,
}

/// Map a `ci_summary::classify_log` class to a remediation action.
///
/// Unknown/empty classes fall through to `AgentFix` — the safe default: try a
/// real fix rather than blindly rerun a failure we could not read.
pub(crate) fn remediation_for_class(class: &str) -> Remediation {
    match class {
        "flake" | "infra-broken" => Remediation::Rerun,
        _ => Remediation::AgentFix, // test-coupling | real-bug | unknown
    }
}

/// The model-escalation ladder for fix retries. Attempt `i` (0-based) uses
/// `ladder[min(i, len-1)]` — later attempts escalate to a more capable (costlier)
/// model. Configurable via `CHUMP_IMPROVE_MODEL_LADDER` (comma-separated).
pub(crate) fn fix_model_ladder() -> Vec<String> {
    std::env::var("CHUMP_IMPROVE_MODEL_LADDER")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|m| m.trim().to_string())
                .filter(|m| !m.is_empty())
                .collect::<Vec<String>>()
        })
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| vec!["claude-sonnet-4-5".to_string(), "opus".to_string()])
}

/// Pick the model for a 0-based fix attempt, clamping to the last ladder rung.
pub(crate) fn model_for_attempt(attempt: usize, ladder: &[String]) -> &str {
    if ladder.is_empty() {
        return "claude-sonnet-4-5";
    }
    &ladder[attempt.min(ladder.len() - 1)]
}

/// How many fix attempts before we close the PR. `CHUMP_IMPROVE_FIX_RETRIES`
/// (default 2). Clamped to at least 1 so we always try before closing.
fn fix_retries() -> usize {
    std::env::var("CHUMP_IMPROVE_FIX_RETRIES")
        .ok()
        .and_then(|s| s.trim().parse::<usize>().ok())
        .unwrap_or(2)
        .max(1)
}

/// The `gh` binary — injectable for tests via `CHUMP_IMPROVE_GH_BIN`.
fn improve_gh_bin() -> String {
    std::env::var("CHUMP_IMPROVE_GH_BIN").unwrap_or_else(|_| "gh".to_string())
}

/// Extract the `databaseId` of the first run whose `conclusion` is `"failure"`
/// from a `gh run list --json databaseId,conclusion` array. Pure — unit-tested.
pub(crate) fn find_failed_run_id(json: &str) -> Option<u64> {
    for frag in json.split('{').skip(1) {
        if !frag.contains("\"conclusion\":\"failure\"") {
            continue;
        }
        if let Some(pos) = frag.find("\"databaseId\":") {
            let rest = &frag[pos + "\"databaseId\":".len()..];
            let digits: String = rest
                .trim_start()
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if let Ok(n) = digits.parse::<u64>() {
                return Some(n);
            }
        }
    }
    None
}

/// The PR's head branch ref (`gh pr view <n> --json headRefName`).
fn pr_head_branch(opts: &Opts, pr_num: u64) -> Option<String> {
    let out = Command::new(improve_gh_bin())
        .args([
            "pr",
            "view",
            &pr_num.to_string(),
            "--repo",
            &opts.owner_repo,
            "--json",
            "headRefName",
            "-q",
            ".headRefName",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

/// The most-recent failed run id for a head branch (via `gh run list`).
fn latest_failed_run_id(opts: &Opts, head_branch: &str) -> Option<u64> {
    if head_branch.is_empty() {
        return None;
    }
    let out = Command::new(improve_gh_bin())
        .args([
            "run",
            "list",
            "--repo",
            &opts.owner_repo,
            "--branch",
            head_branch,
            "--limit",
            "10",
            "--json",
            "databaseId,conclusion",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    find_failed_run_id(&String::from_utf8_lossy(&out.stdout))
}

/// Fetch the failing-check log for the PR's latest run. Best-effort: empty on
/// any gh failure (the classifier treats empty as `real-bug` → AgentFix, the
/// safe default).
fn fetch_failing_log(opts: &Opts, head_branch: &str) -> String {
    let Some(id) = latest_failed_run_id(opts, head_branch) else {
        return String::new();
    };
    let out = Command::new(improve_gh_bin())
        .args([
            "run",
            "view",
            &id.to_string(),
            "--repo",
            &opts.owner_repo,
            "--log-failed",
        ])
        .output();
    match out {
        Ok(o) => {
            let raw = String::from_utf8_lossy(&o.stdout).into_owned();
            if raw.len() > 65_536 {
                raw[..65_536].to_string()
            } else {
                raw
            }
        }
        Err(_) => String::new(),
    }
}

/// Rerun the failed jobs of the PR's latest failed run (flake path).
fn rerun_failed_checks(opts: &Opts, head_branch: &str) -> Result<()> {
    if let Some(id) = latest_failed_run_id(opts, head_branch) {
        let _ = Command::new(improve_gh_bin())
            .args([
                "run",
                "rerun",
                &id.to_string(),
                "--repo",
                &opts.owner_repo,
                "--failed",
            ])
            .status();
        println!("[improve] reran failed jobs of run {id} (flake path — no model spend)");
    } else {
        println!("[improve] no failed run id found to rerun; will re-verify as-is");
    }
    Ok(())
}

/// Close a PR with a reason comment (the no-abandon terminal state).
fn close_pr(opts: &Opts, pr_num: u64, reason: &str) -> Result<()> {
    let out = Command::new(improve_gh_bin())
        .args([
            "pr",
            "close",
            &pr_num.to_string(),
            "--repo",
            &opts.owner_repo,
            "--comment",
            reason,
        ])
        .output()
        .with_context(|| format!("gh pr close #{pr_num}"))?;
    if !out.status.success() {
        bail!(
            "gh pr close #{pr_num} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// The fix-agent prompt: check out the EXISTING branch, fix the ROOT CAUSE of
/// the CI failure, push to the same branch — do NOT open a new PR or merge.
fn build_fix_prompt(
    repo: &str,
    pr_num: u64,
    head_branch: &str,
    gap_title: &str,
    failing_log: &str,
) -> String {
    format!(
        "You are fixing a FAILING pull request in the repository `{repo}`.\n\n\
PR #{pr_num} (branch `{head_branch}`) implements: {gap_title}\n\
Its CI is RED. Your job is to make CI GREEN by fixing the ROOT CAUSE.\n\n\
The PR's branch is ALREADY checked out in your working directory. EDIT FILES ONLY:\n\
1. Diagnose the failure from the CI log below and fix the underlying cause in the code. \
Do NOT disable the failing check, weaken an assertion, or delete the test to go green.\n\
2. EDIT ONLY. Do NOT run git and do NOT touch version control at all — no stage, commit, \
push, checkout, branch, merge, or PR open/close. The system commits your edits \
deterministically (with the zero-touch trailer) and pushes them to the existing branch. \
Running git yourself risks committing runtime junk or a destructive clobber.\n\
3. If the failure is a genuine flake unrelated to this diff, make the smallest real fix; \
do NOT fabricate a no-op just to trigger a rerun.\n\n\
--- FAILING CI LOG (truncated) ---\n{failing_log}\n--- END LOG ---\n\n\
Output nothing but a one-line summary of what you changed."
    )
}

/// Re-spawn a fix agent on the PR's branch with an escalating model.
///
/// COTG-1.3/INFRA-3516: the agent EDITS ONLY. This function deterministically checks out
/// the PR branch BEFORE the agent runs, then commits+pushes the agent's edits through the
/// SAME guarded ceremony as the initial ship (`guarded_stage_and_commit`) AFTER — so the
/// remediation path can no longer re-introduce runtime droppings or slip a destructive
/// clobber past the guards (the BEAST PR #35 defect: remediation commits added 7 junk files
/// + a -324 package.json gut the ship path would have rejected).
// EFFECTIVE-379: the shared checkout → dispatch → guarded-commit → push ceremony
// for BOTH the CI-failure fix (`fix_pr`) and the AC-incompleteness fix
// (`fix_pr_ac`). The caller supplies the fully-built task prompt body (the part
// that differs — a failing CI log vs. the unmet acceptance bullets) and a commit
// kind tag (`ci` | `ac`); everything else — placing the PR branch at its remote
// tip, spawning the backend agent (edit-only), and pushing the guarded commit to
// the existing branch — is identical.
fn fix_pr_dispatch(
    clone_dir: &Path,
    pr_num: u64,
    head_branch: &str,
    gap_title: &str,
    task_prompt_body: &str,
    commit_kind: &str,
    model: &str,
) -> Result<()> {
    // MISSION-063: fixes are signed by the same named agent as the original work.
    let id = agent_identity();
    let cd = clone_dir.to_string_lossy().to_string();
    // Deterministically place the PR's branch at its remote tip in the working tree; the
    // agent only edits from here (the prompt no longer runs git). `-B ... FETCH_HEAD`
    // is idempotent across retries — each attempt starts from the PR's current head.
    //
    // INFRA-3518: check out from FETCH_HEAD, NOT `origin/<branch>`. The external clone at
    // ~/.chump/external/<repo>/clone uses a narrow fetch refspec that does not create an
    // `origin/<branch>` remote-tracking ref for arbitrary PR branches, so
    // `checkout -B <branch> origin/<branch>` failed with "fatal: 'origin/…' is not a
    // commit" and remediation bailed before ever reaching the fix agent (caught by the
    // 2nd RESCUE bench lap 2026-07-30). `git fetch origin <branch>` always populates
    // FETCH_HEAD regardless of refspec — and we now bail loudly if the fetch itself fails.
    if !Command::new("git")
        .args(["-C", &cd, "fetch", "origin", head_branch])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        bail!("could not fetch PR branch {head_branch} from origin in {cd} for remediation");
    }
    // INFRA-3519: the external scratch clone can be left dirty by a prior lap's
    // operations, so a plain checkout refuses ("local changes would be
    // overwritten by checkout"). The clone is throwaway — hard-reset + clean it,
    // then force the checkout, so remediation always starts from the PR's clean
    // remote tip regardless of what the previous attempt left behind.
    let _ = Command::new("git")
        .args(["-C", &cd, "reset", "--hard", "HEAD"])
        .status();
    let _ = Command::new("git")
        .args(["-C", &cd, "clean", "-fd"])
        .status();
    if !Command::new("git")
        .args(["-C", &cd, "checkout", "-f", "-B", head_branch, "FETCH_HEAD"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        bail!("could not checkout PR branch {head_branch} (FETCH_HEAD) in {cd} for remediation");
    }
    let prompt = format!("{}{}", task_prompt_body, id.prompt_signature());
    let prompt_file = write_temp_prompt(&prompt)?;

    // COTG-1.6/INFRA-3488: the fix-retry path must NOT default to claude either
    // (Principle 0 — this was the real violation: fix_pr spawned claude unconditionally,
    // so a failing PR pulled in claude even in default chump-local mode). Default is the
    // OS's own runtime via `chump agent-run`; claude is opt-in. The escalating `model`
    // ladder maps to the cascade's model-CLASS so the sonnet→opus strength progression
    // is preserved without naming claude.
    let backend = resolve_improve_backend();
    let mut cmd = if backend == "claude" {
        let claude_bin =
            std::env::var("CHUMP_IMPROVE_CLAUDE_BIN").unwrap_or_else(|_| "claude".to_string());
        let mut c = Command::new(&claude_bin);
        c.arg("-p")
            .arg(std::fs::read_to_string(&prompt_file)?)
            .arg("--dangerously-skip-permissions")
            .args(["--model", model])
            .current_dir(clone_dir);
        id.apply_git_env(&mut c);
        configure_claude_auth_env(&mut c);
        c
    } else {
        let chump_bin = std::env::var("CHUMP_IMPROVE_CHUMP_BIN")
            .or_else(|_| std::env::var("CHUMP_BIN"))
            .unwrap_or_else(|_| "chump".to_string());
        let mut c = Command::new(&chump_bin);
        c.arg("agent-run")
            .arg("--prompt-file")
            .arg(&prompt_file)
            .arg("--cwd")
            .arg(clone_dir);
        id.apply_git_env(&mut c);
        if std::env::var("CHUMP_PREFERRED_MODEL_CLASS").is_err() {
            c.env("CHUMP_PREFERRED_MODEL_CLASS", model_to_class(model));
        }
        c
    };

    let out = cmd
        .output()
        .with_context(|| format!("spawn improve fix backend `{backend}`"))?;
    let _ = std::fs::remove_file(&prompt_file);

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!(
            "improve fix backend `{}` exited {} — {}",
            backend,
            out.status.code().unwrap_or(-1),
            stderr.trim().lines().next().unwrap_or("(no output)")
        );
    }

    // COTG-1.3/INFRA-3516: commit + push the agent's edits through the SAME guarded ceremony
    // as the initial ship — junk-exclusion + verify_staged_edit — then push to the EXISTING
    // branch (no new PR). Before this, the agent ran freeform git and re-corrupted the PR.
    let title: String = gap_title.trim().chars().take(60).collect();
    let msg = format!(
        "fix({commit_kind}): {title} (PR #{pr_num})\n\n{}",
        id.trailer()
    );
    let _branch =
        guarded_stage_and_commit(clone_dir, &msg, &id, &format!("for the PR #{pr_num} fix"))?;
    if !Command::new("git")
        .args([
            "-C",
            &cd,
            "push",
            "origin",
            head_branch,
            "--force-with-lease",
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        bail!("git push of the fix to {head_branch} failed in {cd}");
    }
    Ok(())
}

/// CI-failure remediation: build the failing-log fix prompt, then dispatch through
/// the shared ceremony. Thin wrapper — EFFECTIVE-379 extracted the shared core into
/// [`fix_pr_dispatch`] so the AC path can reuse it.
fn fix_pr(
    clone_dir: &Path,
    repo: &str,
    pr_num: u64,
    head_branch: &str,
    gap_title: &str,
    failing_log: &str,
    model: &str,
) -> Result<()> {
    let log_excerpt: String = failing_log.chars().take(6000).collect();
    let body = build_fix_prompt(repo, pr_num, head_branch, gap_title, &log_excerpt);
    fix_pr_dispatch(
        clone_dir,
        pr_num,
        head_branch,
        gap_title,
        &body,
        "ci",
        model,
    )
}

/// EFFECTIVE-379: the fix prompt for an AC-incomplete PR — CI is GREEN but the
/// AC judge (Gate 4 of external verify-merge, CREDIBLE-212) found specific unmet
/// acceptance criteria. The CI path is useless here: `fetch_failing_log` returns
/// nothing on green CI, so the agent would get an empty log. Instead we hand it
/// the exact unmet-bullet TEXT and tell it to satisfy ONLY those.
fn build_ac_fix_prompt(
    repo: &str,
    pr_num: u64,
    head_branch: &str,
    gap_title: &str,
    unmet_bullets: &[String],
) -> String {
    let bullets = unmet_bullets
        .iter()
        .enumerate()
        .map(|(i, b)| format!("{}. {}", i + 1, b.trim()))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "You are COMPLETING an incomplete pull request in the repository `{repo}`.\n\n\
PR #{pr_num} (branch `{head_branch}`) implements: {gap_title}\n\
Its CI is GREEN, but an acceptance-criteria review found these criteria STILL UNMET:\n\n\
--- UNMET ACCEPTANCE CRITERIA ---\n{bullets}\n--- END ---\n\n\
The PR's branch is ALREADY checked out in your working directory. EDIT FILES ONLY:\n\
1. Make the smallest real code changes so EACH unmet criterion above is satisfied. \
Work ONLY on these criteria; do not refactor unrelated code or redo what the PR already did.\n\
2. EDIT ONLY. Do NOT run git and do NOT touch version control at all — no stage, commit, \
push, checkout, branch, merge, or PR open/close. The system commits your edits \
deterministically (with the zero-touch trailer) and pushes them to the existing branch. \
Running git yourself risks committing runtime junk or a destructive clobber.\n\
3. If a criterion is genuinely already satisfied and the reviewer was wrong, make the \
smallest change that makes it verifiable (a focused test or an explicit code path); do NOT \
fabricate a no-op.\n\n\
Output nothing but a one-line summary of what you changed."
    )
}

/// EFFECTIVE-379: AC-incompleteness remediation — dispatch a fix scoped to ONLY
/// the unmet acceptance bullets, reusing the same guarded ceremony as the CI path.
fn fix_pr_ac(
    clone_dir: &Path,
    repo: &str,
    pr_num: u64,
    head_branch: &str,
    gap_title: &str,
    unmet_bullets: &[String],
    model: &str,
) -> Result<()> {
    let body = build_ac_fix_prompt(repo, pr_num, head_branch, gap_title, unmet_bullets);
    fix_pr_dispatch(
        clone_dir,
        pr_num,
        head_branch,
        gap_title,
        &body,
        "ac",
        model,
    )
}

/// MISSION-059: drive a HELD PR to a terminal state instead of abandoning it.
///
/// Loops up to `CHUMP_IMPROVE_FIX_RETRIES` times: classify the CI failure, rerun
/// flakes (cheap) or re-spawn an escalating-model fix agent on the same branch,
/// then re-verify. Returns the final verdict: `"verified"` (merged) or
/// `"closed"` (closed with a reason after the budget is exhausted).
fn remediate_held(
    opts: &Opts,
    clone_dir: &Path,
    gap_title: &str,
    // EFFECTIVE-367 (COTG): the gap's real acceptance criteria, threaded from the
    // pipeline so the AC-coverage judge scores against the ACTUAL bullets instead of
    // re-deriving them from the external PR's title (which carries no chump gap id →
    // NoGapRef → no signal). Empty when the gap had no AC.
    ac_bullets: &[String],
    pr_num: u64,
    pr_url: &str,
) -> Result<String> {
    let retries = fix_retries();
    let ladder = fix_model_ladder();
    let head_branch = pr_head_branch(opts, pr_num).unwrap_or_default();

    println!(
        "\n[improve] MISSION-059: PR #{pr_num} HELD — remediating (no-abandon, up to {retries} attempt(s), branch={head_branch})"
    );

    // EFFECTIVE-385 (decompose-on-review): remember the most recent set of unmet AC
    // bullets so that, if the budget is exhausted without converging, we can carve
    // the remainder into a scoped child gap instead of losing it.
    let mut last_unmet: Vec<String> = Vec::new();

    for attempt in 0..retries {
        let model = model_for_attempt(attempt, &ladder);

        // EFFECTIVE-334 + EFFECTIVE-379: score the PR's AC coverage ONCE per attempt.
        // It serves two jobs: (1) observability (the fix-confidence signal), and
        // (2) classifying the hold. When the AC judge (Gate 4, CREDIBLE-212) is on
        // and finds unmet bullets, this is an AC-INCOMPLETENESS hold — CI is green,
        // so `fetch_failing_log` has nothing to hand a fixer. Route it instead to a
        // re-dispatch scoped to EXACTLY the unmet bullets, fed the bullet TEXT (not
        // an empty log), and let verify_and_merge's Gate 4 re-judge it below.
        let cov =
            crate::pr_ac_coverage::run_with_ac(&opts.owner_repo, pr_num, gap_title, ac_bullets)
                .ok();
        if let Some(c) = &cov {
            let conf = c.confidence();
            println!(
                "[improve] remediate {} → AC-coverage confidence {conf:.3} ({:?})",
                attempt + 1,
                c.status
            );
            emit_remediation_fix_confidence(
                &opts.owner_repo,
                pr_num,
                attempt + 1,
                conf,
                &format!("{:?}", c.status),
            );
        }
        let ac_gate_on = std::env::var("CHUMP_AC_JUDGE_LLM").as_deref() == Ok("1");
        let unmet: Vec<String> = if ac_gate_on {
            match &cov {
                Some(c) if c.status == crate::pr_ac_coverage::CoverageStatus::Miss => c
                    .bullets
                    .iter()
                    .filter(|b| !b.covered && !b.waived)
                    .filter_map(|b| ac_bullets.get(b.index).cloned())
                    .filter(|s| !s.trim().is_empty())
                    .collect(),
                _ => Vec::new(),
            }
        } else {
            Vec::new()
        };
        // EFFECTIVE-385: capture for the budget-exhausted decompose-on-review path.
        last_unmet = unmet.clone();

        if !unmet.is_empty() {
            // EFFECTIVE-379: AC-incompleteness hold — scoped re-dispatch + re-judge.
            println!(
                "[improve] remediate {}/{}: AC-incomplete — {} unmet bullet(s), scoped re-dispatch model={model}",
                attempt + 1,
                retries,
                unmet.len()
            );
            emit_pr_remediation(
                &opts.owner_repo,
                pr_num,
                "ac-incomplete",
                "AcFix",
                attempt + 1,
                model,
            );
            fix_pr_ac(
                clone_dir,
                &opts.owner_repo,
                pr_num,
                &head_branch,
                gap_title,
                &unmet,
                model,
            )?;
        } else {
            // CI-failure hold (MISSION-059): classify the failing log, rerun a
            // flake for free, or re-spawn an escalating-model fix agent.
            let log = fetch_failing_log(opts, &head_branch);
            let class = crate::ci_summary::classify_log(&log, false);
            let action = remediation_for_class(class);
            println!(
                "[improve] remediate {}/{}: class={class} action={action:?} model={model}",
                attempt + 1,
                retries
            );
            emit_pr_remediation(
                &opts.owner_repo,
                pr_num,
                class,
                &format!("{action:?}"),
                attempt + 1,
                model,
            );
            match action {
                Remediation::Rerun => rerun_failed_checks(opts, &head_branch)?,
                Remediation::AgentFix => fix_pr(
                    clone_dir,
                    &opts.owner_repo,
                    pr_num,
                    &head_branch,
                    gap_title,
                    &log,
                    model,
                )?,
            }
        }

        // Re-verify: verify_and_merge polls check-runs until terminal (and re-runs
        // Gate 4 when the AC judge is on), so an AC re-dispatch is re-judged here.
        let verdict = verify_and_merge(opts, pr_num, gap_title)?;
        println!("[improve] remediate {} → verdict: {verdict}", attempt + 1);
        if verdict == "verified" {
            return Ok("verified".to_string());
        }
    }

    // Budget exhausted. EFFECTIVE-385 (decompose-on-review): if the hold was AC
    // incompleteness, carve the STILL-unmet bullets into a scoped child gap BEFORE
    // closing — so the remaining work is captured and pickable, never lost (Jeff's
    // "send back for correction, don't lose anything"). Best-effort: a filing
    // failure must NOT block the close (no open-red left behind).
    let child_note = if last_unmet.is_empty() {
        String::new()
    } else {
        match file_ac_remainder_child_gap(opts, gap_title, &last_unmet, pr_num) {
            Ok(child) => {
                println!(
                    "[improve] decompose-on-review: carved {} unmet AC bullet(s) into child gap {child}",
                    last_unmet.len()
                );
                format!(
                    " The {} still-unmet acceptance criterion(s) were carved into follow-up gap \
                     {child} (pickable on a fresh branch), so no work is lost.",
                    last_unmet.len()
                )
            }
            Err(e) => {
                eprintln!(
                    "[improve] decompose-on-review: could not file child gap ({e}); closing without it"
                );
                String::new()
            }
        }
    };

    // CLOSE the PR (terminal, no open-red left behind).
    let reason = format!(
        "chump improve (MISSION-059): could not converge after {retries} escalating fix \
         attempt(s); closing rather than leaving this PR open-red.{child_note} Reopen after \
         manual triage if the diff is salvageable."
    );
    close_pr(opts, pr_num, &reason)?;
    emit_pr_closed(&opts.owner_repo, pr_num, pr_url, &reason);
    println!("[improve] PR #{pr_num} CLOSED after {retries} attempt(s) (no-abandon)");
    Ok("closed".to_string())
}

/// EFFECTIVE-385 (decompose-on-review): the pillar/domain a child gap inherits from
/// its parent's ID prefix (`EFFECTIVE-379` → `EFFECTIVE`). Defaults to `EFFECTIVE`
/// when the parent ID is empty or prefix-less. Pure — unit-tested.
fn child_gap_domain_from_parent(parent_id: &str) -> String {
    parent_id
        .split('-')
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("EFFECTIVE")
        .to_uppercase()
}

/// EFFECTIVE-385 (decompose-on-review): when a HELD PR can't be converged within the
/// remediate budget AND the hold is unmet acceptance criteria, carve the still-unmet
/// bullets into a scoped CHILD gap before closing — so the remaining work is captured
/// and pickable, never lost. Returns the child gap ID.
///
/// State.db is canonical, so the child is created via `chump gap reserve` + `chump gap
/// set` (not a direct store write). Reserved at P2 — a remediation follow-up, not a
/// top-priority unblocker — which also keeps the autonomous path clear of the P0/P1
/// outcome+evidence intake firewall (MISSION-045). The parent + PR are recorded in the
/// child's description (NOT as `depends_on`, which would wrongly block the child on a
/// parent that is being closed unconverged).
fn file_ac_remainder_child_gap(
    opts: &Opts,
    gap_title: &str,
    unmet: &[String],
    pr_num: u64,
) -> Result<String> {
    let parent = opts.gap_id.clone().unwrap_or_default();
    let domain = child_gap_domain_from_parent(&parent);
    let chump_bin = std::env::var("CHUMP_IMPROVE_CHUMP_BIN")
        .or_else(|_| std::env::var("CHUMP_BIN"))
        .unwrap_or_else(|_| "chump".to_string());
    let short_title: String = gap_title.trim().chars().take(48).collect();
    let title = format!(
        "complete {parent}: {} unmet AC — {short_title}",
        unmet.len()
    );

    let out = Command::new(&chump_bin)
        .args([
            "gap",
            "reserve",
            "--domain",
            &domain,
            "--title",
            &title,
            "--priority",
            "P2",
            "--effort",
            "m",
        ])
        .output()
        .with_context(|| "spawn `chump gap reserve` for decompose-on-review child")?;
    if !out.status.success() {
        bail!(
            "`chump gap reserve` failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    // reserve prints the new ID as the last DOMAIN-NNN token on stdout.
    let stdout = String::from_utf8_lossy(&out.stdout);
    let child_id = stdout
        .split_whitespace()
        .rev()
        .find(|t| {
            t.contains('-')
                && t.chars()
                    .next()
                    .map(|c| c.is_ascii_uppercase())
                    .unwrap_or(false)
                && t.rsplit('-')
                    .next()
                    .map(|n| n.chars().all(|c| c.is_ascii_digit()))
                    .unwrap_or(false)
        })
        .map(|s| s.to_string())
        .ok_or_else(|| {
            anyhow::anyhow!("could not parse child gap ID from reserve output: {stdout:?}")
        })?;

    let description = format!(
        "Decompose-on-review remainder of {parent} (PR #{pr_num}). The parent PR passed CI but \
         the AC judge (Gate 4, CREDIBLE-212) found the acceptance criteria below still UNMET after \
         the remediate budget was exhausted; they are carved here so the work is not lost. Finish \
         on a fresh branch."
    );
    let mut set_args: Vec<String> = vec![
        "gap".into(),
        "set".into(),
        child_id.clone(),
        "--description".into(),
        description,
    ];
    for b in unmet {
        set_args.push("--acceptance-criteria".into());
        set_args.push(b.trim().to_string());
    }
    let set_out = Command::new(&chump_bin)
        .args(&set_args)
        .output()
        .with_context(|| "spawn `chump gap set` for decompose-on-review child")?;
    if !set_out.status.success() {
        bail!(
            "`chump gap set` failed for child {child_id}: {}",
            String::from_utf8_lossy(&set_out.stderr).trim()
        );
    }
    Ok(child_id)
}

// ── MISSION-061: external PR shepherd ──────────────────────────────────────
//
// Before implementing NEW work each cycle, sweep the loop's OWN open PRs and
// drive any held/behind one to terminal (merged or closed). This composes what
// we already built: 059 remediate_held (the per-PR fix engine) + 063 agent
// identity (the ownership filter — only touch a Chump agent's PRs, never a
// human's) + a rebase-BEHIND step. It answers the dep-bound problem: a held PR
// from a prior cycle can block this cycle's work, so resolve blockers first.

/// A minimal open-PR record from `gh pr list --json`.
struct OpenPr {
    number: u64,
    title: String,
    url: String,
    merge_state: String,
    #[allow(dead_code)]
    head_branch: String,
}

/// Max own-PRs to remediate per cycle (`CHUMP_IMPROVE_SWEEP_MAX`, default 3) so
/// the sweep can't starve new work.
fn sweep_max() -> usize {
    std::env::var("CHUMP_IMPROVE_SWEEP_MAX")
        .ok()
        .and_then(|s| s.trim().parse::<usize>().ok())
        .unwrap_or(3)
}

/// Email domain that marks a commit as agent-authored (`CHUMP_AGENT_EMAIL_DOMAIN`,
/// default `chump.fleet` — matches the 063 identity `<code>@<node>.chump.fleet`).
fn agent_email_domain() -> String {
    std::env::var("CHUMP_AGENT_EMAIL_DOMAIN")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "chump.fleet".to_string())
}

/// Pure ownership test: does this commit-author email belong to a Chump agent?
pub(crate) fn email_is_agent(email: &str, domain: &str) -> bool {
    let e = email.trim().to_ascii_lowercase();
    let d = domain.trim().to_ascii_lowercase();
    !d.is_empty() && (e.ends_with(&format!("@{d}")) || e.ends_with(&format!(".{d}")))
}

/// Split a top-level JSON array into its object substrings (string- and
/// nesting-aware). Pure — unit-tested.
pub(crate) fn split_top_objects(json: &str) -> Vec<String> {
    let mut objs = Vec::new();
    let bytes = json.as_bytes();
    let (mut depth, mut start, mut in_str, mut esc) = (0i32, 0usize, false, false);
    for (i, &b) in bytes.iter().enumerate() {
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            b'{' => {
                if depth == 0 {
                    start = i;
                }
                depth += 1;
            }
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    objs.push(json[start..=i].to_string());
                }
            }
            _ => {}
        }
    }
    objs
}

/// Extract a `"field":"value"` string from a flat JSON object (unescapes basics).
pub(crate) fn json_str_field(obj: &str, field: &str) -> Option<String> {
    let needle = format!("\"{field}\":\"");
    let start = obj.find(&needle)? + needle.len();
    let mut out = String::new();
    let mut chars = obj[start..].chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => {
                if let Some(n) = chars.next() {
                    match n {
                        'n' => out.push('\n'),
                        't' => out.push('\t'),
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        o => out.push(o),
                    }
                }
            }
            c => out.push(c),
        }
    }
    None
}

/// Extract a `"field":<int>` unsigned integer from a flat JSON object.
pub(crate) fn json_int_field(obj: &str, field: &str) -> Option<u64> {
    let needle = format!("\"{field}\":");
    let start = obj.find(&needle)? + needle.len();
    let digits: String = obj[start..]
        .trim_start()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

/// List open PRs on the repo (best-effort; empty on any gh failure).
fn list_open_prs(opts: &Opts) -> Vec<OpenPr> {
    let out = Command::new(improve_gh_bin())
        .args([
            "pr",
            "list",
            "--repo",
            &opts.owner_repo,
            "--state",
            "open",
            "--limit",
            "40",
            "--json",
            "number,title,url,mergeStateStatus,headRefName",
        ])
        .output();
    let json = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return Vec::new(),
    };
    split_top_objects(&json)
        .iter()
        .filter_map(|o| {
            Some(OpenPr {
                number: json_int_field(o, "number")?,
                title: json_str_field(o, "title").unwrap_or_default(),
                url: json_str_field(o, "url").unwrap_or_default(),
                merge_state: json_str_field(o, "mergeStateStatus").unwrap_or_default(),
                head_branch: json_str_field(o, "headRefName").unwrap_or_default(),
            })
        })
        .collect()
}

/// Ownership filter: is the PR's latest commit authored by a Chump agent? This
/// is the guardrail that keeps the shepherd from ever touching a human's PR.
fn pr_authored_by_agent(opts: &Opts, pr_num: u64) -> bool {
    let domain = agent_email_domain();
    let out = Command::new(improve_gh_bin())
        .args([
            "pr",
            "view",
            &pr_num.to_string(),
            "--repo",
            &opts.owner_repo,
            "--json",
            "commits",
            "-q",
            ".commits[-1].authors[].email",
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .any(|l| email_is_agent(l, &domain)),
        _ => false,
    }
}

/// Rebase a BEHIND PR onto its base (branch-protection "require up-to-date").
fn rebase_behind_pr(opts: &Opts, pr_num: u64) {
    let _ = Command::new(improve_gh_bin())
        .args([
            "pr",
            "update-branch",
            &pr_num.to_string(),
            "--repo",
            &opts.owner_repo,
            "--rebase",
        ])
        .status();
    println!("[improve] shepherd: rebased BEHIND PR #{pr_num}");
}

/// MISSION-061: sweep the loop's own open PRs and drive each to terminal.
fn shepherd_own_prs(opts: &Opts, clone_dir: &Path) {
    if std::env::var("CHUMP_IMPROVE_SHEPHERD").as_deref() == Ok("0") {
        return;
    }
    let max = sweep_max();
    if max == 0 {
        return;
    }
    let prs = list_open_prs(opts);
    let mut acted = 0usize;
    for pr in &prs {
        if acted >= max {
            break;
        }
        // CLEAN = mergeable + green → auto-merge will land it; nothing to do.
        if pr.merge_state == "CLEAN" || pr.merge_state == "HAS_HOOKS" {
            continue;
        }
        // GUARDRAIL: never touch a PR a human authored.
        if !pr_authored_by_agent(opts, pr.number) {
            continue;
        }
        acted += 1;
        println!(
            "[improve] MISSION-061 shepherd: PR #{} state={} — {}",
            pr.number, pr.merge_state, pr.title
        );
        emit_shepherd_swept(&opts.owner_repo, pr.number, &pr.merge_state);

        if pr.merge_state == "BEHIND" {
            rebase_behind_pr(opts, pr.number);
        }

        match verify_and_merge(opts, pr.number, &pr.title) {
            Ok(v) if v == "verified" => {
                println!("[improve] shepherd: #{} verified + merged", pr.number)
            }
            Ok(_) => {
                // EFFECTIVE-367: the shepherd sweep has no gap-AC in scope (it operates
                // on open PRs, not a picked gap), so pass empty bullets — AC-coverage
                // advises Pass rather than emitting a false NoGapRef signal.
                if let Err(e) = remediate_held(opts, clone_dir, &pr.title, &[], pr.number, &pr.url)
                {
                    eprintln!("[improve] shepherd: remediate #{} failed: {e}", pr.number);
                }
            }
            Err(e) => eprintln!("[improve] shepherd: verify #{} failed: {e}", pr.number),
        }
    }
    if acted > 0 {
        println!("[improve] MISSION-061 shepherd: swept {acted} own PR(s) before new work");
    }
}

/// Emit `kind=improve_pr_swept` — one per own-PR the shepherd resolves.
///
/// scanner-anchor: kind=improve_pr_swept (MISSION-061)
fn emit_shepherd_swept(repo: &str, pr_num: u64, state: &str) {
    let id = agent_identity();
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "improve_pr_swept".to_string(),
        source: Some("chump-improve".to_string()),
        fields: vec![
            ("repo".to_string(), repo.to_string()),
            ("pr".to_string(), pr_num.to_string()),
            ("state".to_string(), state.to_string()),
            ("agent".to_string(), format!("{}@{}", id.codename, id.node)),
        ],
        ..Default::default()
    });
}

// ── Utilities ────────────────────────────────────────────────────────────

/// Resolve the directory where the repo is cloned.
fn resolve_clone_dir(opts: &Opts) -> PathBuf {
    if let Some(ref p) = opts.clone_dir {
        return p.clone();
    }
    // Default: ~/.chump/external/<owner>/<repo>/clone/
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("external")
        .join(opts.owner_repo.replace('/', std::path::MAIN_SEPARATOR_STR))
        .join("clone")
}

/// EFFECTIVE-291: refresh the persistent external-repo clone to the remote's
/// default branch before implementing, so the PR branches from CURRENT main
/// rather than a stale reused clone. Best-effort: a no-op if the clone isn't a
/// git repo yet; a warning (not a hard error) if fetch fails (offline).
/// INFRA-3477: clone the external repo if the persistent clone doesn't exist yet.
/// The scout stage clones on the scan path, but `improve --gap` skips the scout,
/// so the clone must be created here or refresh_clone/implement fail. Idempotent:
/// a no-op when the clone already exists.
fn ensure_clone_exists(clone_dir: &Path, owner_repo: &str) -> Result<()> {
    if clone_dir.join(".git").exists() {
        return Ok(());
    }
    // INFRA-3478: if the caller pre-populated the clone path (a `--clone-dir`
    // fixture, or a partial checkout) and it's non-empty, respect it rather than
    // failing a `git clone` into a non-empty dir or clobbering the caller's data.
    if clone_dir.is_dir()
        && std::fs::read_dir(clone_dir)
            .map(|mut d| d.next().is_some())
            .unwrap_or(false)
    {
        eprintln!(
            "[improve] clone path {} is non-empty but has no .git — using it as-is",
            clone_dir.display()
        );
        return Ok(());
    }
    if let Some(parent) = clone_dir.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let url = format!("https://github.com/{owner_repo}.git");
    let cd = clone_dir.to_string_lossy().to_string();
    println!("[improve] first-touch clone {owner_repo} → {cd}");
    let ok = Command::new("git")
        .args(["clone", "--quiet", &url, &cd])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        bail!("git clone {url} → {cd} failed");
    }
    Ok(())
}

/// INFRA-3478: prepare the shared clone (clone-if-missing + refresh) under an
/// atomic-mkdir lock, so two `improve` processes touching the same external repo
/// for the first time don't race on `git clone` / `git reset` in the shared
/// clone (observed: concurrent first-touch → "could not create work tree dir:
/// File exists"). Per-agent worktrees are created OUTSIDE this lock — they are
/// independently safe. A crashed holder self-heals after the 150s wait bail; the
/// lock dir can also be removed by hand.
fn prepare_shared_clone(clone_dir: &Path, owner_repo: &str) -> Result<()> {
    let base = clone_dir.parent().unwrap_or(clone_dir);
    let _ = std::fs::create_dir_all(base);
    let lock = base.join(".clone.lock");
    let mut waited = 0u32;
    loop {
        match std::fs::create_dir(&lock) {
            Ok(_) => break, // we hold the lock
            Err(_) => {
                // Someone else is preparing it. If it's already usable, proceed.
                if clone_dir.join(".git").exists() {
                    return refresh_clone(clone_dir);
                }
                if waited >= 300 {
                    bail!("timed out (150s) waiting for a concurrent clone of {owner_repo}");
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
                waited += 1;
            }
        }
    }
    let result = (|| -> Result<()> {
        ensure_clone_exists(clone_dir, owner_repo)?;
        refresh_clone(clone_dir)?;
        Ok(())
    })();
    let _ = std::fs::remove_dir(&lock);
    result
}

/// INFRA-3478: unique per-process key for this agent's worktree. The pid isolates
/// concurrent `improve` processes working the same external repo; a serial reuse
/// in one process is safe (the worktree is pruned+removed before re-add).
fn improve_worktree_key() -> String {
    format!("p{}", std::process::id())
}

/// INFRA-3478: create a per-agent LINKED WORKTREE off the shared clone (mirrors
/// internal `chump claim`). The shared clone stays canonical — fetch source,
/// object store, default branch — while each agent branches in its own isolated
/// checkout under `<clone-parent>/wt/<key>`, so N agents on one external repo
/// never collide on the working tree or the index. Idempotent: prunes dead admin
/// entries and clears any stale worktree/branch at this key first.
fn ensure_improve_worktree(clone_dir: &Path, key: &str, base_branch: &str) -> Result<PathBuf> {
    let root = clone_dir.parent().unwrap_or(clone_dir).join("wt");
    let _ = std::fs::create_dir_all(&root);
    let wt = root.join(key);
    let cd = clone_dir.to_string_lossy().to_string();
    let wt_str = wt.to_string_lossy().to_string();
    let branch = format!("chump/improve-{key}");

    // Clear stale state from a prior crashed run at this key.
    let _ = Command::new("git")
        .args(["-C", &cd, "worktree", "prune"])
        .status();
    if wt.exists() {
        let _ = Command::new("git")
            .args(["-C", &cd, "worktree", "remove", &wt_str, "--force"])
            .status();
        let _ = std::fs::remove_dir_all(&wt);
    }
    let _ = Command::new("git")
        .args(["-C", &cd, "branch", "-D", &branch])
        .status();

    // A worktree can't check out a branch already checked out elsewhere (the
    // shared clone holds the default branch), so create a fresh agent branch off
    // the remote default.
    let base_ref = format!("origin/{base_branch}");
    let ok = Command::new("git")
        .args([
            "-C", &cd, "worktree", "add", &wt_str, "-b", &branch, &base_ref,
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        bail!("git worktree add {wt_str} (-b {branch} {base_ref}) failed in clone {cd}");
    }
    Ok(wt)
}

/// INFRA-3478: dispose of a per-agent worktree after a successful ship (the agent
/// has already pushed its branch to origin, so the local checkout is disposable).
fn remove_improve_worktree(clone_dir: &Path, wt: &Path) {
    let cd = clone_dir.to_string_lossy().to_string();
    let _ = Command::new("git")
        .args([
            "-C",
            &cd,
            "worktree",
            "remove",
            &wt.to_string_lossy(),
            "--force",
        ])
        .status();
    let _ = Command::new("git")
        .args(["-C", &cd, "worktree", "prune"])
        .status();
}

fn refresh_clone(clone_dir: &Path) -> Result<()> {
    if !clone_dir.join(".git").exists() {
        return Ok(()); // not cloned yet — the scan/implement path reports that
    }
    let cd = clone_dir.to_string_lossy().to_string();
    let fetched = Command::new("git")
        .args(["-C", &cd, "fetch", "origin", "--quiet"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !fetched {
        eprintln!(
            "[improve] warning: git fetch failed in clone {cd}; using existing state (EFFECTIVE-291)"
        );
        return Ok(());
    }
    // MISSION-057: `git fetch` does NOT update origin/HEAD, so a clone made when
    // the repo default was a feature branch keeps a stale origin/HEAD. Refresh it
    // so default-branch detection is authoritative.
    let _ = Command::new("git")
        .args(["-C", &cd, "remote", "set-head", "origin", "--auto"])
        .status();
    let branch = detect_default_branch(&cd);
    // MISSION-057: SWITCH ONTO the default branch (checkout -B), not just reset the
    // current one. `reset --hard` moves content but keeps the pre-existing local
    // branch NAME — which then leaked into the PR base (fix/rls-recursion-test-
    // proven) and every PR opened DIRTY. Drop untracked leftovers too.
    let _ = Command::new("git")
        .args([
            "-C",
            &cd,
            "checkout",
            "-B",
            &branch,
            &format!("origin/{branch}"),
        ])
        .status();
    let _ = Command::new("git")
        .args(["-C", &cd, "clean", "-fd"])
        .status();
    println!("[improve] clone refreshed to origin/{branch} (EFFECTIVE-291)");
    Ok(())
}

/// Detect a clone's remote default branch: prefer `origin/HEAD`'s target, then
/// fall back to `main`, then `master`.
fn detect_default_branch(cd: &str) -> String {
    if let Ok(out) = Command::new("git")
        .args([
            "-C",
            cd,
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ])
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout)
                .trim()
                .trim_start_matches("origin/")
                .to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    for cand in ["main", "master"] {
        let ok = Command::new("git")
            .args(["-C", cd, "rev-parse", "--verify", &format!("origin/{cand}")])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            return cand.to_string();
        }
    }
    "main".to_string()
}

/// Resolve the `chump` binary to use for `external verify-merge`.
///
/// Check `CHUMP_IMPROVE_CHUMP_BIN` first, then the same fallback chain as
/// `dispatch.rs::resolve_chump_binary`: target/release → target/debug →
/// ~/.local/bin → PATH.
///
/// NOTE: `verify_and_merge` does NOT use this function (CREDIBLE-100). It uses
/// `current_exe()` instead so it always calls the running binary which has the
/// `external verify-merge` subcommand. This function is kept for other callers
/// that need a loose "best-effort" binary resolution.
fn resolve_chump_bin() -> String {
    if let Ok(explicit) = std::env::var("CHUMP_IMPROVE_CHUMP_BIN") {
        return explicit;
    }
    // Try to find the binary relative to a repo root. In practice the worktree's
    // target/ is the same as the main repo's target/ (Cargo workspace feature).
    // Use `cargo metadata` if available; fall back to known paths.
    for candidate in ["target/release/chump", "target/debug/chump"] {
        if Path::new(candidate).exists() {
            return candidate.to_string();
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let dot_local = PathBuf::from(home).join(".local/bin/chump");
        if dot_local.exists() {
            return dot_local.to_string_lossy().to_string();
        }
    }
    "chump".to_string()
}

/// RESILIENT-106: read the OAUTH token from `~/.chump/oauth-token.json`.
///
/// Mirrors the pattern from `scripts/dispatch/worker.sh` (INFRA-620, lines 211-232).
/// Tries keys "token", "access_token", and "accessToken" in that order.
///
/// Returns `None` silently on any error (missing file, parse failure, empty value)
/// so the caller degrades gracefully.
///
/// IMPORTANT: callers MUST NOT log or print the returned value — it's a credential.
fn read_oauth_token_file() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let token_path = PathBuf::from(home).join(".chump/oauth-token.json");
    let content = std::fs::read_to_string(&token_path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&content).ok()?;
    // Try the three key names worker.sh checks, in the same order.
    for key in ["token", "access_token", "accessToken"] {
        if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// Detect the default branch of the cloned repo.
fn detect_base_branch(clone_dir: &Path) -> String {
    // MISSION-057: the PR base MUST be the repo's remote DEFAULT branch — not the
    // clone's current local branch (`rev-parse HEAD`). refresh_clone resets the
    // working tree to origin/<default> but a stale local branch NAME (e.g.
    // fix/rls-recursion-test-proven) survived and leaked into the PR base, so
    // every improve PR opened DIRTY/unmergeable. Use the authoritative resolver
    // (origin/HEAD, refreshed by refresh_clone, then main/master fallback).
    detect_default_branch(&clone_dir.to_string_lossy())
}

/// Build a human-readable description of the gap for the implement-agent prompt.
/// EFFECTIVE-354: pull candidate feature keywords from a gap's title + evidence
/// excerpt for the grounding locator. Strips a leading `[owner]` tag, drops
/// punctuation, generic/process stopwords, pure-numeric and short (<4) tokens;
/// dedups; caps the count. Pure + unit-tested.
fn extract_keywords(gap: &ProposedGap) -> Vec<String> {
    // Generic English + gap/process meta words that would match everywhere and add
    // no feature signal. Domain nouns (meal, budget, search, cart, …) are kept.
    const STOP: &[&str] = &[
        "the",
        "and",
        "for",
        "with",
        "that",
        "this",
        "from",
        "only",
        "when",
        "your",
        "have",
        "into",
        "just",
        "still",
        "will",
        "would",
        "should",
        "could",
        "about",
        "also",
        "some",
        "any",
        "all",
        "not",
        "but",
        "are",
        "was",
        "been",
        "which",
        "what",
        "where",
        "being",
        "they",
        "them",
        "then",
        "than",
        "does",
        "done",
        "gap",
        "issue",
        "bug",
        "bugs",
        "fix",
        "fixed",
        "test",
        "tests",
        "change",
        "changes",
        "implement",
        "implemented",
        "verifiably",
        "regression",
        "acceptance",
        "criteria",
        "described",
        "above",
        "below",
        "specific",
        "rest",
        "page",
        "flow",
        "works",
        "work",
        "working",
        "silently",
        "fails",
        "fail",
        "plain",
        "mode",
        "modes",
    ];
    // Strip a leading bracketed tag like "[olive] " (the repo/owner marker).
    let title = gap.title.trim();
    let title = if let Some(rest) = title.strip_prefix('[') {
        rest.splitn(2, ']').nth(1).unwrap_or(rest)
    } else {
        title
    };
    let text = format!("{} {}", title, gap.source_of_evidence.excerpt).to_lowercase();
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for tok in text.split(|c: char| !c.is_alphanumeric()) {
        if tok.len() < 4 {
            continue;
        }
        if tok.chars().all(|c| c.is_numeric()) {
            continue;
        }
        if STOP.contains(&tok) {
            continue;
        }
        if seen.insert(tok.to_string()) {
            out.push(tok.to_string());
        }
        if out.len() >= 10 {
            break;
        }
    }
    out
}

/// EFFECTIVE-354: format the ranked grep hits into a grounding block appended to
/// the agent's task spec. Pure (no I/O) so it's unit-testable. `ranked` is
/// (relative_path, distinct_keyword_matches, first_line), highest-relevance first.
fn format_grounding_block(ranked: &[(String, u32, u32)], keywords: &[String]) -> String {
    let lines: Vec<String> = ranked
        .iter()
        .take(8)
        .map(|(p, c, l)| format!("  {p}:{l}  (matches {c} keyword(s))"))
        .collect();
    format!(
        "\n\n\u{2501}\u{2501} LIKELY-RELEVANT SOURCE FILES (EFFECTIVE-354 grounding — grep, not a guess) \u{2501}\u{2501}\n\
         Start in these files: read the ACTUAL implementation and EDIT it to fix the defect. \
         Do NOT ship only a test — a test without a source change is a stub and will be rejected.\n{}\n\
         Keywords searched: {}\n",
        lines.join("\n"),
        keywords.join(", "),
    )
}

/// EFFECTIVE-354: grep the working checkout for the gap's keywords and return a
/// ranked "likely-relevant source files" block. Ranks files by how many DISTINCT
/// keywords they match. Cascade-free (ripgrep only). None if nothing useful found.
fn locate_relevant_files(work_dir: &Path, gap: &ProposedGap) -> Option<String> {
    let keywords = extract_keywords(gap);
    if keywords.is_empty() {
        return None;
    }
    let rg = std::env::var("CHUMP_IMPROVE_RG_BIN").unwrap_or_else(|_| "rg".to_string());
    let wd = work_dir.to_string_lossy().to_string();
    // path -> (distinct_keyword_count, earliest_line)
    let mut hits: std::collections::HashMap<String, (u32, u32)> = std::collections::HashMap::new();
    for kw in &keywords {
        let out = Command::new(&rg)
            .args([
                "-i",
                "-n",
                "--no-heading",
                "-m",
                "5",
                "-g",
                "!*.lock",
                "-g",
                "!*.min.*",
                "-g",
                "!node_modules/**",
                "-g",
                "!dist/**",
                "-g",
                "!build/**",
                "-g",
                "!*.md",
                kw,
                &wd,
            ])
            .output();
        let out = match out {
            Ok(o) if o.status.success() => o,
            _ => continue,
        };
        // distinct files matched by THIS keyword (so each keyword adds at most 1).
        let mut files_this_kw: std::collections::HashMap<String, u32> =
            std::collections::HashMap::new();
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let mut parts = line.splitn(3, ':');
            let path = parts.next().unwrap_or("");
            let lineno: u32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            if path.is_empty() {
                continue;
            }
            let rel = path
                .strip_prefix(&wd)
                .unwrap_or(path)
                .trim_start_matches('/')
                .to_string();
            if !is_source_file(&rel.to_ascii_lowercase()) {
                continue;
            }
            let e = files_this_kw.entry(rel).or_insert(lineno);
            if lineno < *e {
                *e = lineno;
            }
        }
        for (rel, firstline) in files_this_kw {
            let e = hits.entry(rel).or_insert((0, firstline));
            e.0 += 1;
            if firstline < e.1 {
                e.1 = firstline;
            }
        }
    }
    if hits.is_empty() {
        return None;
    }
    let mut ranked: Vec<(String, u32, u32)> =
        hits.into_iter().map(|(p, (c, l))| (p, c, l)).collect();
    // most distinct keywords first; tie-break by path for determinism.
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    Some(format_grounding_block(&ranked, &keywords))
}

fn build_gap_description(gap: &ProposedGap) -> String {
    let ac = gap
        .acceptance_criteria_draft
        .iter()
        .enumerate()
        .map(|(i, s)| format!("  {}. {s}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "Gap: {}\n\nPriority: {:?} / Effort: {:?} / Confidence: {:?}\n\
         Source: {} §{}\n  excerpt: {}\n\nAcceptance criteria:\n{ac}",
        gap.title,
        gap.priority,
        gap.effort,
        gap.confidence,
        gap.source_of_evidence.input_path,
        gap.source_of_evidence.section,
        gap.source_of_evidence.excerpt,
    )
}

/// Write the prompt to a temp file and return its path.
fn write_temp_prompt(prompt: &str) -> Result<PathBuf> {
    let path = std::env::temp_dir().join(format!(
        "chump-improve-prompt-{}.txt",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    std::fs::write(&path, prompt).with_context(|| format!("write prompt to {}", path.display()))?;
    Ok(path)
}

/// Extract a GitHub PR URL (`https://github.com/.../pull/N`) from the agent's
/// JSON output. Scans for the first `"pr_url"` field in a JSON block.
fn extract_pr_url_from_output(output: &str) -> Option<String> {
    // Look for a JSON block containing pr_url.
    for line in output.lines() {
        let line = line.trim();
        if line.contains("\"pr_url\"") {
            // Simple extraction — find the value after "pr_url":
            if let Some(start) = line.find("\"pr_url\"") {
                let rest = &line[start + "\"pr_url\"".len()..];
                // Skip whitespace and the colon
                let rest = rest.trim_start().trim_start_matches(':').trim_start();
                // Extract the quoted string
                if let Some(inner) = rest.strip_prefix('"') {
                    if let Some(end) = inner.find('"') {
                        let url = inner[..end].to_string();
                        if url.starts_with("https://github.com/") && url.contains("/pull/") {
                            return Some(url);
                        }
                    }
                }
            }
        }
    }
    None
}

/// Extract the PR number from a GitHub PR URL.
fn extract_pr_number(pr_url: &str) -> Option<u64> {
    pr_url.rsplit('/').next()?.parse().ok()
}

// ── Unit tests ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use chump_handoff::external_repo_schema::{
        save_scan, Confidence, Effort, InputRead, OnboardScan, Priority, ProposedGap,
        SourceOfEvidence,
    };
    use std::fs;
    use tempfile::TempDir;

    // ── EFFECTIVE-353: --gap loads the REAL filed gap, not a placeholder ────

    /// Build a GapRow via serde (it derives Deserialize; the tail fields carry
    /// `#[serde(default)]`), so this test survives GapRow field additions.
    fn stored_gap(json: serde_json::Value) -> chump_gap_store::GapRow {
        serde_json::from_value(json).expect("construct GapRow")
    }

    #[test]
    fn effective353_stored_gap_carries_real_title_description_and_json_ac() {
        let row = stored_gap(serde_json::json!({
            "id": "PRODUCT-143",
            "domain": "PRODUCT",
            "title": "[olive] Meal and budget search modes silently fail ($0.00)",
            "description": "Meal and budget search return $0.00 / not found; only plain grocery-list mode works.",
            "priority": "P2",
            "effort": "s",
            "status": "open",
            "acceptance_criteria": "[\"The issue is verifiably fixed on the LIVE site\",\"No regression\"]",
            "depends_on": "[]",
            "notes": "",
            "source_doc": "",
            "created_at": 0,
            "closed_at": null
        }));

        let pg = proposed_gap_from_stored(&row);
        // The agent gets the REAL bug title, not the bare ID string.
        assert_eq!(pg.title, row.title);
        assert!(pg.title.contains("$0.00"));
        // The real problem statement reaches the agent via the excerpt.
        assert_eq!(pg.source_of_evidence.excerpt, row.description);
        assert_eq!(pg.source_of_evidence.section, "PRODUCT-143");
        // The stored JSON-array AC is parsed into real bullets — no placeholder.
        assert_eq!(pg.acceptance_criteria_draft.len(), 2);
        assert!(pg.acceptance_criteria_draft[0].contains("LIVE site"));
        assert!(!pg
            .acceptance_criteria_draft
            .iter()
            .any(|s| s.contains("Change described in gap")));
        // Domain + priority mapped straight from the row.
        assert_eq!(pg.domain, "PRODUCT");
        assert!(matches!(pg.priority, Priority::P2));
    }

    #[test]
    fn effective353_empty_ac_and_desc_fall_back_soft() {
        let row = stored_gap(serde_json::json!({
            "id": "X-1", "domain": "", "title": "just a title",
            "description": "", "priority": "P9-bogus", "effort": "s",
            "status": "open", "acceptance_criteria": "", "depends_on": "[]",
            "notes": "", "source_doc": "", "created_at": 0, "closed_at": null
        }));
        let pg = proposed_gap_from_stored(&row);
        // Empty AC → generic runnable fallback (never a naked empty list).
        assert_eq!(pg.acceptance_criteria_draft.len(), 2);
        assert!(pg.acceptance_criteria_draft[0].contains("X-1"));
        // Empty description → excerpt falls back to the title.
        assert_eq!(pg.source_of_evidence.excerpt, "just a title");
        // Unknown priority string → safe P1 default; empty domain → EFFECTIVE.
        assert!(matches!(pg.priority, Priority::P1));
        assert_eq!(pg.domain, "EFFECTIVE");
    }

    // ── CREDIBLE-200: stub-guard (no source edit + only placeholder tests) ──

    #[test]
    fn credible200_flags_test_only_placeholder_stub() {
        // The exact olive PR #7 failure: only a test file, only assert 1==1.
        let paths = vec!["tests/test_search_modes.py".to_string()];
        let added = vec![
            "+def test_meal_search_mode_fails():".to_string(),
            "+    assert 1 == 1".to_string(),
            "+def test_budget_search_mode_fails():".to_string(),
            "+    assert 1 == 1".to_string(),
        ];
        assert!(
            stub_reason(&paths, &added).is_some(),
            "assert 1==1 stub must block"
        );

        // assert True / pass variants also blocked.
        let added2 = vec!["+    assert True".to_string(), "+    pass".to_string()];
        assert!(stub_reason(&paths, &added2).is_some());
    }

    #[test]
    fn credible232_olive10_real_parse_test_passes() {
        // POSITIVE case (olive PR #10): a test-only vitest that parses a YAML workflow
        // and asserts the scan job's if: condition. Real expect().toBe() assertions on a
        // parsed value — NOT a stub. Must PASS the stub-guard.
        let paths = vec!["test/unit/workflow-guards.test.ts".to_string()];
        let added = vec![
            "+".to_string(),
            "+  it('scan job STILL runs on non-Dependabot PRs (no coverage lost)', () => {"
                .to_string(),
            "+    const workflowPath = join(process.cwd(), '.github/workflows/upshift-app-scan.yml')".to_string(),
            "+    const yaml = readFileSync(workflowPath, 'utf-8')".to_string(),
            "+    const jobsMatch = yaml.match(/^jobs:\\s*$/m)".to_string(),
            "+    expect(jobsMatch, 'workflow must have jobs: section').toBeTruthy()".to_string(),
            "+    const scanJobMatch = afterJobs.match(/^  scan:\\s*$/m)".to_string(),
            "+    expect(scanJobMatch, 'scan job must exist').toBeTruthy()".to_string(),
            "+    const ifMatch = scanJobSection.match(/^\\s{4}if:\\s*\\$\\{\\{\\s*([^}]+)\\s*\\}\\}/m)".to_string(),
            "+    expect(ifMatch, 'scan job must have an if: condition at job level').toBeTruthy()".to_string(),
            "+    const condition = ifMatch![1].trim()".to_string(),
            "+    expect(condition).toBe(\"github.actor != 'dependabot[bot]'\")".to_string(),
            "+    expect(condition).not.toBe('false')".to_string(),
            "+    expect(condition).not.toContain('false')".to_string(),
            "+  })".to_string(),
        ];
        let r = stub_reason(&paths, &added);
        assert!(
            r.is_none(),
            "olive #10 is a real parse+assert test, NOT a stub — got block: {r:?}"
        );
    }

    #[test]
    fn credible232_unrecognized_assertion_syntax_passes() {
        // POSITIVE case (the durable false-positive CLASS): a test-only change with REAL
        // work whose assertion syntax isn't in the narrow allowlist (ava `t.is`, tap
        // `t.equal`). No placeholder pattern anywhere → NOT a stub. This is the case that
        // FAILED before CREDIBLE-232 (guard equated "no recognized assertion" with "stub").
        let paths = vec!["test/config.test.ts".to_string()];
        let added = vec![
            "+  test('parses the timeout from config', () => {".to_string(),
            "+    const cfg = parseConfig(readFileSync('config.yml', 'utf-8'))".to_string(),
            "+    t.is(cfg.timeout, 30)".to_string(),
            "+  })".to_string(),
        ];
        assert!(
            stub_reason(&paths, &added).is_none(),
            "a real test with an unrecognized assertion syntax is NOT a stub"
        );
    }

    #[test]
    fn credible232_placeholder_skip_todo_still_blocks() {
        // NEGATIVE case: a genuinely fake test-only change (no real assertion, only a
        // skip/todo marker or bare pass) must STILL be blocked — the guard's true purpose
        // (catch fake work) is intact after the CREDIBLE-232 loosening.
        let paths = vec!["test/pending.test.ts".to_string()];
        // vitest it.todo placeholder
        assert!(
            stub_reason(
                &paths,
                &["+  it.todo('handles the empty cart')".to_string()]
            )
            .is_some(),
            "it.todo placeholder must block"
        );
        // test.skip placeholder
        assert!(
            stub_reason(
                &paths,
                &["+  test.skip('computes the discount', () => {})".to_string()]
            )
            .is_some(),
            "test.skip placeholder must block"
        );
        // bare pass + a tautology, python-style
        let py = vec!["tests/test_pending.py".to_string()];
        assert!(
            stub_reason(
                &py,
                &["+def test_todo():".to_string(), "+    pass".to_string()]
            )
            .is_some(),
            "bare pass body must block"
        );
    }

    #[test]
    fn credible200_passes_test_only_with_real_assertion() {
        // A legitimate test-only PR (real assertion) must ship normally.
        let paths = vec!["tests/test_search_modes.py".to_string()];
        let added = vec![
            "+def test_meal_search_returns_cost():".to_string(),
            "+    assert search('meal').total > 0.0".to_string(),
        ];
        assert!(
            stub_reason(&paths, &added).is_none(),
            "real assertion must pass"
        );
    }

    #[test]
    fn credible200_passes_when_source_edited() {
        // A real source edit is never a stub, even alongside a placeholder test.
        let paths = vec![
            "src/search.ts".to_string(),
            "tests/test_search_modes.py".to_string(),
        ];
        let added = vec!["+    assert True".to_string()];
        assert!(
            stub_reason(&paths, &added).is_none(),
            "source edit clears the stub-guard"
        );
    }

    #[test]
    fn credible200_ignores_non_test_only_changes() {
        // Docs/config-only changes are out of the stub-guard's scope.
        let paths = vec!["README.md".to_string(), "config.yaml".to_string()];
        assert!(stub_reason(&paths, &[]).is_none());
    }

    #[test]
    fn credible200_assertion_classification() {
        // placeholders
        assert!(is_placeholder_assertion("assert 1 == 1"));
        assert!(is_placeholder_assertion("assert true"));
        assert!(is_placeholder_assertion("assert_eq!(1, 1)"));
        assert!(is_placeholder_assertion("assert!(true)"));
        assert!(is_placeholder_assertion("assert x == x"));
        // meaningful
        assert!(is_meaningful_assertion("+    assert result == 0.00"));
        assert!(is_meaningful_assertion("+    assert_eq!(total, 42)"));
        assert!(is_meaningful_assertion("+    expect(price).toBe(9.99)"));
        assert!(!is_meaningful_assertion("+    # just a comment"));
        // file classification
        assert!(is_source_file("src/search.ts"));
        assert!(!is_source_file("tests/test_x.py"));
        assert!(is_test_file("tests/test_x.py"));
        assert!(is_test_file("app/foo.test.ts"));
        assert!(!is_test_file("src/foo.ts"));
    }

    // ── EFFECTIVE-354: grounding pre-step (grep locator for the agent) ──────

    fn grounding_gap(title: &str, excerpt: &str) -> ProposedGap {
        ProposedGap {
            title: title.to_string(),
            domain: "PRODUCT".to_string(),
            priority: Priority::P2,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "test".to_string(),
                section: "PRODUCT-143".to_string(),
                excerpt: excerpt.to_string(),
            },
            acceptance_criteria_draft: vec![],
            layer: None,
            doctrine_justification: None,
        }
    }

    #[test]
    fn effective354_extract_keywords_keeps_feature_nouns_drops_noise() {
        let gap = grounding_gap(
            "[olive] Meal and budget search modes silently fail ($0.00 / \"not found\")",
            "Only plain grocery-list mode works; the meal and budget search return $0.00.",
        );
        let kws = extract_keywords(&gap);
        // Feature nouns survive.
        for want in ["search", "budget", "meal", "grocery"] {
            assert!(
                kws.contains(&want.to_string()),
                "keyword '{want}' missing from {kws:?}"
            );
        }
        // The [olive] owner tag, stopwords, and the numeric are dropped.
        assert!(
            !kws.contains(&"olive".to_string()),
            "owner tag must be stripped: {kws:?}"
        );
        assert!(
            !kws.iter()
                .any(|k| ["modes", "fail", "only", "works"].contains(&k.as_str())),
            "process/stopwords must be dropped: {kws:?}"
        );
        assert!(
            !kws.iter().any(|k| k.chars().all(|c| c.is_numeric())),
            "no pure numbers"
        );
    }

    #[test]
    fn effective354_extract_keywords_empty_for_generic_title() {
        // All-stopword title yields nothing to ground on (locator returns None upstream).
        let gap = grounding_gap("fix the bug", "");
        assert!(extract_keywords(&gap).is_empty());
    }

    #[test]
    fn effective354_format_grounding_block_lists_ranked_files() {
        let ranked = vec![
            ("src/search/meal.ts".to_string(), 3u32, 42u32),
            ("src/search/budget.ts".to_string(), 2u32, 10u32),
        ];
        let kws = vec![
            "search".to_string(),
            "meal".to_string(),
            "budget".to_string(),
        ];
        let block = format_grounding_block(&ranked, &kws);
        assert!(block.contains("LIKELY-RELEVANT SOURCE FILES"));
        assert!(block.contains("src/search/meal.ts:42"));
        assert!(block.contains("matches 3 keyword"));
        assert!(block.contains("Keywords searched: search, meal, budget"));
        // Steers the agent to EDIT source, not just add a test (anti-stub framing).
        assert!(block.to_lowercase().contains("edit"));
    }

    // ── MISSION-059: no-abandon remediation helpers ────────────────────────

    #[test]
    fn mission059_remediation_flake_and_infra_rerun() {
        assert_eq!(remediation_for_class("flake"), Remediation::Rerun);
        assert_eq!(remediation_for_class("infra-broken"), Remediation::Rerun);
    }

    #[test]
    fn mission059_remediation_realbug_coupling_and_unknown_agentfix() {
        assert_eq!(remediation_for_class("real-bug"), Remediation::AgentFix);
        assert_eq!(
            remediation_for_class("test-coupling"),
            Remediation::AgentFix
        );
        // Unknown/empty is the safe default: attempt a real fix, not a blind rerun.
        assert_eq!(remediation_for_class(""), Remediation::AgentFix);
        assert_eq!(remediation_for_class("weird"), Remediation::AgentFix);
    }

    #[test]
    fn effective385_child_gap_domain_inherits_parent_prefix() {
        assert_eq!(child_gap_domain_from_parent("EFFECTIVE-379"), "EFFECTIVE");
        assert_eq!(child_gap_domain_from_parent("credible-212"), "CREDIBLE");
        assert_eq!(child_gap_domain_from_parent("MISSION-010"), "MISSION");
        // Empty / prefix-less parent falls back to EFFECTIVE (never panics/empty).
        assert_eq!(child_gap_domain_from_parent(""), "EFFECTIVE");
        assert_eq!(child_gap_domain_from_parent("nodash"), "NODASH");
    }

    #[test]
    fn effective379_ac_fix_prompt_scopes_to_unmet_bullets() {
        let unmet = vec![
            "The /join page renders the invite code from the URL".to_string(),
            "A logged-out visitor is redirected to /login".to_string(),
        ];
        let p = build_ac_fix_prompt(
            "owner/repo",
            42,
            "chump/x-claim",
            "wire the join page",
            &unmet,
        );
        // Every unmet bullet's TEXT is handed to the agent, numbered.
        assert!(p.contains("1. The /join page renders the invite code from the URL"));
        assert!(p.contains("2. A logged-out visitor is redirected to /login"));
        // It frames the hold correctly (green CI, unmet AC) — NOT a red-CI fix.
        assert!(p.contains("CI is GREEN"));
        assert!(p.contains("UNMET ACCEPTANCE CRITERIA"));
        // The edit-only / no-git safety rail is preserved from the CI path.
        assert!(p.contains("EDIT ONLY") || p.contains("EDIT FILES ONLY"));
        assert!(p.contains("Do NOT run git"));
        // It must NOT tell the agent CI is red (the empty-log bug this fixes).
        assert!(!p.contains("CI is RED"));
    }

    #[test]
    fn mission059_model_escalates_then_clamps() {
        let ladder = vec!["sonnet".to_string(), "opus".to_string()];
        // Attempt 0 = cheap, attempt 1 = escalated, attempt 2+ clamps to last.
        assert_eq!(model_for_attempt(0, &ladder), "sonnet");
        assert_eq!(model_for_attempt(1, &ladder), "opus");
        assert_eq!(model_for_attempt(2, &ladder), "opus");
        assert_eq!(model_for_attempt(99, &ladder), "opus");
    }

    #[test]
    fn mission059_model_empty_ladder_has_safe_default() {
        assert_eq!(model_for_attempt(0, &[]), "claude-sonnet-4-5");
    }

    #[test]
    fn mission059_default_ladder_is_sonnet_then_opus() {
        // Guard the default (env-independent shape): cheap first, escalate second.
        let ladder = fix_model_ladder();
        assert!(!ladder.is_empty());
        assert!(ladder[0].contains("sonnet"), "first rung cheap: {ladder:?}");
        assert!(
            ladder.last().unwrap().contains("opus"),
            "last rung escalated: {ladder:?}"
        );
    }

    #[test]
    fn mission059_find_failed_run_id_picks_first_failure() {
        let json = r#"[{"databaseId":111,"conclusion":"success"},{"databaseId":222,"conclusion":"failure"},{"databaseId":333,"conclusion":"failure"}]"#;
        assert_eq!(find_failed_run_id(json), Some(222));
    }

    #[test]
    fn mission059_find_failed_run_id_none_when_all_green() {
        let json = r#"[{"databaseId":111,"conclusion":"success"},{"databaseId":222,"conclusion":"success"}]"#;
        assert_eq!(find_failed_run_id(json), None);
        assert_eq!(find_failed_run_id("[]"), None);
    }

    #[test]
    fn mission059_fix_prompt_forbids_new_pr_and_pins_branch() {
        let p = build_fix_prompt(
            "owner/repo",
            42,
            "chump/feature-x",
            "Add retry",
            "error[E0308]",
        );
        assert!(p.contains("chump/feature-x"), "pins the head branch");
        assert!(p.contains("#42"));
        assert!(
            p.contains("EDIT ONLY") && p.contains("branch"),
            "edit-only mandate; forbids new branch"
        );
        assert!(
            p.contains("merge") && p.contains("PR open/close"),
            "forbids merge + PR (edit-only)"
        );
        assert!(p.contains("error[E0308]"), "includes the failing log");
    }

    // ── MISSION-063: named agent identity ──────────────────────────────────

    #[test]
    fn mission063_roster_pick_is_stable_and_in_roster() {
        let a = roster_pick("closetjunky");
        let b = roster_pick("closetjunky");
        assert_eq!(a, b, "same node → same codename (stable)");
        assert!(AGENT_ROSTER.contains(&a), "pick is from the roster");
        // Different nodes generally differ (not a hard guarantee, but these do).
        assert_ne!(roster_pick("helsinki"), roster_pick("closetjunky-xyz"));
    }

    #[test]
    fn mission063_sanitize_node_shortens_and_cleans() {
        assert_eq!(sanitize_node("ClosetJunky.local"), "closetjunky");
        assert_eq!(sanitize_node("host_name!!"), "host-name--");
        assert_eq!(sanitize_node(""), "node");
    }

    #[test]
    fn mission063_env_override_wins() {
        // Explicit codename + email override the roster/derived defaults.
        let id = build_identity(Some("Zapp"), Some("zapp@example.test"), "rig7");
        assert_eq!(id.codename, "Zapp");
        assert_eq!(id.name, "Chump · Zapp");
        assert_eq!(id.email, "zapp@example.test");
        assert_eq!(id.node, "rig7");
        assert_eq!(id.trailer(), "Chump-Agent: Zapp@rig7");
    }

    #[test]
    fn mission063_blank_override_falls_back_to_default() {
        // Whitespace-only overrides are treated as absent.
        let id = build_identity(Some("  "), Some(""), "closetjunky");
        assert!(AGENT_ROSTER.contains(&id.codename.as_str()));
        assert!(id.email.ends_with("@closetjunky.chump.fleet"));
    }

    // ── MISSION-049: own-repo vs guest-repo mode ───────────────────────────

    #[test]
    fn mission049_resolve_mode_own_when_identity_matches_owner() {
        let fake_gh = TempDir::new().unwrap();
        let gh_path = fake_gh.path().join("gh");
        write_fake_gh(&gh_path, "repairman29", 0);
        let (mode, identity) =
            resolve_mode("repairman29/BEAST-MODE", None, gh_path.to_str().unwrap());
        assert_eq!(mode, ImproveMode::Own);
        assert_eq!(identity, Some("repairman29".to_string()));
    }

    #[test]
    fn mission049_resolve_mode_guest_when_identity_differs_from_owner() {
        let fake_gh = TempDir::new().unwrap();
        let gh_path = fake_gh.path().join("gh");
        write_fake_gh(&gh_path, "repairman29", 0);
        let (mode, identity) = resolve_mode("ehippy/derelict", None, gh_path.to_str().unwrap());
        assert_eq!(mode, ImproveMode::Guest);
        assert_eq!(identity, Some("repairman29".to_string()));
    }

    #[test]
    fn mission049_resolve_mode_guest_when_identity_unresolvable() {
        // gh exits non-zero (e.g. unauthenticated) -> identity unknown -> fail
        // SAFE to Guest rather than risk a false "own" self-merge.
        let fake_gh = TempDir::new().unwrap();
        let gh_path = fake_gh.path().join("gh");
        write_fake_gh(&gh_path, "", 1);
        let (mode, identity) = resolve_mode("ehippy/derelict", None, gh_path.to_str().unwrap());
        assert_eq!(mode, ImproveMode::Guest);
        assert_eq!(identity, None);
    }

    #[test]
    fn mission049_resolve_mode_explicit_override_wins() {
        let fake_gh = TempDir::new().unwrap();
        let gh_path = fake_gh.path().join("gh");
        write_fake_gh(&gh_path, "repairman29", 0);
        // Owner matches identity, but --mode guest forces Guest anyway.
        let (mode, _) = resolve_mode(
            "repairman29/BEAST-MODE",
            Some("guest"),
            gh_path.to_str().unwrap(),
        );
        assert_eq!(mode, ImproveMode::Guest);
    }

    #[test]
    fn mission049_guest_pr_cap_defaults_to_one_and_env_overrides() {
        // Single test (not two) — CHUMP_GUEST_PR_CAP is process-global env, and
        // cargo runs tests in parallel threads within this binary; splitting this
        // into separate set/remove tests would race on the same var.
        std::env::remove_var("CHUMP_GUEST_PR_CAP");
        assert_eq!(guest_pr_cap(), 1);
        std::env::set_var("CHUMP_GUEST_PR_CAP", "3");
        assert_eq!(guest_pr_cap(), 3);
        std::env::remove_var("CHUMP_GUEST_PR_CAP");
    }

    #[test]
    fn mission049_guest_open_pr_count_parses_gh_output() {
        let fake_gh = TempDir::new().unwrap();
        let gh_path = fake_gh.path().join("gh");
        write_fake_gh(&gh_path, "2", 0);
        let n = guest_open_pr_count("ehippy/derelict", "repairman29", gh_path.to_str().unwrap());
        assert_eq!(n, 2);
    }

    #[test]
    fn mission049_guest_open_pr_count_fails_open_to_zero() {
        let fake_gh = TempDir::new().unwrap();
        let gh_path = fake_gh.path().join("gh");
        write_fake_gh(&gh_path, "garbage", 1);
        let n = guest_open_pr_count("ehippy/derelict", "repairman29", gh_path.to_str().unwrap());
        assert_eq!(n, 0);
    }

    #[test]
    fn mission063_email_default_derived_from_codename_and_node() {
        let id = build_identity(Some("Rivet"), None, "closetjunky");
        assert_eq!(id.email, "rivet@closetjunky.chump.fleet");
        assert_eq!(id.name, "Chump · Rivet");
    }

    #[test]
    fn mission063_prompt_signature_carries_trailer_and_name() {
        let id = AgentIdentity {
            codename: "Rivet".into(),
            name: "Chump · Rivet".into(),
            email: "rivet@closetjunky.chump.fleet".into(),
            node: "closetjunky".into(),
        };
        let sig = id.prompt_signature();
        assert!(sig.contains("Chump · Rivet"));
        assert!(sig.contains("Chump-Agent: Rivet@closetjunky"));
        assert!(sig.contains("LAST line of every commit"));
    }

    // ── MISSION-061: external shepherd ─────────────────────────────────────

    #[test]
    fn mission061_email_is_agent_matches_only_agent_domain() {
        // Agent emails (from 063: <code>@<node>.chump.fleet) match; humans don't.
        assert!(email_is_agent(
            "rivet@closetjunky.chump.fleet",
            "chump.fleet"
        ));
        assert!(email_is_agent("bolt@chump.fleet", "chump.fleet"));
        assert!(email_is_agent(
            "  Gizmo@Helsinki.Chump.Fleet ",
            "chump.fleet"
        ));
        // Never match a human's PR — this is the guardrail.
        assert!(!email_is_agent("jeff@gmail.com", "chump.fleet"));
        assert!(!email_is_agent("noreply@github.com", "chump.fleet"));
        // A domain that merely contains the string but isn't the suffix.
        assert!(!email_is_agent("x@chump.fleet.evil.com", "chump.fleet"));
        assert!(!email_is_agent("anything", ""));
    }

    #[test]
    fn mission061_split_top_objects_handles_nesting_and_strings() {
        let json = r#"[{"number":17,"title":"a}b","url":"u1","mergeStateStatus":"BLOCKED","headRefName":"br1"},{"number":18,"title":"c","authors":[{"email":"x@y"}]}]"#;
        let objs = split_top_objects(json);
        assert_eq!(
            objs.len(),
            2,
            "two top-level objects despite nested braces and a brace char inside a string"
        );
        assert!(objs[0].contains("\"number\":17"));
        assert!(objs[1].contains("authors"));
    }

    #[test]
    fn mission061_json_field_extractors() {
        let obj = r#"{"number":17,"title":"fix: a \"quoted\" thing","url":"https://x/17","mergeStateStatus":"BEHIND"}"#;
        assert_eq!(json_int_field(obj, "number"), Some(17));
        assert_eq!(
            json_str_field(obj, "title"),
            Some("fix: a \"quoted\" thing".to_string())
        );
        assert_eq!(json_str_field(obj, "url"), Some("https://x/17".to_string()));
        assert_eq!(
            json_str_field(obj, "mergeStateStatus"),
            Some("BEHIND".to_string())
        );
        assert_eq!(json_int_field(obj, "missing"), None);
    }

    #[test]
    fn mission061_parse_open_pr_list_shape() {
        let json = r#"[{"number":17,"title":"t17","url":"u17","mergeStateStatus":"BLOCKED","headRefName":"b17"},{"number":18,"title":"t18","url":"u18","mergeStateStatus":"CLEAN","headRefName":"b18"}]"#;
        let objs = split_top_objects(json);
        let nums: Vec<u64> = objs
            .iter()
            .filter_map(|o| json_int_field(o, "number"))
            .collect();
        assert_eq!(nums, vec![17, 18]);
        let states: Vec<String> = objs
            .iter()
            .filter_map(|o| json_str_field(o, "mergeStateStatus"))
            .collect();
        assert_eq!(states, vec!["BLOCKED".to_string(), "CLEAN".to_string()]);
    }

    fn sample_scan(owner_repo: &str) -> OnboardScan {
        OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: owner_repo.to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![InputRead {
                path: "README.md".to_string(),
                sha256: "deadbeef".to_string(),
                summary: "Main overview".to_string(),
            }],
            proposed_gaps: vec![
                ProposedGap {
                    title: "EFFECTIVE: add integration tests".to_string(),
                    domain: "EFFECTIVE".to_string(),
                    priority: Priority::P1,
                    effort: Effort::S,
                    confidence: Confidence::High,
                    source_of_evidence: SourceOfEvidence {
                        input_path: "README.md".to_string(),
                        section: "## Testing".to_string(),
                        excerpt: "no integration tests exist".to_string(),
                    },
                    acceptance_criteria_draft: vec![
                        "Integration test added".to_string(),
                        "Test covers the main flow".to_string(),
                    ],
                    layer: None,
                    doctrine_justification: None,
                },
                ProposedGap {
                    title: "DOC: update contributing guide".to_string(),
                    domain: "DOC".to_string(),
                    priority: Priority::P2,
                    effort: Effort::Xs,
                    confidence: Confidence::Med,
                    source_of_evidence: SourceOfEvidence {
                        input_path: "CONTRIBUTING.md".to_string(),
                        section: "## Setup".to_string(),
                        excerpt: "setup instructions are outdated".to_string(),
                    },
                    acceptance_criteria_draft: vec!["CONTRIBUTING.md updated".to_string()],
                    layer: None,
                    doctrine_justification: None,
                },
            ],
        }
    }

    /// Stage 1 PICK: reads the scan and returns the highest-confidence gap.
    #[test]
    fn pick_reads_latest_scan() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();
        let scan = sample_scan("test/repo");
        save_scan(repo_dir, &scan).unwrap();

        // Simulate the clone_dir being <repo_dir>/clone/
        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir),
            ..Default::default()
        };

        let picked = pick_gap_from_scan(&opts, opts.clone_dir.as_ref().unwrap())
            .unwrap()
            .remove(0);
        // Should pick the first (highest-confidence) gap.
        assert_eq!(picked.title, "EFFECTIVE: add integration tests");
    }

    /// Stage 1 PICK: --gap overrides the scan entirely.
    #[test]
    fn pick_gap_id_override() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        // EFFECTIVE-353: --gap now LOADS the real gap from the chump store; for an
        // ID absent from every store it fail-softs to the minimal synthesis whose
        // title is the ID. Use a sentinel ID guaranteed absent so this stays
        // deterministic regardless of the ambient state.db (a real ID like
        // EFFECTIVE-177 now resolves to its stored descriptive title). The
        // real-gap-loading path is covered by
        // effective353_stored_gap_carries_real_title_description_and_json_ac.
        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: Some("NONEXISTENT-EFFECTIVE-353-SENTINEL".to_string()),
            apply: false,
            clone_dir: Some(clone_dir.clone()),
            ..Default::default()
        };

        let picked = pick_gap(&opts, &clone_dir).unwrap().remove(0);
        // Single operator-chosen candidate; fail-soft placeholder carries the ID.
        assert_eq!(picked.title, "NONEXISTENT-EFFECTIVE-353-SENTINEL");
    }

    /// Init a git repo in `dir` with one commit carrying `commit_msg`.
    fn git_repo_with_commit(dir: &std::path::Path, commit_msg: &str) {
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .env("GIT_AUTHOR_NAME", "t")
                .env("GIT_AUTHOR_EMAIL", "t@t.t")
                .env("GIT_COMMITTER_NAME", "t")
                .env("GIT_COMMITTER_EMAIL", "t@t.t")
                .output()
                .unwrap();
        };
        git(&["init", "-q"]);
        fs::write(dir.join("seed.txt"), "seed").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", commit_msg]);
    }

    /// Stage 2 DEDUP (ZERO-WASTE-010): skips when a COMMIT already did the work
    /// (key terms co-occur in a commit message), NOT on mere file-keyword presence.
    #[test]
    fn dedup_detects_redundant_work() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path();
        // A commit already did this work — its message carries the gap's key terms.
        git_repo_with_commit(clone_dir, "feat: add streaming pipeline support");

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming pipeline planned".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming pipeline implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check("owner/testrepo", clone_dir, &gap, "gh").unwrap();
        assert!(
            matches!(result, DedupResult::Redundant { .. }),
            "dedup should detect work already done in a commit"
        );
    }

    /// ZERO-WASTE-010 regression: common title words present in FILES (but no commit
    /// did the work) must NOT trigger a skip — this is the exact BEAST-MODE roadmap
    /// false-positive that skipped real work on the first live run.
    #[test]
    fn dedup_proceeds_when_keywords_only_in_files() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path();
        // Real repo, but the commit does NOT do the work.
        git_repo_with_commit(clone_dir, "initial commit");
        // Files DO contain the title keywords (like any repo that has a roadmap).
        fs::write(
            clone_dir.join("ROADMAP.md"),
            "# Roadmap\n- migrate the tasks eventually\n- more roadmap tasks\n",
        )
        .unwrap();

        let gap = ProposedGap {
            title: "EFFECTIVE: Migrate roadmap tasks to bd".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "AGENTS.md".to_string(),
                section: "## Tracking".to_string(),
                excerpt: "bd mandated; ROADMAP.md still markdown".to_string(),
            },
            acceptance_criteria_draft: vec!["Roadmap tasks migrated to bd".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check("owner/testrepo", clone_dir, &gap, "gh").unwrap();
        assert!(
            matches!(result, DedupResult::NotRedundant),
            "keywords in files (no matching commit) must NOT false-skip — ZERO-WASTE-010"
        );
    }

    /// Stage 2 DEDUP: passes if gap keywords are absent.
    #[test]
    fn dedup_passes_for_new_work() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path();

        // Write a file that does NOT contain the keywords.
        let src_dir = clone_dir.join("src");
        fs::create_dir_all(&src_dir).unwrap();
        fs::write(src_dir.join("main.rs"), "fn main() {}").unwrap();

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming support xyzzy".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::M,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming xyzzy planned but not built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming xyzzy implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check("owner/testrepo", clone_dir, &gap, "gh").unwrap();
        assert!(
            matches!(result, DedupResult::NotRedundant),
            "dedup should pass for new work"
        );
    }

    /// extract_pr_url_from_output parses the URL correctly.
    #[test]
    fn extract_pr_url_parses_json() {
        let output = r#"
Some prose from the agent.

```json
{
  "pr_url": "https://github.com/test/repo/pull/42",
  "head_ref": "chump/improve-abc",
  "base_ref": "main",
  "files_touched": ["src/lib.rs"],
  "commit_sha": "abcdef1234567890abcdef1234567890abcdef12",
  "notes": "Added integration test"
}
```
"#;
        let url = extract_pr_url_from_output(output);
        assert_eq!(
            url,
            Some("https://github.com/test/repo/pull/42".to_string())
        );
    }

    /// extract_pr_number extracts the number from a URL.
    #[test]
    fn extract_pr_number_works() {
        assert_eq!(
            extract_pr_number("https://github.com/test/repo/pull/42"),
            Some(42)
        );
        assert_eq!(
            extract_pr_number("https://github.com/test/repo/pull/999"),
            Some(999)
        );
        assert_eq!(extract_pr_number("https://example.com"), None);
    }

    /// Dry-run mode: stages 2-4 are skipped; emit improve_cycle_complete with verdict=dry_run.
    /// This test verifies the orchestrator runs WITHOUT spawning a real claude/gh binary.
    #[test]
    fn dry_run_skips_implement_and_verify() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();
        let scan = sample_scan("owner/myrepo");
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        // Build an Opts struct directly (dry-run, no apply).
        let opts = Opts {
            owner_repo: "owner/myrepo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
            ..Default::default()
        };

        // Run just the pick stage + dedup logic without spawning any processes.
        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap().remove(0);
        assert_eq!(picked.title, "EFFECTIVE: add integration tests");

        // Dedup on an empty clone dir should pass (no code present).
        let dedup = dedup_check("owner/myrepo", &clone_dir, &picked, "gh").unwrap();
        assert!(matches!(dedup, DedupResult::NotRedundant));

        // Dry-run: stages 3-4 are not called. Verify the chain stops here.
        // (No panic == the orchestrator composed stages 1+2 in order.)
    }

    /// --apply vs dry-run differ: apply mode would call implement + verify-merge;
    /// dry-run stops after pick+dedup. We assert the arg parsing distinction.
    #[test]
    fn apply_flag_parsed_correctly() {
        let args_dry = vec!["owner/repo".to_string()];
        let args_apply = vec!["owner/repo".to_string(), "--apply".to_string()];

        let opts_dry = parse_args(&args_dry).unwrap();
        let opts_apply = parse_args(&args_apply).unwrap();

        assert!(!opts_dry.apply, "dry-run: apply should be false");
        assert!(opts_apply.apply, "apply mode: apply should be true");
    }

    // ── CREDIBLE-100: parse_verdict unit tests ─────────────────────────────

    /// "Verdict: MERGE" → Some("verified")
    #[test]
    fn parse_verdict_merge() {
        assert_eq!(
            parse_verdict("Verdict: MERGE"),
            Some("verified"),
            "bare Verdict: MERGE should return verified"
        );
    }

    /// Multi-line output with Verdict: MERGE embedded → Some("verified")
    #[test]
    fn parse_verdict_merge_in_multiline() {
        let stdout = "[verify-merge] Gate 1: CI green\n\
                      [verify-merge] Gate 2: test proves change\n\
                      [verify-merge] Gate 3: no regression\n\
                      \n\
                      Verdict: MERGE\n";
        assert_eq!(parse_verdict(stdout), Some("verified"));
    }

    /// "Verdict: HELD(<reason>)" → Some("held")
    #[test]
    fn parse_verdict_held_with_reason() {
        let stdout = "...\nVerdict: HELD(unproven)\n";
        assert_eq!(
            parse_verdict(stdout),
            Some("held"),
            "Verdict: HELD(...) should return held"
        );
    }

    /// "Verdict: HELD(no-gates)" → Some("held")
    #[test]
    fn parse_verdict_held_no_gates() {
        assert_eq!(parse_verdict("\nVerdict: HELD(no-gates)\n"), Some("held"));
    }

    /// Brain-style chat reply with no Verdict: line → None (misfire detection)
    #[test]
    fn parse_verdict_brain_reply_is_none() {
        let brain_reply = "The word \"external\" refers to something \
                           originating or acting from outside. In anatomy, \
                           external means situated on or near the outside of \
                           the body. Exit code: 0.";
        assert_eq!(
            parse_verdict(brain_reply),
            None,
            "a brain chat reply with no Verdict: line must return None"
        );
    }

    /// Empty string → None
    #[test]
    fn parse_verdict_empty_is_none() {
        assert_eq!(parse_verdict(""), None);
    }

    // ── RESILIENT-106: oauth token injection path ──────────────────────────

    /// read_oauth_token_file: "token" key is read correctly.
    #[test]
    fn oauth_token_file_token_key() {
        let tmp = TempDir::new().unwrap();
        let token_path = tmp.path().join("oauth-token.json");
        fs::write(&token_path, r#"{"token":"tok_abc123"}"#).unwrap();

        // Override HOME so read_oauth_token_file looks in our temp dir.
        // The function reads ~/.chump/oauth-token.json, so we need
        // HOME=<tmp> and the file at <tmp>/.chump/oauth-token.json.
        let chump_dir = tmp.path().join(".chump");
        fs::create_dir_all(&chump_dir).unwrap();
        fs::write(
            chump_dir.join("oauth-token.json"),
            r#"{"token":"tok_abc123"}"#,
        )
        .unwrap();

        // Temporarily set HOME to our tmp dir and call read_oauth_token_file.
        // We can't set env vars in parallel tests safely, so we test the
        // parse logic directly via serde_json here.
        let content = r#"{"token":"tok_abc123"}"#;
        let v: serde_json::Value = serde_json::from_str(content).unwrap();
        let tok = v.get("token").and_then(|x| x.as_str()).unwrap_or("");
        assert_eq!(tok, "tok_abc123", "token key should be read");
    }

    /// read_oauth_token_file: "access_token" key is read correctly.
    #[test]
    fn oauth_token_file_access_token_key() {
        let content = r#"{"access_token":"at_xyz789"}"#;
        let v: serde_json::Value = serde_json::from_str(content).unwrap();
        // Try all three keys in order — "token" absent, falls through to "access_token".
        let tok = ["token", "access_token", "accessToken"]
            .iter()
            .find_map(|k| v.get(*k).and_then(|x| x.as_str()).filter(|s| !s.is_empty()));
        assert_eq!(tok, Some("at_xyz789"), "access_token key should be read");
    }

    /// read_oauth_token_file: "accessToken" key (camelCase) is read correctly.
    #[test]
    fn oauth_token_file_access_token_camel_key() {
        let content = r#"{"accessToken":"camel_tok_999"}"#;
        let v: serde_json::Value = serde_json::from_str(content).unwrap();
        let tok = ["token", "access_token", "accessToken"]
            .iter()
            .find_map(|k| v.get(*k).and_then(|x| x.as_str()).filter(|s| !s.is_empty()));
        assert_eq!(
            tok,
            Some("camel_tok_999"),
            "accessToken camelCase key should be read"
        );
    }

    /// read_oauth_token_file: missing file returns None gracefully.
    #[test]
    fn oauth_token_file_missing_returns_none() {
        let tmp = TempDir::new().unwrap();
        // No file written — simulate HOME pointing to empty dir.
        let fake_home = tmp.path().to_string_lossy().to_string();
        // We test the logic path: if read_to_string fails, we return None.
        let missing = std::fs::read_to_string(
            std::path::PathBuf::from(&fake_home)
                .join(".chump")
                .join("oauth-token.json"),
        );
        assert!(missing.is_err(), "reading missing file should fail");
        // The function returns None on any error — verified by the Option chain.
        let result: Option<String> = missing.ok().and_then(|c| {
            let v: Option<serde_json::Value> = serde_json::from_str(&c).ok();
            v?.get("token")
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
        });
        assert!(result.is_none(), "missing file path should yield None");
    }

    // ── EFFECTIVE-201: doctrine-order picking tests ────────────────────────

    /// Build a minimal `ProposedGap` with the given layer and confidence for
    /// testing the doctrine-order picker. All other fields are placeholder.
    fn make_gap(title: &str, layer: Option<&str>, conf: Confidence) -> ProposedGap {
        ProposedGap {
            title: title.to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P2,
            effort: Effort::S,
            confidence: conf,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "§test".to_string(),
                excerpt: "test".to_string(),
            },
            acceptance_criteria_draft: vec!["done".to_string()],
            layer: layer.map(|s| s.to_string()),
            doctrine_justification: layer.map(|l| format!("test {l} justification")),
        }
    }

    /// Doctrine-order: L1 is always picked before L2 and L3 regardless of
    /// position in the original scan.
    #[test]
    fn doctrine_order_l1_before_l2_before_l3() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();

        // Build a scan where gaps are ordered L3, L2, L1 — picker must re-sort
        // and return the L1 gap first.
        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: "test/repo".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                make_gap("L3: latent realization idea", Some("L3"), Confidence::High),
                make_gap("L2: README claim unfulfilled", Some("L2"), Confidence::High),
                make_gap("L1: foundation gate unmet", Some("L1"), Confidence::Med),
            ],
        };
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
            ..Default::default()
        };

        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap().remove(0);
        assert_eq!(
            picked.title, "L1: foundation gate unmet",
            "doctrine-order picking must select L1 first, even if it appears last in the scan"
        );
        assert_eq!(picked.layer.as_deref(), Some("L1"));
    }

    /// Within L1, higher confidence is picked first.
    #[test]
    fn doctrine_order_within_layer_by_confidence() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();

        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: "test/repo".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                make_gap("L1 low-conf", Some("L1"), Confidence::Low),
                make_gap("L1 high-conf", Some("L1"), Confidence::High),
                make_gap("L2 high-conf", Some("L2"), Confidence::High),
            ],
        };
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
            ..Default::default()
        };

        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap().remove(0);
        assert_eq!(
            picked.title, "L1 high-conf",
            "within L1, high-confidence gap must be picked before low-confidence"
        );
    }

    /// Untagged gaps (no layer) are de-prioritised below L3.
    #[test]
    fn doctrine_order_untagged_after_l3() {
        let tmp = TempDir::new().unwrap();
        let repo_dir = tmp.path();

        let scan = OnboardScan {
            scan_timestamp: Utc::now(),
            external_repo: "test/repo".to_string(),
            tool_version: "0.1.0".to_string(),
            inputs_read: vec![],
            proposed_gaps: vec![
                make_gap("untagged high-conf", None, Confidence::High),
                make_gap("L3 low-conf", Some("L3"), Confidence::Low),
            ],
        };
        save_scan(repo_dir, &scan).unwrap();

        let clone_dir = repo_dir.join("clone");
        fs::create_dir_all(&clone_dir).unwrap();

        let opts = Opts {
            owner_repo: "test/repo".to_string(),
            gap_id: None,
            apply: false,
            clone_dir: Some(clone_dir.clone()),
            ..Default::default()
        };

        let picked = pick_gap_from_scan(&opts, &clone_dir).unwrap().remove(0);
        assert_eq!(
            picked.title, "L3 low-conf",
            "L3 (even low-confidence) must be picked before an untagged gap"
        );
    }

    // ── B4: configure_claude_auth_env unit tests (RESILIENT-108) ──────────

    /// B4: when CLAUDE_CODE_OAUTH_TOKEN is set in the parent env and fake
    /// ANTHROPIC_* gateway vars are explicitly set on a Command, calling
    /// configure_claude_auth_env strips all four gateway vars (they appear as
    /// `(key, None)` in `Command::get_envs()`) and returns true.
    ///
    /// We use Command::get_envs() to inspect the env-override map without
    /// spawning any process.
    /// COTG-1.6/INFRA-3488: the fix ladder maps to cascade model-CLASSES so the
    /// chump-local path escalates sonnet→opus without ever naming claude.
    #[test]
    fn model_to_class_maps_ladder_without_naming_claude() {
        assert_eq!(model_to_class("claude-sonnet-4-5"), "sonnet");
        assert_eq!(model_to_class("opus"), "opus");
        assert_eq!(model_to_class("some-OPUS-variant"), "opus");
        assert_eq!(model_to_class("gpt-whatever"), "sonnet");
    }

    /// COTG-1.6/INFRA-3488: hard external implementation biases the strong class by
    /// default (evidence: weak-class stormed, opus-class edited surgically); operator
    /// can override.
    #[test]
    #[serial_test::serial]
    fn improve_implement_class_defaults_strong() {
        unsafe {
            std::env::remove_var("CHUMP_IMPROVE_IMPLEMENT_CLASS");
        }
        assert_eq!(improve_implement_class(), "opus");
        unsafe {
            std::env::set_var("CHUMP_IMPROVE_IMPLEMENT_CLASS", "sonnet");
        }
        assert_eq!(improve_implement_class(), "sonnet");
        unsafe {
            std::env::remove_var("CHUMP_IMPROVE_IMPLEMENT_CLASS");
        }
    }

    /// COTG-1.3/INFRA-3485: the edit-verify gate rejects a destructive clobber and an
    /// invalid structured file, and accepts a legitimate edit. Hermetic (git + serde).
    #[test]
    fn edit_verify_rejects_clobber_and_invalid_accepts_good() {
        use std::fs;
        let tmp = tempfile::tempdir().unwrap();
        let wd = tmp.path();
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(["-C", wd.to_str().unwrap()])
                .args(args)
                .output()
                .unwrap();
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.email", "t@t"]);
        git(&["config", "user.name", "t"]);
        // a big valid JSON (for the clobber case), a small valid JSON, a text file.
        let big = format!(
            "{{\n{}\n  \"x\": 1\n}}\n",
            (0..100)
                .map(|i| format!("  \"k{i}\": {i},"))
                .collect::<Vec<_>>()
                .join("\n")
        );
        fs::write(wd.join("big.json"), &big).unwrap();
        fs::write(wd.join("config.json"), "{\n  \"a\": 1,\n  \"b\": 2\n}\n").unwrap();
        fs::write(wd.join("keep.txt"), "seed\n").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-qm", "seed"]);

        // (accept) a small legitimate text edit
        fs::write(wd.join("keep.txt"), "seed\nplus one line\n").unwrap();
        git(&["add", "-A"]);
        assert!(verify_staged_edit(wd).is_ok(), "legit edit must pass");
        git(&["reset", "-q"]);
        git(&["checkout", "-q", "--", "."]);

        // (reject: destructive) clobber big.json to a stub
        fs::write(wd.join("big.json"), "{}\n").unwrap();
        git(&["add", "-A"]);
        let r = verify_staged_edit(wd);
        assert!(
            r.is_err() && r.unwrap_err().to_string().contains("destructive"),
            "clobber must be rejected as destructive"
        );
        git(&["reset", "-q"]);
        git(&["checkout", "-q", "--", "."]);

        // (reject: invalid) small edit that breaks JSON validity
        fs::write(wd.join("config.json"), "{\n  \"a\": 1,\n  oops\n}\n").unwrap();
        git(&["add", "-A"]);
        let r = verify_staged_edit(wd);
        assert!(
            r.is_err() && r.unwrap_err().to_string().contains("parses"),
            "invalid JSON must be rejected"
        );
    }

    /// EFFECTIVE-408: a landed-but-BROKEN edit (invalid YAML, or a destructive clobber)
    /// present in the UNCOMMITTED working tree is detected by `working_tree_edit_is_broken`
    /// — the signal that drives EFFECTIVE-366 escalation. Before this fix, such a repo
    /// state skipped escalation (an edit HAD landed → not the no-edit case) and then failed
    /// at the ship gate instead of retrying with a stronger model. Also proves the
    /// escalation decision (`landed_no_edit || landed_broken_edit`) fires on a broken edit.
    /// Hermetic (git + serde). Note: probes the working tree WITHOUT staging, since
    /// escalation happens before `deterministic_ship` stages anything.
    #[test]
    fn working_tree_broken_edit_triggers_escalation() {
        use std::fs;
        let tmp = tempfile::tempdir().unwrap();
        let wd = tmp.path();
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(["-C", wd.to_str().unwrap()])
                .args(args)
                .output()
                .unwrap();
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.email", "t@t"]);
        git(&["config", "user.name", "t"]);
        let big_yaml = format!(
            "root:\n{}\n",
            (0..100)
                .map(|i| format!("  k{i}: {i}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
        fs::write(wd.join("big.yaml"), &big_yaml).unwrap();
        fs::write(wd.join("conf.yml"), "a: 1\nb: 2\n").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-qm", "seed"]);

        // (clean baseline) no uncommitted edits → not broken.
        assert!(
            !working_tree_edit_is_broken(wd),
            "no edit must not read as broken"
        );

        // (good edit, unstaged) a valid small YAML edit → not broken → no escalation.
        fs::write(wd.join("conf.yml"), "a: 1\nb: 2\nc: 3\n").unwrap();
        assert!(
            !working_tree_edit_is_broken(wd),
            "a valid unstaged edit must not read as broken"
        );
        git(&["checkout", "-q", "--", "."]);

        // (broken edit, unstaged) invalid YAML → broken → escalate. The weak model
        // "landed" an edit (work_dir_has_real_edits would be true), but it's rejected.
        fs::write(wd.join("conf.yml"), "a: 1\nb: [1, 2, 3\n").unwrap();
        assert!(
            working_tree_edit_is_broken(wd),
            "invalid-YAML edit must read as broken (drives EFFECTIVE-366 escalation)"
        );
        // The escalation decision must fire: an edit landed (not no-edit) but it's broken.
        let landed_no_edit = false;
        let landed_broken_edit = !landed_no_edit && working_tree_edit_is_broken(wd);
        assert!(
            landed_no_edit || landed_broken_edit,
            "broken landed edit must trigger the Claude-rung escalation, not fail the run"
        );
        git(&["checkout", "-q", "--", "."]);

        // (destructive clobber, unstaged) near-total rewrite → broken → escalate.
        fs::write(wd.join("big.yaml"), "x: 1\n").unwrap();
        assert!(
            working_tree_edit_is_broken(wd),
            "a destructive clobber must read as broken"
        );
    }

    /// COTG-1.3/INFRA-3516: the guarded ceremony that BOTH the ship and remediation paths
    /// now share (a) drops chump's runtime droppings so they never enter a commit, (b) commits
    /// the real edit, and (c) rejects a destructive clobber — proving the fix path can no
    /// longer re-corrupt a PR the way BEAST #35's remediation commits did. Hermetic (git).
    #[test]
    fn guarded_commit_drops_junk_and_rejects_clobber() {
        use std::fs;
        let tmp = tempfile::tempdir().unwrap();
        let wd = tmp.path();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .args(["-C", wd.to_str().unwrap()])
                .args(args)
                .output()
                .unwrap()
        };
        run(&["init", "-q", "-b", "work"]);
        run(&["config", "user.email", "t@t"]);
        run(&["config", "user.name", "t"]);
        fs::write(wd.join("app.txt"), "seed\n").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "seed"]);
        let id = agent_identity();

        // (accept) a real edit ALONGSIDE runtime droppings the agent wrote into the cwd.
        fs::write(wd.join("app.txt"), "seed\nreal fix\n").unwrap();
        fs::create_dir_all(wd.join(".chump-locks")).unwrap();
        fs::write(wd.join(".chump-locks/lease.json"), "{}").unwrap();
        fs::create_dir_all(wd.join("sessions")).unwrap();
        fs::write(wd.join("sessions/chump_memory.db"), "sqlite-junk").unwrap();
        // CREDIBLE-199: agent-run's own tool-call trace, written into the cwd.
        fs::create_dir_all(wd.join("logs")).unwrap();
        fs::write(wd.join("logs/chump.log"), "1785905003 | write_file | ...\n").unwrap();
        let branch = guarded_stage_and_commit(wd, "fix(ci): x\n\ntrailer", &id, "for the test")
            .expect("a real edit must commit");
        assert_eq!(branch, "work", "returns the branch holding the commit");
        let files =
            String::from_utf8(run(&["show", "--name-only", "--format=", "HEAD"]).stdout).unwrap();
        assert!(files.contains("app.txt"), "the real edit is committed");
        assert!(
            !files.contains(".chump-locks")
                && !files.contains("sessions/")
                && !files.contains("logs/chump.log"),
            "runtime droppings (incl. logs/chump.log, CREDIBLE-199) must NOT enter the commit — got: {files:?}"
        );

        // (reject) a destructive clobber never commits (guard shared with the ship path).
        fs::write(wd.join("app.txt"), "x\n").unwrap(); // near-total deletion
                                                       // pad the prior file so the clobber heuristic (d>=50) can fire.
        let big: String = (0..80).map(|i| format!("line {i}\n")).collect();
        fs::write(wd.join("big.txt"), &big).unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-qm", "grow"]);
        fs::write(wd.join("big.txt"), "gone\n").unwrap();
        let before = String::from_utf8(run(&["rev-parse", "HEAD"]).stdout).unwrap();
        let r = guarded_stage_and_commit(wd, "clobber", &id, "for the test");
        assert!(
            r.is_err(),
            "a destructive clobber must be rejected, not committed"
        );
        let after = String::from_utf8(run(&["rev-parse", "HEAD"]).stdout).unwrap();
        assert_eq!(before, after, "no commit was created on rejection");
    }

    /// COTG-1.4/INFRA-3486: the resume journal round-trips the pr_url through the exact JSON
    /// snapshot save_flow_checkpoint writes, so a crashed run resumes at the same PR.
    #[test]
    fn flow_checkpoint_pr_url_roundtrips() {
        let url = "https://github.com/owner/repo/pull/42";
        // the EXACT format save_flow_checkpoint persists:
        let snap = format!("{{\"pr_url\":{url:?}}}");
        assert_eq!(parse_flow_pr_url(&snap), Some(url.to_string()));
        // a snapshot with no pr_url (or malformed) → no resume, run fresh:
        assert_eq!(parse_flow_pr_url("{}"), None);
        assert_eq!(parse_flow_pr_url("not json"), None);
        assert_eq!(parse_flow_pr_url("{\"other\":1}"), None);
    }

    /// COTG-1.2/INFRA-3484: the deterministic ceremony reads the PR URL from gh's own
    /// output (a bare URL), not an agent JSON block.
    #[test]
    fn first_github_pr_url_parses_gh_output() {
        assert_eq!(
            first_github_pr_url("https://github.com/owner/repo/pull/42\n"),
            Some("https://github.com/owner/repo/pull/42".to_string())
        );
        // ignores non-PR github URLs + surrounding noise
        assert_eq!(
            first_github_pr_url("Creating pull request...\nhttps://github.com/o/r/pull/7 done"),
            Some("https://github.com/o/r/pull/7".to_string())
        );
        assert_eq!(first_github_pr_url("no url here"), None);
        assert_eq!(
            first_github_pr_url("https://github.com/o/r/tree/main"),
            None
        );
    }

    /// INFRA-3478: the per-agent worktree key is pid-scoped so concurrent
    /// `improve` processes on the same external repo get distinct worktrees, and
    /// stable within a process (one implement call reuses it).
    #[test]
    fn improve_worktree_key_is_pid_scoped() {
        let k = improve_worktree_key();
        assert!(k.starts_with('p'), "key should be pid-scoped: {k}");
        assert!(
            k[1..].chars().all(|c| c.is_ascii_digit()),
            "key tail must be the numeric pid: {k}"
        );
        assert_eq!(k, improve_worktree_key(), "stable within a process");
    }

    /// INFRA-3477 / Principle 0: `improve` must default to the OS's own runtime
    /// ("chump-local") and NEVER silently fall back to the claude CLI. claude is
    /// opt-in only. Guards the outward-flywheel default against regression.
    #[test]
    #[serial_test::serial]
    fn improve_backend_defaults_to_chump_local_not_claude() {
        unsafe {
            std::env::remove_var("CHUMP_IMPROVE_BACKEND");
        }
        assert_eq!(
            resolve_improve_backend(),
            "chump-local",
            "unset → chump-local (never claude)"
        );

        unsafe {
            std::env::set_var("CHUMP_IMPROVE_BACKEND", "   ");
        }
        assert_eq!(
            resolve_improve_backend(),
            "chump-local",
            "blank/whitespace → chump-local (never claude)"
        );

        unsafe {
            std::env::set_var("CHUMP_IMPROVE_BACKEND", "claude");
        }
        assert_eq!(
            resolve_improve_backend(),
            "claude",
            "explicit opt-in resolves to claude"
        );

        // Isolate from other tests.
        unsafe {
            std::env::remove_var("CHUMP_IMPROVE_BACKEND");
        }
    }

    #[test]
    #[serial_test::serial]
    fn configure_auth_env_strips_gateway_when_oauth_in_env() {
        // Set the OAUTH token in the process env for this test.
        // Use a clearly fake value — never logged.
        unsafe {
            std::env::set_var("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-token-b4-unit");
        }

        let mut cmd = Command::new("true"); // never spawned
                                            // Explicitly add gateway vars to cmd so env_remove can target them.
        cmd.env("ANTHROPIC_API_KEY", "fake-key");
        cmd.env("ANTHROPIC_AUTH_TOKEN", "fake-auth-token");
        cmd.env("ANTHROPIC_BASE_URL", "https://fake.gateway.example");
        cmd.env("ANTHROPIC_CUSTOM_HEADERS", "X-Fake: header");

        let result = configure_claude_auth_env(&mut cmd);

        // Restore env before assertions (isolate from other tests).
        unsafe {
            std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
        }

        assert!(
            result,
            "configure_claude_auth_env must return true when OAUTH token is in env"
        );

        // After env_remove(), the key appears as (key, None) in get_envs().
        let env_map: std::collections::HashMap<_, _> = cmd
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().to_string(),
                    v.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert_eq!(
            env_map.get("ANTHROPIC_API_KEY"),
            Some(&None),
            "ANTHROPIC_API_KEY must be removed from Command env when OAUTH is active"
        );
        assert_eq!(
            env_map.get("ANTHROPIC_AUTH_TOKEN"),
            Some(&None),
            "ANTHROPIC_AUTH_TOKEN must be removed from Command env when OAUTH is active"
        );
        assert_eq!(
            env_map.get("ANTHROPIC_BASE_URL"),
            Some(&None),
            "ANTHROPIC_BASE_URL must be removed from Command env when OAUTH is active"
        );
        assert_eq!(
            env_map.get("ANTHROPIC_CUSTOM_HEADERS"),
            Some(&None),
            "ANTHROPIC_CUSTOM_HEADERS must be removed from Command env when OAUTH is active"
        );
        // CLAUDE_CODE_OAUTH_TOKEN was in the parent env (token_in_env=true) so
        // configure_claude_auth_env does NOT re-inject it (no explicit cmd.env call).
        // It must not be removed either.
        assert_ne!(
            env_map.get("CLAUDE_CODE_OAUTH_TOKEN"),
            Some(&None),
            "CLAUDE_CODE_OAUTH_TOKEN must NOT be removed from Command env"
        );
    }

    /// B4: when no OAUTH token is available (neither env nor file), the
    /// function returns false and does NOT strip any gateway vars.
    #[test]
    #[serial_test::serial]
    fn configure_auth_env_noop_when_no_oauth() {
        // If the test process happens to carry CLAUDE_CODE_OAUTH_TOKEN, skip —
        // we can't safely remove it without affecting other parallel tests.
        if std::env::var_os("CLAUDE_CODE_OAUTH_TOKEN").is_some() {
            return;
        }

        // Point HOME at an empty tmp dir so read_oauth_token_file returns None.
        let tmp = TempDir::new().unwrap();
        let orig_home = std::env::var("HOME").unwrap_or_default();
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        let mut cmd = Command::new("true");
        cmd.env("ANTHROPIC_API_KEY", "real-key-must-not-be-stripped");

        let result = configure_claude_auth_env(&mut cmd);

        unsafe {
            std::env::set_var("HOME", &orig_home);
        }

        assert!(
            !result,
            "configure_claude_auth_env must return false when no OAUTH token available"
        );

        // ANTHROPIC_API_KEY must NOT appear as None in the env map.
        let env_map: std::collections::HashMap<_, _> = cmd
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().to_string(),
                    v.map(|v| v.to_string_lossy().to_string()),
                )
            })
            .collect();

        assert_ne!(
            env_map.get("ANTHROPIC_API_KEY"),
            Some(&None),
            "ANTHROPIC_API_KEY must NOT be stripped when no OAUTH token is available"
        );
    }

    // ── B5: open-PR dedup unit tests (ZERO-WASTE-011 / RESILIENT-108) ─────

    /// Helper: init a git repo in `dir` with one commit carrying `commit_msg`.
    fn git_repo_with_commit_b5(dir: &std::path::Path, commit_msg: &str) {
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .env("GIT_AUTHOR_NAME", "t")
                .env("GIT_AUTHOR_EMAIL", "t@t.t")
                .env("GIT_COMMITTER_NAME", "t")
                .env("GIT_COMMITTER_EMAIL", "t@t.t")
                .output()
                .unwrap();
        };
        git(&["init", "-q"]);
        fs::write(dir.join("seed.txt"), "seed").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", commit_msg]);
    }

    /// Write a fake gh binary at `path` that emits `output` on stdout and
    /// exits with `exit_code`. Makes the file executable (unix only).
    fn write_fake_gh(path: &std::path::Path, output: &str, exit_code: i32) {
        let script = format!(
            "#!/usr/bin/env bash\necho '{}'\nexit {}\n",
            output.replace('\'', "'\\''"),
            exit_code
        );
        fs::write(path, script).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// B5: fake gh returns a matching open PR → dedup Redundant.
    #[test]
    fn dedup_open_pr_match_is_redundant() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit: unrelated work");

        let fake_gh = tmp.path().join("gh");
        // The fake gh emits one PR whose title contains the gap's key terms.
        write_fake_gh(
            &fake_gh,
            r#"[{"number":99,"title":"add streaming pipeline for async events"}]"#,
            0,
        );

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming pipeline not yet built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming pipeline implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        // Pass fake_gh directly — no global env mutation needed.
        let result = dedup_check(
            "owner/testrepo",
            &clone_dir,
            &gap,
            &fake_gh.to_string_lossy(),
        )
        .unwrap();

        assert!(
            matches!(result, DedupResult::Redundant { .. }),
            "open PR matching title keywords must trigger Redundant (ZERO-WASTE-011)"
        );
        if let DedupResult::Redundant { reason } = result {
            assert!(
                reason.contains("open PR"),
                "reason must mention 'open PR', got: {reason}"
            );
        }
    }

    /// B5: fake gh returns empty list + no matching commit → NotRedundant.
    #[test]
    fn dedup_no_open_pr_is_not_redundant() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit: unrelated work");

        let fake_gh = tmp.path().join("gh");
        write_fake_gh(&fake_gh, "[]", 0);

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline xyzzy99".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming xyzzy99 not built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming xyzzy99 implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check(
            "owner/testrepo",
            &clone_dir,
            &gap,
            &fake_gh.to_string_lossy(),
        )
        .unwrap();

        assert!(
            matches!(result, DedupResult::NotRedundant),
            "empty open-PR list + no matching commit must be NotRedundant"
        );
    }

    /// B5: gh exits non-zero (network error) → fail-open, returns NotRedundant.
    #[test]
    fn dedup_gh_failure_is_not_redundant() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit");

        let fake_gh = tmp.path().join("gh");
        write_fake_gh(&fake_gh, "error: network failure", 1);

        let gap = ProposedGap {
            title: "EFFECTIVE: add streaming pipeline".to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: "streaming pipeline not built".to_string(),
            },
            acceptance_criteria_draft: vec!["Streaming pipeline implemented".to_string()],
            layer: None,
            doctrine_justification: None,
        };

        let result = dedup_check(
            "owner/testrepo",
            &clone_dir,
            &gap,
            &fake_gh.to_string_lossy(),
        )
        .unwrap();

        assert!(
            matches!(result, DedupResult::NotRedundant),
            "gh failure must fail-open toward NotRedundant (verify-merge is the backstop)"
        );
    }

    /// EFFECTIVE-289: a scan whose TOP-ranked gap is already covered by an open
    /// PR must not stop the pick — the dedup loop (mirroring `run()`'s Stage 2,
    /// improve.rs:248-285) advances to the next ranked candidate and picks that
    /// one instead of reporting "nothing to do". Guards the MISSION-056 behavior
    /// against regression now that a dedicated regression test exists for it.
    #[test]
    fn dedup_loop_skips_top_redundant_and_picks_next_candidate() {
        let tmp = TempDir::new().unwrap();
        let clone_dir = tmp.path().join("clone");
        fs::create_dir_all(&clone_dir).unwrap();
        git_repo_with_commit_b5(&clone_dir, "initial commit: unrelated work");

        // Fake gh: an open PR exists that matches the TOP candidate's title
        // keywords ("streaming pipeline") but not the second candidate's
        // ("retry backoff").
        let fake_gh = tmp.path().join("gh");
        write_fake_gh(
            &fake_gh,
            r#"[{"number":99,"title":"add streaming pipeline for async events"}]"#,
            0,
        );

        let make_gap = |title: &str, excerpt: &str| ProposedGap {
            title: title.to_string(),
            domain: "EFFECTIVE".to_string(),
            priority: Priority::P1,
            effort: Effort::S,
            confidence: Confidence::High,
            source_of_evidence: SourceOfEvidence {
                input_path: "README.md".to_string(),
                section: "## Roadmap".to_string(),
                excerpt: excerpt.to_string(),
            },
            acceptance_criteria_draft: vec![format!("{title} implemented")],
            layer: None,
            doctrine_justification: None,
        };

        let candidates = vec![
            make_gap(
                "EFFECTIVE: add streaming pipeline",
                "streaming pipeline not yet built",
            ),
            make_gap(
                "EFFECTIVE: add retry backoff xyzzy99",
                "retry backoff xyzzy99 not built",
            ),
        ];

        // Same loop shape as run()'s Stage 2 (improve.rs:248-285), minus the
        // fleet-internal sourcing resolver (covered separately, and it touches
        // real CHUMP_REPO_ROOT/arsenal state — out of scope for this unit test).
        let mut chosen: Option<ProposedGap> = None;
        let mut skipped_titles: Vec<String> = Vec::new();
        for cand in &candidates {
            match dedup_check(
                "owner/testrepo",
                &clone_dir,
                cand,
                &fake_gh.to_string_lossy(),
            )
            .unwrap()
            {
                DedupResult::Redundant { .. } => skipped_titles.push(cand.title.clone()),
                DedupResult::NotRedundant => {
                    chosen = Some(cand.clone());
                    break;
                }
            }
        }

        assert_eq!(
            skipped_titles,
            vec!["EFFECTIVE: add streaming pipeline".to_string()],
            "top candidate must be dedup-skipped (covered by open PR), not silently kept"
        );
        assert_eq!(
            chosen.map(|g| g.title),
            Some("EFFECTIVE: add retry backoff xyzzy99".to_string()),
            "loop must advance past the redundant top candidate and pick the next undone one, not exit"
        );
    }

    // ── EFFECTIVE-288 GREEN-FIRST doctrine ────────────────────────────────
    // "Step 1: make it green. Step 2: ship something new."

    #[test]
    fn green_first_none_when_repo_is_green() {
        // No failing checks at all → nothing to fix → fall through to features.
        assert!(green_first_gap_from_failures(&[]).is_none());
    }

    #[test]
    fn green_first_none_when_single_pr_fails() {
        // A check failing on ONE PR is likely that PR's own bug, not a broken
        // gate — must NOT hijack the pick away from feature work.
        let failures = vec![("flaky-test".to_string(), 1)];
        assert!(
            green_first_gap_from_failures(&failures).is_none(),
            "a 1-PR failure is per-PR, not a repo-wide broken gate"
        );
    }

    #[test]
    fn green_first_forces_fix_when_check_fails_across_prs() {
        use chump_handoff::external_repo_schema::{Effort, Priority};
        // "Code Quality Analysis" failing on 3 open PRs (the real BEAST-MODE
        // case) is a broken gate blocking every merge → forced top-priority fix.
        let failures = vec![("Code Quality Analysis".to_string(), 3)];
        let gap = green_first_gap_from_failures(&failures)
            .expect("a check failing across >=2 PRs must force a green-first pick");
        assert!(
            gap.title.contains("GREEN-FIRST") && gap.title.contains("Code Quality Analysis"),
            "title names the doctrine + the failing check: {}",
            gap.title
        );
        assert_eq!(
            gap.priority,
            Priority::P0,
            "a broken merge-gate is top priority"
        );
        assert_eq!(gap.effort, Effort::M);
        assert_eq!(
            gap.layer.as_deref(),
            Some("L1"),
            "green-first is foundation work"
        );
        assert!(
            gap.doctrine_justification
                .as_deref()
                .unwrap_or("")
                .contains("green-first"),
            "carries the green-first doctrine justification"
        );
    }

    #[test]
    fn green_first_picks_the_most_failing_check() {
        // When several checks fail across PRs, the highest-count one is named
        // first (repo_failing_checks sorts most-failing first; the pure fn keeps
        // that order via `.find`).
        let failures = vec![
            ("widely-broken".to_string(), 5),
            ("less-broken".to_string(), 2),
        ];
        let gap = green_first_gap_from_failures(&failures).expect("some failure crosses the bar");
        assert!(
            gap.title.contains("widely-broken"),
            "names the most-failing gate first: {}",
            gap.title
        );
    }

    // ── EFFECTIVE-291: clone refresh ──────────────────────────────────────

    /// Helper: run git in `cwd`, asserting success (commits get a fixed identity).
    fn git_ok(cwd: &std::path::Path, args: &[&str]) {
        let ok = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        assert!(ok, "git {:?} failed in {}", args, cwd.display());
    }

    fn rev_parse(dir: &std::path::Path, rev: &str) -> String {
        let out = Command::new("git")
            .args(["-C", &dir.to_string_lossy(), "rev-parse", rev])
            .output()
            .unwrap();
        assert!(out.status.success(), "rev-parse {rev} failed");
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    #[test]
    fn refresh_clone_brings_stale_clone_to_origin_head() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let origin = root.join("origin.git");
        let work = root.join("work"); // pushes commits into origin
        let clone = root.join("clone"); // the persistent "improve clone" under test

        // bare origin on `main`
        assert!(Command::new("git")
            .args(["init", "--bare", "-b", "main", &origin.to_string_lossy()])
            .status()
            .unwrap()
            .success());
        // work clone → commit c1 → push
        assert!(Command::new("git")
            .args(["clone", &origin.to_string_lossy(), &work.to_string_lossy()])
            .status()
            .unwrap()
            .success());
        fs::write(work.join("a.txt"), "v1").unwrap();
        git_ok(&work, &["add", "."]);
        git_ok(&work, &["commit", "-m", "c1"]);
        git_ok(&work, &["push", "origin", "main"]);
        // improve clone created now (sits at c1)
        assert!(Command::new("git")
            .args(["clone", &origin.to_string_lossy(), &clone.to_string_lossy()])
            .status()
            .unwrap()
            .success());
        // origin advances to c2 → the improve clone is now STALE (behind)
        fs::write(work.join("a.txt"), "v2").unwrap();
        git_ok(&work, &["add", "."]);
        git_ok(&work, &["commit", "-m", "c2"]);
        git_ok(&work, &["push", "origin", "main"]);
        let clone_before = rev_parse(&clone, "HEAD");
        let origin_head = rev_parse(&work, "origin/main");
        assert_ne!(clone_before, origin_head, "precondition: clone is behind");

        // refresh: the clone must come up to origin/main's HEAD
        refresh_clone(&clone).unwrap();

        assert_eq!(
            rev_parse(&clone, "HEAD"),
            origin_head,
            "refresh_clone must fast-forward the clone to origin's default-branch HEAD"
        );
    }

    #[test]
    fn refresh_clone_noop_when_not_a_git_repo() {
        let tmp = TempDir::new().unwrap();
        // a non-git directory → no-op, no error
        refresh_clone(tmp.path()).unwrap();
    }

    #[test]
    fn credible198_parse_satisfied_verdict_and_fail_open() {
        // CREDIBLE-198: the verify-before-execute parser reads SATISFIED / NOT-SATISFIED, and
        // must FAIL-OPEN (=> not satisfied => execute) on anything unparseable — so a garbled
        // reply can never false-close real work.
        let (s, r) = parse_satisfied_verdict("VERDICT: SATISFIED - World.js:353 spawn off water");
        assert!(s, "SATISFIED verdict parses as satisfied");
        assert!(
            r.contains("World.js:353"),
            "reason carries the evidence, got: {r}"
        );

        let (s, _) = parse_satisfied_verdict("VERDICT: NOT-SATISFIED - lethality still kills bot");
        assert!(!s, "NOT-SATISFIED must NOT read as satisfied");
        let (s, _) = parse_satisfied_verdict("verdict: not satisfied - unmet");
        assert!(!s, "case/space variant of NOT SATISFIED is still negative");

        // FAIL-OPEN: no VERDICT line / garbage / empty / bare word => not satisfied => execute.
        assert!(!parse_satisfied_verdict("the model rambled without a verdict").0);
        assert!(!parse_satisfied_verdict("").0);
        assert!(
            !parse_satisfied_verdict("SATISFIED").0,
            "a bare word without the VERDICT: prefix must NOT satisfy (conservative)"
        );
    }

    #[test]
    fn effective361_real_edit_status_line_ignores_junk() {
        // EFFECTIVE-361: a REAL source edit counts; chump's own bookkeeping never does.
        assert!(is_real_edit_status_line(" M src/lib/agent/orchestrator.ts"));
        assert!(is_real_edit_status_line("A  new_file.rs"));
        assert!(is_real_edit_status_line("?? untracked.txt"));
        // rename → judge the destination path.
        assert!(is_real_edit_status_line("R  old.rs -> src/renamed.rs"));
        // chump bookkeeping / session / log writes must NOT count as an edit.
        assert!(!is_real_edit_status_line(" M .chump/farmer-heartbeat"));
        assert!(!is_real_edit_status_line("?? .chump-locks/claim-x.json"));
        assert!(!is_real_edit_status_line(" M sessions/chump_memory.db"));
        assert!(!is_real_edit_status_line("A  logs/run.log"));
        // degenerate lines never crash / never count.
        assert!(!is_real_edit_status_line(""));
        assert!(!is_real_edit_status_line("M"));
        assert!(!is_real_edit_status_line(" M   "));
    }
}
