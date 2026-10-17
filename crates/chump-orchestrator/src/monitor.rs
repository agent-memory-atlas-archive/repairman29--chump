//! Monitor loop for dispatched subagents — AUTO-013 MVP step 3.
//!
//! Step 2 (PR #145) shipped `dispatch_gap` which spawns a subagent and
//! returns a [`crate::dispatch::DispatchHandle`]. This module owns the
//! handles after spawn and watches each one until it reaches a terminal
//! [`DispatchOutcome`].
//!
//! Per the design doc §Q3 / §Q4:
//!
//! - Tick every 30s (configurable; lower in tests).
//! - For each in-flight handle:
//!   1. Probe the subprocess: did it exit non-zero? → `Killed(code)`.
//!   2. Probe the PR via `gh pr list --head <branch> --state all`.
//!      - PR `state=MERGED` → `Shipped(number)`.
//!      - PR exists, `mergeStateStatus=DIRTY` → log a warning (MVP just notes).
//!   3. Apply the soft-deadline ladder (S=20 / M=60 / L=180 / XL=skip):
//!      - `now - started_at > soft_deadline` AND no PR yet → `Stalled`.
//!      - `now - started_at > 2 × soft_deadline` → SIGTERM, 30s grace,
//!        SIGKILL. Mark `Killed("soft-deadline exceeded")`.
//!
//! The PR probe is behind the [`PrProvider`] trait so unit tests can drive
//! the state machine without shelling out to `gh` (which would hit
//! GitHub's API and require auth in CI).
//!
//! Subprocess management uses `std::process::Child` (matches `dispatch.rs`).
//! Async polling uses `tokio::time::sleep` for the inter-tick gap so the
//! orchestrator stays responsive to other work in the same runtime.

use crate::dispatch::{task_class_for_gap_id, DispatchHandle};
use crate::reflect::{
    gap_domain, outcome_str, pr_number_of, DispatchReflection, NoopReflectionWriter,
    ReflectionWriter,
};
use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Terminal state of a dispatched subagent. The monitor returns one per
/// handle once `watch_until_done` finishes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DispatchOutcome {
    /// PR `state=MERGED`. Carries the PR number.
    Shipped(u32),
    /// No heartbeat / no PR within `soft_deadline`. The subprocess (if any)
    /// is left alone — the design doc says soft-stall is informational, not
    /// auto-killed.
    Stalled,
    /// Soft-deadline 2x exceeded OR subprocess exited non-zero.
    /// String is the human-readable reason (e.g. `"exit code 1"`,
    /// `"soft-deadline exceeded (180s × 2)"`).
    Killed(String),
    /// PR opened but CI failed. Carries the PR number. MVP doesn't actively
    /// detect CI fail (it surfaces if `gh pr list` reports it); reserved
    /// for the per-tick PR probe.
    CiFailed(u32),
    /// INFRA-394: sibling agent won the gap race; this agent ceded gracefully.
    /// Not a failure — it is successful coordination. Carries the sibling's
    /// PR number when visible, otherwise `None`.
    RaceAbandoned(Option<u32>),
}

/// One row from `gh pr list --json number,state,mergeStateStatus`. Public
/// so test providers can build matching values.
#[derive(Debug, Clone, Deserialize)]
pub struct PrStatus {
    pub number: u32,
    /// `OPEN` | `CLOSED` | `MERGED` (GraphQL enum). We only care about MERGED.
    pub state: String,
    /// Optional — `gh` returns `""` when the calculation is in flight.
    /// `DIRTY` means rebase needed.
    #[serde(rename = "mergeStateStatus", default)]
    pub merge_state_status: String,
}

/// Source of PR status per branch. The production impl shells out to
/// `gh pr list`; tests inject a deterministic table.
pub trait PrProvider {
    /// Return the most recent PR for the given branch, if any. Errors should
    /// be considered transient — the monitor will retry on the next tick.
    fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>>;
}

/// Production provider — shells out to `gh pr list --head <branch>`.
///
/// Returns `Ok(None)` when there is no PR for the branch yet. Errors when
/// `gh` itself fails (auth, network) — the monitor logs and keeps polling.
pub struct GhPrProvider;

impl PrProvider for GhPrProvider {
    fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>> {
        let out = Command::new("gh")
            .args([
                "pr",
                "list",
                "--head",
                branch,
                "--state",
                "all",
                "--json",
                "number,state,mergeStateStatus",
                "--limit",
                "1",
            ])
            .output()
            .context("running gh pr list")?;
        if !out.status.success() {
            anyhow::bail!(
                "gh pr list failed for {branch}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
        let stdout = String::from_utf8(out.stdout).context("gh pr list output not utf-8")?;
        let rows: Vec<PrStatus> =
            serde_json::from_str(stdout.trim()).context("parsing gh pr list JSON")?;
        Ok(rows.into_iter().next())
    }
}

/// Soft-deadline derived from gap effort string. Returns seconds.
///
/// XL is intentionally excluded — the picker filters those out. We still
/// hand back a generous default in case an XL slips through, but the
/// monitor caller is expected to keep XL out of the dispatch table.
pub fn soft_deadline_seconds(effort: &str) -> u64 {
    match effort.to_ascii_lowercase().as_str() {
        "s" => 20 * 60,
        "m" => 60 * 60,
        "l" => 180 * 60,
        "xl" => 360 * 60, // shouldn't happen — picker rejects
        _ => 60 * 60,     // unknown effort → assume medium
    }
}

/// Internal per-handle tick result. Public for testing the pure decision
/// function in isolation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TickDecision {
    /// Continue watching.
    KeepGoing,
    /// Terminal outcome reached.
    Done(DispatchOutcome),
    /// Soft-deadline 2x exceeded — caller should kill the subprocess and
    /// then mark `Done(Killed(reason))`.
    KillThenDone(String),
}

/// Pure decision function — given current state, return next action.
/// Separated from I/O so the state machine has a fast unit-test path.
pub fn decide_tick(
    pr: Option<&PrStatus>,
    started_at_unix: u64,
    now_unix: u64,
    soft_deadline_secs: u64,
    child_exit_code: Option<i32>,
) -> TickDecision {
    // 1. Subprocess died — terminal.
    if let Some(code) = child_exit_code {
        if code == 0 {
            // Clean exit but we still want a PR; re-check below.
        } else {
            return TickDecision::Done(DispatchOutcome::Killed(format!("exit code {code}")));
        }
    }

    // 2. PR state.
    if let Some(p) = pr {
        if p.state.eq_ignore_ascii_case("MERGED") {
            return TickDecision::Done(DispatchOutcome::Shipped(p.number));
        }
        if p.state.eq_ignore_ascii_case("CLOSED") {
            // Closed without merge — treat as CI/manual failure.
            return TickDecision::Done(DispatchOutcome::CiFailed(p.number));
        }
        // OPEN: not yet terminal. Fall through to deadline check.
    }

    // 3. Deadlines (only meaningful when no PR exists — once a PR is open,
    // the merge queue / human owns the timeline).
    let elapsed = now_unix.saturating_sub(started_at_unix);
    if pr.is_none() && elapsed > 2 * soft_deadline_secs {
        return TickDecision::KillThenDone(format!(
            "soft-deadline exceeded ({soft_deadline_secs}s × 2)"
        ));
    }
    if pr.is_none() && elapsed > soft_deadline_secs {
        return TickDecision::Done(DispatchOutcome::Stalled);
    }

    TickDecision::KeepGoing
}

/// Per-handle monitoring config — soft deadline + branch identity. The
/// caller fills these in when building the loop because a `DispatchHandle`
/// alone doesn't carry the gap effort.
pub struct WatchEntry {
    pub handle: DispatchHandle,
    pub soft_deadline_secs: u64,
    /// Original effort string from the gap (`"s"` / `"m"` / `"l"` / …).
    /// Carried through so the AUTO-013 step-4 reflection row records it
    /// verbatim. Defaults to `"m"` when the caller doesn't know.
    pub effort: String,
    /// Original priority string (`"P1"` / `"P2"` / …). COG-036 records this
    /// on the routing-outcome row; defaults to `""` when the caller doesn't
    /// know.
    pub priority: String,
}

/// The monitor loop itself.
pub struct MonitorLoop<'p, P: PrProvider> {
    entries: Vec<WatchEntry>,
    /// Repository root. Used by COG-036 to locate `.chump/state.db` for the
    /// routing-outcome write hook; reserved for the worktree-teardown call
    /// in step 5.
    repo_root: PathBuf,
    tick: Duration,
    provider: &'p P,
    /// AUTO-013 step 4 — sink for one [`DispatchReflection`] per terminal
    /// outcome. Defaults to [`NoopReflectionWriter`] for back-compat with
    /// callers that don't wire one. Use [`MonitorLoop::with_reflection_writer`]
    /// to attach a real writer.
    reflection_writer: Box<dyn ReflectionWriter>,
}

impl<'p, P: PrProvider> MonitorLoop<'p, P> {
    pub fn new(
        entries: Vec<WatchEntry>,
        repo_root: PathBuf,
        tick: Duration,
        provider: &'p P,
    ) -> Self {
        Self {
            entries,
            repo_root,
            tick,
            provider,
            reflection_writer: Box::new(NoopReflectionWriter),
        }
    }

    /// Wire a [`ReflectionWriter`] (AUTO-013 step 4). Builder-style — call
    /// before [`MonitorLoop::watch_until_done`].
    pub fn with_reflection_writer(mut self, writer: Box<dyn ReflectionWriter>) -> Self {
        self.reflection_writer = writer;
        self
    }

    /// Drive the loop until every entry has reached a terminal outcome.
    /// Returns one `(branch_name, outcome)` per entry, in input order.
    ///
    /// As each entry reaches a terminal outcome, a [`DispatchReflection`]
    /// is built from the entry + the snapshot stderr tail and handed to
    /// the configured [`ReflectionWriter`] (AUTO-013 step 4). Writer
    /// errors are logged but never abort the loop — losing one row is
    /// strictly better than losing a whole batch's outcomes.
    pub async fn watch_until_done(mut self) -> Vec<(String, DispatchOutcome)> {
        // Take ownership of the handles so we can mutate `child` per entry
        // without borrow conflicts inside the tick loop.
        let mut pending: Vec<WatchEntry> = std::mem::take(&mut self.entries);
        let mut done: HashMap<String, DispatchOutcome> = HashMap::new();
        let mut order: Vec<String> = pending
            .iter()
            .map(|e| e.handle.branch_name.clone())
            .collect();
        let total_entries = order.len();

        while !pending.is_empty() {
            let mut still_pending: Vec<WatchEntry> = Vec::with_capacity(pending.len());
            // Per-tick siblings count: how many were still in flight at the
            // top of this tick. Used as `parallel_siblings` (excluding self)
            // for any entry that goes terminal during the tick.
            let in_flight = pending.len();
            for mut entry in pending.drain(..) {
                let exit = poll_child_exit(&mut entry.handle);
                let pr = self
                    .provider
                    .latest_pr(&entry.handle.branch_name)
                    .unwrap_or_else(|e| {
                        eprintln!(
                            "[monitor] gh pr list failed for {}: {e:#} (will retry)",
                            entry.handle.branch_name
                        );
                        None
                    });
                let now = unix_now();
                let decision = decide_tick(
                    pr.as_ref(),
                    entry.handle.started_at_unix,
                    now,
                    entry.soft_deadline_secs,
                    exit,
                );
                match decision {
                    TickDecision::KeepGoing => still_pending.push(entry),
                    TickDecision::Done(out) => {
                        self.record_reflection(&entry, &out, now, in_flight);
                        done.insert(entry.handle.branch_name.clone(), out);
                    }
                    TickDecision::KillThenDone(reason) => {
                        kill_child_with_grace(&mut entry.handle);
                        let out = DispatchOutcome::Killed(reason);
                        self.record_reflection(&entry, &out, now, in_flight);
                        done.insert(entry.handle.branch_name.clone(), out);
                    }
                }
            }
            pending = still_pending;
            if pending.is_empty() {
                break;
            }
            tokio::time::sleep(self.tick).await;
        }

        let _ = total_entries; // reserved for future per-batch summary metric
                               // Re-emit in input order so callers can join with their dispatch list.
        order
            .drain(..)
            .map(|b| {
                let o = done
                    .remove(&b)
                    .unwrap_or(DispatchOutcome::Stalled /* should not happen */);
                (b, o)
            })
            .collect()
    }

    /// Build + persist one dispatch reflection. Errors are logged only;
    /// the monitor must keep draining outcomes even if the DB is locked.
    fn record_reflection(
        &self,
        entry: &WatchEntry,
        outcome: &DispatchOutcome,
        now_unix: u64,
        in_flight_at_tick_start: usize,
    ) {
        let duration_s = now_unix.saturating_sub(entry.handle.started_at_unix);
        // Siblings = others in flight at the top of the tick this one ended on.
        // Subtract self so a singleton batch reports 0.
        let parallel_siblings = in_flight_at_tick_start.saturating_sub(1);
        // COG-025: prepend `backend=<label>` to notes so the synthesis layer
        // (PRODUCT-006) and the COG-026 A/B aggregator can split rows by
        // backend without a schema migration. The first line of notes is
        // still the most-recent stderr signal; the backend tag just sits in
        // front so a 1-second grep can split shipped/stalled by backend.
        //
        // INFRA-336: ALSO emit `cause:<class>` (bot-merge-hung /
        // cargo-build-timeout / chump-binary-wedge / API-credit-exhausted /
        // unknown) for failure outcomes. The dispatch-quality report
        // (INFRA-335 / PR #934) matches on these substrings; pre-INFRA-336
        // every failure showed as "unknown × N" because notes lacked the
        // class tag. Putting cause= after backend= preserves the existing
        // grep ordering for COG-026 and just adds new signal.
        let backend_label = entry.handle.backend.label();
        let stderr_tail = entry.handle.stderr_tail_snapshot();
        let cause_tag = match crate::reflect::classify_failure_cause(outcome, &stderr_tail) {
            Some(c) => format!(" cause:{c}"),
            None => String::new(),
        };
        let notes = if stderr_tail.is_empty() {
            format!("backend={backend_label}{cause_tag}")
        } else {
            format!("backend={backend_label}{cause_tag} {stderr_tail}")
        };
        let reflection = DispatchReflection {
            gap_id: entry.handle.gap_id.clone(),
            effort: entry.effort.clone(),
            gap_domain: gap_domain(&entry.handle.gap_id),
            outcome: outcome_str(outcome).to_string(),
            duration_s,
            parallel_siblings,
            pr_number: pr_number_of(outcome),
            notes,
        };
        if let Err(e) = self.reflection_writer.write(&reflection) {
            eprintln!(
                "[monitor] reflection write failed for {} ({}): {e:#} (continuing)",
                entry.handle.gap_id, reflection.outcome
            );
        }

        // COG-036: append a routing-outcome row to .chump/state.db so the
        // future Thompson-sampling router (COG-037) can self-learn from
        // real dispatch outcomes. Best-effort — the dispatch already
        // succeeded/failed; the scoreboard is observability and must never
        // abort the monitor drain.
        if let Err(e) = write_routing_outcome(&self.repo_root, entry, outcome, now_unix, duration_s)
        {
            eprintln!(
                "[monitor] routing_outcome write failed for {} ({}): {e:#} (non-fatal)",
                entry.handle.gap_id,
                outcome_str(outcome),
            );
        }
    }
}

/// Append a row to `routing_outcomes` in `<repo_root>/.chump/state.db`.
/// Resolves the DB path, creates the schema if absent, and inserts. Errors
/// propagate to the caller, which is required by COG-036 to log + swallow.
fn write_routing_outcome(
    repo_root: &Path,
    entry: &WatchEntry,
    outcome: &DispatchOutcome,
    now_unix: u64,
    duration_s: u64,
) -> Result<()> {
    let db_path = chump_store_path::state_db_path(repo_root); // INFRA-8190
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    let conn =
        Connection::open(&db_path).with_context(|| format!("opening {}", db_path.display()))?;
    // Use the same WAL/timeout pragmas as GapStore so we coexist with
    // concurrent gap-store writers.
    conn.execute_batch(
        "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
    )?;
    // Defensive: if the GapStore migration hasn't run yet on this DB (e.g.
    // a fresh checkout where dispatch terminates before any gap_store::open
    // has happened), make sure the table is there. This duplicates the
    // canonical schema in src/gap_store.rs — keep them in sync.
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS routing_outcomes (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            recorded_at   TEXT NOT NULL,
            task_class    TEXT NOT NULL DEFAULT '',
            priority      TEXT NOT NULL DEFAULT '',
            effort        TEXT NOT NULL DEFAULT '',
            backend       TEXT NOT NULL,
            model         TEXT NOT NULL DEFAULT '',
            provider_pfx  TEXT NOT NULL DEFAULT '',
            gap_id        TEXT NOT NULL,
            outcome       TEXT NOT NULL,
            pr_number     INTEGER,
            duration_s    INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS routing_outcomes_lookup
            ON routing_outcomes(task_class, backend, model, provider_pfx);
        CREATE INDEX IF NOT EXISTS routing_outcomes_recent
            ON routing_outcomes(recorded_at);",
    )?;
    // INFRA-1770: keep the cost_usd column in sync with the gap_store.rs
    // migration — see comment there. Idempotent on a DB that already has it.
    let _ = conn.execute(
        "ALTER TABLE routing_outcomes ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0.0",
        [],
    );

    let task_class = task_class_for_gap_id(&entry.handle.gap_id).unwrap_or("");
    // COG-038: prefer the handle's model/provider (carried from the
    // chosen Candidate) so cascade-driven dispatches populate the
    // scoreboard signature correctly. Env vars remain a back-compat
    // fallback for callers that haven't migrated and for the env-override
    // path in `resolve_route_for_gap`.
    let model = entry
        .handle
        .model
        .clone()
        .unwrap_or_else(|| std::env::var("CHUMP_DISPATCH_MODEL").unwrap_or_default());
    let provider_pfx = entry
        .handle
        .provider_pfx
        .clone()
        .unwrap_or_else(|| std::env::var("CHUMP_DISPATCH_PROVIDER_PFX").unwrap_or_default());
    let outcome_label = outcome_str(outcome);
    let pr_num = pr_number_of(outcome);
    let recorded_at = unix_to_rfc3339(now_unix);
    let cost_usd = tier_default_cost_usd(&entry.effort);

    conn.execute(
        "INSERT INTO routing_outcomes
            (recorded_at, task_class, priority, effort, backend, model,
             provider_pfx, gap_id, outcome, pr_number, duration_s, cost_usd)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            recorded_at,
            task_class,
            entry.priority,
            entry.effort,
            entry.handle.backend.label(),
            model,
            provider_pfx,
            entry.handle.gap_id,
            outcome_label,
            pr_num,
            duration_s as i64,
            cost_usd,
        ],
    )
    .context("insert routing_outcomes row")?;
    Ok(())
}

/// INFRA-1770: effort-tier → estimated USD cost of one dispatch attempt.
/// The orchestrator crate has no per-dispatch token accounting yet, so this
/// mirrors the same tier defaults as `budget_tracker::tier_default_cost_usd`
/// in the bin crate (which chump-orchestrator cannot depend on) as a
/// reasonable stand-in until real measured cost is threaded through
/// `DispatchHandle`. Keep the two functions' constants in sync.
fn tier_default_cost_usd(effort: &str) -> f64 {
    match effort {
        "xs" => 0.50,
        "s" => 2.00,
        "m" => 5.00,
        "l" => 20.00,
        _ => 5.00, // unknown → m default
    }
}

/// RFC3339 UTC string, matching the format `record_routing_outcome` writes
/// in tests (`"2026-04-27T12:00:00Z"`).
fn unix_to_rfc3339(ts_secs: u64) -> String {
    use chrono::{TimeZone, Utc};
    Utc.timestamp_opt(ts_secs as i64, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_default()
}

/// Try to reap the child without blocking. Returns the exit code if it has
/// already terminated, `None` otherwise.
fn poll_child_exit(handle: &mut DispatchHandle) -> Option<i32> {
    let child = handle.child.as_mut()?;
    match child.try_wait() {
        Ok(Some(status)) => Some(status.code().unwrap_or(-1)),
        Ok(None) => None,
        Err(e) => {
            eprintln!(
                "[monitor] try_wait failed for pid {:?}: {e:#}",
                handle.child_pid
            );
            None
        }
    }
}

/// Send SIGTERM, sleep 30s, send SIGKILL. On platforms without signals
/// (or when the child is already gone) we fall back to `Child::kill`.
fn kill_child_with_grace(handle: &mut DispatchHandle) {
    let Some(child) = handle.child.as_mut() else {
        return;
    };
    #[cfg(unix)]
    {
        if let Some(pid) = handle.child_pid {
            // Best-effort — ignore failure (child may have already exited).
            let _ = unsafe {
                libc_kill(pid as i32, 15 /* SIGTERM */)
            };
        }
        std::thread::sleep(Duration::from_secs(30));
    }
    // SIGKILL / TerminateProcess via stdlib.
    let _ = child.kill();
    let _ = child.wait();
}

/// Tiny libc kill shim so we don't pull a libc crate dep just for SIGTERM.
#[cfg(unix)]
unsafe fn libc_kill(pid: i32, sig: i32) -> i32 {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    kill(pid, sig)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Convenience: derive the `WatchEntry` list from a vector of dispatched
/// handles + their original gaps (so we can map `effort` → soft deadline).
pub fn watch_entries(
    handles: Vec<DispatchHandle>,
    efforts_by_gap: &HashMap<String, String>,
) -> Vec<WatchEntry> {
    watch_entries_with_priority(handles, efforts_by_gap, &HashMap::new())
}

/// COG-036: like [`watch_entries`] but also threads each gap's priority
/// string into the `WatchEntry` so the routing-outcome row records it.
/// Caller passes a parallel `priorities_by_gap` map; missing entries
/// default to `""`.
pub fn watch_entries_with_priority(
    handles: Vec<DispatchHandle>,
    efforts_by_gap: &HashMap<String, String>,
    priorities_by_gap: &HashMap<String, String>,
) -> Vec<WatchEntry> {
    handles
        .into_iter()
        .map(|h| {
            let effort = efforts_by_gap
                .get(&h.gap_id)
                .cloned()
                .unwrap_or_else(|| "m".to_string());
            let priority = priorities_by_gap
                .get(&h.gap_id)
                .cloned()
                .unwrap_or_default();
            WatchEntry {
                soft_deadline_secs: soft_deadline_seconds(&effort),
                handle: h,
                effort,
                priority,
            }
        })
        .collect()
}

/// Construct a default monitor configured with the production
/// [`GhPrProvider`] and a 30-second tick.
pub fn default_monitor(
    entries: Vec<WatchEntry>,
    repo_root: &Path,
) -> MonitorLoop<'static, GhPrProvider> {
    // Static provider so the lifetime works without juggling.
    static PROVIDER: GhPrProvider = GhPrProvider;
    MonitorLoop::new(
        entries,
        repo_root.to_path_buf(),
        Duration::from_secs(30),
        &PROVIDER,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap as Map;

    fn handle(branch: &str, gap: &str, started: u64) -> DispatchHandle {
        DispatchHandle {
            gap_id: gap.into(),
            worktree_path: PathBuf::from(format!("/tmp/{branch}")),
            branch_name: branch.into(),
            child_pid: None,
            started_at_unix: started,
            child: None,
            stderr_tail: None,
            backend: crate::dispatch::DispatchBackend::Claude,
            model: None,
            provider_pfx: None,
        }
    }

    fn entry(h: DispatchHandle, soft: u64) -> WatchEntry {
        WatchEntry {
            handle: h,
            soft_deadline_secs: soft,
            effort: "m".into(),
            priority: "P1".into(),
        }
    }

    fn pr(num: u32, state: &str) -> PrStatus {
        PrStatus {
            number: num,
            state: state.into(),
            merge_state_status: String::new(),
        }
    }

    // -- soft_deadline_seconds --------------------------------------------

    #[test]
    fn soft_deadline_table() {
        assert_eq!(soft_deadline_seconds("s"), 20 * 60);
        assert_eq!(soft_deadline_seconds("M"), 60 * 60);
        assert_eq!(soft_deadline_seconds("L"), 180 * 60);
        assert_eq!(soft_deadline_seconds("xl"), 360 * 60);
        // Unknown maps to medium so an off-spec value can't hang forever.
        assert_eq!(soft_deadline_seconds("weird"), 60 * 60);
    }

    // -- decide_tick (the pure brain) -------------------------------------

    #[test]
    fn decide_shipped_when_pr_merged() {
        let p = pr(42, "MERGED");
        let d = decide_tick(Some(&p), 0, 100, 1000, None);
        assert_eq!(d, TickDecision::Done(DispatchOutcome::Shipped(42)));
    }

    #[test]
    fn decide_ci_failed_when_pr_closed() {
        let p = pr(7, "CLOSED");
        let d = decide_tick(Some(&p), 0, 100, 1000, None);
        assert_eq!(d, TickDecision::Done(DispatchOutcome::CiFailed(7)));
    }

    #[test]
    fn decide_keep_going_when_pr_open_within_deadline() {
        let p = pr(99, "OPEN");
        let d = decide_tick(Some(&p), 0, 100, 1000, None);
        assert_eq!(d, TickDecision::KeepGoing);
    }

    #[test]
    fn decide_keep_going_no_pr_within_deadline() {
        let d = decide_tick(None, 0, 100, 1000, None);
        assert_eq!(d, TickDecision::KeepGoing);
    }

    #[test]
    fn decide_stalled_no_pr_past_soft_deadline() {
        // elapsed = 1500, soft = 1000, 2x = 2000 → stalled (not killed yet).
        let d = decide_tick(None, 0, 1500, 1000, None);
        assert_eq!(d, TickDecision::Done(DispatchOutcome::Stalled));
    }

    #[test]
    fn decide_kill_no_pr_past_2x_soft_deadline() {
        // elapsed = 2500, 2x soft = 2000 → kill.
        let d = decide_tick(None, 0, 2500, 1000, None);
        match d {
            TickDecision::KillThenDone(reason) => {
                assert!(reason.contains("1000s × 2"), "got: {reason}");
            }
            other => panic!("expected KillThenDone, got {other:?}"),
        }
    }

    #[test]
    fn decide_killed_when_child_exits_nonzero() {
        let d = decide_tick(None, 0, 100, 1000, Some(2));
        assert_eq!(
            d,
            TickDecision::Done(DispatchOutcome::Killed("exit code 2".into()))
        );
    }

    #[test]
    fn decide_clean_exit_without_pr_keeps_going_until_deadline() {
        // Subprocess exited 0 but no PR yet — wait for the deadline ladder
        // (the agent might be mid-`gh pr create` from a child shell).
        let d = decide_tick(None, 0, 100, 1000, Some(0));
        assert_eq!(d, TickDecision::KeepGoing);
    }

    #[test]
    fn decide_pr_takes_precedence_over_deadline() {
        // PR exists and is open AND we're past 2x deadline. Per design,
        // once a PR exists the merge queue / human owns the timeline:
        // we should NOT kill.
        let p = pr(11, "OPEN");
        let d = decide_tick(Some(&p), 0, 9_999, 1000, None);
        assert_eq!(d, TickDecision::KeepGoing);
    }

    // -- MonitorLoop with mocked PR provider ------------------------------

    /// Deterministic provider. Map of branch → sequence of responses; each
    /// `latest_pr` call pops the head until exhausted (then repeats last).
    struct ScriptedProvider {
        scripts: RefCell<Map<String, Vec<Option<PrStatus>>>>,
    }

    impl ScriptedProvider {
        fn new(scripts: Map<String, Vec<Option<PrStatus>>>) -> Self {
            Self {
                scripts: RefCell::new(scripts),
            }
        }
    }

    impl PrProvider for ScriptedProvider {
        fn latest_pr(&self, branch: &str) -> Result<Option<PrStatus>> {
            let mut s = self.scripts.borrow_mut();
            let v = s.entry(branch.to_string()).or_default();
            if v.len() > 1 {
                Ok(v.remove(0))
            } else {
                Ok(v.first().cloned().unwrap_or(None))
            }
        }
    }

    #[tokio::test]
    async fn watch_returns_immediately_on_empty_input() {
        let provider = ScriptedProvider::new(Map::new());
        let m = MonitorLoop::new(
            vec![],
            PathBuf::from("/tmp"),
            Duration::from_millis(10),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert!(out.is_empty());
    }

    #[tokio::test]
    async fn watch_picks_up_merged_pr_on_first_tick() {
        let mut scripts = Map::new();
        scripts.insert("claude/x".to_string(), vec![Some(pr(101, "MERGED"))]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![entry(handle("claude/x", "X-1", unix_now()), 600)];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].0, "claude/x");
        assert_eq!(out[0].1, DispatchOutcome::Shipped(101));
    }

    #[tokio::test]
    async fn watch_marks_stalled_when_no_pr_after_deadline() {
        // started_at far in the past so `elapsed > soft_deadline` immediately.
        let mut scripts = Map::new();
        scripts.insert("claude/y".to_string(), vec![None]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![entry(handle("claude/y", "Y-1", 0), 1)];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 1);
        // 2x soft = 2 seconds; elapsed is huge → KillThenDone path → Killed.
        match &out[0].1 {
            DispatchOutcome::Killed(_) => {}
            other => panic!("expected Killed (past 2x), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn watch_processes_multiple_branches_in_input_order() {
        let mut scripts = Map::new();
        scripts.insert("claude/a".to_string(), vec![Some(pr(1, "MERGED"))]);
        scripts.insert("claude/b".to_string(), vec![Some(pr(2, "MERGED"))]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![
            entry(handle("claude/a", "A", unix_now()), 600),
            entry(handle("claude/b", "B", unix_now()), 600),
        ];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].0, "claude/a");
        assert_eq!(out[1].0, "claude/b");
        assert_eq!(out[0].1, DispatchOutcome::Shipped(1));
        assert_eq!(out[1].1, DispatchOutcome::Shipped(2));
    }

    // -- watch_entries helper ---------------------------------------------

    #[test]
    fn watch_entries_uses_effort_table_and_defaults_to_medium() {
        let h1 = handle("claude/a", "A", 0);
        let h2 = handle("claude/b", "B", 0);
        let h3 = handle("claude/c", "C-NO-EFFORT", 0);
        let mut efforts: Map<String, String> = Map::new();
        efforts.insert("A".into(), "s".into());
        efforts.insert("B".into(), "l".into());
        let entries = watch_entries(vec![h1, h2, h3], &efforts);
        assert_eq!(entries[0].soft_deadline_secs, 20 * 60);
        assert_eq!(entries[0].effort, "s");
        assert_eq!(entries[1].soft_deadline_secs, 180 * 60);
        assert_eq!(entries[1].effort, "l");
        // C has no effort entry → medium fallback.
        assert_eq!(entries[2].soft_deadline_secs, 60 * 60);
        assert_eq!(entries[2].effort, "m");
    }

    // -- AUTO-013 step 4: reflection writes per outcome -------------------

    #[tokio::test]
    async fn watch_writes_one_reflection_per_outcome() {
        use crate::reflect::MemoryReflectionWriter;
        let mut scripts = Map::new();
        scripts.insert("claude/a".to_string(), vec![Some(pr(1, "MERGED"))]);
        scripts.insert("claude/b".to_string(), vec![Some(pr(2, "CLOSED"))]);
        scripts.insert("claude/c".to_string(), vec![None]); // no PR
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![
            entry(handle("claude/a", "AUTO-1", unix_now()), 600),
            entry(handle("claude/b", "EVAL-9", unix_now()), 600),
            // c has elapsed > 2x soft → KillThenDone path
            entry(handle("claude/c", "PRODUCT-3", 0), 1),
        ];
        let writer = std::sync::Arc::new(MemoryReflectionWriter::new());
        // Wrap Arc in a Box pointing at a borrowed-clone trait object via
        // a small adapter so we can both pass ownership AND inspect after.
        struct ArcAdapter(std::sync::Arc<MemoryReflectionWriter>);
        impl crate::reflect::ReflectionWriter for ArcAdapter {
            fn write(&self, r: &crate::reflect::DispatchReflection) -> Result<()> {
                self.0.write(r)
            }
        }
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        )
        .with_reflection_writer(Box::new(ArcAdapter(std::sync::Arc::clone(&writer))));
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 3);

        let snap = writer.snapshot();
        assert_eq!(snap.len(), 3, "one reflection per terminal outcome");
        // Each reflection must carry the gap_id verbatim and an outcome
        // string the synthesis layer can match on.
        let by_gap: Map<String, _> = snap.iter().map(|r| (r.gap_id.clone(), r.clone())).collect();
        assert_eq!(by_gap["AUTO-1"].outcome, "shipped");
        assert_eq!(by_gap["AUTO-1"].pr_number, Some(1));
        assert_eq!(by_gap["AUTO-1"].gap_domain, "auto");
        assert_eq!(by_gap["EVAL-9"].outcome, "ci_failed");
        assert_eq!(by_gap["EVAL-9"].pr_number, Some(2));
        assert_eq!(by_gap["EVAL-9"].gap_domain, "eval");
        assert_eq!(by_gap["PRODUCT-3"].outcome, "killed");
        assert_eq!(by_gap["PRODUCT-3"].pr_number, None);
        assert_eq!(by_gap["PRODUCT-3"].gap_domain, "product");

        // Directive must include all the fields PRODUCT-006 reads.
        let d = by_gap["AUTO-1"].directive();
        assert!(d.contains("gap=AUTO-1"));
        assert!(d.contains("effort=m"));
        assert!(d.contains("outcome=shipped"));
        assert!(d.contains("pr_number=Some(1)"));
        assert!(d.contains("parallel_siblings="));
    }

    #[tokio::test]
    async fn watch_default_writer_is_noop() {
        // A monitor built without with_reflection_writer must still drain
        // outcomes — the absence of a writer is not a failure mode.
        let mut scripts = Map::new();
        scripts.insert("claude/x".to_string(), vec![Some(pr(7, "MERGED"))]);
        let provider = ScriptedProvider::new(scripts);
        let entries = vec![entry(handle("claude/x", "X", unix_now()), 600)];
        let m = MonitorLoop::new(
            entries,
            PathBuf::from("/tmp"),
            Duration::from_millis(5),
            &provider,
        );
        let out = m.watch_until_done().await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].1, DispatchOutcome::Shipped(7));
    }

    // ── COG-036: routing-outcome write hook ─────────────────────────────

    #[test]
    fn outcome_str_table_covers_all_variants() {
        assert_eq!(outcome_str(&DispatchOutcome::Shipped(1)), "shipped");
        assert_eq!(outcome_str(&DispatchOutcome::Stalled), "stalled");
        assert_eq!(outcome_str(&DispatchOutcome::Killed("x".into())), "killed");
        assert_eq!(outcome_str(&DispatchOutcome::CiFailed(42)), "ci_failed");
    }

    #[test]
    fn write_routing_outcome_is_best_effort_on_unwritable_path() {
        // Pointing at a path that cannot be created (a non-directory file
        // sitting where `.chump/` would go) must surface an Err so the
        // caller can log + swallow. The contract is "non-fatal at the call
        // site"; this test verifies the helper itself returns Err rather
        // than panicking.
        let dir = tempfile::TempDir::new().unwrap();
        // Create a regular file at <root>/.chump so create_dir_all fails.
        let blocker = dir.path().join(".chump");
        std::fs::write(&blocker, b"not a dir").unwrap();

        let h = handle("claude/blocked", "INFRA-001", unix_now());
        let e = WatchEntry {
            handle: h,
            soft_deadline_secs: 600,
            effort: "m".into(),
            priority: "P1".into(),
        };
        let out = DispatchOutcome::Shipped(7);
        let res = write_routing_outcome(dir.path(), &e, &out, unix_now(), 12);
        assert!(
            res.is_err(),
            "expected Err when .chump path is a file, got {res:?}"
        );
        // Crucially: did NOT panic.
    }

    #[tokio::test]
    async fn watch_writes_routing_outcome_row() {
        // End-to-end: a monitor running with a tempdir repo_root should
        // append one routing_outcomes row per terminal outcome. Verifies
        // (a) the schema is created on demand, (b) the column values
        // match what the entry+outcome carried in.
        let dir = tempfile::TempDir::new().unwrap();
        let mut scripts = Map::new();
        scripts.insert("claude/a".to_string(), vec![Some(pr(101, "MERGED"))]);
        scripts.insert("claude/b".to_string(), vec![Some(pr(202, "CLOSED"))]);
        let provider = ScriptedProvider::new(scripts);

        let entries = vec![
            WatchEntry {
                handle: handle("claude/a", "EVAL-1", unix_now()),
                soft_deadline_secs: 600,
                effort: "s".into(),
                priority: "P1".into(),
            },
            WatchEntry {
                handle: handle("claude/b", "INFRA-7", unix_now()),
                soft_deadline_secs: 600,
                effort: "m".into(),
                priority: "P2".into(),
            },
        ];
        let m = MonitorLoop::new(
            entries,
            dir.path().to_path_buf(),
            Duration::from_millis(5),
            &provider,
        );
        let _ = m.watch_until_done().await;

        // Read back via raw rusqlite (avoids cross-crate dep on gap_store).
        struct Row {
            gap_id: String,
            backend: String,
            outcome: String,
            pr_number: Option<i64>,
            task_class: String,
            priority: String,
            effort: String,
            cost_usd: f64,
        }
        let conn = Connection::open(dir.path().join(".chump").join("state.db")).unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT gap_id, backend, outcome, pr_number, task_class,
                        priority, effort, duration_s, cost_usd
                 FROM routing_outcomes ORDER BY gap_id",
            )
            .unwrap();
        let rows: Vec<Row> = stmt
            .query_map([], |r| {
                Ok(Row {
                    gap_id: r.get(0)?,
                    backend: r.get(1)?,
                    outcome: r.get(2)?,
                    pr_number: r.get(3)?,
                    task_class: r.get(4)?,
                    priority: r.get(5)?,
                    effort: r.get(6)?,
                    cost_usd: r.get(8)?,
                })
            })
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(rows.len(), 2, "one row per terminal outcome");
        // EVAL-1 → shipped(101), task_class=research, effort=s, priority=P1
        assert_eq!(rows[0].gap_id, "EVAL-1");
        assert_eq!(rows[0].backend, "claude");
        assert_eq!(rows[0].outcome, "shipped");
        assert_eq!(rows[0].pr_number, Some(101));
        assert_eq!(rows[0].task_class, "research");
        assert_eq!(rows[0].priority, "P1");
        assert_eq!(rows[0].effort, "s");
        // INFRA-1770: effort=s → tier_default_cost_usd("s") == $2.00.
        assert!((rows[0].cost_usd - 2.00).abs() < f64::EPSILON);
        // INFRA-7 → ci_failed(202), task_class="" (no research prefix), priority=P2
        assert_eq!(rows[1].gap_id, "INFRA-7");
        assert_eq!(rows[1].outcome, "ci_failed");
        assert_eq!(rows[1].pr_number, Some(202));
        assert_eq!(rows[1].task_class, "");
        assert_eq!(rows[1].priority, "P2");
        // INFRA-1770: effort=m → tier_default_cost_usd("m") == $5.00.
        assert!((rows[1].cost_usd - 5.00).abs() < f64::EPSILON);
    }
}
