//! Integration tests for the INFRA-7714 (INFRA-2252 slice) merge-queue CAS lock.
//!
//! Mirrors `distributed_mutex.rs`: runs against a real NATS server (default
//! `nats://127.0.0.1:4222`) and SKIPs (returns early with a logged warning)
//! when NATS is unreachable, so CI without a NATS service container still
//! passes.
//!
//! ```bash
//! docker run -d --name chump-nats -p 4222:4222 nats:latest -js
//! cargo test -p chump-coord --test merge_queue_lock -- --nocapture
//! ```
//!
//! The property under test is the one INFRA-7714's acceptance criteria
//! specify: NATS KV Compare-And-Set semantics serialize the local merge
//! queue — two holders cannot acquire the lock simultaneously, and release
//! correctly clears the entry so the next holder can acquire it.

use chump_coord::CoordClient;
use std::sync::OnceLock;
use tokio::sync::Mutex;

/// Unlike `distributed_mutex.rs` (one unique gap ID per test), the
/// merge-queue lock is a single well-known key shared fleet-wide by design
/// — that's the property under test. So tests in this file can't run
/// concurrently against each other without tripping over each other's
/// locks; this mutex serializes them within the process.
fn test_serial_guard() -> &'static Mutex<()> {
    static GUARD: OnceLock<Mutex<()>> = OnceLock::new();
    GUARD.get_or_init(|| Mutex::new(()))
}

/// Connect to NATS or skip (return None) if unreachable.
async fn connect_or_skip(test_name: &str) -> Option<CoordClient> {
    match CoordClient::connect_or_skip().await {
        Some(c) => Some(c),
        None => {
            eprintln!(
                "[{}] SKIP — NATS unreachable. Run: docker run -d -p 4222:4222 nats:latest -js",
                test_name
            );
            None
        }
    }
}

#[tokio::test]
async fn first_acquire_wins_second_loses() {
    let _guard = test_serial_guard().lock().await;
    let Some(client) = connect_or_skip("first_acquire_wins_second_loses").await else {
        return;
    };

    // Best-effort cleanup in case a prior failed run left the lock held.
    client.release_merge_lock().await.ok();

    let first = client
        .try_acquire_merge_lock("holder-alpha")
        .await
        .expect("first acquire should not error");
    assert!(first, "first acquire must win");

    let second = client
        .try_acquire_merge_lock("holder-beta")
        .await
        .expect("second acquire should not error");
    assert!(!second, "second acquire must lose (CAS conflict)");

    client.release_merge_lock().await.ok();
}

#[tokio::test]
async fn release_allows_reacquire() {
    let _guard = test_serial_guard().lock().await;
    let Some(client) = connect_or_skip("release_allows_reacquire").await else {
        return;
    };
    client.release_merge_lock().await.ok();

    assert!(client.try_acquire_merge_lock("holder-1").await.unwrap());
    client.release_merge_lock().await.expect("release ok");

    assert!(
        client.try_acquire_merge_lock("holder-2").await.unwrap(),
        "post-release reacquire must succeed"
    );
    client.release_merge_lock().await.ok();
}

#[tokio::test]
async fn merge_lock_holder_returns_current_holder() {
    let _guard = test_serial_guard().lock().await;
    let Some(client) = connect_or_skip("merge_lock_holder_returns_current_holder").await else {
        return;
    };
    client.release_merge_lock().await.ok();

    assert!(client.merge_lock_holder().await.unwrap().is_none());

    assert!(client.try_acquire_merge_lock("the-holder").await.unwrap());
    let holder = client
        .merge_lock_holder()
        .await
        .expect("read ok")
        .expect("holder must exist");
    assert_eq!(holder.holder, "the-holder");

    client.release_merge_lock().await.ok();
    assert!(client.merge_lock_holder().await.unwrap().is_none());
}
