//! INFRA-8198 — integration test asserting `chump dispatch`'s spawned work
//! child dies when dispatch does, instead of outliving its own budget
//! deadline unsupervised (the exact bug this gap closes: preflight printed,
//! `chump dispatch --auto-merge --backend headless` exited 0 with no
//! "[dispatch] ... duration=" line, while its `claude -p` child kept
//! running with PPID 1 for 25+ minutes past the 1800s budget).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use tempfile::TempDir;

fn get_chump_bin() -> &'static str {
    env!("CARGO_BIN_EXE_chump")
}

/// Fixture: an isolated git repo with an `origin` remote + `main` branch
/// (so `chump dispatch`'s worktree-creation step — `git worktree add <path>
/// -b <branch> origin/main` — has something to resolve), plus isolated
/// CHUMP_HOME/CHUMP_REPO state so gap reserve/dispatch don't touch the real
/// checkout's `.chump/state.db` (same isolation pattern as
/// tests/decomposed_auto_close_integration.rs, INFRA-8183).
struct Fixture {
    temp_dir: TempDir,
    repo: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp_dir = TempDir::new().expect("tempdir");
        let root = temp_dir.path();
        let origin = root.join("origin.git");
        let repo = root.join("repo");

        let status = Command::new("git")
            .args(["init", "--quiet", "--bare"])
            .arg(&origin)
            .status()
            .expect("spawn git init --bare");
        assert!(status.success(), "git init --bare origin failed");

        let status = Command::new("git")
            .args(["init", "--quiet", "-b", "main"])
            .arg(&repo)
            .status()
            .expect("spawn git init repo");
        assert!(status.success(), "git init repo failed");

        let run_git = |args: &[&str]| {
            let status = Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(args)
                .status()
                .expect("spawn git");
            assert!(status.success(), "git {args:?} failed");
        };

        run_git(&["config", "user.email", "infra-8198@test.invalid"]);
        run_git(&["config", "user.name", "infra-8198-test"]);
        fs::write(repo.join("README.md"), "infra-8198 fixture\n").expect("write README");
        run_git(&["add", "README.md"]);
        run_git(&["commit", "-q", "-m", "init"]);
        run_git(&[
            "remote",
            "add",
            "origin",
            origin.to_str().expect("origin path is utf8"),
        ]);
        run_git(&["push", "-q", "origin", "main"]);
        run_git(&["fetch", "-q", "origin"]);

        Self { temp_dir, repo }
    }

    /// A `chump` Command scoped to this fixture's isolated state —
    /// CHUMP_REPO/CHUMP_HOME/CHUMP_WORKTREE_ROOT all point at the fixture
    /// repo, never the real checkout's shared `.chump/state.db`.
    fn chump_cmd(&self) -> Command {
        let mut cmd = Command::new(get_chump_bin());
        cmd.current_dir(&self.repo)
            .env("CHUMP_REPO", &self.repo)
            .env("CHUMP_HOME", &self.repo)
            .env("CHUMP_WORKTREE_ROOT", &self.repo)
            .env("CHUMP_GAP_RESERVE_NO_SIMILARITY", "1");
        cmd
    }

    fn reserve_gap(&self) -> String {
        let out = self
            .chump_cmd()
            .args([
                "gap",
                "reserve",
                "--domain",
                "INFRA",
                "--title",
                "INFRA-8198 dispatch-child-lifetime fixture gap",
                "--priority",
                "P2",
                "--effort",
                "xs",
                "--force",
            ])
            .output()
            .expect("spawn chump gap reserve");
        assert!(
            out.status.success(),
            "gap reserve failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .find(|l| l.trim_start().starts_with("INFRA-"))
            .unwrap_or_else(|| {
                panic!(
                    "could not find reserved gap id in gap reserve output: {}",
                    String::from_utf8_lossy(&out.stdout)
                )
            })
            .trim()
            .to_string()
    }

    /// Writes a fake `claude` executable into a scratch bin dir on the
    /// fixture, returning `(bin_dir, pidfile_path)`. The fake `claude`
    /// writes its own pid to `pidfile_path`, then sleeps far longer than
    /// any budget this test configures — standing in for the real
    /// `claude -p` headless child INFRA-8198 found still running 25+
    /// minutes past its 1800s budget with no supervisor.
    fn write_fake_claude(&self) -> (PathBuf, PathBuf) {
        let bin_dir = self.temp_dir.path().join("fakebin");
        fs::create_dir_all(&bin_dir).expect("mkdir fakebin");
        let pidfile = self.temp_dir.path().join("claude.pid");
        let script = format!("#!/bin/sh\necho $$ > {}\nsleep 120\n", pidfile.display());
        let path = bin_dir.join("claude");
        fs::write(&path, script).expect("write fake claude script");
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mut perms = fs::metadata(&path).expect("stat fake claude").permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&path, perms).expect("chmod fake claude");
        }
        (bin_dir, pidfile)
    }
}

/// SAFETY: `kill(pid, 0)` sends no signal — it only probes whether `pid`
/// exists and is signalable. `pid` always comes from a pidfile this test
/// itself wrote, naming the fake `claude` process it spawned.
fn pid_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn prepend_path(bin_dir: &Path) -> String {
    format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

/// Test A (budget): dispatch under a 3s subagent budget should exit
/// non-zero quickly, print a `[dispatch] ... exit=` line with
/// `child_alive_at_exit=false`, and the fake `claude` child must not
/// survive it.
#[test]
fn ac1_budget_kill_reaps_the_whole_child() {
    let fixture = Fixture::new();
    let gap_id = fixture.reserve_gap();
    let (bin_dir, pidfile) = fixture.write_fake_claude();
    let path_var = prepend_path(&bin_dir);

    let start = Instant::now();
    let out = fixture
        .chump_cmd()
        .env("PATH", &path_var)
        .env("CHUMP_SUBAGENT_BUDGET_S", "3")
        .env("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S", "3")
        .args([
            "dispatch",
            &gap_id,
            "--backend",
            "headless",
            "--prompt",
            "x",
        ])
        .output()
        .expect("spawn chump dispatch");
    let elapsed = start.elapsed();

    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);

    assert!(
        !out.status.success(),
        "dispatch should exit non-zero under a 3s budget; stdout={stdout} stderr={stderr}"
    );
    assert!(
        elapsed < Duration::from_secs(60),
        "dispatch took {elapsed:?}, expected under 60s (budget=3s + grace=30s)"
    );
    assert!(
        stderr.contains("[dispatch] ") && stderr.contains("exit="),
        "stderr missing '[dispatch] ... exit=' line: {stderr}"
    );
    assert!(
        stderr.contains("child_alive_at_exit=false"),
        "stderr missing child_alive_at_exit=false: {stderr}"
    );

    assert!(
        pidfile.exists(),
        "fake claude never wrote its pidfile — dispatch never spawned it; stderr={stderr}"
    );
    let pid_str = fs::read_to_string(&pidfile).expect("read pidfile");
    let pid: u32 = pid_str
        .trim()
        .parse()
        .expect("pidfile should contain a pid");

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && pid_alive(pid) {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        !pid_alive(pid),
        "fake claude pid {pid} still alive 5s after dispatch exited"
    );
}

/// Test B (abrupt parent death): SIGKILL `chump dispatch` itself mid-flight
/// — `Drop` never runs on a SIGKILLed process, so only the kernel-enforced
/// `PR_SET_PDEATHSIG` backstop (Linux-only) can reap the fake `claude`
/// child here.
#[cfg(target_os = "linux")]
#[test]
fn ac2_parent_sigkill_still_reaps_child_via_pdeathsig() {
    let fixture = Fixture::new();
    let gap_id = fixture.reserve_gap();
    let (bin_dir, pidfile) = fixture.write_fake_claude();
    let path_var = prepend_path(&bin_dir);

    let mut child = fixture
        .chump_cmd()
        .env("PATH", &path_var)
        .env("CHUMP_SUBAGENT_BUDGET_S", "0")
        .env("CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S", "0")
        .env("CHUMP_DISPATCH_HANG_TIMEOUT_SECS", "0")
        .args([
            "dispatch",
            &gap_id,
            "--backend",
            "headless",
            "--prompt",
            "x",
        ])
        .spawn()
        .expect("spawn chump dispatch");

    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline && !pidfile.exists() {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        pidfile.exists(),
        "fake claude never wrote its pidfile within 30s"
    );
    let pid_str = fs::read_to_string(&pidfile).expect("read pidfile");
    let fake_claude_pid: u32 = pid_str
        .trim()
        .parse()
        .expect("pidfile should contain a pid");

    // SAFETY: killing our own just-spawned `chump dispatch` child process.
    unsafe {
        libc::kill(child.id() as libc::pid_t, libc::SIGKILL);
    }
    let _ = child.wait();

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && pid_alive(fake_claude_pid) {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        !pid_alive(fake_claude_pid),
        "fake claude pid {fake_claude_pid} survived a SIGKILL of its chump-dispatch parent"
    );
}
