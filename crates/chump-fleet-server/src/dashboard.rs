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
    pub active_leases: Vec<ActiveLease>,
    pub window_hours: u32,
}

/// Payload surfaced from the most-recent `kind=ci_qa_score` ambient event.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CiQaScore {
    /// % of merged PRs that landed WITHOUT a bypass signal (0.0–100.0) —
    /// see `scripts/ops/ci-qa-score.sh`. Kept for back-compat with existing
    /// consumers; `ci_clean_landing_pct` below is the distinctly-named twin
    /// (INFRA-3847, parent INFRA-3841 slice 4/9) so this value is never
    /// confused with `vital-signs.sh`'s `ci_run_pass_rate` (success/decided
    /// CI *runs* in 24h — a different metric measuring a different thing).
    pub pct: f64,
    /// Same value as `pct`, under the canonical distinctly-named column —
    /// % of merged PRs landed clean (no --no-verify / post-CI rebase /
    /// flake-rerun bypass signal).
    pub ci_clean_landing_pct: f64,
    /// Number of CI runs included in the score.
    pub sample_size: u64,
    /// Canonical status — always one of `green`/`amber`/`red`/`unknown`
    /// (INFRA-3854). Emitters historically used ad-hoc labels
    /// (`OK`/`WARN`/`ALERT`/`no_data`, `healthy`/`degraded`); the dashboard
    /// normalizes whatever arrives via [`CiQaStatus::normalize`] so every
    /// consumer of this field sees the same 4-value vocabulary already used
    /// by `scripts/ops/vital-signs.sh`.
    pub status: CiQaStatus,
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
    let db_path = repo_root.join(".chump").join("state.db");
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

// ── entrypoint called from routes ─────────────────────────────────────────────

/// Build the full `DashboardSummary` for a given repo root.
/// All errors are absorbed into reasonable defaults.
pub fn build_summary(repo_root: &Path) -> DashboardSummary {
    const WINDOW_HOURS: u32 = 24;

    let today_ships = count_today_ships(repo_root, WINDOW_HOURS);
    let ci_qa_score =
        read_ci_qa_score(repo_root, WINDOW_HOURS).or_else(|| compute_ci_qa_score_live(repo_root));
    let active_leases = read_active_leases(repo_root);

    DashboardSummary {
        today_ships,
        merges_24h: today_ships,
        ci_qa_score,
        active_leases,
        window_hours: WINDOW_HOURS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
            active_leases: Vec::new(),
            window_hours: 24,
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
}
