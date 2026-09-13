//! SQLite access layer for fleet_events.db.
//!
//! The events schema is owned by INFRA-2174 (capture daemon). We open the DB
//! read-write only to maintain the derived `agent_segments` table; all reads
//! from `events` are SELECT-only.

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

/// A raw event row from the `events` table (written by INFRA-2174).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventRow {
    pub id: i64,
    pub ts: String,
    pub ts_ms: i64,
    pub source: String,
    pub subject: String,
    pub event_kind: String,
    pub session_id: String,
    pub gap_id: String,
    pub payload: String,
}

/// A derived agent segment from `agent_segments`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSegment {
    pub id: i64,
    pub session_id: String,
    pub start_ts_ms: i64,
    pub end_ts_ms: Option<i64>,
    pub activity: String,
    pub gap_id: Option<String>,
    pub event_count: i64,
}

/// A per-node fleet-health heartbeat row (RESILIENT-1055).
///
/// `payload` is the raw heartbeat JSON exactly as the sentinel POSTed it; the
/// route layer re-parses it so newly-added heartbeat fields (e.g. the
/// `failed_units` / `healers` organ detail) surface without a DB migration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeHeartbeat {
    pub node: String,
    /// Epoch seconds stamped by the node when it wrote the heartbeat.
    pub epoch: i64,
    /// Server wall-clock (ms) when this heartbeat was ingested.
    pub received_ms: i64,
    /// The raw heartbeat JSON body as received.
    pub payload: String,
}

/// Thread-safe wrapper around a SQLite connection.
pub struct FleetStore {
    conn: Mutex<Connection>,
}

impl FleetStore {
    /// Open (or create) the fleet events DB. Ensures `agent_segments` schema
    /// exists even if INFRA-2174 hasn't run yet, so the server starts cleanly
    /// on a fresh or fixture DB.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating fleet db directory {}", parent.display()))?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("opening fleet db at {}", path.display()))?;

        // Ensure the events table exists (INFRA-2174 normally creates it, but
        // we need it present for the fixture-based dev/test workflow).
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS events (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                ts         TEXT NOT NULL,
                ts_ms      INTEGER NOT NULL,
                source     TEXT NOT NULL DEFAULT '',
                subject    TEXT NOT NULL DEFAULT '',
                event_kind TEXT NOT NULL DEFAULT '',
                session_id TEXT NOT NULL DEFAULT '',
                gap_id     TEXT NOT NULL DEFAULT '',
                payload    TEXT NOT NULL DEFAULT '',
                UNIQUE(ts_ms, session_id, event_kind, gap_id)
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts_ms ON events(ts_ms);
            CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, ts_ms);
            CREATE INDEX IF NOT EXISTS idx_events_kind ON events(event_kind, ts_ms);",
        )
        .context("creating events table")?;

        // The agent_segments table — derived by the segmenter background task.
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS agent_segments (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   TEXT NOT NULL,
                start_ts_ms  INTEGER NOT NULL,
                end_ts_ms    INTEGER,
                activity     TEXT NOT NULL,
                gap_id       TEXT,
                event_count  INTEGER NOT NULL DEFAULT 0,
                UNIQUE(session_id, start_ts_ms, activity)
            );
            CREATE INDEX IF NOT EXISTS idx_segments_ts
                ON agent_segments(start_ts_ms, end_ts_ms);
            CREATE INDEX IF NOT EXISTS idx_segments_session
                ON agent_segments(session_id, start_ts_ms);",
        )
        .context("creating agent_segments table")?;

        // RESILIENT-1055: per-node fleet-health heartbeats pushed by each node's
        // fleet-health-sentinel (`POST /api/sentinel-heartbeat`). One row per
        // node (latest wins) so `GET /api/fleet/nodes` can report cross-node
        // organ health as a server-side API read instead of an SSH crawl.
        // `payload` holds the full heartbeat JSON verbatim (node/epoch/failed/
        // healed/unhealed/healers_down + the enriched failed_units/healers
        // detail), so new heartbeat fields surface without a schema change.
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS node_heartbeats (
                node        TEXT PRIMARY KEY,
                epoch       INTEGER NOT NULL,
                received_ms INTEGER NOT NULL,
                payload     TEXT NOT NULL
            );",
        )
        .context("creating node_heartbeats table")?;

        Ok(FleetStore {
            conn: Mutex::new(conn),
        })
    }

    // ── events queries ────────────────────────────────────────────────────────

    /// Return events in [from_ms, to_ms] ordered by ts_ms ASC.
    /// `limit` is capped at 50 000; `offset` enables pagination.
    pub fn query_events(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<EventRow>> {
        let limit = limit.min(50_000).max(1);
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload
               FROM events
              WHERE ts_ms >= ?1 AND ts_ms <= ?2
              ORDER BY ts_ms ASC
              LIMIT ?3 OFFSET ?4",
        )?;
        let rows = stmt
            .query_map(params![from_ms, to_ms, limit, offset], row_to_event)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Return the maximum event id currently in the table (for WS live-tail).
    pub fn max_event_id(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let id: i64 = conn
            .query_row("SELECT COALESCE(MAX(id), 0) FROM events", [], |r| r.get(0))
            .context("max event id")?;
        Ok(id)
    }

    /// Return events with id > `since_id`, ordered by id ASC (for WS polling).
    pub fn events_since(&self, since_id: i64) -> Result<Vec<EventRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload
               FROM events
              WHERE id > ?1
              ORDER BY id ASC
              LIMIT 1000",
        )?;
        let rows = stmt
            .query_map(params![since_id], row_to_event)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // ── segments queries ──────────────────────────────────────────────────────

    pub fn query_segments(&self, from_ms: i64, to_ms: i64) -> Result<Vec<AgentSegment>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, session_id, start_ts_ms, end_ts_ms, activity, gap_id, event_count
               FROM agent_segments
              WHERE start_ts_ms >= ?1
                AND (end_ts_ms IS NULL OR end_ts_ms <= ?2)
              ORDER BY start_ts_ms ASC",
        )?;
        let rows = stmt
            .query_map(params![from_ms, to_ms], row_to_segment)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // ── sessions queries ──────────────────────────────────────────────────────

    /// Return distinct session_ids that have at least one event in the last 5 min.
    pub fn active_sessions(&self) -> Result<Vec<String>> {
        let since_ms = now_ms() - 5 * 60 * 1000;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT DISTINCT session_id
               FROM events
              WHERE ts_ms >= ?1
                AND session_id != ''
              ORDER BY session_id",
        )?;
        let rows = stmt
            .query_map(params![since_ms], |r| r.get(0))?
            .collect::<std::result::Result<Vec<String>, _>>()?;
        Ok(rows)
    }

    // ── trace queries ─────────────────────────────────────────────────────────

    /// Return a best-effort causal chain for a PR number.
    ///
    /// Collects:
    ///   1. Events whose `payload` contains "pr <N>" or "pr#<N>" (case-insensitive).
    ///   2. `bash_call` events whose payload references "gh pr" commands that
    ///      include the PR number.
    ///
    /// Results are deduped by id and ordered by ts_ms ASC.
    pub fn trace_pr(&self, pr_number: i64) -> Result<Vec<EventRow>> {
        let pr_str = pr_number.to_string();
        // Two patterns: "pr 123" or "#123" in payload.
        let like_pr_space = format!("%pr {}%", pr_str);
        let like_pr_hash = format!("%#{}%", pr_str);
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT DISTINCT id, ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload
               FROM events
              WHERE (LOWER(payload) LIKE LOWER(?1)
                     OR LOWER(payload) LIKE LOWER(?2))
              ORDER BY ts_ms ASC
              LIMIT 5000",
        )?;
        let rows = stmt
            .query_map(params![like_pr_space, like_pr_hash], row_to_event)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // ── segmenter write path ──────────────────────────────────────────────────

    /// Upsert an agent segment. Called by the segmenter background task.
    pub fn upsert_segment(
        &self,
        session_id: &str,
        start_ts_ms: i64,
        end_ts_ms: Option<i64>,
        activity: &str,
        gap_id: Option<&str>,
        event_count: i64,
    ) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO agent_segments
                 (session_id, start_ts_ms, end_ts_ms, activity, gap_id, event_count)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(session_id, start_ts_ms, activity) DO UPDATE SET
                 end_ts_ms   = excluded.end_ts_ms,
                 gap_id      = excluded.gap_id,
                 event_count = excluded.event_count",
            params![
                session_id,
                start_ts_ms,
                end_ts_ms,
                activity,
                gap_id,
                event_count
            ],
        )?;
        Ok(())
    }

    /// Return all events for a given session_id, ordered by ts_ms ASC.
    /// Used by the segmenter to derive segments.
    pub fn events_for_session(&self, session_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload
               FROM events
              WHERE session_id = ?1
              ORDER BY ts_ms ASC",
        )?;
        let rows = stmt
            .query_map(params![session_id], row_to_event)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // ── node heartbeats (RESILIENT-1055) ──────────────────────────────────────

    /// Upsert a node's fleet-health heartbeat (latest wins, keyed by node).
    pub fn upsert_node_heartbeat(
        &self,
        node: &str,
        epoch: i64,
        received_ms: i64,
        payload: &str,
    ) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO node_heartbeats (node, epoch, received_ms, payload)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(node) DO UPDATE SET
                 epoch       = excluded.epoch,
                 received_ms = excluded.received_ms,
                 payload     = excluded.payload",
            params![node, epoch, received_ms, payload],
        )?;
        Ok(())
    }

    /// Return every node's latest heartbeat, ordered by node name.
    pub fn list_node_heartbeats(&self) -> Result<Vec<NodeHeartbeat>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT node, epoch, received_ms, payload
               FROM node_heartbeats
              ORDER BY node ASC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(NodeHeartbeat {
                    node: r.get(0)?,
                    epoch: r.get(1)?,
                    received_ms: r.get(2)?,
                    payload: r.get(3)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Return all distinct session_ids that have events.
    pub fn all_session_ids(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt =
            conn.prepare("SELECT DISTINCT session_id FROM events WHERE session_id != ''")?;
        let rows = stmt
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<Vec<String>, _>>()?;
        Ok(rows)
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn row_to_event(r: &rusqlite::Row<'_>) -> rusqlite::Result<EventRow> {
    // INFRA-2189: the recorder writes NULLs for unset session_id / gap_id /
    // subject; coerce to empty string so the existing String fields don't
    // explode on r.get. Filed as a follow-up to harden the recorder writer.
    Ok(EventRow {
        id: r.get(0)?,
        ts: r.get(1)?,
        ts_ms: r.get(2)?,
        source: r.get(3)?,
        subject: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
        event_kind: r.get(5)?,
        session_id: r.get::<_, Option<String>>(6)?.unwrap_or_default(),
        gap_id: r.get::<_, Option<String>>(7)?.unwrap_or_default(),
        payload: r.get(8)?,
    })
}

fn row_to_segment(r: &rusqlite::Row<'_>) -> rusqlite::Result<AgentSegment> {
    Ok(AgentSegment {
        id: r.get(0)?,
        session_id: r.get(1)?,
        start_ts_ms: r.get(2)?,
        end_ts_ms: r.get(3)?,
        activity: r.get(4)?,
        gap_id: r.get(5)?,
        event_count: r.get(6)?,
    })
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::FleetStore;

    #[test]
    fn open_creates_a_missing_db_parent_directory() {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp
            .path()
            .join("fresh")
            .join(".chump")
            .join("fleet_events.db");

        let store = FleetStore::open(&path).expect("fresh fleet store opens");

        assert!(
            path.is_file(),
            "fleet DB should be created: {}",
            path.display()
        );
        assert!(store.all_session_ids().expect("read fresh db").is_empty());
    }
}
