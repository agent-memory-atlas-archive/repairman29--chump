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
    // `pgrep -f <pattern>` prints one matching PID per line on both Linux and
    // macOS (BSD `pgrep` lacks `-c`). Exclude our own PID so `chump admit`
    // never counts itself.
    let self_pid = std::process::id();
    match Command::new("pgrep").arg("-f").arg(&pattern).output() {
        Ok(out) => String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.trim().parse::<u32>().ok())
            .filter(|&pid| pid != self_pid)
            .count() as u32,
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

/// Metadata persisted in each active slot lease file (`RESILIENT-1679`).
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SlotLeaseInfo {
    pub slot: u32,
    pub resource: String,
    pub pid: u32,
    pub holder: String,
    pub acquired_at: i64,
}

/// RAII handle for an acquired admission slot lease (`RESILIENT-1679`).
/// When `drop_on_exit` is `true` (in-process scoped callers and `--hold-ms`),
/// dropping the handle removes the slot file immediately. When `drop_on_exit`
/// is `false` (CLI `chump admit <resource>` handing a lease to its parent shell
/// PID), the slot file stays on disk bound to `info.pid` and is automatically
/// reaped once `pid_is_alive(info.pid)` returns `false` (or `chump admit release`
/// is called).
#[derive(Debug)]
pub struct AdmissionLease {
    pub info: SlotLeaseInfo,
    slot_path: PathBuf,
    drop_on_exit: bool,
}

impl AdmissionLease {
    pub fn slot_path(&self) -> &Path {
        &self.slot_path
    }
}

impl Drop for AdmissionLease {
    fn drop(&mut self) {
        if self.drop_on_exit {
            let _ = std::fs::remove_file(&self.slot_path);
        }
    }
}

/// Directory holding slot lease files and `.coord.lock` for `resource`.
pub fn slot_dir(resource: Resource, node_env: &Path) -> PathBuf {
    let base = node_env
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new(".chump"));
    base.join("admit-slots").join(resource.label())
}

/// Check whether a process ID is currently alive on this host (`kill(pid, 0)`).
pub fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    // SAFETY: kill(pid, 0) sends no signal; it only probes process existence.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Resolve the default lease owner PID for CLI calls: `CHUMP_ADMIT_OWNER_PID`
/// if set, otherwise parent process ID (`getppid()`) so a shell invoking
/// `chump admit claude` owns the lease for the lifetime of that shell.
pub fn default_owner_pid() -> u32 {
    if let Ok(v) = std::env::var("CHUMP_ADMIT_OWNER_PID") {
        if let Ok(pid) = v.trim().parse::<u32>() {
            if pid > 0 {
                return pid;
            }
        }
    }
    // SAFETY: getppid() is always safe and returns the parent PID.
    let ppid = unsafe { libc::getppid() };
    if ppid > 1 {
        ppid as u32
    } else {
        std::process::id()
    }
}

/// Run `f` while holding an exclusive `flock(LOCK_EX)` on `<dir>/.coord.lock`.
fn with_coord_lock<T>(dir: &Path, f: impl FnOnce() -> T) -> T {
    let _ = std::fs::create_dir_all(dir);
    let lock_path = dir.join(".coord.lock");
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .ok();
    if let Some(ref file) = lock_file {
        use std::os::unix::io::AsRawFd as _;
        // SAFETY: file.as_raw_fd() is a valid open descriptor for the duration of this scope.
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_EX);
        }
    }
    let out = f();
    if let Some(ref file) = lock_file {
        use std::os::unix::io::AsRawFd as _;
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
    }
    out
}

/// Read all live leases in `dir`, reaping any lease file whose `pid` is dead.
/// Caller must hold `with_coord_lock(dir)`.
fn reap_and_read_leases_locked(dir: &Path) -> Vec<(PathBuf, SlotLeaseInfo)> {
    let mut live = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return live;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.starts_with("lease-") || !name.ends_with(".json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&path) else {
            let _ = std::fs::remove_file(&path);
            continue;
        };
        let Ok(info) = serde_json::from_str::<SlotLeaseInfo>(&body) else {
            let _ = std::fs::remove_file(&path);
            continue;
        };
        if !pid_is_alive(info.pid) {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        live.push((path, info));
    }
    live.sort_by(|a, b| {
        a.1.slot
            .cmp(&b.1.slot)
            .then_with(|| a.1.acquired_at.cmp(&b.1.acquired_at))
            .then_with(|| a.1.holder.cmp(&b.1.holder))
    });
    live
}

/// Return all currently active (live-PID) slot leases for `resource`, reaping
/// any dead-PID lease files on the way (`RESILIENT-1679` AC3).
pub fn active_leases(resource: Resource, node_env: &Path) -> Vec<SlotLeaseInfo> {
    let dir = slot_dir(resource, node_env);
    with_coord_lock(&dir, || {
        reap_and_read_leases_locked(&dir)
            .into_iter()
            .map(|(_, info)| info)
            .collect()
    })
}

/// Release a lease held by `holder` for `resource` (returns `true` if removed).
pub fn release_lease(resource: Resource, node_env: &Path, holder: &str) -> bool {
    let dir = slot_dir(resource, node_env);
    with_coord_lock(&dir, || {
        let path = dir.join(format!("lease-{holder}.json"));
        std::fs::remove_file(&path).is_ok()
    })
}

/// Attempt to acquire a slot lease atomically under `.coord.lock`.
/// Returns `Ok((AdmissionLease, active_before))` when a slot is available, or
/// `Err(active_now)` when at/above `ceiling`.
pub fn try_acquire_slot(
    resource: Resource,
    ceiling: u32,
    node_env: &Path,
    owner_pid: u32,
    holder: &str,
    drop_on_exit: bool,
) -> Result<(AdmissionLease, u32), u32> {
    let dir = slot_dir(resource, node_env);
    with_coord_lock(&dir, || {
        let live = reap_and_read_leases_locked(&dir);
        let other_leases: Vec<&SlotLeaseInfo> = live
            .iter()
            .filter(|(_, info)| info.holder != holder)
            .map(|(_, info)| info)
            .collect();
        let leased_other = other_leases.len() as u32;
        let proc_count = count(resource);
        let active = leased_other.max(proc_count);
        if active >= ceiling {
            return Err(active);
        }

        let mut chosen_slot = 0u32;
        while chosen_slot < ceiling {
            if !other_leases.iter().any(|l| l.slot == chosen_slot) {
                break;
            }
            chosen_slot += 1;
        }

        let info = SlotLeaseInfo {
            slot: chosen_slot,
            resource: resource.label().to_string(),
            pid: owner_pid,
            holder: holder.to_string(),
            acquired_at: chrono::Utc::now().timestamp(),
        };
        let slot_path = dir.join(format!("lease-{holder}.json"));
        if let Ok(json) = serde_json::to_string(&info) {
            let _ = std::fs::write(&slot_path, json);
        }
        Ok((
            AdmissionLease {
                info,
                slot_path,
                drop_on_exit,
            },
            active,
        ))
    })
}

/// Acquire a slot lease with millisecond polling (used by concurrent callers
/// and tests). Returns `(Decision, Option<AdmissionLease>)`.
#[allow(clippy::too_many_arguments)]
pub fn admit_with_lease_ms(
    resource: Resource,
    ceiling: u32,
    wait_ms: u64,
    poll_ms: u64,
    repo_root: &Path,
    node_env: &Path,
    owner_pid: u32,
    holder: &str,
    drop_on_exit: bool,
) -> (Decision, Option<AdmissionLease>) {
    match try_acquire_slot(resource, ceiling, node_env, owner_pid, holder, drop_on_exit) {
        Ok((lease, active)) => return (Decision::Free { active, ceiling }, Some(lease)),
        Err(active) => {
            emit_deferred(repo_root, resource, active, ceiling, 0, "deferred");
            if wait_ms == 0 {
                return (
                    Decision::Deferred {
                        active,
                        ceiling,
                        waited_s: 0,
                    },
                    None,
                );
            }
        }
    }

    let step_ms = poll_ms.clamp(1, wait_ms);
    let mut waited_ms = 0u64;
    let mut last_active = ceiling;
    while waited_ms < wait_ms {
        std::thread::sleep(Duration::from_millis(step_ms));
        waited_ms += step_ms;
        match try_acquire_slot(resource, ceiling, node_env, owner_pid, holder, drop_on_exit) {
            Ok((lease, active)) => {
                let waited_s = waited_ms.div_ceil(1000);
                return (
                    Decision::AdmittedAfterWait {
                        active,
                        ceiling,
                        waited_s,
                    },
                    Some(lease),
                );
            }
            Err(active) => {
                last_active = active;
            }
        }
    }

    let waited_s = waited_ms / 1000;
    emit_deferred(
        repo_root,
        resource,
        last_active,
        ceiling,
        waited_s,
        "timeout",
    );
    (
        Decision::Deferred {
            active: last_active,
            ceiling,
            waited_s,
        },
        None,
    )
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
    let owner_pid = default_owner_pid();
    let holder = format!("pid-{owner_pid}");
    let ceil = ceiling(resource, node_env);
    let poll_ms = poll_s.saturating_mul(1000).max(1);
    let (decision, _lease) = admit_with_lease_ms(
        resource,
        ceil,
        wait_s.saturating_mul(1000),
        poll_ms,
        repo_root,
        node_env,
        owner_pid,
        &holder,
        false,
    );
    decision
}

/// In-process gate used by [`crate::dispatch`] before spawning a `claude -p`
/// child. Acquires a slot lease bound to this process's PID (`std::process::id()`),
/// performing a bounded wait (`CHUMP_ADMISSION_WAIT_TIMEOUT_S`, default 300s;
/// poll `CHUMP_ADMISSION_POLL_INTERVAL_S`, default 5s) and then **failing open**.
/// Set `CHUMP_ADMISSION_DISABLE=1` to bypass entirely.
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
    let ceil = ceiling(resource, &node_env);
    let pid = std::process::id();
    let holder = format!("pid-{pid}");
    let (decision, _lease) = admit_with_lease_ms(
        resource,
        ceil,
        wait_s.saturating_mul(1000),
        poll_s.saturating_mul(1000).max(1),
        repo_root,
        &node_env,
        pid,
        &holder,
        false,
    );
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

/// RESILIENT-1640: Cargo admission gate for the `chump dispatch` ship phase.
///
/// Unlike [`gate_before_spawn`] (which fails open after its wait timeout),
/// the ship phase must **not** fail open into a contended build: if the cargo
/// ceiling is hit, it emits `kind=admission_deferred` **once** and waits bounded
/// by the step budget (`step_budget_s`, or `CHUMP_ADMISSION_WAIT_TIMEOUT_S` when
/// smaller). If the ceiling does not free within the bounded wait, returns `Err`
/// rather than launching another concurrent cargo build.
pub fn gate_cargo_before_ship(repo_root: &Path, step_budget_s: u64) -> Result<Decision, String> {
    if std::env::var("CHUMP_ADMISSION_DISABLE").as_deref() == Ok("1") {
        return Ok(Decision::Free {
            active: 0,
            ceiling: u32::MAX,
        });
    }
    let env_wait_s = std::env::var("CHUMP_ADMISSION_WAIT_TIMEOUT_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok());
    let wait_s = match (env_wait_s, step_budget_s) {
        (Some(w), b) if b > 0 => w.min(b),
        (Some(w), _) => w,
        (None, b) if b > 0 => b,
        (None, _) => 300,
    };
    let poll_s = std::env::var("CHUMP_ADMISSION_POLL_INTERVAL_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(5);
    let node_env = default_node_env();
    gate_cargo_before_ship_with(
        repo_root,
        &node_env,
        wait_s.saturating_mul(1000),
        poll_s.saturating_mul(1000).max(1),
    )
}

/// Testable core for [`gate_cargo_before_ship`] with explicit `node_env` and
/// millisecond wait/poll intervals. Emits `kind=admission_deferred` at most once
/// on contention and returns `Err` when still contended after `wait_ms`.
pub fn gate_cargo_before_ship_with(
    repo_root: &Path,
    node_env: &Path,
    wait_ms: u64,
    poll_ms: u64,
) -> Result<Decision, String> {
    let ceil = ceiling(Resource::Cargo, node_env);
    let pid = std::process::id();
    let holder = format!("pid-{pid}-ship-gate");
    match try_acquire_slot(Resource::Cargo, ceil, node_env, pid, &holder, true) {
        Ok((_lease, active)) => {
            eprintln!("[admission] cargo (ship): admitted ({active}/{ceil})");
            return Ok(Decision::Free {
                active,
                ceiling: ceil,
            });
        }
        Err(active) => {
            emit_deferred(repo_root, Resource::Cargo, active, ceil, 0, "deferred");
            if wait_ms == 0 {
                return Err(format!(
                    "[admission] cargo (ship): {active} active >= ceiling {ceil} (wait_ms=0) — refusing to fail open into contended build"
                ));
            }
        }
    }

    let step_ms = poll_ms.clamp(1, wait_ms);
    let mut waited_ms = 0u64;
    let mut last_active = ceil;
    while waited_ms < wait_ms {
        std::thread::sleep(Duration::from_millis(step_ms));
        waited_ms += step_ms;
        match try_acquire_slot(Resource::Cargo, ceil, node_env, pid, &holder, true) {
            Ok((_lease, active)) => {
                let waited_s = waited_ms.div_ceil(1000);
                eprintln!(
                    "[admission] cargo (ship): admitted after {waited_s}s wait ({active}/{ceil})"
                );
                return Ok(Decision::AdmittedAfterWait {
                    active,
                    ceiling: ceil,
                    waited_s,
                });
            }
            Err(active) => {
                last_active = active;
            }
        }
    }

    let waited_s = waited_ms / 1000;
    Err(format!(
        "[admission] cargo (ship): still {last_active} active >= ceiling {ceil} after {waited_s}s — refusing to fail open into contended build"
    ))
}

fn print_help() {
    println!(
        "chump admit — node-wide admission ceiling & lease gate (INFRA-8219 / RESILIENT-1679)"
    );
    println!();
    println!("Hands out a PID-bound slot lease up to the per-node concurrency ceiling for");
    println!("`claude -p` and cargo/rustc jobs, and inspects or releases active leases.");
    println!();
    println!("USAGE");
    println!("  chump admit <claude|cargo> [--wait-s N] [--owner-pid PID] [--hold-ms MS] [--json]");
    println!("  chump admit status [--json]");
    println!("  chump admit release <claude|cargo> [--owner-pid PID]");
    println!();
    println!("OPTIONS");
    println!("  --wait-s N       Wait up to N seconds for a slot to free (default 0 = check once)");
    println!(
        "  --owner-pid PID  Bind the lease to PID (default: CHUMP_ADMIT_OWNER_PID or parent PID)"
    );
    println!("  --hold-ms MS     Hold the lease for MS milliseconds in this process, then release");
    println!("  --json           Emit the decision or status as a JSON object");
    println!("  -h, --help       Show this help");
    println!();
    println!("CEILING (precedence: env > ~/.chump/node.env > nproc default)");
    println!("  CHUMP_MAX_CONCURRENT_CLAUDE       default max(1, nproc/2)");
    println!("  CHUMP_MAX_CONCURRENT_CARGO_JOBS   default max(1, nproc/2)");
    println!();
    println!("EXIT CODES");
    println!("  0   a slot lease was granted (admitted)");
    println!("  75  deferred — no slot within the wait window (EX_TEMPFAIL)");
    println!("  2   bad input — missing/unknown resource or flag");
}

fn run_status(args: &[String]) -> i32 {
    let mut json = false;
    for arg in args {
        match arg.as_str() {
            "--json" => json = true,
            "-h" | "--help" => {
                print_help();
                return 0;
            }
            other => {
                eprintln!("chump admit status: unexpected argument '{other}'");
                return EX_USAGE;
            }
        }
    }
    let node_env = default_node_env();
    let claude_ceil = ceiling(Resource::Claude, &node_env);
    let claude_leases = active_leases(Resource::Claude, &node_env);
    let claude_active = (claude_leases.len() as u32).max(count(Resource::Claude));

    let cargo_ceil = ceiling(Resource::Cargo, &node_env);
    let cargo_leases = active_leases(Resource::Cargo, &node_env);
    let cargo_active = (cargo_leases.len() as u32).max(count(Resource::Cargo));

    if json {
        let out = serde_json::json!({
            "claude": {
                "ceiling": claude_ceil,
                "active": claude_active,
                "leased": claude_leases.len(),
                "leases": claude_leases,
            },
            "cargo": {
                "ceiling": cargo_ceil,
                "active": cargo_active,
                "leased": cargo_leases.len(),
                "leases": cargo_leases,
            }
        });
        println!("{out}");
    } else {
        println!(
            "admit status: claude {claude_active}/{claude_ceil} active ({} lease(s)), cargo {cargo_active}/{cargo_ceil} active ({} lease(s))",
            claude_leases.len(),
            cargo_leases.len()
        );
        for l in &claude_leases {
            println!(
                "  claude slot {}: holder={} pid={} acquired_at={}",
                l.slot, l.holder, l.pid, l.acquired_at
            );
        }
        for l in &cargo_leases {
            println!(
                "  cargo slot {}: holder={} pid={} acquired_at={}",
                l.slot, l.holder, l.pid, l.acquired_at
            );
        }
    }
    0
}

fn run_release(args: &[String]) -> i32 {
    let mut resource: Option<Resource> = None;
    let mut owner_pid: Option<u32> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--owner-pid" => {
                i += 1;
                match args.get(i).and_then(|v| v.trim().parse::<u32>().ok()) {
                    Some(p) if p > 0 => owner_pid = Some(p),
                    _ => {
                        eprintln!("chump admit release: --owner-pid requires a positive integer");
                        return EX_USAGE;
                    }
                }
            }
            other if !other.starts_with('-') && resource.is_none() => {
                resource = Resource::parse(other);
                if resource.is_none() {
                    eprintln!(
                        "chump admit release: unknown resource '{other}' (expected claude|cargo)"
                    );
                    return EX_USAGE;
                }
            }
            other => {
                eprintln!("chump admit release: unexpected argument '{other}'");
                return EX_USAGE;
            }
        }
        i += 1;
    }
    let Some(res) = resource else {
        eprintln!("chump admit release: missing resource (expected claude|cargo)");
        return EX_USAGE;
    };
    let pid = owner_pid.unwrap_or_else(default_owner_pid);
    let holder = format!("pid-{pid}");
    let node_env = default_node_env();
    let _ = release_lease(res, &node_env, &holder);
    0
}

/// CLI entry: `chump admit <claude|cargo|status|release> ...`.
/// `args` is everything after the `admit` verb.
pub fn run(args: &[String]) -> i32 {
    if args.first().map(|s| s.as_str()) == Some("status") {
        return run_status(&args[1..]);
    }
    if args.first().map(|s| s.as_str()) == Some("release") {
        return run_release(&args[1..]);
    }

    let mut resource: Option<Resource> = None;
    let mut wait_s: u64 = 0;
    let mut owner_pid_arg: Option<u32> = None;
    let mut hold_ms: Option<u64> = None;
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
            "--owner-pid" => {
                i += 1;
                match args.get(i).and_then(|v| v.trim().parse::<u32>().ok()) {
                    Some(p) if p > 0 => owner_pid_arg = Some(p),
                    _ => {
                        eprintln!("chump admit: --owner-pid requires a positive integer");
                        return EX_USAGE;
                    }
                }
            }
            "--hold-ms" => {
                i += 1;
                match args.get(i).and_then(|v| v.trim().parse::<u64>().ok()) {
                    Some(ms) => hold_ms = Some(ms),
                    None => {
                        eprintln!("chump admit: --hold-ms requires a non-negative integer");
                        return EX_USAGE;
                    }
                }
            }
            other if !other.starts_with('-') && resource.is_none() => {
                match Resource::parse(other) {
                    Some(r) => resource = Some(r),
                    None => {
                        eprintln!("chump admit: unknown resource '{other}' (expected claude|cargo|status|release)");
                        return EX_USAGE;
                    }
                }
            }
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
            eprintln!("chump admit: missing resource (expected claude|cargo|status|release)");
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

    let owner_pid = owner_pid_arg.unwrap_or_else(|| {
        if hold_ms.is_some() {
            std::process::id()
        } else {
            default_owner_pid()
        }
    });
    let holder = format!("pid-{owner_pid}");
    let ceil = ceiling(resource, &node_env);
    let drop_on_exit = hold_ms.is_some();
    let poll_ms = if hold_ms.is_some() {
        50
    } else {
        poll_s.saturating_mul(1000).max(1)
    };
    let (decision, lease) = admit_with_lease_ms(
        resource,
        ceil,
        wait_s.saturating_mul(1000),
        poll_ms,
        &repo_root,
        &node_env,
        owner_pid,
        &holder,
        drop_on_exit,
    );

    let (active, ceiling_val, waited, state) = match decision {
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

    let slot_num = lease.as_ref().map(|l| l.info.slot);

    if json {
        println!(
            "{}",
            serde_json::json!({
                "resource": resource.label(),
                "admitted": decision.admitted(),
                "state": state,
                "active": active,
                "ceiling": ceiling_val,
                "waited_s": waited,
                "slot": slot_num,
                "pid": owner_pid,
            })
        );
    } else if decision.admitted() {
        println!(
            "admit {}: OK ({active}/{ceiling_val} active, slot={} pid={owner_pid}){}",
            resource.label(),
            slot_num.unwrap_or(0),
            if waited > 0 {
                format!(", waited {waited}s")
            } else {
                String::new()
            }
        );
    } else {
        println!(
            "admit {}: DEFERRED ({active}/{ceiling_val} active, waited {waited}s)",
            resource.label()
        );
    }

    if let (Some(_held), Some(ms)) = (&lease, hold_ms) {
        std::thread::sleep(Duration::from_millis(ms));
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

    #[test]
    fn resilient1679_five_concurrent_callers_against_ceiling_two_never_exceed_two() {
        use std::sync::atomic::{AtomicU32, Ordering};
        use std::sync::{Arc, Barrier};

        let dir = tempfile::tempdir().unwrap();
        let node_env = dir.path().join("node.env");
        std::fs::write(&node_env, "CHUMP_MAX_CONCURRENT_CLAUDE=2\n").unwrap();
        let repo_root = dir.path().to_path_buf();

        let barrier = Arc::new(Barrier::new(5));
        let in_flight = Arc::new(AtomicU32::new(0));
        let max_seen = Arc::new(AtomicU32::new(0));
        let admitted_total = Arc::new(AtomicU32::new(0));

        let mut handles = Vec::new();
        for idx in 0..5 {
            let b = Arc::clone(&barrier);
            let cur = Arc::clone(&in_flight);
            let peak = Arc::clone(&max_seen);
            let total = Arc::clone(&admitted_total);
            let env_path = node_env.clone();
            let root_path = repo_root.clone();
            handles.push(std::thread::spawn(move || {
                b.wait();
                let holder = format!("caller-{idx}");
                let (decision, lease) = admit_with_lease_ms(
                    Resource::Claude,
                    2,
                    2000,
                    15,
                    &root_path,
                    &env_path,
                    std::process::id(),
                    &holder,
                    true,
                );
                assert!(
                    decision.admitted(),
                    "caller-{idx} should be admitted within wait window"
                );
                let _lease = lease.expect("admitted caller must receive an AdmissionLease");
                let now_holding = cur.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(now_holding, Ordering::SeqCst);
                total.fetch_add(1, Ordering::SeqCst);
                // Hold the slot long enough that all 5 concurrent callers overlap
                std::thread::sleep(Duration::from_millis(80));
                cur.fetch_sub(1, Ordering::SeqCst);
            }));
        }

        for h in handles {
            h.join().unwrap();
        }

        assert_eq!(
            admitted_total.load(Ordering::SeqCst),
            5,
            "all 5 callers must complete"
        );
        assert_eq!(
            max_seen.load(Ordering::SeqCst),
            2,
            "at most C=2 callers may hold a slot concurrently (got {})",
            max_seen.load(Ordering::SeqCst)
        );
        // After all leases drop, active_leases must be empty.
        assert!(active_leases(Resource::Claude, &node_env).is_empty());
    }

    #[test]
    fn resilient1679_dead_pid_lease_is_reaped_and_status_lists_live_leases() {
        let dir = tempfile::tempdir().unwrap();
        let node_env = dir.path().join("node.env");
        std::fs::write(&node_env, "CHUMP_MAX_CONCURRENT_CLAUDE=2\n").unwrap();

        // Acquire one live lease bound to our own PID, and one bound to a dead PID (999_999_991).
        let (_live_lease, _) = try_acquire_slot(
            Resource::Claude,
            2,
            &node_env,
            std::process::id(),
            "live-holder",
            false,
        )
        .expect("live slot should acquire");

        let sdir = slot_dir(Resource::Claude, &node_env);
        let dead_info = SlotLeaseInfo {
            slot: 1,
            resource: "claude".to_string(),
            pid: 999_999_991,
            holder: "dead-holder".to_string(),
            acquired_at: 100,
        };
        std::fs::write(
            sdir.join("lease-dead-holder.json"),
            serde_json::to_string(&dead_info).unwrap(),
        )
        .unwrap();

        let leases = active_leases(Resource::Claude, &node_env);
        assert_eq!(
            leases.len(),
            1,
            "dead PID lease must be reaped automatically"
        );
        assert_eq!(leases[0].holder, "live-holder");
        assert_eq!(leases[0].pid, std::process::id());

        assert!(release_lease(Resource::Claude, &node_env, "live-holder"));
        assert!(active_leases(Resource::Claude, &node_env).is_empty());
    }

    #[test]
    fn resilient1640_gate_cargo_before_ship_emits_deferred_once_and_does_not_fail_open() {
        let dir = tempfile::tempdir().unwrap();
        let node_env = dir.path().join("node.env");
        std::fs::write(&node_env, "CHUMP_MAX_CONCURRENT_CARGO_JOBS=1\n").unwrap();

        // Hold the sole cargo slot so the ship gate sees contention.
        let (held_lease, _) = try_acquire_slot(
            Resource::Cargo,
            1,
            &node_env,
            std::process::id(),
            "contending-cargo",
            false,
        )
        .expect("initial cargo slot should acquire");

        // 1. Contended across entire wait budget: must NOT fail open (returns Err)
        //    and must emit kind=admission_deferred exactly once.
        let res = gate_cargo_before_ship_with(dir.path(), &node_env, 120, 40);
        let err = res.expect_err("contended cargo ship gate must not fail open");
        assert!(
            err.contains("refusing to fail open"),
            "unexpected error: {err}"
        );
        let ambient = dir.path().join(".chump-locks/ambient.jsonl");
        let body = std::fs::read_to_string(&ambient).expect("ambient.jsonl written");
        let deferred_lines: Vec<&str> = body
            .lines()
            .filter(|l| l.contains("\"kind\":\"admission_deferred\""))
            .collect();
        assert_eq!(
            deferred_lines.len(),
            1,
            "must emit admission_deferred exactly once on contention, got: {body}"
        );

        // 2. When the contending lease frees mid-wait, the gate admits after wait.
        let node_env_cl = node_env.clone();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(60));
            drop(held_lease);
            release_lease(Resource::Cargo, &node_env_cl, "contending-cargo");
        });
        let admitted = gate_cargo_before_ship_with(dir.path(), &node_env, 500, 25)
            .expect("ship gate should admit once slot frees");
        releaser.join().unwrap();
        assert!(
            matches!(admitted, Decision::AdmittedAfterWait { ceiling: 1, .. }),
            "expected AdmittedAfterWait, got {admitted:?}"
        );
    }
}
