//! `chump-curator-supervisor` — INFRA-2239
//!
//! L3 supervision daemon over the 6 productized curator roles.
//! On each StartInterval tick (default 300s), iterates all roles and runs
//! 4 detection checks. On novel failure: files a gap, optionally spawns a
//! Sonnet sub-agent, optionally auto-restarts the tmux pane.
//!
//! ## Detection checks
//!
//! 1. **error_pattern_scan** — regex match in last 50 log lines for known
//!    fatal patterns (`unknown subcommand`, `Traceback`, `panic`, `fatal:`,
//!    `exit 1`). Triggered when ≥ 2 matches found.
//! 2. **heartbeat state** (RESILIENT-246) — four-way, not boolean:
//!    `Fresh` / `Stalled` / `NeverSeen` / `Blind`. Accepts both the generic
//!    `curator_heartbeat` kind (stub roles) and each productized role's own
//!    `<role>_heartbeat` kind. Only `Stalled` is auto-remediated; a role that
//!    never started has no pane to respawn, and a scan that cannot cover the
//!    threshold window reports its blindness instead of guessing.
//! 3. **crash_loop_check** — last 100 log lines are ≥ 80% error-class lines.
//! 4. **productivity_drop_check** — zero state.db gap mutations attributed
//!    to the role's session_id in the past 1 hour.
//!
//! ## Env vars
//!
//! | Variable | Default | Purpose |
//! |---|---|---|
//! | `CHUMP_REPO_ROOT` | git rev-parse | Repository root |
//! | `CHUMP_CURATOR_SUPERVISOR_MODE` | `aggressive` | `aggressive` or `conservative` |
//! | `CHUMP_CURATOR_SUPERVISOR_AUTORESTART` | `1` | `0` to disable tmux respawn |
//! | `CHUMP_CURATOR_SUPERVISOR_DRY_RUN` | unset | `1` to emit would-* events instead of acting |
//! | `CHUMP_CURATOR_SUPERVISOR_INTERVAL_S` | `300` | Tick interval in seconds |
//! | `CHUMP_CURATOR_SUPERVISOR_LOG_DIR` | `.chump-locks/autopilot-logs` | Curator log directory |
//! | `CHUMP_CURATOR_SUPERVISOR_AMBIENT` | `.chump-locks/ambient.jsonl` | Ambient stream path |
//! | `CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR` | `.chump-locks/curator-supervisor/seen` | Dedup sentinel dir |
//! | `CHUMP_CURATOR_SUPERVISOR_SENTINEL_TTL_H` | `24` | Sentinel TTL in hours |
//! | `CHUMP_CURATOR_HEARTBEAT_STALL_M` | `10` | Minutes without heartbeat = stall |
//! | `CHUMP_CURATOR_SUPERVISOR_PRODUCTIVITY_H` | `1` | Hours window for productivity check |

use std::fs;
use std::io::{self, BufRead};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result};
use chrono::Utc;
use regex::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tracing::{debug, info, warn};

// ── constants ──────────────────────────────────────────────────────────────

/// The 6 productized curator roles (must match fleet-autopilot.sh CURATOR_ROLES).
/// Format: (role_name, loop_script_relative_to_repo)
const CURATOR_ROLES: &[(&str, &str)] = &[
    ("shepherd", "scripts/coord/opus-shepherd-triage.sh"),
    ("target", ""),
    ("handoff", "scripts/coord/handoff-loop.sh"),
    ("ci-audit", "scripts/coord/ci-audit-loop.sh"),
    ("decompose", "scripts/coord/decompose-loop.sh"),
    ("md-links", "scripts/coord/md-links-loop.sh"),
];

/// Error patterns that trigger detection (checked in last 50 log lines).
/// These are plain substring patterns matched with regex literal search,
/// NOT regex syntax — bracket chars are escaped when building the Regex.
const ERROR_PATTERNS: &[&str] = &[
    "unknown subcommand",
    "Traceback",
    "panic",
    "fatal:",
    "exit 1",
    "FAILED",
    "error[E",
];

const DEFAULT_INTERVAL_S: u64 = 300;
const DEFAULT_STALL_M: u64 = 10;
const DEFAULT_SENTINEL_TTL_H: u64 = 24;
const DEFAULT_PRODUCTIVITY_H: u64 = 1;
const CRASH_LOOP_ERROR_RATIO: f64 = 0.80;
const ERROR_PATTERN_MIN_MATCHES: usize = 2;
// RESILIENT-035 circuit breaker: cap how often a single role can fork into
// remediation. Without these, a flapping role produces N distinct error
// fingerprints over time and bypasses the sentinel dedup — the supervisor
// would spawn N Sonnets and respawn N times in a single hour.
const DEFAULT_MAX_SPAWNS_PER_HOUR: u64 = 3;
const DEFAULT_FLAPPING_DETECT_WINDOW_M: u64 = 30;
const DEFAULT_FLAPPING_DETECT_THRESHOLD: u64 = 3;
// RESILIENT-038: substrate (environmental) causes take out every curator at
// once — spawning six Sonnets won't fix a full disk. Cache the verdict so a
// tick with several failing curators doesn't hammer `gh api` / `df` / NATS /
// the auth probe once per curator.
const SUBSTRATE_CACHE_TTL_S: u64 = 300;
const DISK_FULL_PCT_THRESHOLD: u64 = 95;
const GH_RATE_LIMIT_LOW_WATERMARK: u64 = 50;

// ── config ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct Config {
    repo_root: PathBuf,
    log_dir: PathBuf,
    ambient_path: PathBuf,
    sentinel_dir: PathBuf,
    sentinel_ttl: Duration,
    stall_threshold: Duration,
    productivity_window: Duration,
    mode: SupervisorMode,
    autorestart: bool,
    dry_run: bool,
    interval: Duration,
    // RESILIENT-035 circuit breaker
    max_spawns_per_hour: u64,
    flapping_window: Duration,
    flapping_threshold: u64,
}

#[derive(Debug, Clone, PartialEq)]
enum SupervisorMode {
    Aggressive,
    Conservative,
}

impl Config {
    fn from_env() -> Result<Self> {
        let repo_root = resolve_repo_root();
        let log_dir = env_path(
            "CHUMP_CURATOR_SUPERVISOR_LOG_DIR",
            repo_root.join(".chump-locks/autopilot-logs"),
        );
        let ambient_path = env_path(
            "CHUMP_CURATOR_SUPERVISOR_AMBIENT",
            repo_root.join(".chump-locks/ambient.jsonl"),
        );
        let sentinel_dir = env_path(
            "CHUMP_CURATOR_SUPERVISOR_SENTINEL_DIR",
            repo_root.join(".chump-locks/curator-supervisor/seen"),
        );
        let sentinel_ttl_h: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_SENTINEL_TTL_H",
            DEFAULT_SENTINEL_TTL_H,
        );
        let stall_m: u64 = env_u64("CHUMP_CURATOR_HEARTBEAT_STALL_M", DEFAULT_STALL_M);
        let productivity_h: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_PRODUCTIVITY_H",
            DEFAULT_PRODUCTIVITY_H,
        );
        let interval_s: u64 = env_u64("CHUMP_CURATOR_SUPERVISOR_INTERVAL_S", DEFAULT_INTERVAL_S);

        let mode_str = std::env::var("CHUMP_CURATOR_SUPERVISOR_MODE")
            .unwrap_or_else(|_| "aggressive".to_string());
        let mode = if mode_str == "conservative" {
            SupervisorMode::Conservative
        } else {
            SupervisorMode::Aggressive
        };

        let autorestart = std::env::var("CHUMP_CURATOR_SUPERVISOR_AUTORESTART")
            .map(|v| v != "0" && v != "false")
            .unwrap_or(true);

        let dry_run = std::env::var("CHUMP_CURATOR_SUPERVISOR_DRY_RUN")
            .map(|v| v == "1" || v == "true")
            .unwrap_or(false);

        // RESILIENT-035 circuit breaker config.
        let max_spawns_per_hour: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_MAX_SPAWNS_PER_HOUR",
            DEFAULT_MAX_SPAWNS_PER_HOUR,
        );
        let flapping_window_m: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_FLAPPING_WINDOW_M",
            DEFAULT_FLAPPING_DETECT_WINDOW_M,
        );
        let flapping_threshold: u64 = env_u64(
            "CHUMP_CURATOR_SUPERVISOR_FLAPPING_THRESHOLD",
            DEFAULT_FLAPPING_DETECT_THRESHOLD,
        );

        Ok(Config {
            repo_root,
            log_dir,
            ambient_path,
            sentinel_dir,
            sentinel_ttl: Duration::from_secs(sentinel_ttl_h * 3600),
            stall_threshold: Duration::from_secs(stall_m * 60),
            productivity_window: Duration::from_secs(productivity_h * 3600),
            mode,
            autorestart,
            dry_run,
            interval: Duration::from_secs(interval_s),
            max_spawns_per_hour,
            flapping_window: Duration::from_secs(flapping_window_m * 60),
            flapping_threshold,
        })
    }
}

// ── detection results ──────────────────────────────────────────────────────

#[derive(Debug, Default)]
struct DetectionResult {
    role: String,
    error_pattern_triggered: bool,
    error_pattern_sample: Option<String>,
    heartbeat: HeartbeatState,
    crash_loop_triggered: bool,
    productivity_drop_triggered: bool,
}

impl DetectionResult {
    fn is_failing(&self) -> bool {
        self.error_pattern_triggered
            || self.heartbeat.is_failing()
            || self.crash_loop_triggered
            || self.productivity_drop_triggered
    }

    /// Whether auto-remediation (tmux respawn, Sonnet sub-agent) is coherent
    /// for this result. A role that never started has no pane to respawn, and
    /// an unobservable role must not be acted on at all — in both cases the
    /// honest move is to report and stop.
    fn is_remediable(&self) -> bool {
        if matches!(self.heartbeat, HeartbeatState::Blind { .. }) {
            return false;
        }
        self.error_pattern_triggered
            || self.crash_loop_triggered
            || self.productivity_drop_triggered
            || self.heartbeat.is_remediable()
    }

    fn failure_summary(&self) -> String {
        let mut parts = Vec::new();
        if self.error_pattern_triggered {
            if let Some(s) = &self.error_pattern_sample {
                parts.push(format!(
                    "error_pattern({})",
                    s.chars().take(60).collect::<String>()
                ));
            } else {
                parts.push("error_pattern".to_string());
            }
        }
        if self.heartbeat.is_failing() {
            parts.push(self.heartbeat.summary());
        }
        if self.crash_loop_triggered {
            parts.push("crash_loop".to_string());
        }
        if self.productivity_drop_triggered {
            parts.push("productivity_drop".to_string());
        }
        parts.join("; ")
    }

    fn error_fingerprint(&self) -> String {
        let fallback = self.failure_summary();
        let sample = self.error_pattern_sample.as_deref().unwrap_or(&fallback);
        let mut hasher = Sha256::new();
        hasher.update(sample.as_bytes());
        let hash = hex::encode(hasher.finalize());
        format!("{}:{}", self.role, &hash[..8])
    }
}

// ── main ───────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::from_env().context("Failed to build config from env")?;
    info!(
        mode = ?cfg.mode,
        autorestart = cfg.autorestart,
        dry_run = cfg.dry_run,
        interval_s = cfg.interval.as_secs(),
        "chump-curator-supervisor starting"
    );

    // Ensure sentinel directory exists.
    fs::create_dir_all(&cfg.sentinel_dir)
        .with_context(|| format!("create sentinel dir {:?}", cfg.sentinel_dir))?;

    // Single-shot mode: just run one tick and exit (for launchd StartInterval use).
    run_tick(&cfg).await?;

    Ok(())
}

// ── tick ───────────────────────────────────────────────────────────────────

async fn run_tick(cfg: &Config) -> Result<()> {
    info!(
        "supervisor tick starting — checking {} roles",
        CURATOR_ROLES.len()
    );

    // One pass over ambient for the whole tick, shared by all roles.
    let roles: Vec<&str> = CURATOR_ROLES.iter().map(|(r, _)| *r).collect();
    let scan = HeartbeatScan::collect(&cfg.ambient_path, &roles)?;

    // If the scan cannot see far enough back, it cannot speak to ANY role's
    // absence. Say so once, as a supervisor problem, and skip the heartbeat
    // verdicts for this tick — the other three checks still run. Fanning this
    // out into six curator gaps would file six false reports every time the
    // ambient log rotates.
    let blind_reason = scan.coverage_gap(cfg.stall_threshold);
    if let Some(why) = &blind_reason {
        warn!(
            why = %why,
            "HEARTBEAT CHECK BLIND — cannot distinguish a dead curator from an \
             unobservable one; reporting no heartbeat verdicts this tick"
        );
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                "kind": "curator_supervisor_blind",
                "check": "heartbeat",
                "why": why,
            }),
        );
    }

    let mut failures: Vec<DetectionResult> = Vec::new();
    let mut checked = 0usize;

    for (role, _loop_script) in CURATOR_ROLES {
        let result = check_role(cfg, role, &scan, blind_reason.is_some()).await;
        match result {
            Ok(det) => {
                checked += 1;
                if det.is_failing() {
                    warn!(role, summary = %det.failure_summary(), "curator failure detected");
                    failures.push(det);
                } else {
                    debug!(role, hb = %det.heartbeat.summary(), "healthy");
                }
            }
            Err(e) => {
                warn!(role, err = %e, "check_role returned error (skipping)");
            }
        }
    }

    if failures.is_empty() {
        // Only claim health for roles actually checked. If check_role errored
        // out for some, saying "all curators healthy" would repeat the very
        // mistake this file is about.
        if blind_reason.is_some() {
            // The log-based checks passed, but the heartbeat dimension was
            // never assessed. "All curators healthy" here is precisely the
            // sentence this fix exists to delete.
            warn!(
                "{checked} curators pass the log-based checks, but heartbeat state is \
                 UNKNOWN this tick — this is not a clean bill of health"
            );
        } else if checked == CURATOR_ROLES.len() {
            info!("all {checked} curators healthy");
        } else {
            warn!(
                "{checked}/{} curators verified healthy — {} could not be checked; \
                 the rest are UNKNOWN, not healthy",
                CURATOR_ROLES.len(),
                CURATOR_ROLES.len() - checked
            );
        }
        return Ok(());
    }

    // RESILIENT-038: triage substrate (environmental) causes BEFORE spawning
    // anything. disk-full / GH-rate-limited / NATS-down / auth-expired take
    // out every curator simultaneously — code changes to any one curator
    // won't help, so this must run before per-curator remediation, not after.
    if let Some(cause) = substrate_check(cfg) {
        report_substrate_outage(cfg, &cause, &failures).await?;
        return Ok(());
    }

    // RESILIENT-246: when EVERY role reports never-started, the fault is one
    // level up — fleet-autopilot never spawned them, or the tmux server is
    // gone. Six identical gaps and six respawn attempts would describe six
    // symptoms of one cause, and respawning a pane inside a tmux session that
    // does not exist is not remediation. Report it once, loudly, and stop.
    let all_never_started = failures.len() == CURATOR_ROLES.len()
        && failures
            .iter()
            .all(|d| matches!(d.heartbeat, HeartbeatState::NeverSeen));

    if all_never_started {
        report_fleet_wide_curator_outage(cfg, &failures).await?;
        return Ok(());
    }

    let multi_failure = failures.len() > 1;
    info!("{} curator(s) failing", failures.len());

    for det in &failures {
        handle_failure(cfg, det, multi_failure).await?;
    }

    Ok(())
}

/// Every curator is absent at once: file ONE gap against the launcher rather
/// than one per role, and take no automated remediation.
async fn report_fleet_wide_curator_outage(
    cfg: &Config,
    failures: &[DetectionResult],
) -> Result<()> {
    let roles: Vec<&str> = failures.iter().map(|d| d.role.as_str()).collect();
    warn!(
        roles = %roles.join(","),
        "ALL {} curators report never-started — treating as ONE launcher-level outage, \
         not {} independent failures; no auto-restart, no sub-agents",
        failures.len(),
        failures.len(),
    );

    let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        &cfg.ambient_path,
        &serde_json::json!({
            "ts": ts,
            "kind": "curator_fleet_outage",
            "roles": roles,
            "detail": "no heartbeat from any curator role across the covered window; \
                       suspect fleet-autopilot / tmux server, not the individual roles",
            "remediation": "none attempted — nothing to restart",
        }),
    );

    // Dedupe on a stable fingerprint so this pages once per TTL, not per tick.
    let fp = "curator-fleet:all-never-started".to_string();
    let sentinel_path = cfg
        .sentinel_dir
        .join(format!("{}.sentinel", fp.replace(':', "_")));
    if sentinel_path.exists() {
        if let Ok(meta) = fs::metadata(&sentinel_path) {
            if let Ok(modified) = meta.modified() {
                if let Ok(elapsed) = SystemTime::now().duration_since(modified) {
                    if elapsed < cfg.sentinel_ttl {
                        info!("fleet outage already paged within TTL — not re-filing");
                        return Ok(());
                    }
                }
            }
        }
    }

    if cfg.dry_run {
        info!("dry run — would file P0 fleet-wide curator outage gap");
        write_sentinel(&sentinel_path, &fp)?;
        return Ok(());
    }

    let det = DetectionResult {
        role: "ALL".to_string(),
        heartbeat: HeartbeatState::NeverSeen,
        ..Default::default()
    };
    match file_curator_gap(
        cfg,
        &det,
        "P0",
        &format!(
            "No heartbeat from any of the {} curator roles ({}).\n\
         Every role reports never-started, so this is one launcher-level outage.\n\
         Check: tmux has-session -t chump-curators; bash scripts/coord/fleet-autopilot.sh",
            failures.len(),
            roles.join(", "),
        ),
    ) {
        Ok(gap_id) => {
            info!(gap_id = %gap_id, "filed fleet-wide curator outage gap");
            write_sentinel(&sentinel_path, &fp)?;
        }
        Err(e) => warn!(err = %e, "could not file fleet outage gap"),
    }
    Ok(())
}

// ── per-role detection ─────────────────────────────────────────────────────

async fn check_role(
    cfg: &Config,
    role: &str,
    scan: &HeartbeatScan,
    blind: bool,
) -> Result<DetectionResult> {
    let mut det = DetectionResult {
        role: role.to_string(),
        ..Default::default()
    };

    let log_path = cfg.log_dir.join(format!("curator-{role}.log"));

    // 1. error_pattern_scan — last 50 log lines
    if log_path.exists() {
        let (triggered, sample) = error_pattern_scan(&log_path, 50, ERROR_PATTERN_MIN_MATCHES)?;
        det.error_pattern_triggered = triggered;
        det.error_pattern_sample = sample;
    }

    // 2. heartbeat state — fresh / stalled / never-seen / unobservable.
    //    When the tick is blind the verdict is Unassessed, NOT Fresh: writing
    //    "fresh(0s ago)" for a curator we never observed would be the same
    //    confident lie in a new coat.
    det.heartbeat = if blind {
        HeartbeatState::Unassessed
    } else {
        scan.state_for(role, cfg.stall_threshold)
    };

    // 3. crash_loop_check — last 100 log lines ≥ 80% error-class
    if log_path.exists() {
        det.crash_loop_triggered = crash_loop_check(&log_path, 100, CRASH_LOOP_ERROR_RATIO)?;
    }

    // 4. productivity_drop_check — no state.db mutations in last N hours
    let state_db = chump_store_path::state_db_path(&cfg.repo_root); // INFRA-8190
    if state_db.exists() {
        let session_id = infer_session_id(role);
        det.productivity_drop_triggered =
            productivity_drop_check(&state_db, &session_id, cfg.productivity_window)?;
    }

    Ok(det)
}

// ── detection primitives ───────────────────────────────────────────────────

fn error_pattern_scan(
    log_path: &Path,
    last_n_lines: usize,
    min_matches: usize,
) -> Result<(bool, Option<String>)> {
    let patterns: Vec<Regex> = ERROR_PATTERNS
        .iter()
        .map(|p| Regex::new(&regex::escape(p)).expect("valid escaped regex"))
        .collect();

    let lines = tail_lines(log_path, last_n_lines)?;
    let mut match_count = 0usize;
    let mut first_match: Option<String> = None;

    for line in &lines {
        for pat in &patterns {
            if pat.is_match(line) {
                match_count += 1;
                if first_match.is_none() {
                    first_match = Some(line.trim().to_string());
                }
                break;
            }
        }
    }

    Ok((match_count >= min_matches, first_match))
}

// ── heartbeat observation (RESILIENT-246) ──────────────────────────────────
//
// The original `silent_stall_check` collapsed three different situations into
// one `false`, i.e. "healthy":
//
//   1. a heartbeat was seen recently                     — genuinely healthy
//   2. no heartbeat has EVER been seen for this role     — the role is dead
//   3. the supervisor could not look (no ambient file,
//      or the window did not reach back far enough)      — unknown
//
// Only (1) is health. (2) and (3) are both forms of not-knowing, and the
// supervisor logged "all curators healthy" on every tick for the entire time
// the six curators were not running at all — zero heartbeat events of any
// naming exist across 30k retained ambient lines and three days of history.
//
// Absence of evidence is not evidence of health. Each case now has its own
// state, and each gets a different response.

/// What the supervisor was able to OBSERVE about one role's heartbeat.
#[derive(Debug, Clone, PartialEq)]
enum HeartbeatState {
    /// Heartbeat seen within the stall threshold.
    Fresh { ago: Duration },
    /// Heartbeat seen, but older than the threshold. It was alive and stopped:
    /// there is a real process to restart, so normal remediation applies.
    Stalled { ago: Duration },
    /// The scan demonstrably covered the threshold window and found no
    /// heartbeat for this role at all. The role never came up. A failure — but
    /// a different one from `Stalled`, because there is no live process to
    /// restart and the fault is usually upstream of the role itself.
    NeverSeen,
    /// The supervisor could not observe. Reported loudly, never remediated:
    /// you cannot restart what you cannot see, and guessing here is how a
    /// nightly log rotation turns into six false P0s.
    Blind { why: String },
    /// The tick reported its blindness once, at tick level, and skipped the
    /// per-role verdict. Not a failure — but explicitly NOT a claim of health
    /// either, so it can never be mistaken for `Fresh` in a log or a summary.
    Unassessed,
}

impl HeartbeatState {
    fn is_failing(&self) -> bool {
        !matches!(
            self,
            HeartbeatState::Fresh { .. } | HeartbeatState::Unassessed
        )
    }

    /// True only where restarting a pane or spawning a sub-agent is a coherent
    /// response. `NeverSeen` and `Blind` are deliberately excluded.
    fn is_remediable(&self) -> bool {
        matches!(self, HeartbeatState::Stalled { .. })
    }

    fn summary(&self) -> String {
        match self {
            HeartbeatState::Fresh { ago } => format!("fresh({}s ago)", ago.as_secs()),
            HeartbeatState::Stalled { ago } => {
                format!("silent_stall(last_heartbeat={}s ago)", ago.as_secs())
            }
            HeartbeatState::NeverSeen => {
                "never_started(no heartbeat of any kind in the covered window)".to_string()
            }
            HeartbeatState::Blind { why } => format!("heartbeat_unobservable({why})"),
            HeartbeatState::Unassessed => {
                "heartbeat_not_assessed(scan blind this tick)".to_string()
            }
        }
    }
}

impl Default for HeartbeatState {
    /// Blind, not Fresh. A result that was never populated must not read as
    /// healthy — that is the same mistake one level up.
    fn default() -> Self {
        HeartbeatState::Blind {
            why: "not checked".to_string(),
        }
    }
}

/// The ambient kind a given role actually emits.
///
/// This is the defect that kept the fail-open invisible: the supervisor watched
/// for `curator_heartbeat`, but the four productized curators each emit their
/// OWN kind — `handoff_heartbeat`, `ci_audit_heartbeat`, `decompose_heartbeat`,
/// `md_links_heartbeat` (see `_cmd_heartbeat` in `scripts/coord/*-loop.sh`).
/// Only the two stub roles (shepherd, target), which do no real work, emit the
/// generic kind from `fleet-autopilot.sh`. The detector was subscribed to a
/// channel no working curator has ever published to.
///
/// Fixing the fail-open WITHOUT fixing this would page all four productized
/// roles as dead on every tick, forever, while they were running perfectly.
fn heartbeat_kind_for(role: &str) -> String {
    format!("{}_heartbeat", role.replace('-', "_"))
}

/// Does this ambient event count as a heartbeat for `role`?
fn heartbeat_matches(v: &Value, role: &str) -> bool {
    let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
    if kind.is_empty() {
        return false;
    }
    // A role-specific kind is unambiguous on its own, so no role field is
    // required. decompose-loop.sh writes role="curator-opus-decompose", not
    // "decompose" — demanding an exact match here would drop its heartbeats.
    if kind == heartbeat_kind_for(role) {
        return true;
    }
    // The generic kind is shared across roles, so it must name its own.
    if kind == "curator_heartbeat" {
        let event_role = v.get("role").and_then(|r| r.as_str()).unwrap_or("");
        return event_role == role || event_role.contains(role);
    }
    false
}

/// One pass over the ambient stream, shared by every role in a tick.
struct HeartbeatScan {
    /// Newest heartbeat per role.
    latest: std::collections::HashMap<String, chrono::DateTime<Utc>>,
    /// Oldest parsable timestamp observed. This is the evidence of how far
    /// back the scan actually reached.
    oldest_seen: Option<chrono::DateTime<Utc>>,
    /// Set when the supervisor could not observe at all.
    blind: Option<String>,
}

impl HeartbeatScan {
    /// Read the ambient stream once and index heartbeats for every role.
    ///
    /// Reads the whole retained file rather than a fixed line count. The old
    /// 500-line window covered ~12 minutes at this fleet's measured 42
    /// lines/min, against a 10-minute threshold: a 1.2x margin. Any chattier
    /// and the window would be NARROWER than the threshold, so a perfectly
    /// healthy curator's heartbeat would scroll out of view and read as
    /// absent. A window that must be re-tuned whenever the fleet gets busier
    /// is not a check. Reading once per tick instead of once per role also
    /// cuts the I/O it replaces by 6x.
    fn collect(ambient_path: &Path, roles: &[&str]) -> Result<Self> {
        let mut scan = HeartbeatScan {
            latest: std::collections::HashMap::new(),
            oldest_seen: None,
            blind: None,
        };

        if !ambient_path.exists() {
            scan.blind = Some(format!(
                "ambient stream absent at {}",
                ambient_path.display()
            ));
            return Ok(scan);
        }

        let lines = match tail_lines(ambient_path, usize::MAX) {
            Ok(l) => l,
            Err(e) => {
                scan.blind = Some(format!("ambient stream unreadable: {e}"));
                return Ok(scan);
            }
        };

        for line in &lines {
            let Ok(v) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let Some(ts) = v
                .get("ts")
                .and_then(|t| t.as_str())
                .and_then(|s| s.parse::<chrono::DateTime<Utc>>().ok())
            else {
                continue;
            };
            // Coverage is tracked against every timestamped event, not just
            // heartbeats: any line proves the scan reached back that far.
            if scan.oldest_seen.map(|o| ts < o).unwrap_or(true) {
                scan.oldest_seen = Some(ts);
            }
            for role in roles {
                if heartbeat_matches(&v, role) {
                    let slot = scan.latest.entry((*role).to_string()).or_insert(ts);
                    if ts > *slot {
                        *slot = ts;
                    }
                }
            }
        }

        if scan.oldest_seen.is_none() {
            scan.blind = Some("ambient stream has no parsable timestamps".to_string());
        }
        Ok(scan)
    }

    /// Can this scan support a claim about ANY role's absence?
    ///
    /// Coverage is a property of the scan, not of a role: same file, same
    /// cutoff. So a blind scan is one supervisor-level problem, not six
    /// curator-level ones, and must be reported once rather than fanned out
    /// into a gap per role on every nightly rotation.
    fn coverage_gap(&self, threshold: Duration) -> Option<String> {
        if let Some(why) = &self.blind {
            return Some(why.clone());
        }
        let now = Utc::now();
        let cutoff = now - chrono::Duration::from_std(threshold).unwrap_or_default();
        match self.oldest_seen {
            Some(oldest) if oldest > cutoff => Some(format!(
                "retained ambient covers only {}s of the {}s threshold (rotated recently?)",
                (now - oldest).num_seconds().max(0),
                threshold.as_secs()
            )),
            Some(_) => None,
            None => Some("no timestamps in ambient stream".to_string()),
        }
    }

    /// Classify one role against the stall threshold.
    fn state_for(&self, role: &str, threshold: Duration) -> HeartbeatState {
        if let Some(why) = &self.blind {
            return HeartbeatState::Blind { why: why.clone() };
        }
        let now = Utc::now();

        if let Some(ts) = self.latest.get(role) {
            let ago = (now - *ts).to_std().unwrap_or(Duration::from_secs(0));
            return if ago > threshold {
                HeartbeatState::Stalled { ago }
            } else {
                HeartbeatState::Fresh { ago }
            };
        }

        // Nothing found. Before calling the role dead, prove the scan actually
        // looked across the whole threshold window. ambient.jsonl rotates
        // nightly; right after a rotation the retained file can be seconds
        // old, and "no heartbeat in the last 5 seconds" is not evidence that a
        // curator died. Without this guard every rotation pages all six roles.
        let cutoff = now - chrono::Duration::from_std(threshold).unwrap_or_default();
        match self.oldest_seen {
            Some(oldest) if oldest <= cutoff => HeartbeatState::NeverSeen,
            Some(oldest) => {
                let covered = (now - oldest).num_seconds().max(0);
                HeartbeatState::Blind {
                    why: format!(
                        "retained ambient covers only {}s of the {}s threshold \
                         (rotated recently?) — absence is not yet evidence",
                        covered,
                        threshold.as_secs()
                    ),
                }
            }
            None => HeartbeatState::Blind {
                why: "no timestamps in ambient stream".to_string(),
            },
        }
    }
}

fn crash_loop_check(log_path: &Path, last_n_lines: usize, ratio_threshold: f64) -> Result<bool> {
    let error_re =
        Regex::new(r"(?i)(error|panic|traceback|fatal|failed|unknown subcommand|exit [^0])")
            .expect("valid static regex");

    let lines = tail_lines(log_path, last_n_lines)?;
    if lines.is_empty() {
        return Ok(false);
    }

    let error_count = lines.iter().filter(|l| error_re.is_match(l)).count();
    Ok(error_count as f64 / lines.len() as f64 >= ratio_threshold)
}

fn productivity_drop_check(state_db: &Path, session_id: &str, window: Duration) -> Result<bool> {
    let conn = rusqlite::Connection::open(state_db)
        .with_context(|| format!("open state.db at {:?}", state_db))?;

    // Check if a gap_history table exists (gracefully skip if not).
    let has_table: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='gap_history'",
            [],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0)
        > 0;

    if !has_table {
        // No history table yet — skip this check.
        return Ok(false);
    }

    let cutoff = chrono::Utc::now() - chrono::Duration::from_std(window).unwrap();
    let cutoff_str = cutoff.format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM gap_history WHERE session_id = ?1 AND created_at >= ?2",
            rusqlite::params![session_id, cutoff_str],
            |r| r.get(0),
        )
        .unwrap_or(0);

    Ok(count == 0)
}

// ── failure handling ───────────────────────────────────────────────────────

async fn handle_failure(cfg: &Config, det: &DetectionResult, multi_failure: bool) -> Result<()> {
    let fp = det.error_fingerprint();
    let sentinel_path = cfg.sentinel_dir.join(format!("{}.sentinel", fp));

    // Dedupe: check sentinel TTL.
    if sentinel_path.exists() {
        if let Ok(meta) = fs::metadata(&sentinel_path) {
            if let Ok(modified) = meta.modified() {
                if let Ok(elapsed) = SystemTime::now().duration_since(modified) {
                    if elapsed < cfg.sentinel_ttl {
                        info!(
                            role = %det.role,
                            fingerprint = %fp,
                            "sentinel dedup active — skipping re-filing"
                        );
                        return Ok(());
                    }
                }
            }
        }
    }

    // RESILIENT-040: anti-race check #1 — has someone ALREADY filed a gap for
    // this fingerprint? If so, don't file a duplicate AND don't spawn a
    // racing Sonnet against it. Counts as a circuit-breaker activation so
    // a flapping role still trips RESILIENT-035 even when remediation is
    // a no-op.
    if !cfg.dry_run {
        if let Some(existing_gap) = find_open_gap_with_fingerprint(cfg, &fp)? {
            let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
            emit_ambient(
                &cfg.ambient_path,
                &serde_json::json!({
                    "ts": ts,
                    "kind": "curator_supervisor_gap_already_filed",
                    "role": det.role,
                    "fingerprint": fp,
                    "existing_gap_id": existing_gap,
                }),
            );
            info!(
                role = %det.role,
                fingerprint = %fp,
                existing_gap_id = %existing_gap,
                "RESILIENT-040: gap with this fingerprint already filed — skipping"
            );
            // Write sentinel + count as activation to feed circuit breaker.
            write_sentinel(&sentinel_path, &fp)?;
            record_spawn_activation(cfg, det)?;
            return Ok(());
        }
    }

    let priority = if multi_failure { "P0" } else { "P1" };
    let log_tail = get_log_tail(cfg, &det.role, 20);
    let summary = det.failure_summary();

    info!(
        role = %det.role,
        priority,
        fingerprint = %fp,
        "filing gap for curator failure"
    );

    // File the gap (or emit would-file-gap in dry_run).
    let gap_id_for_sonnet: String = if cfg.dry_run {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_dry_run",
                "action": "would-file-gap",
                "role": det.role,
                "priority": priority,
                "fingerprint": fp,
                "summary": summary,
            }),
        );
        // Still write the sentinel so dedupe works in dry-run.
        write_sentinel(&sentinel_path, &fp)?;
        format!("DRY-RUN-{}", fp)
    } else {
        let gap_id = file_curator_gap(cfg, det, priority, &log_tail)?;
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                "kind": "curator_failure_paged",
                "role": det.role,
                "gap_id": gap_id,
                "priority": priority,
                "fingerprint": fp,
                "summary": summary,
            }),
        );
        info!(role = %det.role, gap_id = %gap_id, "curator_failure_paged emitted");
        write_sentinel(&sentinel_path, &fp)?;
        gap_id
    };

    // RESILIENT-035 circuit breaker: cap per-role remediation rate so a
    // flapping role doesn't fork-bomb. Counts recent activation sentinels.
    if circuit_breaker_tripped(cfg, det)? {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_circuit_broken",
                "role": det.role,
                "max_spawns_per_hour": cfg.max_spawns_per_hour,
                "flapping_window_m": cfg.flapping_window.as_secs() / 60,
                "flapping_threshold": cfg.flapping_threshold,
                "gap_id": gap_id_for_sonnet,
            }),
        );
        warn!(
            role = %det.role,
            max = cfg.max_spawns_per_hour,
            "RESILIENT-035 circuit broken — halting auto-remediation for this role; operator review required"
        );
        // Broadcast a WARN to operator so we don't silently halt.
        let broadcast_path = cfg.repo_root.join("scripts/coord/broadcast.sh");
        if broadcast_path.exists() && !cfg.dry_run {
            let msg = format!(
                "RESILIENT-035 circuit broken: curator-supervisor halted auto-remediation for role={} after {} spawns in 1h OR {} detections in {}m. Operator review required (gap={}).",
                det.role,
                cfg.max_spawns_per_hour,
                cfg.flapping_threshold,
                cfg.flapping_window.as_secs() / 60,
                gap_id_for_sonnet,
            );
            let _ = tokio::process::Command::new(&broadcast_path)
                .args(["WARN", &msg])
                .output()
                .await;
        }
        return Ok(());
    }

    // RESILIENT-040: anti-race check #2 — does the gap we're about to act on
    // already have an active claim by another session? If so, another worker
    // is already on it; spawning a parallel Sonnet creates a claim collision.
    let claim_collision = !cfg.dry_run && gap_already_claimed(cfg, &gap_id_for_sonnet)?;
    if claim_collision {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_spawn_skipped_claim_collision",
                "role": det.role,
                "gap_id": gap_id_for_sonnet,
            }),
        );
        info!(
            role = %det.role,
            gap_id = %gap_id_for_sonnet,
            "RESILIENT-040: gap already claimed elsewhere — skipping spawn"
        );
        // Count as activation so flapping still trips the breaker.
        record_spawn_activation(cfg, det)?;
        // Still allow autorestart — the claim collision is about gap work,
        // not about the curator process itself.
        if cfg.autorestart {
            autorestart_curator(cfg, det).await?;
            record_spawn_activation(cfg, det)?;
        }
        return Ok(());
    }

    // RESILIENT-246: the gap is filed either way, but automated remediation
    // only runs where it is coherent. A role that never started has no pane to
    // respawn, and a role we could not observe must not be acted on at all —
    // acting on an unknown is how a detector bug becomes a fleet incident.
    if !det.is_remediable() {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_remediation_withheld",
                "role": det.role,
                "gap_id": gap_id_for_sonnet,
                "heartbeat": det.heartbeat.summary(),
                "why": "state is not remediable — reported, not acted on",
            }),
        );
        info!(
            role = %det.role,
            hb = %det.heartbeat.summary(),
            "reported without remediation — nothing coherent to restart"
        );
        return Ok(());
    }

    // Aggressive mode: spawn Sonnet sub-agent (spawn_sonnet handles dry_run internally).
    if cfg.mode == SupervisorMode::Aggressive {
        spawn_sonnet(cfg, det, &gap_id_for_sonnet, &log_tail).await?;
        record_spawn_activation(cfg, det)?;
    }

    // Auto-restart: respawn tmux pane.
    if cfg.autorestart {
        autorestart_curator(cfg, det).await?;
        record_spawn_activation(cfg, det)?;
    }

    Ok(())
}

// ── RESILIENT-040 anti-race helpers ───────────────────────────────────────────

/// Check whether any `.chump-locks/claim-<gap-lower>-*.json` files exist for
/// the given gap_id. Existence alone counts as a claim (the supervisor itself
/// doesn't hold gap claims, so any present file is another session's work).
fn gap_already_claimed(cfg: &Config, gap_id: &str) -> Result<bool> {
    if gap_id.is_empty() {
        return Ok(false);
    }
    let lock_dir = cfg
        .ambient_path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".chump-locks"));
    let prefix = format!("claim-{}-", gap_id.to_lowercase());
    let read = match fs::read_dir(&lock_dir) {
        Ok(r) => r,
        Err(_) => return Ok(false),
    };
    for entry in read.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with(&prefix) && name_str.ends_with(".json") {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Grep `chump gap list --status open --json` for an open gap whose
/// description / notes contain the given fingerprint substring. Returns the
/// gap_id of the FIRST match (lexical order), or None if no open gap matches.
/// Best-effort: shells out to `chump`; returns None silently on any failure
/// so the supervisor degrades to "no match" rather than crashing.
fn find_open_gap_with_fingerprint(cfg: &Config, fingerprint: &str) -> Result<Option<String>> {
    let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
    let output = std::process::Command::new(&chump_bin)
        .args(["gap", "list", "--status", "open", "--json"])
        .current_dir(&cfg.repo_root)
        .output();
    let bytes = match output {
        Ok(o) if o.status.success() => o.stdout,
        _ => return Ok(None),
    };
    let v: serde_json::Value = match serde_json::from_slice(&bytes) {
        Ok(v) => v,
        Err(_) => return Ok(None),
    };
    let arr = match v.as_array() {
        Some(a) => a,
        None => return Ok(None),
    };
    for g in arr {
        let id = g
            .get("id")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let desc = g.get("description").and_then(|x| x.as_str()).unwrap_or("");
        let notes = g.get("notes").and_then(|x| x.as_str()).unwrap_or("");
        let title = g.get("title").and_then(|x| x.as_str()).unwrap_or("");
        if desc.contains(fingerprint) || notes.contains(fingerprint) || title.contains(fingerprint)
        {
            return Ok(Some(id));
        }
    }
    Ok(None)
}

// ── RESILIENT-035 circuit breaker ─────────────────────────────────────────────

/// Per-role activation sentinel path. Tracks supervisor remediation actions
/// (Sonnet spawns + tmux respawns) so we can rate-cap them.
fn activation_sentinel_dir(cfg: &Config, role: &str) -> PathBuf {
    cfg.sentinel_dir
        .parent()
        .unwrap_or(&cfg.sentinel_dir)
        .join("activations")
        .join(role)
}

/// Append one activation marker for this role with current mtime. Each marker
/// is a separate file so we can count by listing the directory (no concurrent
/// write contention — supervisor is single-process).
fn record_spawn_activation(cfg: &Config, det: &DetectionResult) -> Result<()> {
    let dir = activation_sentinel_dir(cfg, &det.role);
    fs::create_dir_all(&dir).context("create activation sentinel dir")?;
    let ts_ms = Utc::now().timestamp_millis();
    let path = dir.join(format!("{ts_ms}.act"));
    fs::write(&path, det.error_fingerprint()).context("write activation sentinel")?;
    Ok(())
}

/// True if the circuit breaker should halt further remediation for this role.
///
/// Two independent triggers (whichever fires first):
/// 1. `>= max_spawns_per_hour` activations in the last 60 minutes.
/// 2. `>= flapping_threshold` detections (regardless of fingerprint) in the
///    last `flapping_window` minutes.
fn circuit_breaker_tripped(cfg: &Config, det: &DetectionResult) -> Result<bool> {
    let dir = activation_sentinel_dir(cfg, &det.role);
    if !dir.exists() {
        return Ok(false);
    }
    let now = SystemTime::now();
    let one_hour = Duration::from_secs(3600);
    let mut count_1h: u64 = 0;
    let mut count_window: u64 = 0;
    for entry in fs::read_dir(&dir).context("read activation sentinel dir")? {
        let Ok(entry) = entry else { continue };
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(mtime) = meta.modified() else { continue };
        let Ok(age) = now.duration_since(mtime) else {
            continue;
        };
        if age <= one_hour {
            count_1h += 1;
        }
        if age <= cfg.flapping_window {
            count_window += 1;
        }
    }
    Ok(count_1h >= cfg.max_spawns_per_hour || count_window >= cfg.flapping_threshold)
}

// ── RESILIENT-038: substrate-vs-code triage ───────────────────────────────
//
// The detection checks above answer "is curator X failing?" but not "why".
// A full disk, an exhausted GH rate limit, an unreachable NATS broker, or an
// expired OAuth token each fail every curator at the same moment — spawning
// six Sonnets to "fix" six curators whose code was never the problem is pure
// waste, and it buries the one gap that actually matters (the substrate
// condition) under six that don't.

/// One substrate-level cause the pre-flight can detect. `kind` is a short,
/// stable identifier (used in the gap title + dedup fingerprint); `detail`
/// is the human-readable evidence for the gap body / WARN broadcast.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
struct SubstrateCause {
    kind: String,
    detail: String,
}

/// On-disk cache entry (AC3: avoid hammering `df`/`gh api`/NATS/auth-status
/// once per failing curator in the same tick, and across ticks within the
/// TTL). The supervisor is single-shot per launchd invocation, so the cache
/// must survive on disk, not just in-process.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct SubstrateCacheEntry {
    checked_at_ms: i64,
    cause: Option<SubstrateCause>,
}

fn substrate_cache_path(cfg: &Config) -> PathBuf {
    cfg.sentinel_dir
        .parent()
        .unwrap_or(&cfg.sentinel_dir)
        .join("substrate-check-cache.json")
}

/// AC1: query disk / GH rate limit / NATS / auth health BEFORE any spawn
/// decision is made. Returns the first substrate cause found, or `None` if
/// the environment looks healthy (in which case the failures are presumed
/// to be curator-code issues, handled by the existing per-role path).
fn substrate_check(cfg: &Config) -> Option<SubstrateCause> {
    let cache_path = substrate_cache_path(cfg);
    if let Ok(raw) = fs::read_to_string(&cache_path) {
        if let Ok(entry) = serde_json::from_str::<SubstrateCacheEntry>(&raw) {
            let now_ms = Utc::now().timestamp_millis();
            let age_s = (now_ms.saturating_sub(entry.checked_at_ms)).max(0) / 1000;
            if (age_s as u64) < SUBSTRATE_CACHE_TTL_S {
                debug!(age_s, cached = ?entry.cause, "substrate_check: using cached verdict");
                return entry.cause;
            }
        }
    }

    let cause = substrate_check_uncached(cfg);
    let entry = SubstrateCacheEntry {
        checked_at_ms: Utc::now().timestamp_millis(),
        cause: cause.clone(),
    };
    if let Ok(json) = serde_json::to_string(&entry) {
        if let Some(parent) = cache_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(&cache_path, json);
    }
    cause
}

/// Run the four probes in order, returning the first cause found. Each probe
/// degrades to `None` on any tooling failure (missing binary, unparseable
/// output) rather than treating "could not check" as "substrate is broken" —
/// that would be the same fail-closed-on-a-guess mistake RESILIENT-246 fixed
/// for heartbeats.
fn substrate_check_uncached(cfg: &Config) -> Option<SubstrateCause> {
    check_disk(cfg)
        .or_else(|| check_gh_rate_limit(cfg))
        .or_else(|| check_nats(cfg))
        .or_else(|| check_auth(cfg))
}

/// `df` on the repo filesystem. `>= DISK_FULL_PCT_THRESHOLD`% used → disk_full.
fn check_disk(cfg: &Config) -> Option<SubstrateCause> {
    let out = std::process::Command::new("df")
        .args(["-Pk", &cfg.repo_root.display().to_string()])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let pct = parse_df_capacity_pct(&text)?;
    if pct >= DISK_FULL_PCT_THRESHOLD {
        Some(SubstrateCause {
            kind: "disk_full".to_string(),
            detail: format!(
                "df reports {pct}% used at {} (threshold {DISK_FULL_PCT_THRESHOLD}%)",
                cfg.repo_root.display()
            ),
        })
    } else {
        None
    }
}

/// Extract the Capacity% column from `df -P` output. Split out from
/// `check_disk` so a mocked disk-full state can be tested without shelling
/// out to a real `df` (RESILIENT-038 AC4).
fn parse_df_capacity_pct(df_output: &str) -> Option<u64> {
    // POSIX `df -P`: header line + one data line; last line is the one we want
    // even if the mount path wrapped the filesystem name onto its own line.
    let last_line = df_output.lines().last()?;
    let fields: Vec<&str> = last_line.split_whitespace().collect();
    let capacity_field = fields.get(4)?;
    capacity_field.trim_end_matches('%').parse().ok()
}

/// `gh api rate_limit` — low remaining core budget means every curator's
/// `gh` calls are about to start failing, not that any one curator is broken.
fn check_gh_rate_limit(cfg: &Config) -> Option<SubstrateCause> {
    let out = std::process::Command::new("gh")
        .args(["api", "rate_limit"])
        .current_dir(&cfg.repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v: Value = serde_json::from_slice(&out.stdout).ok()?;
    let remaining = v
        .get("resources")?
        .get("core")?
        .get("remaining")?
        .as_u64()?;
    if remaining < GH_RATE_LIMIT_LOW_WATERMARK {
        Some(SubstrateCause {
            kind: "gh_rate_limited".to_string(),
            detail: format!(
                "gh api rate_limit: {remaining} core requests remaining (watermark {GH_RATE_LIMIT_LOW_WATERMARK})"
            ),
        })
    } else {
        None
    }
}

/// `chump-coord ping`. Only checked when NATS is actually configured — the
/// offline-fallback path (docs/process/SCHEDULING_LAYERS.md; the FLEET-034
/// push tier) makes an unconfigured NATS an expected, non-substrate state.
fn check_nats(cfg: &Config) -> Option<SubstrateCause> {
    if std::env::var("CHUMP_NATS_URL")
        .unwrap_or_default()
        .is_empty()
    {
        return None;
    }
    let out = std::process::Command::new("chump-coord")
        .arg("ping")
        .current_dir(&cfg.repo_root)
        .output()
        .ok()?;
    if out.status.success() {
        None
    } else {
        Some(SubstrateCause {
            kind: "nats_down".to_string(),
            detail: format!(
                "chump-coord ping failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        })
    }
}

/// `scripts/coord/auth-status.sh --quiet` (RESILIENT-086) — the canonical
/// VALIDITY probe. A non-zero exit means no curator can transact regardless
/// of what its own code does.
fn check_auth(cfg: &Config) -> Option<SubstrateCause> {
    let script = cfg.repo_root.join("scripts/coord/auth-status.sh");
    if !script.exists() {
        return None;
    }
    let out = std::process::Command::new("bash")
        .args([script.to_string_lossy().as_ref(), "--quiet"])
        .current_dir(&cfg.repo_root)
        .output()
        .ok()?;
    if out.status.success() {
        None
    } else {
        Some(SubstrateCause {
            kind: "auth_unhealthy".to_string(),
            detail: String::from_utf8_lossy(&out.stdout).trim().to_string(),
        })
    }
}

/// AC2: file ONE gap for the substrate cause (not one per failing curator),
/// broadcast a WARN, and do NOT spawn any per-curator Sonnet sub-agents.
async fn report_substrate_outage(
    cfg: &Config,
    cause: &SubstrateCause,
    failures: &[DetectionResult],
) -> Result<()> {
    let roles: Vec<&str> = failures.iter().map(|d| d.role.as_str()).collect();
    warn!(
        kind = %cause.kind,
        detail = %cause.detail,
        roles = %roles.join(","),
        "RESILIENT-038: substrate cause detected — filing ONE gap, zero Sonnet spawns"
    );

    emit_ambient(
        &cfg.ambient_path,
        &serde_json::json!({
            "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            "kind": "curator_substrate_outage",
            "substrate_kind": cause.kind,
            "detail": cause.detail,
            "roles": roles,
            "remediation": "none attempted — environmental cause, not curator code",
        }),
    );

    // Dedupe on the substrate kind so a still-full disk doesn't refile every
    // tick — mirrors the fleet-wide-outage sentinel above.
    let fp = format!("substrate:{}", cause.kind);
    let sentinel_path = cfg
        .sentinel_dir
        .join(format!("{}.sentinel", fp.replace(':', "_")));
    if sentinel_path.exists() {
        if let Ok(meta) = fs::metadata(&sentinel_path) {
            if let Ok(modified) = meta.modified() {
                if let Ok(elapsed) = SystemTime::now().duration_since(modified) {
                    if elapsed < cfg.sentinel_ttl {
                        info!("substrate outage already paged within TTL — not re-filing");
                        return Ok(());
                    }
                }
            }
        }
    }

    if cfg.dry_run {
        info!("dry run — would file substrate outage gap + broadcast WARN");
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                "kind": "curator_supervisor_dry_run",
                "action": "would-file-substrate-gap",
                "substrate_kind": cause.kind,
                "roles": roles,
            }),
        );
        write_sentinel(&sentinel_path, &fp)?;
        return Ok(());
    }

    let title = format!("substrate: {} impacting curators", cause.kind);
    let description = format!(
        "Auto-filed by chump-curator-supervisor substrate_check() (RESILIENT-038) at {}.\n\
         Substrate cause: {}\n\
         Detail: {}\n\
         Affected curators: {}\n\n\
         This is an ENVIRONMENTAL cause, not a curator code defect — no per-curator \
         gap or Sonnet sub-agent was spawned for this failure cluster.",
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
        cause.kind,
        cause.detail,
        roles.join(", "),
    );
    let ac = format!(
        "Resolve the substrate condition ({}) so curators can run again. \
         Verify via a fresh substrate_check() pass returning healthy and curator \
         heartbeats resuming in ambient.jsonl.",
        cause.kind
    );

    let gap_id = match file_gap(cfg, &title, "P0", &description, &ac) {
        Ok(id) => id,
        Err(e) => {
            warn!(err = %e, "RESILIENT-038: could not file substrate outage gap");
            return Ok(());
        }
    };
    write_sentinel(&sentinel_path, &fp)?;

    let broadcast_path = cfg.repo_root.join("scripts/coord/broadcast.sh");
    if broadcast_path.exists() {
        let msg = format!(
            "RESILIENT-038: substrate cause impacting curators ({}): {}. Gap {} filed. \
             No per-curator Sonnets spawned — fix the substrate condition, not curator code.",
            cause.kind, cause.detail, gap_id,
        );
        let _ = tokio::process::Command::new("bash")
            .arg(&broadcast_path)
            .args(["WARN", &msg])
            .current_dir(&cfg.repo_root)
            .output()
            .await;
    }

    Ok(())
}

fn file_curator_gap(
    cfg: &Config,
    det: &DetectionResult,
    priority: &str,
    log_tail: &str,
) -> Result<String> {
    let role = &det.role;
    let summary = det.failure_summary();
    let title = format!("RESILIENT: curator-{role} auto-filed — detected: {summary}");
    let description = format!(
        "Auto-filed by chump-curator-supervisor (INFRA-2239) at {}.\n\
         Role: {role}\n\
         Failure: {summary}\n\n\
         Last 20 log lines:\n```\n{log_tail}\n```",
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
    );

    let ac = "Fix curator-{role} so it completes a full tick without error. \
         Verify via heartbeat in ambient.jsonl and clean log output."
        .replace("{role}", role);

    file_gap(cfg, &title, priority, &description, &ac)
}

/// `chump gap reserve` + `chump gap set` for a single auto-filed gap. Shared
/// by both the per-curator path (`file_curator_gap`) and the RESILIENT-038
/// substrate-outage path so the two only file gaps through one code path.
fn file_gap(
    cfg: &Config,
    title: &str,
    priority: &str,
    description: &str,
    ac: &str,
) -> Result<String> {
    // chump gap reserve
    let reserve_out = std::process::Command::new("chump")
        .args([
            "gap",
            "reserve",
            "--domain",
            "INFRA",
            "--title",
            title,
            "--priority",
            priority,
            "--effort",
            "s",
            "--json",
        ])
        .current_dir(&cfg.repo_root)
        .output()
        .context("chump gap reserve")?;

    if !reserve_out.status.success() {
        let stderr = String::from_utf8_lossy(&reserve_out.stderr);
        anyhow::bail!("chump gap reserve failed: {stderr}");
    }

    let reserve_json: Value =
        serde_json::from_slice(&reserve_out.stdout).context("parse gap reserve output")?;
    let gap_id = reserve_json
        .get("id")
        .or_else(|| reserve_json.get("gap_id"))
        .and_then(|v| v.as_str())
        .unwrap_or("INFRA-NEW")
        .to_string();

    // chump gap set description + AC
    let _ = std::process::Command::new("chump")
        .args([
            "gap",
            "set",
            &gap_id,
            "--description",
            description,
            "--acceptance-criteria",
            ac,
        ])
        .current_dir(&cfg.repo_root)
        .output();

    info!(title, gap_id = %gap_id, "gap filed");
    Ok(gap_id)
}

async fn spawn_sonnet(
    cfg: &Config,
    det: &DetectionResult,
    gap_id: &str,
    log_tail: &str,
) -> Result<()> {
    if cfg.dry_run {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_dry_run",
                "action": "would-spawn-sonnet",
                "role": det.role,
                "gap_id": gap_id,
            }),
        );
        return Ok(());
    }

    // Build the subagent prompt with SUBAGENT_DISPATCH.md contract preamble.
    let dispatch_md_path = cfg.repo_root.join("docs/process/SUBAGENT_DISPATCH.md");
    let dispatch_preamble = fs::read_to_string(&dispatch_md_path).unwrap_or_else(|_| {
        "# SUBAGENT_DISPATCH execution contract\n(see docs/process/SUBAGENT_DISPATCH.md)\n"
            .to_string()
    });

    let prompt = format!(
        "{dispatch_preamble}\n\n\
         ---\n\
         ## Your task\n\
         Gap: {gap_id}\n\
         Role: {role}\n\
         Failure: {summary}\n\n\
         Last 20 log lines from curator-{role}.log:\n```\n{log_tail}\n```\n\n\
         Fix the curator so it completes a full tick without error. \
         Claim gap {gap_id}, implement the fix, run preflight, ship.\n\
         No clarifying questions — make decisions and ship.\n",
        dispatch_preamble = dispatch_preamble,
        gap_id = gap_id,
        role = det.role,
        summary = det.failure_summary(),
        log_tail = log_tail,
    );

    info!(
        role = %det.role,
        gap_id,
        "spawning Sonnet sub-agent (fire-and-forget)"
    );

    // CREDIBLE-359: structured telemetry for every Agent-tool dispatch, so
    // the fleet-wide opus-vs-sonnet delegation ratio (META-069) is auditable
    // from ambient.jsonl instead of inferred from log-scraping.
    emit_ambient(
        &cfg.ambient_path,
        &serde_json::json!({
            "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            "kind": "sub_agent_dispatched",
            "role": det.role,
            "gap_id": gap_id,
            "model": "sonnet",
            "delegated": true,
        }),
    );

    // Fire-and-forget: spawn claude -p in background so supervisor tick
    // doesn't block on LLM latency. Background process inherits ambient.
    tokio::spawn(async move {
        let status = tokio::process::Command::new("claude")
            .args(["-p", "--model", "claude-sonnet-4-5", &prompt])
            .status()
            .await;
        match status {
            Ok(s) => info!(exit_code = s.code(), "Sonnet sub-agent exited"),
            Err(e) => warn!(err = %e, "Sonnet sub-agent spawn error"),
        }
    });

    Ok(())
}

async fn autorestart_curator(cfg: &Config, det: &DetectionResult) -> Result<()> {
    let role = &det.role;
    let tmux_session = std::env::var("CHUMP_CURATOR_TMUX_SESSION")
        .unwrap_or_else(|_| "chump-curators".to_string());

    // Build the respawn command: matches fleet-autopilot.sh curator_loop_cmd() format.
    let loop_script = find_loop_script(role);
    let log_file = cfg.log_dir.join(format!("curator-{role}.log"));
    let date_str = Utc::now().format("%Y-%m-%d").to_string();
    let session_id = format!("curator-opus-{role}-{date_str}");
    let tick_interval =
        std::env::var("CHUMP_CURATOR_TICK_INTERVAL_S").unwrap_or_else(|_| "300".to_string());
    let repo = cfg.repo_root.display();
    let log = log_file.display();

    let inner_cmd = if !loop_script.is_empty() {
        let script_path = cfg.repo_root.join(loop_script);
        format!(
            "export CHUMP_SESSION_ID={session_id} REPO_ROOT={repo}; \
             while true; do {script} tick 2>&1 | tee -a {log}; \
             {script} heartbeat 2>>{log}; sleep {tick_interval}; done",
            script = script_path.display(),
        )
    } else {
        // Stub role (no loop script): minimal heartbeat loop.
        format!(
            "export CHUMP_SESSION_ID={session_id} REPO_ROOT={repo} \
             AMBIENT={ambient} CURATOR_ROLE={role} LOG_FILE={log} INTERVAL={tick_interval}; \
             while true; do ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); \
             printf '{{\"ts\":\"%s\",\"kind\":\"curator_heartbeat\",\"role\":\"{role}\",\"session\":\"{session_id}\"}}\n' \
             \"$ts\" >> \"$AMBIENT\" 2>/dev/null || true; \
             echo \"[{role}] tick $ts\" >> \"$LOG_FILE\" 2>&1; sleep \"$INTERVAL\"; done",
            ambient = cfg.ambient_path.display(),
        )
    };

    let respawn_cmd = format!("/bin/bash -lc '{inner_cmd}'");
    let target = format!("{tmux_session}:{role}");

    if cfg.dry_run {
        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        emit_ambient(
            &cfg.ambient_path,
            &serde_json::json!({
                "ts": ts,
                "kind": "curator_supervisor_dry_run",
                "action": "would-respawn-pane",
                "role": role,
                "target": target,
            }),
        );
        return Ok(());
    }

    info!(role, target = %target, "respawning curator pane");

    // CREDIBLE-359: respawning a curator pane restarts its own Opus session
    // in place — no delegation to a Sonnet sub-agent — so it's the
    // delegated=false counterpart to the spawn_sonnet telemetry above.
    emit_ambient(
        &cfg.ambient_path,
        &serde_json::json!({
            "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            "kind": "sub_agent_dispatched",
            "role": role,
            "model": "opus",
            "delegated": false,
        }),
    );

    let respawn_status = std::process::Command::new("tmux")
        .args(["respawn-pane", "-t", &target, "-k", &respawn_cmd])
        .current_dir(&cfg.repo_root)
        .status();

    match respawn_status {
        Err(e) => {
            warn!(role, err = %e, "tmux respawn-pane invocation error");
        }
        Ok(s) if !s.success() => {
            warn!(role, code = s.code(), "tmux respawn-pane failed");
        }
        Ok(_) => {
            info!(
                role,
                "tmux respawn-pane succeeded, waiting for heartbeat (60s)"
            );
            // Poll ambient.jsonl for up to 60s for a fresh heartbeat.
            let heartbeat_seen = wait_for_heartbeat(&cfg.ambient_path, role, 60).await;
            if heartbeat_seen {
                emit_ambient(
                    &cfg.ambient_path,
                    &serde_json::json!({
                        "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                        "kind": "curator_respawned",
                        "role": role,
                    }),
                );
                info!(role, "curator_respawned emitted");
            } else {
                emit_ambient(
                    &cfg.ambient_path,
                    &serde_json::json!({
                        "ts": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                        "kind": "curator_respawn_failed",
                        "role": role,
                        "reason": "no heartbeat within 60s",
                    }),
                );
                warn!(
                    role,
                    "curator_respawn_failed — no heartbeat within 60s, broadcasting WARN"
                );
                // Escalate to operator via broadcast.sh.
                let broadcast_sh = cfg.repo_root.join("scripts/coord/broadcast.sh");
                let _ = std::process::Command::new("bash")
                    .arg(&broadcast_sh)
                    .args([
                        "--all",
                        "WARN",
                        &format!("curator-{role} respawn failed — no heartbeat within 60s"),
                    ])
                    .current_dir(&cfg.repo_root)
                    .status();
            }
        }
    }

    Ok(())
}

/// Poll ambient.jsonl until a fresh curator_heartbeat for `role` appears (max `timeout_s`).
async fn wait_for_heartbeat(ambient_path: &Path, role: &str, timeout_s: u64) -> bool {
    let started = std::time::Instant::now();
    let deadline = Duration::from_secs(timeout_s);
    let baseline = Utc::now();

    // Path to string for passing to spawned code.
    let ambient_path = ambient_path.to_path_buf();
    let role = role.to_string();

    loop {
        if started.elapsed() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_secs(3)).await;

        // Read last 20 lines and look for a heartbeat newer than baseline.
        if let Ok(lines) = tail_lines(&ambient_path, 20) {
            for line in &lines {
                let Ok(v) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                if v.get("kind").and_then(|k| k.as_str()) != Some("curator_heartbeat") {
                    continue;
                }
                if v.get("role").and_then(|r| r.as_str()) != Some(role.as_str()) {
                    continue;
                }
                if let Some(ts_str) = v.get("ts").and_then(|t| t.as_str()) {
                    if let Ok(ts) = ts_str.parse::<chrono::DateTime<Utc>>() {
                        if ts >= baseline {
                            return true;
                        }
                    }
                }
            }
        }
    }
}

// ── helpers ────────────────────────────────────────────────────────────────

fn resolve_repo_root() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_REPO_ROOT") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
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
        .unwrap_or_else(|| PathBuf::from("/Users/jeffadkins/Projects/Chump"))
}

fn env_path(key: &str, default: PathBuf) -> PathBuf {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or(default)
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Return the last `n` lines of a file. Returns empty vec if file missing.
fn tail_lines(path: &Path, n: usize) -> Result<Vec<String>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = fs::File::open(path).with_context(|| format!("open {:?}", path))?;
    let reader = io::BufReader::new(file);
    let mut lines: Vec<String> = reader.lines().map_while(Result::ok).collect();
    if lines.len() > n {
        lines.drain(0..lines.len() - n);
    }
    Ok(lines)
}

fn get_log_tail(cfg: &Config, role: &str, n: usize) -> String {
    let log_path = cfg.log_dir.join(format!("curator-{role}.log"));
    tail_lines(&log_path, n).unwrap_or_default().join("\n")
}

fn infer_session_id(role: &str) -> String {
    let date = Utc::now().format("%Y-%m-%d");
    format!("curator-opus-{role}-{date}")
}

fn find_loop_script(role: &str) -> &'static str {
    CURATOR_ROLES
        .iter()
        .find(|(r, _)| *r == role)
        .map(|(_, s)| *s)
        .unwrap_or("")
}

fn emit_ambient(ambient_path: &Path, event: &Value) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(ambient_path)
    {
        use std::io::Write;
        let line = serde_json::to_string(event).unwrap_or_else(|_| "{}".to_string());
        let _ = writeln!(f, "{line}");
    }
}

fn write_sentinel(sentinel_path: &Path, fingerprint: &str) -> Result<()> {
    if let Some(parent) = sentinel_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(sentinel_path, fingerprint)?;
    Ok(())
}

// ── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn make_temp_log(dir: &TempDir, name: &str, lines: &[&str]) -> PathBuf {
        let path = dir.path().join(name);
        let mut f = fs::File::create(&path).unwrap();
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
        path
    }

    #[test]
    fn test_error_pattern_scan_triggers() {
        let dir = TempDir::new().unwrap();
        let path = make_temp_log(
            &dir,
            "test.log",
            &[
                "normal line",
                "error: unknown subcommand: tick",
                "another line",
                "error: unknown subcommand: heartbeat",
                "ok line",
            ],
        );
        let (triggered, sample) = error_pattern_scan(&path, 50, 2).unwrap();
        assert!(triggered, "should trigger on 2+ error patterns");
        assert!(sample.is_some());
    }

    #[test]
    fn test_error_pattern_scan_no_trigger_below_threshold() {
        let dir = TempDir::new().unwrap();
        let path = make_temp_log(
            &dir,
            "test.log",
            &["normal line", "unknown subcommand: tick", "ok line"],
        );
        let (triggered, _) = error_pattern_scan(&path, 50, 2).unwrap();
        assert!(
            !triggered,
            "should not trigger on 1 match when threshold is 2"
        );
    }

    #[test]
    fn test_crash_loop_check_triggers() {
        let dir = TempDir::new().unwrap();
        let mut lines: Vec<&str> = Vec::new();
        lines.extend(std::iter::repeat_n("error: something went wrong", 85));
        lines.extend(std::iter::repeat_n("normal output", 15));
        let path = make_temp_log(&dir, "test.log", &lines);
        let triggered = crash_loop_check(&path, 100, 0.80).unwrap();
        assert!(triggered, "85% error ratio should trigger crash loop");
    }

    #[test]
    fn test_crash_loop_check_no_trigger() {
        let dir = TempDir::new().unwrap();
        let mut lines: Vec<&str> = Vec::new();
        lines.extend(std::iter::repeat_n("normal output", 50));
        lines.extend(std::iter::repeat_n("error: something", 50));
        let path = make_temp_log(&dir, "test.log", &lines);
        let triggered = crash_loop_check(&path, 100, 0.80).unwrap();
        assert!(
            !triggered,
            "50% error ratio should not trigger at 80% threshold"
        );
    }

    #[test]
    fn test_tail_lines_returns_last_n() {
        let dir = TempDir::new().unwrap();
        let lines: Vec<String> = (0..100).map(|i| format!("line {i}")).collect();
        let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
        let path = make_temp_log(&dir, "test.log", &refs);
        let tail = tail_lines(&path, 10).unwrap();
        assert_eq!(tail.len(), 10);
        assert_eq!(tail[0], "line 90");
        assert_eq!(tail[9], "line 99");
    }

    #[test]
    fn test_sentinel_dedup() {
        let dir = TempDir::new().unwrap();
        let sentinel_path = dir.path().join("decompose:abcdef12.sentinel");
        write_sentinel(&sentinel_path, "decompose:abcdef12").unwrap();
        assert!(sentinel_path.exists(), "sentinel file should be created");
        let meta = fs::metadata(&sentinel_path).unwrap();
        let modified = meta.modified().unwrap();
        let elapsed = SystemTime::now().duration_since(modified).unwrap();
        // Just created — elapsed should be < 1s.
        assert!(
            elapsed < Duration::from_secs(1),
            "fresh sentinel: elapsed should be <1s"
        );
    }

    #[test]
    fn test_error_fingerprint_consistent() {
        let det = DetectionResult {
            role: "decompose".to_string(),
            error_pattern_triggered: true,
            error_pattern_sample: Some("unknown subcommand: tick".to_string()),
            ..Default::default()
        };
        let fp1 = det.error_fingerprint();
        let fp2 = det.error_fingerprint();
        assert_eq!(fp1, fp2, "fingerprint must be deterministic");
        assert!(
            fp1.starts_with("decompose:"),
            "fingerprint must include role"
        );
    }

    // ── RESILIENT-246: heartbeat truth ───────────────────────────────────────
    //
    // The previous version of this block contained
    //
    //     assert!(!stalled, "no ambient file → should not stall");
    //
    // which asserted the bug: with no ambient stream at all, the supervisor was
    // required to report health. A test that pins a fail-open in place is part
    // of the fail-open, and it is why this survived review. It is inverted
    // below.

    const THRESH: Duration = Duration::from_secs(600);
    const ROLES: &[&str] = &["decompose", "handoff", "ci-audit", "md-links", "shepherd"];

    fn ts_ago(mins: i64) -> String {
        (Utc::now() - chrono::Duration::minutes(mins))
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string()
    }

    /// Write an ambient file, always including one old non-heartbeat line so
    /// the scan can prove it covered the threshold window (otherwise every
    /// fixture is legitimately Blind).
    fn ambient_with(dir: &TempDir, body: &str) -> PathBuf {
        let p = dir.path().join("ambient.jsonl");
        let anchor = format!(
            "{{\"ts\":\"{}\",\"kind\":\"farmer_heartbeat\"}}\n",
            ts_ago(120)
        );
        fs::write(&p, format!("{anchor}{body}")).unwrap();
        p
    }

    fn state(p: &Path, role: &str) -> HeartbeatState {
        HeartbeatScan::collect(p, ROLES)
            .unwrap()
            .state_for(role, THRESH)
    }

    #[test]
    fn test_no_ambient_file_is_blind_not_healthy() {
        let dir = TempDir::new().unwrap();
        let ambient = dir.path().join("does-not-exist.jsonl");
        let st = state(&ambient, "decompose");
        assert!(
            matches!(st, HeartbeatState::Blind { .. }),
            "a missing ambient stream means the supervisor cannot see, not that \
             the curator is well; got {st:?}"
        );
        assert!(st.is_failing(), "Blind must never read as healthy");
        assert!(
            !st.is_remediable(),
            "Blind must never trigger a restart — you cannot restart what you cannot see"
        );
    }

    #[test]
    fn test_never_heartbeated_is_dead_not_healthy() {
        // The live condition on 2026-08-09: ambient full of other traffic,
        // reaching well past the threshold, and not one curator heartbeat.
        let dir = TempDir::new().unwrap();
        let ambient = ambient_with(&dir, "");
        let st = state(&ambient, "decompose");
        assert_eq!(
            st,
            HeartbeatState::NeverSeen,
            "a role that has never heartbeated across a fully covered window is dead"
        );
        assert!(st.is_failing(), "NeverSeen must page");
        assert!(
            !st.is_remediable(),
            "NeverSeen has no live pane to respawn — report, do not fork-bomb"
        );
    }

    #[test]
    fn test_stalled_heartbeat_still_detected_and_remediable() {
        let dir = TempDir::new().unwrap();
        let ambient = ambient_with(
            &dir,
            &format!(
                "{{\"ts\":\"{}\",\"kind\":\"curator_heartbeat\",\"role\":\"decompose\"}}\n",
                ts_ago(30)
            ),
        );
        match state(&ambient, "decompose") {
            HeartbeatState::Stalled { ago } => {
                assert!(ago > Duration::from_secs(1000), "~30 min, got {ago:?}");
            }
            other => panic!("30-min-old heartbeat must stall, got {other:?}"),
        }
        assert!(
            state(&ambient, "decompose").is_remediable(),
            "a role that was alive and went quiet IS the case restart was built for"
        );
    }

    #[test]
    fn test_fresh_heartbeat_is_healthy() {
        let dir = TempDir::new().unwrap();
        let ambient = ambient_with(
            &dir,
            &format!(
                "{{\"ts\":\"{}\",\"kind\":\"curator_heartbeat\",\"role\":\"decompose\"}}\n",
                ts_ago(1)
            ),
        );
        let st = state(&ambient, "decompose");
        assert!(matches!(st, HeartbeatState::Fresh { .. }), "got {st:?}");
        assert!(!st.is_failing());
    }

    #[test]
    fn test_productized_roles_emit_their_own_kind_and_are_seen() {
        // The mismatch that hid the fail-open. Each productized curator emits
        // <role>_heartbeat, NOT curator_heartbeat. Before this fix all four
        // were invisible; after the fail-open fix alone, all four would have
        // been paged as dead while running perfectly.
        let dir = TempDir::new().unwrap();
        let now = ts_ago(0);
        let body = format!(
            "{{\"ts\":\"{now}\",\"kind\":\"handoff_heartbeat\",\"role\":\"handoff\"}}\n\
             {{\"ts\":\"{now}\",\"kind\":\"ci_audit_heartbeat\",\"role\":\"ci-audit\"}}\n\
             {{\"ts\":\"{now}\",\"kind\":\"md_links_heartbeat\",\"role\":\"md-links\"}}\n\
             {{\"ts\":\"{now}\",\"kind\":\"decompose_heartbeat\",\"role\":\"curator-opus-decompose\"}}\n"
        );
        let ambient = ambient_with(&dir, &body);
        for role in ["handoff", "ci-audit", "md-links", "decompose"] {
            let st = state(&ambient, role);
            assert!(
                matches!(st, HeartbeatState::Fresh { .. }),
                "{role} emits {} and must be recognised; got {st:?}",
                heartbeat_kind_for(role)
            );
        }
    }

    #[test]
    fn test_decompose_role_field_mismatch_does_not_hide_it() {
        // decompose-loop.sh writes role="curator-opus-decompose". An exact
        // role-field match would drop every one of its heartbeats.
        let dir = TempDir::new().unwrap();
        let ambient = ambient_with(
            &dir,
            &format!(
                "{{\"ts\":\"{}\",\"kind\":\"decompose_heartbeat\",\"role\":\"curator-opus-decompose\"}}\n",
                ts_ago(0)
            ),
        );
        assert!(matches!(
            state(&ambient, "decompose"),
            HeartbeatState::Fresh { .. }
        ));
    }

    #[test]
    fn test_one_roles_heartbeat_does_not_vouch_for_another() {
        let dir = TempDir::new().unwrap();
        let ambient = ambient_with(
            &dir,
            &format!(
                "{{\"ts\":\"{}\",\"kind\":\"handoff_heartbeat\",\"role\":\"handoff\"}}\n",
                ts_ago(0)
            ),
        );
        assert!(matches!(
            state(&ambient, "handoff"),
            HeartbeatState::Fresh { .. }
        ));
        assert_eq!(
            state(&ambient, "ci-audit"),
            HeartbeatState::NeverSeen,
            "handoff being alive says nothing about ci-audit"
        );
    }

    #[test]
    fn test_short_window_after_rotation_is_blind_not_a_mass_page() {
        // ambient.jsonl rotates nightly. Seconds after a rotation the retained
        // file cannot cover a 10-minute threshold, so "no heartbeat" proves
        // nothing. Without this, every rotation would page all six roles at
        // once — turning a truth fix into a recurring 3am incident.
        let dir = TempDir::new().unwrap();
        let p = dir.path().join("ambient.jsonl");
        fs::write(
            &p,
            format!(
                "{{\"ts\":\"{}\",\"kind\":\"farmer_heartbeat\"}}\n",
                ts_ago(1)
            ),
        )
        .unwrap();
        let st = state(&p, "decompose");
        assert!(
            matches!(st, HeartbeatState::Blind { .. }),
            "a 1-minute-deep file cannot disprove a 10-minute threshold; got {st:?}"
        );
        assert!(!st.is_remediable(), "never act on an unproven absence");
    }

    #[test]
    fn test_busy_fleet_cannot_scroll_a_heartbeat_out_of_view() {
        // The old scan read a fixed 500 lines. At the fleet's measured 42
        // lines/min that covered ~12 minutes against a 10-minute threshold —
        // and a busier fleet would invert it. Bury a fresh heartbeat under
        // 5,000 lines of unrelated traffic: it must still be found.
        let dir = TempDir::new().unwrap();
        let mut body = format!(
            "{{\"ts\":\"{}\",\"kind\":\"decompose_heartbeat\",\"role\":\"decompose\"}}\n",
            ts_ago(1)
        );
        for _ in 0..5_000 {
            body.push_str(&format!(
                "{{\"ts\":\"{}\",\"kind\":\"farmer_heartbeat\"}}\n",
                ts_ago(0)
            ));
        }
        let ambient = ambient_with(&dir, &body);
        assert!(
            matches!(state(&ambient, "decompose"), HeartbeatState::Fresh { .. }),
            "a healthy curator must not be declared dead just because the fleet got chatty"
        );
    }

    #[test]
    fn test_coverage_is_a_scan_property_not_a_per_role_one() {
        // Blindness is one supervisor problem, not six curator problems: same
        // file, same cutoff. Reporting it per-role would file six phantom
        // gaps every time the ambient log rotates.
        let dir = TempDir::new().unwrap();
        let shallow = dir.path().join("shallow.jsonl");
        fs::write(
            &shallow,
            format!(
                "{{\"ts\":\"{}\",\"kind\":\"farmer_heartbeat\"}}\n",
                ts_ago(1)
            ),
        )
        .unwrap();
        assert!(
            HeartbeatScan::collect(&shallow, ROLES)
                .unwrap()
                .coverage_gap(THRESH)
                .is_some(),
            "a 1-minute-deep file cannot support a 10-minute absence claim"
        );

        let deep = ambient_with(&dir, "");
        assert!(
            HeartbeatScan::collect(&deep, ROLES)
                .unwrap()
                .coverage_gap(THRESH)
                .is_none(),
            "a 2-hour-deep file covers the threshold and CAN prove absence"
        );
    }

    #[test]
    fn test_unassessed_is_not_a_claim_of_health() {
        let st = HeartbeatState::Unassessed;
        assert!(
            !st.is_failing(),
            "the tick already reported its blindness — do not double-page per role"
        );
        assert!(!st.is_remediable(), "never act on something never assessed");
        let s = st.summary();
        assert!(
            !s.contains("fresh") && s.contains("not_assessed"),
            "an unassessed role must never render as fresh; got {s:?}"
        );
    }

    #[test]
    fn test_default_detection_result_is_not_healthy() {
        let det = DetectionResult::default();
        assert!(
            det.is_failing(),
            "an unpopulated DetectionResult must not read as a healthy curator"
        );
        assert!(!det.is_remediable(), "and must not trigger remediation");
    }

    // ── RESILIENT-040 anti-race helper tests ─────────────────────────────────

    fn _test_cfg_at(root: &Path) -> Config {
        Config {
            repo_root: root.to_path_buf(),
            log_dir: root.join("logs"),
            ambient_path: root.join("locks/ambient.jsonl"),
            sentinel_dir: root.join("supervisor/seen"),
            sentinel_ttl: Duration::from_secs(3600),
            stall_threshold: Duration::from_secs(600),
            productivity_window: Duration::from_secs(3600),
            mode: SupervisorMode::Aggressive,
            autorestart: true,
            dry_run: true,
            interval: Duration::from_secs(300),
            max_spawns_per_hour: 3,
            flapping_window: Duration::from_secs(1800),
            flapping_threshold: 3,
        }
    }

    #[test]
    fn test_gap_already_claimed_returns_false_for_empty_gap_id() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        // ambient_path is locks/ambient.jsonl → lock_dir = locks/
        fs::create_dir_all(dir.path().join("locks")).unwrap();
        assert!(!gap_already_claimed(&cfg, "").unwrap());
    }

    #[test]
    fn test_gap_already_claimed_returns_false_when_no_claim_file() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        fs::create_dir_all(dir.path().join("locks")).unwrap();
        assert!(!gap_already_claimed(&cfg, "INFRA-9999").unwrap());
    }

    #[test]
    fn test_gap_already_claimed_returns_true_when_claim_file_present() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        let locks = dir.path().join("locks");
        fs::create_dir_all(&locks).unwrap();
        // gap_id is lowercased before glob match.
        fs::write(
            locks.join("claim-infra-9999-12345-1780000000.json"),
            r#"{"session_id":"sibling-x"}"#,
        )
        .unwrap();
        assert!(gap_already_claimed(&cfg, "INFRA-9999").unwrap());
    }

    #[test]
    fn test_gap_already_claimed_works_for_dry_run_ids() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        let locks = dir.path().join("locks");
        fs::create_dir_all(&locks).unwrap();
        fs::write(
            locks.join("claim-dry-run-decompose:abc12345-1-1.json"),
            r#"{"session_id":"sibling-x"}"#,
        )
        .unwrap();
        // DRY-RUN prefix no longer short-circuits — it should detect the claim
        // so dry-run smoke tests can validate the collision path.
        assert!(gap_already_claimed(&cfg, "DRY-RUN-decompose:abc12345").unwrap());
    }

    #[test]
    fn test_find_open_gap_with_fingerprint_degrades_silently_when_chump_missing() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        // Point CHUMP_BIN at a non-existent binary so the shell-out fails.
        std::env::set_var("CHUMP_BIN", "/does/not/exist/chump-missing");
        let result = find_open_gap_with_fingerprint(&cfg, "decompose:deadbeef");
        std::env::remove_var("CHUMP_BIN");
        // Should return Ok(None) — degraded path, not a crash.
        assert!(matches!(result, Ok(None)));
    }

    // ── RESILIENT-038: substrate-vs-code triage ──────────────────────────────

    #[test]
    fn test_parse_df_capacity_pct_disk_full() {
        let df_out = "Filesystem     1024-blocks     Used Available Capacity Mounted on\n\
                       /dev/disk3s1     976490568 946490568  10000000      99% /\n";
        assert_eq!(parse_df_capacity_pct(df_out), Some(99));
    }

    #[test]
    fn test_parse_df_capacity_pct_healthy() {
        let df_out = "Filesystem     1024-blocks     Used Available Capacity Mounted on\n\
                       /dev/disk3s1     976490568 400000000 500000000      45% /\n";
        assert_eq!(parse_df_capacity_pct(df_out), Some(45));
    }

    #[test]
    fn test_parse_df_capacity_pct_malformed_returns_none() {
        assert_eq!(parse_df_capacity_pct(""), None);
        assert_eq!(parse_df_capacity_pct("not df output at all"), None);
    }

    #[test]
    fn test_substrate_cache_round_trips_within_ttl() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        let cache_path = substrate_cache_path(&cfg);
        fs::create_dir_all(cache_path.parent().unwrap()).unwrap();
        let entry = SubstrateCacheEntry {
            checked_at_ms: Utc::now().timestamp_millis(),
            cause: Some(SubstrateCause {
                kind: "disk_full".to_string(),
                detail: "df reports 99% used".to_string(),
            }),
        };
        fs::write(&cache_path, serde_json::to_string(&entry).unwrap()).unwrap();

        // substrate_check() must return the cached cause WITHOUT re-probing —
        // proven here because the cache was pre-seeded, not because probes
        // were stubbed. If disk/gh/nats/auth all disagreed with the cache the
        // fresh-probe path would still return the cache's verdict inside TTL.
        let got = substrate_check(&cfg);
        assert_eq!(
            got,
            Some(entry.cause.unwrap()),
            "cached verdict must win inside TTL"
        );
    }

    #[test]
    fn test_substrate_cache_expired_entry_is_not_reused() {
        let dir = TempDir::new().unwrap();
        let cfg = _test_cfg_at(dir.path());
        let cache_path = substrate_cache_path(&cfg);
        fs::create_dir_all(cache_path.parent().unwrap()).unwrap();
        let stale_ms = Utc::now().timestamp_millis() - (SUBSTRATE_CACHE_TTL_S as i64 + 60) * 1000;
        let entry = SubstrateCacheEntry {
            checked_at_ms: stale_ms,
            cause: Some(SubstrateCause {
                kind: "disk_full".to_string(),
                detail: "stale".to_string(),
            }),
        };
        fs::write(&cache_path, serde_json::to_string(&entry).unwrap()).unwrap();

        // Past TTL, substrate_check() must re-probe rather than trust the
        // stale cache entry (detected by checking the cache file gets
        // rewritten with a newer timestamp).
        let _ = substrate_check(&cfg);
        let raw = fs::read_to_string(&cache_path).unwrap();
        let refreshed: SubstrateCacheEntry = serde_json::from_str(&raw).unwrap();
        assert!(
            refreshed.checked_at_ms > stale_ms,
            "expired cache entry must be replaced with a fresh probe timestamp"
        );
    }

    /// AC4 smoke test: mock a disk-full substrate cause, synthesize 3 failing
    /// curators, and assert exactly ONE substrate gap-filing path fires (via
    /// the dry-run gap/broadcast markers, since a real `chump gap reserve`
    /// needs a live state.db) and zero Sonnet-spawn markers appear.
    #[tokio::test]
    async fn test_disk_full_substrate_cause_files_one_gap_and_spawns_zero_sonnets() {
        let dir = TempDir::new().unwrap();
        let mut cfg = _test_cfg_at(dir.path());
        cfg.dry_run = true;
        fs::create_dir_all(&cfg.sentinel_dir).unwrap();
        fs::create_dir_all(cfg.ambient_path.parent().unwrap()).unwrap();

        let cause = SubstrateCause {
            kind: "disk_full".to_string(),
            detail: "df reports 99% used at /repo (threshold 95%)".to_string(),
        };
        let failures: Vec<DetectionResult> = ["shepherd", "handoff", "ci-audit"]
            .iter()
            .map(|role| DetectionResult {
                role: role.to_string(),
                error_pattern_triggered: true,
                error_pattern_sample: Some("fatal: disk full".to_string()),
                heartbeat: HeartbeatState::Stalled {
                    ago: Duration::from_secs(900),
                },
                crash_loop_triggered: false,
                productivity_drop_triggered: false,
            })
            .collect();

        report_substrate_outage(&cfg, &cause, &failures)
            .await
            .unwrap();

        let ambient_raw = fs::read_to_string(&cfg.ambient_path).unwrap_or_default();
        let events: Vec<Value> = ambient_raw
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();

        let substrate_events = events
            .iter()
            .filter(|e| e.get("kind").and_then(|k| k.as_str()) == Some("curator_substrate_outage"))
            .count();
        assert_eq!(
            substrate_events, 1,
            "exactly one substrate outage event, not one per curator"
        );

        let gap_would_file = events.iter().any(|e| {
            e.get("kind").and_then(|k| k.as_str()) == Some("curator_supervisor_dry_run")
                && e.get("action").and_then(|a| a.as_str()) == Some("would-file-substrate-gap")
        });
        assert!(
            gap_would_file,
            "expected a single would-file-substrate-gap marker"
        );

        let sonnet_spawn_markers = events
            .iter()
            .filter(|e| {
                e.get("kind").and_then(|k| k.as_str()) == Some("curator_supervisor_dry_run")
                    && e.get("action").and_then(|a| a.as_str()) == Some("would-spawn-sonnet")
            })
            .count();
        assert_eq!(
            sonnet_spawn_markers, 0,
            "substrate-caused failures must not trigger any per-curator Sonnet spawn"
        );

        // Dedup sentinel written so a still-full disk doesn't refile every tick.
        let sentinel_path = cfg.sentinel_dir.join("substrate_disk_full.sentinel");
        assert!(
            sentinel_path.exists(),
            "substrate dedup sentinel must be written"
        );
    }

    #[tokio::test]
    async fn test_substrate_outage_dedup_skips_refile_within_ttl() {
        let dir = TempDir::new().unwrap();
        let mut cfg = _test_cfg_at(dir.path());
        cfg.dry_run = true;
        cfg.sentinel_ttl = Duration::from_secs(3600);
        fs::create_dir_all(&cfg.sentinel_dir).unwrap();
        fs::create_dir_all(cfg.ambient_path.parent().unwrap()).unwrap();

        let cause = SubstrateCause {
            kind: "gh_rate_limited".to_string(),
            detail: "gh api rate_limit: 3 core requests remaining".to_string(),
        };
        let failures = vec![DetectionResult {
            role: "handoff".to_string(),
            ..Default::default()
        }];

        report_substrate_outage(&cfg, &cause, &failures)
            .await
            .unwrap();
        report_substrate_outage(&cfg, &cause, &failures)
            .await
            .unwrap();

        let ambient_raw = fs::read_to_string(&cfg.ambient_path).unwrap();
        let outage_events = ambient_raw
            .lines()
            .filter(|l| l.contains("\"kind\":\"curator_substrate_outage\""))
            .count();
        assert_eq!(
            outage_events, 2,
            "the observed-outage event still fires each tick — only the gap-filing dedupes"
        );
        let would_file_markers = ambient_raw
            .lines()
            .filter(|l| l.contains("would-file-substrate-gap"))
            .count();
        assert_eq!(
            would_file_markers, 1,
            "second call within sentinel TTL must not re-file the substrate gap"
        );
    }
}
