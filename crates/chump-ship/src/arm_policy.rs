//! INFRA-8221 (slice 2) — the ONE arm policy, in Rust.
//!
//! Mirrors `scripts/coord/lib/arm-policy.sh` (RESILIENT-1613, PHASE-R R3)
//! so every Rust armer, merger and rebaser reads "held" the same way the
//! shell armers do. A human or architect disarm is a decision, not a fault.
//!
//! # The contract
//!
//! A PR is HELD when ANY of these is true:
//!   * it carries the label `no-auto-merge` (canonical) or one of the legacy
//!     hold labels `hold`, `do-not-merge`, `CHUMP_HOLD` (case-insensitive);
//!   * its body, or ANY of its comments, has a line matching
//!     `^[ \t]*Auto-merge:[ \t]*hold\b` (case-insensitive).
//!
//! A held PR must never be armed, re-armed, rebased, force-pushed or merged
//! by automation. Refusing emits `kind=pr_arm_skipped_hold` naming the armer.
//! An allowed ARM on a PR whose most recent auto-merge timeline event is a
//! disarm emits `kind=pr_rearmed` (audit trail, not enforcement).
//!
//! # Read path
//!
//! `gh pr view <sel> [--repo R] --json number,labels,body,comments` (the only
//! source of comments), tagged `CHUMP_GH_CALL_CRITICALITY=background`. Fails
//! OPEN when gh cannot be read: a transient API error must not freeze every
//! arm in the fleet (same as the shell policy).
//!
//! # Testing
//!
//! Every gate goes through [`PrHoldFetcher`]. Tests install a fake one with
//! [`override_for_tests`] (thread-local, so parallel tests do not collide)
//! and never touch the network.

use std::cell::RefCell;
use std::fmt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;

use serde_json::Value;

/// Canonical hold label; the legacy ones follow it in [`HOLD_LABELS`].
pub const HOLD_LABEL: &str = "no-auto-merge";
/// Every label that holds a PR (compared case-insensitively).
pub const HOLD_LABELS: [&str; 4] = ["no-auto-merge", "hold", "do-not-merge", "CHUMP_HOLD"];

/// Why a PR is held.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HoldReason {
    /// A hold label, with the label's spelling as it appears on the PR.
    Label(String),
    /// An `Auto-merge: hold` line in the PR body.
    BodyMarker,
    /// An `Auto-merge: hold` line in a PR comment.
    CommentMarker,
}

impl fmt::Display for HoldReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HoldReason::Label(l) => write!(f, "label:{l}"),
            HoldReason::BodyMarker => write!(f, "marker:body"),
            HoldReason::CommentMarker => write!(f, "marker:comment"),
        }
    }
}

/// Result of reading a PR against the policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HoldStatus {
    Held(HoldReason),
    NotHeld,
}

impl HoldStatus {
    pub fn is_held(&self) -> bool {
        matches!(self, HoldStatus::Held(_))
    }
}

/// The policy could not read the PR (the gates treat this as fail-open).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArmPolicyError(pub String);

impl fmt::Display for ArmPolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "arm policy could not read the PR: {}", self.0)
    }
}

impl std::error::Error for ArmPolicyError {}

/// A gate refused: the PR is held. Callers skip the arm/merge/rebase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArmHeld {
    /// PR number when known, else the selector (branch) that was checked.
    pub pr: String,
    pub armer: String,
    pub reason: HoldReason,
}

impl fmt::Display for ArmHeld {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "PR #{} is HELD ({}); {} will not arm, merge or rebase it (remove the hold label / marker to release)",
            self.pr, self.reason, self.armer
        )
    }
}

impl std::error::Error for ArmHeld {}

/// What the gate is about to do. Only `Arm` runs the re-arm audit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateAction {
    /// Enable auto-merge (`gh pr merge --auto`, enablePullRequestAutoMerge).
    Arm,
    /// Merge, rebase, update-branch or force-push.
    Touch,
}

/// True when `line` is an `Auto-merge: hold` marker line
/// (`^[ \t]*auto-merge:[ \t]*hold\b`, case-insensitive).
pub fn line_is_hold_marker(line: &str) -> bool {
    let t = line.trim_start_matches([' ', '\t']).to_ascii_lowercase();
    let Some(rest) = t.strip_prefix("auto-merge:") else {
        return false;
    };
    let rest = rest.trim_start_matches([' ', '\t']);
    let Some(after) = rest.strip_prefix("hold") else {
        return false;
    };
    match after.chars().next() {
        None => true,
        Some(c) => !(c.is_alphanumeric() || c == '_'),
    }
}

fn text_has_marker(s: &str) -> bool {
    s.lines().any(line_is_hold_marker)
}

fn entry_text(v: &Value, key: &str) -> String {
    match v {
        Value::Object(_) => v.get(key).and_then(Value::as_str).unwrap_or("").to_string(),
        Value::String(s) => s.clone(),
        _ => String::new(),
    }
}

/// Classify a `gh pr view --json labels,body,comments` (or REST pulls)
/// payload. Pure. Errors only when the payload is not a JSON object.
pub fn hold_status_from_json(v: &Value) -> Result<HoldStatus, ArmPolicyError> {
    if !v.is_object() {
        return Err(ArmPolicyError("payload is not a JSON object".into()));
    }
    if let Some(labels) = v.get("labels").and_then(Value::as_array) {
        for l in labels {
            let name = entry_text(l, "name");
            if HOLD_LABELS.iter().any(|h| h.eq_ignore_ascii_case(&name)) {
                return Ok(HoldStatus::Held(HoldReason::Label(name)));
            }
        }
    }
    if text_has_marker(v.get("body").and_then(Value::as_str).unwrap_or("")) {
        return Ok(HoldStatus::Held(HoldReason::BodyMarker));
    }
    if let Some(comments) = v.get("comments").and_then(Value::as_array) {
        if comments
            .iter()
            .any(|c| text_has_marker(&entry_text(c, "body")))
        {
            return Ok(HoldStatus::Held(HoldReason::CommentMarker));
        }
    }
    Ok(HoldStatus::NotHeld)
}

/// Source of PR data for the policy. The default is [`GhFetcher`].
pub trait PrHoldFetcher {
    /// `gh pr view <selector> [--repo repo] --json number,labels,body,comments`.
    /// `repo` empty = the current checkout's repo.
    fn fetch(&self, selector: &str, repo: &str) -> Result<Value, String>;

    /// Most recent auto-merge timeline event as (event, actor, created_at).
    fn last_auto_merge_event(&self, _pr: u64, _repo: &str) -> Option<(String, String, String)> {
        None
    }
}

/// Reads through the `gh` CLI, optionally from a given directory (gh
/// resolves the repo from the checkout it runs in when `repo` is empty).
#[derive(Default)]
pub struct GhFetcher {
    pub cwd: Option<PathBuf>,
}

impl GhFetcher {
    fn gh(&self) -> Command {
        let mut cmd = Command::new("gh");
        if let Some(d) = &self.cwd {
            cmd.current_dir(d);
        }
        cmd.env("CHUMP_GH_CALL_CRITICALITY", "background");
        cmd
    }
}

impl PrHoldFetcher for GhFetcher {
    fn fetch(&self, selector: &str, repo: &str) -> Result<Value, String> {
        let mut cmd = self.gh();
        cmd.args(["pr", "view", selector]);
        if !repo.is_empty() {
            cmd.args(["--repo", repo]);
        }
        cmd.args(["--json", "number,labels,body,comments"]);
        let out = cmd.output().map_err(|e| format!("spawn gh: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "gh pr view {selector} exited {}",
                out.status.code().unwrap_or(-1)
            ));
        }
        serde_json::from_slice(&out.stdout).map_err(|e| format!("parse gh pr view: {e}"))
    }

    fn last_auto_merge_event(&self, pr: u64, repo: &str) -> Option<(String, String, String)> {
        let path = if repo.is_empty() {
            format!("repos/{{owner}}/{{repo}}/issues/{pr}/timeline")
        } else {
            format!("repos/{repo}/issues/{pr}/timeline")
        };
        let out = self
            .gh()
            .args(["api", &path, "--paginate", "--jq"])
            .arg(
                ".[] | select(.event == \"auto_merge_disabled\" or .event == \"auto_squash_enabled\" \
                 or .event == \"auto_merge_enabled\" or .event == \"auto_rebase_enabled\") \
                 | [.event, (.actor.login // \"\"), (.created_at // \"\")] | @tsv",
            )
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let last = text.lines().rfind(|l| !l.trim().is_empty())?;
        let mut parts = last.split('\t');
        Some((
            parts.next().unwrap_or("").to_string(),
            parts.next().unwrap_or("").to_string(),
            parts.next().unwrap_or("").to_string(),
        ))
    }
}

struct TestOverride {
    fetcher: Rc<dyn PrHoldFetcher>,
    ambient: PathBuf,
}

thread_local! {
    static OVERRIDE: RefCell<Option<TestOverride>> = const { RefCell::new(None) };
}

/// Guard returned by [`override_for_tests`]; restores the real fetcher on drop.
pub struct OverrideGuard(());

impl Drop for OverrideGuard {
    fn drop(&mut self) {
        OVERRIDE.with(|o| *o.borrow_mut() = None);
    }
}

/// Test hook: route every gate on THIS thread through `fetcher` and write
/// ambient events to `ambient`. Used by the per-call-site tests in other
/// crates, so it is public; production code never calls it.
#[doc(hidden)]
pub fn override_for_tests(fetcher: Rc<dyn PrHoldFetcher>, ambient: &Path) -> OverrideGuard {
    OVERRIDE.with(|o| {
        *o.borrow_mut() = Some(TestOverride {
            fetcher,
            ambient: ambient.to_path_buf(),
        })
    });
    OverrideGuard(())
}

fn current_fetcher(cwd: Option<&Path>) -> (Rc<dyn PrHoldFetcher>, Option<PathBuf>) {
    OVERRIDE.with(|o| match o.borrow().as_ref() {
        Some(t) => (Rc::clone(&t.fetcher), Some(t.ambient.clone())),
        None => (
            Rc::new(GhFetcher {
                cwd: cwd.map(Path::to_path_buf),
            }) as Rc<dyn PrHoldFetcher>,
            None,
        ),
    })
}

/// ambient.jsonl: `CHUMP_AMBIENT_LOG`, else `<git common dir>/../.chump-locks/ambient.jsonl`,
/// else `./.chump-locks/ambient.jsonl`.
pub fn default_ambient_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let common = Command::new("git")
        .args(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()));
    let root = common
        .and_then(|c| c.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."));
    root.join(".chump-locks").join("ambient.jsonl")
}

fn append_ambient(path: &Path, line: &str) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        Ok(mut f) => {
            let _ = writeln!(f, "{line}");
        }
        Err(e) => eprintln!(
            "[arm-policy] WARN: ambient write failed ({}): {e}",
            path.display()
        ),
    }
}

fn now_ts() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn pr_field(pr: &str) -> Value {
    pr.parse::<u64>()
        .map(Value::from)
        .unwrap_or_else(|_| Value::from(pr))
}

/// Is this PR held? Reads labels, body and comments through gh.
pub fn pr_is_held(pr: u64, repo: &str) -> Result<HoldStatus, ArmPolicyError> {
    pr_ref_is_held(&pr.to_string(), repo)
}

/// [`pr_is_held`] for a selector gh accepts (PR number, URL or branch).
pub fn pr_ref_is_held(selector: &str, repo: &str) -> Result<HoldStatus, ArmPolicyError> {
    let (fetcher, _) = current_fetcher(None);
    let v = fetcher.fetch(selector, repo).map_err(ArmPolicyError)?;
    hold_status_from_json(&v)
}

/// Gate an ARM of PR `pr`. `Err(ArmHeld)` = skip the arm (the refusal has
/// already been emitted as `kind=pr_arm_skipped_hold`).
pub fn require_arm_allowed(pr: u64, repo: &str, armer: &str) -> Result<(), ArmHeld> {
    require_allowed(&pr.to_string(), repo, armer, GateAction::Arm)
}

/// Gate a merge / rebase / force-push of PR `pr` (no re-arm audit).
pub fn require_touch_allowed(pr: u64, repo: &str, armer: &str) -> Result<(), ArmHeld> {
    require_allowed(&pr.to_string(), repo, armer, GateAction::Touch)
}

/// The gate, for any selector gh accepts (PR number, URL or branch name).
pub fn require_allowed(
    selector: &str,
    repo: &str,
    armer: &str,
    action: GateAction,
) -> Result<(), ArmHeld> {
    require_allowed_at(selector, repo, armer, action, None)
}

/// [`require_allowed`] with gh run from `cwd` (the checkout whose repo an
/// empty `repo` means).
pub fn require_allowed_at(
    selector: &str,
    repo: &str,
    armer: &str,
    action: GateAction,
    cwd: Option<&Path>,
) -> Result<(), ArmHeld> {
    let (fetcher, ambient_override) = current_fetcher(cwd);
    let ambient = || {
        ambient_override
            .clone()
            .unwrap_or_else(default_ambient_path)
    };
    let payload = match fetcher.fetch(selector, repo) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[arm-policy] WARN: PR {selector}: could not read labels/body/comments ({e}); failing open");
            return Ok(());
        }
    };
    let pr_label = payload
        .get("number")
        .and_then(Value::as_u64)
        .map(|n| n.to_string())
        .unwrap_or_else(|| selector.to_string());
    match hold_status_from_json(&payload) {
        Err(e) => {
            eprintln!("[arm-policy] WARN: PR {selector}: {e}; failing open");
            Ok(())
        }
        Ok(HoldStatus::Held(reason)) => {
            // Literal kind for the event-registry scanner (serde_json::json! below
            // formats it with a space):
            // scanner-anchor: "kind":"pr_arm_skipped_hold" (registered in docs/observability/EVENT_REGISTRY.yaml, RESILIENT-1613 / INFRA-8221)
            let ev = serde_json::json!({
                "ts": now_ts(),
                "kind": "pr_arm_skipped_hold",
                "pr": pr_field(&pr_label),
                "armer": armer,
                "reason": reason.to_string(),
                "source": "gh",
            });
            append_ambient(&ambient(), &ev.to_string());
            let held = ArmHeld {
                pr: pr_label,
                armer: armer.to_string(),
                reason,
            };
            eprintln!("[arm-policy] {held}");
            Err(held)
        }
        Ok(HoldStatus::NotHeld) => {
            if action == GateAction::Arm
                && std::env::var("CHUMP_ARM_POLICY_REARM_AUDIT").as_deref() != Ok("0")
            {
                if let Ok(n) = pr_label.parse::<u64>() {
                    if let Some((ev, actor, at)) = fetcher.last_auto_merge_event(n, repo) {
                        if ev == "auto_merge_disabled" {
                            // scanner-anchor: "kind":"pr_rearmed" (registered in docs/observability/EVENT_REGISTRY.yaml, RESILIENT-1613 / INFRA-8221)
                            let line = serde_json::json!({
                                "ts": now_ts(),
                                "kind": "pr_rearmed",
                                "pr": n,
                                "armer": armer,
                                "disarm_actor": actor,
                                "disarmed_at": at,
                            });
                            append_ambient(&ambient(), &line.to_string());
                            eprintln!("[arm-policy] PR #{n}: re-arm by {armer} after a disarm by {actor} at {at} (kind=pr_rearmed)");
                        }
                    }
                }
            }
            Ok(())
        }
    }
}

/// Shared test fixtures: a scripted fetcher. Public so the per-call-site
/// tests in other crates can use it.
#[doc(hidden)]
pub mod testing {
    use super::*;
    use std::cell::Cell;

    /// Returns a fixed payload (or error) and counts calls.
    pub struct FakeFetcher {
        pub payload: Result<Value, String>,
        pub last_event: Option<(String, String, String)>,
        pub calls: Cell<u32>,
    }

    impl FakeFetcher {
        pub fn held_by_label(label: &str) -> Rc<Self> {
            Rc::new(Self {
                payload: Ok(serde_json::json!({
                    "number": 4242,
                    "labels": [{"name": label}],
                    "body": "",
                    "comments": [],
                })),
                last_event: None,
                calls: Cell::new(0),
            })
        }
        pub fn clean() -> Rc<Self> {
            Rc::new(Self {
                payload: Ok(serde_json::json!({
                    "number": 4242, "labels": [], "body": "plain", "comments": [],
                })),
                last_event: None,
                calls: Cell::new(0),
            })
        }
    }

    impl PrHoldFetcher for FakeFetcher {
        fn fetch(&self, _selector: &str, _repo: &str) -> Result<Value, String> {
            self.calls.set(self.calls.get() + 1);
            self.payload.clone()
        }
        fn last_auto_merge_event(&self, _pr: u64, _repo: &str) -> Option<(String, String, String)> {
            self.last_event.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::FakeFetcher;
    use super::*;
    use serde_json::json;
    use std::cell::Cell;

    fn status(v: Value) -> HoldStatus {
        hold_status_from_json(&v).unwrap()
    }

    #[test]
    fn each_hold_label_holds_case_insensitively() {
        for l in [
            "no-auto-merge",
            "No-Auto-Merge",
            "hold",
            "HOLD",
            "do-not-merge",
            "CHUMP_HOLD",
            "chump_hold",
        ] {
            assert_eq!(
                status(json!({"labels": [{"name": "pr:parallel-safe"}, {"name": l}], "body": ""})),
                HoldStatus::Held(HoldReason::Label(l.to_string())),
                "label {l}"
            );
        }
    }

    #[test]
    fn body_marker_holds() {
        let s = status(
            json!({"labels": [], "body": "Summary\n  auto-merge: HOLD until CREDIBLE-1508"}),
        );
        assert_eq!(s, HoldStatus::Held(HoldReason::BodyMarker));
        assert_eq!(s.to_string_reason(), "marker:body");
    }

    #[test]
    fn comment_marker_holds_in_object_and_string_shapes() {
        assert_eq!(
            status(
                json!({"labels": [], "body": "plain", "comments": [{"body": "lgtm"}, {"body": "\tAuto-merge: hold"}]})
            ),
            HoldStatus::Held(HoldReason::CommentMarker)
        );
        assert_eq!(
            status(json!({"body": "", "comments": ["Auto-merge:hold"]})),
            HoldStatus::Held(HoldReason::CommentMarker)
        );
    }

    #[test]
    fn unheld_and_near_misses_are_not_held() {
        assert_eq!(
            status(
                json!({"labels": [{"name": "holdover"}], "body": "plain", "comments": [{"body": "lgtm"}]})
            ),
            HoldStatus::NotHeld
        );
        // `holding` is not `hold\b`; a marker mid-line is not a marker line.
        assert_eq!(
            status(json!({"body": "Auto-merge: holding pattern explained"})),
            HoldStatus::NotHeld
        );
        assert_eq!(
            status(json!({"body": "Architect said Auto-merge: hold"})),
            HoldStatus::NotHeld
        );
        assert_eq!(status(json!({})), HoldStatus::NotHeld);
        assert!(hold_status_from_json(&json!([1, 2])).is_err());
    }

    #[test]
    fn marker_line_matcher() {
        assert!(line_is_hold_marker("Auto-merge: hold"));
        assert!(line_is_hold_marker("  auto-merge:hold."));
        assert!(line_is_hold_marker("AUTO-MERGE:\t HOLD (architect)"));
        assert!(!line_is_hold_marker("Auto-merge: hold_x"));
        assert!(!line_is_hold_marker("Auto-merge: holds"));
        assert!(!line_is_hold_marker("> Auto-merge: hold"));
    }

    #[test]
    fn gate_refuses_held_pr_and_emits_pr_arm_skipped_hold() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = FakeFetcher::held_by_label("no-auto-merge");
        let _g = override_for_tests(fake.clone(), &amb);
        let err = require_arm_allowed(4242, "o/r", "unit-armer").unwrap_err();
        assert_eq!(err.reason, HoldReason::Label("no-auto-merge".into()));
        assert_eq!(err.pr, "4242");
        let text = std::fs::read_to_string(&amb).unwrap();
        let ev: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(ev["kind"], "pr_arm_skipped_hold");
        assert_eq!(ev["pr"], 4242);
        assert_eq!(ev["armer"], "unit-armer");
        assert_eq!(ev["reason"], "label:no-auto-merge");
        assert!(pr_is_held(4242, "o/r").unwrap().is_held());
        // A branch selector resolves the PR number from the payload.
        let err = require_allowed("chump/x", "", "unit-armer", GateAction::Touch).unwrap_err();
        assert_eq!(err.pr, "4242");
    }

    #[test]
    fn gate_allows_clean_pr_and_fails_open_on_read_error() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        {
            let _g = override_for_tests(FakeFetcher::clean(), &amb);
            assert!(require_arm_allowed(1, "", "a").is_ok());
            assert!(require_touch_allowed(1, "", "a").is_ok());
        }
        {
            let broken = Rc::new(FakeFetcher {
                payload: Err("gh down".into()),
                last_event: None,
                calls: Cell::new(0),
            });
            let _g = override_for_tests(broken, &amb);
            assert!(
                require_arm_allowed(1, "", "a").is_ok(),
                "read failure must fail open"
            );
            assert!(pr_is_held(1, "").is_err());
        }
        assert!(!amb.exists(), "no event for allowed / fail-open arms");
    }

    #[test]
    fn arm_after_disarm_emits_pr_rearmed_but_touch_does_not() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = Rc::new(FakeFetcher {
            payload: Ok(json!({"number": 102, "labels": [], "body": "", "comments": []})),
            last_event: Some((
                "auto_merge_disabled".into(),
                "architect".into(),
                "2026-10-17T02:27:18Z".into(),
            )),
            calls: Cell::new(0),
        });
        let _g = override_for_tests(fake, &amb);
        require_touch_allowed(102, "o/r", "rebaser").unwrap();
        assert!(!amb.exists(), "Touch never runs the re-arm audit");
        require_arm_allowed(102, "o/r", "unit-armer").unwrap();
        let ev: Value =
            serde_json::from_str(std::fs::read_to_string(&amb).unwrap().trim()).unwrap();
        assert_eq!(ev["kind"], "pr_rearmed");
        assert_eq!(ev["pr"], 102);
        assert_eq!(ev["disarm_actor"], "architect");
        assert_eq!(ev["disarmed_at"], "2026-10-17T02:27:18Z");
    }

    impl HoldStatus {
        fn to_string_reason(&self) -> String {
            match self {
                HoldStatus::Held(r) => r.to_string(),
                HoldStatus::NotHeld => String::new(),
            }
        }
    }
}
