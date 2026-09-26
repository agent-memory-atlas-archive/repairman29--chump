//! chump-idea-drop — persisted model for dropped ideas (EFFECTIVE-392 slice,
//! EFFECTIVE-1291).
//!
//! This crate defines only the storage schema + a thin open/insert/lookup
//! surface. The digest pipeline (AC-writer wiring, dedupe, gap-filing) is
//! out of scope here — see EFFECTIVE-392.

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::fs;
use std::path::{Path, PathBuf};

/// A single dropped idea row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DroppedIdea {
    pub id: i64,
    pub sentence: String,
    pub citation: String,
    pub status: String,
    pub created_at: String,
}

/// Resolve the repo root. Prefers CHUMP_REPO_ROOT (test override), then the
/// current dir.
pub fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        let p = PathBuf::from(r);
        if p.is_dir() {
            return p;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Resolve the dropped-ideas DB path. Defaults to `<repo>/.chump/ideas.db`.
/// Override via CHUMP_IDEA_DROP_DB for tests.
pub fn idea_drop_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_IDEA_DROP_DB") {
        return PathBuf::from(p);
    }
    repo_root().join(".chump/ideas.db")
}

/// Resolve the migration SQL path. CHUMP_IDEA_DROP_MIGRATION lets tests
/// point at an isolated fixture; default is repo_root/migrations/dropped_ideas_v1.sql.
fn migration_sql_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_IDEA_DROP_MIGRATION") {
        return PathBuf::from(p);
    }
    repo_root().join("migrations/dropped_ideas_v1.sql")
}

/// Open (and lazily initialize) the dropped-ideas DB. Applies the v1 schema
/// idempotently every open — every CREATE statement is `IF NOT EXISTS`.
pub fn open_db() -> Result<Connection> {
    open_db_at(&idea_drop_db_path(), &migration_sql_path())
}

/// Explicit-path variant — bypasses env-var resolution. Used by tests and
/// callers that need isolation from CHUMP_IDEA_DROP_DB.
pub fn open_db_at(db_path: &Path, schema_path: &Path) -> Result<Connection> {
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating parent dir for {}", db_path.display()))?;
    }
    let conn = Connection::open(db_path)
        .with_context(|| format!("opening dropped-ideas DB at {}", db_path.display()))?;
    let sql = fs::read_to_string(schema_path)
        .with_context(|| format!("reading dropped-ideas schema at {}", schema_path.display()))?;
    conn.execute_batch(&sql)
        .with_context(|| "applying dropped-ideas schema")?;
    Ok(conn)
}

/// Record a dropped idea: one sentence plus a citation. Status defaults to
/// 'pending'.
pub fn drop_idea(conn: &Connection, sentence: &str, citation: &str) -> Result<i64> {
    conn.execute(
        "INSERT INTO dropped_ideas (sentence, citation) VALUES (?1, ?2)",
        params![sentence, citation],
    )
    .context("inserting dropped idea")?;
    Ok(conn.last_insert_rowid())
}

/// Look up dropped ideas by citation.
pub fn lookup_by_citation(conn: &Connection, citation: &str) -> Result<Vec<DroppedIdea>> {
    let mut stmt = conn.prepare(
        "SELECT id, sentence, citation, status, created_at FROM dropped_ideas WHERE citation = ?1 ORDER BY id",
    )?;
    let rows = stmt
        .query_map(params![citation], |row| {
            Ok(DroppedIdea {
                id: row.get(0)?,
                sentence: row.get(1)?,
                citation: row.get(2)?,
                status: row.get(3)?,
                created_at: row.get(4)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Look up dropped ideas by status.
pub fn lookup_by_status(conn: &Connection, status: &str) -> Result<Vec<DroppedIdea>> {
    let mut stmt = conn.prepare(
        "SELECT id, sentence, citation, status, created_at FROM dropped_ideas WHERE status = ?1 ORDER BY id",
    )?;
    let rows = stmt
        .query_map(params![status], |row| {
            Ok(DroppedIdea {
                id: row.get(0)?,
                sentence: row.get(1)?,
                citation: row.get(2)?,
                status: row.get(3)?,
                created_at: row.get(4)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn migration_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("migrations")
            .join("dropped_ideas_v1.sql")
    }

    #[test]
    fn schema_applies_cleanly_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("ideas.db");
        let conn = open_db_at(&db_path, &migration_path()).unwrap();
        // Re-applying the schema on an already-initialized DB must not error.
        let sql = fs::read_to_string(migration_path()).unwrap();
        conn.execute_batch(&sql).unwrap();

        // Re-opening (simulating a fresh process, e.g. staging) must also work.
        drop(conn);
        let conn2 = open_db_at(&db_path, &migration_path()).unwrap();
        conn2
            .execute("SELECT 1 FROM dropped_ideas LIMIT 0", [])
            .unwrap();
    }

    #[test]
    fn indexes_exist_for_citation_and_status() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("ideas.db");
        let conn = open_db_at(&db_path, &migration_path()).unwrap();

        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'dropped_ideas'")
            .unwrap();
        let names: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        assert!(names.contains(&"dropped_ideas_citation_idx".to_string()));
        assert!(names.contains(&"dropped_ideas_status_idx".to_string()));
    }

    #[test]
    fn drop_and_lookup_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("ideas.db");
        let conn = open_db_at(&db_path, &migration_path()).unwrap();

        let id = drop_idea(&conn, "cheap idea drop needs a home", "session-abc123").unwrap();
        assert!(id > 0);

        let by_citation = lookup_by_citation(&conn, "session-abc123").unwrap();
        assert_eq!(by_citation.len(), 1);
        assert_eq!(by_citation[0].sentence, "cheap idea drop needs a home");
        assert_eq!(by_citation[0].status, "pending");
        assert!(!by_citation[0].created_at.is_empty());

        let by_status = lookup_by_status(&conn, "pending").unwrap();
        assert_eq!(by_status.len(), 1);
        assert_eq!(by_status[0].id, id);

        let none = lookup_by_status(&conn, "digested").unwrap();
        assert!(none.is_empty());
    }
}
