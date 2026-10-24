//! `chumpd worker` — per-worker loop control (PHASE-R R6, INFRA-8575; slice of
//! the INFRA-8195 umbrella).
//!
//! The outer loop *control* that used to live at the top level of
//! `scripts/dispatch/worker.sh` moves here: the tick cadence, the per-tick
//! heartbeat write, the `.chump/fleet-paused` sentinel gate, and a per-tick
//! wall-clock budget. Each tick still execs the existing shell *tick body*
//! (`worker.sh` in single-tick mode), so the per-cycle work is byte-identical
//! — only the control scaffolding moved into Rust. `worker.sh` keeps its file
//! name and becomes a thin shim that `exec`s `chumpd worker`, so every
//! installer and unit that references the path keeps working.
//!
//! Shim-first discipline: this slice owns the *loop control only*. Carving the
//! shell body's own internal `sleep; continue` cadence out (so Rust is the sole
//! cadence owner) is a later slice — until then `chumpd worker` defaults to a
//! zero inter-tick sleep when driving `worker.sh`, letting the shell body's own
//! sleeps govern idle backoff, which keeps today's behavior byte-identical.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 0 = running; nonzero = the raw signal that requested shutdown. Separate from
/// the supervisor's `SHUTDOWN_SIGNAL` so the two code paths never alias.
static WORKER_SHUTDOWN: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_worker_term(sig: i32) {
    WORKER_SHUTDOWN.store(sig, Ordering::SeqCst);
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// chrono-free ISO-ish stamp; every ambient consumer parses `ts` loosely.
fn iso_now() -> String {
    format!("epoch:{}", now_epoch())
}

/// Resolved loop-control configuration. Built from flags first, then env, then
/// a byte-identical default. All knobs are plain config (no `*_BYPASS/SKIP/NO_*`
/// — INFRA-2429 ceiling, AC4).
#[derive(Clone, Debug)]
pub struct WorkerConfig {
    pub repo: PathBuf,
    /// Full command run (via `bash -c`) once per tick — the shell tick body.
    pub tick_cmd: String,
    /// Inter-tick sleep. 0 = none (the shell body's own sleeps govern cadence
    /// in shim-first mode).
    pub cadence_secs: u64,
    /// Per-tick wall-clock budget. 0 = no timeout.
    pub budget_secs: u64,
    pub pause_file: PathBuf,
    /// Node state dir (`CHUMP_STATE_DIR`, else `$HOME/.chump`) consulted via the
    /// shared `node_pause::is_paused` detector (INFRA-8583).
    pub state_dir: PathBuf,
    pub heartbeat_file: PathBuf,
    pub ambient: PathBuf,
    pub agent_id: String,
    /// 0 = loop forever; >0 stops after N ticks (test determinism).
    pub max_ticks: u64,
}

fn env_or<K: AsRef<str>>(key: K, default: &str) -> String {
    std::env::var(key.as_ref()).unwrap_or_else(|_| default.to_string())
}

/// Default subagent budget (`CHUMP_SUBAGENT_BUDGET_S` in `src/dispatch.rs`).
pub const DEFAULT_SUBAGENT_BUDGET_SECS: u64 = 900;

/// Read the active subagent wall-clock budget floor (`CHUMP_SUBAGENT_BUDGET_S`,
/// defaulting to `DEFAULT_SUBAGENT_BUDGET_SECS`). A non-zero `chumpd worker`
/// tick budget must never be lower than this floor because `budget_killed`
/// kills the entire tick body including any live `claude -p` child (INFRA-8584).
pub fn subagent_budget_floor_secs() -> u64 {
    std::env::var("CHUMP_SUBAGENT_BUDGET_S")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|&v| v > 0)
        .unwrap_or(DEFAULT_SUBAGENT_BUDGET_SECS)
}

/// Enforce the INFRA-8584 invariant: `0` stays `0` (unbounded default config so
/// `budget_killed` never fires before the subagent budget), while any non-zero
/// `requested` tick budget below `subagent_floor` is clamped up to
/// `subagent_floor` with a warning on stderr. Returns `(effective_budget, clamped)`.
pub fn clamp_tick_budget_to_subagent_floor(requested: u64, subagent_floor: u64) -> (u64, bool) {
    if requested == 0 {
        return (0, false);
    }
    if requested < subagent_floor {
        eprintln!(
            "chumpd worker: warning: configured tick budget ({requested}s) is below CHUMP_SUBAGENT_BUDGET_S ({subagent_floor}s); clamping budget_secs={subagent_floor} so budget_killed never reaps a live subagent before its own budget [INFRA-8584]"
        );
        return (subagent_floor, true);
    }
    (requested, false)
}

impl WorkerConfig {
    /// Parse `chumpd worker [flags]`. `args` is argv *after* the `worker`
    /// subcommand token.
    pub fn from_args(args: &[String]) -> Self {
        let home = PathBuf::from(env_or("HOME", "/tmp"));
        let repo = std::env::var("REPO_ROOT")
            .or_else(|_| std::env::var("CHUMP_REPO"))
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join("Projects/Chump"));
        let agent_id = env_or("AGENT_ID", "0");
        let hb_dir = env_or("CHUMP_HEARTBEAT_DIR", "/tmp");

        // Env defaults (overridden by flags below).
        let mut cfg = WorkerConfig {
            tick_cmd: std::env::var("CHUMP_WORKER_TICK_CMD").unwrap_or_else(|_| {
                format!(
                    "bash {} --tick",
                    repo.join("scripts/dispatch/worker.sh").display()
                )
            }),
            cadence_secs: std::env::var("CHUMP_WORKER_TICK_CADENCE_S")
                .ok()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(0),
            budget_secs: std::env::var("CHUMP_WORKER_TICK_BUDGET_S")
                .ok()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(0),
            pause_file: std::env::var("CHUMP_WORKER_PAUSE_FILE")
                .map(PathBuf::from)
                .unwrap_or_else(|_| repo.join(".chump/fleet-paused")),
            state_dir: std::env::var("CHUMP_STATE_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| home.join(".chump")),
            heartbeat_file: std::env::var("CHUMP_WORKER_HEARTBEAT_FILE")
                .map(PathBuf::from)
                .unwrap_or_else(|_| {
                    PathBuf::from(format!(
                        "{}/chump-fleet-worker-{}.heartbeat",
                        hb_dir, agent_id
                    ))
                }),
            ambient: repo.join(".chump-locks/ambient.jsonl"),
            max_ticks: 0,
            repo,
            agent_id,
        };

        let mut i = 0;
        while i < args.len() {
            let a = &args[i];
            let mut take = || {
                i += 1;
                args.get(i).cloned()
            };
            match a.as_str() {
                "--tick-cmd" => {
                    if let Some(v) = take() {
                        cfg.tick_cmd = v;
                    }
                }
                "--cadence-secs" => {
                    if let Some(v) = take() {
                        cfg.cadence_secs = v.trim().parse().unwrap_or(cfg.cadence_secs);
                    }
                }
                "--budget-secs" => {
                    if let Some(v) = take() {
                        cfg.budget_secs = v.trim().parse().unwrap_or(cfg.budget_secs);
                    }
                }
                "--pause-file" => {
                    if let Some(v) = take() {
                        cfg.pause_file = PathBuf::from(v);
                    }
                }
                "--state-dir" => {
                    if let Some(v) = take() {
                        cfg.state_dir = PathBuf::from(v);
                    }
                }
                "--heartbeat-file" => {
                    if let Some(v) = take() {
                        cfg.heartbeat_file = PathBuf::from(v);
                    }
                }
                "--ambient" => {
                    if let Some(v) = take() {
                        cfg.ambient = PathBuf::from(v);
                    }
                }
                "--max-ticks" => {
                    if let Some(v) = take() {
                        cfg.max_ticks = v.trim().parse().unwrap_or(cfg.max_ticks);
                    }
                }
                _ => {}
            }
            i += 1;
        }
        let (clamped, _) =
            clamp_tick_budget_to_subagent_floor(cfg.budget_secs, subagent_budget_floor_secs());
        cfg.budget_secs = clamped;
        cfg
    }

    /// True when either the farmer kill switch (`self.pause_file`, default
    /// `<repo>/.chump/fleet-paused`) exists OR the shared node-mode detector
    /// (`crate::node_pause::is_paused(&self.state_dir)`) reports the node paused
    /// (`CHUMP_NODE_MODE=paused` in `<state_dir>/node.env`, legacy
    /// `control-plane` + `CHUMP_NODE_WORK_ENABLED=0`, or
    /// `<state_dir>/.chump/fleet-paused`) — INFRA-8583 AC1/AC2.
    pub fn is_paused(&self) -> bool {
        self.pause_file.exists() || crate::node_pause::is_paused(&self.state_dir)
    }
}

fn emit(cfg: &WorkerConfig, json: &str) {
    if let Some(parent) = cfg.ambient.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&cfg.ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
    println!("{}", json);
}

/// Write the per-tick heartbeat: `<epoch> <state>`, matching worker.sh's
/// `write_heartbeat` shape (the supervisor reads mtime, not content).
fn write_heartbeat(path: &Path, state: &str) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(path, format!("{} {}\n", now_epoch(), state));
}

/// Run one tick body under an optional wall-clock budget. Returns the child's
/// exit code (or -1 if it was budget-killed / failed to spawn).
fn run_tick_with_budget(cfg: &WorkerConfig) -> i32 {
    let mut child = match Command::new("bash")
        .arg("-c")
        .arg(&cfg.tick_cmd)
        .current_dir(&cfg.repo)
        // The shim path: the shell body runs a single pass, not its own loop.
        .env("CHUMP_WORKER_SINGLE_TICK", "1")
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("chumpd worker: tick spawn failed: {e}");
            return -1;
        }
    };

    let (effective_budget_secs, _) =
        clamp_tick_budget_to_subagent_floor(cfg.budget_secs, subagent_budget_floor_secs());
    if effective_budget_secs == 0 {
        return child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
    }

    let deadline = now_epoch() + effective_budget_secs;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.code().unwrap_or(-1),
            Ok(None) => {
                if now_epoch() >= deadline || WORKER_SHUTDOWN.load(Ordering::SeqCst) != 0 {
                    let _ = child.kill();
                    let _ = child.wait();
                    // scanner-anchor: "kind":"chumpd_worker_tick_budget_killed"
                    emit(
                        cfg,
                        &format!(
                            r#"{{"ts":"{}","kind":"chumpd_worker_tick_budget_killed","agent":"{}","budget_secs":{}}}"#,
                            iso_now(),
                            cfg.agent_id,
                            cfg.budget_secs
                        ),
                    );
                    return -1;
                }
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(_) => return -1,
        }
    }
}

fn install_signal_handlers() {
    // SAFETY: the handler only stores into an atomic — signal-safe.
    unsafe {
        let handler = on_worker_term as extern "C" fn(i32) as *const () as usize;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }
}

/// `chumpd worker` entry. Returns the process exit code (128+signum on signal,
/// else 0).
pub fn run(args: &[String]) -> i32 {
    install_signal_handlers();
    let cfg = WorkerConfig::from_args(args);
    run_with_config(cfg)
}

pub fn run_with_config(cfg: WorkerConfig) -> i32 {
    // scanner-anchor: "kind":"chumpd_worker_loop_started"
    emit(
        &cfg,
        &format!(
            r#"{{"ts":"{}","kind":"chumpd_worker_loop_started","agent":"{}","cadence_secs":{},"budget_secs":{},"note":"PHASE-R R6 INFRA-8575 — loop control owned by chumpd worker; worker.sh is the tick-body shim"}}"#,
            iso_now(),
            cfg.agent_id,
            cfg.cadence_secs,
            cfg.budget_secs
        ),
    );

    let mut ticks: u64 = 0;
    let mut paused_emitted = false;
    while WORKER_SHUTDOWN.load(Ordering::SeqCst) == 0 {
        // Fleet-paused sentinel OR shared node-mode pause detector (INFRA-8583):
        // skip the tick body (no new work) but stay visibly alive via the
        // heartbeat, mirroring worker.sh FLEET-054.
        if cfg.is_paused() {
            write_heartbeat(&cfg.heartbeat_file, "paused");
            if !paused_emitted {
                // scanner-anchor: "kind":"chumpd_worker_paused"
                emit(
                    &cfg,
                    &format!(
                        r#"{{"ts":"{}","kind":"chumpd_worker_paused","agent":"{}","pause_file":"{}"}}"#,
                        iso_now(),
                        cfg.agent_id,
                        cfg.pause_file.display()
                    ),
                );
                paused_emitted = true;
            }
            ticks += 1;
            if cfg.max_ticks != 0 && ticks >= cfg.max_ticks {
                break;
            }
            sleep_cadence(&cfg);
            continue;
        }
        paused_emitted = false;

        write_heartbeat(&cfg.heartbeat_file, "tick");
        let _rc = run_tick_with_budget(&cfg);

        ticks += 1;
        if cfg.max_ticks != 0 && ticks >= cfg.max_ticks {
            break;
        }
        sleep_cadence(&cfg);
    }

    let signal = WORKER_SHUTDOWN.load(Ordering::SeqCst);
    // scanner-anchor: "kind":"chumpd_worker_loop_stopped"
    emit(
        &cfg,
        &format!(
            r#"{{"ts":"{}","kind":"chumpd_worker_loop_stopped","agent":"{}","signal":{},"ticks":{}}}"#,
            iso_now(),
            cfg.agent_id,
            signal,
            ticks
        ),
    );
    if signal == 0 {
        0
    } else {
        128 + signal
    }
}

/// Cadence sleep that wakes early on shutdown so SIGTERM isn't swallowed for a
/// whole cadence window.
fn sleep_cadence(cfg: &WorkerConfig) {
    let mut remaining = cfg.cadence_secs;
    while remaining > 0 && WORKER_SHUTDOWN.load(Ordering::SeqCst) == 0 {
        let chunk = remaining.min(1);
        std::thread::sleep(Duration::from_secs(chunk));
        remaining -= chunk;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_code_convention_in_args_default() {
        // Empty argv → defaults resolve without panicking and max_ticks stays 0.
        let cfg = WorkerConfig::from_args(&[]);
        assert_eq!(cfg.max_ticks, 0);
        assert_eq!(cfg.cadence_secs, 0);
        assert!(cfg.tick_cmd.contains("worker.sh"));
    }

    #[test]
    fn flags_override_defaults() {
        let args: Vec<String> = [
            "--cadence-secs",
            "7",
            "--budget-secs",
            "1200",
            "--max-ticks",
            "2",
            "--tick-cmd",
            "true",
            "--pause-file",
            "/tmp/p",
            "--heartbeat-file",
            "/tmp/hb",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let cfg = WorkerConfig::from_args(&args);
        assert_eq!(cfg.cadence_secs, 7);
        assert_eq!(cfg.budget_secs, 1200);
        assert_eq!(cfg.max_ticks, 2);
        assert_eq!(cfg.tick_cmd, "true");
        assert_eq!(cfg.pause_file, PathBuf::from("/tmp/p"));
        assert_eq!(cfg.heartbeat_file, PathBuf::from("/tmp/hb"));
    }

    #[test]
    fn heartbeat_write_is_epoch_prefixed() {
        let dir = std::env::temp_dir().join(format!("chumpd-wl-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let hb = dir.join("hb");
        write_heartbeat(&hb, "tick");
        let body = fs::read_to_string(&hb).unwrap();
        assert!(body.ends_with(" tick\n"), "body={body:?}");
        let epoch: u64 = body.split_whitespace().next().unwrap().parse().unwrap();
        assert!(epoch > 0);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn worker_loop_idles_when_node_env_paused_without_fleet_paused_file() {
        let dir = std::env::temp_dir().join(format!("chumpd-wl-infra8583-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let state_dir = dir.join("state");
        let repo_dir = dir.join("repo");
        fs::create_dir_all(&state_dir).unwrap();
        fs::create_dir_all(&repo_dir).unwrap();

        // AC1: node.env says CHUMP_NODE_MODE=paused and NO fleet-paused file exists.
        fs::write(state_dir.join("node.env"), "CHUMP_NODE_MODE=paused\n").unwrap();
        let pause_file = repo_dir.join(".chump/fleet-paused");
        assert!(
            !pause_file.exists(),
            "no fleet-paused file may exist in this fixture"
        );
        assert!(
            !crate::node_pause::node_sentinel_path(&state_dir).exists(),
            "no state_dir/.chump/fleet-paused sentinel may exist in this fixture"
        );

        let marker = dir.join("tick_ran");
        let hb = dir.join("worker.hb");
        let amb = dir.join("ambient.jsonl");
        let cfg = WorkerConfig {
            repo: repo_dir,
            tick_cmd: format!("touch {}", marker.display()),
            cadence_secs: 0,
            budget_secs: 5,
            pause_file,
            state_dir,
            heartbeat_file: hb.clone(),
            ambient: amb.clone(),
            agent_id: "test-0".to_string(),
            max_ticks: 1,
        };
        assert!(
            cfg.is_paused(),
            "shared detector must report paused from node.env alone"
        );

        let rc = run_with_config(cfg);
        assert_eq!(rc, 0);
        assert!(
            !marker.exists(),
            "worker loop must idle (never run tick_cmd) when node.env is paused"
        );
        let hb_body = fs::read_to_string(&hb).unwrap();
        assert!(
            hb_body.ends_with(" paused\n"),
            "heartbeat must record paused state, got: {hb_body:?}"
        );
        let amb_body = fs::read_to_string(&amb).unwrap();
        assert!(
            amb_body.contains("\"kind\":\"chumpd_worker_paused\""),
            "ambient must record chumpd_worker_paused, got: {amb_body:?}"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tick_budget_below_subagent_budget_is_clamped_with_warning() {
        // AC1 (INFRA-8584): a non-zero tick budget below CHUMP_SUBAGENT_BUDGET_S
        // is clamped up to the subagent budget floor.
        let (effective, clamped) = clamp_tick_budget_to_subagent_floor(30, 900);
        assert!(
            clamped,
            "budget below subagent floor must report clamped=true"
        );
        assert_eq!(effective, 900);

        let (at_floor, clamped_at_floor) = clamp_tick_budget_to_subagent_floor(900, 900);
        assert!(!clamped_at_floor);
        assert_eq!(at_floor, 900);

        let (above_floor, clamped_above) = clamp_tick_budget_to_subagent_floor(1500, 900);
        assert!(!clamped_above);
        assert_eq!(above_floor, 1500);

        let floor = subagent_budget_floor_secs();
        let args: Vec<String> = ["--budget-secs", "30"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let cfg = WorkerConfig::from_args(&args);
        assert_eq!(
            cfg.budget_secs, floor,
            "from_args must clamp --budget-secs 30 up to subagent_budget_floor_secs ({floor})"
        );
    }

    #[test]
    fn default_zero_tick_budget_never_fires_budget_killed() {
        // AC2 (INFRA-8584): default config has budget_secs == 0 (unbounded) and
        // never fires chumpd_worker_tick_budget_killed.
        let (effective, clamped) = clamp_tick_budget_to_subagent_floor(0, 900);
        assert!(!clamped);
        assert_eq!(effective, 0);

        let default_cfg = WorkerConfig::from_args(&[]);
        assert_eq!(default_cfg.budget_secs, 0);

        let dir = std::env::temp_dir().join(format!("chumpd-wl-infra8584-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let state_dir = dir.join("state");
        let repo_dir = dir.join("repo");
        fs::create_dir_all(&state_dir).unwrap();
        fs::create_dir_all(&repo_dir).unwrap();

        let marker = dir.join("tick_ok");
        let hb = dir.join("worker.hb");
        let amb = dir.join("ambient.jsonl");
        let cfg = WorkerConfig {
            repo: repo_dir.clone(),
            tick_cmd: format!("touch {}", marker.display()),
            cadence_secs: 0,
            budget_secs: 0,
            pause_file: repo_dir.join(".chump/fleet-paused"),
            state_dir,
            heartbeat_file: hb,
            ambient: amb.clone(),
            agent_id: "test-8584".to_string(),
            max_ticks: 1,
        };
        let rc = run_with_config(cfg);
        assert_eq!(rc, 0);
        assert!(marker.exists(), "default zero-budget tick must complete");
        let amb_body = fs::read_to_string(&amb).unwrap();
        assert!(
            !amb_body.contains("chumpd_worker_tick_budget_killed"),
            "default config (budget_secs=0) must never emit chumpd_worker_tick_budget_killed: {amb_body:?}"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
