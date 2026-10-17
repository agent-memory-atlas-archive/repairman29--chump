//! ChumpBench runner — DOC-072 / EFFECTIVE-327.
//!
//! Runs a **track** (a repo + a plain-language task + a known-good acceptance check) as one
//! scoreable lap: optionally drive the track's mode engine, grade the acceptance check, tally
//! the human touches during the lap (the CREDIBLE-171 zero-touch metric), and print a scorecard.
//! The scorecard's human-touches-per-lap, trended across the suite, is the readiness number —
//! not CI-green, not a merged PR, but a course completed with no one reaching in.
//!
//! v1 scope: the schema + the grading/scoring harness + `ci-green` grading, proven on the
//! known-good RESCUE/BEAST lap. Engine-drive (`--apply`) shells the mode engine; other
//! acceptance kinds and ambient-event emission are honest follow-ups.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Locate the `comprehend` binary (almanac-organs). Honors `CHUMP_COMPREHEND_BIN`,
/// else falls back to `~/.cargo/bin/comprehend`. Inlined here (EFFECTIVE-405) to keep
/// this crate free of any inbound call to the bin — `comprehend_tool` stays in the bin
/// and keeps its own copy for its own uses; this pure env/HOME lookup has no shared state.
fn comprehend_bin() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("CHUMP_COMPREHEND_BIN") {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }
    let home = std::env::var("HOME").ok()?;
    let default = PathBuf::from(home).join(".cargo/bin/comprehend");
    default.exists().then_some(default)
}

/// A track: the schema from `e2e/chumpbench/<track>.yaml`.
#[derive(Debug, Deserialize)]
pub struct Track {
    pub id: String,
    pub mode: String,
    pub repo: String,
    #[serde(default)]
    pub stack: String,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub difficulty: String,
    pub task: String,
    pub acceptance: Acceptance,
    #[serde(default)]
    pub budget: Budget,
    /// CREDIBLE-187: an optional shell command run in the fresh clone BEFORE the agent,
    /// to seed a real, deterministic breakage the lap then rescues. This makes a RESCUE
    /// lap self-contained + repeatable (no dependence on a live, PR-invisible red check
    /// like the push-only ml-pipeline) and never touches the target's main. Pair with a
    /// `command` acceptance that goes green only once the break is fixed.
    #[serde(default)]
    pub seed_break: String,
}

#[derive(Debug, Deserialize)]
pub struct Acceptance {
    /// ci-green | test-passes | url-live | assertion | comprehension-accuracy
    pub kind: String,
    #[serde(default)]
    pub check: String,
    /// CREDIBLE-186: for `ci-green`, the name of the SPECIFIC check that was red
    /// (e.g. "ml-pipeline"). The acceptance PASSES only once THIS check is present
    /// and conclusively green — never on a transient window where only fast or
    /// unrelated checks have reported (the false-green that merged junk to
    /// BEAST-MODE main). Empty = grade all checks, but still require every check
    /// conclusive first (kills the race regardless).
    #[serde(default)]
    pub required_check: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct Budget {
    #[serde(default)]
    pub max_wall_clock_min: u64,
    #[serde(default)]
    pub max_human_touches: u64,
}

/// The verdict of an acceptance check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Pass,
    Fail,
    Unknown,
}

/// Grade a set of CI check-run conclusions. FAIL if any conclusive run failed; PASS if at least
/// one ran and none failed; UNKNOWN if nothing conclusive ran (e.g. CI is PR-scoped, not on the
/// branch we looked at). Conservative on purpose — a lap only PASSES on real green.
pub fn grade_check_conclusions(conclusions: &[String]) -> Verdict {
    let mut any_ok = false;
    for c in conclusions {
        match c.trim().to_lowercase().as_str() {
            "failure" | "cancelled" | "timed_out" | "action_required" | "startup_failure"
            | "stale" => return Verdict::Fail,
            "success" | "neutral" | "skipped" => any_ok = true,
            _ => {}
        }
    }
    if any_ok {
        Verdict::Pass
    } else {
        Verdict::Unknown
    }
}

/// The overall lap result: FAIL unless acceptance PASSED; then PASS if within the human-touch
/// budget, else PARTIAL (the acceptance was met, but a human had to reach in to get there).
pub fn overall_result(acc: Verdict, human_touches: Option<u64>, max_touches: u64) -> &'static str {
    match acc {
        Verdict::Fail | Verdict::Unknown => "FAIL",
        Verdict::Pass => match human_touches {
            Some(t) if t > max_touches => "PARTIAL",
            _ => "PASS",
        },
    }
}

/// A scored lap.
#[derive(Debug, Serialize)]
pub struct LapScore {
    pub track: String,
    pub mode: String,
    pub repo: String,
    pub acceptance_kind: String,
    pub acceptance_verdict: Verdict,
    pub result: String,
    pub human_touches: Option<u64>,
    pub detail: String,
    /// CREDIBLE-188: effort — wall-clock seconds for the whole lap (drive + score).
    /// The first honest effort dimension; a lap is now DATA, not just a green cell.
    #[serde(default)]
    pub wall_clock_s: u64,
    /// CREDIBLE-188: the preferred model class this lap routed to (from difficulty).
    /// The *actual* provider slot + token/cost live in the agent-run subprocess and
    /// need it to emit per-run cost before the bench can attribute them (filed follow-up).
    #[serde(default)]
    pub model_class: String,
    /// CREDIBLE-192: the SPIRIT judge's verdict on whether the change GENUINELY achieves
    /// the intent — GENUINE | STUB | HACK | PARTIAL | (empty = not judged / gateway down).
    /// ADVISORY for now (shown, not gated): the letter (acceptance) still decides result;
    /// this is the missing "does it do what we needed, in the best way" lens.
    #[serde(default)]
    pub spirit_verdict: String,
    #[serde(default)]
    pub spirit_reason: String,
    /// CREDIBLE-190: agent-loop effort signals, parsed from the task-directed agent-run
    /// output, so flails are LEGIBLE in the scorecard instead of hiding behind wall-clock.
    /// `tool_calls` = how many tools the agent invoked; `hit_iteration_cap` = the agent
    /// exhausted its max-iteration budget without terminating (the 1909s / 26-write flail:
    /// it produced the correct fix but couldn't recognize it was done and stop). Populated
    /// only on --implement laps (the ones that spawn a captured agent-run).
    #[serde(default)]
    pub tool_calls: u64,
    #[serde(default)]
    pub hit_iteration_cap: bool,
}

fn gh_bin() -> String {
    std::env::var("CHUMP_BENCH_GH_BIN")
        .or_else(|_| std::env::var("CHUMP_GH_BIN"))
        .unwrap_or_else(|_| "gh".to_string())
}

/// CREDIBLE-192: the SPIRIT judge — asks an LLM (via the shared `chump llm-complete`
/// gateway the code-reviewer uses) whether the lap's diff GENUINELY achieves the intent,
/// vs a stub / hack / teaching-to-the-test. ADVISORY: returns (verdict, reason); empty
/// verdict when there's no diff or the gateway is down. This is the missing SPIRIT lens;
/// the LETTER lens is `pr_ac_coverage`.
/// CREDIBLE-195 (CREDIBLE-191 slice 1): build the SPIRIT-judge prompt, GROUNDED so the lens
/// stops false-STUB-ing genuine minimal fixes. It gives the judge (a) the acceptance RESULT —
/// a change that made a real acceptance check PASS is strong evidence it is NOT a stub (a
/// minimal-but-correct fix is GENUINE, not STUB merely for being short); and (b) a fuller
/// INTENT (mode + the acceptance command, so the judge knows what "done" means, not just a
/// terse task line). Crucially, acceptance-PASS rules out STUB but NOT hack: a diff that passes
/// by hardcoding the expected answer or gaming the check is still a HACK — that lens stays sharp.
/// Pure (no I/O) so the grounding is unit-testable without the LLM gateway.
fn build_spirit_prompt(track: &Track, acceptance: Verdict, diff_excerpt: &str) -> String {
    let acc_str = match acceptance {
        Verdict::Pass => "PASS",
        Verdict::Fail => "FAIL",
        Verdict::Unknown => "UNKNOWN",
    };
    let acceptance_check = if track.acceptance.check.trim().is_empty() {
        "(none specified)"
    } else {
        track.acceptance.check.trim()
    };
    format!(
        "You are a strict senior engineer. Judge whether the DIFF genuinely achieves the \
         INTENT in SPIRIT, not just letter.\n\
         GROUNDING: an automated acceptance check for this task returned {acc_str}. A change that \
         makes a REAL acceptance check PASS is strong evidence it is NOT a stub — a minimal but \
         correct fix that passes acceptance is GENUINE; do NOT call a small correct change STUB \
         merely because it is short. BUT acceptance passing does NOT by itself prove genuineness: \
         if the diff passes by hardcoding the expected answer or gaming the check, that is a HACK.\n\
         Definitions: GENUINE = really does what the intent needs, cleanly. STUB = literally a \
         placeholder / no-op / 'add your code here' / empty / does nothing. HACK = games the check, \
         hardcodes the expected output, or is unidiomatic. PARTIAL = real but incomplete.\n\
         Reply EXACTLY one line:\n\
         VERDICT: <GENUINE|STUB|HACK|PARTIAL> - <reason in 15 words or fewer>\n\n\
         === INTENT ===\nmode: {mode}\ntask: {task}\nacceptance (what 'done' means): {acceptance_check}\n\n\
         === ACCEPTANCE RESULT ===\n{acc_str}\n\n=== DIFF ===\n{diff_excerpt}\n",
        mode = track.mode,
        task = track.task,
    )
}

fn spirit_judge(
    chump_bin: &str,
    track: &Track,
    acceptance: Verdict,
    dir: &Path,
) -> (String, String) {
    let cd = dir.to_string_lossy().to_string();
    // CREDIBLE-194: judge the LAP's real commit range, not `base_branch...HEAD`.
    // RESCUE/--implement laps commit onto the clone's OWN main, so base_branch resolves
    // to the same tip as HEAD and the three-dot diff is empty → "no diff to judge" on
    // exactly the laps that most need spirit judgment. lap_commit_range() (INFRA-3523,
    // base=origin/<default>..tip) is the range the touch-tally already uses correctly;
    // fall back to base...HEAD only if it can't resolve. Exclude the runtime junk the
    // agent tends to sweep into commits (session dbs, ambient log) so the lens judges
    // the real change, not the OS's own scratch state.
    let range = lap_commit_range(dir).unwrap_or_else(|| format!("{}...HEAD", base_branch(dir)));
    let diff = Command::new("git")
        .args([
            "-C",
            &cd,
            "diff",
            &range,
            "--",
            ".",
            ":(exclude)sessions/**",
            ":(exclude).chump-locks/**",
            ":(exclude)**/*.db",
            ":(exclude)**/*.db-shm",
            ":(exclude)**/*.db-wal",
        ])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let diff = diff.trim();
    if diff.is_empty() {
        return (String::new(), "no diff to judge".to_string());
    }
    let diff_excerpt: String = diff.chars().take(8000).collect();
    let prompt = build_spirit_prompt(track, acceptance, &diff_excerpt);
    let class = std::env::var("CHUMP_BENCH_SPIRIT_MODEL").unwrap_or_else(|_| "opus".to_string());
    let mut child = match Command::new(chump_bin)
        .args(["llm-complete", "--model", &class, "--max-tokens", "200"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return (String::new(), "spirit gateway unavailable".to_string()),
    };
    if let Some(mut si) = child.stdin.take() {
        use std::io::Write;
        let _ = si.write_all(prompt.as_bytes());
    }
    let out = match child.wait_with_output() {
        Ok(o) => o,
        Err(_) => return (String::new(), "spirit gateway error".to_string()),
    };
    parse_spirit_verdict(&String::from_utf8_lossy(&out.stdout))
}

/// CREDIBLE-192: parse the spirit judge's reply into (verdict, reason). Pure — unit-tested.
fn parse_spirit_verdict(resp: &str) -> (String, String) {
    for line in resp.lines() {
        let l = line.trim();
        if l.to_uppercase().starts_with("VERDICT:") {
            let rest = l[8..].trim();
            let rest_up = rest.to_uppercase();
            for v in ["GENUINE", "STUB", "HACK", "PARTIAL"] {
                if rest_up.starts_with(v) {
                    let reason = rest
                        .splitn(2, |c| c == '-' || c == '\u{2014}' || c == ':')
                        .nth(1)
                        .map(|s| s.trim().to_string())
                        .unwrap_or_default();
                    return (v.to_string(), reason);
                }
            }
        }
    }
    // Fallback: a bare keyword anywhere (worst = STUB/HACK, so check those first).
    let up = resp.to_uppercase();
    for v in ["STUB", "HACK", "PARTIAL", "GENUINE"] {
        if up.contains(v) {
            return (
                v.to_string(),
                "inferred from unstructured reply".to_string(),
            );
        }
    }
    (String::new(), "unparseable spirit reply".to_string())
}

/// A single CI check-run: its name, lifecycle status, and (once completed) conclusion.
#[derive(Debug, Clone)]
struct CheckRun {
    name: String,
    /// queued | in_progress | completed
    status: String,
    /// success | failure | neutral | cancelled | … | "" while not completed
    conclusion: String,
}

/// Fetch the check-runs for a repo ref (branch name or SHA) as name+status+conclusion.
/// None on gh/API failure; Some(empty) when the ref genuinely has no check-runs.
fn fetch_check_runs(repo: &str, git_ref: &str) -> Option<Vec<CheckRun>> {
    let out = Command::new(gh_bin())
        .args([
            "api",
            &format!("repos/{repo}/commits/{git_ref}/check-runs"),
            "--jq",
            ".check_runs[] | [.name, .status, (.conclusion // \"\")] | @tsv",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let mut v = Vec::new();
    for line in s.lines() {
        let mut it = line.splitn(3, '\t');
        let name = it.next().unwrap_or("").to_string();
        let status = it.next().unwrap_or("").to_string();
        let conclusion = it.next().unwrap_or("").to_string();
        if !name.is_empty() {
            v.push(CheckRun {
                name,
                status,
                conclusion,
            });
        }
    }
    Some(v)
}

/// CREDIBLE-186: grade a set of check-runs HONESTLY. The false-green that merged junk
/// to BEAST-MODE main came from grading a transient snapshot (2 fast checks green while
/// the real one hadn't run). This grader refuses that:
///   1. If ANY check is still running (status != completed) → Unknown (not settled yet).
///   2. If a `required_check` is named, it must be PRESENT and green — a missing one is
///      Unknown (hasn't reported), a failed one is Fail. This is the specific
///      previously-red check the lap is meant to turn green.
///   3. Only once everything is conclusive do we grade the whole set (Fail if any failed).
///
/// Pure — unit-tested.
fn grade_checks_strict(checks: &[CheckRun], required_check: &str) -> (Verdict, String) {
    let pending: Vec<&str> = checks
        .iter()
        .filter(|c| c.status != "completed")
        .map(|c| c.name.as_str())
        .collect();
    if !pending.is_empty() {
        return (
            Verdict::Unknown,
            format!(
                "{} check(s) still running (e.g. {})",
                pending.len(),
                pending.first().copied().unwrap_or("")
            ),
        );
    }
    if !required_check.is_empty() {
        match checks.iter().find(|c| c.name == required_check) {
            None => {
                return (
                    Verdict::Unknown,
                    format!("required check '{required_check}' has not reported yet"),
                )
            }
            Some(c) => match c.conclusion.as_str() {
                "success" | "neutral" | "skipped" => {}
                other => {
                    return (
                        Verdict::Fail,
                        format!("required check '{required_check}' = {other}"),
                    )
                }
            },
        }
    }
    let concls: Vec<String> = checks
        .iter()
        .map(|c| c.conclusion.clone())
        .filter(|s| !s.is_empty() && s != "null")
        .collect();
    if concls.is_empty() {
        return (Verdict::Unknown, "no conclusive checks".to_string());
    }
    let detail = if required_check.is_empty() {
        format!("{} check(s) conclusive", concls.len())
    } else {
        format!(
            "{} check(s) conclusive, required '{required_check}' green",
            concls.len()
        )
    };
    (grade_check_conclusions(&concls), detail)
}

/// Grade a `ci-green` acceptance on the repo's default branch — a single honest snapshot
/// (Unknown until settled). Callers that must WAIT for CI to settle use `await_ci_verdict`.
fn fetch_ci_verdict(repo: &str, required_check: &str) -> (Verdict, String) {
    let branch = Command::new(gh_bin())
        .args([
            "repo",
            "view",
            repo,
            "--json",
            "defaultBranchRef",
            "--jq",
            ".defaultBranchRef.name",
        ])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "main".to_string());
    match fetch_check_runs(repo, &branch) {
        Some(checks) if !checks.is_empty() => {
            let (v, detail) = grade_checks_strict(&checks, required_check);
            (v, format!("{detail} on {branch}"))
        }
        Some(_) => (
            Verdict::Unknown,
            format!("no check-runs on {branch} (may be PR-scoped)"),
        ),
        None => (Verdict::Unknown, "could not query CI via gh".to_string()),
    }
}

/// CREDIBLE-186: poll `fetch_ci_verdict` until it settles (Pass/Fail) or the budget
/// elapses. A ci-green acceptance must never grade a mid-run snapshot — an Unknown
/// (checks still running / required check not reported) means "keep waiting", not "fail".
/// Returns the last verdict on timeout (Unknown → the scorer honestly reports FAIL).
fn await_ci_verdict(repo: &str, required_check: &str, budget_secs: u64) -> (Verdict, String) {
    use std::time::{Duration, Instant};
    let deadline = Instant::now() + Duration::from_secs(budget_secs.max(1));
    loop {
        let last = fetch_ci_verdict(repo, required_check);
        if !matches!(last.0, Verdict::Unknown) {
            return last;
        }
        if Instant::now() >= deadline {
            return (
                last.0,
                format!("{} (CI did not settle within {budget_secs}s)", last.1),
            );
        }
        std::thread::sleep(Duration::from_secs(20));
    }
}

/// The clone's base branch name — the remote default the lap branched FROM. Mirrors
/// `improve.rs::detect_default_branch` (symbolic-ref origin/HEAD, then main/master), kept
/// self-contained so the bench runner compiles independently of the improve engine.
fn base_branch(clone: &Path) -> String {
    let cd = clone.to_string_lossy().to_string();
    if let Ok(out) = Command::new("git")
        .args([
            "-C",
            &cd,
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ])
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout)
                .trim()
                .trim_start_matches("origin/")
                .to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    for cand in ["main", "master"] {
        for r in [format!("origin/{cand}"), cand.to_string()] {
            let ok = Command::new("git")
                .args(["-C", &cd, "rev-parse", "--verify", "--quiet", &r])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                return cand.to_string();
            }
        }
    }
    "main".to_string()
}

/// Resolve a rev to a form `git log` accepts, preferring the remote ref over the local branch of
/// the same name (`origin/main` before `main`). Returns None if neither exists.
fn resolve_rev(clone: &Path, name: &str) -> Option<String> {
    let cd = clone.to_string_lossy().to_string();
    for r in [format!("origin/{name}"), name.to_string()] {
        let ok = Command::new("git")
            .args(["-C", &cd, "rev-parse", "--verify", "--quiet", &r])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            return Some(r);
        }
    }
    None
}

/// INFRA-3523: the range of commits the LAP itself produced, as a `base..tip` spec for `git log`.
///
/// The improve/rescue engine branches `chump/improve-<key>` off `origin/<default>` and commits the
/// lap's work there (the OS commit carries the `Chump-Agent:` trailer); the shared clone keeps that
/// branch after ship. So the lap's commits are exactly `base..<lap-branch>` — NOT the clone's whole
/// history. Counting `git log origin/HEAD -n50` (the old behavior) tallied the external repo's
/// entire pre-existing default-branch history as human touches (~50), which is the bug this fixes.
///
/// tip = the newest local `chump/*` lap branch if one exists, else HEAD. base = the remote default
/// branch. Returns None when the base can't be resolved (can't scope → caller reports "can't read").
fn lap_commit_range(clone: &Path) -> Option<String> {
    let cd = clone.to_string_lossy().to_string();
    let base = resolve_rev(clone, &base_branch(clone))?;

    // Prefer the lap's own branch (chump/*), newest first; the improve engine names it
    // chump/improve-<key> and leaves it in the clone after ship.
    let tip = Command::new("git")
        .args([
            "-C",
            &cd,
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads/chump/",
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(|s| s.trim().to_string())
                .find(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "HEAD".to_string());

    Some(format!("{base}..{tip}"))
}

/// Trailer-based provenance count over the commits in `range` (a `git log` revision range) of a
/// local clone: (human, zero_touch, scanned). A commit carrying `Chump-Agent:` is the OS's; one
/// lacking it (and not a bot) is a human touch (COTG-3.2). The range is scoped to the LAP's own
/// commits (INFRA-3523, see `lap_commit_range`) so the count is the lap's touches, not the clone's
/// entire history. Kept self-contained so the runner compiles independently of the CREDIBLE-171
/// metric; both share the same trailer rule and can be deduped once both land.
fn count_provenance(clone: &Path, range: &str) -> Option<(u64, u64, u64)> {
    let out = Command::new("git")
        .args([
            "-C",
            &clone.to_string_lossy(),
            "log",
            range,
            "-n50",
            "--format=%an%x1f%ae%x1f%b%x1e",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let (mut human, mut zt, mut scanned) = (0u64, 0u64, 0u64);
    for rec in text.split('\u{1e}') {
        let rec = rec.trim_matches(|c| c == '\n' || c == '\r');
        if rec.is_empty() {
            continue;
        }
        let f: Vec<&str> = rec.split('\u{1f}').collect();
        if f.len() < 3 {
            continue;
        }
        scanned += 1;
        if f[2].to_lowercase().contains("chump-agent:") {
            zt += 1;
        } else {
            let idl = format!("{} {}", f[0], f[1]).to_lowercase();
            if !(idl.contains("bot") || idl.contains("github-actions")) {
                human += 1;
            }
        }
    }
    Some((human, zt, scanned))
}

/// The local clone the external-improve flow leaves on disk for a repo (if any).
fn local_clone_dir(repo: &str) -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    // EFFECTIVE-343: sanitize BOTH '/' and ':' — a `bootstrap:<name>` pseudo-repo
    // otherwise leaves a colon in the path, and `python -m venv` (and other tools)
    // refuse to operate in a directory whose path contains the PATH separator.
    let slug = repo.replace(['/', ':'], "_");
    Path::new(&home)
        .join(".chump/external")
        .join(&slug)
        .join("clone")
}

/// Map a process exit code to a verdict: 0 → PASS, non-zero → FAIL, no code (killed / spawn
/// failure) → UNKNOWN. Pure + testable — the core of the `command` acceptance grader.
pub fn verdict_from_exit(code: Option<i32>) -> Verdict {
    match code {
        Some(0) => Verdict::Pass,
        Some(_) => Verdict::Fail,
        None => Verdict::Unknown,
    }
}

/// Recursively collect `.py` files under `dir`, skipping `.git` and common venv dirs — small,
/// bounded clones (bootstrap scaffolds), so no need for a walkdir dependency.
fn collect_py_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if matches!(
                name,
                ".git" | "venv" | ".venv" | "__pycache__" | "node_modules"
            ) {
                continue;
            }
            collect_py_files(&path, out);
        } else if path.extension().is_some_and(|x| x == "py") {
            out.push(path);
        }
    }
}

/// EFFECTIVE-351: fail fast on a syntactically-invalid artifact, before spending time on the
/// (often much slower) acceptance `check:` command — and feed the parser error back in the
/// score detail. Guards the tool-storm-truncation failure mode seen 2026-08-02: an agent
/// aborted mid-write during a git_commit storm and shipped rename_photos.py with an unclosed
/// `print(` paren, which the pytest/venv acceptance command couldn't distinguish from a real
/// test failure. Only applies to `stack: python` tracks; other stacks return None (no-op).
fn syntax_precheck(stack: &str, cwd: &Path) -> Option<(Verdict, String)> {
    if !stack.eq_ignore_ascii_case("python") {
        return None;
    }
    let mut py_files = Vec::new();
    collect_py_files(cwd, &mut py_files);
    py_files.sort();
    for file in &py_files {
        let output = Command::new("python3")
            .arg("-m")
            .arg("py_compile")
            .arg(file)
            .output();
        match output {
            Ok(o) if !o.status.success() => {
                let err: String = String::from_utf8_lossy(&o.stderr)
                    .lines()
                    .last()
                    .unwrap_or("")
                    .chars()
                    .take(200)
                    .collect();
                let rel = file.strip_prefix(cwd).unwrap_or(file).display();
                return Some((
                    Verdict::Fail,
                    format!("syntax pre-check failed: {rel}: {err}"),
                ));
            }
            // Ok(status success) => keep checking remaining files.
            // Err(_) => python3 unavailable — don't block scoring on a missing interpreter,
            // fall through to the acceptance command as before.
            _ => {}
        }
    }
    None
}

/// Grade a `command` acceptance: run the track's `check` as a shell command in `cwd` (the repo's
/// local clone). PASS iff it exits 0. These commands come from OUR own in-repo track YAMLs — a
/// test harness, not untrusted input. UNKNOWN if there's no clone to run in (drive a lap first).
fn grade_command(check: &str, cwd: Option<&Path>) -> (Verdict, String) {
    let Some(dir) = cwd else {
        return (
            Verdict::Unknown,
            "no local clone to run the acceptance command in (drive an --apply lap first)"
                .to_string(),
        );
    };
    if check.trim().is_empty() {
        return (
            Verdict::Unknown,
            "track has no acceptance command".to_string(),
        );
    }
    match Command::new("sh")
        .arg("-c")
        .arg(check)
        .current_dir(dir)
        .output()
    {
        Ok(o) => {
            let v = verdict_from_exit(o.status.code());
            let tail: String = String::from_utf8_lossy(&o.stderr)
                .lines()
                .last()
                .unwrap_or("")
                .chars()
                .take(80)
                .collect();
            let cmd: String = check.chars().take(60).collect();
            let suffix = if tail.is_empty() {
                String::new()
            } else {
                format!(" — {tail}")
            };
            (v, format!("`{cmd}` exit {:?}{suffix}", o.status.code()))
        }
        Err(e) => (
            Verdict::Unknown,
            format!("could not run acceptance command: {e}"),
        ),
    }
}

/// Best-effort human-touch tally for `repo` from a local clone the improve flow left on disk;
/// otherwise None (a driven `--apply` lap produces the count).
fn tally_human_touches(repo: &str) -> (Option<u64>, String) {
    let clone = local_clone_dir(repo);
    if !clone.join(".git").exists() {
        return (
            None,
            "n/a — no local clone (a driven --apply lap produces the touch count)".to_string(),
        );
    }
    // CREDIBLE-183: a CREATE lap (bootstrap:*) is a FRESH repo — there's no base
    // branch to diff against; the whole history IS the lap (the scaffold + the
    // implement commit, both OS-authored, Chump-Agent-trailed). Count over full
    // history. For IMPROVE/RESCUE clones keep the INFRA-3523 base..lap-branch
    // scoping so we don't count the clone's entire upstream history.
    let range = if repo.starts_with("bootstrap:") {
        "HEAD".to_string()
    } else {
        match lap_commit_range(&clone) {
            Some(r) => r,
            None => {
                return (
                    None,
                    "n/a — could not resolve the lap's commit range in local clone".to_string(),
                );
            }
        }
    };
    match count_provenance(&clone, &range) {
        Some((human, zt, scanned)) if scanned > 0 => {
            let ratio = zt as f64 / scanned as f64 * 100.0;
            (
                Some(human),
                format!("{human} human / {zt} zero-touch of {scanned} lap commit(s) ({ratio:.0}% zero-touch) in local clone"),
            )
        }
        Some(_) => (
            None,
            "n/a — no lap commits in local clone (base..lap-branch is empty)".to_string(),
        ),
        None => (
            None,
            "n/a — could not read local clone provenance".to_string(),
        ),
    }
}

/// Load a track from a YAML file.
pub fn load_track(path: &Path) -> Result<Track> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading track {}", path.display()))?;
    serde_yaml::from_str(&text).with_context(|| format!("parsing track {}", path.display()))
}

/// EFFECTIVE-345: task-directed execution for an EXISTING repo. Clone the repo
/// into the dir the scorer runs acceptance in, run `agent-run --slim` with the
/// TRACK's task — so the agent does the *specific* task, not the repo's own gaps
/// (which is what generic `chump improve` would work) — then commit its output
/// with a Chump-Agent trailer so the touch tally proves zero-touch. This is the
/// CREATE `--implement` pattern, but on an existing repo; it's what lets the
/// IMPROVE/FINISH/COMPREHEND tracks satisfy their task-specific acceptance.
/// EFFECTIVE-348: map a track's declared `difficulty` to a preferred model class,
/// then stamp the cascade-routing env onto an `agent-run` command so bench laps use
/// the right model for the task instead of whatever the bandit drifts to. The 5 easy
/// greens proved 70B-class (sonnet) is plenty for straightforward tasks; the rescue /
/// CI-debug class flails on 70Bs and needs the opus pool (Qwen3-Coder-480B / Gemini-Pro
/// / NVIDIA). Only laps with a recognised difficulty escalate; unknown → leave the
/// cascade on its default so nothing regresses. Bench targets are Jeff's test repos
/// (not proprietary), so we open privacy to `trains` here to make the full opus pool
/// reachable — this env is scoped to the child agent-run, never the fleet's own rounds.
fn model_class_for_difficulty(difficulty: &str) -> Option<&'static str> {
    match difficulty.trim().to_lowercase().as_str() {
        "tiny" | "easy" => Some("sonnet"),
        "medium" | "hard" | "difficult" => Some("opus"),
        _ => None,
    }
}

fn apply_difficulty_routing(cmd: &mut Command, track: &Track) {
    if let Some(class) = model_class_for_difficulty(&track.difficulty) {
        eprintln!(
            "[bench] difficulty={} → preferred model class '{}' (opus pool for hard laps)",
            track.difficulty, class
        );
        cmd.env("CHUMP_PREFERRED_MODEL_CLASS", class)
            // Test repos: allow the full pool so opus slots (incl. trains-tier) are eligible.
            .env("CHUMP_ROUND_PRIVACY", "trains")
            .env("CHUMP_AUTO_PRIVACY", "0");
    }
}

/// EFFECTIVE-349: fetch the tail of the most-recent FAILED run's log for a repo so a
/// RESCUE agent can diagnose the real root cause instead of guessing blind (the blind
/// guess produced placeholder stub files that false-greened). Prefers a run whose name
/// or workflow matches `required_check`; falls back to the most recent failure. Returns
/// the last `max_chars` of the failed-step log (the error is usually at the end), or
/// None if nothing can be retrieved.
fn fetch_failure_log(repo: &str, required_check: &str, max_chars: usize) -> Option<String> {
    let gh = gh_bin();
    let out = Command::new(&gh)
        .args([
            "run",
            "list",
            "--repo",
            repo,
            "--status",
            "failure",
            "--limit",
            "20",
            "--json",
            "databaseId,name,workflowName",
            "--jq",
            ".[] | [.databaseId, .name, .workflowName] | @tsv",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let want = required_check.trim().to_lowercase();
    let listing = String::from_utf8_lossy(&out.stdout);
    let mut first: Option<String> = None;
    let mut matched: Option<String> = None;
    for line in listing.lines() {
        let mut it = line.splitn(3, '\t');
        let id = it.next().unwrap_or("").trim().to_string();
        let name = it.next().unwrap_or("").to_lowercase();
        let wf = it.next().unwrap_or("").to_lowercase();
        if id.is_empty() {
            continue;
        }
        if first.is_none() {
            first = Some(id.clone());
        }
        if !want.is_empty() && (name.contains(&want) || wf.contains(&want)) {
            matched = Some(id);
            break;
        }
    }
    let run_id = matched.or(first)?;
    let log = Command::new(&gh)
        .args(["run", "view", &run_id, "--repo", repo, "--log-failed"])
        .output()
        .ok()?;
    if !log.status.success() {
        return None;
    }
    let full = String::from_utf8_lossy(&log.stdout);
    let full = full.trim();
    if full.is_empty() {
        return None;
    }
    Some(tail_to_chars(full, max_chars))
}

/// EFFECTIVE-349: keep the last `max_chars` of `s` (the CI error is usually at the end),
/// on a UTF-8 char boundary, with a truncation marker. Pure — unit-tested.
fn tail_to_chars(s: &str, max_chars: usize) -> String {
    if s.len() <= max_chars {
        return s.to_string();
    }
    let mut start = s.len() - max_chars;
    while start < s.len() && !s.is_char_boundary(start) {
        start += 1;
    }
    format!(
        "…(log truncated to last {max_chars} chars)…\n{}",
        &s[start..]
    )
}

/// CREDIBLE-190: parse the captured task-directed agent-run output (a `.bench-agent-output.log`
/// beside the clone) for effort signals the scorecard was blind to — how many tools the agent
/// invoked, and whether it exhausted its max-iteration budget WITHOUT terminating (the flail
/// where the agent produced the fix but couldn't recognize it was done and kept rewriting).
/// Returns (0, false) when there's no capture (e.g. a non-`--implement` lap). Pure read.
fn parse_agent_effort(clone_dir: &Path) -> (u64, bool) {
    let capture = clone_dir
        .parent()
        .unwrap_or(clone_dir)
        .join(".bench-agent-output.log");
    match std::fs::read_to_string(&capture) {
        Ok(text) => (
            text.matches("Executing tool:").count() as u64,
            text.contains("Exceeded max iterations"),
        ),
        Err(_) => (0, false),
    }
}

/// EFFECTIVE-352: the task-directed `--implement` prompt, with an explicit STOP-WHEN-DONE
/// instruction. Without it the agent produced the correct fix early but kept re-writing to
/// "double-check", looping to its iteration cap (the 1909s / 26-write flail CREDIBLE-190 made
/// legible). Pure so the nudge is unit-testable without spawning an agent.
fn build_implement_prompt(task: &str, comprehension: &str) -> String {
    format!(
        "{task}{comprehension}\n\nYou are working in an existing repository (your current \
         directory). Make the change directly — edit or create the necessary files so the task \
         is complete. Do not ask questions; implement fully.\n\n\
         STOP WHEN DONE: make the MINIMAL change that completes the task, then STOP. Do NOT \
         re-write files you already wrote to 'double-check', do not re-verify by rewriting, and \
         do not keep polishing. Once the necessary files are written you are finished — end your \
         turn."
    )
}

fn drive_task_directed(chump: &str, track: &Track) -> Result<Option<(Verdict, String)>> {
    let dir = local_clone_dir(&track.repo);
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    // Fresh clone each lap.
    let _ = std::fs::remove_dir_all(&dir);
    let dir_str = dir.to_string_lossy().into_owned();
    eprintln!("[bench] cloning {} for a task-directed lap …", track.repo);
    // `gh repo clone` so private repos authenticate; shallow for speed.
    let clone = Command::new("gh")
        .args(["repo", "clone", &track.repo, &dir_str, "--", "--depth", "1"])
        .status()
        .with_context(|| "spawn gh repo clone")?;
    if !clone.success() {
        anyhow::bail!("gh repo clone {} failed", track.repo);
    }
    // CREDIBLE-187: seed a deterministic breakage the lap will rescue. Runs in the
    // clone BEFORE the agent; committed so it's part of the repo state the agent must
    // fix. Self-contained + repeatable, and never touches the target's main.
    if !track.seed_break.trim().is_empty() {
        eprintln!("[bench] CREDIBLE-187: seeding breakage …");
        let seeded = Command::new("sh")
            .args(["-c", &track.seed_break])
            .current_dir(&dir)
            .status();
        match seeded {
            Ok(s) if s.success() => {
                let _ = Command::new("git")
                    .args(["-C", &dir_str, "add", "-A"])
                    .status();
                let _ = Command::new("git")
                    .args([
                        "-C",
                        &dir_str,
                        "-c",
                        "gpg.sign=false",
                        "commit",
                        "-m",
                        // CREDIBLE-187: the seed is the BENCH setting up the scenario,
                        // not a human reaching into the fix — mark it OS-authored so the
                        // zero-touch tally doesn't miscount it as a human touch.
                        "chore: seed breakage for ChumpBench RESCUE lap\n\nChump-Agent: bench-seed",
                        "--no-verify",
                    ])
                    .status();
            }
            other => eprintln!("[bench] seed_break did not succeed ({other:?}) — continuing"),
        }
    }
    // EFFECTIVE-349: comprehension-before-action. For a RESCUE lap, hand the agent the
    // actual CI failure log + a pointer at where CI bugs live, so it fixes the real root
    // cause instead of guessing blind (the blind guess wrote placeholder stubs that
    // false-greened). Explicitly forbid the stub/placeholder failure mode we observed.
    let mut comprehension = String::new();
    if track.mode.eq_ignore_ascii_case("RESCUE") {
        if track.acceptance.kind.eq_ignore_ascii_case("command")
            && !track.acceptance.check.trim().is_empty()
        {
            // CREDIBLE-187: a command-acceptance RESCUE — run the verification command in
            // the clone, capture its failure output, and hand THAT to the agent. Concrete,
            // deterministic evidence of what is broken (no dependence on a live CI check).
            let out = Command::new("sh")
                .args(["-c", &track.acceptance.check])
                .current_dir(&dir)
                .output();
            if let Ok(o) = out {
                let mut combined = String::from_utf8_lossy(&o.stdout).into_owned();
                combined.push_str(&String::from_utf8_lossy(&o.stderr));
                let tail = tail_to_chars(combined.trim(), 4000);
                eprintln!(
                    "[bench] CREDIBLE-187: attached {}-char command-failure output",
                    tail.len()
                );
                comprehension = format!(
                    "\n\nThe verification command `{}` is currently FAILING in this repo. \
                     Its output is below — diagnose the ROOT CAUSE from it and fix the code \
                     so the command exits 0. Do NOT create placeholder, stub, or \"add your \
                     code here\" files, and do NOT edit the verification command itself — fix \
                     the actual bug.\n=== COMMAND OUTPUT ===\n{}\n=== END OUTPUT ===",
                    track.acceptance.check,
                    if tail.is_empty() {
                        "(no output)"
                    } else {
                        &tail
                    }
                );
            }
        } else {
            let rc = track.acceptance.required_check.trim();
            let label = if rc.is_empty() {
                "the failing check"
            } else {
                rc
            };
            match fetch_failure_log(&track.repo, rc, 4000) {
                Some(log) => {
                    eprintln!(
                        "[bench] EFFECTIVE-349: attached {}-char failure log for '{label}'",
                        log.len()
                    );
                    comprehension = format!(
                        "\n\nThe failing CI check is '{label}'. Its most recent failure log \
                         (tail) is below — diagnose the ROOT CAUSE from it. A failing CI check \
                         is almost always caused by a workflow or config file (look first under \
                         .github/workflows/ and at build/lock/config files), NOT the application \
                         code. Fix the actual cause. Do NOT create placeholder, stub, or \
                         \"add your code here\" files — that does not fix anything.\n\
                         === FAILURE LOG (tail) ===\n{log}\n=== END LOG ==="
                    );
                }
                None => eprintln!(
                    "[bench] EFFECTIVE-349: no failure log retrieved for '{label}' — proceeding without it"
                ),
            }
        }
    }
    // The agent gets the TASK (not the acceptance command) and works in the clone.
    let prompt = build_implement_prompt(&track.task, &comprehension);
    // Prompt lives OUTSIDE the clone so the agent doesn't treat it as a repo file.
    let prompt_path = dir
        .parent()
        .unwrap_or(dir.as_path())
        .join(".bench-task-prompt.txt");
    std::fs::write(&prompt_path, &prompt).with_context(|| "write task prompt")?;
    let prompt_str = prompt_path.to_string_lossy().into_owned();
    eprintln!(
        "[bench] task-directed agent-run on {} (can take minutes) …",
        track.repo
    );
    let mut cmd = Command::new(chump);
    cmd.args([
        "agent-run",
        "--slim",
        "--cwd",
        &dir_str,
        "--prompt-file",
        &prompt_str,
    ])
    // CREATE builds new files; existing-repo tasks may too — re-admit
    // write_file (with its shrink guard) so the agent can create files.
    .env("CHUMP_FREE_TIER_WRITE_FILE", "1");
    apply_difficulty_routing(&mut cmd, track);
    // CREDIBLE-190: capture the agent-run output beside the clone so the scorecard can
    // surface tool-call count + whether the agent exhausted its iteration budget (the
    // 1909s/26-write flail). Redirected to a file (not inherited) so it's parseable;
    // watch it live with `tail -f`. On any capture-setup failure, fall back to inherited
    // stdio so a lap never fails just because we couldn't observe it.
    let capture_path = dir
        .parent()
        .unwrap_or(dir.as_path())
        .join(".bench-agent-output.log");
    match std::fs::File::create(&capture_path) {
        Ok(f) => {
            eprintln!(
                "[bench] agent-run output → {} (tail -f to watch)",
                capture_path.display()
            );
            if let Ok(f2) = f.try_clone() {
                cmd.stdout(std::process::Stdio::from(f))
                    .stderr(std::process::Stdio::from(f2));
            }
        }
        Err(e) => {
            eprintln!("[bench] could not capture agent-run output ({e}) — effort will read 0")
        }
    }
    let status = cmd.status();
    let _ = std::fs::remove_file(&prompt_path);
    match status {
        Ok(s) if s.success() => eprintln!("[bench] task-directed step completed"),
        Ok(s) => eprintln!(
            "[bench] task-directed step exited non-zero ({:?}) — scoring current state",
            s.code()
        ),
        Err(e) => {
            eprintln!("[bench] task-directed step failed to spawn: {e} — scoring current state")
        }
    }
    // Capture the agent's output as an OS-authored commit (CREDIBLE-183) so the
    // touch tally can prove zero-touch.
    let _ = Command::new("git")
        .args(["-C", &dir_str, "add", "-A"])
        .status();
    let has_changes = Command::new("git")
        .args(["-C", &dir_str, "diff", "--cached", "--quiet"])
        .status()
        .map(|s| !s.success())
        .unwrap_or(false);
    if has_changes {
        let _ = Command::new("git")
            .args([
                "-C",
                &dir_str,
                "-c",
                "gpg.sign=false",
                "commit",
                "-m",
                "feat: implement track task\n\nChump-Agent: bench-implement",
                "--no-verify",
            ])
            .status();
    }
    // EFFECTIVE-350: a RESCUE lap scores on PR-GREEN by default — open a PR with the
    // fix and check whether the previously-red `required_check` goes green ON THE PR.
    // Nothing merges to the target's main unless the operator opts in
    // (CHUMP_BENCH_SHIP=1) AND the fix is green (the pre-merge gate). This is what
    // makes the lap safe + repeatable: the proof is "the fix passes CI", not "we
    // merged to someone's main". Returns the PR-green verdict as the lap's acceptance.
    // CREDIBLE-187: only the ci-green flavor ships a PR (its acceptance grades live CI).
    // A `command`-acceptance RESCUE is scored LOCALLY in the clone (grade_command) — no
    // PR, fully deterministic — so we fall through to Ok(None) and let score_track run it.
    if has_changes
        && track.mode.eq_ignore_ascii_case("RESCUE")
        && track.repo.contains('/')
        && track.acceptance.kind.eq_ignore_ascii_case("ci-green")
    {
        let budget_min = if track.budget.max_wall_clock_min == 0 {
            20
        } else {
            track.budget.max_wall_clock_min
        };
        match rescue_ship_and_score(
            &track.repo,
            &dir_str,
            &track.acceptance.required_check,
            budget_min,
        ) {
            Ok(verdict) => return Ok(Some(verdict)),
            Err(e) => {
                eprintln!("[bench] rescue PR/score failed: {e} — falling back to current state");
                return Ok(None);
            }
        }
    }
    Ok(None)
}

/// EFFECTIVE-346: branch name for a shipped RESCUE fix. Deterministic from the fix
/// commit's short SHA so re-runs of the same fix reuse the branch (idempotent push)
/// and distinct fixes get distinct branches. Pure — unit-tested.
fn rescue_branch_name(sha: &str) -> String {
    let clean: String = sha
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(12)
        .collect();
    let clean = if clean.is_empty() {
        "fix".to_string()
    } else {
        clean
    };
    format!("chump/bench-rescue-{clean}")
}

/// EFFECTIVE-350: what to do with the rescue PR after scoring it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RescueDisposition {
    /// Land the fix on main — only when the operator opted in AND the fix is green.
    Merge,
    /// Close the proof PR — the default: we scored on PR-green without touching main.
    Close,
}

/// EFFECTIVE-350: decide the PR's fate. Default is PR-green scoring: open a PR, check
/// whether it turns the required check green, then CLOSE it (nothing lands on main, so
/// nothing can be polluted). Only merge to main when the operator explicitly opted in
/// (CHUMP_BENCH_SHIP=1) AND the fix is actually green on the PR — the pre-merge gate
/// that makes the junk-to-main class impossible. Pure — unit-tested.
fn rescue_disposition(verdict: Verdict, ship_opt_in: bool) -> RescueDisposition {
    if ship_opt_in && verdict == Verdict::Pass {
        RescueDisposition::Merge
    } else {
        RescueDisposition::Close
    }
}

/// EFFECTIVE-350: push the RESCUE fix, open a PR, and score on **PR-green** — poll the
/// PR's OWN checks until the previously-red `required_check` settles (green/red), using
/// the same honest grader as main. Returns that verdict as the lap's acceptance.
///
/// The PR is the proof surface, not a merge: by default we CLOSE it after scoring, so
/// nothing lands on the target's main (the pollution class is gone). Only when the
/// operator opts in (CHUMP_BENCH_SHIP=1) AND the fix is green do we merge it — the
/// pre-merge gate. Bounded by the track's wall-clock budget.
fn rescue_ship_and_score(
    repo: &str,
    dir_str: &str,
    required_check: &str,
    budget_min: u64,
) -> Result<(Verdict, String)> {
    use std::time::{Duration, Instant};
    let gh = gh_bin();
    let ship_opt_in = std::env::var("CHUMP_BENCH_SHIP").ok().as_deref() == Some("1");
    let base = Command::new(&gh)
        .args([
            "repo",
            "view",
            repo,
            "--json",
            "defaultBranchRef",
            "--jq",
            ".defaultBranchRef.name",
        ])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "main".to_string());
    let sha = Command::new("git")
        .args(["-C", dir_str, "rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "fix".to_string());
    let branch = rescue_branch_name(&sha);
    eprintln!("[bench] opening rescue PR on {repo} from branch {branch} (base {base}) …");
    let push = Command::new("git")
        .args([
            "-C",
            dir_str,
            "push",
            "origin",
            &format!("HEAD:refs/heads/{branch}"),
        ])
        .status()
        .with_context(|| "git push rescue branch")?;
    if !push.success() {
        anyhow::bail!("push of rescue branch {branch} failed");
    }
    let pr = Command::new(&gh)
        .args([
            "pr",
            "create",
            "--repo",
            repo,
            "--base",
            &base,
            "--head",
            &branch,
            "--title",
            "fix: rescue red CI (ChumpBench RESCUE lap)",
            "--body",
            "Autonomous RESCUE lap fix produced by ChumpBench.\n\nChump-Agent: bench-rescue",
        ])
        .output()
        .with_context(|| "gh pr create")?;
    if pr.status.success() {
        eprintln!(
            "[bench] opened PR {}",
            String::from_utf8_lossy(&pr.stdout).trim()
        );
    } else {
        let err = String::from_utf8_lossy(&pr.stderr);
        if !err.contains("already exists") {
            anyhow::bail!("gh pr create failed: {err}");
        }
        eprintln!("[bench] PR for {branch} already exists — reusing");
    }
    // Score on PR-green: poll the PR's OWN head checks until the required check settles.
    let deadline = Instant::now() + Duration::from_secs(budget_min.saturating_mul(60).max(60));
    let mut last = (Verdict::Unknown, "no PR checks observed".to_string());
    loop {
        let head = Command::new(&gh)
            .args([
                "pr",
                "view",
                &branch,
                "--repo",
                repo,
                "--json",
                "headRefOid",
                "--jq",
                ".headRefOid",
            ])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty());
        if let Some(head_sha) = head {
            let (v, detail) = match fetch_check_runs(repo, &head_sha) {
                Some(c) if !c.is_empty() => grade_checks_strict(&c, required_check),
                _ => (Verdict::Unknown, "no PR checks yet".to_string()),
            };
            eprintln!("[bench] rescue PR checks: {detail}");
            last = (v, detail);
            if !matches!(v, Verdict::Unknown) {
                break;
            }
        }
        if Instant::now() >= deadline {
            eprintln!("[bench] rescue PR budget ({budget_min}m) exhausted before checks settled");
            break;
        }
        std::thread::sleep(Duration::from_secs(20));
    }
    // Dispose of the proof PR: merge only on opt-in + green, else close (main untouched).
    match rescue_disposition(last.0, ship_opt_in) {
        RescueDisposition::Merge => {
            eprintln!("[bench] CHUMP_BENCH_SHIP=1 + green → merging rescue PR to {base}");
            merge_rescue_pr(&gh, &branch, repo);
        }
        RescueDisposition::Close => {
            eprintln!("[bench] scored on PR-green — closing proof PR (main untouched)");
            let _ = Command::new(&gh)
                .args([
                    "pr",
                    "close",
                    &branch,
                    "--repo",
                    repo,
                    "--delete-branch",
                    "--comment",
                    "ChumpBench RESCUE lap: scored on PR-green; closing (no merge). \
                     Set CHUMP_BENCH_SHIP=1 to land the fix.",
                ])
                .status();
        }
    }
    Ok(last)
}

/// A single publish destination for an artifact type — EFFECTIVE-477 (EFFECTIVE-364 slice).
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PublishTarget {
    pub target_type: String,
    pub platform_id: String,
    pub requires_approval: bool,
}

/// Path to the publish-target registry config. Honors `CHUMP_PUBLISH_TARGETS_PATH`,
/// else falls back to `publish_targets.json` next to this crate's manifest — reading
/// at runtime (not `include_str!`) so editing the file + restarting the binary picks
/// up new targets with no code changes (AC 3).
fn publish_targets_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_PUBLISH_TARGETS_PATH") {
        return PathBuf::from(p);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("publish_targets.json")
}

/// Look up the publish targets registered for `artifact_type` in `publish_targets.json`.
/// Returns an empty list for an unregistered artifact type or missing/malformed config —
/// callers (e.g. `drive_engine`) can call this unconditionally without a panic risk.
pub fn get_publish_targets(artifact_type: &str) -> Vec<PublishTarget> {
    let path = publish_targets_path();
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(registry) =
        serde_json::from_str::<std::collections::HashMap<String, Vec<PublishTarget>>>(&raw)
    else {
        return Vec::new();
    };
    registry.get(artifact_type).cloned().unwrap_or_default()
}

/// Drive the track's mode engine (only on `--apply`). Wires RESCUE/IMPROVE/FINISH →
/// `chump improve` (or, on `--implement`, task-directed `agent-run`, EFFECTIVE-345),
/// CREATE → `chump bootstrap`, COMPREHEND → the `comprehend` engine (or task-directed
/// on `--implement`). On `implement` (EFFECTIVE-341/345), drives `chump agent-run` so
/// the lap does the track's actual task, not just a scaffold or a generic gap.
fn drive_engine(track: &Track, implement: bool) -> Result<Option<(Verdict, String)>> {
    let chump = std::env::var("CHUMP_BENCH_CHUMP_BIN")
        .or_else(|_| std::env::var("CHUMP_BIN"))
        .unwrap_or_else(|_| "chump".to_string());
    match track.mode.to_uppercase().as_str() {
        // FINISH (complete a half-built repo) shares the improve engine: pointing
        // `chump improve` at an existing clone drives the agent to work the repo
        // toward green — which is exactly "wire the stubbed endpoint + make its
        // test pass" (EFFECTIVE-340). RESCUE (fix broken CI) and IMPROVE (add a
        // feature) are the same operation with different intent.
        "RESCUE" | "IMPROVE" | "FINISH" => {
            // EFFECTIVE-345: --implement runs the TRACK's task on a fresh clone
            // via agent-run (so the acceptance can actually be satisfied). Plain
            // --apply keeps the generic improve engine (works the repo's own gaps).
            if implement {
                return drive_task_directed(&chump, track);
            }
            let status = Command::new(&chump)
                .args(["improve", &track.repo, "--apply"])
                .status()
                .with_context(|| "spawn chump improve")?;
            if !status.success() {
                anyhow::bail!("engine `chump improve {}` exited non-zero", track.repo);
            }
            Ok(None)
        }
        "CREATE" => {
            // CREATE tracks carry a `bootstrap:<name>` pseudo-repo — the lap
            // creates the project from the plain-language `task`. Drive the
            // create engine: `chump bootstrap` scaffolds the project (git init +
            // manifest + first commit; the bench passes --no-umbrella-gap) into
            // the same dir the scorer runs the acceptance command in.
            //
            // EFFECTIVE-335 v1: bootstrap SCAFFOLDS but does not IMPLEMENT the
            // tool, so a track whose acceptance runs the generated program will
            // honestly score FAIL post-scaffold — surfacing "implement-after-
            // bootstrap" as the next CREATE layer (a follow-up wires
            // bootstrap → implement so acceptance can pass zero-touch).
            let dir = local_clone_dir(&track.repo);
            if let Some(parent) = dir.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("mkdir {}", parent.display()))?;
            }
            // Bootstrap wants a fresh dir — clear any prior lap's output.
            let _ = std::fs::remove_dir_all(&dir);
            let dir_str = dir.to_string_lossy().into_owned();
            // EFFECTIVE-339: honor the track's stack so the scaffold language
            // matches the acceptance command (e.g. stack: python → a python
            // scaffold, not the Rust default). Unknown/empty stacks fall through
            // to bootstrap's Rust default.
            let template = match track.stack.to_lowercase().as_str() {
                "python" | "py" => Some("python"),
                "node" | "javascript" | "typescript" | "js" | "ts" => Some("node"),
                "rust" | "rs" => Some("rust"),
                _ => None,
            };
            let mut args: Vec<&str> = vec!["bootstrap", track.task.as_str(), "--dir", &dir_str];
            if let Some(t) = template {
                args.push("--template");
                args.push(t);
            }
            // Bench harness flags: no LLM arch decision, and --no-umbrella-gap so
            // repeated laps don't flood the canonical registry with one
            // `Bootstrap: <task>` gap each (EFFECTIVE-339).
            args.push("--skip-arch-decision");
            args.push("--no-umbrella-gap");
            let status = Command::new(&chump)
                .args(&args)
                .status()
                .with_context(|| "spawn chump bootstrap")?;
            if !status.success() {
                anyhow::bail!(
                    "engine `chump bootstrap` exited non-zero for {}",
                    track.repo
                );
            }
            // EFFECTIVE-341: implement-after-bootstrap. Bootstrap only scaffolds;
            // on --implement, drive the coding agent to actually BUILD the tool
            // from the vision so a CREATE lap can pass zero-touch. The agent gets
            // the TASK, NOT the acceptance command — feeding it the grader would
            // be teaching to the test. `agent-run` roots its file tools at --cwd,
            // so edits land in the same scaffold dir the scorer runs acceptance
            // in. A failed/soft implement must NOT fail the drive — we score
            // whatever state the agent left (honest partial).
            if implement {
                let prompt = format!(
                    "{}\n\nThe project is scaffolded in this directory. Implement it \
                     fully so it works end to end: write all necessary source files \
                     and make it runnable from this directory. Do not ask questions — \
                     implement completely.",
                    track.task
                );
                // Write the prompt OUTSIDE the scored clone dir so the agent does
                // not treat it as a project file.
                let prompt_path = dir
                    .parent()
                    .unwrap_or(dir.as_path())
                    .join(".bench-implement-prompt.txt");
                if let Err(e) = std::fs::write(&prompt_path, &prompt) {
                    eprintln!(
                        "[bench] implement: could not write prompt file: {e} — skipping implement"
                    );
                } else {
                    eprintln!(
                        "[bench] implementing {} via agent-run (can take minutes) …",
                        track.repo
                    );
                    let prompt_str = prompt_path.to_string_lossy().into_owned();
                    let mut cmd = Command::new(&chump);
                    // --slim: the free-tier writer profile (EFFECTIVE-342) so
                    // the agent actually WRITES the tool instead of returning
                    // it as text.
                    cmd.args([
                        "agent-run",
                        "--slim",
                        "--cwd",
                        &dir_str,
                        "--prompt-file",
                        &prompt_str,
                    ])
                    // CREATE builds NEW files from scratch. The slim profile
                    // ships patch_file (edit existing) but not write_file, which
                    // patch_file can't substitute for — patching a nonexistent
                    // file fails and the model storms. Re-admit write_file (with
                    // its >50%-shrink guard) so the agent can CREATE the tool.
                    .env("CHUMP_FREE_TIER_WRITE_FILE", "1");
                    apply_difficulty_routing(&mut cmd, track);
                    match cmd.status() {
                        Ok(s) if s.success() => eprintln!("[bench] implement step completed"),
                        Ok(s) => eprintln!(
                            "[bench] implement step exited non-zero ({:?}) — scoring current state",
                            s.code()
                        ),
                        Err(e) => eprintln!(
                            "[bench] implement step failed to spawn: {e} — scoring current state"
                        ),
                    }
                    let _ = std::fs::remove_file(&prompt_path);
                }
                // CREDIBLE-183: capture the agent's working-tree output as an
                // OS-authored commit. The implement agent often leaves files
                // uncommitted (write_file without git_commit); without this its
                // work is invisible to count_provenance and the zero-touch tally
                // reports n/a instead of a provable 0.
                let cd = dir.to_string_lossy().to_string();
                let _ = Command::new("git").args(["-C", &cd, "add", "-A"]).status();
                let has_changes = Command::new("git")
                    .args(["-C", &cd, "diff", "--cached", "--quiet"])
                    .status()
                    .map(|s| !s.success()) // non-zero exit ⇒ staged differences exist
                    .unwrap_or(false);
                if has_changes {
                    let _ = Command::new("git")
                        .args([
                            "-C",
                            &cd,
                            "-c",
                            "gpg.sign=false",
                            "commit",
                            "-m",
                            "feat: implement from vision\n\nChump-Agent: bench-implement",
                            "--no-verify",
                        ])
                        .status();
                }
            }
            Ok(None)
        }
        "COMPREHEND" => {
            // EFFECTIVE-345: --implement runs the TRACK's task on a fresh clone
            // (e.g. "produce docs/ONBOARDING_MAP.md") so the agent WRITES the
            // deliverable the acceptance checks for. Plain --apply keeps the
            // read-only comprehend engine (reports, doesn't write).
            if implement {
                return drive_task_directed(&chump, track);
            }
            // COMPREHEND tracks point at an existing repo — the lap *understands*
            // it (no mutation). Drive the comprehension engine: the `comprehend`
            // binary (almanac-organs) runs the wiring/gates/config organs over the
            // clone and prints a report. We point it at the same dir the scorer
            // runs the acceptance command in (`local_clone_dir`) — read-only, so
            // unlike CREATE we must NOT wipe the dir first.
            //
            // EFFECTIVE-336 v1: comprehend REPORTS but does not WRITE the
            // onboarding map, so a track whose acceptance checks for that file
            // will honestly score FAIL post-comprehend — surfacing "write-the-map-
            // after-comprehend" as the next COMPREHEND layer (a follow-up wires
            // comprehend → emit docs/ONBOARDING_MAP.md so acceptance can pass
            // zero-touch). Mirrors the CREATE arm's honest-partial posture.
            let bin = comprehend_bin().ok_or_else(|| {
                anyhow::anyhow!("comprehend binary not found (set CHUMP_COMPREHEND_BIN)")
            })?;
            let dir = local_clone_dir(&track.repo);
            let status = Command::new(&bin)
                .arg("--repo")
                .arg(&dir)
                .status()
                .with_context(|| "spawn comprehend")?;
            if !status.success() {
                anyhow::bail!(
                    "engine `comprehend --repo` exited non-zero for {}",
                    track.repo
                );
            }
            Ok(None)
        }
        other => {
            anyhow::bail!(
                "unknown bench mode {other} (wired: RESCUE/IMPROVE/CREATE/COMPREHEND/FINISH)"
            )
        }
    }
}

/// Score a track: grade the acceptance check + tally touches. (Does not drive the engine.)
pub fn score_track(track: &Track, drive_verdict: Option<(Verdict, String)>) -> LapScore {
    let (acc, detail) = match (drive_verdict, track.acceptance.kind.to_lowercase().as_str()) {
        // EFFECTIVE-350: a RESCUE lap scores on PR-GREEN — the drive step already
        // opened a PR and graded whether the previously-red check went green on it.
        // Use that verdict directly (the authoritative acceptance for the lap).
        (Some(v), _) => v,
        // CREDIBLE-186: poll until CI SETTLES and the named previously-red check is
        // green — never grade a transient snapshot (the false-green that merged junk
        // to BEAST-MODE main). Bounded by CHUMP_BENCH_CI_WAIT_SECS (default 300s).
        (None, "ci-green") => {
            let budget_secs = std::env::var("CHUMP_BENCH_CI_WAIT_SECS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(300);
            await_ci_verdict(&track.repo, &track.acceptance.required_check, budget_secs)
        }
        // The universal gradeable primitive: run the acceptance command in the repo's clone,
        // PASS iff exit 0. Covers test-passes (cargo/npm test), url-live (curl), the CREATE
        // tool-runs check, and comprehension-accuracy (a validator that the map's paths exist).
        (None, "command") => {
            let d = local_clone_dir(&track.repo);
            let cwd = if d.exists() { Some(d) } else { None };
            match cwd
                .as_deref()
                .and_then(|dir| syntax_precheck(&track.stack, dir))
            {
                Some(fail) => fail,
                None => grade_command(&track.acceptance.check, cwd.as_deref()),
            }
        }
        (None, other) => (
            Verdict::Unknown,
            format!("acceptance kind '{other}' not graded yet (v1: ci-green | command)"),
        ),
    };
    let (touches, touch_detail) = tally_human_touches(&track.repo);
    let result = overall_result(acc, touches, track.budget.max_human_touches).to_string();
    LapScore {
        track: track.id.clone(),
        mode: track.mode.clone(),
        repo: track.repo.clone(),
        acceptance_kind: track.acceptance.kind.clone(),
        acceptance_verdict: acc,
        result,
        human_touches: touches,
        detail: format!("{detail}; touches: {touch_detail}"),
        // CREDIBLE-188: set by the caller (run/run_heat) which times the whole lap.
        wall_clock_s: 0,
        model_class: String::new(),
        spirit_verdict: String::new(),
        spirit_reason: String::new(),
        // CREDIBLE-190: set by the caller from the captured agent-run output (--implement laps).
        tool_calls: 0,
        hit_iteration_cap: false,
    }
}

fn usage() -> i32 {
    eprintln!(
        "chump bench — ChumpBench: run a track as a scoreable lap (DOC-072)\n\n\
USAGE:\n  chump bench run --track <path.yaml> [--apply] [--implement] [--json]\n\n\
FLAGS:\n  \
--track <path>   Path to a track YAML (e2e/chumpbench/<id>.yaml)\n  \
--apply          Drive the track's mode engine first, THEN score (default: score current state)\n  \
--implement      CREATE only: after scaffolding, drive the coding agent to build the tool (implies --apply; slow)\n  \
--json           Machine-readable scorecard"
    );
    2
}

/// CLI entry — dispatched from `main.rs` on `chump bench`.
pub fn run(args: &[String]) -> i32 {
    // CREDIBLE-184: `chump bench heat` runs the whole track suite and prints one
    // aggregated V1 scorecard (the green/red board we drive to green).
    if args.first().map(String::as_str) == Some("heat") {
        return run_heat(&args[1..]);
    }
    // args[0] is the subcommand ("run"); tolerate its absence.
    let mut track_path: Option<String> = None;
    let mut apply = false;
    let mut implement = false;
    let mut json = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "run" => {}
            "--track" => {
                i += 1;
                match args.get(i) {
                    Some(p) => track_path = Some(p.clone()),
                    None => {
                        eprintln!("--track needs a path");
                        return usage();
                    }
                }
            }
            "--apply" => apply = true,
            // --implement drives the coding agent to BUILD the tool after
            // scaffolding (CREATE only, EFFECTIVE-341). Implies --apply.
            "--implement" => {
                apply = true;
                implement = true;
            }
            "--json" => json = true,
            "-h" | "--help" => return usage(),
            other => {
                eprintln!("unknown arg: {other}");
                return usage();
            }
        }
        i += 1;
    }
    let Some(tp) = track_path else {
        eprintln!("a --track <path.yaml> is required");
        return usage();
    };
    let track = match load_track(Path::new(&tp)) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("could not load track: {e:#}");
            return 1;
        }
    };

    let lap_t0 = std::time::Instant::now();
    let drive_verdict = if apply {
        eprintln!("[bench] driving {} engine on {} …", track.mode, track.repo);
        match drive_engine(&track, implement) {
            Ok(v) => v,
            Err(e) => {
                // CREDIBLE-193: an engine-drive failure under --apply must NOT fall
                // through to score the pre-existing clone. A prior lap's leftover fix
                // sits in the reused clone, so grade_command passes → false PASS with
                // no lap-authored diff (spirit: "no diff to judge"). Grade the lap a
                // hard FAIL, using the engine error as the acceptance verdict —
                // score_track's (Some(v), _) arm consumes it directly. Distinct from
                // CREDIBLE-190 (engine-SUCCESS + non-wiped clone).
                eprintln!(
                    "[bench] engine drive FAILED: {e:#} — grading lap FAIL (refusing to score stale clone)"
                );
                Some((Verdict::Fail, format!("engine drive failed: {e:#}")))
            }
        }
    } else {
        None
    };

    let mut score = score_track(&track, drive_verdict);
    score.wall_clock_s = lap_t0.elapsed().as_secs();
    score.model_class = model_class_for_difficulty(&track.difficulty)
        .unwrap_or("default")
        .to_string();
    // CREDIBLE-192: advisory SPIRIT judgment on the lap's diff (does it GENUINELY
    // achieve the intent, or is it a stub/hack?). Only when we drove a lap.
    if apply {
        let chump_bin = std::env::var("CHUMP_BENCH_CHUMP_BIN")
            .or_else(|_| std::env::var("CHUMP_BIN"))
            .unwrap_or_else(|_| "chump".to_string());
        let d = local_clone_dir(&track.repo);
        if d.exists() {
            let (v, r) = spirit_judge(&chump_bin, &track, score.acceptance_verdict, &d);
            score.spirit_verdict = v;
            score.spirit_reason = r;
        }
        // CREDIBLE-190: only --implement laps spawn a captured agent-run; read its effort.
        if implement {
            let (tc, cap) = parse_agent_effort(&d);
            score.tool_calls = tc;
            score.hit_iteration_cap = cap;
        }
    }
    if json {
        println!(
            "{}",
            serde_json::to_string(&score).unwrap_or_else(|_| "{}".into())
        );
        return 0;
    }
    println!("── ChumpBench lap: {} ──", score.track);
    println!("  mode:       {}  repo: {}", score.mode, score.repo);
    println!("  task:       {}", track.task);
    println!(
        "  acceptance: {} → {:?}",
        score.acceptance_kind, score.acceptance_verdict
    );
    println!(
        "  human touches: {}",
        score
            .human_touches
            .map(|t| t.to_string())
            .unwrap_or_else(|| "n/a".into())
    );
    println!(
        "  effort:     {}s wall-clock · routed class '{}'{}",
        score.wall_clock_s,
        score.model_class,
        // CREDIBLE-190: make the agent-loop flail legible right in the scorecard.
        if score.tool_calls > 0 || score.hit_iteration_cap {
            format!(
                " · {} tool-calls{}",
                score.tool_calls,
                if score.hit_iteration_cap {
                    " · ⚠ HIT ITERATION CAP (agent didn't terminate)"
                } else {
                    ""
                }
            )
        } else {
            String::new()
        }
    );
    if !score.spirit_verdict.is_empty() {
        println!(
            "  spirit:     {} — {} (advisory)",
            score.spirit_verdict, score.spirit_reason
        );
    }
    println!("  RESULT:     {}", score.result);
    println!("  detail:     {}", score.detail);
    0
}

/// Aggregate a heat's per-track scores: (green, total, zero_touch_passes).
/// A green track has `result == "PASS"`; a zero-touch pass additionally proved
/// `human_touches == Some(0)` — the V1 bar is not just green, it's green with a
/// receipt that no one reached in.
fn heat_summary(scores: &[LapScore]) -> (usize, usize, usize) {
    let total = scores.len();
    let green = scores.iter().filter(|s| s.result == "PASS").count();
    let zt = scores
        .iter()
        .filter(|s| s.result == "PASS" && s.human_touches == Some(0))
        .count();
    (green, total, zt)
}

/// CREDIBLE-184: run every track in the suite and print one aggregated V1
/// scorecard — the single green/red board we drive to green. Score-only by
/// default (fast, current state); `--apply`/`--implement` drive each engine
/// first. Exits non-zero unless every track is green, so the loop/CI can gate
/// on "fully green".
fn run_heat(args: &[String]) -> i32 {
    let mut apply = false;
    let mut implement = false;
    let mut json = false;
    let mut dir = "e2e/chumpbench".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--apply" => apply = true,
            "--implement" => {
                apply = true;
                implement = true;
            }
            "--json" => json = true,
            "--dir" => {
                i += 1;
                if let Some(d) = args.get(i) {
                    dir = d.clone();
                }
            }
            "-h" | "--help" => {
                eprintln!(
                    "usage: chump bench heat [--apply] [--implement] [--json] [--dir <path>]"
                );
                return 2;
            }
            other => {
                eprintln!("unknown arg: {other}");
                return 2;
            }
        }
        i += 1;
    }

    let mut paths: Vec<std::path::PathBuf> = match std::fs::read_dir(&dir) {
        Ok(rd) => rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.extension()
                    .map(|x| x == "yaml" || x == "yml")
                    .unwrap_or(false)
            })
            .collect(),
        Err(e) => {
            eprintln!("bench heat: cannot read {dir}: {e}");
            return 1;
        }
    };
    paths.sort();
    if paths.is_empty() {
        eprintln!("bench heat: no tracks in {dir}");
        return 1;
    }

    let mut scores: Vec<LapScore> = Vec::new();
    for p in &paths {
        let track = match load_track(p) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("[heat] skip {}: {e:#}", p.display());
                continue;
            }
        };
        let lap_t0 = std::time::Instant::now();
        let drive_verdict = if apply {
            eprintln!("[heat] driving {} on {} …", track.mode, track.repo);
            match drive_engine(&track, implement) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!(
                        "[heat] {} drive failed: {e:#} — scoring current state",
                        track.id
                    );
                    None
                }
            }
        } else {
            None
        };
        let mut lap = score_track(&track, drive_verdict);
        lap.wall_clock_s = lap_t0.elapsed().as_secs();
        lap.model_class = model_class_for_difficulty(&track.difficulty)
            .unwrap_or("default")
            .to_string();
        if apply {
            let cbin = std::env::var("CHUMP_BENCH_CHUMP_BIN")
                .or_else(|_| std::env::var("CHUMP_BIN"))
                .unwrap_or_else(|_| "chump".to_string());
            let d = local_clone_dir(&track.repo);
            if d.exists() {
                let (v, r) = spirit_judge(&cbin, &track, lap.acceptance_verdict, &d);
                lap.spirit_verdict = v;
                lap.spirit_reason = r;
            }
            // CREDIBLE-190: only --implement laps capture agent output; read its effort.
            if implement {
                let (tc, cap) = parse_agent_effort(&d);
                lap.tool_calls = tc;
                lap.hit_iteration_cap = cap;
            }
        }
        scores.push(lap);
    }

    if json {
        println!(
            "{}",
            serde_json::to_string(&scores).unwrap_or_else(|_| "[]".into())
        );
        let (green, total, _) = heat_summary(&scores);
        return if green == total { 0 } else { 1 };
    }

    let (green, total, zt) = heat_summary(&scores);
    println!("── ChumpBench V1 scorecard — {green}/{total} green ──");
    println!(
        "  {:<32} {:<8} {:<8} {:<6} {:<7} {:<8} {:<7} SPIRIT",
        "TRACK", "MODE", "RESULT", "TOUCH", "WALL", "CLASS", "TOOLS"
    );
    for s in &scores {
        let touch = s
            .human_touches
            .map(|t| t.to_string())
            .unwrap_or_else(|| "n/a".into());
        let spirit = if s.spirit_verdict.is_empty() {
            "-".to_string()
        } else {
            s.spirit_verdict.clone()
        };
        // CREDIBLE-190: TOOLS column — tool-call count, with ⚠ when the agent hit its
        // iteration cap (flailed without terminating). "-" when not a captured lap.
        let tools = if s.tool_calls > 0 || s.hit_iteration_cap {
            format!(
                "{}{}",
                s.tool_calls,
                if s.hit_iteration_cap { "⚠" } else { "" }
            )
        } else {
            "-".to_string()
        };
        println!(
            "  {:<32} {:<8} {:<8} {:<6} {:<7} {:<8} {:<7} {}",
            s.track,
            s.mode,
            s.result,
            touch,
            format!("{}s", s.wall_clock_s),
            s.model_class,
            tools,
            spirit
        );
    }
    let total_wall: u64 = scores.iter().map(|s| s.wall_clock_s).sum();
    println!("  ─────");
    println!(
        "  GREEN: {green}/{total}   zero-touch passes: {zt}/{green}   total wall-clock: {total_wall}s"
    );
    if green == total && total > 0 {
        println!("  ✅ V1 scorecard fully green");
        0
    } else {
        println!("  ⛳ {} track(s) still red", total - green);
        1
    }
}

/// Merge the bench's proof PR (by branch) through the one arm policy
/// (INFRA-8221): a PR someone put on hold while the bench waited for checks
/// (no-auto-merge label / `Auto-merge: hold`) is left alone. Returns whether
/// the merge command ran and succeeded.
fn merge_rescue_pr(gh: &str, branch: &str, repo: &str) -> bool {
    if let Err(held) = chump_ship::arm_policy::require_allowed(
        branch,
        repo,
        "chump-bench(rescue)",
        chump_ship::arm_policy::GateAction::Touch,
    ) {
        eprintln!("[bench] {held}");
        return false;
    }
    Command::new(gh)
        .args(["pr", "merge", branch, "--repo", repo, "--squash", "--admin"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lap(result: &str, touches: Option<u64>) -> LapScore {
        LapScore {
            track: "t".into(),
            mode: "CREATE".into(),
            repo: "r".into(),
            acceptance_kind: "command".into(),
            acceptance_verdict: Verdict::Pass,
            result: result.into(),
            human_touches: touches,
            detail: String::new(),
            wall_clock_s: 0,
            model_class: String::new(),
            spirit_verdict: String::new(),
            spirit_reason: String::new(),
            tool_calls: 0,
            hit_iteration_cap: false,
        }
    }

    fn cr(name: &str, status: &str, conclusion: &str) -> CheckRun {
        CheckRun {
            name: name.to_string(),
            status: status.to_string(),
            conclusion: conclusion.to_string(),
        }
    }

    #[test]
    fn credible192_parse_spirit_verdict() {
        assert_eq!(
            parse_spirit_verdict("VERDICT: GENUINE - cleanly implements the parser").0,
            "GENUINE"
        );
        let (v, r) = parse_spirit_verdict("VERDICT: STUB - placeholder, does nothing");
        assert_eq!(v, "STUB");
        assert!(r.contains("placeholder"));
        // em-dash separator + surrounding prose lines.
        assert_eq!(
            parse_spirit_verdict("here is my review\nVERDICT: HACK \u{2014} hardcodes the answer")
                .0,
            "HACK"
        );
        // Unstructured fallback: a bare keyword still classifies (worst-first).
        assert_eq!(
            parse_spirit_verdict("this looks like a stub to me honestly").0,
            "STUB"
        );
        // Nothing parseable → empty verdict (advisory: treated as not-judged).
        assert_eq!(parse_spirit_verdict("I cannot tell").0, "");
    }

    #[test]
    fn credible186_strict_grader_refuses_transient_and_keys_on_required_check() {
        // The exact false-green shape: fast checks green, but the required check
        // (ml-pipeline) is still running → NOT a pass, it's Unknown ("keep waiting").
        let mid_run = vec![
            cr("build", "completed", "success"),
            cr("Code Quality Analysis", "completed", "success"),
            cr("ml-pipeline", "in_progress", ""),
            cr("smoke-tests", "queued", ""),
        ];
        assert_eq!(
            grade_checks_strict(&mid_run, "ml-pipeline").0,
            Verdict::Unknown,
            "must not PASS while the required check is still running"
        );

        // Required check present but FAILED → Fail (even if everything else is green).
        let req_failed = vec![
            cr("build", "completed", "success"),
            cr("ml-pipeline", "completed", "failure"),
        ];
        assert_eq!(
            grade_checks_strict(&req_failed, "ml-pipeline").0,
            Verdict::Fail
        );

        // Required check missing entirely (never reported) → Unknown, not Pass.
        let req_absent = vec![cr("build", "completed", "success")];
        assert_eq!(
            grade_checks_strict(&req_absent, "ml-pipeline").0,
            Verdict::Unknown
        );

        // The honest green: all settled AND the required check itself is green → Pass.
        let real_green = vec![
            cr("build", "completed", "success"),
            cr("ml-pipeline", "completed", "success"),
            cr("smoke-tests", "completed", "success"),
        ];
        assert_eq!(
            grade_checks_strict(&real_green, "ml-pipeline").0,
            Verdict::Pass
        );

        // No required check named: still refuse a mid-run snapshot; PASS only when all settled.
        let no_req_mid = vec![
            cr("build", "completed", "success"),
            cr("x", "in_progress", ""),
        ];
        assert_eq!(grade_checks_strict(&no_req_mid, "").0, Verdict::Unknown);
        let no_req_done = vec![
            cr("build", "completed", "success"),
            cr("x", "completed", "success"),
        ];
        assert_eq!(grade_checks_strict(&no_req_done, "").0, Verdict::Pass);
        // A failure anywhere (all settled) → Fail even without a named required check.
        let no_req_fail = vec![
            cr("build", "completed", "success"),
            cr("x", "completed", "failure"),
        ];
        assert_eq!(grade_checks_strict(&no_req_fail, "").0, Verdict::Fail);
    }

    #[test]
    fn effective349_tail_to_chars_keeps_end_on_boundary() {
        // Shorter than the cap → returned whole, no marker.
        assert_eq!(tail_to_chars("short log", 100), "short log");
        // Longer than the cap → keeps the TAIL (the error), with a marker prefix.
        let big = "A".repeat(5000);
        let out = tail_to_chars(&big, 100);
        assert!(out.contains("truncated"));
        assert!(out.ends_with(&"A".repeat(100)));
        // Multi-byte content near the cut does not panic and stays valid UTF-8.
        let unicode = format!("{}déjà-vu-café", "x".repeat(50));
        let out = tail_to_chars(&unicode, 10);
        assert!(out.is_char_boundary(out.len()));
        assert!(out.ends_with("café"));
    }

    #[test]
    fn effective350_rescue_disposition_merges_only_on_optin_and_green() {
        use RescueDisposition::*;
        // Default (no opt-in): always close the proof PR — nothing touches main,
        // regardless of verdict. This is what makes the pollution class impossible.
        assert_eq!(rescue_disposition(Verdict::Pass, false), Close);
        assert_eq!(rescue_disposition(Verdict::Fail, false), Close);
        assert_eq!(rescue_disposition(Verdict::Unknown, false), Close);
        // Opt-in: merge ONLY when the fix is actually green (the pre-merge gate).
        assert_eq!(rescue_disposition(Verdict::Pass, true), Merge);
        assert_eq!(rescue_disposition(Verdict::Fail, true), Close);
        assert_eq!(rescue_disposition(Verdict::Unknown, true), Close);
    }

    #[test]
    fn effective346_rescue_branch_name_is_deterministic_and_clean() {
        assert_eq!(rescue_branch_name("abc1234"), "chump/bench-rescue-abc1234");
        // Same SHA → same branch (idempotent re-push).
        assert_eq!(rescue_branch_name("abc1234"), rescue_branch_name("abc1234"));
        // Non-alphanumerics stripped; length capped.
        assert_eq!(
            rescue_branch_name("  ab/cd\n1234567890xyz  "),
            "chump/bench-rescue-abcd12345678"
        );
        // Empty/garbage SHA falls back to a valid ref.
        assert_eq!(rescue_branch_name(""), "chump/bench-rescue-fix");
        assert_eq!(rescue_branch_name("///"), "chump/bench-rescue-fix");
    }

    #[test]
    fn effective348_difficulty_maps_to_model_class() {
        // Easy laps stay on cheap 70B-class; hard laps escalate to the opus pool.
        assert_eq!(model_class_for_difficulty("easy"), Some("sonnet"));
        assert_eq!(model_class_for_difficulty("tiny"), Some("sonnet"));
        assert_eq!(model_class_for_difficulty("medium"), Some("opus"));
        assert_eq!(model_class_for_difficulty("hard"), Some("opus"));
        // Case/whitespace-insensitive.
        assert_eq!(model_class_for_difficulty("  HARD "), Some("opus"));
        // Unknown/blank difficulty leaves the cascade on its default (no escalation).
        assert_eq!(model_class_for_difficulty(""), None);
        assert_eq!(model_class_for_difficulty("spicy"), None);
    }

    #[test]
    fn heat_summary_counts_green_and_zero_touch() {
        // green = PASS; zero-touch pass = PASS with a proven touches==0 receipt
        // (a PASS with touches n/a is green but NOT a proven zero-touch pass).
        let scores = vec![lap("PASS", Some(0)), lap("PASS", None), lap("FAIL", None)];
        assert_eq!(heat_summary(&scores), (2, 3, 1));
    }

    #[test]
    fn ci_grading_is_conservative() {
        assert_eq!(
            grade_check_conclusions(&["success".into(), "skipped".into()]),
            Verdict::Pass
        );
        // any failure dominates
        assert_eq!(
            grade_check_conclusions(&["success".into(), "failure".into()]),
            Verdict::Fail
        );
        // nothing conclusive → unknown, never a false pass
        assert_eq!(grade_check_conclusions(&[]), Verdict::Unknown);
        assert_eq!(
            grade_check_conclusions(&["".into(), "null".into()]),
            Verdict::Unknown
        );
    }

    #[test]
    fn overall_result_maps_verdict_and_touch_budget() {
        // acceptance fail → FAIL regardless of touches
        assert_eq!(overall_result(Verdict::Fail, Some(0), 0), "FAIL");
        assert_eq!(overall_result(Verdict::Unknown, Some(0), 0), "FAIL");
        // acceptance pass + within touch budget → PASS
        assert_eq!(overall_result(Verdict::Pass, Some(0), 0), "PASS");
        assert_eq!(overall_result(Verdict::Pass, None, 0), "PASS");
        // acceptance pass but a human had to reach in → PARTIAL (the honest distinction)
        assert_eq!(overall_result(Verdict::Pass, Some(3), 0), "PARTIAL");
    }

    #[test]
    fn credible193_engine_failure_grades_fail_not_stale_pass() {
        // CREDIBLE-193: when the --apply engine drive FAILS, run() now hands
        // score_track a Some((Verdict::Fail, <engine error>)) so the lap grades a
        // hard FAIL — instead of falling through to grade_command on the STALE local
        // clone, where a prior lap's leftover fix false-greened the acceptance
        // (result=PASS, wall_clock_s=1, spirit="no diff to judge"). This pins that a
        // failure drive-verdict maps to result="FAIL", never a stale PASS. The repo
        // name has no local clone, so grade_command is never consulted.
        let y = r#"
id: rescue-nonexistent
mode: RESCUE
repo: test/credible193-nonexistent-bench-repo
stack: javascript
difficulty: easy
task: "fix the bug"
acceptance:
  kind: command
  check: "node -e \"process.exit(0)\""
budget:
  max_wall_clock_min: 30
  max_human_touches: 0
"#;
        let t: Track = serde_yaml::from_str(y).unwrap();
        let score = score_track(
            &t,
            Some((
                Verdict::Fail,
                "engine drive failed: no onboard scan".to_string(),
            )),
        );
        assert_eq!(
            score.result, "FAIL",
            "engine-drive failure must grade FAIL, not score a stale clone"
        );
        assert_eq!(score.acceptance_verdict, Verdict::Fail);
        assert!(
            score.detail.contains("engine drive failed"),
            "the engine error must be surfaced in the lap detail, got: {}",
            score.detail
        );
    }

    #[test]
    fn track_yaml_round_trips() {
        let y = r#"
id: rescue-beast-ci
mode: RESCUE
repo: repairman29/BEAST-MODE
stack: javascript
state: red-ci
difficulty: medium
task: "CI is red, fix it."
acceptance:
  kind: ci-green
  check: "all checks pass"
budget:
  max_wall_clock_min: 30
  max_human_touches: 0
"#;
        let t: Track = serde_yaml::from_str(y).unwrap();
        assert_eq!(t.id, "rescue-beast-ci");
        assert_eq!(t.mode, "RESCUE");
        assert_eq!(t.acceptance.kind, "ci-green");
        assert_eq!(t.budget.max_human_touches, 0);
        // Backward-compat: a track without seed_break parses (serde default = empty).
        assert!(t.seed_break.is_empty());
    }

    #[test]
    fn credible187_seed_break_and_command_acceptance_parse() {
        // The deterministic RESCUE shape: a command acceptance + a seed_break the lap
        // applies before the agent runs.
        let y = r#"
id: rescue-beast-ci
mode: RESCUE
repo: repairman29/BEAST-MODE
stack: javascript
difficulty: easy
task: "fix the bug"
acceptance:
  kind: command
  check: "node -e \"process.exit(0)\""
seed_break: "printf '%s' 'bug' > fixture.js"
budget:
  max_wall_clock_min: 15
  max_human_touches: 0
"#;
        let t: Track = serde_yaml::from_str(y).unwrap();
        assert_eq!(t.acceptance.kind, "command");
        assert!(t.acceptance.check.contains("node -e"));
        assert!(t.seed_break.contains("fixture.js"));
    }

    /// INFRA-3523: the touch counter must tally only the LAP's own commits, not the external
    /// clone's entire pre-existing history. Fixture: a repo with N human commits on the base
    /// branch + 1 zero-touch lap commit on a `chump/*` branch → scanned == 1 (the lap commit),
    /// human == 0, zt == 1 — NOT N+1.
    #[test]
    fn touch_count_is_scoped_to_the_lap_not_the_whole_clone() {
        let tmp = std::env::temp_dir().join(format!("chump-bench-inf3523-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let cd = tmp.to_string_lossy().to_string();
        let git = |args: &[&str]| {
            let ok = Command::new("git")
                .args(["-C", &cd])
                .args(args)
                .env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00")
                .env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00")
                .output()
                .unwrap();
            assert!(
                ok.status.success(),
                "git {args:?} failed: {}",
                String::from_utf8_lossy(&ok.stderr)
            );
        };
        git(&["init", "-q", "-b", "main"]);
        // A distinct HUMAN identity with no trailer — these must NOT be counted.
        git(&["config", "user.name", "Jane Human"]);
        git(&["config", "user.email", "jane@example.com"]);
        // N = 5 pre-existing human commits on the base branch (the clone's inherited history).
        let n = 5;
        for i in 0..n {
            std::fs::write(tmp.join(format!("f{i}.txt")), format!("{i}")).unwrap();
            git(&["add", "-A"]);
            git(&[
                "commit",
                "-q",
                "-m",
                &format!("pre-existing human commit {i}"),
            ]);
        }
        // The lap branches off base and adds ONE commit carrying the zero-touch trailer.
        git(&["checkout", "-q", "-b", "chump/improve-p999"]);
        std::fs::write(tmp.join("lap.txt"), "lap").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "lap work\n\nChump-Agent: chump/v1"]);

        // The scoped range must be base..lap-branch and yield exactly the 1 lap commit.
        let range = lap_commit_range(&tmp).expect("range resolves");
        assert_eq!(
            range, "main..chump/improve-p999",
            "scoped to base..lap-branch"
        );
        let (human, zt, scanned) = count_provenance(&tmp, &range).expect("counts");
        assert_eq!(
            scanned, 1,
            "scanned only the lap's commit, not the {} pre-existing",
            n
        );
        assert_eq!(zt, 1, "the lap commit is zero-touch (carries the trailer)");
        assert_eq!(human, 0, "no human touches in the lap itself");

        // Guard against regression: the OLD full-history count would have scanned N+1.
        let (_, _, full) = count_provenance(&tmp, "chump/improve-p999").expect("full counts");
        assert_eq!(
            full,
            (n + 1) as u64,
            "sanity: unscoped counts every commit (the old bug)"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible194_spirit_diff_range_nonempty_when_lap_commits_on_main() {
        // CREDIBLE-194: a RESCUE/--implement lap commits onto the clone's OWN main (no
        // chump/* branch). The OLD spirit-judge diff `base_branch...HEAD` was empty there
        // (base resolves to the same tip as HEAD) → "no diff to judge" on exactly the laps
        // that most need judging. Prove the lap_commit_range-based diff sees the lap's
        // change while the old three-dot diff does not.
        let tmp = std::env::temp_dir().join(format!("chump-bench-c194-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let cd = tmp.to_string_lossy().to_string();
        let git = |args: &[&str]| {
            let ok = Command::new("git")
                .args(["-C", &cd])
                .args(args)
                .env("GIT_AUTHOR_DATE", "2026-01-01T00:00:00")
                .env("GIT_COMMITTER_DATE", "2026-01-01T00:00:00")
                .output()
                .unwrap();
            assert!(
                ok.status.success(),
                "git {args:?} failed: {}",
                String::from_utf8_lossy(&ok.stderr)
            );
        };
        let git_out = |args: &[&str]| -> String {
            let o = Command::new("git")
                .args(["-C", &cd])
                .args(args)
                .output()
                .unwrap();
            String::from_utf8_lossy(&o.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.name", "Bench Bot"]);
        git(&["config", "user.email", "bench@example.com"]);
        // Base commit, then freeze origin/main at it (the immovable base a real clone has).
        std::fs::write(tmp.join("f0.txt"), "0").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "base"]);
        let base_sha = git_out(&["rev-parse", "HEAD"]);
        git(&["update-ref", "refs/remotes/origin/main", &base_sha]);
        git(&[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
        ]);
        // The lap commits its fix ONTO main (the RESCUE/--implement scenario, no chump/* branch).
        std::fs::write(tmp.join("fixture.js"), "function add(a,b){return a+b}").unwrap();
        git(&["add", "-A"]);
        git(&[
            "commit",
            "-q",
            "-m",
            "fix the fixture\n\nChump-Agent: chump/v1",
        ]);

        // OLD spirit-judge behavior: base_branch is "main"; `main...HEAD` is empty because
        // the lap commits are ON main (base == HEAD).
        let old_three_dot = git_out(&["diff", "main...HEAD"]);
        assert!(
            old_three_dot.is_empty(),
            "old base_branch...HEAD diff is empty on a commit-on-main lap (the bug)"
        );

        // FIX: lap_commit_range yields origin/main..HEAD → the diff sees the lap's change.
        let range = lap_commit_range(&tmp).expect("range resolves");
        let scoped = git_out(&["diff", &range]);
        assert!(
            scoped.contains("fixture.js"),
            "lap_commit_range diff must contain the lap's change, got: {scoped:?}"
        );
        assert!(
            !scoped.is_empty(),
            "the spirit judge now has a real diff to judge"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible195_spirit_prompt_is_grounded_by_acceptance_and_intent() {
        // CREDIBLE-195 (CREDIBLE-191 slice 1): the spirit prompt must be grounded so the lens
        // stops false-STUB-ing genuine minimal fixes — it needs the acceptance RESULT + a
        // fuller intent (mode + acceptance command), while keeping the HACK lens sharp.
        let y = r#"
id: rescue-beast-ci
mode: RESCUE
repo: repairman29/BEAST-MODE
stack: javascript
difficulty: easy
task: "fix the add function"
acceptance:
  kind: command
  check: "node -e \"const {add}=require('./f'); if(add(2,3)!==5) process.exit(1)\""
budget:
  max_wall_clock_min: 30
  max_human_touches: 0
"#;
        let t: Track = serde_yaml::from_str(y).unwrap();
        let diff = "+function add(a,b){return a+b}";
        let p = build_spirit_prompt(&t, Verdict::Pass, diff);
        // grounded by the acceptance RESULT (the fix that closes the false-STUB)
        assert!(
            p.contains("acceptance check for this task returned PASS"),
            "prompt must state the acceptance result: {p}"
        );
        assert!(
            p.contains("minimal but correct fix that passes acceptance is GENUINE"),
            "prompt must tell the judge a passing minimal fix is GENUINE, not STUB"
        );
        // the HACK lens stays sharp (acceptance-pass rules out STUB, not hack)
        assert!(
            p.contains("hardcoding the expected answer or gaming the check is")
                || p.contains("HACK"),
            "prompt must keep the hack lens"
        );
        // fuller intent: mode + the acceptance command (not just the terse task)
        assert!(p.contains("mode: RESCUE"), "intent must include the mode");
        assert!(
            p.contains("node -e"),
            "intent must include the acceptance command so the judge knows what 'done' means"
        );
        assert!(p.contains("return a+b"), "the diff must be included");
        // FAIL acceptance surfaces as FAIL (grounding reflects reality, not always PASS)
        let pf = build_spirit_prompt(&t, Verdict::Fail, diff);
        assert!(
            pf.contains("returned FAIL"),
            "a failed acceptance must surface as FAIL in the prompt"
        );
    }

    #[test]
    fn effective352_implement_prompt_tells_agent_to_stop_when_done() {
        // EFFECTIVE-352: the --implement prompt must carry an explicit termination
        // instruction so the agent stops after the minimal fix instead of looping to its
        // iteration cap (the 1909s / 26-write flail). Also preserve the task + comprehension.
        let p = build_implement_prompt("fix the add function", "\n\n=== CI LOG ===\nboom");
        assert!(p.contains("fix the add function"), "keeps the task");
        assert!(
            p.contains("=== CI LOG ==="),
            "keeps the comprehension block"
        );
        assert!(
            p.contains("STOP WHEN DONE"),
            "carries the stop-when-done instruction"
        );
        assert!(
            p.contains("MINIMAL change") && p.contains("end your turn"),
            "instructs a minimal change then terminate"
        );
        assert!(
            p.to_lowercase().contains("do not") && p.contains("double-check"),
            "explicitly forbids the re-write-to-double-check loop that caused the flail"
        );
    }

    #[test]
    fn credible190_parse_agent_effort_counts_tools_and_detects_cap() {
        // CREDIBLE-190: the scorecard was blind to the agent-loop flail (26 write_file +
        // "Exceeded max iterations"). parse_agent_effort reads the captured agent-run log
        // beside the clone and surfaces (tool_calls, hit_iteration_cap).
        let base = std::env::temp_dir().join(format!("chump-bench-c190-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let clone = base.join("clone");
        std::fs::create_dir_all(&clone).unwrap();
        // No capture (e.g. a non --implement lap) → (0, false), never panics.
        assert_eq!(parse_agent_effort(&clone), (0, false));
        // A flail: 3 tool calls AND the iteration cap.
        let cap = base.join(".bench-agent-output.log");
        std::fs::write(
            &cap,
            "🔧 Executing tool: write_file\nnoise\n🔧 Executing tool: write_file\n\
             🔧 Executing tool: git_commit\nExceeded max iterations (30)\n",
        )
        .unwrap();
        assert_eq!(
            parse_agent_effort(&clone),
            (3, true),
            "counts 3 tool calls and detects the iteration cap"
        );
        // A clean lap: tool calls, no cap.
        std::fs::write(&cap, "🔧 Executing tool: read_file\ndone\n").unwrap();
        assert_eq!(
            parse_agent_effort(&clone),
            (1, false),
            "1 tool call, no iteration cap"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn command_acceptance_grades_by_exit_code() {
        // pure exit-code mapping
        assert_eq!(verdict_from_exit(Some(0)), Verdict::Pass);
        assert_eq!(verdict_from_exit(Some(1)), Verdict::Fail);
        assert_eq!(verdict_from_exit(Some(127)), Verdict::Fail);
        assert_eq!(verdict_from_exit(None), Verdict::Unknown);
        // live: a real command in a tempdir — exit 0 → PASS, exit 1 → FAIL
        let tmp = std::env::temp_dir();
        assert_eq!(grade_command("true", Some(&tmp)).0, Verdict::Pass);
        assert_eq!(grade_command("false", Some(&tmp)).0, Verdict::Fail);
        // no clone to run in → UNKNOWN, never a false pass
        assert_eq!(grade_command("true", None).0, Verdict::Unknown);
        // empty check → UNKNOWN
        assert_eq!(grade_command("   ", Some(&tmp)).0, Verdict::Unknown);
    }

    /// EFFECTIVE-351: fail fast on a syntactically-invalid python artifact — the
    /// tool-storm-truncation regression class (unclosed paren from an aborted mid-write).
    #[test]
    fn syntax_precheck_catches_invalid_python_before_scoring() {
        let dir = std::env::temp_dir().join(format!(
            "chump-bench-syntax-precheck-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // valid python → no precheck failure, falls through to the acceptance command
        std::fs::write(dir.join("ok.py"), "print('fine')\n").unwrap();
        assert_eq!(syntax_precheck("python", &dir), None);

        // truncated print( — the exact failure mode from the 2026-08-02 git_commit storm
        std::fs::write(dir.join("broken.py"), "print('oops'\n").unwrap();
        let result = syntax_precheck("python", &dir);
        assert!(result.is_some(), "unclosed paren must fail the precheck");
        let (verdict, detail) = result.unwrap();
        assert_eq!(verdict, Verdict::Fail);
        assert!(
            detail.contains("syntax pre-check failed"),
            "detail should feed the parser error back: {detail}"
        );

        // non-python stacks are a no-op — precheck only applies where we can compile-check
        std::fs::write(dir.join("broken.js"), "function( {\n").unwrap();
        let js_dir = std::env::temp_dir().join(format!(
            "chump-bench-syntax-precheck-js-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&js_dir);
        std::fs::create_dir_all(&js_dir).unwrap();
        std::fs::write(js_dir.join("broken.js"), "function( {\n").unwrap();
        assert_eq!(syntax_precheck("javascript", &js_dir), None);

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&js_dir);
    }

    /// INFRA-8221: the rescue-PR merge refuses a held PR before gh runs.
    #[test]
    fn merge_rescue_pr_refuses_held_pr() {
        let dir = std::env::temp_dir().join(format!("bench-arm-policy-{}", std::process::id()));
        let amb = dir.join("ambient.jsonl");
        let _ = std::fs::remove_file(&amb);
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("hold");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        assert!(!merge_rescue_pr(
            "/nonexistent/gh-must-not-run",
            "bench/x",
            "o/r"
        ));
        assert_eq!(fake.calls.get(), 1);
        assert!(std::fs::read_to_string(&amb)
            .unwrap()
            .contains("chump-bench(rescue)"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
