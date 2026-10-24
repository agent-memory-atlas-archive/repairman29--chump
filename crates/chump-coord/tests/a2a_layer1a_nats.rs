// crates/chump-coord/tests/a2a_layer1a_nats.rs — INFRA-2266
//
// A2A Layer 1a slice 3/4 integration tests — NATS-primary JetStream durable consumer.
//
// This file tests the public surface exposed via `chump_coord::nats_primary`:
//   - durable_consumer_name() sanitisation
//   - max_ack_pending() and layer_enabled() helpers
//   - subscribe→publish→receive round-trip with p99 < 50ms (N=20, AC#3)
//   - file-fallback within 5s on NATS unavailable (AC#2)
//   - backpressure emission on slow consumer (AC#5)
//   - CHUMP_A2A_LAYER=0 path unaffected (AC#6)
//
// All NATS tests guard with `nats_available()` and skip cleanly when no
// server is reachable — never fails the build due to missing NATS.

use chump_coord::nats_primary::{
    durable_consumer_name, layer_enabled, max_ack_pending, subscribe_events_with_session,
    EventFilter,
};
use chump_coord::{CoordClient, CoordEvent as LibCoordEvent};
use serde_json::json;
use serial_test::serial;
use std::time::{Duration, Instant};

// ── Helper ────────────────────────────────────────────────────────────────────

/// Returns Some(url) if NATS is reachable within 500ms, else None (test skips).
async fn nats_available() -> Option<String> {
    let url =
        std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| "nats://127.0.0.1:4222".to_string());
    match tokio::time::timeout(Duration::from_millis(500), async_nats::connect(&url)).await {
        Ok(Ok(_)) => Some(url),
        _ => None,
    }
}

// ── Unit tests (no NATS required) ────────────────────────────────────────────

#[test]
fn durable_name_sanitises_slashes_colons_spaces() {
    assert_eq!(
        durable_consumer_name("session/with:dots.and spaces"),
        "chump_session_with_dots_and_spaces"
    );
}

#[test]
fn durable_name_preserves_dash_underscore() {
    assert_eq!(
        durable_consumer_name("claim-infra-2266-49096"),
        "chump_claim-infra-2266-49096"
    );
}

#[test]
fn durable_name_alphanumeric_preserved() {
    assert_eq!(durable_consumer_name("abc123"), "chump_abc123");
}

#[test]
#[serial]
fn max_ack_pending_default_is_512() {
    std::env::remove_var("CHUMP_A2A_MAX_ACK_PENDING");
    assert_eq!(max_ack_pending(), 512);
}

#[test]
#[serial]
fn max_ack_pending_reads_env() {
    std::env::set_var("CHUMP_A2A_MAX_ACK_PENDING", "32");
    assert_eq!(max_ack_pending(), 32);
    std::env::remove_var("CHUMP_A2A_MAX_ACK_PENDING");
}

#[test]
#[serial]
fn layer_enabled_default_false() {
    std::env::remove_var("CHUMP_A2A_LAYER");
    assert!(!layer_enabled(), "CHUMP_A2A_LAYER unset must be disabled");
}

#[test]
#[serial]
fn layer_enabled_with_layer_1() {
    std::env::set_var("CHUMP_A2A_LAYER", "1");
    assert!(layer_enabled());
    std::env::remove_var("CHUMP_A2A_LAYER");
}

/// AC#6: CHUMP_A2A_LAYER=0 must return a stream without any NATS dependency.
#[tokio::test]
#[serial]
async fn layer0_subscribe_requires_no_nats() {
    std::env::remove_var("CHUMP_A2A_LAYER");
    let result = subscribe_events_with_session(
        EventFilter::All,
        Some("test-nats-primary-layer0".to_string()),
    )
    .await;
    assert!(
        result.is_ok(),
        "layer 0 subscribe must succeed with no NATS: {:?}",
        result.err().map(|e| e.to_string())
    );
}

/// AC#2 (partial): CHUMP_A2A_LAYER=1 with no NATS must still return Ok
/// (file fallback kicks in asynchronously, not as an Err).
#[tokio::test]
#[serial]
async fn layer1_returns_ok_when_nats_unreachable() {
    std::env::set_var("CHUMP_A2A_LAYER", "1");
    std::env::set_var("CHUMP_NATS_TIMEOUT_MS", "150");
    std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:19999"); // nothing there
    let result = subscribe_events_with_session(
        EventFilter::All,
        Some("test-nats-primary-no-nats".to_string()),
    )
    .await;
    assert!(
        result.is_ok(),
        "layer 1 subscribe must return Ok even with NATS unreachable (fallback path)"
    );
    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::remove_var("CHUMP_NATS_TIMEOUT_MS");
    std::env::remove_var("CHUMP_NATS_URL");
}

// ── NATS integration tests (skip if no server) ───────────────────────────────

/// AC#3: subscribe → publish → receive round-trip with p99 < 50ms (N=20 events).
///
/// Subscribes on a per-test durable consumer, publishes 20 events through
/// JetStream, measures end-to-end latency. All 20 must arrive; p99 < 50ms.
#[tokio::test]
#[serial]
async fn nats_roundtrip_p99_under_50ms() {
    let Some(nats_url) = nats_available().await else {
        eprintln!("skip — no NATS available for nats_roundtrip_p99_under_50ms");
        return;
    };

    std::env::set_var("CHUMP_A2A_LAYER", "1");
    std::env::set_var("CHUMP_NATS_URL", &nats_url);

    let session_id = format!("test-nats-rt-{}", uuid::Uuid::new_v4().simple());
    let bucket = format!("chump_gaps_npt_{}", uuid::Uuid::new_v4().simple());
    std::env::set_var("CHUMP_NATS_GAP_BUCKET", &bucket);

    // Subscribe first — consumer must exist before we publish
    let mut stream = subscribe_events_with_session(
        EventFilter::Kind("test_nats_roundtrip".to_string()),
        Some(session_id.clone()),
    )
    .await
    .expect("subscribe must succeed with NATS available");

    // Allow subscriber task to establish the JetStream consumer
    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = CoordClient::connect().await.expect("CoordClient::connect");

    const N: usize = 20;
    let mut send_times = Vec::with_capacity(N);

    for i in 0..N {
        send_times.push(Instant::now());
        client
            .emit(LibCoordEvent {
                event: "test_nats_roundtrip".to_string(),
                session: session_id.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                kind: Some("test_nats_roundtrip".to_string()),
                ..Default::default()
            })
            .await
            .unwrap_or_else(|e| panic!("emit {i} failed: {e}"));
    }

    let mut latencies_ms = Vec::with_capacity(N);
    for (i, send_time) in send_times.iter().enumerate() {
        let event = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .unwrap_or_else(|_| panic!("timeout waiting for event {i}"))
            .unwrap_or_else(|| panic!("stream ended before event {i}"));
        let elapsed = send_time.elapsed().as_millis() as u64;
        latencies_ms.push(elapsed);
        assert_eq!(event.kind, "test_nats_roundtrip", "wrong kind at event {i}");
    }

    latencies_ms.sort_unstable();
    let p99_idx = ((N as f64 * 0.99) as usize).min(N - 1);
    let p99_ms = latencies_ms[p99_idx];

    eprintln!(
        "nats_roundtrip latencies (ms): min={} median={} p99={} max={}",
        latencies_ms[0],
        latencies_ms[N / 2],
        p99_ms,
        latencies_ms[N - 1]
    );

    assert!(
        p99_ms < 50,
        "p99 latency {p99_ms}ms exceeds 50ms budget (AC#3)"
    );

    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::remove_var("CHUMP_NATS_URL");
    std::env::remove_var("CHUMP_NATS_GAP_BUCKET");
}

/// AC#5: backpressure event (fleet_a2a_backpressure) emitted when slow consumer.
///
/// Sets max_ack_pending=8, publishes 10 events without draining, asserts
/// fleet_a2a_backpressure appears in the ambient log.
#[tokio::test]
#[serial]
async fn nats_backpressure_emitted_on_slow_consumer() {
    let Some(nats_url) = nats_available().await else {
        eprintln!("skip — no NATS available for nats_backpressure_emitted_on_slow_consumer");
        return;
    };

    std::env::set_var("CHUMP_A2A_LAYER", "1");
    std::env::set_var("CHUMP_NATS_URL", &nats_url);
    std::env::set_var("CHUMP_A2A_MAX_ACK_PENDING", "8");

    let tmp_log = format!("/tmp/a2a-npt-bp-{}.jsonl", uuid::Uuid::new_v4().simple());
    std::env::set_var("CHUMP_AMBIENT_LOG", &tmp_log);

    let session_id = format!("test-npt-bp-{}", uuid::Uuid::new_v4().simple());
    let bucket = format!("chump_gaps_npt_bp_{}", uuid::Uuid::new_v4().simple());
    std::env::set_var("CHUMP_NATS_GAP_BUCKET", &bucket);

    // Subscribe but intentionally do NOT drain — creates slow consumer
    let _stream = subscribe_events_with_session(
        EventFilter::Kind("test_npt_backpressure".to_string()),
        Some(session_id.clone()),
    )
    .await
    .expect("subscribe");

    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = CoordClient::connect().await.expect("CoordClient connect");

    // Publish 10 events — exceeds max_ack_pending=8
    for i in 0..10u32 {
        client
            .emit(LibCoordEvent {
                event: "test_npt_backpressure".to_string(),
                session: session_id.clone(),
                ts: chrono::Utc::now().to_rfc3339(),
                kind: Some("test_npt_backpressure".to_string()),
                ..Default::default()
            })
            .await
            .unwrap_or_else(|e| panic!("emit {i}: {e}"));
    }

    // Give subscriber task time to detect and emit backpressure
    tokio::time::sleep(Duration::from_millis(600)).await;

    let log_contents = std::fs::read_to_string(&tmp_log).unwrap_or_default();
    assert!(
        log_contents.contains("fleet_a2a_backpressure"),
        "expected fleet_a2a_backpressure in ambient log;\nlog:\n{log_contents}"
    );

    let _ = std::fs::remove_file(&tmp_log);
    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::remove_var("CHUMP_NATS_URL");
    std::env::remove_var("CHUMP_A2A_MAX_ACK_PENDING");
    std::env::remove_var("CHUMP_AMBIENT_LOG");
    std::env::remove_var("CHUMP_NATS_GAP_BUCKET");
}

/// AC#2 (file-fallback): write an event to ambient.jsonl, subscribe with filter,
/// assert receipt. Tests the file-fallback path when NATS is unavailable.
#[tokio::test]
#[serial]
async fn file_fallback_delivers_event_within_500ms() {
    use std::io::Write;

    let tmp = tempfile::NamedTempFile::new().expect("tempfile");
    let tmp_path = tmp.path().to_str().unwrap().to_string();

    std::env::remove_var("CHUMP_A2A_LAYER"); // layer 0 = file only
    std::env::set_var("CHUMP_AMBIENT_LOG", &tmp_path);

    let mut stream = subscribe_events_with_session(
        EventFilter::Kind("test_npt_file_fallback".to_string()),
        Some("test-npt-ff".to_string()),
    )
    .await
    .expect("subscribe must succeed in layer-0 mode");

    // Small delay so tail-poll task positions at EOF before write
    tokio::time::sleep(Duration::from_millis(50)).await;

    let ts = chrono::Utc::now().to_rfc3339();
    let event_line = format!(
        r#"{{"ts":"{ts}","kind":"test_npt_file_fallback","session_id":"test-npt-ff","payload":{{}}}}"#
    );
    {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&tmp_path)
            .expect("open tmp log for write");
        writeln!(f, "{event_line}").expect("write event line");
    }

    let start = Instant::now();
    let received = tokio::time::timeout(Duration::from_millis(500), stream.next())
        .await
        .expect("event not received within 500ms — file-fallback latency budget exceeded")
        .expect("stream ended unexpectedly");

    let elapsed = start.elapsed();
    assert_eq!(
        received.kind, "test_npt_file_fallback",
        "wrong kind received: {}",
        received.kind
    );
    eprintln!(
        "file-fallback receipt latency (nats_primary path): {}ms",
        elapsed.as_millis()
    );

    std::env::remove_var("CHUMP_AMBIENT_LOG");
}

/// Smoke test: EventFilter JSON round-trip via nats_primary re-export.
#[test]
fn event_filter_json_round_trip() {
    let filters = vec![
        EventFilter::All,
        EventFilter::Kind("gap_claimed".to_string()),
        EventFilter::Session("opus-1".to_string()),
        EventFilter::Kinds(vec!["a".to_string(), "b".to_string()]),
    ];
    for f in filters {
        let j = serde_json::to_string(&f).expect("serialize");
        let back: EventFilter = serde_json::from_str(&j).expect("deserialize");
        assert_eq!(
            format!("{f:?}"),
            format!("{back:?}"),
            "EventFilter round-trip mismatch"
        );
    }
}

/// Smoke: CoordEvent round-trip (via nats_primary re-export path).
#[test]
fn coord_event_round_trip_via_nats_primary() {
    use chump_coord::nats_primary::CoordEvent;
    let e = CoordEvent {
        ts: "2026-05-30T00:00:00Z".to_string(),
        kind: "fleet_a2a_degraded".to_string(),
        session_id: Some("infra-2266-session".to_string()),
        payload: json!({"reason": "connect timed out"}),
    };
    let j = serde_json::to_string(&e).expect("serialize");
    let back: CoordEvent = serde_json::from_str(&j).expect("deserialize");
    assert_eq!(e, back, "CoordEvent round-trip lossless");
}

/// CREDIBLE-1532: writing to ambient.jsonl immediately after
/// subscribe_events_with_session().await returns (with zero sleep before write,
/// before the spawned tail task has even been polled) must still deliver the
/// event because the initial EOF offset is captured synchronously at subscribe time.
#[tokio::test]
#[serial]
async fn credible1532_file_fallback_delivers_immediate_write_without_pre_sleep() {
    use std::io::Write;

    let tmp = tempfile::NamedTempFile::new().expect("tempfile");
    let tmp_path = tmp.path().to_str().unwrap().to_string();

    // Seed pre-subscribe history that must NOT be replayed
    {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&tmp_path)
            .expect("open tmp log for history write");
        writeln!(
            f,
            r#"{{"ts":"2026-10-24T00:00:00Z","kind":"gap_claimed","session_id":"old-history","payload":{{}}}}"#
        )
        .expect("write history line");
    }

    std::env::remove_var("CHUMP_A2A_LAYER");
    std::env::set_var("CHUMP_AMBIENT_LOG", &tmp_path);

    let mut stream = subscribe_events_with_session(
        EventFilter::Kind("gap_claimed".to_string()),
        Some("test-credible1532".to_string()),
    )
    .await
    .expect("subscribe must succeed in layer-0 mode");

    // Write immediately with NO sleep before write — on a current_thread tokio
    // runtime the spawned tail task has not yet been polled here!
    {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&tmp_path)
            .expect("open tmp log for post-subscribe write");
        writeln!(
            f,
            r#"{{"ts":"2026-10-24T00:00:01Z","kind":"gap_claimed","session_id":"new-post-subscribe","payload":{{}}}}"#
        )
        .expect("write post-subscribe line");
    }

    let received = tokio::time::timeout(Duration::from_millis(2000), stream.next())
        .await
        .expect("immediate post-subscribe event must be delivered")
        .expect("stream ended unexpectedly");

    assert_eq!(received.session_id.as_deref(), Some("new-post-subscribe"));
    std::env::remove_var("CHUMP_AMBIENT_LOG");
}
