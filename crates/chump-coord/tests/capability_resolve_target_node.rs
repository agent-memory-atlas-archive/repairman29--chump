// crates/chump-coord/tests/capability_resolve_target_node.rs — INFRA-3729
//
// Integration test for `chump_coord::capability::resolve_target_node`
// (INFRA-3652 slice): publishes a CapabilityManifest to the real NATS KV
// bucket, then asserts resolution reads back the `machine` hostname, and
// that not-found / stale / no-machine manifests fail closed (per
// INFRA-3652 AC-2 — a missing hostname must never be treated as "assume
// localhost").
//
// Skips (not fails) when NATS is unreachable, matching the
// `CoordClient::connect_or_skip` convention used elsewhere in this crate.

use chrono::Utc;
use chump_coord::capability::{
    publish_manifest, resolve_target_node, CapabilityManifest, CAPABILITY_SCHEMA_VERSION,
};
use chump_coord::CoordClient;

fn make_manifest(session_id: &str, machine: Option<&str>, ttl_seconds: u32) -> CapabilityManifest {
    let now = Utc::now();
    CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: session_id.to_string(),
        harness: "claude".to_string(),
        model_tier: "sonnet".to_string(),
        skills: vec!["rust".to_string()],
        machine: machine.map(|m| m.to_string()),
        gpu: None,
        ip: None,
        started_at: now,
        heartbeat_at: now,
        ttl_seconds,
        external_repo_enabled: false,
    }
}

#[tokio::test]
async fn resolves_machine_hostname_from_published_manifest() {
    let Some(client) = CoordClient::connect_or_skip().await else {
        eprintln!("NATS unavailable — skipping resolve_target_node integration test");
        return;
    };

    let session_id = format!("infra-3729-test-{}", std::process::id());
    let manifest = make_manifest(&session_id, Some("test-host-42"), 300);
    publish_manifest(&client.capabilities_kv, &manifest)
        .await
        .expect("publish manifest");

    let resolved = resolve_target_node(&client.capabilities_kv, &session_id)
        .await
        .expect("resolve_target_node should find the just-published manifest");
    assert_eq!(resolved, "test-host-42");
}

#[tokio::test]
async fn errors_on_unknown_unit() {
    let Some(client) = CoordClient::connect_or_skip().await else {
        eprintln!("NATS unavailable — skipping resolve_target_node integration test");
        return;
    };

    let unit = format!("infra-3729-nonexistent-{}", std::process::id());
    let result = resolve_target_node(&client.capabilities_kv, &unit).await;
    assert!(result.is_err(), "unknown unit must fail closed");
}

#[tokio::test]
async fn errors_on_stale_manifest() {
    let Some(client) = CoordClient::connect_or_skip().await else {
        eprintln!("NATS unavailable — skipping resolve_target_node integration test");
        return;
    };

    let session_id = format!("infra-3729-stale-{}", std::process::id());
    // ttl_seconds = 0 with heartbeat_at = now is already stale by the time
    // is_alive() checks it (age in whole seconds >= 1 on the next tick).
    let mut manifest = make_manifest(&session_id, Some("stale-host"), 0);
    manifest.heartbeat_at = Utc::now() - chrono::Duration::seconds(5);
    publish_manifest(&client.capabilities_kv, &manifest)
        .await
        .expect("publish manifest");

    let result = resolve_target_node(&client.capabilities_kv, &session_id).await;
    assert!(result.is_err(), "stale manifest must fail closed");
}

#[tokio::test]
async fn errors_on_manifest_with_no_machine() {
    let Some(client) = CoordClient::connect_or_skip().await else {
        eprintln!("NATS unavailable — skipping resolve_target_node integration test");
        return;
    };

    let session_id = format!("infra-3729-no-machine-{}", std::process::id());
    let manifest = make_manifest(&session_id, None, 300);
    publish_manifest(&client.capabilities_kv, &manifest)
        .await
        .expect("publish manifest");

    let result = resolve_target_node(&client.capabilities_kv, &session_id).await;
    assert!(result.is_err(), "manifest with no machine must fail closed");
}
