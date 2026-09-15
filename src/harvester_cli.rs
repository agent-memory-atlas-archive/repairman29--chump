//! `chump harvest <subcommand>` — INFRA-1823.
//!
//! Productizes the Harvester (fleet cartographer) as a first-class Chump
//! engine capability instead of a Claude-Code-session-only shell script.
//! Usable from any harness (Claude Code, opencode, codex, manual) the same
//! way every other `chump <subcommand>` is.
//!
//! The Rust layer here owns argument validation (usage errors → exit 2,
//! matching the convention used by `chump gap decompose` et al.) and the two
//! behaviors that need to live outside the shell script: the high-severity
//! alert gate on `scan`, and the self-invocation used by `chump gap
//! decompose`'s pre-flight (see `check_topic_output` in main.rs).
//!
//! The jq/gh catalog logic itself stays in `scripts/arsenal/harvest.sh` —
//! duplicating it here would mean two sources of truth for what counts as
//! an "overlap". `chump harvest` is a thin, validated front door onto that
//! script, the same shape as `chump cartograph` / `chump ingest` wrap their
//! phase scripts.

use std::path::PathBuf;
use std::process::Command;

fn repo_root() -> PathBuf {
    crate::repo_path::repo_root()
}

fn harvest_script() -> PathBuf {
    repo_root().join("scripts/arsenal/harvest.sh")
}

fn catalog_path() -> PathBuf {
    repo_root().join("docs/arsenal/GLOBAL_ARSENAL.json")
}

fn print_help() {
    println!("chump harvest — Fleet Cartographer CLI (INFRA-1823)");
    println!();
    println!("Catalogs load-bearing primitives across the repairman29 fleet so Chump");
    println!("never re-implements what already exists. Wraps scripts/arsenal/harvest.sh");
    println!("+ scripts/arsenal/build.py; usable from any harness.");
    println!();
    println!("USAGE");
    println!("  chump harvest scan                       Refresh the catalog from `gh repo list`");
    println!(
        "  chump harvest check <GAP-ID|topic>        Print arsenal overlap for a gap or topic"
    );
    println!("  chump harvest brief <src-repo> <target>   Scaffold a Cross-Pollination Brief");
    println!("  chump harvest deep-scan <cluster>          List repos in a cluster with metadata");
    println!("  chump harvest list-clusters                Print all known cluster names + counts");
    println!("  chump harvest help                         Show this help");
    println!();
    println!("EXIT CODES");
    println!("  0   success (or overlap found, for `check`)");
    println!("  1   no overlap found (`check`) / high-severity alert present (`scan`)");
    println!("  2   bad input — missing required argument or unknown subcommand");
    println!("  3   catalog missing — run `chump harvest scan` first");
}

/// Runs `scripts/arsenal/harvest.sh <sub> <args..>`, inheriting stdio, and
/// returns its exit code (defaulting to 1 if the process couldn't be
/// spawned or was killed by a signal).
fn run_script(sub: &str, extra: &[String]) -> i32 {
    let script = harvest_script();
    if !script.exists() {
        eprintln!("chump harvest: script missing at {}", script.display());
        return 3;
    }
    match Command::new("bash")
        .arg(&script)
        .arg(sub)
        .args(extra)
        .current_dir(repo_root())
        .status()
    {
        Ok(status) => status.code().unwrap_or(1),
        Err(e) => {
            eprintln!("chump harvest: failed to run {}: {e}", script.display());
            1
        }
    }
}

/// Same as `run_script` but captures stdout instead of inheriting it.
/// Used by `chump gap decompose`'s pre-flight check (AC4) — the caller
/// wants the text to embed as a citation, not to print it directly.
pub fn capture_check(topic: &str) -> Option<(bool, String)> {
    let script = harvest_script();
    if !script.exists() || !catalog_path().exists() {
        return None;
    }
    let output = Command::new("bash")
        .arg(&script)
        .arg("check")
        .arg(topic)
        .current_dir(repo_root())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Some((output.status.success(), text))
}

/// Checks the freshly-rebuilt catalog for `severity: "high"` alerts.
/// Returns the count found (0 means clean).
fn count_high_severity_alerts() -> usize {
    let path = catalog_path();
    let Ok(text) = std::fs::read_to_string(&path) else {
        return 0;
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
        return 0;
    };
    json.get("alerts")
        .and_then(|a| a.as_array())
        .map(|alerts| {
            alerts
                .iter()
                .filter(|a| a.get("severity").and_then(|s| s.as_str()) == Some("high"))
                .count()
        })
        .unwrap_or(0)
}

pub fn run(args: &[String]) -> i32 {
    let Some(sub) = args.first().map(String::as_str) else {
        // No subcommand at all — usage error (AC2), distinct from an
        // explicit `chump harvest help`/`--help` request (which is a
        // successful help print, AC1).
        eprintln!("chump harvest: missing subcommand");
        print_help();
        return 2;
    };
    let rest: Vec<String> = args.iter().skip(1).cloned().collect();

    match sub {
        "scan" => {
            let code = run_script("scan", &[]);
            if code != 0 {
                return code;
            }
            let high = count_high_severity_alerts();
            if high > 0 {
                eprintln!(
                    "chump harvest scan: {high} high-severity alert(s) present — see docs/arsenal/GLOBAL_ARSENAL.json .alerts"
                );
                return 1;
            }
            0
        }

        "check" => {
            let topic = rest.first();
            let Some(topic) = topic else {
                eprintln!("Usage: chump harvest check <GAP-ID|topic>");
                return 2;
            };
            if topic.starts_with("--") || topic.is_empty() {
                eprintln!("Usage: chump harvest check <GAP-ID|topic>");
                return 2;
            }
            run_script("check", std::slice::from_ref(topic))
        }

        "brief" => {
            if rest.len() < 2 || rest[0].starts_with("--") || rest[1].starts_with("--") {
                eprintln!("Usage: chump harvest brief <src-repo> <target>");
                return 2;
            }
            run_script("brief", &rest[..2])
        }

        "deep-scan" => {
            let cluster = rest.first();
            let Some(cluster) = cluster else {
                eprintln!("Usage: chump harvest deep-scan <cluster>");
                return 2;
            };
            if cluster.starts_with("--") || cluster.is_empty() {
                eprintln!("Usage: chump harvest deep-scan <cluster>");
                return 2;
            }
            run_script("deep-scan", std::slice::from_ref(cluster))
        }

        "list-clusters" => run_script("list-clusters", &[]),

        "help" | "--help" | "-h" => {
            print_help();
            0
        }

        other => {
            eprintln!("chump harvest: unknown subcommand '{other}'");
            eprintln!("run 'chump harvest help' for usage");
            2
        }
    }
}
