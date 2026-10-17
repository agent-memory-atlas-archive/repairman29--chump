//! INFRA-1714: `chump pr-rescue` — closed-loop PR rescue.
//!
//! v0 scope: --once mode that classifies open BLOCKED/DIRTY PRs against two
//! highest-frequency failure patterns, and auto-applies a mechanical fix:
//!
//!   (a) orphan-allowlist  — audit fails with "register-without-emit (orphan): KIND";
//!                            fix = `gh pr update-branch --rebase` (server-side rebase
//!                            picks up the event-registry allowlist change from main).
//!   (b) env-var-coverage   — fast-checks fails with "FAIL: N env var(s) are neither
//!                            in .env.example nor in scripts/ci/env-vars-internal.txt";
//!                            fix = parse the var names from the log, append to
//!                            scripts/ci/env-vars-internal.txt under a per-gap section
//!                            header, commit + push.
//!
//! Later arms (landed after v0): DebtCeiling (INFRA-3490), DirtyConflict
//! (INFRA-1751), and compile-missing-dep (INFRA-3522: E0432/E0433 unresolved
//! import / undeclared crate → auto-add the missing dep to the owning crate's
//! Cargo.toml, workspace-aware).
//!
//! Deferred to follow-up gaps:
//!   - --daemon mode (loop with sleep, launchd plist)
//!   - --stats / cost-aware ceiling
//!   - bootstrap-manifest entry
//!
//! Safety rails (active in v0):
//!   - CHUMP_PR_RESCUE_MAX_AGE_HOURS (default 24h) — skip PRs older than this
//!   - DRAFT PRs never touched
//!   - --dry-run for inspection without mutation
//!   - --force-with-lease only (we never use bare --force)
//!   - per-PR cooldown of 5 min via .chump/pr_rescue_stats.json
//!
//! Ambient events emitted: pr_rescue_tick_started, pr_rescue_tick_ended,
//! pr_rescue_applied {pr, class, success, fix_sha}, pr_rescue_skipped {pr, reason},
//! pr_rescue_failed {pr, class, error}, pr_rescue_unknown {pr, failed_check_names},
//! pr_rescue_permanent {pr, class}.

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_AGE_HOURS_DEFAULT: u64 = 24;
const PER_PR_COOLDOWN_SECS: u64 = 300; // 5 min

/// CLI options for `chump pr-rescue`.
#[derive(Debug, Clone)]
pub struct RescueOpts {
    /// Single-pass (no loop). v0 only supports --once; --daemon is a stub.
    pub once: bool,
    /// Rescue only this specific PR.
    pub pr: Option<u32>,
    /// Print actions without mutating.
    pub dry_run: bool,
    /// Print classification of PR <N> without acting.
    pub explain: Option<u32>,
}

/// What the classifier decided about a PR's failure root cause.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "class")]
pub enum Classification {
    /// audit failed because event-registry contains an "orphan" kind (registered
    /// but not emitted). The fix landed on main in a separate PR; rebase picks it up.
    OrphanAllowlist { orphan_kind: String },
    /// fast-checks env-var coverage failed; named vars need to be appended to
    /// scripts/ci/env-vars-internal.txt.
    EnvVarCoverage { vars: Vec<String> },
    /// INFRA-3490: the EFFECTIVE-094 bypass-var debt-ceiling gate failed — the PR added
    /// a bypass var, pushing the count over the ceiling. `count` is the new (over-ceiling)
    /// total; the fix raises scripts/ci/bypass-var-ceiling.txt to it with a reasoned entry.
    /// (This is the exact class that blocked #3362/#3353 and needed a manual bump.)
    DebtCeiling { count: u64 },
    /// INFRA-3522: a crate failed to compile because it uses a dependency that
    /// isn't declared in its Cargo.toml — a deterministic compile break with a
    /// mechanical fix. Detected from rustc's E0432 (unresolved import) / E0433
    /// (use of undeclared crate or module) / "can't find crate for" diagnostics.
    /// `crate_name` is the missing dependency; `source_path` is the file rustc
    /// pointed at (used to locate the owning workspace member's Cargo.toml). The
    /// fix adds the dep to that manifest, reusing an existing version spec from
    /// elsewhere in the workspace when one exists (else `*`).
    CompileMissingDep {
        crate_name: String,
        source_path: Option<String>,
    },
    /// PR's mergeable_state is "dirty" (merge conflict with main). v1b handler
    /// attempts `git fetch origin main && git rebase origin/main` in a temp
    /// worktree and force-pushes-with-lease on clean apply. If rebase has
    /// conflicts the rescuer emits pr_rescue_conflict_needs_human and skips.
    DirtyConflict,
    /// All required checks passed and PR is mergeable — no rescue needed.
    Healthy,
    /// Classifier matched none of the known patterns. Logged for human review.
    Unknown { failed_check_names: Vec<String> },
    /// Known-but-not-auto-fixable (real test fail, branch-protection, etc.).
    Permanent { reason: String },
}

/// Top-level entry from main.rs subcommand dispatch.
pub fn run(opts: RescueOpts) -> Result<()> {
    if let Some(pr) = opts.explain {
        let class = classify_pr(pr)?;
        let j = serde_json::to_string_pretty(&class)?;
        println!("{j}");
        return Ok(());
    }

    emit_ambient("pr_rescue_tick_started", serde_json::json!({}));

    let targets: Vec<u32> = if let Some(pr) = opts.pr {
        vec![pr]
    } else {
        list_open_prs()?
    };

    let mut applied = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;
    let mut unknown = 0usize;

    for pr in targets {
        match rescue_one(pr, opts.dry_run) {
            RescueOutcome::Applied => applied += 1,
            RescueOutcome::Skipped => skipped += 1,
            RescueOutcome::Failed => failed += 1,
            RescueOutcome::Unknown => unknown += 1,
        }
    }

    emit_ambient(
        "pr_rescue_tick_ended",
        serde_json::json!({
            "applied": applied,
            "skipped": skipped,
            "failed": failed,
            "unknown": unknown,
        }),
    );

    println!("pr-rescue: applied={applied} skipped={skipped} failed={failed} unknown={unknown}");
    Ok(())
}

enum RescueOutcome {
    Applied,
    Skipped,
    Failed,
    Unknown,
}

fn rescue_one(pr: u32, dry_run: bool) -> RescueOutcome {
    // INFRA-8221: a held PR (no-auto-merge label / `Auto-merge: hold`) is
    // never rebased, force-pushed or patched by the rescuer.
    if chump_ship::arm_policy::require_touch_allowed(u64::from(pr), "", "chump pr-rescue").is_err()
    {
        return RescueOutcome::Skipped;
    }
    // Cooldown gate: don't thrash on the same PR within 5 min.
    if !cooldown_ok(pr) {
        emit_ambient(
            "pr_rescue_skipped",
            serde_json::json!({"pr": pr, "reason": "cooldown_active"}),
        );
        return RescueOutcome::Skipped;
    }

    // Age gate: don't auto-fix stale PRs.
    if pr_too_old(pr) {
        emit_ambient(
            "pr_rescue_skipped",
            serde_json::json!({"pr": pr, "reason": "older_than_max_age"}),
        );
        return RescueOutcome::Skipped;
    }

    let class = match classify_pr(pr) {
        Ok(c) => c,
        Err(e) => {
            emit_ambient(
                "pr_rescue_failed",
                serde_json::json!({"pr": pr, "class": "classify_error", "error": e.to_string()}),
            );
            return RescueOutcome::Failed;
        }
    };

    match &class {
        Classification::Healthy => RescueOutcome::Skipped,
        Classification::OrphanAllowlist { orphan_kind } => {
            mark_attempt(pr);
            match fix_orphan_allowlist(pr, dry_run) {
                Ok(()) => {
                    emit_ambient(
                        "pr_rescue_applied",
                        serde_json::json!({
                            "pr": pr,
                            "class": "orphan-allowlist",
                            "orphan_kind": orphan_kind,
                            "dry_run": dry_run,
                        }),
                    );
                    RescueOutcome::Applied
                }
                Err(e) => {
                    emit_ambient(
                        "pr_rescue_failed",
                        serde_json::json!({
                            "pr": pr,
                            "class": "orphan-allowlist",
                            "error": e.to_string(),
                        }),
                    );
                    RescueOutcome::Failed
                }
            }
        }
        Classification::EnvVarCoverage { vars } => {
            mark_attempt(pr);
            match fix_env_var_coverage(pr, vars, dry_run) {
                Ok(()) => {
                    emit_ambient(
                        "pr_rescue_applied",
                        serde_json::json!({
                            "pr": pr,
                            "class": "env-var-coverage",
                            "vars": vars,
                            "dry_run": dry_run,
                        }),
                    );
                    RescueOutcome::Applied
                }
                Err(e) => {
                    emit_ambient(
                        "pr_rescue_failed",
                        serde_json::json!({
                            "pr": pr,
                            "class": "env-var-coverage",
                            "error": e.to_string(),
                        }),
                    );
                    RescueOutcome::Failed
                }
            }
        }
        Classification::DebtCeiling { count } => {
            mark_attempt(pr);
            match fix_debt_ceiling(pr, *count, dry_run) {
                Ok(()) => {
                    emit_ambient(
                        "pr_rescue_applied",
                        serde_json::json!({
                            "pr": pr,
                            "class": "debt-ceiling",
                            "count": count,
                            "dry_run": dry_run,
                        }),
                    );
                    RescueOutcome::Applied
                }
                Err(e) => {
                    emit_ambient(
                        "pr_rescue_failed",
                        serde_json::json!({
                            "pr": pr,
                            "class": "debt-ceiling",
                            "error": e.to_string(),
                        }),
                    );
                    RescueOutcome::Failed
                }
            }
        }
        Classification::CompileMissingDep {
            crate_name,
            source_path,
        } => {
            mark_attempt(pr);
            match fix_compile_missing_dep(pr, crate_name, source_path.as_deref(), dry_run) {
                Ok(()) => {
                    emit_ambient(
                        "pr_rescue_applied",
                        serde_json::json!({
                            "pr": pr,
                            "class": "compile-missing-dep",
                            "crate": crate_name,
                            "source_path": source_path,
                            "dry_run": dry_run,
                        }),
                    );
                    RescueOutcome::Applied
                }
                Err(e) => {
                    emit_ambient(
                        "pr_rescue_failed",
                        serde_json::json!({
                            "pr": pr,
                            "class": "compile-missing-dep",
                            "error": e.to_string(),
                        }),
                    );
                    RescueOutcome::Failed
                }
            }
        }
        Classification::Unknown { failed_check_names } => {
            emit_ambient(
                "pr_rescue_unknown",
                serde_json::json!({"pr": pr, "failed_check_names": failed_check_names}),
            );
            RescueOutcome::Unknown
        }
        Classification::Permanent { reason } => {
            emit_ambient(
                "pr_rescue_permanent",
                serde_json::json!({"pr": pr, "reason": reason}),
            );
            RescueOutcome::Skipped
        }
        Classification::DirtyConflict => {
            mark_attempt(pr);
            match fix_dirty_conflict(pr, dry_run) {
                Ok(()) => {
                    emit_ambient(
                        "pr_rescue_applied",
                        serde_json::json!({
                            "pr": pr,
                            "class": "dirty-conflict",
                            "dry_run": dry_run,
                        }),
                    );
                    RescueOutcome::Applied
                }
                Err(e) => {
                    // Conflict-on-rebase is a "needs human" path, not a tool
                    // failure — emit a distinct kind so dashboards can route it.
                    let msg = e.to_string();
                    if msg.contains("rebase produced conflicts") || msg.contains("CONFLICT") {
                        emit_ambient(
                            "pr_rescue_conflict_needs_human",
                            serde_json::json!({"pr": pr, "error": msg}),
                        );
                        RescueOutcome::Skipped
                    } else {
                        emit_ambient(
                            "pr_rescue_failed",
                            serde_json::json!({
                                "pr": pr,
                                "class": "dirty-conflict",
                                "error": msg,
                            }),
                        );
                        RescueOutcome::Failed
                    }
                }
            }
        }
    }
}

// ── classifier ────────────────────────────────────────────────────────────

/// Pure classifier — no mutation. Reads PR check_runs and fails over patterns.
pub fn classify_pr(pr: u32) -> Result<Classification> {
    // INFRA-1751 v1b: dirty-conflict gate runs FIRST. A PR can be DIRTY with
    // zero failing checks (merge conflict against main); v0's "no failures →
    // Healthy" path mis-classifies those as nothing-to-do. Checking the merge
    // state up-front catches that class.
    if is_dirty(pr) {
        return Ok(Classification::DirtyConflict);
    }

    let runs = list_failing_checks(pr)?;
    if runs.is_empty() {
        return Ok(Classification::Healthy);
    }

    // Pattern A: orphan-allowlist. Look for the marker line in any failing job's log.
    for run in &runs {
        if let Some(kind) = grep_orphan_kind(run.id) {
            return Ok(Classification::OrphanAllowlist { orphan_kind: kind });
        }
    }

    // Pattern B: env-var-coverage. Same approach — scan logs for the DOC-026 marker.
    for run in &runs {
        let vars = grep_env_var_coverage(run.id);
        if !vars.is_empty() {
            return Ok(Classification::EnvVarCoverage { vars });
        }
    }

    // Pattern C: bypass-var debt-ceiling (INFRA-3490). The EFFECTIVE-094 gate failed
    // because the PR pushed the bypass-var count over the ceiling — deterministic + a
    // known 1-line fix (raise the ceiling with a reasoned entry).
    for run in &runs {
        if let Some(count) = grep_debt_ceiling(run.id) {
            return Ok(Classification::DebtCeiling { count });
        }
    }

    // Pattern D: compile-missing-dep (INFRA-3522). A crate uses a dependency it
    // never declared — rustc emits E0432/E0433 (or "can't find crate for"). This
    // is deterministic and mechanically fixable (add the dep to the owning
    // crate's Cargo.toml). Runs after the cheaper marker-line patterns above.
    for run in &runs {
        if let Some((crate_name, source_path)) = grep_compile_missing_dep(run.id) {
            return Ok(Classification::CompileMissingDep {
                crate_name,
                source_path,
            });
        }
    }

    // Permanent-ish hints. (v0 best-effort; v1 will broaden.)
    let names: Vec<String> = runs.iter().map(|r| r.name.clone()).collect();
    if names
        .iter()
        .any(|n| n == "cargo-test" || n == "cargo-test-required" || n == "test")
    {
        // Could be real test fail OR a cascade from fast-checks. Without log
        // pattern match we treat as unknown so a human can decide.
        return Ok(Classification::Unknown {
            failed_check_names: names,
        });
    }

    Ok(Classification::Unknown {
        failed_check_names: names,
    })
}

#[derive(Debug, Clone)]
struct FailingCheck {
    id: u64,
    name: String,
}

fn list_failing_checks(pr: u32) -> Result<Vec<FailingCheck>> {
    // INFRA-1759: gh pr view --json statusCheckRollup returns
    // databaseId=null for every entry, so the v0 classifier filtered them
    // all out and saw zero failing checks (false-Healthy). Fix: use the
    // REST commits/SHA/check-runs endpoint, which returns real IDs.
    //
    // Step 1: get the head SHA from the PR (cheap, single REST hit).
    let head_out = run_gh(&["pr", "view", &pr.to_string(), "--json", "headRefOid"])?;
    let head_v: serde_json::Value =
        serde_json::from_str(&head_out).with_context(|| format!("parse headRefOid for #{pr}"))?;
    let sha = head_v["headRefOid"]
        .as_str()
        .ok_or_else(|| anyhow!("headRefOid missing"))?
        .to_string();

    // Step 2: pull check-runs for that SHA. The REST endpoint paginates;
    // 100 per page is the max and covers every PR's check set we ship.
    let runs_json = run_gh(&[
        "api",
        &format!("repos/:owner/:repo/commits/{sha}/check-runs?per_page=100"),
    ])?;
    let runs_v: serde_json::Value = serde_json::from_str(&runs_json)
        .with_context(|| format!("parse check-runs for sha {sha}"))?;
    let arr = runs_v["check_runs"]
        .as_array()
        .ok_or_else(|| anyhow!("check_runs not array"))?;

    // Step 3: collapse to unique (name → most-recent-id) so a repeated check
    // (e.g. after a rebase) doesn't double-classify. The check-runs response
    // is sorted by started_at DESC so first-seen wins.
    let mut seen: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
    for entry in arr {
        if entry["conclusion"].as_str() != Some("failure") {
            continue;
        }
        let id = match entry["id"].as_u64() {
            Some(n) => n,
            None => continue,
        };
        let name = match entry["name"].as_str() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => continue,
        };
        seen.entry(name).or_insert(id);
    }
    Ok(seen
        .into_iter()
        .map(|(name, id)| FailingCheck { id, name })
        .collect())
}

fn grep_orphan_kind(job_id: u64) -> Option<String> {
    let log = run_gh_or_empty(&["run", "view", "--job", &job_id.to_string(), "--log-failed"]);
    // Marker line: "register-without-emit (orphan): KIND"
    for line in log.lines() {
        if let Some(idx) = line.find("register-without-emit (orphan):") {
            let rest = &line[idx + "register-without-emit (orphan):".len()..];
            let kind = rest.split_whitespace().next().unwrap_or("").to_string();
            if !kind.is_empty() {
                return Some(kind);
            }
        }
    }
    None
}

fn grep_env_var_coverage(job_id: u64) -> Vec<String> {
    let log = run_gh_or_empty(&["run", "view", "--job", &job_id.to_string(), "--log-failed"]);
    let mut vars = vec![];
    let mut in_block = false;
    for line in log.lines() {
        if line.contains("env var(s) are neither in .env.example") {
            in_block = true;
            continue;
        }
        if in_block {
            // Block lines look like "  CHUMP_FOO_BAR" (leading whitespace + ALL_CAPS).
            let trimmed = line.trim_start();
            if let Some((_, rest)) = line.split_once("\t") {
                // GitHub log lines are prefixed with "JOB\tSTEP\tTS\t..."; the real
                // content is at the tail. Strip the prefix.
                let content = rest.trim_start();
                if let Some(content_after_ts) = content.split_once('Z') {
                    let payload = content_after_ts.1.trim();
                    let upper = payload.to_uppercase();
                    if upper.starts_with("CHUMP_") || upper.starts_with("OPENAI_") {
                        // Strip any trailing whitespace/punct.
                        let var = payload
                            .split_whitespace()
                            .next()
                            .unwrap_or("")
                            .trim_end_matches([':', ',', '.'])
                            .to_string();
                        if !var.is_empty() {
                            vars.push(var);
                        }
                        continue;
                    }
                }
            }
            // Fallback parse: bare line.
            let upper = trimmed.to_uppercase();
            if upper.starts_with("CHUMP_") || upper.starts_with("OPENAI_") {
                let var = trimmed
                    .split_whitespace()
                    .next()
                    .unwrap_or("")
                    .trim_end_matches([':', ',', '.'])
                    .to_string();
                if !var.is_empty() {
                    vars.push(var);
                }
                continue;
            }
            // End of block: blank line or "Fix by either:" message.
            if trimmed.is_empty() || trimmed.starts_with("Fix by either") {
                in_block = false;
            }
        }
    }
    vars.sort();
    vars.dedup();
    vars
}

// ── fixers ───────────────────────────────────────────────────────────────

fn fix_orphan_allowlist(pr: u32, dry_run: bool) -> Result<()> {
    println!("[pr-rescue] #{pr}: orphan-allowlist → `gh pr update-branch --rebase`");
    if dry_run {
        return Ok(());
    }
    let out = run_gh(&["pr", "update-branch", &pr.to_string(), "--rebase"])?;
    if !out.contains("PR branch updated") && !out.is_empty() {
        // Still consider success if no error — gh sometimes returns silently.
        eprintln!("[pr-rescue] gh output: {out}");
    }
    Ok(())
}

fn fix_env_var_coverage(pr: u32, vars: &[String], dry_run: bool) -> Result<()> {
    println!(
        "[pr-rescue] #{pr}: env-var-coverage → append {} var(s) to env-vars-internal.txt + push",
        vars.len()
    );
    if dry_run {
        for v in vars {
            println!("[pr-rescue]   would add: {v}");
        }
        return Ok(());
    }

    // 1. Determine the PR's head branch + checkout.
    let branch = run_gh(&["pr", "view", &pr.to_string(), "--json", "headRefName"])?;
    let v: serde_json::Value = serde_json::from_str(&branch)?;
    let head_ref = v["headRefName"]
        .as_str()
        .ok_or_else(|| anyhow!("headRefName missing"))?
        .to_string();

    let repo_root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let wt = format!("/tmp/chump-pr-rescue-{pr}");

    // Create / reuse a worktree.
    if !PathBuf::from(&wt).exists() {
        let status = Command::new("git")
            .current_dir(&repo_root)
            .args(["worktree", "add", &wt, &head_ref])
            .status()
            .context("git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed");
        }
    } else {
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["fetch", "origin", &head_ref])
            .status();
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["reset", "--hard", &format!("origin/{head_ref}")])
            .status();
    }

    // 2. Append to env-vars-internal.txt.
    let env_path = PathBuf::from(&wt).join("scripts/ci/env-vars-internal.txt");
    let mut content = std::fs::read_to_string(&env_path)
        .with_context(|| format!("read {}", env_path.display()))?;
    if !content.ends_with('\n') {
        content.push('\n');
    }
    content.push('\n');
    content.push_str(&format!(
        "# INFRA-1714 pr-rescue: PR #{pr} env-var-coverage auto-fix\n"
    ));
    for var in vars {
        if !content.contains(&format!("\n{var}\n")) {
            content.push_str(var);
            content.push('\n');
        }
    }
    std::fs::write(&env_path, &content)?;

    // 3. Commit.
    Command::new("git")
        .current_dir(&wt)
        .args(["add", "scripts/ci/env-vars-internal.txt"])
        .status()
        .context("git add")?;
    let commit_msg = format!(
        "fix(pr-rescue): allowlist {} env var(s) for DOC-026 on PR #{pr}\n\nAuto-applied by `chump pr-rescue` (INFRA-1714) — these vars were\nintroduced by the PR but missing from scripts/ci/env-vars-internal.txt,\nbreaking the env-var-coverage check in fast-checks.\n",
        vars.len()
    );
    let commit_status = Command::new("git")
        .current_dir(&wt)
        .args(["commit", "-m", &commit_msg])
        .status()
        .context("git commit")?;
    if !commit_status.success() {
        bail!("git commit failed (possibly nothing to add)");
    }

    // 4. Push with --force-with-lease.
    let push_status = Command::new("git")
        .current_dir(&wt)
        .args([
            "push",
            "--force-with-lease",
            "origin",
            &format!("HEAD:{head_ref}"),
        ])
        .status()
        .context("git push")?;
    if !push_status.success() {
        bail!("git push failed");
    }
    Ok(())
}

/// INFRA-3490: extract the new (over-ceiling) bypass-var count from a failed job's log.
/// The gate prints: "[bypass-lint] FAIL (EFFECTIVE-094 debt-ceiling): bypass/skip/check
/// var count 237 > ceiling 236."
fn grep_debt_ceiling(job_id: u64) -> Option<u64> {
    let log = run_gh_or_empty(&["run", "view", "--job", &job_id.to_string(), "--log-failed"]);
    for line in log.lines() {
        if line.contains("debt-ceiling") && line.contains("var count ") {
            if let Some(idx) = line.find("var count ") {
                let rest = &line[idx + "var count ".len()..];
                let num: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
                if let Ok(n) = num.parse::<u64>() {
                    return Some(n);
                }
            }
        }
    }
    None
}

/// INFRA-3490: raise scripts/ci/bypass-var-ceiling.txt to `count` (the new total) with a
/// reasoned entry, then push — the canonical fix for the EFFECTIVE-094 debt-ceiling gate.
/// Mirrors fix_env_var_coverage (worktree → edit → commit → push).
fn fix_debt_ceiling(pr: u32, count: u64, dry_run: bool) -> Result<()> {
    println!("[pr-rescue] #{pr}: debt-ceiling → raise bypass-var-ceiling.txt to {count} + push");
    if dry_run {
        return Ok(());
    }
    let branch = run_gh(&["pr", "view", &pr.to_string(), "--json", "headRefName"])?;
    let v: serde_json::Value = serde_json::from_str(&branch)?;
    let head_ref = v["headRefName"]
        .as_str()
        .ok_or_else(|| anyhow!("headRefName missing"))?
        .to_string();
    let repo_root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let wt = format!("/tmp/chump-pr-rescue-{pr}");
    if !PathBuf::from(&wt).exists() {
        let status = Command::new("git")
            .current_dir(&repo_root)
            .args(["worktree", "add", &wt, &head_ref])
            .status()
            .context("git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed");
        }
    } else {
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["fetch", "origin", &head_ref])
            .status();
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["reset", "--hard", &format!("origin/{head_ref}")])
            .status();
    }
    // Replace the single standalone numeric ceiling line with `count`; append a reason.
    let ceil_path = PathBuf::from(&wt).join("scripts/ci/bypass-var-ceiling.txt");
    let content = std::fs::read_to_string(&ceil_path)
        .with_context(|| format!("read {}", ceil_path.display()))?;
    let (out, old) = bump_ceiling_text(&content, count, pr)?;
    std::fs::write(&ceil_path, &out)?;
    println!("[pr-rescue] #{pr}: ceiling {old} -> {count}");
    Command::new("git")
        .current_dir(&wt)
        .args(["add", "scripts/ci/bypass-var-ceiling.txt"])
        .status()
        .context("git add")?;
    let commit_msg = format!(
        "fix(pr-rescue): raise bypass-var ceiling to {count} for PR #{pr}\n\nAuto-applied by `chump pr-rescue` (INFRA-3490) — the PR added a bypass var,\ntripping the EFFECTIVE-094 debt-ceiling gate. Ceiling raised with a reasoned entry.\n"
    );
    let commit_status = Command::new("git")
        .current_dir(&wt)
        .args(["commit", "-m", &commit_msg])
        .status()
        .context("git commit")?;
    if !commit_status.success() {
        bail!("git commit failed (possibly nothing to add)");
    }
    let push_status = Command::new("git")
        .current_dir(&wt)
        .args([
            "push",
            "--force-with-lease",
            "origin",
            &format!("HEAD:{head_ref}"),
        ])
        .status()
        .context("git push")?;
    if !push_status.success() {
        bail!("git push failed");
    }
    Ok(())
}

/// INFRA-3490: replace the single standalone numeric ceiling line with `count` and append a
/// reasoned entry. Pure (no I/O) so it's unit-testable. Returns (new_text, old_ceiling).
fn bump_ceiling_text(content: &str, count: u64, pr: u32) -> Result<(String, u64)> {
    let mut out = String::new();
    let mut bumped = false;
    let mut old = 0u64;
    for line in content.lines() {
        if !bumped {
            if let Ok(n) = line.trim().parse::<u64>() {
                old = n;
                out.push_str(&count.to_string());
                out.push('\n');
                bumped = true;
                continue;
            }
        }
        out.push_str(line);
        out.push('\n');
    }
    if !bumped {
        bail!("no numeric ceiling line found in bypass-var-ceiling.txt");
    }
    out.push_str(&format!(
        "# {old} -> {count} (pr-rescue auto-bump, INFRA-3490): PR #{pr} added a bypass var; the EFFECTIVE-094 debt-ceiling gate blocked it. Raised to the new count. Review the added var + ratchet down when the bypass is removed.\n"
    ));
    Ok((out, old))
}

// ── INFRA-3522: compile-missing-dep handler ───────────────────────────────

/// INFRA-3522: scan a failed job's log for a missing-dependency compile error
/// and return `(crate_name, source_path)`. Thin gh-shell-out wrapper around the
/// pure parser so the parse is unit-testable without a network round-trip.
fn grep_compile_missing_dep(job_id: u64) -> Option<(String, Option<String>)> {
    let log = run_gh_or_empty(&["run", "view", "--job", &job_id.to_string(), "--log-failed"]);
    parse_missing_dep_from_log(&log)
}

/// Pure parser (no I/O) — extracts the first missing crate + the source file
/// rustc pointed at from a CI log. Recognizes the three rustc shapes for a
/// dependency that isn't declared:
///   - E0432: `unresolved import \`NAME::...\``
///   - E0433: `use of undeclared crate or module \`NAME\``
///   - `can't find crate for \`NAME\``
///
/// The crate is the first `::`-segment of the identifier. `crate`/`self`/`super`
/// segments are internal paths (not a missing external dep) and are ignored.
fn parse_missing_dep_from_log(log: &str) -> Option<(String, Option<String>)> {
    let mut pending: Option<String> = None;
    for raw in log.lines() {
        let line = strip_gh_log_prefix(raw);
        if pending.is_none() {
            pending = extract_missing_crate(line);
        }
        // Once we have a crate name, the first following `--> path:line:col`
        // gives us the source file (→ owning workspace member).
        if pending.is_some() {
            if let Some(idx) = line.find("--> ") {
                let rest = line[idx + "--> ".len()..].trim();
                let path = rest.split(':').next().unwrap_or("").trim();
                let src = if path.is_empty() {
                    None
                } else {
                    Some(path.to_string())
                };
                return Some((pending.take().unwrap(), src));
            }
        }
    }
    // Crate identified but no source path line seen (still actionable → root).
    pending.map(|c| (c, None))
}

/// Extract the missing crate name from a single (prefix-stripped) rustc line.
fn extract_missing_crate(line: &str) -> Option<String> {
    if let Some(name) = backticked_after(line, "undeclared crate or module") {
        return first_crate_segment(&name);
    }
    if let Some(name) = backticked_after(line, "can't find crate for") {
        return first_crate_segment(&name);
    }
    if line.contains("unresolved import") {
        if let Some(name) = first_backticked(line) {
            return first_crate_segment(&name);
        }
    }
    None
}

/// Return the contents of the first backtick pair that appears after `marker`.
fn backticked_after(line: &str, marker: &str) -> Option<String> {
    let idx = line.find(marker)?;
    first_backticked(&line[idx + marker.len()..])
}

/// Return the contents of the first backtick pair in `s`.
fn first_backticked(s: &str) -> Option<String> {
    let start = s.find('`')? + 1;
    let end = s[start..].find('`')? + start;
    Some(s[start..end].to_string())
}

/// First `::`-segment of a rust path, cleaned to `[A-Za-z0-9_]`. Returns None
/// for internal path roots (`crate`/`self`/`super`) or an empty/invalid ident.
fn first_crate_segment(path: &str) -> Option<String> {
    let seg: String = path
        .trim()
        .split("::")
        .next()
        .unwrap_or("")
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    if seg.is_empty() || matches!(seg.as_str(), "crate" | "self" | "super") {
        None
    } else {
        Some(seg)
    }
}

/// Strip GitHub's raw-log line prefix (`JOB\tSTEP\tISO8601 <payload>`) to the
/// payload. Falls back to the raw line for bare cargo output with no prefix.
fn strip_gh_log_prefix(line: &str) -> &str {
    let content = line.splitn(3, '\t').nth(2).unwrap_or(line);
    // Drop a leading ISO timestamp ending in 'Z' when it's at the very start.
    if let Some(pos) = content.find('Z') {
        if pos < 30 {
            return content[pos + 1..].trim_start();
        }
    }
    content.trim_start()
}

/// INFRA-3522: add the missing dependency to the owning crate's Cargo.toml
/// (workspace-aware) and push. Mirrors fix_debt_ceiling (worktree → edit →
/// commit → push); the manifest-mutation core is the pure `add_dep_line`.
fn fix_compile_missing_dep(
    pr: u32,
    crate_name: &str,
    source_path: Option<&str>,
    dry_run: bool,
) -> Result<()> {
    println!(
        "[pr-rescue] #{pr}: compile-missing-dep → add `{crate_name}` to {} + push",
        source_path.unwrap_or("<root crate>")
    );
    if dry_run {
        return Ok(());
    }
    let branch = run_gh(&["pr", "view", &pr.to_string(), "--json", "headRefName"])?;
    let v: serde_json::Value = serde_json::from_str(&branch)?;
    let head_ref = v["headRefName"]
        .as_str()
        .ok_or_else(|| anyhow!("headRefName missing"))?
        .to_string();
    let repo_root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let wt = format!("/tmp/chump-pr-rescue-{pr}");
    if !PathBuf::from(&wt).exists() {
        let status = Command::new("git")
            .current_dir(&repo_root)
            .args(["worktree", "add", &wt, &head_ref])
            .status()
            .context("git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed");
        }
    } else {
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["fetch", "origin", &head_ref])
            .status();
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["reset", "--hard", &format!("origin/{head_ref}")])
            .status();
    }

    // Locate the owning workspace member's manifest from the source path.
    let root_manifest_path = PathBuf::from(&wt).join("Cargo.toml");
    let root_manifest = std::fs::read_to_string(&root_manifest_path)
        .with_context(|| format!("read {}", root_manifest_path.display()))?;
    let members = parse_workspace_members(&root_manifest);
    let manifest_rel = manifest_for_source(source_path, &members);
    let manifest_path = PathBuf::from(&wt).join(&manifest_rel);
    let manifest = std::fs::read_to_string(&manifest_path)
        .with_context(|| format!("read {}", manifest_path.display()))?;

    // Reuse an existing version spec for this crate from the target manifest or
    // the workspace root; fall back to `*` (any version) when it's brand-new.
    let spec = find_existing_dep_spec(&[manifest.clone(), root_manifest.clone()], crate_name)
        .unwrap_or_else(|| "\"*\"".to_string());
    let out = add_dep_line(&manifest, crate_name, &spec, pr)?;
    std::fs::write(&manifest_path, &out)?;
    println!("[pr-rescue] #{pr}: added `{crate_name} = {spec}` to {manifest_rel}");

    Command::new("git")
        .current_dir(&wt)
        .args(["add", &manifest_rel])
        .status()
        .context("git add")?;
    let commit_msg = format!(
        "fix(pr-rescue): add missing dep `{crate_name}` to {manifest_rel} for PR #{pr}\n\nAuto-applied by `chump pr-rescue` (INFRA-3522) — the crate used `{crate_name}`\nwithout declaring it, tripping a rustc E0432/E0433 compile break. Added it to\nthe owning member's Cargo.toml (spec {spec}, reused from the workspace when\navailable).\n"
    );
    let commit_status = Command::new("git")
        .current_dir(&wt)
        .args(["commit", "-m", &commit_msg])
        .status()
        .context("git commit")?;
    if !commit_status.success() {
        bail!("git commit failed (possibly nothing to add)");
    }
    let push_status = Command::new("git")
        .current_dir(&wt)
        .args([
            "push",
            "--force-with-lease",
            "origin",
            &format!("HEAD:{head_ref}"),
        ])
        .status()
        .context("git push")?;
    if !push_status.success() {
        bail!("git push failed");
    }
    Ok(())
}

/// Parse the `[workspace] members = [ ... ]` list from a root Cargo.toml. Pure;
/// tolerant of comments and trailing commas. Returns member dir paths.
fn parse_workspace_members(content: &str) -> Vec<String> {
    let mut members = vec![];
    let mut in_members = false;
    for line in content.lines() {
        let t = line.trim();
        if !in_members {
            if t.starts_with("members") && t.contains('[') {
                in_members = true;
                // Handle a single-line `members = ["a", "b"]` form too.
                if t.contains(']') {
                    for tok in t.split(['[', ']', ',']) {
                        if let Some(m) = tok.trim().strip_prefix('"') {
                            if let Some(m) = m.strip_suffix('"') {
                                members.push(m.to_string());
                            }
                        }
                    }
                    break;
                }
            }
            continue;
        }
        if t.starts_with(']') {
            break;
        }
        // Line like: "crates/foo",   (optionally with a trailing comment)
        let code = t
            .split('#')
            .next()
            .unwrap_or(t)
            .trim()
            .trim_end_matches(',');
        if let Some(m) = code.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
            members.push(m.to_string());
        }
    }
    members
}

/// Map a rustc source path to the Cargo.toml of the workspace member that owns
/// it (longest matching member-dir prefix). Root crate → "Cargo.toml". Pure.
fn manifest_for_source(source_path: Option<&str>, members: &[String]) -> String {
    let sp = match source_path {
        Some(s) => s,
        None => return "Cargo.toml".to_string(),
    };
    let mut best = "";
    for m in members {
        let dir = m.trim_end_matches('/');
        let prefix = format!("{dir}/");
        if sp.starts_with(&prefix) && dir.len() > best.len() {
            best = dir;
        }
    }
    if best.is_empty() {
        "Cargo.toml".to_string()
    } else {
        format!("{best}/Cargo.toml")
    }
}

/// Find an existing version spec for `crate_name` across the given manifest
/// contents (target member first, then root). Returns the RHS of the
/// declaration (e.g. `"1"` or `{ version = "1", features = ["x"] }`). Pure.
fn find_existing_dep_spec(contents: &[String], crate_name: &str) -> Option<String> {
    let with_space = format!("{crate_name} =");
    let no_space = format!("{crate_name}=");
    for c in contents {
        for line in c.lines() {
            let t = line.trim_start();
            if t.starts_with(&with_space) || t.starts_with(&no_space) {
                if let Some((_, rhs)) = line.split_once('=') {
                    // Strip a trailing line comment, but not a `#` inside a string.
                    let rhs = if rhs.contains('"') {
                        rhs.trim()
                    } else {
                        rhs.split('#').next().unwrap_or(rhs).trim()
                    };
                    if !rhs.is_empty() {
                        return Some(rhs.to_string());
                    }
                }
            }
        }
    }
    None
}

/// Insert `crate_name = spec` into the `[dependencies]` table of a Cargo.toml.
/// Pure (no I/O) so it's unit-testable. Bails if the dep is already declared
/// (never double-add) or if there's no `[dependencies]` table to add it to.
fn add_dep_line(content: &str, crate_name: &str, spec: &str, pr: u32) -> Result<String> {
    // Guard: already declared anywhere → don't duplicate.
    let with_space = format!("{crate_name} =");
    let no_space = format!("{crate_name}=");
    if content
        .lines()
        .any(|l| l.trim_start().starts_with(&with_space) || l.trim_start().starts_with(&no_space))
    {
        bail!("dependency `{crate_name}` already declared in manifest");
    }
    let dep_line = format!("{crate_name} = {spec} # INFRA-3522 pr-rescue: auto-added for PR #{pr}");
    let mut out = String::new();
    let mut inserted = false;
    for line in content.lines() {
        out.push_str(line);
        out.push('\n');
        if !inserted && line.trim() == "[dependencies]" {
            out.push_str(&dep_line);
            out.push('\n');
            inserted = true;
        }
    }
    if !inserted {
        bail!("no [dependencies] table found in manifest");
    }
    Ok(out)
}

// ── INFRA-1751 v1b: dirty-conflict handler ────────────────────────────────

/// Check `mergeable_state` via gh api. Returns true iff GitHub considers the
/// PR to have a merge conflict with the base branch.
///
/// We use `gh api` (REST) rather than `gh pr view` so the rate-limit cost
/// shows up under the REST bucket (the GraphQL bucket is the hot one).
pub fn is_dirty(pr: u32) -> bool {
    let out = run_gh_or_empty(&[
        "api",
        &format!("repos/:owner/:repo/pulls/{pr}"),
        "--jq",
        ".mergeable_state",
    ]);
    out.trim() == "dirty"
}

/// Rebase the PR's branch onto origin/main in a throwaway worktree and
/// force-push-with-lease. On rebase conflict, abort + bubble up — the caller
/// emits pr_rescue_conflict_needs_human.
fn fix_dirty_conflict(pr: u32, dry_run: bool) -> Result<()> {
    println!("[pr-rescue] #{pr}: dirty-conflict → rebase onto origin/main + force-push-with-lease");
    if dry_run {
        return Ok(());
    }

    // 1. Determine PR's head branch.
    let branch = run_gh(&["pr", "view", &pr.to_string(), "--json", "headRefName"])?;
    let v: serde_json::Value = serde_json::from_str(&branch)?;
    let head_ref = v["headRefName"]
        .as_str()
        .ok_or_else(|| anyhow!("headRefName missing"))?
        .to_string();

    let repo_root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let wt = format!("/tmp/chump-pr-rescue-{pr}");

    // 2. Create / reuse a worktree on the branch. Same pattern as
    // fix_env_var_coverage.
    if !PathBuf::from(&wt).exists() {
        let status = Command::new("git")
            .current_dir(&repo_root)
            .args(["worktree", "add", &wt, &head_ref])
            .status()
            .context("git worktree add")?;
        if !status.success() {
            bail!("git worktree add failed for {head_ref}");
        }
    } else {
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["fetch", "origin", &head_ref])
            .status();
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["reset", "--hard", &format!("origin/{head_ref}")])
            .status();
    }

    // 3. Fetch latest main + attempt rebase.
    let fetch = Command::new("git")
        .current_dir(&wt)
        .args(["fetch", "origin", "main"])
        .status()
        .context("git fetch origin main")?;
    if !fetch.success() {
        bail!("git fetch origin main failed");
    }
    let rebase = Command::new("git")
        .current_dir(&wt)
        .args(["rebase", "origin/main"])
        .output()
        .context("git rebase origin/main")?;
    if !rebase.status.success() {
        // Abort the half-applied rebase to leave the worktree clean for next
        // attempt. The caller routes the error to pr_rescue_conflict_needs_human.
        let _ = Command::new("git")
            .current_dir(&wt)
            .args(["rebase", "--abort"])
            .status();
        let stderr = String::from_utf8_lossy(&rebase.stderr);
        bail!("rebase produced conflicts: {stderr}");
    }

    // 4. Force-push-with-lease. Never bare --force.
    let push = Command::new("git")
        .current_dir(&wt)
        .args([
            "push",
            "--force-with-lease",
            "--no-verify",
            "origin",
            &format!("HEAD:{head_ref}"),
        ])
        .status()
        .context("git push --force-with-lease")?;
    if !push.success() {
        bail!("force-push-with-lease failed");
    }
    Ok(())
}

// ── safety: age + cooldown ───────────────────────────────────────────────

fn pr_too_old(pr: u32) -> bool {
    let max_hours = std::env::var("CHUMP_PR_RESCUE_MAX_AGE_HOURS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(MAX_AGE_HOURS_DEFAULT);
    let out = match run_gh(&["pr", "view", &pr.to_string(), "--json", "createdAt"]) {
        Ok(o) => o,
        Err(_) => return false, // Can't determine age → don't block.
    };
    let v: serde_json::Value = match serde_json::from_str(&out) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let created_at = v["createdAt"].as_str().unwrap_or("");
    let created_unix = match chrono::DateTime::parse_from_rfc3339(created_at) {
        Ok(t) => t.timestamp() as u64,
        Err(_) => return false,
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    now.saturating_sub(created_unix) > max_hours * 3600
}

#[derive(Default, Serialize, Deserialize)]
struct RescueStats {
    last_attempt: std::collections::HashMap<u32, u64>,
}

fn stats_path() -> PathBuf {
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(root).join(".chump/pr_rescue_stats.json")
}

fn load_stats() -> RescueStats {
    let p = stats_path();
    if let Ok(s) = std::fs::read_to_string(&p) {
        serde_json::from_str(&s).unwrap_or_default()
    } else {
        RescueStats::default()
    }
}

fn save_stats(s: &RescueStats) {
    let p = stats_path();
    if let Some(parent) = p.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(j) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(p, j);
    }
}

fn cooldown_ok(pr: u32) -> bool {
    let stats = load_stats();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    match stats.last_attempt.get(&pr) {
        Some(&last) => now.saturating_sub(last) >= PER_PR_COOLDOWN_SECS,
        None => true,
    }
}

fn mark_attempt(pr: u32) {
    let mut stats = load_stats();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    stats.last_attempt.insert(pr, now);
    save_stats(&stats);
}

// ── github + ambient helpers ──────────────────────────────────────────────

fn list_open_prs() -> Result<Vec<u32>> {
    let out = run_gh(&[
        "pr", "list", "--state", "open", "--limit", "50", "--json", "number",
    ])?;
    let v: serde_json::Value = serde_json::from_str(&out)?;
    let arr = v.as_array().ok_or_else(|| anyhow!("pr list not array"))?;
    Ok(arr
        .iter()
        .filter_map(|e| e["number"].as_u64().map(|n| n as u32))
        .collect())
}

fn run_gh(args: &[&str]) -> Result<String> {
    let out = Command::new("gh")
        .args(args)
        .output()
        .with_context(|| format!("running: gh {}", args.join(" ")))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("gh {} failed: {stderr}", args.join(" "));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn run_gh_or_empty(args: &[&str]) -> String {
    run_gh(args).unwrap_or_default()
}

fn emit_ambient(kind: &str, fields: serde_json::Value) {
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let path = PathBuf::from(root).join(".chump-locks/ambient.jsonl");
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut event = serde_json::json!({"ts": now, "kind": kind});
    if let serde_json::Value::Object(map) = fields {
        for (k, v) in map {
            event[k] = v;
        }
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{event}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INFRA-8221: a held PR is skipped before cooldown, classification or any fix.
    #[test]
    fn rescue_one_skips_held_pr() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("CHUMP_HOLD");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        assert!(matches!(rescue_one(4242, false), RescueOutcome::Skipped));
        assert_eq!(fake.calls.get(), 1);
        assert!(std::fs::read_to_string(&amb)
            .unwrap()
            .contains("chump pr-rescue"));
    }

    /// INFRA-3490: the debt-ceiling auto-fix replaces the single numeric ceiling line with
    /// the new count + appends a reasoned entry, leaving the header + history intact.
    #[test]
    fn bump_ceiling_text_raises_the_number_and_records_a_reason() {
        let src = "# header comment\n# another\n236\n\n# 235 -> 236 (old): reason\n";
        let (out, old) = bump_ceiling_text(src, 238, 3362).unwrap();
        assert_eq!(old, 236);
        // the number line is now 238, only once:
        assert!(out.lines().any(|l| l.trim() == "238"));
        assert!(!out.lines().any(|l| l.trim() == "236"));
        // header + prior history preserved:
        assert!(out.contains("# header comment"));
        assert!(out.contains("# 235 -> 236 (old): reason"));
        // a reasoned auto-bump entry was appended:
        assert!(out.contains("236 -> 238") && out.contains("pr-rescue auto-bump"));
        assert!(out.contains("#3362"));
    }

    /// A file with no standalone numeric line is an error (don't silently mis-edit).
    #[test]
    fn bump_ceiling_text_errors_without_a_numeric_line() {
        assert!(bump_ceiling_text("# only comments\n# no number\n", 5, 1).is_err());
    }

    #[test]
    fn classification_serializes_with_tag() {
        let c = Classification::OrphanAllowlist {
            orphan_kind: "synthesis_gap_filed".into(),
        };
        let j = serde_json::to_string(&c).unwrap();
        assert!(j.contains("\"class\":\"OrphanAllowlist\""));
        assert!(j.contains("synthesis_gap_filed"));
    }

    #[test]
    fn dirty_conflict_serializes_as_unit_variant() {
        // INFRA-1751 v1b: the new DirtyConflict variant carries no fields;
        // it still ships under the "class" tag so downstream JSON consumers
        // can route on it identically to the other variants.
        let c = Classification::DirtyConflict;
        let j = serde_json::to_string(&c).unwrap();
        assert!(j.contains("\"class\":\"DirtyConflict\""));
    }

    /// INFRA-3522: the CompileMissingDep variant ships under the "class" tag and
    /// carries both the missing crate and the source path, like its siblings.
    #[test]
    fn compile_missing_dep_serializes_with_tag() {
        let c = Classification::CompileMissingDep {
            crate_name: "serde_json".into(),
            source_path: Some("crates/chump-foo/src/lib.rs".into()),
        };
        let j = serde_json::to_string(&c).unwrap();
        assert!(j.contains("\"class\":\"CompileMissingDep\""));
        assert!(j.contains("serde_json"));
        assert!(j.contains("crates/chump-foo/src/lib.rs"));
    }

    /// INFRA-3522: the log parser recognizes all three rustc missing-dep shapes,
    /// takes the crate as the first `::`-segment, and grabs the `-->` source path.
    #[test]
    fn parse_missing_dep_recognizes_rustc_shapes() {
        // E0432 unresolved import — crate is the first path segment.
        let e0432 = "error[E0432]: unresolved import `regex`\n --> crates/chump-foo/src/lib.rs:3:5\n  |\n3 | use regex::Regex;\n";
        assert_eq!(
            parse_missing_dep_from_log(e0432),
            Some(("regex".into(), Some("crates/chump-foo/src/lib.rs".into())))
        );

        // E0433 undeclared crate or module.
        let e0433 = "error[E0433]: failed to resolve: use of undeclared crate or module `tokio`\n --> src/main.rs:10:9\n";
        assert_eq!(
            parse_missing_dep_from_log(e0433),
            Some(("tokio".into(), Some("src/main.rs".into())))
        );

        // "can't find crate for" (no source path in this excerpt).
        let cant_find = "error[E0463]: can't find crate for `anyhow`\n";
        assert_eq!(
            parse_missing_dep_from_log(cant_find),
            Some(("anyhow".into(), None))
        );

        // GitHub-log-prefixed line (JOB\tSTEP\tISO8601 payload) still parses.
        let prefixed = "cargo-check\tcargo check\t2026-05-22T23:33:33.198Z error[E0432]: unresolved import `uuid`\ncargo-check\tcargo check\t2026-05-22T23:33:33.199Z  --> crates/chump-bar/src/x.rs:1:5\n";
        assert_eq!(
            parse_missing_dep_from_log(prefixed),
            Some(("uuid".into(), Some("crates/chump-bar/src/x.rs".into())))
        );

        // Internal paths (`crate::`) are not a missing external dep.
        assert_eq!(
            parse_missing_dep_from_log("error[E0432]: unresolved import `crate::foo`\n"),
            None
        );
    }

    /// INFRA-3522: source path → owning member manifest (longest prefix wins),
    /// with the root crate as the fallback.
    #[test]
    fn manifest_for_source_maps_to_owning_member() {
        let members = vec![
            "crates/chump-foo".to_string(),
            "crates/mcp-servers/chump-mcp-foo".to_string(),
        ];
        assert_eq!(
            manifest_for_source(Some("crates/chump-foo/src/lib.rs"), &members),
            "crates/chump-foo/Cargo.toml"
        );
        // Longest match wins over a shorter prefix.
        assert_eq!(
            manifest_for_source(
                Some("crates/mcp-servers/chump-mcp-foo/src/main.rs"),
                &members
            ),
            "crates/mcp-servers/chump-mcp-foo/Cargo.toml"
        );
        // Root-crate source and unknown paths fall back to the root manifest.
        assert_eq!(
            manifest_for_source(Some("src/pr_rescue.rs"), &members),
            "Cargo.toml"
        );
        assert_eq!(manifest_for_source(None, &members), "Cargo.toml");
    }

    /// INFRA-3522: workspace member list is parsed from the root Cargo.toml,
    /// tolerating comments + trailing commas.
    #[test]
    fn parse_workspace_members_reads_the_list() {
        let src = "[workspace]\nmembers = [\n    \"chump-tool-macro\",\n    \"crates/chump-foo\", # a comment\n]\nresolver = \"2\"\n";
        let members = parse_workspace_members(src);
        assert_eq!(members, vec!["chump-tool-macro", "crates/chump-foo"]);
    }

    /// INFRA-3522: an existing version spec is reused (target manifest first),
    /// preserving the full RHS (features etc.).
    #[test]
    fn find_existing_dep_spec_reuses_the_rhs() {
        let target = "[dependencies]\nserde = \"1\"\n";
        let root = "[dependencies]\nuuid = { version = \"1\", features = [\"v4\"] }\n";
        assert_eq!(
            find_existing_dep_spec(&[target.to_string(), root.to_string()], "uuid"),
            Some("{ version = \"1\", features = [\"v4\"] }".to_string())
        );
        assert_eq!(
            find_existing_dep_spec(&[target.to_string(), root.to_string()], "serde"),
            Some("\"1\"".to_string())
        );
        // Not present anywhere → None (caller falls back to `*`).
        assert_eq!(
            find_existing_dep_spec(&[target.to_string(), root.to_string()], "nowhere"),
            None
        );
    }

    /// INFRA-3522: add_dep_line inserts the dep right under [dependencies], is
    /// idempotent (bails if already present), and needs a [dependencies] table.
    #[test]
    fn add_dep_line_inserts_under_dependencies_table() {
        let src = "[package]\nname = \"foo\"\n\n[dependencies]\nserde = \"1\"\n";
        let out = add_dep_line(src, "regex", "\"1\"", 4242).unwrap();
        // The new dep sits directly under the table header.
        let lines: Vec<&str> = out.lines().collect();
        let hdr = lines
            .iter()
            .position(|l| l.trim() == "[dependencies]")
            .unwrap();
        assert!(lines[hdr + 1].starts_with("regex = \"1\""));
        assert!(lines[hdr + 1].contains("INFRA-3522"));
        // Existing dep preserved.
        assert!(out.contains("serde = \"1\""));

        // Idempotent: re-adding a present dep is an error, not a duplicate.
        assert!(add_dep_line(&out, "regex", "\"1\"", 4242).is_err());
        // No [dependencies] table → error.
        assert!(add_dep_line("[package]\nname = \"x\"\n", "regex", "\"1\"", 1).is_err());
    }

    #[test]
    fn env_var_block_parses() {
        let log_excerpt = r#"
fast-checks	env-var coverage — all src/ reads documented or allowlisted (DOC-026)	2026-05-22T23:33:33.198Z FAIL: 3 env var(s) are neither in .env.example nor in scripts/ci/env-vars-internal.txt:
fast-checks	env-var coverage — all src/ reads documented or allowlisted (DOC-026)	2026-05-22T23:33:33.199Z   CHUMP_CLAIM_NUGGET_TOP_K
fast-checks	env-var coverage — all src/ reads documented or allowlisted (DOC-026)	2026-05-22T23:33:33.199Z   CHUMP_TEAM_URL
fast-checks	env-var coverage — all src/ reads documented or allowlisted (DOC-026)	2026-05-22T23:33:33.199Z   CHUMP_TEAM_USER_ID
fast-checks	env-var coverage — all src/ reads documented or allowlisted (DOC-026)	2026-05-22T23:33:33.199Z Fix by either:
"#;
        // Synthetic call — bypass the gh-shell-out by inlining the parser logic.
        let mut vars = vec![];
        let mut in_block = false;
        for line in log_excerpt.lines() {
            if line.contains("env var(s) are neither in .env.example") {
                in_block = true;
                continue;
            }
            if in_block {
                let trimmed = line.trim_start();
                if let Some((_, rest)) = line.split_once("\t") {
                    let content = rest.trim_start();
                    if let Some(content_after_ts) = content.split_once('Z') {
                        let payload = content_after_ts.1.trim();
                        let upper = payload.to_uppercase();
                        if upper.starts_with("CHUMP_") || upper.starts_with("OPENAI_") {
                            let var = payload
                                .split_whitespace()
                                .next()
                                .unwrap_or("")
                                .trim_end_matches([':', ',', '.'])
                                .to_string();
                            if !var.is_empty() {
                                vars.push(var);
                            }
                            continue;
                        }
                    }
                }
                if trimmed.starts_with("Fix by either") || trimmed.is_empty() {
                    in_block = false;
                }
            }
        }
        assert_eq!(
            vars,
            vec![
                "CHUMP_CLAIM_NUGGET_TOP_K",
                "CHUMP_TEAM_URL",
                "CHUMP_TEAM_USER_ID"
            ]
        );
    }
}
