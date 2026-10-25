//! verify_claim_branch.rs — INFRA-1649 (re-do of INFRA-1598)
//!
//! `chump verify-claim-branch` is the reusable primitive behind Guard 5
//! (`scripts/git-hooks/pre-push`, RESILIENT-026): given the current git
//! branch and the set of live leases under `.chump-locks/`, confirm the
//! branch actually belongs to the gap this session claimed. The bash guard
//! duplicates this logic inline; this subcommand gives non-hook callers
//! (subagent shipping epilogue, `gh pr create` wrappers, ad-hoc checks) the
//! same check without re-implementing the jq parsing.
//!
//! Root cause this guards against (2026-05-16, INFRA-1427): a subagent's
//! `/tmp/chump-infra-1427` worktree had a gitdir back-reference to the
//! parent session's `.git`, so `git push origin HEAD` resolved HEAD via the
//! parent worktree's branch — pushing `chump/great-ritchie-f0a0ae` instead
//! of `chump/infra-1427-claim`. PR opened on the wrong branch; required
//! manual close + reopen.
//!
//! Verdicts:
//!   - No live leases at all → nothing to check, exit 0.
//!   - Live leases present, none for this session/branch → peer leases,
//!     not off-rails for us, exit 0 (warns on stderr).
//!   - This session's lease names a gap whose expected branch
//!     (`chump/<gap-id-lowercase>-claim`) matches the current branch → OK,
//!     exit 0.
//!   - Mismatch → exit 1 with the named-branch diff, emits
//!     `kind=claim_branch_mismatch` to ambient.jsonl.
//!
//! INFRA-779 sentinel: if the worktree `git rev-parse --show-toplevel`
//! resolves to doesn't match the current working directory (the linked-
//! worktree gitdir-back-reference-corruption class), emits
//! `kind=worktree_gitdir_corrupt` regardless of the branch verdict — this is
//! the underlying mechanism that produces the INFRA-1427 failure mode above.

use chump_agent_lease::{current_session_id, list_active, Lease};
use chump_verify::claim_branch_observability;
use std::path::Path;
use std::process::Command;

fn expected_branch(gap_id: &str) -> String {
    format!("chump/{}-claim", gap_id.to_lowercase())
}

fn current_branch(repo_root: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["-C"])
        .arg(repo_root)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_lowercase();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn resolved_toplevel(repo_root: &Path) -> Option<std::path::PathBuf> {
    let out = Command::new("git")
        .args(["-C"])
        .arg(repo_root)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        std::fs::canonicalize(s).ok()
    }
}

fn emit_ambient(repo_root: &Path, kind: &str, fields: &[(&str, &str)]) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        if v.is_empty() {
            continue;
        }
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

/// Verdict returned by [`verify`]. Exit-code mapping lives in [`run_cli`].
pub enum Verdict {
    /// No live leases — nothing to check.
    NoLeases,
    /// Live leases exist but none belong to this session/branch.
    PeerLeasesOnly,
    /// This session's claimed branch matches the current branch.
    Ok { gap_id: String },
    /// This session's claimed branch does NOT match the current branch.
    Mismatch {
        gap_id: String,
        current: String,
        expected: String,
    },
}

/// Core check, split out from `run_cli` so it's unit-testable without a
/// subprocess (`git`) or real `.chump-locks/` — callers pass leases + branch
/// directly.
pub fn verify(current_branch: &str, session_id: &str, leases: &[Lease]) -> Verdict {
    if leases.is_empty() {
        return Verdict::NoLeases;
    }

    // Prefer a lease whose gap_id's expected branch matches ours (mirrors
    // Guard 5 bash: branch-name is the join key, not session_id alone,
    // because a session can hold leases for paths without a gap_id).
    let branch_match = leases
        .iter()
        .filter_map(|l| l.gap_id.as_ref().map(|g| (l, g)))
        .find(|(lease, gap_id)| {
            expected_branch(gap_id) == current_branch
                || lease
                    .branch
                    .as_deref()
                    .map(|b| b.eq_ignore_ascii_case(current_branch))
                    .unwrap_or(false)
        });

    if let Some((lease, gap_id)) = branch_match {
        let _ = lease; // branch already matches expected — OK regardless of session_id
        return Verdict::Ok {
            gap_id: gap_id.clone(),
        };
    }

    // No lease matches this branch by name. If THIS session holds a lease
    // with a gap_id, that's a real mismatch (we're off-rails). Otherwise
    // the leases present belong to peers — not our problem.
    if let Some(mine) = leases
        .iter()
        .find(|l| l.session_id == session_id && l.gap_id.is_some())
    {
        let gap_id = mine.gap_id.clone().unwrap();
        let expected = mine
            .branch
            .clone()
            .unwrap_or_else(|| expected_branch(&gap_id));
        return Verdict::Mismatch {
            gap_id,
            current: current_branch.to_string(),
            expected,
        };
    }

    Verdict::PeerLeasesOnly
}

/// Emits the INFRA-1649 structured observability event to stdout and the
/// `cost reported: $X` line to stderr, then returns `exit_code` so callers
/// can `return emit_observability_event(...)` as their final statement.
fn emit_observability_event(
    status: claim_branch_observability::RunStatus,
    started: std::time::Instant,
    failure_class: claim_branch_observability::FailureClass,
    exit_code: i32,
) -> i32 {
    let duration_ms = started.elapsed().as_millis() as u64;
    let cost_per_second = claim_branch_observability::cost_per_second_from_env();
    let event = claim_branch_observability::build_event(
        status,
        duration_ms,
        failure_class,
        cost_per_second,
    );
    println!("{event}");
    eprintln!("cost reported: ${}", event["cost_estimate"]);
    exit_code
}

pub fn run_cli(args: &[String]) -> i32 {
    use claim_branch_observability::{FailureClass, RunStatus};
    let started = std::time::Instant::now();
    let want_json = args.iter().any(|a| a == "--json");
    let repo_root = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));

    // Test-only hook (INFRA-1649): simulate a hung `git` subprocess without
    // actually blocking, so the timeout/transient observability path is
    // deterministically exercisable in CI.
    if std::env::var("CHUMP_VERIFY_CLAIM_BRANCH_FORCE_TIMEOUT").as_deref() == Ok("1") {
        eprintln!("chump verify-claim-branch: TIMEOUT waiting for git to resolve the branch");
        return emit_observability_event(RunStatus::Timeout, started, FailureClass::Transient, 124);
    }

    // --branch <name> overrides git branch detection (explicit callers /
    // tests that don't want to depend on the cwd's actual HEAD).
    let branch_override = args
        .iter()
        .position(|a| a == "--branch")
        .and_then(|i| args.get(i + 1))
        .cloned();

    let Some(branch) = branch_override.or_else(|| current_branch(&repo_root)) else {
        eprintln!("chump verify-claim-branch: could not resolve current git branch");
        return emit_observability_event(RunStatus::Failure, started, FailureClass::Permanent, 1);
    };

    // INFRA-779 sentinel: linked-worktree gitdir back-reference corruption.
    // If `git rev-parse --show-toplevel` doesn't resolve to our own cwd, the
    // worktree's gitdir is pointing somewhere else — the exact mechanism
    // behind the INFRA-1427 wrong-branch push.
    if let (Some(resolved), Ok(cwd)) = (
        resolved_toplevel(&repo_root),
        std::fs::canonicalize(&repo_root),
    ) {
        if resolved != cwd {
            // scanner-anchor: "kind":"worktree_gitdir_corrupt"
            emit_ambient(
                &repo_root,
                "worktree_gitdir_corrupt",
                &[
                    ("cwd", &cwd.display().to_string()),
                    ("resolved_toplevel", &resolved.display().to_string()),
                    ("branch", &branch),
                ],
            );
            eprintln!(
                "chump verify-claim-branch: WARN worktree gitdir mismatch — cwd={} resolved_toplevel={} (INFRA-779)",
                cwd.display(),
                resolved.display()
            );
        }
    }

    let session_id = current_session_id();
    let leases = list_active();
    let verdict = verify(&branch, &session_id, &leases);

    match verdict {
        Verdict::NoLeases => {
            if want_json {
                println!("{{\"verdict\":\"no_leases\",\"branch\":\"{branch}\"}}");
            }
            emit_observability_event(RunStatus::Success, started, FailureClass::None, 0)
        }
        Verdict::PeerLeasesOnly => {
            eprintln!(
                "chump verify-claim-branch: WARN {} live lease(s) present but none match branch '{branch}' — peer leases, not blocking",
                leases.len()
            );
            if want_json {
                println!("{{\"verdict\":\"peer_leases_only\",\"branch\":\"{branch}\"}}");
            }
            emit_observability_event(RunStatus::Success, started, FailureClass::None, 0)
        }
        Verdict::Ok { gap_id } => {
            // scanner-anchor: "kind":"claim_branch_verified"
            emit_ambient(
                &repo_root,
                "claim_branch_verified",
                &[("gap_id", &gap_id), ("branch", &branch)],
            );
            if want_json {
                println!("{{\"verdict\":\"ok\",\"gap_id\":\"{gap_id}\",\"branch\":\"{branch}\"}}");
            } else {
                println!("chump verify-claim-branch: OK — branch '{branch}' matches claimed gap {gap_id}");
            }
            emit_observability_event(RunStatus::Success, started, FailureClass::None, 0)
        }
        Verdict::Mismatch {
            gap_id,
            current,
            expected,
        } => {
            // scanner-anchor: "kind":"claim_branch_mismatch"
            emit_ambient(
                &repo_root,
                "claim_branch_mismatch",
                &[
                    ("gap_id", &gap_id),
                    ("current_branch", &current),
                    ("expected_branch", &expected),
                ],
            );
            if want_json {
                println!(
                    "{{\"verdict\":\"mismatch\",\"gap_id\":\"{gap_id}\",\"current_branch\":\"{current}\",\"expected_branch\":\"{expected}\"}}"
                );
            } else {
                eprintln!();
                eprintln!("ERROR: pushing branch '{current}' but active lease for gap {gap_id} expects branch '{expected}'.");
                eprintln!("Likely cause: cd'd into wrong worktree.");
                eprintln!("Use: cd to your claim worktree OR run `chump --release` if abandoning this claim.");
                eprintln!();
            }
            emit_observability_event(RunStatus::Failure, started, FailureClass::Permanent, 1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lease(session_id: &str, gap_id: Option<&str>) -> Lease {
        Lease {
            session_id: session_id.to_string(),
            paths: vec![],
            taken_at: "2026-01-01T00:00:00Z".to_string(),
            expires_at: "2099-01-01T00:00:00Z".to_string(),
            heartbeat_at: "2026-01-01T00:00:00Z".to_string(),
            purpose: "test".to_string(),
            worktree: "".to_string(),
            gap_id: gap_id.map(|s| s.to_string()),
            pending_new_gap: None,
            branch: None,
        }
    }

    #[test]
    fn no_leases_is_ok() {
        matches!(verify("chump/foo", "s1", &[]), Verdict::NoLeases);
    }

    #[test]
    fn matching_branch_is_ok() {
        let leases = vec![lease("s1", Some("INFRA-1649"))];
        match verify("chump/infra-1649-claim", "s1", &leases) {
            Verdict::Ok { gap_id } => assert_eq!(gap_id, "INFRA-1649"),
            _ => panic!("expected Ok"),
        }
    }

    #[test]
    fn mismatched_branch_for_own_session_is_mismatch() {
        let leases = vec![lease("s1", Some("INFRA-1649"))];
        match verify("chump/some-other-branch", "s1", &leases) {
            Verdict::Mismatch {
                gap_id,
                current,
                expected,
            } => {
                assert_eq!(gap_id, "INFRA-1649");
                assert_eq!(current, "chump/some-other-branch");
                assert_eq!(expected, "chump/infra-1649-claim");
            }
            _ => panic!("expected Mismatch"),
        }
    }

    #[test]
    fn peer_lease_only_is_not_blocking() {
        let leases = vec![lease("other-session", Some("INFRA-9999"))];
        matches!(
            verify("chump/my-unrelated-branch", "s1", &leases),
            Verdict::PeerLeasesOnly
        );
    }

    #[test]
    fn lease_without_gap_id_does_not_block() {
        let leases = vec![lease("s1", None)];
        matches!(
            verify("chump/my-unrelated-branch", "s1", &leases),
            Verdict::PeerLeasesOnly
        );
    }
}
