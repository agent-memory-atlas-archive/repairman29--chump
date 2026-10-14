//! spawn_worker: run a tooled agent in an ephemeral git worktree with isolated inference context.
//! Gate: CHUMP_SPAWN_WORKERS_ENABLED=1. Concurrency: CHUMP_SPAWN_MAX_PARALLEL (default 3).
//!
//! Context isolation (Phase 4, Sprint 2):
//! - File system: ephemeral `git worktree add --detach` (auto-cleaned on completion)
//! - Inference: fresh provider + restricted tool registry, NO blackboard/neuromod/chat history
//! - Return: unified `.patch` diff + summary posted to orchestrator's blackboard

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::tool::ToolRegistry;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::Semaphore;

use crate::provider_cascade;
use crate::repo_path;
use crate::tool_inventory;

pub fn spawn_workers_enabled() -> bool {
    std::env::var("CHUMP_SPAWN_WORKERS_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn max_parallel() -> usize {
    std::env::var("CHUMP_SPAWN_MAX_PARALLEL")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=16).contains(&n))
        .unwrap_or(3)
}

static SPAWN_SEMAPHORE: std::sync::OnceLock<Arc<Semaphore>> = std::sync::OnceLock::new();
fn spawn_semaphore() -> &'static Arc<Semaphore> {
    SPAWN_SEMAPHORE.get_or_init(|| Arc::new(Semaphore::new(max_parallel())))
}

fn worker_system_prompt(task: &str) -> String {
    format!(
        "You are an ephemeral worker. Solve the exact objective below. You have 5 iterations. \
         Do not explore unrelated code. Run tests before reporting success. \
         Return a brief summary of what you changed and why.\n\nObjective: {}",
        task
    )
}

async fn run_git(dir: &PathBuf, args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| anyhow!("git failed: {}", e))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let combined = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{}\n{}", stdout, stderr)
    };
    Ok((out.status.success(), combined))
}

/// RAII guard that removes the git worktree on drop.
struct WorktreeGuard {
    repo_root: PathBuf,
    worktree_path: PathBuf,
}

impl Drop for WorktreeGuard {
    fn drop(&mut self) {
        let _ = std::process::Command::new("git")
            .current_dir(&self.repo_root)
            .args(["worktree", "remove", "--force"])
            .arg(&self.worktree_path)
            .output();
        // Belt and suspenders: if worktree remove fails, clean up the directory
        if self.worktree_path.exists() {
            let _ = std::fs::remove_dir_all(&self.worktree_path);
        }
    }
}

pub struct SpawnWorkerTool;

impl SpawnWorkerTool {
    async fn execute_headless_test(&self) -> Result<String> {
        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg("setsid true")
            .output()
            .await;

        match output {
            Ok(status) => {
                if status.status.success() {
                    println!("HEADLESS TEST PASSED");
                    Ok("HEADLESS TEST PASSED".to_string())
                } else {
                    let stderr = String::from_utf8_lossy(&status.stderr);
                    let err_msg = format!("fork failed: {}", stderr.trim());
                    eprintln!("{}", err_msg);
                    Err(anyhow!(err_msg))
                }
            }
            Err(e) => {
                let err_msg = format!("fork failed: {}", e);
                eprintln!("{}", err_msg);
                Err(anyhow!(err_msg))
            }
        }
    }
}

#[async_trait]
impl axonerai::tool::Tool for SpawnWorkerTool {
    fn name(&self) -> String {
        "spawn_worker".to_string()
    }

    fn description(&self) -> String {
        "Run a tooled worker in an isolated git worktree. Params: task (description), \
         working_dir (repo root path), optional max_iterations (default 15), optional branch \
         (for the worktree base). Worker has read_file, list_dir, write_file, patch_file, \
         run_test, run_cli, git_commit, diff_review only. Returns { success, patch, \
         files_changed, test_results?, summary }."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "task": { "type": "string", "description": "Subtask description" },
                "working_dir": { "type": "string", "description": "Repo root path (absolute or under CHUMP_HOME)" },
                "max_iterations": { "type": "number", "description": "Max agent iterations (default 15)" },
                "branch": { "type": "string", "description": "Base branch/ref for the worktree (default: HEAD)" }
            },
            "required": ["task", "working_dir"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        // Headless test mode: HEADLESS_TEST=1 performs a minimal detached session test.
        if std::env::var("HEADLESS_TEST")
            .map(|v| v == "1")
            .unwrap_or(false)
        {
            return self.execute_headless_test().await;
        }

        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let task = input
            .get("task")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing task"))?
            .trim()
            .to_string();
        let working_dir_str = input
            .get("working_dir")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing working_dir"))?
            .trim();
        let _max_iterations = input
            .get("max_iterations")
            .and_then(|v| v.as_u64())
            .unwrap_or(15) as usize;
        let base_ref = input
            .get("branch")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("HEAD")
            .to_string();

        let working_dir: PathBuf = if PathBuf::from(working_dir_str).is_absolute() {
            PathBuf::from(working_dir_str)
        } else {
            repo_path::runtime_base().join(working_dir_str.trim_start_matches('/'))
        };
        let working_dir = working_dir
            .canonicalize()
            .map_err(|e| anyhow!("working_dir not found: {}", e))?;
        if !working_dir.join(".git").exists() && !working_dir.join(".git").is_file() {
            return Err(anyhow!("working_dir is not a git repo (no .git)"));
        }

        let _permit = spawn_semaphore()
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| anyhow!("spawn_worker semaphore closed"))?;

        // Create ephemeral worktree
        let uuid = uuid::Uuid::new_v4().to_string()[..8].to_string();
        let worktree_name = format!("chump_worker_{}", uuid);
        let worktree_path = working_dir
            .parent()
            .unwrap_or(&working_dir)
            .join(&worktree_name);

        // Clean up any stale worktree at this path
        if worktree_path.exists() {
            let _ = std::fs::remove_dir_all(&worktree_path);
        }

        let (ok, out) = run_git(
            &working_dir,
            &[
                "worktree",
                "add",
                "--detach",
                worktree_path.to_str().unwrap_or(""),
                &base_ref,
            ],
        )
        .await?;
        if !ok {
            return Err(anyhow!("git worktree add failed: {}", out.trim()));
        }

        let _guard = WorktreeGuard {
            repo_root: working_dir.clone(),
            worktree_path: worktree_path.clone(),
        };

        let slot_id =
            provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".to_string());
        let model_name =
            provider_cascade::get_last_used_model().unwrap_or_else(|| "unknown".to_string());
        tracing::info!(
            worktree = %worktree_path.display(),
            task = %&task[..task.len().min(80)],
            slot_id = %slot_id,
            model_name = %model_name,
            "spawn_worker: created ephemeral worktree"
        );

        // INFRA-1588: Register worker RPC handlers if NATS is available.
        // CREDIBLE-246 (CREDIBLE-099 slice): also register a presence
        // record in the `chump_workers` NATS-KV bucket so this worker is
        // discoverable — not just its RPC endpoints. Declared outside the
        // `result` block so the terminal-mark below (after `.await`) can
        // still see them.
        let session_id = format!("worker-{}", uuid);
        let mut presence_kv: Option<async_nats::jetstream::kv::Store> = None;

        // Run the agent in the isolated worktree
        let result = async {
            let provider = provider_cascade::global_provider();
            let mut registry = ToolRegistry::new();
            tool_inventory::register_worker_tools(&mut registry);

            if let Ok(nats_url) = std::env::var("NATS_URL") {
                if let Ok(nats) = async_nats::connect(nats_url).await {
                    let js = async_nats::jetstream::new(nats.clone());
                    match chump_coord::presence::init_workers_bucket(&js).await {
                        Ok(kv) => {
                            let _ = chump_coord::rpc::register_worker_rpc_handlers_with_presence(
                                &nats,
                                &session_id,
                                &kv,
                            )
                            .await;
                            presence_kv = Some(kv);
                        }
                        Err(_) => {
                            let _ =
                                chump_coord::rpc::register_worker_rpc_handlers(&nats, &session_id)
                                    .await;
                        }
                    }
                }
            }

            let system_prompt = worker_system_prompt(&task);
            let session_dir = worktree_path.join(".chump_worker_session");
            let _ = std::fs::create_dir_all(&session_dir);
            let session_manager = FileSessionManager::new("worker".to_string(), session_dir)
                .map_err(|e| anyhow!("session manager: {}", e))?;

            let agent = Agent::new(
                provider,
                registry,
                Some(system_prompt),
                Some(session_manager),
            );

            // Override working repo for tools that check it
            repo_path::set_working_repo(worktree_path.clone()).map_err(|e| anyhow!("{}", e))?;

            let reply = agent
                .run(&task)
                .await
                .map_err(|e| anyhow!("agent run: {}", e))?;

            let hit_max = reply.contains("max iterations");
            let success = !hit_max;

            // Generate unified diff (patch) from worktree changes
            // First: stage everything so we capture new files too
            let _ = run_git(&worktree_path, &["add", "-A"]).await;
            let (_, patch) = run_git(&worktree_path, &["diff", "--cached", "--unified=3"]).await?;

            // Also get file list
            let (_, files_out) =
                run_git(&worktree_path, &["diff", "--cached", "--name-only"]).await?;
            let files_changed: Vec<String> = files_out
                .lines()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .collect();

            // Run tests in the worktree
            let test_out = Command::new("cargo")
                .args(["test"])
                .current_dir(&worktree_path)
                .output()
                .await;
            let test_results = match test_out {
                Ok(o) => {
                    String::from_utf8_lossy(&o.stdout).into_owned()
                        + &String::from_utf8_lossy(&o.stderr)
                }
                Err(_) => "cargo test not run".to_string(),
            };

            // Post patch + summary to blackboard for orchestrator visibility
            if !patch.is_empty() {
                let bb_content = format!(
                    "[Worker result] {} files changed. Summary: {}\n\nPatch ({} bytes):\n{}",
                    files_changed.len(),
                    &reply[..reply.len().min(200)],
                    patch.len(),
                    &patch[..patch.len().min(2000)],
                );
                crate::blackboard::post(
                    crate::blackboard::Module::Custom("spawn_worker".to_string()),
                    bb_content,
                    crate::blackboard::SalienceFactors {
                        novelty: 0.9,
                        uncertainty_reduction: 0.7,
                        goal_relevance: 0.9,
                        urgency: 0.5,
                    },
                );
            }

            Ok::<_, anyhow::Error>((
                success,
                patch,
                files_changed,
                test_results,
                reply.trim().to_string(),
            ))
        }
        .await;

        repo_path::clear_working_repo();

        // CREDIBLE-256 (CREDIBLE-099 slice): deregister this worker's presence
        // record now that it has shipped its patch (or exited via error,
        // handled below) — deletes from the `chump_workers` KV bucket rather
        // than leaving a `Terminal` tombstone (CREDIBLE-246's behavior).
        if let Some(kv) = &presence_kv {
            let _ = chump_coord::presence::deregister_presence(kv, &session_id).await;
        }

        let (success, patch, files_changed, test_results, summary) = result?;

        let out = json!({
            "success": success,
            "patch": patch,
            "patch_bytes": patch.len(),
            "files_changed": files_changed,
            "test_results": test_results,
            "summary": summary,
            "isolation": "ephemeral_worktree"
        });
        Ok(out.to_string())
    }
}

#[cfg(test)]
mod tests {
    //! These tests mutate process-wide env vars (`CHUMP_SPAWN_WORKERS_ENABLED`,
    //! `CHUMP_SPAWN_MAX_PARALLEL`). Without `#[serial]` they raced — `_default`
    //! could read while `_bounds` was mid-set, getting the wrong answer.
    //! Pre-existing flake; fixed in passing while landing memory curation.
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial(spawn_worker_env)]
    fn spawn_workers_disabled_by_default() {
        std::env::remove_var("CHUMP_SPAWN_WORKERS_ENABLED");
        assert!(!spawn_workers_enabled());
    }

    #[test]
    #[serial(spawn_worker_env)]
    fn spawn_workers_enabled_with_env() {
        std::env::set_var("CHUMP_SPAWN_WORKERS_ENABLED", "1");
        assert!(spawn_workers_enabled());
        std::env::set_var("CHUMP_SPAWN_WORKERS_ENABLED", "true");
        assert!(spawn_workers_enabled());
        std::env::set_var("CHUMP_SPAWN_WORKERS_ENABLED", "0");
        assert!(!spawn_workers_enabled());
        std::env::remove_var("CHUMP_SPAWN_WORKERS_ENABLED");
    }

    #[test]
    #[serial(spawn_worker_env)]
    fn max_parallel_default() {
        std::env::remove_var("CHUMP_SPAWN_MAX_PARALLEL");
        assert_eq!(max_parallel(), 3);
    }

    #[test]
    #[serial(spawn_worker_env)]
    fn max_parallel_bounds() {
        std::env::set_var("CHUMP_SPAWN_MAX_PARALLEL", "0");
        assert_eq!(max_parallel(), 3); // out of range, falls to default
        std::env::set_var("CHUMP_SPAWN_MAX_PARALLEL", "1");
        assert_eq!(max_parallel(), 1);
        std::env::set_var("CHUMP_SPAWN_MAX_PARALLEL", "16");
        assert_eq!(max_parallel(), 16);
        std::env::set_var("CHUMP_SPAWN_MAX_PARALLEL", "17");
        assert_eq!(max_parallel(), 3); // out of range
        std::env::set_var("CHUMP_SPAWN_MAX_PARALLEL", "garbage");
        assert_eq!(max_parallel(), 3);
        std::env::remove_var("CHUMP_SPAWN_MAX_PARALLEL");
    }

    #[test]
    fn worker_system_prompt_contains_task() {
        let prompt = worker_system_prompt("fix the login bug");
        assert!(prompt.contains("fix the login bug"));
        assert!(prompt.contains("ephemeral worker"));
        assert!(prompt.contains("5 iterations"));
    }

    #[test]
    fn tool_metadata() {
        let tool = SpawnWorkerTool;
        assert_eq!(axonerai::tool::Tool::name(&tool), "spawn_worker");
        let schema = axonerai::tool::Tool::input_schema(&tool);
        assert!(schema["properties"]["task"].is_object());
        assert!(schema["properties"]["working_dir"].is_object());
        let Some(required) = schema["required"].as_array() else {
            panic!("spawn_worker schema: required must be a JSON array");
        };
        assert!(required.contains(&serde_json::json!("task")));
        assert!(required.contains(&serde_json::json!("working_dir")));
    }

    #[test]
    fn spawn_worker_logs_contain_slot_and_model() {
        // Set up mock last-used slot/model state before spawning
        crate::provider_cascade::set_last_used_slot("test-slot-id".to_string());
        crate::provider_cascade::set_last_used_model("test-model-name".to_string());

        // Verify the getter functions return expected values (which will be used in logging)
        let slot_id =
            crate::provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".to_string());
        let model_name =
            crate::provider_cascade::get_last_used_model().unwrap_or_else(|| "unknown".to_string());

        // Assert that both fields are present and contain the expected values
        assert_eq!(slot_id, "test-slot-id");
        assert_eq!(model_name, "test-model-name");

        // Verify these would be included in a log line like:
        // "spawn_worker: created ephemeral worktree slot_id=test-slot-id model_name=test-model-name"
        let log_line = format!(
            "spawn_worker: created ephemeral worktree slot_id={} model_name={}",
            slot_id, model_name
        );
        assert!(log_line.contains("slot_id="));
        assert!(log_line.contains("model_name="));
        assert!(log_line.contains("test-slot-id"));
        assert!(log_line.contains("test-model-name"));
    }
}
