//! `chump ingest <repo-path>` — INFRA-1780 (INFRA-1746 phase 1a) +
//! INFRA-1784 (INFRA-1746 phase 5, orchestration).
//!
//! Phase 1a scope, deliberately narrow: validate that the target is a
//! directory containing `.git`, and emit observability events. **No
//! filesystem mutation, git operation, or network call happens in this
//! phase, regardless of `--confirm-mutations`.** Once validation passes,
//! `--confirm-mutations` hands off to `ingest_orchestrate::run` (INFRA-1784),
//! which runs the Librarian/Cartographer/Evangelist/Systematizer phases in
//! sequence and writes the takeover certificate + proposed gaps. Without
//! `--confirm-mutations`, `chump ingest` stays fully read-only (phase 1a
//! only) — that's the safety contract INFRA-1746 requires.

use std::path::Path;
use std::time::Instant;

const DEFAULT_BUDGET_USD: f64 = 10.0;

struct Opts {
    repo_path: String,
    budget_usd_raw: String,
    confirm_mutations: bool,
    import_backlog: bool,
    domain: String,
}

enum ParseOutcome {
    Ok(Opts),
    Help,
    UsageError(String),
}

/// `chump ingest` subcommand entry point. `args` is everything after `ingest`.
pub fn run(args: &[String]) -> i32 {
    match parse_args(args) {
        ParseOutcome::Help => {
            print_usage();
            0
        }
        ParseOutcome::UsageError(msg) => {
            eprintln!("chump ingest: {msg}");
            print_usage();
            2
        }
        ParseOutcome::Ok(opts) => run_validated(&opts),
    }
}

fn parse_args(args: &[String]) -> ParseOutcome {
    let mut repo_path: Option<String> = None;
    let mut budget_usd_raw = DEFAULT_BUDGET_USD.to_string();
    let mut confirm_mutations = false;
    let mut import_backlog = false;
    let mut domain = "INFRA".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => return ParseOutcome::Help,
            "--confirm-mutations" => confirm_mutations = true,
            "--import-backlog" => import_backlog = true,
            "--domain" => {
                i += 1;
                match args.get(i) {
                    Some(v) => domain = v.clone(),
                    None => return ParseOutcome::UsageError("--domain requires a value".into()),
                }
            }
            a if a.starts_with("--domain=") => {
                domain = a.trim_start_matches("--domain=").to_string();
            }
            "--budget-usd" => {
                i += 1;
                match args.get(i) {
                    Some(v) => budget_usd_raw = v.clone(),
                    None => {
                        return ParseOutcome::UsageError("--budget-usd requires a value".into())
                    }
                }
            }
            a if a.starts_with("--budget-usd=") => {
                budget_usd_raw = a.trim_start_matches("--budget-usd=").to_string();
            }
            a if !a.starts_with('-') => {
                if repo_path.is_some() {
                    return ParseOutcome::UsageError(format!("unexpected extra argument: {a}"));
                }
                repo_path = Some(a.to_string());
            }
            a => return ParseOutcome::UsageError(format!("unknown flag: {a}")),
        }
        i += 1;
    }
    match repo_path {
        Some(p) => ParseOutcome::Ok(Opts {
            repo_path: p,
            budget_usd_raw,
            confirm_mutations,
            import_backlog,
            domain,
        }),
        None => ParseOutcome::UsageError(
            "missing required argument <repo-path>\nUsage: chump ingest <repo-path> [--budget-usd N] [--confirm-mutations]".into(),
        ),
    }
}

fn print_usage() {
    println!("Usage: chump ingest <repo-path> [options]");
    println!();
    println!("Phase 1a (INFRA-1780): validates <repo-path> is a directory containing");
    println!("a .git subdirectory. Read-only — no filesystem mutation, git operation,");
    println!("or network call is performed unless --confirm-mutations is passed.");
    println!();
    println!("With --confirm-mutations (INFRA-1784, phase 5): runs the Librarian,");
    println!("Cartographer, Evangelist, and Systematizer phases in sequence, writes");
    println!("<repo-path>/.chump-ingest/certificate.json (takeover certificate) and");
    println!("<repo-path>/.chump-ingest/proposed-gaps.json (up to 5 candidate gaps).");
    println!("Auto-PR opening is deferred past v1 — see INFRA-1784 module doc.");
    println!();
    println!();
    println!("With --import-backlog (MISSION-055): reads the repo's DEFINED backlog —");
    println!(".beast-mode-tasks.json, a beads JSONL store, or TODO.md/TODO — and files");
    println!("one fleet gap per item via `chump gap reserve`, tagged");
    println!("external_repo:<owner/repo>. Idempotent: re-running skips items already");
    println!("imported (tracked via an [ingest:<repo>:<key>] marker in the gap title).");
    println!();
    println!("Options:");
    println!("  --budget-usd N       Cost ceiling for downstream phases (default: 10.0)");
    println!("  --confirm-mutations  Run the full orchestration instead of validate-only");
    println!("  --import-backlog     Import the repo's defined backlog as fleet gaps");
    println!("  --domain D           Gap domain for imported items (default: INFRA)");
}

fn run_validated(opts: &Opts) -> i32 {
    let start = Instant::now();
    emit_ingest_initiated(&opts.repo_path, &opts.budget_usd_raw);

    let budget_usd = match opts.budget_usd_raw.parse::<f64>() {
        Ok(v) if v.is_finite() && v > 0.0 => v,
        _ => {
            let elapsed_ms = start.elapsed().as_millis();
            let error = format!(
                "--budget-usd must be a positive number, got '{}'",
                opts.budget_usd_raw
            );
            emit_ingest_failed(&opts.repo_path, "invalid_budget", false, elapsed_ms, &error);
            eprintln!("chump ingest: {error}");
            return 1;
        }
    };

    let path = Path::new(&opts.repo_path);
    if !path.exists() {
        let elapsed_ms = start.elapsed().as_millis();
        let error = format!("path does not exist: {}", opts.repo_path);
        emit_ingest_failed(&opts.repo_path, "path_not_found", false, elapsed_ms, &error);
        eprintln!("chump ingest: {error}");
        return 1;
    }
    if !path.is_dir() || !path.join(".git").exists() {
        let elapsed_ms = start.elapsed().as_millis();
        let error = format!(
            "path is not a git repository (expected a directory containing .git): {}",
            opts.repo_path
        );
        emit_ingest_failed(&opts.repo_path, "not_a_git_repo", false, elapsed_ms, &error);
        eprintln!("chump ingest: {error}");
        return 1;
    }

    let elapsed_ms = start.elapsed().as_millis();
    emit_ingest_validated(&opts.repo_path, elapsed_ms);

    if opts.import_backlog {
        return run_backlog_import(path, &opts.domain);
    }

    if !opts.confirm_mutations {
        println!(
            "chump ingest: {} is a valid git repository (phase 1a — read-only, no mutation performed; budget=${budget_usd:.2})",
            opts.repo_path
        );
        println!("chump ingest: re-run with --confirm-mutations to run the full orchestration (INFRA-1784).");
        return 0;
    }

    run_orchestration(path, budget_usd)
}

/// `--import-backlog` path (MISSION-055): reads the repo's DEFINED backlog
/// and files one fleet gap per item via `chump gap reserve`.
fn run_backlog_import(target_repo: &Path, domain: &str) -> i32 {
    emit_backlog_import_started(target_repo);
    match crate::ingest_backlog::run_import(target_repo, domain) {
        Ok(report) => {
            println!(
                "chump ingest: backlog import complete for {} — source: {}, items found: {}, gaps created: {}, skipped (already imported): {}",
                target_repo.display(),
                report.source,
                report.items_found,
                report.gaps_created,
                report.gaps_skipped_existing,
            );
            for id in &report.created_ids {
                println!("  {id}");
            }
            emit_backlog_import_completed(target_repo, &report);
            0
        }
        Err(e) => {
            eprintln!("chump ingest: backlog import failed: {e}");
            emit_backlog_import_failed(target_repo, &e);
            1
        }
    }
}

/// `--confirm-mutations` path (INFRA-1784, INFRA-1746 phase 5): runs the
/// Librarian/Cartographer/Evangelist/Systematizer phases in sequence,
/// writes the takeover certificate + proposed gaps.
fn run_orchestration(target_repo: &Path, budget_usd: f64) -> i32 {
    let chump_repo_root = crate::repo_path::repo_root();
    let cfg = crate::ingest_orchestrate::OrchestrateConfig {
        target_repo: target_repo.to_path_buf(),
        budget_usd,
    };
    crate::ingest_orchestrate::emit_started(&chump_repo_root, target_repo);
    match crate::ingest_orchestrate::run(&cfg) {
        Ok(report) => {
            println!(
                "chump ingest: orchestration complete for {} — phases: {}, gaps proposed: {}, cost: ${:.2}, certificate: {}",
                target_repo.display(),
                report.phases_completed.join(", "),
                report.gaps_proposed.len(),
                report.total_cost_usd_cents as f64 / 100.0,
                report.certificate_path.display(),
            );
            crate::ingest_orchestrate::emit_completed(&chump_repo_root, &report);
            0
        }
        Err(e) => {
            eprintln!("chump ingest: orchestration failed: {e}");
            crate::ingest_orchestrate::emit_failed(&chump_repo_root, target_repo, &e);
            if e.class.transient() {
                1
            } else {
                2
            }
        }
    }
}

fn emit_ingest_initiated(repo_path: &str, budget_usd_raw: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_initiated".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), repo_path.to_string()),
            ("budget_usd".to_string(), budget_usd_raw.to_string()),
        ],
        ..Default::default()
    });
}

fn emit_ingest_validated(repo_path: &str, elapsed_ms: u128) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_validated".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), repo_path.to_string()),
            ("cost_usd_cents".to_string(), "0".to_string()),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
        ],
        ..Default::default()
    });
}

fn emit_ingest_failed(
    repo_path: &str,
    failure_class: &str,
    transient: bool,
    elapsed_ms: u128,
    error: &str,
) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_failed".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), repo_path.to_string()),
            ("failure_class".to_string(), failure_class.to_string()),
            ("transient".to_string(), transient.to_string()),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
            ("error".to_string(), error.to_string()),
        ],
        ..Default::default()
    });
}

fn emit_backlog_import_started(target_repo: &Path) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        // scanner-anchor: "kind":"ingest_backlog_import_started"
        kind: "ingest_backlog_import_started".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![("repo_path".to_string(), target_repo.display().to_string())],
        ..Default::default()
    });
}

fn emit_backlog_import_completed(target_repo: &Path, report: &crate::ingest_backlog::ImportReport) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        // scanner-anchor: "kind":"ingest_backlog_import_completed"
        kind: "ingest_backlog_import_completed".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), target_repo.display().to_string()),
            ("source".to_string(), report.source.clone()),
            ("items_found".to_string(), report.items_found.to_string()),
            ("gaps_created".to_string(), report.gaps_created.to_string()),
            (
                "gaps_skipped_existing".to_string(),
                report.gaps_skipped_existing.to_string(),
            ),
        ],
        ..Default::default()
    });
}

fn emit_backlog_import_failed(target_repo: &Path, error: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        // scanner-anchor: "kind":"ingest_backlog_import_failed"
        kind: "ingest_backlog_import_failed".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("repo_path".to_string(), target_repo.display().to_string()),
            ("error".to_string(), error.to_string()),
        ],
        ..Default::default()
    });
}
