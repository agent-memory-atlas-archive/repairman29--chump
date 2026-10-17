//! ZERO-WASTE-133: keep agent searches out of a worktree's build output.
//!
//! Receipt (2026-10-16, cuphead): a headless repair agent spent 33 of its 60
//! minutes blocked on one `ugrep` that ran across a worktree holding
//! gigabytes of cargo build artefacts. Every worktree an agent works in is
//! created by `chump claim` or `chump dispatch`, so both call
//! [`write_search_ignore`] right after `git worktree add`.
//!
//! What honours what (checked against the real tools, not assumed):
//! - ripgrep, fd and ag read `.ignore` in every directory they walk, so the
//!   file written here excludes the build dirs for them. ugrep reads it too
//!   when asked (`--ignore-files=.ignore`).
//! - Claude Code shadows `grep` in its Bash tool with its embedded ugrep run
//!   as `ugrep -G --ignore-files --hidden -I --exclude-dir=.git ...`; a bare
//!   `--ignore-files` means `.gitignore`. That is how an agent's `grep -r`
//!   is served, so the worktree's `.gitignore` must also list the build dirs.
//!   For the Chump repo the tracked `.gitignore` already does
//!   (`/target`, `/.cargo-build-target`, `.cargo-*-target/`);
//!   [`gitignore_covers_build_dirs`] lets callers and tests verify it.
//!
//! The `.ignore` file is kept out of `git status` through the repo's
//! `info/exclude` (shared by all linked worktrees), so it can never be
//! committed by `git add -A`, in Chump or in an external repo.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The file name ripgrep / fd / ag honour per directory.
pub const SEARCH_IGNORE_FILE: &str = ".ignore";

/// Build-output directories excluded from agent searches.
pub const SEARCH_EXCLUDED_DIRS: &[&str] = &[
    "target",
    ".cargo-build-target",
    ".cargo-test-target",
    "target-local",
];

/// First line of the file; identifies a file this module wrote so a rewrite
/// never clobbers a `.ignore` the repo itself tracks.
const MARKER: &str =
    "# ZERO-WASTE-133: written at worktree creation by chump claim / chump dispatch.";

/// The `.ignore` body.
pub fn search_ignore_contents() -> String {
    let mut s = String::new();
    s.push_str(MARKER);
    s.push('\n');
    s.push_str("# Keeps rg / fd / ag (and ugrep --ignore-files=.ignore) out of build output.\n");
    for d in SEARCH_EXCLUDED_DIRS {
        s.push('/');
        s.push_str(d);
        s.push_str("/\n");
    }
    s
}

/// Write `<worktree>/.ignore` and keep it out of `git status`.
///
/// Returns the path written, or `None` when the worktree already has a
/// `.ignore` this module did not write (left untouched). Errors are returned
/// for the caller to log; neither caller fails the claim/dispatch on them.
pub fn write_search_ignore(worktree: &Path) -> std::io::Result<Option<PathBuf>> {
    let path = worktree.join(SEARCH_IGNORE_FILE);
    if let Ok(existing) = std::fs::read_to_string(&path) {
        if !existing.starts_with(MARKER) {
            return Ok(None);
        }
    }
    std::fs::write(&path, search_ignore_contents())?;
    exclude_from_git_status(worktree);
    Ok(Some(path))
}

/// Append `/.ignore` to the repo's `info/exclude` (idempotent). Best effort:
/// outside a git checkout this is a no-op.
fn exclude_from_git_status(worktree: &Path) {
    let Ok(out) = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["rev-parse", "--git-path", "info/exclude"])
        .output()
    else {
        return;
    };
    if !out.status.success() {
        return;
    }
    let rel = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if rel.is_empty() {
        return;
    }
    let exclude = {
        let p = PathBuf::from(&rel);
        if p.is_absolute() {
            p
        } else {
            worktree.join(p)
        }
    };
    let line = format!("/{SEARCH_IGNORE_FILE}");
    let current = std::fs::read_to_string(&exclude).unwrap_or_default();
    if current.lines().any(|l| l.trim() == line) {
        return;
    }
    if let Some(parent) = exclude.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut next = current;
    if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str(&line);
    next.push('\n');
    let _ = std::fs::write(&exclude, next);
}

/// True when the worktree's root `.gitignore` excludes both `target` and
/// `.cargo-build-target` (the dirs Claude Code's ugrep-backed `grep` needs
/// excluded via `.gitignore`). Pattern match is deliberately literal: the
/// forms git, ripgrep and ugrep all agree on.
pub fn gitignore_covers_build_dirs(worktree: &Path) -> bool {
    let Ok(body) = std::fs::read_to_string(worktree.join(".gitignore")) else {
        return false;
    };
    let lines: Vec<&str> = body.lines().map(str::trim).collect();
    let covers = |d: &str| {
        lines.iter().any(|l| {
            let l = l.trim_end_matches('/');
            l == d || l == format!("/{d}") || (d.starts_with(".cargo-") && l == ".cargo-*-target")
        })
    };
    covers("target") && covers(".cargo-build-target")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git_repo() -> tempfile::TempDir {
        let td = tempfile::tempdir().unwrap();
        let ok = Command::new("git")
            .arg("-C")
            .arg(td.path())
            .args(["init", "-q"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        assert!(ok, "git init");
        td
    }

    #[test]
    fn writes_ignore_listing_every_build_dir() {
        let td = git_repo();
        let p = write_search_ignore(td.path()).unwrap().expect("written");
        let body = std::fs::read_to_string(p).unwrap();
        for d in SEARCH_EXCLUDED_DIRS {
            assert!(body.contains(&format!("/{d}/")), "missing {d}: {body}");
        }
    }

    #[test]
    fn ignore_file_is_invisible_to_git_status() {
        let td = git_repo();
        write_search_ignore(td.path()).unwrap();
        let out = Command::new("git")
            .arg("-C")
            .arg(td.path())
            .args(["status", "--porcelain", "--untracked-files=all"])
            .output()
            .unwrap();
        let s = String::from_utf8_lossy(&out.stdout);
        assert!(!s.contains(".ignore"), "status shows .ignore: {s}");
        // Idempotent: a second write does not duplicate the exclude line.
        write_search_ignore(td.path()).unwrap();
        let ex = std::fs::read_to_string(td.path().join(".git/info/exclude")).unwrap();
        assert_eq!(ex.lines().filter(|l| *l == "/.ignore").count(), 1);
    }

    #[test]
    fn never_clobbers_a_repo_owned_ignore() {
        let td = git_repo();
        std::fs::write(td.path().join(".ignore"), "vendor/\n").unwrap();
        assert!(write_search_ignore(td.path()).unwrap().is_none());
        assert_eq!(
            std::fs::read_to_string(td.path().join(".ignore")).unwrap(),
            "vendor/\n"
        );
    }

    #[test]
    fn gitignore_coverage_check() {
        let td = tempfile::tempdir().unwrap();
        assert!(!gitignore_covers_build_dirs(td.path()));
        std::fs::write(td.path().join(".gitignore"), "/target\n.cargo-*-target/\n").unwrap();
        assert!(gitignore_covers_build_dirs(td.path()));
        std::fs::write(td.path().join(".gitignore"), "/target\n").unwrap();
        assert!(!gitignore_covers_build_dirs(td.path()));
    }

    #[test]
    fn chump_repo_gitignore_covers_build_dirs() {
        // The repo this crate ships in: ugrep's default --ignore-files reads
        // this file, so it must keep listing both dirs.
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        assert!(gitignore_covers_build_dirs(&root));
    }
}
