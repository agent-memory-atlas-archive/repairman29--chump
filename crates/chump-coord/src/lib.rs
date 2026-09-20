//! # chump-coord
//!
//! NATS-backed atomic coordination layer for multi-agent Chump sessions.
//!
//! ## Design (Phase 1 — additive)
//!
//! Phase 1 runs **alongside** the existing file-based lease system
//! (`.chump-locks/*.json` + `ambient.jsonl`). File leases remain
//! authoritative; this crate provides an **atomic claim layer** on top:
//!
//! - **NATS KV `chump_gaps`** — one key per gap (`gap.<gap-id>`), written
//!   with [`kv::Store::create`] which fails atomically if the key exists.
//!   Eliminates the 3-second sleep race that caused 5× duplicate implementations.
//!
//! - **NATS JetStream `CHUMP_EVENTS`** — persistent, replayable event stream
//!   on subjects `chump.events.*`. Augments `ambient.jsonl` with real-time
//!   fanout and 24-hour replay.
//!
//! Both are **optional**: every public function degrades gracefully when the
//! NATS server is unreachable. The caller always falls back to the file system.
//!
//! ## Quick start
//!
//! ```no_run
//! use chump_coord::CoordClient;
//!
//! # #[tokio::main]
//! # async fn main() -> anyhow::Result<()> {
//! let client = CoordClient::connect_or_skip().await;
//!
//! if let Some(c) = client {
//!     match c.try_claim_gap("COG-016", "my-session-id").await? {
//!         true  => println!("Claimed COG-016"),
//!         false => println!("Already claimed — pick a different gap"),
//!     }
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ## Environment variables
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_NATS_URL` | `nats://127.0.0.1:4222` | NATS server address |
//! | `CHUMP_NATS_TIMEOUT_MS` | `500` | Connection + op timeout in ms |
//! | `CHUMP_GAP_CLAIM_TTL_SECS` | `14400` (4h) | KV entry TTL |
//! | `CHUMP_NATS_GAP_BUCKET` | `chump_gaps` | KV bucket name (override for tests) |
//! | `CHUMP_NATS_WORK_BOARD_BUCKET` | `chump_work_board` | KV bucket name for FLEET-008 work board (override for tests) |
//! | `CHUMP_WORK_BOARD_TTL_SECS` | `604800` (7d) | Work-board entry TTL |
//! | `CHUMP_NATS_HELP_REQUESTS_BUCKET` | `chump_help_requests` | KV bucket name for FLEET-010 help requests (override for tests) |
//! | `CHUMP_HELP_REQUEST_TTL_SECS` | `604800` (7d) | Help-request entry TTL |
//!
//! ## Modules
//!
//! - [`work_board`] — FLEET-008 shared subtask queue (post / claim / complete).
//! - [`help_request`] — FLEET-010 help-seeking protocol (post / claim / complete).
//! - [`mission`] — META-164 public Mission / PersistentMission / Replanner surface (INFRA-2247).

pub mod assign;
pub mod capability;
pub mod consensus;
pub mod events;
pub mod help_request;
/// META-175: per-role JetStream durable consumers (restart-safe replay building block).
/// Feature-gated behind CHUMP_FLEET_WIRE_V1=1 + CHUMP_NATS_URL.
pub mod jetstream_consumer;
pub mod mesh;
pub mod mission;
/// INFRA-2266: Layer 1a slice 3/4 — NATS-primary JetStream durable consumer.
/// Public surface re-exports `events` types + exposes durable_consumer_name,
/// max_ack_pending, and layer_enabled helpers.
pub mod nats_primary;
pub mod presence;
pub mod rpc;
pub mod scratchpad;
pub mod work_board;
pub mod worker;

// INFRA-1815: mesh-bridge — separate file to minimise collision surface with
// sibling leases on lib.rs. Full doc + re-exports live in mesh_bridge.rs.
#[cfg(feature = "mesh-bridge")]
pub mod mesh_bridge;

use anyhow::{anyhow, Result};
use async_nats::jetstream::{self, kv};
use bytes::Bytes;
use chrono::Utc;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// Default NATS server URL — localhost embedded instance.
pub const DEFAULT_NATS_URL: &str = "nats://127.0.0.1:4222";

/// KV bucket name for atomic gap claims.
///
/// NATS KV bucket names must be alphanumeric (plus `-` / `_`); dots are
/// reserved for subject hierarchy and rejected at bucket creation. The
/// per-gap key inside the bucket is `gap.<gap-id>`, where dots ARE allowed.
pub const GAP_BUCKET: &str = "chump_gaps";

/// JetStream stream name for coordination events.
pub const EVENTS_STREAM: &str = "CHUMP_EVENTS";

/// JetStream subject prefix for all events.
pub const EVENTS_SUBJECT: &str = "chump.events";

/// Default TTL for gap claim entries (4 hours, matches file lease default).
pub const DEFAULT_GAP_TTL_SECS: u64 = 14_400;

/// KV bucket for the INFRA-2252 local-merge-queue CAS lock (INFRA-7714 slice).
///
/// Distinct from [`GAP_BUCKET`]: this is a single well-known key
/// (`MERGE_QUEUE_LOCK_KEY`) shared by every worker on the local mesh, used to
/// serialize merges into local `main` when `CHUMP_GITHUB_MODE=offline`.
pub const MERGE_QUEUE_BUCKET: &str = "chump_merge_queue";

/// The single key inside [`MERGE_QUEUE_BUCKET`] that acts as the lock.
pub const MERGE_QUEUE_LOCK_KEY: &str = "lock";

/// Default TTL for the merge-queue lock (5 minutes) — a safety net so a
/// holder that crashes mid-merge doesn't wedge the queue forever.
pub const DEFAULT_MERGE_LOCK_TTL_SECS: u64 = 300;

// ── Claim record ─────────────────────────────────────────────────────────────

/// Stored in NATS KV `chump_gaps` under key `gap.<gap-id>` when a session claims a gap.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GapClaim {
    /// Session ID of the claiming agent.
    pub session_id: String,
    /// RFC3339 timestamp of when the claim was created.
    pub claimed_at: String,
    /// Optional: files the claiming session intends to touch.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<String>,
}

/// Stored in NATS KV [`MERGE_QUEUE_BUCKET`] under [`MERGE_QUEUE_LOCK_KEY`]
/// while a worker holds the local-merge-queue lock.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergeLockHolder {
    /// Identity of the lock holder, e.g. `"<pid>@<hostname>"`.
    pub holder: String,
    /// RFC3339 timestamp of when the lock was acquired.
    pub acquired_at: String,
}

// ── Event record ─────────────────────────────────────────────────────────────

/// All structured events published to `chump.events.*`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CoordEvent {
    /// Event type: INTENT | DONE | STUCK | HANDOFF | WARN | ALERT | session_start | commit
    pub event: String,
    /// Sending session ID.
    pub session: String,
    /// RFC3339 UTC timestamp.
    pub ts: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gap: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

// ── CoordClient ───────────────────────────────────────────────────────────────

/// Connected coordination client.
pub struct CoordClient {
    /// Raw NATS client — exposed so callers can subscribe directly.
    pub nats: async_nats::Client,
    js: jetstream::Context,
    gaps_kv: kv::Store,
    /// FLEET-008 work-board KV bucket. Populated lazily during
    /// [`Self::connect`] so the work_board module can rely on it.
    pub(crate) work_board_kv: kv::Store,
    /// FLEET-010 help-requests KV bucket. Independent of the work
    /// board so help requests can hang off either subtasks or gaps
    /// and survive subtask state transitions.
    pub(crate) help_requests_kv: kv::Store,
    /// INFRA-1120 Layer 2c: capability manifests KV bucket.
    /// Workers publish their CapabilityManifest here at startup and every
    /// 30s heartbeat; TTL = 5 min. Picker reads this to route gaps.
    pub capabilities_kv: kv::Store,
    /// CREDIBLE-246 (CREDIBLE-099 slice): worker presence KV bucket.
    /// Distinct from `gaps_kv` (which registers the CLAIM) — this bucket
    /// registers the WORKER itself (worker_id, backend, machine, skills,
    /// harness, current_gap, status).
    pub workers_kv: kv::Store,
    /// INFRA-7714 (INFRA-2252 slice): local-merge-queue CAS lock bucket.
    pub(crate) merge_queue_kv: kv::Store,
}

/// Parse credentials out of a `nats://[user[:pass]@]host:port` URL.
/// Returns `Some((user, Some(pass)))` for user/password auth,
/// `Some((token, None))` for the token-only `nats://token@host` form,
/// or `None` when the URL carries no userinfo.
pub(crate) fn parse_nats_creds(url: &str) -> Option<(String, Option<String>)> {
    let after = url
        .strip_prefix("nats://")
        .or_else(|| url.strip_prefix("tls://"))
        .unwrap_or(url);
    let at = after.find('@')?;
    let creds = &after[..at];
    if creds.is_empty() {
        return None;
    }
    match creds.split_once(':') {
        Some((u, p)) => Some((u.to_string(), Some(p.to_string()))),
        None => Some((creds.to_string(), None)),
    }
}

impl CoordClient {
    /// Connect to NATS and initialise the KV bucket + JetStream stream.
    pub async fn connect() -> Result<Self> {
        let url = std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| DEFAULT_NATS_URL.to_string());
        let timeout_ms: u64 = std::env::var("CHUMP_NATS_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(500);
        let ttl_secs: u64 = std::env::var("CHUMP_GAP_CLAIM_TTL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_GAP_TTL_SECS);

        // RESILIENT-190: async_nats (0.49) takes auth from ConnectOptions, NOT
        // from the URL's userinfo — `connect(url)` opens the TCP socket but sends
        // no credentials, so an authenticated broker rejects it with
        // "authorization violation". Parse `nats://user:pass@host` (or the
        // token-only `nats://token@host`) out of the URL and set it explicitly.
        // Bonus: the token never appears in the timeout error message below.
        let mut opts = async_nats::ConnectOptions::new();
        if let Some((user, pass)) = parse_nats_creds(&url) {
            opts = match pass {
                Some(p) => opts.user_and_password(user, p),
                None => opts.token(user),
            };
        }
        let nats = tokio::time::timeout(
            Duration::from_millis(timeout_ms),
            opts.connect(url.as_str()),
        )
        .await
        .map_err(|_| anyhow!("NATS connect timed out after {}ms", timeout_ms))?
        .map_err(|e| anyhow!("NATS connect failed: {}", e))?;

        let js = jetstream::new(nats.clone());

        // KV bucket for gap claims — max_age = TTL. Bucket name is overridable
        // so integration tests can use a fresh bucket per-test (each `create`
        // is idempotent on the existing bucket, so changing TTL requires a new
        // name). Default `GAP_BUCKET` is the production value.
        let bucket_name =
            std::env::var("CHUMP_NATS_GAP_BUCKET").unwrap_or_else(|_| GAP_BUCKET.to_string());
        let gaps_kv = js
            .create_key_value(kv::Config {
                bucket: bucket_name,
                max_age: Duration::from_secs(ttl_secs),
                history: 5,
                ..Default::default()
            })
            .await
            .map_err(|e| anyhow!("KV bucket setup failed: {}", e))?;

        // JetStream stream for coordination events.
        js.get_or_create_stream(jetstream::stream::Config {
            name: EVENTS_STREAM.to_string(),
            subjects: vec![format!("{}.>", EVENTS_SUBJECT)],
            max_age: Duration::from_secs(86_400), // 24h
            ..Default::default()
        })
        .await
        .map_err(|e| anyhow!("JetStream stream setup failed: {}", e))?;

        // FLEET-008 work-board KV bucket. Independent of the gap-claim
        // bucket so its TTL (7d default) and history depth (16) can be
        // tuned without affecting atomic gap claims.
        let work_board_kv = work_board::init_bucket(&js).await?;

        // FLEET-010 help-requests KV bucket. Separate bucket so
        // help-request lifecycle is independent of the parent
        // subtask / gap (a subtask can stay claimed while its help
        // request is being resolved) and so help-request TTL can
        // be tuned independently.
        let help_requests_kv = help_request::init_bucket(&js).await?;

        // INFRA-1120 Layer 2c: capability manifests KV bucket.
        let capabilities_kv = capability::init_capabilities_bucket(&js).await?;

        // CREDIBLE-246 (CREDIBLE-099 slice): worker presence KV bucket.
        let workers_kv = presence::init_workers_bucket(&js).await?;

        // INFRA-7714 (INFRA-2252 slice): local-merge-queue CAS lock bucket.
        // TTL bounds how long a crashed holder can wedge the queue.
        let merge_lock_ttl_secs: u64 = std::env::var("CHUMP_MERGE_LOCK_TTL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_MERGE_LOCK_TTL_SECS);
        let merge_queue_bucket_name = std::env::var("CHUMP_NATS_MERGE_QUEUE_BUCKET")
            .unwrap_or_else(|_| MERGE_QUEUE_BUCKET.to_string());
        let merge_queue_kv = js
            .create_key_value(kv::Config {
                bucket: merge_queue_bucket_name,
                max_age: Duration::from_secs(merge_lock_ttl_secs),
                history: 1,
                ..Default::default()
            })
            .await
            .map_err(|e| anyhow!("merge-queue KV bucket setup failed: {}", e))?;

        Ok(Self {
            nats,
            js,
            gaps_kv,
            work_board_kv,
            help_requests_kv,
            capabilities_kv,
            workers_kv,
            merge_queue_kv,
        })
    }

    /// Like [`connect`] but returns `None` instead of an error when NATS is
    /// unreachable. Shell scripts use this to fall back to file-based leases.
    pub async fn connect_or_skip() -> Option<Self> {
        match Self::connect().await {
            Ok(c) => Some(c),
            Err(e) => {
                eprintln!(
                    "[chump-coord] NATS unavailable ({}) — using file-based coordination",
                    e
                );
                None
            }
        }
    }

    /// Returns `true` if the NATS server responded within 200ms.
    pub async fn ping(&self) -> bool {
        tokio::time::timeout(Duration::from_millis(200), self.nats.flush())
            .await
            .map(|r| r.is_ok())
            .unwrap_or(false)
    }

    // ── Atomic gap claims ─────────────────────────────────────────────────────

    /// Attempt to atomically claim `gap_id` for `session_id`.
    ///
    /// Returns `Ok(true)` if the claim was acquired, `Ok(false)` if another
    /// session already holds it. The [`kv::Store::create`] call is the
    /// atomic mutex — it fails with `AlreadyExists` if the key exists.
    pub async fn try_claim_gap(&self, gap_id: &str, session_id: &str) -> Result<bool> {
        self.try_claim_gap_with_files(gap_id, session_id, &[]).await
    }

    /// Like [`try_claim_gap`] but records intended file touches.
    pub async fn try_claim_gap_with_files(
        &self,
        gap_id: &str,
        session_id: &str,
        files: &[&str],
    ) -> Result<bool> {
        let key = format!("gap.{}", gap_id);
        let claim = GapClaim {
            session_id: session_id.to_string(),
            claimed_at: Utc::now().to_rfc3339(),
            files: files.iter().map(|s| s.to_string()).collect(),
        };
        let value: Bytes = serde_json::to_vec(&claim)?.into();

        match self.gaps_kv.create(&key, value).await {
            Ok(_) => Ok(true),
            Err(e) => {
                // AlreadyExists = another session won the race
                if e.kind() == kv::CreateErrorKind::AlreadyExists {
                    Ok(false)
                } else {
                    Err(anyhow!("KV create error: {}", e))
                }
            }
        }
    }

    /// Release a gap claim. No-op if the key doesn't exist or is already gone.
    pub async fn release_gap(&self, gap_id: &str) -> Result<()> {
        let key = format!("gap.{}", gap_id);
        self.gaps_kv
            .purge(&key)
            .await
            .map_err(|e| anyhow!("KV purge error: {}", e))?;
        Ok(())
    }

    /// Read the current claim holder for a gap, or `None` if unclaimed.
    pub async fn gap_claim(&self, gap_id: &str) -> Result<Option<GapClaim>> {
        let key = format!("gap.{}", gap_id);
        match self.gaps_kv.get(&key).await {
            Ok(Some(bytes)) => {
                let claim: GapClaim = serde_json::from_slice(&bytes)?;
                Ok(Some(claim))
            }
            Ok(None) => Ok(None),
            Err(e) => Err(anyhow!("KV get error: {}", e)),
        }
    }

    /// List all currently active gap claims.
    pub async fn list_gap_claims(&self) -> Result<Vec<(String, GapClaim)>> {
        let mut keys = self
            .gaps_kv
            .keys()
            .await
            .map_err(|e| anyhow!("KV keys error: {}", e))?;

        let mut out = Vec::new();
        while let Some(key_result) = keys.next().await {
            let key = key_result.map_err(|e| anyhow!("KV key stream error: {}", e))?;
            if let Ok(Some(bytes)) = self.gaps_kv.get(&key).await {
                if let Ok(claim) = serde_json::from_slice::<GapClaim>(&bytes) {
                    let gap_id = key.trim_start_matches("gap.").to_string();
                    out.push((gap_id, claim));
                }
            }
        }
        Ok(out)
    }

    // ── Merge-queue CAS lock (INFRA-7714 / INFRA-2252 slice) ────────────────────

    /// Attempt to atomically acquire the local-merge-queue lock for `holder`
    /// (typically `"<pid>@<hostname>"`). Returns `Ok(true)` if acquired,
    /// `Ok(false)` if another holder already has it (CAS conflict — this is
    /// the expected "someone else is merging" case, not an error).
    ///
    /// Distinct from [`try_claim_gap`]: this is a single well-known key
    /// shared by every worker on the mesh, not a per-gap entry.
    pub async fn try_acquire_merge_lock(&self, holder: &str) -> Result<bool> {
        let record = MergeLockHolder {
            holder: holder.to_string(),
            acquired_at: Utc::now().to_rfc3339(),
        };
        let value: Bytes = serde_json::to_vec(&record)?.into();

        match self
            .merge_queue_kv
            .create(MERGE_QUEUE_LOCK_KEY, value)
            .await
        {
            Ok(_) => Ok(true),
            Err(e) => {
                if e.kind() == kv::CreateErrorKind::AlreadyExists {
                    Ok(false)
                } else {
                    Err(anyhow!("merge-lock KV create error: {}", e))
                }
            }
        }
    }

    /// Release the merge-queue lock. No-op if it doesn't exist or already
    /// expired via TTL.
    pub async fn release_merge_lock(&self) -> Result<()> {
        self.merge_queue_kv
            .purge(MERGE_QUEUE_LOCK_KEY)
            .await
            .map_err(|e| anyhow!("merge-lock KV purge error: {}", e))?;
        Ok(())
    }

    /// Read the current merge-lock holder, or `None` if unlocked.
    pub async fn merge_lock_holder(&self) -> Result<Option<MergeLockHolder>> {
        match self.merge_queue_kv.get(MERGE_QUEUE_LOCK_KEY).await {
            Ok(Some(bytes)) => Ok(Some(serde_json::from_slice(&bytes)?)),
            Ok(None) => Ok(None),
            Err(e) => Err(anyhow!("merge-lock KV get error: {}", e)),
        }
    }

    // ── Event publishing ──────────────────────────────────────────────────────

    /// Publish a structured event to `chump.events.<event_type>`.
    pub async fn emit(&self, event: CoordEvent) -> Result<()> {
        let subject = format!("{}.{}", EVENTS_SUBJECT, event.event.to_lowercase());
        let payload: Bytes = serde_json::to_vec(&event)?.into();
        self.js
            .publish(subject, payload)
            .await
            .map_err(|e| anyhow!("JetStream publish error: {}", e))?
            .await
            .map_err(|e| anyhow!("JetStream ack error: {}", e))?;
        Ok(())
    }

    /// Convenience: emit an INTENT event for a gap.
    pub async fn emit_intent(&self, session_id: &str, gap_id: &str, files: &str) -> Result<()> {
        self.emit(CoordEvent {
            event: "INTENT".to_string(),
            session: session_id.to_string(),
            ts: Utc::now().to_rfc3339(),
            gap: Some(gap_id.to_string()),
            files: Some(files.to_string()),
            ..Default::default()
        })
        .await
    }

    /// Convenience: emit a DONE event when a gap ships.
    pub async fn emit_done(&self, session_id: &str, gap_id: &str, commit: &str) -> Result<()> {
        self.emit(CoordEvent {
            event: "DONE".to_string(),
            session: session_id.to_string(),
            ts: Utc::now().to_rfc3339(),
            gap: Some(gap_id.to_string()),
            commit: Some(commit.to_string()),
            ..Default::default()
        })
        .await
    }

    /// Internal: publish a raw payload on an arbitrary JetStream
    /// subject. Used by sibling modules ([`work_board`]) that emit on
    /// nested subjects like `chump.events.work_board.posted` rather
    /// than the top-level `chump.events.<type>` shape that
    /// [`Self::emit`] produces.
    pub(crate) async fn js_publish_raw(&self, subject: &str, payload: Bytes) -> Result<()> {
        self.js
            .publish(subject.to_string(), payload)
            .await
            .map_err(|e| anyhow!("JetStream publish error: {}", e))?
            .await
            .map_err(|e| anyhow!("JetStream ack error: {}", e))?;
        Ok(())
    }

    /// Flush pending pub acks.
    pub async fn flush(&self) -> Result<()> {
        self.nats
            .flush()
            .await
            .map_err(|e| anyhow!("NATS flush error: {}", e))
    }

    // ── Capability manifest API (INFRA-1120 Layer 2c) ─────────────────────────

    /// Publish a CapabilityManifest for the current session to the
    /// `chump_capabilities` KV bucket and append to the file audit trail.
    ///
    /// Call at worker startup and then via [`capability::heartbeat_loop`]
    /// every 30 seconds. Manifests older than `ttl_seconds` (default 300s)
    /// are treated as stale by [`Self::list_capabilities`].
    pub async fn publish_capability(
        &self,
        manifest: &capability::CapabilityManifest,
    ) -> Result<()> {
        capability::publish_manifest(&self.capabilities_kv, manifest).await
    }

    /// List all live (non-stale) capability manifests currently in the
    /// `chump_capabilities` KV bucket.
    ///
    /// Stale manifests (heartbeat_at older than their `ttl_seconds`) are
    /// excluded — they represent dead or unreachable sessions. Picker uses
    /// this to route gaps to capable sessions (AC-4: >=1 routing decision
    /// per gap during the 7-day release gate).
    pub async fn list_capabilities(&self) -> Result<Vec<capability::CapabilityManifest>> {
        capability::list_capabilities(&self.capabilities_kv).await
    }

    // ── Worker presence API (CREDIBLE-246 / CREDIBLE-099 slice) ───────────────

    /// AC-1: register a worker presence record in the `chump_workers` KV
    /// bucket. Call once at worker startup, alongside RPC handler
    /// registration.
    pub async fn register_worker_presence(
        &self,
        presence: &presence::WorkerPresence,
    ) -> Result<()> {
        presence::register_presence(&self.workers_kv, presence).await
    }

    /// AC-2: update the current-gap field (and `updated_at`) for a
    /// registered worker — call when the worker picks a new gap.
    pub async fn update_worker_presence_gap(
        &self,
        worker_id: &str,
        current_gap: Option<String>,
    ) -> Result<()> {
        presence::update_presence_gap(&self.workers_kv, worker_id, current_gap).await
    }

    /// AC-2: refresh a worker's presence heartbeat (`updated_at`) without
    /// changing other fields.
    pub async fn refresh_worker_presence(&self, worker_id: &str) -> Result<()> {
        presence::refresh_presence(&self.workers_kv, worker_id).await
    }

    /// AC-2: mark a worker's presence `Terminal` — call on ship or exit.
    pub async fn mark_worker_terminal(&self, worker_id: &str) -> Result<()> {
        presence::mark_terminal(&self.workers_kv, worker_id).await
    }

    /// CREDIBLE-256: deregister a worker's presence record on ship/exit by
    /// deleting it from the `chump_workers` KV bucket outright.
    pub async fn deregister_worker_presence(&self, worker_id: &str) -> Result<()> {
        presence::deregister_presence(&self.workers_kv, worker_id).await
    }

    /// Read a single worker's presence record.
    pub async fn worker_presence(
        &self,
        worker_id: &str,
    ) -> Result<Option<presence::WorkerPresence>> {
        presence::get_presence(&self.workers_kv, worker_id).await
    }

    /// List every worker presence record currently in the bucket.
    pub async fn list_worker_presence(&self) -> Result<Vec<presence::WorkerPresence>> {
        presence::list_presence(&self.workers_kv).await
    }
}

#[cfg(test)]
mod parse_creds_tests {
    use super::parse_nats_creds;

    #[test]
    fn user_and_password() {
        assert_eq!(
            parse_nats_creds("nats://chump:secret@1.2.3.4:4222"),
            Some(("chump".to_string(), Some("secret".to_string())))
        );
    }

    #[test]
    fn token_only() {
        assert_eq!(
            parse_nats_creds("nats://deadbeef@host:4222"),
            Some(("deadbeef".to_string(), None))
        );
    }

    #[test]
    fn no_userinfo_is_none() {
        assert_eq!(parse_nats_creds("nats://127.0.0.1:4222"), None);
    }

    #[test]
    fn tls_scheme_and_empty_userinfo() {
        assert_eq!(
            parse_nats_creds("tls://u:p@host:4222"),
            Some(("u".to_string(), Some("p".to_string())))
        );
        // A stray leading '@' with empty creds carries no auth.
        assert_eq!(parse_nats_creds("nats://@host:4222"), None);
    }
}
