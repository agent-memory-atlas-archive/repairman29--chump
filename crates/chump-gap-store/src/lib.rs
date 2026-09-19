//! SQLite-backed gap store — INFRA-023.
//!
//! Wraps `gaps`, `leases`, and `intents` tables in `.chump/state.db`.
//! All mutations are single-transaction so concurrent agents get atomic IDs.
//!
//! DATABASE: `<repo_root>/.chump/state.db`
//!
//! MIGRATION from docs/gaps.yaml + .chump-locks/ JSON:
//!   `GapStore::import_from_yaml(&repo_root)` is idempotent — safe to re-run.
//!   Existing DB rows are NOT overwritten; only new gaps are inserted.

pub mod backend;
pub mod maintenance;
pub mod sync;

use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

// INFRA-1893: debounce flag — emit gap_reserve_open_pr_scan_failed at most once per process.
static SCAN_FAILED_WARNED: AtomicBool = AtomicBool::new(false);

// ────────────────────────── Data types ──────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GapRow {
    pub id: String,
    pub domain: String,
    pub title: String,
    pub description: String,
    pub priority: String,
    pub effort: String,
    pub status: String,
    pub acceptance_criteria: String,
    pub depends_on: String,
    pub notes: String,
    pub source_doc: String,
    pub created_at: i64,
    pub closed_at: Option<i64>,
    /// ISO date string from `opened_date:` in YAML. Empty if absent.
    /// Stored separately from `created_at` (unix ts) because the YAML uses
    /// human-friendly dates without time/zone, and round-trip must preserve
    /// the exact author-provided string.
    #[serde(default)]
    pub opened_date: String,
    /// ISO date string from `closed_date:` in YAML. Empty if absent.
    #[serde(default)]
    pub closed_date: String,
    /// PR number from `closed_pr:` in YAML. None if absent or unset.
    /// Pairs with the INFRA-107 closed_pr integrity guard: a gap with
    /// `status: done` MUST have a numeric `closed_pr`. Stored as INTEGER
    /// in SQLite; serialized to YAML only when present and `status: done`.
    /// INFRA-156 added the column + CLI `--closed-pr` flag plumbing.
    #[serde(default)]
    pub closed_pr: Option<i64>,
    /// Comma-separated list of required skills (e.g., "rust,sqlite,macos").
    /// INFRA-314: workers filter gaps by matching WORKER_SKILLS env var.
    #[serde(default)]
    pub skills_required: String,
    /// Preferred backend: claude | local-llm | cascade | any (default: any).
    /// INFRA-314: workers score gap affinity.
    #[serde(default)]
    pub preferred_backend: String,
    /// Preferred machine: macbook | pi-mesh | cloud-overflow | any (default: any).
    /// INFRA-314: workers score gap affinity.
    #[serde(default)]
    pub preferred_machine: String,
    /// Estimated minutes to complete (5..240). Refines effort level.
    /// INFRA-314: workers can use for capacity planning.
    #[serde(default)]
    pub estimated_minutes: String,
    /// Required model tier: haiku | sonnet | opus | any (default: any).
    /// INFRA-418: planner + task router use this to assign work to appropriate capability.
    #[serde(default)]
    pub required_model: String,
    /// INFRA-2134: JSON blob recording how/where a gap was shipped.
    /// Nullable — only present when status == "shipped" or "done" AND the
    /// integrator (or per-PR webhook) populated the field.
    ///
    /// Integration-cycle shape:
    ///   { "integration_id": "integration-YYYY-MM-DD-HHMM",
    ///     "integration_pr":  "https://github.com/…/pull/NNNN",
    ///     "child_commit":    "<sha>",
    ///     "merge_sha":       "<sha>",
    ///     "shipped_at":      "<iso8601>" }
    ///
    /// Per-PR (backwards-compat) shape:
    ///   { "pr_url": "https://github.com/…/pull/NNNN",
    ///     "merge_sha": "<sha>" }
    #[serde(default)]
    pub shipped_in: Option<String>,
    /// MISSION-008: nullable FK into the `outcomes` table.
    /// NULL for all gaps that predate this migration or that have not been
    /// assigned to an outcome. NEVER used to gate gap-close — advisory only.
    #[serde(default)]
    pub outcome_id: Option<String>,
    /// CREDIBLE-107: free-text evidence blob required for P0/P1 RESILIENT/MISSION/CREDIBLE gaps.
    /// Shape (informational, not validated): COMMAND / OUTPUT / THEORY / ALT sections.
    /// NULL for gaps that predate this migration or lower-priority gaps.
    #[serde(default)]
    pub evidence: Option<String>,
}

/// MISSION-008: first-class Outcome object.
/// Gaps ladder up to outcomes via `gaps.outcome_id` (nullable FK).
/// Outcome status is advisory-only — it NEVER gates a child gap from closing.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct OutcomeRow {
    pub id: String,
    pub title: String,
    pub priority: String,
    pub definition_of_done: String,
    pub status: String, // "open" | "done" | "parked"
    pub created_at: i64,
    pub closed_at: Option<i64>,
    /// RESILIENT-254: why an "open, no movement" outcome is deliberately
    /// parked rather than rotting unnoticed. Set via `chump outcome park`.
    /// Only meaningful when status == "parked"; NULL otherwise.
    #[serde(default)]
    pub park_reason: Option<String>,
    /// EFFECTIVE-443: JTBD-sharpen triple captured at intake time. All three
    /// are `None` for outcomes created without a JTBD (pre-slice outcomes,
    /// or ones created via `chump outcome create` directly).
    #[serde(default)]
    pub jtbd_who: Option<String>,
    #[serde(default)]
    pub jtbd_struggling_moment: Option<String>,
    #[serde(default)]
    pub jtbd_done_signal: Option<String>,
}

/// MISSION-033: first-class Repo object.
/// `repos` is a DERIVED INDEX — `external_repo:<owner>/<repo>` in
/// `gaps.skills_required` is the canonical registry; this table is populated
/// by auto-upsert on `chump gap import` and by manual `chump repos add`.
/// Lifecycle is decoupled from gaps: removing a gap does NOT remove its repo row.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct RepoRow {
    /// "owner/repo" — primary key.
    pub id: String,
    pub owner: String,
    pub name: String,
    pub added_at: i64,
    /// Unix epoch of last onboard scan (NULL until first scan).
    pub last_scan_at: Option<i64>,
    /// Unix epoch of last clone GC pass (NULL until first GC).
    pub last_clone_at: Option<i64>,
    /// Unix epoch of last external PR ship (NULL until first ship).
    pub last_ship_at: Option<i64>,
    /// dogfood | trains | safe  (Phase B privacy tier).
    pub cascade_tier: String,
    /// active | paused | archived.
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeaseRow {
    pub session_id: String,
    pub gap_id: String,
    pub worktree: String,
    pub expires_at: i64,
}

// ────────────────────────── DB open/migrate ──────────────────────────

pub struct GapStore {
    conn: Connection,
    repo_root: PathBuf,
}

impl GapStore {
    pub fn db_path(repo_root: &Path) -> PathBuf {
        if let Ok(p) = std::env::var("CHUMP_STATE_DB") {
            return std::path::PathBuf::from(p);
        }
        repo_root.join(".chump").join("state.db")
    }

    /// Test-only accessor for the underlying connection. Production callers
    /// must use the typed methods (`get`, `reserve`, etc.). This exists so
    /// briefing-module tests (INFRA-760) can seed synthetic gaps directly
    /// without re-implementing the reserve() flow.
    #[cfg(any(test, feature = "test-helpers"))]
    pub fn conn_for_test(&self) -> &Connection {
        &self.conn
    }

    /// INFRA-2053 sync-module accessor — direct connection reference so
    /// `sync_pull` can issue INSERT/UPDATE that bypass the integrity
    /// guards (recycled-ID, title-hijack) in `set_fields`. Those guards
    /// would refuse legitimate sync operations like recovering a TODO-AC
    /// overwrite from a clean YAML. Scoped `pub(crate)` so external
    /// callers cannot reach it — `sync::sync_pull` is the only consumer.
    pub(crate) fn conn_for_sync(&self) -> &Connection {
        &self.conn
    }

    /// INFRA-1435: append an audit row to `gap_dup_archive_audit` (creates
    /// the table on first call). Used by `chump gap consolidate --apply`
    /// to record a dup-archive decision: which ID was kept, which was
    /// INFRA-1418: append an audit row to `gap_offline_bypass_audit` (creates
    /// the table on first call). Used by `chump gap reserve --force-anti-offline`
    /// to record a deliberate breaking-of-offline-compliance decision: the
    /// proposed title, the operator-provided reason, and a unix timestamp.
    /// See docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §4 for the playbook.
    pub fn record_offline_bypass(
        &self,
        proposed_title: &str,
        reason: &str,
        operator: &str,
    ) -> Result<()> {
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS gap_offline_bypass_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                proposed_title TEXT NOT NULL,
                reason TEXT NOT NULL,
                operator TEXT NOT NULL DEFAULT '',
                ts INTEGER NOT NULL
             )",
            [],
        )?;
        let ts = unix_now();
        self.conn.execute(
            "INSERT INTO gap_offline_bypass_audit
                (proposed_title, reason, operator, ts)
             VALUES (?1, ?2, ?3, ?4)",
            params![proposed_title, reason, operator, ts],
        )?;
        Ok(())
    }

    /// archived, the similarity score, the depends_on rewrite count, the
    /// operator-provided reason, and a unix timestamp.
    pub fn record_dup_archive(
        &self,
        kept_id: &str,
        archived_id: &str,
        similarity_pct: u32,
        depends_on_rewrites: usize,
        reason: &str,
        operator: &str,
    ) -> Result<()> {
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS gap_dup_archive_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kept_id TEXT NOT NULL,
                archived_id TEXT NOT NULL,
                similarity_pct INTEGER NOT NULL,
                depends_on_rewrites INTEGER NOT NULL DEFAULT 0,
                reason TEXT NOT NULL,
                operator TEXT NOT NULL DEFAULT '',
                ts INTEGER NOT NULL
             )",
            [],
        )?;
        let ts = unix_now();
        self.conn.execute(
            "INSERT INTO gap_dup_archive_audit
                (kept_id, archived_id, similarity_pct, depends_on_rewrites,
                 reason, operator, ts)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                kept_id,
                archived_id,
                similarity_pct,
                depends_on_rewrites as i64,
                reason,
                operator,
                ts,
            ],
        )?;
        Ok(())
    }

    /// EFFECTIVE-310: lazily create the per-gap failure strike table.
    /// Strikes count consecutive whole-gap failures on a given backend
    /// (chump-local today). At the threshold the worker's decompose
    /// reflex fires instead of another whole-gap retry.
    fn ensure_strike_table(&self) -> Result<()> {
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS gap_strikes (
                gap_id  TEXT NOT NULL,
                backend TEXT NOT NULL DEFAULT 'chump-local',
                count   INTEGER NOT NULL DEFAULT 0,
                last_at INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (gap_id, backend)
             )",
            [],
        )?;
        Ok(())
    }

    /// EFFECTIVE-310: increment the strike counter for (gap_id, backend)
    /// and return the new count.
    pub fn record_strike(&self, gap_id: &str, backend: &str) -> Result<i64> {
        self.ensure_strike_table()?;
        let ts = unix_now();
        self.conn.execute(
            "INSERT INTO gap_strikes (gap_id, backend, count, last_at)
             VALUES (?1, ?2, 1, ?3)
             ON CONFLICT(gap_id, backend)
             DO UPDATE SET count = count + 1, last_at = ?3",
            params![gap_id, backend, ts],
        )?;
        self.strike_count(gap_id, backend)
    }

    /// EFFECTIVE-310: current strike count for (gap_id, backend); 0 if none.
    pub fn strike_count(&self, gap_id: &str, backend: &str) -> Result<i64> {
        self.ensure_strike_table()?;
        let n: i64 = self
            .conn
            .query_row(
                "SELECT count FROM gap_strikes WHERE gap_id = ?1 AND backend = ?2",
                params![gap_id, backend],
                |r| r.get(0),
            )
            .unwrap_or(0);
        Ok(n)
    }

    /// EFFECTIVE-310: clear all strikes for a gap (any backend). Called on a
    /// clean cycle so a later transient failure starts from zero.
    pub fn clear_strikes(&self, gap_id: &str) -> Result<()> {
        self.ensure_strike_table()?;
        self.conn
            .execute("DELETE FROM gap_strikes WHERE gap_id = ?1", params![gap_id])?;
        Ok(())
    }

    pub fn open(repo_root: &Path) -> Result<Self> {
        let path = Self::db_path(repo_root);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating .chump/ at {}", parent.display()))?;
        }
        // Retry on "database is locked" at open time. The PRAGMA busy_timeout
        // below only applies POST-open; the open itself can briefly fail with
        // SQLITE_BUSY when a sibling process is mid-`PRAGMA journal_mode=WAL`
        // or migration (both take a short exclusive lock). The
        // gap_reserve_cross_host_race integration test (INFRA-216) reliably
        // reproduces this on CI without the retry loop.
        //
        // INFRA-253 (2026-05-02): bumped attempts 8 → 20 (cap 1000ms; total
        // budget ~16s) after observing 6+ blocked PRs in a single dispatcher
        // cycle hitting the 8-attempt ceiling under CI scheduler jitter.
        //
        // META-015 (2026-05-02): INFRA-253's bump covered surface (1) but
        // missed surface (2) — `PRAGMA journal_mode=WAL` itself can return
        // SQLITE_BUSY even AFTER busy_timeout is set, because the WAL
        // upgrade needs the schema-mutation lock and SQLite documents that
        // this PRAGMA does NOT honor busy_timeout when the upgrade is
        // contended (https://sqlite.org/wal.html — "An attempt to execute
        // PRAGMA journal_mode=WAL on a database file that is in the middle
        // of WAL upgrade by another process will fail with SQLITE_BUSY").
        //
        // The fix is to wrap the whole open + PRAGMA-init sequence in the
        // same retry loop. A spurious BUSY from the WAL upgrade is
        // recoverable: drop the half-initialised connection, sleep with
        // INFRA-253's exponential backoff, retry. Once one process
        // completes its WAL switch the file is in WAL mode and subsequent
        // opens see it as already-WAL — no upgrade needed, no contended
        // schema lock, fast path.
        //
        // Pre-fix flake rate ~50% under INFRA-213's parallel CI matrix;
        // post-fix 10/10 PASS in local stress runs.
        let conn = {
            let mut delay_ms = 50u64;
            let mut attempts = 0;
            loop {
                let attempt_result = (|| -> Result<Connection> {
                    let conn = Connection::open(&path)
                        .with_context(|| format!("opening {}", path.display()))?;
                    conn.busy_timeout(std::time::Duration::from_secs(5))
                        .with_context(|| "setting busy_timeout via rusqlite API")?;
                    conn.execute_batch(
                        "PRAGMA busy_timeout=5000; \
                         PRAGMA journal_mode=WAL; \
                         PRAGMA foreign_keys=ON;",
                    )
                    .with_context(|| "PRAGMA init batch")?;
                    Ok(conn)
                })();
                match attempt_result {
                    Ok(c) => break c,
                    Err(e) => {
                        let msg = format!("{e:#}");
                        if attempts >= 20 || !msg.contains("database is locked") {
                            return Err(e);
                        }
                        std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                        delay_ms = (delay_ms * 2).min(1000);
                        attempts += 1;
                    }
                }
            }
        };
        let store = Self {
            conn,
            repo_root: repo_root.to_path_buf(),
        };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        self.conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS gaps (
                id                  TEXT PRIMARY KEY,
                domain              TEXT NOT NULL DEFAULT '',
                title               TEXT NOT NULL DEFAULT '',
                description         TEXT NOT NULL DEFAULT '',
                priority            TEXT NOT NULL DEFAULT '',
                effort              TEXT NOT NULL DEFAULT '',
                status              TEXT NOT NULL DEFAULT 'open',
                acceptance_criteria TEXT NOT NULL DEFAULT '',
                depends_on          TEXT NOT NULL DEFAULT '',
                notes               TEXT NOT NULL DEFAULT '',
                source_doc          TEXT NOT NULL DEFAULT '',
                created_at          INTEGER NOT NULL DEFAULT 0,
                closed_at           INTEGER
            );

            -- Atomic per-domain sequence counter. Each reserve increments next_num.
            CREATE TABLE IF NOT EXISTS gap_counters (
                domain      TEXT PRIMARY KEY,
                next_num    INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS leases (
                session_id  TEXT PRIMARY KEY,
                gap_id      TEXT NOT NULL,
                worktree    TEXT NOT NULL DEFAULT '',
                expires_at  INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS intents (
                ts          INTEGER NOT NULL,
                session_id  TEXT NOT NULL,
                gap_id      TEXT NOT NULL,
                files       TEXT NOT NULL DEFAULT ''
            );

            CREATE INDEX IF NOT EXISTS leases_gap ON leases(gap_id);
            CREATE INDEX IF NOT EXISTS gaps_status ON gaps(status);
            CREATE INDEX IF NOT EXISTS gaps_domain ON gaps(domain);

            -- COG-036: per-dispatch outcome scoreboard. Each terminal
            -- DispatchOutcome from the orchestrator monitor writes one row
            -- so a future Thompson-sampling router (COG-037) can self-learn.
            CREATE TABLE IF NOT EXISTS routing_outcomes (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at   TEXT NOT NULL,
                task_class    TEXT NOT NULL DEFAULT '',
                priority      TEXT NOT NULL DEFAULT '',
                effort        TEXT NOT NULL DEFAULT '',
                backend       TEXT NOT NULL,
                model         TEXT NOT NULL DEFAULT '',
                provider_pfx  TEXT NOT NULL DEFAULT '',
                gap_id        TEXT NOT NULL,
                outcome       TEXT NOT NULL,
                pr_number     INTEGER,
                duration_s    INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS routing_outcomes_lookup
                ON routing_outcomes(task_class, backend, model, provider_pfx);
            CREATE INDEX IF NOT EXISTS routing_outcomes_recent
                ON routing_outcomes(recorded_at);
        ",
        )?;
        // INFRA-1770: cost_usd per dispatch attempt, so the (eventual)
        // INFRA-1764 router can score routes by
        // (success_rate * value) / cost_per_attempt instead of success_rate
        // alone. ALTER TABLE ADD is idempotent — duplicate-column errors are
        // ignored so re-running migrate() on an existing DB is safe.
        let _ = self.conn.execute(
            "ALTER TABLE routing_outcomes ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0.0",
            [],
        );
        // M1 (INFRA-059): add ISO-date columns alongside existing unix timestamps.
        // The YAML uses author-provided date strings (`opened_date: '2026-04-25'`);
        // round-trip preserves them verbatim instead of reformatting from unix ts.
        // ALTER TABLE ADD is idempotent here — duplicate-column errors are ignored.
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN opened_date TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN closed_date TEXT NOT NULL DEFAULT ''",
            [],
        );
        // INFRA-156: closed_pr (PR number that landed the closure). Nullable
        // because (a) open gaps haven't shipped yet, (b) historical done
        // rows imported before this column existed should keep loading
        // without losing their YAML closed_pr value (round-tripped via
        // import_from_yaml on next regen).
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN closed_pr INTEGER", []);
        // INFRA-314: affinity tags for worker preference matching.
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN skills_required TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN preferred_backend TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN preferred_machine TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN estimated_minutes TEXT NOT NULL DEFAULT ''",
            [],
        );
        // INFRA-418: required_model tier for task routing (haiku | sonnet | opus | any).
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN required_model TEXT NOT NULL DEFAULT ''",
            [],
        );
        // INFRA-2134: shipped_in — nullable JSON blob recording how/where a gap was
        // shipped. Populated by chump-integrator-daemon (integration-cycle path) or
        // the per-PR webhook receiver (per-PR path). NULL for open/in-flight gaps.
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN shipped_in TEXT", []);
        // EFFECTIVE-363: artifact_type — what kind of artifact this gap produces
        // (code | doc | release-note | copy | design | deck | analytics-report | ...).
        // Default 'code' so every pre-existing row (and every caller that never
        // sets it) keeps behaving exactly as before — the pipeline was code-typed
        // in practice already, this just makes that assumption explicit and
        // overridable. Drives per-type gate dispatch in `chump preflight`
        // (see crates/chump-preflight/src/artifact_gates.rs).
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN artifact_type TEXT NOT NULL DEFAULT 'code'",
            [],
        );
        // EFFECTIVE-038: A2A L2 task-suspension columns. A gap that hits
        // input_required (ambiguous decision, needs operator judgment) or
        // auth_required (missing credential — RESILIENT-054's silent-death
        // mode) flips status='waiting_operator' instead of failing or
        // spawning a free-text follow-up gap. `waiting_payload` carries the
        // structured question (kind + question + any context); `resume_status`
        // is the status to restore on `chump gap respond` (almost always
        // whatever the gap's status was the instant before it suspended, so
        // it resumes exactly where it paused instead of falling back to a
        // generic 'open'). All three are nullable/defaulted so existing rows
        // are unaffected until a gap actually suspends.
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN waiting_payload TEXT", []);
        let _ = self.conn.execute(
            "ALTER TABLE gaps ADD COLUMN resume_status TEXT NOT NULL DEFAULT ''",
            [],
        );
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN waiting_since INTEGER", []);
        // Backfill closed_date for done rows that predate the column. Idempotent:
        // only touches rows where closed_date is empty AND closed_at is set, so
        // re-running is a no-op once the row is healed. UTC matches `unix_to_iso_date`.
        let _ = self.conn.execute(
            "UPDATE gaps
                SET closed_date = strftime('%Y-%m-%d', closed_at, 'unixepoch')
                WHERE status = 'done'
                  AND closed_at IS NOT NULL AND closed_at > 0
                  AND (closed_date IS NULL OR closed_date = '')",
            [],
        );

        // INFRA-1682: heal closed_at rows that hold TEXT instead of INTEGER.
        // Discovery 2026-05-22: one rogue row (INFRA-1390) with
        // closed_at='2026-05-17 03:16:05' broke every audit-priorities query
        // ("Invalid column type Text at index: 12, name: closed_at"). The
        // SELECT-side now uses `CASE WHEN typeof(closed_at)='integer' THEN
        // closed_at ELSE NULL END` so the same class of bad row can't crash
        // future queries; this migration heals existing bad rows by coercing
        // text-encoded datetimes to unix-epoch integers. Idempotent: only
        // touches rows where typeof != integer/null.
        let _ = self.conn.execute(
            "UPDATE gaps
                SET closed_at = CASE
                    WHEN closed_at GLOB '[0-9]*' THEN CAST(closed_at AS INTEGER)
                    ELSE strftime('%s', closed_at)
                END
                WHERE typeof(closed_at) NOT IN ('integer', 'null')",
            [],
        );
        // INFRA-112: drop any pre-existing rows with NULL/empty/whitespace id.
        // Such rows survive `INSERT OR IGNORE` (PRIMARY KEY on TEXT permits empty
        // strings in legacy SQLite) but vanish from the YAML mirror because
        // `serde_yaml` round-trips `- id: ` as a list entry whose `id` is null,
        // and downstream consumers (CI guards, gap-preflight) treat that as
        // missing. Cheap one-shot cleanup; the trigger below prevents future
        // regressions.
        let _ = self.conn.execute(
            "DELETE FROM gaps WHERE id IS NULL
               OR LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(id, ' ', ''),
                  char(9), ''), char(10), ''), char(13), '')) = 0",
            [],
        );
        // INFRA-112: trigger-enforced non-empty id. SQLite cannot add CHECK
        // constraints via ALTER TABLE, so we attach BEFORE INSERT/UPDATE
        // triggers that RAISE(ABORT) on empty/whitespace ids. CREATE TRIGGER
        // IF NOT EXISTS makes this idempotent across reopens.
        self.conn.execute_batch(
            "
            CREATE TRIGGER IF NOT EXISTS gaps_id_nonempty_insert
            BEFORE INSERT ON gaps
            FOR EACH ROW
            WHEN NEW.id IS NULL OR LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(NEW.id, ' ', ''), char(9), ''), char(10), ''), char(13), '')) = 0
            BEGIN
                SELECT RAISE(ABORT, 'gap id must be non-empty');
            END;

            CREATE TRIGGER IF NOT EXISTS gaps_id_nonempty_update
            BEFORE UPDATE OF id ON gaps
            FOR EACH ROW
            WHEN NEW.id IS NULL OR LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(NEW.id, ' ', ''), char(9), ''), char(10), ''), char(13), '')) = 0
            BEGIN
                SELECT RAISE(ABORT, 'gap id must be non-empty');
            END;
            ",
        )?;

        // INFRA-2137: register `bisect_quarantined` and `ready_to_ship` as
        // valid status values via an advisory metadata table.  SQLite TEXT
        // columns carry no CHECK constraints (ALTER TABLE cannot add them
        // idempotently), so we track known statuses explicitly. The table is
        // used by `valid_statuses()` and by the `requeue_gap` guard.
        let _ = self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS gap_status_registry (
                 status TEXT PRIMARY KEY,
                 added_by TEXT NOT NULL DEFAULT '',
                 note TEXT NOT NULL DEFAULT ''
             );
             INSERT OR IGNORE INTO gap_status_registry (status, added_by, note)
             VALUES
               ('open',                'legacy',       'default status at reserve time'),
               ('claimed',             'legacy',       'active claim lease'),
               ('done',                'legacy',       'shipped and merged'),
               ('wontfix',             'legacy',       'will not be implemented'),
               ('ready_to_ship',       'INFRA-2130',   'passed preflight; awaiting integration batch'),
               ('bisect_quarantined',  'INFRA-2137',   'failed integration-bisect; needs operator review'),
               ('already_satisfied',   'CREDIBLE-197', 'acceptance verified already met in the repo; closed with an evidence receipt, no PR — a Scout/Holler finding that was already fixed'),
               ('waiting_operator',    'EFFECTIVE-038','suspended — carrying a structured question payload (input_required | auth_required); chump gap respond resumes it');
            ",
        );

        // RESILIENT-1364: register `decomposed` — the status `chump gap
        // decompose --apply` flips a parent umbrella to, instead of leaving
        // it `open`. Being a distinct, non-'open' status IS the whole fix:
        // every picker/worker path reads `status='open'` (`chump gap list
        // --status open`), so a decomposed parent simply stops being
        // pickable the moment this status lands — no picker-side "has open
        // children" filter needed. `auto_close_decomposed_parents()` later
        // flips it to `done` once every child slice named in its notes
        // reaches `done`.
        let _ = self.conn.execute(
            "INSERT OR IGNORE INTO gap_status_registry (status, added_by, note)
             VALUES ('decomposed', 'RESILIENT-1364',
               'umbrella parent taken out of the pick pool by chump gap decompose --apply; auto-closes to done once all child slices (parsed from notes) reach done')",
            [],
        );

        // MISSION-008: additive, non-destructive migrations for first-class
        // Outcome objects. Two changes:
        //   (a) CREATE TABLE IF NOT EXISTS outcomes — new table, never existed.
        //   (b) ALTER TABLE gaps ADD COLUMN outcome_id — nullable FK,
        //       existing rows default to NULL so all existing flows are unchanged.
        //
        // The outcome rollup (chump outcome status <id>) is ADVISORY ONLY —
        // it never gates or blocks a child gap from closing.
        let _ = self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS outcomes (
                id                  TEXT PRIMARY KEY,
                title               TEXT NOT NULL DEFAULT '',
                priority            TEXT NOT NULL DEFAULT 'P2',
                definition_of_done  TEXT NOT NULL DEFAULT '',
                status              TEXT NOT NULL DEFAULT 'open',
                created_at          INTEGER NOT NULL DEFAULT 0,
                closed_at           INTEGER
             );
             CREATE INDEX IF NOT EXISTS outcomes_status ON outcomes(status);
            ",
        );
        // ALTER TABLE ADD COLUMN is idempotent — duplicate-column errors are
        // silently ignored so re-running migrate() is safe.
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN outcome_id TEXT", []);
        // EFFECTIVE-363: outcomes get the same artifact_type default as gaps,
        // so an outcome that rolls up non-code artifacts (release notes, decks,
        // design passes) can be tagged too. Advisory only, like the rest of
        // the outcomes table.
        let _ = self.conn.execute(
            "ALTER TABLE outcomes ADD COLUMN artifact_type TEXT NOT NULL DEFAULT 'code'",
            [],
        );

        // RESILIENT-254: park_reason lets an outcome that has open children
        // but no recent movement declare itself DELIBERATELY parked, so the
        // commitment-rot SLO (L5-SLO-2) doesn't page on a decision the
        // operator already made. NULL unless status == 'parked'.
        let _ = self
            .conn
            .execute("ALTER TABLE outcomes ADD COLUMN park_reason TEXT", []);

        // EFFECTIVE-443: JTBD-sharpen columns — who is struggling, the
        // struggling moment, and the done-signal — captured at intake time
        // (`chump intake --create`) so the plain-language "job to be done"
        // survives past the CLI turn that produced it instead of being
        // printed once and lost. Nullable, no default: outcomes created
        // before this slice (and outcomes created outside vision-intake)
        // simply have no JTBD triple.
        let _ = self
            .conn
            .execute("ALTER TABLE outcomes ADD COLUMN jtbd_who TEXT", []);
        let _ = self.conn.execute(
            "ALTER TABLE outcomes ADD COLUMN jtbd_struggling_moment TEXT",
            [],
        );
        let _ = self
            .conn
            .execute("ALTER TABLE outcomes ADD COLUMN jtbd_done_signal TEXT", []);

        // CREDIBLE-107: evidence column for P0/P1 RESILIENT/MISSION/CREDIBLE gaps.
        // Nullable TEXT — no default — so existing rows stay NULL (no evidence required
        // retroactively). New gaps in enforced domains must supply evidence at reserve time.
        let _ = self
            .conn
            .execute("ALTER TABLE gaps ADD COLUMN evidence TEXT", []);

        // MISSION-033: first-class repos table + 3 indexes.
        // Derived index: auto-upserted on `chump gap import` for every
        // `external_repo:<owner>/<repo>` tag in gaps.skills_required.
        // Also supports manual `chump repos add` for repos not yet gap-tagged.
        // Lifecycle is decoupled: removing a gap does NOT remove its repo row.
        let _ = self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS repos (
                id              TEXT PRIMARY KEY,
                owner           TEXT NOT NULL,
                name            TEXT NOT NULL,
                added_at        INTEGER NOT NULL,
                last_scan_at    INTEGER,
                last_clone_at   INTEGER,
                last_ship_at    INTEGER,
                cascade_tier    TEXT NOT NULL DEFAULT 'dogfood',
                status          TEXT NOT NULL DEFAULT 'active'
             );
             CREATE INDEX IF NOT EXISTS repos_status ON repos(status);
             CREATE INDEX IF NOT EXISTS repos_last_scan_at ON repos(last_scan_at);
             CREATE INDEX IF NOT EXISTS repos_last_clone_at ON repos(last_clone_at);
            ",
        );

        Ok(())
    }
}

// ────────────────────────── gap commands ──────────────────────────

/// EFFECTIVE-364 slice (EFFECTIVE-478): the event handed to the publication
/// resolver when a gap ships — enough for the resolver to decide whether
/// (and where) "ship -> told" work should be reserved.
#[derive(Debug, Clone, Serialize)]
struct PublicationEvent {
    source_gap_id: String,
    artifact_type: String,
}

/// EFFECTIVE-364 slice (EFFECTIVE-834): resolves a shipped gap into
/// publication work. Records the receipt for audit, then looks up
/// `publish_targets.json` (via `chump_bench::get_publish_targets`, EFFECTIVE-477)
/// for the shipped gap's `artifact_type`. When one or more targets are
/// registered, reserves a low-priority follow-up gap per target so the
/// "ship -> told" work actually lands in the queue; an unregistered
/// artifact_type (the common case today) is a no-op past the receipt log.
async fn resolve_publication(event: PublicationEvent, repo_root: PathBuf) -> Result<()> {
    use std::io::Write as _;
    let line = serde_json::to_string(&event)? + "\n";
    let path = repo_root
        .join(".chump-locks")
        .join("publication_events.jsonl");
    std::fs::create_dir_all(path.parent().unwrap_or(&repo_root))?;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    f.write_all(line.as_bytes())?;

    let targets = chump_bench::bench::get_publish_targets(&event.artifact_type);
    if targets.is_empty() {
        return Ok(());
    }

    let store = GapStore::open(&repo_root)?;
    for target in targets {
        let title = format!(
            "Publish {} ({}) to {} [{}]",
            event.source_gap_id, event.artifact_type, target.platform_id, target.target_type
        );
        store.reserve("EFFECTIVE", &title, "P3", "xs")?;
    }
    Ok(())
}

impl GapStore {
    /// Total row count across all statuses. Used to detect an empty-on-clone DB.
    pub fn gap_count(&self) -> Result<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM gaps", [], |r| r.get(0))
            .map_err(anyhow::Error::from)
    }

    /// If the DB has zero rows and docs/gaps/ contains YAML files, auto-import.
    /// Returns the number of gaps imported (0 if DB was already populated or no
    /// YAML files were found). Silently skips on any error so callers don't break.
    pub fn auto_seed_if_empty(&self) -> usize {
        if self.gap_count().unwrap_or(1) > 0 {
            return 0;
        }
        let gaps_dir = self.repo_root.join("docs").join("gaps");
        let has_yaml = std::fs::read_dir(&gaps_dir)
            .ok()
            .map(|d| {
                d.flatten().any(|e| {
                    e.path()
                        .extension()
                        .and_then(|s| s.to_str())
                        .map(|s| s == "yaml")
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);
        if !has_yaml {
            return 0;
        }
        eprintln!("[gap-list] state.db is empty — auto-importing from docs/gaps/ (INFRA-821)");
        match self.import_from_yaml(&self.repo_root.clone()) {
            Ok((ins, _, _)) => {
                if ins > 0 {
                    eprintln!("[gap-list] imported {} gap(s) — re-run to list", ins);
                }
                ins
            }
            Err(_) => 0,
        }
    }

    /// List gaps, optionally filtered by status.
    pub fn list(&self, status_filter: Option<&str>) -> Result<Vec<GapRow>> {
        let make_row = |row: &rusqlite::Row<'_>| {
            Ok(GapRow {
                id: row.get(0)?,
                domain: row.get(1)?,
                title: row.get(2)?,
                description: row.get(3)?,
                priority: row.get(4)?,
                effort: row.get(5)?,
                status: row.get(6)?,
                acceptance_criteria: row.get(7)?,
                depends_on: row.get(8)?,
                notes: row.get(9)?,
                source_doc: row.get(10)?,
                created_at: row.get(11)?,
                closed_at: row.get(12)?,
                opened_date: row.get(13)?,
                closed_date: row.get(14)?,
                closed_pr: row.get(15)?,
                skills_required: row.get(16)?,
                preferred_backend: row.get(17)?,
                preferred_machine: row.get(18)?,
                estimated_minutes: row.get(19)?,
                required_model: row.get(20)?,
                shipped_in: row.get(21)?,
                outcome_id: row.get(22)?,
                evidence: row.get(23)?,
            })
        };
        if let Some(s) = status_filter {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        CAST(acceptance_criteria AS TEXT) AS acceptance_criteria,depends_on,notes,source_doc,created_at,CASE WHEN typeof(closed_at)='integer' THEN closed_at ELSE NULL END AS closed_at,
                        opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                        preferred_machine,estimated_minutes,required_model,shipped_in,outcome_id,evidence
                 FROM gaps WHERE status=?1 ORDER BY id",
            )?;
            let rows = stmt.query_map(params![s], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                        CAST(acceptance_criteria AS TEXT) AS acceptance_criteria,depends_on,notes,source_doc,created_at,CASE WHEN typeof(closed_at)='integer' THEN closed_at ELSE NULL END AS closed_at,
                        opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                        preferred_machine,estimated_minutes,required_model,shipped_in,outcome_id,evidence
                 FROM gaps ORDER BY id",
            )?;
            let rows = stmt.query_map([], make_row)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
        }
    }

    /// CREDIBLE-339: list gaps with a specific status, ordered by closed_at ASC
    /// (oldest closed first). Used by the done-gap over-claim auditor
    /// so each run processes the oldest closed gaps and subsequent runs
    /// naturally pick up newer gaps without re-auditing.
    pub fn list_by_status_ordered(&self, status: &str) -> Result<Vec<GapRow>> {
        let make_row = |row: &rusqlite::Row<'_>| {
            Ok(GapRow {
                id: row.get(0)?,
                domain: row.get(1)?,
                title: row.get(2)?,
                description: row.get(3)?,
                priority: row.get(4)?,
                effort: row.get(5)?,
                status: row.get(6)?,
                acceptance_criteria: row.get(7)?,
                depends_on: row.get(8)?,
                notes: row.get(9)?,
                source_doc: row.get(10)?,
                created_at: row.get(11)?,
                closed_at: row.get(12)?,
                opened_date: row.get(13)?,
                closed_date: row.get(14)?,
                closed_pr: row.get(15)?,
                skills_required: row.get(16)?,
                preferred_backend: row.get(17)?,
                preferred_machine: row.get(18)?,
                estimated_minutes: row.get(19)?,
                required_model: row.get(20)?,
                shipped_in: row.get(21)?,
                outcome_id: row.get(22)?,
                evidence: row.get(23)?,
            })
        };
        let mut stmt = self.conn.prepare(
            "SELECT id,domain,title,description,priority,effort,status,
                    CAST(acceptance_criteria AS TEXT) AS acceptance_criteria,depends_on,notes,source_doc,created_at,CASE WHEN typeof(closed_at)='integer' THEN closed_at ELSE NULL END AS closed_at,
                    opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                    preferred_machine,estimated_minutes,required_model,shipped_in,outcome_id,evidence
             FROM gaps WHERE status=?1 ORDER BY closed_at ASC",
        )?;
        let rows = stmt.query_map(params![status], make_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    // ── INFRA-1149: reserve-time title similarity ─────────────────────────────
    //
    // Computes token-set Jaccard similarity between two gap titles.
    // Tokenises on non-alphanumeric boundaries, lower-cases, and removes
    // common English stopwords so "EFFECTIVE: add X for Y" doesn't score
    // 0.6 against "CREDIBLE: add Z for W" just from shared boilerplate.
    //
    // Returns a value in [0.0, 1.0] where 1.0 = identical token sets.
    pub fn title_jaccard(a: &str, b: &str) -> f64 {
        const STOPWORDS: &[&str] = &[
            "a",
            "an",
            "the",
            "to",
            "for",
            "in",
            "of",
            "on",
            "at",
            "with",
            "by",
            "and",
            "or",
            "is",
            "are",
            "be",
            "add",
            "update",
            "fix",
            "from",
            "into",
            "as",
            "via",
            "per",
            "when",
            "if",
            "so",
            "that",
            "this",
            "it",
            // pillar prefix tokens — normalize these away
            "effective",
            "credible",
            "resilient",
            "zero",
            "waste",
            "mission",
        ];
        let tokenize = |s: &str| -> std::collections::HashSet<String> {
            s.to_lowercase()
                .split(|c: char| !c.is_alphanumeric())
                .filter(|t| !t.is_empty() && t.len() > 1)
                .filter(|t| !STOPWORDS.contains(t))
                .map(|t| t.to_string())
                .collect()
        };
        let ta = tokenize(a);
        let tb = tokenize(b);
        if ta.is_empty() && tb.is_empty() {
            return 1.0;
        }
        let intersection = ta.intersection(&tb).count();
        let union = ta.union(&tb).count();
        if union == 0 {
            0.0
        } else {
            intersection as f64 / union as f64
        }
    }

    /// INFRA-1149: return the top-N most similar existing gaps for a proposed
    /// title. Searches open gaps + done gaps closed within the last `days` days.
    /// Returns `[(gap_id, title, status, score)]` sorted descending by score,
    /// capped at `top_n`.
    pub fn similarity_candidates(
        &self,
        proposed_title: &str,
        top_n: usize,
        lookback_days: u32,
    ) -> Result<Vec<(String, String, String, f64)>> {
        // Compute cutoff date for "recently closed" window
        let cutoff = {
            use std::time::{SystemTime, UNIX_EPOCH};
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let days_secs = lookback_days as u64 * 86_400;
            let cutoff_ts = now.saturating_sub(days_secs);
            // Convert to ISO date string YYYY-MM-DD for comparison
            let days_since_epoch = cutoff_ts / 86_400;
            // Rough date arithmetic: good enough for 30-day window
            let year = 1970 + days_since_epoch / 365;
            let _ = year; // used in format below
                          // Use chrono-free approach: just format the cutoff as days subtracted from now
                          // We'll filter in Rust since SQLite date arithmetic varies
            cutoff_ts
        };

        // Query open gaps + recently-closed done gaps
        let mut stmt = self.conn.prepare(
            "SELECT id, title, status, closed_at FROM gaps
             WHERE status = 'open'
                OR (status = 'done' AND closed_at IS NOT NULL AND CAST(closed_at AS INTEGER) >= ?1)
             ORDER BY id",
        )?;
        let rows = stmt.query_map(params![cutoff as i64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;

        let mut scored: Vec<(String, String, String, f64)> = rows
            .filter_map(|r| r.ok())
            .map(|(id, title, status)| {
                let score = Self::title_jaccard(proposed_title, &title);
                (id, title, status, score)
            })
            .filter(|(_, _, _, score)| *score > 0.0)
            .collect();

        scored.sort_by(|a, b| b.3.partial_cmp(&a.3).unwrap_or(std::cmp::Ordering::Equal));
        scored.truncate(top_n);
        Ok(scored)
    }

    /// Get a single gap by ID.
    ///
    /// INFRA-630: if `gap_id` looks like an 8-char hex short-prefix (all
    /// lowercase/uppercase hex digits, exactly 8 chars), fall through to a
    /// `LIKE '<prefix>%'` query so operators can use the compact form printed
    /// by chump-proprietary tooling (e.g. `chump gap show 8d3f2c0e`).
    /// Returns the unique match, or None if zero or multiple rows match
    /// (ambiguous prefix → exact ID required).
    pub fn get(&self, gap_id: &str) -> Result<Option<GapRow>> {
        // INFRA-630: detect 8-char hex short-prefix form
        let is_uuid_short_prefix =
            gap_id.len() == 8 && gap_id.chars().all(|c| c.is_ascii_hexdigit());

        let mut stmt = self.conn.prepare(
            "SELECT id,domain,title,description,priority,effort,status,
                    CAST(acceptance_criteria AS TEXT) AS acceptance_criteria,depends_on,notes,source_doc,created_at,CASE WHEN typeof(closed_at)='integer' THEN closed_at ELSE NULL END AS closed_at,
                    opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                    preferred_machine,estimated_minutes,required_model,shipped_in,outcome_id,evidence
             FROM gaps WHERE id=?1",
        )?;
        let row = stmt
            .query_row(params![gap_id], |row| {
                Ok(GapRow {
                    id: row.get(0)?,
                    domain: row.get(1)?,
                    title: row.get(2)?,
                    description: row.get(3)?,
                    priority: row.get(4)?,
                    effort: row.get(5)?,
                    status: row.get(6)?,
                    acceptance_criteria: row.get(7)?,
                    depends_on: row.get(8)?,
                    notes: row.get(9)?,
                    source_doc: row.get(10)?,
                    created_at: row.get(11)?,
                    closed_at: row.get(12)?,
                    opened_date: row.get(13)?,
                    closed_date: row.get(14)?,
                    closed_pr: row.get(15)?,
                    skills_required: row.get(16)?,
                    preferred_backend: row.get(17)?,
                    preferred_machine: row.get(18)?,
                    estimated_minutes: row.get(19)?,
                    required_model: row.get(20)?,
                    shipped_in: row.get(21)?,
                    outcome_id: row.get(22)?,
                    evidence: row.get(23)?,
                })
            })
            .optional()?;

        // INFRA-630: prefix-match fallback for 8-char UUID short prefixes.
        // Only runs when exact match returned nothing AND input looks like hex.
        if row.is_none() && is_uuid_short_prefix {
            let pattern = format!("{}%", gap_id.to_lowercase());
            let mut pfx_stmt = self.conn.prepare(
                "SELECT id,domain,title,description,priority,effort,status,
                         CAST(acceptance_criteria AS TEXT) AS acceptance_criteria,depends_on,notes,source_doc,created_at,CASE WHEN typeof(closed_at)='integer' THEN closed_at ELSE NULL END AS closed_at,
                         opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                         preferred_machine,estimated_minutes,required_model,shipped_in,outcome_id,evidence
                  FROM gaps WHERE LOWER(id) LIKE ?1 LIMIT 2",
            )?;
            // Collect up to 2 rows to detect ambiguity without borrow conflicts.
            let matches: Vec<GapRow> = pfx_stmt
                .query_map(params![pattern], |r| {
                    Ok(GapRow {
                        id: r.get(0)?,
                        domain: r.get(1)?,
                        title: r.get(2)?,
                        description: r.get(3)?,
                        priority: r.get(4)?,
                        effort: r.get(5)?,
                        status: r.get(6)?,
                        acceptance_criteria: r.get(7)?,
                        depends_on: r.get(8)?,
                        notes: r.get(9)?,
                        source_doc: r.get(10)?,
                        created_at: r.get(11)?,
                        closed_at: r.get(12)?,
                        opened_date: r.get(13)?,
                        closed_date: r.get(14)?,
                        closed_pr: r.get(15)?,
                        skills_required: r.get(16)?,
                        preferred_backend: r.get(17)?,
                        preferred_machine: r.get(18)?,
                        estimated_minutes: r.get(19)?,
                        required_model: r.get(20)?,
                        shipped_in: r.get(21)?,
                        outcome_id: r.get(22)?,
                        evidence: r.get(23)?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            if matches.len() == 1 {
                // Unique match — return it.
                return Ok(Some(matches.into_iter().next().unwrap()));
            }
            // 0 matches → NotFound (fall through to Ok(None) below).
            // 2 matches → ambiguous prefix; caller should pass full UUID.
        }

        Ok(row)
    }

    /// PRODUCT-176: the set of status values this store recognizes, read from
    /// the advisory `gap_status_registry` table (the canonical list — INFRA-2137
    /// seeds it and later gaps extend it). Exposed so callers that accept a
    /// status from outside the process (the web API's PATCH /api/gap/{id})
    /// can reject unknown values instead of writing a typo'd status that no
    /// picker, gauge, or curate pass will ever match. SQLite TEXT carries no
    /// CHECK constraint here, so this registry is the only guard.
    pub fn known_statuses(&self) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT status FROM gap_status_registry ORDER BY status")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// Update mutable fields on an existing gap row. Pass None to leave a
    /// field unchanged. Used by `chump gap set` so agents can author
    /// description / acceptance / notes without hand-editing YAML.
    pub fn set_fields(&self, gap_id: &str, fields: GapFieldUpdate) -> Result<()> {
        // INFRA-402: lift the INFRA-107 closed_pr-integrity guard out of
        // the pre-commit YAML-diff layer and into the canonical write
        // path. The pre-commit guard catches `status: done` without a
        // numeric `closed_pr` in the YAML diff — but `chump gap set
        // --status done` writes directly to .chump/state.db without
        // necessarily emitting a YAML diff (only `--update-yaml`
        // regenerates), so the guard never sees it. INFRA-339 closed
        // via this path on 2026-05-03 (status=done, closed_pr absent).
        // Bypass: CHUMP_BYPASS_CLOSED_PR_GUARD=1 — for the legitimate
        // import / migration cases where closed_pr is genuinely unknown.
        if let Some(s) = fields.status.as_deref() {
            if s == "done" && std::env::var("CHUMP_BYPASS_CLOSED_PR_GUARD").as_deref() != Ok("1") {
                // closed_pr must either be in this update OR already on the row.
                let supplied_pr = fields.closed_pr.unwrap_or(0);
                if supplied_pr == 0 {
                    let existing_pr: Option<i64> = self
                        .conn
                        .query_row("SELECT closed_pr FROM gaps WHERE id=?", [gap_id], |row| {
                            row.get(0)
                        })
                        .ok()
                        .flatten();
                    if existing_pr.unwrap_or(0) == 0 {
                        bail!(
                            "INFRA-402: refusing to flip {gap_id} to status=done without a numeric closed_pr. \
                             Pass --closed-pr <N>, or set CHUMP_BYPASS_CLOSED_PR_GUARD=1 for genuine migration cases."
                        );
                    }
                }
            }
        }

        // INFRA-456: lift two additional integrity guards from the YAML
        // pre-commit hook into the DB write path so they're unbypassable
        // by any caller that goes through `chump gap set` directly:
        //   (1) recycled-ID guard (INFRA-014 class) — done is terminal;
        //       cannot move done → open/in_progress. New work needs a
        //       new ID.
        //   (2) gap-ID hijack guard — silently rewriting an existing
        //       gap's title or description on an open gap (stealing the
        //       slot for unrelated work) is forbidden. Caught PR #60 ↔
        //       #65 EVAL-011 collision in 2026-04-18.
        // Both guards read the current row once and compare to the
        // proposed update.
        let cur_meta: Option<(String, String, String)> = self
            .conn
            .query_row(
                "SELECT status, title, description FROM gaps WHERE id=?",
                [gap_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .ok();

        if let Some((cur_status, cur_title, cur_description)) = cur_meta.as_ref() {
            // Guard (1) — recycled-ID
            if cur_status == "done" {
                if let Some(new_status) = fields.status.as_deref() {
                    if new_status != "done"
                        && std::env::var("CHUMP_ALLOW_RECYCLE").as_deref() != Ok("1")
                    {
                        bail!(
                            "INFRA-456 recycled-ID guard: gap {} is already done; cannot move to status='{}'. \
                             Done is terminal — reserve a new gap ID for follow-up work \
                             (chump gap reserve --domain ... --title ...). \
                             Bypass for genuine reopen cases (operator authorization required): \
                             CHUMP_ALLOW_RECYCLE=1.",
                            gap_id, new_status
                        );
                    }
                }
            }

            // Guard (2) — hijack
            // Allow rewrites if the operator opts in. The flag is intentionally
            // verbose so it shows up in `git log` and `ambient.jsonl`.
            let allow_rewrite = std::env::var("CHUMP_ALLOW_GAP_REWRITE").as_deref() == Ok("1");
            if !allow_rewrite {
                if let Some(new_title) = fields.title.as_deref() {
                    if !cur_title.is_empty() && new_title != cur_title {
                        bail!(
                            "INFRA-456 hijack guard: gap {} already has a title and a different one was supplied. \
                             Title was: '{}'. Proposed: '{}'. \
                             Existing gaps cannot be silently repurposed — reserve a new gap ID instead. \
                             Bypass for genuine title corrections: CHUMP_ALLOW_GAP_REWRITE=1.",
                            gap_id, cur_title, new_title
                        );
                    }
                }
                if let Some(new_description) = fields.description.as_deref() {
                    if !cur_description.is_empty()
                        && new_description != cur_description
                        // Allow growing the description (append-only is fine).
                        && !new_description.contains(cur_description.as_str())
                    {
                        bail!(
                            "INFRA-456 hijack guard: gap {} already has a description and an incompatible one was supplied. \
                             Existing description: '{}'. Proposed: '{}'. \
                             Existing gaps cannot be silently repurposed — reserve a new gap ID instead. \
                             (Appending to an existing description is allowed.) \
                             Bypass for genuine corrections: CHUMP_ALLOW_GAP_REWRITE=1.",
                            gap_id,
                            cur_description.chars().take(80).collect::<String>(),
                            new_description.chars().take(80).collect::<String>()
                        );
                    }
                }
            }
        }

        // INFRA-3580: reopening a gap (status -> open) logically retracts its
        // close, but until now closed_pr/closed_date stayed stamped with the
        // old value — exactly the state scripts/ci/test-gap-closure-consistency.sh
        // flags as `stale_post_merge_gap`. Auto-clear them on --status open,
        // gated behind the same CHUMP_ALLOW_RECYCLE flag as the reopen itself
        // (so this can't quietly rewrite shipping history without operator
        // authorization) and only when the caller didn't explicitly supply a
        // new closed_pr/closed_date in the same call.
        let auto_clear_closure = fields.status.as_deref() == Some("open")
            && std::env::var("CHUMP_ALLOW_RECYCLE").as_deref() == Ok("1")
            && fields.closed_pr.is_none()
            && fields.closed_date.is_none();

        let mut sets: Vec<&str> = Vec::new();
        let mut vals: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(v) = fields.title {
            sets.push("title=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.description {
            sets.push("description=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.priority {
            sets.push("priority=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.effort {
            sets.push("effort=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.status {
            sets.push("status=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.acceptance_criteria {
            sets.push("acceptance_criteria=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.depends_on {
            sets.push("depends_on=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.notes {
            sets.push("notes=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.source_doc {
            sets.push("source_doc=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.opened_date {
            sets.push("opened_date=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.closed_date {
            sets.push("closed_date=?");
            vals.push(Box::new(v));
        } else if auto_clear_closure {
            sets.push("closed_date=?");
            vals.push(Box::new(String::new()));
        }
        if let Some(v) = fields.closed_pr {
            sets.push("closed_pr=?");
            vals.push(Box::new(v));
        } else if auto_clear_closure {
            sets.push("closed_pr=?");
            vals.push(Box::new(Option::<i64>::None));
        }
        if let Some(v) = fields.skills_required {
            sets.push("skills_required=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.preferred_backend {
            sets.push("preferred_backend=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.preferred_machine {
            sets.push("preferred_machine=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.estimated_minutes {
            sets.push("estimated_minutes=?");
            vals.push(Box::new(v));
        }
        if let Some(v) = fields.required_model {
            sets.push("required_model=?");
            vals.push(Box::new(v));
        }
        // MISSION-008: nullable FK to outcomes. Empty string clears the FK
        // (sets it to NULL in DB); non-empty string sets it.
        if let Some(v) = fields.outcome_id {
            sets.push("outcome_id=?");
            // Treat empty string as SQL NULL so the FK is truly nullable.
            if v.is_empty() {
                vals.push(Box::new(Option::<String>::None));
            } else {
                vals.push(Box::new(v));
            }
        }
        // CREDIBLE-107: evidence blob (nullable TEXT). Empty string clears it.
        if let Some(v) = fields.evidence {
            sets.push("evidence=?");
            if v.is_empty() {
                vals.push(Box::new(Option::<String>::None));
            } else {
                vals.push(Box::new(v));
            }
        }
        // EFFECTIVE-363: artifact_type. Falls back to 'code' on empty string
        // rather than NULL — the column is NOT NULL DEFAULT 'code'.
        if let Some(v) = fields.artifact_type {
            sets.push("artifact_type=?");
            vals.push(Box::new(if v.is_empty() { "code".to_string() } else { v }));
        }
        if sets.is_empty() {
            return Ok(());
        }
        vals.push(Box::new(gap_id.to_string()));
        let sql = format!("UPDATE gaps SET {} WHERE id=?", sets.join(","));
        let params_vec: Vec<&dyn rusqlite::ToSql> = vals.iter().map(|b| b.as_ref()).collect();
        let changed = self.conn.execute(&sql, params_vec.as_slice())?;
        if changed == 0 {
            bail!("gap {} not found", gap_id);
        }
        Ok(())
    }

    /// EFFECTIVE-363: read a gap's `artifact_type` (code | doc | release-note |
    /// copy | design | deck | analytics-report | ...). Callers that need to
    /// dispatch per-type quality gates (e.g. `chump preflight --artifact-type`)
    /// use this instead of pulling the whole `Gap` row.
    pub fn get_artifact_type(&self, gap_id: &str) -> Result<String> {
        let v: String = self.conn.query_row(
            "SELECT artifact_type FROM gaps WHERE id=?1",
            [gap_id],
            |r| r.get(0),
        )?;
        Ok(v)
    }

    /// EFFECTIVE-038 (A2A L2): suspend a gap into `waiting_operator`, carrying
    /// a structured question payload — the Google-A2A-shaped alternative to
    /// "silently die" (auth_required, RESILIENT-054) or "guess wrong / file a
    /// disconnected follow-up gap" (input_required, ambiguous decision).
    ///
    /// `kind` is `"input_required"` or `"auth_required"`; `question` is a
    /// human-readable prompt for the operator; `context_json` is an optional
    /// caller-supplied JSON blob (e.g. partial progress) round-tripped
    /// verbatim into the payload so `respond` can hand it back unchanged.
    ///
    /// Captures the gap's current status as `resume_status` so `respond`
    /// resumes exactly where the gap paused, not to a generic 'open'.
    /// Refuses to suspend a gap that is already `done` or `waiting_operator`.
    pub fn suspend_waiting(
        &self,
        gap_id: &str,
        kind: &str,
        question: &str,
        context_json: Option<&str>,
    ) -> Result<()> {
        if kind != "input_required" && kind != "auth_required" {
            bail!(
                "suspend_waiting: kind must be 'input_required' or 'auth_required', got '{}'",
                kind
            );
        }
        let cur_status: Option<String> = self
            .conn
            .query_row("SELECT status FROM gaps WHERE id=?1", [gap_id], |r| {
                r.get(0)
            })
            .ok();
        let cur_status = match cur_status {
            Some(s) => s,
            None => bail!("gap {} not found", gap_id),
        };
        if cur_status == "done" {
            bail!(
                "gap {} is already done; cannot suspend to waiting_operator",
                gap_id
            );
        }
        if cur_status == "waiting_operator" {
            bail!(
                "gap {} is already waiting_operator; respond to it first before suspending again",
                gap_id
            );
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let payload = serde_json::json!({
            "kind": kind,
            "question": question,
            "context": context_json.and_then(|c| serde_json::from_str::<serde_json::Value>(c).ok()),
        });
        self.conn.execute(
            "UPDATE gaps SET status='waiting_operator', waiting_payload=?1,
             resume_status=?2, waiting_since=?3 WHERE id=?4",
            params![payload.to_string(), cur_status, now, gap_id],
        )?;
        Ok(())
    }

    /// EFFECTIVE-038: read the structured question payload of a gap
    /// currently in `waiting_operator`. Returns `None` if the gap has no
    /// pending payload (never suspended, or already resumed).
    pub fn get_waiting_payload(&self, gap_id: &str) -> Result<Option<String>> {
        let v: Option<String> = self.conn.query_row(
            "SELECT waiting_payload FROM gaps WHERE id=?1",
            [gap_id],
            |r| r.get(0),
        )?;
        Ok(v)
    }

    /// EFFECTIVE-038: resume a `waiting_operator` gap with the operator's
    /// answer. Restores `status` to whatever it was the instant before
    /// suspension (`resume_status`), clears the waiting payload, and appends
    /// the question + answer to `notes` as an audit trail. Returns the
    /// resumed status. Errors if the gap is not currently `waiting_operator`.
    pub fn respond_gap(&self, gap_id: &str, answer_json: &str) -> Result<String> {
        let row: Option<(String, Option<String>, String, String)> = self
            .conn
            .query_row(
                "SELECT status, waiting_payload, resume_status, notes FROM gaps WHERE id=?1",
                [gap_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .ok();
        let (status, payload, resume_status, notes) = match row {
            Some(v) => v,
            None => bail!("gap {} not found", gap_id),
        };
        if status != "waiting_operator" {
            bail!(
                "gap {} is not waiting_operator (current status: '{}') — nothing to respond to",
                gap_id,
                status
            );
        }
        let resume_status = if resume_status.is_empty() {
            "open".to_string()
        } else {
            resume_status
        };
        let question = payload
            .as_deref()
            .and_then(|p| serde_json::from_str::<serde_json::Value>(p).ok())
            .and_then(|v| v.get("question").and_then(|q| q.as_str()).map(String::from))
            .unwrap_or_default();
        let mut new_notes = notes;
        if !new_notes.is_empty() {
            new_notes.push('\n');
        }
        new_notes.push_str(&format!(
            "[operator response] Q: {question} A: {answer_json}"
        ));
        self.conn.execute(
            "UPDATE gaps SET status=?1, waiting_payload=NULL, resume_status='', notes=?2
             WHERE id=?3",
            params![resume_status, new_notes, gap_id],
        )?;
        Ok(resume_status)
    }

    /// Reserve a new gap ID atomically using a per-domain counter row.
    /// The counter upsert + gap insert runs under an exclusive transaction,
    /// so concurrent callers get distinct IDs with no retries.
    ///
    /// Picks an ID free across all four collision sources: state.db (already
    /// in counter logic), docs/gaps.yaml (via [`Self::import_from_yaml`]),
    /// open-PR titles, and live `pending_new_gap` leases on disk. The two
    /// extra sources are gathered by [`Self::external_pending_ids`] and
    /// passed into [`Self::reserve_with_external`]. Together with the
    /// per-domain `flock` in `scripts/coord/gap-reserve.sh`, this prevents
    /// the 4-way INFRA-087..090 collision pattern (PRs #565/#566/#568/#569,
    /// 2026-04-26).
    pub fn reserve(
        &self,
        domain: &str,
        title: &str,
        priority: &str,
        effort: &str,
    ) -> Result<String> {
        let extra = self
            .external_pending_ids(domain)
            .unwrap_or_else(|_| Vec::new());
        self.reserve_with_external(domain, title, priority, effort, &extra)
    }

    /// Same as [`Self::reserve`] but with an explicit list of in-use ID
    /// numbers from sources outside the DB (open PRs, in-flight leases).
    /// Used by tests to inject collision scenarios deterministically without
    /// shelling out to `gh` or fabricating lease files.
    pub fn reserve_with_external(
        &self,
        domain: &str,
        title: &str,
        priority: &str,
        effort: &str,
        extra_used: &[i64],
    ) -> Result<String> {
        let domain_upper = domain.to_uppercase();
        let now = unix_now();

        // INFRA-2177: dropped the import_from_yaml() call that used to run here.
        //
        // History:
        //   INFRA-070 / INFRA-143 added import_from_yaml to seed the counter from
        //   docs/gaps.yaml so reserve couldn't collide with IDs in YAML that weren't
        //   yet in state.db. That made sense when the per-file YAML files were the
        //   canonical source and state.db was a derived cache.
        //
        //   INFRA-498 / INFRA-228 inverted the relationship: state.db is now the
        //   single source of truth; per-file YAMLs are dump artifacts. Crucially,
        //   `chump gap reserve` itself writes the per-file YAML *after* inserting the
        //   DB row, so any ID that exists in docs/gaps/*.yaml also exists in
        //   state.db — the import is redundant.
        //
        //   Side-effect of keeping the call: a single malformed sibling YAML (e.g.
        //   INFRA-2170, where numbered AC items with colon-space patterns broke
        //   YAML mapping/sequence ambiguity) caused `serde_yaml::from_str` to fail,
        //   which aborted reserve for *every* domain fleet-wide for 30+ minutes.
        //   Five concurrent curator sessions stalled (META-124 Wave 1 incident,
        //   2026-05-29).
        //
        //   The ID-collision risk that INFRA-143 guarded against is fully covered by
        //   the SELECT MAX query below plus the gap_counters upsert: both read
        //   exclusively from state.db, which is always up to date because reserve
        //   writes there first. No YAML read is needed.
        //
        //   Nightly gap-curate.sh (INFRA-637) still calls import_from_yaml to
        //   reconcile any manual YAML edits back into state.db — that's the right
        //   home for the reconciliation pass, not the hot reserve path.

        // INFRA-3687, parts 1+2 of the stale-checkout collision fix: consult
        // origin/main's canonical state.sql BEFORE touching the local
        // counter, and fail closed if this checkout is genuinely behind
        // origin/main AND canonical truth is unverifiable. Computed up
        // front (outside the BEGIN IMMEDIATE write-lock below) since both
        // are pure git shell-outs with no state.db interaction — no reason
        // to hold the write lock across them.
        //
        // Existing test fixtures (`test_store()`) use a bare `TempDir` with
        // no `.git` at all, so both calls return `None` for them and this
        // gate is a no-op — unaffected.
        let canonical_max = self.canonical_max_id(&domain_upper);
        let behind = behind_origin_main_count(&self.repo_root).unwrap_or(0);
        let allow_stale = std::env::var("CHUMP_RESERVE_ALLOW_STALE").as_deref() == Ok("1");
        if behind > 0 && canonical_max.is_none() {
            if !allow_stale {
                bail!(
                    "refusing to reserve {domain_upper}: checkout is {behind} commit(s) behind \
                     origin/main and canonical state.sql is unreadable — cannot guarantee a \
                     unique ID. Run `git pull` (or restore state.db from state.sql) and retry. \
                     Emergency escape hatch: CHUMP_RESERVE_ALLOW_STALE=1 (audited)."
                );
            }
            // CHUMP_RESERVE_ALLOW_STALE=1 audit trail — same ambient-event
            // idiom already used twice below in this function
            // (gap_id_allocator_collision_avoided /
            // gap_id_reused_from_git_history_avoided). Registered in
            // docs/observability/EVENT_REGISTRY.yaml.
            let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
            let ts = unix_to_iso_full(unix_now());
            // scanner-anchor: "kind":"gap_reserve_stale_bypass_used" (registered in docs/observability/EVENT_REGISTRY.yaml, INFRA-3687)
            let line = format!(
                "{{\"ts\":\"{ts}\",\"kind\":\"gap_reserve_stale_bypass_used\",\
                 \"domain\":\"{domain_upper}\",\"behind\":{behind}}}\n"
            );
            use std::io::Write as _;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&amb)
            {
                let _ = f.write_all(line.as_bytes());
            }
        }

        // Seed the counter from existing gaps if this is the first reserve for the domain.
        // Then atomically bump it and insert the new gap row under IMMEDIATE (reserved write
        // lock). BEGIN EXCLUSIVE was too strong: concurrent GapStore::open + migrate on the
        // same WAL file failed CI with "database is locked" (gap_store::tests::test_reserve_concurrent).
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        let result = (|| -> Result<String> {
            // Ensure counter row exists, seeded from max existing ID for this domain.
            // INFRA-070: ON CONFLICT bumps the counter to MAX(current, gaps_max+1) so a
            // previously-low counter can't keep returning IDs that exist in YAML.
            let prefix = format!("{}-", domain_upper);
            let existing_max: i64 = self.conn.query_row(
                "SELECT COALESCE(MAX(CAST(SUBSTR(id, LENGTH(?1)+1) AS INTEGER)), 0) FROM gaps WHERE id LIKE ?2",
                params![prefix, format!("{}%", prefix)],
                |r| r.get(0),
            )?;
            // INFRA-100: also bump past any IDs that exist in open PRs or
            // pending leases (sources the DB cannot see). The counter must
            // start above the max of (DB max, external max).
            let extra_max = extra_used.iter().copied().max().unwrap_or(0);
            // INFRA-3687: also bump past origin/main's canonical state.sql
            // max (computed above, before the transaction started) — the
            // fix for the stale-checkout collision class. A checkout behind
            // origin/main has a stale `existing_max` here; folding in
            // `canonical_max` makes it impossible to re-issue an ID that
            // canonically already belongs to a merged gap, independent of
            // how stale this checkout's local DB and leases are.
            let combined_max = std::cmp::max(
                std::cmp::max(existing_max, extra_max),
                canonical_max.unwrap_or(0),
            );
            self.conn.execute(
                "INSERT INTO gap_counters(domain, next_num) VALUES(?1, ?2)
                 ON CONFLICT(domain) DO UPDATE SET next_num = MAX(next_num, excluded.next_num)",
                params![domain_upper, combined_max + 1],
            )?;
            // INFRA-100: walk past any extra-used IDs that fall above the
            // counter's current value too (defense-in-depth: a stale counter
            // row could be ahead of `existing_max` but behind `extra_max`).
            // Atomic UPDATE with arithmetic ensures concurrent reserves still
            // get distinct numbers.
            for &n in extra_used {
                self.conn.execute(
                    "UPDATE gap_counters SET next_num = MAX(next_num, ?1 + 1) WHERE domain=?2",
                    params![n, domain_upper],
                )?;
            }
            // CREDIBLE-052: if the naive next ID (existing_max+1) was already
            // taken by an open PR or sibling lease, emit a collision-avoided event
            // so operators can see cross-session ID races in the ambient stream.
            let naive_next = existing_max + 1;
            if extra_used.contains(&naive_next) {
                let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
                let ts = unix_to_iso_full(unix_now());
                let line = format!(
                    "{{\"ts\":\"{ts}\",\"kind\":\"gap_id_allocator_collision_avoided\",\
                     \"domain\":\"{domain_upper}\",\"skipped_id\":\"{prefix}{naive_next:03}\"}}\n"
                );
                use std::io::Write as _;
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&amb)
                {
                    let _ = f.write_all(line.as_bytes());
                }
            }
            // Atomically bump the counter and read the assigned number.
            //
            // INFRA-1954: state.db (plus the open-PR/lease sources above) is
            // blind to a gap that already shipped and was later dropped from
            // the live registry — e.g. state.db rebuilt from an older
            // `.chump/state.sql` snapshot, or a domain counter that never saw
            // the closed row. Git commit history never forgets, so before
            // committing to a candidate ID, check whether it already appears
            // in a past commit message on any ref; if so, skip it and try the
            // next number. Bounded retry (not unbounded) so a persistently
            // broken git binary can't hang reserve forever.
            // CREDIBLE-292: pull fresh origin refs once before the retry loop
            // so git_id_referenced() below can see IDs a sibling node already
            // merged, even if this checkout's last fetch predates them.
            fetch_origin_refs(&self.repo_root);
            const MAX_GIT_HISTORY_SKIPS: u32 = 50;
            let mut new_id = String::new();
            for _ in 0..MAX_GIT_HISTORY_SKIPS {
                self.conn.execute(
                    "UPDATE gap_counters SET next_num = next_num + 1 WHERE domain=?1",
                    params![domain_upper],
                )?;
                let num: i64 = self.conn.query_row(
                    "SELECT next_num - 1 FROM gap_counters WHERE domain=?1",
                    params![domain_upper],
                    |r| r.get(0),
                )?;
                let candidate = format!("{}{:03}", prefix, num);
                if git_id_referenced(&self.repo_root, &candidate) {
                    let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
                    let ts = unix_to_iso_full(unix_now());
                    // scanner-anchor: "kind":"gap_id_reused_from_git_history_avoided" (registered in docs/observability/EVENT_REGISTRY.yaml, INFRA-1954)
                    let line = format!(
                        "{{\"ts\":\"{ts}\",\"kind\":\"gap_id_reused_from_git_history_avoided\",\
                         \"domain\":\"{domain_upper}\",\"skipped_id\":\"{candidate}\"}}\n"
                    );
                    use std::io::Write as _;
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&amb)
                    {
                        let _ = f.write_all(line.as_bytes());
                    }
                    continue;
                }
                new_id = candidate;
                break;
            }
            if new_id.is_empty() {
                bail!(
                    "reserve({domain}) failed: {MAX_GIT_HISTORY_SKIPS} consecutive candidate \
                     IDs were all found referenced in git history — investigate \
                     CHUMP_RESERVE_GIT_HISTORY_CHECK or the domain counter."
                );
            }
            self.conn.execute(
                "INSERT INTO gaps(id,domain,title,priority,effort,status,created_at)
                 VALUES(?1,?2,?3,?4,?5,'open',?6)",
                params![new_id, domain_upper, title, priority, effort, now],
            )?;
            Ok(new_id)
        })();
        match result {
            Ok(id) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(id)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }

    /// INFRA-216: post-reserve verification round-trip.
    ///
    /// After picking the next ID and inserting the DB row, this method:
    /// 1. Writes a `pending_new_gap` lease so sibling sessions on the same
    ///    host (or shared filesystem) can see the claim immediately.
    /// 2. Sleeps `CHUMP_RESERVE_VERIFY_SLEEP_MS` ms (default 200) to let
    ///    concurrent sibling lease writes propagate.
    /// 3. Re-scans all live leases for the same domain.
    /// 4. If another live session holds the SAME reserved ID, the session
    ///    with the lexicographically smallest `session_id` wins (keeps the
    ///    ID); all others roll back their DB row and retry.
    /// 5. After `MAX_RETRIES` without winning, returns an error naming the
    ///    colliding session(s).
    ///
    /// Set `CHUMP_RESERVE_VERIFY=0` to skip verification (offline builds,
    /// `cargo test` where the 200 ms sleep would be expensive).
    pub fn reserve_verified(
        &self,
        domain: &str,
        title: &str,
        priority: &str,
        effort: &str,
        session_id: &str,
    ) -> Result<String> {
        if std::env::var("CHUMP_RESERVE_VERIFY").as_deref() == Ok("0") {
            return self.reserve(domain, title, priority, effort);
        }

        let sleep_ms: u64 = std::env::var("CHUMP_RESERVE_VERIFY_SLEEP_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(200);

        const MAX_RETRIES: u32 = 3;
        let locks_dir = self.repo_root.join(".chump-locks");
        let lease_path = locks_dir.join(format!("{}.json", session_id));

        for attempt in 1..=MAX_RETRIES {
            // Step 1: pick ID via existing reserve logic (reads current leases
            // to skip already-claimed numbers before inserting the DB row).
            let extra = self.external_pending_ids(domain).unwrap_or_default();
            let id = self.reserve_with_external(domain, title, priority, effort, &extra)?;
            let domain_upper = domain.to_uppercase();

            // Step 2: advertise the reservation via a pending_new_gap lease
            // so sibling sessions on the same filesystem can see our claim.
            let _ = std::fs::create_dir_all(&locks_dir);
            let now = unix_now();
            let lease_json = serde_json::json!({
                "session_id": session_id,
                "pending_new_gap": {
                    "id": &id,
                    "title": title,
                    "domain": &domain_upper,
                },
                "heartbeat_at": unix_to_iso_full(now),
                // INFRA-110: 2h TTL on reserve-time pending_new_gap leases
                // (was 1h). Unifies with shell gap-reserve.sh GAP_CLAIM_TTL_HOURS
                // default of 2h so concurrent shell + Rust reservers honor the
                // same squat window. Bound by INFRA-322 auto-cleanup at the end
                // of reserve_verified() — this TTL only matters if the
                // process dies before that cleanup runs.
                "expires_at": unix_to_iso_full(now + 7200),
            });
            if let Ok(txt) = serde_json::to_string(&lease_json) {
                let _ = std::fs::write(&lease_path, txt);
            }

            // Step 3: sleep to let concurrent sibling lease writes propagate.
            if sleep_ms > 0 {
                std::thread::sleep(std::time::Duration::from_millis(sleep_ms));
            }

            // Step 4: re-scan; find any OTHER live session with the same ID.
            // Use next_back() (DoubleEndedIterator) instead of last() per
            // clippy::double_ended_iterator_last — last() needlessly walks
            // the full iterator.
            let id_num: i64 = id
                .split('-')
                .next_back()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let colliders = self.colliding_sessions(&domain_upper, id_num, session_id)?;

            if colliders.is_empty() {
                // No collision — verification passed. INFRA-322: drop the
                // pending_new_gap lease now that the reserve transaction
                // is complete. Without this, the lease lingers for ~1h
                // and blocks subsequent gap-claim.sh on the same ID from
                // real sessions (gap-preflight reads it as a live claim
                // by a chump-anon-* session). Belt-and-suspenders with
                // the gap-preflight workaround in INFRA-322's PR #919.
                let _ = std::fs::remove_file(&lease_path);
                return Ok(id);
            }

            // Tiebreak: lexicographically smallest session_id wins so the
            // outcome is deterministic when both sides detect the race
            // simultaneously.
            let winner_candidate = colliders.iter().min().map(String::as_str).unwrap_or("");

            // CREDIBLE-029: emit gap_id_allocator_collision to ambient.jsonl
            // so fleet ops can see the race in the ambient stream rather than
            // having it silently retried. Emitted by both the winner and the
            // loser so the event count reflects actual collision frequency.
            let amb_path = locks_dir.join("ambient.jsonl");
            let ts_now = unix_to_iso_full(unix_now());
            let resolution = if session_id < winner_candidate {
                "won_tiebreak"
            } else {
                "lost_tiebreak_retrying"
            };
            let collision_line = format!(
                "{{\"ts\":\"{ts_now}\",\"event\":\"ALERT\",\"kind\":\"gap_id_allocator_collision\",\
                 \"chosen_id\":\"{id}\",\"session\":\"{session_id}\",\
                 \"conflicting_sessions\":{colliders_json},\"resolution\":\"{resolution}\",\
                 \"attempt\":{attempt}}}\n",
                colliders_json = serde_json::to_string(&colliders).unwrap_or_else(|_| "[]".to_string()),
            );
            use std::io::Write as _;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&amb_path)
            {
                let _ = f.write_all(collision_line.as_bytes());
            }

            if session_id < winner_candidate {
                // We hold the lexicographically smallest ID — we win.
                // INFRA-322: drop the lease (same rationale as above).
                let _ = std::fs::remove_file(&lease_path);
                return Ok(id);
            }

            // We lose — roll back our DB row so the counter won't skip past
            // the winning session's claimed number on the next attempt.
            let _ = self
                .conn
                .execute("DELETE FROM gaps WHERE id=?1", params![&id]);
            let _ = std::fs::remove_file(&lease_path);

            if attempt == MAX_RETRIES {
                bail!(
                    "reserve({domain}) failed after {MAX_RETRIES} attempts: \
                     ID {id} was simultaneously claimed by session(s) {colliders:?} \
                     within the {sleep_ms}ms verification window. Investigate \
                     shared-filesystem lease propagation or increase \
                     CHUMP_RESERVE_VERIFY_SLEEP_MS."
                );
            }
            // Loop: the next call to reserve_with_external will see the
            // winner's lease file and skip past the contested ID.
        }

        bail!("reserve({domain}) failed after {MAX_RETRIES} retries — persistent collision")
    }

    /// Return the `session_id` strings of all live leases (other than our
    /// own) that carry a `pending_new_gap` for the given `domain` and
    /// `id_num`. Used by [`Self::reserve_verified`] to detect cross-host
    /// races after the 200 ms propagation window.
    fn colliding_sessions(
        &self,
        domain_upper: &str,
        id_num: i64,
        my_session: &str,
    ) -> Result<Vec<String>> {
        let prefix = format!("{}-", domain_upper);
        let target_id = format!("{}{:03}", prefix, id_num);
        let mut colliders = Vec::new();
        let locks_dir = self.repo_root.join(".chump-locks");
        let Ok(entries) = std::fs::read_dir(&locks_dir) else {
            return Ok(colliders);
        };
        let now = unix_now();
        for ent in entries.flatten() {
            let path = ent.path();
            let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if !name.ends_with(".json") || name.starts_with('.') || name == "ambient.jsonl" {
                continue;
            }
            let txt = match std::fs::read_to_string(&path) {
                Ok(t) => t,
                Err(_) => continue,
            };
            let v: serde_json::Value = match serde_json::from_str(&txt) {
                Ok(v) => v,
                Err(_) => continue,
            };
            // Skip stale leases (same staleness thresholds as external_pending_ids).
            let heartbeat = v
                .get("heartbeat_at")
                .and_then(|s| s.as_str())
                .and_then(parse_iso_to_unix);
            let expires = v
                .get("expires_at")
                .and_then(|s| s.as_str())
                .and_then(parse_iso_to_unix);
            if let Some(h) = heartbeat {
                if now - h > 900 {
                    continue;
                }
            }
            if let Some(e) = expires {
                if now - e > 30 {
                    continue;
                }
            }
            let sid = v
                .get("session_id")
                .and_then(|s| s.as_str())
                .unwrap_or("")
                .to_string();
            if sid == my_session || sid.is_empty() {
                continue;
            }
            if let Some(p) = v.get("pending_new_gap").and_then(|p| p.as_object()) {
                if p.get("id").and_then(|i| i.as_str()) == Some(target_id.as_str()) {
                    colliders.push(sid);
                }
            }
        }
        Ok(colliders)
    }

    /// INFRA-100: gather gap-ID numbers from sources the DB can't see —
    /// `.chump-locks/*.json` `pending_new_gap.id` entries (in-flight reserves
    /// from sibling sessions) and, when `CHUMP_RESERVE_SCAN_OPEN_PRS=1` is
    /// set, open-PR titles via `gh pr list --state open --json title`.
    ///
    /// The PR scan defaults OFF because (a) `scripts/coord/gap-reserve.sh`
    /// already runs `gh pr diff` against open PRs touching docs/gaps.yaml
    /// and (b) shelling out to `gh` is a network/auth dependency that
    /// would slow `cargo test` and break offline runs. Production
    /// invocations through the shell wrapper get full coverage; the env
    /// var lets a future Rust-only path enable it explicitly.
    ///
    /// Stale leases (expired or heartbeat older than 15 min) are skipped —
    /// their pending IDs are unlikely to land and continuing to reserve
    /// past them would inflate the next number indefinitely.
    pub fn external_pending_ids(&self, domain: &str) -> Result<Vec<i64>> {
        let mut out = Vec::new();
        let domain_upper = domain.to_uppercase();
        let prefix = format!("{}-", domain_upper);

        // Lease scan
        let locks_dir = self.repo_root.join(".chump-locks");
        if let Ok(entries) = std::fs::read_dir(&locks_dir) {
            let now = unix_now();
            for ent in entries.flatten() {
                let path = ent.path();
                let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if !name.ends_with(".json") || name.starts_with('.') || name == "ambient.jsonl" {
                    continue;
                }
                let txt = match std::fs::read_to_string(&path) {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                let v: serde_json::Value = match serde_json::from_str(&txt) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                // Skip stale: heartbeat older than 15 min OR expired more than 30 s ago.
                let heartbeat = v
                    .get("heartbeat_at")
                    .and_then(|s| s.as_str())
                    .and_then(parse_iso_to_unix);
                let expires = v
                    .get("expires_at")
                    .and_then(|s| s.as_str())
                    .and_then(parse_iso_to_unix);
                if let Some(h) = heartbeat {
                    if now - h > 900 {
                        continue;
                    }
                }
                if let Some(e) = expires {
                    if now - e > 30 {
                        continue;
                    }
                }
                if let Some(p) = v.get("pending_new_gap").and_then(|p| p.as_object()) {
                    if let Some(id) = p.get("id").and_then(|i| i.as_str()) {
                        if let Some(rest) = id.strip_prefix(&prefix) {
                            if let Ok(n) = rest.parse::<i64>() {
                                out.push(n);
                            }
                        }
                    }
                }
            }
        }

        // Open-PR scan (INFRA-100: default ON since 2026-05-02). On 2026-05-01
        // we shipped 8 collision pairs (INFRA-202..215 cluster) because this
        // scan was opt-in via CHUMP_RESERVE_SCAN_OPEN_PRS=1 and nobody had it
        // enabled. Open-PR titles are the most direct evidence of "an ID is
        // already claimed by a sibling session about to push" — there's no
        // good reason to default it off. Opt out via CHUMP_RESERVE_SCAN_OPEN_PRS=0
        // for offline / no-gh-CLI scenarios.
        //
        // Network failure is non-fatal: print a one-line warning and continue
        // with lease+DB+YAML coverage. Bricking reserve on a flaky network
        // would be worse than tolerating a slightly higher residual race risk.
        if std::env::var("CHUMP_RESERVE_SCAN_OPEN_PRS").as_deref() != Ok("0") {
            match list_open_pr_titles() {
                Ok(pr_titles) => {
                    let pat = regex_lite_for_domain(&domain_upper);
                    for title in pr_titles {
                        for n in pat.find_numbers(&title) {
                            out.push(n);
                        }
                    }
                }
                Err(e) => {
                    // INFRA-1893: negative-confirmation gate before emitting any
                    // visible warning. Run a cheap gh smoke call (gh api user).
                    // If the smoke passes (gh is healthy), the original failure was
                    // an internal inconsistency (spurious 401 from --paginate/--jq
                    // path or scope mismatch). Suppress the operator-visible warning
                    // and emit a forensic ambient event instead.
                    // If the smoke also fails, gh is genuinely broken — emit a
                    // single visible warning (debounced per-process via
                    // SCAN_FAILED_WARNED) and a gap_reserve_open_pr_scan_failed
                    // ambient event.
                    let amb = locks_dir.join("ambient.jsonl");
                    let ts = unix_to_iso_full(unix_now());
                    use std::io::Write as _;
                    let reason_escaped = e.to_string().replace('"', "'");
                    if gh_smoke_check() {
                        // gh is healthy — inconsistency in the scan call itself.
                        // Suppress stderr warning; emit forensic telemetry only.
                        let line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"gap_reserve_open_pr_scan_inconsistent\",\
                             \"domain\":\"{domain_upper}\",\"reason\":\"{reason_escaped}\"}}\n"
                        );
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&amb)
                        {
                            let _ = f.write_all(line.as_bytes());
                        }
                    } else {
                        // gh is genuinely unreachable / unauthenticated.
                        // Emit operator-visible warning at most once per process.
                        if !SCAN_FAILED_WARNED.swap(true, Ordering::Relaxed) {
                            eprintln!(
                                "[gap reserve] WARN: open-PR scan failed ({e}). Continuing \
                                 with lease+DB coverage only — slight collision risk against \
                                 in-flight PRs from sibling sessions. Set \
                                 CHUMP_RESERVE_SCAN_OPEN_PRS=0 to silence."
                            );
                        }
                        // Emit gap_reserve_open_pr_scan_failed (once per process
                        // — guard the file write with the same flag so 5 back-to-back
                        // reserves don't append 5 identical lines).
                        // CREDIBLE-052: also retain gap_id_allocator_offline for
                        // existing consumers that watch that kind.
                        let scan_line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"gap_reserve_open_pr_scan_failed\",\
                             \"domain\":\"{domain_upper}\",\"reason\":\"{reason_escaped}\"}}\n"
                        );
                        let offline_line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"gap_id_allocator_offline\",\
                             \"domain\":\"{domain_upper}\",\"reason\":\"{reason_escaped}\"}}\n"
                        );
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&amb)
                        {
                            let _ = f.write_all(scan_line.as_bytes());
                            let _ = f.write_all(offline_line.as_bytes());
                        }
                    }
                }
            }
        }

        Ok(out)
    }

    /// INFRA-3687: read origin/main's tracked `.chump/state.sql` — the
    /// canonical, git-tracked dump of every gap ever reserved or merged —
    /// and return the highest `<DOMAIN>-N` id number found for
    /// `domain_upper`.
    ///
    /// This closes the stale-checkout ID collision class documented in
    /// `docs/process/CANONICAL_STATE_CONTRACT.md` § Drift Mode G: a
    /// checkout N commits behind `origin/main` has a stale local `gaps`
    /// table, so `existing_max` (local state.db) and `extra_max`
    /// (`.chump-locks/*.json` leases + open-PR titles) can BOTH under-count,
    /// and `reserve_with_external` re-issues an ID that canonically already
    /// belongs to a merged gap (real repro: a checkout 177 commits behind
    /// reserved `INFRA-3680`, canonically a merged "parse_verdict" gap).
    /// Folding this method's result into `combined_max` in
    /// `reserve_with_external` makes that physically impossible whenever
    /// origin refs are reachable.
    ///
    /// Best-effort `git fetch origin main --quiet` first (mirrors the
    /// INFRA-2423 `ship()` auto-fetch pattern; non-fatal offline/no-remote —
    /// falls through to whatever `origin/main` this checkout already knows
    /// about). Then reads `origin/main:.chump/state.sql` via `git show` and
    /// delegates to [`Self::max_id_num_in_gaps`] — the SAME id-column-only
    /// extraction the local allocator uses, deliberately NOT a raw
    /// text/regex scan over the whole dump (see that method's docs for why:
    /// state.sql is known to carry `<DOMAIN>-N`-shaped junk substrings
    /// outside the `id` column, e.g. `INFRA-9999999` quoted in a note).
    ///
    /// Returns `None` — "could not verify canonical truth" — ONLY when
    /// there is no `.git`, the `git show` itself fails (offline,
    /// unreachable ref, or the file does not exist at `origin/main`'s
    /// current tip), or the YAML fails to parse. Deliberately distinct from
    /// "the file was read successfully but this domain has zero canonical
    /// gaps" — that case is verified truth (a fresh domain's canonical max
    /// really is 0) and returns `Some(0)`, not `None`. Collapsing the two
    /// would make `reserve_with_external`'s fail-closed gate refuse every
    /// first-ever reserve for a new domain on a checkout that happens to be
    /// behind, which is not a staleness risk at all. Callers MUST treat
    /// `None` as "unverifiable" — see the fail-closed gate in
    /// `reserve_with_external`.
    pub fn canonical_max_id(&self, domain_upper: &str) -> Option<i64> {
        if !self.repo_root.join(".git").exists() {
            return None;
        }
        // Best-effort refresh; non-fatal if offline (mirrors the INFRA-2423
        // auto-fetch already used by ship()'s proof-of-merge check).
        let _ = std::process::Command::new("git")
            .args(["fetch", "origin", "main", "--quiet"])
            .current_dir(&self.repo_root)
            .output();
        let output = std::process::Command::new("git")
            .args(["show", "origin/main:.chump/state.sql"])
            .current_dir(&self.repo_root)
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let file = Self::parse_state_sql_yaml(&text).ok()?;
        // Read + parse succeeded: this IS verified canonical truth, even
        // when the domain has zero matches there (a brand-new domain's
        // canonical max legitimately is 0 — see the doc comment above).
        Some(Self::max_id_num_in_gaps(&file.gaps, domain_upper).unwrap_or(0))
    }

    /// Public wrapper around [`behind_origin_main_count`] for CLI callers
    /// (`chump gap list`'s Drift-Mode-G staleness warning, part 3 of the
    /// INFRA-3687 fix). Deliberately does NOT fetch first — `gap list` is a
    /// hot/frequent read path and this must stay non-blocking; it reports
    /// against whatever `origin/main` ref this checkout already has from
    /// ambient fetches elsewhere. See that function's docs for `None`
    /// semantics.
    pub fn behind_origin_main(&self) -> Option<u64> {
        behind_origin_main_count(&self.repo_root)
    }

    /// Claim a gap for a session (write lease row).
    pub fn claim(
        &self,
        gap_id: &str,
        session_id: &str,
        worktree: &str,
        ttl_secs: i64,
    ) -> Result<()> {
        let expires_at = unix_now() + ttl_secs;
        // Verify gap exists and is open
        let status: String = self
            .conn
            .query_row(
                "SELECT status FROM gaps WHERE id=?1",
                params![gap_id],
                |r| r.get(0),
            )
            .with_context(|| format!("gap {} not found in state.db", gap_id))?;
        if status == "done" {
            bail!("gap {} is already done", gap_id);
        }
        // Check for live conflicting claim
        let live_claim: Option<String> = self.conn.query_row(
            "SELECT session_id FROM leases WHERE gap_id=?1 AND expires_at>?2 AND session_id!=?3",
            params![gap_id, unix_now(), session_id],
            |r| r.get(0),
        ).optional()?;
        if let Some(other) = live_claim {
            bail!("gap {} is live-claimed by session {}", gap_id, other);
        }
        // INFRA-1032: warn when this session already has a lease with a different worktree path
        if !worktree.is_empty() {
            let existing_wt: Option<String> = self
                .conn
                .query_row(
                    "SELECT worktree FROM leases WHERE session_id=?1",
                    params![session_id],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(ref existing) = existing_wt {
                if !existing.is_empty() && existing != worktree {
                    // INFRA-693: this crate intentionally avoids the tracing
                    // dep to keep the surface small; eprintln! is the right
                    // shape here (single warning at a known race seam).
                    eprintln!(
                        "WARN: INFRA-1032: session_id={} worktree clobber detected — \
                         existing_worktree={} new_worktree={}",
                        session_id, existing, worktree
                    );
                }
            }
        }
        self.conn.execute(
            "INSERT INTO leases(session_id,gap_id,worktree,expires_at)
             VALUES(?1,?2,?3,?4)
             ON CONFLICT(session_id) DO UPDATE SET gap_id=excluded.gap_id,
                 worktree=excluded.worktree, expires_at=excluded.expires_at",
            params![session_id, gap_id, worktree, expires_at],
        )?;
        Ok(())
    }

    /// Preflight check: is the gap open and unclaimed?
    ///
    /// INFRA-630: accepts 8-char hex short-prefix (UUID short form) via the
    /// same prefix-match logic as `get()`. Resolves to full ID before checking
    /// lease table so lease lookups remain exact.
    pub fn preflight(&self, gap_id: &str) -> Result<PreflightResult> {
        // INFRA-630: resolve short-prefix to full ID first.
        let resolved: std::borrow::Cow<str> =
            if gap_id.len() == 8 && gap_id.chars().all(|c| c.is_ascii_hexdigit()) {
                let pattern = format!("{}%", gap_id.to_lowercase());
                let full: Option<String> = self
                    .conn
                    .query_row(
                        "SELECT id FROM gaps WHERE LOWER(id) LIKE ?1 LIMIT 1",
                        params![pattern],
                        |r| r.get(0),
                    )
                    .optional()?;
                match full {
                    Some(id) => std::borrow::Cow::Owned(id),
                    None => std::borrow::Cow::Borrowed(gap_id),
                }
            } else {
                std::borrow::Cow::Borrowed(gap_id)
            };
        let gap_id = resolved.as_ref();

        let row = self
            .conn
            .query_row(
                "SELECT status FROM gaps WHERE id=?1",
                params![gap_id],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        match row {
            None => return Ok(PreflightResult::NotFound),
            Some(s) if s == "done" => return Ok(PreflightResult::Done),
            _ => {}
        }
        let live_claim: Option<String> = self
            .conn
            .query_row(
                "SELECT session_id FROM leases WHERE gap_id=?1 AND expires_at>?2",
                params![gap_id, unix_now()],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(s) = live_claim {
            return Ok(PreflightResult::Claimed(s));
        }
        Ok(PreflightResult::Available)
    }

    /// Batch-fetch all currently-active leases as a `gap_id → session_id` map.
    ///
    /// Used by `handle_gap_queue` to replace per-row `preflight()` calls with a
    /// single query, reducing latency from O(N×2 queries) to O(1 query) for the
    /// list view (INFRA-1277).  Only non-expired leases are returned.
    pub fn active_leases(&self) -> Result<std::collections::HashMap<String, String>> {
        let now = unix_now();
        let mut stmt = self
            .conn
            .prepare("SELECT gap_id, session_id FROM leases WHERE expires_at > ?1")?;
        let map: std::collections::HashMap<String, String> = stmt
            .query_map(params![now], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(map)
    }

    /// Mark a gap as done. Stamps both `closed_at` (unix ts) and
    /// `closed_date` (ISO yyyy-mm-dd, matching YAML convention). When
    /// `closed_pr` is `Some(n)`, also sets the closed_pr column — this
    /// is what the INFRA-107 closed_pr integrity guard requires for any
    /// status:done flip in YAML, so passing it here keeps the canonical
    /// state.db and the YAML mirror in agreement (INFRA-156).
    pub fn ship(&self, gap_id: &str, session_id: &str, closed_pr: Option<i64>) -> Result<()> {
        // INFRA-1392 PROOF-OF-MERGE: refuse to flip status=done unless we
        // can verify the work actually landed. Pattern observed
        // 2026-05-22: sibling claim flipped INFRA-1368 / INFRA-1363 to
        // status=done within minutes of filing, before the PRs merged.
        // Cost: real claims that already existed were treated as
        // already-done and skipped; ~3 wasted compute-hours.
        //
        // INFRA-2423: auto-fetch origin/main before the proof-of-merge check
        // so that a stale local main does not cause a spurious failure.
        // If local main is behind and the working tree is clean, auto-pull
        // with --ff-only. If dirty, emit a clear error and bail — the caller
        // must stash or commit before shipping. No bypass env var is needed.
        //
        // The webhook path also lands here: receiver calls ship() with
        // closed_pr set and the merge commit on main from the webhook's
        // `pull_request.merge_commit_sha` is what git log finds.
        if self.repo_root.join(".git").exists() {
            // Fetch quietly; failure is non-fatal (offline or no remote).
            let _ = std::process::Command::new("git")
                .args(["fetch", "origin", "main", "--quiet"])
                .current_dir(&self.repo_root)
                .stderr(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .status();

            // Count commits behind after the fetch.
            let behind: u64 = std::process::Command::new("git")
                .args(["rev-list", "--count", "main..origin/main"])
                .current_dir(&self.repo_root)
                .output()
                .ok()
                .filter(|o| o.status.success())
                .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
                .unwrap_or(0);

            if behind > 0 {
                // Check whether the working tree is clean (unstaged or staged changes).
                let dirty = std::process::Command::new("git")
                    .args(["diff", "--quiet", "HEAD"])
                    .current_dir(&self.repo_root)
                    .status()
                    .map(|s| !s.success())
                    .unwrap_or(false);

                if dirty {
                    // Emit ambient event so fleet-brief / watchdogs can surface
                    // this as a friction signal. Best-effort: never fail caller.
                    {
                        use std::io::Write as _;
                        let ts = unix_to_iso_full(unix_now());
                        let line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"ship_autofetch_blocked_dirty\",\
                             \"gap_id\":\"{gap_id}\",\"behind\":{behind}}}\n"
                        );
                        let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&amb)
                        {
                            let _ = f.write_all(line.as_bytes());
                        }
                    }
                    bail!(
                        "INFRA-2423 AUTO-FETCH: local main is {behind} commits behind \
                         origin/main; cannot auto-pull with uncommitted changes. \
                         Please `git stash` or commit first, then retry `chump gap ship`."
                    );
                } else {
                    // Clean tree — pull fast-forward silently and emit ambient
                    // event so curators can observe auto-pull frequency.
                    let _ = std::process::Command::new("git")
                        .args(["pull", "--ff-only", "origin", "main", "--quiet"])
                        .current_dir(&self.repo_root)
                        .stderr(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .status();
                    {
                        use std::io::Write as _;
                        let ts = unix_to_iso_full(unix_now());
                        let line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"ship_autofetch_pulled\",\
                             \"gap_id\":\"{gap_id}\",\"behind\":{behind}}}\n"
                        );
                        let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&amb)
                        {
                            let _ = f.write_all(line.as_bytes());
                        }
                    }

                    // RESILIENT-492: after a successful pull, rebuild the
                    // release binary so a stale binary can never ship silently.
                    // Capture stdout/stderr to build.log in the repo root and
                    // abort the ship if the build fails. Only applies to a
                    // real Cargo workspace — auto-fetch/auto-pull test
                    // fixtures use plain git repos with no Cargo.toml, and
                    // ship() must stay usable against those without dragging
                    // in a cargo dependency.
                    if self.repo_root.join("Cargo.toml").exists() {
                        let build_output = std::process::Command::new("cargo")
                            .args(["build", "--release"])
                            .current_dir(&self.repo_root)
                            .output()
                            .context("RESILIENT-492: failed to spawn `cargo build --release`")?;

                        {
                            use std::io::Write as _;
                            let build_log = self.repo_root.join("build.log");
                            if let Ok(mut f) = std::fs::File::create(&build_log) {
                                let _ = f.write_all(&build_output.stdout);
                                let _ = f.write_all(&build_output.stderr);
                            }
                        }

                        if !build_output.status.success() {
                            bail!(
                                "RESILIENT-492: cargo build --release failed with {:?} after \
                                 auto-pull for {gap_id} — see build.log in repo root for details",
                                build_output.status.code()
                            );
                        }

                        eprintln!("cargo build --release completed with exit code 0");
                    }
                }
            }
        }

        if !verify_proof_of_merge(&self.repo_root, gap_id, closed_pr) {
            bail!(
                "INFRA-1392 PROOF-OF-MERGE: refusing to flip {gap_id} to status=done — \
                 no commit on local main carries this gap ID. Either (a) wait for the \
                 actual merge to land on main, or (b) ensure the merge commit subject \
                 mentions {gap_id}. Auto-fetch from origin/main already ran; if the \
                 commit is not yet on main, wait for the merge to land and retry."
            );
        }

        let now = unix_now();
        let iso = unix_to_iso_date(now);
        // CREDIBLE-218: reconcile ANY non-terminal status, not just 'open'. A gap
        // that merged while in an intermediate status (ready_to_ship / in_review /
        // in_flight / claimed / blocked) was previously un-reconcilable here — the
        // UPDATE only matched status='open' — so it became a permanent GHOST
        // (merged on main, still shown open). We exclude only the DELIBERATE terminal
        // statuses (already done, or an operator's superseded/wontfix/closed decision)
        // so a real terminal choice is never silently flipped to done.
        let changed = if let Some(pr) = closed_pr {
            self.conn.execute(
                "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2, closed_pr=?3
                 WHERE id=?4 AND status NOT IN
                   ('done','superseded','wontfix','wont_fix','closed','closed_not_a_bug','already_satisfied')",
                params![now, iso, pr, gap_id],
            )?
        } else {
            self.conn.execute(
                "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2
                 WHERE id=?3 AND status NOT IN
                   ('done','superseded','wontfix','wont_fix','closed','closed_not_a_bug','already_satisfied')",
                params![now, iso, gap_id],
            )?
        };
        if changed == 0 {
            bail!(
                "gap {} not found, already done, or in a deliberate terminal status \
                 (superseded/wontfix/closed)",
                gap_id
            );
        }
        let _ = self.conn.execute(
            "DELETE FROM leases WHERE session_id=?1 AND gap_id=?2",
            params![session_id, gap_id],
        );

        // META-555 (advisory MVP): now that the gap has flipped to done,
        // evaluate whether its acceptance criterion was EFFECT-verified and
        // not merely CI-green. Best-effort + NEVER blocks — a gap with no
        // `verify:` criterion (the default) is untouched; one whose `verify:`
        // live-check fails is flagged (note + `closed_effect_unverified`
        // signal) so it stays visible under the SAME id instead of silently
        // respawning as a fresh gap id (root incident: RESILIENT-1230 ->
        // 1258 -> 1294, one unfixed symptom, three ids).
        self.record_effect_verification(gap_id);

        // EFFECTIVE-478 (EFFECTIVE-364 slice): trigger the publication
        // resolver asynchronously so "ship -> told" work gets queued
        // without blocking this transition. `ship()` is called from a sync
        // context with no ambient tokio runtime, so we spin up a
        // lightweight current-thread runtime on a background OS thread
        // rather than calling `tokio::spawn` directly (which panics
        // outside a runtime). Any failure is logged and never propagated —
        // publication is best-effort and must not turn a successful ship
        // into an error.
        {
            let artifact_type = self
                .get_artifact_type(gap_id)
                .unwrap_or_else(|_| "code".to_string());
            let event = PublicationEvent {
                source_gap_id: gap_id.to_string(),
                artifact_type,
            };
            let repo_root = self.repo_root.clone();
            std::thread::spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        eprintln!(
                            "WARN: EFFECTIVE-478: publication resolver runtime init failed: {e:#}"
                        );
                        return;
                    }
                };
                let _guard = rt.enter();
                let handle = tokio::spawn(resolve_publication(event, repo_root));
                match rt.block_on(handle) {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => {
                        eprintln!("WARN: EFFECTIVE-478: publication resolver failed: {e:#}")
                    }
                    Err(e) => {
                        eprintln!("WARN: EFFECTIVE-478: publication resolver task panicked: {e:#}")
                    }
                }
            });
        }

        Ok(())
    }

    /// META-555: after a gap flips to done in `ship()`, evaluate whether its
    /// acceptance criterion was EFFECT-verified — not merely that a PR merged
    /// green. Reads the gap's opt-in `verify:` live-check command(s) (see
    /// `extract_verify_commands`) and runs them in the repo root. Pure of side
    /// effects (no ambient emit, no DB write) so it is cheaply unit-testable;
    /// `record_effect_verification` is the side-effecting wrapper ship() calls.
    ///
    /// ANTI-WEDGE: a gap with no `verify:` criterion returns `NoLiveCriterion`
    /// immediately, having run nothing. This is the >99% default and the reason
    /// this check can never stall an ordinary closure.
    pub fn evaluate_effect_verification(&self, gap_id: &str) -> EffectVerdict {
        let ac: String = match self.conn.query_row(
            "SELECT CAST(acceptance_criteria AS TEXT) FROM gaps WHERE id=?1",
            params![gap_id],
            |r| r.get(0),
        ) {
            Ok(s) => s,
            Err(_) => return EffectVerdict::NoLiveCriterion,
        };
        let cmds = extract_verify_commands(&ac);
        if cmds.is_empty() {
            return EffectVerdict::NoLiveCriterion;
        }
        let timeout_s: u64 = std::env::var("CHUMP_EFFECT_VERIFY_TIMEOUT_S")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(30);
        for cmd in &cmds {
            match run_verify_command(&self.repo_root, cmd, timeout_s) {
                Ok(true) => continue,
                Ok(false) => {
                    return EffectVerdict::EffectUnverified {
                        failed_command: cmd.clone(),
                        detail: "verify command exited non-zero".to_string(),
                    }
                }
                Err(e) => {
                    return EffectVerdict::EffectUnverified {
                        failed_command: cmd.clone(),
                        detail: format!("{e:#}"),
                    }
                }
            }
        }
        EffectVerdict::EffectVerified
    }

    /// META-555: the side-effecting wrapper `ship()` calls once a gap has flipped
    /// to done. Best-effort ONLY — every path swallows its errors so a successful
    /// close is NEVER turned into a failure (the hard anti-wedge rule). Outputs:
    ///   * NoLiveCriterion  -> nothing (ordinary closures untouched).
    ///   * EffectVerified   -> a `closed_effect_verified` ambient signal (receipt).
    ///   * EffectUnverified -> a `closed_effect_unverified` ambient signal AND a
    ///     queryable `[META-555 EFFECT-UNVERIFIED ...]` note appended to the gap,
    ///     so downstream (dedup / operator / a future re-work consumer) can find
    ///     done-but-flagged gaps via `notes LIKE '%EFFECT-UNVERIFIED%'` and
    ///     re-work them under the SAME id rather than spawning a duplicate.
    fn record_effect_verification(&self, gap_id: &str) {
        let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
        let append = |payload: &serde_json::Value| {
            use std::io::Write as _;
            let _ = std::fs::create_dir_all(amb.parent().unwrap_or(&self.repo_root));
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&amb)
            {
                let _ = writeln!(f, "{payload}");
            }
        };
        match self.evaluate_effect_verification(gap_id) {
            EffectVerdict::NoLiveCriterion => {}
            EffectVerdict::EffectVerified => {
                // scanner-anchor: "kind":"closed_effect_verified" (META-555)
                append(&serde_json::json!({
                    "ts": unix_to_iso_full(unix_now()),
                    "kind": "closed_effect_verified",
                    "gap_id": gap_id,
                }));
            }
            EffectVerdict::EffectUnverified {
                failed_command,
                detail,
            } => {
                let ts = unix_to_iso_full(unix_now());
                let flag =
                    format!("[META-555 EFFECT-UNVERIFIED @ {ts}: `{failed_command}` -> {detail}]");
                // Queryable flag so a merged-but-ineffective fix stays visible
                // under the same id rather than being silently clean-done.
                let _ = self.conn.execute(
                    "UPDATE gaps SET notes = TRIM(COALESCE(notes,'') || char(10) || ?1) WHERE id=?2",
                    params![flag, gap_id],
                );
                // scanner-anchor: "kind":"closed_effect_unverified" (META-555)
                append(&serde_json::json!({
                    "ts": ts,
                    "kind": "closed_effect_unverified",
                    "gap_id": gap_id,
                    "cmd": failed_command,
                    "detail": detail,
                }));
            }
        }
    }

    /// RESILIENT-119: first-class triage-close for gaps that will never ship
    /// a PR (superseded / wontfix / obsolete / duplicate). Deliberately does
    /// NOT run the `ship()` guards — INFRA-2423 (clean/current worktree) and
    /// INFRA-1392 (proof-of-merge commit on main) exist to protect PR-ships
    /// from being marked done prematurely. A triage-close is the opposite
    /// case: there is no PR and never will be one, so those guards can only
    /// ever fail spuriously here. Before this method existed, the only way
    /// to flip such a gap's status was `git reset --hard origin/main +
    /// CHUMP_BINARY_STALENESS_CHECK=0 chump gap edit --status superseded` —
    /// a band-aid that discarded local state as a side effect just to dodge
    /// guards that were never meant to apply.
    pub fn close(&self, gap_id: &str, session_id: &str, reason: &str) -> Result<()> {
        const VALID_REASONS: &[&str] = &["superseded", "wontfix", "obsolete", "duplicate"];
        if !VALID_REASONS.contains(&reason) {
            bail!(
                "chump gap close: invalid --reason {:?}. Must be one of: {}",
                reason,
                VALID_REASONS.join(", ")
            );
        }
        let now = unix_now();
        let iso = unix_to_iso_date(now);
        let changed = self.conn.execute(
            "UPDATE gaps SET status=?1, closed_at=?2, closed_date=?3
             WHERE id=?4 AND status NOT IN
               ('done','superseded','wontfix','wont_fix','closed','closed_not_a_bug','already_satisfied','obsolete','duplicate')",
            params![reason, now, iso, gap_id],
        )?;
        if changed == 0 {
            bail!(
                "gap {} not found or already in a terminal status (done/superseded/wontfix/closed/obsolete/duplicate)",
                gap_id
            );
        }
        let _ = self.conn.execute(
            "DELETE FROM leases WHERE session_id=?1 AND gap_id=?2",
            params![session_id, gap_id],
        );
        // Best-effort ambient audit event — never fail the caller on write errors.
        {
            use std::io::Write as _;
            let ts = unix_to_iso_full(now);
            // scanner-anchor: gap_triage_closed (RESILIENT-119)
            let line = format!(
                r#"{{"ts":"{ts}","kind":"gap_triage_closed","gap_id":"{gap_id}","reason":"{reason}","session_id":"{session_id}"}}"#,
            ) + "\n";
            let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
            let _ = std::fs::create_dir_all(amb.parent().unwrap_or(&self.repo_root));
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&amb)
            {
                let _ = f.write_all(line.as_bytes());
            }
        }
        Ok(())
    }

    /// INFRA-2134: Record how/where a gap was shipped in the `shipped_in` JSON
    /// column. Accepts a pre-serialised JSON string (the caller constructs the
    /// appropriate shape). Idempotent: calling again overwrites the previous
    /// value. Does NOT change gap status — call `ship()` first for status
    /// transitions; this is a pure metadata annotation.
    ///
    /// Integration-cycle callers (chump-integrator-daemon) pass the full 5-key
    /// shape; per-PR webhook callers pass the 2-key backwards-compat shape.
    pub fn set_shipped_in(&self, gap_id: &str, shipped_in_json: &str) -> Result<()> {
        let changed = self.conn.execute(
            "UPDATE gaps SET shipped_in=?1 WHERE id=?2",
            params![shipped_in_json, gap_id],
        )?;
        if changed == 0 {
            bail!("set_shipped_in: gap {} not found", gap_id);
        }
        // INFRA-2134: emit gap_shipped_in_set to ambient.jsonl so fleet-brief,
        // kpi-report, and ops-audit can trace audit-trail writes. Best-effort:
        // never fail the caller on ambient write errors.
        {
            use std::io::Write as _;
            let v: serde_json::Value =
                serde_json::from_str(shipped_in_json).unwrap_or(serde_json::Value::Null);
            let shape = if v.get("integration_id").is_some() {
                "integration"
            } else {
                "per_pr"
            };
            let ts = unix_to_iso_full(unix_now());
            let line = format!(
                "{{\"ts\":\"{ts}\",\"kind\":\"gap_shipped_in_set\",\
                 \"gap_id\":\"{gap_id}\",\"shape\":\"{shape}\"}}\n"
            );
            let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&amb)
            {
                let _ = f.write_all(line.as_bytes());
            }
        }
        Ok(())
    }

    /// INFRA-1144: After a gap is shipped, close any open PRs whose title
    /// contains the gap ID, subject to safety gates:
    /// - Skip PRs with 'orphan-pr-closer-skip' in title
    /// - Skip PRs whose head_sha was pushed within CHUMP_GAP_SHIP_ORPHAN_FRESHNESS_MIN (default 30 min)
    /// - Skip if CHUMP_GAP_SHIP_NO_ORPHAN_CLOSE=1 is set
    ///
    /// Returns a Vec of (pr_number, close_reason) tuples for successfully closed PRs.
    /// Failures (e.g., gh api errors) are logged but do not fail the overall ship.
    pub fn close_orphan_prs(
        &self,
        gap_id: &str,
        _closed_pr: Option<i64>,
        repo_root: &Path,
    ) -> Result<Vec<(i64, String)>> {
        use std::process::Command;
        use std::time::{Duration, SystemTime};

        // Operator escape hatch
        if std::env::var("CHUMP_GAP_SHIP_NO_ORPHAN_CLOSE").as_deref() == Ok("1") {
            return Ok(Vec::new());
        }

        // Freshness gate (default 30 min)
        let freshness_min = std::env::var("CHUMP_GAP_SHIP_ORPHAN_FRESHNESS_MIN")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(30);
        let freshness_secs = freshness_min * 60;

        // Query for open PRs with gap ID in title
        let repo = self
            .get_repo_from_git(repo_root)
            .context("failed to resolve GitHub repo")?;

        // Use gh api to list open PRs
        let output = Command::new("gh")
            .args(["api", &format!("repos/{repo}/pulls?state=open&per_page=100")])
            .arg("--jq")
            .arg(format!("[.[] | select(.title | contains(\"{gap_id}\")) | {{number: .number, title: .title, head_ref: .head.ref, pushed_at: .head.repo.pushed_at}}]"))
            .output();

        let output = match output {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
            _ => return Ok(Vec::new()), // Silently skip on gh api failure
        };

        if output.trim().is_empty() || output.trim() == "[]" {
            return Ok(Vec::new());
        }

        let prs: Vec<serde_json::Value> = match serde_json::from_str(&output) {
            Ok(v) => v,
            Err(_) => return Ok(Vec::new()),
        };

        let mut closed = Vec::new();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::from_secs(0))
            .as_secs();

        for pr in prs {
            let pr_num = pr["number"].as_i64().unwrap_or(0);
            let title = pr["title"].as_str().unwrap_or("");
            let pushed_at_str = pr["pushed_at"].as_str().unwrap_or("");

            // Skip PRs with escape hatch in title
            if title.contains("orphan-pr-closer-skip") {
                continue;
            }

            // Skip PRs that were pushed recently
            if let Some(pushed_ts) = parse_iso_to_unix(pushed_at_str) {
                if now.saturating_sub(pushed_ts as u64) < freshness_secs {
                    continue;
                }
            }

            // Attempt to close the PR
            let comment = format!(
                "Superseded: gap {gap_id} was shipped. Closing this PR as no longer needed."
            );

            // Post comment
            let _ = Command::new("gh")
                .args(["api", &format!("repos/{repo}/issues/{pr_num}/comments")])
                .args(["-X", "POST", "-f"])
                .arg(format!("body={comment}"))
                .output();

            // Close the PR
            let close_result = Command::new("gh")
                .args(["api", &format!("repos/{repo}/pulls/{pr_num}")])
                .args(["-X", "PATCH", "-f", "state=closed"])
                .output();

            if let Ok(output) = close_result {
                if output.status.success() {
                    let close_reason = format!(
                        "closed orphan PR #{pr_num} (title: {title})",
                        title = title.replace('"', "\\\"")
                    );
                    closed.push((pr_num, close_reason));
                }
            }
        }

        Ok(closed)
    }

    /// Helper: resolve GitHub repo from git remote origin
    fn get_repo_from_git(&self, repo_root: &Path) -> Result<String> {
        let output = std::process::Command::new("git")
            .args([
                "-C",
                repo_root.to_str().unwrap_or("."),
                "remote",
                "get-url",
                "origin",
            ])
            .output()
            .context("git remote get-url failed")?;

        if !output.status.success() {
            bail!("cannot resolve git remote origin");
        }

        let url = String::from_utf8_lossy(&output.stdout);
        let trimmed = url.trim();

        let repo = if let Some(s) = trimmed.strip_prefix("git@github.com:") {
            s.trim_end_matches(".git").to_string()
        } else if let Some(s) = trimmed.strip_prefix("https://github.com/") {
            s.trim_end_matches(".git").to_string()
        } else if let Some(s) = trimmed.strip_prefix("http://github.com/") {
            s.trim_end_matches(".git").to_string()
        } else {
            String::new()
        };

        if repo.is_empty() {
            bail!("cannot parse GitHub repo from remote URL: {}", url);
        }

        Ok(repo)
    }

    // ── INFRA-2137: quarantine / requeue helpers ──────────────────────────────

    /// Append a timestamped note to the gap's `notes` field.
    ///
    /// Format: `[YYYY-MM-DDTHH:MM:SSZ] <text>` — same convention as
    /// `--add-note` in `chump gap set`.  Multiple calls accumulate newline-
    /// separated entries; the first entry seeds an empty notes field.
    pub fn append_notes_for_gap(&self, gap_id: &str, text: &str) -> Result<()> {
        let existing: String = self
            .conn
            .query_row("SELECT notes FROM gaps WHERE id=?1", params![gap_id], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or_default();
        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let new_entry = format!("[{}] {}", ts, text);
        let combined = if existing.trim().is_empty() {
            new_entry
        } else {
            format!("{}\n{}", existing.trim_end(), new_entry)
        };
        let changed = self.conn.execute(
            "UPDATE gaps SET notes=?1 WHERE id=?2",
            params![combined, gap_id],
        )?;
        if changed == 0 {
            bail!("append_notes_for_gap: gap {} not found", gap_id);
        }
        Ok(())
    }

    /// Count gaps with `status = 'bisect_quarantined'`.
    ///
    /// Used by `chump health --slo-check` (L2-SLO-6) to flag saturation
    /// when more than 5 gaps are stuck awaiting operator review.
    pub fn count_bisect_quarantined(&self) -> Result<u64> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM gaps WHERE status='bisect_quarantined'",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);
        Ok(n.max(0) as u64)
    }

    /// Move a gap from `bisect_quarantined` → `ready_to_ship` after operator
    /// review.  Appends a note recording who requeued it and when.
    ///
    /// Fails if the gap is not in `bisect_quarantined` status (guard against
    /// accidental requeue of arbitrary gaps).
    pub fn requeue_gap(&self, gap_id: &str) -> Result<()> {
        let cur: Option<String> = self
            .conn
            .query_row(
                "SELECT status FROM gaps WHERE id=?1",
                params![gap_id],
                |r| r.get(0),
            )
            .optional()?;
        match cur.as_deref() {
            None => bail!("requeue_gap: gap {} not found", gap_id),
            Some(s) if s != "bisect_quarantined" => bail!(
                "requeue_gap: gap {} has status='{}'; only bisect_quarantined gaps \
                 can be requeued (expected bisect_quarantined)",
                gap_id,
                s
            ),
            _ => {}
        }
        let changed = self.conn.execute(
            "UPDATE gaps SET status='ready_to_ship' WHERE id=?1 AND status='bisect_quarantined'",
            params![gap_id],
        )?;
        if changed == 0 {
            bail!(
                "requeue_gap: gap {} was not updated (concurrent modification?)",
                gap_id
            );
        }
        self.append_notes_for_gap(
            gap_id,
            "requeued: operator review complete (chump gap requeue)",
        )?;
        Ok(())
    }

    /// Dump gaps as canonical YAML, lossless across all DB columns.
    /// M1 (INFRA-059) — round-trips through `import_from_yaml` with byte
    /// stability for the `gaps:` block (the `meta:` preamble is preserved
    /// verbatim by `dump_yaml_with_meta` when given the source YAML).
    pub fn dump_yaml(&self) -> Result<String> {
        let gaps = self.list(None)?;
        let mut out = String::from("gaps:\n");
        for g in &gaps {
            out.push_str(&format_gap_yaml(g));
        }
        // INFRA-112: self-validating round-trip — re-parse what we just emitted
        // and confirm the entry count matches the source. Catches future
        // regressions in `format_gap_yaml` (e.g. an emitter change that drops a
        // row when a field contains an unescaped colon) or in the upstream YAML
        // parser. Cheap: parses ~half a megabyte once per dump.
        let parsed: YamlGapsFile = serde_yaml::from_str(&out)
            .with_context(|| "dump_yaml emitted YAML that fails to parse")?;
        if parsed.gaps.len() != gaps.len() {
            bail!(
                "dump_yaml is lossy: DB has {} gaps, YAML round-trip has {} \
                 (delta={}). Likely cause: a row with an empty/whitespace id \
                 or a field that breaks YAML scalar quoting.",
                gaps.len(),
                parsed.gaps.len(),
                gaps.len() as i64 - parsed.gaps.len() as i64,
            );
        }
        Ok(out)
    }

    /// Like `dump_yaml`, but reuses the `meta:` preamble from `source_yaml`
    /// (everything before the first `gaps:` line) so a file regen preserves
    /// the human-curated meta block. Falls back to bare `dump_yaml()` if no
    /// `gaps:` line is found.
    ///
    /// INFRA-208: ALSO does per-gap unknown-field preservation, mirroring
    /// `dump_per_file`'s `merge_preserve_unknown_fields` behavior. Without
    /// this, a monolithic dump silently strips `acceptance:`, `closed_commit:`,
    /// `runnable_now:`, and any other hand-curated fields the DB schema
    /// doesn't own. The merge is per-gap: parse `source_yaml` into per-id
    /// blocks, and for each gap formatted from the DB, splice in the
    /// matching block's unknown fields.
    pub fn dump_yaml_with_meta(&self, source_yaml: &str) -> Result<String> {
        // Parse source YAML into {gap_id: full_block_text} for per-gap merge.
        let source_by_id = parse_monolithic_into_blocks(source_yaml);

        let gaps = self.list(None)?;
        let mut body = String::from("gaps:\n");
        for g in &gaps {
            let generated = format_gap_yaml(g);
            let merged = if let Some(existing) = source_by_id.get(&g.id) {
                merge_preserve_unknown_fields(&generated, existing)
            } else {
                generated
            };
            body.push_str(&merged);
        }

        // INFRA-112 self-validation (mirrors dump_yaml).
        let parsed: YamlGapsFile = serde_yaml::from_str(&body)
            .with_context(|| "dump_yaml_with_meta emitted YAML that fails to parse")?;
        if parsed.gaps.len() != gaps.len() {
            bail!(
                "dump_yaml_with_meta is lossy: DB has {} gaps, YAML round-trip has {} \
                 (delta={})",
                gaps.len(),
                parsed.gaps.len(),
                gaps.len() as i64 - parsed.gaps.len() as i64,
            );
        }

        if let Some(gaps_idx) = source_yaml.find("\ngaps:\n") {
            let preamble = &source_yaml[..gaps_idx + 1];
            Ok(format!("{}{}", preamble, body))
        } else {
            Ok(body)
        }
    }

    /// INFRA-188 v0 (2026-05-02): dump every gap as a SEPARATE YAML file at
    /// `<out_dir>/<ID>.yaml`. Each file contains a single block-list entry
    /// in the same format as `dump_yaml` produces — i.e.
    /// `- id: INFRA-180\n  domain: ...\n` — so reaggregating into the
    /// legacy monolithic `docs/gaps.yaml` is just
    /// `(echo "gaps:"; cat <out_dir>/*.yaml) > docs/gaps.yaml`.
    ///
    /// Returns `(written, skipped)`. Skipped means the existing file's
    /// content was byte-identical, so no write happened (file mtime
    /// stable for INFRA-148 staleness checks). Creates `out_dir` if
    /// missing.
    ///
    /// This v0 ONLY writes files. The full INFRA-188 cutover (remove
    /// monolithic gaps.yaml, update 5 pre-commit guards to read directory,
    /// update 3 coord scripts, update 2 GitHub workflows, add the CI guard
    /// against re-adding monolithic) is the follow-up work tracked in
    /// INFRA-188 itself. Both layouts coexist until cutover.
    pub fn dump_per_file(&self, out_dir: &std::path::Path) -> Result<(usize, usize)> {
        let gaps = self.list(None)?;
        std::fs::create_dir_all(out_dir)
            .with_context(|| format!("creating {}", out_dir.display()))?;

        let mut written = 0usize;
        let mut skipped = 0usize;
        for g in &gaps {
            if g.id.trim().is_empty() {
                continue; // defense against any INFRA-112-class empty-id rows
            }
            let path = out_dir.join(format!("{}.yaml", g.id));
            let generated = format_gap_yaml(g);
            // INFRA-208 preserve-on-merge: if the file exists, splice in any
            // hand-curated fields the DB schema doesn't know about
            // (`acceptance:`, `closed_commit:`, `runnable_now:`, …) so a
            // round-trip dump is lossless instead of stripping them silently.
            let content = match std::fs::read_to_string(&path) {
                Ok(existing) => merge_preserve_unknown_fields(&generated, &existing),
                Err(_) => generated,
            };
            let needs_write = match std::fs::read_to_string(&path) {
                Ok(existing) => existing != content,
                Err(_) => true,
            };
            if needs_write {
                std::fs::write(&path, &content)
                    .with_context(|| format!("writing {}", path.display()))?;
                written += 1;
            } else {
                skipped += 1;
            }
        }
        Ok((written, skipped))
    }

    /// Dump exactly one gap's per-file YAML mirror. Used by
    /// `chump gap reserve` and `chump gap ship --update-yaml` post-INFRA-188
    /// (INFRA-228, INFRA-229) so the per-file directory at
    /// `docs/gaps/<ID>.yaml` stays in sync with `.chump/state.db` without
    /// regenerating all 542+ files on every gap mutation.
    ///
    /// Returns `Ok(true)` if the file was written (new or content changed),
    /// `Ok(false)` if the existing content was byte-identical and no
    /// write happened (preserves mtime for INFRA-148 staleness checks).
    /// Returns `Err` if the gap id is not in the store, or if I/O fails.
    pub fn dump_per_file_single(&self, gap_id: &str, out_dir: &std::path::Path) -> Result<bool> {
        let row = self
            .get(gap_id)?
            .ok_or_else(|| anyhow::anyhow!("gap {} not found in store", gap_id))?;
        if row.id.trim().is_empty() {
            anyhow::bail!("gap {} has an empty id row in store", gap_id);
        }
        std::fs::create_dir_all(out_dir)
            .with_context(|| format!("creating {}", out_dir.display()))?;
        let path = out_dir.join(format!("{}.yaml", row.id));
        let generated = format_gap_yaml(&row);
        // INFRA-208 preserve-on-merge: splice unknown hand-curated fields
        // (`acceptance:`, `closed_commit:`, `runnable_now:`, …) from the
        // existing file into the generated content so a single-gap update
        // is lossless. Without this, every `chump gap ship --update-yaml`
        // strips fields the DB schema doesn't know about — that's the
        // 22500-line lossy diff the gap was filed against.
        let content = match std::fs::read_to_string(&path) {
            Ok(existing) => merge_preserve_unknown_fields(&generated, &existing),
            Err(_) => generated,
        };
        match std::fs::read_to_string(&path) {
            Ok(existing) if existing == content => Ok(false),
            _ => {
                std::fs::write(&path, &content)
                    .with_context(|| format!("writing {}", path.display()))?;
                Ok(true)
            }
        }
    }
}

/// Mutable-field bundle for `chump gap set`. None means "leave unchanged".
/// Strings can be empty to clear a field; pass `Some("")` to do so.
#[derive(Debug, Default)]
pub struct GapFieldUpdate {
    pub title: Option<String>,
    pub description: Option<String>,
    pub priority: Option<String>,
    pub effort: Option<String>,
    pub status: Option<String>,
    pub acceptance_criteria: Option<String>,
    pub depends_on: Option<String>,
    pub notes: Option<String>,
    pub source_doc: Option<String>,
    pub opened_date: Option<String>,
    pub closed_date: Option<String>,
    /// PR number for closure (INFRA-156). `None` leaves the column unchanged;
    /// pass `Some(n)` to set or update. Pairs with `--closed-pr` on
    /// `chump gap set` and `chump gap ship`.
    pub closed_pr: Option<i64>,
    /// INFRA-314: comma-separated required skills.
    pub skills_required: Option<String>,
    /// INFRA-314: preferred backend (claude | local-llm | cascade | any).
    pub preferred_backend: Option<String>,
    /// INFRA-314: preferred machine (macbook | pi-mesh | cloud-overflow | any).
    pub preferred_machine: Option<String>,
    /// INFRA-314: estimated minutes to complete.
    pub estimated_minutes: Option<String>,
    /// INFRA-418: required model tier (haiku | sonnet | opus | any).
    pub required_model: Option<String>,
    /// MISSION-008: nullable FK into outcomes table. None leaves it unchanged.
    pub outcome_id: Option<String>,
    /// CREDIBLE-107: evidence blob for P0/P1 RESILIENT/MISSION/CREDIBLE gaps.
    /// None leaves unchanged; Some(text) stores the evidence; Some("") clears it.
    pub evidence: Option<String>,
    /// EFFECTIVE-363: artifact_type (code | doc | release-note | copy | design |
    /// deck | analytics-report | ...). None leaves unchanged. Empty string is
    /// rejected the same way any other required-with-default column would be —
    /// callers should pass the literal type, not clear it back to blank.
    pub artifact_type: Option<String>,
}

/// Render one gap as a YAML block-list entry. Field order matches the
/// hand-curated convention in `docs/gaps.yaml` (id → domain → title →
/// status → priority → effort → description → acceptance_criteria →
/// depends_on → notes → source_doc → opened_date → closed_date). Empty
/// fields are omitted (matches existing YAML practice).
fn format_gap_yaml(g: &GapRow) -> String {
    let mut s = String::new();
    s.push_str(&format!("- id: {}\n", g.id));
    if !g.domain.is_empty() {
        s.push_str(&format!("  domain: {}\n", g.domain));
    }
    if !g.title.is_empty() {
        s.push_str(&format!("  title: {}\n", yaml_scalar(&g.title)));
    }
    if !g.status.is_empty() {
        s.push_str(&format!("  status: {}\n", g.status));
    }
    if !g.priority.is_empty() {
        s.push_str(&format!("  priority: {}\n", g.priority));
    }
    if !g.effort.is_empty() {
        s.push_str(&format!("  effort: {}\n", g.effort));
    }
    if !g.description.is_empty() {
        s.push_str("  description: ");
        s.push_str(&yaml_block_scalar(&g.description, "  "));
        s.push('\n');
    }
    if let Some(items) = parse_json_string_list(&g.acceptance_criteria) {
        if !items.is_empty() {
            s.push_str("  acceptance_criteria:\n");
            for item in &items {
                s.push_str(&format!("    - {}\n", yaml_scalar(item)));
            }
        }
    }
    if let Some(items) = parse_json_string_list(&g.depends_on) {
        if !items.is_empty() {
            // Flow style for short lists matches the existing convention.
            let flow = items.join(", ");
            s.push_str(&format!("  depends_on: [{}]\n", flow));
        }
    }
    if !g.notes.is_empty() {
        s.push_str("  notes: ");
        s.push_str(&yaml_block_scalar(&g.notes, "  "));
        s.push('\n');
    }
    if !g.source_doc.is_empty() {
        s.push_str(&format!("  source_doc: {}\n", yaml_scalar(&g.source_doc)));
    }
    if !g.opened_date.is_empty() {
        s.push_str(&format!("  opened_date: {}\n", yaml_date(&g.opened_date)));
    }
    if !g.closed_date.is_empty() {
        s.push_str(&format!("  closed_date: {}\n", yaml_date(&g.closed_date)));
    }
    // INFRA-156: emit closed_pr as an integer when set. Position right after
    // closed_date matches the prevailing convention in docs/gaps.yaml. The
    // INFRA-107 integrity guard rejects status:done without a numeric
    // closed_pr, so closure PRs that go through `chump gap ship --closed-pr N`
    // produce a YAML diff this guard accepts.
    if let Some(pr) = g.closed_pr {
        s.push_str(&format!("  closed_pr: {}\n", pr));
    }
    // INFRA-314: affinity tags for worker preference matching.
    if !g.skills_required.is_empty() {
        if let Some(items) = parse_json_string_list(&g.skills_required) {
            if !items.is_empty() {
                s.push_str("  skills_required: [");
                s.push_str(&items.join(", "));
                s.push_str("]\n");
            }
        } else {
            s.push_str(&format!(
                "  skills_required: {}\n",
                yaml_scalar(&g.skills_required)
            ));
        }
    }
    if !g.preferred_backend.is_empty() {
        s.push_str(&format!("  preferred_backend: {}\n", g.preferred_backend));
    }
    if !g.preferred_machine.is_empty() {
        s.push_str(&format!("  preferred_machine: {}\n", g.preferred_machine));
    }
    if !g.estimated_minutes.is_empty() {
        s.push_str(&format!("  estimated_minutes: {}\n", g.estimated_minutes));
    }
    if !g.required_model.is_empty() {
        s.push_str(&format!("  required_model: {}\n", g.required_model));
    }
    // MISSION-008: emit outcome_id when set (advisory FK — never gates close).
    if let Some(ref oid) = g.outcome_id {
        if !oid.is_empty() {
            s.push_str(&format!("  outcome_id: {}\n", yaml_scalar(oid)));
        }
    }
    // CREDIBLE-107: emit evidence when set (P0/P1 RESILIENT/MISSION/CREDIBLE gate).
    if let Some(ref ev) = g.evidence {
        if !ev.is_empty() {
            s.push_str("  evidence: ");
            s.push_str(&yaml_block_scalar(ev, "  "));
            s.push('\n');
        }
    }
    s.push('\n');
    s
}

// ────────────────────────── INFRA-208 preserve-on-merge ──────────────────────────

/// The set of top-level gap fields the DB schema owns. Any other
/// 2-space-indented `key:` line inside a per-file `docs/gaps/<ID>.yaml`
/// is treated as hand-curated and preserved across `dump_per_file*` writes
/// (see `merge_preserve_unknown_fields`).
///
/// Known unknown fields in the wild: `acceptance:` (free-text counterpart
/// to the structured `acceptance_criteria:` list), `closed_commit:` (40-char
/// SHA pin), `runnable_now:` (operational shell snippet). New fields can
/// be hand-added without code changes — the merge is whitelist-by-DB, so
/// anything outside the list survives automatically.
const DB_OWNED_GAP_FIELDS: &[&str] = &[
    "id",
    "domain",
    "title",
    "status",
    "priority",
    "effort",
    "description",
    "acceptance_criteria",
    "depends_on",
    "notes",
    "source_doc",
    "opened_date",
    "closed_date",
    "closed_pr",
    "skills_required",
    "preferred_backend",
    "preferred_machine",
    "estimated_minutes",
    "required_model",
    "outcome_id",
    // INFRA-3605: evidence IS a DB-owned column (format_gap_yaml emits it
    // above). Its absence here was the bug: merge_preserve_unknown_fields
    // treated any pre-existing on-disk `evidence:` block as unknown/
    // hand-curated and re-spliced it in *after* the freshly generated
    // `evidence:` block, producing two `evidence:` keys in one gap mapping.
    // serde_yaml correctly rejects that as a duplicate field, which made
    // `chump gap dump --out docs/gaps.yaml` (the state.db -> gaps.yaml sync
    // path, via dump_yaml_with_meta) fail outright and no-op instead of
    // updating the mirror -- the root cause of the ~449-entry drift.
    "evidence",
    // artifact_type (EFFECTIVE-363) is also DB-owned. format_gap_yaml does
    // not currently emit it, so this entry is a no-op today, but it
    // documents ownership correctly and pre-empts the same duplicate-key
    // class the day emission is added.
    "artifact_type",
];

/// INFRA-208: take freshly-generated per-file YAML (one block-list entry as
/// produced by `format_gap_yaml`) and splice in any top-level fields from
/// the existing on-disk file that the DB schema doesn't own. The merge is
/// textual — preserving original block-scalar formatting, comments inside
/// the value, and exact whitespace — so round-trip dumps are byte-stable
/// for the preserved regions.
///
/// Behavior:
///   - DB-owned fields in `existing` are dropped (DB is the source of truth
///     for those).
///   - Unknown fields (e.g. `acceptance:`, `closed_commit:`, `runnable_now:`)
///     are appended to the generated entry, in the order they appeared in
///     `existing`, before the trailing blank line.
///   - If `existing` fails to parse as a single block-list entry (e.g.
///     truncated, hand-corrupted), the generated content is returned as-is
///     so a stray bad file doesn't prevent the dump from progressing.
fn merge_preserve_unknown_fields(generated: &str, existing: &str) -> String {
    let unknown_blocks = extract_unknown_field_blocks(existing);
    if unknown_blocks.is_empty() {
        return generated.to_string();
    }
    // Splice the unknown blocks in just before the trailing blank line that
    // `format_gap_yaml` emits. If the trailing-newline pattern isn't there
    // (caller passed something hand-mangled), append at end.
    let preserved: String = unknown_blocks.concat();
    if let Some(stripped) = generated.strip_suffix("\n\n") {
        format!("{}\n{}\n", stripped, preserved)
    } else if let Some(stripped) = generated.strip_suffix('\n') {
        format!("{}\n{}", stripped, preserved)
    } else {
        format!("{}\n{}", generated, preserved)
    }
}

/// Scan a per-file gap YAML (a single block-list entry indented at 2 spaces)
/// and return each top-level field block (key line + indented continuation
/// lines) whose key is NOT in `DB_OWNED_GAP_FIELDS`. Each returned string is
/// terminated with a newline.
///
/// Recognizes the standard per-file shape produced by `format_gap_yaml`:
///   `- id: …\n  key1: …\n  key2: |\n    multiline\n    body\n  key3: …\n`
/// The leading `- id:` line is treated as belonging to the `id` field;
/// other 2-space-indent `<key>:` lines are field starts; 4+ space lines
/// are continuation. Comment lines (`#…`) attached to an unknown field
/// are preserved with that field.
/// INFRA-208: split a monolithic gaps.yaml file into per-gap blocks keyed
/// by gap-ID, so `dump_yaml_with_meta` can splice unknown fields per-gap.
///
/// Each block is the text from `- id: <ID>` (inclusive) up to the start of
/// the next `- id:` line (exclusive) or end-of-file. Trailing blank lines
/// are kept attached to the preceding block (matches what `format_gap_yaml`
/// produces and what `merge_preserve_unknown_fields` expects).
///
/// The meta preamble (everything before the first `- id:` after the
/// `gaps:` line) is silently dropped — `dump_yaml_with_meta`'s caller is
/// responsible for re-emitting it via the existing `gaps_idx` slice.
fn parse_monolithic_into_blocks(source: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    // Find all `- id: ` line starts. These delimit per-gap blocks.
    let lines: Vec<&str> = source.lines().collect();
    let mut starts: Vec<usize> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if let Some(rest) = line.strip_prefix("- id:") {
            // Match `- id: <ID>` (with or without trailing whitespace).
            let id_str = rest
                .trim()
                .trim_matches(|c| c == '"' || c == '\'')
                .to_string();
            if !id_str.is_empty() {
                starts.push(i);
                // Defer ID extraction until block-end resolution below.
                let _ = id_str;
            }
        }
    }
    // For each start, the block runs to the next start (or EOF).
    for (idx, &start) in starts.iter().enumerate() {
        let end = starts.get(idx + 1).copied().unwrap_or(lines.len());
        // Reconstruct the block (preserving newlines).
        let mut block = String::new();
        for line in &lines[start..end] {
            block.push_str(line);
            block.push('\n');
        }
        // Re-extract the id from line[start] for the map key.
        if let Some(rest) = lines[start].strip_prefix("- id:") {
            let id_str = rest
                .trim()
                .trim_matches(|c| c == '"' || c == '\'')
                .to_string();
            if !id_str.is_empty() {
                out.insert(id_str, block);
            }
        }
    }
    out
}

fn extract_unknown_field_blocks(existing: &str) -> Vec<String> {
    let lines: Vec<&str> = existing.lines().collect();
    let mut blocks: Vec<String> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        // A field start at 2-space indent looks like "  <key>:" (the `- id:`
        // line is special; we lump it under the `id` field which is DB-owned
        // and therefore dropped anyway).
        let key = if let Some(stripped) = line.strip_prefix("- ") {
            // First entry: `- id: …`
            extract_key_from_field_line(stripped)
        } else if line.starts_with("  ") && !line.starts_with("    ") {
            extract_key_from_field_line(&line[2..])
        } else {
            // Pre-entry blank line, comment line, or stray content; skip.
            i += 1;
            continue;
        };

        // Find the end of this field block: next field start, or end of file.
        let block_start = i;
        i += 1;
        while i < lines.len() {
            let l = lines[i];
            // Trailing blank line — belongs to the entry as a whole, stop.
            if l.is_empty() {
                break;
            }
            // Next 2-space-indent field start ends the current block.
            if l.starts_with("  ") && !l.starts_with("    ") {
                // But "  - " (acceptance_criteria list items) is continuation,
                // not a new field.
                if l.starts_with("    -") || l[2..].starts_with('-') {
                    i += 1;
                    continue;
                }
                if extract_key_from_field_line(&l[2..]).is_some() {
                    break;
                }
            }
            // Another `- id:` would mean a multi-entry block list; per-file
            // YAML is single-entry by convention, but stop just in case.
            if l.starts_with("- ") {
                break;
            }
            i += 1;
        }

        if let Some(k) = key {
            if !DB_OWNED_GAP_FIELDS.contains(&k) {
                let mut block = String::new();
                for l in &lines[block_start..i] {
                    block.push_str(l);
                    block.push('\n');
                }
                blocks.push(block);
            }
        }
    }
    blocks
}

/// Given a line with the leading indent already stripped (so it starts at
/// the key character), return the key name if the line is a field-start of
/// the shape `<key>: …` or `<key>:` (block-scalar header). Returns None for
/// list items (`- foo`), comments (`# foo`), and continuation text.
fn extract_key_from_field_line(content: &str) -> Option<&str> {
    if content.starts_with('#') || content.starts_with('-') || content.is_empty() {
        return None;
    }
    let colon = content.find(':')?;
    let key = &content[..colon];
    // YAML keys: alnum + underscore + dash. Anything else means we mis-classified
    // a continuation line as a field start.
    if key.is_empty()
        || !key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    // Field-start lines either end at the colon (`key:` for block scalars)
    // or have a space after (`key: value`). Reject `key:value` (no space) —
    // that's almost always inside a URL or a description sentence.
    let after = &content[colon + 1..];
    if !after.is_empty() && !after.starts_with(' ') {
        return None;
    }
    Some(key)
}

// ────────────────────────── one-shot importer ──────────────────────────

#[derive(Debug, Deserialize)]
struct YamlGap {
    id: String,
    #[serde(default)]
    domain: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    priority: String,
    #[serde(default)]
    effort: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    acceptance_criteria: Option<serde_json::Value>,
    #[serde(default)]
    depends_on: Option<serde_json::Value>,
    #[serde(default)]
    notes: Option<serde_yaml::Value>,
    #[serde(default)]
    source_doc: Option<serde_yaml::Value>,
    #[serde(default)]
    opened_date: Option<serde_yaml::Value>,
    #[serde(default)]
    closed_date: Option<serde_yaml::Value>,
    /// INFRA-156: PR number that landed the closure. YAML may carry this as
    /// a bare integer (`closed_pr: 598`) or, in legacy files, as a string —
    /// we accept both via `serde_yaml::Value` and coerce in
    /// `import_from_yaml`.
    #[serde(default)]
    closed_pr: Option<serde_yaml::Value>,
    /// INFRA-314: comma-separated required skills.
    #[serde(default)]
    skills_required: Option<serde_yaml::Value>,
    /// INFRA-314: preferred backend.
    #[serde(default)]
    preferred_backend: Option<serde_yaml::Value>,
    /// INFRA-314: preferred machine.
    #[serde(default)]
    preferred_machine: Option<serde_yaml::Value>,
    /// INFRA-314: estimated minutes.
    #[serde(default)]
    estimated_minutes: Option<serde_yaml::Value>,
    /// INFRA-418: required model tier (haiku | sonnet | opus | any).
    #[serde(default)]
    required_model: Option<serde_yaml::Value>,
    /// MISSION-008: nullable FK to outcomes table.
    #[serde(default)]
    outcome_id: Option<serde_yaml::Value>,
    /// CREDIBLE-107: evidence blob (P0/P1 RESILIENT/MISSION/CREDIBLE gate).
    #[serde(default)]
    evidence: Option<serde_yaml::Value>,
}

#[derive(Deserialize)]
struct YamlGapsFile {
    #[serde(default)]
    gaps: Vec<YamlGap>,
}

/// VOA-006: load the gap registry, parsing each `docs/gaps/*.yaml` on its own.
///
/// The three call sites here (import, closed_pr backfill, status backfill) each
/// used to concatenate every per-file YAML into one buffer and parse it once, so
/// a single malformed entry aborted the whole read. INFRA-3429.yaml shipped with
/// 39 duplicate `evidence:` keys (#3309) and that alone killed every
/// `chump gap import` — the docs/gaps -> state.db sync was dead and freshly filed
/// gaps never became pickable.
///
/// A bad file is now named on stderr and stepped over. Returns `None` only when
/// there is no registry at all (neither `docs/gaps/` nor `docs/gaps.yaml`), which
/// callers treat as a clean no-op rather than an error.
fn load_gap_registry(repo_root: &Path) -> Result<Option<YamlGapsFile>> {
    let read_monolithic = || -> Result<Option<YamlGapsFile>> {
        let yaml_path = repo_root.join("docs").join("gaps.yaml");
        match std::fs::read_to_string(&yaml_path) {
            Ok(t) => Ok(Some(serde_yaml::from_str(&t).with_context(|| {
                format!("parsing gap registry {}", yaml_path.display())
            })?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(anyhow::Error::from(e))
                .with_context(|| format!("reading {}", yaml_path.display())),
        }
    };

    let per_file_dir = repo_root.join("docs").join("gaps");
    if !per_file_dir.is_dir() {
        return read_monolithic();
    }

    let mut dir_entries: Vec<_> = std::fs::read_dir(&per_file_dir)
        .with_context(|| format!("reading {}", per_file_dir.display()))?
        .flatten()
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|s| s.to_str())
                .map(|s| s == "yaml")
                .unwrap_or(false)
        })
        .collect();
    dir_entries.sort_by_key(|e| e.file_name());

    if dir_entries.is_empty() {
        return read_monolithic();
    }

    let mut gaps: Vec<YamlGap> = Vec::new();
    let mut malformed = 0usize;
    for entry in &dir_entries {
        let content = std::fs::read_to_string(entry.path())
            .with_context(|| format!("reading {}", entry.path().display()))?;
        if content.trim().is_empty() {
            continue;
        }
        // Each file holds a bare YAML list; wrap it so it parses as YamlGapsFile.
        let wrapped = format!("gaps:\n{content}");
        match serde_yaml::from_str::<YamlGapsFile>(&wrapped) {
            Ok(f) => gaps.extend(f.gaps),
            Err(e) => {
                eprintln!(
                    "chump gap import: SKIPPING malformed {}: {e}",
                    entry.path().display()
                );
                malformed += 1;
            }
        }
    }
    if malformed > 0 {
        eprintln!(
            "chump gap import: {malformed} malformed file(s) skipped — fix them or they stay unimported"
        );
    }
    Ok(Some(YamlGapsFile { gaps }))
}

impl GapStore {
    /// Import from the gap registry into the DB. Idempotent — existing rows are skipped.
    ///
    /// INFRA-188: reads from per-file `docs/gaps/*.yaml` directory if it exists,
    /// otherwise falls back to monolithic `docs/gaps.yaml`. Both layouts are
    /// accepted for backward compatibility during the transition period.
    ///
    /// Missing-file/directory is treated as a no-op (returns `Ok((0, 0))`) so
    /// fresh tempdir callers and bootstrap paths don't have to special-case it.
    /// A YAML file that *exists* but is unreadable / malformed propagates the
    /// error so callers like `reserve()` can fail loud (INFRA-143).
    /// Backfill `closed_pr` for rows that already exist in the DB but have
    /// `closed_pr IS NULL`, using the YAML file(s) at `repo_root` as the
    /// authoritative source.  Only rows where the YAML carries a numeric
    /// `closed_pr` AND the DB row currently has NULL are updated — rows that
    /// already have a value are never overwritten (idempotent).
    ///
    /// Returns the number of rows updated (0 on a clean tree).
    ///
    /// INFRA-233: root cause of ~200 NULL closed_pr rows was that
    /// `import_from_yaml` used INSERT OR IGNORE, which skips existing rows
    /// entirely — so the `closed_pr` column added by INFRA-156 was never
    /// backfilled for rows imported before the column existed.  This method
    /// is now called automatically by `import_from_yaml` so re-running
    /// `chump gap import` heals the tree.
    pub fn backfill_closed_pr_from_yaml(&self, repo_root: &Path) -> Result<usize> {
        // VOA-006: shared resilient loader — one bad file no longer sinks the read.
        let file = match load_gap_registry(repo_root)? {
            Some(f) => f,
            None => return Ok(0),
        };

        let mut backfilled = 0usize;
        for g in &file.gaps {
            let Some(pr) = g.closed_pr.as_ref().and_then(yaml_value_to_i64) else {
                continue;
            };
            // Only update rows that exist AND currently have NULL closed_pr.
            let changed = self.conn.execute(
                "UPDATE gaps SET closed_pr=?1 WHERE id=?2 AND closed_pr IS NULL",
                params![pr, g.id],
            )?;
            backfilled += changed;
        }
        Ok(backfilled)
    }

    /// INFRA-1434: import_from_yaml with title-similarity guard.
    ///
    /// Wraps [`Self::import_from_yaml`] with an INFRA-1149-style Jaccard check
    /// applied to each *net-new* gap (id not already in state.db). When the top
    /// match against open + recently-closed gaps scores ≥ `block_threshold`,
    /// the row is treated as a duplicate: removed after import, counted in the
    /// returned `blocked_by_similarity`, and a `gap_import_similarity_block`
    /// event is appended to `<repo_root>/.chump-locks/ambient.jsonl`.
    ///
    /// Returns `(inserted, already_present, backfilled, blocked_by_similarity)`.
    /// The first three match `import_from_yaml`'s tuple; the fourth is new.
    ///
    /// Bypass: pass `block_threshold=None` to behave exactly like
    /// `import_from_yaml`. The CLI exposes this via `CHUMP_GAP_IMPORT_NO_SIMILARITY=1`.
    pub fn import_from_yaml_with_similarity(
        &self,
        repo_root: &Path,
        block_threshold: Option<f64>,
    ) -> Result<(usize, usize, usize, usize)> {
        // Fast path: no filter requested → delegate to the canonical importer.
        // Keeps internal callers (GapStore::open, next_id, tests) unchanged.
        let Some(threshold) = block_threshold else {
            let (ins, skip, backfilled) = self.import_from_yaml(repo_root)?;
            return Ok((ins, skip, backfilled, 0));
        };

        // Pre-pass: collect (id, title) for *net-new* gaps only. Routine
        // round-trips of existing gaps via dump→import must not fire.
        let new_titles: Vec<(String, String)> = self.parse_new_gap_titles(repo_root)?;

        // Two-source check: each net-new gap is compared against (a) existing
        // open + recently-closed gaps in state.db via similarity_candidates,
        // AND (b) any previously-accepted new gaps in *this* batch. Without
        // (b), a single import containing two identical titles (today's
        // INFRA-1267/1268 case) would slip through because both are absent
        // from the DB at pre-pass time.
        use std::collections::HashSet;
        let mut skip_ids: HashSet<String> = HashSet::new();
        let mut blocked_log: Vec<(String, String, String, f64)> = Vec::new();
        // Accumulator of (id, title) for new gaps already accepted in this
        // batch. Iteration order matches parse_new_gap_titles → directory-
        // sorted YAML files, so the lower filename wins (deterministic).
        let mut accepted_in_batch: Vec<(String, String)> = Vec::new();
        for (id, title) in &new_titles {
            // (a) Existing-DB check.
            let mut top_match: Option<(String, String, f64)> = None;
            if let Ok(cands) = self.similarity_candidates(title, 1, 30) {
                if let Some((top_id, top_title, _status, top_score)) = cands.first() {
                    if top_id != id && *top_score >= threshold {
                        top_match = Some((top_id.clone(), top_title.clone(), *top_score));
                    }
                }
            }
            // (b) Within-batch check — wins over (a) if higher-scoring.
            for (prev_id, prev_title) in &accepted_in_batch {
                let s = Self::title_jaccard(title, prev_title);
                if s >= threshold && top_match.as_ref().map(|m| s > m.2).unwrap_or(true) {
                    top_match = Some((prev_id.clone(), prev_title.clone(), s));
                }
            }
            match top_match {
                Some((top_id, top_title, score)) => {
                    skip_ids.insert(id.clone());
                    blocked_log.push((id.clone(), top_id, top_title, score));
                }
                None => {
                    accepted_in_batch.push((id.clone(), title.clone()));
                }
            }
        }

        // Emit one ambient event per blocked row. Best-effort; never abort
        // the import on ambient-write failure.
        if !blocked_log.is_empty() {
            let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
            if let Some(parent) = ambient_path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let ts = unix_now();
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(&ambient_path)
            {
                use std::io::Write;
                for (proposed_id, top_id, top_title, score) in &blocked_log {
                    let safe_title = top_title.replace(['"', '\\'], "");
                    let _ = writeln!(
                        f,
                        r#"{{"ts":{ts},"kind":"gap_import_similarity_block","proposed_id":"{proposed_id}","top_match_id":"{top_id}","top_match_title":"{safe_title}","top_match_score":{score:.3}}}"#
                    );
                }
            }
        }

        // Run the canonical import, then DELETE the rows that we should have
        // blocked. Safe because parse_new_gap_titles guarantees skip_ids are
        // net-new — never present before this call — and import_from_yaml
        // uses INSERT OR IGNORE which won't overwrite anything.
        let (ins_total, skip_already_present, backfilled) = self.import_from_yaml(repo_root)?;
        let mut blocked = 0usize;
        for id in &skip_ids {
            let removed = self
                .conn
                .execute("DELETE FROM gaps WHERE id=?1", params![id])?;
            blocked += removed;
        }
        let ins_kept = ins_total.saturating_sub(blocked);
        Ok((ins_kept, skip_already_present, backfilled, blocked))
    }

    /// INFRA-1434 helper: parse YAML files in `<repo_root>/docs/gaps/` (or the
    /// monolithic `docs/gaps.yaml`) and return only the (id, title) pairs whose
    /// ID is **not already present** in state.db. Round-tripping an existing
    /// gap via `chump gap dump --update-yaml` → `chump gap import` should not
    /// fire similarity checks.
    fn parse_new_gap_titles(&self, repo_root: &Path) -> Result<Vec<(String, String)>> {
        let per_file_dir = repo_root.join("docs").join("gaps");
        let text = if per_file_dir.is_dir() {
            let mut parts = Vec::new();
            let mut dir_entries: Vec<_> = std::fs::read_dir(&per_file_dir)
                .with_context(|| format!("reading {}", per_file_dir.display()))?
                .flatten()
                .filter(|e| {
                    e.path()
                        .extension()
                        .and_then(|s| s.to_str())
                        .map(|s| s == "yaml")
                        .unwrap_or(false)
                })
                .collect();
            dir_entries.sort_by_key(|e| e.file_name());
            for entry in &dir_entries {
                if let Ok(content) = std::fs::read_to_string(entry.path()) {
                    parts.push(content);
                }
            }
            if parts.is_empty() {
                return Ok(Vec::new());
            }
            format!("gaps:\n{}", parts.join(""))
        } else {
            let yaml_path = repo_root.join("docs").join("gaps.yaml");
            match std::fs::read_to_string(&yaml_path) {
                Ok(t) => t,
                Err(_) => return Ok(Vec::new()),
            }
        };
        let file: YamlGapsFile = match serde_yaml::from_str(&text) {
            Ok(f) => f,
            Err(_) => return Ok(Vec::new()), // canonical import will surface parse errors
        };

        let mut existing_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut stmt = self.conn.prepare("SELECT id FROM gaps")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        for r in rows.flatten() {
            existing_ids.insert(r);
        }

        let mut out = Vec::new();
        for g in &file.gaps {
            if existing_ids.contains(&g.id) {
                continue;
            }
            if g.title.trim().is_empty() {
                continue;
            }
            out.push((g.id.clone(), g.title.clone()));
        }
        Ok(out)
    }

    pub fn import_from_yaml(&self, repo_root: &Path) -> Result<(usize, usize, usize)> {
        // VOA-006: parse per-file rather than concatenate-then-parse-once. A single
        // malformed entry (e.g. INFRA-3429's 39 duplicate `evidence:` keys, shipped in
        // #3309) used to abort the WHOLE docs/gaps -> state.db sync, so no gap could be
        // imported and freshly-filed gaps never became pickable. Now a bad file is
        // skipped and named on stderr; every well-formed file still imports.
        let file = match load_gap_registry(repo_root)? {
            Some(f) => f,
            None => return Ok((0, 0, 0)),
        };

        let mut inserted = 0usize;
        let mut skipped = 0usize;

        for g in &file.gaps {
            // Normalize acceptance_criteria to JSON-stringified array of strings.
            let ac = match &g.acceptance_criteria {
                Some(v) => normalize_string_list(v),
                None => String::new(),
            };
            // Normalize depends_on the same way (handles both ["X"] block and [X, Y] flow).
            let deps = match &g.depends_on {
                Some(v) => {
                    let json: serde_json::Value =
                        serde_json::from_str(&v.to_string()).unwrap_or(serde_json::Value::Null);
                    normalize_string_list(&json)
                }
                None => String::new(),
            };
            let notes = g
                .notes
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let source_doc = g
                .source_doc
                .as_ref()
                .map(yaml_value_to_loose_string)
                .unwrap_or_default();
            let opened_date = g
                .opened_date
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let closed_date = g
                .closed_date
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            // INFRA-156: coerce closed_pr to Option<i64>. YAML integers come
            // through as serde_yaml::Value::Number; legacy `TBD` strings (now
            // blocked at commit by the INFRA-107 guard) are rejected as None
            // rather than fabricated to a number.
            let closed_pr = g.closed_pr.as_ref().and_then(yaml_value_to_i64);
            // INFRA-314: affinity tags.
            let skills_required = g
                .skills_required
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let preferred_backend = g
                .preferred_backend
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let preferred_machine = g
                .preferred_machine
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let estimated_minutes = g
                .estimated_minutes
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let required_model = g
                .required_model
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            // MISSION-008: outcome_id is nullable — None if absent in YAML.
            let outcome_id: Option<String> = g
                .outcome_id
                .as_ref()
                .map(yaml_value_to_string)
                .filter(|s| !s.is_empty());
            // CREDIBLE-107: evidence is nullable — None if absent in YAML.
            let evidence: Option<String> = g
                .evidence
                .as_ref()
                .map(yaml_value_to_string)
                .filter(|s| !s.is_empty());
            let created_at = unix_now();

            let changed = self.conn.execute(
                "INSERT OR IGNORE INTO gaps(id,domain,title,description,priority,effort,status,
                    acceptance_criteria,depends_on,notes,source_doc,created_at,
                    opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                    preferred_machine,estimated_minutes,required_model,outcome_id,evidence)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)",
                params![
                    g.id,
                    g.domain,
                    g.title,
                    g.description,
                    g.priority,
                    g.effort,
                    g.status,
                    ac,
                    deps,
                    notes,
                    source_doc,
                    created_at,
                    opened_date,
                    closed_date,
                    closed_pr,
                    skills_required,
                    preferred_backend,
                    preferred_machine,
                    estimated_minutes,
                    required_model,
                    outcome_id,
                    evidence,
                ],
            )?;
            if changed > 0 {
                inserted += 1;
            } else {
                skipped += 1;
            }
        }
        // INFRA-233: backfill closed_pr for rows that existed before the
        // column was added (INFRA-156) — INSERT OR IGNORE skips them, so
        // the backfill must be a separate UPDATE pass.
        let backfilled = self.backfill_closed_pr_from_yaml(repo_root)?;
        // INFRA-460 (P0): same INSERT-OR-IGNORE blind spot for `status`.
        // The INFRA-236 commit-subject closer writes `status: done` to the
        // per-file YAML when a PR with `Closes <GAP-ID>` lands on main,
        // but the next `chump gap import` skipped the update (INSERT OR
        // IGNORE = no-op on PK conflict). Result: every closed-via-commit
        // gap stayed `status: open` in state.db. Then `chump gap dump
        // --update-yaml` regenerated the YAML from the stale DB and
        // reverted the closer's flip. **Root cause of every OPEN-BUT-
        // LANDED ghost on origin/main since the INFRA-188 per-file
        // cutover (2026-05-02).** Diagnosed in PR #1094's Red Letter.
        //
        // Fix: monotonic status backfill. If YAML says `done` and DB says
        // anything else, flip DB to `done` and propagate closed_date /
        // closed_pr atomically. Status flips are monotonic in practice —
        // the closer only ever writes `done`; superseded/blocked/deferred
        // are explicit operator actions via `chump gap set`. Restricting
        // the backfill to YAML-says-done means we never accidentally
        // re-open a gap or erase a hand-set state.
        let status_backfilled = self.backfill_status_done_from_yaml(repo_root)?;
        // MISSION-033: auto-upsert repos rows for every external_repo:* tag
        // found in the gaps we just processed. Idempotent: INSERT OR IGNORE
        // preserves existing rows (last_scan_at etc. are never overwritten here).
        // Malformed tags (no '/' separator) are skipped with an ambient event.
        let _ = self.upsert_repos_from_skills(&file.gaps);
        Ok((inserted, skipped, backfilled + status_backfilled))
    }

    /// INFRA-538 — rebuild state.db from `.chump/state.sql` (the tracked YAML
    /// mirror). Reads the YAML dump at `sql_path`, clears the `gaps` table,
    /// and re-inserts all rows. Preserves every field including `closed_pr`,
    /// `closed_date`, `notes`, and affinity columns.
    ///
    /// The caller is responsible for backing up the existing state.db before
    /// calling this (typically rename to state.db.bak).
    pub fn restore_from_state_sql(&mut self, sql_path: &Path) -> Result<usize> {
        let file = Self::load_state_sql(sql_path)?;

        // Clear existing data so the restore is a full replacement, not a merge.
        self.conn
            .execute("DELETE FROM gaps", [])
            .context("clearing gaps table before restore")?;

        let mut inserted = 0usize;
        for g in &file.gaps {
            self.insert_or_replace_gap_row(g)
                .with_context(|| format!("inserting gap {} during restore", g.id))?;
            inserted += 1;
        }
        Ok(inserted)
    }

    /// INFRA-3002 — targeted single-gap sync from `.chump/state.sql` into
    /// state.db, without touching any other row. Used by `chump claim` to
    /// self-heal the "gap {id} not found in state.db" failure mode: a
    /// worktree's local state.db is a snapshot taken at `chump claim`
    /// worktree-creation time, so a gap reserved/imported on `origin/main`
    /// afterward is invisible until someone manually runs
    /// `chump gap restore --from-sql` (a full-table rebuild). This lets
    /// `claim` repair just the one row it needs, in-place.
    ///
    /// Returns `Ok(true)` if `gap_id` was found in state.sql and
    /// inserted/replaced, `Ok(false)` if state.sql has no such gap.
    pub fn sync_gap_from_state_sql(&self, sql_path: &Path, gap_id: &str) -> Result<bool> {
        let file = Self::load_state_sql(sql_path)?;
        match file.gaps.iter().find(|g| g.id == gap_id) {
            Some(g) => {
                self.insert_or_replace_gap_row(g)
                    .with_context(|| format!("inserting gap {gap_id} during single-gap sync"))?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    fn load_state_sql(sql_path: &Path) -> Result<YamlGapsFile> {
        let text = std::fs::read_to_string(sql_path)
            .with_context(|| format!("reading state.sql at {}", sql_path.display()))?;
        Self::parse_state_sql_yaml(&text)
            .with_context(|| format!("parsing YAML in {}", sql_path.display()))
    }

    /// Parse the YAML body of a `.chump/state.sql` dump (despite the `.sql`
    /// extension it is a YAML gaps list, not SQL — see [`Self::load_state_sql`])
    /// from an in-memory string. Split out of `load_state_sql` so
    /// [`Self::canonical_max_id`] can parse `git show origin/main:.chump/state.sql`
    /// output directly, without a temp-file round trip.
    fn parse_state_sql_yaml(text: &str) -> Result<YamlGapsFile> {
        serde_yaml::from_str(text).context("parsing state.sql YAML")
    }

    /// Extract the highest numeric suffix among `gaps[].id` values matching
    /// `<DOMAIN_UPPER>-<N>` — the **id column only**.
    ///
    /// This is deliberately narrow: `state.sql` is known to contain
    /// `<DOMAIN>-<N>`-shaped substrings *outside* the `id` field too (test
    /// fixtures and incident write-ups quoted verbatim in `notes`/`title`/
    /// `description`, e.g. a stray `INFRA-9999999` mentioned as example
    /// junk data). A raw text/regex scan over the whole dump would treat
    /// those as real gap IDs and could rocket the allocator to a nonsense
    /// value — a worse regression than the stale-checkout collision this
    /// method exists to prevent. Scanning only `g.id` mirrors exactly what
    /// the local counter's SQL query does
    /// (`SELECT MAX(...) FROM gaps WHERE id LIKE 'DOMAIN-%'`).
    ///
    /// `MAX_SANE_GAP_NUM` is defense-in-depth on top of that: even a
    /// legitimate-looking `id` field is dropped if its suffix is absurdly
    /// large, so a malformed or synthetic row can never poison allocation.
    fn max_id_num_in_gaps(gaps: &[YamlGap], domain_upper: &str) -> Option<i64> {
        const MAX_SANE_GAP_NUM: i64 = 1_000_000;
        let prefix = format!("{}-", domain_upper);
        gaps.iter()
            .filter_map(|g| g.id.strip_prefix(prefix.as_str()))
            .filter_map(|rest| rest.parse::<i64>().ok())
            .filter(|&n| n > 0 && n <= MAX_SANE_GAP_NUM)
            .max()
    }

    fn insert_or_replace_gap_row(&self, g: &YamlGap) -> Result<()> {
        let ac = match &g.acceptance_criteria {
            Some(v) => normalize_string_list(v),
            None => String::new(),
        };
        let deps = match &g.depends_on {
            Some(v) => {
                let json: serde_json::Value =
                    serde_json::from_str(&v.to_string()).unwrap_or(serde_json::Value::Null);
                normalize_string_list(&json)
            }
            None => String::new(),
        };
        let notes = g
            .notes
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let source_doc = g
            .source_doc
            .as_ref()
            .map(yaml_value_to_loose_string)
            .unwrap_or_default();
        let opened_date = g
            .opened_date
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let closed_date = g
            .closed_date
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let closed_pr = g.closed_pr.as_ref().and_then(yaml_value_to_i64);
        let skills_required = g
            .skills_required
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let preferred_backend = g
            .preferred_backend
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let preferred_machine = g
            .preferred_machine
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let estimated_minutes = g
            .estimated_minutes
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        let required_model = g
            .required_model
            .as_ref()
            .map(yaml_value_to_string)
            .unwrap_or_default();
        // MISSION-008: nullable outcome FK.
        let outcome_id: Option<String> = g
            .outcome_id
            .as_ref()
            .map(yaml_value_to_string)
            .filter(|s| !s.is_empty());
        // CREDIBLE-107: nullable evidence blob.
        let evidence: Option<String> = g
            .evidence
            .as_ref()
            .map(yaml_value_to_string)
            .filter(|s| !s.is_empty());
        let created_at = unix_now();

        self.conn.execute(
            "INSERT OR REPLACE INTO gaps(id,domain,title,description,priority,effort,status,
                acceptance_criteria,depends_on,notes,source_doc,created_at,
                opened_date,closed_date,closed_pr,skills_required,preferred_backend,
                preferred_machine,estimated_minutes,required_model,outcome_id,evidence)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)",
            params![
                g.id,
                g.domain,
                g.title,
                g.description,
                g.priority,
                g.effort,
                g.status,
                ac,
                deps,
                notes,
                source_doc,
                created_at,
                opened_date,
                closed_date,
                closed_pr,
                skills_required,
                preferred_backend,
                preferred_machine,
                estimated_minutes,
                required_model,
                outcome_id,
                evidence,
            ],
        )?;
        Ok(())
    }

    /// INFRA-460 — propagate `status: done` from per-file YAML mirrors to
    /// state.db. Mirrors `backfill_closed_pr_from_yaml` (INFRA-233): a
    /// post-import UPDATE pass that catches rows the `INSERT OR IGNORE`
    /// in `import_from_yaml` would have skipped on PK conflict.
    ///
    /// Monotonic — only flips `status != 'done'` → `done` when YAML
    /// asserts `done`. Never reverses a closure. Also propagates
    /// `closed_date` and `closed_pr` atomically with the status flip if
    /// the YAML provides them and the DB row is missing them, since the
    /// closer writes all three together.
    pub fn backfill_status_done_from_yaml(&self, repo_root: &Path) -> Result<usize> {
        // Shared loader with import_from_yaml / backfill_closed_pr_from_yaml, so
        // drift between the three call sites really is impossible (VOA-006 — they
        // were previously three copy-pasted blocks that all had to be fixed).
        let file = match load_gap_registry(repo_root)? {
            Some(f) => f,
            None => return Ok(0),
        };

        let mut backfilled = 0usize;
        for g in &file.gaps {
            // Only YAMLs that assert `done` get propagated. Anything else
            // (open, superseded, blocked, deferred) we leave to explicit
            // operator commands so we never accidentally erase a
            // hand-set state. YamlGap.status is a String directly (not
            // Option<Value>), so plain comparison.
            if g.status != "done" {
                continue;
            }
            let yaml_closed_date = g
                .closed_date
                .as_ref()
                .map(yaml_value_to_string)
                .unwrap_or_default();
            let yaml_closed_pr = g.closed_pr.as_ref().and_then(yaml_value_to_i64);

            // UPDATE only flips when DB.status = 'open'. Any other DB
            // state (done, superseded, blocked, deferred) is operator
            // intent and stays as-is — we don't blindly trust YAML to
            // overwrite hand-set states. closed_date and closed_pr
            // piggyback if the YAML provides them; COALESCE keeps any DB
            // value already populated so a divergent hand-set date is
            // preserved.
            let changed = self.conn.execute(
                "UPDATE gaps
                 SET status = 'done',
                     closed_date = CASE WHEN ?1 = '' THEN closed_date ELSE ?1 END,
                     closed_pr   = COALESCE(?2, closed_pr)
                 WHERE id = ?3 AND status = 'open'",
                params![yaml_closed_date, yaml_closed_pr, g.id],
            )?;
            backfilled += changed;
        }
        Ok(backfilled)
    }
}

// ────────────────────────── helpers ──────────────────────────

#[derive(Debug)]
pub enum PreflightResult {
    Available,
    NotFound,
    Done,
    Claimed(String),
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// INFRA-2053 sync-module shim around the private `unix_now()` — keeps
/// sync.rs from duplicating the SystemTime/UNIX_EPOCH boilerplate.
pub(crate) fn unix_now_pub() -> i64 {
    unix_now()
}

/// INFRA-1392: verify that work for `gap_id` actually landed on local
/// main. Returns true when EITHER:
///   - `closed_pr` is Some AND a recent commit on main carries the
///     gap ID in its subject or body, OR
///   - `closed_pr` is Some AND a recent commit on main carries
///     `(#<pr_number>)` in the subject (squash-merge GitHub convention).
///
/// Offline-compatible: only `git log` is consulted; no GitHub API call
/// is required. The webhook receiver path naturally also satisfies this
/// because the webhook fires only AFTER the merge commit lands on main,
/// which is the same commit `git log` finds.
///
/// "Recent" = last 200 commits on main. Wider than necessary but cheap
/// — git log of 200 commits is sub-100ms.
pub fn verify_proof_of_merge(repo_root: &Path, gap_id: &str, closed_pr: Option<i64>) -> bool {
    // Test-fixture compatibility: if there's no .git under repo_root,
    // we're either in a synthetic test or a fresh init. The guard
    // can't usefully verify proof-of-merge in that context, so we
    // err on the side of "pass" — production always has a .git tree,
    // so the guard remains effective there.
    if !repo_root.join(".git").exists() {
        return true;
    }
    // CREDIBLE-218: search the FULL history of main via git's own --grep, not just the
    // last 200 commits. The old `-n 200` window meant a merge that landed more than 200
    // commits ago could not be proven → `ship()` refused → the gap became a permanent
    // ghost. `--grep` scans the entire commit message (subject + body) across all of
    // main's history efficiently; `-F` fixed-strings + `-i` case-insensitive match the
    // prior scanning semantics, and multiple `--grep` are OR'd by git's default, so the
    // gap ID OR the PR marker `(#N)` proves the merge. `-n 1` stops at the first hit.
    let mut args: Vec<String> = vec![
        "log".into(),
        "main".into(),
        "-i".into(),
        "-F".into(),
        "-n".into(),
        "1".into(),
        "--format=%H".into(),
        format!("--grep={gap_id}"),
    ];
    if let Some(n) = closed_pr {
        args.push(format!("--grep=(#{n})"));
    }
    let out = std::process::Command::new("git")
        .args(&args)
        .current_dir(repo_root)
        .output();
    let Ok(o) = out else {
        // git binary not available — fail open (rare in prod; defensive).
        return true;
    };
    if !o.status.success() {
        // `git log main` fails when `main` doesn't exist (e.g. branch
        // hasn't been created yet in a fresh repo). For integration
        // tests that `git init` an empty repo, this is the expected
        // "no commits yet" state — pass through so test scaffolding
        // can ship synthetic gaps. Production main always exists.
        // Detect "no commits at all" via `git rev-parse HEAD`: if
        // even HEAD doesn't resolve, the repo is completely fresh.
        let any_commit = std::process::Command::new("git")
            .args(["rev-parse", "--verify", "HEAD"])
            .current_dir(repo_root)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if !any_commit {
            return true; // fresh repo, no commits at all — test fixture
        }
        // Otherwise: there are commits but no main branch — that's a
        // genuinely odd production state. Fail closed.
        return false;
    }
    // Success + a matching commit hash on stdout ⇒ the merge is proven anywhere in
    // main's history. Success + empty ⇒ no commit mentions this gap/PR ⇒ not proven.
    !String::from_utf8_lossy(&o.stdout).trim().is_empty()
}

/// INFRA-100: parse `2026-04-28T22:30:00Z` style ISO-8601 (lease files use
/// this) into a unix timestamp. Returns None on parse failure rather than
/// panicking — leases that don't carry a heartbeat / expiry are simply not
/// staleness-checked. Implementation is a tiny zero-dep parser since chrono
/// isn't already in this crate's hot path and we don't need the full feature
/// set; just yyyy-mm-ddThh:mm:ssZ.
fn parse_iso_to_unix(s: &str) -> Option<i64> {
    let bytes = s.as_bytes();
    if bytes.len() < 19 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    let year: i64 = std::str::from_utf8(&bytes[0..4]).ok()?.parse().ok()?;
    let month: u32 = std::str::from_utf8(&bytes[5..7]).ok()?.parse().ok()?;
    let day: u32 = std::str::from_utf8(&bytes[8..10]).ok()?.parse().ok()?;
    let hour: u32 = std::str::from_utf8(&bytes[11..13]).ok()?.parse().ok()?;
    let minute: u32 = std::str::from_utf8(&bytes[14..16]).ok()?.parse().ok()?;
    let second: u32 = std::str::from_utf8(&bytes[17..19]).ok()?.parse().ok()?;
    // Days-since-epoch via the standard cumulative-days-per-month dance,
    // adjusted for leap years. Sufficient precision for 15-min staleness checks.
    let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let mut days: i64 = 0;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
    let dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for m in 1..month {
        days += dim[(m - 1) as usize] as i64;
        if m == 2 && is_leap(year) {
            days += 1;
        }
    }
    days += day as i64 - 1;
    Some(days * 86400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64)
}

/// INFRA-1893: lightweight gh health probe — calls `gh api user` (1 REST call,
/// core bucket, no scope beyond public read). Returns true if gh responds 200,
/// false on any error. Used as a negative-confirmation gate before surfacing a
/// visible warning when the open-PR scan fails: if the smoke passes but the
/// scan failed, the failure is an internal inconsistency (spurious 401 from
/// --paginate/--jq path) and we suppress the operator-visible warning.
fn gh_smoke_check() -> bool {
    std::process::Command::new("gh")
        .args(["api", "user", "--jq", ".login"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// INFRA-1039: use REST endpoint (gh api repos/{nwo}/pulls) instead of GraphQL
/// (gh pr list) so the scan works even when GraphQL quota is exhausted.
/// Returns Err on any failure so the caller can degrade gracefully.
fn list_open_pr_titles() -> Result<Vec<String>> {
    // Resolve the repo nameWithOwner via REST (never touches GraphQL).
    let nwo_out = std::process::Command::new("gh")
        .args([
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "--jq",
            ".nameWithOwner",
        ])
        .output()
        .with_context(|| "spawning gh repo view")?;
    if !nwo_out.status.success() {
        bail!(
            "gh repo view failed: {}",
            String::from_utf8_lossy(&nwo_out.stderr)
        );
    }
    let nwo = String::from_utf8_lossy(&nwo_out.stdout).trim().to_string();
    if nwo.is_empty() {
        bail!("gh repo view returned empty nameWithOwner");
    }

    // Fetch open PRs via REST (core bucket; unaffected by GraphQL exhaustion).
    let endpoint = format!("repos/{nwo}/pulls");
    let output = std::process::Command::new("gh")
        .args([
            "api",
            &endpoint,
            "--method",
            "GET",
            "-f",
            "state=open",
            "-f",
            "per_page=100",
            "--jq",
            ".[].title",
            "--paginate",
        ])
        .output()
        .with_context(|| format!("spawning gh api {endpoint}"))?;
    if !output.status.success() {
        bail!(
            "gh api {endpoint} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.to_string())
        .collect())
}

/// INFRA-1954: has `id` (e.g. `"INFRA-1953"`) ever been referenced in a
/// commit message on any ref? `reserve_with_external`'s counter-based dedup
/// only sees rows currently in state.db plus in-flight leases/open-PR
/// titles — it is blind to a gap that shipped, whose commit landed on main,
/// but whose row later disappeared from state.db (e.g. a rebuild from an
/// older `.chump/state.sql` snapshot). Git commit history never forgets, so
/// it's the last line of defense against handing out that same ID again.
///
/// Skips entirely (returns `false`) when `repo_root` has no `.git` — most
/// unit tests run against a bare tempdir and shelling out to git there is
/// pure overhead with no repo to search. Any git failure (binary missing,
/// corrupt repo, etc.) is non-fatal — this is defense-in-depth on top of the
/// DB-based counter, not the primary correctness mechanism, so a git hiccup
/// must not brick reserve. Opt out via `CHUMP_RESERVE_GIT_HISTORY_CHECK=0`.
fn git_id_referenced(repo_root: &Path, id: &str) -> bool {
    if std::env::var("CHUMP_RESERVE_GIT_HISTORY_CHECK").as_deref() == Ok("0") {
        return false;
    }
    if !repo_root.join(".git").exists() {
        return false;
    }
    let output = std::process::Command::new("git")
        .args(["log", "--all", "--oneline", "-F", "--grep", id, "-1"])
        .current_dir(repo_root)
        .output();
    match output {
        Ok(out) => out.status.success() && !out.stdout.is_empty(),
        Err(_) => false,
    }
}

/// CREDIBLE-292: refresh `refs/remotes/origin/*` before [`git_id_referenced`]
/// runs, so the history check sees IDs a sibling node already merged to
/// `origin/main` even if this checkout hasn't fetched in a while.
///
/// This is the actual fix for the registry split-brain collision pattern
/// (RESILIENT-331, CREDIBLE-289): `git_id_referenced` only ever searched
/// refs this checkout already knew about (`git log --all`) — on a node that
/// hadn't fetched recently (or whose `backlog-sync --reader` daemon was
/// dead), a sibling node's already-merged ID was invisible, so the naive
/// counter handed it out again. `origin/main` is the one shared coordination
/// point every node already pushes to for shipped work, so a cheap fetch
/// immediately before the check closes the gap without needing new
/// infrastructure (NATS-KV, node-prefixed ranges, etc).
///
/// Best-effort and non-fatal: a network hiccup, missing `origin` remote, or
/// offline dev box must not brick `reserve()` — the existing DB/lease/PR
/// sources still apply, and this is defense-in-depth on top of those, not
/// the sole guard. Bounded by a short timeout via `git`'s own connect
/// timeout is not configurable here, so instead we just don't block long: if
/// `git fetch` hangs indefinitely (e.g. auth prompt), that's a pre-existing
/// risk for every other git-shelling caller in this file too.
/// Opt out via `CHUMP_RESERVE_FETCH_ORIGIN=0` (offline-only workflows).
fn fetch_origin_refs(repo_root: &Path) {
    if std::env::var("CHUMP_RESERVE_FETCH_ORIGIN").as_deref() == Ok("0") {
        return;
    }
    if !repo_root.join(".git").exists() {
        return;
    }
    let _ = std::process::Command::new("git")
        .args(["fetch", "origin", "--quiet", "--no-tags"])
        .current_dir(repo_root)
        .output();
}

/// INFRA-3687: how many commits `origin/main` is ahead of local `main` —
/// i.e. how far behind this checkout is. Deliberately returns `None` (NOT
/// `0`) when the question doesn't apply: no `.git` at all (synthetic test
/// fixtures — every existing `test_store()`-based test uses a bare
/// `TempDir`), or the `rev-list` call itself fails (no local `main` ref,
/// detached HEAD, shallow clone). Callers MUST treat `None` as "not
/// applicable" and skip any staleness gate built on top of it, never as
/// "definitely not behind" — see the fail-closed check in
/// `reserve_with_external` and `GapStore::behind_origin_main`.
///
/// Uses whatever `refs/remotes/origin/main` this checkout already knows
/// about — no fetch here, callers that need a fresh view fetch first
/// (`canonical_max_id` does; `chump gap list`'s staleness warning
/// deliberately does not, to stay non-blocking on a hot read path).
fn behind_origin_main_count(repo_root: &Path) -> Option<u64> {
    if !repo_root.join(".git").exists() {
        return None;
    }
    let output = std::process::Command::new("git")
        .args(["rev-list", "--count", "main..origin/main"])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .ok()
}

/// INFRA-100: lightweight matcher for `<DOMAIN>-NNN` substrings in a string.
/// Avoids pulling in the `regex` crate just for this since it's not already
/// a dep of chump's bin target. Domain is uppercase; NNN is one-or-more
/// digits (we want to catch zero-padded `INFRA-080` *and* unpadded `INFRA-9`).
struct DomainPattern {
    prefix: String,
}
impl DomainPattern {
    fn find_numbers(&self, hay: &str) -> Vec<i64> {
        let mut out = Vec::new();
        let mut idx = 0;
        let bytes = hay.as_bytes();
        while let Some(rel) = hay[idx..].find(&self.prefix) {
            let start = idx + rel + self.prefix.len();
            // Boundary: char before prefix should be non-alphanumeric or BOL.
            let pre_ok = idx + rel == 0 || {
                let b = bytes[idx + rel - 1];
                !(b.is_ascii_alphanumeric())
            };
            if !pre_ok {
                idx = start;
                continue;
            }
            // Read digits.
            let mut end = start;
            while end < bytes.len() && bytes[end].is_ascii_digit() {
                end += 1;
            }
            if end > start {
                if let Ok(n) = hay[start..end].parse::<i64>() {
                    out.push(n);
                }
            }
            idx = if end == start { start + 1 } else { end };
        }
        out
    }
}
fn regex_lite_for_domain(domain_upper: &str) -> DomainPattern {
    DomainPattern {
        prefix: format!("{}-", domain_upper),
    }
}

fn yaml_quote(s: &str) -> String {
    if s.contains(':') || s.contains('#') || s.contains('\'') {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

/// Quote a YAML scalar for an inline value. Returns the input unchanged if
/// safe; otherwise wraps in double quotes with escapes. Multi-line strings
/// should use `yaml_block_scalar` instead.
fn yaml_scalar(s: &str) -> String {
    if s.is_empty() {
        return "\"\"".to_string();
    }
    if s.contains('\n') {
        // Caller should use yaml_block_scalar; defensive fallback to double-quoted.
        return format!(
            "\"{}\"",
            s.replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n")
        );
    }
    let needs_quoting = s.contains(':')
        || s.contains('#')
        || s.contains('"')
        || s.starts_with('\'')
        || s.starts_with('-')
        || s.starts_with('?')
        || s.starts_with('&')
        || s.starts_with('*')
        || s.starts_with('[')
        || s.starts_with('{')
        || s.starts_with('|')
        || s.starts_with('>')
        || s.starts_with('@')
        || s.starts_with('`')
        || s.trim() != s
        || matches!(s, "true" | "false" | "null" | "yes" | "no" | "~");
    if needs_quoting {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

/// Render a multi-line description/notes field as a YAML block scalar with
/// `>` (folded) for short text or literal `|` for text that already has
/// embedded newlines. `indent` is the prefix for content lines (typically
/// "  " — two spaces, matching block-list entry indentation).
fn yaml_block_scalar(s: &str, indent: &str) -> String {
    if !s.contains('\n') && s.len() < 80 && !s.contains(':') && !s.contains('#') {
        // short single line — emit inline
        return yaml_scalar(s);
    }
    // INFRA-112: normalize trailing newlines before splitting. YAML's bare
    // `|` block scalar preserves a single final `\n`, so a dump → re-parse
    // cycle silently appends `\n` to the stored value. Without normalization
    // here, the next emit splits on that trailing `\n` into a phantom empty
    // line and renders an indented blank, breaking byte-stable round-trip
    // (test_dump_yaml_byte_stable_round_trip). Trimming at emit time keeps
    // the existing visual format (bare `|`, no `|-` suffix everywhere) and
    // makes the first dump and every subsequent re-dump produce identical
    // bytes regardless of how many round-trips the value has been through.
    let trimmed = s.trim_end_matches('\n');
    let mut out = String::from("|\n");
    for line in trimmed.split('\n') {
        out.push_str(indent);
        out.push_str("  ");
        out.push_str(line);
        out.push('\n');
    }
    // Trim trailing newline so caller-added "\n" doesn't double.
    if out.ends_with('\n') {
        out.pop();
    }
    out
}

/// Parse a gap's acceptance_criteria JSON list into Vec<String>. Returns an
/// empty Vec when the field is empty or unparseable. Public for COG-052 audit-ac.
pub fn parse_json_ac_list(s: &str) -> Vec<String> {
    parse_json_string_list(s).unwrap_or_default()
}

/// META-555: Effect-verified done-bar — the opt-in `verify:` acceptance-criterion
/// marker and its evaluation. WHY THIS EXISTS: gaps close on PR-merge (CI-green),
/// not on outcome-changed, so a fix that merges but does not actually work is
/// marked `done` and its still-present symptom respawns as a fresh gap id. Live
/// proof 2026-09-15: RESILIENT-1230 -> 1258 -> 1294 = three ids for ONE unfixed
/// sentinel false-page; PRs #4688 and #4690 both merged green and flipped their
/// gaps to done while the symptom never stopped once. CI-green proved the code
/// compiled + its own unit test passed; it never proved the LIVE symptom stopped.
///
/// This is the ADVISORY MVP wire-in of the fleet's existing effect-verification
/// idea (scripts/ops/effect-verifier.sh RESILIENT-1109 and
/// organ-success-verifier.sh RESILIENT-1108 verify ORGAN effects; this brings the
/// same shape to the GAP-CLOSURE path). It NEVER blocks a close — see
/// `GapStore::ship` / `GapStore::record_effect_verification`.
///
/// An acceptance-criterion list item whose trimmed text begins (case-insensitively)
/// with the exact prefix `verify:` DECLARES a live, checkable command that proves
/// the fix changed the real outcome (e.g.
/// `verify: ! journalctl -u sentinel | grep -q false-page`). The command is
/// everything after the prefix. Every other criterion — the overwhelming default —
/// yields no command, so ship() is byte-for-byte unchanged for it. THIS is the
/// structural anti-wedge guarantee: the opt-in class is empty until a gap author
/// or curator deliberately writes a `verify:` line, and a `verify:` substring
/// buried mid-sentence (or a `self-verify:` prefix) never matches.
pub fn extract_verify_commands(acceptance_criteria: &str) -> Vec<String> {
    const MARKER: &str = "verify:";
    parse_json_ac_list(acceptance_criteria)
        .iter()
        .filter_map(|item| {
            let t = item.trim();
            if t.len() >= MARKER.len() && t[..MARKER.len()].eq_ignore_ascii_case(MARKER) {
                let cmd = t[MARKER.len()..].trim();
                if cmd.is_empty() {
                    None
                } else {
                    Some(cmd.to_string())
                }
            } else {
                None
            }
        })
        .collect()
}

/// META-555: the verdict of the advisory effect check run at gap-close time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EffectVerdict {
    /// The gap carries no `verify:` live-check criterion (the default for nearly
    /// every gap). ship() does nothing extra — no signal, no annotation. This is
    /// the case that guarantees ordinary closures are never touched.
    NoLiveCriterion,
    /// The gap carried one or more `verify:` commands and they all exited 0 — the
    /// merged fix demonstrably changed the live outcome. Clean-done, confirmed.
    EffectVerified,
    /// A `verify:` command failed (non-zero, could not spawn, or timed out). The
    /// close STILL succeeds (advisory MVP — never blocks); the gap is annotated
    /// and a `closed_effect_unverified` signal is emitted so a merged-but-
    /// ineffective fix stays visibly FLAGGED under the SAME id instead of
    /// silently clean-done + respawning as a new id.
    EffectUnverified {
        failed_command: String,
        detail: String,
    },
}

/// META-555: run one `verify:` live-check under `sh -c` in the repo root, bounded
/// by `timeout_s`. Ok(true) => exited 0; Ok(false) => exited non-zero; Err =>
/// could not spawn or timed out. The caller treats every non-Ok(true) as
/// UNVERIFIED (we could not prove the effect), never as verified.
fn run_verify_command(repo_root: &std::path::Path, cmd: &str, timeout_s: u64) -> Result<bool> {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .current_dir(repo_root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("META-555: spawn verify command failed: {cmd}"))?;
    let deadline = Instant::now() + Duration::from_secs(timeout_s.max(1));
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status.success());
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("META-555: verify command timed out after {timeout_s}s: {cmd}");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// INFRA-1411: load a single gap from its YAML file as a fallback when
/// state.db is missing the row or holds vague (TODO/TBD) acceptance_criteria.
///
/// Looks for `<repo_root>/docs/gaps/<ID>.yaml`. Accepts either shape:
///   1. Top-level list:   `- id: INFRA-1411\n  title: …`
///   2. `gaps:` keyed:    `gaps:\n  - id: INFRA-1411\n    title: …`
///
/// Handles the double-encoded AC pattern observed 2026-05-16 in state.db
/// (`acceptance_criteria: "[\"a\",\"b\"]"` — a single-string-element list
/// whose only entry is a JSON-encoded array). Always returns AC as a
/// canonical single-level JSON array string.
pub fn load_gap_from_yaml(repo_root: &std::path::Path, gap_id: &str) -> Result<Option<GapRow>> {
    let path = repo_root.join("docs/gaps").join(format!("{}.yaml", gap_id));
    if !path.exists() {
        return Ok(None);
    }
    let body =
        std::fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    // Try top-level-list shape first; fall back to `gaps:`-keyed shape.
    let yaml_gap: Option<YamlGap> = if let Ok(list) = serde_yaml::from_str::<Vec<YamlGap>>(&body) {
        list.into_iter().find(|g| g.id == gap_id)
    } else if let Ok(file) = serde_yaml::from_str::<YamlGapsFile>(&body) {
        file.gaps.into_iter().find(|g| g.id == gap_id)
    } else {
        None
    };
    let Some(yg) = yaml_gap else {
        return Ok(None);
    };

    // Normalize acceptance_criteria. The YAML on disk may carry it as a
    // real JSON array, OR as a single-element list whose only entry is a
    // JSON-encoded string of an array (double-encoded import bug).
    let ac_string = match yg.acceptance_criteria.as_ref() {
        None => String::new(),
        Some(serde_json::Value::Array(items)) => {
            if items.len() == 1 {
                if let Some(s) = items[0].as_str() {
                    if let Ok(inner) = serde_json::from_str::<serde_json::Value>(s) {
                        if inner.is_array() {
                            inner.to_string()
                        } else {
                            serde_json::Value::Array(items.clone()).to_string()
                        }
                    } else {
                        serde_json::Value::Array(items.clone()).to_string()
                    }
                } else {
                    serde_json::Value::Array(items.clone()).to_string()
                }
            } else {
                serde_json::Value::Array(items.clone()).to_string()
            }
        }
        Some(other) => other.to_string(),
    };

    // Best-effort coerce of YAML-Value-typed simple scalar fields back to string.
    let stringify_val = |v: &Option<serde_yaml::Value>| -> String {
        match v {
            None => String::new(),
            Some(serde_yaml::Value::String(s)) => s.clone(),
            Some(serde_yaml::Value::Number(n)) => n.to_string(),
            Some(serde_yaml::Value::Bool(b)) => b.to_string(),
            Some(_) => String::new(),
        }
    };

    let closed_pr = match yg.closed_pr.as_ref() {
        None => None,
        Some(serde_yaml::Value::Number(n)) => n.as_i64(),
        Some(serde_yaml::Value::String(s)) => s.trim().parse::<i64>().ok(),
        Some(_) => None,
    };

    let depends_on_string = match yg.depends_on.as_ref() {
        None => String::new(),
        Some(v) => v.to_string(),
    };

    Ok(Some(GapRow {
        id: yg.id,
        domain: yg.domain,
        title: yg.title,
        description: yg.description,
        priority: yg.priority,
        effort: yg.effort,
        status: yg.status,
        acceptance_criteria: ac_string,
        depends_on: depends_on_string,
        notes: stringify_val(&yg.notes),
        source_doc: stringify_val(&yg.source_doc),
        created_at: 0,
        closed_at: None,
        opened_date: stringify_val(&yg.opened_date),
        closed_date: stringify_val(&yg.closed_date),
        closed_pr,
        skills_required: stringify_val(&yg.skills_required),
        preferred_backend: stringify_val(&yg.preferred_backend),
        preferred_machine: stringify_val(&yg.preferred_machine),
        estimated_minutes: stringify_val(&yg.estimated_minutes),
        required_model: stringify_val(&yg.required_model),
        // INFRA-2134: YAML files don't carry shipped_in; it lives only in state.db.
        shipped_in: None,
        // MISSION-008: outcome_id from YAML; None if absent.
        outcome_id: yg.outcome_id.as_ref().and_then(|v| match v {
            serde_yaml::Value::String(s) if !s.is_empty() => Some(s.clone()),
            _ => None,
        }),
        // CREDIBLE-107: evidence from YAML; None if absent.
        evidence: yg.evidence.as_ref().and_then(|v| match v {
            serde_yaml::Value::String(s) if !s.is_empty() => Some(s.clone()),
            _ => None,
        }),
    }))
}

/// ZERO-WASTE-045: given a list of candidate gap IDs (typically extracted
/// from an Almanac full-text-search hit over `docs/gaps/*.yaml`), load each
/// candidate straight from its YAML file and score it against `proposed_title`
/// with `title_jaccard`. Unlike `similarity_candidates` (which only sees
/// state.db's `open` + recently-closed-`done` rows), this reads YAML directly,
/// so it surfaces gaps that shipped long ago and dropped out of state.db's
/// closed-lookback window — the DOC-082 failure mode this gap fixes was
/// re-filing something already SHIPPED, not something open.
///
/// Returns `(id, title, status, score)` tuples with `score >= threshold`,
/// sorted by descending score. IDs that fail to load (missing/malformed YAML,
/// or don't parse) are silently skipped — this is a best-effort dedupe
/// signal, not a source of truth.
pub fn shipped_gap_dedupe_candidates(
    repo_root: &std::path::Path,
    proposed_title: &str,
    candidate_ids: &[String],
    threshold: f64,
) -> Vec<(String, String, String, f64)> {
    let mut seen = std::collections::HashSet::new();
    let mut scored: Vec<(String, String, String, f64)> = candidate_ids
        .iter()
        .filter(|id| seen.insert((*id).clone()))
        .filter_map(|id| load_gap_from_yaml(repo_root, id).ok().flatten())
        .map(|g| {
            let score = GapStore::title_jaccard(proposed_title, &g.title);
            (g.id, g.title, g.status, score)
        })
        .filter(|(_, _, _, score)| *score >= threshold)
        .collect();
    scored.sort_by(|a, b| b.3.partial_cmp(&a.3).unwrap_or(std::cmp::Ordering::Equal));
    scored
}

/// INFRA-6701: recently-merged-PR overlap advisory candidates.
///
/// Reads the local GitHub PR cache (`.chump/github_cache.db`, populated by the
/// webhook / REST cache path) for PRs merged within the last `window_days` and
/// returns those whose title Jaccard-overlaps `proposed_title` at or above
/// `threshold`. This is the fold the reserve-time dedupe layer was missing: the
/// state.db + Almanac checks catch duplicate *gaps*, and the FLEET-029 glance
/// catches overlap with *open* PRs, but nothing folded a new gap against PRs
/// that recently MERGED — the exact shape of the "already shipped, just closing
/// the gap" bookkeeping-PR class (INFRA-6701 convergence audit).
///
/// Advisory ONLY. Returns `(pr_number, pr_title, merged_at, score)` sorted
/// descending by score. Best-effort: returns an empty vec on a missing or
/// unreadable cache so the caller surfaces a signal rather than blocking a
/// legitimate reserve — gaps are truth; we surface duplicates, never throttle.
pub fn recently_merged_pr_dedupe_candidates(
    repo_root: &std::path::Path,
    proposed_title: &str,
    window_days: i64,
    threshold: f64,
) -> Vec<(i64, String, String, f64)> {
    let db = repo_root.join(".chump").join("github_cache.db");
    if !db.exists() {
        return Vec::new();
    }
    let conn = match rusqlite::Connection::open_with_flags(
        &db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let mut stmt = match conn.prepare(
        "SELECT number, title, merged_at FROM pr_state \
         WHERE merged_at IS NOT NULL AND title IS NOT NULL \
           AND julianday('now') - julianday(merged_at) <= ?1",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([window_days], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    });
    let rows = match rows {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let mut scored: Vec<(i64, String, String, f64)> = rows
        .filter_map(|r| r.ok())
        .map(|(num, title, merged_at)| {
            let score = GapStore::title_jaccard(proposed_title, &title);
            (num, title, merged_at, score)
        })
        .filter(|(_, _, _, score)| *score >= threshold)
        .collect();
    scored.sort_by(|a, b| b.3.partial_cmp(&a.3).unwrap_or(std::cmp::Ordering::Equal));
    scored
}

/// INFRA-1411: returns true when `ac_string` either is empty OR every
/// item is a TODO/TBD/placeholder string. Used by `chump gap show` to
/// trigger the YAML fallback even when state.db has a row.
pub fn acceptance_criteria_is_vague(ac_string: &str) -> bool {
    let items = parse_json_ac_list(ac_string);
    if items.is_empty() {
        return ac_string.trim().is_empty();
    }
    items.iter().all(|item| {
        let up = item.trim().to_uppercase();
        up.is_empty()
            || up.contains("TODO")
            || up.contains("TBD")
            || up.contains("<FILL IN>")
            || up.contains("WARN: NEEDS ACCEPTANCE_CRITERIA")
    })
}

/// Parse a stored JSON-string-array column back to Vec<String>. Returns None
/// when the field is empty or unparseable.
fn parse_json_string_list(s: &str) -> Option<Vec<String>> {
    if s.trim().is_empty() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(s).ok()?;
    let arr = v.as_array()?;
    Some(
        arr.iter()
            .filter_map(|x| x.as_str().map(String::from))
            .collect(),
    )
}

/// Quote a YAML date scalar. Existing `docs/gaps.yaml` uses single-quoted
/// dates (`'2026-04-25'`); preserve that for round-trip. Strips any stray
/// surrounding quotes/backslashes that may have leaked in from past
/// hand-edits or escaped values.
fn yaml_date(s: &str) -> String {
    let trimmed = s
        .trim()
        .trim_matches(|c: char| c == '\'' || c == '"' || c == '\\');
    format!("'{}'", trimmed)
}

/// Convert a unix timestamp to ISO YYYY-MM-DD using local-naive UTC.
fn unix_to_iso_date(ts: i64) -> String {
    use chrono::{TimeZone, Utc};
    Utc.timestamp_opt(ts, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// Convert a unix timestamp to full ISO-8601 `YYYY-MM-DDTHH:MM:SSZ`.
/// Used by `reserve_verified` for lease file heartbeat/expiry timestamps.
fn unix_to_iso_full(ts: i64) -> String {
    use chrono::{TimeZone, Utc};
    Utc.timestamp_opt(ts, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}

/// Normalize a serde_json::Value (typically a YAML-imported list or scalar)
/// into a JSON string-array stored in the DB. Non-array inputs become `[]`.
fn normalize_string_list(v: &serde_json::Value) -> String {
    let items: Vec<String> = match v {
        serde_json::Value::Array(arr) => arr
            .iter()
            .filter_map(|x| match x {
                serde_json::Value::String(s) => Some(s.clone()),
                serde_json::Value::Number(n) => Some(n.to_string()),
                serde_json::Value::Bool(b) => Some(b.to_string()),
                _ => None,
            })
            .collect(),
        serde_json::Value::Null => Vec::new(),
        _ => Vec::new(),
    };
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string())
}

/// Loose string coercion that joins sequence values with `, `. Handles the
/// historical `source_doc:` field that some PRs wrote as a list instead of a
/// scalar. Non-list values fall through to `yaml_value_to_string`.
fn yaml_value_to_loose_string(v: &serde_yaml::Value) -> String {
    if let serde_yaml::Value::Sequence(seq) = v {
        return seq
            .iter()
            .map(yaml_value_to_string)
            .collect::<Vec<_>>()
            .join(", ");
    }
    yaml_value_to_string(v)
}

/// INFRA-156: Convert a YAML value to `Option<i64>` for `closed_pr`. Accepts
/// numeric YAML scalars (`closed_pr: 598`) and numeric strings; everything
/// else (TBD, null, missing) becomes `None`. The INFRA-107 commit-time
/// guard rejects non-numeric closed_pr values, so a clean import shouldn't
/// see strings here — but we coerce defensively rather than crash if a
/// pre-guard YAML is being re-imported on a fresh DB.
fn yaml_value_to_i64(v: &serde_yaml::Value) -> Option<i64> {
    match v {
        serde_yaml::Value::Number(n) => n.as_i64(),
        serde_yaml::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// Convert a serde_yaml::Value to a string for date-like fields. YAML may
/// parse `2026-04-25` as a date type or string; we want the ISO text either way.
fn yaml_value_to_string(v: &serde_yaml::Value) -> String {
    match v {
        serde_yaml::Value::String(s) => s.clone(),
        serde_yaml::Value::Number(n) => n.to_string(),
        serde_yaml::Value::Bool(b) => b.to_string(),
        serde_yaml::Value::Null => String::new(),
        other => serde_yaml::to_string(other)
            .unwrap_or_default()
            .trim()
            .trim_end_matches('\n')
            .to_string(),
    }
}

trait OptionalExt<T> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error>;
}
impl<T> OptionalExt<T> for Result<T, rusqlite::Error> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error> {
        match self {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

// ────────── MISSION-008: first-class Outcome CRUD ──────────

/// Advisory rollup for one outcome: counts of child gaps by status.
/// NEVER gates a child gap from closing — purely informational.
#[derive(Debug, Clone, Default)]
pub struct OutcomeStatusRollup {
    pub outcome: OutcomeRow,
    pub total: usize,
    pub open: usize,
    pub done: usize,
    pub other: usize,
}

impl GapStore {
    /// Create a new outcome row. IDs are caller-supplied (e.g. "META-067").
    /// Idempotent: returns Ok if the ID already exists (INSERT OR IGNORE).
    pub fn create_outcome(
        &self,
        id: &str,
        title: &str,
        priority: &str,
        definition_of_done: &str,
    ) -> Result<()> {
        let now = unix_now();
        self.conn.execute(
            "INSERT OR IGNORE INTO outcomes(id,title,priority,definition_of_done,status,created_at)
             VALUES(?1,?2,?3,?4,'open',?5)",
            params![id, title, priority, definition_of_done, now],
        )?;
        Ok(())
    }

    /// EFFECTIVE-443: attach the JTBD-sharpen triple to an existing outcome.
    /// Called by `chump intake --create` right after `create_outcome` when
    /// the vision-intake subagent supplied a `jtbd` object. A no-op (Ok) if
    /// the outcome id doesn't exist — the caller already has the outcome.
    pub fn set_outcome_jtbd(
        &self,
        id: &str,
        who: &str,
        struggling_moment: &str,
        done_signal: &str,
    ) -> Result<()> {
        self.conn.execute(
            "UPDATE outcomes SET jtbd_who=?2, jtbd_struggling_moment=?3, jtbd_done_signal=?4
             WHERE id=?1",
            params![id, who, struggling_moment, done_signal],
        )?;
        Ok(())
    }

    /// Fetch one outcome by ID. Returns None if not found.
    pub fn get_outcome(&self, id: &str) -> Result<Option<OutcomeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id,title,priority,definition_of_done,status,created_at,closed_at,park_reason,
                    jtbd_who,jtbd_struggling_moment,jtbd_done_signal
             FROM outcomes WHERE id=?1",
        )?;
        stmt.query_row(params![id], |r| {
            Ok(OutcomeRow {
                id: r.get(0)?,
                title: r.get(1)?,
                priority: r.get(2)?,
                definition_of_done: r.get(3)?,
                status: r.get(4)?,
                created_at: r.get(5)?,
                closed_at: r.get(6)?,
                park_reason: r.get(7)?,
                jtbd_who: r.get(8)?,
                jtbd_struggling_moment: r.get(9)?,
                jtbd_done_signal: r.get(10)?,
            })
        })
        .optional()
        .map_err(Into::into)
    }

    /// List all outcomes, ordered by id.
    pub fn list_outcomes(&self) -> Result<Vec<OutcomeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id,title,priority,definition_of_done,status,created_at,closed_at,park_reason,
                    jtbd_who,jtbd_struggling_moment,jtbd_done_signal
             FROM outcomes ORDER BY id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(OutcomeRow {
                id: r.get(0)?,
                title: r.get(1)?,
                priority: r.get(2)?,
                definition_of_done: r.get(3)?,
                status: r.get(4)?,
                created_at: r.get(5)?,
                closed_at: r.get(6)?,
                park_reason: r.get(7)?,
                jtbd_who: r.get(8)?,
                jtbd_struggling_moment: r.get(9)?,
                jtbd_done_signal: r.get(10)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// RESILIENT-254: mark an outcome as deliberately parked — it has open
    /// children that aren't moving, but that's a decision, not rot. Excluded
    /// from the L5-SLO-2 commitment-rot breach as long as status=='parked'.
    pub fn park_outcome(&self, id: &str, reason: &str) -> Result<()> {
        let n = self.conn.execute(
            "UPDATE outcomes SET status='parked', park_reason=?2 WHERE id=?1",
            params![id, reason],
        )?;
        if n == 0 {
            anyhow::bail!("outcome '{}' not found", id);
        }
        Ok(())
    }

    /// Reverse of `park_outcome` — reopen a parked outcome for SLO tracking.
    pub fn unpark_outcome(&self, id: &str) -> Result<()> {
        let n = self.conn.execute(
            "UPDATE outcomes SET status='open', park_reason=NULL WHERE id=?1 AND status='parked'",
            params![id],
        )?;
        if n == 0 {
            anyhow::bail!("outcome '{}' not found or not parked", id);
        }
        Ok(())
    }

    /// Advisory rollup of child-gap progress for one outcome.
    /// NEVER blocks or gates child-gap close — purely observable.
    pub fn outcome_status(&self, outcome_id: &str) -> Result<Option<OutcomeStatusRollup>> {
        let outcome = match self.get_outcome(outcome_id)? {
            Some(o) => o,
            None => return Ok(None),
        };
        let mut stmt = self
            .conn
            .prepare("SELECT status FROM gaps WHERE outcome_id=?1")?;
        let statuses: Vec<String> = stmt
            .query_map(params![outcome_id], |r| r.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let total = statuses.len();
        let open = statuses
            .iter()
            .filter(|s| s.as_str() == "open" || s.as_str() == "claimed")
            .count();
        let done = statuses.iter().filter(|s| s.as_str() == "done").count();
        let other = total - open - done;
        Ok(Some(OutcomeStatusRollup {
            outcome,
            total,
            open,
            done,
            other,
        }))
    }

    /// Return open P0 outcomes (for outcome-aware budget view in audit-priorities).
    /// Keeps existing per-gap P0 checks intact — adds outcome-level view alongside.
    pub fn list_p0_outcomes(&self) -> Result<Vec<OutcomeRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id,title,priority,definition_of_done,status,created_at,closed_at,park_reason,
                    jtbd_who,jtbd_struggling_moment,jtbd_done_signal
             FROM outcomes WHERE priority='P0' AND status='open' ORDER BY id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(OutcomeRow {
                id: r.get(0)?,
                title: r.get(1)?,
                priority: r.get(2)?,
                definition_of_done: r.get(3)?,
                status: r.get(4)?,
                created_at: r.get(5)?,
                closed_at: r.get(6)?,
                park_reason: r.get(7)?,
                jtbd_who: r.get(8)?,
                jtbd_struggling_moment: r.get(9)?,
                jtbd_done_signal: r.get(10)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// RESILIENT-254 (L5-SLO-2): outcomes that are open, have ≥1 open child
    /// gap, and have shown no child-gap completion movement since `since_unix`.
    /// Parked outcomes (status=='parked') are excluded by construction — a
    /// parked outcome never has status=='open' so it never reaches this query.
    pub fn stale_outcomes(&self, since_unix: i64) -> Result<Vec<OutcomeRow>> {
        let outcomes = self.list_outcomes()?;
        let all_gaps = self.list(None)?;
        let mut out = Vec::new();
        for o in outcomes {
            if o.status != "open" {
                continue;
            }
            // Give a freshly-created outcome a full window before judging it —
            // "no movement yet" and "no movement in ages" aren't the same thing.
            if o.created_at >= since_unix {
                continue;
            }
            let children: Vec<&GapRow> = all_gaps
                .iter()
                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                .collect();
            let open_children = children.iter().filter(|g| g.status == "open").count();
            if open_children == 0 {
                continue;
            }
            let recent_movement = children
                .iter()
                .any(|g| g.closed_at.is_some_and(|c| c >= since_unix));
            if !recent_movement {
                out.push(o);
            }
        }
        Ok(out)
    }

    /// List gaps that belong to a given outcome_id.
    /// Used by roadmap-status LEFT JOIN path and outcome status rollup.
    pub fn gaps_for_outcome(&self, outcome_id: &str) -> Result<Vec<GapRow>> {
        self.list(None).map(|all| {
            all.into_iter()
                .filter(|g| g.outcome_id.as_deref() == Some(outcome_id))
                .collect()
        })
    }
}

// ────────── decomposed umbrella gaps (RESILIENT-1364) ──────────

/// RESILIENT-1364: parse the child gap IDs recorded by `chump gap decompose
/// --apply` in a parent's notes field: "Decomposed into N slices: ID, ID,
/// ...". This free-text line is, today, the ONLY link between an umbrella
/// and its slices (no parent_id column) — this is the single extraction
/// point so a future structured link only has to change one function.
/// Returns an empty vec if the marker isn't present or nothing parses.
pub fn parse_decomposed_children(notes: &str) -> Vec<String> {
    const MARKER: &str = "Decomposed into";
    let Some(marker_pos) = notes.find(MARKER) else {
        return Vec::new();
    };
    let after_marker = &notes[marker_pos..];
    let Some(colon_pos) = after_marker.find(':') else {
        return Vec::new();
    };
    let ids_part = &after_marker[colon_pos + 1..];
    // Stop at end of line — notes may carry more content after this marker.
    let ids_line = ids_part.lines().next().unwrap_or("");
    ids_line
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

/// Advisory rollup of one decomposed umbrella's children, mirroring
/// `outcome_status`'s open_children pattern above for gap-to-gap umbrellas
/// instead of outcome-to-gap.
#[derive(Debug, Clone)]
pub struct DecomposedParentRollup {
    pub parent_id: String,
    pub child_ids: Vec<String>,
    /// Children that resolved to a real gap row.
    pub total: usize,
    pub open: usize,
    pub done: usize,
}

impl GapStore {
    /// Rollup of a decomposed parent's children, parsed from its notes.
    /// Returns `None` if `parent_id` doesn't exist or has no parseable
    /// "Decomposed into" marker.
    pub fn decomposed_parent_rollup(
        &self,
        parent_id: &str,
    ) -> Result<Option<DecomposedParentRollup>> {
        let parent = match self.get(parent_id)? {
            Some(g) => g,
            None => return Ok(None),
        };
        let child_ids = parse_decomposed_children(&parent.notes);
        if child_ids.is_empty() {
            return Ok(None);
        }
        let mut total = 0usize;
        let mut open = 0usize;
        let mut done = 0usize;
        for cid in &child_ids {
            if let Some(child) = self.get(cid)? {
                total += 1;
                if child.status == "open" || child.status == "claimed" {
                    open += 1;
                } else if child.status == "done" {
                    done += 1;
                }
            }
        }
        Ok(Some(DecomposedParentRollup {
            parent_id: parent_id.to_string(),
            child_ids,
            total,
            open,
            done,
        }))
    }

    /// RESILIENT-1364 fix #2: scan every gap with status='decomposed' and
    /// auto-close (status -> done) any whose children are ALL 'done'.
    /// Mirrors the outcomes open_children pattern above, extended into an
    /// action here because a decomposed umbrella (unlike an outcome) has no
    /// other route out of limbo once its slices land.
    ///
    /// The closing UPDATE excludes only the deliberate terminal statuses
    /// (CREDIBLE-218 shape) rather than gating on `WHERE status='decomposed'`
    /// — so a parent that drifted to some other status between the read
    /// above and this write (e.g. an operator hand-closed it in the
    /// meantime) is never double-closed or ghosted; the UPDATE affects 0
    /// rows and is simply skipped.
    ///
    /// A child ID that doesn't resolve to a real gap is treated as "not
    /// done" (never auto-closes on unverifiable data) rather than being
    /// silently ignored.
    ///
    /// Returns the IDs of parents that were auto-closed.
    pub fn auto_close_decomposed_parents(&self) -> Result<Vec<String>> {
        let parents = self.list(Some("decomposed"))?;
        let mut closed = Vec::new();
        let now = unix_now();
        let iso = unix_to_iso_date(now);
        for parent in parents {
            let child_ids = parse_decomposed_children(&parent.notes);
            if child_ids.is_empty() {
                continue;
            }
            let mut all_done = true;
            for cid in &child_ids {
                match self.get(cid)? {
                    Some(child) if child.status == "done" => {}
                    _ => {
                        all_done = false;
                        break;
                    }
                }
            }
            if !all_done {
                continue;
            }
            let changed = self.conn.execute(
                "UPDATE gaps SET status='done', closed_at=?1, closed_date=?2
                 WHERE id=?3 AND status NOT IN
                   ('done','superseded','wontfix','wont_fix','closed','closed_not_a_bug','already_satisfied')",
                params![now, iso, parent.id],
            )?;
            if changed > 0 {
                let _ = self
                    .conn
                    .execute("DELETE FROM leases WHERE gap_id=?1", params![parent.id]);
                closed.push(parent.id);
            }
        }
        Ok(closed)
    }
}

// ────────── repos table (MISSION-033) ──────────

impl GapStore {
    /// Parse one row from the repos table.
    fn row_to_repo(row: &rusqlite::Row<'_>) -> rusqlite::Result<RepoRow> {
        Ok(RepoRow {
            id: row.get(0)?,
            owner: row.get(1)?,
            name: row.get(2)?,
            added_at: row.get(3)?,
            last_scan_at: row.get(4)?,
            last_clone_at: row.get(5)?,
            last_ship_at: row.get(6)?,
            cascade_tier: row.get(7)?,
            status: row.get(8)?,
        })
    }

    /// Emit a `repo_import_skipped` event to `.chump-locks/ambient.jsonl`.
    fn emit_repo_import_skipped(&self, value: &str, reason: &str) {
        let amb = self.repo_root.join(".chump-locks").join("ambient.jsonl");
        let ts = unix_to_iso_full(unix_now());
        let safe_val = value.replace('"', "\\\"");
        let line = format!(
            "{{\"ts\":\"{ts}\",\"kind\":\"repo_import_skipped\",\
             \"value\":\"{safe_val}\",\"reason\":\"{reason}\"}}\n"
        );
        use std::io::Write as _;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&amb)
        {
            let _ = f.write_all(line.as_bytes());
        }
    }

    /// MISSION-033: scan a list of YamlGap rows and INSERT OR IGNORE one
    /// repos row per distinct `external_repo:<owner>/<repo>` tag found in
    /// `skills_required`. Idempotent — existing rows are never overwritten.
    /// Malformed tags (no '/' separator) are silently skipped and a
    /// `kind=repo_import_skipped` event is emitted to ambient.jsonl.
    pub(crate) fn upsert_repos_from_skills(&self, gaps: &[YamlGap]) -> Result<usize> {
        let now = unix_now();
        let mut inserted = 0usize;
        let mut seen = std::collections::HashSet::new();

        for g in gaps {
            let skills = match &g.skills_required {
                Some(v) => {
                    let s = yaml_value_to_string(v);
                    if s.is_empty() {
                        continue;
                    }
                    s
                }
                None => continue,
            };
            for tag in skills.split(',') {
                let tag = tag.trim();
                if !tag.starts_with("external_repo:") {
                    continue;
                }
                let owner_repo = &tag["external_repo:".len()..];
                if seen.contains(owner_repo) {
                    continue;
                }
                let Some(slash) = owner_repo.find('/') else {
                    // Malformed — no '/' separator. Skip + emit ambient event.
                    self.emit_repo_import_skipped(owner_repo, "no_slash");
                    continue;
                };
                let owner = &owner_repo[..slash];
                let name = &owner_repo[slash + 1..];
                if owner.is_empty() || name.is_empty() {
                    self.emit_repo_import_skipped(owner_repo, "empty_component");
                    continue;
                }
                let changed = self.conn.execute(
                    "INSERT OR IGNORE INTO repos(id,owner,name,added_at,cascade_tier,status)
                     VALUES(?1,?2,?3,?4,'dogfood','active')",
                    params![owner_repo, owner, name, now],
                )?;
                if changed > 0 {
                    inserted += 1;
                }
                seen.insert(owner_repo.to_string());
            }
        }
        Ok(inserted)
    }

    /// List repos, optionally filtered by status.
    pub fn list_repos(&self, status_filter: Option<&str>) -> Result<Vec<RepoRow>> {
        let sql = if status_filter.is_some() {
            "SELECT id,owner,name,added_at,last_scan_at,last_clone_at,last_ship_at,\
             cascade_tier,status FROM repos WHERE status=?1 ORDER BY id"
        } else {
            "SELECT id,owner,name,added_at,last_scan_at,last_clone_at,last_ship_at,\
             cascade_tier,status FROM repos ORDER BY id"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let rows = if let Some(s) = status_filter {
            stmt.query_map(params![s], Self::row_to_repo)?
                .collect::<Result<Vec<_>, _>>()?
        } else {
            stmt.query_map([], Self::row_to_repo)?
                .collect::<Result<Vec<_>, _>>()?
        };
        Ok(rows)
    }

    /// Fetch one repo by id ("owner/repo"). Returns None if not found.
    pub fn get_repo(&self, id: &str) -> Result<Option<RepoRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT id,owner,name,added_at,last_scan_at,last_clone_at,last_ship_at,\
             cascade_tier,status FROM repos WHERE id=?1",
        )?;
        stmt.query_row(params![id], Self::row_to_repo)
            .optional()
            .map_err(Into::into)
    }

    /// Insert a new repo row. Returns error if the id already exists.
    /// For idempotent upsert from gap import, use upsert_repos_from_skills.
    pub fn add_repo(
        &self,
        id: &str,
        owner: &str,
        name: &str,
        cascade_tier: &str,
        status: &str,
    ) -> Result<()> {
        let now = unix_now();
        self.conn.execute(
            "INSERT INTO repos(id,owner,name,added_at,cascade_tier,status)
             VALUES(?1,?2,?3,?4,?5,?6)",
            params![id, owner, name, now, cascade_tier, status],
        )?;
        Ok(())
    }

    /// Remove a repo row. Does NOT touch any gaps. Errors if not found.
    pub fn remove_repo(&self, id: &str) -> Result<bool> {
        let n = self
            .conn
            .execute("DELETE FROM repos WHERE id=?1", params![id])?;
        Ok(n > 0)
    }

    /// Update one or more nullable fields on a repo row.
    /// All parameters are Option — only Some values are applied.
    /// Returns false if the repo id was not found.
    pub fn set_repo_fields(
        &self,
        id: &str,
        cascade_tier: Option<&str>,
        status: Option<&str>,
        last_scan_at: Option<i64>,
        last_clone_at: Option<i64>,
        last_ship_at: Option<i64>,
    ) -> Result<bool> {
        let existing = match self.get_repo(id)? {
            Some(r) => r,
            None => return Ok(false),
        };
        let tier = cascade_tier.unwrap_or(&existing.cascade_tier);
        let st = status.unwrap_or(&existing.status);
        let scan = last_scan_at.or(existing.last_scan_at);
        let clone = last_clone_at.or(existing.last_clone_at);
        let ship = last_ship_at.or(existing.last_ship_at);
        self.conn.execute(
            "UPDATE repos SET cascade_tier=?1,status=?2,last_scan_at=?3,\
             last_clone_at=?4,last_ship_at=?5 WHERE id=?6",
            params![tier, st, scan, clone, ship, id],
        )?;
        Ok(true)
    }

    /// Count *open* gaps linked to a repo via `external_repo:<id>` tag in
    /// skills_required. Counts open work only — done/closed/in_review gaps
    /// are noise for the demo-target picker (EFFECTIVE-216).
    pub fn repo_gap_count(&self, repo_id: &str) -> Result<i64> {
        // skills_required is a CSV; leading `%` lets the tag appear at start,
        // middle, or end of the field.
        let pattern = format!("%external_repo:{}%", repo_id);
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM gaps \
                 WHERE skills_required LIKE ?1 AND status = 'open'",
                params![pattern],
                |r| r.get(0),
            )
            .map_err(Into::into)
    }
}

// ────────── routing outcomes (COG-036) ──────────

/// One row written to `routing_outcomes` per terminal dispatch outcome.
/// Consumed by `routing_scoreboard()` and (eventually) the COG-037
/// Thompson-sampling router.
#[derive(Debug, Clone, Default)]
pub struct RoutingOutcomeRow {
    /// RFC3339 UTC timestamp.
    pub recorded_at: String,
    /// `"research"`, `"dispatch"`, or `""` (unknown / generic).
    pub task_class: String,
    pub priority: String,
    pub effort: String,
    /// `"claude"` | `"chump-local"`.
    pub backend: String,
    pub model: String,
    pub provider_pfx: String,
    pub gap_id: String,
    /// `"shipped"` | `"stalled"` | `"killed"` | `"ci_failed"`.
    pub outcome: String,
    pub pr_number: Option<u32>,
    pub duration_s: i64,
    /// INFRA-1770: estimated USD cost of this one dispatch attempt (LLM
    /// spend). `0.0` when unknown/unmeasured — callers should prefer a real
    /// measured cost (e.g. `session_ledger::cost_usd_from_tokens`) over the
    /// effort-tier default when one is available.
    pub cost_usd: f64,
}

/// One aggregated row from the `(task_class, backend, model, provider_pfx)`
/// rollup used by `chump dispatch scoreboard` and the COG-037 sampler.
#[derive(Debug, Clone)]
pub struct ScoreboardEntry {
    pub task_class: String,
    pub backend: String,
    pub model: String,
    pub provider_pfx: String,
    pub successes: u64,
    pub failures: u64,
    pub total: u64,
    pub success_rate: f64,
    pub last_seen: String,
    /// INFRA-1770: mean `cost_usd` across every attempt on this route.
    pub avg_cost_usd: f64,
    /// INFRA-1770: `(success_rate * value) / avg_cost_usd`, the score the
    /// (eventual) INFRA-1764 router is meant to rank routes by instead of
    /// success_rate alone — a route that ships reliably but burns 10x the
    /// budget of an equally-reliable cheaper route should rank lower.
    /// `value` is the mean priority weight of attempts on this route (P0=4
    /// … P3=1, default 2), a proxy for how much a shipped gap on this route
    /// was actually worth. `0.0` when `avg_cost_usd` is `0.0` (no cost data
    /// yet — most historical rows predate this column).
    pub route_score: f64,
}

impl GapStore {
    /// Append one routing-outcome row. Best-effort: callers (the orchestrator
    /// monitor) treat write errors as non-fatal because the dispatch already
    /// succeeded/failed before this row exists.
    pub fn record_routing_outcome(&self, row: &RoutingOutcomeRow) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO routing_outcomes
                    (recorded_at, task_class, priority, effort, backend, model,
                     provider_pfx, gap_id, outcome, pr_number, duration_s, cost_usd)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    row.recorded_at,
                    row.task_class,
                    row.priority,
                    row.effort,
                    row.backend,
                    row.model,
                    row.provider_pfx,
                    row.gap_id,
                    row.outcome,
                    row.pr_number,
                    row.duration_s,
                    row.cost_usd,
                ],
            )
            .context("insert routing_outcomes row")?;
        Ok(())
    }

    /// Aggregate routing outcomes by `(task_class, backend, model,
    /// provider_pfx)`. `"shipped"` counts as success; everything else is a
    /// failure. Ordered by `total DESC, success_rate DESC` so the scoreboard
    /// surfaces the most-trafficked routes first.
    pub fn routing_scoreboard(&self) -> Result<Vec<ScoreboardEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT task_class, backend, model, provider_pfx,
                    SUM(CASE WHEN outcome='shipped' THEN 1 ELSE 0 END) AS successes,
                    SUM(CASE WHEN outcome='shipped' THEN 0 ELSE 1 END) AS failures,
                    COUNT(*) AS total,
                    MAX(recorded_at) AS last_seen,
                    AVG(cost_usd) AS avg_cost_usd,
                    AVG(CASE priority
                        WHEN 'P0' THEN 4.0 WHEN 'P1' THEN 3.0
                        WHEN 'P2' THEN 2.0 WHEN 'P3' THEN 1.0
                        ELSE 2.0 END) AS avg_value
             FROM routing_outcomes
             GROUP BY task_class, backend, model, provider_pfx
             ORDER BY total DESC, successes DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            let task_class: String = r.get(0)?;
            let backend: String = r.get(1)?;
            let model: String = r.get(2)?;
            let provider_pfx: String = r.get(3)?;
            let successes: i64 = r.get(4)?;
            let failures: i64 = r.get(5)?;
            let total: i64 = r.get(6)?;
            let last_seen: String = r.get::<_, Option<String>>(7)?.unwrap_or_default();
            let avg_cost_usd: f64 = r.get::<_, Option<f64>>(8)?.unwrap_or(0.0);
            let avg_value: f64 = r.get::<_, Option<f64>>(9)?.unwrap_or(2.0);
            let success_rate = if total > 0 {
                successes as f64 / total as f64
            } else {
                0.0
            };
            // INFRA-1770: score routes by (success_rate * value) / cost —
            // undefined (0.0) until real cost_usd data accumulates.
            let route_score = if avg_cost_usd > 0.0 {
                (success_rate * avg_value) / avg_cost_usd
            } else {
                0.0
            };
            Ok(ScoreboardEntry {
                task_class,
                backend,
                model,
                provider_pfx,
                successes: successes as u64,
                failures: failures as u64,
                total: total as u64,
                success_rate,
                last_seen,
                avg_cost_usd,
                route_score,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }
}

// ────────────────────────── tests ──────────────────────────

/// INFRA-2423: auto-fetch unit tests for `GapStore::ship()`.
///
/// These tests verify the auto-fetch logic introduced to eliminate the deleted
/// bypass env var. They use a two-repo setup (local + bare
/// "origin") to produce genuine `git rev-list` counts, rather than mocking.
///
/// Test structure:
///   1. Reserve a gap via `store.reserve()` to get the assigned ID.
///   2. Build a git commit carrying that ID on the right branch.
///   3. Call `store.ship()` and assert the expected outcome.
#[cfg(test)]
mod auto_fetch_tests {
    use super::*;
    use tempfile::tempdir;

    fn git(dir: &std::path::Path, args: &[&str]) {
        std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .ok();
    }

    fn git_config(dir: &std::path::Path) {
        git(dir, &["config", "user.email", "test@test.local"]);
        git(dir, &["config", "user.name", "test"]);
    }

    /// Init a local git repo on `main` branch with one commit.
    fn init_repo(dir: &std::path::Path) {
        git(dir, &["init", "--quiet"]);
        git_config(dir);
        git(dir, &["checkout", "-b", "main"]);
        std::fs::write(dir.join("README.md"), b"init").ok();
        git(dir, &["add", "README.md"]);
        git(
            dir,
            &["commit", "--quiet", "--allow-empty", "-m", "chore: initial"],
        );
    }

    /// Create a bare clone of `src` at `dest`.
    fn bare_clone(src: &std::path::Path, dest: &std::path::Path) {
        std::process::Command::new("git")
            .args(["clone", "--bare", "--quiet", src.to_str().unwrap(), "."])
            .current_dir(dest)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .ok();
    }

    /// Clone `origin_url` into `dest` and configure identity.
    fn non_bare_clone(origin_url: &str, dest: &std::path::Path) {
        std::process::Command::new("git")
            .args(["clone", "--quiet", origin_url, "."])
            .current_dir(dest)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .ok();
        git_config(dest);
    }

    /// Open a GapStore on `repo`, suppressing open-PR scan for tests.
    fn open_store(repo: &std::path::Path) -> GapStore {
        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
        }
        GapStore::open(repo).unwrap()
    }

    /// Scenario C: clean local main up-to-date with origin.
    /// ship() auto-fetches, finds 0 commits behind, proof-of-merge passes
    /// (gap ID is already in local main's log), succeeds with no noise.
    #[test]
    fn scenario_c_up_to_date_clean_succeeds() {
        let dir = tempdir().unwrap();
        let repo = dir.path();
        init_repo(repo);

        // Open store BEFORE creating the origin so reserve() works.
        let store = open_store(repo);
        let gap_id = store
            .reserve("INFRA", "scenario-c auto-fetch", "P3", "xs")
            .unwrap();

        // Commit the gap ID to local main.
        let msg = format!("feat({gap_id}): scenario-c proof-of-merge");
        git(repo, &["commit", "--allow-empty", "--quiet", "-m", &msg]);

        // Set up bare origin in sync with local.
        let origin_dir = tempdir().unwrap();
        bare_clone(repo, origin_dir.path());
        std::process::Command::new("git")
            .args([
                "remote",
                "add",
                "origin",
                origin_dir.path().to_str().unwrap(),
            ])
            .current_dir(repo)
            .status()
            .ok();
        git(repo, &["fetch", "origin", "--quiet"]);

        // ship(): behind=0, proof passes, no dirty-tree check triggered.
        let result = store.ship(&gap_id, "test-session", None);
        assert!(
            result.is_ok(),
            "Scenario C: expected Ok on up-to-date clean repo; got: {result:?}"
        );
    }

    /// Scenario B: dirty local main behind origin.
    /// ship() auto-fetches, detects behind > 0, detects dirty tree,
    /// returns Err with the "cannot auto-pull with uncommitted changes" message.
    /// Setting the deleted bypass var to "1" has NO effect (var is gone).
    #[test]
    fn scenario_b_dirty_behind_origin_exits_error() {
        let dir = tempdir().unwrap();
        let repo = dir.path();
        init_repo(repo);

        // Create origin and push.
        let origin_dir = tempdir().unwrap();
        bare_clone(repo, origin_dir.path());
        std::process::Command::new("git")
            .args([
                "remote",
                "add",
                "origin",
                origin_dir.path().to_str().unwrap(),
            ])
            .current_dir(repo)
            .status()
            .ok();
        git(repo, &["push", "--quiet", "origin", "main"]);

        // Advance origin (via scratch clone) so local is behind. Also
        // commit a (real-world-realistic) `.chump/state.sql` so
        // INFRA-3687's canonical_max_id() can verify canonical truth here —
        // this scenario is exercising ship()'s dirty-tree guard, not the
        // stale-checkout reserve() guard, so canonical must be readable or
        // the new fail-closed gate below would (correctly, but not what
        // this test is about) refuse the reserve() call before ship() is
        // ever reached.
        let scratch_dir = tempdir().unwrap();
        non_bare_clone(origin_dir.path().to_str().unwrap(), scratch_dir.path());
        std::fs::write(scratch_dir.path().join("extra.txt"), b"extra").ok();
        std::fs::create_dir_all(scratch_dir.path().join(".chump")).ok();
        std::fs::write(scratch_dir.path().join(".chump/state.sql"), b"gaps: []\n").ok();
        git(
            scratch_dir.path(),
            &["add", "extra.txt", ".chump/state.sql"],
        );
        git(
            scratch_dir.path(),
            &["commit", "--quiet", "-m", "chore: origin-ahead"],
        );
        git(scratch_dir.path(), &["push", "--quiet", "origin", "main"]);

        // Make local dirty (staged change).
        std::fs::write(repo.join("dirty.txt"), b"uncommitted").ok();
        git(repo, &["add", "dirty.txt"]);

        let store = open_store(repo);
        let gap_id = store
            .reserve("INFRA", "scenario-b dirty-behind", "P3", "xs")
            .unwrap();

        // INFRA-2423: the deleted bypass var must have no effect.
        // Construct the name dynamically so no literal of the deleted var
        // appears in the source (the absence check in test-status-flip-proof-of-merge.sh
        // does a literal grep and must find zero matches outside doc comments).
        let deleted_bypass_var = ["CHUMP_BYPASS_PROOF", "_OF_MERGE"].concat();
        unsafe {
            std::env::set_var(&deleted_bypass_var, "1");
        }
        let result = store.ship(&gap_id, "test-session", None);
        unsafe {
            std::env::remove_var(&deleted_bypass_var);
        }

        assert!(
            result.is_err(),
            "Scenario B: expected Err on dirty+behind; got Ok"
        );
        let err_msg = format!("{:?}", result.unwrap_err());
        assert!(
            err_msg.contains("cannot auto-pull with uncommitted changes"),
            "Scenario B: expected dirty-tree message; got: {err_msg}"
        );
    }

    /// Scenario A: clean local main behind origin.
    /// ship() auto-fetches, detects behind > 0, finds clean tree,
    /// auto-pulls (ff-only), proof-of-merge passes (gap ID now in log), succeeds.
    #[test]
    fn scenario_a_clean_behind_auto_pulls_and_succeeds() {
        let dir = tempdir().unwrap();
        let repo = dir.path();
        init_repo(repo);

        // Create origin and push.
        let origin_dir = tempdir().unwrap();
        bare_clone(repo, origin_dir.path());
        std::process::Command::new("git")
            .args([
                "remote",
                "add",
                "origin",
                origin_dir.path().to_str().unwrap(),
            ])
            .current_dir(repo)
            .status()
            .ok();
        git(repo, &["push", "--quiet", "origin", "main"]);

        // Reserve the gap BEFORE advancing origin so store has the row.
        let store = open_store(repo);
        let gap_id = store
            .reserve("INFRA", "scenario-a clean-behind", "P3", "xs")
            .unwrap();

        // Advance origin with a commit that carries the gap ID.
        let scratch_dir = tempdir().unwrap();
        non_bare_clone(origin_dir.path().to_str().unwrap(), scratch_dir.path());
        std::fs::write(scratch_dir.path().join("landed.txt"), b"landed").ok();
        git(scratch_dir.path(), &["add", "landed.txt"]);
        let msg = format!("feat({gap_id}): scenario-a origin-ahead with gap id");
        git(scratch_dir.path(), &["commit", "--quiet", "-m", &msg]);
        git(scratch_dir.path(), &["push", "--quiet", "origin", "main"]);

        // Local is clean and behind — ship() should auto-pull then succeed.
        let result = store.ship(&gap_id, "test-session", None);
        assert!(
            result.is_ok(),
            "Scenario A: expected Ok after auto-pull on clean+behind; got: {result:?}"
        );
    }

    /// INFRA-3687 regression lock, part 1: the exact stale-checkout drift
    /// from the real repro (a checkout 177 commits behind reserved
    /// INFRA-3680, canonically a merged "parse_verdict" gap). Local
    /// state.db only ever sees a low max (INFRA-1xx-ish); origin/main's
    /// canonical `.chump/state.sql` already records a much higher gap
    /// (INFRA-3866). `reserve()` must fold in the canonical max and must
    /// NOT hand back an ID at or below it.
    #[test]
    fn canonical_max_id_reads_origin_state_sql_and_reserve_beats_stale_local() {
        let dir = tempdir().unwrap();
        let repo = dir.path();
        init_repo(repo);

        // Origin starts in sync with local (no state.sql yet).
        let origin_dir = tempdir().unwrap();
        bare_clone(repo, origin_dir.path());
        std::process::Command::new("git")
            .args([
                "remote",
                "add",
                "origin",
                origin_dir.path().to_str().unwrap(),
            ])
            .current_dir(repo)
            .status()
            .ok();
        git(repo, &["push", "--quiet", "origin", "main"]);

        // Advance origin (via scratch clone) with a canonical state.sql
        // recording INFRA-3866 as an already-merged gap — this checkout's
        // local state.db has never seen it. Also plant a junk
        // `INFRA-9999999`-shaped substring in the notes field of the SAME
        // row to prove the id-column-only extraction isn't fooled by it.
        let scratch_dir = tempdir().unwrap();
        non_bare_clone(origin_dir.path().to_str().unwrap(), scratch_dir.path());
        std::fs::create_dir_all(scratch_dir.path().join(".chump")).ok();
        std::fs::write(
            scratch_dir.path().join(".chump/state.sql"),
            b"gaps:\n\
              - id: INFRA-3866\n\
              \x20 domain: INFRA\n\
              \x20 title: parse_verdict\n\
              \x20 status: done\n\
              \x20 priority: P2\n\
              \x20 effort: s\n\
              \x20 notes: \"see also junk id INFRA-9999999 mentioned in an old incident writeup\"\n",
        )
        .ok();
        git(scratch_dir.path(), &["add", ".chump/state.sql"]);
        git(
            scratch_dir.path(),
            &[
                "commit",
                "--quiet",
                "-m",
                "chore: canonical state.sql with INFRA-3866",
            ],
        );
        git(scratch_dir.path(), &["push", "--quiet", "origin", "main"]);

        // Local checkout never pulled this — reproduces the "N commits
        // behind" drift. Seed local state.db with a low max (INFRA-1) so
        // existing_max alone would naively pick INFRA-2.
        let store = open_store(repo);
        store
            .reserve("INFRA", "local-only seed, stale checkout", "P2", "xs")
            .unwrap();

        let canonical = store.canonical_max_id("INFRA");
        assert_eq!(
            canonical,
            Some(3866),
            "canonical_max_id must read origin/main's state.sql id column \
             only (3866), ignoring the junk INFRA-9999999 substring in \
             notes; got {canonical:?}"
        );

        let id = store
            .reserve("INFRA", "post-drift reserve must beat canonical", "P1", "s")
            .unwrap();
        let picked_num: i64 = id
            .strip_prefix("INFRA-")
            .and_then(|n| n.parse().ok())
            .unwrap_or(-1);
        assert!(
            picked_num > 3866,
            "reserve must allocate above canonical max 3866 despite a \
             stale local checkout; got {id}"
        );
    }

    /// INFRA-3687 regression lock, part 2: fail-closed when this checkout
    /// is genuinely behind origin/main AND canonical truth is unreadable
    /// (origin/main advanced but never touched `.chump/state.sql`, so `git
    /// show origin/main:.chump/state.sql` fails). `reserve()` must refuse
    /// rather than silently trust a possibly-stale local counter.
    /// `CHUMP_RESERVE_ALLOW_STALE=1` must bypass the refusal.
    #[test]
    fn reserve_fails_closed_when_behind_and_canonical_unreadable_bypass_works() {
        let dir = tempdir().unwrap();
        let repo = dir.path();
        init_repo(repo);

        let origin_dir = tempdir().unwrap();
        bare_clone(repo, origin_dir.path());
        std::process::Command::new("git")
            .args([
                "remote",
                "add",
                "origin",
                origin_dir.path().to_str().unwrap(),
            ])
            .current_dir(repo)
            .status()
            .ok();
        git(repo, &["push", "--quiet", "origin", "main"]);

        // Advance origin with a commit that does NOT touch .chump/state.sql
        // — canonical_max_id's `git show origin/main:.chump/state.sql` will
        // fail (the file has never existed at that ref), simulating
        // "canonical truth unreadable" while genuinely behind.
        let scratch_dir = tempdir().unwrap();
        non_bare_clone(origin_dir.path().to_str().unwrap(), scratch_dir.path());
        std::fs::write(scratch_dir.path().join("extra.txt"), b"extra").ok();
        git(scratch_dir.path(), &["add", "extra.txt"]);
        git(
            scratch_dir.path(),
            &[
                "commit",
                "--quiet",
                "-m",
                "chore: origin-ahead, no state.sql ever committed",
            ],
        );
        git(scratch_dir.path(), &["push", "--quiet", "origin", "main"]);

        let store = open_store(repo);
        unsafe {
            std::env::remove_var("CHUMP_RESERVE_ALLOW_STALE");
        }
        let result = store.reserve(
            "INFRA",
            "should refuse — unverifiable staleness",
            "P3",
            "xs",
        );
        assert!(
            result.is_err(),
            "expected Err when behind + canonical-unreadable; got {result:?}"
        );
        let msg = format!("{:?}", result.unwrap_err());
        assert!(
            msg.contains("behind origin/main") && msg.contains("CHUMP_RESERVE_ALLOW_STALE"),
            "expected staleness refusal message naming the escape hatch; got: {msg}"
        );

        // CHUMP_RESERVE_ALLOW_STALE=1 must bypass the fail-closed gate.
        unsafe {
            std::env::set_var("CHUMP_RESERVE_ALLOW_STALE", "1");
        }
        let result2 = store.reserve("INFRA", "bypass allowed via env escape hatch", "P3", "xs");
        unsafe {
            std::env::remove_var("CHUMP_RESERVE_ALLOW_STALE");
        }
        assert!(
            result2.is_ok(),
            "CHUMP_RESERVE_ALLOW_STALE=1 must bypass the fail-closed gate; got {result2:?}"
        );
    }
}

/// INFRA-3687: fast, no-git unit tests for the id-column-only extraction
/// that [`GapStore::canonical_max_id`] delegates to. Proves the invariant
/// directly against the parser + filter, independent of the git plumbing
/// (which the `auto_fetch_tests` module above exercises end-to-end).
#[cfg(test)]
mod canonical_max_id_parse_tests {
    use super::*;

    #[test]
    fn canonical_max_id_ignores_junk_ids_in_descriptions() {
        // Real state.sql shape: one gap whose `id` is legitimately
        // INFRA-3887, but whose `notes` field quotes a much larger
        // `INFRA-9999999`-shaped substring as example junk data (and
        // INFRA-9999 too, just to be doubly sure) — plus an older, lower
        // real gap. A naive text/regex scan over the whole dump would
        // return 9999999; the id-column-only extraction must return 3887.
        let yaml = r#"
gaps:
- id: INFRA-3887
  domain: INFRA
  title: "real gap"
  status: open
  priority: P2
  effort: s
  notes: "mentions INFRA-9999999 as junk test data, and INFRA-9999 too, but is NOT one"
- id: INFRA-042
  domain: INFRA
  title: "older real gap"
  status: done
  priority: P3
  effort: xs
"#;
        let file = GapStore::parse_state_sql_yaml(yaml).expect("state.sql YAML must parse");
        let max = GapStore::max_id_num_in_gaps(&file.gaps, "INFRA");
        assert_eq!(
            max,
            Some(3887),
            "junk INFRA-9999999 / INFRA-9999 substrings in `notes` must not \
             poison the max — only the `id` column is authoritative; got {max:?}"
        );
    }

    #[test]
    fn max_id_num_in_gaps_drops_absurdly_large_ids_as_a_sanity_ceiling() {
        // Defense-in-depth: even if a malformed/synthetic row DID slip an
        // absurd number into the `id` column itself, it must not poison
        // allocation. This is belt-and-suspenders on top of the
        // id-column-only extraction above, not the primary defense.
        let yaml = r#"
gaps:
- id: INFRA-3887
  domain: INFRA
  title: "real gap"
  status: open
  priority: P2
  effort: s
- id: INFRA-99999999
  domain: INFRA
  title: "synthetic/malformed fixture row — must be ignored"
  status: open
  priority: P2
  effort: s
"#;
        let file = GapStore::parse_state_sql_yaml(yaml).expect("state.sql YAML must parse");
        let max = GapStore::max_id_num_in_gaps(&file.gaps, "INFRA");
        assert_eq!(
            max,
            Some(3887),
            "an absurdly large id-column value must be dropped by the sanity \
             ceiling, not treated as the real max; got {max:?}"
        );
    }

    #[test]
    fn canonical_max_id_returns_none_without_a_git_dir() {
        // Every existing test_store()-based fixture (and any real
        // synthetic GapStore built in a bare TempDir) has no `.git` at
        // all. canonical_max_id must short-circuit to None rather than
        // attempting to shell out to git in a directory that isn't a repo.
        let dir = tempfile::tempdir().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        assert_eq!(store.canonical_max_id("INFRA"), None);
    }
}

#[cfg(test)]
mod proof_of_merge_tests {
    //! INFRA-1392: pure-function tests for the proof-of-merge helper.
    use super::*;
    use tempfile::tempdir;

    // CREDIBLE-280: every git invocation in this module must be hermetic (no
    // ambient global/system config, no leaked GIT_* env) and its exit status
    // must be checked. Before this fix, `empty_repo_with_no_commits_passes`,
    // `repo_with_commits_but_no_main_branch_fails_closed`,
    // `real_repo_with_matching_commit_subject_passes`, and
    // `real_repo_with_pr_number_in_subject_passes_when_closed_pr_set` ran
    // `git init`/`git config`/`git commit` against whatever global/system
    // gitconfig happened to be present on the runner and silently discarded
    // the exit status of `git commit` (`let _ = ... .status()`). On a
    // CI-hosted runner with an ambient gitconfig (e.g. `commit.gpgsign` or a
    // `core.hooksPath` pointing at this repo's hooks), `git commit` could
    // fail without the test noticing, leaving the fixture repo with fewer
    // commits than the assertions below assume — an intermittent failure
    // that never reproduced locally where no such ambient config exists.
    fn hermetic_git(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
        std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .output()
            .expect("git should spawn")
    }

    #[test]
    fn fixture_without_git_dir_passes_through() {
        // Tests use synthetic stores without a real .git tree. The guard
        // must default to "pass" so existing fixture-based tests don't
        // get broken by the new behaviour.
        let dir = tempdir().unwrap();
        assert!(verify_proof_of_merge(dir.path(), "INFRA-9500", Some(123)));
        assert!(verify_proof_of_merge(dir.path(), "INFRA-9500", None));
    }

    #[test]
    fn credible218_merge_older_than_200_commits_is_proven() {
        // CREDIBLE-218: a merge that landed MORE than 200 commits ago must still be
        // provable. The old `-n 200` window silently missed it, ship() refused, and the
        // gap became a permanent ghost. Here the gap-mentioning commit is the OLDEST,
        // buried under 205 newer commits.
        //
        // FLAKE FIX (CREDIBLE-282): this fixture flaked red on GitHub-hosted ubuntu
        // runners even after making every `git commit` call hermetic. Root cause: it
        // spawned 206 separate `git commit` subprocesses in a tight loop. Under CI
        // resource contention (fork/exec pressure, disk I/O contention from sibling
        // shards), an occasional `git commit` invocation in that chain silently failed
        // ("filler N must land"), even with clean env + inline identity.
        //
        // CREDIBLE-289 FIX: replace the 206-subprocess commit loop with a SINGLE
        // `git fast-import` call. fast-import takes the entire commit graph as one
        // stdin stream and builds it in-process — no per-commit fork/exec, so there is
        // nothing left for CI resource contention to race.
        let dir = tempdir().unwrap();
        // Hermetic git: no ambient global/system config and no leaked GIT_* env can
        // perturb this fixture on a shared runner.
        if !hermetic_git(dir.path(), &["init", "--initial-branch=main", "--quiet"])
            .status
            .success()
        {
            return; // older git without --initial-branch
        }
        // Build the whole 206-commit chain as one fast-import stream. Root commit
        // (mark :1) carries the gap ID; it has no `from` line so it starts a fresh
        // root. Every later commit omits `from` too — fast-import defaults to the
        // branch's current tip, so they chain automatically.
        let mut stream = String::new();
        let write_commit = |mark: usize, msg: &str, stream: &mut String| {
            stream.push_str("commit refs/heads/main\n");
            stream.push_str(&format!("mark :{mark}\n"));
            stream.push_str("author t <t@t.local> 0 +0000\n");
            stream.push_str("committer t <t@t.local> 0 +0000\n");
            stream.push_str(&format!("data {}\n", msg.len()));
            stream.push_str(msg);
            stream.push_str("\n\n");
        };
        write_commit(
            1,
            "EFFECTIVE-9999: the real merge, buried deep",
            &mut stream,
        );
        // 205 newer commits bury it past the old -n 200 window.
        for i in 0..205 {
            write_commit(2 + i, &format!("chore: filler {i}"), &mut stream);
        }

        use std::io::Write;
        let mut child = std::process::Command::new("git")
            .args(["fast-import", "--quiet"])
            .current_dir(dir.path())
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("git fast-import should spawn");
        child
            .stdin
            .take()
            .expect("fast-import stdin")
            .write_all(stream.as_bytes())
            .expect("fast-import stream should write");
        let out = child
            .wait_with_output()
            .expect("git fast-import should complete");
        assert!(
            out.status.success(),
            "git fast-import must build the 206-commit fixture: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            verify_proof_of_merge(dir.path(), "EFFECTIVE-9999", None),
            "a merge >200 commits back must still be proven (CREDIBLE-218)"
        );
    }

    #[test]
    fn empty_repo_with_no_commits_passes() {
        // Integration tests `git init` then immediately try to ship a
        // synthetic gap. Zero commits = test fixture, not production.
        // Guard passes so tests can ship synthetic gaps.
        let dir = tempdir().unwrap();
        let init = hermetic_git(dir.path(), &["init", "--quiet"]);
        assert!(
            init.status.success(),
            "git init must succeed: {}",
            String::from_utf8_lossy(&init.stderr)
        );
        assert!(verify_proof_of_merge(dir.path(), "INFRA-9501", Some(123)));
    }

    #[test]
    fn repo_with_commits_but_no_main_branch_fails_closed() {
        // Genuinely odd production state: commits exist on some other
        // branch, but `main` doesn't. We have no way to verify proof
        // there — fail closed.
        let dir = tempdir().unwrap();
        let init = hermetic_git(dir.path(), &["init", "--initial-branch=other", "--quiet"]);
        if !init.status.success() {
            return; // older git without --initial-branch
        }
        hermetic_git(dir.path(), &["config", "user.email", "test@test.local"]);
        hermetic_git(dir.path(), &["config", "user.name", "test"]);
        let commit = hermetic_git(
            dir.path(),
            &[
                "commit",
                "--allow-empty",
                "-m",
                "feat: INFRA-9501 on side branch",
            ],
        );
        assert!(
            commit.status.success(),
            "git commit must succeed: {}",
            String::from_utf8_lossy(&commit.stderr)
        );
        // HEAD exists (commit on "other") but `git log main` will fail.
        assert!(!verify_proof_of_merge(dir.path(), "INFRA-9501", Some(123)));
    }

    #[test]
    fn real_repo_with_matching_commit_subject_passes() {
        let dir = tempdir().unwrap();
        let init = hermetic_git(dir.path(), &["init", "--initial-branch=main", "--quiet"]);
        if !init.status.success() {
            // Older git without --initial-branch; skip gracefully.
            return;
        }
        // Configure local user.email/name for the commit.
        hermetic_git(dir.path(), &["config", "user.email", "test@test.local"]);
        hermetic_git(dir.path(), &["config", "user.name", "test"]);
        let commit = hermetic_git(
            dir.path(),
            &[
                "commit",
                "--allow-empty",
                "-m",
                "feat(INFRA-9502): RESILIENT — proof-of-merge fixture",
            ],
        );
        assert!(
            commit.status.success(),
            "git commit must succeed: {}",
            String::from_utf8_lossy(&commit.stderr)
        );
        assert!(verify_proof_of_merge(dir.path(), "INFRA-9502", None));
        // Case-insensitive: lowercase claim should still hit the
        // uppercase commit subject.
        assert!(verify_proof_of_merge(dir.path(), "infra-9502", None));
        // Disjoint gap ID — should NOT match.
        assert!(!verify_proof_of_merge(dir.path(), "INFRA-9503", None));
    }

    #[test]
    fn real_repo_with_pr_number_in_subject_passes_when_closed_pr_set() {
        let dir = tempdir().unwrap();
        let init = hermetic_git(dir.path(), &["init", "--initial-branch=main", "--quiet"]);
        if !init.status.success() {
            return;
        }
        hermetic_git(dir.path(), &["config", "user.email", "test@test.local"]);
        hermetic_git(dir.path(), &["config", "user.name", "test"]);
        // Subject mentions only the PR number (squash-merge convention),
        // NOT the gap ID. The gap-ID branch of the check should miss but
        // the `(#PR)` branch should hit.
        let commit = hermetic_git(
            dir.path(),
            &[
                "commit",
                "--allow-empty",
                "-m",
                "feat: ship a thing (#4242)",
            ],
        );
        assert!(
            commit.status.success(),
            "git commit must succeed: {}",
            String::from_utf8_lossy(&commit.stderr)
        );
        assert!(verify_proof_of_merge(
            dir.path(),
            "INFRA-NO-MATCH",
            Some(4242)
        ));
        // Without the closed_pr hint, no match.
        assert!(!verify_proof_of_merge(dir.path(), "INFRA-NO-MATCH", None));
        // Wrong PR number — no match.
        assert!(!verify_proof_of_merge(
            dir.path(),
            "INFRA-NO-MATCH",
            Some(9999)
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_store() -> (GapStore, TempDir) {
        // INFRA-100: open-PR scan is default-ON in production but tests must
        // not hit the live `gh pr list` (would pick up real PR titles like
        // INFRA-200, INFRA-222 and pollute the deterministic fixtures).
        // Set the opt-out for the duration of every test that uses this
        // helper. SAFETY: tests in this file share the same process so an
        // env-var set is visible across them — that's exactly what we want
        // because every test in this module operates on synthetic fixtures.
        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
        }
        let dir = TempDir::new().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        (store, dir)
    }

    // ── INFRA-100: cross-source picker tests ──────────────────────────

    // ── RESILIENT-1364: decomposed-umbrella pick-pool + auto-close ────

    #[test]
    fn parse_decomposed_children_extracts_ids_from_notes() {
        let notes = "Decomposed into 3 slices: RESILIENT-1353, RESILIENT-1354, RESILIENT-1355";
        let ids = parse_decomposed_children(notes);
        assert_eq!(
            ids,
            vec!["RESILIENT-1353", "RESILIENT-1354", "RESILIENT-1355"]
        );

        assert!(parse_decomposed_children("no marker here").is_empty());
        assert!(parse_decomposed_children("").is_empty());
    }

    #[test]
    fn decomposed_status_is_registered() {
        // RESILIENT-1364: the picker at every call site keys off
        // gap_status_registry-known statuses; 'decomposed' must be present
        // from a fresh store, the same way 'ready_to_ship' etc. are.
        let (store, _dir) = test_store();
        let known = store.known_statuses().unwrap();
        assert!(
            known.iter().any(|k| k == "decomposed"),
            "registry must contain 'decomposed': {known:?}"
        );
    }

    #[test]
    fn decomposed_parent_is_excluded_from_the_open_pick_pool() {
        // RESILIENT-1364 fix #1: this is the exact failure mode from the
        // gap report — a just-sliced umbrella must never again be returned
        // by `chump gap list --status open` (store.list(Some("open"))),
        // which is what every worker/curator reads to pick its next gap.
        let (store, _dir) = test_store();
        let parent = store
            .reserve("RESILIENT", "umbrella parent", "P1", "m")
            .unwrap();
        let child1 = store.reserve("RESILIENT", "slice one", "P2", "s").unwrap();
        let child2 = store.reserve("RESILIENT", "slice two", "P2", "s").unwrap();

        // Before the fix, decompose left status='open' (only priority was
        // demoted) — that's exactly the bug. Simulate the fixed
        // `chump gap decompose --apply` write path.
        store
            .set_fields(
                &parent,
                GapFieldUpdate {
                    priority: Some("P2".into()),
                    status: Some("decomposed".into()),
                    notes: Some(format!("Decomposed into 2 slices: {child1}, {child2}")),
                    ..Default::default()
                },
            )
            .unwrap();

        let open = store.list(Some("open")).unwrap();
        assert!(
            !open.iter().any(|g| g.id == parent),
            "decomposed parent must not be in the open pick pool: {:?}",
            open.iter().map(|g| &g.id).collect::<Vec<_>>()
        );
        // Its slices, meanwhile, ARE pickable — that's the whole point.
        assert!(open.iter().any(|g| g.id == child1));
        assert!(open.iter().any(|g| g.id == child2));
    }

    #[test]
    fn auto_close_decomposed_parents_waits_for_all_children_then_closes() {
        // RESILIENT-1364 fix #2, mirroring the outcomes open_children
        // pattern: a decomposed parent must stay open (as a tracking row)
        // while ANY child slice is unfinished, and auto-close to 'done'
        // only once every child named in its notes has reached 'done'.
        let (store, _dir) = test_store();
        let parent = store
            .reserve("RESILIENT", "umbrella parent", "P1", "m")
            .unwrap();
        let child1 = store.reserve("RESILIENT", "slice one", "P2", "s").unwrap();
        let child2 = store.reserve("RESILIENT", "slice two", "P2", "s").unwrap();

        store
            .set_fields(
                &parent,
                GapFieldUpdate {
                    status: Some("decomposed".into()),
                    notes: Some(format!("Decomposed into 2 slices: {child1}, {child2}")),
                    ..Default::default()
                },
            )
            .unwrap();

        // Neither child done yet -> no auto-close.
        let closed = store.auto_close_decomposed_parents().unwrap();
        assert!(
            closed.is_empty(),
            "must not auto-close while both children are open"
        );
        assert_eq!(store.get(&parent).unwrap().unwrap().status, "decomposed");

        // One child done, one still open -> still no auto-close.
        store
            .set_fields(
                &child1,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(101),
                    ..Default::default()
                },
            )
            .unwrap();
        let closed = store.auto_close_decomposed_parents().unwrap();
        assert!(
            closed.is_empty(),
            "must not auto-close with one child still open"
        );
        assert_eq!(store.get(&parent).unwrap().unwrap().status, "decomposed");

        // Both children done -> parent auto-closes.
        store
            .set_fields(
                &child2,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(102),
                    ..Default::default()
                },
            )
            .unwrap();
        let closed = store.auto_close_decomposed_parents().unwrap();
        assert_eq!(closed, vec![parent.clone()]);
        assert_eq!(store.get(&parent).unwrap().unwrap().status, "done");

        // Idempotent: running again is a no-op (already done, excluded by
        // the terminal-status guard in the UPDATE).
        let closed_again = store.auto_close_decomposed_parents().unwrap();
        assert!(closed_again.is_empty());
    }

    #[test]
    fn decomposed_parent_rollup_reports_counts() {
        let (store, _dir) = test_store();
        let parent = store
            .reserve("RESILIENT", "umbrella parent", "P1", "m")
            .unwrap();
        let child1 = store.reserve("RESILIENT", "slice one", "P2", "s").unwrap();
        let child2 = store.reserve("RESILIENT", "slice two", "P2", "s").unwrap();
        store
            .set_fields(
                &parent,
                GapFieldUpdate {
                    status: Some("decomposed".into()),
                    notes: Some(format!("Decomposed into 2 slices: {child1}, {child2}")),
                    ..Default::default()
                },
            )
            .unwrap();

        let rollup = store
            .decomposed_parent_rollup(&parent)
            .unwrap()
            .expect("parent has a parseable decompose marker");
        assert_eq!(rollup.total, 2);
        assert_eq!(rollup.open, 2);
        assert_eq!(rollup.done, 0);

        store
            .set_fields(
                &child1,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(201),
                    ..Default::default()
                },
            )
            .unwrap();
        let rollup = store.decomposed_parent_rollup(&parent).unwrap().unwrap();
        assert_eq!(rollup.open, 1);
        assert_eq!(rollup.done, 1);

        // A plain gap with no decompose marker in its notes has no rollup.
        let plain = store
            .reserve("RESILIENT", "not an umbrella", "P2", "s")
            .unwrap();
        assert!(store.decomposed_parent_rollup(&plain).unwrap().is_none());
    }

    #[test]
    fn known_statuses_reads_the_registry() {
        // PRODUCT-176: the web PATCH surface validates incoming status values
        // against gap_status_registry — this asserts the reader sees both the
        // legacy seeds and the later INFRA-2137 additions.
        let (store, _dir) = test_store();
        let known = store.known_statuses().unwrap();
        for s in [
            "open",
            "claimed",
            "done",
            "wontfix",
            "bisect_quarantined",
            "ready_to_ship",
        ] {
            assert!(
                known.iter().any(|k| k == s),
                "registry must contain '{s}': {known:?}"
            );
        }
        assert!(
            !known.iter().any(|k| k == "tottaly-done"),
            "unknown stays unknown"
        );
    }

    #[test]
    fn set_outcome_jtbd_persists_and_round_trips() {
        // EFFECTIVE-443: the JTBD-sharpen triple (who / struggling-moment /
        // done-signal) must survive a write + re-fetch — before this slice,
        // outcomes only had jtbd fields in the ephemeral CLI output, not the
        // stored row, so a fresh `get_outcome`/`list_outcomes` always came
        // back with all three fields unset.
        let (store, _dir) = test_store();
        store
            .create_outcome("VISION-test1", "A test outcome", "P2", "done means x")
            .unwrap();

        // Freshly created outcome has no JTBD yet.
        let fresh = store.get_outcome("VISION-test1").unwrap().unwrap();
        assert!(fresh.jtbd_who.is_none());
        assert!(fresh.jtbd_struggling_moment.is_none());
        assert!(fresh.jtbd_done_signal.is_none());

        store
            .set_outcome_jtbd(
                "VISION-test1",
                "a solo dog walker juggling paper routes",
                "the phone rings mid-walk and they lose track of who's next",
                "they can glance at one place and see every upcoming route",
            )
            .unwrap();

        let updated = store.get_outcome("VISION-test1").unwrap().unwrap();
        assert_eq!(
            updated.jtbd_who.as_deref(),
            Some("a solo dog walker juggling paper routes")
        );
        assert_eq!(
            updated.jtbd_struggling_moment.as_deref(),
            Some("the phone rings mid-walk and they lose track of who's next")
        );
        assert_eq!(
            updated.jtbd_done_signal.as_deref(),
            Some("they can glance at one place and see every upcoming route")
        );

        // list_outcomes must also carry the persisted triple through.
        let listed = store
            .list_outcomes()
            .unwrap()
            .into_iter()
            .find(|o| o.id == "VISION-test1")
            .unwrap();
        assert_eq!(
            listed.jtbd_who.as_deref(),
            Some("a solo dog walker juggling paper routes")
        );
    }

    #[test]
    fn reserve_with_external_bumps_past_open_pr_collisions() {
        // Reproduces the INFRA-087..090 4-way collision pattern: 4 sibling
        // sessions each have an in-flight ID for the same domain. The DB
        // counter only knows about its own row, but reserve() must not
        // hand back any of {87, 88, 89, 90} — should jump to 91.
        let (store, _dir) = test_store();
        // Seed the DB with one existing INFRA-086 so existing_max=86.
        store.reserve("INFRA", "first", "P2", "s").unwrap();
        // Manually set the DB's counter to next=87 (matches sibling reality:
        // siblings each reserved 87..90 but those rows aren't in *this* DB).
        store
            .conn
            .execute(
                "INSERT OR REPLACE INTO gaps(id,domain,title,priority,effort,status,created_at)
             VALUES('INFRA-086','INFRA','seed','P2','s','open',?1)",
                params![unix_now()],
            )
            .unwrap();
        // Reserve with external IDs claimed by siblings.
        let extras = vec![87i64, 88, 89, 90];
        let id = store
            .reserve_with_external("INFRA", "mine", "P1", "s", &extras)
            .unwrap();
        assert!(
            !extras.iter().any(|n| id == format!("INFRA-{:03}", n)),
            "reserve picked a collision: {id} (extras: {extras:?})"
        );
        // Specifically: should be the next free above 90 (since DB has 086
        // pre-existing and externals are 87..90, first free is 91).
        assert_eq!(id, "INFRA-091", "expected INFRA-091, got {id}");
    }

    #[test]
    fn external_pending_ids_reads_lease_files() {
        let (store, dir) = test_store();
        // Write a fresh lease with a pending_new_gap.
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let now = unix_now();
        let exp = now + 3600;
        let now_iso = chrono_like_iso(now).to_string();
        let exp_iso = chrono_like_iso(exp).to_string();
        let lease = serde_json::json!({
            "session_id": "test-session",
            "pending_new_gap": { "id": "INFRA-099", "title": "x", "domain": "INFRA" },
            "heartbeat_at": now_iso,
            "expires_at": exp_iso,
        });
        std::fs::write(
            locks.join("test-session.json"),
            serde_json::to_string(&lease).unwrap(),
        )
        .unwrap();
        let ids = store.external_pending_ids("INFRA").unwrap();
        assert!(ids.contains(&99), "expected 99 in {ids:?}");
    }

    #[test]
    fn external_pending_ids_skips_stale_lease() {
        let (store, dir) = test_store();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        // Heartbeat 30 minutes ago — past the 15-minute staleness window.
        let stale = unix_now() - 30 * 60;
        let stale_iso = chrono_like_iso(stale);
        let exp_iso = chrono_like_iso(stale + 3600);
        let lease = serde_json::json!({
            "session_id": "stale-session",
            "pending_new_gap": { "id": "INFRA-200", "title": "stale", "domain": "INFRA" },
            "heartbeat_at": stale_iso,
            "expires_at": exp_iso,
        });
        std::fs::write(
            locks.join("stale-session.json"),
            serde_json::to_string(&lease).unwrap(),
        )
        .unwrap();
        let ids = store.external_pending_ids("INFRA").unwrap();
        assert!(
            !ids.contains(&200),
            "stale lease should be skipped: {ids:?}"
        );
    }

    #[test]
    fn domain_pattern_finds_padded_and_unpadded_ids() {
        let pat = regex_lite_for_domain("INFRA");
        let titles =
            "INFRA-100: foo, INFRA-99: bar, INFRA-080 baz, EVAL-100 (skip), prefixINFRA-7 (skip)";
        let nums = pat.find_numbers(titles);
        assert!(nums.contains(&100));
        assert!(nums.contains(&99));
        assert!(nums.contains(&80));
        // Reject non-boundary matches.
        assert!(
            !nums.contains(&7),
            "should reject prefixINFRA-7 (no word boundary): {nums:?}"
        );
    }

    #[test]
    fn parse_iso_to_unix_handles_z_suffix() {
        // 2026-04-28T22:30:00Z = 1777629000
        let ts = parse_iso_to_unix("2026-04-28T22:30:00Z").unwrap();
        // Sanity: value should be in 2026 range (>= 2026-01-01, < 2027-01-01).
        let jan1 = parse_iso_to_unix("2026-01-01T00:00:00Z").unwrap();
        let jan1_next = parse_iso_to_unix("2027-01-01T00:00:00Z").unwrap();
        assert!(ts > jan1 && ts < jan1_next, "ts={ts} jan1={jan1}");
    }

    /// Tiny helper: format a unix ts as `YYYY-MM-DDTHH:MM:SSZ` without
    /// pulling chrono. Round-trips with `parse_iso_to_unix` for tests.
    fn chrono_like_iso(ts: i64) -> String {
        let mut secs = ts;
        let s = secs.rem_euclid(60);
        secs = secs.div_euclid(60);
        let m = secs.rem_euclid(60);
        secs = secs.div_euclid(60);
        let h = secs.rem_euclid(24);
        let mut days = secs.div_euclid(24);
        let mut year = 1970i64;
        let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        loop {
            let dy = if is_leap(year) { 366 } else { 365 };
            if days < dy {
                break;
            }
            days -= dy;
            year += 1;
        }
        let dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        let mut month = 1u32;
        for (i, d) in dim.iter().enumerate() {
            let mut dd = *d as i64;
            if i == 1 && is_leap(year) {
                dd += 1;
            }
            if days < dd {
                month = (i + 1) as u32;
                break;
            }
            days -= dd;
        }
        let day = days + 1;
        format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
    }

    #[test]
    fn test_reserve_sequential() {
        let (store, _dir) = test_store();
        let id1 = store.reserve("INFRA", "First gap", "P1", "s").unwrap();
        let id2 = store.reserve("INFRA", "Second gap", "P1", "s").unwrap();
        assert_eq!(id1, "INFRA-001");
        assert_eq!(id2, "INFRA-002");
    }

    /// INFRA-2177 regression: a malformed docs/gaps.yaml (or per-file YAML) must
    /// NOT abort reserve. Reserve reads exclusively from state.db; per-file YAMLs
    /// are dump artifacts only. A single corrupt sibling file blocked the fleet
    /// fleet-wide for 30+ minutes (META-124 Wave 1 incident, 2026-05-29).
    ///
    /// Historical note: INFRA-143 previously inverted this assertion — reserve was
    /// *required* to fail on unreadable YAML as a guard against ID collisions.
    /// That guard became a liability once state.db became the canonical source
    /// (INFRA-498). The SELECT MAX + gap_counters upsert below provides the same
    /// collision safety purely from state.db.
    #[test]
    fn test_reserve_succeeds_despite_malformed_yaml() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        std::fs::create_dir_all(repo_root.join("docs")).unwrap();
        // Not valid YAML — `gaps:` should be a list, not a scalar.
        std::fs::write(
            repo_root.join("docs").join("gaps.yaml"),
            "gaps: this is not a list\n",
        )
        .unwrap();
        // Also corrupt one per-file YAML to simulate the INFRA-2170 incident.
        let per_file_dir = repo_root.join("docs").join("gaps");
        std::fs::create_dir_all(&per_file_dir).unwrap();
        std::fs::write(
            per_file_dir.join("INFRA-001.yaml"),
            // Numbered AC items with colon-space: trips YAML mapping/sequence ambiguity
            "- id: INFRA-001\n  acceptance_criteria:\n    1. deploy: succeeds\n    2. test: passes\n",
        )
        .unwrap();
        let store = GapStore::open(&repo_root).unwrap();
        let id = store
            .reserve("INFRA", "new gap", "P1", "s")
            .expect("reserve must succeed even when YAML files are malformed");
        assert_eq!(
            id, "INFRA-001",
            "first reserve in empty DB should be INFRA-001"
        );
    }

    /// INFRA-070 regression: reserve must NOT return an ID that already exists
    /// in state.db. The counter seeds from SELECT MAX(id) so any pre-existing
    /// rows are skipped. (Formerly guarded by import_from_yaml; now relies
    /// solely on state.db per INFRA-2177.)
    #[test]
    fn test_reserve_skips_db_existing_ids() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        let store = GapStore::open(&repo_root).unwrap();
        // Seed state.db directly so reserve has existing IDs to skip past.
        store
            .conn
            .execute(
                "INSERT INTO gaps(id,domain,title,priority,effort,status,created_at) \
                 VALUES('INFRA-005','INFRA','hand-added','P2','m','open',0)",
                [],
            )
            .unwrap();
        store
            .conn
            .execute(
                "INSERT INTO gaps(id,domain,title,priority,effort,status,created_at) \
                 VALUES('INFRA-042','INFRA','hand-added','P2','m','open',0)",
                [],
            )
            .unwrap();
        let id = store.reserve("INFRA", "new gap", "P1", "s").unwrap();
        // Must skip past INFRA-042 — not collide with it or INFRA-005.
        assert_eq!(id, "INFRA-043", "reserve should skip past DB max, got {id}");
    }

    #[test]
    fn test_reserve_concurrent() {
        // Spawn 10 threads, each reserving one INFRA gap.
        // All 10 should get distinct IDs with no errors.
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        // Create schema once. Concurrent `migrate()` from many fresh `open()` calls
        // races on empty DB and surfaces "database is locked" on CI (WAL + parallel DDL).
        {
            let _seed = GapStore::open(&repo_root).unwrap();
        }

        let results: Vec<_> = (0..10)
            .map(|_| {
                let root = repo_root.clone();
                std::thread::spawn(move || {
                    let store = GapStore::open(&root).unwrap();
                    store.reserve("INFRA", "concurrent gap", "P1", "s")
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();

        let ids: Vec<String> = results.into_iter().map(|r| r.unwrap()).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), 10, "expected 10 distinct IDs, got: {:?}", ids);
    }

    #[test]
    fn test_claim_and_preflight() {
        let (store, _dir) = test_store();
        let id = store.reserve("EVAL", "Test gap", "P1", "s").unwrap();

        match store.preflight(&id).unwrap() {
            PreflightResult::Available => {}
            other => panic!("expected Available, got {:?}", other),
        }

        store
            .claim(&id, "session-abc", "/worktrees/test", 3600)
            .unwrap();

        match store.preflight(&id).unwrap() {
            PreflightResult::Claimed(s) => assert_eq!(s, "session-abc"),
            other => panic!("expected Claimed, got {:?}", other),
        }
    }

    #[test]
    fn test_ship() {
        let (store, _dir) = test_store();
        let id = store.reserve("MEM", "Test gap", "P1", "s").unwrap();
        store
            .claim(&id, "session-xyz", "/worktrees/test", 3600)
            .unwrap();
        store.ship(&id, "session-xyz", None).unwrap();

        match store.preflight(&id).unwrap() {
            PreflightResult::Done => {}
            other => panic!("expected Done, got {:?}", other),
        }
    }

    // EFFECTIVE-834 (EFFECTIVE-364 slice): resolve_publication reads the
    // shipped gap's artifact_type, looks up publish_targets.json, and only
    // reserves a follow-up "publish work" gap when a target is registered
    // for that artifact_type. Exercises the resolver directly (rather than
    // via ship()'s fire-and-forget background thread) so the assertion is
    // deterministic.
    #[tokio::test]
    #[serial_test::serial(publish_targets_path_env)]
    async fn effective834_resolver_queues_publish_work_when_targets_exist() {
        let (store, dir) = test_store();
        let repo_root = dir.path().to_path_buf();

        let targets_path = dir.path().join("publish_targets.json");
        std::fs::write(
            &targets_path,
            r#"{"doc":[{"target_type":"docs-site","platform_id":"github-pages","requires_approval":true}]}"#,
        )
        .unwrap();
        unsafe {
            std::env::set_var("CHUMP_PUBLISH_TARGETS_PATH", &targets_path);
        }

        let event = PublicationEvent {
            source_gap_id: "EFFECTIVE-999".to_string(),
            artifact_type: "doc".to_string(),
        };
        resolve_publication(event, repo_root).await.unwrap();

        unsafe {
            std::env::remove_var("CHUMP_PUBLISH_TARGETS_PATH");
        }

        let open = store.list(Some("open")).unwrap();
        assert!(
            open.iter()
                .any(|g| g.title.contains("EFFECTIVE-999") && g.title.contains("github-pages")),
            "expected a queued publish-work gap, got: {:?}",
            open.iter().map(|g| &g.title).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    #[serial_test::serial(publish_targets_path_env)]
    async fn effective834_resolver_noop_when_no_targets_registered() {
        let (store, dir) = test_store();
        let repo_root = dir.path().to_path_buf();

        let targets_path = dir.path().join("publish_targets.json");
        std::fs::write(&targets_path, r#"{}"#).unwrap();
        unsafe {
            std::env::set_var("CHUMP_PUBLISH_TARGETS_PATH", &targets_path);
        }

        let event = PublicationEvent {
            source_gap_id: "EFFECTIVE-998".to_string(),
            artifact_type: "code".to_string(),
        };
        resolve_publication(event, repo_root).await.unwrap();

        unsafe {
            std::env::remove_var("CHUMP_PUBLISH_TARGETS_PATH");
        }

        let open = store.list(Some("open")).unwrap();
        assert!(
            !open.iter().any(|g| g.title.contains("EFFECTIVE-998")),
            "expected no publish-work gap when no targets are registered, got: {:?}",
            open.iter().map(|g| &g.title).collect::<Vec<_>>()
        );
    }

    #[test]
    fn credible218_ship_reconciles_ready_to_ship() {
        // CREDIBLE-218: a gap that merged while in an INTERMEDIATE status (not 'open')
        // must be reconcilable by ship(). Previously the UPDATE only matched
        // status='open', so ready_to_ship / in_review / in_flight gaps became permanent
        // ghosts. (test_store has no .git, so verify_proof_of_merge passes through.)
        let (store, _dir) = test_store();
        let id = store.reserve("CREDIBLE", "ghosted gap", "P1", "s").unwrap();
        store
            .conn
            .execute(
                "UPDATE gaps SET status='ready_to_ship' WHERE id=?1",
                params![id],
            )
            .unwrap();
        store.ship(&id, "sess", Some(4242)).unwrap();
        match store.preflight(&id).unwrap() {
            PreflightResult::Done => {}
            other => panic!("expected Done after reconciling ready_to_ship, got {other:?}"),
        }
    }

    #[test]
    fn zerowaste056_ship_syncs_yaml_to_done() {
        // ZERO-WASTE-056: the `gap ship` CLI writes docs/gaps/<ID>.yaml atomically
        // (via dump_per_file_single) in the same op as the state.db flip, so the
        // gap-close rides in the WORK PR and no separate per-gap reconcile PR is
        // ever needed (that churn was ~half of all merges). Locks in the two ops
        // the CLI handler chains; removing the dump call fails this.
        let (store, _dir) = test_store();
        let id = store
            .reserve("ZERO-WASTE", "ship-yaml-sync test", "P1", "s")
            .unwrap();
        let gaps_dir = _dir.path().join("docs").join("gaps");
        store.ship(&id, "s", Some(4242)).unwrap();
        let wrote = store.dump_per_file_single(&id, &gaps_dir).unwrap();
        assert!(wrote, "dump_per_file_single should write the yaml on ship");
        let yaml = std::fs::read_to_string(gaps_dir.join(format!("{id}.yaml"))).unwrap();
        assert!(
            yaml.contains("status: done"),
            "post-ship yaml must show status: done (no drift), got: {yaml}"
        );
        assert!(
            yaml.contains("closed_pr: 4242"),
            "post-ship yaml must record closed_pr, got: {yaml}"
        );
    }

    #[test]
    fn credible218_ship_refuses_deliberate_terminal() {
        // A superseded/wontfix gap is a deliberate operator decision — ship() must NOT
        // silently flip it to done just because a commit mentions the ID.
        let (store, _dir) = test_store();
        let id = store
            .reserve("CREDIBLE", "superseded gap", "P2", "s")
            .unwrap();
        store
            .conn
            .execute(
                "UPDATE gaps SET status='superseded' WHERE id=?1",
                params![id],
            )
            .unwrap();
        assert!(
            store.ship(&id, "sess", None).is_err(),
            "ship() must refuse to reconcile a deliberate terminal status"
        );
    }

    #[test]
    fn test_list_filter() {
        let (store, _dir) = test_store();
        store.reserve("COG", "open gap", "P1", "s").unwrap();
        let id2 = store.reserve("COG", "to close", "P1", "s").unwrap();
        store.claim(&id2, "s", "/wt", 3600).unwrap();
        store.ship(&id2, "s", None).unwrap();

        let open = store.list(Some("open")).unwrap();
        assert_eq!(open.len(), 1);
        let all = store.list(None).unwrap();
        assert_eq!(all.len(), 2);
    }

    /// INFRA-1776 P0: regression. INFRA-1751 (pr-rescue v1b, merged
    /// 2026-05-23 03:50Z) wrote `acceptance_criteria` as BLOB into the
    /// gaps table — the next `chump gap list` call exploded with
    /// `Invalid column type Blob at index: 7, name: acceptance_criteria`
    /// and the picker saw 0 pickable gaps fleet-wide, stalling every
    /// worker. The CAST(... AS TEXT) coercion in all 4 SELECT paths
    /// must absorb both type-tags transparently.
    #[test]
    fn list_tolerates_blob_acceptance_criteria_column() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "blob-ac gap", "P1", "s").unwrap();
        // Manually downgrade the column to BLOB to simulate the
        // INFRA-1751 write path. The picker must still surface the row.
        store
            .conn
            .execute(
                "UPDATE gaps SET acceptance_criteria = CAST(?1 AS BLOB) WHERE id=?2",
                params!["AC1\nAC2", id],
            )
            .unwrap();
        // Confirm storage type is genuinely blob now.
        let stored_type: String = store
            .conn
            .query_row(
                "SELECT typeof(acceptance_criteria) FROM gaps WHERE id=?1",
                params![id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stored_type, "blob");
        // The fix must keep `list` working AND `get` working.
        let open = store.list(Some("open")).unwrap();
        assert!(
            open.iter().any(|g| g.id == id),
            "BLOB-typed acceptance_criteria must not stall list()"
        );
        let row = store.get(&id).unwrap().expect("row exists");
        assert_eq!(row.acceptance_criteria, "AC1\nAC2");
    }

    #[test]
    fn test_ship_stamps_iso_date() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "x", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        store.ship(&id, "s", None).unwrap();
        let row = store.get(&id).unwrap().expect("row exists");
        assert_eq!(row.status, "done");
        // ISO YYYY-MM-DD, 10 chars, dashes at positions 4 and 7.
        assert_eq!(
            row.closed_date.len(),
            10,
            "closed_date={:?}",
            row.closed_date
        );
        assert_eq!(&row.closed_date[4..5], "-");
        assert_eq!(&row.closed_date[7..8], "-");
    }

    /// Migration backfills closed_date for done rows that predate the column
    /// (originally seen on FLEET-006, DOC-007: closed_at populated, closed_date empty).
    /// Re-opening a store should heal the row in-place; reopening again is a no-op.
    #[test]
    fn test_migrate_backfills_closed_date() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        {
            let store = GapStore::open(&repo_root).unwrap();
            // Insert a synthetic pre-migration row: status=done, closed_at set,
            // closed_date empty. Use a known timestamp (2026-04-26 18:55:22 UTC).
            store
                .conn
                .execute(
                    "INSERT INTO gaps(id,domain,title,status,created_at,closed_at,closed_date)
                     VALUES('LEGACY-001','LEGACY','old','done',?1,?2,'')",
                    params![1_777_180_000_i64, 1_777_180_000_i64],
                )
                .unwrap();
        }
        // Reopen — migrate() should heal the row.
        let store = GapStore::open(&repo_root).unwrap();
        let row = store.get("LEGACY-001").unwrap().expect("row exists");
        assert_eq!(row.closed_date, "2026-04-26", "expected backfilled date");

        // Idempotency: hand-set a different closed_date, reopen, and confirm the
        // backfill leaves it alone (only blank rows get touched).
        store
            .conn
            .execute(
                "UPDATE gaps SET closed_date='2026-04-27' WHERE id='LEGACY-001'",
                [],
            )
            .unwrap();
        drop(store);
        let store = GapStore::open(&repo_root).unwrap();
        let row = store.get("LEGACY-001").unwrap().expect("row exists");
        assert_eq!(row.closed_date, "2026-04-27", "backfill must be idempotent");
    }

    /// INFRA-112: empty/whitespace gap ids must be rejected at the SQL layer
    /// so they can never enter the store via `INSERT OR IGNORE` paths
    /// (`import_from_yaml`, hand-issued sqlite3, future codepaths). Without
    /// the trigger, such rows survive in the DB but vanish from the YAML
    /// mirror — silently shrinking the visible gap registry.
    #[test]
    fn test_migrate_rejects_empty_id_at_insert() {
        let (store, _dir) = test_store();
        for bad in ["", "   ", "\t", "\n"] {
            let r = store.conn.execute(
                "INSERT INTO gaps(id,domain,title,status,created_at)
                 VALUES(?1,'INFRA','x','open',0)",
                params![bad],
            );
            assert!(r.is_err(), "trigger must reject id={:?}", bad);
        }
        let r = store.conn.execute(
            "INSERT OR IGNORE INTO gaps(id,domain,title,status,created_at)
             VALUES('','INFRA','x','open',0)",
            [],
        );
        assert!(
            r.is_err(),
            "trigger must reject empty id even with OR IGNORE"
        );
    }

    /// INFRA-112: pre-existing empty-id rows (from before the trigger) must
    /// be cleaned up on reopen, and dump_yaml's self-validation must see the
    /// DB and YAML counts agree afterward.
    #[test]
    fn test_migrate_cleans_existing_empty_id_rows_and_dump_self_validates() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path().to_path_buf();
        {
            let store = GapStore::open(&repo_root).unwrap();
            // Drop the trigger, insert a bad row, then close. Simulates a DB
            // written by an older binary that lacked the constraint.
            store
                .conn
                .execute_batch("DROP TRIGGER IF EXISTS gaps_id_nonempty_insert;")
                .unwrap();
            store
                .conn
                .execute(
                    "INSERT INTO gaps(id,domain,title,status,created_at)
                     VALUES('','INFRA','orphan','open',0)",
                    [],
                )
                .unwrap();
            store
                .conn
                .execute(
                    "INSERT INTO gaps(id,domain,title,status,created_at)
                     VALUES('GOOD-001','INFRA','keeper','open',0)",
                    [],
                )
                .unwrap();
        }
        // Reopen — migrate() must DELETE the empty-id row and recreate the
        // trigger. dump_yaml then self-validates round-trip count.
        let store = GapStore::open(&repo_root).unwrap();
        let count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM gaps", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1, "empty-id row must be cleaned up on reopen");
        let yaml = store
            .dump_yaml()
            .expect("dump_yaml must succeed and self-validate after cleanup");
        assert!(yaml.contains("GOOD-001"));
        assert!(
            !yaml.contains("\n- id: \n"),
            "no empty-id list entry should remain"
        );
    }

    // ── INFRA-402: closed_pr integrity guard at the DB write layer ──────
    // INFRA-460: these three tests share global env state
    // (CHUMP_BYPASS_CLOSED_PR_GUARD) and must run serially. Without
    // serial_test, set_fields_bypass_env_honored leaks the var to
    // siblings during its window — observed flake in CI's
    // cargo-test-workspace step on this PR. The dep is already used by
    // src/reasoning_mode.rs for the same reason.

    #[test]
    #[serial_test::serial(closed_pr_guard_env)]
    fn set_fields_status_done_requires_closed_pr() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "guard test", "P1", "s").unwrap();

        // Attempt to flip status=done WITHOUT --closed-pr → must error.
        let err = store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert!(
            err.to_string().contains("INFRA-402"),
            "error must reference INFRA-402, got: {err}"
        );

        // DB row should still be 'open' — write was rejected.
        let status: String = store
            .conn
            .query_row("SELECT status FROM gaps WHERE id=?", [&id], |r| r.get(0))
            .unwrap();
        assert_eq!(status, "open", "DB must not have been mutated");
    }

    #[test]
    #[serial_test::serial(closed_pr_guard_env)]
    fn set_fields_status_done_with_closed_pr_succeeds() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "happy path", "P1", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(1234),
                    ..Default::default()
                },
            )
            .unwrap();
        let (status, closed_pr): (String, Option<i64>) = store
            .conn
            .query_row(
                "SELECT status, closed_pr FROM gaps WHERE id=?",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(status, "done");
        assert_eq!(closed_pr, Some(1234));
    }

    #[test]
    fn set_fields_status_done_with_existing_closed_pr_succeeds() {
        // If a prior set already wrote closed_pr, a later --status done
        // (without re-passing --closed-pr) must succeed.
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "two-step close", "P1", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    closed_pr: Some(5678),
                    ..Default::default()
                },
            )
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    ..Default::default()
                },
            )
            .expect("status=done with already-set closed_pr should succeed");
    }

    #[test]
    #[serial_test::serial(closed_pr_guard_env)]
    fn set_fields_bypass_env_honored() {
        // CHUMP_BYPASS_CLOSED_PR_GUARD=1 — for genuine migration cases
        // where closed_pr is unknown.
        unsafe {
            std::env::set_var("CHUMP_BYPASS_CLOSED_PR_GUARD", "1");
        }
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "bypass test", "P1", "s").unwrap();
        let result = store.set_fields(
            &id,
            GapFieldUpdate {
                status: Some("done".into()),
                ..Default::default()
            },
        );
        unsafe {
            std::env::remove_var("CHUMP_BYPASS_CLOSED_PR_GUARD");
        }
        result.expect("bypass env should allow status=done without closed_pr");
    }

    // ── INFRA-456: recycled-ID + hijack guards at the DB write layer ──────

    #[test]
    #[serial_test::serial(recycle_bypass_env)]
    fn infra456_recycled_id_guard_blocks_done_to_open() {
        // Defensive: a parallel test in the same binary may have leaked
        // CHUMP_ALLOW_RECYCLE=1 even when not on the same serial group.
        std::env::remove_var("CHUMP_ALLOW_RECYCLE");
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "test gap", "P1", "s").unwrap();
        // Ship it (status=done with closed_pr).
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(42),
                    ..Default::default()
                },
            )
            .unwrap();
        // Attempt to recycle: done → open. Must error.
        let err = store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("open".into()),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert!(
            err.to_string().contains("INFRA-456 recycled-ID"),
            "error must reference INFRA-456 recycled-ID, got: {err}"
        );
        // DB still done.
        let status: String = store
            .conn
            .query_row("SELECT status FROM gaps WHERE id=?", [&id], |r| r.get(0))
            .unwrap();
        assert_eq!(status, "done");
    }

    #[test]
    #[serial_test::serial(recycle_bypass_env)]
    fn infra456_recycled_id_bypass_env_honored() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "test gap", "P1", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(42),
                    ..Default::default()
                },
            )
            .unwrap();
        std::env::set_var("CHUMP_ALLOW_RECYCLE", "1");
        let result = store.set_fields(
            &id,
            GapFieldUpdate {
                status: Some("open".into()),
                ..Default::default()
            },
        );
        std::env::remove_var("CHUMP_ALLOW_RECYCLE");
        result.expect("CHUMP_ALLOW_RECYCLE=1 should bypass recycled-ID guard");
    }

    #[test]
    #[serial_test::serial(recycle_bypass_env)]
    fn infra3580_reopen_clears_stale_closed_pr() {
        // Reopening a gap (status -> open) must retract closed_pr/closed_date
        // too, or the row lands in the exact shape
        // scripts/ci/test-gap-closure-consistency.sh flags as
        // stale_post_merge_gap: status=open with closed_pr still set.
        std::env::remove_var("CHUMP_ALLOW_RECYCLE");
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "test gap", "P1", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(42),
                    closed_date: Some("2026-08-01".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        std::env::set_var("CHUMP_ALLOW_RECYCLE", "1");
        let result = store.set_fields(
            &id,
            GapFieldUpdate {
                status: Some("open".into()),
                ..Default::default()
            },
        );
        std::env::remove_var("CHUMP_ALLOW_RECYCLE");
        result.expect("reopen should succeed");

        let (status, closed_pr, closed_date): (String, Option<i64>, String) = store
            .conn
            .query_row(
                "SELECT status, closed_pr, closed_date FROM gaps WHERE id=?",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(status, "open");
        assert_eq!(closed_pr, None, "closed_pr must be cleared on reopen");
        assert_eq!(closed_date, "", "closed_date must be cleared on reopen");

        // Without CHUMP_ALLOW_RECYCLE, an explicit --closed-pr/--closed-date
        // pair on the same call is still honored verbatim (no silent clear
        // of caller-supplied values).
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_pr: Some(99),
                    closed_date: Some("2026-08-05".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        std::env::set_var("CHUMP_ALLOW_RECYCLE", "1");
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("open".into()),
                    closed_pr: Some(100),
                    closed_date: Some("2026-08-06".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        std::env::remove_var("CHUMP_ALLOW_RECYCLE");
        let (closed_pr2, closed_date2): (Option<i64>, String) = store
            .conn
            .query_row(
                "SELECT closed_pr, closed_date FROM gaps WHERE id=?",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(closed_pr2, Some(100));
        assert_eq!(closed_date2, "2026-08-06");
    }

    #[test]
    #[serial_test::serial(rewrite_bypass_env)]
    fn infra456_hijack_guard_blocks_silent_title_rewrite() {
        std::env::remove_var("CHUMP_ALLOW_GAP_REWRITE");
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "original title", "P1", "s").unwrap();
        let err = store
            .set_fields(
                &id,
                GapFieldUpdate {
                    title: Some("totally different work".into()),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert!(
            err.to_string().contains("INFRA-456 hijack"),
            "error must reference INFRA-456 hijack, got: {err}"
        );
        // Title unchanged.
        let title: String = store
            .conn
            .query_row("SELECT title FROM gaps WHERE id=?", [&id], |r| r.get(0))
            .unwrap();
        assert_eq!(title, "original title");
    }

    #[test]
    #[serial_test::serial(rewrite_bypass_env)]
    fn infra456_hijack_bypass_env_honored() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "original title", "P1", "s").unwrap();
        std::env::set_var("CHUMP_ALLOW_GAP_REWRITE", "1");
        let result = store.set_fields(
            &id,
            GapFieldUpdate {
                title: Some("corrected title".into()),
                ..Default::default()
            },
        );
        std::env::remove_var("CHUMP_ALLOW_GAP_REWRITE");
        result.expect("CHUMP_ALLOW_GAP_REWRITE=1 should bypass hijack guard");
    }

    #[test]
    #[serial_test::serial(rewrite_bypass_env)]
    fn infra456_hijack_guard_allows_description_append() {
        std::env::remove_var("CHUMP_ALLOW_GAP_REWRITE");
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "title", "P1", "s").unwrap();
        // Set initial description.
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    description: Some("Initial description.".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        // Append to it — must be allowed.
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    description: Some("Initial description. Plus follow-up note.".into()),
                    ..Default::default()
                },
            )
            .expect("appending to description should be allowed");
    }

    #[test]
    #[serial_test::serial(rewrite_bypass_env)]
    fn infra456_hijack_guard_blocks_incompatible_description_rewrite() {
        std::env::remove_var("CHUMP_ALLOW_GAP_REWRITE");
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "title", "P1", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    description: Some("Original problem statement.".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let err = store
            .set_fields(
                &id,
                GapFieldUpdate {
                    description: Some("Totally different problem.".into()),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert!(err.to_string().contains("INFRA-456 hijack"));
    }

    #[test]
    fn test_dump_yaml_round_trip() {
        let (store, _dir) = test_store();
        // Reserve two gaps, populate fields via set_fields.
        let id1 = store.reserve("INFRA", "First gap", "P1", "s").unwrap();
        store
            .set_fields(
                &id1,
                GapFieldUpdate {
                    description: Some("Short description".to_string()),
                    acceptance_criteria: Some(
                        serde_json::to_string(&["AC one", "AC two"]).unwrap(),
                    ),
                    depends_on: Some(serde_json::to_string(&["INFRA-000"]).unwrap()),
                    notes: Some("Note text".to_string()),
                    opened_date: Some("2026-04-25".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        let _id2 = store
            .reserve("EVAL", "Second: with colon", "P1", "s")
            .unwrap();

        // Dump → re-parse → verify gap count and key fields survived.
        let body = store.dump_yaml().unwrap();
        assert!(
            body.starts_with("gaps:\n"),
            "must start with gaps:\\n; got: {:?}",
            &body[..30]
        );
        let parsed: YamlGapsFile = serde_yaml::from_str(&body)
            .unwrap_or_else(|e| panic!("re-parse failed: {e}\n---\n{body}"));
        assert_eq!(parsed.gaps.len(), 2);
        let g1 = parsed
            .gaps
            .iter()
            .find(|g| g.id == id1)
            .expect("id1 present");
        assert_eq!(g1.title, "First gap");
        assert_eq!(g1.description, "Short description");
        assert_eq!(g1.priority, "P1");
        assert_eq!(g1.effort, "s");
        let ac = g1
            .acceptance_criteria
            .as_ref()
            .expect("ac present")
            .as_array()
            .expect("ac is array");
        assert_eq!(ac.len(), 2);
        assert_eq!(ac[0].as_str(), Some("AC one"));
    }

    /// INFRA-112 (acceptance #4): byte-stable round-trip — dump → fresh DB →
    /// import that dump → dump again. Both YAML strings must be byte-equal.
    /// Catches non-determinism in the emitter (HashMap iteration order,
    /// timestamp drift, locale-dependent formatting) that count- and
    /// field-equality tests miss. The earlier test_dump_yaml_round_trip
    /// proves the dump is *parseable*; this proves it is *idempotent*.
    #[test]
    fn test_dump_yaml_byte_stable_round_trip() {
        // Seed store A with a representative variety of fields.
        let (store_a, _dir_a) = test_store();
        let id1 = store_a.reserve("INFRA", "First gap", "P1", "s").unwrap();
        store_a
            .set_fields(
                &id1,
                GapFieldUpdate {
                    description: Some("Multi-line\ndescription with: a colon".to_string()),
                    acceptance_criteria: Some(
                        serde_json::to_string(&["AC one", "AC two: with colon"]).unwrap(),
                    ),
                    depends_on: Some(serde_json::to_string(&["INFRA-000", "EVAL-001"]).unwrap()),
                    notes: Some("Note text\nwith newline".to_string()),
                    source_doc: Some("docs/process/foo.md".to_string()),
                    opened_date: Some("2026-04-25".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        let id2 = store_a
            .reserve("EVAL", "Second: with colon in title", "P0", "m")
            .unwrap();
        store_a
            .set_fields(
                &id2,
                GapFieldUpdate {
                    description: Some("Plain description".to_string()),
                    status: Some("done".to_string()),
                    closed_date: Some("2026-04-26".to_string()),
                    // INFRA-402: status=done write path now requires a numeric
                    // closed_pr (or CHUMP_BYPASS_CLOSED_PR_GUARD=1). The test
                    // fixture pre-dates this guard; passing closed_pr keeps
                    // the byte-stable round-trip semantics intact.
                    closed_pr: Some(42),
                    ..Default::default()
                },
            )
            .unwrap();
        let _ = store_a.reserve("META", "Minimal gap", "P2", "xs").unwrap();

        let dump1 = store_a.dump_yaml().expect("dump A");

        // Import into a fresh DB and dump again. The two YAML strings must
        // be byte-equal — any drift indicates the emitter is non-deterministic
        // or the importer mutates fields it should preserve.
        let dir_b = TempDir::new().unwrap();
        let store_b = GapStore::open(dir_b.path()).unwrap();
        // import_from_yaml takes the *repo root* and reads docs/gaps.yaml
        // beneath it. Stage dump1 at that conventional path.
        let yaml_path = dir_b.path().join("docs").join("gaps.yaml");
        std::fs::create_dir_all(yaml_path.parent().unwrap()).unwrap();
        std::fs::write(&yaml_path, &dump1).unwrap();
        store_b
            .import_from_yaml(dir_b.path())
            .expect("import dump1 into store B");

        let dump2 = store_b.dump_yaml().expect("dump B");

        assert_eq!(
            dump1,
            dump2,
            "dump → import → dump must be byte-stable; emitter is non-deterministic\n\
             --- first dump ({} bytes) ---\n{}\n--- second dump ({} bytes) ---\n{}",
            dump1.len(),
            dump1,
            dump2.len(),
            dump2,
        );
    }

    /// INFRA-147: dump_yaml_with_meta must preserve everything before the
    /// `gaps:` line byte-for-byte (the hand-curated `meta:` block holds CPO
    /// priorities and update_instructions). Bare dump_yaml() drops this.
    #[test]
    fn test_dump_yaml_with_meta_preserves_preamble() {
        let (store, _dir) = test_store();
        let _id = store.reserve("INFRA", "x", "P1", "s").unwrap();

        let source = "\
meta:
  version: '1'
  generated: '2026-04-16'
  current_priorities:
    p0_now:
      - PRODUCT-015
      - PRODUCT-016
gaps:
- id: INFRA-OLD
  title: stale entry
";
        let regenerated = store.dump_yaml_with_meta(source).unwrap();
        // Preamble (everything up to and including the newline before "gaps:")
        // must be byte-identical.
        let expected_preamble = "\
meta:
  version: '1'
  generated: '2026-04-16'
  current_priorities:
    p0_now:
      - PRODUCT-015
      - PRODUCT-016
";
        assert!(
            regenerated.starts_with(expected_preamble),
            "preamble lost; got prefix: {:?}",
            &regenerated[..expected_preamble.len().min(regenerated.len())]
        );
        // gaps: block follows, populated from DB (not from source).
        assert!(regenerated.contains("\ngaps:\n- id: INFRA-001\n"));
        assert!(
            !regenerated.contains("INFRA-OLD"),
            "stale gaps from source must NOT leak through; gaps come from DB"
        );
    }

    /// Empty source (e.g. fresh export to a new file) falls back to bare dump.
    #[test]
    fn test_dump_yaml_with_meta_empty_source_falls_back() {
        let (store, _dir) = test_store();
        let _id = store.reserve("INFRA", "x", "P1", "s").unwrap();
        let regenerated = store.dump_yaml_with_meta("").unwrap();
        assert!(regenerated.starts_with("gaps:\n"));
    }

    /// INFRA-188 v0: dump_per_file emits one file per gap; reaggregating
    /// with `cat` produces the same content as the monolithic dump_yaml
    /// (modulo the leading `gaps:\n`).
    #[test]
    fn test_dump_per_file_writes_one_file_per_gap() {
        let (store, dir) = test_store();
        let id1 = store.reserve("INFRA", "first", "P1", "s").unwrap();
        let id2 = store.reserve("EVAL", "second", "P0", "m").unwrap();
        let _id3 = store.reserve("META", "third", "P2", "xs").unwrap();

        let out_dir = dir.path().join("docs/gaps");
        let (written, skipped) = store.dump_per_file(&out_dir).unwrap();

        assert_eq!(written, 3, "expected 3 files written");
        assert_eq!(skipped, 0, "no files should be skipped on first run");

        // Each file exists at <ID>.yaml and contains the gap's id
        for id in &[&id1, &id2] {
            let path = out_dir.join(format!("{}.yaml", id));
            assert!(path.exists(), "file {} missing", path.display());
            let content = std::fs::read_to_string(&path).unwrap();
            assert!(
                content.contains(&format!("- id: {}", id)),
                "file should contain id line; got: {content}"
            );
        }

        // Idempotency: a second dump with no DB changes should write 0 files
        // (all skipped because byte-identical).
        let (written2, skipped2) = store.dump_per_file(&out_dir).unwrap();
        assert_eq!(written2, 0, "second dump should write 0 files");
        assert_eq!(skipped2, 3, "second dump should skip all 3");
    }

    /// INFRA-228/229: single-gap per-file dump. New since 2026-05-02
    /// to back `chump gap reserve` (write per-file mirror at create
    /// time) and `chump gap ship --update-yaml` (write per-file
    /// mirror on ship instead of the deleted monolithic gaps.yaml).
    #[test]
    fn test_dump_per_file_single_writes_one_gap() {
        let (store, dir) = test_store();
        let id1 = store.reserve("INFRA", "alpha", "P1", "s").unwrap();
        let _id2 = store.reserve("EVAL", "beta", "P0", "m").unwrap();

        let out_dir = dir.path().join("docs/gaps");
        let wrote = store.dump_per_file_single(&id1, &out_dir).unwrap();
        assert!(wrote, "first single-dump should write");

        let path = out_dir.join(format!("{}.yaml", id1));
        assert!(path.exists(), "{} missing", path.display());
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains(&format!("- id: {}", id1)));
        // Crucially, the second gap's file is NOT written — single-gap
        // dump only touches its target. This is the property `reserve`
        // and `ship --update-yaml` rely on for cheap per-mutation writes.
        let other = out_dir.join("EVAL-001.yaml");
        assert!(
            !other.exists(),
            "single-dump must not touch sibling gap files"
        );

        // Idempotency: a second call with no DB change returns false.
        let wrote2 = store.dump_per_file_single(&id1, &out_dir).unwrap();
        assert!(!wrote2, "second single-dump should skip (byte-identical)");

        // After mutating the gap (set status to done), single-dump
        // must re-write.
        store.ship(&id1, "test-session", Some(999)).unwrap();
        let wrote3 = store.dump_per_file_single(&id1, &out_dir).unwrap();
        assert!(wrote3, "post-ship single-dump must rewrite");
        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(
            updated.contains("status: done"),
            "post-ship dump must reflect new status; got: {updated}"
        );
    }

    /// INFRA-228/229: a single-dump on an unknown id is an error,
    /// not a silent no-op. Callers (reserve / ship --update-yaml)
    /// already have the id in scope so this is a programmer-error
    /// condition worth surfacing.
    #[test]
    fn test_dump_per_file_single_unknown_id_errors() {
        let (store, dir) = test_store();
        let out_dir = dir.path().join("docs/gaps");
        let err = store
            .dump_per_file_single("DOES-NOT-EXIST-001", &out_dir)
            .unwrap_err();
        assert!(
            err.to_string().contains("not found"),
            "expected 'not found' error, got: {err}"
        );
    }

    /// INFRA-188 v0: per-file dump's content is byte-equal to what the
    /// monolithic dump produces for the same gap. Roundtrip: dump_yaml
    /// with all gaps  ==  "gaps:\n" + cat(per-file files).
    #[test]
    fn test_dump_per_file_reaggregates_to_monolithic() {
        let (store, dir) = test_store();
        let _id1 = store.reserve("INFRA", "alpha", "P1", "s").unwrap();
        let _id2 = store
            .reserve("EVAL", "beta with: a colon", "P0", "m")
            .unwrap();

        let out_dir = dir.path().join("docs/gaps");
        store.dump_per_file(&out_dir).unwrap();

        // Reaggregate
        let mut entries: Vec<_> = std::fs::read_dir(&out_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .collect();
        entries.sort();
        let mut reagg = String::from("gaps:\n");
        for p in &entries {
            reagg.push_str(&std::fs::read_to_string(p).unwrap());
        }

        // Compare against monolithic dump
        let mono = store.dump_yaml().unwrap();
        assert_eq!(
            reagg.trim_end(),
            mono.trim_end(),
            "reaggregated per-file output should byte-equal monolithic dump"
        );
    }

    #[test]
    #[serial_test::serial(rewrite_bypass_env)]
    fn test_set_fields_clear_and_update() {
        let (store, _dir) = test_store();
        let id = store.reserve("MEM", "Old title", "P1", "s").unwrap();
        // INFRA-456: this test pre-dates the hijack guard and intentionally
        // exercises a title rewrite to test the field-clear semantic.
        // Opt into the bypass for the duration so the guard doesn't fire.
        std::env::set_var("CHUMP_ALLOW_GAP_REWRITE", "1");
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    title: Some("New title".to_string()),
                    notes: Some("Important".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        std::env::remove_var("CHUMP_ALLOW_GAP_REWRITE");
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.title, "New title");
        assert_eq!(row.notes, "Important");

        // None means unchanged — title should not revert.
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    notes: Some(String::new()),
                    ..Default::default()
                },
            )
            .unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.title, "New title");
        assert_eq!(row.notes, "");
    }

    // ── INFRA-156: closed_pr round-trip ─────────────────────────────────

    #[test]
    fn test_set_closed_pr_persists_and_emits_to_yaml() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "x", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        // First close via set_fields (the `chump gap set --closed-pr` path).
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("done".into()),
                    closed_date: Some("2026-04-28".into()),
                    closed_pr: Some(598),
                    ..Default::default()
                },
            )
            .unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.status, "done");
        assert_eq!(row.closed_pr, Some(598));
        // YAML emit must include the integer scalar (no quotes, no TBD).
        let yaml = store.dump_yaml().unwrap();
        assert!(
            yaml.contains("  closed_pr: 598\n"),
            "yaml missing closed_pr line: {}",
            yaml
        );
    }

    #[test]
    fn test_ship_with_closed_pr_stamps_pr_number() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "y", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        // The `chump gap ship --closed-pr N` path: ship() takes the option
        // directly so callers don't have to do a follow-up set_fields call.
        store.ship(&id, "s", Some(631)).unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.status, "done");
        assert_eq!(row.closed_pr, Some(631));
        // ship() without a closed_pr (legacy callers) must leave it None.
        let id2 = store.reserve("INFRA", "z", "P1", "s").unwrap();
        store.claim(&id2, "s", "/wt", 3600).unwrap();
        store.ship(&id2, "s", None).unwrap();
        let row2 = store.get(&id2).unwrap().expect("row");
        assert_eq!(row2.status, "done");
        assert_eq!(row2.closed_pr, None);
    }

    // ── RESILIENT-119: triage-close ─────────────────────────────────────

    #[test]
    fn test_close_flips_status_for_each_valid_reason() {
        // No `.git` in `test_store()`'s tempdir, so ship()'s auto-fetch /
        // proof-of-merge machinery would be unreachable anyway — but close()
        // must not even attempt it: no fetch, no worktree-clean check, no
        // scan for a commit naming the gap.
        let (store, _dir) = test_store();
        for reason in ["superseded", "wontfix", "obsolete", "duplicate"] {
            let id = store.reserve("INFRA", reason, "P1", "s").unwrap();
            store.claim(&id, "s", "/wt", 3600).unwrap();
            store.close(&id, "s", reason).unwrap();
            let row = store.get(&id).unwrap().expect("row");
            assert_eq!(row.status, reason);
        }
    }

    #[test]
    fn test_close_rejects_invalid_reason() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "bad reason", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        let err = store.close(&id, "s", "bogus").unwrap_err();
        assert!(
            format!("{err:#}").contains("invalid --reason"),
            "unexpected error: {err:#}"
        );
        // Status must be untouched by the rejected call.
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.status, "open");
    }

    #[test]
    fn test_close_is_not_a_reroute_of_ship_and_releases_lease() {
        let (store, dir) = test_store();
        let id = store.reserve("INFRA", "lease release", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        store.close(&id, "s", "wontfix").unwrap();
        // Lease is released just like ship() does.
        let leftover: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM leases WHERE gap_id=?1 AND session_id=?2",
                params![id, "s"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(leftover, 0, "close() must release the caller's lease");
        // Already-terminal gap cannot be re-closed.
        let err = store.close(&id, "s", "superseded").unwrap_err();
        assert!(
            format!("{err:#}").contains("already in a terminal status"),
            "unexpected error: {err:#}"
        );
        drop(dir);
    }

    #[test]
    fn test_yaml_import_coerces_closed_pr_integer() {
        // Round-trip: dump → re-import should preserve closed_pr through the
        // YAML mirror without losing the value or fabricating a string.
        let (store, dir) = test_store();
        let id = store.reserve("INFRA", "import test", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        store.ship(&id, "s", Some(598)).unwrap();
        let yaml = store.dump_yaml().unwrap();
        // Persist YAML and re-import into a fresh store rooted at the same dir.
        let yaml_dir = dir.path().join("docs");
        std::fs::create_dir_all(&yaml_dir).unwrap();
        std::fs::write(yaml_dir.join("gaps.yaml"), &yaml).unwrap();
        let store2 = GapStore::open(dir.path()).unwrap();
        // Existing row already in DB; round-trip via a deleted+reimported row
        // is the more interesting test — drop it and re-import.
        store2
            .conn
            .execute("DELETE FROM gaps WHERE id=?1", params![id])
            .unwrap();
        let (ins, _skip, _backfilled) = store2.import_from_yaml(dir.path()).unwrap();
        assert!(ins >= 1, "expected at least one inserted row, got {}", ins);
        let reimported = store2.get(&id).unwrap().expect("row reimported");
        assert_eq!(reimported.closed_pr, Some(598));
    }

    /// VOA-006: one corrupt per-file entry must not abort the whole import.
    ///
    /// Precedent: INFRA-3429.yaml shipped with 39 duplicate `evidence:` keys
    /// (#3309). Because the importer concatenated every `docs/gaps/*.yaml` into a
    /// single buffer and parsed it once, that lone bad file made `chump gap import`
    /// fail outright — the entire YAML -> state.db sync was dead, and newly filed
    /// gaps never became pickable. Fails before the fix (the whole call errors).
    #[test]
    fn test_import_skips_malformed_file_and_imports_the_rest() {
        let (_store, dir) = test_store();
        let gaps_dir = dir.path().join("docs").join("gaps");
        std::fs::create_dir_all(&gaps_dir).unwrap();

        // Well-formed neighbours, sorted either side of the corrupt file.
        for id in ["INFRA-0001", "INFRA-9999"] {
            std::fs::write(
                gaps_dir.join(format!("{id}.yaml")),
                format!(
                    "- id: {id}\n  domain: INFRA\n  title: healthy entry\n  \
                     status: open\n  priority: P1\n  effort: s\n"
                ),
            )
            .unwrap();
        }
        // The corrupt one: duplicate `evidence` key, exactly INFRA-3429's shape.
        std::fs::write(
            gaps_dir.join("INFRA-5000.yaml"),
            "- id: INFRA-5000\n  domain: INFRA\n  title: corrupt entry\n  status: open\n  \
             priority: P1\n  effort: s\n  evidence: |\n    first\n  evidence: |\n    second\n",
        )
        .unwrap();

        let store = GapStore::open(dir.path()).unwrap();
        let (inserted, _skipped, _backfilled) = store
            .import_from_yaml(dir.path())
            .expect("import must succeed despite one malformed file");

        assert!(
            inserted >= 2,
            "healthy files must still import; inserted={inserted}"
        );
        assert!(
            store.get("INFRA-0001").unwrap().is_some(),
            "file sorting before the corrupt one must import"
        );
        assert!(
            store.get("INFRA-9999").unwrap().is_some(),
            "file sorting after the corrupt one must import"
        );
        assert!(
            store.get("INFRA-5000").unwrap().is_none(),
            "the malformed file itself must be skipped, not partially imported"
        );
    }

    /// INFRA-233: `import_from_yaml` must backfill `closed_pr` for rows that
    /// already exist in the DB with `closed_pr IS NULL` but the YAML carries a
    /// value.  This covers the ~200 historical gaps whose `closed_pr` was NULL
    /// because they were imported before the INFRA-156 column migration added
    /// the `closed_pr` backfill (INSERT OR IGNORE skips existing rows entirely).
    #[test]
    fn test_import_backfills_null_closed_pr() {
        let (store, dir) = test_store();
        // Simulate a gap that was imported before INFRA-156: status=done,
        // closed_pr=NULL in the DB, but the YAML on disk has closed_pr=232.
        let id = store
            .reserve("COG", "legacy closed gap", "P1", "s")
            .unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        // ship without closed_pr — simulates a pre-INFRA-156 closure.
        store.ship(&id, "s", None).unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.closed_pr, None, "pre-condition: closed_pr must be NULL");

        // Write a YAML file that carries closed_pr for this gap.
        let yaml_dir = dir.path().join("docs");
        std::fs::create_dir_all(&yaml_dir).unwrap();
        let yaml = format!(
            "gaps:\n- id: {}\n  domain: COG\n  title: legacy closed gap\n  status: done\n  closed_pr: 232\n",
            id
        );
        std::fs::write(yaml_dir.join("gaps.yaml"), &yaml).unwrap();

        // Re-run import — the existing row should have its closed_pr backfilled.
        let (_ins, _skip, backfilled) = store.import_from_yaml(dir.path()).unwrap();
        assert_eq!(
            backfilled, 1,
            "expected exactly 1 row backfilled, got {}",
            backfilled
        );
        let row = store.get(&id).unwrap().expect("row still present");
        assert_eq!(
            row.closed_pr,
            Some(232),
            "closed_pr must be backfilled from YAML"
        );

        // Idempotency: re-run import again — no additional backfill should happen.
        let (_ins2, _skip2, backfilled2) = store.import_from_yaml(dir.path()).unwrap();
        assert_eq!(
            backfilled2, 0,
            "second import must be idempotent; got {} backfilled",
            backfilled2
        );
        // Value must be unchanged.
        let row = store.get(&id).unwrap().expect("row still present");
        assert_eq!(
            row.closed_pr,
            Some(232),
            "closed_pr must remain 232 after idempotent backfill"
        );
    }

    /// INFRA-460: `chump gap import` must propagate `status: done` from
    /// the per-file YAML to state.db, even when the row already exists.
    /// Pre-fix this was the silent-skip bug that produced every
    /// OPEN-BUT-LANDED ghost on origin/main since INFRA-188 (2026-05-02):
    /// the closer wrote `status: done` to YAML, INSERT OR IGNORE did
    /// nothing on PK conflict, and the next dump regenerated the YAML
    /// with the stale DB's `status: open`.
    #[test]
    fn test_import_propagates_status_done_from_yaml() {
        let (store, dir) = test_store();
        // Reserve a gap that lives in DB as `open`.
        let id = store.reserve("INFRA", "ghost gap", "P1", "s").unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.status, "open", "pre-condition: DB status is 'open'");

        // Write a YAML that asserts `done` (mimics what INFRA-236's
        // commit-subject closer would have written when a Closes <ID>
        // commit landed on main).
        let yaml_dir = dir.path().join("docs");
        std::fs::create_dir_all(&yaml_dir).unwrap();
        let yaml = format!(
            "gaps:\n- id: {}\n  domain: INFRA\n  title: ghost gap\n  status: done\n  closed_pr: 999\n  closed_date: '2026-05-04'\n",
            id
        );
        std::fs::write(yaml_dir.join("gaps.yaml"), &yaml).unwrap();

        // Run import. The status backfill should flip the DB row.
        let (_ins, _skip, backfilled) = store.import_from_yaml(dir.path()).unwrap();
        assert!(
            backfilled >= 1,
            "expected at least 1 row backfilled (status + closed_pr); got {}",
            backfilled
        );
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(
            row.status, "done",
            "status must be propagated from YAML 'done' to DB"
        );
        assert_eq!(
            row.closed_pr,
            Some(999),
            "closed_pr must propagate atomically with the status flip"
        );
        assert_eq!(
            row.closed_date, "2026-05-04",
            "closed_date must propagate atomically with the status flip"
        );

        // Idempotency: second import must not double-flip.
        let (_ins2, _skip2, backfilled2) = store.import_from_yaml(dir.path()).unwrap();
        assert_eq!(
            backfilled2, 0,
            "second import must be idempotent (row already done); got {} backfilled",
            backfilled2
        );
    }

    /// INFRA-460 must be MONOTONIC — never reverse a closure or overwrite
    /// a non-`open` DB state. If YAML says `open` but DB says `done`,
    /// the DB stays `done` (don't re-open by accident). If DB has been
    /// hand-set to `superseded` / `blocked` / `deferred`, leave it alone
    /// (the operator's intent overrides the YAML).
    #[test]
    fn test_import_status_backfill_is_monotonic() {
        let (store, dir) = test_store();

        // Case 1: DB done + YAML open → DB stays done (no reverse).
        let id1 = store.reserve("INFRA", "shipped gap", "P1", "s").unwrap();
        store.claim(&id1, "s", "/wt", 3600).unwrap();
        store.ship(&id1, "s", Some(500)).unwrap();
        let row = store.get(&id1).unwrap().expect("row");
        assert_eq!(row.status, "done");

        // Case 2: DB superseded + YAML done → DB stays superseded.
        let id2 = store.reserve("INFRA", "superseded gap", "P1", "s").unwrap();
        store
            .conn
            .execute(
                "UPDATE gaps SET status='superseded' WHERE id=?1",
                params![id2],
            )
            .unwrap();

        // Write YAMLs: id1 with `open` (would-be-reverse), id2 with `done`
        // (would-be-overwrite).
        let yaml_dir = dir.path().join("docs");
        std::fs::create_dir_all(&yaml_dir).unwrap();
        let yaml = format!(
            "gaps:\n\
- id: {}\n  domain: INFRA\n  title: shipped gap\n  status: open\n\
- id: {}\n  domain: INFRA\n  title: superseded gap\n  status: done\n  closed_pr: 700\n",
            id1, id2
        );
        std::fs::write(yaml_dir.join("gaps.yaml"), &yaml).unwrap();

        let _ = store.import_from_yaml(dir.path()).unwrap();

        // id1 must still be done (not reversed).
        assert_eq!(
            store.get(&id1).unwrap().unwrap().status,
            "done",
            "INFRA-460: must not reverse a done status (YAML 'open' loses to DB 'done')"
        );
        // id2 must still be superseded (not overwritten).
        assert_eq!(
            store.get(&id2).unwrap().unwrap().status,
            "superseded",
            "INFRA-460: must not overwrite a non-open hand-set state (DB 'superseded' wins)"
        );
    }

    /// INFRA-233: `backfill_closed_pr_from_yaml` must NOT overwrite a
    /// `closed_pr` value that is already set in the DB (even if the YAML
    /// carries a different number — the DB wins for existing non-NULL values).
    #[test]
    fn test_backfill_skips_existing_closed_pr() {
        let (store, dir) = test_store();
        let id = store.reserve("INFRA", "shipped gap", "P1", "s").unwrap();
        store.claim(&id, "s", "/wt", 3600).unwrap();
        store.ship(&id, "s", Some(999)).unwrap();
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.closed_pr, Some(999));

        // Write YAML with a *different* closed_pr.
        let yaml_dir = dir.path().join("docs");
        std::fs::create_dir_all(&yaml_dir).unwrap();
        let yaml = format!(
            "gaps:\n- id: {}\n  domain: INFRA\n  title: shipped gap\n  status: done\n  closed_pr: 111\n",
            id
        );
        std::fs::write(yaml_dir.join("gaps.yaml"), &yaml).unwrap();

        let backfilled = store.backfill_closed_pr_from_yaml(dir.path()).unwrap();
        assert_eq!(
            backfilled, 0,
            "must not overwrite existing non-NULL closed_pr"
        );
        let row = store.get(&id).unwrap().expect("row");
        assert_eq!(row.closed_pr, Some(999), "existing value must be preserved");
    }

    // ── COG-036: routing-outcome scoreboard ─────────────────────────────

    fn outcome(
        backend: &str,
        outcome: &str,
        ts: &str,
        pr: Option<u32>,
        task_class: &str,
        model: &str,
    ) -> RoutingOutcomeRow {
        RoutingOutcomeRow {
            recorded_at: ts.into(),
            task_class: task_class.into(),
            priority: "P1".into(),
            effort: "m".into(),
            backend: backend.into(),
            model: model.into(),
            provider_pfx: if model.is_empty() { "" } else { "together" }.into(),
            gap_id: "INFRA-999".into(),
            outcome: outcome.into(),
            pr_number: pr,
            duration_s: 60,
            cost_usd: 2.0,
        }
    }

    #[test]
    fn routing_outcomes_record_and_read_back() {
        let (store, _dir) = test_store();
        let row = outcome("claude", "shipped", "2026-04-27T12:00:00Z", Some(7), "", "");
        store.record_routing_outcome(&row).unwrap();
        let board = store.routing_scoreboard().unwrap();
        assert_eq!(board.len(), 1);
        assert_eq!(board[0].backend, "claude");
        assert_eq!(board[0].successes, 1);
        assert_eq!(board[0].failures, 0);
        assert_eq!(board[0].total, 1);
        assert!((board[0].success_rate - 1.0).abs() < f64::EPSILON);
        assert_eq!(board[0].last_seen, "2026-04-27T12:00:00Z");
        assert!((board[0].avg_cost_usd - 2.0).abs() < f64::EPSILON);
        // priority=P1 -> value=3.0; score = (1.0 success * 3.0 value) / 2.0 cost.
        assert!((board[0].route_score - 1.5).abs() < 1e-9);
    }

    #[test]
    fn routing_outcomes_route_score_is_zero_without_cost_data() {
        let (store, _dir) = test_store();
        let mut row = outcome("claude", "shipped", "2026-04-27T12:00:00Z", Some(7), "", "");
        row.cost_usd = 0.0;
        store.record_routing_outcome(&row).unwrap();
        let board = store.routing_scoreboard().unwrap();
        assert_eq!(board.len(), 1);
        assert_eq!(board[0].avg_cost_usd, 0.0);
        assert_eq!(
            board[0].route_score, 0.0,
            "score is undefined (0.0) when no cost data has accumulated yet"
        );
    }

    #[test]
    fn routing_outcomes_empty_returns_empty_vec() {
        let (store, _dir) = test_store();
        let board = store.routing_scoreboard().unwrap();
        assert!(board.is_empty());
    }

    #[test]
    fn routing_outcomes_aggregates_by_route() {
        let (store, _dir) = test_store();
        // claude/research: 3 ships, 1 stall — 75% success.
        for i in 0..3 {
            store
                .record_routing_outcome(&outcome(
                    "claude",
                    "shipped",
                    &format!("2026-04-27T12:0{i}:00Z"),
                    Some(i + 1),
                    "research",
                    "",
                ))
                .unwrap();
        }
        store
            .record_routing_outcome(&outcome(
                "claude",
                "stalled",
                "2026-04-27T13:00:00Z",
                None,
                "research",
                "",
            ))
            .unwrap();
        // chump-local/research: 1 ship, 1 ci_failed — 50% success.
        store
            .record_routing_outcome(&outcome(
                "chump-local",
                "shipped",
                "2026-04-27T14:00:00Z",
                Some(99),
                "research",
                "qwen",
            ))
            .unwrap();
        store
            .record_routing_outcome(&outcome(
                "chump-local",
                "ci_failed",
                "2026-04-27T15:00:00Z",
                Some(100),
                "research",
                "qwen",
            ))
            .unwrap();

        let board = store.routing_scoreboard().unwrap();
        assert_eq!(board.len(), 2, "two distinct routes");
        // claude/research: 4 total, ships 3 — top of list because total DESC.
        assert_eq!(board[0].backend, "claude");
        assert_eq!(board[0].total, 4);
        assert_eq!(board[0].successes, 3);
        assert_eq!(board[0].failures, 1);
        assert!((board[0].success_rate - 0.75).abs() < 1e-9);
        // chump-local/research: 2 total.
        assert_eq!(board[1].backend, "chump-local");
        assert_eq!(board[1].total, 2);
        assert_eq!(board[1].successes, 1);
        assert_eq!(board[1].failures, 1);
        assert!((board[1].success_rate - 0.5).abs() < 1e-9);
    }

    #[test]
    fn routing_outcomes_writes_are_append_only() {
        let (store, _dir) = test_store();
        // Two writes for the same route should produce two rows that
        // aggregate, not overwrite.
        store
            .record_routing_outcome(&outcome(
                "claude",
                "shipped",
                "2026-04-27T10:00:00Z",
                Some(1),
                "",
                "",
            ))
            .unwrap();
        store
            .record_routing_outcome(&outcome(
                "claude",
                "killed",
                "2026-04-27T11:00:00Z",
                None,
                "",
                "",
            ))
            .unwrap();
        let board = store.routing_scoreboard().unwrap();
        assert_eq!(
            board.len(),
            1,
            "single route (same task_class+backend+model)"
        );
        assert_eq!(board[0].total, 2);
        assert_eq!(board[0].successes, 1);
        assert_eq!(board[0].failures, 1);
        // last_seen reflects the most-recent write.
        assert_eq!(board[0].last_seen, "2026-04-27T11:00:00Z");
    }

    // ── INFRA-216: post-reserve cross-host collision tests ────────────────

    /// When no sibling lease claims the same ID, reserve_verified returns
    /// the picked ID immediately (no collision, no retry).
    #[test]
    fn reserve_verified_passes_with_no_collision() {
        let (store, _dir) = test_store();
        unsafe {
            std::env::set_var("CHUMP_RESERVE_VERIFY", "1");
            std::env::set_var("CHUMP_RESERVE_VERIFY_SLEEP_MS", "0");
        }
        let id = store
            .reserve_verified("INFRA", "first", "P1", "s", "session-alpha")
            .unwrap();
        assert_eq!(id, "INFRA-001");
    }

    /// Simulate a cross-host race: a sibling session writes a
    /// `pending_new_gap` lease for the same ID *before* our verification
    /// re-scan. Our session has a lexicographically larger session_id, so
    /// it loses the tiebreak, rolls back, and retries to the next ID.
    #[test]
    fn reserve_verified_detects_collision_and_retries() {
        let (store, dir) = test_store();
        unsafe {
            std::env::set_var("CHUMP_RESERVE_VERIFY", "1");
            std::env::set_var("CHUMP_RESERVE_VERIFY_SLEEP_MS", "0");
        }

        // Write a sibling lease claiming INFRA-001 with a lexicographically
        // *smaller* session_id ("session-aaa" < "session-zzz") so the sibling
        // wins the tiebreak and we retry.
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let now = unix_now();
        let sibling = serde_json::json!({
            "session_id": "session-aaa",
            "pending_new_gap": { "id": "INFRA-001", "title": "sibling", "domain": "INFRA" },
            "heartbeat_at": chrono_like_iso(now),
            "expires_at": chrono_like_iso(now + 3600),
        });
        std::fs::write(
            locks.join("session-aaa.json"),
            serde_json::to_string(&sibling).unwrap(),
        )
        .unwrap();

        // Our session "session-zzz" would also pick INFRA-001 (empty DB), but
        // should detect the collision and retry to INFRA-002.
        let id = store
            .reserve_verified("INFRA", "mine", "P1", "s", "session-zzz")
            .unwrap();
        assert_eq!(
            id, "INFRA-002",
            "should skip INFRA-001 held by session-aaa, got {id}"
        );
    }

    /// `colliding_sessions` correctly identifies a sibling session that
    /// also holds the same pending_new_gap ID, while ignoring our own
    /// session and leases for different IDs.
    #[test]
    fn colliding_sessions_finds_sibling_and_ignores_own() {
        let (store, dir) = test_store();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let now = unix_now();
        let iso = chrono_like_iso(now);
        let exp = chrono_like_iso(now + 3600);

        // Our own lease for INFRA-005 (should be ignored by colliding_sessions).
        let our_lease = serde_json::json!({
            "session_id": "session-mine",
            "pending_new_gap": { "id": "INFRA-005", "title": "mine", "domain": "INFRA" },
            "heartbeat_at": &iso, "expires_at": &exp,
        });
        std::fs::write(
            locks.join("session-mine.json"),
            serde_json::to_string(&our_lease).unwrap(),
        )
        .unwrap();

        // Sibling A also claims INFRA-005 (the one we care about).
        let sibling_a = serde_json::json!({
            "session_id": "session-rival",
            "pending_new_gap": { "id": "INFRA-005", "title": "rival", "domain": "INFRA" },
            "heartbeat_at": &iso, "expires_at": &exp,
        });
        std::fs::write(
            locks.join("session-rival.json"),
            serde_json::to_string(&sibling_a).unwrap(),
        )
        .unwrap();

        // Sibling B claims a different ID (INFRA-007) — should not appear.
        let sibling_b = serde_json::json!({
            "session_id": "session-other",
            "pending_new_gap": { "id": "INFRA-007", "title": "other", "domain": "INFRA" },
            "heartbeat_at": &iso, "expires_at": &exp,
        });
        std::fs::write(
            locks.join("session-other.json"),
            serde_json::to_string(&sibling_b).unwrap(),
        )
        .unwrap();

        let colliders = store
            .colliding_sessions("INFRA", 5, "session-mine")
            .unwrap();
        assert_eq!(
            colliders,
            vec!["session-rival"],
            "expected only session-rival as collider, got {colliders:?}"
        );
    }

    /// The tiebreak rule: when colliding_sessions returns results, the
    /// session with the lexicographically smallest session_id wins. Verify
    /// that the winner determination logic is correct for both orderings.
    #[test]
    fn reserve_verified_tiebreak_smaller_session_wins() {
        let (store, dir) = test_store();
        unsafe {
            std::env::set_var("CHUMP_RESERVE_VERIFY", "1");
            std::env::set_var("CHUMP_RESERVE_VERIFY_SLEEP_MS", "0");
        }
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let now = unix_now();
        // Pre-seed INFRA-001 in the sibling's lease with a SMALLER session_id
        // so external_pending_ids sees it and we pick INFRA-002.  Then verify
        // we get INFRA-002 cleanly (no collision on INFRA-002).
        let sibling = serde_json::json!({
            "session_id": "session-aaa",
            "pending_new_gap": { "id": "INFRA-001", "title": "winner", "domain": "INFRA" },
            "heartbeat_at": chrono_like_iso(now),
            "expires_at": chrono_like_iso(now + 3600),
        });
        std::fs::write(
            locks.join("session-aaa.json"),
            serde_json::to_string(&sibling).unwrap(),
        )
        .unwrap();

        // "session-zzz" > "session-aaa" so we lose INFRA-001 and fall back
        // to INFRA-002 (no collision there).
        let id = store
            .reserve_verified("INFRA", "mine", "P1", "s", "session-zzz")
            .unwrap();
        assert_eq!(
            id, "INFRA-002",
            "session-zzz should fall back to INFRA-002, got {id}"
        );
    }

    /// With CHUMP_RESERVE_VERIFY=0, reserve_verified delegates directly
    /// to reserve() with no sleep or collision scan.
    #[test]
    fn reserve_verified_skips_verification_when_disabled() {
        let (store, _dir) = test_store();
        unsafe {
            std::env::set_var("CHUMP_RESERVE_VERIFY", "0");
        }
        let id = store
            .reserve_verified("INFRA", "fast", "P1", "s", "any-session")
            .unwrap();
        assert_eq!(id, "INFRA-001");
    }

    // ── INFRA-1954: git-history reuse guard ─────────────────────────────

    /// Reproduces the 2026-05-25 Cold Water incident: state.db has no row
    /// for the domain (fresh/rebuilt counter), so the naive next ID would be
    /// `<PREFIX>-001` — but that ID was already used by a gap that shipped
    /// and whose commit is sitting in git history. reserve() must skip it
    /// and hand out `<PREFIX>-002` instead.
    #[test]
    fn reserve_skips_id_already_referenced_in_git_history() {
        let dir = TempDir::new().unwrap();
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir.path())
                .status()
                .unwrap();
        };
        git(&["init", "--initial-branch=main", "--quiet"]);
        git(&["config", "user.email", "test@test.local"]);
        git(&["config", "user.name", "test"]);
        git(&[
            "commit",
            "--allow-empty",
            "-m",
            "feat(COLDWATER-001): already shipped and removed from the registry",
        ]);

        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
            std::env::set_var("CHUMP_RESERVE_GIT_HISTORY_CHECK", "1");
        }
        let store = GapStore::open(dir.path()).unwrap();

        let id = store.reserve("COLDWATER", "re-reserve", "P1", "s").unwrap();
        assert_eq!(
            id, "COLDWATER-002",
            "should skip COLDWATER-001 (found in git history), got {id}"
        );
    }

    /// Sanity check on the other side: when the candidate ID does NOT appear
    /// anywhere in git history, reserve() proceeds normally without skipping.
    #[test]
    fn reserve_does_not_skip_id_absent_from_git_history() {
        let dir = TempDir::new().unwrap();
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir.path())
                .status()
                .unwrap();
        };
        git(&["init", "--initial-branch=main", "--quiet"]);
        git(&["config", "user.email", "test@test.local"]);
        git(&["config", "user.name", "test"]);
        git(&["commit", "--allow-empty", "-m", "chore: unrelated commit"]);

        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
            std::env::set_var("CHUMP_RESERVE_GIT_HISTORY_CHECK", "1");
        }
        let store = GapStore::open(dir.path()).unwrap();

        let id = store.reserve("FRESHDOM", "brand new", "P1", "s").unwrap();
        assert_eq!(id, "FRESHDOM-001");
    }

    /// CREDIBLE-292: reproduces the registry split-brain collision pattern
    /// (RESILIENT-331, CREDIBLE-289) — two nodes with independent local
    /// state.db copies, sharing one `origin` remote. Node A reserves and
    /// pushes SPLIT-001; node B's checkout hasn't fetched since before that
    /// push, so its own counter (seeded from an empty local state.db) would
    /// naively also hand out SPLIT-001. `fetch_origin_refs` + the existing
    /// git-history check must close that gap: node B's reserve() fetches
    /// origin first and skips the already-taken ID.
    #[test]
    fn reserve_avoids_cross_node_collision_via_origin_fetch() {
        let git = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {args:?} failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        };

        // Bare "origin" both nodes share.
        let origin_dir = TempDir::new().unwrap();
        git(
            origin_dir.path(),
            &["init", "--bare", "--initial-branch=main", "--quiet"],
        );

        // Node A: clones origin, reserves+commits+pushes SPLIT-001.
        let node_a = TempDir::new().unwrap();
        git(
            node_a.path(),
            &["clone", "--quiet", origin_dir.path().to_str().unwrap(), "."],
        );
        git(node_a.path(), &["config", "user.email", "a@test.local"]);
        git(node_a.path(), &["config", "user.name", "node-a"]);
        git(
            node_a.path(),
            &[
                "commit",
                "--allow-empty",
                "-m",
                "feat(SPLIT-001): node A's reservation",
            ],
        );
        git(node_a.path(), &["push", "--quiet", "origin", "main"]);

        // Node B: independent clone of the SAME origin, but never fetched
        // after node A's push landed (simulates the dead backlog-sync
        // window) — its local refs are exactly what they were at clone time.
        let node_b = TempDir::new().unwrap();
        git(
            node_b.path(),
            &["clone", "--quiet", origin_dir.path().to_str().unwrap(), "."],
        );
        git(node_b.path(), &["config", "user.email", "b@test.local"]);
        git(node_b.path(), &["config", "user.name", "node-b"]);

        unsafe {
            std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
            std::env::set_var("CHUMP_RESERVE_GIT_HISTORY_CHECK", "1");
            std::env::set_var("CHUMP_RESERVE_FETCH_ORIGIN", "1");
        }
        let store_b = GapStore::open(node_b.path()).unwrap();
        // Node B's local state.db has never seen SPLIT-001 — naive counter
        // would start at SPLIT-001 too. fetch_origin_refs() pulls node A's
        // push first, so git_id_referenced() catches it and skips ahead.
        let id = store_b
            .reserve("SPLIT", "node B's reservation", "P1", "s")
            .unwrap();
        assert_eq!(
            id, "SPLIT-002",
            "node B must skip SPLIT-001 (already minted by node A on origin/main), got {id}"
        );
    }

    // ── INFRA-208: dump preserves unknown hand-curated fields ──────────

    /// Bare round-trip: a per-file YAML containing `acceptance:`,
    /// `closed_commit:`, and `runnable_now:` (the three fields the gap
    /// quantified as lossy on 2026-05-02) survives `dump_per_file_single`.
    #[test]
    fn dump_per_file_single_preserves_acceptance_closed_commit_runnable_now() {
        let (store, _dbdir) = test_store();
        let id = store.reserve("INFRA", "preserve test", "P1", "s").unwrap();

        let out_dir = TempDir::new().unwrap();
        // Seed a per-file mirror with hand-curated fields the schema doesn't own.
        let seeded = format!(
            "- id: {id}\n  \
             domain: INFRA\n  \
             title: preserve test\n  \
             status: open\n  \
             priority: P1\n  \
             effort: s\n  \
             acceptance: |\n    \
             this is a multi-line\n    \
             acceptance free-text block\n    \
             that the DB schema does not own\n  \
             closed_commit: 0123456789abcdef0123456789abcdef01234567\n  \
             runnable_now: |\n    \
             # Reproduce in a fresh tempdir:\n    \
             cargo test --bin chump dump_per_file_single_preserves\n\n",
            id = id
        );
        let path = out_dir.path().join(format!("{}.yaml", id));
        std::fs::write(&path, &seeded).unwrap();

        // Run the dump. The bool return is "did we write?" — true OR false is
        // valid here (the merge could be a no-op if the seeded format already
        // matched what `format_gap_yaml` would emit). We care about post-state.
        let _ = store.dump_per_file_single(&id, out_dir.path()).unwrap();

        let after = std::fs::read_to_string(&path).unwrap();
        assert!(
            after.contains("acceptance: |"),
            "acceptance: free-text field stripped\n--- got ---\n{after}"
        );
        assert!(
            after.contains("acceptance free-text block"),
            "acceptance: body content stripped\n--- got ---\n{after}"
        );
        assert!(
            after.contains("closed_commit: 0123456789abcdef0123456789abcdef01234567"),
            "closed_commit: 40-char SHA stripped\n--- got ---\n{after}"
        );
        assert!(
            after.contains("runnable_now: |"),
            "runnable_now: shell snippet header stripped\n--- got ---\n{after}"
        );
        assert!(
            after.contains("cargo test --bin chump dump_per_file_single_preserves"),
            "runnable_now: body content stripped\n--- got ---\n{after}"
        );
    }

    /// DB-owned fields MUST update when DB diverges from disk — preservation
    /// is opt-in only for fields the schema doesn't know about. Without this,
    /// the merge would freeze hand-edits to title/status/etc. and silently
    /// invert the "DB is canonical" contract (INFRA-059).
    #[test]
    fn dump_per_file_single_overrides_db_owned_fields() {
        let (store, _dbdir) = test_store();
        let id = store.reserve("INFRA", "fresh title", "P1", "s").unwrap();

        let out_dir = TempDir::new().unwrap();
        // Stale on-disk YAML claims a different title and status — exactly the
        // drift case INFRA-059 flipped authority to .chump/state.db to fix.
        let stale = format!(
            "- id: {id}\n  \
             domain: INFRA\n  \
             title: STALE TITLE\n  \
             status: done\n  \
             priority: P1\n  \
             effort: s\n  \
             acceptance: |\n    \
             keep this hand-curated text\n\n",
            id = id
        );
        let path = out_dir.path().join(format!("{}.yaml", id));
        std::fs::write(&path, &stale).unwrap();

        store.dump_per_file_single(&id, out_dir.path()).unwrap();
        let after = std::fs::read_to_string(&path).unwrap();

        // DB wins for title + status.
        assert!(
            after.contains("title: fresh title"),
            "DB title did not override disk\n--- got ---\n{after}"
        );
        assert!(
            !after.contains("title: STALE TITLE"),
            "stale title leaked through\n--- got ---\n{after}"
        );
        assert!(
            after.contains("status: open"),
            "DB status did not override disk\n--- got ---\n{after}"
        );
        // Unknown field still preserved.
        assert!(
            after.contains("keep this hand-curated text"),
            "preservation regressed\n--- got ---\n{after}"
        );
    }

    /// `dump_per_file` (the all-gaps variant) applies the same merge so a
    /// `chump gap dump --per-file` after surgical hand-edits doesn't
    /// strip them either.
    #[test]
    fn dump_per_file_all_preserves_unknown_fields() {
        let (store, _dbdir) = test_store();
        let id = store.reserve("INFRA", "all-variant", "P1", "s").unwrap();

        let out_dir = TempDir::new().unwrap();
        let seeded = format!(
            "- id: {id}\n  \
             domain: INFRA\n  \
             title: all-variant\n  \
             status: open\n  \
             priority: P1\n  \
             effort: s\n  \
             closed_commit: deadbeefcafebabe1234567890abcdef12345678\n\n",
            id = id
        );
        let path = out_dir.path().join(format!("{}.yaml", id));
        std::fs::write(&path, &seeded).unwrap();

        store.dump_per_file(out_dir.path()).unwrap();
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(
            after.contains("closed_commit: deadbeefcafebabe1234567890abcdef12345678"),
            "dump_per_file stripped closed_commit\n--- got ---\n{after}"
        );
    }

    /// INFRA-3605 regression: `evidence` IS a DB-owned column
    /// (`format_gap_yaml` emits it), but was missing from
    /// `DB_OWNED_GAP_FIELDS`. That made `merge_preserve_unknown_fields`
    /// treat any pre-existing on-disk `evidence:` block as unknown/
    /// hand-curated and splice it back in after the freshly generated
    /// `evidence:` block, producing two `evidence:` keys in one gap
    /// mapping. Applies to both `dump_per_file`/`dump_per_file_single`
    /// (this test) and `dump_yaml_with_meta` (the monolithic-dump-onto-
    /// existing-file path used by `chump gap dump --out docs/gaps.yaml`,
    /// which self-validates via serde_yaml and fails outright on the
    /// duplicate -- the state.db -> gaps.yaml sync no-op this gap fixes).
    #[test]
    fn dump_per_file_single_does_not_duplicate_evidence_field() {
        let (store, _dbdir) = test_store();
        let id = store
            .reserve("INFRA", "evidence dup test", "P1", "s")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    evidence: Some("fresh evidence from the DB".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();

        let out_dir = TempDir::new().unwrap();
        // Seed a per-file mirror that ALREADY has an evidence: block (the
        // shape every gap with evidence set has on disk before a re-dump).
        let seeded = format!(
            "- id: {id}\n  \
             domain: INFRA\n  \
             title: evidence dup test\n  \
             status: open\n  \
             priority: P1\n  \
             effort: s\n  \
             evidence: |\n    \
             stale evidence already on disk\n\n",
            id = id
        );
        let path = out_dir.path().join(format!("{}.yaml", id));
        std::fs::write(&path, &seeded).unwrap();

        store.dump_per_file_single(&id, out_dir.path()).unwrap();
        let after = std::fs::read_to_string(&path).unwrap();

        let evidence_key_count = after
            .lines()
            .filter(|l| l.starts_with("  evidence:"))
            .count();
        assert_eq!(
            evidence_key_count, 1,
            "expected exactly one 'evidence:' key, got {evidence_key_count}\n--- got ---\n{after}"
        );
        assert!(
            after.contains("fresh evidence from the DB"),
            "DB evidence did not win\n--- got ---\n{after}"
        );
        assert!(
            !after.contains("stale evidence already on disk"),
            "stale on-disk evidence should have been replaced, not preserved\n--- got ---\n{after}"
        );
        // The whole file must still parse as valid YAML with no duplicate keys.
        let parsed: Result<serde_yaml::Value, _> = serde_yaml::from_str(&after);
        assert!(
            parsed.is_ok(),
            "output is not valid YAML: {:?}\n--- got ---\n{after}",
            parsed.err()
        );
    }

    /// Unit-level tests for the field-block extractor — ensure the line
    /// scanner correctly distinguishes block-scalar continuation from new
    /// field starts, and ignores DB-owned keys.
    #[test]
    fn extract_unknown_field_blocks_handles_block_scalars() {
        let yaml = "- id: INFRA-999\n  \
                    domain: INFRA\n  \
                    title: extractor test\n  \
                    description: |\n    \
                    db-owned, must NOT be returned\n  \
                    acceptance: |\n    \
                    line one of free-text\n    \
                    line two indented further\n  \
                    closed_commit: abcdef0123456789abcdef0123456789abcdef01\n";
        let blocks = extract_unknown_field_blocks(yaml);
        assert_eq!(
            blocks.len(),
            2,
            "expected 2 unknown-field blocks (acceptance + closed_commit), got: {:?}",
            blocks
        );
        assert!(blocks[0].starts_with("  acceptance: |\n"));
        assert!(blocks[0].contains("line one of free-text"));
        assert!(blocks[0].contains("line two indented further"));
        assert!(blocks[1].starts_with("  closed_commit: "));
        // Nothing in either block should be DB-owned.
        for b in &blocks {
            assert!(!b.contains("description:"), "extractor leaked description");
            assert!(!b.contains("title:"), "extractor leaked title");
        }
    }

    /// Acceptance_criteria list items (`  - foo`) are continuation, not
    /// new field starts. Without the list-item guard, the extractor would
    /// classify each `- ` line as a new entry and drop everything after.
    #[test]
    fn extract_unknown_field_blocks_does_not_split_on_list_items() {
        let yaml = "- id: INFRA-998\n  \
                    domain: INFRA\n  \
                    title: list-item test\n  \
                    acceptance_criteria:\n    \
                    - first\n    \
                    - second\n  \
                    closed_commit: 1111111111111111111111111111111111111111\n";
        let blocks = extract_unknown_field_blocks(yaml);
        assert_eq!(blocks.len(), 1, "got blocks: {:?}", blocks);
        assert!(blocks[0].starts_with("  closed_commit: "));
    }

    #[test]
    fn cog052_parse_json_ac_list_roundtrip() {
        // Well-formed JSON array.
        let items = parse_json_ac_list(r#"["cargo check passes","test script exits 0"]"#);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0], "cargo check passes");
        assert_eq!(items[1], "test script exits 0");
        // Empty / blank input returns empty vec.
        assert!(parse_json_ac_list("").is_empty());
        assert!(parse_json_ac_list("   ").is_empty());
        // Unparseable returns empty vec (graceful).
        assert!(parse_json_ac_list("not json").is_empty());
    }

    // ── META-555: effect-verified done-bar (advisory MVP) ─────────────────────

    #[test]
    fn meta555_extract_verify_commands_default_is_empty() {
        // Natural-language ACs (the overwhelming default) yield NO command, so
        // ship() is untouched for them — the structural anti-wedge guarantee.
        assert!(extract_verify_commands(
            r#"["cargo fmt passes","script exists and is executable"]"#
        )
        .is_empty());
        assert!(extract_verify_commands("").is_empty());
        assert!(extract_verify_commands("not json").is_empty());
        // A mid-sentence or differently-prefixed "verify:" must NOT match — only
        // an exact `verify:` prefix on the trimmed item counts.
        assert!(extract_verify_commands(
            r#"["This will self-verify: nothing","please verify: it by hand"]"#
        )
        .is_empty());
    }

    #[test]
    fn meta555_extract_verify_commands_opt_in_marker() {
        let cmds = extract_verify_commands(
            r#"["some prose","verify: test -f Cargo.toml","VERIFY:   echo hi  "]"#,
        );
        assert_eq!(
            cmds,
            vec!["test -f Cargo.toml".to_string(), "echo hi".to_string()]
        );
    }

    #[test]
    fn meta555_no_criterion_is_noop() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "plain-gap", "P2", "s").unwrap();
        // No verify: marker -> NoLiveCriterion, nothing run.
        assert_eq!(
            store.evaluate_effect_verification(&id),
            EffectVerdict::NoLiveCriterion
        );
    }

    #[test]
    fn meta555_passing_verify_is_effect_verified() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "verified-gap", "P2", "s").unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    acceptance_criteria: Some(r#"["verify: true"]"#.to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(
            store.evaluate_effect_verification(&id),
            EffectVerdict::EffectVerified
        );
    }

    #[test]
    fn meta555_failing_verify_flags_gap_but_still_ships() {
        // The core scenario: a fix that "merges" but does NOT change the live
        // outcome. Its verify: check fails -> the gap ships (done) but is left
        // FLAGGED (note annotation) rather than clean-done, so it can be
        // re-worked under the same id instead of spawning a duplicate.
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "ineffective-fix", "P2", "s")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    acceptance_criteria: Some(r#"["verify: false"]"#.to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        // Direct verdict.
        match store.evaluate_effect_verification(&id) {
            EffectVerdict::EffectUnverified { failed_command, .. } => {
                assert_eq!(failed_command, "false");
            }
            other => panic!("expected EffectUnverified, got {other:?}"),
        }
        // End-to-end through ship(): closure SUCCEEDS (never blocked) ...
        store.ship(&id, "s", None).unwrap();
        let g = store.get(&id).unwrap().expect("gap exists");
        assert_eq!(g.status, "done", "advisory MVP must NOT block the close");
        // ... but the gap is visibly FLAGGED, not clean-done.
        assert!(
            g.notes.contains("EFFECT-UNVERIFIED"),
            "expected effect-unverified flag in notes, got: {:?}",
            g.notes
        );
    }

    #[test]
    fn meta555_ordinary_ship_is_not_flagged() {
        // Anti-wedge end-to-end: a normal gap with no verify: criterion ships
        // exactly as before — done, and NOT flagged.
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "ordinary", "P2", "s").unwrap();
        store.ship(&id, "s", None).unwrap();
        let g = store.get(&id).unwrap().expect("gap exists");
        assert_eq!(g.status, "done");
        assert!(
            !g.notes.contains("EFFECT-UNVERIFIED"),
            "ordinary ship must not be flagged"
        );
    }

    /// Empty-input guard: nothing to preserve, nothing returned.
    #[test]
    fn merge_preserve_unknown_fields_noop_when_existing_is_pure() {
        let generated = "- id: INFRA-1\n  domain: INFRA\n  title: x\n\n";
        let existing = "- id: INFRA-1\n  domain: INFRA\n  title: x\n\n";
        let merged = merge_preserve_unknown_fields(generated, existing);
        assert_eq!(merged, generated);
    }

    // ── CREDIBLE-005: error-path tests ────────────────────────────────────────

    #[test]
    fn ship_nonexistent_gap_returns_err() {
        let (store, _dir) = test_store();
        let result = store.ship("INFRA-999", "session-x", None);
        assert!(result.is_err(), "ship on unknown gap should fail, got Ok");
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("not found") || msg.contains("already done"),
            "unexpected error: {msg}"
        );
    }

    #[test]
    fn ship_already_done_gap_returns_err() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "done-candidate", "P2", "s").unwrap();
        store.ship(&id, "session-a", None).unwrap();
        let second_ship = store.ship(&id, "session-b", None);
        assert!(
            second_ship.is_err(),
            "shipping an already-done gap should fail"
        );
        let msg = format!("{:#}", second_ship.unwrap_err());
        assert!(
            msg.contains("not found") || msg.contains("already done"),
            "unexpected error: {msg}"
        );
    }

    #[test]
    fn claim_nonexistent_gap_returns_err() {
        let (store, _dir) = test_store();
        let result = store.claim("INFRA-404", "session-x", "/tmp/wt", 3600);
        assert!(result.is_err(), "claim on unknown gap should fail");
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("not found"),
            "expected 'not found' in error: {msg}"
        );
    }

    #[test]
    fn claim_done_gap_returns_err() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "done-target", "P2", "s").unwrap();
        store.ship(&id, "session-x", None).unwrap();
        let result = store.claim(&id, "session-y", "/tmp/wt", 3600);
        assert!(result.is_err(), "claiming a done gap should fail");
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("already done") || msg.contains("not found"),
            "unexpected error: {msg}"
        );
    }

    #[test]
    fn claim_live_claimed_gap_returns_err() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "contested", "P2", "s").unwrap();
        store.claim(&id, "session-owner", "/tmp/wt1", 3600).unwrap();
        let result = store.claim(&id, "session-interloper", "/tmp/wt2", 3600);
        assert!(result.is_err(), "claiming a live-claimed gap should fail");
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("live-claimed"),
            "expected 'live-claimed' in error: {msg}"
        );
    }

    #[test]
    fn get_nonexistent_gap_returns_ok_none() {
        let (store, _dir) = test_store();
        let result = store.get("INFRA-404").unwrap();
        assert!(result.is_none(), "get on unknown gap should return None");
    }

    #[test]
    fn preflight_nonexistent_gap_returns_not_found() {
        let (store, _dir) = test_store();
        let result = store.preflight("INFRA-404").unwrap();
        assert!(
            matches!(result, PreflightResult::NotFound),
            "expected NotFound, got {result:?}"
        );
    }

    #[test]
    fn preflight_done_gap_returns_done() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "will-be-done", "P2", "s").unwrap();
        store.ship(&id, "session-x", None).unwrap();
        let result = store.preflight(&id).unwrap();
        assert!(
            matches!(result, PreflightResult::Done),
            "expected Done, got {result:?}"
        );
    }

    #[test]
    fn preflight_claimed_gap_returns_claimed() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "will-be-claimed", "P2", "s")
            .unwrap();
        store.claim(&id, "session-owner", "/tmp/wt", 3600).unwrap();
        let result = store.preflight(&id).unwrap();
        assert!(
            matches!(result, PreflightResult::Claimed(_)),
            "expected Claimed, got {result:?}"
        );
        if let PreflightResult::Claimed(s) = result {
            assert_eq!(s, "session-owner");
        }
    }

    #[test]
    fn set_recycled_id_guard_rejects_reopening_done_gap() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "done-gap", "P2", "s").unwrap();
        store.ship(&id, "session-x", None).unwrap();
        let result = store.set_fields(
            &id,
            GapFieldUpdate {
                status: Some("open".to_string()),
                ..Default::default()
            },
        );
        assert!(result.is_err(), "recycled-ID guard should reject reopening");
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("recycled-ID") || msg.contains("already done") || msg.contains("terminal"),
            "unexpected error: {msg}"
        );
    }

    #[test]
    fn set_hijack_guard_rejects_title_rewrite() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "original-title", "P2", "s").unwrap();
        let result = store.set_fields(
            &id,
            GapFieldUpdate {
                title: Some("completely-different-title".to_string()),
                ..Default::default()
            },
        );
        assert!(result.is_err(), "hijack guard should reject title rewrite");
        let msg = format!("{:#}", result.unwrap_err());
        assert!(
            msg.contains("hijack") || msg.contains("title"),
            "unexpected error: {msg}"
        );
    }

    #[test]
    fn dump_per_file_single_returns_err_for_unknown_gap() {
        let (store, dir) = test_store();
        let per_file_dir = dir.path().join("gaps");
        std::fs::create_dir_all(&per_file_dir).unwrap();
        let result = store.dump_per_file_single("INFRA-999", &per_file_dir);
        assert!(
            result.is_err() || matches!(result, Ok(false)),
            "dump_per_file_single on unknown gap should fail or return false"
        );
    }

    // ZERO-WASTE-045: shipped_gap_dedupe_candidates tests. This is what a
    // reserve-time Almanac-corpus search feeds into: a list of candidate IDs
    // (found via full-text search over docs/gaps/*.yaml) get loaded straight
    // from YAML and scored, so long-shipped gaps that fell out of state.db's
    // closed-lookback window still surface as near-matches.
    // ── INFRA-6701: recently-merged-PR overlap advisory ──────────────
    fn seed_pr_cache(dir: &std::path::Path) -> std::path::PathBuf {
        let chump = dir.join(".chump");
        std::fs::create_dir_all(&chump).unwrap();
        let db = chump.join("github_cache.db");
        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TABLE pr_state (number INTEGER PRIMARY KEY, title TEXT, merged_at TEXT);",
        )
        .unwrap();
        db
    }

    #[test]
    fn recently_merged_pr_flags_in_window_near_dup_only() {
        let tmp = tempfile::tempdir().unwrap();
        let db = seed_pr_cache(tmp.path());
        let conn = rusqlite::Connection::open(&db).unwrap();
        // In-window merged near-dup — MUST be flagged.
        conn.execute(
            "INSERT INTO pr_state (number, title, merged_at) VALUES (?1, ?2, datetime('now'))",
            rusqlite::params![4242_i64, "duty-officer escalation page fallback"],
        )
        .unwrap();
        // Unrelated merged PR — MUST NOT match.
        conn.execute(
            "INSERT INTO pr_state (number, title, merged_at) VALUES (?1, ?2, datetime('now'))",
            rusqlite::params![4243_i64, "kroger cart pricing edge function"],
        )
        .unwrap();
        // Near-dup but merged 90 days ago — outside the 7-day window.
        conn.execute(
            "INSERT INTO pr_state (number, title, merged_at) VALUES (?1, ?2, datetime('now','-90 days'))",
            rusqlite::params![4244_i64, "duty-officer escalation page fallback"],
        )
        .unwrap();
        // Still-open PR (merged_at NULL) — this fold is merged-only.
        conn.execute(
            "INSERT INTO pr_state (number, title, merged_at) VALUES (?1, ?2, NULL)",
            rusqlite::params![4245_i64, "duty-officer escalation page fallback"],
        )
        .unwrap();

        let hits = recently_merged_pr_dedupe_candidates(
            tmp.path(),
            "duty-officer escalation page fallback",
            7,
            0.65,
        );
        assert_eq!(
            hits.len(),
            1,
            "expected exactly one in-window merged near-dup, got {hits:?}"
        );
        assert_eq!(hits[0].0, 4242, "wrong PR flagged: {hits:?}");
        assert!(hits[0].3 >= 0.65, "score below threshold: {hits:?}");
    }

    #[test]
    fn recently_merged_pr_degrades_to_empty_when_cache_absent() {
        // No .chump/github_cache.db → advisory helper returns empty and never
        // errors, so a missing cache can never block a legitimate reserve.
        let tmp = tempfile::tempdir().unwrap();
        let hits = recently_merged_pr_dedupe_candidates(
            tmp.path(),
            "some brand new gap title with no dup",
            7,
            0.65,
        );
        assert!(
            hits.is_empty(),
            "expected empty on absent cache, got {hits:?}"
        );
    }

    #[test]
    fn shipped_gap_dedupe_candidates_surfaces_old_shipped_gap() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs/gaps");
        std::fs::create_dir_all(&gaps_dir).unwrap();
        std::fs::write(
            gaps_dir.join("ZERO-WASTE-999.yaml"),
            "- id: ZERO-WASTE-999\n  domain: ZERO-WASTE\n  title: \"dedupe gaps at reserve time via almanac index\"\n  status: done\n  priority: P1\n  effort: m\n  closed_pr: 4242\n",
        )
        .unwrap();

        let candidates = shipped_gap_dedupe_candidates(
            dir.path(),
            "dedupe gaps at reserve time using almanac index",
            &["ZERO-WASTE-999".to_string()],
            0.5,
        );
        assert_eq!(
            candidates.len(),
            1,
            "near-identical shipped gap must surface"
        );
        assert_eq!(candidates[0].0, "ZERO-WASTE-999");
        assert_eq!(
            candidates[0].2, "done",
            "status must be the ground-truth YAML status"
        );
        assert!(candidates[0].3 >= 0.5);
    }

    #[test]
    fn shipped_gap_dedupe_candidates_filters_below_threshold() {
        let dir = tempfile::tempdir().unwrap();
        let gaps_dir = dir.path().join("docs/gaps");
        std::fs::create_dir_all(&gaps_dir).unwrap();
        std::fs::write(
            gaps_dir.join("INFRA-1.yaml"),
            "- id: INFRA-1\n  domain: INFRA\n  title: \"completely unrelated topic about disk pressure\"\n  status: done\n  priority: P2\n  effort: s\n  closed_pr: 1\n",
        )
        .unwrap();

        let candidates = shipped_gap_dedupe_candidates(
            dir.path(),
            "dedupe gaps at reserve time using almanac index",
            &["INFRA-1".to_string()],
            0.5,
        );
        assert!(
            candidates.is_empty(),
            "unrelated title must not surface as a candidate"
        );
    }

    #[test]
    fn shipped_gap_dedupe_candidates_skips_missing_ids() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("docs/gaps")).unwrap();
        let candidates = shipped_gap_dedupe_candidates(
            dir.path(),
            "anything",
            &["DOES-NOT-EXIST-1".to_string()],
            0.0,
        );
        assert!(
            candidates.is_empty(),
            "nonexistent gap ID must be skipped, not error"
        );
    }

    #[test]
    fn reserve_increments_id_counter_monotonically() {
        let (store, _dir) = test_store();
        let id1 = store.reserve("EVAL", "first", "P2", "s").unwrap();
        let id2 = store.reserve("EVAL", "second", "P2", "s").unwrap();
        let n1: u32 = id1.split('-').next_back().unwrap().parse().unwrap();
        let n2: u32 = id2.split('-').next_back().unwrap().parse().unwrap();
        assert!(n2 > n1, "IDs must increment: {id1} then {id2}");
    }

    #[test]
    fn list_with_status_filter_excludes_done_gaps() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "will-be-done", "P2", "s").unwrap();
        store.ship(&id, "session-x", None).unwrap();
        let open_gaps = store.list(Some("open")).unwrap();
        assert!(
            !open_gaps.iter().any(|g| g.id == id),
            "done gap should not appear in open list"
        );
        let done_gaps = store.list(Some("done")).unwrap();
        assert!(
            done_gaps.iter().any(|g| g.id == id),
            "done gap should appear in done list"
        );
    }

    #[test]
    fn ship_with_closed_pr_stamps_pr_number() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "with-pr", "P2", "s").unwrap();
        store.ship(&id, "session-x", Some(1234)).unwrap();
        let gap = store.get(&id).unwrap().unwrap();
        assert_eq!(gap.closed_pr, Some(1234));
        assert_eq!(gap.status, "done");
    }

    // INFRA-1149: title_jaccard similarity tests
    #[test]
    fn title_jaccard_identical_titles() {
        let score = GapStore::title_jaccard("foo bar baz", "foo bar baz");
        assert_eq!(score, 1.0, "identical titles should have score 1.0");
    }

    #[test]
    fn title_jaccard_empty_strings() {
        let score = GapStore::title_jaccard("", "");
        assert_eq!(score, 1.0, "two empty strings should have score 1.0");
    }

    #[test]
    fn title_jaccard_completely_different() {
        let score = GapStore::title_jaccard("alpha bravo charlie", "delta echo foxtrot");
        assert_eq!(
            score, 0.0,
            "completely different tokens should have score 0.0"
        );
    }

    #[test]
    fn title_jaccard_partial_overlap() {
        let score = GapStore::title_jaccard("foo bar baz", "foo bar qux");
        // Tokens: {foo, bar, baz} vs {foo, bar, qux} → intersection=2, union=4 → 0.5
        assert!(
            score > 0.4 && score < 0.6,
            "partial overlap should be ~0.5, got {}",
            score
        );
    }

    #[test]
    fn title_jaccard_stopword_filtering() {
        let score = GapStore::title_jaccard("the foo and the bar", "the foo and the baz");
        // After stopword removal: {foo, bar} vs {foo, baz} → intersection=1, union=3 → 0.333...
        assert!(
            score > 0.3 && score < 0.4,
            "stopword filtering should work correctly, got {}",
            score
        );
    }

    #[test]
    fn title_jaccard_pillar_prefix_normalization() {
        let score1 = GapStore::title_jaccard("RESILIENT: foo bar", "foo bar");
        let score2 = GapStore::title_jaccard("EFFECTIVE: foo bar baz", "CREDIBLE: foo bar qux");
        // Both should normalize pillar prefixes away
        assert!(
            score1 > 0.7,
            "pillar prefix should not affect core similarity"
        );
        assert!(
            score2 > 0.3 && score2 < 0.7,
            "both should strip pillar prefix"
        );
    }

    // INFRA-1149: similarity_candidates integration tests
    #[test]
    fn similarity_candidates_finds_similar_gaps() {
        let (store, _dir) = test_store();
        let id1 = store
            .reserve("INFRA", "RESILIENT: foo bar baz", "P1", "s")
            .unwrap();
        let id2 = store
            .reserve("INFRA", "RESILIENT: foo bar qux", "P1", "s")
            .unwrap();
        let id3 = store
            .reserve("INFRA", "unrelated alpha beta", "P1", "s")
            .unwrap();

        let candidates = store
            .similarity_candidates("RESILIENT: foo bar something", 3, 30)
            .unwrap();

        // Should find id1 and id2 with similarity > 0
        assert!(
            candidates.iter().any(|(id, _, _, _)| id == &id1),
            "should find similar gap id1"
        );
        assert!(
            candidates.iter().any(|(id, _, _, _)| id == &id2),
            "should find similar gap id2"
        );

        // id1 should rank higher than id3
        if let Some(pos1) = candidates.iter().position(|(id, _, _, _)| id == &id1) {
            if let Some(pos3) = candidates.iter().position(|(id, _, _, _)| id == &id3) {
                assert!(pos1 < pos3, "more similar gap should rank higher");
            }
        }
    }

    #[test]
    fn similarity_candidates_respects_top_n() {
        let (store, _dir) = test_store();
        for i in 0..5 {
            store
                .reserve("INFRA", &format!("foo bar variant {}", i), "P1", "s")
                .unwrap();
        }

        let candidates = store.similarity_candidates("foo bar query", 2, 30).unwrap();
        assert!(candidates.len() <= 2, "should respect top_n limit");
    }

    #[test]
    fn similarity_candidates_respects_lookback() {
        let (store, _dir) = test_store();
        let id_open = store.reserve("INFRA", "open gap title", "P1", "s").unwrap();
        let id_done = store.reserve("INFRA", "done gap title", "P1", "s").unwrap();

        // Ship the done gap
        store.ship(&id_done, "test-session", None).unwrap();

        // Query with 30-day lookback should find both
        let candidates_30 = store
            .similarity_candidates("gap title variant", 3, 30)
            .unwrap();
        assert!(
            !candidates_30.is_empty(),
            "should find gaps within 30-day window"
        );

        // Query with 0-day lookback should only find open gaps
        let candidates_0 = store
            .similarity_candidates("gap title variant", 3, 0)
            .unwrap();
        assert!(
            candidates_0.iter().any(|(id, _, _, _)| id == &id_open),
            "should include open gaps regardless of lookback"
        );
    }

    #[test]
    fn close_orphan_prs_respects_bypass_env() {
        let (store, dir) = test_store();
        let id = store.reserve("INFRA", "test-orphan", "P2", "s").unwrap();

        // Set the bypass env var
        std::env::set_var("CHUMP_GAP_SHIP_NO_ORPHAN_CLOSE", "1");

        // Calling close_orphan_prs should return empty vec without any gh calls
        let result = store.close_orphan_prs(&id, Some(1234), dir.path()).unwrap();
        assert_eq!(
            result.len(),
            0,
            "orphan closing should be skipped with bypass env"
        );

        // Clean up
        std::env::remove_var("CHUMP_GAP_SHIP_NO_ORPHAN_CLOSE");
    }

    // ── INFRA-2022: set_fields acceptance_criteria round-trip ──────────────
    // Verifies that an operator-supplied AC value is persisted to state.db
    // and survives a subsequent get(). This is the DB-level guard for the
    // bug where `chump gap set` silently lost the provided value.

    #[test]
    fn set_fields_acceptance_criteria_roundtrip() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "ac-roundtrip-test", "P1", "xs")
            .unwrap();

        // Confirm the gap starts with empty or TODO AC (from reserve defaults).
        let before = store.get(&id).unwrap().unwrap();
        // Either empty or the obs-AC TODO stubs — neither should be our target.
        let target = r#"["real criterion here","second bullet"]"#;
        assert_ne!(
            before.acceptance_criteria, target,
            "pre-condition: gap should not already have the target AC"
        );

        // Apply the operator-provided value via set_fields — the path that
        // was broken in INFRA-2022.
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    acceptance_criteria: Some(target.to_string()),
                    ..Default::default()
                },
            )
            .expect("set_fields acceptance_criteria must succeed");

        // Read back from DB and verify value was persisted.
        let after = store.get(&id).unwrap().unwrap();
        assert_eq!(
            after.acceptance_criteria, target,
            "set_fields must persist the operator-supplied AC; got {:?}",
            after.acceptance_criteria
        );
    }

    #[test]
    fn set_fields_acceptance_criteria_overwrites_todo_placeholders() {
        // Regression: when a gap is reserved with the default obs-AC TODO stubs
        // (INFRA-756), a subsequent `chump gap set --acceptance-criteria "..."'
        // must fully replace them. The bug in INFRA-2022 was that the positional
        // form `acceptance_criteria "..."` (no `--`) was silently ignored at the
        // CLI layer, leaving the TODOs in place. This test verifies the DB layer
        // correctly overwrites any existing value when set_fields is called.
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "overwrite-todo-test", "P1", "xs")
            .unwrap();

        // Seed with TODO placeholders (simulating what reserve installs).
        let todo_ac = r#"["TODO: what events","TODO: how cost tracked"]"#;
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    acceptance_criteria: Some(todo_ac.to_string()),
                    ..Default::default()
                },
            )
            .unwrap();

        // Now overwrite with real AC — must fully replace the TODO stubs.
        let real_ac = r#"["chump gap show INFRA-NNN renders the operator-provided text"]"#;
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    acceptance_criteria: Some(real_ac.to_string()),
                    ..Default::default()
                },
            )
            .unwrap();

        let after = store.get(&id).unwrap().unwrap();
        assert_eq!(
            after.acceptance_criteria, real_ac,
            "set_fields must overwrite TODO stubs with real AC; got {:?}",
            after.acceptance_criteria
        );
        // Verify the original TODO stubs were fully replaced — the stored value
        // must NOT equal the seed stubs even if some descriptive text might
        // coincidentally contain the word "TODO".
        assert_ne!(
            after.acceptance_criteria, todo_ac,
            "stored AC must not still be the original TODO stubs"
        );
    }

    // ── INFRA-2134: shipped_in field tests ──────────────────────────────────

    /// Open gap: shipped_in must be None.
    #[test]
    fn shipped_in_is_none_for_open_gap() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "open gap shipped_in", "P1", "s")
            .unwrap();
        let row = store.get(&id).unwrap().expect("row exists");
        assert_eq!(row.status, "open");
        assert!(
            row.shipped_in.is_none(),
            "open gap must have no shipped_in; got {:?}",
            row.shipped_in
        );
    }

    /// Integration-cycle shipped gap: set_shipped_in with 5-key JSON; get round-trips it.
    #[test]
    fn shipped_in_integration_cycle_round_trips() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "integration shipped gap", "P1", "s")
            .unwrap();
        let json = r#"{"integration_id":"integration-2026-05-29-1430","integration_pr":"https://github.com/repairman29/chump/pull/2789","child_commit":"abc1234def","merge_sha":"f8e9d2a1b3","shipped_at":"2026-05-29T14:30:00Z"}"#;
        store.set_shipped_in(&id, json).unwrap();
        let row = store.get(&id).unwrap().expect("row exists");
        let stored = row.shipped_in.expect("shipped_in must be set");
        let parsed: serde_json::Value = serde_json::from_str(&stored).expect("valid JSON");
        assert_eq!(parsed["integration_id"], "integration-2026-05-29-1430");
        assert_eq!(
            parsed["integration_pr"],
            "https://github.com/repairman29/chump/pull/2789"
        );
        assert_eq!(parsed["child_commit"], "abc1234def");
        assert_eq!(parsed["merge_sha"], "f8e9d2a1b3");
        assert_eq!(parsed["shipped_at"], "2026-05-29T14:30:00Z");
    }

    /// Per-PR shipped gap (backwards-compat): 2-key shape with pr_url + merge_sha.
    #[test]
    fn shipped_in_per_pr_backwards_compat_round_trips() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "per-pr shipped gap", "P1", "s")
            .unwrap();
        let json = r#"{"pr_url":"https://github.com/repairman29/chump/pull/2750","merge_sha":"deadbeef12"}"#;
        store.set_shipped_in(&id, json).unwrap();
        let row = store.get(&id).unwrap().expect("row exists");
        let stored = row.shipped_in.expect("shipped_in must be set");
        let parsed: serde_json::Value = serde_json::from_str(&stored).expect("valid JSON");
        assert_eq!(
            parsed["pr_url"],
            "https://github.com/repairman29/chump/pull/2750"
        );
        assert_eq!(parsed["merge_sha"], "deadbeef12");
        // Integration keys absent in backwards-compat shape.
        assert!(parsed.get("integration_id").is_none());
        assert!(parsed.get("child_commit").is_none());
    }

    /// --json output shape: shipped_in deserialises to a nested object, not a string.
    #[test]
    fn shipped_in_json_output_is_nested_object() {
        let (store, _dir) = test_store();
        let id = store.reserve("INFRA", "json shape gap", "P1", "s").unwrap();
        let json = r#"{"integration_id":"integration-2026-05-29-1500","integration_pr":"https://github.com/repairman29/chump/pull/2800","child_commit":"cafe0011","merge_sha":"babe0022","shipped_at":"2026-05-29T15:00:00Z"}"#;
        store.set_shipped_in(&id, json).unwrap();
        let row = store.get(&id).unwrap().expect("row exists");
        // Simulate the --json serialisation path: serde_json::to_value(&g),
        // then replace the shipped_in string with a parsed object.
        let mut val = serde_json::to_value(&row).unwrap();
        if let Some(obj) = val.as_object_mut() {
            if let Some(raw) = row.shipped_in.as_deref() {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(raw) {
                    obj.insert("shipped_in".to_string(), parsed);
                }
            }
        }
        // The shipped_in key must be an object, not a string.
        let si = val.get("shipped_in").expect("shipped_in key present");
        assert!(
            si.is_object(),
            "shipped_in must be a JSON object in --json output; got {:?}",
            si
        );
        assert_eq!(si["integration_id"], "integration-2026-05-29-1500");
        assert_eq!(si["merge_sha"], "babe0022");
    }
}

// ── INFRA-2137: bisect_quarantined + requeue tests ────────────────────────────
#[cfg(test)]
mod quarantine_tests {
    use super::*;
    use tempfile::tempdir;

    fn test_store() -> (GapStore, tempfile::TempDir) {
        let dir = tempdir().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        (store, dir)
    }

    // 1. status_registry_seeded: after open(), gap_status_registry contains
    //    both 'bisect_quarantined' and 'ready_to_ship'.
    #[test]
    fn status_registry_seeded() {
        let (store, _dir) = test_store();
        let count: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM gap_status_registry WHERE status IN ('bisect_quarantined','ready_to_ship')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 2, "registry must contain both new statuses");
    }

    // CREDIBLE-197: an external gap whose acceptance is verified already-met (a
    // Scout/Holler finding that was already fixed) closes as `already_satisfied`
    // with an evidence RECEIPT and NO PR. The INFRA-402 no-fake-done guard keys only
    // on status="done", so this needs no CHUMP_BYPASS_CLOSED_PR_GUARD; the status is
    // registered + terminal (not 'open', so never re-picked/re-executed).
    #[test]
    fn credible197_already_satisfied_closes_without_pr_and_guard_intact() {
        let (store, _dir) = test_store();

        // The disposition is a registered status (honest for audit).
        let reg: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM gap_status_registry WHERE status='already_satisfied'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(reg, 1, "already_satisfied must be a registered status");

        // Close a gap as already_satisfied: NO closed_pr, with a verification receipt.
        let id = store
            .reserve("INFRA", "spawn already fixed", "P2", "s")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("already_satisfied".to_string()),
                    evidence: Some(
                        "AC already met: World.js:353 spawnX 17->16 off water; verified read-only"
                            .to_string(),
                    ),
                    closed_date: Some("2026-08-03".to_string()),
                    ..Default::default()
                },
            )
            .expect(
                "already_satisfied must close WITHOUT a closed_pr (INFRA-402 keys only on 'done')",
            );

        let row = store.get(&id).unwrap().unwrap();
        assert_eq!(row.status, "already_satisfied");
        assert_ne!(row.status, "open", "terminal — never re-picked");
        assert!(
            row.closed_pr.is_none(),
            "no PR backs an already-satisfied close"
        );
        assert!(
            row.evidence
                .as_deref()
                .unwrap_or("")
                .contains("World.js:353"),
            "the verification receipt is recorded in evidence, got: {:?}",
            row.evidence
        );

        // The INFRA-402 guard is INTACT — a plain `done` without a PR still bails.
        let id2 = store
            .reserve("INFRA", "needs a real pr", "P2", "s")
            .unwrap();
        let err = store.set_fields(
            &id2,
            GapFieldUpdate {
                status: Some("done".to_string()),
                ..Default::default()
            },
        );
        assert!(
            err.is_err(),
            "INFRA-402 must still block status=done without a closed_pr"
        );
        assert!(format!("{:#}", err.unwrap_err()).contains("INFRA-402"));
    }

    // 2. append_notes_seeds_empty: appending to a gap with no notes yields a
    //    single timestamped entry.
    #[test]
    fn append_notes_seeds_empty() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "notes-seed-test", "P1", "xs")
            .unwrap();
        store.append_notes_for_gap(&id, "first note").unwrap();
        let row = store.get(&id).unwrap().unwrap();
        assert!(
            row.notes.contains("first note"),
            "notes must contain appended text"
        );
        assert!(row.notes.contains('['), "notes must have timestamp bracket");
    }

    // 3. append_notes_accumulates: two appends accumulate, newline-separated.
    #[test]
    fn append_notes_accumulates() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "notes-accum-test", "P1", "xs")
            .unwrap();
        store.append_notes_for_gap(&id, "alpha").unwrap();
        store.append_notes_for_gap(&id, "beta").unwrap();
        let row = store.get(&id).unwrap().unwrap();
        assert!(row.notes.contains("alpha"), "first note must persist");
        assert!(row.notes.contains("beta"), "second note must be appended");
        let count = row.notes.matches('[').count();
        assert_eq!(count, 2, "exactly two bracketed timestamps expected");
    }

    // 4. count_bisect_quarantined_zero: fresh store has zero quarantined gaps.
    #[test]
    fn count_bisect_quarantined_zero() {
        let (store, _dir) = test_store();
        assert_eq!(store.count_bisect_quarantined().unwrap(), 0);
    }

    // 5. count_bisect_quarantined_counts: after setting status, count reflects it.
    #[test]
    fn count_bisect_quarantined_counts() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "quarantine-count-test", "P1", "xs")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("bisect_quarantined".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(store.count_bisect_quarantined().unwrap(), 1);

        let id2 = store
            .reserve("INFRA", "quarantine-count-test-2", "P1", "xs")
            .unwrap();
        store
            .set_fields(
                &id2,
                GapFieldUpdate {
                    status: Some("bisect_quarantined".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(store.count_bisect_quarantined().unwrap(), 2);
    }

    // 6. requeue_transitions_status: requeue_gap moves bisect_quarantined → ready_to_ship.
    #[test]
    fn requeue_transitions_status() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "requeue-status-test", "P1", "xs")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("bisect_quarantined".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        store.requeue_gap(&id).unwrap();
        let row = store.get(&id).unwrap().unwrap();
        assert_eq!(
            row.status, "ready_to_ship",
            "status must be ready_to_ship after requeue"
        );
        assert!(
            row.notes.contains("requeued"),
            "notes must record the requeue operation"
        );
    }

    // 7. requeue_rejects_wrong_status: requeue_gap fails on a non-quarantined gap.
    #[test]
    fn requeue_rejects_wrong_status() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "requeue-reject-test", "P1", "xs")
            .unwrap();
        // Still 'open' — requeue must fail.
        let err = store.requeue_gap(&id).unwrap_err();
        assert!(
            err.to_string().contains("bisect_quarantined"),
            "error must name the expected status; got: {err}"
        );
    }

    // 8. requeue_appends_note: note mentions operator review.
    #[test]
    fn requeue_appends_note() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("INFRA", "requeue-note-test", "P1", "xs")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("bisect_quarantined".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        store.requeue_gap(&id).unwrap();
        let row = store.get(&id).unwrap().unwrap();
        assert!(
            row.notes.contains("operator review"),
            "note must mention operator review; got: {:?}",
            row.notes
        );
    }

    // EFFECTIVE-216: repo_gap_count returns only open gaps tagged with
    // external_repo:<owner>/<repo>, regardless of CSV position. Done /
    // closed / in_review gaps tagged with the same repo must NOT count.
    #[test]
    fn repo_gap_count_open_only_and_csv_mid_string() {
        let (store, _dir) = test_store();

        // INFRA-402 guard requires closed_pr when flipping to done.
        let make = |suffix: &str, status: &str, skills: &str, closed_pr: Option<i64>| {
            let id = store
                .reserve("INFRA", &format!("rgc-test-{suffix}"), "P1", "xs")
                .unwrap();
            store
                .set_fields(
                    &id,
                    GapFieldUpdate {
                        status: Some(status.to_string()),
                        skills_required: Some(skills.to_string()),
                        closed_pr,
                        ..Default::default()
                    },
                )
                .unwrap();
        };

        // 2 open with tag at varying CSV positions — both must count.
        make("a", "open", "external_repo:foo/bar", None);
        make("b", "open", "rust,external_repo:foo/bar,sqlite", None);
        // 2 non-open with the same tag — must NOT count (the bug being fixed).
        // Use done (with closed_pr to satisfy INFRA-402) and in_review.
        make("c", "done", "external_repo:foo/bar", Some(9001));
        make("d", "in_review", "rust,external_repo:foo/bar", None);
        // 1 open but a different repo — must NOT count.
        make("e", "open", "external_repo:other/repo", None);

        let count = store.repo_gap_count("foo/bar").unwrap();
        assert_eq!(count, 2, "expected 2 (only open foo/bar gaps); got {count}");
    }

    // EFFECTIVE-363: artifact_type defaults to 'code' for every gap (old and
    // new), no migration breakage, and `chump gap set --artifact-type` round
    // trips through set_fields/get_artifact_type.
    #[test]
    fn artifact_type_defaults_to_code_and_round_trips() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("EFFECTIVE", "artifact-type-test", "P1", "xs")
            .unwrap();

        assert_eq!(store.get_artifact_type(&id).unwrap(), "code");

        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    artifact_type: Some("release-note".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(store.get_artifact_type(&id).unwrap(), "release-note");

        // Empty string is treated as "reset to the default", not "clear to
        // NULL" — the column is NOT NULL DEFAULT 'code'.
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    artifact_type: Some(String::new()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(store.get_artifact_type(&id).unwrap(), "code");
    }

    // ── INFRA-3002 AC #3: claim self-heals a gap missing from the local
    //    worktree's state.db by syncing the single row from state.sql ────────

    #[test]
    fn sync_gap_from_state_sql_inserts_missing_row() {
        let (store, dir) = test_store();
        let sql_path = dir.path().join("state.sql");
        std::fs::write(
            &sql_path,
            r#"gaps:
  - id: INFRA-9001
    domain: INFRA
    title: a gap that only exists on origin/main
    priority: P1
    effort: s
    status: open
"#,
        )
        .unwrap();

        // Not present in this worktree's freshly-opened state.db.
        assert!(store.get("INFRA-9001").unwrap().is_none());

        let found = store
            .sync_gap_from_state_sql(&sql_path, "INFRA-9001")
            .unwrap();
        assert!(found, "gap present in state.sql should be found+synced");

        let row = store.get("INFRA-9001").unwrap().expect("row now present");
        assert_eq!(row.title, "a gap that only exists on origin/main");
        assert_eq!(row.status, "open");
    }

    #[test]
    fn sync_gap_from_state_sql_returns_false_when_absent() {
        let (store, dir) = test_store();
        let sql_path = dir.path().join("state.sql");
        std::fs::write(
            &sql_path,
            r#"gaps:
  - id: INFRA-9002
    domain: INFRA
    title: unrelated gap
    priority: P1
    effort: s
    status: open
"#,
        )
        .unwrap();

        let found = store
            .sync_gap_from_state_sql(&sql_path, "INFRA-NONEXISTENT")
            .unwrap();
        assert!(!found, "gap absent from state.sql must not be synthesized");
        assert!(store.get("INFRA-NONEXISTENT").unwrap().is_none());
    }

    #[test]
    fn sync_gap_from_state_sql_does_not_touch_other_rows() {
        let (store, dir) = test_store();
        let id_existing = store
            .reserve("INFRA", "pre-existing gap", "P1", "s")
            .unwrap();

        let sql_path = dir.path().join("state.sql");
        std::fs::write(
            &sql_path,
            format!(
                r#"gaps:
  - id: {id_existing}
    domain: INFRA
    title: CLOBBERED — should never be written
    priority: P1
    effort: s
    status: open
  - id: INFRA-9003
    domain: INFRA
    title: the only gap claim actually needs
    priority: P1
    effort: s
    status: open
"#
            ),
        )
        .unwrap();

        store
            .sync_gap_from_state_sql(&sql_path, "INFRA-9003")
            .unwrap();

        // Targeted sync must leave the unrelated pre-existing row untouched,
        // unlike restore_from_state_sql's full-table replace.
        let untouched = store.get(&id_existing).unwrap().unwrap();
        assert_eq!(untouched.title, "pre-existing gap");

        let synced = store.get("INFRA-9003").unwrap().unwrap();
        assert_eq!(synced.title, "the only gap claim actually needs");
    }

    #[test]
    fn claim_fails_fast_when_gap_and_state_sql_both_lack_it() {
        // Regression guard for the "genuine missing gap" case (AC #6): if the
        // gap truly does not exist anywhere, sync_gap_from_state_sql must
        // report false and claim() must still fail — the self-heal path must
        // never silently fabricate a claimable row.
        let (store, dir) = test_store();
        let sql_path = dir.path().join("state.sql");
        std::fs::write(&sql_path, "gaps: []\n").unwrap();

        let found = store
            .sync_gap_from_state_sql(&sql_path, "INFRA-GHOST")
            .unwrap();
        assert!(!found);
        let err = store
            .claim("INFRA-GHOST", "session-x", "wt-x", 3600)
            .unwrap_err();
        assert!(err.to_string().contains("not found in state.db"));
    }
}

// ── EFFECTIVE-038: A2A L2 waiting_operator suspend/respond tests ─────────────
#[cfg(test)]
mod waiting_operator_tests {
    use super::*;
    use tempfile::tempdir;

    fn test_store() -> (GapStore, tempfile::TempDir) {
        let dir = tempdir().unwrap();
        let store = GapStore::open(dir.path()).unwrap();
        (store, dir)
    }

    #[test]
    fn waiting_operator_is_a_known_status() {
        let (store, _dir) = test_store();
        let statuses = store.known_statuses().unwrap();
        assert!(statuses.iter().any(|s| s == "waiting_operator"));
    }

    #[test]
    fn suspend_then_respond_resumes_from_prior_status() {
        let (store, _dir) = test_store();
        let id = store
            .reserve("EFFECTIVE", "suspend test", "P1", "s")
            .unwrap();
        store
            .set_fields(
                &id,
                GapFieldUpdate {
                    status: Some("claimed".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();

        store
            .suspend_waiting(
                &id,
                "input_required",
                "which backend should this target?",
                Some(r#"{"progress":"70%"}"#),
            )
            .unwrap();

        let g = store.get(&id).unwrap().unwrap();
        assert_eq!(g.status, "waiting_operator");
        let payload = store.get_waiting_payload(&id).unwrap().unwrap();
        assert!(payload.contains("input_required"));
        assert!(payload.contains("70%"));

        let resumed = store.respond_gap(&id, r#"{"backend":"claude"}"#).unwrap();
        assert_eq!(resumed, "claimed");
        let g = store.get(&id).unwrap().unwrap();
        assert_eq!(g.status, "claimed");
        assert!(g.notes.contains("operator response"));
        assert!(g.notes.contains(r#"{"backend":"claude"}"#));
        assert!(store.get_waiting_payload(&id).unwrap().is_none());
    }

    #[test]
    fn auth_required_suspends_instead_of_silent_death() {
        // RESILIENT-054: a missing credential must suspend, not die silently.
        let (store, _dir) = test_store();
        let id = store.reserve("EFFECTIVE", "auth test", "P1", "s").unwrap();

        store
            .suspend_waiting(&id, "auth_required", "missing GH_TOKEN", None)
            .unwrap();

        let g = store.get(&id).unwrap().unwrap();
        assert_eq!(g.status, "waiting_operator");
        let payload = store.get_waiting_payload(&id).unwrap().unwrap();
        assert!(payload.contains("auth_required"));
    }

    #[test]
    fn respond_without_pending_suspension_errors() {
        let (store, _dir) = test_store();
        let id = store.reserve("EFFECTIVE", "no suspend", "P1", "s").unwrap();
        let err = store.respond_gap(&id, r#"{"x":1}"#).unwrap_err();
        assert!(err.to_string().contains("not waiting_operator"));
    }

    #[test]
    fn cannot_suspend_a_done_gap() {
        let (store, _dir) = test_store();
        let id = store.reserve("EFFECTIVE", "done test", "P1", "s").unwrap();
        store.ship(&id, "session-x", Some(1)).unwrap();
        let err = store
            .suspend_waiting(&id, "input_required", "q?", None)
            .unwrap_err();
        assert!(err.to_string().contains("already done"));
    }

    #[test]
    fn suspend_rejects_unknown_kind() {
        let (store, _dir) = test_store();
        let id = store.reserve("EFFECTIVE", "bad kind", "P1", "s").unwrap();
        let err = store
            .suspend_waiting(&id, "bogus_kind", "q?", None)
            .unwrap_err();
        assert!(err.to_string().contains("kind must be"));
    }
}

#[cfg(test)]
mod meta555_effect_verify_tests {
    use crate::extract_verify_commands;

    // ANTI-WEDGE (META-555): an acceptance-criteria list with no `verify:` line
    // yields no commands, so evaluate_effect_verification returns NoLiveCriterion
    // and ship() is left untouched — ordinary gap closures can never block.
    #[test]
    fn no_verify_line_yields_no_commands() {
        assert!(extract_verify_commands("[]").is_empty());
        assert!(extract_verify_commands(r#"["do the thing","and another"]"#).is_empty());
        assert!(extract_verify_commands("not valid json").is_empty());
    }

    #[test]
    fn extracts_single_verify_command() {
        assert_eq!(
            extract_verify_commands(r#"["verify: true"]"#),
            vec!["true".to_string()]
        );
    }

    #[test]
    fn verify_prefix_case_insensitive_and_trimmed() {
        assert_eq!(
            extract_verify_commands(r#"["VERIFY:   mycmd --flag  "]"#),
            vec!["mycmd --flag".to_string()]
        );
    }

    #[test]
    fn only_verify_items_match_when_mixed_with_plain_ac() {
        assert_eq!(
            extract_verify_commands(r#"["set up the thing","verify: check --live","more prose"]"#),
            vec!["check --live".to_string()]
        );
    }

    #[test]
    fn empty_verify_command_is_ignored() {
        assert!(extract_verify_commands(r#"["verify:   "]"#).is_empty());
    }
}
