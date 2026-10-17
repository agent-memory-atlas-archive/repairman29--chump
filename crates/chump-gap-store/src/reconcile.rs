//! INFRA-8222 (Phase R R4 follow-up to INFRA-8190): reconcile a stale gap
//! store into the live repo-local store.
//!
//! Before INFRA-8190 pinned the installer to the repo-local store, sourced
//! sessions on some nodes wrote to `~/.chump/state.db` (node.env pinned
//! `CHUMP_STATE_DB` there) while the fleet wrote to `<repo>/.chump/state.db`.
//! Measured on cuphead 2026-10-17 04:30Z: live store 13499 gaps / 499 open /
//! 20 PHASE-R, stale home store 12787 gaps / 8266 open / 0 PHASE-R. The
//! stale store's opens are old and must not resurrect gaps the live store
//! already closed.
//!
//! `reconcile()` merges the tables in [`MERGED_TABLES`] by primary key:
//!
//! * a row missing in `--into` is inserted;
//! * a row present in both keeps whichever has the newer timestamp
//!   (`updated_at` when both stores carry it, else the max of the row's
//!   timestamp columns); equal timestamps keep `--into`;
//! * **terminal-status guard**: a row whose `--into` status is terminal
//!   (done / shipped / closed / ...) is never overwritten by a non-terminal
//!   `--from` row, whatever the timestamps say. Each refusal is counted;
//! * columns are merged by the intersection of the two stores' column sets
//!   (28 vs 29 columns was seen on closetjunky); extras are reported.
//!
//! The merge never deletes a row. It refuses to run while either store has
//! an active writer unless `force_offline` is set, and backs `--into` up to
//! `<into>.bak-<ts>` (SQLite `VACUUM INTO`) before writing.

use anyhow::{bail, Context, Result};
use rusqlite::types::Value;
use rusqlite::{params_from_iter, Connection, OpenFlags, TransactionBehavior};
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Maximum number of conflict rows written to the audit JSON.
pub const CONFLICT_CAP: usize = 200;

/// Statuses a row never leaves for a non-terminal one during a reconcile.
pub const TERMINAL_STATUSES: &[&str] = &[
    "done",
    "shipped",
    "closed",
    "merged",
    "wontfix",
    "superseded",
    "already_satisfied",
];

/// One table the reconcile merges.
#[derive(Debug, Clone, Copy)]
pub struct TableSpec {
    pub name: &'static str,
    /// Primary-key columns.
    pub pk: &'static [&'static str],
    /// Freshness columns, best first. `updated_at` (when both stores have
    /// it) wins outright; otherwise the max of these is the row's timestamp.
    pub ts_cols: &'static [&'static str],
    /// Status column the terminal-status guard reads, if any.
    pub status_col: Option<&'static str>,
    /// Leases: rows already expired in `--from` are skipped, never imported.
    pub skip_expired: bool,
}

/// Tables merged, in order. Outcome links live on `gaps.outcome_id` and
/// notes on `gaps.notes`, so both ride with the gap row; `gap_prs` carries
/// the typed gap-to-PR links. `gap_counters` merges max-wins on `next_num`
/// so a reserve after the merge can never re-issue an imported ID.
pub const MERGED_TABLES: &[TableSpec] = &[
    TableSpec {
        name: "gaps",
        pk: &["id"],
        ts_cols: &["closed_at", "waiting_since", "created_at"],
        status_col: Some("status"),
        skip_expired: false,
    },
    TableSpec {
        name: "outcomes",
        pk: &["id"],
        ts_cols: &["closed_at", "created_at"],
        status_col: Some("status"),
        skip_expired: false,
    },
    TableSpec {
        name: "gap_prs",
        pk: &["gap_id", "pr_number"],
        ts_cols: &["opened_at"],
        status_col: Some("state"),
        skip_expired: false,
    },
    TableSpec {
        name: "leases",
        pk: &["session_id"],
        ts_cols: &["expires_at"],
        status_col: None,
        skip_expired: true,
    },
    TableSpec {
        name: "gap_counters",
        pk: &["domain"],
        ts_cols: &["next_num"],
        status_col: None,
        skip_expired: false,
    },
];

#[derive(Debug, Clone)]
pub struct ReconcileOptions {
    pub from: PathBuf,
    pub into: PathBuf,
    pub dry_run: bool,
    /// Skip the active-writer refusal.
    pub force_offline: bool,
    /// Do not insert `--from` gaps that are absent from `--into` AND
    /// non-terminal (counted as skipped). Off by default.
    pub skip_new_open: bool,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct TableCounts {
    pub inserted: u64,
    pub updated: u64,
    pub skipped: u64,
    /// Terminal-status guard refusals (would have reopened a closed row).
    pub refused: u64,
    /// Of `inserted`: rows inserted with a non-terminal status.
    pub inserted_nonterminal: u64,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct ColumnDiff {
    pub common: usize,
    pub from_only: Vec<String>,
    pub into_only: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Conflict {
    pub table: String,
    pub key: String,
    pub from_ts: i64,
    pub into_ts: i64,
    pub from_status: Option<String>,
    pub into_status: Option<String>,
    /// `took_from` | `kept_into` | `refused_reopen`.
    pub resolution: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ReconcileReport {
    pub ts: String,
    pub from: String,
    pub into: String,
    pub dry_run: bool,
    pub force_offline: bool,
    pub backup: Option<String>,
    pub tables: BTreeMap<String, TableCounts>,
    pub columns: BTreeMap<String, ColumnDiff>,
    /// Tables in `MERGED_TABLES` missing from one side (not merged).
    pub tables_missing: Vec<String>,
    pub conflicts_total: u64,
    pub conflicts: Vec<Conflict>,
}

impl ReconcileReport {
    pub fn total(&self) -> TableCounts {
        let mut t = TableCounts::default();
        for c in self.tables.values() {
            t.inserted += c.inserted;
            t.updated += c.updated;
            t.skipped += c.skipped;
            t.refused += c.refused;
            t.inserted_nonterminal += c.inserted_nonterminal;
        }
        t
    }

    /// Human summary, one line per table.
    pub fn summary(&self) -> String {
        let mut s = format!(
            "chump store reconcile{}: {} -> {}\n",
            if self.dry_run { " (dry-run)" } else { "" },
            self.from,
            self.into
        );
        for (name, c) in &self.tables {
            s.push_str(&format!(
                "  {name:<13} inserted={} (non-terminal {}) updated={} skipped={} refused_reopen={}\n",
                c.inserted, c.inserted_nonterminal, c.updated, c.skipped, c.refused
            ));
        }
        for (name, d) in &self.columns {
            if !d.from_only.is_empty() || !d.into_only.is_empty() {
                s.push_str(&format!(
                    "  {name}: merged on {} common column(s); from-only {:?}; into-only {:?}\n",
                    d.common, d.from_only, d.into_only
                ));
            }
        }
        for t in &self.tables_missing {
            s.push_str(&format!("  {t}: missing on one side, not merged\n"));
        }
        s.push_str(&format!("  conflicts: {}\n", self.conflicts_total));
        if let Some(b) = &self.backup {
            s.push_str(&format!("  backup: {b}\n"));
        }
        s
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// Normalise a timestamp to unix seconds (millisecond values are divided).
fn norm_secs(n: i64) -> i64 {
    if n > 100_000_000_000 {
        n / 1000
    } else {
        n
    }
}

fn value_ts(v: &Value) -> Option<i64> {
    match v {
        Value::Integer(i) => Some(norm_secs(*i)),
        Value::Real(f) => Some(norm_secs(*f as i64)),
        Value::Text(s) => parse_text_ts(s),
        _ => None,
    }
}

fn parse_text_ts(s: &str) -> Option<i64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    if let Ok(n) = s.parse::<i64>() {
        return Some(norm_secs(n));
    }
    if let Ok(d) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(d.timestamp());
    }
    for fmt in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"] {
        if let Ok(d) = chrono::NaiveDateTime::parse_from_str(s, fmt) {
            return Some(d.and_utc().timestamp());
        }
    }
    None
}

fn value_text(v: &Value) -> Option<String> {
    match v {
        Value::Text(s) => Some(s.clone()),
        Value::Integer(i) => Some(i.to_string()),
        _ => None,
    }
}

/// 2 = terminal, 1 = decomposed (out of the pick pool, not closed), 0 = live.
fn status_rank(s: Option<&str>) -> u8 {
    match s.map(|x| x.trim().to_ascii_lowercase()) {
        Some(x) if TERMINAL_STATUSES.contains(&x.as_str()) => 2,
        Some(x) if x == "decomposed" => 1,
        _ => 0,
    }
}

fn qi(ident: &str) -> String {
    format!("\"{}\"", ident.replace('"', "\"\""))
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool> {
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
        [table],
        |r| r.get(0),
    )?;
    Ok(n > 0)
}

fn table_columns(conn: &Connection, table: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")?;
    let cols = stmt
        .query_map([table], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(cols)
}

fn read_rows(conn: &Connection, table: &str, cols: &[String]) -> Result<Vec<Vec<Value>>> {
    let sql = format!(
        "SELECT {} FROM {}",
        cols.iter().map(|c| qi(c)).collect::<Vec<_>>().join(","),
        qi(table)
    );
    let mut stmt = conn.prepare(&sql)?;
    let n = cols.len();
    let rows = stmt
        .query_map([], |r| {
            (0..n)
                .map(|i| r.get::<_, Value>(i))
                .collect::<rusqlite::Result<Vec<_>>>()
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

fn key_of(row: &[Value], pk_idx: &[usize]) -> String {
    pk_idx
        .iter()
        .map(|&i| match &row[i] {
            Value::Text(s) => s.clone(),
            Value::Integer(n) => n.to_string(),
            other => format!("{other:?}"),
        })
        .collect::<Vec<_>>()
        .join("|")
}

enum Action {
    Insert(Vec<Value>),
    Update(Vec<Value>),
}

struct TablePlan {
    table: &'static str,
    cols: Vec<String>,
    pk_idx: Vec<usize>,
    actions: Vec<Action>,
}

/// Lock directory for a store: `<root>/.chump-locks` when the store lives at
/// `<root>/.chump/state.db`, else `<dir>/.chump-locks`.
pub fn locks_dir_for(db: &Path) -> PathBuf {
    let parent = db.parent().unwrap_or_else(|| Path::new("."));
    if parent.file_name().and_then(|n| n.to_str()) == Some(".chump") {
        parent
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join(".chump-locks")
    } else {
        parent.join(".chump-locks")
    }
}

/// Reasons `db` looks like it has an active writer. Empty means offline.
/// Checks: (1) SQLite write lock (`BEGIN IMMEDIATE` with no busy wait),
/// (2) unexpired rows in its `leases` table, (3) unexpired
/// `.chump-locks/claim-*.json` files next to it.
pub fn active_writer_reasons(db: &Path) -> Vec<String> {
    let mut reasons = Vec::new();
    match Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_WRITE) {
        Ok(conn) => {
            let _ = conn.busy_timeout(std::time::Duration::from_millis(0));
            if let Err(e) = conn.execute_batch("BEGIN IMMEDIATE; ROLLBACK;") {
                reasons.push(format!("sqlite write lock held ({e})"));
            }
            if table_exists(&conn, "leases").unwrap_or(false) {
                let now = now_secs();
                let active: Vec<String> = conn
                    .prepare(
                        "SELECT session_id || ' -> ' || gap_id FROM leases
                         WHERE (CASE WHEN expires_at > 100000000000
                                     THEN expires_at / 1000 ELSE expires_at END) > ?1
                         LIMIT 5",
                    )
                    .and_then(|mut s| {
                        s.query_map([now], |r| r.get::<_, String>(0))?
                            .collect::<rusqlite::Result<Vec<_>>>()
                    })
                    .unwrap_or_default();
                if !active.is_empty() {
                    reasons.push(format!("active lease(s) in store: {}", active.join(", ")));
                }
            }
        }
        Err(e) => reasons.push(format!("cannot open for the write-lock probe ({e})")),
    }
    let locks = locks_dir_for(db);
    if let Ok(entries) = std::fs::read_dir(&locks) {
        let now = now_secs();
        for entry in entries.flatten() {
            let p = entry.path();
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !(name.starts_with("claim-") && name.ends_with(".json")) {
                continue;
            }
            let raw = std::fs::read_to_string(&p).unwrap_or_default();
            let exp = serde_json::from_str::<serde_json::Value>(&raw)
                .ok()
                .and_then(|v| v.get("expires_at").cloned())
                .and_then(|v| match v {
                    serde_json::Value::Number(n) => n.as_i64().map(norm_secs),
                    serde_json::Value::String(s) => parse_text_ts(&s),
                    _ => None,
                });
            let active = match exp {
                Some(t) => t > now,
                // Unparseable expiry: treat as live only if touched in the last hour.
                None => entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|m| m.elapsed().ok())
                    .map(|age| age.as_secs() < 3600)
                    .unwrap_or(false),
            };
            if active {
                reasons.push(format!("active claim file {}", p.display()));
            }
        }
    }
    reasons
}

fn plan_table(
    spec: &TableSpec,
    from: &Connection,
    into: &Connection,
    opts: &ReconcileOptions,
    report: &mut ReconcileReport,
) -> Result<Option<TablePlan>> {
    if !table_exists(from, spec.name)? || !table_exists(into, spec.name)? {
        report.tables_missing.push(spec.name.to_string());
        return Ok(None);
    }
    let from_cols = table_columns(from, spec.name)?;
    let into_cols = table_columns(into, spec.name)?;
    let cols: Vec<String> = into_cols
        .iter()
        .filter(|c| from_cols.contains(c))
        .cloned()
        .collect();
    report.columns.insert(
        spec.name.to_string(),
        ColumnDiff {
            common: cols.len(),
            from_only: from_cols
                .iter()
                .filter(|c| !into_cols.contains(c))
                .cloned()
                .collect(),
            into_only: into_cols
                .iter()
                .filter(|c| !from_cols.contains(c))
                .cloned()
                .collect(),
        },
    );
    let idx = |name: &str| cols.iter().position(|c| c == name);
    let pk_idx: Vec<usize> = spec.pk.iter().filter_map(|p| idx(p)).collect();
    if pk_idx.len() != spec.pk.len() {
        bail!(
            "table {}: primary key {:?} not present in both stores",
            spec.name,
            spec.pk
        );
    }
    let ts_idx: Vec<usize> = if let Some(i) = idx("updated_at") {
        vec![i]
    } else {
        spec.ts_cols.iter().filter_map(|c| idx(c)).collect()
    };
    let status_idx = spec.status_col.and_then(idx);
    let row_ts = |row: &[Value]| -> i64 {
        ts_idx
            .iter()
            .filter_map(|&i| value_ts(&row[i]))
            .max()
            .unwrap_or(0)
    };
    let row_status =
        |row: &[Value]| -> Option<String> { status_idx.and_then(|i| value_text(&row[i])) };

    let into_rows: HashMap<String, Vec<Value>> = read_rows(into, spec.name, &cols)?
        .into_iter()
        .map(|r| (key_of(&r, &pk_idx), r))
        .collect();
    let from_rows = read_rows(from, spec.name, &cols)?;

    let mut counts = TableCounts::default();
    let mut actions = Vec::new();
    let now = now_secs();
    for row in from_rows {
        let key = key_of(&row, &pk_idx);
        let from_ts = row_ts(&row);
        if spec.skip_expired && from_ts <= now {
            counts.skipped += 1;
            continue;
        }
        let from_status = row_status(&row);
        match into_rows.get(&key) {
            None => {
                let nonterminal = status_idx.is_some() && status_rank(from_status.as_deref()) < 2;
                if nonterminal && opts.skip_new_open && spec.name == "gaps" {
                    counts.skipped += 1;
                    continue;
                }
                if nonterminal {
                    counts.inserted_nonterminal += 1;
                }
                counts.inserted += 1;
                actions.push(Action::Insert(row));
            }
            Some(existing) if *existing == row => counts.skipped += 1,
            Some(existing) => {
                let into_ts = row_ts(existing);
                let into_status = row_status(existing);
                let resolution = if from_ts > into_ts {
                    if status_rank(from_status.as_deref()) < status_rank(into_status.as_deref()) {
                        counts.refused += 1;
                        "refused_reopen"
                    } else {
                        counts.updated += 1;
                        actions.push(Action::Update(row));
                        "took_from"
                    }
                } else {
                    // Equal or older: keep --into. Still count a would-be
                    // reopen so the audit shows how many stale opens the
                    // store tried to bring back.
                    if status_rank(from_status.as_deref()) < status_rank(into_status.as_deref()) {
                        counts.refused += 1;
                        "refused_reopen"
                    } else {
                        counts.skipped += 1;
                        "kept_into"
                    }
                };
                report.conflicts_total += 1;
                if report.conflicts.len() < CONFLICT_CAP {
                    report.conflicts.push(Conflict {
                        table: spec.name.to_string(),
                        key,
                        from_ts,
                        into_ts,
                        from_status,
                        into_status,
                        resolution: resolution.to_string(),
                    });
                }
            }
        }
    }
    report.tables.insert(spec.name.to_string(), counts);
    Ok(Some(TablePlan {
        table: spec.name,
        cols,
        pk_idx,
        actions,
    }))
}

fn apply_plan(conn: &mut Connection, plans: &[TablePlan]) -> Result<()> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for plan in plans {
        let col_list = plan
            .cols
            .iter()
            .map(|c| qi(c))
            .collect::<Vec<_>>()
            .join(",");
        let placeholders = (1..=plan.cols.len())
            .map(|i| format!("?{i}"))
            .collect::<Vec<_>>()
            .join(",");
        let insert_sql = format!(
            "INSERT INTO {} ({col_list}) VALUES ({placeholders})",
            qi(plan.table)
        );
        let set_list = plan
            .cols
            .iter()
            .enumerate()
            .filter(|(i, _)| !plan.pk_idx.contains(i))
            .map(|(i, c)| format!("{}=?{}", qi(c), i + 1))
            .collect::<Vec<_>>()
            .join(",");
        let where_list = plan
            .pk_idx
            .iter()
            .map(|&i| format!("{}=?{}", qi(&plan.cols[i]), i + 1))
            .collect::<Vec<_>>()
            .join(" AND ");
        let update_sql = format!(
            "UPDATE {} SET {set_list} WHERE {where_list}",
            qi(plan.table)
        );
        let mut ins = tx.prepare(&insert_sql)?;
        let mut upd = if set_list.is_empty() {
            None
        } else {
            Some(tx.prepare(&update_sql)?)
        };
        for a in &plan.actions {
            match a {
                Action::Insert(row) => {
                    ins.execute(params_from_iter(row.iter()))
                        .with_context(|| format!("insert into {}", plan.table))?;
                }
                Action::Update(row) => {
                    if let Some(u) = upd.as_mut() {
                        u.execute(params_from_iter(row.iter()))
                            .with_context(|| format!("update {}", plan.table))?;
                    }
                }
            }
        }
    }
    tx.commit()?;
    Ok(())
}

/// Merge `opts.from` into `opts.into`. See the module docs for the rules.
/// Returns `Err` (without touching either store) when an active writer is
/// detected and `force_offline` is false.
pub fn reconcile(opts: &ReconcileOptions) -> Result<ReconcileReport> {
    for (label, p) in [("--from", &opts.from), ("--into", &opts.into)] {
        if !p.is_file() {
            bail!("{label} {} is not a file", p.display());
        }
    }
    let same = std::fs::canonicalize(&opts.from).ok() == std::fs::canonicalize(&opts.into).ok();
    if same {
        bail!("--from and --into are the same store");
    }
    if !opts.force_offline {
        let mut reasons = Vec::new();
        for (label, p) in [("--from", &opts.from), ("--into", &opts.into)] {
            for r in active_writer_reasons(p) {
                reasons.push(format!("{label} {}: {r}", p.display()));
            }
        }
        if !reasons.is_empty() {
            bail!(
                "refusing to reconcile while a store has an active writer (stop the fleet, or pass --force-offline):\n  {}",
                reasons.join("\n  ")
            );
        }
    }

    let from = Connection::open_with_flags(&opts.from, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("opening --from {}", opts.from.display()))?;
    let into_flags = if opts.dry_run {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    } else {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    };
    let mut into = Connection::open_with_flags(&opts.into, into_flags)
        .with_context(|| format!("opening --into {}", opts.into.display()))?;
    into.busy_timeout(std::time::Duration::from_secs(5))?;

    let ts = chrono::Utc::now();
    let mut report = ReconcileReport {
        ts: ts.to_rfc3339(),
        from: opts.from.display().to_string(),
        into: opts.into.display().to_string(),
        dry_run: opts.dry_run,
        force_offline: opts.force_offline,
        ..Default::default()
    };
    let mut plans = Vec::new();
    for spec in MERGED_TABLES {
        if let Some(p) = plan_table(spec, &from, &into, opts, &mut report)? {
            plans.push(p);
        }
    }
    drop(from);

    if !opts.dry_run {
        let backup = PathBuf::from(format!(
            "{}.bak-{}",
            opts.into.display(),
            ts.format("%Y%m%dT%H%M%SZ")
        ));
        into.execute(
            &format!(
                "VACUUM INTO '{}'",
                backup.display().to_string().replace('\'', "''")
            ),
            [],
        )
        .with_context(|| format!("backing up --into to {}", backup.display()))?;
        report.backup = Some(backup.display().to_string());
        apply_plan(&mut into, &plans)?;
    }
    Ok(report)
}

/// Write the audit JSON (pretty) to `path`.
pub fn write_audit(report: &ReconcileReport, path: &Path) -> Result<()> {
    let body = serde_json::to_string_pretty(report)?;
    std::fs::write(path, body).with_context(|| format!("writing audit {}", path.display()))
}

/// Append `kind=store_reconciled` to `ambient` (best effort).
pub fn emit_store_reconciled(report: &ReconcileReport, audit: &Path, ambient: &Path) {
    let t = report.total();
    let js = |s: &str| serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into());
    // scanner-anchor (EVENT_REGISTRY.yaml): "kind":"store_reconciled"
    let line = format!(
        "{{\"ts\":{},\"kind\":\"store_reconciled\",\"from\":{},\"into\":{},\"dry_run\":{},\"inserted\":{},\"updated\":{},\"skipped\":{},\"refused\":{},\"conflicts\":{},\"audit\":{}}}\n",
        js(&report.ts),
        js(&report.from),
        js(&report.into),
        report.dry_run,
        t.inserted,
        t.updated,
        t.skipped,
        t.refused,
        report.conflicts_total,
        js(&audit.display().to_string()),
    );
    if let Some(dir) = ambient.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::GapStore;

    /// Build a store with the crate's own migration code; return its db path.
    fn fixture(dir: &Path) -> PathBuf {
        std::fs::create_dir_all(dir).unwrap();
        let store = GapStore::open(dir).unwrap();
        drop(store);
        dir.join(".chump").join("state.db")
    }

    fn put_gap(db: &Path, id: &str, status: &str, created: i64, closed: Option<i64>, title: &str) {
        let c = Connection::open(db).unwrap();
        c.execute(
            "INSERT OR REPLACE INTO gaps (id, domain, title, status, created_at, closed_at)
             VALUES (?1, 'INFRA', ?2, ?3, ?4, ?5)",
            rusqlite::params![id, title, status, created, closed],
        )
        .unwrap();
    }

    fn gap(db: &Path, id: &str) -> Option<(String, String)> {
        let c = Connection::open(db).unwrap();
        c.query_row("SELECT status, title FROM gaps WHERE id=?1", [id], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .ok()
    }

    fn opts(from: &Path, into: &Path, dry_run: bool) -> ReconcileOptions {
        ReconcileOptions {
            from: from.to_path_buf(),
            into: into.to_path_buf(),
            dry_run,
            force_offline: false,
            skip_new_open: false,
        }
    }

    #[test]
    fn inserts_missing_rows() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        put_gap(&from, "INFRA-1", "open", 100, None, "only in stale");
        put_gap(&into, "INFRA-2", "open", 100, None, "only in live");
        let r = reconcile(&opts(&from, &into, false)).unwrap();
        assert_eq!(gap(&into, "INFRA-1").unwrap().1, "only in stale");
        assert!(gap(&into, "INFRA-2").is_some());
        assert_eq!(r.tables["gaps"].inserted, 1);
        assert_eq!(r.tables["gaps"].inserted_nonterminal, 1);
        assert!(r
            .backup
            .as_deref()
            .map(|b| Path::new(b).is_file())
            .unwrap_or(false));
    }

    #[test]
    fn newer_wins_and_equal_keeps_into() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        // from newer (closed later) -> takes from
        put_gap(&from, "INFRA-10", "done", 100, Some(500), "from-newer");
        put_gap(&into, "INFRA-10", "open", 100, None, "into-older");
        // equal timestamps -> keep into
        put_gap(&from, "INFRA-11", "open", 200, None, "from-equal");
        put_gap(&into, "INFRA-11", "open", 200, None, "into-equal");
        // into newer -> keep into
        put_gap(&from, "INFRA-12", "done", 100, Some(300), "from-older");
        put_gap(&into, "INFRA-12", "done", 100, Some(900), "into-newer");
        let r = reconcile(&opts(&from, &into, false)).unwrap();
        assert_eq!(
            gap(&into, "INFRA-10").unwrap(),
            ("done".into(), "from-newer".into())
        );
        assert_eq!(gap(&into, "INFRA-11").unwrap().1, "into-equal");
        assert_eq!(gap(&into, "INFRA-12").unwrap().1, "into-newer");
        assert_eq!(r.tables["gaps"].updated, 1);
        assert_eq!(r.conflicts_total, 3);
    }

    #[test]
    fn terminal_status_guard_refuses_reopen_even_when_newer() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        // Stale open row has a NEWER timestamp than the live done row: the
        // guard must still refuse.
        put_gap(&from, "INFRA-20", "open", 9_000, None, "stale reopen");
        put_gap(&into, "INFRA-20", "done", 100, Some(200), "live done");
        // Older stale open vs live closed: also counted as a refusal.
        put_gap(&from, "INFRA-21", "open", 50, None, "stale open");
        put_gap(&into, "INFRA-21", "closed", 50, Some(300), "live closed");
        let r = reconcile(&opts(&from, &into, false)).unwrap();
        assert_eq!(
            gap(&into, "INFRA-20").unwrap(),
            ("done".into(), "live done".into())
        );
        assert_eq!(gap(&into, "INFRA-21").unwrap().0, "closed");
        assert_eq!(r.tables["gaps"].refused, 2);
        assert_eq!(r.tables["gaps"].updated, 0);
        assert!(r.conflicts.iter().all(|c| c.resolution == "refused_reopen"));
    }

    #[test]
    fn dry_run_leaves_into_untouched() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        put_gap(&from, "INFRA-30", "open", 100, None, "new");
        put_gap(&from, "INFRA-31", "done", 100, Some(500), "newer");
        put_gap(&into, "INFRA-31", "open", 100, None, "older");
        // Checkpoint so the main file holds everything before hashing.
        Connection::open(&into)
            .unwrap()
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .unwrap();
        let before = std::fs::read(&into).unwrap();
        let r = reconcile(&opts(&from, &into, true)).unwrap();
        assert_eq!(r.tables["gaps"].inserted, 1);
        assert_eq!(r.tables["gaps"].updated, 1);
        assert!(r.backup.is_none());
        assert_eq!(std::fs::read(&into).unwrap(), before);
        assert!(gap(&into, "INFRA-30").is_none());
        assert_eq!(gap(&into, "INFRA-31").unwrap().1, "older");
        let baks = std::fs::read_dir(into.parent().unwrap())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".bak-"))
            .count();
        assert_eq!(baks, 0);
    }

    #[test]
    fn merges_on_column_intersection_and_reports_extras() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        // The stale store predates landing_receipt_json (28 vs 29 columns).
        Connection::open(&from)
            .unwrap()
            .execute_batch("ALTER TABLE gaps DROP COLUMN landing_receipt_json;")
            .unwrap();
        put_gap(&from, "INFRA-40", "open", 100, None, "from older schema");
        let r = reconcile(&opts(&from, &into, false)).unwrap();
        let d = &r.columns["gaps"];
        assert_eq!(d.into_only, vec!["landing_receipt_json".to_string()]);
        assert!(d.from_only.is_empty());
        assert_eq!(gap(&into, "INFRA-40").unwrap().1, "from older schema");
    }

    #[test]
    fn refuses_with_active_lease_unless_forced() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        Connection::open(&into)
            .unwrap()
            .execute(
                "INSERT INTO leases (session_id, gap_id, worktree, expires_at) VALUES ('s1','INFRA-1','',?1)",
                [now_secs() + 3600],
            )
            .unwrap();
        let err = reconcile(&opts(&from, &into, true)).unwrap_err();
        assert!(format!("{err:#}").contains("active lease"));
        let mut o = opts(&from, &into, true);
        o.force_offline = true;
        assert!(reconcile(&o).is_ok());
    }

    #[test]
    fn counters_take_max_and_expired_leases_skip() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        let cf = Connection::open(&from).unwrap();
        cf.execute(
            "INSERT OR REPLACE INTO gap_counters VALUES ('INFRA', 900)",
            [],
        )
        .unwrap();
        cf.execute(
            "INSERT INTO leases (session_id, gap_id, worktree, expires_at) VALUES ('old','INFRA-1','',100)",
            [],
        )
        .unwrap();
        drop(cf);
        Connection::open(&into)
            .unwrap()
            .execute(
                "INSERT OR REPLACE INTO gap_counters VALUES ('INFRA', 500)",
                [],
            )
            .unwrap();
        let r = reconcile(&opts(&from, &into, false)).unwrap();
        let n: i64 = Connection::open(&into)
            .unwrap()
            .query_row(
                "SELECT next_num FROM gap_counters WHERE domain='INFRA'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 900);
        assert_eq!(r.tables["leases"].skipped, 1);
        assert_eq!(r.tables["leases"].inserted, 0);
    }

    #[test]
    fn audit_and_emit_write_files() {
        let td = tempfile::tempdir().unwrap();
        let from = fixture(&td.path().join("stale"));
        let into = fixture(&td.path().join("live"));
        put_gap(&from, "INFRA-50", "open", 100, None, "x");
        let r = reconcile(&opts(&from, &into, true)).unwrap();
        let audit = td.path().join("audit.json");
        write_audit(&r, &audit).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&audit).unwrap()).unwrap();
        assert_eq!(v["tables"]["gaps"]["inserted"], 1);
        let amb = locks_dir_for(&into).join("ambient.jsonl");
        emit_store_reconciled(&r, &audit, &amb);
        let line = std::fs::read_to_string(&amb).unwrap();
        let ev: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(ev["kind"], "store_reconciled");
        assert_eq!(ev["dry_run"], true);
    }
}
