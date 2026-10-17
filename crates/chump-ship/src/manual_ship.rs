//! `ManualShipPath` — happy-path manual ship executor (INFRA-2001 Phase 2).
//!
//! Implements [`crate::ship::Ship`] for the manual ship flavour. This is
//! the path agent-initiated ships take ~80% of the time: agent has
//! finished work, push branch + open PR + arm auto-merge.
//!
//! ## Single-instance by construction (fixes INFRA-1532)
//!
//! On `[ManualShipPath::new]`, the executor binds a Unix domain socket
//! at `/tmp/chump-ship-{session_id}.sock`. If another `ManualShipPath`
//! for the same `session_id` already holds the socket, `bind` returns
//! `EADDRINUSE` and `new()` returns [`ShipError::BotMergeDoubleInstance`].
//!
//! This replaces the prior convention-based check (the bash callsite
//! cooperated by checking for a pidfile, but two scripts racing past
//! the check could both proceed). With a kernel-enforced socket bind,
//! the second instance is rejected atomically — no operator discipline
//! required, no convention to violate.
//!
//! The socket is dropped (via [`UnixListener`]'s `Drop`) when the
//! executor falls out of scope. The socket file itself is cleaned up
//! in [`ManualShipPath::drop`].
//!
//! ## Subprocess vs library
//!
//! Phase 1 uses **subprocess** `git` + `gh` (via `tokio::process::Command`
//! with `env_clear` for the leak-class vars, mirroring INFRA-1997 chump-
//! git-hooks). The alternative — `octocrab` + `git2` — would pull in
//! ~50 transitive deps and increase compile-time substantially for
//! capability that subprocesses already provide. Tracked as a Phase 2
//! follow-up if/when richer integration is needed.
//!
//! ## Phase 1 happy-path only
//!
//! No retries. No conflict-recovery. No `--stack-on`. No `--force-with-lease`
//! race handling. Those live in `scripts/coord/bot-merge.sh` for now;
//! Phase 2 sub-gap will port them.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use chrono::Utc;
use tokio::net::UnixListener;
use tokio::process::Command;

use crate::ship::{
    truncate_for_log, PreflightGate, PreflightReport, Ship, ShipError, ShipIntent, ShipReceipt,
};

/// Env vars that can redirect git/gh to the wrong repo or org. Mirrors
/// the chump-git-hooks `ENV_LEAK_VARS` list — every subprocess we spawn
/// strips these on the `Command` to prevent inherited GitHub Actions
/// runner state from misdirecting our calls.
const ENV_LEAK_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GITHUB_WORKSPACE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
];

/// Manual ship executor — pushes branch + opens PR + arms auto-merge.
///
/// Construct via [`ManualShipPath::new`]; constructor binds the
/// single-instance socket so a second `new()` for the same session id
/// fails fast with [`ShipError::BotMergeDoubleInstance`].
pub struct ManualShipPath {
    intent: ShipIntent<'static>,
    /// Absolute path to the repo root. The executor invokes `git -C` and
    /// `gh` from this directory.
    repo_root: PathBuf,
    /// Single-instance guard. Held until Drop so the socket file lives
    /// for the duration of the ship. Field is read at drop time.
    _socket_guard: SingleInstanceGuard,
    /// If true, [`Ship::ship`] returns a synthesized receipt without
    /// actually pushing or calling GitHub. Smoke tests + dry-runs use
    /// this; production ships pass `false`.
    dry_run: bool,
}

/// RAII wrapper that holds the bound socket + path-to-clean-up-on-drop.
struct SingleInstanceGuard {
    _listener: UnixListener,
    socket_path: PathBuf,
}

impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        // Best-effort cleanup of the socket file. Failure to remove is
        // tolerable — the next process will simply rebind a fresh node.
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

impl ManualShipPath {
    /// Construct a new executor. Binds the single-instance socket at
    /// `/tmp/chump-ship-{session_id}.sock` — returns
    /// [`ShipError::BotMergeDoubleInstance`] if another process already
    /// holds it.
    ///
    /// `repo_root` is the working directory for subprocess `git`+`gh`.
    /// `dry_run=true` skips the push + PR-create + arm-auto-merge calls
    /// and returns a synthesized receipt instead (for smoke tests).
    pub fn new(
        intent: ShipIntent<'static>,
        repo_root: impl AsRef<Path>,
        dry_run: bool,
    ) -> Result<Self, ShipError> {
        let socket_path = socket_path_for(&intent.session_id);

        // EADDRINUSE on bind → another instance is alive. Some platforms
        // (Linux) leave a stale socket node on crash, so we attempt to
        // unlink first IFF the file exists AND nothing is listening on it.
        //
        // The probe-and-unlink IS racy in principle, but the kernel-enforced
        // semantic we want is: "two ManualShipPath::new() calls for the
        // same session id, racing, AT MOST ONE wins." The probe step
        // doesn't undermine that — whichever caller wins the subsequent
        // bind() is the live instance.
        if socket_path.exists() {
            // Try to connect; if connect succeeds, somebody is listening
            // → genuine collision. If it fails, the socket is stale.
            match std::os::unix::net::UnixStream::connect(&socket_path) {
                Ok(_) => {
                    return Err(ShipError::BotMergeDoubleInstance {
                        detail: format!(
                            "socket {} already bound by an active ManualShipPath \
                             (session_id={}). Another ship is in flight for this session.",
                            socket_path.display(),
                            intent.session_id
                        ),
                    });
                }
                Err(_) => {
                    // Stale socket → remove and continue to bind below.
                    let _ = std::fs::remove_file(&socket_path);
                }
            }
        }

        let listener = match UnixListener::bind(&socket_path) {
            Ok(l) => l,
            Err(err) if err.kind() == std::io::ErrorKind::AddrInUse => {
                return Err(ShipError::BotMergeDoubleInstance {
                    detail: format!(
                        "socket {} bind failed with EADDRINUSE — concurrent ManualShipPath \
                         instance for session_id={}",
                        socket_path.display(),
                        intent.session_id
                    ),
                });
            }
            Err(err) => return Err(ShipError::Io(err)),
        };

        Ok(ManualShipPath {
            intent,
            repo_root: repo_root.as_ref().to_path_buf(),
            _socket_guard: SingleInstanceGuard {
                _listener: listener,
                socket_path,
            },
            dry_run,
        })
    }

    /// Construct a `Command` for invoking `git` from `repo_root` with the
    /// leak-class env vars stripped. Mirrors `HookContext::git()` from
    /// chump-git-hooks (INFRA-1997).
    fn git(&self) -> Command {
        let mut cmd = Command::new("git");
        for v in ENV_LEAK_VARS {
            cmd.env_remove(v);
        }
        cmd.arg("-C").arg(&self.repo_root);
        cmd
    }

    /// Same as [`Self::git`] but for `gh`.
    fn gh(&self) -> Command {
        let mut cmd = Command::new("gh");
        for v in ENV_LEAK_VARS {
            cmd.env_remove(v);
        }
        cmd.current_dir(&self.repo_root);
        cmd
    }

    /// Pre-flight gate: branch exists locally.
    async fn gate_branch_exists(&self) -> PreflightGate {
        let out = self
            .git()
            .args([
                "rev-parse",
                "--verify",
                &format!("refs/heads/{}", self.intent.branch),
            ])
            .output()
            .await;
        match out {
            Ok(o) if o.status.success() => PreflightGate {
                name: "branch_exists".into(),
                passed: true,
                detail: String::new(),
            },
            Ok(o) => PreflightGate {
                name: "branch_exists".into(),
                passed: false,
                detail: format!(
                    "branch `{}` not found (rc={}): {}",
                    self.intent.branch,
                    o.status.code().unwrap_or(-1),
                    truncate_for_log(&String::from_utf8_lossy(&o.stderr), 240),
                ),
            },
            Err(err) => PreflightGate {
                name: "branch_exists".into(),
                passed: false,
                detail: format!("failed to run git rev-parse: {err}"),
            },
        }
    }

    /// Pre-flight gate: branch is ahead of base (something to ship).
    async fn gate_ahead_of_base(&self) -> PreflightGate {
        let revspec = format!("origin/{}..{}", self.intent.base, self.intent.branch);
        let out = self
            .git()
            .args(["rev-list", "--count", &revspec])
            .output()
            .await;
        match out {
            Ok(o) if o.status.success() => {
                let count_str = String::from_utf8_lossy(&o.stdout).trim().to_string();
                let count: u64 = count_str.parse().unwrap_or(0);
                if count > 0 {
                    PreflightGate {
                        name: "ahead_of_base".into(),
                        passed: true,
                        detail: String::new(),
                    }
                } else {
                    PreflightGate {
                        name: "ahead_of_base".into(),
                        passed: false,
                        detail: format!(
                            "branch `{}` is not ahead of `origin/{}` — nothing to ship",
                            self.intent.branch, self.intent.base
                        ),
                    }
                }
            }
            Ok(o) => PreflightGate {
                name: "ahead_of_base".into(),
                passed: false,
                detail: format!(
                    "git rev-list failed (rc={}): {}",
                    o.status.code().unwrap_or(-1),
                    truncate_for_log(&String::from_utf8_lossy(&o.stderr), 240),
                ),
            },
            Err(err) => PreflightGate {
                name: "ahead_of_base".into(),
                passed: false,
                detail: format!("failed to run git rev-list: {err}"),
            },
        }
    }

    /// Push the branch with `--force-with-lease`. Phase 1 happy-path:
    /// no retry on lease rejection — caller falls back to bash if so.
    async fn push_branch(&self) -> Result<(), ShipError> {
        if self.dry_run {
            tracing::info!(
                branch = %self.intent.branch,
                "[dry-run] skipping git push --force-with-lease"
            );
            return Ok(());
        }
        let out = self
            .git()
            .args([
                "push",
                "-u",
                "origin",
                self.intent.branch.as_ref(),
                "--force-with-lease",
            ])
            .output()
            .await?;
        if !out.status.success() {
            return Err(ShipError::Git {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        Ok(())
    }

    /// Open the PR via `gh pr create`. Returns the parsed PR number + URL.
    async fn create_pr(&self) -> Result<(u64, String), ShipError> {
        if self.dry_run {
            tracing::info!(
                gap = %self.intent.gap_id,
                "[dry-run] skipping gh pr create"
            );
            return Ok((
                0,
                format!(
                    "https://github.com/dry-run/dry-run/pull/0 (gap={})",
                    self.intent.gap_id
                ),
            ));
        }
        let title = self.intent.commit_message.to_string();
        let body = format!(
            "Automated ship for {gap}.\n\n\
             Generated by chump-ship (INFRA-2001 Phase 2 — ManualShipPath).",
            gap = self.intent.gap_id
        );
        let out = self
            .gh()
            .args([
                "pr",
                "create",
                "--base",
                self.intent.base.as_ref(),
                "--head",
                self.intent.branch.as_ref(),
                "--title",
                &title,
                "--body",
                &body,
            ])
            .output()
            .await?;
        if !out.status.success() {
            return Err(ShipError::Gh {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
        // `gh pr create` prints the PR URL on stdout, last line of output.
        let url = stdout
            .lines()
            .rev()
            .find(|l| l.starts_with("http"))
            .ok_or_else(|| ShipError::UnparseablePrNumber {
                raw: stdout.clone(),
            })?
            .to_string();
        let pr_num = parse_pr_number_from_url(&url)
            .ok_or(ShipError::UnparseablePrNumber { raw: url.clone() })?;
        Ok((pr_num, url))
    }

    /// Resolve the head SHA of the local branch after push.
    async fn resolve_head_sha(&self) -> Result<String, ShipError> {
        if self.dry_run {
            return Ok("dryrun0000000000000000000000000000000000".to_string());
        }
        let out = self
            .git()
            .args(["rev-parse", self.intent.branch.as_ref()])
            .output()
            .await?;
        if !out.status.success() {
            return Err(ShipError::Git {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    /// Arm GitHub auto-merge (`--auto --squash`). Returns false if the
    /// arm subcommand failed in a non-fatal way (secondary rate limit
    /// is the common case); operator can re-arm manually.
    async fn arm_auto_merge(&self, pr_number: u64) -> Result<bool, ShipError> {
        if self.dry_run {
            tracing::info!(pr = pr_number, "[dry-run] skipping auto-merge arm");
            return Ok(true);
        }
        // INFRA-8221: the one arm policy. A held PR (no-auto-merge label or an
        // `Auto-merge: hold` line, possibly carried in from the intent's body)
        // is left unarmed; not-armed is already a non-fatal outcome here.
        if let Err(held) = crate::arm_policy::require_allowed_at(
            &pr_number.to_string(),
            "",
            "chump-ship(manual_ship)",
            crate::arm_policy::GateAction::Arm,
            Some(&self.repo_root),
        ) {
            tracing::warn!(pr = pr_number, %held, "arm policy: PR held; not arming");
            return Ok(false);
        }
        let out = self
            .gh()
            .args(["pr", "merge", &pr_number.to_string(), "--auto", "--squash"])
            .output()
            .await?;
        if !out.status.success() {
            // Phase 1 happy-path: log + return false (not-armed) rather
            // than fail the whole ship. The PR is up; operator can arm.
            tracing::warn!(
                pr = pr_number,
                rc = out.status.code().unwrap_or(-1),
                stderr_tail = %truncate_for_log(&String::from_utf8_lossy(&out.stderr), 240),
                "auto-merge arm failed; PR open but not armed"
            );
            return Ok(false);
        }
        Ok(true)
    }
}

#[async_trait]
impl Ship for ManualShipPath {
    fn intent(&self) -> &ShipIntent<'_> {
        &self.intent
    }

    async fn preflight(&self) -> Result<PreflightReport, ShipError> {
        let gates = vec![
            self.gate_branch_exists().await,
            self.gate_ahead_of_base().await,
        ];
        Ok(PreflightReport { gates })
    }

    async fn ship(&self) -> Result<ShipReceipt, ShipError> {
        // 1. Run preflight + short-circuit on first failure.
        let report = self.preflight().await?;
        if !report.all_passed() {
            let fail = report
                .first_failure()
                .expect("all_passed=false implies a failure exists");
            return Err(ShipError::PreflightFailed {
                gate_name: fail.name.clone(),
                detail: fail.detail.clone(),
            });
        }

        // 2. Push the branch.
        self.push_branch().await?;

        // 3. Open the PR.
        let (pr_number, pr_url) = self.create_pr().await?;

        // 4. Resolve head SHA for the receipt.
        let head_sha = self.resolve_head_sha().await?;

        // 5. Arm auto-merge.
        let auto_merge_armed = self.arm_auto_merge(pr_number).await?;

        Ok(ShipReceipt {
            pr_number,
            pr_url,
            head_sha,
            auto_merge_armed,
            shipped_at: Utc::now(),
        })
    }
}

/// Resolve the socket path for a given session id.
///
/// Exposed pub-crate so the smoke test can probe the path.
pub(crate) fn socket_path_for(session_id: &str) -> PathBuf {
    // Sanitize: replace path-separator chars in session id to avoid
    // accidental directory traversal. Session ids in practice are
    // `claim-infra-NNNN-PID-TS` shaped — all safe — but defensive.
    let safe = session_id.replace(['/', '\\'], "_");
    PathBuf::from(format!("/tmp/chump-ship-{}.sock", safe))
}

/// Extract a PR number from a GitHub PR URL like
/// `https://github.com/owner/repo/pull/1913`.
fn parse_pr_number_from_url(url: &str) -> Option<u64> {
    url.rsplit('/').next().and_then(|seg| seg.parse().ok())
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn unique_session_id(label: &str) -> String {
        format!(
            "test-{label}-{pid}-{ts}",
            label = label,
            pid = std::process::id(),
            ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )
    }

    #[test]
    fn parse_pr_number_typical_url() {
        let n = parse_pr_number_from_url("https://github.com/foo/bar/pull/1913");
        assert_eq!(n, Some(1913));
    }

    #[test]
    fn parse_pr_number_garbage_returns_none() {
        let n = parse_pr_number_from_url("not a url");
        assert_eq!(n, None);
    }

    #[test]
    fn socket_path_sanitizes_slashes() {
        let p = socket_path_for("a/b\\c");
        let lossy = p.to_string_lossy();
        assert!(lossy.contains("a_b_c"));
        // Any '/' that remains must be from the "/tmp/" prefix only.
        if lossy.contains('/') {
            assert!(lossy.starts_with("/tmp/"));
        }
    }

    #[tokio::test]
    async fn new_binds_socket() {
        let tmp = TempDir::new().unwrap();
        let session = unique_session_id("bind");
        let intent = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", session.clone());
        let _shipper = ManualShipPath::new(intent, tmp.path(), true).expect("bind");
        // The socket should exist on disk.
        let p = socket_path_for(&session);
        assert!(p.exists(), "socket file should exist after bind: {:?}", p);
    }

    #[tokio::test]
    async fn double_instance_is_refused() {
        let tmp = TempDir::new().unwrap();
        let session = unique_session_id("double");
        let intent1 = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", session.clone());
        let intent2 = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", session.clone());
        // First shipper binds the socket.
        let _first = ManualShipPath::new(intent1, tmp.path(), true).expect("first bind");
        // Second shipper for same session id must be refused.
        let result = ManualShipPath::new(intent2, tmp.path(), true);
        match result {
            Err(ShipError::BotMergeDoubleInstance { detail }) => {
                assert!(
                    detail.contains(&session),
                    "diagnostic should mention session id: {detail}"
                );
            }
            Err(other) => panic!("expected BotMergeDoubleInstance, got error: {other}"),
            Ok(_) => panic!("expected BotMergeDoubleInstance, got Ok"),
        }
    }

    #[tokio::test]
    async fn socket_freed_on_drop_allows_rebind() {
        let tmp = TempDir::new().unwrap();
        let session = unique_session_id("rebind");
        let intent1 = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", session.clone());
        let p = socket_path_for(&session);
        {
            let _first = ManualShipPath::new(intent1, tmp.path(), true).expect("first bind");
            assert!(p.exists());
        } // _first dropped here.
          // Socket file should be cleaned up (Drop on SingleInstanceGuard).
        assert!(
            !p.exists(),
            "socket should be cleaned up on drop, but still exists: {:?}",
            p
        );
        // A new shipper for the same session id can rebind.
        let intent2 = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", session.clone());
        let _second = ManualShipPath::new(intent2, tmp.path(), true).expect("rebind after drop");
        assert!(p.exists());
    }

    #[tokio::test]
    async fn preflight_fails_when_branch_missing() {
        // A fresh temp dir is not a git repo — `git rev-parse` will fail.
        let tmp = TempDir::new().unwrap();
        let session = unique_session_id("nobranch");
        let intent = ShipIntent::owned(
            "INFRA-TEST",
            "this-branch-doesnt-exist",
            "main",
            "msg",
            session,
        );
        let shipper = ManualShipPath::new(intent, tmp.path(), true).expect("bind");
        let report = shipper.preflight().await.expect("preflight runs");
        assert!(!report.all_passed());
        let first = report.first_failure().unwrap();
        // The first gate is branch_exists, so that one should fail.
        assert_eq!(first.name, "branch_exists");
    }

    #[tokio::test]
    async fn ship_short_circuits_on_preflight_failure() {
        let tmp = TempDir::new().unwrap();
        let session = unique_session_id("preflight-fail");
        let intent = ShipIntent::owned("INFRA-TEST", "missing-branch", "main", "msg", session);
        let shipper = ManualShipPath::new(intent, tmp.path(), true).expect("bind");
        let result = shipper.ship().await;
        match result {
            Err(ShipError::PreflightFailed { gate_name, .. }) => {
                assert_eq!(gate_name, "branch_exists");
            }
            other => panic!("expected PreflightFailed, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn ship_intent_accessor_returns_inner_intent() {
        let tmp = TempDir::new().unwrap();
        let session = unique_session_id("accessor");
        let intent = ShipIntent::owned("INFRA-X", "b", "main", "msg", session);
        let shipper = ManualShipPath::new(intent, tmp.path(), true).expect("bind");
        assert_eq!(&*shipper.intent().gap_id, "INFRA-X");
        assert_eq!(&*shipper.intent().branch, "b");
    }

    /// INFRA-8221: a held PR is refused by arm_auto_merge before any gh call
    /// (the pr_arm_skipped_hold event is only written by the gate).
    #[tokio::test]
    async fn arm_auto_merge_refuses_held_pr() {
        let tmp = TempDir::new().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = crate::arm_policy::testing::FakeFetcher::held_by_label("no-auto-merge");
        let _g = crate::arm_policy::override_for_tests(fake.clone(), &amb);
        let session = unique_session_id("held");
        let intent = ShipIntent::owned("INFRA-8221", "b", "main", "msg", session);
        let shipper = ManualShipPath::new(intent, tmp.path(), false).expect("bind");
        let armed = shipper.arm_auto_merge(4242).await.expect("non-fatal");
        assert!(!armed, "held PR must not be armed");
        assert_eq!(fake.calls.get(), 1);
        let ev = std::fs::read_to_string(&amb).unwrap();
        assert!(ev.contains("\"kind\":\"pr_arm_skipped_hold\""), "{ev}");
        assert!(ev.contains("chump-ship(manual_ship)"), "{ev}");
    }
}
