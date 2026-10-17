//! Audit log: per-action, per-actor, queryable record of mutations to
//! canonical Chump resources (gaps, PRs, leases, config).
//!
//! Vendored pattern from repairman29/BEAST-MODE at commit
//! cdc4c728df30d2f1174bc7d19192ddb9d6bfcfab,
//! original lib/enterprise/auditLogger.js (CP-010).
//!
//! Departures from upstream:
//!  - SQLite-backed (BEAST-MODE was in-memory only, lost on restart).
//!  - Auto-logging on gap mutations (BEAST-MODE required explicit caller opt-in).
//!  - HTTP-specific fields (ip, userAgent) replaced by CLI-relevant
//!    (harness, session_id).
//!
//! See docs/arsenal/cross-pollination/CP-010-beast-mode-audit-logger.md for
//! the full schema mapping, backing-store rationale, and CLI surface spec.

use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// In-memory ring-buffer cap, mirroring BEAST-MODE's `maxLogs = 10000`. The
/// SQLite table is the durable store (rotation below); this constant bounds
/// the row count a single `query()` call with no `--limit` will hand back to
/// keep CLI output and JSON payloads bounded even on a large table.
pub const MAX_LOGS: u64 = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuditResult {
    Success,
    Failure,
    Partial,
}

impl AuditResult {
    pub fn as_str(&self) -> &'static str {
        match self {
            AuditResult::Success => "success",
            AuditResult::Failure => "failure",
            AuditResult::Partial => "partial",
        }
    }

    fn parse(s: &str) -> Self {
        match s {
            "failure" => AuditResult::Failure,
            "partial" => AuditResult::Partial,
            _ => AuditResult::Success,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub id: String,
    pub action: String,
    pub actor: String,
    pub ts: String, // RFC-3339 UTC, Z-terminated
    pub harness: Option<String>,
    pub resource: Option<String>,
    pub resource_id: Option<String>,
    pub changes: Option<serde_json::Value>,
    pub result: AuditResult,
    pub metadata: serde_json::Value,
    pub gap_id: Option<String>,
    pub session_id: Option<String>,
}

impl AuditEntry {
    /// Builds a new entry with a generated id and current timestamp.
    /// Mirrors BEAST-MODE's `id = audit-${Date.now()}-${rand}` shape.
    pub fn new(actor: &str, action: &str) -> Self {
        let now = chrono::Utc::now();
        let rand_suffix: String = {
            use rand::RngExt;
            let mut rng = rand::rng();
            (0..6)
                .map(|_| {
                    let c = rng.random_range(0..36);
                    std::char::from_digit(c, 36).unwrap_or('0')
                })
                .collect()
        };
        AuditEntry {
            id: format!("audit-{}-{}", now.timestamp_micros(), rand_suffix),
            action: action.to_string(),
            actor: actor.to_string(),
            ts: now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            harness: None,
            resource: None,
            resource_id: None,
            changes: None,
            result: AuditResult::Success,
            metadata: serde_json::json!({}),
            gap_id: None,
            session_id: None,
        }
    }

    pub fn with_resource(mut self, resource: &str, resource_id: &str) -> Self {
        self.resource = Some(resource.to_string());
        self.resource_id = Some(resource_id.to_string());
        self
    }

    pub fn with_changes(mut self, changes: serde_json::Value) -> Self {
        self.changes = Some(changes);
        self
    }

    pub fn with_result(mut self, result: AuditResult) -> Self {
        self.result = result;
        self
    }

    pub fn with_gap_id(mut self, gap_id: &str) -> Self {
        self.gap_id = Some(gap_id.to_string());
        self
    }
}

/// Path to the audit database. Defaults to `<repo_root>/.chump/state.db`
/// (co-located with the gaps table per CP-010's backing-store decision) —
/// override via `CHUMP_STATE_DB` for test isolation, mirroring
/// `GapStore::db_path`.
pub fn db_path(repo_root: &Path) -> PathBuf {
    // INFRA-8190: delegate to the ONE resolver.
    chump_gap_store::store_path::state_db_path(repo_root)
}

pub fn open(repo_root: &Path) -> Result<Connection> {
    let path = db_path(repo_root);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("creating .chump dir for audit_log db")?;
    }
    let conn = Connection::open(&path).context("opening audit_log state.db")?;
    ensure_schema(&conn)?;
    Ok(conn)
}

/// Idempotent schema creation — additive, does not touch the `gaps` table.
/// Safe to call against an existing state.db (CREATE TABLE IF NOT EXISTS).
pub fn ensure_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS audit_log (
            id          TEXT PRIMARY KEY,
            action      TEXT NOT NULL,
            actor       TEXT NOT NULL,
            ts          TEXT NOT NULL,
            harness     TEXT,
            resource    TEXT,
            resource_id TEXT,
            changes     TEXT,
            result      TEXT NOT NULL DEFAULT 'success',
            metadata    TEXT NOT NULL DEFAULT '{}',
            gap_id      TEXT,
            session_id  TEXT
        );
        CREATE INDEX IF NOT EXISTS audit_log_ts_desc ON audit_log(ts DESC);
        CREATE INDEX IF NOT EXISTS audit_log_actor_ts ON audit_log(actor, ts DESC);
        CREATE INDEX IF NOT EXISTS audit_log_action_ts ON audit_log(action, ts DESC);
        CREATE INDEX IF NOT EXISTS audit_log_resource_ts ON audit_log(resource, resource_id, ts DESC);
        "#,
    )
    .context("creating audit_log table/indexes")?;
    Ok(())
}

/// Writes one entry. Idempotent on `id` (INSERT OR REPLACE).
pub fn log_action(conn: &Connection, entry: &AuditEntry) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO audit_log
            (id, action, actor, ts, harness, resource, resource_id, changes, result, metadata, gap_id, session_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            entry.id,
            entry.action,
            entry.actor,
            entry.ts,
            entry.harness,
            entry.resource,
            entry.resource_id,
            entry.changes.as_ref().map(|v| v.to_string()),
            entry.result.as_str(),
            entry.metadata.to_string(),
            entry.gap_id,
            entry.session_id,
        ],
    )
    .context("inserting audit_log row")?;
    Ok(())
}

/// Convenience builder for the common "gap mutation" case.
pub fn log_gap_mutation(
    conn: &Connection,
    actor: &str,
    gap_id: &str,
    action: &str,
    changes: serde_json::Value,
) -> Result<()> {
    let entry = AuditEntry::new(actor, action)
        .with_resource("gap", gap_id)
        .with_gap_id(gap_id)
        .with_changes(changes);
    log_action(conn, &entry)
}

#[derive(Debug, Default, Clone)]
pub struct QueryFilter {
    pub actor: Option<String>,
    pub action: Option<String>,
    pub resource: Option<String>,
    pub resource_id: Option<String>,
    /// RFC-3339 lower bound, inclusive (already resolved from "24h"-style input by the caller).
    pub since: Option<String>,
    pub until: Option<String>,
    pub limit: Option<u64>,
}

pub fn query(conn: &Connection, filter: &QueryFilter) -> Result<Vec<AuditEntry>> {
    let mut sql = String::from(
        "SELECT id, action, actor, ts, harness, resource, resource_id, changes, result, metadata, gap_id, session_id
         FROM audit_log WHERE 1=1",
    );
    let mut binds: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

    if let Some(v) = &filter.actor {
        sql.push_str(" AND actor = ?");
        binds.push(Box::new(v.clone()));
    }
    if let Some(v) = &filter.action {
        sql.push_str(" AND action = ?");
        binds.push(Box::new(v.clone()));
    }
    if let Some(v) = &filter.resource {
        sql.push_str(" AND resource = ?");
        binds.push(Box::new(v.clone()));
    }
    if let Some(v) = &filter.resource_id {
        sql.push_str(" AND resource_id = ?");
        binds.push(Box::new(v.clone()));
    }
    if let Some(v) = &filter.since {
        sql.push_str(" AND ts >= ?");
        binds.push(Box::new(v.clone()));
    }
    if let Some(v) = &filter.until {
        sql.push_str(" AND ts <= ?");
        binds.push(Box::new(v.clone()));
    }
    sql.push_str(" ORDER BY ts DESC LIMIT ?");
    let limit = filter.limit.unwrap_or(100).min(MAX_LOGS);
    binds.push(Box::new(limit as i64));

    let mut stmt = conn.prepare(&sql).context("preparing audit_log query")?;
    let bind_refs: Vec<&dyn rusqlite::ToSql> = binds.iter().map(|b| b.as_ref()).collect();
    let rows = stmt
        .query_map(bind_refs.as_slice(), row_to_entry)
        .context("executing audit_log query")?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.context("reading audit_log row")?);
    }
    Ok(out)
}

fn row_to_entry(row: &rusqlite::Row) -> rusqlite::Result<AuditEntry> {
    let changes_raw: Option<String> = row.get(7)?;
    let metadata_raw: String = row.get(9)?;
    let result_raw: String = row.get(8)?;
    Ok(AuditEntry {
        id: row.get(0)?,
        action: row.get(1)?,
        actor: row.get(2)?,
        ts: row.get(3)?,
        harness: row.get(4)?,
        resource: row.get(5)?,
        resource_id: row.get(6)?,
        changes: changes_raw.and_then(|s| serde_json::from_str(&s).ok()),
        result: AuditResult::parse(&result_raw),
        metadata: serde_json::from_str(&metadata_raw).unwrap_or_else(|_| serde_json::json!({})),
        gap_id: row.get(10)?,
        session_id: row.get(11)?,
    })
}

#[derive(Debug, Serialize)]
pub struct RetentionReport {
    pub removed: u64,
    pub remaining: u64,
}

/// Deletes rows with `ts` older than `cutoff` (RFC-3339, already resolved by
/// the caller from a duration like "90d"). Mirrors BEAST-MODE's
/// `clearLogs(olderThanDays)` — operator-invoked, no automatic rotation.
pub fn clear_older_than(conn: &Connection, cutoff: &str) -> Result<RetentionReport> {
    let removed = conn
        .execute("DELETE FROM audit_log WHERE ts < ?1", params![cutoff])
        .context("deleting old audit_log rows")? as u64;
    let remaining: u64 = conn
        .query_row("SELECT COUNT(*) FROM audit_log", [], |r| r.get(0))
        .context("counting remaining audit_log rows")?;
    Ok(RetentionReport { removed, remaining })
}

/// Resolves a `--since`/`--until`/`--older-than` style argument into an
/// RFC-3339 timestamp string. Accepts relative durations (`24h`, `7d`, `90d`,
/// `1m` meaning 1 minute, `0s`) or an already-RFC-3339/date string, which is
/// passed through unchanged.
pub fn resolve_time_bound(arg: &str) -> Result<String> {
    if let Some(rest) = arg.strip_suffix('s').or_else(|| arg.strip_suffix("sec")) {
        let secs: i64 = rest.parse().context("parsing seconds duration")?;
        return Ok((chrono::Utc::now() - chrono::Duration::seconds(secs))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    }
    if let Some(rest) = arg.strip_suffix('m') {
        let mins: i64 = rest.parse().context("parsing minutes duration")?;
        return Ok((chrono::Utc::now() - chrono::Duration::minutes(mins))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    }
    if let Some(rest) = arg.strip_suffix('h') {
        let hours: i64 = rest.parse().context("parsing hours duration")?;
        return Ok((chrono::Utc::now() - chrono::Duration::hours(hours))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    }
    if let Some(rest) = arg.strip_suffix('d') {
        let days: i64 = rest.parse().context("parsing days duration")?;
        return Ok((chrono::Utc::now() - chrono::Duration::days(days))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    }
    // Already an ISO date/timestamp — pass through.
    Ok(arg.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        ensure_schema(&conn).unwrap();
        conn
    }

    #[test]
    fn log_and_query_by_action() {
        let conn = test_conn();
        log_gap_mutation(
            &conn,
            "alice",
            "INFRA-1",
            "gap.shipped",
            serde_json::json!({}),
        )
        .unwrap();
        log_gap_mutation(
            &conn,
            "bob",
            "INFRA-1",
            "gap.shipped",
            serde_json::json!({}),
        )
        .unwrap();
        log_gap_mutation(
            &conn,
            "alice",
            "INFRA-1",
            "gap.priority_changed",
            serde_json::json!({}),
        )
        .unwrap();

        let shipped = query(
            &conn,
            &QueryFilter {
                action: Some("gap.shipped".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(shipped.len(), 2);

        let alice = query(
            &conn,
            &QueryFilter {
                actor: Some("alice".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(alice.len(), 2);

        let alice_shipped = query(
            &conn,
            &QueryFilter {
                actor: Some("alice".to_string()),
                action: Some("gap.shipped".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(alice_shipped.len(), 1);
    }

    #[test]
    fn retention_sweep_removes_old_rows() {
        let conn = test_conn();
        log_gap_mutation(
            &conn,
            "alice",
            "INFRA-1",
            "gap.shipped",
            serde_json::json!({}),
        )
        .unwrap();
        log_gap_mutation(
            &conn,
            "bob",
            "INFRA-1",
            "gap.shipped",
            serde_json::json!({}),
        )
        .unwrap();

        let future_cutoff = (chrono::Utc::now() + chrono::Duration::seconds(5))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let report = clear_older_than(&conn, &future_cutoff).unwrap();
        assert_eq!(report.removed, 2);
        assert_eq!(report.remaining, 0);
    }

    #[test]
    fn resolve_time_bound_relative() {
        let bound = resolve_time_bound("24h").unwrap();
        // Should be a parseable RFC-3339 timestamp in the past.
        let parsed = chrono::DateTime::parse_from_rfc3339(&bound).unwrap();
        assert!(parsed < chrono::Utc::now());
    }
}
