//! Axum router: REST endpoints + WebSocket live-tail.

use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State, WebSocketUpgrade},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::time::{interval, Duration};
use tower_http::services::ServeDir;

use crate::dashboard;
use crate::db::{now_ms, FleetStore};
use crate::gap_write::{self, GapWriteRequest};
use crate::mission::{self, MissionRequest};

// ── shared state ──────────────────────────────────────────────────────────────

pub type SharedStore = Arc<FleetStore>;

/// Combined application state: the fleet events store plus the repo root path
/// used by the dashboard-summary handler for reading ambient.jsonl, github
/// cache, and claim lease files.
#[derive(Clone)]
pub struct AppState {
    pub store: SharedStore,
    pub repo_root: PathBuf,
}

pub fn build_router(store: SharedStore, repo_root: PathBuf) -> Router {
    // INFRA-5663: the daily cockpit is a single static page served from the
    // repo working tree (kept current with green-main by node-refresh's hard
    // reset), so "merged" reaches "running" with no copy-into-the-binary step.
    let cockpit_dir = repo_root.join("web").join("cockpit-live");
    // INFRA-2176: the fleet-scrubber forensic timeline is a static single-page
    // app that reads this server's /api/segments, /api/events, /api/sessions/active
    // and /api/live routes. It is mounted at /scrubber so `chump fleet view`
    // (scripts/dev/chump-fleet-view.sh) and the README's documented URL
    // (http://localhost:7070/scrubber) resolve against the same origin the API
    // is served from — no CORS, no separate process. Nested before the cockpit
    // fallback so /scrubber/* wins over the catch-all ServeDir.
    let scrubber_dir = repo_root.join("web").join("fleet-scrubber");
    let state = AppState { store, repo_root };
    Router::new()
        .route("/api/events", get(get_events))
        .route("/api/segments", get(get_segments))
        .route("/api/sessions/active", get(get_active_sessions))
        .route("/api/trace/pr/{n}", get(get_trace_pr))
        .route("/api/dashboard-summary", get(get_dashboard_summary))
        .route("/api/debt", get(get_debt))
        .route("/api/debt-index", get(get_debt))
        .route("/api/mission", post(post_mission))
        .route("/api/gap", post(post_gap))
        .route("/api/gaps", get(get_gaps))
        .route("/api/store/gaps", get(get_store_gaps))
        .route("/api/store/gaps/{id}", get(get_store_gap_by_id))
        .route("/api/doc/{name}", get(get_doc))
        .route("/api/sentinel-heartbeat", post(post_sentinel_heartbeat))
        .route("/api/fleet/nodes", get(get_fleet_nodes))
        .route("/api/live", get(ws_live))
        .route("/healthz", get(healthz))
        // INFRA-2176: fleet-scrubber static SPA at /scrubber (append_index so
        // /scrubber serves web/fleet-scrubber/index.html; /scrubber/fixtures/*
        // resolves for ?fixtures=1 demo mode).
        .nest_service(
            "/scrubber",
            ServeDir::new(scrubber_dir).append_index_html_on_directories(true),
        )
        // INFRA-5663: static cockpit page at `/` (and any other non-API path).
        // API routes are matched first; anything unmatched falls through to the
        // static dir, so `/` serves web/cockpit-live/index.html.
        .fallback_service(ServeDir::new(cockpit_dir).append_index_html_on_directories(true))
        .with_state(state)
}

// ── query params ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct EventsQuery {
    pub from: Option<i64>,
    pub to: Option<i64>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct SegmentsQuery {
    pub from: Option<i64>,
    pub to: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
pub struct GapsQuery {
    pub priority: Option<String>,
    pub status: Option<String>,
    pub domain: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct StoreGapsQuery {
    pub status: Option<String>,
    pub priority: Option<String>,
    pub domain: Option<String>,
    pub limit: Option<usize>,
    pub order: Option<String>,
}

// ── response envelopes ────────────────────────────────────────────────────────

#[derive(Serialize)]
struct ActiveSessionsResponse {
    session_ids: Vec<String>,
    count: usize,
}

// ── handlers ──────────────────────────────────────────────────────────────────

/// GET /api/events?from=<ts_ms>&to=<ts_ms>&limit=<N>&offset=<N>
///
/// Returns events in [from, to] ordered by ts_ms ASC.
/// Defaults: from = now-1h, to = now, limit = 10000, offset = 0.
/// Hard cap: limit = 50 000.
async fn get_events(State(s): State<AppState>, Query(q): Query<EventsQuery>) -> Response {
    let now = now_ms();
    let from = q.from.unwrap_or(now - 3_600_000); // last 1h
    let to = q.to.unwrap_or(now);
    let limit = q.limit.unwrap_or(10_000);
    let offset = q.offset.unwrap_or(0);

    match s.store.query_events(from, to, limit, offset) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/events error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/segments?from=<ts_ms>&to=<ts_ms>
///
/// Returns agent_segments rows in window. Defaults: last 1h.
async fn get_segments(State(s): State<AppState>, Query(q): Query<SegmentsQuery>) -> Response {
    let now = now_ms();
    let from = q.from.unwrap_or(now - 3_600_000);
    let to = q.to.unwrap_or(now);

    match s.store.query_segments(from, to) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/segments error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/sessions/active
///
/// Returns distinct session_ids that have at least one event in the last 5 min.
async fn get_active_sessions(State(s): State<AppState>) -> Response {
    match s.store.active_sessions() {
        Ok(ids) => {
            let count = ids.len();
            Json(ActiveSessionsResponse {
                session_ids: ids,
                count,
            })
            .into_response()
        }
        Err(e) => {
            tracing::error!("GET /api/sessions/active error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/trace/pr/:n
///
/// Best-effort causal chain for PR number n.
/// Queries events whose payload matches "pr <N>" or "#<N>", plus bash_call
/// events referencing "gh pr ..." with the PR number.
async fn get_trace_pr(State(s): State<AppState>, Path(n): Path<i64>) -> Response {
    match s.store.trace_pr(n) {
        Ok(rows) => Json(rows).into_response(),
        Err(e) => {
            tracing::error!("GET /api/trace/pr/{n} error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/dashboard-summary (INFRA-1883)
///
/// Returns today's ship count, latest CI QA score, and active leases in one JSON.
/// All fields are populated synchronously in a `spawn_blocking` task to avoid
/// blocking the async runtime while doing file I/O.
async fn get_dashboard_summary(State(s): State<AppState>) -> Response {
    let repo_root = s.repo_root.clone();
    let result = tokio::task::spawn_blocking(move || dashboard::build_summary(&repo_root)).await;

    match result {
        Ok(summary) => Json(summary).into_response(),
        Err(e) => {
            tracing::error!("GET /api/dashboard-summary task error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error building dashboard summary"})),
            )
                .into_response()
        }
    }
}

/// GET /api/debt (and alias GET /api/debt-index) (INFRA-8179)
///
/// Unauthenticated read (matching `/api/dashboard-summary` and `/api/fleet/nodes`)
/// exposing the debt/dormancy crown-metric index (`live_pct`, `debt`,
/// `top5_dormant`, `nba_candidate_count`, `nba_candidates`, `prune_count`).
async fn get_debt(State(s): State<AppState>) -> Response {
    let repo_root = s.repo_root.clone();
    let result = tokio::task::spawn_blocking(move || dashboard::build_debt_index(&repo_root)).await;

    match result {
        Ok(debt) => Json(debt).into_response(),
        Err(e) => {
            tracing::error!("GET /api/debt task error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error building debt index"})),
            )
                .into_response()
        }
    }
}

/// WS /api/live
///
/// On connect: server polls events table every 1s, pushes new rows (since
/// last-sent id) to the WS client as a JSON array per message.
async fn ws_live(State(s): State<AppState>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| handle_ws(socket, s.store))
}

async fn handle_ws(mut socket: axum::extract::ws::WebSocket, store: SharedStore) {
    // Start from the current max id so we only send events that arrive after
    // the client connects.
    let mut last_id = match store.max_event_id() {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("ws: failed to get max event id: {e}");
            return;
        }
    };

    let mut ticker = interval(Duration::from_secs(1));

    loop {
        ticker.tick().await;

        let new_events = match store.events_since(last_id) {
            Ok(rows) => rows,
            Err(e) => {
                tracing::warn!("ws: events_since error: {e}");
                continue;
            }
        };

        if new_events.is_empty() {
            continue;
        }

        // Advance the cursor.
        if let Some(last) = new_events.last() {
            last_id = last.id;
        }

        let payload = match serde_json::to_string(&new_events) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("ws: serialization error: {e}");
                continue;
            }
        };

        let msg = axum::extract::ws::Message::Text(payload.into());
        if socket.send(msg).await.is_err() {
            // Client disconnected.
            tracing::debug!("ws: client disconnected");
            break;
        }
    }
}

/// Shared fail-closed bearer-auth check for the bat-phone routes
/// (`/api/mission`, `/api/gap`, `/api/gaps`). Returns `Some(response)` when
/// the request must be rejected (503 unconfigured / 401 wrong token), or
/// `None` when the caller is authorized to proceed.
fn check_bearer_auth(headers: &axum::http::HeaderMap) -> Option<Response> {
    let Some(expected) = mission::configured_token() else {
        return Some(
            (
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({
                    "error": "bat-phone disabled: CHUMP_BATPHONE_TOKEN not set"
                })),
            )
                .into_response(),
        );
    };
    let presented = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.strip_prefix("Bearer ").unwrap_or(v).trim().to_string())
        .unwrap_or_default();
    if !mission::constant_time_eq(&presented, &expected) {
        return Some(
            (
                axum::http::StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"error": "unauthorized"})),
            )
                .into_response(),
        );
    }
    None
}

/// GET /api/gaps (RESILIENT-1030 / INFRA-8179) — authed read of the gap queue
/// state, sorted by `priority_rank` (`P0 < P1 < P2 < P3`, `critical < high <
/// medium < low`) and filtered by optional `priority`, `status`, and `domain`
/// query parameters.
///
/// Same fail-closed bearer auth as `/api/mission` and `/api/gap`. Lets the
/// operator see what's pickable over the tailnet API instead of
/// SSH+sqlite+`chump gap list`.
async fn get_gaps(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(q): Query<GapsQuery>,
) -> Response {
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    let repo_root = s.repo_root.clone();
    let status = q.status;
    let priority = q.priority;
    let domain = q.domain;
    let result = tokio::task::spawn_blocking(move || {
        gap_write::list_gaps_filtered(
            &repo_root,
            status.as_deref(),
            priority.as_deref(),
            domain.as_deref(),
        )
    })
    .await;

    match result {
        Ok(Ok(gaps)) => Json(gaps).into_response(),
        Ok(Err(e)) => {
            tracing::error!("GET /api/gaps failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("GET /api/gaps task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

/// GET /api/store/gaps (RESILIENT-1700) — canonical SQLite `gaps` table read
/// endpoint for store-over-API organs.
///
/// Queries `gaps` from the configured SQLite `state.db` (`CHUMP_STATE_DB` /
/// `<state_dir>/state.db`) and returns JSON rows with the canonical 15-column
/// SQLite schema (`id, title, description, domain, priority, status, effort,
/// skills_required, acceptance_criteria, depends_on, parent_id, notes,
/// closed_pr, closed_date, created_at`), supporting optional `?status=`,
/// `?priority=`, `?domain=`, `?limit=`, and `?order=id|priority`.
async fn get_store_gaps(State(s): State<AppState>, Query(q): Query<StoreGapsQuery>) -> Response {
    let repo_root = s.repo_root.clone();
    let result = tokio::task::spawn_blocking(move || {
        gap_write::query_store_gaps(
            &repo_root,
            q.status.as_deref(),
            q.priority.as_deref(),
            q.domain.as_deref(),
            q.limit,
            q.order.as_deref(),
        )
    })
    .await;

    match result {
        Ok(Ok(rows)) => (
            [(
                axum::http::header::CONTENT_TYPE,
                "application/json; charset=utf-8",
            )],
            gap_write::format_sqlite_json_array(&rows),
        )
            .into_response(),
        Ok(Err(e)) => {
            tracing::error!("GET /api/store/gaps failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("GET /api/store/gaps task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

/// GET /api/store/gaps/{id} (RESILIENT-1700) — single canonical gap row read by
/// `id` (or 404 if not found).
async fn get_store_gap_by_id(State(s): State<AppState>, Path(id): Path<String>) -> Response {
    let repo_root = s.repo_root.clone();
    let lookup_id = id.clone();
    let result = tokio::task::spawn_blocking(move || {
        gap_write::query_store_gap_by_id(&repo_root, &lookup_id)
    })
    .await;

    match result {
        Ok(Ok(Some(row))) => Json(row).into_response(),
        Ok(Ok(None)) => (
            axum::http::StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": format!("gap {id:?} not found")})),
        )
            .into_response(),
        Ok(Err(e)) => {
            tracing::error!("GET /api/store/gaps/{id} failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("GET /api/store/gaps/{id} task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

/// POST /api/mission — bat-phone external mission intake (EFFECTIVE-513).
///
/// Fail-closed bearer auth via `CHUMP_BATPHONE_TOKEN`. On success it reserves a
/// gap, seeds description + AC, and spawns a detached `chump gap decompose`
/// (never awaited — it runs ~1-2 min under a free-tier LLM and must not block
/// the response or halt the fleet). Returns 202 with the created gap id; the
/// fleet queue picks up the slices on its own cadence.
async fn post_mission(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    payload: Result<Json<MissionRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    // 1. Auth — fail-closed. No token configured => route refuses entirely.
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    // 2. Body.
    let req = match payload {
        Ok(Json(r)) => r,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("invalid JSON body: {e}")})),
            )
                .into_response();
        }
    };
    if req.title.trim().is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "title is required"})),
        )
            .into_response();
    }

    // 3. Reserve + set + spawn decompose off the async runtime (it shells out).
    let repo_root = s.repo_root.clone();
    let result =
        tokio::task::spawn_blocking(move || mission::create_mission_gap(&repo_root, req)).await;

    match result {
        Ok(Ok(outcome)) => (axum::http::StatusCode::ACCEPTED, Json(outcome)).into_response(),
        Ok(Err(e)) => {
            tracing::error!("POST /api/mission failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("POST /api/mission task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

/// POST /api/gap — bat-phone canonical gap-write (INFRA-3689).
///
/// Second dispatch surface alongside `POST /api/mission`: exposes the raw
/// `chump gap reserve|set|ship` primitive over HTTP so a non-canonical/stale
/// client (the operator's Mac) can mutate canonical gap state WITHOUT
/// holding a writable local canonical replica — it delegates the write to
/// this server, which runs on owned iron (CJ) against the real checkout.
///
/// Auth is the EXACT same fail-closed bearer check as `post_mission` — same
/// `CHUMP_BATPHONE_TOKEN` env, same constant-time comparison, same
/// 503-when-unconfigured / 401-when-wrong semantics. `op` is validated
/// against the `reserve|set|ship` allow-list before any shell-out; an
/// unknown op is a 400, never reaches `gap_write::execute_gap_write`.
async fn post_gap(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    payload: Result<Json<GapWriteRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    // 1. Auth — fail-closed, identical to post_mission.
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    // 2. Body.
    let req = match payload {
        Ok(Json(r)) => r,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("invalid JSON body: {e}")})),
            )
                .into_response();
        }
    };

    // 3. op allow-list — 400 before any shell-out.
    if !gap_write::is_valid_op(&req.op) {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": format!(
                    "unsupported op {:?} (allowed: {:?})",
                    req.op,
                    gap_write::ALLOWED_OPS
                )
            })),
        )
            .into_response();
    }

    // 4. Execute off the async runtime (it shells out).
    let repo_root = s.repo_root.clone();
    let result =
        tokio::task::spawn_blocking(move || gap_write::execute_gap_write(&repo_root, req)).await;

    match result {
        Ok(Ok(outcome)) => (axum::http::StatusCode::ACCEPTED, Json(outcome)).into_response(),
        Ok(Err(e)) => {
            // PRODUCT-323: a caller error (e.g. an empty op=set) is a 400, not a 500.
            if e.downcast_ref::<gap_write::InvalidRequest>().is_some() {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"error": e.to_string()})),
                )
                    .into_response();
            }
            tracing::error!("POST /api/gap failed: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("POST /api/gap task join error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "internal error"})),
            )
                .into_response()
        }
    }
}

// ── fleet-health heartbeats (RESILIENT-1055) ──────────────────────────────────

/// Default staleness threshold (seconds): sentinel cadence 5m × stale-mult 3.
/// Overridable via `CHUMP_SENTINEL_STALE_SECS` to stay coherent with the
/// sentinel's own `CHUMP_SENTINEL_CADENCE_MIN` / `CHUMP_SENTINEL_STALE_MULT`.
const DEFAULT_STALE_SECS: i64 = 900;

fn stale_threshold_secs() -> i64 {
    std::env::var("CHUMP_SENTINEL_STALE_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(DEFAULT_STALE_SECS)
}

/// One node's health as reported by its last heartbeat, with server-computed
/// freshness. `health` is the raw heartbeat body re-parsed, so per-organ detail
/// (`failed_units`, `healers`) flows through untouched.
#[derive(Serialize)]
struct FleetNodeHealth {
    node: String,
    epoch: i64,
    received_ms: i64,
    age_secs: i64,
    stale: bool,
    health: serde_json::Value,
}

#[derive(Serialize)]
struct FleetNodesResponse {
    generated_ms: i64,
    stale_threshold_secs: i64,
    node_count: usize,
    stale_count: usize,
    /// Total `failed` chump units summed across all reporting nodes — the
    /// single number that would have caught the 33-failed-organ incident.
    failed_units_total: i64,
    nodes: Vec<FleetNodeHealth>,
}

/// POST /api/sentinel-heartbeat (RESILIENT-1055) — ingest sink for the
/// per-node fleet-health-sentinel heartbeat.
///
/// The sentinel (`scripts/ops/fleet-health-sentinel.sh`) already POSTs its
/// heartbeat file here every pass; before this route it hit a 404 void. Body is
/// the heartbeat JSON: it MUST carry a non-empty `node`; `epoch` (seconds) is
/// used for staleness and falls back to server receive-time when absent. The
/// full body is stored verbatim (keyed by node, latest wins).
///
/// Auth is the EXACT same fail-closed bearer check as the other write routes
/// (`CHUMP_BATPHONE_TOKEN`), so a node pushing over the tailnet authenticates
/// identically to `/api/gap`.
async fn post_sentinel_heartbeat(
    State(s): State<AppState>,
    headers: axum::http::HeaderMap,
    body: String,
) -> Response {
    // 1. Auth — fail-closed, identical to post_gap / post_mission.
    if let Some(rejection) = check_bearer_auth(&headers) {
        return rejection;
    }

    // 2. Parse body as JSON object.
    let value: serde_json::Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("invalid JSON body: {e}")})),
            )
                .into_response();
        }
    };

    // 3. node is required (the aggregation key).
    let node = value
        .get("node")
        .and_then(|v| v.as_str())
        .map(|s| s.trim())
        .unwrap_or_default();
    if node.is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "heartbeat body must include a non-empty \"node\""})),
        )
            .into_response();
    }

    let received_ms = now_ms();
    // epoch (seconds) is the node's own stamp; fall back to receive time.
    let epoch = value
        .get("epoch")
        .and_then(|v| v.as_i64())
        .unwrap_or(received_ms / 1000);

    match s
        .store
        .upsert_node_heartbeat(node, epoch, received_ms, &body)
    {
        Ok(()) => (
            axum::http::StatusCode::ACCEPTED,
            Json(serde_json::json!({"ok": true, "node": node, "epoch": epoch})),
        )
            .into_response(),
        Err(e) => {
            tracing::error!("POST /api/sentinel-heartbeat store error: {e}");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// GET /api/fleet/nodes (RESILIENT-1055) — cross-node organ health, aggregated
/// server-side from the pushed heartbeats.
///
/// Replaces the SSH crawl the sentinel's `--fleet` grade did (the covenant
/// break): the operator reads one route instead of `ssh`-ing each node. Each
/// node reports its `failed` count plus `failed_units` / `healers` detail; the
/// server stamps `age_secs` + `stale` per node so a dead sentinel shows as a
/// stale row rather than silence.
///
/// INFRA-5663: this is an **unauthenticated read**, matching the cockpit spec
/// (`docs/process/COCKPIT.md` §2: reads — events/segments/dashboard-summary/
/// live/fleet/nodes — are open; only mutating routes + `/api/gaps` are
/// Bearer-gated). The daily cockpit page fetches it from an unauthed browser to
/// render the honest "nodes: 1 of 3" tile per `merged-not-running-disease`. The
/// *write* side (`POST /api/sentinel-heartbeat`) stays fail-closed behind
/// `CHUMP_BATPHONE_TOKEN`, and this read is safe only on the tailnet bind — no
/// public exposure without read-auth (RESILIENT-1088).
async fn get_fleet_nodes(State(s): State<AppState>) -> Response {
    let rows = match s.store.list_node_heartbeats() {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("GET /api/fleet/nodes error: {e}");
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": e.to_string()})),
            )
                .into_response();
        }
    };

    let now = now_ms();
    let now_secs = now / 1000;
    let threshold = stale_threshold_secs();
    let mut stale_count = 0usize;
    let mut failed_units_total = 0i64;

    let nodes: Vec<FleetNodeHealth> = rows
        .into_iter()
        .map(|hb| {
            let age_secs = (now_secs - hb.epoch).max(0);
            let stale = age_secs > threshold;
            if stale {
                stale_count += 1;
            }
            // Re-parse the stored body so per-organ detail passes through; on a
            // malformed row fall back to the raw string rather than dropping it.
            let health: serde_json::Value = serde_json::from_str(&hb.payload)
                .unwrap_or_else(|_| serde_json::json!({"raw": hb.payload}));
            failed_units_total += health.get("failed").and_then(|v| v.as_i64()).unwrap_or(0);
            FleetNodeHealth {
                node: hb.node,
                epoch: hb.epoch,
                received_ms: hb.received_ms,
                age_secs,
                stale,
                health,
            }
        })
        .collect();

    Json(FleetNodesResponse {
        generated_ms: now,
        stale_threshold_secs: threshold,
        node_count: nodes.len(),
        stale_count,
        failed_units_total,
        nodes,
    })
    .into_response()
}

/// GET /api/doc/{name} (INFRA-5663) — render an allow-listed durable repo doc
/// straight from the working tree at HEAD.
///
/// The cockpit renders durable knowledge (roadmap, mission) as a *view* of
/// files that already exist in the repo — never a forked copy in the page
/// (`docs/process/COCKPIT.md` §4: "rendered from repo files at HEAD, never
/// forked into the page"). `name` is matched against a fixed allow-list, so
/// there is no path traversal and no arbitrary-file read — only the two Phase-1
/// docs the cockpit needs. This is the Phase-1 seed of the fuller `/docs/*`
/// route (Phase 2). Unauthenticated read, tailnet-only like the other reads.
async fn get_doc(State(s): State<AppState>, Path(name): Path<String>) -> Response {
    // Fixed allow-list: cockpit key -> repo-relative path. No traversal.
    let rel: &str = match name.as_str() {
        "roadmap" => "docs/ROADMAP.md",
        "mission" => "docs/MISSION.md",
        _ => {
            return (
                axum::http::StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": format!("unknown doc {name:?}")})),
            )
                .into_response();
        }
    };

    let path = s.repo_root.join(rel);
    match std::fs::read_to_string(&path) {
        Ok(body) => (
            [(
                axum::http::header::CONTENT_TYPE,
                "text/markdown; charset=utf-8",
            )],
            body,
        )
            .into_response(),
        Err(e) => {
            tracing::warn!("GET /api/doc/{name}: {e}");
            (
                axum::http::StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": format!("doc unavailable: {e}")})),
            )
                .into_response()
        }
    }
}

/// GET /healthz — liveness probe.
async fn healthz() -> &'static str {
    "ok"
}
