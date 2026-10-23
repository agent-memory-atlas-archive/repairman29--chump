//! Pending tool-approval requests. Agent registers a request and blocks; Discord/web calls resolve_approval when the user allows/denies.
//!
//! RESILIENT-277: a retry loop that mints a fresh request_id per attempt
//! produces N cards for one logical question, and taps on the abandoned
//! cards resolve an id with no receiver (a silent no-op). Dedupe joins
//! same (tool, normalized-args) attempts onto the SAME live request via a
//! `watch` channel (which — unlike `oneshot` — supports re-subscribing
//! after the previous waiter's timeout dropped its receiver), so only the
//! first attempt ever gets a card and every later tap still resolves it.

use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::watch;

struct PendingRequest {
    tool_name: String,
    args_key: String,
    tx: watch::Sender<Option<bool>>,
}

static PENDING: std::sync::OnceLock<Mutex<HashMap<String, PendingRequest>>> =
    std::sync::OnceLock::new();

fn pending() -> &'static Mutex<HashMap<String, PendingRequest>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Whether `resolve_approval` actually found a live receiver (HIT) or the
/// id was unknown/already-resolved (ORPHAN — a tap on a stale/superseded
/// card). Logged by callers so a silently-dropped tap is distinguishable
/// from a tap that never arrived.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveOutcome {
    Hit,
    Orphan,
}

impl ResolveOutcome {
    pub fn as_str(&self) -> &'static str {
        match self {
            ResolveOutcome::Hit => "hit",
            ResolveOutcome::Orphan => "orphan",
        }
    }
}

fn normalize_args_key(args: &serde_json::Value) -> String {
    // serde_json::Value's Ord-independent Display isn't key-order-stable for
    // maps built by different code paths, so route through a canonicalized
    // BTreeMap to make the dedupe key stable regardless of insertion order.
    fn canonicalize(v: &serde_json::Value) -> serde_json::Value {
        match v {
            serde_json::Value::Object(map) => {
                let sorted: std::collections::BTreeMap<String, serde_json::Value> = map
                    .iter()
                    .map(|(k, v)| (k.clone(), canonicalize(v)))
                    .collect();
                serde_json::to_value(sorted).unwrap_or(serde_json::Value::Null)
            }
            serde_json::Value::Array(arr) => {
                serde_json::Value::Array(arr.iter().map(canonicalize).collect())
            }
            other => other.clone(),
        }
    }
    canonicalize(args).to_string()
}

/// Create (or join) a pending approval request for `tool_name` with `args`.
///
/// If an approval for the same (tool_name, normalized args) is already
/// in flight (RESILIENT-277 FIX 1: a prior attempt that timed out but was
/// never resolved), returns the EXISTING request_id and a fresh receiver
/// subscribed to the same channel instead of minting a new id — so a
/// retry joins the original question rather than spawning a duplicate
/// card. The bool return is `true` when this call joined an existing
/// request rather than creating a new one; callers should skip posting a
/// new approval card in that case.
pub fn request_approval_for(
    tool_name: &str,
    args: &serde_json::Value,
) -> (String, watch::Receiver<Option<bool>>, bool) {
    let args_key = normalize_args_key(args);
    let mut guard = match pending().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some((existing_id, entry)) = guard
        .iter()
        .find(|(_, e)| e.tool_name == tool_name && e.args_key == args_key)
    {
        let rx = entry.tx.subscribe();
        return (existing_id.clone(), rx, true);
    }
    let request_id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = watch::channel(None);
    guard.insert(
        request_id.clone(),
        PendingRequest {
            tool_name: tool_name.to_string(),
            args_key,
            tx,
        },
    );
    (request_id, rx, false)
}

/// Test/legacy helper: create a pending request with no dedupe key.
#[cfg(test)]
fn request_approval() -> (String, watch::Receiver<Option<bool>>) {
    let (id, rx, _joined) = request_approval_for("test_tool", &serde_json::json!({}));
    (id, rx)
}

/// Resolve a pending approval. Called by Discord button handler or POST
/// /api/approve. Returns `Hit` when a live receiver was found and
/// notified, `Orphan` when the id was unknown/already resolved — RESILIENT-277
/// FIX 4: callers log this so a tap on a stale card is distinguishable from
/// no tap at all.
pub fn resolve_approval(request_id: &str, allowed: bool) -> ResolveOutcome {
    let outcome = {
        let mut guard = match pending().lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(entry) = guard.remove(request_id) {
            let _ = entry.tx.send(Some(allowed));
            ResolveOutcome::Hit
        } else {
            ResolveOutcome::Orphan
        }
    };
    crate::pending_peer_approval::clear_pending_peer_approval(request_id);
    outcome
}

/// Abandon a pending approval without a decision (RESILIENT-277 FIX 3): the
/// turn ended (timed out / errored / completed) while this request was
/// still unresolved. Drops the channel (any live receiver observes the
/// sender close, i.e. resolves to a denial via `wait_for` erroring) and
/// removes bookkeeping so the id can no longer be joined or double-edited.
pub fn abandon(request_id: &str) {
    let mut guard = match pending().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    guard.remove(request_id);
}

/// True when `request_id` is still awaiting a decision (not yet resolved/expired).
/// Used by the INFRA-1340 Web Push escalation worker to skip pushing when the
/// operator already responded, and by RESILIENT-277 to decide which cards
/// need to be superseded when a turn ends.
pub fn is_pending(request_id: &str) -> bool {
    if let Ok(guard) = pending().lock() {
        return guard.contains_key(request_id);
    }
    false
}

/// Default timeout for waiting for approval (seconds). Env CHUMP_APPROVAL_TIMEOUT_SECS.
pub fn approval_timeout_secs() -> u64 {
    std::env::var("CHUMP_APPROVAL_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60)
        .clamp(5, 600)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[tokio::test]
    #[serial]
    async fn resolve_sends_allow_to_receiver() {
        let (id, mut rx) = request_approval();
        assert_eq!(resolve_approval(&id, true), ResolveOutcome::Hit);
        rx.changed().await.unwrap();
        assert_eq!(*rx.borrow(), Some(true));
    }

    #[tokio::test]
    #[serial]
    async fn resolve_sends_deny_to_receiver() {
        let (id, mut rx) = request_approval();
        assert_eq!(resolve_approval(&id, false), ResolveOutcome::Hit);
        rx.changed().await.unwrap();
        assert_eq!(*rx.borrow(), Some(false));
    }

    #[tokio::test]
    #[serial]
    async fn resolve_unknown_id_is_orphan_no_panic() {
        assert_eq!(
            resolve_approval("00000000-0000-0000-0000-000000000099", true),
            ResolveOutcome::Orphan
        );
    }

    #[tokio::test]
    #[serial]
    async fn same_tool_and_args_joins_existing_request() {
        let args = serde_json::json!({"cmd": "ls-same-tool"});
        let (id1, _rx1, joined1) = request_approval_for("run_cli", &args);
        assert!(!joined1);
        let (id2, _rx2, joined2) = request_approval_for("run_cli", &args);
        assert!(joined2, "second attempt with identical args must join");
        assert_eq!(
            id1, id2,
            "joined attempt must reuse the original request_id"
        );
        abandon(&id1);
    }

    #[tokio::test]
    #[serial]
    async fn different_args_do_not_join() {
        let (id1, _rx1, _) =
            request_approval_for("run_cli", &serde_json::json!({"cmd": "ls-diff"}));
        let (id2, _rx2, joined2) =
            request_approval_for("run_cli", &serde_json::json!({"cmd": "pwd-diff"}));
        assert!(!joined2);
        assert_ne!(id1, id2);
        abandon(&id1);
        abandon(&id2);
    }

    #[tokio::test]
    #[serial]
    async fn joined_receiver_observes_resolution_from_original_request() {
        let args = serde_json::json!({"cmd": "ls-joined-rx"});
        let (id1, _rx1, _) = request_approval_for("run_cli", &args);
        let (_id2, mut rx2, joined2) = request_approval_for("run_cli", &args);
        assert!(joined2);
        resolve_approval(&id1, true);
        rx2.changed().await.unwrap();
        assert_eq!(*rx2.borrow(), Some(true));
    }

    #[tokio::test]
    #[serial]
    async fn key_normalization_ignores_field_order() {
        let (id1, _rx1, _) = request_approval_for("run_cli", &serde_json::json!({"a": 1, "b": 2}));
        let (id2, _rx2, joined2) =
            request_approval_for("run_cli", &serde_json::json!({"b": 2, "a": 1}));
        assert!(joined2);
        assert_eq!(id1, id2);
        abandon(&id1);
    }

    #[tokio::test]
    #[serial]
    async fn abandon_removes_pending_state() {
        let (id, _rx, _) = request_approval_for("run_cli", &serde_json::json!({}));
        assert!(is_pending(&id));
        abandon(&id);
        assert!(!is_pending(&id));
        assert_eq!(resolve_approval(&id, true), ResolveOutcome::Orphan);
    }
}
