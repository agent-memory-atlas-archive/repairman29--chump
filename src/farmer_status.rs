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
///   5. `~/.chump/oauth-token.json` — consulted ONLY as a last-resort fallback
///      when steps 1-4 produced no signal (no api key, no cache, no free-tier,
///      no `.credentials.json` token at all). On Linux (RESILIENT-1652) this
///      file IS the credential `claude -p` uses and no macOS-Keychain refresher
///      keeps its mtime fresh, so it is judged by CONTENT (via
///      [`oauth_token_json_content_verdict`]): a present, non-empty, `sk-`-shaped
///      token whose expiry (if present) is in the future reads fresh, while a
///      missing/empty/expired token reds — mtime is NOT consulted. On macOS
///      (unchanged) it is the Keychain mirror's mtime (a stale mirror reds,
///      preserving the old default). A valid `.credentials.json` in step 4
///      short-circuits FIRST on both platforms, so a stale mirror never reds a
///      node whose creds are good.
///   6. No positive signal of trouble -> fresh (fail-open; non-Linux only).
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

    // RESILIENT-1636/1652: validate the credential path `claude -p` actually
    // uses. `claude -p` reads `~/.claude/.credentials.json` relative to HOME —
    // NOT `CHUMP_HOME`. On cuphead `CHUMP_HOME` is set (node.env exports it), so
    // reading `<CHUMP_HOME>/.claude/.credentials.json` found nothing, fell
    // through to the stale mirror, and reported oauth_fresh=false while
    // `claude -p` authenticated fine from `<HOME>/.claude/.credentials.json`
    // (RESILIENT-1652 evidence). Resolve this one path from HOME.
    // Some(true) => usable; Some(false) => actually-dead creds, RED (restores the
    // stale_token_reds_by_default pin); None => no token, fall through.
    let creds_path = PathBuf::from(claude_credentials_home().unwrap_or_default())
        .join(".claude/.credentials.json");
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

    // The `~/.chump/oauth-token.json` env token — last-resort fallback, reached
    // only when NOTHING above gave a signal (no api key / cache / free-tier /
    // `.credentials.json` token).
    let chump_dir = PathBuf::from(&home).join(".chump");
    let token_path = chump_dir.join("oauth-token.json");
    if cfg!(target_os = "linux") {
        // RESILIENT-1652 (task 2): on Linux this file IS the credential
        // `claude -p` uses — it exports CLAUDE_CODE_OAUTH_TOKEN from it — and NO
        // macOS-Keychain refresher keeps its mtime fresh (`oauth-token-refresh.sh`
        // is macOS-only). So mtime is a FALSE death signal (cuphead: a valid env
        // token reads 45h "stale"). Judge by CONTENT: present + non-empty +
        // plausible token shape + future expiry IF one is present. A missing /
        // empty / expired token is a genuine RED (claude -p cannot authenticate).
        // The raw read result is handed to a pure helper so BOTH the present-file
        // content arm and the missing-file `Err` RED arm are unit-testable without
        // touching the host fs/env (the M-A pin).
        return linux_oauth_token_file_verdict_with_dir(
            std::fs::read_to_string(&token_path),
            now_ms(),
            Some(&chump_dir),
            reasons,
        );
    } else if token_path.exists() {
        // macOS path UNCHANGED (RESILIENT-1636): the Keychain mirror's mtime.
        // cfg!(...) (not #[cfg]) keeps this arm compiled on every platform so
        // mtime_age_s / oauth_token_verdict stay referenced (no dead_code under
        // -D warnings) and the Linux content helper is likewise always built.
        match mtime_age_s(&token_path) {
            Some(age) => return oauth_token_verdict(age, free_tier_cascade_active(), reasons),
            None => return true,
        }
    } else if let Some((exhausted_name, exhausted_date)) = find_exhausted_oauth_token(&chump_dir) {
        // RESILIENT-1690: even on non-Linux, if oauth-token.json is missing and an
        // oauth-token.json.exhausted* rotation artifact is present (with no valid
        // api-key / cache / free-tier / .credentials.json above), surface the exact
        // exhausted filename, date, spend-limit reason, and recovery command.
        reasons.push(format_exhausted_oauth_reason(
            &exhausted_name,
            &exhausted_date,
        ));
        return false;
    }

    // No positive signal of trouble — fail-open (non-Linux, token absent).
    true
}

/// RESILIENT-1690: recovery command surfaced when `~/.chump/oauth-token.json`
/// is missing or rotated out to `~/.chump/oauth-token.json.exhausted*`.
pub const OAUTH_RECOVERY_COMMAND: &str =
    "run 'claude setup-token' and save to ~/.chump/oauth-token.json, or set ANTHROPIC_API_KEY";

/// RESILIENT-1690: scan `chump_dir` (`~/.chump`) for a rotated-out
/// `oauth-token.json.exhausted*` file. Returns `(exact_filename, date_str)`
/// for the most recent matching file when present.
pub fn find_exhausted_oauth_token(chump_dir: &Path) -> Option<(String, String)> {
    let entries = std::fs::read_dir(chump_dir).ok()?;
    let mut matches: Vec<(String, PathBuf)> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with("oauth-token.json.exhausted") {
                Some((name, e.path()))
            } else {
                None
            }
        })
        .collect();
    matches.sort_by(|a, b| b.0.cmp(&a.0));
    let (filename, path) = matches.into_iter().next()?;
    let suffix = filename
        .strip_prefix("oauth-token.json.exhausted")
        .unwrap_or("")
        .trim_start_matches(['-', '.', '_']);
    let date = if !suffix.is_empty() {
        suffix.to_string()
    } else {
        std::fs::metadata(&path)
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|mtime| {
                let dt: chrono::DateTime<chrono::Utc> = mtime.into();
                dt.format("%Y-%m-%d").to_string()
            })
            .unwrap_or_else(|| "unknown-date".to_string())
    };
    Some((filename, date))
}

/// RESILIENT-1690: format the operator-actionable reason when
/// `~/.chump/oauth-token.json` is missing and `~/.chump/oauth-token.json.exhausted*`
/// is present.
pub fn format_exhausted_oauth_reason(filename: &str, date: &str) -> String {
    format!(
        "~/.chump/oauth-token.json missing — rotated to ~/.chump/{filename} on {date} due to \
         OAuth spend-limit/exhaustion; recovery: {OAUTH_RECOVERY_COMMAND}"
    )
}

/// RESILIENT-1690: when no valid model credential source exists on the node
/// (`!oauth_fresh`), emit `kind=node_auth_dead` once (deduped via
/// `<repo_root>/.chump-locks/node_auth_dead.stamp`) and auto-file an operator
/// ASK in `<repo_root>/.chump-locks/operator-asks.jsonl` (plus `ask_jeff_db`
/// when `sessions/` exists). Returns `true` if a new event/ask was emitted, or
/// `false` if suppressed by the dedup stamp.
pub fn record_node_auth_dead_once(repo_root: &Path, reasons: &[String]) -> bool {
    let locks_dir = repo_root.join(".chump-locks");
    let stamp_path = locks_dir.join("node_auth_dead.stamp");
    if stamp_path.exists() {
        return false;
    }
    if std::fs::create_dir_all(&locks_dir).is_err() {
        return false;
    }
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let reason_summary = if reasons.is_empty() {
        "no valid model credential source on node".to_string()
    } else {
        reasons.join("; ")
    };
    let _ = std::fs::write(&stamp_path, format!("{ts} {reason_summary}\n"));

    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| locks_dir.join("ambient.jsonl"));
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // scanner-anchor: "kind":"node_auth_dead"
    let event_line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"node_auth_dead\",\"reason\":{},\"recovery\":{}}}\n",
        serde_json::to_string(&reason_summary).unwrap_or_else(|_| "\"auth_dead\"".to_string()),
        serde_json::to_string(OAUTH_RECOVERY_COMMAND).unwrap_or_else(|_| "\"\"".to_string()),
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = f.write_all(event_line.as_bytes());
    }

    let question = format!(
        "Node model credentials are dead or exhausted ({reason_summary}). Please refresh credentials: {OAUTH_RECOVERY_COMMAND}"
    );
    let ask_path = locks_dir.join("operator-asks.jsonl");
    let ask_line = serde_json::json!({
        "ts": ts,
        "ask_type": "operator_ask",
        "topic": "node_auth_dead",
        "priority": "blocking",
        "question": question,
        "reason": reason_summary,
        "recovery": OAUTH_RECOVERY_COMMAND,
    });
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ask_path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{ask_line}");
    }
    if repo_root.join("sessions").is_dir() {
        let _ = crate::ask_jeff_db::question_ask(&question, Some(&reason_summary), "blocking");
    }
    true
}

/// RESILIENT-1652 (task 2): pure verdict for the Linux
/// `~/.chump/oauth-token.json` fallback — the file `claude -p` reads
/// `CLAUDE_CODE_OAUTH_TOKEN` from on a Linux node. Takes the RAW
/// `std::fs::read_to_string` result so BOTH arms are deterministically
/// unit-testable without touching the host fs/env:
///   * `Ok(body)` is judged by CONTENT via [`oauth_token_json_content_verdict`]
///     (present + non-empty + `sk-`-shaped + future expiry ⇒ fresh); any other
///     content is a RED (empty / malformed / expired);
///   * `Err(_)` (missing / unreadable) is a genuine RED — `claude -p` has no
///     `CLAUDE_CODE_OAUTH_TOKEN` source, and NOTHING above gave a signal.
///
/// Mirrors the inline arms it replaced byte-for-byte, including the pushed RED
/// reasons. This is the M-A pin: the `Err` arm must return `false`, NEVER
/// fail-open to `true`.
fn linux_oauth_token_file_verdict(
    read: std::io::Result<String>,
    now_ms: i64,
    reasons: &mut Vec<String>,
) -> bool {
    linux_oauth_token_file_verdict_with_dir(read, now_ms, None, reasons)
}

fn linux_oauth_token_file_verdict_with_dir(
    read: std::io::Result<String>,
    now_ms: i64,
    chump_dir: Option<&Path>,
    reasons: &mut Vec<String>,
) -> bool {
    match read {
        Ok(body) => match oauth_token_json_content_verdict(&body, now_ms) {
            Some(true) => true,
            _ => {
                reasons.push(
                    "~/.chump/oauth-token.json token is empty / malformed / expired \
                     (claude -p has no usable CLAUDE_CODE_OAUTH_TOKEN)"
                        .to_string(),
                );
                false
            }
        },
        Err(_) => {
            if let Some((exhausted_name, exhausted_date)) =
                chump_dir.and_then(find_exhausted_oauth_token)
            {
                reasons.push(format_exhausted_oauth_reason(
                    &exhausted_name,
                    &exhausted_date,
                ));
            } else {
                reasons.push(
                    "~/.chump/oauth-token.json missing (claude -p has no CLAUDE_CODE_OAUTH_TOKEN \
                     source and no api-key / cache / free-tier / .credentials.json signal)"
                        .to_string(),
                );
            }
            false
        }
    }
}

/// RESILIENT-1652 (task 2): pure CONTENT verdict for the Linux
/// `~/.chump/oauth-token.json` env token (the file `claude -p` reads
/// `CLAUDE_CODE_OAUTH_TOKEN` from; written from providers.env-linux, usually
/// with no expiry field). A token is fresh iff it is present, non-empty, shaped
/// like an Anthropic token (`sk-` prefix), and — IF an expiry field is present —
/// not yet expired. `Some(true)` = usable, `Some(false)` =
/// empty/malformed/expired (RED), `None` = unparseable JSON (caller treats as
/// RED). Pure (no fs/env) and mtime-independent — content, never mtime.
fn oauth_token_json_content_verdict(content: &str, now_ms: i64) -> Option<bool> {
    let v: serde_json::Value = serde_json::from_str(content).ok()?;
    // Claude Code nests under `claudeAiOauth`; the providers.env-linux writer is
    // flat (`{"token":"sk-…"}`). Tolerate both.
    let obj = v.get("claudeAiOauth").unwrap_or(&v);
    let token = [
        "token",
        "accessToken",
        "access_token",
        "CLAUDE_CODE_OAUTH_TOKEN",
    ]
    .iter()
    .find_map(|k| obj.get(*k).and_then(|x| x.as_str()))
    .map(str::trim)
    .unwrap_or("");
    // Present + non-empty + plausible Anthropic token shape (`sk-ant-oat01-…`).
    if token.is_empty() || !token.starts_with("sk-") {
        return Some(false);
    }
    // If an expiry is present it must be in the future (epoch millis; a JSON
    // number or numeric string). No expiry field at all → usable (the
    // providers.env-linux shape carries none).
    let expires = obj
        .get("expiresAt")
        .or_else(|| obj.get("expires_at"))
        .and_then(|x| {
            x.as_i64()
                .or_else(|| x.as_str().and_then(|s| s.trim().parse().ok()))
        });
    match expires {
        Some(exp) if exp <= now_ms => Some(false), // expired
        _ => Some(true),
    }
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

/// RESILIENT-1652: the home `claude -p` reads `~/.claude/.credentials.json`
/// from. This is `HOME`, NOT `CHUMP_HOME` — the two differ on a node (cuphead)
/// whose node.env exports `CHUMP_HOME`, and reading the creds from `CHUMP_HOME`
/// found nothing and falsely reported oauth_fresh=false. Unlike the chump state
/// files (`oauth-token.json` mirror, `auth-status-cache`, which live under
/// `CHUMP_HOME`/`chump_state_home`), the Claude credential store is owned by
/// the Claude CLI and keyed off `HOME`.
fn claude_credentials_home() -> Option<String> {
    resolve_claude_home(std::env::var("HOME").ok())
}

/// Pure precedence rule for [`claude_credentials_home`]: a non-empty `HOME`
/// wins; nothing else is consulted (the Claude CLI reads `~` = `HOME`). Split
/// out so it is unit-testable without mutating process-global env.
fn resolve_claude_home(home: Option<String>) -> Option<String> {
    home.filter(|s| !s.is_empty())
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
    if std::env::var("CHUMP_FREE_TIER_PROVIDERS")
        .ok()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
    {
        return true;
    }
    // RESILIENT-1688: BYOK-primary nodes (Google AI / Mistral / OpenAI / OpenRouter)
    // do not require a Claude OAuth token when CHUMP_BYOK_PRIMARY=1 and at least
    // one BYOK API key is configured.
    if std::env::var("CHUMP_BYOK_PRIMARY").as_deref() == Ok("1") {
        for key_var in [
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "MISTRAL_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY",
        ] {
            if std::env::var(key_var)
                .ok()
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false)
            {
                return true;
            }
        }
    }
    false
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

/// RESILIENT-1652 (task 0): resolve the node state dir (where `node.env` and
/// the node pause sentinel live) the same way `chump node pause` does —
/// `CHUMP_STATE_DIR` if set, else `<state-home>/.chump`, else `.chump`. This is
/// the ONE place [`compute`] reads the host env for the pause inputs; tests call
/// [`compute_at`] with an explicit state dir so they never read the host (the
/// cuphead trap: the host's `~/.chump/node.env` is `CHUMP_NODE_MODE=paused`, so
/// a test that let `compute` read the host saw `paused=true` and the
/// stale-heartbeat reason it was asserting on was suppressed).
fn resolve_node_state_dir() -> PathBuf {
    std::env::var("CHUMP_STATE_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| chump_state_home().map(|h| PathBuf::from(h).join(".chump")))
        .unwrap_or_else(|| PathBuf::from(".chump"))
}

/// Node-mode pause detection (RESILIENT-1636 / RESILIENT-1614 / RESILIENT-1652).
/// Delegates to the ONE paused predicate in [`crate::node_pause`], shared with
/// the pause detector in `node_mode.rs`, `chump node is-paused`, and
/// node-converge. A node is paused when the node **state dir** expresses it via
/// `node.env` (`CHUMP_NODE_MODE=paused` in either line form, OR the legacy
/// `control-plane` + `CHUMP_NODE_WORK_ENABLED=0` form cuphead carried) OR the
/// `<state_dir>/.chump/fleet-paused` node pause sentinel is present. A paused
/// node's stale heartbeat is EXPECTED (the farmer is deliberately idle), so it
/// is reported as PAUSED. Returns the signal so the gate can attribute the
/// reason.
///
/// RESILIENT-1652 (task 0 + 5): this reads ONLY the passed `state_dir` — it does
/// NOT consult an exported `CHUMP_NODE_MODE` env var (that override is removed,
/// so node.env is the sole durable source) and it does NOT resolve the state dir
/// from the host itself. Both make every caller that passes an explicit (temp)
/// state dir fully hermetic. The node pause sentinel here is a DIFFERENT file
/// from the kill switch [`check_sentinel`] reads (`repo_root/.chump`), so a
/// verb-paused node reports PAUSED without tripping the HARD-RED kill switch.
fn node_is_paused(state_dir: &Path) -> Option<crate::node_pause::PauseSignal> {
    crate::node_pause::pause_signal(state_dir)
}

/// Compute the farmer status, resolving the node state dir from the host env
/// (`CHUMP_STATE_DIR` / `HOME`). Production entry point.
pub fn compute(repo_root: &Path) -> FarmerStatus {
    compute_at(repo_root, &resolve_node_state_dir())
}

/// RESILIENT-1652 (task 0): compute the farmer status against an EXPLICIT node
/// state dir (where `node.env` + the node pause sentinel live). Split out from
/// [`compute`] so tests pass a temp dir and never read the host's (paused)
/// `~/.chump/node.env`. The kill-switch sentinel stays resolved from
/// `repo_root/.chump` (it is the ci-health-gate's file, keyed off the repo, not
/// the node state dir).
pub fn compute_at(repo_root: &Path, state_dir: &Path) -> FarmerStatus {
    let chump_dir = repo_root.join(".chump");
    let mut reasons = Vec::new();

    let sentinel_absent = check_sentinel(&chump_dir, &mut reasons);
    let exit78_free = check_exit78_free(&mut reasons);
    let oauth_fresh = check_oauth_fresh(repo_root, &mut reasons);
    if !oauth_fresh {
        let _ = record_node_auth_dead_once(repo_root, &reasons);
    }
    let (heartbeat_fresh, heartbeat_age_s) = heartbeat_verdict(&chump_dir);
    let pause_signal = node_is_paused(state_dir);
    let paused = pause_signal.is_some();

    // RESILIENT-1636: a paused node's stale heartbeat is expected — report it
    // as PAUSED, not as a stale-farmer malfunction. A truly-stale heartbeat on
    // an UN-paused node keeps the original RED reason. RESILIENT-1652: attribute
    // the pause accurately (node-env pause vs. the kill-switch sentinel).
    if let Some(sig) = pause_signal {
        let agenote = heartbeat_age_s
            .map(|a| format!(" (heartbeat age={a}s, staleness expected while paused)"))
            .unwrap_or_default();
        let reason = match sig {
            crate::node_pause::PauseSignal::NodeEnv => {
                format!("farmer paused by node mode (CHUMP_NODE_MODE=paused){agenote}")
            }
            crate::node_pause::PauseSignal::Sentinel => {
                format!("farmer paused (fleet-paused sentinel present){agenote}")
            }
        };
        reasons.push(reason);
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
        // RESILIENT-1652 (task 0): isolate the pause inputs with an explicit,
        // CLEAN (no node.env, no sentinel) state dir so the host's paused
        // `~/.chump/node.env` can't flip this node to PAUSED and suppress the
        // stale-heartbeat reason this test asserts on.
        let clean_state = tempfile::tempdir().unwrap();
        let status = compute_at(dir.path(), clean_state.path());
        assert!(!status.paused, "clean state dir must not read as paused");
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
    fn compute_at_reads_passed_state_dir_not_host() {
        // RESILIENT-1652 (task 0): the hermetic guarantee. compute_at takes the
        // node state dir explicitly; the pause verdict depends ONLY on that dir,
        // never on the host's `~/.chump/node.env` (which on cuphead is
        // CHUMP_NODE_MODE=paused). Prove both directions in one test:
        //   * a CLEAN state dir → not paused, so a stale heartbeat reads as a
        //     malfunction ("farmer heartbeat stale") even if the host is paused;
        //   * a PAUSED state dir → paused, and the staleness is attributed to
        //     the pause, not reported as a malfunction.
        let repo = tempfile::tempdir().unwrap();
        let chump_dir = repo.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let hb = chump_dir.join("farmer-heartbeat");
        let f = std::fs::File::create(&hb).unwrap();
        let old = SystemTime::now() - std::time::Duration::from_secs(HEARTBEAT_MAX_AGE_S + 1);
        f.set_modified(old).unwrap();

        // Clean state dir (no node.env, no node sentinel) → not paused.
        let clean = tempfile::tempdir().unwrap();
        let s = compute_at(repo.path(), clean.path());
        assert!(!s.paused, "a clean state dir must not read as paused");
        assert!(
            s.reasons
                .iter()
                .any(|r| r.contains("farmer heartbeat stale")),
            "un-paused stale heartbeat must report the malfunction: {:?}",
            s.reasons
        );

        // Paused state dir (node.env=paused) → paused; staleness attributed to
        // the pause, NOT reported as a stale-farmer malfunction.
        let paused_dir = tempfile::tempdir().unwrap();
        std::fs::write(
            paused_dir.path().join("node.env"),
            "CHUMP_NODE_MODE=paused\n",
        )
        .unwrap();
        let s2 = compute_at(repo.path(), paused_dir.path());
        assert!(s2.paused, "a paused node.env must read as paused");
        assert!(
            !s2.reasons
                .iter()
                .any(|r| r.contains("farmer heartbeat stale")),
            "a paused node's stale heartbeat must NOT read as a malfunction: {:?}",
            s2.reasons
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

    // ── RESILIENT-1652 (task 2): Linux oauth-token.json judged by CONTENT ─────

    #[test]
    fn oauth_token_json_content_verdict_cases() {
        // A long-lived env token (the providers.env-linux shape: flat `token`,
        // no expiry field) is fresh regardless of mtime — this is pure content.
        let long = r#"{"token":"sk-ant-oat01-abc","written_at":"2026-10-17T17:58:18Z","source":"providers.env-linux"}"#;
        assert_eq!(
            oauth_token_json_content_verdict(long, 9_999_999_999_999),
            Some(true)
        );
        // Empty token → RED.
        assert_eq!(
            oauth_token_json_content_verdict(r#"{"token":""}"#, 1),
            Some(false)
        );
        // No token key at all → RED.
        assert_eq!(
            oauth_token_json_content_verdict(r#"{"source":"x"}"#, 1),
            Some(false)
        );
        // A non-token-shaped value (no `sk-` prefix) → RED.
        assert_eq!(
            oauth_token_json_content_verdict(r#"{"token":"old"}"#, 1),
            Some(false)
        );
        // Future expiry → fresh; past expiry → RED.
        assert_eq!(
            oauth_token_json_content_verdict(
                r#"{"token":"sk-ant-x","expiresAt":9999999999999}"#,
                1_000
            ),
            Some(true)
        );
        assert_eq!(
            oauth_token_json_content_verdict(r#"{"token":"sk-ant-x","expiresAt":1}"#, 1_000_000),
            Some(false)
        );
        // Unparseable JSON → None (caller treats as RED).
        assert_eq!(oauth_token_json_content_verdict("not json", 1), None);
        // Nested claudeAiOauth + accessToken key is tolerated.
        assert_eq!(
            oauth_token_json_content_verdict(r#"{"claudeAiOauth":{"accessToken":"sk-ant-x"}}"#, 1),
            Some(true)
        );
    }

    #[test]
    fn linux_missing_oauth_token_reds() {
        // RESILIENT-1652 (task 2): on a Linux node `~/.chump/oauth-token.json` IS
        // the credential `claude -p` reads CLAUDE_CODE_OAUTH_TOKEN from; a MISSING
        // file (and no api-key / cache / free-tier / .credentials.json signal
        // above) is a genuine RED, NOT a fail-open green. Pins the M-A mutant: the
        // `Err(_)` arm in the Linux fallback must return false, never true.
        let mut reasons = Vec::new();
        let missing =
            std::io::Error::new(std::io::ErrorKind::NotFound, "no such file or directory");
        assert!(
            !linux_oauth_token_file_verdict(Err(missing), now_ms(), &mut reasons),
            "a missing oauth-token.json must RED — claude -p has no token source"
        );
        assert!(
            reasons.iter().any(|r| r.contains("missing")),
            "the RED reason must explain the token is missing: {reasons:?}"
        );
        // A present, valid env token still reads fresh through the SAME helper
        // (so the refactor is behaviour-identical, not a one-way RED).
        reasons.clear();
        assert!(
            linux_oauth_token_file_verdict(
                Ok(r#"{"token":"sk-ant-oat01-x"}"#.to_string()),
                1,
                &mut reasons
            ),
            "a present, sk-shaped token must read fresh"
        );
        assert!(reasons.is_empty(), "a fresh token pushes no reason");
        // A present-but-empty token reds through the content verdict (not the
        // missing-file arm).
        assert!(!linux_oauth_token_file_verdict(
            Ok(r#"{"token":""}"#.to_string()),
            1,
            &mut reasons
        ));
    }

    // ── RESILIENT-1636: paused-node reporting ────────────────────────────────

    #[test]
    fn node_env_paused_parse() {
        // Delegates to the ONE predicate in node_pause (both line forms + the
        // legacy control-plane form). Kept here so the farmer gate's reliance on
        // it is guarded at this layer too.
        use crate::node_pause::node_env_is_paused;
        assert!(node_env_is_paused("export CHUMP_NODE_MODE=paused\n"));
        assert!(node_env_is_paused("CHUMP_NODE_MODE=paused"));
        assert!(node_env_is_paused(
            "CHUMP_NODE_MODE=control-plane\nCHUMP_NODE_WORK_ENABLED=0\n"
        ));
        assert!(!node_env_is_paused("export CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("# comment\nexport FOO=bar\n"));
    }

    #[test]
    fn resolve_claude_home_is_home_only() {
        // RESILIENT-1652: the Claude credential store is keyed off HOME, never
        // CHUMP_HOME. A non-empty HOME wins; empty/absent → None (fail-open).
        assert_eq!(
            resolve_claude_home(Some("/home/ubuntu".into())),
            Some("/home/ubuntu".into())
        );
        assert_eq!(resolve_claude_home(Some(String::new())), None);
        assert_eq!(resolve_claude_home(None), None);
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

    #[test]
    fn exhausted_oauth_token_surfaces_filename_date_and_recovery_resilient_1690() {
        let dir = tempfile::tempdir().unwrap();
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        std::fs::write(
            chump_dir.join("oauth-token.json.exhausted-2026-10-25"),
            r#"{"token":"sk-ant-oat01-exhausted"}"#,
        )
        .unwrap();

        let (fname, date) = find_exhausted_oauth_token(&chump_dir).expect("should find .exhausted");
        assert_eq!(fname, "oauth-token.json.exhausted-2026-10-25");
        assert_eq!(date, "2026-10-25");

        let mut reasons = Vec::new();
        let missing =
            std::io::Error::new(std::io::ErrorKind::NotFound, "no such file or directory");
        assert!(!linux_oauth_token_file_verdict_with_dir(
            Err(missing),
            now_ms(),
            Some(&chump_dir),
            &mut reasons
        ));
        assert_eq!(reasons.len(), 1);
        assert!(reasons[0].contains("oauth-token.json.exhausted-2026-10-25"));
        assert!(reasons[0].contains("2026-10-25"));
        assert!(reasons[0].contains("spend-limit/exhaustion"));
        assert!(reasons[0].contains("claude setup-token"));
        assert!(reasons[0].contains("ANTHROPIC_API_KEY"));
    }

    #[test]
    fn node_auth_dead_emits_once_and_files_operator_ask_resilient_1690() {
        let repo = tempfile::tempdir().unwrap();
        let reasons = vec![format_exhausted_oauth_reason(
            "oauth-token.json.exhausted-2026-10-25",
            "2026-10-25",
        )];

        // First invocation emits node_auth_dead, writes stamp, and files operator ask.
        assert!(record_node_auth_dead_once(repo.path(), &reasons));
        let locks = repo.path().join(".chump-locks");
        assert!(locks.join("node_auth_dead.stamp").exists());

        let ambient = std::fs::read_to_string(locks.join("ambient.jsonl")).unwrap();
        assert!(ambient.contains("\"kind\":\"node_auth_dead\""));
        assert!(ambient.contains("oauth-token.json.exhausted-2026-10-25"));
        assert!(ambient.contains("claude setup-token"));

        let asks = std::fs::read_to_string(locks.join("operator-asks.jsonl")).unwrap();
        assert!(asks.contains("\"topic\":\"node_auth_dead\""));
        assert!(asks.contains("\"priority\":\"blocking\""));

        // Second invocation is deduped by node_auth_dead.stamp.
        assert!(!record_node_auth_dead_once(repo.path(), &reasons));
        let ambient_after = std::fs::read_to_string(locks.join("ambient.jsonl")).unwrap();
        assert_eq!(ambient.lines().count(), 1);
        assert_eq!(ambient_after.lines().count(), 1);
    }
}
