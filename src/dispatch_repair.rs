//! INFRA-8199 — `chump dispatch` open-PR gate, repair brief, and a work
//! prompt that never decomposes on its own.
//!
//! Receipt (cuphead `~/.chump/dispatch-logs/CREDIBLE-1491.redispatch.log`,
//! 2026-10-16 00:35Z): `chump dispatch CREDIBLE-1491 --backend headless
//! --auto-merge` with no `--prompt` auto-built the work prompt from the gap.
//! PR #5473 (branch `claude/credible-1491`, red on fmt/clippy/test) was
//! already open, and the gap description ended with "Decompose at claim
//! time". The agent never touched the PR: it filed eight sub-gaps (two at
//! P0, pushing the P0 budget past 5), rewrote the umbrella's `depends_on`
//! and committed a decomposition doc. Cleanup was by hand.
//!
//! Three rules close that class:
//!
//! 1. **Refuse.** Before any work backend is spawned, run the INFRA-1982
//!    open-PR check. An open PR for the gap refuses the dispatch (PR number +
//!    head branch printed) unless `CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1`.
//! 2. **Repair.** With the override set and a PR open, the auto-built prompt
//!    is a REPAIR brief (PR number, head branch, failing check names from the
//!    local github cache or `gh pr checks`, "fix and push"), and the worktree
//!    starts from the PR head branch instead of `origin/main`. Every brief
//!    emits `kind=dispatch_repair_brief_built` so repairs are auditable.
//! 3. **Never decompose.** The repair brief carries no decomposition
//!    instructions at all. With no PR and a description that asks for
//!    "Decompose at claim time", the prompt tells the agent to run
//!    `chump gap decompose <ID> --dry-run` and STOP: filing sub-gaps is the
//!    operator's or the decompose curator's call, not a dispatched agent's.
//!
//! INFRA-332 (`subagent-shipping-epilogue`): the ordinary work prompt is
//! built by [`crate::execute_gap::build_execute_gap_prompt`], which injects
//! `scripts/dispatch/subagent-shipping-epilogue.md` verbatim, so that path
//! carries the canonical bot-merge / final-report contract. The repair brief
//! and the decompose-review brief deliberately do NOT inject it: the epilogue
//! tells the agent to open a PR and run bot-merge, while a repair pushes to
//! the existing PR's branch ("do not open a new PR") and a decompose review
//! makes no commits at all. Injecting it there would hand the agent two
//! contradictory shipping contracts.
//!
//! The pure pieces (matching, parsing, prompt builders) are unit-tested
//! below; the thin `chump dispatch` arm in `main.rs` only calls
//! [`open_pr_gate`] and [`build_auto_prompt`].

use std::path::Path;
use std::process::Command;

/// The INFRA-1982 bypass env var, shared with `chump claim`.
pub const ALLOW_DUP_ENV: &str = "CHUMP_CLAIM_ALLOW_DUPLICATE_PR";

/// One open pull request that covers the gap being dispatched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenPr {
    pub number: u64,
    pub head_branch: String,
    pub title: String,
    /// Head commit SHA (`headRefOid`); empty when gh didn't return it.
    pub head_sha: String,
}

/// True when `haystack` mentions `gap_id` as a whole token, case-insensitive.
/// `CREDIBLE-149` must not match a PR titled `CREDIBLE-1491: ...`, so the
/// characters on either side of the hit must not be ASCII alphanumerics.
pub fn contains_gap_token(haystack: &str, gap_id: &str) -> bool {
    let hay = haystack.to_ascii_lowercase();
    let needle = gap_id.to_ascii_lowercase();
    if needle.is_empty() {
        return false;
    }
    let bytes = hay.as_bytes();
    let mut start = 0;
    while let Some(off) = hay[start..].find(&needle) {
        let i = start + off;
        let end = i + needle.len();
        let before_ok = i == 0 || !bytes[i - 1].is_ascii_alphanumeric();
        let after_ok = end >= bytes.len() || !bytes[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        start = i + 1;
    }
    false
}

/// True when `branch` is one of the gap's conventional head branches:
/// `chump/<slug>...` (chump claim) or `claude/<slug>...` (chump dispatch,
/// see `chump_orchestrator::dispatch::dispatch_paths`), token-bounded.
pub fn branch_is_for_gap(branch: &str, gap_id: &str) -> bool {
    let slug = gap_id.to_ascii_lowercase().replace('_', "-");
    let b = branch.to_ascii_lowercase();
    ["chump/", "claude/"].iter().any(|prefix| {
        b.strip_prefix(prefix)
            .and_then(|rest| rest.strip_prefix(slug.as_str()))
            .map(|tail| {
                tail.is_empty()
                    || !tail
                        .as_bytes()
                        .first()
                        .map(u8::is_ascii_alphanumeric)
                        .unwrap_or(false)
            })
            .unwrap_or(false)
    })
}

/// Pick the first open PR in a `gh pr list --json
/// number,title,headRefName,headRefOid` array that covers `gap_id`: title
/// mentions the gap as a token, or the head branch is the gap's branch.
pub fn match_open_pr(gap_id: &str, prs: &[serde_json::Value]) -> Option<OpenPr> {
    prs.iter().find_map(|v| {
        let number = v["number"].as_u64()?;
        let title = v["title"].as_str().unwrap_or("");
        let head = v["headRefName"].as_str().unwrap_or("");
        if contains_gap_token(title, gap_id) || branch_is_for_gap(head, gap_id) {
            Some(OpenPr {
                number,
                head_branch: head.to_string(),
                title: title.to_string(),
                head_sha: v["headRefOid"].as_str().unwrap_or("").to_string(),
            })
        } else {
            None
        }
    })
}

fn gh_pr_list(repo_root: &Path, extra: &[&str]) -> Vec<serde_json::Value> {
    let mut cmd = Command::new("gh");
    cmd.args(["pr", "list", "--state", "open"])
        .args(extra)
        .args([
            "--json",
            "number,title,headRefName,headRefOid",
            "--limit",
            "30",
        ])
        .current_dir(repo_root);
    match cmd.output() {
        Ok(out) if out.status.success() => {
            serde_json::from_slice::<Vec<serde_json::Value>>(&out.stdout).unwrap_or_default()
        }
        _ => Vec::new(),
    }
}

/// INFRA-1982 open-PR check for dispatch: search open PRs for the gap ID,
/// then fall back to the dispatch head branch (`claude/<slug>`) in case the
/// PR title never named the gap. Best-effort: gh failures → `None` (offline
/// fallback, same as `chump claim`).
pub fn find_open_pr_for_gap(repo_root: &Path, gap_id: &str) -> Option<OpenPr> {
    let by_search = gh_pr_list(repo_root, &["--search", gap_id]);
    if let Some(pr) = match_open_pr(gap_id, &by_search) {
        return Some(pr);
    }
    let branch = format!("claude/{}", gap_id.to_ascii_lowercase().replace('_', "-"));
    let by_head = gh_pr_list(repo_root, &["--head", &branch]);
    match_open_pr(gap_id, &by_head)
}

/// Same truthiness rule `chump claim` uses for the bypass: set, non-empty,
/// not "0".
pub fn allow_duplicate_pr_from_env() -> bool {
    std::env::var(ALLOW_DUP_ENV)
        .map(|v| !v.trim().is_empty() && v.trim() != "0")
        .unwrap_or(false)
}

/// The refusal printed when a dispatch hits an open PR without the override.
pub fn refusal_message(gap_id: &str, pr: &OpenPr) -> String {
    format!(
        "[dispatch] INFRA-1982/INFRA-8199: open PR #{n} already covers {gap} \
         (head branch: {branch}). Refusing to spawn a work backend that would \
         start over from origin/main.\n  Repair it there, or set {env}=1 to \
         dispatch a REPAIR brief onto {branch}.",
        n = pr.number,
        gap = gap_id,
        branch = pr.head_branch,
        env = ALLOW_DUP_ENV,
    )
}

/// Pure decision for the gate: `Ok(None)` = no PR, proceed normally;
/// `Ok(Some(pr))` = PR open and override set, dispatch a repair;
/// `Err(msg)` = PR open, no override, refuse.
pub fn decide_gate(
    gap_id: &str,
    open: Option<OpenPr>,
    allow_dup: bool,
) -> Result<Option<OpenPr>, String> {
    match open {
        None => Ok(None),
        Some(pr) if allow_dup => Ok(Some(pr)),
        Some(pr) => Err(refusal_message(gap_id, &pr)),
    }
}

/// The gate `chump dispatch` runs before spawning any work backend.
pub fn open_pr_gate(repo_root: &Path, gap_id: &str) -> Result<Option<OpenPr>, String> {
    decide_gate(
        gap_id,
        find_open_pr_for_gap(repo_root, gap_id),
        allow_duplicate_pr_from_env(),
    )
}

/// Check conclusions/buckets that count as "failing" for a repair brief.
fn is_failing(state: &str) -> bool {
    matches!(
        state.trim().to_ascii_lowercase().as_str(),
        "failure" | "fail" | "timed_out" | "cancelled" | "cancel" | "action_required" | "error"
    )
}

/// Parse `cache_lookup_checks <sha>` output (`name\tstatus\tconclusion` per
/// line) into the failing check names, sorted and deduplicated.
pub fn failing_checks_from_cache(text: &str) -> Vec<String> {
    let mut names: Vec<String> = text
        .lines()
        .filter_map(|line| {
            let mut cols = line.split('\t');
            let name = cols.next()?.trim();
            let _status = cols.next().unwrap_or("");
            let conclusion = cols.next().unwrap_or("");
            (!name.is_empty() && is_failing(conclusion)).then(|| name.to_string())
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Parse `gh pr checks <N> --json name,bucket` output into the failing
/// check names, sorted and deduplicated.
pub fn failing_checks_from_gh_json(bytes: &[u8]) -> Vec<String> {
    let arr: Vec<serde_json::Value> = serde_json::from_slice(bytes).unwrap_or_default();
    let mut names: Vec<String> = arr
        .iter()
        .filter_map(|v| {
            let name = v["name"].as_str()?.trim();
            let bucket = v["bucket"]
                .as_str()
                .or_else(|| v["state"].as_str())
                .unwrap_or("");
            (!name.is_empty() && is_failing(bucket)).then(|| name.to_string())
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Failing check names for the PR head, cache-first (INFRA-1081): the local
/// github cache via `scripts/coord/lib/github_cache.sh::cache_lookup_checks`,
/// then `gh pr checks` on a miss. Returns the names plus which source
/// answered (`cache`, `gh`, or `none`).
pub fn lookup_failing_checks(repo_root: &Path, pr: &OpenPr) -> (Vec<String>, &'static str) {
    let canonical = crate::repo_path::main_checkout_root();
    let lib = repo_root.join("scripts/coord/lib/github_cache.sh");
    if !pr.head_sha.is_empty() && lib.exists() {
        let mut cmd = Command::new("bash");
        cmd.arg("-c")
            .arg(r#"source "$1" >/dev/null 2>&1 && cache_lookup_checks "$2""#)
            .arg("_")
            .arg(&lib)
            .arg(&pr.head_sha)
            .current_dir(&canonical);
        if std::env::var_os("CHUMP_CACHE_DB").is_none() {
            cmd.env("CHUMP_CACHE_DB", canonical.join(".chump/github_cache.db"));
        }
        if let Ok(out) = cmd.output() {
            let text = String::from_utf8_lossy(&out.stdout);
            if !text.trim().is_empty() {
                return (failing_checks_from_cache(&text), "cache");
            }
        }
    }
    // `gh pr checks` exits non-zero when any check failed or is pending, so
    // read stdout regardless of the exit status.
    if let Ok(out) = Command::new("gh")
        .args([
            "pr",
            "checks",
            &pr.number.to_string(),
            "--json",
            "name,bucket",
        ])
        .current_dir(repo_root)
        .output()
    {
        if !out.stdout.is_empty() {
            return (failing_checks_from_gh_json(&out.stdout), "gh");
        }
    }
    (Vec::new(), "none")
}

fn rules_block(rules: &str) -> String {
    if rules.trim().is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    }
}

/// Build the REPAIR brief for an open PR. Contains no decomposition
/// instructions of any kind (INFRA-8199 AC3).
pub fn build_repair_brief(
    gap_id: &str,
    pr: &OpenPr,
    failing: &[String],
    checks_source: &str,
    rules: &str,
) -> String {
    let checks = if failing.is_empty() {
        format!(
            "No failing checks were found (source: {checks_source}). Run \
             `gh pr checks {n}` to read the current state before changing anything.",
            n = pr.number
        )
    } else {
        let list: Vec<String> = failing.iter().map(|c| format!("  - {c}")).collect();
        format!(
            "Failing checks on the PR head (source: {checks_source}):\n{}",
            list.join("\n")
        )
    };
    format!(
        "{rules}You are a Chump dispatched agent REPAIRING an existing pull request \
for gap {gap}.\n\n\
PR #{n} (\"{title}\") is already open for this gap. Its head branch is `{branch}`. \
This worktree is checked out on `{branch}` (not origin/main), so the PR's commits \
are already here.\n\n\
{checks}\n\n\
Your job:\n\
1. Reproduce each failing check locally (for Rust: `cargo fmt --all -- --check`, \
`cargo clippy --workspace --all-targets -- -D warnings`, the named test) and fix the cause.\n\
2. Commit the fix on `{branch}` and push it: `git push origin HEAD:{branch}`.\n\
3. Do not open a new PR, and do not close or retitle PR #{n}. Rebase onto origin/main \
only if the PR is DIRTY.\n\n\
Scope: this is a repair of PR #{n}, not new work. Do not file, reserve or split gaps, \
do not edit the gap's depends_on, and do not write planning docs. If the failure \
cannot be fixed inside this PR, say why in your final message and stop.\n\n\
Reply with the PR number when the fix is pushed.",
        rules = rules_block(rules),
        gap = gap_id,
        n = pr.number,
        title = pr.title,
        branch = pr.head_branch,
        checks = checks,
    )
}

/// True when the gap description asks for decomposition at claim time
/// ("Decompose at claim time", "decompose at claim-time", ...).
pub fn description_requests_decompose(description: &str) -> bool {
    let norm: String = description
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c == '-' || c == '_' { ' ' } else { c })
        .collect();
    let norm = norm.split_whitespace().collect::<Vec<_>>().join(" ");
    norm.contains("decompose at claim time") || norm.contains("decompose at claim")
}

/// Prompt for a gap whose description asks for claim-time decomposition:
/// propose via `chump gap decompose <ID> --dry-run`, then STOP for review.
pub fn build_decompose_review_prompt(gap_id: &str, rules: &str) -> String {
    format!(
        "{rules}You are a Chump dispatched agent on gap {gap}. Its description asks \
for decomposition at claim time.\n\n\
Run exactly this and nothing else that changes state:\n  \
chump gap decompose {gap} --dry-run\n\n\
Then STOP. Put the proposed slices in your final message for review. Filing \
sub-gaps is the operator's or the decompose curator's call, not yours: do not \
run `chump gap reserve`, do not file sub-gaps, do not edit the umbrella's \
depends_on or priority, and do not commit a decomposition doc. Make no commits \
and do not run bot-merge.",
        rules = rules_block(rules),
        gap = gap_id,
    )
}

/// Guard sentence appended to the ordinary (no PR, no decompose request)
/// work prompt so a large gap can't trigger self-directed sub-gap filing.
pub const NO_SELF_FILING_GUARD: &str = "\n\n---\n\nINFRA-8199 guard: filing \
sub-gaps or new gaps is the operator's call, not yours. Never run \
`chump gap reserve`, never edit another gap's depends_on or priority, and \
never commit planning docs from this session. If the gap is too large to \
ship in one PR, say so in your final message and stop.";

/// Which kind of auto-built prompt `chump dispatch` produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutoPromptKind {
    /// Ordinary work prompt (execute-gap prompt + guard).
    Work,
    /// Repair brief for an open PR.
    Repair,
    /// Decompose `--dry-run` then stop for review.
    DecomposeReview,
}

/// Pure prompt selection. `base_work_prompt` is the execute-gap prompt; it is
/// only used for [`AutoPromptKind::Work`].
pub fn select_auto_prompt(
    gap_id: &str,
    description: &str,
    open_pr: Option<(&OpenPr, &[String], &str)>,
    base_work_prompt: &str,
    rules: &str,
) -> (AutoPromptKind, String) {
    if let Some((pr, failing, source)) = open_pr {
        return (
            AutoPromptKind::Repair,
            build_repair_brief(gap_id, pr, failing, source, rules),
        );
    }
    if description_requests_decompose(description) {
        return (
            AutoPromptKind::DecomposeReview,
            build_decompose_review_prompt(gap_id, rules),
        );
    }
    (
        AutoPromptKind::Work,
        format!("{base_work_prompt}{NO_SELF_FILING_GUARD}"),
    )
}

fn gap_description(gap_id: &str) -> String {
    let canonical = crate::repo_path::main_checkout_root();
    chump_gap_store::GapStore::open(&canonical)
        .ok()
        .and_then(|store| store.get(gap_id).ok().flatten())
        .map(|row| row.description)
        .unwrap_or_default()
}

/// Build the auto prompt for `chump dispatch --backend headless` with no
/// `--prompt`. Looks up the description and (for a repair) the failing
/// checks, and emits `kind=dispatch_repair_brief_built` for every repair.
pub fn build_auto_prompt(
    gap_id: &str,
    repo_root: &Path,
    open_pr: Option<&OpenPr>,
) -> (AutoPromptKind, String) {
    let rules = std::fs::read_to_string(repo_root.join("docs/process/CHUMP_DISPATCH_RULES.md"))
        .unwrap_or_default();
    let description = gap_description(gap_id);
    match open_pr {
        Some(pr) => {
            let (failing, source) = lookup_failing_checks(repo_root, pr);
            let out = select_auto_prompt(
                gap_id,
                &description,
                Some((pr, &failing, source)),
                "",
                &rules,
            );
            emit_dispatch_repair_brief_built(gap_id, pr, &failing, source);
            out
        }
        None => {
            if description_requests_decompose(&description) {
                select_auto_prompt(gap_id, &description, None, "", &rules)
            } else {
                let base = crate::execute_gap::build_execute_gap_prompt(gap_id, repo_root);
                select_auto_prompt(gap_id, &description, None, &base, "")
            }
        }
    }
}

fn json_escape(s: &str) -> String {
    serde_json::to_string(s)
        .map(|q| q[1..q.len() - 1].to_string())
        .unwrap_or_default()
}

/// Emit `kind=dispatch_repair_brief_built` so every repair dispatch is
/// auditable (which PR, which branch, how many failing checks, from where).
/// Render one `kind=dispatch_repair_brief_built` JSONL line (pure).
pub fn repair_brief_event_line(
    ts: &str,
    session: &str,
    gap_id: &str,
    pr: &OpenPr,
    failing: &[String],
    checks_source: &str,
) -> String {
    // scanner-anchor: "kind":"dispatch_repair_brief_built"
    format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"dispatch_repair_brief_built\",\"session\":\"{session}\",\
         \"gap_id\":\"{gap}\",\"pr_number\":{n},\"head_branch\":\"{branch}\",\
         \"failing_checks\":\"{checks}\",\"checks_source\":\"{source}\"}}",
        ts = json_escape(ts),
        session = json_escape(session),
        gap = json_escape(gap_id),
        n = pr.number,
        branch = json_escape(&pr.head_branch),
        checks = json_escape(&failing.join(",")),
        source = json_escape(checks_source),
    )
}

/// Emit `kind=dispatch_repair_brief_built` so every repair dispatch is
/// auditable (which PR, which branch, how many failing checks, from where).
pub fn emit_dispatch_repair_brief_built(
    gap_id: &str,
    pr: &OpenPr,
    failing: &[String],
    checks_source: &str,
) {
    let lock_dir = crate::repo_path::runtime_base().join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));
    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = repair_brief_event_line(&ts, &session, gap_id, pr, failing, checks_source);
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }
    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = Command::new("chump-coord")
            .arg("emit")
            .arg("dispatch_repair_brief_built")
            .arg(format!("gap_id={gap_id}"))
            .arg(format!("pr_number={}", pr.number))
            .arg(format!("head_branch={}", pr.head_branch))
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr_5473() -> OpenPr {
        OpenPr {
            number: 5473,
            head_branch: "claude/credible-1491".to_string(),
            title: "CREDIBLE-1491: branch-protection baseline".to_string(),
            head_sha: "abc123".to_string(),
        }
    }

    /// Fixture shaped like the 00:35Z receipt: the description that ended
    /// with "Decompose at claim time".
    const RECEIPT_DESCRIPTION: &str = "Umbrella for the branch-protection \
        baseline work. Rough shape: (a) baseline file, (b) drift check, (c) \
        CI gate. Decompose at claim time.";

    #[test]
    fn gap_token_is_boundary_aware() {
        assert!(contains_gap_token("CREDIBLE-1491: fix", "CREDIBLE-1491"));
        assert!(contains_gap_token("fix (credible-1491)", "CREDIBLE-1491"));
        assert!(!contains_gap_token(
            "CREDIBLE-14910: other",
            "CREDIBLE-1491"
        ));
        assert!(!contains_gap_token("CREDIBLE-1491: x", "CREDIBLE-149"));
        assert!(!contains_gap_token("anything", ""));
    }

    #[test]
    fn branch_match_covers_claim_and_dispatch_conventions() {
        assert!(branch_is_for_gap("claude/credible-1491", "CREDIBLE-1491"));
        assert!(branch_is_for_gap(
            "chump/credible-1491-fleet-1",
            "CREDIBLE-1491"
        ));
        assert!(!branch_is_for_gap("claude/credible-14910", "CREDIBLE-1491"));
        assert!(!branch_is_for_gap("feature/credible-1491", "CREDIBLE-1491"));
    }

    #[test]
    fn match_open_pr_by_title_or_branch() {
        let prs: Vec<serde_json::Value> = serde_json::from_str(
            r#"[
              {"number":1,"title":"CREDIBLE-14910: unrelated","headRefName":"chump/credible-14910","headRefOid":"x"},
              {"number":5473,"title":"wip","headRefName":"claude/credible-1491","headRefOid":"abc123"}
            ]"#,
        )
        .unwrap();
        let pr = match_open_pr("CREDIBLE-1491", &prs).expect("branch match");
        assert_eq!(pr.number, 5473);
        assert_eq!(pr.head_branch, "claude/credible-1491");
        assert_eq!(pr.head_sha, "abc123");
        assert!(match_open_pr("INFRA-1", &prs).is_none());
    }

    #[test]
    fn gate_refuses_without_override_and_repairs_with_it() {
        let err = decide_gate("CREDIBLE-1491", Some(pr_5473()), false).unwrap_err();
        assert!(err.contains("#5473"), "{err}");
        assert!(err.contains("claude/credible-1491"), "{err}");
        assert!(err.contains(ALLOW_DUP_ENV), "{err}");
        assert_eq!(
            decide_gate("CREDIBLE-1491", Some(pr_5473()), true).unwrap(),
            Some(pr_5473())
        );
        assert_eq!(decide_gate("CREDIBLE-1491", None, false).unwrap(), None);
    }

    #[test]
    fn failing_checks_parse_cache_and_gh() {
        let cache = "clippy\tcompleted\tfailure\nfast-checks\tcompleted\tsuccess\n\
                     fmt\tcompleted\tfailure\ntest\tcompleted\ttimed_out\n";
        assert_eq!(
            failing_checks_from_cache(cache),
            vec!["clippy", "fmt", "test"]
        );
        let gh = br#"[{"name":"fmt","bucket":"fail"},{"name":"docs","bucket":"pass"},
                      {"name":"cargo-test","bucket":"fail"},{"name":"x","bucket":"pending"}]"#;
        assert_eq!(failing_checks_from_gh_json(gh), vec!["cargo-test", "fmt"]);
        assert!(failing_checks_from_gh_json(b"not json").is_empty());
    }

    #[test]
    fn repair_brief_names_pr_branch_checks_and_never_decomposes() {
        let failing = vec!["clippy".to_string(), "fmt".to_string(), "test".to_string()];
        let (kind, prompt) = select_auto_prompt(
            "CREDIBLE-1491",
            RECEIPT_DESCRIPTION,
            Some((&pr_5473(), &failing, "cache")),
            "BASE WORK PROMPT",
            "",
        );
        assert_eq!(kind, AutoPromptKind::Repair);
        assert!(prompt.contains("PR #5473"), "{prompt}");
        assert!(prompt.contains("`claude/credible-1491`"), "{prompt}");
        for c in &failing {
            assert!(prompt.contains(&format!("  - {c}")), "missing check {c}");
        }
        assert!(prompt.contains("git push origin HEAD:claude/credible-1491"));
        assert!(
            !prompt.to_ascii_lowercase().contains("decompos"),
            "repair brief must carry no decomposition instruction: {prompt}"
        );
        assert!(
            !prompt.contains("BASE WORK PROMPT"),
            "repair brief must not fall back to the generic work prompt"
        );
    }

    #[test]
    fn repair_brief_with_no_failing_checks_points_at_gh() {
        let prompt = build_repair_brief("CREDIBLE-1491", &pr_5473(), &[], "none", "");
        assert!(prompt.contains("gh pr checks 5473"), "{prompt}");
        assert!(!prompt.to_ascii_lowercase().contains("decompos"));
    }

    #[test]
    fn decompose_request_without_pr_proposes_dry_run_and_stops() {
        let (kind, prompt) =
            select_auto_prompt("CREDIBLE-1491", RECEIPT_DESCRIPTION, None, "BASE", "");
        assert_eq!(kind, AutoPromptKind::DecomposeReview);
        assert!(prompt.contains("chump gap decompose CREDIBLE-1491 --dry-run"));
        assert!(prompt.contains("STOP"));
        assert!(prompt.contains("do not file sub-gaps"));
        assert!(prompt.contains("operator's or the decompose curator's call"));
        assert!(!prompt.contains("BASE"));
    }

    #[test]
    fn description_matcher_variants() {
        assert!(description_requests_decompose(
            "... Decompose at claim time."
        ));
        assert!(description_requests_decompose("decompose at claim-time"));
        assert!(description_requests_decompose("DECOMPOSE\nAT   CLAIM TIME"));
        assert!(!description_requests_decompose("Ship the fix to src/x.rs"));
    }

    #[test]
    fn ordinary_work_prompt_gets_the_no_self_filing_guard() {
        let (kind, prompt) =
            select_auto_prompt("INFRA-1", "Fix src/x.rs", None, "BASE WORK PROMPT", "");
        assert_eq!(kind, AutoPromptKind::Work);
        assert!(prompt.starts_with("BASE WORK PROMPT"));
        assert!(prompt.contains("Never run `chump gap reserve`"));
        assert!(!prompt.to_ascii_lowercase().contains("decompos"));
    }

    #[test]
    fn event_line_is_registered_kind_with_pr_number() {
        let line = repair_brief_event_line(
            "2026-10-16T00:35:00Z",
            "dispatch-credible-1491-1-1",
            "CREDIBLE-1491",
            &pr_5473(),
            &["fmt".to_string(), "clippy".to_string()],
            "gh",
        );
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["kind"], "dispatch_repair_brief_built");
        assert_eq!(v["gap_id"], "CREDIBLE-1491");
        assert_eq!(v["pr_number"], 5473);
        assert_eq!(v["head_branch"], "claude/credible-1491");
        assert_eq!(v["failing_checks"], "fmt,clippy");
        assert_eq!(v["checks_source"], "gh");
    }
}
