//! Worker-capability registry (INFRA-1475 — which machines can claim which gaps).
//!
//! Workers advertise here via `upsert_capability`; push-routing uses the rows
//! to dispatch gaps to capable workers. `heartbeat()` is called periodically
//! by long-running workers to refresh `last_heartbeat_at` — stale rows mean
//! the machine is offline.

use crate::errors::ChumpTeamError;
use crate::gaps::fetch_json;
use crate::{ChumpTeam, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    Claude,
    Opencode,
    Codex,
    Manual,
}

impl Backend {
    fn as_db_str(&self) -> &'static str {
        match self {
            Backend::Claude => "claude",
            Backend::Opencode => "opencode",
            Backend::Codex => "codex",
            Backend::Manual => "manual",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerCapability {
    pub team_id: Uuid,
    pub user_id: Uuid,
    pub machine: String,
    pub skills: Vec<String>,
    pub backend: Backend,
    pub max_concurrent_gaps: i32,
    pub max_concurrent_cargo_jobs: i32,
    pub last_heartbeat_at: DateTime<Utc>,
}

impl ChumpTeam {
    /// Register or update this machine's capabilities. Upsert semantics —
    /// PostgREST `Prefer: resolution=merge-duplicates` would normally do this
    /// in one round-trip; the postgrest crate doesn't expose that header yet
    /// so we do explicit insert-or-update.
    pub async fn upsert_capability(&self, cap: WorkerCapability) -> Result<()> {
        let payload = serde_json::json!({
            "team_id": cap.team_id,
            "user_id": cap.user_id,
            "machine": cap.machine,
            "skills": cap.skills,
            "backend": cap.backend.as_db_str(),
            "max_concurrent_gaps": cap.max_concurrent_gaps,
            "max_concurrent_cargo_jobs": cap.max_concurrent_cargo_jobs,
            "last_heartbeat_at": cap.last_heartbeat_at.to_rfc3339(),
        });
        // PostgREST upsert via header on insert. The postgrest 1.6 crate
        // doesn't have an .upsert() helper, so we use the underlying header
        // injection.
        let q = self
            .postgrest()
            .from("worker_capabilities")
            .insert(payload.to_string());
        // Try insert first; on 23505 (duplicate PK), fall through to update.
        match fetch_json::<Vec<WorkerCapability>>(q, "worker_capabilities").await {
            Ok(_) => Ok(()),
            Err(ChumpTeamError::Conflict { .. }) => {
                // Update path.
                let patch = serde_json::json!({
                    "skills": cap.skills,
                    "backend": cap.backend.as_db_str(),
                    "max_concurrent_gaps": cap.max_concurrent_gaps,
                    "max_concurrent_cargo_jobs": cap.max_concurrent_cargo_jobs,
                    "last_heartbeat_at": cap.last_heartbeat_at.to_rfc3339(),
                });
                let q = self
                    .postgrest()
                    .from("worker_capabilities")
                    .update(patch.to_string())
                    .eq("team_id", cap.team_id.to_string())
                    .eq("user_id", cap.user_id.to_string())
                    .eq("machine", &cap.machine);
                let _: Vec<WorkerCapability> = fetch_json(q, "worker_capabilities").await?;
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    /// Heartbeat — bump last_heartbeat_at to now. Cheap; safe to call
    /// every ~30s from a worker.
    pub async fn heartbeat(&self, team_id: Uuid, user_id: Uuid, machine: &str) -> Result<()> {
        let payload = serde_json::json!({
            "last_heartbeat_at": Utc::now().to_rfc3339(),
        });
        let q = self
            .postgrest()
            .from("worker_capabilities")
            .update(payload.to_string())
            .eq("team_id", team_id.to_string())
            .eq("user_id", user_id.to_string())
            .eq("machine", machine);
        let _: Vec<WorkerCapability> = fetch_json(q, "worker_capabilities").await?;
        Ok(())
    }

    /// List all known workers in the team. Includes stale ones (cockpit
    /// view); callers filter by `last_heartbeat_at` for "online" semantics.
    pub async fn list_capabilities(&self, team_id: Uuid) -> Result<Vec<WorkerCapability>> {
        let q = self
            .postgrest()
            .from("worker_capabilities")
            .select("*")
            .eq("team_id", team_id.to_string())
            .order("last_heartbeat_at.desc");
        fetch_json::<Vec<WorkerCapability>>(q, "worker_capabilities").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_db_strings() {
        assert_eq!(Backend::Claude.as_db_str(), "claude");
        assert_eq!(Backend::Opencode.as_db_str(), "opencode");
        assert_eq!(Backend::Codex.as_db_str(), "codex");
        assert_eq!(Backend::Manual.as_db_str(), "manual");
    }
}
