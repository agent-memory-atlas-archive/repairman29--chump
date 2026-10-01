//! CREDIBLE-155 — `chump verify`: the unified policy engine (ground-up step 4,
//! docs/design/GROUND_UP_2026-07-19.md §3).
//!
//! One Rust engine replaces the grep-based pre-commit/CI gate archipelago:
//! typed rules over PARSED diff semantics, identical local + CI behavior from
//! one implementation, machine-readable remediation per rule, and ONE bypass
//! surface — the `Verify-Bypass: <rule-id>: <reason>` commit trailer — which
//! always emits an audited ambient event (kind=verify_bypassed).
//!
//! Stages:
//!   --stage pre-commit   PREVIEW. Staged diff only; git writes the commit
//!                        message AFTER pre-commit succeeds (INFRA-1969 proved
//!                        trailer checks at pre-commit are structurally broken
//!                        — the trailer is never visible there), so this stage
//!                        prints would-fail verdicts and exits 0 unless
//!                        --strict. Binding enforcement happens at commit-msg.
//!   --stage commit-msg   BINDING. Staged diff + --msg-file <path> (the real
//!                        in-progress message). Any fail exits 1; a
//!                        `Verify-Bypass: <rule-id>: <reason>` trailer flips
//!                        that rule to bypassed and appends one audited line
//!                        to .chump-locks/ambient.jsonl.
//!   --stage ci           BINDING. Diff vs --base (default origin/main);
//!                        trailers are read from all commit bodies in the
//!                        merge-base..HEAD range. Same rules, same exits.
//!
//! Exit codes: 0 = pass/preview, 1 = rule failure at a binding stage (or
//! --strict preview), 2 = engine error (git plumbing, bad flags).
//!
//! Migration table for the full gate archipelago:
//! docs/process/VERIFY_MIGRATION.md

pub mod rules;

use rules::Evaluation;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

// ── Types ────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage {
    PreCommit,
    CommitMsg,
    Ci,
}

impl Stage {
    pub fn as_str(self) -> &'static str {
        match self {
            Stage::PreCommit => "pre-commit",
            Stage::CommitMsg => "commit-msg",
            Stage::Ci => "ci",
        }
    }

    /// Binding stages enforce (exit 1 on fail). Pre-commit is a preview:
    /// the commit message (and therefore the Verify-Bypass trailer) does not
    /// exist yet at that hook stage (INFRA-1969).
    pub fn is_binding(self) -> bool {
        !matches!(self, Stage::PreCommit)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
}

/// One file in the diff under verification, with its added lines parsed out
/// (rules match on these, never on raw patch text).
#[derive(Clone, Debug)]
pub struct DiffFile {
    pub path: String,
    pub kind: ChangeKind,
    pub added_lines: Vec<String>,
}

/// Everything a rule may look at. Built once per invocation.
pub struct VerifyContext {
    pub stage: Stage,
    pub repo_root: PathBuf,
    pub files: Vec<DiffFile>,
    /// The commit message: `--msg-file` contents at commit-msg stage, the
    /// concatenated commit bodies of the base..HEAD range at ci stage, and
    /// `None` at pre-commit (git has not written it yet).
    pub commit_message: Option<String>,
    /// Gap under work, resolved from commit message > branch name > CHUMP_GAP_ID.
    pub gap_id: Option<String>,
    /// rule_id -> reason, parsed from `Verify-Bypass: <rule-id>: <reason>` trailers.
    pub bypasses: BTreeMap<String, String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Verdict {
    Pass,
    Fail,
    Bypassed,
    NotApplicable,
}

impl Verdict {
    fn as_str(self) -> &'static str {
        match self {
            Verdict::Pass => "pass",
            Verdict::Fail => "fail",
            Verdict::Bypassed => "bypassed",
            Verdict::NotApplicable => "not-applicable",
        }
    }
}

pub struct RuleReport {
    pub rule_id: &'static str,
    pub verdict: Verdict,
    pub detail: String,
    pub remediation: String,
    pub incident_receipt: &'static str,
    pub bypass_reason: Option<String>,
}

// ── Entry point ──────────────────────────────────────────────────────────────

const USAGE: &str = "Usage: chump verify --stage <pre-commit|commit-msg|ci> [options]
   or: chump verify --live <gap-id|pr-number> [--revive] [--json]

Unified policy engine (CREDIBLE-155) — typed rules over parsed diff
semantics, one implementation for local hooks and CI.

`--live` is a separate mode (INFRA-3653, PEER-VERI-06): it probes a gap's
PROOF ACs against their resolved target node (not this host) and prints a
BUILT/WIRED/DETECTABLE/REVIVABLE verdict. See `chump verify --live --help`.

Options:
  --stage <s>       pre-commit (preview of staged diff), commit-msg
                    (binding; requires --msg-file), ci (binding; diff vs --base)
  --msg-file <p>    path to the in-progress commit message (commit-msg stage)
  --base <ref>      base ref for ci stage (default: origin/main)
  --json            machine-readable report on stdout
  --strict          make the pre-commit preview exit non-zero on would-fail
  --rules           list registered rules with incident receipts and exit
  -h, --help        this help

Bypass: add a commit trailer  Verify-Bypass: <rule-id>: <reason>
Every bypass appends one audited kind=verify_bypassed line to
.chump-locks/ambient.jsonl. No per-rule env vars exist (INFRA-2429).

Exit codes: 0 pass/preview, 1 rule failure (binding or --strict), 2 engine error.";

pub fn run(argv: &[String]) -> i32 {
    // `chump verify --live <gap|pr>` (INFRA-3653, PEER-VERI-06) — a distinct
    // mode from the --stage diff-policy engine above: probes a gap's PROOF
    // ACs against their RESOLVED target node instead of parsing a git diff.
    // Dispatched first so it never falls through to the `--stage is required`
    // error below.
    if argv.first().map(String::as_str) == Some("--live") {
        return crate::pr_ac_coverage::run_live(&argv[1..]);
    }

    let mut stage: Option<Stage> = None;
    let mut msg_file: Option<String> = None;
    let mut base = "origin/main".to_string();
    let mut json = false;
    let mut strict = false;

    let mut it = argv.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "-h" | "--help" => {
                println!("{USAGE}");
                return 0;
            }
            "--rules" => {
                for r in rules::registry() {
                    println!("{}\t{}", r.id(), r.incident_receipt());
                }
                return 0;
            }
            "--stage" => match it.next().map(String::as_str) {
                Some("pre-commit") => stage = Some(Stage::PreCommit),
                Some("commit-msg") => stage = Some(Stage::CommitMsg),
                Some("ci") => stage = Some(Stage::Ci),
                other => {
                    eprintln!("chump verify: bad --stage {:?}\n{USAGE}", other);
                    return 2;
                }
            },
            "--msg-file" => msg_file = it.next().cloned(),
            "--base" => {
                if let Some(b) = it.next() {
                    base = b.clone();
                }
            }
            "--json" => json = true,
            "--strict" => strict = true,
            other => {
                eprintln!("chump verify: unknown flag '{other}'\n{USAGE}");
                return 2;
            }
        }
    }

    let Some(stage) = stage else {
        eprintln!("chump verify: --stage is required\n{USAGE}");
        return 2;
    };

    let ctx = match build_context(stage, msg_file.as_deref(), &base) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("chump verify: engine error: {e}");
            return 2;
        }
    };

    let reports = evaluate_all(&ctx);

    // Audit every bypass at binding stages — one ambient line per bypassed rule.
    if stage.is_binding() {
        for r in &reports {
            if r.verdict == Verdict::Bypassed {
                emit_verify_bypassed(
                    r.rule_id,
                    r.bypass_reason.as_deref().unwrap_or(""),
                    stage,
                    ctx.gap_id.as_deref(),
                );
            }
        }
    }

    let failures = reports
        .iter()
        .filter(|r| r.verdict == Verdict::Fail)
        .count();

    if json {
        print_json(stage, &reports, failures);
    } else {
        print_human(stage, &reports, failures);
    }

    if failures > 0 && (stage.is_binding() || strict) {
        1
    } else {
        0
    }
}

fn evaluate_all(ctx: &VerifyContext) -> Vec<RuleReport> {
    let mut out = Vec::new();
    for rule in rules::registry() {
        let ev = rule.evaluate(ctx);
        let report = match ev {
            Evaluation::Pass(detail) => RuleReport {
                rule_id: rule.id(),
                verdict: Verdict::Pass,
                detail,
                remediation: String::new(),
                incident_receipt: rule.incident_receipt(),
                bypass_reason: None,
            },
            Evaluation::NotApplicable(detail) => RuleReport {
                rule_id: rule.id(),
                verdict: Verdict::NotApplicable,
                detail,
                remediation: String::new(),
                incident_receipt: rule.incident_receipt(),
                bypass_reason: None,
            },
            Evaluation::Fail {
                detail,
                remediation,
            } => {
                if let Some(reason) = ctx.bypasses.get(rule.id()) {
                    RuleReport {
                        rule_id: rule.id(),
                        verdict: Verdict::Bypassed,
                        detail,
                        remediation,
                        incident_receipt: rule.incident_receipt(),
                        bypass_reason: Some(reason.clone()),
                    }
                } else {
                    RuleReport {
                        rule_id: rule.id(),
                        verdict: Verdict::Fail,
                        detail,
                        remediation,
                        incident_receipt: rule.incident_receipt(),
                        bypass_reason: None,
                    }
                }
            }
        };
        out.push(report);
    }
    out
}

// ── Context construction (git plumbing) ──────────────────────────────────────

fn build_context(
    stage: Stage,
    msg_file: Option<&str>,
    base: &str,
) -> Result<VerifyContext, String> {
    let repo_root = git_capture(&["rev-parse", "--show-toplevel"])
        .map_err(|e| format!("not a git repo? {e}"))?
        .trim()
        .to_string();
    let repo_root = PathBuf::from(repo_root);

    let (name_status, patch) = match stage {
        Stage::PreCommit | Stage::CommitMsg => {
            let ns = git_capture(&["diff", "--cached", "--name-status", "-M"])?;
            let p = git_capture(&["diff", "--cached", "--unified=0", "--no-color"])?;
            (ns, p)
        }
        Stage::Ci => {
            let mb = git_capture(&["merge-base", base, "HEAD"])
                .map_err(|e| format!("merge-base {base} HEAD failed: {e}"))?
                .trim()
                .to_string();
            let ns = git_capture(&["diff", "--name-status", "-M", &mb, "HEAD"])?;
            let p = git_capture(&["diff", "--unified=0", "--no-color", &mb, "HEAD"])?;
            (ns, p)
        }
    };

    let files = parse_diff(&name_status, &patch);

    let commit_message = match stage {
        Stage::PreCommit => None,
        Stage::CommitMsg => {
            let path = msg_file
                .ok_or_else(|| "--msg-file is required at --stage commit-msg".to_string())?;
            Some(
                std::fs::read_to_string(path)
                    .map_err(|e| format!("cannot read --msg-file {path}: {e}"))?,
            )
        }
        Stage::Ci => {
            let mb = git_capture(&["merge-base", base, "HEAD"])?
                .trim()
                .to_string();
            let range = format!("{mb}..HEAD");
            Some(git_capture(&["log", "--format=%B", &range])?)
        }
    };

    let bypasses = commit_message
        .as_deref()
        .map(parse_bypass_trailers)
        .unwrap_or_default();

    let gap_id = resolve_gap_id(commit_message.as_deref());

    Ok(VerifyContext {
        stage,
        repo_root,
        files,
        commit_message,
        gap_id,
        bypasses,
    })
}

fn git_capture(args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .args(args)
        .output()
        .map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    if !out.status.success() {
        return Err(format!(
            "git {} exited {}: {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Merge `--name-status` output with the `-U0` patch into typed DiffFiles.
pub fn parse_diff(name_status: &str, patch: &str) -> Vec<DiffFile> {
    // path -> added lines, from the unified-0 patch.
    let mut added: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut current: Option<String> = None;
    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("+++ ") {
            current = rest.strip_prefix("b/").map(str::to_string);
            continue;
        }
        if line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        if let Some(body) = line.strip_prefix('+') {
            if let Some(path) = &current {
                added
                    .entry(path.clone())
                    .or_default()
                    .push(body.to_string());
            }
        }
    }

    let mut files = Vec::new();
    for line in name_status.lines() {
        let mut cols = line.split('\t');
        let Some(status) = cols.next() else { continue };
        let (kind, path) = match status.chars().next() {
            Some('A') => (ChangeKind::Added, cols.next()),
            Some('M') => (ChangeKind::Modified, cols.next()),
            Some('D') => (ChangeKind::Deleted, cols.next()),
            // Rename: "R100\told\tnew" — the new path carries the content.
            Some('R') => (ChangeKind::Renamed, cols.nth(1)),
            _ => (ChangeKind::Modified, cols.next()),
        };
        let Some(path) = path else { continue };
        files.push(DiffFile {
            path: path.to_string(),
            kind,
            added_lines: added.remove(path).unwrap_or_default(),
        });
    }
    files
}

/// Parse `Verify-Bypass: <rule-id>: <reason>` trailers (case-insensitive key).
pub fn parse_bypass_trailers(message: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in message.lines() {
        let lower = line.trim_start().to_ascii_lowercase();
        let Some(rest_start) = lower.strip_prefix("verify-bypass:") else {
            continue;
        };
        // Re-slice the original line to preserve reason casing.
        let rest = &line.trim_start()[line.trim_start().len() - rest_start.len()..];
        if let Some((rule_id, reason)) = rest.split_once(':') {
            let rule_id = rule_id.trim().to_ascii_lowercase();
            let reason = reason.trim().to_string();
            if !rule_id.is_empty() && !reason.is_empty() {
                out.insert(rule_id, reason);
            }
        }
    }
    out
}

/// Gap ID resolution: first `ABC-123`-shaped token in the commit message,
/// else the `chump/<gap-id>-claim` branch convention, else CHUMP_GAP_ID.
fn resolve_gap_id(message: Option<&str>) -> Option<String> {
    if let Some(msg) = message {
        if let Some(id) = first_gap_token(msg) {
            return Some(id);
        }
    }
    if let Ok(branch) = git_capture(&["rev-parse", "--abbrev-ref", "HEAD"]) {
        let branch = branch.trim();
        if let Some(rest) = branch.strip_prefix("chump/") {
            let stem = rest.strip_suffix("-claim").unwrap_or(rest);
            if let Some(id) = first_gap_token(&stem.to_ascii_uppercase()) {
                return Some(id);
            }
        }
    }
    std::env::var("CHUMP_GAP_ID").ok().filter(|s| !s.is_empty())
}

/// First token shaped like `[A-Z][A-Z0-9]+-[0-9]+` in the text.
pub fn first_gap_token(text: &str) -> Option<String> {
    for raw in text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '-')) {
        let Some((dom, num)) = raw.rsplit_once('-') else {
            continue;
        };
        if dom.len() >= 2
            && dom.chars().next().is_some_and(|c| c.is_ascii_uppercase())
            && dom
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            && !num.is_empty()
            && num.chars().all(|c| c.is_ascii_digit())
        {
            return Some(raw.to_string());
        }
    }
    None
}

// ── Output ───────────────────────────────────────────────────────────────────

fn print_human(stage: Stage, reports: &[RuleReport], failures: usize) {
    println!(
        "[verify] stage={} ({}) rules={}",
        stage.as_str(),
        if stage.is_binding() {
            "binding"
        } else {
            "preview"
        },
        reports.len()
    );
    for r in reports {
        match r.verdict {
            Verdict::Pass => println!("  PASS {}", r.rule_id),
            Verdict::NotApplicable => println!("  N/A  {} — {}", r.rule_id, r.detail),
            Verdict::Bypassed => println!(
                "  BYPASSED {} — reason: {}",
                r.rule_id,
                r.bypass_reason.as_deref().unwrap_or("")
            ),
            Verdict::Fail => {
                println!("  FAIL {} — {}", r.rule_id, r.detail);
                println!("       remediation: {}", r.remediation);
                println!("       receipt: {}", r.incident_receipt);
                println!(
                    "       bypass: commit trailer 'Verify-Bypass: {}: <reason>' (audited)",
                    r.rule_id
                );
            }
        }
    }
    if failures > 0 {
        if stage.is_binding() {
            println!("[verify] {failures} rule(s) failed — commit blocked.");
        } else {
            println!(
                "[verify] {failures} rule(s) would fail — enforcement fires at commit-msg stage; fix now or add the Verify-Bypass trailer."
            );
        }
    }
}

fn print_json(stage: Stage, reports: &[RuleReport], failures: usize) {
    let mut items = Vec::new();
    for r in reports {
        let bypass = match &r.bypass_reason {
            Some(b) => format!(",\"bypass_reason\":\"{}\"", json_escape(b)),
            None => String::new(),
        };
        items.push(format!(
            "{{\"rule_id\":\"{}\",\"verdict\":\"{}\",\"detail\":\"{}\",\"remediation\":\"{}\",\"incident_receipt\":\"{}\"{}}}",
            r.rule_id,
            r.verdict.as_str(),
            json_escape(&r.detail),
            json_escape(&r.remediation),
            json_escape(r.incident_receipt),
            bypass
        ));
    }
    println!(
        "{{\"stage\":\"{}\",\"binding\":{},\"failures\":{},\"results\":[{}]}}",
        stage.as_str(),
        stage.is_binding(),
        failures,
        items.join(",")
    );
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

// ── Ambient audit trail ──────────────────────────────────────────────────────

/// Append one audited bypass line to ambient.jsonl (or CHUMP_AMBIENT_LOG).
/// Best-effort: the audit trail must never break a commit.
fn emit_verify_bypassed(rule_id: &str, reason: &str, stage: Stage, gap_id: Option<&str>) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let worktree = repo_root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    // scanner-anchor: "kind":"verify_bypassed"
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{}\",\"worktree\":\"{}\",\"kind\":\"verify_bypassed\",\"rule\":\"{}\",\"reason\":\"{}\",\"stage\":\"{}\",\"gap_id\":\"{}\"}}",
        json_escape(&session),
        json_escape(&worktree),
        json_escape(rule_id),
        json_escape(reason),
        stage.as_str(),
        json_escape(gap_id.unwrap_or(""))
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Test helper: build a context with no git plumbing.
#[cfg(test)]
pub(crate) fn test_context(
    stage: Stage,
    repo_root: &std::path::Path,
    files: Vec<DiffFile>,
    commit_message: Option<&str>,
    gap_id: Option<&str>,
) -> VerifyContext {
    let bypasses = commit_message
        .map(parse_bypass_trailers)
        .unwrap_or_default();
    VerifyContext {
        stage,
        repo_root: repo_root.to_path_buf(),
        files,
        commit_message: commit_message.map(str::to_string),
        gap_id: gap_id.map(str::to_string),
        bypasses,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_diff_extracts_added_lines_per_file() {
        let ns = "A\tdocs/new.md\nM\tsrc/lib.rs\nD\tdocs/old.md\n";
        let patch = "diff --git a/docs/new.md b/docs/new.md\n--- /dev/null\n+++ b/docs/new.md\n@@ -0,0 +1,2 @@\n+hello\n+world\ndiff --git a/src/lib.rs b/src/lib.rs\n--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -1,0 +2 @@\n+let x = 1;\n";
        let files = parse_diff(ns, patch);
        assert_eq!(files.len(), 3);
        assert_eq!(files[0].path, "docs/new.md");
        assert_eq!(files[0].kind, ChangeKind::Added);
        assert_eq!(files[0].added_lines, vec!["hello", "world"]);
        assert_eq!(files[1].added_lines, vec!["let x = 1;"]);
        assert_eq!(files[2].kind, ChangeKind::Deleted);
        assert!(files[2].added_lines.is_empty());
    }

    #[test]
    fn parse_diff_rename_uses_new_path() {
        let ns = "R100\told/name.rs\tnew/name.rs\n";
        let files = parse_diff(ns, "");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "new/name.rs");
        assert_eq!(files[0].kind, ChangeKind::Renamed);
    }

    #[test]
    fn bypass_trailer_parses_rule_and_reason() {
        let msg = "feat: x\n\nbody\n\nVerify-Bypass: docs-delta: doc is a scratch note\nverify-bypass: test-lag:   covered by e2e suite\n";
        let map = parse_bypass_trailers(msg);
        assert_eq!(map.get("docs-delta").unwrap(), "doc is a scratch note");
        assert_eq!(map.get("test-lag").unwrap(), "covered by e2e suite");
    }

    #[test]
    fn bypass_trailer_ignores_malformed_lines() {
        let map = parse_bypass_trailers("Verify-Bypass: no-reason-part\nVerify-Bypass:\n");
        assert!(map.is_empty());
    }

    #[test]
    fn gap_token_extraction() {
        assert_eq!(
            first_gap_token("feat(CREDIBLE-155): unify gates"),
            Some("CREDIBLE-155".to_string())
        );
        assert_eq!(first_gap_token("no gap here"), None);
        // lowercase branch stems are uppercased by the caller before this.
        assert_eq!(first_gap_token("credible-155"), None);
    }
}
