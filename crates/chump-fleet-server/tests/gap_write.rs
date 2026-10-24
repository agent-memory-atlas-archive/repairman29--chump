//! Integration tests for POST /api/gap — the canonical gap-write bat-phone
//! surface (INFRA-3689).
//!
//! Mirrors `tests/mission_intake.rs`'s pattern: `axum::Router::oneshot` (no
//! network socket), one combined test so the shared-process
//! `CHUMP_BATPHONE_TOKEN` / `CHUMP_BIN` env vars are mutated sequentially,
//! never racing a parallel test. `CHUMP_BIN` points at a fake `chump`
//! script (deterministic, no real network / no real state.db) so the
//! reserve+outcome path exercises the full `gap_write::execute_gap_write`
//! shell-out sequence — including the INFRA-3686 outcome-forwarding
//! follow-up `gap set` call — without depending on a built release binary.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::mission::{create_mission_gap, MissionRequest, BATPHONE_TOKEN_ENV};
use chump_fleet_server::{db::FleetStore, routes};

fn test_dir() -> PathBuf {
    std::env::temp_dir().join(format!("chump-test-gap-write-{}", std::process::id()))
}

fn build_app(repo_root: &Path) -> axum::Router {
    let store = Arc::new(FleetStore::open(&repo_root.join("fleet_events_test.db")).unwrap());
    routes::build_router(store, repo_root.to_path_buf())
}

/// Fake `chump` binary: understands `gap reserve --domain D --title T
/// --priority P --effort E` (echoes a deterministic gap id to stdout) and
/// `gap set <id> ...` (records the call to a log file so the test can
/// assert the outcome/AC follow-up actually ran, per INFRA-3686). Any other
/// invocation exits 0 with empty stdout — good enough for `ship`/plain
/// `set` calls in this suite.
fn write_fake_chump_bin(dir: &Path, gap_id: &str) -> PathBuf {
    let script_path = dir.join("fake-chump-gap-write");
    let log_path = dir.join("fake-chump.log");
    let body = format!(
        r#"#!/bin/sh
echo "$@" >> "{log}"
case "$1 $2" in
  "gap reserve")
    echo "{id}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"#,
        log = log_path.display(),
        id = gap_id,
    );
    std::fs::write(&script_path, body).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&script_path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&script_path, perms).unwrap();
    }
    script_path
}

async fn post_gap(app: axum::Router, auth: Option<&str>, body: Value) -> (StatusCode, Value) {
    let mut builder = Request::builder()
        .method("POST")
        .uri("/api/gap")
        .header("content-type", "application/json");
    if let Some(a) = auth {
        builder = builder.header("authorization", a);
    }
    let req = builder.body(Body::from(body.to_string())).unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let val: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, val)
}

#[tokio::test]
async fn gap_write_auth_op_validation_and_reserve_with_outcome() {
    let dir = test_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let fake_bin = write_fake_chump_bin(&dir, "INFRA-8471");

    // (a) No token configured -> fail-closed 503.
    std::env::remove_var(BATPHONE_TOKEN_ENV);
    std::env::remove_var("CHUMP_BIN");
    let (status, _) = post_gap(
        build_app(&dir),
        Some("Bearer anything"),
        json!({"op": "reserve", "domain": "INFRA", "title": "x"}),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::SERVICE_UNAVAILABLE,
        "unset token must fail closed"
    );

    // (b) Token configured, missing bearer -> 401.
    std::env::set_var(BATPHONE_TOKEN_ENV, "s3cret-token");
    let (status, _) = post_gap(
        build_app(&dir),
        None,
        json!({"op": "reserve", "domain": "INFRA", "title": "x"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "missing bearer -> 401");

    // (c) Token configured, wrong bearer -> 401.
    let (status, _) = post_gap(
        build_app(&dir),
        Some("Bearer wrong-token"),
        json!({"op": "reserve", "domain": "INFRA", "title": "x"}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "wrong token -> 401");

    // (d) Valid auth, bad op -> 400 (before any shell-out — CHUMP_BIN still
    //     unset here, so a 400 proves the allow-list check runs first).
    let (status, body) = post_gap(
        build_app(&dir),
        Some("Bearer s3cret-token"),
        json!({"op": "delete", "gap_id": "INFRA-1"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "unsupported op -> 400");
    assert!(
        body.get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("")
            .contains("unsupported op"),
        "400 body should name the bad op: {body:?}"
    );

    // (e) Valid auth, op=reserve + outcome -> 202, no 500, outcome forwarded
    //     via a follow-up `gap set` (INFRA-3686 fix under test).
    std::env::set_var("CHUMP_BIN", &fake_bin);
    let (status, body) = post_gap(
        build_app(&dir),
        Some("Bearer s3cret-token"),
        json!({
            "op": "reserve",
            "domain": "INFRA",
            "title": "route mutations through the fleet-server",
            "priority": "P0",
            "outcome": "MISSION-010",
            "effort": "m"
        }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "reserve+outcome must not 500: {body:?}"
    );
    assert_eq!(
        body.get("gap_id").and_then(|v| v.as_str()),
        Some("INFRA-8471")
    );
    assert_eq!(body.get("op").and_then(|v| v.as_str()), Some("reserve"));

    // (e2) PRODUCT-323: an op=set with no recognised field is a 400 (not 500)
    //      and the error names the fields the caller sent.
    let (status, body) = post_gap(
        build_app(&dir),
        Some("Bearer s3cret-token"),
        json!({"op": "set", "gap_id": "INFRA-8471", "note": "hello"}),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "empty set must be 400: {body:?}"
    );
    let err = body.get("error").and_then(|e| e.as_str()).unwrap_or("");
    assert!(err.contains("received fields: [op, gap_id, note]"), "{err}");

    // The fake binary logs every invocation; assert BOTH `gap reserve` and a
    // follow-up `gap set ... --outcome MISSION-010` ran — proving the
    // outcome field was forwarded, not silently dropped (INFRA-3686).
    let log = std::fs::read_to_string(dir.join("fake-chump.log")).unwrap_or_default();
    assert!(
        log.contains("gap reserve"),
        "expected a `gap reserve` call, log:\n{log}"
    );
    assert!(
        log.contains("gap set INFRA-8471") && log.contains("--outcome MISSION-010"),
        "expected outcome forwarded via follow-up `gap set`, log:\n{log}"
    );

    // RESILIENT-1030: this is a P0 reserve with no `evidence` field in the
    // body. Before the fix, `chump gap reserve` would refuse P0/P1
    // RESILIENT/MISSION/CREDIBLE gaps without `--evidence` and this whole
    // dispatch would 500. Assert the route auto-exempts an already-authed
    // bat-phone dispatch via `--no-evidence-required` instead.
    assert!(
        log.contains("--no-evidence-required"),
        "expected the evidence gate to be auto-exempted for an authed P0 dispatch, log:\n{log}"
    );

    // ── RESILIENT-1030: GET /api/gaps — same bearer auth, then a fresh
    // fake `chump` that answers `gap list --status open --json` so we can
    // assert the route passes the queue JSON through unmodified. Kept in
    // this same test function (not a separate #[tokio::test]) because both
    // tests mutate the shared-process CHUMP_BATPHONE_TOKEN/CHUMP_BIN env
    // vars, and Rust runs tests in the same binary on parallel threads by
    // default — a second test fn here would race this one.
    async fn get_gaps_uri(app: axum::Router, uri: &str, auth: Option<&str>) -> (StatusCode, Value) {
        let mut builder = Request::builder().method("GET").uri(uri);
        if let Some(a) = auth {
            builder = builder.header("authorization", a);
        }
        let req = builder.body(Body::empty()).unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let val: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, val)
    }

    async fn get_gaps(app: axum::Router, auth: Option<&str>) -> (StatusCode, Value) {
        get_gaps_uri(app, "/api/gaps", auth).await
    }

    let gaps_dir = dir.join("get-gaps");
    std::fs::create_dir_all(&gaps_dir).unwrap();
    let gap_list_bin = gaps_dir.join("fake-chump-gap-list");
    std::fs::write(
        &gap_list_bin,
        r#"#!/bin/sh
echo '[{"id":"INFRA-0100","priority":"P2","status":"open"},{"id":"RESILIENT-1030","priority":"P0","status":"open"},{"id":"INFRA-2000","priority":"P1","status":"open"},{"id":"INFRA-3000","priority":"P0","status":"done"}]'
exit 0
"#,
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&gap_list_bin).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&gap_list_bin, perms).unwrap();
    }

    // No token configured -> fail closed 503.
    std::env::remove_var(BATPHONE_TOKEN_ENV);
    std::env::remove_var("CHUMP_BIN");
    let (status, _) = get_gaps(build_app(&gaps_dir), Some("Bearer anything")).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);

    // Token configured, wrong bearer -> 401.
    std::env::set_var(BATPHONE_TOKEN_ENV, "s3cret-token");
    let (status, _) = get_gaps(build_app(&gaps_dir), Some("Bearer wrong")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Correct bearer -> 200 with open gaps sorted P0-first (INFRA-8179).
    std::env::set_var("CHUMP_BIN", &gap_list_bin);
    let (status, body) = get_gaps(build_app(&gaps_dir), Some("Bearer s3cret-token")).await;
    assert_eq!(status, StatusCode::OK);
    let arr = body
        .as_array()
        .expect("GET /api/gaps must return JSON array");
    let ids: Vec<&str> = arr.iter().filter_map(|g| g["id"].as_str()).collect();
    assert_eq!(
        ids,
        vec!["RESILIENT-1030", "INFRA-2000", "INFRA-0100"],
        "GET /api/gaps must sort P0 < P1 < P2 and default to status=open"
    );

    // INFRA-8179: ?priority=P0 filter honored.
    let (status, body_p0) = get_gaps_uri(
        build_app(&gaps_dir),
        "/api/gaps?priority=P0",
        Some("Bearer s3cret-token"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let arr_p0 = body_p0.as_array().unwrap();
    assert_eq!(arr_p0.len(), 1);
    assert_eq!(arr_p0[0]["id"].as_str(), Some("RESILIENT-1030"));

    // INFRA-8179: ?status=done&priority=P0 filter honored.
    let (status, body_done) = get_gaps_uri(
        build_app(&gaps_dir),
        "/api/gaps?status=done&priority=P0",
        Some("Bearer s3cret-token"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let arr_done = body_done.as_array().unwrap();
    assert_eq!(arr_done.len(), 1);
    assert_eq!(arr_done[0]["id"].as_str(), Some("INFRA-3000"));

    std::env::remove_var(BATPHONE_TOKEN_ENV);
    std::env::remove_var("CHUMP_BIN");

    // ── EFFECTIVE-1519: `create_mission_gap` must append exactly one
    // `"stage":"draft"` entry to `logs/launch.log` on a successful mission
    // creation. Reuses the same fake-chump reserve dir as above (`dir`,
    // `fake_bin`) so the shell-out path is deterministic.
    std::env::set_var("CHUMP_BIN", &fake_bin);
    let outcome = create_mission_gap(
        &dir,
        MissionRequest {
            title: "launch-log test mission".to_string(),
            intent: None,
            description: None,
            priority: None,
            outcome: None,
            domain: None,
            effort: None,
            acceptance_criteria: None,
            platform: Some("twitter".to_string()),
            user_id: Some("jeff".to_string()),
        },
    )
    .expect("create_mission_gap should succeed with the fake chump binary");
    assert_eq!(outcome.gap_id, "INFRA-8471");

    let launch_log = std::fs::read_to_string(dir.join("logs/launch.log"))
        .expect("logs/launch.log should exist after a successful mission creation");
    let draft_entries: Vec<&str> = launch_log
        .lines()
        .filter(|l| l.contains("\"stage\":\"draft\""))
        .collect();
    assert_eq!(
        draft_entries.len(),
        1,
        "expected exactly one draft-stage log entry, got:\n{launch_log}"
    );
    assert!(draft_entries[0].contains("\"platform\":\"twitter\""));
    assert!(draft_entries[0].contains("\"user_id\":\"jeff\""));

    std::env::remove_var("CHUMP_BIN");
    let _ = std::fs::remove_dir_all(&dir);
}
