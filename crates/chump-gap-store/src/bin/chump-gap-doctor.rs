//! `chump-gap-doctor` — Rust port of `scripts/coord/gap-doctor.py`
//! (Phase 1 of INFRA-2000 / META-107).
//!
//! ## Subcommands
//!
//! - `doctor`          — print drift report (read-only)
//! - `sync-from-yaml`  — UPDATE DB rows where YAML says `done`
//!                        (`--apply` to mutate; default dry-run)
//! - `sync-from-db`    — placeholder for regenerating per-file YAML
//!                        mirrors from DB. Phase 1 surfaces a banner and
//!                        defers the rewrite path to the legacy
//!                        `chump gap dump --per-file` invocation; not
//!                        ported here because the rewrite needs the
//!                        full `dump_per_file` surface which lives on
//!                        `GapStore` already.
//! - `safe-sweep`      — placeholder. The Python tool's safe-sweep
//!                        emits ambient ALERTs; Phase 1 forbids new
//!                        ambient emit, so this subcommand prints a
//!                        notice and exits 0.
//! - `check-second-store` — RESILIENT-1057: sqlite (`state.db`) is the
//!                        canonical gap store. If `CHUMP_GAP_STORE_URL` is
//!                        set (the optional PostgREST second store,
//!                        INFRA-2092), probe it via `curl` and compare its
//!                        open-gap count to sqlite's. Unset/unreachable is
//!                        treated as dormant (fine); reachable-but-diverging
//!                        is the silent split-brain this guards against.
//!
//! ## Exit codes
//!
//! - `doctor`         — 0 on zero drift, 1 on any drift.
//! - `sync-from-yaml` — 0 on success, 1 on DB error.
//! - `sync-from-db`   — 0 (banner only).
//! - `safe-sweep`     — 0 (banner only).
//! - `check-second-store` — 0 if canonical/dormant/consistent, 1 if diverged.

use std::process::{Command, ExitCode};

use chump_gap_store::backend::guard::{evaluate, SecondStoreState};
use chump_gap_store::maintenance::doctor::{GapDoctor, HealMode};
use chump_gap_store::maintenance::resolve_repo_root;
use chump_gap_store::GapStore;

fn usage() {
    eprintln!("usage: chump-gap-doctor <doctor|sync-from-yaml|sync-from-db|safe-sweep|check-second-store> [--apply] [--dry-run]");
}

/// RESILIENT-1057: probe the optional PostgREST second store (if
/// `CHUMP_GAP_STORE_URL` is set) via `curl` and turn the result into a
/// [`SecondStoreState`]. Shelling out to `curl` avoids pulling an HTTP
/// client dependency into `chump-gap-store` for a check that only runs
/// when an operator has opted into the second store.
fn probe_second_store(base_url: &str) -> SecondStoreState {
    // `Prefer: count=exact` + `Range: 0-0` asks PostgREST for a
    // `Content-Range: 0-0/<exact-count>` header without transferring rows.
    let output = Command::new("curl")
        .arg("-sS")
        .arg("-i")
        .arg("--max-time")
        .arg("5")
        .arg("-H")
        .arg("Prefer: count=exact")
        .arg("-H")
        .arg("Range-Unit: items")
        .arg("-H")
        .arg("Range: 0-0")
        .arg(format!("{base_url}/shared_gaps?status=eq.open&select=id"))
        .output();

    let output = match output {
        Ok(o) => o,
        Err(e) => {
            return SecondStoreState::Unreachable {
                detail: format!("curl spawn failed: {e}"),
            }
        }
    };
    if !output.status.success() {
        return SecondStoreState::Unreachable {
            detail: format!(
                "curl exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        };
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let status_line = text.lines().next().unwrap_or("");
    if !(status_line.contains(" 200") || status_line.contains(" 206")) {
        return SecondStoreState::Unreachable {
            detail: format!("non-2xx response: {}", status_line.trim()),
        };
    }
    // Content-Range: 0-0/1946  (or 0-0/*  if PostgREST couldn't count)
    let count = text
        .lines()
        .find_map(|line| {
            line.strip_prefix("Content-Range: ")
                .or_else(|| line.strip_prefix("content-range: "))
        })
        .and_then(|v| v.rsplit('/').next())
        .and_then(|n| n.trim().parse::<u64>().ok());
    match count {
        Some(n) => SecondStoreState::Reachable { open_count: n },
        None => SecondStoreState::Unreachable {
            detail: format!("no parseable Content-Range in response headers: {status_line}"),
        },
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        return ExitCode::from(2);
    }
    let cmd = args[0].as_str();
    let flag_apply = args.iter().any(|a| a == "--apply");

    let root = match resolve_repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[chump-gap-doctor] resolve_repo_root failed: {}", e);
            return ExitCode::from(2);
        }
    };

    // INFRA-499 short-circuit: if docs/gaps/ has no YAMLs at all, the
    // entire drift detection is moot. Matches the Python tool's behavior.
    let gaps_dir = root.join("docs").join("gaps");
    let has_yamls = gaps_dir.is_dir()
        && std::fs::read_dir(&gaps_dir)
            .map(|it| {
                it.filter_map(|r| r.ok()).any(|e| {
                    e.path()
                        .extension()
                        .and_then(|s| s.to_str())
                        .map(|ext| ext.eq_ignore_ascii_case("yaml"))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);
    if !has_yamls {
        eprintln!(
            "[chump-gap-doctor] post-INFRA-498: docs/gaps/*.yaml deleted — \
             no drift to detect. state.db is the only truth (INFRA-8193). \
             Use 'chump gap show <ID>' for \
             human-readable per-gap inspection."
        );
        return ExitCode::SUCCESS;
    }

    let doctor = GapDoctor::new(&root);

    match cmd {
        "doctor" => {
            let report = match doctor.heal(HealMode::ScanOnly) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[chump-gap-doctor] doctor failed: {:#}", e);
                    return ExitCode::from(2);
                }
            };
            print!("{}", report.render());
            if report.drift_total() == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(1)
            }
        }
        "sync-from-yaml" => {
            let mode = if flag_apply {
                HealMode::FixSafe
            } else {
                HealMode::ScanOnly
            };
            let report = match doctor.heal(mode) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[chump-gap-doctor] sync-from-yaml failed: {:#}", e);
                    return ExitCode::from(1);
                }
            };
            println!(
                "== sync-from-yaml: {} rows to update ==",
                report.buckets.db_open_yaml_done.len()
            );
            for gid in &report.buckets.db_open_yaml_done {
                println!("  {} (status open->done)", gid);
            }
            if !flag_apply {
                println!();
                println!("(dry-run — pass --apply to mutate state.db)");
            } else if report.rows_updated > 0 {
                println!("applied: {} rows", report.rows_updated);
            } else {
                println!("nothing to do");
            }
            ExitCode::SUCCESS
        }
        "sync-from-db" => {
            // Phase 1: defer the per-file YAML rewrite to `chump gap dump
            // --per-file`. The Python tool calls `subprocess.run([...])`
            // for this; we surface the call as a guidance banner so
            // operators see what to run, and exit 0 (no error).
            let scan = match doctor.heal(HealMode::ScanOnly) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[chump-gap-doctor] sync-from-db scan failed: {:#}", e);
                    return ExitCode::from(1);
                }
            };
            println!(
                "== sync-from-db: {} rows would flip in YAML ==",
                scan.buckets.db_done_yaml_open.len()
            );
            for gid in &scan.buckets.db_done_yaml_open {
                println!("  {}", gid);
            }
            println!();
            println!(
                "(Phase 1 routes per-file YAML rewrites through the legacy path. \
                 Run: chump gap dump --per-file --out-dir docs/gaps to apply.)"
            );
            ExitCode::SUCCESS
        }
        "check-second-store" => {
            // RESILIENT-1057: sqlite (state.db) is canonical. If
            // CHUMP_GAP_STORE_URL points at a live PostgREST second store,
            // verify it agrees with sqlite's open-gap count instead of
            // silently trusting (or ignoring) it.
            let store = match GapStore::open(&root) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!(
                        "[chump-gap-doctor] check-second-store: failed to open state.db: {:#}",
                        e
                    );
                    return ExitCode::from(2);
                }
            };
            let sqlite_open = match store.list_by_status_ordered("open") {
                Ok(rows) => rows.len() as u64,
                Err(e) => {
                    eprintln!(
                        "[chump-gap-doctor] check-second-store: failed to list open gaps: {:#}",
                        e
                    );
                    return ExitCode::from(2);
                }
            };
            let second_store = match std::env::var("CHUMP_GAP_STORE_URL") {
                Ok(url) if !url.trim().is_empty() => probe_second_store(url.trim()),
                _ => SecondStoreState::NotConfigured,
            };
            let verdict = evaluate(sqlite_open, &second_store);
            println!(
                "[chump-gap-doctor] check-second-store: {}",
                verdict.render()
            );
            if verdict.is_alarm() {
                ExitCode::from(1)
            } else {
                ExitCode::SUCCESS
            }
        }
        "safe-sweep" => {
            // Phase 1 forbids new ambient emit; the Python tool's
            // safe-sweep is the one writing ALERTs. Defer to legacy.
            eprintln!(
                "[chump-gap-doctor] safe-sweep is Phase-1-deferred — \
                 unset CHUMP_GAP_MAINTENANCE_RUST to run the Python \
                 safe-sweep (it owns the ambient ALERT semantics)."
            );
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("[chump-gap-doctor] unknown subcommand: {}", cmd);
            usage();
            ExitCode::from(2)
        }
    }
}
