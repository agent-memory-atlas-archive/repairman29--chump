//! `chump swe <prompt>` — one-shot bounded SWE-agent wrapper (INFRA-2089).
//!
//! Productizes the existing per-gap claim -> worktree -> subagent-dispatch
//! -> auto-merge pipeline ([`crate::dispatch::run`]) as a single command
//! surface for a raw natural-language prompt, so a user never has to know
//! the gap registry exists:
//!
//! 1. Reserve a synthetic `INFRA` gap whose title is the prompt.
//! 2. Dispatch a headless (`claude -p`) sub-agent into a fresh `/tmp`-style
//!    worktree under a wall-clock budget (`CHUMP_SUBAGENT_BUDGET_S`, already
//!    enforced by [`crate::dispatch::spawn_headless`]'s watchdog).
//! 3. Arm auto-merge on success (`--auto-merge` on the underlying ship step).
//! 4. Emit exactly one `kind=swe_invocation_complete` ambient event summarizing
//!    the outcome: `success` | `failed` | `killed_at_budget`.
//!
//! `--budget-tokens` / `--budget-dollars` are accepted and threaded through
//! to the emitted event for observability, but are advisory-only today —
//! chump has no per-call token/cost metering hook at the dispatch layer, so
//! the enforced budget is wall-clock (`--budget-secs`).

use crate::dispatch::{self, DispatchMode, DispatchOptions, ShipResult, WorkBackend};
use crate::repo_path;
use std::process::Command;

const DEFAULT_BUDGET_SECS: u64 = 1800;

struct SweArgs {
    prompt: String,
    budget_secs: u64,
    budget_tokens: Option<u64>,
    budget_dollars: Option<f64>,
    paths: Option<String>,
    dry_run_diff: bool,
}

const USAGE: &str = "Usage: chump swe '<prompt>' [--budget-secs N] [--budget-tokens N] [--budget-dollars N] [--paths CSV] [--dry-run-diff]";

fn parse_args(args: &[String]) -> Result<SweArgs, String> {
    // args[0] == "swe"
    let mut prompt: Option<String> = None;
    let mut budget_secs = DEFAULT_BUDGET_SECS;
    let mut budget_tokens = None;
    let mut budget_dollars = None;
    let mut paths = None;
    let mut dry_run_diff = false;

    let mut i = 1;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--budget-secs" => {
                i += 1;
                budget_secs = args
                    .get(i)
                    .and_then(|v| v.parse::<u64>().ok())
                    .ok_or_else(|| "--budget-secs requires a numeric value".to_string())?;
            }
            "--budget-tokens" => {
                i += 1;
                let v = args
                    .get(i)
                    .and_then(|v| v.parse::<u64>().ok())
                    .ok_or_else(|| "--budget-tokens requires a numeric value".to_string())?;
                budget_tokens = Some(v);
            }
            "--budget-dollars" => {
                i += 1;
                let v = args
                    .get(i)
                    .and_then(|v| v.parse::<f64>().ok())
                    .ok_or_else(|| "--budget-dollars requires a numeric value".to_string())?;
                budget_dollars = Some(v);
            }
            "--paths" => {
                i += 1;
                paths = Some(
                    args.get(i)
                        .cloned()
                        .ok_or_else(|| "--paths requires a value".to_string())?,
                );
            }
            "--dry-run-diff" => {
                dry_run_diff = true;
            }
            other if other.starts_with('-') => {
                return Err(format!("unknown flag: {other}\n{USAGE}"));
            }
            other => {
                if prompt.is_some() {
                    return Err(format!(
                        "chump swe takes a single quoted prompt argument (got extra: {other:?})\n{USAGE}"
                    ));
                }
                prompt = Some(other.to_string());
            }
        }
        i += 1;
    }

    let prompt = prompt.ok_or_else(|| USAGE.to_string())?;
    if prompt.trim().is_empty() {
        return Err(format!("prompt must not be empty\n{USAGE}"));
    }
    Ok(SweArgs {
        prompt,
        budget_secs,
        budget_tokens,
        budget_dollars,
        paths,
        dry_run_diff,
    })
}

fn chump_bin() -> String {
    std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string())
}

/// Derive a gap title from the prompt: single line, capped length, tagged
/// so the registry can tell a `chump swe` invocation apart from a
/// hand-filed gap at a glance.
fn title_from_prompt(prompt: &str) -> String {
    let single_line: String = prompt.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_CHARS: usize = 110;
    if single_line.chars().count() > MAX_CHARS {
        let truncated: String = single_line.chars().take(MAX_CHARS).collect();
        format!("swe: {truncated}…")
    } else {
        format!("swe: {single_line}")
    }
}

/// Reserve a synthetic `INFRA` gap for this one-shot prompt. P2 so it
/// doesn't hit the MISSION-045 `--outcome` requirement gate — a `chump swe`
/// invocation is a direct user ask, not a fleet-planned priority gap.
fn reserve_gap(prompt: &str) -> Result<String, String> {
    let title = title_from_prompt(prompt);
    let out = Command::new(chump_bin())
        .args([
            "gap",
            "reserve",
            "--domain",
            "INFRA",
            "--title",
            &title,
            "--priority",
            "P2",
            "--effort",
            "s",
            "--notes",
            "filed by `chump swe` (INFRA-2089) — synthetic one-shot SWE-agent gap",
        ])
        .current_dir(repo_path::repo_root())
        .output()
        .map_err(|e| format!("failed to spawn `chump gap reserve`: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "chump gap reserve failed (exit {:?}): {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if id.is_empty() {
        return Err("chump gap reserve returned an empty gap id".to_string());
    }
    Ok(id)
}

/// Emit `kind=swe_invocation_complete` to ambient.jsonl (INFRA-2089).
/// # scanner-anchor: "kind":"swe_invocation_complete"
#[allow(clippy::too_many_arguments)]
fn emit_swe_invocation_complete(
    gap_id: &str,
    prompt: &str,
    outcome: &str,
    detail: &str,
    budget_secs: u64,
    budget_tokens: Option<u64>,
    budget_dollars: Option<f64>,
) {
    let repo_root = repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let prompt_escaped = prompt.replace('\\', "\\\\").replace('"', "\\\"");
    let detail_escaped = detail.replace('\\', "\\\\").replace('"', "\\\"");
    let budget_tokens_field = budget_tokens
        .map(|v| v.to_string())
        .unwrap_or_else(|| "null".to_string());
    let budget_dollars_field = budget_dollars
        .map(|v| v.to_string())
        .unwrap_or_else(|| "null".to_string());

    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\
         \"event\":\"swe_invocation_complete\",\"kind\":\"swe_invocation_complete\",\
         \"gap\":\"{gap_id}\",\"outcome\":\"{outcome}\",\"detail\":\"{detail_escaped}\",\
         \"prompt\":\"{prompt_escaped}\",\"budget_secs\":{budget_secs},\
         \"budget_tokens\":{budget_tokens_field},\"budget_dollars\":{budget_dollars_field}}}"
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

pub fn run(args: &[String]) -> i32 {
    let parsed = match parse_args(args) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };

    if parsed.dry_run_diff {
        println!("[swe] dry-run — would reserve+claim a synthetic gap and dispatch under budget:");
        println!("  title:           {}", title_from_prompt(&parsed.prompt));
        println!("  prompt:          {}", parsed.prompt);
        println!("  budget_secs:     {}", parsed.budget_secs);
        if let Some(t) = parsed.budget_tokens {
            println!("  budget_tokens:   {t} (advisory)");
        }
        if let Some(d) = parsed.budget_dollars {
            println!("  budget_dollars:  {d} (advisory)");
        }
        if let Some(p) = &parsed.paths {
            println!("  paths:           {p}");
        }
        println!("  auto_merge:      true");
        return 0;
    }

    if let Some(tokens) = parsed.budget_tokens {
        eprintln!(
            "[swe] note: --budget-tokens={tokens} is advisory only — no per-call token metering \
             hook exists at the dispatch layer today; --budget-secs is the enforced budget."
        );
    }
    if let Some(dollars) = parsed.budget_dollars {
        eprintln!(
            "[swe] note: --budget-dollars={dollars} is advisory only — no per-call cost metering \
             hook exists at the dispatch layer today; --budget-secs is the enforced budget."
        );
    }

    let gap_id = match reserve_gap(&parsed.prompt) {
        Ok(id) => id,
        Err(e) => {
            eprintln!("[swe] reserve failed: {e}");
            emit_swe_invocation_complete(
                "",
                &parsed.prompt,
                "failed",
                &e,
                parsed.budget_secs,
                parsed.budget_tokens,
                parsed.budget_dollars,
            );
            return 1;
        }
    };
    println!("[swe] reserved {gap_id}");

    // Read by crate::dispatch::spawn_headless's parent-side watchdog:
    // SIGTERM at budget_secs, SIGKILL 30s later. Emits
    // kind=subagent_killed_at_budget on its own if it fires.
    std::env::set_var("CHUMP_SUBAGENT_BUDGET_S", parsed.budget_secs.to_string());

    let repo_root = repo_path::repo_root();
    let opts = DispatchOptions {
        gap_id: &gap_id,
        work: WorkBackend::Headless {
            model: String::new(),
            prompt: parsed.prompt.clone(),
        },
        auto_merge: true,
        skip_tests: false,
        paths: parsed.paths.as_deref(),
        repo_root,
        mode: DispatchMode::Work,
    };

    let (outcome, detail, exit_code) = match dispatch::run(opts) {
        Ok(out) => match out.result {
            ShipResult::Shipped { pr_number } => {
                println!("[swe] shipped PR #{pr_number} for {gap_id} (auto-merge armed)");
                ("success".to_string(), format!("pr={pr_number}"), 0)
            }
            // CREDIBLE-1506: armed+pending is a success — the PR lands on green CI.
            ShipResult::Armed { pr_number } => {
                println!("[swe] armed PR #{pr_number} for {gap_id} — auto-merge pending");
                ("success".to_string(), format!("pr={pr_number}"), 0)
            }
            ShipResult::Blocked { reason } => {
                eprintln!("[swe] blocked: {reason}");
                let kind = if reason.contains("budget") || reason.contains("killed") {
                    "killed_at_budget"
                } else {
                    "failed"
                };
                (kind.to_string(), reason, 1)
            }
            ShipResult::Aborted { error } => {
                eprintln!("[swe] aborted: {error}");
                let kind = if error.contains("budget")
                    || error.contains("SIGKILL")
                    || error.contains("killed")
                {
                    "killed_at_budget"
                } else {
                    "failed"
                };
                (kind.to_string(), error, 1)
            }
        },
        Err(e) => {
            eprintln!("[swe] dispatch error: {e:#}");
            ("failed".to_string(), format!("{e:#}"), 1)
        }
    };

    emit_swe_invocation_complete(
        &gap_id,
        &parsed.prompt,
        &outcome,
        &detail,
        parsed.budget_secs,
        parsed.budget_tokens,
        parsed.budget_dollars,
    );

    exit_code
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_bare_prompt() {
        let a = args(&["swe", "fix the flaky test"]);
        let parsed = parse_args(&a).unwrap();
        assert_eq!(parsed.prompt, "fix the flaky test");
        assert_eq!(parsed.budget_secs, DEFAULT_BUDGET_SECS);
        assert!(parsed.budget_tokens.is_none());
        assert!(parsed.budget_dollars.is_none());
        assert!(parsed.paths.is_none());
        assert!(!parsed.dry_run_diff);
    }

    #[test]
    fn parses_all_flags() {
        let a = args(&[
            "swe",
            "add a retry loop",
            "--budget-secs",
            "600",
            "--budget-tokens",
            "50000",
            "--budget-dollars",
            "2.5",
            "--paths",
            "src/foo.rs,src/bar.rs",
            "--dry-run-diff",
        ]);
        let parsed = parse_args(&a).unwrap();
        assert_eq!(parsed.prompt, "add a retry loop");
        assert_eq!(parsed.budget_secs, 600);
        assert_eq!(parsed.budget_tokens, Some(50_000));
        assert_eq!(parsed.budget_dollars, Some(2.5));
        assert_eq!(parsed.paths.as_deref(), Some("src/foo.rs,src/bar.rs"));
        assert!(parsed.dry_run_diff);
    }

    #[test]
    fn rejects_missing_prompt() {
        let a = args(&["swe", "--budget-secs", "60"]);
        assert!(parse_args(&a).is_err());
    }

    #[test]
    fn rejects_empty_prompt() {
        let a = args(&["swe", "   "]);
        assert!(parse_args(&a).is_err());
    }

    #[test]
    fn rejects_two_positional_args() {
        let a = args(&["swe", "do this", "and this"]);
        assert!(parse_args(&a).is_err());
    }

    #[test]
    fn rejects_unknown_flag() {
        let a = args(&["swe", "do this", "--bogus"]);
        assert!(parse_args(&a).is_err());
    }

    #[test]
    fn title_from_prompt_truncates_long_prompts() {
        let long = "x".repeat(200);
        let title = title_from_prompt(&long);
        assert!(title.starts_with("swe: "));
        assert!(title.ends_with('…'));
        assert!(title.chars().count() < long.chars().count());
    }

    #[test]
    fn title_from_prompt_collapses_whitespace() {
        let title = title_from_prompt("fix   the   bug\nplease");
        assert_eq!(title, "swe: fix the bug please");
    }
}
