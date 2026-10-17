//! INFRA-2159 (META-125/C8) — `chump-consensus-aggregator-daemon`.
//!
//! Rust binary that watches `.chump-locks/ambient.jsonl` for `kind=vote`
//! events (emitted by `chump vote`, src/commands/vote.rs) grouped by
//! `corr_id`, and — once a proposal reaches quorum OR its deadline passes
//! (whichever comes first) — computes a confidence-weighted decision and
//! emits `kind=consensus_resolved` (registered in
//! docs/observability/EVENT_REGISTRY.yaml, previously `status: planned`
//! with no production emitter). The finalized `ConsensusRecord` is also
//! written to `.chump/state.db` (table `consensus_decisions`) for
//! queryable history, per the C8 spec in
//! docs/strategy/LIVE_A2A_CONSENSUS_2026-05-29.md:141.
//!
//! Confidence weighting: each `kind=vote` event carries an optional
//! `confidence` field (0-100, INFRA-2157/C6; defaults to 100 when absent).
//! A vote's weight is `confidence / 100.0`. The decision is
//! `Proceed` when weighted-yes > weighted-no, `Abort` when
//! weighted-no > weighted-yes, else `Inconclusive`. Raw (unweighted)
//! `votes_for` / `votes_against` counts are also carried so downstream
//! consumers (e.g. `chump pe-suite status`) that only read the required
//! EVENT_REGISTRY fields keep working unweighted.
//!
//! ## Observability (satisfies gap AC1-4)
//!
//! - **Events emitted on success:** `kind=consensus_resolved` with
//!   `{ts, kind, corr_id, decision, votes_for, votes_against,
//!   weighted_for, weighted_against, quorum, resolved_reason}` where
//!   `resolved_reason` is `"quorum_reached"` or `"timeout"`.
//! - **Events emitted on failure:** none — a malformed vote line is
//!   skipped (see failure-class taxonomy below) and counted in the
//!   per-pass summary printed to stderr; a corr_id with no quorum and no
//!   expired deadline is left pending (no event) so a later pass can
//!   pick it up once more votes land.
//! - **Events emitted on timeout:** same `kind=consensus_resolved` line
//!   as success, with `resolved_reason=timeout` — a timed-out proposal
//!   is not a distinct outcome, it is a resolution path, so it reuses
//!   the terminal event rather than needing its own kind.
//! - **Cost:** read-only over local `ambient.jsonl` plus one SQLite
//!   write per newly-resolved corr_id; no LLM calls, no network calls.
//!   The per-pass summary line
//!   (`[consensus-aggregator] pass: resolved=N pending=M malformed=K`)
//!   is the operator-facing cost/throughput signal — grep it for cost
//!   accounting, there is nothing else to bill.
//! - **Failure-class taxonomy:** permanent (exit 2) — bad CLI args, or
//!   `.chump/state.db` cannot be opened/migrated; transient (logged,
//!   pass continues) — a single malformed JSON line in ambient.jsonl
//!   (skipped, counted in `malformed`), or ambient.jsonl missing
//!   entirely (treated as zero votes, not fatal, since a fresh repo has
//!   no ambient stream yet).
//! - **Smoke test:** `scripts/ci/test-chump-consensus-aggregator-daemon.sh`.
//!
//! Usage: `chump-consensus-aggregator-daemon [--once] [--interval <secs>]
//! [--quorum <N>] [--ambient <path>] [--state-db <path>]`
//! `--once` runs a single pass and exits (used by the smoke test and by
//! cron/launchd invocation per INFRA-2160/C9); omitting it loops forever
//! at `--interval` (default 30s).

use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

const DEFAULT_QUORUM: u32 = 3;
const DEFAULT_INTERVAL_SECS: u64 = 30;

struct Cfg {
    once: bool,
    interval_secs: u64,
    quorum: u32,
    ambient_path: PathBuf,
    state_db_path: PathBuf,
}

impl Cfg {
    fn from_args() -> Result<Self, String> {
        let repo_root = repo_root();
        let mut once = false;
        let mut interval_secs = DEFAULT_INTERVAL_SECS;
        let mut quorum = DEFAULT_QUORUM;
        let mut ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
            .map(PathBuf::from)
            .unwrap_or_else(|_| repo_root.join(".chump-locks/ambient.jsonl"));
        // INFRA-8190: the ONE resolver (honors CHUMP_STATE_DB first).
        let mut state_db_path = chump_gap_store::store_path::state_db_path(&repo_root);

        let args: Vec<String> = std::env::args().collect();
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--once" => once = true,
                "--interval" => {
                    i += 1;
                    let v = args
                        .get(i)
                        .ok_or_else(|| "--interval requires a value".to_string())?;
                    interval_secs = v
                        .parse()
                        .map_err(|_| format!("--interval must be an integer (got {v:?})"))?;
                }
                "--quorum" => {
                    i += 1;
                    let v = args
                        .get(i)
                        .ok_or_else(|| "--quorum requires a value".to_string())?;
                    quorum = v
                        .parse()
                        .map_err(|_| format!("--quorum must be an integer (got {v:?})"))?;
                }
                "--ambient" => {
                    i += 1;
                    ambient_path = PathBuf::from(
                        args.get(i)
                            .ok_or_else(|| "--ambient requires a value".to_string())?,
                    );
                }
                "--state-db" => {
                    i += 1;
                    state_db_path = PathBuf::from(
                        args.get(i)
                            .ok_or_else(|| "--state-db requires a value".to_string())?,
                    );
                }
                other => {
                    return Err(format!("unknown argument: {other}"));
                }
            }
            i += 1;
        }

        Ok(Cfg {
            once,
            interval_secs,
            quorum,
            ambient_path,
            state_db_path,
        })
    }
}

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(content) = std::fs::read_to_string(&cargo) {
                if content.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// One parsed `kind=vote` event. `corr_id` lives on the enclosing map key
/// (see `load_votes`), not duplicated per-event.
struct VoteEvent {
    vote: i32,
    confidence: f64,
    deadline: Option<String>,
}

/// Minimal flat-JSON field extractor, mirroring
/// src/commands/consensus_tally.rs::json_get_str — kept local since bin
/// targets don't share the `chump` binary's `src/commands` modules
/// (no lib.rs in this crate).
fn json_get_str<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\":");
    let pos = line.find(needle.as_str())?;
    let rest = &line[pos + needle.len()..];
    if let Some(stripped) = rest.strip_prefix('"') {
        let mut end = 0;
        let mut escaped = false;
        for (idx, c) in stripped.char_indices() {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                end = idx;
                break;
            }
        }
        Some(&stripped[..end])
    } else {
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c == ' ')
            .unwrap_or(rest.len());
        Some(rest[..end].trim())
    }
}

/// Parse a Unix-seconds timestamp from an RFC-3339 string, best-effort.
fn parse_iso8601(s: &str) -> Option<i64> {
    use std::str::FromStr;
    if let Ok(dt) = chrono::DateTime::<chrono::FixedOffset>::from_str(s) {
        return Some(dt.timestamp());
    }
    if let Ok(dt) = chrono::DateTime::<chrono::Utc>::from_str(s) {
        return Some(dt.timestamp());
    }
    None
}

/// Load all `kind=vote` events from ambient.jsonl, plus the set of
/// corr_ids that already have a `kind=consensus_resolved` line (already
/// finalized — skip on re-run, this is what makes a pass idempotent).
/// Returns `(votes_by_corr_id, already_resolved, malformed_count)`.
fn load_votes(
    path: &Path,
) -> (
    HashMap<String, Vec<VoteEvent>>,
    std::collections::HashSet<String>,
    u32,
) {
    let mut votes: HashMap<String, Vec<VoteEvent>> = HashMap::new();
    let mut resolved: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut malformed = 0u32;

    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return (votes, resolved, malformed),
    };

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let kind = match json_get_str(line, "kind") {
            Some(k) => k,
            None => continue,
        };
        if kind == "consensus_resolved" {
            if let Some(c) = json_get_str(line, "corr_id") {
                if !c.is_empty() {
                    resolved.insert(c.to_string());
                }
            }
            continue;
        }
        if kind != "vote" {
            continue;
        }
        let corr_id = match json_get_str(line, "corr_id") {
            Some(c) if !c.is_empty() => c.to_string(),
            _ => {
                malformed += 1;
                continue;
            }
        };
        let vote = match json_get_str(line, "vote")
            .and_then(|v| v.trim_matches('"').parse::<i32>().ok())
        {
            Some(v) => v,
            None => {
                malformed += 1;
                continue;
            }
        };
        let confidence = json_get_str(line, "confidence")
            .and_then(|v| v.trim_matches('"').parse::<f64>().ok())
            .unwrap_or(100.0)
            .clamp(0.0, 100.0)
            / 100.0;
        let deadline = json_get_str(line, "deadline").map(|d| d.to_string());

        votes.entry(corr_id).or_default().push(VoteEvent {
            vote,
            confidence,
            deadline,
        });
    }

    (votes, resolved, malformed)
}

struct Resolution {
    corr_id: String,
    decision: &'static str,
    votes_for: u32,
    votes_against: u32,
    weighted_for: f64,
    weighted_against: f64,
    quorum: u32,
    resolved_reason: &'static str,
}

/// Decide whether `events` for one corr_id should resolve this pass, and
/// if so compute the confidence-weighted decision.
fn maybe_resolve(
    corr_id: &str,
    events: &[VoteEvent],
    quorum: u32,
    now_secs: i64,
) -> Option<Resolution> {
    let total = events.len() as u32;
    let latest_deadline = events
        .iter()
        .filter_map(|e| e.deadline.as_deref())
        .filter_map(parse_iso8601)
        .max();
    let timed_out = latest_deadline.map(|d| d <= now_secs).unwrap_or(false);

    if total < quorum && !timed_out {
        return None; // still pending — not enough votes, deadline not reached
    }

    let votes_for = events.iter().filter(|e| e.vote > 0).count() as u32;
    let votes_against = events.iter().filter(|e| e.vote < 0).count() as u32;
    let weighted_for: f64 = events
        .iter()
        .filter(|e| e.vote > 0)
        .map(|e| e.confidence)
        .sum();
    let weighted_against: f64 = events
        .iter()
        .filter(|e| e.vote < 0)
        .map(|e| e.confidence)
        .sum();

    let decision = if weighted_for > weighted_against {
        "Proceed"
    } else if weighted_against > weighted_for {
        "Abort"
    } else {
        "Inconclusive"
    };

    let resolved_reason = if total >= quorum {
        "quorum_reached"
    } else {
        "timeout"
    };

    Some(Resolution {
        corr_id: corr_id.to_string(),
        decision,
        votes_for,
        votes_against,
        weighted_for,
        weighted_against,
        quorum,
        resolved_reason,
    })
}

fn emit_consensus_resolved(ambient_path: &Path, r: &Resolution) -> std::io::Result<()> {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let escaped_corr = r.corr_id.replace('\\', "\\\\").replace('"', "\\\"");
    let line = format!(
        r#"{{"ts":"{ts}","kind":"consensus_resolved","corr_id":"{escaped_corr}","decision":"{decision}","votes_for":{votes_for},"votes_against":{votes_against},"weighted_for":{weighted_for:.3},"weighted_against":{weighted_against:.3},"quorum":{quorum},"resolved_reason":"{resolved_reason}"}}"#,
        decision = r.decision,
        votes_for = r.votes_for,
        votes_against = r.votes_against,
        weighted_for = r.weighted_for,
        weighted_against = r.weighted_against,
        quorum = r.quorum,
        resolved_reason = r.resolved_reason,
    );
    // scanner-anchor: "kind":"consensus_resolved"
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)?;
    writeln!(f, "{line}")
}

fn ensure_schema(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS consensus_decisions (
            corr_id          TEXT PRIMARY KEY,
            decision         TEXT NOT NULL,
            votes_for        INTEGER NOT NULL,
            votes_against    INTEGER NOT NULL,
            weighted_for     REAL NOT NULL,
            weighted_against REAL NOT NULL,
            quorum           INTEGER NOT NULL,
            resolved_reason  TEXT NOT NULL,
            resolved_at      TEXT NOT NULL,
            record_json      TEXT NOT NULL
        )",
        [],
    )?;
    Ok(())
}

fn write_state_db(conn: &Connection, r: &Resolution) -> rusqlite::Result<()> {
    let resolved_at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let record_json = format!(
        r#"{{"corr_id":{corr_id:?},"decision":{decision:?},"votes_for":{votes_for},"votes_against":{votes_against},"weighted_for":{weighted_for},"weighted_against":{weighted_against},"quorum":{quorum},"resolved_reason":{resolved_reason:?},"resolved_at":{resolved_at:?}}}"#,
        corr_id = r.corr_id,
        decision = r.decision,
        votes_for = r.votes_for,
        votes_against = r.votes_against,
        weighted_for = r.weighted_for,
        weighted_against = r.weighted_against,
        quorum = r.quorum,
        resolved_reason = r.resolved_reason,
        resolved_at = resolved_at,
    );
    conn.execute(
        "INSERT INTO consensus_decisions
            (corr_id, decision, votes_for, votes_against, weighted_for, weighted_against, quorum, resolved_reason, resolved_at, record_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(corr_id) DO UPDATE SET
            decision=excluded.decision,
            votes_for=excluded.votes_for,
            votes_against=excluded.votes_against,
            weighted_for=excluded.weighted_for,
            weighted_against=excluded.weighted_against,
            quorum=excluded.quorum,
            resolved_reason=excluded.resolved_reason,
            resolved_at=excluded.resolved_at,
            record_json=excluded.record_json",
        params![
            r.corr_id,
            r.decision,
            r.votes_for,
            r.votes_against,
            r.weighted_for,
            r.weighted_against,
            r.quorum,
            r.resolved_reason,
            resolved_at,
            record_json,
        ],
    )?;
    Ok(())
}

/// Run a single pass; returns (resolved, pending, malformed) counts.
/// Failure-class: permanent errors (state.db open/migrate failure) bubble
/// up via `Result`; a malformed ambient line is transient and just
/// counted, never fatal.
fn run_pass(cfg: &Cfg) -> anyhow::Result<(u32, u32, u32)> {
    let (votes_by_corr, already_resolved, malformed) = load_votes(&cfg.ambient_path);

    if let Some(parent) = cfg.state_db_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let conn = Connection::open(&cfg.state_db_path)
        .map_err(|e| anyhow::anyhow!("opening state.db at {:?}: {e}", cfg.state_db_path))?;
    ensure_schema(&conn)
        .map_err(|e| anyhow::anyhow!("migrating consensus_decisions table: {e}"))?;

    let now_secs = chrono::Utc::now().timestamp();
    let mut resolved_count = 0u32;
    let mut pending_count = 0u32;

    for (corr_id, events) in votes_by_corr.iter() {
        if already_resolved.contains(corr_id) {
            continue; // idempotent: already finalized in a prior pass
        }
        match maybe_resolve(corr_id, events, cfg.quorum, now_secs) {
            Some(resolution) => {
                emit_consensus_resolved(&cfg.ambient_path, &resolution)?;
                write_state_db(&conn, &resolution).map_err(|e| {
                    anyhow::anyhow!("writing consensus_decisions row for {corr_id}: {e}")
                })?;
                resolved_count += 1;
            }
            None => pending_count += 1,
        }
    }

    Ok((resolved_count, pending_count, malformed))
}

fn main() {
    let cfg = match Cfg::from_args() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[consensus-aggregator] argument error: {e}");
            std::process::exit(2);
        }
    };

    loop {
        match run_pass(&cfg) {
            Ok((resolved, pending, malformed)) => {
                eprintln!(
                    "[consensus-aggregator] pass: resolved={resolved} pending={pending} malformed={malformed}"
                );
            }
            Err(e) => {
                eprintln!("[consensus-aggregator] permanent error: {e}");
                std::process::exit(2);
            }
        }

        if cfg.once {
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(cfg.interval_secs));
    }
}
