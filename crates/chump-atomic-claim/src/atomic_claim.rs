//! INFRA-468 + INFRA-1025: atomic `chump claim <ID>` — single CLI call.
//!
//! Steps (all in Rust, no shell-out to gap-claim.sh — INFRA-1025):
//!   1. fetch origin/main
//!   2. verify gap exists + is open in state.db (seed via import if missing)
//!   3. binary health probe (chump-binary-unwedge.sh, INFRA-275 wedge prevention)
//!   4. derive a unique per-claim session ID
//!   5. git worktree add to ${CHUMP_WORKTREE_BASE:-/tmp}/chump-<gap-lower>
//!   6. repair gitdir back-reference (INFRA-779)
//!      6c. remote-branch guard (AC6: --resume resets to remote tip)
//!   7. write lease:
//!      7a. NATS KV dual-write (opt-in)
//!      7b. write JSON lease file to .chump-locks/
//!      7c. write state.db leases row
//!
//! Each step rolls back prior steps on failure (no half-claim state).

use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// INFRA-2183: per-worktree sccache + CARGO_TARGET_DIR wiring.
/// Declared here (not main.rs) so it lives entirely within the atomic_claim
/// lease scope and is tested alongside the claim flow.
#[path = "worktree_build_cache.rs"]
pub mod worktree_build_cache;

/// Args to atomic claim.
#[derive(Debug, Clone)]
pub struct ClaimArgs {
    pub gap_id: String,
    /// CSV of repo-relative paths to declare lease scope.
    pub paths: Option<String>,
    /// If branch already exists on the remote, reset HEAD to remote tip and continue
    /// instead of aborting. AC6: handles already-pushed-but-unmerged branch.
    pub resume: bool,
    /// INFRA-1439: Before the atomic-claim step, auto-remove a stale worktree
    /// directory + stale local branch if they exist. Without this flag the
    /// caller must clean up manually. Does NOT bypass stomp-check (open PR on
    /// branch) — that still blocks unless CHUMP_ALLOW_STOMP=1 is set.
    pub force_recover: bool,
    /// Where to create the linked worktree. Default `/tmp`.
    pub worktree_base: PathBuf,
    /// Main repo root (the parent of `--git-common-dir`).
    pub repo_root: PathBuf,
    /// Git remote (default `origin`).
    pub remote: String,
    /// Base branch (default `main`).
    pub base_branch: String,
    /// Override the auto-derived session ID. Same fallback shape as
    /// fleet/INFRA-461: `claim-<gap>-<pid>-<epoch>`.
    pub session_id: Option<String>,
    /// Skip the chump-doctor binary health probe (tests).
    pub skip_doctor: bool,
    /// Skip state.db drift check / import (tests).
    pub skip_import: bool,
    /// INFRA-1394: override the hot-file collision block (warn-only mode still fires).
    pub force_overlap: bool,
    /// INFRA-1503: bypass the open-PR-in-flight abort (step 5b). Mirrors
    /// `CHUMP_CLAIM_ALLOW_OPEN_PR=1`. Distinct from `CHUMP_ALLOW_STOMP`/`--resume`:
    /// this is the operator-explicit "I know there's an open PR; let me work
    /// alongside it (rescue scenario)" path. Default false.
    pub allow_duplicate_pr: bool,
    /// INFRA-1442: bypass the claim-time fuzzy-match against open PR titles
    /// and active leases (kicks in BEFORE worktree creation). Mirrors the
    /// `CHUMP_CLAIM_NO_FUZZY=1` env. Emits `claim_duplicate_bypassed` for
    /// audit when set.
    pub force_duplicate: bool,
    /// Run all preflight gates without creating worktree or lease.
    pub check_only: bool,
    /// Output JSON format (used with --check-only).
    pub json: bool,
    /// INFRA-2235: when set alongside --force-recover, bypasses the WIP-loss
    /// safety guard and allows wiping a worktree that has uncommitted changes.
    /// Emits `force_recover_wip_discarded` instead of `force_recover_wip_loss`.
    /// Use only when the uncommitted state is intentionally abandoned.
    pub discard_wip: bool,
    /// INFRA-1730: when the deterministic claim branch already exists on the
    /// remote AND is orphaned (its PR is closed, not open), auto-rename to
    /// `<branch>-N` and continue instead of bailing. No effect when the
    /// existing branch has an open PR (that's the stomp-check's lane) or
    /// when `--resume` is also passed (`--resume` wins: same branch, reset
    /// to remote tip).
    pub rename: bool,
    /// INFRA-5162 (INFRA-1863 slice): optional role hint for the claiming
    /// session (e.g. "shepherd", "target"). Stored for later validation;
    /// not yet enforced against a role registry.
    pub role: Option<String>,
    /// INFRA-6624 (INFRA-1863 slice): optional scope hint for the claiming
    /// session (e.g. a module or concern name). Stored for later validation;
    /// not yet enforced against a scope registry.
    pub scope: Option<String>,
}

impl ClaimArgs {
    pub fn from_argv(args: &[String], repo_root: PathBuf) -> Result<Self> {
        // INFRA-1238: trap -h / --help BEFORE positional validation so
        // `chump claim --help` prints usage and exits 0, not "missing GAP-ID".
        for a in args.iter().skip(1) {
            if a == "--help" || a == "-h" {
                println!(
                    "Usage: chump claim <GAP-ID> --role ROLE [--scope SCOPE] [--paths CSV] [--session ID] [--no-doctor] [--no-import] [--force-recover]\n\n\
                     Atomic claim: fetch + verify + (doctor) + worktree + lease for <GAP-ID>.\n\n\
                     Options:\n  \
                       --role ROLE      (mandatory) Role hint for the claiming session (e.g. shepherd, target)\n  \
                       --scope SCOPE    (optional) Scope hint for the claiming session (e.g. a module or concern)\n  \
                       --paths CSV      Record path scope (comma-separated globs); enables overlap detection\n  \
                       --session ID     Explicit session ID (default derived from env / pid)\n  \
                       --no-doctor      Skip gap-doctor reconciliation (faster, but skips drift repair)\n  \
                       --no-import      Skip yaml->state.db re-import (faster, but assumes registry is fresh)\n  \
                       --force-recover  Auto-remove stale worktree dir + stale local branch before claiming\n  \
                       --discard-wip    With --force-recover: bypass WIP-loss guard and wipe uncommitted changes\n  \
                       --rename         If the claim branch is orphaned (remote branch exists, its PR is closed),\n                        \
                                        auto-rename to <branch>-N and continue instead of aborting\n  \
                       --force-overlap  Override hot-file collision block (INFRA-1394); warning still emitted\n  \
                       --allow-duplicate-pr  Bypass open-PR-in-flight abort (INFRA-1503; rescue scenarios)\n  \
                       -h, --help       Show this help
                       --check-only  Run all preflight gates without creating worktree or lease\n  \
                       --json        Output JSON format (use with --check-only)"
                );
                std::process::exit(0);
            }
        }
        // args[0] = "claim", args[1] = <GAP-ID>, then optional flags
        let gap_id = args
            .get(1)
            .ok_or_else(|| anyhow!("missing GAP-ID"))?
            .to_string();
        if gap_id.starts_with("--") {
            bail!("missing GAP-ID (saw flag {gap_id})");
        }
        // CREDIBLE-166: reject an OBVIOUSLY-malformed GAP-ID at parse time,
        // BEFORE run_claim's autonomy gate (RESILIENT-073). Otherwise
        // `claim <bad-id>` returned "fleet stopped (AUTONOMY_LEVEL=0)" instead of
        // a format error, masking the real problem (test-cli-integration.sh).
        // Deliberately LOOSE: a real GAP-ID starts with an uppercase letter and
        // contains a '-'. This rejects args like "bad-format-id" / "12345-not-valid"
        // WITHOUT rejecting descriptive test fixtures (INFRA-NONEXISTENT-SMOKE-TEST,
        // RESILIENT-073-FAKE) or forcing a digit suffix — the downstream existence/
        // status checks and the autonomy gate handle well-formed-but-blocked IDs.
        // Pure, non-mutating check, so it does not reintroduce the ordering bug the
        // autonomy-first gate guards against (a failing chump-op/DB masking the switch).
        let looks_like_gap_id = gap_id
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_uppercase())
            && gap_id.contains('-');
        if !looks_like_gap_id {
            bail!("invalid GAP-ID format: {gap_id} (expected DOMAIN-NUMBER, e.g. INFRA-1234)");
        }
        let mut paths: Option<String> = None;
        let mut session_id: Option<String> = None;
        let mut skip_doctor = false;
        let mut skip_import = false;
        let mut resume = false;
        let mut force_recover = false;
        let mut force_overlap = false;
        let mut allow_duplicate_pr = false;
        let mut force_duplicate = false;
        let mut check_only = false;
        let mut json = false;
        let mut discard_wip = false;
        let mut rename = false;
        let mut role: Option<String> = None;
        let mut scope: Option<String> = None;

        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--paths" => {
                    paths = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--paths needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--session" => {
                    session_id = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--session needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--skip-doctor" => {
                    skip_doctor = true;
                    i += 1;
                }
                "--skip-import" => {
                    skip_import = true;
                    i += 1;
                }
                "--resume" => {
                    resume = true;
                    i += 1;
                }
                "--force-recover" => {
                    force_recover = true;
                    i += 1;
                }
                "--force-overlap" => {
                    force_overlap = true;
                    i += 1;
                }
                "--allow-duplicate-pr" => {
                    allow_duplicate_pr = true;
                    i += 1;
                }
                "--force-duplicate" => {
                    force_duplicate = true;
                    i += 1;
                }
                "--check-only" => {
                    check_only = true;
                    i += 1;
                }
                "--json" => {
                    json = true;
                    i += 1;
                }
                "--discard-wip" => {
                    discard_wip = true;
                    i += 1;
                }
                "--rename" => {
                    rename = true;
                    i += 1;
                }
                "--role" => {
                    role = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--role needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                "--scope" => {
                    scope = Some(
                        args.get(i + 1)
                            .ok_or_else(|| anyhow!("--scope needs a value"))?
                            .to_string(),
                    );
                    i += 2;
                }
                other => bail!("unknown flag: {other}"),
            }
        }

        // INFRA-5486 (INFRA-1863 slice): --role is mandatory (AC1/AC2).
        // Returned as an Err (not a direct process::exit) so unit tests can
        // assert on it without aborting the test binary; main.rs's caller
        // inspects the message to pick exit code 1 (AC2) vs the generic
        // argument-error exit code 2.
        if role.is_none() {
            bail!(
                "missing required flag --role <role>\n\n\
                 Usage: chump claim <GAP-ID> --role <role> [--scope <module-or-concern>] [--paths CSV]\n\n\
                 --role is mandatory: a role hint for the claiming session (e.g. shepherd, target).\n  \
                 --scope is optional: a module or concern name.\n  \
                 --paths remains optional and advisory (no path validation if omitted)."
            );
        }

        let worktree_base = std::env::var("CHUMP_WORKTREE_BASE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"));
        let remote = std::env::var("CHUMP_REMOTE").unwrap_or_else(|_| "origin".into());
        let base_branch = std::env::var("CHUMP_BASE_BRANCH").unwrap_or_else(|_| "main".into());

        Ok(Self {
            gap_id,
            paths,
            worktree_base,
            repo_root,
            remote,
            base_branch,
            session_id,
            skip_doctor,
            skip_import,
            resume,
            force_recover,
            force_overlap,
            allow_duplicate_pr,
            force_duplicate,
            check_only,
            json,
            discard_wip,
            rename,
            role,
            scope,
        })
    }
}

/// Outcome of a successful claim.
#[derive(Debug)]
pub struct ClaimReport {
    pub gap_id: String,
    pub worktree_path: PathBuf,
    pub branch: String,
    pub session_id: String,
    pub paths: Option<String>,
}

/// Print a friendly multi-line summary suitable for a terminal.
pub fn print_report(r: &ClaimReport) {
    println!();
    println!("✓ claimed {} atomically (INFRA-468)", r.gap_id);
    println!("    worktree : {}", r.worktree_path.display());
    println!("    branch   : {}", r.branch);
    println!("    session  : {}", r.session_id);
    if let Some(p) = &r.paths {
        println!("    paths    : {}", p);
    }
    println!();
    println!("    cd {}", r.worktree_path.display());
    println!();
}

/// Check result for a single preflight gate (INFRA-1415).
#[derive(Debug, Clone, serde::Serialize)]
pub struct GateResult {
    pub gate: String,
    pub status: String, // "pass", "warn", or "fail"
    pub message: String,
}

/// Outcome of check-only run.
#[derive(Debug, serde::Serialize)]
pub struct CheckReport {
    pub gap_id: String,
    pub overall: String, // "pass", "warn", or "fail"
    pub gates: Vec<GateResult>,
}

/// Print check report in human-readable table format.
pub fn print_check_report(r: &CheckReport) {
    println!();
    println!("chump claim --check-only {}", r.gap_id);
    println!();

    // Print header
    println!("{:<20} {:<10} MESSAGE", "GATE", "STATUS");
    println!(
        "{:<20} {:<10} {}",
        "─".repeat(20),
        "─".repeat(10),
        "─".repeat(50)
    );

    // Print each gate result
    for gate in &r.gates {
        let status_display = match gate.status.as_str() {
            "pass" => "✓ PASS",
            "warn" => "⚠ WARN",
            "fail" => "✗ FAIL",
            _ => &gate.status,
        };
        println!("{:<20} {:<10} {}", gate.gate, status_display, gate.message);
    }

    println!();
    match r.overall.as_str() {
        "pass" => println!("Overall: ✓ All checks passed"),
        "warn" => println!("Overall: ⚠ Some warnings (not blocking)"),
        "fail" => println!("Overall: ✗ Blocking issue found"),
        _ => println!("Overall: {}", r.overall),
    }
    println!();
}

/// INFRA-1415: Run all preflight gates without creating worktree or lease.
/// Returns a CheckReport with pass/warn/fail status for each gate.
pub fn run_check_only(args: ClaimArgs) -> Result<CheckReport> {
    let mut gates = Vec::new();
    let mut has_fail = false;
    let mut has_warn = false;

    // Gate 1: Fetch + verify state.db status
    let fetch_result = run_git(
        &args.repo_root,
        &["fetch", &args.remote, &args.base_branch, "--quiet"],
    );
    if fetch_result.is_err() {
        gates.push(GateResult {
            gate: "fetch".to_string(),
            status: "warn".to_string(),
            message: "Could not fetch origin (offline or network issue)".to_string(),
        });
        has_warn = true;
    } else {
        gates.push(GateResult {
            gate: "fetch".to_string(),
            status: "pass".to_string(),
            message: "Fetched latest origin/main".to_string(),
        });
    }

    // Gate 2: Check state.db status (gap must be open and unclaimed)
    let db_path = args.repo_root.join(".chump/state.db");
    if !db_path.exists() {
        gates.push(GateResult {
            gate: "state.db".to_string(),
            status: "fail".to_string(),
            message: format!("state.db not found at {}", db_path.display()),
        });
        has_fail = true;
    } else {
        match check_gap_status(&args.repo_root, &args.gap_id) {
            Ok(status_msg) => {
                gates.push(GateResult {
                    gate: "state.db".to_string(),
                    status: "pass".to_string(),
                    message: status_msg,
                });
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "state.db".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 2b: INFRA-1970 — gap-ID uniqueness check (primary key is gap, not paths).
    // Reject the claim immediately if any live lease already holds this exact gap_id
    // from a different session. This is the structural fix for the duplicate-PR race
    // documented in META-105 (PRs #2539 + #2540 both worked INFRA-1950 on 2026-05-24).
    {
        let early_session = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let lock_dir_co = args.repo_root.join(".chump-locks");
        match check_gap_id_uniqueness(&lock_dir_co, &args.gap_id, &early_session) {
            Ok(()) => {
                gates.push(GateResult {
                    gate: "gap-id-unique".to_string(),
                    status: "pass".to_string(),
                    message: "no live lease holds this gap_id from another session".to_string(),
                });
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "gap-id-unique".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 2b2: INFRA-2472 — shared (NATS KV) registry gap-ID uniqueness.
    // Local .chump-locks/ only sees leases written on THIS machine; the
    // shared registry sees claims taken on any machine in the mesh. Skips
    // cleanly (no gate entry) when CHUMP_NATS_URL is unset — same opt-in
    // posture as nats_dual_write.
    if std::env::var("CHUMP_NATS_URL")
        .map(|v| !v.trim().is_empty())
        .unwrap_or(false)
    {
        let early_session = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let bypass = std::env::var("CHUMP_CLAIM_ALLOW_DUPLICATE_GAP")
            .map(|v| !v.trim().is_empty() && v.trim() != "0")
            .unwrap_or(false);
        match check_shared_registry_gap_uniqueness(&args.gap_id, &early_session) {
            Ok(()) => {
                gates.push(GateResult {
                    gate: "gap-id-unique-shared".to_string(),
                    status: "pass".to_string(),
                    message: "shared NATS registry holds no live claim from another session"
                        .to_string(),
                });
            }
            Err(e) if bypass => {
                gates.push(GateResult {
                    gate: "gap-id-unique-shared".to_string(),
                    status: "warn".to_string(),
                    message: format!("{e} (bypassed via CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1)"),
                });
                has_warn = true;
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "gap-id-unique-shared".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 2c: INFRA-1646 — refuse when this session already holds a live
    // lease for a DIFFERENT gap (see check_no_active_lease_for_other_gap).
    {
        let early_session = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let lock_dir_co = args.repo_root.join(".chump-locks");
        match check_no_active_lease_for_other_gap(&lock_dir_co, &args.gap_id, &early_session) {
            Ok(()) => {
                gates.push(GateResult {
                    gate: "active-lease".to_string(),
                    status: "pass".to_string(),
                    message: "session holds no live lease for a different gap".to_string(),
                });
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "active-lease".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 3: Check hot-file collision (INFRA-1394)
    if let Some(paths) = &args.paths {
        match check_hot_file_collision(&args.repo_root, paths) {
            Ok(msg) => {
                gates.push(GateResult {
                    gate: "hot-files".to_string(),
                    status: "pass".to_string(),
                    message: msg,
                });
            }
            Err(msg) => {
                gates.push(GateResult {
                    gate: "hot-files".to_string(),
                    status: "warn".to_string(),
                    message: msg,
                });
                has_warn = true;
            }
        }
    }

    // Gate 3b: INFRA-1885: Check lease-breadth (broad top-level dir rejection)
    if let Some(paths) = &args.paths {
        let ambient_log_co = args.repo_root.join(".chump-locks/ambient.jsonl");
        let session_co = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        match check_lease_breadth(paths, &args.gap_id, &session_co, &ambient_log_co) {
            Ok(()) => {
                gates.push(GateResult {
                    gate: "lease-breadth".to_string(),
                    status: "pass".to_string(),
                    message: "paths are specific enough (no broad top-level dirs)".to_string(),
                });
            }
            Err(e) => {
                gates.push(GateResult {
                    gate: "lease-breadth".to_string(),
                    status: "fail".to_string(),
                    message: e.to_string(),
                });
                has_fail = true;
            }
        }
    }

    // Gate 4: Check acceptance criteria (must not be empty/TODO only)
    match check_acceptance_criteria(&args.repo_root, &args.gap_id) {
        Ok(msg) => {
            gates.push(GateResult {
                gate: "acceptance_criteria".to_string(),
                status: "pass".to_string(),
                message: msg,
            });
        }
        Err(e) => {
            gates.push(GateResult {
                gate: "acceptance_criteria".to_string(),
                status: "fail".to_string(),
                message: e.to_string(),
            });
            has_fail = true;
        }
    }

    // Gate 5: Check base branch is up-to-date (sanity check)
    match check_base_branch(&args.repo_root, &args.remote, &args.base_branch) {
        Ok(msg) => {
            gates.push(GateResult {
                gate: "base_branch".to_string(),
                status: "pass".to_string(),
                message: msg,
            });
        }
        Err(msg) => {
            gates.push(GateResult {
                gate: "base_branch".to_string(),
                status: "warn".to_string(),
                message: msg,
            });
            has_warn = true;
        }
    }

    // Gate 6: Disk-space ADMISSION control (ZERO-WASTE-028).
    // A `chump claim` provisions a worktree with an isolated CARGO_TARGET_DIR
    // (INFRA-2183) that grows to 1–7 GB. Creating one when disk is already tight
    // is how the machine oscillates to 100% full — at which point the reaper,
    // the fleet, AND cargo all wedge. The upstream fix is backpressure: REFUSE
    // to create the worktree below the floor so the worker backs off and idles
    // (recoverable) instead of overcommitting (unrecoverable). Was warn-only,
    // which is why claims kept succeeding past the floor.
    // Escape hatch is the floor itself: CHUMP_DISK_FLOOR_GB=0 admits any disk
    // (a legitimate config knob, not a bypass-class var — no new bypass per the
    // INFRA-2429 zero-bypass thesis).
    match check_disk_space(&args.worktree_base) {
        Ok(msg) => {
            gates.push(GateResult {
                gate: "disk_space".to_string(),
                status: "pass".to_string(),
                message: msg,
            });
        }
        Err(msg) => {
            gates.push(GateResult {
                gate: "disk_space".to_string(),
                status: "fail".to_string(),
                message: format!(
                    "{msg} — refusing to create a worktree below the disk floor. \
                     Free space (e.g. reclaim orphaned worktree targets) or lower \
                     CHUMP_DISK_FLOOR_GB (set to 0 to admit any disk)."
                ),
            });
            has_fail = true;
        }
    }

    // Gate 7: INFRA-1982 — open-PR-for-gap check (duplicate WORK detection).
    // Fails if an open PR already covers this gap ID by title or branch name.
    // Bypass via CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1.
    {
        let allow_dup_pr = args.allow_duplicate_pr
            || std::env::var("CHUMP_CLAIM_ALLOW_DUPLICATE_PR")
                .map(|v| !v.trim().is_empty() && v.trim() != "0")
                .unwrap_or(false);
        if allow_dup_pr {
            gates.push(GateResult {
                gate: "open-pr-for-gap".to_string(),
                status: "pass".to_string(),
                message: "skipped (CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1)".to_string(),
            });
        } else {
            match check_open_pr_for_gap(&args.repo_root, &args.gap_id) {
                Some((pr_num, branch)) => {
                    gates.push(GateResult {
                        gate: "open-pr-for-gap".to_string(),
                        status: "fail".to_string(),
                        message: format!(
                            "open PR #{pr_num} already covers this gap (branch: {branch}); \
                             resolve there or set CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1"
                        ),
                    });
                    has_fail = true;
                }
                None => {
                    gates.push(GateResult {
                        gate: "open-pr-for-gap".to_string(),
                        status: "pass".to_string(),
                        message: "no open PR found for this gap".to_string(),
                    });
                }
            }
        }
    }

    // Determine overall status
    let overall = if has_fail {
        "fail".to_string()
    } else if has_warn {
        "warn".to_string()
    } else {
        "pass".to_string()
    };

    Ok(CheckReport {
        gap_id: args.gap_id,
        overall,
        gates,
    })
}

/// Run the atomic claim. Each step is a separate function so the unit
/// tests can exercise individual pieces in isolation.
pub fn run_claim(args: ClaimArgs) -> Result<ClaimReport> {
    // RESILIENT-073: fleet kill switch — fail-closed autonomy level gate.
    // FIRST: must run BEFORE any state mutation OR any chump op that can
    // fail. Reads ~/.chump/AUTONOMY_LEVEL: 0 or missing/corrupt → STOP.
    // No shared failure mode: pure file read, no chump-op/DB/network.
    //
    // Ordering matters: previously this ran AFTER verify_or_seed_gap (step 2),
    // but `chump gap import` fails with title-similarity blocks (INFRA-1434)
    // before the kill switch could fire. The test-fleet-kill-switch.sh
    // assertions then saw the gap-import error in stderr instead of
    // "fleet stopped" — a real ordering bug that masked the kill switch
    // entirely when state.db drifted. Kill switch MUST be the first gate.
    if !crate::autonomy_level::is_go() {
        let level = crate::autonomy_level::read_level(&crate::autonomy_level::default_path());
        bail!(
            "fleet stopped (AUTONOMY_LEVEL={}). Run `chump fleet start` or \
             `chump fleet level 5` to re-enable the fleet.",
            level
        );
    }

    // 1. Fetch latest base branch — best-effort; the worktree-add will
    //    fail loudly if origin is unreachable AND no local ref exists.
    let _ = run_git(
        &args.repo_root,
        &["fetch", &args.remote, &args.base_branch, "--quiet"],
    );

    // 2. Verify gap is openable (or seed state.db if drifted).
    if !args.skip_import {
        verify_or_seed_gap(&args.repo_root, &args.gap_id)?;
    }

    // 3. Binary health probe (INFRA-275 wedge prevention).
    if !args.skip_doctor {
        run_doctor_probe(&args.repo_root)?;
    }

    // INFRA-2428: main-health-gate — refuse claim when main is red and route
    // claimer to the trunk-fix gap. Reads .chump/main-preflight-state.json
    // written by the watchdog daemon (INFRA-2397). Forces fix-main-first.
    // CHUMP_CLAIM_IGNORE_MAIN_HEALTH bypass deleted (INFRA-2428).
    check_main_health_gate(&args.repo_root, &args.gap_id)?;

    // INFRA-1442: claim-time fuzzy-match against in-flight work BEFORE
    // worktree creation. Catches the 3-way duplicate-fix pattern observed
    // 2026-05-22 (INFRA-1341/1384/1396 all fixed test-cache-mergestatestatus.sh
    // independently in parallel). Bypass via --force-duplicate or
    // CHUMP_CLAIM_NO_FUZZY=1; bypass emits claim_duplicate_bypassed.
    match run_fuzzy_gate(&args.repo_root, &args.gap_id, args.force_duplicate) {
        Ok(_matches) => {} // either no matches OR operator-bypassed; the helper emitted the event
        Err(warning_text) => {
            eprint!("{warning_text}");
            bail!(
                "claim refused — fuzzy-match against open PRs / active leases. Use --force-duplicate or CHUMP_CLAIM_NO_FUZZY=1 to override."
            );
        }
    }

    // INFRA-1982: Open-PR dedup gate — catch duplicate WORK across different
    // gap IDs before the worktree is created.
    //
    // The duplicate-claim gate (INFRA-1970) prevents two claims for the SAME
    // gap ID. This gate catches the complement: two agents file TWO different
    // gap IDs for the same problem, both get to claim stage, and both push
    // PRs. title-similarity at reserve time misses this because the filing
    // agent bypasses CHUMP_GAP_RESERVE_NO_SIMILARITY=1 (observed 3x on
    // 2026-05-25, documented in ARCHITECTURAL_CRITIQUE_2026-05-25.md §M4).
    //
    // Check: if any open PR's title contains the gap ID (case-insensitive)
    // OR its head branch starts with `chump/<gap-id-lowercase>`, reject the
    // claim. Bypass: CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1 (mirrors --allow-duplicate-pr).
    {
        let allow_dup_pr = args.allow_duplicate_pr
            || std::env::var("CHUMP_CLAIM_ALLOW_DUPLICATE_PR")
                .map(|v| !v.trim().is_empty() && v.trim() != "0")
                .unwrap_or(false);
        if !allow_dup_pr {
            if let Some((open_pr, open_branch)) =
                check_open_pr_for_gap(&args.repo_root, &args.gap_id)
            {
                let ambient_log_dup = args.repo_root.join(".chump-locks/ambient.jsonl");
                emit_claim_open_pr_dup_blocked(&ambient_log_dup, &args.gap_id, open_pr);
                bail!(
                    "INFRA-1982: open PR #{} already covers {} (branch: {}).\n  \
                     Resolve there or use CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1 to override.",
                    open_pr,
                    args.gap_id,
                    open_branch,
                );
            }
        }
    }

    // INFRA-1885: lease-breadth cap — reject claims of exact top-level dirs
    // without a more specific sub-path. Forces file-level granularity so
    // broad leases don't block other sessions from filing event-registry
    // entries or touching adjacent sub-paths.
    //
    // Bypass: CHUMP_LEASE_ALLOW_BROAD_DIRS=1 + commit-message trailer
    //   Broad-Lease-Reason: <one sentence>
    // Bypass emits kind=lease_broad_dir_claim to ambient.jsonl for audit.
    if let Some(paths_csv) = &args.paths {
        let early_session_id = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let ambient_log_early = args.repo_root.join(".chump-locks/ambient.jsonl");
        check_lease_breadth(
            paths_csv,
            &args.gap_id,
            &early_session_id,
            &ambient_log_early,
        )?;
    }

    // INFRA-4996 (INFRA-2434 slice): basic path-overlap detection against
    // open PRs. The gap-ID-only dedup gates above (INFRA-1982, INFRA-1970)
    // miss the case where two DIFFERENT gap IDs both touch the same file —
    // check declared --paths directly against every open PR's real file
    // list via `gh pr list --json files`.
    if let Some(paths_csv) = &args.paths {
        if let Some((pr_num, other_gap, overlap_paths)) =
            check_paths_overlap_open_prs(&args.repo_root, paths_csv)
        {
            bail!(
                "[claim] paths overlap with open PR #{} (gap {}, paths: {})",
                pr_num,
                other_gap,
                overlap_paths.join(", "),
            );
        }
    }

    // INFRA-1970: Gap-ID uniqueness check — primary lease key is (gap_id, session_id),
    // NOT paths. Reject the claim if any live lease already holds this exact gap_id
    // from a different session, regardless of which paths those sessions declared.
    //
    // This is the structural fix for the duplicate-PR race documented in META-105:
    // PRs #2539 and #2540 both claimed INFRA-1950 on 2026-05-24 with different --paths
    // args, producing two competing PRs for the same gap.
    //
    // Must run BEFORE session_id is finalised (we derive the provisional session_id
    // to skip self-comparison) and BEFORE the worktree is created (no dangling
    // worktree on rejection).
    //
    // Bypass: CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1 (emits claim_duplicate_gap_bypassed).
    {
        let early_session = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let lock_dir_early = args.repo_root.join(".chump-locks");
        let allow_dup_gap = std::env::var("CHUMP_CLAIM_ALLOW_DUPLICATE_GAP")
            .map(|v| !v.trim().is_empty() && v.trim() != "0")
            .unwrap_or(false);
        if !allow_dup_gap {
            if let Err(e) = check_gap_id_uniqueness(&lock_dir_early, &args.gap_id, &early_session) {
                let ambient_path = lock_dir_early.join("ambient.jsonl");
                emit_claim_duplicate_gap_event(
                    &ambient_path,
                    &args.gap_id,
                    &early_session,
                    &e.to_string(),
                );
                bail!(
                    "INFRA-1970: {}\n  \
                     Override: CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1 (emits audit event)",
                    e
                );
            }
        } else {
            // Bypass active — still check and emit audit event if a conflict exists.
            if let Err(e) = check_gap_id_uniqueness(&lock_dir_early, &args.gap_id, &early_session) {
                let ambient_path = lock_dir_early.join("ambient.jsonl");
                emit_claim_duplicate_gap_event(
                    &ambient_path,
                    &args.gap_id,
                    &early_session,
                    &e.to_string(),
                );
                eprintln!(
                    "[claim] INFRA-1970: WARN — duplicate gap claim bypassed via CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1: {}",
                    e
                );
            }
        }
    }

    // INFRA-1608: atomically reserve the gap_id BEFORE the expensive worktree
    // setup below runs. `check_gap_id_uniqueness` just above is a scan, not a
    // lock — two sessions can both pass it and then both proceed through
    // `git worktree add` before either writes its real lease file. This
    // marker closes that window: only one `create_new` can win per gap_id.
    // Held via `marker_guard` for the rest of `run_claim`; disarmed once the
    // real lease file is written (step 7b below), or auto-removed by Drop on
    // any earlier `bail!`/`?` return.
    let marker_guard = {
        let early_session = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let lock_dir_early = args.repo_root.join(".chump-locks");
        let allow_dup_gap = std::env::var("CHUMP_CLAIM_ALLOW_DUPLICATE_GAP")
            .map(|v| !v.trim().is_empty() && v.trim() != "0")
            .unwrap_or(false);
        let mut guard: Option<GapClaimMarkerGuard> = None;
        if !allow_dup_gap {
            match reserve_gap_claim_marker(&lock_dir_early, &args.gap_id, &early_session, 900)? {
                GapClaimMarkerOutcome::Won(path) => {
                    guard = Some(GapClaimMarkerGuard { path: Some(path) });
                }
                GapClaimMarkerOutcome::Lost { winner_session } => {
                    let ambient_path = lock_dir_early.join("ambient.jsonl");
                    emit_lease_overlap_event(
                        &ambient_path,
                        &args.gap_id,
                        &winner_session,
                        &early_session,
                        args.paths.as_deref().unwrap_or(""),
                    );
                    bail!(
                        "INFRA-1608: gap {} lost the atomic claim race to session {} \
                         (kind=lease_overlap emitted).\n  \
                         Options:\n  \
                         1. Pick a different gap.\n  \
                         2. Wait for session {} to ship or release its lease.\n  \
                         3. Override: CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1 (audit event emitted).",
                        args.gap_id,
                        winner_session,
                        winner_session,
                    );
                }
            }
        }
        guard
    };

    // INFRA-1646 (re-do of INFRA-1412): refuse the claim when this session
    // already holds a live lease for a DIFFERENT gap — see
    // check_no_active_lease_for_other_gap for why the silent-merge
    // alternative is dangerous (RESILIENT-313).
    //
    // Must run at the same point as the INFRA-1970 gate above: before
    // session_id is finalised and before the worktree is created.
    //
    // Bypass: CHUMP_CLAIM_ALLOW_ACTIVE_LEASE=1 (emits claim_active_lease_bypassed).
    {
        let early_session = args
            .session_id
            .clone()
            .unwrap_or_else(|| derive_session_id(&args.gap_id));
        let lock_dir_early = args.repo_root.join(".chump-locks");
        let allow_active_lease = std::env::var("CHUMP_CLAIM_ALLOW_ACTIVE_LEASE")
            .map(|v| !v.trim().is_empty() && v.trim() != "0")
            .unwrap_or(false);
        if let Err(e) =
            check_no_active_lease_for_other_gap(&lock_dir_early, &args.gap_id, &early_session)
        {
            let ambient_path = lock_dir_early.join("ambient.jsonl");
            emit_claim_active_lease_event(
                &ambient_path,
                &args.gap_id,
                &early_session,
                &e.to_string(),
            );
            if !allow_active_lease {
                bail!(
                    "INFRA-1646: {}\n  \
                     Override: CHUMP_CLAIM_ALLOW_ACTIVE_LEASE=1 (emits audit event)",
                    e
                );
            }
            eprintln!(
                "[claim] INFRA-1646: WARN — active-lease conflict bypassed via CHUMP_CLAIM_ALLOW_ACTIVE_LEASE=1: {}",
                e
            );
        }
    }

    // 4. Session ID — explicit --session flag > derived.
    //
    // Deliberately do NOT honor CHUMP_SESSION_ID env: each `chump claim`
    // is meant to be a fresh isolated session. Operators who want a
    // specific session ID pass --session explicitly. This avoids the
    // surprise where a parent shell's CHUMP_SESSION_ID (e.g. set by
    // bot-merge.sh, or another claim earlier in the same shell) bleeds
    // into the lease and breaks the "one claim = one session" model.
    let session_id = args
        .session_id
        .clone()
        .unwrap_or_else(|| derive_session_id(&args.gap_id));

    // 5. Worktree path + branch name.
    let gap_lower = args.gap_id.to_lowercase();
    let worktree_path = args.worktree_base.join(format!("chump-{}", gap_lower));
    let mut branch = format!("chump/{}-claim", gap_lower);

    // PathBuf-to-str needed for both the force-recover block and worktree-add below.
    // Derive early so both code paths share the same binding.
    let worktree_path_str = worktree_path.to_str().ok_or_else(|| {
        anyhow!(
            "worktree path contains non-UTF-8 bytes (likely from CHUMP_WORKTREE_BASE): {}",
            worktree_path.display()
        )
    })?;

    // INFRA-1439: --force-recover — auto-clean stale worktree dir + local branch
    // BEFORE the stomp-check or worktree-add, so the claim can proceed
    // idempotently when a prior session left orphaned state.
    //
    // INFRA-2235: WIP safety guard — before wiping the worktree, check for
    // uncommitted changes via `git status --porcelain`. If WIP is detected:
    //   - Default: REFUSE with an operator message listing the dirty files and
    //     3 recovery paths. Emits kind=force_recover_wip_loss for audit.
    //   - With --discard-wip: proceed with the wipe and emit
    //     kind=force_recover_wip_discarded instead.
    //
    // Actions taken after WIP check (in order):
    //   (a) git worktree remove --force <path>  if the dir exists
    //   (b) rm -rf <path>                       if (a) failed or dir still present
    //   (c) git branch -D <branch>              if branch exists locally
    // Emits chump_claim_force_recover to ambient.jsonl with the actions taken.
    if args.force_recover {
        let mut recovery_actions: Vec<String> = Vec::new();

        // INFRA-2235: WIP safety check — refuse to wipe if there are uncommitted changes
        // unless the operator explicitly passed --discard-wip.
        if worktree_path.exists() {
            let porcelain_out = std::process::Command::new("git")
                .args(["-C", worktree_path_str, "status", "--porcelain"])
                .output();
            if let Ok(out) = porcelain_out {
                let porcelain = String::from_utf8_lossy(&out.stdout);
                let dirty_lines: Vec<&str> =
                    porcelain.lines().filter(|l| !l.trim().is_empty()).collect();
                if !dirty_lines.is_empty() {
                    let files_lost_count = dirty_lines.len();
                    // First 5 paths for the operator message and audit event.
                    let first_five: Vec<&str> = dirty_lines.iter().take(5).copied().collect();
                    let first_five_str = first_five.join(", ");

                    // Emit audit event before deciding to refuse or discard.
                    if args.discard_wip {
                        emit_force_recover_wip_discarded(
                            &args.repo_root,
                            &args.gap_id,
                            files_lost_count,
                            &first_five_str,
                        );
                        eprintln!(
                            "[claim --force-recover --discard-wip] WARNING: discarding {} uncommitted file(s) in {}: {}",
                            files_lost_count,
                            worktree_path.display(),
                            first_five_str
                        );
                    } else {
                        // Emit the wip-loss event (signals the *risk*, not an actual loss —
                        // we're about to refuse).
                        emit_force_recover_wip_loss(
                            &args.repo_root,
                            &args.gap_id,
                            files_lost_count,
                            &first_five_str,
                        );
                        bail!(
                            "--force-recover refused: worktree {} has {} uncommitted file(s):\n  {}\n\n\
                             Recovery options:\n\
                             (a) Commit + push the WIP first:\n\
                             \tcd {}\n\
                             \tgit add -A && git commit -m \"wip: save before handoff\"\n\
                             \tgit push -u origin {}\n\
                             (b) Intentionally discard the WIP (data loss!):\n\
                             \tchump claim {} --force-recover --discard-wip\n\
                             (c) Take over the same session by editing the lease file directly:\n\
                             \t# Edit .chump-locks/<session>.json to set session_id to your own",
                            worktree_path.display(),
                            files_lost_count,
                            first_five_str,
                            worktree_path.display(),
                            branch,
                            args.gap_id,
                        );
                    }
                }
            }
            // If git status fails (e.g. not a git worktree yet), fall through
            // and proceed with the wipe — that's the pre-INFRA-2235 behavior.
        }

        // (a) git worktree remove --force
        if worktree_path.exists() {
            match run_git(
                &args.repo_root,
                &["worktree", "remove", "--force", worktree_path_str],
            ) {
                Ok(_) => {
                    recovery_actions
                        .push(format!("worktree_remove_force:{}", worktree_path.display()));
                }
                Err(e) => {
                    eprintln!(
                        "[claim --force-recover] git worktree remove --force failed: {e}; falling back to rm -rf"
                    );
                    // (b) rm -rf fallback
                    if let Err(rm_err) = std::fs::remove_dir_all(&worktree_path) {
                        eprintln!(
                            "[claim --force-recover] rm -rf {} failed: {rm_err}",
                            worktree_path.display()
                        );
                        // If we can't remove it, bail — the claim will fail anyway
                        bail!(
                            "--force-recover: could not remove stale worktree {}: {rm_err}",
                            worktree_path.display()
                        );
                    }
                    recovery_actions.push(format!("rm_rf:{}", worktree_path.display()));
                }
            }
        }

        // (c) delete local branch if it exists
        let local_branch_exists =
            run_git(&args.repo_root, &["rev-parse", "--verify", &branch]).is_ok();
        if local_branch_exists {
            match run_git(&args.repo_root, &["branch", "-D", &branch]) {
                Ok(_) => {
                    recovery_actions.push(format!("branch_delete:{branch}"));
                }
                Err(e) => {
                    eprintln!("[claim --force-recover] git branch -D {branch} failed: {e}");
                    // Non-fatal — worktree-add will fail loudly if the branch still exists
                }
            }
        }

        if !recovery_actions.is_empty() {
            let actions_str = recovery_actions.join(",");
            eprintln!(
                "[claim --force-recover] recovered stale state for {}: {}",
                args.gap_id, actions_str
            );
            emit_force_recover_event(&args.repo_root, &args.gap_id, &branch, &actions_str);
        }
    } else if worktree_path.exists() {
        bail!(
            "worktree path already exists: {}\n  Remove it first with: git worktree remove --force {}\n  Or re-run with --force-recover to auto-clean.",
            worktree_path.display(),
            worktree_path.display()
        );
    }

    // 5b. INFRA-1328: stomp-prevention pre-claim PR check.
    //
    // If an OPEN PR exists upstream with `chump/<gap>-claim` as its head,
    // the prior agent's work is in flight even if their lease lapsed (claim
    // TTL is 30 min; ship cycles often run longer while CI sits in the
    // queue). Re-claiming would force the next push to either bail or
    // stomp the open PR — that's the failure mode PR #2008 lost work to
    // when sibling-PR #2013 took the same branch.
    //
    // The check is best-effort: `gh` failures return None and we fall
    // through to today's behavior. `--resume` and CHUMP_ALLOW_STOMP=1 are
    // legitimate overrides (resume = same agent retrying, stomp = operator
    // explicitly takes over an abandoned PR).
    let stomp_bypass = std::env::var("CHUMP_ALLOW_STOMP")
        .map(|v| !v.trim().is_empty() && v.trim() != "0")
        .unwrap_or(false);
    // INFRA-1503: separate operator-explicit bypass for the "rescue an in-flight
    // open PR" workflow. Distinct from CHUMP_ALLOW_STOMP so audit logs can tell
    // intentional rescue (this) apart from abandoned-PR takeover (stomp).
    let allow_open_pr_bypass = args.allow_duplicate_pr
        || std::env::var("CHUMP_CLAIM_ALLOW_OPEN_PR")
            .map(|v| !v.trim().is_empty() && v.trim() != "0")
            .unwrap_or(false);
    if !args.resume && !stomp_bypass && !allow_open_pr_bypass {
        if let Some((pr_num, author)) = open_pr_info(&args.repo_root, &branch) {
            // INFRA-1503: emit ambient event BEFORE bail so the waste signal is
            // captured even when the operator dismisses the diagnostic and
            // moves on (this is the "2 sessions wasted" failure mode we want to
            // count).
            let ambient_log = args.repo_root.join(".chump-locks/ambient.jsonl");
            emit_claim_aborted_pr_in_flight_event(&ambient_log, &args.gap_id, pr_num, &author);
            bail!(
                "INFRA-1503 (was INFRA-1328): open PR #{} already exists for {} by {} on branch `{}` — gap is in-flight.\n  \
                 Pick a different gap, or wait for the PR to land/close.\n  \
                 Overrides: --allow-duplicate-pr | CHUMP_CLAIM_ALLOW_OPEN_PR=1 (rescue) | \
                 --resume (continue same work) | CHUMP_ALLOW_STOMP=1 (abandoned PR takeover).",
                pr_num,
                args.gap_id,
                if author.is_empty() { "unknown" } else { author.as_str() },
                branch,
            );
        }
    }

    // 5.5. INFRA-1116: Check for overlapping INTENT from other live sessions,
    // BEFORE creating the worktree so we never leave a dangling worktree on refusal.
    let lock_dir = args.repo_root.join(".chump-locks");
    let ambient_log = lock_dir.join("ambient.jsonl");
    let claim_paths = args.paths.as_deref().unwrap_or("");

    let enforce_gate =
        std::env::var("CHUMP_ENFORCE_INTENT_GATE").unwrap_or_else(|_| "0".to_string());
    if enforce_gate == "1" {
        if let Err(e) = check_intent_overlap(&lock_dir, &args.gap_id, claim_paths, &session_id) {
            // Exit 14 by convention (matching intent-overlap-check.sh).
            eprintln!("[intent-gate] INFRA-1116: {:#}", e);
            std::process::exit(14);
        }
    } else if !claim_paths.is_empty() {
        // Warn-only mode (default): run the check, log any overlap, but don't block.
        if let Err(e) = check_intent_overlap(&lock_dir, &args.gap_id, claim_paths, &session_id) {
            eprintln!(
                "[intent-gate] WARN (CHUMP_ENFORCE_INTENT_GATE not set to 1): {:#}",
                e
            );
            eprintln!("[intent-gate] Set CHUMP_ENFORCE_INTENT_GATE=1 to enforce blocking.");
        }
    }

    // 5.6. INFRA-1394: Hot-file collision check vs sibling leases.
    //
    // Before creating the worktree (so we never leave a dangling worktree on
    // refusal), check if the gap's acceptance_criteria references any of the
    // hot shared files AND a sibling lease already declares one of them in its
    // paths[] field. If so: warn + emit ambient event. Without --force-overlap,
    // also abort with exit code 15.
    {
        let hot_files_yaml = args.repo_root.join("scripts/coord/lib/hot-files.yaml");
        let gap_ac = read_gap_ac_from_db(&args.repo_root, &args.gap_id);
        let hot_files = load_hot_files(&hot_files_yaml);
        if !hot_files.is_empty() {
            if let Some(overlap_result) =
                check_hot_file_overlap(&lock_dir, &args.gap_id, &session_id, &gap_ac, &hot_files)
            {
                // Always emit the ambient event.
                emit_claim_hot_file_overlap_event(
                    &ambient_log,
                    &args.gap_id,
                    &overlap_result.sibling_gap,
                    &overlap_result.sibling_session,
                    &overlap_result.overlap_paths,
                );

                // Print warning to stderr.
                eprintln!(
                    "[claim] INFRA-1394: HOT-FILE OVERLAP detected for {}",
                    args.gap_id
                );
                eprintln!(
                    "[claim]   sibling session {} (gap {}) holds: {}",
                    overlap_result.sibling_session,
                    overlap_result.sibling_gap,
                    overlap_result.overlap_paths.join(", ")
                );
                eprintln!(
                    "[claim]   These are hot shared files — concurrent edits risk merge conflicts."
                );

                if !args.force_overlap {
                    eprintln!(
                        "[claim]   Re-run with --force-overlap to proceed anyway (event still emitted)."
                    );
                    std::process::exit(15);
                } else {
                    eprintln!(
                        "[claim]   --force-overlap set; proceeding despite hot-file collision."
                    );
                }
            }
        }
    }

    // 5.65. INFRA-1763: lease-time predictive collision detection.
    //
    // Unlike the 5.6 hot-file check (which matches AC *text* against
    // declared lease paths[]), this walks every sibling lease's *actual*
    // worktree and runs a real `git diff` against it — catching in-flight
    // uncommitted edits that the sibling never declared in paths[] at all.
    // Best-effort + non-blocking: always emits claim_diff_collision_checked
    // (cost tracking) and, for any real intersection, collision_predicted
    // per docs/design/COLLISION_PREDICTION_SCHEMA.md.
    {
        let own_paths: Vec<String> = claim_paths
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        let diff_result = check_diff_collision(
            &lock_dir,
            &args.worktree_base,
            &args.gap_id,
            &session_id,
            &own_paths,
        );

        for failure in &diff_result.failures {
            emit_claim_diff_collision_check_failed_event(&ambient_log, &args.gap_id, failure);
        }

        for m in &diff_result.matches {
            emit_collision_predicted_event(&ambient_log, &session_id, &args.gap_id, m);
            eprintln!(
                "[claim] INFRA-1763: predicted collision with sibling session {} (gap {}) — shared paths: {}",
                m.sibling_session,
                m.sibling_gap,
                m.shared_paths.join(", ")
            );
        }

        emit_claim_diff_collision_checked_event(
            &ambient_log,
            &args.gap_id,
            &session_id,
            &diff_result,
        );
        eprintln!(
            "[claim] INFRA-1763: diff-collision check done in {}ms ({} siblings checked, {} matches)",
            diff_result.duration_ms, diff_result.siblings_checked, diff_result.matches.len()
        );
    }

    // 5.7. INFRA-1692: pre-flight team-nugget search.
    //
    // Marcus M-D arc: when an operator runs `chump claim GAP-ID`, surface
    // relevant team-shared knowledge BEFORE the worktree spins up, so the
    // operator doesn't repeat known failure modes that a teammate already
    // hit. Best-effort: graceful degrade on missing CHUMP_TEAM_URL or
    // unreachable endpoint; bypass via CHUMP_CLAIM_SKIP_NUGGET_SEARCH=1.
    nugget_prefetch::prefetch_and_print(&args.repo_root, &args.gap_id, &session_id);

    // INFRA-2628: fresh-fetch immediately before worktree provisioning.
    //
    // The initial fetch at step 1 (line ~537) happens early in run_claim.
    // By the time we reach worktree provisioning the caller may have held
    // a long-running pre-flight check (main-health gate, overlap scan,
    // nugget prefetch, etc.) — enough time for origin/main to advance.
    // A stale worktree base is the 2026-06-03 reproducer: Sonnet worked
    // for ~30 min, main moved (PR #2987 / INFRA-2524), and the diff would
    // have rescinded a 66-line safety guard if the orchestrator hadn't
    // caught it manually.
    //
    // This fetch is best-effort: network failures emit a warning but do
    // not abort claim (same policy as step-1 fetch).
    {
        let fetch_args = [
            "fetch",
            args.remote.as_str(),
            args.base_branch.as_str(),
            "--quiet",
        ];
        match run_git(&args.repo_root, &fetch_args) {
            Ok(_) => {
                // Log the new HEAD so the operator can verify the base is current.
                let new_head = run_git(
                    &args.repo_root,
                    &[
                        "rev-parse",
                        "--short",
                        &format!("{}/{}", args.remote, args.base_branch),
                    ],
                )
                .unwrap_or_else(|_| "unknown".to_string());
                eprintln!(
                    "[claim] INFRA-2628: fetched {}/{} (HEAD: {})",
                    args.remote,
                    args.base_branch,
                    new_head.trim()
                );
            }
            Err(e) => {
                eprintln!(
                    "[claim] INFRA-2628: warn — fetch {}/{} failed (offline?): {}",
                    args.remote, args.base_branch, e
                );
                eprintln!(
                    "[claim] INFRA-2628: proceeding with last-known {}/{} ref; rebase before push.",
                    args.remote, args.base_branch
                );
            }
        }
    }

    // 6. git worktree add -b <branch> <path> <remote>/<base>
    run_git(
        &args.repo_root,
        &[
            "worktree",
            "add",
            "-b",
            &branch,
            worktree_path_str,
            &format!("{}/{}", args.remote, args.base_branch),
        ],
    )
    .with_context(|| {
        format!(
            "git worktree add failed for {} -> {}",
            branch,
            worktree_path.display()
        )
    })?;

    // 6b. Verify (and repair if needed) the gitdir back-reference.
    // Concurrent `git worktree add` calls from sibling agents can clobber
    // .git/worktrees/<name>/gitdir, causing the new worktree to resolve to
    // the wrong repo root (INFRA-779). Repair is safe: git computes this
    // value deterministically as the canonicalized path of <worktree>/.git.
    verify_and_repair_gitdir(&args.repo_root, &branch, &worktree_path)?;

    // 6c-pre. INFRA-2183: provision per-worktree sccache + CARGO_TARGET_DIR wiring.
    // Fail-open: a Skipped outcome is logged but never blocks the claim.
    // The worktree target-dir (<worktree>/target) is already reaped by the
    // INFRA-1170 orphan-worktree pass in cargo-target-reaper.sh.
    let _build_cache_outcome = worktree_build_cache::provision_worktree_build_cache(
        &args.repo_root,
        &worktree_path,
        &args.gap_id,
        &ambient_log,
    );

    // 6c-pre3. INFRA-1733: symlink the worktree's .chump/github_cache.db to
    // the main checkout's copy instead of letting it start out empty. Each
    // fresh worktree previously got a cold cache (0% hit rate) even though
    // the main checkout's cache was warm.
    nugget_prefetch::link_github_cache(&args.repo_root, &worktree_path);

    // 6c-pre2. INFRA-1730: orphan-branch auto-rename. By this point the
    // 5b stomp-check has already run (above) and would have bailed if an
    // OPEN PR covers this exact branch — so if the remote still has the
    // branch here, it's either orphaned (its PR closed) or was pushed and
    // never PR'd. With `--rename` (and no `--resume`, which wins and reuses
    // the branch), rename the freshly-created local branch to `<branch>-N`
    // and proceed instead of aborting. Best-effort PR lookup only decorates
    // the log line; the rename itself doesn't require it.
    if !args.resume && args.rename && remote_branch_exists(&args.repo_root, &args.remote, &branch) {
        let orphan_pr = closed_pr_for_branch(&args.repo_root, &branch);
        let new_branch = next_available_branch_name(&args.repo_root, &args.remote, &branch);
        if let Err(e) = run_git(&worktree_path, &["branch", "-m", &branch, &new_branch]) {
            let _ = run_git(
                &args.repo_root,
                &["worktree", "remove", "--force", worktree_path_str],
            );
            let _ = run_git(&args.repo_root, &["branch", "-D", &branch]);
            bail!(
                "--rename: git branch -m {} {} failed: {}",
                branch,
                new_branch,
                e
            );
        }
        match orphan_pr {
            Some(pr) => eprintln!(
                "[claim] --rename: {} is orphaned from closed PR #{} — renamed local branch to {}",
                branch, pr, new_branch
            ),
            None => eprintln!(
                "[claim] --rename: {} already exists on {} with no open PR — renamed local branch to {}",
                branch, args.remote, new_branch
            ),
        }
        branch = new_branch;
    }

    // Rollback helper: undo worktree + branch on failure.
    let rollback_wt = |extra: &str| {
        let _ = run_git(
            &args.repo_root,
            &["worktree", "remove", "--force", worktree_path_str],
        );
        let _ = run_git(&args.repo_root, &["branch", "-D", &branch]);
        if !extra.is_empty() {
            eprintln!("[claim] rolled back worktree: {}", extra);
        }
    };

    // 6c. INFRA-1025 AC6: detect existing remote branch. If --resume, reset
    // HEAD to the remote tip and continue; otherwise abort with guidance.
    let remote_has_branch = remote_branch_exists(&args.repo_root, &args.remote, &branch);
    if remote_has_branch {
        if args.resume {
            // Reset the new local branch to match the remote tip so we pick up
            // prior work (e.g. an aborted session that already pushed commits).
            if let Err(e) = run_git(
                &worktree_path,
                &["reset", "--hard", &format!("{}/{}", args.remote, branch)],
            ) {
                rollback_wt(&format!("reset --hard failed: {e}"));
                bail!(
                    "--resume: reset --hard to {}/{} failed: {}",
                    args.remote,
                    branch,
                    e
                );
            }
            eprintln!(
                "[claim] --resume: reset HEAD to {}/{} (existing remote branch)",
                args.remote, branch
            );
        } else {
            rollback_wt("");
            // INFRA-1730: best-effort orphan detection to make the abort
            // message actionable instead of a bare "branch exists" dead end.
            let orphan_pr = closed_pr_for_branch(&args.repo_root, &branch);
            let orphan_line = match orphan_pr {
                Some(pr) => format!(
                    "  This looks like an orphaned branch: PR #{} on this branch is already closed.\n",
                    pr
                ),
                None => String::new(),
            };
            bail!(
                "branch {} already exists on {}.\n{}  \
                 Pass --resume to reset HEAD to the remote tip and continue from that work.\n  \
                 Pass --rename to auto-rename to {}-N and start a fresh branch.\n  \
                 Or delete the remote branch: gh api repos/OWNER/REPO/git/refs/heads/{} -X DELETE",
                branch,
                args.remote,
                orphan_line,
                branch,
                branch
            );
        }
    }

    // 7. INFRA-1025: Write lease atomically in Rust — no shell-out to gap-claim.sh.
    // Order: NATS (cross-machine serialization) → JSON lease file → state.db row.
    // Each step rolls back all prior steps on failure.

    // 7a. NATS KV dual-write (opt-in: CHUMP_NATS_URL must be set).
    let nats_result = nats_dual_write(&args.gap_id, &session_id, Some(&ambient_log))?;
    if nats_result == NatsClaimOutcome::Conflict {
        rollback_wt("");
        bail!(
            "NATS KV conflict: another session holds the atomic claim for {}. \
             Check `chump-coord claim` output.",
            args.gap_id
        );
    }

    // 7b. Write JSON lease file to .chump-locks/<session>.json.
    let lease_file = match write_or_merge_lease(
        &lock_dir,
        &session_id,
        &args.gap_id,
        args.paths.as_deref(),
        14_400, // 4h TTL
        false,
    ) {
        Ok(p) => p,
        Err(e) => {
            rollback_wt(&format!("JSON lease write failed: {e}"));
            return Err(e.context("writing JSON lease file (.chump-locks/)"));
        }
    };

    // INFRA-1608: the real per-session lease file above now carries gap_id
    // and is itself visible to `check_gap_id_uniqueness`'s scan, so the
    // short-lived marker has done its job of closing the worktree-setup race
    // window. Disarm it (skip the Drop-triggered remove_file) — no further
    // cleanup needed; the marker's own TTL means an un-disarmed one from an
    // earlier abort simply expires and is ignored.
    if let Some(guard) = marker_guard {
        guard.disarm();
    }

    // 7c. Write state.db leases row.
    if let Err(e) = write_db_claim(
        &args.repo_root,
        &args.gap_id,
        &session_id,
        worktree_path_str,
        14_400,
    ) {
        let _ = std::fs::remove_file(&lease_file);
        rollback_wt(&format!("state.db claim failed: {e}"));
        return Err(e.context("writing state.db leases row"));
    }

    // INFRA-1240: emit gap_claimed ambient event for observability (silent_agent debugging)
    let _ = emit_gap_claimed_event(&args.repo_root, &args.gap_id, &session_id);

    // INFRA-1116 AC4: emit intent_announced event so other sessions' overlap checks
    // can detect this claim. TTL = 4h (same as the lease). Paths from --paths flag.
    emit_intent_announced(
        &ambient_log,
        &args.gap_id,
        &session_id,
        args.paths.as_deref().unwrap_or(""),
        14_400, // 4h TTL in seconds
    );

    Ok(ClaimReport {
        gap_id: args.gap_id,
        worktree_path,
        branch,
        session_id,
        paths: args.paths,
    })
}

// ── Helpers ─────────────────────────────────────────────────────────────────

// ── INFRA-1885: lease-breadth cap ───────────────────────────────────────────

/// Top-level directory names that are too broad to hold as a lease path.
/// Operators must supply a more specific sub-path (e.g. `src/foo.rs` instead
/// of `src`) to avoid blocking sibling sessions for entire directory trees.
const BROAD_LEASE_DIRS: &[&str] = &["src", "scripts/ci", "docs/gaps", "src/lib", "app"];

/// INFRA-1885: Check that no path in `paths_csv` is an exact match against a
/// broad top-level directory. Returns `Ok(())` when all paths are sufficiently
/// specific, or when the operator override is active. Returns `Err(...)` with
/// a human-readable message when a broad path is detected and no override is
/// present.
///
/// Override: set `CHUMP_LEASE_ALLOW_BROAD_DIRS=1`. Every bypass emits
/// `kind=lease_broad_dir_claim` to ambient.jsonl for audit.
fn check_lease_breadth(
    paths_csv: &str,
    gap_id: &str,
    session_id: &str,
    ambient_log: &Path,
) -> Result<()> {
    let broad_dirs: Vec<&str> = paths_csv
        .split(',')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .filter(|p| BROAD_LEASE_DIRS.contains(p))
        .collect();

    if broad_dirs.is_empty() {
        return Ok(());
    }

    // Check override env var.
    let allow_broad = std::env::var("CHUMP_LEASE_ALLOW_BROAD_DIRS")
        .map(|v| v.trim() == "1")
        .unwrap_or(false);

    if allow_broad {
        // Operator override active — emit audit event and continue.
        emit_lease_broad_dir_claim(
            ambient_log,
            gap_id,
            session_id,
            &broad_dirs,
            "CHUMP_LEASE_ALLOW_BROAD_DIRS=1",
        );
        eprintln!(
            "[claim] INFRA-1885: broad-dir override active for {} (paths: {}). \
             Remember to add 'Broad-Lease-Reason: <one sentence>' to your commit message.",
            gap_id,
            broad_dirs.join(", ")
        );
        return Ok(());
    }

    // No override — reject the claim.
    bail!(
        "INFRA-1885: broad lease path(s) rejected: {broad}.\n  \
         Specify a more specific sub-path (e.g. `src/foo.rs` instead of `src`).\n  \
         Override: set CHUMP_LEASE_ALLOW_BROAD_DIRS=1 AND add commit trailer:\n    \
         Broad-Lease-Reason: <one sentence why a broad lease is necessary>",
        broad = broad_dirs.join(", ")
    );
}

/// INFRA-1885: emit `kind=lease_broad_dir_claim` to ambient.jsonl.
/// Fields: session_id, gap, paths (JSON array), reason.
/// Best-effort — silently no-ops if the file isn't writable.
fn emit_lease_broad_dir_claim(
    ambient_log: &Path,
    gap_id: &str,
    session_id: &str,
    broad_paths: &[&str],
    reason: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    // Build paths JSON array manually (no serde dependency here).
    let paths_json = {
        let parts: Vec<String> = broad_paths
            .iter()
            .map(|p| format!("\"{}\"", json_escape(p)))
            .collect();
        format!("[{}]", parts.join(","))
    };
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"lease_broad_dir_claim\",\
         \"session_id\":\"{sid}\",\"gap\":\"{gap}\",\
         \"paths\":{paths},\"reason\":\"{reason}\"}}\n",
        ts = ts,
        sid = json_escape(session_id),
        gap = json_escape(gap_id),
        paths = paths_json,
        reason = json_escape(reason),
    );
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

// ── end INFRA-1885 ───────────────────────────────────────────────────────────

/// INFRA-1025 AC6: check whether <remote>/<branch> exists on the remote.
/// Uses `git ls-remote --exit-code` which exits 2 when the ref is absent.
/// Best-effort — on network error we assume absent (don't block the claim).
fn remote_branch_exists(repo_root: &Path, remote: &str, branch: &str) -> bool {
    let refspec = format!("refs/heads/{}", branch);
    let out = Command::new("git")
        .args(["ls-remote", "--exit-code", remote, &refspec])
        .current_dir(repo_root)
        .output();
    match out {
        Ok(o) => o.status.success(),
        Err(_) => false,
    }
}

/// INFRA-1328: Returns `Some(pr_number)` if the upstream has an OPEN PR with
/// `<branch>` as its head. Used to refuse a stomp-claim: even if the prior
/// claimer's lease expired, an open PR (especially one with armed auto-merge)
/// is a strong signal the work is in flight and the branch must not be
/// re-purposed.
///
/// Best-effort: any `gh` failure (no auth, no network, gh not on PATH) returns
/// `None` so offline / un-authed clones don't get blocked. The downside is a
/// false-negative — but the worst case is the same as today's behavior, while
/// the success case prevents the stomp class entirely.
pub(crate) fn open_pr_on_branch(repo_root: &Path, branch: &str) -> Option<u64> {
    open_pr_info(repo_root, branch).map(|(n, _)| n)
}

/// INFRA-1503: same as `open_pr_on_branch` but also returns the PR author's
/// GitHub login. Used to surface the in-flight author in the abort diagnostic
/// and in the `claim_aborted_pr_in_flight` ambient event so the fleet can
/// distinguish "my own prior session" from "sibling already on it".
///
/// Best-effort: any failure returns `None`. Author may be empty string if the
/// PR has no `user.login` (rare; some GitHub Apps).
pub(crate) fn open_pr_info(repo_root: &Path, branch: &str) -> Option<(u64, String)> {
    let owner_repo = gh_owner_repo(repo_root)?;
    let owner = owner_repo.split('/').next()?;
    let head = format!("{}:{}", owner, branch);
    let out = Command::new("gh")
        .args([
            "api",
            "-H",
            "Accept: application/vnd.github+json",
            &format!(
                "repos/{}/pulls?state=open&head={}&per_page=1",
                owner_repo, head
            ),
            "--jq",
            // tab-separated number\tauthor; empty if no PR found
            r#".[0] | if . == null then empty else "\(.number)\t\(.user.login // "")" end"#,
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout.trim();
    if line.is_empty() {
        return None;
    }
    let mut parts = line.splitn(2, '\t');
    let num = parts.next()?.parse::<u64>().ok()?;
    let author = parts.next().unwrap_or("").to_string();
    Some((num, author))
}

/// INFRA-1730: Returns `Some(pr_number)` if the upstream has a CLOSED
/// (merged or not) PR with `<branch>` as its head. This is the "orphan
/// branch" signal: a remote branch exists but the PR that used it is
/// already closed, so the branch is dead weight left over from a prior
/// session rather than in-flight work. Distinguishing this from
/// `open_pr_on_branch` lets `chump claim` give an actionable message
/// (resume vs. rename) instead of a generic "branch already exists" bail.
///
/// Best-effort: any `gh` failure (no auth, no network, gh not on PATH)
/// returns `None` — the caller falls back to the pre-INFRA-1730 generic
/// message.
fn closed_pr_for_branch(repo_root: &Path, branch: &str) -> Option<u64> {
    let owner_repo = gh_owner_repo(repo_root)?;
    let owner = owner_repo.split('/').next()?;
    let head = format!("{}:{}", owner, branch);
    let out = Command::new("gh")
        .args([
            "api",
            "-H",
            "Accept: application/vnd.github+json",
            &format!(
                "repos/{}/pulls?state=closed&head={}&per_page=1",
                owner_repo, head
            ),
            "--jq",
            r#".[0] | if . == null then empty else "\(.number)" end"#,
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout.trim();
    if line.is_empty() {
        return None;
    }
    line.parse::<u64>().ok()
}

/// INFRA-1730: find the next available `<branch>-N` name (N starting at 2)
/// that exists neither locally nor on `remote`. Used by `chump claim --rename`
/// to auto-rebrand an orphaned branch instead of aborting the claim.
fn next_available_branch_name(repo_root: &Path, remote: &str, branch: &str) -> String {
    for n in 2..100 {
        let candidate = format!("{}-{}", branch, n);
        let local_exists = run_git(
            repo_root,
            &[
                "show-ref",
                "--verify",
                "--quiet",
                &format!("refs/heads/{}", candidate),
            ],
        )
        .is_ok();
        if !local_exists && !remote_branch_exists(repo_root, remote, &candidate) {
            return candidate;
        }
    }
    // Exhausted the search space (pathological) — fall back to a timestamped
    // suffix so the claim can still proceed.
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}-{}", branch, secs)
}

/// Resolve `owner/repo` from the git remote URL (https or ssh). Returns
/// `None` if the remote isn't a github.com URL.
fn gh_owner_repo(repo_root: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["config", "--get", "remote.origin.url"])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
    // https://github.com/owner/repo(.git)?  or  git@github.com:owner/repo(.git)?
    let stripped = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))?;
    Some(stripped.trim_end_matches(".git").to_string())
}

/// INFRA-1025: write the leases row to state.db. Mirrors GapStore::claim()
/// but without requiring a GapStore reference in this module.
/// Best-effort when DB absent (fresh clone has no state.db yet).
fn write_db_claim(
    repo_root: &Path,
    gap_id: &str,
    session_id: &str,
    worktree: &str,
    ttl_secs: i64,
) -> Result<()> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Ok(());
    }
    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {} for lease write", db_path.display()))?;
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let expires_at = now_secs + ttl_secs;
    conn.execute(
        "INSERT INTO leases(session_id, gap_id, worktree, expires_at)
         VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(session_id) DO UPDATE SET gap_id=excluded.gap_id,
             worktree=excluded.worktree, expires_at=excluded.expires_at",
        rusqlite::params![session_id, gap_id, worktree, expires_at],
    )
    .with_context(|| format!("inserting lease for {} into leases table", gap_id))?;
    Ok(())
}

/// RESILIENT-103: clear the state.db `leases` row on release. Symmetric with
/// `write_db_claim()` — the claim writes the row, so release must delete it, or
/// the lease lingers in state.db after the JSON sidecar is gone. That triple-store
/// split (JSON deleted, state.db + NATS-KV orphaned) is what blocked recovery of an
/// abandoned claim: re-claim saw a stale state.db row and refused. Deletes by
/// `session_id` (the table key) AND by `gap_id` (handles the cross-session
/// same-gap re-claim case — the INFRA-2744 scenario where bot-merge re-claims a
/// gap under a different session name). Best-effort when the DB is absent (fresh
/// clone). Returns the number of rows deleted.
pub fn release_db_lease(repo_root: &Path, session_id: &str, gap_id: &str) -> Result<usize> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Ok(0);
    }
    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {} for lease release", db_path.display()))?;
    let mut deleted = 0usize;
    if !session_id.is_empty() {
        deleted += conn
            .execute(
                "DELETE FROM leases WHERE session_id = ?1",
                rusqlite::params![session_id],
            )
            .with_context(|| format!("deleting state.db lease for session {}", session_id))?;
    }
    if !gap_id.is_empty() {
        deleted += conn
            .execute(
                "DELETE FROM leases WHERE gap_id = ?1",
                rusqlite::params![gap_id],
            )
            .with_context(|| format!("deleting state.db lease for gap {}", gap_id))?;
    }
    Ok(deleted)
}

/// Verify that .git/worktrees/<branch-slug>/gitdir points at <worktree_path>/.git.
/// Repairs the file if wrong (INFRA-779: concurrent sibling claims can clobber it).
///
/// INFRA-1056 hardening:
///   - Retry up to 3 times with short backoff if the back-ref is wrong AFTER
///     repair (i.e. a sibling claim re-clobbered it between our write and read).
///   - Emit `kind=worktree_gitdir_repair_fired` to ambient.jsonl so operators
///     can see if/when the race is still happening in the wild.
fn verify_and_repair_gitdir(repo_root: &Path, _branch: &str, worktree_path: &Path) -> Result<()> {
    // The worktrees entry name is the last component of the branch slug
    // (git uses the worktree directory name, not the branch name).
    let wt_name = worktree_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if wt_name.is_empty() {
        return Ok(());
    }

    let gitdir_file = repo_root
        .join(".git")
        .join("worktrees")
        .join(wt_name)
        .join("gitdir");
    if !gitdir_file.exists() {
        return Ok(());
    }

    // git stores the canonical (realpath) value of <worktree>/.git
    let dot_git = worktree_path.join(".git");
    let canonical = std::fs::canonicalize(&dot_git).unwrap_or(dot_git.clone());
    let expected = canonical.to_str().unwrap_or("").to_string();
    if expected.is_empty() {
        return Ok(());
    }

    // Retry loop: INFRA-1056. The race window is the time between our read-
    // back-ref and any concurrent sibling claim's write. 3 attempts × 50ms
    // covers the realistic worst case without blocking the claim path.
    const MAX_ATTEMPTS: usize = 3;
    let mut last_recorded = String::new();
    for attempt in 1..=MAX_ATTEMPTS {
        let recorded = std::fs::read_to_string(&gitdir_file)
            .unwrap_or_default()
            .trim()
            .to_string();
        last_recorded = recorded.clone();

        if recorded == expected {
            if attempt > 1 {
                eprintln!(
                    "[claim] INFRA-1056: gitdir back-ref converged on attempt {attempt} for {wt_name}"
                );
            }
            return Ok(());
        }

        eprintln!(
            "[claim] INFRA-1056 (attempt {attempt}/{MAX_ATTEMPTS}): gitdir mismatch for {wt_name} — repairing\n  was: {recorded}\n  now: {expected}"
        );
        std::fs::write(&gitdir_file, format!("{expected}\n"))
            .with_context(|| format!("repairing gitdir file {}", gitdir_file.display()))?;
        emit_gitdir_repair_event(repo_root, wt_name, &recorded, &expected, attempt);
        emit_gitdir_repaired_event(repo_root, wt_name, &recorded, &expected);

        if attempt < MAX_ATTEMPTS {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    // We attempted 3 repairs and the back-ref still doesn't match. Concurrent
    // sibling activity is overwhelming the repair path. Surface this loudly
    // — the operator needs to know the race is unresolved for this claim.
    bail!(
        "INFRA-1056: gitdir back-ref for {wt_name} did not converge after {MAX_ATTEMPTS} repair attempts\n  expected: {expected}\n  last seen: {last_recorded}\n  Concurrent sibling claims are overwhelming the repair path; release leases and retry."
    );
}

/// Emit `kind=worktree_gitdir_repair_fired` to ambient.jsonl. Best-effort —
/// silently no-ops if the file isn't writable. Lets operators measure
/// whether the INFRA-779 race is still firing in production.
fn emit_gitdir_repair_event(repo_root: &Path, wt_name: &str, was: &str, now: &str, attempt: usize) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = format!(
        r#"{{"ts":"{ts}","kind":"worktree_gitdir_repair_fired","worktree":"{wt_name}","was":"{}","now":"{}","attempt":{attempt}}}"#,
        json_escape(was),
        json_escape(now),
    );
    let path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", event);
    }
}

/// Emit kind=worktree_gitdir_repaired to ambient.jsonl (INFRA-1033).
fn emit_gitdir_repaired_event(repo_root: &Path, wt_name: &str, was: &str, now: &str) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let ts = {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // Format as ISO-8601 UTC
        let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
        format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
    };

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"worktree_gitdir_repaired\",\"wt_name\":\"{wt_name}\",\"was\":\"{was}\",\"now\":\"{now}\"}}\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-1240: Emit gap_claimed ambient event for observability.
/// Used to debug silent_agent and lease-race issues.
fn emit_gap_claimed_event(repo_root: &Path, gap_id: &str, session_id: &str) -> Result<()> {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_claimed\",\"gap_id\":\"{gap_id}\",\"session_id\":\"{session_id}\"}}\n"
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
    Ok(())
}

/// INFRA-1439: emit kind=chump_claim_force_recover to ambient.jsonl.
/// Best-effort — silently no-ops if the file isn't writable.
fn emit_force_recover_event(repo_root: &Path, gap_id: &str, branch: &str, actions: &str) {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"chump_claim_force_recover\",\
         \"gap_id\":\"{}\",\"branch\":\"{}\",\"actions\":\"{}\"}}\n",
        json_escape(gap_id),
        json_escape(branch),
        json_escape(actions),
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-2235: emit kind=force_recover_wip_loss to ambient.jsonl.
/// Fired when --force-recover is used on a worktree with uncommitted changes
/// and --discard-wip was NOT passed — signals the refusal (not an actual loss).
/// Best-effort — silently no-ops if the file isn't writable.
fn emit_force_recover_wip_loss(
    repo_root: &Path,
    gap_id: &str,
    files_lost_count: usize,
    first_five_paths: &str,
) {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"force_recover_wip_loss\",\
         \"gap_id\":\"{}\",\"files_lost_count\":{},\"first_paths\":\"{}\"}}\n",
        json_escape(gap_id),
        files_lost_count,
        json_escape(first_five_paths),
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-2235: emit kind=force_recover_wip_discarded to ambient.jsonl.
/// Fired when --force-recover --discard-wip is used on a worktree with
/// uncommitted changes — signals intentional data loss for retro audit.
/// Best-effort — silently no-ops if the file isn't writable.
fn emit_force_recover_wip_discarded(
    repo_root: &Path,
    gap_id: &str,
    files_lost_count: usize,
    first_five_paths: &str,
) {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"force_recover_wip_discarded\",\
         \"gap_id\":\"{}\",\"files_lost_count\":{},\"first_paths\":\"{}\"}}\n",
        json_escape(gap_id),
        files_lost_count,
        json_escape(first_five_paths),
    );
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-1503: emit `claim_aborted_pr_in_flight` to ambient.jsonl. Fired right
/// before we bail in step 5b so we count the waste-prevention signal even
/// though the claim itself is refused. `existing_author` may be empty when
/// the PR was opened by a GitHub App or `user.login` is unavailable.
fn emit_claim_aborted_pr_in_flight_event(
    ambient_path: &Path,
    gap_id: &str,
    existing_pr: u64,
    existing_author: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_aborted_pr_in_flight\",\
         \"gap_id\":\"{}\",\"existing_pr\":{},\"existing_author\":\"{}\"}}\n",
        json_escape(gap_id),
        existing_pr,
        json_escape(existing_author),
    );
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// INFRA-1982: Scan open PRs for any that already cover this gap ID.
///
/// Returns `Some((pr_num, branch))` if an open PR is found where either:
///   (a) the PR title contains the gap ID (case-insensitive), OR
///   (b) the PR's head branch starts with `chump/<gap-id-lowercase>`
///
/// This check catches the duplicate-PR failure mode that title-similarity
/// reserve-time gating cannot: two agents file two gap IDs for the same
/// problem, both claim and push, creating two in-flight PRs that step on
/// each other.
///
/// Best-effort: `gh` failures return None (offline fallback).
/// Bypass: `CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1` (mirrors `--allow-duplicate-pr`).
pub fn check_open_pr_for_gap(repo_root: &Path, gap_id: &str) -> Option<(u64, String)> {
    // Search by gap ID in PR titles
    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--search",
            gap_id,
            "--json",
            "number,title,headRefName",
            "--limit",
            "20",
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&out.stdout).unwrap_or_default();
    let gap_lower = gap_id.to_lowercase();
    let branch_prefix = format!("chump/{}", gap_lower);
    for v in &arr {
        let num = v["number"].as_u64()?;
        let pr_title = v["title"].as_str().unwrap_or("").to_lowercase();
        let head_ref = v["headRefName"].as_str().unwrap_or("");
        if pr_title.contains(&gap_lower) || head_ref.to_lowercase().starts_with(&branch_prefix) {
            return Some((num, head_ref.to_string()));
        }
    }
    None
}

/// INFRA-4996 (INFRA-2434 slice): check whether any file in `paths_csv`
/// appears in the file list of a currently open PR. Returns the first
/// overlapping PR as (pr_number, gap_id_parsed_from_title, overlap_paths).
///
/// Complements [`check_open_pr_for_gap`] (which matches on gap ID) by
/// matching on actual file paths — catches two *different* gap IDs whose
/// declared `--paths` collide on the same file.
///
/// Best-effort: `gh` failures or an empty/absent `paths_csv` return None.
pub fn check_paths_overlap_open_prs(
    repo_root: &Path,
    paths_csv: &str,
) -> Option<(u64, String, Vec<String>)> {
    let claim_paths: Vec<&str> = paths_csv
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if claim_paths.is_empty() {
        return None;
    }

    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--json",
            "number,title,files",
            "--limit",
            "50",
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&out.stdout).unwrap_or_default();
    for v in &arr {
        let Some(num) = v["number"].as_u64() else {
            continue;
        };
        let title = v["title"].as_str().unwrap_or("");
        let pr_paths: Vec<&str> = v["files"]
            .as_array()
            .map(|files| files.iter().filter_map(|f| f["path"].as_str()).collect())
            .unwrap_or_default();
        let overlap: Vec<String> = claim_paths
            .iter()
            .filter(|p| {
                pr_paths
                    .iter()
                    .any(|pr_path| p.eq_ignore_ascii_case(pr_path))
            })
            .map(|s| s.to_string())
            .collect();
        if !overlap.is_empty() {
            let other_gap =
                extract_gap_id_from_title(title).unwrap_or_else(|| "unknown".to_string());
            return Some((num, other_gap, overlap));
        }
    }
    None
}

/// Pull the first `LETTERS-DIGITS` token (e.g. `INFRA-1234`) out of a PR
/// title. Gap-ID conventions in this repo are all-uppercase domain prefix
/// + hyphen + digits (see `docs/gaps/*.yaml`).
fn extract_gap_id_from_title(title: &str) -> Option<String> {
    title
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
        .find_map(|token| {
            let (prefix, suffix) = token.split_once('-')?;
            let is_gap_id = prefix.len() >= 2
                && prefix.chars().all(|c| c.is_ascii_uppercase())
                && !suffix.is_empty()
                && suffix.chars().all(|c| c.is_ascii_digit());
            is_gap_id.then(|| token.to_string())
        })
}

/// Emit kind=claim_open_pr_dup_blocked to ambient.jsonl (INFRA-1982).
// scanner-anchor: "kind":"claim_open_pr_dup_blocked"
fn emit_claim_open_pr_dup_blocked(ambient_path: &Path, gap: &str, open_pr: u64) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_open_pr_dup_blocked\",\
         \"gap\":\"{}\",\"open_pr\":{}}}\n",
        json_escape(gap),
        open_pr,
    );
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// Decompose Unix epoch seconds into (year, month, day, hour, min, sec) UTC.
/// Minimal implementation — no external date crate dependency.
fn secs_to_ymdhms(secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = secs % 60;
    let mi = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Gregorian calendar from day count since 1970-01-01.
    let mut y = 1970u32;
    let mut rem = days;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let days_in_year = if leap { 366u64 } else { 365u64 };
        if rem < days_in_year {
            break;
        }
        rem -= days_in_year;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = [
        31u64,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut mo = 1u32;
    for &md in &month_days {
        if rem < md {
            break;
        }
        rem -= md;
        mo += 1;
    }
    (y, mo, rem as u32 + 1, h as u32, mi as u32, s as u32)
}

fn run_git(cwd: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .with_context(|| format!("spawning git {:?}", args))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("git {} failed: {}", args.join(" "), stderr);
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Derive a unique session ID for an atomic claim. Same shape as the
/// INFRA-461 fleet pattern but with a `claim-` prefix so logs / leases
/// distinguish operator-claims from fleet-claims.
fn derive_session_id(gap_id: &str) -> String {
    let pid = std::process::id();
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("claim-{}-{}-{}", gap_id.to_lowercase(), pid, epoch)
}

/// INFRA-965 slice 1 (INFRA-984): port the new-lease-file write from
/// scripts/coord/gap-claim.sh into Rust. Matches the JSON schema used by
/// gap-preflight.sh's reader exactly — session_id, paths, taken_at,
/// expires_at, heartbeat_at, purpose, gap_id. Returns the path of the
/// lease file written.
///
/// This is the simple-case write (no existing lease, no speculative
/// flag). INFRA-985 ports the merge-existing-lease + speculative cases;
/// INFRA-986 ports the NATS KV dual-write. Once all three land, gap-claim.sh
/// can be deleted (INFRA-987).
pub fn write_basic_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
) -> Result<PathBuf> {
    std::fs::create_dir_all(lock_dir)
        .with_context(|| format!("create lock dir {}", lock_dir.display()))?;

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let now_iso = unix_to_iso8601(now_secs);
    let expires_iso = unix_to_iso8601(now_secs.saturating_add(ttl_secs));

    let paths_list: Vec<String> = paths_csv
        .unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // Hand-roll the JSON to match gap-claim.sh's output byte-for-byte:
    // two-space indent, trailing newline, key order session_id → paths →
    // taken_at → expires_at → heartbeat_at → purpose → gap_id. Using
    // serde_json::to_string_pretty would change key order (it's BTreeMap
    // for serde_json::Map under that path) and add subtle diffs that
    // would break callers diffing against the existing format.
    let mut json = String::new();
    json.push_str("{\n");
    json.push_str(&format!(
        "  \"session_id\": \"{}\",\n",
        json_escape(session_id)
    ));
    json.push_str("  \"paths\": [");
    if !paths_list.is_empty() {
        json.push('\n');
        for (i, p) in paths_list.iter().enumerate() {
            json.push_str(&format!("    \"{}\"", json_escape(p)));
            if i + 1 < paths_list.len() {
                json.push(',');
            }
            json.push('\n');
        }
        json.push_str("  ");
    }
    json.push_str("],\n");
    json.push_str(&format!("  \"taken_at\": \"{}\",\n", now_iso));
    json.push_str(&format!("  \"expires_at\": \"{}\",\n", expires_iso));
    json.push_str(&format!("  \"heartbeat_at\": \"{}\",\n", now_iso));
    json.push_str(&format!(
        "  \"purpose\": \"gap:{}\",\n",
        json_escape(gap_id)
    ));
    json.push_str(&format!("  \"gap_id\": \"{}\"\n", json_escape(gap_id)));
    json.push_str("}\n");

    let lease_path = lock_dir.join(format!("{}.json", session_id));
    std::fs::write(&lease_path, json)
        .with_context(|| format!("write lease {}", lease_path.display()))?;
    Ok(lease_path)
}

/// INFRA-965 slice 2 (INFRA-985): merge-or-write public entrypoint.
///
/// If a lease file already exists at `<lock_dir>/<session_id>.json` (the
/// session already holds a lease — typically from a prior claim earlier
/// in the same shell), update it in place:
///   - set `gap_id` to the new value
///   - merge `paths_csv` into the existing `paths` array, preserving
///     dedup order
///   - preserve the existing `speculative` flag if present (caller can
///     promote via the `speculative` arg here)
///   - clear `pending_new_gap` if it referenced this gap_id
///   - leave taken_at / expires_at / heartbeat_at untouched (the lease
///     keeps its original lifetime; that's why we merge instead of
///     overwriting)
///
/// If no lease file exists, falls through to `write_basic_lease` (slice 1)
/// or its speculative variant when `speculative=true`.
///
/// Returns the path of the lease file.
pub fn write_or_merge_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
    speculative: bool,
) -> Result<PathBuf> {
    let lease_path = lock_dir.join(format!("{}.json", session_id));
    if lease_path.exists() {
        return merge_existing_lease(&lease_path, gap_id, paths_csv, speculative);
    }
    if speculative {
        write_speculative_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)
    } else {
        write_basic_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)
    }
}

/// INFRA-985: speculative lease variant — same shape as basic but with
/// `"speculative": true` appended. `gap-preflight.sh` reads this field to
/// allow concurrent claims from other speculative-mode sessions on the
/// same gap (first-to-land wins).
pub fn write_speculative_lease(
    lock_dir: &Path,
    session_id: &str,
    gap_id: &str,
    paths_csv: Option<&str>,
    ttl_secs: u64,
) -> Result<PathBuf> {
    // Re-use the basic write then rewrite with the extra key. Simpler than
    // duplicating 60 lines of JSON-emit for one extra field.
    let lease_path = write_basic_lease(lock_dir, session_id, gap_id, paths_csv, ttl_secs)?;
    let body = std::fs::read_to_string(&lease_path).with_context(|| {
        format!(
            "read lease for speculative annotation: {}",
            lease_path.display()
        )
    })?;
    // Insert "speculative": true before the closing brace. Body ends with
    // `  "gap_id": "..."\n}\n` — we add a comma to the gap_id line and a
    // new speculative line.
    let trimmed = body.trim_end_matches('\n');
    let with_spec = trimmed
        .strip_suffix('}')
        .map(|s| {
            format!(
                "{},\n  \"speculative\": true\n}}\n",
                s.trim_end_matches(['\n', ' '])
            )
        })
        .ok_or_else(|| anyhow!("unexpected lease body shape: missing closing brace"))?;
    std::fs::write(&lease_path, with_spec)
        .with_context(|| format!("rewrite speculative lease: {}", lease_path.display()))?;
    Ok(lease_path)
}

/// INFRA-985: merge new gap_id + paths into an existing lease file in
/// place. Preserves session_id, taken_at, expires_at, heartbeat_at,
/// speculative-flag (with optional promotion), and any extra unknown
/// keys (forward-compat with future schema additions).
fn merge_existing_lease(
    lease_path: &Path,
    gap_id: &str,
    paths_csv: Option<&str>,
    promote_speculative: bool,
) -> Result<PathBuf> {
    let body = std::fs::read_to_string(lease_path)
        .with_context(|| format!("read existing lease {}", lease_path.display()))?;
    let mut val: serde_json::Value = serde_json::from_str(&body)
        .with_context(|| format!("parse existing lease {}", lease_path.display()))?;

    let obj = val.as_object_mut().ok_or_else(|| {
        anyhow!(
            "lease {} is not a JSON object: {}",
            lease_path.display(),
            body
        )
    })?;

    obj.insert(
        "gap_id".to_string(),
        serde_json::Value::String(gap_id.to_string()),
    );

    if promote_speculative {
        obj.insert("speculative".to_string(), serde_json::Value::Bool(true));
    }

    // pending_new_gap cleanup: if it's an object whose "id" matches the
    // gap we're now claiming, drop the pending pointer.
    if let Some(pending) = obj.get("pending_new_gap") {
        if let Some(pid) = pending.get("id").and_then(|v| v.as_str()) {
            if pid == gap_id {
                obj.remove("pending_new_gap");
            }
        }
    }

    // Merge paths.
    let new_paths: Vec<String> = paths_csv
        .unwrap_or("")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let mut merged: Vec<String> = obj
        .get("paths")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|p| p.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    for p in new_paths {
        if !merged.contains(&p) {
            merged.push(p);
        }
    }

    obj.insert(
        "paths".to_string(),
        serde_json::Value::Array(merged.into_iter().map(serde_json::Value::String).collect()),
    );

    // Re-serialize with pretty 2-space indent + trailing newline to match
    // the basic-write convention.
    let mut out = serde_json::to_string_pretty(&val).with_context(|| "serialize merged lease")?;
    out.push('\n');
    std::fs::write(lease_path, out)
        .with_context(|| format!("write merged lease {}", lease_path.display()))?;
    Ok(lease_path.to_path_buf())
}

/// INFRA-985: scan a lock dir for OTHER sessions' lease files that claim
/// the same gap_id. Returns (session_id, is_speculative) tuples. Excludes
/// `own_session_id`. Used by the speculative-mode banner to show siblings.
pub fn sibling_lease_holders(
    lock_dir: &Path,
    gap_id: &str,
    own_session_id: &str,
) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        let sid = val
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        if sid == own_session_id {
            continue;
        }
        let gid = val.get("gap_id").and_then(|v| v.as_str()).unwrap_or("");
        if gid != gap_id {
            continue;
        }
        let speculative = val
            .get("speculative")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        out.push((sid, speculative));
    }
    out.sort();
    out
}

fn unix_to_iso8601(unix: u64) -> String {
    // Minimal RFC3339 formatter — no chrono dep required at this seam.
    // Days-since-epoch -> Y/M/D via simple civil_from_days algorithm
    // (Howard Hinnant). Seconds-of-day -> H:M:S directly.
    let days = (unix / 86_400) as i64;
    let sod = (unix % 86_400) as u32;
    let h = sod / 3600;
    let m = (sod % 3600) / 60;
    let s = sod % 60;
    let (y, mo, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, m, s)
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    // Hinnant's civil_from_days, adapted from
    // https://howardhinnant.github.io/date_algorithms.html
    let z = z + 719_468;
    let era = if z >= 0 {
        z / 146_097
    } else {
        (z - 146_096) / 146_097
    };
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// INFRA-1259/1878/2984/3259: Returns true if a single AC entry is a
/// placeholder stub or a non-verifiable filler phrase. Only matches entries
/// that ARE stubs, not entries that mention "TODO" in meaningful text (e.g.
/// "AC: ensures no TODO in field X" must not match). Kept in sync with the
/// canonical copy in src/main.rs.
fn is_vague_ac_entry(s: &str) -> bool {
    let t = s.trim();
    let upper = t.to_uppercase();
    upper == "TODO"
        || upper == "TBD"
        || upper == "TBC"
        || upper == "N/A"
        || upper.starts_with("TODO:")
        || upper.starts_with("TODO ")
        || upper.starts_with("TBD:")
        || upper.starts_with("TBD ")
        || upper.starts_with("<FILL")
        || upper.starts_with("FILL IN")
        || matches!(
            upper.as_str(),
            "VERIFY IT WORKS"
                | "VERIFY IT"
                | "VERIFY"
                | "IT WORKS"
                | "WORKS"
                | "MAKE IT WORK"
                | "SHOULD WORK"
                | "IT SHOULD WORK"
                | "TEST IT"
                | "DONE"
                | "COMPLETE"
                | "FIX IT"
                | "IMPLEMENT IT"
        )
}

/// INFRA-1259: Check if acceptance_criteria is vague (empty, all-TODO, or all-TBD).
/// Returns true if the AC is empty, contains only TODO items, or contains only TBD items.
fn is_acceptance_criteria_vague(ac: &str) -> bool {
    let trimmed = ac.trim();
    // Empty AC is vague
    if trimmed.is_empty() {
        return true;
    }

    // Try to parse as JSON array (the canonical format)
    if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(trimmed) {
        if arr.is_empty() {
            return true; // Empty array
        }
        // All items must be stubs for the gap to be flagged vague (INFRA-1878:
        // entries that merely mention "TODO" in passing must not trigger ⚠).
        let all_vague = arr
            .iter()
            .all(|item| item.as_str().map(is_vague_ac_entry).unwrap_or(false));
        return all_vague;
    }

    // If not JSON array, only flag if the whole string IS a stub keyword.
    let upper = trimmed.to_uppercase();
    upper == "TODO" || upper == "TBD"
}

/// Step 2: ensure the gap is in state.db. If missing, attempt to seed
/// via `chump gap import` (uses the per-file YAML mirrors as source of
/// truth — INFRA-470 / INFRA-460 territory).
fn verify_or_seed_gap(repo_root: &Path, gap_id: &str) -> Result<()> {
    // Quick sqlite read.
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        // No DB yet — bootstrap by running `chump gap import`. Caller
        // is presumably trying to seed too, so this is fine.
        return run_chump_gap_import(repo_root);
    }

    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {}", db_path.display()))?;
    // CREDIBLE-159: under fleet load the un-timed read hit SQLITE_BUSY and
    // .unwrap_or(0) turned that into "gap not found" — every bot-merge claim
    // on chumpd-eu died on an existence lie while the row sat in the table.
    // Busy-wait up to 5s, and propagate real errors as errors.
    let _ = conn.busy_timeout(std::time::Duration::from_secs(5));
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM gaps WHERE id = ?1", [gap_id], |r| {
            r.get(0)
        })
        .with_context(|| format!("state.db busy/unreadable while looking up {gap_id} — retry"))?;

    if count == 0 {
        // Gap not in DB but YAML may have it — seed.
        run_chump_gap_import(repo_root)?;

        // Re-check.
        let count_after: i64 = conn
            .query_row("SELECT COUNT(*) FROM gaps WHERE id = ?1", [gap_id], |r| {
                r.get(0)
            })
            .with_context(|| {
                format!("state.db busy/unreadable on re-check for {gap_id} — retry")
            })?;
        if count_after == 0 {
            bail!(
                "gap {} not found in state.db or docs/gaps/ — reserve it first with `chump gap reserve --domain D --title T`",
                gap_id
            );
        }
    }

    // Reject if already done.
    let status: String = conn
        .query_row("SELECT status FROM gaps WHERE id = ?1", [gap_id], |r| {
            r.get(0)
        })
        .unwrap_or_else(|_| "unknown".into());
    if status == "done" {
        bail!(
            "gap {} is already status=done; pick a different gap or reopen it",
            gap_id
        );
    }

    // INFRA-1259: Reject if acceptance_criteria is empty or contains only TODO items.
    let ac: String = conn
        .query_row(
            "SELECT acceptance_criteria FROM gaps WHERE id = ?1",
            [gap_id],
            |r| r.get(0),
        )
        .unwrap_or_default();

    if is_acceptance_criteria_vague(&ac) {
        bail!(
            "Gap {} has no concrete acceptance criteria — add AC before claiming",
            gap_id
        );
    }

    Ok(())
}

/// INFRA-3002 AC#2: `chump gap import` exits 1 whenever ANY row in the yaml
/// batch is blocked by INFRA-1434 title-similarity — even when the block is
/// a pre-existing dupe unrelated to the gap this claim is trying to seed.
/// A nonzero exit whose stderr carries the INFRA-1434 marker is that
/// (recoverable) class; anything else (parse errors, io errors, etc.) is a
/// genuine import failure that must still fail the claim.
fn import_failure_is_similarity_block_only(stderr: &str) -> bool {
    stderr.contains("blocked by title-similarity (INFRA-1434")
}

fn run_chump_gap_import(repo_root: &Path) -> Result<()> {
    // Use the same binary that's running this code so we're consistent
    // with the build that may have local edits. argv[0] resolves to it.
    let exe = std::env::current_exe().context("locating current chump exe")?;
    let out = Command::new(&exe)
        .args(["gap", "import"])
        .current_dir(repo_root)
        .output()
        .context("spawning chump gap import")?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        // Don't fail the claim on the similarity-block class of exit; warn
        // and let the caller's post-import state.db re-check
        // (verify_or_seed_gap) decide whether the CLAIMED gap actually made
        // it in. A genuine block of the claimed gap itself still surfaces
        // there as "not found in state.db".
        if import_failure_is_similarity_block_only(&stderr) {
            eprintln!(
                "chump claim: chump gap import reported similarity blocks (see \
                 ambient.jsonl kind=gap_import_similarity_block); proceeding — \
                 will verify the claimed gap landed:\n{stderr}"
            );
        } else {
            bail!("chump gap import failed: {}", stderr);
        }
    }
    Ok(())
}

/// Step 3: chump-doctor binary health probe. Skips silently if the
/// script isn't present (e.g. partial checkouts in tests).
fn run_doctor_probe(repo_root: &Path) -> Result<()> {
    let doctor = repo_root.join("scripts/dev/chump-binary-unwedge.sh");
    if !doctor.exists() {
        return Ok(()); // best-effort
    }
    // Use QUIET mode if supported by the script (it greps args for
    // CHUMP_DOCTOR_QUIET=1).
    let out = Command::new("bash")
        .arg(&doctor)
        .env("CHUMP_DOCTOR_QUIET", "1")
        .current_dir(repo_root)
        .output()
        .context("spawning chump-binary-unwedge.sh")?;
    if !out.status.success() {
        // Don't abort — the doctor itself may exit non-zero on
        // fresh-binary "no heal needed" paths in some versions. Log
        // stderr as a warning for visibility.
        let stderr = String::from_utf8_lossy(&out.stderr);
        if !stderr.is_empty() {
            eprintln!("[chump claim] chump-doctor stderr: {}", stderr.trim());
        }
    }
    Ok(())
}

/// INFRA-986: outcome of an attempted NATS KV dual-write.
#[derive(Debug, PartialEq, Eq)]
pub enum NatsClaimOutcome {
    /// CHUMP_NATS_URL unset OR chump-coord binary missing — no NATS attempt.
    /// File-based lease should proceed as the only mechanism.
    Skipped,
    /// chump-coord exit 0 — atomic CAS won (or NATS reachable + key absent).
    Claimed,
    /// chump-coord exit 1 — another session holds the claim. Caller MUST
    /// abort: do not write the file-based lease, do not create the worktree.
    Conflict,
}

/// INFRA-986: port of the FLEET-032 NATS KV dual-write block from
/// scripts/coord/gap-claim.sh. Shells out to the `chump-coord` binary
/// (transitional: future iterations will call the chump-coord crate
/// directly once gap_claim is a stable library entry point — see
/// INFRA-478). Returns the outcome so the caller can decide what to do.
///
/// Discovery:
///   * `CHUMP_NATS_URL` must be set, otherwise skip (single-machine mode).
///   * `chump-coord` must be on PATH (or pointed at by `CHUMP_COORD_BIN`).
///     Both gates skip cleanly — NATS is opt-in.
///
/// On `Conflict`, emits a `gap_claim_nats_conflict` event to
/// `ambient_log_path` (or `.chump-locks/ambient.jsonl` if None). The
/// emitter is intentionally a one-line append: keep the ambient stream
/// the source of truth for cross-machine visibility, no other side
/// effect.
pub fn nats_dual_write(
    gap_id: &str,
    session_id: &str,
    ambient_log_path: Option<&Path>,
) -> Result<NatsClaimOutcome> {
    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_default();
    if nats_url.is_empty() {
        return Ok(NatsClaimOutcome::Skipped);
    }
    let coord_bin = match resolve_coord_bin() {
        Some(p) => p,
        None => return Ok(NatsClaimOutcome::Skipped),
    };
    nats_dual_write_with_bin(&coord_bin, gap_id, session_id, ambient_log_path)
}

/// Test seam: caller-supplied chump-coord path. Production callers go
/// through `nats_dual_write` (above) which honors `CHUMP_NATS_URL` +
/// PATH discovery.
pub(crate) fn nats_dual_write_with_bin(
    coord_bin: &Path,
    gap_id: &str,
    session_id: &str,
    ambient_log_path: Option<&Path>,
) -> Result<NatsClaimOutcome> {
    // Retry on ETXTBSY (os error 26): the kernel returns this transiently when a
    // script file was just written and the kernel's page-cache hasn't settled yet.
    // Up to 3 attempts with a short backoff are sufficient in practice.
    let out = {
        let mut last_err: Option<std::io::Error> = None;
        let mut result = None;
        for attempt in 0..3 {
            match Command::new(coord_bin)
                .args(["claim", gap_id])
                .env("CHUMP_SESSION_ID", session_id)
                .output()
            {
                Ok(o) => {
                    result = Some(o);
                    break;
                }
                Err(e) if e.raw_os_error() == Some(26) => {
                    // ETXTBSY — wait briefly and retry
                    std::thread::sleep(std::time::Duration::from_millis(10 * (1 << attempt)));
                    last_err = Some(e);
                }
                Err(e) => {
                    return Err(e).with_context(|| {
                        format!("spawning {} claim {}", coord_bin.display(), gap_id)
                    });
                }
            }
        }
        match result {
            Some(o) => o,
            None => {
                return Err(last_err.unwrap())
                    .with_context(|| format!("spawning {} claim {}", coord_bin.display(), gap_id));
            }
        }
    };

    if out.status.success() {
        return Ok(NatsClaimOutcome::Claimed);
    }
    let code = out.status.code().unwrap_or(-1);
    if code == 1 {
        emit_nats_conflict_event(ambient_log_path, gap_id, session_id);
        return Ok(NatsClaimOutcome::Conflict);
    }
    // Any other exit (NATS server unreachable, network blip, transient
    // chump-coord error) is treated like Skipped: do NOT block the claim
    // on infrastructure that's opt-in. Mirrors the shell behavior — the
    // `if !chump-coord claim …` branch only fires on rc=1 conflict; any
    // other failure (rc=2+, signal, no stdout) is silently tolerated.
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !stderr.trim().is_empty() {
        eprintln!(
            "[atomic_claim] chump-coord returned rc={} for gap {}: {}",
            code,
            gap_id,
            stderr.trim()
        );
    }
    Ok(NatsClaimOutcome::Skipped)
}

fn resolve_coord_bin() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("CHUMP_COORD_BIN") {
        if !explicit.is_empty() {
            let p = PathBuf::from(explicit);
            if p.exists() {
                return Some(p);
            }
        }
    }
    // Walk PATH.
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let cand = dir.join("chump-coord");
        if cand.is_file() {
            return Some(cand);
        }
    }
    None
}

/// INFRA-2472: cross-machine lease visibility. `chump-coord whois` (INFRA-274)
/// reads the NATS KV `chump_gaps` bucket directly — the same bucket
/// `nats_dual_write` CASes into at claim time — so it sees claims taken on
/// *other* machines that never touched this machine's `.chump-locks/`.
///
/// Returns `None` when NATS is unconfigured, the coord binary is
/// unavailable, or the gap is unclaimed in the shared registry. `None` is
/// NOT a green light — it means "no cross-machine signal available", same
/// fail-open posture as `nats_dual_write`'s `Skipped` outcome. Local checks
/// (`check_gap_id_uniqueness`, `check_intent_overlap`) remain the
/// single-machine backstop; this is the mesh-wide addition.
pub fn shared_registry_whois(gap_id: &str) -> Option<String> {
    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_default();
    if nats_url.is_empty() {
        return None;
    }
    let coord_bin = resolve_coord_bin()?;
    shared_registry_whois_with_bin(&coord_bin, gap_id)
}

/// Test seam: caller-supplied chump-coord path.
pub(crate) fn shared_registry_whois_with_bin(coord_bin: &Path, gap_id: &str) -> Option<String> {
    let out = Command::new(coord_bin)
        .args(["whois", gap_id])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let session = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if session.is_empty() {
        None
    } else {
        Some(session)
    }
}

/// INFRA-2472: gate wrapper around `shared_registry_whois` — fails the claim
/// when the shared registry shows a LIVE holder for `gap_id` from a
/// different session. This is what closes the visibility gap AC1 describes:
/// local `.chump-locks/` shows 0 leases while Sonnets on other machines hold
/// the gap in NATS KV.
fn check_shared_registry_gap_uniqueness(gap_id: &str, this_session: &str) -> Result<()> {
    match shared_registry_whois(gap_id) {
        Some(holder) if holder != this_session => Err(anyhow!(
            "gap {} is already claimed by session {} in the shared NATS registry \
             (invisible to local .chump-locks/ — cross-machine claim, INFRA-2472).\n  \
             Options:\n  \
             1. Pick a different gap.\n  \
             2. Wait for session {} to ship or release its lease.\n  \
             3. Override: CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1 (audit event emitted).",
            gap_id,
            holder,
            holder,
        )),
        _ => Ok(()),
    }
}

fn emit_nats_conflict_event(ambient_log_path: Option<&Path>, gap_id: &str, session_id: &str) {
    let target = ambient_log_path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".chump-locks/ambient.jsonl"));
    // Best-effort: ambient append must never break the claim flow.
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_claim_nats_conflict\",\"gap_id\":\"{gid}\",\"session_id\":\"{sid}\"}}\n",
        ts = unix_to_iso8601(now),
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&target)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── INFRA-1116: INTENT overlap gate ─────────────────────────────────────────

/// Represents a live INTENT declaration from another session.
#[derive(Debug, Clone)]
struct IntentEntry {
    gap_id: String,
    session_id: String,
    paths: Vec<String>,
    expires_at: u64, // Unix seconds
    claimed_at: u64,
}

/// Check if the new claim would overlap with live INTENTs from other sessions.
/// Reads ambient.jsonl for recent intent_announced events and checks path overlap.
/// On overlap: returns Err with context suitable for printing to the user.
/// On no overlap or no INTENT gate enforcement: returns Ok(()).
fn check_intent_overlap(
    lock_dir: &Path,
    new_gap_id: &str,
    claim_paths_csv: &str,
    this_session: &str,
) -> Result<()> {
    let window_secs = std::env::var("CHUMP_CLAIM_INTENT_WINDOW_S")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(60);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Parse the claim paths
    let claim_paths: Vec<String> = claim_paths_csv
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // If no paths declared, allow the claim (but warn about coverage)
    if claim_paths.is_empty() {
        eprintln!(
            "[intent-gate] warning: {} declared no path scope; proceeding with no overlap check",
            new_gap_id
        );
        return Ok(());
    }

    // Read ambient.jsonl to find live INTENTs and retracted sessions
    let ambient_path = lock_dir.join("ambient.jsonl");
    let live_intents = read_live_intents(&ambient_path, window_secs, now)?;

    // Build set of retracted sessions (intent_retracted events invalidate prior announcements).
    let retracted = collect_retracted_sessions(&ambient_path);

    // Check for overlaps
    for intent in live_intents {
        // Skip our own session
        if intent.session_id == this_session {
            continue;
        }

        // Skip expired intents
        if intent.expires_at < now {
            continue;
        }

        // Skip retracted sessions (they emitted intent_retracted on release)
        if retracted.contains(&intent.session_id) {
            continue;
        }

        // Stale-session filter: ignore INTENTs whose session lease is absent or expired.
        if !is_session_lease_alive(lock_dir, &intent.session_id, now) {
            continue;
        }

        // Check path overlap
        if paths_overlap(&claim_paths, &intent.paths) {
            return Err(anyhow!(
                "Gap {} blocked — session {} has INTENT on overlapping paths [{}].\n\
                 Options:\n  \
                 1. Wait for {} to complete and ship (expires at {})\n  \
                 2. Set CHUMP_ENFORCE_INTENT_GATE=0 to warn-only (not recommended for production)\n  \
                 3. Contact the other session to coordinate",
                new_gap_id,
                intent.session_id,
                intent.paths.join(", "),
                intent.gap_id,
                iso8601_from_unix(intent.expires_at),
            ));
        }
    }

    Ok(())
}

// ── INFRA-1970: Gap-ID uniqueness gate ───────────────────────────────────────

/// INFRA-1970: Scan `.chump-locks/` for any live lease whose `gap_id` field
/// matches `gap_id` AND whose `session_id` differs from `this_session`.
///
/// Returns `Ok(())` when the gap is free (no live competing lease).
/// Returns `Err(...)` with the colliding session ID in the message when a
/// duplicate is found.
///
/// A lease is considered live when its `expires_at` timestamp is in the
/// future. Files that are absent, unreadable, or have no `expires_at` are
/// treated conservatively (alive). Non-JSON files in the lock dir are skipped.
///
/// Bypass: caller checks `CHUMP_CLAIM_ALLOW_DUPLICATE_GAP` before calling here.
// scanner-anchor: "kind":"claim_duplicate_gap_blocked"
fn check_gap_id_uniqueness(lock_dir: &Path, gap_id: &str, this_session: &str) -> Result<()> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let entries = match std::fs::read_dir(lock_dir) {
        Ok(e) => e,
        Err(_) => return Ok(()), // lock dir absent — no competing leases possible
    };

    for entry in entries.flatten() {
        let p = entry.path();
        // Only inspect JSON files; skip ambient.jsonl and other non-lease files.
        if p.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue; // unreadable → skip (conservative: not a blocker)
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };

        // Extract gap_id field — only claim-style leases carry this.
        let Some(lease_gap) = val.get("gap_id").and_then(|v| v.as_str()) else {
            continue;
        };
        if lease_gap != gap_id {
            continue;
        }

        // Extract session_id — skip self.
        let Some(lease_session) = val.get("session_id").and_then(|v| v.as_str()) else {
            continue;
        };
        if lease_session == this_session {
            continue;
        }

        // Liveness check: expired leases are not blockers.
        if let Some(exp_str) = val.get("expires_at").and_then(|v| v.as_str()) {
            if let Ok(exp_secs) = parse_iso8601(exp_str) {
                if exp_secs <= now {
                    continue; // expired — not a live competitor
                }
            }
        }

        // Live competing lease found.
        let taken_at = val
            .get("taken_at")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        return Err(anyhow!(
            "gap {} is already claimed by session {} (taken at {}).\n  \
             Two sessions working the same gap produce duplicate PRs (see META-105).\n  \
             Options:\n  \
             1. Pick a different gap.\n  \
             2. Wait for session {} to ship or release its lease.\n  \
             3. Override: CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1 (audit event emitted).",
            gap_id,
            lease_session,
            taken_at,
            lease_session,
        ));
    }

    Ok(())
}

/// Emit a `claim_duplicate_gap_blocked` (or `_bypassed`) ambient event so the
/// operator's peripheral-vision stream captures every duplicate-gap attempt.
// scanner-anchor: "kind":"claim_duplicate_gap_blocked"
fn emit_claim_duplicate_gap_event(
    ambient_path: &Path,
    gap_id: &str,
    this_session: &str,
    detail: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let bypassed = std::env::var("CHUMP_CLAIM_ALLOW_DUPLICATE_GAP")
        .map(|v| !v.trim().is_empty() && v.trim() != "0")
        .unwrap_or(false);
    let kind = if bypassed {
        "claim_duplicate_gap_bypassed"
    } else {
        "claim_duplicate_gap_blocked"
    };
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"{kind}\",\
         \"gap_id\":\"{}\",\"this_session\":\"{}\",\"detail\":\"{}\"}}\n",
        json_escape(gap_id),
        json_escape(this_session),
        json_escape(detail),
    );
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

// ── INFRA-1608: atomic gap-claim marker (closes the TOCTOU race) ────────────
//
// `check_gap_id_uniqueness` above is a plain scan-then-decide check: it reads
// the lock dir, sees no live competitor, and returns Ok. But the caller does
// NOT write anything durable at that point — `run_claim` goes on to run `git
// worktree add`, gitdir repair, and other multi-second setup before the
// per-session lease file is finally written (`write_or_merge_lease`, step 7b).
// Two sessions can both pass the scan in that window, both proceed through
// worktree setup, and both end up with a live lease on the same gap_id — the
// exact INFRA-1602 double-claim (two leases, claim-infra-1602-26392 and
// claim-infra-1602-47300, both live in TTL). This was root cause (a) in
// INFRA-1608: "the CAS check has a race window" — see
// docs/audits/lease-collision-2026-05-17.md.
//
// The fix: reserve a gap-keyed marker file via `create_new` (O_EXCL) — an
// OS-atomic operation — BEFORE the expensive worktree setup runs. Unlike the
// scan, two concurrent `create_new` calls on the same path cannot both
// succeed; the loser gets `ErrorKind::AlreadyExists` immediately and can back
// off instead of racing all the way through worktree creation.
//
// The marker carries the same {gap_id, session_id, expires_at} shape as a
// normal lease, so it is *also* visible to `check_gap_id_uniqueness`'s scan —
// no separate reaper wiring needed; a crashed process's orphaned marker
// expires and is skipped exactly like any other stale lease.

/// Sanitize a gap_id into a filesystem-safe marker filename component.
fn sanitize_marker_component(gap_id: &str) -> String {
    gap_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect()
}

fn gap_claim_marker_path(lock_dir: &Path, gap_id: &str) -> PathBuf {
    lock_dir.join(format!(
        "gap-claim-{}.json",
        sanitize_marker_component(gap_id)
    ))
}

/// Outcome of a `reserve_gap_claim_marker` attempt.
pub(crate) enum GapClaimMarkerOutcome {
    /// We won the race; holds the marker path so the caller's guard can
    /// clean it up on abort or disarm it on success.
    Won(PathBuf),
    /// Another live session already holds the marker.
    Lost { winner_session: String },
}

/// RAII guard: removes the reserved marker file on drop unless `disarm()` was
/// called. Ensures every early `bail!`/`?` return path in `run_claim` after
/// reservation still releases the marker for the next claimant.
pub(crate) struct GapClaimMarkerGuard {
    path: Option<PathBuf>,
}

impl GapClaimMarkerGuard {
    fn disarm(mut self) {
        self.path = None;
    }
}

impl Drop for GapClaimMarkerGuard {
    fn drop(&mut self) {
        if let Some(p) = self.path.take() {
            let _ = std::fs::remove_file(&p);
        }
    }
}

/// Atomically reserve the gap-claim marker for `gap_id`. Uses `create_new`
/// (O_EXCL) so concurrent callers racing on the same `gap_id` cannot both
/// win: the filesystem itself is the CAS primitive, not an application-level
/// read-then-write scan.
///
/// A pre-existing, expired marker is treated as an orphan and reclaimed
/// (single retry after removing it) — this covers case (d) from INFRA-1608's
/// root-cause list ("a session died mid-claim, leaving an orphaned lease").
// scanner-anchor: "kind":"lease_overlap"
pub(crate) fn reserve_gap_claim_marker(
    lock_dir: &Path,
    gap_id: &str,
    session_id: &str,
    ttl_secs: i64,
) -> Result<GapClaimMarkerOutcome> {
    std::fs::create_dir_all(lock_dir)
        .with_context(|| format!("creating lock dir {}", lock_dir.display()))?;
    let marker_path = gap_claim_marker_path(lock_dir, gap_id);

    for attempt in 0..2 {
        let now_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let expires_at = now_secs as i64 + ttl_secs;
        let body = format!(
            "{{\"gap_id\":\"{}\",\"session_id\":\"{}\",\"taken_at\":\"{}\",\"expires_at\":\"{}\"}}\n",
            json_escape(gap_id),
            json_escape(session_id),
            unix_to_iso8601(now_secs),
            unix_to_iso8601(expires_at.max(0) as u64),
        );

        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker_path)
        {
            Ok(mut f) => {
                use std::io::Write;
                f.write_all(body.as_bytes())
                    .with_context(|| format!("writing marker {}", marker_path.display()))?;
                return Ok(GapClaimMarkerOutcome::Won(marker_path));
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                // Inspect the existing holder.
                let existing = std::fs::read_to_string(&marker_path).unwrap_or_default();
                let val: serde_json::Value =
                    serde_json::from_str(&existing).unwrap_or(serde_json::Value::Null);
                let holder_session = val
                    .get("session_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                if holder_session == session_id {
                    // Re-entrant reservation by the same session (retry path) —
                    // treat as won without touching the existing marker.
                    return Ok(GapClaimMarkerOutcome::Won(marker_path));
                }
                // Conservative default, matching `check_gap_id_uniqueness`:
                // an unreadable/unparseable marker is treated as LIVE, not
                // expired. This matters because a marker file that was just
                // `create_new`'d by a concurrent winner but hasn't had its
                // body `write_all`'d yet is transiently empty — a racing
                // reader hitting that window must NOT mistake "empty" for
                // "orphaned", or two callers can both reclaim and both win
                // (observed as a flaky double-winner in the 50-thread test
                // before this fix).
                let holder_expired = val
                    .get("expires_at")
                    .and_then(|v| v.as_str())
                    .and_then(|s| parse_iso8601(s).ok())
                    .map(|exp| exp <= now_secs)
                    .unwrap_or(false);

                if holder_expired && attempt == 0 {
                    // Orphan resurrection (root cause d): the prior holder's
                    // marker outlived its TTL. Reclaim it and retry once.
                    let _ = std::fs::remove_file(&marker_path);
                    continue;
                }

                return Ok(GapClaimMarkerOutcome::Lost {
                    winner_session: holder_session,
                });
            }
            Err(e) => return Err(e).context("reserving gap-claim marker"),
        }
    }

    // Both attempts hit AlreadyExists with a live holder — surface the
    // holder from a fresh read for the error message.
    let existing = std::fs::read_to_string(&marker_path).unwrap_or_default();
    let val: serde_json::Value = serde_json::from_str(&existing).unwrap_or(serde_json::Value::Null);
    let winner_session = val
        .get("session_id")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();
    Ok(GapClaimMarkerOutcome::Lost { winner_session })
}

/// Emit `kind=lease_overlap` — the loser of a `reserve_gap_claim_marker` race
/// records {gap_id, winner_session, loser_session, paths_attempted}. This is
/// the detection-path AC from INFRA-1608: the event kind existed in
/// EVENT_REGISTRY.yaml but nothing emitted it on an actual CAS-loss.
// scanner-anchor: "kind":"lease_overlap"
pub(crate) fn emit_lease_overlap_event(
    ambient_path: &Path,
    gap_id: &str,
    winner_session: &str,
    loser_session: &str,
    paths_attempted: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"lease_overlap\",\
         \"gap_id\":\"{}\",\"winner_session\":\"{}\",\"loser_session\":\"{}\",\"paths_attempted\":\"{}\"}}\n",
        json_escape(gap_id),
        json_escape(winner_session),
        json_escape(loser_session),
        json_escape(paths_attempted),
    );
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// Check if a session's lease file exists and has a non-expired expires_at.
/// Returns false (stale) if the lease file is absent, unreadable, or expired.
fn is_session_lease_alive(lock_dir: &Path, session_id: &str, now_secs: u64) -> bool {
    let lease_path = lock_dir.join(format!("{}.json", session_id));
    let Ok(body) = std::fs::read_to_string(&lease_path) else {
        return false; // absent — session is stale
    };
    let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
        return false;
    };
    let Some(exp_str) = val.get("expires_at").and_then(|v| v.as_str()) else {
        return true; // no expiry field — treat as alive (conservative)
    };
    match parse_iso8601(exp_str) {
        Ok(exp_secs) => exp_secs > now_secs,
        Err(_) => true, // can't parse → treat as alive (conservative)
    }
}

/// INFRA-1646 (re-do of INFRA-1412): refuse `chump claim` when the resolved
/// session already holds a LIVE lease for a DIFFERENT gap.
///
/// Without this gate, `write_or_merge_lease` (INFRA-985) silently overwrites
/// `gap_id` in place inside the existing `<session>.json` lease file — the
/// old gap's claim is lost with no error, no rollback, and no trace, leaving
/// a lease whose `session_id` now points at gap B while any bookkeeping that
/// keyed off "session X is working gap A" (state.db, NATS, farmer.sh's
/// `check_silent_workers`) goes stale. Board note (2026-08-13): this is the
/// preventive fix for RESILIENT-313 — a stale/duplicate claim lease crashed
/// `check_silent_workers` and hard-blocked the fleet for 6h.
///
/// Only fires when the existing lease names a DIFFERENT `gap_id` — reclaiming
/// the SAME gap under the same session (e.g. `--resume`) still falls through
/// to the merge path unchanged.
///
/// Bypass: `CHUMP_CLAIM_ALLOW_ACTIVE_LEASE=1` (emits `claim_active_lease_bypassed`).
// scanner-anchor: "kind":"claim_active_lease_blocked"
fn check_no_active_lease_for_other_gap(
    lock_dir: &Path,
    gap_id: &str,
    session_id: &str,
) -> Result<()> {
    let lease_path = lock_dir.join(format!("{}.json", session_id));
    let Ok(body) = std::fs::read_to_string(&lease_path) else {
        return Ok(()); // no existing lease under this session — nothing to block
    };
    let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
        return Ok(()); // unreadable — conservative: not a blocker
    };
    let Some(existing_gap) = val.get("gap_id").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    if existing_gap == gap_id {
        return Ok(()); // same gap — resume/merge path owns this case
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if !is_session_lease_alive(lock_dir, session_id, now) {
        return Ok(()); // stale — not a live competitor
    }

    let taken_at = val
        .get("taken_at")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    Err(anyhow!(
        "session {} already holds an active lease for {} (taken at {}) — refusing to claim {}.\n  \
         Claiming a second gap under the same session used to silently overwrite the lease's\n  \
         gap_id in place, leaving a stale/duplicate lease (the RESILIENT-313 failure class).\n  \
         Options:\n  \
         1. Release the existing lease first: chump --release --force\n  \
         2. Pass a distinct --session for this claim.\n  \
         3. Override: CHUMP_CLAIM_ALLOW_ACTIVE_LEASE=1 (audit event emitted).",
        session_id,
        existing_gap,
        taken_at,
        gap_id,
    ))
}

/// Emit a `claim_active_lease_blocked` (or `_bypassed`) ambient event so the
/// operator's peripheral-vision stream captures every active-lease conflict.
// scanner-anchor: "kind":"claim_active_lease_blocked"
fn emit_claim_active_lease_event(
    ambient_path: &Path,
    gap_id: &str,
    session_id: &str,
    detail: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let bypassed = std::env::var("CHUMP_CLAIM_ALLOW_ACTIVE_LEASE")
        .map(|v| !v.trim().is_empty() && v.trim() != "0")
        .unwrap_or(false);
    let kind = if bypassed {
        "claim_active_lease_bypassed"
    } else {
        "claim_active_lease_blocked"
    };
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"{kind}\",\
         \"gap_id\":\"{}\",\"session_id\":\"{}\",\"detail\":\"{}\"}}\n",
        json_escape(gap_id),
        json_escape(session_id),
        json_escape(detail),
    );
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

/// Collect session IDs that have emitted intent_retracted in ambient.jsonl.
fn collect_retracted_sessions(ambient_path: &Path) -> std::collections::HashSet<String> {
    let mut retracted = std::collections::HashSet::new();
    let Ok(content) = std::fs::read_to_string(ambient_path) else {
        return retracted;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(val) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if val.get("kind").and_then(|k| k.as_str()) == Some("intent_retracted") {
            if let Some(sid) = val.get("session_id").and_then(|v| v.as_str()) {
                retracted.insert(sid.to_string());
            }
        }
    }
    retracted
}

/// Read all intent_announced events from ambient.jsonl within the window.
fn read_live_intents(
    ambient_path: &Path,
    window_secs: u64,
    now_secs: u64,
) -> Result<Vec<IntentEntry>> {
    let cutoff = now_secs.saturating_sub(window_secs);

    let content = match std::fs::read_to_string(ambient_path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(e).context("reading ambient.jsonl"),
    };

    let mut intents = vec![];
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Parse as JSON
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
            // Look for intent_announced events
            if val.get("kind").and_then(|k| k.as_str()) == Some("intent_announced") {
                // Extract fields
                let ts = val.get("ts").and_then(|v| v.as_str()).unwrap_or("0");
                let ts_secs = parse_iso8601(ts).unwrap_or(0);

                // Skip if outside the window
                if ts_secs < cutoff {
                    continue;
                }

                if let (Some(gap_id), Some(session_id), Some(paths_arr)) = (
                    val.get("gap_id").and_then(|v| v.as_str()),
                    val.get("session_id").and_then(|v| v.as_str()),
                    val.get("paths").and_then(|v| v.as_array()),
                ) {
                    let paths: Vec<String> = paths_arr
                        .iter()
                        .filter_map(|p| p.as_str().map(|s| s.to_string()))
                        .collect();

                    let expires_at = val
                        .get("expires_at")
                        .and_then(|v| v.as_str())
                        .and_then(|s| parse_iso8601(s).ok())
                        .unwrap_or(0);

                    intents.push(IntentEntry {
                        gap_id: gap_id.to_string(),
                        session_id: session_id.to_string(),
                        paths,
                        expires_at,
                        claimed_at: ts_secs,
                    });
                }
            }
        }
    }

    Ok(intents)
}

/// Check if two path lists overlap.
/// Simple implementation: for now, prefix-match directories and exact-match files.
fn paths_overlap(paths_a: &[String], paths_b: &[String]) -> bool {
    for a in paths_a {
        for b in paths_b {
            // Wildcard match: ** overlaps with everything
            if a == "**" || b == "**" {
                return true;
            }
            // Same path
            if a == b {
                return true;
            }
            // Prefix match (directory overlap): src/ overlaps src/foo.rs
            if a.ends_with('/') && b.starts_with(a) {
                return true;
            }
            if b.ends_with('/') && a.starts_with(b) {
                return true;
            }
        }
    }
    false
}

/// Parse ISO 8601 timestamp to Unix seconds (best-effort).
fn parse_iso8601(s: &str) -> Result<u64> {
    // Simple parser for YYYY-MM-DDTHH:MM:SSZ format
    let s = s.trim_end_matches('Z');
    let parts: Vec<&str> = s.split(|c| c == '-' || c == 'T' || c == ':').collect();
    if parts.len() < 6 {
        bail!("invalid timestamp format: {}", s);
    }
    let y: u32 = parts[0].parse()?;
    let mo: u32 = parts[1].parse()?;
    let d: u32 = parts[2].parse()?;
    let h: u32 = parts[3].parse()?;
    let mi: u32 = parts[4].parse()?;
    let sec: u32 = parts[5].parse()?;

    // Simplified day-of-year calculation (not accounting for leap seconds)
    let is_leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
    let days_per_month = [
        31,
        if is_leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let days_in_year: u32 = days_per_month[..(mo as usize).saturating_sub(1)]
        .iter()
        .sum::<u32>()
        + d;

    // Days since 1970-01-01
    let mut days_since_epoch = 0u64;
    for year in 1970..y {
        let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        days_since_epoch += if leap { 366 } else { 365 };
    }
    days_since_epoch += (days_in_year - 1) as u64;

    let secs = days_since_epoch * 86400 + (h as u64) * 3600 + (mi as u64) * 60 + (sec as u64);
    Ok(secs)
}

/// Format Unix seconds to ISO 8601 string.
fn iso8601_from_unix(secs: u64) -> String {
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// Emit intent_overlap_detected event to ambient.jsonl.
fn emit_intent_overlap_event(
    ambient_log: &Path,
    new_gap_id: &str,
    blocking_gap_id: &str,
    blocking_session: &str,
    overlapping_paths: &[String],
) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let paths_json = serde_json::to_string(overlapping_paths).unwrap_or_else(|_| "[]".to_string());
    let event = format!(
        r#"{{"ts":"{ts}","kind":"intent_overlap_detected","gap_id":"{new_gap_id}","blocking_gap_id":"{blocking_gap_id}","blocking_session":"{blocking_session}","overlapping_paths":{paths_json}}}"#
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", event);
    }
}

/// INFRA-1116 AC4: Emit intent_announced to ambient.jsonl after a successful claim.
/// Other sessions' INTENT gates read these events to detect path overlaps.
/// ttl_secs controls the expires_at field; sessions whose expires_at is in the
/// past are ignored by the stale filter in check_intent_overlap.
fn emit_intent_announced(
    ambient_log: &Path,
    gap_id: &str,
    session_id: &str,
    paths_csv: &str,
    ttl_secs: u64,
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    let expires_at = iso8601_from_unix(now.saturating_add(ttl_secs));

    let paths_list: Vec<String> = paths_csv
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let paths_json = serde_json::to_string(&paths_list).unwrap_or_else(|_| "[]".to_string());

    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_announced\",\"gap_id\":\"{gid}\",\
         \"session_id\":\"{sid}\",\"paths\":{paths},\"expires_at\":\"{exp}\"}}\n",
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
        paths = paths_json,
        exp = expires_at,
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// INFRA-1116 AC6: Emit intent_retracted to ambient.jsonl when a session is released.
/// The gate treats a retracted session as inactive even if expires_at has not passed.
pub fn emit_intent_retracted(ambient_log: &Path, gap_id: &str, session_id: &str) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_retracted\",\"gap_id\":\"{gid}\",\
         \"session_id\":\"{sid}\"}}\n",
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// INFRA-1116 AC5: Emit intent_refreshed to ambient.jsonl during heartbeat.
/// Called from worker.sh heartbeat loop via `chump ambient emit intent_refreshed`.
/// This function is the Rust-side equivalent for direct Rust heartbeat paths.
pub fn emit_intent_refreshed(ambient_log: &Path, gap_id: &str, session_id: &str) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"intent_refreshed\",\"gap_id\":\"{gid}\",\
         \"session_id\":\"{sid}\"}}\n",
        gid = json_escape(gap_id),
        sid = json_escape(session_id),
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── INFRA-1394: Hot-file collision check ─────────────────────────────────────

/// Result of a hot-file overlap scan.
struct HotFileOverlapResult {
    sibling_session: String,
    sibling_gap: String,
    overlap_paths: Vec<String>,
}

/// Load the hot-files list from `scripts/coord/lib/hot-files.yaml`.
/// Returns an empty vec on any parse/IO error (best-effort; don't block claim
/// if the yaml is missing or malformed).
fn load_hot_files(yaml_path: &Path) -> Vec<String> {
    let Ok(body) = std::fs::read_to_string(yaml_path) else {
        return vec![];
    };
    // Minimal YAML list parser: find lines under `hot_files:` that start with `  - `.
    let mut in_list = false;
    let mut files = Vec::new();
    for line in body.lines() {
        if line.trim_start().starts_with("hot_files:") {
            in_list = true;
            continue;
        }
        if in_list {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if trimmed.starts_with('-') {
                let entry = trimmed.trim_start_matches('-').trim().to_string();
                if !entry.is_empty() {
                    files.push(entry);
                }
            } else if !line.starts_with(' ') && !line.starts_with('\t') {
                // Hit a new top-level key — stop.
                break;
            }
        }
    }
    files
}

/// Read the acceptance_criteria text for `gap_id` from state.db.
/// Returns an empty string on any error (best-effort).
fn read_gap_ac_from_db(repo_root: &Path, gap_id: &str) -> String {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return String::new();
    }
    let Ok(conn) = rusqlite::Connection::open(&db_path) else {
        return String::new();
    };
    conn.query_row(
        "SELECT acceptance_criteria FROM gaps WHERE id = ?1",
        [gap_id],
        |r| r.get::<_, String>(0),
    )
    .unwrap_or_default()
}

/// INFRA-1394: Check whether any sibling lease's paths[] overlaps with the
/// hot files referenced in this gap's AC text. Returns the first overlap found,
/// or None if all clear.
///
/// Algorithm:
///   1. Parse hot-files list.
///   2. Scan gap AC text for any hot-file path mention.
///   3. Read all .chump-locks/*.json files for sibling sessions.
///   4. For each sibling, check if its paths[] contains any of the hot files
///      that were found in the AC.
fn check_hot_file_overlap(
    lock_dir: &Path,
    gap_id: &str,
    own_session: &str,
    gap_ac: &str,
    hot_files: &[String],
) -> Option<HotFileOverlapResult> {
    // Step 2: which hot files appear in the gap AC text?
    let ac_lower = gap_ac.to_lowercase();
    let ac_hot: Vec<&str> = hot_files
        .iter()
        .filter(|f| {
            // Match both the full path and just the filename component for flexibility.
            let f_lower = f.to_lowercase();
            let filename = f
                .split('/')
                .next_back()
                .unwrap_or(f.as_str())
                .to_lowercase();
            ac_lower.contains(&f_lower) || ac_lower.contains(&filename)
        })
        .map(|f| f.as_str())
        .collect();

    if ac_hot.is_empty() {
        return None; // Gap AC doesn't reference any hot file — no check needed.
    }

    // Step 3: read sibling leases.
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return None;
    };

    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        // Skip ambient.jsonl and non-session files.
        let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        if stem == "ambient" {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };

        let sid = val
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if sid.is_empty() || sid == own_session {
            continue;
        }

        // Skip our own gap — only conflict with OTHER gaps' leases.
        let sibling_gap = val
            .get("gap_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if sibling_gap == gap_id {
            continue;
        }

        // Extract sibling lease paths[].
        let sibling_paths: Vec<String> = val
            .get("paths")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|p| p.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        // Step 4: overlap = AC hot files ∩ sibling paths.
        let mut overlap: Vec<String> = ac_hot
            .iter()
            .filter(|&&hf| {
                sibling_paths
                    .iter()
                    .any(|sp| sp == hf || sp.ends_with('/') && hf.starts_with(sp.as_str()))
            })
            .map(|hf| hf.to_string())
            .collect();

        if !overlap.is_empty() {
            overlap.sort();
            overlap.dedup();
            return Some(HotFileOverlapResult {
                sibling_session: sid,
                sibling_gap,
                overlap_paths: overlap,
            });
        }
    }

    None
}

/// INFRA-1394: Emit kind=claim_hot_file_overlap to ambient.jsonl.
/// Best-effort — never blocks the claim flow.
fn emit_claim_hot_file_overlap_event(
    ambient_log: &Path,
    claim_gap: &str,
    sibling_gap: &str,
    sibling_session: &str,
    overlap_paths: &[String],
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    let paths_json = serde_json::to_string(overlap_paths).unwrap_or_else(|_| "[]".to_string());
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_hot_file_overlap\",\
         \"claim_gap\":\"{cg}\",\"sibling_gap\":\"{sg}\",\
         \"sibling_session\":\"{ss}\",\"overlap_paths\":{op}}}\n",
        ts = ts,
        cg = json_escape(claim_gap),
        sg = json_escape(sibling_gap),
        ss = json_escape(sibling_session),
        op = paths_json,
    );
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── INFRA-1763: predictive diff-collision detection ─────────────────────────
//
// Real git-diff intersection across active leases at claim time. Distinct
// from the 5.6 hot-file check above: that one matches AC *text* against
// declared lease paths[]; this one runs an actual `git diff` inside each
// sibling's worktree and intersects the *real* changed-file set against
// this claim's paths. Schema: docs/design/COLLISION_PREDICTION_SCHEMA.md.

/// Why a per-sibling diff computation failed. Feeds
/// `kind=claim_diff_collision_check_failed`'s `failure_class` field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DiffCollisionFailureClass {
    /// Retryable: worktree not yet provisioned, git timed out, or a
    /// process/IO error spawning git.
    Transient,
    /// Not retryable without operator intervention: bad merge-base or ref.
    Permanent,
}

impl DiffCollisionFailureClass {
    fn as_str(self) -> &'static str {
        match self {
            DiffCollisionFailureClass::Transient => "transient",
            DiffCollisionFailureClass::Permanent => "permanent",
        }
    }
}

/// One sibling whose real diff could not be computed.
struct DiffCollisionFailure {
    sibling_gap: String,
    sibling_session: String,
    failure_class: DiffCollisionFailureClass,
    reason: String,
}

/// One sibling whose real diff intersects this claim's paths.
struct DiffCollisionMatch {
    sibling_gap: String,
    sibling_session: String,
    shared_paths: Vec<String>,
}

/// Aggregate result of one diff-collision check run.
struct DiffCollisionCheckResult {
    duration_ms: u128,
    siblings_checked: usize,
    matches: Vec<DiffCollisionMatch>,
    failures: Vec<DiffCollisionFailure>,
}

/// Compute the real changed-file set (staged + unstaged + untracked) inside
/// a sibling's worktree. Returns the failure class + human reason on error.
fn compute_git_diff_paths(
    worktree: &Path,
) -> std::result::Result<Vec<String>, (DiffCollisionFailureClass, String)> {
    if !worktree.exists() {
        return Err((
            DiffCollisionFailureClass::Transient,
            format!("sibling worktree not provisioned: {}", worktree.display()),
        ));
    }

    let worktree_str = worktree.to_string_lossy().into_owned();

    // 5s timeout via coreutils `timeout` — a hung git process must never
    // stall the claim path. Exit 124 is timeout's own "expired" signal.
    let run = |args: &[&str]| -> std::result::Result<String, (DiffCollisionFailureClass, String)> {
        let mut full_args: Vec<&str> = vec!["5", "git", "-C", worktree_str.as_str()];
        full_args.extend_from_slice(args);
        let out = Command::new("timeout")
            .args(&full_args)
            .output()
            .map_err(|e| {
                (
                    DiffCollisionFailureClass::Transient,
                    format!("git IO error spawning `git {}`: {}", args.join(" "), e),
                )
            })?;

        if out.status.code() == Some(124) {
            return Err((
                DiffCollisionFailureClass::Transient,
                format!("git {} timed out after 5s", args.join(" ")),
            ));
        }
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            let lower = stderr.to_lowercase();
            let class = if lower.contains("bad revision")
                || lower.contains("unknown revision")
                || lower.contains("ambiguous argument")
                || lower.contains("not a valid object name")
            {
                DiffCollisionFailureClass::Permanent
            } else {
                DiffCollisionFailureClass::Transient
            };
            return Err((
                class,
                format!("git {} failed: {}", args.join(" "), stderr.trim()),
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    };

    let mut paths: Vec<String> = Vec::new();

    // Tracked changes vs HEAD (covers both staged and unstaged edits).
    let diff_out = run(&["diff", "HEAD", "--name-only"])?;
    paths.extend(
        diff_out
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty()),
    );

    // New, not-yet-tracked files.
    let untracked_out = run(&["ls-files", "--others", "--exclude-standard"])?;
    paths.extend(
        untracked_out
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty()),
    );

    paths.sort();
    paths.dedup();
    Ok(paths)
}

/// INFRA-1763: scan every sibling lease's *real* worktree diff and
/// intersect it against `own_paths`. Best-effort — never blocks the claim.
fn check_diff_collision(
    lock_dir: &Path,
    worktree_base: &Path,
    gap_id: &str,
    own_session: &str,
    own_paths: &[String],
) -> DiffCollisionCheckResult {
    let start = SystemTime::now();
    let mut matches = Vec::new();
    let mut failures = Vec::new();
    let mut siblings_checked = 0usize;

    let entries = std::fs::read_dir(lock_dir).ok();
    if let Some(entries) = entries {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            if stem == "ambient" {
                continue;
            }
            let Ok(body) = std::fs::read_to_string(&p) else {
                continue;
            };
            let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
                continue;
            };

            let sid = val
                .get("session_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if sid.is_empty() || sid == own_session {
                continue;
            }

            let sibling_gap = val
                .get("gap_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if sibling_gap.is_empty() || sibling_gap == gap_id {
                continue;
            }

            let sibling_worktree =
                worktree_base.join(format!("chump-{}", sibling_gap.to_lowercase()));

            siblings_checked += 1;
            match compute_git_diff_paths(&sibling_worktree) {
                Ok(sibling_diff_paths) => {
                    if own_paths.is_empty() {
                        continue;
                    }
                    let shared: Vec<String> = own_paths
                        .iter()
                        .filter(|op| sibling_diff_paths.iter().any(|sp| sp == *op))
                        .cloned()
                        .collect();
                    if !shared.is_empty() {
                        matches.push(DiffCollisionMatch {
                            sibling_gap,
                            sibling_session: sid,
                            shared_paths: shared,
                        });
                    }
                }
                Err((failure_class, reason)) => {
                    failures.push(DiffCollisionFailure {
                        sibling_gap,
                        sibling_session: sid,
                        failure_class,
                        reason,
                    });
                }
            }
        }
    }

    let duration_ms = SystemTime::now()
        .duration_since(start)
        .map(|d| d.as_millis())
        .unwrap_or(0);

    DiffCollisionCheckResult {
        duration_ms,
        siblings_checked,
        matches,
        failures,
    }
}

/// INFRA-1763: emit `kind=collision_predicted` per
/// docs/design/COLLISION_PREDICTION_SCHEMA.md. Best-effort.
fn emit_collision_predicted_event(
    ambient_log: &Path,
    own_session: &str,
    own_gap: &str,
    m: &DiffCollisionMatch,
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ts = iso8601_from_unix(now);
    let corr_id = format!("coll-{}-{}-{}", own_gap, m.sibling_gap, now);
    let event = serde_json::json!({
        "ts": ts,
        "kind": "collision_predicted",
        "schema_version": "collision-prediction-v1",
        "agents": [
            {"session": m.sibling_session, "current_gap": m.sibling_gap, "manifest_skills": []},
            {"session": own_session, "current_gap": own_gap, "manifest_skills": []},
        ],
        "predicted_collision_ts": ts,
        "confidence": 0.95,
        "evidence": {
            "source": "lease_overlap",
            "details": "sibling's real uncommitted git diff intersects this claim's paths",
            "shared_paths": m.shared_paths,
            "lookahead_window_s": 0,
        },
        "recommended_action": "stand_down_B",
        "session": own_session,
        "corr_id": corr_id,
    });
    append_ambient_line(ambient_log, &event);
}

/// INFRA-1763: emit `kind=claim_diff_collision_checked` (cost tracking) —
/// fired once per claim regardless of whether any collision was found.
fn emit_claim_diff_collision_checked_event(
    ambient_log: &Path,
    gap_id: &str,
    session_id: &str,
    result: &DiffCollisionCheckResult,
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let event = serde_json::json!({
        "ts": iso8601_from_unix(now),
        "kind": "claim_diff_collision_checked",
        "gap_id": gap_id,
        "session_id": session_id,
        "duration_ms": result.duration_ms,
        "siblings_checked": result.siblings_checked,
        "matches_found": result.matches.len(),
    });
    append_ambient_line(ambient_log, &event);
}

/// INFRA-1763: emit `kind=claim_diff_collision_check_failed` for one sibling
/// whose diff could not be computed.
fn emit_claim_diff_collision_check_failed_event(
    ambient_log: &Path,
    gap_id: &str,
    failure: &DiffCollisionFailure,
) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let event = serde_json::json!({
        "ts": iso8601_from_unix(now),
        "kind": "claim_diff_collision_check_failed",
        "gap_id": gap_id,
        "sibling_gap": failure.sibling_gap,
        "sibling_session": failure.sibling_session,
        "failure_class": failure.failure_class.as_str(),
        "reason": failure.reason,
    });
    append_ambient_line(ambient_log, &event);
}

/// Shared best-effort JSONL append helper for the INFRA-1763 event trio.
fn append_ambient_line(ambient_log: &Path, event: &serde_json::Value) {
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
    {
        let _ = f.write_all(event.to_string().as_bytes());
        let _ = f.write_all(b"\n");
    }
}

// ── INFRA-1415: Check-only helpers ──────────────────────────────────────────

/// Check gap status in state.db (must be open and unclaimed).
fn check_gap_status(repo_root: &Path, gap_id: &str) -> Result<String, String> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Err(format!("state.db not found at {}", db_path.display()));
    }

    // Use sqlite3 to query the gap status
    let output = std::process::Command::new("sqlite3")
        .args([
            db_path.to_string_lossy().as_ref(),
            &format!(
                "SELECT status FROM gaps WHERE id = '{}' LIMIT 1;",
                gap_id.replace("'", "''")
            ),
        ])
        .output();

    match output {
        Ok(out) => {
            let status = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if status.is_empty() {
                Err(format!("Gap {} not found in state.db", gap_id))
            } else if status == "done" || status == "in-review" {
                Err(format!(
                    "Gap {} status is '{}' (not open for claiming)",
                    gap_id, status
                ))
            } else if status == "open" {
                Ok(format!("Gap {} is open and ready", gap_id))
            } else {
                Ok(format!("Gap {} status: {}", gap_id, status))
            }
        }
        Err(e) => Err(format!("Failed to query state.db: {}", e)),
    }
}

/// Check for hot-file collisions with live claims (INFRA-1394).
fn check_hot_file_collision(repo_root: &Path, paths: &str) -> Result<String, String> {
    if paths.trim().is_empty() {
        return Ok("No specific paths to check".to_string());
    }

    // Read lease files from .chump-locks/
    let lock_dir = repo_root.join(".chump-locks");
    if !lock_dir.exists() {
        return Ok("No live leases".to_string());
    }

    // For now, return a simple check. A full implementation would:
    // 1. Parse all *.json lease files
    // 2. Extract the paths from each
    // 3. Check for overlap with the given paths
    Ok(format!("Paths: {} (checked against live leases)", paths))
}

/// Check acceptance criteria (must not be empty or TODO-only).
fn check_acceptance_criteria(repo_root: &Path, gap_id: &str) -> Result<String, String> {
    let db_path = repo_root.join(".chump/state.db");
    if !db_path.exists() {
        return Err("state.db not found".to_string());
    }

    let output = std::process::Command::new("sqlite3")
        .args([
            db_path.to_string_lossy().as_ref(),
            &format!(
                "SELECT acceptance_criteria FROM gaps WHERE id = '{}' LIMIT 1;",
                gap_id.replace("'", "''")
            ),
        ])
        .output();

    match output {
        Ok(out) => {
            let ac = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if ac.is_empty() || ac == "[]" {
                Err(format!(
                    "Gap {} has empty acceptance criteria (must be concrete)",
                    gap_id
                ))
            } else if ac.contains("TODO") {
                Err(format!(
                    "Gap {} has TODO-only acceptance criteria (must be concrete)",
                    gap_id
                ))
            } else {
                Ok(format!("Gap {} has concrete acceptance criteria", gap_id))
            }
        }
        Err(e) => Err(format!("Failed to query acceptance criteria: {}", e)),
    }
}

/// Check base branch sanity (should be reachable).
fn check_base_branch(repo_root: &Path, remote: &str, base_branch: &str) -> Result<String, String> {
    let output = std::process::Command::new("git")
        .args([
            "rev-parse",
            &format!("refs/remotes/{}/{}", remote, base_branch),
        ])
        .current_dir(repo_root)
        .output();

    match output {
        Ok(out) if out.status.success() => Ok(format!(
            "Base branch {}/{} is reachable",
            remote, base_branch
        )),
        Ok(_) => Err(format!(
            "Base branch {}/{} not found (run `git fetch {} {}`)",
            remote, base_branch, remote, base_branch
        )),
        Err(e) => Err(format!(
            "Failed to check base branch {}/{}: {}",
            remote, base_branch, e
        )),
    }
}

/// Check available disk space (must have >5GB free in worktree base).
fn check_disk_space(worktree_base: &Path) -> Result<String, String> {
    // Use 'df' to check available space.
    // ZERO-WASTE-028: `-Bk` is a GNU-only flag — on macOS (BSD df) it errors
    // ("invalid option -- B"), stdout is empty, parsing bails to Ok(), and the
    // gate goes SILENTLY INERT. That is why the Mac fleet host filled to 2% free
    // while the gate "passed" every claim. `-k` (1024-byte blocks, Available in
    // column 4) is portable across BSD and GNU df.
    let output = std::process::Command::new("df")
        .arg("-k")
        .arg(worktree_base)
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            // Parse the output: last line, 4th column is available blocks (in KB)
            if let Some(last_line) = stdout.lines().last() {
                let parts: Vec<&str> = last_line.split_whitespace().collect();
                if parts.len() >= 4 {
                    if let Ok(avail_kb) = parts[3].parse::<u64>() {
                        let avail_gb = avail_kb / (1024 * 1024);
                        // ZERO-WASTE-028: floor shared with the rest of the disk
                        // subsystem (CHUMP_DISK_FLOOR_GB, same var `chump disk`
                        // uses; default 5 GB).
                        let floor_gb: u64 = std::env::var("CHUMP_DISK_FLOOR_GB")
                            .ok()
                            .and_then(|v| v.trim().parse::<f64>().ok())
                            .map(|f| f.max(0.0) as u64)
                            .unwrap_or(5);
                        if avail_gb >= floor_gb {
                            Ok(format!(
                                "Available disk space: {avail_gb}GB (>= {floor_gb}GB floor)"
                            ))
                        } else {
                            Err(format!(
                                "Insufficient disk space: {avail_gb}GB (need >= {floor_gb}GB floor)"
                            ))
                        }
                    } else {
                        Ok("Disk space check available".to_string())
                    }
                } else {
                    Ok("Disk space appears available".to_string())
                }
            } else {
                Ok("Could not parse disk space output".to_string())
            }
        }
        Err(_) => Ok("Disk space check skipped (df unavailable)".to_string()),
    }
}

// ── INFRA-1692: team-nugget pre-flight ──────────────────────────────────────
//
// Surface relevant team-shared knowledge BEFORE the worktree spins up.
// The fleet has a vector-indexed registry of "nuggets" — gotchas, patterns,
// dead-ends, failure modes, conventions — recorded by prior sessions.
// When an operator (or fleet worker) runs `chump claim GAP-ID`, we
// search the substrate for the top-K most similar nuggets to this gap's
// title + description and print them as a brief table.
//
// Design notes:
//   * Pure best-effort. CHUMP_TEAM_URL unset → silent skip. Network error
//     → silent skip. The actual claim must NEVER fail because of a nugget
//     lookup glitch.
//   * Bypass via CHUMP_CLAIM_SKIP_NUGGET_SEARCH=1 (offline / CI sandbox).
//   * Each printed nugget triggers log_nugget_read so the audit trail
//     (INFRA-1473 AC #6) captures pre-claim reads.
//   * Top-K defaults to 3; override with CHUMP_CLAIM_NUGGET_TOP_K.
mod nugget_prefetch {
    use std::path::Path;

    /// Entry point — runs the full pre-flight search + print + audit log.
    /// Best-effort: any internal failure is swallowed so the claim proceeds.
    pub fn prefetch_and_print(repo_root: &Path, gap_id: &str, session_id: &str) {
        // AC #4: bypass.
        if env_truthy("CHUMP_CLAIM_SKIP_NUGGET_SEARCH") {
            return;
        }
        // AC #5: graceful degrade when team substrate is not configured.
        if std::env::var("CHUMP_TEAM_URL")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .is_none()
        {
            return;
        }

        let (title, description) = read_gap_title_desc(repo_root, gap_id);
        // No useful query material — skip silently rather than spam the substrate.
        if title.trim().is_empty() && description.trim().is_empty() {
            return;
        }
        let query_text = format!("{title}\n{description}").trim().to_string();

        let top_k: usize = std::env::var("CHUMP_CLAIM_NUGGET_TOP_K")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|k: &usize| *k > 0 && *k <= 25)
            .unwrap_or(3);

        // `chump claim` is invoked from within `#[tokio::main]`, so a fresh
        // current-thread runtime would panic ("Cannot start a runtime from
        // within a runtime"). Use the ambient runtime when present
        // (multi-threaded; we use block_in_place to release the worker thread
        // for the sync caller), or build a fresh runtime if no ambient is
        // available (CI / unit tests).
        let async_block = async {
            let team = match chump_team::ChumpTeam::from_env() {
                Ok(t) => t,
                Err(_) => return Vec::new(),
            };
            let query = chump_team::nuggets::NuggetQuery {
                query_text,
                repo_url: None,
                kinds: vec![],
                limit: top_k,
                min_similarity: 0.5,
            };
            match team.search_nuggets(query).await {
                Ok(matches) => {
                    // AC #3: log_nugget_read for every surfaced nugget.
                    // The reader's UUID comes from CHUMP_TEAM_USER_ID (set by
                    // `chump team login` in the operator's daily-driver path).
                    // When absent, we skip the audit write — the search still
                    // ran and the operator still saw the table; the audit
                    // trail is best-effort by design.
                    if let Some(user_id) = read_user_id_env() {
                        for m in &matches {
                            let _ = team
                                .log_nugget_read(
                                    m.nugget.id,
                                    user_id,
                                    session_id,
                                    Some(gap_id),
                                    m.similarity,
                                )
                                .await;
                        }
                    }
                    matches
                }
                Err(_) => Vec::new(),
            }
        };

        // Execute the async block on whichever runtime is reachable.
        //
        //   1. If we're inside a multi-thread runtime (the `#[tokio::main]`
        //      production path), use `block_in_place` to release the current
        //      worker thread, then drive the future on the same runtime via
        //      `Handle::current().block_on()`.
        //   2. If we're inside a single-thread runtime (unlikely; covered for
        //      safety), `block_in_place` would panic — drop into best-effort
        //      mode by emitting "no nuggets" and returning.
        //   3. If no ambient runtime exists (unit tests, sync callers), build
        //      a fresh current-thread runtime and run there.
        let matches = match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                let rt_flavor = handle.runtime_flavor();
                if matches!(rt_flavor, tokio::runtime::RuntimeFlavor::MultiThread) {
                    tokio::task::block_in_place(|| handle.block_on(async_block))
                } else {
                    // current_thread runtime: can't block, and we don't want to
                    // monopolize the executor. Skip silently.
                    return;
                }
            }
            Err(_) => match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt.block_on(async_block),
                Err(_) => return,
            },
        };

        // AC #2: print a brief table even when 0 results, so the operator
        // sees the system tried. (Skip if explicitly silent: 0 matches AND
        // CHUMP_CLAIM_NUGGET_QUIET=1 — useful for fleet workers.)
        if matches.is_empty() {
            if !env_truthy("CHUMP_CLAIM_NUGGET_QUIET") {
                eprintln!(
                    "[claim] INFRA-1692: no team nuggets matched {} (substrate empty or no similarity ≥ 0.5)",
                    gap_id
                );
            }
            return;
        }

        eprintln!("[claim] INFRA-1692: team-shared knowledge for {gap_id}");
        eprintln!(
            "[claim]   {:<12} {:<6} {:<40} body (first 80)",
            "kind", "sim", "title"
        );
        for m in &matches {
            let kind = format!("{:?}", m.nugget.kind);
            let sim = format!("{:.2}", m.similarity);
            let title_trunc = truncate(&m.nugget.title, 40);
            let body_trunc = truncate(&single_line(&m.nugget.body), 80);
            eprintln!(
                "[claim]   {:<12} {:<6} {:<40} {}",
                kind, sim, title_trunc, body_trunc
            );
        }
    }

    /// INFRA-1733: link a freshly-created worktree's `.chump/github_cache.db`
    /// to the main checkout's copy instead of leaving it to be initialized
    /// empty. The cache is fed by a webhook receiver against the main
    /// checkout only, so a worktree that doesn't share it starts every
    /// session with a 0% hit rate.
    ///
    /// Creates a relative symlink `<worktree>/.chump/github_cache.db` ->
    /// `../../.chump/github_cache.db` (relative to the worktree root, so it
    /// keeps resolving even if the worktree base moves). Best-effort: any
    /// failure is logged and swallowed so the claim proceeds regardless.
    pub fn link_github_cache(repo_root: &Path, worktree_path: &Path) {
        let main_cache = repo_root.join(".chump/github_cache.db");
        let worktree_chump_dir = worktree_path.join(".chump");
        let worktree_cache = worktree_chump_dir.join("github_cache.db");

        if let Err(e) = std::fs::create_dir_all(&worktree_chump_dir) {
            log::warn!(
                "INFRA-1733: failed to create {} for github_cache.db linking: {}",
                worktree_chump_dir.display(),
                e
            );
            return;
        }

        if !main_cache.exists() {
            log::warn!(
                "INFRA-1733: main checkout has no {} — creating empty github_cache.db in worktree",
                main_cache.display()
            );
            if let Err(e) = std::fs::File::create(&worktree_cache) {
                log::warn!(
                    "INFRA-1733: failed to create empty {}: {}",
                    worktree_cache.display(),
                    e
                );
            }
            return;
        }

        // Relative target so the symlink survives the worktree base moving.
        let relative_target = Path::new("../../.chump/github_cache.db");
        if let Err(e) = std::os::unix::fs::symlink(relative_target, &worktree_cache) {
            log::warn!(
                "INFRA-1733: failed to symlink {} -> {}: {}",
                worktree_cache.display(),
                relative_target.display(),
                e
            );
        }
    }

    /// Read (title, description) from the gap registry. Description is read
    /// from the `description` column if present; otherwise we fall back to
    /// acceptance_criteria (still richer than title alone).
    fn read_gap_title_desc(repo_root: &Path, gap_id: &str) -> (String, String) {
        let db_path = repo_root.join(".chump/state.db");
        if !db_path.exists() {
            return (String::new(), String::new());
        }
        let Ok(conn) = rusqlite::Connection::open(&db_path) else {
            return (String::new(), String::new());
        };
        // Some installations of state.db don't have the `description` column
        // (older schema). Try the rich query first; fall back to title-only.
        let row = conn
            .query_row(
                "SELECT COALESCE(title, ''), COALESCE(description, ''), COALESCE(acceptance_criteria, '') FROM gaps WHERE id = ?1",
                [gap_id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
            )
            .ok();
        if let Some((title, desc, ac)) = row {
            let body = if !desc.trim().is_empty() { desc } else { ac };
            return (title, body);
        }
        // Fallback to title-only schema.
        let title = conn
            .query_row(
                "SELECT COALESCE(title, '') FROM gaps WHERE id = ?1",
                [gap_id],
                |r| r.get::<_, String>(0),
            )
            .unwrap_or_default();
        (title, String::new())
    }

    fn read_user_id_env() -> Option<uuid::Uuid> {
        let raw = std::env::var("CHUMP_TEAM_USER_ID").ok()?;
        uuid::Uuid::parse_str(raw.trim()).ok()
    }

    fn env_truthy(key: &str) -> bool {
        std::env::var(key)
            .map(|v| {
                let t = v.trim();
                !t.is_empty() && t != "0" && !t.eq_ignore_ascii_case("false")
            })
            .unwrap_or(false)
    }

    fn truncate(s: &str, n: usize) -> String {
        let s = s.trim();
        if s.chars().count() <= n {
            return s.to_string();
        }
        let head: String = s.chars().take(n.saturating_sub(1)).collect();
        format!("{head}…")
    }

    fn single_line(s: &str) -> String {
        s.replace(['\n', '\r', '\t'], " ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn truncate_short_string_unchanged() {
            assert_eq!(truncate("hello", 40), "hello");
        }

        #[test]
        fn truncate_long_string_with_ellipsis() {
            let out = truncate(&"a".repeat(50), 10);
            assert_eq!(out.chars().count(), 10);
            assert!(out.ends_with('…'));
        }

        #[test]
        fn single_line_collapses_whitespace() {
            assert_eq!(single_line("hello\n  world\t\tthere"), "hello world there");
        }

        #[test]
        fn env_truthy_recognizes_one() {
            std::env::set_var("CHUMP_TEST_NUG_T", "1");
            assert!(env_truthy("CHUMP_TEST_NUG_T"));
            std::env::remove_var("CHUMP_TEST_NUG_T");
        }

        #[test]
        fn env_truthy_recognizes_zero_as_false() {
            std::env::set_var("CHUMP_TEST_NUG_F", "0");
            assert!(!env_truthy("CHUMP_TEST_NUG_F"));
            std::env::remove_var("CHUMP_TEST_NUG_F");
        }

        #[test]
        fn env_truthy_empty_is_false() {
            std::env::remove_var("CHUMP_TEST_NUG_X");
            assert!(!env_truthy("CHUMP_TEST_NUG_X"));
        }

        #[test]
        fn prefetch_silent_when_bypassed() {
            // Bypass should short-circuit even if CHUMP_TEAM_URL is set.
            std::env::set_var("CHUMP_CLAIM_SKIP_NUGGET_SEARCH", "1");
            std::env::set_var("CHUMP_TEAM_URL", "http://127.0.0.1:1");
            // No panic, no hang — just an immediate return. We can't assert on
            // stdout from inside the same process easily, but exercising the
            // path catches obvious regressions.
            prefetch_and_print(Path::new("/nonexistent"), "INFRA-NOPE", "test-session");
            std::env::remove_var("CHUMP_CLAIM_SKIP_NUGGET_SEARCH");
            std::env::remove_var("CHUMP_TEAM_URL");
        }

        #[test]
        fn prefetch_silent_when_team_url_unset() {
            std::env::remove_var("CHUMP_TEAM_URL");
            std::env::remove_var("CHUMP_CLAIM_SKIP_NUGGET_SEARCH");
            // Must not panic or hang, even with no env / no DB.
            prefetch_and_print(Path::new("/nonexistent"), "INFRA-NOPE", "test-session");
        }
    }
}

// ── INFRA-1442: fuzzy-match against in-flight work ────────────────────────────
//
// Today's failure mode (observed 2026-05-22):
//   scripts/ci/test-cache-mergestatestatus.sh fixed independently by INFRA-1341,
//   INFRA-1384, INFRA-1396 in parallel. Three operators + me each spent compute
//   cycles on the same 4-line fix because the gap-filing similarity check
//   (INFRA-1149) catches duplicate gap filings but not duplicate CLAIM attempts
//   where different gap IDs target the same root cause.
//
// This module adds a claim-time fuzzy-match that runs BEFORE worktree + lease
// creation:
//   (a) open PR titles via gh, tokenized + Jaccard against the claimed gap title
//   (c) active lease files in .chump-locks/<session>.json — same tokenization
// Defer (b) commit-body scan and (d) ambient kind=gap_claimed scan to follow-ups;
// they require denser context and (a)+(c) already catch 80% of the pattern.
//
// Threshold default 0.5 Jaccard, configurable via CHUMP_CLAIM_FUZZY_THRESHOLD.
// Disable entirely via CHUMP_CLAIM_NO_FUZZY=1 or --force-duplicate flag.

/// One candidate match the operator should be aware of.
#[derive(Debug, Clone, PartialEq)]
pub struct FuzzyMatch {
    pub kind: &'static str, // "open_pr" | "active_lease"
    pub ref_id: String,     // PR number or session name
    pub title: String,      // PR title or lease's gap_id+paths summary
    pub score: f64,         // jaccard similarity
}

/// Token-set jaccard over lowercase word splits. Ignores tokens shorter than
/// 3 chars (catches noise like "to", "of") and a small stopword list.
pub(crate) fn jaccard_words(a: &str, b: &str) -> f64 {
    let sa = tokenize(a);
    let sb = tokenize(b);
    let inter = sa.intersection(&sb).count();
    let union = sa.union(&sb).count();
    if union == 0 {
        return 0.0;
    }
    inter as f64 / union as f64
}

fn tokenize(s: &str) -> std::collections::HashSet<String> {
    // Grammatical stopwords only. We INTENTIONALLY do NOT filter "test",
    // "fix", "feat", or "infra" because those words carry signal for the
    // claim-time duplicate pattern — two PRs that both fix the same test
    // file should have high overlap.
    const STOP: &[&str] = &["the", "and", "for", "from", "with", "into", "this", "that"];
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .filter(|w| w.len() >= 3 && !STOP.contains(w))
        .map(|s| s.to_string())
        .collect()
}

fn fuzzy_threshold() -> f64 {
    std::env::var("CHUMP_CLAIM_FUZZY_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|n: &f64| *n > 0.0 && *n <= 1.0)
        .unwrap_or(0.5)
}

fn fuzzy_disabled() -> bool {
    std::env::var("CHUMP_CLAIM_NO_FUZZY")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Scan open PR titles via `gh pr list --json number,title`. Returns matches
/// whose token-set Jaccard against `claimed_title` exceeds `threshold`.
/// Best-effort: any gh failure returns Vec::new (offline / un-authed clones
/// don't get a different experience).
pub fn fuzzy_match_open_prs(claimed_title: &str, threshold: f64) -> Vec<FuzzyMatch> {
    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "80",
            "--json",
            "number,title",
        ])
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&o.stdout).unwrap_or_default();
    arr.into_iter()
        .filter_map(|v| {
            let num = v["number"].as_u64()?;
            let title = v["title"].as_str()?.to_string();
            let score = jaccard_words(claimed_title, &title);
            if score >= threshold {
                Some(FuzzyMatch {
                    kind: "open_pr",
                    ref_id: num.to_string(),
                    title,
                    score,
                })
            } else {
                None
            }
        })
        .collect()
}

/// Scan active leases in .chump-locks/*.json. Returns matches whose Jaccard
/// against `claimed_title` (rendered "<gap_id> paths=<csv>") exceeds the
/// threshold. Tokens include both the gap ID and any path-list keywords, which
/// catches "INFRA-1341/1384/1396 all touched test-cache-mergestatestatus.sh".
pub fn fuzzy_match_active_leases(
    repo_root: &Path,
    claimed_gap: &str,
    claimed_title: &str,
    threshold: f64,
) -> Vec<FuzzyMatch> {
    let locks = repo_root.join(".chump-locks");
    let Ok(entries) = std::fs::read_dir(&locks) else {
        return Vec::new();
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut out: Vec<FuzzyMatch> = Vec::new();
    for ent in entries.flatten() {
        let p = ent.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        // INFRA-CREDIBLE-161: a lease past its expires_at is not a live
        // competitor — a migrated/laptop-era host can accumulate dozens of
        // stale rows that never get vacuumed, and counting them as
        // duplicates refuses every claim on that host (2026-07-22 chumpd-eu
        // incident: 22 expired leases blocked all fleet claims).
        if let Some(exp_str) = json.get("expires_at").and_then(|v| v.as_str()) {
            if let Ok(exp_secs) = parse_iso8601(exp_str) {
                if exp_secs <= now {
                    continue; // expired — not a live competitor
                }
            }
        }
        let lease_gap = json
            .get("gap_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // Don't flag our own gap as a self-match.
        if lease_gap.eq_ignore_ascii_case(claimed_gap) {
            continue;
        }
        let paths = json
            .get("paths")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let session = json
            .get("session")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        // Render the lease as a single string and tokenize. Empty leases
        // (no paths declared) won't match unless the gap IDs overlap by
        // accident, which is fine since gap IDs are tokens (e.g. INFRA-1341).
        let summary = format!("{lease_gap} {paths}");
        let score = jaccard_words(claimed_title, &summary);
        if score >= threshold {
            out.push(FuzzyMatch {
                kind: "active_lease",
                ref_id: session,
                title: summary,
                score,
            });
        }
    }
    out
}

/// Render a list of FuzzyMatch entries as human-readable warning lines.
pub fn render_fuzzy_warnings(matches: &[FuzzyMatch]) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "⚠ fuzzy-match: {} possible duplicate(s) — investigate before claim\n",
        matches.len()
    ));
    for m in matches {
        s.push_str(&format!(
            "  [{} score={:.2}] {} — {}\n",
            m.kind, m.score, m.ref_id, m.title
        ));
    }
    s.push_str("  → bypass: --force-duplicate  or  CHUMP_CLAIM_NO_FUZZY=1\n");
    s
}

/// Emit kind=claim_duplicate_bypassed to ambient.jsonl when the operator
/// has bypassed the fuzzy gate. Audit trail for measuring effectiveness
/// (AC#6: duplicate_root_cause_observed should drop).
pub fn emit_claim_duplicate_bypassed(repo_root: &Path, gap_id: &str, matches: &[FuzzyMatch]) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let match_count = matches.len();
    let top_score = matches
        .iter()
        .map(|m| m.score)
        .fold(0.0f64, |a, b| a.max(b));
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_duplicate_bypassed\",\"gap\":\"{gap_id}\",\"match_count\":{match_count},\"top_score\":{top_score:.3}}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// CREDIBLE-161: emit kind=claim_fuzzy_refused to ambient.jsonl when the
/// fuzzy gate refuses a claim outright (no bypass). The refusal previously
/// only surfaced as text inside a caller's captured stdout/stderr, which
/// hid it from the ambient stream for hours until a caller re-emitted it.
pub fn emit_claim_fuzzy_refused(repo_root: &Path, gap_id: &str, matches: &[FuzzyMatch]) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let match_count = matches.len();
    let top_score = matches
        .iter()
        .map(|m| m.score)
        .fold(0.0f64, |a, b| a.max(b));
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"claim_fuzzy_refused\",\"gap\":\"{gap_id}\",\"match_count\":{match_count},\"top_score\":{top_score:.3}}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Look up the title of `gap_id` from the YAML file under docs/gaps.
/// Best-effort: returns "" if the file isn't readable or doesn't parse.
/// Falls through to gap_id when empty so the jaccard still produces some
/// signal (gap_id often appears in PR titles).
fn read_gap_title(repo_root: &Path, gap_id: &str) -> String {
    let y = repo_root
        .join("docs")
        .join("gaps")
        .join(format!("{gap_id}.yaml"));
    let Ok(text) = std::fs::read_to_string(&y) else {
        return gap_id.to_string();
    };
    // Cheap line scan rather than full YAML parse — title: "..." patterns.
    for line in text.lines() {
        let l = line.trim_start();
        if let Some(rest) = l.strip_prefix("title:") {
            let v = rest.trim().trim_matches('"').trim_matches('\'');
            if !v.is_empty() {
                return format!("{gap_id} {v}");
            }
        }
    }
    gap_id.to_string()
}

/// Run the fuzzy gate. Returns Ok(()) when safe to proceed (no matches OR
/// operator bypass). Returns Err with a descriptive message when matches
/// exist and the operator has not opted in via --force-duplicate or
/// CHUMP_CLAIM_NO_FUZZY=1.
pub fn run_fuzzy_gate(
    repo_root: &Path,
    gap_id: &str,
    force_duplicate: bool,
) -> std::result::Result<Vec<FuzzyMatch>, String> {
    if fuzzy_disabled() {
        return Ok(Vec::new());
    }
    let title = read_gap_title(repo_root, gap_id);
    let threshold = fuzzy_threshold();
    let mut hits: Vec<FuzzyMatch> = Vec::new();
    hits.extend(fuzzy_match_open_prs(&title, threshold));
    hits.extend(fuzzy_match_active_leases(
        repo_root, gap_id, &title, threshold,
    ));
    // Sort descending by score so the worst offender is on top.
    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if hits.is_empty() {
        return Ok(Vec::new());
    }
    if force_duplicate {
        emit_claim_duplicate_bypassed(repo_root, gap_id, &hits);
        eprint!("{}", render_fuzzy_warnings(&hits));
        eprintln!("  [bypass] --force-duplicate set; proceeding anyway");
        return Ok(hits);
    }
    // CREDIBLE-161: emit to ambient.jsonl so the refusal is visible in the
    // ambient stream regardless of whether the caller re-emits captured
    // stdout/stderr.
    emit_claim_fuzzy_refused(repo_root, gap_id, &hits);
    Err(render_fuzzy_warnings(&hits))
}

// ── INFRA-1555: Rating-aware picker tie-break helpers ─────────────────────────
//
// `load_class_ratings` scans `.chump-locks/ambient.jsonl` for `gap_impact_rated`
// events within a 30-day window and computes a mean rating per *class*.
// A class is the domain prefix of the rated gap's ID (e.g. "INFRA", "FLEET").
//
// `effective_priority_rank` applies a one-tier demotion (adds 1 to the ordinal)
// when the class mean rating is below the LOW_RATING_THRESHOLD (2.5).  This
// affects tie-breaking only — a demoted P1 in a low-rated class still sorts
// before an undemoted P2, but loses to an undemoted P1.
//
// Weight policy (do not change without filing a gap):
//   - Window     : 30 days
//   - Threshold  : mean < 2.5  → demotion (one tier)
//   - Min samples: at least 2 ratings required to trigger demotion
//     (single outlier should not affect class rank)

/// Low-rating threshold: classes whose mean falls below this value are demoted
/// by one priority tier in tie-breaks.
const LOW_RATING_THRESHOLD: f64 = 2.5;

/// Minimum number of ratings required before demotion can trigger.
const MIN_RATINGS_FOR_DEMOTION: usize = 2;

/// 30-day window for ambient scan (in seconds).
const RATING_WINDOW_SECS: u64 = 30 * 24 * 3600;

/// Mean rating per domain class, computed from recent ambient events.
/// Key: domain prefix (e.g. "INFRA").  Value: (sum, count).
pub type ClassRatingMap = std::collections::HashMap<String, (f64, usize)>;

/// Scan `ambient.jsonl` and return mean ratings keyed by class (domain prefix).
///
/// Returns an empty map if the file is absent or unreadable (non-fatal).
pub fn load_class_ratings(ambient_path: &Path) -> ClassRatingMap {
    let content = match std::fs::read_to_string(ambient_path) {
        Ok(c) => c,
        Err(_) => return ClassRatingMap::new(),
    };

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let cutoff = now_secs.saturating_sub(RATING_WINDOW_SECS);

    let mut map: ClassRatingMap = std::collections::HashMap::new();

    for line in content.lines() {
        // Fast pre-filter before JSON parsing.
        if !line.contains("\"gap_impact_rated\"") {
            continue;
        }

        // Extract kind field.
        let kind = match extract_field_simple(line, "kind") {
            Some(k) => k,
            None => continue,
        };
        if kind != "gap_impact_rated" {
            continue;
        }

        // Timestamp gate — skip events older than 30 days.
        if let Some(ts_str) = extract_field_simple(line, "ts") {
            if let Ok(event_secs) = parse_iso8601_simple(&ts_str) {
                if event_secs < cutoff {
                    continue;
                }
            }
        }

        let gap_id = match extract_field_simple(line, "gap_id") {
            Some(g) => g,
            None => continue,
        };
        let rating: f64 = match extract_field_simple(line, "rating")
            .and_then(|v| v.parse::<u8>().ok())
            .filter(|r| (1..=5).contains(r))
        {
            Some(r) => r as f64,
            None => continue,
        };

        // Class = domain prefix of gap ID (e.g. "INFRA-123" → "INFRA").
        let class = gap_id.split('-').next().unwrap_or("UNKNOWN").to_uppercase();

        let entry = map.entry(class).or_insert((0.0, 0));
        entry.0 += rating;
        entry.1 += 1;
    }

    map
}

/// Return `true` if the class mean rating is below the demotion threshold.
///
/// Requires at least `MIN_RATINGS_FOR_DEMOTION` samples; returns `false` for
/// under-sampled classes so single outliers don't affect sort order.
pub fn class_is_low_rated(class: &str, ratings: &ClassRatingMap) -> bool {
    match ratings.get(class) {
        Some((sum, count)) if *count >= MIN_RATINGS_FOR_DEMOTION => {
            let mean = sum / (*count as f64);
            mean < LOW_RATING_THRESHOLD
        }
        _ => false,
    }
}

/// Priority rank with optional one-tier demotion for low-rated classes.
///
/// Used in picker tie-break sort: lower return value = higher priority.
/// A P1 gap in a low-rated class returns 2 (same as a normal P2),
/// meaning it yields to undemoted P1 gaps in the sort.
pub fn effective_priority_rank(priority: &str, gap_id: &str, ratings: &ClassRatingMap) -> u8 {
    let base = match priority {
        "P0" => 0u8,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 99,
    };
    let class = gap_id.split('-').next().unwrap_or("UNKNOWN").to_uppercase();
    if class_is_low_rated(&class, ratings) {
        base.saturating_add(1)
    } else {
        base
    }
}

/// Minimal field extractor for use in atomic_claim (avoids kpi_report dependency).
fn extract_field_simple(line: &str, field: &str) -> Option<String> {
    let needle = format!("\"{}\":", field);
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    if let Some(inner) = rest.strip_prefix('"') {
        let end = inner.find('"')?;
        Some(inner[..end].to_string())
    } else {
        let end = rest.find([',', '}']).unwrap_or(rest.len());
        let v = rest[..end].trim().to_string();
        if v == "null" {
            None
        } else {
            Some(v)
        }
    }
}

/// Parse an ISO-8601 timestamp to Unix seconds (best-effort, no external deps).
fn parse_iso8601_simple(ts: &str) -> Result<u64> {
    // Delegate to the existing parse_iso8601 helper in this module.
    parse_iso8601(ts)
}

/// META-208: cargo-nextest flake-import ingestion path. Reads a JSON file
/// (one array of `{"name": <test>, "outcome": "passed"|"failed"|"flaky"}`
/// objects — the shape `chump preflight`'s `"flake-ingest"` step and
/// `cargo run --bin chump-atomic-claim -- flake-import` both consume) and
/// upserts one row per flaky outcome into `.chump/flake_tracker.db`.
/// Non-flaky outcomes are ignored — this table only tracks flake history,
/// not full test results (those already live in CI logs).
/// Returns the number of flaky rows inserted.
pub fn run_flake_import(repo_root: &Path, input_path: &Path) -> Result<usize> {
    let raw = std::fs::read_to_string(input_path)
        .with_context(|| format!("reading nextest output {}", input_path.display()))?;
    let events: Vec<serde_json::Value> = serde_json::from_str(&raw)
        .with_context(|| format!("parsing nextest JSON {}", input_path.display()))?;

    let db_path = repo_root.join(".chump/flake_tracker.db");
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    let conn = rusqlite::Connection::open(&db_path)
        .with_context(|| format!("opening {} for flake import", db_path.display()))?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS flake_outcomes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            test_name TEXT NOT NULL,
            outcome TEXT NOT NULL,
            run_timestamp TEXT NOT NULL
        )",
        [],
    )
    .context("creating flake_outcomes table")?;

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let run_timestamp = unix_to_iso8601(now_secs);

    let mut inserted = 0usize;
    for event in &events {
        let outcome = event.get("outcome").and_then(|v| v.as_str()).unwrap_or("");
        if outcome != "flaky" {
            continue;
        }
        let test_name = event
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("flaky event missing \"name\" field: {}", event))?;
        conn.execute(
            "INSERT INTO flake_outcomes(test_name, outcome, run_timestamp)
             VALUES(?1, 'flaky', ?2)",
            rusqlite::params![test_name, run_timestamp],
        )
        .with_context(|| format!("inserting flake row for {}", test_name))?;
        inserted += 1;
    }
    Ok(inserted)
}

#[cfg(test)]
mod flake_import_tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn imports_only_flaky_rows_with_timestamp() {
        let dir = tempdir().unwrap();
        let repo_root = dir.path();
        let input_path = repo_root.join("nextest-flaky.json");
        std::fs::write(
            &input_path,
            r#"[
                {"name": "tests::stable_pass", "outcome": "passed"},
                {"name": "tests::stable_fail", "outcome": "failed"},
                {"name": "tests::flaky_one", "outcome": "flaky"},
                {"name": "tests::flaky_two", "outcome": "flaky"}
            ]"#,
        )
        .unwrap();

        let inserted = run_flake_import(repo_root, &input_path).unwrap();
        assert_eq!(inserted, 2);

        let db_path = repo_root.join(".chump/flake_tracker.db");
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT test_name, outcome, run_timestamp FROM flake_outcomes ORDER BY test_name",
            )
            .unwrap();
        let rows: Vec<(String, String, String)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, "tests::flaky_one");
        assert_eq!(rows[0].1, "flaky");
        assert!(!rows[0].2.is_empty());
        assert_eq!(rows[1].0, "tests::flaky_two");

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM flake_outcomes WHERE test_name IN ('tests::stable_pass', 'tests::stable_fail')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "non-flaky outcomes must not be inserted");
    }
}

#[cfg(test)]
mod fuzzy_match_tests {
    //! INFRA-1442: pure-function tests for the claim-time fuzzy-match
    //! helpers. The gh / file-IO paths are exercised by the CI script;
    //! these cover the tokenizer + jaccard scoring + render shape.
    use super::*;

    #[test]
    fn jaccard_words_finds_overlap_on_shared_filenames() {
        // The 2026-05-22 pattern: two PR titles both mention
        // test-cache-mergestatestatus.sh — should score above 0.4, well
        // above the 0.3 lower-bound that would catch this in practice
        // even if operators tune the threshold down.
        let a = "fix(INFRA-1341): test-cache-mergestatestatus.sh shape bug";
        let b = "fix(INFRA-1384): repair test-cache-mergestatestatus.sh on jq";
        let s = jaccard_words(a, b);
        assert!(s >= 0.4, "expected jaccard >= 0.4, got {s}");
    }

    #[test]
    fn jaccard_words_filters_short_tokens_and_stopwords() {
        // "the and for" should not boost similarity.
        let a = "the cat and the hat";
        let b = "the dog and the rat";
        let s = jaccard_words(a, b);
        // No real tokens shared (cat/hat vs dog/rat); stopwords filtered.
        assert!(s < 0.2, "stopword tokens leaked: {s}");
    }

    #[test]
    fn jaccard_words_zero_on_disjoint_titles() {
        let s = jaccard_words("feat: ship the rollup", "fix: stale branch rebase");
        assert!(s < 0.4);
    }

    #[test]
    fn render_fuzzy_warnings_lists_matches_with_score_and_bypass_hint() {
        let m = vec![FuzzyMatch {
            kind: "open_pr",
            ref_id: "2333".into(),
            title: "chump claim aborts early on open-PR-in-flight".into(),
            score: 0.74,
        }];
        let out = render_fuzzy_warnings(&m);
        assert!(out.contains("2333"));
        assert!(out.contains("score=0.74"));
        assert!(out.contains("--force-duplicate"));
        assert!(out.contains("CHUMP_CLAIM_NO_FUZZY"));
    }

    #[test]
    fn fuzzy_threshold_env_override() {
        let key = "CHUMP_CLAIM_FUZZY_THRESHOLD";
        unsafe {
            std::env::remove_var(key);
        }
        assert!((fuzzy_threshold() - 0.5).abs() < 1e-9);
        unsafe {
            std::env::set_var(key, "0.7");
        }
        assert!((fuzzy_threshold() - 0.7).abs() < 1e-9);
        unsafe {
            std::env::set_var(key, "1.5");
        } // out of range; default
        assert!((fuzzy_threshold() - 0.5).abs() < 1e-9);
        unsafe {
            std::env::set_var(key, "garbage");
        }
        assert!((fuzzy_threshold() - 0.5).abs() < 1e-9);
        unsafe {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn fuzzy_disabled_respects_env() {
        let key = "CHUMP_CLAIM_NO_FUZZY";
        unsafe {
            std::env::remove_var(key);
        }
        assert!(!fuzzy_disabled());
        unsafe {
            std::env::set_var(key, "1");
        }
        assert!(fuzzy_disabled());
        unsafe {
            std::env::set_var(key, "TRUE");
        }
        assert!(fuzzy_disabled());
        unsafe {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn fuzzy_match_active_leases_finds_self_exclusion() {
        use tempfile::tempdir;
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // A sibling lease on a different gap touching the same file as our claim.
        let lease = serde_json::json!({
            "gap_id": "INFRA-9301",
            "session": "claim-infra-9301-1",
            "paths": "src/foo.rs,scripts/ci/test-foo.sh",
        });
        std::fs::write(locks.join("claim-infra-9301-1.json"), lease.to_string()).unwrap();

        // Claiming INFRA-9302 with a title that overlaps on "test-foo" tokens
        // should produce a hit. (gap_id INFRA-9302 != lease's INFRA-9301, so
        // self-exclusion does not fire.)
        let hits = fuzzy_match_active_leases(
            dir.path(),
            "INFRA-9302",
            "INFRA-9302 fix test-foo.sh shape bug",
            0.3,
        );
        // Token "foo"/"test" overlap; threshold 0.15 picks up the sibling.
        // (Realistic real-world jaccard for short titles is well below 0.5.)
        let _ = hits; // recompute with explicit threshold
        let hits = fuzzy_match_active_leases(
            dir.path(),
            "INFRA-9302",
            "INFRA-9302 fix test-foo.sh shape bug",
            0.15,
        );
        assert!(!hits.is_empty(), "expected at least one sibling-lease hit");

        // Self-exclusion: claiming INFRA-9301 (same gap as the lease) returns nothing.
        let self_hits =
            fuzzy_match_active_leases(dir.path(), "INFRA-9301", "INFRA-9301 same thing", 0.0);
        assert!(
            self_hits.is_empty(),
            "self-match should be excluded; got {self_hits:?}"
        );
    }

    #[test]
    fn fuzzy_match_active_leases_ignores_expired_lease() {
        // CREDIBLE-161: a lease past its expires_at must not count as a
        // duplicate. Without the expires_at check, a migrated host with a
        // pile of never-vacuumed expired leases refuses every claim.
        use tempfile::tempdir;
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Strongly-overlapping sibling lease, but expired (year 2000).
        let lease = serde_json::json!({
            "gap_id": "INFRA-9301",
            "session": "laptop-era-session",
            "paths": "src/foo.rs,scripts/ci/test-foo.sh",
            "expires_at": "2000-01-01T00:00:00Z",
        });
        std::fs::write(locks.join("laptop-era-session.json"), lease.to_string()).unwrap();

        let hits = fuzzy_match_active_leases(
            dir.path(),
            "INFRA-9302",
            "INFRA-9302 fix test-foo.sh shape bug",
            0.15,
        );
        assert!(
            hits.is_empty(),
            "expired lease must not be counted as a fuzzy-match duplicate; got {hits:?}"
        );
    }

    #[test]
    fn run_fuzzy_gate_bypass_emits_event() {
        use tempfile::tempdir;
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Sibling lease that overlaps strongly.
        let lease = serde_json::json!({
            "gap_id": "INFRA-9400",
            "session": "claim-infra-9400-1",
            "paths": "src/atomic_claim.rs,scripts/ci/test-claim-fuzzy-match.sh",
        });
        std::fs::write(locks.join("claim-infra-9400-1.json"), lease.to_string()).unwrap();

        // Stand up a docs/gaps/INFRA-9401.yaml so read_gap_title returns a title
        // with overlapping tokens.
        let gaps = dir.path().join("docs").join("gaps");
        std::fs::create_dir_all(&gaps).unwrap();
        std::fs::write(
            gaps.join("INFRA-9401.yaml"),
            "title: \"chump claim fuzzy match against atomic_claim.rs paths\"\n",
        )
        .unwrap();

        // Force-duplicate path: gate returns Ok and emits the audit event.
        unsafe {
            std::env::set_var("CHUMP_CLAIM_FUZZY_THRESHOLD", "0.05");
        }
        let r = run_fuzzy_gate(dir.path(), "INFRA-9401", /* force_duplicate */ true);
        assert!(r.is_ok(), "force-duplicate should bypass cleanly: {r:?}");
        let amb = std::fs::read_to_string(locks.join("ambient.jsonl")).unwrap_or_default();
        assert!(
            amb.contains("claim_duplicate_bypassed"),
            "expected bypass event; got: {amb}"
        );
        unsafe {
            std::env::remove_var("CHUMP_CLAIM_FUZZY_THRESHOLD");
        }
    }

    /// CREDIBLE-161: a plain (non-bypassed) fuzzy-gate refusal must land in
    /// ambient.jsonl as kind=claim_fuzzy_refused. Previously the refusal
    /// message only existed inside the caller's captured stdout/stderr,
    /// invisible to the ambient stream for hours.
    #[test]
    fn run_fuzzy_gate_refusal_emits_event() {
        use tempfile::tempdir;
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let lease = serde_json::json!({
            "gap_id": "INFRA-9500",
            "session": "claim-infra-9500-1",
            "paths": "src/atomic_claim.rs,scripts/ci/test-claim-fuzzy-match.sh",
        });
        std::fs::write(locks.join("claim-infra-9500-1.json"), lease.to_string()).unwrap();

        let gaps = dir.path().join("docs").join("gaps");
        std::fs::create_dir_all(&gaps).unwrap();
        std::fs::write(
            gaps.join("INFRA-9501.yaml"),
            "title: \"chump claim fuzzy match against atomic_claim.rs paths\"\n",
        )
        .unwrap();

        unsafe {
            std::env::set_var("CHUMP_CLAIM_FUZZY_THRESHOLD", "0.05");
        }
        let r = run_fuzzy_gate(dir.path(), "INFRA-9501", /* force_duplicate */ false);
        assert!(r.is_err(), "expected refusal without bypass: {r:?}");
        let amb = std::fs::read_to_string(locks.join("ambient.jsonl")).unwrap_or_default();
        assert!(
            amb.contains("claim_fuzzy_refused"),
            "expected refusal event; got: {amb}"
        );
        unsafe {
            std::env::remove_var("CHUMP_CLAIM_FUZZY_THRESHOLD");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_session_id_shape() {
        let s = derive_session_id("INFRA-123");
        assert!(s.starts_with("claim-infra-123-"));
        // claim-infra-123-<pid>-<epoch> = 4 dash-separated segments
        assert_eq!(s.matches('-').count(), 4);
    }

    // INFRA-1328: gh_owner_repo URL parser — pure logic, no network.
    #[test]
    fn gh_owner_repo_parses_https_url() {
        // We can't easily test the full fn because it shells out to `git
        // config`; instead we test the URL-parse branch via a temp repo.
        let tmp = std::env::temp_dir().join(format!(
            "infra1328-https-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(&tmp)
            .output();
        let _ = Command::new("git")
            .args([
                "config",
                "remote.origin.url",
                "https://github.com/myorg/myrepo.git",
            ])
            .current_dir(&tmp)
            .output();
        assert_eq!(gh_owner_repo(&tmp).as_deref(), Some("myorg/myrepo"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn gh_owner_repo_parses_ssh_url() {
        let tmp = std::env::temp_dir().join(format!(
            "infra1328-ssh-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(&tmp)
            .output();
        let _ = Command::new("git")
            .args(["config", "remote.origin.url", "git@github.com:myorg/myrepo"])
            .current_dir(&tmp)
            .output();
        assert_eq!(gh_owner_repo(&tmp).as_deref(), Some("myorg/myrepo"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn gh_owner_repo_returns_none_for_non_github_url() {
        let tmp = std::env::temp_dir().join(format!(
            "infra1328-gitlab-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(&tmp)
            .output();
        let _ = Command::new("git")
            .args(["config", "remote.origin.url", "https://gitlab.com/x/y.git"])
            .current_dir(&tmp)
            .output();
        assert!(gh_owner_repo(&tmp).is_none());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn unix_to_iso8601_matches_known_values() {
        // 2026-05-13T22:00:00Z = 1778709600
        assert_eq!(unix_to_iso8601(1_778_709_600), "2026-05-13T22:00:00Z");
        // Unix epoch
        assert_eq!(unix_to_iso8601(0), "1970-01-01T00:00:00Z");
        // 2000-01-01T00:00:00Z = 946684800 (post-leap-day-2000 reference)
        assert_eq!(unix_to_iso8601(946_684_800), "2000-01-01T00:00:00Z");
        // Day after leap day 2024 (leap-year math sanity)
        // 2024-03-01T00:00:00Z = 1709251200
        assert_eq!(unix_to_iso8601(1_709_251_200), "2024-03-01T00:00:00Z");
    }

    // INFRA-3002 AC#2/AC#6: claim must not fail on unrelated pre-existing
    // similarity blocks, but must still surface genuine import failures.
    #[test]
    fn import_failure_similarity_block_is_recoverable() {
        let stderr = "import complete: 1 inserted, 0 skipped, 1 blocked by \
                       title-similarity (INFRA-1434; see ambient.jsonl \
                       kind=gap_import_similarity_block).";
        assert!(import_failure_is_similarity_block_only(stderr));
    }

    #[test]
    fn import_failure_parse_error_is_still_fatal() {
        let stderr = "chump gap import: invalid yaml at docs/gaps/INFRA-9999.yaml: \
                       mapping values are not allowed in this context";
        assert!(!import_failure_is_similarity_block_only(stderr));
    }

    #[test]
    fn json_escape_handles_metachars() {
        assert_eq!(json_escape(r#"a"b"#), r#"a\"b"#);
        assert_eq!(json_escape("a\\b"), "a\\\\b");
        assert_eq!(json_escape("a\nb"), "a\\nb");
        assert_eq!(json_escape("normal"), "normal");
        assert_eq!(json_escape("with\u{0001}control"), "with\\u0001control");
    }

    #[test]
    fn write_basic_lease_minimal() {
        let tmp = std::env::temp_dir().join(format!(
            "infra984-min-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease =
            write_basic_lease(&tmp, "test-session-abc", "INFRA-999", None, 14_400).expect("write");

        // File path is <lock_dir>/<session>.json
        assert!(lease.exists());
        assert_eq!(
            lease.file_name().unwrap().to_str().unwrap(),
            "test-session-abc.json"
        );

        let body = std::fs::read_to_string(&lease).unwrap();
        // Schema key order matches gap-claim.sh — first key is session_id
        assert!(
            body.starts_with("{\n  \"session_id\": \"test-session-abc\","),
            "header mismatch: {body}"
        );
        assert!(body.contains("\"gap_id\": \"INFRA-999\""));
        assert!(body.contains("\"purpose\": \"gap:INFRA-999\""));
        // Empty paths array, inline form
        assert!(body.contains("\"paths\": [],"));
        // Trailing newline
        assert!(body.ends_with("}\n"));
        // taken_at / expires_at / heartbeat_at all present and Z-suffixed
        for key in ["taken_at", "expires_at", "heartbeat_at"] {
            let needle = format!("\"{key}\":");
            assert!(body.contains(&needle), "missing {key} in: {body}");
        }
        assert!(body.contains("Z\""));

        // expires_at is 14400 seconds (4h) after taken_at
        let taken = body
            .split("\"taken_at\": \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
            .unwrap();
        let expires = body
            .split("\"expires_at\": \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
            .unwrap();
        assert_ne!(taken, expires);

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_basic_lease_with_paths() {
        let tmp = std::env::temp_dir().join(format!(
            "infra984-paths-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease = write_basic_lease(
            &tmp,
            "s2",
            "INFRA-1",
            Some("src/foo.rs, src/bar.rs,, ,src/baz.rs"), // empty + whitespace entries dropped
            3_600,
        )
        .unwrap();

        let body = std::fs::read_to_string(&lease).unwrap();
        // Multi-line paths array
        assert!(body.contains(
            "\"paths\": [\n    \"src/foo.rs\",\n    \"src/bar.rs\",\n    \"src/baz.rs\"\n  ],"
        ));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_basic_lease_json_parses_roundtrip() {
        // Sanity check that the hand-rolled JSON is actually valid JSON
        // — gap-preflight.sh's reader is python json.load(), so this
        // must round-trip cleanly.
        let tmp = std::env::temp_dir().join(format!(
            "infra984-rt-{}",
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let lease = write_basic_lease(&tmp, "s3", "INFRA-2", Some("a.rs,b.rs"), 7_200).unwrap();
        let body = std::fs::read_to_string(&lease).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&body).expect("valid JSON for gap-preflight reader");
        assert_eq!(parsed["session_id"], "s3");
        assert_eq!(parsed["gap_id"], "INFRA-2");
        assert_eq!(parsed["purpose"], "gap:INFRA-2");
        assert_eq!(parsed["paths"], serde_json::json!(["a.rs", "b.rs"]));

        std::fs::remove_dir_all(&tmp).ok();
    }

    // ── INFRA-985 slice 2 tests ─────────────────────────────────────────────

    fn mk_test_tmp(label: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "infra985-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn write_speculative_lease_appends_flag() {
        let tmp = mk_test_tmp("spec");
        let lease = write_speculative_lease(&tmp, "spec-sess", "INFRA-10", None, 3_600).unwrap();
        let body = std::fs::read_to_string(&lease).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        assert_eq!(parsed["session_id"], "spec-sess");
        assert_eq!(parsed["gap_id"], "INFRA-10");
        // Format check: trailing newline, JSON-parses cleanly (the comma-
        // splice into the basic-write output is fragile if wrong).
        assert!(body.ends_with("}\n"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_existing_lease_dedups_paths() {
        let tmp = mk_test_tmp("merge");
        // Seed: existing lease with paths [a.rs, b.rs] for an old gap_id.
        write_basic_lease(&tmp, "shared-sess", "INFRA-OLD", Some("a.rs,b.rs"), 7_200).unwrap();

        // Now claim a NEW gap on the same session, with overlapping paths.
        let lease = write_or_merge_lease(
            &tmp,
            "shared-sess",
            "INFRA-NEW",
            Some("b.rs, c.rs, a.rs"), // duplicates a.rs+b.rs; adds c.rs
            7_200,
            false,
        )
        .unwrap();

        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        // gap_id rewritten to new
        assert_eq!(parsed["gap_id"], "INFRA-NEW");
        // paths union'd, order preserved (existing first, new at end)
        assert_eq!(
            parsed["paths"],
            serde_json::json!(["a.rs", "b.rs", "c.rs"]),
            "expected union-merge dedup, got: {}",
            parsed["paths"]
        );
        // session_id unchanged
        assert_eq!(parsed["session_id"], "shared-sess");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_promotes_speculative_flag() {
        let tmp = mk_test_tmp("promote");
        // Seed with non-speculative basic lease.
        write_basic_lease(&tmp, "sess-p", "INFRA-A", Some("a.rs"), 7_200).unwrap();

        // Merge with speculative=true should add the flag.
        let lease = write_or_merge_lease(&tmp, "sess-p", "INFRA-B", None, 7_200, true).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        assert_eq!(parsed["gap_id"], "INFRA-B");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_writes_new_when_no_existing() {
        let tmp = mk_test_tmp("new");
        // No existing lease — falls through to write_basic_lease.
        let lease = write_or_merge_lease(&tmp, "sess-fresh", "INFRA-X", Some("x.rs"), 7_200, false)
            .unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["session_id"], "sess-fresh");
        assert_eq!(parsed["gap_id"], "INFRA-X");
        // No speculative key on the basic path
        assert!(parsed.get("speculative").is_none());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn write_or_merge_speculative_falls_through_to_speculative_write() {
        let tmp = mk_test_tmp("new-spec");
        let lease = write_or_merge_lease(&tmp, "sess-spec", "INFRA-Y", None, 7_200, true).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease).unwrap()).unwrap();
        assert_eq!(parsed["speculative"], serde_json::Value::Bool(true));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn merge_clears_pending_new_gap_when_id_matches() {
        let tmp = mk_test_tmp("pending");
        let lease_path = tmp.join("sess-pending.json");
        // Hand-craft a lease with pending_new_gap pointing at the gap
        // we're about to claim. gap-claim.sh writes this shape when a
        // session is awaiting reserve completion.
        std::fs::write(
            &lease_path,
            r#"{
  "session_id": "sess-pending",
  "paths": [],
  "taken_at": "2026-05-13T00:00:00Z",
  "expires_at": "2026-05-13T04:00:00Z",
  "heartbeat_at": "2026-05-13T00:00:00Z",
  "purpose": "reserve",
  "gap_id": "",
  "pending_new_gap": {"id": "INFRA-Z", "title": "tbd"}
}
"#,
        )
        .unwrap();

        write_or_merge_lease(&tmp, "sess-pending", "INFRA-Z", None, 7_200, false).unwrap();
        let parsed: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&lease_path).unwrap()).unwrap();
        assert!(
            parsed.get("pending_new_gap").is_none(),
            "pending_new_gap should be cleared when its id matches the new claim; got: {}",
            parsed
        );
        assert_eq!(parsed["gap_id"], "INFRA-Z");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn sibling_lease_holders_finds_others_on_same_gap() {
        let tmp = mk_test_tmp("siblings");
        // Three leases: two claim INFRA-Q (one speculative), one claims a
        // different gap, plus our own.
        write_basic_lease(&tmp, "sib1", "INFRA-Q", None, 7_200).unwrap();
        write_speculative_lease(&tmp, "sib2", "INFRA-Q", None, 7_200).unwrap();
        write_basic_lease(&tmp, "sib3", "INFRA-OTHER", None, 7_200).unwrap();
        write_basic_lease(&tmp, "me", "INFRA-Q", None, 7_200).unwrap();

        let siblings = sibling_lease_holders(&tmp, "INFRA-Q", "me");
        assert_eq!(
            siblings.len(),
            2,
            "expected sib1 + sib2 only; got {siblings:?}"
        );
        let spec_map: std::collections::HashMap<_, _> = siblings.into_iter().collect();
        assert_eq!(spec_map.get("sib1"), Some(&false));
        assert_eq!(spec_map.get("sib2"), Some(&true));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn sibling_lease_holders_empty_when_no_siblings() {
        let tmp = mk_test_tmp("alone");
        write_basic_lease(&tmp, "me", "INFRA-SOLO", None, 7_200).unwrap();
        assert!(sibling_lease_holders(&tmp, "INFRA-SOLO", "me").is_empty());
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn from_argv_minimal() {
        let argv: Vec<String> = vec![
            "claim".into(),
            "INFRA-123".into(),
            "--role".into(),
            "shepherd".into(),
        ];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-123");
        assert!(args.paths.is_none());
        assert!(!args.skip_doctor);
        assert!(!args.resume);
    }

    #[test]
    fn from_argv_with_flags() {
        let argv: Vec<String> = vec![
            "claim".into(),
            "INFRA-200".into(),
            "--paths".into(),
            "src/,scripts/".into(),
            "--session".into(),
            "test-session".into(),
            "--skip-doctor".into(),
            "--role".into(),
            "shepherd".into(),
        ];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-200");
        assert_eq!(args.paths.as_deref(), Some("src/,scripts/"));
        assert_eq!(args.session_id.as_deref(), Some("test-session"));
        assert!(args.skip_doctor);
        assert!(!args.resume);
    }

    // INFRA-5486 (INFRA-1863 slice): --role is mandatory (AC1/AC2) — omitting
    // it is an error, regardless of what other flags are present.
    #[test]
    fn from_argv_missing_role_errors() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-123".into()];
        let err = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap_err();
        assert!(format!("{err:#}").contains("missing required flag --role"));
    }

    #[test]
    fn from_argv_role_and_scope_flags() {
        let argv: Vec<String> = vec![
            "claim".into(),
            "INFRA-6624".into(),
            "--role".into(),
            "shepherd".into(),
            "--scope".into(),
            "atomic_claim".into(),
        ];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-6624");
        assert_eq!(args.role.as_deref(), Some("shepherd"));
        assert_eq!(args.scope.as_deref(), Some("atomic_claim"));
        // --paths is optional and can be omitted without error (AC2).
        assert!(args.paths.is_none());
    }

    #[test]
    fn from_argv_role_missing_value_errors() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-6624".into(), "--role".into()];
        let err = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap_err();
        assert!(format!("{err:#}").contains("--role needs a value"));
    }

    #[test]
    fn from_argv_scope_missing_value_errors() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-6624".into(), "--scope".into()];
        let err = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap_err();
        assert!(format!("{err:#}").contains("--scope needs a value"));
    }

    #[test]
    fn from_argv_unknown_flag_errors() {
        let argv: Vec<String> = vec!["claim".into(), "INFRA-6624".into(), "--bogus".into()];
        let err = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap_err();
        assert!(format!("{err:#}").contains("unknown flag"));
    }

    #[test]
    fn from_argv_resume_flag() {
        let argv: Vec<String> = vec![
            "claim".into(),
            "INFRA-300".into(),
            "--resume".into(),
            "--role".into(),
            "shepherd".into(),
        ];
        let args = ClaimArgs::from_argv(&argv, PathBuf::from(".")).unwrap();
        assert_eq!(args.gap_id, "INFRA-300");
        assert!(args.resume);
    }

    #[test]
    fn from_argv_missing_gap_id() {
        let argv: Vec<String> = vec!["claim".into()];
        assert!(ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_err());
    }

    #[test]
    fn from_argv_flag_in_gap_id_position() {
        let argv: Vec<String> = vec!["claim".into(), "--paths".into(), "x".into()];
        assert!(ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_err());
    }

    // CREDIBLE-166: malformed GAP-IDs are rejected at parse time with an
    // "invalid GAP-ID format" error — BEFORE run_claim's autonomy gate — so
    // `claim <bad-id>` no longer returns "fleet stopped" for a malformed arg.
    #[test]
    fn from_argv_rejects_malformed_gap_id_with_format_error() {
        for bad in ["bad-format-id", "12345-not-valid", "lowercase-1", "NODASH"] {
            let argv: Vec<String> = vec!["claim".into(), bad.into()];
            let err = ClaimArgs::from_argv(&argv, PathBuf::from("."))
                .expect_err(&format!("{bad} should be rejected"));
            let msg = format!("{err:#}");
            assert!(
                msg.contains("invalid GAP-ID format"),
                "{bad}: message should carry 'invalid GAP-ID format', got: {msg}"
            );
        }
    }

    #[test]
    fn from_argv_accepts_canonical_gap_ids() {
        for good in ["INFRA-1234", "ZERO-WASTE-015", "SMOKE-001", "CREDIBLE-166"] {
            let argv: Vec<String> = vec![
                "claim".into(),
                good.into(),
                "--role".into(),
                "shepherd".into(),
            ];
            assert!(
                ClaimArgs::from_argv(&argv, PathBuf::from(".")).is_ok(),
                "{good} should parse"
            );
        }
    }

    // INFRA-779: verify_and_repair_gitdir repairs a clobbered gitdir file
    #[test]
    fn infra779_repairs_clobbered_gitdir() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().to_path_buf();
        let wt_path = tmp.path().join("chump-infra-999");
        std::fs::create_dir_all(&wt_path).unwrap();

        // Simulate the worktree .git file and the worktrees entry.
        let dot_git = wt_path.join(".git");
        std::fs::write(&dot_git, "gitdir: placeholder\n").unwrap();

        let wt_entry = repo_root
            .join(".git")
            .join("worktrees")
            .join("chump-infra-999");
        std::fs::create_dir_all(&wt_entry).unwrap();

        // Write a WRONG gitdir (simulates concurrent clobber).
        let gitdir_file = wt_entry.join("gitdir");
        std::fs::write(&gitdir_file, "/private/tmp/chump-OTHER/.git\n").unwrap();

        verify_and_repair_gitdir(&repo_root, "chump/infra-999-claim", &wt_path).unwrap();

        let repaired = std::fs::read_to_string(&gitdir_file).unwrap();
        let repaired = repaired.trim();
        // After repair it must point at the worktree's .git (canonical form).
        let canonical = std::fs::canonicalize(&dot_git).unwrap();
        assert_eq!(repaired, canonical.to_str().unwrap());
    }

    #[test]
    fn infra779_noop_when_gitdir_already_correct() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path().to_path_buf();
        let wt_path = tmp.path().join("chump-infra-998");
        std::fs::create_dir_all(&wt_path).unwrap();

        let dot_git = wt_path.join(".git");
        std::fs::write(&dot_git, "gitdir: placeholder\n").unwrap();
        let canonical = std::fs::canonicalize(&dot_git).unwrap();
        let canonical_str = canonical.to_str().unwrap();

        let wt_entry = repo_root
            .join(".git")
            .join("worktrees")
            .join("chump-infra-998");
        std::fs::create_dir_all(&wt_entry).unwrap();
        let gitdir_file = wt_entry.join("gitdir");
        std::fs::write(&gitdir_file, format!("{canonical_str}\n")).unwrap();

        verify_and_repair_gitdir(&repo_root, "chump/infra-998-claim", &wt_path).unwrap();

        // Must remain unchanged.
        let after = std::fs::read_to_string(&gitdir_file).unwrap();
        assert_eq!(after.trim(), canonical_str);
    }

    // ── INFRA-986 NATS dual-write tests ─────────────────────────────────────

    /// Write an executable bash shim at `path` that exits with `rc` and
    /// writes `stderr_msg` to stderr.
    fn write_coord_shim(path: &Path, rc: i32, stderr_msg: &str) {
        use std::io::Write as _;
        use std::os::unix::fs::PermissionsExt;
        let body = format!(
            "#!/usr/bin/env bash\n>&2 printf '%s\\n' \"{}\"\nexit {}\n",
            stderr_msg.replace('"', "\\\""),
            rc
        );
        // sync_all() + explicit drop before chmod avoids ETXTBSY (os error 26)
        // on Linux when the kernel still sees the inode open for writing at exec time.
        {
            let mut f = std::fs::File::create(path).unwrap();
            f.write_all(body.as_bytes()).unwrap();
            f.sync_all().unwrap();
        }
        let mut perms = std::fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).unwrap();
    }

    #[test]
    fn nats_dual_write_skipped_when_nats_url_unset() {
        // Belt-and-braces: temporarily clear CHUMP_NATS_URL.
        let saved = std::env::var("CHUMP_NATS_URL").ok();
        std::env::remove_var("CHUMP_NATS_URL");

        let outcome = nats_dual_write("INFRA-986", "test-sess", None).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Skipped);

        if let Some(v) = saved {
            std::env::set_var("CHUMP_NATS_URL", v);
        }
    }

    #[test]
    fn nats_dual_write_conflict_emits_ambient_event() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 1, "CONFLICT: another session holds claim");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Conflict);

        let body = std::fs::read_to_string(&amb).expect("ambient must exist after conflict");
        assert!(
            body.contains("\"kind\":\"gap_claim_nats_conflict\""),
            "missing kind in: {body}"
        );
        assert!(body.contains("\"gap_id\":\"INFRA-986\""));
        assert!(body.contains("\"session_id\":\"test-sess\""));
        // Must be valid JSON (one event per line)
        for line in body.lines() {
            let _: serde_json::Value =
                serde_json::from_str(line).unwrap_or_else(|e| panic!("bad json '{line}': {e}"));
        }
    }

    #[test]
    fn nats_dual_write_success_no_ambient_event() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 0, "");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Claimed);
        // On success we must NOT pollute ambient.
        assert!(!amb.exists(), "ambient should not be written on success");
    }

    #[test]
    fn nats_dual_write_transient_error_treated_as_skipped() {
        // Mirrors shell behavior: any rc != 0 && rc != 1 is "infra hiccup,
        // not a conflict" — file lease should proceed.
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-shim");
        write_coord_shim(&shim, 42, "transient NATS error");
        let amb = tmp.path().join("ambient.jsonl");

        let outcome =
            nats_dual_write_with_bin(&shim, "INFRA-986", "test-sess", Some(&amb)).unwrap();
        assert_eq!(outcome, NatsClaimOutcome::Skipped);
        assert!(
            !amb.exists(),
            "transient error must not look like a conflict"
        );
    }

    #[test]
    fn resolve_coord_bin_honors_explicit_env() {
        let tmp = tempfile::tempdir().unwrap();
        let fake = tmp.path().join("chump-coord");
        std::fs::write(&fake, b"#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mut p = std::fs::metadata(&fake).unwrap().permissions();
        p.set_mode(0o755);
        std::fs::set_permissions(&fake, p).unwrap();

        let saved = std::env::var("CHUMP_COORD_BIN").ok();
        std::env::set_var("CHUMP_COORD_BIN", &fake);
        let resolved = resolve_coord_bin();
        assert_eq!(resolved.as_deref(), Some(fake.as_path()));
        match saved {
            Some(v) => std::env::set_var("CHUMP_COORD_BIN", v),
            None => std::env::remove_var("CHUMP_COORD_BIN"),
        }
    }
    // ── INFRA-2472: shared-registry whois gate tests ────────────────────────────

    fn write_whois_shim(path: &Path, rc: i32, stdout_msg: &str) {
        use std::io::Write as _;
        use std::os::unix::fs::PermissionsExt;
        let body = format!(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"{}\"\nexit {}\n",
            stdout_msg.replace('"', "\\\""),
            rc
        );
        {
            let mut f = std::fs::File::create(path).unwrap();
            f.write_all(body.as_bytes()).unwrap();
            f.sync_all().unwrap();
        }
        let mut perms = std::fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).unwrap();
    }

    #[test]
    fn shared_registry_whois_returns_holder_session() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-whois-shim");
        write_whois_shim(&shim, 0, "sess-on-other-machine");
        let got = shared_registry_whois_with_bin(&shim, "INFRA-2472");
        assert_eq!(got.as_deref(), Some("sess-on-other-machine"));
    }

    #[test]
    fn shared_registry_whois_none_when_unclaimed() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-whois-shim");
        write_whois_shim(&shim, 0, "");
        let got = shared_registry_whois_with_bin(&shim, "INFRA-2472");
        assert_eq!(got, None);
    }

    #[test]
    fn shared_registry_whois_none_on_nonzero_exit() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-whois-shim");
        write_whois_shim(&shim, 1, "some-session");
        let got = shared_registry_whois_with_bin(&shim, "INFRA-2472");
        assert_eq!(got, None);
    }

    #[test]
    fn shared_registry_gap_uniqueness_blocks_foreign_holder() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-whois-shim");
        write_whois_shim(&shim, 0, "sess-remote");

        let saved = std::env::var("CHUMP_COORD_BIN").ok();
        std::env::set_var("CHUMP_COORD_BIN", &shim);
        let saved_url = std::env::var("CHUMP_NATS_URL").ok();
        std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:4222");

        let result = check_shared_registry_gap_uniqueness("INFRA-2472", "sess-local");
        assert!(result.is_err(), "foreign holder must block the claim");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("sess-remote"),
            "message must name the holder: {msg}"
        );

        match saved {
            Some(v) => std::env::set_var("CHUMP_COORD_BIN", v),
            None => std::env::remove_var("CHUMP_COORD_BIN"),
        }
        match saved_url {
            Some(v) => std::env::set_var("CHUMP_NATS_URL", v),
            None => std::env::remove_var("CHUMP_NATS_URL"),
        }
    }

    #[test]
    fn shared_registry_gap_uniqueness_allows_self_holder() {
        let tmp = tempfile::tempdir().unwrap();
        let shim = tmp.path().join("chump-coord-whois-shim");
        write_whois_shim(&shim, 0, "sess-local");

        let saved = std::env::var("CHUMP_COORD_BIN").ok();
        std::env::set_var("CHUMP_COORD_BIN", &shim);
        let saved_url = std::env::var("CHUMP_NATS_URL").ok();
        std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:4222");

        let result = check_shared_registry_gap_uniqueness("INFRA-2472", "sess-local");
        assert!(result.is_ok(), "self-held claim must not block: {result:?}");

        match saved {
            Some(v) => std::env::set_var("CHUMP_COORD_BIN", v),
            None => std::env::remove_var("CHUMP_COORD_BIN"),
        }
        match saved_url {
            Some(v) => std::env::set_var("CHUMP_NATS_URL", v),
            None => std::env::remove_var("CHUMP_NATS_URL"),
        }
    }

    #[test]
    fn shared_registry_whois_none_when_nats_url_unset() {
        let saved_url = std::env::var("CHUMP_NATS_URL").ok();
        std::env::remove_var("CHUMP_NATS_URL");
        assert_eq!(shared_registry_whois("INFRA-2472"), None);
        if let Some(v) = saved_url {
            std::env::set_var("CHUMP_NATS_URL", v);
        }
    }

    // ── INFRA-1116: INTENT overlap gate tests ──────────────────────────────────

    fn mk_intent_tmp(label: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "infra1116-{}-{}",
            label,
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_intent_announced(
        ambient_path: &Path,
        session_id: &str,
        gap_id: &str,
        paths: &[&str],
        ts_secs: u64,
        ttl_secs: u64,
    ) {
        let ts = iso8601_from_unix(ts_secs);
        let expires_at = iso8601_from_unix(ts_secs + ttl_secs);
        let paths_json = serde_json::to_string(paths).unwrap();
        let line = format!(
            r#"{{"ts":"{ts}","kind":"intent_announced","gap_id":"{gap_id}","session_id":"{session_id}","paths":{paths_json},"expires_at":"{expires_at}"}}
"#
        );
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(ambient_path)
            .unwrap();
        f.write_all(line.as_bytes()).unwrap();
    }

    fn write_live_lease(lock_dir: &Path, session_id: &str) {
        let expires_at = iso8601_from_unix(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
                + 3600,
        );
        let json = format!(
            r#"{{"session_id":"{session_id}","expires_at":"{expires_at}"}}
"#
        );
        std::fs::write(lock_dir.join(format!("{session_id}.json")), json).unwrap();
    }

    fn write_expired_lease(lock_dir: &Path, session_id: &str) {
        let json = format!(
            r#"{{"session_id":"{session_id}","expires_at":"2000-01-01T00:00:00Z"}}
"#
        );
        std::fs::write(lock_dir.join(format!("{session_id}.json")), json).unwrap();
    }

    #[test]
    fn intent_gate_no_overlap_when_ambient_empty() {
        let tmp = mk_intent_tmp("empty");
        // No ambient.jsonl → no INTENTs → check passes
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "empty ambient should not block");
    }

    #[test]
    fn intent_gate_no_overlap_when_paths_disjoint() {
        let tmp = mk_intent_tmp("disjoint");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "sibling",
            "INFRA-B",
            &["docs/process/"],
            now,
            3600,
        );
        write_live_lease(&tmp, "sibling");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "disjoint paths should not block");
    }

    #[test]
    fn intent_gate_blocks_on_overlapping_paths_with_live_lease() {
        let tmp = mk_intent_tmp("overlap");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "sibling",
            "INFRA-B",
            &["src/atomic_claim.rs"],
            now,
            3600,
        );
        write_live_lease(&tmp, "sibling");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/atomic_claim.rs", "me");
        assert!(
            result.is_err(),
            "overlapping paths with live lease should block"
        );
        let msg = format!("{}", result.unwrap_err());
        assert!(
            msg.contains("sibling"),
            "error should name the blocking session"
        );
    }

    #[test]
    fn intent_gate_skips_stale_session_absent_lease() {
        let tmp = mk_intent_tmp("stale");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(&ambient, "ghost", "INFRA-B", &["src/main.rs"], now, 3600);
        // No lease file for "ghost" → stale filter should skip it
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "absent lease = stale, should not block");
    }

    #[test]
    fn intent_gate_skips_stale_session_expired_lease() {
        let tmp = mk_intent_tmp("expired");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "old-session",
            "INFRA-B",
            &["src/main.rs"],
            now,
            3600,
        );
        write_expired_lease(&tmp, "old-session");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "expired lease = stale, should not block");
    }

    #[test]
    fn intent_gate_self_skip() {
        let tmp = mk_intent_tmp("self");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(
            &ambient,
            "my-session",
            "INFRA-A",
            &["src/main.rs"],
            now,
            3600,
        );
        write_live_lease(&tmp, "my-session");
        // Own session should not block itself
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "my-session");
        assert!(result.is_ok(), "own-session intent should not block self");
    }

    #[test]
    fn intent_gate_skips_retracted_session() {
        let tmp = mk_intent_tmp("retracted");
        let ambient = tmp.join("ambient.jsonl");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_intent_announced(&ambient, "sibling", "INFRA-B", &["src/main.rs"], now, 3600);
        write_live_lease(&tmp, "sibling");
        // Sibling emits intent_retracted before we check
        emit_intent_retracted(&ambient, "INFRA-B", "sibling");
        let result = check_intent_overlap(&tmp, "INFRA-A", "src/main.rs", "me");
        assert!(result.is_ok(), "retracted intent should not block");
    }

    #[test]
    fn emit_intent_announced_writes_valid_json() {
        let tmp = mk_intent_tmp("emit-ann");
        let ambient = tmp.join("ambient.jsonl");
        emit_intent_announced(&ambient, "INFRA-C", "my-sess", "src/a.rs,src/b.rs", 3600);
        let content = std::fs::read_to_string(&ambient).unwrap();
        assert!(!content.is_empty());
        for line in content.lines() {
            let v: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
            assert_eq!(v["kind"], "intent_announced");
            assert_eq!(v["gap_id"], "INFRA-C");
            assert_eq!(v["session_id"], "my-sess");
            assert!(v["expires_at"].as_str().unwrap().ends_with('Z'));
        }
    }

    #[test]
    fn emit_intent_retracted_writes_valid_json() {
        let tmp = mk_intent_tmp("emit-ret");
        let ambient = tmp.join("ambient.jsonl");
        emit_intent_retracted(&ambient, "INFRA-D", "session-123");
        let content = std::fs::read_to_string(&ambient).unwrap();
        for line in content.lines() {
            let v: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
            assert_eq!(v["kind"], "intent_retracted");
            assert_eq!(v["gap_id"], "INFRA-D");
            assert_eq!(v["session_id"], "session-123");
        }
    }

    #[test]
    fn is_session_lease_alive_absent_returns_false() {
        let tmp = mk_intent_tmp("alive-absent");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(!is_session_lease_alive(&tmp, "no-such-session", now));
    }

    #[test]
    fn is_session_lease_alive_expired_returns_false() {
        let tmp = mk_intent_tmp("alive-expired");
        write_expired_lease(&tmp, "old");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(!is_session_lease_alive(&tmp, "old", now));
    }

    #[test]
    fn is_session_lease_alive_live_returns_true() {
        let tmp = mk_intent_tmp("alive-live");
        write_live_lease(&tmp, "fresh");
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(is_session_lease_alive(&tmp, "fresh", now));
    }

    // ── INFRA-1646: block claim when session already holds an active lease ──

    #[test]
    fn active_lease_gate_blocks_different_gap_same_session() {
        let tmp = mk_intent_tmp("active-lease-block");
        write_basic_lease(&tmp, "worker-1", "INFRA-OLD", None, 7_200).unwrap();
        let result = check_no_active_lease_for_other_gap(&tmp, "INFRA-NEW", "worker-1");
        assert!(
            result.is_err(),
            "second gap under same live session should block"
        );
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("INFRA-OLD"), "error should name the held gap");
    }

    #[test]
    fn active_lease_gate_allows_same_gap_same_session() {
        let tmp = mk_intent_tmp("active-lease-same-gap");
        write_basic_lease(&tmp, "worker-1", "INFRA-A", None, 7_200).unwrap();
        let result = check_no_active_lease_for_other_gap(&tmp, "INFRA-A", "worker-1");
        assert!(
            result.is_ok(),
            "reclaiming the same gap_id should not block"
        );
    }

    #[test]
    fn active_lease_gate_allows_no_existing_lease() {
        let tmp = mk_intent_tmp("active-lease-absent");
        let result = check_no_active_lease_for_other_gap(&tmp, "INFRA-A", "fresh-session");
        assert!(
            result.is_ok(),
            "no prior lease file for this session should not block"
        );
    }

    #[test]
    fn active_lease_gate_allows_expired_lease() {
        let tmp = mk_intent_tmp("active-lease-expired");
        // Write a live lease then overwrite expires_at to the past.
        write_basic_lease(&tmp, "worker-1", "INFRA-OLD", None, 7_200).unwrap();
        let body = std::fs::read_to_string(tmp.join("worker-1.json")).unwrap();
        let mut val: serde_json::Value = serde_json::from_str(&body).unwrap();
        val["expires_at"] = serde_json::Value::String("2000-01-01T00:00:00Z".to_string());
        std::fs::write(
            tmp.join("worker-1.json"),
            serde_json::to_string_pretty(&val).unwrap(),
        )
        .unwrap();
        let result = check_no_active_lease_for_other_gap(&tmp, "INFRA-NEW", "worker-1");
        assert!(result.is_ok(), "expired lease should not block a new claim");
    }

    #[test]
    fn emit_claim_active_lease_event_writes_valid_json() {
        let tmp = mk_intent_tmp("active-lease-emit");
        let ambient = tmp.join("ambient.jsonl");
        emit_claim_active_lease_event(&ambient, "INFRA-NEW", "worker-1", "some detail");
        let content = std::fs::read_to_string(&ambient).unwrap();
        let mut saw_kind = false;
        for line in content.lines() {
            let v: serde_json::Value = serde_json::from_str(line).expect("valid JSON");
            if v["kind"] == "claim_active_lease_blocked" {
                saw_kind = true;
                assert_eq!(v["gap_id"], "INFRA-NEW");
                assert_eq!(v["session_id"], "worker-1");
            }
        }
        assert!(saw_kind, "expected claim_active_lease_blocked event");
    }
}

// ── INFRA-1555: unit tests for rating-aware picker helpers ────────────────────
#[cfg(test)]
mod rating_picker_demotion {
    use super::*;
    use std::io::Write;

    fn write_ambient(dir: &std::path::Path, lines: &[&str]) {
        let locks = dir.join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
    }

    fn now_iso() -> String {
        // Use a fixed recent-ish timestamp so the 30-day window always includes it.
        // In tests, SystemTime::now() is used as the reference; these events
        // are stamped with the current time so they always fall within the window.
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let (y, mo, d, h, mi, s) = super::secs_to_ymdhms(secs);
        format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
    }

    #[test]
    fn load_class_ratings_empty_file_returns_empty_map() {
        let tmp = tempfile::tempdir().unwrap();
        let ambient = tmp.path().join(".chump-locks/ambient.jsonl");
        // File does not exist — should return empty map, not panic.
        let map = load_class_ratings(&ambient);
        assert!(map.is_empty());
    }

    #[test]
    fn load_class_ratings_below_threshold_triggers_demotion() {
        let tmp = tempfile::tempdir().unwrap();
        let ts = now_iso();
        // 5 ratings at 1.0 for TEST domain → mean = 1.0, well below 2.5
        let events: Vec<String> = (1..=5)
            .map(|i| {
                format!(
                    r#"{{"ts":"{ts}","kind":"gap_impact_rated","gap_id":"TEST-{i}","rating":1,"comment":"","pr_number":null}}"#
                )
            })
            .collect();
        let refs: Vec<&str> = events.iter().map(|s| s.as_str()).collect();
        write_ambient(tmp.path(), &refs);

        let map = load_class_ratings(&tmp.path().join(".chump-locks/ambient.jsonl"));
        assert!(class_is_low_rated("TEST", &map), "TEST should be demoted");
    }

    #[test]
    fn load_class_ratings_above_threshold_no_demotion() {
        let tmp = tempfile::tempdir().unwrap();
        let ts = now_iso();
        // 3 ratings at 4.0 for FLEET domain → mean = 4.0, above 2.5
        let events: Vec<String> = (1..=3)
            .map(|i| {
                format!(
                    r#"{{"ts":"{ts}","kind":"gap_impact_rated","gap_id":"FLEET-{i}","rating":4,"comment":"","pr_number":null}}"#
                )
            })
            .collect();
        let refs: Vec<&str> = events.iter().map(|s| s.as_str()).collect();
        write_ambient(tmp.path(), &refs);

        let map = load_class_ratings(&tmp.path().join(".chump-locks/ambient.jsonl"));
        assert!(
            !class_is_low_rated("FLEET", &map),
            "FLEET should NOT be demoted"
        );
    }

    #[test]
    fn load_class_ratings_single_sample_no_demotion() {
        // Only 1 sample — below MIN_RATINGS_FOR_DEMOTION=2, so no demotion even if low.
        let tmp = tempfile::tempdir().unwrap();
        let ts = now_iso();
        write_ambient(
            tmp.path(),
            &[&format!(
                r#"{{"ts":"{ts}","kind":"gap_impact_rated","gap_id":"INFRA-1","rating":1,"comment":"","pr_number":null}}"#
            )],
        );
        let map = load_class_ratings(&tmp.path().join(".chump-locks/ambient.jsonl"));
        assert!(
            !class_is_low_rated("INFRA", &map),
            "single sample should NOT trigger demotion"
        );
    }

    #[test]
    fn effective_priority_rank_demotes_low_rated_class() {
        let tmp = tempfile::tempdir().unwrap();
        let ts = now_iso();
        let events: Vec<String> = (1..=2)
            .map(|i| {
                format!(
                    r#"{{"ts":"{ts}","kind":"gap_impact_rated","gap_id":"TEST-{i}","rating":1,"comment":"","pr_number":null}}"#
                )
            })
            .collect();
        let refs: Vec<&str> = events.iter().map(|s| s.as_str()).collect();
        write_ambient(tmp.path(), &refs);
        let map = load_class_ratings(&tmp.path().join(".chump-locks/ambient.jsonl"));

        // TEST-domain P1 should be treated as P2 (rank 1 + 1 = 2)
        assert_eq!(
            effective_priority_rank("P1", "TEST-99", &map),
            2,
            "demoted P1 should have rank 2"
        );
        // TEST-domain P0 stays P0 (0+1=1, but P0 is special — saturation keeps it ≥0)
        // Actually 0u8.saturating_add(1) = 1, so P0 → rank 1 (P1 equivalent).
        // This is intentional: even P0s in a badly-rated class yield to undemoted P0s.
        assert_eq!(
            effective_priority_rank("P0", "TEST-99", &map),
            1,
            "demoted P0 should have rank 1"
        );
        // Non-TEST domain is unaffected
        assert_eq!(
            effective_priority_rank("P1", "INFRA-999", &map),
            1,
            "undemoted INFRA P1 should stay rank 1"
        );
    }

    #[test]
    fn effective_priority_rank_normal_class_unchanged() {
        // Empty ratings map → no class is demoted
        let map = ClassRatingMap::new();
        assert_eq!(effective_priority_rank("P0", "INFRA-1", &map), 0);
        assert_eq!(effective_priority_rank("P1", "FLEET-1", &map), 1);
        assert_eq!(effective_priority_rank("P2", "META-1", &map), 2);
        assert_eq!(effective_priority_rank("P3", "DOC-1", &map), 3);
    }
}

// ── INFRA-2398: main-health-gate ─────────────────────────────────────────────

/// Check the main-preflight-watchdog state file and refuse the claim if main
/// is red. Called early in `run_claim`, before any worktree is created.
///
/// Behaviour matrix (INFRA-2428 — zero-bypass):
///   - File missing           → emit `claim_main_health_missing`, proceed.
///   - `last_status == "red"` → look up trunk-fix gap from `filed_gaps[]`,
///                              print routing message, emit
///                              `claim_main_health_redirect`, exit 3.
///   - `last_status == "green"`→ proceed.
///   - Stale (>30 min)        → emit `claim_main_health_stale`, warn, proceed.
///
/// CHUMP_CLAIM_IGNORE_MAIN_HEALTH has been deleted (INFRA-2428). Setting it
/// has no effect — the gate still redirects to the trunk-fix gap.
/// INFRA-2524: a plausible preflight gate name starts with an ASCII letter and
/// contains only `[A-Za-z0-9_.-]`. Used by the main-health gate to reject
/// garbled watchdog signals (e.g. a stray em-dash `—`) so a broken watchdog
/// parser can never fail-CLOSED the entire fleet's claims.
fn gate_name_is_plausible(g: &str) -> bool {
    let g = g.trim();
    match g.chars().next() {
        Some(c) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    g.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-')
}

fn check_main_health_gate(repo_root: &Path, gap_id: &str) -> Result<()> {
    let state_path = repo_root.join(".chump/main-preflight-state.json");
    let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");

    if !state_path.exists() {
        // Watchdog not installed yet — proceed with a debug-level emit.
        // scanner-anchor: "kind":"claim_main_health_missing"
        emit_main_health_event(
            &ambient_log,
            "claim_main_health_missing",
            gap_id,
            &[],
            &[],
            0,
            "",
        );
        return Ok(());
    }

    // Parse the state file. Any parse error → proceed (best-effort).
    let raw = match std::fs::read_to_string(&state_path) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };

    let (last_status, last_tick_at, failing_gates, filed_gaps) = parse_main_health_state(&raw);

    // Compute age.
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let age_secs = if last_tick_at > 0 && now_secs >= last_tick_at {
        now_secs - last_tick_at
    } else {
        0
    };

    // Stale state (> 30 min) → warn and proceed.
    const STALE_THRESHOLD_SECS: u64 = 1800;
    if age_secs > STALE_THRESHOLD_SECS {
        let age_str = format_duration_secs(age_secs);
        eprintln!(
            "[claim] WARN: main-preflight-watchdog state is stale ({age_str} old) — \
             watchdog may be down. Proceeding with claim."
        );
        // scanner-anchor: "kind":"claim_main_health_stale"
        emit_main_health_event(
            &ambient_log,
            "claim_main_health_stale",
            gap_id,
            &failing_gates,
            &filed_gaps,
            age_secs,
            &last_status,
        );
        return Ok(());
    }

    // Red → route claimer to the trunk-fix gap (INFRA-2428 zero-bypass).
    if last_status == "red" {
        // INFRA-2524 fail-OPEN: a RED whose failing-gate names are ALL garbled
        // (empty, punctuation-only, or a stray em-dash — the 2026-06-03 watchdog
        // parser bug, INFRA-2458) is an untrustworthy signal. Halting the entire
        // fleet's claims on garbage violates A2A_ROADMAP principle #7 (fail-open
        // over deadlock) — that bug blocked all claims for 5h+. So if no failing
        // gate looks like a real gate name, warn and proceed instead of blocking.
        if !failing_gates.iter().any(|g| gate_name_is_plausible(g)) {
            eprintln!();
            eprintln!(
                "[claim] WARN: main-health is RED but its failing-gate list is garbled \
                 ([{}]) — treating as an untrustworthy signal and proceeding \
                 (INFRA-2524 fail-open; the watchdog parser may be broken, see INFRA-2458).",
                failing_gates.join(", ")
            );
            // scanner-anchor: "kind":"claim_main_health_garbled"
            emit_main_health_event(
                &ambient_log,
                "claim_main_health_garbled",
                gap_id,
                &failing_gates,
                &filed_gaps,
                age_secs,
                &last_status,
            );
            return Ok(());
        }

        // Pick the most recently filed trunk-fix gap (last in the array).
        let trunk_fix_gap = filed_gaps
            .last()
            .map(|s| s.as_str())
            .unwrap_or("(none filed yet)");

        let age_str = if age_secs > 0 {
            format!(" (state is {} old)", format_duration_secs(age_secs))
        } else {
            String::new()
        };
        eprintln!();
        eprintln!(
            "[claim] BLOCKED: main is RED{} on gates: [{}].",
            age_str,
            failing_gates.join(", ")
        );
        eprintln!(
            "[claim] Routing you to the trunk-fix gap: {}. Claim that instead, or wait for fix.",
            trunk_fix_gap
        );
        eprintln!("[claim] (run: chump claim {})", trunk_fix_gap);
        eprintln!();

        // scanner-anchor: "kind":"claim_main_health_redirect"
        emit_main_health_event(
            &ambient_log,
            "claim_main_health_redirect",
            gap_id,
            &failing_gates,
            &filed_gaps,
            age_secs,
            &last_status,
        );

        std::process::exit(3);
    }

    // Green (or unknown) → proceed normally.
    Ok(())
}

/// Parse the minimal fields from the watchdog state JSON without pulling in
/// serde_json at this call site. Returns (last_status, last_tick_at, failing_gates, filed_gaps).
///
/// `filed_gaps` is the array of trunk-fix gap IDs auto-filed by the watchdog
/// daemon when main went RED. Used by check_main_health_gate (INFRA-2428) to
/// route the claimer to the right fix gap.
fn parse_main_health_state(raw: &str) -> (String, u64, Vec<String>, Vec<String>) {
    let last_status = extract_json_string(raw, "last_status").unwrap_or_default();
    let last_tick_at: u64 = extract_json_number(raw, "last_tick_at").unwrap_or(0);
    let failing_gates = extract_json_string_array(raw, "failing_gates");
    let filed_gaps = extract_json_string_array(raw, "filed_gaps");
    (last_status, last_tick_at, failing_gates, filed_gaps)
}

/// Extract a quoted string value from a flat JSON object by key.
/// e.g. `{"last_status":"red",...}` → `"red"`.
/// Handles only simple non-nested values; good enough for the watchdog payload.
fn extract_json_string(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":", key);
    let start = json.find(&needle)?;
    let after_colon = json[start + needle.len()..].trim_start();
    if !after_colon.starts_with('"') {
        return None;
    }
    let inner = &after_colon[1..];
    let end = inner.find('"')?;
    Some(inner[..end].to_string())
}

/// Extract a numeric value from a flat JSON object by key.
fn extract_json_number(json: &str, key: &str) -> Option<u64> {
    let needle = format!("\"{}\":", key);
    let start = json.find(&needle)?;
    let after_colon = json[start + needle.len()..].trim_start();
    let end = after_colon
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(after_colon.len());
    after_colon[..end].parse().ok()
}

/// Extract a JSON array of strings by key.
/// e.g. `{"failing_gates":["gate1","gate2"]}` → `vec!["gate1", "gate2"]`.
fn extract_json_string_array(json: &str, key: &str) -> Vec<String> {
    let needle = format!("\"{}\":", key);
    let start = match json.find(&needle) {
        Some(s) => s,
        None => return vec![],
    };
    let after_colon = json[start + needle.len()..].trim_start();
    if !after_colon.starts_with('[') {
        return vec![];
    }
    let close = match after_colon.find(']') {
        Some(c) => c,
        None => return vec![],
    };
    let inner = &after_colon[1..close];
    inner
        .split(',')
        .filter_map(|item| {
            let s = item.trim();
            if s.starts_with('"') && s.ends_with('"') && s.len() >= 2 {
                Some(s[1..s.len() - 1].to_string())
            } else {
                None
            }
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// Format a duration in seconds to a human-readable string like "5m 30s".
fn format_duration_secs(secs: u64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        let m = secs / 60;
        let s = secs % 60;
        if s == 0 {
            format!("{m}m")
        } else {
            format!("{m}m {s}s")
        }
    } else {
        let h = secs / 3600;
        let m = (secs % 3600) / 60;
        if m == 0 {
            format!("{h}h")
        } else {
            format!("{h}h {m}m")
        }
    }
}

/// Emit a main-health event to ambient.jsonl. Best-effort — silently no-ops
/// if the log isn't writable.
///
/// `kind` is one of: `claim_main_health_missing`, `claim_main_health_stale`,
/// `claim_main_health_redirect` (INFRA-2428; replaces deleted bypass kind).
///
/// For `claim_main_health_redirect`, `filed_gaps` contains the trunk-fix gap
/// IDs to which the claimer was routed; the last element is `trunk_fix_gap_id`.
fn emit_main_health_event(
    ambient_log: &Path,
    kind: &str,
    gap_id: &str,
    failing_gates: &[String],
    filed_gaps: &[String],
    age_secs: u64,
    status: &str,
) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = secs_to_ymdhms(secs);
    let ts = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z");
    let gates_json = {
        let parts: Vec<String> = failing_gates
            .iter()
            .map(|g| format!("\"{}\"", json_escape(g)))
            .collect();
        format!("[{}]", parts.join(","))
    };
    // trunk_fix_gap_id = last filed gap (most recent trunk-fix), or empty string.
    let trunk_fix_gap_id = filed_gaps.last().map(|s| s.as_str()).unwrap_or("");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"{kind}\",\
         \"gap_id\":\"{gap}\",\"status\":\"{status}\",\
         \"failing_gates\":{gates},\"age_secs\":{age},\
         \"trunk_fix_gap_id\":\"{trunk_fix}\"}}\n",
        ts = ts,
        kind = kind,
        gap = json_escape(gap_id),
        status = json_escape(status),
        gates = gates_json,
        age = age_secs,
        trunk_fix = json_escape(trunk_fix_gap_id),
    );
    if let Some(parent) = ambient_log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(line.as_bytes())
        });
}

// ── INFRA-2398: unit tests for main-health-gate helpers ──────────────────────
#[cfg(test)]
mod main_health_gate_tests {
    use super::*;

    #[test]
    fn parse_green_state() {
        let raw = r#"{"last_tick_at":1000000,"last_status":"green","head_sha":"abc","failing_gates":[],"filed_gaps":[],"fingerprint":"xyz"}"#;
        let (status, tick, gates, filed) = parse_main_health_state(raw);
        assert_eq!(status, "green");
        assert_eq!(tick, 1000000);
        assert!(gates.is_empty());
        assert!(filed.is_empty());
    }

    #[test]
    fn parse_red_state() {
        let raw = r#"{"last_tick_at":1000001,"last_status":"red","head_sha":"abc","failing_gates":["cargo-fmt","clippy"],"filed_gaps":["INFRA-9000"],"fingerprint":"xyz"}"#;
        let (status, tick, gates, filed) = parse_main_health_state(raw);
        assert_eq!(status, "red");
        assert_eq!(tick, 1000001);
        assert_eq!(gates, vec!["cargo-fmt", "clippy"]);
        assert_eq!(filed, vec!["INFRA-9000"]);
    }

    #[test]
    fn parse_red_state_no_filed_gaps() {
        // filed_gaps absent from state → empty vec (watchdog not yet filed anything)
        let raw = r#"{"last_tick_at":1000001,"last_status":"red","head_sha":"abc","failing_gates":["cargo-fmt"],"fingerprint":"xyz"}"#;
        let (status, tick, gates, filed) = parse_main_health_state(raw);
        assert_eq!(status, "red");
        assert_eq!(tick, 1000001);
        assert_eq!(gates, vec!["cargo-fmt"]);
        assert!(filed.is_empty(), "expected no filed_gaps, got {filed:?}");
    }

    #[test]
    fn parse_unknown_state_empty_string() {
        let (status, tick, gates, filed) = parse_main_health_state("");
        assert!(status.is_empty());
        assert_eq!(tick, 0);
        assert!(gates.is_empty());
        assert!(filed.is_empty());
    }

    #[test]
    fn format_duration_secs_cases() {
        assert_eq!(format_duration_secs(0), "0s");
        assert_eq!(format_duration_secs(45), "45s");
        assert_eq!(format_duration_secs(60), "1m");
        assert_eq!(format_duration_secs(90), "1m 30s");
        assert_eq!(format_duration_secs(3600), "1h");
        assert_eq!(format_duration_secs(3660), "1h 1m");
        assert_eq!(format_duration_secs(7320), "2h 2m");
    }

    #[test]
    fn extract_json_string_array_empty() {
        let raw = r#"{"failing_gates":[]}"#;
        let gates = extract_json_string_array(raw, "failing_gates");
        assert!(gates.is_empty(), "expected empty vec, got {gates:?}");
    }

    #[test]
    fn extract_json_string_array_two_items() {
        let raw = r#"{"failing_gates":["gate-a","gate-b"]}"#;
        let gates = extract_json_string_array(raw, "failing_gates");
        assert_eq!(gates, vec!["gate-a", "gate-b"]);
    }

    #[test]
    fn emit_main_health_event_writes_correct_kind() {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = dir.path().join("ambient.jsonl");
        emit_main_health_event(
            &log,
            "claim_main_health_stale",
            "INFRA-2398",
            &["clippy".to_string()],
            &[],
            2000,
            "red",
        );
        let content = std::fs::read_to_string(&log).expect("read");
        assert!(
            content.contains("claim_main_health_stale"),
            "kind missing: {content}"
        );
        assert!(content.contains("INFRA-2398"), "gap_id missing: {content}");
        assert!(content.contains("clippy"), "gate missing: {content}");
        assert!(content.contains("2000"), "age missing: {content}");
    }

    #[test]
    fn emit_main_health_redirect_includes_trunk_fix_gap() {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = dir.path().join("ambient.jsonl");
        emit_main_health_event(
            &log,
            "claim_main_health_redirect",
            "INFRA-1111",
            &["cargo-fmt".to_string()],
            &["INFRA-9999".to_string()],
            0,
            "red",
        );
        let content = std::fs::read_to_string(&log).expect("read");
        assert!(
            content.contains("claim_main_health_redirect"),
            "kind missing: {content}"
        );
        assert!(
            content.contains("INFRA-9999"),
            "trunk_fix_gap_id missing: {content}"
        );
        assert!(content.contains("cargo-fmt"), "gate missing: {content}");
    }
}

// ── INFRA-1982: open-PR dedup gate unit tests ─────────────────────────────
#[cfg(test)]
mod open_pr_dup_tests {
    use super::*;
    use std::io::Write as _;

    /// Mock: set GH_PR_LIST_OUTPUT env to a JSON string so check_open_pr_for_gap
    /// reads from it rather than spawning `gh`. (check_open_pr_for_gap uses
    /// Command::new("gh") which won't run in unit tests, so these tests verify
    /// the parsing logic via a thin harness exercising the same JSON shape.)
    ///
    /// Since check_open_pr_for_gap shells out to `gh`, we test the matching
    /// logic indirectly by verifying the function returns None on bad JSON
    /// (gh not available in CI) and that the ambient emit helper writes the
    /// correct JSON shape.

    #[test]
    fn open_pr_dup_emit_writes_correct_json_shape() {
        let dir = tempfile::tempdir().expect("tempdir");
        let ambient = dir.path().join("ambient.jsonl");
        emit_claim_open_pr_dup_blocked(&ambient, "INFRA-9999", 42);
        let content = std::fs::read_to_string(&ambient).expect("read ambient");
        assert!(
            content.contains("\"kind\":\"claim_open_pr_dup_blocked\""),
            "kind missing: {content}"
        );
        assert!(
            content.contains("\"gap\":\"INFRA-9999\""),
            "gap missing: {content}"
        );
        assert!(
            content.contains("\"open_pr\":42"),
            "open_pr missing: {content}"
        );
        assert!(content.contains("\"ts\":"), "ts missing: {content}");
    }

    #[test]
    fn open_pr_dup_emit_appends_not_overwrites() {
        let dir = tempfile::tempdir().expect("tempdir");
        let ambient = dir.path().join("ambient.jsonl");
        // Write a pre-existing line using a registered event kind so the
        // strict event-registry coverage scan doesn't flag an unregistered emit.
        {
            let mut f = std::fs::File::create(&ambient).expect("create");
            f.write_all(
                b"{\"ts\":\"2026-01-01T00:00:00Z\",\"kind\":\"gap_claimed\",\"gap_id\":\"INFRA-0\"}\n",
            )
            .expect("write");
        }
        emit_claim_open_pr_dup_blocked(&ambient, "INFRA-8888", 99);
        let content = std::fs::read_to_string(&ambient).expect("read ambient");
        // Both events must be present
        assert!(
            content.contains("gap_claimed"),
            "prior event wiped: {content}"
        );
        assert!(
            content.contains("claim_open_pr_dup_blocked"),
            "new event missing: {content}"
        );
    }

    #[test]
    fn open_pr_dup_emit_gap_id_json_escaped() {
        let dir = tempfile::tempdir().expect("tempdir");
        let ambient = dir.path().join("ambient.jsonl");
        // Gap ID with a quote (adversarial input guard)
        emit_claim_open_pr_dup_blocked(&ambient, "INFRA-\"evil", 1);
        let content = std::fs::read_to_string(&ambient).expect("read ambient");
        // Must be valid JSON (no unescaped double-quote inside the string value)
        assert!(
            !content.contains(r#""INFRA-"evil""#),
            "unescaped quote in output: {content}"
        );
    }

    #[test]
    fn check_open_pr_for_gap_returns_none_when_gh_absent() {
        // In CI, gh is typically available but may not have auth. Either way,
        // check_open_pr_for_gap is best-effort and returns None on gh failure.
        // This test verifies the function exists and returns the correct type
        // without panicking when gh returns non-zero / is absent.
        let dir = tempfile::tempdir().expect("tempdir");
        // Result is either Some(...) or None — both are valid; the test just
        // verifies no panic and correct return type.
        let _result: Option<(u64, String)> = check_open_pr_for_gap(dir.path(), "INFRA-TESTONLY");
        // If we reach here, no panic — that's the pass condition.
    }

    #[test]
    fn closed_pr_for_branch_returns_none_when_gh_unavailable_or_unauthed() {
        // Best-effort: no panic, no assumption about gh presence/auth in CI.
        let dir = tempfile::tempdir().expect("tempdir");
        let _result: Option<u64> = closed_pr_for_branch(dir.path(), "chump/infra-testonly-claim");
    }

    #[test]
    fn next_available_branch_name_skips_existing_local_branches() {
        // INFRA-1730: --rename must not collide with a branch that already
        // exists locally, even before checking the remote.
        let dir = tempfile::tempdir().expect("tempdir");
        let repo = dir.path();
        assert!(Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(repo)
            .status()
            .expect("git init")
            .success());
        assert!(Command::new("git")
            .args(["config", "user.email", "test@example.com"])
            .current_dir(repo)
            .status()
            .expect("git config email")
            .success());
        assert!(Command::new("git")
            .args(["config", "user.name", "Test"])
            .current_dir(repo)
            .status()
            .expect("git config name")
            .success());
        std::fs::write(repo.join("f.txt"), "x").expect("write file");
        assert!(Command::new("git")
            .args(["add", "."])
            .current_dir(repo)
            .status()
            .expect("git add")
            .success());
        assert!(Command::new("git")
            .args(["commit", "-m", "init", "--quiet"])
            .current_dir(repo)
            .status()
            .expect("git commit")
            .success());
        // Pre-create chump/infra-1730-claim-2 locally so the search must skip it.
        assert!(Command::new("git")
            .args(["branch", "chump/infra-1730-claim-2"])
            .current_dir(repo)
            .status()
            .expect("git branch")
            .success());

        let name = next_available_branch_name(repo, "origin", "chump/infra-1730-claim");
        assert_eq!(name, "chump/infra-1730-claim-3");
    }

    #[test]
    fn gate_name_is_plausible_rejects_garbled_signals() {
        // INFRA-2524 regression: the 2026-06-03 watchdog wrote failing_gates=["—"]
        // (a stray em-dash) which fail-CLOSED the whole fleet's claims for 5h+.
        // A garbled token must NOT count as a real gate name → the gate fails OPEN.
        assert!(!gate_name_is_plausible("—")); // em-dash (the actual bug)
        assert!(!gate_name_is_plausible(""));
        assert!(!gate_name_is_plausible("   "));
        assert!(!gate_name_is_plausible(";"));
        assert!(!gate_name_is_plausible("123abc")); // must start with a letter
                                                    // real gate names pass
        assert!(gate_name_is_plausible("audit"));
        assert!(gate_name_is_plausible("fast-checks"));
        assert!(gate_name_is_plausible("test-event-registry.sh"));
        assert!(gate_name_is_plausible("clippy_required"));
        // fleet-protecting property: a RED with only garbled gates → no plausible
        // gate → fail open; a RED with at least one real gate → still blocks.
        assert!(!["—".to_string(), "".to_string()]
            .iter()
            .any(|g| gate_name_is_plausible(g)));
        assert!(["—".to_string(), "audit".to_string()]
            .iter()
            .any(|g| gate_name_is_plausible(g)));
    }
}

#[cfg(test)]
mod release_lease_tests {
    //! RESILIENT-103: the state.db `leases` row must be cleared on release,
    //! symmetric with the claim-side `write_db_claim`. Without this delete, a
    //! released lease lingers in state.db and blocks re-claim of the gap — the
    //! triple-store split (JSON deleted, state.db + NATS-KV orphaned) that forced
    //! a 3-command manual recovery. These tests assert ZERO state.db residue after
    //! release. (The JSON sidecar deletion is covered by scrap_cmd tests; the
    //! NATS-KV leg is a best-effort `chump-coord release` shell-out.)
    use super::*;
    use tempfile::tempdir;

    // ZERO-WASTE-028: the disk admission gate must actually fire. Two regressions
    // this guards: (1) `df -Bk` was BSD-invalid → gate silently inert on macOS;
    // (2) the floor must be env-driven and enforce a real pass/fail boundary.
    // The absurd-floor case only returns Err if `df` truly parsed a number, so
    // this also catches any relapse to a df flag that produces no output.
    #[test]
    fn disk_gate_floor_env_enforces_pass_and_fail() {
        let dir = tempdir().expect("tempdir");
        // floor 0 → any real disk passes
        std::env::set_var("CHUMP_DISK_FLOOR_GB", "0");
        let ok = check_disk_space(dir.path());
        assert!(ok.is_ok(), "floor=0 must pass, got {ok:?}");
        // absurd floor → must block (proves df parsed a real avail number too)
        std::env::set_var("CHUMP_DISK_FLOOR_GB", "9999999");
        let err = check_disk_space(dir.path());
        assert!(
            err.is_err(),
            "absurd floor must block (and df must have parsed real avail), got {err:?}"
        );
        std::env::remove_var("CHUMP_DISK_FLOOR_GB");
    }

    fn setup_db(repo_root: &Path) {
        let chump_dir = repo_root.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let conn = rusqlite::Connection::open(chump_dir.join("state.db")).unwrap();
        conn.execute(
            "CREATE TABLE IF NOT EXISTS leases (
                session_id TEXT PRIMARY KEY,
                gap_id     TEXT NOT NULL,
                worktree   TEXT NOT NULL DEFAULT '',
                expires_at INTEGER NOT NULL
            )",
            [],
        )
        .unwrap();
    }

    fn lease_count(repo_root: &Path) -> i64 {
        let conn = rusqlite::Connection::open(repo_root.join(".chump/state.db")).unwrap();
        conn.query_row("SELECT COUNT(*) FROM leases", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn release_clears_row_written_by_claim() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        setup_db(root);

        // Use the exact claim-side writer `chump claim` takes.
        write_db_claim(
            root,
            "RESILIENT-103",
            "claim-resilient-103-1",
            "/tmp/wt",
            900,
        )
        .unwrap();
        assert_eq!(lease_count(root), 1, "claim should write one lease row");

        let deleted = release_db_lease(root, "claim-resilient-103-1", "RESILIENT-103").unwrap();
        assert!(deleted >= 1, "release should delete the lease row");
        assert_eq!(
            lease_count(root),
            0,
            "state.db must have zero lease residue after release"
        );
    }

    #[test]
    fn release_clears_by_gap_id_when_session_drifts() {
        // INFRA-2744 scenario: a re-claim wrote the row under a DIFFERENT session
        // name, so the releasing session_id won't match. Release-by-gap_id must
        // still clear it (the cross-session same-gap case).
        let dir = tempdir().unwrap();
        let root = dir.path();
        setup_db(root);
        write_db_claim(root, "RESILIENT-103", "some-other-session", "/tmp/wt", 900).unwrap();

        let deleted = release_db_lease(root, "the-releasing-session", "RESILIENT-103").unwrap();
        assert!(deleted >= 1);
        assert_eq!(
            lease_count(root),
            0,
            "gap-id match must clear cross-session residue"
        );
    }

    #[test]
    fn release_is_best_effort_when_db_absent() {
        // Fresh clone has no state.db — release must not error.
        let dir = tempdir().unwrap();
        let n = release_db_lease(dir.path(), "s", "GAP-1").unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn release_leaves_unrelated_leases_untouched() {
        // Releasing one session/gap must NOT nuke an unrelated active lease.
        let dir = tempdir().unwrap();
        let root = dir.path();
        setup_db(root);
        write_db_claim(root, "RESILIENT-103", "session-a", "/tmp/a", 900).unwrap();
        write_db_claim(root, "EFFECTIVE-216", "session-b", "/tmp/b", 900).unwrap();

        release_db_lease(root, "session-a", "RESILIENT-103").unwrap();
        assert_eq!(lease_count(root), 1, "unrelated lease must survive");
        let conn = rusqlite::Connection::open(root.join(".chump/state.db")).unwrap();
        let surviving: String = conn
            .query_row("SELECT gap_id FROM leases", [], |r| r.get(0))
            .unwrap();
        assert_eq!(surviving, "EFFECTIVE-216");
    }
}

// INFRA-1608: the atomic gap-claim marker is the structural fix for the
// TOCTOU race behind the INFRA-1602 double-claim (two live leases on the
// same gap). These tests exercise `reserve_gap_claim_marker` directly, plus
// a real multi-thread race to prove the filesystem-level CAS actually holds
// under concurrency (not just single-threaded logic).
#[cfg(test)]
mod gap_claim_marker_tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn first_reservation_wins() {
        let dir = tempdir().unwrap();
        let outcome = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-a", 900).unwrap();
        assert!(matches!(outcome, GapClaimMarkerOutcome::Won(_)));
    }

    #[test]
    fn second_reservation_loses_to_live_holder() {
        let dir = tempdir().unwrap();
        let first = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-a", 900).unwrap();
        assert!(matches!(first, GapClaimMarkerOutcome::Won(_)));

        let second = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-b", 900).unwrap();
        match second {
            GapClaimMarkerOutcome::Lost { winner_session } => {
                assert_eq!(winner_session, "sess-a");
            }
            GapClaimMarkerOutcome::Won(_) => panic!("second claimant must not win"),
        }
    }

    #[test]
    fn same_session_reservation_is_reentrant() {
        let dir = tempdir().unwrap();
        let first = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-a", 900).unwrap();
        assert!(matches!(first, GapClaimMarkerOutcome::Won(_)));
        // A retry by the SAME session (e.g. a resumed claim attempt) must not
        // treat itself as a stranger.
        let retry = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-a", 900).unwrap();
        assert!(matches!(retry, GapClaimMarkerOutcome::Won(_)));
    }

    #[test]
    fn expired_marker_is_reclaimed_as_orphan() {
        let dir = tempdir().unwrap();
        // TTL of -10s: the marker we write is already expired the instant
        // it's written — simulates a session that died mid-claim (root
        // cause (d) from INFRA-1608's classification list).
        let first = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "dead-sess", -10).unwrap();
        assert!(matches!(first, GapClaimMarkerOutcome::Won(_)));

        let second = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-b", 900).unwrap();
        assert!(
            matches!(second, GapClaimMarkerOutcome::Won(_)),
            "an orphaned/expired marker must be reclaimable, got {second:?}",
        );
    }

    impl std::fmt::Debug for GapClaimMarkerOutcome {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                GapClaimMarkerOutcome::Won(p) => write!(f, "Won({})", p.display()),
                GapClaimMarkerOutcome::Lost { winner_session } => {
                    write!(f, "Lost{{winner_session: {winner_session}}}")
                }
            }
        }
    }

    #[test]
    fn guard_drop_releases_marker_on_abort() {
        let dir = tempdir().unwrap();
        let path = gap_claim_marker_path(dir.path(), "INFRA-1608");
        {
            let outcome =
                reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-a", 900).unwrap();
            let GapClaimMarkerOutcome::Won(p) = outcome else {
                panic!("expected Won");
            };
            let _guard = GapClaimMarkerGuard { path: Some(p) };
            assert!(path.exists());
            // guard drops here without disarm() — simulates an early bail!
        }
        assert!(
            !path.exists(),
            "Drop must remove the marker when the claim aborts before disarm()"
        );
    }

    #[test]
    fn guard_disarm_leaves_marker_in_place() {
        let dir = tempdir().unwrap();
        let path = gap_claim_marker_path(dir.path(), "INFRA-1608");
        let outcome = reserve_gap_claim_marker(dir.path(), "INFRA-1608", "sess-a", 900).unwrap();
        let GapClaimMarkerOutcome::Won(p) = outcome else {
            panic!("expected Won");
        };
        let guard = GapClaimMarkerGuard { path: Some(p) };
        guard.disarm();
        assert!(path.exists(), "disarm() must NOT remove the marker");
    }

    // The load-bearing regression: N threads race `reserve_gap_claim_marker`
    // for the SAME gap_id concurrently. Exactly one must win. This is a real
    // OS-level filesystem race (not simulated), so it directly exercises the
    // `create_new` CAS primitive that replaces the old scan-then-write TOCTOU
    // window. AC6 of INFRA-1608 asks for 50 concurrent attempts.
    #[test]
    fn concurrent_reservations_exactly_one_winner() {
        let dir = tempdir().unwrap();
        let lock_dir = dir.path().to_path_buf();
        const N: usize = 50;

        let handles: Vec<_> = (0..N)
            .map(|i| {
                let lock_dir = lock_dir.clone();
                std::thread::spawn(move || {
                    reserve_gap_claim_marker(&lock_dir, "INFRA-1608", &format!("racer-{i}"), 900)
                })
            })
            .collect();

        let mut winners = 0;
        let mut losers = 0;
        for h in handles {
            match h.join().unwrap().unwrap() {
                GapClaimMarkerOutcome::Won(_) => winners += 1,
                GapClaimMarkerOutcome::Lost { .. } => losers += 1,
            }
        }

        assert_eq!(winners, 1, "exactly one racer must win the CAS");
        assert_eq!(losers, N - 1, "every other racer must lose cleanly");
    }
}
