//! INFRA-3689: route gap mutations from a non-canonical/stale client (e.g.
//! the operator's Mac) to the OS's own fleet-server (`chump-fleet-server`
//! `POST /api/gap`, `crates/chump-fleet-server/src/gap_write.rs`) on owned
//! iron (CJ), instead of writing to a stale local canonical replica.
//!
//! This finishes the Mac-independence of canonical gap state: a stale
//! client no longer has to hold a writable local canonical replica to
//! perform `chump gap reserve|set|ship` — it delegates the write over HTTP
//! to a server that already has one.
//!
//! ## Staleness detection
//!
//! Uses `GapStore::behind_origin_main()` (INFRA-3687, `crates/chump-gap-store/src/lib.rs`,
//! landed PR #4347) — every call site already has an open `GapStore` in
//! scope, so callers pass its `Option<u64>` straight into
//! [`should_route_to_server`] rather than this module re-deriving the same
//! `git rev-list --count main..origin/main` probe a second time.
//!
//! ## Opt-in
//!
//! The whole routing path is gated behind the `CHUMP_GAP_SERVER` env var
//! (a base URL, e.g. `http://127.0.0.1:7070`) being set. Unset ==
//! unconditionally unchanged local-first behavior — fleet nodes stay fast
//! and offline-capable by default. Set `CHUMP_GAP_SERVER_MODE=canonical` on
//! an operator client once the owned server is the authority: every mutation
//! then routes there and a server failure fails closed instead of splitting
//! state between the client and the node.
//!
//! ## Ambient events
//!
//! Every successful route emits one event, from the three call sites in
//! `src/main.rs` (`chump gap reserve|set|ship`) — registered in
//! `docs/observability/EVENT_REGISTRY.yaml`. The emit call uses `EmitArgs`'s
//! Rust struct-literal `kind: "...".to_string()` form, which the
//! EVENT_REGISTRY coverage scanner's patterns don't match syntactically —
//! this comment is the scanner-anchor pairing the registry entry to its
//! real emit sites (same convention as `src/execute_gap.rs`,
//! `src/trek.rs`).
//! scanner-anchor: "kind":"gap_mutation_routed_to_server"

use serde::{Deserialize, Serialize};

/// Env var: base URL of the fleet-server to route stale-client gap
/// mutations to, e.g. `http://127.0.0.1:7070`. Unset => routing is fully
/// disabled and the CLI behaves exactly as before this gap.
pub const GAP_SERVER_ENV: &str = "CHUMP_GAP_SERVER";
/// Env var: choose `canonical` to route every mutation to `CHUMP_GAP_SERVER`,
/// including when the local checkout is currently up to date. Any other value
/// retains the stale-client-only behavior for backwards compatibility.
pub const GAP_SERVER_MODE_ENV: &str = "CHUMP_GAP_SERVER_MODE";
/// Env var: bearer token for the fleet-server's `/api/gap` (same token as
/// `/api/mission`'s `CHUMP_BATPHONE_TOKEN` — one bat-phone, two endpoints).
pub const BATPHONE_TOKEN_ENV: &str = "CHUMP_BATPHONE_TOKEN";

/// Whether this client treats the configured fleet-server as the sole gap
/// authority. Kept separate from the pure routing decision below so tests do
/// not need to mutate process environment.
pub fn canonical_server_mode() -> bool {
    matches!(
        std::env::var(GAP_SERVER_MODE_ENV)
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str(),
        "canonical" | "always"
    )
}

/// Pure decision function (the INFRA-3689 test seam). Route a gap mutation
/// to the fleet-server instead of writing the local state.db when BOTH:
///   - the operator opted in via `CHUMP_GAP_SERVER` (`server_set`)
///   - `canonical_mode` is set, OR the local canonical checkout is *verifiably*
///     behind `origin/main` (`behind` is `Some(n)` with `n > 0`)
///
/// `behind == None` (staleness unknown) does NOT route: an unverifiable
/// check falls through to the existing local-first path unless canonical mode
/// is explicitly selected.
pub fn should_route_to_server(behind: Option<u64>, server_set: bool, canonical_mode: bool) -> bool {
    server_set && (canonical_mode || behind.is_some_and(|n| n > 0))
}

/// Body posted to the fleet-server's `POST /api/gap` (INFRA-3689), mirroring
/// `chump_fleet_server::gap_write::GapWriteRequest` field-for-field.
#[derive(Debug, Default, Serialize)]
pub struct GapMutationBody {
    pub op: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gap_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub acceptance_criteria: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub depends_on: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub add_note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_doc: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub opened_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closed_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closed_pr: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skills_required: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preferred_backend: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preferred_machine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_minutes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evidence: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artifact_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub external_repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_obs_acs: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

/// Response from `POST /api/gap`, mirroring
/// `chump_fleet_server::gap_write::GapWriteOutcome`.
#[derive(Debug, Deserialize)]
pub struct GapMutationResult {
    pub gap_id: String,
    #[allow(dead_code)]
    pub op: String,
    #[allow(dead_code)]
    pub status: String,
    pub detail: String,
}

/// POST `body` to `{server_base}/api/gap` with bearer auth. Non-2xx or a
/// transport error both surface as `Err` — the caller (each `chump gap
/// <op>` arm) is responsible for NOT silently falling back to a local write
/// on error; see module docs.
pub async fn route_gap_mutation(
    server_base: &str,
    token: &str,
    body: &GapMutationBody,
) -> anyhow::Result<GapMutationResult> {
    let url = format!("{}/api/gap", server_base.trim_end_matches('/'));
    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .bearer_auth(token)
        .json(body)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("POST {url} failed: {e}"))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .unwrap_or_else(|_| "<unreadable body>".to_string());
    if !status.is_success() {
        anyhow::bail!("fleet-server {url} returned {status}: {text}");
    }
    serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("fleet-server {url} returned unparsable JSON ({e}): {text}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_when_stale_and_server_set() {
        assert!(should_route_to_server(Some(1), true, false));
        assert!(should_route_to_server(Some(42), true, false));
    }

    #[test]
    fn stays_local_when_canonical() {
        assert!(!should_route_to_server(Some(0), true, false));
    }

    #[test]
    fn stays_local_when_staleness_unverifiable() {
        // None must never be treated as "definitely stale" — an
        // unverifiable check falls through to the existing local path.
        assert!(!should_route_to_server(None, true, false));
    }

    #[test]
    fn stays_local_when_server_not_set() {
        assert!(!should_route_to_server(Some(5), false, false));
        assert!(!should_route_to_server(None, false, true));
        assert!(!should_route_to_server(Some(0), false, true));
    }

    #[test]
    fn canonical_mode_routes_even_when_local_state_is_current_or_unverifiable() {
        assert!(should_route_to_server(Some(0), true, true));
        assert!(should_route_to_server(None, true, true));
    }

    #[test]
    fn gap_mutation_body_serializes_only_set_fields() {
        let body = GapMutationBody {
            op: "reserve".into(),
            domain: Some("INFRA".into()),
            title: Some("t".into()),
            external_repo: Some("owner/repo".into()),
            force: Some(true),
            ..Default::default()
        };
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(json["op"], "reserve");
        assert_eq!(json["domain"], "INFRA");
        assert_eq!(json["external_repo"], "owner/repo");
        assert_eq!(json["force"], true);
        assert!(
            json.get("gap_id").is_none(),
            "unset fields must be omitted: {json:?}"
        );
        assert!(json.get("outcome").is_none());
    }
}
