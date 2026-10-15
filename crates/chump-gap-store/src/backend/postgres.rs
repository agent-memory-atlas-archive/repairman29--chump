//! Postgres implementation of [`super::GapBackend`] — INFRA-2092.
//!
//! Opt-in only (`postgres-backend` Cargo feature). SQLite
//! ([`super::sqlite::SqliteBackend`]) remains the local-dev default; this
//! exists to break the single-node ceiling identified in INFRA-1967 (C4)
//! for fleets that need shared state across machines.
//!
//! Same `gaps` table shape as the SQLite backend, translated to Postgres
//! types (`BIGINT` for unix-epoch columns, `TEXT` elsewhere — no
//! Postgres-only features used, so the schema stays easy to reason about
//! across both engines).

use super::GapBackend;
use crate::GapRow;
use anyhow::{Context, Result};
use postgres::{Client, NoTls};
use std::sync::Mutex;

pub struct PostgresBackend {
    client: Mutex<Client>,
}

impl PostgresBackend {
    /// `conn_str` is a standard libpq connection string, e.g.
    /// `host=localhost user=chump dbname=chump_state`.
    pub fn open(conn_str: &str) -> Result<Self> {
        let client =
            Client::connect(conn_str, NoTls).with_context(|| "connecting to postgres backend")?;
        let backend = Self {
            client: Mutex::new(client),
        };
        backend.init_schema()?;
        Ok(backend)
    }

    /// Applies the shared-fleet queue schema (INFRA-3631 slice, INFRA-5402)
    /// — `shared_gaps`, `shared_claims`, `worker_capabilities` — the same
    /// tables/types/constraints checked into
    /// `supabase/migrations/0001_team_foundation.sql` +
    /// `0002_shared_gaps.sql`, minus the RLS policies (self-hosted Postgres
    /// has no Supabase Auth to satisfy `auth.uid()`; the substrate installer
    /// disables RLS on these tables separately).
    ///
    /// Every statement is `CREATE ... IF NOT EXISTS` (or otherwise
    /// idempotent — `COMMENT ON TABLE` just resets to the same value), so
    /// re-running against an already-initialized DB is a clean no-op.
    pub fn init_shared_schema(&self) -> Result<()> {
        let mut client = self.client.lock().expect("postgres backend mutex poisoned");
        client
            .batch_execute(
                "
            CREATE EXTENSION IF NOT EXISTS \"pgcrypto\";

            CREATE TABLE IF NOT EXISTS teams (
                id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                name            TEXT NOT NULL,
                slug            TEXT UNIQUE NOT NULL,
                created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                tier            TEXT NOT NULL DEFAULT 'free'
                    CHECK (tier IN ('free', 'team', 'enterprise')),
                self_hosted_url TEXT,
                deleted_at      TIMESTAMPTZ
            );

            CREATE TABLE IF NOT EXISTS shared_gaps (
                id                  TEXT PRIMARY KEY,
                team_id             UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                title               TEXT NOT NULL,
                domain              TEXT NOT NULL,
                priority            TEXT NOT NULL
                    CHECK (priority IN ('P0', 'P1', 'P2', 'P3')),
                effort              TEXT NOT NULL
                    CHECK (effort IN ('xs', 's', 'm', 'l')),
                status              TEXT NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open', 'claimed', 'shipped', 'superseded', 'blocked')),
                description         TEXT,
                acceptance_criteria TEXT,
                notes               TEXT,
                skills_required     JSONB DEFAULT '[]'::jsonb,
                preferred_machine   TEXT,
                depends_on          JSONB DEFAULT '[]'::jsonb,
                created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                created_by_user_id  UUID NOT NULL,
                updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                shipped_at          TIMESTAMPTZ,
                closed_pr           INT
            );
            CREATE INDEX IF NOT EXISTS shared_gaps_team_status_idx ON shared_gaps (team_id, status);
            CREATE INDEX IF NOT EXISTS shared_gaps_priority_idx ON shared_gaps (team_id, priority)
                WHERE status = 'open';
            COMMENT ON TABLE shared_gaps IS
                'Team-shared work queue. Each row is a gap any team operator can claim.';

            CREATE TABLE IF NOT EXISTS shared_claims (
                id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                gap_id           TEXT NOT NULL REFERENCES shared_gaps(id) ON DELETE CASCADE,
                team_id          UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                operator_user_id UUID NOT NULL,
                worker_machine   TEXT NOT NULL,
                session_id       TEXT NOT NULL,
                claimed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                expires_at       TIMESTAMPTZ NOT NULL,
                released_at      TIMESTAMPTZ,
                release_reason   TEXT
                    CHECK (release_reason IN ('shipped', 'aborted', 'expired', 'evicted'))
            );
            -- THE CAS GUARANTEE: at most one active claim per gap (partial
            -- unique index — enforces uniqueness only while released_at IS NULL).
            CREATE UNIQUE INDEX IF NOT EXISTS shared_claims_active_unique
                ON shared_claims (gap_id)
                WHERE released_at IS NULL;
            CREATE INDEX IF NOT EXISTS shared_claims_team_active_idx
                ON shared_claims (team_id, claimed_at DESC)
                WHERE released_at IS NULL;
            COMMENT ON TABLE shared_claims IS
                'Lease records for shared_gaps. Partial unique index enforces atomic claim.';

            CREATE TABLE IF NOT EXISTS worker_capabilities (
                team_id            UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                user_id            UUID NOT NULL,
                machine            TEXT NOT NULL,
                skills             JSONB NOT NULL DEFAULT '[]'::jsonb,
                backend            TEXT NOT NULL DEFAULT 'claude'
                    CHECK (backend IN ('claude', 'opencode', 'codex', 'manual')),
                max_concurrent_gaps INT NOT NULL DEFAULT 2,
                max_concurrent_cargo_jobs INT NOT NULL DEFAULT 4,
                last_heartbeat_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (team_id, user_id, machine)
            );
            CREATE INDEX IF NOT EXISTS worker_capabilities_team_idx ON worker_capabilities (team_id);
            COMMENT ON TABLE worker_capabilities IS
                'Per-machine capability registry. Push-routing matches gaps to capable workers.';
            ",
            )
            .context("init_shared_schema: create shared_gaps/shared_claims/worker_capabilities")?;
        Ok(())
    }
}

impl GapBackend for PostgresBackend {
    fn init_schema(&self) -> Result<()> {
        let mut client = self.client.lock().expect("postgres backend mutex poisoned");
        client
            .batch_execute(
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
                created_at          BIGINT NOT NULL DEFAULT 0,
                closed_at           BIGINT,
                opened_date         TEXT NOT NULL DEFAULT '',
                closed_date         TEXT NOT NULL DEFAULT '',
                closed_pr           BIGINT,
                skills_required     TEXT NOT NULL DEFAULT '',
                preferred_backend   TEXT NOT NULL DEFAULT 'any',
                preferred_machine   TEXT NOT NULL DEFAULT 'any',
                estimated_minutes   TEXT NOT NULL DEFAULT '',
                required_model      TEXT NOT NULL DEFAULT 'any',
                shipped_in          TEXT,
                outcome_id          TEXT,
                evidence            TEXT
            );
            CREATE INDEX IF NOT EXISTS gaps_status ON gaps(status);
            ",
            )
            .context("init_schema: create gaps table")?;
        Ok(())
    }

    fn upsert_gap(&self, gap: &GapRow) -> Result<()> {
        let mut client = self.client.lock().expect("postgres backend mutex poisoned");
        client
            .execute(
                "INSERT INTO gaps (
                    id, domain, title, description, priority, effort, status,
                    acceptance_criteria, depends_on, notes, source_doc, created_at,
                    closed_at, opened_date, closed_date, closed_pr, skills_required,
                    preferred_backend, preferred_machine, estimated_minutes,
                    required_model, shipped_in, outcome_id, evidence
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
                    $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24
                )
                ON CONFLICT (id) DO UPDATE SET
                    domain=excluded.domain, title=excluded.title,
                    description=excluded.description, priority=excluded.priority,
                    effort=excluded.effort, status=excluded.status,
                    acceptance_criteria=excluded.acceptance_criteria,
                    depends_on=excluded.depends_on, notes=excluded.notes,
                    source_doc=excluded.source_doc, created_at=excluded.created_at,
                    closed_at=excluded.closed_at, opened_date=excluded.opened_date,
                    closed_date=excluded.closed_date, closed_pr=excluded.closed_pr,
                    skills_required=excluded.skills_required,
                    preferred_backend=excluded.preferred_backend,
                    preferred_machine=excluded.preferred_machine,
                    estimated_minutes=excluded.estimated_minutes,
                    required_model=excluded.required_model,
                    shipped_in=excluded.shipped_in, outcome_id=excluded.outcome_id,
                    evidence=excluded.evidence",
                &[
                    &gap.id,
                    &gap.domain,
                    &gap.title,
                    &gap.description,
                    &gap.priority,
                    &gap.effort,
                    &gap.status,
                    &gap.acceptance_criteria,
                    &gap.depends_on,
                    &gap.notes,
                    &gap.source_doc,
                    &gap.created_at,
                    &gap.closed_at,
                    &gap.opened_date,
                    &gap.closed_date,
                    &gap.closed_pr,
                    &gap.skills_required,
                    &gap.preferred_backend,
                    &gap.preferred_machine,
                    &gap.estimated_minutes,
                    &gap.required_model,
                    &gap.shipped_in,
                    &gap.outcome_id,
                    &gap.evidence,
                ],
            )
            .context("upsert_gap")?;
        Ok(())
    }

    fn get_gap(&self, id: &str) -> Result<Option<GapRow>> {
        let mut client = self.client.lock().expect("postgres backend mutex poisoned");
        let row = client
            .query_opt(
                "SELECT id, domain, title, description, priority, effort, status,
                        acceptance_criteria, depends_on, notes, source_doc, created_at,
                        closed_at, opened_date, closed_date, closed_pr, skills_required,
                        preferred_backend, preferred_machine, estimated_minutes,
                        required_model, shipped_in, outcome_id, evidence
                 FROM gaps WHERE id = $1",
                &[&id],
            )
            .context("get_gap")?;
        Ok(row.map(|r| row_to_gap(&r)))
    }

    fn list_gaps_by_status(&self, status: &str) -> Result<Vec<GapRow>> {
        let mut client = self.client.lock().expect("postgres backend mutex poisoned");
        let rows = client
            .query(
                "SELECT id, domain, title, description, priority, effort, status,
                        acceptance_criteria, depends_on, notes, source_doc, created_at,
                        closed_at, opened_date, closed_date, closed_pr, skills_required,
                        preferred_backend, preferred_machine, estimated_minutes,
                        required_model, shipped_in, outcome_id, evidence
                 FROM gaps WHERE status = $1 ORDER BY id",
                &[&status],
            )
            .context("list_gaps_by_status")?;
        Ok(rows.iter().map(row_to_gap).collect())
    }

    fn delete_gap(&self, id: &str) -> Result<()> {
        let mut client = self.client.lock().expect("postgres backend mutex poisoned");
        client
            .execute("DELETE FROM gaps WHERE id = $1", &[&id])
            .context("delete_gap")?;
        Ok(())
    }
}

fn row_to_gap(row: &postgres::Row) -> GapRow {
    GapRow {
        id: row.get(0),
        domain: row.get(1),
        title: row.get(2),
        description: row.get(3),
        priority: row.get(4),
        effort: row.get(5),
        status: row.get(6),
        acceptance_criteria: row.get(7),
        depends_on: row.get(8),
        notes: row.get(9),
        source_doc: row.get(10),
        created_at: row.get(11),
        closed_at: row.get(12),
        opened_date: row.get(13),
        closed_date: row.get(14),
        closed_pr: row.get(15),
        skills_required: row.get(16),
        preferred_backend: row.get(17),
        preferred_machine: row.get(18),
        estimated_minutes: row.get(19),
        required_model: row.get(20),
        shipped_in: row.get(21),
        outcome_id: row.get(22),
        evidence: row.get(23),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::tests::exercise_backend_contract;

    /// Requires a live Postgres reachable via `CHUMP_TEST_POSTGRES_URL`
    /// (e.g. `postgres://chump:chump@localhost:5432/chump_test`). Skips
    /// (rather than fails) when unset — no Postgres is provisioned in the
    /// default sandbox/CI image, so this is opt-in verification for anyone
    /// standing up the backend for real, not a gate on every CI run.
    #[test]
    fn postgres_backend_satisfies_contract() {
        let Ok(url) = std::env::var("CHUMP_TEST_POSTGRES_URL") else {
            eprintln!(
                "skipping postgres_backend_satisfies_contract: CHUMP_TEST_POSTGRES_URL not set"
            );
            return;
        };
        let backend = PostgresBackend::open(&url).expect("open postgres backend");
        // Best-effort cleanup so repeat runs against a persistent test DB
        // start from a known state.
        backend.delete_gap("INFRA-9999").ok();
        backend.delete_gap("INFRA-9998").ok();
        exercise_backend_contract(&backend).expect("contract");
    }
}
