//! INFRA-607: RESILIENT: `chump rebase-stuck` — detect DIRTY PRs and attempt auto-rebase.
//!
//! Productizes the manual rebase dance from PRs #1154 (succeeded) and #1182
//! (failed — bad conflict resolution). Safety gate: only auto-resolves if
//! conflict touches <3 files AND <20 lines AND no test-touching files.
//!
//! ## Usage
//!
//! ```
//! chump rebase-stuck                    # list DIRTY PRs
//! chump rebase-stuck --pr <N>           # inspect one PR
//! chump rebase-stuck --pr <N> --apply   # rebase + force-push (with-lease)
//! ```
//!
//! ## Safety thresholds
//!
//! | Signal                      | Threshold | Action if exceeded      |
//! |-----------------------------|-----------|-------------------------|
//! | Conflicting files           | < 3       | exit with diff for human|
//! | Conflicting lines (net ±)   | < 20      | exit with diff for human|
//! | Any test file in conflict   | 0         | refuse, show diff       |
//!
//! ## Exit codes
//!
//! - 0  : success (or dry-run list with 0 dirty PRs)
//! - 1  : conflict too large / test file touched — diff printed for human
//! - 2  : usage / invocation error
//! - 3  : git / gh command failed unexpectedly

use std::process::Command;

// ── Safety thresholds ─────────────────────────────────────────────────────────

const MAX_CONFLICT_FILES: usize = 3;
const MAX_CONFLICT_LINES: usize = 20;

// ── Public types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct DirtyPr {
    pub number: u64,
    pub title: String,
    pub branch: String,
    pub merge_state_status: String,
}

#[derive(Debug, Clone)]
pub struct RebaseOutcome {
    pub pr: DirtyPr,
    pub status: RebaseStatus,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RebaseStatus {
    /// Rebase succeeded (or --apply pushed successfully).
    Clean,
    /// Conflict within safety thresholds — resolved trivially or exited with diff.
    SmallConflict,
    /// Conflict too large / test files touched — refused.
    TooLarge,
    /// git / gh failed with an unexpected error.
    Error,
    /// INFRA-8221: the PR is held by the arm policy (no-auto-merge label /
    /// `Auto-merge: hold`); its branch was not touched.
    Held,
}

// ── gh query helpers ──────────────────────────────────────────────────────────

/// List open PRs whose mergeStateStatus == "DIRTY".
pub fn fetch_dirty_prs() -> Vec<DirtyPr> {
    let out = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--json",
            "number,title,headRefName,mergeStateStatus",
            "--limit",
            "50",
        ])
        .output();
    let out = match out {
        Ok(o) => o,
        Err(e) => {
            eprintln!("rebase-stuck: gh pr list failed: {e}");
            return vec![];
        }
    };
    if !out.status.success() {
        eprintln!(
            "rebase-stuck: gh pr list error: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        return vec![];
    }
    parse_dirty_prs(&String::from_utf8_lossy(&out.stdout))
}

/// Minimal JSON parser for the gh pr list output (no serde dep required).
pub fn parse_dirty_prs(json: &str) -> Vec<DirtyPr> {
    let mut result = Vec::new();
    // Each element looks like:
    // {"headRefName":"...","mergeStateStatus":"DIRTY","number":123,"title":"..."}
    // We use a simple line-by-line scan to avoid pulling in serde.
    for obj in split_json_objects(json) {
        let number = extract_u64(&obj, "number");
        let title = extract_str(&obj, "title");
        let branch = extract_str(&obj, "headRefName");
        let status = extract_str(&obj, "mergeStateStatus");
        if let Some(number) = number {
            if status == "DIRTY" {
                result.push(DirtyPr {
                    number,
                    title,
                    branch,
                    merge_state_status: status,
                });
            }
        }
    }
    result
}

// ── Rebase logic ──────────────────────────────────────────────────────────────

/// Attempt to rebase `branch` onto `main` in a temp clone of the repo.
/// Returns the outcome. If `apply` is true and the rebase is within the safety
/// threshold, force-pushes the rebased branch with `--force-with-lease`.
pub fn attempt_rebase(pr: &DirtyPr, apply: bool) -> RebaseOutcome {
    // INFRA-8221: a held PR is never rebased + force-pushed by automation.
    if apply {
        if let Err(held) =
            chump_ship::arm_policy::require_touch_allowed(pr.number, "", "chump rebase-stuck")
        {
            return RebaseOutcome {
                pr: pr.clone(),
                status: RebaseStatus::Held,
                message: held.to_string(),
            };
        }
    }
    let tmp = match tempdir() {
        Some(d) => d,
        None => {
            return RebaseOutcome {
                pr: pr.clone(),
                status: RebaseStatus::Error,
                message: "could not create temp dir".to_string(),
            }
        }
    };

    // Get remote URL from current repo.
    let remote_url = match get_remote_url() {
        Some(u) => u,
        None => {
            return RebaseOutcome {
                pr: pr.clone(),
                status: RebaseStatus::Error,
                message: "could not determine git remote URL".to_string(),
            }
        }
    };

    // Clone (shallow) into tmp dir.
    let clone_ok = Command::new("git")
        .args([
            "clone",
            "--depth=50",
            "--no-single-branch",
            &remote_url,
            &tmp,
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !clone_ok {
        return RebaseOutcome {
            pr: pr.clone(),
            status: RebaseStatus::Error,
            message: format!("git clone failed for {}", remote_url),
        };
    }

    // Checkout the PR branch.
    let checkout_ok = Command::new("git")
        .args(["checkout", &pr.branch])
        .current_dir(&tmp)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !checkout_ok {
        return RebaseOutcome {
            pr: pr.clone(),
            status: RebaseStatus::Error,
            message: format!("git checkout {} failed", pr.branch),
        };
    }

    // Fetch main.
    let _ = Command::new("git")
        .args(["fetch", "origin", "main"])
        .current_dir(&tmp)
        .status();

    // Attempt rebase.
    let rebase_status = Command::new("git")
        .args(["rebase", "origin/main"])
        .current_dir(&tmp)
        .status();

    match rebase_status {
        Ok(s) if s.success() => {
            // Clean rebase — optionally push.
            if apply {
                let push_ok = Command::new("git")
                    .args(["push", "origin", &pr.branch, "--force-with-lease"])
                    .current_dir(&tmp)
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false);
                if push_ok {
                    RebaseOutcome {
                        pr: pr.clone(),
                        status: RebaseStatus::Clean,
                        message: format!(
                            "PR #{}: clean rebase + force-pushed {}",
                            pr.number, pr.branch
                        ),
                    }
                } else {
                    RebaseOutcome {
                        pr: pr.clone(),
                        status: RebaseStatus::Error,
                        message: format!("PR #{}: rebase clean but force-push failed", pr.number),
                    }
                }
            } else {
                RebaseOutcome {
                    pr: pr.clone(),
                    status: RebaseStatus::Clean,
                    message: format!(
                        "PR #{}: clean rebase (dry-run; pass --apply to push)",
                        pr.number
                    ),
                }
            }
        }
        Ok(_) => {
            // Rebase conflict — inspect size and test-file presence.
            let diff = conflict_diff(&tmp);
            let _ = Command::new("git")
                .args(["rebase", "--abort"])
                .current_dir(&tmp)
                .status();

            let conflict_files = count_conflict_files(&diff);
            let conflict_lines = count_conflict_lines(&diff);
            let has_test_files = diff_touches_tests(&diff);

            if has_test_files {
                return RebaseOutcome {
                    pr: pr.clone(),
                    status: RebaseStatus::TooLarge,
                    message: format!(
                        "PR #{}: REFUSED — conflict touches test files\n{}",
                        pr.number, diff
                    ),
                };
            }
            if conflict_files >= MAX_CONFLICT_FILES || conflict_lines >= MAX_CONFLICT_LINES {
                return RebaseOutcome {
                    pr: pr.clone(),
                    status: RebaseStatus::TooLarge,
                    message: format!(
                        "PR #{}: REFUSED — conflict too large ({} files, {} lines)\n{}",
                        pr.number, conflict_files, conflict_lines, diff
                    ),
                };
            }
            RebaseOutcome {
                pr: pr.clone(),
                status: RebaseStatus::SmallConflict,
                message: format!(
                    "PR #{}: small conflict ({} files, {} lines) — manual resolution needed\n{}",
                    pr.number, conflict_files, conflict_lines, diff
                ),
            }
        }
        Err(e) => RebaseOutcome {
            pr: pr.clone(),
            status: RebaseStatus::Error,
            message: format!("PR #{}: git rebase failed to spawn: {e}", pr.number),
        },
    }
}

// ── Conflict analysis helpers ─────────────────────────────────────────────────

fn conflict_diff(repo_dir: &str) -> String {
    let out = Command::new("git")
        .args(["diff", "--diff-filter=U"])
        .current_dir(repo_dir)
        .output()
        .unwrap_or_else(|_| std::process::Output {
            status: std::process::ExitStatus::default(),
            stdout: vec![],
            stderr: vec![],
        });
    String::from_utf8_lossy(&out.stdout).to_string()
}

/// Count distinct files that have conflict markers.
fn count_conflict_files(diff: &str) -> usize {
    diff.lines()
        .filter(|l| l.starts_with("--- a/") || l.starts_with("+++ b/"))
        .filter_map(|l| l.split_once('/').map(|x| x.1))
        .collect::<std::collections::BTreeSet<_>>()
        .len()
}

/// Count net conflicting lines (lines inside <<<<<<< / >>>>>>> markers).
fn count_conflict_lines(diff: &str) -> usize {
    let mut count = 0usize;
    let mut in_conflict = false;
    for line in diff.lines() {
        if line.starts_with("+<<<<<<<") || line.starts_with("+>>>>>>>") {
            in_conflict = !in_conflict;
        } else if in_conflict && (line.starts_with('+') || line.starts_with('-')) {
            count += 1;
        }
    }
    // Fallback: if no markers found, count total changed lines as proxy.
    if count == 0 {
        count = diff
            .lines()
            .filter(|l| l.starts_with('+') || l.starts_with('-'))
            .filter(|l| !l.starts_with("+++") && !l.starts_with("---"))
            .count();
    }
    count
}

/// True if any conflicting file looks like a test file.
fn diff_touches_tests(diff: &str) -> bool {
    diff.lines()
        .filter(|l| l.starts_with("--- a/") || l.starts_with("+++ b/"))
        .any(|l| {
            let path = l.get(6..).unwrap_or("");
            path.contains("/tests/")
                || path.contains("_test.")
                || path.contains("test_")
                || path.ends_with(".test.rs")
                || path.ends_with("_spec.rs")
                || path.contains("scripts/ci/test-")
        })
}

// ── Git helpers ───────────────────────────────────────────────────────────────

fn get_remote_url() -> Option<String> {
    let out = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()?;
    if out.status.success() {
        Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        None
    }
}

fn tempdir() -> Option<String> {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let path = format!("/tmp/chump-rebase-stuck-{ts}");
    std::fs::create_dir_all(&path).ok()?;
    Some(path)
}

// ── Minimal JSON helpers ──────────────────────────────────────────────────────

/// Split a JSON array string into individual object strings (not a full parser).
fn split_json_objects(json: &str) -> Vec<String> {
    let mut objects = Vec::new();
    let mut depth = 0i32;
    let mut start: Option<usize> = None;
    for (i, c) in json.char_indices() {
        match c {
            '{' => {
                if depth == 0 {
                    start = Some(i);
                }
                depth += 1;
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    if let Some(s) = start.take() {
                        objects.push(json[s..=i].to_string());
                    }
                }
            }
            _ => {}
        }
    }
    objects
}

fn extract_str(obj: &str, key: &str) -> String {
    let needle = format!("\"{}\":", key);
    let pos = match obj.find(&needle) {
        Some(p) => p + needle.len(),
        None => return String::new(),
    };
    let rest = obj[pos..].trim_start();
    if let Some(inner) = rest.strip_prefix('"') {
        let end = inner.find('"').unwrap_or(inner.len());
        inner[..end].to_string()
    } else {
        // Non-string value — return raw until delimiter.
        let end = rest.find([',', '}']).unwrap_or(rest.len());
        rest[..end].trim().to_string()
    }
}

fn extract_u64(obj: &str, key: &str) -> Option<u64> {
    extract_str(obj, key).parse().ok()
}

// ── Public entry point ────────────────────────────────────────────────────────

/// `chump rebase-stuck [--pr <N>] [--apply] [--json]`
pub fn run(args: &[String]) -> i32 {
    let pr_num: Option<u64> = args
        .iter()
        .position(|a| a == "--pr")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok());
    let apply = args.iter().any(|a| a == "--apply");
    let want_json = args.iter().any(|a| a == "--json");

    let dirty_prs = if let Some(n) = pr_num {
        // Fetch single PR info.
        let all = fetch_dirty_prs();
        let filtered: Vec<_> = all.into_iter().filter(|p| p.number == n).collect();
        if filtered.is_empty() {
            // PR exists but might not be DIRTY — still attempt if --apply given.
            let info = fetch_single_pr(n);
            match info {
                Some(pr) => vec![pr],
                None => {
                    eprintln!("rebase-stuck: could not fetch PR #{n}");
                    return 2;
                }
            }
        } else {
            filtered
        }
    } else {
        fetch_dirty_prs()
    };

    if dirty_prs.is_empty() {
        if want_json {
            println!("[]");
        } else {
            println!("rebase-stuck: no DIRTY PRs found");
        }
        return 0;
    }

    if pr_num.is_none() && !apply {
        // List mode — just print dirty PRs.
        if want_json {
            let items: Vec<String> = dirty_prs
                .iter()
                .map(|p| {
                    format!(
                        r#"{{"number":{},"title":"{}","branch":"{}","mergeStateStatus":"{}"}}"#,
                        p.number,
                        p.title.replace('"', "\\\""),
                        p.branch,
                        p.merge_state_status
                    )
                })
                .collect();
            println!("[{}]", items.join(","));
        } else {
            println!("DIRTY PRs ({}):", dirty_prs.len());
            for p in &dirty_prs {
                println!("  #{} — {} ({})", p.number, p.title, p.branch);
            }
            println!("\nRun with --pr <N> --apply to attempt auto-rebase.");
        }
        return 0;
    }

    // Rebase mode.
    let mut worst_exit = 0i32;
    for pr in &dirty_prs {
        let outcome = attempt_rebase(pr, apply);
        let exit_code = match outcome.status {
            RebaseStatus::Clean => 0,
            RebaseStatus::SmallConflict => 1,
            RebaseStatus::TooLarge => 1,
            RebaseStatus::Held => 1,
            RebaseStatus::Error => 3,
        };
        if exit_code > worst_exit {
            worst_exit = exit_code;
        }
        if want_json {
            println!(
                r#"{{"pr":{},"status":"{:?}","message":"{}"}}"#,
                pr.number,
                outcome.status,
                outcome.message.replace('"', "\\\"").replace('\n', "\\n")
            );
        } else {
            println!("{}", outcome.message);
        }
    }
    worst_exit
}

/// Fetch a single PR (any mergeStateStatus) for --pr N when not DIRTY.
fn fetch_single_pr(number: u64) -> Option<DirtyPr> {
    let out = Command::new("gh")
        .args([
            "pr",
            "view",
            &number.to_string(),
            "--json",
            "number,title,headRefName,mergeStateStatus",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let json = String::from_utf8_lossy(&out.stdout).to_string();
    let number_v = extract_u64(&json, "number")?;
    Some(DirtyPr {
        number: number_v,
        title: extract_str(&json, "title"),
        branch: extract_str(&json, "headRefName"),
        merge_state_status: extract_str(&json, "mergeStateStatus"),
    })
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// INFRA-8221: --apply on a held PR returns Held before any clone/push.
    #[test]
    fn attempt_rebase_apply_refuses_held_pr() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("no-auto-merge");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        let pr = DirtyPr {
            number: 4242,
            title: "t".into(),
            branch: "chump/held".into(),
            merge_state_status: "DIRTY".into(),
        };
        let out = attempt_rebase(&pr, true);
        assert!(matches!(out.status, RebaseStatus::Held), "{}", out.message);
        assert_eq!(fake.calls.get(), 1);
        assert!(std::fs::read_to_string(&amb)
            .unwrap()
            .contains("chump rebase-stuck"));
    }

    #[test]
    fn parse_dirty_prs_filters_non_dirty() {
        let json = r#"[
            {"number":10,"title":"clean pr","headRefName":"fix/clean","mergeStateStatus":"CLEAN"},
            {"number":11,"title":"dirty pr","headRefName":"fix/dirty","mergeStateStatus":"DIRTY"}
        ]"#;
        let prs = parse_dirty_prs(json);
        assert_eq!(prs.len(), 1);
        assert_eq!(prs[0].number, 11);
        assert_eq!(prs[0].branch, "fix/dirty");
    }

    #[test]
    fn parse_dirty_prs_empty_array() {
        let prs = parse_dirty_prs("[]");
        assert!(prs.is_empty());
    }

    #[test]
    fn count_conflict_lines_counts_changed_lines() {
        let diff = "+line added\n-line removed\n context\n";
        assert_eq!(count_conflict_lines(diff), 2);
    }

    #[test]
    fn diff_touches_tests_detects_test_paths() {
        let diff = "--- a/src/tests/foo.rs\n+++ b/src/tests/foo.rs\n";
        assert!(diff_touches_tests(diff));
    }

    #[test]
    fn diff_touches_tests_clean_path() {
        let diff = "--- a/src/main.rs\n+++ b/src/main.rs\n";
        assert!(!diff_touches_tests(diff));
    }

    #[test]
    fn count_conflict_files_deduplicates() {
        let diff = "--- a/src/foo.rs\n+++ b/src/foo.rs\n--- a/src/foo.rs\n+++ b/src/foo.rs\n";
        assert_eq!(count_conflict_files(diff), 1);
    }

    #[test]
    fn split_json_objects_basic() {
        let json = r#"[{"a":"1"},{"b":"2"}]"#;
        let objs = split_json_objects(json);
        assert_eq!(objs.len(), 2);
    }

    #[test]
    fn extract_str_finds_value() {
        let obj = r#"{"number":42,"title":"hello world","headRefName":"fix/foo"}"#;
        assert_eq!(extract_str(obj, "title"), "hello world");
        assert_eq!(extract_str(obj, "headRefName"), "fix/foo");
    }
}
