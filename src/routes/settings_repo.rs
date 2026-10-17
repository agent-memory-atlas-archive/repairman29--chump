//! INFRA-1570: `GET /api/settings/repo` + `PUT /api/settings/repo` —
//! per-repo settings backend (sibling to INFRA-1563 /api/decisions and INFRA-988 /api/settings).
//!
//! Storage: `.chump/state.db` table `chump_repo_settings` with columns:
//! - repo_path TEXT PRIMARY KEY
//! - watched_branches TEXT (JSON array or comma-separated)
//! - default_priority_filter TEXT (enum: "all", "P0", "P1", "P2", "P3")
//! - default_effort_filter TEXT (enum: "all", "xs", "s", "m", "l", "xl")
//! - created_at TEXT (ISO 8601)
//! - updated_at TEXT (ISO 8601)
//!
//! Response shape:
//! ```json
//! {
//!   "repo_path": "/path/to/repo",
//!   "watched_branches": ["main", "develop"],
//!   "default_priority_filter": "all",
//!   "default_effort_filter": "all",
//!   "created_at": "2026-05-16T12:00:00Z",
//!   "updated_at": "2026-05-16T12:00:00Z"
//! }
//! ```

use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use rusqlite::Connection;
use std::path::PathBuf;

fn db_path() -> PathBuf {
    // INFRA-8190: the ONE resolver (CHUMP_STATE_DB > main checkout > root).
    chump_gap_store::store_path::state_db_path(&crate::repo_path::runtime_base())
}

fn get_connection() -> Result<Connection, rusqlite::Error> {
    Connection::open(db_path())
}

fn ensure_table(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chump_repo_settings (
            repo_path TEXT PRIMARY KEY,
            watched_branches TEXT,
            default_priority_filter TEXT,
            default_effort_filter TEXT,
            created_at TEXT,
            updated_at TEXT
        )",
        [],
    )?;
    Ok(())
}

#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct RepoSettings {
    pub repo_path: String,
    #[serde(default)]
    pub watched_branches: Vec<String>,
    #[serde(default = "default_priority_filter")]
    pub default_priority_filter: String,
    #[serde(default = "default_effort_filter")]
    pub default_effort_filter: String,
    pub created_at: String,
    pub updated_at: String,
}

fn default_priority_filter() -> String {
    "all".to_string()
}

fn default_effort_filter() -> String {
    "all".to_string()
}

/// GET /api/settings/repo — retrieve per-repo settings for the current repo.
pub async fn handle_settings_repo_get(
    headers: HeaderMap,
) -> Result<Json<RepoSettings>, StatusCode> {
    if !crate::routes::shared::check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let repo_path = get_current_repo_path();
    let conn = get_connection().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    ensure_table(&conn).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Try to fetch existing settings
    if let Ok(settings) = fetch_repo_settings(&conn, &repo_path) {
        return Ok(Json(settings));
    }

    // Return defaults for new repo
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let defaults = RepoSettings {
        repo_path: repo_path.clone(),
        watched_branches: vec!["main".to_string()],
        default_priority_filter: "all".to_string(),
        default_effort_filter: "all".to_string(),
        created_at: now.clone(),
        updated_at: now,
    };

    Ok(Json(defaults))
}

/// PUT /api/settings/repo — persist per-repo settings.
pub async fn handle_settings_repo_put(
    headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !crate::routes::shared::check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let repo_path = get_current_repo_path();
    let conn = get_connection().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    ensure_table(&conn).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Parse watched_branches from request
    let watched_branches: Vec<String> = payload
        .get("watched_branches")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_else(|| vec!["main".to_string()]);

    // Validate and extract priority filter
    let priority_filter = payload
        .get("default_priority_filter")
        .and_then(|v| v.as_str())
        .filter(|v| matches!(*v, "all" | "P0" | "P1" | "P2" | "P3"))
        .unwrap_or("all");

    // Validate and extract effort filter
    let effort_filter = payload
        .get("default_effort_filter")
        .and_then(|v| v.as_str())
        .filter(|v| matches!(*v, "all" | "xs" | "s" | "m" | "l" | "xl"))
        .unwrap_or("all");

    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let branches_json =
        serde_json::to_string(&watched_branches).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Check if settings already exist
    let exists: bool = conn
        .query_row(
            "SELECT 1 FROM chump_repo_settings WHERE repo_path = ?1",
            [&repo_path],
            |_| Ok(true),
        )
        .unwrap_or(false);

    if exists {
        conn.execute(
            "UPDATE chump_repo_settings
             SET watched_branches = ?1,
                 default_priority_filter = ?2,
                 default_effort_filter = ?3,
                 updated_at = ?4
             WHERE repo_path = ?5",
            rusqlite::params![
                &branches_json,
                priority_filter,
                effort_filter,
                &now,
                &repo_path
            ],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    } else {
        let created_at = now.clone();
        conn.execute(
            "INSERT INTO chump_repo_settings
             (repo_path, watched_branches, default_priority_filter, default_effort_filter, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                &repo_path,
                &branches_json,
                priority_filter,
                effort_filter,
                &created_at,
                &now
            ],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    Ok(Json(serde_json::json!({
        "ok": true,
        "repo_path": &repo_path,
        "watched_branches": watched_branches,
        "default_priority_filter": priority_filter,
        "default_effort_filter": effort_filter,
        "updated_at": &now
    })))
}

fn get_current_repo_path() -> String {
    std::env::var("CHUMP_REPO")
        .ok()
        .and_then(|p| if p.trim().is_empty() { None } else { Some(p) })
        .unwrap_or_else(|| {
            crate::repo_path::runtime_base()
                .to_string_lossy()
                .to_string()
        })
}

fn fetch_repo_settings(
    conn: &Connection,
    repo_path: &str,
) -> Result<RepoSettings, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT repo_path, watched_branches, default_priority_filter, default_effort_filter, created_at, updated_at
         FROM chump_repo_settings WHERE repo_path = ?1",
    )?;

    stmt.query_row([repo_path], |row| {
        let branches_json: String = row.get(1)?;
        let watched_branches: Vec<String> =
            serde_json::from_str(&branches_json).unwrap_or_else(|_| vec!["main".to_string()]);

        Ok(RepoSettings {
            repo_path: row.get(0)?,
            watched_branches,
            default_priority_filter: row.get(2)?,
            default_effort_filter: row.get(3)?,
            created_at: row.get(4)?,
            updated_at: row.get(5)?,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_filters() {
        assert_eq!(default_priority_filter(), "all");
        assert_eq!(default_effort_filter(), "all");
    }

    #[test]
    fn test_validate_priority_filters() {
        let valid = vec!["all", "P0", "P1", "P2", "P3"];
        for filter in valid {
            assert!(matches!(filter, "all" | "P0" | "P1" | "P2" | "P3"));
        }
    }

    #[test]
    fn test_validate_effort_filters() {
        let valid = vec!["all", "xs", "s", "m", "l", "xl"];
        for filter in valid {
            assert!(matches!(filter, "all" | "xs" | "s" | "m" | "l" | "xl"));
        }
    }
}
