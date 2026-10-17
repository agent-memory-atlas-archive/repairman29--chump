//! Fleet self-rescue conductor (EFFECTIVE-088 slice a).
//!
//! An autonomous loop that DETECTS a wedged fleet and DRIVES a self-rescue through
//! the consensus bus, obeying the autonomy dial + kill switch. This is the Rust
//! durable replacement for the human-run conductor — the role an Opus session had
//! to play by hand during the 2026-06-15..20 outage.
//!
//! Design (verified 2026-06-20): the consensus deliberator TALLIES correctly, but
//! there is no autonomous curator-voter population, so real proposals die at
//! NO_QUORUM. For non-halt-class SELF-RESCUE (unpause/restart — which "no solo
//! outages", CREDIBLE-090, does not forbid) the conductor PROPOSES on the bus, opens
//! an OBJECTION WINDOW, and acts UNLESS a `-1` vote vetoes. It uses the consensus bus
//! (anyone may veto) without blocking on a quorum that cannot yet form. Halt-class
//! actions are out of scope here — they still require real quorum/operator.
//!
//! Safety: dry-run by default. `--execute` arms real rescue actions. The kill switch
//! (`autonomy_level`) and the wedge-detection are both fail-closed: any uncertainty
//! resolves to "do nothing".

use std::path::{Path, PathBuf};
use std::process::Command;

/// Outcome of one conductor tick (for callers/tests).
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Halted,    // kill switch / dial = 0
    Healthy,   // no wedge detected
    Proposed,  // wedge → proposal raised (dry-run, or awaiting window)
    StoodDown, // objection vetoed the rescue
    Acted,     // rescue executed
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn al_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AUTONOMY_LEVEL_FILE") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join(".chump/AUTONOMY_LEVEL")
}

fn pause_path(repo_root: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_FLEET_PAUSE_FILE") {
        return PathBuf::from(p);
    }
    repo_root.join(".chump/fleet-paused")
}

fn ambient_path(repo_root: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        return PathBuf::from(p);
    }
    repo_root.join(".chump-locks/ambient.jsonl")
}

/// Append a `kind=...` event to ambient.jsonl. Fail-safe (best-effort).
fn emit(repo_root: &Path, kind: &str, fields: &[(&str, &str)]) {
    let ambient = ambient_path(repo_root);
    if let Some(dir) = ambient.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    map.insert(
        "source".into(),
        serde_json::Value::String("conductor".into()),
    );
    for (k, v) in fields {
        map.insert((*k).into(), serde_json::Value::String((*v).into()));
    }
    let line = serde_json::Value::Object(map).to_string();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Count open P0/P1 gaps in state.db. Read-only; 0 on any error (fail-closed).
fn pickable_p0p1(repo_root: &Path) -> i64 {
    let db = chump_gap_store::store_path::state_db_path(repo_root); // INFRA-8190
    match rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(conn) => conn
            .query_row(
                "SELECT COUNT(*) FROM gaps WHERE status='open' AND priority IN ('P0','P1')",
                [],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0),
        Err(_) => 0,
    }
}

/// Short-window lookback (minutes) for the RECENT-stall detector (RESILIENT-295).
/// The 3h window alone hides a fresh stall behind old merges: 11 merges 3h ago
/// reads HEALTHY even if the last 75 minutes shipped nothing while armed PRs pile
/// up. Default 45min per the gap evidence's suggested 30-60min range; tunable.
fn short_window_minutes() -> u64 {
    std::env::var("CHUMP_CONDUCTOR_SHORT_WINDOW_MIN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(45)
}

/// Count merges on origin/main within `since` (git's --since syntax).
/// Returns -1 when git can't answer (so the caller does not infer "wedge").
fn recent_merges(repo_root: &Path, since: &str) -> i64 {
    match Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .arg("log")
        .arg("origin/main")
        .arg("--oneline")
        .arg(format!("--since={since}"))
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).lines().count() as i64,
        _ => -1,
    }
}

/// Count `-1` (veto) votes referencing `corr` in ambient.
fn count_objections(repo_root: &Path, corr: &str) -> i64 {
    let ambient = ambient_path(repo_root);
    match std::fs::read_to_string(&ambient) {
        Ok(s) => s
            .lines()
            .filter(|l| {
                l.contains(corr)
                    && (l.contains("\"vote\":-1")
                        || l.contains("\"value\":-1")
                        || (l.contains("preference") && l.contains("-1")))
            })
            .count() as i64,
        Err(_) => 0,
    }
}

// ── EVENT_REGISTRY coverage scanner-anchor (INFRA-1237 / INFRA-1287) ─────────
// All five conductor_* kinds are emitted below via the local `emit()` helper,
// which takes the kind as a *positional argument* the coverage regex
// (scripts/ci/test-event-registry-coverage.sh) cannot see through. Anchor the
// literals here in the scanner's detectable JSON form so the register-without-emit
// (orphan) gate stays green. These are REAL emits (see the emit(...) call sites in
// tick()), not reservations — `conductor_proposed`/`conductor_dryrun` are already
// covered by the dry-run test's assertions; this anchors the other three too.
// One literal per line — the coverage scanner's extract_kinds() uses re.search
// (first match per line only), so multiple kinds on one line would miss all but
// the first:
//   "kind":"conductor_tick"
//   "kind":"conductor_proposed"
//   "kind":"conductor_dryrun"
//   "kind":"conductor_standdown"
//   "kind":"conductor_acted"
//
/// Pure wedge-detection decision (RESILIENT-295): given ground-truth counts,
/// decide the stall reason (empty = healthy). Split out from `tick()` so the
/// RECENT-stall short-window logic is unit-testable without a real git repo.
fn wedge_reason(
    merges: i64,
    merges_short: i64,
    pickable: i64,
    paused: bool,
    short_min: u64,
) -> String {
    let mut reason = String::new();
    if merges == 0 && pickable > 0 {
        reason = format!("no merges in 3h while {pickable} P0/P1 gaps pickable");
    } else if merges_short == 0 && pickable > 0 {
        // The 3h window (merges > 0) hides a RECENT stall — old merges keep the
        // long window green while the last `short_min` minutes shipped nothing
        // and gaps keep piling up pickable.
        reason = format!(
            "no merges in last {short_min}min (merges_3h={merges} is stale) while {pickable} P0/P1 gaps pickable"
        );
    }
    if paused {
        if reason.is_empty() {
            reason = "fleet-paused sentinel present".into();
        } else {
            reason.push_str("; fleet-paused sentinel present");
        }
    }
    reason
}

/// One conductor tick. `execute=false` is dry-run (default).
/// `grace_secs` is the objection window before acting (skipped in dry-run).
pub fn tick(repo_root: &Path, execute: bool, grace_secs: u64) -> Outcome {
    // 1. kill switch + autonomy dial (fail-closed)
    if !crate::autonomy_level::is_go_at(&al_path()) {
        emit(
            repo_root,
            "conductor_tick",
            &[("state", "halted"), ("reason", "autonomy_level=0")],
        );
        println!("[conductor] autonomy dial = 0 (stopped) — standing down");
        return Outcome::Halted;
    }

    // 2. detect wedge by GROUND TRUTH (CREDIBLE-090 — not detector-trust)
    let merges = recent_merges(repo_root, "3 hours ago");
    let short_min = short_window_minutes();
    let merges_short = recent_merges(repo_root, &format!("{short_min} minutes ago"));
    let pickable = pickable_p0p1(repo_root);
    let paused = pause_path(repo_root).exists();
    let reason = wedge_reason(merges, merges_short, pickable, paused, short_min);

    if reason.is_empty() {
        let m = merges.to_string();
        let ms = merges_short.to_string();
        let p = pickable.to_string();
        emit(
            repo_root,
            "conductor_tick",
            &[
                ("state", "healthy"),
                ("merges_3h", &m),
                ("merges_short", &ms),
                ("short_window_min", &short_min.to_string()),
                ("pickable", &p),
            ],
        );
        println!("[conductor] HEALTHY — merges_3h={merges}, merges_{short_min}m={merges_short}, pickable={pickable}, paused={paused}. No action.");
        return Outcome::Healthy;
    }

    // 3. propose self-rescue on the consensus bus (direct ambient emit = the store
    //    the deliberator + objection-check read; broadcast.sh fanout is best-effort)
    let corr = format!("conductor-rescue-{}", now_unix());
    let rationale = format!(
        "Self-rescue: {reason}. Action: clear stale fleet-paused + kickstart ci-health-gate. Veto with -1 within {grace_secs}s."
    );
    emit(
        repo_root,
        "proposal",
        &[
            ("corr_id", &corr),
            ("subject", &corr),
            ("rationale", &rationale),
        ],
    );
    let _ = Command::new("bash")
        .arg(repo_root.join("scripts/coord/broadcast.sh"))
        .arg("--corr-id")
        .arg(&corr)
        .arg("FEEDBACK")
        .arg("proposal")
        .arg(&corr)
        .arg(&rationale)
        .current_dir(repo_root)
        .output(); // best-effort NATS/inbox fanout; missing script is fine
    emit(
        repo_root,
        "conductor_proposed",
        &[("corr_id", &corr), ("reason", &reason)],
    );
    println!("[conductor] WEDGE: {reason} — proposed self-rescue (corr={corr})");

    // 4 & 5. Objection window + act — only when EXECUTING.
    // In dry-run there is no real objection window (we never wait for votes),
    // so counting objections 0s after posting is meaningless AND non-deterministic
    // on a live host: count_objections can observe a *concurrent* conductor's
    // votes, or a same-second `now_unix()` corr_id collision, and return >0. That
    // flaked `wedge_via_pause_dryrun_does_not_act` (~40% of cargo-test runs) and
    // blocked innocent PRs. A dry-run just proposes + reports — there is nothing
    // to veto because nothing is acted on.
    if execute {
        if grace_secs > 0 {
            std::thread::sleep(std::time::Duration::from_secs(grace_secs));
        }
        let objections = count_objections(repo_root, &corr);
        if objections > 0 {
            let o = objections.to_string();
            emit(
                repo_root,
                "conductor_standdown",
                &[("corr_id", &corr), ("objections", &o)],
            );
            println!("[conductor] {objections} objection(s) — standing down (veto respected)");
            return Outcome::StoodDown;
        }
        let pp = pause_path(repo_root);
        if pp.exists() {
            let bak = pp.with_file_name(format!(
                "{}.conductor-cleared-{}",
                pp.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("fleet-paused"),
                now_unix()
            ));
            let _ = std::fs::rename(&pp, &bak);
        }
        let uid = Command::new("id")
            .arg("-u")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        if !uid.is_empty() {
            let _ = Command::new("launchctl")
                .arg("kickstart")
                .arg(format!("gui/{uid}/com.chump.ci-health-gate"))
                .status();
        }
        emit(
            repo_root,
            "conductor_acted",
            &[
                ("corr_id", &corr),
                ("action", "cleared_pause+kicked_gate"),
                ("reason", &reason),
            ],
        );
        println!("[conductor] no objection — self-rescue EXECUTED");
        Outcome::Acted
    } else {
        emit(
            repo_root,
            "conductor_dryrun",
            &[
                ("corr_id", &corr),
                ("would", "clear_pause+kick_gate"),
                ("reason", &reason),
            ],
        );
        println!("[conductor] DRY-RUN (use --execute to arm): would clear pause + kick ci-health-gate. No action taken.");
        Outcome::Proposed
    }
}

/// Resolve the repo root (env override → cwd).
fn resolve_repo_root() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(p);
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// CLI entry: `chump self-rescue-loop [--execute] [--grace-secs N]`.
pub fn run(args: &[String]) -> i32 {
    let repo_root = resolve_repo_root();
    let repo_root = repo_root.as_path();
    let execute = args.iter().any(|a| a == "--execute");
    let grace_secs = args
        .iter()
        .position(|a| a == "--grace-secs")
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse::<u64>().ok())
        .or_else(|| {
            std::env::var("CHUMP_CONDUCTOR_GRACE_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(300);
    match tick(repo_root, execute, grace_secs) {
        Outcome::Halted | Outcome::Healthy | Outcome::Proposed | Outcome::Acted => 0,
        Outcome::StoodDown => 0, // a respected veto is a successful tick, not an error
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial; // env-var mutating tests must not run in parallel

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "chump-conductor-test-{}-{:?}",
            now_unix(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(d.join(".chump")).unwrap();
        std::fs::create_dir_all(d.join(".chump-locks")).unwrap();
        d
    }

    fn set_dial(root: &Path, level: &str) {
        let al = root.join(".chump/AUTONOMY_LEVEL");
        std::fs::write(&al, level).unwrap();
        std::env::set_var("CHUMP_AUTONOMY_LEVEL_FILE", &al);
    }

    #[test]
    fn recent_stall_hidden_by_3h_window_is_still_flagged() {
        // RESILIENT-295: merges_3h=11 (old merges keep the long window green)
        // but merges_short=0 in the last 45min while gaps are pickable — the
        // conductor must NOT report healthy here.
        let reason = wedge_reason(11, 0, 8, false, 45);
        assert!(
            !reason.is_empty(),
            "3h window hid a recent stall — conductor stayed silent"
        );
        assert!(reason.contains("45min"));
        assert!(reason.contains("merges_3h=11"));
    }

    #[test]
    fn healthy_when_both_windows_show_merges() {
        let reason = wedge_reason(11, 2, 8, false, 45);
        assert!(
            reason.is_empty(),
            "both windows healthy but flagged: {reason}"
        );
    }

    #[test]
    fn long_window_zero_still_takes_priority_reason() {
        // merges=0 in 3h already wedges via the original detector; the message
        // should stay the original (simpler) phrasing, not the short-window one.
        let reason = wedge_reason(0, 0, 3, false, 45);
        assert!(reason.contains("no merges in 3h"));
    }

    #[test]
    fn no_pickable_gaps_means_healthy_even_if_short_window_zero() {
        let reason = wedge_reason(11, 0, 0, false, 45);
        assert!(reason.is_empty(), "no pickable gaps but flagged: {reason}");
    }

    #[test]
    #[serial]
    fn dial_zero_halts() {
        let root = tmp();
        set_dial(&root, "0");
        std::env::set_var("CHUMP_AMBIENT_LOG", root.join(".chump-locks/amb.jsonl"));
        let out = tick(&root, false, 0);
        assert_eq!(out, Outcome::Halted);
        let amb = std::fs::read_to_string(root.join(".chump-locks/amb.jsonl")).unwrap_or_default();
        assert!(amb.contains("\"state\":\"halted\""));
        std::env::remove_var("CHUMP_AUTONOMY_LEVEL_FILE");
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    #[serial]
    fn wedge_via_pause_dryrun_does_not_act() {
        let root = tmp();
        set_dial(&root, "5");
        let pause = root.join(".chump/fleet-paused");
        std::fs::write(&pause, "{\"kind\":\"slo_breach\"}").unwrap();
        std::env::set_var("CHUMP_FLEET_PAUSE_FILE", &pause);
        std::env::set_var("CHUMP_AMBIENT_LOG", root.join(".chump-locks/amb2.jsonl"));
        let out = tick(&root, false, 0); // dry-run
        assert_eq!(out, Outcome::Proposed);
        // dry-run must NOT remove the pause sentinel
        assert!(pause.exists(), "dry-run cleared the pause file — must not");
        let amb = std::fs::read_to_string(root.join(".chump-locks/amb2.jsonl")).unwrap_or_default();
        assert!(amb.contains("\"kind\":\"conductor_proposed\""));
        assert!(amb.contains("\"kind\":\"conductor_dryrun\""));
        std::env::remove_var("CHUMP_AUTONOMY_LEVEL_FILE");
        std::env::remove_var("CHUMP_FLEET_PAUSE_FILE");
        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }
}
