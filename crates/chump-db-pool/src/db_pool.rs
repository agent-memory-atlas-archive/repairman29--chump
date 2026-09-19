//! Shared SQLite connection pool for chump_memory.db (WAL + busy_timeout).
//! Intended for 24/7 concurrent access: heartbeats, Discord, and web API share the pool
//! to avoid database locks. All DB modules use this pool instead of opening a connection per call.

use anyhow::Result;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use std::path::PathBuf;
use std::sync::OnceLock;

pub type PooledConn = r2d2::PooledConnection<SqliteConnectionManager>;

static POOL: OnceLock<Pool<SqliteConnectionManager>> = OnceLock::new();

fn chump_memory_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_MEMORY_DB_PATH") {
        return PathBuf::from(p);
    }
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("sessions/chump_memory.db")
}

/// Run all table schemas and migrations for chump_memory.db (shared by all modules).
fn init_schema(conn: &rusqlite::Connection) -> Result<()> {
    conn.execute_batch(
        "
        -- state_db
        CREATE TABLE IF NOT EXISTS chump_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- task_db
        CREATE TABLE IF NOT EXISTS chump_tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            repo TEXT,
            issue_number INTEGER,
            status TEXT DEFAULT 'open',
            notes TEXT,
            priority INTEGER DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
        );
        -- episode_db
        CREATE TABLE IF NOT EXISTS chump_episodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            happened_at TEXT NOT NULL DEFAULT (datetime('now')),
            summary TEXT NOT NULL,
            detail TEXT,
            tags TEXT,
            repo TEXT,
            sentiment TEXT CHECK(sentiment IN ('win','loss','neutral','frustrating','uncertain')),
            pr_number INTEGER,
            issue_number INTEGER
        );
        -- schedule_db
        CREATE TABLE IF NOT EXISTS chump_scheduled (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fire_at TEXT NOT NULL,
            prompt TEXT NOT NULL,
            context TEXT,
            fired INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_chump_scheduled_fire ON chump_scheduled (fired, fire_at);
        -- ask_jeff_db
        CREATE TABLE IF NOT EXISTS chump_questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question TEXT NOT NULL,
            context TEXT,
            priority TEXT DEFAULT 'curious',
            asked_at TEXT DEFAULT (datetime('now')),
            answered_at TEXT,
            answer TEXT
        );
        -- tool_health_db
        CREATE TABLE IF NOT EXISTS chump_tool_health (
            tool TEXT PRIMARY KEY,
            status TEXT DEFAULT 'ok',
            last_error TEXT,
            last_checked TEXT,
            failure_count INTEGER DEFAULT 0
        );
        -- introspect_tool: ring buffer of recent tool invocations (capped at 200 rows)
        CREATE TABLE IF NOT EXISTS chump_tool_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool TEXT NOT NULL,
            args_snippet TEXT,
            outcome TEXT NOT NULL DEFAULT 'ok',
            called_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_chump_tool_calls_called ON chump_tool_calls (called_at DESC);
        -- memory_db
        CREATE TABLE IF NOT EXISTS chump_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            ts TEXT NOT NULL,
            source TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            content,
            content='chump_memory',
            content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON chump_memory BEGIN
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE ON chump_memory BEGIN
            INSERT INTO memory_fts(memory_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
        END;
        -- web_sessions_db (PWA Tier 2 Phase 1.1)
        CREATE TABLE IF NOT EXISTS chump_web_sessions (
            id TEXT PRIMARY KEY,
            bot TEXT NOT NULL DEFAULT 'chump',
            title TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_web_sessions_updated ON chump_web_sessions(bot, updated_at DESC);
        CREATE TABLE IF NOT EXISTS chump_web_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
            content TEXT NOT NULL,
            tool_calls_json TEXT,
            attachments_json TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_web_messages_session ON chump_web_messages(session_id, created_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS web_messages_fts USING fts5(
            content,
            content='chump_web_messages',
            content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_insert AFTER INSERT ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_delete AFTER DELETE ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(web_messages_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_update AFTER UPDATE ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(web_messages_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO web_messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        -- web_uploads (PWA Tier 2 Phase 1.2)
        CREATE TABLE IF NOT EXISTS chump_web_uploads (
            file_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT,
            size_bytes INTEGER NOT NULL,
            storage_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_web_uploads_session ON chump_web_uploads(session_id);
        -- repo allowlist (Phase 2c): dynamic authorize/deauthorize in addition to CHUMP_GITHUB_REPOS
        CREATE TABLE IF NOT EXISTS chump_authorized_repos (
            repo TEXT PRIMARY KEY,
            added_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- provider_quality (Phase 3a/5c): per-slot success/sanity_fail, latency (EMA), tool_call_accuracy
        CREATE TABLE IF NOT EXISTS chump_provider_quality (
            slot_name TEXT PRIMARY KEY,
            success_count INTEGER NOT NULL DEFAULT 0,
            sanity_fail_count INTEGER NOT NULL DEFAULT 0,
            last_updated TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- push subscriptions (PWA Tier 2 Phase 3.1)
        CREATE TABLE IF NOT EXISTS chump_push_subscriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint TEXT NOT NULL UNIQUE,
            p256dh TEXT,
            auth TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- prediction_log (Synthetic Consciousness Phase 1: surprise tracking)
        CREATE TABLE IF NOT EXISTS chump_prediction_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool TEXT NOT NULL,
            outcome TEXT NOT NULL,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            surprisal REAL NOT NULL DEFAULT 0.0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_prediction_log_tool ON chump_prediction_log (tool, recorded_at DESC);
        -- memory_graph (Synthetic Consciousness Phase 2: associative memory)
        CREATE TABLE IF NOT EXISTS chump_memory_graph (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subject TEXT NOT NULL,
            relation TEXT NOT NULL,
            object TEXT NOT NULL,
            source_memory_id INTEGER,
            source_episode_id INTEGER,
            weight REAL NOT NULL DEFAULT 1.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_memory_graph_subject ON chump_memory_graph (subject);
        CREATE INDEX IF NOT EXISTS idx_memory_graph_object ON chump_memory_graph (object);
        -- causal_lessons (Synthetic Consciousness Phase 4: counterfactual reasoning)
        CREATE TABLE IF NOT EXISTS chump_causal_lessons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_type TEXT,
            action_taken TEXT NOT NULL,
            alternative TEXT,
            lesson TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5,
            times_applied INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_causal_lessons_type ON chump_causal_lessons (task_type);
        -- blackboard_persist (Synthetic Consciousness: cross-session blackboard continuity)
        CREATE TABLE IF NOT EXISTS chump_blackboard_persist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            content TEXT NOT NULL,
            salience REAL NOT NULL DEFAULT 0.0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_bb_persist_salience ON chump_blackboard_persist (salience DESC);
        -- MEM-005: episode extractor cursor — tracks last processed episode_id
        CREATE TABLE IF NOT EXISTS chump_blackboard_cursor (
            id INTEGER PRIMARY KEY,
            last_episode_id INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        -- Seed the singleton cursor row so it's always present.
        INSERT OR IGNORE INTO chump_blackboard_cursor (id, last_episode_id) VALUES (1, 0);
        -- consciousness_metrics (per-session phi/surprisal for correlation tracking)
        CREATE TABLE IF NOT EXISTS chump_consciousness_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            phi_proxy REAL NOT NULL DEFAULT 0.0,
            surprisal_ema REAL NOT NULL DEFAULT 0.0,
            coupling_score REAL NOT NULL DEFAULT 0.0,
            regime TEXT,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS chump_turn_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            turn_number INTEGER NOT NULL DEFAULT 0,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            tokens_spent INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            regime TEXT,
            surprisal_ema REAL NOT NULL DEFAULT 0.0,
            dissipation_rate REAL NOT NULL DEFAULT 0.0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_turn_metrics_session ON chump_turn_metrics (session_id);
        -- Vector 3: automated battle / benchmark baselines (telemetry snapshots)
        CREATE TABLE IF NOT EXISTS chump_battle_baselines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL DEFAULT (datetime('now')),
            label TEXT NOT NULL,
            turns_to_resolution INTEGER NOT NULL DEFAULT 0,
            total_tool_errors INTEGER NOT NULL DEFAULT 0,
            resolution_duration_ms INTEGER NOT NULL DEFAULT 0,
            reply_contains_done INTEGER NOT NULL DEFAULT 0,
            extra_json TEXT
        );
        -- async job log (P2.2): autonomy runs, future server-triggered work
        CREATE TABLE IF NOT EXISTS chump_async_jobs (
            id TEXT PRIMARY KEY,
            job_type TEXT NOT NULL,
            status TEXT NOT NULL,
            task_id INTEGER,
            session_id TEXT,
            last_error TEXT,
            detail TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_async_jobs_updated ON chump_async_jobs (updated_at DESC);
        -- Session checkpoints (conversation-level rollback, Phase 1.6 of Hermes roadmap)
        CREATE TABLE IF NOT EXISTS chump_checkpoints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            name TEXT NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0,
            state_snapshot_json TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            notes TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON chump_checkpoints(session_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_checkpoints_name ON chump_checkpoints(session_id, name);
        -- Procedural skills (Phase 1.1 of Hermes roadmap): reliability tracking for on-disk SKILL.md files.
        CREATE TABLE IF NOT EXISTS chump_skills (
            name TEXT PRIMARY KEY,
            description TEXT NOT NULL DEFAULT '',
            version INTEGER NOT NULL DEFAULT 1,
            category TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]',
            use_count INTEGER NOT NULL DEFAULT 0,
            success_count INTEGER NOT NULL DEFAULT 0,
            failure_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_used_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_skills_category ON chump_skills(category);
        CREATE INDEX IF NOT EXISTS idx_skills_last_used ON chump_skills(last_used_at DESC);
        -- Fleet coordination (Phase 3.1 of Hermes roadmap): peer registry + dispatch log.
        CREATE TABLE IF NOT EXISTS chump_fleet_peers (
            peer_id TEXT PRIMARY KEY,
            role TEXT NOT NULL,
            capabilities_json TEXT NOT NULL DEFAULT '[]',
            endpoint TEXT,
            status TEXT NOT NULL DEFAULT 'unknown',
            last_seen_unix INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            registered_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_fleet_peers_role ON chump_fleet_peers(role);
        CREATE INDEX IF NOT EXISTS idx_fleet_peers_status ON chump_fleet_peers(status);
        CREATE TABLE IF NOT EXISTS chump_fleet_dispatches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            from_peer TEXT NOT NULL,
            to_peer TEXT,
            task_description TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            completed_at TEXT,
            result TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_fleet_dispatches_status ON chump_fleet_dispatches(status, priority DESC);
        -- COG-006: Structured reflections (GEPA-inspired) per task/episode + extracted
        -- improvement targets. Targets are queried on the next task to surface lessons
        -- via the system prompt ('Lessons from prior episodes' block). Two tables so
        -- targets can be filtered/scored independently of the parent reflection record.
        CREATE TABLE IF NOT EXISTS chump_reflections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_id INTEGER,
            intended_goal TEXT NOT NULL DEFAULT '',
            observed_outcome TEXT NOT NULL DEFAULT '',
            outcome_class TEXT NOT NULL DEFAULT 'failure',
            error_pattern TEXT,
            hypothesis TEXT NOT NULL DEFAULT '',
            surprisal_at_reflect REAL,
            confidence_at_reflect REAL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_reflections_created ON chump_reflections(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_reflections_pattern ON chump_reflections(error_pattern);
        CREATE TABLE IF NOT EXISTS chump_improvement_targets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reflection_id INTEGER NOT NULL,
            directive TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'medium',
            scope TEXT,
            actioned_as TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            FOREIGN KEY (reflection_id) REFERENCES chump_reflections(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_improve_priority ON chump_improvement_targets(priority, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_improve_scope ON chump_improvement_targets(scope);
        ",
    )?;
    // provider_quality Phase 5c: latency and tool_call_accuracy columns
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN latency_ms_p50 REAL DEFAULT NULL",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN latency_ms_p95 REAL DEFAULT NULL",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN tool_call_accuracy REAL DEFAULT NULL",
        [],
    );
    // CREDIBLE-227: track 429 (rate-limited) responses separately from generic
    // failures so declared RPD ceilings can be compared against observed
    // rate-limit evidence (a slot 429ing well under its declared cap is
    // evidence the declared number is wrong).
    let _ = conn.execute(
        "ALTER TABLE chump_provider_quality ADD COLUMN rate_limited_count INTEGER NOT NULL DEFAULT 0",
        [],
    );
    // task_db migrations (add columns if missing)
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN priority INTEGER DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN assignee TEXT DEFAULT 'chump'",
        [],
    );
    // episode_db Phase 4: counterfactual reasoning columns
    let _ = conn.execute(
        "ALTER TABLE chump_episodes ADD COLUMN action_taken TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_episodes ADD COLUMN alternatives_considered TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_episodes ADD COLUMN counterfactual_analysis TEXT",
        [],
    );
    // TaskPlanner: ordered steps within a plan group (Vector 2 state machine).
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN planner_group_id TEXT",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN planner_step INTEGER DEFAULT 0",
        [],
    );
    // Task dependency DAGs: JSON array of task IDs, e.g. "[3, 5]"
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN depends_on TEXT DEFAULT '[]'",
        [],
    );
    // Task lease fields (distributed locking for autonomy loop)
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN lease_owner TEXT", []);
    let _ = conn.execute("ALTER TABLE chump_tasks ADD COLUMN lease_token TEXT", []);
    let _ = conn.execute(
        "ALTER TABLE chump_tasks ADD COLUMN lease_expires_at INTEGER DEFAULT 0",
        [],
    );
    // Parent checkpoint for session branching (forward reference; default NULL)
    let _ = conn.execute(
        "ALTER TABLE chump_web_sessions ADD COLUMN parent_checkpoint_id INTEGER",
        [],
    );
    // Session-level analytics (G7)
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_session_metrics (
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL DEFAULT 0,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            narration_count INTEGER NOT NULL DEFAULT 0,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            satisfaction INTEGER DEFAULT NULL,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (session_id, turn_index)
        );
        CREATE INDEX IF NOT EXISTS idx_session_metrics_time ON chump_session_metrics(recorded_at DESC);
        ",
    )?;
    // Message-level feedback (thumbs up/down)
    let _ = conn.execute(
        "ALTER TABLE chump_web_messages ADD COLUMN feedback INTEGER DEFAULT NULL",
        [],
    );
    // Web chat: optional model `<thinking>` monologue for this assistant message (not shown in default UI).
    let _ = conn.execute(
        "ALTER TABLE chump_web_messages ADD COLUMN thinking_monologue TEXT",
        [],
    );
    // Web chat: user feedback on messages (-1 = thumbs down, 0 = neutral, 1 = thumbs up).
    let _ = conn.execute(
        "ALTER TABLE chump_web_messages ADD COLUMN feedback INTEGER DEFAULT 0",
        [],
    );
    // Memory enrichment (reference architecture gap remediation): confidence, provenance, expiry, type.
    let _ = conn.execute(
        "ALTER TABLE chump_memory ADD COLUMN confidence REAL DEFAULT 1.0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_memory ADD COLUMN verified INTEGER DEFAULT 0",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chump_memory ADD COLUMN sensitivity TEXT DEFAULT 'internal'",
        [],
    );
    let _ = conn.execute("ALTER TABLE chump_memory ADD COLUMN expires_at TEXT", []);
    let _ = conn.execute(
        "ALTER TABLE chump_memory ADD COLUMN memory_type TEXT DEFAULT 'semantic_fact'",
        [],
    );
    // Eval framework: data-driven evaluation cases and run results.
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_eval_cases (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            category TEXT NOT NULL,
            input_text TEXT NOT NULL,
            expected_properties_json TEXT NOT NULL DEFAULT '[]',
            scoring_weights_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS chump_eval_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            eval_case_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            agent_version TEXT,
            model_used TEXT,
            scores_json TEXT NOT NULL DEFAULT '{}',
            properties_passed_json TEXT NOT NULL DEFAULT '[]',
            properties_failed_json TEXT NOT NULL DEFAULT '[]',
            duration_ms INTEGER NOT NULL DEFAULT 0,
            raw_output TEXT,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_eval_runs_case ON chump_eval_runs (eval_case_id, recorded_at DESC);
        ",
    )
    .ok();
    // Session metrics for G7 analytics dashboard.
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS chump_session_metrics (
            session_id TEXT NOT NULL,
            turn_index INTEGER NOT NULL,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            narration_count INTEGER NOT NULL DEFAULT 0,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (session_id, turn_index)
        );
        CREATE INDEX IF NOT EXISTS idx_session_metrics_session ON chump_session_metrics(session_id);
        ",
    )
    .ok();
    // FTS5 over web chat messages for verbatim context retrieval (replaces LLM summarization of middle turns).
    conn.execute_batch(
        "
        CREATE VIRTUAL TABLE IF NOT EXISTS web_messages_fts USING fts5(
            content,
            content='chump_web_messages',
            content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_ai AFTER INSERT ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_ad AFTER DELETE ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(web_messages_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        CREATE TRIGGER IF NOT EXISTS web_messages_fts_au AFTER UPDATE ON chump_web_messages BEGIN
            INSERT INTO web_messages_fts(web_messages_fts, rowid, content) VALUES('delete', old.id, old.content);
            INSERT INTO web_messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        ",
    )?;
    // Sprint A Phase 3: tamper-evident tool audit chain
    let _ = conn.execute(
        "ALTER TABLE chump_tool_calls ADD COLUMN audit_hash TEXT",
        [],
    );
    // Sprint B: Bradley-Terry ratings
    let _ = conn.execute(
        "ALTER TABLE chump_skills ADD COLUMN bt_rating REAL DEFAULT 1500.0",
        [],
    );
    // Sprint B: Clam-style skill result caching (deterministic caching)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chump_skill_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            skill_name TEXT NOT NULL,
            version INTEGER NOT NULL,
            args_hash TEXT NOT NULL,
            outcome_json TEXT NOT NULL,
            cached_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        [],
    )?;
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_skill_cache_lookup 
         ON chump_skill_cache (skill_name, version, args_hash)",
        [],
    )?;

    // COG-004: causal_confidence column for graph-derived lesson confidence
    let _ = conn.execute(
        "ALTER TABLE chump_causal_lessons ADD COLUMN causal_confidence REAL",
        [],
    );
    // MEM-003: stale column — edges/lessons older than 90 days are marked stale by curate
    let _ = conn.execute(
        "ALTER TABLE chump_causal_lessons ADD COLUMN stale INTEGER NOT NULL DEFAULT 0",
        [],
    );

    // AUTO-005: tool approval rate tracking
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chump_approval_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool_name TEXT NOT NULL,
            decision TEXT NOT NULL,  -- 'auto_approved' | 'human_allowed' | 'denied' | 'timeout'
            risk_level TEXT NOT NULL DEFAULT 'unknown',
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_approval_stats_tool ON chump_approval_stats(tool_name, recorded_at DESC)",
        [],
    )?;

    // PRODUCT-055: per-slot inference request history (ring buffer, last 10 per slot).
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chump_slot_request_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slot_name TEXT NOT NULL,
            latency_ms REAL NOT NULL,
            tokens_out INTEGER NOT NULL DEFAULT 0,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        [],
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_slot_req_hist ON chump_slot_request_history(slot_name, recorded_at DESC)",
        [],
    )?;

    // COG-012: ASI telemetry tables for logprob + tool latency storage.
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chump_asi_telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            turn_id INTEGER NOT NULL,
            min_logprob REAL NOT NULL,
            avg_logprob REAL NOT NULL,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS chump_tool_latency (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tool_name TEXT NOT NULL,
            peak_latency_ms INTEGER NOT NULL,
            recorded_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        [],
    )?;

    // user_profile — three-layer user model (PRODUCT-003)
    // Sensitive fields stored as BLOB (AES-256-GCM ciphertext); key in sessions/.profile_key.
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS user_identity (
            id INTEGER PRIMARY KEY DEFAULT 1,
            name_enc BLOB,
            role_enc BLOB,
            domains_enc BLOB,
            timezone TEXT NOT NULL DEFAULT 'UTC',
            onboarding_complete INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS user_context_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL UNIQUE,
            value_enc BLOB NOT NULL,
            context_type TEXT NOT NULL DEFAULT 'project',
            expires_at TEXT,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS user_preferences (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL UNIQUE,
            value_enc BLOB NOT NULL,
            source TEXT NOT NULL DEFAULT 'chump_observed',
            confirmed INTEGER NOT NULL DEFAULT 0,
            note_enc BLOB,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS user_behavior (
            id INTEGER PRIMARY KEY DEFAULT 1,
            checkin_frequency TEXT NOT NULL DEFAULT 'async',
            risk_tolerance TEXT NOT NULL DEFAULT 'medium',
            communication_style TEXT NOT NULL DEFAULT 'concise',
            never_do_json TEXT NOT NULL DEFAULT '[]',
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        ",
    )?;

    sync_web_messages_fts(conn)?;
    Ok(())
}

/// Rebuild FTS shadow index if it is behind `chump_web_messages` (e.g. DB existed before FTS).
fn sync_web_messages_fts(conn: &rusqlite::Connection) -> Result<()> {
    let fts_ok: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='web_messages_fts'",
        [],
        |r| r.get(0),
    )?;
    if fts_ok == 0 {
        return Ok(());
    }
    let rows: i64 = conn.query_row("SELECT COUNT(*) FROM chump_web_messages", [], |r| r.get(0))?;
    let fts_rows: i64 =
        conn.query_row("SELECT COUNT(*) FROM web_messages_fts", [], |r| r.get(0))?;
    if rows > fts_rows {
        let _ = conn.execute(
            "INSERT INTO web_messages_fts(web_messages_fts) VALUES('rebuild')",
            [],
        );
    }
    Ok(())
}

fn init_pool() -> Result<Pool<SqliteConnectionManager>> {
    let path = chump_memory_db_path();
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let manager = SqliteConnectionManager::file(&path).with_init(build_connection_init_pragmas);
    let pool = Pool::builder().max_size(16).build(manager)?;
    let conn = pool.get()?;
    init_schema(&conn)?;
    Ok(pool)
}

/// Apply the per-connection init PRAGMAs. When built with `--features encrypted-db`,
/// this runs `PRAGMA key` with the value from `CHUMP_DB_PASSPHRASE` first — sqlcipher
/// requires the key to be set before any other operation on the connection.
///
/// Sprint A1 (Defense Trinity): encrypted-at-rest SQLite via sqlcipher. Gated on the
/// `encrypted-db` Cargo feature so default builds use plain `bundled` SQLite.
fn build_connection_init_pragmas(c: &mut rusqlite::Connection) -> rusqlite::Result<()> {
    #[cfg(feature = "encrypted-db")]
    {
        let key = std::env::var("CHUMP_DB_PASSPHRASE").map_err(|_| {
            rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_AUTH),
                Some(
                    "CHUMP_DB_PASSPHRASE must be set when built with --features encrypted-db"
                        .to_string(),
                ),
            )
        })?;
        if key.trim().is_empty() {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_AUTH),
                Some("CHUMP_DB_PASSPHRASE cannot be empty".to_string()),
            ));
        }
        // Double single-quotes for safe embedding in the PRAGMA statement.
        let escaped = key.replace('\'', "''");
        c.execute_batch(&format!("PRAGMA key = '{}';", escaped))?;
    }
    c.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;")
}

/// Return a connection from the shared pool. Initializes the pool (and schema) on first use.
pub fn get() -> Result<PooledConn> {
    let pool = POOL.get_or_init(|| {
        init_pool().unwrap_or_else(|e| {
            eprintln!("FATAL: chump_memory db pool init failed: {e}");
            std::process::exit(1);
        })
    });
    pool.get().map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Create a fresh in-memory DB and run init_schema to verify all CREATE TABLE/INDEX/TRIGGER statements work.
    #[test]
    fn init_schema_creates_all_tables() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_schema(&conn).unwrap();

        // Verify core tables exist
        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();

        let expected = [
            "chump_async_jobs",
            "chump_authorized_repos",
            "chump_battle_baselines",
            "chump_blackboard_cursor",
            "chump_blackboard_persist",
            "chump_causal_lessons",
            "chump_checkpoints",
            "chump_consciousness_metrics",
            "chump_episodes",
            "chump_eval_cases",
            "chump_eval_runs",
            "chump_memory",
            "chump_memory_graph",
            "chump_prediction_log",
            "chump_provider_quality",
            "chump_push_subscriptions",
            "chump_questions",
            "chump_scheduled",
            "chump_session_metrics",
            "chump_skills",
            "chump_state",
            "chump_tasks",
            "chump_tool_calls",
            "chump_tool_health",
            "chump_turn_metrics",
            "chump_web_messages",
            "chump_web_sessions",
            "chump_web_uploads",
            "user_behavior",
            "user_context_items",
            "user_identity",
            "user_preferences",
        ];
        for name in expected {
            assert!(
                tables.contains(&name.to_string()),
                "missing table: {}. Found: {:?}",
                name,
                tables
            );
        }
    }

    /// Schema should be idempotent — calling init_schema twice should not error.
    #[test]
    fn init_schema_is_idempotent() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_schema(&conn).unwrap();
        init_schema(&conn).unwrap(); // second call should be no-op
    }

    /// ALTER TABLE migrations should silently handle "column already exists".
    #[test]
    fn alter_table_migrations_are_safe() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_schema(&conn).unwrap();
        // Run again — all ALTER TABLE ADD COLUMN should silently succeed
        init_schema(&conn).unwrap();

        // Verify enriched memory columns exist
        let mut stmt = conn
            .prepare("SELECT confidence, verified, sensitivity, expires_at, memory_type FROM chump_memory LIMIT 0")
            .unwrap();
        let _ = stmt.query([]).unwrap();
    }

    /// Verify chump_memory_db_path respects CHUMP_MEMORY_DB_PATH env override.
    #[test]
    fn db_path_respects_env() {
        std::env::set_var("CHUMP_MEMORY_DB_PATH", "/tmp/custom-chump.db");
        let path = chump_memory_db_path();
        assert_eq!(path, PathBuf::from("/tmp/custom-chump.db"));
        std::env::remove_var("CHUMP_MEMORY_DB_PATH");
    }

    /// Verify chump_checkpoints scaffolding (table + indexes + parent_checkpoint_id column).
    #[test]
    fn checkpoints_schema_created() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_schema(&conn).unwrap();
        // Idempotency
        init_schema(&conn).unwrap();

        // Table exists with expected columns
        let mut stmt = conn
            .prepare("SELECT id, session_id, name, message_count, state_snapshot_json, created_at, notes FROM chump_checkpoints LIMIT 0")
            .unwrap();
        let _ = stmt.query([]).unwrap();

        // Indexes exist
        let indexes: Vec<String> = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='chump_checkpoints'",
            )
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();
        assert!(
            indexes.iter().any(|i| i == "idx_checkpoints_session"),
            "missing idx_checkpoints_session, found: {:?}",
            indexes
        );
        assert!(
            indexes.iter().any(|i| i == "idx_checkpoints_name"),
            "missing idx_checkpoints_name, found: {:?}",
            indexes
        );

        // parent_checkpoint_id column was added to chump_web_sessions
        let mut stmt = conn
            .prepare("SELECT parent_checkpoint_id FROM chump_web_sessions LIMIT 0")
            .unwrap();
        let _ = stmt.query([]).unwrap();
    }

    /// Verify FTS5 virtual tables are created.
    #[test]
    fn fts5_tables_created() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_schema(&conn).unwrap();

        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts%'")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();

        assert!(tables.iter().any(|t| t.contains("memory_fts")));
        assert!(tables.iter().any(|t| t.contains("web_messages_fts")));
    }
}
