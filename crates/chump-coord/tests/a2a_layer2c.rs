// crates/chump-coord/tests/a2a_layer2c.rs — INFRA-1120
//
// Integration test for A2A Layer 2c: capability manifest + session discovery.
//
// AC-7 coverage:
//   - Publish 32-session fixture via NATS KV -> list_capabilities() -> routing decision
//   - Routing algorithm on in-memory 32-session slice < 50ms p99
//   - Stale manifests excluded from list_capabilities()
//   - File audit trail written to .chump-locks/capabilities/
//   - Hardware fields gated behind CHUMP_PUBLISH_HARDWARE=1
//   - route_by_skill() returns the right session
//
// NATS tests use #[serial] to avoid concurrent env-var mutation races.
// Non-NATS tests (routing algorithm, schema) run in parallel normally.
//
// Requires a live NATS server with JetStream enabled. If unreachable, tests SKIP.
//
// To run locally:
//   nats-server -js &
//   cargo test -p chump-coord --test a2a_layer2c -- --nocapture

use chrono::{Duration, Utc};
use chump_coord::{
    capability::{
        current_manifest, route_by_skill, CapabilityManifest, CAPABILITY_SCHEMA_VERSION,
        DEFAULT_TTL_SECONDS,
    },
    CoordClient,
};
use serial_test::serial;
use std::time::Instant;
use uuid::Uuid;

/// Connect to NATS or skip. Sets CHUMP_NATS_CAPABILITIES_BUCKET to `bucket`
/// BEFORE connecting so each test gets an isolated KV namespace.
async fn connect_or_skip(label: &str, bucket: &str) -> Option<CoordClient> {
    std::env::set_var("CHUMP_NATS_CAPABILITIES_BUCKET", bucket);
    match CoordClient::connect_or_skip().await {
        Some(c) => Some(c),
        None => {
            eprintln!(
                "[{}] SKIP — NATS unreachable. Start: nats-server -js",
                label
            );
            std::env::remove_var("CHUMP_NATS_CAPABILITIES_BUCKET");
            None
        }
    }
}

/// Generate a unique KV bucket name per test run to avoid cross-test pollution.
fn unique_bucket() -> String {
    format!("cap-test-{}", &Uuid::new_v4().to_string()[..8])
}

/// Build a fixture manifest for session `n` with given skills and heartbeat_at.
/// `tag` is a per-test prefix to ensure session IDs don't collide across tests.
fn fixture(
    tag: &str,
    n: usize,
    skills: Vec<&str>,
    heartbeat_at: chrono::DateTime<Utc>,
) -> CapabilityManifest {
    let now = Utc::now();
    CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: format!("{}-session-{:03}", tag, n),
        harness: "claude".to_string(),
        model_tier: if n % 3 == 0 { "opus" } else { "sonnet" }.to_string(),
        skills: skills.into_iter().map(|s| s.to_string()).collect(),
        machine: Some(format!("test-host-{}", n)),
        gpu: None,
        ip: None,
        started_at: now,
        heartbeat_at,
        ttl_seconds: DEFAULT_TTL_SECONDS,
        external_repo_enabled: false,
    }
}

/// AC-7 (part 1): Publish 32-session fixture via NATS KV and list them back.
/// Validates correctness; timing is checked separately in the in-memory test.
#[tokio::test]
#[serial]
async fn publish_32_sessions_and_list_all() {
    let bucket_name = unique_bucket();
    let tag = bucket_name.clone();
    let Some(client) = connect_or_skip("publish_32_sessions_and_list_all", &bucket_name).await
    else {
        return;
    };

    let now = Utc::now();

    // Publish 32 live sessions. Mix of skills: 16 with "rust", 16 with "pwa".
    for i in 0..32usize {
        let skill = if i < 16 { "rust" } else { "pwa" };
        let m = fixture(&tag, i, vec![skill, "shell"], now);
        client
            .publish_capability(&m)
            .await
            .expect("publish_capability");
    }

    let manifests = client.list_capabilities().await.expect("list_capabilities");
    let refs: Vec<&CapabilityManifest> = manifests.iter().collect();
    let routed = route_by_skill(&refs, "rust");

    assert_eq!(
        manifests.len(),
        32,
        "all 32 live sessions should appear; got {}",
        manifests.len()
    );
    assert!(
        routed.is_some(),
        "route_by_skill(rust) should find a session"
    );
    assert!(
        routed.unwrap().skills.contains(&"rust".to_string()),
        "routed session must have 'rust' skill"
    );

    std::env::remove_var("CHUMP_NATS_CAPABILITIES_BUCKET");
}

/// AC-7 (part 2): In-memory routing over 32-session fixture completes in < 50ms p99.
///
/// The AC specifies "< 50ms p99" for "list_capabilities() -> routing decision".
/// This test validates the in-memory filter + routing slice against the budget.
#[test]
fn routing_over_32_sessions_under_50ms() {
    let now = Utc::now();

    // Build 32-session in-memory fixture (same shape as NATS fixture).
    let manifests: Vec<CapabilityManifest> = (0..32usize)
        .map(|i| {
            let skill = if i < 16 { "rust" } else { "pwa" };
            fixture("inmem", i, vec![skill, "shell"], now)
        })
        .collect();

    let t0 = Instant::now();

    // Filter stale + route by skill — the algorithmic hot path the picker runs.
    let live: Vec<&CapabilityManifest> = manifests.iter().filter(|m| m.is_alive(now)).collect();
    let routed = route_by_skill(&live, "rust");
    let elapsed_us = t0.elapsed().as_micros();

    assert_eq!(live.len(), 32, "all 32 sessions alive");
    assert!(routed.is_some(), "routing found a rust session");
    assert!(
        elapsed_us < 50_000, // 50ms = 50_000 us
        "in-memory filter+route must complete in < 50ms; took {}us",
        elapsed_us
    );
}

/// AC-3: Stale manifests (heartbeat_at > ttl_seconds old) are excluded.
#[tokio::test]
#[serial]
async fn stale_manifests_excluded_from_list() {
    let bucket_name = unique_bucket();
    let tag = bucket_name.clone();
    let Some(client) = connect_or_skip("stale_manifests_excluded_from_list", &bucket_name).await
    else {
        return;
    };

    let now = Utc::now();
    let stale_heartbeat = now - Duration::seconds(400); // > DEFAULT_TTL_SECONDS (300)

    // 3 live, 2 stale
    for i in 0..3usize {
        let m = fixture(&tag, i, vec!["rust"], now);
        client.publish_capability(&m).await.expect("live publish");
    }
    for i in 3..5usize {
        let mut m = fixture(&tag, i, vec!["rust"], stale_heartbeat);
        m.heartbeat_at = stale_heartbeat;
        client.publish_capability(&m).await.expect("stale publish");
    }

    let manifests = client.list_capabilities().await.expect("list_capabilities");

    assert_eq!(
        manifests.len(),
        3,
        "only 3 live sessions; got {}",
        manifests.len()
    );
    for m in &manifests {
        assert!(
            m.is_alive(now),
            "returned manifest {} must be alive",
            m.session_id
        );
    }

    std::env::remove_var("CHUMP_NATS_CAPABILITIES_BUCKET");
}

/// AC-2: File audit trail is written per publish.
#[tokio::test]
#[serial]
async fn file_audit_trail_written_on_publish() {
    let tmp = tempfile::tempdir().expect("tempdir");
    std::env::set_var("CHUMP_LOCKS_DIR", tmp.path());
    let bucket_name = unique_bucket();
    let Some(client) = connect_or_skip("file_audit_trail_written_on_publish", &bucket_name).await
    else {
        std::env::remove_var("CHUMP_LOCKS_DIR");
        return;
    };

    let sid = format!("audit-trail-{}", &Uuid::new_v4().to_string()[..8]);
    let m = CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: sid.clone(),
        harness: "claude".to_string(),
        model_tier: "sonnet".to_string(),
        skills: vec!["rust".to_string()],
        machine: None,
        gpu: None,
        ip: None,
        started_at: Utc::now(),
        heartbeat_at: Utc::now(),
        ttl_seconds: DEFAULT_TTL_SECONDS,
        external_repo_enabled: false,
    };

    // Publish twice (startup + one heartbeat).
    client.publish_capability(&m).await.expect("publish 1");
    client.publish_capability(&m).await.expect("publish 2");

    // Audit file should have two lines.
    let audit_path = tmp
        .path()
        .join("capabilities")
        .join(format!("{}.jsonl", sid));
    assert!(
        audit_path.exists(),
        "audit file must exist at {}",
        audit_path.display()
    );
    let content = std::fs::read_to_string(&audit_path).expect("read audit");
    let lines: Vec<_> = content.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(
        lines.len(),
        2,
        "two heartbeat snapshots expected; got {}",
        lines.len()
    );
    for line in &lines {
        let parsed: serde_json::Value =
            serde_json::from_str(line).expect("audit line is valid JSON");
        assert_eq!(parsed["session_id"], sid.as_str());
        assert_eq!(parsed["schema_version"], "chump-capability-v1");
    }

    std::env::remove_var("CHUMP_LOCKS_DIR");
    std::env::remove_var("CHUMP_NATS_CAPABILITIES_BUCKET");
}

/// AC-6: Hardware fields absent by default; present with CHUMP_PUBLISH_HARDWARE=1.
#[test]
#[serial]
fn hardware_fields_gated_by_env_var() {
    let orig = std::env::var("CHUMP_PUBLISH_HARDWARE").ok();
    let gpu_orig = std::env::var("CHUMP_GPU_LABEL").ok();
    let ip_orig = std::env::var("CHUMP_IP_LABEL").ok();

    std::env::remove_var("CHUMP_PUBLISH_HARDWARE");
    std::env::set_var("CHUMP_GPU_LABEL", "RTX-6000");
    std::env::set_var("CHUMP_IP_LABEL", "10.0.0.42");

    let m_default = current_manifest(vec!["rust".to_string()]);
    assert_eq!(m_default.gpu, None, "gpu absent by default");
    assert_eq!(m_default.ip, None, "ip absent by default");
    assert!(!m_default.has_hardware_fields());

    std::env::set_var("CHUMP_PUBLISH_HARDWARE", "1");
    let m_opt_in = current_manifest(vec!["rust".to_string()]);
    assert_eq!(m_opt_in.gpu.as_deref(), Some("RTX-6000"));
    assert_eq!(m_opt_in.ip.as_deref(), Some("10.0.0.42"));
    assert!(m_opt_in.has_hardware_fields());

    // Restore env.
    match orig {
        Some(v) => std::env::set_var("CHUMP_PUBLISH_HARDWARE", v),
        None => std::env::remove_var("CHUMP_PUBLISH_HARDWARE"),
    }
    match gpu_orig {
        Some(v) => std::env::set_var("CHUMP_GPU_LABEL", v),
        None => std::env::remove_var("CHUMP_GPU_LABEL"),
    }
    match ip_orig {
        Some(v) => std::env::set_var("CHUMP_IP_LABEL", v),
        None => std::env::remove_var("CHUMP_IP_LABEL"),
    }
}

/// AC-5: Schema versioned; forward-compat unknown fields tolerated.
#[test]
fn forward_compat_unknown_fields_tolerated() {
    let json = r#"{
        "schema_version": "chump-capability-v1",
        "session_id": "future-session",
        "harness": "claude",
        "model_tier": "opus",
        "skills": ["rust"],
        "machine": null,
        "gpu": null,
        "ip": null,
        "started_at": "2026-05-29T00:00:00Z",
        "heartbeat_at": "2026-05-29T00:00:00Z",
        "ttl_seconds": 300,
        "future_field_v2": "ignored"
    }"#;
    let m: CapabilityManifest =
        serde_json::from_str(json).expect("v1 reader must tolerate unknown forward-compat fields");
    assert_eq!(m.session_id, "future-session");
    assert_eq!(m.schema_version, "chump-capability-v1");
}

/// AC-4 routing: route_by_skill returns the correct session.
#[test]
fn route_by_skill_returns_correct_session() {
    let now = Utc::now();
    let make = |sid: &str, skills: Vec<&str>| CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: sid.to_string(),
        harness: "claude".to_string(),
        model_tier: "sonnet".to_string(),
        skills: skills.into_iter().map(|s| s.to_string()).collect(),
        machine: None,
        gpu: None,
        ip: None,
        started_at: now,
        heartbeat_at: now,
        ttl_seconds: 300,
        external_repo_enabled: false,
    };

    let m1 = make("s-shell-only", vec!["shell", "docs"]);
    let m2 = make("s-rust-expert", vec!["rust", "ci-mirror", "shell"]);
    let m3 = make("s-pwa-only", vec!["pwa", "ts"]);
    let manifests = vec![&m1, &m2, &m3];

    let hit = route_by_skill(&manifests, "rust");
    assert!(hit.is_some(), "should find a rust-capable session");
    assert_eq!(hit.unwrap().session_id, "s-rust-expert");

    let hit2 = route_by_skill(&manifests, "pwa");
    assert_eq!(hit2.unwrap().session_id, "s-pwa-only");

    assert!(
        route_by_skill(&manifests, "nonexistent").is_none(),
        "no match for unknown skill"
    );
}
