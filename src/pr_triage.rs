//! INFRA-605: `chump pr triage`
//!
//! Scans all open PRs and reports per-PR:
//!   - classification: clean / dirty / failing / blocked / auto-merge-armed
//!   - real-failure check vs flake-class-detected
//!   - hours since CI last greened
//!
//! Options:
//!   --rerun-flakes   — trigger `gh run rerun` for runs classified as flakes
//!   --rebase-dirty   — auto-rebase + force-push for DIRTY PRs
//!   --json           — emit JSON output
//!
//! Testability:
//!   - `CHUMP_GH` env var overrides the `gh` binary path (for mock injection).

use std::process::Command;

fn gh_cmd() -> String {
    std::env::var("CHUMP_GH").unwrap_or_else(|_| "gh".to_string())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrClass {
    Clean,
    Dirty,
    Failing { flake_detected: bool },
    Blocked,
    AutoMergeArmed,
}

impl PrClass {
    pub fn label(&self) -> &'static str {
        match self {
            PrClass::Clean => "clean",
            PrClass::Dirty => "dirty",
            PrClass::Failing { .. } => "failing",
            PrClass::Blocked => "blocked",
            PrClass::AutoMergeArmed => "auto-merge-armed",
        }
    }
}

#[derive(Debug, Clone)]
pub struct PrEntry {
    pub number: u64,
    pub title: String,
    pub branch: String,
    pub class: PrClass,
    pub hours_since_green: Option<f64>,
    pub run_id: Option<String>,
    /// INFRA-1409: per-PR recommended mechanical action.
    pub recommended_action: Option<RecommendedAction>,
    /// INFRA-1409: when waiting-for-sibling, which gap.
    pub waiting_on_gap: Option<String>,
    /// INFRA-1409: name of the first failing check (informs action recommendation).
    pub failing_check: Option<String>,
}

/// INFRA-1409: machine-actionable next step for a PR.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecommendedAction {
    Rebase,
    ForcePush,
    ReArmAutoMerge,
    FixClippy,
    WaitForSibling,
    CloseAndRespawn,
    Monitor,
}

impl RecommendedAction {
    pub fn label(&self) -> &'static str {
        match self {
            RecommendedAction::Rebase => "rebase",
            RecommendedAction::ForcePush => "force-push",
            RecommendedAction::ReArmAutoMerge => "re-arm",
            RecommendedAction::FixClippy => "fix-clippy",
            RecommendedAction::WaitForSibling => "wait-sibling",
            RecommendedAction::CloseAndRespawn => "close-respawn",
            RecommendedAction::Monitor => "monitor",
        }
    }
}

/// INFRA-1409: derive the recommended action from a PR's classification
/// and (optionally) failing-check name + currently-claimed-gaps map.
pub fn recommend_action(
    class: &PrClass,
    failing_check: Option<&str>,
    sibling_claims: &std::collections::HashMap<String, String>,
) -> (RecommendedAction, Option<String>) {
    match class {
        PrClass::Clean => (RecommendedAction::Monitor, None),
        PrClass::AutoMergeArmed => (RecommendedAction::Monitor, None),
        PrClass::Dirty => (RecommendedAction::Rebase, None),
        PrClass::Blocked => {
            if let Some(check) = failing_check {
                let check_l = check.to_lowercase();
                for (gap_id, gap_title) in sibling_claims.iter() {
                    let t = gap_title.to_lowercase();
                    if t.contains(&check_l)
                        || (check_l.contains("audit") && t.contains("audit"))
                        || (check_l.contains("clippy") && t.contains("clippy"))
                        || (check_l.contains("acp") && t.contains("acp"))
                    {
                        return (RecommendedAction::WaitForSibling, Some(gap_id.clone()));
                    }
                }
            }
            (RecommendedAction::ReArmAutoMerge, None)
        }
        PrClass::Failing {
            flake_detected: true,
        } => (RecommendedAction::Monitor, None),
        PrClass::Failing {
            flake_detected: false,
        } => {
            if let Some(check) = failing_check {
                let check_l = check.to_lowercase();
                if check_l.contains("clippy") {
                    return (RecommendedAction::FixClippy, None);
                }
                if check_l.contains("fmt") {
                    return (RecommendedAction::Rebase, None);
                }
            }
            (RecommendedAction::CloseAndRespawn, None)
        }
    }
}

pub struct TriageReport {
    pub entries: Vec<PrEntry>,
}

fn run_gh(args: &[&str]) -> Result<String, String> {
    let out = Command::new(gh_cmd())
        .args(args)
        .output()
        .map_err(|e| format!("gh not found: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "gh {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// List open PRs, return JSON array string.
fn list_open_prs() -> Result<String, String> {
    run_gh(&[
        "pr",
        "list",
        "--state",
        "open",
        "--json",
        "number,title,headRefName,isDraft,autoMergeRequest,mergeStateStatus,statusCheckRollup",
        "--limit",
        "100",
    ])
}

#[derive(Debug)]
struct RawPr {
    number: u64,
    title: String,
    branch: String,
    is_draft: bool,
    auto_merge: bool,
    merge_state: String,
    checks: Vec<RawCheck>,
}

#[derive(Debug)]
struct RawCheck {
    state: String, // SUCCESS, FAILURE, PENDING, etc.
    name: String,
    started_at: Option<String>,
    completed_at: Option<String>,
    run_id: Option<u64>,
}

fn parse_prs(json: &str) -> Vec<RawPr> {
    // Minimal hand-rolled JSON parsing to avoid pulling in serde_json.
    // The gh output for this query is predictable enough.
    let json = json.trim();
    if json.is_empty() || json == "[]" || json == "null" {
        return vec![];
    }

    let mut prs = vec![];

    // Split on top-level objects — each PR is a {...} block.
    // We'll use a simple bracket counter approach.
    let chars: Vec<char> = json.chars().collect();
    let mut depth = 0i32;
    let mut start = None;
    let mut objects: Vec<String> = vec![];

    for (i, &c) in chars.iter().enumerate() {
        match c {
            '{' => {
                if depth == 1 {
                    start = Some(i);
                }
                depth += 1;
            }
            '}' => {
                depth -= 1;
                if depth == 1 {
                    if let Some(s) = start {
                        objects.push(chars[s..=i].iter().collect());
                        start = None;
                    }
                }
            }
            '[' => {
                if depth == 0 {
                    depth = 1;
                }
            }
            _ => {}
        }
    }

    for obj in &objects {
        let number = extract_u64(obj, "\"number\":");
        let title = extract_str(obj, "\"title\":");
        let branch = extract_str(obj, "\"headRefName\":");
        let is_draft = obj.contains("\"isDraft\":true");
        // autoMergeRequest is either null or an object; detect presence of object.
        let auto_merge_val = extract_str(obj, "\"autoMergeRequest\":");
        let auto_merge = !auto_merge_val.is_empty() && auto_merge_val != "null"
            || (!obj.contains("\"autoMergeRequest\":null")
                && (obj.contains("\"autoMergeRequest\":{")
                    || obj.contains("\"autoMergeRequest\": {")));
        let merge_state = extract_str(obj, "\"mergeStateStatus\":");

        let checks = extract_checks(obj);

        if let Some(n) = number {
            prs.push(RawPr {
                number: n,
                title,
                branch,
                is_draft,
                auto_merge,
                merge_state,
                checks,
            });
        }
    }

    prs
}

fn extract_u64(obj: &str, key: &str) -> Option<u64> {
    let pos = obj.find(key)?;
    let rest = &obj[pos + key.len()..].trim_start_matches(' ');
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn extract_str(obj: &str, key: &str) -> String {
    let Some(pos) = obj.find(key) else {
        return String::new();
    };
    let rest = obj[pos + key.len()..].trim_start_matches(' ');
    if rest.starts_with('"') {
        // JSON string — find closing quote (handle simple escapes)
        let inner = &rest[1..];
        let mut result = String::new();
        let mut escape = false;
        for c in inner.chars() {
            if escape {
                result.push(c);
                escape = false;
            } else if c == '\\' {
                escape = true;
            } else if c == '"' {
                break;
            } else {
                result.push(c);
            }
        }
        result
    } else if rest.starts_with("null") {
        String::new()
    } else {
        // bare value — take until delimiter
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c == '\n')
            .unwrap_or(rest.len());
        rest[..end].trim().to_string()
    }
}

fn extract_checks(obj: &str) -> Vec<RawCheck> {
    // Extract the statusCheckRollup array.
    let Some(pos) = obj.find("\"statusCheckRollup\":") else {
        return vec![];
    };
    let rest = &obj[pos + "\"statusCheckRollup\":".len()..].trim_start_matches(' ');
    if rest.starts_with("null") || rest.starts_with(']') {
        return vec![];
    }
    // Find the array bounds.
    let Some(arr_start) = rest.find('[') else {
        return vec![];
    };
    let arr = &rest[arr_start..];
    let mut depth = 0i32;
    let mut end = arr.len();
    for (i, c) in arr.chars().enumerate() {
        match c {
            '[' | '{' => depth += 1,
            ']' | '}' => {
                depth -= 1;
                if depth == 0 {
                    end = i + 1;
                    break;
                }
            }
            _ => {}
        }
    }
    let arr_str = &arr[..end];

    // Extract individual check objects.
    let mut checks = vec![];
    let chars: Vec<char> = arr_str.chars().collect();
    let mut d = 0i32;
    let mut s: Option<usize> = None;
    let mut check_objs: Vec<String> = vec![];
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '{' => {
                if d == 1 {
                    s = Some(i);
                }
                d += 1;
            }
            '}' => {
                d -= 1;
                if d == 1 {
                    if let Some(start) = s {
                        check_objs.push(chars[start..=i].iter().collect());
                        s = None;
                    }
                }
            }
            '[' if d == 0 => d = 1,
            _ => {}
        }
    }

    for co in &check_objs {
        // gh returns either CheckRun or StatusContext; both have a state or conclusion field.
        let state = extract_str(co, "\"state\":").to_uppercase();
        let conclusion = extract_str(co, "\"conclusion\":").to_uppercase();
        let effective_state = if !conclusion.is_empty() {
            conclusion
        } else {
            state
        };

        let name = extract_str(co, "\"name\":").to_string();
        let started_at = {
            let s = extract_str(co, "\"startedAt\":");
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        };
        let completed_at = {
            let s = extract_str(co, "\"completedAt\":");
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        };
        let run_id = extract_u64(co, "\"databaseId\":");

        checks.push(RawCheck {
            state: effective_state,
            name,
            started_at,
            completed_at,
            run_id,
        });
    }

    checks
}

fn hours_since_green(checks: &[RawCheck]) -> Option<f64> {
    // Find the most recent completedAt among SUCCESS checks.
    use std::time::{SystemTime, UNIX_EPOCH};

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_secs_f64();

    checks
        .iter()
        .filter(|c| c.state == "SUCCESS")
        .filter_map(|c| c.completed_at.as_deref())
        .filter_map(|ts| parse_iso8601(ts))
        .map(|t| (now - t) / 3600.0)
        .reduce(f64::min)
}

fn parse_iso8601(s: &str) -> Option<f64> {
    // Parse "2026-05-08T12:34:56Z" → unix seconds (good enough precision).
    let s = s.trim_end_matches('Z');
    let parts: Vec<&str> = s.splitn(2, 'T').collect();
    if parts.len() != 2 {
        return None;
    }
    let date_parts: Vec<u64> = parts[0].split('-').filter_map(|x| x.parse().ok()).collect();
    let time_parts: Vec<u64> = parts[1].split(':').filter_map(|x| x.parse().ok()).collect();
    if date_parts.len() < 3 || time_parts.len() < 3 {
        return None;
    }
    // Approximate: days since epoch.
    let y = date_parts[0];
    let m = date_parts[1];
    let d = date_parts[2];
    let h = time_parts[0];
    let min = time_parts[1];
    let sec = time_parts[2];

    // Days from 1970-01-01 using the Gregorian calendar approximation.
    let days = days_from_epoch(y, m, d)?;
    let total_secs = days * 86400 + h * 3600 + min * 60 + sec;
    Some(total_secs as f64)
}

fn days_from_epoch(y: u64, m: u64, d: u64) -> Option<u64> {
    if y < 1970 || m < 1 || m > 12 || d < 1 || d > 31 {
        return None;
    }
    let months = [0u64, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let is_leap = |yr: u64| yr % 4 == 0 && (yr % 100 != 0 || yr % 400 == 0);

    let mut days: u64 = 0;
    for yr in 1970..y {
        days += if is_leap(yr) { 366 } else { 365 };
    }
    for mo in 1..m {
        days += months[mo as usize];
        if mo == 2 && is_leap(y) {
            days += 1;
        }
    }
    days += d - 1;
    Some(days)
}

fn classify(pr: &RawPr) -> (PrClass, Option<String>) {
    if pr.is_draft {
        return (PrClass::Blocked, None);
    }

    // BEHIND = needs rebase → DIRTY (highest priority after draft).
    if pr.merge_state == "BEHIND" {
        return (PrClass::Dirty, None);
    }

    // Check failures take priority over merge-state BLOCKED, because GitHub
    // marks a PR BLOCKED whenever required checks are failing.
    let has_failure = pr
        .checks
        .iter()
        .any(|c| c.state == "FAILURE" || c.state == "TIMED_OUT" || c.state == "CANCELLED");
    if has_failure {
        let flake = detect_flake(&pr.checks);
        let run_id = failing_run_id(&pr.checks);
        return (
            PrClass::Failing {
                flake_detected: flake,
            },
            run_id,
        );
    }

    if pr.auto_merge {
        return (PrClass::AutoMergeArmed, None);
    }

    let has_pending = pr
        .checks
        .iter()
        .any(|c| c.state == "PENDING" || c.state == "IN_PROGRESS");
    if pr.merge_state == "BLOCKED" || has_pending {
        return (PrClass::Blocked, None);
    }

    (PrClass::Clean, None)
}

fn failing_run_id(checks: &[RawCheck]) -> Option<String> {
    checks
        .iter()
        .find(|c| c.state == "FAILURE" || c.state == "TIMED_OUT")
        .and_then(|c| c.run_id)
        .map(|id| id.to_string())
}

fn detect_flake(checks: &[RawCheck]) -> bool {
    // Heuristic: failure on a check whose name matches known flaky patterns.
    let flaky_patterns = [
        "test",
        "e2e",
        "integration",
        "battle",
        "preflight",
        "clippy",
        "cargo",
    ];
    checks
        .iter()
        .filter(|c| c.state == "FAILURE" || c.state == "TIMED_OUT")
        .any(|c| {
            let lower = c.name.to_lowercase();
            flaky_patterns.iter().any(|p| lower.contains(p))
        })
}

pub struct TriageOptions {
    pub rerun_flakes: bool,
    pub rebase_dirty: bool,
    pub json: bool,
}

/// INFRA-1409: scan .chump-locks/*.json for active sibling leases. Returns
/// a `{gap_id → gap_title}` map for cross-reference when recommending
/// `wait-for-sibling` actions. Used by `recommend_action()`.
///
/// Lease file shape (from atomic_claim::write_basic_lease):
///   { "gap_id": "INFRA-1410", "title": "...", "session_id": "...", ... }
pub fn load_sibling_claims() -> std::collections::HashMap<String, String> {
    use std::path::PathBuf;
    let repo_root: PathBuf = std::env::var("CHUMP_REPO_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::current_dir().unwrap_or_default());
    let locks_dir = repo_root.join(".chump-locks");
    let mut map = std::collections::HashMap::new();
    let Ok(entries) = std::fs::read_dir(&locks_dir) else {
        return map;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&p) else {
            continue;
        };
        // Skip non-lease files (curator metadata, ambient, etc.).
        if !body.contains("\"gap_id\":") {
            continue;
        }
        // Hand-rolled extraction to avoid serde_json.
        let gap_id = extract_json_str(&body, "gap_id").unwrap_or_default();
        let title = extract_json_str(&body, "title").unwrap_or_default();
        if !gap_id.is_empty() {
            map.insert(gap_id, title);
        }
    }
    map
}

/// Crude JSON string-field extractor for "\"key\":\"value\"" patterns.
fn extract_json_str(body: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":\"", key);
    let start = body.find(&needle)? + needle.len();
    let rest = &body[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

pub fn run_triage(opts: &TriageOptions) -> Result<TriageReport, String> {
    let raw = list_open_prs()?;
    let prs = parse_prs(&raw);

    // INFRA-1409: load sibling-claimed gaps once for the whole report so
    // each PR's `wait-for-sibling` recommendation can cross-reference.
    let sibling_claims = load_sibling_claims();

    let mut entries = vec![];
    for pr in &prs {
        let (class, run_id) = classify(pr);
        let hours = hours_since_green(&pr.checks);
        // First failing check name (informs recommended action).
        let failing_check: Option<String> = pr
            .checks
            .iter()
            .find(|c| c.state == "FAILURE")
            .map(|c| c.name.clone());
        let (action, waiting_on) =
            recommend_action(&class, failing_check.as_deref(), &sibling_claims);
        entries.push(PrEntry {
            number: pr.number,
            title: pr.title.clone(),
            branch: pr.branch.clone(),
            class,
            hours_since_green: hours,
            run_id,
            recommended_action: Some(action),
            waiting_on_gap: waiting_on,
            failing_check,
        });
    }

    if opts.rerun_flakes {
        for entry in &entries {
            if let PrClass::Failing {
                flake_detected: true,
            } = entry.class
            {
                if let Some(run_id) = &entry.run_id {
                    eprintln!(
                        "chump pr triage: --rerun-flakes: rerunning failed checks for PR #{}",
                        entry.number
                    );
                    let _ = Command::new(gh_cmd())
                        .args(["run", "rerun", run_id, "--failed"])
                        .status();
                }
            }
        }
    }

    if opts.rebase_dirty {
        for entry in &entries {
            if entry.class == PrClass::Dirty {
                eprintln!(
                    "chump pr triage: --rebase-dirty: rebasing PR #{} ({})",
                    entry.number, entry.branch
                );
                if !rebase_allowed(entry.number) {
                    eprintln!(
                        "  → PR #{} is held (arm policy); not touching it",
                        entry.number
                    );
                    continue;
                }
                let status = Command::new(gh_cmd())
                    .args(["pr", "update-branch", &entry.number.to_string()])
                    .status();
                match status {
                    Ok(s) if s.success() => {
                        eprintln!("  → rebased PR #{}", entry.number);
                    }
                    Ok(s) => {
                        eprintln!(
                            "  → gh pr update-branch exited {:?} for PR #{}",
                            s.code(),
                            entry.number
                        );
                    }
                    Err(e) => {
                        eprintln!("  → failed to rebase PR #{}: {e}", entry.number);
                    }
                }
            }
        }
    }

    Ok(TriageReport { entries })
}

/// INFRA-8221: the one arm policy — a held PR (no-auto-merge label /
/// `Auto-merge: hold`) is never update-branched by `--rebase-dirty`.
fn rebase_allowed(pr: u64) -> bool {
    chump_ship::arm_policy::require_touch_allowed(pr, "", "chump pr triage --rebase-dirty").is_ok()
}

pub fn render_text(report: &TriageReport) -> String {
    if report.entries.is_empty() {
        return "chump pr triage: no open PRs found.\n".to_string();
    }
    let mut out = String::new();
    out.push_str(&format!(
        "PR TRIAGE — {} open PRs\n\n",
        report.entries.len()
    ));
    // INFRA-1409: ACTION column added.
    out.push_str(&format!(
        "{:<6} {:<16} {:<14} {:<14} {:<8}\n",
        "PR#", "CLASS", "CI-GREENED", "ACTION", "TITLE"
    ));
    out.push_str(&"-".repeat(86));
    out.push('\n');
    for e in &report.entries {
        let green = match e.hours_since_green {
            Some(h) if h < 1.0 => format!("{:.0}m ago", h * 60.0),
            Some(h) if h < 24.0 => format!("{:.1}h ago", h),
            Some(h) => format!("{:.0}d ago", h / 24.0),
            None => "never".to_string(),
        };
        let flake_tag = match &e.class {
            PrClass::Failing {
                flake_detected: true,
            } => " [FLAKE?]",
            _ => "",
        };
        let title = if e.title.len() > 36 {
            format!("{}…", &e.title[..35])
        } else {
            e.title.clone()
        };
        // INFRA-1409: action column + optional waiting-on-gap suffix.
        let action_str = e
            .recommended_action
            .as_ref()
            .map(|a| {
                if let Some(g) = e.waiting_on_gap.as_ref() {
                    format!("{}:{}", a.label(), g)
                } else {
                    a.label().to_string()
                }
            })
            .unwrap_or_else(|| "?".to_string());
        out.push_str(&format!(
            "#{:<5} {:<16} {:<14} {:<14} {}{}\n",
            e.number,
            e.class.label(),
            green,
            action_str,
            title,
            flake_tag
        ));
    }
    out
}

pub fn render_json(report: &TriageReport) -> String {
    let mut parts = vec![];
    for e in &report.entries {
        let flake = matches!(
            &e.class,
            PrClass::Failing {
                flake_detected: true
            }
        );
        let hours = e
            .hours_since_green
            .map(|h| format!("{:.2}", h))
            .unwrap_or_else(|| "null".to_string());
        // INFRA-1409: new fields recommended_action, waiting_on_gap, failing_check.
        let action_field = e
            .recommended_action
            .as_ref()
            .map(|a| format!("\"{}\"", a.label()))
            .unwrap_or_else(|| "null".to_string());
        let waiting_field = e
            .waiting_on_gap
            .as_ref()
            .map(|g| json_str(g).to_string())
            .unwrap_or_else(|| "null".to_string());
        let failing_field = e
            .failing_check
            .as_ref()
            .map(|s| json_str(s).to_string())
            .unwrap_or_else(|| "null".to_string());
        parts.push(format!(
            r#"{{"number":{},"title":{},"branch":{},"class":"{}","flake_detected":{},"hours_since_green":{},"recommended_action":{},"waiting_on_gap":{},"failing_check":{}}}"#,
            e.number,
            json_str(&e.title),
            json_str(&e.branch),
            e.class.label(),
            flake,
            hours,
            action_field,
            waiting_field,
            failing_field,
        ));
    }
    format!("[{}]\n", parts.join(","))
}

fn json_str(s: &str) -> String {
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INFRA-8221: --rebase-dirty refuses a held PR.
    #[test]
    fn rebase_dirty_refuses_held_pr() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("no-auto-merge");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        assert!(!rebase_allowed(4242));
        assert!(std::fs::read_to_string(&amb)
            .unwrap()
            .contains("--rebase-dirty"));
    }

    #[test]
    fn test_classify_clean() {
        let pr = RawPr {
            number: 1,
            title: "clean pr".into(),
            branch: "feat-x".into(),
            is_draft: false,
            auto_merge: false,
            merge_state: "CLEAN".into(),
            checks: vec![RawCheck {
                state: "SUCCESS".into(),
                name: "ci".into(),
                started_at: None,
                completed_at: Some("2026-05-08T10:00:00Z".into()),
                run_id: None,
            }],
        };
        let (class, _) = classify(&pr);
        assert_eq!(class, PrClass::Clean);
    }

    #[test]
    fn test_classify_dirty() {
        let pr = RawPr {
            number: 2,
            title: "dirty pr".into(),
            branch: "feat-y".into(),
            is_draft: false,
            auto_merge: false,
            merge_state: "BEHIND".into(),
            checks: vec![],
        };
        let (class, _) = classify(&pr);
        assert_eq!(class, PrClass::Dirty);
    }

    #[test]
    fn test_classify_failing_flake() {
        let pr = RawPr {
            number: 3,
            title: "flaky pr".into(),
            branch: "feat-z".into(),
            is_draft: false,
            auto_merge: false,
            merge_state: "BLOCKED".into(),
            checks: vec![RawCheck {
                state: "FAILURE".into(),
                name: "test-cargo-unit".into(),
                started_at: None,
                completed_at: None,
                run_id: Some(999),
            }],
        };
        let (class, _) = classify(&pr);
        assert!(matches!(
            class,
            PrClass::Failing {
                flake_detected: true
            }
        ));
    }

    #[test]
    fn test_classify_auto_merge_armed() {
        let pr = RawPr {
            number: 4,
            title: "armed pr".into(),
            branch: "feat-w".into(),
            is_draft: false,
            auto_merge: true,
            merge_state: "CLEAN".into(),
            checks: vec![],
        };
        let (class, _) = classify(&pr);
        assert_eq!(class, PrClass::AutoMergeArmed);
    }

    #[test]
    fn test_parse_iso8601() {
        let t = parse_iso8601("2026-05-08T12:00:00Z");
        assert!(t.is_some());
        assert!(t.unwrap() > 0.0);
    }

    #[test]
    fn test_render_text_empty() {
        let r = TriageReport { entries: vec![] };
        let text = render_text(&r);
        assert!(text.contains("no open PRs"));
    }

    #[test]
    fn test_render_json() {
        let r = TriageReport {
            entries: vec![PrEntry {
                number: 1,
                title: "Test PR".into(),
                branch: "feat".into(),
                class: PrClass::Clean,
                hours_since_green: Some(2.5),
                run_id: None,
                recommended_action: Some(RecommendedAction::Monitor),
                waiting_on_gap: None,
                failing_check: None,
            }],
        };
        let json = render_json(&r);
        assert!(json.contains("\"class\":\"clean\""));
        assert!(json.contains("\"number\":1"));
    }
}
