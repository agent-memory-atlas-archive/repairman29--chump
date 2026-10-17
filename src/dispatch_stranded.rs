//! INFRA-8203: detect a dispatch work child that exited with its work
//! uncommitted, and save that work instead of handing bot-merge a dirty tree.
//!
//! Receipt (INFRA-8183 round 3, 2026-10-16T02:13Z on cuphead): a headless
//! agent finished all three fixes, started background builds, called
//! ScheduleWakeup and ended its turn. In `claude -p` that ends the process.
//! Everything was left uncommitted; bot-merge then auto-committed it as a
//! staging commit that INFRA-997 refuses (INFRA-8178, INFRA-8180, INFRA-8202
//! hit the same class that night).
//!
//! Stranded = the worktree has uncommitted changes (tracked or untracked) and
//! zero commits above `origin/main`. The diff, untracked files included, is
//! written as a binary-safe patch to `<dispatch-logs>/<GAP>.stranded.patch`
//! through a throwaway index, so the worktree's own index is never touched.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Dispatch-logs dir override (default `$HOME/.chump/dispatch-logs`).
pub const DISPATCH_LOGS_DIR_ENV: &str = "CHUMP_DISPATCH_LOGS_DIR";

#[derive(Debug, Clone, PartialEq)]
pub struct Stranded {
    /// Paths `git status --porcelain` reported.
    pub files: usize,
    /// `git diff --stat` of the saved patch.
    pub diffstat: String,
    pub patch_path: PathBuf,
}

pub fn dispatch_logs_dir() -> PathBuf {
    if let Ok(d) = std::env::var(DISPATCH_LOGS_DIR_ENV) {
        if !d.trim().is_empty() {
            return PathBuf::from(d);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".chump/dispatch-logs")
}

fn git(worktree: &Path, args: &[&str], index: Option<&Path>) -> Option<std::process::Output> {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(worktree).args(args);
    if let Some(ix) = index {
        cmd.env("GIT_INDEX_FILE", ix);
    }
    cmd.output().ok()
}

fn git_ok(worktree: &Path, args: &[&str], index: Option<&Path>) -> Option<String> {
    let out = git(worktree, args, index)?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Check `worktree` against `base` (normally `origin/main`). Returns
/// `Ok(None)` when the work is not stranded (clean tree, or the agent made at
/// least one commit above `base`), `Ok(Some(..))` after saving the patch.
pub fn check_and_save(
    worktree: &Path,
    gap_id: &str,
    base: &str,
    logs_dir: &Path,
) -> std::io::Result<Option<Stranded>> {
    let Some(status) = git_ok(
        worktree,
        &["status", "--porcelain", "--untracked-files=all"],
        None,
    ) else {
        return Ok(None); // not a git worktree: nothing to judge
    };
    let files = status.lines().filter(|l| !l.trim().is_empty()).count();
    if files == 0 {
        return Ok(None);
    }
    let range = format!("{base}..HEAD");
    let ahead: u64 = git_ok(worktree, &["rev-list", "--count", &range], None)
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    if ahead > 0 {
        return Ok(None);
    }

    std::fs::create_dir_all(logs_dir)?;
    let patch_path = logs_dir.join(format!("{gap_id}.stranded.patch"));
    let index = logs_dir.join(format!(".{gap_id}.stranded.index"));
    let _ = std::fs::remove_file(&index);
    let staged = git_ok(worktree, &["read-tree", "HEAD"], Some(&index)).is_some()
        && git_ok(worktree, &["add", "-A"], Some(&index)).is_some();
    let (patch, diffstat) = if staged {
        (
            git(
                worktree,
                &["diff", "--cached", "--binary", "HEAD"],
                Some(&index),
            )
            .map(|o| o.stdout)
            .unwrap_or_default(),
            git_ok(
                worktree,
                &["diff", "--cached", "--stat", "HEAD"],
                Some(&index),
            )
            .unwrap_or_default(),
        )
    } else {
        // Fallback: tracked changes only.
        (
            git(worktree, &["diff", "--binary", "HEAD"], None)
                .map(|o| o.stdout)
                .unwrap_or_default(),
            git_ok(worktree, &["diff", "--stat", "HEAD"], None).unwrap_or_default(),
        )
    };
    let _ = std::fs::remove_file(&index);
    std::fs::write(&patch_path, patch)?;
    Ok(Some(Stranded {
        files,
        diffstat: diffstat.trim_end().to_string(),
        patch_path,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.invalid")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.invalid")
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        assert!(ok, "git {args:?}");
    }

    /// A repo with an `origin/main` ref at its first commit.
    fn repo() -> tempfile::TempDir {
        let td = tempfile::tempdir().unwrap();
        let d = td.path();
        run(d, &["init", "-q", "-b", "main"]);
        std::fs::write(d.join("a.rs"), "fn a() {}\n").unwrap();
        run(d, &["add", "a.rs"]);
        run(d, &["commit", "-qm", "init"]);
        run(d, &["update-ref", "refs/remotes/origin/main", "HEAD"]);
        td
    }

    #[test]
    fn clean_tree_is_not_stranded() {
        let td = repo();
        let logs = tempfile::tempdir().unwrap();
        assert_eq!(
            check_and_save(td.path(), "INFRA-1", "origin/main", logs.path()).unwrap(),
            None
        );
    }

    #[test]
    fn dirty_tree_with_no_commit_saves_a_patch_that_applies() {
        let td = repo();
        let d = td.path();
        std::fs::write(d.join("a.rs"), "fn a() { let x = 1; }\n").unwrap();
        std::fs::write(d.join("new.rs"), "fn new() {}\n").unwrap();
        let logs = tempfile::tempdir().unwrap();
        let s = check_and_save(d, "INFRA-8203", "origin/main", logs.path())
            .unwrap()
            .expect("stranded");
        assert_eq!(s.files, 2);
        assert_eq!(s.patch_path, logs.path().join("INFRA-8203.stranded.patch"));
        assert!(
            s.diffstat.contains("a.rs") && s.diffstat.contains("new.rs"),
            "{}",
            s.diffstat
        );
        // The worktree's own index was not touched.
        let st = git_ok(d, &["diff", "--cached", "--name-only"], None).unwrap();
        assert!(st.trim().is_empty(), "real index changed: {st}");
        // The patch restores the work on a clean checkout.
        run(d, &["checkout", "--", "a.rs"]);
        std::fs::remove_file(d.join("new.rs")).unwrap();
        run(d, &["apply", s.patch_path.to_str().unwrap()]);
        assert!(std::fs::read_to_string(d.join("a.rs"))
            .unwrap()
            .contains("let x"));
        assert!(d.join("new.rs").exists());
    }

    #[test]
    fn dirty_tree_after_a_commit_is_not_stranded() {
        let td = repo();
        let d = td.path();
        std::fs::write(d.join("b.rs"), "fn b() {}\n").unwrap();
        run(d, &["add", "b.rs"]);
        run(d, &["commit", "-qm", "INFRA-8203: work"]);
        std::fs::write(d.join("scratch.txt"), "x\n").unwrap();
        let logs = tempfile::tempdir().unwrap();
        assert_eq!(
            check_and_save(d, "INFRA-8203", "origin/main", logs.path()).unwrap(),
            None
        );
    }
}
