// crates/chump-coord/src/rpc.rs — INFRA-1119
//
// A2A Layer 2b: RPC request/response activation (slice 2/4).
//
// Implements:
// - call_rpc: publish to chump.rpc.<target>.<method>, await reply with deadline
// - serve_rpc: subscribe on chump.rpc.<session>.<method>, dispatch handler, reply
// - request_id dedup within 60s (retries safe)
// - 5 use-case wrappers: ask-eta, ask-overlap, ask-handoff, ask-progress, ask-capability
// - Ambient events: a2a_rpc_sent, a2a_rpc_timeout, a2a_rpc_send_failed,
//   a2a_rpc_handler_crash, a2a_rpc_registered
//
// Builds on: Layer 1a NATS subscribe (shipped in #2952).
// Do NOT edit: nats_primary.rs / events.rs / scratchpad.rs (other A2A PRs in flight).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Default RPC client deadline.
pub const DEFAULT_RPC_TIMEOUT_MS: u64 = 10_000;

/// Dedup window for idempotent retries.
pub const DEDUP_WINDOW_SECONDS: u64 = 60;

/// NATS subject prefix for RPC traffic.
const RPC_SUBJECT_PREFIX: &str = "chump.rpc";

// ── Wire types ────────────────────────────────────────────────────────────────

/// Request envelope sent from caller to target_session over Layer 2b.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcRequest {
    /// UUIDv4 identifier. Server dedups within DEDUP_WINDOW_SECONDS.
    pub request_id: String,
    /// Method name (e.g. "ask-eta", "ask-overlap").
    pub method: String,
    /// JSON payload — method-specific.
    pub args: serde_json::Value,
    /// ISO-8601 send time. Used to compute one-way latency.
    pub sent_at: String,
}

/// Response envelope returned from server-side handler.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcResponse {
    /// Mirrors `RpcRequest.request_id`.
    pub request_id: String,
    /// Method's typed result, or None when `error` is populated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    /// Server-side error string, or None on success.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Round-trip latency the server observed before responding.
    pub latency_ms: u64,
}

/// Error type for `call_rpc` and `serve_rpc`.
#[derive(Debug)]
pub enum RpcError {
    /// NATS connection not provided.
    NoNats,
    /// Client deadline expired before reply arrived.
    Timeout { request_id: String, timeout_ms: u64 },
    /// Handler panicked or returned an error (distinct from Timeout per AC-3).
    HandlerCrash { request_id: String, reason: String },
    /// NATS publish or subscribe failed.
    Transport(String),
    /// Wire-format decode error.
    Deserialize(serde_json::Error),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::NoNats => {
                write!(f, "NATS client not provided — call with a connected client")
            }
            RpcError::Timeout {
                request_id,
                timeout_ms,
            } => write!(
                f,
                "RPC timeout after {}ms (request_id={}) — INFRA-1119",
                timeout_ms, request_id
            ),
            RpcError::HandlerCrash { request_id, reason } => write!(
                f,
                "RPC handler crash (request_id={}): {} — INFRA-1119",
                request_id, reason
            ),
            RpcError::Transport(e) => write!(f, "NATS transport error: {e}"),
            RpcError::Deserialize(e) => write!(f, "deserialize failed: {e}"),
        }
    }
}

impl std::error::Error for RpcError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RpcError::Deserialize(e) => Some(e),
            _ => None,
        }
    }
}

impl RpcError {
    /// INFRA-2358: failure-class taxonomy for ambient events + retry policy.
    ///
    /// `transient` — NoNats/Timeout/Transport: a retry may succeed (broker
    /// hiccup, slow peer, dropped connection).
    /// `permanent` — HandlerCrash/Deserialize: retrying reproduces the same
    /// failure (peer's handler is broken, or the wire payload is malformed).
    pub fn failure_class(&self) -> &'static str {
        match self {
            RpcError::NoNats | RpcError::Timeout { .. } | RpcError::Transport(_) => "transient",
            RpcError::HandlerCrash { .. } | RpcError::Deserialize(_) => "permanent",
        }
    }
}

impl From<serde_json::Error> for RpcError {
    fn from(e: serde_json::Error) -> Self {
        RpcError::Deserialize(e)
    }
}

// ── Dedup table ───────────────────────────────────────────────────────────────

/// In-memory dedup table. Maps `request_id` → first-seen `Instant`.
/// Evicts entries older than DEDUP_WINDOW_SECONDS opportunistically on each
/// `record()` call.
pub struct DedupTable {
    seen: Mutex<HashMap<String, Instant>>,
}

impl DedupTable {
    pub fn new() -> Self {
        Self {
            seen: Mutex::new(HashMap::new()),
        }
    }

    /// Record + check: returns true if `request_id` is new (caller should
    /// process), false if already-seen within the dedup window.
    pub fn record(&self, request_id: &str) -> bool {
        let mut g = self.seen.lock().expect("dedup poisoned");
        let now = Instant::now();
        let window = std::time::Duration::from_secs(DEDUP_WINDOW_SECONDS);
        g.retain(|_, t| now.duration_since(*t) < window);
        if g.contains_key(request_id) {
            false
        } else {
            g.insert(request_id.to_string(), now);
            true
        }
    }

    pub fn len(&self) -> usize {
        self.seen.lock().expect("dedup poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Default for DedupTable {
    fn default() -> Self {
        Self::new()
    }
}

// ── ID generation ─────────────────────────────────────────────────────────────

/// Generate a new UUIDv4 request_id.
pub fn new_request_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

// ── RPC client ────────────────────────────────────────────────────────────────

/// Send an RPC to a peer session over NATS req-reply.
///
/// Publishes `RpcRequest` to `chump.rpc.<target_session>.<method>`.
/// Awaits a `RpcResponse` on the auto-generated NATS reply subject.
/// Emits `a2a_rpc_sent` on publish; `a2a_rpc_timeout` on deadline exceeded.
///
/// Falls back to `RpcError::NoNats` if no NATS client is available.
pub async fn call_rpc(
    target_session: &str,
    method: &str,
    args: serde_json::Value,
    timeout_ms: u64,
) -> Result<RpcResponse, RpcError> {
    call_rpc_with_nats(None, target_session, method, args, timeout_ms).await
}

/// Like `call_rpc` but accepts an explicit NATS client (for testing / worker integration).
pub async fn call_rpc_with_nats(
    nats: Option<&async_nats::Client>,
    target_session: &str,
    method: &str,
    args: serde_json::Value,
    timeout_ms: u64,
) -> Result<RpcResponse, RpcError> {
    let request_id = new_request_id();
    let sent_at = chrono::Utc::now().to_rfc3339();

    let req = RpcRequest {
        request_id: request_id.clone(),
        method: method.to_string(),
        args,
        sent_at: sent_at.clone(),
    };
    let payload = serde_json::to_vec(&req).map_err(RpcError::Deserialize)?;
    let subject = format!("{}.{}.{}", RPC_SUBJECT_PREFIX, target_session, method);

    // Emit a2a_rpc_sent before attempting publish
    let sent_line = format!(
        r#"{{"ts":"{sent_at}","kind":"a2a_rpc_sent","method":"{method}","target":"{target_session}","request_id":"{request_id}"}}"#
    );
    let _ = append_ambient(&sent_line);

    let client = match nats {
        Some(c) => c,
        None => {
            // No NATS client available — emit rpc_send_failed and return error
            let err = RpcError::NoNats;
            let ts = chrono::Utc::now().to_rfc3339();
            let fail_line = format!(
                r#"{{"ts":"{ts}","kind":"a2a_rpc_send_failed","method":"{method}","target":"{target_session}","request_id":"{request_id}","failure_class":"{}"}}"#,
                err.failure_class()
            );
            let _ = append_ambient(&fail_line);
            return Err(err);
        }
    };

    // Publish with NATS request — reply subject is auto-generated
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_millis(timeout_ms);

    let reply_msg = match tokio::time::timeout(
        timeout,
        client.request(subject, bytes::Bytes::from(payload)),
    )
    .await
    {
        Ok(Ok(msg)) => msg,
        Ok(Err(e)) => {
            let err = RpcError::Transport(e.to_string());
            let ts = chrono::Utc::now().to_rfc3339();
            let fail_line = format!(
                r#"{{"ts":"{ts}","kind":"a2a_rpc_send_failed","method":"{method}","target":"{target_session}","request_id":"{request_id}","failure_class":"{}"}}"#,
                err.failure_class()
            );
            let _ = append_ambient(&fail_line);
            return Err(err);
        }
        Err(_elapsed) => {
            // Deadline exceeded — emit a2a_rpc_timeout
            let err = RpcError::Timeout {
                request_id: request_id.clone(),
                timeout_ms,
            };
            let ts = chrono::Utc::now().to_rfc3339();
            let timeout_line = format!(
                r#"{{"ts":"{ts}","kind":"a2a_rpc_timeout","request_id":"{request_id}","timeout_s":{},"failure_class":"{}"}}"#,
                timeout_ms / 1000,
                err.failure_class()
            );
            let _ = append_ambient(&timeout_line);
            return Err(err);
        }
    };

    let elapsed_ms = start.elapsed().as_millis() as u64;

    // Deserialize response
    let mut response: RpcResponse = match serde_json::from_slice(&reply_msg.payload) {
        Ok(r) => r,
        Err(e) => {
            let err = RpcError::Deserialize(e);
            let ts = chrono::Utc::now().to_rfc3339();
            let fail_line = format!(
                r#"{{"ts":"{ts}","kind":"a2a_rpc_send_failed","method":"{method}","target":"{target_session}","request_id":"{request_id}","failure_class":"{}"}}"#,
                err.failure_class()
            );
            let _ = append_ambient(&fail_line);
            return Err(err);
        }
    };
    // Patch latency if server didn't fill it
    if response.latency_ms == 0 {
        response.latency_ms = elapsed_ms;
    }

    // Check for handler crash reported by server
    if let Some(ref err_str) = response.error {
        if err_str.starts_with("handler_crash:") {
            let reason = err_str
                .trim_start_matches("handler_crash:")
                .trim()
                .to_string();
            let err = RpcError::HandlerCrash {
                request_id: response.request_id.clone(),
                reason: reason.clone(),
            };
            let ts = chrono::Utc::now().to_rfc3339();
            let crash_line = format!(
                r#"{{"ts":"{ts}","kind":"a2a_rpc_handler_crash","method":"{method}","session":"{target_session}","request_id":"{}","reason":"{}","failure_class":"{}"}}"#,
                response.request_id,
                reason,
                err.failure_class()
            );
            let _ = append_ambient(&crash_line);
            return Err(err);
        }
    }

    // Success — exactly one of {finished, timeout, send_failed, handler_crash}
    // has now fired for this call (INFRA-2358 AC-1). Cost signal is latency_ms
    // since RPC calls are NATS-native with no LLM spend (INFRA-2358 AC-2).
    let ts = chrono::Utc::now().to_rfc3339();
    let finished_line = format!(
        r#"{{"ts":"{ts}","kind":"a2a_rpc_finished","method":"{method}","target":"{target_session}","request_id":"{}","latency_ms":{}}}"#,
        response.request_id, response.latency_ms
    );
    let _ = append_ambient(&finished_line);

    Ok(response)
}

// ── RPC server ────────────────────────────────────────────────────────────────

/// Register a per-method handler on `chump.rpc.<session_id>.<method>`.
///
/// Spawns a background tokio task that subscribes to the subject, applies
/// dedup, calls `handler(args)`, and publishes the response to the reply
/// subject. Handler panics are caught and returned as `a2a_rpc_handler_crash`
/// events with error="handler_crash: <reason>" in the response.
///
/// Returns immediately after registering the subscription; the background
/// task runs until the NATS connection is closed.
pub async fn serve_rpc<F>(method: &str, handler: F) -> Result<(), RpcError>
where
    F: Fn(serde_json::Value) -> Result<serde_json::Value, String> + Send + Sync + 'static,
{
    serve_rpc_with_nats(None, "local", method, handler).await
}

/// Like `serve_rpc` but accepts explicit NATS client + session_id.
/// This is the path used by worker startup.
pub async fn serve_rpc_with_nats<F>(
    nats: Option<&async_nats::Client>,
    session_id: &str,
    method: &str,
    handler: F,
) -> Result<(), RpcError>
where
    F: Fn(serde_json::Value) -> Result<serde_json::Value, String> + Send + Sync + 'static,
{
    let client = match nats {
        Some(c) => c,
        None => {
            let ts = chrono::Utc::now().to_rfc3339();
            let line = format!(
                r#"{{"ts":"{ts}","kind":"a2a_rpc_registered","method":"{method}","session":"{session_id}","nats":"unavailable"}}"#
            );
            let _ = append_ambient(&line);
            return Err(RpcError::NoNats);
        }
    };

    let subject = format!("{}.{}.{}", RPC_SUBJECT_PREFIX, session_id, method);
    let mut sub = client
        .subscribe(subject.clone())
        .await
        .map_err(|e| RpcError::Transport(e.to_string()))?;

    let ts = chrono::Utc::now().to_rfc3339();
    let reg_line = format!(
        r#"{{"ts":"{ts}","kind":"a2a_rpc_registered","method":"{method}","session":"{session_id}","subject":"{subject}"}}"#
    );
    let _ = append_ambient(&reg_line);

    let method_owned = method.to_string();
    let session_owned = session_id.to_string();
    let handler = Arc::new(handler);
    let dedup = Arc::new(DedupTable::new());
    let nats_clone = client.clone();

    tokio::spawn(async move {
        use futures::StreamExt;
        while let Some(msg) = sub.next().await {
            let request: RpcRequest = match serde_json::from_slice(&msg.payload) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!(
                        "[rpc-serve] {} deserialize error on {}: {}",
                        session_owned, method_owned, e
                    );
                    continue;
                }
            };

            // Dedup — if already seen, skip (reply was already sent on first delivery)
            if !dedup.record(&request.request_id) {
                eprintln!(
                    "[rpc-serve] {} dedup hit for request_id={}",
                    session_owned, request.request_id
                );
                continue;
            }

            let reply_subject = match msg.reply {
                Some(ref s) => s.clone(),
                None => {
                    eprintln!(
                        "[rpc-serve] {} no reply subject on request_id={}",
                        session_owned, request.request_id
                    );
                    continue;
                }
            };

            let start = std::time::Instant::now();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                handler(request.args.clone())
            }));

            let latency_ms = start.elapsed().as_millis() as u64;
            let response = match result {
                Ok(Ok(val)) => RpcResponse {
                    request_id: request.request_id.clone(),
                    result: Some(val),
                    error: None,
                    latency_ms,
                },
                Ok(Err(err_str)) => {
                    // Handler returned Err — emit handler_crash event
                    let ts = chrono::Utc::now().to_rfc3339();
                    let crash_line = format!(
                        r#"{{"ts":"{ts}","kind":"a2a_rpc_handler_crash","method":"{method_owned}","session":"{session_owned}","request_id":"{}","reason":"{err_str}","failure_class":"permanent"}}"#,
                        request.request_id
                    );
                    let _ = append_ambient(&crash_line);
                    RpcResponse {
                        request_id: request.request_id.clone(),
                        result: None,
                        error: Some(format!("handler_crash: {err_str}")),
                        latency_ms,
                    }
                }
                Err(panic_val) => {
                    // Handler panicked — stringify and emit handler_crash
                    let reason = if let Some(s) = panic_val.downcast_ref::<&str>() {
                        s.to_string()
                    } else if let Some(s) = panic_val.downcast_ref::<String>() {
                        s.clone()
                    } else {
                        "unknown panic".to_string()
                    };
                    let ts = chrono::Utc::now().to_rfc3339();
                    let crash_line = format!(
                        r#"{{"ts":"{ts}","kind":"a2a_rpc_handler_crash","method":"{method_owned}","session":"{session_owned}","request_id":"{}","reason":"{reason}","failure_class":"permanent"}}"#,
                        request.request_id
                    );
                    let _ = append_ambient(&crash_line);
                    RpcResponse {
                        request_id: request.request_id.clone(),
                        result: None,
                        error: Some(format!("handler_crash: {reason}")),
                        latency_ms,
                    }
                }
            };

            let payload = match serde_json::to_vec(&response) {
                Ok(b) => b,
                Err(e) => {
                    eprintln!(
                        "[rpc-serve] {} serialize response failed: {}",
                        session_owned, e
                    );
                    continue;
                }
            };

            if let Err(e) = nats_clone
                .publish(reply_subject, bytes::Bytes::from(payload))
                .await
            {
                eprintln!("[rpc-serve] {} reply publish failed: {}", session_owned, e);
            }
        }
    });

    Ok(())
}

// ── 5 use-case wrappers ───────────────────────────────────────────────────────

/// Ask a peer session when it expects to complete a gap.
///
/// Args: `{"gap_id": "<ID>"}` (optional: `"include_subtasks": true`)
/// Response: `{"eta_seconds": <N>}` or `{"eta_seconds": null}` if unknown.
pub async fn ask_eta(
    nats: &async_nats::Client,
    target_session: &str,
    gap_id: &str,
) -> Result<RpcResponse, RpcError> {
    call_rpc_with_nats(
        Some(nats),
        target_session,
        "ask-eta",
        serde_json::json!({"gap_id": gap_id}),
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await
}

/// Ask a peer whether it overlaps with a set of files.
///
/// Args: `{"files": ["path/to/a.rs", ...]}`
/// Response: `{"overlaps": true, "files": [...overlapping...]}` or `{"overlaps": false}`.
pub async fn ask_overlap(
    nats: &async_nats::Client,
    target_session: &str,
    files: &[&str],
) -> Result<RpcResponse, RpcError> {
    call_rpc_with_nats(
        Some(nats),
        target_session,
        "ask-overlap",
        serde_json::json!({"files": files}),
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await
}

/// Initiate a handoff to a peer session (transfer a gap claim).
///
/// Args: `{"gap_id": "<ID>", "reason": "<why>"}` (optional: `"context": {...}`)
/// Response: `{"accepted": true}` or `{"accepted": false, "reason": "<why>"}`.
pub async fn ask_handoff(
    nats: &async_nats::Client,
    target_session: &str,
    gap_id: &str,
    reason: &str,
) -> Result<RpcResponse, RpcError> {
    call_rpc_with_nats(
        Some(nats),
        target_session,
        "ask-handoff",
        serde_json::json!({"gap_id": gap_id, "reason": reason}),
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await
}

/// Ask a peer for its current progress on a gap.
///
/// Args: `{"gap_id": "<ID>"}`
/// Response: `{"status": "claimed|implementing|reviewing", "pct_complete": <0-100>, "subtasks_done": <N>}`.
pub async fn ask_progress(
    nats: &async_nats::Client,
    target_session: &str,
    gap_id: &str,
) -> Result<RpcResponse, RpcError> {
    call_rpc_with_nats(
        Some(nats),
        target_session,
        "ask-progress",
        serde_json::json!({"gap_id": gap_id}),
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await
}

/// Ask a peer what capabilities it supports.
///
/// Args: `{}` (optional: `"capability": "<name>"` to check a specific skill)
/// Response: `{"capabilities": ["rust", "python", ...]}` or `{"present": true/false}` for specific check.
pub async fn ask_capability(
    nats: &async_nats::Client,
    target_session: &str,
    capability: Option<&str>,
) -> Result<RpcResponse, RpcError> {
    let args = match capability {
        Some(cap) => serde_json::json!({"capability": cap}),
        None => serde_json::json!({}),
    };
    call_rpc_with_nats(
        Some(nats),
        target_session,
        "ask-capability",
        args,
        DEFAULT_RPC_TIMEOUT_MS,
    )
    .await
}

// ── Worker integration ────────────────────────────────────────────────────────

/// Register all 5 standard RPC method handlers for a worker session.
///
/// Called from worker startup when a NATS connection is available.
/// Emits a `session_start` ambient event, starts a background heartbeat,
/// and subscribes handlers for the 5 standard peer-RPC methods so the
/// worker is a live, queryable participant rather than silent/unattributed.
///
/// Returns a success payload `{"registered": true, "session_id": "<id>"}`
/// once every handler is subscribed.
pub async fn register_worker_rpc_handlers(
    nats: &async_nats::Client,
    session_id: &str,
) -> Result<serde_json::Value, RpcError> {
    // INFRA-1588: Emit session_start to ambient for worker attribution.
    let start_event = format!(
        "{{\"ts\":\"{}\",\"session\":\"{}\",\"kind\":\"session_start\",\"role\":\"worker\"}}",
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        session_id
    );
    let _ = append_ambient(&start_event);

    // Start background heartbeat task for this worker session.
    let session_clone = session_id.to_string();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            let hb = format!(
                "{{\"ts\":\"{}\",\"session\":\"{}\",\"kind\":\"heartbeat\"}}",
                chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                session_clone
            );
            let _ = append_ambient(&hb);
        }
    });

    // ask-eta stub handler
    serve_rpc_with_nats(Some(nats), session_id, "ask-eta", |_args| {
        Ok(serde_json::json!({"eta_seconds": null}))
    })
    .await?;

    // ask-overlap stub handler
    serve_rpc_with_nats(Some(nats), session_id, "ask-overlap", |args| {
        let empty: Vec<String> = vec![];
        let files = args
            .get("files")
            .and_then(|f| f.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect::<Vec<_>>()
            })
            .unwrap_or(empty);
        let _ = files;
        Ok(serde_json::json!({"overlaps": false}))
    })
    .await?;

    // ask-handoff stub handler
    serve_rpc_with_nats(Some(nats), session_id, "ask-handoff", |_args| {
        Ok(serde_json::json!({"accepted": false, "reason": "handoff not implemented in this worker"}))
    })
    .await?;

    // ask-progress stub handler
    serve_rpc_with_nats(Some(nats), session_id, "ask-progress", |_args| {
        Ok(serde_json::json!({"status": "unknown", "pct_complete": 0}))
    })
    .await?;

    // ask-capability: report capabilities from env
    let caps: Vec<String> = std::env::var("WORKER_SKILLS")
        .unwrap_or_default()
        .split(',')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    let caps_json = serde_json::to_string(&caps).unwrap_or_else(|_| "[]".to_string());
    serve_rpc_with_nats(Some(nats), session_id, "ask-capability", move |args| {
        let caps: Vec<String> = serde_json::from_str(&caps_json).unwrap_or_default();
        if let Some(cap_name) = args.get("capability").and_then(|v| v.as_str()) {
            let present = caps.iter().any(|c| c == cap_name);
            Ok(serde_json::json!({"present": present}))
        } else {
            Ok(serde_json::json!({"capabilities": caps}))
        }
    })
    .await?;

    // prune_ledger: return the deterministic set of low-Crit dormant ledger
    // entry ids eligible for pruning (CREDIBLE-1049, CREDIBLE-356 slice).
    // args: {"entries": [{"id","criticality","dormant","timestamp"}, ...], "threshold": f64}
    serve_rpc_with_nats(Some(nats), session_id, "prune_ledger", |args| {
        let entries: Vec<crate::ledger::LedgerEntry> = args
            .get("entries")
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|e: serde_json::Error| e.to_string())?
            .unwrap_or_default();
        let threshold = args
            .get("threshold")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.5);
        let pruned = crate::ledger::prune_ledger(&entries, threshold);
        Ok(serde_json::json!({"pruned": pruned}))
    })
    .await?;

    Ok(serde_json::json!({"registered": true, "session_id": session_id}))
}

/// Like [`register_worker_rpc_handlers`] but also registers this worker's
/// [`crate::presence::WorkerPresence`] record in the `chump_workers` NATS-KV
/// bucket (CREDIBLE-246 / CREDIBLE-099 slice) and refreshes it every 60s
/// alongside the existing ambient heartbeat, so a worker's presence — not
/// just its RPC handlers — is discoverable in NATS.
pub async fn register_worker_rpc_handlers_with_presence(
    nats: &async_nats::Client,
    session_id: &str,
    presence_kv: &async_nats::jetstream::kv::Store,
) -> Result<(), RpcError> {
    register_worker_rpc_handlers(nats, session_id).await?;

    let presence = crate::presence::build_presence(session_id, None);
    if let Err(e) = crate::presence::register_presence(presence_kv, &presence).await {
        eprintln!("[presence] register failed (non-fatal): {}", e);
    }

    let kv_clone = presence_kv.clone();
    let session_clone = session_id.to_string();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(e) = crate::presence::refresh_presence(&kv_clone, &session_clone).await {
                eprintln!("[presence] heartbeat refresh failed (non-fatal): {}", e);
            }
        }
    });

    // CREDIBLE-250 (CREDIBLE-099 slice): "register-worker" RPC handler — lets
    // a peer explicitly (re)register a `WorkerPresence` record for this
    // session over NATS RPC, distinct from the self-registration above which
    // only runs once at this worker's own startup. The handler itself is a
    // sync closure (per `serve_rpc_with_nats`'s bound), so the actual async
    // KV write happens on a background task fed via an unbounded channel;
    // the handler acks immediately with a success response once the request
    // is queued.
    let (register_tx, mut register_rx) =
        tokio::sync::mpsc::unbounded_channel::<crate::presence::WorkerPresence>();
    let register_kv = presence_kv.clone();
    tokio::spawn(async move {
        while let Some(presence) = register_rx.recv().await {
            if let Err(e) = crate::presence::register_presence(&register_kv, &presence).await {
                eprintln!(
                    "[presence] register-worker RPC store failed (non-fatal): {}",
                    e
                );
            }
        }
    });

    let register_session = session_id.to_string();
    serve_rpc_with_nats(Some(nats), session_id, "register-worker", move |args| {
        let worker_id = args
            .get("worker_id")
            .and_then(|v| v.as_str())
            .unwrap_or(&register_session)
            .to_string();
        let current_gap = args
            .get("current_gap")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let mut presence = crate::presence::build_presence(&worker_id, current_gap);
        if let Some(backend) = args.get("backend").and_then(|v| v.as_str()) {
            presence.backend = backend.to_string();
        }
        if let Some(machine) = args.get("machine").and_then(|v| v.as_str()) {
            presence.machine = Some(machine.to_string());
        }
        if let Some(harness) = args.get("harness").and_then(|v| v.as_str()) {
            presence.harness = harness.to_string();
        }
        if let Some(skills) = args.get("skills").and_then(|v| v.as_array()) {
            presence.skills = skills
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect();
        }

        let result = serde_json::json!({"registered": true, "worker_id": presence.worker_id});
        register_tx
            .send(presence)
            .map_err(|e| format!("register-worker channel closed: {}", e))?;
        Ok(result)
    })
    .await?;

    // CREDIBLE-261 (CREDIBLE-099 slice): "deregister-worker" RPC handler —
    // lets a peer explicitly remove this session's `WorkerPresence` record
    // from the `chump_workers` NATS-KV bucket, e.g. on graceful shutdown.
    // Mirrors the register-worker handler above: sync closure hands off to a
    // background task over an unbounded channel, and acks immediately once
    // the request is queued.
    let (deregister_tx, mut deregister_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let deregister_kv = presence_kv.clone();
    tokio::spawn(async move {
        while let Some(worker_id) = deregister_rx.recv().await {
            if let Err(e) = crate::presence::deregister_presence(&deregister_kv, &worker_id).await {
                eprintln!(
                    "[presence] deregister-worker RPC removal failed (non-fatal): {}",
                    e
                );
            }
        }
    });

    let deregister_session = session_id.to_string();
    serve_rpc_with_nats(Some(nats), session_id, "deregister-worker", move |args| {
        let worker_id = args
            .get("worker_id")
            .and_then(|v| v.as_str())
            .unwrap_or(&deregister_session)
            .to_string();

        let result = serde_json::json!({"deregistered": true, "worker_id": worker_id});
        deregister_tx
            .send(worker_id)
            .map_err(|e| format!("deregister-worker channel closed: {}", e))?;
        Ok(result)
    })
    .await?;

    Ok(())
}

// ── Ambient helper ───────────────────────────────────────────────────────────

fn append_ambient(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let log = std::env::var("CHUMP_AMBIENT_LOG")
        .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string());

    // INFRA-1588: avoid absolute path if it starts with current dir to stay portable in worktrees.
    let log_path = if let Ok(cwd) = std::env::current_dir() {
        let p = std::path::PathBuf::from(&log);
        if p.is_absolute() && p.starts_with(&cwd) {
            p.strip_prefix(&cwd).unwrap().to_path_buf()
        } else {
            p
        }
    } else {
        std::path::PathBuf::from(&log)
    };

    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    writeln!(f, "{}", line)
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_sane() {
        assert_eq!(DEFAULT_RPC_TIMEOUT_MS, 10_000);
        assert_eq!(DEDUP_WINDOW_SECONDS, 60);
    }

    #[test]
    fn dedup_table_accepts_new_rejects_duplicate() {
        let t = DedupTable::new();
        assert!(t.record("req-1"));
        assert!(!t.record("req-1"), "duplicate should be rejected");
        assert!(t.record("req-2"));
        assert_eq!(t.len(), 2);
    }

    #[test]
    fn new_request_id_unique_per_call() {
        let a = new_request_id();
        let b = new_request_id();
        assert_ne!(a, b, "UUIDs should be distinct");
    }

    #[test]
    fn new_request_id_is_valid_uuid() {
        let id = new_request_id();
        assert!(
            uuid::Uuid::parse_str(&id).is_ok(),
            "should be a valid UUID: {id}"
        );
    }

    #[test]
    fn request_json_round_trip() {
        let r = RpcRequest {
            request_id: "abc-123".to_string(),
            method: "ask-eta".to_string(),
            args: serde_json::json!({"gap_id": "INFRA-1119"}),
            sent_at: "2026-05-23T15:00:00Z".to_string(),
        };
        let j = serde_json::to_string(&r).unwrap();
        let back: RpcRequest = serde_json::from_str(&j).unwrap();
        assert_eq!(r, back);
    }

    #[test]
    fn response_omits_none_fields() {
        let r = RpcResponse {
            request_id: "abc-123".to_string(),
            result: Some(serde_json::json!({"eta_seconds": 120})),
            error: None,
            latency_ms: 42,
        };
        let j = serde_json::to_string(&r).unwrap();
        assert!(!j.contains("\"error\""), "None error should be omitted");
        assert!(j.contains("\"result\""), "Some result should be present");
    }

    #[test]
    fn rpc_error_timeout_display_mentions_infra() {
        let e = RpcError::Timeout {
            request_id: "req-1".to_string(),
            timeout_ms: 10_000,
        };
        let s = format!("{e}");
        assert!(
            s.contains("INFRA-1119"),
            "timeout error should reference INFRA-1119: {s}"
        );
    }

    #[test]
    fn rpc_error_handler_crash_display_mentions_infra() {
        let e = RpcError::HandlerCrash {
            request_id: "req-1".to_string(),
            reason: "test".to_string(),
        };
        let s = format!("{e}");
        assert!(
            s.contains("INFRA-1119"),
            "handler_crash error should reference INFRA-1119: {s}"
        );
    }

    #[tokio::test]
    async fn call_rpc_no_nats_returns_no_nats_error() {
        // Without NATS, call_rpc_with_nats(None, ...) should return NoNats
        let result = call_rpc_with_nats(
            None,
            "peer-session",
            "ask-eta",
            serde_json::json!({"gap_id": "INFRA-1119"}),
            DEFAULT_RPC_TIMEOUT_MS,
        )
        .await;
        assert!(
            matches!(result, Err(RpcError::NoNats)),
            "expected NoNats, got: {:?}",
            result.err().map(|e| e.to_string())
        );
    }

    #[tokio::test]
    async fn serve_rpc_no_nats_returns_no_nats_error() {
        let result = serve_rpc_with_nats(None, "session-1", "ask-eta", |_| {
            Ok(serde_json::json!({"eta_seconds": 30}))
        })
        .await;
        assert!(matches!(result, Err(RpcError::NoNats)), "expected NoNats");
    }

    #[test]
    fn dedup_table_size_tracks_unique_entries() {
        let t = DedupTable::new();
        for i in 0..5 {
            t.record(&format!("req-{i}"));
        }
        assert_eq!(t.len(), 5);
        // Re-recording doesn't grow the table
        for i in 0..5 {
            t.record(&format!("req-{i}"));
        }
        assert_eq!(t.len(), 5);
    }

    // ── INFRA-2358: failure_class taxonomy ──────────────────────────────────

    #[test]
    fn failure_class_no_nats_is_transient() {
        assert_eq!(RpcError::NoNats.failure_class(), "transient");
    }

    #[test]
    fn failure_class_timeout_is_transient() {
        let e = RpcError::Timeout {
            request_id: "req-1".to_string(),
            timeout_ms: 10_000,
        };
        assert_eq!(e.failure_class(), "transient");
    }

    #[test]
    fn failure_class_transport_is_transient() {
        let e = RpcError::Transport("connection reset".to_string());
        assert_eq!(e.failure_class(), "transient");
    }

    #[test]
    fn failure_class_handler_crash_is_permanent() {
        let e = RpcError::HandlerCrash {
            request_id: "req-1".to_string(),
            reason: "boom".to_string(),
        };
        assert_eq!(e.failure_class(), "permanent");
    }

    #[test]
    fn failure_class_deserialize_is_permanent() {
        let json_err = serde_json::from_str::<RpcRequest>("not json").unwrap_err();
        let e = RpcError::Deserialize(json_err);
        assert_eq!(e.failure_class(), "permanent");
    }

    #[tokio::test]
    async fn call_rpc_no_nats_emits_send_failed_with_failure_class() {
        let tmp = std::env::temp_dir().join(format!("chump-rpc-test-{}", new_request_id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let ambient_path = tmp.join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", ambient_path.to_str().unwrap());

        let result = call_rpc_with_nats(
            None,
            "peer-session",
            "ask-eta",
            serde_json::json!({}),
            DEFAULT_RPC_TIMEOUT_MS,
        )
        .await;
        assert!(matches!(result, Err(RpcError::NoNats)));

        let contents = std::fs::read_to_string(&ambient_path).unwrap_or_default();
        assert!(
            contents.contains("\"kind\":\"a2a_rpc_send_failed\""),
            "expected a2a_rpc_send_failed in ambient log: {contents}"
        );
        assert!(
            contents.contains("\"failure_class\":\"transient\""),
            "expected failure_class=transient: {contents}"
        );

        std::env::remove_var("CHUMP_AMBIENT_LOG");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
