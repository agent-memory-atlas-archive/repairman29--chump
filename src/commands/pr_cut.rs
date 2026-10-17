//! INFRA-8221 (slice 2) — `chump pr cut <N> --reason "<text>"`.
//!
//! The ONE sanctioned way to close a fleet PR on purpose (RESILIENT-1606 /
//! RESILIENT-1607). The terminal `pr-cut` label tells the post-push integrity
//! watch not to reopen it and the trunk-recovery reviver not to revive it.
//!
//! When `scripts/coord/pr-cut.sh` is present in the checkout (it lands with
//! #5527) this arm runs it with the same arguments, so there is one
//! implementation. When the script is absent, the same steps run here, in
//! the same order:
//!
//! 1. ensure the `pr-cut` label exists;
//! 2. add it (BEFORE the close, so a poller in the close window sees it);
//! 3. close with a comment carrying the reason (an already-closed PR gets
//!    the label and a comment);
//! 4. emit `kind=pr_cut`;
//! 5. append a note to the PR's gap, or print the command when the gap
//!    store is unreachable.
//!
//! Exit: 0 cut done (or dry-run), 1 gh failure, 2 usage error / PR merged.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const CUT_LABEL: &str = "pr-cut";
const DEFAULT_REPO: &str = "repairman29/chump";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CutArgs {
    pub pr: u64,
    pub reason: String,
    pub repo: String,
    pub dry_run: bool,
}

/// Parse `<N> --reason <text> [--repo owner/repo] [--dry-run]`.
pub fn parse_args(args: &[String]) -> Result<CutArgs, String> {
    let mut pr: Option<u64> = None;
    let mut reason = String::new();
    let mut repo = DEFAULT_REPO.to_string();
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--reason" | "--repo" => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| format!("{a} needs a value"))?;
                if a == "--reason" {
                    reason = v.clone();
                } else {
                    repo = v.clone();
                }
                i += 2;
                continue;
            }
            "--dry-run" => dry_run = true,
            _ if a.starts_with("--reason=") => reason = a["--reason=".len()..].to_string(),
            _ if a.starts_with('-') => return Err(format!("unknown flag: {a}")),
            _ => {
                if pr.is_some() {
                    return Err(format!("unexpected extra argument: {a}"));
                }
                pr = Some(
                    a.parse()
                        .map_err(|_| format!("PR number required, got {a:?}"))?,
                );
            }
        }
        i += 1;
    }
    let pr = pr.ok_or("usage: chump pr cut <PR-NUMBER> --reason \"text\"")?;
    if reason.trim().is_empty() {
        return Err("--reason is required: say why this PR is being cut".into());
    }
    Ok(CutArgs {
        pr,
        reason,
        repo,
        dry_run,
    })
}

/// Gap id from the title (`INFRA-8221: ...`), else the branch
/// (`chump/resilient-1606-fleet-1-...` → `RESILIENT-1606`).
pub fn gap_id_for(title: &str, branch: &str) -> Option<String> {
    fn scan(s: &str, upper_only: bool) -> Option<String> {
        let parts: Vec<&str> = s
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
            .collect();
        for tok in parts {
            let segs: Vec<&str> = tok.split('-').collect();
            // Find the first all-digit segment preceded by >=1 alphabetic segments.
            for (idx, seg) in segs.iter().enumerate() {
                if idx == 0 || seg.is_empty() || !seg.chars().all(|c| c.is_ascii_digit()) {
                    continue;
                }
                let prefix = &segs[..idx];
                let ok = prefix.iter().all(|p| {
                    !p.is_empty()
                        && p.chars().all(|c| c.is_ascii_alphabetic())
                        && (!upper_only || p.chars().all(|c| c.is_ascii_uppercase()))
                });
                if ok {
                    return Some(format!("{}-{}", prefix.join("-").to_ascii_uppercase(), seg));
                }
                break;
            }
        }
        None
    }
    scan(title, true).or_else(|| branch.strip_prefix("chump/").and_then(|b| scan(b, false)))
}

/// Side effects, injectable for tests.
pub trait CutEnv {
    /// Run `gh <args>`; (success, stdout).
    fn gh(&self, args: &[&str]) -> (bool, String);
    /// Run `chump <args>`; (success, stdout).
    fn chump(&self, args: &[&str]) -> (bool, String);
    fn ambient_path(&self) -> PathBuf;
}

/// Real subprocesses.
pub struct RealEnv {
    pub repo_root: PathBuf,
}

fn run(cmd: &mut Command) -> (bool, String) {
    match cmd.output() {
        Ok(o) => (
            o.status.success(),
            String::from_utf8_lossy(&o.stdout).to_string(),
        ),
        Err(_) => (false, String::new()),
    }
}

impl CutEnv for RealEnv {
    fn gh(&self, args: &[&str]) -> (bool, String) {
        run(Command::new("gh").args(args))
    }
    fn chump(&self, args: &[&str]) -> (bool, String) {
        let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("chump"));
        let bin = std::env::var("CHUMP_BIN").map(PathBuf::from).unwrap_or(exe);
        run(Command::new(bin).args(args))
    }
    fn ambient_path(&self) -> PathBuf {
        for var in ["CHUMP_AMBIENT_PATH", "CHUMP_AMBIENT_LOG"] {
            if let Ok(p) = std::env::var(var) {
                if !p.is_empty() {
                    return PathBuf::from(p);
                }
            }
        }
        self.repo_root.join(".chump-locks").join("ambient.jsonl")
    }
}

fn close_comment(reason: &str) -> String {
    format!(
        "pr-cut: {reason}\n\nClosed deliberately (`chump pr cut`, RESILIENT-1607). The `{CUT_LABEL}` label is terminal: the post-push integrity watch will not reopen this PR and the trunk-recovery reviver will not revive it. To bring the work back, open a new PR."
    )
}

fn append(path: &Path, line: &str) {
    if let Some(d) = path.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// The Rust implementation of the cut (used when pr-cut.sh is absent).
pub fn cut(a: &CutArgs, env: &dyn CutEnv) -> i32 {
    let pr = a.pr.to_string();
    let (ok, view) = env.gh(&[
        "pr",
        "view",
        &pr,
        "--repo",
        &a.repo,
        "--json",
        "state,title,headRefName,mergedAt",
    ]);
    let v: serde_json::Value = match (ok, serde_json::from_str(&view)) {
        (true, Ok(v)) => v,
        _ => {
            eprintln!(
                "pr-cut: could not read PR #{pr} on {} (gh pr view failed)",
                a.repo
            );
            return 1;
        }
    };
    let field = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    let (state, title, branch, merged_at) = (
        field("state"),
        field("title"),
        field("headRefName"),
        field("mergedAt"),
    );
    if !merged_at.is_empty() || state == "MERGED" {
        eprintln!("pr-cut: PR #{pr} is already MERGED; there is nothing to cut.");
        return 2;
    }
    let gap = gap_id_for(&title, &branch);
    if a.dry_run {
        println!(
            "[pr-cut] [dry-run] PR #{pr} ({branch}, state={state}, gap={}) on {}",
            gap.as_deref().unwrap_or("none"),
            a.repo
        );
        println!("[pr-cut] [dry-run] would: ensure label '{CUT_LABEL}'; add it; close with the reason comment; emit kind=pr_cut; note the gap");
        return 0;
    }

    // 1 + 2. Label first.
    let (_, labels) = env.gh(&["label", "list", "--repo", &a.repo, "--limit", "300"]);
    if !labels
        .lines()
        .any(|l| l.split_whitespace().next() == Some(CUT_LABEL))
    {
        let (made, _) = env.gh(&[
            "label",
            "create",
            CUT_LABEL,
            "--repo",
            &a.repo,
            "--color",
            "6E7781",
            "--description",
            "Deliberately closed by a human or architect; organs must not reopen or revive",
        ]);
        if !made {
            println!("[pr-cut] WARN: could not create label '{CUT_LABEL}' (it may already exist)");
        }
    }
    if !env
        .gh(&[
            "pr",
            "edit",
            &pr,
            "--repo",
            &a.repo,
            "--add-label",
            CUT_LABEL,
        ])
        .0
    {
        eprintln!("pr-cut: could not add label '{CUT_LABEL}' to PR #{pr}; NOT closing (the label must land before the close, or an organ will reopen it).");
        return 1;
    }
    println!("[pr-cut] labeled PR #{pr} '{CUT_LABEL}'");

    // 3. Close with the reason.
    let comment = close_comment(&a.reason);
    if state == "OPEN" {
        if !env
            .gh(&["pr", "close", &pr, "--repo", &a.repo, "--comment", &comment])
            .0
        {
            eprintln!("pr-cut: gh pr close #{pr} failed (label '{CUT_LABEL}' is already on it).");
            return 1;
        }
        println!("[pr-cut] closed PR #{pr} with the reason comment");
    } else if env
        .gh(&["pr", "comment", &pr, "--repo", &a.repo, "--body", &comment])
        .0
    {
        println!("[pr-cut] PR #{pr} was already {state}; labeled and commented");
    } else {
        println!("[pr-cut] WARN: PR #{pr} was already {state} and the reason comment could not be posted");
    }

    // 4. Ambient event.
    // scanner-anchor: "kind":"pr_cut" (registered in docs/observability/EVENT_REGISTRY.yaml, RESILIENT-1607 / INFRA-8221)
    let ev = serde_json::json!({
        "ts": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        "kind": "pr_cut",
        "pr": a.pr,
        "branch": branch,
        "gap": gap.clone().unwrap_or_default(),
        "reason": a.reason.trim(),
    });
    append(&env.ambient_path(), &ev.to_string());

    // 5. Gap note (never fails the cut).
    match gap {
        Some(gid) => {
            let note = format!(
                "[pr-cut {}] PR #{pr} closed deliberately: {}",
                chrono::Utc::now().format("%Y-%m-%d"),
                a.reason
            );
            let mut noted = false;
            let (ok, js) = env.chump(&["gap", "show", &gid, "--json"]);
            if ok {
                if let Ok(g) = serde_json::from_str::<serde_json::Value>(&js) {
                    let old = g.get("notes").and_then(|n| n.as_str()).unwrap_or("");
                    let new = if old.is_empty() {
                        note.clone()
                    } else {
                        format!("{old}\n{note}")
                    };
                    noted = env.chump(&["gap", "set", &gid, "--notes", &new]).0;
                }
            }
            if noted {
                println!("[pr-cut] noted gap {gid}");
            } else {
                println!("[pr-cut] gap store not reachable here; record the note yourself (this appends nothing automatically):");
                println!("  chump gap set {gid} --notes \"<existing notes>\\n{note}\"");
            }
        }
        None => println!("[pr-cut] no gap id found in the title or branch; skipping the gap note"),
    }
    println!("[pr-cut] done: PR #{pr} is cut ('{CUT_LABEL}' = terminal; rot-reaped = reaper victim, revivable)");
    0
}

/// `chump pr cut` entry: delegate to scripts/coord/pr-cut.sh when present,
/// else run [`cut`]. `args` are the words after `chump pr cut`.
pub fn run_cli(args: &[String], repo_root: &Path) -> i32 {
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!(
            "usage: chump pr cut <PR-NUMBER> --reason \"text\" [--repo owner/repo] [--dry-run]"
        );
        return 0;
    }
    let script = repo_root.join("scripts/coord/pr-cut.sh");
    if script.is_file() {
        return Command::new("bash")
            .arg(&script)
            .args(args)
            .status()
            .map(|s| s.code().unwrap_or(1))
            .unwrap_or(1);
    }
    match parse_args(args) {
        Ok(a) => cut(
            &a,
            &RealEnv {
                repo_root: repo_root.to_path_buf(),
            },
        ),
        Err(e) => {
            eprintln!("pr-cut: {e}");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct FakeEnv {
        calls: RefCell<Vec<String>>,
        view: String,
        ambient: PathBuf,
        gap_json: Option<String>,
    }

    impl CutEnv for FakeEnv {
        fn gh(&self, args: &[&str]) -> (bool, String) {
            self.calls
                .borrow_mut()
                .push(format!("gh {}", args.join(" ")));
            match (args[0], args[1]) {
                ("pr", "view") => (true, self.view.clone()),
                ("label", "list") => (true, "bug\tSomething\nhold\tx\n".into()),
                _ => (true, String::new()),
            }
        }
        fn chump(&self, args: &[&str]) -> (bool, String) {
            self.calls
                .borrow_mut()
                .push(format!("chump {}", args.join(" ")));
            match (args[1], &self.gap_json) {
                ("show", Some(j)) => (true, j.clone()),
                ("set", Some(_)) => (true, String::new()),
                _ => (false, String::new()),
            }
        }
        fn ambient_path(&self) -> PathBuf {
            self.ambient.clone()
        }
    }

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn parse_args_requires_pr_and_reason() {
        let a = parse_args(&s(&[
            "5478",
            "--reason",
            "duplicate of #5480",
            "--repo",
            "o/r",
        ]))
        .unwrap();
        assert_eq!(
            (a.pr, a.reason.as_str(), a.repo.as_str(), a.dry_run),
            (5478, "duplicate of #5480", "o/r", false)
        );
        assert_eq!(
            parse_args(&s(&["--reason=x", "1", "--dry-run"]))
                .unwrap()
                .repo,
            DEFAULT_REPO
        );
        assert!(parse_args(&s(&["5478"])).is_err());
        assert!(parse_args(&s(&["--reason", "x"])).is_err());
        assert!(parse_args(&s(&["abc", "--reason", "x"])).is_err());
        assert!(parse_args(&s(&["1", "2", "--reason", "x"])).is_err());
        assert!(parse_args(&s(&["1", "--bogus"])).is_err());
    }

    #[test]
    fn gap_id_from_title_then_branch() {
        assert_eq!(
            gap_id_for("INFRA-8221: arm policy", "x").as_deref(),
            Some("INFRA-8221")
        );
        assert_eq!(
            gap_id_for("RESILIENT-1606/1607: cut", "x").as_deref(),
            Some("RESILIENT-1606")
        );
        assert_eq!(
            gap_id_for("fix things", "chump/resilient-1606-fleet-1-20261017").as_deref(),
            Some("RESILIENT-1606")
        );
        assert_eq!(gap_id_for("fix things", "feature/x"), None);
    }

    #[test]
    fn cut_labels_before_close_emits_pr_cut_and_notes_gap() {
        let tmp = tempfile::tempdir().unwrap();
        let env = FakeEnv {
            calls: RefCell::new(vec![]),
            view: r#"{"state":"OPEN","title":"INFRA-9999: slice","headRefName":"chump/infra-9999-x","mergedAt":null}"#.into(),
            ambient: tmp.path().join("ambient.jsonl"),
            gap_json: Some(r#"{"notes":"old note"}"#.into()),
        };
        let a = parse_args(&s(&[
            "77",
            "--reason",
            "superseded by #78",
            "--repo",
            "o/r",
        ]))
        .unwrap();
        assert_eq!(cut(&a, &env), 0);
        let calls = env.calls.borrow();
        let pos = |p: &str| {
            calls
                .iter()
                .position(|c| c.starts_with(p))
                .unwrap_or_else(|| panic!("no {p}: {calls:?}"))
        };
        assert!(pos("gh label create pr-cut") < pos("gh pr edit 77 --repo o/r --add-label pr-cut"));
        assert!(
            pos("gh pr edit 77")
                < pos("gh pr close 77 --repo o/r --comment pr-cut: superseded by #78")
        );
        assert!(calls
            .iter()
            .any(|c| c.starts_with("chump gap set INFRA-9999 --notes old note\n[pr-cut ")));
        let ev: serde_json::Value =
            serde_json::from_str(std::fs::read_to_string(&env.ambient).unwrap().trim()).unwrap();
        assert_eq!(ev["kind"], "pr_cut");
        assert_eq!(ev["pr"], 77);
        assert_eq!(ev["gap"], "INFRA-9999");
        assert_eq!(ev["branch"], "chump/infra-9999-x");
        assert_eq!(ev["reason"], "superseded by #78");
    }

    #[test]
    fn cut_refuses_merged_pr_and_comments_on_closed_one() {
        let tmp = tempfile::tempdir().unwrap();
        let merged = FakeEnv {
            calls: RefCell::new(vec![]),
            view: r#"{"state":"MERGED","title":"x","headRefName":"b","mergedAt":"2026-10-17T00:00:00Z"}"#.into(),
            ambient: tmp.path().join("a1.jsonl"),
            gap_json: None,
        };
        let a = parse_args(&s(&["5", "--reason", "r"])).unwrap();
        assert_eq!(cut(&a, &merged), 2);
        assert!(!merged
            .calls
            .borrow()
            .iter()
            .any(|c| c.contains("--add-label")));

        let closed = FakeEnv {
            calls: RefCell::new(vec![]),
            view: r#"{"state":"CLOSED","title":"no gap here","headRefName":"feature/b","mergedAt":null}"#.into(),
            ambient: tmp.path().join("a2.jsonl"),
            gap_json: None,
        };
        assert_eq!(cut(&a, &closed), 0);
        let calls = closed.calls.borrow();
        assert!(calls.iter().any(|c| c.starts_with("gh pr comment 5")));
        assert!(!calls.iter().any(|c| c.starts_with("gh pr close")));
        assert!(
            !calls.iter().any(|c| c.starts_with("chump ")),
            "no gap id → no gap calls"
        );
    }

    #[test]
    fn dry_run_changes_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let env = FakeEnv {
            calls: RefCell::new(vec![]),
            view: r#"{"state":"OPEN","title":"INFRA-1: x","headRefName":"b","mergedAt":null}"#
                .into(),
            ambient: tmp.path().join("a.jsonl"),
            gap_json: None,
        };
        let a = parse_args(&s(&["9", "--reason", "r", "--dry-run"])).unwrap();
        assert_eq!(cut(&a, &env), 0);
        assert_eq!(env.calls.borrow().len(), 1, "only the read");
        assert!(!env.ambient.exists());
    }
}
