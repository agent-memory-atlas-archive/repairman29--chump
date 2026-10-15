//! Minimal async job log (universal power P2.2): append-only rows for autonomy, future web hooks, etc.

use anyhow::Result;
use rusqlite::params;
use serde_json::{json, Value};

/// Insert one job row (id is a new UUID).
pub fn insert_job(
    job_type: &str,
    status: &str,
    task_id: Option<i64>,
    session_id: Option<&str>,
    detail: Option<&str>,
    last_error: Option<&str>,
) -> Result<()> {
    let conn = crate::db_pool::get()?;
    let id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO chump_async_jobs (id, job_type, status, task_id, session_id, last_error, detail, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, datetime('now'), datetime('now'))",
        params![
            id,
            job_type,
            status,
            task_id,
            session_id,
            last_error,
            detail.unwrap_or(""),
        ],
    )?;
    Ok(())
}

/// Recent jobs, newest first.
pub fn recent_jobs(limit: usize) -> Result<Vec<Value>> {
    let conn = crate::db_pool::get()?;
    let limit = limit.clamp(1, 200) as i64;
    let mut stmt = conn.prepare(
        "SELECT id, job_type, status, task_id, session_id, last_error, detail, created_at, updated_at
         FROM chump_async_jobs ORDER BY rowid DESC LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![limit], |r| {
        Ok(json!({
            "id": r.get::<_, String>(0)?,
            "job_type": r.get::<_, String>(1)?,
            "status": r.get::<_, String>(2)?,
            "task_id": r.get::<_, Option<i64>>(3)?,
            "session_id": r.get::<_, Option<String>>(4)?,
            "last_error": r.get::<_, Option<String>>(5)?,
            "detail": r.get::<_, String>(6)?,
            "created_at": r.get::<_, String>(7)?,
            "updated_at": r.get::<_, String>(8)?,
        }))
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Mark the most recent job of a given type as running (RESILIENT-1427).
pub fn mark_running(job_type: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_async_jobs SET status = 'running', updated_at = datetime('now')
         WHERE job_type = ?1 AND status = 'pending'
         ORDER BY rowid DESC LIMIT 1",
        params![job_type],
    )?;
    Ok(())
}

/// Mark the most recent job of a given type as completed (RESILIENT-1427).
pub fn mark_completed(job_type: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_async_jobs SET status = 'completed', updated_at = datetime('now')
         WHERE job_type = ?1 AND (status = 'pending' OR status = 'running')
         ORDER BY rowid DESC LIMIT 1",
        params![job_type],
    )?;
    Ok(())
}

/// Mark the most recent job of a given type as failed with error message (RESILIENT-1427).
pub fn mark_failed(job_type: &str, error: &str) -> Result<()> {
    let conn = crate::db_pool::get()?;
    conn.execute(
        "UPDATE chump_async_jobs SET status = 'failed', last_error = ?2, updated_at = datetime('now')
         WHERE job_type = ?1 AND (status = 'pending' OR status = 'running')
         ORDER BY rowid DESC LIMIT 1",
        params![job_type, error],
    )?;
    Ok(())
}
