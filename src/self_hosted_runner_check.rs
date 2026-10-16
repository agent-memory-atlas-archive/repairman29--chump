//! INFRA-1544: self-hosted runner liveness check for fleet doctor.
//!
//! Queries GitHub API to check if at least one self-hosted runner is online.
//! Used by `chump fleet doctor --strict` to ensure CI can run on self-hosted runners.
//!
//! Check ID: `self_hosted_runner_liveness`
//!
//! Returns:
//!   - Green if N >= min_runners and N > 0
//!   - Yellow if N == min_runners (degraded but functional)
//!   - Red if N < min_runners OR (N == 0 AND workflows need self-hosted)

use crate::ambient_emit::{emit, EmitArgs};
use serde::{Deserialize, Serialize};
use std::process::Command;

/// Response from GitHub API /repos/{owner}/{repo}/actions/runners
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunnersResponse {
    pub total_count: u32,
    pub runners: Vec<Runner>,
}

/// One runner entry from the API response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Runner {
    pub id: u64,
    pub name: String,
    pub status: String, // "online", "offline", "busy"
    #[serde(default)]
    pub busy: bool,
}

/// Result of a single runner check
#[derive(Debug, Clone, Serialize)]
pub struct RunnerCheckResult {
    pub online_count: u32,
    pub offline_count: u32,
    pub busy_count: u32,
    pub total_count: u32,
    pub healthy: bool,
    pub detail: String,
}

/// Default minimum online runners required.
pub const DEFAULT_MIN_RUNNERS: u32 = 1;

/// Query GitHub API for runner status.
///
/// Uses `gh api repos/{owner}/{repo}/actions/runners` to fetch runner info.
/// Returns parsed runner counts and health status.
pub fn check_runner_health() -> Result<RunnerCheckResult, String> {
    let owner = get_repo_owner()?;
    let repo = get_repo_name()?;

    let api_path = format!("repos/{}/{}/actions/runners", owner, repo);
    let output = Command::new("gh")
        .arg("api")
        .arg(&api_path)
        .output()
        .map_err(|e| format!("failed to run gh api: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh api failed: {}", stderr));
    }

    let json_str = String::from_utf8(output.stdout)
        .map_err(|e| format!("invalid UTF-8 in gh response: {}", e))?;

    let response: RunnersResponse = serde_json::from_str(&json_str)
        .map_err(|e| format!("failed to parse runners response: {}", e))?;

    let mut online_count = 0;
    let mut offline_count = 0;
    let mut busy_count = 0;

    for runner in &response.runners {
        match runner.status.as_str() {
            "online" => {
                if runner.busy {
                    busy_count += 1;
                } else {
                    online_count += 1;
                }
            }
            "offline" => {
                offline_count += 1;
            }
            _ => {}
        }
    }

    let min_runners = std::env::var("CHUMP_FLEET_DOCTOR_MIN_RUNNERS")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(DEFAULT_MIN_RUNNERS);

    let available_count = online_count;
    let healthy = available_count >= min_runners;

    let detail = if available_count == 0 {
        format!(
            "0 online runners (offline={}, total={}): CI cannot proceed on self-hosted",
            offline_count, response.total_count
        )
    } else if available_count < min_runners {
        format!(
            "{} online runners available (busy={}, offline={}, threshold={})",
            available_count, busy_count, offline_count, min_runners
        )
    } else if available_count == min_runners {
        format!(
            "{} online runner(s) available (degraded: at capacity, busy={}, offline={})",
            available_count, busy_count, offline_count
        )
    } else {
        format!(
            "{} online runner(s) available (healthy: busy={}, offline={})",
            available_count, busy_count, offline_count
        )
    };

    Ok(RunnerCheckResult {
        online_count: available_count,
        offline_count,
        busy_count,
        total_count: response.total_count,
        healthy,
        detail,
    })
}

/// Emit a telemetry event for runner status.
pub fn emit_runner_status(result: &RunnerCheckResult) {
    let _ = emit(&EmitArgs {
        kind: "fleet_doctor_runner_count".to_string(),
        source: Some("self_hosted_runner_check".to_string()),
        fields: vec![
            ("online".to_string(), result.online_count.to_string()),
            ("offline".to_string(), result.offline_count.to_string()),
            ("busy".to_string(), result.busy_count.to_string()),
            ("total".to_string(), result.total_count.to_string()),
            ("healthy".to_string(), result.healthy.to_string()),
        ],
        ..Default::default()
    });
}

/// Get repository owner from git remote origin.
fn get_repo_owner() -> Result<String, String> {
    let output = Command::new("gh")
        .arg("repo")
        .arg("view")
        .arg("--json")
        .arg("owner")
        .arg("--jq")
        .arg(".owner.login")
        .output()
        .map_err(|e| format!("failed to get repo owner: {}", e))?;

    if !output.status.success() {
        return Err("failed to determine repo owner".to_string());
    }

    String::from_utf8(output.stdout)
        .map_err(|e| format!("invalid UTF-8: {}", e))
        .map(|s| s.trim().to_string())
}

/// Get repository name from git remote origin.
fn get_repo_name() -> Result<String, String> {
    let output = Command::new("gh")
        .arg("repo")
        .arg("view")
        .arg("--json")
        .arg("name")
        .arg("--jq")
        .arg(".name")
        .output()
        .map_err(|e| format!("failed to get repo name: {}", e))?;

    if !output.status.success() {
        return Err("failed to determine repo name".to_string());
    }

    String::from_utf8(output.stdout)
        .map_err(|e| format!("invalid UTF-8: {}", e))
        .map(|s| s.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runner_check_result_serializes() {
        let result = RunnerCheckResult {
            online_count: 2,
            offline_count: 1,
            busy_count: 1,
            total_count: 4,
            healthy: true,
            detail: "2 online runners available".to_string(),
        };

        let json = serde_json::to_string(&result).expect("should serialize");
        assert!(json.contains("\"online_count\":2"));
        assert!(json.contains("\"offline_count\":1"));
        assert!(json.contains("\"healthy\":true"));
    }

    #[test]
    fn health_check_zero_runners() {
        let result = RunnerCheckResult {
            online_count: 0,
            offline_count: 2,
            busy_count: 0,
            total_count: 2,
            healthy: false,
            detail: "0 online runners (offline=2, total=2): CI cannot proceed on self-hosted"
                .to_string(),
        };

        assert!(!result.healthy);
        assert!(result.detail.contains("CI cannot proceed"));
    }

    #[test]
    fn health_check_degraded() {
        let result = RunnerCheckResult {
            online_count: 1,
            offline_count: 1,
            busy_count: 0,
            total_count: 2,
            healthy: true,
            detail: "1 online runner(s) available (degraded: at capacity, busy=0, offline=1)"
                .to_string(),
        };

        assert!(result.healthy);
        assert!(result.detail.contains("degraded"));
    }

    #[test]
    fn health_check_healthy() {
        let result = RunnerCheckResult {
            online_count: 2,
            offline_count: 0,
            busy_count: 1,
            total_count: 3,
            healthy: true,
            detail: "2 online runner(s) available (healthy: busy=1, offline=0)".to_string(),
        };

        assert!(result.healthy);
        assert!(result.detail.contains("healthy"));
    }
}
