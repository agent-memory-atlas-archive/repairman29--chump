//! CLI/exec tool for Chump: run shell commands with timeout and output cap.
//! **Host shell (host-trust):** not sandboxed like WASM; see `docs/operations/TOOL_APPROVAL.md` trust ladder.
//! For private Chump: always on in Discord; no allowlist by default (any command).
//! Set CHUMP_CLI_ALLOWLIST to restrict; set CHUMP_CLI_BLOCKLIST to forbid.
//! Heuristic risk is computed for logging and (when approval is enabled) for the approval UI.

use crate::chump_log;
use crate::precision_controller;
use crate::repo_path;
use crate::tool_health_db;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::time::Duration;

/// Risk level from heuristic inspection of a command (for logging and approval UI).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CliRiskLevel {
    Low,
    Medium,
    High,
}

impl CliRiskLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            CliRiskLevel::Low => "low",
            CliRiskLevel::Medium => "medium",
            CliRiskLevel::High => "high",
        }
    }
}

/// Heuristic risk for a shell command. Returns (level, short reason).
/// Used for logging and for approval payload when CHUMP_TOOLS_ASK includes run_cli.
pub fn heuristic_risk(command: &str) -> (CliRiskLevel, String) {
    let c = command.trim();
    let lower = c.to_lowercase();
    // Destructive / system-wide
    if lower.contains("rm -rf /") || lower == "rm -rf /" {
        return (
            CliRiskLevel::High,
            "destructive: rm -rf on root".to_string(),
        );
    }
    // Forbidden: do not delete clone dirs under repos/ (agent must not nuke product repos)
    if lower.contains("rm ") && (lower.contains("repos/") || lower.contains("repos ")) {
        return (
            CliRiskLevel::High,
            "forbidden: do not delete clone dirs under repos/".to_string(),
        );
    }
    if lower.contains("mkfs.") || lower.contains("dd if=") {
        return (CliRiskLevel::High, "disk/block device write".to_string());
    }
    if lower.contains("> /dev/sd") || lower.contains(">/dev/sd") {
        return (
            CliRiskLevel::High,
            "direct write to block device".to_string(),
        );
    }
    // Privilege escalation
    if lower.starts_with("sudo ") || lower.contains(" sudo ") {
        return (
            CliRiskLevel::High,
            "privilege escalation (sudo)".to_string(),
        );
    }
    // Database destructive
    if lower.contains("drop table") || lower.contains("drop database") {
        return (
            CliRiskLevel::High,
            "destructive SQL (drop table/database)".to_string(),
        );
    }
    // Permissions
    if lower.contains("chmod 777") || lower.contains("chmod 777 ") {
        return (CliRiskLevel::Medium, "permissive chmod (777)".to_string());
    }
    // Credential-like args (simple pattern)
    if lower.contains("password=") || lower.contains("--password") || lower.contains("api_key=") {
        return (
            CliRiskLevel::Medium,
            "command may contain credentials".to_string(),
        );
    }
    // Moderate risk: rm -rf on paths (not root)
    if lower.contains("rm -rf") || lower.contains("rm -fr ") {
        return (
            CliRiskLevel::Medium,
            "recursive delete (rm -rf)".to_string(),
        );
    }
    (CliRiskLevel::Low, "no high-risk pattern".to_string())
}

const DEFAULT_TIMEOUT_SECS: u64 = 60;
const MAX_OUTPUT_CHARS: usize = 2500;
const EXECUTIVE_DEFAULT_TIMEOUT_SECS: u64 = 300;
const EXECUTIVE_DEFAULT_MAX_OUTPUT_CHARS: usize = 50_000;

pub struct CliTool {
    /// If empty, any command is allowed. Otherwise only these (lowercase) executables.
    allowlist: Vec<String>,
    /// Commands (lowercase) to never run, e.g. dangerous defaults.
    blocklist: Vec<String>,
    timeout_secs: u64,
    max_output: usize,
}

impl CliTool {
    /// Test helper: build with explicit allowlist and blocklist (default timeout and output cap).
    #[allow(dead_code)]
    pub fn with_allowlist_blocklist(allowlist: Vec<String>, blocklist: Vec<String>) -> Self {
        Self {
            allowlist,
            blocklist,
            timeout_secs: DEFAULT_TIMEOUT_SECS,
            max_output: MAX_OUTPUT_CHARS,
        }
    }

    /// Build for Discord: always enabled. Unset CHUMP_CLI_ALLOWLIST = any command; set it = allowlist only. Optional blocklist.
    pub fn for_discord() -> Self {
        let allowlist: Vec<String> = std::env::var("CHUMP_CLI_ALLOWLIST")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|x| x.trim().to_lowercase())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let blocklist: Vec<String> = std::env::var("CHUMP_CLI_BLOCKLIST")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|x| x.trim().to_lowercase())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let timeout_secs = std::env::var("CHUMP_CLI_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_TIMEOUT_SECS);
        Self {
            allowlist,
            blocklist,
            timeout_secs,
            max_output: MAX_OUTPUT_CHARS,
        }
    }

    fn allowed(&self, base: &str) -> bool {
        let b = base.to_lowercase();
        if self.blocklist.contains(&b) {
            return false;
        }
        self.allowlist.is_empty() || self.allowlist.contains(&b)
    }
}

/// True when CHUMP_EXECUTIVE_MODE=1 or "true". Full exec: no allowlist/blocklist, higher timeout/cap. Audit in chump.log.
fn executive_mode() -> bool {
    std::env::var("CHUMP_EXECUTIVE_MODE")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn executive_timeout_secs() -> u64 {
    std::env::var("CHUMP_EXECUTIVE_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=3600).contains(&n))
        .unwrap_or(EXECUTIVE_DEFAULT_TIMEOUT_SECS)
}

fn executive_max_output_chars() -> usize {
    std::env::var("CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1000..=1_000_000).contains(&n))
        .unwrap_or(EXECUTIVE_DEFAULT_MAX_OUTPUT_CHARS)
}

#[async_trait]
impl Tool for CliTool {
    fn name(&self) -> String {
        "run_cli".to_string()
    }

    fn description(&self) -> String {
        "Run a shell command. Pass 'command' as the full command string (e.g. 'ls -la', 'cat README.md', 'git status'). Run one command per call.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Full shell command (e.g. ls -la, cat README.md, git status)"
                }
            },
            "required": ["command"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        self.run(input).await
    }
}

impl CliTool {
    /// Shared execution so alias tools (git, cargo) can delegate here.
    pub async fn run(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        // Accept "command", "cmd", "content", "shell", "script", or first string in object; or top-level string.
        let cmd = input
            .get("command")
            .or_else(|| input.get("cmd"))
            .or_else(|| input.get("shell"))
            .or_else(|| input.get("script"))
            .and_then(|c| c.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let cmd = cmd.or_else(|| {
            let mut c = input
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim();
            if c.starts_with("run ") {
                c = c.strip_prefix("run ").unwrap_or(c).trim();
            }
            if !c.is_empty()
                && !c.contains("\"action\"")
                && (c.starts_with("cargo")
                    || c.starts_with("git")
                    || c.starts_with("ls")
                    || c.starts_with("cat")
                    || c.starts_with("pwd")
                    || c.starts_with("sh ")
                    || c.contains(" "))
            {
                Some(c.to_string())
            } else {
                None
            }
        });
        // Fallback: entire input is a string (some APIs send raw string)
        let cmd = cmd.or_else(|| {
            input
                .as_str()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        });
        // Fallback: first string value in object (model sent e.g. {"file": "path"} or {"args": "cmd"})
        let cmd = cmd.or_else(|| {
            input.as_object().and_then(|o| {
                for (k, v) in o {
                    if k == "action" || k == "parameters" {
                        continue;
                    }
                    if let Some(s) = v.as_str() {
                        let s = s.trim();
                        if !s.is_empty()
                            && s.len() < 2000
                            && (s.contains(' ')
                                || s.starts_with("cargo")
                                || s.starts_with("git")
                                || s.starts_with("cat")
                                || s.starts_with("ls")
                                || s.contains('/'))
                        {
                            return Some(s.to_string());
                        }
                    }
                }
                None
            })
        });
        let cmd = cmd.ok_or_else(|| {
            anyhow!("missing command (use command, cmd, or content with a shell command)")
        })?;
        let cmd = cmd.trim().to_string();
        if cmd.is_empty() {
            return Err(anyhow!("empty command"));
        }
        let (risk_level, risk_reason) = heuristic_risk(&cmd);
        let preview = if cmd.len() > 80 {
            format!("{}...", &cmd[..80])
        } else {
            cmd.clone()
        };
        tracing::info!(
            command_preview = %preview,
            risk = risk_level.as_str(),
            reason = %risk_reason,
            "run_cli heuristic_risk"
        );
        // Block forbidden patterns (e.g. deleting clone dirs under repos/)
        if risk_reason.contains("forbidden: do not delete clone dirs") {
            return Err(anyhow!(
                "run_cli blocked: {}. To recover a broken clone, the user must run 'rm -rf repos/owner_name' manually (replace with the repo dir you need removed), then you can github_clone_or_pull again.",
                risk_reason
            ));
        }
        let executive = executive_mode();
        // Allowlist/blocklist: skip when executive (full host authority for testing/self-improve).
        if !executive {
            let base = cmd.split_ascii_whitespace().next().unwrap_or(&cmd);
            if !self.allowed(base) {
                return Err(anyhow!(
                    "command not allowed: {} (blocklisted or not in allowlist)",
                    base
                ));
            }
        }

        // RESILIENT-1427: Check admission for cargo build-related commands (agent builds).
        // Inspect the command to see if it's a cargo build/check/test/install and enforce
        // the concurrency ceiling if so.
        let is_cargo_build = cmd.starts_with("cargo ")
            && (cmd.contains("build")
                || cmd.contains("check")
                || cmd.contains("test")
                || cmd.contains("install"));
        if is_cargo_build {
            let max_concurrent = crate::admission_check::get_max_concurrent_cargo_jobs();
            if let Err(e) = crate::admission_check::check_admission(max_concurrent) {
                return Err(anyhow!("cargo job admission check failed: {}", e));
            }
            // Insert job entry to track this cargo job (status: pending initially).
            let _ = crate::admission_check::insert_cargo_job("pending", Some(&cmd));
            // Mark as running immediately before execution.
            let _ = crate::job_log::mark_running("cargo_job");
        }

        let (timeout_secs, max_output) = if executive {
            (executive_timeout_secs(), executive_max_output_chars())
        } else {
            (self.timeout_secs, self.max_output)
        };

        // Resolve cwd once — used by both the ACP delegation path (as a String)
        // and the local-execution path (as a PathBuf).
        let real_cwd = if repo_path::has_working_repo_override() {
            repo_path::repo_root()
        } else {
            std::env::var("CHUMP_REPO")
                .or_else(|_| std::env::var("CHUMP_HOME"))
                .ok()
                .and_then(|p| {
                    let path = std::path::PathBuf::from(p.trim());
                    if path.is_dir() {
                        Some(path)
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| {
                    std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
                })
        };

        // INFRA-001b: if a speculative sandbox is active, redirect the working
        // directory so shell commands write into the isolated worktree rather
        // than the real repo. The sandbox root is the same layout as the repo,
        // so relative paths inside commands still resolve correctly.
        let cwd_path = crate::speculative_execution::speculative_sandbox_root()
            .filter(|_| crate::speculative_execution::sandbox_speculation_enabled())
            .inspect(|sandbox| {
                tracing::debug!(
                    sandbox = %sandbox.display(),
                    cmd = %cmd,
                    "INFRA-001b: cli_tool redirecting to speculative sandbox"
                );
            })
            .unwrap_or(real_cwd);

        // ACP delegation: when Chump runs under an ACP client that declared
        // terminal capability, spawn the command in the editor's environment
        // instead of locally. Skip this fast-path for non-ACP launches and
        // clients that didn't declare terminal support.
        let cwd_str = cwd_path.to_string_lossy().to_string();
        if let Some(acp_result) = crate::acp_server::acp_maybe_run_shell_cmd(
            &cmd,
            Some(cwd_str),
            timeout_secs,
            max_output,
        )
        .await
        {
            return acp_result.map(|r| {
                let exit_code = r.exit_code;
                chump_log::log_cli_with_executive(&cmd, &[], exit_code, r.output.len(), executive);
                if exit_code == Some(127) && tool_health_db::tool_health_available() {
                    let tool_name = cmd.split_whitespace().next().unwrap_or("run_cli");
                    let _ = tool_health_db::record_failure(
                        tool_name,
                        "unavailable",
                        Some(r.output.as_str()),
                    );
                }
                if precision_controller::battle_benchmark_env_on() {
                    format!("{}\n[exit status: {}]", r.output, exit_code.unwrap_or(-1))
                } else {
                    r.output
                }
            });
        }

        // Local execution path: route through the sandbox module which,
        // under CHUMP_AGENT_SANDBOX=1, wraps the command in macOS
        // sandbox-exec with a worktree-pinned profile (INFRA-1454).
        // Default-off in v1 so the pilot ships without disturbing existing
        // flows; the sandbox-exec path returns the same shape of Command
        // when disabled or unsupported.
        let mut c = crate::sandbox::wrap_command(&cmd, &cwd_path);

        let output = tokio::time::timeout(Duration::from_secs(timeout_secs), c.output())
            .await
            .map_err(|_| anyhow!("command timed out after {}s", timeout_secs))??;

        let mut out = String::new();
        if !output.stdout.is_empty() {
            out.push_str(&String::from_utf8_lossy(&output.stdout));
        }
        if !output.stderr.is_empty() {
            if !out.is_empty() {
                out.push_str("\nstderr:\n");
            }
            out.push_str(&String::from_utf8_lossy(&output.stderr));
        }
        if out.is_empty() {
            out = format!("exit code {}", output.status.code().unwrap_or(-1));
        }
        if out.chars().count() > max_output {
            const KEEP_FIRST: usize = 1000;
            const KEEP_LAST: usize = 2000;
            let n = out.chars().count();
            if n > KEEP_FIRST + KEEP_LAST {
                let first: String = out.chars().take(KEEP_FIRST).collect();
                let last: String = out.chars().skip(n.saturating_sub(KEEP_LAST)).collect();
                let trimmed = n - KEEP_FIRST - KEEP_LAST;
                out = format!("{}\n[... {} chars trimmed ...]\n{}", first, trimmed, last);
            } else {
                out = out.chars().take(max_output).collect::<String>();
            }
        }
        let exit_code = output.status.code();
        chump_log::log_cli_with_executive(&cmd, &[], exit_code, out.len(), executive);

        // RESILIENT-1427: Mark cargo job as completed or failed based on exit code.
        if is_cargo_build {
            if exit_code == Some(0) {
                let _ = crate::job_log::mark_completed("cargo_job");
            } else {
                let error_msg = format!("exit code: {:?}", exit_code);
                let _ = crate::job_log::mark_failed("cargo_job", &error_msg);
            }
        }

        // Exit 127 = command not found; record so assemble_context can warn
        if exit_code == Some(127) && tool_health_db::tool_health_available() {
            let tool_name = cmd.split_whitespace().next().unwrap_or("run_cli");
            let _ = tool_health_db::record_failure(tool_name, "unavailable", Some(out.as_str()));
        }
        if precision_controller::battle_benchmark_env_on() {
            use std::fmt::Write as _;
            let _ = writeln!(out, "\n[exit status: {}]", exit_code.unwrap_or(-1));
        }
        Ok(out)
    }
}

/// Alias so when the model calls "git" or "cargo" we still run the command via run_cli logic.
pub struct CliToolAlias {
    pub name: String,
    pub inner: CliTool,
}

#[async_trait]
impl Tool for CliToolAlias {
    fn name(&self) -> String {
        self.name.clone()
    }
    fn description(&self) -> String {
        format!("Run a {} command (same as run_cli). Pass 'command' or 'content' with the full shell command.", self.name)
    }
    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }
    async fn execute(&self, input: Value) -> Result<String> {
        // When model sends git/cargo with wrong shape (e.g. {"command": "main"}), fix up so we run "git main" or "cargo main"
        let input = normalize_alias_input(&self.name, input);
        self.inner.run(input).await
    }
}

fn normalize_alias_input(tool_name: &str, input: Value) -> Value {
    let cmd_str = input
        .get("command")
        .or_else(|| input.get("cmd"))
        .and_then(|c| c.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let content_str = input
        .get("content")
        .and_then(|c| c.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    // If content is already a full command (git/cargo ...), use as-is
    if let Some(ref c) = content_str {
        if c.starts_with("git ") || c.starts_with("cargo ") || c.starts_with("run ") {
            return serde_json::json!({ "command": c.clone() });
        }
    }
    // If we have a command that's just one word (e.g. "main", "status"), treat as subcommand: "git main" / "cargo build"
    if let Some(ref c) = cmd_str {
        if !c.contains(' ') && c.len() < 80 {
            return serde_json::json!({ "command": format!("{} {}", tool_name, c) });
        }
        if !c.starts_with("git ") && !c.starts_with("cargo ") {
            return serde_json::json!({ "command": format!("{} {}", tool_name, c) });
        }
        return serde_json::json!({ "command": c.clone() });
    }
    // No command/cmd; build from first string param
    if let Some(obj) = input.as_object() {
        for (k, v) in obj {
            if k == "action" || k == "parameters" {
                continue;
            }
            if let Some(s) = v.as_str() {
                let s = s.trim();
                if !s.is_empty() && s.len() < 200 {
                    return serde_json::json!({ "command": format!("{} {}", tool_name, s) });
                }
            }
        }
    }
    input
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn run_blocked_command_returns_error() {
        let tool = CliTool::with_allowlist_blocklist(vec![], vec!["rm".into()]);
        let out = tool.run(json!({ "command": "rm -rf /nonexistent" })).await;
        assert!(out.is_err());
        let err = out.unwrap_err().to_string();
        assert!(err.contains("not allowed") || err.contains("blocklist"));
    }

    #[tokio::test]
    async fn run_rm_repos_blocked() {
        let tool = CliTool::with_allowlist_blocklist(vec![], vec![]);
        let out = tool
            .run(json!({ "command": "rm -rf repos/repairman29_chump-chassis" }))
            .await;
        assert!(out.is_err(), "rm -rf repos/ must be blocked");
        let err = out.unwrap_err().to_string();
        assert!(err.contains("blocked") || err.contains("forbidden") || err.contains("repos"));
    }

    #[tokio::test]
    async fn run_empty_allowlist_allows_safe_command() {
        let tool = CliTool::with_allowlist_blocklist(vec![], vec![]);
        let out = tool.run(json!({ "command": "echo ok" })).await;
        assert!(out.is_ok());
        assert!(out.unwrap().contains("ok"));
    }

    #[tokio::test]
    async fn run_allowlist_only_listed() {
        let tool = CliTool::with_allowlist_blocklist(vec!["echo".into()], vec![]);
        let out = tool.run(json!({ "command": "echo allowed" })).await;
        assert!(out.is_ok());
        assert!(out.unwrap().contains("allowed"));
        let out = tool.run(json!({ "command": "cat /dev/null" })).await;
        assert!(out.is_err());
    }

    /// Golden-path checklist: `rm` is not in a tight dev allowlist (cargo, git, rg, ls, cat, head, wc).
    #[tokio::test]
    async fn run_rm_rf_root_rejected_by_tight_allowlist() {
        let tool = CliTool::with_allowlist_blocklist(
            vec![
                "cargo".into(),
                "git".into(),
                "rg".into(),
                "ls".into(),
                "cat".into(),
                "head".into(),
                "wc".into(),
            ],
            vec![],
        );
        let out = tool.run(json!({ "command": "rm -rf /" })).await;
        assert!(out.is_err());
        let err = out.unwrap_err().to_string();
        assert!(
            err.contains("not allowed") && err.contains("rm"),
            "expected allowlist rejection for rm, got: {err}"
        );
    }
}
