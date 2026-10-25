//! CREDIBLE-1589 AC2 — drive a CHANGES-REQUIRED repair through the REAL claim
//! gate (gate 7, open-pr-for-gap = `dispatch_repair::open_pr_gate`) using the
//! real `chump` binary, with the work AGENT stubbed: `--print-prompt` resolves
//! the dispatch mode and prints the brief, then returns before any backend
//! spawns. No `claude -p` runs, no worktree is created.
//!
//! Why this test exists: the review organ's `scripts/ci/test-arm-policy.sh`
//! stubs `chump` as a bash `exit 0`, so claim gate 7 (Rust) never executes and
//! its "reached the PR branch" check was a `grep` on the stub's logged argv — a
//! string match, not a gate traversal. This test runs the real gate end to end.
//!
//! What it proves:
//!   * `--repair` is a REAL flag on `chump dispatch` (not a silently-ignored
//!     token): with an open PR for the gap, `--repair` admits the dispatch as a
//!     REPAIR onto the EXISTING PR head branch (DispatchMode::Repair), and the
//!     printed brief lands on that branch.
//!   * The explicit flag — NOT the banned `CHUMP_CLAIM_ALLOW_DUPLICATE_PR` env
//!     default — is what authorizes it: the positive run never sets that env var
//!     (it is even removed from the child env).
//!   * The flag is load-bearing (built-in mutant): the identical dispatch
//!     WITHOUT `--repair` and WITHOUT the env var is refused by the gate
//!     (exit 1, "Pass --repair ..."), never landing on the PR branch.
//!
//! Run: cargo test --test dispatch_repair_gate

use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

const GAP: &str = "CREDIBLE-1589";
const PR_BRANCH: &str = "claude/credible-1589";

fn chump_bin() -> &'static str {
    env!("CARGO_BIN_EXE_chump")
}

/// An isolated git repo so `repo_path::main_checkout_root()` resolves inside
/// the sandbox (via `git rev-parse --git-common-dir`) and never the real
/// checkout's shared `.chump/state.db`.
fn init_repo(dir: &Path) {
    let run_git = |args: &[&str]| {
        let st = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .status()
            .expect("spawn git");
        assert!(st.success(), "git {args:?} failed");
    };
    run_git(&["init", "--quiet", "-b", "main"]);
    run_git(&["config", "user.email", "credible-1589@test.invalid"]);
    run_git(&["config", "user.name", "credible-1589-test"]);
    fs::write(dir.join("README.md"), "credible-1589 fixture\n").expect("write README");
    run_git(&["add", "README.md"]);
    run_git(&["commit", "-q", "-m", "init"]);
}

/// A fake `gh` that reports exactly one OPEN PR covering the gap (so the real
/// gate 7 finds it) and no failing checks. Returned on a `bin` dir meant to be
/// prepended to PATH.
fn write_fake_gh(bin_dir: &Path) {
    fs::create_dir_all(bin_dir).expect("mkdir fakebin");
    // `gh pr list ...` (the gate's open-PR search) → one PR for the gap, whose
    // title names the gap and whose head branch is the gap's branch.
    // `gh pr checks <N> ...` (repair-brief failing-check lookup) → none.
    let script = format!(
        "#!/bin/sh\ncase \"$1 $2\" in\n\
         'pr list') printf '%s\\n' '[{{\"number\":5473,\"title\":\"{gap}: organ repair path\",\"headRefName\":\"{branch}\",\"headRefOid\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\"}}]' ;;\n\
         'pr checks') printf '%s\\n' '[]' ;;\n\
         *) printf '%s\\n' '[]' ;;\n\
         esac\nexit 0\n",
        gap = GAP,
        branch = PR_BRANCH,
    );
    let path = bin_dir.join("gh");
    fs::write(&path, script).expect("write fake gh");
    use std::os::unix::fs::PermissionsExt as _;
    let mut perms = fs::metadata(&path).expect("stat fake gh").permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&path, perms).expect("chmod fake gh");
}

/// Run the real `chump dispatch ... --print-prompt` against the fixture, with
/// the fake `gh` on PATH and all chump state isolated to `repo`. The child env
/// never carries `CHUMP_CLAIM_ALLOW_DUPLICATE_PR` — the gate must rely on the
/// explicit flag alone.
fn run_dispatch(repo: &Path, bin_dir: &Path, with_repair: bool) -> Output {
    let path_var = format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut cmd = Command::new(chump_bin());
    cmd.current_dir(repo)
        .env("PATH", path_var)
        .env("CHUMP_REPO", repo)
        .env("CHUMP_HOME", repo)
        .env("CHUMP_WORKTREE_ROOT", repo)
        // The gate must be authorized by the flag, never an ambient env
        // default — scrub the legacy bypass out of the child env.
        .env_remove("CHUMP_CLAIM_ALLOW_DUPLICATE_PR");
    cmd.args(["dispatch", GAP, "--backend", "headless"]);
    if with_repair {
        cmd.arg("--repair");
    }
    cmd.arg("--print-prompt");
    cmd.output().expect("spawn chump dispatch")
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}
fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

#[test]
fn repair_flag_admits_repair_onto_pr_head_branch() {
    let tmp = TempDir::new().expect("tempdir");
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();
    init_repo(&repo);
    let bin_dir = tmp.path().join("fakebin");
    write_fake_gh(&bin_dir);

    // ── Positive: --repair admits a REPAIR that lands on the PR head branch ──
    let ok = run_dispatch(&repo, &bin_dir, true);
    let out = stdout(&ok);
    let err = stderr(&ok);
    assert!(
        ok.status.success(),
        "`chump dispatch {GAP} --repair --print-prompt` should exit 0 (gate admits repair); \
         status={:?}\nstdout={out}\nstderr={err}",
        ok.status.code()
    );
    // DispatchMode::Repair was selected (not Work).
    assert!(
        out.contains("mode=Repair"),
        "resolved mode should be Repair; stdout={out}\nstderr={err}"
    );
    // The repair reached the EXISTING PR head branch: the printed brief tells
    // the agent the worktree is checked out on that branch, and the gate's
    // "repairing on <branch>" line names it.
    assert!(
        out.contains(PR_BRANCH),
        "repair brief should reference the PR head branch `{PR_BRANCH}`; stdout={out}"
    );
    assert!(
        err.contains("repairing on") && err.contains(PR_BRANCH),
        "gate should log `repairing on {PR_BRANCH}`; stderr={err}"
    );
    // Authorized by the explicit flag, not the ambient env default.
    assert!(
        err.contains("--repair"),
        "gate should report the --repair flag as the trigger; stderr={err}"
    );
    assert!(
        !err.contains("CHUMP_CLAIM_ALLOW_DUPLICATE_PR=1"),
        "repair must not be attributed to the banned env default; stderr={err}"
    );

    // ── Built-in mutant: the flag is load-bearing. Same dispatch WITHOUT
    //    --repair (and with the env scrubbed) → the real gate 7 refuses, so
    //    the work never lands on the PR branch. If --repair were a no-op, this
    //    would also be admitted and the assertion below would fail. ──
    let refused = run_dispatch(&repo, &bin_dir, false);
    let rerr = stderr(&refused);
    assert!(
        !refused.status.success(),
        "without --repair the gate should refuse (exit non-zero); status={:?}\nstderr={rerr}",
        refused.status.code()
    );
    assert!(
        rerr.contains("Refusing to spawn") && rerr.contains("--repair"),
        "refusal should name the open PR and point at --repair; stderr={rerr}"
    );
}
