//! Integration test for GET /api/dashboard-summary (INFRA-1883).
//!
//! Uses `axum::Router::oneshot` (no network socket needed). Builds the router
//! with a temporary fleet_events.db, then exercises three scenarios:
//!
//! 1. Empty fixtures — endpoint still returns 200 with correct shape.
//! 2. Full fixtures — github_cache.db + ambient.jsonl + claim files all populated.
//! 3. Lease cap — 15 claim files → active_leases capped at 10.

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use rusqlite::Connection;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower::ServiceExt; // for `.oneshot()`

use chump_fleet_server::{db::FleetStore, routes};

// ── fixture helpers ───────────────────────────────────────────────────────────

fn tempdir(suffix: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "chump-test-dashboard-{}-{}",
        std::process::id(),
        suffix
    ));
    let _ = fs::remove_dir_all(&p);
    fs::create_dir_all(&p).unwrap();
    p
}

/// Write a minimal github_cache.db with `n` PRs merged 1 h ago (within 24h window).
fn write_github_cache(db_path: &Path, merged_count: usize) {
    let conn = Connection::open(db_path).unwrap();
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS pr_state (
            number              INTEGER PRIMARY KEY,
            head_ref            TEXT,
            head_sha            TEXT,
            base_ref            TEXT,
            base_sha            TEXT,
            mergeable_state     TEXT,
            auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
            draft               INTEGER NOT NULL DEFAULT 0,
            merged_at           TEXT,
            title               TEXT,
            user_login          TEXT,
            updated_at_api      TEXT NOT NULL DEFAULT '',
            fetched_at_local    TEXT NOT NULL DEFAULT '',
            raw_payload_json    TEXT,
            merge_state_status  TEXT
        );",
    )
    .unwrap();

    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    // 1 hour ago — safely inside the 24h window.
    let merged_at = epoch_to_rfc3339(now_secs - 3600);

    for i in 0..merged_count {
        conn.execute(
            "INSERT OR IGNORE INTO pr_state
               (number, title, merged_at, updated_at_api, fetched_at_local)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                (i + 1000) as i64,
                format!("PR fixture {}", i),
                merged_at,
                merged_at,
                merged_at,
            ],
        )
        .unwrap();
    }
}

/// Write a one-line ambient.jsonl with a `ci_qa_score` event timestamped now.
fn write_ambient_jsonl(path: &Path, pct: f64, sample_size: u64, status: &str) {
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let ts = epoch_to_rfc3339(now_secs);
    let ts_ms = now_secs as i64 * 1000;
    let line = serde_json::json!({
        "ts": ts,
        "ts_ms": ts_ms,
        "kind": "ci_qa_score",
        "pct": pct,
        "sample_size": sample_size,
        "status": status,
    });
    fs::write(path, format!("{}\n", line)).unwrap();
}

/// Write `n` claim JSON files under `lock_dir`, each expiring 1 h from now.
fn write_claim_files(lock_dir: &Path, n: usize) {
    fs::create_dir_all(lock_dir).unwrap();
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let expires_at = epoch_to_rfc3339(now_secs + 3600);

    for i in 0..n {
        let content = serde_json::json!({
            "gap_id": format!("INFRA-{}", 9000 + i),
            "session_id": format!("claim-test-session-{}", i),
            "expires_at": expires_at,
            "paths": [],
        });
        fs::write(
            lock_dir.join(format!("claim-test-{}.json", i)),
            content.to_string(),
        )
        .unwrap();
    }
}

/// Build the router under test with a fresh on-disk fleet DB in `tmp` dir.
fn build_test_app(repo_root: PathBuf) -> axum::Router {
    let db_path = repo_root.join("fleet_events_test.db");
    let store = Arc::new(FleetStore::open(&db_path).unwrap());
    routes::build_router(store, repo_root)
}

// ── epoch helper (mirrors dashboard.rs) ──────────────────────────────────────

fn epoch_to_rfc3339(secs: u64) -> String {
    let sec = secs % 60;
    let min = (secs / 60) % 60;
    let hour = (secs / 3600) % 24;
    let days = secs / 86400;
    let (year, month, day) = days_to_ymd(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// Endpoint returns 200 + correct shape even with no fixture data.
#[tokio::test]
async fn test_dashboard_summary_empty_fixtures() {
    let root = tempdir("empty");

    let app = build_test_app(root.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/dashboard-summary")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).expect("response must be valid JSON");

    // Required top-level keys.
    assert!(v.get("today_ships").is_some(), "missing today_ships");
    assert!(
        v.get("merges_24h").is_some(),
        "missing canonical merges_24h column (INFRA-7142)"
    );
    assert!(v.get("ci_qa_score").is_some(), "missing ci_qa_score key");
    assert!(v.get("active_leases").is_some(), "missing active_leases");
    assert!(v.get("window_hours").is_some(), "missing window_hours");

    // today_ships: no local cache — falls back to `gh pr list`, which may
    // return real values in CI. Assert it is a non-negative integer (shape),
    // not a specific count.
    assert!(
        v["today_ships"].as_u64().is_some(),
        "today_ships must be a non-negative integer, got {:?}",
        v["today_ships"]
    );

    // ci_qa_score must be null — no ambient.jsonl in tempdir.
    assert!(
        v["ci_qa_score"].is_null(),
        "ci_qa_score should be null with no ambient data"
    );
    // active_leases must be empty — no claim files in tempdir.
    assert_eq!(v["active_leases"].as_array().unwrap().len(), 0, "no leases");
    assert_eq!(v["window_hours"], 24);
}

/// With full fixture data, all three payload fields are populated correctly.
#[tokio::test]
async fn test_dashboard_summary_with_fixtures() {
    let root = tempdir("fixtures");

    // github_cache.db — 3 merged PRs.
    let chump_dir = root.join(".chump");
    fs::create_dir_all(&chump_dir).unwrap();
    write_github_cache(&chump_dir.join("github_cache.db"), 3);

    // ambient.jsonl — one ci_qa_score event.
    let lock_dir = root.join(".chump-locks");
    fs::create_dir_all(&lock_dir).unwrap();
    write_ambient_jsonl(&lock_dir.join("ambient.jsonl"), 87.5, 40, "healthy");

    // Two claim lease files.
    write_claim_files(&lock_dir, 2);

    let app = build_test_app(root.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/dashboard-summary")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).expect("response must be valid JSON");

    // today_ships from cache.
    assert_eq!(
        v["today_ships"].as_u64().unwrap(),
        3,
        "today_ships should count 3 merged PRs from fixture cache"
    );

    // merges_24h (canonical column, INFRA-7142) mirrors today_ships exactly.
    assert_eq!(
        v["merges_24h"].as_u64().unwrap(),
        3,
        "merges_24h should count 3 merged PRs from fixture cache"
    );
    assert_eq!(
        v["merges_24h"], v["today_ships"],
        "merges_24h and today_ships must always agree"
    );

    // ci_qa_score from ambient fixture.
    let score = v["ci_qa_score"]
        .as_object()
        .expect("ci_qa_score should be an object");
    assert!(
        (score["pct"].as_f64().unwrap() - 87.5).abs() < 0.01,
        "pct mismatch: {:?}",
        score["pct"]
    );
    // INFRA-3847 (parent INFRA-3841 slice 4/9): ci_clean_landing_pct is the
    // distinctly-named twin of `pct` — must agree, and must NOT be confused
    // with vital-signs.sh's separately-namespaced `ci_run_pass_rate` sign
    // (a run-level metric, not this PR-level one).
    assert_eq!(
        score["ci_clean_landing_pct"], score["pct"],
        "ci_clean_landing_pct and pct must always agree"
    );
    assert_eq!(score["sample_size"].as_u64().unwrap(), 40);
    // INFRA-3854: the fixture writes the legacy label "healthy" (still
    // emitted by some readers); the dashboard normalizes it onto the
    // canonical green|amber|red|unknown vocabulary before serializing.
    assert_eq!(score["status"].as_str().unwrap(), "green");

    // active_leases from claim files.
    let leases = v["active_leases"].as_array().unwrap();
    assert_eq!(leases.len(), 2, "should surface 2 fixture leases");
    for lease in leases {
        assert!(lease.get("gap").is_some(), "lease missing gap");
        assert!(lease.get("session").is_some(), "lease missing session");
        assert!(
            lease.get("expires_at").is_some(),
            "lease missing expires_at"
        );
    }

    assert_eq!(v["window_hours"], 24);
}

/// active_leases must be capped at 10 even when more claim files exist.
#[tokio::test]
async fn test_dashboard_summary_lease_cap() {
    let root = tempdir("cap");
    let lock_dir = root.join(".chump-locks");
    write_claim_files(&lock_dir, 15);

    let app = build_test_app(root.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/dashboard-summary")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();
    let leases = v["active_leases"].as_array().unwrap();
    assert!(
        leases.len() <= 10,
        "active_leases must be capped at 10, got {}",
        leases.len()
    );
}

/// INFRA-8179: when 14 open PRs are landing-wedged, `/api/dashboard-summary`
/// must NOT report `ci_qa_score.pct == 100%` / `status == "green"` or
/// `landing_pct == 100%`.
#[tokio::test]
async fn test_dashboard_summary_with_landing_wedged_prs() {
    let root = tempdir("wedged14");
    let chump_dir = root.join(".chump");
    fs::create_dir_all(&chump_dir).unwrap();
    let db_path = chump_dir.join("github_cache.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(
        "CREATE TABLE pr_state (
            number INTEGER PRIMARY KEY,
            merged_at TEXT,
            mergeable_state TEXT,
            updated_at_api TEXT NOT NULL DEFAULT '',
            fetched_at_local TEXT NOT NULL DEFAULT ''
        );",
    )
    .unwrap();
    for i in 1..=14 {
        conn.execute(
            "INSERT INTO pr_state (number, merged_at, mergeable_state) VALUES (?1, NULL, 'DIRTY')",
            rusqlite::params![100 + i],
        )
        .unwrap();
    }
    drop(conn);

    // Even if ambient.jsonl has a stale 100% green ci_qa_score event, 14
    // landing-wedged PRs must degrade both ci_qa_score and landing_* below 100%.
    let lock_dir = root.join(".chump-locks");
    fs::create_dir_all(&lock_dir).unwrap();
    write_ambient_jsonl(&lock_dir.join("ambient.jsonl"), 100.0, 10, "green");

    let app = build_test_app(root.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/dashboard-summary")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(v["stuck_prs"].as_u64(), Some(14));
    assert_eq!(v["landing_wedged_prs"].as_u64(), Some(14));
    assert!(
        v["landing_pct"].as_f64().unwrap() < 100.0,
        "landing_pct must not be 100% while 14 PRs are wedged: {v}"
    );
    assert_ne!(
        v["landing_status"].as_str(),
        Some("green"),
        "landing_status must not be green while 14 PRs are wedged: {v}"
    );

    let score = v["ci_qa_score"].as_object().expect("ci_qa_score object");
    assert!(
        score["pct"].as_f64().unwrap() < 100.0,
        "ci_qa_score.pct must not be 100% while 14 PRs are wedged: {score:?}"
    );
    assert_ne!(
        score["status"].as_str(),
        Some("green"),
        "ci_qa_score.status must not be green while 14 PRs are wedged: {score:?}"
    );
}

/// INFRA-8179: `GET /api/debt` (and `/api/debt-index`) exposes the
/// debt/dormancy crown-metric index (`live_pct`, `debt`, `top5_dormant`,
/// `nba_candidate_count`).
#[tokio::test]
async fn test_debt_route_returns_crown_metrics() {
    let root = tempdir("debt");
    let chump_dir = root.join(".chump");
    fs::create_dir_all(&chump_dir).unwrap();
    let state_db = chump_dir.join("state.db");
    let conn = Connection::open(&state_db).unwrap();
    conn.execute_batch(
        "CREATE TABLE gaps (
            id TEXT PRIMARY KEY,
            title TEXT,
            priority TEXT,
            status TEXT,
            effort TEXT
        );
        INSERT INTO gaps (id, title, priority, status, effort) VALUES
            ('INFRA-10', 'Live capability', 'P0', 'done', 'm'),
            ('INFRA-20', 'Dormant P0 capability', 'P0', 'open', 'l'),
            ('INFRA-30', 'Dormant P1 capability', 'P1', 'open', 'm');",
    )
    .unwrap();
    drop(conn);

    for route in ["/api/debt", "/api/debt-index"] {
        let app = build_test_app(root.clone());
        let resp = app
            .oneshot(Request::builder().uri(route).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "route {route} must 200");
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let v: Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("live_pct").and_then(|x| x.as_f64()).is_some());
        assert!(v.get("debt").and_then(|x| x.as_f64()).unwrap() > 0.0);
        assert_eq!(v["nba_candidate_count"].as_u64(), Some(2));
        let top5 = v["top5_dormant"].as_array().expect("top5_dormant array");
        assert_eq!(top5.len(), 2);
        assert_eq!(top5[0]["id"].as_str(), Some("INFRA-20"));
    }
}
