//! RESILIENT-059: SQLite-backed journal for durable gap execution.
//!
//! Each activity (step) in a gap execution is recorded as a row in
//! `durable_journal`. The table lives in `.chump/state.db` via the shared
//! pool — no new infrastructure required.
//!
//! # Resume semantics
//!
//! A `run_id` is a monotonically increasing integer per `gap_id`. When a
//! worker restarts mid-gap it calls [`Journal::next_run_id`] with
//! `resume=true` to get the most recent run that has incomplete steps,
//! rather than allocating a fresh run. The [`DurableExecutor`] then replays
//! already-completed steps from the journal cache before continuing at the
//! first incomplete step.
//!
//! # Ambient events emitted
//!
//! - `kind=durable_journal_step_started`   — fields: ts, gap_id, run_id, step_name, step_index
//! - `kind=durable_journal_step_completed` — fields: ts, gap_id, run_id, step_name, step_index, elapsed_ms
//! - `kind=durable_journal_resumed`        — fields: ts, gap_id, prior_run_id, replayed_steps

use anyhow::{Context, Result};
use rusqlite::Connection;
use std::path::PathBuf;

// ── DB path helpers ──────────────────────────────────────────────────────────

/// Return the path to `.chump/state.db`, honouring `CHUMP_STATE_DB_PATH` and
/// the `CHUMP_REPO_ROOT` env overrides used by test harnesses.
pub fn state_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_STATE_DB_PATH") {
        return PathBuf::from(p);
    }
    let root = if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        PathBuf::from(r)
    } else {
        let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        loop {
            if dir.join("Cargo.toml").exists() {
                if let Ok(c) = std::fs::read_to_string(dir.join("Cargo.toml")) {
                    if c.contains("[workspace]") {
                        break;
                    }
                }
            }
            if !dir.pop() {
                break;
            }
        }
        dir
    };
    // INFRA-8190: the ONE resolver (CHUMP_STATE_DB > main checkout > root).
    chump_gap_store::store_path::state_db_path(&root)
}

/// Open a raw rusqlite connection to the state DB with WAL + busy-timeout.
fn open_conn(path: &std::path::Path) -> Result<Connection> {
    let conn =
        Connection::open(path).with_context(|| format!("open state DB at {}", path.display()))?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;",
    )?;
    Ok(conn)
}

// ── Schema migration ─────────────────────────────────────────────────────────

const CREATE_TABLE: &str = "
CREATE TABLE IF NOT EXISTS durable_journal (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    gap_id        TEXT    NOT NULL,
    run_id        INTEGER NOT NULL,
    step_name     TEXT    NOT NULL,
    step_index    INTEGER NOT NULL,
    started_at    TEXT    NOT NULL,
    completed_at  TEXT,
    result_json   TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 1,
    UNIQUE (gap_id, run_id, step_name)
);
CREATE INDEX IF NOT EXISTS durable_journal_lookup
    ON durable_journal (gap_id, run_id, step_index);
";

/// Ensure the `durable_journal` table exists. Idempotent — safe to call on
/// every process start.
pub fn ensure_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(CREATE_TABLE)?;
    Ok(())
}

// ── Journal struct ───────────────────────────────────────────────────────────

/// SQLite-backed journal for a single gap execution session.
pub struct Journal {
    conn: Connection,
}

impl Journal {
    /// Open (or create) the journal against the default state DB path.
    pub fn open() -> Result<Self> {
        Self::open_at(&state_db_path())
    }

    /// Open the journal at an explicit DB path. Used by tests to pass a temp DB.
    pub fn open_at(path: &std::path::Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = open_conn(path)?;
        ensure_schema(&conn)?;
        Ok(Self { conn })
    }

    // ── run_id allocation ────────────────────────────────────────────────────

    /// Return the next run_id for `gap_id`.
    ///
    /// If `resume=false` (fresh run): returns `MAX(run_id) + 1`, or 1 if no
    /// prior runs exist.
    ///
    /// If `resume=true`: returns the most recent `run_id` for this `gap_id`
    /// (any existing run — the caller has signalled they want to reattach
    /// to the prior execution). The caller's [`DurableExecutor`] then
    /// short-circuits completed steps via the journal cache and continues
    /// at the first incomplete / not-yet-started step.
    ///
    /// If `resume=false` or there are no prior runs, allocates a fresh
    /// `run_id` (MAX(existing)+1, or 1 if no rows).
    ///
    /// Semantic note (RESILIENT-059): the resume signal is the CALLER's
    /// decision — typically "process restart after crash". The journal
    /// itself does not (and cannot) know whether a run is "logically
    /// complete" without an explicit run-level completion marker.
    /// `resume()` always reattaches; `new()` always starts fresh.
    pub fn next_run_id(&self, gap_id: &str, resume: bool) -> Result<u64> {
        if resume {
            // Find the most recent run that has ANY journal entry —
            // resume always reattaches to the latest prior run for the gap.
            let mut stmt = self
                .conn
                .prepare("SELECT MAX(run_id) FROM durable_journal WHERE gap_id = ?1")?;
            let mut rows = stmt.query([gap_id])?;
            if let Some(row) = rows.next()? {
                let max: Option<i64> = row.get(0)?;
                if let Some(run_id) = max {
                    return Ok(run_id as u64);
                }
            }
            // No prior run for this gap — fall through to fresh allocation.
        }

        let mut stmt = self
            .conn
            .prepare("SELECT COALESCE(MAX(run_id), 0) FROM durable_journal WHERE gap_id = ?1")?;
        let max: i64 = stmt.query_row([gap_id], |r| r.get(0))?;
        Ok((max + 1) as u64)
    }

    // ── step lifecycle ───────────────────────────────────────────────────────

    /// Insert a new in-flight step row. Returns the `step_index` allocated.
    /// Emits `kind=durable_journal_step_started`.
    pub fn start_step(&self, gap_id: &str, run_id: u64, step_name: &str) -> Result<i64> {
        let now = chrono::Utc::now().to_rfc3339();

        // Determine step_index: MAX(step_index)+1 for this (gap_id, run_id).
        let mut stmt = self.conn.prepare(
            "SELECT COALESCE(MAX(step_index), -1) + 1
             FROM durable_journal WHERE gap_id = ?1 AND run_id = ?2",
        )?;
        let step_index: i64 =
            stmt.query_row(rusqlite::params![gap_id, run_id as i64], |r| r.get(0))?;

        self.conn.execute(
            "INSERT OR IGNORE INTO durable_journal
             (gap_id, run_id, step_name, step_index, started_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![gap_id, run_id as i64, step_name, step_index, now],
        )?;

        // Fetch the actual row id (handles OR IGNORE case where row already existed).
        let id: i64 = self.conn.query_row(
            "SELECT id FROM durable_journal
             WHERE gap_id = ?1 AND run_id = ?2 AND step_name = ?3",
            rusqlite::params![gap_id, run_id as i64, step_name],
            |r| r.get(0),
        )?;

        emit_ambient(serde_json::json!({
            "kind": "durable_journal_step_started",
            "ts": &now,
            "gap_id": gap_id,
            "run_id": run_id,
            "step_name": step_name,
            "step_index": step_index,
        }));

        Ok(id)
    }

    /// Mark a step as completed and persist its result JSON.
    /// Emits `kind=durable_journal_step_completed`.
    pub fn complete_step(&self, step_id: i64, result_json: &str) -> Result<()> {
        let now = chrono::Utc::now().to_rfc3339();

        // Read the started_at so we can compute elapsed_ms.
        let (started_at, gap_id, run_id, step_name, step_index): (
            String,
            String,
            i64,
            String,
            i64,
        ) = self.conn.query_row(
            "SELECT started_at, gap_id, run_id, step_name, step_index
             FROM durable_journal WHERE id = ?1",
            [step_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )?;

        self.conn.execute(
            "UPDATE durable_journal SET completed_at = ?1, result_json = ?2 WHERE id = ?3",
            rusqlite::params![now, result_json, step_id],
        )?;

        // Best-effort elapsed_ms computation.
        let elapsed_ms = chrono::DateTime::parse_from_rfc3339(&now)
            .ok()
            .and_then(|end| {
                chrono::DateTime::parse_from_rfc3339(&started_at)
                    .ok()
                    .map(|start| (end - start).num_milliseconds())
            })
            .unwrap_or(0);

        emit_ambient(serde_json::json!({
            "kind": "durable_journal_step_completed",
            "ts": &now,
            "gap_id": &gap_id,
            "run_id": run_id,
            "step_name": &step_name,
            "step_index": step_index,
            "elapsed_ms": elapsed_ms,
        }));

        Ok(())
    }

    /// Increment the attempt_count for a step that is being retried after a
    /// transient failure. Does NOT reset completed_at or result_json — those
    /// only change on success.
    pub fn increment_attempt(&self, step_id: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE durable_journal SET attempt_count = attempt_count + 1 WHERE id = ?1",
            [step_id],
        )?;
        Ok(())
    }

    // ── lookup ───────────────────────────────────────────────────────────────

    /// Return the completed result JSON for a step if it has already finished,
    /// or `None` if the step is in-flight or has never started.
    pub fn lookup_completed(
        &self,
        gap_id: &str,
        run_id: u64,
        step_name: &str,
    ) -> Result<Option<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT result_json FROM durable_journal
             WHERE gap_id = ?1 AND run_id = ?2 AND step_name = ?3
             AND completed_at IS NOT NULL",
        )?;
        let mut rows = stmt.query(rusqlite::params![gap_id, run_id as i64, step_name])?;
        if let Some(row) = rows.next()? {
            let json: Option<String> = row.get(0)?;
            return Ok(json);
        }
        Ok(None)
    }

    /// Return all completed steps for a (gap_id, run_id), ordered by step_index.
    /// Used during resume to reconstruct the replay list.
    pub fn completed_steps(&self, gap_id: &str, run_id: u64) -> Result<Vec<CompletedStep>> {
        let mut stmt = self.conn.prepare(
            "SELECT step_name, step_index, result_json, started_at, completed_at
             FROM durable_journal
             WHERE gap_id = ?1 AND run_id = ?2 AND completed_at IS NOT NULL
             ORDER BY step_index ASC",
        )?;
        let rows = stmt.query_map(rusqlite::params![gap_id, run_id as i64], |r| {
            Ok(CompletedStep {
                step_name: r.get(0)?,
                step_index: r.get(1)?,
                result_json: r.get(2)?,
                started_at: r.get(3)?,
                completed_at: r.get(4)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Count incomplete steps for a (gap_id, run_id). Returns 0 if all steps
    /// have completed (or if no steps were recorded).
    pub fn incomplete_step_count(&self, gap_id: &str, run_id: u64) -> Result<usize> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM durable_journal
             WHERE gap_id = ?1 AND run_id = ?2 AND completed_at IS NULL",
            rusqlite::params![gap_id, run_id as i64],
            |r| r.get(0),
        )?;
        Ok(count as usize)
    }

    /// Emit a `kind=durable_journal_resumed` event for telemetry.
    pub fn emit_resumed(&self, gap_id: &str, prior_run_id: u64, replayed_steps: usize) {
        let now = chrono::Utc::now().to_rfc3339();
        emit_ambient(serde_json::json!({
            "kind": "durable_journal_resumed",
            "ts": now,
            "gap_id": gap_id,
            "prior_run_id": prior_run_id,
            "replayed_steps": replayed_steps,
        }));
    }
}

// ── CompletedStep ─────────────────────────────────────────────────────────────

/// A completed step row returned by [`Journal::completed_steps`].
#[derive(Debug, Clone)]
pub struct CompletedStep {
    pub step_name: String,
    pub step_index: i64,
    pub result_json: Option<String>,
    pub started_at: String,
    pub completed_at: Option<String>,
}

// ── Ambient emit helper ───────────────────────────────────────────────────────

/// Best-effort append to `.chump-locks/ambient.jsonl`. Silently no-ops on any
/// I/O error so that a missing locks dir never breaks a worker.
fn emit_ambient(payload: serde_json::Value) {
    // Honour test override so tests can capture or suppress ambient writes.
    if std::env::var("CHUMP_DURABLE_AMBIENT_DISABLE").is_ok() {
        return;
    }
    let path = {
        let root = if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
            PathBuf::from(r)
        } else {
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
        };
        root.join(".chump-locks").join("ambient.jsonl")
    };
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", payload);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn temp_journal() -> Journal {
        let f = NamedTempFile::new().unwrap();
        let path = f.path().to_owned();
        // Keep the file alive for the test by leaking the guard (tempfile removes on drop).
        std::mem::forget(f);
        unsafe {
            std::env::set_var("CHUMP_DURABLE_AMBIENT_DISABLE", "1");
        }
        Journal::open_at(&path).unwrap()
    }

    #[test]
    fn fresh_run_id_starts_at_1() {
        let j = temp_journal();
        let run_id = j.next_run_id("GAP-1", false).unwrap();
        assert_eq!(run_id, 1);
    }

    #[test]
    fn second_fresh_run_increments() {
        let j = temp_journal();
        let id1 = j.next_run_id("GAP-2", false).unwrap();
        // Simulate a step so the first run is visible in the DB.
        let step_id = j.start_step("GAP-2", id1, "step-a").unwrap();
        j.complete_step(step_id, r#""done""#).unwrap();
        let id2 = j.next_run_id("GAP-2", false).unwrap();
        assert_eq!(id2, id1 + 1);
    }

    #[test]
    fn resume_returns_incomplete_run() {
        let j = temp_journal();
        let run_id = j.next_run_id("GAP-3", false).unwrap();
        // Start but do NOT complete step-a — simulate a crash.
        let _ = j.start_step("GAP-3", run_id, "step-a").unwrap();
        // resume=true should give back the same run_id.
        let resumed = j.next_run_id("GAP-3", true).unwrap();
        assert_eq!(resumed, run_id);
    }

    #[test]
    fn lookup_completed_returns_cached_value() {
        let j = temp_journal();
        let run_id = j.next_run_id("GAP-4", false).unwrap();
        let step_id = j.start_step("GAP-4", run_id, "step-b").unwrap();
        j.complete_step(step_id, r#"{"x":42}"#).unwrap();
        let result = j.lookup_completed("GAP-4", run_id, "step-b").unwrap();
        assert_eq!(result.as_deref(), Some(r#"{"x":42}"#));
    }

    #[test]
    fn lookup_in_flight_returns_none() {
        let j = temp_journal();
        let run_id = j.next_run_id("GAP-5", false).unwrap();
        let _ = j.start_step("GAP-5", run_id, "step-c").unwrap();
        let result = j.lookup_completed("GAP-5", run_id, "step-c").unwrap();
        assert!(result.is_none(), "in-flight step should return None");
    }

    #[test]
    fn completed_steps_ordered_by_index() {
        let j = temp_journal();
        let run_id = j.next_run_id("GAP-6", false).unwrap();
        for name in ["alpha", "beta", "gamma"] {
            let id = j.start_step("GAP-6", run_id, name).unwrap();
            j.complete_step(id, &format!(r#""{}""#, name)).unwrap();
        }
        let steps = j.completed_steps("GAP-6", run_id).unwrap();
        assert_eq!(steps.len(), 3);
        assert_eq!(steps[0].step_name, "alpha");
        assert_eq!(steps[1].step_name, "beta");
        assert_eq!(steps[2].step_name, "gamma");
        // step_index should be 0, 1, 2 in order.
        for (i, s) in steps.iter().enumerate() {
            assert_eq!(s.step_index, i as i64);
        }
    }

    #[test]
    fn cross_run_separation() {
        let j = temp_journal();
        let run1 = j.next_run_id("GAP-7", false).unwrap();
        let id1 = j.start_step("GAP-7", run1, "step-x").unwrap();
        j.complete_step(id1, r#""run1-result""#).unwrap();

        let run2 = j.next_run_id("GAP-7", false).unwrap();
        assert_ne!(run1, run2, "each fresh run must get a distinct run_id");

        // The same step_name in run2 should return None (different run).
        let cached = j.lookup_completed("GAP-7", run2, "step-x").unwrap();
        assert!(
            cached.is_none(),
            "step-x from run1 must not bleed into run2"
        );
    }
}
