//! CREDIBLE-1493 (Phase R R7, slice 1): self-report calibration.
//!
//! The eval harness, pointed inward. Every operational instrument the fleet
//! uses to describe itself (fleet-brief, the mission scoreboard, fleet-doctor,
//! floor-temp, auth-status, the kpi ship gauge, the invariant-boundary gate)
//! is a *self-report*. History says they lie: a lease counter read 189 vs ~1
//! real (CREDIBLE-149), floor-temp read `admin_merge_executed=0` on the day
//! #5466 merged red through `--admin`, the scoreboard read a stale root binary
//! and called deploy STALE while the organs ran the fresh one (2026-10-15),
//! and fleet-brief said "healthy" while two organs had been failed for days.
//!
//! `docs/observability/SELF_REPORTS.yaml` pairs each self-report with a
//! ground-truth probe (git on origin/main, `gh pr list --state merged`,
//! systemctl, sqlite3, the filesystem) and a comparison rule. `chump
//! calibrate` runs both sides, compares, and emits ONE
//! `kind=self_report_calibration` ambient event carrying per-instrument
//! agreement and the overall score (agreeing pairs / total pairs).
//!
//! Honesty rules (the reason this module exists):
//!   * A probe that cannot run on this host (missing binary, wrong OS, no
//!     systemd, empty output) is `unprobed` — never `agree`.
//!   * A self-report that produces no value is `unprobed` too; the score
//!     denominator is ALWAYS the full pair count, so an unprobed pair costs
//!     agreement instead of hiding.
//!
//! Registered through the INFRA-1748 self-registration interface, so
//! `src/main.rs` carries no dispatch arm for it — only the one-line banner
//! readers in `fleet brief` and `kpi report` (see [`banner_line`]).

use crate::commands::registry::{CommandEntry, CommandOutcome};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

inventory::submit! { CommandEntry::new("calibrate", run_cli) }

/// Ambient event kind written by every calibration run.
pub const EVENT_KIND: &str = "self_report_calibration";

/// Default registry location, relative to the repo root.
pub const DEFAULT_REGISTRY: &str = "docs/observability/SELF_REPORTS.yaml";

/// Default per-command timeout.
const DEFAULT_TIMEOUT_SECS: u64 = 120;

/// How much of the tail of an ambient file the banner reader scans.
const BANNER_TAIL_BYTES: u64 = 32 * 1024 * 1024;

// ── Registry schema ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct Registry {
    pub version: u32,
    /// Named, memoized commands. A self-report that several pairs read (the
    /// mission scoreboard, fleet-doctor) runs once per calibration.
    #[serde(default)]
    pub instruments: BTreeMap<String, Instrument>,
    pub pairs: Vec<Pair>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Instrument {
    /// Tree path of the instrument's implementation (validated in CI).
    pub source: String,
    pub cmd: String,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Pair {
    pub id: String,
    pub description: String,
    /// The incident that motivated this pair, when there is one.
    #[serde(default)]
    pub receipt: Option<String>,
    pub self_report: Side,
    pub probe: Side,
    pub compare: Compare,
}

/// One side of a pair: either a direct `cmd`, or an `instrument` (memoized)
/// whose stdout is piped into an `extract` command.
#[derive(Debug, Clone, Deserialize)]
pub struct Side {
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub cmd: Option<String>,
    #[serde(default)]
    pub instrument: Option<String>,
    #[serde(default)]
    pub extract: Option<String>,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

/// Comparison rule between the self-reported value and the probed value.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Compare {
    /// Exact match after trimming; numeric when both sides parse as numbers.
    Equal,
    /// Numeric: |a-b| <= max(abs, rel * max(|a|,|b|)).
    Within {
        #[serde(default)]
        abs: f64,
        #[serde(default)]
        rel: f64,
    },
    /// Numeric: both values fall in the same bucket of the sorted
    /// `thresholds` list (bucket i = count of thresholds <= value).
    SameBucket { thresholds: Vec<f64> },
}

// ── Results ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Agree,
    Disagree,
    Unprobed,
}

impl Verdict {
    fn label(self) -> &'static str {
        match self {
            Verdict::Agree => "agree",
            Verdict::Disagree => "DISAGREE",
            Verdict::Unprobed => "unprobed",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PairResult {
    pub id: String,
    pub verdict: Verdict,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub self_value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe_value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub receipt: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CalibrationReport {
    pub ts: String,
    pub agree: usize,
    pub disagree: usize,
    pub unprobed: usize,
    pub total: usize,
    /// agree / total (0.0 when the registry is empty).
    pub score: f64,
    pub instruments: Vec<PairResult>,
}

impl CalibrationReport {
    pub fn from_results(ts: String, results: Vec<PairResult>) -> Self {
        let agree = results
            .iter()
            .filter(|r| r.verdict == Verdict::Agree)
            .count();
        let disagree = results
            .iter()
            .filter(|r| r.verdict == Verdict::Disagree)
            .count();
        let unprobed = results
            .iter()
            .filter(|r| r.verdict == Verdict::Unprobed)
            .count();
        let total = results.len();
        let score = if total == 0 {
            0.0
        } else {
            agree as f64 / total as f64
        };
        Self {
            ts,
            agree,
            disagree,
            unprobed,
            total,
            score,
            instruments: results,
        }
    }

    /// The one-line summary every surface prints.
    pub fn summary_line(&self) -> String {
        format!(
            "calibration: {}/{} instruments agree (last run {})",
            self.agree, self.total, self.ts
        )
    }

    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ chump calibrate: self-reports vs ground truth (CREDIBLE-1493) ═══\n");
        out.push_str(&format!(
            "{}  [{} disagree, {} unprobed, score {:.2}]\n",
            self.summary_line(),
            self.disagree,
            self.unprobed,
            self.score
        ));
        let width = self
            .instruments
            .iter()
            .map(|r| r.id.len())
            .max()
            .unwrap_or(0);
        for r in &self.instruments {
            let mark = match r.verdict {
                Verdict::Agree => "✓",
                Verdict::Disagree => "✗",
                Verdict::Unprobed => "·",
            };
            let mut line = format!("  {mark} {:<9} {:<width$}", r.verdict.label(), r.id);
            if r.self_value.is_some() || r.probe_value.is_some() {
                line.push_str(&format!(
                    "  self={} probe={}",
                    r.self_value.as_deref().unwrap_or("-"),
                    r.probe_value.as_deref().unwrap_or("-")
                ));
            }
            if let Some(reason) = &r.reason {
                line.push_str(&format!("  ({reason})"));
            }
            if r.verdict == Verdict::Disagree {
                if let Some(receipt) = &r.receipt {
                    line.push_str(&format!("  [receipt: {receipt}]"));
                }
            }
            out.push_str(&line);
            out.push('\n');
        }
        out
    }

    /// The ambient JSON line (one object, newline-terminated).
    pub fn event_json(&self, host: &str) -> String {
        // The literal kind (not EVENT_KIND) so the registry scanner
        // (test-event-registry-coverage.sh) sees the emit site; the test
        // `event_kind_literal_matches_const` keeps the two in lockstep.
        let v = serde_json::json!({
            "ts": self.ts,
            "kind": "self_report_calibration",
            "event": "self_report_calibration",
            "source": "chump-calibrate",
            "host": host,
            "agree": self.agree,
            "disagree": self.disagree,
            "unprobed": self.unprobed,
            "total": self.total,
            "score": (self.score * 1000.0).round() / 1000.0,
            "instruments": self.instruments,
        });
        let mut s = v.to_string();
        s.push('\n');
        s
    }
}

// ── Comparison ─────────────────────────────────────────────────────────────

fn parse_num(s: &str) -> Option<f64> {
    s.trim().parse::<f64>().ok().filter(|f| f.is_finite())
}

fn bucket(v: f64, thresholds: &[f64]) -> usize {
    thresholds.iter().filter(|t| v >= **t).count()
}

/// Compare a self-reported value against a probed value. `Err` means the
/// values could not be compared under this rule (reported as unprobed).
pub fn compare_values(rule: &Compare, self_v: &str, probe_v: &str) -> Result<bool, String> {
    let (a, b) = (self_v.trim(), probe_v.trim());
    match rule {
        Compare::Equal => match (parse_num(a), parse_num(b)) {
            (Some(x), Some(y)) => Ok((x - y).abs() < 1e-9),
            _ => Ok(a == b),
        },
        Compare::Within { abs, rel } => {
            let (x, y) = numeric_pair(a, b)?;
            let allowed = abs.max(rel * x.abs().max(y.abs()));
            Ok((x - y).abs() <= allowed + 1e-9)
        }
        Compare::SameBucket { thresholds } => {
            let (x, y) = numeric_pair(a, b)?;
            let mut t = thresholds.clone();
            t.sort_by(|p, q| p.partial_cmp(q).unwrap_or(std::cmp::Ordering::Equal));
            Ok(bucket(x, &t) == bucket(y, &t))
        }
    }
}

fn numeric_pair(a: &str, b: &str) -> Result<(f64, f64), String> {
    match (parse_num(a), parse_num(b)) {
        (Some(x), Some(y)) => Ok((x, y)),
        _ => Err(format!(
            "non-numeric values for a numeric rule: {a:?} vs {b:?}"
        )),
    }
}

// ── Execution ──────────────────────────────────────────────────────────────

/// Abstracts the host so the runner is unit-testable.
pub trait Host {
    /// `Ok(())` when the requirement holds here, `Err(why)` otherwise.
    fn requirement(&self, spec: &str) -> Result<(), String>;
    /// Run a bash command (optionally fed `stdin`); return stdout.
    fn run(&self, cmd: &str, stdin: Option<&str>, timeout: Duration) -> Result<String, String>;
}

/// The real host: `bash -c` with the calibration env exported.
pub struct RealHost {
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
}

fn which(bin: &str) -> bool {
    if bin.contains('/') {
        return Path::new(bin).is_file();
    }
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

fn expand_path(raw: &str, cwd: &Path) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    let p = PathBuf::from(raw);
    if p.is_absolute() {
        p
    } else {
        cwd.join(p)
    }
}

impl Host for RealHost {
    fn requirement(&self, spec: &str) -> Result<(), String> {
        let (kind, arg) = spec.split_once(':').unwrap_or((spec, ""));
        let ok = match kind {
            "bin" => which(arg),
            "file" => expand_path(arg, &self.cwd).exists(),
            "os" => std::env::consts::OS == arg,
            "env" => std::env::var(arg).map(|v| !v.is_empty()).unwrap_or(false),
            "systemd" => Path::new("/run/systemd/system").is_dir(),
            other => return Err(format!("unknown requirement kind '{other}'")),
        };
        if ok {
            Ok(())
        } else {
            Err(format!("requirement not met on this host: {spec}"))
        }
    }

    fn run(&self, cmd: &str, stdin: Option<&str>, timeout: Duration) -> Result<String, String> {
        let mut child = Command::new("bash")
            .arg("-c")
            .arg(cmd)
            .current_dir(&self.cwd)
            .envs(self.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("spawn bash: {e}"))?;
        if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
            let data = input.as_bytes().to_vec();
            // Writer thread so a large instrument output cannot deadlock
            // against a child that is also filling its stdout pipe.
            std::thread::spawn(move || {
                let _ = pipe.write_all(&data);
            });
        }
        let mut stdout = child.stdout.take().ok_or("no stdout pipe")?;
        let reader = std::thread::spawn(move || {
            let mut buf = String::new();
            let _ = stdout.read_to_string(&mut buf);
            buf
        });
        let start = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if start.elapsed() >= timeout => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("timed out after {}s", timeout.as_secs()));
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                Err(e) => return Err(format!("wait: {e}")),
            }
        }
        reader
            .join()
            .map_err(|_| "stdout reader panicked".to_string())
    }
}

/// The value a command reports: its last non-empty stdout line, trimmed.
fn value_of(stdout: &str) -> Option<String> {
    stdout
        .lines()
        .map(str::trim)
        .rev()
        .find(|l| !l.is_empty())
        .map(str::to_string)
}

struct Runner<'a, H: Host> {
    host: &'a H,
    registry: &'a Registry,
    default_timeout: Duration,
    memo: HashMap<String, Result<String, String>>,
}

impl<'a, H: Host> Runner<'a, H> {
    fn timeout(&self, secs: Option<u64>) -> Duration {
        secs.map(Duration::from_secs)
            .unwrap_or(self.default_timeout)
    }

    fn check_requires(&self, reqs: &[String]) -> Result<(), String> {
        for r in reqs {
            self.host.requirement(r)?;
        }
        Ok(())
    }

    /// Resolve one side to a value. `Err(reason)` → unprobed.
    fn side_value(&mut self, side: &Side) -> Result<String, String> {
        self.check_requires(&side.requires)?;
        let stdout = if let Some(name) = &side.instrument {
            let inst = self
                .registry
                .instruments
                .get(name)
                .ok_or_else(|| format!("unknown instrument '{name}'"))?
                .clone();
            self.check_requires(&inst.requires)?;
            let captured = match self.memo.get(name) {
                Some(r) => r.clone(),
                None => {
                    let r = self
                        .host
                        .run(&inst.cmd, None, self.timeout(inst.timeout_secs));
                    self.memo.insert(name.clone(), r.clone());
                    r
                }
            }
            .map_err(|e| format!("instrument '{name}' failed: {e}"))?;
            match &side.extract {
                Some(ex) => self
                    .host
                    .run(ex, Some(&captured), self.timeout(side.timeout_secs))?,
                None => captured,
            }
        } else if let Some(cmd) = &side.cmd {
            self.host.run(cmd, None, self.timeout(side.timeout_secs))?
        } else {
            return Err("side has neither cmd nor instrument".to_string());
        };
        value_of(&stdout).ok_or_else(|| "produced no value".to_string())
    }

    fn run_pair(&mut self, pair: &Pair) -> PairResult {
        let mut res = PairResult {
            id: pair.id.clone(),
            verdict: Verdict::Unprobed,
            self_value: None,
            probe_value: None,
            reason: None,
            receipt: pair.receipt.clone(),
        };
        // Self-report first: some probes (auth-status --probe) refresh the
        // very cache the self-report reads.
        match self.side_value(&pair.self_report) {
            Ok(v) => res.self_value = Some(v),
            Err(e) => {
                res.reason = Some(format!("self-report unavailable: {e}"));
                return res;
            }
        }
        match self.side_value(&pair.probe) {
            Ok(v) => res.probe_value = Some(v),
            Err(e) => {
                res.reason = Some(format!("probe cannot run: {e}"));
                return res;
            }
        }
        let (a, b) = (
            res.self_value.as_deref().unwrap_or(""),
            res.probe_value.as_deref().unwrap_or(""),
        );
        match compare_values(&pair.compare, a, b) {
            Ok(true) => res.verdict = Verdict::Agree,
            Ok(false) => res.verdict = Verdict::Disagree,
            Err(e) => res.reason = Some(format!("incomparable: {e}")),
        }
        res
    }
}

/// Run every pair (or only `only`) of `registry` against `host`.
pub fn calibrate<H: Host>(
    host: &H,
    registry: &Registry,
    only: Option<&str>,
    default_timeout: Duration,
    ts: String,
) -> CalibrationReport {
    let mut runner = Runner {
        host,
        registry,
        default_timeout,
        memo: HashMap::new(),
    };
    let results = registry
        .pairs
        .iter()
        .filter(|p| only.is_none_or(|o| p.id == o))
        .map(|p| runner.run_pair(p))
        .collect();
    CalibrationReport::from_results(ts, results)
}

/// Parse a registry and check its internal consistency.
pub fn parse_registry(text: &str) -> anyhow::Result<Registry> {
    let reg: Registry = serde_yaml::from_str(text)?;
    let mut seen = std::collections::HashSet::new();
    for p in &reg.pairs {
        anyhow::ensure!(seen.insert(p.id.clone()), "duplicate pair id '{}'", p.id);
        for (label, side) in [("self_report", &p.self_report), ("probe", &p.probe)] {
            match (&side.cmd, &side.instrument) {
                (Some(_), None) => {}
                (None, Some(name)) => anyhow::ensure!(
                    reg.instruments.contains_key(name),
                    "pair '{}' {label}: unknown instrument '{name}'",
                    p.id
                ),
                _ => anyhow::bail!(
                    "pair '{}' {label}: exactly one of cmd / instrument is required",
                    p.id
                ),
            }
        }
        if let Compare::SameBucket { thresholds } = &p.compare {
            anyhow::ensure!(
                !thresholds.is_empty(),
                "pair '{}': same_bucket needs thresholds",
                p.id
            );
        }
    }
    Ok(reg)
}

// ── Ambient I/O ────────────────────────────────────────────────────────────

fn ambient_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    crate::repo_path::main_checkout_root()
        .join(".chump-locks")
        .join("ambient.jsonl")
}

fn append_event(path: &Path, line: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    f.write_all(line.as_bytes())
}

/// Find the newest `kind=self_report_calibration` event in the tail of an
/// ambient file.
pub fn last_event_in(path: &Path) -> Option<serde_json::Value> {
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(BANNER_TAIL_BYTES);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    text.lines()
        .rev()
        .filter(|l| l.contains(EVENT_KIND))
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find(|v| v.get("kind").and_then(|k| k.as_str()) == Some(EVENT_KIND))
}

/// Render the banner for a parsed event.
pub fn banner_from_event(ev: Option<&serde_json::Value>) -> String {
    match ev {
        Some(v) => {
            let n = v.get("agree").and_then(|x| x.as_u64()).unwrap_or(0);
            let m = v.get("total").and_then(|x| x.as_u64()).unwrap_or(0);
            let ts = v.get("ts").and_then(|x| x.as_str()).unwrap_or("?");
            format!("calibration: {n}/{m} instruments agree (last run {ts})")
        }
        None => "calibration: never run (chump calibrate)".to_string(),
    }
}

/// `calibration: N/M instruments agree (last run <ts>)` from the last event
/// in the live ambient log (falling back to the first rotated slot).
pub fn banner_line() -> String {
    let live = ambient_path();
    let rotated = PathBuf::from(format!("{}.1", live.display()));
    let ev = last_event_in(&live).or_else(|| last_event_in(&rotated));
    banner_from_event(ev.as_ref())
}

/// The last event as JSON (for `fleet brief --json`).
pub fn last_event() -> Option<serde_json::Value> {
    let live = ambient_path();
    let rotated = PathBuf::from(format!("{}.1", live.display()));
    last_event_in(&live).or_else(|| last_event_in(&rotated))
}

// ── CLI ────────────────────────────────────────────────────────────────────

fn host_name() -> String {
    Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn calibration_env(repo_root: &Path) -> Vec<(String, String)> {
    let now = chrono::Utc::now();
    let iso = |d: chrono::Duration| (now - d).format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let main_root = crate::repo_path::main_checkout_root();
    let gh_repo = std::env::var("CHUMP_CALIBRATE_GH_REPO")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "repairman29/chump".to_string());
    vec![
        (
            "CHUMP_CALIBRATE_REPO_ROOT".into(),
            repo_root.display().to_string(),
        ),
        (
            "CHUMP_CALIBRATE_LOCKS_DIR".into(),
            main_root.join(".chump-locks").display().to_string(),
        ),
        ("CHUMP_CALIBRATE_GH_REPO".into(), gh_repo),
        (
            "CHUMP_CALIBRATE_NOW_EPOCH".into(),
            now.timestamp().to_string(),
        ),
        (
            "CHUMP_CALIBRATE_SINCE_1H".into(),
            iso(chrono::Duration::hours(1)),
        ),
        (
            "CHUMP_CALIBRATE_SINCE_24H".into(),
            iso(chrono::Duration::hours(24)),
        ),
        (
            "CHUMP_CALIBRATE_SINCE_7D".into(),
            iso(chrono::Duration::days(7)),
        ),
    ]
}

const USAGE: &str =
    "Usage: chump calibrate [--json] [--only <id>] [--list] [--banner] [--no-emit] [--strict]

CREDIBLE-1493 (Phase R R7): run every self-report in
docs/observability/SELF_REPORTS.yaml next to its ground-truth probe, compare,
and emit one kind=self_report_calibration ambient event.

  --json      machine-readable report
  --only ID   run a single pair
  --list      list registered pairs and exit
  --banner    print the last run's one-line score and exit (no probes)
  --no-emit   do not append the ambient event
  --strict    exit 1 when any pair disagrees (default: exit 0)

Env: CHUMP_CALIBRATE_REGISTRY (registry path), CHUMP_CALIBRATE_TIMEOUT_SECS
(per-command timeout, default 120), CHUMP_CALIBRATE_GH_REPO (owner/repo the
GitHub probes read, default repairman29/chump).";

pub fn run_cli(args: &[String]) -> CommandOutcome {
    let rest: Vec<&str> = args.iter().skip(2).map(String::as_str).collect();
    let has = |f: &str| rest.contains(&f);
    if has("--help") || has("-h") || has("help") {
        println!("{USAGE}");
        return Ok(());
    }
    if has("--banner") {
        println!("{}", banner_line());
        return Ok(());
    }
    let only = rest
        .iter()
        .position(|a| *a == "--only")
        .and_then(|i| rest.get(i + 1))
        .map(|s| s.to_string());

    let repo_root = crate::repo_path::repo_root();
    let reg_path = std::env::var("CHUMP_CALIBRATE_REGISTRY")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| repo_root.join(DEFAULT_REGISTRY));
    let text = std::fs::read_to_string(&reg_path)
        .map_err(|e| anyhow::anyhow!("read {}: {e}", reg_path.display()))?;
    let registry = parse_registry(&text)?;

    if has("--list") {
        for p in &registry.pairs {
            println!("{:<34} {}", p.id, p.description);
        }
        return Ok(());
    }
    if let Some(o) = &only {
        anyhow::ensure!(
            registry.pairs.iter().any(|p| &p.id == o),
            "no pair with id '{o}' (see chump calibrate --list)"
        );
    }

    let timeout = Duration::from_secs(
        std::env::var("CHUMP_CALIBRATE_TIMEOUT_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_TIMEOUT_SECS),
    );
    let host = RealHost {
        cwd: repo_root.clone(),
        env: calibration_env(&repo_root),
    };
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let report = calibrate(&host, &registry, only.as_deref(), timeout, ts);

    if !has("--no-emit") {
        // "kind":"self_report_calibration" — written by event_json().
        if let Err(e) = append_event(&ambient_path(), &report.event_json(&host_name())) {
            eprintln!("chump calibrate: could not append ambient event: {e}");
        }
    }
    if has("--json") {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print!("{}", report.render_text());
    }
    if has("--strict") && report.disagree > 0 {
        std::process::exit(1);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_rule_numeric_and_string() {
        assert_eq!(compare_values(&Compare::Equal, "3", "3.0"), Ok(true));
        assert_eq!(compare_values(&Compare::Equal, "0", "1"), Ok(false));
        assert_eq!(
            compare_values(&Compare::Equal, "healthy", " healthy "),
            Ok(true)
        );
        assert_eq!(
            compare_values(&Compare::Equal, "healthy", "attention"),
            Ok(false)
        );
    }

    #[test]
    fn within_rule_abs_and_rel() {
        let r = Compare::Within { abs: 2.0, rel: 0.0 };
        assert_eq!(compare_values(&r, "10", "12"), Ok(true));
        assert_eq!(compare_values(&r, "10", "13"), Ok(false));
        let r = Compare::Within { abs: 0.0, rel: 0.5 };
        // 78 reported vs 2 real (CREDIBLE-146 class) must disagree.
        assert_eq!(compare_values(&r, "78", "2"), Ok(false));
        assert_eq!(compare_values(&r, "12", "18"), Ok(true));
        assert!(compare_values(&r, "n/a", "3").is_err());
    }

    #[test]
    fn same_bucket_rule() {
        let r = Compare::SameBucket {
            thresholds: vec![1.0],
        };
        assert_eq!(compare_values(&r, "0", "0"), Ok(true));
        assert_eq!(compare_values(&r, "3", "1"), Ok(true));
        assert_eq!(compare_values(&r, "0", "2"), Ok(false));
        let r = Compare::SameBucket {
            thresholds: vec![3.0, 1.0],
        };
        assert_eq!(compare_values(&r, "1", "2"), Ok(true));
        assert_eq!(compare_values(&r, "2", "3"), Ok(false));
    }

    const FIXTURE: &str = r##"
version: 1
instruments:
  fake-dashboard:
    source: src/commands/calibrate.rs
    cmd: "printf 'ships=5\nadmin_merges=0\n'"
pairs:
  - id: agreeing
    description: ships agree
    self_report:
      instrument: fake-dashboard
      extract: "grep ships= | cut -d= -f2"
    probe:
      cmd: "echo 5"
    compare: { rule: equal }
  - id: disagreeing
    description: floor-temp says 0 admin merges, truth says 1
    receipt: "#5466"
    self_report:
      instrument: fake-dashboard
      extract: "grep admin_merges= | cut -d= -f2"
    probe:
      cmd: "echo 1"
    compare: { rule: equal }
  - id: unprobed
    description: probe needs a binary this host lacks
    self_report:
      cmd: "echo healthy"
    probe:
      cmd: "echo healthy"
      requires: ["bin:chump-calibrate-definitely-missing-binary"]
    compare: { rule: equal }
  - id: silent-probe
    description: a probe that prints nothing is unprobed, never agree
    self_report:
      cmd: "echo 0"
    probe:
      cmd: "true"
    compare: { rule: equal }
"##;

    fn test_host() -> RealHost {
        RealHost {
            cwd: std::env::temp_dir(),
            env: vec![],
        }
    }

    #[test]
    fn fixture_registry_agree_disagree_unprobed() {
        let reg = parse_registry(FIXTURE).expect("fixture parses");
        let report = calibrate(
            &test_host(),
            &reg,
            None,
            Duration::from_secs(10),
            "2026-10-17T00:00:00Z".into(),
        );
        let v: HashMap<_, _> = report
            .instruments
            .iter()
            .map(|r| (r.id.as_str(), r.verdict))
            .collect();
        assert_eq!(v["agreeing"], Verdict::Agree);
        assert_eq!(v["disagreeing"], Verdict::Disagree);
        assert_eq!(v["unprobed"], Verdict::Unprobed);
        assert_eq!(v["silent-probe"], Verdict::Unprobed);
        assert_eq!(
            (report.agree, report.disagree, report.unprobed, report.total),
            (1, 1, 2, 4)
        );
        // Unprobed pairs stay in the denominator.
        assert!((report.score - 0.25).abs() < 1e-9);
        assert_eq!(
            report.summary_line(),
            "calibration: 1/4 instruments agree (last run 2026-10-17T00:00:00Z)"
        );
        let text = report.render_text();
        assert!(text.contains("[receipt: #5466]"), "{text}");
    }

    #[test]
    fn only_filter_runs_one_pair() {
        let reg = parse_registry(FIXTURE).unwrap();
        let report = calibrate(
            &test_host(),
            &reg,
            Some("disagreeing"),
            Duration::from_secs(10),
            "t".into(),
        );
        assert_eq!(report.total, 1);
        assert_eq!(report.disagree, 1);
    }

    #[test]
    fn timeout_is_unprobed() {
        let reg = parse_registry(
            r#"
version: 1
pairs:
  - id: slow
    description: probe hangs
    self_report: { cmd: "echo 1" }
    probe: { cmd: "sleep 5; echo 1", timeout_secs: 1 }
    compare: { rule: equal }
"#,
        )
        .unwrap();
        let report = calibrate(
            &test_host(),
            &reg,
            None,
            Duration::from_secs(10),
            "t".into(),
        );
        assert_eq!(report.instruments[0].verdict, Verdict::Unprobed);
        assert!(report.instruments[0]
            .reason
            .as_deref()
            .unwrap()
            .contains("timed out"));
    }

    #[test]
    fn registry_rejects_bad_shapes() {
        let dup = r#"
version: 1
pairs:
  - { id: a, description: x, self_report: { cmd: "echo 1" }, probe: { cmd: "echo 1" }, compare: { rule: equal } }
  - { id: a, description: y, self_report: { cmd: "echo 1" }, probe: { cmd: "echo 1" }, compare: { rule: equal } }
"#;
        assert!(parse_registry(dup).is_err());
        let both = r#"
version: 1
pairs:
  - { id: a, description: x, self_report: { cmd: "echo 1", instrument: z }, probe: { cmd: "echo 1" }, compare: { rule: equal } }
"#;
        assert!(parse_registry(both).is_err());
        let unknown = r#"
version: 1
pairs:
  - { id: a, description: x, self_report: { instrument: nope }, probe: { cmd: "echo 1" }, compare: { rule: equal } }
"#;
        assert!(parse_registry(unknown).is_err());
    }

    #[test]
    fn event_kind_literal_matches_const() {
        let r = CalibrationReport::from_results("t".into(), vec![]);
        let v: serde_json::Value = serde_json::from_str(r.event_json("h").trim()).unwrap();
        assert_eq!(v["kind"], EVENT_KIND);
        assert_eq!(v["event"], EVENT_KIND);
        assert_eq!(v["score"], 0.0);
    }

    #[test]
    fn event_round_trips_through_banner_reader() {
        let reg = parse_registry(FIXTURE).unwrap();
        let report = calibrate(
            &test_host(),
            &reg,
            None,
            Duration::from_secs(10),
            "2026-10-17T03:00:00Z".into(),
        );
        let dir = tempfile::tempdir().unwrap();
        let amb = dir.path().join("ambient.jsonl");
        std::fs::write(&amb, "{\"kind\":\"other\"}\nnot json\n").unwrap();
        assert_eq!(
            banner_from_event(last_event_in(&amb).as_ref()),
            "calibration: never run (chump calibrate)"
        );
        append_event(&amb, &report.event_json("testhost")).unwrap();
        append_event(&amb, "{\"kind\":\"other\"}\n").unwrap();
        let ev = last_event_in(&amb).expect("event found");
        assert_eq!(ev["kind"], EVENT_KIND);
        assert_eq!(ev["instruments"].as_array().unwrap().len(), 4);
        assert_eq!(
            banner_from_event(Some(&ev)),
            "calibration: 1/4 instruments agree (last run 2026-10-17T03:00:00Z)"
        );
    }

    #[test]
    fn shipped_registry_parses_with_at_least_twelve_pairs() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(DEFAULT_REGISTRY);
        let reg = parse_registry(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert!(reg.pairs.len() >= 12, "only {} pairs", reg.pairs.len());
        for receipt_pair in [
            "floor-temp-admin-merges",
            "fleet-status-active-leases",
            "kpi-ships-1d",
            "scoreboard-deploy-freshness",
            "brief-healthy-vs-failed-organs",
        ] {
            assert!(
                reg.pairs.iter().any(|p| p.id == receipt_pair),
                "missing receipt pair {receipt_pair}"
            );
        }
    }
}
