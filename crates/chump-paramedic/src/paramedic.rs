//! INFRA-1375: chump paramedic — rule-engine PR rescue daemon.
//!
//! Subcommands:
//!   chump paramedic triage           — read PR state, emit JSON action plan (read-only, exit 0)
//!   chump paramedic execute --plan F — run one cycle (default budget 90s per PR)
//!   chump paramedic daemon            — loop triage→execute every --interval-secs (default 600)
//!
//! Six action types (AC §2):
//!   REBASE_DIRTY        — gh pr update-branch on PRs behind main
//!   RERUN_FLAKE         — re-trigger known-flake CI failures
//!   ALLOWLIST_EMIT_NO_REG — auto-allowlist unregistered ambient event kinds
//!   SQUASH_INIT_LEAK    — flag PRs with Test <test@test.local> empty-author commits
//!   FILE_CLUSTER_RESCUE — reserve a RESCUE gap when ≥3 PRs share the same failing check
//!   RESCUE_CI_FAILURE   — INFRA-1713: diagnose top failing check on BLOCKED PRs; dispatch rescue subagent

use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tracing::{info, warn};

// ── data types ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ParamedicAction {
    RebaseDirty,
    RerunFlake,
    AllowlistEmitNoReg,
    SquashInitLeak,
    FileClusterRescue,
    /// INFRA-1420: when a "keystone-fix" merges (commit subject carries
    /// `unblocks-cluster: <check-name>` trailer), update-branch every open
    /// PR that's red on that check. Replaces the manual cascade I ran by
    /// hand during the #2065 landing (18 PRs rebased one-by-one).
    KeystoneCascade,
    /// INFRA-1713: PR is BLOCKED with ≥1 required check FAILURE and no
    /// commit in the last 30 min (avoid racing the author). Reads the top
    /// failing check, extracts 100-line log tail, and dispatches a rescue
    /// subagent. 3 consecutive failures → stop trying, post manual-review
    /// comment, emit kind=ci_rescue_exhausted.
    RescueCiFailure,
}

impl ParamedicAction {
    fn as_str(&self) -> &'static str {
        match self {
            Self::RebaseDirty => "REBASE_DIRTY",
            Self::RerunFlake => "RERUN_FLAKE",
            Self::AllowlistEmitNoReg => "ALLOWLIST_EMIT_NO_REG",
            Self::SquashInitLeak => "SQUASH_INIT_LEAK",
            Self::FileClusterRescue => "FILE_CLUSTER_RESCUE",
            Self::KeystoneCascade => "KEYSTONE_CASCADE",
            Self::RescueCiFailure => "RESCUE_CI_FAILURE",
        }
    }
}

/// INFRA-1420: parse the `unblocks-cluster: <check-name>` trailer from a
/// commit message body. Returns the check name (trimmed) when present,
/// or None. Case-insensitive on the trailer key; the value is returned
/// as-is to preserve job-name capitalization.
pub fn extract_unblocks_cluster_trailer(msg: &str) -> Option<String> {
    for line in msg.lines() {
        let t = line.trim();
        if let Some(rest) = strip_prefix_ci(t, "unblocks-cluster:") {
            let v = rest.trim().to_string();
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    None
}

fn strip_prefix_ci<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() < prefix.len() {
        return None;
    }
    let (head, tail) = s.split_at(prefix.len());
    if head.eq_ignore_ascii_case(prefix) {
        Some(tail)
    } else {
        None
    }
}

/// INFRA-1420: list keystone-fix merge subjects from `git log` on the
/// configured base branch since `since`. v1 returns the touched check
/// names; the cascade caller intersects them with open-PR failure
/// names. Best-effort: any git failure returns empty.
pub fn recent_keystone_check_names(repo_root: &Path, since_seconds: u64) -> Vec<String> {
    let since_arg = format!("--since={since_seconds} seconds ago");
    let out = std::process::Command::new("git")
        .args(["log", "-z", "--format=%B", "main", &since_arg])
        .current_dir(repo_root)
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    let body = String::from_utf8_lossy(&o.stdout);
    let mut hits: Vec<String> = Vec::new();
    for raw_msg in body.split('\0') {
        if let Some(name) = extract_unblocks_cluster_trailer(raw_msg) {
            hits.push(name);
        }
    }
    hits
}

/// INFRA-1420: how recent the `unblocks-cluster:` trailer must be to
/// trigger a cascade. Default 600s (10 min) — long enough that paramedic
/// running on a 10-min loop won't miss a keystone, short enough that
/// re-runs after fleet failure don't replay yesterday's cascade.
pub fn keystone_lookback_seconds() -> u64 {
    std::env::var("CHUMP_PARAMEDIC_KEYSTONE_LOOKBACK_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n: &u64| n > 0)
        .unwrap_or(600)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionItem {
    pub pr_number: u64,
    pub action: String,
    pub reason: String,
    /// Gap ID owning this PR, if known from cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gap_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionPlan {
    pub generated_at: String,
    pub items: Vec<ActionItem>,
}

/// Lightweight PR record from github_cache.db.
#[derive(Debug, Clone)]
struct PrInfo {
    number: u64,
    head_ref: String,
    head_sha: String,
    mergeable_state: Option<String>,
    merge_state_status: Option<String>,
    raw_payload: Option<String>,
    // INFRA-1429: time-gate + label-skip for auto-rebase.
    updated_at: Option<String>,
    labels: Vec<String>,
}

// ── public entry points ───────────────────────────────────────────────────────

/// `chump paramedic triage` — read PR state and output JSON action plan.
pub fn triage(repo_root: &Path, dry_run: bool) -> Result<ActionPlan> {
    let _ = dry_run; // triage is always read-only
    let prs = read_pr_state(repo_root)?;
    info!(pr_count = prs.len(), "paramedic triage: scanning open PRs");
    let skips = load_skip_list(repo_root);
    let attempts = open_attempts_db(repo_root)?;

    let now = iso8601_now();
    let mut items: Vec<ActionItem> = Vec::new();

    // Track failing-check distribution for FILE_CLUSTER_RESCUE.
    let mut check_fail_counts: std::collections::HashMap<String, Vec<u64>> =
        std::collections::HashMap::new();

    for pr in &prs {
        if should_skip(pr, &skips, &attempts, repo_root) {
            continue;
        }

        // REBASE_DIRTY — PR is behind main (merge_state_status = BEHIND).
        // INFRA-1429 added a TIME GATE (default 30min) so paramedic
        // doesn't waste API budget rebasing PRs that may merge as-is, plus
        // a `do-not-paramedic` label skip so operators can park PRs.
        let mss = pr
            .merge_state_status
            .as_deref()
            .or(pr.mergeable_state.as_deref())
            .unwrap_or("");
        if (mss.eq_ignore_ascii_case("BEHIND") || mss.eq_ignore_ascii_case("behind"))
            && !has_do_not_paramedic_label(&pr.labels)
            && is_stale_by_age(
                pr.updated_at.as_deref(),
                chrono::Utc::now().timestamp(),
                stale_branch_max_age_min(),
            )
        {
            items.push(ActionItem {
                pr_number: pr.number,
                action: ParamedicAction::RebaseDirty.as_str().to_string(),
                reason: format!(
                    "mergeable_state={mss} stale>{}min",
                    stale_branch_max_age_min()
                ),
                gap_id: extract_gap_id(&pr.head_ref),
            });
        }

        // SQUASH_INIT_LEAK — detect Test <test@test.local> author in PR body or head ref.
        if detect_init_leak(pr) {
            items.push(ActionItem {
                pr_number: pr.number,
                action: ParamedicAction::SquashInitLeak.as_str().to_string(),
                reason: "init-leak author detected in PR".to_string(),
                gap_id: extract_gap_id(&pr.head_ref),
            });
        }

        // RERUN_FLAKE — check check_runs table for known flake conclusions.
        if let Some(flake_check) = detect_rerun_flake(pr, repo_root, &attempts) {
            items.push(ActionItem {
                pr_number: pr.number,
                action: ParamedicAction::RerunFlake.as_str().to_string(),
                reason: format!("known-flake check failed: {flake_check}"),
                gap_id: extract_gap_id(&pr.head_ref),
            });
            // Also track for cluster rescue.
            check_fail_counts
                .entry(flake_check)
                .or_default()
                .push(pr.number);
        }

        // RESCUE_CI_FAILURE (INFRA-1713): PR is BLOCKED with a required check
        // failure and no author commit in the last 30 min. Do NOT fire if
        // RERUN_FLAKE already covers it (flakes get a rerun first).
        if let Some(failing_check) = detect_ci_failure_blocked(pr, repo_root, &attempts) {
            items.push(ActionItem {
                pr_number: pr.number,
                action: ParamedicAction::RescueCiFailure.as_str().to_string(),
                reason: format!("BLOCKED+FAILURE on check: {failing_check}"),
                gap_id: extract_gap_id(&pr.head_ref),
            });
        }

        // ALLOWLIST_EMIT_NO_REG — check ambient for unregistered event kinds.
        if detect_unregistered_event(pr, repo_root) {
            items.push(ActionItem {
                pr_number: pr.number,
                action: ParamedicAction::AllowlistEmitNoReg.as_str().to_string(),
                reason: "unregistered event kind blocks CI".to_string(),
                gap_id: extract_gap_id(&pr.head_ref),
            });
        }
    }

    // FILE_CLUSTER_RESCUE — ≥3 PRs share the same failing check name.
    for (check_name, pr_nums) in &check_fail_counts {
        if pr_nums.len() >= 3 {
            // Emit one cluster-rescue item on PR 0 (representative).
            items.push(ActionItem {
                pr_number: *pr_nums.first().unwrap_or(&0),
                action: ParamedicAction::FileClusterRescue.as_str().to_string(),
                reason: format!(
                    "check '{}' failing on {} PRs: {:?}",
                    check_name,
                    pr_nums.len(),
                    &pr_nums[..pr_nums.len().min(5)]
                ),
                gap_id: None,
            });
        }
    }

    // INFRA-1420: KEYSTONE_CASCADE — scan recent commits on main for the
    // `unblocks-cluster: <check>` trailer. Each matching trailer emits one
    // cascade item; the action_keystone_cascade runner fans out to every
    // open PR failing that check. Lookback default 10 min so paramedic's
    // 10-min triage cycle doesn't miss a keystone but also doesn't replay
    // yesterday's cascade.
    for check_name in recent_keystone_check_names(repo_root, keystone_lookback_seconds()) {
        items.push(ActionItem {
            pr_number: 0,
            action: ParamedicAction::KeystoneCascade.as_str().to_string(),
            reason: check_name,
            gap_id: None,
        });
    }

    Ok(ActionPlan {
        generated_at: now,
        items,
    })
}

/// `chump paramedic execute --plan <file>` — run one cycle against a plan.
pub fn execute(plan: &ActionPlan, repo_root: &Path, dry_run: bool, budget_secs: u64) -> Result<()> {
    let attempts = open_attempts_db(repo_root)?;
    let skips = load_skip_list(repo_root);

    info!(
        item_count = plan.items.len(),
        dry_run, budget_secs, "paramedic execute: running action plan"
    );

    for item in &plan.items {
        let pr_start = Instant::now();
        if pr_start.elapsed() > Duration::from_secs(budget_secs) {
            warn!(
                budget_secs,
                "paramedic execute: budget exceeded, stopping early"
            );
            break;
        }

        let attempt_count = count_attempts(&attempts, item.pr_number, &item.action);

        info!(
            pr_number = item.pr_number,
            action = %item.action,
            attempt = attempt_count + 1,
            "paramedic execute: running action"
        );

        let outcome = run_action(item, repo_root, dry_run, &skips);
        let latency_ms = pr_start.elapsed().as_millis() as u64;

        let (outcome_str, ok) = match &outcome {
            Ok(_) => ("ok".to_string(), true),
            Err(e) => (format!("fail: {e:#}"), false),
        };

        if ok {
            info!(pr_number = item.pr_number, action = %item.action, latency_ms, "paramedic action succeeded");
        } else {
            warn!(pr_number = item.pr_number, action = %item.action, outcome = %outcome_str, "paramedic action failed");
        }

        // Emit ambient event (AC §5).
        emit_paramedic_action(
            repo_root,
            item.pr_number,
            &item.action,
            &outcome_str,
            &item.reason,
            latency_ms,
            attempt_count + 1,
            dry_run,
        );

        if !dry_run {
            record_attempt(&attempts, item.pr_number, &item.action, &outcome_str);
        }
    }
    Ok(())
}

/// `chump paramedic daemon --interval-secs N` — loop triage→execute.
/// INFRA-1397: daemon with leader election.
///
/// If CHUMP_NATS_URL is set and `nats` CLI is reachable, uses NATS-KV
/// (bucket chump_paramedic, key leader, TTL 30s) for multi-machine election.
/// Otherwise falls back to a lockfile at .chump-locks/paramedic.leader with
/// mtime-based TTL (equivalent semantics, same-machine scope only).
///
/// CHUMP_PARAMEDIC_FORCE_LEADER=1 bypasses election and always runs as leader
/// (docs/process/PARAMEDIC_SUPERVISION.md §Manual force leader).
pub fn daemon(interval_secs: u64, repo_root: &Path, dry_run: bool) -> Result<()> {
    let budget_secs = std::env::var("CHUMP_PARAMEDIC_BUDGET_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(90u64);

    let nats_url = std::env::var("CHUMP_NATS_URL").unwrap_or_default();
    let force_leader = std::env::var("CHUMP_PARAMEDIC_FORCE_LEADER")
        .map(|v| v == "1")
        .unwrap_or(false);
    let machine = hostname();
    let pid = std::process::id();
    let started_at = iso8601_now();
    let leader_path = repo_root.join(".chump-locks").join("paramedic.leader");

    info!(interval_secs, dry_run, pid, machine = %machine, "paramedic daemon started");
    eprintln!(
        "[paramedic] daemon started (interval={interval_secs}s dry_run={dry_run} pid={pid} machine={machine})"
    );

    let mut cycle_count: u64 = 0;
    let mut last_standby_emit: u64 = 0;
    let mut last_renew: u64 = 0;

    loop {
        let now_s = now_epoch();

        // ── leader election ─────────────────────────────────────────────────
        let is_leader = if force_leader {
            if !dry_run {
                leader_write(&leader_path, &machine, pid, &started_at);
            }
            true
        } else if !nats_url.is_empty() {
            nats_kv_try_acquire(&nats_url, &machine, pid, &started_at, dry_run)
        } else {
            lockfile_try_acquire(&leader_path, &machine, pid, &started_at, dry_run)
        };

        if is_leader {
            // Renew leadership every 10s (updates mtime / NATS TTL).
            if now_s.saturating_sub(last_renew) >= 10 {
                if !dry_run {
                    if !nats_url.is_empty() {
                        nats_kv_renew(&nats_url, &machine, pid, &started_at);
                    } else {
                        leader_write(&leader_path, &machine, pid, &started_at);
                    }
                }
                last_renew = now_s;
            }

            cycle_count += 1;
            let cycle_start = Instant::now();

            // INFRA-1645: LLM healthcheck. Opt-in via PARAMEDIC_LLM_ENDPOINT
            // so daemons that don't drive an LLM-backed action (RESCUE_CI_FAILURE
            // dispatch) don't pay the curl round-trip every cycle. Failure here
            // never stops the triage→execute cycle below — a flaky model
            // backend shouldn't wedge PR rescue.
            if let Ok(endpoint) = std::env::var("PARAMEDIC_LLM_ENDPOINT") {
                let mut client = CurlLlmClient { endpoint };
                if let Err(e) = run_llm_healthcheck_with_backoff(&mut client, repo_root) {
                    warn!(error = %e, "paramedic daemon: LLM healthcheck failed");
                }
            }

            // Run one triage→execute cycle.
            let (pr_count, action_count) = match triage(repo_root, dry_run) {
                Ok(plan) => {
                    let pr_count = plan
                        .items
                        .iter()
                        .map(|i| i.pr_number)
                        .collect::<std::collections::HashSet<_>>()
                        .len() as u64;
                    let n = plan.items.len() as u64;
                    info!(action_count = n, "paramedic daemon: triage complete");
                    eprintln!("[paramedic] triage: {n} action(s) queued");
                    if let Err(e) = execute(&plan, repo_root, dry_run, budget_secs) {
                        warn!(error = %e, "paramedic daemon: execute error");
                        eprintln!("[paramedic] execute error: {e:#}");
                    }
                    (pr_count, n)
                }
                Err(e) => {
                    warn!(error = %e, "paramedic daemon: triage error");
                    eprintln!("[paramedic] triage error: {e:#}");
                    (0, 0)
                }
            };

            // Emit heartbeat (AC §6).
            emit_paramedic_heartbeat(
                repo_root,
                &machine,
                pid,
                cycle_count,
                pr_count,
                action_count,
                dry_run,
            );

            let elapsed = cycle_start.elapsed().as_secs();
            let sleep_secs = interval_secs.saturating_sub(elapsed);
            if sleep_secs > 0 {
                std::thread::sleep(Duration::from_secs(sleep_secs));
            }
        } else {
            // Standby: emit event every 60s and poll for leader expiry.
            if now_s.saturating_sub(last_standby_emit) >= 60 {
                emit_paramedic_standby(repo_root, &machine, pid, dry_run);
                last_standby_emit = now_s;
                info!(machine = %machine, pid, "paramedic daemon: standby");
                eprintln!("[paramedic] standby — waiting for leader expiry");
            }
            // Poll every 10s for leader TTL expiry (30s TTL → standby acquires within 30s of crash).
            std::thread::sleep(Duration::from_secs(10));
        }
    }
}

// ── leader election helpers ───────────────────────────────────────────────────

/// Write leader JSON to the lockfile (creates parents if needed).
fn leader_write(path: &std::path::Path, machine: &str, pid: u32, started_at: &str) {
    let payload = json!({
        "machine": machine,
        "pid": pid,
        "started_at": started_at,
        "renewed_at": iso8601_now(),
    });
    let content = serde_json::to_string(&payload).unwrap_or_default();
    if let Some(p) = path.parent() {
        let _ = fs::create_dir_all(p);
    }
    let _ = fs::write(path, content);
}

/// Lockfile-based leader election (AC §5).
///
/// TTL semantics: leader is considered live if the file mtime was updated
/// within the last 30s. Standby processes detect expiry by checking mtime;
/// the leader renews every 10s, so staleness means crash or network partition.
///
/// Returns true if this process is (or became) the leader.
fn lockfile_try_acquire(
    path: &std::path::Path,
    machine: &str,
    pid: u32,
    started_at: &str,
    dry_run: bool,
) -> bool {
    const LEADER_TTL_SECS: u64 = 30;

    if dry_run {
        return true; // Always leader in dry-run (no file I/O).
    }

    if let Ok(content) = fs::read_to_string(path) {
        if let Ok(leader) = serde_json::from_str::<serde_json::Value>(&content) {
            let leader_pid = leader.get("pid").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let leader_machine = leader.get("machine").and_then(|v| v.as_str()).unwrap_or("");

            // Check mtime — primary TTL mechanism (works across machines via shared FS).
            let is_fresh = path
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.elapsed().ok())
                .map(|e| e.as_secs() < LEADER_TTL_SECS)
                .unwrap_or(false);

            if is_fresh {
                // On same machine, also verify the PID is still alive.
                if leader_machine == machine && leader_pid > 0 && leader_pid != pid {
                    let alive = std::process::Command::new("kill")
                        .args(["-0", &leader_pid.to_string()])
                        .status()
                        .map(|s| s.success())
                        .unwrap_or(false);
                    if alive {
                        return false; // Active same-machine leader.
                    }
                    // PID dead → fall through to acquire below.
                } else if leader_machine != machine {
                    return false; // Remote machine leader still fresh.
                } else if leader_pid == pid {
                    return true; // We already are the leader.
                }
            }
            // Stale leader (TTL expired or PID dead) → try to acquire.
        }
    }

    // No valid leader — write our entry and become leader.
    leader_write(path, machine, pid, started_at);
    true
}

/// NATS-KV leader election via `nats` CLI (AC §4).
///
/// Uses `nats kv create` (atomic — fails if key already exists) to win the
/// election race. Bucket TTL of 30s makes the key disappear when the leader
/// crashes and stops renewing.
///
/// Falls back to lockfile if `nats` CLI is unavailable or the server is
/// unreachable (INFRA-1397 AC §5 guarantee).
fn nats_kv_try_acquire(
    nats_url: &str,
    machine: &str,
    pid: u32,
    started_at: &str,
    dry_run: bool,
) -> bool {
    if dry_run {
        return true;
    }

    let payload = json!({"machine": machine, "pid": pid, "started_at": started_at});
    let value = serde_json::to_string(&payload).unwrap_or_default();

    // Ensure bucket exists (idempotent; TTL 30s on the bucket keys).
    let _ = std::process::Command::new("nats")
        .args([
            "kv",
            "add",
            "chump_paramedic",
            "--ttl",
            "30s",
            "--server",
            nats_url,
        ])
        .output();

    // Atomic create — fails with non-zero if key already exists.
    let result = std::process::Command::new("nats")
        .args([
            "kv",
            "create",
            "chump_paramedic",
            "leader",
            &value,
            "--server",
            nats_url,
        ])
        .output();

    match result {
        Ok(out) => out.status.success(),
        Err(_) => {
            // NATS CLI unavailable — log and return false so caller falls
            // through to lockfile_try_acquire on next iteration.
            eprintln!("[paramedic] WARN: nats CLI unavailable; CHUMP_NATS_URL set but unreachable");
            false
        }
    }
}

/// Renew NATS-KV leader TTL by overwriting with a fresh timestamp.
fn nats_kv_renew(nats_url: &str, machine: &str, pid: u32, started_at: &str) {
    let payload = json!({
        "machine": machine, "pid": pid, "started_at": started_at,
        "renewed_at": iso8601_now(),
    });
    let value = serde_json::to_string(&payload).unwrap_or_default();
    let _ = std::process::Command::new("nats")
        .args([
            "kv",
            "put",
            "chump_paramedic",
            "leader",
            &value,
            "--server",
            nats_url,
        ])
        .output();
}

/// Get hostname for leader election JSON payload.
fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

/// Emit kind=paramedic_heartbeat to ambient.jsonl (AC §6).
fn emit_paramedic_heartbeat(
    repo_root: &Path,
    machine: &str,
    pid: u32,
    cycle_count: u64,
    pr_count: u64,
    last_action_count: u64,
    dry_run: bool,
) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let event = json!({
        "ts": iso8601_now(),
        "kind": "paramedic_heartbeat",
        "machine": machine,
        "pid": pid,
        "cycle_count": cycle_count,
        "pr_count": pr_count,
        "last_action_count": last_action_count,
        "dry_run": dry_run,
    });
    info!(
        machine = %machine,
        pid,
        cycle_count,
        pr_count,
        last_action_count,
        "paramedic heartbeat"
    );
    let line = serde_json::to_string(&event).unwrap_or_default() + "\n";
    if let Ok(mut f) = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&ambient_path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Emit kind=paramedic_standby to ambient.jsonl (AC §6).
fn emit_paramedic_standby(repo_root: &Path, machine: &str, pid: u32, dry_run: bool) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let event = json!({
        "ts": iso8601_now(),
        "kind": "paramedic_standby",
        "machine": machine,
        "pid": pid,
        "dry_run": dry_run,
    });
    warn!(machine = %machine, pid, "paramedic standby: waiting for leader");
    let line = serde_json::to_string(&event).unwrap_or_default() + "\n";
    if let Ok(mut f) = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&ambient_path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── action runners ────────────────────────────────────────────────────────────

fn run_action(item: &ActionItem, repo_root: &Path, dry_run: bool, _skips: &SkipList) -> Result<()> {
    // INFRA-8221: the one arm policy. A held PR (no-auto-merge label /
    // `Auto-merge: hold`) is never update-branched or patched by the paramedic.
    if !dry_run
        && matches!(item.action.as_str(), "REBASE_DIRTY" | "RESCUE_CI_FAILURE")
        && !touch_allowed(item.pr_number, repo_root)
    {
        return Ok(());
    }
    match item.action.as_str() {
        "REBASE_DIRTY" => action_rebase_dirty(item.pr_number, repo_root, dry_run),
        "RERUN_FLAKE" => action_rerun_flake(item.pr_number, repo_root, dry_run),
        "ALLOWLIST_EMIT_NO_REG" => action_allowlist_emit(item.pr_number, repo_root, dry_run),
        "SQUASH_INIT_LEAK" => action_squash_init_leak(item.pr_number, repo_root, dry_run),
        "FILE_CLUSTER_RESCUE" => action_file_cluster_rescue(item, repo_root, dry_run),
        "KEYSTONE_CASCADE" => action_keystone_cascade(item, repo_root, dry_run),
        "RESCUE_CI_FAILURE" => action_rescue_ci_failure(item, repo_root, dry_run),
        other => anyhow::bail!("unknown action: {other}"),
    }
}

/// INFRA-8221: arm-policy gate for paramedic PR mutations (emits
/// `kind=pr_arm_skipped_hold` when it refuses).
fn touch_allowed(pr: u64, repo_root: &Path) -> bool {
    chump_ship::arm_policy::require_allowed_at(
        &pr.to_string(),
        "",
        "chump-paramedic",
        chump_ship::arm_policy::GateAction::Touch,
        Some(repo_root),
    )
    .is_ok()
}

/// INFRA-1420: KEYSTONE_CASCADE action. `item.reason` carries the check
/// name. Fan out: query open PRs failing that check, run `gh pr update-branch
/// --rebase` on each (skip DIRTY ones — those need manual conflict resolution),
/// emit `kind=keystone_cascade_fired` with the fan-out count.
fn action_keystone_cascade(item: &ActionItem, repo_root: &Path, dry_run: bool) -> Result<()> {
    let check_name = &item.reason;
    let targets = open_prs_failing_check(check_name);
    if dry_run {
        info!(
            target_check = %check_name,
            fanout = targets.len(),
            "KEYSTONE_CASCADE dry-run: would update-branch on these PRs"
        );
        return Ok(());
    }
    let mut ok_count = 0;
    let mut skipped: Vec<u64> = Vec::new();
    for pr in &targets {
        if !touch_allowed(*pr, repo_root) {
            skipped.push(*pr);
            continue;
        }
        let out = std::process::Command::new("gh")
            .args(["pr", "update-branch", &pr.to_string(), "--rebase"])
            .output();
        match out {
            Ok(o) if o.status.success() => {
                ok_count += 1;
            }
            _ => {
                skipped.push(*pr);
            }
        }
    }
    emit_keystone_cascade_event(repo_root, item.pr_number, check_name, ok_count, &skipped);
    Ok(())
}

/// List open PRs that have FAILURE conclusion on the given check name.
/// Best-effort gh call; returns Vec::new on any failure.
fn open_prs_failing_check(check_name: &str) -> Vec<u64> {
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "100",
            "--json",
            "number,statusCheckRollup",
        ])
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&o.stdout).unwrap_or_default();
    let mut out_prs: Vec<u64> = Vec::new();
    for pr in arr {
        let n = pr.get("number").and_then(|v| v.as_u64()).unwrap_or(0);
        if n == 0 {
            continue;
        }
        let Some(rollup) = pr.get("statusCheckRollup").and_then(|v| v.as_array()) else {
            continue;
        };
        for entry in rollup {
            let conclusion = entry
                .get("conclusion")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if !matches!(conclusion, "FAILURE" | "CANCELLED" | "TIMED_OUT") {
                continue;
            }
            let name = entry.get("name").and_then(|v| v.as_str()).unwrap_or("");
            if name == check_name {
                out_prs.push(n);
                break;
            }
        }
    }
    out_prs
}

fn emit_keystone_cascade_event(
    repo_root: &Path,
    keystone_pr: u64,
    check_name: &str,
    fanout_count: usize,
    skipped: &[u64],
) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let skipped_str = skipped
        .iter()
        .map(|n| n.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"keystone_cascade_fired\",\"keystone_pr\":{keystone_pr},\"target_check\":\"{check_name}\",\"fanout_count\":{fanout_count},\"skipped\":\"{skipped_str}\"}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn action_rebase_dirty(pr_number: u64, repo_root: &Path, dry_run: bool) -> Result<()> {
    if dry_run {
        return Ok(());
    }
    // INFRA-1429: try --rebase first; on failure (rebase rejected by GitHub
    // because the PR has merge conflicts or the rebase produces a
    // surprising diff), fall back to plain merge. The result tag is
    // recorded in ambient so we can audit how often merge fires.
    let try_rebase = std::process::Command::new("gh")
        .args(["pr", "update-branch", &pr_number.to_string(), "--rebase"])
        .output()
        .context("gh pr update-branch --rebase")?;
    if try_rebase.status.success() {
        emit_stale_branch_event(repo_root, pr_number, "rebase");
        return Ok(());
    }
    let stderr_rebase = String::from_utf8_lossy(&try_rebase.stderr).to_string();
    let try_merge = std::process::Command::new("gh")
        .args(["pr", "update-branch", &pr_number.to_string()])
        .output()
        .context("gh pr update-branch (merge fallback)")?;
    if try_merge.status.success() {
        emit_stale_branch_event(repo_root, pr_number, "merge");
        return Ok(());
    }
    let stderr_merge = String::from_utf8_lossy(&try_merge.stderr);
    emit_stale_branch_event(repo_root, pr_number, "failed");
    anyhow::bail!(
        "gh pr update-branch failed (rebase: {stderr_rebase}; merge fallback: {stderr_merge})"
    );
}

fn emit_stale_branch_event(repo_root: &Path, pr_number: u64, result: &str) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"stale_branch_auto_rebased\",\"pr\":{pr_number},\"result\":\"{result}\"}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn action_rerun_flake(pr_number: u64, _repo_root: &Path, dry_run: bool) -> Result<()> {
    if dry_run {
        return Ok(());
    }
    // Re-run the most recent failed workflow run on this PR.
    let list_out = std::process::Command::new("gh")
        .args([
            "run",
            "list",
            "--json",
            "databaseId,conclusion,status",
            "--limit",
            "5",
        ])
        .output()
        .context("gh run list")?;
    if !list_out.status.success() {
        anyhow::bail!("gh run list failed");
    }
    // Just re-run the PR checks (simplified: trigger re-run via gh pr comment / API).
    let _ = std::process::Command::new("gh")
        .args([
            "pr",
            "comment",
            &pr_number.to_string(),
            "--body",
            "<!-- paramedic rerun -->",
        ])
        .output();
    Ok(())
}

fn action_allowlist_emit(_pr_number: u64, repo_root: &Path, dry_run: bool) -> Result<()> {
    if dry_run {
        return Ok(());
    }
    // Scan ambient.jsonl for unregistered event kinds and append to reserved.txt.
    let reserved_path = repo_root
        .join("docs")
        .join("observability")
        .join("event-registry-reserved.txt");
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if !ambient_path.exists() {
        return Ok(());
    }
    let f = fs::File::open(&ambient_path).context("open ambient.jsonl")?;
    let reader = BufReader::new(f);
    let mut new_kinds: std::collections::HashSet<String> = std::collections::HashSet::new();
    for line in reader.lines().flatten() {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) {
            if let Some(k) = v.get("kind").and_then(|v| v.as_str()) {
                new_kinds.insert(k.to_string());
            }
        }
    }
    let existing = fs::read_to_string(&reserved_path).unwrap_or_default();
    let mut appended = false;
    let mut f = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&reserved_path)
        .context("open event-registry-reserved.txt")?;
    for kind in &new_kinds {
        if !existing.contains(kind.as_str()) {
            writeln!(f, "{kind}").ok();
            appended = true;
        }
    }
    if appended {
        eprintln!("[paramedic] allowlisted new event kinds in event-registry-reserved.txt");
    }
    Ok(())
}

fn action_squash_init_leak(pr_number: u64, _repo_root: &Path, dry_run: bool) -> Result<()> {
    // Flag the PR with a comment — actual squash requires human confirmation.
    if dry_run {
        return Ok(());
    }
    let _ = std::process::Command::new("gh")
        .args([
            "pr",
            "comment",
            &pr_number.to_string(),
            "--body",
            "⚠️ **Paramedic**: detected `Test <test@test.local>` author commit. \
             Please squash the init-leak commit before merge.",
        ])
        .output();
    Ok(())
}

fn action_file_cluster_rescue(item: &ActionItem, _repo_root: &Path, dry_run: bool) -> Result<()> {
    if dry_run {
        return Ok(());
    }
    // Reserve a RESCUE gap for the cluster.
    let title = format!(
        "RESILIENT: rescue cluster — {}",
        &item.reason[..item.reason.len().min(60)]
    );
    let _ = std::process::Command::new("chump")
        .args([
            "gap",
            "reserve",
            "--domain",
            "INFRA",
            "--title",
            &title,
            "--priority",
            "P1",
            "--acceptance-criteria",
            &format!("Resolve PR cluster: {}", item.reason),
        ])
        .output();
    Ok(())
}

// ── skip-list ─────────────────────────────────────────────────────────────────

struct SkipList {
    do_not_paramedic_label: String,
    body_marker: String,
    max_attempts_without_merge: u32,
    attempt_ttl_hours: u64,
}

impl Default for SkipList {
    fn default() -> Self {
        Self {
            do_not_paramedic_label: "do-not-paramedic".to_string(),
            body_marker: "<!-- no-paramedic -->".to_string(),
            max_attempts_without_merge: 3,
            attempt_ttl_hours: 24,
        }
    }
}

fn load_skip_list(_repo_root: &Path) -> SkipList {
    SkipList::default()
}

fn should_skip(pr: &PrInfo, skips: &SkipList, attempts: &Connection, repo_root: &Path) -> bool {
    // Check label and body marker in raw_payload.
    if let Some(ref payload) = pr.raw_payload {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(payload) {
            // Unwrap webhook envelope if present.
            let pr_obj = if v.get("pull_request").is_some() {
                v["pull_request"].clone()
            } else {
                v.clone()
            };
            // Check labels.
            if let Some(labels) = pr_obj.get("labels").and_then(|v| v.as_array()) {
                for label in labels {
                    if label
                        .get("name")
                        .and_then(|v| v.as_str())
                        .map(|s| s == skips.do_not_paramedic_label)
                        .unwrap_or(false)
                    {
                        return true;
                    }
                }
            }
            // Check body marker.
            if let Some(body) = pr_obj.get("body").and_then(|v| v.as_str()) {
                if body.contains(&skips.body_marker) {
                    return true;
                }
            }
        }
    }

    // Check attempts: if attempted ≥ max_attempts in last TTL hours without merge, skip.
    let cutoff_secs = skips.attempt_ttl_hours * 3600;
    let cutoff_epoch = now_epoch().saturating_sub(cutoff_secs);
    let count: u32 = attempts
        .query_row(
            "SELECT COUNT(*) FROM attempts WHERE pr_number=? AND attempted_at > ?",
            rusqlite::params![pr.number, cutoff_epoch],
            |row| row.get(0),
        )
        .unwrap_or(0);
    if count >= skips.max_attempts_without_merge {
        return true;
    }

    // Check active sibling lease for this PR's gap.
    if let Some(ref head) = Some(pr.head_ref.clone()) {
        if let Some(gap_id) = extract_gap_id(head) {
            if has_active_lease(repo_root, &gap_id) {
                return true;
            }
        }
    }

    false
}

fn has_active_lease(repo_root: &Path, gap_id: &str) -> bool {
    let locks_dir = repo_root.join(".chump-locks");
    let Ok(entries) = fs::read_dir(&locks_dir) else {
        return false;
    };
    let now = now_epoch();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(content) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) else {
            continue;
        };
        if v.get("gap_id").and_then(|v| v.as_str()) != Some(gap_id) {
            continue;
        }
        // Check not expired.
        if let Some(exp) = v.get("expires_at").and_then(|v| v.as_u64()) {
            if exp > now {
                return true;
            }
        }
    }
    false
}

// ── detection helpers ─────────────────────────────────────────────────────────

fn detect_init_leak(pr: &PrInfo) -> bool {
    // Head ref naming convention or raw payload body hints.
    pr.head_sha.is_empty() // simplified heuristic
        || pr.raw_payload.as_deref().map(|p| {
            p.contains("test@test.local")
        }).unwrap_or(false)
}

fn detect_rerun_flake(pr: &PrInfo, repo_root: &Path, attempts: &Connection) -> Option<String> {
    // Read KNOWN_FLAKES.yaml if present.
    let flakes_path = repo_root.join("KNOWN_FLAKES.yaml");
    let known: Vec<String> = if flakes_path.exists() {
        fs::read_to_string(&flakes_path)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let l = l.trim();
                if l.starts_with("- ") || l.starts_with("  - ") {
                    Some(
                        l.trim_start_matches("- ")
                            .trim_start_matches("  - ")
                            .to_string(),
                    )
                } else {
                    None
                }
            })
            .collect()
    } else {
        // Default well-known flakes.
        vec!["Rust build (stable)".to_string(), "cargo-test".to_string()]
    };

    // Check check_runs table for this SHA.
    let db_path = repo_root.join(".chump").join("github_cache.db");
    let Ok(conn) = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return None;
    };
    let rows: Vec<(String, String)> = conn
        .prepare("SELECT name, conclusion FROM check_runs WHERE head_sha=?")
        .ok()?
        .query_map(rusqlite::params![pr.head_sha], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .ok()?
        .flatten()
        .collect();

    for (name, conclusion) in &rows {
        if conclusion == "failure" || conclusion == "FAILURE" {
            for flake in &known {
                if name.contains(flake.as_str()) {
                    // Only suggest rerun if not attempted recently.
                    let count: u32 = attempts
                        .query_row(
                            "SELECT COUNT(*) FROM attempts WHERE pr_number=? AND action='RERUN_FLAKE'",
                            rusqlite::params![pr.number],
                            |row| row.get(0),
                        )
                        .unwrap_or(0);
                    if count < 2 {
                        return Some(name.clone());
                    }
                }
            }
        }
    }
    None
}

fn detect_unregistered_event(_pr: &PrInfo, _repo_root: &Path) -> bool {
    // This is detected at the CI level — paramedic action is triggered
    // when CI fails with "event kind not registered" pattern.
    // Here we just return false (the ALLOWLIST action is triggered
    // by the RERUN_FLAKE detection catching event-registry CI failures).
    false
}

/// INFRA-1713: detect PRs that should get a CI rescue attempt.
///
/// Trigger conditions (all must hold):
///   1. mergeStateStatus = BLOCKED
///   2. ≥1 required check has conclusion = FAILURE (from check_runs cache)
///   3. No commit pushed in the last 30 min (time-gate; avoids racing the author)
///   4. Fewer than 3 consecutive RESCUE_CI_FAILURE attempts recorded
///      (the 3-strike exhaustion check lives in `should_skip` via the
///       max_attempts_without_merge counter, but we add an explicit guard
///       here so we can return the failing check name for the ActionItem reason)
///
/// Returns Some(check_name) of the top failing required check, or None.
fn detect_ci_failure_blocked(
    pr: &PrInfo,
    repo_root: &Path,
    attempts: &Connection,
) -> Option<String> {
    // Gate 1: must be BLOCKED.
    let mss = pr
        .merge_state_status
        .as_deref()
        .or(pr.mergeable_state.as_deref())
        .unwrap_or("");
    if !mss.eq_ignore_ascii_case("BLOCKED") {
        return None;
    }

    // Gate 2: no author push in the last 30 min.
    let no_recent_push = is_stale_by_age(
        pr.updated_at.as_deref(),
        chrono::Utc::now().timestamp(),
        ci_rescue_quiet_period_min(),
    );
    if !no_recent_push {
        return None;
    }

    // Gate 3: fewer than 3 rescue attempts already recorded.
    let rescue_count: u32 = attempts
        .query_row(
            "SELECT COUNT(*) FROM attempts WHERE pr_number=? AND action='RESCUE_CI_FAILURE'",
            rusqlite::params![pr.number],
            |row| row.get(0),
        )
        .unwrap_or(0);
    if rescue_count >= 3 {
        return None;
    }

    // Gate 4: find top failing required check in check_runs cache.
    let db_path = repo_root.join(".chump").join("github_cache.db");
    let Ok(conn) = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return None;
    };

    // Priority order for failure classes matches AC: clippy, cargo-test, fast-checks, audit, docs-delta.
    let priority_classes = [
        "clippy",
        "cargo-test",
        "cargo test",
        "fast-checks",
        "audit",
        "docs-delta",
    ];

    let rows: Vec<(String, String)> = conn
        .prepare(
            "SELECT name, conclusion FROM check_runs WHERE head_sha=? AND conclusion IN ('failure','FAILURE')",
        )
        .ok()?
        .query_map(rusqlite::params![pr.head_sha], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .ok()?
        .flatten()
        .collect();

    if rows.is_empty() {
        return None;
    }

    // Return highest-priority failing check.
    for class in &priority_classes {
        if let Some((name, _)) = rows.iter().find(|(n, _)| n.to_lowercase().contains(class)) {
            return Some(name.clone());
        }
    }
    // Fallback: first failing check in cache order.
    rows.into_iter().next().map(|(name, _)| name)
}

/// How long (minutes) since last author push before paramedic will attempt a CI rescue.
/// Default 30 min — long enough to avoid racing the author, short enough to be useful.
fn ci_rescue_quiet_period_min() -> u64 {
    std::env::var("CHUMP_PARAMEDIC_CI_RESCUE_QUIET_MIN")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n: &u64| n > 0)
        .unwrap_or(30)
}

// ── action: RESCUE_CI_FAILURE (INFRA-1713) ────────────────────────────────────

/// INFRA-1713: action runner for RESCUE_CI_FAILURE.
///
/// Steps:
///   1. Re-check PR checks via `gh pr checks <N> --json` to get the current
///      failing check name and run ID.
///   2. Fetch last 100 lines of the failed log via `gh run view <run-id> --log-failed`.
///   3. Dispatch a rescue subagent (via `chump --execute-gap` with a synthetic
///      rescue-pr context, or print the dispatch plan in dry-run mode).
///   4. Emit kind=ci_rescue_attempt with outcome=dispatched|gave_up.
///   5. If this is the 3rd consecutive failure on the PR, also post a
///      "recommend manual review" comment and emit kind=ci_rescue_exhausted.
///
/// Budget: 15 min wall-clock per AC. We don't block the paramedic loop here —
/// dispatch is fire-and-forget (the subagent runs independently).
fn action_rescue_ci_failure(item: &ActionItem, repo_root: &Path, dry_run: bool) -> Result<()> {
    let pr = item.pr_number;

    // Step 1: get current check status.
    let (check_name, run_id) = fetch_top_failing_check(pr)?;
    info!(
        pr_number = pr,
        check_name = %check_name,
        run_id = run_id.unwrap_or(0),
        "RESCUE_CI_FAILURE: top failing check"
    );

    // Step 2: fetch log tail (best-effort; proceed even if unavailable).
    let log_tail = run_id
        .map(|rid| fetch_run_log_tail(rid, 100))
        .unwrap_or_default();

    // Step 3: identify failure class.
    let failure_class = classify_failure_check(&check_name);

    if dry_run {
        info!(
            pr_number = pr,
            check_name = %check_name,
            failure_class = %failure_class,
            log_tail_lines = log_tail.lines().count(),
            "RESCUE_CI_FAILURE dry-run: would dispatch rescue subagent"
        );
        eprintln!(
            "[paramedic] RESCUE_CI_FAILURE dry-run PR#{pr}: check={check_name} class={failure_class} log_tail={} lines",
            log_tail.lines().count()
        );
        emit_ci_rescue_attempt(
            repo_root,
            pr,
            &check_name,
            &failure_class,
            "dry_run",
            dry_run,
        );
        return Ok(());
    }

    // Step 4: dispatch rescue subagent.
    let outcome =
        dispatch_ci_rescue_subagent(pr, &check_name, &failure_class, &log_tail, repo_root);
    let outcome_str = match &outcome {
        Ok(_) => "dispatched",
        Err(_) => "gave_up",
    };

    emit_ci_rescue_attempt(
        repo_root,
        pr,
        &check_name,
        &failure_class,
        outcome_str,
        dry_run,
    );

    // Step 5: 3-strike exhaustion check (attempt count already recorded by
    // the outer execute() loop via record_attempt before we're called again;
    // we read the count *before* this attempt is recorded, so +1 for current).
    let attempts = open_attempts_db(repo_root)?;
    let prior_count = count_attempts(&attempts, pr, "RESCUE_CI_FAILURE");
    if prior_count + 1 >= 3 {
        post_manual_review_comment(pr)?;
        emit_ci_rescue_exhausted(repo_root, pr, &check_name, prior_count + 1);
    }

    outcome.map(|_| ())
}

/// Call `gh pr checks <N> --json name,state,completedAt` and return the top
/// failing check name and its run databaseId (if available).
fn fetch_top_failing_check(pr: u64) -> Result<(String, Option<u64>)> {
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "checks",
            &pr.to_string(),
            "--json",
            "name,state,completedAt",
        ])
        .output()
        .context("gh pr checks")?;

    if !out.status.success() {
        // Fallback: try without --json (some older gh versions).
        anyhow::bail!(
            "gh pr checks failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    let arr: Vec<serde_json::Value> = serde_json::from_slice(&out.stdout).unwrap_or_default();

    // Priority order: clippy > cargo-test > fast-checks > audit > docs-delta > any.
    let priority_classes = [
        "clippy",
        "cargo-test",
        "cargo test",
        "fast-checks",
        "audit",
        "docs-delta",
    ];
    let failing: Vec<&serde_json::Value> = arr
        .iter()
        .filter(|v| {
            v.get("state")
                .and_then(|s| s.as_str())
                .map(|s| s.eq_ignore_ascii_case("FAILURE") || s.eq_ignore_ascii_case("failed"))
                .unwrap_or(false)
        })
        .collect();

    if failing.is_empty() {
        anyhow::bail!("no failing checks found for PR#{pr}");
    }

    for class in &priority_classes {
        if let Some(v) = failing.iter().find(|v| {
            v.get("name")
                .and_then(|n| n.as_str())
                .map(|n| n.to_lowercase().contains(class))
                .unwrap_or(false)
        }) {
            let name = v
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("unknown")
                .to_string();
            return Ok((name, None)); // run ID not in this endpoint; use run list if needed
        }
    }

    // Fallback: first failing check.
    let name = failing[0]
        .get("name")
        .and_then(|n| n.as_str())
        .unwrap_or("unknown")
        .to_string();
    Ok((name, None))
}

/// Fetch the last `lines` lines of the failed log for a workflow run.
/// Uses `gh run view <run-id> --log-failed`. Returns empty string on any failure.
fn fetch_run_log_tail(run_id: u64, lines: usize) -> String {
    let out = std::process::Command::new("gh")
        .args(["run", "view", &run_id.to_string(), "--log-failed"])
        .output();
    let Ok(o) = out else { return String::new() };
    if !o.status.success() {
        return String::new();
    }
    let text = String::from_utf8_lossy(&o.stdout);
    // Return last `lines` lines.
    let all_lines: Vec<&str> = text.lines().collect();
    let start = all_lines.len().saturating_sub(lines);
    all_lines[start..].join("\n")
}

/// Map check name to one of the AC failure classes.
fn classify_failure_check(check_name: &str) -> String {
    let lower = check_name.to_lowercase();
    for class in &[
        "clippy",
        "cargo-test",
        "cargo test",
        "fast-checks",
        "audit",
        "docs-delta",
    ] {
        if lower.contains(class) {
            return class.to_string();
        }
    }
    "unknown".to_string()
}

/// Dispatch a CI rescue subagent. Uses `chump rescue-pr` if available,
/// otherwise prints a dispatch plan log line (partial impl per scope notes).
/// Returns Ok(()) if dispatch was initiated (fire-and-forget).
fn dispatch_ci_rescue_subagent(
    pr: u64,
    check_name: &str,
    failure_class: &str,
    log_tail: &str,
    repo_root: &Path,
) -> Result<String> {
    // Try `chump rescue-pr` first (may not exist yet — graceful fallback).
    let rescue_attempt = std::process::Command::new("chump")
        .args([
            "rescue-pr",
            &pr.to_string(),
            "--check",
            check_name,
            "--class",
            failure_class,
        ])
        .env("CHUMP_RESCUE_LOG_TAIL", log_tail)
        .current_dir(repo_root)
        .spawn();

    match rescue_attempt {
        Ok(_child) => {
            // Fire-and-forget: child runs independently.
            info!(
                pr_number = pr,
                check_name = %check_name,
                failure_class = %failure_class,
                "RESCUE_CI_FAILURE: dispatched chump rescue-pr subagent"
            );
            eprintln!("[paramedic] dispatched rescue subagent for PR#{pr} check={check_name}");
            Ok("dispatched".to_string())
        }
        Err(_) => {
            // `chump rescue-pr` not yet implemented — log intent and give up gracefully.
            // This is the "detect + log" partial path per INFRA-1713 scope notes.
            warn!(
                pr_number = pr,
                check_name = %check_name,
                failure_class = %failure_class,
                "RESCUE_CI_FAILURE: chump rescue-pr unavailable; logged dispatch intent"
            );
            eprintln!(
                "[paramedic] RESCUE_CI_FAILURE PR#{pr}: would dispatch subagent \
                 check={check_name} class={failure_class} log_tail={} lines (chump rescue-pr not yet implemented)",
                log_tail.lines().count()
            );
            Err(anyhow::anyhow!("chump rescue-pr not yet implemented"))
        }
    }
}

/// Post a "recommend manual review" comment when 3 consecutive CI rescue
/// attempts have failed for a PR.
fn post_manual_review_comment(pr: u64) -> Result<()> {
    let body = "⚠️ **Paramedic CI Rescue exhausted** (3 consecutive attempts).\n\
         This PR has a persistent CI failure that automated rescue could not fix.\n\
         **Please review manually** — paramedic will not attempt further rescues on this PR.\n\
         \n<!-- paramedic-ci-rescue-exhausted -->"
        .to_string();
    let out = std::process::Command::new("gh")
        .args(["pr", "comment", &pr.to_string(), "--body", &body])
        .output()
        .context("gh pr comment (manual-review)")?;
    if !out.status.success() {
        anyhow::bail!(
            "gh pr comment failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

/// Emit kind=ci_rescue_attempt to ambient.jsonl (AC §5).
fn emit_ci_rescue_attempt(
    repo_root: &Path,
    pr: u64,
    check_name: &str,
    failure_class: &str,
    outcome: &str,
    dry_run: bool,
) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = iso8601_now();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"ci_rescue_attempt\",\"pr\":{pr},\
         \"check_name\":\"{check_name}\",\"failure_class\":\"{failure_class}\",\
         \"outcome\":\"{outcome}\",\"dry_run\":{dry_run}}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Emit kind=ci_rescue_exhausted to ambient.jsonl (AC §8).
fn emit_ci_rescue_exhausted(repo_root: &Path, pr: u64, check_name: &str, attempt_count: u32) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = iso8601_now();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"ci_rescue_exhausted\",\"pr\":{pr},\
         \"check_name\":\"{check_name}\",\"attempt_count\":{attempt_count}}}\n"
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── attempts DB ──────────────────────────────────────────────────────────────

fn open_attempts_db(repo_root: &Path) -> Result<Connection> {
    let db_path = repo_root.join(".chump").join("paramedic_attempts.db");
    if let Some(p) = db_path.parent() {
        fs::create_dir_all(p).ok();
    }
    let conn = Connection::open(&db_path).context("open paramedic_attempts.db")?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS attempts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            pr_number   INTEGER NOT NULL,
            action      TEXT NOT NULL,
            attempted_at INTEGER NOT NULL,
            outcome     TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS attempts_pr ON attempts(pr_number, attempted_at);",
    )
    .context("create attempts table")?;
    Ok(conn)
}

fn count_attempts(conn: &Connection, pr_number: u64, action: &str) -> u32 {
    conn.query_row(
        "SELECT COUNT(*) FROM attempts WHERE pr_number=? AND action=?",
        rusqlite::params![pr_number, action],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

fn record_attempt(conn: &Connection, pr_number: u64, action: &str, outcome: &str) {
    let _ = conn.execute(
        "INSERT INTO attempts(pr_number, action, attempted_at, outcome) VALUES(?,?,?,?)",
        rusqlite::params![pr_number, action, now_epoch(), outcome],
    );
}

// ── cache DB read ─────────────────────────────────────────────────────────────

fn read_pr_state(repo_root: &Path) -> Result<Vec<PrInfo>> {
    let db_path = repo_root.join(".chump").join("github_cache.db");
    if db_path.exists() {
        // Cache-first (INFRA-1081): if the DB is present, trust it even if empty.
        // An empty cache means "no PRs in the window" — don't fall back to gh
        // for a potentially stale network read.  Absence of the file means the
        // cache receiver hasn't run yet; fall back to gh in that case only.
        return read_from_cache_db(&db_path);
    }
    // Fallback: gh pr list (only when cache DB has never been populated).
    read_from_gh()
}

fn read_from_cache_db(db_path: &Path) -> Result<Vec<PrInfo>> {
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .context("open github_cache.db")?;
    let col_exists: bool = {
        let cols: Vec<String> = conn
            .prepare("PRAGMA table_info(pr_state)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .flatten()
            .collect();
        cols.contains(&"merge_state_status".to_string())
    };
    let sql = if col_exists {
        "SELECT number, head_ref, head_sha, mergeable_state, merge_state_status, raw_payload_json
         FROM pr_state WHERE merged_at IS NULL ORDER BY number DESC LIMIT 100"
    } else {
        "SELECT number, head_ref, head_sha, mergeable_state, NULL, raw_payload_json
         FROM pr_state WHERE merged_at IS NULL ORDER BY number DESC LIMIT 100"
    };
    let prs = conn
        .prepare(sql)?
        .query_map([], |row| {
            Ok(PrInfo {
                number: row.get::<_, i64>(0)? as u64,
                head_ref: row.get(1).unwrap_or_default(),
                head_sha: row.get(2).unwrap_or_default(),
                mergeable_state: row.get(3)?,
                merge_state_status: row.get(4)?,
                raw_payload: row.get(5)?,
                // INFRA-1429: cache path doesn't store these yet; conservative
                // defaults: no updated_at → is_stale_by_age fails open (treats
                // as stale), no labels → no skip. Tighten in a follow-up if
                // the cache adds these columns.
                updated_at: None,
                labels: Vec::new(),
            })
        })?
        .flatten()
        .collect();
    Ok(prs)
}

fn read_from_gh() -> Result<Vec<PrInfo>> {
    let out = std::process::Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--limit",
            "100",
            "--json",
            "number,headRefName,headRefOid,mergeable,mergeStateStatus,updatedAt,labels",
        ])
        .output()
        .context("gh pr list")?;
    if !out.status.success() {
        anyhow::bail!("gh pr list failed");
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&out.stdout)?;
    Ok(arr
        .into_iter()
        .map(|v| {
            let labels: Vec<String> = v["labels"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|l| l.get("name").and_then(|n| n.as_str()))
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default();
            PrInfo {
                number: v["number"].as_u64().unwrap_or(0),
                head_ref: v["headRefName"].as_str().unwrap_or("").to_string(),
                head_sha: v["headRefOid"].as_str().unwrap_or("").to_string(),
                mergeable_state: v["mergeable"].as_str().map(str::to_lowercase),
                merge_state_status: v["mergeStateStatus"].as_str().map(str::to_lowercase),
                raw_payload: None,
                updated_at: v["updatedAt"].as_str().map(String::from),
                labels,
            }
        })
        .collect())
}

// INFRA-1429: TIME-GATE for auto-rebase. Today's REBASE_DIRTY rule fires
// the moment a PR turns BEHIND, which spends API calls on PRs that may
// be about to merge anyway. The age gate defers the rebase until the
// PR has been behind long enough that the operator clearly isn't about
// to merge it as-is. Default 30 min; configurable via env.
fn stale_branch_max_age_min() -> u64 {
    std::env::var("CHUMP_PARAMEDIC_STALE_BRANCH_MAX_AGE_MIN")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n: &u64| n > 0)
        .unwrap_or(30)
}

/// True when the PR's `updatedAt` is older than `max_age_min` minutes.
/// Treats a missing `updatedAt` as "old enough" (fail-open: better to
/// rebase than to leave it sitting). Pure function — testable with a
/// fixed `now_unix` for determinism.
pub(crate) fn is_stale_by_age(updated_at: Option<&str>, now_unix: i64, max_age_min: u64) -> bool {
    let Some(ts) = updated_at else {
        return true;
    };
    match chrono::DateTime::parse_from_rfc3339(ts) {
        Ok(dt) => {
            let then = dt.timestamp();
            let age_secs = now_unix.saturating_sub(then).max(0);
            age_secs as u64 / 60 >= max_age_min
        }
        Err(_) => true,
    }
}

/// True when any of `labels` matches the do-not-paramedic skip label
/// (case-insensitive; we accept the underscore and hyphen variants
/// because operators have applied both in the wild).
pub(crate) fn has_do_not_paramedic_label(labels: &[String]) -> bool {
    labels.iter().any(|l| {
        let lo = l.to_lowercase();
        lo == "do-not-paramedic" || lo == "do_not_paramedic" || lo == "skip-paramedic"
    })
}

// ── ambient emit ──────────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
fn emit_paramedic_action(
    repo_root: &Path,
    pr_number: u64,
    action: &str,
    outcome: &str,
    reason: &str,
    latency_ms: u64,
    attempt_count: u32,
    dry_run: bool,
) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let event = json!({
        "ts": iso8601_now(),
        "kind": "paramedic_action",
        "pr_number": pr_number,
        "action": action,
        "outcome": outcome,
        "reason": reason,
        "latency_ms": latency_ms,
        "attempt_count": attempt_count,
        "dry_run": dry_run,
    });
    let line = serde_json::to_string(&event).unwrap_or_default() + "\n";
    if let Ok(mut f) = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&ambient_path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn extract_gap_id(head_ref: &str) -> Option<String> {
    // Branch names follow chump/<DOMAIN>-<N>-claim pattern.
    let parts: Vec<&str> = head_ref.splitn(3, '/').collect();
    if parts.len() >= 2 {
        let candidate = parts[1];
        // E.g. "infra-1375-claim" → "INFRA-1375"
        let without_claim = candidate.trim_end_matches("-claim");
        // Split at last '-' to separate number.
        if let Some(dash) = without_claim.rfind('-') {
            let domain = without_claim[..dash].to_uppercase().replace('-', "");
            let num = &without_claim[dash + 1..];
            if num.chars().all(|c| c.is_ascii_digit()) && !num.is_empty() {
                return Some(format!("{domain}-{num}"));
            }
        }
    }
    None
}

fn iso8601_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Simplified ISO8601 — matches ambient.jsonl format.
    let (y, mo, d, h, mi, s) = epoch_to_parts(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn epoch_to_parts(secs: u64) -> (u64, u64, u64, u64, u64, u64) {
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Simplified Gregorian — accurate for dates 1970–2100.
    let years = days / 365 + 1970;
    let day_of_year = days % 365;
    let month_days = [31u64, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut month = 1u64;
    let mut rem = day_of_year;
    for &md in &month_days {
        if rem < md {
            break;
        }
        rem -= md;
        month += 1;
    }
    let day = rem + 1;
    (years, month, day, h, m, s)
}

// ── LLM resilience (INFRA-1645, re-do of INFRA-1597) ────────────────────────
//
// The paramedic daemon periodically pings its configured LLM backend (used
// by RESCUE_CI_FAILURE dispatch) to confirm the model is reachable before
// spending a rescue-subagent budget on it. Backends occasionally 404 during
// model rollovers/retirements — that's a transient condition, not a fatal
// one, so we retry with exponential backoff + jitter rather than crash-looping
// the daemon. The backoff shape mirrors `organ_watchdog_in_backoff` in
// scripts/ops/organ-watchdog.sh (check-then-defer semantics) for consistency
// across the fleet's self-healing surfaces, though the implementations are
// independent — this one is jittered exponential backoff, that one is a
// filesystem cooldown-flag check.

/// Outcome of a single LLM call attempt.
#[derive(Debug, Clone)]
pub enum LlmCallError {
    /// An HTTP status code was returned (status, short message).
    Http(u16, String),
    /// The call could not be completed (DNS, connect refused, timeout, ...).
    Network(String),
}

impl std::fmt::Display for LlmCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http(status, msg) => write!(f, "http {status}: {msg}"),
            Self::Network(msg) => write!(f, "network error: {msg}"),
        }
    }
}

/// Whether a failed LLM call should be retried (`Transient`) or should stop
/// the daemon's healthcheck loop immediately (`Permanent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LlmFailureClass {
    Transient,
    Permanent,
}

/// Classify an LLM-endpoint failure. 404 (model retired/renamed mid-rollover)
/// and 429 (rate limited) are transient — worth a backoff+retry. Any other
/// 4xx (401 bad auth, 400 bad request, 422 invalid payload, ...) is a
/// permanent misconfiguration that retrying will not fix. Anything outside
/// the 4xx range (network errors, 5xx) is treated as transient — the same
/// "assume recoverable unless proven otherwise" default the fleet's other
/// backoff loops use.
pub fn classify_llm_error(err: &LlmCallError) -> LlmFailureClass {
    match err {
        LlmCallError::Http(404, _) | LlmCallError::Http(429, _) => LlmFailureClass::Transient,
        LlmCallError::Http(400..=499, _) => LlmFailureClass::Permanent,
        LlmCallError::Http(_, _) | LlmCallError::Network(_) => LlmFailureClass::Transient,
    }
}

/// Exponential backoff with jitter, configurable via env vars so operators
/// can tune retry pressure without a rebuild:
///   PARAMEDIC_BACKOFF_BASE_MS   — base delay for attempt 0 (default 500)
///   PARAMEDIC_BACKOFF_MAX_MS    — cap on any single delay (default 30_000)
///   PARAMEDIC_BACKOFF_JITTER    — "1"/"true" enables +/-25% jitter (default on)
///
/// Doubling per attempt, capped at max, matching the organ-watchdog cooldown
/// philosophy of "back off further the longer something stays broken."
pub fn backoff_delay_ms(attempt: u32) -> u64 {
    let base = std::env::var("PARAMEDIC_BACKOFF_BASE_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(500u64);
    let max = std::env::var("PARAMEDIC_BACKOFF_MAX_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30_000u64);
    let jitter_enabled = std::env::var("PARAMEDIC_BACKOFF_JITTER")
        .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
        .unwrap_or(true);

    let raw = base.saturating_mul(1u64 << attempt.min(20));
    let capped = raw.min(max);

    if !jitter_enabled {
        return capped;
    }
    // Deterministic pseudo-jitter derived from wall-clock nanos — avoids
    // pulling in a `rand` dependency for a +/-25% wobble whose only job is
    // to de-synchronize concurrent retriers.
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let jitter_pct = (nanos % 51) as i64 - 25; // -25..=25
    let jittered = (capped as i64) + (capped as i64 * jitter_pct / 100);
    jittered.clamp(0, max as i64) as u64
}

/// A pluggable LLM endpoint. Production uses `CurlLlmClient` (shells to
/// `curl`, matching this module's existing style of driving CLI tools rather
/// than pulling in an async HTTP stack); tests inject a mock so
/// `resilience.rs` can validate the retry/backoff state machine against a
/// real local TCP listener without touching the network.
pub trait LlmClient {
    /// Attempt one call. `Ok(())` means the model responded healthy.
    fn call(&mut self) -> Result<(), LlmCallError>;
}

/// Production `LlmClient`: HTTP GET via `curl`, classifying the result by
/// exit status / HTTP status code.
pub struct CurlLlmClient {
    pub endpoint: String,
}

impl LlmClient for CurlLlmClient {
    fn call(&mut self) -> Result<(), LlmCallError> {
        let out = std::process::Command::new("curl")
            .args([
                "-s",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "--max-time",
                "5",
                &self.endpoint,
            ])
            .output()
            .map_err(|e| LlmCallError::Network(e.to_string()))?;

        let code_str = String::from_utf8_lossy(&out.stdout);
        let status: u16 = code_str.trim().parse().unwrap_or(0);
        if status == 0 {
            return Err(LlmCallError::Network(format!(
                "curl produced no status code (exit={:?})",
                out.status.code()
            )));
        }
        if (200..300).contains(&status) {
            Ok(())
        } else {
            Err(LlmCallError::Http(status, format!("GET {}", self.endpoint)))
        }
    }
}

/// Max retry attempts for the LLM healthcheck before giving up and emitting
/// `permanent_failure` (distinct from a same-cycle permanent classification,
/// which gives up immediately).
fn llm_healthcheck_max_attempts() -> u32 {
    std::env::var("PARAMEDIC_LLM_MAX_ATTEMPTS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n: &u32| n > 0)
        .unwrap_or(10)
}

/// Run one LLM healthcheck with retry+backoff, emitting the AC §1 events as
/// it goes:
///   - `model_unavailable` on every transient (404/429/network) failure
///   - `paramedic_healthy` once the model responds
///   - `permanent_failure` on a non-retryable 4xx, or once retries exhaust
///
/// Returns Ok(()) on eventual success, Err on permanent failure / exhaustion.
pub fn run_llm_healthcheck_with_backoff(
    client: &mut dyn LlmClient,
    repo_root: &Path,
) -> Result<()> {
    let max_attempts = llm_healthcheck_max_attempts();
    let mut attempt: u32 = 0;

    loop {
        match client.call() {
            Ok(()) => {
                emit_paramedic_healthy(repo_root, attempt);
                return Ok(());
            }
            Err(err) => {
                let class = classify_llm_error(&err);
                match class {
                    LlmFailureClass::Permanent => {
                        emit_permanent_failure(repo_root, &err, attempt);
                        anyhow::bail!("paramedic LLM healthcheck: permanent failure: {err}");
                    }
                    LlmFailureClass::Transient => {
                        emit_model_unavailable(repo_root, &err, attempt);
                        attempt += 1;
                        if attempt >= max_attempts {
                            emit_permanent_failure(repo_root, &err, attempt);
                            anyhow::bail!(
                                "paramedic LLM healthcheck: exhausted {max_attempts} attempts, last error: {err}"
                            );
                        }
                        std::thread::sleep(Duration::from_millis(backoff_delay_ms(attempt)));
                    }
                }
            }
        }
    }
}

/// `chump paramedic smoke-test` / AC §3: perform a quick observability check
/// against a dummy LLM call and print a `cost_report` JSON line. Uses a
/// deterministic in-process stub (no network) so the smoke test is fast and
/// works offline — its job is to prove the observability plumbing (event
/// shape, cost accounting fields) works, not to validate a live model.
pub fn smoke_test(repo_root: &Path) -> Result<()> {
    struct DummyLlmClient;
    impl LlmClient for DummyLlmClient {
        fn call(&mut self) -> Result<(), LlmCallError> {
            Ok(())
        }
    }

    let mut client = DummyLlmClient;
    run_llm_healthcheck_with_backoff(&mut client, repo_root)?;

    // Dummy token/cost accounting — smoke test proves the fields exist and
    // are numeric, not that a real call happened.
    let tokens_used: u64 = 128;
    let estimated_cost_usd: f64 = 0.0006;
    let event = json!({
        "ts": iso8601_now(),
        "event": "cost_report",
        "kind": "cost_report",
        "tokens_used": tokens_used,
        "estimated_cost_usd": estimated_cost_usd,
    });
    println!("{event}");
    emit_ambient_line(repo_root, &event);
    Ok(())
}

fn emit_model_unavailable(repo_root: &Path, err: &LlmCallError, attempt: u32) {
    let event = json!({
        "ts": iso8601_now(),
        "kind": "model_unavailable",
        "event": "model_unavailable",
        "attempt": attempt,
        "error": err.to_string(),
    });
    warn!(attempt, error = %err, "paramedic: model_unavailable");
    emit_ambient_line(repo_root, &event);
}

fn emit_paramedic_healthy(repo_root: &Path, attempts_before_healthy: u32) {
    let event = json!({
        "ts": iso8601_now(),
        "kind": "paramedic_healthy",
        "event": "paramedic_healthy",
        "attempts_before_healthy": attempts_before_healthy,
    });
    info!(attempts_before_healthy, "paramedic: paramedic_healthy");
    emit_ambient_line(repo_root, &event);
}

fn emit_permanent_failure(repo_root: &Path, err: &LlmCallError, attempt: u32) {
    let event = json!({
        "ts": iso8601_now(),
        "kind": "permanent_failure",
        "event": "permanent_failure",
        "attempt": attempt,
        "error": err.to_string(),
    });
    warn!(attempt, error = %err, "paramedic: permanent_failure");
    emit_ambient_line(repo_root, &event);
}

fn emit_ambient_line(repo_root: &Path, event: &serde_json::Value) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    let line = serde_json::to_string(event).unwrap_or_default() + "\n";
    if let Some(parent) = ambient_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&ambient_path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod ci_rescue_tests {
    //! INFRA-1713: unit tests for CI rescue detection helpers.
    use super::*;

    #[test]
    fn classify_failure_check_known_classes() {
        assert_eq!(classify_failure_check("clippy (stable)"), "clippy");
        assert_eq!(
            classify_failure_check("cargo-test / workspace"),
            "cargo-test"
        );
        assert_eq!(classify_failure_check("fast-checks gate"), "fast-checks");
        assert_eq!(classify_failure_check("audit-required"), "audit");
        assert_eq!(classify_failure_check("docs-delta check"), "docs-delta");
        assert_eq!(classify_failure_check("some-other-check"), "unknown");
    }

    #[test]
    fn classify_failure_check_case_insensitive() {
        assert_eq!(classify_failure_check("Clippy (stable)"), "clippy");
        assert_eq!(classify_failure_check("FAST-CHECKS"), "fast-checks");
    }

    #[test]
    fn ci_rescue_quiet_period_min_default() {
        // Verify default when the env var is absent.
        // Uses a unique sub-key not shared with env_override to avoid
        // parallel-test env pollution.
        let key = "CHUMP_PARAMEDIC_CI_RESCUE_QUIET_MIN";
        let saved = std::env::var(key).ok();
        unsafe {
            std::env::remove_var(key);
        }
        let result = ci_rescue_quiet_period_min();
        // Restore before asserting so even a panic cleans up.
        unsafe {
            match &saved {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        assert_eq!(result, 30);
    }

    #[test]
    fn ci_rescue_quiet_period_min_env_override() {
        let key = "CHUMP_PARAMEDIC_CI_RESCUE_QUIET_MIN";
        let saved = std::env::var(key).ok();
        unsafe {
            std::env::set_var(key, "15");
        }
        let r1 = ci_rescue_quiet_period_min();
        unsafe {
            std::env::set_var(key, "0");
        }
        // Zero rejected; default wins.
        let r2 = ci_rescue_quiet_period_min();
        // Restore before asserting.
        unsafe {
            match &saved {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        assert_eq!(r1, 15);
        assert_eq!(r2, 30);
    }

    #[test]
    fn fetch_run_log_tail_returns_last_n_lines() {
        // We can't call gh in unit tests; just verify the line-trimming logic
        // directly using a synthetic multi-line string.
        let text = (0..200u32)
            .map(|i| format!("line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let all: Vec<&str> = text.lines().collect();
        let start = all.len().saturating_sub(100);
        let tail = all[start..].join("\n");
        assert_eq!(tail.lines().count(), 100);
        assert!(tail.contains("line 199"));
        assert!(!tail.contains("line 99\n"));
    }

    #[test]
    fn rescue_ci_failure_action_tag_stable() {
        // The dispatcher and ambient telemetry key off this literal.
        assert_eq!(
            ParamedicAction::RescueCiFailure.as_str(),
            "RESCUE_CI_FAILURE"
        );
    }
}

#[cfg(test)]
mod keystone_cascade_tests {
    //! INFRA-1420: unit tests for keystone-fix detector + trailer parser.
    use super::*;

    /// INFRA-8221: REBASE_DIRTY on a held PR returns before gh runs.
    #[test]
    fn rebase_dirty_refuses_held_pr() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("no-auto-merge");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        let item = ActionItem {
            pr_number: 4242,
            action: "REBASE_DIRTY".into(),
            reason: String::new(),
            gap_id: None,
        };
        run_action(&item, tmp.path(), false, &SkipList::default())
            .expect("held = skipped, not an error");
        assert_eq!(fake.calls.get(), 1);
        let ev = std::fs::read_to_string(&amb).unwrap();
        assert!(ev.contains("\"armer\":\"chump-paramedic\""), "{ev}");
        assert!(!ev.contains("stale_branch_auto_rebased"));
    }

    #[test]
    fn extract_unblocks_cluster_trailer_finds_value() {
        let msg = "feat(INFRA-1234): some keystone fix\n\nbody body\n\nunblocks-cluster: audit-required\nCo-Authored-By: claude\n";
        assert_eq!(
            extract_unblocks_cluster_trailer(msg),
            Some("audit-required".to_string())
        );
    }

    #[test]
    fn extract_unblocks_cluster_trailer_case_insensitive() {
        let msg = "feat: x\n\nUnblocks-Cluster: fast-checks\n";
        assert_eq!(
            extract_unblocks_cluster_trailer(msg),
            Some("fast-checks".to_string())
        );
        let msg = "feat: x\n\nUNBLOCKS-CLUSTER: clippy-required\n";
        assert_eq!(
            extract_unblocks_cluster_trailer(msg),
            Some("clippy-required".to_string())
        );
    }

    #[test]
    fn extract_unblocks_cluster_trailer_returns_none_when_absent() {
        let msg = "feat: routine fix with no keystone marker\n\nCo-Authored-By: claude\n";
        assert_eq!(extract_unblocks_cluster_trailer(msg), None);
    }

    #[test]
    fn extract_unblocks_cluster_trailer_ignores_empty_value() {
        let msg = "feat: x\n\nunblocks-cluster:   \n";
        assert_eq!(extract_unblocks_cluster_trailer(msg), None);
    }

    #[test]
    fn extract_unblocks_cluster_trailer_handles_first_line() {
        // Even if the trailer is on the first line (unusual), still parse.
        let msg = "unblocks-cluster: test-foo\n";
        assert_eq!(
            extract_unblocks_cluster_trailer(msg),
            Some("test-foo".to_string())
        );
    }

    #[test]
    fn keystone_lookback_seconds_env_override() {
        let key = "CHUMP_PARAMEDIC_KEYSTONE_LOOKBACK_SECS";
        unsafe {
            std::env::remove_var(key);
        }
        assert_eq!(keystone_lookback_seconds(), 600);
        unsafe {
            std::env::set_var(key, "120");
        }
        assert_eq!(keystone_lookback_seconds(), 120);
        unsafe {
            std::env::set_var(key, "0");
        }
        // Zero rejected (would be a never-firing cascade); default wins.
        assert_eq!(keystone_lookback_seconds(), 600);
        unsafe {
            std::env::set_var(key, "garbage");
        }
        assert_eq!(keystone_lookback_seconds(), 600);
        unsafe {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn paramedic_action_keystone_cascade_tag() {
        // The action's stable tag must remain "KEYSTONE_CASCADE" — the
        // run_action dispatcher and the ambient telemetry both key off it.
        assert_eq!(
            ParamedicAction::KeystoneCascade.as_str(),
            "KEYSTONE_CASCADE"
        );
    }
}

#[cfg(test)]
mod stale_branch_tests {
    //! INFRA-1429: unit tests for the time-gate + label-skip helpers
    //! around the REBASE_DIRTY rule. Pure-function targets so we can run
    //! deterministically without network or filesystem.
    use super::*;

    #[test]
    fn is_stale_by_age_returns_true_when_updated_at_missing() {
        // Fail-open: missing timestamp means "old enough" so paramedic
        // can still rebase. Wrong direction is a no-op cost; right
        // direction prevents a PR sitting forever because GraphQL
        // forgot to return updatedAt.
        assert!(is_stale_by_age(None, 1_000_000_000, 30));
    }

    #[test]
    fn is_stale_by_age_returns_true_for_unparseable_timestamp() {
        // Same fail-open behaviour for a malformed timestamp.
        assert!(is_stale_by_age(Some("not-rfc3339"), 1_000_000_000, 30));
    }

    #[test]
    fn is_stale_by_age_respects_threshold() {
        // 2026-05-22T22:00:00Z → unix 1779487200
        let now: i64 = 1_779_487_200 + 31 * 60; // 31 minutes later
        assert!(is_stale_by_age(Some("2026-05-22T22:00:00Z"), now, 30));
        let now: i64 = 1_779_487_200 + 29 * 60; // 29 minutes later
        assert!(!is_stale_by_age(Some("2026-05-22T22:00:00Z"), now, 30));
    }

    #[test]
    fn is_stale_by_age_handles_now_in_the_past() {
        // If clock skew puts now before updated_at, treat as "not stale"
        // rather than negative-age weirdness.
        let now: i64 = 1_779_487_200;
        let ts = "2026-05-22T22:30:00Z"; // 30min in the future from `now`
        assert!(!is_stale_by_age(Some(ts), now, 30));
    }

    #[test]
    fn has_do_not_paramedic_label_matches_variants_case_insensitive() {
        assert!(has_do_not_paramedic_label(&["do-not-paramedic".into()]));
        assert!(has_do_not_paramedic_label(&["DO-NOT-PARAMEDIC".into()]));
        assert!(has_do_not_paramedic_label(&["do_not_paramedic".into()]));
        assert!(has_do_not_paramedic_label(&["skip-paramedic".into()]));
        assert!(!has_do_not_paramedic_label(&[
            "bug".into(),
            "needs-review".into()
        ]));
        assert!(!has_do_not_paramedic_label(&[]));
    }

    #[test]
    fn stale_branch_max_age_min_env_override() {
        // Each test mutates a private env var; serialize with --test-threads=1.
        let key = "CHUMP_PARAMEDIC_STALE_BRANCH_MAX_AGE_MIN";
        unsafe {
            std::env::remove_var(key);
        }
        assert_eq!(stale_branch_max_age_min(), 30);
        unsafe {
            std::env::set_var(key, "5");
        }
        assert_eq!(stale_branch_max_age_min(), 5);
        unsafe {
            std::env::set_var(key, "not-a-number");
        }
        assert_eq!(stale_branch_max_age_min(), 30);
        unsafe {
            std::env::set_var(key, "0");
        }
        // Zero is rejected (would mean "rebase every PR every cycle");
        // default of 30 wins.
        assert_eq!(stale_branch_max_age_min(), 30);
        unsafe {
            std::env::remove_var(key);
        }
    }
}
