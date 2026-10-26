//! CREDIBLE-096 / CREDIBLE-102 / CREDIBLE-104: `chump external verify-merge` — autonomous PR merge judge.
//!
//! Trust keystone for Chump's "autonomously improve someone's repo, no human
//! in the loop" mission. Decides whether a PR on an external repo meets the
//! bar for an autonomous merge, then optionally executes it.
//!
//! ## Gates (ALL must pass to merge)
//!
//! 0. **Comprehension organs (opt-in, INFRA-3470)** — when
//!    `CHUMP_VERIFY_COMPREHEND_GATE=1`, runs the comprehend organs
//!    (`crate::comprehend_gate`) against the PR head and HELDs on any
//!    high-severity structured finding (DRIFT / MISSING / zero-coverage
//!    organ). Fails open when the comprehend binary isn't installed.
//!
//! 1. **Repo CI green** — polls the PR head SHA's check-runs until ALL
//!    non-advisory checks reach a **terminal** conclusion, then judges:
//!    - All SUCCESS / SKIPPED / NEUTRAL → PASS.
//!    - Any FAILURE / CANCELLED / TIMED_OUT / ACTION_REQUIRED → HELD(ci).
//!    - Timeout (CHUMP_VERIFY_CI_WAIT_SECS, default 1200 s) with checks still
//!      pending → HELD(ci_pending).
//!    - Zero checks → HELD(no-gates): refuse to merge without any signal.
//!
//!    Polling interval: CHUMP_VERIFY_CI_POLL_SECS (default 30 s).
//!    Advisory checks: CHUMP_VERIFY_CI_ADVISORY_NAMES (comma-separated
//!    case-insensitive substrings). Matching checks are polled + logged but
//!    NEVER gate the verdict — their pending/failure state cannot HELD.
//!
//! 2. **Anti-cosmetic test gate** — the PR diff MUST add or modify at least
//!    one test file (heuristic: path contains `test` / `spec`, or file is
//!    `*_test.*` / `*_spec.*` / `test_*.rs` etc.).  That test must:
//!    - FAIL (non-zero exit) on the **base** commit of the repo, AND
//!    - PASS (exit 0) on the **PR head** commit.
//!
//!    Base run: checks out base SHA, then overlays the PR's test files from
//!    head onto the working tree (so ADDED test files — not present on base —
//!    are available). Runs only the changed test files.
//!
//!    A test that passes on both proves nothing — HELD(unproven).
//!    A PR with no changed test files at all — HELD(cosmetic).
//!    Deps are installed (ensure_deps) before EVERY run.
//!
//! 3. **No-regression (DELTA)** — runs full suite on BOTH base and head,
//!    compares failing-test sets. HELD(regression) ONLY if a test that
//!    PASSED on base now FAILS on head (newly-introduced regression).
//!    Pre-existing failures (red on both base and head) do NOT block.
//!    This is NOT a weakening: Gate 2 still proves the specific fix;
//!    Gate 3 ensures the PR introduces no new breakage.
//!    If CHUMP_EXTERNAL_VERIFY_FULL_SUITE is not "1", gate is marked
//!    CoveredByCi (same as before — clean repos unaffected).
//!
//! ## Dependency installation (FIX 1 — CREDIBLE-104)
//!
//! Before running tests at any SHA, `ensure_deps` is called:
//!   - Npm: if `node_modules/` absent, runs `npm ci` (fallback `npm install`
//!     when no `package-lock.json`). Timeout: CHUMP_VERIFY_DEPS_TIMEOUT_SECS
//!     (default 600 s). Failure → HELD(install-failed), NOT a test failure.
//!   - Pytest: best-effort `pip install -r requirements.txt` if present.
//!   - Cargo / Make: no-op (toolchain assumed present).
//!
//! ## Ambient events emitted
//!
//! - `kind=external_merge_verified` — ALL gates passed (and --apply merged).
//! - `kind=external_merge_held` — at least one gate failed; includes reason.
//!
//! ## Usage
//!
//! ```text
//! chump external verify-merge \
//!     --pr <N> --repo <owner/repo> --gap <ID> \
//!     [--clone-dir <path>] [--apply]
//! ```
//!
//! Dry-run by default; --apply actually merges.
//!
//! ## Kill-switch (Category B — operator kill-switch, _DISABLED form)
//!
//! `CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1` — disables the subcommand
//! entirely (exits 1 with an explanatory message). For use when the upstream
//! gh API is unavailable or during incident response.

use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

// ── Public API ────────────────────────────────────────────────────────────

/// Entry point called from `src/main.rs` after routing `chump external verify-merge`.
pub fn run(args: &[String]) -> i32 {
    // Category-B kill-switch using _DISABLED suffix (not _SKIP/_BYPASS/_CHECK).
    if std::env::var("CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED").as_deref() == Ok("1") {
        eprintln!("[external verify-merge] disabled via CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1");
        eprintln!("Unset to re-enable.");
        return 1;
    }

    match run_inner(args) {
        Ok(rc) => rc,
        Err(e) => {
            eprintln!("chump external verify-merge: {e:#}");
            1
        }
    }
}

// ── Core logic ────────────────────────────────────────────────────────────

fn run_inner(args: &[String]) -> anyhow::Result<i32> {
    if args.is_empty() || args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        return Ok(0);
    }

    let opts = Opts::parse(args)?;

    let clone_dir = resolve_clone_dir(&opts)?;

    println!(
        "[verify-merge] checking PR #{} on {repo}",
        opts.pr,
        repo = opts.repo
    );
    println!("[verify-merge] clone dir: {}", clone_dir.display());

    // ── Gate 1: Repo CI green ─────────────────────────────────────────────
    println!("\n[verify-merge] Gate 1: Repo CI check-runs (polling until terminal) ...");
    let ci_result = poll_ci_until_terminal(&opts)?;
    match &ci_result {
        CiResult::Green {
            check_count,
            checks,
            red_advisory,
        } => {
            println!("  PASS: {check_count} check-run(s) all terminal-green");
            for c in checks.iter().take(5) {
                println!("    ✓ {c}");
            }
            if checks.len() > 5 {
                println!("    … and {} more", checks.len() - 5);
            }
            // RESILIENT-1365: emit signal when advisory checks are red.
            if !red_advisory.is_empty() {
                emit_advisory_check_red(&opts, red_advisory);
            }
        }
        CiResult::NoGates => {
            let reason = "repo has no CI to verify against";
            println!("  FAIL: {reason}");
            emit_held(&opts, reason);
            println!("\nVerdict: HELD(no-gates)");
            println!("  {reason}");
            return Ok(1);
        }
        CiResult::Red { failing } => {
            let reason = format!(
                "CI red: {} check(s) failed: {}",
                failing.len(),
                failing.join(", ")
            );
            println!("  FAIL: {reason}");
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(ci)");
            println!("  {reason}");
            return Ok(1);
        }
        CiResult::TimedOut { pending } => {
            let reason = format!(
                "CI timeout: {} check(s) still pending after wait cap: {}",
                pending.len(),
                pending.join(", ")
            );
            println!("  FAIL: {reason}");
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(ci_pending)");
            println!("  {reason}");
            return Ok(1);
        }
    }

    // ── Clone / fetch the repo ────────────────────────────────────────────
    let (base_sha, head_sha) = fetch_pr_commits(&opts)?;
    println!(
        "\n[verify-merge] PR base SHA: {} / head SHA: {}",
        &base_sha[..base_sha.len().min(12)],
        &head_sha[..head_sha.len().min(12)]
    );

    ensure_clone(&clone_dir, &opts.repo, &opts.gh_bin)?;
    fetch_refs(&clone_dir, &base_sha, &head_sha)?;

    // ── Gate 0 (opt-in): comprehension organs ────────────────────────────
    // INFRA-3470: structured findings from the comprehend organs can HELD a
    // merge before the expensive test gates run. Opt-in
    // (CHUMP_VERIFY_COMPREHEND_GATE=1) and fails open when the comprehend
    // binary isn't installed — an absent organ is a coverage gap, not a
    // reason to block every external_repo PR.
    if crate::comprehend_gate::gate_enabled() {
        println!("\n[verify-merge] Gate 0: comprehension organs (opt-in) ...");
        git_checkout_detach(&clone_dir, &head_sha)?;
        if let Some(reason) = crate::comprehend_gate::run_gate(&clone_dir)? {
            println!("  FAIL: {reason}");
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(comprehend)");
            println!("  {reason}");
            return Ok(1);
        }
        println!("  PASS: no high-severity organ findings");
    }

    // ── Gate 2: Anti-cosmetic test gate ──────────────────────────────────
    println!("\n[verify-merge] Gate 2: Anti-cosmetic test gate ...");
    let test_files = diff_test_files(&clone_dir, &base_sha, &head_sha)?;
    if test_files.is_empty() {
        let reason = "no test files added or modified by this PR";
        println!("  FAIL: {reason}");
        emit_held(&opts, reason);
        println!("\nVerdict: HELD(cosmetic)");
        println!("  {reason}");
        return Ok(1);
    }
    println!("  test files changed: {:?}", test_files);

    let runner = detect_test_runner(&clone_dir)?;
    println!("  detected test runner: {:?}", runner);

    if let TestRunner::Unknown = &runner {
        let reason = "cannot determine test runner for this repo";
        println!("  FAIL: {reason}");
        emit_held(&opts, reason);
        println!("\nVerdict: HELD(no-runner)");
        println!("  {reason}");
        return Ok(1);
    }

    // Base run: checkout base, overlay PR test files from head, run tests.
    // This correctly handles ADDED test files (not present on base).
    let base_result =
        run_tests_at_sha_with_overlay(&clone_dir, &base_sha, &head_sha, &runner, &test_files)?;
    match base_result {
        TestRunResult::InstallFailed { reason } => {
            let msg = format!("deps install failed on base: {reason}");
            println!("  FAIL: {msg}");
            emit_held(&opts, &msg);
            println!("\nVerdict: HELD(install-failed)");
            println!("  {msg}");
            return Ok(1);
        }
        TestRunResult::Ran {
            passed: base_passed,
            output: base_output,
        } => {
            let fails_on_base = !base_passed;

            // Head run: checkout head, run tests (no overlay needed — test files present).
            let head_result =
                run_tests_at_sha_no_overlay(&clone_dir, &head_sha, &runner, &test_files)?;
            match head_result {
                TestRunResult::InstallFailed { reason } => {
                    let msg = format!("deps install failed on head: {reason}");
                    println!("  FAIL: {msg}");
                    emit_held(&opts, &msg);
                    println!("\nVerdict: HELD(install-failed)");
                    println!("  {msg}");
                    return Ok(1);
                }
                TestRunResult::Ran {
                    passed: passes_on_head,
                    output: head_output,
                } => {
                    println!("  fails on base: {fails_on_base}");
                    println!("  passes on head: {passes_on_head}");

                    let pure_test_addition = if !fails_on_base && passes_on_head {
                        is_pure_test_addition(&clone_dir, &base_sha, &head_sha, &test_files)
                            .unwrap_or(false)
                    } else {
                        false
                    };

                    if !fails_on_base && !pure_test_addition {
                        let reason =
                            "test passes on base too — change is unproven (cosmetic or duplicate)";
                        println!("  FAIL: {reason}");
                        println!(
                            "  base output: {}",
                            base_output.trim().lines().next().unwrap_or("(empty)")
                        );
                        emit_held(&opts, reason);
                        println!("\nVerdict: HELD(unproven)");
                        println!("  {reason}");
                        return Ok(1);
                    }
                    if pure_test_addition {
                        println!(
                            "  PASS (pure-test-addition): PR adds only new test files covering existing behavior and passes on head"
                        );
                    }

                    if !passes_on_head {
                        let reason =
                            "test still fails on PR head — change does not fix what it claims";
                        println!("  FAIL: {reason}");
                        println!(
                            "  head output: {}",
                            head_output.trim().lines().next().unwrap_or("(empty)")
                        );
                        emit_held(&opts, reason);
                        println!("\nVerdict: HELD(test-fails-on-head)");
                        println!("  {reason}");
                        return Ok(1);
                    }

                    println!(
                        "  PASS: test fails on base, passes on head (real behavioral change proven)"
                    );
                }
            }
        }
    }

    // ── Gate 3: No regression (delta between base and head) ──────────────
    println!("\n[verify-merge] Gate 3: No-regression (delta: base vs head) ...");
    let regression_result = run_full_suite_delta(&clone_dir, &base_sha, &head_sha, &runner)?;
    match regression_result {
        RegressionResult::Pass {
            base_fail_count,
            head_fail_count,
        } => {
            println!(
                "  PASS: no new failures (base failures: {base_fail_count}, head failures: {head_fail_count})"
            );
        }
        RegressionResult::CoveredByCi => {
            println!("  PASS (covered by CI gate 1 — CI runs tests)");
        }
        RegressionResult::InstallFailed { reason } => {
            let msg = format!("deps install failed during regression check: {reason}");
            println!("  FAIL: {msg}");
            emit_held(&opts, &msg);
            println!("\nVerdict: HELD(install-failed)");
            println!("  {msg}");
            return Ok(1);
        }
        RegressionResult::NewFailures {
            newly_failing,
            base_fail_count,
            head_fail_count,
        } => {
            let reason = format!(
                "regression: {} test(s) newly failing (base_failures={base_fail_count} head_failures={head_fail_count}): {}",
                newly_failing.len(),
                newly_failing.join(", ")
            );
            println!("  FAIL: {}", reason);
            emit_held(&opts, &reason);
            println!("\nVerdict: HELD(regression)");
            println!("  {reason}");
            return Ok(1);
        }
    }

    // ── Gate 4: AC completeness (CREDIBLE-212 — EFFECTIVE-375 relocated) ────
    // The EFFECTIVE-375 AC hard gate originally lived in improve.rs AFTER
    // verify_and_merge returned — but gates 1/2/3 passing here fires the
    // `--apply` merge below (merge_pr = `gh pr merge --squash`, immediate), so a
    // "verified" verdict meant the PR was ALREADY merged. Flipping it to held
    // post-merge gated nothing (cosmetic) and shoved an already-squash-merged PR
    // into remediate_held. Co-locate the AC judge with gates 1/2/3, BEFORE the
    // merge, so an UNMET acceptance criterion actually blocks the door — same
    // shape as every gate above (emit_held + HELD verdict + early return).
    //
    // Opt-in (CHUMP_AC_JUDGE_LLM=1, until the AC-writer lands so we don't hard-
    // block on vague boilerplate AC) and fails OPEN — a judge/load error is
    // logged and does NOT hold (a broken judge must never false-block a real fix).
    if std::env::var("CHUMP_AC_JUDGE_LLM").as_deref() == Ok("1") {
        let stored = crate::pr_ac_coverage::load_ac_bullets(&opts.gap).unwrap_or_default();
        // EFFECTIVE-387 (hands-free on-ramp): a PR with NO stored acceptance criteria
        // makes Gate 4 a no-op — the exact false-green COTG kills (a gap-less human PR,
        // or a gap filed with empty AC, sails through on CI alone). When synth is on,
        // generate AC from the PR itself (title + body + diff) via the AC-writer and
        // judge against THOSE, so "no AC" no longer means "unjudged". Opt-in
        // (CHUMP_AC_SYNTH=1) + fails OPEN (synth failure → skip, never false-block).
        let synth_enabled = std::env::var("CHUMP_AC_SYNTH").as_deref() == Ok("1");
        let synth = if stored.is_empty() && synth_enabled {
            synth_ac_for_pr(&opts)
        } else {
            None
        };
        let (bullets, synthesized) = select_gate_bullets(stored, synth_enabled, synth);
        if bullets.is_empty() {
            println!(
                "\n[verify-merge] Gate 4: AC completeness — skipped (gap {} has no acceptance criteria)",
                opts.gap
            );
        } else {
            println!(
                "\n[verify-merge] Gate 4: AC completeness — LLM-judging {} {} bullet(s) for gap {} ...",
                bullets.len(),
                if synthesized { "SYNTHESIZED" } else { "stored" },
                opts.gap
            );
            match crate::pr_ac_coverage::run_with_ac(&opts.repo, opts.pr, &opts.gap, &bullets) {
                Ok(cov) if cov.status == crate::pr_ac_coverage::CoverageStatus::Miss => {
                    let unmet: Vec<usize> = cov
                        .bullets
                        .iter()
                        .filter(|b| !b.covered && !b.waived)
                        .map(|b| b.index + 1)
                        .collect();
                    let reason = format!(
                        "ac-incomplete: {} unmet {} acceptance bullet(s) {unmet:?} despite green CI",
                        unmet.len(),
                        if synthesized { "synthesized" } else { "stored" }
                    );
                    println!("  FAIL: {reason}");
                    emit_held(&opts, &reason);
                    println!("\nVerdict: HELD(ac-incomplete)");
                    println!("  {reason}");
                    return Ok(1);
                }
                Ok(_) => println!("  PASS: all acceptance bullets satisfied."),
                Err(e) => {
                    eprintln!("  (Gate 4 AC judge error — failing OPEN, not blocking: {e})")
                }
            }
        }
    }

    // ── All gates pass ────────────────────────────────────────────────────
    let proof = Proof {
        ci_checks: match &ci_result {
            CiResult::Green { checks, .. } => checks.clone(),
            _ => vec![],
        },
        test_files: test_files.clone(),
        base_sha: base_sha.clone(),
        head_sha: head_sha.clone(),
    };

    emit_verified(&opts, &proof);

    println!("\nVerdict: MERGE");
    println!("  All 3 gates passed.");
    println!(
        "  Proof: {} CI checks, test fails-on-base + passes-on-head confirmed.",
        proof.ci_checks.len()
    );

    if opts.apply {
        println!(
            "\n[verify-merge] --apply: merging PR #{} on {} ...",
            opts.pr, opts.repo
        );
        let merge_result = merge_pr(&opts)?;
        if merge_result {
            println!("[verify-merge] PR #{} merged successfully.", opts.pr);
            run_outcome_probe(&opts);
        } else {
            eprintln!("[verify-merge] merge command failed — check gh output above.");
            return Ok(1);
        }
    } else {
        println!("\n(dry-run — pass --apply to execute the merge)");
    }

    Ok(0)
}

// ── Types ─────────────────────────────────────────────────────────────────

struct Opts {
    pr: u64,
    repo: String,
    gap: String,
    clone_dir: Option<PathBuf>,
    apply: bool,
    /// Path to `gh` binary; resolved from PATH, overridable via CHUMP_GH_BIN.
    gh_bin: String,
    /// CREDIBLE-COTG-3.1: URL to fetch AFTER a successful --apply merge, to
    /// prove the shipped change actually changed observable, live behavior —
    /// not just that CI + the anti-cosmetic gates were satisfied in the repo
    /// checkout. `None` skips the probe entirely (opt-in, so repos with no
    /// live surface — libraries, CLIs — aren't forced to supply one).
    outcome_probe_url: Option<String>,
    /// Substring that must appear in the probe response body for the outcome
    /// to be considered proven. Required alongside `outcome_probe_url`.
    outcome_probe_contains: Option<String>,
}

impl Opts {
    fn parse(args: &[String]) -> anyhow::Result<Self> {
        use anyhow::Context;
        let mut pr: Option<u64> = None;
        let mut repo: Option<String> = None;
        let mut gap = String::new();
        let mut clone_dir: Option<PathBuf> = None;
        let mut apply = false;
        let mut outcome_probe_url: Option<String> = None;
        let mut outcome_probe_contains: Option<String> = None;

        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--pr" => {
                    i += 1;
                    pr = Some(
                        args.get(i)
                            .context("--pr requires a value")?
                            .parse()
                            .context("--pr must be a positive integer")?,
                    );
                }
                "--repo" => {
                    i += 1;
                    repo = Some(args.get(i).context("--repo requires a value")?.clone());
                }
                "--gap" => {
                    i += 1;
                    gap = args.get(i).context("--gap requires a value")?.clone();
                }
                "--clone-dir" => {
                    i += 1;
                    clone_dir = Some(PathBuf::from(
                        args.get(i).context("--clone-dir requires a value")?,
                    ));
                }
                "--apply" => {
                    apply = true;
                }
                "--outcome-probe-url" => {
                    i += 1;
                    outcome_probe_url = Some(
                        args.get(i)
                            .context("--outcome-probe-url requires a value")?
                            .clone(),
                    );
                }
                "--outcome-probe-contains" => {
                    i += 1;
                    outcome_probe_contains = Some(
                        args.get(i)
                            .context("--outcome-probe-contains requires a value")?
                            .clone(),
                    );
                }
                _ => {}
            }
            i += 1;
        }

        let pr = pr.context("--pr <N> is required")?;
        let repo = repo.context("--repo <owner/repo> is required")?;
        if gap.is_empty() {
            anyhow::bail!("--gap <ID> is required");
        }
        // Validate owner/repo shape.
        if !repo.contains('/') {
            anyhow::bail!("--repo must be in owner/repo format, got {:?}", repo);
        }
        if outcome_probe_url.is_some() != outcome_probe_contains.is_some() {
            anyhow::bail!(
                "--outcome-probe-url and --outcome-probe-contains must be passed together"
            );
        }

        let gh_bin = std::env::var("CHUMP_GH_BIN").unwrap_or_else(|_| "gh".to_string());

        Ok(Opts {
            pr,
            repo,
            gap,
            clone_dir,
            apply,
            gh_bin,
            outcome_probe_url,
            outcome_probe_contains,
        })
    }
}

struct Proof {
    ci_checks: Vec<String>,
    test_files: Vec<String>,
    base_sha: String,
    head_sha: String,
}

enum CiResult {
    Green {
        check_count: usize,
        checks: Vec<String>,
        /// Advisory checks that are red but do not gate (RESILIENT-1365).
        red_advisory: Vec<String>,
    },
    NoGates,
    Red {
        failing: Vec<String>,
    },
    /// Timed out waiting for checks to reach terminal state.
    TimedOut {
        pending: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TestRunner {
    /// `cargo test --test <name> -- <test_fn>`  (Rust)
    Cargo,
    /// `npm test` / `yarn test`
    Npm,
    /// `pytest` (Python)
    Pytest,
    /// `make test`
    Make,
    /// Could not determine
    Unknown,
}

/// Result of a single test invocation (specific files or full suite).
enum TestRunResult {
    /// Dependencies failed to install — surfaces as HELD(install-failed), NOT test failure.
    InstallFailed { reason: String },
    /// Tests ran; `passed` = exit 0.
    Ran { passed: bool, output: String },
}

/// Gate 3 regression result.
enum RegressionResult {
    /// No new failures introduced (includes the old all-green case).
    Pass {
        base_fail_count: usize,
        head_fail_count: usize,
    },
    /// CI gate already proved tests pass; skip local run.
    CoveredByCi,
    /// Deps installation failed during regression check.
    InstallFailed { reason: String },
    /// Tests that passed on base now fail on head.
    NewFailures {
        newly_failing: Vec<String>,
        base_fail_count: usize,
        head_fail_count: usize,
    },
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn print_usage() {
    println!("Usage: chump external verify-merge \\");
    println!("    --pr <N> --repo <owner/repo> --gap <ID> \\");
    println!("    [--clone-dir <path>] [--apply] \\");
    println!("    [--outcome-probe-url <url> --outcome-probe-contains <substring>]");
    println!();
    println!("Gates (ALL must pass):");
    println!("  1. Repo CI green — polls check-runs until all terminal; all must be green.");
    println!("     Zero checks → HELD(no-gates).");
    println!("  2. Anti-cosmetic — diff adds/modifies a test; that test fails on base");
    println!("     (with PR test files overlaid), passes on head. Deps installed first.");
    println!("     No test → HELD(cosmetic). Passes-on-both → HELD(unproven).");
    println!("  3. No-regression (delta) — full suite on base + head; HELD(regression)");
    println!("     only when a test that passed on base fails on head. Pre-existing");
    println!("     failures do NOT block. Set CHUMP_EXTERNAL_VERIFY_FULL_SUITE=1 to enable.");
    println!();
    println!("Verdict: MERGE (all pass) or HELD(<reason>).");
    println!("Dry-run by default; --apply executes the merge.");
    println!();
    println!("Post-merge outcome probe (opt-in) — after a successful --apply merge,");
    println!("fetches --outcome-probe-url and asserts --outcome-probe-contains appears");
    println!("in the response body. Proves the LIVE outcome, not just the repo checkout.");
    println!("Never gates the merge (already happened); emits");
    println!("kind=outcome_probe_verified / outcome_probe_failed to ambient.jsonl.");
    println!("Set CHUMP_OUTCOME_PROBE_RENDER=1 to render the URL through headless");
    println!("Chromium (--dump-dom) instead of a raw curl fetch, so the substring");
    println!("check sees post-JS DOM content (needed for SPAs). Falls back to curl");
    println!("automatically if no Chromium binary is found or the render fails.");
    println!();
    println!("Kill-switch: CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1");
    println!("Deps timeout: CHUMP_VERIFY_DEPS_TIMEOUT_SECS (default 600)");
}

fn resolve_clone_dir(opts: &Opts) -> anyhow::Result<PathBuf> {
    if let Some(ref d) = opts.clone_dir {
        return Ok(d.clone());
    }
    // Default: ~/.chump/external/<owner>/<repo>/clone
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let dir = PathBuf::from(home)
        .join(".chump")
        .join("external")
        .join(opts.repo.replace('/', "_"))
        .join("clone");
    Ok(dir)
}

// ── Terminal-state constants ───────────────────────────────────────────────
// A check-run conclusion is terminal when it is one of these values (GitHub docs).
// QUEUED / IN_PROGRESS / null-conclusion are non-terminal (still running).
const TERMINAL_CONCLUSIONS: &[&str] = &[
    "success",
    "failure",
    "cancelled",
    "timed_out",
    "action_required",
    "skipped",
    "neutral",
    "stale",
];
// These terminal conclusions are treated as a non-blocking pass.
const PASS_CONCLUSIONS: &[&str] = &["success", "skipped", "neutral"];
// These terminal conclusions are hard failures.
const FAIL_CONCLUSIONS: &[&str] = &["failure", "cancelled", "timed_out", "action_required"];

/// CREDIBLE-228: is this a known-benign infrastructure check that must never
/// gate a merge? Motivating case: when a PR is authored by a bot whose commit
/// email is not linked to a GitHub account, Vercel posts a FAILING commit
/// status "GitHub couldn't verify an account for the commit" on *every* such
/// commit. It is an account-linking artifact, not a code failure, so it must
/// not hold the PR — otherwise every autonomous PR self-closes. Matched
/// conservatively: the check must be Vercel's AND its message must mention
/// verifying an account (apostrophe-robust substring).
fn is_benign_infra_check(name_lower: &str, detail_lower: &str) -> bool {
    name_lower.contains("vercel") && detail_lower.contains("verify an account")
}

/// Detect whether a check context is advisory (non-required) or required.
///
/// A check is advisory if:
/// - Its name matches an entry in `advisory_substrings` (case-insensitive), OR
/// - It is a known-benign infrastructure check, OR
/// - When `required_contexts` is set, the check's name is NOT in that list.
///
/// When `required_contexts` is `None`, only the env advisory list and benign
/// predicate determine advisory status.
///
/// Returns `true` if the check is advisory (non-gating), `false` if it is required.
fn is_advisory_check(
    check_name: &str,
    check_detail: &str,
    advisory_substrings: &[String],
    required_contexts: Option<&[String]>,
) -> bool {
    let name_lower = check_name.to_ascii_lowercase();
    let detail_lower = check_detail.to_ascii_lowercase();

    let env_advisory = advisory_substrings
        .iter()
        .any(|sub| name_lower.contains(sub.as_str()));
    let benign = is_benign_infra_check(&name_lower, &detail_lower);

    match required_contexts {
        Some(ctxs) => {
            env_advisory || benign || !ctxs.iter().any(|c| c.eq_ignore_ascii_case(check_name))
        }
        None => env_advisory || benign,
    }
}

/// Parse a single check entry from statusCheckRollup JSON.
///
/// `required_contexts` is the base branch's branch-protection required-check
/// set (CREDIBLE-228). When `Some(non-empty)`, ONLY checks whose name is in
/// that set gate the merge — anything else is advisory. When `None` (no
/// readable protection), fall back to the env advisory list plus the curated
/// benign-infra predicate.
fn classify_check(
    check: &serde_json::Value,
    advisory_substrings: &[String],
    required_contexts: Option<&[String]>,
) -> CheckInfo {
    let name = check
        .get("name")
        .or_else(|| check.get("context"))
        .and_then(|v| v.as_str())
        .unwrap_or("(unnamed)")
        .to_string();

    // CREDIBLE-228: gather human-readable detail (commit-status `description` +
    // check-run `output`) so the benign-infra predicate can inspect the message
    // text, e.g. Vercel's "GitHub couldn't verify an account for the commit".
    let mut detail = String::new();
    for key in ["description", "title", "summary", "text"] {
        if let Some(s) = check.get(key).and_then(|v| v.as_str()) {
            detail.push_str(s);
            detail.push(' ');
        }
    }
    if let Some(output) = check.get("output") {
        for key in ["title", "summary", "text"] {
            if let Some(s) = output.get(key).and_then(|v| v.as_str()) {
                detail.push_str(s);
                detail.push(' ');
            }
        }
    }

    let conclusion = check
        .get("conclusion")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let state = check
        .get("state")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let status = check
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    // Commit-status uses `state`; check-run uses `conclusion`.
    // Terminal = conclusion is one of TERMINAL_CONCLUSIONS, OR state is a
    // commit-status terminal value (success/failure/error).
    let effective_conclusion = if !conclusion.is_empty() {
        conclusion.clone()
    } else {
        // commit status: state = success | failure | error | pending
        match state.as_str() {
            "success" => "success".to_string(),
            "failure" | "error" => "failure".to_string(),
            _ => String::new(),
        }
    };

    let is_terminal = TERMINAL_CONCLUSIONS.contains(&effective_conclusion.as_str())
        // commit-status pending → not terminal
        || (!effective_conclusion.is_empty()
            && effective_conclusion != "pending"
            && !status.eq("in_progress")
            && !status.eq("queued")
            && !status.eq("requested")
            && !state.eq("pending"));

    // Also treat as non-terminal when status shows still running.
    let is_still_running = status == "in_progress"
        || status == "queued"
        || status == "requested"
        || state == "pending";

    let is_terminal = is_terminal && !is_still_running;

    let is_pass = PASS_CONCLUSIONS.contains(&effective_conclusion.as_str()) || state == "success";

    let is_fail = FAIL_CONCLUSIONS.contains(&effective_conclusion.as_str())
        || state == "failure"
        || state == "error";

    let is_advisory = is_advisory_check(&name, &detail, advisory_substrings, required_contexts);

    CheckInfo {
        name,
        is_advisory,
        is_terminal,
        is_pass,
        is_fail,
    }
}

struct CheckInfo {
    name: String,
    is_advisory: bool,
    is_terminal: bool,
    #[allow(dead_code)]
    // EFFECTIVE-394: computed pass signal kept for struct symmetry; not yet read
    is_pass: bool,
    is_fail: bool,
}

/// Fetch check-runs once via `gh pr view --json statusCheckRollup`.
fn fetch_check_runs(opts: &Opts) -> anyhow::Result<Vec<serde_json::Value>> {
    let output = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "view",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--json",
            "statusCheckRollup",
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("failed to run gh: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value = serde_json::from_str(&stdout)
        .map_err(|e| anyhow::anyhow!("failed to parse gh json: {e}\nraw: {stdout}"))?;

    Ok(json
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default())
}

/// `gh pr view <pr> --repo <repo> --json baseRefName` → the PR's base branch.
/// CREDIBLE-228 helper. Returns `None` if gh fails or the field is missing.
fn fetch_base_ref_name(opts: &Opts) -> Option<String> {
    let output = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "view",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--json",
            "baseRefName",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    v.get("baseRefName")
        .and_then(|b| b.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// CREDIBLE-228: fetch the base branch's REQUIRED status-check contexts from
/// branch protection. These are the only checks GitHub itself lets block a
/// merge; anything else on the PR is advisory (e.g. Vercel's benign
/// account-verification status).
///
/// Returns:
///   `Some(contexts)` — protection is readable AND declares a non-empty
///                      required set; only these checks gate Gate 1.
///   `None`           — no base branch resolvable, protection unreadable (404 /
///                      no admin / repo has none), or the required set is empty.
///                      Callers then fall back to the benign-infra predicate.
fn fetch_required_contexts(opts: &Opts) -> Option<Vec<String>> {
    let base = fetch_base_ref_name(opts)?;
    let output = Command::new(&opts.gh_bin)
        .args([
            "api",
            &format!("repos/{}/branches/{}/protection", opts.repo, base),
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        // 404 on repos without branch protection, or 403 without admin scope.
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let rsc = v.get("required_status_checks")?;
    let mut contexts: Vec<String> = Vec::new();
    // Classic API: required_status_checks.contexts = ["ctx", ...]
    if let Some(arr) = rsc.get("contexts").and_then(|c| c.as_array()) {
        contexts.extend(arr.iter().filter_map(|c| c.as_str()).map(|s| s.to_string()));
    }
    // Newer API: required_status_checks.checks = [{"context":"ctx",...}, ...]
    if let Some(arr) = rsc.get("checks").and_then(|c| c.as_array()) {
        contexts.extend(
            arr.iter()
                .filter_map(|c| c.get("context").and_then(|x| x.as_str()))
                .map(|s| s.to_string()),
        );
    }
    if contexts.is_empty() {
        None
    } else {
        Some(contexts)
    }
}

/// Poll the PR's check-runs until ALL non-advisory checks are terminal,
/// then judge the result. Implements the CREDIBLE-102 wait-before-judge logic.
///
/// Tuning env vars:
///   CHUMP_VERIFY_CI_POLL_SECS  — polling interval in seconds (default 30)
///   CHUMP_VERIFY_CI_WAIT_SECS  — maximum wait in seconds (default 1200 = 20 min)
///   CHUMP_VERIFY_CI_ADVISORY_NAMES — comma-separated case-insensitive name
///                                      substrings; matching checks are non-gating
fn poll_ci_until_terminal(opts: &Opts) -> anyhow::Result<CiResult> {
    let poll_secs: u64 = std::env::var("CHUMP_VERIFY_CI_POLL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30);
    let wait_secs: u64 = std::env::var("CHUMP_VERIFY_CI_WAIT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1200);
    // CREDIBLE-176: how long to keep polling while the rollup is EMPTY before
    // concluding the repo has no CI. A PR opened moments ago (e.g. right after
    // the improve loop opens it) has not had its workflow check-runs registered
    // by GitHub yet, so the rollup is transiently empty — that is "no checks
    // YET", not "no CI configured". Give checks this grace window to appear.
    let empty_grace_secs: u64 = std::env::var("CHUMP_VERIFY_CI_EMPTY_GRACE_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(180);

    // Parse advisory substrings (lowercase for case-insensitive matching).
    let advisory_substrings: Vec<String> = std::env::var("CHUMP_VERIFY_CI_ADVISORY_NAMES")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .collect();

    // CREDIBLE-228: query branch protection ONCE — the required-check set is
    // stable across the poll. When present, only these checks gate Gate 1, so
    // Vercel's benign "couldn't verify an account" status (never a required
    // context) stops self-closing autonomous PRs. When absent/unreadable,
    // classify_check falls back to the benign-infra predicate + env advisory
    // list. Force the old all-checks-block behavior with
    // CHUMP_VERIFY_CI_REQUIRED_ONLY=0.
    let required_contexts: Option<Vec<String>> =
        if std::env::var("CHUMP_VERIFY_CI_REQUIRED_ONLY").as_deref() == Ok("0") {
            None
        } else {
            fetch_required_contexts(opts)
        };
    if let Some(ctxs) = &required_contexts {
        println!(
            "[verify-merge] Gate 1: branch protection declares {} required check(s) — {} — others are advisory",
            ctxs.len(),
            ctxs.join(", ")
        );
    }

    let started_at = std::time::Instant::now();

    loop {
        let checks = fetch_check_runs(opts)?;

        if checks.is_empty() {
            // CREDIBLE-176: an empty rollup does NOT immediately mean "no CI".
            // Right after PR-open, GitHub has usually not registered the
            // workflow check-runs yet. Distinguish "no checks YET (wait)" from
            // "genuinely no CI (no-gates)" by giving checks a grace window to
            // appear. Only conclude no-gates if the rollup is STILL empty after
            // the grace window — that is the true "repo has no CI" signal.
            let elapsed = started_at.elapsed().as_secs();
            if elapsed < empty_grace_secs {
                println!(
                    "[verify-merge] Gate 1: no checks registered yet — waiting for CI to appear, elapsed {elapsed}s / grace {empty_grace_secs}s"
                );
                if poll_secs > 0 {
                    std::thread::sleep(std::time::Duration::from_secs(poll_secs));
                }
                continue;
            }
            println!(
                "[verify-merge] Gate 1: no checks appeared within {empty_grace_secs}s grace — treating as no-gates"
            );
            return Ok(CiResult::NoGates);
        }

        let infos: Vec<CheckInfo> = checks
            .iter()
            .map(|c| classify_check(c, &advisory_substrings, required_contexts.as_deref()))
            .collect();

        // Partition into required vs advisory.
        let required: Vec<&CheckInfo> = infos.iter().filter(|i| !i.is_advisory).collect();
        let advisory: Vec<&CheckInfo> = infos.iter().filter(|i| i.is_advisory).collect();

        // Log advisory check state (informational, never gates).
        for a in &advisory {
            if !a.is_terminal {
                println!("  [advisory] {} — still pending (non-gating)", a.name);
            } else if a.is_fail {
                println!(
                    "  [advisory] {} — failed (non-gating, advisory check)",
                    a.name
                );
            }
        }

        // Check if all required checks are terminal.
        let pending_required: Vec<&str> = required
            .iter()
            .filter(|i| !i.is_terminal)
            .map(|i| i.name.as_str())
            .collect();

        if pending_required.is_empty() {
            // All required checks are terminal — judge now.
            let failing: Vec<String> = required
                .iter()
                .filter(|i| i.is_fail)
                .map(|i| i.name.clone())
                .collect();

            if failing.is_empty() {
                let passing: Vec<String> = required.iter().map(|i| i.name.clone()).collect();
                // RESILIENT-1365: collect red advisory checks to signal later.
                let red_advisory: Vec<String> = advisory
                    .iter()
                    .filter(|i| i.is_fail)
                    .map(|i| i.name.clone())
                    .collect();
                return Ok(CiResult::Green {
                    check_count: passing.len(),
                    checks: passing,
                    red_advisory,
                });
            } else {
                return Ok(CiResult::Red { failing });
            }
        }

        // Not all terminal yet — check timeout.
        let elapsed = started_at.elapsed().as_secs();
        if elapsed >= wait_secs {
            return Ok(CiResult::TimedOut {
                pending: pending_required.iter().map(|s| s.to_string()).collect(),
            });
        }

        // Progress report and sleep.
        println!(
            "[verify-merge] Gate 1: waiting for CI — {} pending ({}), elapsed {}s / cap {}s",
            pending_required.len(),
            pending_required.join(", "),
            elapsed,
            wait_secs,
        );

        if poll_secs > 0 {
            std::thread::sleep(std::time::Duration::from_secs(poll_secs));
        }
    }
}

/// `gh pr view <pr> --repo <repo> --json baseRefOid,headRefOid`
fn fetch_pr_commits(opts: &Opts) -> anyhow::Result<(String, String)> {
    let output = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "view",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--json",
            "baseRefOid,headRefOid",
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("gh pr view (commits): {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value = serde_json::from_str(&stdout)
        .map_err(|e| anyhow::anyhow!("parse gh json (commits): {e}\nraw: {stdout}"))?;

    let base = json
        .get("baseRefOid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("missing baseRefOid in gh response"))?
        .to_string();
    let head = json
        .get("headRefOid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("missing headRefOid in gh response"))?
        .to_string();

    Ok((base, head))
}

/// Clone the repo if not already present; otherwise fetch.
fn ensure_clone(clone_dir: &Path, repo: &str, _gh_bin: &str) -> anyhow::Result<()> {
    if clone_dir.join(".git").exists() {
        // Already cloned; fetch latest.
        println!(
            "[verify-merge] repo already cloned at {} — fetching ...",
            clone_dir.display()
        );
        let status = ext_git()
            .args([
                "-C",
                &clone_dir.to_string_lossy(),
                "fetch",
                "--quiet",
                "origin",
            ])
            .status()
            .map_err(|e| anyhow::anyhow!("git fetch: {e}"))?;
        if !status.success() {
            // Non-fatal: might be offline or the PR branch was deleted. Continue.
            eprintln!("[verify-merge] warning: git fetch failed (continuing)");
        }
        return Ok(());
    }

    println!("[verify-merge] cloning {} ...", repo);
    if let Some(parent) = clone_dir.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let clone_url = format!("https://github.com/{repo}.git");
    let status = ext_git()
        .args([
            "clone",
            "--depth",
            "50", // shallow enough to be fast; deep enough for diff
            &clone_url,
            &clone_dir.to_string_lossy(),
        ])
        .status()
        .map_err(|e| anyhow::anyhow!("git clone: {e}"))?;

    if !status.success() {
        anyhow::bail!("git clone of {repo} failed");
    }
    Ok(())
}

/// Ensure both SHAs are available locally (they may not be in a shallow clone).
fn fetch_refs(clone_dir: &Path, base_sha: &str, head_sha: &str) -> anyhow::Result<()> {
    for sha in [base_sha, head_sha] {
        // Check if SHA is already available.
        let available = ext_git()
            .args(["-C", &clone_dir.to_string_lossy(), "cat-file", "-e", sha])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);

        if !available {
            // Fetch the specific SHA.
            let _ = ext_git()
                .args([
                    "-C",
                    &clone_dir.to_string_lossy(),
                    "fetch",
                    "--depth",
                    "1",
                    "origin",
                    sha,
                ])
                .status();
        }
    }
    Ok(())
}

/// Returns list of test files changed between base and head.
/// Heuristic: file path contains `test` or `spec`, or matches `*_test.*`,
/// `*_spec.*`, `test_*.*`, or `__tests__/*`.
fn diff_test_files(clone_dir: &Path, base: &str, head: &str) -> anyhow::Result<Vec<String>> {
    let output = ext_git()
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "diff",
            "--name-only",
            base,
            head,
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("git diff --name-only: {e}"))?;

    let files: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|p| is_test_file(p))
        .map(String::from)
        .collect();

    Ok(files)
}

/// Heuristic: does this path look like a test file?
fn is_test_file(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    let stem = std::path::Path::new(&lower)
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or("");

    // Common patterns across Rust / JS / Python / Go / Ruby / etc.
    lower.contains("/test/")
        || lower.contains("/tests/")
        || lower.contains("/spec/")
        || lower.contains("/__tests__/")
        || lower.contains("/test_")
        || stem.starts_with("test_")
        || stem.ends_with("_test.rs")
        || stem.ends_with("_test.go")
        || stem.ends_with("_test.ts")
        || stem.ends_with("_test.js")
        || stem.ends_with("_spec.rb")
        || stem.ends_with("_spec.js")
        || stem.ends_with("_spec.ts")
        || stem.ends_with(".test.ts")
        || stem.ends_with(".test.js")
        || stem.ends_with(".spec.ts")
        || stem.ends_with(".spec.js")
        || lower.contains("test") // broad fallback: any file with "test" in the path
}

/// Return true if the PR is a pure test-coverage addition/extension PR:
/// - every changed file between `base_sha` and `head_sha` is in `test_files`
///   (or is a companion `DEPTH.md` / `e2e/DEPTH.md` ledger update), AND
/// - every changed test file exists on head and contains both a test definition
///   (`def test_`, `test(`, `it(`, or `#[test]`) and a real assertion
///   (`assert`, `expect(`, or `pytest.raises`), rejecting trivial/cosmetic stubs.
fn is_pure_test_addition(
    clone_dir: &Path,
    base_sha: &str,
    head_sha: &str,
    test_files: &[String],
) -> anyhow::Result<bool> {
    if test_files.is_empty() {
        return Ok(false);
    }
    let out = ext_git()
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "diff",
            "--name-status",
            &format!("{base_sha}..{head_sha}"),
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("git diff --name-status failed: {e}"))?;
    if !out.status.success() {
        return Ok(false);
    }
    let raw = String::from_utf8_lossy(&out.stdout);
    let mut saw_test = false;
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut parts = trimmed.splitn(2, '\t');
        let status = parts.next().unwrap_or("").trim();
        let path = parts.next().unwrap_or("").trim();
        if path.is_empty() || (!status.starts_with('A') && !status.starts_with('M')) {
            return Ok(false);
        }
        if path == "DEPTH.md" || path == "e2e/DEPTH.md" {
            continue;
        }
        if !test_files.iter().any(|tf| tf == path) {
            return Ok(false);
        }
        let full_path = clone_dir.join(path);
        let Ok(content) = std::fs::read_to_string(&full_path) else {
            return Ok(false);
        };
        let has_test_fn = content.contains("def test_")
            || content.contains("async def test_")
            || content.contains("#[test]")
            || content.contains("test(")
            || content.contains("it(");
        let has_assertion = content.contains("assert")
            || content.contains("expect(")
            || content.contains("pytest.raises");
        if !has_test_fn || !has_assertion {
            return Ok(false);
        }
        saw_test = true;
    }
    Ok(saw_test)
}

/// Detect how to run tests for this repo.
fn detect_test_runner(clone_dir: &Path) -> anyhow::Result<TestRunner> {
    // Rust
    if clone_dir.join("Cargo.toml").exists() {
        return Ok(TestRunner::Cargo);
    }
    // JS/TS — check package.json has a test script
    let pkg_json = clone_dir.join("package.json");
    if pkg_json.exists() {
        if let Ok(s) = std::fs::read_to_string(&pkg_json) {
            if let Ok(j) = serde_json::from_str::<serde_json::Value>(&s) {
                if j.get("scripts").and_then(|sc| sc.get("test")).is_some() {
                    return Ok(TestRunner::Npm);
                }
            }
        }
    }
    // Python
    if clone_dir.join("pytest.ini").exists()
        || clone_dir.join("pyproject.toml").exists()
        || clone_dir.join("setup.cfg").exists()
        || clone_dir.join("conftest.py").exists()
        || clone_dir.join("tests/conftest.py").exists()
    {
        return Ok(TestRunner::Pytest);
    }
    // Makefile with a `test` target
    let makefile = clone_dir.join("Makefile");
    if makefile.exists() {
        if let Ok(s) = std::fs::read_to_string(&makefile) {
            if s.lines()
                .any(|l| l.starts_with("test:") || l.starts_with("test "))
            {
                return Ok(TestRunner::Make);
            }
        }
    }
    Ok(TestRunner::Unknown)
}

// ── FIX 1: Dependency installation ────────────────────────────────────────

/// Ensure dependencies are installed before running tests.
///
/// - Npm: if `node_modules/` absent → `npm ci` (or `npm install` on no lock).
///   Timeout: CHUMP_VERIFY_DEPS_TIMEOUT_SECS (default 600 s).
/// - Pytest: best-effort `pip install -r requirements.txt` if present.
/// - Cargo / Make: no-op.
///
/// Returns `Ok(())` on success or when no-op.
/// Returns `Err` when installation fails — caller should surface HELD(install-failed).
fn ensure_deps(clone_dir: &Path, runner: &TestRunner) -> anyhow::Result<()> {
    match runner {
        TestRunner::Npm => {
            // Only install if node_modules is absent.
            if clone_dir.join("node_modules").exists() {
                return Ok(());
            }

            let timeout_secs: u64 = std::env::var("CHUMP_VERIFY_DEPS_TIMEOUT_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(600);

            // Prefer npm ci (reproducible); fallback to npm install if no lockfile.
            let use_ci = clone_dir.join("package-lock.json").exists()
                || clone_dir.join("npm-shrinkwrap.json").exists();

            let npm_cmd = std::env::var("CHUMP_NPM_BIN").unwrap_or_else(|_| "npm".to_string());
            let install_args: &[&str] = if use_ci { &["ci"] } else { &["install"] };

            println!(
                "[verify-merge] ensure_deps: running `npm {}` in {} (timeout {}s) ...",
                install_args[0],
                clone_dir.display(),
                timeout_secs
            );

            // We use std::process with a timeout via a background thread + kill.
            // (std::process::Command has no built-in timeout on stable Rust.)
            let mut child = Command::new(&npm_cmd)
                .args(install_args)
                .current_dir(clone_dir)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| anyhow::anyhow!("failed to spawn npm: {e}"))?;

            let deadline = std::time::Duration::from_secs(timeout_secs);
            let start = std::time::Instant::now();

            loop {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        if !status.success() {
                            anyhow::bail!(
                                "npm {} failed (exit {:?})",
                                install_args[0],
                                status.code()
                            );
                        }
                        println!("[verify-merge] ensure_deps: npm {} OK", install_args[0]);
                        return Ok(());
                    }
                    Ok(None) => {
                        if start.elapsed() >= deadline {
                            let _ = child.kill();
                            anyhow::bail!(
                                "npm {} timed out after {}s",
                                install_args[0],
                                timeout_secs
                            );
                        }
                        std::thread::sleep(std::time::Duration::from_millis(500));
                    }
                    Err(e) => {
                        anyhow::bail!("npm {} wait error: {e}", install_args[0]);
                    }
                }
            }
        }
        TestRunner::Pytest => {
            // Best-effort: if requirements.txt exists, install it.
            let req = clone_dir.join("requirements.txt");
            if !req.exists() {
                return Ok(());
            }
            println!("[verify-merge] ensure_deps: pip install -r requirements.txt ...");
            let status = Command::new("pip")
                .args(["install", "-r", "requirements.txt"])
                .current_dir(clone_dir)
                .status()
                .map_err(|e| anyhow::anyhow!("pip install: {e}"))?;
            if !status.success() {
                anyhow::bail!("pip install -r requirements.txt failed");
            }
            Ok(())
        }
        // Cargo: toolchain assumed present; `cargo test` handles deps via Cargo.lock.
        // Make: external deps are out of scope.
        TestRunner::Cargo | TestRunner::Make | TestRunner::Unknown => Ok(()),
    }
}

// ── FIX 2: Anti-cosmetic base run with test-file overlay ─────────────────

/// Gate 2 base run: checkout `base_sha`, overlay test files from `head_sha`,
/// install deps, run only `test_files`, then restore.
///
/// This correctly handles the case where a test file is ADDED by the PR
/// (doesn't exist on base): overlaying it from head makes it available so
/// the test can fail vs. the base production code.
fn run_tests_at_sha_with_overlay(
    clone_dir: &Path,
    base_sha: &str,
    head_sha: &str,
    runner: &TestRunner,
    test_files: &[String],
) -> anyhow::Result<TestRunResult> {
    // 1. Checkout base production code.
    git_checkout_detach(clone_dir, base_sha)?;

    // 2. Install deps at base (node_modules etc. may not exist).
    if let Err(e) = ensure_deps(clone_dir, runner) {
        return Ok(TestRunResult::InstallFailed {
            reason: e.to_string(),
        });
    }

    // 3. Overlay each changed test file from head onto the working tree.
    for f in test_files {
        // Ensure parent directory exists (for ADDED files).
        if let Some(parent) = Path::new(f).parent() {
            let full_parent = clone_dir.join(parent);
            let _ = std::fs::create_dir_all(&full_parent);
        }
        let status = ext_git()
            .args([
                "-C",
                &clone_dir.to_string_lossy(),
                "checkout",
                head_sha,
                "--",
                f.as_str(),
            ])
            .status()
            .map_err(|e| anyhow::anyhow!("git checkout head -- {f}: {e}"))?;
        if !status.success() {
            // Non-fatal: file might not exist on head either (deleted) — skip.
            eprintln!("[verify-merge] warning: could not overlay {f} from head (skipping)");
        }
    }

    // 4. Run only the test files.
    let cmd_and_args = test_command_specific(runner, test_files);
    let output = Command::new(&cmd_and_args[0])
        .args(&cmd_and_args[1..])
        .current_dir(clone_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| anyhow::anyhow!("test runner (base+overlay) {:?}: {e}", runner))?;

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let passed = output.status.success();

    // 5. Restore test files to base state (cleanup; subsequent runs start clean).
    for f in test_files {
        let _ = ext_git()
            .args([
                "-C",
                &clone_dir.to_string_lossy(),
                "checkout",
                base_sha,
                "--",
                f.as_str(),
            ])
            .status();
        // If the file didn't exist on base, the checkout above will fail and
        // leave the file absent — which is correct. Remove it explicitly.
        let full = clone_dir.join(f);
        if full.exists() {
            // Check if it was tracked at base: if git checkout succeeded it's fine.
            // If it errored, the overlay file is still there; remove it.
        } else {
            // File wasn't on base — remove any leftover from the overlay.
            let _ = std::fs::remove_file(&full);
        }
    }

    Ok(TestRunResult::Ran {
        passed,
        output: combined,
    })
}

/// Gate 2 head run: checkout `sha`, install deps, run test files (no overlay).
fn run_tests_at_sha_no_overlay(
    clone_dir: &Path,
    sha: &str,
    runner: &TestRunner,
    test_files: &[String],
) -> anyhow::Result<TestRunResult> {
    git_checkout_detach(clone_dir, sha)?;

    if let Err(e) = ensure_deps(clone_dir, runner) {
        return Ok(TestRunResult::InstallFailed {
            reason: e.to_string(),
        });
    }

    let cmd_and_args = test_command_specific(runner, test_files);
    let output = Command::new(&cmd_and_args[0])
        .args(&cmd_and_args[1..])
        .current_dir(clone_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| anyhow::anyhow!("test runner (head) {:?}: {e}", runner))?;

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(TestRunResult::Ran {
        passed: output.status.success(),
        output: combined,
    })
}

/// Detached-HEAD checkout helper.
fn git_checkout_detach(clone_dir: &Path, sha: &str) -> anyhow::Result<()> {
    let co = ext_git()
        .args([
            "-C",
            &clone_dir.to_string_lossy(),
            "checkout",
            "--detach",
            sha,
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("git checkout {sha}: {e}"))?;
    if !co.status.success() {
        let err = String::from_utf8_lossy(&co.stderr);
        anyhow::bail!("git checkout {sha} failed: {err}");
    }
    Ok(())
}

fn python_bin() -> String {
    if Command::new("which")
        .arg("python3")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        "python3".to_string()
    } else {
        "python".to_string()
    }
}

/// Build the test command for SPECIFIC changed test files (Gate 2).
fn test_command_specific(runner: &TestRunner, test_files: &[String]) -> Vec<String> {
    match runner {
        TestRunner::Cargo => {
            // Cargo doesn't have per-file targeting, so use file-stem filter hints.
            let filter = test_files
                .iter()
                .filter_map(|f| {
                    Path::new(f)
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .map(|s| s.to_string())
                })
                .collect::<Vec<_>>()
                .join(" ");
            if filter.is_empty() {
                vec!["cargo".into(), "test".into()]
            } else {
                vec!["cargo".into(), "test".into(), "--".into(), filter]
            }
        }
        TestRunner::Npm => {
            // Use npx jest with --passWithNoTests and specific file paths.
            // Falls back gracefully if jest is not present (npx will error → test fails).
            let npx = std::env::var("CHUMP_NPX_BIN").unwrap_or_else(|_| "npx".to_string());
            let mut cmd = vec![npx, "jest".into(), "--passWithNoTests".into()];
            for f in test_files {
                cmd.push(f.clone());
            }
            cmd
        }
        TestRunner::Pytest => {
            let mut cmd = vec![python_bin(), "-m".into(), "pytest".into(), "-x".into()];
            for f in test_files {
                cmd.push(f.clone());
            }
            cmd
        }
        TestRunner::Make => vec!["make".into(), "test".into()],
        TestRunner::Unknown => vec!["true".into()],
    }
}

// ── FIX 3: Gate 3 as delta (base vs head) ────────────────────────────────

/// Run the full suite on BOTH base and head (when enabled) and compute the
/// delta of failing tests. HELD(regression) only if a test that PASSED on
/// base FAILS on head.
///
/// Pre-existing failures (red on both) do NOT block. This correctly handles
/// messy 0→1 repos with a partially-red existing suite.
///
/// When CHUMP_EXTERNAL_VERIFY_FULL_SUITE != "1", returns CoveredByCi.
fn run_full_suite_delta(
    clone_dir: &Path,
    base_sha: &str,
    head_sha: &str,
    runner: &TestRunner,
) -> anyhow::Result<RegressionResult> {
    if std::env::var("CHUMP_EXTERNAL_VERIFY_FULL_SUITE").as_deref() != Ok("1") {
        return Ok(RegressionResult::CoveredByCi);
    }

    // Run on base.
    println!(
        "[verify-merge] Gate 3: running full suite on base ({}) ...",
        &base_sha[..base_sha.len().min(12)]
    );
    git_checkout_detach(clone_dir, base_sha)?;
    if let Err(e) = ensure_deps(clone_dir, runner) {
        return Ok(RegressionResult::InstallFailed {
            reason: e.to_string(),
        });
    }
    let base_failures = collect_failing_tests(clone_dir, runner)?;
    println!(
        "[verify-merge] Gate 3: base failures: {}",
        base_failures.len()
    );

    // Run on head.
    println!(
        "[verify-merge] Gate 3: running full suite on head ({}) ...",
        &head_sha[..head_sha.len().min(12)]
    );
    git_checkout_detach(clone_dir, head_sha)?;
    if let Err(e) = ensure_deps(clone_dir, runner) {
        return Ok(RegressionResult::InstallFailed {
            reason: e.to_string(),
        });
    }
    let head_failures = collect_failing_tests(clone_dir, runner)?;
    println!(
        "[verify-merge] Gate 3: head failures: {}",
        head_failures.len()
    );

    // Delta: tests that passed on base but fail on head.
    let newly_failing: Vec<String> = head_failures.difference(&base_failures).cloned().collect();

    let base_fail_count = base_failures.len();
    let head_fail_count = head_failures.len();

    if newly_failing.is_empty() {
        Ok(RegressionResult::Pass {
            base_fail_count,
            head_fail_count,
        })
    } else {
        Ok(RegressionResult::NewFailures {
            newly_failing,
            base_fail_count,
            head_fail_count,
        })
    }
}

/// Run the full suite and collect names of failing tests.
///
/// Uses the full-suite command and parses output to extract test identifiers.
/// For runners where parsing is not available (Make), failure = any non-zero
/// exit and the sentinel "ALL" is used.
fn collect_failing_tests(clone_dir: &Path, runner: &TestRunner) -> anyhow::Result<HashSet<String>> {
    let cmd_and_args = full_suite_command(runner);
    let output = Command::new(&cmd_and_args[0])
        .args(&cmd_and_args[1..])
        .current_dir(clone_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| anyhow::anyhow!("full suite runner: {e}"))?;

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    if output.status.success() {
        return Ok(HashSet::new());
    }

    // Parse failing test names from combined output.
    let failures = parse_failing_tests(runner, &combined);
    Ok(failures)
}

/// Extract failing test identifiers from runner output.
/// Returns a set of test name strings. For runners where parsing is not
/// practical, returns {"ALL"} on any failure so the delta comparison still
/// works (pre-existing ALL failure on both base+head → no regression).
fn parse_failing_tests(runner: &TestRunner, output: &str) -> HashSet<String> {
    let mut failures = HashSet::new();
    match runner {
        TestRunner::Cargo => {
            // Cargo test output: "test path::to::test_name ... FAILED"
            for line in output.lines() {
                let trimmed = line.trim();
                if trimmed.ends_with("... FAILED") || trimmed.ends_with("...FAILED") {
                    let name = trimmed
                        .trim_end_matches("FAILED")
                        .trim_end_matches("...")
                        .trim()
                        .to_string();
                    if !name.is_empty() {
                        failures.insert(name);
                    }
                }
            }
            // Fallback if no individual failures parsed but suite failed.
            if failures.is_empty() {
                failures.insert("ALL".to_string());
            }
        }
        TestRunner::Npm => {
            // Jest output: "  ✕ test description" or "  × test description"
            // Also: "FAIL src/foo.test.js"
            for line in output.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("✕ ")
                    || trimmed.starts_with("× ")
                    || trimmed.starts_with("FAIL ")
                    || trimmed.starts_with("✗ ")
                {
                    failures.insert(trimmed.to_string());
                }
            }
            if failures.is_empty() {
                failures.insert("ALL".to_string());
            }
        }
        TestRunner::Pytest => {
            // pytest output: "FAILED tests/test_foo.py::test_bar"
            for line in output.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("FAILED ") {
                    let name = trimmed.trim_start_matches("FAILED ").trim().to_string();
                    if !name.is_empty() {
                        failures.insert(name);
                    }
                }
            }
            if failures.is_empty() {
                failures.insert("ALL".to_string());
            }
        }
        TestRunner::Make | TestRunner::Unknown => {
            // Can't parse — treat any failure as the sentinel "ALL".
            failures.insert("ALL".to_string());
        }
    }
    failures
}

fn full_suite_command(runner: &TestRunner) -> Vec<String> {
    match runner {
        TestRunner::Cargo => vec!["cargo".into(), "test".into()],
        TestRunner::Npm => {
            let npm = std::env::var("CHUMP_NPM_BIN").unwrap_or_else(|_| "npm".to_string());
            vec![npm, "test".into()]
        }
        TestRunner::Pytest => vec![python_bin(), "-m".into(), "pytest".into()],
        TestRunner::Make => vec!["make".into(), "test".into()],
        TestRunner::Unknown => vec!["true".into()],
    }
}

/// EFFECTIVE-387: decide which AC bullets Gate 4 judges. Stored bullets win; when
/// there are none and synth is enabled, use the synthesized set (if it produced
/// any); otherwise none (Gate 4 skips). Returns `(bullets, was_synthesized)`. Pure —
/// unit-tested, so the on-ramp's selection logic is verifiable without the LLM.
fn select_gate_bullets(
    stored: Vec<String>,
    synth_enabled: bool,
    synth: Option<Vec<String>>,
) -> (Vec<String>, bool) {
    if !stored.is_empty() {
        return (stored, false);
    }
    if synth_enabled {
        if let Some(sb) = synth {
            if !sb.is_empty() {
                return (sb, true);
            }
        }
    }
    (Vec::new(), false)
}

/// EFFECTIVE-387: synthesize acceptance criteria for a PR that has none stored, by
/// feeding its title + body + diff to the AC-writer (EFFECTIVE-386). Returns `None`
/// on any failure so Gate 4 skips (fail-open). This is the hands-free-loop on-ramp:
/// a gap-less PR gets judgeable criteria instead of a silent CI-only pass.
fn synth_ac_for_pr(opts: &Opts) -> Option<Vec<String>> {
    let pr = opts.pr.to_string();
    let meta = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "view",
            &pr,
            "--repo",
            &opts.repo,
            "--json",
            "title,body",
        ])
        .output()
        .ok()?;
    if !meta.status.success() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&meta.stdout).ok()?;
    let title = v.get("title").and_then(|x| x.as_str()).unwrap_or("");
    let body = v.get("body").and_then(|x| x.as_str()).unwrap_or("");
    if title.trim().is_empty() {
        return None;
    }
    let diff = Command::new(&opts.gh_bin)
        .args(["pr", "diff", &pr, "--repo", &opts.repo])
        .output()
        .ok()?;
    let full_diff = String::from_utf8_lossy(&diff.stdout).into_owned();
    let diff_ctx: String = full_diff.chars().take(40_000).collect();
    let mut bullets =
        crate::pr_ac_coverage::generate_ac(title, body, &diff_ctx).unwrap_or_default();
    // PEER-VERI-08 (INFRA-3655) AC#1: a diff touching a systemd unit, install
    // script, or deploy path gets a PROVEN-BY bullet injected even when the
    // LLM writer didn't think to add one — liveness can't be skipped by
    // omission. Scanned against the FULL diff (not the 40k-char-truncated
    // LLM context) so a proof target beyond the truncation point is still
    // found. Docs-only diffs (no service surface touched) get none.
    if let Some(proof) = crate::pr_ac_coverage::maybe_inject_proof_ac(&full_diff, &bullets) {
        bullets.push(proof);
    }
    if bullets.is_empty() {
        None
    } else {
        Some(bullets)
    }
}

// ── Post-merge LIVE outcome probe (CREDIBLE-COTG-3.1) ───────────────────────
//
// Gates 1-4 prove the PR is well-formed (CI green, a real behavioral test,
// no regression, AC covered) — but every one of them runs against the repo
// checkout, BEFORE the merge lands anywhere live. None of them prove the
// *outcome* the PR was written to cause: e.g. a broken-link fix that leaves
// the link broken because it fixed the wrong file, or a deploy config change
// that never actually rolls out. The outcome probe closes that gap: after
// --apply merges the PR, fetch a caller-supplied live URL and assert the
// expected substring is now present. Opt-in (`--outcome-probe-url` +
// `--outcome-probe-contains`) since most gaps have no single live surface to
// check, and it can never hold the merge — the PR is already merged by the
// time this runs, so a probe failure is a durable-fix signal for a human /
// follow-up gap, not something this process can undo.

/// Pure matcher — no I/O — so the "does the outcome match" logic is testable
/// without a live network fetch. Case-sensitive, trims neither side (a probe
/// author who wants insensitivity/trimming controls that in the substring
/// they pass in).
fn outcome_probe_matches(content: &str, expected_substring: &str) -> bool {
    content.contains(expected_substring)
}

/// Fetch `url` via `curl` (already a fleet-wide dependency; avoids adding
/// reqwest to chump-verify, which is deliberately kept dependency-light for
/// compile speed — see the crate-level doc comment in Cargo.toml).
fn fetch_url_for_probe(url: &str, curl_bin: &str) -> anyhow::Result<String> {
    let out = Command::new(curl_bin)
        .args(["-sL", "--max-time", "20", url])
        .output()
        .map_err(|e| anyhow::anyhow!("curl: {e}"))?;
    if !out.status.success() {
        anyhow::bail!(
            "curl exited {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

// ── CREDIBLE-COTG-3.1 finish: real-CDP outcome probe ────────────────────────
//
// `fetch_url_for_probe` (curl) only sees the server's initial response body —
// on a JS-rendered SPA the `--outcome-probe-contains` substring may only
// exist in the client-rendered DOM, never in the raw HTML curl sees. That
// makes the probe blind to the exact class of "shipped but doesn't actually
// work live" bug it exists to catch on modern frontends. Promote to a real
// headless-Chromium render (`--dump-dom`, same CDP-backed engine src/browser.rs
// already shells out to for screenshots) so the probe sees what a user's
// browser would. Opt-in (CHUMP_OUTCOME_PROBE_RENDER=1) and falls back to curl
// on any failure (missing binary, timeout, non-zero exit) so a broken/absent
// Chromium never turns a passing probe into a false HELD — the merge has
// already happened, so a fetch failure must never be silently treated as
// probe failure when a working fallback exists.

/// Locate a headless-Chromium-family binary, honoring `CHUMP_CHROMIUM_BIN`
/// as an override. Returns `None` if nothing usable is on PATH.
fn find_chromium_bin() -> Option<String> {
    if let Ok(bin) = std::env::var("CHUMP_CHROMIUM_BIN") {
        if !bin.is_empty() {
            return Some(bin);
        }
    }
    [
        "chromium",
        "chromium-browser",
        "google-chrome",
        "google-chrome-stable",
    ]
    .iter()
    .find(|b| {
        Command::new("which")
            .arg(b)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    })
    .map(|b| b.to_string())
}

/// Render `url` through headless Chromium and return the post-JS DOM as text
/// (`--dump-dom`). Real CDP-backed rendering — same engine as `simple_screenshot`
/// in `src/browser.rs`, no chromiumoxide dep needed for this text-only use case.
fn render_url_via_chromium(
    url: &str,
    chromium_bin: &str,
    timeout_secs: u64,
) -> anyhow::Result<String> {
    let mut child = Command::new(chromium_bin)
        .args([
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--virtual-time-budget=8000",
            "--dump-dom",
            url,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| anyhow::anyhow!("failed to spawn {chromium_bin}: {e}"))?;

    let deadline = std::time::Duration::from_secs(timeout_secs);
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = child.wait_with_output()?;
                if !status.success() {
                    anyhow::bail!(
                        "{chromium_bin} --dump-dom exited {}: {}",
                        status,
                        String::from_utf8_lossy(&out.stderr)
                    );
                }
                return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
            }
            Ok(None) => {
                if start.elapsed() >= deadline {
                    let _ = child.kill();
                    anyhow::bail!("{chromium_bin} --dump-dom timed out after {timeout_secs}s");
                }
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
            Err(e) => anyhow::bail!("{chromium_bin} wait error: {e}"),
        }
    }
}

/// Runs the post-merge outcome probe if configured; no-ops if the opts don't
/// carry `outcome_probe_url` + `outcome_probe_contains`. Never returns an
/// error to the caller — a probe failure is logged + emitted to ambient, but
/// the merge already happened and cannot be gated retroactively.
fn run_outcome_probe(opts: &Opts) {
    let (Some(url), Some(expected)) = (&opts.outcome_probe_url, &opts.outcome_probe_contains)
    else {
        return;
    };

    // CREDIBLE-COTG-3.1: opt-in CDP-rendered fetch, falling back to curl.
    let render_enabled = std::env::var("CHUMP_OUTCOME_PROBE_RENDER").as_deref() == Ok("1");
    let render_timeout: u64 = std::env::var("CHUMP_OUTCOME_PROBE_RENDER_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30);

    let curl_fallback = |reason: Option<&str>| -> anyhow::Result<String> {
        if let Some(r) = reason {
            println!(
                "\n[verify-merge] Outcome probe: {r} — falling back to curl fetch of {url} ..."
            );
        } else {
            println!("\n[verify-merge] Outcome probe: fetching {url} ...");
        }
        let curl_bin = std::env::var("CHUMP_CURL_BIN").unwrap_or_else(|_| "curl".to_string());
        fetch_url_for_probe(url, &curl_bin)
    };

    let mut method = "curl";
    let body_result: anyhow::Result<String> = if render_enabled {
        match find_chromium_bin() {
            Some(bin) => {
                println!(
                    "\n[verify-merge] Outcome probe: rendering {url} via headless Chromium ({bin}) ..."
                );
                match render_url_via_chromium(url, &bin, render_timeout) {
                    Ok(dom) => {
                        method = "browser";
                        Ok(dom)
                    }
                    Err(e) => curl_fallback(Some(&format!("browser render failed ({e:#})"))),
                }
            }
            None => curl_fallback(Some(
                "CHUMP_OUTCOME_PROBE_RENDER=1 but no Chromium binary found",
            )),
        }
    } else {
        curl_fallback(None)
    };

    match body_result {
        Ok(body) => {
            if outcome_probe_matches(&body, expected) {
                println!(
                    "  PASS: live outcome confirmed via {method} (found {expected:?} at {url})"
                );
                emit_outcome_probe(opts, url, true, &format!("match found via {method}"));
            } else {
                println!(
                    "  FAIL: live outcome NOT confirmed via {method} — {expected:?} not found at {url}"
                );
                emit_outcome_probe(
                    opts,
                    url,
                    false,
                    &format!("substring not found in probe response (method={method})"),
                );
            }
        }
        Err(e) => {
            println!("  FAIL: outcome probe fetch error: {e:#}");
            emit_outcome_probe(opts, url, false, &format!("fetch error: {e}"));
        }
    }
}

/// Emit `kind=outcome_probe_verified` / `kind=outcome_probe_failed`.
/// ambient-kind: outcome_probe_verified  CREDIBLE-COTG-3.1 emitter: crates/chump-verify/src/external_verify_merge.rs
/// ambient-kind: outcome_probe_failed  CREDIBLE-COTG-3.1 emitter: crates/chump-verify/src/external_verify_merge.rs
fn emit_outcome_probe(opts: &Opts, url: &str, passed: bool, note: &str) {
    let kind = if passed {
        "outcome_probe_verified"
    } else {
        "outcome_probe_failed"
    };
    emit_ambient_event(
        kind,
        &[
            ("pr", &opts.pr.to_string()),
            ("repo", &opts.repo),
            ("gap", &opts.gap),
            ("url", url),
            ("note", note),
        ],
    );
}

/// Execute `gh pr merge <N> --repo <repo> --squash`.
///
/// INFRA-8221: refuses (Err) a PR held by the one arm policy — a
/// `no-auto-merge` / hold label or an `Auto-merge: hold` line — before gh
/// runs; the refusal is emitted as `kind=pr_arm_skipped_hold`.
fn merge_pr(opts: &Opts) -> anyhow::Result<bool> {
    chump_ship::arm_policy::require_touch_allowed(
        opts.pr,
        &opts.repo,
        "chump-verify(external_verify_merge)",
    )
    .map_err(|held| anyhow::anyhow!("{held}"))?;
    let status = Command::new(&opts.gh_bin)
        .args([
            "pr",
            "merge",
            &opts.pr.to_string(),
            "--repo",
            &opts.repo,
            "--squash",
        ])
        .status()
        .map_err(|e| anyhow::anyhow!("gh pr merge: {e}"))?;
    Ok(status.success())
}

// ── Ambient emission ──────────────────────────────────────────────────────

/// Emit `kind=external_merge_verified` — all gates passed.
/// ambient-kind: external_merge_verified  CREDIBLE-096 emitter: src/external_verify_merge.rs
fn emit_verified(opts: &Opts, proof: &Proof) {
    let proof_json = serde_json::json!({
        "ci_checks": proof.ci_checks.len(),
        "test_files": proof.test_files,
        "base_sha": &proof.base_sha[..proof.base_sha.len().min(12)],
        "head_sha": &proof.head_sha[..proof.head_sha.len().min(12)],
    });
    emit_ambient_event(
        "external_merge_verified",
        &[
            ("pr", &opts.pr.to_string()),
            ("repo", &opts.repo),
            ("gap", &opts.gap),
            ("proof", &proof_json.to_string()),
        ],
    );
}

/// Emit `kind=external_merge_held` — at least one gate failed.
/// ambient-kind: external_merge_held  CREDIBLE-096 emitter: src/external_verify_merge.rs
fn emit_held(opts: &Opts, reason: &str) {
    emit_ambient_event(
        "external_merge_held",
        &[
            ("pr", &opts.pr.to_string()),
            ("repo", &opts.repo),
            ("gap", &opts.gap),
            ("reason", reason),
        ],
    );
}

/// Emit `kind=advisory_check_red` — advisory check(s) are red but verified is posted.
/// RESILIENT-1365: loud routed signal when advisory check red would withhold verified.
/// ambient-kind: advisory_check_red  RESILIENT-1365 emitter: src/external_verify_merge.rs
fn emit_advisory_check_red(opts: &Opts, red_checks: &[String]) {
    let context = red_checks.join(", ");
    let message = format!(
        "verified withheld on #{}: advisory check {} red -> rerun",
        opts.pr, context
    );
    emit_ambient_event(
        "advisory_check_red",
        &[
            ("pr", &opts.pr.to_string()),
            ("repo", &opts.repo),
            ("gap", &opts.gap),
            ("message", &message),
        ],
    );
}

/// Git command with the hook-exported GIT_* environment scrubbed.
/// Every git op in this module targets an explicit external clone dir
/// (via `-C` or `.current_dir`), but GIT_DIR/GIT_WORK_TREE — exported by
/// git when this code runs inside a hook (pre-push → preflight → tests, or
/// a hook-invoked verify-merge) — override both, silently redirecting the
/// op to the HOST repo (RESILIENT-172). Scrub them at the source.
fn ext_git() -> Command {
    let mut c = Command::new("git");
    for k in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY",
        "GIT_COMMON_DIR",
    ] {
        c.env_remove(k);
    }
    c
}

fn emit_ambient_event(kind: &str, fields: &[(&str, &str)]) {
    // Mirror the pattern from src/orchestrate.rs::emit_ambient_event.
    let ambient = if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        PathBuf::from(path)
    } else {
        let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        // Walk up to find repo root (has Cargo.toml + [workspace]).
        loop {
            let cargo = dir.join("Cargo.toml");
            if cargo.exists() {
                if let Ok(c) = std::fs::read_to_string(&cargo) {
                    if c.contains("[workspace]") {
                        break;
                    }
                }
            }
            if !dir.pop() {
                dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
                break;
            }
        }
        let lock_dir = dir.join(".chump-locks");
        let _ = std::fs::create_dir_all(&lock_dir);
        lock_dir.join("ambient.jsonl")
    };

    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut map = serde_json::Map::new();
    map.insert("ts".into(), serde_json::Value::String(ts));
    map.insert("kind".into(), serde_json::Value::String(kind.into()));
    for (k, v) in fields {
        map.insert((*k).into(), serde_json::Value::String((*v).into()));
    }
    if let Ok(line) = serde_json::to_string(&serde_json::Value::Object(map)) {
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient)
            .and_then(|mut f| writeln!(f, "{line}"));
    }
}

// ── Unit tests ────────────────────────────────────────────────────────────
//
// CREDIBLE-102 tests: poll_ci_until_terminal with fake gh binary + counter file.
// CREDIBLE-104 tests: ensure_deps, base-overlay, Gate-3 delta.
//
// Tests that set env vars are #[serial_test::serial] to prevent races.

#[cfg(test)]
mod tests {
    use super::{is_advisory_check, select_gate_bullets};

    #[test]
    fn test_is_advisory_check_required_context() {
        let required = vec!["CI".to_string(), "tests".to_string()];
        let advisory_subs = vec![];

        // Check in required list → not advisory
        assert!(!is_advisory_check(
            "CI",
            "",
            &advisory_subs,
            Some(&required)
        ));
        assert!(!is_advisory_check(
            "tests",
            "",
            &advisory_subs,
            Some(&required)
        ));

        // Check NOT in required list → advisory
        assert!(is_advisory_check(
            "vercel",
            "",
            &advisory_subs,
            Some(&required)
        ));
        assert!(is_advisory_check(
            "unknown-check",
            "",
            &advisory_subs,
            Some(&required)
        ));

        // Case-insensitive matching
        assert!(!is_advisory_check(
            "ci",
            "",
            &advisory_subs,
            Some(&required)
        ));
        assert!(!is_advisory_check(
            "TESTS",
            "",
            &advisory_subs,
            Some(&required)
        ));
    }

    #[test]
    fn test_is_advisory_check_env_advisory_list() {
        let required = vec!["CI".to_string()];
        let advisory_subs = vec!["vercel".to_string(), "lint".to_string()];

        // Check in env advisory list → advisory
        assert!(is_advisory_check(
            "vercel-prod",
            "",
            &advisory_subs,
            Some(&required)
        ));
        assert!(is_advisory_check(
            "lint-check",
            "",
            &advisory_subs,
            Some(&required)
        ));

        // Case-insensitive substring matching
        assert!(is_advisory_check(
            "VERCEL-PREVIEW",
            "",
            &advisory_subs,
            Some(&required)
        ));

        // Check not in either list → depends on required_contexts
        assert!(!is_advisory_check(
            "CI",
            "",
            &advisory_subs,
            Some(&required)
        ));
    }

    #[test]
    fn test_is_advisory_check_benign_infra() {
        let required = vec!["CI".to_string(), "vercel-preview".to_string()];
        let advisory_subs = vec![];

        // Vercel check with account verification message → advisory (benign)
        let vercel_detail = "GitHub couldn't verify an account for the commit";
        assert!(is_advisory_check(
            "vercel-preview",
            vercel_detail,
            &advisory_subs,
            Some(&required)
        ));

        // Vercel check without account verification message → required (in required list, not benign)
        let other_detail = "Deployment failed due to error";
        assert!(!is_advisory_check(
            "vercel-preview",
            other_detail,
            &advisory_subs,
            Some(&required)
        ));

        // Non-Vercel check not in required list → advisory (not in required_contexts)
        assert!(is_advisory_check(
            "heroku-deploy",
            vercel_detail,
            &advisory_subs,
            Some(&required)
        ));
    }

    #[test]
    fn test_is_advisory_check_no_required_contexts() {
        let advisory_subs = vec!["advisory".to_string()];

        // With no required_contexts, only env list and benign predicate apply
        assert!(!is_advisory_check("CI", "", &advisory_subs, None));
        assert!(is_advisory_check(
            "advisory-check",
            "",
            &advisory_subs,
            None
        ));

        // Benign infra check → advisory
        let vercel_detail = "GitHub couldn't verify an account for the commit";
        assert!(is_advisory_check(
            "vercel-check",
            vercel_detail,
            &advisory_subs,
            None
        ));
    }

    #[test]
    fn test_is_advisory_check_env_overrides_required() {
        let required = vec!["CI".to_string()];
        let advisory_subs = vec!["ci".to_string()];

        // Even if check is in required_contexts, env advisory list overrides it
        assert!(is_advisory_check("CI", "", &advisory_subs, Some(&required)));
    }

    #[test]
    fn effective387_select_gate_bullets_prefers_stored_then_synth_then_none() {
        let stored = vec!["real bullet".to_string()];
        let synth = Some(vec!["synth bullet".to_string()]);
        // Stored present → use stored, not synthesized (even if synth exists).
        let (b, s) = select_gate_bullets(stored.clone(), true, synth.clone());
        assert_eq!(b, stored);
        assert!(!s);
        // No stored + synth on + synth produced → use synth, flagged synthesized.
        let (b, s) = select_gate_bullets(vec![], true, synth.clone());
        assert_eq!(b, vec!["synth bullet".to_string()]);
        assert!(s);
        // No stored + synth OFF → none (Gate 4 skips), even if a synth result was passed.
        let (b, s) = select_gate_bullets(vec![], false, synth.clone());
        assert!(b.is_empty());
        assert!(!s);
        // No stored + synth on but synth failed/empty → none (fail-open skip).
        let (b, s) = select_gate_bullets(vec![], true, None);
        assert!(b.is_empty());
        assert!(!s);
        let (b, s) = select_gate_bullets(vec![], true, Some(vec![]));
        assert!(b.is_empty());
        assert!(!s);
    }

    /// Git command for fixture repos with the hook-exported GIT_* environment
    /// scrubbed. When cargo test runs inside a git hook (pre-push -> chump
    /// preflight -> cargo test), git exports GIT_DIR/GIT_WORK_TREE/
    /// GIT_INDEX_FILE for the HOST repo — and GIT_DIR overrides
    /// Command::current_dir entirely, so every fixture git op silently
    /// mutates the host repo instead of its TempDir (RESILIENT-172: observed
    /// rewriting remotes, git identity, and committing fixture files onto
    /// real branches). Always use this instead of Command::new("git") in
    /// tests; pair with .current_dir(<fixture dir>) as before.
    fn fixture_git() -> Command {
        let mut c = Command::new("git");
        for k in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_PREFIX",
            "GIT_OBJECT_DIRECTORY",
            "GIT_COMMON_DIR",
        ] {
            c.env_remove(k);
        }
        c
    }

    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    /// Build a minimal Opts with a custom gh_bin and PR=1 on owner/test-repo.
    fn make_opts(gh_bin: &str) -> Opts {
        Opts {
            pr: 1,
            repo: "owner/test-repo".into(),
            gap: "CREDIBLE-102".into(),
            clone_dir: None,
            apply: false,
            gh_bin: gh_bin.to_string(),
            outcome_probe_url: None,
            outcome_probe_contains: None,
        }
    }

    /// Write a shell script to `dir/gh` and make it executable.
    /// Returns the path to the script.
    fn write_fake_gh(dir: &std::path::Path, script_body: &str) -> String {
        let bin = dir.join("gh");
        let content = format!("#!/usr/bin/env bash\n{script_body}\n");
        fs::write(&bin, content).expect("write fake gh");
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).expect("chmod fake gh");
        bin.to_string_lossy().into_owned()
    }

    /// Build a fake gh script that uses a counter file to cycle through
    /// `responses`.  Each call to gh (when the args contain "statusCheckRollup")
    /// increments the counter and returns the corresponding JSON.
    /// Other calls (baseRefOid, merge, etc.) return a safe stub.
    fn fake_gh_with_responses(dir: &std::path::Path, responses: &[&str]) -> String {
        let counter_file = dir.join("call_counter");
        fs::write(&counter_file, "0").expect("write counter");

        // Embed responses as a bash array.
        let responses_bash: Vec<String> = responses
            .iter()
            .map(|r| format!("'{}'", r.replace('\'', "'\\''")))
            .collect();
        let array_literal = responses_bash.join(" ");
        let counter_path = counter_file.to_string_lossy().into_owned();

        let script = format!(
            r#"
RESPONSES=({array_literal})
COUNT_FILE='{counter_path}'
COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
ARGS="$*"
if echo "$ARGS" | grep -q "statusCheckRollup"; then
    IDX=$COUNT
    if [ "$IDX" -ge "${{#RESPONSES[@]}}" ]; then
        IDX=$(( ${{#RESPONSES[@]}} - 1 ))
    fi
    echo "${{RESPONSES[$IDX]}}"
    echo $(( COUNT + 1 )) > "$COUNT_FILE"
elif echo "$ARGS" | grep -q "baseRefOid"; then
    echo '{{"baseRefOid":"aabbcc112233","headRefOid":"ddeeff445566"}}'
else
    echo '{{}}'
fi
"#
        );
        write_fake_gh(dir, &script)
    }

    // ── CREDIBLE-102: poll_ci_until_terminal tests ────────────────────────

    // ── (a) pending → pending → SUCCESS: Gate 1 PASS ─────────────────────
    #[test]
    #[serial_test::serial]
    fn test_ci_wait_pending_then_success() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let pending_json =
            r#"{"statusCheckRollup":[{"name":"CI","status":"IN_PROGRESS","conclusion":null}]}"#;
        let success_json =
            r#"{"statusCheckRollup":[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]}"#;

        let gh_bin =
            fake_gh_with_responses(tmp.path(), &[pending_json, pending_json, success_json]);

        // POLL_SECS=0 for instant polling; WAIT_SECS large enough to not time out.
        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        // Redirect ambient writes.
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green { check_count, .. } => {
                assert_eq!(check_count, 1, "expected 1 check to be green");
            }
            other => panic!(
                "expected CiResult::Green, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => "TimedOut",
                    _ => unreachable!(),
                }
            ),
        }
    }

    // ── CREDIBLE-176: empty rollup right after PR-open must WAIT, not no-gates ──
    // Regression guard for the bench-lap failure: PR opened seconds earlier,
    // GitHub hadn't registered the workflow check-runs yet → transiently empty
    // rollup was wrongly read as "repo has no CI". Now it waits out the grace
    // window and judges the checks once they appear.
    #[test]
    #[serial_test::serial]
    fn test_ci_empty_then_checks_appear_is_not_nogates() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let empty_json = r#"{"statusCheckRollup":[]}"#;
        let success_json =
            r#"{"statusCheckRollup":[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]}"#;

        // First two polls: empty rollup (checks not registered yet). Third: green.
        let gh_bin = fake_gh_with_responses(tmp.path(), &[empty_json, empty_json, success_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        // Grace window > 0 so the empty polls WAIT rather than concluding no-gates.
        std::env::set_var("CHUMP_VERIFY_CI_EMPTY_GRACE_SECS", "3600");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green { check_count, .. } => {
                assert_eq!(
                    check_count, 1,
                    "checks appeared after grace — should judge them green"
                );
            }
            other => panic!(
                "empty-then-registered must NOT be NoGates; got {}",
                match other {
                    CiResult::NoGates => "NoGates (CREDIBLE-176 regression)",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => "TimedOut",
                    _ => unreachable!(),
                }
            ),
        }
    }

    // ── CREDIBLE-176: genuinely no CI (empty past grace) still → NoGates ──
    // The fix must not break the real "repo has no CI" case: with the grace
    // window elapsed and the rollup still empty, the verdict stays NoGates.
    #[test]
    #[serial_test::serial]
    fn test_ci_empty_past_grace_is_nogates() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let empty_json = r#"{"statusCheckRollup":[]}"#;
        let gh_bin = fake_gh_with_responses(tmp.path(), &[empty_json, empty_json, empty_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        // Grace = 0 → an empty rollup is immediately treated as no-gates.
        std::env::set_var("CHUMP_VERIFY_CI_EMPTY_GRACE_SECS", "0");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        assert!(
            matches!(result, CiResult::NoGates),
            "empty rollup past grace must remain NoGates (genuine no-CI case)"
        );
    }

    // ── (b) pending → FAILURE: Gate 1 HELD(ci) ───────────────────────────
    #[test]
    #[serial_test::serial]
    fn test_ci_wait_pending_then_failure() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let pending_json =
            r#"{"statusCheckRollup":[{"name":"tests","status":"IN_PROGRESS","conclusion":null}]}"#;
        let failure_json = r#"{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"FAILURE"}]}"#;

        let gh_bin = fake_gh_with_responses(tmp.path(), &[pending_json, failure_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Red { failing } => {
                assert!(
                    failing.iter().any(|f| f.contains("tests")),
                    "expected 'tests' in failing list, got {:?}",
                    failing
                );
            }
            other => panic!(
                "expected CiResult::Red, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Green { .. } => "Green",
                    CiResult::TimedOut { .. } => "TimedOut",
                    CiResult::Red { .. } => unreachable!(),
                }
            ),
        }
    }

    // ── (c) stays pending past wait cap: HELD(ci_pending) ─────────────────
    #[test]
    #[serial_test::serial]
    fn test_ci_wait_timeout() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let pending_json =
            r#"{"statusCheckRollup":[{"name":"slow-job","status":"QUEUED","conclusion":null}]}"#;

        // Only ever returns pending — will time out immediately since WAIT_SECS=0.
        let gh_bin = fake_gh_with_responses(tmp.path(), &[pending_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        // WAIT_SECS=0 means the elapsed check fires on the first pending poll.
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "0");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::TimedOut { pending } => {
                assert!(
                    pending.iter().any(|p| p.contains("slow-job")),
                    "expected 'slow-job' in pending list, got {:?}",
                    pending
                );
            }
            other => panic!(
                "expected CiResult::TimedOut, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Green { .. } => "Green",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => unreachable!(),
                }
            ),
        }
    }

    // ── (d) required SUCCESS + advisory pending: Gate 1 PASS ─────────────
    #[test]
    #[serial_test::serial]
    fn test_ci_advisory_pending_does_not_gate() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        // required CI check SUCCESS, advisory "vercel" check still pending.
        let mixed_json = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},
            {"name":"Vercel Preview","status":"IN_PROGRESS","conclusion":null}
        ]}"#;

        let gh_bin = fake_gh_with_responses(tmp.path(), &[mixed_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        // Mark "vercel" as advisory (case-insensitive substring match).
        std::env::set_var("CHUMP_VERIFY_CI_ADVISORY_NAMES", "vercel");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green {
                check_count,
                checks,
                ..
            } => {
                // Only the non-advisory "CI" check should appear in the passing list.
                assert_eq!(check_count, 1, "expected 1 required check (CI)");
                assert!(
                    checks.iter().any(|c| c == "CI"),
                    "expected 'CI' in passing list, got {:?}",
                    checks
                );
            }
            other => panic!(
                "expected CiResult::Green (advisory pending should not gate), got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Red { .. } => "Red",
                    CiResult::TimedOut { .. } => "TimedOut",
                    _ => unreachable!(),
                }
            ),
        }
    }

    // ── CREDIBLE-228: required-checks-only Gate 1 ────────────────────────
    //
    // A fake gh that answers the three calls Gate 1 makes: statusCheckRollup,
    // baseRefName, and `api .../protection`. `protection_ok=false` makes the
    // protection call fail (exit 1) so the poll falls back to the benign-infra
    // predicate — modelling a repo with no readable branch protection.
    fn fake_gh_ci_protection(
        dir: &std::path::Path,
        rollup_json: &str,
        base_ref: &str,
        protection_json: &str,
        protection_ok: bool,
    ) -> String {
        let protection_arm = if protection_ok {
            format!("echo '{}'", protection_json.replace('\'', "'\\''"))
        } else {
            "echo 'Not Found' >&2; exit 1".to_string()
        };
        let script = format!(
            r#"
ARGS="$*"
if echo "$ARGS" | grep -q "statusCheckRollup"; then
    echo '{rollup}'
elif echo "$ARGS" | grep -q "baseRefName"; then
    echo '{{"baseRefName":"{base_ref}"}}'
elif echo "$ARGS" | grep -q "baseRefOid"; then
    echo '{{"baseRefOid":"aabbcc112233","headRefOid":"ddeeff445566"}}'
elif echo "$ARGS" | grep -q "protection"; then
    {protection_arm}
else
    echo '{{}}'
fi
"#,
            rollup = rollup_json.replace('\'', "'\\''"),
        );
        write_fake_gh(dir, &script)
    }

    fn reset_ci_env() {
        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        std::env::remove_var("CHUMP_VERIFY_CI_ADVISORY_NAMES");
        std::env::remove_var("CHUMP_VERIFY_CI_REQUIRED_ONLY");
    }

    /// The mission-blocker (Bug 1 / CREDIBLE-228 / originally filed as the
    /// CREDIBLE-106 symptom): a FAILING check that is NOT in the branch's
    /// required-status-check set must NOT hold the PR. Branch protection lists
    /// only "CI" as required; a failing "Vercel" status must be treated as
    /// advisory → Gate 1 PASS, not HELD(ci).
    #[test]
    #[serial_test::serial]
    fn test_ci_non_required_failing_check_does_not_gate() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let rollup = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},
            {"context":"Vercel","state":"FAILURE","description":"GitHub couldn't verify an account for the commit author"}
        ]}"#;
        // Branch protection requires ONLY "CI".
        let protection = r#"{"required_status_checks":{"contexts":["CI"]}}"#;
        let gh_bin = fake_gh_ci_protection(tmp.path(), rollup, "main", protection, true);

        reset_ci_env();
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green {
                check_count,
                checks,
                ..
            } => {
                assert_eq!(
                    check_count, 1,
                    "only the required 'CI' check should gate; the failing non-required Vercel check must be advisory"
                );
                assert!(
                    checks.iter().any(|c| c == "CI"),
                    "expected 'CI' in passing list, got {:?}",
                    checks
                );
            }
            other => panic!(
                "a failing NON-REQUIRED check must not cause HELD; expected Green, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Red { .. } =>
                        "Red (CREDIBLE-228 regression — self-closes autonomous PRs)",
                    CiResult::TimedOut { .. } => "TimedOut",
                    _ => unreachable!(),
                }
            ),
        }
    }

    /// Fallback path: when branch protection is UNREADABLE (404 / no admin),
    /// the curated benign-infra predicate must still spare Vercel's
    /// "couldn't verify an account" status from gating — no env config needed.
    #[test]
    #[serial_test::serial]
    fn test_ci_benign_vercel_account_check_does_not_gate_on_fallback() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let rollup = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},
            {"context":"Vercel","state":"FAILURE","description":"GitHub couldn't verify an account for the commit author"}
        ]}"#;
        // protection_ok=false → required_contexts is None → fallback to benign predicate.
        let gh_bin = fake_gh_ci_protection(tmp.path(), rollup, "main", "", false);

        reset_ci_env();
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        assert!(
            matches!(result, CiResult::Green { .. }),
            "benign Vercel account-verification status must not gate even without branch protection"
        );
    }

    /// RESILIENT-1399: required SUCCESS + advisory FAILING: Gate 1 PASS.
    /// Advisory checks that are red must NOT prevent posting verified when
    /// all required checks are green.
    #[test]
    #[serial_test::serial]
    fn test_ci_advisory_red_does_not_gate() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        // required "CI" check SUCCESS, advisory "lint" check FAILED.
        let mixed_json = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},
            {"name":"lint-check","status":"COMPLETED","conclusion":"FAILURE"}
        ]}"#;

        let gh_bin = fake_gh_with_responses(tmp.path(), &[mixed_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        // Mark "lint" as advisory (case-insensitive substring match).
        std::env::set_var("CHUMP_VERIFY_CI_ADVISORY_NAMES", "lint");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Green {
                check_count,
                checks,
                red_advisory,
            } => {
                // Only the required "CI" check should gate; the failing advisory check must not block.
                assert_eq!(check_count, 1, "expected 1 required check (CI)");
                assert!(
                    checks.iter().any(|c| c == "CI"),
                    "expected 'CI' in passing list, got {:?}",
                    checks
                );
                // RESILIENT-1365: red_advisory should be populated with the failing lint check.
                assert_eq!(red_advisory.len(), 1, "expected 1 red advisory check");
                assert!(
                    red_advisory.iter().any(|c| c.contains("lint")),
                    "expected 'lint' in red_advisory, got {:?}",
                    red_advisory
                );
            }
            other => panic!(
                "expected CiResult::Green (advisory red should not gate), got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Red { .. } =>
                        "Red (RESILIENT-1399 regression — advisory checks should not block)",
                    CiResult::TimedOut { .. } => "TimedOut",
                    _ => unreachable!(),
                }
            ),
        }
    }

    /// RESILIENT-1365: when advisory checks are red and verified is posted,
    /// emit `kind=advisory_check_red` signal to ambient.jsonl.
    #[test]
    #[serial_test::serial]
    fn test_emit_advisory_check_red_signal_when_advisory_red() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        // required "CI" check SUCCESS, advisory "lint" check FAILED.
        let mixed_json = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},
            {"name":"lint-check","status":"COMPLETED","conclusion":"FAILURE"}
        ]}"#;

        let gh_bin = fake_gh_with_responses(tmp.path(), &[mixed_json]);

        std::env::set_var("CHUMP_VERIFY_CI_POLL_SECS", "0");
        std::env::set_var("CHUMP_VERIFY_CI_WAIT_SECS", "3600");
        std::env::set_var("CHUMP_VERIFY_CI_ADVISORY_NAMES", "lint");
        let ambient_path = tmp.path().join("ambient.jsonl");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            ambient_path.to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        // Verify the gate passes and red_advisory is populated.
        let red_advisory = match result {
            CiResult::Green { red_advisory, .. } => red_advisory,
            _ => panic!("expected Green result"),
        };

        assert!(
            !red_advisory.is_empty(),
            "expected red_advisory to be populated"
        );

        // Emit the signal as the main code would.
        emit_advisory_check_red(&opts, &red_advisory);

        // Check that the ambient event was written.
        let ambient_content =
            std::fs::read_to_string(&ambient_path).expect("ambient.jsonl should be created");
        assert!(
            ambient_content.contains("advisory_check_red"),
            "ambient.jsonl should contain advisory_check_red event, got: {ambient_content}"
        );
        assert!(
            ambient_content.contains(&format!("#{}", opts.pr)),
            "ambient.jsonl should contain PR number, got: {ambient_content}"
        );
        assert!(
            ambient_content.contains("verified withheld"),
            "ambient.jsonl should contain 'verified withheld' message, got: {ambient_content}"
        );
    }

    /// Guard: a REAL required check that fails still HELDs — the fix must not
    /// turn Gate 1 into a rubber stamp.
    #[test]
    #[serial_test::serial]
    fn test_ci_required_failing_check_still_gates() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let rollup = r#"{"statusCheckRollup":[
            {"name":"CI","status":"COMPLETED","conclusion":"FAILURE"}
        ]}"#;
        let protection = r#"{"required_status_checks":{"contexts":["CI"]}}"#;
        let gh_bin = fake_gh_ci_protection(tmp.path(), rollup, "main", protection, true);

        reset_ci_env();
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let opts = make_opts(&gh_bin);
        let result = poll_ci_until_terminal(&opts).expect("poll_ci");

        match result {
            CiResult::Red { failing } => {
                assert!(
                    failing.iter().any(|f| f.contains("CI")),
                    "expected required 'CI' in failing list, got {:?}",
                    failing
                );
            }
            other => panic!(
                "a failing REQUIRED check must still HELD; expected Red, got: {}",
                match other {
                    CiResult::NoGates => "NoGates",
                    CiResult::Green { .. } =>
                        "Green (fix over-reached — Gate 1 became a rubber stamp)",
                    CiResult::TimedOut { .. } => "TimedOut",
                    CiResult::Red { .. } => unreachable!(),
                }
            ),
        }
    }

    // ── CREDIBLE-104 new tests ────────────────────────────────────────────

    /// Helper: create a minimal npm repo (package.json with jest test script)
    /// at `dir`. No node_modules. Two commits:
    ///   base: src/add.js with a bug (always returns 0), no test file
    ///   head branch: src/add.js fixed + __tests__/add.test.js that fails on buggy code
    ///
    /// Returns (base_sha, head_sha, test_file_path).
    fn setup_npm_repo(dir: &Path) -> (String, String, String) {
        std::fs::create_dir_all(dir).expect("create repo dir");
        fixture_git()
            .args(["init", "-q"])
            .current_dir(dir)
            .status()
            .expect("git init");
        fixture_git()
            .args(["config", "user.email", "test@example.com"])
            .current_dir(dir)
            .status()
            .ok();
        fixture_git()
            .args(["config", "user.name", "Test"])
            .current_dir(dir)
            .status()
            .ok();

        // package.json with a jest-like test script (we'll stub jest via CHUMP_NPX_BIN)
        fs::write(
            dir.join("package.json"),
            r#"{"name":"test-repo","version":"1.0.0","scripts":{"test":"jest"}}"#,
        )
        .expect("package.json");
        // package-lock.json so npm ci is preferred
        fs::write(dir.join("package-lock.json"), r#"{"lockfileVersion":3}"#).expect("lock");

        std::fs::create_dir_all(dir.join("src")).expect("src dir");
        // Buggy implementation: always returns 0
        fs::write(
            dir.join("src/add.js"),
            "module.exports = function add(a, b) { return 0; };\n",
        )
        .expect("src/add.js");

        fixture_git()
            .args(["add", "."])
            .current_dir(dir)
            .status()
            .expect("git add");
        fixture_git()
            .args(["commit", "-q", "-m", "base: buggy add"])
            .current_dir(dir)
            .status()
            .expect("git commit base");
        let base_sha = String::from_utf8(
            fixture_git()
                .args(["rev-parse", "HEAD"])
                .current_dir(dir)
                .output()
                .expect("rev-parse")
                .stdout,
        )
        .expect("utf8")
        .trim()
        .to_string();

        // PR head: fix the implementation AND add a test
        fixture_git()
            .args(["checkout", "-q", "-b", "pr-head"])
            .current_dir(dir)
            .status()
            .ok();
        fs::write(
            dir.join("src/add.js"),
            "module.exports = function add(a, b) { return a + b; };\n",
        )
        .expect("src/add.js fixed");

        std::fs::create_dir_all(dir.join("__tests__")).expect("__tests__ dir");
        // Test file that requires add.js; will only pass with the fixed implementation
        fs::write(
            dir.join("__tests__/add.test.js"),
            "const add = require('../src/add');\nif (add(1,2) !== 3) { process.exit(1); }\nconsole.log('pass');\n",
        ).expect("add.test.js");

        fixture_git()
            .args(["add", "."])
            .current_dir(dir)
            .status()
            .expect("git add head");
        fixture_git()
            .args(["commit", "-q", "-m", "fix: add returns sum + add test"])
            .current_dir(dir)
            .status()
            .expect("git commit head");
        let head_sha = String::from_utf8(
            fixture_git()
                .args(["rev-parse", "HEAD"])
                .current_dir(dir)
                .output()
                .expect("rev-parse")
                .stdout,
        )
        .expect("utf8")
        .trim()
        .to_string();

        (base_sha, head_sha, "__tests__/add.test.js".to_string())
    }

    /// Write a fake npm binary that records invocations.
    fn write_fake_npm(dir: &Path, invocation_log: &Path) -> String {
        let log = invocation_log.to_string_lossy().into_owned();
        let bin = dir.join("npm");
        fs::write(
            &bin,
            format!(
                "#!/usr/bin/env bash\necho \"npm $*\" >> \"{log}\"\n# ci and install succeed; test is handled by npx stub\nexit 0\n"
            ),
        ).expect("write fake npm");
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).expect("chmod npm");
        bin.to_string_lossy().into_owned()
    }

    /// Write a fake npx binary that runs the test file via `node` directly.
    /// When called as `npx jest --passWithNoTests <file>`, it runs the file with node.
    fn write_fake_npx(dir: &Path) -> String {
        let bin = dir.join("npx");
        fs::write(
            &bin,
            // Skip "jest" and "--passWithNoTests", run remaining args as node scripts.
            r#"#!/usr/bin/env bash
# Fake npx: skip "jest" and "--passWithNoTests", run remaining args with node
ARGS=("$@")
FILES=()
skip_next=0
for arg in "${ARGS[@]}"; do
    case "$arg" in
        jest|--passWithNoTests) continue ;;
        *) FILES+=("$arg") ;;
    esac
done
if [ ${#FILES[@]} -eq 0 ]; then
    exit 0
fi
for f in "${FILES[@]}"; do
    node "$f" || exit 1
done
exit 0
"#,
        )
        .expect("write fake npx");
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).expect("chmod npx");
        bin.to_string_lossy().into_owned()
    }

    // ── Test (a): Npm PR ADDS a test; base-overlay proves fail-on-base → MERGE ─

    #[test]
    #[serial_test::serial]
    fn test_npm_added_test_overlay_proves_fix() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let repo_dir = tmp.path().join("repo");
        let clone_dir = tmp.path().join("clone");
        let fake_bin_dir = tmp.path().join("fake_bins");
        fs::create_dir_all(&fake_bin_dir).expect("fake_bins dir");

        let (base_sha, head_sha, test_file) = setup_npm_repo(&repo_dir);

        // Clone it
        fixture_git()
            .args([
                "clone",
                "-q",
                repo_dir.to_str().unwrap(),
                clone_dir.to_str().unwrap(),
            ])
            .status()
            .expect("clone");
        // Make both SHAs available
        fixture_git()
            .args(["fetch", "-q", "origin", &base_sha, &head_sha])
            .current_dir(&clone_dir)
            .status()
            .ok();

        // Stub npm (records calls) and npx (runs node)
        let invocation_log = tmp.path().join("npm_invocations.txt");
        let _npm_bin = write_fake_npm(&fake_bin_dir, &invocation_log);
        let _npx_bin = write_fake_npx(&fake_bin_dir);

        std::env::set_var("CHUMP_NPM_BIN", fake_bin_dir.join("npm").to_str().unwrap());
        std::env::set_var("CHUMP_NPX_BIN", fake_bin_dir.join("npx").to_str().unwrap());
        std::env::set_var("CHUMP_VERIFY_DEPS_TIMEOUT_SECS", "30");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_str().unwrap(),
        );

        let runner = TestRunner::Npm;
        let test_files = vec![test_file];

        // Base run with overlay: should FAIL (base code is buggy, test file overlaid from head)
        let base_result =
            run_tests_at_sha_with_overlay(&clone_dir, &base_sha, &head_sha, &runner, &test_files)
                .expect("base overlay run");

        let base_passed = match base_result {
            TestRunResult::Ran { passed, .. } => passed,
            TestRunResult::InstallFailed { reason } => panic!("install failed on base: {reason}"),
        };
        assert!(
            !base_passed,
            "test should FAIL on base code (add always returns 0)"
        );

        // Head run (no overlay): should PASS (fixed code)
        let head_result = run_tests_at_sha_no_overlay(&clone_dir, &head_sha, &runner, &test_files)
            .expect("head run");

        let head_passed = match head_result {
            TestRunResult::Ran { passed, .. } => passed,
            TestRunResult::InstallFailed { reason } => panic!("install failed on head: {reason}"),
        };
        assert!(head_passed, "test should PASS on head code (add fixed)");

        // This combination (fail on base, pass on head) → MERGE verdict in Gate 2
    }

    // ── Test (b): ensure_deps invokes npm ci when node_modules absent ──────

    #[test]
    #[serial_test::serial]
    fn test_ensure_deps_calls_npm_ci_when_node_modules_absent() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let fake_bin_dir = tmp.path().join("bins");
        fs::create_dir_all(&fake_bin_dir).expect("bins dir");

        // Fake repo dir with package.json + package-lock.json (no node_modules)
        let repo_dir = tmp.path().join("repo");
        fs::create_dir_all(&repo_dir).expect("repo dir");
        fs::write(
            repo_dir.join("package.json"),
            r#"{"name":"x","scripts":{"test":"jest"}}"#,
        )
        .expect("pkg.json");
        fs::write(
            repo_dir.join("package-lock.json"),
            r#"{"lockfileVersion":3}"#,
        )
        .expect("lock");
        // No node_modules directory.

        let invocation_log = tmp.path().join("npm_calls.txt");
        let npm_bin = write_fake_npm(&fake_bin_dir, &invocation_log);

        std::env::set_var("CHUMP_NPM_BIN", &npm_bin);
        std::env::set_var("CHUMP_VERIFY_DEPS_TIMEOUT_SECS", "30");

        let result = ensure_deps(&repo_dir, &TestRunner::Npm);
        assert!(result.is_ok(), "ensure_deps should succeed: {:?}", result);

        // Check invocation log contains "npm ci"
        let log = fs::read_to_string(&invocation_log).unwrap_or_default();
        assert!(
            log.contains("npm ci"),
            "expected 'npm ci' in invocation log, got: {log:?}"
        );
    }

    // ── Test (c): Gate-3 delta: pre-existing failure not held; new regression is held ─

    #[test]
    #[serial_test::serial]
    fn test_gate3_delta_preexisting_failure_not_regression() {
        // Simulate: full suite on base has 1 failure ("old_test_fail").
        // Full suite on head also has that same failure + a NEW passing test added.
        // Delta: no new failures → PASS (not held).

        let base_failures: HashSet<String> = ["old_test_fail".to_string()].into_iter().collect();
        let head_failures: HashSet<String> = ["old_test_fail".to_string()].into_iter().collect();

        let newly_failing: Vec<String> =
            head_failures.difference(&base_failures).cloned().collect();

        assert!(
            newly_failing.is_empty(),
            "pre-existing failure should not be a regression: {:?}",
            newly_failing
        );
    }

    #[test]
    fn test_gate3_delta_new_regression_is_held() {
        // Simulate: base has no failures; head introduces a new one.
        let base_failures: HashSet<String> = HashSet::new();
        let head_failures: HashSet<String> =
            ["newly_broken_test".to_string()].into_iter().collect();

        let newly_failing: Vec<String> =
            head_failures.difference(&base_failures).cloned().collect();

        assert_eq!(
            newly_failing,
            vec!["newly_broken_test".to_string()],
            "new failure should be detected as regression"
        );
    }

    #[test]
    fn test_gate3_delta_mixed_preexisting_and_new() {
        // Simulate: base has 2 failures; head has those 2 plus a NEW one.
        let base_failures: HashSet<String> = ["fail_a".to_string(), "fail_b".to_string()]
            .into_iter()
            .collect();
        let head_failures: HashSet<String> = [
            "fail_a".to_string(),
            "fail_b".to_string(),
            "fail_new".to_string(),
        ]
        .into_iter()
        .collect();

        let newly_failing: Vec<String> =
            head_failures.difference(&base_failures).cloned().collect();

        assert_eq!(
            newly_failing,
            vec!["fail_new".to_string()],
            "only new failure should be detected"
        );
    }

    // ── CREDIBLE-COTG-3.1: post-merge outcome probe ────────────────────────

    #[test]
    fn outcome_probe_matches_when_substring_present() {
        let body = "<html><body>Deployed: v2.3.1 — fix confirmed live</body></html>";
        assert!(outcome_probe_matches(body, "fix confirmed live"));
    }

    #[test]
    fn outcome_probe_matches_false_when_substring_absent() {
        // Without the outcome_probe_matches implementation this would panic
        // (function undefined); with it, a body that never got the fix must
        // report false so the probe is reported as HELD/failed, not silently
        // treated as verified.
        let body = "<html><body>Deployed: v2.3.0 — old content</body></html>";
        assert!(!outcome_probe_matches(body, "fix confirmed live"));
    }

    #[test]
    fn outcome_probe_matches_is_case_sensitive() {
        let body = "Status: OK";
        assert!(!outcome_probe_matches(body, "status: ok"));
        assert!(outcome_probe_matches(body, "Status: OK"));
    }

    #[test]
    fn opts_parse_accepts_outcome_probe_flags() {
        let args: Vec<String> = [
            "--pr",
            "42",
            "--repo",
            "owner/repo",
            "--gap",
            "CREDIBLE-3494",
            "--outcome-probe-url",
            "https://example.com/status",
            "--outcome-probe-contains",
            "healthy",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();

        let opts = Opts::parse(&args).expect("parse should succeed");
        assert_eq!(
            opts.outcome_probe_url.as_deref(),
            Some("https://example.com/status")
        );
        assert_eq!(opts.outcome_probe_contains.as_deref(), Some("healthy"));
    }

    #[test]
    fn opts_parse_omits_outcome_probe_flags_by_default() {
        let args: Vec<String> = ["--pr", "42", "--repo", "owner/repo", "--gap", "GAP-1"]
            .iter()
            .map(|s| s.to_string())
            .collect();

        let opts = Opts::parse(&args).expect("parse should succeed");
        assert!(opts.outcome_probe_url.is_none());
        assert!(opts.outcome_probe_contains.is_none());
    }

    #[test]
    fn opts_parse_rejects_outcome_probe_url_without_contains() {
        let args: Vec<String> = [
            "--pr",
            "42",
            "--repo",
            "owner/repo",
            "--gap",
            "GAP-1",
            "--outcome-probe-url",
            "https://example.com",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();

        let err = match Opts::parse(&args) {
            Err(e) => e,
            Ok(_) => panic!("must require both flags together"),
        };
        assert!(err.to_string().contains("must be passed together"));
    }

    #[test]
    fn run_outcome_probe_noop_when_unconfigured() {
        // No url/contains configured — must not attempt any I/O or panic.
        let opts = make_opts("gh");
        run_outcome_probe(&opts);
    }

    // ── CREDIBLE-COTG-3.1: real-CDP render promotion ────────────────────────

    #[test]
    #[serial_test::serial]
    fn find_chromium_bin_honors_env_override() {
        std::env::set_var("CHUMP_CHROMIUM_BIN", "/opt/custom/my-chromium");
        let found = find_chromium_bin();
        std::env::remove_var("CHUMP_CHROMIUM_BIN");
        assert_eq!(found.as_deref(), Some("/opt/custom/my-chromium"));
    }

    #[test]
    #[serial_test::serial]
    fn find_chromium_bin_empty_override_falls_through_to_path_search() {
        // An empty override must not be treated as "found" — fall through to
        // the PATH search (which may legitimately find nothing on CI boxes).
        std::env::set_var("CHUMP_CHROMIUM_BIN", "");
        let found = find_chromium_bin();
        std::env::remove_var("CHUMP_CHROMIUM_BIN");
        // Whatever the PATH search returns, it must never be the empty string.
        if let Some(bin) = found {
            assert!(!bin.is_empty());
        }
    }

    #[test]
    fn render_url_via_chromium_errors_on_missing_binary() {
        let err = render_url_via_chromium(
            "https://example.com",
            "__chump_nonexistent_chromium_xyz__",
            5,
        )
        .unwrap_err();
        assert!(err.to_string().contains("failed to spawn"));
    }

    #[test]
    #[serial_test::serial]
    fn run_outcome_probe_render_falls_back_to_curl_when_no_chromium() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        std::env::set_var("CHUMP_OUTCOME_PROBE_RENDER", "1");
        std::env::set_var("CHUMP_CHROMIUM_BIN", "");
        std::env::set_var("CHUMP_CURL_BIN", "__chump_nonexistent_curl_xyz__");
        std::env::set_var(
            "CHUMP_AMBIENT_IN_PROMPT",
            tmp.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );

        let mut opts = make_opts("gh");
        opts.outcome_probe_url = Some("https://example.com".to_string());
        opts.outcome_probe_contains = Some("hello".to_string());

        // Must not panic even though both the render path and the curl
        // fallback are unavailable — a probe failure is logged/emitted, never
        // a crash (the merge already happened by the time this runs).
        run_outcome_probe(&opts);

        std::env::remove_var("CHUMP_OUTCOME_PROBE_RENDER");
        std::env::remove_var("CHUMP_CHROMIUM_BIN");
        std::env::remove_var("CHUMP_CURL_BIN");
    }

    /// INFRA-8221: the --apply merge refuses a held PR before gh runs.
    #[test]
    fn merge_pr_refuses_held_pr() {
        let tmp = tempfile::tempdir().unwrap();
        let amb = tmp.path().join("ambient.jsonl");
        let fake = chump_ship::arm_policy::testing::FakeFetcher::held_by_label("no-auto-merge");
        let _g = chump_ship::arm_policy::override_for_tests(fake.clone(), &amb);
        let opts = super::Opts {
            pr: 4242,
            repo: "o/r".into(),
            gap: "INFRA-8221".into(),
            clone_dir: None,
            apply: true,
            gh_bin: "/nonexistent/gh-must-not-run".into(),
            outcome_probe_url: None,
            outcome_probe_contains: None,
        };
        let err = super::merge_pr(&opts).unwrap_err().to_string();
        assert!(err.contains("HELD"), "{err}");
        assert_eq!(fake.calls.get(), 1);
        assert!(std::fs::read_to_string(&amb)
            .unwrap()
            .contains("pr_arm_skipped_hold"));
    }

    #[test]
    fn detect_test_runner_recognizes_conftest_and_tests_conftest() {
        let tmp1 = tempfile::tempdir().unwrap();
        std::fs::write(tmp1.path().join("conftest.py"), "# root conftest\n").unwrap();
        assert_eq!(
            super::detect_test_runner(tmp1.path()).unwrap(),
            super::TestRunner::Pytest
        );

        let tmp2 = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp2.path().join("tests")).unwrap();
        std::fs::write(
            tmp2.path().join("tests/conftest.py"),
            "# nested tests/conftest.py\n",
        )
        .unwrap();
        assert_eq!(
            super::detect_test_runner(tmp2.path()).unwrap(),
            super::TestRunner::Pytest
        );
    }

    #[test]
    fn is_pure_test_addition_distinguishes_added_test_only_from_modified_prod() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let run_git = |args: &[&str]| {
            let st = std::process::Command::new("git")
                .args(["-C", &dir.to_string_lossy()])
                .args(args)
                .status()
                .unwrap();
            assert!(st.success(), "git {args:?} failed");
        };
        run_git(&["init", "-b", "main"]);
        run_git(&["config", "user.email", "test@example.com"]);
        run_git(&["config", "user.name", "Test"]);
        std::fs::write(dir.join("app.py"), "def add(a, b):\n    return a + b\n").unwrap();
        run_git(&["add", "app.py"]);
        run_git(&["commit", "-m", "initial"]);

        let base_sha = String::from_utf8(
            std::process::Command::new("git")
                .args(["-C", &dir.to_string_lossy(), "rev-parse", "HEAD"])
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        std::fs::create_dir_all(dir.join("tests")).unwrap();
        std::fs::write(
            dir.join("tests/test_app.py"),
            "from app import add\ndef test_add():\n    assert add(1, 2) == 3\n",
        )
        .unwrap();
        run_git(&["add", "tests/test_app.py"]);
        run_git(&["commit", "-m", "add test only"]);

        let head_pure = String::from_utf8(
            std::process::Command::new("git")
                .args(["-C", &dir.to_string_lossy(), "rev-parse", "HEAD"])
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        let test_files = super::diff_test_files(dir, &base_sha, &head_pure).unwrap();
        assert_eq!(test_files, vec!["tests/test_app.py".to_string()]);
        assert!(
            super::is_pure_test_addition(dir, &base_sha, &head_pure, &test_files).unwrap(),
            "pure test-addition commit must return true"
        );

        // Now modify production file app.py -> no longer a pure test addition.
        std::fs::write(dir.join("app.py"), "def add(a, b):\n    return a + b + 0\n").unwrap();
        run_git(&["add", "app.py"]);
        run_git(&["commit", "-m", "touch prod file"]);
        let head_mixed = String::from_utf8(
            std::process::Command::new("git")
                .args(["-C", &dir.to_string_lossy(), "rev-parse", "HEAD"])
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        let test_files_mixed = super::diff_test_files(dir, &base_sha, &head_mixed).unwrap();
        assert!(
            !super::is_pure_test_addition(dir, &base_sha, &head_mixed, &test_files_mixed).unwrap(),
            "commit touching prod file must NOT be treated as pure test addition"
        );
    }
}
