//! INFRA-1883: `/api/dashboard-summary` — operator quick-glance endpoint.
//!
//! Returns a single JSON document with:
//!
//! - `today_ships` — count of PRs merged in the last 24 h.
//!   Reads `.chump/github_cache.db` first (cache-first per INFRA-1081);
//!   falls through to `gh pr list --state merged --json mergedAt` on cold cache.
//! - `merges_24h` — INFRA-7142 (INFRA-3841 slice): identical value to
//!   `today_ships`, emitted under the canonical `merges_24h` column name
//!   shared with `scripts/ops/vital-signs.sh` and
//!   `scripts/ops/faculty-collector.sh` (both also emit a top-level
//!   `merges_24h` field). `today_ships` stays for back-compat with existing
//!   consumers (`web/v2/dashboard-tiles.js`, `scripts/dev/chump-dashboard-tui.sh`).
//! - `ci_qa_score` — payload of the most recent `kind=ci_qa_score` event from
//!   `.chump-locks/ambient.jsonl` (INFRA-1872 emit) within the last 24 h. When
//!   no fresh event exists (the emitter isn't scheduled on this node), falls
//!   back to shelling out to the canonical `scripts/ops/ci-qa-score.sh --json`,
//!   which recomputes live AND re-emits the ambient event (self-healing).
//!   Returns `null` only when neither source yields data.
//! - `active_leases` — top-10 active (unexpired) claim leases sorted by
//!   `expires_at` DESC. Primary source is the canonical gap-store sqlite
//!   `.chump/state.db` (`leases` table); claim/lease state moved there from the
//!   legacy `.chump-locks/claim-*.json` files, which remain a fallback.
//! - `window_hours` — always 24 (seconds per window).

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ── public response shape ─────────────────────────────────────────────────────

/// Top-level response for `GET /api/dashboard-summary`.
#[derive(Debug, Serialize)]
pub struct DashboardSummary {
    pub today_ships: u64,
    /// INFRA-7142 (INFRA-3841 slice): same value as `today_ships`, emitted
    /// under the canonical `merges_24h` column name shared with
    /// `scripts/ops/vital-signs.sh` (top-level `merges_24h`) and
    /// `scripts/ops/faculty-collector.sh` (top-level `merges_24h`). Kept
    /// alongside `today_ships` rather than replacing it — `today_ships` is a
    /// stable public field consumed by `web/v2/dashboard-tiles.js` and
    /// `scripts/dev/chump-dashboard-tui.sh`.
    pub merges_24h: u64,
    pub ci_qa_score: Option<CiQaScore>,
    /// INFRA-8179: count of open PRs currently stuck or landing-wedged
    /// (`DIRTY`/`BLOCKED`/`BEHIND`/`UNSTABLE` in `github_cache.db` or active
    /// `pr_wedged`/`pr_stuck`/`landing_wedged` signals in `ambient.jsonl`).
    pub stuck_prs: u64,
    /// INFRA-8179: alias of `stuck_prs` for cockpit landing-health consumers.
    pub landing_wedged_prs: u64,
    /// INFRA-8179: honest landing percentage (`0.0..=100.0`) accounting for
    /// open landing-wedged PRs so the cockpit never shows 100% green while
    /// PRs are wedged.
    pub landing_pct: f64,
    /// INFRA-8179: canonical `green|amber|red|unknown` status for landing health.
    pub landing_status: CiQaStatus,
    pub active_leases: Vec<ActiveLease>,
    pub window_hours: u32,
    /// RESILIENT-1012: last `node_install_verified` ambient event per node
    /// (host) — the ribbon-acceptance gauge, one entry per node that has
    /// ever self-reported. Board-visible "did the last node self-test pass"
    /// instead of needing an operator to SSH in and eyeball `systemctl`.
    pub ribbon_acceptance: Vec<NodeInstallVerified>,
}

/// Payload surfaced from the most-recent `kind=ci_qa_score` ambient event,
/// adjusted by `count_stuck_or_wedged_prs` (INFRA-8179) so open landing-wedged
/// PRs degrade `pct`, `ci_clean_landing_pct`, and `status`.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CiQaScore {
    /// % of merged PRs that landed WITHOUT a bypass signal (0.0–100.0) —
    /// see `scripts/ops/ci-qa-score.sh`, degraded when open PRs are
    /// landing-wedged (INFRA-8179).
    pub pct: f64,
    /// Same value as `pct`, under the canonical distinctly-named column —
    /// % of PRs landed clean (INFRA-3847 / INFRA-8179).
    pub ci_clean_landing_pct: f64,
    /// Number of PRs/runs included in the score.
    pub sample_size: u64,
    /// Canonical status — always one of `green`/`amber`/`red`/`unknown`
    /// (INFRA-3854).
    pub status: CiQaStatus,
    /// INFRA-8179: number of open stuck / landing-wedged PRs factored into this score.
    #[serde(default)]
    pub stuck_prs: u64,
    /// INFRA-8179: alias for `stuck_prs`.
    #[serde(default)]
    pub landing_wedged_prs: u64,
}

/// The single status vocabulary shared across every emitter + the dashboard
/// (INFRA-3854, parent INFRA-3841 slice). Mirrors the `green|amber|red|unknown`
/// vocabulary `scripts/ops/vital-signs.sh` already uses.
#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CiQaStatus {
    Green,
    Amber,
    Red,
    Unknown,
}

impl CiQaStatus {
    /// Normalize any raw status label (canonical or legacy) into the
    /// 4-value vocabulary. Unrecognized labels map to `Unknown` rather than
    /// erroring, so a stale/foreign emitter never breaks the dashboard.
    pub fn normalize(raw: &str) -> Self {
        match raw.to_ascii_lowercase().as_str() {
            "green" | "ok" | "healthy" | "pass" => CiQaStatus::Green,
            "amber" | "warn" | "warning" | "degraded" => CiQaStatus::Amber,
            "red" | "alert" | "critical" | "fail" => CiQaStatus::Red,
            _ => CiQaStatus::Unknown,
        }
    }
}

/// One active claim lease entry.
#[derive(Debug, Serialize)]
pub struct ActiveLease {
    pub gap: String,
    pub session: String,
    pub expires_at: String,
}

/// One node's most recent `kind=node_install_verified` self-report
/// (RESILIENT-1012).
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct NodeInstallVerified {
    pub host: String,
    pub role: String,
    pub pass: bool,
    pub active_organs: u64,
    pub expected_organs: u64,
    pub ts: String,
}

// ── path helpers ──────────────────────────────────────────────────────────────

/// Resolve the repo root via `git rev-parse --show-toplevel`.
/// Falls back to `.` on failure.
pub fn repo_root() -> PathBuf {
    std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

// ── today_ships ───────────────────────────────────────────────────────────────

/// Count PRs merged in the last `window_hours` hours.
///
/// INFRA-3843 (parent INFRA-3841): `merges_24h` is a CANONICAL computation
/// shared with `scripts/ops/vital-signs.sh` and `scripts/ops/faculty-collector.sh`
/// via `scripts/ops/lib/merges-24h.sh`. Rust can't `source` a bash lib, so
/// when `window_hours == 24` (the only window this server ever requests) and
/// the shared script is resolvable on disk, shell out to it — it implements
/// the identical cache-first-then-`gh` strategy below. Fall back to the
/// in-process implementation when the script isn't found (e.g. hermetic
/// tests whose fixture repo root doesn't contain a full checkout) or the
/// window isn't the canonical 24h.
///
/// In-process strategy (also the shared script's strategy):
///  1. Open `.chump/github_cache.db` read-only.
///  2. Query `merged_at IS NOT NULL AND merged_at >= <cutoff_rfc3339>`.
///  3. On any error (missing DB, SQL error), fall back to `gh pr list`.
pub fn count_today_ships(repo_root: &Path, window_hours: u32) -> u64 {
    count_today_ships_from_shared_helper(repo_root, window_hours)
        .or_else(|| count_today_ships_from_cache(repo_root, window_hours).ok())
        .unwrap_or_else(|| count_today_ships_from_gh(window_hours))
}

/// Shell out to the canonical `scripts/ops/lib/merges-24h.sh` helper. Only
/// applies for the canonical 24h window; the script is located via the real
/// git checkout root (not `repo_root`, which in tests is a bare fixture
/// dir) so it resolves correctly under `cargo test` too, while `repo_root`
/// is still passed through as the *data* root the script should read.
fn count_today_ships_from_shared_helper(data_root: &Path, window_hours: u32) -> Option<u64> {
    if window_hours != 24 {
        return None;
    }
    let script = repo_root().join("scripts/ops/lib/merges-24h.sh");
    if !script.is_file() {
        return None;
    }
    let out = std::process::Command::new("bash")
        .arg(&script)
        .arg(data_root)
        .arg("repairman29/chump")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse::<u64>()
        .ok()
}

fn count_today_ships_from_cache(repo_root: &Path, window_hours: u32) -> Result<u64> {
    let db_path = repo_root.join(".chump").join("github_cache.db");
    let conn = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("opening github_cache at {}", db_path.display()))?;

    // Compute the cutoff timestamp as RFC 3339 string.
    // The `merged_at` column stores ISO 8601 strings from GitHub's API, e.g.
    // "2026-05-28T12:34:56Z" — lexicographic comparison is correct for UTC.
    let cutoff = cutoff_rfc3339(window_hours);

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pr_state WHERE merged_at IS NOT NULL AND merged_at >= ?1",
            params![cutoff],
            |r| r.get(0),
        )
        .context("querying merged PR count from cache")?;

    Ok(count.max(0) as u64)
}

/// RFC 3339 timestamp for `now - window_hours`.
fn cutoff_rfc3339(window_hours: u32) -> String {
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs();
    let cutoff_secs = secs.saturating_sub(u64::from(window_hours) * 3600);
    // Build a minimal RFC 3339 string: YYYY-MM-DDTHH:MM:SSZ
    epoch_to_rfc3339(cutoff_secs)
}

fn epoch_to_rfc3339(secs: u64) -> String {
    // Manual conversion — avoids pulling in `chrono` or `time` crates.
    let s = secs;
    let sec = s % 60;
    let min = (s / 60) % 60;
    let hour = (s / 3600) % 24;
    let days = s / 86400;
    // Days since 1970-01-01.
    let (year, month, day) = days_to_ymd(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    // Gregorian calendar: 400-year cycle = 146097 days.
    let z = days + 719468; // shift epoch to 0000-03-01
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

/// Fallback: shell out to `gh pr list` to count merged PRs in window.
fn count_today_ships_from_gh(window_hours: u32) -> u64 {
    // Ask for up to 200 recent merged PRs; count those merged after the cutoff.
    let cutoff = cutoff_rfc3339(window_hours);
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "merged",
            "--repo",
            "repairman29/chump",
            "--limit",
            "200",
            "--json",
            "mergedAt",
        ])
        .output();

    let out = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return 0,
    };

    let json: serde_json::Value = match serde_json::from_slice(&out) {
        Ok(v) => v,
        Err(_) => return 0,
    };

    let arr = match json.as_array() {
        Some(a) => a,
        None => return 0,
    };

    arr.iter()
        .filter(|pr| {
            pr.get("mergedAt")
                .and_then(|v| v.as_str())
                .map(|t| t >= cutoff.as_str())
                .unwrap_or(false)
        })
        .count() as u64
}

// ── ci_qa_score ───────────────────────────────────────────────────────────────

/// Read the most recent `kind=ci_qa_score` event from `ambient.jsonl`
/// (INFRA-1872 emit) within the last `window_hours` hours.
///
/// Returns `None` if the file is absent, empty, or no qualifying event
/// exists within the window.
pub fn read_ci_qa_score(repo_root: &Path, window_hours: u32) -> Option<CiQaScore> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let content = std::fs::read_to_string(&ambient_path).ok()?;

    let cutoff_ms = {
        use std::time::{Duration, SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        (secs.saturating_sub(u64::from(window_hours) * 3600)) as i64 * 1000
    };

    // Scan lines in reverse; return the first (= most recent) matching event.
    for line in content.lines().rev() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Filter by kind.
        if v.get("kind").and_then(|k| k.as_str()) != Some("ci_qa_score") {
            continue;
        }

        // Filter by timestamp — ambient events use either `ts` (ISO string) or
        // `ts_ms` (integer milliseconds). Try both.
        let in_window = event_in_window(&v, cutoff_ms);
        if !in_window {
            continue;
        }

        // Extract the score payload. The INFRA-1872 spec emits the fields
        // directly at the top level; fall back to a nested `payload` object.
        let score = extract_ci_qa_score(&v);
        if score.is_some() {
            return score;
        }
    }

    None
}

fn event_in_window(v: &serde_json::Value, cutoff_ms: i64) -> bool {
    // Try ts_ms (integer milliseconds).
    if let Some(ts_ms) = v.get("ts_ms").and_then(|t| t.as_i64()) {
        return ts_ms >= cutoff_ms;
    }
    // Try ts (ISO 8601 / RFC 3339 string) — parse manually by comparing
    // the first 19 characters lexicographically against the cutoff.
    if let Some(ts_str) = v.get("ts").and_then(|t| t.as_str()) {
        let cutoff_secs = cutoff_ms / 1000;
        let cutoff_str = epoch_to_rfc3339(cutoff_secs.max(0) as u64);
        return ts_str >= cutoff_str.as_str();
    }
    // No timestamp found — include by default (conservatively).
    true
}

fn extract_ci_qa_score(v: &serde_json::Value) -> Option<CiQaScore> {
    // The INFRA-1872 emitter may place fields at top-level or inside `payload`.
    let candidates: &[&serde_json::Value] = &[v, v.get("payload").unwrap_or(v)];

    for obj in candidates {
        let pct = obj
            .get("pct")
            .and_then(|p| p.as_f64())
            .or_else(|| obj.get("pass_pct").and_then(|p| p.as_f64()))
            .or_else(|| obj.get("score").and_then(|p| p.as_f64()));

        let sample_size = obj
            .get("sample_size")
            .and_then(|s| s.as_u64())
            .or_else(|| obj.get("n").and_then(|s| s.as_u64()))
            .or_else(|| obj.get("count").and_then(|s| s.as_u64()));

        let status = obj
            .get("status")
            .and_then(|s| s.as_str())
            .map(str::to_owned)
            .or_else(|| obj.get("label").and_then(|s| s.as_str()).map(str::to_owned));

        if let (Some(pct), Some(sample_size), Some(status)) = (pct, sample_size, status) {
            return Some(CiQaScore {
                pct,
                ci_clean_landing_pct: pct,
                sample_size,
                status: CiQaStatus::normalize(&status),
                stuck_prs: 0,
                landing_wedged_prs: 0,
            });
        }
    }
    None
}

/// Fallback for when `ambient.jsonl` carries no fresh `ci_qa_score` event
/// (i.e. the INFRA-1872 emitter isn't scheduled on this node): shell out to
/// the canonical `scripts/ops/ci-qa-score.sh --json`. That script recomputes
/// the score from live CI data AND re-emits the ambient event, so subsequent
/// requests are served by the fast ambient path (self-healing). The script
/// exits 1/2 for WARN/ALERT, so stdout is parsed regardless of exit status.
///
/// Only runs when the dashboard's data root IS the real git checkout: the
/// script computes over the checkout's own ambient log and `gh` history and
/// (re-)emits into it, so it is meaningless — and a test-polluting side
/// effect — to invoke it for a synthetic/tempdir data root.
fn compute_ci_qa_score_live(data_root: &Path) -> Option<CiQaScore> {
    let checkout = repo_root();
    let same = std::fs::canonicalize(data_root).ok() == std::fs::canonicalize(&checkout).ok()
        || data_root == checkout;
    if !same {
        return None;
    }
    let script = checkout.join("scripts/ops/ci-qa-score.sh");
    if !script.is_file() {
        return None;
    }
    let out = std::process::Command::new("bash")
        .arg(&script)
        .arg("--json")
        .output()
        .ok()?;
    // Do NOT gate on out.status: WARN/ALERT return non-zero by design.
    let stdout = String::from_utf8_lossy(&out.stdout);
    for line in stdout.lines().rev() {
        let v: serde_json::Value = match serde_json::from_str(line.trim()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("kind").and_then(|k| k.as_str()) != Some("ci_qa_score") {
            continue;
        }
        if let Some(score) = extract_ci_qa_score(&v) {
            return Some(score);
        }
    }
    None
}

// ── ribbon_acceptance (RESILIENT-1012) ────────────────────────────────────────

/// Read the most recent `kind=node_install_verified` event PER HOST from
/// `ambient.jsonl` (no time window — a node that hasn't self-tested since
/// last boot should still show its last-known verdict rather than silently
/// disappearing from the board). Returns entries sorted by host name.
pub fn read_ribbon_acceptance(repo_root: &Path) -> Vec<NodeInstallVerified> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let content = match std::fs::read_to_string(&ambient_path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };

    let mut latest: std::collections::BTreeMap<String, NodeInstallVerified> =
        std::collections::BTreeMap::new();

    for line in content.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("kind").and_then(|k| k.as_str()) != Some("node_install_verified") {
            continue;
        }
        let entry = match extract_node_install_verified(&v) {
            Some(e) => e,
            None => continue,
        };
        // Lines are appended in chronological order, so the last one seen
        // per host is the most recent — plain overwrite is correct.
        latest.insert(entry.host.clone(), entry);
    }

    latest.into_values().collect()
}

fn extract_node_install_verified(v: &serde_json::Value) -> Option<NodeInstallVerified> {
    let host = v.get("host").and_then(|h| h.as_str())?.to_owned();
    let role = v
        .get("role")
        .and_then(|r| r.as_str())
        .unwrap_or("unknown")
        .to_owned();
    let pass = v.get("pass").and_then(|p| p.as_bool())?;
    let active_organs = v.get("active_organs").and_then(|a| a.as_u64()).unwrap_or(0);
    let expected_organs = v
        .get("expected_organs")
        .and_then(|e| e.as_u64())
        .unwrap_or(0);
    let ts = v
        .get("ts")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .to_owned();

    Some(NodeInstallVerified {
        host,
        role,
        pass,
        active_organs,
        expected_organs,
        ts,
    })
}

// ── active_leases ─────────────────────────────────────────────────────────────

/// Return the top-10 active (unexpired) claim leases, most-time-remaining
/// first. Primary source is the canonical gap-store sqlite `.chump/state.db`
/// (`leases` table) — claim/lease state moved there from the legacy
/// `.chump-locks/claim-*.json` files (gap-store consolidation). Falls back to
/// the legacy JSON files when the DB is absent or unreadable.
pub fn read_active_leases(repo_root: &Path) -> Vec<ActiveLease> {
    read_active_leases_from_db(repo_root)
        .unwrap_or_else(|| read_active_leases_from_files(repo_root))
}

/// Read active (unexpired) leases from `.chump/state.db`. Returns `None` when
/// the DB is absent/unreadable (so the caller falls back to the JSON files);
/// returns `Some(vec![])` when the DB is readable but holds no active lease
/// (authoritative empty — no active claims — do NOT resurrect stale files).
fn read_active_leases_from_db(repo_root: &Path) -> Option<Vec<ActiveLease>> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let db_path = chump_store_path::state_db_path(repo_root); // INFRA-8190
    if !db_path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    let mut stmt = conn
        .prepare(
            "SELECT gap_id, session_id, expires_at FROM leases \
             WHERE expires_at > ?1 ORDER BY expires_at DESC LIMIT 10",
        )
        .ok()?;
    let rows = stmt
        .query_map(params![now], |r| {
            let gap: String = r.get(0)?;
            let session: String = r.get(1)?;
            let expires_at: i64 = r.get(2)?;
            Ok(ActiveLease {
                gap,
                session,
                expires_at: epoch_to_rfc3339(expires_at.max(0) as u64),
            })
        })
        .ok()?;
    Some(rows.filter_map(|r| r.ok()).collect())
}

/// Legacy fallback: parse `.chump-locks/claim-*.json` and return the top-10
/// leases sorted by `expires_at` descending (most time remaining first).
fn read_active_leases_from_files(repo_root: &Path) -> Vec<ActiveLease> {
    let lock_dir = repo_root.join(".chump-locks");
    let pattern = lock_dir.join("claim-*.json");

    let entries = match glob::glob(pattern.to_str().unwrap_or("")) {
        Ok(e) => e,
        Err(_) => return vec![],
    };

    let mut leases: Vec<ActiveLease> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|path| parse_claim_json(&path))
        .collect();

    // Sort by expires_at descending (most time remaining first).
    leases.sort_by(|a, b| b.expires_at.cmp(&a.expires_at));
    leases.truncate(10);
    leases
}

fn parse_claim_json(path: &Path) -> Option<ActiveLease> {
    let content = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&content).ok()?;

    // The claim JSON has varied field names across versions.
    // Try gap_id / gap, session_id / session, expires_at / lease_expires.
    let gap = v
        .get("gap_id")
        .or_else(|| v.get("gap"))
        .and_then(|g| g.as_str())
        .map(str::to_owned)?;

    let session = v
        .get("session_id")
        .or_else(|| v.get("session"))
        .and_then(|s| s.as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            // Derive from filename: claim-<gap>-<session>.json
            path.file_stem()
                .and_then(|s| s.to_str())
                .map(str::to_owned)
                .unwrap_or_default()
        });

    let expires_at = v
        .get("expires_at")
        .or_else(|| v.get("lease_expires"))
        .or_else(|| v.get("expiry"))
        .and_then(|e| {
            // Accept either string or numeric (epoch seconds).
            if let Some(s) = e.as_str() {
                Some(s.to_owned())
            } else {
                e.as_i64().map(|ts| epoch_to_rfc3339(ts.max(0) as u64))
            }
        })
        .unwrap_or_default();

    Some(ActiveLease {
        gap,
        session,
        expires_at,
    })
}

// ── stuck / landing-wedged PRs (INFRA-8179) ───────────────────────────────────

/// Count open PRs that are stuck or landing-wedged from:
///  1. `.chump/github_cache.db` (`pr_state` rows with `merged_at` null/empty and
///     wedged/blocked/dirty/unstable/behind mergeable state),
///  2. `.chump-locks/ambient.jsonl` (`pr_wedged`, `pr_stuck`,
///     `pr_stuck_announced`, `pr_stuck_cluster`, `landing_wedged`,
///     `merge_wedged` events within `window_hours`),
///  3. `.chump-locks/pr-wedged-signaled.json` (if present).
pub fn count_stuck_or_wedged_prs(repo_root: &Path, window_hours: u32) -> u64 {
    let mut pr_nums: std::collections::BTreeSet<u64> = std::collections::BTreeSet::new();
    let mut unnumbered_events: u64 = 0;
    let mut cluster_count: u64 = 0;

    // 1. Check `.chump/github_cache.db` `pr_state`.
    collect_wedged_prs_from_cache(repo_root, &mut pr_nums);

    // 2. Check `.chump-locks/ambient.jsonl`.
    collect_wedged_prs_from_ambient(
        repo_root,
        window_hours,
        &mut pr_nums,
        &mut unnumbered_events,
        &mut cluster_count,
    );

    // 3. Check `.chump-locks/pr-wedged-signaled.json`.
    collect_wedged_prs_from_signaled_file(repo_root, &mut pr_nums);

    (pr_nums.len() as u64 + unnumbered_events).max(cluster_count)
}

fn collect_wedged_prs_from_cache(repo_root: &Path, pr_nums: &mut std::collections::BTreeSet<u64>) {
    let db_path = repo_root.join(".chump").join("github_cache.db");
    let Ok(conn) = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return;
    };

    let Ok(mut col_stmt) = conn.prepare("PRAGMA table_info(pr_state)") else {
        return;
    };
    let Ok(col_rows) = col_stmt.query_map([], |r| r.get::<_, String>(1)) else {
        return;
    };
    let cols: std::collections::BTreeSet<String> = col_rows
        .filter_map(|r| r.ok())
        .map(|s| s.to_ascii_lowercase())
        .collect();

    let has_mergeable = cols.contains("mergeable_state");
    let has_merge_status = cols.contains("merge_state_status");
    let has_auto_merge = cols.contains("auto_merge_enabled");
    let has_wedged =
        cols.contains("wedged") || cols.contains("landing_wedged") || cols.contains("stuck");
    if !has_mergeable && !has_merge_status && !has_auto_merge && !has_wedged {
        return;
    }

    let select_mergeable = if has_mergeable {
        "COALESCE(CAST(mergeable_state AS TEXT), '')"
    } else {
        "''"
    };
    let select_merge_status = if has_merge_status {
        "COALESCE(CAST(merge_state_status AS TEXT), '')"
    } else {
        "''"
    };
    let select_auto_merge = if has_auto_merge {
        "COALESCE(CAST(auto_merge_enabled AS TEXT), '0')"
    } else {
        "'0'"
    };
    let select_wedged = if cols.contains("landing_wedged") {
        "COALESCE(CAST(landing_wedged AS TEXT), '0')"
    } else if cols.contains("wedged") {
        "COALESCE(CAST(wedged AS TEXT), '0')"
    } else if cols.contains("stuck") {
        "COALESCE(CAST(stuck AS TEXT), '0')"
    } else {
        "'0'"
    };
    let state_filter = if cols.contains("state") {
        "AND UPPER(COALESCE(state, 'OPEN')) = 'OPEN'"
    } else {
        ""
    };

    let sql = format!(
        "SELECT number, {select_mergeable}, {select_merge_status}, {select_auto_merge}, {select_wedged} \
         FROM pr_state \
         WHERE (merged_at IS NULL OR merged_at = '') {state_filter}"
    );
    let Ok(mut stmt) = conn.prepare(&sql) else {
        return;
    };
    let Ok(rows) = stmt.query_map([], |r| {
        let num: i64 = r.get(0)?;
        let m_state: String = r.get(1)?;
        let ms_status: String = r.get(2)?;
        let auto_m: String = r.get(3)?;
        let wedged_flag: String = r.get(4)?;
        Ok((num, m_state, ms_status, auto_m, wedged_flag))
    }) else {
        return;
    };

    const WEDGED_STATES: &[&str] = &[
        "DIRTY",
        "BLOCKED",
        "BEHIND",
        "UNSTABLE",
        "WEDGED",
        "STUCK",
        "CONFLICTING",
        "HAS_HOOKS",
    ];

    for (num, m_state, ms_status, auto_m, wedged_flag) in rows.flatten() {
        if num <= 0 {
            continue;
        }
        let m_up = m_state.trim().to_ascii_uppercase();
        let ms_up = ms_status.trim().to_ascii_uppercase();
        let auto_on = matches!(auto_m.trim(), "1" | "true" | "TRUE");
        let explicit_wedged = matches!(wedged_flag.trim(), "1" | "true" | "TRUE");
        let state_wedged = WEDGED_STATES.contains(&m_up.as_str())
            || WEDGED_STATES.contains(&ms_up.as_str())
            || (auto_on
                && ((!m_up.is_empty() && m_up != "CLEAN")
                    || (!ms_up.is_empty() && ms_up != "CLEAN")));
        if explicit_wedged || state_wedged {
            pr_nums.insert(num as u64);
        }
    }
}

fn parse_pr_num_value(v: &serde_json::Value) -> Option<u64> {
    v.as_u64().or_else(|| {
        v.as_str()
            .and_then(|s| s.trim().trim_start_matches('#').parse::<u64>().ok())
    })
}

fn collect_wedged_prs_from_ambient(
    repo_root: &Path,
    window_hours: u32,
    pr_nums: &mut std::collections::BTreeSet<u64>,
    unnumbered_events: &mut u64,
    cluster_count: &mut u64,
) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let Ok(content) = std::fs::read_to_string(&ambient_path) else {
        return;
    };
    let cutoff_ms = {
        use std::time::{Duration, SystemTime, UNIX_EPOCH};
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        (secs.saturating_sub(u64::from(window_hours) * 3600)) as i64 * 1000
    };

    const WEDGED_KINDS: &[&str] = &[
        "pr_wedged",
        "pr_stuck",
        "pr_stuck_announced",
        "pr_stuck_cluster",
        "landing_wedged",
        "merge_wedged",
    ];

    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if !event_in_window(&v, cutoff_ms) {
            continue;
        }
        let Some(kind) = v.get("kind").and_then(|k| k.as_str()) else {
            continue;
        };
        if matches!(kind, "pr_merged" | "pr_closed" | "pr_unwedged") {
            if let Some(n) = v
                .get("pr")
                .or_else(|| v.get("pr_number"))
                .or_else(|| v.get("number"))
                .and_then(parse_pr_num_value)
            {
                pr_nums.remove(&n);
            }
            continue;
        }
        if !WEDGED_KINDS.contains(&kind) {
            continue;
        }

        let payload = v.get("payload").unwrap_or(&v);
        let mut matched_specific = false;

        for count_key in ["stuck_count", "wedged_count", "landing_wedged_prs", "count"] {
            if let Some(c) = v
                .get(count_key)
                .or_else(|| payload.get(count_key))
                .and_then(|c| c.as_u64())
            {
                *cluster_count = (*cluster_count).max(c);
                matched_specific = true;
            }
        }

        if let Some(arr) = v
            .get("prs")
            .or_else(|| payload.get("prs"))
            .and_then(|a| a.as_array())
        {
            for item in arr {
                if let Some(n) = parse_pr_num_value(item) {
                    pr_nums.insert(n);
                    matched_specific = true;
                }
            }
        }

        for pr_key in ["pr", "pr_number", "number"] {
            if let Some(n) = v
                .get(pr_key)
                .or_else(|| payload.get(pr_key))
                .and_then(parse_pr_num_value)
            {
                pr_nums.insert(n);
                matched_specific = true;
            }
        }

        if !matched_specific {
            *unnumbered_events += 1;
        }
    }
}

fn collect_wedged_prs_from_signaled_file(
    repo_root: &Path,
    pr_nums: &mut std::collections::BTreeSet<u64>,
) {
    let path = repo_root
        .join(".chump-locks")
        .join("pr-wedged-signaled.json");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return;
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) else {
        return;
    };
    match v {
        serde_json::Value::Array(items) => {
            for item in items {
                if let Some(n) = parse_pr_num_value(&item) {
                    pr_nums.insert(n);
                }
            }
        }
        serde_json::Value::Object(map) => {
            if let Some(serde_json::Value::Array(items)) = map.get("prs") {
                for item in items {
                    if let Some(n) = parse_pr_num_value(item) {
                        pr_nums.insert(n);
                    }
                }
            } else {
                for key in map.keys() {
                    if let Ok(n) = key.trim().trim_start_matches('#').parse::<u64>() {
                        pr_nums.insert(n);
                    }
                }
            }
        }
        _ => {}
    }
}

// ── debt / dormancy crown-metric index (INFRA-8179) ───────────────────────────

/// One dormant capability entry surfaced in `/api/debt` (`top5_dormant` and
/// `nba_candidates`).
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct DormantCapabilityEntry {
    pub id: String,
    pub name: String,
    pub title: String,
    pub priority: String,
    pub criticality: String,
    pub stages_short: u8,
    pub status: String,
}

/// Response payload for `GET /api/debt` (and alias `GET /api/debt-index`).
///
/// Mirrors the `CrownGauge` / `DebtIndexSection` schema in `chump-kpi-report`
/// (`live_pct`, `debt`, `top5_dormant`, `nba_candidate_count`, `nba_candidates`,
/// `prune_count`) so the cockpit and operators can read the live-capability /
/// dormancy crown metric over HTTP.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DebtIndexResponse {
    /// Crit-weighted fraction of capabilities that are live (`0.0..=1.0`).
    pub live_pct: f64,
    /// Same live fraction expressed as a `0.0..=100.0` percentage for UI tiles.
    pub live_pct_100: f64,
    /// Dormancy debt score: sum of `criticality_weight * stages_short` over
    /// high-criticality (`Crit`/`Warn`) dormant capabilities.
    pub debt: f64,
    /// Alias of `debt` for callers reading `debt_score`.
    pub debt_score: f64,
    pub total_capabilities: usize,
    pub live_count: usize,
    pub dormant_count: usize,
    pub prune_count: usize,
    pub top5_dormant: Vec<DormantCapabilityEntry>,
    pub nba_candidate_count: usize,
    pub nba_candidates: Vec<DormantCapabilityEntry>,
    pub status: CiQaStatus,
}

fn gap_criticality(priority: &str) -> (&'static str, f64, u8) {
    match priority.trim().to_ascii_lowercase().as_str() {
        "p0" | "p1" | "critical" | "high" => ("Crit", 4.0, 2),
        "p2" | "medium" => ("Warn", 2.0, 1),
        _ => ("Info", 1.0, 0),
    }
}

fn gap_stage_status(status: &str) -> (&'static str, bool) {
    match status.trim().to_ascii_lowercase().as_str() {
        "done" | "shipped" | "closed" => ("Complete", true),
        "in_progress" | "claimed" | "running" => ("Running", true),
        _ => ("Pending", false),
    }
}

fn effort_to_stages_short(effort: &str, is_live: bool) -> u8 {
    if is_live {
        return 0;
    }
    match effort.trim().to_ascii_lowercase().as_str() {
        "xs" => 1,
        "s" => 2,
        "m" => 3,
        "l" => 4,
        "xl" => 5,
        _ => 2,
    }
}

/// Build the debt/dormancy crown-metric index from `.chump/state.db` (`gaps` +
/// optional `tech_debt_findings`), falling back to `ambient.jsonl`
/// (`kind=debt_index_computed`) when the DB is absent.
pub fn build_debt_index(repo_root: &Path) -> DebtIndexResponse {
    let db_path = chump_store_path::state_db_path(repo_root);
    if db_path.is_file() {
        if let Ok(conn) = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
            if let Some(resp) = compute_debt_index_from_db(&conn) {
                return resp;
            }
        }
    }
    if let Some(resp) = read_debt_index_from_ambient(repo_root) {
        return resp;
    }
    DebtIndexResponse {
        live_pct: 1.0,
        live_pct_100: 100.0,
        debt: 0.0,
        debt_score: 0.0,
        total_capabilities: 0,
        live_count: 0,
        dormant_count: 0,
        prune_count: 0,
        top5_dormant: vec![],
        nba_candidate_count: 0,
        nba_candidates: vec![],
        status: CiQaStatus::Unknown,
    }
}

fn compute_debt_index_from_db(conn: &Connection) -> Option<DebtIndexResponse> {
    let prune_count: usize = conn
        .query_row(
            "SELECT COUNT(*) FROM tech_debt_findings \
             WHERE resolved_by_gap IS NULL OR resolved_by_gap = ''",
            [],
            |r| r.get::<_, i64>(0),
        )
        .ok()
        .map(|n| n.max(0) as usize)
        .unwrap_or(0);

    let mut stmt = conn
        .prepare(
            "SELECT id, COALESCE(title, ''), COALESCE(priority, 'P2'), \
                    COALESCE(status, 'open'), COALESCE(effort, 's') \
             FROM gaps",
        )
        .ok()?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
            ))
        })
        .ok()?;

    let mut total_capabilities = 0usize;
    let mut live_count = 0usize;
    let mut total_weight = 0.0f64;
    let mut live_weight = 0.0f64;
    let mut debt = 0.0f64;
    let mut dormant_with_rank: Vec<(u8, DormantCapabilityEntry)> = Vec::new();
    let mut nba_with_rank: Vec<(u8, DormantCapabilityEntry)> = Vec::new();

    for row in rows.flatten() {
        let (id, title, priority, status, effort) = row;
        total_capabilities += 1;
        let (crit_label, crit_weight, crit_rank) = gap_criticality(&priority);
        let (stage_label, is_live) = gap_stage_status(&status);
        let stages_short = effort_to_stages_short(&effort, is_live);

        total_weight += crit_weight;
        if is_live {
            live_count += 1;
            live_weight += crit_weight;
        } else {
            let display_name = if title.trim().is_empty() {
                id.clone()
            } else {
                format!("{id}: {}", title.trim())
            };
            let entry = DormantCapabilityEntry {
                id,
                name: display_name,
                title,
                priority,
                criticality: crit_label.to_string(),
                stages_short,
                status: stage_label.to_string(),
            };
            if crit_rank >= 1 {
                debt += crit_weight * f64::from(stages_short);
                nba_with_rank.push((crit_rank, entry.clone()));
            }
            dormant_with_rank.push((crit_rank, entry));
        }
    }

    dormant_with_rank.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| b.1.stages_short.cmp(&a.1.stages_short))
            .then_with(|| a.1.name.cmp(&b.1.name))
    });
    nba_with_rank.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| b.1.stages_short.cmp(&a.1.stages_short))
            .then_with(|| a.1.name.cmp(&b.1.name))
    });

    let dormant_count = dormant_with_rank.len();
    let top5_dormant: Vec<DormantCapabilityEntry> = dormant_with_rank
        .into_iter()
        .take(5)
        .map(|(_, e)| e)
        .collect();
    let nba_candidates: Vec<DormantCapabilityEntry> =
        nba_with_rank.into_iter().map(|(_, e)| e).collect();
    let nba_candidate_count = nba_candidates.len();

    let live_pct = if total_weight > 0.0 {
        (live_weight / total_weight).clamp(0.0, 1.0)
    } else {
        1.0
    };
    let live_pct_100 = (live_pct * 1000.0).round() / 10.0;

    let status = if total_capabilities == 0 {
        CiQaStatus::Unknown
    } else if debt <= 0.0 {
        CiQaStatus::Green
    } else if live_pct >= 0.5 {
        CiQaStatus::Amber
    } else {
        CiQaStatus::Red
    };

    Some(DebtIndexResponse {
        live_pct,
        live_pct_100,
        debt,
        debt_score: debt,
        total_capabilities,
        live_count,
        dormant_count,
        prune_count,
        top5_dormant,
        nba_candidate_count,
        nba_candidates,
        status,
    })
}

fn read_debt_index_from_ambient(repo_root: &Path) -> Option<DebtIndexResponse> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let content = std::fs::read_to_string(&ambient_path).ok()?;
    for line in content.lines().rev() {
        let v: serde_json::Value = serde_json::from_str(line).ok()?;
        if v.get("kind").and_then(|k| k.as_str()) != Some("debt_index_computed") {
            continue;
        }
        let live_pct = v.get("live_pct").and_then(|x| x.as_f64()).unwrap_or(1.0);
        let debt = v.get("debt").and_then(|x| x.as_f64()).unwrap_or(0.0);
        let nba_candidate_count = v
            .get("nba_count")
            .or_else(|| v.get("nba_candidate_count"))
            .and_then(|x| x.as_u64())
            .unwrap_or(0) as usize;
        let prune_count = v.get("prune_count").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
        let status = if debt <= 0.0 {
            CiQaStatus::Green
        } else if live_pct >= 0.5 {
            CiQaStatus::Amber
        } else {
            CiQaStatus::Red
        };
        return Some(DebtIndexResponse {
            live_pct,
            live_pct_100: (live_pct * 1000.0).round() / 10.0,
            debt,
            debt_score: debt,
            total_capabilities: nba_candidate_count,
            live_count: 0,
            dormant_count: nba_candidate_count,
            prune_count,
            top5_dormant: vec![],
            nba_candidate_count,
            nba_candidates: vec![],
            status,
        });
    }
    None
}

// ── entrypoint called from routes ─────────────────────────────────────────────

/// Build the full `DashboardSummary` for a given repo root.
/// All errors are absorbed into reasonable defaults.
pub fn build_summary(repo_root: &Path) -> DashboardSummary {
    const WINDOW_HOURS: u32 = 24;

    let today_ships = count_today_ships(repo_root, WINDOW_HOURS);
    let raw_ci_qa =
        read_ci_qa_score(repo_root, WINDOW_HOURS).or_else(|| compute_ci_qa_score_live(repo_root));
    let stuck_prs = count_stuck_or_wedged_prs(repo_root, WINDOW_HOURS);

    let ci_qa_score = match (raw_ci_qa, stuck_prs) {
        (Some(mut score), n) if n > 0 => {
            let base_sample = score.sample_size.max(today_ships);
            let clean_landed = ((score.pct / 100.0) * (base_sample as f64))
                .round()
                .max(0.0);
            let total = base_sample + n;
            let mut effective_pct = if total > 0 {
                ((clean_landed * 100.0) / (total as f64) * 10.0).round() / 10.0
            } else {
                0.0
            };
            if effective_pct >= 100.0 {
                effective_pct = 99.0;
            }
            score.pct = effective_pct;
            score.ci_clean_landing_pct = effective_pct;
            score.sample_size = total;
            score.stuck_prs = n;
            score.landing_wedged_prs = n;
            score.status = if effective_pct < 80.0 || n >= 5 {
                CiQaStatus::Red
            } else {
                CiQaStatus::Amber
            };
            Some(score)
        }
        (None, n) if n > 0 => {
            let total = today_ships + n;
            let mut effective_pct = if total > 0 {
                ((today_ships as f64 * 100.0) / (total as f64) * 10.0).round() / 10.0
            } else {
                0.0
            };
            if effective_pct >= 100.0 {
                effective_pct = 99.0;
            }
            let status = if effective_pct < 80.0 || n >= 5 {
                CiQaStatus::Red
            } else {
                CiQaStatus::Amber
            };
            Some(CiQaScore {
                pct: effective_pct,
                ci_clean_landing_pct: effective_pct,
                sample_size: total,
                status,
                stuck_prs: n,
                landing_wedged_prs: n,
            })
        }
        (other, _) => other,
    };

    let (landing_pct, landing_status) = if stuck_prs > 0 {
        let total_landing = today_ships + stuck_prs;
        let mut pct = if total_landing > 0 {
            ((today_ships as f64 * 100.0) / (total_landing as f64) * 10.0).round() / 10.0
        } else {
            0.0
        };
        if pct >= 100.0 {
            pct = 99.0;
        }
        let status = if pct < 80.0 || stuck_prs >= 5 {
            CiQaStatus::Red
        } else {
            CiQaStatus::Amber
        };
        (pct, status)
    } else if let Some(ref s) = ci_qa_score {
        (s.ci_clean_landing_pct, s.status)
    } else if today_ships > 0 {
        (100.0, CiQaStatus::Green)
    } else {
        (0.0, CiQaStatus::Unknown)
    };

    let active_leases = read_active_leases(repo_root);
    let ribbon_acceptance = read_ribbon_acceptance(repo_root);

    DashboardSummary {
        today_ships,
        merges_24h: today_ships,
        ci_qa_score,
        stuck_prs,
        landing_wedged_prs: stuck_prs,
        landing_pct,
        landing_status,
        active_leases,
        window_hours: WINDOW_HOURS,
        ribbon_acceptance,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_ambient(dir: &Path, lines: &[String]) {
        let locks = dir.join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        std::fs::write(locks.join("ambient.jsonl"), lines.join("\n") + "\n").unwrap();
    }

    /// RESILIENT-1012: no ambient.jsonl at all → empty gauge, not a panic.
    #[test]
    fn ribbon_acceptance_empty_without_ambient_file() {
        let dir = std::env::temp_dir().join("chump-test-ribbon-empty");
        std::fs::create_dir_all(&dir).unwrap();
        assert!(read_ribbon_acceptance(&dir).is_empty());
    }

    /// RESILIENT-1012 core AC: the gauge must surface the MOST RECENT
    /// node_install_verified event per host — an older FAIL from the same
    /// host followed by a newer PASS must resolve to PASS (the ribbon's
    /// current, not historical, state), and two distinct hosts must both
    /// appear rather than one clobbering the other.
    #[test]
    fn ribbon_acceptance_keeps_latest_per_host_and_all_hosts() {
        let dir = std::env::temp_dir().join("chump-test-ribbon-latest");
        write_ambient(
            &dir,
            &[
                r#"{"ts":"2026-09-05T10:00:00Z","kind":"node_install_verified","host":"mugman","role":"muscle","pass":false,"active_organs":2,"expected_organs":5}"#.to_string(),
                r#"{"ts":"2026-09-05T10:05:00Z","kind":"node_install_verified","host":"mugman","role":"muscle","pass":true,"active_organs":5,"expected_organs":5}"#.to_string(),
                r#"{"ts":"2026-09-05T10:05:00Z","kind":"node_install_verified","host":"helsinki","role":"brain","pass":true,"active_organs":8,"expected_organs":8}"#.to_string(),
                r#"{"ts":"2026-09-05T10:06:00Z","kind":"organ_reconcile_noop"}"#.to_string(),
            ],
        );

        let result = read_ribbon_acceptance(&dir);
        assert_eq!(
            result.len(),
            2,
            "expected one entry per host, got {result:?}"
        );

        let mugman = result.iter().find(|e| e.host == "mugman").unwrap();
        assert!(mugman.pass, "mugman's LATEST event is pass=true");
        assert_eq!(mugman.active_organs, 5);
        assert_eq!(mugman.expected_organs, 5);

        let helsinki = result.iter().find(|e| e.host == "helsinki").unwrap();
        assert!(helsinki.pass);
        assert_eq!(helsinki.role, "brain");
    }

    /// INFRA-3854 (INFRA-3841 slice 6/9): every `ci_qa_score` emitter, plus
    /// the dashboard's own normalization, must resolve onto the same 4-value
    /// vocabulary already used by `scripts/ops/vital-signs.sh`
    /// (`green|amber|red|unknown`). `scripts/ops/ci-qa-score.sh` previously
    /// emitted `OK|WARN|ALERT|no_data` — this test proves both that vocabulary
    /// and the canonical one normalize onto exactly `{green, amber, red,
    /// unknown}`, and that garbage input degrades to `unknown` rather than
    /// erroring.
    #[test]
    fn ci_qa_status_normalizes_every_emitter_onto_canonical_vocabulary() {
        let legacy_ci_qa_score_sh = [("OK", "green"), ("WARN", "amber"), ("ALERT", "red")];
        for (raw, want) in legacy_ci_qa_score_sh {
            let got = serde_json::to_value(CiQaStatus::normalize(raw)).unwrap();
            assert_eq!(
                got, want,
                "legacy ci-qa-score.sh status {raw:?} must normalize to {want:?}"
            );
        }

        let canonical = [
            ("green", CiQaStatus::Green),
            ("amber", CiQaStatus::Amber),
            ("red", CiQaStatus::Red),
            ("unknown", CiQaStatus::Unknown),
        ];
        for (raw, want) in canonical {
            assert_eq!(CiQaStatus::normalize(raw), want);
        }

        // Unrecognized input (e.g. a foreign emitter's own label) must
        // degrade to `unknown`, never panic or propagate an unbounded string.
        assert_eq!(CiQaStatus::normalize("no_data"), CiQaStatus::Unknown);
        assert_eq!(CiQaStatus::normalize("garbage"), CiQaStatus::Unknown);

        // Every possible normalized value serializes to one of exactly the
        // 4 canonical lowercase strings — the single status vocabulary.
        for status in [
            CiQaStatus::Green,
            CiQaStatus::Amber,
            CiQaStatus::Red,
            CiQaStatus::Unknown,
        ] {
            let s = serde_json::to_value(status).unwrap();
            let s = s.as_str().unwrap();
            assert!(
                ["green", "amber", "red", "unknown"].contains(&s),
                "status {s:?} is outside the canonical 4-value vocabulary"
            );
        }
    }

    /// INFRA-7142 (INFRA-3841 slice): the JSON emitted by dashboard.rs must
    /// carry the canonical `merges_24h` column name — the same name used by
    /// `scripts/ops/vital-signs.sh` and `scripts/ops/faculty-collector.sh`
    /// (see `scripts/ci/test-merges-24h-canonical.sh`). Before this change
    /// `DashboardSummary` only had `today_ships`, so `v["merges_24h"]` was
    /// `Value::Null` and this assertion failed.
    #[test]
    fn dashboard_summary_emits_canonical_merges_24h_column() {
        let summary = DashboardSummary {
            today_ships: 7,
            merges_24h: 7,
            ci_qa_score: None,
            stuck_prs: 0,
            landing_wedged_prs: 0,
            landing_pct: 100.0,
            landing_status: CiQaStatus::Green,
            active_leases: Vec::new(),
            window_hours: 24,
            ribbon_acceptance: Vec::new(),
        };

        let v: serde_json::Value = serde_json::to_value(&summary).unwrap();

        assert_eq!(
            v.get("merges_24h").and_then(|n| n.as_u64()),
            Some(7),
            "DashboardSummary must serialize a canonical `merges_24h` column matching today_ships"
        );
        assert_eq!(
            v["merges_24h"], v["today_ships"],
            "merges_24h must always equal today_ships"
        );
    }

    #[test]
    fn build_summary_degrades_ci_qa_and_landing_when_prs_wedged() {
        use std::time::{Duration, SystemTime, UNIX_EPOCH};
        let tmp = std::env::temp_dir().join(format!(
            "infra-8179-wedged-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or(Duration::ZERO)
                .as_nanos()
        ));
        let chump_dir = tmp.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let db_path = chump_dir.join("github_cache.db");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE pr_state (
                number INTEGER PRIMARY KEY,
                merged_at TEXT,
                mergeable_state TEXT,
                updated_at_api TEXT NOT NULL DEFAULT '',
                fetched_at_local TEXT NOT NULL DEFAULT ''
            );
            INSERT INTO pr_state (number, merged_at, mergeable_state) VALUES
                (101, NULL, 'DIRTY'),
                (102, NULL, 'BLOCKED'),
                (103, NULL, 'BEHIND');",
        )
        .unwrap();
        drop(conn);

        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_millis() as i64;
        write_ambient(
            &tmp,
            &[
                format!(
                    r#"{{"kind":"ci_qa_score","ts_ms":{now_ms},"pct":100.0,"sample_size":7,"status":"green"}}"#
                ),
                format!(r#"{{"kind":"pr_wedged","ts_ms":{now_ms},"pr":104}}"#),
            ],
        );

        let summary = build_summary(&tmp);
        std::fs::remove_dir_all(&tmp).ok();

        assert_eq!(summary.stuck_prs, 4);
        assert_eq!(summary.landing_wedged_prs, 4);
        assert!(
            summary.landing_pct < 100.0,
            "landing_pct must be < 100 when PRs are wedged, got {}",
            summary.landing_pct
        );
        assert_ne!(
            summary.landing_status,
            CiQaStatus::Green,
            "landing_status must not be Green when PRs are wedged"
        );
        let qa = summary.ci_qa_score.expect("ci_qa_score must be present");
        assert!(
            qa.pct < 100.0,
            "ci_qa_score.pct must be < 100 when PRs are wedged, got {}",
            qa.pct
        );
        assert!(qa.ci_clean_landing_pct < 100.0);
        assert_ne!(
            qa.status,
            CiQaStatus::Green,
            "ci_qa_score.status must not be Green when PRs are wedged"
        );
        assert_eq!(qa.stuck_prs, 4);
    }

    #[test]
    fn build_debt_index_computes_crown_metrics_from_state_db() {
        use std::time::{Duration, SystemTime, UNIX_EPOCH};
        let tmp = std::env::temp_dir().join(format!(
            "infra-8179-debt-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or(Duration::ZERO)
                .as_nanos()
        ));
        let chump_dir = tmp.join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let db_path = chump_dir.join("state.db");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE gaps (
                id TEXT PRIMARY KEY,
                title TEXT,
                priority TEXT,
                status TEXT,
                effort TEXT
            );
            INSERT INTO gaps (id, title, priority, status, effort) VALUES
                ('INFRA-1', 'Shipped cap', 'P0', 'done', 'm'),
                ('INFRA-2', 'Dormant P0 cap', 'P0', 'open', 'l'),
                ('INFRA-3', 'Dormant P2 cap', 'P2', 'open', 's');",
        )
        .unwrap();
        drop(conn);

        let debt = build_debt_index(&tmp);
        std::fs::remove_dir_all(&tmp).ok();

        assert_eq!(debt.total_capabilities, 3);
        assert_eq!(debt.live_count, 1);
        assert_eq!(debt.dormant_count, 2);
        // P0 live weight 4.0 / total weight (4.0 + 4.0 + 2.0 = 10.0) = 0.4
        assert!((debt.live_pct - 0.4).abs() < 1e-6, "got {}", debt.live_pct);
        // Debt = 4.0 * 4 (l) + 2.0 * 2 (s) = 20.0
        assert!((debt.debt - 20.0).abs() < 1e-6, "got {}", debt.debt);
        assert_eq!(debt.nba_candidate_count, 2);
        assert_eq!(debt.top5_dormant.len(), 2);
        assert_eq!(debt.top5_dormant[0].id, "INFRA-2");
        assert_eq!(debt.status, CiQaStatus::Red);
    }

    /// INFRA-7400 (INFRA-3841 slice): INFRA-3843/INFRA-7142 already unified
    /// vital-signs.sh, faculty-collector.sh, and dashboard.rs onto the
    /// single canonical computation in `scripts/ops/lib/merges-24h.sh` (see
    /// `scripts/ci/test-merges-24h-canonical.sh`), but that shell-side test
    /// never exercised dashboard.rs's own code path — it only proved the two
    /// *bash* callers agreed with each other. This test closes that hole:
    /// it drives `count_today_ships_from_shared_helper` (dashboard.rs's
    /// real entry point) against the exact fixture shape used by the shell
    /// test (5 merges inside the 24h window, 2 outside as a negative
    /// control) and asserts the Rust path aggregates to the same value.
    #[test]
    fn count_today_ships_matches_canonical_fixture() {
        use std::time::{Duration, SystemTime, UNIX_EPOCH};

        let tmp = std::env::temp_dir().join(format!(
            "infra-7400-merges24h-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or(Duration::ZERO)
                .as_nanos()
        ));
        let chump_dir = tmp.join(".chump");
        std::fs::create_dir_all(&chump_dir).expect("create fixture .chump dir");
        let db_path = chump_dir.join("github_cache.db");

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs();
        let merged_1h_ago = epoch_to_rfc3339(now.saturating_sub(3600));
        let merged_3d_ago = epoch_to_rfc3339(now.saturating_sub(3 * 86400));

        let conn = Connection::open(&db_path).expect("create fixture cache db");
        conn.execute_batch(&format!(
            "CREATE TABLE pr_state (
                number INTEGER PRIMARY KEY,
                merged_at TEXT,
                updated_at_api TEXT NOT NULL DEFAULT '',
                fetched_at_local TEXT NOT NULL DEFAULT ''
            );
            INSERT INTO pr_state (number, merged_at, updated_at_api, fetched_at_local) VALUES
                (1, '{m1}', '{m1}', '{m1}'),
                (2, '{m1}', '{m1}', '{m1}'),
                (3, '{m1}', '{m1}', '{m1}'),
                (4, '{m1}', '{m1}', '{m1}'),
                (5, '{m1}', '{m1}', '{m1}'),
                (6, '{m3d}', '{m3d}', '{m3d}'),
                (7, '{m3d}', '{m3d}', '{m3d}');",
            m1 = merged_1h_ago,
            m3d = merged_3d_ago,
        ))
        .expect("seed fixture pr_state rows");
        drop(conn);

        let via_shared_helper = count_today_ships_from_shared_helper(&tmp, 24);
        let via_public_api = count_today_ships(&tmp, 24);

        std::fs::remove_dir_all(&tmp).ok();

        assert_eq!(
            via_shared_helper,
            Some(5),
            "dashboard.rs's shared-helper path must aggregate merges_24h the same way \
             scripts/ci/test-merges-24h-canonical.sh proves vital-signs.sh and \
             faculty-collector.sh do (5 merges inside the 24h window)"
        );
        assert_eq!(
            via_public_api, 5,
            "count_today_ships (the DashboardSummary.merges_24h source) must equal \
             the canonical fixture count"
        );
    }

    /// EFFECTIVE-1134: exercises the unified `chump_agent_lease::LeaseStore`
    /// abstraction end-to-end against its SQLite back-end, proving the
    /// dashboard crate can depend on the shared lease CRUD surface rather
    /// than rolling its own.
    #[test]
    fn lease_store_crud() {
        use chump_agent_lease::store::sqlite::SqliteLeaseStore;
        use chump_agent_lease::{LeaseRecord, LeaseStore};

        let store = SqliteLeaseStore::open(":memory:").expect("open in-memory lease store");
        let record = LeaseRecord {
            id: "EFFECTIVE-1134".to_string(),
            session_id: "dashboard-test-session".to_string(),
            paths: vec!["crates/chump-fleet-server/src/dashboard.rs".to_string()],
            expires_at: "2026-01-01T00:00:00Z".to_string(),
        };

        store.create(&record).expect("create");
        assert_eq!(
            store.read(&record.id).expect("read after create"),
            Some(record.clone()),
            "read must return exactly what was created"
        );

        let mut updated = record.clone();
        updated.session_id = "dashboard-test-session-2".to_string();
        store.update(&updated).expect("update");
        assert_eq!(
            store.read(&record.id).expect("read after update"),
            Some(updated),
            "read must reflect the updated session_id"
        );

        store.delete(&record.id).expect("delete");
        assert_eq!(
            store.read(&record.id).expect("read after delete"),
            None,
            "read must return None after delete"
        );
    }
}
