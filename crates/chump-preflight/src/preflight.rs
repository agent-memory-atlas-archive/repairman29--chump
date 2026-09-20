//! INFRA-1670: `chump preflight` — single-command local CI mirror.
//! INFRA-1672: `--scope` flag — auto-detect docs/scripts/rust scopes from
//! the staged diff so a docs-only PR doesn't pay the full cargo bill.
//!
//! Runs the gates that catch the bulk of CI failures locally, in seconds
//! instead of the ~15-minute GitHub Actions round-trip. The gates are
//! exactly what CI runs:
//!
//!   1. `cargo fmt --all -- --check`              (fmt drift)
//!   2. `cargo clippy --workspace --all-targets -- -D warnings`
//!   3. `cargo check --workspace --all-targets`
//!   4. (optional, `--with-tests`) selected `scripts/ci/test-*.sh`
//!
//! Each step prints its name + duration + status. Exits non-zero on the
//! first failure (unless `--keep-going`).
//!
//! INFRA-2422: CHUMP_PREFLIGHT_SKIP deleted. When origin/main itself is
//! failing a gate (main-RED), preflight reads .chump/main-preflight-state.json
//! and auto-skips ONLY the failing gates (kind=preflight_main_red_skip).
//! No agent-side override env var is needed or honored.
//!
//! Speed targets (INFRA-1672):
//!   `--scope docs`     <5s   (no cargo, no scripts gates)
//!   `--scope scripts` <15s   (no cargo; relevant scripts/ci/test-*.sh)
//!   `--scope rust`    <60s   (cargo fmt/clippy/check warm; no scripts)
//!   `--scope all`     same as INFRA-1670 (every gate)

use std::process::{Command, Stdio};
use std::time::Instant;

/// One gate the preflight runs.
#[derive(Debug, Clone)]
struct Step {
    /// Human-readable name printed in the status line.
    name: &'static str,
    /// Argv to run. First element is the binary; rest are args.
    argv: Vec<String>,
    /// Bucket this gate belongs to — used by `--scope` filtering.
    // Populated by every `step()`; retained for `--scope` bucketing and debug
    // output. Not read directly today — flagged only once this module became
    // its own crate (EFFECTIVE-400); was reachable-as-live inside the bin.
    #[allow(dead_code)]
    kind: GateKind,
}

/// Bucket each gate belongs to. `--scope` keeps only the buckets that match
/// the staged diff (or all, if explicitly forced).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateKind {
    /// `cargo fmt|clippy|check` — runs only when rust files changed.
    Rust,
    /// `scripts/ci/test-*.sh` — runs when shell / workflow files changed.
    Scripts,
    /// Always-on cheap gates. Reserved for future use — runs on every scope.
    #[allow(dead_code)]
    AlwaysFast,
}

fn step(name: &'static str, argv: &[&str], kind: GateKind) -> Step {
    Step {
        name,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        kind,
    }
}

/// RESILIENT-072 / INFRA-2720: scripts/ci/cargo-test-with-rerun.sh REQUIRES
/// `-- <cmd> [args...]`. Without the `--` separator + a real command after
/// it, the wrapper prints `usage: ...` and exits non-zero without running a
/// single test. This is a standalone fn (rather than inline in `run()`) so
/// the `--` + cargo-invocation shape is unit-testable.
fn cargo_test_wrapper_argv(nextest_available: bool) -> &'static [&'static str] {
    if nextest_available {
        &[
            "bash",
            "scripts/ci/cargo-test-with-rerun.sh",
            "--",
            "cargo",
            "nextest",
            "run",
            "--bin",
            "chump",
        ]
    } else {
        &[
            "bash",
            "scripts/ci/cargo-test-with-rerun.sh",
            "--",
            "cargo",
            "test",
            "--bin",
            "chump",
            "--tests",
        ]
    }
}

/// INFRA-3377 (META-070): staged-diff commit-content-guards mirrored from
/// `scripts/git-hooks/pre-commit-*.sh` into `chump preflight --pre-commit`.
/// Each of these scripts inspects `git diff --cached` directly (same input
/// the real pre-commit hook sees) and already owns its own
/// `CHUMP_<NAME>_CHECK=0` disable var — those are scanned by
/// `scripts/ci/test-no-new-bypass-env-vars.sh`'s EFFECTIVE-094 debt-ceiling,
/// so preflight deliberately does NOT layer a second per-gate opt-out toggle
/// on top of each one (that would just grow the bypass-var count with no
/// new capability — disable at the source script instead).
///
/// `event-registry-staged` is a distinct gate from the existing
/// `event-registry-audit` mirror above: that one runs
/// `scripts/ci/test-event-registry-coverage.sh` (full-tree audit, any scope);
/// this one runs `pre-commit-event-registry.sh` (staged-diff only, catches
/// new unregistered ambient-event kind literals before they're even
/// committed).
const CONTENT_GUARD_MIRRORS: &[(&str, &str)] = &[
    (
        "ac-completeness",
        "scripts/git-hooks/pre-commit-ac-completeness.sh",
    ),
    (
        "css-token-discipline",
        "scripts/git-hooks/pre-commit-css-token-discipline.sh",
    ),
    (
        "default-flip",
        "scripts/git-hooks/pre-commit-default-flip.sh",
    ),
    (
        "effect-metric",
        "scripts/git-hooks/pre-commit-effect-metric.sh",
    ),
    (
        "event-registry-staged",
        "scripts/git-hooks/pre-commit-event-registry.sh",
    ),
    (
        "bash-portability",
        "scripts/git-hooks/pre-commit-bash-portability.sh",
    ),
    (
        "gap-divergence",
        "scripts/git-hooks/pre-commit-gap-divergence.sh",
    ),
    (
        "git-identity",
        "scripts/git-hooks/pre-commit-git-identity.sh",
    ),
    (
        "hardcoded-dates",
        "scripts/git-hooks/pre-commit-hardcoded-dates.sh",
    ),
    (
        "main-worktree-config",
        "scripts/git-hooks/pre-commit-main-worktree-config.sh",
    ),
    ("obs-budget", "scripts/git-hooks/pre-commit-obs-budget.sh"),
    (
        "preflight-ci-parity",
        "scripts/git-hooks/pre-commit-preflight-ci-parity.sh",
    ),
    (
        "pwa-index-uniq",
        "scripts/git-hooks/pre-commit-pwa-index-uniq.sh",
    ),
    ("redundancy", "scripts/git-hooks/pre-commit-redundancy.sh"),
    ("rust-first", "scripts/git-hooks/pre-commit-rust-first.sh"),
];

// INFRA-5000 (META-070/INFRA-3373 slice, cluster cli-observability-misc):
// the 41 leftover CLI/observability/cost/telemetry smoke scripts enumerated
// in docs/process/AUDIT_JOB_DECOMPOSITION.md's cli-observability-misc
// section. Grab-bag of one-off ci.yml audit-job scripts with lowest
// per-script cascade risk but highest count — mirrored here as the
// `cli-observability-misc` gate.
const CLI_OBSERVABILITY_MISC_SCRIPTS: &[(&str, &str)] = &[
    ("acp-real-clients", "scripts/ci/test-acp-real-clients.sh"),
    (
        "api-chat-cost-kill",
        "scripts/ci/test-api-chat-cost-kill.sh",
    ),
    (
        "api-cost-leaderboard",
        "scripts/ci/test-api-cost-leaderboard.sh",
    ),
    (
        "cascade-rebase-observability",
        "scripts/ci/test-cascade-rebase-observability.sh",
    ),
    ("chump-fleet-cli", "scripts/ci/test-chump-fleet-cli.sh"),
    ("chump-skill-cli", "scripts/ci/test-chump-skill-cli.sh"),
    ("cli-aliases", "scripts/ci/test-cli-aliases.sh"),
    (
        "cli-arg-validation",
        "scripts/ci/test-cli-arg-validation.sh",
    ),
    ("cli-exit-codes", "scripts/ci/test-cli-exit-codes.sh"),
    ("cli-fleet-coord", "scripts/ci/test-cli-fleet-coord.sh"),
    ("cli-help", "scripts/ci/test-cli-help.sh"),
    ("cli-integration", "scripts/ci/test-cli-integration.sh"),
    ("cli-output-format", "scripts/ci/test-cli-output-format.sh"),
    (
        "cli-product-surface",
        "scripts/ci/test-cli-product-surface.sh",
    ),
    (
        "cog-043-action-telemetry",
        "scripts/ci/test-cog-043-action-telemetry.sh",
    ),
    ("cost-enforcement", "scripts/ci/test-cost-enforcement.sh"),
    ("cost-per-model", "scripts/ci/test-cost-per-model.sh"),
    ("cost-watch", "scripts/ci/test-cost-watch.sh"),
    ("coupling-cost", "scripts/ci/test-coupling-cost.sh"),
    (
        "cursor-cli-integration",
        "scripts/ci/test-cursor-cli-integration.sh",
    ),
    (
        "doc-only-clippy-skip",
        "scripts/ci/test-doc-only-clippy-skip.sh",
    ),
    (
        "event-registry-guard",
        "scripts/ci/test-event-registry-guard.sh",
    ),
    (
        "fleet-metrics-snapshot",
        "scripts/ci/test-fleet-metrics-snapshot.sh",
    ),
    ("gap-closed-pr-cli", "scripts/ci/test-gap-closed-pr-cli.sh"),
    ("gate-telemetry", "scripts/ci/test-gate-telemetry.sh"),
    ("gen-cost-summary", "scripts/ci/test-gen-cost-summary.sh"),
    (
        "github-api-telemetry",
        "scripts/ci/test-github-api-telemetry.sh",
    ),
    (
        "github-api-telemetry-shim",
        "scripts/ci/test-github-api-telemetry-shim.sh",
    ),
    ("harvester-cli", "scripts/ci/test-harvester-cli.sh"),
    (
        "infra-1062-clippy-timeout-silent-exit",
        "scripts/ci/test-infra-1062-clippy-timeout-silent-exit.sh",
    ),
    (
        "observability-coverage",
        "scripts/ci/test-observability-coverage.sh",
    ),
    (
        "observability-loop",
        "scripts/ci/test-observability-loop.sh",
    ),
    ("pr-cost-telemetry", "scripts/ci/test-pr-cost-telemetry.sh"),
    ("pr-fix-clippy", "scripts/ci/test-pr-fix-clippy.sh"),
    (
        "pr-stuck-cluster-observability",
        "scripts/ci/test-pr-stuck-cluster-observability.sh",
    ),
    (
        "pr-unstick-observability",
        "scripts/ci/test-pr-unstick-observability.sh",
    ),
    ("pwa-cost-ceiling", "scripts/ci/test-pwa-cost-ceiling.sh"),
    (
        "pwa-version-compat",
        "scripts/ci/test-pwa-version-compat.sh",
    ),
    (
        "pwa-workflow-observability",
        "scripts/ci/test-pwa-workflow-observability.sh",
    ),
    ("telemetry-cost", "scripts/ci/test-telemetry-cost.sh"),
    (
        "worker-preship-clippy",
        "scripts/ci/test-worker-preship-clippy.sh",
    ),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Pass,
    Fail,
    Skipped,
}

struct Outcome {
    status: Status,
    elapsed_ms: u128,
    /// stdout+stderr if Fail; None on Pass for terseness.
    captured: Option<String>,
}

fn run_step(s: &Step) -> Outcome {
    let started = Instant::now();

    // META-208: "flake-ingest" is a pseudo-step (no subprocess spawn) — after
    // a successful "test" step produces cargo-nextest JSON output, this arm
    // calls chump_atomic_claim::run_flake_import in-process to upsert flaky
    // outcomes into .chump/flake_tracker.db. argv[1] is the path to the
    // nextest output file produced by the preceding "test" step; argv[2]
    // (optional, test-only override) is the repo root — defaults to cwd.
    if s.argv[0] == "flake-ingest" {
        let input_path = std::path::Path::new(&s.argv[1]);
        let repo_root = match s.argv.get(2) {
            Some(rr) => std::path::PathBuf::from(rr),
            None => std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")),
        };
        return match chump_atomic_claim::atomic_claim::run_flake_import(&repo_root, input_path) {
            Ok(n) => Outcome {
                status: Status::Pass,
                elapsed_ms: started.elapsed().as_millis(),
                captured: Some(format!(
                    "[preflight] flake-ingest: {n} flaky test(s) recorded"
                )),
            },
            Err(e) => Outcome {
                status: Status::Fail,
                elapsed_ms: started.elapsed().as_millis(),
                captured: Some(format!("[preflight] flake-ingest failed: {e:#}")),
            },
        };
    }

    // INFRA-2721/2722: graceful-skip when a bash gate points at a missing
    // script. Without this guard the gate hard-fails locally (because the
    // script genuinely isn't on disk) but the CI parity rule says main is
    // ALSO red, so blocking pushes is pure overhead. The skip emits an
    // audit-trail outcome rather than a silent pass — operator/curator can
    // see the missing-script class in --json output and file a restore gap.
    if s.argv.len() >= 2 && s.argv[0] == "bash" {
        let script_path = &s.argv[1];
        if !std::path::Path::new(script_path).exists() {
            return Outcome {
                status: Status::Skipped,
                elapsed_ms: started.elapsed().as_millis(),
                captured: Some(format!(
                    "[preflight] skip-missing-script: {} (file does not exist; \
                     same condition on origin/main — see INFRA-2721/INFRA-2722)",
                    script_path
                )),
            };
        }
    }

    let mut cmd = Command::new(&s.argv[0]);
    cmd.args(&s.argv[1..]).stdin(Stdio::null());
    let result = cmd.output();
    let elapsed_ms = started.elapsed().as_millis();
    match result {
        Ok(o) if o.status.success() => Outcome {
            status: Status::Pass,
            elapsed_ms,
            captured: None,
        },
        Ok(o) => {
            let mut captured = String::new();
            captured.push_str(&String::from_utf8_lossy(&o.stdout));
            captured.push_str(&String::from_utf8_lossy(&o.stderr));
            Outcome {
                status: Status::Fail,
                elapsed_ms,
                captured: Some(captured),
            }
        }
        Err(e) => Outcome {
            status: Status::Fail,
            elapsed_ms,
            captured: Some(format!("failed to spawn {:?}: {}", s.argv, e)),
        },
    }
}

/// Resolved scope after parsing `--scope` and (if auto) reading the diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Scope {
    rust: bool,
    scripts: bool,
    /// Docs: no Rust gates and no scripts gates, just the always-fast ones.
    /// We track it explicitly so `--help` text / status line reads naturally.
    docs: bool,
}

impl Scope {
    fn all() -> Self {
        Self {
            rust: true,
            scripts: true,
            docs: true,
        }
    }
    fn none() -> Self {
        Self {
            rust: false,
            scripts: false,
            docs: false,
        }
    }
    /// Returns true if the gate's kind should run under this scope.
    fn includes(&self, kind: GateKind) -> bool {
        match kind {
            // AlwaysFast is universal — even docs-only scopes get it because
            // it's <2s and catches the most common cross-cutting issues.
            GateKind::AlwaysFast => true,
            GateKind::Rust => self.rust,
            GateKind::Scripts => self.scripts,
        }
    }
    fn label(&self) -> String {
        let mut parts = vec![];
        if self.rust {
            parts.push("rust");
        }
        if self.scripts {
            parts.push("scripts");
        }
        if self.docs && !self.rust && !self.scripts {
            parts.push("docs");
        }
        if parts.is_empty() {
            "none (always-fast only)".to_string()
        } else {
            parts.join("+")
        }
    }
}

/// `--scope` enum surface. `Auto` is the default and reads the diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScopeArg {
    Auto,
    All,
    Rust,
    Scripts,
    Docs,
}

impl ScopeArg {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(ScopeArg::Auto),
            "all" => Some(ScopeArg::All),
            "rust" => Some(ScopeArg::Rust),
            "scripts" => Some(ScopeArg::Scripts),
            "docs" => Some(ScopeArg::Docs),
            _ => None,
        }
    }
}

/// Given a list of staged file paths (relative to repo root), determine
/// which gate buckets should run. Mirrors the `changes:` path-filter section
/// of `.github/workflows/ci.yml`.
///
/// Mapping (kept deliberately simple for Phase 1 — full YAML parsing is a
/// follow-up if/when the path lists diverge from this snapshot):
///
///   *.rs, Cargo.toml, Cargo.lock, build.rs, crates/**, chump-tool-macro/**,
///   src/**, tests/**, wasm/**                    → rust
///   *.sh, scripts/**, .github/workflows/**,
///   bin/**, launchd/**, config/**, .release-plz.toml → scripts
///   *.md, docs/**, book/**, CHANGELOG.md, SECURITY.md, README.md → docs
///
/// Anything unrecognized falls back to `all` (conservative — better to do
/// extra work than skip a gate the diff actually needs).
fn scope_from_paths(paths: &[String]) -> Scope {
    if paths.is_empty() {
        // No staged diff → assume worst case (full scope). This matches the
        // INFRA-1670 behavior so `chump preflight` with no staged changes
        // still runs a full local-CI mirror.
        return Scope::all();
    }
    let mut s = Scope::none();
    let mut unrecognized = false;
    for p in paths {
        let lower = p.to_lowercase();
        let is_rust = lower.ends_with(".rs")
            || lower == "cargo.toml"
            || lower == "cargo.lock"
            || lower == "build.rs"
            || lower.starts_with("src/")
            || lower.starts_with("crates/")
            || lower.starts_with("chump-tool-macro/")
            || lower.starts_with("tests/")
            || lower.starts_with("wasm/")
            // INFRA-1787 AC#3: env-var-coverage lives in the rust-scope gate
            // bucket, but its allowlist file is a scripts/ path — without this
            // special case, a diff touching only env-vars-internal.txt (no
            // .rs files) would fall into scripts-only scope and skip the gate.
            || lower == "scripts/ci/env-vars-internal.txt";
        let is_scripts = lower.ends_with(".sh")
            || lower.starts_with("scripts/")
            || lower.starts_with(".github/workflows/")
            || lower.starts_with("bin/")
            || lower.starts_with("launchd/")
            || lower.starts_with("config/")
            || lower == ".release-plz.toml";
        let is_docs =
            lower.ends_with(".md") || lower.starts_with("docs/") || lower.starts_with("book/");
        if is_rust {
            s.rust = true;
        }
        if is_scripts {
            s.scripts = true;
        }
        if is_docs {
            s.docs = true;
        }
        if !is_rust && !is_scripts && !is_docs {
            unrecognized = true;
        }
    }
    if unrecognized {
        // Conservative: an unknown path means we don't know the impact; run
        // every bucket so we don't ship a regression.
        return Scope::all();
    }
    s
}

/// Read `git diff --cached --name-only` from the repo root. Returns an empty
/// vec on any error (so callers can fall back to "all scope").
fn staged_paths(repo_root: &std::path::Path) -> Vec<String> {
    let out = Command::new("git")
        .args(["diff", "--cached", "--name-only"])
        .current_dir(repo_root)
        .output();
    let Ok(o) = out else { return vec![] };
    if !o.status.success() {
        return vec![];
    }
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

// ── EFFECTIVE-372: crate-scoped `cargo check` ───────────────────────────────
//
// `cargo check --workspace --all-targets` re-checks every crate in the
// workspace even when the staged diff touches exactly one. On this repo's
// ~70-crate workspace that's the single slowest step in the BLOCKING gate.
// Scoping to `-p <changed-crate>` (one `-p` per crate actually touched)
// keeps the gate fast for the common single-crate PR while still falling
// back to the full workspace check whenever scoping can't be proven safe
// (root Cargo.toml/Cargo.lock changed, or a changed path can't be resolved
// to a crate root).

/// Returns true if `text` (a Cargo.toml's contents) has a `[package]` table.
/// Distinguishes a crate manifest (which may also carry `[workspace]` at the
/// repo root) from a virtual-manifest-only Cargo.toml.
fn toml_has_package_section(text: &str) -> bool {
    text.lines().any(|l| l.trim() == "[package]")
}

/// Extract `name = "..."` from the `[package]` table of a Cargo.toml.
fn package_name_from_cargo_toml(text: &str) -> Option<String> {
    let mut in_package = false;
    for line in text.lines() {
        let t = line.trim();
        if let Some(section) = t.strip_prefix('[') {
            in_package = section.trim_end_matches(']') == "package";
            continue;
        }
        if in_package {
            if let Some(rest) = t.strip_prefix("name") {
                let rest = rest.trim_start();
                if let Some(rest) = rest.strip_prefix('=') {
                    let v = rest.trim().trim_matches('"');
                    return Some(v.to_string());
                }
            }
        }
    }
    None
}

/// Walk up from `rel_path`'s parent directory to the nearest ancestor
/// (inclusive of `repo_root`) whose `Cargo.toml` has a `[package]` table.
/// Returns that directory, or `None` if none is found before `repo_root`.
fn crate_root_for_file(repo_root: &std::path::Path, rel_path: &str) -> Option<std::path::PathBuf> {
    let file_path = repo_root.join(rel_path);
    let mut dir = file_path.parent()?.to_path_buf();
    loop {
        let cargo_toml = dir.join("Cargo.toml");
        if cargo_toml.is_file() {
            if let Ok(text) = std::fs::read_to_string(&cargo_toml) {
                if toml_has_package_section(&text) {
                    return Some(dir);
                }
            }
        }
        if dir == repo_root {
            return None;
        }
        dir = dir.parent()?.to_path_buf();
    }
}

/// Given the staged/changed paths, determine which crate package names the
/// blocking `cargo check` gate needs to cover. Returns `None` when scoping
/// can't be proven safe — the caller should fall back to `--workspace`:
///   - no rust-relevant paths changed
///   - the root `Cargo.toml` or `Cargo.lock` changed (workspace-wide impact:
///     member list, dependency graph, or the root package itself)
///   - any changed rust file can't be resolved to a crate root
fn changed_crate_names(repo_root: &std::path::Path, paths: &[String]) -> Option<Vec<String>> {
    let rust_paths: Vec<&String> = paths
        .iter()
        .filter(|p| {
            let lower = p.to_lowercase();
            lower.ends_with(".rs") || lower.ends_with("build.rs")
        })
        .collect();
    if rust_paths.is_empty() {
        return None;
    }
    if paths.iter().any(|p| p == "Cargo.toml" || p == "Cargo.lock") {
        return None;
    }
    let mut names: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for p in rust_paths {
        let dir = crate_root_for_file(repo_root, p)?;
        let cargo_toml = dir.join("Cargo.toml");
        let text = std::fs::read_to_string(&cargo_toml).ok()?;
        let name = package_name_from_cargo_toml(&text)?;
        names.insert(name);
    }
    if names.is_empty() {
        None
    } else {
        Some(names.into_iter().collect())
    }
}

/// Cap `cargo check -j` at a sane ceiling (~6) so a scoped, single-crate
/// check doesn't monopolize every core on the machine, and back off to a
/// single job under a load-aware-defer: when 1-minute load average already
/// exceeds available CPUs, the machine is busy (another cargo build,
/// another agent) — deferring to 1 job avoids compounding the contention
/// instead of racing it.
fn compute_check_jobs(cpus: usize, load1: f64) -> usize {
    let cap = cpus.clamp(1, 6);
    if load1 > cpus as f64 {
        1
    } else {
        cap
    }
}

/// Best-effort CPU count; defaults to 4 if unavailable (matches CI runner
/// baseline so behavior is predictable when detection fails).
fn available_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}

/// Best-effort 1-minute load average from `/proc/loadavg` (Linux). Returns
/// 0.0 (i.e. "not busy") on any platform/parse failure so the gate never
/// deadlocks waiting on a signal it can't read.
fn load_average_1m() -> f64 {
    std::fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|s| s.split_whitespace().next().map(|s| s.to_string()))
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(0.0)
}

/// Build the blocking `cargo check` step, scoped to the changed crate(s)
/// when scoping is safe, falling back to `--workspace` otherwise. Always
/// applies the jobs cap + `nice` (see `compute_check_jobs`).
fn cargo_check_step(repo_root: &std::path::Path, paths: &[String]) -> Step {
    let jobs = compute_check_jobs(available_cpus(), load_average_1m());
    let mut argv: Vec<String> = vec![
        "nice".to_string(),
        "-n".to_string(),
        "10".to_string(),
        "cargo".to_string(),
        "check".to_string(),
    ];
    let name: &'static str = match changed_crate_names(repo_root, paths) {
        Some(names) if !names.is_empty() => {
            for n in &names {
                argv.push("-p".to_string());
                argv.push(n.clone());
            }
            eprintln!(
                "[preflight] cargo check scoped to crate(s): {}",
                names.join(", ")
            );
            "cargo check (scoped)"
        }
        _ => {
            argv.push("--workspace".to_string());
            "cargo check"
        }
    };
    argv.push("--all-targets".to_string());
    argv.push("--jobs".to_string());
    argv.push(jobs.to_string());
    Step {
        name,
        argv,
        kind: GateKind::Rust,
    }
}

/// Resolve the user's `--scope` argument into a concrete `Scope`. `Auto`
/// consults the staged diff via `git diff --cached --name-only`.
fn resolve_scope(arg: ScopeArg, repo_root: &std::path::Path) -> Scope {
    match arg {
        ScopeArg::All => Scope::all(),
        ScopeArg::Rust => Scope {
            rust: true,
            scripts: false,
            docs: false,
        },
        ScopeArg::Scripts => Scope {
            rust: false,
            scripts: true,
            docs: false,
        },
        ScopeArg::Docs => Scope {
            rust: false,
            scripts: false,
            docs: true,
        },
        ScopeArg::Auto => {
            let paths = staged_paths(repo_root);
            scope_from_paths(&paths)
        }
    }
}

/// CLI args parser — intentionally lightweight (no clap; this is a one-shot subcommand).
struct Args {
    with_tests: bool,
    keep_going: bool,
    json: bool,
    help: bool,
    scope: ScopeArg,
    /// True if `--scope <bad>` was passed; main loop errors out.
    bad_scope: Option<String>,
    /// INFRA-1788: enables pre-commit-only gates (docs-delta-trailer audit).
    /// When false, those gates are silently skipped — the bare `chump preflight`
    /// invocation stays under its speed target and doesn't fail-close on a diff
    /// that hasn't yet had its commit message authored.
    pre_commit: bool,
    /// META-153: diff-scoped failure attribution. When Some("origin/main"),
    /// run preflight against origin/main HEAD (with caching) to determine which
    /// failures are pre-existing vs. caused by the current diff.
    vs_ref: Option<String>,
    /// EFFECTIVE-318: reproduce CI's audit shards locally. Forces scope=all +
    /// --with-tests, and additionally runs every `scripts/ci/test-*.sh` that
    /// audit.yml runs and that is locally-safe (auto-classified: no gh/curl/push/
    /// network markers). Closes the "local preflight != CI" gap that makes a
    /// failure cost a ~20-min CI round-trip instead of one local pass.
    full: bool,
    /// EFFECTIVE-363: dispatch by artifact_type instead of assuming cargo.
    /// When set to a type registered in `artifact_gates::REGISTRY` (e.g.
    /// "release-note"), preflight runs *only* that type's gates and skips
    /// the cargo-shaped pipeline entirely. Unset or "code" runs the normal
    /// pipeline below unchanged.
    artifact_type: Option<String>,
}

fn parse_args(argv: &[String]) -> Args {
    let mut a = Args {
        with_tests: false,
        keep_going: false,
        json: false,
        help: false,
        scope: ScopeArg::Auto,
        bad_scope: None,
        pre_commit: false,
        vs_ref: None,
        full: false,
        artifact_type: None,
    };
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        match arg.as_str() {
            "--with-tests" => a.with_tests = true,
            "--full" => a.full = true,
            "--keep-going" => a.keep_going = true,
            "--json" => a.json = true,
            "--pre-commit" => a.pre_commit = true,
            "-h" | "--help" => a.help = true,
            "--scope" => {
                if i + 1 >= argv.len() {
                    a.bad_scope = Some("(missing value)".to_string());
                } else {
                    let v = &argv[i + 1];
                    match ScopeArg::parse(v) {
                        Some(s) => a.scope = s,
                        None => a.bad_scope = Some(v.clone()),
                    }
                    i += 1;
                }
            }
            s if s.starts_with("--scope=") => {
                let v = &s["--scope=".len()..];
                match ScopeArg::parse(v) {
                    Some(s) => a.scope = s,
                    None => a.bad_scope = Some(v.to_string()),
                }
            }
            "--vs" => {
                if i + 1 < argv.len() {
                    a.vs_ref = Some(argv[i + 1].clone());
                    i += 1;
                }
            }
            s if s.starts_with("--vs=") => {
                a.vs_ref = Some(s["--vs=".len()..].to_string());
            }
            "--artifact-type" => {
                if i + 1 < argv.len() {
                    a.artifact_type = Some(argv[i + 1].clone());
                    i += 1;
                }
            }
            s if s.starts_with("--artifact-type=") => {
                a.artifact_type = Some(s["--artifact-type=".len()..].to_string());
            }
            _ => {} // ignore unknowns for forward-compat
        }
        i += 1;
    }
    a
}

fn print_help() {
    println!(
        "chump preflight — local CI mirror (INFRA-1670, INFRA-1672)

USAGE:
    chump preflight [OPTIONS]

OPTIONS:
    --scope <S>     Limit gates to a scope. S = auto|all|rust|scripts|docs.
                    Default 'auto' reads `git diff --cached --name-only`
                    and runs only the buckets the diff touches.
                    Speed targets:
                       docs    <5s   (no cargo, no scripts gates)
                       scripts <15s  (no cargo; relevant scripts/ci/test-*.sh)
                       rust    <60s  (cargo fmt/clippy/check warm; no scripts)
                       all     same as the full INFRA-1670 set
    --with-tests    Also run scripts/ci/test-*.sh that match the staged diff
                    (slower; off by default to keep the fast path under 60s)
    --full          EFFECTIVE-318: reproduce CI's audit shards locally. Forces
                    --scope all + --with-tests, then runs every audit.yml test
                    script that is locally-safe (auto-skips network/gh gates).
                    Slower, but one local pass replaces a ~20-min CI round-trip.
    --keep-going    Don't exit on the first failure; run all gates
    --json          Emit one JSON object per gate to stdout (machine-readable)
    --pre-commit    Enable pre-commit-only gates (docs-delta-trailer audit
                    against HEAD's COMMIT_EDITMSG, INFRA-1788; plus 14
                    staged-diff commit-content-guards mirrored from
                    scripts/git-hooks/pre-commit-*.sh, INFRA-3377/META-070).
                    Mirrored from scripts/coord/chump-commit.sh on the path
                    leading to a real commit; the bare 'chump preflight'
                    silently skips these so it stays fast for ad-hoc
                    validation runs.
    --vs <REF>      META-153: diff-scoped failure attribution. REF is typically
                    'origin/main'. Runs preflight against both HEAD and REF,
                    separates failures into NEW (your diff broke this — blocks)
                    and PRE-EXISTING (already failing on REF — warns only).
                    Baseline cached at .chump/preflight-baseline.json (TTL 1h,
                    keyed by REF HEAD SHA). Falls back to normal mode when REF
                    is unreachable. Pairs with --json for structured output.
    --artifact-type <T>  EFFECTIVE-363: dispatch by artifact_type instead of
                    assuming cargo. When T is registered in
                    artifact_gates::REGISTRY (e.g. \"release-note\"), runs
                    only that type's gates and skips the cargo pipeline
                    entirely. Unregistered T (including the default \"code\")
                    falls through to the normal pipeline below.
    -h, --help      This message

BYPASS:
    Main-RED auto-skip (INFRA-2422): when origin/main itself is failing a
    gate, preflight reads .chump/main-preflight-state.json and auto-skips
    only those failing gates with a logged reason. No env override needed.
    CHUMP_PREFLIGHT_SKIP_REGISTRY=1   Skip event-registry-audit (INFRA-1731).
    CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1  Skip docs-delta-trailer (INFRA-1788).
    CHUMP_PREFLIGHT_SKIP_PIPEFAIL=1   Skip pipefail-race-sweep (INFRA-2350).
    CHUMP_PREFLIGHT_SKIP_PATHFILTER=1 Skip path-filter-coverage (INFRA-2350).
    CHUMP_PREFLIGHT_SKIP_INSTALLMAP=1 Skip install-manifest gate (INFRA-2350).

GATES (in order):
    1. event-registry-audit            (scope: ALWAYS, INFRA-1731/MISSION-064)
    2. env-var-coverage                (scope: ALWAYS, INFRA-1787/MISSION-064)
    3. cargo fmt --check               (scope: rust)
    4. cargo clippy -- -D warnings     (scope: rust)
    5. cargo check --all-targets        (scope: rust)
    6. docs-delta-trailer              (--pre-commit only, INFRA-1788)
    7. 14 commit-content-guards        (--pre-commit only, INFRA-3377/META-070)
    8. (with --with-tests) selected scripts/ci/test-*.sh  (scope: scripts)

EXIT CODES:
    0   all gates passed (or --vs: only pre-existing failures)
    1   one or more NEW gates failed (see stdout)
    2   bad usage"
    );
}

/// INFRA-1788: docs-delta-trailer audit. Mirrors the block in
/// scripts/git-hooks/pre-commit (INFRA-009 + INFRA-124) so operators catch a
/// missing or understated `Net-new-docs: +N` trailer BEFORE the pre-commit
/// hook fires — same fail-fast experience without paying a hook round-trip on
/// every commit attempt.
///
/// Inputs come from the staged diff (`git diff --cached --diff-filter=A|D
/// -- docs/*.md`) and from HEAD's `COMMIT_EDITMSG` (the message the operator
/// is about to commit). When invoked outside `--pre-commit` mode the gate is
/// silently skipped — there's no commit message to validate yet.
///
/// Returns a `Step`-shaped outcome string for the status line and a non-zero
/// `should_fail` to drive exit semantics. The check is implemented inline
/// rather than spawning bash so the operator sees the INFRA-124 diagnostic
/// in the same terminal stream as the rest of preflight's output.
struct DocsDeltaOutcome {
    /// Human-readable result line (the same lines the bash hook prints).
    message: String,
    /// True if the gate should fail-close. False on accept / advisory.
    should_fail: bool,
    /// True if the gate ran a real check (i.e. there were docs/*.md adds).
    /// When false the caller logs "skipped (no docs/*.md adds)".
    ran: bool,
}

fn run_docs_delta_check(repo_root: &std::path::Path) -> DocsDeltaOutcome {
    // 1. Count staged adds + deletes under docs/*.md.
    let count_paths = |filter: &str| -> usize {
        let out = Command::new("git")
            .args([
                "diff",
                "--cached",
                "--name-only",
                &format!("--diff-filter={}", filter),
                "--",
                "docs/*.md",
            ])
            .current_dir(repo_root)
            .output();
        let Ok(o) = out else { return 0 };
        if !o.status.success() {
            return 0;
        }
        String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .count()
    };
    let added = count_paths("A");
    let deleted = count_paths("D");

    if added == 0 || added <= deleted {
        return DocsDeltaOutcome {
            message: String::new(),
            should_fail: false,
            ran: false,
        };
    }

    let net = added - deleted;

    // 2. Find HEAD's COMMIT_EDITMSG. We resolve it via `git rev-parse
    //    --git-dir` rather than assuming `.git/` so worktrees Just Work.
    let git_dir = Command::new("git")
        .args(["rev-parse", "--git-dir"])
        .current_dir(repo_root)
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        });
    let mut trailer_val: Option<usize> = None;
    if let Some(gd) = git_dir.as_deref() {
        let msg_path = std::path::PathBuf::from(gd).join("COMMIT_EDITMSG");
        if let Ok(content) = std::fs::read_to_string(&msg_path) {
            for line in content.lines() {
                // Mirror the bash regex: `^Net-new-docs:[[:space:]]*\+?[0-9]+`
                // case-insensitive, first match wins.
                let lower = line.to_ascii_lowercase();
                if let Some(rest) = lower.strip_prefix("net-new-docs:") {
                    // Skip leading spaces + optional '+', then read digits.
                    let bytes = rest.trim_start().trim_start_matches('+');
                    let digits: String = bytes.chars().take_while(|c| c.is_ascii_digit()).collect();
                    if !digits.is_empty() {
                        if let Ok(n) = digits.parse::<usize>() {
                            trailer_val = Some(n);
                            break;
                        }
                    }
                }
            }
        }
    }

    match trailer_val {
        None => DocsDeltaOutcome {
            message: format!(
                "✖  docs-delta (INFRA-124): commit adds {} docs/*.md, deletes {} (net +{})\n   \
                 Red Letter #3 counter-pressure: either delete/archive a comparable doc,\n   \
                 or add a commit-message trailer:    Net-new-docs: +{}\n   \
                 Bypass: CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1 chump preflight --pre-commit",
                added, deleted, net, net
            ),
            should_fail: true,
            ran: true,
        },
        Some(v) if v < net => DocsDeltaOutcome {
            message: format!(
                "✖  docs-delta (INFRA-124): trailer claims Net-new-docs: +{}\n   \
                 but commit actually adds {} docs/*.md, deletes {} (net +{}).\n   \
                 Trailer must equal or exceed the computed delta. Update to:\n   \
                 \x20\x20\x20\x20\x20\x20Net-new-docs: +{}\n   \
                 Bypass: CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1 chump preflight --pre-commit",
                v, added, deleted, net, net
            ),
            should_fail: true,
            ran: true,
        },
        Some(_) => DocsDeltaOutcome {
            // Trailer present and >= NET — accept silently.
            message: String::new(),
            should_fail: false,
            ran: true,
        },
    }
}

/// Discover scripts/ci/test-*.sh files. The MVP returns a tight whitelist of
/// fast, broadly-useful tests; INFRA-1672 wires diff scoping above the gate
/// itself rather than per-script.
fn discover_test_scripts(repo_root: &std::path::Path) -> Vec<std::path::PathBuf> {
    // Conservative whitelist — these are the ones that have most often
    // failed-on-CI-but-would-have-passed-locally in the last 48h.
    let candidates = [
        // RESILIENT-361: dead-writer FIFO wedge regression — proves the
        // CHUMP_TOKEN_PARSE_TIMEOUT_S SIGALRM bound actually unblocks
        // _parse_token_usage.py instead of hanging forever. Fast (~1s),
        // pure local (fifo + subshell, no network).
        "scripts/ci/test-parse-token-usage-dead-writer-timeout.sh",
        "scripts/ci/test-event-registry-coverage.sh",
        // MISSION-045: outcome-gate keystone — proves P0/P1 reserves are blocked
        // without an outcome (when outcomes exist), the audited flag + empty-DB
        // skip work. Fast (~2s), pure local (chump binary + temp dirs, no network).
        "scripts/ci/test-outcome-gate.sh",
        // RESILIENT-313: farmer stale-lease heartbeat regression — a present
        // claim-*.json lease must never crash the tick before write_heartbeat.
        // Pure shell, ~3s, Linux-safe, no network.
        "scripts/ci/test-farmer-stale-lease-heartbeat.sh",
        // EFFECTIVE-323: opencode harness smoke — build_harness_cmd argv is
        // well-formed + set-u clean (catches the $_TO unbound + missing-`run`
        // class). Pure shell, ~1s; live spawn skips without opencode/auth.
        "scripts/ci/test-opencode-harness-smoke.sh",
        // EFFECTIVE-320: born-wired — install-opencode-harness.sh wires
        // opencode.json's mcp.almanac idempotently without clobbering config.
        // Fully stubbed, ~1s, no network.
        "scripts/ci/test-opencode-harness-install.sh",
        // INFRA-2496: audit parser correctness regression — guards against
        // merge-conflict clobbers silently dropping registry kinds.
        "scripts/ci/test-event-registry-audit-regression.sh",
        "scripts/ci/test-no-raw-gh-in-hot-paths.sh",
        "scripts/ci/check-path-filter-coverage.sh",
        "scripts/ci/test-env-var-coverage.sh",
        "scripts/ci/test-merged-check-guard.sh",
        // INFRA-2295: stale-pr-rebase-bot 3-strike circuit-break
        "scripts/ci/test-stale-pr-rebase-bot.sh",
        // RESILIENT-266: discord gateway daemon guard. Pure shell — asserts the
        // liveness alarm does not route through the gateway it checks, that the
        // runner refuses a second instance, and that a stale pidfile is never
        // mistaken for a live process. Mirrored, not allowlisted: it runs
        // locally in well under a second.
        // RESILIENT-263: operator escalation channel wiring. Pure shell — no
        // cargo, no network. This mirror was written on the 263 branch but PR
        // #3544 MERGED BEFORE IT WAS PUSHED, so main landed the audit.yml step
        // without it and main's fast-checks went red at 20:15:44. Carried here
        // so this PR unbreaks main rather than needing a separate fix.
        "scripts/ci/test-notify-operator.sh",
        // RESILIENT-1096: every literal CHUMP_NOTIFY_KIND assignment in
        // production scripts must have a suppress|page|direct verdict in
        // operator-escalation-registry.txt. Pure shell, no cargo, no network.
        "scripts/ci/test-notify-kind-escalation-coverage.sh",
        "scripts/ci/test-discord-gateway.sh",
        // RESILIENT-248: pr-rescue zero-CI-runs detector. Pure decision-function
        // fixture — no network, no cargo, no GH_TOKEN, well under a second.
        // Mirrored here rather than allowlisted precisely BECAUSE it can run
        // locally; the exceptions file is for gates that genuinely cannot be.
        "scripts/ci/test-pr-rescue-noci.sh",
        // RESILIENT-050: trunk-RED hold gate — fast (~2s), no network needed.
        "scripts/ci/test-reaper-trunk-red-hold.sh",
        // REAPER-SPARE (PR #4589 fix): stale-pr-reaper must SPARE recoverable
        // BLOCKED PRs (pending required checks, or a flake-budget-exhausted
        // known flake on an otherwise-green PR) and only bounce genuinely dead
        // ones (hard non-flake failure / conflict). Pure decision-function
        // fixtures + INFRA-304 markers, no network, ~1s.
        "scripts/ci/test-reaper-spare-recoverable-blocked.sh",
        // INFRA-1410 (completes PR #4606): stale-pr-reaper prompt-retries the
        // current failing run on flake re-arm. Network-free — the test stubs
        // gh / chump / the rebase script via PATH and drives the whole respawn
        // state machine in a tmpdir — so it runs in local preflight identically
        // to the ci.yml fast-checks job (registers this gate for preflight-vs-CI
        // parity, INFRA-1867).
        "scripts/ci/test-pr-stuck-auto-respawn.sh",
        // RESILIENT-066: fleet-pause autolift + pause-immune choir — Tier A,
        // pure shell, no GitHub API, ~2s.
        "scripts/ci/test-fleet-pause-autolift.sh",
        // RESILIENT-068: farmer un-killable control-plane tender — 9 fixture
        // tests, pure bash+sqlite3, zero network, ~2s.
        "scripts/ci/test-farmer.sh",
        // CREDIBLE-089: M2 gate end-to-end verifier — asserts that the L6
        // substrate (gap-supervisor, fleet-supervisor, guardrail) responds
        // correctly to synthetic red-trunk conditions. Pure shell, ~1s,
        // detects regressions in the L6 keystones before they reach trunk.
        "scripts/ci/test-m2-gate-end-to-end.sh",
        // INFRA-2265: bootstrap smoke — asserts `chump bootstrap <intent>` produces
        // a git repo + README.md + Cargo.toml + ambient events. Scoped to
        // src/main.rs OR src/commands/bootstrap.rs OR crates/chump-handoff/src/contracts.rs.
        // Pure local, no network needed when --skip-arch-decision is honored.
        "scripts/ci/test-bootstrap-smoke.sh",
        // INFRA-2275: external-repo plist installer smoke test. macOS-only;
        // skips cleanly on Linux via [SKIP] exit 0 path. Runs when
        // src/onboard.rs OR scripts/plists/com.chump.external-repo-loop.plist.template touched.
        "scripts/ci/test-external-repo-plist-installer.sh",
        // INFRA-1881: rust template smoke test — asserts `chump bootstrap <path> --template rust`
        // writes Cargo.toml + src/main.rs + README.md + .gitignore, inits git, and passes
        // cargo check. Scoped to src/commands/bootstrap.rs. SKIPs cleanly if cargo not on PATH.
        "scripts/ci/test-chump-bootstrap-rust.sh",
        // INFRA-2925: pr-stuck-cluster-detector run-event observability
        // (outcome/failure_class/gap_reserve_calls) — pure bash, ~1s, no
        // network, 3 synthetic-ambient fixture tests.
        "scripts/ci/test-pr-stuck-cluster-observability.sh",
        // INFRA-3352: pr-stuck-cluster-detector CORE detection logic (below-
        // threshold no-op, cluster-detected filing, window/cooldown dedup) —
        // existed since INFRA-1133 but was never wired into preflight or CI,
        // so a regression in the detector's actual cluster math would ship
        // silently. Pure bash + synthetic ambient.jsonl fixtures, ~1s, no
        // network.
        "scripts/ci/test-pr-stuck-cluster-detection.sh",
        // INFRA-2391: `chump demo` subcommand smoke — asserts --help and an
        // end-to-end --dry-run both exit 0. Pure local, no network.
        "scripts/ci/test-chump-demo-smoke.sh",
        // INFRA-3561 (INFRA-1655 slice): guards CHUMP_RUNNER_M4_MAX default
        // (raised 2->4 by INFRA-3549) against silently regressing in either
        // scripts/coord/chump-runner-autoscale.sh or
        // scripts/setup/install-runner-autoscale.sh. Pure grep, no network, <1s.
        "scripts/ci/test-runner-autoscale-max-default.sh",
        // INFRA-3579 (INFRA-1655 slice): guards the INFRA-1852 concurrency-
        // group fix (ci.yml `group:` keyed on github.sha, not PR number)
        // against silently regressing. Pure grep, no network, <1s.
        "scripts/ci/test-ci-concurrency-group-key.sh",
        // CREDIBLE-269: `verified` aggregator decision-logic guard — proves
        // scripts/ci/aggregator-verified.sh's lane classification (PASS/FAIL/
        // PENDING) matches docs/design/CI_VERIFIED_AGGREGATOR.md §2.2-2.3.
        // Pure bash, no network, no GitHub context needed — the ci.yml
        // `verified` job step itself IS GitHub-context-dependent (needs.*.result)
        // and is allowlisted separately in preflight-ci-parity-exceptions.txt.
        "scripts/ci/test-aggregator-verified.sh",
        // INFRA-1841 (CP-009): mock-services offline-CI fixture smoke test —
        // builds+runs the 4 vendored Anthropic/OpenAI/Stripe/Supabase mocks
        // under tests/fixtures/mock-services and asserts response shape.
        // SKIPs cleanly (exit 0) when docker is unavailable/unreachable, so
        // it never false-fails a host without Docker. ~4s warm, ~15s cold.
        "scripts/ci/test-mock-services.sh",
        // INFRA-1841 (CP-009): mock-services CHUMP_USE_MOCK_SERVICES=1
        // opt-in wiring pattern — proves scripts/ci/lib/mock-services-env.sh
        // transparently redirects Anthropic/OpenAI calls to the local
        // mocks. Same skip behavior as test-mock-services.sh above.
        "scripts/ci/test-mock-services-integration.sh",
        // INFRA-2351 (META-269 sub-2): bash-portability-lint smoke test —
        // proves the GNU-sed/GNU-date/POSIX-sh-bashism checks in
        // scripts/ci/bash-portability-lint.sh actually fire on synthetic
        // fixtures. Pure bash, no network, ~1s.
        "scripts/ci/test-bash-portability-lint.sh",
        // INFRA-2358: A2A typed RPC v1 observability smoke test — proves the
        // 4 terminal event kinds (finished/timeout/send_failed/
        // handler_crash) are registered + emitted from both
        // crates/chump-coord/src/rpc.rs and scripts/coord/rpc/_rpc_lib.sh,
        // that latency_ms and failure_class ride along, and runs
        // `cargo test -p chump-coord --lib rpc::`. Pure local, no network.
        "scripts/ci/test-a2a-rpc-observability.sh",
    ];
    candidates
        .iter()
        .map(|p| repo_root.join(p))
        .filter(|p| p.is_file())
        .collect()
}

// ── EFFECTIVE-318: --full audit-shard reproduction ──────────────────────────
//
// The curated whitelist above is hand-maintained and covers only the tests
// most-often-caught-locally. `--full` instead DISCOVERS every test script that
// audit.yml actually runs, so local preflight stays in sync with CI without a
// human porting each gate one at a time (the toil that left ~60 of ~120 audit
// scripts un-mirrored). Trustworthiness comes from auto-classification: a test
// that needs the network (gh / curl / git push / smee / a live server) would
// false-fail locally, so it is SKIPPED with a reason rather than run. We err
// toward skipping — a false-skip only means "that one still runs in CI", while
// a false-run would erode trust in a green `--full`.

/// Extract the unique `scripts/ci/*.sh` paths that audit.yml invokes. Line-based
/// (no YAML dep): any `scripts/ci/<name>.sh` token in the workflow is a gate the
/// audit shards run. Returns absolute paths that exist on disk.
fn discover_audit_scripts(repo_root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let audit = repo_root.join(".github/workflows/audit.yml");
    let Ok(text) = std::fs::read_to_string(&audit) else {
        return Vec::new();
    };
    extract_ci_script_tokens(&text)
        .into_iter()
        .map(|p| repo_root.join(p))
        .filter(|p| p.is_file())
        .collect()
}

/// Pure token extraction (testable): every `scripts/ci/<name>.sh` referenced on
/// a non-comment line. Deduped + sorted.
fn extract_ci_script_tokens(text: &str) -> std::collections::BTreeSet<String> {
    let mut seen = std::collections::BTreeSet::new();
    for line in text.lines() {
        // Skip comment-only lines so a commented-out gate isn't resurrected.
        if line.trim_start().starts_with('#') {
            continue;
        }
        let mut rest = line;
        while let Some(pos) = rest.find("scripts/ci/") {
            let tail = &rest[pos..];
            // Token ends at the first char not valid in our script paths.
            let end = tail
                .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | '.')))
                .unwrap_or(tail.len());
            let token = &tail[..end];
            if token.ends_with(".sh") {
                seen.insert(token.to_string());
            }
            rest = &tail[end.max(1)..];
        }
    }
    seen
}

/// Auto-classify a test script as safe to run in a local `--full` pass.
/// Returns false when the script (executable lines only — comments ignored)
/// contains a marker that needs the network / GitHub / a live daemon, which
/// would false-fail off-CI. Conservative by design: any real marker → skip.
fn is_local_safe_script(path: &std::path::Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        // Unreadable → don't run it (can't classify → skip is the safe default).
        return false;
    };
    // Markers that imply a live external dependency preflight can't satisfy.
    const NETWORK_MARKERS: &[&str] = &[
        "gh api",
        "gh pr",
        "gh run",
        "gh workflow",
        "gh release",
        "gh repo",
        "gh auth",
        "curl ",
        "wget ",
        "git push",
        "git fetch",
        "git clone",
        "smee",
        "nats",
        "nc -",
        "ncat",
        "://api.github.com",
        "cache_refresh_open_prs",
    ];
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with('#') {
            continue;
        }
        // Strip trailing inline comment cheaply (best-effort; markers rarely
        // live only inside a quoted string, and a false-skip is safe anyway).
        let code = t.split(" #").next().unwrap_or(t);
        for m in NETWORK_MARKERS {
            if code.contains(m) {
                return false;
            }
        }
    }
    true
}

// ── RESILIENT-196: disk-floor guard ────────────────────────────────────────
//
// A full workspace build writes several GB into target/. Starting one below
// headroom ENOSPC-crashes mid-compile — on 2026-07-24 the data volume hit 100%
// and deadlocked even the shell (couldn't write a command's output file). Refuse
// to start the cargo gates below a floor, with a clear message + an audit event,
// instead of crashing. Fail-open if df is unreadable (never block on unknown).

const DEFAULT_PREFLIGHT_DISK_FLOOR_GB: f64 = 15.0;

fn preflight_disk_floor_gb() -> f64 {
    std::env::var("CHUMP_PREFLIGHT_DISK_FLOOR_GB")
        .ok()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .unwrap_or(DEFAULT_PREFLIGHT_DISK_FLOOR_GB)
}

/// Pure floor comparison (extracted for testing). At-or-above the floor is OK.
fn disk_floor_breached(free_gb: f64, floor_gb: f64) -> bool {
    free_gb < floor_gb
}

/// Live free space (GiB) at `path` via `df -Pk`. `None` on any failure so the
/// caller fails open rather than blocking on an unreadable df.
fn free_disk_gb(path: &std::path::Path) -> Option<f64> {
    let out = std::process::Command::new("df")
        .args(["-Pk", &path.to_string_lossy()])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    // POSIX `df -Pk`: header line, then one data line; column 4 = available 1K-blocks.
    let avail_k: f64 = text
        .lines()
        .nth(1)?
        .split_whitespace()
        .nth(3)?
        .parse()
        .ok()?;
    Some(avail_k / 1_048_576.0) // KiB → GiB
}

fn emit_disk_floor_breach(free_gb: f64, floor_gb: f64) {
    // scanner-anchor: kind=disk_floor_breach (RESILIENT-196)
    let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
        kind: "disk_floor_breach".to_string(),
        source: Some("chump-preflight".to_string()),
        fields: vec![
            ("free_gb".to_string(), format!("{free_gb:.1}")),
            ("floor_gb".to_string(), format!("{floor_gb:.1}")),
        ],
        ..Default::default()
    });
}

/// Refuse to start a cargo build below the disk floor. Returns Err(message) when
/// breached; Ok otherwise (including fail-open on unreadable df or floor<=0).
fn check_build_disk_floor(repo_root: &std::path::Path) -> Result<(), String> {
    let floor = preflight_disk_floor_gb();
    if floor <= 0.0 {
        return Ok(()); // disabled via CHUMP_PREFLIGHT_DISK_FLOOR_GB=0
    }
    let Some(free) = free_disk_gb(repo_root) else {
        return Ok(()); // fail-open: unknown free space never blocks
    };
    if disk_floor_breached(free, floor) {
        emit_disk_floor_breach(free, floor);
        return Err(format!(
            "disk floor breached: {free:.1} GB free < {floor:.1} GB needed for a build.\n\
             A full compile writes several GB to target/; starting one now risks an \
             ENOSPC crash mid-build. Free space first, e.g.:\n  \
             rm -rf target/debug/incremental   # regenerable\n  \
             rm -rf /private/tmp/wt-*           # stale worktrees (branches pushed)\n  \
             cargo clean                        # full, slow rebuild\n\
             Or lower/disable the floor: CHUMP_PREFLIGHT_DISK_FLOOR_GB=<N> (0 disables)."
        ));
    }
    Ok(())
}

/// Entry point called from main.rs subcommand dispatch.
/// Returns the process exit code.
pub fn run(argv: &[String]) -> i32 {
    // RESILIENT-172: when preflight is invoked from a git hook (pre-push),
    // git exports GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE for the HOST repo.
    // GIT_DIR overrides Command::current_dir in every child process, so any
    // gate that spawns git against an explicit fixture/clone dir (cargo test
    // fixtures especially) silently mutates the host repo instead — observed
    // live 2026-07-18: remote URL rewritten, git identity flipped, fixture
    // commits landed on real branches. Preflight never needs the hook's
    // GIT_* context (it resolves the repo via cwd), so scrub it once here
    // and every spawned gate inherits a clean environment.
    for k in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY",
        "GIT_COMMON_DIR",
    ] {
        std::env::remove_var(k);
    }
    let mut args = parse_args(argv);
    if args.help {
        print_help();
        return 0;
    }
    // EFFECTIVE-318: --full reproduces CI's audit shards locally — force the
    // widest scope + script gates, then (below) add every locally-safe audit
    // test script. One local pass instead of a ~20-min CI round-trip per miss.
    if args.full {
        args.scope = ScopeArg::All;
        args.with_tests = true;
    }
    if let Some(bad) = &args.bad_scope {
        eprintln!(
            "chump preflight: bad --scope value '{}' (want auto|all|rust|scripts|docs)",
            bad
        );
        return 2;
    }
    let repo_root = match find_repo_root() {
        Some(p) => p,
        None => {
            eprintln!("chump preflight: not inside a git repo");
            return 2;
        }
    };

    // Set cwd to repo root so cargo + scripts pick up the right Cargo.toml.
    if std::env::set_current_dir(&repo_root).is_err() {
        eprintln!(
            "chump preflight: could not cd to repo root {}",
            repo_root.display()
        );
        return 2;
    }

    // EFFECTIVE-363: artifact_type dispatch happens before any cargo-shaped
    // scope logic runs — a non-code, *registered* artifact_type (e.g.
    // "release-note") never touches cargo at all, it runs only its
    // registered gates and returns immediately. An unregistered type
    // (including the default "code") falls through to the normal pipeline
    // below unchanged.
    if let Some(t) = &args.artifact_type {
        if t != "code" && crate::artifact_gates::gates_for(t).is_some() {
            return crate::artifact_gates::dispatch(&repo_root, t, args.keep_going);
        } else if t != "code" {
            eprintln!(
                "chump preflight: no gate registry entry for --artifact-type '{}' — falling back to the cargo pipeline",
                t
            );
        }
    }

    // INFRA-2422: read main-preflight state BEFORE scope so we can report
    // which gates will be auto-skipped due to trunk-RED.
    let main_red_gates = read_main_preflight_failing_gates(&repo_root);
    let trunk_fix_gap_id = if main_red_gates.is_empty() {
        String::new()
    } else {
        read_trunk_fix_gap_id(&repo_root)
    };
    // Helper: returns true when a gate should be auto-skipped because
    // origin/main is already failing it (zero-bypass: no env override needed).
    let is_main_red_gate =
        |gate_name: &str| -> bool { main_red_gates.iter().any(|g| g == gate_name) };

    let scope = resolve_scope(args.scope, &repo_root);
    eprintln!(
        "[preflight] scope={} (--scope {:?})",
        scope.label(),
        args.scope
    );
    // RESILIENT-196: refuse to start the cargo gates below the disk floor rather
    // than ENOSPC-crashing mid-compile (2026-07-24 deadlock). Only guards when a
    // rust build will actually run; fails open on unreadable df.
    if scope.rust {
        if let Err(msg) = check_build_disk_floor(&repo_root) {
            eprintln!("[preflight] {msg}");
            return 2;
        }
    }
    // Print which heavy buckets are being skipped — useful operator signal.
    if !scope.rust {
        eprintln!("[preflight] skipping cargo gates (no rust files in scope)");
    }
    if !scope.scripts && args.with_tests {
        eprintln!("[preflight] skipping scripts gates (no scripts files in scope)");
    }
    if !main_red_gates.is_empty() {
        eprintln!(
            "[preflight] main-RED: auto-skipping {} gate(s) failing on origin/main: [{}]",
            main_red_gates.len(),
            main_red_gates.join(", ")
        );
        if !trunk_fix_gap_id.is_empty() {
            eprintln!("[preflight]   trunk fix tracked in: {}", trunk_fix_gap_id);
        }
    }

    let mut steps: Vec<Step> = vec![];

    // MISSION-064: env-var-coverage (INFRA-1787) + event-registry-audit
    // (INFRA-1731) are ALWAYS-ON (AlwaysFast), not rust-scoped. A scripts- or
    // docs-scoped PR that introduces a new CHUMP_* env var or ambient kind
    // (common in shell) must be caught locally, not on a ~15-min CI round-trip
    // (docs/strategy/CI_REVIEW_2026-05-29.md Lever 4 — the cheapest high-value
    // lever). Per-gate skip flags preserved.
    if std::env::var("CHUMP_PREFLIGHT_SKIP_REGISTRY").as_deref() == Ok("1") {
        eprintln!("[preflight] skipping event-registry-audit (CHUMP_PREFLIGHT_SKIP_REGISTRY=1)");
        let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
            kind: "preflight_registry_bypassed".to_string(),
            source: Some("chump-preflight".to_string()),
            fields: vec![(
                "reason".to_string(),
                "CHUMP_PREFLIGHT_SKIP_REGISTRY=1".to_string(),
            )],
            ..Default::default()
        });
    } else {
        steps.push(step(
            "event-registry-audit",
            &["bash", "scripts/ci/test-event-registry-coverage.sh"],
            GateKind::AlwaysFast,
        ));
    }
    if std::env::var("CHUMP_PREFLIGHT_SKIP_ENVVARS").as_deref() == Ok("1") {
        eprintln!("[preflight] skipping env-var-coverage (CHUMP_PREFLIGHT_SKIP_ENVVARS=1)");
        let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
            kind: "preflight_envvars_bypassed".to_string(),
            source: Some("chump-preflight".to_string()),
            fields: vec![(
                "reason".to_string(),
                "CHUMP_PREFLIGHT_SKIP_ENVVARS=1".to_string(),
            )],
            ..Default::default()
        });
    } else {
        steps.push(step(
            "env-var-coverage",
            &["bash", "scripts/ci/test-env-var-coverage.sh"],
            GateKind::AlwaysFast,
        ));
    }

    if scope.includes(GateKind::Rust) {
        steps.push(step(
            "cargo fmt --check",
            &["cargo", "fmt", "--all", "--", "--check"],
            GateKind::Rust,
        ));
        steps.push(step(
            "cargo clippy -D warnings",
            &[
                "cargo",
                "clippy",
                "--workspace",
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ],
            GateKind::Rust,
        ));
        // META-178 / META-177 lane D: use --all-targets so that test code,
        // bench targets, and integration-test initializers are checked.
        // Without this, a struct field added to a shared crate (e.g. GapRow)
        // passes cargo check in the defining crate but misses dependent crates
        // whose test initializers (in #[cfg(test)] blocks) reference the old
        // struct layout — exactly the INFRA-2134 trunk-RED root cause.
        //
        // EFFECTIVE-372: scoped to the changed crate(s) (`-p <crate>` per
        // touched crate) + capped jobs + nice + load-aware-defer, falling
        // back to `--workspace` whenever scoping can't be proven safe (see
        // `changed_crate_names`). Still `--all-targets` either way so the
        // INFRA-2134 test-initializer coverage above is unaffected.
        steps.push(cargo_check_step(&repo_root, &staged_paths(&repo_root)));
        // MISSION-064: event-registry-audit + env-var-coverage moved to the
        // ALWAYS-ON section above (they now run for any scope, not just rust).
        // INFRA-1789: chump-subcommand-help regression gate. Catches the
        // class of failures where a subcommand registers but `chump <subcmd>
        // --help` falls through to the LLM agent or fails on "missing
        // positional" (INFRA-1238 shipped 2× this quarter). The CI script
        // skips cleanly if chump binary isn't on PATH, so this gate is safe
        // to run unconditionally in the Rust-scope branch.
        // Skip via CHUMP_PREFLIGHT_SKIP_SUBCMDHELP=1 with audit-trail emit.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_SUBCMDHELP").as_deref() == Ok("1") {
            eprintln!(
                "[preflight] skipping chump-subcommand-help (CHUMP_PREFLIGHT_SKIP_SUBCMDHELP=1)"
            );
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_subcmdhelp_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_SUBCMDHELP=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "chump-subcommand-help",
                &["bash", "scripts/ci/test-chump-subcommand-help.sh"],
                GateKind::Rust,
            ));
        }
        // MISSION-033: repos table migration + CLI + auto-import gate.
        // Verifies the repos table schema, all 3 indexes, upsert_repos_from_skills
        // auto-population, and the full chump repos list/show/add/set/rm CLI.
        steps.push(step(
            "repos table migration + CLI + auto-import (MISSION-033)",
            &["bash", "scripts/ci/test-chump-repos.sh"],
            GateKind::Rust,
        ));
        // INFRA-1791: gap-preflight-ac-gate audit. Surfaces open gaps with
        // vague/empty AC (TODO placeholders) before the operator tries to
        // claim them — INFRA-1259's "every open gap must have concrete AC"
        // discipline. Skip via CHUMP_PREFLIGHT_SKIP_ACGATE=1 with audit-trail
        // emit (mirrors INFRA-1731 #2377 pattern).
        if std::env::var("CHUMP_PREFLIGHT_SKIP_ACGATE").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping gap-preflight-ac-gate (CHUMP_PREFLIGHT_SKIP_ACGATE=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_acgate_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_ACGATE=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "gap-preflight-ac-gate",
                &["bash", "scripts/ci/test-gap-preflight-ac-gate.sh"],
                GateKind::Rust,
            ));
        }
        // INFRA-1831: gaps-integrity local gate (META-070). Validates that
        // every docs/gaps/*.yaml parses as YAML, has a non-empty id, and
        // ids are unique across the registry. Would have caught both
        // 2026-05-23 cascade keystones (#2417 + #2419) — 3 yaml files with
        // malformed AC that blocked the merge queue for ~2.5h.
        // Mirrors INFRA-1731 #2377 pattern: skip via env + audit emit.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_GAPSINT").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping gaps-integrity (CHUMP_PREFLIGHT_SKIP_GAPSINT=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_gapsint_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_GAPSINT=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "gaps-integrity",
                &[
                    "python3",
                    "scripts/coord/check-gaps-integrity.py",
                    "--per-file",
                    "docs/gaps/",
                ],
                GateKind::Rust,
            ));
        }

        // INFRA-1790: markdown intra-doc-links audit (DOC-039). Catches
        // broken relative links in .md files modified by the current PR
        // (vs origin/main). The underlying script defaults to "changed"
        // mode so this gate auto-scopes to the diff — no extra plumbing.
        // Skip via CHUMP_PREFLIGHT_SKIP_MDLINKS=1 with audit-trail emit.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_MDLINKS").as_deref() == Ok("1") {
            eprintln!(
                "[preflight] skipping markdown-intra-doc-links (CHUMP_PREFLIGHT_SKIP_MDLINKS=1)"
            );
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_mdlinks_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_MDLINKS=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "markdown-intra-doc-links",
                &["bash", "scripts/ci/test-markdown-intra-doc-links.sh"],
                GateKind::Rust,
            ));
        }

        // INFRA-1921 (batched per AC): 4 META-070 mirror gates land together
        // because they all insert at the same site and each one alone causes
        // identical conflicts on the others' branches when main moves. Each
        // gate has its own bypass env var so an operator can disable them
        // individually without disabling the whole batch.

        // INFRA-1855: cargo-test workspace gate (META-070 Tier-C). Heaviest
        // unmirrored gate — catches "broken on main, every PR fails" class
        // (INFRA-1832 events.rs Debug panic + INFRA-1916 chump-pillar-health
        // removal would both have been caught locally). Wraps existing
        // scripts/ci/cargo-test-with-rerun.sh.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_CARGOTEST").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping cargo-test (CHUMP_PREFLIGHT_SKIP_CARGOTEST=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_cargotest_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_CARGOTEST=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            // INFRA-2720: cargo-test-with-rerun.sh REQUIRES `-- <cmd> [args...]`.
            // Without the separator + cargo invocation the wrapper prints
            // usage and exits non-zero — every push from a clean checkout
            // failed this gate locally (CI ran the wrapper through a
            // different ci.yml step that passed args; preflight inherited
            // the wrapper but not the args).
            //
            // CREDIBLE-175: run the suite under `cargo nextest run`
            // (process-isolated) — exactly what CI runs (ci.yml wraps
            // `cargo nextest run` in this same script). Thread-shared
            // `cargo test` false-reds on CHUMP_REPO/CHUMP_HOME env-var races
            // (repo_tools/tool_middleware) that CI's nextest never hits, which
            // forced --skip-tests bypasses on otherwise-clean pushes. Fall back
            // to `cargo test` only when cargo-nextest is not installed.
            let nextest_available = std::process::Command::new("cargo")
                .args(["nextest", "--version"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            steps.push(step(
                "cargo-test",
                cargo_test_wrapper_argv(nextest_available),
                GateKind::Rust,
            ));
        }

        // INFRA-1857: system-integration-test gate (INFRA-849). Mirrors
        // .github/workflows/ci.yml integration-test job — runs the synthetic
        // state.db fixture + chump CLI smoke via existing
        // scripts/ci/test-system-integration.sh.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_INTEGRATION").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping integration-test (CHUMP_PREFLIGHT_SKIP_INTEGRATION=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_integration_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_INTEGRATION=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "integration-test",
                &["bash", "scripts/ci/test-system-integration.sh"],
                GateKind::Rust,
            ));
        }

        // INFRA-1858: chump-first contract gate (CREDIBLE-046). Mirrors
        // .github/workflows/no-anthropic-smoke.yml — proves the coordination
        // layer (gap list/reserve/show/ship) works without ANTHROPIC_API_KEY
        // or CLAUDE_CODE_OAUTH_TOKEN. The CREDIBLE-046 regression cost
        // ~3h of throughput before #2404 fixed it; this gate catches it
        // locally before push.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_CHUMPFIRST").as_deref() == Ok("1") {
            eprintln!(
                "[preflight] skipping chump-first-contract (CHUMP_PREFLIGHT_SKIP_CHUMPFIRST=1)"
            );
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_chumpfirst_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_CHUMPFIRST=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "chump-first-contract",
                &["bash", "scripts/ci/check-chump-first-contract.sh"],
                GateKind::Rust,
            ));
        }

        // INFRA-1859: acp-smoke gate. Mirrors editor-integration.yml acp-smoke
        // job — runs the ACP protocol smoke test via existing
        // scripts/ci/test-acp-smoke.sh. The underlying script handles its
        // own missing-dep skip-gracefully (node + chromedriver).
        if std::env::var("CHUMP_PREFLIGHT_SKIP_ACPSMOKE").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping acp-smoke (CHUMP_PREFLIGHT_SKIP_ACPSMOKE=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_acpsmoke_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_ACPSMOKE=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "acp-smoke",
                &["bash", "scripts/ci/test-acp-smoke.sh"],
                GateKind::Rust,
            ));
        }
    }

    // INFRA-1788: docs-delta-trailer gate. Only fires under --pre-commit
    // (we're on the path to a real commit and HEAD's COMMIT_EDITMSG is
    // populated). The gate doesn't go through the generic step runner —
    // it executes inline because its diagnostic message needs to flow
    // through preflight's terminal output, not be captured-and-truncated.
    let mut docs_delta_failed = false;
    if args.pre_commit {
        if std::env::var("CHUMP_PREFLIGHT_SKIP_DOCSDELTA").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping docs-delta-trailer (CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_docsdelta_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            let started_dd = Instant::now();
            eprint!("[preflight] docs-delta-trailer ... ");
            let dd = run_docs_delta_check(&repo_root);
            let elapsed_dd = started_dd.elapsed().as_millis();
            let symbol = if !dd.ran {
                "·"
            } else if dd.should_fail {
                "✗"
            } else {
                "✓"
            };
            eprintln!("{} ({}ms)", symbol, elapsed_dd);
            if !dd.message.is_empty() {
                eprintln!("{}", dd.message);
            }
            if dd.should_fail {
                docs_delta_failed = true;
            }
        }
    }
    // else: bare `chump preflight` — gate is silently skipped (AC #6).

    // INFRA-1854: pr-hygiene local gate. Mirrors ci.yml pr-hygiene job —
    // wraps CREDIBLE-027 mass-deletion + INFRA-1568 broad-canary sub-checks
    // via scripts/ci/check-pr-hygiene.sh. (check-pr-scope CREDIBLE-026 is
    // already covered by INFRA-1792 pr-scope-sanity gate.) Lives in the
    // Scripts scope (vs the 4 Rust-scope gates above) because pr-hygiene
    // only inspects file paths in the diff — runs even when no Rust changed.
    if scope.includes(GateKind::Scripts) {
        if std::env::var("CHUMP_PREFLIGHT_SKIP_PRHYGIENE").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping pr-hygiene (CHUMP_PREFLIGHT_SKIP_PRHYGIENE=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_prhygiene_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_PRHYGIENE=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "pr-hygiene",
                &["bash", "scripts/ci/check-pr-hygiene.sh"],
                GateKind::Scripts,
            ));
        }

        // INFRA-2350 (META-269 sub-1): mirror three CI gates that today's
        // session demonstrated are NOT caught locally — pipefail-race-sweep
        // (INFRA-1658), path-filter-coverage (INFRA-682), and install-mapping
        // (INFRA-1810). Each fires in <1s and runs whenever Scripts scope is
        // active. Skip via the gate-specific bypass env with audit-trail emit.

        // INFRA-1658: bash subshell pipefail-race sweep. Catches a class of
        // races where `cmd | other-cmd` inside a `set -e`-d script swallows
        // failure because bash's pipefail isn't set. Detecting locally avoids
        // a CI round-trip on the install/uninstall path.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_PIPEFAIL").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping pipefail-race-sweep (CHUMP_PREFLIGHT_SKIP_PIPEFAIL=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_pipefail_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_PIPEFAIL=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "pipefail-race-sweep",
                &["bash", "scripts/ci/test-pipefail-race-sweep.sh"],
                GateKind::Scripts,
            ));
        }

        // INFRA-682: path-filter allowlist structural coverage. Detects when
        // a contributor adds new code paths but forgets to add them to the
        // ci.yml `code:` paths-filter. Previously runtime-detected via the
        // `if: filter.code == 'false'` warning; this gate catches the
        // structural drift earlier.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_PATHFILTER").as_deref() == Ok("1") {
            eprintln!(
                "[preflight] skipping path-filter-coverage (CHUMP_PREFLIGHT_SKIP_PATHFILTER=1)"
            );
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_pathfilter_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_PATHFILTER=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "path-filter-coverage",
                &["bash", "scripts/ci/check-path-filter-coverage.sh"],
                GateKind::Scripts,
            ));
        }

        // INFRA-1810: install-script manifest gate. Verifies every
        // scripts/setup/install-*.sh is mapped to REQUIRED_DAEMONS,
        // optional-installers-allowlist.txt, or deprecated-installers-allowlist.txt.
        // Prevents the "ship but never install" class — productization layer
        // sits dormant because the daemon was never wired into the installer.
        if std::env::var("CHUMP_PREFLIGHT_SKIP_INSTALLMAP").as_deref() == Ok("1") {
            eprintln!("[preflight] skipping install-manifest (CHUMP_PREFLIGHT_SKIP_INSTALLMAP=1)");
            let _ =
                chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
                    kind: "preflight_installmap_bypassed".to_string(),
                    source: Some("chump-preflight".to_string()),
                    fields: vec![(
                        "reason".to_string(),
                        "CHUMP_PREFLIGHT_SKIP_INSTALLMAP=1".to_string(),
                    )],
                    ..Default::default()
                });
        } else {
            steps.push(step(
                "install-manifest",
                &["bash", "scripts/ci/test-install-script-manifest.sh"],
                GateKind::Scripts,
            ));
        }

        // INFRA-2419: plist-no-tmp-paths gate. Verifies no checked-in plist
        // template or installer-generated plist bakes an ephemeral temp path
        // (/tmp/, /private/tmp/, /var/folders/, $TMPDIR) into ProgramArguments
        // or WorkingDirectory. Root cause: com.chump.integrator-daemon crashed
        // 145 times (37h) because the plist had `cd /private/tmp/chump-install`
        // baked in — the dir was reaped after install. Pure static file lint;
        // safe and fast (<1s) in local preflight with no launchd dependency.
        steps.push(step(
            "plist-no-tmp-paths",
            &["bash", "scripts/ci/test-plist-no-tmp-paths.sh"],
            GateKind::Scripts,
        ));

        // INFRA-2338: install-trunk-sentinel.sh smoke. Verifies the installer
        // writes BOTH the trunk-sentinel plist AND the fix-trunk-dispatcher
        // plist, with REPO_ROOT correctly substituted. Mocks launchctl/plutil
        // via a stub bin dir; no real launchd touched.
        steps.push(step(
            "install-trunk-sentinel",
            &["bash", "scripts/ci/test-install-trunk-sentinel.sh"],
            GateKind::Scripts,
        ));

        // INFRA-1808: every scripts/setup/install-*.sh must be mode 0755.
        // install-bot-merge-watchdog.sh shipped 0644 and silently never ran
        // via chump-fleet-bootstrap.sh for days. Pure stat check, <1s.
        steps.push(step(
            "install-scripts-executable",
            &["bash", "scripts/ci/test-install-scripts-executable.sh"],
            GateKind::Scripts,
        ));

        // INFRA-1808: bootstrap-auto-install smoke. install-bootstrap-auto-
        // launchd.sh (the hourly self-install job for chump-fleet-bootstrap.sh)
        // must generate a valid plist and its runner must emit
        // kind=fleet_bootstrap_auto_install. Dry-run + stub bootstrap script;
        // no real launchd touched.
        steps.push(step(
            "bootstrap-auto-install",
            &["bash", "scripts/ci/test-bootstrap-auto-install.sh"],
            GateKind::Scripts,
        ));

        // RESILIENT-271: coord-assign-launchd gate. Verifies the
        // com.chump.coord-assign plist + installer that wires the built
        // `chump-coord assign` push-routing daemon (FLEET-034 / INFRA-2476)
        // into launchd — without it the daemon was built code-on-disk but
        // never ran, so preferred_machine could never route work via the
        // mesh. Pure static plist-lint + installer dry-run against a temp
        // HOME with a stubbed launchctl; no real launchd touched, <1s.
        steps.push(step(
            "coord-assign-launchd",
            &["bash", "scripts/ci/test-coord-assign-launchd.sh"],
            GateKind::Scripts,
        ));

        // INFRA-2429: no-new-bypass-env-vars gate. Catches new CHUMP_*_BYPASS,
        // CHUMP_*_SKIP, and CHUMP_IGNORE_* introductions before push, enforcing
        // the operator zero-bypass thesis. Runs in the Scripts scope because it
        // only needs `git diff` — no cargo binary required. Always-on: this gate
        // intentionally has NO bypass env var of its own (the allowlist file is
        // the only sanctioned escape hatch). Runs in <1s.
        steps.push(step(
            "no-new-bypass-env-vars",
            &["bash", "scripts/ci/test-no-new-bypass-env-vars.sh"],
            GateKind::Scripts,
        ));

        // INFRA-2741: mission-picker gate. Mirrors the audit.yml
        // test-mission-picker.sh step (MISSION-011) — verifies that
        // scripts/dispatch/_pick_gap.py surfaces mission-linked gaps before
        // equal-priority substrate gaps and that the boost stays bounded (a
        // substrate P0 still beats a mission P1). Pure-Python unit test with
        // synthetic gaps.json fixtures: no network, no chump binary, no
        // GitHub API — runs in <2s, so it belongs in the local fast loop
        // rather than the parity allowlist. Always-on with NO bypass env var
        // (a CHUMP_*_SKIP would trip the EFFECTIVE-094 zero-bypass
        // debt-ceiling enforced by the no-new-bypass-env-vars gate above).
        steps.push(step(
            "mission-picker",
            &["bash", "scripts/ci/test-mission-picker.sh"],
            GateKind::Scripts,
        ));

        // MISSION-028: worker-picker mission-rank gate. Mirrors the audit.yml
        // test-mission-picker-worker.sh step — verifies that the WORKER's
        // picker (_pick_and_claim_gap.py, used by worker.sh) also surfaces
        // P0-MISSION gaps before P0-substrate gaps and that the xs-effort
        // gate exception works for sonnet workers. Same characteristics as
        // the mission-picker gate above: pure-Python, <2s, no network.
        steps.push(step(
            "mission-picker-worker",
            &["bash", "scripts/ci/test-mission-picker-worker.sh"],
            GateKind::Scripts,
        ));

        // RESILIENT-332: worker-picker anti-SPIN gate. Mirrors the audit.yml
        // test-worker-no-spin.sh step — proves the worker picker
        // (_pick_and_claim_gap.py) ADVANCES past a preflight-failing or
        // open-PR gap and never re-offers it (the 2026-08-15 spin where a
        // worker re-picked two stale-open gaps 108x/15min doing zero work).
        // Same characteristics as the picker gates above: pure-Python picker +
        // cooldown files, <2s, no network, no chump binary.
        steps.push(step(
            "worker-no-spin",
            &["bash", "scripts/ci/test-worker-no-spin.sh"],
            GateKind::Scripts,
        ));

        // RESILIENT-135: worker timeout-scaler gate. Mirrors the audit.yml
        // test-worker-timeout-scale.sh step — proves the effort-based per-cycle
        // timeout derives from an IMMUTABLE base and cannot compound toward ~0s
        // (the death-spiral that zeroed autonomous worker completion: a live
        // worker was spawning claude -p with 0-7s budgets, killed rc=124 every
        // cycle). Pure bash arithmetic over the sourced compute_scaled_timeout()
        // helper: no network, no chump binary, <1s. Always-on, NO bypass env var.
        steps.push(step(
            "worker-timeout-scale",
            &["bash", "scripts/ci/test-worker-timeout-scale.sh"],
            GateKind::Scripts,
        ));

        // INFRA-3379 (META-086 cluster 1/5, gap/state-registry consistency):
        // mirror 14 gap/state-registry gates that were previously only
        // allowlisted in preflight-ci-parity-exceptions.txt. Each is pure
        // shell/sqlite, no chump binary required, <5s — safe for the fast
        // local loop. All always-on (no per-gate bypass env var) per the
        // EFFECTIVE-094 bypass-var debt-ceiling: adding 14 new
        // CHUMP_PREFLIGHT_SKIP_* vars would blow the ceiling, so these
        // follow the plist-no-tmp-paths / no-new-bypass-env-vars precedent
        // of shipping without one.
        steps.push(step(
            "docs-delta-trailer",
            &["bash", "scripts/ci/test-infra-124-docs-delta-trailer.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pre-push-force-lease-guard",
            &["bash", "scripts/ci/test-pre-push-force-lease-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "claim-fuzzy-match",
            &["bash", "scripts/ci/test-claim-fuzzy-match.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "git-identity-guard",
            &["bash", "scripts/ci/test-git-identity-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "hardcoded-date-guard",
            &["bash", "scripts/ci/test-hardcoded-date-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "migration-pipeline-gates",
            &["bash", "scripts/ci/test-migration-pipeline-gates.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "model-registry",
            &["bash", "scripts/ci/test-model-registry.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "submodule-guard",
            &["bash", "scripts/ci/test-submodule-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "credential-pattern-guard",
            &["bash", "scripts/ci/test-credential-pattern-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "docs-delta-guard",
            &["bash", "scripts/ci/test-docs-delta-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "raw-yaml-guard",
            &["bash", "scripts/ci/test-raw-yaml-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "ambient-schema",
            &["bash", "scripts/ci/test-ambient-schema.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "schema-version-assert",
            &["bash", "scripts/ci/test-schema-version-assert.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "lease-ttl-file",
            &["bash", "scripts/ci/test-infra-115-lease-ttl-file.sh"],
            GateKind::Scripts,
        ));

        // INFRA-4050 (META-070/META-086 audit-job decomposition, cluster
        // C3-pr-worker-lifecycle): mirror the 22 remaining unmirrored
        // PR/worker-lifecycle & merge-automation gates from
        // docs/process/AUDIT_JOB_DECOMPOSITION.md's C3 table (23 total in
        // that table; test-no-verify-audit.sh was already mirrored above).
        // Each is pure shell/fixture-based, no chump binary build required
        // — safe for the fast local loop. All always-on (no per-gate bypass
        // env var) per the EFFECTIVE-094 bypass-var debt-ceiling, same
        // precedent as the INFRA-3379 cluster mirror above.
        steps.push(step(
            "bot-merge-auto-close",
            &["bash", "scripts/ci/test-bot-merge-auto-close.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "bot-merge-conflict-wiring",
            &["bash", "scripts/ci/test-bot-merge-conflict-wiring.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "conflict-resolver",
            &["bash", "scripts/ci/test-conflict-resolver.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "external-verify-merge",
            &["bash", "scripts/ci/test-external-verify-merge.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "gate-promotion-no-regression",
            &["bash", "scripts/ci/test-gate-promotion-no-regression.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "bot-merge-hang",
            &["bash", "scripts/ci/test-infra-119-bot-merge-hang.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "install-pr-auto-rebase",
            &["bash", "scripts/ci/test-install-pr-auto-rebase.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-auto-rebase",
            &["bash", "scripts/ci/test-pr-auto-rebase.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-blocked-watch",
            &["bash", "scripts/ci/test-pr-blocked-watch.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-explain-block",
            &["bash", "scripts/ci/test-pr-explain-block.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-terminal-state",
            &["bash", "scripts/ci/test-pr-terminal-state.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-triage-bot",
            &["bash", "scripts/ci/test-pr-triage-bot.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-watch-auto-resolve",
            &["bash", "scripts/ci/test-pr-watch-auto-resolve.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pr-watch-shepherd-smoke",
            &["bash", "scripts/ci/test-pr-watch-shepherd-smoke.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pre-push-preflight-hook",
            &["bash", "scripts/ci/test-pre-push-preflight-hook.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pre-push-rebase-allow",
            &["bash", "scripts/ci/test-pre-push-rebase-allow.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pre-push-test-gate",
            &["bash", "scripts/ci/test-pre-push-test-gate.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "preflight-ci-parity-smoke",
            &["bash", "scripts/ci/test-preflight-ci-parity.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "rebase-coordination",
            &["bash", "scripts/ci/test-rebase-coordination.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "review-handoff-smoke",
            &["bash", "scripts/ci/test-review-handoff-smoke.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "stale-branch-rebase",
            &["bash", "scripts/ci/test-stale-branch-rebase.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "status-flip-proof-of-merge",
            &["bash", "scripts/ci/test-status-flip-proof-of-merge.sh"],
            GateKind::Scripts,
        ));

        // INFRA-3383 (META-086 misc-hygiene cluster): mirror 25 docs/CLI/
        // git-hooks hygiene gates that were previously only allowlisted in
        // preflight-ci-parity-exceptions.txt. Each is a fixture-based or
        // pure-shell check, no chump binary build required, <1s each —
        // safe for the fast local loop. All always-on (no per-gate bypass
        // env var) per the EFFECTIVE-094 bypass-var debt-ceiling, same
        // precedent as the INFRA-3379/INFRA-3377 cluster mirrors above.
        steps.push(step(
            "book-sync-guard",
            &["bash", "scripts/ci/test-book-sync-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "doc-freshness",
            &["bash", "scripts/ci/test-doc-freshness.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "no-claude-leak",
            &["bash", "scripts/ci/test-no-claude-leak.sh"],
            GateKind::Scripts,
        ));
        // CREDIBLE-240: docs/CAPABILITIES_REGISTRY.json is indexed by almanac,
        // so a broken catalog or a dangling file_paths receipt gets served to
        // agents with a file:line citation. Hermetic and ~2s — safe for the
        // fast local loop, same shape as the doc-freshness mirror above.
        steps.push(step(
            "capabilities-registry",
            &["bash", "scripts/ci/test-capabilities-registry.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "no-verify-audit",
            &["bash", "scripts/ci/test-no-verify-audit.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "css-token-discipline-smoke",
            &["bash", "scripts/ci/test-css-token-discipline.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "grep-c-echo0-guard-smoke",
            &["bash", "scripts/ci/test-grep-c-echo0-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "cross-judge-guard",
            &["bash", "scripts/ci/test-cross-judge-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "prereg-content-guard",
            &["bash", "scripts/ci/test-prereg-content-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "effective-010-completion",
            &["bash", "scripts/ci/test-effective-010-completion.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "default-flip-guard",
            &["bash", "scripts/ci/test-default-flip-guard.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "install-ambient-hooks",
            &["bash", "scripts/ci/test-install-ambient-hooks.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "merge-driver-ci-yml-add-row",
            &["bash", "scripts/ci/test-merge-driver-ci-yml-add-row.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "merge-driver-ci-yml",
            &["bash", "scripts/ci/test-merge-driver-ci-yml.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "merge-driver-coverage",
            &["bash", "scripts/ci/test-merge-driver-coverage.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "merge-driver-gap-yaml",
            &["bash", "scripts/ci/test-merge-driver-gap-yaml.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "merge-driver-pre-commit",
            &["bash", "scripts/ci/test-merge-driver-pre-commit.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "merge-driver-state-sql",
            &["bash", "scripts/ci/test-merge-driver-state-sql.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "infra-1025-atomic-claim",
            &["bash", "scripts/ci/test-infra-1025-atomic-claim.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "infra-3002-claim-import-similarity-nonfatal",
            &[
                "bash",
                "scripts/ci/test-claim-import-similarity-nonfatal.sh",
            ],
            GateKind::Scripts,
        ));
        steps.push(step(
            "infra-250-v1-retirement",
            &["bash", "scripts/ci/test-infra-250-v1-retirement.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "infra-257-doc-only-guards",
            &["bash", "scripts/ci/test-infra-257-doc-only-guards.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "infra-258-reaper-partial-delivery",
            &[
                "bash",
                "scripts/ci/test-infra-258-reaper-partial-delivery.sh",
            ],
            GateKind::Scripts,
        ));
        steps.push(step(
            "attribution-portable",
            &["bash", "scripts/ci/test-attribution-portable.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "cli-version-debug",
            &["bash", "scripts/ci/test-cli-version-debug.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "subagent-epilogue-ref",
            &["bash", "scripts/ci/test-subagent-epilogue-ref.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "pick-and-claim-lockdir",
            &["bash", "scripts/ci/test-pick-and-claim-lockdir.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "meta-011-git-stomp",
            &["bash", "scripts/ci/test-meta-011-git-stomp.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "preflight-ci-parity-smoke",
            &["bash", "scripts/ci/test-preflight-ci-parity-smoke.sh"],
            GateKind::Scripts,
        ));
        steps.push(step(
            "gap-reserve-no-stale-collision",
            &["bash", "scripts/ci/test-gap-reserve-no-stale-collision.sh"],
            GateKind::Scripts,
        ));
        // RESILIENT-001: the mirror-converge dirty-tree gate. Hermetic —
        // builds bare-repo fixtures in a tmpdir with a stubbed `chump`, no
        // network/root/systemctl — so it runs in local preflight identically
        // to the ci.yml pr-hygiene job (registers this gate for
        // preflight-vs-CI parity, INFRA-1867).
        steps.push(step(
            "backlog-sync-reader-dirty-tree",
            &["bash", "scripts/ci/test-backlog-sync-reader-dirty-tree.sh"],
            GateKind::Scripts,
        ));
        // INFRA-7887: registry-remote contract for the same script. Hermetic:
        // bare-repo fixtures in a tmpdir with HOME pinned and a stubbed
        // `chump`. Mirrors the ci.yml step of the same name.
        steps.push(step(
            "backlog-sync-registry-remote",
            &["bash", "scripts/ci/test-backlog-sync-registry-remote.sh"],
            GateKind::Scripts,
        ));

        // EFFECTIVE-1666 (EFFECTIVE-414 slice): bin-bloat-guard mirror.
        // Pure `git diff` + `wc -c` over new top-level src/*.rs files —
        // hermetic, <1s, no cargo build. Mirrors the ci.yml step above.
        steps.push(step(
            "bin-bloat-guard",
            &[
                "bash",
                "scripts/ci/bin-bloat-guard.sh",
                "--base",
                "origin/main",
            ],
            GateKind::Scripts,
        ));

        // INFRA-5000 (META-070/INFRA-3373 slice): cli_observability_misc
        // gate — mirrors the 41 remaining cli-observability-misc cluster
        // scripts from docs/process/AUDIT_JOB_DECOMPOSITION.md.
        for (name, script) in CLI_OBSERVABILITY_MISC_SCRIPTS {
            steps.push(step(name, &["bash", script], GateKind::Scripts));
        }
    }

    // INFRA-3377 (META-070): commit-content-guards mirrors. --pre-commit
    // only, same rationale as docs-delta-trailer above — these gates read
    // `git diff --cached`, so running them under a bare `chump preflight`
    // (no real staged commit in flight) would just recheck an empty stage
    // and pass trivially. Each fires in well under 1s (pure `git diff
    // --cached` + grep/awk, no cargo, no network).
    if args.pre_commit {
        for (name, script) in CONTENT_GUARD_MIRRORS {
            steps.push(step(name, &["bash", script], GateKind::Scripts));
        }
    }

    if args.with_tests && scope.includes(GateKind::Scripts) {
        for script in discover_test_scripts(&repo_root) {
            let path = script.to_string_lossy().into_owned();
            let name: &'static str = Box::leak(
                format!("script: {}", script.file_name().unwrap().to_string_lossy())
                    .into_boxed_str(),
            );
            steps.push(Step {
                name,
                argv: vec!["bash".to_string(), path],
                kind: GateKind::Scripts,
            });
        }
    }

    // EFFECTIVE-318: --full — reproduce CI's audit shards by running every
    // locally-safe test script audit.yml runs that isn't already a gate above.
    if args.full && scope.includes(GateKind::Scripts) {
        // Paths already covered by a step above (curated whitelist + the manual
        // mirror list), so --full only ADDS the gap, never double-runs.
        let mut present: std::collections::BTreeSet<String> = steps
            .iter()
            .filter_map(|s| s.argv.iter().find(|a| a.contains("scripts/ci/")).cloned())
            .collect();
        let mut added = 0usize;
        let mut skipped_net = 0usize;
        for script in discover_audit_scripts(&repo_root) {
            let path = script.to_string_lossy().into_owned();
            if present.contains(&path) {
                continue;
            }
            present.insert(path.clone());
            if !is_local_safe_script(&script) {
                skipped_net += 1;
                continue;
            }
            let name: &'static str = Box::leak(
                format!("audit: {}", script.file_name().unwrap().to_string_lossy())
                    .into_boxed_str(),
            );
            steps.push(Step {
                name,
                argv: vec!["bash".to_string(), path],
                kind: GateKind::Scripts,
            });
            added += 1;
        }
        eprintln!(
            "[preflight] --full: +{added} audit gate(s) discovered from audit.yml; \
             {skipped_net} skipped (need network/gh — CI-only)"
        );
    }

    // ── META-153: --vs baseline resolution ──────────────────────────────────
    // Resolve baseline BEFORE running HEAD gates so we can tell the operator
    // early if baseline is unavailable (and fall back gracefully per AC #4).
    let baseline: Option<BaselineCache> = if let Some(ref vs_ref) = args.vs_ref {
        eprintln!("[preflight] --vs {}: resolving baseline SHA …", vs_ref);
        match resolve_ref_sha(&repo_root, vs_ref) {
            None => {
                eprintln!(
                    "\x1b[33m⚠  [preflight] --vs {}: could not resolve ref (offline or not fetched).\x1b[0m",
                    vs_ref
                );
                eprintln!("   Falling back to normal preflight (no baseline diff).");
                None
            }
            Some(ref_sha) => {
                let cache_path = baseline_cache_path(&repo_root);
                let cached = load_baseline_cache(&cache_path);
                let fresh = cached.as_ref().is_some_and(|c| {
                    c.baseline_sha == ref_sha && baseline_age_secs(c) < BASELINE_CACHE_TTL_SECS
                });
                if fresh {
                    let age = baseline_age_secs(cached.as_ref().unwrap());
                    eprintln!(
                        "[preflight] baseline cache HIT — sha={} age={}s",
                        &ref_sha[..std::cmp::min(12, ref_sha.len())],
                        age
                    );
                    cached
                } else {
                    eprintln!(
                        "[preflight] baseline cache MISS — running preflight on {} …",
                        &ref_sha[..std::cmp::min(12, ref_sha.len())]
                    );
                    match run_baseline_against_ref(&repo_root, &ref_sha, &steps) {
                        None => {
                            eprintln!(
                                "\x1b[33m⚠  [preflight] --vs: worktree checkout failed for {}.\x1b[0m",
                                &ref_sha[..std::cmp::min(12, ref_sha.len())]
                            );
                            eprintln!("   Falling back to normal preflight (no baseline diff).");
                            None
                        }
                        Some(results) => {
                            let _ = save_baseline_cache(&cache_path, &ref_sha, &results);
                            Some(BaselineCache {
                                baseline_sha: ref_sha.clone(),
                                generated_at_secs: unix_now(),
                                gate_results: results,
                            })
                        }
                    }
                }
            }
        }
    } else {
        None
    };

    let started = Instant::now();
    let mut any_failed = false;
    let mut json_results: Vec<String> = vec![];
    // Collect HEAD gate outcomes for baseline diff later.
    let mut head_outcomes: Vec<(String, Status, u128)> = vec![];

    if steps.is_empty() {
        eprintln!(
            "[preflight] no gates selected for this scope — nothing to do (normal for docs-only)"
        );
    }

    for s in &steps {
        // INFRA-2422: auto-skip gates that are already failing on origin/main.
        // This replaces the deleted CHUMP_PREFLIGHT_SKIP=1 env bypass. Only
        // the specific failing gate is skipped; all other gates run normally.
        if is_main_red_gate(s.name) {
            eprintln!(
                "[preflight] skipping {} (main-red — see {})",
                s.name,
                if trunk_fix_gap_id.is_empty() {
                    "watchdog state"
                } else {
                    &trunk_fix_gap_id
                }
            );
            emit_main_red_skip(s.name, &trunk_fix_gap_id);
            head_outcomes.push((s.name.to_string(), Status::Skipped, 0));
            if args.json {
                json_results.push(format!(
                    r#"{{"step":"{}","status":"Skipped","elapsed_ms":0,"reason":"main-red"}}"#,
                    s.name
                ));
            }
            continue;
        }

        eprint!("[preflight] {} ... ", s.name);
        let out = run_step(s);
        let symbol = match out.status {
            Status::Pass => "✓",
            Status::Fail => "✗",
            Status::Skipped => "·",
        };
        eprintln!("{} ({}ms)", symbol, out.elapsed_ms);
        if args.json {
            json_results.push(format!(
                r#"{{"step":"{}","status":"{:?}","elapsed_ms":{}}}"#,
                s.name, out.status, out.elapsed_ms
            ));
        }
        head_outcomes.push((s.name.to_string(), out.status, out.elapsed_ms));
        if out.status == Status::Fail {
            // In --vs mode we run all gates (need full picture for diff),
            // otherwise respect --keep-going.
            let should_continue = baseline.is_some() || args.keep_going;
            if let Some(cap) = &out.captured {
                eprintln!("---- {} output ----", s.name);
                // Truncate to first ~2KB to avoid swamping the terminal.
                let trunc = if cap.len() > 2048 {
                    format!(
                        "{}\n... [{} more bytes truncated]",
                        &cap[..2048],
                        cap.len() - 2048
                    )
                } else {
                    cap.clone()
                };
                eprintln!("{}", trunc);
                eprintln!("---- end ----");
            }
            if !should_continue {
                any_failed = true;
                break;
            }
        }
    }

    let total_ms = started.elapsed().as_millis();

    // INFRA-1788: fold the inline docs-delta-trailer outcome into the
    // overall pass/fail decision (it runs outside the generic step loop).
    if docs_delta_failed {
        any_failed = true;
    }

    // ── META-153: diff attribution output ───────────────────────────────────
    if let Some(ref cache) = baseline {
        let baseline_age = baseline_age_secs(cache);
        let mut new_failures: Vec<String> = vec![];
        let mut preexisting: Vec<BaselineGateResult> = vec![];

        for (name, status, _) in &head_outcomes {
            if *status != Status::Fail {
                continue;
            }
            // Check if this gate also failed on baseline.
            let failed_on_baseline = cache
                .gate_results
                .iter()
                .any(|r| r.name == *name && !r.passed);
            if failed_on_baseline {
                if let Some(r) = cache.gate_results.iter().find(|r| r.name == *name) {
                    preexisting.push(r.clone());
                }
            } else {
                new_failures.push(name.clone());
            }
        }
        // docs_delta_failed is always NEW (pre-commit gate, not run on baseline).
        if docs_delta_failed {
            new_failures.push("docs-delta-trailer".to_string());
        }

        // Output sections per AC #3.
        eprintln!();
        if new_failures.is_empty() && preexisting.is_empty() {
            eprintln!(
                "\n[preflight --vs] PASS — no failures on HEAD ({}ms)",
                total_ms
            );
        } else {
            if !new_failures.is_empty() {
                eprintln!("╔══ NEW (your diff broke this — BLOCKS) ══╗");
                for name in &new_failures {
                    eprintln!("  ✗  {}", name);
                }
                eprintln!("╚════════════════════════════════════════╝");
            }
            if !preexisting.is_empty() {
                eprintln!("┌── PRE-EXISTING (not yours — warns, does not block) ──┐");
                for r in &preexisting {
                    let short_sha = &r.originating_commit_sha
                        [..std::cmp::min(8, r.originating_commit_sha.len())];
                    let age_h = baseline_age / 3600;
                    eprintln!(
                        "  ⚠  {} (baseline sha={} by {} ~{}h ago)",
                        r.name, short_sha, r.originating_commit_author, age_h
                    );
                }
                eprintln!("└──────────────────────────────────────────────────────┘");
            }
        }

        // JSON output per AC #6.
        if args.json {
            let new_json: Vec<String> = new_failures.iter().map(|n| json_str(n)).collect();
            let pre_json: Vec<String> = preexisting
                .iter()
                .map(|r| {
                    format!(
                        r#"{{"name":{},"baseline_sha":{},"author":{}}}"#,
                        json_str(&r.name),
                        json_str(&r.originating_commit_sha),
                        json_str(&r.originating_commit_author),
                    )
                })
                .collect();
            println!(
                r#"{{"new_failures":[{}],"preexisting_failures":[{}],"baseline_sha":{},"baseline_age_seconds":{}}}"#,
                new_json.join(","),
                pre_json.join(","),
                json_str(&cache.baseline_sha),
                baseline_age,
            );
        }

        // Emit ambient event per AC #7.
        let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
            kind: "preflight_baseline_diff".to_string(),
            source: Some("chump-preflight".to_string()),
            fields: vec![
                ("new_fail_count".to_string(), new_failures.len().to_string()),
                (
                    "preexisting_fail_count".to_string(),
                    preexisting.len().to_string(),
                ),
                (
                    "baseline_sha".to_string(),
                    cache.baseline_sha[..std::cmp::min(12, cache.baseline_sha.len())].to_string(),
                ),
            ],
            ..Default::default()
        });

        // Per AC #3: only NEW failures block.
        if !new_failures.is_empty() {
            eprintln!(
                "\n[preflight --vs] FAIL — {} new failure(s) introduced by your diff ({}ms)",
                new_failures.len(),
                total_ms
            );
            eprintln!("   Fix the failing gate(s) or wait for trunk fix (if main is also RED).");
            return 1;
        } else if !preexisting.is_empty() {
            eprintln!(
                "\n[preflight --vs] PASS (with {} pre-existing warning(s)) — your diff is clean ({}ms)",
                preexisting.len(),
                total_ms
            );
            return 0;
        } else {
            eprintln!("\n[preflight --vs] PASS — all gates green ({}ms)", total_ms);
            return 0;
        }
    }

    // ── Normal (non --vs) path ───────────────────────────────────────────────
    // Collect any gate failures not yet counted in the loop above.
    for (_, status, _) in &head_outcomes {
        if *status == Status::Fail {
            any_failed = true;
            break;
        }
    }

    if args.json {
        println!("[{}]", json_results.join(","));
    }
    if any_failed {
        eprintln!(
            "\n[preflight] FAIL — at least one gate did not pass (total {}ms)",
            total_ms
        );
        eprintln!("   Fix the failing gate(s) or wait for trunk fix (if main is also RED).");
        1
    } else {
        eprintln!("\n[preflight] PASS — all gates green ({}ms)", total_ms);
        0
    }
}

fn find_repo_root() -> Option<std::path::PathBuf> {
    let out = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(std::path::PathBuf::from(path))
    }
}

// ─── INFRA-2422: main-red-aware gate auto-skip ─────────────────────────────
//
// Reads `.chump/main-preflight-state.json` written by the
// main-preflight-watchdog daemon (INFRA-2397 + INFRA-2404).
// Returns the list of gate names currently failing on origin/main.
// When a gate is in this list, preflight auto-skips it with a logged
// reason rather than blocking the contributor's work.
//
// Shape of the JSON (subset we care about):
//   {"state":"RED","failing_gates":["event-registry-audit"],"filed_gaps":["INFRA-NNNN"]}
//
// Any parse error or missing file → empty Vec (no gates auto-skipped).
fn read_main_preflight_failing_gates(repo_root: &std::path::Path) -> Vec<String> {
    let state_path = repo_root.join(".chump/main-preflight-state.json");
    let raw = match std::fs::read_to_string(&state_path) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    // Only auto-skip when state=RED.
    if !raw.contains("\"RED\"") && !raw.contains("\"red\"") {
        return vec![];
    }
    // Extract failing_gates array. We parse manually to avoid a serde dep.
    // Pattern: "failing_gates":["gate1","gate2"]
    let gates_start = match raw.find("\"failing_gates\"") {
        Some(i) => i,
        None => return vec![],
    };
    let after_key = &raw[gates_start..];
    let arr_start = match after_key.find('[') {
        Some(i) => i,
        None => return vec![],
    };
    let arr_end = match after_key[arr_start..].find(']') {
        Some(i) => arr_start + i,
        None => return vec![],
    };
    let arr_content = &after_key[arr_start + 1..arr_end];
    // Extract quoted strings from the array.
    let mut gates = vec![];
    let mut remaining = arr_content;
    while let Some(q_start) = remaining.find('"') {
        let after_open = &remaining[q_start + 1..];
        if let Some(q_end) = after_open.find('"') {
            let gate = after_open[..q_end].trim().to_string();
            // Skip em-dash placeholder (watchdog uses "—" when no real gate name known).
            if !gate.is_empty() && gate != "—" && gate != "-" {
                gates.push(gate);
            }
            remaining = &after_open[q_end + 1..];
        } else {
            break;
        }
    }
    gates
}

/// Emit `preflight_main_red_skip` to ambient for a gate that was auto-skipped
/// because origin/main is already failing it.
// scanner-anchor: "kind":"preflight_main_red_skip"
fn emit_main_red_skip(gate: &str, trunk_fix_gap_id: &str) {
    let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
        kind: "preflight_main_red_skip".to_string(),
        source: Some("chump-preflight".to_string()),
        fields: vec![
            ("gate".to_string(), gate.to_string()),
            ("trunk_fix_gap_id".to_string(), trunk_fix_gap_id.to_string()),
        ],
        ..Default::default()
    });
}

/// Read the first filed trunk-fix gap ID from `.chump/main-preflight-state.json`.
/// Returns an empty string if none is found.
fn read_trunk_fix_gap_id(repo_root: &std::path::Path) -> String {
    let state_path = repo_root.join(".chump/main-preflight-state.json");
    let raw = match std::fs::read_to_string(&state_path) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };
    // Extract last element of filed_gaps array.
    let key_start = match raw.find("\"filed_gaps\"") {
        Some(i) => i,
        None => return String::new(),
    };
    let after_key = &raw[key_start..];
    let arr_start = match after_key.find('[') {
        Some(i) => i,
        None => return String::new(),
    };
    let arr_end = match after_key[arr_start..].find(']') {
        Some(i) => arr_start + i,
        None => return String::new(),
    };
    let arr_content = &after_key[arr_start + 1..arr_end];
    // Take the last quoted value.
    let mut last_gap = String::new();
    let mut remaining = arr_content;
    while let Some(q_start) = remaining.find('"') {
        let after_open = &remaining[q_start + 1..];
        if let Some(q_end) = after_open.find('"') {
            let gap = after_open[..q_end].trim().to_string();
            if !gap.is_empty() {
                last_gap = gap;
            }
            remaining = &after_open[q_end + 1..];
        } else {
            break;
        }
    }
    last_gap
}

// ─── META-153: diff-scoped failure attribution ──────────────────────────────

/// One gate result stored in the baseline cache.
#[derive(Debug, Clone)]
struct BaselineGateResult {
    name: String,
    passed: bool,
    duration_ms: u128,
    /// SHA of the commit that introduced this baseline.
    originating_commit_sha: String,
    /// Author of that commit.
    originating_commit_author: String,
}

/// The on-disk cache at `.chump/preflight-baseline.json`.
struct BaselineCache {
    baseline_sha: String,
    generated_at_secs: u64,
    gate_results: Vec<BaselineGateResult>,
}

const BASELINE_CACHE_TTL_SECS: u64 = 3600; // 1 hour per AC #2

/// Resolve the HEAD SHA of a ref (e.g. "origin/main") in the given repo.
/// Returns None on any error (offline, not fetched, etc.).
fn resolve_ref_sha(repo_root: &std::path::Path, git_ref: &str) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", git_ref])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if sha.len() < 7 {
        None
    } else {
        Some(sha)
    }
}

/// Resolve commit author for a SHA. Falls back to "<unknown>" on error.
fn commit_author(repo_root: &std::path::Path, sha: &str) -> String {
    let out = Command::new("git")
        .args(["log", "-1", "--pretty=%an", sha])
        .current_dir(repo_root)
        .output();
    match out {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if s.is_empty() {
                "<unknown>".to_string()
            } else {
                s
            }
        }
        _ => "<unknown>".to_string(),
    }
}

/// Seconds since UNIX epoch (best-effort; returns 0 on error).
fn unix_now() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Path to the baseline cache file.
fn baseline_cache_path(repo_root: &std::path::Path) -> std::path::PathBuf {
    repo_root.join(".chump").join("preflight-baseline.json")
}

/// Load the baseline cache from disk. Returns None on any parse / IO error.
fn load_baseline_cache(path: &std::path::Path) -> Option<BaselineCache> {
    let content = std::fs::read_to_string(path).ok()?;
    // Minimal hand-rolled JSON parse — no serde dependency required.
    // Format:
    // {"baseline_sha":"<sha>","generated_at":"<iso>","generated_at_secs":<N>,"gate_results":[...]}
    let sha = extract_json_str(&content, "baseline_sha")?;
    let gen_secs = extract_json_u64(&content, "generated_at_secs").unwrap_or(0);
    let results = parse_gate_results(&content);
    Some(BaselineCache {
        baseline_sha: sha,
        generated_at_secs: gen_secs,
        gate_results: results,
    })
}

/// Persist baseline cache to disk.
fn save_baseline_cache(
    path: &std::path::Path,
    sha: &str,
    results: &[BaselineGateResult],
) -> std::io::Result<()> {
    let now_secs = unix_now();
    let now_iso = {
        // Minimal ISO-8601 UTC timestamp without chrono.
        let s = now_secs;
        let sec = s % 60;
        let min = (s / 60) % 60;
        let hour = (s / 3600) % 24;
        let days = s / 86400;
        // Approximate date from epoch (good enough for TTL bookkeeping).
        let year = 1970 + days / 365;
        let doy = days % 365;
        let month = doy / 30 + 1;
        let day = doy % 30 + 1;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            year, month, day, hour, min, sec
        )
    };
    let mut entries = Vec::with_capacity(results.len());
    for r in results {
        entries.push(format!(
            r#"{{"name":{},"result":"{}","duration_ms":{},"originating_commit_sha":{},"originating_commit_author":{}}}"#,
            json_str(&r.name),
            if r.passed { "pass" } else { "fail" },
            r.duration_ms,
            json_str(&r.originating_commit_sha),
            json_str(&r.originating_commit_author),
        ));
    }
    let json = format!(
        r#"{{"baseline_sha":{},"generated_at":{},"generated_at_secs":{},"gate_results":[{}]}}"#,
        json_str(sha),
        json_str(&now_iso),
        now_secs,
        entries.join(","),
    );
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(path, json)
}

/// Quote a string as a JSON string value (handles backslash + double-quote).
fn json_str(s: &str) -> String {
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{}\"", escaped)
}

/// Minimal JSON string extraction — pulls the first `"key":"<value>"` match.
fn extract_json_str(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":\"", key);
    let start = json.find(&needle)? + needle.len();
    let rest = &json[start..];
    let mut val = String::new();
    let mut chars = rest.chars();
    loop {
        match chars.next()? {
            '"' => break,
            '\\' => match chars.next()? {
                '"' => val.push('"'),
                '\\' => val.push('\\'),
                'n' => val.push('\n'),
                c => val.push(c),
            },
            c => val.push(c),
        }
    }
    Some(val)
}

/// Minimal JSON u64 extraction — pulls the first `"key":<N>` match.
fn extract_json_u64(json: &str, key: &str) -> Option<u64> {
    let needle = format!("\"{}\":", key);
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// Parse the `gate_results` array from cached JSON. Returns empty vec on parse failure.
fn parse_gate_results(json: &str) -> Vec<BaselineGateResult> {
    let mut results = Vec::new();
    // Find gate_results array content.
    let arr_needle = "\"gate_results\":[";
    let Some(arr_start) = json.find(arr_needle) else {
        return results;
    };
    let arr_content = &json[arr_start + arr_needle.len()..];
    // Split on object boundaries — each entry is a {...} block.
    let mut depth = 0i32;
    let mut obj_start = None;
    for (i, c) in arr_content.char_indices() {
        match c {
            '{' => {
                if depth == 0 {
                    obj_start = Some(i);
                }
                depth += 1;
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    if let Some(s) = obj_start {
                        let obj = &arr_content[s..=i];
                        if let Some(r) = parse_one_gate_result(obj) {
                            results.push(r);
                        }
                        obj_start = None;
                    }
                }
            }
            ']' if depth == 0 => break,
            _ => {}
        }
    }
    results
}

fn parse_one_gate_result(obj: &str) -> Option<BaselineGateResult> {
    let name = extract_json_str(obj, "name")?;
    let result_str = extract_json_str(obj, "result")?;
    let passed = result_str == "pass";
    let duration_ms = extract_json_u64(obj, "duration_ms").unwrap_or(0);
    let originating_commit_sha =
        extract_json_str(obj, "originating_commit_sha").unwrap_or_else(|| "unknown".to_string());
    let originating_commit_author = extract_json_str(obj, "originating_commit_author")
        .unwrap_or_else(|| "<unknown>".to_string());
    Some(BaselineGateResult {
        name,
        passed,
        duration_ms: duration_ms.into(),
        originating_commit_sha,
        originating_commit_author,
    })
}

/// Run all preflight steps against a temporary worktree checked out at `ref_sha`.
/// Returns the gate results (name → passed).
/// On any setup error, returns None (caller falls back to normal mode).
fn run_baseline_against_ref(
    repo_root: &std::path::Path,
    ref_sha: &str,
    steps: &[Step],
) -> Option<Vec<BaselineGateResult>> {
    // Create a temp dir for the worktree.
    let tmp_dir = std::env::temp_dir().join(format!("chump-baseline-{}", &ref_sha[..8]));
    // Clean up any stale worktree from a previous run.
    if tmp_dir.exists() {
        // Remove the worktree via git first.
        let _ = Command::new("git")
            .args(["worktree", "remove", "--force", &tmp_dir.to_string_lossy()])
            .current_dir(repo_root)
            .output();
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }
    // Add worktree at ref SHA (detached HEAD).
    let out = Command::new("git")
        .args([
            "worktree",
            "add",
            "--detach",
            &tmp_dir.to_string_lossy(),
            ref_sha,
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        let _ = Command::new("git")
            .args(["worktree", "remove", "--force", &tmp_dir.to_string_lossy()])
            .current_dir(repo_root)
            .output();
        return None;
    }

    let author = commit_author(repo_root, ref_sha);
    let mut results = Vec::with_capacity(steps.len());

    for s in steps {
        let started = Instant::now();
        // Run the step with cwd = the baseline worktree.
        let mut cmd = Command::new(&s.argv[0]);
        cmd.args(&s.argv[1..])
            .current_dir(&tmp_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let pass = cmd.output().map(|o| o.status.success()).unwrap_or(false);
        results.push(BaselineGateResult {
            name: s.name.to_string(),
            passed: pass,
            duration_ms: started.elapsed().as_millis(),
            originating_commit_sha: ref_sha[..std::cmp::min(12, ref_sha.len())].to_string(),
            originating_commit_author: author.clone(),
        });
    }

    // Clean up the worktree.
    let _ = Command::new("git")
        .args(["worktree", "remove", "--force", &tmp_dir.to_string_lossy()])
        .current_dir(repo_root)
        .output();

    Some(results)
}

/// Determine how many seconds old a baseline cache is.
fn baseline_age_secs(cache: &BaselineCache) -> u64 {
    let now = unix_now();
    now.saturating_sub(cache.generated_at_secs)
}

/// Result of the diff-scoped attribution pass.
// Reserved for the baseline-diff attribution pass; not constructed today.
// Flagged only once this module became its own crate (EFFECTIVE-400).
#[allow(dead_code)]
struct BaselineDiff {
    /// Gates that PASS on baseline but FAIL on HEAD — caused by the diff.
    new_failures: Vec<String>,
    /// Gates that FAIL on baseline AND FAIL on HEAD — not caused by the diff.
    preexisting_failures: Vec<BaselineGateResult>,
    /// SHA of the baseline ref used.
    baseline_sha: String,
    /// Age of the cache in seconds.
    baseline_age_secs: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    // INFRA-3352: test-pr-stuck-cluster-detection.sh existed since INFRA-1133
    // but was never in the discover_test_scripts allowlist, so a regression
    // in the detector's core cluster math (threshold/window/cooldown) could
    // ship without preflight or CI ever running it. Guard the wiring.
    #[test]
    fn infra3352_pr_stuck_cluster_detection_test_is_wired() {
        let repo_root = find_repo_root().expect("repo root");
        let scripts = discover_test_scripts(&repo_root);
        assert!(
            scripts
                .iter()
                .any(|p| p.ends_with("scripts/ci/test-pr-stuck-cluster-detection.sh")),
            "test-pr-stuck-cluster-detection.sh must be wired into preflight's \
             always-run allowlist so detector regressions surface locally"
        );
    }

    // RESILIENT-072: cargo-test-with-rerun.sh exits 2 with a `usage:` error
    // if invoked without `-- <cmd>`. Assert both nextest and cargo-test
    // fallback argvs carry the required separator + a real command after it.
    #[test]
    fn resilient072_cargo_test_wrapper_argv_has_separator_and_cmd() {
        for nextest_available in [true, false] {
            let argv = cargo_test_wrapper_argv(nextest_available);
            assert_eq!(
                argv[0], "bash",
                "wrapper must be invoked via bash, not exec'd directly"
            );
            assert!(
                argv[1].ends_with("cargo-test-with-rerun.sh"),
                "argv[1] must be the wrapper script"
            );
            let sep_pos = argv.iter().position(|a| *a == "--").unwrap_or_else(|| {
                panic!(
                    "cargo-test-with-rerun.sh requires a `--` separator; \
                     without it the wrapper prints usage and exits non-zero \
                     without running a single test (RESILIENT-072). argv={argv:?}"
                )
            });
            assert!(
                sep_pos + 1 < argv.len(),
                "`--` must be followed by a real command, not be the last arg"
            );
            assert_eq!(
                argv[sep_pos + 1],
                "cargo",
                "the wrapped command must be `cargo ...`"
            );
        }
    }

    // RESILIENT-196: disk-floor guard (pure comparison — no env/process races).
    #[test]
    fn resilient196_disk_floor_comparison() {
        assert!(
            disk_floor_breached(9.0, 15.0),
            "9 GB free < 15 GB floor → breach"
        );
        assert!(
            disk_floor_breached(2.1, 15.0),
            "the 2026-07-24 crash condition"
        );
        assert!(!disk_floor_breached(20.0, 15.0), "plenty of headroom → ok");
        assert!(
            !disk_floor_breached(15.0, 15.0),
            "exactly at floor → ok (not <)"
        );
        assert_eq!(
            DEFAULT_PREFLIGHT_DISK_FLOOR_GB, 15.0,
            "raised from disk_cmd's 5 GB inventory floor"
        );
    }

    #[test]
    fn parse_args_defaults() {
        let a = parse_args(&[]);
        assert!(!a.with_tests);
        assert!(!a.keep_going);
        assert!(!a.json);
        assert!(!a.help);
        assert_eq!(a.scope, ScopeArg::Auto);
        assert!(a.bad_scope.is_none());
        assert!(!a.full);
    }

    #[test]
    fn parse_args_full_flag() {
        let a = parse_args(&["--full".to_string()]);
        assert!(a.full);
    }

    // ── EFFECTIVE-318 ────────────────────────────────────────────────────────
    #[test]
    fn extract_ci_script_tokens_finds_dedupes_and_skips_comments() {
        let yml = "\
      - name: a\n\
        run: bash scripts/ci/test-alpha.sh\n\
      - name: b\n\
        run: CHUMP_X=1 bash scripts/ci/test-beta.sh && echo ok\n\
      - name: dup\n\
        run: bash scripts/ci/test-alpha.sh\n\
        # run: bash scripts/ci/test-commented-out.sh\n\
      - name: notsh\n\
        run: cat scripts/ci/env-vars-internal.txt\n";
        let got = extract_ci_script_tokens(yml);
        assert!(got.contains("scripts/ci/test-alpha.sh"));
        assert!(got.contains("scripts/ci/test-beta.sh"));
        // commented-out gate is not resurrected
        assert!(!got.contains("scripts/ci/test-commented-out.sh"));
        // non-.sh reference ignored
        assert!(!got.contains("scripts/ci/env-vars-internal.txt"));
        // dedup: alpha appears once
        assert_eq!(
            got.iter()
                .filter(|t| *t == "scripts/ci/test-alpha.sh")
                .count(),
            1
        );
    }

    fn _write_tmp_script(name: &str, body: &str) -> std::path::PathBuf {
        let p =
            std::env::temp_dir().join(format!("chump_pf_318_{}_{}.sh", std::process::id(), name));
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn is_local_safe_script_flags_network_markers() {
        let p = _write_tmp_script("net", "#!/bin/bash\nset -e\ngh api repos/x/y\n");
        assert!(!is_local_safe_script(&p), "gh api → not local-safe");
        let _ = std::fs::remove_file(&p);

        let p2 = _write_tmp_script("push", "#!/bin/bash\ngit push origin HEAD\n");
        assert!(!is_local_safe_script(&p2), "git push → not local-safe");
        let _ = std::fs::remove_file(&p2);
    }

    #[test]
    fn is_local_safe_script_passes_pure_local_and_ignores_comments() {
        let p = _write_tmp_script(
            "clean",
            "#!/bin/bash\n# this test does not call gh api at all\nsqlite3 :memory: 'select 1'\necho ok\n",
        );
        assert!(
            is_local_safe_script(&p),
            "pure-local script with marker only in a comment is safe"
        );
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn parse_args_flags() {
        let argv = vec![
            "--with-tests".to_string(),
            "--keep-going".to_string(),
            "--json".to_string(),
        ];
        let a = parse_args(&argv);
        assert!(a.with_tests);
        assert!(a.keep_going);
        assert!(a.json);
    }

    #[test]
    fn parse_args_help_short_and_long() {
        assert!(parse_args(&["-h".to_string()]).help);
        assert!(parse_args(&["--help".to_string()]).help);
    }

    #[test]
    fn parse_args_ignores_unknown() {
        let argv = vec!["--unknown".to_string(), "--with-tests".to_string()];
        let a = parse_args(&argv);
        assert!(a.with_tests);
    }

    #[test]
    fn parse_args_scope_separate() {
        let a = parse_args(&["--scope".to_string(), "rust".to_string()]);
        assert_eq!(a.scope, ScopeArg::Rust);
        assert!(a.bad_scope.is_none());
    }

    #[test]
    fn parse_args_scope_equals() {
        let a = parse_args(&["--scope=docs".to_string()]);
        assert_eq!(a.scope, ScopeArg::Docs);
    }

    #[test]
    fn parse_args_scope_all_variants() {
        for (lit, expected) in [
            ("auto", ScopeArg::Auto),
            ("all", ScopeArg::All),
            ("rust", ScopeArg::Rust),
            ("scripts", ScopeArg::Scripts),
            ("docs", ScopeArg::Docs),
        ] {
            let a = parse_args(&["--scope".to_string(), lit.to_string()]);
            assert_eq!(a.scope, expected, "scope literal {lit}");
        }
    }

    #[test]
    fn parse_args_scope_bad_value() {
        let a = parse_args(&["--scope".to_string(), "frontend".to_string()]);
        assert!(a.bad_scope.is_some());
    }

    #[test]
    fn parse_args_scope_missing_value() {
        let a = parse_args(&["--scope".to_string()]);
        assert!(a.bad_scope.is_some());
    }

    #[test]
    fn run_step_passes_on_true() {
        let s = step("true probe", &["true"], GateKind::Rust);
        let out = run_step(&s);
        assert_eq!(out.status, Status::Pass);
        assert!(out.captured.is_none());
    }

    #[test]
    fn run_step_fails_on_false() {
        let s = step("false probe", &["false"], GateKind::Rust);
        let out = run_step(&s);
        assert_eq!(out.status, Status::Fail);
        assert!(out.captured.is_some());
    }

    // META-208: "flake-ingest" arm runs in-process (no subprocess spawn) —
    // exercises run_step's dispatch, not just chump_atomic_claim directly.
    #[test]
    fn run_step_flake_ingest_imports_flaky_rows() {
        let dir = tempfile::tempdir().expect("tempdir");
        let input_path = dir.path().join("nextest-flaky.json");
        std::fs::write(
            &input_path,
            r#"[{"name": "tests::flaky_one", "outcome": "flaky"}]"#,
        )
        .unwrap();
        let s = step(
            "flake-ingest",
            &[
                "flake-ingest",
                input_path.to_str().unwrap(),
                dir.path().to_str().unwrap(),
            ],
            GateKind::AlwaysFast,
        );
        let out = run_step(&s);

        assert_eq!(out.status, Status::Pass);
        assert!(out.captured.unwrap().contains("1 flaky"));
    }

    // INFRA-2422: The old skip_via_env_returns_zero test is removed because
    // the env bypass is deleted. The --help path exits 0 regardless.
    #[test]
    fn help_exits_zero() {
        let code = run(&["--help".to_string()]);
        assert_eq!(code, 0, "--help must exit 0");
    }

    #[test]
    fn read_main_preflight_failing_gates_parses_red_state() {
        use std::io::Write;
        let dir = tempfile::tempdir().expect("tempdir");
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let state_path = chump_dir.join("main-preflight-state.json");
        let mut f = std::fs::File::create(&state_path).unwrap();
        write!(
            f,
            r#"{{"state":"RED","last_status":"red","failing_gates":["event-registry-audit","env-var-coverage"],"filed_gaps":["INFRA-9999"]}}"#
        )
        .unwrap();
        let gates = read_main_preflight_failing_gates(dir.path());
        assert_eq!(gates, vec!["event-registry-audit", "env-var-coverage"]);
    }

    #[test]
    fn read_main_preflight_failing_gates_green_returns_empty() {
        use std::io::Write;
        let dir = tempfile::tempdir().expect("tempdir");
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let state_path = chump_dir.join("main-preflight-state.json");
        let mut f = std::fs::File::create(&state_path).unwrap();
        write!(
            f,
            r#"{{"state":"GREEN","last_status":"green","failing_gates":[],"filed_gaps":[]}}"#
        )
        .unwrap();
        let gates = read_main_preflight_failing_gates(dir.path());
        assert!(gates.is_empty(), "GREEN state must return empty gates");
    }

    #[test]
    fn read_main_preflight_failing_gates_emdash_placeholder_ignored() {
        use std::io::Write;
        let dir = tempfile::tempdir().expect("tempdir");
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let state_path = chump_dir.join("main-preflight-state.json");
        let mut f = std::fs::File::create(&state_path).unwrap();
        // Watchdog uses "—" (em-dash) as a placeholder when gate name is unknown.
        write!(
            f,
            r#"{{"state":"RED","last_status":"red","failing_gates":["—"],"filed_gaps":["INFRA-9999"]}}"#
        )
        .unwrap();
        let gates = read_main_preflight_failing_gates(dir.path());
        assert!(gates.is_empty(), "em-dash placeholder must be ignored");
    }

    #[test]
    fn read_trunk_fix_gap_id_returns_last_filed_gap() {
        use std::io::Write;
        let dir = tempfile::tempdir().expect("tempdir");
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let state_path = chump_dir.join("main-preflight-state.json");
        let mut f = std::fs::File::create(&state_path).unwrap();
        write!(
            f,
            r#"{{"state":"RED","filed_gaps":["INFRA-1000","INFRA-2422"]}}"#
        )
        .unwrap();
        let gap_id = read_trunk_fix_gap_id(dir.path());
        assert_eq!(gap_id, "INFRA-2422");
    }

    // ── INFRA-1672: scope_from_paths matrix ────────────────────────────────

    #[test]
    fn scope_from_paths_docs_only() {
        let paths = vec![
            "docs/process/CLAUDE_GOTCHAS.md".to_string(),
            "README.md".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(!s.rust, "docs-only must skip rust");
        assert!(!s.scripts, "docs-only must skip scripts");
        assert!(s.docs, "docs-only must record docs");
    }

    #[test]
    fn scope_from_paths_rust_only() {
        let paths = vec![
            "src/preflight.rs".to_string(),
            "Cargo.toml".to_string(),
            "crates/chump-tool-macro/src/lib.rs".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(s.rust);
        assert!(!s.scripts);
        assert!(!s.docs);
    }

    #[test]
    fn scope_from_paths_scripts_only() {
        let paths = vec![
            "scripts/ci/test-foo.sh".to_string(),
            ".github/workflows/ci.yml".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(!s.rust);
        assert!(s.scripts);
        assert!(!s.docs);
    }

    #[test]
    fn scope_from_paths_mixed_rust_and_docs() {
        let paths = vec![
            "src/lib.rs".to_string(),
            "docs/process/CLAUDE_GOTCHAS.md".to_string(),
        ];
        let s = scope_from_paths(&paths);
        assert!(s.rust);
        assert!(!s.scripts);
        assert!(s.docs);
    }

    #[test]
    fn scope_from_paths_env_vars_internal_txt_triggers_rust_scope() {
        // INFRA-1787 AC#3: touching only the env-var allowlist (no .rs files)
        // must still trigger the rust-scope bucket so env-var-coverage runs.
        let paths = vec!["scripts/ci/env-vars-internal.txt".to_string()];
        let s = scope_from_paths(&paths);
        assert!(
            s.rust,
            "env-vars-internal.txt alone should trigger rust scope"
        );
        assert!(s.scripts);
    }

    #[test]
    fn scope_from_paths_unrecognized_falls_back_to_all() {
        // An exotic path we don't classify → conservative: run everything.
        let paths = vec!["weird/unknown-thing.xyz".to_string()];
        let s = scope_from_paths(&paths);
        assert!(s.rust && s.scripts && s.docs, "unknown path → all scope");
    }

    #[test]
    fn scope_from_paths_empty_means_all() {
        let s = scope_from_paths(&[]);
        assert!(s.rust && s.scripts && s.docs, "empty diff → all scope");
    }

    #[test]
    fn scope_includes_respects_always_fast() {
        let s = Scope::none();
        assert!(
            s.includes(GateKind::AlwaysFast),
            "AlwaysFast must run on any scope"
        );
        assert!(!s.includes(GateKind::Rust));
        assert!(!s.includes(GateKind::Scripts));
    }

    #[test]
    fn scope_label_human_readable() {
        assert_eq!(Scope::all().label(), "rust+scripts");
        assert_eq!(
            Scope {
                rust: false,
                scripts: false,
                docs: true,
            }
            .label(),
            "docs"
        );
        assert_eq!(Scope::none().label(), "none (always-fast only)");
    }

    // ── META-153: baseline cache + diff attribution tests ─────────────────

    #[test]
    fn parse_args_vs_flag_separate() {
        let argv = vec!["--vs".to_string(), "origin/main".to_string()];
        let a = parse_args(&argv);
        assert_eq!(a.vs_ref, Some("origin/main".to_string()));
    }

    #[test]
    fn parse_args_vs_flag_equals() {
        let argv = vec!["--vs=origin/main".to_string()];
        let a = parse_args(&argv);
        assert_eq!(a.vs_ref, Some("origin/main".to_string()));
    }

    #[test]
    fn parse_args_vs_absent_is_none() {
        let a = parse_args(&[]);
        assert!(a.vs_ref.is_none());
    }

    #[test]
    fn baseline_cache_parse_roundtrip() {
        // Write a synthetic cache and read it back.
        let tmp = std::env::temp_dir().join("chump-test-baseline-cache.json");
        let results = vec![
            BaselineGateResult {
                name: "gate-A".to_string(),
                passed: false,
                duration_ms: 42,
                originating_commit_sha: "abc123".to_string(),
                originating_commit_author: "alice".to_string(),
            },
            BaselineGateResult {
                name: "gate-B".to_string(),
                passed: true,
                duration_ms: 11,
                originating_commit_sha: "def456".to_string(),
                originating_commit_author: "bob".to_string(),
            },
        ];
        save_baseline_cache(&tmp, "deadbeefcafe", &results).expect("save should succeed");
        let loaded = load_baseline_cache(&tmp).expect("load should succeed");
        let _ = std::fs::remove_file(&tmp);

        assert_eq!(loaded.baseline_sha, "deadbeefcafe");
        assert_eq!(loaded.gate_results.len(), 2);
        assert_eq!(loaded.gate_results[0].name, "gate-A");
        assert!(!loaded.gate_results[0].passed);
        assert_eq!(loaded.gate_results[0].originating_commit_author, "alice");
        assert_eq!(loaded.gate_results[1].name, "gate-B");
        assert!(loaded.gate_results[1].passed);
    }

    #[test]
    fn baseline_diff_attribution() {
        // Synthetic scenario:
        //   gate-A: fails on baseline AND HEAD  → PRE-EXISTING
        //   gate-B: passes on baseline, fails on HEAD → NEW
        //   gate-C: passes both → no mention
        let cache = BaselineCache {
            baseline_sha: "abc".to_string(),
            generated_at_secs: unix_now(),
            gate_results: vec![
                BaselineGateResult {
                    name: "gate-A".to_string(),
                    passed: false,
                    duration_ms: 1,
                    originating_commit_sha: "aaa".to_string(),
                    originating_commit_author: "alice".to_string(),
                },
                BaselineGateResult {
                    name: "gate-B".to_string(),
                    passed: true,
                    duration_ms: 1,
                    originating_commit_sha: "bbb".to_string(),
                    originating_commit_author: "bob".to_string(),
                },
                BaselineGateResult {
                    name: "gate-C".to_string(),
                    passed: true,
                    duration_ms: 1,
                    originating_commit_sha: "ccc".to_string(),
                    originating_commit_author: "carol".to_string(),
                },
            ],
        };

        // HEAD outcomes: gate-A fails, gate-B fails, gate-C passes.
        let head_outcomes = vec![
            ("gate-A".to_string(), Status::Fail, 1u128),
            ("gate-B".to_string(), Status::Fail, 1u128),
            ("gate-C".to_string(), Status::Pass, 1u128),
        ];

        let mut new_failures: Vec<String> = vec![];
        let mut preexisting: Vec<BaselineGateResult> = vec![];
        for (name, status, _) in &head_outcomes {
            if *status != Status::Fail {
                continue;
            }
            let failed_on_baseline = cache
                .gate_results
                .iter()
                .any(|r| r.name == *name && !r.passed);
            if failed_on_baseline {
                if let Some(r) = cache.gate_results.iter().find(|r| r.name == *name) {
                    preexisting.push(r.clone());
                }
            } else {
                new_failures.push(name.clone());
            }
        }

        // AC #8 assertions:
        assert_eq!(
            new_failures,
            vec!["gate-B".to_string()],
            "gate-B must be NEW"
        );
        assert_eq!(preexisting.len(), 1, "gate-A must be PRE-EXISTING");
        assert_eq!(preexisting[0].name, "gate-A");
        // gate-C must not appear in either list.
        assert!(!new_failures.contains(&"gate-C".to_string()));
        assert!(!preexisting.iter().any(|r| r.name == "gate-C"));
    }

    #[test]
    fn baseline_age_secs_fresh() {
        let cache = BaselineCache {
            baseline_sha: "abc".to_string(),
            generated_at_secs: unix_now(),
            gate_results: vec![],
        };
        let age = baseline_age_secs(&cache);
        // Generated "now" → age should be <5s in any reasonable test run.
        assert!(age < 5, "fresh cache should have age < 5s, got {}", age);
    }

    #[test]
    fn baseline_age_secs_stale() {
        let cache = BaselineCache {
            baseline_sha: "abc".to_string(),
            // 2 hours ago
            generated_at_secs: unix_now().saturating_sub(7200),
            gate_results: vec![],
        };
        let age = baseline_age_secs(&cache);
        assert!(
            age >= 7200,
            "stale cache should report age >= 7200s, got {}",
            age
        );
        assert!(age > BASELINE_CACHE_TTL_SECS, "stale cache must exceed TTL");
    }

    #[test]
    fn extract_json_str_basic() {
        let json = r#"{"baseline_sha":"deadbeef","other":"val"}"#;
        assert_eq!(
            extract_json_str(json, "baseline_sha"),
            Some("deadbeef".to_string())
        );
        assert_eq!(extract_json_str(json, "other"), Some("val".to_string()));
        assert_eq!(extract_json_str(json, "missing"), None);
    }

    #[test]
    fn extract_json_u64_basic() {
        let json = r#"{"generated_at_secs":1234567,"other":99}"#;
        assert_eq!(
            extract_json_u64(json, "generated_at_secs"),
            Some(1234567u64)
        );
        assert_eq!(extract_json_u64(json, "other"), Some(99u64));
        assert_eq!(extract_json_u64(json, "missing"), None);
    }

    #[test]
    fn json_str_escaping() {
        assert_eq!(json_str("hello"), "\"hello\"");
        assert_eq!(json_str("say \"hi\""), "\"say \\\"hi\\\"\"");
        assert_eq!(json_str("back\\slash"), "\"back\\\\slash\"");
    }

    // ── EFFECTIVE-372: crate-scoped cargo check ─────────────────────────────

    /// Builds a tiny 2-crate workspace fixture on disk:
    ///   <root>/Cargo.toml            [package] name="root-pkg" + [workspace]
    ///   <root>/src/main.rs
    ///   <root>/crates/foo/Cargo.toml [package] name="chump-foo"
    ///   <root>/crates/foo/src/lib.rs
    ///   <root>/crates/bar/Cargo.toml [package] name="chump-bar"
    ///   <root>/crates/bar/src/lib.rs
    fn make_fixture_workspace() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();
        std::fs::write(
            root.join("Cargo.toml"),
            "[package]\nname = \"root-pkg\"\nversion = \"0.1.0\"\n\n[workspace]\nmembers = [\"crates/foo\", \"crates/bar\"]\n",
        )
        .unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();

        for (dir_name, pkg_name) in [("foo", "chump-foo"), ("bar", "chump-bar")] {
            let crate_dir = root.join("crates").join(dir_name);
            std::fs::create_dir_all(crate_dir.join("src")).unwrap();
            std::fs::write(
                crate_dir.join("Cargo.toml"),
                format!("[package]\nname = \"{pkg_name}\"\nversion = \"0.1.0\"\n"),
            )
            .unwrap();
            std::fs::write(crate_dir.join("src/lib.rs"), "").unwrap();
        }
        dir
    }

    #[test]
    fn toml_has_package_section_detects_package_table() {
        assert!(toml_has_package_section(
            "[package]\nname = \"x\"\n\n[workspace]\nmembers = []\n"
        ));
        assert!(!toml_has_package_section(
            "[workspace]\nmembers = [\"a\", \"b\"]\n"
        ));
    }

    #[test]
    fn package_name_from_cargo_toml_extracts_name() {
        let text = "[package]\nname = \"chump-foo\"\nversion = \"0.1.0\"\n";
        assert_eq!(
            package_name_from_cargo_toml(text),
            Some("chump-foo".to_string())
        );
        assert_eq!(package_name_from_cargo_toml("[workspace]\n"), None);
    }

    #[test]
    fn crate_root_for_file_finds_nested_crate_not_workspace_root() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let found = crate_root_for_file(root, "crates/foo/src/lib.rs").unwrap();
        assert_eq!(found, root.join("crates/foo"));
    }

    #[test]
    fn crate_root_for_file_falls_back_to_workspace_root_package() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let found = crate_root_for_file(root, "src/main.rs").unwrap();
        assert_eq!(found, root.to_path_buf());
    }

    #[test]
    fn changed_crate_names_scopes_to_single_touched_crate() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let paths = vec!["crates/foo/src/lib.rs".to_string()];
        let names = changed_crate_names(root, &paths).expect("should scope");
        assert_eq!(names, vec!["chump-foo".to_string()]);
    }

    #[test]
    fn changed_crate_names_covers_multiple_touched_crates() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let paths = vec![
            "crates/foo/src/lib.rs".to_string(),
            "crates/bar/src/lib.rs".to_string(),
        ];
        let names = changed_crate_names(root, &paths).expect("should scope");
        assert_eq!(
            names,
            vec!["chump-bar".to_string(), "chump-foo".to_string()]
        );
    }

    #[test]
    fn changed_crate_names_falls_back_on_root_cargo_toml_change() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let paths = vec![
            "crates/foo/src/lib.rs".to_string(),
            "Cargo.toml".to_string(),
        ];
        assert_eq!(
            changed_crate_names(root, &paths),
            None,
            "root Cargo.toml touching the member list must fall back to full workspace"
        );
    }

    #[test]
    fn changed_crate_names_falls_back_on_no_rust_paths() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let paths = vec!["docs/README.md".to_string()];
        assert_eq!(changed_crate_names(root, &paths), None);
    }

    #[test]
    fn compute_check_jobs_caps_at_six() {
        assert_eq!(compute_check_jobs(16, 0.0), 6);
        assert_eq!(compute_check_jobs(2, 0.0), 2);
        assert_eq!(compute_check_jobs(1, 0.0), 1);
    }

    #[test]
    fn compute_check_jobs_defers_to_one_under_load() {
        // Load average already exceeds available CPUs -> back off to 1 job
        // rather than compounding contention (load-aware-defer).
        assert_eq!(compute_check_jobs(8, 20.0), 1);
    }

    #[test]
    fn cargo_check_step_scopes_argv_to_changed_crate_not_workspace() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let paths = vec!["crates/foo/src/lib.rs".to_string()];
        let step = cargo_check_step(root, &paths);
        assert!(
            step.argv.iter().any(|a| a == "-p"),
            "scoped step must pass -p <crate>, argv={:?}",
            step.argv
        );
        assert!(
            step.argv.contains(&"chump-foo".to_string()),
            "scoped step must target the changed crate's package name, argv={:?}",
            step.argv
        );
        assert!(
            !step.argv.iter().any(|a| a == "--workspace"),
            "scoped step must NOT run the full workspace check, argv={:?}",
            step.argv
        );
    }

    #[test]
    fn cargo_check_step_falls_back_to_workspace_when_scoping_unsafe() {
        let fixture = make_fixture_workspace();
        let root = fixture.path();
        let paths = vec!["Cargo.lock".to_string()];
        let step = cargo_check_step(root, &paths);
        assert!(
            step.argv.iter().any(|a| a == "--workspace"),
            "unscoped fallback must run --workspace, argv={:?}",
            step.argv
        );
    }
}
