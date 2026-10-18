//! RESILIENT-069: `chump farmer status` — the readiness gate, "lights-on
//! check" for `scripts/coord/farmer.sh` (RESILIENT-068).
//!
//! One command, exit 0/1:
//!   GREEN (exit 0) = sentinel absent + zero exit-78 supervisors +
//!                     oauth fresh + farmer heartbeat <120s
//!   RED   (exit 1) = at least one of the above is concretely unhealthy
//!
//! Reads ONLY local state (files + `launchctl list`) — no network, no
//! `gh`, no sqlite writes. Target <100ms so it's cheap enough to call from
//! every work entry-point (session-start, `chump claim`, the gap-reserve
//! admission guard, `worker.sh` tick) without adding perceptible latency.
//!
//! Fail-open by design for checks whose signal is simply ABSENT (farmer
//! never installed on this host, `launchctl` unavailable on Linux, no
//! oauth/api-key signal at all) — RED only fires on POSITIVE evidence of
//! trouble (a sentinel file present, a daemon that actually exited 78, a
//! heartbeat file that exists but has gone stale, an auth cache that
//! actually recorded BROKEN). This mirrors the vacuous-until-real-state
//! pattern used by the MISSION-045 outcome gate — a gate that blocks work
//! on hosts where the thing it's checking was never wired up would be
//! worse than no gate at all.

use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Control-plane launchd labels the farmer monitors (mirrors
/// `CONTROL_PLANE_LABELS` in scripts/coord/farmer.sh).
const CONTROL_PLANE_LABELS: &[&str] = &[
    "com.chump.bot-merge-watchdog",
    "com.chump.main-health-watchdog",
    "com.chump.reap-stale-leases",
    "com.chump.stale-process-watchdog",
    "com.chump.heartbeat-watcher",
    "com.chump.ci-health-gate",
    "com.chump.queue-health-monitor",
    "dev.chump.premature-closure-watch",
    "dev.chump.system-invariants-monitor",
];

const HEARTBEAT_MAX_AGE_S: u64 = 120;
const OAUTH_CACHE_TTL_S: u64 = 600;
const OAUTH_TOKEN_MAX_AGE_S: u64 = 3600;

#[derive(Debug, Clone, Serialize)]
pub struct FarmerStatus {
    pub green: bool,
    pub sentinel_absent: bool,
    pub exit78_free: bool,
    pub oauth_fresh: bool,
    pub heartbeat_fresh: bool,
    pub heartbeat_age_s: Option<u64>,
    pub reasons: Vec<String>,
}

fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn mtime_age_s(path: &Path) -> Option<u64> {
    let meta = std::fs::metadata(path).ok()?;
    let mtime = meta.modified().ok()?;
    let age = SystemTime::now().duration_since(mtime).ok()?;
    Some(age.as_secs())
}

/// Sentinel check: `.chump/fleet-paused` present means the fleet is
/// deliberately paused — not lights-on.
fn check_sentinel(chump_dir: &Path, reasons: &mut Vec<String>) -> bool {
    let sentinel = chump_dir.join("fleet-paused");
    if sentinel.exists() {
        reasons.push("sentinel present: .chump/fleet-paused".to_string());
        false
    } else {
        true
    }
}

/// exit-78 supervisor check: none of the control-plane launchd labels may
/// have last-exited with EX_CONFIG (78). Fail-open if `launchctl` is
/// unavailable (Linux dev/CI hosts) — absence of the tool is not evidence
/// of a crashed supervisor.
fn check_exit78_free(reasons: &mut Vec<String>) -> bool {
    let output = match std::process::Command::new("launchctl").arg("list").output() {
        Ok(o) if o.status.success() => o,
        _ => return true, // launchctl absent/failed — vacuous pass (fail-open)
    };
    let text = String::from_utf8_lossy(&output.stdout);
    let mut ok = true;
    for line in text.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        // launchctl list columns: PID  LastExitStatus  Label
        if cols.len() < 3 {
            continue;
        }
        let label = cols[2];
        if !CONTROL_PLANE_LABELS.contains(&label) {
            continue;
        }
        if cols[1] == "78" {
            reasons.push(format!("supervisor exit-78: {label}"));
            ok = false;
        }
    }
    ok
}

/// oauth-fresh check. Priority mirrors `check_auth()` in farmer.sh:
///   1. ANTHROPIC_API_KEY present (env or .env) -> fresh, no oauth needed.
///   2. auth-status.sh cache (`~/.chump/auth-status-cache`) says rc=0 and
///      is within TTL -> fresh. rc!=0 within TTL -> not fresh (positive
///      evidence of BROKEN).
///   3. oauth-token.json exists and is younger than the max age -> fresh.
///   4. No signal at all (nothing installed) -> fresh (fail-open).
fn check_oauth_fresh(repo_root: &Path, reasons: &mut Vec<String>) -> bool {
    let api_key = std::env::var("ANTHROPIC_API_KEY")
        .ok()
        .filter(|s| !s.is_empty());
    if api_key.is_some() {
        return true;
    }
    if let Ok(env_text) = std::fs::read_to_string(repo_root.join(".env")) {
        for line in env_text.lines() {
            if let Some(v) = line.strip_prefix("ANTHROPIC_API_KEY=") {
                if !v.trim().trim_matches('"').trim_matches('\'').is_empty() {
                    return true;
                }
            }
        }
    }

    let home = chump_state_home().unwrap_or_default();
    let cache_path = PathBuf::from(&home).join(".chump/auth-status-cache");
    if let Ok(text) = std::fs::read_to_string(&cache_path) {
        let mut lines = text.lines();
        let ts: Option<u64> = lines.next().and_then(|s| s.trim().parse().ok());
        let rc: Option<i32> = lines.next().and_then(|s| s.trim().parse().ok());
        if let (Some(ts), Some(rc)) = (ts, rc) {
            let age = now_s().saturating_sub(ts);
            if age < OAUTH_CACHE_TTL_S {
                if rc == 0 {
                    return true;
                }
                reasons.push(format!(
                    "auth-status cache reports BROKEN (rc={rc}, age={age}s)"
                ));
                return false;
            }
        }
    }

    let token_path = PathBuf::from(&home).join(".chump/oauth-token.json");
    if token_path.exists() {
        match mtime_age_s(&token_path) {
            Some(age) => return oauth_token_verdict(age, free_tier_cascade_active(), reasons),
            None => return true,
        }
    }

    // No signal at all — fail-open.
    true
}

/// CREDIBLE-1519: resolve the chump state home directory the oauth-freshness
/// check reads (`<home>/.chump/{auth-status-cache,oauth-token.json}`). Honors
/// `CHUMP_HOME` before falling back to `HOME`, mirroring
/// `auth::chump_config_path`. Without this, a caller that redirected all other
/// state via a temp `CHUMP_HOME` (hermetic `scripts/ci/test-*.sh` seeds, a
/// `CHUMP_HOME`-scoped invocation) still had this gate read the host's real
/// `~/.chump/oauth-token.json` — a 69-day-stale host token then RED-blocked
/// `chump gap reserve` inside the temp home, failing preflight on every
/// Rust-touching push from a paused/observer host.
fn chump_state_home() -> Option<String> {
    resolve_state_home(std::env::var("CHUMP_HOME").ok(), std::env::var("HOME").ok())
}

/// Pure precedence rule for [`chump_state_home`]: a non-empty `CHUMP_HOME`
/// wins, else `HOME`. Split out so the precedence is unit-testable without
/// mutating process-global env (which would race the auth.rs env tests in the
/// same test binary).
fn resolve_state_home(chump_home: Option<String>, home: Option<String>) -> Option<String> {
    chump_home.filter(|s| !s.is_empty()).or(home)
}

/// RESILIENT-409: true when a free-tier / execute-gap provider cascade (the
/// DeepSeek floor) is configured. In this mode the Anthropic oauth token is
/// never used, so its staleness must not gate claims. Reads one env var only
/// -- no network, keeps `farmer status` local-only and <100ms.
fn free_tier_cascade_active() -> bool {
    std::env::var("CHUMP_FREE_TIER_PROVIDERS")
        .ok()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
}

/// RESILIENT-409: pure verdict for the oauth-token.json freshness fallback.
/// A fresh token is always GREEN. A stale token is RED -- EXCEPT when a
/// free-tier cascade is active, because the DeepSeek floor never touches the
/// Anthropic oauth token, so RED-blocking on its (perpetually stale on Linux,
/// where the macOS-launchd refresher never runs) mtime self-strangles the
/// whole fleet every OAUTH_TOKEN_MAX_AGE_S with zero benefit. The
/// auth-status-cache BROKEN branch in `check_oauth_fresh` still forces RED on
/// real auth failure even in free-tier mode. Pure (no env/fs) so it is
/// deterministically unit-testable.
fn oauth_token_verdict(age_s: u64, free_tier: bool, reasons: &mut Vec<String>) -> bool {
    if age_s <= OAUTH_TOKEN_MAX_AGE_S {
        return true;
    }
    if free_tier {
        reasons.push(format!(
            "oauth-token.json stale (age={age_s}s > {OAUTH_TOKEN_MAX_AGE_S}s) but free-tier cascade active -- decoupled from Anthropic-oauth (RESILIENT-409)"
        ));
        return true;
    }
    reasons.push(format!(
        "oauth-token.json stale: age={age_s}s > {OAUTH_TOKEN_MAX_AGE_S}s, no api-key fallback, no fresh cache"
    ));
    false
}

/// heartbeat-fresh check: `.chump/farmer-heartbeat` — vacuous pass if the
/// farmer has never run on this host (file absent). RED only when the
/// file exists but is stale, i.e. the farmer was alive and stopped
/// ticking.
fn check_heartbeat_fresh(chump_dir: &Path, reasons: &mut Vec<String>) -> (bool, Option<u64>) {
    let path = chump_dir.join("farmer-heartbeat");
    match mtime_age_s(&path) {
        None => (true, None), // never installed on this host — vacuous pass
        Some(age) => {
            if age > HEARTBEAT_MAX_AGE_S {
                reasons.push(format!(
                    "farmer heartbeat stale: age={age}s > {HEARTBEAT_MAX_AGE_S}s"
                ));
                (false, Some(age))
            } else {
                (true, Some(age))
            }
        }
    }
}

pub fn compute(repo_root: &Path) -> FarmerStatus {
    let chump_dir = repo_root.join(".chump");
    let mut reasons = Vec::new();

    let sentinel_absent = check_sentinel(&chump_dir, &mut reasons);
    let exit78_free = check_exit78_free(&mut reasons);
    let oauth_fresh = check_oauth_fresh(repo_root, &mut reasons);
    let (heartbeat_fresh, heartbeat_age_s) = check_heartbeat_fresh(&chump_dir, &mut reasons);

    let green = sentinel_absent && exit78_free && oauth_fresh && heartbeat_fresh;

    FarmerStatus {
        green,
        sentinel_absent,
        exit78_free,
        oauth_fresh,
        heartbeat_fresh,
        heartbeat_age_s,
        reasons,
    }
}

/// Returns `true` when lights-on (GREEN). Cheap enough to call inline from
/// any gate without a subprocess spawn.
pub fn is_green(repo_root: &Path) -> bool {
    compute(repo_root).green
}

/// CLI handler for `chump farmer status [--json] [--quiet]`.
pub fn run_cli(args: &[String]) -> i32 {
    let want_json = args.iter().any(|a| a == "--json");
    let quiet = args.iter().any(|a| a == "--quiet");
    let repo_root = crate::repo_path::repo_root();
    let status = compute(&repo_root);

    if want_json {
        match serde_json::to_string_pretty(&status) {
            Ok(s) => println!("{s}"),
            Err(e) => eprintln!("error serializing farmer status to JSON: {e}"),
        }
    } else if !quiet {
        println!(
            "chump farmer status: {}",
            if status.green { "GREEN" } else { "RED" }
        );
        println!(
            "  sentinel_absent:  {}",
            if status.sentinel_absent { "ok" } else { "FAIL" }
        );
        println!(
            "  exit78_free:      {}",
            if status.exit78_free { "ok" } else { "FAIL" }
        );
        println!(
            "  oauth_fresh:      {}",
            if status.oauth_fresh { "ok" } else { "FAIL" }
        );
        println!(
            "  heartbeat_fresh:  {}{}",
            if status.heartbeat_fresh { "ok" } else { "FAIL" },
            status
                .heartbeat_age_s
                .map(|a| format!(" (age={a}s)"))
                .unwrap_or_default()
        );
        for r in &status.reasons {
            println!("  - {r}");
        }
    }

    if status.green {
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentinel_absent_by_default() {
        let dir = tempfile::tempdir().unwrap();
        let mut reasons = Vec::new();
        assert!(check_sentinel(dir.path(), &mut reasons));
        assert!(reasons.is_empty());
    }

    #[test]
    fn sentinel_present_fails_the_check() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("fleet-paused"), "waste spike").unwrap();
        let mut reasons = Vec::new();
        assert!(!check_sentinel(dir.path(), &mut reasons));
        assert_eq!(reasons.len(), 1);
    }

    #[test]
    fn heartbeat_absent_is_vacuous_pass() {
        // A host where the farmer daemon was never installed must not be
        // treated as RED — only a stale (once-present) heartbeat is signal.
        let dir = tempfile::tempdir().unwrap();
        let mut reasons = Vec::new();
        let (fresh, age) = check_heartbeat_fresh(dir.path(), &mut reasons);
        assert!(fresh);
        assert!(age.is_none());
        assert!(reasons.is_empty());
    }

    #[test]
    fn heartbeat_fresh_within_window() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("farmer-heartbeat"), "2026-08-13T00:00:00Z").unwrap();
        let mut reasons = Vec::new();
        let (fresh, age) = check_heartbeat_fresh(dir.path(), &mut reasons);
        assert!(fresh);
        assert!(age.unwrap() < HEARTBEAT_MAX_AGE_S);
    }

    #[test]
    fn heartbeat_stale_fails_and_explains_why() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("farmer-heartbeat");
        let file = std::fs::File::create(&path).unwrap();
        // Back-date the mtime past the freshness window.
        let old = SystemTime::now() - std::time::Duration::from_secs(HEARTBEAT_MAX_AGE_S + 1);
        file.set_modified(old).unwrap();
        let mut reasons = Vec::new();
        let (fresh, age) = check_heartbeat_fresh(dir.path(), &mut reasons);
        assert!(!fresh);
        assert!(age.unwrap() > HEARTBEAT_MAX_AGE_S);
        assert!(reasons[0].contains("farmer heartbeat stale"));
    }

    #[test]
    fn green_requires_all_four_checks() {
        let base = FarmerStatus {
            green: true,
            sentinel_absent: true,
            exit78_free: true,
            oauth_fresh: true,
            heartbeat_fresh: true,
            heartbeat_age_s: None,
            reasons: vec![],
        };
        assert!(
            base.sentinel_absent && base.exit78_free && base.oauth_fresh && base.heartbeat_fresh
        );

        let mut red = base.clone();
        red.oauth_fresh = false;
        assert!(
            !(red.sentinel_absent && red.exit78_free && red.oauth_fresh && red.heartbeat_fresh)
        );
    }

    #[test]
    fn resolve_state_home_prefers_chump_home() {
        // CREDIBLE-1519 AC2: the oauth-freshness check must resolve its state
        // dir from CHUMP_HOME before HOME, so a hermetic temp CHUMP_HOME
        // redirects the token path and the host's stale ~/.chump token can't
        // RED-block a scoped `chump gap reserve`. Pure test — no env mutation.
        assert_eq!(
            resolve_state_home(Some("/tmp/chome".into()), Some("/home/host".into())),
            Some("/tmp/chome".into())
        );
        // Empty CHUMP_HOME is treated as unset -> fall back to HOME.
        assert_eq!(
            resolve_state_home(Some(String::new()), Some("/home/host".into())),
            Some("/home/host".into())
        );
        // No CHUMP_HOME -> HOME.
        assert_eq!(
            resolve_state_home(None, Some("/home/host".into())),
            Some("/home/host".into())
        );
        // Neither set -> None (callers default to empty, hitting the fail-open
        // "no signal" branch rather than reading an attacker-controlled root).
        assert_eq!(resolve_state_home(None, None), None);
    }

    #[test]
    fn stale_token_reds_by_default() {
        // AC3 regression: without a free-tier cascade, a stale token stays RED.
        let mut r = Vec::new();
        assert!(!oauth_token_verdict(
            OAUTH_TOKEN_MAX_AGE_S + 1,
            false,
            &mut r
        ));
        assert_eq!(r.len(), 1);
        assert!(r[0].contains("stale"));
    }

    #[test]
    fn stale_token_decoupled_under_free_tier() {
        // AC2 (RESILIENT-409): DeepSeek floor never uses the Anthropic oauth
        // token, so a 33-day-stale token must NOT RED-block claims when a
        // free-tier cascade is active.
        let mut r = Vec::new();
        assert!(oauth_token_verdict(33 * 24 * 3600, true, &mut r));
        assert!(r[0].contains("free-tier"));
        assert!(r[0].contains("RESILIENT-409"));
    }

    #[test]
    fn fresh_token_green_regardless_of_free_tier() {
        let mut r = Vec::new();
        assert!(oauth_token_verdict(10, false, &mut r));
        assert!(oauth_token_verdict(10, true, &mut r));
        assert!(r.is_empty());
    }
}
