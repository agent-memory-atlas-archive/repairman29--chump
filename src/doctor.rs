//! `chump --doctor` — self-diagnosis CLI command.
//!
//! Sprint D3 (observability + UX): one command that tells users what's wrong
//! with their setup and how to fix it. Modeled after Hermes's `hermes doctor`
//! and cargo's `cargo --list`, but oriented around Chump's specific failure modes.
//!
//! Checks run in this order (each check can emit Pass / Warn / Fail with a fix hint):
//!
//! 1. Binary + version
//! 2. Rust toolchain (informational)
//! 3. `.env` file present and readable
//! 4. Critical env vars (OPENAI_API_BASE, CHUMP_REPO/CHUMP_HOME)
//! 5. DB pool init + schema sanity
//! 6. Inference backend reachability (HTTP GET health)
//! 7. Embed server (optional)
//! 8. Brain directory writability (optional)
//! 9. Tool inventory summary
//! 10. Recent tool health (from `chump_tool_health` DB table)
//! 11. Disk usage of `sessions/`
//! 12. Audit chain integrity (Sprint A3)
//!
//! Output:
//! - Default: ANSI-styled report to stdout, exit 0 if all Pass, exit 1 if any Fail
//! - `--json`: machine-readable JSON to stdout
//! - `--verbose`: include raw values for each check

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[path = "gap_cmd.rs"]
#[allow(dead_code)]
pub mod gap_cmd;

/// Result of a single diagnostic check.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum CheckStatus {
    Pass,
    Warn,
    Fail,
    Skip,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    pub name: String,
    pub status: CheckStatus,
    pub message: String,
    pub fix_hint: Option<String>,
}

impl CheckResult {
    pub fn pass(name: &str, message: impl Into<String>) -> Self {
        Self {
            name: name.to_string(),
            status: CheckStatus::Pass,
            message: message.into(),
            fix_hint: None,
        }
    }
    pub fn warn(name: &str, message: impl Into<String>, fix: impl Into<String>) -> Self {
        Self {
            name: name.to_string(),
            status: CheckStatus::Warn,
            message: message.into(),
            fix_hint: Some(fix.into()),
        }
    }
    pub fn fail(name: &str, message: impl Into<String>, fix: impl Into<String>) -> Self {
        Self {
            name: name.to_string(),
            status: CheckStatus::Fail,
            message: message.into(),
            fix_hint: Some(fix.into()),
        }
    }
    pub fn skip(name: &str, message: impl Into<String>) -> Self {
        Self {
            name: name.to_string(),
            status: CheckStatus::Skip,
            message: message.into(),
            fix_hint: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorReport {
    pub version: String,
    pub checks: Vec<CheckResult>,
}

impl DoctorReport {
    /// RESILIENT-1353: Detects if any health check has failed.
    /// This is the core FAIL detection for fleet-doctor --json output parsing.
    pub fn any_failed(&self) -> bool {
        self.checks.iter().any(|c| c.status == CheckStatus::Fail)
    }

    pub fn any_warning(&self) -> bool {
        self.checks.iter().any(|c| c.status == CheckStatus::Warn)
    }

    pub fn summary_line(&self) -> String {
        let pass = self
            .checks
            .iter()
            .filter(|c| c.status == CheckStatus::Pass)
            .count();
        let warn = self
            .checks
            .iter()
            .filter(|c| c.status == CheckStatus::Warn)
            .count();
        let fail = self
            .checks
            .iter()
            .filter(|c| c.status == CheckStatus::Fail)
            .count();
        let skip = self
            .checks
            .iter()
            .filter(|c| c.status == CheckStatus::Skip)
            .count();
        format!(
            "{} checks: {} pass, {} warn, {} fail, {} skip",
            self.checks.len(),
            pass,
            warn,
            fail,
            skip
        )
    }
}

/// Run all diagnostics and return the report.
pub async fn run_all_checks() -> DoctorReport {
    let mut checks = Vec::new();
    checks.push(check_version());
    checks.push(check_env_file());
    checks.push(check_openai_api_base());
    checks.push(check_repo_env());
    checks.push(check_db_pool());
    checks.push(check_inference_reachable().await);
    checks.push(check_embed_server().await);
    checks.push(check_brain_dir());
    checks.push(check_tool_inventory());
    checks.push(check_audit_chain());
    checks.push(check_disk_usage());
    checks.push(check_model_capabilities());
    checks.push(check_gap_stores());
    checks.push(check_load_aware_deadman());
    DoctorReport {
        version: env!("CARGO_PKG_VERSION").to_string(),
        checks,
    }
}

fn check_version() -> CheckResult {
    CheckResult::pass(
        "version",
        format!("chump {} (build OK)", env!("CARGO_PKG_VERSION")),
    )
}

fn check_env_file() -> CheckResult {
    let base = crate::repo_path::runtime_base();
    let env_path = base.join(".env");
    if env_path.exists() {
        CheckResult::pass("env_file", format!(".env found at {}", env_path.display()))
    } else {
        CheckResult::warn(
            "env_file",
            format!(".env not found at {}", env_path.display()),
            "copy .env.minimal to .env (or run ./scripts/setup/setup-local.sh for guided setup)",
        )
    }
}

fn check_openai_api_base() -> CheckResult {
    match std::env::var("OPENAI_API_BASE") {
        Ok(base) if !base.trim().is_empty() => {
            CheckResult::pass("openai_api_base", format!("OPENAI_API_BASE = {}", base))
        }
        _ => CheckResult::warn(
            "openai_api_base",
            "OPENAI_API_BASE not set — defaults to http://localhost:11434/v1 (Ollama)",
            "set OPENAI_API_BASE in .env (e.g. http://localhost:11434/v1 for Ollama, http://localhost:8000/v1 for vLLM-MLX)",
        ),
    }
}

fn check_repo_env() -> CheckResult {
    let repo = std::env::var("CHUMP_REPO").ok();
    let home = std::env::var("CHUMP_HOME").ok();
    match (repo, home) {
        (Some(r), _) if std::path::Path::new(&r).is_dir() => {
            CheckResult::pass("repo_env", format!("CHUMP_REPO = {}", r))
        }
        (_, Some(h)) if std::path::Path::new(&h).is_dir() => {
            CheckResult::pass("repo_env", format!("CHUMP_HOME = {}", h))
        }
        (Some(r), _) => CheckResult::fail(
            "repo_env",
            format!("CHUMP_REPO = {} but directory does not exist", r),
            "fix the path or unset to use the current working directory",
        ),
        _ => CheckResult::warn(
            "repo_env",
            "CHUMP_REPO and CHUMP_HOME not set — repo tools (read_file, git_commit, etc.) will be disabled",
            "set CHUMP_REPO=/path/to/your/project in .env to enable repo-aware tools",
        ),
    }
}

fn check_db_pool() -> CheckResult {
    match crate::db_pool::get() {
        Ok(conn) => {
            // Verify a key table exists
            let row: Result<i64, _> = conn.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='chump_memory'",
                [],
                |r| r.get(0),
            );
            match row {
                Ok(1) => CheckResult::pass("db_pool", "SQLite pool ready; chump_memory table present"),
                Ok(_) => CheckResult::warn(
                    "db_pool",
                    "DB opened but chump_memory table missing",
                    "delete sessions/chump_memory.db and let Chump recreate it",
                ),
                Err(e) => CheckResult::warn(
                    "db_pool",
                    format!("DB opened but schema check failed: {}", e),
                    "check that sessions/chump_memory.db is not corrupted",
                ),
            }
        }
        Err(e) => CheckResult::fail(
            "db_pool",
            format!("could not open SQLite pool: {}", e),
            "check sessions/ directory permissions; if using encrypted-db feature, set CHUMP_DB_PASSPHRASE",
        ),
    }
}

async fn check_inference_reachable() -> CheckResult {
    let base = std::env::var("OPENAI_API_BASE")
        .unwrap_or_else(|_| "http://localhost:11434/v1".to_string());
    let base = base.trim_end_matches('/').trim_end_matches("/v1");
    let health_url = if base.contains(":11434") {
        // Ollama doesn't have /v1/models on older versions; try the plain root.
        format!("{}/api/tags", base)
    } else {
        format!("{}/v1/models", base)
    };
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return CheckResult::skip(
                "inference_reachable",
                format!("could not build HTTP client: {}", e),
            );
        }
    };
    match client.get(&health_url).send().await {
        Ok(resp) if resp.status().is_success() => CheckResult::pass(
            "inference_reachable",
            format!("inference backend OK at {}", base),
        ),
        Ok(resp) => CheckResult::fail(
            "inference_reachable",
            format!(
                "inference backend at {} returned HTTP {}",
                base,
                resp.status()
            ),
            "check the backend is running and listening on the expected port",
        ),
        Err(e) => CheckResult::fail(
            "inference_reachable",
            format!("cannot reach inference backend at {}: {}", base, e),
            "start Ollama (ollama serve) or vLLM; check OPENAI_API_BASE in .env",
        ),
    }
}

async fn check_embed_server() -> CheckResult {
    let url = match std::env::var("CHUMP_EMBED_URL") {
        Ok(u) if !u.trim().is_empty() => u,
        _ => {
            return CheckResult::skip(
                "embed_server",
                "CHUMP_EMBED_URL not set; semantic recall falls back to in-process fastembed feature or keyword-only",
            );
        }
    };
    let health = format!("{}/health", url.trim_end_matches('/'));
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
    {
        Ok(c) => c,
        Err(_) => return CheckResult::skip("embed_server", "HTTP client build failed"),
    };
    match client.get(&health).send().await {
        Ok(resp) if resp.status().is_success() => {
            CheckResult::pass("embed_server", format!("embed server OK at {}", url))
        }
        Ok(resp) => CheckResult::warn(
            "embed_server",
            format!("embed server at {} returned HTTP {}", url, resp.status()),
            "check embed server is healthy; semantic recall will fall back to keyword-only",
        ),
        Err(_) => CheckResult::warn(
            "embed_server",
            format!("cannot reach embed server at {}", url),
            "start the embed server or unset CHUMP_EMBED_URL to use in-process fastembed / keyword-only",
        ),
    }
}

fn check_brain_dir() -> CheckResult {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let path = if std::path::Path::new(&root).is_absolute() {
        std::path::PathBuf::from(&root)
    } else {
        crate::repo_path::runtime_base().join(&root)
    };
    if !path.exists() {
        return CheckResult::skip(
            "brain_dir",
            format!(
                "brain directory at {} does not exist (optional)",
                path.display()
            ),
        );
    }
    // Try a write test
    let probe = path.join(".chump-doctor-probe");
    match std::fs::write(&probe, b"probe") {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            CheckResult::pass(
                "brain_dir",
                format!("brain directory writable at {}", path.display()),
            )
        }
        Err(e) => CheckResult::warn(
            "brain_dir",
            format!("brain directory at {} not writable: {}", path.display(), e),
            "fix permissions on the brain directory or set CHUMP_BRAIN_PATH elsewhere",
        ),
    }
}

fn check_tool_inventory() -> CheckResult {
    // We don't actually construct the registry here (avoids heavy init); just
    // count the submitted ToolEntry items via the inventory iter at startup.
    let count = inventory::iter::<crate::tool_inventory::ToolEntry>
        .into_iter()
        .count();
    CheckResult::pass(
        "tool_inventory",
        format!("{} tools registered via inventory", count),
    )
}

fn check_audit_chain() -> CheckResult {
    match crate::introspect_tool::audit_chain_status() {
        Ok(status) if status.intact => CheckResult::pass(
            "audit_chain",
            format!(
                "audit chain intact: {} chained rows, {} legacy rows skipped",
                status.chained_rows, status.legacy_rows
            ),
        ),
        Ok(status) => CheckResult::fail(
            "audit_chain",
            format!(
                "audit chain TAMPERED: {} corrupted row(s) in chump_tool_calls",
                status.tamper_points.len()
            ),
            "investigate unauthorized DB modifications; see src/introspect_tool.rs::audit_chain_status for tamper_points",
        ),
        Err(_) => CheckResult::skip("audit_chain", "DB not available; skipping chain verification"),
    }
}

/// INFRA-741: report detected capabilities for the currently configured model
/// using the probe cache. Does not run a live probe (doctor must stay fast).
fn check_model_capabilities() -> CheckResult {
    let model = std::env::var("OPENAI_MODEL").unwrap_or_default();
    let base_url = std::env::var("OPENAI_API_BASE")
        .unwrap_or_else(|_| "http://localhost:11434/v1".to_string());

    if model.is_empty() {
        return CheckResult::skip(
            "model-capabilities",
            "OPENAI_MODEL not set — skipping probe",
        );
    }

    match crate::model_overlay::cached_capability_summary(&model, &base_url) {
        Some(summary) => {
            CheckResult::pass("model-capabilities", format!("model={} {}", model, summary))
        }
        None => CheckResult::warn(
            "model-capabilities",
            format!("no probe cached for model={}", model),
            "run `chump probe` (or any gap) to cache capabilities for this model+endpoint",
        ),
    }
}

fn check_disk_usage() -> CheckResult {
    let sessions = crate::repo_path::runtime_base().join("sessions");
    if !sessions.exists() {
        return CheckResult::skip("disk_usage", "sessions/ directory does not yet exist");
    }
    let total: u64 = walkdir(&sessions)
        .iter()
        .filter_map(|p| std::fs::metadata(p).ok())
        .map(|m| m.len())
        .sum();
    let mb = total as f64 / (1024.0 * 1024.0);
    if mb > 1000.0 {
        CheckResult::warn(
            "disk_usage",
            format!("sessions/ directory is {:.1} GB", mb / 1024.0),
            "consider running ./scripts/dev/cleanup-repo.sh or archiving old sessions",
        )
    } else {
        CheckResult::pass("disk_usage", format!("sessions/ = {:.1} MB", mb))
    }
}

fn walkdir(root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(p) = stack.pop() {
        if let Ok(rd) = std::fs::read_dir(&p) {
            for entry in rd.flatten() {
                let pp = entry.path();
                if pp.is_dir() {
                    stack.push(pp);
                } else {
                    out.push(pp);
                }
            }
        }
    }
    out
}

/// RESILIENT-1650 (PHASE-R R4): scan candidate gap stores on this node
/// (`CHUMP_STATE_DB`, `<repo>/.chump/state.db`, `~/.chump/state.db`, and
/// bounded `$HOME` `.chump/state.db` copies) and classify each as `canonical`,
/// `non-canonical` (carries `NONCANONICAL` or `CHUMP_STORE_ARCHIVED`), or
/// `UNMARKED` (extra unmarked live store, which fails the check).
pub fn classify_node_gap_stores(
    home: Option<&Path>,
    repo_root: Option<&Path>,
    env_state_db: Option<&str>,
) -> CheckResult {
    let mut candidate_dbs: Vec<PathBuf> = Vec::new();

    if let Some(raw) = env_state_db.map(str::trim).filter(|s| !s.is_empty()) {
        candidate_dbs.push(PathBuf::from(raw));
    }
    if let Some(repo) = repo_root {
        candidate_dbs.push(repo.join(".chump").join("state.db"));
    }
    if let Some(h) = home {
        candidate_dbs.push(h.join(".chump").join("state.db"));
        candidate_dbs.push(h.join("chump").join(".chump").join("state.db"));
        scan_home_for_chump_stores(h, 0, 4, &mut candidate_dbs);
    }

    let mut seen_dirs: BTreeSet<PathBuf> = BTreeSet::new();
    let mut unmarked: Vec<PathBuf> = Vec::new();
    let mut noncanonical: Vec<String> = Vec::new();

    for db in candidate_dbs {
        // Ignore symlinks (linked worktrees symlink .chump/state.db to main checkout).
        if let Ok(meta) = std::fs::symlink_metadata(&db) {
            if meta.file_type().is_symlink() {
                continue;
            }
        }
        let Some(parent) = db.parent() else {
            continue;
        };
        let marker = chump_gap_store::GapStore::store_noncanonical_marker(&db);
        let db_exists = db.is_file();
        if !db_exists && marker.is_none() {
            continue;
        }
        let canon_dir = std::fs::canonicalize(parent).unwrap_or_else(|_| parent.to_path_buf());
        if !seen_dirs.insert(canon_dir) {
            continue;
        }
        if let Some(m) = marker {
            let marker_name = m
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("NONCANONICAL");
            noncanonical.push(format!("{} ({})", db.display(), marker_name));
        } else if db_exists {
            unmarked.push(db);
        }
    }

    let preferred_canon: Option<PathBuf> = env_state_db
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| repo_root.map(|r| r.join(".chump").join("state.db")))
        .or_else(|| home.map(|h| h.join("chump").join(".chump").join("state.db")));

    let mut canonical: Option<PathBuf> = None;
    let mut unmarked_extras: Vec<PathBuf> = Vec::new();

    if let Some(ref pref) = preferred_canon {
        let pref_canon = std::fs::canonicalize(pref).ok();
        for u in &unmarked {
            let matches_pref = std::fs::canonicalize(u).ok() == pref_canon || u == pref;
            if canonical.is_none() && matches_pref {
                canonical = Some(u.clone());
            }
        }
    }
    if canonical.is_none() && !unmarked.is_empty() {
        canonical = Some(unmarked[0].clone());
    }
    let canon_real = canonical
        .as_ref()
        .and_then(|c| std::fs::canonicalize(c).ok());
    for u in unmarked {
        let is_canon = match (&canonical, &canon_real) {
            (Some(c), Some(cr)) => std::fs::canonicalize(&u).ok().as_ref() == Some(cr) || &u == c,
            (Some(c), None) => &u == c,
            _ => false,
        };
        if !is_canon {
            unmarked_extras.push(u);
        }
    }

    let canon_str = canonical
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "none".to_string());
    let noncanon_str = if noncanonical.is_empty() {
        "none".to_string()
    } else {
        noncanonical.join(", ")
    };

    if !unmarked_extras.is_empty() {
        let unmarked_str: Vec<String> = unmarked_extras
            .iter()
            .map(|p| p.display().to_string())
            .collect();
        CheckResult::fail(
            "single-store",
            format!(
                "canonical: {}; non-canonical: {}; UNMARKED: {} (RESILIENT-1650 split-brain hazard)",
                canon_str,
                noncanon_str,
                unmarked_str.join(", ")
            ),
            "retire each UNMARKED store with scripts/coord/archive-stale-gap-store.sh <path> --reason <why> --canonical <canonical-store> or drop a NONCANONICAL marker beside it",
        )
    } else {
        CheckResult::pass(
            "single-store",
            format!(
                "canonical: {}; non-canonical: {} (UNMARKED: none)",
                canon_str, noncanon_str
            ),
        )
    }
}

fn scan_home_for_chump_stores(dir: &Path, depth: usize, max_depth: usize, out: &mut Vec<PathBuf>) {
    if depth > max_depth {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        if ft.is_symlink() || !ft.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let name_s = name.to_string_lossy();
        if matches!(
            name_s.as_ref(),
            "tmp" | ".cache" | "node_modules" | ".cargo" | ".rustup" | ".git" | "target"
        ) || name_s.ends_with("-backup")
        {
            continue;
        }
        let path = entry.path();
        if name_s == ".chump" {
            out.push(path.join("state.db"));
            continue;
        }
        scan_home_for_chump_stores(&path, depth + 1, max_depth, out);
    }
}

pub fn check_gap_stores() -> CheckResult {
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let repo = crate::repo_path::runtime_base();
    let env_db = std::env::var("CHUMP_STATE_DB").ok();
    classify_node_gap_stores(home.as_deref(), Some(&repo), env_db.as_deref())
}

/// CREDIBLE-1568: maximum age (seconds) for `kind=deadman_tick` in `ambient.jsonl`.
pub const DEADMAN_MAX_AGE_SECS: u64 = 300;

/// CREDIBLE-1568: pure evaluator for `deadman_tick` freshness (`<= 300s`).
/// When `active_host` is false (non-Linux/non-systemd and
/// `CHUMP_DOCTOR_CHECK_DEADMAN` is not `"1"`), returns `CheckStatus::Skip`.
pub fn check_load_aware_deadman_at(
    ambient_path: &Path,
    now_unix: u64,
    active_host: bool,
) -> CheckResult {
    if !active_host {
        return CheckResult::skip(
            "load-aware-deadman",
            "not a Linux systemd host (set CHUMP_DOCTOR_CHECK_DEADMAN=1 to force check)",
        );
    }
    let Ok(contents) = std::fs::read_to_string(ambient_path) else {
        return CheckResult::fail(
            "load-aware-deadman",
            format!(
                "ambient.jsonl missing at {} — cannot verify deadman_tick heartbeat (CREDIBLE-1568)",
                ambient_path.display()
            ),
            "bash scripts/setup/install-load-aware-deadman.sh && systemctl --user status chump-load-aware-deadman.timer",
        );
    };

    let mut latest_ts_str: Option<String> = None;
    for line in contents.lines() {
        if !line.contains("deadman_tick") {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
            if v.get("kind").and_then(|k| k.as_str()) == Some("deadman_tick") {
                if let Some(ts) = v.get("ts").and_then(|t| t.as_str()) {
                    latest_ts_str = Some(ts.to_string());
                }
            }
        }
    }

    let Some(ts_str) = latest_ts_str else {
        return CheckResult::fail(
            "load-aware-deadman",
            format!(
                "no kind=deadman_tick heartbeat found in {} — load-aware dead-man is silent or not installed (CREDIBLE-1568)",
                ambient_path.display()
            ),
            "bash scripts/setup/install-load-aware-deadman.sh && systemctl --user restart chump-load-aware-deadman.timer",
        );
    };

    let Some(tick_unix) = chrono::DateTime::parse_from_rfc3339(&ts_str)
        .ok()
        .map(|dt| dt.timestamp().max(0) as u64)
    else {
        return CheckResult::fail(
            "load-aware-deadman",
            format!(
                "newest deadman_tick timestamp '{}' could not be parsed (CREDIBLE-1568)",
                ts_str
            ),
            "inspect .chump-locks/ambient.jsonl and chump-load-aware-deadman.timer logs",
        );
    };

    let age = now_unix.saturating_sub(tick_unix);
    if age > DEADMAN_MAX_AGE_SECS {
        CheckResult::fail(
            "load-aware-deadman",
            format!(
                "last deadman_tick was {}s ago (threshold <={}s) — dead-man heartbeat is stale (CREDIBLE-1568)",
                age, DEADMAN_MAX_AGE_SECS
            ),
            "systemctl --user restart chump-load-aware-deadman.timer",
        )
    } else {
        CheckResult::pass(
            "load-aware-deadman",
            format!(
                "deadman_tick fresh ({}s ago, threshold <={}s)",
                age, DEADMAN_MAX_AGE_SECS
            ),
        )
    }
}

pub fn check_load_aware_deadman() -> CheckResult {
    let forced = std::env::var("CHUMP_DOCTOR_CHECK_DEADMAN")
        .map(|v| v.trim() == "1")
        .unwrap_or(false);
    let is_linux_systemd = cfg!(target_os = "linux") && Path::new("/run/systemd/system").exists();
    let ambient = std::env::var("CHUMP_AMBIENT_LOG")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if let Ok(home) = std::env::var("HOME") {
                let candidate = PathBuf::from(&home)
                    .join("chump")
                    .join(".chump-locks")
                    .join("ambient.jsonl");
                if candidate.exists() {
                    return candidate;
                }
            }
            crate::repo_path::runtime_base()
                .join(".chump-locks")
                .join("ambient.jsonl")
        });
    let now_unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    check_load_aware_deadman_at(&ambient, now_unix, forced || is_linux_systemd)
}

// ── Pretty-printing ───────────────────────────────────────────────────

fn icon(status: &CheckStatus) -> &'static str {
    match status {
        CheckStatus::Pass => "✓",
        CheckStatus::Warn => "⚠",
        CheckStatus::Fail => "✗",
        CheckStatus::Skip => "○",
    }
}

/// Print a human-readable report to stdout. Returns the exit code (0 = all ok, 1 = failures).
pub fn print_human_report(report: &DoctorReport) -> i32 {
    println!();
    println!("chump doctor — v{}", report.version);
    println!("{}", "=".repeat(60));
    for c in &report.checks {
        println!("  {}  {:24} — {}", icon(&c.status), c.name, c.message);
        if let Some(ref fix) = c.fix_hint {
            println!("      → {}", fix);
        }
    }
    println!("{}", "=".repeat(60));
    println!("  {}", report.summary_line());
    println!();
    if report.any_failed() {
        1
    } else {
        0
    }
}

/// Print report as JSON. Returns the exit code.
pub fn print_json_report(report: &DoctorReport) -> i32 {
    match serde_json::to_string_pretty(report) {
        Ok(s) => println!("{}", s),
        Err(e) => eprintln!("doctor: JSON serialization failed: {}", e),
    }
    if report.any_failed() {
        1
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn summary_counts_correctly() {
        let report = DoctorReport {
            version: "0.1.0".to_string(),
            checks: vec![
                CheckResult::pass("a", "ok"),
                CheckResult::pass("b", "ok"),
                CheckResult::warn("c", "hmm", "fix it"),
                CheckResult::fail("d", "bad", "fix asap"),
                CheckResult::skip("e", "optional"),
            ],
        };
        let s = report.summary_line();
        assert!(s.contains("2 pass"));
        assert!(s.contains("1 warn"));
        assert!(s.contains("1 fail"));
        assert!(s.contains("1 skip"));
        assert!(report.any_failed());
        assert!(report.any_warning());
    }

    #[test]
    fn all_pass_has_no_failures() {
        let report = DoctorReport {
            version: "0.1.0".to_string(),
            checks: vec![CheckResult::pass("a", "ok")],
        };
        assert!(!report.any_failed());
        assert!(!report.any_warning());
    }

    #[test]
    fn icons_match_status() {
        assert_eq!(icon(&CheckStatus::Pass), "✓");
        assert_eq!(icon(&CheckStatus::Warn), "⚠");
        assert_eq!(icon(&CheckStatus::Fail), "✗");
        assert_eq!(icon(&CheckStatus::Skip), "○");
    }

    #[test]
    fn check_result_builders() {
        let p = CheckResult::pass("x", "ok");
        assert_eq!(p.status, CheckStatus::Pass);
        assert!(p.fix_hint.is_none());

        let w = CheckResult::warn("x", "hmm", "fix");
        assert_eq!(w.status, CheckStatus::Warn);
        assert_eq!(w.fix_hint.as_deref(), Some("fix"));
    }

    #[test]
    #[serial]
    fn version_check_always_passes() {
        let r = check_version();
        assert_eq!(r.status, CheckStatus::Pass);
        assert!(r.message.contains("chump"));
    }

    // INFRA-977: serialize against other env-mutating tests. Without this,
    // a parallel test (e.g. in src/tool_middleware.rs already uses bare
    // #[serial]) calls set_var("CHUMP_REPO", ...) between this test's
    // remove_var and the check_repo_env call, so status comes back Pass
    // instead of Warn — observed flake on every PR in the 2026-05-13 queue
    // (#1648/1649/1650/1651/1652). Bare #[serial] joins the same default
    // serialization group used elsewhere in the codebase for env tests.
    #[test]
    #[serial]
    fn repo_env_missing_is_warn_not_fail() {
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();
        std::env::remove_var("CHUMP_REPO");
        std::env::remove_var("CHUMP_HOME");
        let r = check_repo_env();
        assert_eq!(r.status, CheckStatus::Warn);
        if let Some(v) = prev_repo {
            std::env::set_var("CHUMP_REPO", v);
        }
        if let Some(v) = prev_home {
            std::env::set_var("CHUMP_HOME", v);
        }
    }

    #[test]
    fn resilient1650_classify_node_gap_stores_canonical_noncanonical_and_unmarked() {
        let sb = tempfile::tempdir().unwrap();
        let canon_dir = sb.path().join("chump").join(".chump");
        let noncanon_dir = sb.path().join(".chump");
        let unmarked_dir = sb.path().join(".chumpnode").join("repo").join(".chump");
        std::fs::create_dir_all(&canon_dir).unwrap();
        std::fs::create_dir_all(&noncanon_dir).unwrap();
        std::fs::create_dir_all(&unmarked_dir).unwrap();

        let canon_db = canon_dir.join("state.db");
        let noncanon_db = noncanon_dir.join("state.db");
        let unmarked_db = unmarked_dir.join("state.db");
        std::fs::write(&canon_db, b"").unwrap();
        std::fs::write(&noncanon_db, b"").unwrap();
        std::fs::write(noncanon_dir.join("NONCANONICAL"), b"retired home store\n").unwrap();
        std::fs::write(&unmarked_db, b"").unwrap();

        // With 1 canonical, 1 NONCANONICAL, and 1 UNMARKED copy: must FAIL and name all three.
        let res = classify_node_gap_stores(Some(sb.path()), Some(&sb.path().join("chump")), None);
        assert_eq!(res.status, CheckStatus::Fail, "msg: {}", res.message);
        assert!(res.message.contains("canonical:"), "msg: {}", res.message);
        assert!(
            res.message.contains("non-canonical:") && res.message.contains("NONCANONICAL"),
            "msg: {}",
            res.message
        );
        assert!(
            res.message.contains("UNMARKED:")
                && res.message.contains(&unmarked_db.display().to_string()),
            "msg: {}",
            res.message
        );

        // Once the unmarked copy is marked NONCANONICAL (or CHUMP_STORE_ARCHIVED), check PASSes.
        std::fs::write(
            unmarked_dir.join("CHUMP_STORE_ARCHIVED"),
            b"CHUMP_STORE_ARCHIVED\n",
        )
        .unwrap();
        let res_ok =
            classify_node_gap_stores(Some(sb.path()), Some(&sb.path().join("chump")), None);
        assert_eq!(res_ok.status, CheckStatus::Pass, "msg: {}", res_ok.message);
        assert!(
            res_ok.message.contains("canonical:") && res_ok.message.contains("non-canonical:"),
            "msg: {}",
            res_ok.message
        );
    }

    #[test]
    #[serial]
    fn credible1568_deadman_liveness_fresh_vs_stale_and_env_override() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let now_unix = 1_760_000_600u64; // 2025-10-09T08:10:00Z

        // 1. Not active host -> Skip.
        let r_skip = check_load_aware_deadman_at(&amb, now_unix, false);
        assert_eq!(r_skip.status, CheckStatus::Skip);

        // 2. Active host, missing ambient.jsonl -> Fail.
        let r_missing = check_load_aware_deadman_at(&amb, now_unix, true);
        assert_eq!(r_missing.status, CheckStatus::Fail);

        // 3. Active host, exact boundary 300s (fresh <= 300s) -> Pass (kills `< 300` mutant).
        let ts_300 = chrono::DateTime::from_timestamp((now_unix - 300) as i64, 0)
            .unwrap()
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();
        std::fs::write(
            &amb,
            format!(r#"{{"ts":"{ts_300}","kind":"deadman_tick","load1":0.5}}"#) + "\n",
        )
        .unwrap();
        let r_300 = check_load_aware_deadman_at(&amb, now_unix, true);
        assert_eq!(
            r_300.status,
            CheckStatus::Pass,
            "300s is within <=300s threshold: {}",
            r_300.message
        );

        // 4. Active host, 301s old -> Fail (kills `<= 9999` mutant).
        let ts_301 = chrono::DateTime::from_timestamp((now_unix - 301) as i64, 0)
            .unwrap()
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();
        std::fs::write(
            &amb,
            format!(r#"{{"ts":"{ts_301}","kind":"deadman_tick","load1":0.5}}"#) + "\n",
        )
        .unwrap();
        let r_301 = check_load_aware_deadman_at(&amb, now_unix, true);
        assert_eq!(
            r_301.status,
            CheckStatus::Fail,
            "301s must fail <=300s threshold: {}",
            r_301.message
        );

        // 5. Env-wired check_load_aware_deadman() honors CHUMP_DOCTOR_CHECK_DEADMAN=1.
        let prev_force = std::env::var("CHUMP_DOCTOR_CHECK_DEADMAN").ok();
        let prev_amb = std::env::var("CHUMP_AMBIENT_LOG").ok();
        std::env::set_var("CHUMP_DOCTOR_CHECK_DEADMAN", "1");
        std::env::set_var("CHUMP_AMBIENT_LOG", &amb);
        let r_env_stale = check_load_aware_deadman();
        assert_eq!(r_env_stale.status, CheckStatus::Fail);

        match prev_force {
            Some(v) => std::env::set_var("CHUMP_DOCTOR_CHECK_DEADMAN", v),
            None => std::env::remove_var("CHUMP_DOCTOR_CHECK_DEADMAN"),
        }
        match prev_amb {
            Some(v) => std::env::set_var("CHUMP_AMBIENT_LOG", v),
            None => std::env::remove_var("CHUMP_AMBIENT_LOG"),
        }
    }
}
