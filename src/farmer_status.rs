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
    /// RESILIENT-1636: the node was deliberately paused (`chump node pause` /
    /// `CHUMP_NODE_MODE=paused`). A paused farmer is NOT lights-on (`green`
    /// stays false, so NEW claims are still refused), but its stale heartbeat
    /// is EXPECTED, not a malfunction — so it is reported as PAUSED, not stale.
    pub paused: bool,
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

/// oauth-fresh check. RESILIENT-1636: this gate must validate the credential
/// path `claude -p` ACTUALLY uses on the host, NOT the macOS-only
/// `~/.chump/oauth-token.json` Keychain mirror's mtime. On a Linux node the
/// mirror refresher never runs (`oauth-token-refresh.sh` is macOS-Keychain
/// only → `kind=oauth_refresh_unsupported_platform`), so a stale mirror is a
/// FALSE death signal while `claude -p` authenticates fine from its own
/// credentials all day. Presence/mtime is not validity (RESILIENT-086); the
/// authority for a BROKEN verdict is `auth-status.sh`'s probed cache
/// (CREDIBLE-147, the six-day June outage).
///
/// Priority (first positive/negative signal wins; RED requires POSITIVE evidence):
///   1. ANTHROPIC_API_KEY present (env or .env) -> fresh, no oauth needed.
///   2. auth-status.sh VALIDITY cache (`~/.chump/auth-status-cache`) says rc=0
///      within TTL -> fresh; rc!=0 within TTL -> RED (probed BROKEN).
///   3. free-tier cascade active (RESILIENT-409) -> Anthropic oauth unused -> fresh.
///   4. the credential path `claude -p` uses, `$HOME/.claude/.credentials.json`:
///        * valid / expired-but-refreshable token (`Some(true)`) -> fresh;
///        * expired, non-refreshable token (`Some(false)`) -> RED (the restored
///          `stale_token_reds_by_default` invariant: an actually-dead credential
///          must still refuse, paused or not);
///        * no token / unparseable (`None`) -> fall through.
///        * NOTE (RESILIENT-1636): there is NO presence-only
///          `CLAUDE_CODE_OAUTH_TOKEN` shortcut — a token env var being *set* is
///          not evidence it is *valid* (RESILIENT-086). The cache rc=0 branch
///          (step 2) is the only "a probe said the token works" fresh path.
///   5. `~/.chump/oauth-token.json` Keychain mirror — consulted ONLY as a
///      last-resort fallback when steps 1-4 produced no signal (no api key, no
///      cache, no free-tier, no `.credentials.json` token at all). A stale
///      mirror reds here (preserving the old default), but a valid
///      `.credentials.json` in step 4 short-circuits FIRST, so a stale mirror
///      never reds a node whose `claude -p` creds are good (the cuphead case).
///   6. No positive signal of trouble -> fresh (fail-open).
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
        if let Some(verdict) = auth_status_cache_verdict(&text, now_s(), reasons) {
            return verdict;
        }
    }

    // RESILIENT-409: DeepSeek floor never touches the Anthropic oauth token.
    if free_tier_cascade_active() {
        return true;
    }

    // RESILIENT-1636: validate the credential path `claude -p` actually uses.
    // Some(true) => usable; Some(false) => actually-dead creds, RED (restores the
    // stale_token_reds_by_default pin); None => no token, fall through.
    let creds_path = PathBuf::from(&home).join(".claude/.credentials.json");
    if let Ok(body) = std::fs::read_to_string(&creds_path) {
        match claude_creds_verdict(&body, now_ms()) {
            Some(true) => return true,
            Some(false) => {
                reasons.push(
                    "~/.claude/.credentials.json token expired with no refresh token \
                     (claude -p cannot authenticate)"
                        .to_string(),
                );
                return false;
            }
            None => {}
        }
    }

    // RESILIENT-1636: last-resort fallback — the macOS Keychain mirror's mtime.
    // Only reached when NOTHING above gave a signal (no api key / cache / free-tier
    // / `.credentials.json` token). A stale mirror reds here (preserving the old
    // default), but a node with valid `.credentials.json` never gets this far.
    let token_path = PathBuf::from(&home).join(".chump/oauth-token.json");
    if token_path.exists() {
        match mtime_age_s(&token_path) {
            Some(age) => return oauth_token_verdict(age, free_tier_cascade_active(), reasons),
            None => return true,
        }
    }

    // No positive signal of trouble — fail-open (RED only on probed BROKEN above).
    true
}

/// RESILIENT-1636: pure verdict for the auth-status.sh VALIDITY cache body
/// (`<home>/.chump/auth-status-cache`, two lines: epoch-seconds then rc). Split
/// out so "rc!=0 within TTL => RED" is deterministically unit-testable without
/// mutating process-global env. `Some(true)` = probed rc=0 within TTL (fresh),
/// `Some(false)` = probed rc!=0 within TTL (RED, BROKEN), `None` = stale /
/// malformed (caller continues to the next signal).
fn auth_status_cache_verdict(text: &str, now: u64, reasons: &mut Vec<String>) -> Option<bool> {
    let mut lines = text.lines();
    let ts: Option<u64> = lines.next().and_then(|s| s.trim().parse().ok());
    let rc: Option<i32> = lines.next().and_then(|s| s.trim().parse().ok());
    if let (Some(ts), Some(rc)) = (ts, rc) {
        let age = now.saturating_sub(ts);
        if age < OAUTH_CACHE_TTL_S {
            if rc == 0 {
                return Some(true);
            }
            reasons.push(format!(
                "auth-status cache reports BROKEN (rc={rc}, age={age}s)"
            ));
            return Some(false);
        }
    }
    None
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

/// RESILIENT-1636: pure validity verdict for Claude Code's credential store
/// (`~/.claude/.credentials.json`), the path `claude -p` actually reads. This
/// is a VALIDITY check (token present + expiry in the future, or expired but
/// refreshable), NOT a presence/mtime check (RESILIENT-086). Pure (no fs/env)
/// so it is deterministically unit-testable.
///
/// Returns `Some(true)` when a usable token is present and not-expired (or
/// expired-but-refreshable); `Some(false)` when the access token is expired
/// with no refresh token; `None` when there is no token at all / unparseable
/// (caller falls through to the fail-open branch).
fn claude_creds_verdict(content: &str, now_ms: i64) -> Option<bool> {
    let v: serde_json::Value = serde_json::from_str(content).ok()?;
    // Claude Code nests under `claudeAiOauth`; tolerate a flat shape too.
    let oauth = v.get("claudeAiOauth").unwrap_or(&v);
    // A usable access token must be present under one of the known key names.
    let _token = ["accessToken", "access_token", "token"]
        .iter()
        .find_map(|k| {
            oauth
                .get(*k)
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
        })?;
    // expiresAt is epoch millis (a JSON number or a numeric string).
    let expires = oauth.get("expiresAt").and_then(|x| {
        x.as_i64()
            .or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))
    });
    match expires {
        Some(exp) if exp > now_ms => Some(true), // valid, not yet expired
        Some(_) => {
            // Access token expired — usable iff a refresh token exists, which
            // Claude Code uses to mint a fresh token on the next call.
            let refreshable = oauth
                .get("refreshToken")
                .and_then(|x| x.as_str())
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            Some(refreshable)
        }
        None => Some(true), // token present, no expiry field — treat as usable
    }
}

/// RESILIENT-1636: milliseconds since the Unix epoch (for the ms-precision
/// `expiresAt` in `~/.claude/.credentials.json`).
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
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

/// heartbeat-fresh check: `.chump/farmer-heartbeat` — vacuous pass if the
/// farmer has never run on this host (file absent). RED only when the
/// file exists but is stale, i.e. the farmer was alive and stopped
/// ticking.
///
/// RESILIENT-1636: the reason text is pushed by [`compute`] (not here), so a
/// node paused by owner decision reports the staleness as PAUSED rather than
/// as a malfunction. This helper returns the pure (fresh, age) verdict.
fn heartbeat_verdict(chump_dir: &Path) -> (bool, Option<u64>) {
    let path = chump_dir.join("farmer-heartbeat");
    match mtime_age_s(&path) {
        None => (true, None), // never installed on this host — vacuous pass
        Some(age) => (age <= HEARTBEAT_MAX_AGE_S, Some(age)),
    }
}

/// Node-mode pause detection (RESILIENT-1636 / RESILIENT-1614). A node paused
/// via `chump node pause` writes `CHUMP_NODE_MODE=paused` to `node.env`; the
/// env var may also be exported directly. A paused node's stale heartbeat is
/// EXPECTED (the farmer is deliberately idle), so it is reported as PAUSED.
fn node_is_paused() -> bool {
    if let Ok(m) = std::env::var("CHUMP_NODE_MODE") {
        let m = m.trim();
        if m == "paused" {
            return true;
        }
        if !m.is_empty() {
            return false; // explicit non-paused mode wins over the file
        }
    }
    // node.env lives at CHUMP_STATE_DIR (if set) else <state-home>/.chump, the
    // same resolution `chump node pause` uses in node_mode.rs.
    let state_dir = std::env::var("CHUMP_STATE_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| chump_state_home().map(|h| PathBuf::from(h).join(".chump")));
    if let Some(dir) = state_dir {
        if let Ok(body) = std::fs::read_to_string(dir.join("node.env")) {
            return node_env_is_paused(&body);
        }
    }
    false
}

/// Pure parse of a `node.env` body for `CHUMP_NODE_MODE=paused` (with or
/// without the `export ` prefix node_mode.rs writes). Split out for unit tests.
fn node_env_is_paused(content: &str) -> bool {
    content.lines().any(|l| {
        let t = l.trim().trim_start_matches("export ").trim();
        t == "CHUMP_NODE_MODE=paused"
    })
}

pub fn compute(repo_root: &Path) -> FarmerStatus {
    let chump_dir = repo_root.join(".chump");
    let mut reasons = Vec::new();

    let sentinel_absent = check_sentinel(&chump_dir, &mut reasons);
    let exit78_free = check_exit78_free(&mut reasons);
    let oauth_fresh = check_oauth_fresh(repo_root, &mut reasons);
    let (heartbeat_fresh, heartbeat_age_s) = heartbeat_verdict(&chump_dir);
    let paused = node_is_paused();

    // RESILIENT-1636: a paused node's stale heartbeat is expected — report it
    // as PAUSED, not as a stale-farmer malfunction. A truly-stale heartbeat on
    // an UN-paused node keeps the original RED reason.
    if paused {
        let agenote = heartbeat_age_s
            .map(|a| format!(" (heartbeat age={a}s, staleness expected while paused)"))
            .unwrap_or_default();
        reasons.push(format!(
            "farmer paused by node mode (CHUMP_NODE_MODE=paused){agenote}"
        ));
    } else if !heartbeat_fresh {
        reasons.push(format!(
            "farmer heartbeat stale: age={}s > {HEARTBEAT_MAX_AGE_S}s",
            heartbeat_age_s.unwrap_or(0)
        ));
    }

    // A paused node is NOT lights-on: green stays false so NEW claims are still
    // refused (the gate must not be weakened). The re-entry admission for
    // already-claimed work lives in `claim_admission`, not here.
    let green = sentinel_absent && exit78_free && oauth_fresh && heartbeat_fresh && !paused;

    FarmerStatus {
        green,
        sentinel_absent,
        exit78_free,
        oauth_fresh,
        heartbeat_fresh,
        heartbeat_age_s,
        paused,
        reasons,
    }
}

/// RESILIENT-1636: the farmer gate's admission verdict for `chump claim`.
///
/// The gate must refuse NEW worker claims when the farmer is not lights-on,
/// but must NOT refuse the ship step of work a dispatch/chain lane ALREADY
/// claimed (bot-merge re-invokes `chump claim` to re-enter the worktree whose
/// lease the dispatch already holds — on a paused node that re-claim was dying
/// at the gate, so every dispatch shipped only through salvage).
#[derive(Debug)]
pub enum ClaimAdmission {
    /// Farmer lights-on — admit normally.
    Green,
    /// Farmer not lights-on, but the current session already holds a live lease
    /// for this gap: re-entry of already-admitted work. Carries a note printed
    /// to stdout so bot-merge / `chump dispatch` can surface the reason.
    ReentryAdmit { note: String },
    /// Farmer not lights-on and this is a NEW claim (no live lease held by the
    /// current session for this gap) — refused. Carries the status for reasons.
    Refuse { status: FarmerStatus },
}

/// Decide whether `chump claim <gap>` may proceed under the current farmer
/// state. `session_id` is the dispatch/worker session (from `CHUMP_SESSION_ID`);
/// when it already holds a live lease for `gap_id` the claim is a re-entry and
/// is admitted even on a RED/paused farmer. A new claim (no such lease) is
/// still refused — the gate is not weakened.
pub fn claim_admission(repo_root: &Path, gap_id: &str, session_id: Option<&str>) -> ClaimAdmission {
    let mut status = compute(repo_root);
    let reentry_session = session_id.map(str::trim).filter(|s| !s.is_empty());

    // RESILIENT-1636 (optional item 6): scan every lock dir a dispatch's
    // lease-only claim may have written — CHUMP_LOCK_DIR, plus the repo and
    // cwd-worktree `.chump-locks` — so the re-entry admission fires on cuphead
    // regardless of which root the dispatch resolved.
    let verdict = reentry_session
        .map(|sess| classify_session_lease_in_dirs(&lease_lock_dirs(repo_root), gap_id, sess))
        .unwrap_or(LeaseVerdict::NotLive);

    // CHIEF RULE 8: a matching lease whose expires_at is missing/unparseable is
    // MALFORMED (not live) and refuses with its own distinct reason.
    if matches!(verdict, LeaseVerdict::Malformed) {
        status.reasons.push(format!(
            "lease malformed: missing or unparseable expires_at for {gap_id} \
             — treating as not-live, re-entry refused (RESILIENT-1636)"
        ));
    }

    let has_reentry_lease = matches!(verdict, LeaseVerdict::Live);
    build_admission(status, gap_id, reentry_session, has_reentry_lease)
}

/// RESILIENT-1636 (optional item 6): the set of `.chump-locks` directories a
/// dispatch's lease-only claim may have written its lease into. Dedups so a
/// lease present in two aliased paths is only read once. Order: `CHUMP_LOCK_DIR`
/// (explicit override), the repo root's `.chump-locks`, and the current
/// worktree's `.chump-locks` (when it differs from repo_root — a linked
/// worktree's cwd).
fn lease_lock_dirs(repo_root: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut push = |p: PathBuf| {
        if !dirs.contains(&p) {
            dirs.push(p);
        }
    };
    if let Ok(d) = std::env::var("CHUMP_LOCK_DIR") {
        if !d.trim().is_empty() {
            push(PathBuf::from(d));
        }
    }
    push(repo_root.join(".chump-locks"));
    if let Ok(cwd) = std::env::current_dir() {
        push(cwd.join(".chump-locks"));
    }
    dirs
}

/// Pure admission decision (no fs/env), split out so the invariant is
/// deterministically unit-testable.
///
/// RESILIENT-1636 (independent-review hardening): a ship gate may relax ONLY
/// for a node the operator DELIBERATELY PAUSED, and only the (expected) stale
/// heartbeat may be excused. Re-entry of already-claimed work is admitted iff:
///   * GREEN                                   → admit normally; OR
///   * the node is `paused` AND otherwise healthy (`sentinel_absent`,
///     `exit78_free`, `oauth_fresh` all hold — heartbeat staleness is the
///     ONLY thing pause excuses) AND the session holds a live re-entry lease.
///
/// Every genuinely-RED case — an un-paused node (even with a live lease), a
/// paused node with a `fleet-paused` sentinel, an exit-78 supervisor, or a
/// BROKEN oauth probe — still REFUSES, pinned by unit + e2e tests. The admit
/// note therefore never says "RED": we only reach it when `status.paused`.
fn build_admission(
    status: FarmerStatus,
    gap_id: &str,
    session_id: Option<&str>,
    has_reentry_lease: bool,
) -> ClaimAdmission {
    if status.green {
        return ClaimAdmission::Green;
    }
    // Re-entry relaxation is paused-only, and paused excuses the stale heartbeat
    // and NOTHING else. Any other unhealthy signal is a genuine RED → refuse.
    let paused_otherwise_healthy =
        status.paused && status.sentinel_absent && status.exit78_free && status.oauth_fresh;
    if has_reentry_lease && paused_otherwise_healthy {
        if let Some(sess) = session_id {
            return ClaimAdmission::ReentryAdmit {
                note: format!(
                    "farmer paused but session {sess} already holds a live lease for {gap_id} \
                     — admitting re-entry (ship step of already-claimed work; RESILIENT-1636). \
                     NEW claims remain refused."
                ),
            };
        }
    }
    ClaimAdmission::Refuse { status }
}

/// RESILIENT-1636 / CHIEF RULE 8: the classification of the current session's
/// lease for a gap. A "live lease" means a lease row for THIS gap and THIS
/// session whose `expires_at` parses and is in the future. A missing or
/// unparseable `expires_at` is NOT live — it is MALFORMED (refused with its own
/// distinct reason); an expired one, or no matching lease at all, is `NotLive`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LeaseVerdict {
    /// A matching lease exists and its `expires_at` parses to a future instant.
    Live,
    /// A matching lease exists but `expires_at` is missing or unparseable.
    Malformed,
    /// No matching lease, or the matching lease has expired.
    NotLive,
}

/// Classify the current session's lease for `gap_id` across several lock dirs,
/// taking the strongest verdict found: `Live` wins over `Malformed`, which wins
/// over `NotLive` (so one aliased dir holding a good lease isn't masked by a
/// malformed copy in another).
fn classify_session_lease_in_dirs(
    lock_dirs: &[PathBuf],
    gap_id: &str,
    session_id: &str,
) -> LeaseVerdict {
    let mut best = LeaseVerdict::NotLive;
    for dir in lock_dirs {
        match classify_session_lease(dir, gap_id, session_id) {
            LeaseVerdict::Live => return LeaseVerdict::Live,
            LeaseVerdict::Malformed => best = LeaseVerdict::Malformed,
            LeaseVerdict::NotLive => {}
        }
    }
    best
}

/// RESILIENT-1636: classify `session_id`'s lease for `gap_id` in a single
/// `lock_dir`. The dispatch lane's lease-only claim writes
/// `<lock_dir>/<session>.json` with `{gap_id, session_id, expires_at}` (RFC3339);
/// scan every lease file so filename sanitisation can't cause a miss. Returns
/// the strongest verdict across all matching rows.
fn classify_session_lease(lock_dir: &Path, gap_id: &str, session_id: &str) -> LeaseVerdict {
    let now = now_s();
    let Ok(entries) = std::fs::read_dir(lock_dir) else {
        return LeaseVerdict::NotLive;
    };
    let mut best = LeaseVerdict::NotLive;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(val) = serde_json::from_str::<serde_json::Value>(&body) else {
            continue;
        };
        if val.get("gap_id").and_then(|v| v.as_str()) != Some(gap_id) {
            continue;
        }
        if val.get("session_id").and_then(|v| v.as_str()) != Some(session_id) {
            continue;
        }
        // CHIEF RULE 8: liveness requires an expires_at that parses AND is in the
        // future. Missing OR unparseable => malformed (not live). Expired => not
        // live. Only a parsed, future expiry is a live re-entry anchor.
        match val.get("expires_at").and_then(|v| v.as_str()) {
            Some(exp) => match parse_rfc3339_secs(exp) {
                Some(exp_secs) if exp_secs > now => return LeaseVerdict::Live,
                Some(_) => {}                        // expired — not live
                None => best = best.max_malformed(), // unparseable — malformed
            },
            None => best = best.max_malformed(), // missing expires_at — malformed
        }
    }
    best
}

impl LeaseVerdict {
    /// Raise a `NotLive` verdict to `Malformed`; leave `Live`/`Malformed` as-is.
    fn max_malformed(self) -> LeaseVerdict {
        match self {
            LeaseVerdict::Live => LeaseVerdict::Live,
            _ => LeaseVerdict::Malformed,
        }
    }
}

/// RESILIENT-1636: thin bool wrapper — does `session_id` hold a LIVE (parsed +
/// future `expires_at`) lease for `gap_id` in `lock_dir`? Missing/unparseable
/// expires_at and expired leases are all NOT live.
fn session_holds_live_lease_for_gap(lock_dir: &Path, gap_id: &str, session_id: &str) -> bool {
    matches!(
        classify_session_lease(lock_dir, gap_id, session_id),
        LeaseVerdict::Live
    )
}

/// RFC3339 (`2026-04-17T02:27:48Z`) → Unix seconds, for lease-expiry liveness.
fn parse_rfc3339_secs(s: &str) -> Option<u64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.timestamp().max(0) as u64)
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
        let verdict = if status.green {
            "GREEN"
        } else if status.paused {
            "PAUSED"
        } else {
            "RED"
        };
        println!("chump farmer status: {verdict}");
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
        let (fresh, age) = heartbeat_verdict(dir.path());
        assert!(fresh);
        assert!(age.is_none());
    }

    #[test]
    fn heartbeat_fresh_within_window() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("farmer-heartbeat"), "2026-08-13T00:00:00Z").unwrap();
        let (fresh, age) = heartbeat_verdict(dir.path());
        assert!(fresh);
        assert!(age.unwrap() < HEARTBEAT_MAX_AGE_S);
    }

    #[test]
    fn heartbeat_stale_fails_and_explains_why() {
        let dir = tempfile::tempdir().unwrap();
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let path = chump_dir.join("farmer-heartbeat");
        let file = std::fs::File::create(&path).unwrap();
        // Back-date the mtime past the freshness window.
        let old = SystemTime::now() - std::time::Duration::from_secs(HEARTBEAT_MAX_AGE_S + 1);
        file.set_modified(old).unwrap();
        // The stale verdict is still the pure helper's job …
        let (fresh, age) = heartbeat_verdict(&chump_dir);
        assert!(!fresh);
        assert!(age.unwrap() > HEARTBEAT_MAX_AGE_S);
        // … but the refusal REASON moved into compute()'s stale branch, so the
        // "explains why" assertion must read it where it now lives: an un-paused
        // node's stale heartbeat yields a reason naming "farmer heartbeat stale".
        let status = compute(dir.path());
        assert!(!status.heartbeat_fresh);
        assert!(
            status
                .reasons
                .iter()
                .any(|r| r.contains("farmer heartbeat stale")),
            "expected a 'farmer heartbeat stale' reason, got {:?}",
            status.reasons
        );
    }

    #[test]
    fn green_requires_all_checks_and_not_paused() {
        let base = FarmerStatus {
            green: true,
            sentinel_absent: true,
            exit78_free: true,
            oauth_fresh: true,
            heartbeat_fresh: true,
            heartbeat_age_s: None,
            paused: false,
            reasons: vec![],
        };
        let is_green = |s: &FarmerStatus| {
            s.sentinel_absent && s.exit78_free && s.oauth_fresh && s.heartbeat_fresh && !s.paused
        };
        assert!(is_green(&base));

        let mut red = base.clone();
        red.oauth_fresh = false;
        assert!(!is_green(&red));

        // RESILIENT-1636: a paused node is not lights-on even with every other
        // check green — so NEW claims are still refused.
        let mut paused = base.clone();
        paused.paused = true;
        assert!(!is_green(&paused));
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

    // ── RESILIENT-1636: credential-path validity (not the mirror mtime) ──────

    #[test]
    fn creds_future_expiry_is_valid() {
        // AC3: valid ~/.claude credentials read as fresh. expiresAt in the
        // future (epoch MILLIS) → usable.
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":9999999999999}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000), Some(true));
    }

    #[test]
    fn creds_expired_but_refreshable_is_valid() {
        // An expired access token is still usable when a refresh token exists —
        // Claude Code mints a fresh token on the next call.
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":1}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000_000), Some(true));
    }

    #[test]
    fn creds_expired_no_refresh_is_invalid() {
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","expiresAt":1}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000_000), Some(false));
    }

    #[test]
    fn creds_no_token_is_none() {
        // No usable token → None (caller falls through to fail-open, not RED).
        assert_eq!(claude_creds_verdict(r#"{"claudeAiOauth":{}}"#, 1), None);
        assert_eq!(claude_creds_verdict("not json", 1), None);
    }

    #[test]
    fn creds_present_without_expiry_is_valid() {
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x"}}"#;
        assert_eq!(claude_creds_verdict(body, 1), Some(true));
    }

    // ── RESILIENT-1636: paused-node reporting ────────────────────────────────

    #[test]
    fn node_env_paused_parse() {
        assert!(node_env_is_paused("export CHUMP_NODE_MODE=paused\n"));
        assert!(node_env_is_paused("CHUMP_NODE_MODE=paused"));
        assert!(!node_env_is_paused("export CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("# comment\nexport FOO=bar\n"));
    }

    // ── RESILIENT-1636: re-entry admission vs new-claim refusal ──────────────

    fn write_lease(lock_dir: &Path, session: &str, gap: &str, expires: &str) {
        std::fs::create_dir_all(lock_dir).unwrap();
        std::fs::write(
            lock_dir.join(format!("{session}.json")),
            format!(r#"{{"session_id":"{session}","gap_id":"{gap}","expires_at":"{expires}"}}"#),
        )
        .unwrap();
    }

    #[test]
    fn session_live_lease_detects_self_reentry() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join(".chump-locks");
        write_lease(&lock, "sess-A", "GAP-1", "2999-01-01T00:00:00Z");
        assert!(session_holds_live_lease_for_gap(&lock, "GAP-1", "sess-A"));
        // Wrong gap / wrong session / expired → not a re-entry anchor.
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-2", "sess-A"));
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-1", "sess-B"));
        write_lease(&lock, "sess-C", "GAP-9", "2000-01-01T00:00:00Z");
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-9", "sess-C"));
    }

    fn paused_status() -> FarmerStatus {
        // The cuphead ship-wall condition: paused node, stale heartbeat.
        FarmerStatus {
            green: false,
            sentinel_absent: true,
            exit78_free: true,
            oauth_fresh: true,
            heartbeat_fresh: false,
            heartbeat_age_s: Some(80_000),
            paused: true,
            reasons: vec!["farmer paused by node mode (CHUMP_NODE_MODE=paused)".into()],
        }
    }

    #[test]
    fn admission_reentry_admitted_under_paused() {
        // Re-entry of already-claimed work: the dispatch holds the lease, so the
        // ship step (bot-merge re-claim) must reach push even on a paused farmer.
        match build_admission(paused_status(), "GAP-1", Some("sess-A"), true) {
            ClaimAdmission::ReentryAdmit { note } => {
                assert!(note.contains("re-entry"));
                assert!(note.contains("paused"));
                assert!(note.contains("GAP-1"));
            }
            other => panic!("expected ReentryAdmit, got {other:?}"),
        }
    }

    #[test]
    fn admission_new_claim_refused_under_paused() {
        // The gate is not weakened: no live lease for this session → refused.
        match build_admission(paused_status(), "GAP-2", Some("sess-A"), false) {
            ClaimAdmission::Refuse { status } => assert!(status.paused),
            other => panic!("expected Refuse, got {other:?}"),
        }
        // No session at all → refused regardless.
        assert!(matches!(
            build_admission(paused_status(), "GAP-1", None, false),
            ClaimAdmission::Refuse { .. }
        ));
    }

    #[test]
    fn admission_green_admits_without_lease() {
        let mut green = paused_status();
        green.green = true;
        green.paused = false;
        green.heartbeat_fresh = true;
        assert!(matches!(
            build_admission(green, "GAP-1", None, false),
            ClaimAdmission::Green
        ));
    }

    // ── RESILIENT-1636 (independent-review hardening): genuinely-RED cases must
    // refuse EVEN WITH a live re-entry lease. A ship gate relaxes ONLY for a
    // deliberately-paused node whose single unhealthy signal is the (expected)
    // stale heartbeat; every other RED condition still refuses. ───────────────

    #[test]
    fn admission_unpaused_stale_heartbeat_refuses_even_with_lease() {
        // An UN-paused node with a stale heartbeat is genuinely RED — a live
        // lease does NOT admit re-entry (pause is the only heartbeat excuse).
        let status = FarmerStatus {
            green: false,
            sentinel_absent: true,
            exit78_free: true,
            oauth_fresh: true,
            heartbeat_fresh: false,
            heartbeat_age_s: Some(80_000),
            paused: false,
            reasons: vec!["farmer heartbeat stale".into()],
        };
        match build_admission(status, "GAP-1", Some("sess-A"), true) {
            ClaimAdmission::Refuse { status } => assert!(!status.paused),
            other => panic!("expected Refuse, got {other:?}"),
        }
    }

    #[test]
    fn admission_paused_with_sentinel_refuses_even_with_lease() {
        // Paused but the fleet-paused SENTINEL is present — a genuine RED that
        // pause does not excuse. Refuse despite the live lease.
        let mut status = paused_status();
        status.sentinel_absent = false;
        assert!(matches!(
            build_admission(status, "GAP-1", Some("sess-A"), true),
            ClaimAdmission::Refuse { .. }
        ));
    }

    #[test]
    fn admission_paused_with_exit78_refuses_even_with_lease() {
        // Paused but a control-plane supervisor exited 78 — genuine RED.
        let mut status = paused_status();
        status.exit78_free = false;
        assert!(matches!(
            build_admission(status, "GAP-1", Some("sess-A"), true),
            ClaimAdmission::Refuse { .. }
        ));
    }

    #[test]
    fn admission_paused_with_oauth_broken_refuses_even_with_lease() {
        // Paused but oauth is NOT fresh (probed BROKEN / expired creds) — genuine
        // RED. Pause excuses the stale heartbeat, never a dead credential.
        let mut status = paused_status();
        status.oauth_fresh = false;
        assert!(matches!(
            build_admission(status, "GAP-1", Some("sess-A"), true),
            ClaimAdmission::Refuse { .. }
        ));
    }

    #[test]
    fn admission_reentry_note_never_says_red() {
        // The admit note is reached only when paused — it must never say "RED".
        if let ClaimAdmission::ReentryAdmit { note } =
            build_admission(paused_status(), "GAP-1", Some("sess-A"), true)
        {
            assert!(
                !note.contains("RED"),
                "admit note must never say RED: {note}"
            );
            assert!(note.contains("paused"));
        } else {
            panic!("expected ReentryAdmit under a paused, otherwise-healthy farmer");
        }
    }

    // ── RESILIENT-1636 / CHIEF RULE 8: a lease with missing or unparseable
    // expires_at is NOT live — it is malformed. ───────────────────────────────

    #[test]
    fn lease_missing_expires_at_is_not_live() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&lock).unwrap();
        std::fs::write(
            lock.join("sess-A.json"),
            r#"{"session_id":"sess-A","gap_id":"GAP-1"}"#,
        )
        .unwrap();
        assert_eq!(
            classify_session_lease(&lock, "GAP-1", "sess-A"),
            LeaseVerdict::Malformed
        );
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-1", "sess-A"));
    }

    #[test]
    fn lease_unparseable_expires_at_is_not_live() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&lock).unwrap();
        std::fs::write(
            lock.join("sess-A.json"),
            r#"{"session_id":"sess-A","gap_id":"GAP-1","expires_at":"not-a-date"}"#,
        )
        .unwrap();
        assert_eq!(
            classify_session_lease(&lock, "GAP-1", "sess-A"),
            LeaseVerdict::Malformed
        );
        assert!(!session_holds_live_lease_for_gap(&lock, "GAP-1", "sess-A"));
    }

    // ── RESILIENT-1636: auth-status cache rc!=0 inside TTL ⇒ oauth_fresh=false ──

    #[test]
    fn auth_status_cache_broken_within_ttl_is_red() {
        let now = 1_000_000;
        let mut r = Vec::new();
        // rc=1, age=5s (< TTL) ⇒ probed BROKEN ⇒ Some(false) (RED).
        let body = format!("{}\n1\n", now - 5);
        assert_eq!(auth_status_cache_verdict(&body, now, &mut r), Some(false));
        assert!(r[0].contains("BROKEN"));
        // rc=0 within TTL ⇒ fresh.
        let mut r2 = Vec::new();
        let body_ok = format!("{}\n0\n", now - 5);
        assert_eq!(
            auth_status_cache_verdict(&body_ok, now, &mut r2),
            Some(true)
        );
        // stale (age > TTL) ⇒ None (caller continues to next signal).
        let mut r3 = Vec::new();
        let body_stale = format!("{}\n1\n", now - (OAUTH_CACHE_TTL_S + 10));
        assert_eq!(auth_status_cache_verdict(&body_stale, now, &mut r3), None);
    }

    // ── RESILIENT-1636 / CHIEF RULE 7: the deleted `stale_token_reds_by_default`
    // pin is restored BYTE-IDENTICAL to origin/main (do not edit its body, name
    // or assertions). The positive re-entry case is a SEPARATE test above. ─────

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

    #[test]
    fn creds_expired_no_refresh_drives_check_oauth_red() {
        // Item (3) equivalent restored at the check level: no api key, no free
        // tier, no cache — an expired non-refreshable .credentials.json makes
        // claude_creds_verdict Some(false), which check_oauth_fresh turns to RED.
        let body = r#"{"claudeAiOauth":{"accessToken":"sk-x","expiresAt":1}}"#;
        assert_eq!(claude_creds_verdict(body, 1_000_000), Some(false));
    }
}
