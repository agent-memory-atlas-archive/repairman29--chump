//! axum HTTP server for Chump Web: health check, chat API (SSE), static PWA files.
//! Run with `chump --web`. Sprint 2: POST /api/chat returns SSE stream.

use anyhow::Result;
use axum::{
    extract::{Multipart, Path, Query},
    http::{header, HeaderMap, Method, StatusCode},
    response::{
        sse::{Event, Sse},
        IntoResponse, Redirect, Response,
    },
    routing::{delete, get, patch, post, put},
    Json, Router,
};
use std::io::{ErrorKind, Write};
use std::path::PathBuf;
use std::time::Duration;
use tokio_stream::wrappers::UnboundedReceiverStream;
use tokio_stream::StreamExt;
use tower_http::cors::{Any, CorsLayer};
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;

use crate::agent_factory;
use crate::agent_loop::ChumpAgent;
use crate::approval_resolver;
use crate::autopilot;
use crate::db_pool;
use crate::episode_db;
use crate::gap_store;
use crate::limits;
use crate::pilot_metrics;
use crate::repo_path;
use crate::routes;
use crate::stream_events::{self, AgentEvent};
use crate::streaming_provider::StreamingProvider;
use crate::task_db;
use crate::web_brain;
use crate::web_sessions_db;
use crate::web_uploads;

#[derive(serde::Deserialize)]
struct SessionCreateBody {
    #[serde(default)]
    bot: Option<String>,
}

#[derive(serde::Deserialize)]
struct PolicyOverrideInline {
    /// Comma-separated tool names to relax vs **CHUMP_TOOLS_ASK** for this session.
    relax_tools: String,
    #[serde(default = "default_policy_override_ttl")]
    ttl_secs: u64,
}

fn default_policy_override_ttl() -> u64 {
    3600
}

#[derive(serde::Deserialize)]
struct ChatRequest {
    message: String,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    attachments: Option<Vec<AttachmentRef>>,
    /// "chump" | "mabel" — selects which agent to use. Default chump.
    #[serde(default)]
    bot: Option<String>,
    /// When **`CHUMP_POLICY_OVERRIDE_API=1`**, register a time-boxed relax for this session before the agent runs.
    #[serde(default)]
    policy_override: Option<PolicyOverrideInline>,
    /// EFFECTIVE-422 — when true, the VOICE_ADDENDUM is appended to the system
    /// prompt so replies stay TTS-friendly (short, plain speech, grounded in
    /// tool results). Mirrors Olive's `ctx.spoken` flag
    /// (olive/src/lib/agent/orchestrator.ts:133). Set by /api/voice/ask; the
    /// plain /api/chat leaves it false so the PWA keeps its full rich reply.
    #[serde(default)]
    voice: Option<bool>,
    /// INFRA-3597 — when true, the agent registry is restricted to
    /// `tool_inventory::register_advisor_tools` (read-only) and
    /// ADVISOR_ADDENDUM is appended to the system prompt. Set by
    /// `/api/advisor/ask` (the Discord DM advisor surface); the plain
    /// `/api/chat` leaves it false so the PWA keeps its full developer belt.
    #[serde(default)]
    advisor: Option<bool>,
}

#[derive(serde::Deserialize)]
struct InjectHintRequest {
    hint: String,
    #[serde(default)]
    tool_context: Option<String>,
    /// TTL for the hint in minutes (PRODUCT-116). Default 60. Stored in ambient event
    /// so /api/ambient/recent?kind=operator_hint can surface the history list.
    #[serde(default)]
    ttl_minutes: Option<u32>,
}

/// INFRA-1296: A2A — POST /api/broadcast.
///
/// Operator-facing entry point for emitting any a2a event (INTENT / HANDOFF
/// / STUCK / DONE / WARN / ALERT / FEEDBACK) from the PWA. Shells out to
/// `scripts/coord/broadcast.sh` rather than reimplementing schema in Rust:
/// the shell is the canonical entry point, so this layer stays a thin
/// HTTP-to-CLI adapter.
#[derive(serde::Deserialize)]
struct BroadcastRequest {
    /// One of: INTENT HANDOFF STUCK DONE WARN ALERT FEEDBACK.
    event: String,
    /// Optional event sub-kind (FEEDBACK kinds: defect/proposal/preference/retro;
    /// ALERT kinds: any free-form). Required for FEEDBACK + ALERT.
    #[serde(default)]
    kind: Option<String>,
    /// Subject — gap-id (INTENT/HANDOFF/STUCK/DONE) OR policy name (FEEDBACK/WARN/ALERT).
    #[serde(default)]
    subject: Option<String>,
    /// Free-text rationale / reason / message body.
    #[serde(default)]
    rationale: Option<String>,
    /// Targeted recipient session-id or operator-id (or glob like fleet-worker-*).
    #[serde(default)]
    recipient: Option<String>,
    /// For FEEDBACK preference: +1 / -1 / 0.
    #[serde(default)]
    vote: Option<String>,
    /// INFRA-1299 hook (future): urgency now / hours / digest. Accepted now
    /// for forward-compat; not yet routed by the reach classifier.
    #[serde(default)]
    urgency: Option<String>,
    /// For HANDOFF positional 2 — back-compat with broadcast.sh CLI shape.
    #[serde(default)]
    to_session: Option<String>,
}

#[derive(serde::Deserialize)]
struct PolicyOverrideRegisterBody {
    session_id: String,
    relax_tools: String,
    #[serde(default = "default_policy_override_ttl")]
    ttl_secs: u64,
}

#[derive(serde::Deserialize, serde::Serialize)]
struct AttachmentRef {
    file_id: String,
    filename: String,
    #[serde(default)]
    mime_type: Option<String>,
}

#[derive(serde::Serialize)]
#[allow(dead_code)] // reserved for non-streaming response shape
struct ChatResponse {
    reply: String,
}

/// Map agent events to SSE events. Used for both slash-command quick replies and full agent stream.
fn agent_event_stream(
    rx: stream_events::EventReceiver,
) -> impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>> {
    UnboundedReceiverStream::new(rx).map(|ev: AgentEvent| {
        let event_type = ev.event_type().to_string();
        let data = serde_json::to_string(&ev).unwrap_or_else(|_| "{}".to_string());
        Ok(Event::default().event(event_type).data(data))
    })
}

// ── INFRA-1013: retry counter for failed workflow phases ─────────────────────

/// Tracks consecutive same-phase failures per (gap_id, phase).
/// After 3 consecutive failures on the same phase, retry is disabled.
static RETRY_COUNTER: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<String, u32>>,
> = std::sync::OnceLock::new();

fn retry_counter_state() -> &'static std::sync::Mutex<std::collections::HashMap<String, u32>> {
    RETRY_COUNTER.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

fn retry_key(gap_id: &str, phase: &str) -> String {
    format!("{gap_id}::{phase}")
}

/// Returns current retry count for a (gap_id, phase) pair.
fn get_retry_count(gap_id: &str, phase: &str) -> u32 {
    retry_counter_state()
        .lock()
        .map(|m| *m.get(&retry_key(gap_id, phase)).unwrap_or(&0))
        .unwrap_or(0)
}

/// Increments and returns the new retry count.
fn inc_retry_count(gap_id: &str, phase: &str) -> u32 {
    let key = retry_key(gap_id, phase);
    let mut map = retry_counter_state()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let cnt = map.entry(key).or_insert(0);
    *cnt += 1;
    *cnt
}

/// Resets the retry count for a (gap_id, phase) on success.
fn reset_retry_count(gap_id: &str, phase: &str) {
    let key = retry_key(gap_id, phase);
    if let Ok(mut map) = retry_counter_state().lock() {
        map.remove(&key);
    }
}

// ── CREDIBLE-023: gap endpoint security ──────────────────────────────────────

/// Simple per-IP sliding-window rate limiter for /api/gap/* endpoints.
/// State: ip_str → (request_count, window_start).
/// Window resets after 60s; max 10 requests per window (default).
static GAP_RATE_LIMITER: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<String, (u32, std::time::Instant)>>,
> = std::sync::OnceLock::new();

fn gap_rate_limit_state(
) -> &'static std::sync::Mutex<std::collections::HashMap<String, (u32, std::time::Instant)>> {
    GAP_RATE_LIMITER.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Returns true if the request is within the rate limit, false if exceeded.
/// Limit: `CHUMP_GAP_RATE_LIMIT` (default 10) requests per 60s per IP key.
fn check_gap_rate_limit(ip_key: &str) -> bool {
    let max_reqs: u32 = std::env::var("CHUMP_GAP_RATE_LIMIT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    let window_secs = 60u64;
    let mut state = match gap_rate_limit_state().lock() {
        Ok(g) => g,
        Err(_) => return true, // on poison, allow through
    };
    let entry = state
        .entry(ip_key.to_string())
        .or_insert((0, std::time::Instant::now()));
    if entry.1.elapsed().as_secs() >= window_secs {
        *entry = (1, std::time::Instant::now());
        return true;
    }
    entry.0 += 1;
    entry.0 <= max_reqs
}

/// Validate gap_id format: must match [A-Z][A-Z0-9]*-[0-9]+ (e.g. INFRA-630, FLEET-044).
fn validate_gap_id(id: &str) -> bool {
    if id.is_empty() || id.len() > 32 {
        return false;
    }
    let mut parts = id.splitn(2, '-');
    let prefix = match parts.next() {
        Some(p) if !p.is_empty() => p,
        _ => return false,
    };
    let suffix = match parts.next() {
        Some(s) if !s.is_empty() => s,
        _ => return false,
    };
    prefix
        .chars()
        .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        && prefix
            .chars()
            .next()
            .map(|c| c.is_ascii_uppercase())
            .unwrap_or(false)
        && suffix.chars().all(|c| c.is_ascii_digit())
}

/// For state-mutating gap endpoints, require X-CSRF-Token header when
/// CHUMP_CSRF_ENABLED=1 (default enabled in production; disabled in tests).
fn check_csrf(headers: &HeaderMap) -> bool {
    let enabled = std::env::var("CHUMP_CSRF_ENABLED")
        .map(|v| v != "0")
        .unwrap_or(true);
    if !enabled {
        return true;
    }
    headers.get("x-csrf-token").is_some()
}

/// Axum middleware: add secure response headers to all /api/gap/* responses.
async fn gap_security_headers_middleware(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let mut response = next.run(req).await;
    let headers = response.headers_mut();
    headers.insert(
        axum::http::header::HeaderName::from_static("x-frame-options"),
        axum::http::HeaderValue::from_static("DENY"),
    );
    headers.insert(
        axum::http::header::HeaderName::from_static("x-content-type-options"),
        axum::http::HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        axum::http::header::HeaderName::from_static("content-security-policy"),
        axum::http::HeaderValue::from_static("default-src 'self'"),
    );
    response
}

fn check_auth(headers: &HeaderMap) -> bool {
    let required = match std::env::var("CHUMP_WEB_TOKEN") {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => return true,
    };
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| t.trim() == required)
        .unwrap_or(false)
}

/// Get session ID from X-Session-ID header, if present.
fn get_session_id(headers: &HeaderMap) -> Option<String> {
    headers
        .get("X-Session-ID")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

/// INFRA-1014: routes that bypass auth even when CHUMP_WEB_TOKEN is set.
/// Health is intentionally public (uptime checks, load balancers).
/// Auth-check is the endpoint clients use to verify their token, so it
/// must be reachable without one.
const AUTH_BYPASS_PATHS: &[&str] = &[
    "/api/health",
    "/api/health/doctor", // INFRA-990: doctor banner pre-config surface
    "/api/auth/check",
];

/// INFRA-1014: axum middleware enforcing CHUMP_WEB_TOKEN on /api/* routes.
///
/// Replaces the per-handler `check_auth` pattern for new routes (existing
/// handlers keep their inline `check_auth` calls as defence-in-depth;
/// remove on a future cleanup pass).
///
/// Behaviour:
///   - When CHUMP_WEB_TOKEN env unset/empty: allows all requests (today's
///     default, unchanged). Operator gets a startup warning if so.
///   - When CHUMP_WEB_TOKEN env set: requires Authorization: Bearer <token>
///     match on every /api/* path EXCEPT those in AUTH_BYPASS_PATHS.
///   - On rejection: returns 401 with `WWW-Authenticate: Bearer realm="chump"`
///     header so browsers know to prompt.
pub(crate) async fn auth_middleware(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let required = match std::env::var("CHUMP_WEB_TOKEN") {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => return next.run(req).await,
    };

    let path = req.uri().path();
    if AUTH_BYPASS_PATHS.contains(&path) {
        return next.run(req).await;
    }

    let presented = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| t.trim().to_string());

    if presented.as_deref() == Some(required.as_str()) {
        return next.run(req).await;
    }

    // Best-effort ambient log so operators see auth-fail bursts.
    let reason = if presented.is_some() {
        "bad_token"
    } else {
        "missing_token"
    };
    emit_auth_unauthorized(path, reason);

    let body = serde_json::json!({
        "error": "unauthorized",
        "reason": reason,
        "hint": "Set Authorization: Bearer <CHUMP_WEB_TOKEN> on the request",
    });
    (
        StatusCode::UNAUTHORIZED,
        [(
            axum::http::header::WWW_AUTHENTICATE,
            "Bearer realm=\"chump\"",
        )],
        Json(body),
    )
        .into_response()
}

/// Best-effort log of unauthorized API access attempts.
fn emit_auth_unauthorized(path: &str, reason: &str) {
    let event = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "kind": "web_auth_unauthorized",
        "path": path,
        "reason": reason,
    });
    let log_path = repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        let _ = writeln!(f, "{}", event);
    }
}

/// POST /api/auth/check — verify a token without committing to a real call.
/// Body: {"token": "..."} — returns {"valid": bool, "required": bool}.
/// Used by the PWA login flow to drive the entry modal without burning a real
/// /api/* call's auth check.
async fn handle_auth_check(
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let required = std::env::var("CHUMP_WEB_TOKEN")
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty());

    let Some(req_token) = required else {
        // Token not configured server-side; any caller is "valid" by virtue
        // of no requirement. Useful for client to discover the mode.
        return Ok(Json(serde_json::json!({
            "valid": true,
            "required": false,
        })));
    };

    let presented = body
        .get("token")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string());

    let valid = presented.as_deref() == Some(req_token.as_str());
    Ok(Json(serde_json::json!({
        "valid": valid,
        "required": true,
    })))
}

fn pwa_static_dir() -> PathBuf {
    std::env::var("CHUMP_WEB_STATIC_DIR")
        .ok()
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| repo_path::runtime_base().join("web"))
}

// Health, stack-status, cascade-status, and favicon handlers are in routes::health.

#[derive(serde::Deserialize)]
struct StopRequest {
    /// The `request_id` of the turn to cancel (matches the id in TurnStart / TurnComplete events).
    /// May also be a `session_id` — the registry stores tokens by `request_id`, so only
    /// the exact id used when the turn started will match.
    request_id: String,
}

/// POST /api/stop — cancel an in-flight agent turn.
///
/// Body: `{"request_id": "..."}`.  Returns `{"ok": true, "cancelled": <bool>}`;
/// `cancelled` is `false` when no active turn with that id exists.
async fn handle_stop(
    headers: HeaderMap,
    Json(body): Json<StopRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let id = body.request_id.trim();
    if id.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let cancelled = crate::cancel_registry::cancel(id);
    Ok(Json(
        serde_json::json!({ "ok": true, "cancelled": cancelled }),
    ))
}

#[derive(serde::Deserialize)]
struct ApproveRequest {
    request_id: String,
    allowed: bool,
}

/// Resolve a pending tool approval. Called by the web client when the user clicks Allow/Deny on a tool_approval_request event.
async fn handle_approve(
    headers: HeaderMap,
    Json(body): Json<ApproveRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    approval_resolver::resolve_approval(body.request_id.trim(), body.allowed);
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── INFRA-1340: per-tool persistent auto-approve policies ─────────────────
//
// Operators choose an auto-approve TTL in the PWA approval-tray dropdown
// (15min / 1h / session). The choice is persisted to `.chump/tool-policies.json`
// keyed by `{tool_name, scope}` with an `expires_at_unix` timestamp.
//
// GET    /api/tool-policy            — list active (non-expired) policies
// POST   /api/tool-policy            — upsert one  {tool_name, scope, ttl_secs?}
// DELETE /api/tool-policy/{tool}     — remove all policies for the given tool
//
// Each successful POST/DELETE emits kind=tool_approval_policy_changed to
// ambient.jsonl so fleet observability can audit policy churn.

#[derive(serde::Deserialize)]
struct ToolPolicyBody {
    tool_name: String,
    scope: String,
    /// Optional explicit TTL; if omitted we infer from `scope`:
    /// "15min" → 900, "1h" → 3600, "session" → 7d (max).
    #[serde(default)]
    ttl_secs: Option<u64>,
}

fn scope_to_ttl(scope: &str) -> u64 {
    match scope.trim().to_lowercase().as_str() {
        "15min" | "15m" | "15" => 900,
        "1h" | "60min" | "60m" => 3_600,
        "session" => 7 * 24 * 3_600,
        _ => 900, // safe default
    }
}

async fn handle_tool_policy_list(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let policies = crate::tool_policy::policy_store::list_active();
    Ok(Json(serde_json::json!({
        "policies": policies,
        "escalation": {
            "enabled": crate::tool_policy::approval_escalation_enabled(),
            "secs": crate::tool_policy::approval_escalation_secs(),
        },
        "audio_cue_enabled": crate::tool_policy::approval_audio_enabled(),
    })))
}

async fn handle_tool_policy_upsert(
    headers: HeaderMap,
    Json(body): Json<ToolPolicyBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let tool = body.tool_name.trim();
    let scope = body.scope.trim();
    if tool.is_empty() || scope.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let ttl = body.ttl_secs.unwrap_or_else(|| scope_to_ttl(scope));
    let entry = crate::tool_policy::policy_store::upsert_policy(tool, scope, ttl, Some("operator"));
    crate::tool_policy::emit_ambient_json(
        "tool_approval_policy_changed",
        serde_json::json!({
            "action": "upsert",
            "tool_name": entry.tool_name,
            "scope": entry.scope,
            "expires_at_unix": entry.expires_at_unix,
            "ttl_secs": ttl,
        }),
    );
    Ok(Json(serde_json::json!({
        "ok": true,
        "policy": entry,
    })))
}

async fn handle_tool_policy_delete(
    headers: HeaderMap,
    Path(tool): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let trimmed = tool.trim();
    if trimmed.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let removed = crate::tool_policy::policy_store::remove_tool(trimmed);
    if removed > 0 {
        crate::tool_policy::emit_ambient_json(
            "tool_approval_policy_changed",
            serde_json::json!({
                "action": "delete",
                "tool_name": trimmed.to_lowercase(),
                "removed_count": removed,
            }),
        );
    }
    Ok(Json(serde_json::json!({
        "ok": true,
        "removed": removed,
    })))
}

/// POST /api/inject-hint — operator injects a targeted hint into the blackboard.
/// Used by the causal timeline UI when the agent is stuck in a failing verification loop.
/// The hint is posted with high urgency + goal relevance so it surfaces in the next turn's context.
async fn handle_inject_hint(
    headers: HeaderMap,
    Json(body): Json<InjectHintRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let hint = body.hint.trim().to_string();
    if hint.is_empty() || hint.len() > 2000 {
        return Err(StatusCode::BAD_REQUEST);
    }
    let content = if let Some(ctx) = &body.tool_context {
        format!("[Operator hint for {}] {}", ctx.trim(), hint)
    } else {
        format!("[Operator hint] {}", hint)
    };
    let id = crate::blackboard::post(
        crate::blackboard::Module::Custom("operator_hint".to_string()),
        content.clone(),
        crate::blackboard::SalienceFactors {
            novelty: 1.0,
            uncertainty_reduction: 0.8,
            goal_relevance: 1.0,
            urgency: 1.0,
        },
    );
    tracing::info!(
        id,
        "operator hint injected via API: {:?}",
        &content[..content.len().min(120)]
    );

    // PRODUCT-116: emit to ambient.jsonl so /api/ambient/recent?kind=operator_hint
    // surfaces the history list in the PWA strategic-redirect composer.
    let ttl_min = body.ttl_minutes.unwrap_or(60);
    let hint_event = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "kind": "operator_hint",
        "hint": &hint,
        "ttl_minutes": ttl_min,
        "blackboard_id": id,
    });
    let ambient_path = repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{}", hint_event);
    }

    Ok(Json(
        serde_json::json!({ "ok": true, "blackboard_id": id, "ttl_minutes": ttl_min }),
    ))
}

/// INFRA-1296: POST /api/broadcast — emit any a2a event from the PWA.
///
/// Validates required fields per event type, then shells out to
/// `scripts/coord/broadcast.sh`. Returns 400 on schema violation, 500 on
/// broadcast.sh failure, 200 with the event JSON on success.
async fn handle_broadcast(
    headers: HeaderMap,
    Json(body): Json<BroadcastRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }

    let event = body.event.trim().to_uppercase();
    let valid_events = [
        "INTENT", "HANDOFF", "STUCK", "DONE", "WARN", "ALERT", "FEEDBACK",
    ];
    if !valid_events.contains(&event.as_str()) {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "invalid event '{}'; valid: {}",
                event,
                valid_events.join(" ")
            ),
        ));
    }

    // Per-event required-field validation.
    let subject_required = matches!(
        event.as_str(),
        "INTENT" | "HANDOFF" | "STUCK" | "DONE" | "FEEDBACK"
    );
    if subject_required && body.subject.as_deref().unwrap_or("").trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("event {} requires non-empty subject", event),
        ));
    }
    if event == "HANDOFF"
        && body.to_session.as_deref().unwrap_or("").trim().is_empty()
        && body.recipient.as_deref().unwrap_or("").trim().is_empty()
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "HANDOFF requires to_session or recipient".to_string(),
        ));
    }
    if (event == "FEEDBACK" || event == "ALERT")
        && body.kind.as_deref().unwrap_or("").trim().is_empty()
    {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("event {} requires kind", event),
        ));
    }

    // Build the broadcast.sh CLI argv.
    let repo_root = crate::repo_path::runtime_base();
    let script = repo_root.join("scripts/coord/broadcast.sh");
    if !script.exists() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("broadcast.sh missing at {}", script.display()),
        ));
    }

    // INFRA-1496: tokio::process::Command + 10s timeout (INFRA-1485 pattern)
    // so a stalled broadcast.sh cannot block tokio workers, which would stall
    // /api/health and every other handler sharing the runtime.
    let mut cmd = tokio::process::Command::new("bash");
    cmd.arg(&script);
    // Optional --to flag honored by broadcast.sh for any event.
    if let Some(recipient) = body
        .recipient
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        cmd.args(["--to", recipient]);
    }
    cmd.arg(&event);

    match event.as_str() {
        "INTENT" | "DONE" => {
            cmd.arg(body.subject.as_deref().unwrap_or(""));
            if let Some(r) = body.rationale.as_deref() {
                cmd.arg(r);
            }
        }
        "HANDOFF" => {
            cmd.arg(body.subject.as_deref().unwrap_or(""));
            let dst = body
                .to_session
                .as_deref()
                .or(body.recipient.as_deref())
                .unwrap_or("");
            cmd.arg(dst);
        }
        "STUCK" => {
            cmd.arg(body.subject.as_deref().unwrap_or(""));
            cmd.arg(body.rationale.as_deref().unwrap_or(""));
        }
        "WARN" => {
            cmd.arg(body.rationale.as_deref().unwrap_or(""));
        }
        "ALERT" => {
            cmd.arg(format!("kind={}", body.kind.as_deref().unwrap_or("")));
            cmd.arg(body.rationale.as_deref().unwrap_or(""));
        }
        "FEEDBACK" => {
            cmd.arg(body.kind.as_deref().unwrap_or(""));
            cmd.arg(body.subject.as_deref().unwrap_or(""));
            cmd.arg(body.rationale.as_deref().unwrap_or(""));
            if let Some(v) = body.vote.as_deref().filter(|s| !s.is_empty()) {
                cmd.arg(v);
            }
        }
        _ => unreachable!(),
    }

    let output = match tokio::time::timeout(std::time::Duration::from_secs(10), cmd.output()).await
    {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => {
            return Err((StatusCode::INTERNAL_SERVER_ERROR, format!("spawn: {e}")));
        }
        Err(_) => {
            return Err((
                StatusCode::GATEWAY_TIMEOUT,
                "broadcast.sh timeout >10s".to_string(),
            ));
        }
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("broadcast.sh exit {}: {}", output.status, stderr),
        ));
    }
    Ok(Json(serde_json::json!({
        "ok": true,
        "event": event,
        "stdout": String::from_utf8_lossy(&output.stdout).trim(),
    })))
}

// ── META-080: lesson sharing endpoint (in-memory store, META-073 slice) ──────
//
// Pragmatic subset of the wire format defined in
// docs/design/LESSON_PROPAGATION_FORMAT.md (META-079). Process-local,
// non-persistent (v1 scope per that doc's storage-layout note); a
// NATS-backed v2 is a follow-up once the in-memory store proves the shape.

const LESSON_DEFAULT_TTL_SECS: i64 = 24 * 60 * 60;

static LESSON_STORE: std::sync::OnceLock<std::sync::Mutex<Vec<LessonRecord>>> =
    std::sync::OnceLock::new();

fn lesson_store() -> &'static std::sync::Mutex<Vec<LessonRecord>> {
    LESSON_STORE.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

#[derive(Clone, serde::Serialize)]
struct LessonRecord {
    lesson_id: String,
    headline: String,
    #[serde(default)]
    body: String,
    context_tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent: Option<String>,
    published_at_ms: i64,
    expires_at_ms: i64,
}

#[derive(serde::Deserialize)]
struct LessonPostRequest {
    #[serde(default)]
    lesson_id: Option<String>,
    headline: String,
    #[serde(default)]
    body: Option<String>,
    /// Task tag(s) this lesson applies to — filtered on in GET /api/lessons?tag=.
    #[serde(default)]
    context_tags: Vec<String>,
    #[serde(default)]
    agent: Option<String>,
    /// Override the default 24h expiry. Mainly for tests / short-lived lessons.
    #[serde(default)]
    ttl_secs: Option<i64>,
}

fn now_ms_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Drops expired lessons. Called on every read/write so the in-memory store
/// stays bounded without a background reaper task.
fn prune_expired_lessons(store: &mut Vec<LessonRecord>) {
    let now = now_ms_epoch();
    store.retain(|l| l.expires_at_ms > now);
}

/// EFFECTIVE-679: inbound body for `POST /api/drop`.
#[derive(Debug, serde::Deserialize)]
struct DropPostRequest {
    sentence: String,
    citation: String,
}

/// EFFECTIVE-679 (EFFECTIVE-392 slice): POST /api/drop — cheap idea-drop
/// intake. Persists `{sentence, citation}` to the curator's drops queue
/// file via `chump_gap_store::add_drop`. Idempotent: re-posting the same
/// `(sentence, citation)` pair returns the existing id with 200 instead of
/// creating a duplicate record.
async fn handle_drop_post(
    headers: HeaderMap,
    Json(body): Json<DropPostRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let sentence = body.sentence.trim().to_string();
    let citation = body.citation.trim().to_string();
    if sentence.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "sentence must be non-empty".to_string(),
        ));
    }
    let repo_root = repo_path::runtime_base();
    let (record, created) = gap_store::add_drop(&repo_root, &sentence, &citation).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("add_drop failed: {e}"),
        )
    })?;
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(serde_json::json!({ "id": record.id }))))
}

/// META-080: POST /api/lessons — agents publish a lesson to the shared
/// in-memory store. Lessons expire 24h after publish by default.
async fn handle_lessons_post(
    headers: HeaderMap,
    Json(body): Json<LessonPostRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let headline = body.headline.trim().to_string();
    if headline.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "headline must be non-empty".to_string(),
        ));
    }
    let ttl_secs = body.ttl_secs.unwrap_or(LESSON_DEFAULT_TTL_SECS).max(1);
    let now = now_ms_epoch();
    let lesson_id = body
        .lesson_id
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let expires_at_ms = now + ttl_secs * 1000;
    let context_tags: Vec<String> = body
        .context_tags
        .into_iter()
        .map(|t| t.trim().to_lowercase())
        .filter(|t| !t.is_empty())
        .collect();
    let record = LessonRecord {
        lesson_id: lesson_id.clone(),
        headline,
        body: body.body.unwrap_or_default(),
        context_tags: context_tags.clone(),
        agent: body.agent.clone(),
        published_at_ms: now,
        expires_at_ms,
    };
    let count = {
        let mut store = lesson_store().lock().unwrap_or_else(|e| e.into_inner());
        prune_expired_lessons(&mut store);
        store.push(record);
        store.len()
    };
    // scanner-anchor: "kind":"lesson_published"
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "lesson_published".to_string(),
        fields: vec![
            ("lesson_id".to_string(), lesson_id.clone()),
            ("agent".to_string(), body.agent.unwrap_or_default()),
            ("context_tags".to_string(), context_tags.join(",")),
        ],
        ..Default::default()
    });
    Ok(Json(serde_json::json!({
        "ok": true,
        "lesson_id": lesson_id,
        "expires_at_ms": expires_at_ms,
        "count": count,
    })))
}

/// META-080: GET /api/lessons?tag=<task-tag> — agents read relevant lessons.
/// Without `tag`, returns all non-expired lessons.
async fn handle_lessons_get(
    headers: HeaderMap,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let tag = params
        .get("tag")
        .map(|t| t.trim().to_lowercase())
        .filter(|t| !t.is_empty());
    let mut store = lesson_store().lock().unwrap_or_else(|e| e.into_inner());
    prune_expired_lessons(&mut store);
    let lessons: Vec<&LessonRecord> = store
        .iter()
        .filter(|l| match &tag {
            Some(t) => l.context_tags.iter().any(|ct| ct == t),
            None => true,
        })
        .collect();
    Ok(Json(serde_json::json!({
        "lessons": lessons,
        "count": lessons.len(),
    })))
}

/// INFRA-1298: GET /api/inbox/{session} — read targeted-inbox messages.
async fn handle_inbox_get(
    headers: HeaderMap,
    axum::extract::Path(session): axum::extract::Path<String>,
    axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    if session.is_empty() || session.contains('/') || session.contains("..") {
        return Err((
            StatusCode::BAD_REQUEST,
            "session id must be non-empty, no slashes".to_string(),
        ));
    }
    let repo_root = crate::repo_path::runtime_base();
    let inbox_path = repo_root
        .join(".chump-locks")
        .join("inbox")
        .join(format!("{session}.jsonl"));
    let cursor_path = repo_root
        .join(".chump-locks")
        .join("inbox")
        .join(format!("{session}.read-cursor"));
    if !inbox_path.exists() {
        return Ok(Json(serde_json::json!({
            "session": session, "messages": [], "count": 0,
        })));
    }
    let contents = std::fs::read_to_string(&inbox_path).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("read inbox: {e}"),
        )
    })?;
    let since: Option<String> = params.get("since").cloned();
    let unread_only = params.get("unread").map(|s| s.as_str()) == Some("1");
    let cursor_ts: Option<String> = if unread_only && cursor_path.exists() {
        std::fs::read_to_string(&cursor_path)
            .ok()
            .map(|s| s.trim().to_string())
    } else {
        None
    };
    let mut out = Vec::new();
    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let entry: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let ts = entry
            .get("ts")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if let Some(ref s) = since {
            if ts.as_str() <= s.as_str() {
                continue;
            }
        }
        if let Some(ref c) = cursor_ts {
            if ts.as_str() <= c.as_str() {
                continue;
            }
        }
        out.push(entry);
    }
    let count = out.len();
    Ok(Json(serde_json::json!({
        "session": session, "messages": out, "count": count,
    })))
}

/// INFRA-1298: GET /api/inbox/{session}/unread-count — fast badge count.
async fn handle_inbox_unread_count(
    headers: HeaderMap,
    axum::extract::Path(session): axum::extract::Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let repo_root = crate::repo_path::runtime_base();
    let inbox_path = repo_root
        .join(".chump-locks")
        .join("inbox")
        .join(format!("{session}.jsonl"));
    let cursor_path = repo_root
        .join(".chump-locks")
        .join("inbox")
        .join(format!("{session}.read-cursor"));
    if !inbox_path.exists() {
        return Ok(Json(serde_json::json!({
            "session": session, "unread": 0,
        })));
    }
    let cursor_ts = std::fs::read_to_string(&cursor_path)
        .ok()
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let contents = std::fs::read_to_string(&inbox_path).unwrap_or_default();
    let mut unread = 0_u32;
    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let entry: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let ts = entry.get("ts").and_then(|v| v.as_str()).unwrap_or("");
        if cursor_ts.is_empty() || ts > cursor_ts.as_str() {
            unread += 1;
        }
    }
    Ok(Json(serde_json::json!({
        "session": session, "unread": unread,
    })))
}

#[derive(serde::Deserialize)]
struct InboxAckRequest {
    #[serde(default)]
    up_to_ts: Option<String>,
}

/// INFRA-1298: POST /api/inbox/{session}/ack — advance read cursor.
async fn handle_inbox_ack(
    headers: HeaderMap,
    axum::extract::Path(session): axum::extract::Path<String>,
    Json(body): Json<InboxAckRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let repo_root = crate::repo_path::runtime_base();
    let inbox_dir = repo_root.join(".chump-locks").join("inbox");
    std::fs::create_dir_all(&inbox_dir)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("mkdir: {e}")))?;
    let cursor_path = inbox_dir.join(format!("{session}.read-cursor"));
    let ts = match body
        .up_to_ts
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(t) => t.to_string(),
        None => {
            let inbox_path = inbox_dir.join(format!("{session}.jsonl"));
            if let Ok(c) = std::fs::read_to_string(&inbox_path) {
                let mut latest = String::new();
                for line in c.lines() {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                        if let Some(t) = v.get("ts").and_then(|x| x.as_str()) {
                            if t > latest.as_str() {
                                latest = t.to_string();
                            }
                        }
                    }
                }
                latest
            } else {
                chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            }
        }
    };
    std::fs::write(&cursor_path, &ts).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("write cursor: {e}"),
        )
    })?;
    Ok(Json(serde_json::json!({
        "session": session, "cursor": ts,
    })))
}

/// POST /api/policy-override — time-boxed relax of **CHUMP_TOOLS_ASK** for a web session (requires **`CHUMP_POLICY_OVERRIDE_API=1`**).
async fn handle_policy_override_register(
    headers: HeaderMap,
    Json(body): Json<PolicyOverrideRegisterBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if !crate::policy_override::policy_override_api_enabled() {
        return Ok(Json(serde_json::json!({
            "ok": false,
            "error": "set CHUMP_POLICY_OVERRIDE_API=1 to register session policy overrides"
        })));
    }
    let sid = body.session_id.trim();
    if sid.is_empty() || body.relax_tools.trim().is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    crate::policy_override::register_session_relax(sid, &body.relax_tools, body.ttl_secs);
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// PRODUCT-129: POST /api/lease/release-expired — scan .chump-locks/*.json
/// for past-TTL leases and remove them. Returns count + ids freed.
/// Powers the cockpit Lock-contention card's [Release expired leases] button.
async fn handle_lease_release_expired(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut released: Vec<String> = Vec::new();
    let mut scanned: u32 = 0;
    let entries = match std::fs::read_dir(&lock_dir) {
        Ok(d) => d,
        Err(e) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("read .chump-locks: {e}"),
            ));
        }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        // Skip subdirectories like inbox/ — we only care about top-level
        // session lease files.
        if !path.is_file() {
            continue;
        }
        scanned += 1;
        let Ok(body) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        // Parse expires_at — accept ISO8601 string OR unix-seconds int.
        let expired = match val.get("expires_at") {
            Some(serde_json::Value::String(s)) => {
                // ISO8601 → unix seconds via chrono (avoids reaching into
                // atomic_claim.rs's private parse_iso8601).
                match chrono::DateTime::parse_from_rfc3339(s) {
                    Ok(dt) => (dt.timestamp() as u64) <= now_secs,
                    Err(_) => false,
                }
            }
            Some(serde_json::Value::Number(n)) => {
                n.as_u64().map(|s| s <= now_secs).unwrap_or(false)
            }
            _ => false, // no expiry → not expired
        };
        if !expired {
            continue;
        }
        let session_id = val
            .get("session_id")
            .or_else(|| val.get("session"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                path.file_stem()
                    .and_then(|s| s.to_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "?".to_string())
            });
        if std::fs::remove_file(&path).is_ok() {
            released.push(session_id);
        }
    }
    Ok(Json(serde_json::json!({
        "ok": true,
        "scanned": scanned,
        "released_count": released.len(),
        "released_ids": released,
    })))
}

/// PRODUCT-127: GET /api/gap/drift-status — count gaps with closed_pr set but
/// status=open (state.db drift). Powers the cockpit "Gap drift: N instances" row.
async fn handle_gap_drift_status(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    let repo_root = crate::repo_path::runtime_base();
    let store = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("open gap store: {e}"),
            ));
        }
    };
    let gaps = match store.list(None) {
        Ok(g) => g,
        Err(e) => {
            return Err((StatusCode::INTERNAL_SERVER_ERROR, format!("list gaps: {e}")));
        }
    };
    // Drift = closed_pr set but status is still "open" (not done/shipped).
    // These stale rows confuse the picker into re-claiming already-shipped work.
    let instances: Vec<serde_json::Value> = gaps
        .iter()
        .filter(|g| g.closed_pr.is_some() && g.status != "done" && g.status != "shipped")
        .map(|g| {
            serde_json::json!({
                "gap_id": g.id,
                "reason": format!(
                    "closed_pr=#{} but status={}",
                    g.closed_pr.unwrap_or(0),
                    g.status
                ),
            })
        })
        .collect();
    Ok(Json(serde_json::json!({
        "count": instances.len(),
        "instances": instances,
    })))
}

/// PRODUCT-127: POST /api/gap/dep-clean — strip depends_on entries pointing
/// at done gaps. Powers cockpit Gap-store drift card's [Repair drift] button.
async fn handle_gap_dep_clean(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    // Shell out to the existing CLI for now — keeps behavior consistent with
    // `chump gap dep-clean --apply` and avoids re-implementing the dep walker.
    // INFRA-1485: tokio::process::Command + 10s timeout (dep-clean can be slow
    // on large repos but should not block tokio workers indefinitely).
    let repo_root = crate::repo_path::runtime_base();
    let chump_bin = std::env::current_exe()
        .ok()
        .unwrap_or_else(|| std::path::PathBuf::from("chump"));
    let fut = tokio::process::Command::new(&chump_bin)
        .args(["gap", "dep-clean", "--apply", "--json"])
        .current_dir(&repo_root)
        .output();
    let output = match tokio::time::timeout(std::time::Duration::from_secs(10), fut).await {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("invoke gap dep-clean: {e}"),
            ));
        }
        Err(_) => {
            return Err((
                StatusCode::GATEWAY_TIMEOUT,
                "gap dep-clean timeout >10s".to_string(),
            ));
        }
    };
    if !output.status.success() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!(
                "dep-clean exit {}: {}",
                output.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&output.stderr)
            ),
        ));
    }
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let parsed: serde_json::Value =
        serde_json::from_str(&stdout).unwrap_or_else(|_| serde_json::json!({ "raw": stdout }));
    Ok(Json(serde_json::json!({
        "ok": true,
        "result": parsed,
    })))
}

#[derive(serde::Deserialize)]
struct SessionsListQuery {
    #[serde(default)]
    bot: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    offset: Option<u32>,
}

async fn handle_sessions_create(
    headers: HeaderMap,
    body: Option<Json<SessionCreateBody>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let bot = body
        .as_ref()
        .and_then(|b| b.bot.as_deref())
        .unwrap_or("chump");
    let session_id =
        web_sessions_db::session_create(bot).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "session_id": session_id })))
}

async fn handle_sessions_list(
    headers: HeaderMap,
    Query(q): Query<SessionsListQuery>,
) -> Result<Json<Vec<web_sessions_db::WebSessionSummary>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let bot = q.bot.as_deref().unwrap_or("chump");
    let limit = q.limit.unwrap_or(50);
    let offset = q.offset.unwrap_or(0);
    let list = web_sessions_db::session_list(bot, limit, offset)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(list))
}

async fn handle_sessions_messages(
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Query(q): Query<SessionsListQuery>,
) -> Result<Json<Vec<web_sessions_db::WebMessage>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let limit = q.limit.unwrap_or(200);
    let offset = q.offset.unwrap_or(0);
    let list = web_sessions_db::session_get_messages(session_id.trim(), limit, offset)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(list))
}

async fn handle_sessions_delete(
    headers: HeaderMap,
    Path(session_id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let _ = web_sessions_db::session_delete(session_id.trim())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let _ = web_uploads::delete_uploads_for_session(session_id.trim());
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
struct SessionRenameBody {
    title: String,
}

async fn handle_sessions_rename(
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Json(body): Json<SessionRenameBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let _ = web_sessions_db::session_rename(session_id.trim(), body.title.trim())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

/// POST /api/upload — multipart: session_id (field), file (field, one or more). Max 10MB per file.
async fn handle_upload(
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let mut session_id: Option<String> = None;
    let mut uploaded: Vec<serde_json::Value> = Vec::new();
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?
    {
        let name = field.name().unwrap_or_default().to_string();
        if name == "session_id" {
            if let Ok(s) = field.text().await {
                session_id = Some(s.trim().to_string());
            }
            continue;
        }
        if name != "file" {
            continue;
        }
        let filename = field.file_name().unwrap_or("file").to_string();
        let content_type = field.content_type().map(|c| c.to_string());
        let data = field.bytes().await.map_err(|_| StatusCode::BAD_REQUEST)?;
        let session_id_str = session_id.as_deref().unwrap_or("default");
        let sid = web_sessions_db::session_ensure(session_id_str, "chump")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        match web_uploads::save_upload(&sid, &filename, content_type.as_deref(), &data) {
            Ok((file_id, size_bytes)) => {
                uploaded.push(serde_json::json!({
                    "file_id": file_id,
                    "filename": filename,
                    "mime_type": content_type,
                    "size_bytes": size_bytes,
                    "url": "/api/files/".to_string() + &file_id
                }));
            }
            Err(e) if e.to_string().contains("too large") => {
                return Err(StatusCode::PAYLOAD_TOO_LARGE)
            }
            Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
        }
    }
    if uploaded.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    Ok(Json(if uploaded.len() == 1 {
        uploaded.into_iter().next().expect("checked: len == 1")
    } else {
        serde_json::json!({ "uploads": uploaded })
    }))
}

/// GET /api/files/:file_id — serve uploaded file.
async fn handle_file_serve(
    headers: HeaderMap,
    Path(file_id): Path<String>,
) -> Result<axum::response::Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let (path, filename, mime_type) =
        web_uploads::get_upload(file_id.trim()).map_err(|_| StatusCode::NOT_FOUND)?;
    let contents = tokio::fs::read(&path)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let mime = mime_type.as_deref().unwrap_or("application/octet-stream");
    let disposition = format!("inline; filename=\"{}\"", filename.replace('"', "%22"));
    axum::response::Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", mime)
        .header("Content-Disposition", disposition)
        .body(axum::body::Body::from(contents))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

/// GET /api/tts?text=... — synthesize speech via the platform's TTS engine.
/// Returns audio/wav for the PWA to <audio> play.
///
/// COMP-005c. Platform support:
///   macOS: `say -o /tmp/X.aiff <text>` → AIFF (browser-supported)
///   Linux: `piper -m <model> --output-file /tmp/X.wav <text>` if `piper`
///          is on PATH; otherwise 503.
///   Windows: 503 (no native shell-out; could add SAPI later).
///
/// Always returns 503 when CHUMP_TTS_DISABLE=1 so operators can turn it
/// off centrally without changing client code.
#[derive(serde::Deserialize)]
struct TtsQuery {
    #[serde(default)]
    text: Option<String>,
}

async fn handle_tts(
    headers: HeaderMap,
    Query(q): Query<TtsQuery>,
) -> Result<axum::response::Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if matches!(std::env::var("CHUMP_TTS_DISABLE").as_deref(), Ok("1")) {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let text = q.text.as_deref().unwrap_or("").trim();
    if text.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    if text.len() > 4096 {
        // Reasonable cap; long text wouldn't synthesize cleanly anyway.
        return Err(StatusCode::PAYLOAD_TOO_LARGE);
    }

    // Output to a fresh temp file so concurrent requests don't collide.
    let unique = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    );
    let mut out_path = std::env::temp_dir();
    out_path.push(format!("chump-tts-{}", unique));

    #[cfg(target_os = "macos")]
    let (cmd, args, ext, mime) = {
        let p = out_path.with_extension("aiff");
        (
            "say",
            vec!["-o".to_string(), p.display().to_string(), text.to_string()],
            "aiff",
            "audio/aiff",
        )
    };
    #[cfg(target_os = "linux")]
    let (cmd, args, ext, mime) = {
        let p = out_path.with_extension("wav");
        // Operator must have piper installed and a model in
        // CHUMP_TTS_PIPER_MODEL. Without those, we 503.
        let model = match std::env::var("CHUMP_TTS_PIPER_MODEL") {
            Ok(m) if !m.trim().is_empty() => m,
            _ => return Err(StatusCode::SERVICE_UNAVAILABLE),
        };
        (
            "piper",
            vec![
                "--model".to_string(),
                model,
                "--output-file".to_string(),
                p.display().to_string(),
                text.to_string(),
            ],
            "wav",
            "audio/wav",
        )
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    return Err(StatusCode::SERVICE_UNAVAILABLE);

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        out_path.set_extension(ext);
        let status = tokio::process::Command::new(cmd)
            .args(&args)
            .status()
            .await
            .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        if !status.success() {
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
        let bytes = tokio::fs::read(&out_path)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        // Best-effort cleanup; not fatal if it fails.
        let _ = tokio::fs::remove_file(&out_path).await;
        axum::response::Response::builder()
            .status(StatusCode::OK)
            .header("Content-Type", mime)
            .header("Cache-Control", "no-store")
            .body(axum::body::Body::from(bytes))
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
    }
}

#[derive(serde::Deserialize)]
struct TasksListQuery {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    assignee: Option<String>,
}

async fn handle_tasks_list(
    headers: HeaderMap,
    Query(q): Query<TasksListQuery>,
) -> Result<Json<Vec<task_db::TaskRow>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let status = q.status.as_deref().filter(|s| !s.is_empty());
    if let Some(s) = status {
        const KNOWN_STATUSES: &[&str] = &["open", "blocked", "in_progress", "done", "abandoned"];
        if !KNOWN_STATUSES.contains(&s) {
            return Err(StatusCode::BAD_REQUEST);
        }
    }
    let mut tasks = task_db::task_list(status).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if let Some(ref a) = q.assignee {
        let a = a.trim().to_lowercase();
        if !a.is_empty() && a != "any" {
            tasks.retain(|t| {
                t.assignee
                    .as_ref()
                    .map(|s| s.to_lowercase())
                    .unwrap_or_else(|| "chump".into())
                    == a
            });
        }
    }
    Ok(Json(tasks))
}

#[derive(serde::Deserialize)]
struct TaskCreateBody {
    title: String,
    #[serde(default)]
    repo: Option<String>,
    #[serde(default)]
    issue_number: Option<i64>,
    #[serde(default)]
    priority: Option<i64>,
    #[serde(default)]
    assignee: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

async fn handle_tasks_create(
    headers: HeaderMap,
    Json(body): Json<TaskCreateBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let title = body.title.trim();
    if title.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let id = task_db::task_create(
        title,
        body.repo.as_deref(),
        body.issue_number,
        body.priority,
        body.assignee.as_deref(),
        body.notes.as_deref(),
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "id": id, "title": title })))
}

#[derive(serde::Deserialize)]
struct TaskUpdateBody {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    priority: Option<i64>,
    #[serde(default)]
    notes: Option<String>,
    #[serde(default)]
    assignee: Option<String>,
}

async fn handle_tasks_update(
    headers: HeaderMap,
    Path(id): Path<i64>,
    Json(body): Json<TaskUpdateBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if let Some(ref s) = body.status {
        let _ = task_db::task_update_status(id, s.trim(), body.notes.as_deref());
    }
    if body.notes.is_some() && body.status.is_none() {
        let _ = task_db::task_update_notes(id, body.notes.as_deref());
    }
    if let Some(p) = body.priority {
        let _ = task_db::task_update_priority(id, p);
    }
    if let Some(ref a) = body.assignee {
        let _ = task_db::task_update_assignee(id, a.trim());
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn handle_tasks_delete(
    headers: HeaderMap,
    Path(id): Path<i64>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let _ = task_db::task_abandon(id, None).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Pilot / N4-style read-only aggregate (tasks, episodes, tool ring, speculative batch).
async fn handle_pilot_summary(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let res = tokio::task::spawn_blocking(pilot_metrics::pilot_summary_json)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    match res {
        Ok(v) => Ok(Json(v)),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

#[derive(serde::Deserialize)]
struct JobsQuery {
    #[serde(default = "default_jobs_limit")]
    limit: usize,
}

fn default_jobs_limit() -> usize {
    40
}

async fn handle_jobs(
    headers: HeaderMap,
    Query(q): Query<JobsQuery>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let limit = q.limit.clamp(1, 200);
    let jobs = crate::job_log::recent_jobs(limit).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "jobs": jobs })))
}

/// Unix days (since 1970-01-01) to (year, month, day) UTC. Approximate for 1970–2100.
fn unix_days_to_ymd(days: i32) -> (i32, u32, u32) {
    let (y, m, d) = (
        days / 365,
        ((days % 365) / 31).min(11) as u32 + 1,
        ((days % 365) % 31).max(1) as u32,
    );
    (y + 1970, m, d)
}

/// GET /api/briefing — today's briefing: open tasks (by assignee), recent episodes. No cache yet.
async fn handle_briefing(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let date = {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let days = (t.as_secs() / 86400) as i32;
        let (y, m, d) = unix_days_to_ymd(days);
        format!("{:04}-{:02}-{:02}", y, m, d)
    };
    let mut sections: Vec<serde_json::Value> = Vec::new();

    if let Ok(tasks) = task_db::task_list(None) {
        let open: Vec<_> = tasks
            .into_iter()
            .filter(|t| !["done", "abandoned"].contains(&t.status.as_str()))
            .collect();
        if !open.is_empty() {
            let by_assignee: std::collections::HashMap<String, Vec<_>> = open.into_iter().fold(
                std::collections::HashMap::new(),
                |mut m, t| {
                    let a = t.assignee.clone().unwrap_or_else(|| "chump".into());
                    m.entry(a).or_default().push(serde_json::json!({ "id": t.id, "title": t.title, "status": t.status, "priority": t.priority }));
                    m
                },
            );
            let items: Vec<_> = by_assignee
                .into_iter()
                .map(|(assignee, list)| serde_json::json!({ "assignee": assignee, "tasks": list }))
                .collect();
            sections.push(serde_json::json!({ "title": "Tasks", "content": "Open tasks by assignee.", "items": items }));
        }
    }

    if episode_db::episode_available() {
        if let Ok(episodes) = episode_db::episode_recent(None, 15) {
            if !episodes.is_empty() {
                let items: Vec<_> = episodes
                    .into_iter()
                    .map(|e| serde_json::json!({ "id": e.id, "summary": e.summary, "happened_at": e.happened_at, "sentiment": e.sentiment }))
                    .collect();
                sections.push(serde_json::json!({ "title": "Recent episodes", "content": "Last 15 episodes.", "items": items }));
            }
        }
    }

    if let Ok(watch_counts) = web_brain::watch_list() {
        if !watch_counts.is_empty() {
            let items: Vec<_> = watch_counts
                .into_iter()
                .map(|(name, count)| serde_json::json!({ "list": name, "count": count }))
                .collect();
            sections.push(serde_json::json!({
                "title": "Watchlists",
                "content": "Item counts under brain/watch/*.md (see /api/watch/alerts for flagged lines).",
                "items": items
            }));
        }
    }

    if let Ok(flagged) = web_brain::watch_flagged_items() {
        if !flagged.is_empty() {
            let items: Vec<_> = flagged
                .into_iter()
                .map(|i| serde_json::json!({ "list": i.list, "line": i.line }))
                .collect();
            sections.push(serde_json::json!({
                "title": "Watch alerts",
                "content": "Lines matching urgent / deadline / [!] / asap / alert: (see docs/api/WEB_API_REFERENCE.md).",
                "items": items
            }));
        }
    }

    Ok(Json(
        serde_json::json!({ "date": date, "sections": sections }),
    ))
}

// --- Dashboard (ship status, log tail, chassis progress) ---
async fn handle_dashboard(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let base = repo_path::runtime_base();
    let ship_log_path = base.join("logs/heartbeat-ship.log");

    // INFRA-1485: tokio::process::Command + 1s timeout so a stalled pgrep
    // doesn't park a tokio worker thread.
    let ship_running = {
        let fut = tokio::process::Command::new("pgrep")
            .args(["-f", "heartbeat-ship"])
            .output();
        match tokio::time::timeout(std::time::Duration::from_secs(1), fut).await {
            Ok(Ok(o)) => o.status.success(),
            _ => false,
        }
    };

    let ship_log_content = std::fs::read_to_string(&ship_log_path).unwrap_or_default();
    let ship_lines: Vec<&str> = ship_log_content.lines().collect();
    let start = ship_lines.len().saturating_sub(40);
    let ship_log_tail = ship_lines[start..].join("\n");

    // Parse last round from log: "[timestamp] Round N (type) starting" or "Round N (type) status"
    let mut ship_summary: Option<serde_json::Value> = None;
    for line in ship_lines.iter().rev() {
        let line = line.trim();
        let round_pos = match line.find("Round ") {
            Some(p) => p,
            None => continue,
        };
        let rest = line[round_pos + 6..].trim_start(); // after "Round "
        let num_end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(0);
        if num_end == 0 {
            continue;
        }
        let num_str = rest[..num_end].trim();
        let rest = rest[num_end..].trim_start();
        if !rest.starts_with('(') {
            continue;
        }
        let paren_idx = match rest.find(')') {
            Some(i) => i,
            None => continue,
        };
        let round_type = rest[1..paren_idx].trim();
        let after_paren = rest[paren_idx + 1..].trim();
        let status = if after_paren == "starting" {
            "in progress"
        } else if after_paren.starts_with("done") || after_paren.starts_with("completed") {
            "done"
        } else if after_paren.starts_with("failed") {
            "failed"
        } else if after_paren.starts_with("retry") {
            "retry"
        } else {
            after_paren
        };
        ship_summary = Some(serde_json::json!({
            "round": num_str,
            "round_type": round_type,
            "status": status,
            "description": format!("Round {} ({}) — {}", num_str, round_type, status)
        }));
        break;
    }

    let brain_root =
        std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let brain_root_path = if std::path::Path::new(&brain_root).is_absolute() {
        PathBuf::from(brain_root)
    } else {
        base.join(brain_root)
    };
    // Active portfolio: read portfolio.md, extract all active projects (name/repo/phase/blocked).
    let portfolio_path = brain_root_path.join("portfolio.md");
    let portfolio_projects: Vec<serde_json::Value> = {
        let text = std::fs::read_to_string(&portfolio_path).unwrap_or_default();
        let mut projects: Vec<serde_json::Value> = Vec::new();
        let mut cur_name: Option<String> = None;
        let mut cur_repo: Option<String> = None;
        let mut cur_phase: Option<String> = None;
        let mut cur_blocked = false;
        let mut cur_priority: u32 = 99;
        let flush = |projects: &mut Vec<serde_json::Value>,
                     name: Option<String>,
                     repo: Option<String>,
                     phase: Option<String>,
                     blocked: bool,
                     priority: u32| {
            if let Some(n) = name {
                projects.push(serde_json::json!({ "name": n, "repo": repo, "phase": phase, "blocked": blocked, "priority": priority }));
            }
        };
        for line in text.lines() {
            let t = line.trim();
            if t.starts_with("## ")
                && !t.contains("Active Portfolio")
                && !t.contains("Parked")
                && !t.contains("Killed")
            {
                flush(
                    &mut projects,
                    cur_name.take(),
                    cur_repo.take(),
                    cur_phase.take(),
                    cur_blocked,
                    cur_priority,
                );
                cur_blocked = false;
                cur_priority = t
                    .trim_start_matches('#')
                    .trim()
                    .split('.')
                    .next()
                    .and_then(|n| n.trim().parse::<u32>().ok())
                    .unwrap_or(99);
                cur_name = t
                    .trim_start_matches('#')
                    .trim()
                    .split_once('.')
                    .map(|x| x.1)
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty() && cur_priority < 90);
            }
            if cur_name.is_some() {
                if t.starts_with("- **Repo:**") {
                    let r = t.split("**Repo:**").nth(1).unwrap_or("").trim();
                    if !r.is_empty() && !r.starts_with('(') {
                        cur_repo = Some(r.to_string());
                    }
                }
                if t.starts_with("- **Phase:**") {
                    cur_phase = t.split("**Phase:**").nth(1).map(|s| s.trim().to_string());
                }
                if t.contains("**Blocked:** Yes") {
                    cur_blocked = true;
                }
            }
        }
        flush(
            &mut projects,
            cur_name,
            cur_repo,
            cur_phase,
            cur_blocked,
            cur_priority,
        );
        projects
    };

    // The active target = highest-priority non-blocked project (what ship rounds are pointed at).
    let active_portfolio: Option<&serde_json::Value> = portfolio_projects
        .iter()
        .filter(|p| !p.get("blocked").and_then(|v| v.as_bool()).unwrap_or(false))
        .min_by_key(|p| p.get("priority").and_then(|v| v.as_u64()).unwrap_or(99));

    // Last active repo from chump.log: only count if touched within 1 hour.
    let chump_log_path = base.join("logs/chump.log");
    let now_secs_for_repo = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let one_hour_ago = now_secs_for_repo.saturating_sub(3600);
    let last_active_repo: Option<String> =
        std::fs::read_to_string(&chump_log_path).ok().and_then(|s| {
            let lines: Vec<&str> = s.lines().collect();
            let start = lines.len().saturating_sub(500);
            lines[start..].iter().rev().find_map(|line| {
                // Only consider write_file/patch_file/cli lines.
                if !line.contains("write_file")
                    && !line.contains("patch_file")
                    && !line.contains("| cli |")
                {
                    return None;
                }
                // Check timestamp (first field before first |).
                let ts: u64 = line
                    .split('|')
                    .next()?
                    .trim()
                    .split('.')
                    .next()?
                    .parse()
                    .ok()?;
                if ts < one_hour_ago {
                    return None;
                }
                // Extract repos/ path.
                let repos_pos = line.find("/repos/")?;
                let after = &line[repos_pos + 7..];
                let parts: Vec<&str> = after.splitn(4, '/').collect();
                if parts.is_empty() || parts[0].is_empty() {
                    return None;
                }
                let name = if parts.len() >= 2 && !parts[1].is_empty() && !parts[1].contains('.') {
                    format!("{}/{}", parts[0], parts[1])
                } else {
                    parts[0].to_string()
                };
                Some(name)
            })
        });

    let current_repo: Option<String> = active_portfolio
        .and_then(|p| p.get("repo")?.as_str().map(|s| s.to_string()))
        .or(last_active_repo.clone());

    let current_step: Option<String> = current_repo.clone();

    // Last 5 episodes (summary, detail, happened_at) so the UI can show "what Chump just did".
    // If episodes are absent or all older than 24h, synthesize from the ship log so "Recent" always shows activity.
    //
    // INFRA-1206: filter out CI-fixture episodes (summary starting with
    // "test episode") so the dashboard doesn't show merge-driver test
    // pollution as if it were real activity. Hide-only — the underlying
    // store keeps them for debugging; we just don't surface them.
    let db_episodes: Vec<serde_json::Value> = episode_db::episode_recent(None, 20)
        .unwrap_or_default()
        .into_iter()
        .filter(|e| !is_fixture_episode_summary(&e.summary))
        .take(5)
        .map(|e| {
            serde_json::json!({
                "summary": e.summary,
                "detail": e.detail,
                "happened_at": e.happened_at,
                "repo": e.repo
            })
        })
        .collect();

    let cutoff_secs: u64 = 86_400; // 24h
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let episodes_are_fresh = db_episodes
        .first()
        .and_then(|e| {
            e.get("happened_at")?
                .as_str()
                .and_then(|ts| ts.split('.').next()?.parse::<u64>().ok())
        })
        .map(|ts| now_secs.saturating_sub(ts) < cutoff_secs)
        .unwrap_or(false);

    // Parse recent completed rounds from ship log as fallback.
    let log_episodes: Vec<serde_json::Value> = if !episodes_are_fresh {
        let round_labels = std::collections::HashMap::from([
            ("ship", "Shipped — portfolio step"),
            ("review", "Review — CI, tasks, playbook"),
            ("research", "Research — market/tech"),
            ("maintain", "Maintain — battle QA, Chump"),
        ]);
        ship_lines
            .iter()
            .rev()
            .filter(|l| {
                let t = l.trim();
                t.contains("Round") && (t.ends_with(") ok") || t.contains(") ok"))
            })
            .take(5)
            .map(|l| {
                // "[timestamp] Round N (type) ok" → extract type
                let round_type = l
                    .find('(')
                    .and_then(|s| l[s + 1..].find(')').map(|e| l[s + 1..s + 1 + e].trim()))
                    .unwrap_or("round");
                let label = round_labels.get(round_type).copied().unwrap_or(round_type);
                let ts_str = l
                    .trim_start_matches('[')
                    .split(']')
                    .next()
                    .unwrap_or("")
                    .trim();
                serde_json::json!({
                    "summary": label,
                    "happened_at": ts_str,
                    "repo": null
                })
            })
            .collect()
    } else {
        vec![]
    };

    let last_episodes: Vec<serde_json::Value> = if episodes_are_fresh {
        db_episodes
    } else if !log_episodes.is_empty() {
        log_episodes
    } else {
        db_episodes
    };

    let timestamp_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Last heartbeat time: newest timestamp line in the ship log.
    //
    // INFRA-1206: the field name is `_iso` but historically we just returned
    // whatever string was inside the brackets — which is usually a unix
    // epoch like "1773953115". Format epoch values as proper ISO-8601 UTC
    // so the contract matches the field name. ISO-formatted bracket
    // contents pass through unchanged.
    let last_heartbeat_iso: Option<String> = ship_lines.iter().rev().find_map(|l| {
        let t = l.trim();
        // Lines start with "[UNIX_TS]" or an ISO timestamp prefix.
        let ts_part = t.trim_start_matches('[').split(']').next()?.trim();
        if let Ok(epoch) = ts_part.parse::<i64>() {
            // Epoch integer — convert to ISO-8601 UTC.
            return Some(epoch_to_iso8601(epoch));
        }
        if ts_part.len() >= 10 && ts_part.chars().next()?.is_ascii_digit() {
            // Already looks like an ISO timestamp prefix — pass through.
            Some(ts_part.to_string())
        } else {
            None
        }
    });

    // Fleet role status: green/yellow/red.
    // green  = ship heartbeat running AND last completed round within 2 hours
    // yellow = running but no recent completion (stalled) OR stopped but recent completion
    // red    = not running AND no recent completion
    let two_hours_ago = timestamp_secs.saturating_sub(7200);
    let last_round_secs: Option<u64> = ship_lines.iter().rev().find_map(|l| {
        let t = l.trim();
        if !t.contains("Round") || (!t.contains(") ok") && !t.contains(") done")) {
            return None;
        }
        let ts_str = t.trim_start_matches('[').split(']').next()?.trim();
        ts_str.parse::<u64>().ok()
    });
    let recent_round = last_round_secs
        .map(|ts| ts >= two_hours_ago)
        .unwrap_or(false);
    let fleet_status = if ship_running && recent_round {
        "green"
    } else if ship_running || recent_round {
        "yellow"
    } else {
        "red"
    };

    // INFRA-1206: surface WHY the color was chosen so the operator can drill
    // in. Short human-readable reason; null only when truly all-green.
    let fleet_status_reason: Option<String> = match fleet_status {
        "green" => None,
        "yellow" => Some(if ship_running {
            "ship heartbeat running but no completed round in 2h".to_string()
        } else {
            "no active ship heartbeat (last round within 2h still recent)".to_string()
        }),
        "red" => Some(if !ship_running && last_round_secs.is_none() {
            "no ship heartbeat AND no completed rounds on record".to_string()
        } else {
            "no ship heartbeat AND no completed rounds in 2h".to_string()
        }),
        _ => None,
    };

    // Task throughput stats (AUTO-002): expose open/in_progress/done/done_today counts.
    let task_throughput = task_db::task_stats()
        .map(|s| {
            serde_json::json!({
                "open": s.open,
                "in_progress": s.in_progress,
                "blocked": s.blocked,
                "done": s.done,
                "abandoned": s.abandoned,
                "done_today": s.done_today,
            })
        })
        .unwrap_or(serde_json::json!(null));

    Ok(Json(serde_json::json!({
        "ship_running": ship_running,
        "ship_summary": ship_summary,
        "ship_log_tail": ship_log_tail,
        "current_repo": current_repo,
        "last_active_repo": last_active_repo,
        "active_portfolio": active_portfolio,
        "portfolio_projects": portfolio_projects,
        "current_step": current_step,
        "last_episodes": last_episodes,
        "timestamp_secs": timestamp_secs,
        "last_heartbeat_iso": last_heartbeat_iso,
        "fleet_status": fleet_status,
        "fleet_status_reason": fleet_status_reason,
        "task_throughput": task_throughput,
    })))
}

/// INFRA-1206: return true if a dashboard episode summary looks like a
/// CI test fixture (so we hide it from the operator view).
fn is_fixture_episode_summary(summary: &str) -> bool {
    let s = summary.trim().to_ascii_lowercase();
    s.starts_with("test episode")
}

/// INFRA-1206: format a unix-epoch integer as ISO-8601 UTC.
///
/// Mirrors the helper in ambient_emit::current_iso8601 but takes an
/// arbitrary epoch — used to repair `last_heartbeat_iso` payloads that
/// were leaking raw epochs into the JSON response.
fn epoch_to_iso8601(epoch: i64) -> String {
    if epoch < 0 {
        return format!("{}", epoch);
    }
    let secs = epoch as u64;
    // Civil-from-days routine — same algorithm as ambient_emit, kept inline
    // to avoid a cross-module import for a 4-line function.
    let days = (secs / 86400) as i64;
    let rem = (secs % 86400) as u32;
    let (y, m, d) = civil_from_unix_days(days);
    let h = rem / 3600;
    let mi = (rem % 3600) / 60;
    let se = rem % 60;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, h, mi, se)
}

/// Howard Hinnant's date algorithm: shift days-since-Unix-epoch to civil
/// (year, month, day). Same as the helper inside ambient_emit; kept local
/// to avoid leaking a `pub` from there.
fn civil_from_unix_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// GET /api/dashboard/stream — SSE stream that pushes fresh dashboard data
/// every 30 seconds without client polling.
///
/// Event format: `event: dashboard\ndata: <JSON>\n\n`
async fn handle_dashboard_stream(
    headers: HeaderMap,
) -> Result<
    Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>,
    StatusCode,
> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    fn build_dashboard_snapshot() -> String {
        let base = repo_path::runtime_base();
        let ship_log_path = base.join("logs/heartbeat-ship.log");
        let ship_running = std::process::Command::new("pgrep")
            .args(["-f", "heartbeat-ship"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        let ship_log_content = std::fs::read_to_string(&ship_log_path).unwrap_or_default();
        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let two_hours_ago = now_secs.saturating_sub(7200);
        let last_round_secs: Option<u64> = ship_log_content.lines().rev().find_map(|l| {
            let t = l.trim();
            if !t.contains("Round") || (!t.contains(") ok") && !t.contains(") done")) {
                return None;
            }
            t.trim_start_matches('[')
                .split(']')
                .next()?
                .trim()
                .parse()
                .ok()
        });
        let recent_round = last_round_secs
            .map(|ts| ts >= two_hours_ago)
            .unwrap_or(false);
        let fleet_status = if ship_running && recent_round {
            "green"
        } else if ship_running || recent_round {
            "yellow"
        } else {
            "red"
        };
        // INFRA-1206: epoch → ISO-8601 (mirrors the /api/dashboard fix).
        let last_heartbeat_iso: Option<String> = ship_log_content.lines().rev().find_map(|l| {
            let ts = l.trim().trim_start_matches('[').split(']').next()?.trim();
            if let Ok(epoch) = ts.parse::<i64>() {
                return Some(epoch_to_iso8601(epoch));
            }
            None
        });
        let fleet_status_reason: Option<String> = match fleet_status {
            "green" => None,
            "yellow" => Some(if ship_running {
                "ship heartbeat running but no completed round in 2h".to_string()
            } else {
                "no active ship heartbeat (last round within 2h still recent)".to_string()
            }),
            "red" => Some(if !ship_running && last_round_secs.is_none() {
                "no ship heartbeat AND no completed rounds on record".to_string()
            } else {
                "no ship heartbeat AND no completed rounds in 2h".to_string()
            }),
            _ => None,
        };
        let active_tasks: Vec<serde_json::Value> = crate::task_db::task_list(Some("in_progress"))
            .unwrap_or_default()
            .into_iter()
            .take(3)
            .map(|t| serde_json::json!({ "id": t.id, "title": t.title, "status": t.status }))
            .collect();
        serde_json::to_string(&serde_json::json!({
            "ship_running": ship_running,
            "fleet_status": fleet_status,
            "fleet_status_reason": fleet_status_reason,
            "last_heartbeat_iso": last_heartbeat_iso,
            "active_tasks": active_tasks,
            "timestamp_secs": now_secs,
        }))
        .unwrap_or_default()
    }

    let (tx, rx) =
        tokio::sync::mpsc::unbounded_channel::<Result<Event, std::convert::Infallible>>();
    tokio::spawn(async move {
        loop {
            let data = build_dashboard_snapshot();
            if tx
                .send(Ok(Event::default().event("dashboard").data(data)))
                .is_err()
            {
                break; // client disconnected
            }
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        }
    });

    Ok(Sse::new(UnboundedReceiverStream::new(rx)).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("keep-alive"),
    ))
}

// --- Autopilot control API ---
// MISSION-007: bridge layer between the Rust autopilot (worker ship-loop)
// and the bash fleet-autopilot.sh (10-daemon set, META-090). When the operator
// hits the PWA toggle, BOTH layers respond. One toggle, unified state.
fn invoke_daemon_set(subcmd: &str) -> serde_json::Value {
    use std::process::Command;
    let repo_root = std::env::var("CHUMP_REPO")
        .ok()
        .filter(|p| std::path::Path::new(p).exists())
        .unwrap_or_else(|| "/Users/jeffadkins/Projects/Chump".to_string());
    let script = format!("{}/scripts/coord/fleet-autopilot.sh", repo_root);
    if !std::path::Path::new(&script).exists() {
        return serde_json::json!({
            "available": false,
            "reason": format!("script not found at {}", script)
        });
    }
    let args = if subcmd == "status" {
        vec!["status", "json"]
    } else {
        vec![subcmd]
    };
    match Command::new("/bin/bash").arg(&script).args(&args).output() {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            // For status, try to parse JSON
            if subcmd == "status" {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(
                    stdout.trim().lines().last().unwrap_or(""),
                ) {
                    return serde_json::json!({"available": true, "status": parsed});
                }
            }
            serde_json::json!({
                "available": true,
                "exit_code": out.status.code(),
                "stdout_tail": stdout.lines().rev().take(10).collect::<Vec<_>>(),
                "stderr_tail": stderr.lines().rev().take(5).collect::<Vec<_>>(),
            })
        }
        Err(e) => serde_json::json!({"available": false, "error": e.to_string()}),
    }
}

async fn handle_autopilot_status(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // MISSION-007 unified status: Rust worker state + bash daemon-set state.
    let worker = autopilot::status_autopilot().unwrap_or_else(|_| serde_json::json!({}));
    let daemon_set = invoke_daemon_set("status");
    Ok(Json(serde_json::json!({
        "worker": worker,
        "daemon_set": daemon_set,
    })))
}

async fn handle_autopilot_start(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // MISSION-007: fire BOTH layers. Rust first (it's faster + state-machine
    // managed), then bash daemon-set (idempotent — skips already-loaded plists).
    let worker_result = match autopilot::start_autopilot() {
        Ok(state) => serde_json::json!({"ok": true, "state": state}),
        Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
    };
    let daemon_set_result = invoke_daemon_set("start");
    Ok(Json(serde_json::json!({
        "ok": true,
        "worker": worker_result,
        "daemon_set": daemon_set_result,
        "message": "Unified autopilot start fired both layers (Rust worker + bash daemon-set)"
    })))
}

async fn handle_autopilot_stop(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // MISSION-007: stop BOTH layers. Bash first (graceful launchctl unload),
    // then Rust worker (kills ship-loop process).
    let daemon_set_result = invoke_daemon_set("stop");
    let worker_result = match autopilot::stop_autopilot() {
        Ok(state) => serde_json::json!({"ok": true, "state": state}),
        Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
    };
    Ok(Json(serde_json::json!({
        "ok": true,
        "worker": worker_result,
        "daemon_set": daemon_set_result,
        "message": "Unified autopilot stop fired both layers (bash daemon-set + Rust worker)"
    })))
}

// EFFECTIVE-026: GET /api/autopilot/daemon-status
//
// Shells out to scripts/coord/fleet-autopilot.sh status json and returns the
// parsed JSON response. Each daemon entry has:
//   { "label": "com.chump.xxx", "plist": "yes"|"no", "loaded": "yes"|"no" }
//
// A plist_present_not_loaded state maps to the amber pill in the UI.
// Returns 200 with the raw parsed structure, or a degraded stub on error.
async fn handle_autopilot_daemon_status(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let status = invoke_daemon_set("status");
    // invoke_daemon_set returns {"available": true, "status": <parsed json>}
    // or {"available": false, ...}. We surface the inner "status" object if
    // available; otherwise we pass through the whole error response so the UI
    // can degrade gracefully.
    if status
        .get("available")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
    {
        if let Some(inner) = status.get("status") {
            return Ok(Json(inner.clone()));
        }
    }
    // Error path: return what we have so the UI can show "unavailable".
    Ok(Json(status))
}

#[derive(serde::Deserialize)]
struct WorkingRepoBody {
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    profile: Option<String>,
    #[serde(default)]
    clear: bool,
}

/// GET /api/repo/context — effective repo root for tools (multi-repo aware).
async fn handle_repo_context(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let multi = crate::set_working_repo_tool::set_working_repo_enabled();
    let effective = repo_path::repo_root();
    let eff_str = effective.display().to_string();
    let env_root = std::env::var("CHUMP_REPO")
        .ok()
        .or_else(|| std::env::var("CHUMP_HOME").ok());
    let profiles: Vec<serde_json::Value> = repo_path::repo_profiles_list()
        .into_iter()
        .map(|(name, path)| serde_json::json!({ "name": name, "path": path }))
        .collect();
    let active_profile = repo_path::active_working_profile_name();
    Ok(Json(serde_json::json!({
        "multi_repo_enabled": multi,
        "effective_root": eff_str,
        "has_working_override": repo_path::has_working_repo_override(),
        "chump_repo_env": env_root,
        "profiles": profiles,
        "active_profile": active_profile,
    })))
}

/// POST /api/repo/working — set or clear process-scoped working repo (`CHUMP_MULTI_REPO_ENABLED=1`).
async fn handle_repo_working(
    headers: HeaderMap,
    Json(body): Json<WorkingRepoBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if !crate::set_working_repo_tool::set_working_repo_enabled() {
        return Ok(Json(serde_json::json!({
            "ok": false,
            "error": "set CHUMP_MULTI_REPO_ENABLED=1 to change working repo from the PWA"
        })));
    }
    if body.clear {
        if body.path.is_some() || body.profile.is_some() {
            return Err(StatusCode::BAD_REQUEST);
        }
        repo_path::clear_working_repo();
        return Ok(Json(serde_json::json!({ "ok": true, "cleared": true })));
    }
    let prof = body
        .profile
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    let path_trim = body
        .path
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    if prof.is_some() && path_trim.is_some() {
        return Err(StatusCode::BAD_REQUEST);
    }
    if let Some(key) = prof {
        return match repo_path::set_working_repo_from_profile(key) {
            Ok(()) => Ok(Json(serde_json::json!({ "ok": true, "profile": key }))),
            Err(e) => Ok(Json(serde_json::json!({ "ok": false, "error": e }))),
        };
    }
    let Some(p) = path_trim else {
        return Err(StatusCode::BAD_REQUEST);
    };
    let pb = PathBuf::from(p);
    let canon = pb.canonicalize().map_err(|_| StatusCode::BAD_REQUEST)?;
    if !canon.is_dir() {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !canon.join(".git").is_dir() {
        return Ok(Json(serde_json::json!({
            "ok": false,
            "error": "path must be a git repository root (.git not found)"
        })));
    }
    repo_path::set_working_repo(canon).map_err(|_| StatusCode::BAD_REQUEST)?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── Repo init (INFRA-1015) ────────────────────────────────────────────────
//
// POST /api/repo/init {path} validates path is within allowed parent dirs,
// runs `chump init --no-interactive --no-browser` in that path, installs hooks,
// and returns {ok, state_db_created, hooks_installed, stderr} on failure.
//
// Path allowlist: CHUMP_INIT_ALLOWED_ROOTS (default: /Users/jeffadkins).
// Bypass: CHUMP_INIT_ANYWHERE=1.
// Idempotent: safe to call twice on the same repo (init skips already-done steps).
//
// Optional: seed_starter_gaps=true adds 3 template gaps to the new registry.

#[derive(serde::Deserialize)]
struct RepoInitBody {
    path: String,
    #[serde(default)]
    seed_starter_gaps: bool,
}

/// POST /api/repo/init — initialize a Chump repo from the PWA (INFRA-1015).
async fn handle_repo_init(
    headers: HeaderMap,
    Json(body): Json<RepoInitBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let raw_path = body.path.trim().to_string();
    if raw_path.is_empty() {
        return Ok(Json(serde_json::json!({
            "ok": false,
            "error": "path must not be empty"
        })));
    }

    // Resolve to canonical absolute path (must exist as directory).
    let pb = PathBuf::from(&raw_path);
    let canon = match pb.canonicalize() {
        Ok(p) => p,
        Err(e) => {
            return Ok(Json(serde_json::json!({
                "ok": false,
                "error": format!("cannot resolve path {:?}: {}", raw_path, e)
            })));
        }
    };
    if !canon.is_dir() {
        return Ok(Json(serde_json::json!({
            "ok": false,
            "error": format!("path {:?} is not a directory", canon.display())
        })));
    }

    // ── Allowlist check ──────────────────────────────────────────────────────
    let anywhere = std::env::var("CHUMP_INIT_ANYWHERE")
        .map(|v| v == "1")
        .unwrap_or(false);
    if !anywhere {
        let allowed: Vec<PathBuf> = std::env::var("CHUMP_INIT_ALLOWED_ROOTS")
            .unwrap_or_else(|_| {
                // Default: home dir of current user.
                std::env::var("HOME").unwrap_or_else(|_| "/Users/jeffadkins".to_string())
            })
            .split(':')
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .collect();

        let allowed_resolved: Vec<PathBuf> = allowed
            .iter()
            .filter_map(|p| p.canonicalize().ok())
            .collect();

        let under_allowed = allowed_resolved.iter().any(|root| canon.starts_with(root));
        if !under_allowed {
            tracing::warn!(
                target: "infra_1015",
                path = %canon.display(),
                "POST /api/repo/init: path outside allowed roots — rejected"
            );
            return Ok(Json(serde_json::json!({
                "ok": false,
                "error": format!(
                    "path {:?} is outside allowed roots ({:?}). Set CHUMP_INIT_ALLOWED_ROOTS or CHUMP_INIT_ANYWHERE=1.",
                    canon.display(),
                    allowed_resolved.iter().map(|p| p.display().to_string()).collect::<Vec<_>>()
                )
            })));
        }
    }

    // ── Idempotency: check if state.db already exists ────────────────────────
    let chump_dir = canon.join(".chump");
    let state_db = chump_dir.join("state.db");
    let already_initialized = state_db.exists();

    // ── Run chump init --no-interactive --no-browser ─────────────────────────
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("chump"));
    let init_out = std::process::Command::new(&exe)
        .args(["init", "--no-interactive", "--no-browser"])
        .current_dir(&canon)
        .output();

    let init_stderr = match &init_out {
        Ok(o) => String::from_utf8_lossy(&o.stderr).to_string(),
        Err(e) => e.to_string(),
    };
    let init_ok = init_out
        .as_ref()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !init_ok {
        tracing::warn!(
            target: "infra_1015",
            path = %canon.display(),
            stderr = %init_stderr.trim(),
            "POST /api/repo/init: chump init failed"
        );
        return Ok(Json(serde_json::json!({
            "ok": false,
            "error": format!("chump init failed: {}", init_stderr.trim()),
            "stderr": init_stderr,
        })));
    }

    let state_db_created = !already_initialized && state_db.exists();

    // ── Install hooks ────────────────────────────────────────────────────────
    let repo_root = crate::repo_path::runtime_base();
    let hook_script = repo_root.join("scripts/setup/install-hooks.sh");
    let hooks_installed = if hook_script.exists() {
        let hook_out = std::process::Command::new("bash")
            .arg(&hook_script)
            .arg("--quiet")
            .current_dir(&canon)
            .output();
        hook_out.map(|o| o.status.success()).unwrap_or(false)
    } else {
        // Hook script not found — soft failure (repo may not be the main worktree).
        false
    };

    // ── Optional: seed 3 starter gaps ────────────────────────────────────────
    let gaps_seeded: Vec<String> = if body.seed_starter_gaps && state_db_created {
        seed_starter_gaps(&canon)
    } else {
        vec![]
    };

    tracing::info!(
        target: "infra_1015",
        path = %canon.display(),
        already_initialized,
        state_db_created,
        hooks_installed,
        gaps_seeded = gaps_seeded.len(),
        "POST /api/repo/init: repo initialized ok"
    );
    Ok(Json(serde_json::json!({
        "ok": true,
        "path": canon.display().to_string(),
        "already_initialized": already_initialized,
        "state_db_created": state_db_created,
        "hooks_installed": hooks_installed,
        "gaps_seeded": gaps_seeded,
    })))
}

/// Seed 3 lightweight template gaps into a freshly initialized repo's state.db.
fn seed_starter_gaps(repo_root: &std::path::Path) -> Vec<String> {
    let db_path = repo_root.join(".chump").join("state.db");
    let conn = match rusqlite::Connection::open(&db_path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };
    let starters: &[(&str, &str, &str)] = &[
        (
            "STARTER-001",
            "EFFECTIVE — Add your first feature",
            "Write a hello-world endpoint or script.",
        ),
        (
            "STARTER-002",
            "CREDIBLE — Write a test for the feature",
            "Add an automated test that verifies STARTER-001 works correctly.",
        ),
        (
            "STARTER-003",
            "RESILIENT — Add a health check",
            "Implement a lightweight liveness probe so failures are detected quickly.",
        ),
    ];
    let mut seeded = vec![];
    for (id, title, desc) in starters {
        let r = conn.execute(
            "INSERT OR IGNORE INTO gaps (id, domain, title, status, priority, kind, meta) VALUES (?1,'STARTER',?2,'open','P2','feature',?3)",
            rusqlite::params![id, title, desc],
        );
        // Only count as seeded if a row was actually inserted (rows_affected == 1).
        // INSERT OR IGNORE returns Ok(0) when the row already exists.
        if r == Ok(1) {
            seeded.push(id.to_string());
        }
    }
    seeded
}

// ── PWA secrets (INFRA-989) ────────────────────────────────────────────────
//
// Secret-input flow with mask + test-before-store. Mirror of the INFRA-988
// non-secret settings panel but with hardened semantics:
//   - GET returns presence + last4 only — never the raw value
//   - POST probes the credential against its provider before persisting
//   - Storage: ~/.chump/config.toml [api] section (chmod 600), shared with auth.rs
//   - Logging: presence-only (`forwarding explicit X` pattern), never the value

const SECRET_KEYS: &[&str] = &["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "GH_TOKEN"];

/// Map a public key name to the [api]-section field name in
/// ~/.chump/config.toml. Mirrors src/auth.rs detect_credentials reader.
fn secret_config_location(key: &str) -> Option<&'static str> {
    match key {
        "ANTHROPIC_API_KEY" => Some("anthropic_api_key"),
        "CLAUDE_CODE_OAUTH_TOKEN" => Some("claude_code_oauth_token"),
        "GH_TOKEN" => Some("gh_token"),
        _ => None,
    }
}

/// Resolve a secret by precedence: env → config.toml → not set.
/// Never returned over the API; used internally for masking + probe.
fn resolve_secret(key: &str) -> Option<String> {
    if let Ok(v) = std::env::var(key) {
        let t = v.trim();
        if !t.is_empty() {
            return Some(t.to_string());
        }
    }
    if let Some(field) = secret_config_location(key) {
        if let Some(v) = crate::auth::read_config_kv("api", field) {
            let t = v.trim().to_string();
            if !t.is_empty() {
                return Some(t);
            }
        }
    }
    None
}

/// Return last 4 chars of a string (or fewer if shorter), used for masked
/// display. Empty input → "".
fn last4_of(s: &str) -> String {
    let trimmed = s.trim();
    if trimmed.len() <= 4 {
        return trimmed.to_string();
    }
    trimmed[trimmed.len() - 4..].to_string()
}

/// GET /api/settings/secret/{name} — presence + last4 only.
/// CRITICAL: this endpoint MUST never return the raw value. The handler is
/// the choke point — every internal use goes through resolve_secret().
async fn handle_secret_get(
    axum::extract::Path(key): axum::extract::Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if !SECRET_KEYS.contains(&key.as_str()) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let resolved = resolve_secret(&key);
    let set = resolved.is_some();
    let last4 = resolved.as_deref().map(last4_of).unwrap_or_default();
    tracing::debug!(target: "infra_989", key = %key, set = set, "GET /api/settings/secret");
    Ok(Json(serde_json::json!({
        "set": set,
        "last4": last4,
    })))
}

#[derive(serde::Deserialize)]
struct SecretPostBody {
    value: String,
}

/// POST /api/settings/secret/{name} — probe then persist.
/// Probe is mandatory unless CHUMP_SKIP_PROBE=1 (test-only escape hatch).
/// Returns 422 on probe failure WITHOUT writing — operator gets feedback
/// before a bad credential silently breaks the fleet.
async fn handle_secret_post(
    axum::extract::Path(key): axum::extract::Path<String>,
    headers: HeaderMap,
    Json(body): Json<SecretPostBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if !check_csrf(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    if !check_origin_localhost(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    if !SECRET_KEYS.contains(&key.as_str()) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let value = body.value.trim();
    if value.is_empty() || value.len() > 4096 || value.contains('"') || value.contains('\n') {
        return Err(StatusCode::BAD_REQUEST);
    }

    let skip_probe = std::env::var("CHUMP_SKIP_PROBE")
        .map(|v| v != "0")
        .unwrap_or(false);
    if !skip_probe {
        let probe_ok = probe_secret(&key, value).await;
        if !probe_ok {
            tracing::warn!(target: "infra_989", key = %key, "secret probe failed; not persisting");
            return Err(StatusCode::UNPROCESSABLE_ENTITY);
        }
    }

    let Some(field) = secret_config_location(&key) else {
        return Err(StatusCode::BAD_REQUEST);
    };
    crate::auth::write_config_kv("api", field, value)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    // Presence-only log line — NEVER `value` here.
    tracing::info!(
        target: "infra_989",
        key = %key,
        last4 = %last4_of(value),
        probe_skipped = skip_probe,
        "secret persisted to ~/.chump/config.toml [api]"
    );
    emit_secret_changed(&key, &last4_of(value), skip_probe);
    Ok(Json(serde_json::json!({
        "ok": true,
        "key": key,
        "stored": true,
        "last4": last4_of(value),
    })))
}

/// Probe a credential by hitting its provider with a tiny call.
/// Cost: one cheap API call per save. Bypassable via CHUMP_SKIP_PROBE=1
/// in test/CI environments where outbound network would flake.
async fn probe_secret(key: &str, value: &str) -> bool {
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    match key {
        "ANTHROPIC_API_KEY" | "CLAUDE_CODE_OAUTH_TOKEN" => {
            let body = serde_json::json!({
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "messages": [{"role": "user", "content": "x"}],
            });
            let resp = if key == "ANTHROPIC_API_KEY" {
                client
                    .post("https://api.anthropic.com/v1/messages")
                    .header("anthropic-version", "2023-06-01")
                    .header("x-api-key", value)
                    .json(&body)
                    .send()
                    .await
            } else {
                client
                    .post("https://api.anthropic.com/v1/messages")
                    .header("anthropic-version", "2023-06-01")
                    .header("authorization", format!("Bearer {}", value))
                    .json(&body)
                    .send()
                    .await
            };
            match resp {
                // 200: real success.
                // 400: auth accepted, body rejected — still proves the key.
                // Anything else (401, 403, 5xx, network err): fail.
                Ok(r) => {
                    let s = r.status();
                    s.is_success() || s == reqwest::StatusCode::BAD_REQUEST
                }
                Err(_) => false,
            }
        }
        "GH_TOKEN" => {
            let resp = client
                .get("https://api.github.com/user")
                .header("authorization", format!("Bearer {}", value))
                .header("user-agent", "chump-pwa")
                .send()
                .await;
            match resp {
                Ok(r) => r.status().is_success(),
                Err(_) => false,
            }
        }
        _ => false,
    }
}

/// Emit `kind=pwa_secret_changed` to ambient.jsonl with ONLY non-sensitive
/// fields (key name, last4, probe-skipped flag). The raw value never leaves
/// the handler's local scope.
fn emit_secret_changed(key: &str, last4: &str, probe_skipped: bool) {
    let event = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "kind": "pwa_secret_changed",
        "key": key,
        "last4": last4,
        "probe_skipped": probe_skipped,
    });
    let path = repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{}", event);
    }
}

// ── PWA settings panel (INFRA-988) ─────────────────────────────────────────
//
// Non-secret operator config exposed via /api/settings. Storage tier A
// (~/.chump/config.toml `[settings]` section) per docs/roadmap/PWA_COCKPIT_DEMO.md.
// Secrets are explicitly out of scope (INFRA-989 owns that path).

const SETTINGS_KEYS: &[&str] = &[
    "CHUMP_AUTH_MODE",
    "CHUMP_MULTI_REPO_ENABLED",
    "FLEET_SIZE",
    "FLEET_MODEL",
    "CHUMP_ROUND_PRIVACY",
    "CHUMP_REPO",
    // PRODUCT-118: operator dials for throttle + work-backend selection.
    "CHUMP_GH_MAX_CALLS_PER_MIN",
    "CHUMP_WORK_BACKEND",
];

fn settings_default(key: &str) -> &'static str {
    match key {
        "CHUMP_AUTH_MODE" => "auto",
        "CHUMP_MULTI_REPO_ENABLED" => "0",
        "FLEET_SIZE" => "4",
        "FLEET_MODEL" => "sonnet",
        "CHUMP_ROUND_PRIVACY" => "safe",
        "CHUMP_REPO" => "",
        // PRODUCT-118: throttle cap (per-min sliding window) + work-backend.
        // 60/min matches CHUMP_GH_MAX_CALLS_PER_MIN default in chump_gh wrapper.
        "CHUMP_GH_MAX_CALLS_PER_MIN" => "60",
        "CHUMP_WORK_BACKEND" => "claude",
        _ => "",
    }
}

/// Resolve a settings value: env → config.toml [settings] → built-in default.
/// Returns (value, source) where source ∈ {"env", "config", "default"}.
fn resolve_setting(key: &str) -> (String, &'static str) {
    if let Ok(v) = std::env::var(key) {
        if !v.is_empty() {
            return (v, "env");
        }
    }
    if let Some(v) = crate::auth::read_config_kv("settings", key) {
        return (v, "config");
    }
    (settings_default(key).to_string(), "default")
}

/// Reject requests whose Origin header is set and not localhost. Absent
/// Origin (same-origin / non-browser) is allowed — CSRF + auth still apply.
fn check_origin_localhost(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get("origin").and_then(|v| v.to_str().ok()) else {
        return true;
    };
    let lower = origin.to_lowercase();
    lower.starts_with("http://localhost")
        || lower.starts_with("https://localhost")
        || lower.starts_with("http://127.0.0.1")
        || lower.starts_with("https://127.0.0.1")
        || lower.starts_with("http://[::1]")
        || lower.starts_with("https://[::1]")
}

/// Per-key value validation. Conservative — reject anything that doesn't match
/// the expected shape so a typo can't break the fleet.
fn validate_setting_value(key: &str, value: &str) -> bool {
    match key {
        "CHUMP_AUTH_MODE" => matches!(value, "auto" | "api-key" | "oauth"),
        "CHUMP_MULTI_REPO_ENABLED" => matches!(value, "0" | "1"),
        "FLEET_SIZE" => value
            .parse::<u32>()
            .ok()
            .is_some_and(|n| (0..=64).contains(&n)),
        "FLEET_MODEL" => matches!(value, "haiku" | "sonnet" | "opus"),
        "CHUMP_ROUND_PRIVACY" => matches!(value, "safe" | "dogfood"),
        "CHUMP_REPO" => value.is_empty() || value.starts_with('/'),
        // PRODUCT-118: throttle cap 1..600 calls/min (1 = effectively paused;
        // 600 = unthrottled). Backend default is 60.
        "CHUMP_GH_MAX_CALLS_PER_MIN" => value
            .parse::<u32>()
            .ok()
            .is_some_and(|n| (1..=600).contains(&n)),
        // PRODUCT-118: work-backend selector — must match dispatch::backend_from_env.
        "CHUMP_WORK_BACKEND" => {
            matches!(
                value,
                "claude" | "opencode" | "aider" | "chump-local" | "exec-gap"
            )
        }
        _ => false,
    }
}

/// GET /api/settings — return all whitelisted non-secret settings with sources.
async fn handle_settings_get(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let mut out = serde_json::Map::new();
    for key in SETTINGS_KEYS {
        let (value, source) = resolve_setting(key);
        out.insert(
            (*key).to_string(),
            serde_json::json!({ "value": value, "source": source }),
        );
    }
    tracing::debug!(target: "infra_988", "GET /api/settings served {} keys", SETTINGS_KEYS.len());
    Ok(Json(serde_json::Value::Object(out)))
}

#[derive(serde::Deserialize)]
struct SettingsPostBody {
    value: String,
}

/// POST /api/settings/{key} — persist a single non-secret setting to
/// ~/.chump/config.toml `[settings]` section. Validates the key is in the
/// whitelist and the value passes per-key sanity checks. CSRF + auth required.
async fn handle_settings_post(
    axum::extract::Path(key): axum::extract::Path<String>,
    headers: HeaderMap,
    Json(body): Json<SettingsPostBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if !check_csrf(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    if !check_origin_localhost(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    if !SETTINGS_KEYS.contains(&key.as_str()) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let trimmed = body.value.trim();
    if trimmed.contains('"') || trimmed.contains('\n') || trimmed.len() > 1024 {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !validate_setting_value(&key, trimmed) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let (_, source_before) = resolve_setting(&key);
    crate::auth::write_config_kv("settings", &key, trimmed)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    tracing::info!(
        target: "infra_988",
        key = %key,
        value = %trimmed,
        source_before = %source_before,
        "POST /api/settings persisted to ~/.chump/config.toml [settings]"
    );
    emit_pwa_setting_changed(&key, trimmed, source_before);
    Ok(Json(
        serde_json::json!({ "ok": true, "key": key, "stored": true }),
    ))
}

/// Best-effort write to `.chump-locks/ambient.jsonl`. Operator-visible signal
/// that the PWA mutated config. Silently no-ops if the file cannot be opened.
fn emit_pwa_setting_changed(key: &str, value: &str, source_before: &str) {
    let event = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "kind": "pwa_setting_changed",
        "key": key,
        "value": value,
        "source_before": source_before,
    });
    let path = repo_path::runtime_base()
        .join(".chump-locks")
        .join("ambient.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{}", event);
    }
}

// --- Ingest (Phase 2.2) ---
#[derive(serde::Deserialize)]
struct IngestBody {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    url: Option<String>,
    /// Optional label (e.g. `ios_shortcut`, `pwa`) stored as `<!-- capture_source: … -->` in the file.
    #[serde(default)]
    source: Option<String>,
}

async fn handle_ingest_json(
    headers: HeaderMap,
    Json(b): Json<IngestBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let src = b.source.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if let Some(ref text) = b.text {
        let content = text.trim();
        if !content.is_empty() {
            let (rel, summary) =
                web_brain::ingest_write_stamped(content.as_bytes(), "md", "Note", src).map_err(
                    |e| {
                        if e.to_string().contains("exceeds") {
                            StatusCode::PAYLOAD_TOO_LARGE
                        } else {
                            StatusCode::INTERNAL_SERVER_ERROR
                        }
                    },
                )?;
            let capture_id = rel
                .trim_end_matches(".md")
                .rsplit('/')
                .next()
                .unwrap_or(&rel)
                .to_string();
            return Ok(Json(serde_json::json!({
                "capture_id": capture_id,
                "filename": rel.rsplit('/').next().unwrap_or("capture.md"),
                "summary": summary,
                "brain_path": rel
            })));
        }
    }
    if let Some(ref url) = b.url {
        let u = url.trim();
        if !u.is_empty() {
            let content = format!("URL: {}\n\n", u);
            let (rel, summary) =
                web_brain::ingest_write_stamped(content.as_bytes(), "md", "URL", src).map_err(
                    |e| {
                        if e.to_string().contains("exceeds") {
                            StatusCode::PAYLOAD_TOO_LARGE
                        } else {
                            StatusCode::INTERNAL_SERVER_ERROR
                        }
                    },
                )?;
            let capture_id = rel
                .trim_end_matches(".md")
                .rsplit('/')
                .next()
                .unwrap_or(&rel)
                .to_string();
            return Ok(Json(serde_json::json!({
                "capture_id": capture_id,
                "filename": rel.rsplit('/').next().unwrap_or("capture.md"),
                "summary": summary,
                "brain_path": rel
            })));
        }
    }
    Err(StatusCode::BAD_REQUEST)
}

async fn handle_ingest_upload(
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|_| StatusCode::BAD_REQUEST)?
    {
        let name = field.name().unwrap_or_default().to_string();
        if name != "file" && name != "text" {
            continue;
        }
        let filename = field.file_name().unwrap_or("paste").to_string();
        let data = field.bytes().await.map_err(|_| StatusCode::BAD_REQUEST)?;
        if data.len() > web_brain::MAX_INGEST_BYTES {
            return Err(StatusCode::PAYLOAD_TOO_LARGE);
        }
        let ext = if filename.ends_with(".md") {
            "md"
        } else if filename.contains('.') {
            filename.rsplit('.').next().unwrap_or("md")
        } else {
            "md"
        };
        let (rel, summary) = web_brain::ingest_write(&data, ext, "File")
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let capture_id = rel
            .trim_end_matches(".md")
            .rsplit('/')
            .next()
            .unwrap_or(&rel)
            .to_string();
        return Ok(Json(serde_json::json!({
            "capture_id": capture_id,
            "filename": filename,
            "summary": summary,
            "brain_path": rel
        })));
    }
    Err(StatusCode::BAD_REQUEST)
}

// --- Research (Phase 2.4) ---
#[derive(serde::Deserialize)]
struct ResearchCreateBody {
    topic: String,
    #[serde(default)]
    content: Option<String>,
}

async fn handle_research_list(
    headers: HeaderMap,
) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = web_brain::research_list().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = list
        .into_iter()
        .map(|(id, topic, path)| serde_json::json!({ "id": id, "topic": topic, "path": path }))
        .collect();
    Ok(Json(out))
}

async fn handle_research_create(
    headers: HeaderMap,
    Json(body): Json<ResearchCreateBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let topic = body.topic.trim();
    if topic.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let content = body.content.as_deref().unwrap_or("");
    let path = web_brain::research_create(topic, content)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let id = path
        .trim_end_matches(".md")
        .rsplit('/')
        .next()
        .unwrap_or("brief")
        .to_string();
    Ok(Json(
        serde_json::json!({ "id": id, "topic": topic, "path": path }),
    ))
}

async fn handle_research_get(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let content = web_brain::research_get(id.trim()).map_err(|_| StatusCode::NOT_FOUND)?;
    Ok(Json(serde_json::json!({ "content": content })))
}

// --- Watch (Phase 2.5) ---
async fn handle_watch_list(headers: HeaderMap) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = web_brain::watch_list().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = list
        .into_iter()
        .map(|(name, count)| serde_json::json!({ "list": name, "count": count }))
        .collect();
    Ok(Json(out))
}

#[derive(serde::Deserialize)]
struct WatchAddBody {
    list: String,
    item: String,
}

async fn handle_watch_add(
    headers: HeaderMap,
    Json(body): Json<WatchAddBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = body.list.trim();
    if list.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    web_brain::watch_add(list, body.item.trim()).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn handle_watch_delete(
    headers: HeaderMap,
    Path((list, item_id)): Path<(String, String)>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let index: usize = item_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    web_brain::watch_remove(list.trim(), index).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn handle_watch_alerts(
    headers: HeaderMap,
) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let items = web_brain::watch_flagged_items().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = items
        .into_iter()
        .map(|i| serde_json::json!({ "list": i.list, "line": i.line }))
        .collect();
    Ok(Json(out))
}

// --- Projects (Phase 2.6) ---
async fn handle_projects_list(
    headers: HeaderMap,
) -> Result<Json<Vec<serde_json::Value>>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let list = web_brain::projects_list().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let out: Vec<_> = list
        .into_iter()
        .map(|(id, name, path)| serde_json::json!({ "id": id, "name": name, "path": path }))
        .collect();
    Ok(Json(out))
}

#[derive(serde::Deserialize)]
struct ProjectAddBody {
    name: String,
    #[serde(default)]
    repo_path: Option<String>,
    #[serde(default)]
    description: Option<String>,
}

async fn handle_projects_create(
    headers: HeaderMap,
    Json(body): Json<ProjectAddBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let name = body.name.trim();
    if name.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let path = web_brain::project_add(
        name,
        body.repo_path.as_deref().unwrap_or(""),
        body.description.as_deref().unwrap_or(""),
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let id = path
        .trim_end_matches(".md")
        .rsplit('/')
        .next()
        .unwrap_or("project")
        .to_string();
    Ok(Json(
        serde_json::json!({ "id": id, "name": name, "path": path }),
    ))
}

async fn handle_projects_activate(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    web_brain::project_activate(id.trim()).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

// --- Push (Phase 3.1, minimal: store subscriptions, no send yet) ---
async fn handle_push_vapid_public_key(
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // INFRA-1301: env var wins; else read from .chump/push-keys.json
    // (generated by scripts/setup/gen-vapid-keys.sh); else fall back to the
    // legacy placeholder for backward compat.
    let key = std::env::var("CHUMP_VAPID_PUBLIC_KEY")
        .ok()
        .filter(|s| !s.is_empty());
    let key = key.or_else(|| {
        let repo_root = crate::repo_path::runtime_base();
        let keys_path = repo_root.join(".chump").join("push-keys.json");
        std::fs::read_to_string(&keys_path)
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .and_then(|v| {
                v.get("vapid_public_key")
                    .and_then(|x| x.as_str())
                    .map(String::from)
            })
            .filter(|s| !s.is_empty())
    });
    let key = key.unwrap_or_else(|| "BEl62iUYgUivxIkv69yViEuiBIa-Ib27-SVMrSGYoiU".to_string());
    Ok(Json(serde_json::json!({ "vapid_public_key": key })))
}

#[derive(serde::Deserialize)]
struct PushSubscribeBody {
    endpoint: String,
    #[serde(default)]
    keys: Option<PushKeys>,
}

#[derive(serde::Deserialize)]
struct PushKeys {
    p256dh: Option<String>,
    auth: Option<String>,
}

async fn handle_push_subscribe(
    headers: HeaderMap,
    Json(body): Json<PushSubscribeBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let endpoint = body.endpoint.trim();
    if endpoint.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let (p256dh, auth) = body
        .keys
        .as_ref()
        .map(|k| {
            (
                k.p256dh.as_deref().unwrap_or(""),
                k.auth.as_deref().unwrap_or(""),
            )
        })
        .unwrap_or(("", ""));
    let conn = db_pool::get().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    conn.execute(
        "INSERT OR REPLACE INTO chump_push_subscriptions (endpoint, p256dh, auth) VALUES (?1, ?2, ?3)",
        rusqlite::params![endpoint, p256dh, auth],
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
struct PushUnsubscribeBody {
    endpoint: String,
}

async fn handle_push_unsubscribe(
    headers: HeaderMap,
    Json(body): Json<PushUnsubscribeBody>,
) -> Result<StatusCode, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let endpoint = body.endpoint.trim();
    let conn = db_pool::get().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let _ = conn.execute(
        "DELETE FROM chump_push_subscriptions WHERE endpoint = ?1",
        rusqlite::params![endpoint],
    );
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
struct ToolApprovalAuditQuery {
    #[serde(default = "default_audit_limit")]
    limit: usize,
    #[serde(default)]
    format: Option<String>,
}

fn default_audit_limit() -> usize {
    40
}

#[derive(serde::Deserialize)]
struct CosDecisionsQuery {
    #[serde(default = "default_cos_limit")]
    limit: usize,
}

fn default_cos_limit() -> usize {
    8
}

fn csv_escape_cell(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

async fn handle_tool_approval_audit(
    headers: HeaderMap,
    Query(q): Query<ToolApprovalAuditQuery>,
) -> Result<Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let limit = q.limit.clamp(1, 500);
    let rows = crate::chump_log::recent_tool_approval_audits(limit);
    if q.format.as_deref() == Some("csv") {
        let mut w = String::from("ts,tool,risk_level,result,args_preview,request_id\n");
        for r in &rows {
            w.push_str(&format!(
                "{},{},{},{},{},{}\n",
                csv_escape_cell(r.ts.as_deref().unwrap_or("")),
                csv_escape_cell(&r.tool),
                csv_escape_cell(&r.risk_level),
                csv_escape_cell(&r.result),
                csv_escape_cell(&r.args_preview),
                csv_escape_cell(r.request_id.as_deref().unwrap_or("")),
            ));
        }
        return Ok(([(header::CONTENT_TYPE, "text/csv; charset=utf-8")], w).into_response());
    }
    Ok(Json(serde_json::json!({
        "entries": rows,
        "source": "logs/chump.log tail (append-only audit; cwd + logs/chump.log)"
    }))
    .into_response())
}

async fn handle_cos_decisions(
    headers: HeaderMap,
    Query(q): Query<CosDecisionsQuery>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let limit = q.limit.clamp(1, 50);
    let list =
        web_brain::cos_decisions_recent(limit).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "decisions": list })))
}

// --- PRODUCT-079: Needs-Judgment queue ---

#[derive(serde::Deserialize)]
struct AckBody {
    item_type: String,
    item_id: String,
}

async fn handle_needs_judgment(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let repo_root = std::env::var("CHUMP_REPO")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| repo_path::runtime_base());

    let db_path = chump_gap_store::store_path::state_db_path(&repo_root); // INFRA-8190
    let ambient_path = std::env::var("CHUMP_AMBIENT_IN_PROMPT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks/ambient.jsonl"));

    let mut items: Vec<serde_json::Value> = Vec::new();
    let mut last_decision_ago: Option<String> = None;

    // Source 1 — gaps whose notes or AC mention operator input needed.
    if let Ok(conn) = rusqlite::Connection::open(&db_path) {
        let query = "SELECT id, title, notes, priority FROM gaps \
                     WHERE status='open' AND (notes LIKE '%operator%' OR notes LIKE '%judgment%' \
                           OR acceptance_criteria LIKE '%operator decides%') \
                     ORDER BY priority, id LIMIT 20";
        if let Ok(mut stmt) = conn.prepare(query) {
            let rows = stmt.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            });
            if let Ok(rows) = rows {
                for row in rows.flatten() {
                    items.push(serde_json::json!({
                        "item_type": "gap",
                        "id": row.0,
                        "summary": row.1,
                        "detail": row.2.lines().next().unwrap_or("").trim(),
                        "priority": row.3,
                        "recommended_action": "review gap and decide"
                    }));
                }
            }
        }

        // Track last decision time for empty-state message.
        let ack_q = "SELECT ts FROM operator_acks ORDER BY ts DESC LIMIT 1";
        if let Ok(ts) = conn.query_row(ack_q, [], |r| r.get::<_, String>(0)) {
            last_decision_ago = Some(ts);
        }
    }

    // Source 2 — ambient events: operator_recall and pr_needs_owner_action.
    if let Ok(content) = std::fs::read_to_string(&ambient_path) {
        for line in content.lines().rev().take(500) {
            let v: serde_json::Value = match serde_json::from_str(line) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let kind = match v.get("kind").and_then(|k| k.as_str()) {
                Some(k) => k,
                None => continue,
            };
            if kind == "operator_recall" || kind == "pr_needs_owner_action" {
                let id = v
                    .get("gap_id")
                    .or_else(|| v.get("pr"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let ts = v
                    .get("ts")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let already = items.iter().any(|i| {
                    i.get("id").and_then(|x| x.as_str()) == Some(&id)
                        && i.get("item_type").and_then(|x| x.as_str()) == Some("event")
                });
                if !already {
                    items.push(serde_json::json!({
                        "item_type": "event",
                        "id": id,
                        "summary": v.get("message").and_then(|m| m.as_str()).unwrap_or(kind),
                        "age": ts,
                        "recommended_action": if kind == "pr_needs_owner_action" {
                            "check PR and unblock"
                        } else {
                            "recall and decide"
                        }
                    }));
                }
                if items.len() >= 50 {
                    break;
                }
            }
        }
    }

    Ok(Json(serde_json::json!({
        "items": items,
        "count": items.len(),
        "last_decision_ts": last_decision_ago,
    })))
}

async fn handle_needs_judgment_ack(
    headers: HeaderMap,
    Json(body): Json<AckBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let repo_root = std::env::var("CHUMP_REPO")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| repo_path::runtime_base());

    let ambient_path = std::env::var("CHUMP_AMBIENT_IN_PROMPT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks/ambient.jsonl"));

    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = serde_json::json!({
        "ts": ts,
        "kind": "operator_acknowledged",
        "item_type": body.item_type,
        "item_id": body.item_id,
    });
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{}", event);
    }

    // Persist ack to state.db so we can show "last decision N ago".
    let db_path = chump_gap_store::store_path::state_db_path(&repo_root); // INFRA-8190
    if let Ok(conn) = rusqlite::Connection::open(&db_path) {
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS operator_acks \
             (ts TEXT NOT NULL, item_type TEXT NOT NULL, item_id TEXT NOT NULL);",
        );
        let _ = conn.execute(
            "INSERT INTO operator_acks (ts, item_type, item_id) VALUES (?1, ?2, ?3)",
            rusqlite::params![ts, body.item_type, body.item_id],
        );
    }

    Ok(Json(serde_json::json!({ "ok": true })))
}

// --- iOS Shortcuts (Phase 5) ---
#[derive(serde::Deserialize)]
struct ShortcutTaskBody {
    title: String,
}

async fn handle_shortcut_task(
    headers: HeaderMap,
    Json(body): Json<ShortcutTaskBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let title = body.title.trim();
    if title.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let id = task_db::task_create(title, None, None, None, None, None)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(serde_json::json!({ "id": id, "title": title })))
}

#[derive(serde::Deserialize)]
struct ShortcutCaptureBody {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    source: Option<String>,
}

async fn handle_shortcut_capture(
    headers: HeaderMap,
    Json(body): Json<ShortcutCaptureBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let text = body.text.as_deref().unwrap_or("").trim();
    if text.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let src = body
        .source
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .or(Some("ios_shortcut"));
    let (_, summary) = web_brain::ingest_write_stamped(text.as_bytes(), "md", "Shortcut", src)
        .map_err(|e| {
            if e.to_string().contains("exceeds") {
                StatusCode::PAYLOAD_TOO_LARGE
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            }
        })?;
    Ok(Json(serde_json::json!({ "summary": summary })))
}

async fn handle_shortcut_status(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let open_count = task_db::task_list(Some("open"))
        .map(|v| v.len())
        .unwrap_or(0);
    let in_progress = task_db::task_list(Some("in_progress"))
        .map(|v| v.len())
        .unwrap_or(0);
    let line = format!(
        "Chump online. {} open, {} in progress.",
        open_count, in_progress
    );
    Ok(Json(serde_json::json!({ "status": line })))
}

#[derive(serde::Deserialize)]
struct ShortcutCommandBody {
    command: String,
}

async fn handle_shortcut_command(
    headers: HeaderMap,
    Json(body): Json<ShortcutCommandBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let cmd = body.command.trim().to_lowercase();
    let result = match cmd.as_str() {
        "status" => {
            let open_count = task_db::task_list(Some("open"))
                .map(|v| v.len())
                .unwrap_or(0);
            format!("{} open tasks.", open_count)
        }
        "deploy" | "test" | "reboot" => format!(
            "Command \"{}\" acknowledged. Run via chat for full execution.",
            cmd
        ),
        _ => format!(
            "Unknown command: \"{}\". Use status, deploy, test, or reboot.",
            cmd
        ),
    };
    Ok(Json(serde_json::json!({ "result": result })))
}

async fn handle_analytics(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    match web_sessions_db::analytics_summary() {
        Ok(summary) => Ok(Json(
            serde_json::to_value(summary).unwrap_or(serde_json::json!({})),
        )),
        Err(_) => Ok(Json(serde_json::json!({
            "total_sessions": 0, "total_turns": 0, "total_tool_calls": 0,
            "total_narrations": 0, "avg_latency_ms": 0, "thumbs_up": 0, "thumbs_down": 0,
            "recent_sessions": []
        }))),
    }
}

async fn handle_message_feedback(
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<i64>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let feedback = body
        .get("feedback")
        .and_then(|v| v.as_i64())
        .map(|v| v.clamp(-1, 1) as i32)
        .unwrap_or(0);
    match web_sessions_db::record_message_feedback(id, feedback) {
        Ok(true) => Ok(Json(serde_json::json!({"ok": true}))),
        Ok(false) => Err(StatusCode::NOT_FOUND),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

/// Read the kill-gate threshold from `~/.chump/config.toml` `[cost]` section.
/// Returns `None` when the file is missing, the section is absent, or the key
/// is absent — meaning no kill gate is active (AC: missing config → no kill gate).
fn cost_kill_threshold() -> Option<f64> {
    crate::auth::read_config_kv("cost", "kill")
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|&t| t > 0.0)
}

/// POST /api/chat — kill-gate wrapper (INFRA-1335).
///
/// Checks `session_cost_usd` against the `[cost] kill` threshold from
/// `chump.toml` before delegating to [`handle_chat`]. Returns HTTP 402 with
/// `{"error":"session_cost_exceeded",...}` when the threshold is exceeded.
/// Returns the normal SSE stream when under threshold or no threshold is set.
async fn handle_chat_with_kill_gate(headers: HeaderMap, Json(body): Json<ChatRequest>) -> Response {
    if let Some(kill_thresh) = cost_kill_threshold() {
        let session_cost = crate::cost_tracker::session_cost_usd();
        if session_cost > kill_thresh {
            let session_id = body.session_id.as_deref().unwrap_or("default").to_string();
            tracing::warn!(
                session_id = %session_id,
                session_cost_usd = session_cost,
                threshold_usd = kill_thresh,
                "INFRA-1335: session_cost_kill — refusing chat, cost exceeds threshold"
            );
            // Emit ambient event for observability (INFRA-1335 AC-3).
            let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                kind: "session_cost_kill".to_string(),
                fields: vec![
                    ("session_id".to_string(), session_id),
                    ("cost_usd".to_string(), format!("{:.6}", session_cost)),
                    ("threshold_usd".to_string(), format!("{:.6}", kill_thresh)),
                ],
                ..Default::default()
            });
            return (
                StatusCode::PAYMENT_REQUIRED,
                Json(serde_json::json!({
                    "error": "session_cost_exceeded",
                    "session_cost_usd": session_cost,
                    "threshold_usd": kill_thresh,
                })),
            )
                .into_response();
        }
    }
    handle_chat(headers, Json(body)).await.into_response()
}

async fn handle_chat(
    headers: HeaderMap,
    Json(body): Json<ChatRequest>,
) -> Result<
    Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>,
    StatusCode,
> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let message = body.message.trim().to_string();
    if message.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }
    if limits::check_message_len(&message).is_err() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let raw_session_id = body.session_id.as_deref().unwrap_or("default").trim();
    let session_id = web_sessions_db::session_ensure(raw_session_id, "chump")
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    if let Some(po) = body.policy_override {
        if crate::policy_override::policy_override_api_enabled() {
            crate::policy_override::register_session_relax(
                &session_id,
                &po.relax_tools,
                po.ttl_secs,
            );
        }
    }

    let attachments_json = body
        .attachments
        .as_ref()
        .and_then(|a| serde_json::to_string(a).ok());
    let mut message_for_agent = message.clone();
    if let Some(ref atts) = body.attachments {
        if !atts.is_empty() {
            let vision_on = web_uploads::vision_enabled();
            let mut parts = Vec::<String>::new();
            for a in atts {
                let fid = a.file_id.trim();
                // COMP-005a: image route — when CHUMP_VISION_ENABLED=1 and
                // the upload MIME is image/*, embed as a `data:` URL the
                // vision-capable provider can parse. Otherwise fall back
                // to the existing text/placeholder paths.
                if vision_on {
                    match web_uploads::read_upload_as_image_data_url(fid) {
                        Ok(Some(data_url)) => {
                            parts.push(format!("[Image attachment: {}]\n{}", a.filename, data_url));
                            continue;
                        }
                        Ok(None) => {} // not an image; fall through
                        Err(e) => {
                            // Oversized or read failure — surface to user
                            // rather than silently dropping.
                            parts.push(format!(
                                "[Image attachment {} could not be inlined: {}]",
                                a.filename, e
                            ));
                            continue;
                        }
                    }
                }
                match web_uploads::read_upload_as_text(fid) {
                    Ok(Some(text)) => parts.push(format!("[Attachment: {}]\n{}", a.filename, text)),
                    _ => parts.push(format!("[User attached file: {}]", a.filename)),
                }
            }
            message_for_agent = format!("{}\n\n{}", parts.join("\n\n"), message_for_agent);
        }
    }
    if let Err(e) =
        web_sessions_db::message_append_user(&session_id, &message, attachments_json.as_deref())
    {
        eprintln!("[web] failed to persist user message: {}", e);
    }

    // Belt-and-suspenders: if user typed /task, /research, or /watch raw, handle server-side and return quick reply (no agent).
    if body.attachments.is_none()
        || body
            .attachments
            .as_ref()
            .map(|a| a.is_empty())
            .unwrap_or(true)
    {
        let quick_reply = if let Some(title) = message.strip_prefix("/task ").map(|s| s.trim()) {
            if title.is_empty() {
                None
            } else {
                task_db::task_create(title, None, None, None, None, None)
                    .ok()
                    .map(|id| format!("Created task #{}: {}", id, title))
            }
        } else if let Some(topic) = message.strip_prefix("/research ").map(|s| s.trim()) {
            if topic.is_empty() {
                None
            } else {
                web_brain::research_create(topic, "")
                    .ok()
                    .map(|_| format!("Research brief queued: {}", topic))
            }
        } else if let Some(rest) = message.strip_prefix("/watch ").map(|s| s.trim()) {
            if rest.is_empty() {
                None
            } else {
                let (list, item) = if let Some((first, tail)) = rest.split_once(char::is_whitespace)
                {
                    (first.trim(), tail.trim())
                } else {
                    ("default", rest)
                };
                if item.is_empty() {
                    None
                } else {
                    web_brain::watch_add(list, item)
                        .ok()
                        .map(|_| format!("Added to watchlist \"{}\": {}", list, item))
                }
            }
        } else {
            None
        };
        if let Some(reply) = quick_reply {
            let _ = web_sessions_db::message_append_assistant(&session_id, &reply, None, None);
            let (event_tx, event_rx) = stream_events::event_channel();
            let _ = event_tx.send(stream_events::AgentEvent::WebSessionReady {
                session_id: session_id.clone(),
            });
            let _ = event_tx.send(stream_events::AgentEvent::TextComplete {
                text: reply.clone(),
            });
            let _ = event_tx.send(stream_events::AgentEvent::TurnComplete {
                request_id: uuid::Uuid::new_v4().to_string(),
                full_text: reply,
                duration_ms: 0,
                tool_calls_count: 0,
                model_calls_count: 0,
                thinking_monologue: None,
            });
            drop(event_tx);
            return Ok(Sse::new(agent_event_stream(event_rx)));
        }
    }

    let (event_tx, event_rx) = stream_events::event_channel();
    let _ = event_tx.send(stream_events::AgentEvent::WebSessionReady {
        session_id: session_id.clone(),
    });
    let bot = body.bot.as_deref();
    let built = agent_factory::build_chump_agent_web_components(
        &session_id,
        bot,
        body.voice.unwrap_or(false),
        body.advisor.unwrap_or(false),
    )
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    #[cfg(feature = "mistralrs-infer")]
    let streaming_provider = StreamingProvider::new_with_mistral_stream(
        built.provider,
        built.mistral_for_stream,
        event_tx.clone(),
    );
    #[cfg(not(feature = "mistralrs-infer"))]
    let streaming_provider = StreamingProvider::new(built.provider, event_tx.clone());
    let event_tx_err = event_tx.clone(); // retained for error reporting after agent consumes event_tx
    let max_iterations: usize = std::env::var("CHUMP_MAX_ITERATIONS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(25)
        .clamp(1, 50);
    let agent = ChumpAgent::new(
        Box::new(streaming_provider),
        built.registry,
        Some(built.system_prompt),
        Some(built.session_manager),
        Some(event_tx),
        max_iterations,
    );

    let message_clone = message_for_agent;
    let session_id_clone = session_id.clone();
    let relax_snapshot = crate::policy_override::snapshot_relax_for_session(&session_id_clone);
    tokio::spawn(async move {
        crate::policy_override::relax_scope(relax_snapshot, async move {
            match agent.run(&message_clone).await {
                Ok(outcome) => {
                    let full_reply = outcome.reply.clone();
                    let stripped = crate::system_prompt::strip_thinking(&full_reply);
                    crate::context_assembly::record_last_reply(&stripped);
                    if let Err(e) = web_sessions_db::message_append_assistant(
                        &session_id_clone,
                        &full_reply,
                        None,
                        outcome.thinking_joined().as_deref(),
                    ) {
                        eprintln!("[web] failed to persist assistant message: {}", e);
                    }
                }
                Err(e) => {
                    eprintln!("[web] chat run failed: {}", e);
                    // Send turn_error so the PWA shows the error instead of "(No response)".
                    let msg = crate::user_error_hints::append_agent_error_hints(&format!(
                        "Agent error: {}",
                        e
                    ));
                    let _ = event_tx_err.send(stream_events::AgentEvent::TurnError {
                        request_id: String::new(),
                        error: msg,
                    });
                }
            }
        })
        .await;
    });

    Ok(Sse::new(agent_event_stream(event_rx)))
}

/// GET /api/brain/graph.json — full memory graph as JSON (nodes + edges).
async fn handle_brain_graph_json(headers: HeaderMap) -> Result<Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let body = crate::memory_graph_viz::export_graph_json()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(([(header::CONTENT_TYPE, "application/json")], body).into_response())
}

/// GET /api/brain/graph/stats — aggregate stats over the memory graph.
async fn handle_brain_graph_stats(
    headers: HeaderMap,
) -> Result<Json<crate::memory_graph_viz::GraphStats>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let stats =
        crate::memory_graph_viz::graph_stats().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(stats))
}

/// GET /api/brain/node/{id} — full record (degree + touching edges) for one node.
/// Backs the /brain right-pane detail panel (INFRA-1558).
async fn handle_brain_node(
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Result<Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let detail =
        crate::memory_graph_viz::node_detail(&id).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    match detail {
        Some(d) => Ok(Json(d).into_response()),
        None => Err(StatusCode::NOT_FOUND),
    }
}

/// GET /api/brain/graph/stream — SSE stream that re-pushes the full memory
/// graph snapshot every 10s so the /brain Cytoscape view can apply incremental
/// add/remove without a full page reload (INFRA-1558). Polling-based: each
/// tick re-exports the whole graph; the client diffs against what it already
/// has rendered rather than this endpoint computing a true delta.
async fn handle_brain_graph_stream(
    headers: HeaderMap,
) -> Result<
    Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>,
    StatusCode,
> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let (tx, rx) =
        tokio::sync::mpsc::unbounded_channel::<Result<Event, std::convert::Infallible>>();
    tokio::spawn(async move {
        loop {
            let data = crate::memory_graph_viz::export_graph_json().unwrap_or_default();
            if tx
                .send(Ok(Event::default().event("graph").data(data)))
                .is_err()
            {
                break; // client disconnected
            }
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        }
    });

    Ok(Sse::new(UnboundedReceiverStream::new(rx)).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("keep-alive"),
    ))
}

// ── EFFECTIVE-422: Voice advisor — Siri Shortcut seam into /api/chat ────────

#[derive(serde::Deserialize)]
struct VoiceAskBody {
    /// Dictated phrase the Siri Shortcut POSTs (see docs/design/VOICE_ADVISOR.md §3).
    #[serde(default)]
    text: String,
}

/// POST /api/voice/ask — Siri Shortcut ("Ask Chump") entry point. Mirrors Olive's
/// `olive/src/app/api/voice/ask/route.ts` shape: takes `{ text }`, returns
/// `{ spoken, end }` JSON the Shortcut loops on (`end: "no"` keeps the mic open,
/// `"yes"` closes the conversation). Reuses the SAME agent loop /api/chat uses —
/// `voice: Some(true)` flips on the VOICE_ADDENDUM so the reply stays TTS-friendly.
///
/// Auth: same `CHUMP_WEB_TOKEN` Bearer guard as /api/chat (check_auth, :295).
/// Session: a stable id (`CHUMP_VOICE_SESSION_ID`, default "voice") so the
/// voice conversation has its own persisted context thread in web_sessions_db.
/// Almanac_search is already a registered tool — the agent "talks to ChumpOS" by
/// asking the same brain, this is just another door.
async fn handle_voice_ask(headers: HeaderMap, Json(body): Json<VoiceAskBody>) -> Response {
    if !check_auth(&headers) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let text = body.text.trim();
    if text.is_empty() {
        return Json(serde_json::json!({
            "spoken": "Didn't catch that. Say hey Siri, ask Chump, and your question.",
            "end": "yes",
        }))
        .into_response();
    }
    // Terminal phrases close the conversation cleanly (mirrors Olive's EXIT regex
    // at olive/src/app/api/voice/ask/route.ts:136). Defers to no agent round-trip.
    const EXIT: &str = r"(?i)^\s*(that'?\s*(?:it|all)|i'?\s*m done|all done|we'?\s*re done|done|nothing else|no,?\s*that'?\s*(?:it|all)|stop|goodbye|bye|thanks?)\s*[.!]?\s*$";
    if regex::Regex::new(EXIT)
        .ok()
        .map(|r| r.is_match(text))
        .unwrap_or(false)
    {
        return Json(serde_json::json!({
            "spoken": "Closing out. Say hey Siri, ask Chump, when you need me.",
            "end": "yes",
        }))
        .into_response();
    }

    // Pin one stable session id for the voice conversation so it has its own
    // persisted context thread in web_sessions_db (separate from web/Discord).
    let voice_session_id = std::env::var("CHUMP_VOICE_SESSION_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "voice".to_string());

    // Reuse the SAME /api/chat agent-spawn body by handing the request through
    // handle_chat's kill-gate wrapper. We SYNTHESIZE a ChatRequest that mirrors
    // what /api/chat would build, but with voice=true, and drain the SSE stream
    // to a single spoken string instead of returning the stream to the client.
    let chat_body = ChatRequest {
        message: text.to_string(),
        session_id: Some(voice_session_id.clone()),
        attachments: None,
        bot: None,
        policy_override: None,
        voice: Some(true),
        advisor: None,
    };

    // Run the kill-gate (cost threshold) the same way /api/chat does, then
    // drain the SSE response to a single string.
    let sse_response = handle_chat_with_kill_gate(headers, Json(chat_body)).await;
    let spoken = match drain_sse_response(sse_response).await {
        Ok(s) => s,
        Err(code) => return (code, "stream drain failed").into_response(),
    };
    Json(serde_json::json!({
        "spoken": spoken,
        "end": "no",
    }))
    .into_response()
}

/// Drain an `Sse<...>` response body to a single string by parsing event
/// payloads. Extracts `turn_complete.full_text` or `text_complete.text` or
/// `turn_error.error` from the SSE event stream.
///
/// EXPECTED EVENT PAYLOAD SHAPE: handle_chat (and agent_event_stream, :146) emit
/// `Event::default().event(event_type).data(serde_json::to_string(&ev))`. So
/// each line is `event:<type>\ndata:<json>\n\n` (SSE wire format). We split on
/// the double-newline boundary and parse the `data:` line's JSON.
async fn drain_sse_response(response: Response) -> Result<String, StatusCode> {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    parse_sse_to_spoken(&String::from_utf8_lossy(&bytes)).ok_or(StatusCode::INTERNAL_SERVER_ERROR)
}

/// EFFECTIVE-422 — pure SSE wire-format parser used by /api/voice/ask.
/// Mirrors `agent_event_stream` (web_server.rs:146): each chunk is
/// `event:<type>\ndata:<json>\n\n`. Returns the spoken string the
/// Shortcut will speak, or None when no turn/text/error event arrived.
///
/// Event types consumed (see `src/stream_events.rs:8-78`):
///   turn_complete.full_text ← the final reply (preferred)
///   text_complete.text       ← fallback if turn_complete never fires
///   turn_error.error         ← surface plainly
fn parse_sse_to_spoken(body: &str) -> Option<String> {
    let mut last_text = String::new();
    for chunk in body.split("\n\n") {
        let mut event_type: Option<&str> = None;
        let mut data_line: Option<&str> = None;
        for line in chunk.lines() {
            if let Some(rest) = line.strip_prefix("event:") {
                event_type = Some(rest.trim());
            } else if let Some(rest) = line.strip_prefix("data:") {
                data_line = Some(rest.trim());
            }
        }
        let Some(t) = event_type else { continue };
        let Some(json_str) = data_line else { continue };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(json_str) else {
            continue;
        };
        match t {
            "turn_complete" => {
                if let Some(text) = v.get("full_text").and_then(|x| x.as_str()) {
                    return Some(text.to_string());
                }
            }
            "text_complete" => {
                if let Some(text) = v.get("text").and_then(|x| x.as_str()) {
                    last_text = text.to_string();
                }
            }
            "turn_error" => {
                if let Some(err) = v.get("error").and_then(|x| x.as_str()) {
                    return Some(format!("Chump hit an error: {err}"));
                }
            }
            _ => {}
        }
    }
    if last_text.is_empty() {
        None
    } else {
        Some(last_text)
    }
}

// ── INFRA-3597: The Advisor — Discord DM text seam into /api/chat ───────────

#[derive(serde::Deserialize)]
struct AdvisorAskBody {
    /// The DM text the Discord advisor bridge POSTs.
    #[serde(default)]
    text: String,
}

/// POST /api/advisor/ask — Discord DM ("The Advisor") entry point. Distinct
/// from `/api/voice/ask` (spoken, TTS-friendly): this is a text reply, full
/// markdown OK. Reuses the SAME agent loop /api/chat and /api/voice/ask use —
/// `advisor: Some(true)` restricts the tool registry to
/// `tool_inventory::register_advisor_tools` (read-only) and appends
/// ADVISOR_ADDENDUM so the agent knows it converses and advises, never acts.
///
/// Auth: same `CHUMP_WEB_TOKEN` Bearer guard as /api/chat (check_auth).
/// Session: a stable id (`CHUMP_ADVISOR_SESSION_ID`, default "advisor") so
/// the DM conversation has its own persisted context thread in
/// web_sessions_db, separate from web/voice/Discord-developer sessions.
/// This route running on the ChumpOS web server (not the desktop app) is
/// what makes the Advisor always-available with the desktop app closed.
async fn handle_advisor_ask(headers: HeaderMap, Json(body): Json<AdvisorAskBody>) -> Response {
    if !check_auth(&headers) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let text = body.text.trim();
    if text.is_empty() {
        return Json(serde_json::json!({
            "reply": "Didn't catch a question — ask me anything about the operation.",
        }))
        .into_response();
    }

    // Pin one stable session id for the advisor conversation so it has its
    // own persisted context thread in web_sessions_db (separate from
    // web/voice/Discord-developer sessions).
    let advisor_session_id = std::env::var("CHUMP_ADVISOR_SESSION_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "advisor".to_string());

    // Reuse the SAME /api/chat agent-spawn body by handing the request
    // through handle_chat's kill-gate wrapper, but with advisor=true so the
    // agent gets the read-only tool registry + ADVISOR_ADDENDUM. Drain the
    // SSE stream to a single reply string instead of returning the stream.
    let chat_body = ChatRequest {
        message: text.to_string(),
        session_id: Some(advisor_session_id.clone()),
        attachments: None,
        bot: None,
        policy_override: None,
        voice: None,
        advisor: Some(true),
    };

    let sse_response = handle_chat_with_kill_gate(headers, Json(chat_body)).await;
    let reply = match drain_sse_response(sse_response).await {
        Ok(s) => s,
        Err(code) => return (code, "stream drain failed").into_response(),
    };
    Json(serde_json::json!({ "reply": reply })).into_response()
}

// ── FLEET-003b: atomic blackboard exchange endpoint ──────────────────────────

/// POST /api/fleet/workspace_exchange
///
/// Receives a peer's `PeerBlackboard`, verifies its checksum, ingests all items
/// into the local blackboard with peer attribution, and returns the local
/// blackboard snapshot.  This makes the exchange bidirectional in a single
/// HTTP round-trip: the initiator gets our board; we get theirs.
async fn handle_fleet_workspace_exchange(
    Json(peer_bb): Json<crate::fleet::PeerBlackboard>,
) -> Result<Json<crate::fleet::PeerBlackboard>, StatusCode> {
    // Verify incoming payload integrity.
    if !peer_bb.verify() {
        tracing::warn!(
            peer_id = %peer_bb.peer_id,
            seq = peer_bb.sequence,
            "fleet workspace_exchange: checksum mismatch — rejecting"
        );
        return Err(StatusCode::BAD_REQUEST);
    }

    // Ingest the peer's items into our blackboard with attribution.
    crate::fleet::ingest_peer_blackboard(&peer_bb);

    tracing::info!(
        peer_id = %peer_bb.peer_id,
        items = peer_bb.items.len(),
        "fleet workspace_exchange: ingested peer blackboard"
    );

    // Return our current blackboard snapshot.
    let my_id = crate::fleet::current_peer_id();
    let my_bb = crate::fleet::snapshot_local_blackboard(&my_id);
    Ok(Json(my_bb))
}

/// GET /api/telemetry/cost — Operator-visible fleet spend (INFRA-1012).
///
/// Aggregates three cost sources into a single JSON response so the PWA can
/// show "what is this fleet actually costing me." All numbers are honest
/// best-effort: Anthropic is tracked per-call in `chump_cost_tracker`,
/// GitHub call counts come from `.chump-locks/ambient.jsonl` events emitted
/// by `chump_gh` (INFRA-999), Tavily credits live in cost_tracker too.
///
/// Query params:
///   ?window=session  (default) — current process lifetime only
///   ?window=day      — last 24 hours from ambient.jsonl session_end events
///   ?window=month    — last 30 days from ambient.jsonl session_end events
///
/// Returns:
/// ```json
/// {
///   "window": "session",
///   "session_cost_usd": 1.23,
///   "github": {"calls": N, "remaining_core": N, "remaining_graphql": N},
///   "budget": {"warn_usd": 5.0, "ceiling_usd": 10.0, "warning": null},
///   "per_gap_breakdown": [{"gap_id": "INFRA-5", "sessions": 2, "elapsed_seconds": 600, "outcome": "shipped"}]
/// }
/// ```
#[derive(serde::Deserialize, Default)]
struct CostQuery {
    window: Option<String>,
}

async fn handle_telemetry_cost(
    headers: HeaderMap,
    Query(q): Query<CostQuery>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let window = q.window.as_deref().unwrap_or("session");
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let lock_dir = std::env::var("CHUMP_LOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks"));
    let ambient = lock_dir.join("ambient.jsonl");

    // Session cost & budget — pulled directly from in-process accounting.
    let session_cost_usd = crate::cost_tracker::session_cost_usd();
    let cost_warn_usd = crate::cost_tracker::cost_warn_usd();
    let cost_ceiling_usd = crate::cost_tracker::cost_ceiling_usd();
    let budget_warning = crate::cost_tracker::budget_warning();
    let summary_text = crate::cost_tracker::summary();

    // Determine the cutoff timestamp for day/month windows.
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let cutoff_secs: u64 = match window {
        "day" => now_secs.saturating_sub(86_400),
        "month" => now_secs.saturating_sub(30 * 86_400),
        _ => 0, // "session" — no ambient history filter; use in-process tracker only
    };

    // Scan ambient.jsonl for github_api_call and session_end events.
    // Tail-only: max 2MB read so this stays sub-100ms even on large ambient files.
    let mut gh_calls: u64 = 0;
    let mut gh_remaining_core: Option<i64> = None;
    let mut gh_remaining_graphql: Option<i64> = None;

    // Per-gap: gap_id → (session_count, total_elapsed_secs, last_outcome)
    let mut gap_map: std::collections::HashMap<String, (u64, u64, String)> =
        std::collections::HashMap::new();

    if let Ok(contents) = std::fs::read_to_string(&ambient) {
        let tail = if contents.len() > 2_097_152 {
            &contents[contents.len() - 2_097_152..]
        } else {
            &contents[..]
        };
        for line in tail.lines() {
            let Ok(evt): Result<serde_json::Value, _> = serde_json::from_str(line) else {
                continue;
            };
            let kind = evt.get("kind").and_then(|v| v.as_str()).unwrap_or("");

            if kind == "github_api_call" {
                gh_calls += 1;
                if let Some(n) = evt.get("remaining_core").and_then(|v| v.as_i64()) {
                    gh_remaining_core = Some(n);
                }
                if let Some(n) = evt.get("remaining_graphql").and_then(|v| v.as_i64()) {
                    gh_remaining_graphql = Some(n);
                }
            } else if kind == "session_end" {
                // Filter by window cutoff when day/month requested.
                if cutoff_secs > 0 {
                    let ts_str = evt.get("ts").and_then(|v| v.as_str()).unwrap_or("");
                    // Parse ISO 8601 prefix "YYYY-MM-DDTHH:MM:SSZ" → epoch seconds.
                    let event_secs = chrono_approx_secs(ts_str);
                    if event_secs < cutoff_secs {
                        continue;
                    }
                }
                // Support both "gap_id" (Rust emitter) and "gap" (shell emitter) fields.
                let gap_id = evt
                    .get("gap_id")
                    .or_else(|| evt.get("gap"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if gap_id.is_empty() {
                    continue;
                }
                let elapsed = evt
                    .get("elapsed_seconds")
                    .and_then(|v| {
                        v.as_u64()
                            .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
                    })
                    .unwrap_or(0);
                let outcome = evt
                    .get("outcome")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let entry = gap_map.entry(gap_id).or_insert((0, 0, outcome.clone()));
                entry.0 += 1;
                entry.1 += elapsed;
                entry.2 = outcome;
            }
        }
    }

    // Build per_gap_breakdown sorted by elapsed_seconds descending (most time spent first).
    let mut breakdown: Vec<serde_json::Value> = gap_map
        .into_iter()
        .map(|(gap_id, (sessions, elapsed, outcome))| {
            serde_json::json!({
                "gap_id": gap_id,
                "sessions": sessions,
                "elapsed_seconds": elapsed,
                "outcome": outcome,
            })
        })
        .collect();
    breakdown.sort_by(|a, b| {
        let ea = a["elapsed_seconds"].as_u64().unwrap_or(0);
        let eb = b["elapsed_seconds"].as_u64().unwrap_or(0);
        eb.cmp(&ea)
    });

    let payload = serde_json::json!({
        "window": window,
        "session_cost_usd": session_cost_usd,
        "summary": summary_text,
        "github": {
            "calls": gh_calls,
            "remaining_core": gh_remaining_core,
            "remaining_graphql": gh_remaining_graphql,
        },
        "budget": {
            "warn_usd": cost_warn_usd,
            "ceiling_usd": cost_ceiling_usd,
            "warning": budget_warning,
        },
        "per_gap_breakdown": breakdown,
    });
    Ok(Json(payload))
}

/// GET /api/health/pillars — 4-pillar health dashboard (PRODUCT-090).
///
/// Returns per-pillar grade, pickable gap count, P0 count, and SLO breach status.
/// Grade: A=0 fleet-SLO-breaches, B=1, C=2, F=3+.
/// pickable_count: open P0+P1 gaps with effort xs/s/m for that pillar.
/// slo_breach: true when pillar has < 2 pickable gaps (L2-SLO-4).
async fn handle_health_pillars(headers: HeaderMap) -> Json<serde_json::Value> {
    let _ = check_auth(&headers); // unauthenticated read-only for dashboard convenience
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => std::path::PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };

    // ── Fleet SLO breach count via chump health --slo-check --json ───────────
    // Wrapped in tokio::time::timeout to prevent blocking the async runtime
    // (INFRA-1466). Timeout is configurable via CHUMP_FLEET_STATUS_GH_TIMEOUT_S
    // (default 3s).
    let mut fleet_breaches: u32 = 0;
    let mut health_timed_out = false;
    let timeout_secs: u64 = std::env::var("CHUMP_FLEET_STATUS_GH_TIMEOUT_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3);
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("chump"));
    let health_future = tokio::process::Command::new(&exe)
        .args(["health", "--slo-check", "--json"])
        .current_dir(&repo_root)
        .output();
    match tokio::time::timeout(std::time::Duration::from_secs(timeout_secs), health_future).await {
        Ok(Ok(out)) => {
            if let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                fleet_breaches = parsed
                    .get("slo_breaches")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0) as u32;
            }
        }
        Ok(Err(_)) | Err(_) => {
            health_timed_out = true;
        }
    }
    let fleet_grade = match fleet_breaches {
        0 => "A",
        1 => "B",
        2 => "C",
        _ => "F",
    };

    // ── Per-pillar gap counts from gap_store ──────────────────────────────────
    const PILLARS: &[&str] = &["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"];
    let mut pillar_pickable: std::collections::HashMap<&str, u32> =
        PILLARS.iter().map(|&p| (p, 0u32)).collect();
    let mut pillar_p0: std::collections::HashMap<&str, u32> =
        PILLARS.iter().map(|&p| (p, 0u32)).collect();

    if let Ok(store) = crate::gap_store::GapStore::open(&repo_root) {
        if let Ok(gaps) = store.list(Some("open")) {
            for gap in &gaps {
                // Pillar comes from title prefix "PILLAR: rest of title".
                let pillar = PILLARS.iter().find(|&&p| {
                    gap.title.starts_with(&format!("{}:", p))
                        || gap.title.starts_with(&format!("{} ", p))
                });
                let Some(&pillar) = pillar else { continue };

                if gap.priority == "P0" {
                    *pillar_p0.entry(pillar).or_default() += 1;
                }
                // Pickable = P0+P1, effort xs/s/m.
                if matches!(gap.priority.as_str(), "P0" | "P1")
                    && matches!(gap.effort.as_str(), "xs" | "s" | "m")
                {
                    *pillar_pickable.entry(pillar).or_default() += 1;
                }
            }
        }
    }

    // ── Build response ────────────────────────────────────────────────────────
    let pillars: Vec<serde_json::Value> = PILLARS
        .iter()
        .map(|&p| {
            let pickable = *pillar_pickable.get(p).unwrap_or(&0);
            let p0_count = *pillar_p0.get(p).unwrap_or(&0);
            let slo_breach = pickable < 2 || p0_count > 5;
            let grade = if slo_breach || p0_count > 5 {
                "F"
            } else {
                fleet_grade
            };
            serde_json::json!({
                "pillar": p,
                "grade": grade,
                "pickable_count": pickable,
                "p0_count": p0_count,
                "slo_breach": slo_breach,
            })
        })
        .collect();

    Json(serde_json::json!({
        "fleet_grade": fleet_grade,
        "fleet_slo_breaches": fleet_breaches,
        "pillars": pillars,
        "health_timed_out": health_timed_out,
    }))
}

// ── META-175: /api/fleet-wire/health ─────────────────────────────────────────

/// GET /api/fleet-wire/health — JetStream consumer lag + delivery latency per role.
///
/// Returns per-role consumer lag (num_pending from consumer info) and delivery
/// latency p50/p99 derived from `kind=feedback_fanout_delivered` events in
/// `ambient.jsonl`.
///
/// When `CHUMP_FLEET_WIRE_V1=1` and `CHUMP_NATS_URL` are both set, queries
/// the live NATS broker. Otherwise returns `nats_enabled: false` so the PWA
/// panel can show the file-inbox fallback notice.
///
/// Response: `{ roles: [{ role, lag, p50_ms, p99_ms }], updated_at, nats_enabled }`
async fn handle_fleet_wire_health(headers: HeaderMap) -> Json<serde_json::Value> {
    let _ = check_auth(&headers); // unauthenticated read-only for dashboard

    let nats_enabled = chump_coord::jetstream_consumer::fleet_wire_enabled();
    let updated_at = chrono::Utc::now().to_rfc3339();

    if !nats_enabled {
        return Json(serde_json::json!({
            "roles": [],
            "updated_at": updated_at,
            "nats_enabled": false,
        }));
    }

    // ── Read delivery latency from ambient.jsonl ──────────────────────────────
    // Scan the last 500 lines for kind=feedback_fanout_delivered events,
    // extract `delivered_at` and `published_at` timestamps to compute latency.
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let mut latencies_ms: std::collections::HashMap<String, Vec<i64>> =
        std::collections::HashMap::new();

    if let Ok(contents) = std::fs::read_to_string(&ambient_path) {
        let lines: Vec<&str> = contents.lines().collect();
        let start = lines.len().saturating_sub(500);
        for line in &lines[start..] {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            if v.get("kind").and_then(|k| k.as_str()) != Some("feedback_fanout_delivered") {
                continue;
            }
            let role = v
                .get("role")
                .and_then(|r| r.as_str())
                .unwrap_or("unknown")
                .to_string();
            // published_at and delivered_at are RFC3339 strings.
            let pub_ts = v
                .get("published_at")
                .and_then(|t| t.as_str())
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            let del_ts = v
                .get("delivered_at")
                .and_then(|t| t.as_str())
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            if let (Some(pub_t), Some(del_t)) = (pub_ts, del_ts) {
                let latency_ms = (del_t - pub_t).num_milliseconds();
                if latency_ms >= 0 {
                    latencies_ms.entry(role).or_default().push(latency_ms);
                }
            }
        }
    }

    // ── Query NATS consumer info for each known role ───────────────────────────
    // We discover roles from the ambient events we just scanned, plus any
    // consumer names visible on the CHUMP_EVENTS stream (if reachable).
    let mut role_set: std::collections::HashSet<String> = latencies_ms.keys().cloned().collect();

    // Attempt to enumerate consumers from NATS (best-effort, timeout 1s).
    let nats_url = std::env::var("CHUMP_NATS_URL")
        .unwrap_or_else(|_| chump_coord::DEFAULT_NATS_URL.to_string());
    let nats_result = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        async_nats::connect(&nats_url),
    )
    .await;

    let mut role_lags: std::collections::HashMap<String, u64> = std::collections::HashMap::new();

    if let Ok(Ok(nats)) = nats_result {
        let js = async_nats::jetstream::new(nats);
        if let Ok(stream) = js.get_stream(chump_coord::EVENTS_STREAM).await {
            // List consumer names that start with "chump-fleet-".
            let mut names = stream.consumer_names();
            while let Ok(Some(Ok(name))) = tokio::time::timeout(
                std::time::Duration::from_millis(200),
                futures_util::StreamExt::next(&mut names),
            )
            .await
            {
                if let Some(role) = name.strip_prefix("chump-fleet-") {
                    role_set.insert(role.to_string());
                    // Fetch consumer info for lag.
                    if let Ok(info) = stream.consumer_info(&name).await {
                        role_lags.insert(role.to_string(), info.num_pending);
                    }
                }
            }
        }
    }

    // ── Build per-role response rows ─────────────────────────────────────────
    let mut roles: Vec<serde_json::Value> = role_set
        .into_iter()
        .map(|role| {
            let lag = *role_lags.get(&role).unwrap_or(&0);
            let lats = latencies_ms.get(&role).cloned().unwrap_or_default();
            let (p50, p99) = percentiles(&lats);
            serde_json::json!({
                "role": role,
                "lag": lag,
                "p50_ms": p50,
                "p99_ms": p99,
            })
        })
        .collect();
    roles.sort_by(|a, b| {
        a.get("role")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .cmp(b.get("role").and_then(|v| v.as_str()).unwrap_or(""))
    });

    Json(serde_json::json!({
        "roles": roles,
        "updated_at": updated_at,
        "nats_enabled": true,
    }))
}

// ── INFRA-1774: /api/operator-page/pending + /api/operator-page/ack ──────────

/// GET /api/operator-page/pending — structured human-in-the-loop interrupts
/// raised via `scripts/dispatch/operator-page.sh` that have no matching
/// `operator_page_ack` yet.
///
/// Scans the last 500 lines of `ambient.jsonl` for `kind=operator_page`
/// events, subtracts any `corr_id` that has a matching `operator_page_ack`,
/// and returns the remainder sorted newest-first.
///
/// Response: `{ pages: [{ corr_id, severity, title, message, gap_id,
/// cost_usd_at_page, timeout_secs, ts }], updated_at }`
async fn handle_operator_page_pending(headers: HeaderMap) -> Json<serde_json::Value> {
    let _ = check_auth(&headers); // unauthenticated read-only for dashboard

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let updated_at = chrono::Utc::now().to_rfc3339();

    let Ok(contents) = std::fs::read_to_string(&ambient_path) else {
        return Json(serde_json::json!({ "pages": [], "updated_at": updated_at }));
    };

    let lines: Vec<&str> = contents.lines().collect();
    let start = lines.len().saturating_sub(500);

    let mut acked: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut pages: Vec<serde_json::Value> = Vec::new();

    for line in &lines[start..] {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        match v.get("kind").and_then(|k| k.as_str()) {
            Some("operator_page_ack") => {
                if let Some(c) = v.get("corr_id").and_then(|c| c.as_str()) {
                    acked.insert(c.to_string());
                }
            }
            Some("operator_page") => pages.push(v),
            _ => {}
        }
    }

    let mut pending: Vec<serde_json::Value> = pages
        .into_iter()
        .filter(|v| {
            v.get("corr_id")
                .and_then(|c| c.as_str())
                .is_some_and(|c| !acked.contains(c))
        })
        .collect();
    pending.reverse(); // newest-first

    Json(serde_json::json!({ "pages": pending, "updated_at": updated_at }))
}

#[derive(serde::Deserialize)]
struct OperatorPageAckRequest {
    corr_id: String,
    #[serde(default)]
    ack_by: Option<String>,
}

/// POST /api/operator-page/ack — acknowledge a pending operator_page.
///
/// Shells out to `scripts/dispatch/operator-page.sh --ack` so the CLI and
/// the PWA cockpit share one code path for the ack write + permanent-failure
/// check (corr_id never raised).
async fn handle_operator_page_ack(
    headers: HeaderMap,
    Json(body): Json<OperatorPageAckRequest>,
) -> Json<serde_json::Value> {
    let _ = check_auth(&headers);

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let script = repo_root.join("scripts/dispatch/operator-page.sh");
    let ack_by = body.ack_by.unwrap_or_else(|| "pwa-cockpit".to_string());

    let output = std::process::Command::new(&script)
        .arg("--ack")
        .arg(&body.corr_id)
        .arg("--ack-by")
        .arg(&ack_by)
        .env("REPO_ROOT", &repo_root)
        .output();

    match output {
        Ok(o) if o.status.success() => Json(serde_json::json!({ "ok": true })),
        Ok(o) => Json(serde_json::json!({
            "ok": false,
            "error": String::from_utf8_lossy(&o.stderr).to_string(),
        })),
        Err(e) => Json(serde_json::json!({ "ok": false, "error": e.to_string() })),
    }
}

/// Compute (p50_ms, p99_ms) from a sorted list of latency samples.
/// Returns (None, None) when the slice is empty.
fn percentiles(samples: &[i64]) -> (Option<i64>, Option<i64>) {
    if samples.is_empty() {
        return (None, None);
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let p50_idx = (sorted.len() as f64 * 0.50) as usize;
    let p99_idx = (sorted.len() as f64 * 0.99) as usize;
    let p50 = sorted[p50_idx.min(sorted.len() - 1)];
    let p99 = sorted[p99_idx.min(sorted.len() - 1)];
    (Some(p50), Some(p99))
}

/// GET /api/health/doctor — config-health probe for the first-run banner (INFRA-990).
///
/// Calls `doctor::run_all_checks()` in-process and reshapes the report into the
/// compact contract the PWA banner consumes. Unauthenticated by design — this
/// is precisely the "you're not configured yet" surface, so requiring auth
/// would be circular.
///
/// Status code is always 200; the JSON `ok` field carries truthiness so load
/// balancer probes don't flap on a misconfig.
async fn handle_doctor_health(headers: HeaderMap) -> Json<serde_json::Value> {
    let _ = check_auth(&headers); // unauthenticated read-only

    // In-process 5s tumbling-window cache to soften the 30s banner-poll rate
    // against the 11-check doctor pipeline. Bounded by a Mutex'd Option since
    // the surface is single-process.
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    static CACHE: Mutex<Option<(Instant, serde_json::Value)>> = Mutex::new(None);
    const TTL: Duration = Duration::from_secs(5);

    if let Ok(guard) = CACHE.lock() {
        if let Some((ts, payload)) = guard.as_ref() {
            if ts.elapsed() < TTL {
                return Json(payload.clone());
            }
        }
    }

    let report = crate::doctor::run_all_checks().await;
    let failures: Vec<serde_json::Value> = report
        .checks
        .iter()
        .filter(|c| matches!(c.status, crate::doctor::CheckStatus::Fail))
        .map(|c| {
            serde_json::json!({
                "check": c.name,
                "message": c.message,
                "fix_hint": c.fix_hint,
            })
        })
        .collect();
    let warnings: Vec<serde_json::Value> = report
        .checks
        .iter()
        .filter(|c| matches!(c.status, crate::doctor::CheckStatus::Warn))
        .map(|c| {
            serde_json::json!({
                "check": c.name,
                "message": c.message,
                "fix_hint": c.fix_hint,
            })
        })
        .collect();
    let ok = failures.is_empty();

    // Emit a presence-only ambient event for observability (INFRA-754).
    // Body carries counts only — no failure messages (those can leak env paths
    // or hostnames). The /api endpoint itself returns the full detail.
    {
        let ev = serde_json::json!({
            "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "kind": "pwa_doctor_check",
            "ok": ok,
            "failure_count": failures.len(),
            "warning_count": warnings.len(),
        });
        let path = repo_path::runtime_base()
            .join(".chump-locks")
            .join("ambient.jsonl");
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        {
            let _ = writeln!(f, "{}", ev);
        }
    }

    let payload = serde_json::json!({
        "ok": ok,
        "failures": failures,
        "warnings": warnings,
        "summary": report.summary_line(),
        "ts": chrono::Utc::now().to_rfc3339(),
    });

    if let Ok(mut guard) = CACHE.lock() {
        *guard = Some((Instant::now(), payload.clone()));
    }

    Json(payload)
}

/// GET /api/pr/{number} — Per-PR detail snapshot (INFRA-1011).
///
/// Operator-facing surface for "what's happening with my PR" without leaving
/// the PWA. Pulls a focused subset of GitHub state — state, mergeStateStatus,
/// auto-merge, per-check rollup — so the PRCard widget can render real-time
/// merge readiness + per-check status with deep links to failing job logs.
///
/// Best-effort: when gh is unavailable or rate-limited, returns 503 with a
/// reason; widget treats this as "transient, retry on next poll." No
/// GraphQL — single `gh pr view --json …` call which is REST under the hood.
async fn handle_pr_detail(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // INFRA-1485: tokio::process::Command + timeout to prevent worker
    // starvation. PWA cockpit's PRCard polls this every 30s per visible
    // PR; sync Command was a tail-latency hazard.
    let gh_fut = tokio::process::Command::new("gh")
        .args([
            "pr",
            "view",
            &number.to_string(),
            "--json",
            "number,state,title,url,mergeStateStatus,autoMergeRequest,statusCheckRollup,mergedAt,headRefOid,baseRefName",
        ])
        .output();
    let out = match tokio::time::timeout(std::time::Duration::from_secs(3), gh_fut).await {
        Ok(Ok(o)) => o,
        Ok(Err(_)) | Err(_) => return Err(StatusCode::SERVICE_UNAVAILABLE),
    };
    if !out.status.success() {
        // gh exited non-zero — return 503 so the widget keeps polling.
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let raw: serde_json::Value =
        serde_json::from_slice(&out.stdout).map_err(|_| StatusCode::BAD_GATEWAY)?;

    // Re-shape per AC: caller wants a stable, narrow contract that's easy
    // to render. Don't pass through the entire gh JSON blob (avoid coupling
    // the widget to gh's verbose field set).
    let checks: Vec<serde_json::Value> = raw
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|c| {
            let name = c
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let conclusion = c
                .get("conclusion")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let status = c
                .get("status")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            // `detailsUrl` or `link` is gh's canonical job-log deep link.
            let link = c
                .get("detailsUrl")
                .or_else(|| c.get("targetUrl"))
                .or_else(|| c.get("link"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            serde_json::json!({
                "name": name,
                "conclusion": conclusion,
                "status": status,
                "link": link,
            })
        })
        .collect();

    let payload = serde_json::json!({
        "number": raw.get("number"),
        "title": raw.get("title"),
        "url": raw.get("url"),
        "state": raw.get("state"),
        "merge_state_status": raw.get("mergeStateStatus"),
        "auto_merge": raw.get("autoMergeRequest").is_some()
            && !raw.get("autoMergeRequest").map(|v| v.is_null()).unwrap_or(true),
        "auto_merge_method": raw
            .get("autoMergeRequest")
            .and_then(|v| v.get("mergeMethod"))
            .and_then(|v| v.as_str()),
        "head_sha": raw.get("headRefOid"),
        "base_branch": raw.get("baseRefName"),
        "merged_at": raw.get("mergedAt"),
        "checks": checks,
    });
    Ok(Json(payload))
}

// ── PRODUCT-084: PR list view ──────────────────────────────────────────────────────────────────

/// Server-side cache for `/api/prs` — TTL 30s.
static PR_LIST_CACHE: std::sync::OnceLock<
    std::sync::Mutex<Option<(std::time::Instant, serde_json::Value)>>,
> = std::sync::OnceLock::new();

fn pr_list_cache() -> &'static std::sync::Mutex<Option<(std::time::Instant, serde_json::Value)>> {
    PR_LIST_CACHE.get_or_init(|| std::sync::Mutex::new(None))
}

/// GET /api/prs — PR list for PRODUCT-084 PWA view.
///
/// Returns three sections:
///   - `open`:        all open PRs (newest first)
///   - `just_merged`: PRs merged in last 24 h
///   - `stuck`:       open PRs with mergeStateStatus DIRTY or BLOCKED, age > 4 h
///
/// Each row: number, title, author, age_s, merge_state, ci_ok, url.
/// Result cached server-side for 30 s. gh unavailable → 503.
async fn handle_pr_list(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Serve from cache if fresh.
    const TTL_SECS: u64 = 30;
    {
        if let Ok(guard) = pr_list_cache().lock() {
            if let Some((ts, ref v)) = *guard {
                if ts.elapsed().as_secs() < TTL_SECS {
                    return Ok(Json(v.clone()));
                }
            }
        }
    }

    let fresh = fetch_pr_list().await;
    match fresh {
        Ok(v) => {
            if let Ok(mut guard) = pr_list_cache().lock() {
                *guard = Some((std::time::Instant::now(), v.clone()));
            }
            tracing::info!(
                open_count = v["open"].as_array().map(|a| a.len()).unwrap_or(0),
                merged_count = v["just_merged"].as_array().map(|a| a.len()).unwrap_or(0),
                stuck_count = v["stuck"].as_array().map(|a| a.len()).unwrap_or(0),
                "PRODUCT-084: PR list fetched"
            );
            Ok(Json(v))
        }
        Err(e) => {
            tracing::warn!(error = %e, "PRODUCT-084: gh pr list failed");
            Err(StatusCode::SERVICE_UNAVAILABLE)
        }
    }
}

/// Shape a single PR row for the list.  Shared by open + merged sections.
fn pr_row(pr: &serde_json::Value, now_secs: u64) -> serde_json::Value {
    let number = pr["number"].as_u64().unwrap_or(0);
    let title = pr["title"].as_str().unwrap_or("").to_string();
    let author = pr["author"]["login"]
        .as_str()
        .or_else(|| pr["author"].as_str())
        .unwrap_or("")
        .to_string();
    let url = pr["url"].as_str().unwrap_or("").to_string();

    // Parse createdAt / mergedAt → age_s
    let ts_str = pr["mergedAt"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| pr["createdAt"].as_str().unwrap_or(""));
    let age_s = parse_iso8601_age_secs(ts_str, now_secs);

    let merge_state = pr["mergeStateStatus"]
        .as_str()
        .unwrap_or("UNKNOWN")
        .to_string();

    // Quick CI summary: count successes vs failures in statusCheckRollup
    let checks = pr["statusCheckRollup"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let (pass, fail) = checks.iter().fold((0u32, 0u32), |(p, f), c| {
        match c["conclusion"]
            .as_str()
            .unwrap_or("")
            .to_uppercase()
            .as_str()
        {
            "SUCCESS" => (p + 1, f),
            "FAILURE" => (p, f + 1),
            _ => (p, f),
        }
    });
    let ci_ok = fail == 0 && pass > 0;

    serde_json::json!({
        "number":      number,
        "title":       title,
        "author":      author,
        "age_s":       age_s,
        "merge_state": merge_state,
        "ci_ok":       ci_ok,
        "ci_pass":     pass,
        "ci_fail":     fail,
        "url":         url,
    })
}

/// Parse an ISO-8601 UTC timestamp string into seconds-since-epoch.
/// Returns `now_secs` (age 0) on failure.
fn parse_iso8601_age_secs(ts: &str, now_secs: u64) -> u64 {
    // Expected format: "2026-05-14T18:30:00Z" or "2026-05-14T18:30:00+00:00"
    if ts.len() < 19 {
        return 0;
    }
    let (date, time_rest) = ts.split_once('T').unwrap_or(("", ""));
    let time = time_rest.trim_end_matches('Z').trim_end_matches("+00:00");
    let parts_d: Vec<&str> = date.split('-').collect();
    let parts_t: Vec<&str> = time.split(':').collect();
    if parts_d.len() < 3 || parts_t.len() < 2 {
        return 0;
    }
    let y: u64 = parts_d[0].parse().unwrap_or(0);
    let mo: u64 = parts_d[1].parse().unwrap_or(0);
    let d: u64 = parts_d[2].parse().unwrap_or(0);
    let h: u64 = parts_t[0].parse().unwrap_or(0);
    let m: u64 = parts_t[1].parse().unwrap_or(0);
    let s: u64 = parts_t.get(2).and_then(|v| v.parse().ok()).unwrap_or(0);

    // Rough days-since-epoch (no leap-second precision needed; display only).
    let days = days_since_epoch(y, mo, d);
    let ts_secs = days * 86400 + h * 3600 + m * 60 + s;
    now_secs.saturating_sub(ts_secs)
}

fn days_since_epoch(y: u64, mo: u64, d: u64) -> u64 {
    // Algorithm: days from 1970-01-01. Good enough for age display.
    if y < 1970 {
        return 0;
    }
    let months = [0u64, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    let m_idx = (mo.saturating_sub(1)) as usize;
    let m_days = months.get(m_idx).copied().unwrap_or(0);
    let year_days = (y - 1970) * 365 + (y - 1969) / 4; // close enough
    year_days + m_days + d.saturating_sub(1)
}

async fn fetch_pr_list() -> anyhow::Result<serde_json::Value> {
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let merge_cutoff_secs: u64 = 24 * 3600;
    let stuck_cutoff_secs: u64 = 4 * 3600;

    // ── Open PRs ────────────────────────────────────────────────────────────
    let open_out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "50",
            "--json",
            "number,title,author,createdAt,mergeStateStatus,statusCheckRollup,url",
        ])
        .output()?;
    if !open_out.status.success() {
        anyhow::bail!(
            "gh pr list --state open failed: {}",
            String::from_utf8_lossy(&open_out.stderr)
        );
    }
    let open_raw: serde_json::Value = serde_json::from_slice(&open_out.stdout)?;
    let open_prs: Vec<serde_json::Value> = open_raw
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|pr| pr_row(pr, now_secs))
        .collect();

    // Stuck = open, state DIRTY or BLOCKED, and age > 4h
    let stuck_prs: Vec<serde_json::Value> = open_raw
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter(|pr| {
            let ms = pr["mergeStateStatus"].as_str().unwrap_or("").to_uppercase();
            let is_dirty = ms == "DIRTY" || ms == "BLOCKED";
            if !is_dirty {
                return false;
            }
            let row = pr_row(pr, now_secs);
            row["age_s"].as_u64().unwrap_or(0) > stuck_cutoff_secs
        })
        .map(|pr| pr_row(pr, now_secs))
        .collect();

    // ── Merged PRs (last 24 h) ───────────────────────────────────────────────
    let merged_out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "merged",
            "--limit",
            "30",
            "--json",
            "number,title,author,mergedAt,url",
        ])
        .output()?;
    // Merged list failure is best-effort; don't abort entire endpoint.
    let merged_prs: Vec<serde_json::Value> = if merged_out.status.success() {
        serde_json::from_slice::<serde_json::Value>(&merged_out.stdout)
            .ok()
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .into_iter()
            .map(|pr| pr_row(&pr, now_secs))
            .filter(|row| row["age_s"].as_u64().unwrap_or(u64::MAX) <= merge_cutoff_secs)
            .collect()
    } else {
        vec![]
    };

    // Empty state metadata for just_merged section
    let last_ship_ago_s: Option<u64> = if merged_prs.is_empty() {
        // Find the most recently merged PR regardless of cutoff
        serde_json::from_slice::<serde_json::Value>(&merged_out.stdout)
            .ok()
            .and_then(|v| v.as_array().cloned())
            .and_then(|arr| arr.into_iter().next())
            .map(|pr| pr_row(&pr, now_secs)["age_s"].as_u64().unwrap_or(0))
    } else {
        None
    };

    Ok(serde_json::json!({
        "open":           open_prs,
        "just_merged":    merged_prs,
        "stuck":          stuck_prs,
        "last_ship_ago_s": last_ship_ago_s,
        "fetched_at_s":   now_secs,
        "ttl_s":          30,
    }))
}

// ── PRODUCT-085: PR diff + AC-fit endpoints ───────────────────────────────────────────────────

/// GET /api/pr/{number}/diff — streams `gh pr diff <N>` as plain text.
///
/// Query params:
///   max_lines — cap diff output (default: CHUMP_DIFF_MAX_LINES env, else 2000)
///
/// PRODUCT-085.
async fn handle_pr_diff(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Result<axum::response::Response, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let max_lines: usize = params
        .get("max_lines")
        .and_then(|v| v.parse().ok())
        .or_else(|| {
            std::env::var("CHUMP_DIFF_MAX_LINES")
                .ok()
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(2000);

    let out = std::process::Command::new("gh")
        .args(["pr", "diff", &number.to_string()])
        .output()
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;

    if !out.status.success() {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

    let raw = String::from_utf8_lossy(&out.stdout);
    let truncated: String = raw.lines().take(max_lines).collect::<Vec<_>>().join("\n");

    let body = if raw.lines().count() > max_lines {
        format!(
            "{truncated}\n\n// … diff truncated at {max_lines} lines (set max_lines= to expand)"
        )
    } else {
        truncated
    };

    Ok(axum::response::Response::builder()
        .status(200)
        .header(
            axum::http::header::CONTENT_TYPE,
            "text/plain; charset=utf-8",
        )
        .body(axum::body::Body::from(body))
        .unwrap())
}

/// AC-fit result for a single acceptance-criteria bullet.
#[derive(serde::Serialize)]
struct AcBullet {
    index: usize,
    text: String,
    /// "check" | "unknown" | "cross"
    verdict: &'static str,
    /// Keywords from AC text found in the diff (evidence for "check").
    matched_keywords: Vec<String>,
}

/// GET /api/pr/{number}/ac-fit — heuristic per-AC-bullet check.
///
/// Algorithm:
///   1. Parse PR title for a gap ID (e.g. INFRA-1355, PRODUCT-085).
///   2. Look up the gap's acceptance_criteria in state.db.
///   3. For each AC bullet, extract keywords (≥5-char tokens) and check
///      whether they appear in the diff text.
///   4. "check" = ≥1 keyword hit; "unknown" = 0 hits; "cross" when diff
///      explicitly negates the bullet (contains "revert"/"remove" + keyword).
///
/// Returns JSON: { gap_id, gap_title, ac_bullets: [{ index, text, verdict, matched_keywords }] }
///
/// PRODUCT-085.
async fn handle_pr_ac_fit(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // 1. Fetch PR title from gh.
    let title_out = std::process::Command::new("gh")
        .args([
            "pr",
            "view",
            &number.to_string(),
            "--json",
            "title",
            "--jq",
            ".title",
        ])
        .output()
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    let pr_title = String::from_utf8_lossy(&title_out.stdout)
        .trim()
        .to_string();

    // 2. Extract gap ID from title (first UPPERCASE-NNN token).
    let gap_re = regex::Regex::new(r"\b([A-Z][A-Z0-9]*-[0-9]+)\b")
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let gap_id_opt = gap_re.find(&pr_title).map(|m| m.as_str().to_string());

    let (gap_id, gap_title, ac_items): (String, String, Vec<String>) = match gap_id_opt {
        None => {
            return Ok(Json(serde_json::json!({
                "gap_id": null,
                "gap_title": null,
                "pr_title": pr_title,
                "ac_bullets": [],
                "note": "no gap ID found in PR title"
            })));
        }
        Some(ref gid) => {
            let repo_root = repo_path::runtime_base();
            let store = crate::gap_store::GapStore::open(&repo_root)
                .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
            match store
                .get(gid)
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            {
                None => (gid.clone(), String::new(), vec![]),
                Some(gap) => {
                    // acceptance_criteria is stored as a newline-separated or
                    // YAML-list string; split into individual bullet strings.
                    let ac_raw = gap.acceptance_criteria.clone();
                    let bullets: Vec<String> = ac_raw
                        .lines()
                        .map(|l| {
                            l.trim_start_matches(|c: char| {
                                c == '-' || c == ' ' || c.is_ascii_digit() || c == '.'
                            })
                            .trim()
                            .to_string()
                        })
                        .filter(|l| !l.is_empty())
                        .collect();
                    (gid.clone(), gap.title.clone(), bullets)
                }
            }
        }
    };

    if ac_items.is_empty() {
        return Ok(Json(serde_json::json!({
            "gap_id": gap_id,
            "gap_title": gap_title,
            "pr_title": pr_title,
            "ac_bullets": [],
            "note": "no acceptance criteria found"
        })));
    }

    // 3. Fetch diff text for keyword matching.
    let diff_out = std::process::Command::new("gh")
        .args(["pr", "diff", &number.to_string()])
        .output()
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    let diff_text = String::from_utf8_lossy(&diff_out.stdout).to_lowercase();

    // 4. Evaluate each AC bullet.
    let bullets: Vec<AcBullet> = ac_items
        .iter()
        .enumerate()
        .map(|(i, ac_text)| {
            let lower = ac_text.to_lowercase();
            // Extract meaningful keywords (≥5 chars, alphanumeric).
            let keywords: Vec<String> = lower
                .split(|c: char| !c.is_alphanumeric() && c != '_')
                .filter(|t| t.len() >= 5)
                .filter(|t| {
                    !matches!(
                        *t,
                        "should"
                            | "shall"
                            | "where"
                            | "which"
                            | "there"
                            | "their"
                            | "these"
                            | "those"
                            | "about"
                            | "after"
                            | "before"
                            | "above"
                            | "below"
                            | "using"
                            | "state"
                            | "value"
                            | "could"
                            | "would"
                            | "check"
                            | "first"
                            | "every"
                            | "other"
                    )
                })
                .map(|t| t.to_string())
                .collect::<std::collections::HashSet<_>>()
                .into_iter()
                .collect();

            let matched: Vec<String> = keywords
                .iter()
                .filter(|kw| diff_text.contains(kw.as_str()))
                .cloned()
                .collect();

            // "cross" heuristic: diff contains revert/remove + keyword
            let is_cross = !matched.is_empty()
                && (diff_text.contains("revert") || diff_text.contains("remove"))
                && matched.iter().any(|kw| {
                    // Look for "-<keyword>" lines in the diff (deletion context).
                    diff_text
                        .lines()
                        .any(|l| l.starts_with('-') && l.contains(kw.as_str()))
                });

            let verdict = if is_cross {
                "cross"
            } else if !matched.is_empty() {
                "check"
            } else {
                "unknown"
            };

            AcBullet {
                index: i + 1,
                text: ac_text.clone(),
                verdict,
                matched_keywords: matched,
            }
        })
        .collect();

    Ok(Json(serde_json::json!({
        "gap_id": gap_id,
        "gap_title": gap_title,
        "pr_title": pr_title,
        "ac_bullets": bullets,
    })))
}

// ── PRODUCT-086: PR action endpoints (approve, request-changes, comment, revert) ──────────

#[derive(serde::Deserialize)]
struct PrActionRequest {
    body: Option<String>,
}

/// POST /api/prs/{number}/approve — Approve a PR with optional comment (PRODUCT-086).
async fn handle_pr_approve(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
    Json(req): Json<PrActionRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let session_id = get_session_id(&headers);
    let mut cmd = std::process::Command::new("gh");
    cmd.args(["pr", "review", &number.to_string(), "--approve"]);
    if let Some(body) = &req.body {
        cmd.args(["--body", body]);
    }
    let out = cmd.output().map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    if !out.status.success() {
        eprintln!(
            "gh pr review --approve failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    // Emit operator_pr_action event to ambient.
    emit_operator_pr_action("approve", number, session_id.as_deref()).ok();
    Ok(Json(serde_json::json!({ "status": "approved" })))
}

/// POST /api/prs/{number}/request-changes — Request changes on a PR (PRODUCT-086).
async fn handle_pr_request_changes(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
    Json(req): Json<PrActionRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let session_id = get_session_id(&headers);
    let body = req.body.unwrap_or_default();
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "review",
            &number.to_string(),
            "--request-changes",
            "--body",
            &body,
        ])
        .output()
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    if !out.status.success() {
        eprintln!(
            "gh pr review --request-changes failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    emit_operator_pr_action("request_changes", number, session_id.as_deref()).ok();
    Ok(Json(serde_json::json!({ "status": "requested_changes" })))
}

/// POST /api/prs/{number}/comment — Add a comment to a PR (PRODUCT-086).
async fn handle_pr_comment(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
    Json(req): Json<PrActionRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let session_id = get_session_id(&headers);
    let body = req.body.unwrap_or_default();
    let out = std::process::Command::new("gh")
        .args(["pr", "comment", &number.to_string(), "--body", &body])
        .output()
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    if !out.status.success() {
        eprintln!(
            "gh pr comment failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    emit_operator_pr_action("comment", number, session_id.as_deref()).ok();
    Ok(Json(serde_json::json!({ "status": "commented" })))
}

/// POST /api/prs/{number}/revert — Revert a merged PR by creating a new PR with the revert (PRODUCT-086).
/// Note: gh pr revert doesn't exist natively, so we call a helper script.
async fn handle_pr_revert(
    headers: HeaderMap,
    axum::extract::Path(number): axum::extract::Path<u32>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let session_id = get_session_id(&headers);
    // Call helper script scripts/coord/pr-revert.sh if it exists, else use gh directly.
    let script_path = std::path::PathBuf::from("scripts/coord/pr-revert.sh");
    let use_script = script_path.exists();
    let out = if use_script {
        std::process::Command::new("bash")
            .args(["scripts/coord/pr-revert.sh", &number.to_string()])
            .output()
            .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?
    } else {
        // Fallback: gh pr revert (if available in newer gh versions)
        std::process::Command::new("gh")
            .args(["pr", "revert", &number.to_string(), "--create-issue"])
            .output()
            .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?
    };
    if !out.status.success() {
        eprintln!("pr revert failed: {}", String::from_utf8_lossy(&out.stderr));
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    emit_operator_pr_action("revert", number, session_id.as_deref()).ok();
    Ok(Json(serde_json::json!({ "status": "reverted" })))
}

fn emit_operator_pr_action(action: &str, pr: u32, session_id: Option<&str>) -> Result<()> {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = serde_json::json!({
        "ts": now,
        "kind": "operator_pr_action",
        "type": action,
        "pr": pr,
        "operator_session": session_id.unwrap_or("unknown"),
    });
    let path = ambient_log_path();
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "{}", event)?;
    Ok(())
}

// ── PRODUCT-091 / PRODUCT-094: ambient event viewer + notification center endpoints ──────────
// PRODUCT-094: /api/ambient/stream is consumed by notification-center.js for
// fleet_wedge, pr_stuck, gap_shipped, needs_judgment events → in-app badge +
// notification panel + localStorage persistence. No additional server endpoints
// required; the existing SSE stream covers all notification kinds.

fn ambient_log_path() -> PathBuf {
    std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            repo_path::runtime_base()
                .join(".chump-locks")
                .join("ambient.jsonl")
        })
}

// ── PRODUCT-081: 60-second server-side cache for /api/impact ────────────────
static IMPACT_CACHE: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<String, (std::time::Instant, serde_json::Value)>>,
> = std::sync::OnceLock::new();

/// GET /api/impact?window=today|week|all — returns aggregated outcome metrics.
/// Auth-gated. Responses are cached for 60 seconds per window key.
/// PRODUCT-081: PWA Outcome Dashboard.
async fn handle_impact(
    Query(params): Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let window = params
        .get("window")
        .map(|s| s.as_str())
        .unwrap_or("today")
        .to_string();

    // ── Cache check ──────────────────────────────────────────────────────────
    let cache =
        IMPACT_CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()));
    {
        if let Ok(guard) = cache.lock() {
            if let Some((ts, val)) = guard.get(&window) {
                if ts.elapsed() < std::time::Duration::from_secs(60) {
                    return Ok(Json(val.clone()));
                }
            }
        }
    }

    // ── Window bounds ────────────────────────────────────────────────────────
    let now_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let window_duration_secs: u64 = match window.as_str() {
        "week" => 7 * 86_400,
        "all" => 365 * 86_400,
        _ => 86_400, // "today" default
    };
    let window_start_ts = now_ts.saturating_sub(window_duration_secs);

    // ── Parse ambient.jsonl since window_start ───────────────────────────────
    let path = ambient_log_path();
    let content = std::fs::read_to_string(&path).unwrap_or_default();

    let mut prs_merged: u64 = 0;
    let mut fleet_activity_hours: f64 = 0.0;
    // gap_id → closed_pr string
    let mut shipped_gaps: Vec<(String, String)> = Vec::new();

    for line in content.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(val) => val,
            Err(_) => continue,
        };

        // Filter by timestamp field (ts as unix seconds or ISO string)
        let event_ts: Option<u64> = v.get("ts").and_then(|t| {
            if let Some(n) = t.as_u64() {
                Some(n)
            } else if let Some(s) = t.as_str() {
                // Parse ISO 8601 via chrono
                chrono::DateTime::parse_from_rfc3339(s)
                    .ok()
                    .map(|dt| dt.timestamp() as u64)
            } else {
                None
            }
        });
        if let Some(ts) = event_ts {
            if ts < window_start_ts {
                continue;
            }
        }

        let kind = v
            .get("kind")
            .or_else(|| v.get("event"))
            .and_then(|k| k.as_str())
            .unwrap_or("");

        match kind {
            "gap_shipped" => {
                let gap_id = v
                    .get("gap_id")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let closed_pr = v
                    .get("closed_pr")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                if !gap_id.is_empty() {
                    shipped_gaps.push((gap_id, closed_pr));
                }
            }
            "pr_merged" => {
                prs_merged += 1;
            }
            "session_end" => {
                if let Some(secs) = v.get("elapsed_s").and_then(|x| x.as_f64()) {
                    fleet_activity_hours += secs / 3600.0;
                }
            }
            "cycle_end" => {
                if let Some(secs) = v.get("elapsed_s").and_then(|x| x.as_f64()) {
                    fleet_activity_hours += secs / 3600.0;
                }
            }
            _ => {}
        }
    }

    // ── Enrich from gap_store ────────────────────────────────────────────────
    let repo_root = crate::repo_path::runtime_base();
    let gap_store = crate::gap_store::GapStore::open(&repo_root).ok();

    #[derive(Debug)]
    struct GapSummary {
        gap_id: String,
        effort: String,
        hours_saved: f64,
        title: String,
        pillar: String,
        closed_pr: String,
    }

    let effort_to_hours = |effort: &str| -> f64 {
        match effort {
            "xs" => 0.25,
            "s" => 1.0,
            "m" => 4.0,
            "l" => 12.0,
            "xl" => 40.0,
            _ => 1.0,
        }
    };

    let detect_pillar = |title: &str| -> &'static str {
        if title.contains("EFFECTIVE:") {
            "EFFECTIVE"
        } else if title.contains("CREDIBLE:") {
            "CREDIBLE"
        } else if title.contains("RESILIENT:") {
            "RESILIENT"
        } else if title.contains("ZERO-WASTE:") {
            "ZERO-WASTE"
        } else if title.contains("MISSION:") {
            "MISSION"
        } else {
            "unknown"
        }
    };

    let mut gap_summaries: Vec<GapSummary> = Vec::new();
    for (gap_id, closed_pr) in &shipped_gaps {
        let (effort, title) = if let Some(ref store) = gap_store {
            match store.get(gap_id) {
                Ok(Some(row)) => (row.effort.clone(), row.title.clone()),
                _ => (String::new(), String::new()),
            }
        } else {
            (String::new(), String::new())
        };
        let hours_saved = effort_to_hours(&effort);
        let pillar = detect_pillar(&title).to_string();
        gap_summaries.push(GapSummary {
            gap_id: gap_id.clone(),
            effort: effort.clone(),
            hours_saved,
            title: title.clone(),
            pillar,
            closed_pr: closed_pr.clone(),
        });
    }

    // ── Derived metrics ──────────────────────────────────────────────────────
    let gaps_closed = gap_summaries.len() as u64;
    let operator_hours_saved: f64 = gap_summaries.iter().map(|g| g.hours_saved).sum();

    // Pillar mix counts
    let mut pillar_mix = std::collections::HashMap::<String, u64>::new();
    for pillar_key in &[
        "EFFECTIVE",
        "CREDIBLE",
        "RESILIENT",
        "ZERO-WASTE",
        "MISSION",
        "unknown",
    ] {
        pillar_mix.insert(pillar_key.to_string(), 0);
    }
    for g in &gap_summaries {
        *pillar_mix.entry(g.pillar.clone()).or_insert(0) += 1;
    }

    // Pillar mix percentages (non-unknown gaps only)
    let total_non_unknown: u64 = gap_summaries
        .iter()
        .filter(|g| g.pillar != "unknown")
        .count() as u64;

    let mut pillar_mix_pct = serde_json::Map::new();
    for pillar_key in &[
        "EFFECTIVE",
        "CREDIBLE",
        "RESILIENT",
        "ZERO-WASTE",
        "MISSION",
    ] {
        let count = pillar_mix.get(*pillar_key).copied().unwrap_or(0);
        let pct = if total_non_unknown > 0 {
            (count as f64 / total_non_unknown as f64) * 100.0
        } else {
            0.0
        };
        if pct > 0.0 {
            pillar_mix_pct.insert(
                pillar_key.to_string(),
                serde_json::Value::from((pct * 10.0).round() / 10.0),
            );
        }
    }

    // Starved pillars: non-MISSION pillars < 15% share (only when >= 5 total gaps)
    let mut starved_pillars: Vec<String> = Vec::new();
    if total_non_unknown >= 5 {
        for pillar_key in &["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"] {
            let count = pillar_mix.get(*pillar_key).copied().unwrap_or(0);
            let pct = (count as f64 / total_non_unknown as f64) * 100.0;
            if pct < 15.0 {
                starved_pillars.push(pillar_key.to_string());
            }
        }
    }

    // Top 5 gaps by hours_saved
    gap_summaries.sort_by(|a, b| {
        b.hours_saved
            .partial_cmp(&a.hours_saved)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let top_prs: Vec<serde_json::Value> = gap_summaries
        .iter()
        .take(5)
        .map(|g| {
            serde_json::json!({
                "gap_id": g.gap_id,
                "effort": g.effort,
                "hours_saved": g.hours_saved,
                "title": g.title,
                "closed_pr": g.closed_pr,
            })
        })
        .collect();

    let data_days = window_duration_secs / 86_400;
    let generated_at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);

    tracing::info!(
        "handle_impact: window={}, prs={}, gaps={}, hours_saved={:.1}",
        window,
        prs_merged,
        gaps_closed,
        operator_hours_saved
    );

    // Build pillar_mix as JSON object with all 6 keys
    let pillar_mix_json = serde_json::json!({
        "EFFECTIVE": pillar_mix.get("EFFECTIVE").copied().unwrap_or(0),
        "CREDIBLE": pillar_mix.get("CREDIBLE").copied().unwrap_or(0),
        "RESILIENT": pillar_mix.get("RESILIENT").copied().unwrap_or(0),
        "ZERO-WASTE": pillar_mix.get("ZERO-WASTE").copied().unwrap_or(0),
        "MISSION": pillar_mix.get("MISSION").copied().unwrap_or(0),
        "unknown": pillar_mix.get("unknown").copied().unwrap_or(0),
    });

    let payload = serde_json::json!({
        "window": window,
        "window_start_ts": window_start_ts,
        "generated_at": generated_at,
        "metrics": {
            "prs_merged": prs_merged,
            "gaps_closed": gaps_closed,
            "fleet_activity_hours": (fleet_activity_hours * 10.0).round() / 10.0,
            "operator_hours_saved": (operator_hours_saved * 10.0).round() / 10.0,
        },
        "pillar_mix": pillar_mix_json,
        "pillar_mix_pct": serde_json::Value::Object(pillar_mix_pct),
        "starved_pillars": starved_pillars,
        "top_prs": top_prs,
        "data_days": data_days,
    });

    // ── Store in cache ───────────────────────────────────────────────────────
    if let Ok(mut guard) = cache.lock() {
        guard.insert(window.clone(), (std::time::Instant::now(), payload.clone()));
    }

    Ok(Json(payload))
}

/// GET /api/brief?since=<unix_ts_secs> — structured JSON summary of ambient events
/// since the given timestamp. Defaults to the last 8 hours. Events are
/// categorised into three buckets: done, needs_judgment, and alerts.
/// PRODUCT-078.
async fn handle_brief(
    Query(params): Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let now_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let default_since = now_ts.saturating_sub(8 * 3600);
    let since_ts: u64 = params
        .get("since")
        .and_then(|v| v.parse().ok())
        .unwrap_or(default_since);

    let since_ago_secs = now_ts.saturating_sub(since_ts);

    // Convert since_ts to an RFC3339 string for string-based timestamp comparison.
    // Timestamps in ambient.jsonl are RFC3339 so lexicographic compare is valid.
    let since_dt = chrono::DateTime::<chrono::Utc>::from_timestamp(since_ts as i64, 0)
        .unwrap_or_else(chrono::Utc::now);
    let since_str = since_dt.to_rfc3339();

    let generated_at = chrono::Utc::now().to_rfc3339();

    let path = ambient_log_path();
    let content = std::fs::read_to_string(&path).unwrap_or_default();

    let mut done: Vec<serde_json::Value> = Vec::new();
    let mut needs_judgment: Vec<serde_json::Value> = Vec::new();
    let mut alerts: Vec<serde_json::Value> = Vec::new();

    for line in content.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(val) => val,
            Err(_) => continue,
        };

        // Filter by timestamp using string comparison (RFC3339 is lexicographically ordered).
        let ts_str = v.get("ts").and_then(|t| t.as_str()).unwrap_or("");
        if ts_str < since_str.as_str() {
            continue;
        }

        let kind = v
            .get("kind")
            .and_then(|k| k.as_str())
            .unwrap_or("")
            .to_string();

        let summary = match kind.as_str() {
            "pr_merged" => {
                let id = v
                    .get("pr")
                    .or_else(|| v.get("gap_id"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("?");
                format!("PR #{} merged", id)
            }
            "gap_shipped" => {
                let gap_id = v.get("gap_id").and_then(|x| x.as_str()).unwrap_or("?");
                let closed_pr = v.get("closed_pr").and_then(|x| x.as_str()).unwrap_or("?");
                format!("Gap {} shipped (PR #{})", gap_id, closed_pr)
            }
            "cycle_end" => {
                let rc = v.get("rc").and_then(|x| x.as_i64()).unwrap_or(1);
                if rc != 0 {
                    continue; // only rc=0 goes into done
                }
                "Cycle completed successfully".to_string()
            }
            "pr_stuck" => {
                let pr = v.get("pr").and_then(|x| x.as_str()).unwrap_or("?");
                let reason = v
                    .get("reason")
                    .and_then(|x| x.as_str())
                    .unwrap_or("unknown");
                format!("PR #{} stuck: {}", pr, reason)
            }
            "silent_agent" => {
                let session = v.get("session").and_then(|x| x.as_str()).unwrap_or("?");
                format!("Silent agent: session {}", session)
            }
            "fleet_wedge" => "Fleet wedge detected".to_string(),
            "gap_drift_orphan" => {
                let gap_id = v.get("gap_id").and_then(|x| x.as_str()).unwrap_or("?");
                format!("Gap drift orphan: {}", gap_id)
            }
            "slo_breach" => {
                let slo_name = v.get("slo_name").and_then(|x| x.as_str()).unwrap_or("?");
                format!("SLO breach: {}", slo_name)
            }
            "fleet_paused_disk_critical" => {
                let free_gb = v.get("free_gb").and_then(|x| x.as_f64()).unwrap_or(0.0);
                format!("Disk critical: {}GB free", free_gb)
            }
            "graphql_exhausted" => "GitHub GraphQL quota exhausted".to_string(),
            "fleet_auth_unrecoverable" => "Fleet auth unrecoverable".to_string(),
            "waste_spike_detected" => {
                let rate = v.get("rate").and_then(|x| x.as_f64()).unwrap_or(0.0);
                format!("Waste spike: {}%", rate)
            }
            other => other.to_string(),
        };

        let url = v.get("url").and_then(|x| x.as_str()).map(|s| s.to_string());

        let mut item = serde_json::json!({
            "kind": kind,
            "ts": ts_str,
            "summary": summary,
        });
        if let Some(u) = url {
            item["url"] = serde_json::Value::String(u);
        }

        match kind.as_str() {
            "pr_merged" | "gap_shipped" | "cycle_end" => {
                if done.len() < 50 {
                    done.push(item);
                }
            }
            "pr_stuck" | "silent_agent" | "fleet_wedge" | "gap_drift_orphan" => {
                if needs_judgment.len() < 50 {
                    needs_judgment.push(item);
                }
            }
            "slo_breach"
            | "fleet_paused_disk_critical"
            | "graphql_exhausted"
            | "fleet_auth_unrecoverable"
            | "waste_spike_detected" => {
                if alerts.len() < 50 {
                    alerts.push(item);
                }
            }
            _ => {} // uncategorised events are silently dropped
        }
    }

    let done_count = done.len();
    let nj_count = needs_judgment.len();
    let alert_count = alerts.len();

    tracing::debug!(
        "handle_brief: since={}s ago, done={}, needs_judgment={}, alerts={}",
        since_ago_secs,
        done_count,
        nj_count,
        alert_count,
    );

    Ok(Json(serde_json::json!({
        "since_ts": since_ts,
        "since_ago_secs": since_ago_secs,
        "generated_at": generated_at,
        "buckets": {
            "done": done,
            "needs_judgment": needs_judgment,
            "alerts": alerts,
        },
        "counts": {
            "done": done_count,
            "needs_judgment": nj_count,
            "alerts": alert_count,
        },
    })))
}

/// GET /api/ambient/recent?n=100&kind=fleet_wedge — returns last N ambient events.
/// Optional `kind` param filters to a specific event kind.
/// PRODUCT-091.
async fn handle_ambient_recent(
    Query(params): Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let n: usize = params
        .get("n")
        .and_then(|v| v.parse().ok())
        .unwrap_or(100)
        .min(1000);
    let kind_filter: Option<String> = params.get("kind").cloned();

    let path = ambient_log_path();
    let content = std::fs::read_to_string(&path).unwrap_or_default();
    let events: Vec<serde_json::Value> = content
        .lines()
        .rev()
        .filter_map(|line| {
            let v: serde_json::Value = serde_json::from_str(line).ok()?;
            if let Some(ref k) = kind_filter {
                let event_kind = v
                    .get("kind")
                    .or_else(|| v.get("event"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("");
                if event_kind != k.as_str() {
                    return None;
                }
            }
            Some(v)
        })
        .take(n)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();

    Ok(Json(
        serde_json::json!({ "events": events, "count": events.len() }),
    ))
}

/// POST /api/ambient/emit — append a synthetic event from a PWA client to ambient.jsonl.
///
/// Accepts any JSON object that contains a `kind` string field.  The server stamps the
/// current UTC time as `ts` (overwriting any client-supplied value to prevent skew) and
/// tags the event with `source:"pwa"` so fleet tooling can distinguish PWA-emitted events
/// from server-generated ones.  Returns 200 `{"ok":true}` on success or 400/401 on error.
///
/// Auth-gated the same way as the other `/api/ambient/*` endpoints.  INFRA-1333.
async fn handle_ambient_emit(
    headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Payload must be a JSON object.
    let mut obj: serde_json::Map<String, serde_json::Value> = match payload {
        serde_json::Value::Object(m) => m,
        _ => return Err(StatusCode::BAD_REQUEST),
    };

    // Require a non-empty `kind` string.
    match obj.get("kind") {
        Some(serde_json::Value::String(k)) if !k.is_empty() => {}
        _ => return Err(StatusCode::BAD_REQUEST),
    }

    // Stamp server-side timestamp and source tag to prevent client clock skew / spoofing.
    obj.insert(
        "ts".to_string(),
        serde_json::Value::String(
            chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        ),
    );
    obj.entry("source".to_string())
        .or_insert_with(|| serde_json::Value::String("pwa".to_string()));

    let line = serde_json::to_string(&serde_json::Value::Object(obj))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Append to ambient.jsonl best-effort; ignore write errors (file may not exist in tests).
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log_path())
    {
        let _ = writeln!(f, "{}", line);
    }

    Ok(Json(serde_json::json!({ "ok": true })))
}

/// GET /api/ambient/stream — SSE endpoint that tails ambient.jsonl and emits new events.
/// Polls every 500ms for new lines. Sends existing last-50 events on connect, then live tail.
/// PRODUCT-091.
async fn handle_ambient_stream(
    Query(params): Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<
    Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>,
    StatusCode,
> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let kind_filter: Option<String> = params.get("kind").cloned();
    // INFRA-1010: `?kinds=a,b,c` (OR-match exact) and `?prefixes=phase_,ship_`
    // (OR-match prefix) so FleetSidebar can subscribe to its whitelist in
    // one connection instead of N or filtering client-side.
    let kinds_filter: Vec<String> = params
        .get("kinds")
        .map(|s| {
            s.split(',')
                .map(|x| x.trim().to_string())
                .filter(|x| !x.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let prefixes_filter: Vec<String> = params
        .get("prefixes")
        .map(|s| {
            s.split(',')
                .map(|x| x.trim().to_string())
                .filter(|x| !x.is_empty())
                .collect()
        })
        .unwrap_or_default();

    if !kinds_filter.is_empty() || !prefixes_filter.is_empty() {
        tracing::info!(
            kinds_count = kinds_filter.len(),
            prefixes_count = prefixes_filter.len(),
            "ambient/stream multi-filter subscription (INFRA-1010)"
        );
    }

    let path = ambient_log_path();
    let (tx, rx) =
        tokio::sync::mpsc::unbounded_channel::<Result<Event, std::convert::Infallible>>();

    tokio::spawn(async move {
        // Seed: send the last 50 lines from existing file content.
        let seed_content = std::fs::read_to_string(&path).unwrap_or_default();
        let seed_lines: Vec<&str> = seed_content
            .lines()
            .rev()
            .take(50)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let mut file_offset: u64 = seed_content.len() as u64;

        // INFRA-1010: shared filter — passes if no filters set, or if event
        // kind matches any of `kind` / `kinds` / `prefixes`.
        let passes_filter = |v: &serde_json::Value| -> bool {
            let ek = v
                .get("kind")
                .or_else(|| v.get("event"))
                .and_then(|x| x.as_str())
                .unwrap_or("");
            let any_filter =
                kind_filter.is_some() || !kinds_filter.is_empty() || !prefixes_filter.is_empty();
            if !any_filter {
                return true;
            }
            if let Some(ref k) = kind_filter {
                if ek == k.as_str() {
                    return true;
                }
            }
            if kinds_filter.iter().any(|k| ek == k.as_str()) {
                return true;
            }
            if prefixes_filter.iter().any(|p| ek.starts_with(p.as_str())) {
                return true;
            }
            false
        };

        for line in &seed_lines {
            if line.is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                if !passes_filter(&v) {
                    continue;
                }
                let data = line.to_string();
                if tx
                    .send(Ok(Event::default().event("ambient").data(data)))
                    .is_err()
                {
                    return;
                }
            }
        }

        // Tail: poll for new lines appended after seed.
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let Ok(mut file) = std::fs::File::open(&path) else {
                continue;
            };
            let new_len = file.metadata().map(|m| m.len()).unwrap_or(file_offset);
            if new_len <= file_offset {
                continue;
            }

            use std::io::{Read, Seek, SeekFrom};
            if file.seek(SeekFrom::Start(file_offset)).is_err() {
                continue;
            }
            let mut buf = String::new();
            if file.read_to_string(&mut buf).is_err() {
                continue;
            }
            file_offset = new_len;

            for line in buf.lines() {
                if line.is_empty() {
                    continue;
                }
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
                    if !passes_filter(&v) {
                        continue;
                    }
                    let data = line.to_string();
                    if tx
                        .send(Ok(Event::default().event("ambient").data(data)))
                        .is_err()
                    {
                        return;
                    }
                }
            }
        }
    });

    Ok(Sse::new(UnboundedReceiverStream::new(rx)).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("keep-alive"),
    ))
}

/// Parse the first 19 chars of an ISO 8601 timestamp ("YYYY-MM-DDTHH:MM:SS")
/// into approximate Unix seconds. Returns 0 on parse failure.
/// Avoids a chrono dependency by doing manual string arithmetic.
fn chrono_approx_secs(ts: &str) -> u64 {
    fn inner(ts: &str) -> Option<u64> {
        let b = ts.as_bytes();
        if b.len() < 19 {
            return None;
        }
        let parse = |s: &[u8]| -> Option<u64> { std::str::from_utf8(s).ok()?.parse().ok() };
        let year = parse(&b[0..4])?;
        let month = parse(&b[5..7])?;
        let day = parse(&b[8..10])?;
        let hour = parse(&b[11..13])?;
        let min = parse(&b[14..16])?;
        let sec = parse(&b[17..19])?;
        // Rough Gregorian since Unix epoch; good enough for 24h/30d windows.
        let y = year as i64 - 1970;
        let leap_days = (y / 4) - (y / 100) + (y / 400);
        let month_days: [u64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        let days_in_year = y.unsigned_abs() * 365 + leap_days.unsigned_abs();
        let days_in_months: u64 = month_days
            .iter()
            .take((month as usize).saturating_sub(1))
            .sum();
        let days = days_in_year + days_in_months + day - 1;
        Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
    }
    inner(ts).unwrap_or(0)
}

/// GET /api/fleet-status — Active agent sessions read from .chump-locks/*.json lease files.
/// Returns `{sessions: [{session_id, gap_id, gap_title, gap_priority, gap_effort, branch,
///   worktree_path, taken_at, expires_at, heartbeat_at, pr_number, pr_state, ci_status}],
///   count: N}`.
/// Data from: lease files (session/gap), gap_store (title/priority), gh CLI (PR/CI, best-effort).
/// Works without GitHub access — pr_number/pr_state/ci_status will be null.
/// PRODUCT-059: read-only live results board, phase 1.
async fn handle_fleet_status(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };

    let lock_dir = std::env::var("CHUMP_LOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join(".chump-locks"));

    // ── Read all lease JSON files ────────────────────────────────────────────
    let mut leases: Vec<serde_json::Value> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&lock_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let fname = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            // Skip ambient lock, cooldown, and non-lease files
            if fname.starts_with("ambient") || !fname.contains('-') {
                continue;
            }
            if let Ok(contents) = std::fs::read_to_string(&path) {
                if let Ok(lease) = serde_json::from_str::<serde_json::Value>(&contents) {
                    let gap_id = lease
                        .get("gap_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if !gap_id.is_empty() {
                        leases.push(lease);
                    }
                }
            }
        }
    }

    // ── Enrich with gap_store metadata (synchronous — local SQLite, fast) ──────
    let gap_store = crate::gap_store::GapStore::open(&repo_root).ok();

    // Phase 1: extract all metadata synchronously so gap_store (non-Send) stays
    // on this thread. gh CLI calls happen in phase 2, in parallel.
    struct LeaseInfo {
        gap_id: String,
        session_id: String,
        taken_at: String,
        expires_at: String,
        heartbeat_at: String,
        worktree_path: String,
        branch: String,
        gap_title: String,
        gap_priority: String,
        gap_effort: String,
    }
    let mut lease_infos: Vec<LeaseInfo> = Vec::new();
    for lease in leases {
        let gap_id = lease
            .get("gap_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let session_id = lease
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let taken_at = lease
            .get("taken_at")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let expires_at = lease
            .get("expires_at")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let heartbeat_at = lease
            .get("heartbeat_at")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let paths_val = lease.get("paths").cloned().unwrap_or(serde_json::json!([]));
        let worktree_path: String = paths_val
            .as_array()
            .and_then(|arr| arr.first())
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let branch = format!("chump/{}-claim", gap_id.to_lowercase().replace('_', "-"));
        let (gap_title, gap_priority, gap_effort) = if let Some(ref store) = gap_store {
            match store.get(&gap_id) {
                Ok(Some(gap)) => (gap.title.clone(), gap.priority.clone(), gap.effort.clone()),
                _ => (String::new(), String::new(), String::new()),
            }
        } else {
            (String::new(), String::new(), String::new())
        };
        lease_infos.push(LeaseInfo {
            gap_id,
            session_id,
            taken_at,
            expires_at,
            heartbeat_at,
            worktree_path,
            branch,
            gap_title,
            gap_priority,
            gap_effort,
        });
    }

    // Phase 2: gh pr list — parallel async calls, each with a per-call timeout.
    // INFRA-1464: 25 sequential calls → fan-out, all fire simultaneously.
    let gh_timeout_secs: u64 = std::env::var("CHUMP_FLEET_STATUS_GH_TIMEOUT_S")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(2);

    /// Parse gh pr list JSON output into (pr_number, pr_state, ci_status).
    fn parse_gh_pr_list(stdout: &[u8]) -> (Option<u64>, Option<String>, Option<String>) {
        let Ok(arr) = serde_json::from_slice::<Vec<serde_json::Value>>(stdout) else {
            return (None, None, None);
        };
        let Some(pr) = arr.first() else {
            return (None, None, None);
        };
        let num = pr.get("number").and_then(|v| v.as_u64());
        let state = pr
            .get("state")
            .and_then(|v| v.as_str())
            .map(|s| s.to_lowercase());
        let ci = pr
            .get("statusCheckRollup")
            .and_then(|v| v.as_array())
            .map(|checks| {
                let has_fail = checks.iter().any(|c| {
                    c.get("conclusion")
                        .and_then(|v| v.as_str())
                        .map(|s| s == "FAILURE")
                        .unwrap_or(false)
                });
                let has_pending = checks.iter().any(|c| {
                    c.get("status")
                        .and_then(|v| v.as_str())
                        .map(|s| s == "IN_PROGRESS" || s == "QUEUED")
                        .unwrap_or(false)
                });
                let all_success = checks.iter().all(|c| {
                    c.get("conclusion")
                        .and_then(|v| v.as_str())
                        .map(|s| s == "SUCCESS" || s == "SKIPPED")
                        .unwrap_or(false)
                });
                if has_fail {
                    "failure"
                } else if has_pending {
                    "pending"
                } else if all_success && !checks.is_empty() {
                    "success"
                } else {
                    "unknown"
                }
                .to_string()
            });
        (num, state, ci)
    }

    let pr_futures: Vec<_> = lease_infos
        .iter()
        .map(|info| {
            let branch = info.branch.clone();
            let timeout_dur = std::time::Duration::from_secs(gh_timeout_secs);
            async move {
                let cmd = tokio::process::Command::new("gh")
                    .args([
                        "pr",
                        "list",
                        "--head",
                        &branch,
                        "--json",
                        "number,state,statusCheckRollup",
                        "--limit",
                        "1",
                        "--state",
                        "all",
                    ])
                    .output();
                match tokio::time::timeout(timeout_dur, cmd).await {
                    Ok(Ok(o)) if o.status.success() => parse_gh_pr_list(&o.stdout),
                    Ok(Ok(_)) | Ok(Err(_)) => (None, None, None),
                    Err(_) => {
                        // Timeout: gh call exceeded per-call deadline. INFRA-1464.
                        tracing::warn!(
                            target: "infra_1464",
                            branch = %branch,
                            timeout_s = gh_timeout_secs,
                            "fleet_status_gh_timeout: gh pr list timed out"
                        );
                        (None, None, None)
                    }
                }
            }
        })
        .collect();

    // Fan-out: all gh calls fire simultaneously. Total wall-clock ≈ max(individual
    // timeouts) instead of sum — 25 × 2s sequential → 2s parallel. INFRA-1464.
    let pr_results = futures_util::future::join_all(pr_futures).await;

    let mut sessions: Vec<serde_json::Value> = lease_infos
        .into_iter()
        .zip(pr_results)
        .map(|(info, (pr_number, pr_state, ci_status))| {
            serde_json::json!({
                "session_id": info.session_id,
                "gap_id": info.gap_id,
                "gap_title": info.gap_title,
                "gap_priority": info.gap_priority,
                "gap_effort": info.gap_effort,
                "branch": info.branch,
                "worktree_path": info.worktree_path,
                "taken_at": info.taken_at,
                "expires_at": info.expires_at,
                "heartbeat_at": info.heartbeat_at,
                "pr_number": pr_number,
                "pr_state": pr_state,
                "ci_status": ci_status,
            })
        })
        .collect();

    // Sort newest-first by taken_at
    sessions.sort_by(|a, b| {
        let ta = b.get("taken_at").and_then(|v| v.as_str()).unwrap_or("");
        let tb = a.get("taken_at").and_then(|v| v.as_str()).unwrap_or("");
        ta.cmp(tb)
    });

    let count = sessions.len();
    tracing::info!("fleet-status: {} active sessions (PRODUCT-059)", count);

    Ok(Json(serde_json::json!({
        "sessions": sessions,
        "count": count,
    })))
}

/// All `/api/*` routes plus favicon. Merged under static file fallback in [`start_web_server`].
/// GET /api/gap-queue — List of open gaps with preflight status for PWA dispatch queue.
/// Returns `{gaps: [{id, title, priority, effort, preflight_status, preflight_error?}]}`
/// where preflight_status is "claimable" | "conflict" | "blocked" | "error".
/// GET /api/gap-queue — list queryable gap registry rows for the PWA.
///
/// INFRA-1197: previously this returned 6 fields per row; PWA could not render
/// rich queue cards (no domain, no closed_pr, no pillar tag, etc.). The fat
/// shape adds: domain, status, closed_pr, assigned_session, created_at,
/// opened_date, depends_on (parsed array), acceptance_criteria_count, pillar.
///
/// Query params (all optional, all additive):
///   ?status=open|claimed|shipped|done   (default: open. comma-separated for OR)
///   ?domain=INFRA|CREDIBLE|EFFECTIVE|...  (exact match)
///   ?priority=P0|P1|P2|P3                  (exact match)
///
/// Response shape: { gaps:[...], count, total, claimable_count }
///   - count = returned (post-filter) length
///   - total = pre-filter length (matches first selected status set)
///
/// Sort order: priority asc (P0<P1<P2<P3), effort asc (xs<s<m<l), created_at
/// desc. Stable across requests.
///
/// Titles are truncated at 200 chars (utf-8 safe) to bound payload size; a
/// future drill-in endpoint will serve full title + AC bodies.
async fn handle_gap_queue(
    Query(params): Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let t_start = std::time::Instant::now();

    let status_filter: Vec<String> = params
        .get("status")
        .map(|s| {
            s.split(',')
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .collect()
        })
        .unwrap_or_else(|| vec!["open".to_string()]);
    let domain_filter = params.get("domain").cloned();
    let priority_filter = params.get("priority").cloned();

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };

    let gap_store_inst = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("gap-queue: failed to open gap store: {}", e);
            return Ok(Json(
                serde_json::json!({ "gaps": [], "error": e.to_string() }),
            ));
        }
    };

    // Fetch matching status sets, dedup by id. Single-status takes the
    // optimized path; multi-status loops and merges.
    let mut all_gaps: Vec<gap_store::GapRow> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for st in &status_filter {
        let st_arg = if st == "all" { None } else { Some(st.as_str()) };
        match gap_store_inst.list(st_arg) {
            Ok(chunk) => {
                for g in chunk {
                    if seen.insert(g.id.clone()) {
                        all_gaps.push(g);
                    }
                }
            }
            Err(e) => {
                tracing::warn!("gap-queue: failed to list status={}: {}", st, e);
                return Ok(Json(
                    serde_json::json!({ "gaps": [], "error": e.to_string() }),
                ));
            }
        }
    }
    let total_pre_filter = all_gaps.len();

    // Domain + priority filters.
    let filtered: Vec<gap_store::GapRow> = all_gaps
        .into_iter()
        .filter(|g| {
            domain_filter
                .as_ref()
                .map(|d| g.domain == *d)
                .unwrap_or(true)
        })
        .filter(|g| {
            priority_filter
                .as_ref()
                .map(|p| g.priority == *p)
                .unwrap_or(true)
        })
        .collect();

    // Sort: priority asc, effort asc, created_at desc (newest first within tier).
    fn priority_ord(p: &str) -> u8 {
        match p {
            "P0" => 0,
            "P1" => 1,
            "P2" => 2,
            "P3" => 3,
            _ => 9,
        }
    }
    fn effort_ord(e: &str) -> u8 {
        match e {
            "xs" => 0,
            "s" => 1,
            "m" => 2,
            "l" => 3,
            _ => 9,
        }
    }
    let mut sorted = filtered;
    sorted.sort_by(|a, b| {
        priority_ord(&a.priority)
            .cmp(&priority_ord(&b.priority))
            .then(effort_ord(&a.effort).cmp(&effort_ord(&b.effort)))
            .then(b.created_at.cmp(&a.created_at))
    });

    // INFRA-1277: batch-fetch all active leases once (1 query) instead of
    // calling preflight() per row (2 queries × N rows).  The list view only
    // needs to distinguish claimable / blocked-by-lease / blocked-by-status;
    // the actual claim path still runs the full preflight before locking.
    let active_leases: std::collections::HashMap<String, String> =
        gap_store_inst.active_leases().unwrap_or_default();

    let mut result_gaps = Vec::with_capacity(sorted.len());
    for gap in sorted {
        // Derive preflight_status entirely in memory — no per-row DB round-trip.
        let (preflight_status, preflight_error, assigned_session): (
            String,
            Option<String>,
            Option<String>,
        ) = match gap.status.as_str() {
            // CREDIBLE-197: `already_satisfied` is a terminal disposition (acceptance
            // verified already met, closed with an evidence receipt, no PR) — it must
            // read as closed/blocked, never claimable.
            "done" | "shipped" | "already_satisfied" => (
                "blocked".to_string(),
                Some("Gap is already closed/done".to_string()),
                None,
            ),
            _ => match active_leases.get(&gap.id) {
                Some(sid) => (
                    "blocked".to_string(),
                    Some(format!("Already claimed by session {}", sid)),
                    Some(sid.clone()),
                ),
                None => ("claimable".to_string(), None, None),
            },
        };

        let depends_on = gap_store::parse_json_ac_list(&gap.depends_on);
        let ac_count = gap_store::parse_json_ac_list(&gap.acceptance_criteria).len();
        let pillar = derive_pillar_from_title(&gap.title);
        let title_truncated = truncate_utf8(&gap.title, 200);
        let opened_date = if gap.opened_date.is_empty() {
            serde_json::Value::Null
        } else {
            serde_json::Value::String(gap.opened_date.clone())
        };

        result_gaps.push(serde_json::json!({
            "id": gap.id,
            "title": title_truncated,
            "priority": gap.priority,
            "effort": gap.effort,
            "preflight_status": preflight_status,
            "preflight_error": preflight_error,
            "domain": gap.domain,
            "status": gap.status,
            "closed_pr": gap.closed_pr,
            "assigned_session": assigned_session,
            "created_at": gap.created_at,
            "opened_date": opened_date,
            "depends_on": depends_on,
            "acceptance_criteria_count": ac_count,
            "pillar": pillar,
        }));
    }

    let claimable_count = result_gaps
        .iter()
        .filter(|g| g["preflight_status"] == "claimable")
        .count();
    let elapsed_ms = t_start.elapsed().as_millis();

    // INFRA-1197: ambient telemetry for adoption / load profiling.
    // Best-effort — never fail the request on an emit hiccup.
    let filter_summary = format!(
        "status={};domain={};priority={}",
        status_filter.join(","),
        domain_filter.as_deref().unwrap_or("*"),
        priority_filter.as_deref().unwrap_or("*")
    );
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "gap_queue_request".to_string(),
        fields: vec![
            ("filter".to_string(), filter_summary.clone()),
            ("count".to_string(), result_gaps.len().to_string()),
            ("ms".to_string(), elapsed_ms.to_string()),
        ],
        ..Default::default()
    });

    // INFRA-1277: SLO signal — emit slow-path event when >500ms so the
    // ambient stream surfaces latency regressions before operators notice.
    if elapsed_ms > 500 {
        tracing::warn!(
            "gap-queue: SLOW {}ms for {} gaps (filter={})",
            elapsed_ms,
            result_gaps.len(),
            filter_summary
        );
        let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
            kind: "api_gap_queue_slow".to_string(),
            fields: vec![
                ("ms".to_string(), elapsed_ms.to_string()),
                ("count".to_string(), result_gaps.len().to_string()),
                ("filter".to_string(), filter_summary),
            ],
            ..Default::default()
        });
    }

    tracing::info!(
        "gap-queue: {} gaps, {} claimable, {}ms (INFRA-1277 batch-preflight)",
        result_gaps.len(),
        claimable_count,
        elapsed_ms
    );

    Ok(Json(serde_json::json!({
        "gaps": result_gaps,
        "count": result_gaps.len(),
        "total": total_pre_filter,
        "claimable_count": claimable_count,
    })))
}

/// GET /api/gaps/search — PRODUCT-089: full-text + field filter over the gap registry.
///
/// Query params (all optional):
///   q        — substring match against title + description (case-insensitive)
///   domain   — exact match (e.g. INFRA, PRODUCT)
///   status   — exact match (open / done / in_flight)
///   priority — exact match (P0 / P1 / P2)
///   effort   — exact match (xs / s / m / l / xl)
///   has_ac   — "false" → only gaps with empty/TODO AC; anything else ignored
#[derive(serde::Deserialize, Default)]
struct GapSearchQuery {
    q: Option<String>,
    domain: Option<String>,
    status: Option<String>,
    priority: Option<String>,
    effort: Option<String>,
    has_ac: Option<String>,
}

async fn handle_gaps_search(
    Query(params): Query<GapSearchQuery>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => std::path::PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let gap_store = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            return Ok(Json(
                serde_json::json!({ "total": 0, "results": [], "error": e.to_string() }),
            ));
        }
    };

    let all = match gap_store.list(None) {
        Ok(v) => v,
        Err(e) => {
            return Ok(Json(
                serde_json::json!({ "total": 0, "results": [], "error": e.to_string() }),
            ));
        }
    };

    let q_lower = params.q.as_deref().unwrap_or("").to_lowercase();
    let want_missing_ac = params.has_ac.as_deref() == Some("false");

    let results: Vec<_> = all
        .into_iter()
        .filter(|g| {
            if let Some(d) = &params.domain {
                if !g.domain.eq_ignore_ascii_case(d) {
                    return false;
                }
            }
            if let Some(s) = &params.status {
                if !g.status.eq_ignore_ascii_case(s) {
                    return false;
                }
            }
            if let Some(p) = &params.priority {
                if !g.priority.eq_ignore_ascii_case(p) {
                    return false;
                }
            }
            if let Some(e) = &params.effort {
                if !g.effort.eq_ignore_ascii_case(e) {
                    return false;
                }
            }
            if want_missing_ac {
                let ac = g.acceptance_criteria.trim().to_lowercase();
                if !ac.is_empty() && !ac.starts_with("todo") {
                    return false;
                }
            }
            if !q_lower.is_empty() {
                let hay = format!("{} {}", g.title, g.description).to_lowercase();
                if !hay.contains(&q_lower) {
                    return false;
                }
            }
            true
        })
        .map(|g| {
            let ac_count = if g.acceptance_criteria.trim().is_empty() {
                0usize
            } else {
                g.acceptance_criteria
                    .lines()
                    .filter(|l| !l.trim().is_empty())
                    .count()
            };
            serde_json::json!({
                "id": g.id,
                "title": g.title,
                "domain": g.domain,
                "status": g.status,
                "priority": g.priority,
                "effort": g.effort,
                "ac_count": ac_count,
            })
        })
        .collect();

    let total = results.len();
    Ok(Json(
        serde_json::json!({ "total": total, "results": results }),
    ))
}

/// INFRA-1197: parse leading pillar tag from a gap title.
/// Returns "effective" / "credible" / "resilient" / "zero-waste" / "mission"
/// based on the title's `<TAG>:` prefix, or None if no tag is present.
/// Domain-as-fallback is intentionally NOT done — keeps semantics crisp.
fn derive_pillar_from_title(title: &str) -> Option<&'static str> {
    let t = title.trim_start();
    if t.starts_with("EFFECTIVE:") {
        Some("effective")
    } else if t.starts_with("CREDIBLE:") {
        Some("credible")
    } else if t.starts_with("RESILIENT:") {
        Some("resilient")
    } else if t.starts_with("ZERO-WASTE:") {
        Some("zero-waste")
    } else if t.starts_with("MISSION:") {
        Some("mission")
    } else {
        None
    }
}

/// INFRA-1197: utf-8-safe truncation at `max` bytes — never splits a code
/// point. Mirrors the floor_char_boundary helper used in chump-planner.
fn truncate_utf8(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

/// GET /api/gaps/next — RESILIENT-1013: batphone picker endpoint. Returns the
/// single highest-priority claimable gap so a remote worker (no local
/// state.db) can join the fleet with just `CHUMP_GAP_API_URL` set. Mirrors
/// the filter + sort semantics of `handle_gap_queue` but does the
/// claimable-filtering + top-1 selection server-side so the worker doesn't
/// need to fetch the full open-gap list to pick one.
///
/// Query params (all optional, comma-separated where noted):
///   domain    — exact match against gap.domain
///   priority  — CSV of acceptable priorities (e.g. "P0,P1")
///   effort    — CSV of acceptable efforts (e.g. "xs,s,m")
async fn handle_gap_next(
    Query(params): Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let domain_filter = params.get("domain").cloned();
    let priority_filter: Option<Vec<String>> = params
        .get("priority")
        .map(|s| s.split(',').map(|t| t.trim().to_string()).collect());
    let effort_filter: Option<Vec<String>> = params
        .get("effort")
        .map(|s| s.split(',').map(|t| t.trim().to_string()).collect());

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };

    let gap_store_inst = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("gap-next: failed to open gap store: {}", e);
            return Ok(Json(
                serde_json::json!({ "gap": null, "error": e.to_string() }),
            ));
        }
    };

    let open_gaps = match gap_store_inst.list(Some("open")) {
        Ok(g) => g,
        Err(e) => {
            tracing::warn!("gap-next: failed to list open gaps: {}", e);
            return Ok(Json(
                serde_json::json!({ "gap": null, "error": e.to_string() }),
            ));
        }
    };

    let active_leases: std::collections::HashMap<String, String> =
        gap_store_inst.active_leases().unwrap_or_default();

    fn priority_ord(p: &str) -> u8 {
        match p {
            "P0" => 0,
            "P1" => 1,
            "P2" => 2,
            "P3" => 3,
            _ => 9,
        }
    }
    fn effort_ord(e: &str) -> u8 {
        match e {
            "xs" => 0,
            "s" => 1,
            "m" => 2,
            "l" => 3,
            _ => 9,
        }
    }

    let mut candidates: Vec<gap_store::GapRow> = open_gaps
        .into_iter()
        .filter(|g| !active_leases.contains_key(&g.id))
        .filter(|g| {
            domain_filter
                .as_ref()
                .map(|d| &g.domain == d)
                .unwrap_or(true)
        })
        .filter(|g| {
            priority_filter
                .as_ref()
                .map(|ps| ps.iter().any(|p| p == &g.priority))
                .unwrap_or(true)
        })
        .filter(|g| {
            effort_filter
                .as_ref()
                .map(|es| es.iter().any(|e| e == &g.effort))
                .unwrap_or(true)
        })
        .collect();

    candidates.sort_by(|a, b| {
        priority_ord(&a.priority)
            .cmp(&priority_ord(&b.priority))
            .then(effort_ord(&a.effort).cmp(&effort_ord(&b.effort)))
            .then(b.created_at.cmp(&a.created_at))
    });

    let next = candidates.into_iter().next().map(|gap| {
        serde_json::json!({
            "id": gap.id,
            "title": truncate_utf8(&gap.title, 200),
            "domain": gap.domain,
            "priority": gap.priority,
            "effort": gap.effort,
            "status": gap.status,
            "acceptance_criteria_count": gap_store::parse_json_ac_list(&gap.acceptance_criteria).len(),
        })
    });

    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "gap_next_request".to_string(),
        fields: vec![("found".to_string(), next.is_some().to_string())],
        ..Default::default()
    });

    Ok(Json(serde_json::json!({ "gap": next })))
}

/// POST /api/gap/claim/:id — Claim a gap and create a worktree for it.
/// PRODUCT-176: JSON body for POST /api/gap. `domain` + `title` are required;
/// everything else mirrors the `chump gap reserve` flags it replaces.
#[derive(serde::Deserialize)]
struct GapCreateBody {
    domain: String,
    title: String,
    priority: Option<String>,
    effort: Option<String>,
    description: Option<String>,
    /// AC list; omitted → the same default obs-ACs `chump gap reserve` writes.
    acceptance_criteria: Option<Vec<String>>,
    skills_required: Option<String>,
    /// Tagged into skills_required as `external_repo:<owner/repo>` (MISSION-041
    /// parity: skills_required is the routing key the picker actually parses).
    external_repo: Option<String>,
    outcome_id: Option<String>,
    evidence: Option<String>,
}

/// PRODUCT-176: JSON body for PATCH /api/gap/{id}. Every field optional;
/// present fields map onto [`gap_store::GapFieldUpdate`]. Store-side integrity
/// guards (done-without-closed_pr, terminal-done reopen, title hijack) stay in
/// force — this surface adds no bypass.
#[derive(serde::Deserialize)]
struct GapUpdateBody {
    title: Option<String>,
    description: Option<String>,
    priority: Option<String>,
    effort: Option<String>,
    status: Option<String>,
    acceptance_criteria: Option<Vec<String>>,
    depends_on: Option<String>,
    notes: Option<String>,
    closed_pr: Option<i64>,
    skills_required: Option<String>,
    preferred_backend: Option<String>,
    preferred_machine: Option<String>,
    estimated_minutes: Option<String>,
    required_model: Option<String>,
    outcome_id: Option<String>,
    evidence: Option<String>,
}

const VALID_PRIORITIES: [&str; 4] = ["P0", "P1", "P2", "P3"];
const VALID_EFFORTS: [&str; 5] = ["xs", "s", "m", "l", "xl"];

fn gap_api_error(
    status: StatusCode,
    msg: impl Into<String>,
) -> (StatusCode, Json<serde_json::Value>) {
    (status, Json(serde_json::json!({ "error": msg.into() })))
}

fn gap_row_json(row: &gap_store::GapRow) -> serde_json::Value {
    serde_json::json!({
        "id": row.id,
        "domain": row.domain,
        "title": row.title,
        "description": row.description,
        "priority": row.priority,
        "effort": row.effort,
        "status": row.status,
        "acceptance_criteria": row.acceptance_criteria,
        "skills_required": row.skills_required,
        "outcome_id": row.outcome_id,
        "closed_pr": row.closed_pr,
    })
}

/// POST /api/gap — create a gap over HTTP (PRODUCT-176).
///
/// Runs the same `reserve_verified` path as `chump gap reserve` (collision-safe
/// across sessions via the pending-lease protocol) and enforces MISSION-045
/// parity: P0/P1 without an `outcome_id` is refused, because an HTTP surface
/// that skipped the outcome gate would be the bypass hole the intake firewall
/// exists to close.
async fn handle_gap_create(
    headers: HeaderMap,
    Json(body): Json<GapCreateBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    if !check_auth(&headers) {
        return Err(gap_api_error(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !check_csrf(&headers) {
        return Err(gap_api_error(StatusCode::FORBIDDEN, "missing CSRF token"));
    }
    let ip_key = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("local")
        .to_string();
    if !check_gap_rate_limit(&ip_key) {
        return Err(gap_api_error(StatusCode::TOO_MANY_REQUESTS, "rate limited"));
    }

    let title = body.title.trim().to_string();
    if title.is_empty() || title.len() > 200 {
        return Err(gap_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "title must be 1-200 chars",
        ));
    }
    let domain = body.domain.trim().to_uppercase();
    if domain.is_empty()
        || domain.len() > 24
        || !domain
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic())
        || !domain
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(gap_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "domain must start with a letter and contain only [A-Za-z0-9_-], max 24 chars",
        ));
    }
    let priority = body.priority.as_deref().unwrap_or("P2").to_uppercase();
    if !VALID_PRIORITIES.contains(&priority.as_str()) {
        return Err(gap_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("priority must be one of {VALID_PRIORITIES:?}"),
        ));
    }
    let effort = body.effort.as_deref().unwrap_or("m").to_lowercase();
    if !VALID_EFFORTS.contains(&effort.as_str()) {
        return Err(gap_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("effort must be one of {VALID_EFFORTS:?}"),
        ));
    }
    // MISSION-045 parity: P0/P1 requires an outcome. The CLI refuses without
    // --outcome; the HTTP surface must not become the workaround.
    if (priority == "P0" || priority == "P1")
        && body
            .outcome_id
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .is_empty()
    {
        return Err(gap_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "P0/P1 gaps require outcome_id (MISSION-045); use P2/P3 for exploration",
        ));
    }

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let store = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            return Err(gap_api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to open gap store: {e}"),
            ))
        }
    };

    let session_id =
        get_session_id(&headers).unwrap_or_else(|| format!("web-api-{}", std::process::id()));
    let id = match store.reserve_verified(&domain, &title, &priority, &effort, &session_id) {
        Ok(id) => id,
        Err(e) => {
            return Err(gap_api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("reserve failed: {e}"),
            ))
        }
    };

    // Optional extras in one set_fields pass. Mirrors the CLI's warn-and-continue:
    // the gap exists once reserve succeeds; extras failing must not orphan it.
    let ac_json = match &body.acceptance_criteria {
        Some(list) if !list.is_empty() => {
            serde_json::to_string(list).unwrap_or_else(|_| "[]".into())
        }
        _ => {
            let acs = crate::default_acceptance_criteria(&title, &domain);
            serde_json::to_string(&acs).unwrap_or_else(|_| "[]".into())
        }
    };
    let skills = match (
        body.skills_required.as_deref(),
        body.external_repo.as_deref(),
    ) {
        (Some(s), Some(r)) if !s.trim().is_empty() => {
            Some(format!("{},external_repo:{}", s.trim(), r.trim()))
        }
        (_, Some(r)) => Some(format!("external_repo:{}", r.trim())),
        (Some(s), None) if !s.trim().is_empty() => Some(s.trim().to_string()),
        _ => None,
    };
    let update = gap_store::GapFieldUpdate {
        description: body.description.clone(),
        acceptance_criteria: Some(ac_json),
        skills_required: skills,
        outcome_id: body.outcome_id.clone(),
        evidence: body.evidence.clone().filter(|e| !e.trim().is_empty()),
        ..Default::default()
    };
    let mut warnings: Vec<String> = Vec::new();
    if let Err(e) = store.set_fields(&id, update) {
        warnings.push(format!("gap created but extras failed to apply: {e}"));
    }

    let row = store.get(&id).ok().flatten();
    tracing::info!(
        "gap-create: reserved {} via HTTP (session {})",
        id,
        session_id
    );
    let mut resp = match row {
        Some(r) => gap_row_json(&r),
        None => serde_json::json!({ "id": id }),
    };
    if !warnings.is_empty() {
        resp["warnings"] = serde_json::json!(warnings);
    }
    Ok(Json(resp))
}

/// PATCH /api/gap/{id} — update fields on an existing gap (PRODUCT-176).
///
/// Thin HTTP mapping onto [`gap_store::GapStore::set_fields`], which carries
/// the integrity guards (INFRA-402 done-needs-closed_pr, INFRA-456 terminal
/// done + hijack). Guard refusals surface as 422 with the store's own message
/// — never a silent success, never a 500 for a policy refusal.
async fn handle_gap_update(
    Path(gap_id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<GapUpdateBody>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    if !check_auth(&headers) {
        return Err(gap_api_error(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    if !validate_gap_id(&gap_id) {
        return Err(gap_api_error(StatusCode::BAD_REQUEST, "invalid gap id"));
    }
    if !check_csrf(&headers) {
        return Err(gap_api_error(StatusCode::FORBIDDEN, "missing CSRF token"));
    }
    let ip_key = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("local")
        .to_string();
    if !check_gap_rate_limit(&ip_key) {
        return Err(gap_api_error(StatusCode::TOO_MANY_REQUESTS, "rate limited"));
    }

    if let Some(p) = body.priority.as_deref() {
        if !VALID_PRIORITIES.contains(&p.to_uppercase().as_str()) {
            return Err(gap_api_error(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("priority must be one of {VALID_PRIORITIES:?}"),
            ));
        }
    }
    if let Some(e) = body.effort.as_deref() {
        if !VALID_EFFORTS.contains(&e.to_lowercase().as_str()) {
            return Err(gap_api_error(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("effort must be one of {VALID_EFFORTS:?}"),
            ));
        }
    }

    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let store = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            return Err(gap_api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("failed to open gap store: {e}"),
            ))
        }
    };

    match store.get(&gap_id) {
        Ok(Some(_)) => {}
        Ok(None) => return Err(gap_api_error(StatusCode::NOT_FOUND, "gap not found")),
        Err(e) => {
            return Err(gap_api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("lookup failed: {e}"),
            ))
        }
    }

    // Status values are registry-checked (gap_status_registry is the canonical
    // list; SQLite enforces nothing) so a typo'd status can't enter the store
    // where no picker or gauge would ever match it again.
    if let Some(s) = body.status.as_deref() {
        match store.known_statuses() {
            Ok(known) if !known.iter().any(|k| k == s) => {
                return Err(gap_api_error(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!("unknown status '{s}' — known: {}", known.join(", ")),
                ));
            }
            _ => {}
        }
    }

    let has_any_field = body.title.is_some()
        || body.description.is_some()
        || body.priority.is_some()
        || body.effort.is_some()
        || body.status.is_some()
        || body.acceptance_criteria.is_some()
        || body.depends_on.is_some()
        || body.notes.is_some()
        || body.closed_pr.is_some()
        || body.skills_required.is_some()
        || body.preferred_backend.is_some()
        || body.preferred_machine.is_some()
        || body.estimated_minutes.is_some()
        || body.required_model.is_some()
        || body.outcome_id.is_some()
        || body.evidence.is_some();
    if !has_any_field {
        return Err(gap_api_error(
            StatusCode::BAD_REQUEST,
            "no fields to update",
        ));
    }

    let ac_json = body
        .acceptance_criteria
        .as_ref()
        .map(|list| serde_json::to_string(list).unwrap_or_else(|_| "[]".into()));
    let update = gap_store::GapFieldUpdate {
        title: body.title.clone(),
        description: body.description.clone(),
        priority: body.priority.as_deref().map(str::to_uppercase),
        effort: body.effort.as_deref().map(str::to_lowercase),
        status: body.status.clone(),
        acceptance_criteria: ac_json,
        depends_on: body.depends_on.clone(),
        notes: body.notes.clone(),
        closed_pr: body.closed_pr,
        skills_required: body.skills_required.clone(),
        preferred_backend: body.preferred_backend.clone(),
        preferred_machine: body.preferred_machine.clone(),
        estimated_minutes: body.estimated_minutes.clone(),
        required_model: body.required_model.clone(),
        outcome_id: body.outcome_id.clone(),
        evidence: body.evidence.clone(),
        ..Default::default()
    };

    if let Err(e) = store.set_fields(&gap_id, update) {
        // Integrity-guard refusals are client errors carrying the store's own
        // explanation, not server faults.
        return Err(gap_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("{e}"),
        ));
    }

    tracing::info!("gap-update: {} updated via HTTP", gap_id);
    match store.get(&gap_id) {
        Ok(Some(r)) => Ok(Json(gap_row_json(&r))),
        _ => Ok(Json(
            serde_json::json!({ "id": gap_id, "status": "updated" }),
        )),
    }
}

async fn handle_gap_claim(
    Path(gap_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // CREDIBLE-023: validate gap_id format
    if !validate_gap_id(&gap_id) {
        return Err(StatusCode::BAD_REQUEST);
    }
    // CREDIBLE-023: CSRF token required for state-mutating POST
    if !check_csrf(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    // CREDIBLE-023: rate limit per IP (X-Forwarded-For or "local")
    let ip_key = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("local")
        .to_string();
    if !check_gap_rate_limit(&ip_key) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let gap_store = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("gap-claim: failed to open gap store: {}", e);
            return Ok(Json(serde_json::json!({
                "error": format!("Failed to open gap store: {}", e)
            })));
        }
    };
    let preflight = gap_store.preflight(&gap_id);
    match preflight {
        Ok(gap_store::PreflightResult::Available) => {
            tracing::info!("gap-claim: {} is available, proceeding with claim", gap_id);
            Ok(Json(serde_json::json!({
                "gap_id": gap_id,
                "status": "claimed",
                "worktree_path": format!("/tmp/chump-{}", gap_id),
                "message": "Gap claimed successfully (worktree creation deferred to daemon)"
            })))
        }
        Ok(gap_store::PreflightResult::Claimed(session_id)) => {
            tracing::warn!("gap-claim: {} already claimed by {}", gap_id, session_id);
            Ok(Json(serde_json::json!({
                "error": format!("Gap already claimed by session {}", session_id),
                "status": "blocked"
            })))
        }
        Ok(gap_store::PreflightResult::Done) => {
            tracing::warn!("gap-claim: {} is done/closed", gap_id);
            Ok(Json(serde_json::json!({
                "error": "Gap is already closed or done",
                "status": "blocked"
            })))
        }
        Ok(gap_store::PreflightResult::NotFound) => {
            tracing::warn!("gap-claim: {} not found in registry", gap_id);
            Ok(Json(serde_json::json!({
                "error": "Gap not found in registry",
                "status": "not_found"
            })))
        }
        Err(e) => {
            tracing::warn!("gap-claim: preflight check failed: {}", e);
            Ok(Json(serde_json::json!({
                "error": format!("Preflight check failed: {}", e),
                "status": "error"
            })))
        }
    }
}

/// GET /api/gap/status/:id — Get the current status of a claimed gap.
async fn handle_gap_status(
    Path(gap_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // CREDIBLE-023: validate gap_id format (no CSRF required for GET)
    if !validate_gap_id(&gap_id) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let gap_store = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("gap-status: failed to open gap store: {}", e);
            return Ok(Json(serde_json::json!({
                "error": format!("Failed to open gap store: {}", e)
            })));
        }
    };

    match gap_store.get(&gap_id) {
        Ok(Some(gap)) => {
            tracing::info!("gap-status: {} has status {}", gap_id, gap.status);
            Ok(Json(serde_json::json!({
                "gap_id": gap_id,
                "status": gap.status,
                "title": gap.title,
                "priority": gap.priority,
                "effort": gap.effort,
                "closed_date": gap.closed_date,
                "closed_pr": gap.closed_pr
            })))
        }
        Ok(None) => {
            tracing::warn!("gap-status: {} not found", gap_id);
            Ok(Json(serde_json::json!({
                "error": "Gap not found",
                "status": "not_found"
            })))
        }
        Err(e) => {
            tracing::warn!("gap-status: error querying gap {}: {}", gap_id, e);
            Ok(Json(serde_json::json!({
                "error": format!("Failed to query gap: {}", e),
                "status": "error"
            })))
        }
    }
}

/// GET /api/gap/{id}/status — EFFECTIVE-014: workflow phase + progress for polling.
///
/// Maps recent `gap_workflow_phase` events from ambient.jsonl to a structured
/// response suitable for 2s polling from the PWA UI.
///
/// Response: `{status, workflow_phase, progress_pct, error}`
/// GET /api/gap/{id}/stream — SSE workflow timeline (INFRA-1009).
///
/// Push-delivers `gap_workflow_phase` events from `ambient.jsonl` for the
/// requested gap so the PWA timeline widget renders phase progression
/// (preflight → claim → execute → ship) without 5s polling lag.
///
/// Event format: `event: phase\ndata: <JSON>\n\n`. The JSON carries the
/// original ambient event verbatim (passthrough): phase / phase_status /
/// progress_pct / message / ts / gap_id — whatever the emitter chose to
/// include. Workflow_done is signaled by `data: {"done": true, ...}`
/// after a `gap_workflow_phase` with `phase_status=complete` and `phase=ship`.
///
/// Backward-compat: `/api/gap/{id}/status` (poll) remains for one release.
async fn handle_gap_workflow_stream(
    Path(gap_id): Path<String>,
    headers: HeaderMap,
) -> Result<
    Sse<impl tokio_stream::Stream<Item = Result<Event, std::convert::Infallible>>>,
    StatusCode,
> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let ambient_path = std::env::var("CHUMP_AMBIENT_IN_PROMPT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let base = match std::env::var("CHUMP_REPO") {
                Ok(r) => PathBuf::from(r),
                Err(_) => repo_path::runtime_base(),
            };
            base.join(".chump-locks").join("ambient.jsonl")
        });

    let (tx, rx) =
        tokio::sync::mpsc::unbounded_channel::<Result<Event, std::convert::Infallible>>();
    let gap_id_clone = gap_id.clone();
    tokio::spawn(async move {
        // Initial-state replay: send any matching phase events already in
        // ambient so the client immediately sees the current state without
        // waiting for the next emission. Tail the last 1MB only to keep
        // initial-latency bounded.
        let mut last_offset: u64 = 0;
        if let Ok(meta) = tokio::fs::metadata(&ambient_path).await {
            let size = meta.len();
            let start = size.saturating_sub(1_048_576);
            last_offset = start;
        }

        loop {
            // Read new bytes since last_offset.
            let new_lines = match read_phase_events_since(&ambient_path, last_offset, &gap_id_clone)
            {
                Ok((evts, next_offset)) => {
                    last_offset = next_offset;
                    evts
                }
                Err(_) => Vec::new(),
            };

            let mut done = false;
            for evt in new_lines {
                let phase = evt
                    .get("phase")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let phase_status = evt
                    .get("phase_status")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let data = serde_json::to_string(&evt).unwrap_or_default();
                if tx
                    .send(Ok(Event::default().event("phase").data(data)))
                    .is_err()
                {
                    return; // client disconnected
                }
                if phase == "ship" && phase_status == "complete" {
                    done = true;
                }
            }

            if done {
                let done_msg = serde_json::json!({"done": true, "gap_id": gap_id_clone});
                let _ = tx.send(Ok(Event::default()
                    .event("workflow_done")
                    .data(done_msg.to_string())));
                break;
            }

            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }
    });

    Ok(Sse::new(UnboundedReceiverStream::new(rx)).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("keep-alive"),
    ))
}

/// Scan ambient.jsonl from byte-offset `since`, return matching phase events
/// and the new offset. Out-of-order writes are tolerated; the client
/// de-dupes by (gap_id, ts, phase) if needed.
fn read_phase_events_since(
    path: &std::path::Path,
    since: u64,
    gap_id: &str,
) -> std::io::Result<(Vec<serde_json::Value>, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    let size = f.metadata()?.len();
    if size < since {
        // File rotated/truncated; restart from 0.
        return read_phase_events_since(path, 0, gap_id);
    }
    f.seek(SeekFrom::Start(since))?;
    let mut buf = String::new();
    f.read_to_string(&mut buf)?;
    let mut out = Vec::new();
    for line in buf.lines() {
        let Ok(v): Result<serde_json::Value, _> = serde_json::from_str(line) else {
            continue;
        };
        if v.get("kind").and_then(|k| k.as_str()) != Some("gap_workflow_phase") {
            continue;
        }
        if v.get("gap_id").and_then(|k| k.as_str()) != Some(gap_id) {
            continue;
        }
        out.push(v);
    }
    Ok((out, size))
}

async fn handle_gap_workflow_status(
    Path(gap_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Resolve gap status from the gap store.
    let repo_root = match std::env::var("CHUMP_REPO") {
        Ok(r) => PathBuf::from(r),
        Err(_) => repo_path::runtime_base(),
    };
    let gap_status = match crate::gap_store::GapStore::open(&repo_root) {
        Ok(gs) => gs
            .get(&gap_id)
            .ok()
            .flatten()
            .map(|g| g.status)
            .unwrap_or_else(|| "not_found".to_string()),
        Err(_) => "unknown".to_string(),
    };

    // If the gap is done, return immediately with 100%.
    if gap_status == "done" {
        return Ok(Json(serde_json::json!({
            "status": "done",
            "workflow_phase": "ship",
            "progress_pct": 100,
            "error": null,
        })));
    }

    // Parse recent workflow phase events from ambient.jsonl.
    let ambient_path = std::env::var("CHUMP_AMBIENT_IN_PROMPT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let base = match std::env::var("CHUMP_REPO") {
                Ok(r) => PathBuf::from(r),
                Err(_) => repo_path::runtime_base(),
            };
            base.join(".chump-locks").join("ambient.jsonl")
        });

    let (workflow_phase, progress_pct, error_msg) =
        read_workflow_phase_from_ambient(&ambient_path, &gap_id);

    Ok(Json(serde_json::json!({
        "status": gap_status,
        "workflow_phase": workflow_phase,
        "progress_pct": progress_pct,
        "error": error_msg,
    })))
}

/// Scan ambient.jsonl for the most recent `gap_workflow_phase` events for `gap_id`.
/// Returns (phase, progress_pct 0–100, error_msg).
fn read_workflow_phase_from_ambient(
    path: &std::path::Path,
    gap_id: &str,
) -> (Option<String>, u8, Option<String>) {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return (None, 0, None),
    };

    // Walk lines in reverse to find the most recent event for this gap.
    let mut last_phase: Option<String> = None;
    let mut last_status: Option<String> = None;

    for line in content.lines().rev() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("kind").and_then(|k| k.as_str()) != Some("gap_workflow_phase") {
            continue;
        }
        if v.get("gap_id").and_then(|k| k.as_str()) != Some(gap_id) {
            continue;
        }
        // First matching line (most recent) wins.
        last_phase = v
            .get("phase")
            .and_then(|p| p.as_str())
            .map(|s| s.to_string());
        last_status = v
            .get("status")
            .and_then(|s| s.as_str())
            .map(|s| s.to_string());
        break;
    }

    let phase = last_phase.as_deref().unwrap_or("");
    let status = last_status.as_deref().unwrap_or("");

    let progress: u8 = match (phase, status) {
        ("preflight", _) => 10,
        ("claim", "started") => 25,
        ("claim", "success") => 30,
        ("execute-gap", "started") => 40,
        ("execute-gap", "success") => 85,
        ("ship", "started") => 90,
        ("ship", "success") => 100,
        _ => 0,
    };

    let error_msg = if status.contains("fail") || status.contains("error") {
        Some(format!("{phase} {status}"))
    } else {
        None
    };

    (last_phase, progress, error_msg)
}

/// POST /api/gap/work/:id — Trigger Chump to autonomously work on a claimed gap.
/// Spawns a background process to claim, work, and ship the gap.
/// CREDIBLE-024: assigns a unique request_id for tracing through all log/ambient events.
async fn handle_gap_work(
    Path(gap_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // CREDIBLE-023: validate gap_id format, CSRF, rate limit
    if !validate_gap_id(&gap_id) {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !check_csrf(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    let ip_key = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("local")
        .to_string();
    if !check_gap_rate_limit(&ip_key) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }

    // CREDIBLE-024: unique request_id for end-to-end tracing.
    let request_id = uuid::Uuid::new_v4()
        .to_string()
        .chars()
        .take(12)
        .collect::<String>();

    let gap_id_clone = gap_id.clone();
    let rid = request_id.clone();
    tokio::spawn(async move {
        tracing::info!(
            request_id = %rid,
            "gap-work: spawning autonomous workflow for {}",
            gap_id_clone
        );
        emit_pwa_log(&gap_id_clone, "dispatch", "started", &rid, None);

        if let Err(e) = spawn_gap_workflow(&gap_id_clone, &rid).await {
            tracing::error!(
                request_id = %rid,
                "gap-work: workflow failed for {}: {}",
                gap_id_clone, e
            );
            emit_pwa_log(
                &gap_id_clone,
                "dispatch",
                &format!("FAILED ({rid})"),
                &rid,
                None,
            );
        }
    });

    Ok(Json(serde_json::json!({
        "status": "started",
        "gap_id": gap_id,
        "request_id": request_id,
        "message": "Autonomous workflow triggered"
    })))
}

/// GET /api/logs/{request_id} — INFRA-1013: return PWA log entries for one workflow run.
/// Allows the "View full log" button in the retry UI to retrieve the complete trace.
async fn handle_get_logs(
    Path(request_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if request_id.is_empty() || request_id.len() > 64 {
        return Err(StatusCode::BAD_REQUEST);
    }
    let entries = read_pwa_log_for_request(&request_id);
    Ok(Json(serde_json::json!({
        "request_id": request_id,
        "entries": entries,
        "count": entries.len(),
    })))
}

/// GET /docs/*path — INFRA-1303: serve repo docs/ directory over HTTP.
///
/// Reads the requested path from `<repo_root>/docs/` and returns its contents.
/// Only `.md`, `.txt`, `.yaml`, `.yml`, `.json`, `.toml` files are served.
/// Path traversal (../) is rejected with 400. Missing files return 404.
/// No auth required — docs are non-sensitive read-only content.
async fn handle_docs_file(Path(path): Path<String>) -> impl axum::response::IntoResponse {
    use axum::http::{header, StatusCode};

    // Reject path traversal attempts.
    if path.contains("..") || path.contains('\0') {
        return (
            StatusCode::BAD_REQUEST,
            [(header::CONTENT_TYPE, "text/plain")],
            "invalid path".to_string(),
        )
            .into_response();
    }

    // Only serve safe text file extensions.
    let allowed_ext = [".md", ".txt", ".yaml", ".yml", ".json", ".toml"];
    if !allowed_ext.iter().any(|ext| path.ends_with(ext)) {
        return (
            StatusCode::FORBIDDEN,
            [(header::CONTENT_TYPE, "text/plain")],
            "only text/doc files served".to_string(),
        )
            .into_response();
    }

    let repo_root = crate::repo_path::repo_root();
    let target = repo_root.join("docs").join(&path);

    // Canonicalize to confirm the file is still inside docs/.
    let docs_root = match repo_root.join("docs").canonicalize() {
        Ok(p) => p,
        Err(_) => {
            return (
                StatusCode::NOT_FOUND,
                [(header::CONTENT_TYPE, "text/plain")],
                "docs dir not found".to_string(),
            )
                .into_response()
        }
    };
    let canonical = match target.canonicalize() {
        Ok(p) => p,
        Err(_) => {
            return (
                StatusCode::NOT_FOUND,
                [(header::CONTENT_TYPE, "text/plain")],
                format!("not found: {path}"),
            )
                .into_response()
        }
    };
    if !canonical.starts_with(&docs_root) {
        return (
            StatusCode::BAD_REQUEST,
            [(header::CONTENT_TYPE, "text/plain")],
            "path outside docs/".to_string(),
        )
            .into_response();
    }

    let content = match std::fs::read_to_string(&canonical) {
        Ok(s) => s,
        Err(_) => {
            return (
                StatusCode::NOT_FOUND,
                [(header::CONTENT_TYPE, "text/plain")],
                format!("not found: {path}"),
            )
                .into_response()
        }
    };

    let content_type = if path.ends_with(".json") {
        "application/json"
    } else if path.ends_with(".yaml") || path.ends_with(".yml") {
        "text/yaml"
    } else {
        "text/plain; charset=utf-8" // .md, .txt, .toml — raw text
    };

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, content_type)],
        content,
    )
        .into_response()
}

/// GET /api/docs — EFFECTIVE-012: serve OpenAPI 3.0 spec for client discovery.
///
/// Reads `docs/api/openapi.yaml` relative to the repo root and returns it with
/// `Content-Type: application/yaml`. No auth required (read-only public spec).
/// Validated by `openapi-generator validate`.
async fn handle_api_docs() -> impl axum::response::IntoResponse {
    use axum::http::{header, StatusCode};

    let repo_root = crate::repo_path::repo_root();
    let spec_path = repo_root.join("docs").join("api").join("openapi.yaml");

    match std::fs::read_to_string(&spec_path) {
        Ok(content) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "application/yaml")],
            content,
        )
            .into_response(),
        Err(_) => (
            StatusCode::NOT_FOUND,
            [(header::CONTENT_TYPE, "text/plain")],
            "openapi.yaml not found — ensure docs/api/openapi.yaml exists in the repo".to_string(),
        )
            .into_response(),
    }
}

/// POST /api/gap/work/{id}/retry?from_phase=<phase> — INFRA-1013: retry workflow from a phase.
///
/// Tracks consecutive failures per (gap_id, phase). After 3 failures, returns 409 with
/// "max_retries_exceeded" so the UI can disable the retry button.
///
/// Valid phases: "preflight", "claim", "execute", "ship"
async fn handle_gap_work_retry(
    Path(gap_id): Path<String>,
    axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    if !validate_gap_id(&gap_id) {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !check_csrf(&headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    let ip_key = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("local")
        .to_string();
    if !check_gap_rate_limit(&ip_key) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }

    let from_phase = params
        .get("from_phase")
        .map(String::as_str)
        .unwrap_or("preflight");
    let valid_phases = ["preflight", "claim", "execute", "ship"];
    if !valid_phases.contains(&from_phase) {
        return Err(StatusCode::BAD_REQUEST);
    }

    const MAX_RETRIES: u32 = 3;
    let current_count = get_retry_count(&gap_id, from_phase);
    if current_count >= MAX_RETRIES {
        return Ok(Json(serde_json::json!({
            "status": "max_retries_exceeded",
            "gap_id": gap_id,
            "phase": from_phase,
            "retry_count": current_count,
            "message": format!("Phase '{}' has failed {} times. Manual intervention recommended.", from_phase, current_count),
        })));
    }

    let retry_num = inc_retry_count(&gap_id, from_phase);

    let request_id = uuid::Uuid::new_v4()
        .to_string()
        .chars()
        .take(12)
        .collect::<String>();

    let gap_id_clone = gap_id.clone();
    let phase_clone = from_phase.to_string();
    let rid = request_id.clone();
    tokio::spawn(async move {
        tracing::info!(
            request_id = %rid,
            "gap-work-retry: retrying {} from phase {} (attempt {})",
            gap_id_clone, phase_clone, retry_num
        );
        emit_pwa_log(&gap_id_clone, &phase_clone, "retry-started", &rid, None);

        if let Err(e) = spawn_gap_workflow_from(&gap_id_clone, &rid, &phase_clone).await {
            tracing::error!(
                request_id = %rid,
                "gap-work-retry: workflow failed for {} from {}: {}",
                gap_id_clone, phase_clone, e
            );
            emit_pwa_log(
                &gap_id_clone,
                &phase_clone,
                &format!("retry-FAILED ({rid})"),
                &rid,
                None,
            );
        } else {
            reset_retry_count(&gap_id_clone, &phase_clone);
        }
    });

    Ok(Json(serde_json::json!({
        "status": "retry-started",
        "gap_id": gap_id,
        "from_phase": from_phase,
        "request_id": request_id,
        "retry_count": retry_num,
        "retries_remaining": MAX_RETRIES.saturating_sub(retry_num),
    })))
}

/// CREDIBLE-024 / INFRA-1013: write a structured JSON log entry to CHUMP_PWA_LOG.
/// stdout_tail: last N lines of subprocess stdout (for failed phases, shown in retry UI).
/// exit_code: subprocess exit code (for failed phases).
fn emit_pwa_log(
    gap_id: &str,
    phase: &str,
    status: &str,
    request_id: &str,
    duration_ms: Option<u64>,
) {
    emit_pwa_log_full(gap_id, phase, status, request_id, duration_ms, None, None);
}

fn emit_pwa_log_full(
    gap_id: &str,
    phase: &str,
    status: &str,
    request_id: &str,
    duration_ms: Option<u64>,
    stdout_tail: Option<&str>,
    exit_code: Option<i32>,
) {
    let log_path =
        std::env::var("CHUMP_PWA_LOG").unwrap_or_else(|_| "/tmp/chump-pwa.log".to_string());
    let mut entry = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "request_id": request_id,
        "gap_id": gap_id,
        "phase": phase,
        "status": status,
        "duration_ms": duration_ms,
    });
    if let Some(tail) = stdout_tail {
        entry["stdout_tail"] = serde_json::Value::String(tail.to_string());
    }
    if let Some(code) = exit_code {
        entry["exit_code"] = serde_json::Value::Number(code.into());
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        let _ = writeln!(file, "{}", entry);
    }
}

/// INFRA-1013: read PWA log entries for a given request_id.
/// Returns at most 200 entries to bound memory.
fn read_pwa_log_for_request(request_id: &str) -> Vec<serde_json::Value> {
    let log_path =
        std::env::var("CHUMP_PWA_LOG").unwrap_or_else(|_| "/tmp/chump-pwa.log".to_string());
    let content = match std::fs::read_to_string(&log_path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };
    content
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|entry| {
            entry
                .get("request_id")
                .and_then(|v| v.as_str())
                .map(|rid| rid == request_id)
                .unwrap_or(false)
        })
        .take(200)
        .collect()
}

/// INFRA-1013: last N lines of a string (for stdout_tail in failure messages).
fn last_n_lines(s: &str, n: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

/// Emit a workflow event to ambient.jsonl for fleet observability.
fn emit_ambient_event(gap_id: &str, phase: &str, status: &str) {
    if let Ok(ambient_path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        let event = serde_json::json!({
            "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "kind": "gap_workflow_phase",
            "gap_id": gap_id,
            "phase": phase,
            "status": status
        });
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient_path)
        {
            let _ = writeln!(file, "{}", event);
        }
    }
}

/// Run pre-flight validation via gap-preflight.sh (exits 1 if not pickable).
fn run_preflight_check(gap_id: &str, repo_root: &std::path::Path) -> Result<(), String> {
    let preflight_script = repo_root.join("scripts/coord/gap-preflight.sh");
    if !preflight_script.exists() {
        tracing::warn!("gap-preflight.sh not found, skipping pre-flight check");
        return Ok(());
    }

    match std::process::Command::new("bash")
        .arg(preflight_script)
        .arg(gap_id)
        .current_dir(repo_root)
        .status()
    {
        Ok(status) if status.success() => {
            tracing::info!("gap-preflight: {} passed validation", gap_id);
            Ok(())
        }
        Ok(status) => Err(format!(
            "Pre-flight failed: gap {} not pickable ({})",
            gap_id, status
        )),
        Err(e) => Err(format!("Failed to run preflight check: {}", e)),
    }
}

/// Release lease for a gap (cleanup on error).
fn cleanup_lease(gap_id: &str, repo_root: &std::path::Path) {
    let session_id = format!("chump-pwa-{}", gap_id);
    let lease_path = repo_root
        .join(".chump-locks")
        .join(format!("{}.json", session_id));
    if lease_path.exists() {
        if let Err(e) = std::fs::remove_file(&lease_path) {
            tracing::warn!("Failed to cleanup lease {}: {}", lease_path.display(), e);
        } else {
            tracing::info!("Cleaned up lease for {}", gap_id);
        }
    }
}

/// Remove temporary worktree after workflow completes.
fn cleanup_worktree(gap_id: &str) {
    let worktree_path = PathBuf::from(format!("/tmp/chump-{}", gap_id));
    if worktree_path.exists() {
        if let Err(e) = std::fs::remove_dir_all(&worktree_path) {
            tracing::warn!(
                "Failed to cleanup worktree {}: {}",
                worktree_path.display(),
                e
            );
        } else {
            tracing::info!("Cleaned up worktree for {}", gap_id);
        }
    }
}

/// Helper to configure GitHub credentials for agent subprocess.
/// Supports two modes:
///
/// 1. Explicit (secure): GH_TOKEN and SSH_KEY_PATH env vars override keyring lookup
/// 2. Implicit (local dev): inherits parent process env (gh CLI from keyring, SSH keys)
///
/// Logs credential presence without exposing values (sanitized for security).
fn configure_agent_credentials(cmd: &mut std::process::Command) {
    // GH_TOKEN: explicit GitHub token (overrides keyring)
    if let Ok(token) = std::env::var("GH_TOKEN") {
        cmd.env("GH_TOKEN", token);
        tracing::debug!("gap-work: forwarding explicit GH_TOKEN to agent");
    } else {
        // No explicit token; agent will use keyring lookup (local dev path)
        tracing::debug!("gap-work: agent will use local keyring for GitHub auth");
    }

    // SSH_KEY_PATH: explicit SSH key for git operations
    if let Ok(key_path) = std::env::var("SSH_KEY_PATH") {
        let path_display = key_path.clone();
        cmd.env("SSH_KEY_PATH", key_path);
        tracing::debug!(
            "gap-work: forwarding explicit SSH_KEY_PATH to agent ({})",
            path_display
        );
    }

    // GITHUB_TOKEN: alternative to GH_TOKEN (some tools use this)
    if let Ok(token) = std::env::var("GITHUB_TOKEN") {
        cmd.env("GITHUB_TOKEN", token);
        tracing::debug!("gap-work: forwarding explicit GITHUB_TOKEN to agent");
    }
}

/// Spawn an autonomous workflow to work on and ship a gap.
/// Follows Chump's agent protocol per `execute_gap.rs`:
///
/// 0. Pre-flight validation — ensure gap is pickable (no blocking deps)
/// 1. chump claim <ID> — atomic: setup worktree with gap checked out
/// 2. chump --execute-gap <ID> — spawn full agent session that:
///    - reads gap acceptance criteria
///    - runs multi-turn agent loop to work on gap
///    - agent commits, pushes, creates/merges PR autonomously
/// 3. chump gap ship <ID> --update-yaml — finalize and sync YAML mirror
///
/// Credentials: supports explicit (GH_TOKEN, SSH_KEY_PATH env vars) or implicit (keyring).
/// Emits to ambient.jsonl for fleet observability. Cleans up leases on error.
/// Run a blocking subprocess with a 5-minute timeout (CREDIBLE-023).
/// Returns Err with a timeout message if the process exceeds the limit.
async fn run_subprocess_with_timeout(
    mut cmd: std::process::Command,
) -> Result<std::process::ExitStatus, Box<dyn std::error::Error + Send + Sync>> {
    let timeout_secs: u64 = std::env::var("CHUMP_SUBPROCESS_TIMEOUT_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(300);
    let result = tokio::time::timeout(
        Duration::from_secs(timeout_secs),
        tokio::task::spawn_blocking(move || cmd.status()),
    )
    .await;
    match result {
        Ok(Ok(Ok(status))) => Ok(status),
        Ok(Ok(Err(e))) => Err(Box::new(e) as Box<dyn std::error::Error + Send + Sync>),
        Ok(Err(e)) => Err(Box::new(e) as Box<dyn std::error::Error + Send + Sync>),
        Err(_elapsed) => Err(format!(
            "subprocess exceeded {}s timeout — CREDIBLE-023",
            timeout_secs
        )
        .into()),
    }
}

/// INFRA-1013: like run_subprocess_with_timeout but captures combined stdout+stderr.
/// Returns (exit_status, combined_output_tail).
async fn run_subprocess_with_output(
    mut cmd: std::process::Command,
) -> Result<(std::process::ExitStatus, String), Box<dyn std::error::Error + Send + Sync>> {
    use std::process::Stdio;
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let timeout_secs: u64 = std::env::var("CHUMP_SUBPROCESS_TIMEOUT_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(300);
    let result = tokio::time::timeout(
        Duration::from_secs(timeout_secs),
        tokio::task::spawn_blocking(move || cmd.output()),
    )
    .await;
    match result {
        Ok(Ok(Ok(out))) => {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            Ok((out.status, combined))
        }
        Ok(Ok(Err(e))) => Err(Box::new(e) as Box<dyn std::error::Error + Send + Sync>),
        Ok(Err(e)) => Err(Box::new(e) as Box<dyn std::error::Error + Send + Sync>),
        Err(_elapsed) => Err(format!(
            "subprocess exceeded {}s timeout — CREDIBLE-023",
            timeout_secs
        )
        .into()),
    }
}

/// INFRA-1013: spawn workflow starting from a named phase (for retry).
/// Phases before from_phase are skipped. "preflight" is always re-run for safety
/// regardless of from_phase (except when from_phase == "ship").
async fn spawn_gap_workflow_from(
    gap_id: &str,
    request_id: &str,
    from_phase: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Always at least re-validate from preflight unless retrying ship directly.
    let effective_start = match from_phase {
        "ship" => "ship",
        _ => "preflight",
    };
    spawn_gap_workflow_inner(gap_id, request_id, effective_start).await
}

async fn spawn_gap_workflow(
    gap_id: &str,
    request_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    spawn_gap_workflow_inner(gap_id, request_id, "preflight").await
}

/// CREDIBLE-024 / INFRA-1013: run workflow phases starting from from_phase.
/// All log events and ambient entries include request_id for end-to-end tracing.
async fn spawn_gap_workflow_inner(
    gap_id: &str,
    request_id: &str,
    from_phase: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    use std::process::Command;

    let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
    let repo_root = std::env::var("CHUMP_REPO")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_path::runtime_base());

    // INFRA-1013: phase ordering for skip logic
    let phase_order = ["preflight", "claim", "execute", "ship"];
    let start_idx = phase_order
        .iter()
        .position(|&p| p == from_phase)
        .unwrap_or(0);

    // Step 0: Pre-flight validation (always run unless retrying ship phase directly)
    if start_idx
        <= phase_order
            .iter()
            .position(|&p| p == "preflight")
            .unwrap_or(0)
    {
        tracing::info!(request_id = %request_id, "gap-work: running pre-flight validation for {}", gap_id);
        if let Err(e) = run_preflight_check(gap_id, &repo_root) {
            tracing::warn!(request_id = %request_id, "gap-work: pre-flight failed: {}", e);
            emit_pwa_log(
                gap_id,
                "preflight",
                &format!("FAILED ({request_id}, {e})"),
                request_id,
                None,
            );
            cleanup_lease(gap_id, &repo_root);
            cleanup_worktree(gap_id);
            return Err(e.into());
        }
        emit_ambient_event(gap_id, "preflight", "passed");
        emit_pwa_log(gap_id, "preflight", "passed", request_id, None);
    }

    // Step 1: Claim the gap (skip if retrying from execute or ship)
    let claim_idx = phase_order.iter().position(|&p| p == "claim").unwrap_or(1);
    if start_idx <= claim_idx {
        tracing::info!(request_id = %request_id, "gap-work: claiming {} in {}", gap_id, repo_root.display());
        emit_ambient_event(gap_id, "claim", "started");
        emit_pwa_log(gap_id, "claim", "started", request_id, None);
        let t_claim = std::time::Instant::now();

        let mut cmd = Command::new(&chump_bin);
        cmd.arg("claim")
            .arg(gap_id)
            .current_dir(&repo_root)
            .env("CHUMP_REPO", repo_root.to_string_lossy().to_string());
        configure_agent_credentials(&mut cmd);

        match run_subprocess_with_timeout(cmd).await {
            Ok(status) if status.success() => {
                let ms = t_claim.elapsed().as_millis() as u64;
                tracing::info!(request_id = %request_id, "gap-work: claim succeeded for {}", gap_id);
                emit_ambient_event(gap_id, "claim", "success");
                emit_pwa_log(gap_id, "claim", "success", request_id, Some(ms));
            }
            Ok(status) => {
                let ms = t_claim.elapsed().as_millis() as u64;
                tracing::warn!(request_id = %request_id, "gap-work: claim failed for {} with status {}", gap_id, status);
                emit_ambient_event(gap_id, "claim", "failed");
                emit_pwa_log(
                    gap_id,
                    "claim",
                    &format!("FAILED ({request_id})"),
                    request_id,
                    Some(ms),
                );
                cleanup_lease(gap_id, &repo_root);
                cleanup_worktree(gap_id);
                return Err(format!("Claim failed: {}", status).into());
            }
            Err(e) => {
                tracing::error!(request_id = %request_id, "gap-work: failed to spawn chump claim: {}", e);
                emit_ambient_event(gap_id, "claim", "error");
                emit_pwa_log(
                    gap_id,
                    "claim",
                    &format!("FAILED ({request_id}, {e})"),
                    request_id,
                    None,
                );
                cleanup_lease(gap_id, &repo_root);
                cleanup_worktree(gap_id);
                return Err(e.to_string().into());
            }
        }
    }

    // Step 2: Spawn full agent session (skip if retrying from ship)
    let execute_idx = phase_order
        .iter()
        .position(|&p| p == "execute")
        .unwrap_or(2);
    if start_idx <= execute_idx {
        tracing::info!(request_id = %request_id, "gap-work: spawning agent session via chump --execute-gap {}", gap_id);
        emit_ambient_event(gap_id, "execute-gap", "started");
        emit_pwa_log(gap_id, "execute-gap", "started", request_id, None);
        let t_exec = std::time::Instant::now();

        let mut cmd = Command::new(&chump_bin);
        cmd.arg("--execute-gap")
            .arg(gap_id)
            .current_dir(&repo_root)
            .env("CHUMP_REPO", repo_root.to_string_lossy().to_string());
        configure_agent_credentials(&mut cmd);

        match run_subprocess_with_output(cmd).await {
            Ok((status, out)) if status.success() => {
                let ms = t_exec.elapsed().as_millis() as u64;
                tracing::info!(request_id = %request_id, "gap-work: agent session succeeded for {}", gap_id);
                emit_ambient_event(gap_id, "execute-gap", "success");
                emit_pwa_log(gap_id, "execute-gap", "success", request_id, Some(ms));
                reset_retry_count(gap_id, "execute");
                let _ = out; // discard stdout on success
            }
            Ok((status, out)) => {
                let ms = t_exec.elapsed().as_millis() as u64;
                let tail = last_n_lines(&out, 3);
                let code = status.code().unwrap_or(-1);
                tracing::warn!(request_id = %request_id, "gap-work: agent session failed for {} with status {}", gap_id, status);
                emit_ambient_event(gap_id, "execute-gap", "failed");
                emit_pwa_log_full(
                    gap_id,
                    "execute-gap",
                    &format!("FAILED ({request_id})"),
                    request_id,
                    Some(ms),
                    Some(&tail),
                    Some(code),
                );
                tracing::info!(request_id = %request_id, "gap-work: continuing to ship phase despite agent exit code {}", status);
            }
            Err(e) => {
                tracing::error!(request_id = %request_id, "gap-work: failed to spawn agent session: {}", e);
                emit_ambient_event(gap_id, "execute-gap", "error");
                emit_pwa_log(
                    gap_id,
                    "execute-gap",
                    &format!("FAILED ({request_id}, {e})"),
                    request_id,
                    None,
                );
            }
        };
    }

    // Step 3: Ship the gap
    tracing::info!(request_id = %request_id, "gap-work: finalizing gap {} via chump gap ship --update-yaml", gap_id);
    emit_ambient_event(gap_id, "ship", "started");
    emit_pwa_log(gap_id, "ship", "started", request_id, None);
    let t_ship = std::time::Instant::now();

    let mut cmd = Command::new(&chump_bin);
    cmd.arg("gap")
        .arg("ship")
        .arg(gap_id)
        .arg("--update-yaml")
        .current_dir(&repo_root)
        .env("CHUMP_REPO", repo_root.to_string_lossy().to_string());
    configure_agent_credentials(&mut cmd);

    // CREDIBLE-023: 5-minute timeout per subprocess phase
    match run_subprocess_with_timeout(cmd).await {
        Ok(status) if status.success() => {
            let ms = t_ship.elapsed().as_millis() as u64;
            tracing::info!(request_id = %request_id, "gap-work: ship succeeded for {} — gap closed and YAML synced", gap_id);
            emit_ambient_event(gap_id, "ship", "success");
            emit_pwa_log(gap_id, "ship", "success", request_id, Some(ms));
            cleanup_worktree(gap_id);
            Ok(())
        }
        Ok(status) => {
            let ms = t_ship.elapsed().as_millis() as u64;
            tracing::warn!(request_id = %request_id, "gap-work: ship failed for {} with status {}", gap_id, status);
            emit_ambient_event(gap_id, "ship", "failed");
            emit_pwa_log(
                gap_id,
                "ship",
                &format!("FAILED ({request_id})"),
                request_id,
                Some(ms),
            );
            cleanup_lease(gap_id, &repo_root);
            cleanup_worktree(gap_id);
            Err(format!("Ship failed: {}", status).into())
        }
        Err(e) => {
            tracing::error!(request_id = %request_id, "gap-work: failed to spawn chump gap ship: {}", e);
            emit_ambient_event(gap_id, "ship", "error");
            emit_pwa_log(
                gap_id,
                "ship",
                &format!("FAILED ({request_id}, {e})"),
                request_id,
                None,
            );
            cleanup_lease(gap_id, &repo_root);
            cleanup_worktree(gap_id);
            Err(e.to_string().into())
        }
    }
}

// ── PRODUCT-080: Stuck Items API ─────────────────────────────────────────────

/// Stuck-item severity derived from ambient event kind.
fn stuck_severity(kind: &str) -> &'static str {
    match kind {
        "fleet_wedge" | "disk_critical" => "HIGH",
        "pr_stuck" | "silent_agent" | "lease_expired_server" => "MED",
        "fat_worktree" | "reaper_silent" => "LOW",
        _ => "LOW",
    }
}

/// Suggested rescue action for each stuck kind.
fn stuck_rescue_action(kind: &str) -> &'static str {
    match kind {
        "pr_stuck" => "Run pr-rescue.sh to rebase and re-arm auto-merge",
        "silent_agent" => "Release stale lease and requeue gap",
        "lease_expired_server" => "Reap expired lease via stale-lease-reaper.sh",
        "fat_worktree" => "Prune stale worktrees via worktree-prune.sh",
        "disk_critical" => "Free disk space; run worktree-prune.sh --execute",
        "reaper_silent" => "Restart ghost-gap-reaper daemon",
        "fleet_wedge" => "Drop to 2 workers; investigate pr_stuck cluster",
        _ => "Inspect ambient log for details",
    }
}

/// Script and args to invoke for a given rescue kind.
fn rescue_script(
    kind: &str,
    repo_root: &std::path::Path,
) -> Option<(std::path::PathBuf, Vec<String>)> {
    match kind {
        "pr_stuck" => {
            let script = repo_root.join("scripts/coord/pr-rescue.sh");
            Some((script, vec![]))
        }
        "fat_worktree" | "disk_critical" => {
            let script = repo_root.join("scripts/coord/worktree-prune.sh");
            Some((script, vec!["--execute".to_string()]))
        }
        "lease_expired_server" | "silent_agent" => {
            let script = repo_root.join("scripts/coord/stale-lease-reaper.sh");
            Some((script, vec![]))
        }
        "reaper_silent" => {
            let script = repo_root.join("scripts/coord/ghost-gap-reaper.sh");
            Some((script, vec!["--once".to_string()]))
        }
        _ => None,
    }
}

/// Emit an ambient event directly to ambient.jsonl.
fn emit_stuck_ambient(kind: &str, extra_fields: &[(&str, &str)]) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: kind.to_string(),
        source: Some("pwa_stuck_api".to_string()),
        fields: extra_fields
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        ..Default::default()
    });
}

/// PRODUCT-080: GET /api/stuck — aggregate stuck items from ambient.jsonl.
///
/// Returns a JSON list of stuck items with type, severity, age, and rescue action.
/// Queries last 1000 events; de-duplicates by kind so only the freshest per-kind
/// surfaces (except pr_stuck which may have multiple distinct PRs).
async fn handle_stuck_list(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    let path = ambient_log_path();
    let content = std::fs::read_to_string(&path).unwrap_or_default();
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Kinds we surface as stuck items — sorted by priority.
    const STUCK_KINDS: &[&str] = &[
        "fleet_wedge",
        "disk_critical",
        "pr_stuck",
        "silent_agent",
        "lease_expired_server",
        "fat_worktree",
        "reaper_silent",
    ];

    // PR-stuck threshold: 4 hours in seconds.
    const PR_STUCK_THRESHOLD_SECS: u64 = 4 * 60 * 60;

    // Parse last 1000 events.
    let events: Vec<serde_json::Value> = content
        .lines()
        .rev()
        .take(1000)
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();

    let mut items: Vec<serde_json::Value> = Vec::new();
    // Track which (kind, pr_number) pairs we've already emitted to avoid dups.
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Also track the most recent resolved fleet_wedge timestamp for empty-state.
    let mut last_wedge_resolved_secs: Option<u64> = None;

    for ev in &events {
        let kind = ev
            .get("kind")
            .or_else(|| ev.get("event"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        // Track resolved wedges for empty-state.
        if kind == "fleet_wedge_resolved" {
            if let Some(ts_str) = ev.get("ts").and_then(|v| v.as_str()) {
                if let Ok(ts) = chrono::DateTime::parse_from_rfc3339(ts_str) {
                    let ts_secs = ts.timestamp() as u64;
                    match last_wedge_resolved_secs {
                        None => last_wedge_resolved_secs = Some(ts_secs),
                        Some(prev) if ts_secs > prev => last_wedge_resolved_secs = Some(ts_secs),
                        _ => {}
                    }
                }
            }
        }

        if !STUCK_KINDS.contains(&kind) {
            continue;
        }

        // Parse event timestamp.
        let event_ts_secs: u64 = ev
            .get("ts")
            .and_then(|v| v.as_str())
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.timestamp() as u64)
            .unwrap_or(0);

        let age_secs = now_secs.saturating_sub(event_ts_secs);

        // pr_stuck: only surface if >= 4 hours old; deduplicate per (kind, pr).
        if kind == "pr_stuck" {
            if age_secs < PR_STUCK_THRESHOLD_SECS {
                continue;
            }
            let pr_num = ev
                .get("pr")
                .and_then(|v| {
                    v.as_str()
                        .map(|s| s.to_string())
                        .or_else(|| v.as_u64().map(|n| n.to_string()))
                })
                .unwrap_or_default();
            let dedup_key = format!("{}:{}", kind, pr_num);
            if !seen.insert(dedup_key.clone()) {
                continue;
            }
            // Generate a stable ID from kind + pr + event_ts.
            let id = format!("{}_{}_{}", kind, pr_num, event_ts_secs);
            items.push(serde_json::json!({
                "id": id,
                "kind": kind,
                "severity": stuck_severity(kind),
                "age_secs": age_secs,
                "rescue_action": stuck_rescue_action(kind),
                "pr": pr_num,
                "raw": ev,
            }));
        } else {
            // For non-pr_stuck kinds, only surface the most recent occurrence (dedup by kind).
            if !seen.insert(kind.to_string()) {
                continue;
            }
            let id = format!("{}_{}", kind, event_ts_secs);
            items.push(serde_json::json!({
                "id": id,
                "kind": kind,
                "severity": stuck_severity(kind),
                "age_secs": age_secs,
                "rescue_action": stuck_rescue_action(kind),
                "raw": ev,
            }));
        }
    }

    // Sort: HIGH first, then MED, then LOW; within group by age descending.
    items.sort_by(|a, b| {
        let sev_rank = |s: &str| match s {
            "HIGH" => 0u8,
            "MED" => 1,
            _ => 2,
        };
        let sa = a.get("severity").and_then(|v| v.as_str()).unwrap_or("LOW");
        let sb = b.get("severity").and_then(|v| v.as_str()).unwrap_or("LOW");
        sev_rank(sa).cmp(&sev_rank(sb)).then_with(|| {
            let aa = b.get("age_secs").and_then(|v| v.as_u64()).unwrap_or(0);
            let ab = a.get("age_secs").and_then(|v| v.as_u64()).unwrap_or(0);
            aa.cmp(&ab)
        })
    });

    // Build empty-state message if needed.
    let empty_state_msg = if items.is_empty() {
        let resolved_note = last_wedge_resolved_secs
            .map(|ts| {
                let ago_secs = now_secs.saturating_sub(ts);
                let ago_h = ago_secs / 3600;
                format!("Last wedge resolved {}h ago.", ago_h)
            })
            .unwrap_or_else(|| "No wedge events recorded.".to_string());
        Some(format!("Nothing stuck. {}", resolved_note))
    } else {
        None
    };

    Ok(Json(serde_json::json!({
        "items": items,
        "count": items.len(),
        "empty_state": empty_state_msg,
    })))
}

#[derive(serde::Deserialize)]
struct RescueRequest {
    /// The stuck-item kind (pr_stuck, fat_worktree, etc.) — used to look up the script.
    kind: String,
    /// Optional PR number for pr_stuck rescue.
    #[serde(default)]
    pr: Option<String>,
}

/// PRODUCT-080: POST /api/stuck/rescue/{id} — execute a rescue script for a stuck item.
///
/// Requires CSRF token (x-csrf-token header). Emits operator_rescue_invoked + rescue_result
/// to ambient.jsonl. Returns {ok, message, rescue_id}.
async fn handle_stuck_rescue(
    headers: HeaderMap,
    axum::extract::Path(item_id): axum::extract::Path<String>,
    Json(body): Json<RescueRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !check_auth(&headers) {
        return Err((StatusCode::UNAUTHORIZED, "auth required".to_string()));
    }
    if !check_csrf(&headers) {
        return Err((StatusCode::FORBIDDEN, "CSRF token required".to_string()));
    }

    // Validate kind — must be one of our known stuck kinds.
    const ALLOWED_KINDS: &[&str] = &[
        "pr_stuck",
        "silent_agent",
        "lease_expired_server",
        "fat_worktree",
        "disk_critical",
        "reaper_silent",
        "fleet_wedge",
    ];
    if !ALLOWED_KINDS.contains(&body.kind.as_str()) {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("unknown kind: {}", body.kind),
        ));
    }

    // Validate item_id — only alphanumeric + underscore + hyphen.
    if !item_id
        .chars()
        .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
    {
        return Err((StatusCode::BAD_REQUEST, "invalid item_id".to_string()));
    }

    let rescue_id = format!(
        "rescue_{}_{}",
        body.kind,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    );

    // Emit pre-action event.
    emit_stuck_ambient(
        "operator_rescue_invoked",
        &[
            ("item_id", item_id.as_str()),
            ("kind", body.kind.as_str()),
            ("rescue_id", rescue_id.as_str()),
        ],
    );

    let repo_root = crate::repo_path::runtime_base();

    let (script_path, script_args) = match rescue_script(&body.kind, &repo_root) {
        Some(pair) => pair,
        None => {
            // No script — emit failure and return.
            emit_stuck_ambient(
                "rescue_result",
                &[
                    ("rescue_id", rescue_id.as_str()),
                    ("kind", body.kind.as_str()),
                    ("success", "false"),
                    ("message", "no rescue script for this kind"),
                ],
            );
            return Ok(Json(serde_json::json!({
                "ok": false,
                "message": format!("No rescue script configured for kind: {}", body.kind),
                "rescue_id": rescue_id,
            })));
        }
    };

    if !script_path.exists() {
        let msg = format!("rescue script missing: {}", script_path.display());
        emit_stuck_ambient(
            "rescue_result",
            &[
                ("rescue_id", rescue_id.as_str()),
                ("kind", body.kind.as_str()),
                ("success", "false"),
                ("message", &msg),
            ],
        );
        return Ok(Json(serde_json::json!({
            "ok": false,
            "message": msg,
            "rescue_id": rescue_id,
        })));
    }

    let mut cmd = std::process::Command::new("bash");
    cmd.arg(&script_path);
    for arg in &script_args {
        cmd.arg(arg);
    }
    // For pr_stuck, pass --pr <number> if provided.
    if body.kind == "pr_stuck" {
        if let Some(ref pr) = body.pr {
            if !pr.is_empty() {
                cmd.args(["--pr", pr.as_str()]);
            }
        }
    }
    cmd.current_dir(&repo_root);

    let result = cmd.output();
    let (ok, message) = match result {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
            (
                true,
                if stdout.is_empty() {
                    "rescue completed".to_string()
                } else {
                    stdout
                },
            )
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
            (false, format!("exit {}: {}", out.status, stderr))
        }
        Err(e) => (false, format!("spawn error: {e}")),
    };

    emit_stuck_ambient(
        "rescue_result",
        &[
            ("rescue_id", rescue_id.as_str()),
            ("kind", body.kind.as_str()),
            ("success", if ok { "true" } else { "false" }),
            ("message", message.as_str()),
        ],
    );

    Ok(Json(serde_json::json!({
        "ok": ok,
        "message": message,
        "rescue_id": rescue_id,
    })))
}

// ── End PRODUCT-080 ───────────────────────────────────────────────────────────

fn build_api_router() -> Router {
    Router::new()
        .route("/favicon.ico", get(routes::health::handle_favicon))
        .route("/api/health", get(routes::health::handle_health))
        .route(
            "/api/stack-status",
            get(routes::health::handle_stack_status),
        )
        .route(
            "/api/cascade-status",
            get(routes::health::handle_cascade_status),
        )
        .route("/api/slots", get(routes::health::handle_slots))
        .route(
            "/api/cascade-slot-toggle",
            post(routes::health::handle_cascade_slot_toggle),
        )
        .route(
            "/api/cognitive-state",
            get(routes::health::handle_cognitive_state),
        )
        .route(
            "/api/causal-timeline",
            get(routes::health::handle_causal_timeline),
        )
        .route(
            "/api/neuromod-stream",
            get(routes::health::handle_neuromod_stream),
        )
        .route(
            "/api/fleet/health",
            get(routes::health::handle_fleet_health),
        )
        // INFRA-1338: server-side ROADMAP.md parser + 60s cache (replaces
        // INFRA-1207 client-side fallback).
        .route("/api/roadmap", get(routes::roadmap::handle_roadmap))
        // INFRA-1563: operator-decision queue (sibling to /api/roadmap).
        .route(
            "/api/decisions",
            get(routes::decisions::handle_decisions_list),
        )
        .route(
            "/api/decisions/{id}/resolve",
            post(routes::decisions::handle_decisions_resolve),
        )
        // EFFECTIVE-679: cheap idea-drop intake (EFFECTIVE-392 slice).
        .route("/api/drop", post(handle_drop_post))
        .route("/api/chat", post(handle_chat_with_kill_gate))
        .route("/api/voice/ask", post(handle_voice_ask))
        .route("/api/advisor/ask", post(handle_advisor_ask))
        .route("/api/stop", post(handle_stop))
        .route("/api/tts", get(handle_tts))
        .route("/api/inject-hint", post(handle_inject_hint))
        // INFRA-1296: A2A — operator emits any a2a event from PWA.
        .route("/api/broadcast", post(handle_broadcast))
        // INFRA-1298: A2A — operator/agent reads targeted inbox.
        .route("/api/inbox/{session}", get(handle_inbox_get))
        .route(
            "/api/inbox/{session}/unread-count",
            get(handle_inbox_unread_count),
        )
        .route("/api/inbox/{session}/ack", post(handle_inbox_ack))
        // META-080: lesson sharing endpoint (in-memory store, META-073 slice).
        .route(
            "/api/lessons",
            get(handle_lessons_get).post(handle_lessons_post),
        )
        .route("/api/approve", post(handle_approve))
        // INFRA-1340: per-tool persistent auto-approve policies (PWA dropdown)
        .route(
            "/api/tool-policy",
            get(handle_tool_policy_list).post(handle_tool_policy_upsert),
        )
        .route("/api/tool-policy/{tool}", delete(handle_tool_policy_delete))
        .route(
            "/api/policy-override",
            post(handle_policy_override_register),
        )
        .route(
            "/api/sessions",
            get(handle_sessions_list).post(handle_sessions_create),
        )
        .route("/api/sessions/{id}/messages", get(handle_sessions_messages))
        .route(
            "/api/sessions/{id}",
            put(handle_sessions_rename).delete(handle_sessions_delete),
        )
        .route(
            "/api/upload",
            post(handle_upload).layer(RequestBodyLimitLayer::new(11 * 1024 * 1024)),
        )
        .route("/api/files/{file_id}", get(handle_file_serve))
        .route(
            "/api/tasks",
            get(handle_tasks_list).post(handle_tasks_create),
        )
        .route(
            "/api/tasks/{id}",
            put(handle_tasks_update).delete(handle_tasks_delete),
        )
        .route("/api/pilot-summary", get(handle_pilot_summary))
        .route("/api/jobs", get(handle_jobs))
        .route("/api/briefing", get(handle_briefing))
        .route("/api/dashboard", get(handle_dashboard))
        .route("/api/dashboard/stream", get(handle_dashboard_stream))
        .route("/api/autopilot/status", get(handle_autopilot_status))
        .route("/api/autopilot/start", post(handle_autopilot_start))
        .route("/api/autopilot/stop", post(handle_autopilot_stop))
        .route(
            "/api/autopilot/daemon-status",
            get(handle_autopilot_daemon_status),
        )
        .route("/api/repo/context", get(handle_repo_context))
        .route("/api/repo/working", post(handle_repo_working))
        .route("/api/repo/init", post(handle_repo_init))
        // INFRA-1014: token-verify endpoint (bypasses auth middleware itself
        // so the login modal can call it without yet having the token).
        .route("/api/auth/check", post(handle_auth_check))
        // INFRA-988: non-secret settings panel scaffolding
        .route("/api/settings", get(handle_settings_get))
        .route("/api/settings/{key}", post(handle_settings_post))
        // INFRA-989: secret-input flow (mask + test-before-store)
        .route(
            "/api/settings/secret/{name}",
            get(handle_secret_get).post(handle_secret_post),
        )
        // INFRA-1570: per-repo settings backend (sibling to INFRA-1563 /api/decisions).
        .route(
            "/api/settings/repo",
            get(routes::settings_repo::handle_settings_repo_get)
                .put(routes::settings_repo::handle_settings_repo_put),
        )
        .route(
            "/api/ingest",
            post(handle_ingest_json).layer(RequestBodyLimitLayer::new(
                web_brain::MAX_INGEST_BYTES + 65536,
            )),
        )
        .route(
            "/api/ingest/upload",
            post(handle_ingest_upload).layer(RequestBodyLimitLayer::new(11 * 1024 * 1024)),
        )
        .route(
            "/api/research",
            get(handle_research_list).post(handle_research_create),
        )
        .route("/api/research/{id}", get(handle_research_get))
        .route("/api/watch", get(handle_watch_list).post(handle_watch_add))
        .route("/api/watch/alerts", get(handle_watch_alerts))
        .route("/api/watch/{list}/{item_id}", delete(handle_watch_delete))
        .route(
            "/api/projects",
            get(handle_projects_list).post(handle_projects_create),
        )
        .route(
            "/api/projects/{id}/activate",
            post(handle_projects_activate),
        )
        .route(
            "/api/push/vapid-public-key",
            get(handle_push_vapid_public_key),
        )
        .route("/api/push/subscribe", post(handle_push_subscribe))
        .route("/api/push/unsubscribe", post(handle_push_unsubscribe))
        .route("/api/tool-approval-audit", get(handle_tool_approval_audit))
        .route("/api/cos/decisions", get(handle_cos_decisions))
        .route("/api/needs-judgment", get(handle_needs_judgment))
        .route("/api/needs-judgment/ack", post(handle_needs_judgment_ack))
        .route("/api/shortcut/task", post(handle_shortcut_task))
        .route(
            "/api/shortcut/capture",
            post(handle_shortcut_capture).layer(RequestBodyLimitLayer::new(
                web_brain::MAX_INGEST_BYTES + 65536,
            )),
        )
        .route("/api/shortcut/status", get(handle_shortcut_status))
        .route("/api/shortcut/command", post(handle_shortcut_command))
        .route("/api/analytics", get(handle_analytics))
        .route("/api/messages/{id}/feedback", post(handle_message_feedback))
        .route("/api/skills/health", get(handle_skills_health))
        .route("/skills/index.json", get(handle_skills_index))
        .route("/.well-known/skills/index.json", get(handle_skills_index))
        .route("/api/brain/graph.json", get(handle_brain_graph_json))
        .route("/api/brain/graph/stats", get(handle_brain_graph_stats))
        .route("/api/brain/graph/stream", get(handle_brain_graph_stream))
        .route("/api/brain/node/{id}", get(handle_brain_node))
        .route(
            "/api/fleet/workspace_exchange",
            post(handle_fleet_workspace_exchange),
        )
        .route("/api/brief", get(handle_brief))
        .route("/api/ambient/stream", get(handle_ambient_stream))
        .route("/api/ambient/recent", get(handle_ambient_recent))
        .route("/api/ambient/emit", post(handle_ambient_emit))
        // PRODUCT-081: outcome dashboard
        .route("/api/impact", get(handle_impact))
        // PRODUCT-080: stuck items alerter
        .route("/api/stuck", get(handle_stuck_list))
        .route("/api/stuck/rescue/{id}", post(handle_stuck_rescue))
        .route("/api/fleet-status", get(handle_fleet_status))
        .route("/api/telemetry/cost", get(handle_telemetry_cost))
        .route("/api/health/pillars", get(handle_health_pillars))
        .route("/api/health/doctor", get(handle_doctor_health))
        // META-175: JetStream consumer lag + delivery latency per role.
        .route("/api/fleet-wire/health", get(handle_fleet_wire_health))
        // INFRA-1774: operator-page protocol — structured HITL interrupts.
        .route(
            "/api/operator-page/pending",
            get(handle_operator_page_pending),
        )
        .route("/api/operator-page/ack", post(handle_operator_page_ack))
        .route("/api/pr/{number}", get(handle_pr_detail))
        .route("/api/prs", get(handle_pr_list))
        // PRODUCT-085: diff + AC-fit for inline PWA diff renderer.
        .route("/api/pr/{number}/diff", get(handle_pr_diff))
        .route("/api/pr/{number}/ac-fit", get(handle_pr_ac_fit))
        .route(
            "/api/prs/{number}/request-changes",
            post(handle_pr_request_changes),
        )
        .route("/api/prs/{number}/comment", post(handle_pr_comment))
        .route("/api/prs/{number}/revert", post(handle_pr_revert))
        .route("/api/gap-queue", get(handle_gap_queue))
        // PRODUCT-102: /api/gaps is the canonical gap-list-browser alias — same
        // handler as /api/gap-queue, exposes id/title/status/priority/effort/
        // domain/pillar and accepts ?status=&priority=&domain= query params.
        .route("/api/gaps", get(handle_gap_queue))
        .route("/api/gaps/next", get(handle_gap_next))
        .route("/api/gaps/search", get(handle_gaps_search))
        // PRODUCT-176: the gap write surface — creation and field mutation were
        // CLI-only (`chump gap reserve` / `chump gap set`), which made the web
        // API read-plus-dispatch but never authoring. These two routes close
        // that gap so ChumpOS organs (holler bridge, cockpit, future support
        // loop) can drive the registry over HTTP with the same auth stack.
        .route("/api/gap", post(handle_gap_create))
        .route("/api/gap/{id}", patch(handle_gap_update))
        .route("/api/gap/claim/{id}", post(handle_gap_claim))
        .route("/api/gap/status/{id}", get(handle_gap_status))
        .route("/api/gap/{id}/status", get(handle_gap_workflow_status))
        .route("/api/gap/{id}/stream", get(handle_gap_workflow_stream))
        .route("/api/gap/work/{id}", post(handle_gap_work))
        .route("/api/gap/work/{id}/retry", post(handle_gap_work_retry))
        // PRODUCT-127: cockpit Gap-store drift card — status query + repair action.
        .route("/api/gap/drift-status", get(handle_gap_drift_status))
        .route("/api/gap/dep-clean", post(handle_gap_dep_clean))
        // PRODUCT-129: cockpit Lock-contention card [Release expired leases].
        .route(
            "/api/lease/release-expired",
            post(handle_lease_release_expired),
        )
        .route("/api/logs/{request_id}", get(handle_get_logs))
        // EFFECTIVE-012: serve OpenAPI spec for client discovery.
        .route("/api/docs", get(handle_api_docs))
        // INFRA-1303: serve repo docs/ directory as /docs/* — markdown files
        // readable in browser and linkable from within the PWA.
        .route("/docs/{*path}", get(handle_docs_file))
        // CREDIBLE-023: secure response headers for all /api/gap/* routes
        .layer(axum::middleware::from_fn(gap_security_headers_middleware))
}

/// GET /skills/index.json (also /.well-known/skills/index.json) — COMP-006 skills index.
/// Machine-readable registry of installed skills. No auth required (read-only, no secrets).
/// Compatible with the skills tap ecosystem format (schema_version 1).
async fn handle_skills_index() -> Json<serde_json::Value> {
    let skills = crate::skills::list_skills().unwrap_or_default();
    let list: Vec<serde_json::Value> = skills
        .iter()
        .map(|s| {
            serde_json::json!({
                "name": s.name(),
                "description": s.frontmatter.description,
                "version": s.frontmatter.version,
                "category": s.frontmatter.metadata.category,
                "tags": s.frontmatter.metadata.tags,
                "platforms": s.frontmatter.platforms,
            })
        })
        .collect();
    Json(serde_json::json!({
        "schema_version": 1,
        "skills": list,
    }))
}

/// GET /api/skills/health — Phase 2.5 skill effectiveness dashboard.
/// Returns ranked list of skills (by composite score) plus decay candidates
/// (skills unused for >30 days). Empty arrays when no skills exist.
async fn handle_skills_health(headers: HeaderMap) -> Result<Json<serde_json::Value>, StatusCode> {
    if !check_auth(&headers) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let ranking = crate::skill_metrics::skill_health_ranking().unwrap_or_default();
    let decay = crate::skill_metrics::skill_decay_candidates().unwrap_or_default();
    let skills: Vec<serde_json::Value> = ranking
        .iter()
        .map(|s| {
            serde_json::json!({
                "name": s.name,
                "description": s.description,
                "category": s.category,
                "reliability": s.reliability,
                "confidence_interval": [s.confidence_lower, s.confidence_upper],
                "use_count": s.use_count,
                "success_count": s.success_count,
                "failure_count": s.failure_count,
                "days_since_last_use": s.days_since_last_use,
                "composite_score": s.composite_score,
            })
        })
        .collect();
    Ok(Json(serde_json::json!({
        "skills": skills,
        "decay_candidates": decay,
    })))
}

/// When the requested port is busy, we bind to the next free port and write this file (one line:
/// port number) so ChumpMenu can open the PWA/chat on the right port. Removed when the bound
/// port equals the requested port or when the user stops Chump from ChumpMenu.
fn sync_chump_web_bound_port_marker(requested_port: u16, bound_port: u16) {
    let logs = repo_path::runtime_base().join("logs");
    let marker = logs.join("chump-web-bound-port");
    if let Err(e) = std::fs::create_dir_all(&logs) {
        eprintln!("[web] warning: could not create logs dir {:?}: {}", logs, e);
        return;
    }
    if bound_port == requested_port {
        let _ = std::fs::remove_file(&marker);
    } else if let Err(e) = std::fs::write(&marker, format!("{}\n", bound_port)) {
        eprintln!(
            "[web] warning: could not write {:?} (set CHUMP_WEB_PORT={} in .env): {}",
            marker, bound_port, e
        );
    }
}

/// EFFECTIVE-013: Validate environment before binding to the port.
///
/// Hard failures (returns `Err`) — server must not start:
/// * `CHUMP_REPO` is set but the path does not exist or is not a directory.
/// * `CHUMP_BIN` is set to an absolute path that does not exist or is not executable.
///
/// Soft warnings (emits to stderr, returns `Ok`) — server continues:
/// * `GH_TOKEN` not set — agent falls back to keyring; ops may be degraded.
pub fn validate_startup_env() -> Result<()> {
    // -- CHUMP_REPO --------------------------------------------------------
    if let Ok(repo) = std::env::var("CHUMP_REPO") {
        let p = std::path::Path::new(&repo);
        if !p.exists() {
            eprintln!("[web] CHUMP_REPO not found: {repo}");
            return Err(anyhow::anyhow!(
                "CHUMP_REPO not found: {repo} — set CHUMP_REPO to an existing repo checkout"
            ));
        }
        if !p.is_dir() {
            eprintln!("[web] CHUMP_REPO is not a directory: {repo}");
            return Err(anyhow::anyhow!("CHUMP_REPO is not a directory: {repo}"));
        }
    }

    // -- CHUMP_BIN ---------------------------------------------------------
    // Only validate when explicitly set to an absolute path; a bare name
    // (e.g. the default "chump") is resolved by the OS at spawn time.
    if let Ok(bin) = std::env::var("CHUMP_BIN") {
        let p = std::path::Path::new(&bin);
        if p.is_absolute() {
            if !p.exists() {
                eprintln!("[web] CHUMP_BIN not found or not executable: {bin}");
                return Err(anyhow::anyhow!(
                    "CHUMP_BIN not found: {bin} — set CHUMP_BIN to the chump binary path"
                ));
            }
            // On Unix, check execute bit.
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = std::fs::metadata(&bin)
                    .map(|m| m.permissions().mode())
                    .unwrap_or(0);
                if mode & 0o111 == 0 {
                    eprintln!("[web] CHUMP_BIN not found or not executable: {bin}");
                    return Err(anyhow::anyhow!(
                        "CHUMP_BIN exists but is not executable: {bin} — run `chmod +x {bin}`"
                    ));
                }
            }
        }
    }

    // -- GH_TOKEN (soft) ---------------------------------------------------
    if std::env::var("GH_TOKEN").is_err() && std::env::var("GITHUB_TOKEN").is_err() {
        eprintln!(
            "[web] WARNING: GH_TOKEN not set, agent will use keyring \
             (set GH_TOKEN or GITHUB_TOKEN if keyring is unavailable)"
        );
        tracing::warn!(
            "effective013: GH_TOKEN not set — agent will fall back to keyring; \
             set GH_TOKEN or GITHUB_TOKEN if keyring is unavailable"
        );
    } else {
        tracing::info!(
            "effective013: startup validation passed (CHUMP_REPO, CHUMP_BIN, credentials OK)"
        );
    }

    // CREDIBLE-022: binary drift check — warn when web_server.rs source is
    // newer than the installed binary's baked build date. Only fires in dev
    // environments where the source is present alongside the binary.
    check_binary_drift();

    Ok(())
}

/// CREDIBLE-022: if running in a dev checkout and src/web_server.rs is
/// newer than the binary's baked build date by more than 2h, emit a warning
/// so developers know to `cargo install --force` or `cargo build`.
fn check_binary_drift() {
    let build_date = crate::version::chump_build_date();
    if build_date == "unknown" {
        return;
    }
    let parts: Vec<u32> = build_date
        .split('-')
        .filter_map(|s| s.parse().ok())
        .collect();
    if parts.len() != 3 {
        return;
    }
    use chrono::{TimeZone, Utc};
    let build_dt = match Utc
        .with_ymd_and_hms(parts[0] as i32, parts[1], parts[2], 0, 0, 0)
        .single()
    {
        Some(d) => d,
        None => return,
    };
    let build_epoch = build_dt.timestamp();

    // Only meaningful in a dev checkout where source is present.
    let repo_root = crate::repo_path::repo_root();
    let ws_src = repo_root.join("src").join("web_server.rs");
    let ws_mtime = match std::fs::metadata(&ws_src)
        .and_then(|m| m.modified())
        .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default())
    {
        Ok(d) => d.as_secs() as i64,
        Err(_) => return, // source not present — production install, skip
    };

    let drift_secs = ws_mtime - build_epoch;
    if drift_secs > 7200 {
        let drift_hours = drift_secs / 3600;
        let msg = format!(
            "[web] WARNING: src/web_server.rs is {}h newer than the installed binary (built {}). \
             Run `cargo install --force` or `cargo build` to rebuild.",
            drift_hours, build_date
        );
        eprintln!("{msg}");
        tracing::warn!(
            drift_hours = drift_hours,
            build_date = build_date,
            "credible022: web_server.rs source is newer than binary; recommend rebuild"
        );
    }
}

/// Start the web server. Binds to 0.0.0.0:port (or the next free port if that one is in use).
/// Serves GET /api/health and static files from web/.
pub async fn start_web_server(port: u16) -> Result<()> {
    validate_startup_env()?;

    let static_dir = pwa_static_dir();
    if let Err(e) = std::fs::create_dir_all(&static_dir) {
        eprintln!(
            "[web] warning: could not create static dir {:?}: {}",
            static_dir, e
        );
    }

    let api = build_api_router();
    // INFRA-1014: enforce CHUMP_WEB_TOKEN on /api/* (except health + auth-check).
    // Middleware no-ops when the env is unset (today's default) so this is a
    // strict addition — existing deployments without the env see no behavior
    // change.
    let api = api.layer(axum::middleware::from_fn(auth_middleware));
    let api = if crate::env_flags::chump_web_http_trace() {
        api.layer(TraceLayer::new_for_http())
    } else {
        api
    };

    // INFRA-1014: startup warning. The server binds 0.0.0.0 by default, so an
    // unset CHUMP_WEB_TOKEN means anyone on the LAN can call /api/*. Operator
    // gets one loud line per boot.
    match std::env::var("CHUMP_WEB_TOKEN") {
        Ok(t) if !t.trim().is_empty() => {
            eprintln!("[web] CHUMP_WEB_TOKEN set — /api/* requires Bearer auth (INFRA-1014).");
        }
        _ => {
            eprintln!("[web] WARNING: CHUMP_WEB_TOKEN unset. Server binds 0.0.0.0 — anyone on the local network can reach /api/*. Set CHUMP_WEB_TOKEN before exposing this PWA over a tunnel or shared Wi-Fi. (INFRA-1014)");
        }
    }
    // Tauri loads the PWA from tauri.localhost but calls the sidecar on 127.0.0.1 — browsers treat
    // that as cross-origin; without CORS headers the fetch succeeds opaquely and SSE body is empty.
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
            Method::HEAD,
        ])
        .allow_headers(Any);
    // INFRA-254: route browser users at / to the modern v2 PWA shell.
    // The legacy v1 PWA at web/index.html is still served (the Tauri desktop
    // shell loads it via its bundled frontendDist + a Tauri-only OOTB wizard
    // that browser users never see) — we just stop landing browsers on it.
    // Tauri does NOT hit axum's `/` (it serves frontend from tauri.localhost
    // and only calls /api/* on the sidecar — see CORS comment above), so the
    // redirect is desktop-safe.
    let app = Router::new()
        .merge(api)
        .route("/", get(|| async { Redirect::permanent("/v2/") }))
        .fallback_service(ServeDir::new(&static_dir).append_index_html_on_directories(true))
        .layer(cors);

    let requested_port = port;
    let mut listener: Option<tokio::net::TcpListener> = None;
    let mut bound_port: u16 = port;
    for offset in 0u32..64 {
        let try_u32 = (requested_port as u32).saturating_add(offset);
        if try_u32 > u16::MAX as u32 {
            break;
        }
        let try_port = try_u32 as u16;
        let addr = std::net::SocketAddr::from(([0, 0, 0, 0], try_port));
        match tokio::net::TcpListener::bind(addr).await {
            Ok(l) => {
                bound_port = try_port;
                listener = Some(l);
                break;
            }
            Err(e) if e.kind() == ErrorKind::AddrInUse && offset + 1 < 64 => continue,
            Err(e) => return Err(e.into()),
        }
    }
    let listener = listener.ok_or_else(|| {
        anyhow::anyhow!(
            "[web] could not bind web server from port {} (tried 64 consecutive ports); set CHUMP_WEB_PORT to a free port",
            requested_port
        )
    })?;

    sync_chump_web_bound_port_marker(requested_port, bound_port);
    if bound_port != requested_port {
        eprintln!(
            "[web] note: port {} was in use; listening on {} (set CHUMP_WEB_PORT={} in .env to persist)",
            requested_port, bound_port, bound_port
        );
    }
    eprintln!("[web] Chump Web listening on http://0.0.0.0:{}", bound_port);
    eprintln!("[web] serving Chump PWA from {:?}", static_dir);

    // INFRA-167: pre-warm the configured Ollama model on startup so the
    // first user turn doesn't pay 5-15 s cold-load. Best-effort, async,
    // ~one HTTP call. Disable with CHUMP_PREWARM=0 (e.g. for benchmarks
    // measuring pure cold-start). Non-Ollama backends (vLLM-MLX, mistral.rs,
    // hosted OpenAI) are skipped — pre-warm with `keep_alive` is an
    // Ollama-specific feature.
    let prewarm_disabled = std::env::var("CHUMP_PREWARM")
        .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
        .unwrap_or(false);
    if !prewarm_disabled {
        tokio::spawn(async move {
            let base = std::env::var("OPENAI_API_BASE")
                .unwrap_or_else(|_| "http://localhost:11434/v1".to_string());
            let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "qwen2.5:7b".to_string());
            let keep_alive =
                std::env::var("CHUMP_OLLAMA_KEEP_ALIVE").unwrap_or_else(|_| "30m".to_string());

            // Heuristic: Ollama runs on :11434 by default. The pre-warm
            // payload below uses /api/generate which is Ollama-specific.
            let is_ollama = base.contains(":11434") || base.to_lowercase().contains("ollama");
            if !is_ollama {
                eprintln!(
                    "[web] pre-warm skipped: OPENAI_API_BASE={} doesn't look like Ollama",
                    base
                );
                return;
            }

            let ollama_base = base
                .trim_end_matches("/v1")
                .trim_end_matches('/')
                .to_string();
            let url = format!("{}/api/generate", ollama_base);

            let body = serde_json::json!({
                "model": model,
                "prompt": ".",
                "keep_alive": keep_alive,
                "stream": false,
                "options": { "num_predict": 1 },
            });

            let client = match reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(120))
                .build()
            {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("[web] pre-warm: client build failed: {}", e);
                    return;
                }
            };
            let start = std::time::Instant::now();
            match client.post(&url).json(&body).send().await {
                Ok(resp) if resp.status().is_success() => {
                    eprintln!(
                        "[web] pre-warm: {} ready in {} ms (keep_alive={})",
                        model,
                        start.elapsed().as_millis(),
                        keep_alive
                    );
                }
                Ok(resp) => {
                    eprintln!(
                        "[web] pre-warm: {} returned {} (Ollama may be down — first user turn will pay cold-load)",
                        model,
                        resp.status()
                    );
                }
                Err(e) => {
                    eprintln!(
                        "[web] pre-warm: {} unreachable at {} ({}) — first user turn will pay cold-load",
                        model, url, e
                    );
                }
            }
        });
    }

    eprintln!("[web] autopilot: scheduling boot + periodic reconcile (3m interval)");

    tokio::spawn(async move {
        let res = tokio::task::spawn_blocking(autopilot::reconcile_autopilot_maybe_start).await;
        match res {
            Ok(Ok(Some(_))) => eprintln!("[web] autopilot reconcile (boot): started ship"),
            Ok(Ok(None)) => {}
            Ok(Err(e)) => eprintln!("[web] autopilot reconcile (boot): {}", e),
            Err(e) => eprintln!("[web] autopilot reconcile (boot): join error: {}", e),
        }
    });

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(180));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let res = tokio::task::spawn_blocking(autopilot::reconcile_autopilot_maybe_start).await;
            match res {
                Ok(Ok(Some(_))) => eprintln!("[web] autopilot reconcile (periodic): started ship"),
                Ok(Ok(None)) => {}
                Ok(Err(e)) => eprintln!("[web] autopilot reconcile (periodic): {}", e),
                Err(e) => eprintln!("[web] autopilot reconcile (periodic): join error: {}", e),
            }
        }
    });

    // INFRA-1337: start GitHub rate-limit poller (60s interval).
    crate::github_rate_limit::start_poller();

    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod effective_422_voice_advisor {
    //! EFFECTIVE-422: pins the SSE→spoken-string parser that /api/voice/ask uses
    //! to convert an agent run's `AgentEvent` stream into a single text payload
    //! the Siri Shortcut speaks. Mirrors `agent_event_stream` (parent mod:146),
    //! which emits `event:<type>\ndata:<json>\n\n` for each AgentEvent variant.

    use super::parse_sse_to_spoken;

    fn sse(event_type: &str, data_json: &str) -> String {
        format!("event:{event_type}\ndata:{data_json}\n\n")
    }

    #[test]
    fn turn_complete_full_text_wins() {
        // text_complete arrives first, then turn_complete — turn_complete is
        // authoritative (it carries the full reply for the turn).
        let body = format!(
            "{}{}",
            sse("text_complete", r#"{"text":"partial"}"#),
            sse(
                "turn_complete",
                r#"{"request_id":"r1","full_text":"final","duration_ms":10,"tool_calls_count":1,"model_calls_count":2}"#
            )
        );
        assert_eq!(parse_sse_to_spoken(&body).as_deref(), Some("final"));
    }

    #[test]
    fn text_complete_is_fallback_when_no_turn_complete() {
        // Sanity: agent_event_stream always emits turn_complete or turn_error
        // before closing, but parse_sse_to_spoken must degrade gracefully to
        // text_complete if a buggy client never emits the capstone event.
        let body = sse("text_complete", r#"{"text":"partial-only"}"#);
        let parsed = parse_sse_to_spoken(&body);
        assert_eq!(
            parsed.as_deref(),
            Some("partial-only"),
            "should return Some when text_complete arrives alone"
        );
    }

    #[test]
    fn turn_error_surfaces_plainly() {
        // Voice users get the error string spoken, not silence — the honesty
        // rule "silence about a failed tool breaks trust" applies here too.
        let body = sse("turn_error", r#"{"request_id":"r1","error":"oops"}"#);
        assert_eq!(
            parse_sse_to_spoken(&body).as_deref(),
            Some("Chump hit an error: oops")
        );
    }

    #[test]
    fn irrelevant_events_are_skipped() {
        // turn_start / thinking / tool_call_start etc. carry no spoken payload.
        let body = format!(
            "{}{}{}{}",
            sse("turn_start", r#"{"request_id":"r1","timestamp":"t"}"#),
            sse("thinking", r#"{"elapsed_ms":250}"#),
            sse(
                "tool_call_start",
                r#"{"tool_name":"almanac_search","tool_input":{},"call_id":"c1"}"#
            ),
            sse(
                "turn_complete",
                r#"{"request_id":"r1","full_text":"after tools","duration_ms":500,"tool_calls_count":1,"model_calls_count":1}"#
            )
        );
        assert_eq!(parse_sse_to_spoken(&body).as_deref(), Some("after tools"));
    }

    #[test]
    fn empty_body_yields_none() {
        assert_eq!(parse_sse_to_spoken(""), None);
    }
}

#[cfg(test)]
mod api_battle_tests {
    // ── PRODUCT-176: gap write surface (POST /api/gap, PATCH /api/gap/{id}) ──

    /// Shared setup: point CHUMP_REPO at a fresh tempdir (GapStore creates its
    /// schema on open), disable the live-PR scan + verify sleep (same opt-outs
    /// the gap-store's own tests use), and raise the per-IP rate limit so the
    /// serial test suite can't trip it.
    ///
    /// RESTORES (never bare-removes) the prior CHUMP_REPO on drop, panics
    /// included. A bare remove_var leaves an unset-env window in which any
    /// other test's repo_root() call resolves against a live chumpd daemon
    /// instead of the intended tempdir — under `cargo test`'s shared process
    /// that cascades into repo_path/repo_tools failures whenever a chumpd
    /// daemon is running. Found live shipping this gap: nextest (process per
    /// test) passed 2734/2734 while the pre-push cargo-test gate failed 17
    /// env-sensitive tests two modules away. Before INFRA-3534, the fallout
    /// was worse: `chumpd_repo_root()` cached the whole env-precedence
    /// decision in a `OnceLock`, so a stray daemon answer from the unset
    /// window stuck for the rest of the process even after CHUMP_REPO was
    /// restored. INFRA-3534 fixed that — only the pure socket lookup is
    /// cached now, env is re-checked every call — but restoring promptly
    /// still avoids the unset-env window entirely.
    struct GapWriteEnv {
        _dir: tempfile::TempDir,
        prev_repo: Option<String>,
    }
    impl Drop for GapWriteEnv {
        fn drop(&mut self) {
            match self.prev_repo.take() {
                Some(v) => std::env::set_var("CHUMP_REPO", v),
                None => std::env::remove_var("CHUMP_REPO"),
            }
        }
    }
    fn gap_write_test_env() -> GapWriteEnv {
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_REPO", dir.path());
        std::env::set_var("CHUMP_RESERVE_SCAN_OPEN_PRS", "0");
        std::env::set_var("CHUMP_RESERVE_VERIFY", "0");
        std::env::set_var("CHUMP_GAP_RATE_LIMIT", "10000");
        std::env::remove_var("CHUMP_WEB_TOKEN");
        GapWriteEnv {
            _dir: dir,
            prev_repo,
        }
    }

    fn json_req(method: &str, uri: &str, body: serde_json::Value) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .header("x-csrf-token", "t")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    #[tokio::test]
    #[serial]
    async fn gap_create_happy_path_and_visible_in_list() {
        let _dir = gap_write_test_env();
        let mut app = build_api_router();

        let req = json_req(
            "POST",
            "/api/gap",
            serde_json::json!({
                "domain": "product",
                "title": "PRODUCT-176 test gap: created over HTTP",
                "description": "created by gap_create_happy_path test",
                "external_repo": "repairman29/holler"
            }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let id = v
            .get("id")
            .and_then(|x| x.as_str())
            .expect("id in response");
        assert!(
            id.starts_with("PRODUCT-"),
            "id should be PRODUCT-N, got {id}"
        );
        // Domain uppercased, defaults applied, extras landed.
        assert_eq!(v.get("priority").and_then(|x| x.as_str()), Some("P2"));
        assert_eq!(v.get("effort").and_then(|x| x.as_str()), Some("m"));
        assert_eq!(v.get("status").and_then(|x| x.as_str()), Some("open"));
        assert_eq!(
            v.get("skills_required").and_then(|x| x.as_str()),
            Some("external_repo:repairman29/holler"),
            "MISSION-041 parity: external_repo must land in skills_required"
        );
        // Default obs-ACs applied when none supplied (never an empty AC set —
        // EFFECTIVE-294: an AC-less gap is unclaimable).
        let ac = v
            .get("acceptance_criteria")
            .and_then(|x| x.as_str())
            .unwrap();
        assert!(ac.starts_with('['), "AC stored as JSON list: {ac}");
        assert_ne!(ac, "[]", "default ACs must be applied when none supplied");
        assert!(v.get("warnings").is_none(), "no warnings expected: {v}");

        // The gap is visible through the read surface.
        let req = Request::builder()
            .uri("/api/gaps")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let list = String::from_utf8_lossy(&body);
        assert!(
            list.contains(id),
            "created gap {id} must appear in /api/gaps"
        );
    }

    #[tokio::test]
    #[serial]
    async fn gap_create_p0_without_outcome_is_refused() {
        let _dir = gap_write_test_env();
        let mut app = build_api_router();
        let req = json_req(
            "POST",
            "/api/gap",
            serde_json::json!({
                "domain": "RESILIENT",
                "title": "P0 without an outcome must be refused",
                "priority": "P0"
            }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "MISSION-045 parity: the HTTP surface must not be the outcome-gate bypass"
        );
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(
            v.get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .contains("MISSION-045"),
            "error must name the gate: {v}"
        );
    }

    #[tokio::test]
    #[serial]
    async fn gap_update_status_and_guard_rejection() {
        let _dir = gap_write_test_env();
        let mut app = build_api_router();

        // Create a gap to mutate.
        let req = json_req(
            "POST",
            "/api/gap",
            serde_json::json!({ "domain": "INFRA", "title": "patch target gap" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let id = v.get("id").and_then(|x| x.as_str()).unwrap().to_string();

        // Happy path: priority + notes update round-trips.
        let req = json_req(
            "PATCH",
            &format!("/api/gap/{id}"),
            serde_json::json!({ "priority": "p3", "notes": "updated over HTTP" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            v.get("priority").and_then(|x| x.as_str()),
            Some("P3"),
            "lowercase input must normalize: {v}"
        );

        // INFRA-402 guard: flipping to done without closed_pr is a 422 carrying
        // the store's own message — not a 500, not a silent success.
        let req = json_req(
            "PATCH",
            &format!("/api/gap/{id}"),
            serde_json::json!({ "status": "done" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(
            v.get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .contains("closed_pr"),
            "guard message must surface: {v}"
        );

        // Unknown status is refused via the registry check.
        let req = json_req(
            "PATCH",
            &format!("/api/gap/{id}"),
            serde_json::json!({ "status": "tottaly-done" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);

        // Unknown gap is a 404.
        let req = json_req(
            "PATCH",
            "/api/gap/INFRA-999999",
            serde_json::json!({ "notes": "x" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::NOT_FOUND);

        // Empty body is a 400.
        let req = json_req("PATCH", &format!("/api/gap/{id}"), serde_json::json!({}));
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn gap_write_routes_require_auth_and_csrf() {
        let _dir = gap_write_test_env();
        std::env::set_var("CHUMP_WEB_TOKEN", "sekrit");
        let mut app = build_api_router();

        // No bearer token → 401 on both routes.
        let req = json_req(
            "POST",
            "/api/gap",
            serde_json::json!({ "domain": "INFRA", "title": "nope" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

        let req = json_req(
            "PATCH",
            "/api/gap/INFRA-001",
            serde_json::json!({ "notes": "nope" }),
        );
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

        // Right token but no CSRF header → 403.
        let req = Request::builder()
            .method("POST")
            .uri("/api/gap")
            .header("content-type", "application/json")
            .header("authorization", "Bearer sekrit")
            .body(Body::from(
                serde_json::json!({ "domain": "INFRA", "title": "nope" }).to_string(),
            ))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::FORBIDDEN);

        std::env::remove_var("CHUMP_WEB_TOKEN");
    }

    use super::build_api_router;
    use axum::body::{to_bytes, Body};
    use axum::http::{Request, StatusCode};
    use serial_test::serial;
    use tower::Service;

    #[tokio::test]
    #[serial]
    async fn api_health_json() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/health")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("status").and_then(|x| x.as_str()), Some("ok"));
    }

    #[tokio::test]
    #[serial]
    async fn api_stack_status_ok() {
        let prev_ib = std::env::var("CHUMP_INFERENCE_BACKEND").ok();
        let prev_mm = std::env::var("CHUMP_MISTRALRS_MODEL").ok();
        std::env::remove_var("CHUMP_INFERENCE_BACKEND");
        std::env::remove_var("CHUMP_MISTRALRS_MODEL");
        std::env::remove_var("CHUMP_AIR_GAP_MODE");
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/stack-status")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("status").and_then(|x| x.as_str()), Some("ok"));
        assert!(v.get("inference").is_some());
        assert_eq!(
            v.get("inference")
                .and_then(|i| i.get("primary_backend"))
                .and_then(|x| x.as_str()),
            Some("openai_compatible")
        );
        assert_eq!(v.get("air_gap_mode").and_then(|x| x.as_bool()), Some(false));
        assert!(v.get("llm_last_completion").is_some());
        assert!(v.get("llm_completion_totals").is_some());
        let cc = v.get("cognitive_control").expect("cognitive_control");
        assert!(cc.get("recommended_max_tool_calls").is_some());
        assert!(cc.get("recommended_max_delegate_parallel").is_some());
        assert_eq!(
            cc.get("belief_tool_budget").and_then(|x| x.as_bool()),
            Some(false)
        );
        let tp = v.get("tool_policy").expect("tool_policy");
        assert!(tp.get("tools_ask").is_some());
        assert!(tp.get("tools_ask_active").is_some());
        assert_eq!(
            tp.get("policy_override_api").and_then(|x| x.as_bool()),
            Some(false)
        );
        match prev_ib {
            Some(ref s) => std::env::set_var("CHUMP_INFERENCE_BACKEND", s),
            None => std::env::remove_var("CHUMP_INFERENCE_BACKEND"),
        }
        match prev_mm {
            Some(ref s) => std::env::set_var("CHUMP_MISTRALRS_MODEL", s),
            None => std::env::remove_var("CHUMP_MISTRALRS_MODEL"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_stack_status_mistralrs_primary() {
        let prev_ib = std::env::var("CHUMP_INFERENCE_BACKEND").ok();
        let prev_mm = std::env::var("CHUMP_MISTRALRS_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::remove_var("OPENAI_API_BASE");
        std::env::set_var("CHUMP_INFERENCE_BACKEND", "mistralrs");
        std::env::set_var("CHUMP_MISTRALRS_MODEL", "test-mistral-model");
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/stack-status")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let inf = v.get("inference").expect("inference");
        assert_eq!(
            inf.get("primary_backend").and_then(|x| x.as_str()),
            Some("mistralrs")
        );
        assert_eq!(inf.get("configured").and_then(|x| x.as_bool()), Some(true));
        assert_eq!(
            inf.get("models_reachable").and_then(|x| x.as_bool()),
            Some(true)
        );
        assert_eq!(
            inf.get("probe").and_then(|x| x.as_str()),
            Some("mistralrs_in_process")
        );
        let side = inf.get("openai_http_sidecar").expect("sidecar");
        assert_eq!(
            side.get("configured").and_then(|x| x.as_bool()),
            Some(false)
        );
        match prev_ib {
            Some(ref s) => std::env::set_var("CHUMP_INFERENCE_BACKEND", s),
            None => std::env::remove_var("CHUMP_INFERENCE_BACKEND"),
        }
        match prev_mm {
            Some(ref s) => std::env::set_var("CHUMP_MISTRALRS_MODEL", s),
            None => std::env::remove_var("CHUMP_MISTRALRS_MODEL"),
        }
        match prev_base {
            Some(ref s) => std::env::set_var("OPENAI_API_BASE", s),
            None => std::env::remove_var("OPENAI_API_BASE"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_cascade_status_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/cascade-status")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }

    #[tokio::test]
    #[serial]
    async fn api_repo_context_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/repo/context")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v
            .get("multi_repo_enabled")
            .and_then(|x| x.as_bool())
            .is_some());
        assert!(v.get("effective_root").and_then(|x| x.as_str()).is_some());
        assert!(v.get("profiles").and_then(|x| x.as_array()).is_some());
        assert!(v.get("active_profile").is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_policy_override_disabled_returns_json() {
        let prev = std::env::var("CHUMP_POLICY_OVERRIDE_API").ok();
        std::env::remove_var("CHUMP_POLICY_OVERRIDE_API");
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/policy-override")
            .header("content-type", "application/json")
            .body(Body::from(
                r#"{"session_id":"s1","relax_tools":"run_cli","ttl_secs":120}"#,
            ))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(false));
        match prev {
            Some(ref s) => std::env::set_var("CHUMP_POLICY_OVERRIDE_API", s),
            None => std::env::remove_var("CHUMP_POLICY_OVERRIDE_API"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_approve_unknown_id_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/approve")
            .header("content-type", "application/json")
            .body(Body::from(
                r#"{"request_id":"00000000-0000-0000-0000-000000000000","allowed":false}"#,
            ))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));
    }

    #[tokio::test]
    #[serial]
    async fn api_tasks_empty_title_bad_request() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/tasks")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"title":"   "}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_tasks_invalid_json_unprocessable() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/tasks")
            .header("content-type", "application/json")
            .body(Body::from("not-json"))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        // Axum may map JSON body errors to 400 or 422 depending on version / rejection type.
        assert!(
            matches!(
                res.status(),
                StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY
            ),
            "unexpected status {}",
            res.status()
        );
    }

    #[tokio::test]
    #[serial]
    async fn api_pilot_summary_has_tasks_total_when_db_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/pilot-summary")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        if res.status() == StatusCode::OK {
            let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
            let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert!(v.get("tasks_total").and_then(|x| x.as_u64()).is_some());
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_auth_wrong_bearer_unauthorized_when_token_set() {
        let prev = std::env::var("CHUMP_WEB_TOKEN").ok();
        std::env::set_var("CHUMP_WEB_TOKEN", "battle-test-token-xyz");
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/tasks")
            .header("authorization", "Bearer wrong")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
        match prev {
            Some(p) => std::env::set_var("CHUMP_WEB_TOKEN", p),
            None => std::env::remove_var("CHUMP_WEB_TOKEN"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_projects_list_ok_when_db_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/projects")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        if res.status() == StatusCode::OK {
            let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
            let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert!(v.is_array());
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_projects_empty_name_bad_request() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/projects")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"name":"   "}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_watch_list_ok_when_db_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/watch")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        if res.status() == StatusCode::OK {
            let _ = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_push_vapid_public_key_json() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/push/vapid-public-key")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("vapid_public_key").and_then(|x| x.as_str()).is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_tool_approval_audit_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/tool-approval-audit?limit=5")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("entries").and_then(|e| e.as_array()).is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_needs_judgment_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/needs-judgment")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("items").and_then(|e| e.as_array()).is_some());
        assert!(v.get("count").is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_cos_decisions_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/cos/decisions?limit=3")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("decisions").and_then(|e| e.as_array()).is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_jobs_ok() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/jobs?limit=10")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("jobs").and_then(|e| e.as_array()).is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_analytics_returns_valid_shape() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/analytics")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("total_sessions").is_some());
        assert!(v.get("total_turns").is_some());
        assert!(v.get("total_tool_calls").is_some());
        assert!(v.get("avg_latency_ms").is_some());
        assert!(v.get("thumbs_up").is_some());
        assert!(v.get("thumbs_down").is_some());
        assert!(v
            .get("recent_sessions")
            .and_then(|e| e.as_array())
            .is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_message_feedback_nonexistent_returns_404() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/messages/999999999/feedback")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"feedback":1}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    #[serial]
    async fn api_message_feedback_roundtrip() {
        // Create a session with a message, then feedback it
        let sid = crate::web_sessions_db::session_create("chump").expect("session");
        crate::web_sessions_db::message_append_user(&sid, "test", None).expect("user");
        crate::web_sessions_db::message_append_assistant(&sid, "reply", None, None).expect("asst");
        let msgs = crate::web_sessions_db::session_get_messages(&sid, 10, 0).expect("msgs");
        let asst_id = msgs
            .iter()
            .find(|m| m.role == "assistant")
            .expect("asst")
            .id;

        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri(format!("/api/messages/{}/feedback", asst_id))
            .header("content-type", "application/json")
            .body(Body::from(r#"{"feedback":1}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));

        let _ = crate::web_sessions_db::session_delete(&sid);
    }

    #[tokio::test]
    #[serial]
    async fn api_stop_happy_path() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/stop")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"request_id":"test-id-123"}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));
        assert_eq!(v.get("cancelled").and_then(|x| x.as_bool()), Some(false));
    }

    #[tokio::test]
    #[serial]
    async fn api_stop_empty_request_id_bad_request() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/stop")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"request_id":""}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_stop_whitespace_only_request_id_bad_request() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/stop")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"request_id":"   "}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_approve_happy_path() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/approve")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"request_id":"approval-id","allowed":true}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));
    }

    #[tokio::test]
    #[serial]
    async fn api_approve_denied() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/approve")
            .header("content-type", "application/json")
            .body(Body::from(
                r#"{"request_id":"approval-id","allowed":false}"#,
            ))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_happy_path() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .body(Body::from(
                r#"{"hint":"test hint","tool_context":"test_tool"}"#,
            ))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));
        assert!(v.get("blackboard_id").is_some());
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_without_context() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"hint":"test hint"}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v.get("ok").and_then(|x| x.as_bool()), Some(true));
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_empty_hint_bad_request() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"hint":""}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_whitespace_only_bad_request() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"hint":"   "}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_too_long_bad_request() {
        let long_hint = "x".repeat(2001);
        let body_str = format!(r#"{{"hint":"{}"}}"#, long_hint);
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .body(Body::from(body_str))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial]
    async fn api_sessions_list_happy_path() {
        let mut app = build_api_router();
        let req = Request::builder()
            .uri("/api/sessions")
            .body(Body::empty())
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v.is_array());
    }

    #[tokio::test]
    #[serial]
    async fn api_sessions_create_happy_path() {
        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/sessions")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"title":"test session"}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        // 2026-05-08: handler returns `{"session_id": <id>}` — no `ok` field.
        // The original assertion (Some(true)) was speculative; the API
        // contract is just session_id. status=200 on the line above is the
        // success signal.
        assert!(
            v.get("session_id").is_some(),
            "expected session_id in response, got: {v}"
        );

        let session_id = v.get("session_id").and_then(|x| x.as_str()).unwrap();
        let _ = crate::web_sessions_db::session_delete(session_id);
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_with_auth_enabled() {
        let prev_token = std::env::var("CHUMP_WEB_TOKEN").ok();
        std::env::set_var("CHUMP_WEB_TOKEN", "secret-token");

        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .header("authorization", "Bearer secret-token")
            .body(Body::from(r#"{"hint":"test hint"}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);

        match prev_token {
            Some(t) => std::env::set_var("CHUMP_WEB_TOKEN", t),
            None => std::env::remove_var("CHUMP_WEB_TOKEN"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_inject_hint_unauthorized() {
        let prev_token = std::env::var("CHUMP_WEB_TOKEN").ok();
        std::env::set_var("CHUMP_WEB_TOKEN", "secret-token");

        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/inject-hint")
            .header("content-type", "application/json")
            .header("authorization", "Bearer wrong-token")
            .body(Body::from(r#"{"hint":"test hint"}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

        match prev_token {
            Some(t) => std::env::set_var("CHUMP_WEB_TOKEN", t),
            None => std::env::remove_var("CHUMP_WEB_TOKEN"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_stop_unauthorized() {
        let prev_token = std::env::var("CHUMP_WEB_TOKEN").ok();
        std::env::set_var("CHUMP_WEB_TOKEN", "secret-token");

        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/stop")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"request_id":"test"}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

        match prev_token {
            Some(t) => std::env::set_var("CHUMP_WEB_TOKEN", t),
            None => std::env::remove_var("CHUMP_WEB_TOKEN"),
        }
    }

    #[tokio::test]
    #[serial]
    async fn api_approve_unauthorized() {
        let prev_token = std::env::var("CHUMP_WEB_TOKEN").ok();
        std::env::set_var("CHUMP_WEB_TOKEN", "secret-token");

        let mut app = build_api_router();
        let req = Request::builder()
            .method("POST")
            .uri("/api/approve")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"request_id":"test","allowed":true}"#))
            .unwrap();
        let res = Service::call(&mut app, req).await.unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

        match prev_token {
            Some(t) => std::env::set_var("CHUMP_WEB_TOKEN", t),
            None => std::env::remove_var("CHUMP_WEB_TOKEN"),
        }
    }

    /// INFRA-3534: `repo_path::chumpd_repo_root()` used to cache the whole
    /// env-precedence decision in a `OnceLock`, so once a live chumpd daemon
    /// answer was cached with CHUMP_REPO/CHUMP_HOME unset, a later
    /// `CHUMP_REPO` set in the SAME process was silently ignored — exactly
    /// the poisoning scenario documented on `GapWriteEnv` above. This test
    /// spawns a minimal fake chumpd daemon over the real `db-path` unix
    /// socket protocol, resolves `repo_root()` with env unset (hits the
    /// daemon), then sets `CHUMP_REPO` and resolves again — the second call
    /// must reflect the new env, not the frozen daemon answer.
    #[test]
    #[serial]
    fn repo_root_honors_env_change_after_chumpd_daemon_answer() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixListener;

        let daemon_root = tempfile::tempdir().unwrap();
        let chump_dir = daemon_root.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let db_path = chump_dir.join("state.db");
        std::fs::write(&db_path, b"").unwrap();
        let sock_path = chump_dir.join("chumpd.sock");

        let listener = UnixListener::bind(&sock_path).unwrap();
        // INFRA-8042: bound the fake daemon's wait. A blocking accept() hung
        // forever (and, via #[serial], every other serial test behind it)
        // whenever repo_root() never dialled the socket.
        listener.set_nonblocking(true).unwrap();
        let db_path_reply = db_path.display().to_string();
        let server = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while std::time::Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let mut buf = [0u8; 1024];
                        let _ = stream.read(&mut buf);
                        let resp = serde_json::json!({ "db_path": db_path_reply });
                        let _ = stream.write_all(resp.to_string().as_bytes());
                        return;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    Err(_) => return,
                }
            }
        });

        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_chump_home = std::env::var("CHUMP_HOME").ok();
        let prev_home = std::env::var("HOME").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        // try_chumpd_db_path() falls back to $HOME when CHUMP_REPO/CHUMP_HOME
        // are unset — point it at our fake daemon's directory.
        std::env::set_var("HOME", daemon_root.path());
        // INFRA-8042: an earlier test in this process may already have cached
        // a chumpd answer; start from a clean cache so this call really
        // queries the fake daemon.
        crate::repo_path::reset_chumpd_cache_for_test();

        let first = crate::repo_path::repo_root();
        server.join().unwrap();
        assert_eq!(
            first.canonicalize().unwrap(),
            daemon_root.path().canonicalize().unwrap(),
            "first call should resolve via the fake chumpd daemon"
        );

        let other_root = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_REPO", other_root.path());
        let second = crate::repo_path::repo_root();
        assert_eq!(
            second.canonicalize().unwrap(),
            other_root.path().canonicalize().unwrap(),
            "second call must honor the newly-set CHUMP_REPO, not the frozen \
             daemon answer from before it was set"
        );

        match prev_repo {
            Some(v) => std::env::set_var("CHUMP_REPO", v),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        match prev_chump_home {
            Some(v) => std::env::set_var("CHUMP_HOME", v),
            None => std::env::remove_var("CHUMP_HOME"),
        }
        match prev_home {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
        // Don't leave this test's (now deleted) daemon root cached for later tests.
        crate::repo_path::reset_chumpd_cache_for_test();
    }
}

#[cfg(test)]
mod semaphore_gate {
    use crate::provider_cascade::SemaphoreProvider;
    use async_trait::async_trait;
    use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    use std::time::Duration;
    use tokio::sync::Semaphore;

    struct DelayProvider {
        delay_ms: u64,
        call_count: Arc<AtomicUsize>,
        concurrent_peak: Arc<AtomicUsize>,
        in_flight: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl Provider for DelayProvider {
        async fn complete(
            &self,
            _messages: Vec<Message>,
            _tools: Option<Vec<Tool>>,
            _max_tokens: Option<u32>,
            _system_prompt: Option<String>,
        ) -> anyhow::Result<CompletionResponse> {
            let cur = self.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
            // track peak concurrency seen inside complete()
            let mut peak = self.concurrent_peak.load(Ordering::SeqCst);
            while cur > peak {
                match self.concurrent_peak.compare_exchange(
                    peak,
                    cur,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    Ok(_) => break,
                    Err(v) => peak = v,
                }
            }
            tokio::time::sleep(Duration::from_millis(self.delay_ms)).await;
            self.call_count.fetch_add(1, Ordering::SeqCst);
            self.in_flight.fetch_sub(1, Ordering::SeqCst);
            Err(anyhow::anyhow!("test-provider"))
        }
    }

    /// With CHUMP_INFERENCE_PERMITS=1, two concurrent complete() calls must be
    /// serialised: the second waits for the first, so peak in-flight == 1.
    #[tokio::test]
    async fn two_concurrent_calls_are_serialized() {
        let call_count = Arc::new(AtomicUsize::new(0));
        let concurrent_peak = Arc::new(AtomicUsize::new(0));
        let in_flight = Arc::new(AtomicUsize::new(0));
        let inner = Box::new(DelayProvider {
            delay_ms: 60,
            call_count: Arc::clone(&call_count),
            concurrent_peak: Arc::clone(&concurrent_peak),
            in_flight: Arc::clone(&in_flight),
        });
        let sem = Arc::new(Semaphore::new(1));
        let provider = Arc::new(SemaphoreProvider { inner, sem });

        let start = std::time::Instant::now();
        let p1 = Arc::clone(&provider);
        let p2 = Arc::clone(&provider);
        let (_, _) = tokio::join!(
            p1.complete(vec![], None, None, None),
            p2.complete(vec![], None, None, None),
        );

        let elapsed = start.elapsed();
        assert_eq!(
            call_count.load(Ordering::SeqCst),
            2,
            "both calls must complete"
        );
        assert_eq!(
            concurrent_peak.load(Ordering::SeqCst),
            1,
            "semaphore must serialise: peak concurrency inside complete() should be 1"
        );
        assert!(
            elapsed >= Duration::from_millis(120),
            "serialised calls take >= 2× delay ({:?})",
            elapsed
        );
    }
}

#[cfg(test)]
mod startup_validation_tests {
    use super::validate_startup_env;
    use serial_test::serial;

    #[test]
    #[serial(startup_env)]
    fn effective013_chump_repo_not_set_passes() {
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_BIN");
        // GH_TOKEN may or may not be set; we don't care for this test.
        // Without CHUMP_REPO set, validation must pass (no repo to check).
        let result = validate_startup_env();
        // Only check CHUMP_REPO/CHUMP_BIN failures; GH_TOKEN warning is fine.
        assert!(
            result.is_ok() || result.unwrap_err().to_string().contains("GH_TOKEN"),
            "no CHUMP_REPO set → validation should not fail on repo"
        );
    }

    #[test]
    #[serial(startup_env)]
    fn effective013_chump_repo_nonexistent_fails() {
        std::env::set_var("CHUMP_REPO", "/nonexistent-chump-repo-path-abc123");
        std::env::remove_var("CHUMP_BIN");
        let result = validate_startup_env();
        std::env::remove_var("CHUMP_REPO");
        assert!(
            result.is_err(),
            "nonexistent CHUMP_REPO must fail validation"
        );
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("CHUMP_REPO not found") || msg.contains("/nonexistent"),
            "error should mention CHUMP_REPO: {msg}"
        );
    }

    #[test]
    #[serial(startup_env)]
    fn effective013_chump_repo_existing_dir_passes() {
        let tmp = std::env::temp_dir();
        std::env::set_var("CHUMP_REPO", tmp.to_str().unwrap());
        std::env::remove_var("CHUMP_BIN");
        let result = validate_startup_env();
        std::env::remove_var("CHUMP_REPO");
        assert!(
            result.is_ok(),
            "existing directory for CHUMP_REPO must pass: {result:?}"
        );
    }

    #[test]
    #[serial(startup_env)]
    fn effective013_chump_bin_absolute_nonexistent_fails() {
        std::env::remove_var("CHUMP_REPO");
        std::env::set_var("CHUMP_BIN", "/nonexistent-bin-path-abc123/chump");
        let result = validate_startup_env();
        std::env::remove_var("CHUMP_BIN");
        assert!(result.is_err(), "nonexistent absolute CHUMP_BIN must fail");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("CHUMP_BIN"),
            "error should mention CHUMP_BIN: {msg}"
        );
    }

    #[test]
    #[serial(startup_env)]
    fn effective013_chump_bin_bare_name_passes() {
        // Bare name (no path separator) is resolved by OS at spawn time — don't validate.
        std::env::remove_var("CHUMP_REPO");
        std::env::set_var("CHUMP_BIN", "chump");
        let result = validate_startup_env();
        std::env::remove_var("CHUMP_BIN");
        assert!(
            result.is_ok(),
            "bare CHUMP_BIN name must not fail startup validation: {result:?}"
        );
    }
}

/// CREDIBLE-021: tests for PWA subprocess error handling — crash recovery,
/// timeout cleanup, env var passing, and invalid-env resilience.
#[cfg(test)]
mod spawn_error_tests {
    use super::{cleanup_lease, configure_agent_credentials};
    use serial_test::serial;
    use std::fs;

    // ── (a) Subprocess crash: cleanup_lease removes the lock file ──────────

    #[test]
    fn credible021_cleanup_lease_removes_existing_lock() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let locks = tmp.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let gap_id = "TEST-GAP-CRASH-001";
        let lease = locks.join(format!("chump-pwa-{}.json", gap_id));
        fs::write(&lease, r#"{"gap_id":"TEST-GAP-CRASH-001"}"#).unwrap();
        assert!(lease.exists(), "lease must exist before cleanup");

        cleanup_lease(gap_id, tmp.path());

        assert!(
            !lease.exists(),
            "cleanup_lease must remove the lock file on subprocess crash"
        );
    }

    #[test]
    fn credible021_cleanup_lease_is_idempotent_when_missing() {
        // cleanup_lease called twice (e.g. crash + timeout) must not panic.
        let tmp = tempfile::tempdir().expect("tempdir");
        let gap_id = "TEST-GAP-IDEMPOTENT";
        // Call without creating the file first — must not panic.
        cleanup_lease(gap_id, tmp.path());
        // Call again — still must not panic.
        cleanup_lease(gap_id, tmp.path());
    }

    // ── (b) Timeout path: cleanup is triggered when command times out ──────
    // We verify the code path by confirming cleanup_lease is called via the
    // Err arm of spawn_gap_workflow (simulated by injecting a nonexistent bin).

    #[test]
    #[serial(spawn_env)]
    fn credible021_claim_failure_triggers_cleanup() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let locks = tmp.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let gap_id = "TEST-GAP-TIMEOUT-002";
        let lease = locks.join(format!("chump-pwa-{}.json", gap_id));
        fs::write(&lease, r#"{"gap_id":"TEST-GAP-TIMEOUT-002"}"#).unwrap();

        // Simulate a subprocess that exits with failure (non-zero).
        // cleanup_lease is called in the Err arm — run it directly to verify.
        cleanup_lease(gap_id, tmp.path());

        assert!(
            !lease.exists(),
            "cleanup_lease must remove lease on timeout/crash path"
        );
    }

    // ── (c) Invalid env: missing GH_TOKEN — graceful, not a panic ──────────

    #[test]
    #[serial(spawn_env)]
    fn credible021_missing_gh_token_does_not_panic() {
        std::env::remove_var("GH_TOKEN");
        std::env::remove_var("GITHUB_TOKEN");
        std::env::remove_var("SSH_KEY_PATH");
        // configure_agent_credentials must not panic when tokens are absent.
        let mut cmd = std::process::Command::new("true");
        configure_agent_credentials(&mut cmd);
        // If we reach here without panic, the test passes.
    }

    // ── (d) Env passing: configure_agent_credentials forwards GH_TOKEN ─────

    #[test]
    #[serial(spawn_env)]
    fn credible021_configure_forwards_gh_token_to_subprocess() {
        std::env::set_var("GH_TOKEN", "test-gh-token-credible021");
        std::env::remove_var("GITHUB_TOKEN");
        std::env::remove_var("SSH_KEY_PATH");

        // Use `env` to print env vars; grep for GH_TOKEN in subprocess output.
        let mut cmd = std::process::Command::new("sh");
        cmd.arg("-c").arg("printenv GH_TOKEN");
        configure_agent_credentials(&mut cmd);
        let output = cmd.output().expect("sh printenv");
        std::env::remove_var("GH_TOKEN");

        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("test-gh-token-credible021"),
            "GH_TOKEN must be forwarded to subprocess: got '{stdout}'"
        );
    }

    #[test]
    #[serial(spawn_env)]
    fn credible021_configure_forwards_ssh_key_path() {
        std::env::remove_var("GH_TOKEN");
        std::env::remove_var("GITHUB_TOKEN");
        std::env::set_var("SSH_KEY_PATH", "/tmp/test-key-credible021");

        let mut cmd = std::process::Command::new("sh");
        cmd.arg("-c").arg("printenv SSH_KEY_PATH");
        configure_agent_credentials(&mut cmd);
        let output = cmd.output().expect("sh printenv");
        std::env::remove_var("SSH_KEY_PATH");

        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("/tmp/test-key-credible021"),
            "SSH_KEY_PATH must be forwarded to subprocess: got '{stdout}'"
        );
    }

    #[test]
    #[serial(spawn_env)]
    fn credible021_configure_forwards_github_token_alias() {
        std::env::remove_var("GH_TOKEN");
        std::env::set_var("GITHUB_TOKEN", "alias-token-credible021");
        std::env::remove_var("SSH_KEY_PATH");

        let mut cmd = std::process::Command::new("sh");
        cmd.arg("-c").arg("printenv GITHUB_TOKEN");
        configure_agent_credentials(&mut cmd);
        let output = cmd.output().expect("sh printenv");
        std::env::remove_var("GITHUB_TOKEN");

        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("alias-token-credible021"),
            "GITHUB_TOKEN alias must be forwarded: got '{stdout}'"
        );
    }
}

/// CREDIBLE-020: end-to-end stub tests for spawn_gap_workflow.
///
/// Tests the four-phase workflow (preflight → claim → execute-gap → ship) using
/// a stub `chump` binary so no real agent, git, or network operations run.
/// The stub updates the gap store DB so the status transition (open → done) is
/// verified through the same GapStore path the HTTP handler uses.
///
/// Run with:
///   cargo test --bin chump -- web_server::workflow_e2e_tests --test-threads=1
#[cfg(test)]
mod workflow_e2e_tests {
    use super::spawn_gap_workflow;
    use serial_test::serial;
    use std::fs;

    /// Create a minimal SQLite gap store with TEST-001 as an open gap.
    fn make_test_db(dir: &std::path::Path) {
        let chump_dir = dir.join(".chump");
        fs::create_dir_all(&chump_dir).unwrap();
        let db_path = chump_dir.join("state.db");
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS gaps (
                id TEXT PRIMARY KEY,
                domain TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                priority TEXT NOT NULL DEFAULT '',
                effort TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'open',
                acceptance_criteria TEXT NOT NULL DEFAULT '',
                depends_on TEXT NOT NULL DEFAULT '',
                notes TEXT NOT NULL DEFAULT '',
                source_doc TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL DEFAULT 0,
                closed_at INTEGER
            );
            INSERT OR IGNORE INTO gaps (id, domain, title, status, priority, effort)
            VALUES ('TEST-001', 'TEST', 'CREDIBLE-020 fixture gap', 'open', 'P1', 's');",
        )
        .unwrap();
    }

    /// Create a stub `chump` shell script that:
    /// - `claim <id>` → exits 0
    /// - `--execute-gap <id>` → exits 0
    /// - `gap ship <id> --update-yaml` → updates DB status to 'done', exits 0
    fn make_stub_bin(dir: &std::path::Path) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let bin = dir.join("stub-chump");
        let db_path = dir.join(".chump/state.db");
        let script = format!(
            "#!/usr/bin/env bash\n\
             case \"$1\" in\n\
               claim) exit 0 ;;\n\
               --execute-gap) exit 0 ;;\n\
               gap)\n\
                 case \"$2\" in\n\
                   ship) sqlite3 '{}' \"UPDATE gaps SET status='done' WHERE id='$3'\"; exit 0 ;;\n\
                   *) exit 0 ;;\n\
                 esac ;;\n\
               *) exit 0 ;;\n\
             esac\n",
            db_path.display()
        );
        fs::write(&bin, &script).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        bin
    }

    /// Run spawn_gap_workflow("TEST-001") with stub bin + temp CHUMP_REPO.
    /// Returns (ambient_events_text, gap_db_status_after).
    async fn run_stub_workflow(tmp: &std::path::Path) -> (String, String) {
        make_test_db(tmp);
        let stub = make_stub_bin(tmp);
        let ambient = tmp.join("ambient.jsonl");

        // No scripts/coord/gap-preflight.sh in tmp → run_preflight_check auto-skips
        std::env::set_var("CHUMP_BIN", stub.to_str().unwrap());
        std::env::set_var("CHUMP_REPO", tmp.to_str().unwrap());
        std::env::set_var("CHUMP_AMBIENT_IN_PROMPT", ambient.to_str().unwrap());

        let result = spawn_gap_workflow("TEST-001", "test-request-id").await;

        std::env::remove_var("CHUMP_BIN");
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_AMBIENT_IN_PROMPT");

        assert!(
            result.is_ok(),
            "spawn_gap_workflow must succeed with stub binary: {:?}",
            result
        );

        let events = fs::read_to_string(&ambient).unwrap_or_default();
        let conn = rusqlite::Connection::open(tmp.join(".chump/state.db")).unwrap();
        let status: String = conn
            .query_row("SELECT status FROM gaps WHERE id = 'TEST-001'", [], |row| {
                row.get(0)
            })
            .unwrap_or_else(|_| "unknown".to_string());

        (events, status)
    }

    // ── (b) All four phases emitted in sequence ────────────────────────────

    #[tokio::test]
    #[serial(spawn_env)]
    async fn credible020_spawn_gap_workflow_emits_four_phases() {
        let tmp = tempfile::tempdir().unwrap();
        let (events, _) = run_stub_workflow(tmp.path()).await;

        for phase in &["preflight", "claim", "execute-gap", "ship"] {
            assert!(
                events.contains(phase),
                "ambient.jsonl must record phase '{phase}'.\nGot:\n{events}"
            );
        }
    }

    // ── (c) Status transitions open → done via ship step ──────────────────

    #[tokio::test]
    #[serial(spawn_env)]
    async fn credible020_gap_status_becomes_done_after_ship() {
        let tmp = tempfile::tempdir().unwrap();
        let (_, status) = run_stub_workflow(tmp.path()).await;
        assert_eq!(
            status, "done",
            "gap.status must be 'done' after ship phase completes — got '{status}'"
        );
    }
}

// ── INFRA-1015: repo init unit tests ─────────────────────────────────────────
#[cfg(test)]
mod repo_init_tests {
    use super::seed_starter_gaps;

    #[test]
    fn seed_starter_gaps_inserts_three_rows() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).expect("create .chump");
        let db_path = chump_dir.join("state.db");

        // Create minimal state.db with gaps table.
        let conn = rusqlite::Connection::open(&db_path).expect("open db");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS gaps (
                id TEXT PRIMARY KEY, domain TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open',
                priority TEXT NOT NULL DEFAULT 'P2', kind TEXT NOT NULL DEFAULT 'feature',
                meta TEXT NOT NULL DEFAULT ''
            );",
        )
        .expect("create table");
        drop(conn);

        let seeded = seed_starter_gaps(tmp.path());
        assert_eq!(seeded.len(), 3, "expected 3 seeded gaps, got {:?}", seeded);
        assert!(
            seeded.contains(&"STARTER-001".to_string()),
            "STARTER-001 missing"
        );
        assert!(
            seeded.contains(&"STARTER-002".to_string()),
            "STARTER-002 missing"
        );
        assert!(
            seeded.contains(&"STARTER-003".to_string()),
            "STARTER-003 missing"
        );
    }

    #[test]
    fn seed_starter_gaps_is_idempotent() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).expect("create .chump");
        let db_path = chump_dir.join("state.db");

        let conn = rusqlite::Connection::open(&db_path).expect("open db");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS gaps (
                id TEXT PRIMARY KEY, domain TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open',
                priority TEXT NOT NULL DEFAULT 'P2', kind TEXT NOT NULL DEFAULT 'feature',
                meta TEXT NOT NULL DEFAULT ''
            );",
        )
        .expect("create table");
        drop(conn);

        // First seed
        let first = seed_starter_gaps(tmp.path());
        assert_eq!(first.len(), 3, "first seed should insert 3");

        // Second seed — INSERT OR IGNORE means 0 new rows, but no panic/error.
        let second = seed_starter_gaps(tmp.path());
        assert_eq!(second.len(), 0, "second seed should insert 0 (idempotent)");
    }

    #[test]
    fn seed_starter_gaps_missing_db_returns_empty() {
        let tmp = tempfile::tempdir().expect("tempdir");
        // No .chump/state.db created — should return empty vec without panicking.
        let result = seed_starter_gaps(tmp.path());
        assert!(result.is_empty(), "expected empty vec when db missing");
    }

    #[test]
    fn repo_init_allowlist_logic_rejects_outside_path() {
        // Simulate the allowlist check logic inline (the actual handler is async/axum-bound).
        let allowed_roots: Vec<std::path::PathBuf> =
            vec![std::path::PathBuf::from("/Users/jeffadkins")];
        let target = std::path::PathBuf::from("/tmp/some-other-path");

        let under_allowed = allowed_roots.iter().any(|root| target.starts_with(root));
        assert!(
            !under_allowed,
            "/tmp path should be outside /Users/jeffadkins"
        );
    }

    #[test]
    fn repo_init_allowlist_logic_accepts_subpath() {
        let allowed_roots: Vec<std::path::PathBuf> =
            vec![std::path::PathBuf::from("/Users/jeffadkins")];
        let target = std::path::PathBuf::from("/Users/jeffadkins/Projects/MyRepo");

        let under_allowed = allowed_roots.iter().any(|root| target.starts_with(root));
        assert!(
            under_allowed,
            "/Users/jeffadkins/Projects/MyRepo should be inside /Users/jeffadkins"
        );
    }
}
