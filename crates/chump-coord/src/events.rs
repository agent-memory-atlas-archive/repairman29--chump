// crates/chump-coord/src/events.rs — INFRA-1118
//
// A2A Layer 1a — NATS-primary delivery, file-fallback secondary.
//
// Replaces the stub from INFRA-1758 (slice 1/4) with the real implementation:
//   - subscribe_events(filter) -> EventStream  (JetStream durable push consumer)
//   - File-fallback within 5s when NATS unreachable (emits fleet_a2a_degraded)
//   - Reconnect with durable offset resume (emits fleet_a2a_recovered)
//   - Backpressure detection via pending-count threshold (emits fleet_a2a_backpressure)
//   - Feature-gate: CHUMP_A2A_LAYER=0 (default) returns file-only stream;
//                   CHUMP_A2A_LAYER=1 enables NATS-primary path
//
// Design decisions:
//   (1a-Q1) Per-session durable name: `chump_<session_id_sanitized>`.
//           Rationale: clean isolation; cardinality is bounded by active fleet size
//           which is O(tens). Dead durables expire with stream max_age (24h).
//   (1a-Q2) On restart: replay from last acked sequence. INTENT events matter;
//           DONE events are idempotent — replaying both is safe.
//   (1a-Q3) ambient.jsonl remains the audit trail; no rotation policy change here.

use async_nats::jetstream::{self, consumer};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::timeout;

use crate::{parse_nats_creds, DEFAULT_NATS_URL, EVENTS_STREAM, EVENTS_SUBJECT};

/// Connect to NATS with credentials parsed out of the URL, mirroring
/// `CoordClient::connect` (RESILIENT-190). `async_nats::connect(url)` alone
/// opens the socket but never sends auth — it silently ignores the
/// `user:pass@host` userinfo — so an authenticated broker (e.g. the fleet's
/// deployed helsinki nats-server) rejects every connection attempt from this
/// subscribe path with "authorization violation" while `CoordClient::connect`
/// (used by every publish path) works fine. Before this fix, that meant
/// `subscribe_events` degraded to file-fallback immediately on any
/// credentialed broker — this subscribe path never actually attached to
/// JetStream against the fleet's real NATS deployment.
async fn connect_with_creds(
    url: &str,
) -> std::result::Result<async_nats::Client, async_nats::ConnectError> {
    let mut opts = async_nats::ConnectOptions::new();
    if let Some((user, pass)) = parse_nats_creds(url) {
        opts = match pass {
            Some(p) => opts.user_and_password(user, p),
            None => opts.token(user),
        };
    }
    opts.connect(url).await
}

// ── Public types ─────────────────────────────────────────────────────────────

/// Event filter passed to `subscribe_events`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventFilter {
    /// All events the broker delivers to this session.
    All,
    /// Only events with this exact `kind`.
    Kind(String),
    /// Only events from this exact `session_id`.
    Session(String),
    /// Any event whose `kind` is in this set.
    Kinds(Vec<String>),
}

impl EventFilter {
    /// Whether this filter accepts the given event. Used in the file fallback
    /// path where filtering cannot be pushed down to NATS.
    pub fn matches(&self, event: &CoordEvent) -> bool {
        match self {
            EventFilter::All => true,
            EventFilter::Kind(k) => event.kind == *k,
            EventFilter::Session(s) => event.session_id.as_deref() == Some(s.as_str()),
            EventFilter::Kinds(set) => set.iter().any(|k| k == &event.kind),
        }
    }

    /// Convert to a NATS subject filter string for server-side filtering.
    /// Returns `chump.events.>` for All/Session/Kinds (client-side post-filter),
    /// or `chump.events.<kind>` for exact Kind match.
    fn to_nats_subject(&self) -> String {
        match self {
            EventFilter::Kind(k) => format!("{}.{}", EVENTS_SUBJECT, k.to_lowercase()),
            _ => format!("{}.>", EVENTS_SUBJECT),
        }
    }
}

/// Wire-format event delivered via the pub/sub stream.
/// Compatible with `.chump-locks/ambient.jsonl` line shape.
///
/// Note: `payload` defaults to `null` when absent (ambient.jsonl events and
/// `lib.rs` CoordEvent do not always emit a `payload` field).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct CoordEvent {
    /// ISO-8601 timestamp.
    pub ts: String,
    /// Event kind (e.g. "gap_claimed", "fleet_auth_verified").
    pub kind: String,
    /// Source session ID, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Payload as free-form JSON. Defaults to null when absent.
    #[serde(default)]
    pub payload: serde_json::Value,
}

// RESILIENT-334: the publish side (`lib::CoordEvent`, used by `CoordClient::emit`,
// `work_board`, `help_request`) and this subscribe-side wire type historically used
// *different* JSON shapes — `{"event":"WORK_POSTED", "session":..., "gap":...,
// "reason":...}` vs `{"kind":..., "session_id":..., "payload":...}`. `kind` was a
// required field with no alias, so every `lib::CoordEvent`-shaped message (which
// carries "event", not "kind") silently failed to deserialize and was dropped
// (see the `Err(_) => { ack; continue }` arm in `run_nats_consumer`). That made
// `subscribe_events` a telemetry-only sink for ambient-shaped events — anything a
// worker actually needed to *act on* (WORK_POSTED, HELP_REQUESTED, gap claims)
// never arrived. This manual impl bridges both shapes so a subscriber can react
// to real coordination events, not just its own ambient mirror.
impl<'de> Deserialize<'de> for CoordEvent {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let mut obj = serde_json::Map::deserialize(deserializer)?;

        let ts = obj
            .remove("ts")
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();

        // Prefer an explicit "kind"; fall back to the publish-side "event" field
        // (lib::CoordEvent's INTENT|DONE|STUCK|WORK_POSTED|... discriminant).
        let kind = obj
            .remove("kind")
            .and_then(|v| v.as_str().map(str::to_string))
            .or_else(|| {
                obj.get("event")
                    .and_then(|v| v.as_str().map(str::to_string))
            })
            .unwrap_or_else(|| "unknown".to_string());

        let session_id = obj
            .remove("session_id")
            .and_then(|v| v.as_str().map(str::to_string))
            .or_else(|| {
                obj.get("session")
                    .and_then(|v| v.as_str().map(str::to_string))
            });

        // Explicit "payload" wins. Otherwise, if the message carries
        // lib::CoordEvent-shaped fields (gap/files/reason/commit/to/event),
        // surface them as the payload so a subscriber can act without a
        // second round-trip — that's the whole point of subscribing.
        let payload = match obj.remove("payload") {
            Some(p) => p,
            None => {
                let mut leftover = serde_json::Map::new();
                for key in ["event", "gap", "files", "reason", "commit", "to"] {
                    if let Some(v) = obj.get(key) {
                        if !v.is_null() {
                            leftover.insert(key.to_string(), v.clone());
                        }
                    }
                }
                if leftover.is_empty() {
                    serde_json::Value::Null
                } else {
                    serde_json::Value::Object(leftover)
                }
            }
        };

        Ok(CoordEvent {
            ts,
            kind,
            session_id,
            payload,
        })
    }
}

/// Error type for the pub/sub layer.
#[derive(Debug)]
pub enum SubscribeError {
    /// Internal channel setup failed.
    Internal(String),
    /// Wire-format decode error.
    Deserialize(serde_json::Error),
}

impl std::fmt::Display for SubscribeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SubscribeError::Internal(e) => write!(f, "subscribe internal error: {e}"),
            SubscribeError::Deserialize(e) => write!(f, "deserialize failed: {e}"),
        }
    }
}

impl std::error::Error for SubscribeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            SubscribeError::Deserialize(e) => Some(e),
            _ => None,
        }
    }
}

impl From<serde_json::Error> for SubscribeError {
    fn from(e: serde_json::Error) -> Self {
        SubscribeError::Deserialize(e)
    }
}

// ── EventStream ───────────────────────────────────────────────────────────────

/// Stream of `CoordEvent` items. Wraps a tokio mpsc receiver so the caller
/// can `.next().await` regardless of whether the backing source is NATS or
/// ambient.jsonl.
pub struct EventStream {
    rx: mpsc::Receiver<CoordEvent>,
}

impl EventStream {
    /// Pull the next event. Returns `None` when the stream is exhausted
    /// (underlying channel closed — usually means the subscriber task exited).
    pub async fn next(&mut self) -> Option<CoordEvent> {
        self.rx.recv().await
    }
}

// ── Constants ─────────────────────────────────────────────────────────────────

/// JetStream max_ack_pending for the push consumer.
const DEFAULT_MAX_ACK_PENDING: i64 = 512;

/// Fallback timeout: if NATS connect fails, emit degraded and switch to file
/// fallback within this many seconds.
const FALLBACK_TIMEOUT_SECS: u64 = 5;

/// Reconnect poll interval while in degraded mode.
const RECONNECT_POLL_SECS: u64 = 10;

/// File fallback poll interval for tailing ambient.jsonl.
const FILE_POLL_INTERVAL_MS: u64 = 100;

// ── Public API ────────────────────────────────────────────────────────────────

/// Subscribe to coordination events. Returns a stream of `CoordEvent` items
/// matching the filter.
///
/// **Feature gate:** `CHUMP_A2A_LAYER=1` enables NATS-primary subscribe path.
/// Default (`CHUMP_A2A_LAYER=0` or unset) uses file-only polling — preserving
/// today's behavior with zero NATS dependency.
///
/// When NATS-primary (`CHUMP_A2A_LAYER=1`):
/// - Creates a JetStream durable push consumer named `chump_<session_id>`.
/// - On NATS failure: falls back to ambient.jsonl polling within 5s, emits
///   `kind=fleet_a2a_degraded`.
/// - On NATS recovery: resumes from durable offset, emits `kind=fleet_a2a_recovered`.
/// - Slow consumer: emits `kind=fleet_a2a_backpressure` when pending > max_ack_pending.
pub async fn subscribe_events(filter: EventFilter) -> Result<EventStream, SubscribeError> {
    subscribe_events_with_session(filter, None).await
}

/// Like `subscribe_events` but accepts an explicit session_id for the durable
/// consumer name. If `None`, falls back to `CHUMP_SESSION_ID` env var, then
/// a UUID.
pub async fn subscribe_events_with_session(
    filter: EventFilter,
    session_id: Option<String>,
) -> Result<EventStream, SubscribeError> {
    let a2a_layer: u32 = std::env::var("CHUMP_A2A_LAYER")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);

    let session_id = session_id
        .or_else(|| std::env::var("CHUMP_SESSION_ID").ok())
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    // Channel capacity matches max_ack_pending so backpressure detection (which
    // checks tx.capacity()) fires correctly when the application is slow to drain.
    let channel_cap: usize = std::env::var("CHUMP_A2A_MAX_ACK_PENDING")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_MAX_ACK_PENDING as usize);
    let (tx, rx) = mpsc::channel::<CoordEvent>(channel_cap);

    if a2a_layer >= 1 {
        // NATS-primary path: spawn the subscriber task with file fallback
        let filter_clone = filter;
        let tx_clone = tx;
        tokio::spawn(async move {
            run_subscriber(filter_clone, session_id, tx_clone).await;
        });
    } else {
        // File-only path (CHUMP_A2A_LAYER=0 default) — tail ambient.jsonl.
        // CREDIBLE-1532: capture CHUMP_AMBIENT_LOG and its current byte length
        // synchronously before spawning the tail task so events written
        // immediately after subscribe_events_with_session().await returns are
        // never skipped when the OS scheduler delays initial task polling.
        let log_path = std::env::var("CHUMP_AMBIENT_LOG")
            .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());
        let initial_offset = std::fs::metadata(&log_path).map(|m| m.len()).ok();
        tokio::spawn(async move {
            run_file_subscriber_with_start(filter, tx, log_path, initial_offset).await;
        });
    }

    Ok(EventStream { rx })
}

// ── Subscriber task ───────────────────────────────────────────────────────────

/// Main subscriber task. Tries NATS-primary; on failure falls back to file.
/// Periodically retries NATS reconnect while in degraded mode.
async fn run_subscriber(filter: EventFilter, session_id: String, tx: mpsc::Sender<CoordEvent>) {
    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| DEFAULT_NATS_URL.to_string());
    let timeout_ms: u64 = std::env::var("CHUMP_NATS_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(FALLBACK_TIMEOUT_SECS * 1000);

    // Sanitise session_id for use as a NATS durable consumer name.
    // NATS consumer names allow alphanumeric, dash, underscore.
    let durable_name = format!(
        "chump_{}",
        session_id
            .chars()
            .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            })
            .collect::<String>()
    );

    // Attempt NATS connect with fallback timeout
    let connect_result = timeout(
        Duration::from_millis(timeout_ms.min(FALLBACK_TIMEOUT_SECS * 1000)),
        connect_with_creds(&nats_url),
    )
    .await;

    match connect_result {
        Ok(Ok(nats_client)) => {
            // Connected — run NATS consumer, re-enter degraded loop on drop
            run_nats_then_degrade(nats_client, filter, durable_name, session_id, tx, nats_url)
                .await;
        }
        Ok(Err(e)) => {
            emit_a2a_degraded(&session_id, &format!("connect failed: {e}"));
            run_degraded(filter, durable_name, session_id, tx, nats_url).await;
        }
        Err(_) => {
            emit_a2a_degraded(
                &session_id,
                &format!(
                    "connect timed out after {}ms",
                    timeout_ms.min(FALLBACK_TIMEOUT_SECS * 1000)
                ),
            );
            run_degraded(filter, durable_name, session_id, tx, nats_url).await;
        }
    }
}

/// Run the NATS consumer; on NATS drop, transition to degraded mode.
async fn run_nats_then_degrade(
    nats_client: async_nats::Client,
    filter: EventFilter,
    durable_name: String,
    session_id: String,
    tx: mpsc::Sender<CoordEvent>,
    nats_url: String,
) {
    let exit =
        run_nats_consumer(nats_client, &filter, &durable_name, &session_id, tx.clone()).await;
    match exit {
        NatsConsumerExit::ChannelClosed => {} // clean shutdown
        NatsConsumerExit::NatsError(reason) => {
            emit_a2a_degraded(&session_id, &reason);
            run_degraded(filter, durable_name, session_id, tx, nats_url).await;
        }
    }
}

/// Degraded mode: file-poll + periodic reconnect attempt.
async fn run_degraded(
    filter: EventFilter,
    durable_name: String,
    session_id: String,
    tx: mpsc::Sender<CoordEvent>,
    nats_url: String,
) {
    let timeout_ms: u64 = std::env::var("CHUMP_NATS_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(FALLBACK_TIMEOUT_SECS * 1000);

    // Spawn file-poll in background; drive reconnect attempts on main path
    let (file_cancel_tx, mut file_cancel_rx) = mpsc::channel::<()>(1);
    let filter_file = filter.clone();
    let tx_file = tx.clone();
    tokio::spawn(async move {
        tokio::select! {
            _ = run_file_subscriber(filter_file, tx_file) => {}
            _ = file_cancel_rx.recv() => {}
        }
    });

    loop {
        tokio::time::sleep(Duration::from_secs(RECONNECT_POLL_SECS)).await;

        if tx.is_closed() {
            return;
        }

        let connect_result = timeout(
            Duration::from_millis(timeout_ms),
            connect_with_creds(&nats_url),
        )
        .await;

        if let Ok(Ok(nats_client)) = connect_result {
            // Reconnected — get resume position, emit recovered, stop file poll
            let js = jetstream::new(nats_client.clone());
            let resume_seq = get_durable_last_sequence(&js, &durable_name).await;
            emit_a2a_recovered(&session_id, &durable_name, resume_seq);

            // Cancel the file-poll task
            let _ = file_cancel_tx.try_send(());

            // Resume NATS consumer; if it drops, re-enter degraded
            let exit =
                run_nats_consumer(nats_client, &filter, &durable_name, &session_id, tx.clone())
                    .await;
            match exit {
                NatsConsumerExit::ChannelClosed => return,
                NatsConsumerExit::NatsError(reason) => {
                    emit_a2a_degraded(&session_id, &reason);
                    // Re-spawn file poll and keep looping
                    let filter_file2 = filter.clone();
                    let tx_file2 = tx.clone();
                    tokio::spawn(async move {
                        run_file_subscriber(filter_file2, tx_file2).await;
                    });
                }
            }
        }
        // Connect failed — keep polling file, retry next iteration
    }
}

#[derive(Debug)]
enum NatsConsumerExit {
    ChannelClosed,
    NatsError(String),
}

/// Run the JetStream durable push consumer until NATS drops or channel closes.
async fn run_nats_consumer(
    nats: async_nats::Client,
    filter: &EventFilter,
    durable_name: &str,
    session_id: &str,
    tx: mpsc::Sender<CoordEvent>,
) -> NatsConsumerExit {
    let js = jetstream::new(nats);

    // Ensure the stream exists (get_or_create is idempotent)
    let stream_result = js
        .get_or_create_stream(jetstream::stream::Config {
            name: EVENTS_STREAM.to_string(),
            subjects: vec![format!("{}.>", EVENTS_SUBJECT)],
            max_age: Duration::from_secs(86_400),
            ..Default::default()
        })
        .await;

    let stream = match stream_result {
        Ok(s) => s,
        Err(e) => return NatsConsumerExit::NatsError(format!("stream setup: {e}")),
    };

    let max_ack_pending: i64 = std::env::var("CHUMP_A2A_MAX_ACK_PENDING")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_MAX_ACK_PENDING);

    let filter_subject = filter.to_nats_subject();

    // NATS push consumers require a deliver_subject — the inbox subject
    // where the server pushes messages. We use the durable name as the
    // subject prefix so it's stable across reconnects (same consumer name =
    // same deliver subject = no duplicate delivery on reconnect).
    let deliver_subject = format!("_CHUMP_PUSH.{}", durable_name);

    // Attach to (or create) the durable push consumer
    let consumer_result = stream
        .get_or_create_consumer(
            durable_name,
            consumer::push::Config {
                durable_name: Some(durable_name.to_string()),
                deliver_subject: deliver_subject.clone(),
                filter_subject,
                deliver_policy: consumer::DeliverPolicy::New,
                ack_policy: consumer::AckPolicy::Explicit,
                max_ack_pending,
                ..Default::default()
            },
        )
        .await;

    let consumer = match consumer_result {
        Ok(c) => c,
        Err(e) => return NatsConsumerExit::NatsError(format!("consumer setup: {e}")),
    };

    let mut messages = match consumer.messages().await {
        Ok(m) => m,
        Err(e) => return NatsConsumerExit::NatsError(format!("consumer messages: {e}")),
    };

    // Backpressure detection: measure channel fill = capacity_used / max_capacity.
    // The mpsc channel has max_ack_pending slots; when the application reader is
    // slow the channel fills up. We emit fleet_a2a_backpressure when filled slots
    // reach max_ack_pending (i.e. remaining capacity == 0 or channel would block).
    // Hysteresis: reset once filled slots drop below max_ack_pending / 2.
    let mut backpressure_emitted = false;

    loop {
        match messages.next().await {
            Some(Ok(msg)) => {
                // filled = slots used = max_capacity - remaining_capacity.
                // Emit backpressure when the channel is at least half full
                // (remaining <= max_ack_pending / 2). This fires before tx.send()
                // blocks (which happens at remaining == 0).
                let remaining = tx.capacity() as i64;
                let filled = max_ack_pending - remaining;
                let half = max_ack_pending / 2;

                if filled >= half && !backpressure_emitted {
                    emit_a2a_backpressure(session_id, filled, max_ack_pending);
                    backpressure_emitted = true;
                }
                if backpressure_emitted && filled < half / 2 {
                    backpressure_emitted = false;
                }

                // Decode the event
                let event: CoordEvent = match serde_json::from_slice(&msg.payload) {
                    Ok(e) => e,
                    Err(_) => {
                        let _ = msg.ack().await;
                        continue;
                    }
                };

                // Apply client-side filter (NATS handles Kind at subject level;
                // Session/Kinds/All need post-filter here)
                if !filter.matches(&event) {
                    let _ = msg.ack().await;
                    continue;
                }

                // Forward to application channel. When the receiver is slow /
                // dropped, this will block until capacity is available or return
                // an error when closed.
                if tx.send(event).await.is_err() {
                    let _ = msg.ack().await;
                    return NatsConsumerExit::ChannelClosed;
                }

                let _ = msg.ack().await;

                // Re-check channel fill after send for hysteresis reset.
                let remaining_after = tx.capacity() as i64;
                let filled_after = max_ack_pending - remaining_after;
                let half = max_ack_pending / 2;
                if backpressure_emitted && filled_after < half / 2 {
                    backpressure_emitted = false;
                }
            }
            Some(Err(e)) => {
                return NatsConsumerExit::NatsError(format!("message stream error: {e}"));
            }
            None => {
                return NatsConsumerExit::NatsError("message stream ended".to_string());
            }
        }
    }
}

/// File-fallback subscriber: tail ambient.jsonl and forward matching events.
async fn run_file_subscriber(filter: EventFilter, tx: mpsc::Sender<CoordEvent>) {
    let log_path = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());
    run_file_subscriber_with_start(filter, tx, log_path, None).await;
}

/// Tail `log_path` starting at `initial_offset` (when captured at subscribe
/// time) or `SeekFrom::End(0)` (when entering degraded mode mid-stream).
async fn run_file_subscriber_with_start(
    filter: EventFilter,
    tx: mpsc::Sender<CoordEvent>,
    log_path: String,
    initial_offset: Option<u64>,
) {
    // Wait up to FILE_POLL_INTERVAL_MS * 10 for the file to appear
    let file = loop {
        match std::fs::OpenOptions::new().read(true).open(&log_path) {
            Ok(f) => break f,
            Err(_) => {
                if tx.is_closed() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(FILE_POLL_INTERVAL_MS)).await;
            }
        }
    };

    use std::io::{BufRead, BufReader, Seek, SeekFrom};
    let mut reader = BufReader::new(file);
    // Seek to the subscribe-time EOF offset (or current end if unspecified) so
    // we only tail new lines without racing immediate post-subscribe writes.
    let seek_pos = match initial_offset {
        Some(offset) => SeekFrom::Start(offset),
        None => SeekFrom::End(0),
    };
    let _ = reader.seek(seek_pos);

    loop {
        if tx.is_closed() {
            return;
        }

        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => {
                // EOF — wait and retry
                tokio::time::sleep(Duration::from_millis(FILE_POLL_INTERVAL_MS)).await;
            }
            Ok(_) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                if let Ok(event) = serde_json::from_str::<CoordEvent>(trimmed) {
                    if filter.matches(&event) && tx.send(event).await.is_err() {
                        return;
                    }
                }
                // Non-matching or non-CoordEvent lines are silently skipped
            }
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(FILE_POLL_INTERVAL_MS)).await;
            }
        }
    }
}

/// Get the last delivered sequence number from the durable consumer, if it exists.
/// Returns 0 if the consumer doesn't exist or the query fails.
async fn get_durable_last_sequence(js: &jetstream::Context, durable_name: &str) -> u64 {
    let stream = match js.get_stream(EVENTS_STREAM).await {
        Ok(s) => s,
        Err(_) => return 0,
    };
    match stream.consumer_info(durable_name).await {
        Ok(info) => info.delivered.stream_sequence,
        Err(_) => 0,
    }
}

// ── Ambient emission helpers ─────────────────────────────────────────────────
//
// scanner-anchor: "kind":"fleet_a2a_degraded"
// scanner-anchor: "kind":"fleet_a2a_recovered"
// scanner-anchor: "kind":"fleet_a2a_backpressure"

fn emit_a2a_degraded(session_id: &str, reason: &str) {
    let ts = chrono::Utc::now().to_rfc3339();
    let reason_json = serde_json::Value::String(reason.to_string()).to_string();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"fleet_a2a_degraded","session_id":"{session_id}","reason":{reason_json}}}"#
    );
    let _ = append_ambient(&line);
}

fn emit_a2a_recovered(session_id: &str, durable_name: &str, resume_sequence: u64) {
    let ts = chrono::Utc::now().to_rfc3339();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"fleet_a2a_recovered","session_id":"{session_id}","durable_name":"{durable_name}","resume_sequence":{resume_sequence}}}"#
    );
    let _ = append_ambient(&line);
}

fn emit_a2a_backpressure(session_id: &str, pending_count: i64, max_ack_pending: i64) {
    let ts = chrono::Utc::now().to_rfc3339();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"fleet_a2a_backpressure","session_id":"{session_id}","pending_count":{pending_count},"max_ack_pending":{max_ack_pending}}}"#
    );
    let _ = append_ambient(&line);
}

fn append_ambient(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let log = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)?;
    writeln!(f, "{}", line)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(kind: &str, session: Option<&str>) -> CoordEvent {
        CoordEvent {
            ts: "2026-05-24T00:00:00Z".to_string(),
            kind: kind.to_string(),
            session_id: session.map(String::from),
            payload: serde_json::json!({}),
        }
    }

    #[test]
    fn filter_all_accepts_everything() {
        let f = EventFilter::All;
        assert!(f.matches(&ev("anything", None)));
        assert!(f.matches(&ev("gap_claimed", Some("session-1"))));
    }

    #[test]
    fn filter_kind_exact_match() {
        let f = EventFilter::Kind("gap_claimed".to_string());
        assert!(f.matches(&ev("gap_claimed", None)));
        assert!(!f.matches(&ev("gap_resumed", None)));
    }

    #[test]
    fn filter_session_exact_match() {
        let f = EventFilter::Session("opus-1".to_string());
        assert!(f.matches(&ev("k", Some("opus-1"))));
        assert!(!f.matches(&ev("k", Some("opus-2"))));
        assert!(!f.matches(&ev("k", None)));
    }

    #[test]
    fn filter_kinds_set_match() {
        let f = EventFilter::Kinds(vec!["a".to_string(), "b".to_string()]);
        assert!(f.matches(&ev("a", None)));
        assert!(f.matches(&ev("b", None)));
        assert!(!f.matches(&ev("c", None)));
    }

    #[test]
    fn filter_to_nats_subject_kind() {
        let f = EventFilter::Kind("gap_claimed".to_string());
        assert_eq!(f.to_nats_subject(), "chump.events.gap_claimed");
    }

    #[test]
    fn filter_to_nats_subject_wildcard() {
        assert_eq!(EventFilter::All.to_nats_subject(), "chump.events.>");
        assert_eq!(
            EventFilter::Session("s".to_string()).to_nats_subject(),
            "chump.events.>"
        );
        assert_eq!(
            EventFilter::Kinds(vec!["a".to_string()]).to_nats_subject(),
            "chump.events.>"
        );
    }

    #[test]
    fn json_round_trip_event() {
        let e = CoordEvent {
            ts: "2026-05-24T01:02:03Z".to_string(),
            kind: "test".to_string(),
            session_id: Some("s1".to_string()),
            payload: serde_json::json!({"key": "value", "n": 42}),
        };
        let j = serde_json::to_string(&e).unwrap();
        let back: CoordEvent = serde_json::from_str(&j).unwrap();
        assert_eq!(e, back);
    }

    #[test]
    fn json_round_trip_filter() {
        for f in [
            EventFilter::All,
            EventFilter::Kind("foo".to_string()),
            EventFilter::Session("s".to_string()),
            EventFilter::Kinds(vec!["a".to_string(), "b".to_string()]),
        ] {
            let j = serde_json::to_string(&f).unwrap();
            let back: EventFilter = serde_json::from_str(&j).unwrap();
            assert_eq!(f, back);
        }
    }

    #[test]
    fn session_id_omitted_when_none() {
        let e = CoordEvent {
            ts: "t".to_string(),
            kind: "k".to_string(),
            session_id: None,
            payload: serde_json::json!({}),
        };
        let j = serde_json::to_string(&e).unwrap();
        assert!(!j.contains("session_id"));
    }

    /// Feature-gate: CHUMP_A2A_LAYER=0 (default) must return a stream without
    /// requiring NATS (file-only path). AC#7.
    #[tokio::test]
    async fn subscribe_layer0_no_nats_required() {
        std::env::remove_var("CHUMP_A2A_LAYER");
        let result = subscribe_events(EventFilter::All).await;
        assert!(
            result.is_ok(),
            "layer 0 subscribe must succeed without NATS: {:?}",
            result.err().map(|e| e.to_string())
        );
    }

    /// Feature-gate: CHUMP_A2A_LAYER=1 with NATS unreachable still returns Ok
    /// (fallback kicks in asynchronously). AC#3 / AC#7.
    #[tokio::test]
    async fn subscribe_layer1_returns_stream_even_without_nats() {
        std::env::set_var("CHUMP_A2A_LAYER", "1");
        std::env::set_var("CHUMP_NATS_TIMEOUT_MS", "200");
        std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:19999");
        let result = subscribe_events_with_session(
            EventFilter::All,
            Some("test-session-nats-absent".to_string()),
        )
        .await;
        assert!(
            result.is_ok(),
            "layer 1 subscribe must return Ok even when NATS unreachable"
        );
        std::env::remove_var("CHUMP_A2A_LAYER");
        std::env::remove_var("CHUMP_NATS_TIMEOUT_MS");
        std::env::remove_var("CHUMP_NATS_URL");
    }
}
