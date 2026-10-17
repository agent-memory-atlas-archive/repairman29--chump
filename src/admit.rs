//! `chump admit <claude|cargo> [--wait-s N]` — node-wide admission ceiling.
//!
//! INFRA-8219: Rust port of the RESILIENT-1604 admission gate that lived in
//! `scripts/coord/lib/admission-gate.sh`. Per the PHASE-R R6 architecture rule,
//! Rust owns the invariant (how many `claude -p` / cargo+rustc jobs may run on
//! this node at once) and the shell is reduced to a thin wrapper around this
//! verb.
//!
//! Problem it solves: multiple independent spawn sites (`chump dispatch`,
//! `worker.sh`, curator organs) each think they own the node and spawn work
//! with no shared view of what else is already running. On a 4-core node that
//! means 5-8 concurrent `claude -p` + up to 9 cargo jobs at load 12-18, which
//! budget-kills agents that have already finished their work (receipt: cuphead,
//! 2026-10-16).
//!
//! The gate is process-table-grounded: before admitting, count the live
//! processes on this node (`pgrep -fc`) and compare against the ceiling. The
//! CLI (`chump admit`) exits `0` when a slot is free and `75` (EX_TEMPFAIL)
//! when deferred, so a shell caller can back off. The in-process gate used by
//! [`crate::dispatch`] ([`gate_before_spawn`]) blocks (bounded) and then
//! fails open — a stuck gate is worse than a temporarily-busy node.
//!
//! Ceiling comes from (in precedence order): the process environment, then
//! `~/.chump/node.env`, then an `nproc`-derived default of `max(1, nproc/2)`.
//!
//! Test seams (so CI can prove deferral without real `claude`/`cargo` procs):
//!   * `CHUMP_ADMISSION_TEST_CLAUDE_COUNT` / `CHUMP_ADMISSION_TEST_CARGO_COUNT`
//!     — a fixed live-count override, bypassing `pgrep` entirely.
//!   * `CHUMP_ADMISSION_COUNT_PATTERN_CLAUDE` / `..._CARGO` — override the
//!     `pgrep -f` pattern so a test can count real fake processes (`sleep`).
//!
//! Emits `kind=admission_deferred` (registered in EVENT_REGISTRY.yaml).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// `EX_TEMPFAIL` from `<sysexits.h>` — "temporary failure, try again later".
/// The exit code `chump admit` returns when a slot could not be admitted.
pub const EX_DEFERRED: i32 = 75;

/// Usage error exit code, matching the convention used by `chump gap decompose`
/// et al. (bad input → 2).
const EX_USAGE: i32 = 2;

/// The two resources the node ceiling governs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Resource {
    /// Headless `claude -p` subprocesses.
    Claude,
    /// `cargo` / `rustc` build jobs.
    Cargo,
}

impl Resource {
    /// Parse the CLI positional (`claude` | `cargo`).
    pub fn parse(s: &str) -> Option<Resource> {
        match s {
            "claude" => Some(Resource::Claude),
            "cargo" => Some(Resource::Cargo),
            _ => None,
        }
    }

    /// Short label used in log lines and the ambient `resource` field.
    pub fn label(self) -> &'static str {
        match self {
            Resource::Claude => "claude",
            Resource::Cargo => "cargo",
        }
    }

    /// Env var (and `node.env` key) that configures this resource's ceiling.
    fn ceiling_env_key(self) -> &'static str {
        match self {
            Resource::Claude => "CHUMP_MAX_CONCURRENT_CLAUDE",
            Resource::Cargo => "CHUMP_MAX_CONCURRENT_CARGO_JOBS",
        }
    }

    /// Default `pgrep -f` pattern matching this resource's live processes.
    fn default_pattern(self) -> &'static str {
        match self {
            Resource::Claude => "claude -p",
            Resource::Cargo => "(^|/)(cargo|rustc)( |$)",
        }
    }

    /// Env var overriding [`default_pattern`](Self::default_pattern) (test seam).
    fn pattern_env_key(self) -> &'static str {
        match self {
            Resource::Claude => "CHUMP_ADMISSION_COUNT_PATTERN_CLAUDE",
            Resource::Cargo => "CHUMP_ADMISSION_COUNT_PATTERN_CARGO",
        }
    }

    /// Env var forcing a fixed live count, bypassing `pgrep` (test seam).
    fn test_count_env_key(self) -> &'static str {
        match self {
            Resource::Claude => "CHUMP_ADMISSION_TEST_CLAUDE_COUNT",
            Resource::Cargo => "CHUMP_ADMISSION_TEST_CARGO_COUNT",
        }
    }
}

/// The outcome of an admission attempt.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Decision {
    /// A slot was free on the first check — admitted immediately.
    Free { active: u32, ceiling: u32 },
    /// The ceiling was hit, but a slot freed up within the wait window.
    AdmittedAfterWait {
        active: u32,
        ceiling: u32,
        waited_s: u64,
    },
    /// The ceiling never cleared within the wait window — deferred.
    Deferred {
        active: u32,
        ceiling: u32,
        waited_s: u64,
    },
}

impl Decision {
    /// Whether a slot was ultimately granted (`true`) or the caller should back
    /// off (`false`).
    pub fn admitted(self) -> bool {
        !matches!(self, Decision::Deferred { .. })
    }

    /// CLI exit code: `0` admitted, [`EX_DEFERRED`] (75) deferred.
    pub fn exit_code(self) -> i32 {
        if self.admitted() {
            0
        } else {
            EX_DEFERRED
        }
    }
}

/// `max(1, cores / 2)` — the default ceiling for both resources. Split out as a
/// pure function so the arithmetic is unit-testable without probing the host.
fn ceiling_from_cores(cores: usize) -> u32 {
    let half = cores / 2;
    half.max(1) as u32
}

/// Online CPU count, mirroring `nproc` (falls back to 1 if unavailable).
fn nproc() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

/// The `nproc`-derived default ceiling for this host.
pub fn default_ceiling() -> u32 {
    ceiling_from_cores(nproc())
}

/// Precedence resolution for the ceiling, as a pure function: process env wins,
/// then `node.env`, then the `nproc`-derived default. A zero or unparseable
/// value is treated as absent.
fn resolve_ceiling(env_val: Option<u32>, file_val: Option<u32>, cores: usize) -> u32 {
    env_val
        .filter(|&n| n > 0)
        .or(file_val.filter(|&n| n > 0))
        .unwrap_or_else(|| ceiling_from_cores(cores))
}

/// Read a `KEY=value` / `export KEY=value` assignment from a sourced env file
/// such as `~/.chump/node.env`. Returns the last matching value parsed as
/// `u32`, or `None` if absent/unparseable. Inline `# comments` are stripped.
fn read_env_file_u32(path: &Path, key: &str) -> Option<u32> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut found = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let (k, v) = match line.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        if k.trim() != key {
            continue;
        }
        // Strip an inline comment and surrounding quotes/whitespace.
        let v = v.split('#').next().unwrap_or(v).trim();
        let v = v.trim_matches(|c| c == '"' || c == '\'');
        if let Ok(n) = v.trim().parse::<u32>() {
            found = Some(n);
        }
    }
    found
}

/// Resolve the ceiling for a resource, consulting (in order) the process
/// environment, `node_env`, and the `nproc`-derived default.
pub fn ceiling(resource: Resource, node_env: &Path) -> u32 {
    let key = resource.ceiling_env_key();
    let env_val = std::env::var(key).ok().and_then(|v| v.trim().parse().ok());
    let file_val = read_env_file_u32(node_env, key);
    resolve_ceiling(env_val, file_val, nproc())
}

/// Parse a `pgrep -c` style count (a bare integer on its own line); anything
/// non-numeric (including empty / "no matches") reads as 0.
fn parse_count(s: &str) -> u32 {
    s.lines()
        .next()
        .unwrap_or("")
        .trim()
        .parse::<u32>()
        .unwrap_or(0)
}

/// Count the live processes for a resource. Honors the test seams: a fixed
/// `CHUMP_ADMISSION_TEST_<R>_COUNT` short-circuits `pgrep` entirely, and
/// `CHUMP_ADMISSION_COUNT_PATTERN_<R>` overrides the match pattern.
pub fn count(resource: Resource) -> u32 {
    if let Ok(v) = std::env::var(resource.test_count_env_key()) {
        return parse_count(&v);
    }
    let pattern = std::env::var(resource.pattern_env_key())
        .unwrap_or_else(|_| resource.default_pattern().to_string());
    // `pgrep -fc <pattern>` prints the match count; exit 1 means "no matches"
    // (count 0), which we treat as a normal 0, not an error.
    match Command::new("pgrep").arg("-fc").arg(&pattern).output() {
        Ok(out) => parse_count(&String::from_utf8_lossy(&out.stdout)),
        Err(_) => 0,
    }
}

/// Default path to the node env file (`$CHUMP_STATE_DIR/node.env`, else
/// `$HOME/.chump/node.env`).
pub fn default_node_env() -> PathBuf {
    if let Ok(dir) = std::env::var("CHUMP_STATE_DIR") {
        let d = dir.trim();
        if !d.is_empty() {
            return PathBuf::from(d).join("node.env");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        let h = home.trim();
        if !h.is_empty() {
            return PathBuf::from(h).join(".chump").join("node.env");
        }
    }
    PathBuf::from(".chump/node.env")
}

/// Resolve the ambient log path, honoring the `CHUMP_AMBIENT_IN_PROMPT`
/// override (same convention as the other per-module emitters).
fn ambient_path(repo_root: &Path) -> PathBuf {
    if let Ok(path) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
        return PathBuf::from(path);
    }
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    lock_dir.join("ambient.jsonl")
}

/// Append one `kind=admission_deferred` line to `ambient.jsonl`.
fn emit_deferred(
    repo_root: &Path,
    resource: Resource,
    active: u32,
    ceiling: u32,
    waited_s: u64,
    outcome: &str,
) {
    let ambient = ambient_path(repo_root);
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    // scanner-anchor: "kind":"admission_deferred"
    let line = serde_json::json!({
        "ts": ts,
        "kind": "admission_deferred",
        "resource": resource.label(),
        "active": active,
        "ceiling": ceiling,
        "waited_s": waited_s,
        "outcome": outcome,
        "source": "chump-admit",
    })
    .to_string();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Core admission logic. Checks the live count against the ceiling; if the
/// ceiling is hit, emits `admission_deferred` and (when `wait_s > 0`) polls up
/// to `wait_s` seconds for a slot to free. Returns the [`Decision`].
///
/// `poll_s` is the inter-check interval (clamped to `[1, wait_s]` so a long
/// poll interval can't overshoot a short wait).
pub fn admit(
    resource: Resource,
    wait_s: u64,
    poll_s: u64,
    repo_root: &Path,
    node_env: &Path,
) -> Decision {
    let ceiling = ceiling(resource, node_env);
    let active = count(resource);
    if active < ceiling {
        return Decision::Free { active, ceiling };
    }

    // Ceiling hit — record the deferral the moment we detect it.
    emit_deferred(repo_root, resource, active, ceiling, 0, "deferred");

    if wait_s == 0 {
        return Decision::Deferred {
            active,
            ceiling,
            waited_s: 0,
        };
    }

    let poll = poll_s.clamp(1, wait_s);
    let mut waited = 0u64;
    let mut cur = active;
    while cur >= ceiling && waited < wait_s {
        std::thread::sleep(Duration::from_secs(poll));
        waited += poll;
        cur = count(resource);
    }

    if cur < ceiling {
        Decision::AdmittedAfterWait {
            active: cur,
            ceiling,
            waited_s: waited,
        }
    } else {
        emit_deferred(repo_root, resource, cur, ceiling, waited, "timeout");
        Decision::Deferred {
            active: cur,
            ceiling,
            waited_s: waited,
        }
    }
}

/// In-process gate used by [`crate::dispatch`] before spawning a `claude -p`
/// child. Performs a bounded wait (`CHUMP_ADMISSION_WAIT_TIMEOUT_S`, default
/// 300s; poll `CHUMP_ADMISSION_POLL_INTERVAL_S`, default 5s) and then **fails
/// open** — it never blocks the spawn indefinitely; a stuck gate is worse than
/// a temporarily-busy node. Set `CHUMP_ADMISSION_DISABLE=1` to bypass entirely.
pub fn gate_before_spawn(resource: Resource, repo_root: &Path) {
    if std::env::var("CHUMP_ADMISSION_DISABLE").as_deref() == Ok("1") {
        return;
    }
    let wait_s = std::env::var("CHUMP_ADMISSION_WAIT_TIMEOUT_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(300);
    let poll_s = std::env::var("CHUMP_ADMISSION_POLL_INTERVAL_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(5);
    let node_env = default_node_env();
    let decision = admit(resource, wait_s, poll_s, repo_root, &node_env);
    if let Decision::Deferred {
        active,
        ceiling,
        waited_s,
    } = decision
    {
        eprintln!(
            "[admission] {}: still {active} active >= ceiling {ceiling} after {waited_s}s — \
             admitting anyway (fail-open)",
            resource.label()
        );
    }
}

fn print_help() {
    println!("chump admit — node-wide admission ceiling (INFRA-8219)");
    println!();
    println!("Blocks new work from piling past the per-node concurrency ceiling for");
    println!("`claude -p` and cargo/rustc jobs. Ports the RESILIENT-1604 admission gate.");
    println!();
    println!("USAGE");
    println!("  chump admit <claude|cargo> [--wait-s N] [--json]");
    println!();
    println!("OPTIONS");
    println!("  --wait-s N    Wait up to N seconds for a slot to free (default 0 = check once)");
    println!("  --json        Emit the decision as a JSON object");
    println!("  -h, --help    Show this help");
    println!();
    println!("CEILING (precedence: env > ~/.chump/node.env > nproc default)");
    println!("  CHUMP_MAX_CONCURRENT_CLAUDE       default max(1, nproc/2)");
    println!("  CHUMP_MAX_CONCURRENT_CARGO_JOBS   default max(1, nproc/2)");
    println!();
    println!("EXIT CODES");
    println!("  0   a slot is free (admitted)");
    println!("  75  deferred — no slot within the wait window (EX_TEMPFAIL)");
    println!("  2   bad input — missing/unknown resource or flag");
}

/// CLI entry: `chump admit <claude|cargo> [--wait-s N] [--json]`.
/// `args` is everything after the `admit` verb.
pub fn run(args: &[String]) -> i32 {
    let mut resource: Option<Resource> = None;
    let mut wait_s: u64 = 0;
    let mut json = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                print_help();
                return 0;
            }
            "--json" => json = true,
            "--wait-s" => {
                i += 1;
                match args.get(i).and_then(|v| v.trim().parse::<u64>().ok()) {
                    Some(n) => wait_s = n,
                    None => {
                        eprintln!("chump admit: --wait-s requires a non-negative integer");
                        return EX_USAGE;
                    }
                }
            }
            other if other.starts_with("--wait-s=") => {
                let v = other.strip_prefix("--wait-s=").unwrap_or("");
                match v.trim().parse::<u64>() {
                    Ok(n) => wait_s = n,
                    Err(_) => {
                        eprintln!("chump admit: --wait-s requires a non-negative integer");
                        return EX_USAGE;
                    }
                }
            }
            other if resource.is_none() => match Resource::parse(other) {
                Some(r) => resource = Some(r),
                None => {
                    eprintln!("chump admit: unknown resource '{other}' (expected claude|cargo)");
                    return EX_USAGE;
                }
            },
            other => {
                eprintln!("chump admit: unexpected argument '{other}'");
                return EX_USAGE;
            }
        }
        i += 1;
    }

    let resource = match resource {
        Some(r) => r,
        None => {
            eprintln!("chump admit: missing resource (expected claude|cargo)");
            print_help();
            return EX_USAGE;
        }
    };

    let repo_root = crate::repo_path::repo_root();
    let node_env = default_node_env();
    let poll_s = std::env::var("CHUMP_ADMISSION_POLL_INTERVAL_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(5);

    let decision = admit(resource, wait_s, poll_s, &repo_root, &node_env);

    let (active, ceiling, waited, state) = match decision {
        Decision::Free { active, ceiling } => (active, ceiling, 0, "free"),
        Decision::AdmittedAfterWait {
            active,
            ceiling,
            waited_s,
        } => (active, ceiling, waited_s, "admitted_after_wait"),
        Decision::Deferred {
            active,
            ceiling,
            waited_s,
        } => (active, ceiling, waited_s, "deferred"),
    };

    if json {
        println!(
            "{}",
            serde_json::json!({
                "resource": resource.label(),
                "admitted": decision.admitted(),
                "state": state,
                "active": active,
                "ceiling": ceiling,
                "waited_s": waited,
            })
        );
    } else if decision.admitted() {
        println!(
            "admit {}: OK ({active}/{ceiling} active){}",
            resource.label(),
            if waited > 0 {
                format!(", waited {waited}s")
            } else {
                String::new()
            }
        );
    } else {
        println!(
            "admit {}: DEFERRED ({active}/{ceiling} active, waited {waited}s)",
            resource.label()
        );
    }

    decision.exit_code()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ceiling_from_cores_is_half_floor_min_one() {
        assert_eq!(ceiling_from_cores(0), 1);
        assert_eq!(ceiling_from_cores(1), 1);
        assert_eq!(ceiling_from_cores(2), 1);
        assert_eq!(ceiling_from_cores(3), 1);
        assert_eq!(ceiling_from_cores(4), 2);
        assert_eq!(ceiling_from_cores(8), 4);
        assert_eq!(ceiling_from_cores(16), 8);
    }

    #[test]
    fn default_ceiling_is_at_least_one() {
        assert!(default_ceiling() >= 1);
    }

    #[test]
    fn resolve_ceiling_env_wins_over_file_and_default() {
        assert_eq!(resolve_ceiling(Some(7), Some(3), 8), 7);
    }

    #[test]
    fn resolve_ceiling_file_wins_over_default_when_no_env() {
        assert_eq!(resolve_ceiling(None, Some(3), 8), 3);
    }

    #[test]
    fn resolve_ceiling_zero_is_treated_as_absent() {
        // env=0 falls through to file; file=0 falls through to nproc default.
        assert_eq!(resolve_ceiling(Some(0), Some(5), 8), 5);
        assert_eq!(resolve_ceiling(Some(0), Some(0), 8), ceiling_from_cores(8));
        assert_eq!(resolve_ceiling(None, None, 8), 4);
    }

    #[test]
    fn parse_count_tolerates_noise() {
        assert_eq!(parse_count("3\n"), 3);
        assert_eq!(parse_count("0"), 0);
        assert_eq!(parse_count(""), 0);
        assert_eq!(parse_count("not-a-number"), 0);
        assert_eq!(parse_count("5\n9\n"), 5);
    }

    #[test]
    fn read_env_file_u32_parses_assignments_last_wins() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("node.env");
        std::fs::write(
            &p,
            "# comment\n\
             export CHUMP_MAX_CONCURRENT_CLAUDE=3\n\
             CHUMP_MAX_CONCURRENT_CARGO_JOBS=2  # inline note\n\
             CHUMP_MAX_CONCURRENT_CLAUDE=6\n\
             CHUMP_OTHER=\"nope\"\n",
        )
        .unwrap();
        assert_eq!(
            read_env_file_u32(&p, "CHUMP_MAX_CONCURRENT_CLAUDE"),
            Some(6)
        );
        assert_eq!(
            read_env_file_u32(&p, "CHUMP_MAX_CONCURRENT_CARGO_JOBS"),
            Some(2)
        );
        assert_eq!(read_env_file_u32(&p, "CHUMP_NOT_PRESENT"), None);
    }

    #[test]
    fn read_env_file_u32_missing_file_is_none() {
        assert_eq!(
            read_env_file_u32(
                Path::new("/nonexistent/node.env"),
                "CHUMP_MAX_CONCURRENT_CLAUDE"
            ),
            None
        );
    }

    #[test]
    fn decision_exit_codes() {
        assert_eq!(
            Decision::Free {
                active: 0,
                ceiling: 2
            }
            .exit_code(),
            0
        );
        assert_eq!(
            Decision::AdmittedAfterWait {
                active: 1,
                ceiling: 2,
                waited_s: 5
            }
            .exit_code(),
            0
        );
        assert_eq!(
            Decision::Deferred {
                active: 4,
                ceiling: 2,
                waited_s: 10
            }
            .exit_code(),
            EX_DEFERRED
        );
    }

    #[test]
    fn resource_parse_and_labels() {
        assert_eq!(Resource::parse("claude"), Some(Resource::Claude));
        assert_eq!(Resource::parse("cargo"), Some(Resource::Cargo));
        assert_eq!(Resource::parse("nope"), None);
        assert_eq!(Resource::Claude.label(), "claude");
        assert_eq!(Resource::Cargo.label(), "cargo");
    }
}
