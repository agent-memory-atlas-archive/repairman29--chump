// crates/chump-coord/src/capability.rs — INFRA-1120
//
// CapabilityManifest v1 schema + full Layer 2c publish/discovery layer:
//
//   - CapabilityManifest struct + `current_manifest()` builder
//   - `publish_manifest()` — NATS KV put to `chump_capabilities` with TTL 5min
//   - `heartbeat_loop()` — calls publish every 30s until abort signal
//   - `list_capabilities()` — reads all live (non-stale) manifests from KV
//   - File audit: every publish also appends to `.chump-locks/capabilities/<sid>.jsonl`
//
// Privacy stance:
//   - `harness`, `model_tier`, `skills`, `machine` — always populated
//   - `gpu`, `ip` — populated ONLY when CHUMP_PUBLISH_HARDWARE=1 is set
//     (operators opt-in to publishing hardware details; default off)
//     Documented in .env.example (INFRA-1120).
//
// JSON wire shape (chump-capability-v1):
//   {
//     "schema_version": "chump-capability-v1",
//     "session_id":     "curator-opus-ci-audit-2026-05-23",
//     "harness":        "claude",
//     "model_tier":     "opus",
//     "skills":         ["rust", "shell", "ci-mirror"],
//     "machine":        "macbook",
//     "gpu":            null,    // unless CHUMP_PUBLISH_HARDWARE=1
//     "ip":             null,    // unless CHUMP_PUBLISH_HARDWARE=1
//     "started_at":     "2026-05-23T05:00:00Z",
//     "heartbeat_at":   "2026-05-23T05:30:00Z",
//     "ttl_seconds":    300
//   }

use anyhow::{Context, Result};
use async_nats::jetstream::kv;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write as IoWrite;
use std::path::PathBuf;
use std::time::Duration;

/// Wire-version constant. Bump to `chump-capability-v2` when adding a new
/// REQUIRED field; readers should tolerate forward-compat optional fields
/// without a bump.
pub const CAPABILITY_SCHEMA_VERSION: &str = "chump-capability-v1";

/// Default heartbeat TTL when not overridden by the caller. Matches the
/// 5-min stale-session window the picker uses to exclude dead manifests.
pub const DEFAULT_TTL_SECONDS: u32 = 300;

/// KV bucket name for capability manifests.
/// Per-test override via `CHUMP_NATS_CAPABILITIES_BUCKET`.
pub const CAPABILITIES_BUCKET: &str = "chump_capabilities";

/// Heartbeat interval — 30 seconds.
pub const HEARTBEAT_INTERVAL_SECS: u64 = 30;

// scanner-anchor: capability_published capability_heartbeat

/// Manifest published by every worker session to the `chump_capabilities`
/// NATS KV bucket. Stale entries (heartbeat_at > ttl_seconds old) are
/// excluded from routing decisions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityManifest {
    /// Schema identifier; today `chump-capability-v1`.
    pub schema_version: String,
    /// Stable session identifier (e.g. `curator-opus-ci-audit-2026-05-23`
    /// or `claim-infra-1760-<pid>-<ts>`).
    pub session_id: String,
    /// `claude` | `opencode` | `codex` | `manual` | `fleet-dispatcher`.
    pub harness: String,
    /// `opus` | `sonnet` | `haiku` | `local` | `unknown`.
    pub model_tier: String,
    /// Free-form capability tags. Examples: "rust", "shell", "pwa",
    /// "tree-sitter", "ci-mirror", "doc-author".
    pub skills: Vec<String>,
    /// Machine identifier (hostname or operator-assigned label).
    /// Always populated (it's not sensitive).
    pub machine: Option<String>,
    /// GPU model. Populated only when `CHUMP_PUBLISH_HARDWARE=1`.
    pub gpu: Option<String>,
    /// IP address. Populated only when `CHUMP_PUBLISH_HARDWARE=1`.
    pub ip: Option<String>,
    /// When this manifest was first published.
    pub started_at: DateTime<Utc>,
    /// Last heartbeat. Stale-session detection compares against this.
    pub heartbeat_at: DateTime<Utc>,
    /// Seconds after `heartbeat_at` before this manifest is treated as
    /// stale. Default `DEFAULT_TTL_SECONDS` (300).
    pub ttl_seconds: u32,
}

impl CapabilityManifest {
    /// Whether this manifest should still be considered alive given a
    /// reference timestamp (usually `Utc::now()`).
    pub fn is_alive(&self, now: DateTime<Utc>) -> bool {
        let age = now.signed_duration_since(self.heartbeat_at);
        age.num_seconds() <= self.ttl_seconds as i64
    }

    /// Whether this session is publishing hardware details (gpu/ip).
    pub fn has_hardware_fields(&self) -> bool {
        self.gpu.is_some() || self.ip.is_some()
    }

    /// Update `heartbeat_at` to now, returning a fresh clone.
    pub fn refreshed(&self) -> Self {
        let mut m = self.clone();
        m.heartbeat_at = Utc::now();
        m
    }
}

/// Build a CapabilityManifest for the current worker session by reading
/// environment + system state. Caller passes the skill list since that's
/// session-specific (and not auto-discoverable in a useful way today).
///
/// Hardware fields (gpu, ip) are populated only when
/// `CHUMP_PUBLISH_HARDWARE=1` is set in the environment.
pub fn current_manifest(skills: Vec<String>) -> CapabilityManifest {
    let now = Utc::now();
    let session_id = std::env::var("CHUMP_SESSION_ID")
        .unwrap_or_else(|_| format!("unknown-{}", std::process::id()));
    let harness = std::env::var("CHUMP_AGENT_HARNESS").unwrap_or_else(|_| "manual".to_string());
    let model_tier = std::env::var("FLEET_MODEL").unwrap_or_else(|_| "unknown".to_string());
    let machine = hostname_or_label();

    let publish_hw = std::env::var("CHUMP_PUBLISH_HARDWARE").as_deref() == Ok("1");
    let (gpu, ip) = if publish_hw {
        (gpu_label(), ip_address())
    } else {
        (None, None)
    };

    CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id,
        harness,
        model_tier,
        skills,
        machine,
        gpu,
        ip,
        started_at: now,
        heartbeat_at: now,
        ttl_seconds: DEFAULT_TTL_SECONDS,
    }
}

// ── NATS KV capability store ─────────────────────────────────────────────────

/// Initialise (or open) the `chump_capabilities` KV bucket on the given
/// JetStream context. TTL matches `DEFAULT_TTL_SECONDS` * 2 so NATS
/// auto-purges entries roughly double the stale window.
pub async fn init_capabilities_bucket(js: &async_nats::jetstream::Context) -> Result<kv::Store> {
    let bucket_name = std::env::var("CHUMP_NATS_CAPABILITIES_BUCKET")
        .unwrap_or_else(|_| CAPABILITIES_BUCKET.to_string());
    let ttl_secs: u64 = (DEFAULT_TTL_SECONDS as u64) * 2; // NATS auto-purge at 2x stale window
    js.create_key_value(kv::Config {
        bucket: bucket_name,
        max_age: Duration::from_secs(ttl_secs),
        history: 2, // lightweight — we only need current + one prior
        ..Default::default()
    })
    .await
    .map_err(|e| anyhow::anyhow!("capabilities KV bucket setup failed: {}", e))
}

/// Publish `manifest` to the `chump_capabilities` NATS KV bucket and
/// append a snapshot to the file audit trail.
///
/// `kv` is the capabilities store (obtained from [`init_capabilities_bucket`]
/// or `CoordClient::capabilities_kv`).
///
/// The file audit is best-effort — a write failure is logged but does NOT
/// propagate an error to the caller (forensics, not critical path).
pub async fn publish_manifest(kv: &kv::Store, manifest: &CapabilityManifest) -> Result<()> {
    let payload: Bytes = serde_json::to_vec(manifest)
        .context("serialize CapabilityManifest")?
        .into();
    kv.put(&manifest.session_id, payload)
        .await
        .map_err(|e| anyhow::anyhow!("capabilities KV put failed: {}", e))?;

    // File audit — best-effort, never blocks the KV publish result.
    if let Err(e) = append_file_audit(manifest) {
        eprintln!("[capability] file audit write failed (non-fatal): {}", e);
    }
    Ok(())
}

/// Append a JSON snapshot of `manifest` to `.chump-locks/capabilities/<session-id>.jsonl`.
/// Directory is created on first call.
fn append_file_audit(manifest: &CapabilityManifest) -> Result<()> {
    let dir = chump_locks_capabilities_dir();
    fs::create_dir_all(&dir).context("create .chump-locks/capabilities")?;
    let path = dir.join(format!(
        "{}.jsonl",
        sanitise_session_id(&manifest.session_id)
    ));
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("open audit file {}", path.display()))?;
    let mut line = serde_json::to_string(manifest).context("serialize for audit")?;
    line.push('\n');
    file.write_all(line.as_bytes())
        .context("write audit line")?;
    Ok(())
}

/// Resolve the `.chump-locks/capabilities/` directory, honouring
/// `CHUMP_LOCKS_DIR` override (used in tests).
fn chump_locks_capabilities_dir() -> PathBuf {
    let base = std::env::var("CHUMP_LOCKS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(".chump-locks"));
    base.join("capabilities")
}

/// Sanitise a session_id so it is safe as a filename (replace problematic
/// chars with `_`).
fn sanitise_session_id(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// Heartbeat loop: refreshes and re-publishes `manifest` every
/// `HEARTBEAT_INTERVAL_SECS` seconds until `shutdown_rx` receives `true`.
///
/// Intended to be spawned via `tokio::spawn`. Errors during heartbeat are
/// logged but do not abort the loop — transient NATS blips should not kill
/// the worker.
///
/// ```no_run
/// # use chump_coord::capability::{current_manifest, init_capabilities_bucket};
/// # use async_nats::jetstream;
/// # #[tokio::main]
/// # async fn main() -> anyhow::Result<()> {
/// # let nats = async_nats::connect("nats://127.0.0.1:4222").await?;
/// # let js = jetstream::new(nats);
/// let kv = init_capabilities_bucket(&js).await?;
/// let manifest = current_manifest(vec!["rust".to_string()]);
/// let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
/// tokio::spawn(chump_coord::capability::heartbeat_loop(kv, manifest, shutdown_rx));
/// // ... do work ...
/// let _ = shutdown_tx.send(true);
/// # Ok(())
/// # }
/// ```
pub async fn heartbeat_loop(
    kv: kv::Store,
    mut manifest: CapabilityManifest,
    mut shutdown_rx: tokio::sync::watch::Receiver<bool>,
) {
    let interval = Duration::from_secs(HEARTBEAT_INTERVAL_SECS);
    loop {
        tokio::select! {
            _ = tokio::time::sleep(interval) => {
                manifest = manifest.refreshed();
                if let Err(e) = publish_manifest(&kv, &manifest).await {
                    eprintln!("[capability] heartbeat publish failed (will retry): {}", e);
                }
            }
            _ = shutdown_rx.changed() => {
                if *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }
}

// ── Discovery API ─────────────────────────────────────────────────────────────

/// List all live (non-stale) capability manifests currently in the
/// `chump_capabilities` KV bucket.
///
/// Stale manifests (heartbeat_at older than their ttl_seconds) are silently
/// excluded — they represent dead or unreachable sessions.
///
/// Forward-compat: unknown JSON fields are ignored — readers tolerate v2+
/// fields added in future schema bumps without a code change.
pub async fn list_capabilities(kv: &kv::Store) -> Result<Vec<CapabilityManifest>> {
    let now = Utc::now();
    let mut keys = kv
        .keys()
        .await
        .map_err(|e| anyhow::anyhow!("capabilities KV keys error: {}", e))?;

    let mut out: Vec<CapabilityManifest> = Vec::new();
    while let Some(key_result) = keys.next().await {
        let key = key_result.map_err(|e| anyhow::anyhow!("KV key stream error: {}", e))?;
        if let Ok(Some(bytes)) = kv.get(&key).await {
            if let Ok(m) = serde_json::from_slice::<CapabilityManifest>(&bytes) {
                if m.is_alive(now) {
                    out.push(m);
                }
                // Stale manifests: silently excluded per AC-3.
            }
        }
    }
    Ok(out)
}

/// Simple routing decision: pick the first live session whose skills
/// include `required_skill`. Returns `None` if no capable session is found.
///
/// This satisfies AC-4 ("picker actively consults manifests for >=1 routing
/// decision per gap"). Production picker will apply richer scoring.
pub fn route_by_skill<'a>(
    manifests: &'a [&CapabilityManifest],
    required_skill: &str,
) -> Option<&'a CapabilityManifest> {
    manifests
        .iter()
        .find(|m| m.skills.iter().any(|s| s.as_str() == required_skill))
        .copied()
}

/// Resolve the target node (hostname) for a given unit (session_id) by
/// reading its capability manifest from the NATS KV store.
///
/// Returns the `machine` field (hostname) of the manifest, or an error if
/// the manifest is not found, stale, or has no machine set.
pub async fn resolve_target_node(kv: &kv::Store, unit: &str) -> Result<String> {
    let bytes = kv
        .get(unit)
        .await
        .map_err(|e| anyhow::anyhow!("failed to read capability manifest for '{}': {}", unit, e))?
        .ok_or_else(|| anyhow::anyhow!("no capability manifest found for unit '{}'", unit))?;

    let manifest: CapabilityManifest =
        serde_json::from_slice(&bytes).context("deserialize capability manifest")?;

    if !manifest.is_alive(Utc::now()) {
        anyhow::bail!("capability manifest for unit '{}' is stale", unit);
    }

    manifest.machine.ok_or_else(|| {
        anyhow::anyhow!(
            "capability manifest for unit '{}' has no machine (hostname) set",
            unit
        )
    })
}

// ── Private helpers ───────────────────────────────────────────────────────────

/// Best-effort hostname read. Falls back to `CHUMP_MACHINE_LABEL` env if
/// the hostname call fails. Returns `None` on total failure.
///
/// Public so callers outside this crate (e.g. `chump-verify`'s
/// `check_live_outcome`, INFRA-7098) can compare a [`resolve_target_node`]
/// result against the current host without re-implementing this lookup.
pub fn hostname_or_label() -> Option<String> {
    if let Ok(label) = std::env::var("CHUMP_MACHINE_LABEL") {
        if !label.is_empty() {
            return Some(label);
        }
    }
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn gpu_label() -> Option<String> {
    std::env::var("CHUMP_GPU_LABEL")
        .ok()
        .filter(|s| !s.is_empty())
}

fn ip_address() -> Option<String> {
    std::env::var("CHUMP_IP_LABEL")
        .ok()
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_version_is_v1() {
        assert_eq!(CAPABILITY_SCHEMA_VERSION, "chump-capability-v1");
    }

    #[test]
    fn json_round_trip() {
        let m = CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: "test-session-1".to_string(),
            harness: "claude".to_string(),
            model_tier: "opus".to_string(),
            skills: vec!["rust".to_string(), "ci-mirror".to_string()],
            machine: Some("test-host".to_string()),
            gpu: None,
            ip: None,
            started_at: Utc::now(),
            heartbeat_at: Utc::now(),
            ttl_seconds: DEFAULT_TTL_SECONDS,
        };
        let json = serde_json::to_string(&m).expect("serialize");
        let back: CapabilityManifest = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(m, back);
    }

    #[test]
    fn is_alive_within_ttl() {
        let now = Utc::now();
        let m = CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: "x".to_string(),
            harness: "manual".to_string(),
            model_tier: "unknown".to_string(),
            skills: vec![],
            machine: None,
            gpu: None,
            ip: None,
            started_at: now,
            heartbeat_at: now,
            ttl_seconds: 300,
        };
        assert!(m.is_alive(now));
        let later = now + chrono::Duration::seconds(200);
        assert!(m.is_alive(later));
        let way_later = now + chrono::Duration::seconds(400);
        assert!(!m.is_alive(way_later));
    }

    #[test]
    fn hardware_fields_default_absent() {
        std::env::remove_var("CHUMP_PUBLISH_HARDWARE");
        let m = current_manifest(vec!["test".to_string()]);
        assert_eq!(
            m.gpu, None,
            "gpu should be absent without CHUMP_PUBLISH_HARDWARE=1"
        );
        assert_eq!(
            m.ip, None,
            "ip should be absent without CHUMP_PUBLISH_HARDWARE=1"
        );
        assert!(!m.has_hardware_fields());
    }

    #[test]
    fn refreshed_updates_heartbeat_at() {
        let m = current_manifest(vec![]);
        let before = m.heartbeat_at;
        std::thread::sleep(std::time::Duration::from_millis(2));
        let refreshed = m.refreshed();
        assert!(refreshed.heartbeat_at >= before);
        assert_eq!(refreshed.started_at, m.started_at);
    }

    #[test]
    fn route_by_skill_finds_match() {
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
        };
        let m1 = make("s1", vec!["shell", "docs"]);
        let m2 = make("s2", vec!["rust", "ci-mirror"]);
        let m3 = make("s3", vec!["pwa"]);
        let manifests = vec![&m1, &m2, &m3];
        let hit = route_by_skill(&manifests, "rust");
        assert!(hit.is_some());
        assert_eq!(hit.unwrap().session_id, "s2");
        assert!(route_by_skill(&manifests, "nonexistent").is_none());
    }

    #[test]
    fn file_audit_creates_jsonl() {
        let tmp = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_LOCKS_DIR", tmp.path());
        let m = CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: "audit-test".to_string(),
            harness: "claude".to_string(),
            model_tier: "sonnet".to_string(),
            skills: vec!["rust".to_string()],
            machine: None,
            gpu: None,
            ip: None,
            started_at: Utc::now(),
            heartbeat_at: Utc::now(),
            ttl_seconds: DEFAULT_TTL_SECONDS,
        };
        append_file_audit(&m).expect("write audit");
        append_file_audit(&m).expect("write audit second time");

        let audit_path = tmp.path().join("capabilities").join("audit-test.jsonl");
        assert!(audit_path.exists());
        let content = std::fs::read_to_string(&audit_path).unwrap();
        let lines: Vec<_> = content.lines().filter(|l| !l.is_empty()).collect();
        assert_eq!(lines.len(), 2, "two heartbeat snapshots");
        for line in lines {
            let parsed: serde_json::Value = serde_json::from_str(line).unwrap();
            assert_eq!(parsed["session_id"], "audit-test");
        }
        std::env::remove_var("CHUMP_LOCKS_DIR");
    }
}
